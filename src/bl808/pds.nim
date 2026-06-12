## BL808 Power Down Sleep (PDS) and Hibernate (HBN) controller.
##
## PDS at 0x2000E000 — controls power-down sleep modes
## HBN at 0x2000F000 — controls deep hibernate mode
##
## Sleep modes (from lightest to deepest):
##   1. WFI — CPU halts, peripherals active, instant wake
##   2. PDS — Configurable power domains off, fast wake (~μs)
##   3. HBN — Most power off, HBN RAM retained, slow wake (~ms)

import mmio, memmap, core, efuse

# =============================================================================
# PDS register offsets
# =============================================================================
const
  PdsCtl*           = PdsBase + 0x00'u   # PDS control
  PdsTime1*         = PdsBase + 0x04'u   # PDS sleep duration
  PdsInt*           = PdsBase + 0x0C'u   # PDS interrupt status/control
  PdsCtl2*          = PdsBase + 0x10'u   # Additional control
  PdsCtl3*          = PdsBase + 0x14'u   # Additional control
  PdsCtl4*          = PdsBase + 0x18'u   # Additional control
  PdsStat*          = PdsBase + 0x1C'u   # PDS status
  PdsRam1*          = PdsBase + 0x20'u   # RAM retention/sleep config 1
  PdsCtl5*          = PdsBase + 0x24'u   # Additional control (WFI mask, LDO)
  PdsRam2*          = PdsBase + 0x28'u   # RAM retention/sleep config 2
  PdsCpuCoreCfg0*   = PdsBase + 0x110'u  # CPU core power config
  PdsCpuCoreCfg8*   = PdsBase + 0x130'u  # LP E902 RTC/MTimer clock config
  PdsRc32mCtrl0*    = PdsBase + 0x300'u  # RC32M oscillator control
  PdsRc32mCtrl1*    = PdsBase + 0x304'u  # RC32M control
  PdsPuRstClkpll*   = PdsBase + 0x400'u  # PLL power-up/reset
  PdsUsbCtl*        = PdsBase + 0x500'u  # USB control
  PdsUsbPhyCtrl*    = PdsBase + 0x504'u  # USB PHY control

  PdsGpioISet*      = PdsBase + 0x30'u   # PDS GPIO input enable groups
  PdsGpioPdSet*     = PdsBase + 0x34'u   # PDS GPIO pulldown groups
  PdsGpioPuSet*     = PdsBase + 0x38'u   # PDS GPIO pullup groups
  PdsGpioInt*       = PdsBase + 0x40'u   # PDS GPIO interrupt mode/clear
  PdsGpioStat*      = PdsBase + 0x44'u   # PDS GPIO wake status

  PdsMmForceMask*   = 0x0002_2222'u32    # Force-off bits for MM/D0 domain

# =============================================================================
# HBN register offsets
# =============================================================================
const
  HbnCtl*           = HbnBase + 0x00'u   # HBN control
  HbnTimL*          = HbnBase + 0x04'u   # HBN timer low
  HbnTimH*          = HbnBase + 0x08'u   # HBN timer high
  HbnRtcTimL*       = HbnBase + 0x0C'u   # RTC time low
  HbnRtcTimH*       = HbnBase + 0x10'u   # RTC time high
  HbnIrqMode*       = HbnBase + 0x14'u   # HBN IRQ mode
  HbnIrqStat*       = HbnBase + 0x18'u   # HBN IRQ status
  HbnIrqClr*        = HbnBase + 0x1C'u   # HBN IRQ clear
  HbnPir*           = HbnBase + 0x20'u   # PIR config
  HbnGlb*           = HbnBase + 0x30'u   # HBN global
  HbnPadCtrl0*      = HbnBase + 0x38'u   # AON pad control 0
  HbnPadCtrl1*      = HbnBase + 0x3C'u   # AON pad control 1
  HbnRsv0*          = HbnBase + 0x100'u  # Reserved 0 (retained user storage)
  HbnRsv1*          = HbnBase + 0x104'u  # Reserved 1
  HbnRsv2*          = HbnBase + 0x108'u  # Reserved 2
  HbnRsv3*          = HbnBase + 0x10C'u  # Reserved 3
  HbnRc32kCtrl*     = HbnBase + 0x110'u  # RC32K control
  HbnXtal32kCtrl*   = HbnBase + 0x114'u  # XTAL32K control

