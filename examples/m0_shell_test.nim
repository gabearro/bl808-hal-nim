## M0 interactive debug shell.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_shell_test.nim
## Run:
##   qemu-system-riscv32 -M bl808 -nographic \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_shell_test
##
## Type 'help' for available commands.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart, bl808/irq
import bl808/kernel/cps
import bl808/kernel/log
import bl808/kernel/asyncuart
import bl808/kernel/shell

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32

var console: Uart

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enablePeriphClock(periphUart0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  logInit(console)
  schedulerInit()

  let au = initAsyncUart(console, IrqM0Uart0, 0)
  discard shellTask(au)
  runScheduler()
