## BL808 DBI (Display Bus Interface) driver.
##
## DBI at 0x3001B000 — SPI-like display interface for LCD panels.
## Supports Type B (8080/6800 parallel) and Type C (SPI) interfaces.

import mmio, memmap

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

proc dbiWritePixels*(dbi: Dbi, pixels: openArray[uint16]) =
  ## Write pixel data (RGB565) to the display via FIFO.
  regSet(DbiConfig, 1'u32 shl DbiContinuousEn)
  regSet(DbiConfig, 1'u32 shl DbiEn)
  for px in pixels:
    regWrite(DbiFifoWdata, px.uint32)
  regClear(DbiConfig, 1'u32 shl DbiEn)
  regClear(DbiConfig, 1'u32 shl DbiContinuousEn)

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
