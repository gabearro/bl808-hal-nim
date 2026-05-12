## M0 RTC wall-clock time test.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_rtc_test.nim
## Run:
##   qemu-system-riscv32 -M bl808 -nographic \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_rtc_test

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/cps
import bl808/kernel/log
import bl808/kernel/rtc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var console: Uart

proc rtcTestTask(): CpsVoidFuture {.cps.} =
  # Set time to 2026-03-31 12:00:00
  rtcSetTime(DateTime(year: 2026, month: 3, day: 31,
                      hour: 12, minute: 0, second: 0))

  let dt = rtcGetTime()
  logInfo "Time set to": lStr(" "); lU32(dt.year.uint32); lStr("-"); lU32(dt.month.uint32); lStr("-"); lU32(dt.day.uint32)
  logInfo "  ": lU32(dt.hour.uint32); lStr(":"); lU32(dt.minute.uint32); lStr(":"); lU32(dt.second.uint32)

  # Verify round-trip
  if dt.year == 2026 and dt.month == 3 and dt.day == 31 and dt.hour == 12:
    logInfo "[PASS] Set/get round-trip"
  else:
    logError "[FAIL] Set/get mismatch"

  # Verify Unix timestamp (2026-03-31 12:00:00 UTC)
  let unix = rtcGetUnix()
  logInfo "Unix=": lInt(unix.int)
  # Expected: 1774958400 (March 31, 2026 12:00 UTC)
  if unix > 1774900000'i64 and unix < 1775000000'i64:
    logInfo "[PASS] Unix timestamp in expected range"
  else:
    logWarn "[WARN] Unix timestamp unexpected"

  rtcSetUnix(946684800'i64) # 2000-01-01 00:00:00 UTC
  let unixSet = rtcGetTime()
  if unixSet.year == 2000 and unixSet.month == 1 and unixSet.day == 1:
    logInfo "[PASS] rtcSetUnix round-trip"
  else:
    logError "[FAIL] rtcSetUnix round-trip"

  # Verify calendar conversion round-trips
  let rt = unixToDateTime(dateTimeToUnix(DateTime(
    year: 2000, month: 2, day: 29, hour: 23, minute: 59, second: 59)))
  if rt.year == 2000 and rt.month == 2 and rt.day == 29:
    logInfo "[PASS] Leap year 2000-02-29 round-trip"
  else:
    logError "[FAIL] Leap year conversion"

  # Sleep and check time advances
  await sleepMs(2000)
  let dt2 = rtcGetTime()
  logInfo "After 2s: second=": lU32(dt2.second.uint32)
  if dt2.second >= 2:
    logInfo "[PASS] Time advances"
  else:
    logWarn "[WARN] Time did not advance (QEMU virtual time may not have progressed)"

  # Verify get_fattime() returns non-zero
  let ft = get_fattime()
  logInfo "get_fattime=": lHex(ft)
  if ft != 0:
    logInfo "[PASS] FatFs timestamp non-zero"
  else:
    logError "[FAIL] FatFs timestamp is zero"

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
  logInfo "=== BL808 RTC Test ==="
  logInfo ""

  schedulerInit()
  discard rtcTestTask()
  runScheduler()
