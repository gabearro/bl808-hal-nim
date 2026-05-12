# WiFi + BLE End-to-End Hardening — Design

**Date**: 2026-05-09
**Status**: Approved by user, ready for implementation planning
**Scope**: Multi-iteration arc to take WiFi and BLE on BL808 from "intermittent on hardware" to "≥ 99 % success rate over three consecutive matrix runs."

---

## 1. Goal and success criteria

A single `make hw-e2e` target builds **six firmwares** (3 milestones × 2 backends each), runs each on hardware N times (default N=20), and emits a structured report. Exits zero only when every cell hits the configured success-rate floor.

| Test binary | Backends | Milestone | Phase buckets |
|---|---|---|---|
| `m0_wifi_e2e_test` | blob (`-d:bl808WifiVendor`), reimpl | Associate to `Frog` → DHCP → TCP echo to harness host | `scan`, `auth`, `4whs`, `assoc`, `dhcp`, `tcp` |
| `m0_ble_periph_e2e_test` | blob (`-d:bl808BleVendor`), reimpl | Advertise `bl808-e2e` → Mac connects → MTU exchange → 1 GATT read → clean disconnect | `adv_start`, `connect_req`, `mtu`, `gatt_read`, `disconnect` |
| `m0_ble_central_e2e_test` | blob, reimpl | Mac advertises `mac-e2e` → board scans → connects → MTU exchange → 1 GATT read → disconnect | `scan`, `connect_req`, `mtu`, `gatt_read`, `disconnect` |

Each cell is `(binary, backend)`: 6 cells total.

**Mac-side coordination per role:**
- WiFi: passive — `Frog` AP must be reachable; harness sanity-pings it before the cell starts.
- BLE peripheral: `tools/ble_connect_validate.py` spawned per attempt by `hw_e2e_mac.py`; returns non-zero on failure.
- BLE central: `tools/ble_advertise_macos.py` spawned once per cell, advertising `mac-e2e` for the duration of the cell's N attempts.

**Out of scope for this arc** (deliberate — pulled in only after the 95 % floor is reached):
- WiFi roaming, multiple AP profiles, WPA2-Enterprise (only WPA2-PSK to `Frog`).
- BLE pairing / bonding / encryption.
- BLE GATT beyond a single fixed read characteristic.
- WiFi+BLE coex in the same firmware (each is its own binary).
- D0 and LP cores' role in WiFi/BLE (M0-only — matches existing test surface).

---

## 2. Architecture

Five new components plus one extension to existing harness code.

### 2.1 Phase marker library — `src/bl808/kernel/e2e_marker.nim`

~80 lines. Single template:
```
phaseMark(phase, kind, kv...)
```
Emits **two** sinks per call:
1. UART line: `@e2e <phase>:<kind> [k=v]…` — machine parseable, no allocations.
2. Fixed-size record (4-byte phase + 4-byte kind + 16-byte kv blob) into the JTAG memory log ring (existing `src/bl808/kernel/jtaglog.nim`).

`phase` is a Nim enum, `kind ∈ {start, ok, fail, info}`. Attempt framing markers are part of the same enum: `attempt:start n=K total=N`, `attempt:done n=K total=N result=ok|fail`.

### 2.2 E2E test scaffolding — `src/bl808/kernel/e2e_runner.nim`

~150 lines. Provides the per-binary entry-point loop:
```
for i in 1..N:
  phaseMark(attempt, start, n=i, total=N)
  runOne()              # test body emits its own phaseMark per phase
  deinitForRetry()      # stack-specific clean teardown hook
  phaseMark(attempt, done, n=i, total=N, result=...)
```
Plus `waitMacReady()` (reads `@cmd start` from UART input — used by BLE central to wait for the Mac advertiser).

Single-boot N-attempt loop. If a backend cannot honour `deinitForRetry()` cleanly, the test opts out and re-flashes per attempt.

### 2.3 Six test binaries — `examples/m0_*_e2e_test.nim`

