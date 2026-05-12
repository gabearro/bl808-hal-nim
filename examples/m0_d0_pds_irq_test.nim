## M0 helper for the D0 PDS IRQ routing test.
##
## Powers on the MM domain so the D0 firmware can boot, then idles while the
## host injects a PDS wake event over QMP.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/pds

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32

var console: Uart

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 D0 PDS IRQ Helper (M0) ===")
  discard console.sendLine("[M0] Powering on MM domain")
  pdsPowerOnMmSystem()
  releaseD0()
  discard console.sendLine("[M0] MM domain on; waiting for host-triggered PDS wake")

  while true:
    wfi()
