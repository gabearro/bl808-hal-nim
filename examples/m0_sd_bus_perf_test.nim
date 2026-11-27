## M0 SD bus-mode and multiblock validation.
##
## Mounts the existing card without formatting and checks CMD17 and CMD18
## against known file contents. Exercises 1-bit, 4-bit, and SD high-speed modes
## and verifies that normal filesystem writes still work.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/sdh
import bl808/kernel/alloc
import bl808/kernel/fatfs
import bl808/kernel/sdblk

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  HighSpeedClockDiv {.intdefine.} = 16'u32
  ScratchPath = "sd_bus_perf.bin"
  TestSectors = 9
  WordsPerSector = 128

var console: Uart
var testRead: array[TestSectors * WordsPerSector, uint32]
var testData: array[TestSectors * WordsPerSector, uint32]

proc line(s: string) =
  discard console.sendLine(s)

proc pass(label: string) =
  discard console.sendString("[PASS] ")
  discard console.sendLine(label)

proc fail(label: string, value: uint32 = 0) =
  when defined(sdDiagNoFailMarker):
    discard console.sendString("[DIAGFAIL] ")
  else:
    discard console.sendString("[FAIL] ")
  discard console.sendString(label)
  discard console.sendString(" value=")
  console.sendHex32(value)
  discard console.sendString(" sd_phase=")
  console.sendHex32(sdLastPhase)
  discard console.sendString(" sd_err=")
  console.sendHex32(sdLastError.ord.uint32)
  discard console.sendString(" sd_cmd=")
  console.sendHex32(sdLastCommand)
  discard console.sendString(" sd_sector=")
  console.sendHex32(sdLastSector)
  discard console.sendString(" sd_int=")
  console.sendHex32(sdLastIntStatus)
  discard console.sendString(" sd_state=")
  console.sendHex32(sdLastPresentState)
  discard console.sendString(" sd_adma_err=")
  console.sendHex32(sdLastAdmaError)
  discard console.sendString(" sd_adma_addr=")
  console.sendHex32(sdLastAdmaAddress)
  discard console.sendString(" sd_blkcnt=")
  console.sendHex32(sdLastBlockCount)
  discard console.sendString(" sd_desc_attr=")
  console.sendHex32(sdLastAdmaDescAttr)
  discard console.sendString(" sd_desc_len=")
  console.sendHex32(sdLastAdmaDescLen)
  discard console.sendString(" sd_desc_data=")
  console.sendHex32(sdLastAdmaDescData)
  discard console.sendString(" sd_data0=")
  console.sendHex32(sdLastAdmaData0)
  discard console.sendString(" sd_data1=")
  console.sendHex32(sdLastAdmaData1)
  discard console.sendLine("")
  while true:
    wfi()

proc prepareReadFixture(fs: var SdFs): uint32 =
  ## Resolve the physical sectors of the existing test's scratch file.
  discard fs.remove(ScratchPath)
  var f: Fil
  let openErr = fs.open(f, ScratchPath, faWrite or faCreateAlways)
  if openErr != frOk:
    fail("opened ADMA read fixture", openErr.ord.uint32)
  for i in 0 ..< testData.len:
    testData[i] = 0x9E3779B9'u32 * (i + 1).uint32
  let bytes = cast[ptr UncheckedArray[uint8]](addr testData[0])
  for sector in 0 ..< TestSectors:
    let offset = sector * 512
    if fs.write(f, bytes.toOpenArray(offset, offset + 511)) != 512:
      fail("wrote known ADMA read fixture sector", sector.uint32)
  if fs.sync(f) != frOk:
    fail("wrote known ADMA read fixture")
  result = f.physicalSector(1)
  if result == 0:
    fail("resolved physical sector of ADMA read fixture")
  for i in 1 ..< TestSectors:
    if f.physicalSector((i * 512 + 1).uint64) != result + i.uint32:
      fail("ADMA read fixture is contiguous", i.uint32)
  if fs.close(f) != frOk:
    fail("closed ADMA read fixture")

proc verifyAdmaRead(sector, count: uint32; label: string) =
  let before = sdAdmaReadOps
  let err = sdReadSectors(sector, count, cast[ptr UncheckedArray[uint32]](addr testRead[0]))
  if err != sdhOk or sdAdmaReadOps - before != count:
    fail(label, err.ord.uint32)
  for i in 0 ..< count.int * WordsPerSector:
    if testRead[i] != testData[i]:
      discard console.sendString("DMA word ")
      console.sendHex32(testRead[i])
      discard console.sendString(" expected ")
      console.sendHex32(testData[i])
      line("")
      fail("ADMA read data mismatch at word", i.uint32)
  pass(label)

proc verifyFatFsWrite(fs: var SdFs; label: string) =
  let path = ScratchPath
  discard fs.remove(path)

  var f: Fil
  var err = fs.open(f, path, faWrite or faCreateAlways)
  if err != frOk:
    fail("FatFs multiblock-backed open", err.uint32)

  var data: array[1536, uint8]
  for i in 0 ..< data.len:
    data[i] = ((i * 17 + 3) and 0xFF).uint8

  let written = fs.write(f, data)
  if written != data.len:
    fail("FatFs multiblock-backed write", written.uint32)
  err = fs.sync(f)
  if err != frOk:
    fail("FatFs multiblock-backed sync", err.uint32)
  err = fs.close(f)
  if err != frOk:
    fail("FatFs multiblock-backed close", err.uint32)

  var r: Fil
  err = fs.open(r, path, faRead)
  if err != frOk:
    fail("FatFs multiblock-backed reopen", err.uint32)
  var readback: array[1536, uint8]
  let n = fs.read(r, readback)
  discard fs.close(r)
  if n != data.len:
    fail("FatFs multiblock-backed read length", n.uint32)
  for i in 0 ..< data.len:
    if readback[i] != data[i]:
      fail("FatFs multiblock-backed read data", i.uint32)
  discard fs.remove(path)
  pass(label)

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

  line("")
  line("=== BL808 SD Bus/Multiblock Test ===")

  var fs: SdFs
  let mountStatus = fs.mount()
  if mountStatus != frOk:
    fail("mounted existing filesystem without format", mountStatus.uint32)
  pass("mounted existing filesystem without format")

  verifyFatFsWrite(fs, "Default-speed FatFs write/read through ADMA")
  let fixture = prepareReadFixture(fs)
  verifyAdmaRead(fixture, 1, "CMD17 ADMA read matches known data")
  verifyAdmaRead(fixture, 2, "CMD18 ADMA read matches known data")
  verifyAdmaRead(fixture, TestSectors, "1-bit ADMA read across the bounce buffer boundary")

  let busErr = sdEnable4BitBus()
  if busErr != sdhOk:
    fail("4-bit bus enabled", busErr.ord.uint32)
  pass("4-bit bus enabled")

  verifyAdmaRead(fixture, 2, "4-bit CMD18 ADMA read matches known data")

  let hsErr = sdEnableHighSpeed(HighSpeedClockDiv)
  if hsErr == sdhOk:
    pass("high-speed mode enabled")
    verifyAdmaRead(fixture, 2, "high-speed CMD18 ADMA read matches known data")
    verifyAdmaRead(fixture, TestSectors, "high-speed ADMA read across the bounce buffer boundary")
  else:
    pass("high-speed mode safely unavailable")
  verifyFatFsWrite(fs, "FatFs writes still work after bus-mode changes")

  fs.deinit()
  line("=== Test Complete ===")
  while true:
    wfi()