# =============================================================================
# PDS control fields
# =============================================================================
const
  PdsStartPs*       = 0       # Start power-down sequence
  PdsCrSleepForever* = 1      # Sleep forever (no timer wake)
  PdsCrPdsForceCpu* = 2       # Force CPU off
  PdsXtalForceOff*  = 4       # Force XTAL off
  PdsPdsWakeupSrc*  = 8       # Wakeup source [11:8]

  PdsIntClear*      = 8
  PdsWakeupSrcEnMask* = 0x7FF'u32 shl 10
  PdsWakeSrcTimer*  = 1'u32 shl 10
  PdsWakeSrcHbn*    = 1'u32 shl 11
  PdsWakeSrcGlbGpio* = 1'u32 shl 12
  PdsWakeSrcPdsGpio* = 1'u32 shl 13
  PdsWakeSrcIrRx*   = 1'u32 shl 14
  PdsWakeSrcWifiWake* = 1'u32 shl 15
  PdsWakeSrcWifiTbtt* = 1'u32 shl 19

  PdsE902RtcDivMask* = 0x3FF'u32
  PdsE902RtcRst*     = 1'u32 shl 30
  PdsE902RtcEn*      = 1'u32 shl 31
  PdsE902RtcDiv1MHz* = 159'u32
    ## Ox64 LP normally uses a 160 MHz source; divider is value+1.

# =============================================================================
# HBN_CTL (0x2000F000) bit positions — verified against vendor hbn_reg.h.
# (The previous values here were wrong: HbnSwRst/HbnRtcCtl/HbnDisPwrOff* and a
#  bogus HbnPowerOnRst at bit 0. Bit 0 is actually the RTC-counter enable.)
# =============================================================================
const
  HbnCtlRtcEn*        = 0    # HBN_RTC_CTL[0] — RTC counter enable
  HbnCtlRtcDlyOption* = 4    # HBN_RTC_DLY_OPTION
  HbnMode*            = 7    # HBN_MODE — set to enter hibernate
  HbnCtlTrapMode*     = 8    # HBN_TRAP_MODE
  HbnCtlPwrdnHbnCore* = 9    # HBN_PWRDN_HBN_CORE (LEVEL_1 sets it; LEVEL_0 clears)
  HbnCtlSwRst*        = 12   # HBN_SW_RST
  HbnCtlDisPwrOffLdo11*   = 13
  HbnCtlDisPwrOffLdo11Rt* = 14
  HbnLdo11RtVoutSelShift*  = 15   # HBN_LDO11_RT_VOUT_SEL  [18:15]
  HbnLdo11AonVoutSelShift* = 19   # HBN_LDO11_AON_VOUT_SEL [22:19]
  HbnLdoVoutSelMask*  = 0xF'u32
  HbnLdoLevel0p90V*   = 6'u32     # HBN_LDO_LEVEL_0P90V (vendor HBN default)
  HbnCtlPuDcdcAon*    = 23   # HBN_PU_DCDC_AON
  HbnCtlPuDcdc18Aon*  = 24   # HBN_PU_DCDC18_AON
  HbnCtlPwrOnOption*  = 25   # HBN_PWR_ON_OPTION (0 = POR-twice for robustness)
  # HBN_SRAM (0x34): retention controls.
  HbnSram*            = HbnBase + 0x34'u
  HbnRetramRet*       = 6    # HBN_RETRAM_RET
  HbnRetramSlp*       = 7    # HBN_RETRAM_SLP
  # HBN_GLB (0x30) sub-fields used in entry.
  HbnGlbRootClkSelMask* = 0x3'u32          # HBN_ROOT_CLK_SEL [1:0] (0 = RC32M)
  HbnGlbF32kSelMask*    = 0x3'u32 shl 3     # HBN_F32K_SEL [4:3] (0 = RC32K)
  # HBN_IRQ_MODE (0x14).
  HbnIrqModeEnHwPuPd* = 16                  # HBN_REG_EN_HW_PU_PD
  HbnIrqModePinWakeupMask* = 0x1FF'u32 shl 4  # HBN_PIN_WAKEUP_MASK [12:4]
  # RTC comparator arm constants (vendor HBN_Set_RTC_Timer args).
  HbnRtcCompBit0_39*  = 0x01'u32   # comp mode -> HBN_CTL[3:1] = compMode<<1
  # HBN_RC32K_CTRL0 (0x200): RC32K power-up bit (NOT bit0 of 0x110 — S4 finding).
  HbnRc32kCtrl0*      = HbnBase + 0x200'u
  HbnPuRc32k*         = 1'u32 shl 21
  # AON_RF_TOP_AON (0x880; AON shares the HBN base): crystal-oscillator power.
  AonRfTopAon*        = HbnBase + 0x880'u
  AonPuXtalBufAon*    = 1'u32 shl 4   # AON_PU_XTAL_BUF_AON
  AonPuXtalAon*       = 1'u32 shl 5   # AON_PU_XTAL_AON
  HbnGlbMcuXclkSel*   = 1'u32 shl 0   # HBN_GLB MCU XCLK select (0 = RC32M, 1 = XTAL)

