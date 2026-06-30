## M0 SD swap-file safety test.
##
## Mounts the existing FatFs/exFAT volume without formatting, creates/verifies a
## sentinel file, writes and reads a dedicated BL808 swap file, then verifies the
## sentinel is unchanged. No raw sectors are written.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc
import bl808/kernel/fatfs
import bl808/kernel/sdblk
import bl808/kernel/sd_swap_file

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  SwapDir = "bl808swap_safe"
  SentinelPath = "bl808swap_safe/keep.dat"
  SwapPath = "bl808swap_safe/test.swap"
  SentinelMagic = 0x4C46_534B'u32 # "LFSK"
  SwapSlots = 2'u32

var console: Uart
var page: array[SdSwapPageBytes.int, uint8]

proc line(s: string) =
  discard console.sendLine(s)

proc fail(label: string, value: uint32 = 0) =
  discard console.sendString("[FAIL] ")
  discard console.sendString(label)
  if value != 0:
    discard console.sendString(" value=")
    console.sendHex32(value)
  discard console.sendString(" sd_phase=")
  console.sendHex32(sdLastPhase)
  discard console.sendString(" sd_err=")
  console.sendHex32(sdLastError.ord.uint32)
  discard console.sendLine("")

proc pass(label: string) =
  discard console.sendString("[PASS] ")
  discard console.sendLine(label)

