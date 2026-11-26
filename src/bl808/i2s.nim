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
  I2sBclkCfg*       = I2sBase + 0x10'u   # BCLK configuration
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
  I2sSlaveEn*       = 1       # Slave mode enable
  I2sTxEn*          = 2       # TX data enable
  I2sRxEn*          = 3       # RX data enable
  I2sMonoMode*      = 4       # Mono mode
  I2sMute*          = 5       # Mute output
  I2sFs1tMode*      = 6       # FS 1T mode
  I2sFsChCntShift*  = 7       # Frame slot channel count [8:7]
  I2sFsChCntMask*   = 0x03'u32 shl 7
  I2sFrameSizeShift* = 12     # Frame/slot size [13:12]
  I2sFrameSizeMask* = 0x03'u32 shl 12
  I2sDataSizeShift* = 14      # Data size [15:14]
  I2sDataSizeMask*  = 0x03'u32 shl 14
  I2sFrameSelShift* = 16      # I2S mode [17:16]: 0 left-justified, 1 right-justified, 2 DSP
  I2sFrameSelMask*  = 0x03'u32 shl 16
  I2sEndian*        = 18      # Endian swap
  I2sMonoRxCh*      = 19      # Mono receive channel (0 = left)
  I2sOfsCntShift*   = 20      # Data offset after the FS edge, in BCLKs minus one [24:20]
  I2sOfsCntMask*    = 0x1F'u32 shl 20
  I2sOfsEn*         = 25      # Data offset enable

# =============================================================================
# I2S BCLK configuration fields
# =============================================================================
const
  I2sBclkDivShift*  = 0       # BCLK low time, in I2S clock cycles minus one [11:0]
  I2sBclkDivMask*   = 0xFFF'u32
  I2sBclkDivHShift* = 16      # BCLK high time, in I2S clock cycles minus one [27:16]
  I2sBclkDivHMask*  = 0xFFF'u32 shl 16

# =============================================================================
# FIFO fields
# =============================================================================
const
  # FIFO_CONFIG_0 (bit numbers from the vendor i2s_reg.h: TX is bit 0)
  I2sFifoDmaTxEn*   = 0
  I2sFifoDmaRxEn*   = 1
  I2sFifoTxClr*     = 2
  I2sFifoRxClr*     = 3
  I2sFifoTxOverflow*  = 4     # Read-only; cleared by I2sFifoTxClr
  I2sFifoTxUnderflow* = 5
  I2sFifoRxOverflow*  = 6     # Read-only; cleared by I2sFifoRxClr
  I2sFifoRxUnderflow* = 7
  I2sFifoLrMerge*   = 8       # One FIFO word holds both channels (left in the low half)
  I2sFifoLrExchange* = 9      # Exchange left and right
  I2sFifo24bLeftJustified* = 10  # 24-bit data sits in the top of the 32-bit word
  # FIFO_CONFIG_1
  I2sFifoTxCountShift* = 0
  I2sFifoTxCountMask*  = 0x1F'u32
  I2sFifoRxCountShift* = 8
  I2sFifoRxCountMask*  = 0x1F'u32 shl 8
  I2sFifoTxThresholdShift* = 16
  I2sFifoTxThresholdMask*  = 0x0F'u32 shl 16
  I2sFifoRxThresholdShift* = 24
  I2sFifoRxThresholdMask*  = 0x0F'u32 shl 24
  I2sFifoDepth*     = 16'u32  # Words in each FIFO

# =============================================================================
# IO configuration fields
# =============================================================================
const
  I2sIoTxdInv*      = 0
  I2sIoRxdInv*      = 1
  I2sIoFsInv*       = 2
  I2sIoBclkInv*     = 3
  I2sIoDegCntShift* = 4       # Deglitch count [6:4]
  I2sIoDegCntMask*  = 0x07'u32 shl 4
  I2sIoDegEn*       = 7

