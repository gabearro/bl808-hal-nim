## BL808 Global (GLB) control: clock tree, PLL, clock gating, resets.
##
## The GLB block at 0x20000000 controls system clocks, peripheral resets,
## and clock gating for the MCU subsystem.
## The MM_GLB block at 0x30007000 controls clocks for the MM (D0) subsystem.

import core, mmio, memmap, pds

# =============================================================================
# GLB register offsets (MCU subsystem, base 0x20000000)
# =============================================================================
const
  # System info / clock configuration (verified against BL808 glb_reg.h)
  GlbSocInfo0*      = GlbBase + 0x000'u  # SoC info register 0
  GlbSocInfo1*      = GlbBase + 0x004'u  # SoC info register 1
  GlbSysCfg0*       = GlbBase + 0x090'u  # System config 0 (HBN root clk, HCLK/BCLK div)
  GlbSysCfg1*       = GlbBase + 0x094'u  # System config 1 (divider update)
  GlbMcuCfg0*       = GlbBase + 0x090'u  # Alias for SysCfg0

  # WIFIPLL (verified: offsets 0x810-0x844 from BL808 glb_reg.h)
  GlbWifiPllCfg0*   = GlbBase + 0x810'u  # PLL reset/power control
  GlbWifiPllCfg1*   = GlbBase + 0x814'u  # Post-div, ref-div, ref-clk select
  GlbWifiPllCfg2*   = GlbBase + 0x818'u  # Charge pump config
  GlbWifiPllCfg3*   = GlbBase + 0x81C'u  # Loop filter
  GlbWifiPllCfg4*   = GlbBase + 0x820'u  # Clock select
  GlbWifiPllCfg5*   = GlbBase + 0x824'u  # VCO speed, divider enables
  GlbWifiPllCfg6*   = GlbBase + 0x828'u  # SDM fractional config
  GlbWifiPllCfg7*   = GlbBase + 0x82C'u  # SDM noise/dither
  GlbWifiPllCfg8*   = GlbBase + 0x830'u  # Output divider enables
  GlbWifiPllCfg9*   = GlbBase + 0x834'u  # Test/debug
  GlbWifiPllCfg10*  = GlbBase + 0x838'u  # USBPLL SDM config
  GlbWifiPllCfg11*  = GlbBase + 0x83C'u  # USBPLL SSC config
  GlbWifiPllCfg12*  = GlbBase + 0x840'u  # SSCDIV SDM config
  GlbWifiPllCfg13*  = GlbBase + 0x844'u  # SSCDIV SSC config

  # AUPLL accessed via CCI at 0x20008000 + 0x750
  GlbAuPllCfg0*     = CciBase + 0x750'u  # Audio PLL reset/power
  GlbAuPllCfg1*     = CciBase + 0x754'u  # Audio PLL post-div, ref-div
  GlbAuPllCfg5*     = CciBase + 0x764'u  # Audio PLL VCO speed
  GlbAuPllCfg6*     = CciBase + 0x768'u  # Audio PLL SDM fractional
  GlbAuPllCfg8*     = CciBase + 0x770'u  # Audio PLL output dividers

  # Peripheral clock configuration (verified against BL808 glb_reg.h)
  GlbAdcCfg0*       = GlbBase + 0x110'u  # ADC clock (was 0x0F4 - wrong)
  GlbDacCfg0*       = GlbBase + 0x120'u  # DAC analog control (was 0x0F8 - wrong)
  GlbDmaCfg0*       = GlbBase + 0x130'u  # DMA clock
  GlbIrCfg0*        = GlbBase + 0x140'u  # IR clock (was 0x1C0 - wrong)
  GlbUartCfg0*      = GlbBase + 0x150'u  # UART clock
  GlbUartSigSwap*   = GlbBase + 0x154'u  # UART signal swap
  GlbSfCfg0*        = GlbBase + 0x170'u  # Serial flash clock (was 0x160 - wrong)
  GlbI2cCfg0*       = GlbBase + 0x180'u  # I2C clock
  GlbI2sCfg0*       = GlbBase + 0x190'u  # I2S clock (was 0x1A0 - wrong)
  GlbSpiCfg0*       = GlbBase + 0x1B0'u  # SPI clock
  GlbPwmCfg0*       = GlbBase + 0x1D0'u  # PWM clock
  GlbEmiCfg0*       = GlbBase + 0x0E0'u  # EMI/PSRAM clock
  GlbRtcCfg0*       = GlbBase + 0x0F0'u  # RTC clock
  GlbDigClkCfg0*    = GlbBase + 0x250'u  # Digital clock config 0 (was 0x100 - wrong)
  GlbDigClkCfg1*    = GlbBase + 0x254'u  # Digital clock config 1
  GlbDigClkCfg2*    = GlbBase + 0x258'u  # Digital clock config 2

  # Software reset
  GlbSwrstCfg0*     = GlbBase + 0x540'u
  GlbSwrstCfg1*     = GlbBase + 0x544'u
  GlbSwrstCfg2*     = GlbBase + 0x548'u
  GlbSwrstCfg3*     = GlbBase + 0x54C'u

  # Clock gate
  GlbCgenCfg0*      = GlbBase + 0x580'u
  GlbCgenCfg1*      = GlbBase + 0x584'u
  GlbCgenCfg2*      = GlbBase + 0x588'u
  GlbCgenCfg3*      = GlbBase + 0x58C'u

  # HBN clock mux control
  HbnGlb*            = HbnBase + 0x030'u

