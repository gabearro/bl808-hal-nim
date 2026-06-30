## SD card block device for FatFs.
##
## Implements the SD card initialization sequence (CMD0 -> CMD8 -> ACMD41 ->
## CMD2 -> CMD3 -> CMD7) and exports the FatFs disk_* callbacks as cdecl
## functions that FatFs's ff.c calls through its diskio interface.

import ../sdh, ../mmio, ../memmap
import ../glb, ../gpio
import ../core

# =============================================================================
# SD protocol constants
# =============================================================================
const
  CMD0  = 0'u32   # GO_IDLE_STATE
  CMD2  = 2'u32   # ALL_SEND_CID
  CMD3  = 3'u32   # SEND_RELATIVE_ADDR
  CMD6  = 6'u32   # SWITCH_FUNC
  CMD9  = 9'u32   # SEND_CSD
  CMD12 = 12'u32  # STOP_TRANSMISSION
  CMD13 = 13'u32  # SEND_STATUS
  CMD7  = 7'u32   # SELECT_CARD
  CMD8  = 8'u32   # SEND_IF_COND
  CMD16 = 16'u32  # SET_BLOCKLEN
  CMD17 = 17'u32  # READ_SINGLE_BLOCK
  CMD18 = 18'u32  # READ_MULTIPLE_BLOCK
  CMD24 = 24'u32  # WRITE_BLOCK
  CMD25 = 25'u32  # WRITE_MULTIPLE_BLOCK
  CMD55 = 55'u32  # APP_CMD
  ACMD6 = 6'u32   # SET_BUS_WIDTH
  ACMD13 = 13'u32 # SD_STATUS
  ACMD41 = 41'u32 # SD_SEND_OP_COND

  SectorSize = 512'u32
  SdStatusBytes = 64'u32
  Cmd6StatusBytes = 64'u32
  R1CurrentStateShift = 9'u32
  R1CurrentStateMask = 0xF'u32 shl R1CurrentStateShift
  R1StateProgramming = 7'u32
  AdmaAttrValid = 1'u16 shl 0
  AdmaAttrEnd = 1'u16 shl 1
  AdmaAttrActTran = 2'u16 shl 4
  AdmaWriteScratchSectors = 8'u32

