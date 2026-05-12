## BL808 PDM (Pulse Density Modulation) driver.
##
## PDM interface for digital MEMS microphones.
## Configured through the AUADC/PDM subsystem at 0x2000AC00.
## PDM pins use GPIO function 4 (funcPdm).
## Supports mono and stereo capture with configurable sample rates.

import mmio, memmap

# =============================================================================
# PDM registers within Audio block
# =============================================================================
const
  PdmBase*          = AuadcBase
  PdmCfg0*         = PdmBase + 0x00'u      # PDM configuration 0
  PdmCfg1*         = PdmBase + 0x04'u      # PDM configuration 1 (interface)
  PdmAdc0*         = PdmBase + 0x08'u      # PDM ADC config 0
  PdmAdc1*         = PdmBase + 0x0C'u      # PDM ADC config 1
  PdmDac0*         = PdmBase + 0x10'u      # PDM DAC config
  PdmPdm0*         = PdmBase + 0x1C'u      # PDM mode config
  PdmRxFifoCtrl*   = PdmBase + 0x80'u      # RX FIFO control
  PdmRxFifoSts*    = PdmBase + 0x84'u      # RX FIFO status
  PdmRxFifoData*   = PdmBase + 0x88'u      # RX FIFO data

# =============================================================================
# PDM_CFG0 fields
# =============================================================================
const
  PdmClkGateEn*    = 0       # Audio clock gate enable
  PdmRateShift*    = 28      # Sample rate [31:28]
  PdmRateMask*     = 0x0F'u32 shl 28

# =============================================================================
# PDM_CFG1 fields (interface config)
# =============================================================================
const
  PdmAdc0En*       = 0       # ADC channel 0 enable
  PdmAdc1En*       = 1       # ADC channel 1 enable (stereo)
  PdmItfInvSel*    = 4       # PDM interface data invert
  PdmItfEn*        = 30      # PDM interface enable

# =============================================================================
# PDM_ADC0 fields
# =============================================================================
const
  PdmAdcFirModeShift* = 0    # FIR filter mode [1:0]
  PdmAdcFirModeMask*  = 0x03'u32
  PdmAdcScaleShift*   = 8    # ADC scaling factor [15:8]
  PdmAdcScaleMask*    = 0xFF'u32 shl 8

# =============================================================================
# PDM_ADC1 fields
# =============================================================================
const
  PdmAdcKShift*       = 0    # ADC K parameter [15:0]
  PdmAdcKMask*        = 0xFFFF'u32

# =============================================================================
# PDM_PDM0 fields
# =============================================================================
const
  PdmPdmEn*        = 0       # PDM mode enable
  PdmPdmCh0Sel*    = 4       # Channel 0 L/R select
  PdmPdmCh1Sel*    = 5       # Channel 1 L/R select

# =============================================================================
# RX FIFO control fields
# =============================================================================
const
  PdmRxFifoFlush*  = 0       # FIFO flush (self-clearing)
  PdmRxDrqEn*      = 4       # DMA request enable
  PdmRxChEn*       = 8       # RX channel enable
  PdmRxFifoThreshShift* = 16 # FIFO threshold [21:16]
  PdmRxFifoThreshMask*  = 0x3F'u32 shl 16
  PdmRxIntEn*      = 24      # RX FIFO interrupt enable
  PdmRxIntOverrun* = 25      # RX overrun interrupt enable

# =============================================================================
# RX FIFO status fields
# =============================================================================
const
  PdmRxFifoCountShift* = 0   # Available samples [6:0]
  PdmRxFifoCountMask*  = 0x7F'u32
  PdmRxFifoFull*       = 8   # FIFO full flag
  PdmRxFifoEmpty*      = 9   # FIFO empty flag
  PdmRxOverrun*        = 10  # FIFO overrun flag

# =============================================================================
# Volume register (within audio block for PDM ADC)
# =============================================================================
const
  PdmVolReg*       = PdmBase + 0x38'u      # ADC volume control
  PdmVolShift*     = 0       # Volume [8:0]
  PdmVolMask*      = 0x1FF'u32

# =============================================================================
# Types
# =============================================================================
type
  PdmSampleRate* = enum
    pdmRate8k   = 0   # 8 kHz
    pdmRate16k  = 1   # 16 kHz
    pdmRate22k  = 2   # 22.05 kHz
    pdmRate32k  = 3   # 32 kHz
    pdmRate44k  = 4   # 44.1 kHz
    pdmRate48k  = 5   # 48 kHz
    pdmRate96k  = 6   # 96 kHz

  PdmChannel* = enum
    pdmMono     = 0   # Single channel (ch0 only)
    pdmStereo   = 1   # Dual channel (ch0 + ch1)

  PdmError* = enum
    pdmOk
    pdmTimeout
    pdmOverrun
    pdmFifoEmpty