proc put32(buf: var openArray[uint8], off: int, value: uint32) =
  buf[off + 0] = (value and 0xFF'u32).uint8
  buf[off + 1] = ((value shr 8) and 0xFF'u32).uint8
  buf[off + 2] = ((value shr 16) and 0xFF'u32).uint8
  buf[off + 3] = ((value shr 24) and 0xFF'u32).uint8

proc get32(buf: openArray[uint8], off: int): uint32 =
  buf[off + 0].uint32 or
    (buf[off + 1].uint32 shl 8) or
    (buf[off + 2].uint32 shl 16) or
    (buf[off + 3].uint32 shl 24)

proc writeSentinel(fs: var SdFs, openStatus: var FResult, seekStatus: var FResult,
                   wroteBytes: var int, syncStatus: var FResult,
                   closeStatus: var FResult): bool =
  var f: Fil
  openStatus = fs.open(f, SentinelPath, faWrite or faCreateAlways)
  if openStatus != frOk:
    seekStatus = frInvalidObject
    wroteBytes = -1
    syncStatus = frInvalidObject
    closeStatus = frInvalidObject
    return false
  seekStatus = fs.seek(f, 0)
  if seekStatus != frOk:
    closeStatus = fs.close(f)
    wroteBytes = -1
    syncStatus = frInvalidObject
    return false
  var data: array[32, uint8]
  put32(data, 0, SentinelMagic)
  put32(data, 4, 0x1234_5678'u32)
  wroteBytes = fs.write(f, data)
  syncStatus = fs.sync(f)
  closeStatus = fs.close(f)
  wroteBytes == data.len and syncStatus == frOk and closeStatus == frOk

proc readSentinelDetailed(fs: var SdFs, value: var uint32,
                          openStatus: var FResult, gotBytes: var int,
                          closeStatus: var FResult): bool =
  var f: Fil
  openStatus = fs.open(f, SentinelPath, faRead or faOpenExisting)
  if openStatus != frOk:
    value = 0
    gotBytes = -1
    closeStatus = frInvalidObject
    return false
  openStatus = fs.seek(f, 0)
  if openStatus != frOk:
    value = 0
    gotBytes = -1
    closeStatus = fs.close(f)
    return false
  var data: array[32, uint8]
  gotBytes = fs.read(f, data)
  closeStatus = fs.close(f)
  if gotBytes != data.len or closeStatus != frOk:
    value = 0
    return false
  value = get32(data, 0) xor get32(data, 4)
  value == (SentinelMagic xor 0x1234_5678'u32)

proc failSentinel(label: string, value: uint32, openStatus: FResult,
                  gotBytes: int, closeStatus: FResult) =
  discard console.sendString("[FAIL] ")
  discard console.sendString(label)
  discard console.sendString(" value=")
  console.sendHex32(value)
  discard console.sendString(" open=")
  console.sendHex32(openStatus.ord.uint32)
  discard console.sendString(" read=")
  console.sendHex32(gotBytes.uint32)
  discard console.sendString(" close=")
  console.sendHex32(closeStatus.ord.uint32)
  discard console.sendString(" sd_phase=")
  console.sendHex32(sdLastPhase)
  discard console.sendString(" sd_err=")
  console.sendHex32(sdLastError.ord.uint32)
  discard console.sendLine("")

proc failSentinelWrite(label: string, openStatus: FResult, seekStatus: FResult,
                       wroteBytes: int, syncStatus: FResult,
                       closeStatus: FResult) =
  discard console.sendString("[FAIL] ")
  discard console.sendString(label)
  discard console.sendString(" open=")
  console.sendHex32(openStatus.ord.uint32)
  discard console.sendString(" seek=")
  console.sendHex32(seekStatus.ord.uint32)
  discard console.sendString(" wrote=")
  console.sendHex32(wroteBytes.uint32)
  discard console.sendString(" sync=")
  console.sendHex32(syncStatus.ord.uint32)
  discard console.sendString(" close=")
  console.sendHex32(closeStatus.ord.uint32)
  discard console.sendString(" sd_phase=")
  console.sendHex32(sdLastPhase)
  discard console.sendString(" sd_err=")
  console.sendHex32(sdLastError.ord.uint32)
  discard console.sendLine("")

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
  line("=== BL808 SD Swap File Safety Test ===")

  var fs: SdFs
  let mountStatus = fs.mount()
  if mountStatus != frOk:
    fail("mount existing filesystem without format", mountStatus.uint32)
    while true: wfi()
  pass("mounted existing filesystem without format")

  let mkdirStatus = fs.mkdir(SwapDir)
  if mkdirStatus != frOk and mkdirStatus != frExist:
    fail("create swap safety directory", mkdirStatus.uint32)
    while true: wfi()
  pass("swap safety directory ready")

  discard fs.remove(SentinelPath)
  discard fs.remove(SwapPath)

  var sentOpen: FResult
  var sentSeek: FResult
  var sentWrote: int
  var sentSync: FResult
  var sentClose: FResult
  if not writeSentinel(fs, sentOpen, sentSeek, sentWrote, sentSync, sentClose):
    failSentinelWrite("write sentinel before swap", sentOpen, sentSeek, sentWrote, sentSync, sentClose)
    while true: wfi()

  var before: uint32
  var beforeOpen: FResult
  var beforeGot: int
  var beforeClose: FResult
  if not readSentinelDetailed(fs, before, beforeOpen, beforeGot, beforeClose):
    failSentinel("sentinel before swap", before, beforeOpen, beforeGot, beforeClose)
    while true: wfi()
  if before != (SentinelMagic xor 0x1234_5678'u32):
    failSentinel("sentinel before swap", before, beforeOpen, beforeGot, beforeClose)
    while true: wfi()
  pass("sentinel file prepared")

  var swap: SdSwapFile
  let openSwap = sdSwapOpenOrCreate(fs, swap, SwapPath, SwapSlots)
  if openSwap != sdSwapOk:
    fail("open/create dedicated swap file", openSwap.ord.uint32)
    while true: wfi()
  pass("dedicated swap file opened safely")

  for i in 0 ..< page.len:
    page[i] = (i and 0xFF).uint8
  put32(page, 0, 0x5357_4150'u32) # "SWAP"
  let writePage = sdSwapWritePage(fs, swap, 1, cast[ptr UncheckedArray[uint8]](addr page[0]))
  if writePage != sdSwapOk:
    fail("write swap slot", writePage.ord.uint32)
    while true: wfi()

  for i in 0 ..< page.len:
    page[i] = 0
  let readPage = sdSwapReadPage(fs, swap, 1, cast[ptr UncheckedArray[uint8]](addr page[0]))
  if readPage != sdSwapOk or get32(page, 0) != 0x5357_4150'u32 or page[257] != 1'u8:
    fail("read swap slot", readPage.ord.uint32)
    while true: wfi()
  pass("swap slot read/write round trip")

  let closeSwap = sdSwapClose(fs, swap)
  if closeSwap != sdSwapOk:
    fail("close swap file", closeSwap.ord.uint32)
    while true: wfi()

  var after: uint32
  var openStatus: FResult
  var gotBytes: int
  var closeStatus: FResult
  if not readSentinelDetailed(fs, after, openStatus, gotBytes, closeStatus):
    failSentinel("sentinel preserved after swap", after, openStatus, gotBytes, closeStatus)
    while true: wfi()
  if after != before:
    failSentinel("sentinel preserved after swap", after, openStatus, gotBytes, closeStatus)
    while true: wfi()
  pass("existing non-swap file preserved")

  fs.deinit()
  line("=== Test Complete ===")
  while true:
    wfi()