- `m0_wifi_e2e_test.nim` — ~120 lines.
- `m0_ble_periph_e2e_test.nim` — ~100 lines.
- `m0_ble_central_e2e_test.nim` — ~100 lines.

Each compiles against both backends via existing `-d:bl808WifiVendor` / `-d:bl808BleVendor` flags. Source style follows existing `m0_*_hal_test.nim`.

### 2.4 Soak runner — `tools/hw_e2e.py`

~400 lines. Composes with `tools/hw_validate.py`'s anchor-flash + UART-open primitives. Per (binary × backend) cell:
1. Build firmware.
2. Anchor-flash via existing `--uart-anchor-runtime-jtag` plumbing. **Asserts the anchor responds** before flashing; aborts with `re-flash the anchor with make hw-smoke-anchor` if absent.
3. Drive UART for the full N-attempt run, parsing only `@e2e` markers (free-form prints ignored except for human-readable log capture).
4. Per-phase deadline arming: `phase:start` arms a soft deadline (configurable per phase, e.g. scan=5 s, dhcp=8 s, gatt_read=2 s); on miss, runner injects synthetic `phase:fail reason=timeout`.
5. On any non-`ok` attempt: pull JTAG memory log via single OpenOCD attach + mem read of ring buffer base + immediate detach. Save to `build/hw-e2e/<ts>/cell-<x>-attempt-<n>.jtaglog`. Successful attempts skip JTAG entirely.
6. Emit JSON report (`build/hw-e2e/report-<ts>.json`) and terminal summary with per-phase success rate, regression diff vs previous run.

### 2.5 Mac-side adapter — `tools/hw_e2e_mac.py`

~250 lines. Three modes:
- `wifi-passive` — pre-cell sanity check that `Frog` is reachable from the Mac.
- `ble-peripheral` — spawn `ble_connect_validate.py` per attempt, triggered when UART emits `adv_start:ok`. Subprocess timeout: 10 s.
- `ble-central` — spawn `ble_advertise_macos.py` once per cell (kept up across all N attempts), wait for "advertising" confirmation, then send `@cmd start` over UART input to release the board for the first attempt.

Reuses `tools/ble_advertise_macos.py` and `tools/ble_connect_validate.py` as importable libraries (no double-spawn). Invoked as a subprocess from `hw_e2e.py`; shares its log directory.

### 2.6 Phase-enum single source of truth — `tools/e2e_phases.py`

~60 lines. Defines the canonical `Phase` enum used by `hw_e2e.py`. A small generator script writes the matching Nim enum into `src/bl808/kernel/e2e_marker.nim` at build time. **Renaming a phase in one place auto-updates the other.** A build-time assert fails if they drift.

### 2.7 Extension to `tools/hw_validate.py`

Add `--driver e2e` mode that delegates UART parsing to the soak runner instead of the existing per-test JSON shape. Keeps the JTAG/anchor/load primitives reusable; no new flash code paths.

### 2.8 Failure bucketing rule

The **last `phase:start` without a matching `phase:ok`** is the failure bucket for an attempt. Explicit `phase:fail reason=...` markers are preferred where the firmware can detect the failure itself; the synthetic-timeout rule is the catch-all.

---

## 3. Data flow per attempt

Three variants, one per milestone. All share Section 2's marker grammar.

### 3.1 WiFi attempt

```
board                                      harness                    Mac/AP
─────                                      ───────                    ──────
@e2e attempt:start n=n total=N
@e2e scan:start ssid=Frog
@e2e scan:ok bssid=… rssi=… ch=…
@e2e auth:start
@e2e auth:ok
@e2e 4whs:start
@e2e 4whs:ok
@e2e assoc:start
@e2e assoc:ok aid=…
@e2e dhcp:start
@e2e dhcp:ok ip=… gw=…
@e2e tcp:start dst=<harness IP>:<port>     listening on TCP echo port
@e2e tcp:ok rtt_ms=…                       (echoes 16 bytes)
@e2e attempt:done n=n result=ok
deinitForRetry()  →  next attempt
```