# =============================================================================
# Types
# =============================================================================
type
  I2sFrameFormat* = enum
    i2sLeftJustified  = 0
    i2sRightJustified = 1
    i2sStandard       = 2  # Philips I2S standard: left-justified, data one BCLK after FS
    i2sDspMode        = 3  # DSP, long frame sync

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
# BCLK
# =============================================================================
func bclkDividers*(clockHz, bclkHz: uint32): tuple[low, high: uint32] =
  ## The BCLK low and high times (in I2S clock cycles minus one) that divide
  ## `clockHz` down to the nearest rate to `bclkHz`. An odd division makes
  ## the high time the longer one.
  let bclk = max(bclkHz, 1'u32).uint64
  let total = clamp((clockHz.uint64 + bclk div 2) div bclk, 2'u64, 0x2000'u64)
  (uint32(total div 2 - 1), uint32(total - total div 2 - 1))

func bclkHz*(clockHz, low, high: uint32): uint32 =
  ## The BCLK rate dividers `low` and `high` give from `clockHz`.
  clockHz div (low + high + 2)

proc setBclkDiv*(i2s: I2s, low, high: uint32) =
  ## Set the BCLK low and high times, in I2S clock cycles minus one.
  regModify(I2sBclkCfg, I2sBclkDivMask or I2sBclkDivHMask,
            (low and 0xFFF) or ((high and 0xFFF) shl I2sBclkDivHShift))

proc setBclk*(i2s: I2s, clockHz, bclkHz: uint32) =
  ## Divide the I2S clock (`clockHz`, see `glb.setI2sRefClock`) down to
  ## `bclkHz` = sample rate x channels x slot bits.
  let d = bclkDividers(clockHz, bclkHz)
  setBclkDiv(i2s, d.low, d.high)

# =============================================================================
# FIFO
# =============================================================================
proc clearTxFifo*(i2s: I2s) =
  ## Empty the TX FIFO; also clears its overflow and underflow flags.
  regSet(I2sFifoCfg0, 1'u32 shl I2sFifoTxClr)

proc clearRxFifo*(i2s: I2s) =
  regSet(I2sFifoCfg0, 1'u32 shl I2sFifoRxClr)

proc setFifoFormat*(i2s: I2s, lrMerge: bool, lrExchange = false,
                    leftJustify24 = false) =
  ## `lrMerge`: each FIFO word carries a whole stereo frame, left in the low
  ## half (data of 8 or 16 bits only); otherwise one word per channel.
  var v = 0'u32
  if lrMerge: v = v or (1'u32 shl I2sFifoLrMerge)
  if lrExchange: v = v or (1'u32 shl I2sFifoLrExchange)
  if leftJustify24: v = v or (1'u32 shl I2sFifo24bLeftJustified)
  regModify(I2sFifoCfg0, (1'u32 shl I2sFifoLrMerge) or (1'u32 shl I2sFifoLrExchange) or
                         (1'u32 shl I2sFifo24bLeftJustified), v)

proc setFifoThresholds*(i2s: I2s, tx, rx: uint32) =
  ## FIFO levels (0..15) above which the TX and RX requests are raised.
  regModify(I2sFifoCfg1, I2sFifoTxThresholdMask or I2sFifoRxThresholdMask,
            ((tx and 0x0F) shl I2sFifoTxThresholdShift) or
            ((rx and 0x0F) shl I2sFifoRxThresholdShift))

proc fifoFlag(bit: int): bool {.inline.} =
  (regRead(I2sFifoCfg0) and (1'u32 shl bit)) != 0

proc txUnderflow*(i2s: I2s): bool =
  ## The transmitter ran out of data. Stays set until `clearTxFifo`.
  fifoFlag(I2sFifoTxUnderflow)

proc txOverflow*(i2s: I2s): bool =
  fifoFlag(I2sFifoTxOverflow)

proc rxOverflow*(i2s: I2s): bool =
  ## Received data was lost. Stays set until `clearRxFifo`.
  fifoFlag(I2sFifoRxOverflow)

proc rxUnderflow*(i2s: I2s): bool =
  fifoFlag(I2sFifoRxUnderflow)

# =============================================================================
# I2S initialization
# =============================================================================
proc disable*(i2s: I2s) =
  ## Stop the block: master/slave clocking, transmitter and receiver off.
  regClear(I2sCfg, (1'u32 shl I2sMasterEn) or (1'u32 shl I2sSlaveEn) or
                   (1'u32 shl I2sTxEn) or (1'u32 shl I2sRxEn))

proc enable*(i2s: I2s, role: I2sRole = i2sMaster) =
  ## Start clocking in `role` (a master drives BCLK and FS from here on).
  regModify(I2sCfg, (1'u32 shl I2sMasterEn) or (1'u32 shl I2sSlaveEn),
            1'u32 shl (if role == i2sMaster: I2sMasterEn else: I2sSlaveEn))

proc initI2s*(format: I2sFrameFormat = i2sStandard,
              dataSize: I2sDataSize = i2sData16bit,
              role: I2sRole = i2sMaster,
              bclkDiv: uint32 = 8,
              slotSize: I2sDataSize = dataSize,
              start: bool = true): I2s =
  ## Initialize the I2S block for stereo, MSB first, and enable `role`;
  ## TX and RX stay off (`enableTx`/`enableRx`). With `start = false` the
  ## block is left off, for `enable` to start once its clock is set up.
  ##
  ## `slotSize` is the width of each channel's slot on the wire (at least
  ## `dataSize`). `bclkDiv` is the BCLK low and high time in I2S clock cycles
  ## minus one: BCLK = I2S clock / (2 * (bclkDiv + 1)); see `setBclk`.
  ## The I2S clock gate and reference clock are in `glb` (`periphI2s`,
  ## `setI2sRefClock`), the PLL behind it is `glb.configAudioPll`.
  result.base = I2sBase

  # Off during configuration
  disable(result)

  # The hardware's mode field: 0 left-justified, 1 right-justified, 2 DSP.
  # Philips I2S is left-justified with the data one BCLK after the FS edge.
  var cfg = (slotSize.uint32 shl I2sFrameSizeShift) or
            (dataSize.uint32 shl I2sDataSizeShift)
  case format
  of i2sLeftJustified: discard
  of i2sRightJustified: cfg = cfg or (1'u32 shl I2sFrameSelShift)
  of i2sStandard: cfg = cfg or (1'u32 shl I2sOfsEn)   # offset count 0 = one BCLK
  of i2sDspMode: cfg = cfg or (2'u32 shl I2sFrameSelShift)
  regWrite(I2sCfg, cfg)

  setBclkDiv(result, bclkDiv, bclkDiv)

  # One word per channel, no DMA requests, empty FIFOs, no inversion
  regModify(I2sFifoCfg0,
            (1'u32 shl I2sFifoDmaTxEn) or (1'u32 shl I2sFifoDmaRxEn) or
            (1'u32 shl I2sFifoLrMerge) or (1'u32 shl I2sFifoLrExchange) or
            (1'u32 shl I2sFifo24bLeftJustified) or
            (1'u32 shl I2sFifoTxClr) or (1'u32 shl I2sFifoRxClr),
            (1'u32 shl I2sFifoTxClr) or (1'u32 shl I2sFifoRxClr))
  regClear(I2sIoCfg, (1'u32 shl I2sIoTxdInv) or (1'u32 shl I2sIoRxdInv) or
                     (1'u32 shl I2sIoFsInv) or (1'u32 shl I2sIoBclkInv) or
                     (1'u32 shl I2sIoDegEn))

  if start:
    enable(result, role)

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

proc disableDmaTx*(i2s: I2s) =
  regClear(I2sFifoCfg0, 1'u32 shl I2sFifoDmaTxEn)

proc disableDmaRx*(i2s: I2s) =
  regClear(I2sFifoCfg0, 1'u32 shl I2sFifoDmaRxEn)

proc txFifoAddr*(i2s: I2s): uint {.inline.} =
  I2sFifoWdata

proc rxFifoAddr*(i2s: I2s): uint {.inline.} =
  I2sFifoRdata
