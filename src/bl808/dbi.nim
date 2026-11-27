## BL808 DBI (Display Bus Interface) driver.
##
## DBI at 0x3001B000 — SPI-like display interface for LCD panels.
## Supports Type B (8080/6800 parallel) and Type C (SPI) interfaces.

import dma, dmafifo, mmio, memmap
when defined(bl808d0):
  import dmablock

# =============================================================================
# DBI register offsets (verified against the BL808 RM and hardware)
# =============================================================================
const
  DbiConfig*        = DbiBase + 0x00'u   # DBI configuration
  DbiIntSts*        = DbiBase + 0x04'u   # Interrupt status
  DbiBusBusyReg*    = DbiBase + 0x08'u   # Bus busy status
  DbiPixCnt*        = DbiBase + 0x0C'u   # Pixel count and output format
  DbiPixCfg*        = DbiPixCnt          # Backward-compatible alias
  DbiPrd*           = DbiBase + 0x10'u   # Clock period
  DbiCmd*           = DbiConfig          # Command lives in DBI_CONFIG[15:8]
  DbiWdata*         = DbiBase + 0x18'u   # Write data
  DbiRdata*         = DbiBase + 0x1C'u   # Read data
  DbiFifoCfg0*      = DbiBase + 0x80'u   # FIFO config 0
  DbiFifoCfg1*      = DbiBase + 0x84'u   # FIFO config 1
  DbiFifoWdata*     = DbiBase + 0x88'u   # FIFO write data

# =============================================================================
# DBI_CONFIG fields
# =============================================================================
const
  DbiEn*            = 0       # DBI enable
  DbiSel*           = 1       # 0=Type B, 1=Type C
  DbiCmdEn*         = 2       # Command phase enable
  DbiDatEn*         = 3       # Data phase enable
  DbiDatWr*         = 4       # Data write (1=write, 0=read)
  DbiDatTp*         = 5       # Data type (0=parameter, 1=pixel)
  DbiDatBcShift*    = 6       # Data byte count [7:6]
  DbiDatBcMask*     = 0x03'u32 shl DbiDatBcShift
  DbiCmdShift*      = 8       # Command byte [15:8]
  DbiCmdMask*       = 0xFF'u32 shl DbiCmdShift
  DbiSclkPol*       = 16      # SPI clock polarity (Type C)
  DbiSclkPhase*     = 17      # SPI clock phase (Type C)
  DbiContinuousEn*  = 18      # Continuous mode enable
  DbiDmyEn*         = 19      # Dummy cycle enable
  DbiDmyCntShift*   = 20      # Dummy cycle count [23:20]
  DbiDmyCntMask*    = 0x0F'u32 shl DbiDmyCntShift
  DbiTc3WireMode*   = 27      # Type C 3-wire mode enable
  DbiTcDegEn*       = 28      # Type C input deglitch enable
  DbiTcDegCntShift* = 29      # Type C deglitch cycle count [31:29]
  DbiTcDegCntMask*  = 0x07'u32 shl DbiTcDegCntShift
  DbiBusBusy*       = 0       # DBI_BUS_BUSY bit
  DbiTypeSelectMask* = 1'u32 shl DbiSel
  DbiTc3WireModeMask* = 1'u32 shl DbiTc3WireMode
  DbiModeShift*     = DbiSel  # Compatibility alias; mode bits are not contiguous
  DbiModeMask*      = DbiTypeSelectMask or DbiTc3WireModeMask

# =============================================================================
# DBI_PIX_CNT fields
# =============================================================================
const
  DbiPixCountShift*  = 0
  DbiPixCountMask*   = 0x00FF_FFFF'u32
  DbiPixFormat*      = 31      # 0=RGB565, 1=RGB666/RGB888
  DbiPixFormatMask*  = 1'u32 shl DbiPixFormat

# =============================================================================
# Types
# =============================================================================
type
  DbiMode* = enum
    dbi8080    = 0   # 8080 parallel interface
    dbi6800    = 1   # 6800 parallel interface
    dbiSpi3Wire = 2  # SPI 3-wire
    dbiSpi4Wire = 3  # SPI 4-wire

  DbiPixelFmt* = enum
    dbiRgb565  = 0   # 16-bit RGB565
    dbiRgb666  = 1   # 18-bit RGB666
    dbiRgb888  = 2   # 24-bit RGB888

  Dbi* = object
    base: uint

# =============================================================================
# DBI operations
# =============================================================================
proc modeBits(mode: DbiMode): uint32 {.inline.} =
  case mode
  of dbi8080, dbi6800:
    0'u32
  of dbiSpi3Wire:
    DbiTypeSelectMask or DbiTc3WireModeMask
  of dbiSpi4Wire:
    DbiTypeSelectMask

