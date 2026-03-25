## BL808 Audio Codec driver.
##
## AUADC at 0x2000AC00 — Audio ADC (microphone input, PDM)
## AUDAC at 0x20055000 — Audio DAC (speaker/headphone output)
##
## Register layouts from bouffalo_sdk auadc_reg.h and audac_reg.h.

import mmio, memmap

# =============================================================================
# AUADC (Audio ADC) register offsets — base 0x2000AC00
# =============================================================================
const
  AuadcPdmTop*      = AuadcBase + 0x00'u  # Clock gate, ADC rate
  AuadcPdmItf*      = AuadcBase + 0x04'u  # ADC ch0 enable, ITF enable
  AuadcPdmAdc0*     = AuadcBase + 0x08'u  # FIR mode
  AuadcPdmAdc1*     = AuadcBase + 0x0C'u  # K1/K2 gain coefficients
  AuadcPdmDac0*     = AuadcBase + 0x10'u  # PDM H/L, ADC source select
  AuadcPdmPdm0*     = AuadcBase + 0x1C'u  # PDM enable, channel select
  AuadcAdcS0*       = AuadcBase + 0x38'u  # Volume control (9 bits)
  AuadcAnaCfg1*     = AuadcBase + 0x60'u  # PGA chop, noise, current ctrl
  AuadcAnaCfg2*     = AuadcBase + 0x64'u  # Dither, quantization, DEM, SDM
  AuadcCmd*         = AuadcBase + 0x68'u  # ODR, PGA gain/mode, ch select, enable
  AuadcData*        = AuadcBase + 0x6C'u  # Raw data (24-bit), ready, soft reset
  AuadcRxFifoCtrl*  = AuadcBase + 0x80'u  # FIFO flush, interrupts, DMA
  AuadcRxFifoSts*   = AuadcBase + 0x84'u  # FIFO status
  AuadcRxFifoData*  = AuadcBase + 0x88'u  # FIFO read data

# =============================================================================
# AUDAC (Audio DAC) register offsets — base 0x20055000
# =============================================================================
const
  AudacCtrl0*       = AudacBase + 0x00'u  # DAC enable, ITF enable, clk gate, PWM mode
  AudacStatus*      = AudacBase + 0x04'u  # Busy, mute done, interrupts
  AudacS0*          = AudacBase + 0x08'u  # Volume, ramp rate, ZCD, mute
  AudacS0Misc*      = AudacBase + 0x0C'u  # ZCD timeout
  AudacZd0*         = AudacBase + 0x10'u  # Zero-detect time, enable
  AudacCtrl1*       = AudacBase + 0x14'u  # Mix select, DSM order/dither
  AudacTxFifoCtrl*  = AudacBase + 0x8C'u  # FIFO flush, TX interrupts, DMA
  AudacTxFifoSts*   = AudacBase + 0x90'u  # FIFO status
  AudacTxFifoData*  = AudacBase + 0x94'u  # FIFO write data

# =============================================================================
# AUADC field constants
# =============================================================================
const
  AuadcClkGateEn*   = 0    # in PdmTop: audio clock gate enable
  AuadcRateShift*   = 28   # in PdmTop: ADC rate [31:28]
  AuadcRateMask*    = 0x0F'u32 shl 28
  AuadcAdc0En*      = 0    # in PdmItf: ADC ch0 enable
  AuadcItfEn*       = 30   # in PdmItf: ADC interface enable
  AuadcVolShift*    = 0    # in AdcS0: volume [8:0]
  AuadcVolMask*     = 0x1FF'u32
  AuadcPgaGainShift* = 8   # in Cmd: PGA gain [11:8]
  AuadcPgaGainMask*  = 0x0F'u32 shl 8
  AuadcChSelPShift* = 20   # in Cmd: positive channel [22:20]
  AuadcChSelPMask*  = 0x07'u32 shl 20
  AuadcChSelNShift* = 16   # in Cmd: negative channel [18:16]
  AuadcChSelNMask*  = 0x07'u32 shl 16
  AuadcChEnShift*   = 24   # in Cmd: channel enable [25:24]
  AuadcConv*        = 28   # in Cmd: start conversion
  AuadcSdmPu*       = 29   # in Cmd: SDM power up
  AuadcPgaPu*       = 30   # in Cmd: PGA power up
  AuadcDataReady*   = 24   # in Data: data ready
  AuadcSoftRst*     = 29   # in Data: soft reset
  AuadcRxFifoFlush* = 0    # in RxFifoCtrl
  AuadcRxDrqEn*     = 4    # in RxFifoCtrl: DMA request enable
  AuadcRxChEn*      = 8    # in RxFifoCtrl: channel enable

