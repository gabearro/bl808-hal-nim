## M0 WiFi lwIP smoke test (Iter 2.A.0 follow-up).
##
## Build with:
##   make m0 FILE=examples/m0_wifi_lwip_smoke.nim \
##     NIM="nim -d:bl808kernel -d:bl808WifiVendor \
##              -d:WifiSsid=Frog -d:WifiPassword=6509171272"
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