# =============================================================================
# MM_GLB register offsets (D0 subsystem, base 0x30007000)
# =============================================================================
const
  MmClkCtrlCpu*     = MmGlbBase + 0x00'u
  MmClkCpu*         = MmGlbBase + 0x04'u
  MmDpClk*          = MmGlbBase + 0x08'u
  MmCodecClk*       = MmGlbBase + 0x0C'u
  MmClkCtrlPeri*    = MmGlbBase + 0x10'u
  MmClkCtrlPeri3*   = MmGlbBase + 0x18'u
  MmSwSysReset*     = MmGlbBase + 0x40'u
  MmSwResetPeri*    = MmGlbBase + 0x44'u
  MmSwResetSub*     = MmGlbBase + 0x48'u
  MmSwResetCodec*   = MmGlbBase + 0x4C'u

  # MM peripheral clock control fields
  MmI2c2ClkDivShift*    = 0
  MmI2c2ClkDivMask*     = 0xFF'u32 shl MmI2c2ClkDivShift
  MmI2c2ClkDivEn*       = 8
  MmI2c2ClkEn*          = 9
  MmUart3ClkDivEn*      = 16
  MmUart3ClkDivShift*   = 17
  MmUart3ClkDivMask*    = 0x07'u32 shl MmUart3ClkDivShift
  MmSpi1ClkDivEn*       = 23
  MmSpi1ClkDivShift*    = 24
  MmSpi1ClkDivMask*     = 0xFF'u32 shl MmSpi1ClkDivShift

  MmI2c3ClkDivShift*    = 0
  MmI2c3ClkDivMask*     = 0xFF'u32 shl MmI2c3ClkDivShift
  MmI2c3ClkDivEn*       = 8
  MmI2c3ClkEn*          = 9

  # MM peripheral reset bits
  MmResetDma2*          = 1
  MmResetUart3*         = 2
  MmResetI2c2*          = 3
  MmResetI2c3*          = 4
  MmResetSpi1*          = 8
  MmResetTimer1*        = 9

# =============================================================================
# Clock source enumeration
# =============================================================================
type
  McuSysClk* = enum
    clkRc32m         ## Internal 32 MHz RC oscillator (boot default)
    clkXtal          ## External crystal (24/32/38.4/40 MHz)
    clkCpuPll400m    ## CPU PLL at 400 MHz
    clkWifiPll240m   ## WiFi PLL at 240 MHz
    clkWifiPll320m   ## WiFi PLL at 320 MHz

  DspSysClk* = enum
    dspClkRc32m
    dspClkXtal
    dspClkWifiPll240m
    dspClkWifiPll320m
    dspClkCpuPll400m

  McuXclkSrc* = enum
    mcuXclkRc32m
    mcuXclkXtal

  UartClkSrc* = enum
    uartClkBclk      ## Bus clock
    uartClkPll160m   ## PLL 160 MHz
    uartClkXclk      ## Crystal clock

  SpiClkSrc* = enum
    spiClkBclk       ## Bus clock
    spiClkPll160m    ## PLL 160 MHz
    spiClkXclk       ## Crystal clock

# =============================================================================
# Peripheral index for clock gating and reset (CGEN_CFG1 bit positions)
# =============================================================================
type
  McuPeriph* = enum
    ## CGEN_CFG1 bit positions for MCU peripheral clock gates (from BL808 glb_reg.h)
    periphUart0   = 16
    periphUart1   = 17
    periphSpi     = 18
    periphI2c0    = 19
    periphPwm     = 20
    periphTimer   = 21
    periphIr      = 22
    periphCks     = 23
    # periphRsvd8 = 24  # Reserved; DMA clock is in DMA_CFG0.
    periphI2c1    = 25
    periphUart2   = 26