proc initDbi*(mode: DbiMode = dbiSpi4Wire, pixFmt: DbiPixelFmt = dbiRgb565,
              clockDiv: uint32 = 4): Dbi =
  ## Initialize the DBI display interface.
  result.base = DbiBase

  var cfg = mode.modeBits()
  cfg = cfg or (1'u32 shl DbiCmdEn) or (1'u32 shl DbiDatEn) or (1'u32 shl DbiDatWr)
  regWrite(DbiConfig, cfg)

  var pix = regRead(DbiPixCnt)
  pix = pix and not DbiPixFormatMask
  if pixFmt != dbiRgb565:
    pix = pix or DbiPixFormatMask
  regWrite(DbiPixCnt, pix)

  # Set clock period
  regWrite(DbiPrd, clockDiv)

  # Clear FIFO
  regSet(DbiFifoCfg0, 1'u32 shl 2)

proc dbiWriteCmd*(dbi: Dbi, cmd: uint8) =
  ## Write a command byte to the display.
  regModify(DbiConfig, DbiCmdMask, cmd.uint32 shl DbiCmdShift)

proc dbiWriteData*(dbi: Dbi, data: uint8) =
  ## Write a data byte to the display command data register.
  regWrite(DbiWdata, data.uint32)

proc dbiWriteData16*(dbi: Dbi, data: uint16) =
  ## Write a 16-bit data value to the display command data register.
  regWrite(DbiWdata, data.uint32)

const DbiDmaTx* = DmaFifoEndpoint(
  controller: dma2, request: dmaMmDbiTx.uint32, address: DbiFifoWdata,
  enableRegister: DbiFifoCfg0, enableMask: 1, width: width32,
  direction: dmaFifoWrite)

type DbiError* = enum dbiOk, dbiDmaError, dbiTimeout

proc dbiWritePixels*(dbi: Dbi; pixels: openArray[uint16]): DbiError {.discardable.} =
  ## Transfer RGB565 pixel data through the D0 DMA controller.
  if pixels.len == 0: return dbiOk
  when not defined(bl808d0):
    return dbiDmaError
  else:
    let config = regRead(DbiConfig)
    let enable = 1'u32 shl DbiEn
    if pixels.len > DbiPixCountMask.int + 1 or (config and enable) != 0:
      return dbiDmaError

    let pixelsAddress = unsafeAddr pixels[0]
    let bytes = pixels.len * sizeof(uint16)
    var staging: seq[uint32]
    var source = cast[pointer](pixelsAddress)
    var dmaBytes = bytes
    if ((cast[uint](source) or bytes.uint) and 3) != 0 or
        not dmaBufferInRam(cast[uint](source), bytes):
      staging.setLen((pixels.len + 1) div 2)
      copyMem(addr staging[0], pixelsAddress, bytes)
      source = addr staging[0]
      dmaBytes = staging.len * sizeof(uint32)

    const
      FifoFormat = 7'u32 shl 29
      EndClear = 1'u32 shl 16
    var transfer: DmaFifoTransfer
    if not transfer.prepare(DbiDmaTx, source, dmaBytes): return dbiDmaError
    regModify(DbiFifoCfg0, FifoFormat, FifoFormat or (1'u32 shl 2))
    regModify(DbiPixCnt, DbiPixCountMask, (pixels.len - 1).uint32)
    regSet(DbiIntSts, EndClear)
    if not transfer.start():
      transfer.release()
      return dbiDmaError
    regWrite(DbiConfig, config or enable or (1'u32 shl DbiDatTp) or
      (1'u32 shl DbiDatEn) or (1'u32 shl DbiDatWr))
    var budget = pixels.len.uint64 * 100_000
    result = dbiTimeout
    while budget != 0:
      let state = transfer.status()
      if state in {dmaBlockError, dmaBlockIdle}:
        result = dbiDmaError
        break
      if state == dmaBlockDone and (regRead(DbiIntSts) and 1) != 0:
        result = dbiOk
        break
      dec budget
    regWrite(DbiConfig, config)
    transfer.release(result == dbiOk)
    # An odd pixel count can leave its padded half-word in the FIFO.
    regSet(DbiFifoCfg0, 1'u32 shl 2)
    regSet(DbiIntSts, EndClear)

proc dbiSetWindow*(dbi: Dbi, x0, y0, x1, y1: uint16) =
  ## Set the display window for pixel writes (typical LCD command sequence).
  dbi.dbiWriteCmd(0x2A)  # Column address set
  dbi.dbiWriteData16(x0)
  dbi.dbiWriteData16(x1)
  dbi.dbiWriteCmd(0x2B)  # Page address set
  dbi.dbiWriteData16(y0)
  dbi.dbiWriteData16(y1)
  dbi.dbiWriteCmd(0x2C)  # Memory write

proc dbiFifoAddr*(dbi: Dbi): uint {.inline.} =
  DbiFifoWdata
