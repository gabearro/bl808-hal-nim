## BL808 Power Down Sleep (PDS) and Hibernate (HBN) controller.
##
## PDS at 0x2000E000 — controls power-down sleep modes
## HBN at 0x2000F000 — controls deep hibernate mode
##
## Sleep modes (from lightest to deepest):
##   1. WFI — CPU halts, peripherals active, instant wake
##   2. PDS — Configurable power domains off, fast wake (~μs)
##   3. HBN — Most power off, HBN RAM retained, slow wake (~ms)

import mmio, memmap, core

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
  PdsCpuCoreCfg0*   = PdsBase + 0x110'u  # CPU core power config
  PdsRc32mCtrl0*    = PdsBase + 0x300'u  # RC32M oscillator control
  PdsRc32mCtrl1*    = PdsBase + 0x304'u  # RC32M control
  PdsPuRstClkpll*   = PdsBase + 0x400'u  # PLL power-up/reset
  PdsUsbCtl*        = PdsBase + 0x500'u  # USB control
  PdsUsbPhyCtrl*    = PdsBase + 0x504'u  # USB PHY control

# =============================================================================
# HBN register offsets
# =============================================================================
const
  HbnCtl*           = HbnBase + 0x00'u   # HBN control
  HbnTimL*          = HbnBase + 0x04'u   # HBN timer low
  HbnTimH*          = HbnBase + 0x08'u   # HBN timer high
  HbnIrqMode*       = HbnBase + 0x0C'u   # HBN IRQ mode
  HbnIrqStat*       = HbnBase + 0x10'u   # HBN IRQ status
  HbnIrqClr*        = HbnBase + 0x14'u   # HBN IRQ clear
  HbnPir*           = HbnBase + 0x18'u   # PIR config
  HbnPirInterval*   = HbnBase + 0x1C'u   # PIR interval
  HbnBor*           = HbnBase + 0x20'u   # Brown-Out Reset config
  HbnGlb*           = HbnBase + 0x24'u   # HBN global
  HbnSramCtrl*      = HbnBase + 0x28'u   # SRAM control
  HbnRsv0*          = HbnBase + 0x2C'u   # Reserved 0 (user storage)
  HbnRsv1*          = HbnBase + 0x30'u   # Reserved 1 (user storage)
  HbnRsv2*          = HbnBase + 0x34'u   # Reserved 2
  HbnRsv3*          = HbnBase + 0x38'u   # Reserved 3
  HbnRc32kCtrl*     = HbnBase + 0x3C'u   # RC32K control
  HbnXtal32kCtrl*   = HbnBase + 0x44'u   # XTAL32K control
  HbnRtcTimL*       = HbnBase + 0x4C'u   # RTC time low
  HbnRtcTimH*       = HbnBase + 0x50'u   # RTC time high

# =============================================================================
# PDS control fields
# =============================================================================
const
  PdsStartPs*       = 0       # Start power-down sequence
  PdsCrPdsForceCpu* = 1       # Force CPU off
  PdsCrSleepForever* = 2      # Sleep forever (no timer wake)
  PdsXtalForceOff*  = 4       # Force XTAL off
  PdsPdsWakeupSrc*  = 8       # Wakeup source [11:8]

# =============================================================================
# HBN control fields
# =============================================================================
const
  HbnPowerOnRst*    = 0       # Power-on reset (write 1 to reset into HBN)
  HbnSwRst*         = 1       # Software reset
  HbnDisPwrOffLdo11* = 2      # Disable LDO11 power-off
  HbnDisPwrOffLdo11Rt* = 3    # Disable LDO11_RT power-off
  HbnRtcCtl*        = 8       # RTC control [12:8]

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

# =============================================================================
# PDS operations
# =============================================================================
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

  # Clear PDS interrupt
  regWrite(PdsInt, regRead(PdsInt))

  # Start PDS
  regSet(PdsCtl, 1'u32 shl PdsStartPs)

  # CPU will halt here and resume after wakeup
  wfi()

proc pdsGetStatus*(): uint32 =
  ## Read PDS status register.
  regRead(PdsStat)

# =============================================================================
# HBN (Hibernate) operations
# =============================================================================
proc hbnReadRtc*(): uint64 =
  ## Read the 64-bit RTC counter.
  let lo = regRead(HbnRtcTimL)
  let hi = regRead(HbnRtcTimH) and 0xFF  # Only 8 bits
  (hi.uint64 shl 32) or lo.uint64

proc hbnSetAlarm*(rtcTicks: uint64) =
  ## Set an RTC alarm for wake from HBN.
  regWrite(HbnTimL, (rtcTicks and 0xFFFF_FFFF).uint32)
  regWrite(HbnTimH, ((rtcTicks shr 32) and 0xFF).uint32)

proc hbnEnter*(durationMs: uint32 = 0) {.noreturn.} =
  ## Enter hibernate mode. This is a deep sleep that resets the system on wake.
  ## If durationMs > 0, sets an RTC alarm for timed wakeup.
  ## On wake, the system goes through a full reset.

  if durationMs > 0:
    let rtcNow = hbnReadRtc()
    let rtcWake = rtcNow + (durationMs.uint64 * 32)  # ~32 KHz ticks
    hbnSetAlarm(rtcWake)

  # Trigger hibernate
  regSet(HbnCtl, 1'u32 shl HbnPowerOnRst)

  # Should not reach here
  while true:
    wfi()

proc hbnClearIrq*() =
  ## Clear HBN interrupt flags.
  regWrite(HbnIrqClr, 0xFF'u32)

# =============================================================================
# HBN retention RAM (persists across HBN sleep)
# =============================================================================
proc hbnWriteRetention*(index: range[0..3], value: uint32) =
  ## Write to HBN reserved registers (persist across HBN sleep).
  let addr = HbnRsv0 + index.uint * 4
  regWrite(addr, value)

proc hbnReadRetention*(index: range[0..3]): uint32 =
  let addr = HbnRsv0 + index.uint * 4
  regRead(addr)

# =============================================================================
# RC32K / XTAL32K management
# =============================================================================
proc enableRc32k*() =
  regSet(HbnRc32kCtrl, 1'u32)

proc enableXtal32k*() =
  regSet(HbnXtal32kCtrl, 1'u32)