# =============================================================================
# Clock gating
# =============================================================================
proc enablePeriphClock*(periph: McuPeriph) =
  ## Enable the clock gate for a peripheral.
  regSet(GlbCgenCfg1, 1'u32 shl periph.uint32)

proc disablePeriphClock*(periph: McuPeriph) =
  ## Disable the clock gate for a peripheral.
  regClear(GlbCgenCfg1, 1'u32 shl periph.uint32)

# =============================================================================
# Peripheral software reset
# =============================================================================
proc resetPeriph*(periph: McuPeriph) =
  ## Assert then deassert software reset for a peripheral.
  # SWRST_CFG1 uses same bit positions as CGEN_CFG1
  regSet(GlbSwrstCfg1, 1'u32 shl periph.uint32)
  # Short delay for reset to take effect
  for i in 0 ..< 10:
    discard regRead(GlbSwrstCfg1)
  regClear(GlbSwrstCfg1, 1'u32 shl periph.uint32)

# =============================================================================
# UART clock configuration
# =============================================================================
const
  GlbUartClkDivMask = 0x07'u32
  GlbUartClkEnBit = 4
  HbnMcuXclkSelMask = 1'u32 shl 0
  HbnUartClkSelMask = 1'u32 shl 2
  HbnUartClkSel2Mask = 1'u32 shl 15

proc setMcuXclkSource*(src: McuXclkSrc) =
  ## Select MCU XCLK source: RC32M or crystal.
  regModify(HbnGlb, HbnMcuXclkSelMask, src.uint32)

proc setUartClockDiv*(divider: uint32) =
  ## Set UART clock divider (0 = divide by 1).
  regModify(GlbUartCfg0, GlbUartClkDivMask, divider and GlbUartClkDivMask)

proc enableUartClock*() =
  ## Enable UART clock.
  regSet(GlbUartCfg0, 1'u32 shl GlbUartClkEnBit)

proc disableUartClock*() =
  ## Disable UART clock.
  regClear(GlbUartCfg0, 1'u32 shl GlbUartClkEnBit)

proc setUartClockSource*(src: UartClkSrc) =
  ## Select UART0/1/2 clock source through the HBN mux.
  var hbn = regRead(HbnGlb)
  hbn = hbn and not (HbnUartClkSelMask or HbnUartClkSel2Mask)
  case src
  of uartClkBclk:
    discard
  of uartClkPll160m:
    hbn = hbn or HbnUartClkSelMask
  of uartClkXclk:
    hbn = hbn or HbnUartClkSel2Mask
  regWrite(HbnGlb, hbn)

proc setUartClock*(enable: bool, src: UartClkSrc, divider: uint32 = 0) =
  ## Configure UART0/1/2 clock source, divider, and enable bit.
  disableUartClock()
  setUartClockDiv(divider)
  setUartClockSource(src)
  if enable:
    enableUartClock()

# =============================================================================
# SPI clock configuration
# =============================================================================
proc setSpiClockDiv*(divider: uint32) =
  ## Set SPI clock divider.
  regModify(GlbSpiCfg0, 0x1F'u32 shl 0, divider and 0x1F)

proc enableSpiClock*() =
  regSet(GlbSpiCfg0, 1'u32 shl 8)

proc setSpiClockSource*(src: SpiClkSrc) =
  regModify(GlbSpiCfg0, 0x01'u32 shl 9, src.uint32 shl 9)

# =============================================================================
# I2C clock configuration
# =============================================================================
proc setI2cClockDiv*(divider: uint32) =
  ## Set I2C clock divider.
  regModify(GlbI2cCfg0, 0xFF'u32 shl 16, (divider and 0xFF) shl 16)

proc enableI2cClock*() =
  regSet(GlbI2cCfg0, 1'u32 shl 24)

# =============================================================================
# DMA clock configuration
# =============================================================================
proc enableDma0Clock*() =
  regSet(GlbDmaCfg0, 1'u32 shl 24)

proc enableDma1Clock*() =
  regSet(GlbDmaCfg0, 1'u32 shl 25)

# =============================================================================
# MCU system clock configuration
# =============================================================================
const
  HbnRootClkSelShift = 6
  HbnRootClkSelMask  = 0x03'u32 shl HbnRootClkSelShift
  HclkDivShift       = 8
  HclkDivMask        = 0xFF'u32 shl HclkDivShift
  BclkDivShift       = 16
  BclkDivMask        = 0xFF'u32 shl BclkDivShift

proc setMcuSysClock*(src: McuSysClk, hclkDiv: uint32 = 0, bclkDiv: uint32 = 0) =
  ## Configure MCU system clock source and dividers.
  ##
  ## `hclkDiv`: HCLK divider (0 = /1, 1 = /2, etc.)
  ## `bclkDiv`: BCLK divider from HCLK (0 = /1, 1 = /2, etc.)
  var rootSel: uint32
  var pllSel: uint32 = 0

  case src
  of clkRc32m:
    rootSel = 0  # RC32M
  of clkXtal:
    rootSel = 1  # XTAL
  of clkCpuPll400m:
    rootSel = 2  # PLL
    pllSel = 3
  of clkWifiPll240m:
    rootSel = 2
    pllSel = 2
  of clkWifiPll320m:
    rootSel = 2
    pllSel = 1

  # Set HCLK and BCLK dividers first
  var cfg = regRead(GlbMcuCfg0)
  cfg = (cfg and not HclkDivMask) or ((hclkDiv and 0xFF) shl HclkDivShift)
  cfg = (cfg and not BclkDivMask) or ((bclkDiv and 0xFF) shl BclkDivShift)
  regWrite(GlbMcuCfg0, cfg)

  # Trigger divider update
  regSet(GlbSysCfg1, 1'u32 shl 0)
  discard regWaitClear(GlbSysCfg1, 1'u32 shl 0)

  # Switch clock source
  regModify(GlbMcuCfg0, HbnRootClkSelMask, rootSel shl HbnRootClkSelShift)

# =============================================================================
# MM (D0) system clock configuration
# =============================================================================
proc setDspXclkSel*(sel: uint32) =
  ## Select DSP XCLK source: 0=RC32M, 1=XTAL
  regModify(MmClkCtrlCpu, 1'u32 shl 10, (sel and 1) shl 10)

proc setDspRootClkSel*(sel: uint32) =
  ## Select DSP root clock: 0=XCLK, 1=PLL
  regModify(MmClkCtrlCpu, 1'u32 shl 11, (sel and 1) shl 11)

proc setDspPllClkSel*(sel: uint32) =
  ## Select DSP PLL mux: 0=240M, 1=320M, 2=CPUPLL_400M
  regModify(MmClkCtrlCpu, 0x03'u32 shl 8, (sel and 3) shl 8)

proc setDspSysClkDiv*(cpuDiv, bclk2xDiv: uint32) =
  ## Set DSP system clock dividers with handshake.
  # Save and switch to RC32M
  let prevXclk = (regRead(MmClkCtrlCpu) shr 10) and 1
  let prevRoot = (regRead(MmClkCtrlCpu) shr 11) and 1
  if prevXclk != 0 or prevRoot != 0:
    setDspXclkSel(0)  # RC32M
    setDspRootClkSel(0)  # XCLK
  # Set dividers
  var clkCpu = regRead(MmClkCpu)
  clkCpu = (clkCpu and not 0xFF'u32) or (cpuDiv and 0xFF)
  clkCpu = (clkCpu and not (0xFF'u32 shl 8)) or ((bclk2xDiv and 0xFF) shl 8)
  regWrite(MmClkCpu, clkCpu)
  # Pulse act and wait for done
  regSet(MmClkCtrlCpu, 1'u32 shl 18)
  var timeout = 1024'u32
  while timeout > 0:
    if (regRead(MmClkCtrlCpu) and (1'u32 shl 20)) != 0: break
    timeout.dec
  # Restore
  setDspXclkSel(prevXclk)
  setDspRootClkSel(prevRoot)

proc setDspSysClock*(src: DspSysClk) =
  ## Configure D0 subsystem clock source using proper sequence.
  let prevXclk = (regRead(MmClkCtrlCpu) shr 10) and 1
  # Step 1: Switch to RC32M as safe intermediate
  setDspXclkSel(0)
  setDspRootClkSel(0)
  setDspSysClkDiv(0, 0)
  # Step 2: Configure
  case src
  of dspClkRc32m:
    setDspSysClkDiv(0, 0)
    setDspXclkSel(0)
    setDspRootClkSel(0)
  of dspClkXtal:
    setDspSysClkDiv(0, 0)
    setDspXclkSel(1)
    setDspRootClkSel(0)
  of dspClkWifiPll240m:
    setDspSysClkDiv(0, 1)
    setDspPllClkSel(0)  # 240M
    setDspRootClkSel(1)  # PLL
    setDspXclkSel(prevXclk)
  of dspClkWifiPll320m:
    setDspSysClkDiv(0, 1)
    setDspPllClkSel(1)  # 320M
    setDspRootClkSel(1)
    setDspXclkSel(prevXclk)
  of dspClkCpuPll400m:
    setDspSysClkDiv(0, 1)
    setDspPllClkSel(2)  # CPUPLL_400M
    setDspRootClkSel(1)
    setDspXclkSel(prevXclk)
  # Dummy wait for clock stabilization
  for i in 0..7: discard regRead(MmClkCtrlCpu)

proc setMmUart3Clock*(enable: bool, divider: uint32 = 0) =
  ## Configure MM UART3 clock divider/enable in MM_CLK_CTRL_PERI.
  var reg = regRead(MmClkCtrlPeri)
  reg = reg and not (1'u32 shl MmUart3ClkDivEn)
  reg = (reg and not MmUart3ClkDivMask) or ((divider and 0x07'u32) shl MmUart3ClkDivShift)
  if enable:
    reg = reg or (1'u32 shl MmUart3ClkDivEn)
  regWrite(MmClkCtrlPeri, reg)

proc enableMmUart3Clock*() =
  setMmUart3Clock(true)

proc setMmSpi1Clock*(enable: bool, divider: uint32 = 0) =
  ## Configure MM SPI1 clock divider/enable in MM_CLK_CTRL_PERI.
  var reg = regRead(MmClkCtrlPeri)
  reg = reg and not (1'u32 shl MmSpi1ClkDivEn)
  reg = (reg and not MmSpi1ClkDivMask) or ((divider and 0xFF'u32) shl MmSpi1ClkDivShift)
  if enable:
    reg = reg or (1'u32 shl MmSpi1ClkDivEn)
  regWrite(MmClkCtrlPeri, reg)

proc enableMmSpi1Clock*() =
  setMmSpi1Clock(true)

proc setMmI2c2Clock*(enable: bool, dividerEnabled: bool = true, divider: uint32 = 0) =
  ## Configure MM I2C2 clock divider/enable in MM_CLK_CTRL_PERI.
  var reg = regRead(MmClkCtrlPeri)
  reg = (reg and not MmI2c2ClkDivMask) or ((divider and 0xFF'u32) shl MmI2c2ClkDivShift)
  if dividerEnabled:
    reg = reg or (1'u32 shl MmI2c2ClkDivEn)
  else:
    reg = reg and not (1'u32 shl MmI2c2ClkDivEn)
  if enable:
    reg = reg or (1'u32 shl MmI2c2ClkEn)
  else:
    reg = reg and not (1'u32 shl MmI2c2ClkEn)
  regWrite(MmClkCtrlPeri, reg)

proc enableMmI2c2Clock*() =
  setMmI2c2Clock(true)

proc setMmI2c3Clock*(enable: bool, dividerEnabled: bool = true, divider: uint32 = 0) =
  ## Configure MM I2C3 clock divider/enable in MM_CLK_CTRL_PERI3.
  var reg = regRead(MmClkCtrlPeri3)
  reg = (reg and not MmI2c3ClkDivMask) or ((divider and 0xFF'u32) shl MmI2c3ClkDivShift)
  if dividerEnabled:
    reg = reg or (1'u32 shl MmI2c3ClkDivEn)
  else:
    reg = reg and not (1'u32 shl MmI2c3ClkDivEn)
  if enable:
    reg = reg or (1'u32 shl MmI2c3ClkEn)
  else:
    reg = reg and not (1'u32 shl MmI2c3ClkEn)
  regWrite(MmClkCtrlPeri3, reg)

proc enableMmI2c3Clock*() =
  setMmI2c3Clock(true)

proc enableMmPeriphClock*(bit: uint32) =
  ## Raw MM_CLK_CTRL_PERI bit helper. Prefer dedicated MM helpers above.
  regSet(MmClkCtrlPeri, 1'u32 shl bit)

proc resetMmPeriph*(bit: uint32) =
  ## Reset an MM subsystem peripheral.
  regSet(MmSwResetPeri, 1'u32 shl bit)
  for i in 0 ..< 10:
    discard regRead(MmSwResetPeri)
  regClear(MmSwResetPeri, 1'u32 shl bit)

proc resetMmDma2*() = resetMmPeriph(MmResetDma2)
proc resetMmUart3*() = resetMmPeriph(MmResetUart3)
proc resetMmI2c2*() = resetMmPeriph(MmResetI2c2)
proc resetMmI2c3*() = resetMmPeriph(MmResetI2c3)
proc resetMmSpi1*() = resetMmPeriph(MmResetSpi1)
proc resetMmTimer1*() = resetMmPeriph(MmResetTimer1)

# =============================================================================
# System clock readback helpers
# =============================================================================
proc getHclkDiv*(): uint32 =
  fieldVal(regRead(GlbMcuCfg0), HclkDivShift, 8)

proc getBclkDiv*(): uint32 =
  fieldVal(regRead(GlbMcuCfg0), BclkDivShift, 8)

# =============================================================================
# Additional GLB registers
# =============================================================================
const
  # XTAL configuration
  GlbXtalCfg*      = GlbBase + 0x510'u  # PARM_CFG0 in SDK

  # CGEN_CFG2 bit assignments (verified from BL808 glb_reg.h)
  # Note: CGEN_CFG2 is for system-level clock gates, NOT peripheral gates
  CgenCfg2S0*      = 0   # S0
  CgenCfg2Wifi*    = 4   # WiFi
  CgenCfg2BtBle2*  = 10  # BT/BLE 2
  CgenCfg2M1542*   = 11  # IEEE 802.15.4
  CgenCfg2EmiMisc* = 16  # EMI misc
  CgenCfg2Psram0*  = 17  # PSRAM 0
  CgenCfg2Psram1*  = 18  # PSRAM 1
  CgenCfg2Usb*     = 19  # USB
  CgenCfg2Mix2*    = 20  # MIX2
  CgenCfg2Audio*   = 21  # Audio
  CgenCfg2Sdh*     = 22  # SDH
  CgenCfg2Emac*    = 23  # EMAC

# =============================================================================
# XTAL type (Ox64 uses 40 MHz)
# =============================================================================
type
  XtalType* = enum
    xtalNone = 0
    xtal24m = 1
    xtal32m = 2
    xtal384m = 3
    xtal40m = 4
    xtal26m = 5
    xtalRc32m = 6

# =============================================================================
# PLL configuration
# =============================================================================
# WIFIPLL provides: 80M, 120M, 160M, 240M, 320M outputs
# CPUPLL provides: 100M, 200M, 400M, 600M outputs
# AUPLL provides: various audio clocks

const
  # WIFIPLL_CFG0 fields (from bouffalo_sdk glb_reg.h)
  WifiPllSdmRstN*      = 0    # SDM reset (active low)
  WifiPllPostdivRstb*  = 1    # Post divider reset
  WifiPllFbdvRstb*     = 2    # Feedback divider reset
  WifiPllRefdivRstb*   = 3    # Reference divider reset
  WifiPllPuPostdiv*    = 4    # Post divider power up
  WifiPllPuFbdv*       = 5    # Feedback divider power up
  WifiPllPuClampOp*    = 6    # Clamp OP power up
  WifiPllPuPfd*        = 7    # Phase frequency detector power up
  WifiPllPuCp*         = 8    # Charge pump power up
  WifiPllPuSfreg*      = 9    # Regulator power up
  WifiPllPuPll*        = 10   # Master PLL power up
  WifiPllPuClktree*    = 11   # Clock tree power up

  # WIFIPLL_CFG1 fields
  WifiPllPostdivShift*     = 0
  WifiPllPostdivMask*      = 0x7F'u32
  WifiPllRefdivRatioShift* = 8
  WifiPllRefdivRatioMask*  = 0x0F'u32 shl 8
  WifiPllRefclkSelShift*   = 16
  WifiPllRefclkSelMask*    = 0x03'u32 shl 16

  # WIFIPLL_CFG8 output divider enables (verified from BL808 glb_reg.h)
  WifiPllEnDiv2*   = 0    # 480 MHz
  WifiPllEnDiv4*   = 1    # 240 MHz
  WifiPllEnDiv5*   = 2    # 192 MHz
  WifiPllEnDiv6*   = 3    # 160 MHz
  WifiPllEnDiv8*   = 4    # 120 MHz
  WifiPllEnDiv10*  = 5    # 96 MHz
  WifiPllEnDiv12*  = 6    # 80 MHz
  WifiPllEnDiv20*  = 7    # 48 MHz
  WifiPllEnDiv30*  = 8    # 32 MHz

proc wifiPllEnable*() =
  ## Power up WIFIPLL following the SDK init sequence.
  # Step 1: Power up regulator
  regSet(GlbWifiPllCfg0, 1'u32 shl WifiPllPuSfreg)
  for i in 0 ..< 2000: discard regRead(GlbWifiPllCfg0)

  # Step 2: Power up PLL and all sub-blocks
  let puBits = (1'u32 shl WifiPllPuPll) or (1'u32 shl WifiPllPuClktree) or
               (1'u32 shl WifiPllPuPostdiv) or (1'u32 shl WifiPllPuFbdv) or
               (1'u32 shl WifiPllPuClampOp) or (1'u32 shl WifiPllPuPfd) or
               (1'u32 shl WifiPllPuCp)
  regSet(GlbWifiPllCfg0, puBits)
  for i in 0 ..< 5000: discard regRead(GlbWifiPllCfg0)

  # Step 3: Release resets
  let rstBits = (1'u32 shl WifiPllSdmRstN) or (1'u32 shl WifiPllFbdvRstb) or
                (1'u32 shl WifiPllRefdivRstb) or (1'u32 shl WifiPllPostdivRstb)
  regSet(GlbWifiPllCfg0, rstBits)

  # Step 4: Enable default output dividers
  regSet(GlbWifiPllCfg8, (1'u32 shl WifiPllEnDiv4) or   # 240M
                          (1'u32 shl WifiPllEnDiv6) or   # 160M
                          (1'u32 shl WifiPllEnDiv8) or   # 120M
                          (1'u32 shl WifiPllEnDiv12))    # 80M

proc wifiPllDisable*() =
  regWrite(GlbWifiPllCfg0, 0)  # Power down everything

proc wifiPllEnableOutput*(divBit: uint32) =
  ## Enable a specific WIFIPLL output divider.
  regSet(GlbWifiPllCfg8, 1'u32 shl divBit)

proc wifiPllDisableOutput*(divBit: uint32) =
  regClear(GlbWifiPllCfg8, 1'u32 shl divBit)

proc auPllEnable*() =
  ## Power up AUPLL (audio PLL) via CCI registers.
  regSet(GlbAuPllCfg0, (1'u32 shl 9) or (1'u32 shl 10))  # PU_SFREG, PU_AUPLL
  for i in 0 ..< 5000: discard regRead(GlbAuPllCfg0)
  regSet(GlbAuPllCfg0, 0x0F'u32)  # Release all resets

proc auPllDisable*() =
  regWrite(GlbAuPllCfg0, 0)

# =============================================================================
# PWM clock configuration
# =============================================================================
# NOTE: GlbPwmCfg0 (0x1D0) only contains IO select bits, not clock config.
# PWM clock is gated via CGEN_CFG1 (periphPwm) and uses the bus clock directly.
# The setPwmClockDiv, setPwmClockSource, and enablePwmClock functions that were
# here previously targeted wrong bits and have been removed.

# =============================================================================
# IR clock configuration
# =============================================================================
proc setIrClockDiv*(divider: uint32) =
  regModify(GlbIrCfg0, 0x3F'u32 shl 16, (divider and 0x3F) shl 16)

proc enableIrClock*() =
  regSet(GlbIrCfg0, 1'u32 shl 23)

# =============================================================================
# I2S clock configuration
# =============================================================================
proc setI2sClockDiv*(divider: uint32) =
  regModify(GlbI2sCfg0, 0x3F'u32 shl 0, divider and 0x3F)

proc enableI2sClock*() =
  regSet(GlbI2sCfg0, 1'u32 shl 7)

# =============================================================================
# ADC clock configuration
# =============================================================================
type
  AdcClkSrc* = enum
    adcClkAuPll = 0
    adcClkXtal = 1

proc setAdcClockDiv*(divider: uint32) =
  regModify(GlbAdcCfg0, 0x3F'u32 shl 0, divider and 0x3F)

proc setAdcClockSource*(src: AdcClkSrc) =
  regModify(GlbAdcCfg0, 1'u32 shl 7, src.uint32 shl 7)

proc enableAdcClock*() =
  regSet(GlbAdcCfg0, 1'u32 shl 8)

# =============================================================================
# DAC clock configuration
# =============================================================================
# NOTE: GlbDacCfg0 (0x120) is DAC analog control. It has no clock divider field;
# bit 8 is GPDAC_REF_SEL, not a clock enable. The setDacClockDiv and enableDacClock
# functions that were here previously targeted wrong bits and have been removed.

# =============================================================================
# MM subsystem power-on and D0/LP core release
# =============================================================================
const
  PdsCtl2Addr     = PdsBase + 0x10'u   # MM power domain force bits
  MmCpu0BootAddr  = MmMiscBase + 0x00'u # D0 boot address register
  MmCpu0ClkEn     = 1'u32 shl 12      # D0 CPU clock enable in MM_CLK_CTRL_CPU
  MmCpu0Reset     = 1'u32 shl 8       # D0 CPU reset in MM_SW_SYS_RESET
  GlbSwrstCfg2Addr = GlbBase + 0x548'u # MCU GLB SWRST_CFG2
  PicoCpuReset    = 1'u32 shl 3       # LP CPU reset in GLB_SWRST_CFG2
  PicoClkEn       = 1'u32 shl 28      # LP clock enable in PDS_CPU_CORE_CFG0
  PdsCpuCoreCfg0Addr = PdsBase + 0x110'u
  PdsCpuCoreCfg13Addr = PdsBase + 0x144'u # LP boot address register
  SfCtrlImageOffset0 = SfCtrlBase + 0x0A0'u # Physical flash offset mapped at FlashXipBase
  SfCtrlImageOffsetMask = 0x0FFF_FFFF'u32
  D0EntryFirstInsn = 0x3004_7073'u32   # csrci mstatus,8 from D0 startup
  D0FlashCopyBytes* = 128'u * 1024'u
  JtagD0ImageMagic* = 0x4430_4A54'u32   # "D0JT"
  JtagD0ImageMagicAddr* = XramBase + 0x00'u
  JtagD0ImageSizeAddr* = XramBase + 0x04'u
  JtagD0ImageDataAddr* = XramBase + 0x100'u
  JtagD0ImageMaxBytes* = 0x3D00'u       # Leave the high XRAM status area free.
  JtagLPEntryAddr* = WramBase + 0x0002_0000'u

proc mmPowerOn*() =
  ## Power on the MM (multimedia) subsystem by clearing PDS_CTL2 force bits.
  ## Must be called before releasing D0 or accessing MM peripherals.
  regWrite(PdsCtl2Addr, 0'u32)

proc d0ImageLoaded*(): bool =
  ## True when DRAM already contains the D0 RAM image entry point.
  regRead(DramBase) == D0EntryFirstInsn

proc d0FlashMappedAddr*(flashOffset: uint = Ox64D0BootOffset): uint =
  ## Return the XIP address that maps a physical flash offset.
  let mappedOffset = (regRead(SfCtrlImageOffset0) and SfCtrlImageOffsetMask).uint
  if flashOffset >= mappedOffset:
    FlashXipBase + flashOffset - mappedOffset
  else:
    FlashXipBase + flashOffset

proc d0FlashImageAvailable*(flashOffset: uint = Ox64D0BootOffset): bool =
  ## True when the D0 flash slot appears to contain a DRAM-linked image.
  regRead(d0FlashMappedAddr(flashOffset)) == D0EntryFirstInsn

proc loadD0ImageFromFlash*(flashOffset: uint = Ox64D0BootOffset,
                           bytes: uint = D0FlashCopyBytes) =
  ## Copy the DRAM-linked D0 image from its Ox64 flash slot into MM DRAM.
  let srcBase = d0FlashMappedAddr(flashOffset)
  var offset = 0'u
  while offset < bytes:
    regWrite(DramBase + offset, regRead(srcBase + offset))
    offset += 4'u
  core.fence()

proc d0JtagImageAvailable*(): bool =
  ## True when the JTAG harness staged a D0 binary in shared XRAM.
  let bytes = regRead(JtagD0ImageSizeAddr).uint
  regRead(JtagD0ImageMagicAddr) == JtagD0ImageMagic and
    bytes > 0'u and bytes <= JtagD0ImageMaxBytes and
    regRead(JtagD0ImageDataAddr) == D0EntryFirstInsn

proc loadD0ImageFromJtagBuffer*() =
  ## Copy a D0 RAM image staged by the JTAG harness in XRAM into MM DRAM.
  let bytes = regRead(JtagD0ImageSizeAddr).uint
  var offset = 0'u
  while offset < bytes:
    regWrite(DramBase + offset, regRead(JtagD0ImageDataAddr + offset))
    offset += 4'u
  regWrite(JtagD0ImageMagicAddr, 0)
  core.fence()

proc releaseD0*(forceLoad: bool = true) =
  ## Release D0 (C906) from reset and enable its clock.
  ## Call mmPowerOn() first.
  regSet(MmSwSysReset, MmCpu0Reset)     # hold reset while loading/retargeting
  core.fenceIo()
  when defined(bl808jtagram):
    if d0JtagImageAvailable():
      loadD0ImageFromJtagBuffer()
    elif forceLoad:
      let flashReady = d0FlashImageAvailable()
      if flashReady:
        loadD0ImageFromFlash()
  else:
    let flashReady = d0FlashImageAvailable()
    if (forceLoad and flashReady) or ((not d0ImageLoaded()) and flashReady):
      loadD0ImageFromFlash()
  regWrite(MmCpu0BootAddr, DramBase.uint32)
  core.fenceIo()
  regSet(MmClkCtrlCpu, MmCpu0ClkEn)     # enable clock
  core.fenceIo()
  regClear(MmSwSysReset, MmCpu0Reset)   # deassert reset
  core.fenceIo()

proc releaseLP*() =
  ## Release LP (E902) from reset and enable its clock.
  regSet(GlbSwrstCfg2Addr, PicoCpuReset)    # hold reset while retargeting PC
  core.fenceIo()
  when defined(bl808jtagram):
    regWrite(PdsCpuCoreCfg13Addr, JtagLPEntryAddr.uint32)
  else:
    regWrite(PdsCpuCoreCfg13Addr, (FlashXipBase + Ox64LPBootOffset).uint32)
  core.fenceIo()
  pdsConfigureLpMtimerClock()
  core.fenceIo()
  regSet(PdsCpuCoreCfg0Addr, PicoClkEn)     # enable clock
  core.fenceIo()
  regClear(GlbSwrstCfg2Addr, PicoCpuReset)  # deassert reset
  core.fenceIo()

# =============================================================================
# System level clock gating (CGEN_CFG0, CGEN_CFG2)
# =============================================================================
proc enableSystemClock*(reg: uint, bit: uint32) =
  ## Enable a system-level clock gate bit. Use CgenCfg0/CgenCfg2 constants.
  regSet(reg, 1'u32 shl bit)

proc disableSystemClock*(reg: uint, bit: uint32) =
  regClear(reg, 1'u32 shl bit)

# =============================================================================
# Convenience: enable all peripheral clocks needed for a configuration
# =============================================================================
proc enableAllPeriphClocks*() =
  ## Enable clocks for all commonly used peripherals.
  ## Call this during system init if you want everything available.
  regWrite(GlbCgenCfg1, 0xFFFF_FFFF'u32)
  regWrite(GlbCgenCfg2, 0xFFFF_FFFF'u32)

# =============================================================================
# UART signal swap (for routing UARTs to different pin sets)
# =============================================================================
proc swapUartSignals*(swapBits: uint32) =
  ## Swap UART TX/RX signal routing. Each bit pair controls one UART.
  ## Bit 0-1: UART0, Bit 2-3: UART1, Bit 4-5: UART2
  regWrite(GlbUartSigSwap, swapBits)

# =============================================================================
# Serial flash clock configuration
# =============================================================================
type
  SfClkSrc* = enum
    sfClk120m = 0
    sfClk80m  = 1
    sfClkBclk = 2
    sfClk96m  = 3

proc setSfClockDiv*(divider: uint32) =
  regModify(GlbSfCfg0, 0x07'u32 shl 8, (divider and 0x07) shl 8)

proc setSfClockSource*(src: SfClkSrc) =
  regModify(GlbSfCfg0, 0x03'u32 shl 12, src.uint32 shl 12)

proc enableSfClock*() =
  regSet(GlbSfCfg0, 1'u32 shl 11)
