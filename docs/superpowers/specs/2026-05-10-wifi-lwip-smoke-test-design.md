# WiFi lwIP Smoke Test (DHCP + ICMP) — Design

**Date**: 2026-05-10
**Status**: Approved by user, ready for implementation planning
**Builds on**:
- `docs/superpowers/specs/2026-05-10-wifi-lwip-bringup-iter-2a0-redesign.md` — substrate (committed at HEAD `079bcce`)
- Original Iter 2.A.0 spec (`docs/superpowers/specs/2026-05-10-wifi-lwip-bridge-iter-2a0-design.md`) Section 1 — defined this same DHCP+ICMP smoke; deferred to this iteration.

---

## 1. Goal and success criteria

New `make hw-e2e-lwip-smoke` target. Per attempt: scan → auth → 4whs → assoc → **dhcp** → **icmp echo to gateway**. Reuses `e2e_runner` + `e2e_marker` from Iter 1. Validates the substrate from Iter 2.A.0 actually works on hardware.

**Concrete success criterion**:

```
m0_wifi_lwip_smoke (N=3 attempts)
  associate to Frog
  dhcp_start(netif), poll for IP-assigned, max 10s              → ip=… gw=…
  raw ICMP: send ECHO REQUEST to gw, await REPLY, max 3s        → reply with rtt_ms
  emit @e2e markers for each phase
```

**Pass for the soak**: at least 1 of 3 attempts completes the ICMP echo. Failures are bucketed per phase using the existing aggregator.

**Phase markers emitted (per attempt)**:
- `scan:start` / `scan:ok` / `scan:fail reason=…`
- `auth:start` / `auth:ok` / `auth:fail reason=…`
- `ph4whs:start/ok` (synthetic, same as Iter 1 pattern)
- `assoc:start/ok` (synthetic)
- `dhcp:start` / `dhcp:ok ip=… gw=…` / `dhcp:fail reason=no_netif|dhcp_start|timeout`
- `icmp:start dst=…` / `icmp:ok rtt_ms=… seq=…` / `icmp:fail reason=pcb_alloc|tx_failed|recv_timeout`
- `attempt:start/ok/fail` framing

**Out of scope**:
- TCP echo (the original Iter 2.A spec wanted this; out of scope until ICMP is proven first)
- WiFi reimpl backend cell (`bl808WifiNimFw=1`) — separate iteration
- BLE — separate iteration
- Hardening of the success rate (this is bring-up smoke; "1/3 succeeds" is enough)

**Predicted runtime behavior**: depends on whether the lwIP bridges + RX path actually deliver packets. This iteration is the empirical test of the substrate built in Iter 2.A.0.

---

## 2. The 3 commits in detail

### Commit 1 — `m0_wifi_lwip_smoke.nim` with DHCP phase

**Files**: Create `examples/m0_wifi_lwip_smoke.nim` (~110 lines)

Mirrors `examples/m0_wifi_e2e_test.nim` shape. Imports: `bl808/{startup,core,glb,gpio,uart,wifi,panicoverride,kernel/alloc,kernel/e2e_marker,kernel/e2e_runner}`. Optional `bl808/kernel/jtaglog` under `-d:bl808WifiVendor`.

Inline `{.importc.}` declarations for the lwIP symbols we touch in DHCP (Iter 1 pattern — avoids importing `lwipcore` which would re-compile vendor lwIP in this binary):

```nim
type
  Netif {.importc: "struct netif", header: "lwip/netif.h", incompleteStruct.} = object
  ErrT = int8
const ErrOk: ErrT = 0
proc dhcpStart(netif: ptr Netif): ErrT
  {.importc: "dhcp_start", header: "lwip/dhcp.h".}
proc sysCheckTimeouts()
  {.importc: "sys_check_timeouts", header: "lwip/timeouts.h".}
```

Two `{.emit:}` accessors for `netif->ip_addr.addr` and `netif->gw.addr`.

`runOneAttempt` walks: scan/auth/4whs/assoc (synthetic markers as in Iter 1), then real dhcp phase: `wifiGetNetif()` → cast → `dhcpStart` → poll for non-zero `ip_addr.addr` for 10 s with `sysCheckTimeouts()` per iteration, emit `dhcp:ok ip=… gw=…` or `dhcp:fail reason=…`.

`deinitForRetry` calls `wifiDisconnect`.

`main` does `systemInit`/`heapInit`/`setupConsole`/`hwValidationLogReset` (under WiFi vendor) then `e2eRun(AttemptsTotal, runOneAttempt, deinitForRetry)` then emits `=== BL808 LwIP Smoke Complete ===` sentinel for the catalog `required` matcher.

**Build verification**: `make m0 FILE=examples/m0_wifi_lwip_smoke.nim NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password>'` ends with `Output: build/m0_firmware.bin`.

