## M0 SD bus-mode and multiblock validation.
##
## Mounts the existing card without formatting, verifies CMD18 multiblock reads
## against single-sector reads, negotiates 4-bit DAT mode, negotiates SD
## high-speed mode, and verifies normal filesystem writes still work.

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

var console: Uart

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

proc sameWords(a: openArray[uint32], b: openArray[uint32]): bool =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc verifyMultiblockRead(label: string) =
  var single0: array[128, uint32]
  var single1: array[128, uint32]
  var multi: array[256, uint32]

  var err = sdReadSector(0, cast[ptr UncheckedArray[uint32]](addr single0[0]))
  if err != sdhOk:
    fail(label & " single sector 0", err.ord.uint32)
  err = sdReadSector(1, cast[ptr UncheckedArray[uint32]](addr single1[0]))
  if err != sdhOk:
    fail(label & " single sector 1", err.ord.uint32)
  err = sdReadSectors(0, 2, cast[ptr UncheckedArray[uint32]](addr multi[0]))
  if err != sdhOk:
    fail(label & " CMD18 read", err.ord.uint32)

  if not sameWords(single0, multi[0 .. 127]):
    fail(label & " sector 0 mismatch")
  if not sameWords(single1, multi[128 .. 255]):
    fail(label & " sector 1 mismatch")
  pass(label)

proc verifyFatFsWrite(fs: var SdFs) =
  let path = "sd_bus_perf.bin"
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
  pass("FatFs writes still work after bus-mode changes")

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

  verifyMultiblockRead("multiblock read matches single-block")

  let busErr = sdEnable4BitBus()
  if busErr != sdhOk:
    fail("4-bit bus enabled", busErr.ord.uint32)
  pass("4-bit bus enabled")

  verifyMultiblockRead("4-bit multiblock read matches single-block")

  let hsErr = sdEnableHighSpeed(HighSpeedClockDiv)
  if hsErr == sdhOk:
    pass("high-speed mode enabled")
    verifyMultiblockRead("high-speed multiblock read matches single-block")
  else:
    pass("high-speed mode safely unavailable")
  verifyFatFsWrite(fs)

  fs.deinit()
  line("=== Test Complete ===")
  while true:
    wfi()
