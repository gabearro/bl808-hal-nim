## M0 reporter for the D0 Sv39 SD-backed swap smoke test.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/fatfs
import bl808/kernel/alloc
import bl808/kernel/sd_swap_file

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

  StatusAddr = XramBase + 0x3E00'u
  FailCodeAddr = XramBase + 0x3D04'u
  FailGotAddr = XramBase + 0x3D08'u
  FailExpectedAddr = XramBase + 0x3D0C'u
  DiagAddr = XramBase + 0x3D20'u
  SwapBufAddr = XramBase + 0x3000'u
  SwapSeqAddr = XramBase + 0x3200'u
  SwapOpAddr = XramBase + 0x3204'u
  SwapSlotAddr = XramBase + 0x3208'u
  SwapChunkAddr = XramBase + 0x320C'u
  SwapResultAddr = XramBase + 0x3210'u
  SwapRespSeqAddr = XramBase + 0x3214'u

  SwapOpNone = 0'u32
  SwapOpRead = 1'u32
  SwapOpWrite = 2'u32
  SwapResultOk = 1'u32
  SwapResultErr = 2'u32
  SwapChunkBytes = 512'u
  SwapChunksPerPage = 8
  SwapDir = "bl808swap_safe"
  SwapPath = "bl808swap_safe/d0_vm.swap"
  SwapSlots = 4'u32

  StatusStarted = 1'u32 shl 0
  StatusTables = 1'u32 shl 1
  StatusSatp = 1'u32 shl 2
  StatusSupervisor = 1'u32 shl 3
  StatusSwapProvider = 1'u32 shl 4
  StatusVmReserved = 1'u32 shl 5
  StatusSwapOut = 1'u32 shl 6
  StatusSwapIn = 1'u32 shl 7
  StatusData = 1'u32 shl 8
  StatusRequired = StatusStarted or StatusTables or StatusSatp or
                   StatusSupervisor or StatusSwapProvider or
                   StatusVmReserved or StatusSwapOut or StatusSwapIn or
                   StatusData
  StatusFailed = 1'u32 shl 30
  StatusDone = 1'u32 shl 31

  FaultRecordAddr = XramBase + 0x2E00'u
  JtagD0RunMagic = 0x4430_5255'u32 # "D0RU"
  JtagD0RunPollLimit = 8_000_000
  PollLimit = 4_000_000

var
  console: Uart
  fs: SdFs
  swapFile: SdSwapFile
  swapPage: array[SdSwapPageBytes.int, uint8]
  lastSwapSeq: uint32
  swapServiceReady: bool

