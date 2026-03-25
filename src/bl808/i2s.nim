## BL808 I2S (Inter-IC Sound) driver.
##
## I2S at 0x2000AB00 — stereo audio interface.
## Supports master/slave mode, various sample rates and bit depths.
## TX and RX operate through FIFOs with DMA support.

import mmio, memmap

# =============================================================================
# I2S register offsets
# =============================================================================
const
  I2sCfg*           = I2sBase + 0x00'u   # I2S configuration
  I2sIntSts*        = I2sBase + 0x04'u   # Interrupt status
  I2sBclkCfg*       = I2sBase + 0x08'u   # BCLK configuration
  I2sFifoCfg0*      = I2sBase + 0x80'u   # FIFO configuration 0
  I2sFifoCfg1*      = I2sBase + 0x84'u   # FIFO configuration 1
  I2sFifoWdata*     = I2sBase + 0x88'u   # FIFO write data
  I2sFifoRdata*     = I2sBase + 0x8C'u   # FIFO read data
  I2sIoCfg*         = I2sBase + 0xFC'u   # IO configuration

# =============================================================================
# I2S_CFG fields
# =============================================================================
const
  I2sMasterEn*      = 0       # Master mode enable
  I2sRxEn*          = 1       # RX enable
  I2sTxEn*          = 2       # TX enable
  I2sFrameSelShift* = 3       # Frame format [4:3]: 0=LJ, 1=RJ, 2=I2S, 3=DSP
  I2sFrameSelMask*  = 0x03'u32 shl 3
  I2sDataSizeShift* = 5       # Data size [7:5]: 0=8bit, 1=16bit, 2=24bit, 3=32bit
  I2sDataSizeMask*  = 0x07'u32 shl 5
  I2sMonoMode*      = 8       # Mono mode (left channel only)
  I2sEndian*        = 9       # Endian swap
  I2sMute*          = 10      # Mute output

# =============================================================================
# I2S BCLK configuration fields
# =============================================================================
const
  I2sBclkDivShift*  = 0       # BCLK divider [11:0]
  I2sBclkDivMask*   = 0xFFF'u32

# =============================================================================
# FIFO fields
# =============================================================================
const
  I2sFifoDmaRxEn*   = 0
  I2sFifoDmaTxEn*   = 1
  I2sFifoTxClr*     = 2
  I2sFifoRxClr*     = 3
  I2sFifoTxCountShift* = 0
  I2sFifoTxCountMask*  = 0x1F'u32
  I2sFifoRxCountShift* = 8
  I2sFifoRxCountMask*  = 0x1F'u32 shl 8

# =============================================================================
# Types
# =============================================================================
type
  I2sFrameFormat* = enum
    i2sLeftJustified  = 0
    i2sRightJustified = 1
    i2sStandard       = 2  # Philips I2S standard
    i2sDspMode        = 3

  I2sDataSize* = enum
    i2sData8bit  = 0
    i2sData16bit = 1
    i2sData24bit = 2
    i2sData32bit = 3

  I2sRole* = enum
    i2sMaster
    i2sSlave

  I2s* = object
    base: uint

# =============================================================================
# I2S initialization
# =============================================================================
proc initI2s*(format: I2sFrameFormat = i2sStandard,
              dataSize: I2sDataSize = i2sData16bit,
              role: I2sRole = i2sMaster,
              bclkDiv: uint32 = 8): I2s =
  ## Initialize I2S peripheral.
  result.base = I2sBase

  # Disable during configuration
  var cfg = 0'u32
  if role == i2sMaster:
    cfg = cfg or (1'u32 shl I2sMasterEn)
  cfg = cfg or (format.uint32 shl I2sFrameSelShift)
  cfg = cfg or (dataSize.uint32 shl I2sDataSizeShift)
  regWrite(I2sCfg, cfg)

  # Set BCLK divider
  regModify(I2sBclkCfg, I2sBclkDivMask, bclkDiv and 0xFFF)

  # Clear FIFOs
  regSet(I2sFifoCfg0, (1'u32 shl I2sFifoTxClr) or (1'u32 shl I2sFifoRxClr))

proc enableTx*(i2s: I2s) =
  regSet(I2sCfg, 1'u32 shl I2sTxEn)

proc enableRx*(i2s: I2s) =
  regSet(I2sCfg, 1'u32 shl I2sRxEn)

proc disableTx*(i2s: I2s) =
  regClear(I2sCfg, 1'u32 shl I2sTxEn)

proc disableRx*(i2s: I2s) =
  regClear(I2sCfg, 1'u32 shl I2sRxEn)

proc mute*(i2s: I2s, enable: bool) =
  if enable:
    regSet(I2sCfg, 1'u32 shl I2sMute)
  else:
    regClear(I2sCfg, 1'u32 shl I2sMute)

# =============================================================================
# Data transfer
# =============================================================================
proc writeSample*(i2s: I2s, sample: uint32) {.inline.} =
  regWrite(I2sFifoWdata, sample)

proc readSample*(i2s: I2s): uint32 {.inline.} =
  regRead(I2sFifoRdata)

proc txFifoCount*(i2s: I2s): uint32 =
  regRead(I2sFifoCfg1) and I2sFifoTxCountMask

proc rxFifoCount*(i2s: I2s): uint32 =
  (regRead(I2sFifoCfg1) and I2sFifoRxCountMask) shr I2sFifoRxCountShift

# =============================================================================
# DMA support
# =============================================================================
proc enableDmaTx*(i2s: I2s) =
  regSet(I2sFifoCfg0, 1'u32 shl I2sFifoDmaTxEn)

proc enableDmaRx*(i2s: I2s) =
  regSet(I2sFifoCfg0, 1'u32 shl I2sFifoDmaRxEn)

proc txFifoAddr*(i2s: I2s): uint {.inline.} =
  I2sFifoWdata

proc rxFifoAddr*(i2s: I2s): uint {.inline.} =
  I2sFifoRdata