# =============================================================================
# Types
# =============================================================================
type
  SleepMode* = enum
    sleepWfi       ## WFI only — lightest sleep
    sleepPdsLight  ## PDS with minimal power-down
    sleepPdsDeep   ## PDS with most domains off
    sleepHbn       ## Full hibernate

  WakeupSource* = enum
    wakeTimer      ## Timer wakeup
    wakeGpio       ## GPIO interrupt wakeup
    wakeRtc        ## RTC alarm wakeup

proc pdsClearIrq*()
proc hbnClearWarmBootMagic*()

# =============================================================================
# PDS operations
# =============================================================================
proc pdsConfigureLpMtimerClock*(divider: uint32 = PdsE902RtcDiv1MHz) =
  ## Enable and reset the LP E902 CORET/mtime clock.
  ## The divider field is programmed as value+1, matching the Bouffalo SDK.
  regClear(PdsCpuCoreCfg8, PdsE902RtcEn)
  core.fenceIo()
  regClear(PdsCpuCoreCfg8, PdsE902RtcRst)
  core.fenceIo()
  regSet(PdsCpuCoreCfg8, PdsE902RtcRst)
  core.fenceIo()
  regClear(PdsCpuCoreCfg8, PdsE902RtcRst)
  core.fenceIo()
  regModify(PdsCpuCoreCfg8, PdsE902RtcDivMask, divider)
  core.fenceIo()
  regSet(PdsCpuCoreCfg8, PdsE902RtcEn)
  core.fenceIo()