# =============================================================================
# AUDAC field constants
# =============================================================================
const
  AudacDac0En*      = 0    # in Ctrl0: DAC enable
  AudacItfEn*       = 1    # in Ctrl0: ITF enable
  AudacClkGateEn*   = 27   # in Ctrl0: clock gate enable
  AudacVolShift*    = 13   # in S0: volume [21:13]
  AudacVolMask*     = 0x1FF'u32 shl 13
  AudacVolUpdate*   = 12   # in S0: volume update trigger
  AudacMuteSoft*    = 30   # in S0: soft mute mode
  AudacMute*        = 31   # in S0: mute
  AudacTxFifoFlush* = 0    # in TxFifoCtrl
  AudacTxDrqEn*     = 4    # in TxFifoCtrl: DMA request enable
  AudacTxChEnShift* = 8    # in TxFifoCtrl: channel enable [9:8]
  AudacTxChEnMask*  = 0x03'u32 shl 8

# =============================================================================
# Types
# =============================================================================
type
  AudioSampleRate* = enum
    auRate8k   = 0
    auRate16k  = 1
    auRate22k  = 2
    auRate32k  = 3
    auRate44k  = 4
    auRate48k  = 5
    auRate96k  = 6

# =============================================================================
# Audio ADC (AUADC) operations
# =============================================================================
proc auadcInit*(rate: AudioSampleRate = auRate48k) =
  ## Initialize the audio ADC.
  # Enable clock gate
  regSet(AuadcPdmTop, 1'u32 shl AuadcClkGateEn)
  # Set sample rate
  regModify(AuadcPdmTop, AuadcRateMask, rate.uint32 shl AuadcRateShift)
  # Enable ADC channel 0 and interface
  regSet(AuadcPdmItf, (1'u32 shl AuadcAdc0En) or (1'u32 shl AuadcItfEn))
  # Flush RX FIFO
  regSet(AuadcRxFifoCtrl, 1'u32 shl AuadcRxFifoFlush)
  # Enable FIFO channel
  regSet(AuadcRxFifoCtrl, 1'u32 shl AuadcRxChEn)

proc auadcSetVolume*(vol: uint16) =
  ## Set ADC volume (9-bit, 0-511).
  regModify(AuadcAdcS0, AuadcVolMask, vol.uint32 and 0x1FF)

proc auadcSetPgaGain*(gain: uint8) =
  ## Set PGA gain (0-15).
  regModify(AuadcCmd, AuadcPgaGainMask, (gain.uint32 and 0x0F) shl AuadcPgaGainShift)

proc auadcEnable*() =
  ## Power up ADC and start conversion.
  regSet(AuadcCmd, (1'u32 shl AuadcPgaPu) or (1'u32 shl AuadcSdmPu) or
                   (1'u32 shl AuadcConv) or (3'u32 shl AuadcChEnShift))

proc auadcDisable*() =
  regClear(AuadcCmd, (1'u32 shl AuadcPgaPu) or (1'u32 shl AuadcSdmPu) or
                     (1'u32 shl AuadcConv))

proc auadcDataReady*(): bool =
  (regRead(AuadcData) and (1'u32 shl AuadcDataReady)) != 0

proc auadcReadRaw*(): uint32 =
  ## Read raw 24-bit ADC data.
  regRead(AuadcData) and 0x00FF_FFFF

proc auadcFifoRead*(): uint32 =
  regRead(AuadcRxFifoData)

proc auadcEnableDma*() =
  regSet(AuadcRxFifoCtrl, 1'u32 shl AuadcRxDrqEn)

proc auadcRxFifoAddr*(): uint {.inline.} = AuadcRxFifoData

# =============================================================================
# Audio DAC (AUDAC) operations
# =============================================================================
proc audacInit*() =
  ## Initialize the audio DAC.
  # Enable clock gate
  regSet(AudacCtrl0, 1'u32 shl AudacClkGateEn)
  # Enable DAC and interface
  regSet(AudacCtrl0, (1'u32 shl AudacDac0En) or (1'u32 shl AudacItfEn))
  # Flush TX FIFO
  regSet(AudacTxFifoCtrl, 1'u32 shl AudacTxFifoFlush)
  # Enable both TX channels
  regSet(AudacTxFifoCtrl, 3'u32 shl AudacTxChEnShift)

proc audacSetVolume*(vol: uint16) =
  ## Set DAC volume (9-bit, 0-511).
  regModify(AudacS0, AudacVolMask, (vol.uint32 and 0x1FF) shl AudacVolShift)
  regSet(AudacS0, 1'u32 shl AudacVolUpdate)

proc audacMute*(mute: bool) =
  if mute:
    regSet(AudacS0, (1'u32 shl AudacMute) or (1'u32 shl AudacMuteSoft))
  else:
    regClear(AudacS0, 1'u32 shl AudacMute)

proc audacDisable*() =
  regClear(AudacCtrl0, (1'u32 shl AudacDac0En) or (1'u32 shl AudacItfEn))

proc audacWriteSample*(sample: uint32) {.inline.} =
  regWrite(AudacTxFifoData, sample)

proc audacEnableDma*() =
  regSet(AudacTxFifoCtrl, 1'u32 shl AudacTxDrqEn)

proc audacTxFifoAddr*(): uint {.inline.} = AudacTxFifoData
