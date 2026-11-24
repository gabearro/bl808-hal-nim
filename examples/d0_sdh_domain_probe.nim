## D0 direct SDH controller-domain probe.
##
## This deliberately avoids FatFS and Sv39. It runs on D0 in M-mode and records
## whether D0 can access SDH registers, initialize the host, exchange basic SD
## commands, and read one 512-byte sector through the PIO data path.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio
import bl808/mmio, bl808/memmap
import bl808/sdh
import bl808/kernel/sdblk

const
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
  StatusFailed = 1'u32 shl 30
  StatusDone = 1'u32 shl 31

  CMD0 = 0'u32
  CMD2 = 2'u32
  CMD3 = 3'u32
  CMD7 = 7'u32
  CMD8 = 8'u32
  CMD17 = 17'u32
  CMD55 = 55'u32
  ACMD41 = 41'u32
  SectorSize = 512'u32
  TmRead = (1'u16 shl TmDataDir) or (1'u16 shl TmBlkCntEn)
  TmReadAdma = TmRead or (1'u16 shl TmDmaEn)
  AdmaAttrValid = 1'u16 shl 0
  AdmaAttrEnd = 1'u16 shl 1
  AdmaAttrActTran = 2'u16 shl 4
  AdmaDescAddr = XramBase + 0x3600'u
  AdmaBufAddr = XramBase + 0x3620'u
  WramAdmaDescAddr = WramBase + 0x3000'u
  WramAdmaBufAddr = WramBase + 0x3020'u
  AdmaFillPattern = 0xA5A5_A5A5'u32
  ScratchMagic = 0xD05D_5001'u32
  ScratchWriteMagic = 0xD05D_5002'u32
  ScratchMultiWriteMagic = 0xD05D_5003'u32
  ScratchWords = 256

var
  sector0 {.align: 32.}: array[128, uint32]
  sdblkSector0 {.align: 32.}: array[128, uint32]
  scratchOriginal {.align: 32.}: array[128, uint32]
  scratchWrite {.align: 32.}: array[128, uint32]
  scratchVerify {.align: 32.}: array[128, uint32]
  scratchOriginalMulti {.align: 32.}: array[ScratchWords, uint32]
  scratchWriteMulti {.align: 32.}: array[ScratchWords, uint32]
  scratchVerifyMulti {.align: 32.}: array[ScratchWords, uint32]

proc writeShared(address: uint, value: uint32) =
  regWrite(address, value)
  dcacheCleanRange(address, 4)
  fenceIo()

proc setStatus(mask: uint32) =
  regSet(StatusAddr, mask)
  dcacheCleanRange(StatusAddr, 16)
  fenceIo()

proc writeDiag(index: int, value: uint32) =
  writeShared(DiagAddr + index.uint * 4'u, value)

proc fail(code, got, expected: uint32) =
  if regRead(FailCodeAddr) == 0:
    writeShared(FailCodeAddr, code)
    writeShared(FailGotAddr, got)
    writeShared(FailExpectedAddr, expected)
  setStatus(StatusFailed or StatusDone)
  while true:
    wfi()

proc check(code: uint32, ok: bool) =
  if not ok:
    fail(code, 0, 1)

proc checkErr(code: uint32, err: SdhError) =
  if err != sdhOk:
    fail(code, err.ord.uint32, sdhOk.ord.uint32)

proc sdhIntStatusSnapshot(): uint32 {.inline.} =
  regRead(SdhIntStatus)

proc sdhPresentSnapshot(): uint32 {.inline.} =
  regRead(SdhPresentState)

proc sectorTailLooksBootable(tail: uint32): bool =
  ((tail shr 16) and 0xFFFF'u32) == 0xAA55'u32 or
    (tail and 0xFFFF'u32) == 0xAA55'u32

proc sameSector(a, b: array[128, uint32]): bool =
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc sameScratch(a, b: array[ScratchWords, uint32]): bool =
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc quiesceForM0Handoff() =
  sdhResetData()
  regWrite(SdhIntStatus, 0xFFFF_FFFF'u32)
  let deselectErr = sdhSendCommand(CMD7, 0, respNone, crcCheck = false)
  writeDiag(76, deselectErr.ord.uint32)
  writeDiag(77, sdhPresentSnapshot())
  writeDiag(78, sdhIntStatusSnapshot())
  sdhResetData()
  sdhReset()
  regWrite(SdhIntStatus, 0xFFFF_FFFF'u32)

proc fillDmaBuffer(address: uint, bytes: uint) =
  let words = cast[ptr UncheckedArray[uint32]](address)
  for i in 0 ..< (bytes div 4'u).int:
    words[i] = AdmaFillPattern
  dcacheCleanRange(address, bytes)
  fenceIo()

proc waitAdmaTransferComplete(timeout: uint32 = 1_000_000): SdhError =
  var countdown = timeout
  while countdown > 0:
    let sts = regRead(SdhIntStatus)
    if (sts and (1'u32 shl IntErrInt)) != 0:
      regWrite(SdhIntStatus, 0xFFFF_0000'u32)
      return sdhDataError
    if (sts and (1'u32 shl IntXferComplete)) != 0:
      regWrite(SdhIntStatus, 1'u32 shl IntXferComplete)
      return sdhOk
    countdown.dec
  sdhTimeout

proc admaBufferChanged(address: uint): bool =
  let first = regRead(address)
  let last = regRead(address + SectorSize.uint - 4'u)
  first != AdmaFillPattern or last != AdmaFillPattern

proc readSector0Adma(descAddr, bufAddr: uint, diagBase: int): SdhError =
  fillDmaBuffer(bufAddr, SectorSize.uint)
  regWrite(descAddr, (SectorSize shl 16) or
           (AdmaAttrValid or AdmaAttrEnd or AdmaAttrActTran).uint32)
  regWrite(descAddr + 4'u, bufAddr.uint32)
  dcacheCleanRange(descAddr, 8)
  fenceIo()

  regWrite(SdhAdmaAddr, descAddr.uint32)
  regWrite(SdhBlockSize, (1'u32 shl 16) or SectorSize)
  result = sdhSendCommand(CMD17, 0, resp48bit, dataPresent = true,
                          transferMode = TmReadAdma)
  writeDiag(diagBase, result.ord.uint32)
  writeDiag(diagBase + 1, sdhLastCommandPresentState)
  writeDiag(diagBase + 2, sdhLastCommandIntStatus)
  writeDiag(diagBase + 3, regRead(SdhAdmaAddr))
  if result != sdhOk:
    return

  result = waitAdmaTransferComplete()
  dcacheInvalidateRange(bufAddr, SectorSize.uint)
  writeDiag(diagBase + 4, result.ord.uint32)
  writeDiag(diagBase + 5, sdhPresentSnapshot())
  writeDiag(diagBase + 6, sdhIntStatusSnapshot())
  writeDiag(diagBase + 7, regRead(SdhAdmaErr))
  writeDiag(diagBase + 8, regRead(bufAddr))
  writeDiag(diagBase + 9, regRead(bufAddr + SectorSize.uint - 4'u))
  sdhResetData()

proc main() {.exportc, cdecl.} =
  systemInit()

  writeShared(StatusAddr, 0)
  writeShared(FailCodeAddr, 0)
  writeShared(FailGotAddr, 0)
  writeShared(FailExpectedAddr, 0)
  for i in 0 ..< 96:
    writeDiag(i, 0)
  setStatus(StatusStarted)

  let cap0 = regRead(SdhCapabilities)
  let ver = regRead(SdhSlotIntSts)
  writeDiag(0, cap0)
  writeDiag(1, ver)
  writeDiag(2, regRead(SdhPresentState))
  check(0x5D48_0001'u32, cap0 != 0 or ver != 0)
  setStatus(StatusRegs)

  enableSystemClock(GlbCgenCfg2, CgenCfg2Sdh)
  setSdhClock(true, sdhClkWifiPll96m, 7)
  gpioSetupSdh(0, 1, 2, 3, 4, 5)
  writeDiag(3, regRead(GlbCgenCfg2))
  writeDiag(4, regRead(GlbSdhCfg0))
  setStatus(StatusClock)

  var err = sdInit()
  writeDiag(52, err.ord.uint32)
  checkErr(0x5D48_0011'u32, err)
  err = sdReadSector(0, cast[ptr UncheckedArray[uint32]](addr sdblkSector0[0]))
  writeDiag(53, err.ord.uint32)
  writeDiag(54, sdLastPhase)
  writeDiag(55, sdLastError.ord.uint32)
  writeDiag(56, sdblkSector0[127])
  writeDiag(57, sdLastIntStatus)
  writeDiag(58, sdLastPresentState)
  writeDiag(59, regRead(SdhTransferMode))
  writeDiag(60, regRead(SdhBlockSize))
  checkErr(0x5D48_0012'u32, err)
  setStatus(StatusSdblkRead)
  check(0x5D48_0013'u32, sectorTailLooksBootable(sdblkSector0[127]))
  setStatus(StatusSdblkSectorLooksValid)

  let scratchSector = regRead(ScratchSectorAddr)
  writeDiag(61, scratchSector)
  check(0x5D48_0015'u32, scratchSector != 0)

  err = sdReadSector(scratchSector,
                     cast[ptr UncheckedArray[uint32]](addr scratchOriginal[0]))
  writeDiag(62, err.ord.uint32)
  writeDiag(63, scratchOriginal[0])
  checkErr(0x5D48_0016'u32, err)
  check(0x5D48_0017'u32, scratchOriginal[0] == ScratchMagic)

  err = sdEnableHighSpeed(16'u32)
  writeDiag(79, err.ord.uint32)
  checkErr(0x5D48_001E'u32, err)

  for i in 0 ..< scratchWrite.len:
    scratchWrite[i] = 0xD000_0000'u32 or i.uint32
  scratchWrite[0] = ScratchWriteMagic

  err = sdWriteSector(scratchSector,
                      cast[ptr UncheckedArray[uint32]](addr scratchWrite[0]))
  writeDiag(64, err.ord.uint32)
  writeDiag(65, sdLastPhase)
  writeDiag(66, sdLastError.ord.uint32)
  writeDiag(67, sdLastIntStatus)
  writeDiag(68, sdLastPresentState)
  checkErr(0x5D48_0018'u32, err)

  err = sdReadSector(scratchSector,
                     cast[ptr UncheckedArray[uint32]](addr scratchVerify[0]))
  writeDiag(69, err.ord.uint32)
  writeDiag(70, scratchVerify[0])
  checkErr(0x5D48_0019'u32, err)
  check(0x5D48_001A'u32, sameSector(scratchWrite, scratchVerify))
  setStatus(StatusSdblkWrite)

  err = sdWriteSector(scratchSector,
                      cast[ptr UncheckedArray[uint32]](addr scratchOriginal[0]))
  writeDiag(71, err.ord.uint32)
  writeDiag(72, sdLastPhase)
  writeDiag(73, sdLastError.ord.uint32)
  checkErr(0x5D48_001B'u32, err)

  err = sdReadSector(scratchSector,
                     cast[ptr UncheckedArray[uint32]](addr scratchVerify[0]))
  writeDiag(74, err.ord.uint32)
  writeDiag(75, scratchVerify[0])
  checkErr(0x5D48_001C'u32, err)
  check(0x5D48_001D'u32, sameSector(scratchOriginal, scratchVerify))
  setStatus(StatusSdblkRestore)

  err = sdReadSectors(scratchSector, 2,
                      cast[ptr UncheckedArray[uint32]](addr scratchOriginalMulti[0]))
  writeDiag(80, err.ord.uint32)
  writeDiag(81, scratchOriginalMulti[0])
  checkErr(0x5D48_001F'u32, err)
  check(0x5D48_0020'u32, scratchOriginalMulti[0] == ScratchMagic)

  for i in 0 ..< scratchWriteMulti.len:
    scratchWriteMulti[i] = 0xD100_0000'u32 or i.uint32
  scratchWriteMulti[0] = ScratchMultiWriteMagic

  err = sdWriteSectors(scratchSector, 2,
                       cast[ptr UncheckedArray[uint32]](addr scratchWriteMulti[0]))
  writeDiag(82, err.ord.uint32)
  writeDiag(83, sdLastPhase)
  checkErr(0x5D48_0021'u32, err)

  err = sdReadSectors(scratchSector, 2,
                      cast[ptr UncheckedArray[uint32]](addr scratchVerifyMulti[0]))
  writeDiag(84, err.ord.uint32)
  writeDiag(85, scratchVerifyMulti[0])
  checkErr(0x5D48_0022'u32, err)
  check(0x5D48_0023'u32, sameScratch(scratchWriteMulti, scratchVerifyMulti))
  setStatus(StatusSdblkMultiWrite)

  err = sdWriteSectors(scratchSector, 2,
                       cast[ptr UncheckedArray[uint32]](addr scratchOriginalMulti[0]))
  writeDiag(86, err.ord.uint32)
  writeDiag(87, sdLastPhase)
  checkErr(0x5D48_0024'u32, err)

  err = sdReadSectors(scratchSector, 2,
                      cast[ptr UncheckedArray[uint32]](addr scratchVerifyMulti[0]))
  writeDiag(88, err.ord.uint32)
  writeDiag(89, scratchVerifyMulti[0])
  checkErr(0x5D48_0025'u32, err)
  check(0x5D48_0026'u32, sameScratch(scratchOriginalMulti, scratchVerifyMulti))
  setStatus(StatusSdblkMultiRestore)

  let initErr = sdhOk
  writeDiag(5, initErr.ord.uint32)
  writeDiag(6, regRead(SdhClockCtrl))
  writeDiag(7, sdhPresentSnapshot())
  writeDiag(8, sdhIntStatusSnapshot())
  checkErr(0x5D48_0002'u32, initErr)
  setStatus(StatusHostInit)

  err = sdhInit()
  checkErr(0x5D48_0014'u32, err)

  err = sdhSendCommand(CMD0, 0, respNone)
  writeDiag(9, err.ord.uint32)
  writeDiag(10, sdhIntStatusSnapshot())
  checkErr(0x5D48_0003'u32, err)
  setStatus(StatusCmd0)

  err = sdhSendCommand(CMD8, 0x000001AA'u32, resp48bit)
  let r7 = sdhReadResponse32()
  writeDiag(11, err.ord.uint32)
  writeDiag(12, r7)
  writeDiag(13, sdhIntStatusSnapshot())
  checkErr(0x5D48_0004'u32, err)
  check(0x5D48_0005'u32, (r7 and 0xFF'u32) == 0xAA'u32)
  setStatus(StatusCmd8)

  var ocr = 0'u32
  var ready = false
  for _ in 0 ..< 1000:
    err = sdhSendCommand(CMD55, 0, resp48bit)
    if err != sdhOk:
      break
    err = sdhSendCommand(ACMD41, 0x40FF8000'u32, resp48bit,
                         crcCheck = false)
    if err != sdhOk:
      break
    ocr = sdhReadResponse32()
    if (ocr and (1'u32 shl 31)) != 0:
      ready = true
      break
  writeDiag(14, err.ord.uint32)
  writeDiag(15, ocr)
  writeDiag(16, sdhIntStatusSnapshot())
  checkErr(0x5D48_0006'u32, err)
  check(0x5D48_0007'u32, ready)
  setStatus(StatusAcmd41)

  var cid: array[4, uint32]
  err = sdhSendCommand(CMD2, 0, resp136bit)
  sdhReadResponse(cid)
  writeDiag(17, err.ord.uint32)
  writeDiag(18, cid[0])
  checkErr(0x5D48_0008'u32, err)
  setStatus(StatusCid)

  err = sdhSendCommand(CMD3, 0, resp48bit)
  let rca = sdhReadResponse32() and 0xFFFF0000'u32
  writeDiag(19, err.ord.uint32)
  writeDiag(20, rca)
  checkErr(0x5D48_0009'u32, err)
  check(0x5D48_000A'u32, rca != 0)
  setStatus(StatusRca)

  err = sdhSendCommand(CMD7, rca, resp48busy)
  writeDiag(21, err.ord.uint32)
  writeDiag(22, sdhPresentSnapshot())
  checkErr(0x5D48_000B'u32, err)
  setStatus(StatusSelect)

  err = readSector0Adma(AdmaDescAddr, AdmaBufAddr, 31)
  writeDiag(51, (if admaBufferChanged(AdmaBufAddr): 1'u32 else: 0'u32))
  sdhResetData()

  err = readSector0Adma(WramAdmaDescAddr, WramAdmaBufAddr, 41)
  checkErr(0x5D48_000F'u32, err)
  setStatus(StatusAdmaRead)
  check(0x5D48_0010'u32, admaBufferChanged(WramAdmaBufAddr))
  setStatus(StatusAdmaSectorLooksValid)

  sdhResetData()

  regWrite(SdhBlockSize, (1'u32 shl 16) or 512'u32)
  err = sdhSendCommand(CMD17, 0, resp48bit, dataPresent = true,
                       transferMode = TmRead)
  writeDiag(23, err.ord.uint32)
  writeDiag(24, sdhPresentSnapshot())
  writeDiag(25, sdhIntStatusSnapshot())
  checkErr(0x5D48_000C'u32, err)
  setStatus(StatusCmd17)

  err = sdhReadBlock(sector0)
  writeDiag(26, err.ord.uint32)
  writeDiag(27, sdhPresentSnapshot())
  writeDiag(28, sdhIntStatusSnapshot())
  writeDiag(29, sector0[0])
  writeDiag(30, sector0[127])
  if err == sdhOk:
    setStatus(StatusReadBlock)
    if sectorTailLooksBootable(sector0[127]):
      setStatus(StatusSectorLooksValid)

  quiesceForM0Handoff()
  setStatus(StatusDone)
  while true:
    wfi()
