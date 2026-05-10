# WiFi DHCP + TCP + Reimpl Backend — Iter 2.A Design

**Date**: 2026-05-09
**Status**: Approved by user, ready for implementation planning
**Parent spec**: `docs/superpowers/specs/2026-05-09-wifi-ble-end-to-end-design.md` (Section 5, Iteration 2 — decomposed into 2.A / 2.B / 2.C; this spec covers 2.A only)

---

## 1. Goal and success criteria

`make hw-e2e-quick` grows from 1 cell to **2 cells**, both running the WiFi e2e binary, one against the vendor blob and one against `wifi_fw.nim`. Each attempt walks the full stack: scan → auth → 4whs → assoc → **dhcp** → **tcp**. An attempt is `ok` iff all six phases reach `:ok`.

| Cell | Backend defines | Phases measured |
|---|---|---|
| `wifi-blob` | `bl808WifiVendor` | scan, auth, 4whs, assoc, **dhcp, tcp** |
| `wifi-reimpl` | `bl808WifiVendor`, `bl808WifiNimFw` | scan, auth, 4whs, assoc, **dhcp, tcp** |

**Success criterion for Iter 2.A**: same shape as Iter 1's "land the data shape, not tune the rate." Per cell, ≥ 2/3 attempts `ok` is a PASS for the blob cell. The reimpl cell is **expected to potentially fail consistently** since `wifi_fw.nim` has never been run end-to-end on hardware — failing data is still useful (the failure bucket tells us where reimpl diverges from blob). The reimpl cell's PASS bar for Iter 2.A is "produces a complete 3-attempt report" — not "≥ 2/3 attempts ok".

Two dependencies that determine practical viability:

- **Blob already wires its netif into lwIP**: needs verification. `wifi.nim:wifiGetNetif()` returns a pointer that we cast to `ptr Netif` for lwIP calls. If the blob hasn't already called `netifAdd`/`netifSetUp`/`netifSetLinkUp` on the returned netif, our `dhcpStart(netif)` will silently fail. **Pass 1 of the iteration includes a probe to detect this.**
- **lwIP RX/TX pump exists for WiFi**: the WiFi blob is supposed to call into lwIP from its RX path (otherwise no DHCP responses ever reach lwIP). EMAC has its own pump (`netlwipPoll()`); WiFi may need similar explicit calls from the test's main loop. Will discover during Pass 1.

**Out of scope for 2.A**:
- BLE peripheral & central (deferred to 2.B / 2.C)
- TCP server-mode (board only does outgoing connections)
- IPv6, multiple TCP connections, persistent connections across attempts
- Live UART streaming refactor (deferred to 2.B where Mac-side script orchestration needs it)
- Hardening of the reimpl cell (data collection only here; fixes in a future iteration once buckets are clear)
- N=20 full-soak mode (still N=3 quick; full-soak is Iter 3 territory per the parent spec)

---

## 2. Architecture

Two new components, three extensions.

### 2.1 In-process TCP echo server — new helper inside `tools/hw_e2e.py`

A tiny `EchoServer` class. Single TCP socket bound to `0.0.0.0:0` (kernel-assigned port). Accept loop in a daemon thread reads up to 64 bytes, writes the same bytes back, closes the connection. Lifetime: started before the cell's flash, stopped after the cell completes. ~50 lines.

LAN-IP discovery via the standard idiom: open a UDP socket, `connect("8.8.8.8", 53)`, read `getsockname()[0]` — returns the local interface IP that would be used to reach the public internet (no packet sent). Falls back to `socket.gethostbyname(socket.gethostname())` if the UDP trick errors. The discovered IP is passed to firmware as the `WifiEchoHost` build define.

### 2.2 Firmware DHCP + TCP phases — extension to `examples/m0_wifi_e2e_test.nim`

After the existing synthetic `assoc:ok` markers, add real DHCP and TCP phases:

```
phaseMark(Phase.dhcp, Kind.start)
let netif = cast[ptr Netif](wifiGetNetif())
if netif == nil:                  → dhcp:fail reason=no_netif; return false
let rc = dhcpStart(netif)
if rc != ErrOk:                    → dhcp:fail reason=dhcp_start; return false
poll netif's ip4_addr field for up to 10s, calling sysCheckTimeouts() every 50ms
if no IP after timeout:            → dhcp:fail reason=timeout; return false
phaseMark(Phase.dhcp, Kind.ok) with kvWrite(ip=…) kvWrite(gw=…)

phaseMark(Phase.tcp, Kind.start) with kvWrite(dst=WifiEchoHost) kvWrite(port=WifiEchoPort)
tcpNew → tcpConnect(echo_host, echo_port) → wait connect callback (timeout 5s)
on connected: send 16 bytes "BL808-E2E-PROBE\n" → wait recv callback for 16 bytes (timeout 3s)
validate payload bytes match
tcpClose
phaseMark(Phase.tcp, Kind.ok) with kvWrite(rtt_ms=…)
```