**Commit message**: `Add m0_wifi_lwip_smoke.nim — DHCP phase only (Iter 2.A.0 follow-up step 1/3)`

---

### Commit 2 — Extend `m0_wifi_lwip_smoke.nim` with ICMP echo phase

**Files**: Modify `examples/m0_wifi_lwip_smoke.nim` (~+60 lines)

Add inline declarations for the lwIP raw API + pbuf:

```nim
type
  RawPcb {.importc: "struct raw_pcb", header: "lwip/raw.h", incompleteStruct.} = object
  Pbuf {.importc: "struct pbuf", header: "lwip/pbuf.h", incompleteStruct.} = object
  IpAddr {.importc: "ip4_addr_t", header: "lwip/ip4_addr.h".} = object
    address {.importc: "addr".}: uint32
  PbufLayer = distinct cint
  PbufType = distinct cint
  RawRecvFn = proc(arg: pointer, pcb: ptr RawPcb, p: ptr Pbuf,
                    addr: ptr IpAddr): uint8 {.cdecl.}
var pbufRaw {.importc: "PBUF_RAW", header: "lwip/pbuf.h", nodecl.}: PbufLayer
var pbufRam {.importc: "PBUF_RAM", header: "lwip/pbuf.h", nodecl.}: PbufType
proc rawNew(proto: uint8): ptr RawPcb {.importc: "raw_new", header: "lwip/raw.h".}
proc rawRecv(pcb: ptr RawPcb, recv: RawRecvFn, arg: pointer)
  {.importc: "raw_recv", header: "lwip/raw.h".}
proc rawSendto(pcb: ptr RawPcb, p: ptr Pbuf, dst: ptr IpAddr): ErrT
  {.importc: "raw_sendto", header: "lwip/raw.h".}
proc rawRemove(pcb: ptr RawPcb) {.importc: "raw_remove", header: "lwip/raw.h".}
proc pbufAlloc(layer: PbufLayer, length: uint16, kind: PbufType): ptr Pbuf
  {.importc: "pbuf_alloc", header: "lwip/pbuf.h".}
proc pbufFree(p: ptr Pbuf): uint8 {.importc: "pbuf_free", header: "lwip/pbuf.h".}
proc pbufTake(buf: ptr Pbuf, data: pointer, len: uint16): ErrT
  {.importc: "pbuf_take", header: "lwip/pbuf.h".}
proc pbufCopyPartial(p: ptr Pbuf, buf: pointer, len: uint16, offset: uint16): uint16
  {.importc: "pbuf_copy_partial", header: "lwip/pbuf.h".}
```

Add a small `IcmpState` module-global (`replied: bool`, `rttMs: uint32`, `seq: uint16`, `id: uint16`, `txTickMs: uint32`).

ICMP echo packet builder (8-byte ICMP header + 8-byte payload, total 16 bytes): type=8, code=0, identifier=`id`, sequence=`seq`, then 8 bytes of marker payload (e.g., the bytes `B`, `L`, `8`, `0`, `8`, `-`, `L`, `S`). Compute the RFC1071 checksum on the 16 bytes.

`recv_cb`: parse ICMP echo reply (type=0). Use `pbuf_copy_partial` to extract the 16-byte ICMP header+payload (raw recv on a raw_pcb registered with `IP_PROTO_ICMP` already strips the IP header per lwIP convention; verify against vendor `raw.c` during implementation). Validate identifier/sequence match against `IcmpState.{id, seq}` and validate the 8-byte payload matches what we sent. On match: set `replied=true`, compute `rttMs = readTickMs - txTickMs`, return 1 (callee consumed the pbuf; lwIP must not pass it on or re-free). On mismatch: return 0 (let lwIP free) — `IcmpState.replied` stays false, the polling loop hits `recv_timeout`. (Note: a payload-mismatch path could be distinguished by setting a separate state flag; for the smoke test the simpler `recv_timeout` bucket is sufficient.)

In `runOneAttempt`, after `dhcp:ok`:
```
phaseMark(Phase.icmp, Kind.start, kvWrite("dst", gw4))
state.id = (rand uint16 from cycle counter)
state.seq = 1
state.txTickMs = readTickMs()
pcb = rawNew(IP_PROTO_ICMP=1)
if pcb == nil: → icmp:fail reason=pcb_alloc; return false
rawRecv(pcb, recv_cb, addr state)
build pbuf with 16-byte ICMP echo request
gw_addr.address = gw4
rc = rawSendto(pcb, p, addr gw_addr)
pbufFree(p)  # rawSendto copies; we free our copy
if rc != ErrOk: → icmp:fail reason=tx_failed; rawRemove; return false
poll state.replied for up to 3s with sysCheckTimeouts() every 50ms
rawRemove(pcb)
if not state.replied: → icmp:fail reason=recv_timeout; return false
phaseMark(Phase.icmp, Kind.ok, kvWrite("rtt_ms", state.rttMs), kvWrite("seq", state.seq))
return true
```

