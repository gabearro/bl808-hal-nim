## BL808 ADC (Analog-to-Digital Converter) driver.
##
## The BL808 has a 12-bit SAR ADC accessible through the GPIP block
## at 0x20002000. ADC channels are multiplexed from GPIO pins.
##
## Supports: single-shot conversion, scan mode, FIFO buffering, DMA.

import mmio, memmap

# =============================================================================
# GPIP / ADC register addresses
# =============================================================================
const
  # GPIP registers — FIFO/DMA access (at GPIP base 0x20002000)
  GpipGpadcConfig*  = GpipBase + 0x000'u  # GPADC DMA/FIFO config & status
  GpipGpadcDmaRdata* = GpipBase + 0x004'u # FIFO read data (26-bit)

  # ADC configuration registers — in AON/HBN domain (at 0x2000F000)
  AonBase = HbnBase  # AON shares HBN base address
  AdcCmd*           = AonBase + 0x90C'u   # Global enable, conv start, soft reset, ch select
  AdcCfg1*          = AonBase + 0x910'u   # Cal, continuous, resolution, clock div, scan
  AdcCfg2*          = AonBase + 0x914'u   # Diff mode, Vref, PGA, delay
  AdcScanPos1*      = AonBase + 0x918'u   # Scan positive sequence ch0-5
  AdcScanPos2*      = AonBase + 0x91C'u   # Scan positive sequence ch6-11
  AdcScanNeg1*      = AonBase + 0x920'u   # Scan negative sequence ch0-5
  AdcScanNeg2*      = AonBase + 0x924'u   # Scan negative sequence ch6-11
  AdcStatus*        = AonBase + 0x928'u   # Data ready status
  AdcIsr*           = AonBase + 0x92C'u   # Saturation interrupts
  AdcResult*        = AonBase + 0x930'u   # Conversion result (26-bit)
  AdcRawResult*     = AonBase + 0x934'u   # Raw result (12-bit)
  AdcCalData*       = AonBase + 0x938'u   # OS calibration data

# =============================================================================
# AON_GPADC_REG_CMD fields (offset 0x90C from AON base)
# =============================================================================
const
  AdcGlobalEn*      = 0       # Global ADC enable
  AdcConvStart*     = 1       # Start conversion
  AdcSoftRst*       = 2       # Soft reset
  AdcNegSelShift*   = 3       # Negative channel select [7:3]
  AdcNegSelMask*    = 0x1F'u32 shl 3
  AdcPosSelShift*   = 8       # Positive channel select [12:8]
  AdcPosSelMask*    = 0x1F'u32 shl 8
  AdcNegGnd*        = 13      # Negative channel = GND

# =============================================================================
# AON_GPADC_REG_CONFIG1 fields (offset 0x910)
# =============================================================================
const
  AdcCalOsEn*       = 0       # Offset calibration enable
  AdcContConvEn*    = 1       # Continuous conversion enable
  AdcResSelShift*   = 2       # Resolution select [4:2]
  AdcResSelMask*    = 0x07'u32 shl 2
  AdcClkDivShift*   = 18      # Clock divider ratio [20:18]
  AdcClkDivMask*    = 0x07'u32 shl 18
  AdcScanLenShift*  = 21      # Scan length [24:21] (0-11 = 1-12 channels)
  AdcScanLenMask*   = 0x0F'u32 shl 21
  AdcScanEn*        = 25      # Scan mode enable
  AdcDitherEn*      = 26      # Dither enable

# =============================================================================
# AON_GPADC_REG_CONFIG2 fields (offset 0x914)
# =============================================================================
const
  AdcDiffMode*      = 2       # Differential mode
  AdcVrefSel*       = 3       # Vref select (0=internal, 1=external)
  AdcVbatEn*        = 4       # VBAT sensing enable
  AdcTsEn*          = 6       # Temperature sensor enable
  AdcPgaEnBit*      = 13      # PGA enable

# =============================================================================
# GPIP_GPADC_CONFIG fields (offset 0x000 from GPIP base)
# =============================================================================
const
  GpipDmaEn*        = 0       # DMA enable
  GpipFifoClr*      = 1       # FIFO clear
  GpipFifoNe*       = 2       # FIFO not empty
  GpipFifoFull*     = 3       # FIFO full
  GpipDataReady*    = 4       # Data ready
  GpipDataCountShift* = 16    # FIFO data count [21:16]
  GpipDataCountMask*  = 0x3F'u32 shl 16

# =============================================================================
# Result fields
# =============================================================================
const
  AdcResultDataMask*  = 0x03FF_FFFF'u32  # 26-bit result