# =============================================================================
# PDM initialization
# =============================================================================
proc pdmInit*(rate: PdmSampleRate = pdmRate48k, channel: PdmChannel = pdmMono) =
  ## Initialize the PDM interface for digital microphone capture.
  ##
  ## Configure GPIO pins for funcPdm (function 4) before calling.
  ## PDM_CLK and PDM_DAT pins vary by board; on Ox64, GPIO6/GPIO7 can be used.

  # Disable interface during configuration
  regClear(PdmCfg1, 1'u32 shl PdmItfEn)

  # Enable audio clock gate
  regSet(PdmCfg0, 1'u32 shl PdmClkGateEn)

  # Set sample rate
  regModify(PdmCfg0, PdmRateMask, rate.uint32 shl PdmRateShift)

  # Enable PDM mode
  regSet(PdmPdm0, 1'u32 shl PdmPdmEn)

  # Configure channel(s)
  case channel
  of pdmMono:
    regSet(PdmCfg1, 1'u32 shl PdmAdc0En)
    regClear(PdmCfg1, 1'u32 shl PdmAdc1En)
  of pdmStereo:
    regSet(PdmCfg1, (1'u32 shl PdmAdc0En) or (1'u32 shl PdmAdc1En))
    # ch0 = left, ch1 = right
    regClear(PdmPdm0, 1'u32 shl PdmPdmCh0Sel)
    regSet(PdmPdm0, 1'u32 shl PdmPdmCh1Sel)

  # Set default ADC scaling
  regModify(PdmAdc0, PdmAdcScaleMask, 0x10'u32 shl PdmAdcScaleShift)

  # Flush RX FIFO
  regSet(PdmRxFifoCtrl, 1'u32 shl PdmRxFifoFlush)

  # Enable FIFO channel
  regSet(PdmRxFifoCtrl, 1'u32 shl PdmRxChEn)

# =============================================================================
# Enable / Disable
# =============================================================================
proc pdmEnable*() =
  ## Enable the PDM interface and start capture.
  regSet(PdmCfg1, 1'u32 shl PdmItfEn)

proc pdmDisable*() =
  ## Disable the PDM interface.
  regClear(PdmCfg1, 1'u32 shl PdmItfEn)

# =============================================================================
# Gain / Volume
# =============================================================================
proc pdmSetGain*(volume: uint16) =
  ## Set PDM capture volume (9-bit, 0-511).
  ## Higher values increase gain. Default ~0x100 is unity gain.
  regModify(PdmVolReg, PdmVolMask, volume.uint32 and 0x1FF)

proc pdmSetAdcScale*(scale: uint8) =
  ## Set ADC scaling factor (0-255). Adjusts digital gain in the ADC path.
  regModify(PdmAdc0, PdmAdcScaleMask, scale.uint32 shl PdmAdcScaleShift)

# =============================================================================
# FIFO status
# =============================================================================
proc pdmFifoCount*(): uint32 {.inline.} =
  ## Number of samples available in the RX FIFO.
  regRead(PdmRxFifoSts) and PdmRxFifoCountMask

proc pdmFifoFull*(): bool {.inline.} =
  (regRead(PdmRxFifoSts) and (1'u32 shl PdmRxFifoFull)) != 0

proc pdmFifoEmpty*(): bool {.inline.} =
  (regRead(PdmRxFifoSts) and (1'u32 shl PdmRxFifoEmpty)) != 0

proc pdmOverrun*(): bool {.inline.} =
  ## Check if the RX FIFO has experienced an overrun.
  (regRead(PdmRxFifoSts) and (1'u32 shl PdmRxOverrun)) != 0

# =============================================================================
# Sample read
# =============================================================================
proc pdmReadSample*(): uint32 {.inline.} =
  ## Read a single raw sample from the RX FIFO.
  ## Caller should check pdmFifoEmpty() first.
  regRead(PdmRxFifoData)

proc pdmFifoRead*(timeout: uint32 = 1_000_000): (uint32, PdmError) =
  ## Read a sample from the FIFO, blocking until data is available or timeout.
  var countdown = timeout
  while pdmFifoEmpty():
    countdown.dec
    if countdown == 0: return (0'u32, pdmTimeout)
  if pdmOverrun():
    return (regRead(PdmRxFifoData), pdmOverrun)
  (regRead(PdmRxFifoData), pdmOk)

# =============================================================================
# DMA support
# =============================================================================
proc pdmEnableDma*() =
  ## Enable DMA requests for PDM RX FIFO.
  regSet(PdmRxFifoCtrl, 1'u32 shl PdmRxDrqEn)

proc pdmDisableDma*() =
  regClear(PdmRxFifoCtrl, 1'u32 shl PdmRxDrqEn)

proc pdmRxFifoAddr*(): uint {.inline.} =
  ## Return the RX FIFO data register address (for DMA configuration).
  PdmRxFifoData

# =============================================================================
# FIFO management
# =============================================================================
proc pdmFlushFifo*() =
  ## Flush the RX FIFO, discarding all pending samples.
  regSet(PdmRxFifoCtrl, 1'u32 shl PdmRxFifoFlush)

proc pdmSetFifoThreshold*(thresh: uint8) =
  ## Set FIFO threshold for interrupt/DMA trigger (0-63).
  regModify(PdmRxFifoCtrl, PdmRxFifoThreshMask,
            (thresh.uint32 and 0x3F) shl PdmRxFifoThreshShift)

# =============================================================================
# Interrupt support
# =============================================================================
proc pdmEnableInterrupt*() =
  regSet(PdmRxFifoCtrl, 1'u32 shl PdmRxIntEn)

proc pdmDisableInterrupt*() =
  regClear(PdmRxFifoCtrl, 1'u32 shl PdmRxIntEn)

proc pdmEnableOverrunInterrupt*() =
  regSet(PdmRxFifoCtrl, 1'u32 shl PdmRxIntOverrun)

proc pdmDisableOverrunInterrupt*() =
  regClear(PdmRxFifoCtrl, 1'u32 shl PdmRxIntOverrun)