**Build verification**: same `make m0` command — succeeds.

**Commit message**: `m0_wifi_lwip_smoke: add ICMP echo phase (Iter 2.A.0 follow-up step 2/3)`

---

### Commit 3 — Catalog entry + hw_e2e cell + Makefile target

**Files**: Modify `tools/hardware_validation.json`, `tools/hw_e2e.py`, `Makefile`

**3a) `tools/hardware_validation.json`**: Add new test entry `m0_wifi_lwip_smoke`:
```json
{
  "name": "m0_wifi_lwip_smoke",
  "tiers": ["e2e"],
  "build": [{
    "id": "kernel",
    "core": "bl808m0",
    "source": "examples/m0_wifi_lwip_smoke.nim",
    "flash": "m0",
    "defines": {
      "bl808WifiVendor": "1",
      "WifiSsid": {"env": "BL808_WIFI_SSID"},
      "WifiPassword": {"secret_env": "BL808_WIFI_PASSWORD"},
      "AttemptsTotal": {"env": "BL808_WIFI_E2E_ATTEMPTS", "default": 3}
    }
  }],
  "required": ["=== BL808 LwIP Smoke Complete ==="],
  "timeout": 240
}
```

**3b) `tools/hw_e2e.py`**: Add `wifi-lwip-smoke` to `--cell` choices. Add `run_wifi_lwip_smoke_cell` function mirroring `run_wifi_blob_cell` (subprocess hw_validate.py with `--test m0_wifi_lwip_smoke`, parse log, summarize, JSON). Update `main()` dispatch.

**3c) `Makefile`**: Add `hw-e2e-lwip-smoke` target with credentials guard (mirrors `hw-e2e-quick`):
```makefile
hw-e2e-lwip-smoke: venv
	@test -n "$(WIFI_SSID)" || (echo "Error: WIFI_SSID is required (e.g. WIFI_SSID=Frog)"; exit 1)
	@test -n "$(WIFI_PASSWORD)" || (echo "Error: WIFI_PASSWORD is required"; exit 1)
	$(PYTHON) tools/hw_e2e.py --cell wifi-lwip-smoke --uart $(UART_PORT) --uart-baud $(UART_BAUD) --ssid $(WIFI_SSID) --password $(WIFI_PASSWORD) --attempts 3
```

Plus add to the `.PHONY:` line and a help line.

**Build verification**:
- `python -c "import json; json.load(open('tools/hardware_validation.json'))"` — JSON parses
- `.venv/bin/pytest tools/test_hw_e2e.py -v` — 3/3 still pass
- `make -n hw-e2e-lwip-smoke WIFI_SSID=test WIFI_PASSWORD=test` — resolves cleanly

**Commit message**: `harness: wire wifi-lwip-smoke cell + catalog + Makefile target (Iter 2.A.0 follow-up step 3/3)`

---

## 3. File and module layout

### New files

```
examples/m0_wifi_lwip_smoke.nim          ~170 lines after Commit 2
  Single binary; mirrors examples/m0_wifi_e2e_test.nim shape.
  Inline {.importc.} for dhcp_start, sysCheckTimeouts (Commit 1).
  Inline {.importc.} for raw_*, pbuf_* (Commit 2).
  {.emit:} accessors for netif->ip_addr.addr / gw.addr.
```

### Modified files

```
tools/hardware_validation.json           ~+15 lines (new test entry)
tools/hw_e2e.py                          ~+30 lines (new cell mode + dispatch)
Makefile                                 ~+5 lines (new target + .PHONY + help)
```

### Files NOT touched

- `src/bl808/wifi.nim`, `src/bl808/wifi_vendor_support.c`, `src/bl808/kernel/lwipcore.nim` — Iter 2.A.0 substrate is done; smoke test consumes it via inline importcs
- `src/bl808/kernel/e2e_marker.nim` / `e2e_runner.nim` — substrate already has `Phase.icmp` from Iter 2.A.0 step 2
- `src/bl808/kernel/baremetal_libc.c` — `_ctype_` already there
- `tools/e2e_phases.py`, generator, pytest tests — no changes
- Other examples or test binaries — no changes

### Conventions

- Same as Iter 1: idiomatic Nim, no new linter, no new test framework. Test follows `m0_wifi_e2e_test.nim` shape.
- Inline-importc pattern (rather than `import bl808/kernel/lwipcore`) keeps the test binary's compile surface minimal — it doesn't trigger the vendor lwIP recompilation that already happens via `wifi.nim`'s vendor block.
- Marker grammar unchanged. The aggregator already handles all phases.

