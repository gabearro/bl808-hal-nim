## SD card block device for FatFs.
##
## Implements the SD card initialization sequence (CMD0 -> CMD8 -> ACMD41 ->
## CMD2 -> CMD3 -> CMD7) and exports the FatFs disk_* callbacks as cdecl
## functions that FatFs's ff.c calls through its diskio interface.

import ../sdh, ../mmio, ../memmap
import ../glb, ../gpio

# =============================================================================
# SD protocol constants
# =============================================================================
const
  CMD0  = 0'u32   # GO_IDLE_STATE
  CMD2  = 2'u32   # ALL_SEND_CID
  CMD3  = 3'u32   # SEND_RELATIVE_ADDR
  CMD7  = 7'u32   # SELECT_CARD
  CMD8  = 8'u32   # SEND_IF_COND
  CMD16 = 16'u32  # SET_BLOCKLEN
  CMD17 = 17'u32  # READ_SINGLE_BLOCK
  CMD24 = 24'u32  # WRITE_BLOCK
  CMD55 = 55'u32  # APP_CMD
  ACMD41 = 41'u32 # SD_SEND_OP_COND

  SectorSize = 512'u32

# Transfer mode bits
const
  TmRead = (1'u16 shl TmDataDir) or (1'u16 shl TmBlkCntEn)
  TmWrite = (1'u16 shl TmBlkCntEn)  # direction=0 => write

# =============================================================================
# SD card state
# =============================================================================
var
  sdRca: uint32 = 0
  sdSdhc: bool = false
  sdReady: bool = false

# =============================================================================
# SD card initialization
# =============================================================================

proc sdInit*(): SdhError =
  ## Initialize the SDHCI controller and perform the SD card init sequence.
  enableSystemClock(GlbCgenCfg2, CgenCfg2Sdh)
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

  # CMD3 — get relative card address
  result = sdhSendCommand(CMD3, 0, resp48bit)
  if result != sdhOk: return
  sdRca = sdhReadResponse32() and 0xFFFF0000'u32

  # CMD7 — select card
  result = sdhSendCommand(CMD7, sdRca, resp48busy)
  if result != sdhOk: return

  # CMD16 — set block length (SDSC only; SDHC always uses 512)
  if not sdSdhc:
    result = sdhSendCommand(CMD16, SectorSize, resp48bit)
    if result != sdhOk: return

  sdReady = true
  result = sdhOk

# =============================================================================
# Block read/write
# =============================================================================

proc sdReadSector*(sector: uint32, buf: ptr UncheckedArray[uint32]): SdhError =
  ## Read one 512-byte sector into buf (128 x uint32).
  let blockAddr = if sdSdhc: sector else: sector * SectorSize

  # Set block size = 512, count = 1
  regWrite(SdhBlockSize, (1'u32 shl 16) or SectorSize)

  # CMD17 — read single block (with transfer mode bits)
  result = sdhSendCommand(CMD17, blockAddr, resp48bit,
                          dataPresent = true, transferMode = TmRead)
  if result != sdhOk: return

  # Wait for data ready then read via PIO
  var words: array[128, uint32]
  result = sdhReadBlock(words)
  if result != sdhOk: return

  for i in 0 ..< 128:
    buf[i] = words[i]

  # Wait for transfer complete
  var countdown = 1_000_000'u32
  while countdown > 0:
    let sts = regRead(SdhIntStatus)
    if (sts and (1'u32 shl IntXferComplete)) != 0:
      regWrite(SdhIntStatus, 1'u32 shl IntXferComplete)
      return sdhOk
    countdown.dec
  return sdhTimeout

proc sdWriteSector*(sector: uint32, buf: ptr UncheckedArray[uint32]): SdhError =
  ## Write one 512-byte sector from buf (128 x uint32).
  let blockAddr = if sdSdhc: sector else: sector * SectorSize

  regWrite(SdhBlockSize, (1'u32 shl 16) or SectorSize)

  # CMD24 — write single block
  result = sdhSendCommand(CMD24, blockAddr, resp48bit,
                          dataPresent = true, transferMode = TmWrite)
  if result != sdhOk: return

  var words: array[128, uint32]
  for i in 0 ..< 128:
    words[i] = buf[i]

  result = sdhWriteBlock(words)
  if result != sdhOk: return

  # Wait for transfer complete
  var countdown = 1_000_000'u32
  while countdown > 0:
    let sts = regRead(SdhIntStatus)
    if (sts and (1'u32 shl IntXferComplete)) != 0:
      regWrite(SdhIntStatus, 1'u32 shl IntXferComplete)
      return sdhOk
    countdown.dec
  return sdhTimeout

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
  for i in 0'u32 ..< count:
    let offset = i * (SectorSize div 4)
    if sdReadSector(sector + i, cast[ptr UncheckedArray[uint32]](addr p[offset])) != sdhOk:
      return 1
  0

proc disk_write*(pdrv: uint8, buff: pointer, sector: uint32,
                 count: uint32): uint8 {.exportc, cdecl.} =
  if pdrv != 0 or (diskStat and StaNoinit) != 0: return 1
  let p = cast[ptr UncheckedArray[uint32]](buff)
  for i in 0'u32 ..< count:
    let offset = i * (SectorSize div 4)
    if sdWriteSector(sector + i, cast[ptr UncheckedArray[uint32]](addr p[offset])) != sdhOk:
      return 1
  0

proc disk_ioctl*(pdrv: uint8, cmd: uint8, buff: pointer): uint8 {.exportc, cdecl.} =
  if pdrv != 0 or (diskStat and StaNoinit) != 0: return 1
  case cmd
  of 0:  # CTRL_SYNC — no-op, PIO is synchronous
    0
  of 1:  # GET_SECTOR_COUNT — report 64MB / 512 = 131072 sectors
    cast[ptr uint32](buff)[] = 131072'u32
    0
  of 3:  # GET_BLOCK_SIZE — erase block = 1 sector for simplicity
    cast[ptr uint32](buff)[] = 1'u32
    0
  else:
    0
