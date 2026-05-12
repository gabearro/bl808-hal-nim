## M0 watchdog test — verifies the WDT feed count increments.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_wdt_test.nim
## Run:
##   qemu-system-riscv32 -M bl808 -nographic \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_wdt_test

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart, bl808/timer
import bl808/kernel/cps
import bl808/kernel/log
import bl808/kernel/watchdog

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var console: Uart

proc wdtTestTask(): CpsVoidFuture {.cps.} =
  logInfo "WDT active=": lBool(watchdogIsActive())

  let feeds0 = watchdogFeedCount()
  logInfo "Initial feeds=": lU64(feeds0)

  await sleepMs(50)

  let feeds1 = watchdogFeedCount()
  logInfo "After 50ms feeds=": lU64(feeds1)

  await sleepMs(50)

  let feeds2 = watchdogFeedCount()
  logInfo "After 100ms feeds=": lU64(feeds2)

  if feeds2 > feeds0:
    logInfo "[PASS] WDT feeds incrementing (": lU64(feeds0); lStr(" -> "); lU64(feeds2); lStr(")")
  else:
    logError "[FAIL] WDT feeds not incrementing"

  watchdogDisable()
  if not watchdogIsActive() and watchdogCounter() == 0:
    logInfo "[PASS] WDT disable"
  else:
    logError "[FAIL] WDT disable"

  logInfo ""
  logInfo "=== Test Complete ==="

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  logInit(console)
  logInfo "=== BL808 Watchdog Test ==="
  logInfo ""

  schedulerInit()
  watchdogInit(timer0, timeoutMs = 5000)

  discard wdtTestTask()
  runScheduler()
