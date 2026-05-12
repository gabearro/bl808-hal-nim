## M0 logging framework test.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_log_test.nim
## Run:
##   qemu-system-riscv32 -M bl808 -nographic \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_log_test
##
## Test filtering:
##   nim c -d:bl808m0 -d:logLevel=0 examples/m0_log_test.nim  # all levels
##   nim c -d:bl808m0 -d:logLevel=3 examples/m0_log_test.nim  # error only

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/log

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  gpioSetupUart(14, 15)
  var console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  logInit(console)

  logInfo "=== BL808 Log Framework Test ==="
  logInfo ""
  logInfo "Current logLevel=": lInt(logLevel)
  logInfo ""

  # Simple messages at each level
  logDebug "This is a debug message"
  logDebug "debug value=": lInt(7)
  logInfo "This is an info message"
  logWarn "This is a warning message"
  logError "This is an error message"
  logInfo ""

  # Integer formatting
  logInfo "positive=": lInt(42)
  logInfo "negative=": lInt(-7)
  logInfo "zero=": lInt(0)
  logInfo "u32 max=": lU32(0xFFFFFFFF'u32)
  logInfo "u64=": lU64(1_000_000_000'u64)
  logInfo ""

  # Hex formatting
  logInfo "hex=": lHex(0xDEADBEEF'u32)
  logInfo "hex zero=": lHex(0'u32)
  logInfo ""

  # Bool
  logInfo "true=": lBool(true); lStr(" false="); lBool(false)
  logInfo ""

  # Multiple values in one line
  logInfo "multi": lStr(" a="); lInt(1); lStr(" b="); lInt(2); lStr(" c="); lInt(3)
  logInfo ""

  # Typical real-world usage
  let taskCount = 5
  let heapUsed = 8192
  let heapFree = 212992
  logInfo "[SCHED] tasks=": lInt(taskCount)
  logInfo "[MEM] used=": lInt(heapUsed); lStr(" free="); lInt(heapFree)
  logWarn "[MEM] low memory threshold"
  logError "[FS] mount failed, err=": lInt(-5)
  logInfo ""

  logInfo "=== Test Complete ==="

  while true: wfi()