proc switchJtagMuxToD0() =
  const
    jtagD0Gpio = (27'u32 shl 8) or (1'u32 shl 22) or (1'u32 shl 1) or 1'u32
  regWrite(GpioConfigBase + 6'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 7'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 12'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 13'u * 4'u, jtagD0Gpio)
  fenceIo()

proc spinDelay() =
  for _ in 0 ..< 100:
    {.emit: """asm volatile("");""".}

proc sharedRead32(address: uint): uint32 =
  dcacheInvalidateAll()
  regRead(address)

proc printHex(label: string, value: uint32) =
  discard console.sendString(label)
  console.sendHex32(value)
  discard console.sendLine("")

proc dumpFaultRecord() =
  printHex("  fault_magic=", sharedRead32(FaultRecordAddr + 0'u))
  printHex("  fault_reason=", sharedRead32(FaultRecordAddr + 12'u))
  printHex("  fault_cause_lo=", sharedRead32(FaultRecordAddr + 16'u))
  printHex("  fault_epc_lo=", sharedRead32(FaultRecordAddr + 24'u))
  printHex("  fault_tval_lo=", sharedRead32(FaultRecordAddr + 32'u))

proc dumpDiag() =
  printHex("  d0_vm_reserve=", sharedRead32(DiagAddr + 0'u))
  printHex("  d0_swap_outs=", sharedRead32(DiagAddr + 4'u))
  printHex("  d0_swap_ins=", sharedRead32(DiagAddr + 8'u))
  printHex("  d0_mapped_pages=", sharedRead32(DiagAddr + 12'u))
  printHex("  d0_evictions=", sharedRead32(DiagAddr + 16'u))
  printHex("  m0_swap_last_seq=", lastSwapSeq)

proc copySwapBufferToPage(chunk: uint32) =
  dcacheInvalidateRange(SwapBufAddr, SwapChunkBytes)
  let src = cast[ptr UncheckedArray[uint8]](SwapBufAddr)
  let offset = chunk.uint * SwapChunkBytes
  for i in 0 ..< SwapChunkBytes.int:
    swapPage[(offset + i.uint).int] = src[i]

proc copyPageToSwapBuffer(chunk: uint32) =
  let dst = cast[ptr UncheckedArray[uint8]](SwapBufAddr)
  let offset = chunk.uint * SwapChunkBytes
  for i in 0 ..< SwapChunkBytes.int:
    dst[i] = swapPage[(offset + i.uint).int]
  dcacheCleanRange(SwapBufAddr, SwapChunkBytes)
  fenceIo()

proc completeSwapRequest(seq: uint32, ok: bool) =
  regWrite(SwapResultAddr, if ok: SwapResultOk else: SwapResultErr)
  regWrite(SwapRespSeqAddr, seq)
  regWrite(SwapOpAddr, SwapOpNone)
  dcacheFlushAll()
  fenceIo()

proc serviceSwapRequest() =
  if not swapServiceReady:
    return
  dcacheInvalidateRange(SwapSeqAddr, 32)
  let seq = regRead(SwapSeqAddr)
  if seq == 0 or seq == lastSwapSeq:
    return
  let op = regRead(SwapOpAddr)
  let slot = regRead(SwapSlotAddr)
  let chunk = regRead(SwapChunkAddr)
  if chunk >= SwapChunksPerPage.uint32:
    lastSwapSeq = seq
    completeSwapRequest(seq, false)
    return

  var ok = false
  case op
  of SwapOpRead:
    if chunk == 0:
      ok = sdSwapReadPage(fs, swapFile, slot,
                          cast[ptr UncheckedArray[uint8]](addr swapPage[0])) == sdSwapOk
    else:
      ok = true
    if ok:
      copyPageToSwapBuffer(chunk)
  of SwapOpWrite:
    copySwapBufferToPage(chunk)
    if chunk == (SwapChunksPerPage - 1).uint32:
      ok = sdSwapWritePage(fs, swapFile, slot,
                           cast[ptr UncheckedArray[uint8]](addr swapPage[0])) == sdSwapOk
    else:
      ok = true
  else:
    ok = false
  lastSwapSeq = seq
  completeSwapRequest(seq, ok)

proc waitForJtagD0RunMagic() =
  for _ in 0 ..< JtagD0RunPollLimit:
    if sharedRead32(StatusAddr) == JtagD0RunMagic:
      regWrite(StatusAddr, 0)
      dcacheFlushAll()
      fenceIo()
      return
    spinDelay()
  discard console.sendLine("[FAIL] D0 JTAG load handshake timeout")

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)

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

  discard console.sendLine("")
  discard console.sendLine("=== BL808 D0 Sv39 SD Swap Test ===")

  let mountStatus = fs.mount()
  if mountStatus != frOk:
    discard console.sendString("[FAIL] M0 mounted SD filesystem value=")
    console.sendHex32(mountStatus.ord.uint32)
    discard console.sendLine("")
    while true:
      wfi()
  discard console.sendLine("[PASS] M0 mounted SD filesystem for D0 swap")

  let mkdirStatus = fs.mkdir(SwapDir)
  if mkdirStatus != frOk and mkdirStatus != frExist:
    discard console.sendString("[FAIL] M0 created SD swap directory value=")
    console.sendHex32(mkdirStatus.ord.uint32)
    discard console.sendLine("")
    while true:
      wfi()

  let swapStatus = sdSwapOpenOrCreate(fs, swapFile, SwapPath, SwapSlots)
  if swapStatus != sdSwapOk:
    discard console.sendString("[FAIL] M0 opened SD swap file value=")
    console.sendHex32(swapStatus.ord.uint32)
    discard console.sendLine("")
    while true:
      wfi()
  swapServiceReady = true
  discard console.sendLine("[PASS] M0 opened SD swap file for D0")

  regWrite(StatusAddr, 0)
  regWrite(FailCodeAddr, 0)
  regWrite(FailGotAddr, 0)
  regWrite(FailExpectedAddr, 0)
  for off in countup(0'u, 28'u, 4'u):
    regWrite(DiagAddr + off, 0)
  regWrite(SwapSeqAddr, 0)
  regWrite(SwapOpAddr, SwapOpNone)
  regWrite(SwapSlotAddr, 0)
  regWrite(SwapChunkAddr, 0)
  regWrite(SwapResultAddr, 0)
  regWrite(SwapRespSeqAddr, 0)
  dcacheFlushAll()
  fenceIo()

  mmPowerOn()
  when defined(bl808jtagram):
    regWrite(DramBase, 0x0000_006F'u32) # jal x0, 0
    dcacheFlushAll()
    fenceIo()
    releaseD0(forceLoad = false)
    discard console.sendLine("[INFO] Switching JTAG mux to D0")
    switchJtagMuxToD0()
    discard console.sendLine("[INFO] JTAG mux switched to D0")
    waitForJtagD0RunMagic()
  else:
    releaseD0()

  var status = 0'u32
  for _ in 0 ..< PollLimit:
    serviceSwapRequest()
    status = sharedRead32(StatusAddr)
    if (status and StatusDone) != 0:
      break
    spinDelay()

  if (status and StatusDone) == 0:
    printHex("  d0_sd_swap_status=", status)
    dumpDiag()
    dumpFaultRecord()
    discard console.sendLine("[FAIL] D0 SD swap status timeout")
  elif (status and StatusFailed) != 0:
    dumpDiag()
    dumpFaultRecord()
    discard console.sendString("[FAIL] first code=")
    console.sendHex32(sharedRead32(FailCodeAddr))
    discard console.sendString(" got=")
    console.sendHex32(sharedRead32(FailGotAddr))
    discard console.sendString(" expected=")
    console.sendHex32(sharedRead32(FailExpectedAddr))
    discard console.sendLine("")
    discard console.sendLine("[FAIL] D0 SD swap reported a failed check")
  elif (status and StatusRequired) != StatusRequired:
    discard console.sendLine("[FAIL] D0 SD swap missing required status bits")
    dumpDiag()

  check("D0 SD swap started", (status and StatusStarted) != 0)
  check("D0 Sv39 page tables installed", (status and StatusTables) != 0)
  check("D0 satp enabled", (status and StatusSatp) != 0)
  check("D0 entered supervisor mode", (status and StatusSupervisor) != 0)
  check("D0 installed SD swap provider", (status and StatusSwapProvider) != 0)
  check("D0 reserved VM pages", (status and StatusVmReserved) != 0)
  check("D0 swapped out to SD", (status and StatusSwapOut) != 0)
  check("D0 swapped in from SD", (status and StatusSwapIn) != 0)
  check("D0 verified swapped page data", (status and StatusData) != 0)
  dumpDiag()

  if (status and StatusFailed) == 0 and (status and StatusRequired) == StatusRequired:
    discard console.sendLine("[PASS] D0 SD-backed VM swap complete")
    discard console.sendLine("=== Test Complete ===")

  discard sdSwapClose(fs, swapFile)
  fs.deinit()

  while true:
    wfi()