# =============================================================================
# Types
# =============================================================================
type
  AdcChannel* = range[0..15]
    ## ADC channels 0-11 map to GPIO pins via analog mux.
    ## Channel 12 = DAC output A, 13 = DAC output B
    ## Channel 14 = TSEN (temperature sensor)
    ## Channel 15 = VBAT/2

  AdcResolution* = enum
    adc12Bit = 0
    adc14Bit = 2
    adc16Bit = 4

  AdcVref* = enum
    vref3v3   = 0   # 3.3V internal reference
    vref2v0   = 1   # 2.0V internal reference

  AdcConvMode* = enum
    adcSingle = 0   # Single-shot
    adcContinuous = 1 # Continuous
    adcScan   = 2   # Scan multiple channels

  AdcError* = enum
    adcOk
    adcTimeout
    adcNotReady

  Adc* = object
    resolution: AdcResolution

# =============================================================================
# ADC initialization
# =============================================================================
proc initAdc*(resolution: AdcResolution = adc12Bit,
              vref: AdcVref = vref3v3, clkDiv: uint32 = 2): Adc =
  ## Initialize the ADC peripheral.
  ## ADC configuration registers are in the AON domain at HBN base + 0x90C.
  ## FIFO access is via GPIP at 0x20002000.
  result.resolution = resolution

  # Soft reset
  regSet(AdcCmd, 1'u32 shl AdcSoftRst)
  for i in 0 ..< 100: discard regRead(AdcCmd)
  regClear(AdcCmd, 1'u32 shl AdcSoftRst)

  # Configure ADC_CONFIG1: resolution, clock divider
  var cfg1 = regRead(AdcCfg1)
  cfg1 = (cfg1 and not AdcResSelMask) or (resolution.uint32 shl AdcResSelShift)
  cfg1 = (cfg1 and not AdcClkDivMask) or ((clkDiv and 0x07) shl AdcClkDivShift)
  regWrite(AdcCfg1, cfg1)

  # Configure ADC_CONFIG2: Vref select
  if vref == vref2v0:
    regSet(AdcCfg2, 1'u32 shl AdcVrefSel)
  else:
    regClear(AdcCfg2, 1'u32 shl AdcVrefSel)

  # Clear GPIP FIFO
  regSet(GpipGpadcConfig, 1'u32 shl GpipFifoClr)

# =============================================================================
# Single-shot conversion
# =============================================================================
proc readChannel*(adc: Adc, ch: AdcChannel, timeout: uint32 = 100_000): (uint16, AdcError) =
  ## Perform a single-shot ADC conversion on the specified channel.
  ## Returns the raw ADC value.

  # Set positive channel, negative = GND
  var cmd = regRead(AdcCmd)
  cmd = (cmd and not AdcPosSelMask) or (ch.uint32 shl AdcPosSelShift)
  cmd = cmd or (1'u32 shl AdcNegGnd)
  regWrite(AdcCmd, cmd)

  # Disable scan mode, disable continuous
  regClear(AdcCfg1, (1'u32 shl AdcScanEn) or (1'u32 shl AdcContConvEn))

  # Enable ADC and start conversion
  regSet(AdcCmd, (1'u32 shl AdcGlobalEn) or (1'u32 shl AdcConvStart))

  # Wait for data ready
  var countdown = timeout
  while countdown > 0:
    if (regRead(AdcStatus) and 1) != 0:
      let raw = regRead(AdcResult) and AdcResultDataMask
      # Stop conversion
      regClear(AdcCmd, (1'u32 shl AdcGlobalEn) or (1'u32 shl AdcConvStart))
      return (raw.uint16, adcOk)
    countdown.dec

  regClear(AdcCmd, (1'u32 shl AdcGlobalEn) or (1'u32 shl AdcConvStart))
  (0'u16, adcTimeout)

# =============================================================================
# Scan mode
# =============================================================================
proc startScan*(adc: Adc, channels: openArray[AdcChannel]) =
  ## Start scanning multiple ADC channels continuously.
  ## Results are placed in the GPIP FIFO.
  if channels.len == 0 or channels.len > 12: return

  # Configure scan positive channels into ScanPos1/ScanPos2
  var pos1 = 0'u32
  var pos2 = 0'u32
  for i in 0 ..< min(channels.len, 6):
    pos1 = pos1 or (channels[i].uint32 shl (i * 5))
  for i in 6 ..< min(channels.len, 12):
    pos2 = pos2 or (channels[i].uint32 shl ((i - 6) * 5))
  regWrite(AdcScanPos1, pos1)
  regWrite(AdcScanPos2, pos2)

  # Set scan length and enable scan mode in CONFIG1
  regModify(AdcCfg1, AdcScanLenMask,
            ((channels.len - 1).uint32 and 0x0F) shl AdcScanLenShift)
  regSet(AdcCfg1, (1'u32 shl AdcScanEn) or (1'u32 shl AdcContConvEn))

  # Clear GPIP FIFO and start
  regSet(GpipGpadcConfig, 1'u32 shl GpipFifoClr)
  regSet(AdcCmd, (1'u32 shl AdcGlobalEn) or (1'u32 shl AdcConvStart))

proc stopScan*(adc: Adc) =
  regClear(AdcCmd, (1'u32 shl AdcGlobalEn) or (1'u32 shl AdcConvStart))
  regClear(AdcCfg1, 1'u32 shl AdcScanEn)

proc readFifo*(adc: Adc): (uint32, bool) =
  ## Read one entry from the GPIP ADC FIFO.
  ## Returns (26-bit value, valid).
  let cfg = regRead(GpipGpadcConfig)
  if (cfg and (1'u32 shl GpipFifoNe)) == 0:
    return (0'u32, false)
  let data = regRead(GpipGpadcDmaRdata) and AdcResultDataMask
  (data, true)

proc fifoCount*(adc: Adc): uint32 =
  (regRead(GpipGpadcConfig) and GpipDataCountMask) shr GpipDataCountShift

# =============================================================================
# Temperature sensor
# =============================================================================
const AdcChTsen* = 14  # Temperature sensor channel

proc readTemperatureRaw*(adc: Adc): (uint16, AdcError) =
  ## Read the internal temperature sensor (raw ADC value).
  ## To convert: T(°C) ≈ (raw - offset) * scale (chip-specific calibration).
  adc.readChannel(AdcChTsen)

# =============================================================================
# VBAT reading
# =============================================================================
const AdcChVbat* = 15  # VBAT/2 channel

proc readVbatRaw*(adc: Adc): (uint16, AdcError) =
  ## Read VBAT/2 via ADC. Multiply result by 2 for actual VBAT.
  adc.readChannel(AdcChVbat)

# =============================================================================
# DMA support
# =============================================================================
proc enableDma*(adc: Adc) =
  ## Enable DMA for ADC FIFO reads via GPIP.
  regSet(GpipGpadcConfig, 1'u32 shl GpipDmaEn)

proc disableDma*(adc: Adc) =
  regClear(GpipGpadcConfig, 1'u32 shl GpipDmaEn)

proc fifoDataAddr*(): uint {.inline.} =
  ## Return GPIP FIFO data register address for DMA configuration.
  GpipGpadcDmaRdata

# =============================================================================
# DAC (Digital-to-Analog Converter)
# =============================================================================
# The BL808 DAC is controlled via GPIP registers (0x20002000+0x40)
# and GLB analog registers (0x20000000+0x120).

const
  DacConfig*       = GpipBase + 0x40'u   # DAC config (enable, mode, ch select)
  DacDmaConfig*    = GpipBase + 0x44'u   # DAC DMA config
  DacDmaWdata*     = GpipBase + 0x48'u   # DAC DMA write data
  DacTxFifoSts*    = GpipBase + 0x4C'u   # DAC TX FIFO status

  # GLB DAC analog control
  GlbDacCtrl*      = GlbBase + 0x120'u   # DAC analog control
  GlbDacActrl*     = GlbBase + 0x124'u   # DAC channel A analog
  GlbDacBctrl*     = GlbBase + 0x128'u   # DAC channel B analog
  GlbDacData*      = GlbBase + 0x12C'u   # DAC data (direct write)

const
  DacEn*           = 0    # DAC enable in DacConfig
  DacChASelShift*  = 16   # Channel A select [19:16]
  DacChBSelShift*  = 20   # Channel B select [23:20]
  DacDmaTxEn*      = 0    # DMA TX enable in DacDmaConfig

type
  DacChannel* = enum
    dacA = 0
    dacB = 1

proc dacEnable*(ch: DacChannel) =
  ## Enable a DAC channel.
  regSet(DacConfig, 1'u32 shl DacEn)
  # Enable analog output
  case ch
  of dacA:
    regSet(GlbDacActrl, 1'u32)        # GPDAC_A_EN
    regSet(GlbDacActrl, 1'u32 shl 1)  # GPDAC_IOA_EN
  of dacB:
    regSet(GlbDacBctrl, 1'u32)
    regSet(GlbDacBctrl, 1'u32 shl 1)

proc dacDisable*(ch: DacChannel) =
  case ch
  of dacA: regClear(GlbDacActrl, 0x03'u32)
  of dacB: regClear(GlbDacBctrl, 0x03'u32)

proc dacWrite*(value: uint32) =
  ## Write to the DAC data register (direct output).
  regWrite(GlbDacData, value)

proc dacWriteDma*(value: uint32) =
  ## Write to DAC via DMA FIFO.
  regWrite(DacDmaWdata, value)

proc dacEnableDma*() =
  regSet(DacDmaConfig, 1'u32 shl DacDmaTxEn)
