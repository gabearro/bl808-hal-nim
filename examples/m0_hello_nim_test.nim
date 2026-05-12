## Minimal Ox64 M0 UART smoke test.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_hello_nim_test.nim

import bl808/startup
import bl808/core, bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)

  let console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud,
    dataBits: data8,
    stopBits: stop1,
    parity: parityNone,
  ), ConsoleClkHz)

  for i in 0 ..< 50_000:
    discard regRead(GlbSocInfo0)

  for i in 0 ..< 8:
    discard console.sendLine("Hello from Nim!")
    for j in 0 ..< 300_000:
      discard regRead(GlbSocInfo0)

  while true:
    wfi()
