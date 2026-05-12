## M0 async SD/FatFs test.
##
## Exercises the scheduler-backed async SD wrappers on a QEMU SD card.

import bl808/startup
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc
import bl808/kernel/cps
import bl808/kernel/fatfs
import bl808/kernel/log
import bl808/kernel/asyncfs
import bl808/kernel/rtc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var console: Uart

proc asyncSdTask(): CpsVoidFuture {.cps.} =
  var fs: SdFs
  fs.init()
  if not fs.mounted:
    logError "[FAIL] Could not mount SD filesystem"
    return
  logInfo "[OK] SD filesystem mounted"

  discard fs.remove("async.txt")

  var f: Fil
  let openWrite = await asyncSdOpen(addr fs, addr f, "async.txt",
                                    faWrite or faCreateAlways)
  if openWrite != frOk:
    logError "[FAIL] asyncSdOpen write": lInt(openWrite.int)
    return

  var data = [0x41'u8, 0x73, 0x79, 0x6E, 0x63, 0x21] # "Async!"
  let written = await asyncSdWrite(addr fs, addr f,
    cast[ptr UncheckedArray[uint8]](addr data[0]), data.len)
  if written == data.len:
    logInfo "[PASS] asyncSdWrite"
  else:
    logError "[FAIL] asyncSdWrite"

  let closeWrite = await asyncSdClose(addr fs, addr f)
  if closeWrite == frOk:
    logInfo "[PASS] asyncSdClose write"
  else:
    logError "[FAIL] asyncSdClose write"

  var f2: Fil
  let openRead = await asyncSdOpen(addr fs, addr f2, "async.txt", faRead)
  if openRead != frOk:
    logError "[FAIL] asyncSdOpen read": lInt(openRead.int)
    return

  var buf: array[16, uint8]
  let readLen = await asyncSdRead(addr fs, addr f2,
    cast[ptr UncheckedArray[uint8]](addr buf[0]), buf.len)
  let closeRead = await asyncSdClose(addr fs, addr f2)

  var match = readLen == data.len and closeRead == frOk
  for i in 0 ..< data.len:
    if buf[i] != data[i]:
      match = false
  if match:
    logInfo "[PASS] asyncSdRead data verified"
  else:
    logError "[FAIL] asyncSdRead data mismatch"

  let removeErr = await asyncSdRemove(addr fs, "async.txt")
  if removeErr == frOk:
    logInfo "[PASS] asyncSdRemove"
  else:
    logError "[FAIL] asyncSdRemove"

  fs.deinit()
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
  logInfo "=== BL808 Async SD Test ==="
  logInfo ""

  schedulerInit()
  discard asyncSdTask()
  runScheduler()
