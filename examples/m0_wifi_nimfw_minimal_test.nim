## Minimal nimfw control: build with -d:bl808WifiNimFw but don't call wifiInit.
## Just banner + forever loop. If this boot-loops, the issue isn't wifiInit at
## all — it's something in the nimfw modules' static init / global ctors.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/wifi
import bl808/panicoverride
import bl808/kernel/alloc

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
  heapInit()
  setupConsole()
  var counter = 0'u32
  while true:
    discard console.sendString("[NIMFW-MIN] alive tick=")
    console.sendHex32(counter)
    discard console.sendLine("")
    inc counter
    for _ in 0 .. 4_000_000:
      discard

main()