# Transfer mode bits
const
  TmRead = (1'u16 shl TmDataDir) or (1'u16 shl TmBlkCntEn)
  TmWrite = (1'u16 shl TmBlkCntEn) # direction=0 => write
  TmReadMulti = (1'u16 shl TmDataDir) or (1'u16 shl TmMultiBlock)
  TmWriteMultiAdma = (1'u16 shl TmDmaEn) or (1'u16 shl TmBlkCntEn) or
                     (TmAutoCmd12 shl TmAutoCmdShift) or
                     (1'u16 shl TmMultiBlock)

# =============================================================================
# SD card state
# =============================================================================
var
  sdRca: uint32 = 0
  sdSdhc: bool = false
  sdReady: bool = false
  sdBus4Bit: bool = false
  sdHighSpeed: bool = false
  sdHighSpeedClockDiv: uint32 = 128
  sdCidRaw: array[4, uint32]
  sdCsdRaw: array[4, uint32]
  sdCidValid: bool = false
  sdCsdValid: bool = false
  sdLastError*: SdhError = sdhOk
  sdLastPhase*: uint32 = 0
  sdLastCommand*: uint32 = 0
  sdLastSector*: uint32 = 0
  sdLastIntStatus*: uint32 = 0
  sdLastPresentState*: uint32 = 0
  sdLastAdmaError*: uint32 = 0
  sdLastAdmaAddress*: uint32 = 0
  sdLastAdmaDescAttr*: uint32 = 0
  sdLastAdmaDescLen*: uint32 = 0
  sdLastAdmaDescData*: uint32 = 0
  sdLastBlockCount*: uint32 = 0
  sdLastAdmaData0*: uint32 = 0
  sdLastAdmaData1*: uint32 = 0
  sdReadOps*: uint32 = 0
  sdWriteOps*: uint32 = 0
  sdReadErrors*: uint32 = 0
  sdWriteErrors*: uint32 = 0
  sdCommandErrors*: uint32 = 0
  sdDataErrors*: uint32 = 0
  sdTimeouts*: uint32 = 0

type
  SdhAdma2Desc {.packed.} = object
    attr: uint16
    length: uint16
    address: uint32

{.pragma: sdDmaMem,
  codegenDecl: "$# $# __attribute__((section(\".sddma\"), aligned(32), used))".}

var
  sdAdmaDesc {.sdDmaMem.}: array[1, SdhAdma2Desc]
  sdAdmaSector {.sdDmaMem.}: array[128, uint32]
  sdAdmaWriteScratch {.sdDmaMem.}: array[AdmaWriteScratchSectors.int * 128, uint32]

type
  SdHealth* = object
    present*: bool
    stable*: bool
    ready*: bool
    sdhc*: bool
    bus4Bit*: bool
    highSpeed*: bool
    highSpeedClockDiv*: uint32
    rca*: uint32
    lastError*: SdhError
    lastPhase*: uint32
    lastCommand*: uint32
    lastSector*: uint32
    intStatus*: uint32
    presentState*: uint32
    cmd13Ok*: bool
    r1Status*: uint32
    cidValid*: bool
    csdValid*: bool
    cidRaw*: array[4, uint32]
    csdRaw*: array[4, uint32]
    csdVersion*: uint8
    readBlockLen*: uint32
    capacityBytes*: uint64
    sectorCount*: uint32
    sdStatusOk*: bool
    sdStatusRaw*: array[16, uint32]
    cidManufacturerId*: uint8
    cidOemId*: uint16
    cidProductName*: array[5, uint8]
    cidProductRevision*: uint8
    cidSerialNumber*: uint32
    cidManufacturingDate*: uint16
    csdTranSpeed*: uint8
    csdCommandClasses*: uint16
    csdReadBlockPartial*: bool
    csdWriteBlockMisalign*: bool
    csdReadBlockMisalign*: bool
    csdDsrImplemented*: bool
    csdEraseBlockEnabled*: bool
    csdEraseSectorSize*: uint32
    csdWriteProtectGroupSize*: uint32
    csdWriteBlockLen*: uint32
    csdWriteBlockPartial*: bool
    sdStatusBusWidth*: uint8
    sdStatusSecuredMode*: bool
    sdStatusCardType*: uint16
    sdStatusSpeedClass*: uint8
    sdStatusPerformanceMove*: uint8
    sdStatusAuSize*: uint8
    sdStatusEraseSize*: uint16
    sdStatusEraseTimeout*: uint8
    sdStatusEraseOffset*: uint8
    sdStatusUhsSpeedGrade*: uint8
    sdStatusUhsAuSize*: uint8
    readOps*: uint32
    writeOps*: uint32
    readErrors*: uint32
    writeErrors*: uint32
    commandErrors*: uint32
    dataErrors*: uint32
    timeouts*: uint32

proc bitFromR2(resp: array[4, uint32], bit: int): uint32 =
  ## Extract a bit from an SD R2 payload, numbered like the SD register
  ## fields after the stripped transmission end bit/CRC are removed.
  let shifted = bit - 8
  if shifted < 0 or shifted >= 120:
    return 0
  (resp[shifted div 32] shr (shifted and 31)) and 1'u32

proc bitsFromR2(resp: array[4, uint32], hi, lo: int): uint32 =
  var v = 0'u32
  var outBit = 0
  var b = lo
  while b <= hi:
    v = v or (bitFromR2(resp, b) shl outBit)
    inc b
    inc outBit
  v

proc decodeCsdInto(resp: array[4, uint32], outHealth: var SdHealth) =
  outHealth.csdVersion = bitsFromR2(resp, 127, 126).uint8
  outHealth.csdTranSpeed = bitsFromR2(resp, 103, 96).uint8
  outHealth.csdCommandClasses = bitsFromR2(resp, 95, 84).uint16
  outHealth.csdReadBlockPartial = bitsFromR2(resp, 79, 79) != 0
  outHealth.csdWriteBlockMisalign = bitsFromR2(resp, 78, 78) != 0
  outHealth.csdReadBlockMisalign = bitsFromR2(resp, 77, 77) != 0
  outHealth.csdDsrImplemented = bitsFromR2(resp, 76, 76) != 0
  outHealth.csdEraseBlockEnabled = bitsFromR2(resp, 46, 46) != 0
  outHealth.csdEraseSectorSize = bitsFromR2(resp, 45, 39) + 1
  outHealth.csdWriteProtectGroupSize = bitsFromR2(resp, 38, 32) + 1
  outHealth.csdWriteBlockLen = 1'u32 shl bitsFromR2(resp, 25, 22)
  outHealth.csdWriteBlockPartial = bitsFromR2(resp, 21, 21) != 0
  case outHealth.csdVersion
  of 1:
    let cSize = bitsFromR2(resp, 69, 48)
    outHealth.readBlockLen = 512
    outHealth.capacityBytes = (cSize.uint64 + 1'u64) * 512'u64 * 1024'u64
    outHealth.sectorCount = (outHealth.capacityBytes div SectorSize.uint64).uint32
  of 0:
    let readBlLen = bitsFromR2(resp, 83, 80)
    let cSize = bitsFromR2(resp, 73, 62)
    let cSizeMult = bitsFromR2(resp, 49, 47)
    let blockLen = 1'u64 shl readBlLen
    let mult = 1'u64 shl (cSizeMult + 2)
    outHealth.readBlockLen = blockLen.uint32
    outHealth.capacityBytes = (cSize.uint64 + 1'u64) * mult * blockLen
    outHealth.sectorCount = (outHealth.capacityBytes div SectorSize.uint64).uint32
  else:
    outHealth.readBlockLen = 0
    outHealth.capacityBytes = 0
    outHealth.sectorCount = 0

proc decodeCidInto(resp: array[4, uint32], outHealth: var SdHealth) =
  outHealth.cidManufacturerId = bitsFromR2(resp, 127, 120).uint8
  outHealth.cidOemId = bitsFromR2(resp, 119, 104).uint16
  for i in 0 ..< outHealth.cidProductName.len:
    let hi = 103 - i * 8
    outHealth.cidProductName[i] = bitsFromR2(resp, hi, hi - 7).uint8
  outHealth.cidProductRevision = bitsFromR2(resp, 63, 56).uint8
  outHealth.cidSerialNumber = bitsFromR2(resp, 55, 24)
  outHealth.cidManufacturingDate = bitsFromR2(resp, 19, 8).uint16

proc sdStatusBit(words: array[16, uint32], bit: int): uint32 =
  ## Extract from the SD Status register. Bit numbers follow the SD spec's
  ## 511..0 numbering; word 0 is the first 32 bits read from the card.
  let wireBit = 511 - bit
  (words[wireBit div 32] shr (31 - (wireBit and 31))) and 1'u32

proc sdStatusBits(words: array[16, uint32], hi, lo: int): uint32 =
  var v = 0'u32
  var outBit = 0
  var b = lo
  while b <= hi:
    v = v or (sdStatusBit(words, b) shl outBit)
    inc b
    inc outBit
  v

proc decodeSdStatusInto(words: array[16, uint32], outHealth: var SdHealth) =
  outHealth.sdStatusBusWidth = sdStatusBits(words, 511, 510).uint8
  outHealth.sdStatusSecuredMode = sdStatusBits(words, 509, 509) != 0
  outHealth.sdStatusCardType = sdStatusBits(words, 495, 480).uint16
  outHealth.sdStatusSpeedClass = sdStatusBits(words, 447, 440).uint8
  outHealth.sdStatusPerformanceMove = sdStatusBits(words, 439, 432).uint8
  outHealth.sdStatusAuSize = sdStatusBits(words, 431, 428).uint8
  outHealth.sdStatusEraseSize = sdStatusBits(words, 423, 408).uint16
  outHealth.sdStatusEraseTimeout = sdStatusBits(words, 407, 402).uint8
  outHealth.sdStatusEraseOffset = sdStatusBits(words, 401, 400).uint8
  outHealth.sdStatusUhsSpeedGrade = sdStatusBits(words, 399, 396).uint8
  outHealth.sdStatusUhsAuSize = sdStatusBits(words, 395, 392).uint8

proc noteSdDiag(phase, command, sector: uint32, err: SdhError) =
  sdLastPhase = phase
  sdLastCommand = command
  sdLastSector = sector
  sdLastError = err
  sdLastIntStatus = regRead(SdhIntStatus)
  sdLastPresentState = regRead(SdhPresentState)
  sdLastAdmaError = regRead(SdhAdmaErr)
  sdLastAdmaAddress = regRead(SdhAdmaAddr)
  case err
  of sdhTimeout:
    inc sdTimeouts
  of sdhCmdError, sdhCrcError:
    inc sdCommandErrors
  of sdhDataError:
    inc sdDataErrors
  else:
    discard

proc sdCardAddress(sector: uint32): uint32 {.inline.} =
  if sdSdhc: sector else: sector * SectorSize

proc dmaAddr(p: pointer): uint32 =
  var a = cast[uint](p)
  if a >= OcramCachedBase and a < OcramCachedBase + OcramSize.uint:
    a = a - (OcramCachedBase - OcramBase)
  elif a >= WramCachedBase and a < WramCachedBase + WramSize.uint:
    a = a - (WramCachedBase - WramBase)
  a.uint32

proc sdAppCommand(appCmd: uint32, argument: uint32,
                  respType: SdhRespType = resp48bit,
                  dataPresent = false,
                  transferMode: uint16 = 0,
                  crcCheck = true): SdhError =
  result = sdhSendCommand(CMD55, sdRca, resp48bit)
  if result != sdhOk:
    noteSdDiag(0x5501'u32, CMD55, 0, result)
    return
  result = sdhSendCommand(appCmd, argument, respType,
                          dataPresent = dataPresent,
                          transferMode = transferMode,
                          crcCheck = crcCheck)

proc enterWriteBusMode(restore4Bit: var bool): SdhError =
  ## BL808/OX64 currently validates 4-bit reads but write commands can time out
  ## on DAT when the card remains in 4-bit mode. Keep writes conservative.
  restore4Bit = false
  when defined(bl808UnsafeSd4BitWrite):
    return sdhOk
  else:
    if not sdBus4Bit:
      return sdhOk
    result = sdAppCommand(ACMD6, 0'u32)
    if result != sdhOk:
      noteSdDiag(0x06F1'u32, ACMD6, 0, result)
      return
    sdhSetBusWidth(sdhBus1bit)
    sdBus4Bit = false
    restore4Bit = true
    return sdhOk

proc restoreWriteBusMode(restore4Bit: bool): SdhError =
  when defined(bl808UnsafeSd4BitWrite):
    if not restore4Bit:
      return sdhOk
    result = sdAppCommand(ACMD6, 2'u32)
    if result != sdhOk:
      sdhSetBusWidth(sdhBus1bit)
      sdBus4Bit = false
      noteSdDiag(0x06F2'u32, ACMD6, 0, result)
      return
    sdhSetBusWidth(sdhBus4bit)
    sdBus4Bit = true
    return sdhOk
  else:
    # ACMD6 back to 4-bit immediately after a write has proven unreliable on
    # OX64/BL808. Leave the card/host in 1-bit mode after the first write; code
    # that wants another 4-bit read window can call sdEnable4BitBus again.
    return sdhOk

proc waitTransferComplete(command, phase: uint32): SdhError =
  var countdown = 1_000_000'u32
  while countdown > 0:
    let sts = regRead(SdhIntStatus)
    if (sts and (1'u32 shl IntErrInt)) != 0:
      noteSdDiag(phase, command, 0, sdhDataError)
      sdLastIntStatus = sts
      sdLastPresentState = regRead(SdhPresentState)
      regWrite(SdhIntStatus, 0xFFFF_0000'u32)
      return sdhDataError
    if (sts and (1'u32 shl IntXferComplete)) != 0:
      regWrite(SdhIntStatus, 1'u32 shl IntXferComplete)
      return sdhOk
    countdown.dec
  noteSdDiag(phase, command, 0, sdhTimeout)
  sdhTimeout

proc r1CurrentState(r1: uint32): uint32 {.inline.} =
  (r1 and R1CurrentStateMask) shr R1CurrentStateShift

proc waitCardProgrammingComplete(command, sector, phase: uint32): SdhError =
  ## Mirror the SDK write path: after a write transfer completes, poll CMD13
  ## until the card leaves the PROGRAM state. Transfer-complete means the host
  ## data path is done; it does not guarantee the card will accept the next
  ## write immediately.
  var countdown = 100_000'u32
  while countdown > 0:
    result = sdhSendCommand(CMD13, sdRca, resp48bit)
    if result != sdhOk:
      noteSdDiag(phase, CMD13, sector, result)
      return
    let r1 = sdhReadResponse32()
    if r1CurrentState(r1) != R1StateProgramming:
      return sdhOk
    countdown.dec
  noteSdDiag(phase, command, sector, sdhTimeout)
  result = sdhTimeout

proc readStatusBlock(command, argument, bytes: uint32,
                     outWords: var openArray[uint32],
                     phase: uint32): SdhError =
  regWrite(SdhBlockSize, (1'u32 shl 16) or bytes)
  result = sdhSendCommand(command, argument, resp48bit, dataPresent = true,
                          transferMode = TmRead)
  if result != sdhOk:
    noteSdDiag(phase, command, 0, result)
    return
  result = sdhReadBlock(outWords)
  if result != sdhOk:
    noteSdDiag(phase + 1, command, 0, result)
  sdhResetData()

proc sdWriteSectorAdma(sector: uint32,
                       buf: ptr UncheckedArray[uint32]): SdhError =
  ## SDK-style ADMA2 path for single-sector writes. This is required after
  ## CMD6 SDR25 on BL808/OX64: PIO reads continue to work, but PIO CMD24 writes
  ## can timeout with command-timeout status.
  for i in 0 ..< sdAdmaSector.len:
    sdAdmaSector[i] = buf[i]

  sdAdmaDesc[0].attr = AdmaAttrValid or AdmaAttrEnd or AdmaAttrActTran
  sdAdmaDesc[0].length = SectorSize.uint16
  sdAdmaDesc[0].address = dmaAddr(addr sdAdmaSector[0])
  dcacheFlushAll()
  fenceIo()

  regWrite(SdhAdmaAddr, dmaAddr(addr sdAdmaDesc[0]))
  regWrite(SdhBlockSize, (1'u32 shl 16) or SectorSize)

  result = sdhSendCommand(CMD24, sdCardAddress(sector), resp48bit,
                          dataPresent = true,
                          transferMode = TmWrite or (1'u16 shl TmDmaEn))
  if result != sdhOk:
    inc sdWriteErrors
    noteSdDiag(0x24A1'u32, CMD24, sector, result)
    return

  result = waitTransferComplete(CMD24, 0x24A2'u32)
  if result == sdhOk:
    result = waitCardProgrammingComplete(CMD24, sector, 0x24A3'u32)
  sdhResetData()
  if result == sdhOk:
    inc sdWriteOps
  else:
    inc sdWriteErrors

proc sdWriteSectorsAdma(sector: uint32, count: uint32,
                        buf: ptr UncheckedArray[uint32]): SdhError =
  ## SDK-style ADMA2 path for CMD25. PIO CMD25 can complete but corrupt data on
  ## BL808/OX64; the SDK routes multi-block writes through ADMA2 with Auto CMD12.
  if count == 0:
    return sdhOk
  if count == 1:
    return sdWriteSectorAdma(sector, buf)
  if count > AdmaWriteScratchSectors:
    var blk = 0'u32
    while blk < count:
      let remaining = count - blk
      let chunk = if remaining > AdmaWriteScratchSectors: AdmaWriteScratchSectors else: remaining
      let base = blk * (SectorSize div 4)
      result = sdWriteSectorsAdma(sector + blk, chunk,
                                  cast[ptr UncheckedArray[uint32]](addr buf[base.int]))
      if result != sdhOk:
        return
      blk += chunk
    return sdhOk

  let byteCount = count * SectorSize
  sdLastBlockCount = count
  let srcBytes = cast[ptr UncheckedArray[uint8]](buf)
  let dstBytes = cast[ptr UncheckedArray[uint8]](addr sdAdmaWriteScratch[0])
  for i in 0 ..< byteCount.int:
    dstBytes[i] = srcBytes[i]
  sdLastAdmaData0 = sdAdmaWriteScratch[0]
  sdLastAdmaData1 = sdAdmaWriteScratch[1]

  sdAdmaDesc[0].attr = AdmaAttrValid or AdmaAttrEnd or AdmaAttrActTran
  sdAdmaDesc[0].length = byteCount.uint16
  sdAdmaDesc[0].address = dmaAddr(addr sdAdmaWriteScratch[0])
  sdLastAdmaDescAttr = sdAdmaDesc[0].attr.uint32
  sdLastAdmaDescLen = sdAdmaDesc[0].length.uint32
  sdLastAdmaDescData = sdAdmaDesc[0].address
  dcacheCleanRange(cast[uint](addr sdAdmaWriteScratch[0]), byteCount.uint)
  dcacheCleanRange(cast[uint](addr sdAdmaDesc[0]), sizeof(sdAdmaDesc).uint)
  fenceIo()

  regWrite(SdhAdmaAddr, dmaAddr(addr sdAdmaDesc[0]))
  regWrite16(SdhBlockSize, SectorSize.uint16)
  regWrite16(SdhBlockSize + 2'u, count.uint16)

  result = sdhSendCommand(CMD25, sdCardAddress(sector), resp48bit,
                          dataPresent = true, transferMode = TmWriteMultiAdma)
  if result != sdhOk:
    inc sdWriteErrors
    noteSdDiag(0x25A1'u32, CMD25, sector, result)
    return

  result = waitTransferComplete(CMD25, 0x25A5'u32)
  if result == sdhOk:
    result = waitCardProgrammingComplete(CMD25, sector, 0x25A3'u32)
  sdhResetData()
  if result == sdhOk:
    sdWriteOps += count
  else:
    inc sdWriteErrors

# =============================================================================
# SD card initialization
# =============================================================================

proc sdInit*(): SdhError =
  ## Initialize the SDHCI controller and perform the SD card init sequence.
  sdReady = false
  sdBus4Bit = false
  sdHighSpeed = false
  sdHighSpeedClockDiv = 128'u32
  enableSystemClock(GlbCgenCfg2, CgenCfg2Sdh)
  setSdhClock(true, sdhClkWifiPll96m, 7)
  gpioSetupSdh(0, 1, 2, 3, 4, 5)

  result = sdhInit()
  if result != sdhOk: return

  # CMD0 — reset card (no response)
  result = sdhSendCommand(CMD0, 0, respNone)
  if result != sdhOk: return

  # CMD8 — voltage check (SD 2.0+)
  result = sdhSendCommand(CMD8, 0x000001AA, resp48bit)
  if result != sdhOk: return
  let r7 = sdhReadResponse32()
  if (r7 and 0xFF) != 0xAA:
    return sdhCmdError

  # ACMD41 — wait for card power-up
  for i in 0 ..< 1000:
    result = sdhSendCommand(CMD55, 0, resp48bit)
    if result != sdhOk: return
    # ACMD41 returns R3 — no CRC
    result = sdhSendCommand(ACMD41, 0x40FF8000'u32, resp48bit,
                            crcCheck = false)
    if result != sdhOk: return
    let ocr = sdhReadResponse32()
    if (ocr and (1'u32 shl 31)) != 0:
      sdSdhc = (ocr and (1'u32 shl 30)) != 0
      break
  if not sdSdhc and (sdhReadResponse32() and (1'u32 shl 31)) == 0:
    return sdhTimeout

  # CMD2 — get CID (136-bit response)
  result = sdhSendCommand(CMD2, 0, resp136bit)
  if result != sdhOk: return
  sdhReadResponse(sdCidRaw)
  sdCidValid = true

  # CMD3 — get relative card address
  result = sdhSendCommand(CMD3, 0, resp48bit)
  if result != sdhOk: return
  sdRca = sdhReadResponse32() and 0xFFFF0000'u32

  # CMD9/CMD10 — addressed card metadata while still in standby.
  result = sdhSendCommand(CMD9, sdRca, resp136bit)
  if result != sdhOk: return
  sdhReadResponse(sdCsdRaw)
  sdCsdValid = true

  # CMD7 — select card
  result = sdhSendCommand(CMD7, sdRca, resp48busy)
  if result != sdhOk: return

  # CMD16 — set block length (SDSC only; SDHC always uses 512)
  if not sdSdhc:
    result = sdhSendCommand(CMD16, SectorSize, resp48bit)
    if result != sdhOk: return

  sdReady = true
  result = sdhOk

proc sdSnapshotHealth*(): SdHealth =
  ## Return a best-effort health/metadata snapshot for the currently initialized
  ## SD card. This does not format or mount the filesystem.
  result.ready = sdReady
  # Some boards do not wire the SDHCI card-detect/stable pins even though the
  # card has completed initialization and is serving block I/O. Keep raw
  # presentState below, but expose operational present/stable to OS callers.
  result.present = sdhCardInserted() or sdReady
  result.stable = sdhCardStable() or sdReady
  result.sdhc = sdSdhc
  result.bus4Bit = sdBus4Bit
  result.highSpeed = sdHighSpeed
  result.highSpeedClockDiv = sdHighSpeedClockDiv
  result.rca = sdRca
  result.lastError = sdLastError
  result.lastPhase = sdLastPhase
  result.lastCommand = sdLastCommand
  result.lastSector = sdLastSector
  result.intStatus = regRead(SdhIntStatus)
  result.presentState = regRead(SdhPresentState)
  result.cidValid = sdCidValid
  result.csdValid = sdCsdValid
  result.cidRaw = sdCidRaw
  result.csdRaw = sdCsdRaw
  result.readOps = sdReadOps
  result.writeOps = sdWriteOps
  result.readErrors = sdReadErrors
  result.writeErrors = sdWriteErrors
  result.commandErrors = sdCommandErrors
  result.dataErrors = sdDataErrors
  result.timeouts = sdTimeouts
  if result.cidValid:
    decodeCidInto(sdCidRaw, result)
  if result.csdValid:
    decodeCsdInto(sdCsdRaw, result)

  if not sdReady:
    return

  let statusErr = sdhSendCommand(CMD13, sdRca, resp48bit)
  if statusErr == sdhOk:
    result.cmd13Ok = true
    result.r1Status = sdhReadResponse32()
  else:
    noteSdDiag(0x1301'u32, CMD13, 0, statusErr)
    result.lastError = sdLastError
    result.lastPhase = sdLastPhase
    result.lastCommand = sdLastCommand
    result.intStatus = regRead(SdhIntStatus)
    result.presentState = regRead(SdhPresentState)

  # ACMD13 returns 512 bits of SD Status. Some cards/controllers may reject it;
  # leave sdStatusOk=false and preserve the rest of the snapshot in that case.
  let appErr = sdhSendCommand(CMD55, sdRca, resp48bit)
  if appErr != sdhOk:
    noteSdDiag(0x0D55'u32, CMD55, 0, appErr)
    return

  regWrite(SdhBlockSize, (1'u32 shl 16) or SdStatusBytes)
  let acmdErr = sdhSendCommand(ACMD13, 0, resp48bit,
                               dataPresent = true, transferMode = TmRead)
  if acmdErr != sdhOk:
    noteSdDiag(0x0D01'u32, ACMD13, 0, acmdErr)
    return

  var statusWords: array[16, uint32]
  let readErr = sdhReadBlock(statusWords)
  if readErr != sdhOk:
    noteSdDiag(0x0D02'u32, ACMD13, 0, readErr)
    sdhResetData()
    return
  result.sdStatusOk = true
  result.sdStatusRaw = statusWords
  decodeSdStatusInto(statusWords, result)
  sdhResetData()

proc sdSectorCount*(): uint32 =
  ## Return the CSD-derived logical sector count when available.
  if not sdCsdValid:
    return 0
  var h: SdHealth
  decodeCsdInto(sdCsdRaw, h)
  h.sectorCount

proc sdEraseBlockSectors*(): uint32 =
  ## Return the CSD erase sector size in 512-byte sectors when available.
  if not sdCsdValid:
    return 1
  var h: SdHealth
  decodeCsdInto(sdCsdRaw, h)
  if h.csdEraseSectorSize == 0: 1'u32 else: h.csdEraseSectorSize

# =============================================================================
# Block read/write
# =============================================================================

proc sdDisableHighSpeed*(): SdhError

proc sdReadSector*(sector: uint32, buf: ptr UncheckedArray[uint32]): SdhError =
  ## Read one 512-byte sector into buf (128 x uint32).
  let blockAddr = if sdSdhc: sector else: sector * SectorSize

  # Set block size = 512, count = 1
  regWrite(SdhBlockSize, (1'u32 shl 16) or SectorSize)

  # CMD17 — read single block (with transfer mode bits)
  result = sdhSendCommand(CMD17, blockAddr, resp48bit,
                          dataPresent = true, transferMode = TmRead)
  if result != sdhOk:
    inc sdReadErrors
    noteSdDiag(0x1701'u32, CMD17, sector, result)
    return

  # Wait for data ready then read via PIO
  var words: array[128, uint32]
  result = sdhReadBlock(words)
  if result != sdhOk:
    inc sdReadErrors
    noteSdDiag(0x1702'u32, CMD17, sector, result)
    return

  for i in 0 ..< 128:
    buf[i] = words[i]

  # On BL808's SDH block, single-block PIO reads can expose BUF_READ_RDY and
  # allow the full FIFO drain without subsequently raising XFER_COMPLETE. Once
  # all 512 bytes have been read, the sector is usable by FatFs. Reset DAT so
  # the next data command does not see stale DAT active/inhibit state.
  sdhResetData()
  inc sdReadOps
  return sdhOk

proc sdWriteSector*(sector: uint32, buf: ptr UncheckedArray[uint32]): SdhError =
  ## Write one 512-byte sector from buf (128 x uint32).
  let blockAddr = if sdSdhc: sector else: sector * SectorSize
  var restore4Bit = false

  if sdHighSpeed:
    return sdWriteSectorAdma(sector, buf)

  result = enterWriteBusMode(restore4Bit)
  if result != sdhOk:
    inc sdWriteErrors
    return

  regWrite(SdhBlockSize, (1'u32 shl 16) or SectorSize)

  # CMD24 — write single block
  result = sdhSendCommand(CMD24, blockAddr, resp48bit,
                          dataPresent = true, transferMode = TmWrite)
  if result != sdhOk:
    inc sdWriteErrors
    noteSdDiag(0x2401'u32, CMD24, sector, result)
    discard restoreWriteBusMode(restore4Bit)
    return

  var words: array[128, uint32]
  for i in 0 ..< 128:
    words[i] = buf[i]

  result = sdhWriteBlock(words)
  if result != sdhOk:
    inc sdWriteErrors
    noteSdDiag(0x2402'u32, CMD24, sector, result)
    discard restoreWriteBusMode(restore4Bit)
    return

  # Wait for transfer complete
  var countdown = 1_000_000'u32
  while countdown > 0:
    let sts = regRead(SdhIntStatus)
    if (sts and (1'u32 shl IntErrInt)) != 0:
      inc sdWriteErrors
      noteSdDiag(0x2403'u32, CMD24, sector, sdhDataError)
      sdLastIntStatus = sts
      sdLastPresentState = regRead(SdhPresentState)
      regWrite(SdhIntStatus, 0xFFFF_0000'u32)
      discard restoreWriteBusMode(restore4Bit)
      return sdhDataError
    if (sts and (1'u32 shl IntXferComplete)) != 0:
      regWrite(SdhIntStatus, 1'u32 shl IntXferComplete)
      result = waitCardProgrammingComplete(CMD24, sector, 0x2405'u32)
      if result != sdhOk:
        inc sdWriteErrors
        discard restoreWriteBusMode(restore4Bit)
        return
      let restoreErr = restoreWriteBusMode(restore4Bit)
      if restoreErr != sdhOk:
        inc sdWriteErrors
        return restoreErr
      inc sdWriteOps
      return sdhOk
    countdown.dec
  inc sdWriteErrors
  noteSdDiag(0x2404'u32, CMD24, sector, sdhTimeout)
  discard restoreWriteBusMode(restore4Bit)
  return sdhTimeout

proc readSectorForVerify(sector: uint32, outWords: var array[128, uint32]): SdhError =
  sdReadSector(sector, cast[ptr UncheckedArray[uint32]](addr outWords[0]))

proc sameSector(a, b: array[128, uint32]): bool =
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc sdEnable4BitBus*(): SdhError =
  ## Negotiate SD 4-bit DAT bus width. Rolls back to 1-bit if verification fails.
  if not sdReady:
    return sdhNoCard
  if sdBus4Bit:
    return sdhOk

  var before: array[128, uint32]
  result = readSectorForVerify(0, before)
  if result != sdhOk:
    return

  result = sdAppCommand(ACMD6, 2'u32)
  if result != sdhOk:
    noteSdDiag(0x0601'u32, ACMD6, 0, result)
    return
  sdhSetBusWidth(sdhBus4bit)

  var after: array[128, uint32]
  result = readSectorForVerify(0, after)
  if result == sdhOk and sameSector(before, after):
    sdBus4Bit = true
    return sdhOk

  discard sdAppCommand(ACMD6, 0'u32)
  sdhSetBusWidth(sdhBus1bit)
  sdhResetData()
  sdBus4Bit = false
  if result == sdhOk:
    result = sdhDataError
  noteSdDiag(0x0602'u32, ACMD6, 0, result)

proc sdDisable4BitBus*(): SdhError =
  ## Return to 1-bit DAT bus mode.
  if not sdReady:
    return sdhNoCard
  result = sdAppCommand(ACMD6, 0'u32)
  sdhSetBusWidth(sdhBus1bit)
  if result == sdhOk:
    sdBus4Bit = false

proc sdEnableHighSpeed*(clockDiv: uint32 = 4'u32): SdhError =
  ## Switch the card to SD high-speed function group 1/function 1, then set the
  ## requested clock divider. BL808/OX64 keeps the host high-speed bit disabled
  ## but uses ADMA for writes after the card-side switch.
  if not sdReady:
    return sdhNoCard
  if sdHighSpeed and sdHighSpeedClockDiv == clockDiv:
    return sdhOk

  var before: array[128, uint32]
  result = readSectorForVerify(0, before)
  if result != sdhOk:
    return

  var statusWords: array[16, uint32]
  result = readStatusBlock(CMD6, 0x00FF_FFF1'u32, Cmd6StatusBytes,
                           statusWords, 0x0606'u32)
  if result != sdhOk:
    return

  result = readStatusBlock(CMD6, 0x80FF_FFF1'u32, Cmd6StatusBytes,
                           statusWords, 0x0607'u32)
  if result != sdhOk:
    return

  # The BL808 SDH block is write-unstable when HcHighSpeed is set even at
  # conservative dividers. Use the card-side SDR25 function but keep host timing
  # in default mode; high-speed writes are routed through ADMA CMD24.
  sdhSetHighSpeed(false)
  sdhSetClockDiv(clockDiv)

  var after: array[128, uint32]
  result = readSectorForVerify(0, after)
  if result == sdhOk and sameSector(before, after):
    sdHighSpeed = true
    sdHighSpeedClockDiv = clockDiv
    return sdhOk

  discard readStatusBlock(CMD6, 0x80FF_FFF0'u32, Cmd6StatusBytes,
                          statusWords, 0x0608'u32)
  sdhSetHighSpeed(false)
  sdhSetClockDiv(128'u32)
  sdhResetData()
  sdHighSpeed = false
  sdHighSpeedClockDiv = 128'u32
  if result == sdhOk:
    result = sdhDataError
  noteSdDiag(0x0609'u32, CMD6, 0, result)

proc sdDisableHighSpeed*(): SdhError =
  ## Return the card/host to default-speed signaling.
  if not sdReady:
    return sdhNoCard
  sdhSetHighSpeed(false)
  sdhSetClockDiv(128'u32)
  var statusWords: array[16, uint32]
  result = readStatusBlock(CMD6, 0x80FF_FFF0'u32, Cmd6StatusBytes,
                           statusWords, 0x060A'u32)
  sdhSetHighSpeed(false)
  sdhSetClockDiv(128'u32)
  if result == sdhOk:
    sdHighSpeed = false
    sdHighSpeedClockDiv = 128'u32

proc sdReadSectors*(sector: uint32, count: uint32,
                    buf: ptr UncheckedArray[uint32]): SdhError =
  ## Read one or more 512-byte sectors. count > 1 uses CMD18 multi-block PIO.
  if count == 0:
    return sdhOk
  if count == 1:
    return sdReadSector(sector, buf)

  regWrite(SdhBlockSize, (count shl 16) or SectorSize)
  result = sdhSendCommand(CMD18, sdCardAddress(sector), resp48bit,
                          dataPresent = true, transferMode = TmReadMulti)
  if result != sdhOk:
    inc sdReadErrors
    noteSdDiag(0x1801'u32, CMD18, sector, result)
    return

  var words: array[128, uint32]
  for blk in 0'u32 ..< count:
    result = sdhReadBlock(words)
    if result != sdhOk:
      inc sdReadErrors
      noteSdDiag(0x1802'u32, CMD18, sector + blk, result)
      discard sdhSendCommand(CMD12, 0, resp48busy, cmdType = CmdTypeAbort)
      sdhResetData()
      return
    let base = blk * (SectorSize div 4)
    for i in 0 ..< words.len:
      buf[(base + i.uint32).int] = words[i]

  result = sdhSendCommand(CMD12, 0, resp48busy, cmdType = CmdTypeAbort)
  if result != sdhOk:
    noteSdDiag(0x1803'u32, CMD12, sector, result)
  else:
    result = waitTransferComplete(CMD18, 0x1804'u32)
  sdhResetData()
  if result == sdhOk:
    sdReadOps += count
  else:
    inc sdReadErrors

proc sdWriteSectors*(sector: uint32, count: uint32,
                     buf: ptr UncheckedArray[uint32]): SdhError =
  ## Write one or more 512-byte sectors. Multi-sector writes use CMD25 through
  ## ADMA2 and controller-managed Auto CMD12.
  if count == 0:
    return sdhOk
  if count == 1:
    return sdWriteSector(sector, buf)
  result = sdWriteSectorsAdma(sector, count, buf)

# =============================================================================
# FatFs disk I/O callbacks (called from ff.c via diskio.h)
# =============================================================================

const
  StaNoinit = 0x01'u8
  StaNodisk = 0x02'u8

var diskStat: uint8 = StaNoinit

proc disk_initialize*(pdrv: uint8): uint8 {.exportc, cdecl.} =
  if pdrv != 0: return StaNoinit or StaNodisk
  if sdInit() != sdhOk:
    diskStat = StaNoinit
    return diskStat
  diskStat = 0
  diskStat

proc disk_status*(pdrv: uint8): uint8 {.exportc, cdecl.} =
  if pdrv != 0: return StaNoinit or StaNodisk
  diskStat

proc disk_read*(pdrv: uint8, buff: pointer, sector: uint32,
                count: uint32): uint8 {.exportc, cdecl.} =
  ## Returns 0 (RES_OK) on success, 1 (RES_ERROR) on failure.
  if pdrv != 0 or (diskStat and StaNoinit) != 0: return 1
  let p = cast[ptr UncheckedArray[uint32]](buff)
  if sdReadSectors(sector, count, p) == sdhOk: 0 else: 1

proc disk_write*(pdrv: uint8, buff: pointer, sector: uint32,
                 count: uint32): uint8 {.exportc, cdecl.} =
  if pdrv != 0 or (diskStat and StaNoinit) != 0: return 1
  let p = cast[ptr UncheckedArray[uint32]](buff)
  if sdWriteSectors(sector, count, p) == sdhOk: 0 else: 1

proc disk_ioctl*(pdrv: uint8, cmd: uint8, buff: pointer): uint8 {.exportc, cdecl.} =
  if pdrv != 0 or (diskStat and StaNoinit) != 0: return 1
  case cmd
  of 0:  # CTRL_SYNC — no-op, PIO is synchronous
    0
  of 1:  # GET_SECTOR_COUNT
    let sectors = sdSectorCount()
    cast[ptr uint32](buff)[] = if sectors == 0: 131072'u32 else: sectors
    0
  of 3:  # GET_BLOCK_SIZE
    cast[ptr uint32](buff)[] = sdEraseBlockSectors()
    0
  else:
    0