Harness runs a tiny TCP echo server on its host (one socket, accept loop) so the test target IP is always the harness — no LAN-side fixture required. Credentials (`Frog` / `<wifi-password>`) are passed via existing `-d:WifiSsid=… -d:WifiPassword=…` strdefines.

### 3.2 BLE peripheral attempt

```
board                                      harness                    Mac (ble_connect_validate.py)
─────                                      ───────                    ──────────────────────────────
@e2e attempt:start n=n total=N
@e2e adv_start:start name=bl808-e2e
@e2e adv_start:ok                          spawns ble_connect_validate.py
@e2e connect_req:start                                                 scans, finds bl808-e2e
@e2e connect_req:ok handle=…                                           connected
@e2e mtu:start
@e2e mtu:ok mtu=…                                                      MTU exchange done
@e2e gatt_read:ok value=DEADBEEF                                       reads 0xBEEF, asserts
@e2e disconnect:ok reason=local                                        disconnects
@e2e attempt:done n=n result=ok
```

Fresh CoreBluetooth client per attempt — no Mac-side state carried across attempts. Mac subprocess timeout: 10 s.

### 3.3 BLE central attempt

```
board                                      harness                    Mac (ble_advertise_macos.py)
─────                                      ───────                    ────────────────────────────
                                           starts advertiser FIRST    advertising mac-e2e
                                           waits for "ready"
                                           sends @cmd start over UART
@e2e attempt:start n=n total=N
@e2e scan:start filter=mac-e2e
@e2e scan:ok bdaddr=… rssi=…
@e2e connect_req:start
@e2e connect_req:ok handle=…                                           connection accepted
@e2e mtu:start
@e2e mtu:ok mtu=…
@e2e gatt_read:start svc=… char=…                                      serves 0xCAFEBABE on read
@e2e gatt_read:ok value=CAFEBABE
@e2e disconnect:ok reason=local
@e2e attempt:done n=n result=ok
                                           tears down advertiser at end of cell
```

Advertiser launched **once per cell** to amortise macOS Bluetooth daemon startup over all N attempts.

### 3.4 Synchronisation rules

- **Marker line is authoritative.** No regex on free-form chatter.
- **Per-phase deadline.** Soft per-phase timeouts; runner injects synthetic `fail reason=timeout` on miss.
- **Mac subprocess lifecycle.** BLE peripheral: spawn-per-attempt. BLE central: spawn-per-cell. Stdout of each is folded into the per-attempt record.
- **Failure attachment.** JTAG memory log pulled only on failed attempts; happy path stays touchless.
- **`deinitForRetry()` independence.** Must restore "as if just booted" state. Backends that can't honour that opt out and force re-flash per attempt.

---

## 4. File and module layout

### New files

```
src/bl808/kernel/
  e2e_marker.nim          ~80 lines.
  e2e_runner.nim          ~150 lines.

examples/
  m0_wifi_e2e_test.nim         ~120 lines.
  m0_ble_periph_e2e_test.nim   ~100 lines.
  m0_ble_central_e2e_test.nim  ~100 lines.

tools/
  hw_e2e.py               ~400 lines.
  hw_e2e_mac.py           ~250 lines.
  e2e_phases.py           ~60 lines.

docs/superpowers/specs/
  2026-05-09-wifi-ble-end-to-end-design.md   (this file)
```

### Modified files

```
Makefile
  + hw-e2e:                  build all 6 firmwares, run full matrix, N=20
  + hw-e2e-wifi-only:        WiFi cell only (both backends)
  + hw-e2e-ble-periph-only:  BLE peripheral cell only
  + hw-e2e-ble-central-only: BLE central cell only
  + hw-e2e-quick:            N=3 instead of N=20

src/bl808/kernel/jtaglog.nim
  + record-shape variant for phaseMark events. No API breakage to existing callers.

.gitignore
  + build/hw-e2e/
  + build/kernel-validation-*/      (also closes the gap from Section 0 review)
  + build/validation-wifi-ble-*/
  + qemu-machine/tests/__pycache__/
```

### Conventions

