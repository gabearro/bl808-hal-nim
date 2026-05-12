# WiFi lwIP Smoke Test (DHCP + ICMP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `m0_wifi_lwip_smoke` end-to-end soak (scan → assoc → DHCP → ICMP echo) that empirically validates the lwIP substrate built in Iter 2.A.0.

**Architecture:** One new firmware binary (`examples/m0_wifi_lwip_smoke.nim`) reuses the Iter-1 `e2e_runner` + `e2e_marker` framework and emits structured `@e2e <phase>:<kind>` markers. The binary uses inline `{.importc.}` declarations for the lwIP symbols it needs (the lwIP include path and compiled C objects are already wired via `wifi.nim` → `kernel/lwipcore.nim`). The Python harness gets a new `wifi-lwip-smoke` cell mode in `tools/hw_e2e.py`, a catalog entry in `tools/hardware_validation.json`, and a `make hw-e2e-lwip-smoke` target.

**Tech Stack:** Nim 1.6+ bare-metal (`-d:bl808kernel -d:bl808WifiVendor`), vendor lwIP (NO_SYS=1) raw API, M0 (E907 RV32IMAFC), Python 3 + pytest for harness, OpenOCD + UART for hardware execution.

**Spec:** `docs/superpowers/specs/2026-05-10-wifi-lwip-smoke-test-design.md` (committed at `a1faebc`).

**Starting point:** `master` at `a1faebc` (Iter 2.A.0 substrate is at `079bcce`; the spec commit is on top of it). All prior tracked-but-modified files (`config.nims`, `Makefile`, etc.) must remain untouched by this iteration unless explicitly modified by a step below.

---

## Scope check

Single iteration, three commits, one new firmware binary, three small file edits in tooling. No decomposition needed.

## File structure

| File | Status | Responsibility |
|------|--------|---------------|
| `examples/m0_wifi_lwip_smoke.nim` | **create** | Single-binary smoke test: WiFi connect → DHCP → ICMP echo. Inline `{.importc.}` for lwIP symbols. ~170 lines after Task 2. |
| `tools/hardware_validation.json` | modify | Add `m0_wifi_lwip_smoke` catalog entry (~15 lines). |
| `tools/hw_e2e.py` | modify | Add `wifi-lwip-smoke` choice, `run_wifi_lwip_smoke_cell()`, dispatch in `main()` (~30 lines). |
| `Makefile` | modify | Add `hw-e2e-lwip-smoke` target, `.PHONY`, help line (~6 lines). |

**Files NOT touched (leave alone):**
- `src/bl808/wifi.nim`, `src/bl808/wifi_vendor_support.c`, `src/bl808/kernel/lwipcore.nim`, `src/bl808/kernel/baremetal_libc.c` — substrate from Iter 2.A.0 is intact.
- `src/bl808/kernel/e2e_marker.nim`, `src/bl808/kernel/e2e_runner.nim` — already include `Phase.dhcp` and `Phase.icmp`.
- `tools/e2e_phases.py`, `tools/gen_e2e_marker_nim.py`, `tools/test_hw_e2e.py` — no changes.
- All other `examples/*.nim`, `src/**`, and any other tracked file in the repo.

**Key API references (already exist; do not redefine):**
- `wifiInit() -> WifiError` — `src/bl808/wifi.nim:471`
- `wifiConnect(ssid, password, channel)` — `src/bl808/wifi.nim:480`
- `wifiDisconnect() -> WifiError` — `src/bl808/wifi.nim:496`
- `wifiGetNetif(): pointer` — `src/bl808/wifi.nim:524` (returns lwIP netif as untyped pointer; cast to `ptr Netif`)
- `kernel_read_tick_ms(): uint64` — `src/bl808/kernel/clock.nim:165` (millisecond tick counter)
- `Phase.dhcp`, `Phase.icmp`, `Phase.scan`, `Phase.auth`, `Phase.ph4whs`, `Phase.assoc`, `Phase.attempt` — `src/bl808/kernel/e2e_marker.nim`
- `phaseMark(phase, kind, kvBlock)`, `kvWrite(key, value)` — same module; `kvWrite` accepts `string`, `SomeUnsignedInt`, or `SomeSignedInt`
- `e2eRun(totalAttempts, runOne, deinitForRetry)` — `src/bl808/kernel/e2e_runner.nim`
- `e2eMarkerInit(addr console)` — must be called once before `e2eRun`

**Build verification command (used after every Task 1 / Task 2 step):**
```bash
make m0 FILE=examples/m0_wifi_lwip_smoke.nim \
  NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password>'
```
Expected last line: `Output: build/m0_firmware.bin`

**Critical safety rule:** If a build fails, discard with `git checkout HEAD -- <file>`. **Never** use `git reset --hard`. Investigate the build error and re-attempt; do not bypass with workarounds.

---

## Task 1: DHCP-only smoke binary

**Files:**
- Create: `examples/m0_wifi_lwip_smoke.nim`

