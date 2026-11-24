## M0 reporter for the D0 direct SDH controller-domain probe.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart, bl808/sdh
import bl808/kernel/alloc
import bl808/kernel/fatfs
import bl808/kernel/sdblk

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

  StatusAddr = XramBase + 0x3E00'u
  FailCodeAddr = XramBase + 0x3E04'u
  FailGotAddr = XramBase + 0x3E08'u
  FailExpectedAddr = XramBase + 0x3E0C'u
  ScratchSectorAddr = XramBase + 0x3D00'u
  DiagAddr = XramBase + 0x3E20'u

  StatusStarted = 1'u32 shl 0
  StatusRegs = 1'u32 shl 1
  StatusClock = 1'u32 shl 2
  StatusHostInit = 1'u32 shl 3
  StatusCmd0 = 1'u32 shl 4
  StatusCmd8 = 1'u32 shl 5
  StatusAcmd41 = 1'u32 shl 6
  StatusCid = 1'u32 shl 7
  StatusRca = 1'u32 shl 8
  StatusSelect = 1'u32 shl 9
  StatusCmd17 = 1'u32 shl 10
  StatusReadBlock = 1'u32 shl 11
  StatusSectorLooksValid = 1'u32 shl 12
  StatusAdmaRead = 1'u32 shl 13
  StatusAdmaSectorLooksValid = 1'u32 shl 14
  StatusSdblkRead = 1'u32 shl 15
  StatusSdblkSectorLooksValid = 1'u32 shl 16
  StatusSdblkWrite = 1'u32 shl 17
  StatusSdblkRestore = 1'u32 shl 18
  StatusSdblkMultiWrite = 1'u32 shl 19
  StatusSdblkMultiRestore = 1'u32 shl 20
  StatusRequired = StatusStarted or StatusRegs or StatusClock or
                   StatusHostInit or StatusCmd0 or StatusCmd8 or
                   StatusAcmd41 or StatusCid or StatusRca or
                   StatusSelect or StatusCmd17 or StatusAdmaRead or
                   StatusAdmaSectorLooksValid or StatusSdblkRead or
                   StatusSdblkSectorLooksValid or StatusSdblkWrite or
                   StatusSdblkRestore or StatusSdblkMultiWrite or
                   StatusSdblkMultiRestore
  StatusFailed = 1'u32 shl 30
  StatusDone = 1'u32 shl 31

  FaultRecordAddr = XramBase + 0x2E00'u
  PollLimit = 1_000_000
  JtagD0RunMagic = 0x4430_5255'u32
  JtagD0RunPollLimit = 8_000_000
  ScratchDir = "bl808swap_safe"
  ScratchPath = "bl808swap_safe/d0_sdh_rw.bin"
  ScratchMagic = 0xD05D_5001'u32
  ScratchBytes = 1024

var
  console: Uart
  fs: SdFs
  scratchSector: uint32

