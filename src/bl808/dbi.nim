## BL808 DBI (Display Bus Interface) driver.
##
## DBI at 0x3001B000 — SPI-like display interface for LCD panels.
## Supports Type B (8080/6800 parallel) and Type C (SPI) interfaces.

import mmio, memmap

# =============================================================================
# DBI register offsets
# =============================================================================
const
  DbiConfig*        = DbiBase + 0x00'u   # DBI configuration
  DbiIntSts*        = DbiBase + 0x04'u   # Interrupt status
  DbiIntMask*       = DbiBase + 0x08'u   # Interrupt mask
  DbiPixCfg*        = DbiBase + 0x0C'u   # Pixel configuration
  DbiCmd*           = DbiBase + 0x10'u   # Command register
  DbiData*          = DbiBase + 0x14'u   # Data register
  DbiPeriod*        = DbiBase + 0x18'u   # Clock period
  DbiAddrCfg*       = DbiBase + 0x1C'u   # Address config (column/page)
  DbiFifoCfg0*      = DbiBase + 0x80'u   # FIFO config 0
  DbiFifoCfg1*      = DbiBase + 0x84'u   # FIFO config 1
  DbiFifoWdata*     = DbiBase + 0x88'u   # FIFO write data
  DbiFifoRdata*     = DbiBase + 0x8C'u   # FIFO read data

# =============================================================================
# DBI_CONFIG fields
# =============================================================================
const
  DbiEn*            = 0       # DBI enable
  DbiModeShift*     = 1       # DBI mode [2:1]: 0=TypeB_8080, 1=TypeB_6800, 2=TypeC_SPI3, 3=TypeC_SPI4
  DbiModeMask*      = 0x03'u32 shl 1
  DbiPixFmtShift*   = 4       # Pixel format [5:4]
  DbiPixFmtMask*    = 0x03'u32 shl 4
  DbiContinuousEn*  = 8       # Continuous mode enable
  DbiDmaEn*         = 9       # DMA enable
  DbiSclkPol*       = 12      # SPI clock polarity (Type C)
  DbiSclkPhase*     = 13      # SPI clock phase (Type C)

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
proc initDbi*(mode: DbiMode = dbiSpi4Wire, pixFmt: DbiPixelFmt = dbiRgb565,
              clockDiv: uint32 = 4): Dbi =
  ## Initialize the DBI display interface.
  result.base = DbiBase

  var cfg = 0'u32
  cfg = cfg or (mode.uint32 shl DbiModeShift)
  cfg = cfg or (pixFmt.uint32 shl DbiPixFmtShift)
  regWrite(DbiConfig, cfg)

  # Set clock period
  regWrite(DbiPeriod, clockDiv)

  # Clear FIFO
  regSet(DbiFifoCfg0, 0x0C'u32)

proc dbiWriteCmd*(dbi: Dbi, cmd: uint8) =
  ## Write a command byte to the display.
  regWrite(DbiCmd, cmd.uint32)

proc dbiWriteData*(dbi: Dbi, data: uint8) =
  ## Write a data byte to the display.
  regWrite(DbiData, data.uint32)

proc dbiWriteData16*(dbi: Dbi, data: uint16) =
  ## Write a 16-bit data value.
  regWrite(DbiData, data.uint32)

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

proc dbiEnableDma*(dbi: Dbi) =
  regSet(DbiConfig, 1'u32 shl DbiDmaEn)

proc dbiFifoAddr*(dbi: Dbi): uint {.inline.} =
  DbiFifoWdata