This task creates the binary with the synthetic scan/auth/4whs/assoc markers (matching the Iter-1 pattern) plus a real DHCP phase. ICMP is added in Task 2. The binary's `runOneAttempt` returns `true` after `dhcp:ok` is emitted.

- [ ] **Step 1: Create the binary file with full content**

Create `examples/m0_wifi_lwip_smoke.nim` with the following contents:

```nim
## M0 WiFi lwIP smoke test (Iter 2.A.0 follow-up).
##
## Build with:
##   make m0 FILE=examples/m0_wifi_lwip_smoke.nim \
##     NIM="nim -d:bl808kernel -d:bl808WifiVendor \
##              -d:WifiSsid=Frog -d:WifiPassword=<wifi-password>"
##
## Per attempt: scan -> auth -> 4whs -> assoc (synthetic) -> DHCP.
## ICMP echo phase is added in the next commit.
##
## Pass for the soak (after Task 2): >=1 of N attempts reaches icmp:ok.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/wifi
import bl808/panicoverride
import bl808/kernel/alloc
import bl808/kernel/clock
import bl808/kernel/e2e_marker
import bl808/kernel/e2e_runner
when defined(bl808WifiVendor):
  import bl808/kernel/jtaglog

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  WifiSsid {.strdefine.} = ""
  WifiPassword {.strdefine.} = ""
  WifiChannel {.intdefine.} = 0
  AttemptsTotal {.intdefine.} = 3
  DhcpTimeoutMs = 10_000'u32

# --- Inline lwIP bindings ---
# The `lwip/*.h` include path comes from kernel/lwipcore.nim's passC, which
# is pulled in transitively by `import bl808/wifi` under `-d:bl808WifiVendor`.
# Vendor lwIP C objects (raw.c, dhcp.c, timeouts.c, ...) are also compiled
# via lwipcore. We declare only the symbols this binary needs.
type
  Netif {.importc: "struct netif", header: "lwip/netif.h", incompleteStruct.} = object
  ErrT* = int8
const ErrOk*: ErrT = 0

proc dhcpStart(netif: ptr Netif): ErrT
  {.importc: "dhcp_start", header: "lwip/dhcp.h".}
proc sysCheckTimeouts()
  {.importc: "sys_check_timeouts", header: "lwip/timeouts.h".}

# IPv4 field accessors. The netif struct has nested ip_addr_t fields whose
# layout is version-sensitive; an {.emit:} block sidesteps the binding question.
proc netifIp4(netif: ptr Netif): uint32 =
  var v: uint32 = 0
  {.emit: "`v` = ((struct netif*)`netif`)->ip_addr.addr;".}
  v

proc netifGw4(netif: ptr Netif): uint32 =
  var v: uint32 = 0
  {.emit: "`v` = ((struct netif*)`netif`)->gw.addr;".}
  v

proc nowMs(): uint32 {.inline.} =
  (kernel_read_tick_ms() and 0xffffffff'u64).uint32

var console: Uart

proc setupConsole() =
  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

proc runOneAttempt(): bool {.nimcall.} =
  # Synthetic markers up through assoc (Iter 1 pattern: vendor blob's
  # wifiConnect collapses scan/auth/4whs/assoc into a single call).
  phaseMark(Phase.scan, Kind.start)
  let initRc = wifiInit()
  if initRc != wifiOk:
    phaseMark(Phase.scan, Kind.fail):
      kvWrite("reason", "init_failed")
    return false
  phaseMark(Phase.scan, Kind.ok)

  phaseMark(Phase.auth, Kind.start)
  let connectRc = wifiConnect(WifiSsid, WifiPassword, WifiChannel.uint8)
  if connectRc != wifiOk:
    phaseMark(Phase.auth, Kind.fail):
      kvWrite("reason", "connect_failed")
    return false
  phaseMark(Phase.auth, Kind.ok)
  phaseMark(Phase.ph4whs, Kind.start)
  phaseMark(Phase.ph4whs, Kind.ok)
  phaseMark(Phase.assoc, Kind.start)
  phaseMark(Phase.assoc, Kind.ok)

  # DHCP.
  phaseMark(Phase.dhcp, Kind.start)
  let netifRaw = wifiGetNetif()
  if netifRaw == nil:
    phaseMark(Phase.dhcp, Kind.fail):
      kvWrite("reason", "no_netif")
    return false
  let netif = cast[ptr Netif](netifRaw)
  let dhcpRc = dhcpStart(netif)
  if dhcpRc != ErrOk:
    phaseMark(Phase.dhcp, Kind.fail):
      kvWrite("reason", "dhcp_start")
      kvWrite("rc", dhcpRc.int32)
    return false
  let dhcpDeadline = nowMs() + DhcpTimeoutMs
  while netifIp4(netif) == 0:
    sysCheckTimeouts()
    if nowMs() >= dhcpDeadline:
      phaseMark(Phase.dhcp, Kind.fail):
        kvWrite("reason", "timeout")
      return false
  let ip4 = netifIp4(netif)
  let gw4 = netifGw4(netif)
  phaseMark(Phase.dhcp, Kind.ok):
    kvWrite("ip", ip4)
    kvWrite("gw", gw4)
  return true

proc deinitForRetry() {.nimcall.} =
  discard wifiDisconnect()

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  setupConsole()
  when defined(bl808WifiVendor):
    hwValidationLogReset()
  e2eMarkerInit(addr console)
  discard console.sendLine("")
  discard console.sendLine("=== BL808 WiFi LwIP Smoke Test ===")
  e2eRun(AttemptsTotal, runOneAttempt, deinitForRetry)
  discard console.sendLine("=== BL808 LwIP Smoke Complete ===")

main()
```

- [ ] **Step 2: Build to verify the binary compiles and links**

Run:
```bash
make m0 FILE=examples/m0_wifi_lwip_smoke.nim \
  NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password>'
```

Expected: command succeeds (exit 0); the last line of output is `Output: build/m0_firmware.bin`.

If the build fails:
- If a Nim error mentions an undefined `kernel_read_tick_ms`, double-check that `import bl808/kernel/clock` is present in the imports section.
- If a C error mentions a missing `lwip/dhcp.h` header, double-check that `bl808WifiVendor` is defined on the command line — without it, `wifi.nim` does not import `lwipcore` and the include path is missing.
- If a linker error mentions undefined `dhcp_start` or `sys_check_timeouts`, this means `lwipcore.nim`'s `{.compile:}` directives didn't run; verify `bl808WifiVendor` is set.
- Do **not** modify `wifi.nim`, `lwipcore.nim`, or `wifi_vendor_support.c` to make the build pass — those are part of the substrate. Discard the new binary with `git checkout HEAD -- examples/m0_wifi_lwip_smoke.nim` and report the error tail.

- [ ] **Step 3: Verify no other tracked files were modified**

Run:
```bash
git status --short
```

Expected: the only line under `??` for this iteration is `examples/m0_wifi_lwip_smoke.nim` (other untracked files from prior sessions are fine — they're outside this task's scope). No `^ M` lines for files this task didn't author.

If a file outside `examples/m0_wifi_lwip_smoke.nim` shows as modified, discard it with `git checkout HEAD -- <file>` before committing.

- [ ] **Step 4: Commit**

```bash
git add examples/m0_wifi_lwip_smoke.nim
git commit -m "$(cat <<'EOF'
Add m0_wifi_lwip_smoke.nim — DHCP phase only

Iter 2.A.0 follow-up step 1/3. New binary mirrors m0_wifi_e2e_test.nim
shape (e2e_runner + e2e_marker scaffolding) but extends past assoc with
a real DHCP phase: cast wifiGetNetif() result, call dhcp_start, poll
ip_addr.addr for up to 10 s with sys_check_timeouts driving lwIP.
Emits dhcp:ok ip=… gw=… on success, dhcp:fail reason=no_netif|dhcp_start|
timeout on the three failure modes. ICMP echo phase lands in step 2/3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: ICMP echo phase

**Files:**
- Modify: `examples/m0_wifi_lwip_smoke.nim`

This task extends `runOneAttempt` to send an ICMP echo request to the gateway after DHCP succeeds and waits for a reply (max 3 s). The 16-byte ICMP packet (8-byte header + 8-byte payload) is constructed in-place with an RFC 1071 1's-complement checksum.

- [ ] **Step 1: Add ICMP imports and types after the existing inline lwIP block**

Open `examples/m0_wifi_lwip_smoke.nim`. Find the line:
```nim
proc nowMs(): uint32 {.inline.} =
  (kernel_read_tick_ms() and 0xffffffff'u64).uint32
```

Immediately **after** that block (i.e., before `var console: Uart`), insert:

```nim
# --- ICMP echo bindings (raw API + pbuf) ---
type
  RawPcb {.importc: "struct raw_pcb", header: "lwip/raw.h", incompleteStruct.} = object
  Pbuf {.importc: "struct pbuf", header: "lwip/pbuf.h", incompleteStruct.} = object
  IpAddr {.importc: "ip4_addr_t", header: "lwip/ip4_addr.h".} = object
    address {.importc: "addr".}: uint32
  PbufLayer = distinct cint
  PbufType = distinct cint
  RawRecvFn = proc(arg: pointer, pcb: ptr RawPcb, p: ptr Pbuf,
                   address: ptr IpAddr): uint8 {.cdecl.}

var pbufRaw {.importc: "PBUF_RAW", header: "lwip/pbuf.h", nodecl.}: PbufLayer
var pbufRam {.importc: "PBUF_RAM", header: "lwip/pbuf.h", nodecl.}: PbufType

proc rawNew(proto: uint8): ptr RawPcb
  {.importc: "raw_new", header: "lwip/raw.h".}
proc rawRecv(pcb: ptr RawPcb, recv: RawRecvFn, arg: pointer)
  {.importc: "raw_recv", header: "lwip/raw.h".}
proc rawSendto(pcb: ptr RawPcb, p: ptr Pbuf, dst: ptr IpAddr): ErrT
  {.importc: "raw_sendto", header: "lwip/raw.h".}
proc rawRemove(pcb: ptr RawPcb)
  {.importc: "raw_remove", header: "lwip/raw.h".}
proc pbufAlloc(layer: PbufLayer, length: uint16, kind: PbufType): ptr Pbuf
  {.importc: "pbuf_alloc", header: "lwip/pbuf.h".}
proc pbufFree(p: ptr Pbuf): uint8
  {.importc: "pbuf_free", header: "lwip/pbuf.h".}
proc pbufTake(buf: ptr Pbuf, data: pointer, len: uint16): ErrT
  {.importc: "pbuf_take", header: "lwip/pbuf.h".}
proc pbufCopyPartial(p: ptr Pbuf, buf: pointer, len: uint16, offset: uint16): uint16
  {.importc: "pbuf_copy_partial", header: "lwip/pbuf.h".}

# pbuf field accessors (avoid binding the full struct).
proc pbufTotLen(p: ptr Pbuf): uint16 =
  var v: uint16 = 0
  {.emit: "`v` = ((struct pbuf*)`p`)->tot_len;".}
  v

const
  IpProtoIcmp = 1'u8
  IcmpEchoRequest = 8'u8
  IcmpEchoReply = 0'u8
  IcmpTimeoutMs = 3_000'u32
  IcmpPacketBytes = 16'u16  # 8-byte ICMP header + 8-byte payload
  IcmpPayload: array[8, uint8] = [byte 'B', 'L', '8', '0', '8', '-', 'L', 'S']

type
  IcmpEcho = object
    icmpType: uint8
    code: uint8
    checksum: uint16   # network byte order on the wire
    identifier: uint16 # network byte order on the wire
    sequence: uint16   # network byte order on the wire
    payload: array[8, uint8]
  IcmpState = object
    replied: bool
    rttMs: uint32
    seq: uint16        # host byte order, what we sent
    ident: uint16      # host byte order, what we sent
    txTickMs: uint32

var icmpState: IcmpState

proc htons(v: uint16): uint16 {.inline.} =
  ((v shl 8) and 0xff00'u16) or ((v shr 8) and 0x00ff'u16)

proc inetChecksum(buf: ptr UncheckedArray[uint8], len: int): uint16 =
  ## RFC 1071 1's-complement checksum on a buffer (assumed even-length here).
  var sum: uint32 = 0
  var i = 0
  while i + 1 < len:
    let word = (uint32(buf[i]) shl 8) or uint32(buf[i+1])
    sum += word
    i += 2
  if i < len:
    sum += (uint32(buf[i]) shl 8)
  while (sum shr 16) != 0:
    sum = (sum and 0xffff'u32) + (sum shr 16)
  result = uint16((not sum) and 0xffff'u32)

proc icmpRecvCb(arg: pointer, pcb: ptr RawPcb, p: ptr Pbuf,
                address: ptr IpAddr): uint8 {.cdecl.} =
  ## Raw recv callback. lwIP delivers the packet with the IPv4 header still
  ## attached (LWIP_RAW=1 default). Skip past it via the IHL nibble.
  let totalLen = pbufTotLen(p)
  if totalLen < 20'u16 + 8'u16:
    return 0
  var ipByte0: uint8
  discard pbufCopyPartial(p, addr ipByte0, 1'u16, 0'u16)
  let ihlBytes = uint16(ipByte0 and 0x0f) * 4'u16
  if ihlBytes < 20'u16 or totalLen < ihlBytes + 8'u16:
    return 0
  var icmp: IcmpEcho
  discard pbufCopyPartial(p, addr icmp, sizeof(IcmpEcho).uint16, ihlBytes)
  if icmp.icmpType != IcmpEchoReply:
    return 0
  if htons(icmp.identifier) != icmpState.ident:
    return 0
  if htons(icmp.sequence) != icmpState.seq:
    return 0
  for k in 0 ..< 8:
    if icmp.payload[k] != IcmpPayload[k]:
      return 0
  icmpState.rttMs = nowMs() - icmpState.txTickMs
  icmpState.replied = true
  discard pbufFree(p)
  return 1
```

- [ ] **Step 2: Extend runOneAttempt with the ICMP phase**

In `examples/m0_wifi_lwip_smoke.nim`, find the end of the DHCP phase in `runOneAttempt`:

```nim
  let ip4 = netifIp4(netif)
  let gw4 = netifGw4(netif)
  phaseMark(Phase.dhcp, Kind.ok):
    kvWrite("ip", ip4)
    kvWrite("gw", gw4)
  return true
```

Replace the `return true` at the end with the ICMP phase block, so the tail of `runOneAttempt` reads:

```nim
  let ip4 = netifIp4(netif)
  let gw4 = netifGw4(netif)
  phaseMark(Phase.dhcp, Kind.ok):
    kvWrite("ip", ip4)
    kvWrite("gw", gw4)

  # ICMP echo to gateway.
  phaseMark(Phase.icmp, Kind.start):
    kvWrite("dst", gw4)
  icmpState.replied = false
  icmpState.ident = ((nowMs() and 0xffff'u32) or 1'u32).uint16
  icmpState.seq = 1'u16
  icmpState.txTickMs = nowMs()

  let pcb = rawNew(IpProtoIcmp)
  if pcb == nil:
    phaseMark(Phase.icmp, Kind.fail):
      kvWrite("reason", "pcb_alloc")
    return false
  rawRecv(pcb, icmpRecvCb, addr icmpState)

  var req: IcmpEcho
  req.icmpType = IcmpEchoRequest
  req.code = 0
  req.identifier = htons(icmpState.ident)
  req.sequence = htons(icmpState.seq)
  for i in 0 ..< 8:
    req.payload[i] = IcmpPayload[i]
  req.checksum = 0
  let arr = cast[ptr UncheckedArray[uint8]](addr req)
  req.checksum = htons(inetChecksum(arr, sizeof(IcmpEcho)))

  let pbuf = pbufAlloc(pbufRaw, IcmpPacketBytes, pbufRam)
  if pbuf == nil:
    rawRemove(pcb)
    phaseMark(Phase.icmp, Kind.fail):
      kvWrite("reason", "tx_failed")
    return false
  discard pbufTake(pbuf, addr req, IcmpPacketBytes)
  var dstAddr: IpAddr
  dstAddr.address = gw4
  let txRc = rawSendto(pcb, pbuf, addr dstAddr)
  discard pbufFree(pbuf)
  if txRc != ErrOk:
    rawRemove(pcb)
    phaseMark(Phase.icmp, Kind.fail):
      kvWrite("reason", "tx_failed")
      kvWrite("rc", txRc.int32)
    return false

  let icmpDeadline = nowMs() + IcmpTimeoutMs
  while not icmpState.replied:
    sysCheckTimeouts()
    if nowMs() >= icmpDeadline:
      rawRemove(pcb)
      phaseMark(Phase.icmp, Kind.fail):
        kvWrite("reason", "recv_timeout")
      return false
  rawRemove(pcb)
  phaseMark(Phase.icmp, Kind.ok):
    kvWrite("rtt_ms", icmpState.rttMs)
    kvWrite("seq", icmpState.seq)
  return true
```

- [ ] **Step 3: Build to verify the extended binary compiles and links**

Run:
```bash
make m0 FILE=examples/m0_wifi_lwip_smoke.nim \
  NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password>'
```

Expected: command succeeds (exit 0); the last line of output is `Output: build/m0_firmware.bin`.

If the build fails:
- Linker error on `raw_new` / `raw_recv` / `raw_sendto` / `raw_remove`: vendor `raw.c` is in `lwipcore.nim`'s `{.compile:}` list (line 34), so this should not occur. If it does, verify `bl808WifiVendor` is set on the command line.
- C error on `struct pbuf`'s `tot_len` field name: this is a stable lwIP field; if it errors, double-check the spelling in the `{.emit:}` block.
- Nim error on `kvWrite("rc", txRc.int32)`: `txRc` is `ErrT` (= `int8`); the `.int32` cast is needed because `kvWrite` only handles `string`/`SomeUnsignedInt`/`SomeSignedInt` — the `int8` is a signed int but `sendHex32` expects 32 bits, so cast first. This is already in the code above; do not change.
- Do **not** modify `lwipcore.nim` to add new exports — the binary must use only its inline declarations.
- If the build cannot be made to succeed, discard with `git checkout HEAD -- examples/m0_wifi_lwip_smoke.nim` (this reverts to the post-Task-1 state) and report the error tail.

- [ ] **Step 4: Verify no unrelated files were modified**

Run:
```bash
git status --short
```

Expected: a single ` M examples/m0_wifi_lwip_smoke.nim` line (plus pre-existing untracked entries from prior sessions). No other files showing as modified.

- [ ] **Step 5: Commit**

```bash
git add examples/m0_wifi_lwip_smoke.nim
git commit -m "$(cat <<'EOF'
m0_wifi_lwip_smoke: add ICMP echo phase

Iter 2.A.0 follow-up step 2/3. After dhcp:ok, build a 16-byte ICMP echo
request (8-byte header + 8-byte 'BL808-LS' payload) with an RFC 1071
checksum, send via lwIP raw API to the DHCP-supplied gateway, and poll
sys_check_timeouts for up to 3 s waiting for an echo reply with matching
identifier/sequence/payload. Emits icmp:ok rtt_ms=… seq=… on success;
icmp:fail reason=pcb_alloc|tx_failed|recv_timeout otherwise.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Catalog entry, hw_e2e cell, Makefile target

**Files:**
- Modify: `tools/hardware_validation.json` (add catalog entry)
- Modify: `tools/hw_e2e.py` (add cell choice + dispatch)
- Modify: `Makefile` (add target + .PHONY + help)

This task wires the new binary into the existing harness. There's no firmware code change; everything is mechanical configuration.

- [ ] **Step 1: Add the catalog entry to `tools/hardware_validation.json`**

Open `tools/hardware_validation.json`. Find the existing `m0_wifi_e2e_test` entry (it begins with `      "name": "m0_wifi_e2e_test",` near the end of the `"tests": [` array). The entry's closing `}` is followed by a `]` and `}` that close the array and root object.

Insert a new entry **after** the `m0_wifi_e2e_test` entry's closing `}`. To do this:

1. Locate the existing entry's terminator (the `}` before the `]` that closes the `tests` array).
2. Replace `}\n  ]` with `},\n    {NEW_ENTRY_HERE}\n  ]` so the new entry slots in as the last array element.

The new entry to add (this is the JSON to insert as a sibling object inside `"tests": [...]`):

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

Make sure:
- A comma is added after the previous entry's closing `}` (otherwise the JSON is invalid).
- No trailing comma after the new entry's closing `}` (it's now the last array element).
- Indentation matches the existing entries (4-space at the entry level).

- [ ] **Step 2: Verify the catalog JSON parses**

Run:
```bash
python -c "import json, sys; d = json.load(open('tools/hardware_validation.json')); names = [t['name'] for t in d['tests']]; assert 'm0_wifi_lwip_smoke' in names, names; print('OK,', len(names), 'tests')"
```

Expected: `OK, <N> tests` where `<N>` is one greater than before.

If JSON parse fails:
- The error will identify a line/column. Common causes: missing comma after previous entry, extra trailing comma after new entry, mismatched braces.
- Discard with `git checkout HEAD -- tools/hardware_validation.json` and re-do Step 1 carefully.

- [ ] **Step 3: Extend `tools/hw_e2e.py` with the new cell**

Open `tools/hw_e2e.py`.

(a) Find the `run_wifi_blob_cell` function (starts around `def run_wifi_blob_cell(`). Immediately **after** the closing of that function (i.e., just before `class EchoServer:`), add a new function:

```python
def run_wifi_lwip_smoke_cell(
    *, uart_port: str, uart_baud: int, ssid: str, password: str,
    attempts: int, build_dir: Path,
) -> CellReport:
    """WiFi lwIP smoke cell: scan -> assoc -> DHCP -> ICMP echo to gateway.

    Builds + flashes + runs `m0_wifi_lwip_smoke` via hw_validate.py's catalog
    mode (same plumbing as the wifi-blob cell). No host-side echo server is
    needed (the firmware pings the DHCP-supplied gateway directly).
    """
    work_dir = build_dir / "hw-validate-work"
    log_path = run_via_hw_validate(
        test_name="m0_wifi_lwip_smoke",
        ssid=ssid, password=password, attempts=attempts,
        uart_port=uart_port, uart_baud=uart_baud, work_dir=work_dir,
    )
    print(f"uart log: {log_path}")
    attempts_records = parse_log_file(log_path)

    report = summarize_cell(attempts_records)
    print_cell_summary("wifi-lwip-smoke", report)
    out_dir = build_dir / time.strftime("%Y%m%d-%H%M%S")
    write_cell_report_json(
        out_dir / "wifi-lwip-smoke.json", "wifi-lwip-smoke", report,
        extra={"uart_log": str(log_path)},
    )
    return report
```

(b) Find `parser.add_argument("--cell", choices=["wifi-blob"], default="wifi-blob")` in `main()` and replace with:

```python
    parser.add_argument("--cell", choices=["wifi-blob", "wifi-lwip-smoke"],
                        default="wifi-blob")
```

(c) Find the dispatch block in `main()`:

```python
    if args.cell != "wifi-blob":
        print(f"cell {args.cell!r} not supported in Iteration 1", file=sys.stderr)
        return 2
    report = run_wifi_blob_cell(
        uart_port=args.uart, uart_baud=args.uart_baud,
        ssid=args.ssid, password=args.password,
        attempts=args.attempts, ap_check_target=args.ap_check_target,
        overall_timeout_s=args.overall_timeout_s, build_dir=args.build_dir,
    )
```

Replace the entire block above with:

```python
    if args.cell == "wifi-blob":
        report = run_wifi_blob_cell(
            uart_port=args.uart, uart_baud=args.uart_baud,
            ssid=args.ssid, password=args.password,
            attempts=args.attempts, ap_check_target=args.ap_check_target,
            overall_timeout_s=args.overall_timeout_s, build_dir=args.build_dir,
        )
    elif args.cell == "wifi-lwip-smoke":
        report = run_wifi_lwip_smoke_cell(
            uart_port=args.uart, uart_baud=args.uart_baud,
            ssid=args.ssid, password=args.password,
            attempts=args.attempts, build_dir=args.build_dir,
        )
    else:
        print(f"cell {args.cell!r} not supported", file=sys.stderr)
        return 2
```

- [ ] **Step 4: Verify the existing pytest still passes**

Run:
```bash
.venv/bin/pytest tools/test_hw_e2e.py -v
```

Expected: `10 passed` (the same baseline as before this task). The new function isn't covered by tests, but the existing tests must keep passing — they exercise `drive_uart_for_attempts`, `write_cell_report_json`, `print_cell_summary`, the `EchoServer`, and `discover_lan_ip`, none of which we've modified.

If any test fails:
- The `import` order in `hw_e2e.py` must not change. We're only adding a function and editing `main()`.
- Check for syntax errors with `python -c "import tools.hw_e2e"` from repo root.
- Discard the file with `git checkout HEAD -- tools/hw_e2e.py` and re-do Step 3.

- [ ] **Step 5: Add the Makefile target**

Open `Makefile`.

(a) Find the `.PHONY:` line (around line 37). It currently ends with `... hw-e2e-quick hw-full hw-full-uart hw-full-anchor clean help`. Insert `hw-e2e-lwip-smoke` after `hw-e2e-quick`, so the line becomes:

```makefile
.PHONY: m0 d0 lp ipc examples-check flash-m0 flash-d0 flash-lp venv hw-list hw-preflight hw-smoke hw-smoke-uart hw-smoke-anchor hw-smoke-jtag hw-allcore-jtag hw-e2e-quick hw-e2e-lwip-smoke hw-full hw-full-uart hw-full-anchor clean help
```

(b) Find the `hw-e2e-quick` target (around line 192). Immediately **after** it (i.e., before the `# Clean build artifacts` comment), insert:

```makefile
hw-e2e-lwip-smoke: venv
	@test -n "$(WIFI_SSID)" || (echo "Error: WIFI_SSID is required (e.g. WIFI_SSID=Frog)"; exit 1)
	@test -n "$(WIFI_PASSWORD)" || (echo "Error: WIFI_PASSWORD is required"; exit 1)
	$(PYTHON) tools/hw_e2e.py --cell wifi-lwip-smoke --uart $(UART_PORT) --uart-baud $(UART_BAUD) --ssid $(WIFI_SSID) --password $(WIFI_PASSWORD) --attempts 3
```

**Important:** Use a literal TAB character (not spaces) at the start of each recipe line — the `@test`, `$(PYTHON)` etc. lines must begin with TAB. The Edit tool will preserve whatever you provide; if you copy-paste from this plan, ensure you have actual TABs.

(c) Add a help line. Find the existing `hw-e2e-quick` help line (around line 63):

```makefile
	@echo "  make hw-e2e-quick UART_PORT=<p> WIFI_SSID=<s> WIFI_PASSWORD=<p>  WiFi blob N=3 e2e soak (Iteration 1)"
```

Insert immediately after it:

```makefile
	@echo "  make hw-e2e-lwip-smoke UART_PORT=<p> WIFI_SSID=<s> WIFI_PASSWORD=<p>  WiFi lwIP DHCP+ICMP smoke N=3"
```

- [ ] **Step 6: Verify the Makefile target resolves**

Run:
```bash
make -n hw-e2e-lwip-smoke WIFI_SSID=test WIFI_PASSWORD=test
```

Expected: prints the recipe (the `test -n` checks and the `python tools/hw_e2e.py ...` invocation) without `make: *** No rule to make target` or `*** missing separator` errors.

If `*** missing separator` appears: a line in the new target uses spaces instead of a tab. Open the Makefile, locate the new `hw-e2e-lwip-smoke:` block, and replace the leading whitespace of each recipe line with a single tab character.

If the credentials guard fires (`Error: WIFI_SSID is required` or `Error: WIFI_PASSWORD is required`) during `make -n`: this should NOT happen — `-n` is dry-run mode which prints recipes without executing them. If it does fire on a different make version, the guard is still correct; just confirm the rest of the recipe is shown.

- [ ] **Step 7: Confirm `make help` lists the new target**

Run:
```bash
make help | grep hw-e2e-lwip-smoke
```

Expected: one line of output matching the help text from Step 5(c).

- [ ] **Step 8: Verify only the three intended files were modified**

Run:
```bash
git status --short
```

Expected: exactly three ` M` lines, for `Makefile`, `tools/hardware_validation.json`, and `tools/hw_e2e.py`. No other files modified by this task.

- [ ] **Step 9: Commit**

```bash
git add Makefile tools/hardware_validation.json tools/hw_e2e.py
git commit -m "$(cat <<'EOF'
harness: wire wifi-lwip-smoke cell + catalog + Makefile target

Iter 2.A.0 follow-up step 3/3. Adds m0_wifi_lwip_smoke catalog entry
(env-driven WifiSsid/WifiPassword, e2e tier, 240s timeout), a parallel
run_wifi_lwip_smoke_cell function in tools/hw_e2e.py reusing the same
hw_validate.py catalog-mode plumbing as wifi-blob, and a make
hw-e2e-lwip-smoke target with the standard credentials guard.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Hardware run (post-implementation, no commit)

After Tasks 1-3 are committed, the implementation is complete. The hardware run is a separate validation step — its outcome is empirical and may surface bugs in the substrate, but it does **not** modify code unless a real bug is found and the user authorizes a follow-up fix iteration.

To run on hardware (operator action):

```bash
make hw-e2e-lwip-smoke \
  UART_PORT=/dev/tty.usbserial-TGKWL2RS \
  WIFI_SSID=Frog \
  WIFI_PASSWORD=<wifi-password>
```

Expected outcomes (any of these is a valid completion of this iteration):

1. **Full pass**: all 3 attempts reach `icmp:ok rtt_ms=…`. Substrate is fully validated; iteration is done.
2. **Partial pass**: at least 1 of 3 attempts reaches `icmp:ok`. Substrate's primary path works; intermittent failure mode goes into a follow-up. Iteration is done from the implementation perspective.
3. **All fail at the same phase**: `dhcp:fail reason=…` × 3 or `icmp:fail reason=…` × 3. Substrate has a real bug; surface the marker stream and the per-phase failure bucket. The iteration's *implementation* is still complete (the harness is working as designed by exposing the bug); a *separate* fix iteration is required.

Failure-bucket interpretation (from the spec, for the operator's convenience):

- `dhcp:fail reason=no_netif` → `wifiGetNetif()` returned NULL; the WiFi netif wasn't registered, even though `wifiConnect` succeeded. Investigate the substrate's `netifapi_netif_add` bridge.
- `dhcp:fail reason=dhcp_start` (with `rc=0xFFFFFFFF` etc.) → `dhcp_start` returned an error code; likely the netif isn't in the UP state, or the lwIP heap is too small. Check `lwipopts.h` MEM_SIZE.
- `dhcp:fail reason=timeout` → DHCPDISCOVER was sent but no OFFER reached us. Either the TX bridge (`linkoutput`) isn't sending, or the RX bridge dropped the OFFER pbuf. Capture a packet trace on the AP if possible.
- `icmp:fail reason=tx_failed` → `raw_sendto` failed; netif unreachable. Verify the gateway is in the same subnet as the assigned IP.
- `icmp:fail reason=recv_timeout` → no ECHO REPLY in 3 s. Either the gateway didn't reply (try `ping <board_ip>` from the LAN to confirm L2 reachability), or our raw recv path doesn't deliver ICMP packets. Compare with the working DHCP path (UDP).

---

## Self-review

**Spec coverage:**
- Section 1 (goal, success criteria, marker grammar, out-of-scope): Tasks 1+2 emit the marker grammar verbatim (`scan/auth/4whs/assoc/dhcp/icmp` start/ok/fail with the documented reason buckets). The `dhcp:ok ip=… gw=…` and `icmp:ok rtt_ms=… seq=…` payloads are in the binary. ✅
- Section 2.1 (DHCP commit): Task 1 implements it. ✅
- Section 2.2 (ICMP commit): Task 2 implements it; the `recv_cb` payload validation matches the spec's "validate the 8-byte payload matches what we sent". ✅
- Section 2.3 (catalog + cell + Makefile): Task 3 implements all three pieces. ✅
- Section 3 (file layout, files NOT touched): Plan honors all NOT-touched constraints; `git status` checks at Steps 1.3, 2.4, 3.8 enforce. ✅
- Section 4 (strict sequence, never-reset rule, risk buckets): Per-task discard guidance uses `git checkout HEAD --`; hardware run section preserves the failure-bucket map for the operator. ✅

**Placeholder scan:** No TBD/TODO. Every step has either concrete code or a concrete command. The "discard and report" guidance in failure paths is explicit, not "handle errors". ✅

**Type consistency:**
- `Netif`, `Pbuf`, `RawPcb`, `IpAddr` are declared once in Task 1/2 and used consistently.
- `ErrT`/`ErrOk` introduced in Task 1, reused in Task 2 (`rawSendto` returns `ErrT`).
- `nowMs()` introduced in Task 1, reused in Task 2.
- `IcmpPayload` is module-const (Task 2 add), referenced by both `icmpRecvCb` (validation) and the request builder.
- `kvWrite` calls always pass either `string` or unsigned/signed ints (`txRc.int32` cast is correct because `ErrT = int8`). ✅

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-10-wifi-lwip-smoke-test.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, two-stage review (spec compliance, then code quality) between tasks, fast iteration without manual checkpoints between commits.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints for review.

**Which approach?**