proc pdsSleep*(durationMs: uint32, sources: set[WakeupSource] = {wakeTimer}) =
  ## Enter PDS (Power Down Sleep) for the given duration.
  ## Only available on M0/LP cores.

  # Configure sleep duration (in units of 32 KHz clock ticks)
  # 32 KHz = 1 tick per ~31.25 μs, so ms * 32 = approximate ticks
  let ticks = durationMs * 32
  regWrite(PdsTime1, ticks)

  # Configure wakeup sources
  var ctl = regRead(PdsCtl)
  if wakeTimer in sources:
    ctl = ctl and not (1'u32 shl PdsCrSleepForever)  # Don't sleep forever
  else:
    ctl = ctl or (1'u32 shl PdsCrSleepForever)

  regWrite(PdsCtl, ctl)

  # Clear stale wake status while preserving the configured wake-source mask.
  pdsClearIrq()

  # Start PDS
  regSet(PdsCtl, 1'u32 shl PdsStartPs)

  # CPU will halt here and resume after wakeup
  # NOTE: this is a STUB — it does not produce a wakeable sleep on real silicon.
  # A correct PDS entry needs the full vendor PDS_Enable level config (PDS_CTL /
  # PDS_CTL4 power-domain/clock/LDO fields + PDS_CTL[20:10] wake-source-enable +
  # PDS_TIME1 warmup-latency compensation). HW-confirmed to hang. See pds notes.
  wfi()

proc pdsDiagTimerWake*(durationMs: uint32): tuple[fired: bool, polls: uint32] =
  ## DIAGNOSTIC: arm only the PDS timer + wake source (NO power-down, so the M0
  ## stays clocked and UART alive), pulse pds_start, then busy-poll PDS_INT
  ## ro_pds_wake_int (bit 0). Tells us whether the PDS timer fires a wake event
  ## at all, isolated from the WFI-wake-on-interrupt question.
  regSet(HbnRc32kCtrl, 1'u32)
  regModify(HbnGlb, 0x3'u32 shl 3, 0'u32 shl 3)   # HBN_F32K_SEL = RC32K (the f32k
                                                   # clock the PDS timer counts on)
  core.fenceIo()
  let sleepCnt = durationMs * 32
  regWrite(PdsTime1, if sleepCnt > 38'u32: sleepCnt - 38'u32 else: 1'u32)
  # Minimal CTL: only set the start bit + clear sleep-forever, leave power fields 0.
  pdsClearIrq()
  core.fenceIo()
  var ctl = regRead(PdsCtl) and not (1'u32 shl PdsCrSleepForever)
  regWrite(PdsCtl, ctl)                 # config, start=0
  regWrite(PdsCtl, ctl or 1'u32)        # rising edge on pds_start_ps
  core.fenceIo()
  var polls = 0'u32
  while polls < 2_000_000'u32:
    if (regRead(PdsInt) and 1'u32) != 0: return (true, polls)   # ro_pds_wake_int
    inc polls
  (false, polls)

proc pdsEnterLightTimerWake*(durationMs: uint32) =
  ## "Light" PDS: power down the MM/DSP domain and WFI the CPU with a timer wake,
  ## but KEEP the PLL/xtal/flash ON so entry+exit run from flash XIP (no TCM /
  ## flash-power-down needed — that's what the deep vendor path requires). The
  ## CPU clock-gates in WFI and resumes in place on the PDS timer.
  const
    HbnRc32kCtrl0 = HbnBase + 0x200'u
    HbnPuRc32k    = 1'u32 shl 21
    # CTL with the clock/power KILLERS cleared (no xtalOff/pllOff/pwrOff/dcdc) —
    # just start + gate-clk + mem-stby + iso + rf, so flash stays alive.
    # Engage the PDS state machine by powering down the MM/DSP domain (CTL4), but
    # set NO global CPU-affecting bits in CTL (gateClk/memStby/iso gate/isolate
    # the CPU and weren't restoring on wake) — just pds_start. Keep xtal on so the
    # observer's UART survives.
    CtlLight  = 0x00000001'u32   # pds_start only
    Ctl3Light = 0x04000000'u32   # mm_iso_en
    Ctl4Light = 0x00000F00'u32   # mm pwr_off|reset|mem_stby|gate_clk (engages SM)
    Ctl5Light = 0x00070314'u32
  # f32k / RC32K — the wake timer's clock.
  regSet(HbnRc32kCtrl0, HbnPuRc32k); core.fenceIo()
  core.delayUs(900)
  regModify(HbnGlb, 0x3'u32 shl 3, 0'u32 shl 3)   # HBN_F32K_SEL = RC32K
  core.fenceIo()

  let sleepCnt = durationMs * 32
  regWrite(PdsTime1, if sleepCnt > 38'u32: sleepCnt - 38'u32 else: 1'u32)
  regWrite(PdsRam1, regRead(PdsRam1) or (1'u32 shl 31))
  regWrite(PdsCtl2, 0)
  regWrite(PdsCtl3, Ctl3Light)
  regWrite(PdsCtl5, Ctl5Light)
  regWrite(PdsCtl4, Ctl4Light)

  # PDS_INT: unmask the sleep-timer wakeup (bit 10). Clear pending status with a
  # PULSE on cr_pds_int_clr (bit 8) — set THEN clear. Leaving int_clr set (the old
  # bug, found via the LP observer) continuously clears ro_pds_wake_int so the
  # wake can never latch and the CPU never leaves WFI.
  var pint = regRead(PdsInt) or (1'u32 shl 10)   # unmask pds timer wakeup
  regWrite(PdsInt, pint or (1'u32 shl PdsIntClear))   # int_clr = 1
  regWrite(PdsInt, pint and not (1'u32 shl PdsIntClear))  # int_clr = 0 (pulse)
  core.fenceIo()

  # Start PDS (rising edge on bit 0) then WFI.
  regWrite(PdsCtl, CtlLight and not 1'u32)
  regWrite(PdsCtl, CtlLight or 1'u32)
  core.fenceIo()
  wfi()

proc pdsSetMcu0ResetAddress*(entry: uint32) =
  ## Where the M0 (NP) restarts on a PDS wake when the MCU domain was powered
  ## down (PDS_CPU_CORE_CFG14). On Level-1+ the core comes back via a cold
  ## restart at this address, not a resume at WFI.
  regWrite(PdsBase + 0x148'u, entry)

proc pdsEnterLevel1*(durationMs: uint32) =
  ## Enter PDS Level-1 (the lightest power-down: MM/D0 + PLLs/xtal off, but the
  ## MCU/M0 domain and OCRAM/WRAM RETAINED) for a timer wake, then resume in
  ## place after the WFI. This is a faithful reimplementation of the vendor
  ## PDS_RAM_Config + PDS_Force_Config + PDS_Enable for Level 1 (config words
  ## derived from hal_pm.c pdsCfgLevel1 against the pds_reg.h bit layout). The
  ## ROM-API shortcut is unavailable (the SDK ROM table base does not match this
  ## chip's BootROM), so the sequence is open-coded.
  const
    PdsWarmupLatency = 38'u32
    CtlLevel1  = 0x34746B81'u32  # start|dcdc18Off|gateClk|memStby|iso|pwrOff|
                                 # xtalOff|dcdc11VselEn|au/cpu/wifiPllOff|vsel8|rf3
    Ctl2Level1 = 0x00000000'u32
    Ctl3Level1 = 0x04000000'u32  # cr_pds_mm_iso_en (DspIsoEn)
    Ctl4Level1 = 0x00000F00'u32  # mm pwr_off|reset|mem_stby|gate_clk
    Ctl5Level1 = 0x00070314'u32  # mm/pico wfi_mask|usb33|pd_ldo18io|gpio_keep=7
  let sleepCnt = durationMs * 32           # ~32 KHz ticks

  # The PDS sleep counter ticks on the f32k clock; it MUST be running or the
  # timer never expires and the core never wakes. Power on RC32K correctly:
  # HBN_PU_RC32K is bit 21 of HBN_RC32K_CTRL0 (0x2000F200) — NOT bit 0 of 0x...110
  # — then wait >800us for it to settle, then select it as the f32k source.
  const
    HbnRc32kCtrl0 = HbnBase + 0x200'u   # HBN_RC32K_CTRL0
    HbnPuRc32k    = 1'u32 shl 21         # HBN_PU_RC32K
  regSet(HbnRc32kCtrl0, HbnPuRc32k)
  core.fenceIo()
  core.delayUs(900)                       # RC32K oscillator settle (>800us)
  regModify(HbnGlb, 0x3'u32 shl 3, 0'u32 shl 3)   # HBN_F32K_SEL = RC32K
  core.fenceIo()

  # PDS_RAM_Config: keep OCRAM/WRAM retained (Level 1 leaves their fields), only
  # set the PD_CORE SRAM clock-gating bit (RAM1[31]).
  regWrite(PdsRam1, regRead(PdsRam1) or (1'u32 shl 31))
  regWrite(PdsRam2, regRead(PdsRam2))

  # PDS_Force_Config: CTL2/CTL3/CTL5.
  regWrite(PdsCtl2, Ctl2Level1)
  regWrite(PdsCtl3, Ctl3Level1)
  regWrite(PdsCtl5, Ctl5Level1)

  # PDS_Enable: sleep count (HW compensates the LDO warmup latency), CTL4, clear
  # the wake int, then a rising edge on PDS_CTL[0] (start) with the full config.
  if sleepCnt > PdsWarmupLatency:
    regWrite(PdsTime1, sleepCnt - PdsWarmupLatency)
  else:
    regWrite(PdsTime1, 0)                  # 0 => timer wake masked
  regWrite(PdsCtl4, Ctl4Level1)
  pdsClearIrq()
  core.fenceIo()
  regWrite(PdsCtl, CtlLevel1 and not 1'u32)   # config with start=0
  regWrite(PdsCtl, CtlLevel1 or 1'u32)        # rising edge on start
  core.fenceIo()

  wfi()                                     # halt; timer wake resumes here

proc pdsGetStatus*(): uint32 =
  ## Read PDS status register.
  regRead(PdsStat)

proc pdsClearIrq*() =
  ## Clear pending PDS wake/interrupt flags. cr_pds_int_clr (bit 8) must be a
  ## PULSE (set then clear) — leaving it set perpetually clears ro_pds_wake_int
  ## so a subsequent timer wake can never latch (found via the LP observer).
  let keep = regRead(PdsInt) and PdsWakeupSrcEnMask
  regWrite(PdsInt, keep or (1'u32 shl PdsIntClear))
  regWrite(PdsInt, keep)

proc pdsPowerOnMmSystem*() =
  ## Power on the MM/D0 subsystem by clearing PDS_CTL2 force-off bits.
  regWrite(PdsCtl2, 0'u32)

proc pdsPowerOffMmSystem*() =
  ## Power off the MM/D0 subsystem by asserting PDS_CTL2 force-off bits.
  regWrite(PdsCtl2, PdsMmForceMask)

# =============================================================================
# HBN (Hibernate) operations
# =============================================================================
const Rc32kHz* = 32768'u64   ## RC32K / f32k tick rate; HBN RTC counts on it.

proc hbnReadRtc*(): uint64 =
  ## Latch then read the 40-bit RTC counter. The latch pulse on HbnRtcTimH[31] is
  ## MANDATORY (a direct read returns a stale/garbage value) — verified in S4's
  ## m0_f32k_diag_test, and matching the vendor HBN_Get_RTC_Timer_Val.
  regSet(HbnRtcTimH, 1'u32 shl 31)        # set LATCH
  regClear(HbnRtcTimH, 1'u32 shl 31)      # clear LATCH
  core.fenceIo()
  let lo = regRead(HbnRtcTimL)
  let hi = regRead(HbnRtcTimH) and 0xFF'u32
  (hi.uint64 shl 32) or lo.uint64

proc hbnClearRtcCounter*() =
  ## HBN_Clear_RTC_Counter: HBN_RTC_CTL[0] = 0.
  regClear(HbnCtl, 1'u32 shl HbnCtlRtcEn)

proc hbnEnableRtcCounter*() =
  ## HBN_Enable_RTC_Counter: HBN_RTC_CTL[0] = 1.
  regSet(HbnCtl, 1'u32 shl HbnCtlRtcEn)

proc hbnSetRtcTimer*(comp: uint64) =
  ## Arm the HBN RTC comparator (vendor HBN_Set_RTC_Timer, DELAY_0T + COMP_BIT0_39):
  ## write the 40-bit compare value, set dly_option, set compare mode in HBN_CTL[3:1].
  regWrite(HbnTimL, (comp and 0xFFFF_FFFF'u64).uint32)
  regWrite(HbnTimH, ((comp shr 32) and 0xFF'u64).uint32)
  var ctl = regRead(HbnCtl)
  ctl = ctl or (1'u32 shl HbnCtlRtcDlyOption)     # HBN_RTC_INT_DELAY_0T -> dly_option = 1
  ctl = ctl or (HbnRtcCompBit0_39 shl 1)          # compare mode into HBN_CTL[3:1]
  regWrite(HbnCtl, ctl)

proc hbnPowerOnRc32k*() =
  ## HBN_Power_On_RC32K: set HBN_PU_RC32K (bit 21 of HBN_RC32K_CTRL0 @0x200) and wait
  ## >800us for the oscillator to settle. (The old enableRc32k poked the wrong bit.)
  regSet(HbnRc32kCtrl0, HbnPuRc32k)
  core.fenceIo()
  core.delayUs(900)

proc hbnTrimRc32k*() =
  ## Apply the efuse-calibrated RC32K trim (vendor HBN_Trim_RC32K): write the tuned
  ## oscillator code into HBN_RC32K_CTRL0 (CODE_FR_EXT[31:22], EXT_CODE_EN bit 19).
  ## Without it the RC32K runs untrimmed — fine at the boot voltage, but it drifts
  ## or stalls at the 0.90 V HBN AON LDO, which stops the RTC and prevents the wake.
  ## The trim lives in efuse EF_KEY_SLOT_10_W3: code[17:8], parity bit 18, enable 19.
  let w = efuseReadWord(0xEC'u32 div 4)          # EF_KEY_SLOT_10_W3 (offset 0xEC)
  let code = (w shr 8) and 0x3FF'u32
  let parityStored = (w shr 18) and 0x1'u32
  let extCodeEn = (w shr 19) and 0x1'u32
  var p = 0'u32
  for i in 0 ..< 10:
    p = p xor ((code shr i) and 0x1'u32)         # even parity over the 10-bit code
  if extCodeEn == 1'u32 and p == parityStored:
    var v = regRead(HbnRc32kCtrl0)
    v = (v and not (0x3FF'u32 shl 22)) or (code shl 22)   # HBN_RC32K_CODE_FR_EXT
    v = v or (1'u32 shl 19)                                # HBN_RC32K_EXT_CODE_EN
    regWrite(HbnRc32kCtrl0, v)
    core.fenceIo()
    core.delayUs(2)

proc hbnEnterRtcWake*(seconds: uint32) {.noreturn.} =
  ## M0 HBN LEVEL_0 deep hibernate with an RTC self-wake — HW-VALIDATED on the Ox64
  ## (20.1 s deep sleep + RTC POR wake, repeatable). This is the MINIMAL entry: set up
  ## RC32K, arm the RTC comparator, set HBN_MODE. It runs safely from flash XIP and the
  ## RTC POR cold-boots the flashed image on wake.
  ##
  ## It deliberately does NOT do the vendor's HBN power-minimization (drop AON LDO11 to
  ## 0.90 V, switch the core to RC32M, power off the XTAL). On the BL808 the 0.90 V AON
  ## path is a TCM-resident / LP-domain operation: those steps pull the LDO/clock/XTAL
  ## out from under a flash-XIP-executing E907/M0 and CRASH it before HBN_MODE is set
  ## (HW-verified — the M0 dies mid-teardown). The vendor runs them from TCM (every such
  ## function is ATTR_TCM_SECTION) after powering flash down. Adding the 0.90 V path for
  ## the M0 would need a TCM-resident entry; see hbnTrimRc32k / AonRfTopAon / the LDO
  ## constants below for the building blocks, and the LP-core path for the natural home.
  disableInterrupts()
  # Clean cold boot on wake: HBN_RSV0 must be NON-magic (so the ROM doesn't fast-path to
  # the unset HBN_RSV1 resume pointer) AND NON-ZERO (RSV0=0 fails to flash-boot on this
  # part — HW-verified). A benign sentinel satisfies both.
  regWrite(HbnRsv0, 0x5A5A_0000'u32)
  regWrite(HbnRsv1, 0x5A5A_0001'u32)
  regWrite(HbnIrqClr, 0xFFFF_FFFF'u32); regWrite(HbnIrqClr, 0); core.fenceIo()

  # 1. 32K clock source = RC32K (the RTC clock).
  hbnPowerOnRc32k()
  regModify(HbnGlb, HbnGlbF32kSelMask, 0)         # HBN_F32K_SEL = RC32K
  core.fenceIo()

  # 2. Arm the RTC comparator for now + seconds (the wake AND the safety net — once
  #    armed, any later hang still POR-wakes the chip after `seconds`).
  hbnClearRtcCounter()
  let comp = hbnReadRtc() + seconds.uint64 * Rc32kHz
  hbnSetRtcTimer(comp)
  hbnEnableRtcCounter()
  core.fenceIo()

  # 3. Enter HBN. We do NOT pre-touch HBN_CTL's PWRDN_HBN_CORE / PWR_ON_OPTION bits:
  #    the boot defaults are already LEVEL_0 + POR-twice, and the extra HBN_CTL
  #    read-modify-writes after arming the RTC were HW-observed to suppress the wake
  #    (the disambig, which sets only HBN_MODE, wakes reliably). Just set HBN_MODE.
  regSet(HbnCtl, 1'u32 shl HbnMode)
  while true:
    core.delayMs(1000)

proc hbnClearIrq*() =
  ## Clear HBN interrupt flags.
  regWrite(HbnIrqClr, 0xFFFF_FFFF'u32)

# =============================================================================
# HBN retention RAM (persists across HBN sleep)
# =============================================================================
proc hbnWriteRetention*(index: range[0..3], value: uint32) =
  ## Write to HBN reserved registers (persist across HBN sleep).
  let regAddr = HbnRsv0 + index.uint * 4
  regWrite(regAddr, value)

proc hbnReadRetention*(index: range[0..3]): uint32 =
  let regAddr = HbnRsv0 + index.uint * 4
  regRead(regAddr)

# =============================================================================
# BootROM warm-boot fast-path magic
# =============================================================================
# The BootROM, before running flash, reads the word at HbnRsv0 (0x2000F100) and,
# if it matches one of these magics, takes a warm-boot fast path that JUMPS to a
# retained resume pointer — skipping the normal boot (and, for us, the secure
# stage: verify / measure / TZC lock). Verified against bootrom.dis @0x9000003a
# (EHBN) / @0x9000004a (WHBN), both compared to the word at 0x2000F100.
const
  HbnWarmBootMagicEhbn* = 0x4E424845'u32  # "EHBN"
  HbnWarmBootMagicWhbn* = 0x4E424857'u32  # "WHBN"

proc hbnWarmBootMagicArmed*(): bool =
  ## True if the BootROM would take the warm-boot fast path on the next reset.
  let m = regRead(HbnRsv0)
  m == HbnWarmBootMagicEhbn or m == HbnWarmBootMagicWhbn

proc hbnClearWarmBootMagic*() =
  ## Defang the BootROM warm-boot fast path: clear the HbnRsv0 magic (and the
  ## HbnRsv1 retained pointer) so a stale or attacker-planted "EHBN"/"WHBN"
  ## cannot make the next reset bypass the secure stage. The secure stage calls
  ## this on every cold boot; a deliberate, measured resume re-arms it itself.
  regWrite(HbnRsv0, 0)
  regWrite(HbnRsv1, 0)

# =============================================================================
# RC32K / XTAL32K management
# =============================================================================
proc enableRc32k*() =
  regSet(HbnRc32kCtrl, 1'u32)

proc enableXtal32k*() =
  regSet(HbnXtal32kCtrl, 1'u32)
