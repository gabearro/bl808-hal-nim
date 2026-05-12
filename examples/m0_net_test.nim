## M0 lwIP networking test — TCP echo server over EMAC.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_net_test.nim
## Run:
##   qemu-system-riscv32 -M bl808,net-phy=ip101g -nographic \
##     -nic user,model=bl808-emac,hostfwd=tcp::12345-:7 \
##     -kernel examples/m0_net_test
##
## Test from host:
##   echo "hello" | nc localhost 12345

import bl808/startup
import bl808/mmio, bl808/memmap, bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/irq
import bl808/kernel/cps
import bl808/kernel/emacdrv
import bl808/kernel/lwipcore
import bl808/kernel/netlwip

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32
  EchoPort = 7'u16
  MacAddr: array[6, uint8] = [0xDE'u8, 0xAD, 0xBE, 0xEF, 0x00, 0x01]

var console: Uart
var pollDrv: EmacDriver

# ---------------------------------------------------------------------------
# TCP echo server callbacks (lwIP raw API)
# ---------------------------------------------------------------------------

proc echoRecv(arg: pointer, tpcb: ptr TcpPcb, p: ptr Pbuf,
              err: ErrT): ErrT {.cdecl, exportc.} =
  if p == nil:
    discard console.sendLine("[NET] TCP connection closed")
    discard tcpClose(tpcb)
    return ErrOk
  let length = pbufTotLen(p)
  discard console.sendString("[NET] TCP recv ")
  console.sendHex32(length.uint32)
  discard console.sendLine(" bytes, echoing back")
  # Echo the data back
  let payload = pbufPayload(p)
  let writeErr = tcpWrite(tpcb, payload, length, TcpWriteFlagCopy)
  discard tcpOutput(tpcb)
  tcpRecved(tpcb, length)
  discard pbufFree(p)
  ErrOk

proc echoSent(arg: pointer, tpcb: ptr TcpPcb, len: uint16): ErrT {.cdecl.} =
  ErrOk

proc echoErr(arg: pointer, err: ErrT) {.cdecl.} =
  discard console.sendString("[NET] TCP err callback err=")
  console.sendHex32(err.uint32)
  discard console.sendLine("")

proc echoAccept(arg: pointer, newpcb: ptr TcpPcb,
                err: ErrT): ErrT {.cdecl, exportc.} =
  discard console.sendLine("[NET] New TCP connection accepted!")
  tcpArg(newpcb, nil)
  tcpRecv(newpcb, echoRecv)
  tcpSent(newpcb, echoSent)
  tcpErr(newpcb, echoErr)
  ErrOk

proc arpOutputWrapper(netif: ptr Netif, p: ptr Pbuf, ipaddr: ptr IpAddr): ErrT {.cdecl.} =
  etharpOutput(netif, p, ipaddr)

proc udpRecvCb(arg: pointer, pcb: ptr UdpPcb, p: ptr Pbuf,
               remoteAddr: ptr IpAddr, port: uint16) {.cdecl.} =
  if p != nil:
    discard pbufFree(p)

proc startUdpProbe() =
  let udp = udpNew()
  if udp == nil:
    discard console.sendLine("[NET] UDP probe allocation skipped")
    return
  var anyAddr = ipAddrAny()
  discard udpBind(udp, addr anyAddr, 9)
  udpRecv(udp, udpRecvCb, nil)

  var dst: IpAddr
  ipAddrSet(dst, ip4Addr(10, 0, 2, 2).address)
  let p = pbufAlloc(pbufTransport, 1, pbufRam)
  if p != nil:
    var payload = [0x55'u8]
    discard pbufTake(p, addr payload[0], payload.len.uint16)
    discard udpSendto(udp, p, addr dst, 9)
    discard pbufFree(p)
  udpRemove(udp)
  discard console.sendLine("[NET] UDP raw API probe")

proc startTcpAbortProbe() =
  let pcb = tcpNew()
  if pcb != nil:
    tcpAbort(pcb)
    discard console.sendLine("[NET] TCP abort API probe")

proc startEchoServer() =
  let pcb = tcpNew()
  if pcb == nil:
    discard console.sendLine("[NET] ERROR: tcp_new failed!")
    return
  var anyAddr = ipAddrAny()
  let bindErr = tcpBind(pcb, addr anyAddr, EchoPort)
  if bindErr != ErrOk:
    discard console.sendString("[NET] ERROR: tcp_bind failed: ")
    console.sendHex32(bindErr.uint32)
    discard console.sendLine("")
    return
  let listenPcb = tcpListen(pcb)
  if listenPcb == nil:
    discard console.sendLine("[NET] ERROR: tcp_listen failed!")
    return
  tcpAccept(listenPcb, echoAccept)
  startTcpAbortProbe()
  discard console.sendLine("[NET] TCP echo server listening on port 7")

# ---------------------------------------------------------------------------
# DHCP status callback
# ---------------------------------------------------------------------------

proc dhcpStatusCb(netif: ptr Netif) {.cdecl.} =
  discard console.sendString("[NET] Interface status changed, rxPkts=")
  console.sendHex32(rxPacketsProcessed.uint32)
  discard console.sendString(" emacIsr=")
  console.sendHex32(emacIsrCount.uint32)
  discard console.sendLine("")

proc emacAsyncProbe(drv: EmacDriver): CpsVoidFuture {.cps.} =
  var frame: array[60, uint8]
  for i in 0 ..< 6:
    frame[i] = 0xFF'u8
    frame[6 + i] = MacAddr[i]
  frame[12] = 0x88'u8
  frame[13] = 0xB5'u8
  frame[14] = 0x01'u8

  try:
    discard await withTimeout(drv.sendAsync(frame), 1000)
    discard console.sendLine("[PASS] EMAC sendAsync")
  except CatchableError:
    discard console.sendLine("[WARN] EMAC sendAsync timeout")

  emacPoll(drv)
  try:
    discard await withTimeout(drv.recvAsync(), 5000)
    discard console.sendLine("[PASS] EMAC recvAsync")
  except CatchableError:
    discard console.sendLine("[WARN] EMAC recvAsync no frame")

proc emacPollHook() =
  if pollDrv != nil:
    emacPoll(pollDrv)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 lwIP Networking Test ===")

  heapInit()
  schedulerInit()

  discard console.sendLine("[OK] Kernel initialized")

  # Initialize EMAC
  let drv = emacDriverInit(MacAddr)
  pollDrv = drv
  discard console.sendLine("[OK] EMAC driver initialized")
  addSchedulerPollHook(emacPollHook)

  # QEMU user networking forwards to 10.0.2.15 by convention.
  discard networkTaskStatic(drv, MacAddr,
    ip4Addr(10, 0, 2, 15),
    ip4Addr(255, 255, 255, 0),
    ip4Addr(10, 0, 2, 2))

  let n = netlwipNetif()
  netifSetStatusCallback(n, dhcpStatusCb)
  netifSetOutput(n, arpOutputWrapper)
  startUdpProbe()

  # Start TCP echo server
  startEchoServer()
  discard emacAsyncProbe(drv)

  discard console.sendLine("[OK] Entering scheduler")
  discard console.sendLine("")

  # Diagnostic task — prints network status every 2 seconds
  proc diagTask(): CpsVoidFuture {.cps.} =
    while true:
      await sleepMs(2000)
      discard console.sendString("[NET] rx=")
      console.sendHex32(rxPacketsProcessed.uint32)
      discard console.sendString(" isr=")
      console.sendHex32(emacIsrCount.uint32)
      # Print IP address from lwIP netif
      {.emit: """
      {
        extern struct netif lwipNetif__OOZsrcZbl808ZkernelZnetlwip_u7;
        struct netif *n = &lwipNetif__OOZsrcZbl808ZkernelZnetlwip_u7;
        volatile unsigned int *uart = (volatile unsigned int *)0x2000A088UL;
        uart[0] = ' '; uart[0] = 'I'; uart[0] = 'P'; uart[0] = '=';
        unsigned int ip = n->ip_addr.addr;
        static const char hx[] = "0123456789ABCDEF";
        for (int i = 7; i >= 0; i--) uart[0] = hx[(ip >> (i*4)) & 0xF];
      }
      """.}
      discard console.sendLine("")

  discard diagTask()

  discard console.sendLine("[OK] Entering scheduler")
  discard console.sendLine("")

  runScheduler()
