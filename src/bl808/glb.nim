## BL808 Global (GLB) control: clock tree, PLL, clock gating, resets.
##
## The GLB block at 0x20000000 controls system clocks, peripheral resets,
## and clock gating for the MCU subsystem.
## The MM_GLB block at 0x30007000 controls clocks for the MM (D0) subsystem.

import mmio, memmap

# =============================================================================
# GLB register offsets (MCU subsystem, base 0x20000000)
# =============================================================================
const
  # System clock configuration
  GlbSysCfg0*       = GlbBase + 0x000'u
  GlbSysCfg1*       = GlbBase + 0x004'u
  GlbMcuCfg0*       = GlbBase + 0x090'u  # HBN root clk sel, HCLK/BCLK div

  # PLL configuration (from bouffalo_sdk glb_reg.h: offsets 0x810-0x848)
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
  GlbWifiPllCfg14*  = GlbBase + 0x848'u  # Reserved / DL control

  # AUPLL accessed via CCI at 0x20008000 + 0x750
  GlbAuPllCfg0*     = CciBase + 0x750'u  # Audio PLL reset/power
  GlbAuPllCfg1*     = CciBase + 0x754'u  # Audio PLL post-div, ref-div
  GlbAuPllCfg5*     = CciBase + 0x764'u  # Audio PLL VCO speed
  GlbAuPllCfg6*     = CciBase + 0x768'u  # Audio PLL SDM fractional
  GlbAuPllCfg8*     = CciBase + 0x770'u  # Audio PLL output dividers

  # Peripheral clock configuration
  GlbUartCfg0*      = GlbBase + 0x150'u  # UART clock
  GlbUartSigSwap*   = GlbBase + 0x154'u  # UART signal swap
  GlbSfCfg0*        = GlbBase + 0x160'u  # Serial flash clock
  GlbI2cCfg0*       = GlbBase + 0x180'u  # I2C clock
  GlbSpiCfg0*       = GlbBase + 0x1B0'u  # SPI clock
  GlbDmaCfg0*       = GlbBase + 0x130'u  # DMA clock
  GlbEmiCfg0*       = GlbBase + 0x0E0'u  # EMI/PSRAM clock
  GlbRtcCfg0*       = GlbBase + 0x0F0'u  # RTC clock

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
    periphUart0   = 16
    periphUart1   = 17
    periphSpi     = 18
    periphI2c0    = 19
    periphPwm     = 20
    periphTimer   = 21
    periphIr      = 22
    periphCks     = 23
    periphDma0    = 24
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
proc setUartClockDiv*(divider: uint32) =
  ## Set UART clock divider (0 = divide by 1).
  regModify(GlbUartCfg0, 0x07'u32, divider and 0x07)

proc enableUartClock*() =
  ## Enable UART clock.
  regSet(GlbUartCfg0, 1'u32 shl 4)

proc setUartClockSource*(src: UartClkSrc) =
  ## Select UART clock source.
  regModify(GlbUartCfg0, 0x03'u32 shl 7, src.uint32 shl 7)

# =============================================================================
# SPI clock configuration
# =============================================================================
proc setSpiClockDiv*(divider: uint32) =
  ## Set SPI clock divider.
  regModify(GlbSpiCfg0, 0x1F'u32 shl 0, divider and 0x1F)

proc enableSpiClock*() =
  regSet(GlbSpiCfg0, 1'u32 shl 8)

proc setSpiClockSource*(src: SpiClkSrc) =
  regModify(GlbSpiCfg0, 0x03'u32 shl 9, src.uint32 shl 9)

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
  regWaitClear(GlbSysCfg1, 1'u32 shl 0)

  # Switch clock source
  regModify(GlbMcuCfg0, HbnRootClkSelMask, rootSel shl HbnRootClkSelShift)

# =============================================================================
# MM (D0) system clock configuration
# =============================================================================
proc setDspSysClock*(src: DspSysClk) =
  ## Configure D0 subsystem clock source.
  var clkSel: uint32
  case src
  of dspClkRc32m:    clkSel = 0
  of dspClkXtal:     clkSel = 1
  of dspClkWifiPll240m: clkSel = 2
  of dspClkWifiPll320m: clkSel = 3
  of dspClkCpuPll400m:  clkSel = 4

  regModify(MmClkCtrlCpu, 0x07'u32, clkSel)

proc enableMmPeriphClock*(bit: uint32) =
  ## Enable an MM subsystem peripheral clock (bit in MM_CLK_CTRL_PERI).
  regSet(MmClkCtrlPeri, 1'u32 shl bit)

proc resetMmPeriph*(bit: uint32) =
  ## Reset an MM subsystem peripheral.
  regSet(MmSwResetPeri, 1'u32 shl bit)
  for i in 0 ..< 10:
    discard regRead(MmSwResetPeri)
  regClear(MmSwResetPeri, 1'u32 shl bit)

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
  # PWM clock
  GlbPwmCfg0*      = GlbBase + 0x1D0'u

  # IR clock
  GlbIrCfg0*       = GlbBase + 0x1C0'u

  # I2S / Audio clock
  GlbI2sCfg0*      = GlbBase + 0x1A0'u

  # ADC / DAC clock
  GlbAdcCfg0*      = GlbBase + 0x0F4'u
  GlbDacCfg0*      = GlbBase + 0x0F8'u
  GlbGpAdcCfg0*    = GlbBase + 0x0FC'u

  # XTAL configuration
  GlbXtalCfg*      = GlbBase + 0x510'u

  # Digtal clock config
  GlbDigClkCfg0*   = GlbBase + 0x100'u
  GlbDigClkCfg1*   = GlbBase + 0x104'u
  GlbDigClkCfg2*   = GlbBase + 0x108'u

  # CGEN_CFG0 bit assignments (system level clocks)
  CgenCfg0DmaCh0*  = 0
  CgenCfg0DmaCh1*  = 1
  CgenCfg0DmaCh2*  = 2
  CgenCfg0DmaCh3*  = 3
  CgenCfg0DmaCh4*  = 4
  CgenCfg0DmaCh5*  = 5
  CgenCfg0DmaCh6*  = 6
  CgenCfg0DmaCh7*  = 7

  # CGEN_CFG2 bit assignments
  CgenCfg2Sf*      = 0  # Serial flash controller
  CgenCfg2Dma0*    = 1
  CgenCfg2Dma1*    = 2
  CgenCfg2Uart0*   = 3
  CgenCfg2Uart1*   = 4
  CgenCfg2Uart2*   = 5
  CgenCfg2I2c0*    = 6
  CgenCfg2I2c1*    = 7
  CgenCfg2Spi0*    = 8
  CgenCfg2Pwm*     = 9
  CgenCfg2Timer*   = 10
  CgenCfg2Ir*      = 11
  CgenCfg2Cks*     = 12
  CgenCfg2I2s*     = 14
  CgenCfg2Usb*     = 16
  CgenCfg2Emac*    = 17
  CgenCfg2Audio*   = 18
  CgenCfg2Sdh*     = 19

# =============================================================================
# XTAL type (Ox64 uses 40 MHz)
# =============================================================================
type
  XtalType* = enum
    xtal24m = 0
    xtal32m = 1
    xtal384m = 2
    xtal40m = 3
    xtal26m = 4
    xtalRc32m = 5

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
  WifiPllPuClktree*    = 4    # Clock tree power up
  WifiPllPuPostdiv*    = 5    # Post divider power up
  WifiPllPuFbdv*       = 6    # Feedback divider power up
  WifiPllPuClampOp*    = 7    # Clamp OP power up
  WifiPllPuPfd*        = 8    # Phase frequency detector power up
  WifiPllPuCp*         = 9    # Charge pump power up
  WifiPllPuSfreg*      = 10   # Regulator power up
  WifiPllPuPll*        = 11   # Master PLL power up

  # WIFIPLL_CFG1 fields
  WifiPllPostdivShift*     = 0
  WifiPllPostdivMask*      = 0x7F'u32
  WifiPllRefdivRatioShift* = 8
  WifiPllRefdivRatioMask*  = 0x0F'u32 shl 8
  WifiPllRefclkSelShift*   = 16
  WifiPllRefclkSelMask*    = 0x03'u32 shl 16

  # WIFIPLL_CFG8 output divider enables
  WifiPllEnDiv3*   = 4    # 320 MHz
  WifiPllEnDiv4*   = 5    # 240 MHz
  WifiPllEnDiv5*   = 6    # 192 MHz
  WifiPllEnDiv6*   = 7    # 160 MHz
  WifiPllEnDiv8*   = 8    # 120 MHz
  WifiPllEnDiv10*  = 9    # 96 MHz
  WifiPllEnDiv12*  = 10   # 80 MHz
  WifiPllEnDiv20*  = 11   # 48 MHz
  WifiPllEnDiv30*  = 12   # 32 MHz

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

  # Step 4: Enable default output dividers (160M, 240M, 320M)
  regSet(GlbWifiPllCfg8, (1'u32 shl WifiPllEnDiv3) or   # 320M
                          (1'u32 shl WifiPllEnDiv4) or   # 240M
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
proc setPwmClockDiv*(divider: uint32) =
  regModify(GlbPwmCfg0, 0x0F'u32 shl 0, divider and 0x0F)

proc setPwmClockSource*(clkSel: uint32) =
  ## Set PWM clock source. 0=XCLK, 1=BCLK (use pwm.PwmClkSrc enum).
  regModify(GlbPwmCfg0, 0x01'u32 shl 4, clkSel shl 4)

proc enablePwmClock*() =
  regSet(GlbPwmCfg0, 1'u32 shl 8)

# =============================================================================
# IR clock configuration
# =============================================================================
proc setIrClockDiv*(divider: uint32) =
  regModify(GlbIrCfg0, 0x3F'u32 shl 0, divider and 0x3F)

proc enableIrClock*() =
  regSet(GlbIrCfg0, 1'u32 shl 8)

# =============================================================================
# I2S clock configuration
# =============================================================================
proc setI2sClockDiv*(divider: uint32) =
  regModify(GlbI2sCfg0, 0x3F'u32 shl 0, divider and 0x3F)

proc enableI2sClock*() =
  regSet(GlbI2sCfg0, 1'u32 shl 8)

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
proc setDacClockDiv*(divider: uint32) =
  regModify(GlbDacCfg0, 0x3F'u32 shl 0, divider and 0x3F)

proc enableDacClock*() =
  regSet(GlbDacCfg0, 1'u32 shl 8)

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
  regModify(GlbSfCfg0, 0x07'u32, divider and 0x07)

proc setSfClockSource*(src: SfClkSrc) =
  regModify(GlbSfCfg0, 0x03'u32 shl 4, src.uint32 shl 4)

proc enableSfClock*() =
  regSet(GlbSfCfg0, 1'u32 shl 8)
