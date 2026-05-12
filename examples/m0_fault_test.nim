## M0 fault diagnostics and guardrail smoke test.
##
## Exercises the non-halting fault record APIs and verifies that systemInit()
## installed the stack sentinel before the scheduler starts.

import bl808/startup
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/cps
import bl808/kernel/boothealth
import bl808/kernel/fault
import bl808/kernel/log

proc cMalloc(size: csize_t): pointer {.importc: "malloc", cdecl.}
proc cFree(p: pointer) {.importc: "free", cdecl.}

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var console: Uart

proc check(label: string, ok: bool) =
  if ok:
    logInfo "[PASS] ": lStr(label)
  else:
    logError "[FAIL] ": lStr(label)

proc faultTask(): CpsVoidFuture {.cps.} =
  check("Stack guard initialized", stackGuardOk())
  check("Stack usage measured", stackBytesUsed() > 0'u)
  let boot0 = bootHealthSnapshot()
  check("Boot health record valid",
        bootHealthRecordValid() and boot0.magic == BootHealthMagic and
        boot0.version == BootHealthVersion and boot0.bootCount >= 1'u32)
  bootHealthClear()
  check("Boot health clear", not bootHealthRecordValid())
  bootHealthInit()
  check("Boot health reinitialized", bootHealthRecordValid())
  check("Heap check initial", heapCheck())

  faultClearRecord()
  check("Fault record cleared", not faultRecordValid())

  faultRecord(FaultReasonManual, 0x11'u, 0x22'u, 0x33'u)
  bootHealthCaptureFaultSnapshot()
  let rec = faultRecordSnapshot()
  check("Fault record persisted",
        rec.magic == FaultMagic and rec.version == FaultVersion and
        rec.reason == FaultReasonManual and rec.causeLo == 0x11'u32 and
        rec.epcLo == 0x22'u32 and rec.tvalLo == 0x33'u32)
  check("Fault record includes stack bounds",
        rec.stackStart != 0'u32 and rec.stackEnd > rec.stackStart)
  let bootFault = bootHealthSnapshot()
  check("Boot health captured fault record",
        bootHealthRecordValid() and
        (bootFault.flags and BootHealthFlagPreviousFault) != 0'u32 and
        bootFault.previousFaultReason == FaultReasonManual and
        bootFault.previousFaultCauseLo == 0x11'u32 and
        bootFault.previousFaultEpcLo == 0x22'u32 and
        bootFault.previousFaultTvalLo == 0x33'u32)

  check("Stack guard still intact", faultCheckStackGuard())

  let heap0 = heapStats()
  let p = cMalloc(32)
  check("Heap allocation succeeds", p != nil)
  if p != nil:
    let data = cast[ptr UncheckedArray[uint8]](p)
    for i in 0 ..< 32:
      data[i] = i.uint8
    let heap1 = heapStats()
    check("Heap high-water tracked",
          heap1.highWaterBytes >= heap1.usedBytes and heap1.allocCount > heap0.allocCount)
    cFree(p)
  check("Heap check after free", heapCheck())

  let failBefore = heapStats().allocFailCount
  let huge = cMalloc((heapStats().totalBytes + 1024'u * 1024'u).csize_t)
  check("Heap allocation failure tracked",
        huge == nil and heapStats().allocFailCount == failBefore + 1)

  let canaryBefore = heapStats().canaryFailCount
  let q = cMalloc(8)
  if q != nil:
    let data = cast[ptr UncheckedArray[uint8]](q)
    data[8] = 0xAA'u8
    cFree(q)
  check("Heap tail canary detects overrun",
        q != nil and heapStats().canaryFailCount == canaryBefore + 1 and heapCheck())

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
    baudRate: ConsoleBaud,
    dataBits: data8,
    stopBits: stop1,
    parity: parityNone,
  ), ConsoleClkHz)

  logInit(console)
  logInfo "=== BL808 Fault Diagnostics Test ==="
  logInfo ""

  schedulerInit()
  discard faultTask()
  runScheduler()