proc switchJtagMuxToD0() =
  const jtagD0Gpio = (27'u32 shl 8) or (1'u32 shl 22) or (1'u32 shl 1) or 1'u32
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

proc prepareScratchSector(): bool =
  let mountStatus = fs.mount()
  if mountStatus != frOk:
    printHex("[FAIL] M0 mounted SD filesystem value=", mountStatus.ord.uint32)
    return false
  let mkdirStatus = fs.mkdir(ScratchDir)
  if mkdirStatus != frOk and mkdirStatus != frExist:
    printHex("[FAIL] M0 created scratch directory value=", mkdirStatus.ord.uint32)
    return false

  var f: Fil
  let openStatus = fs.open(f, ScratchPath, faRead or faWrite or faCreateAlways)
  if openStatus != frOk:
    printHex("[FAIL] M0 opened D0 SDH scratch file value=", openStatus.ord.uint32)
    return false

  var sector: array[ScratchBytes, uint8]
  for i in 0 ..< sector.len:
    sector[i] = (i and 0xFF).uint8
  cast[ptr uint32](addr sector[0])[] = ScratchMagic
  let wrote = fs.write(f, sector)
  if wrote != sector.len:
    printHex("[FAIL] M0 wrote D0 SDH scratch file bytes=", wrote.uint32)
    discard fs.close(f)
    return false
  if fs.sync(f) != frOk:
    discard fs.close(f)
    discard console.sendLine("[FAIL] M0 synced D0 SDH scratch file")
    return false
  scratchSector = f.physicalSector(0)
  let secondSector = f.physicalSector(512)
  discard fs.close(f)
  if scratchSector == 0:
    discard console.sendLine("[FAIL] M0 resolved D0 SDH scratch sector")
    return false
  if secondSector != scratchSector + 1:
    printHex("[FAIL] M0 D0 SDH scratch second sector=", secondSector)
    printHex("  m0_d0_sdh_scratch_first=", scratchSector)
    return false
  regWrite(ScratchSectorAddr, scratchSector)
  dcacheFlushAll()
  fenceIo()
  printHex("  m0_d0_sdh_scratch_sector=", scratchSector)
  discard console.sendLine("[PASS] M0 prepared D0 SDH scratch sector")
  true

proc verifyScratchRestored(): bool =
  fs.deinit()
  sdInvalidateState()
  sdhReset()
  let diskStatus = disk_initialize(0)
  if diskStatus != 0:
    printHex("[FAIL] M0 reinitialized SD disk value=", diskStatus.uint32)
    return false
  var boot: array[128, uint32]
  if disk_read(0, addr boot[0], 0, 1) != 0:
    discard console.sendLine("[FAIL] M0 warmed D0 SDH handoff read")
    printHex("  m0_d0_sdh_sd_last_phase=", sdLastPhase)
    printHex("  m0_d0_sdh_sd_last_error=", sdLastError.ord.uint32)
    printHex("  m0_d0_sdh_sd_last_status=", sdLastIntStatus)
    printHex("  m0_d0_sdh_sd_last_present=", sdLastPresentState)
    return false
  let mountStatus = fs.mount()
  if mountStatus != frOk:
    printHex("[FAIL] M0 remounted SD filesystem value=", mountStatus.ord.uint32)
    return false
  var f: Fil
  if fs.open(f, ScratchPath, faRead or faOpenExisting) != frOk:
    discard console.sendLine("[FAIL] M0 reopened D0 SDH scratch file")
    return false
  var sector: array[ScratchBytes, uint8]
  let got = fs.read(f, sector)
  discard fs.close(f)
  if got != sector.len:
    printHex("[FAIL] M0 read D0 SDH scratch file bytes=", got.uint32)
    return false
  if cast[ptr uint32](addr sector[0])[] != ScratchMagic:
    printHex("[FAIL] M0 D0 SDH scratch restore magic=",
             cast[ptr uint32](addr sector[0])[])
    return false
  for i in 4 ..< sector.len:
    if sector[i] != (i and 0xFF).uint8:
      printHex("[FAIL] M0 D0 SDH scratch restore byte=", i.uint32)
      return false
  discard console.sendLine("[PASS] M0 verified D0 SDH scratch restore")
  true

proc dumpDiag() =
  for i in 0 ..< 96:
    discard console.sendString("  d0_sdh_diag")
    console.sendHex32(i.uint32)
    discard console.sendString("=")
    console.sendHex32(sharedRead32(DiagAddr + i.uint * 4'u))
    discard console.sendLine("")

proc dumpFaultRecord() =
  printHex("  fault_magic=", sharedRead32(FaultRecordAddr + 0'u))
  printHex("  fault_reason=", sharedRead32(FaultRecordAddr + 12'u))
  printHex("  fault_cause_lo=", sharedRead32(FaultRecordAddr + 16'u))
  printHex("  fault_epc_lo=", sharedRead32(FaultRecordAddr + 24'u))
  printHex("  fault_tval_lo=", sharedRead32(FaultRecordAddr + 32'u))

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
  discard console.sendLine("=== BL808 D0 SDH Domain Probe ===")

  if not prepareScratchSector():
    while true:
      wfi()

  regWrite(StatusAddr, 0)
  regWrite(FailCodeAddr, 0)
  regWrite(FailGotAddr, 0)
  regWrite(FailExpectedAddr, 0)
  regWrite(ScratchSectorAddr, scratchSector)
  for i in 0 ..< 96:
    regWrite(DiagAddr + i.uint * 4'u, 0)
  dcacheFlushAll()
  fenceIo()

  mmPowerOn()
  when defined(bl808jtagram):
    regWrite(DramBase, 0x0000_006F'u32)
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
    status = sharedRead32(StatusAddr)
    if (status and StatusDone) != 0:
      break
    spinDelay()

  if (status and StatusDone) == 0:
    printHex("  d0_sdh_status=", status)
    printHex("  d0_sdh_fail_code=", sharedRead32(FailCodeAddr))
    printHex("  d0_sdh_fail_got=", sharedRead32(FailGotAddr))
    printHex("  d0_sdh_fail_expected=", sharedRead32(FailExpectedAddr))
    dumpDiag()
    dumpFaultRecord()
    discard console.sendLine("[FAIL] D0 SDH domain probe timeout")
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
    discard console.sendLine("[FAIL] D0 SDH domain probe failed")
  elif (status and StatusRequired) != StatusRequired:
    dumpDiag()
    discard console.sendLine("[FAIL] D0 SDH domain probe missing status bits")

  check("D0 SDH registers accessible", (status and StatusRegs) != 0)
  check("D0 SDH clock configured", (status and StatusClock) != 0)
  check("D0 SDH host initialized", (status and StatusHostInit) != 0)
  check("D0 SDH CMD0 works", (status and StatusCmd0) != 0)
  check("D0 SDH CMD8 works", (status and StatusCmd8) != 0)
  check("D0 SDH ACMD41 ready", (status and StatusAcmd41) != 0)
  check("D0 SDH CID works", (status and StatusCid) != 0)
  check("D0 SDH RCA works", (status and StatusRca) != 0)
  check("D0 SDH select works", (status and StatusSelect) != 0)
  check("D0 SDH CMD17 command works", (status and StatusCmd17) != 0)
  check("D0 SDH PIO read block works", (status and StatusReadBlock) != 0)
  check("D0 SDH PIO sector data valid", (status and StatusSectorLooksValid) != 0)
  check("D0 SDH ADMA read works", (status and StatusAdmaRead) != 0)
  check("D0 SDH ADMA sector data valid", (status and StatusAdmaSectorLooksValid) != 0)
  check("D0 sdblk read works", (status and StatusSdblkRead) != 0)
  check("D0 sdblk sector data valid", (status and StatusSdblkSectorLooksValid) != 0)
  check("D0 sdblk write works", (status and StatusSdblkWrite) != 0)
  check("D0 sdblk restore works", (status and StatusSdblkRestore) != 0)
  check("D0 sdblk multiblock write works", (status and StatusSdblkMultiWrite) != 0)
  check("D0 sdblk multiblock restore works", (status and StatusSdblkMultiRestore) != 0)

  let restored = verifyScratchRestored()

  if (status and StatusFailed) == 0 and
      (status and StatusRequired) == StatusRequired and restored:
    discard console.sendLine("[PASS] D0 SDH domain probe complete")
    discard console.sendLine("=== Test Complete ===")

  while true:
    wfi()
