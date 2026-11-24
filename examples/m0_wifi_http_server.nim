## BL808 pure-Nim WiFi HTTP/1.1 server example.
##
## Joins an AP, obtains a DHCP lease, starts a small lwIP raw-API TCP server,
## and serves one HTTP response per client connection.
##
## Build with:
##   make m0 FILE=examples/m0_wifi_http_server.nim \
##     NIM="nim -d:bl808kernel -d:bl808WifiNimFw \
##              -d:WifiSsid=Frog -d:WifiPassword=<wifi-password>"
##
## Try from a machine on the same network:
##   curl http://<device-ip>/

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/wifi
import bl808/panicoverride
import bl808/psram
import bl808/mmio
when defined(bl808WifiMbedTlsSha1Profile):
  from bl808/memmap import ClicMtimeBase
when defined(bl808WifiMbedTlsSha1Lease):
  from bl808/wifi/mbedtls_sha1_alt import beginShaApKeySetup, finishShaApKeySetup
  proc shaLeaseSelftest(): cint {.importc: "bl808_mbedtls_sha1_lease_selftest", cdecl.}
import bl808/kernel/alloc
import bl808/kernel/clock
import bl808/kernel/e2e_marker
import bl808/kernel/lwipcore
import bl808/wasm_http

when defined(bl808WifiApHttpSmoke):
  # The NO_SYS build deliberately omits the sockets API's broadcast alias.
  {.passC: "-DINADDR_BROADCAST=IPADDR_BROADCAST".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/network/lwip_dhcpd/dhcp_server_raw.c".}
  proc dhcpServerStart(netif: ptr Netif; first, last: ptr IpAddr): ErrT
    {.importc: "dhcp_server_start", cdecl.}
  proc dhcpServerStop(netif: ptr Netif): ErrT {.importc: "dhcp_server_stop", cdecl.}
  var apHostTiming {.importc: "nimfw_ap_host_result".}: array[6, uint32]
  var apFirmwareTiming {.importc: "nimfw_ap_timing".}: array[5, uint32]
  when defined(bl808WifiMbedTlsSha1Hardware):
    var apShaBackend {.importc: "nim_mbedtls_sha1_backend".}: array[4, uint32]
  when defined(bl808WifiMbedTlsSha1Profile):
    proc apBenchCycles(): uint32 {.inline.} =
      {.emit: "__asm__ volatile(\"csrr %0, mcycle\" : \"=r\"(`result`) :: \"memory\");".}

{.emit: "#include \"lwip/tcp.h\"\n#include \"lwip/pbuf.h\"".}
{.emit: """
extern signed char nim_http_recv(void *arg, void *pcb, void *p, signed char err);
extern signed char nim_http_accept(void *arg, void *pcb, signed char err);

static err_t nim_http_recv_shim(void *arg, struct tcp_pcb *pcb,
                                struct pbuf *p, err_t err)
{
    return nim_http_recv(arg, (void *)pcb, (void *)p, (signed char)err);
}

static err_t nim_http_accept_shim(void *arg, struct tcp_pcb *pcb, err_t err)
{
    return nim_http_accept(arg, (void *)pcb, (signed char)err);
}

static void nim_http_tcp_recv(void *pcb)
{
    tcp_recv((struct tcp_pcb *)pcb, nim_http_recv_shim);
}

static void nim_http_tcp_accept(void *pcb)
{
    tcp_accept((struct tcp_pcb *)pcb, nim_http_accept_shim);
}
""".}

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  WifiSsid {.strdefine.} = ""
  WifiPassword {.strdefine.} = ""
  HttpPort {.intdefine.} = 80
  UdpEchoPort {.intdefine.} = 65000
  UdpProbeTargetA {.intdefine.} = 0
  UdpProbeTargetB {.intdefine.} = 0
  UdpProbeTargetC {.intdefine.} = 0
  UdpProbeTargetD {.intdefine.} = 0
  UdpProbePort {.intdefine.} = 65001
  DhcpTimeoutMs = 30_000'u32
  UdpProbeIntervalMs = 1_000'u32
  HttpRequestBufferLen = 2048

const
  HttpGreeting = "Hello World! from Nim on BL808"
  UdpProbePayload = "BL808 Nim lwIP UDP probe"

{.emit: """/*TYPESECTION*/
extern char __psram_bss_start[], __psram_bss_end[];
extern char __sddma_start[], __sddma_end[];
static unsigned long http_psram_bss_start(void) { return (unsigned long)__psram_bss_start; }
static unsigned long http_psram_bss_end(void) { return (unsigned long)__psram_bss_end; }
static unsigned long http_sddma_start(void) { return (unsigned long)__sddma_start; }
static unsigned long http_sddma_end(void) { return (unsigned long)__sddma_end; }
""".}
proc psramBssStart(): uint {.importc: "http_psram_bss_start", nodecl.}
proc psramBssEnd(): uint {.importc: "http_psram_bss_end", nodecl.}
proc sdDmaStart(): uint {.importc: "http_sddma_start", nodecl.}
proc sdDmaEnd(): uint {.importc: "http_sddma_end", nodecl.}

proc clearWords(first, limit: uint) =
  var cursor = first
  while cursor < limit:
    regWrite(cursor, 0'u32)
    cursor += 4'u

proc initHttpPsram() =
  psramInit(psram64mb, psramBurst64)
  psramEnable()
  clearWords(psramBssStart(), psramBssEnd())
  clearWords(sdDmaStart(), sdDmaEnd())

var
  console: Uart
  listenPcb: ptr TcpPcb
  udpPcb: ptr UdpPcb
  httpRequests: uint32
  httpRxBytes: uint32
  httpWriteFail: uint32
  httpCloseFail: uint32
  httpLastIp: uint32
  httpLastGw: uint32
  udpRxPackets: uint32
  udpTxPackets: uint32
  udpRxBytes: uint32
  udpTxBytes: uint32
  udpSendFail: uint32
  udpLastRemoteIp: uint32
  udpLastRemotePort: uint32
  udpProbeLastMs: uint32
  udpProbeTxPackets: uint32
  udpProbeTxBytes: uint32
  udpProbeFail: uint32
  deviceMac: array[6, uint8]
  httpLoopTicks* {.exportc: "nim_http_loop_ticks".}: uint32
  httpAcceptCount* {.exportc: "nim_http_accept_count".}: uint32
  httpRecvCount* {.exportc: "nim_http_recv_count".}: uint32
  httpRecvNilPbuf* {.exportc: "nim_http_recv_nil_pbuf".}: uint32
  httpRecvErrCount* {.exportc: "nim_http_recv_err_count".}: uint32
  httpWasmRequests* {.exportc: "nim_http_wasm_requests".}: uint32
  udpRecvCount* {.exportc: "nim_udp_recv_count".}: uint32
  udpSendCount* {.exportc: "nim_udp_send_count".}: uint32
  udpRecvBytes* {.exportc: "nim_udp_recv_bytes".}: uint32
  udpSendBytes* {.exportc: "nim_udp_send_bytes".}: uint32
  udpSendFailCount* {.exportc: "nim_udp_send_fail_count".}: uint32
  udpProbeSendCount* {.exportc: "nim_udp_probe_send_count".}: uint32
  udpProbeSendFailCount* {.exportc: "nim_udp_probe_send_fail_count".}: uint32

type
  ResponseBuffer = object
    data: array[768, char]
    len: uint16

var httpRequestBuffer: array[HttpRequestBufferLen, byte]

proc appendChar(buf: var ResponseBuffer; ch: char) =
  if buf.len.uint32 < buf.data.len.uint32:
    buf.data[buf.len.int] = ch
    inc buf.len

proc appendText(buf: var ResponseBuffer; text: static[string]) =
  for ch in text:
    appendChar(buf, ch)

proc appendUInt(buf: var ResponseBuffer; value: uint32) =
  var divisor = 1_000_000_000'u32
  var started = false
  while divisor > 0'u32:
    let digit = (value div divisor) mod 10'u32
    if digit != 0'u32 or started or divisor == 1'u32:
      appendChar(buf, char(ord('0') + digit.int))
      started = true
    divisor = divisor div 10'u32

proc appendHexNibble(buf: var ResponseBuffer; value: uint8) =
  let nibble = value and 0x0F'u8
  appendChar(buf, if nibble < 10'u8:
    char(ord('0') + nibble.int)
  else:
    char(ord('A') + nibble.int - 10))

proc appendHex32(buf: var ResponseBuffer; value: uint32) =
  appendText(buf, "0x")
  for shift in countdown(28, 0, 4):
    appendHexNibble(buf, uint8((value shr shift) and 0x0F'u32))

proc appendHexByte(buf: var ResponseBuffer; value: uint8) =
  appendHexNibble(buf, value shr 4)
  appendHexNibble(buf, value)

proc appendMac(buf: var ResponseBuffer; mac: array[6, uint8]) =
  for i in 0 ..< mac.len:
    if i != 0:
      appendChar(buf, ':')
    appendHexByte(buf, mac[i])

proc appendIp4(buf: var ResponseBuffer; ip: uint32) =
  appendUInt(buf, ((ip shr 0) and 0xFF'u32))
  appendChar(buf, '.')
  appendUInt(buf, ((ip shr 8) and 0xFF'u32))
  appendChar(buf, '.')
  appendUInt(buf, ((ip shr 16) and 0xFF'u32))
  appendChar(buf, '.')
  appendUInt(buf, ((ip shr 24) and 0xFF'u32))

proc buildHttpBody(rxLen: uint16): ResponseBuffer =
  appendText(result, HttpGreeting)
  appendText(result, "\n\n")
  appendText(result, "device=BL808\n")
  appendText(result, "runtime=Nim\n")
  appendText(result, "device_mac=")
  appendMac(result, deviceMac)
  appendText(result, "\n")
  appendText(result, "wifi_ssid=")
  appendText(result, WifiSsid)
  appendText(result, "\n")
  appendText(result, "ip=")
  appendIp4(result, httpLastIp)
  appendText(result, "\n")
  appendText(result, "gateway=")
  appendIp4(result, httpLastGw)
  appendText(result, "\n")
  appendText(result, "http_requests=")
  appendUInt(result, httpRequests + 1'u32)
  appendText(result, "\n")
  appendText(result, "http_rx_bytes_total=")
  appendUInt(result, httpRxBytes)
  appendText(result, "\n")
  appendText(result, "http_rx_bytes_last=")
  appendUInt(result, rxLen.uint32)
  appendText(result, "\n")
  appendText(result, "http_write_failures=")
  appendUInt(result, httpWriteFail)
  appendText(result, "\n")
  appendText(result, "http_close_failures=")
  appendUInt(result, httpCloseFail)
  appendText(result, "\n")
  appendText(result, "udp_echo_port=")
  appendUInt(result, UdpEchoPort.uint32)
  appendText(result, "\n")
  appendText(result, "udp_rx_packets=")
  appendUInt(result, udpRxPackets)
  appendText(result, "\n")
  appendText(result, "udp_tx_packets=")
  appendUInt(result, udpTxPackets)
  appendText(result, "\n")
  appendText(result, "udp_rx_bytes_total=")
  appendUInt(result, udpRxBytes)
  appendText(result, "\n")
  appendText(result, "udp_tx_bytes_total=")
  appendUInt(result, udpTxBytes)
  appendText(result, "\n")
  appendText(result, "udp_send_failures=")
  appendUInt(result, udpSendFail)
  appendText(result, "\n")
  appendText(result, "udp_last_remote_ip=")
  appendIp4(result, udpLastRemoteIp)
  appendText(result, "\n")
  appendText(result, "udp_last_remote_port=")
  appendUInt(result, udpLastRemotePort)
  appendText(result, "\n")
  appendText(result, "udp_probe_target=")
  appendIp4(result, ip4Addr(UdpProbeTargetA.uint8, UdpProbeTargetB.uint8,
                            UdpProbeTargetC.uint8, UdpProbeTargetD.uint8).address)
  appendText(result, "\n")
  appendText(result, "udp_probe_port=")
  appendUInt(result, UdpProbePort.uint32)
  appendText(result, "\n")
  appendText(result, "udp_probe_tx_packets=")
  appendUInt(result, udpProbeTxPackets)
  appendText(result, "\n")
  appendText(result, "udp_probe_tx_bytes_total=")
  appendUInt(result, udpProbeTxBytes)
  appendText(result, "\n")
  appendText(result, "udp_probe_failures=")
  appendUInt(result, udpProbeFail)
  appendText(result, "\n")
  appendText(result, "scan_items=")
  appendUInt(result, bl808_wifi_backend_scan_count())
  appendText(result, "\n")
  appendText(result, "scan_done=")
  appendUInt(result, bl808_wifi_backend_scan_done_count())
  appendText(result, "\n")
  appendText(result, "scan_diag=")
  appendUInt(result, bl808_wifi_backend_scan_diag_count())
  appendText(result, "\n")
  appendText(result, "last_status=")
  appendHex32(result, bl808_wifi_backend_last_status().uint32)
  appendText(result, "\n")
  appendText(result, "last_reason=")
  appendHex32(result, bl808_wifi_backend_last_reason().uint32)
  appendText(result, "\n")

proc buildHttpHeader(bodyLen: uint16): ResponseBuffer =
  appendText(result, "HTTP/1.1 200 OK\r\n")
  appendText(result, "Connection: close\r\n")
  appendText(result, "Content-Type: text/plain\r\n")
  appendText(result, "Content-Length: ")
  appendUInt(result, bodyLen.uint32)
  appendText(result, "\r\n\r\n")

proc requestStartsWith(data: openArray[byte], prefix: string): bool =
  if data.len < prefix.len:
    return false
  for i in 0 ..< prefix.len:
    if data[i] != byte(prefix[i]):
      return false
  true

when defined(bl808WifiApChannelSweep):
  static: doAssert defined(bl808WifiApHttpSmoke)
  include wifi_ap_channel_sweep
  var apChannelSweep: ApChannelSweep

proc requestTargetsWasm(data: openArray[byte]): bool =
  data.requestStartsWith("GET /wasm/") or
    data.requestStartsWith("POST /wasm/") or
    data.requestStartsWith("DELETE /wasm/")

proc writeStringResponse(tcp: ptr TcpPcb, response: string): ErrT =
  if response.len == 0:
    return ErrOk
  if response.len > uint16.high.int:
    return ErrMem
  tcpWrite(
    tcp,
    cast[pointer](unsafeAddr response[0]),
    response.len.uint16,
    TcpWriteFlagCopy)

proc tcpRecvShim(pcb: pointer) {.importc: "nim_http_tcp_recv", cdecl.}
proc tcpAcceptShim(pcb: pointer) {.importc: "nim_http_tcp_accept", cdecl.}
proc bl_wifi_mac_addr_get(mac: ptr uint8): cint {.importc, cdecl.}
proc bl_wifi_get_assoc_bssid_internal(vifIdx: uint8; bssid: pointer): cint {.importc, cdecl.}

proc nowMs(): uint32 {.inline.} =
  (kernel_read_tick_ms() and 0xffffffff'u64).uint32

proc pollNetwork() {.inline.} =
  bl808_wifi_backend_poll(4)
  sysCheckTimeouts()

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

proc netifIp4(netif: ptr Netif): uint32 =
  var v: uint32 = 0
  {.emit: "`v` = ((struct netif*)`netif`)->ip_addr.addr;".}
  v

proc netifGw4(netif: ptr Netif): uint32 =
  var v: uint32 = 0
  {.emit: "`v` = ((struct netif*)`netif`)->gw.addr;".}
  v

proc ip4Octet(ip: uint32; index: uint32): uint8 {.inline.} =
  ((ip shr (index * 8)) and 0xff'u32).uint8

proc writeDecByte(v: uint8) =
  let hundreds = v div 100'u8
  let tens = (v div 10'u8) mod 10'u8
  let ones = v mod 10'u8
  if hundreds != 0:
    discard console.sendByte((ord('0') + hundreds.int).uint8)
  if hundreds != 0 or tens != 0:
    discard console.sendByte((ord('0') + tens.int).uint8)
  discard console.sendByte((ord('0') + ones.int).uint8)

proc writeIp4(ip: uint32) =
  writeDecByte(ip4Octet(ip, 0))
  discard console.sendByte('.'.uint8)
  writeDecByte(ip4Octet(ip, 1))
  discard console.sendByte('.'.uint8)
  writeDecByte(ip4Octet(ip, 2))
  discard console.sendByte('.'.uint8)
  writeDecByte(ip4Octet(ip, 3))

proc scanDiagHasFreshResult(itemsBefore: uint32; wantedSsid: string;
                            expectedChannel = 0'u8): bool =
  # "Fresh" means delivered during this serialized startup join. Firmware
  # can replay a cached beacon during a warm join; this is not an RF trace.
  if wantedSsid.len notin 1 .. 32: return false
  let items = bl808_wifi_backend_scan_count()
  # Do not subtract across a reset or wrap.
  if items <= itemsBefore: return false
  let count = bl808_wifi_backend_scan_diag_count()
  let fresh = min(count, items - itemsBefore)
  if fresh == 0: return false
  var peer: array[6, uint8]
  # This standalone station-only image registers the station VIF first.
  if bl_wifi_get_assoc_bssid_internal(0, addr peer[0]) != 0 or
      (peer[0] and 1) != 0 or peer == default(typeof(peer)):
    return false
  for i in count - fresh ..< count:
    var ssidLen: uint8
    var ssid: array[33, uint8]
    var channel: uint8
    var bssid: array[6, uint8]
    let rc = bl808_wifi_backend_scan_diag_get(
      i, addr ssidLen, addr ssid[0], addr channel, nil,
      nil, nil, addr bssid[0])
    if rc != 0 or bssid != peer or ssidLen.int != wantedSsid.len or
        channel notin 1'u8 .. 14'u8 or (expectedChannel != 0 and channel != expectedChannel):
      continue
    var matches = true
    for j in 0 ..< wantedSsid.len:
      if ssid[j] != wantedSsid[j].uint8:
        matches = false
        break
    if not matches: continue
    phaseMark(Phase.scan, Kind.ok):
      kvWrite("items", items)
      kvWrite("done", bl808_wifi_backend_scan_done_count())
      kvWrite("diag", count)
      kvWrite("ch", channel.uint32)
      kvWrite("ssid_len", ssidLen.uint32)
    return true
  false

proc closeClient(pcb: pointer) =
  if pcb == nil:
    return
  let tcp = cast[ptr TcpPcb](pcb)
  tcpRecv(tcp, nil)
  tcpSent(tcp, nil)
  tcpErr(tcp, nil)
  tcpArg(tcp, nil)
  if tcpClose(tcp) != ErrOk:
    inc httpCloseFail
    tcpAbort(tcp)

proc nimHttpRecv(arg, pcb, p: pointer; err: ErrT): ErrT
    {.exportc: "nim_http_recv", cdecl.} =
  discard arg
  inc httpRecvCount
  if pcb == nil:
    if p != nil:
      discard pbufFree(cast[ptr Pbuf](p))
    return ErrOk
  if err != ErrOk:
    inc httpRecvErrCount
    if p != nil:
      discard pbufFree(cast[ptr Pbuf](p))
    closeClient(pcb)
    return ErrOk
  if p == nil:
    inc httpRecvNilPbuf
    closeClient(pcb)
    return ErrOk

  let tcp = cast[ptr TcpPcb](pcb)
  let pbuf = cast[ptr Pbuf](p)
  let rxLen = pbufTotLen(pbuf)
  httpRxBytes += rxLen.uint32
  tcpRecved(tcp, rxLen)
  let copyLen =
    if rxLen.uint32 > httpRequestBuffer.len.uint32:
      httpRequestBuffer.len.uint16
    else:
      rxLen
  let copied = pbufCopyPartial(
    pbuf,
    cast[pointer](addr httpRequestBuffer[0]),
    copyLen,
    0)
  discard pbufFree(pbuf)

  var bodyRc: ErrT
  when defined(bl808WifiApChannelSweep):
    let reply =
      if copyLen == 0 or copied != copyLen: apSweepReject
      else: apSweepRequest(apChannelSweep, cast[uint](arg),
                           httpRequestBuffer.toOpenArray(0, copyLen.int - 1))
    let (status, body) = case reply
      of apSweepProbe: ("200 OK", "channel=" & $apChannelSweep.channel & "\n")
      of apSweepAdvance: ("202 Accepted", "advance=" & $apChannelSweep.channel & "\n")
      of apSweepReject: ("409 Conflict", "No matching active channel\n")
    bodyRc = writeStringResponse(tcp, "HTTP/1.1 " & status &
      "\r\nConnection: close\r\nContent-Type: text/plain\r\nContent-Length: " &
      $body.len & "\r\n\r\n" & body)
    if bodyRc == ErrOk:
      bodyRc = tcpOutput(tcp)
      if bodyRc == ErrOk: apSweepResponseQueued(apChannelSweep, reply, nowMs())
  elif defined(bl808WifiApHttpSmoke):
    const body = "Ox64 setup AP\n"
    const response = "HTTP/1.1 200 OK\r\nConnection: close\r\n" &
      "Content-Type: text/plain\r\nContent-Length: " & $body.len & "\r\n\r\n" & body
    bodyRc = writeStringResponse(tcp, response)
  else:
    if copyLen != 0 and copied == copyLen and
        httpRequestBuffer.toOpenArray(0, copyLen.int - 1).requestTargetsWasm():
      inc httpWasmRequests
      let wasmResponse = handleWasmHttpBytes(
        httpRequestBuffer.toOpenArray(0, copyLen.int - 1))
      let serialized = formatWasmHttpResponse(wasmResponse)
      bodyRc = writeStringResponse(tcp, serialized)
    else:
      let body = buildHttpBody(rxLen)
      let header = buildHttpHeader(body.len)
      let headerRc = tcpWrite(
        tcp,
        cast[pointer](unsafeAddr header.data[0]),
        header.len,
        TcpWriteFlagCopy)
      bodyRc =
        if headerRc == ErrOk:
          tcpWrite(tcp, cast[pointer](unsafeAddr body.data[0]), body.len,
                   TcpWriteFlagCopy)
        else:
          headerRc
  if bodyRc == ErrOk:
    when not defined(bl808WifiApChannelSweep): discard tcpOutput(tcp)
    inc httpRequests
    when defined(bl808WifiApHttpSmoke) and not defined(bl808WifiApChannelSweep):
      if httpRequests == 1:
        discard console.sendLine("[PASS] AP HTTP response queued")
    phaseMark(Phase.tcp, Kind.ok):
      kvWrite("req", httpRequests)
      kvWrite("rx", rxLen.uint32)
      kvWrite("total", httpRxBytes)
  else:
    inc httpWriteFail
    phaseMark(Phase.tcp, Kind.fail):
      kvWrite("reason", "write")
      kvWrite("rc", bodyRc.int32)
      kvWrite("fail", httpWriteFail)
  closeClient(pcb)
  ErrOk

proc nimHttpAccept(arg, newPcb: pointer; err: ErrT): ErrT
    {.exportc: "nim_http_accept", cdecl.} =
  discard arg
  inc httpAcceptCount
  if err != ErrOk or newPcb == nil:
    phaseMark(Phase.tcp, Kind.fail):
      kvWrite("reason", "accept")
      kvWrite("rc", err.int32)
    return ErrOk
  when defined(bl808WifiApChannelSweep):
    tcpArg(cast[ptr TcpPcb](newPcb), cast[pointer](apChannelSweep.channel.uint))
  else:
    tcpArg(cast[ptr TcpPcb](newPcb), nil)
  tcpRecvShim(newPcb)
  ErrOk

proc nimUdpRecv(arg: pointer; pcb: ptr UdpPcb; p: ptr Pbuf;
                remoteAddr: ptr IpAddr; port: uint16) {.cdecl.} =
  discard arg
  if p == nil:
    return

  let rxLen = pbufTotLen(p)
  inc udpRecvCount
  inc udpRxPackets
  udpRxBytes += rxLen.uint32
  udpRecvBytes = udpRxBytes
  udpLastRemotePort = port.uint32
  if remoteAddr != nil:
    udpLastRemoteIp = remoteAddr.address

  let echo = pbufAlloc(pbufTransport, rxLen, pbufRam)
  if echo == nil:
    inc udpSendFail
    udpSendFailCount = udpSendFail
    discard pbufFree(p)
    return

  if pbufCopyPartial(p, pbufPayload(echo), rxLen, 0) != rxLen:
    inc udpSendFail
    udpSendFailCount = udpSendFail
    discard pbufFree(echo)
    discard pbufFree(p)
    return

  let rc =
    if remoteAddr != nil:
      udpSendto(pcb, echo, remoteAddr, port)
    else:
      ErrRte
  if rc == ErrOk:
    inc udpSendCount
    inc udpTxPackets
    udpTxBytes += rxLen.uint32
    udpSendBytes = udpTxBytes
    phaseMark(Phase.tcp, Kind.ok):
      kvWrite("proto", "udp")
      kvWrite("rx", rxLen.uint32)
      kvWrite("port", port.uint32)
  else:
    inc udpSendFail
    udpSendFailCount = udpSendFail
    phaseMark(Phase.tcp, Kind.fail):
      kvWrite("proto", "udp")
      kvWrite("rc", rc.int32)

  discard pbufFree(echo)
  discard pbufFree(p)

proc startUdpEchoServer(port: uint16): bool =
  let pcb = udpNew()
  if pcb == nil:
    phaseMark(Phase.tcp, Kind.fail):
      kvWrite("proto", "udp")
      kvWrite("reason", "udp_new")
    return false
  var any = ipAddrAny()
  let bindRc = udpBind(pcb, addr any, port)
  if bindRc != ErrOk:
    phaseMark(Phase.tcp, Kind.fail):
      kvWrite("proto", "udp")
      kvWrite("reason", "udp_bind")
      kvWrite("rc", bindRc.int32)
    udpRemove(pcb)
    return false
  udpRecv(pcb, nimUdpRecv, nil)
  udpPcb = pcb
  phaseMark(Phase.tcp, Kind.start):
    kvWrite("proto", "udp")
    kvWrite("port", port.uint32)
  true

proc udpProbeTarget(): IpAddr {.inline.} =
  ip4Addr(UdpProbeTargetA.uint8, UdpProbeTargetB.uint8,
          UdpProbeTargetC.uint8, UdpProbeTargetD.uint8)

proc udpProbeEnabled(): bool {.inline.} =
  UdpProbeTargetA != 0 or UdpProbeTargetB != 0 or
    UdpProbeTargetC != 0 or UdpProbeTargetD != 0

proc sendUdpProbe() =
  if udpPcb == nil or not udpProbeEnabled():
    return
  let now = nowMs()
  if udpProbeLastMs != 0'u32 and now - udpProbeLastMs < UdpProbeIntervalMs:
    return
  udpProbeLastMs = now

  let probeLen = UdpProbePayload.len.uint16
  let p = pbufAlloc(pbufTransport, probeLen, pbufRam)
  if p == nil:
    inc udpProbeFail
    udpProbeSendFailCount = udpProbeFail
    return
  if pbufTake(p, cast[pointer](cstring(UdpProbePayload)), probeLen) != ErrOk:
    inc udpProbeFail
    udpProbeSendFailCount = udpProbeFail
    discard pbufFree(p)
    return

  var target = udpProbeTarget()
  let rc = udpSendto(udpPcb, p, addr target, UdpProbePort.uint16)
  if rc == ErrOk:
    inc udpProbeTxPackets
    udpProbeTxBytes += probeLen.uint32
    udpProbeSendCount = udpProbeTxPackets
    phaseMark(Phase.tcp, Kind.ok):
      kvWrite("proto", "udp_probe")
      kvWrite("port", UdpProbePort.uint32)
      kvWrite("tx", probeLen.uint32)
  else:
    inc udpProbeFail
    udpProbeSendFailCount = udpProbeFail
    phaseMark(Phase.tcp, Kind.fail):
      kvWrite("proto", "udp_probe")
      kvWrite("rc", rc.int32)
  discard pbufFree(p)

proc startHttpServer(port: uint16; address = 0'u32): bool =
  let pcb = tcpNew()
  if pcb == nil:
    phaseMark(Phase.tcp, Kind.fail):
      kvWrite("reason", "tcp_new")
    return false
  var local = IpAddr(address: address)
  let bindRc = tcpBind(pcb, addr local, port)
  if bindRc != ErrOk:
    phaseMark(Phase.tcp, Kind.fail):
      kvWrite("reason", "bind")
      kvWrite("rc", bindRc.int32)
    tcpAbort(pcb)
    return false
  listenPcb = tcpListen(pcb)
  if listenPcb == nil:
    phaseMark(Phase.tcp, Kind.fail):
      kvWrite("reason", "listen")
    tcpAbort(pcb)
    return false
  tcpAcceptShim(cast[pointer](listenPcb))
  phaseMark(Phase.tcp, Kind.start):
    kvWrite("port", port.uint32)
  true

when defined(bl808WifiApHttpSmoke):
  const WifiApBenchChannel {.intdefine.} = 11
  static: doAssert WifiApBenchChannel in 1 .. 11, "AP smoke uses the US channel plan"

  proc startApHttpSmoke(ssid: string; channel: int): bool =
    when defined(bl808WifiMbedTlsSha1Lease):
      let checkHardwareBefore = apShaBackend[1]
      let checkSoftwareBefore = apShaBackend[2]
      if not beginShaApKeySetup(): return false
      let knownAnswer = shaLeaseSelftest()
      let released = finishShaApKeySetup()
      if knownAnswer == 0 or not released or apShaBackend[1] <= checkHardwareBefore or
          apShaBackend[2] != checkSoftwareBefore:
        discard console.sendLine("[FAIL] Mbed TLS SHA lease known-answer test")
        return false
      discard console.sendLine("[PASS] Mbed TLS SHA lease known-answer test")
    when defined(bl808WifiMbedTlsSha1Hardware):
      let hardwareBefore = apShaBackend[1]
      let softwareBefore = apShaBackend[2]
    when defined(bl808WifiMbedTlsSha1Profile):
      let observedAt = regRead(ClicMtimeBase)
      let cycleStart = apBenchCycles()
    let startResult = wifiStartAp(ssid, WifiPassword, channel)
    when defined(bl808WifiMbedTlsSha1Profile):
      let cycles = apBenchCycles() - cycleStart
      let observedUs = regRead(ClicMtimeBase) - observedAt
    let keyUs = apFirmwareTiming[2] - apFirmwareTiming[1]
    let commandUs = apHostTiming[5] - apHostTiming[4]
    phaseMark(Phase.auth, if startResult == wifiOk: Kind.ok else: Kind.fail):
      kvWrite("ap_key_us", keyUs)
      kvWrite("ap_start_us", commandUs)
      when defined(bl808WifiMbedTlsSha1Hardware):
        kvWrite("sha_state", apShaBackend[0])
        kvWrite("sha_hw_blocks", apShaBackend[1] - hardwareBefore)
        kvWrite("sha_sw_blocks", apShaBackend[2] - softwareBefore)
        kvWrite("sha_timeouts", apShaBackend[3])
      when defined(bl808WifiMbedTlsSha1Profile):
        kvWrite("ap_observed_us", observedUs)
        kvWrite("ap_m0_cycles", cycles)
    if startResult != wifiOk:
      discard console.sendLine("[FAIL] AP startup")
      return false
    when defined(bl808WifiMbedTlsSha1Hardware):
      if apShaBackend[0] != 2 or apShaBackend[1] == hardwareBefore or
          apShaBackend[2] != softwareBefore:
        discard console.sendLine("[FAIL] AP startup did not use the hardware SHA-1 provider")
        return false
    if keyUs == 0 or commandUs < keyUs or commandUs >= 200_000:
      discard console.sendLine("[FAIL] AP startup exceeded 200 ms budget")
      return false
    discard console.sendLine("[PASS] AP startup under 200 ms budget")
    let ap = cast[ptr Netif](wifiGetApNetif())
    if ap == nil or cast[pointer](ap) == wifiGetNetif() or netifIp4(ap) != 0x010BA8C0'u32:
      discard console.sendLine("[FAIL] AP network interface")
      return false
    discard console.sendLine("[PASS] AP firmware and netif ready")
    var first = ip4Addr(192, 168, 11, 20)
    var last = ip4Addr(192, 168, 11, 23)
    if dhcpServerStart(ap, addr first, addr last) != ErrOk:
      discard console.sendLine("[FAIL] AP DHCP startup")
      return false
    discard console.sendLine("[PASS] AP DHCP server started")
    httpLastIp = netifIp4(ap)
    if listenPcb == nil and not startHttpServer(HttpPort.uint16, httpLastIp):
      discard dhcpServerStop(ap)
      return false
    discard console.sendLine("Ready for AP HTTP client requests at 192.168.11.1")
    true

  when defined(bl808WifiApChannelSweep):
    static: doAssert WifiSsid.len in 1 .. 27, "AP sweep appends a five-byte channel suffix"

    proc startApSweepChannel(channel: int): bool =
      let ssid = apSweepSsid(WifiSsid, channel)
      if not startApHttpSmoke(ssid, channel):
        discard wifiStopAp()
        return false
      apSweepOpen(apChannelSweep, channel)
      phaseMark(Phase.scan, Kind.info):
        kvWrite("bench", "ap_channels")
        kvWrite("event", "ready")
        kvWrite("channel", channel.uint32)
        kvWrite("ssid", ssid)
      true

    proc stopApSweepChannel(last: bool): bool =
      let ap = cast[ptr Netif](wifiGetApNetif())
      if ap == nil or dhcpServerStop(ap) != ErrOk: return false
      if wifiStopAp() != wifiOk: return false
      # Keep the listener across AP netif replacement. Old accepted or
      # TIME-WAIT connections can make a new bind to the same port fail.
      if last:
        if listenPcb == nil or tcpClose(listenPcb) != ErrOk: return false
        listenPcb = nil
      true

    proc apSweepTick() =
      if not apSweepAdvanceDue(apChannelSweep, nowMs()): return
      let finished = apChannelSweep.channel
      let last = finished == ApSweepLastChannel
      apChannelSweep.ready = false
      if not stopApSweepChannel(last):
        discard console.sendLine("[FAIL] AP sweep stop")
        return
      phaseMark(Phase.scan, Kind.info):
        kvWrite("bench", "ap_channels")
        kvWrite("event", "client_confirmed")
        kvWrite("channel", finished.uint32)
      if last:
        discard console.sendLine("[PASS] AP channel sweep complete")
      elif not startApSweepChannel(finished + 1):
        discard console.sendLine("[FAIL] AP sweep start")

proc connectWifiAndDhcp(): bool =
  if wifiInit() != wifiOk:
    phaseMark(Phase.scan, Kind.fail):
      kvWrite("reason", "init")
    return false
  discard bl_wifi_mac_addr_get(addr deviceMac[0])

  phaseMark(Phase.scan, Kind.start):
    kvWrite("mode", "auto")
  phaseMark(Phase.auth, Kind.start)
  let scanItemsBefore = bl808_wifi_backend_scan_count()
  if wifiConnect(WifiSsid, WifiPassword, 0'u8) != wifiOk:
    phaseMark(Phase.auth, Kind.fail):
      kvWrite("reason", "connect")
      kvWrite("status", bl808_wifi_backend_last_status())
      kvWrite("code", bl808_wifi_backend_last_reason())
      kvWrite("scan_done", bl808_wifi_backend_scan_done_count())
      kvWrite("scan_items", bl808_wifi_backend_scan_count())
    return false
  if not scanDiagHasFreshResult(scanItemsBefore, WifiSsid):
    phaseMark(Phase.scan, Kind.fail):
      kvWrite("reason", "no_scan_result")
      kvWrite("done", bl808_wifi_backend_scan_done_count())
      kvWrite("items", bl808_wifi_backend_scan_count())
      kvWrite("diag", bl808_wifi_backend_scan_diag_count())
    return false
  phaseMark(Phase.auth, Kind.ok)
  phaseMark(Phase.ph4whs, Kind.ok)
  phaseMark(Phase.assoc, Kind.ok)

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
      kvWrite("reason", "start")
      kvWrite("rc", dhcpRc.int32)
    return false

  let deadline = nowMs() + DhcpTimeoutMs
  while netifIp4(netif) == 0'u32:
    pollNetwork()
    if nowMs() >= deadline:
      phaseMark(Phase.dhcp, Kind.fail):
        kvWrite("reason", "timeout")
      return false

  let ip = netifIp4(netif)
  httpLastIp = ip
  httpLastGw = netifGw4(netif)
  phaseMark(Phase.dhcp, Kind.ok):
    kvWrite("ip", ip)
    kvWrite("gw", httpLastGw)
  discard console.sendString("HTTP server: http://")
  writeIp4(ip)
  discard console.sendString("/")
  discard console.sendLine("")
  true

when defined(bl808WifiBenchConnectedScanAB):
  static: doAssert not defined(bl808WifiApHttpSmoke)
  var wifiScanAbHome {.importc: "nimfw_dbg_home_wake_ab", volatile.}: array[7, uint32]
  proc wifiScanAbConfirmStatus(): uint32 {.importc: "bl808_wifi_backend_scan_confirmation", cdecl.}
  proc wifiScanAbWpaState(): uint32 {.importc: "bl808_wpa_current_state", cdecl.}
  include wifi_scan_ab_bench

proc main() {.exportc, cdecl.} =
  systemInit()
  initHttpPsram()
  heapInit()
  setupConsole()
  e2eMarkerInit(addr console)
  discard console.sendLine("")
  discard console.sendLine("=== BL808 WiFi HTTP Server ===")
  lwipInit()

  when defined(bl808WifiApHttpSmoke):
    if WifiSsid.len == 0 or WifiPassword.len notin 8..63 or wifiInit() != wifiOk:
      discard console.sendLine("[FAIL] AP smoke setup")
      return
    when defined(bl808WifiApChannelSweep):
      if not startApSweepChannel(ApSweepFirstChannel): return
    else:
      if not startApHttpSmoke(WifiSsid, WifiApBenchChannel):
        discard wifiStopAp()
        return
  else:
    if WifiSsid.len == 0:
      phaseMark(Phase.auth, Kind.fail):
        kvWrite("reason", "missing_ssid")
      discard console.sendLine("=== BL808 WiFi HTTP Server Stopped ===")
      return
    if not connectWifiAndDhcp() or not startHttpServer(HttpPort.uint16) or
        not startUdpEchoServer(UdpEchoPort.uint16):
      discard console.sendLine("=== BL808 WiFi HTTP Server Stopped ===")
      return
    discard console.sendLine("Ready for HTTP/1.1 and UDP echo client requests")
  when defined(bl808WifiBenchConnectedScanAB):
    var scanBench = ScanAbBench(readyAt: nowMs())
  while true:
    inc httpLoopTicks
    when not defined(bl808WifiApHttpSmoke):
      sendUdpProbe()
    pollNetwork()
    when defined(bl808WifiApChannelSweep):
      apSweepTick()
    when defined(bl808WifiBenchConnectedScanAB):
      scanAbTick(scanBench)