- Style: idiomatic Nim, no new linter, no new test framework. Tests follow existing `m0_*_hal_test.nim` shape.
- Python deps: only what `requirements-hw.txt` already provides; pin any additions there.
- Phase enum: `tools/e2e_phases.py` is the single source; Nim copy generated at build time.
- No new docs beyond this spec; the runner's `--help` and a top-of-file comment in `hw_e2e.py` are the user-facing reference.

---

## 5. First-iteration staging

The full design is six matrix cells × N=20. Staged delivery so each iteration produces a runnable thing:

### Iteration 1 — Skeleton

Lands: `e2e_marker.nim`, `e2e_runner.nim`, `e2e_phases.py`, the build-time enum generator, `hw_e2e.py` (single-cell mode), `hw_e2e_mac.py wifi-passive`, the WiFi e2e binary against **the blob backend only**, Makefile `hw-e2e-quick` target.

Success: `make hw-e2e-quick` builds the WiFi blob firmware, anchor-flashes, runs N=3 attempts, prints per-phase success table, exits 0 if ≥ 2/3 succeed. **No tuning** — goal is "loop runs, produces right shape of data."

### Iteration 2 — Matrix breadth, blobs only

Lands: WiFi reimpl backend cell, BLE peripheral binary against blob, BLE central binary against blob, `hw_e2e_mac.py ble-peripheral` and `ble-central` modes, full `hw-e2e` matrix Makefile target.

Success: `make hw-e2e-quick` runs **5 cells** (WiFi blob+reimpl, BLE-periph blob, BLE-central blob — no BLE reimpl yet), N=3, ≥ 2/3 per cell. Failures get JTAG-mem dumps attached.

### Iteration 3 — Reimpl BLE cells + first soak

Lands: BLE peripheral and BLE central reimpl backends. First full N=20 soak run.

Success: 6-cell matrix at N=20 produces a complete report. **No floor enforced** — purpose is baseline failure-rate distribution. Output: scoreboard markdown committed to `build/hw-e2e/baselines/2026-05-XX.md`.

### Iteration 4+ — Hardening loop

Each iteration:
1. Pick worst-rate cell from latest report.
2. Form hypothesis (JTAG-mem trace from a failed attempt is primary input).
3. Make **one** targeted change.
4. Re-run `make hw-e2e` (~10 min).
5. Diff vs previous baseline. Commit baseline if improved; revert change if not.

Floor ratchets: 90 % → 95 % → 99 %. Stop when ratchet stalls.

---

## 6. Stop conditions

Arc is "done" when the 6-cell matrix sustains **≥ 99 % success rate over three consecutive runs on different days** (proves it's not a single-session artifact). Then either start a new arc (coex, encryption, dual-mode, etc.) or ship.

---

## 7. Risks and unknowns

- **Reimpl BLE and reimpl WiFi may regress severely vs blob.** Section 5's iteration 3 is when we'll know; if reimpl baselines are far off blob, the hardening loop in iteration 4+ will lean on differential blob-vs-reimpl debugging more than tuning. Both paths use the same `phaseMark` markers, so the comparison is mechanical.
- **`deinitForRetry()` may not be clean for all backends.** If a backend leaves residual state (uncleared IRQ enables, dangling lwIP netif, BLE controller in an unrecoverable state), single-boot N-attempt loop becomes unsafe and that test forces re-flash per attempt — accepting the latency hit. Detected by attempt-1 success rate diverging significantly from attempt-2..N rate; the soak runner reports both.
- **macOS BLE daemon flakes** can produce false-fail attempts. Mitigation: the `ble-central` advertiser is spawned per cell (not per attempt) so daemon startup cost is amortised; per-attempt CoreBluetooth client is fresh on the peripheral path. If false-fails dominate, escalate to Approach C (external sniffer, deferred).
- **TCP echo target on the harness host** assumes the board can route to the harness over the LAN once DHCP completes. If the harness is on a different VLAN, this fails — operator-side issue, called out in `hw_e2e.py --help`.
- **Anchor binary integrity.** Soak runner asserts anchor responds before flashing; if absent, aborts with re-flash instructions rather than silently entering a path that needs human button-pressing.
