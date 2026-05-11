## M0 WiFi NimFw boot probe (Iter 2.A.3).
##
## Probes whether wifi_fw.nim reimpl bl_init reaches its sentinel
## without crashing. Calls only wifiInit().

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/timer
import bl808/wifi
import bl808/panicoverride
import bl808/kernel/alloc

proc disableM0Wdt() =
  let t = initTimer(timer0)
  wdtDisable(t)

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

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

proc main() {.exportc, cdecl.} =
  systemInit()
  disableM0Wdt()
  heapInit()
  setupConsole()
  discard console.sendLine("")
  discard console.sendLine("=== BL808 WiFi NimFw Boot Probe ===")
  discard console.sendLine("[DBG] WDT disabled, entering wifiInit")

  let rc = wifiInit()
  when defined(bl808WifiNimFw):
    discard console.sendLine("[WIFI-NIMFW] bl_init done")

  if rc == wifiOk:
    discard console.sendLine("[PASS] wifi nimfw init")
  else:
    discard console.sendString("[FAIL] wifi nimfw init rc=")
    console.sendHex32(cast[uint32](rc.int32))
    discard console.sendLine("")

  discard console.sendLine("=== BL808 NimFw Boot Probe Complete ===")
  while true:
    discard

main()
