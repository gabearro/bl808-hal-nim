## M0 WiFi end-to-end soak test (Iteration 1: scan -> assoc only).
##
## Build with:
##   make m0 FILE=examples/m0_wifi_e2e_test.nim \
##     NIM="nim -d:bl808kernel -d:bl808WifiVendor \
##              -d:WifiSsid=Frog -d:WifiPassword=6509171272"
##
## (`-d:bl808kernel` matches the validation harness path that brings in the
## kernel allocator the WiFi vendor blob requires.)
##
## At runtime emits structured `@e2e ...` markers consumed by tools/hw_e2e.py.
## Iteration 1 collapses scan/auth/4whs/assoc into the single wifiConnect call;
## finer-grained per-phase detection lands in later iterations.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/mmio
import bl808/wifi
import bl808/panicoverride
import bl808/kernel/alloc
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
  # Iteration 1 collapses scan/auth/4whs/assoc into wifiConnect.
  phaseMark(Phase.scan, Kind.start)
  let initRc = wifiInit()
  if initRc != wifiOk:
    phaseMark(Phase.scan, Kind.fail):
      kvWrite("reason", "init_failed")
    return false
  phaseMark(Phase.scan, Kind.ok)

  phaseMark(Phase.auth, Kind.start)
  # wifiConnect blocks until association succeeds or fails (vendor blob
  # polling loop inside).
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
  discard console.sendLine("=== BL808 WiFi E2E Soak Test ===")
  e2eRun(AttemptsTotal, runOneAttempt, deinitForRetry)
  discard console.sendLine("=== BL808 E2E Test Complete ===")

main()