The lwIP API is callback-driven (`tcpRecv(pcb, recv_cb)`, `tcpErr(pcb, err_cb)`), so we use a small state-machine approach: declare a module-global `TcpState` record, callbacks update it, the polling loop reads it. ~80 lines added to the binary.

### 2.3 lwIP polling integration — investigation, Pass 1

The first build will reveal whether the WiFi blob already pumps lwIP (likely yes — DHCP can't work without it). If not, add a `netlwipPoll()`-equivalent for WiFi or call `sysCheckTimeouts()` from the test's wait loops. The investigation is part of Iter 2.A's Pass 1.

### 2.4 Catalog — extension to `tools/hardware_validation.json`

Existing `m0_wifi_e2e_test` entry gains two defines: `WifiEchoHost` (env: `BL808_WIFI_E2E_HOST`), `WifiEchoPort` (env: `BL808_WIFI_E2E_PORT`). New `m0_wifi_e2e_test_reimpl` entry: same `source`, same defines, plus `bl808WifiNimFw=1`. Both `tiers: ["e2e"]`. Both `required: ["=== BL808 E2E Test Complete ==="]`. The `WifiEchoHost`/`WifiEchoPort` env vars get set by `hw_e2e.py` from the EchoServer's discovered IP and assigned port.

### 2.5 Orchestrator — extension to `tools/hw_e2e.py`

`--cell` choices grow from `["wifi-blob"]` to `["wifi-blob", "wifi-reimpl", "all"]`. New code path:

```python
if args.cell == "all":
    for cell in ("wifi-blob", "wifi-reimpl"):
        report = run_cell(cell, ...)
        results.append(report)
    print_matrix_summary(results)
    return 0 if all(r.success_rate >= floor for r in results) else 1
```

`run_cell(name)` = the existing per-cell logic (start EchoServer, build, flash, run, parse, write JSON), parameterized by the catalog test name (`m0_wifi_e2e_test` for `wifi-blob`, `m0_wifi_e2e_test_reimpl` for `wifi-reimpl`).

The EchoServer is **shared across cells in `--cell all` mode**: started once at the top of the run, torn down at the end. Per-cell startup cost stays low.

---

## 3. Data flow per attempt

```
hw_e2e.py                       harness host LAN              board (firmware)
─────────                       ────────────────              ─────────────────
EchoServer.start()
  bind 0.0.0.0:0 → port=51234
  daemon thread: accept/echo loop
discover LAN IP: 10.0.0.5
set env BL808_WIFI_E2E_HOST=10.0.0.5
        BL808_WIFI_E2E_PORT=51234
spawn hw_validate.py --test wifi-blob
  → builds firmware with
    -d:WifiEchoHost=10.0.0.5
    -d:WifiEchoPort=51234
  → anchor-flashes, resets target

                                                              boots, runs e2e_runner
                                                              for attempt n in 1..3:
                                                                @e2e attempt:start n=n total=3
                                                                @e2e scan:start ssid=Frog
                                                                  wifiInit()
                                                                @e2e scan:ok
                                                                @e2e auth:start
                                                                  wifiConnect(Frog, …)
                                                                @e2e auth:ok
                                                                @e2e four_whs:start / :ok    (synthetic)
                                                                @e2e assoc:start / :ok       (synthetic)
                                                                @e2e dhcp:start
                                                                  netif = wifiGetNetif()
                                                                  dhcpStart(netif)
                                                                  poll netif.ip4_addr 50ms × 200
                                                                    sysCheckTimeouts() each iter
                                                                @e2e dhcp:ok ip=10.0.0.42 gw=10.0.0.1

                                                                @e2e tcp:start dst=10.0.0.5 port=51234
                                                                  tcpNew → tcpConnect
                                                                  wait connect_cb (5s)
                                connect from 10.0.0.42:54321  ←
                                accept                        →
                                                                  tcpWrite("BL808-E2E-PROBE\n")
                                payload received (16 bytes)   ←
                                echo bytes back               →
                                                                  recv_cb fires, validate 16 bytes match
                                                                  tcpClose
                                close connection              ←
                                                                @e2e tcp:ok rtt_ms=12 bytes=16
                                                                @e2e attempt:ok n=n total=3
                                                                deinitForRetry: wifiDisconnect()
                                                              done loop
                                                              "=== BL808 E2E Test Complete ==="
hw_validate.py exits (sentinel matched)
parse_log_file() → markers
summarize_cell → CellReport
write JSON, print summary
EchoServer.stop()
```

### Failure modes per phase

- **scan / auth / four_whs / assoc**: same as Iter 1 — explicit `phase:fail reason=…` if `wifiInit`/`wifiConnect` returns non-ok; otherwise the firmware emits start-then-ok pairs.
- **dhcp**:
  - `no_netif` — `wifiGetNetif()` returned nil
  - `dhcp_start` — `dhcpStart(netif)` returned non-ErrOk
  - `timeout` — netif's ip4_addr stayed 0 for 10s
  - `unconfigured` — netif up, IP 0.0.0.0/0.0.0.0 (defensive; should not happen)
- **tcp**:
  - `pcb_alloc` — tcpNew returned nil (heap pressure)
  - `connect_failed` — connect_cb fired with err != ErrOk, OR connect_cb didn't fire within 5s
  - `recv_short` — server closed before sending all 16 bytes
  - `payload_mismatch` — 16 bytes received but contents differ
  - `recv_timeout` — recv_cb didn't fire within 3s
  - `lwip_err` — generic lwIP error from err_cb

The marker grammar already supports `reason=` keys; no parser changes needed. The Python aggregator's "explicit fail wins over last-started-without-ok" rule handles all of these correctly.

### EchoServer protocol

- Bind: `0.0.0.0:0` (kernel-assigned port).
- Accept: blocking loop in daemon thread.
- Per-connection: `recv(64)`, `sendall(data)`, `close()`. No state, no protocol negotiation.
- 16 bytes is what the firmware sends (`BL808-E2E-PROBE\n` = 16 bytes including the newline). EchoServer's `recv(64)` is generous — if the LAN MTU fragments differently we still get the bytes.
- Close after one round trip per connection. Each attempt opens a fresh TCP connection.

### Concurrency

Only one cell's firmware is running at a time (cells run sequentially in `--cell all`). EchoServer has at most one in-flight connection. No locking needed in the server.

---

## 4. File and module layout

### New files

(none)

Iter 2.A is purely additive within existing files plus catalog entries.

### Modified files

```
examples/m0_wifi_e2e_test.nim
  + import bl808/kernel/lwipcore (Netif, dhcpStart, tcpNew/Bind/Connect/Write/Recv/Close, sysCheckTimeouts)
  + add `WifiEchoHost` (strdefine), `WifiEchoPort` (intdefine) consts
  + extend `runOneAttempt`:
      after assoc:ok: dhcp phase, then tcp phase
      ~80 lines added including TcpState record + connect/recv/err callbacks
  + the existing four-phase markers stay; the binary keeps its current shape
  ~ +90 lines total

tools/e2e_phases.py
  No change (Phase.dhcp and Phase.tcp already exist; declared in Iter 1 for
  forward-compat). The drift test asserts the Nim copy stays in sync.

src/bl808/kernel/e2e_marker.nim
  No change (generated content; tests verify it matches e2e_phases.py).

src/bl808/kernel/lwipcore.nim
  Possible small extension if `tcpConnect` / `tcpWrite` aren't already exported
  (existing exports cover tcpNew/Bind/Listen/Accept/Recv/Sent/Err but not
  necessarily connect/write). If needed: ~+5 to +20 lines of importc wrappers.

tools/hw_e2e.py
  + class EchoServer (~50 lines): bind, accept loop, lifecycle (start/stop)
  + def discover_lan_ip() -> str (~10 lines): UDP-trick + fallback
  + extend --cell choices: ["wifi-blob", "wifi-reimpl", "all"]
  + extend run_wifi_blob_cell into a generic run_cell(name, catalog_entry, …)
    that takes the catalog test name as a parameter
  + def run_matrix(cells: list[str]) -> int: orchestrator for --cell all
  + main(): if args.cell == "all", call run_matrix; else call run_cell
  + EchoServer started before run_matrix or run_cell, stopped at end
  + env BL808_WIFI_E2E_HOST and BL808_WIFI_E2E_PORT injected into the
    hw_validate.py subprocess env
  ~ +120 lines net (the existing run_wifi_blob_cell is renamed/parameterized,
    not duplicated)

tools/hardware_validation.json
  ~ extend m0_wifi_e2e_test entry: add 2 defines (WifiEchoHost env=BL808_WIFI_E2E_HOST,
    WifiEchoPort env=BL808_WIFI_E2E_PORT)
  + new m0_wifi_e2e_test_reimpl entry: same source, same defines + bl808WifiNimFw=1
  ~ +18 lines

Makefile
  ~ extend hw-e2e-quick to default --cell to "all" instead of "wifi-blob"
  ~ +1 line
```

### Conventions

- Same as Iter 1: idiomatic Nim, no new linter, no new test framework. New TCP/DHCP code follows the existing `phaseMark(start)` → action → `phaseMark(ok|fail)` pattern.
- Python additions stay in the existing `tools/hw_e2e.py` module — no new files.
- Phase enum is still single-source-of-truth in Python; drift test catches desync.
- Build path is still `make m0` (via hw_validate.py's catalog-mode build).
- Anchor flash is still the canonical flash mechanism.
- Failure-bucket aggregation rule is unchanged (last-started-without-ok, explicit-fail-wins).

---

## 5. Staging within Iter 2.A

Three implementation passes. Each produces something testable.

### Pass 1 — lwIP investigation + DHCP only, blob backend

Lands:
- `tools/hw_e2e.py`: `EchoServer` class + `discover_lan_ip()`, but **not yet wired** into the run path. Just unit-tested.
- `examples/m0_wifi_e2e_test.nim`: import lwipcore, add `dhcp:start/ok/fail` markers and the netif-poll loop. **No TCP yet.**
- `tools/hardware_validation.json`: extend `m0_wifi_e2e_test` to add `WifiEchoHost`/`WifiEchoPort` defines (placeholder values; not used yet by firmware).
- Catalog `required` already includes `=== BL808 E2E Test Complete ===` from Iter 1.

Success: `make hw-e2e-quick UART_PORT=… WIFI_SSID=Frog WIFI_PASSWORD=…` runs the blob cell N=3, attempts now reach `dhcp:ok ip=… gw=…` (or `dhcp:fail` with a real reason). The "did the blob register the netif and pump lwIP" question is answered empirically.

If the netif-poll loop times out without an IP because the blob doesn't pump lwIP, the answer is in the failure bucket (`dhcp` with `reason=timeout`). The fix in that case is a small amount of lwIP-pump glue (likely a `bl_main_lwip_input(pkt)` call from a vendor-side hook, OR explicit `sysCheckTimeouts()` calls — to be determined by the bucket data).

This pass deliberately does NOT include TCP. The reason: if DHCP doesn't work, TCP can't work either, and we'd be debugging both at once.

### Pass 2 — TCP echo, blob backend

Lands:
- `examples/m0_wifi_e2e_test.nim`: add `tcp:start/ok/fail` markers + tcpNew/Connect/Write/Recv/Close + TcpState callbacks.
- `tools/hw_e2e.py`: wire EchoServer into the run path; pass `BL808_WIFI_E2E_HOST`/`PORT` via env to the hw_validate.py subprocess.
- Possibly: extend `src/bl808/kernel/lwipcore.nim` with any missing TCP wrappers (`tcpConnect`, `tcpWrite` if they're not exported yet).

Success: `make hw-e2e-quick` blob cell now reaches `tcp:ok bytes=16 rtt_ms=…`. EchoServer JSON report fields visible in summary.

### Pass 3 — Reimpl backend cell + matrix

Lands:
- `tools/hardware_validation.json`: new `m0_wifi_e2e_test_reimpl` entry (`bl808WifiNimFw=1`).
- `tools/hw_e2e.py`: `--cell` accepts `wifi-reimpl` and `all`. `run_matrix(cells)` runs both cells sequentially with a single shared EchoServer instance.
- `Makefile`: `hw-e2e-quick` defaults to `--cell all`.

Success: `make hw-e2e-quick` runs **both** cells N=3, prints a 2-cell summary table. Reimpl cell may fail consistently — that's still a valid landing, the failure bucket tells us where.

### Stop conditions for 2.A as a whole

Pass 1 and Pass 2 both complete (blob reaches dhcp:ok and tcp:ok at least once across N=3 attempts). Pass 3 produces a full 2-cell report regardless of reimpl success rate. The reimpl's actual hardening is then deferred to a later iteration.

---

## 6. Risks and unknowns

- **Blob may not have wired its netif into lwIP.** Pass 1 detects this empirically; the fix is a small amount of glue if needed.
- **Blob's WiFi RX path may not pump lwIP packets.** Same detection mechanism; if DHCP times out we know we need to add a packet-input hook from the vendor's RX.
- **`tcpConnect` / `tcpWrite` may not be exported in `lwipcore.nim`.** Discoverable at the first compile; ~5-20 lines of importc wrappers if missing.
- **Reimpl backend may fail at scan/auth (not just at DHCP/TCP).** Per project memory the reimpl is symbol-complete and audited but never run on hardware. The bucket data will isolate where it fails. Iter 2.A treats this as data collection, not a fix-it iteration.
- **LAN topology — board may not be able to route to the harness Mac.** If the board is on a different VLAN/subnet from the Mac, the TCP echo connect fails. Operator-side issue; the failure bucket (`tcp:fail reason=connect_failed`) makes it visible. Documented in `hw_e2e.py --help`.
- **EchoServer port collision.** Bind to `0:0` lets the kernel pick a free port; collision is impossible by design.
- **Multiple cells in `--cell all` may step on each other if firmware retains WiFi state across re-flash.** Each cell does its own anchor-flash, which fully replaces firmware. Should be clean.
