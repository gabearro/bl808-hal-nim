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
  ErrT = int8
const ErrOk: ErrT = 0

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
  IcmpPayload: array[8, uint8] = [0x42'u8, 0x4C, 0x38, 0x30, 0x38, 0x2D, 0x4C, 0x53]

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