---

## 4. Order of operations and risks

### Strict sequence

```
START at HEAD = 079bcce (Iter 2.A.0 substrate complete; build verified)

1. Apply Commit 1 (smoke binary with DHCP phase only)
   → Build verify: make m0 FILE=examples/m0_wifi_lwip_smoke.nim NIM='...'
     ends with "Output: build/m0_firmware.bin"
   → If pass: commit. If fail: discard with `git checkout HEAD -- examples/m0_wifi_lwip_smoke.nim`,
     surface with build error tail. NEVER `git reset --hard`.

2. Apply Commit 2 (extend with ICMP phase)
   → Build verify: same command → success
   → If pass: commit. If fail: discard the extension only.

3. Apply Commit 3 (catalog + cell + Makefile)
   → Three sub-verifications:
     a) python -c "import json; json.load(open('tools/hardware_validation.json'))" — JSON parses
     b) .venv/bin/pytest tools/test_hw_e2e.py -v — 3/3 still pass
     c) make -n hw-e2e-lwip-smoke WIFI_SSID=test WIFI_PASSWORD=test — resolves
   → If pass: commit. If fail: identify which file broke, discard with checkout HEAD --.

4. Hardware run (no commit unless fixes needed)
   → make hw-e2e-lwip-smoke UART_PORT=/dev/tty.usbserial-TGKWL2RS WIFI_SSID=Frog WIFI_PASSWORD=<wifi-password>
   → Bucket the 3 attempts by phase
   → If at least 1/3 reaches icmp:ok: substrate validated, iteration done
   → If all 3 fail at the same phase: real bug; surface with marker stream for triage
```

After each commit: `git status --short | grep '^ M'` shows 0 unstaged-modified files.

### Risks

- **Commit 1**: low. Mirrors the already-working `m0_wifi_e2e_test.nim` pattern. Worst case: a typo in the inline declarations → easy to spot.

- **Commit 2**: medium. The ICMP packet builder + RFC1071 checksum is hand-written; off-by-one or endianness mistake possible. The pbuf ownership convention for `raw_sendto` (does it copy or take ownership?) is something to verify in vendor lwIP `raw.c` before assuming. If the build fails because `raw_*` symbols don't resolve, vendor `raw.c` may not be in lwipcore's `{.compile:}` list — discoverable at link time.

- **Commit 3**: low. Mechanical: JSON + Nim Python + Makefile entry. Mirrors existing `wifi-blob` cell.

- **Hardware run**: HIGH uncertainty for the smoke itself (this is the empirical test), LOW risk for the rest of the codebase (regression-safe because we only added new files / new entries; existing behavior unchanged). The diagnostic outcomes are mapped to specific failure buckets:
  - `dhcp:fail reason=no_netif` → `wifiGetNetif()` returned nil; investigate WiFi association
  - `dhcp:fail reason=dhcp_start` + non-zero `rc` → `dhcp_start` returned an error; likely netif not in UP state or lwIP heap too small
  - `dhcp:fail reason=timeout` → DISCOVER sent but no OFFER; either TX bridge issue OR RX bridge dropped the OFFER pbuf
  - `icmp:fail reason=tx_failed` → `rawSendto` failed; likely netif not reachable
  - `icmp:fail reason=recv_timeout` → no ECHO REPLY in 3s; either gateway didn't reply, or our RX bridge handles ICMP differently than the DHCP UDP that worked

### What gets reverted on failure

Per-task: `git checkout HEAD -- <files>` to discard working-tree edits. **Never `git reset --hard`**.

Hardware-run failures don't trigger reverts — they trigger investigation. The substrate is intact regardless of whether the smoke succeeds; the worst case is "we discover the substrate has a bug we missed in Iter 2.A.0" and we file a separate fix iteration.

### State at the end

```
HEAD = 079bcce + 3 new commits
... (Iter 2.A.0: 5 commits)
079bcce  wifi_vendor_support: complete tcpip_input bridge + lwipcore clock import
+ 1: Add m0_wifi_lwip_smoke.nim — DHCP phase only (Iter 2.A.0 follow-up step 1/3)
+ 2: m0_wifi_lwip_smoke: add ICMP echo phase (Iter 2.A.0 follow-up step 2/3)
+ 3: harness: wire wifi-lwip-smoke cell + catalog + Makefile target (Iter 2.A.0 follow-up step 3/3)
```

Plus a hardware-run report in conversation; possibly a baseline-rate file under `build/hw-e2e/...`.

### Stop conditions

- Each commit succeeds with verification.
- Hardware run is deterministic-or-explicable: either at least 1/3 succeeds (good), or all 3 fail at the same explainable phase (filable bug).
