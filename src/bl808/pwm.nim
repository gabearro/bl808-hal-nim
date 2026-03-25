## BL808 PWM_V2 (Pulse Width Modulation) driver.
##
## PWM base at 0x2000A400. Motor control group 0 (MC0) provides 4 channels
## (ch0-ch3), each with positive/negative complementary outputs and
## configurable dead-time.
##
## Register layout from bouffalo_sdk pwm_v2_reg.h.

import mmio, memmap

# =============================================================================
# PWM register offsets (from bouffalo_sdk pwm_v2_reg.h)
# =============================================================================
const
  PwmIntConfig*     = PwmBase + 0x00'u   # Global interrupt config
  PwmMc0Config0*    = PwmBase + 0x40'u   # MC0 config 0 (clk div, stop, break)
  PwmMc0Config1*    = PwmBase + 0x44'u   # MC0 config 1 (channel enables/polarity)
  PwmMc0Period*     = PwmBase + 0x48'u   # MC0 period + int period count
  PwmMc0DeadTime*   = PwmBase + 0x4C'u   # MC0 dead time (all 4 channels)
  PwmMc0Ch0Thre*    = PwmBase + 0x50'u   # CH0 threshold (low/high)
  PwmMc0Ch1Thre*    = PwmBase + 0x54'u   # CH1 threshold
  PwmMc0Ch2Thre*    = PwmBase + 0x58'u   # CH2 threshold
  PwmMc0Ch3Thre*    = PwmBase + 0x5C'u   # CH3 threshold
  PwmMc0IntSts*     = PwmBase + 0x60'u   # MC0 interrupt status
  PwmMc0IntMask*    = PwmBase + 0x64'u   # MC0 interrupt mask
  PwmMc0IntClear*   = PwmBase + 0x68'u   # MC0 interrupt clear
  PwmMc0IntEn*      = PwmBase + 0x6C'u   # MC0 interrupt enable

# =============================================================================
# PWM_MC0_CONFIG0 fields
# =============================================================================
const
  PwmClkDivShift*   = 0       # Clock divider [15:0]
  PwmClkDivMask*    = 0xFFFF'u32
  PwmStopOnRept*    = 19      # Stop on repeat count reached
  PwmAdcTrgSrcShift* = 20     # ADC trigger source [23:20]
  PwmAdcTrgSrcMask*  = 0x0F'u32 shl 20
  PwmSwBreakEn*     = 24      # Software break enable
  PwmExtBreakEn*    = 25      # External break enable
  PwmExtBreakPl*    = 26      # External break polarity
  PwmStopEn*        = 27      # Stop enable
  PwmStopMode*      = 28      # Stop mode (0=abrupt, 1=graceful)
  PwmStsStop*       = 29      # Status: stopped (read-only)
  PwmRegClkSelShift* = 30     # Clock source select [31:30]
  PwmRegClkSelMask*  = 0x03'u32 shl 30

# =============================================================================
# PWM_MC0_CONFIG1 fields (per-channel output enable/polarity/break state)
# =============================================================================
const
  # Channel 0
  PwmCh0Pen*        = 0       # CH0 positive output enable
  PwmCh0Psi*        = 1       # CH0 positive idle state
  PwmCh0Nen*        = 2       # CH0 negative output enable
  PwmCh0Nsi*        = 3       # CH0 negative idle state
  # Channel 1 at bits 4-7, Channel 2 at 8-11, Channel 3 at 12-15
  # Polarity at bits 16-23, Break state at bits 24-31
  PwmCh0Ppl*        = 16      # CH0 positive polarity
  PwmCh0Npl*        = 17      # CH0 negative polarity
  PwmCh0Pbs*        = 24      # CH0 positive break state
  PwmCh0Nbs*        = 25      # CH0 negative break state

# =============================================================================
# PWM_MC0_PERIOD fields
# =============================================================================
const
  PwmPeriodShift*   = 0       # Period value [15:0]
  PwmPeriodMask*    = 0xFFFF'u32
  PwmIntPeriodCntShift* = 16  # Interrupt period count [31:16]
  PwmIntPeriodCntMask*  = 0xFFFF'u32 shl 16

# =============================================================================
# PWM_MC0_DEAD_TIME fields (4 channels, 8 bits each)
# =============================================================================
const
  PwmCh0DtgShift*   = 0       # CH0 dead-time [7:0]
  PwmCh1DtgShift*   = 8       # CH1 dead-time [15:8]
  PwmCh2DtgShift*   = 16      # CH2 dead-time [23:16]
  PwmCh3DtgShift*   = 24      # CH3 dead-time [31:24]

# =============================================================================
# PWM_MC0_CHx_THRE fields (low/high threshold pair)
# =============================================================================
const
  PwmThrelShift*    = 0       # Threshold low [15:0]
  PwmThrelMask*     = 0xFFFF'u32
  PwmThrehShift*    = 16      # Threshold high [31:16]
  PwmThrehMask*     = 0xFFFF'u32 shl 16

# =============================================================================
# Interrupt bits (in INT_STS, INT_MASK, INT_CLEAR, INT_EN)
# =============================================================================
const
  PwmIntCh0l*       = 0       # CH0 low threshold match
  PwmIntCh0h*       = 1       # CH0 high threshold match
  PwmIntCh1l*       = 2
  PwmIntCh1h*       = 3
  PwmIntCh2l*       = 4
  PwmIntCh2h*       = 5
  PwmIntCh3l*       = 6
  PwmIntCh3h*       = 7
  PwmIntPrde*       = 8       # Period end interrupt
  PwmIntBrk*        = 9       # Break interrupt
  PwmIntRept*       = 10      # Repeat interrupt

# =============================================================================
# Types
# =============================================================================
type
  PwmChannel* = range[0..3]

  PwmClkSrc* = enum
    pwmClkXclk   = 0
    pwmClkBclk   = 1
    pwmClkF32k   = 2

  Pwm* = object
    base: uint

# =============================================================================
# Helper: threshold register address for a channel
# =============================================================================
proc threAddr(ch: PwmChannel): uint {.inline.} =
  PwmMc0Ch0Thre + ch.uint * 4

# =============================================================================
# PWM initialization
# =============================================================================
proc initPwm*(): Pwm =
  result.base = PwmBase

proc configureChannel*(pwm: Pwm, ch: PwmChannel, period: uint16,
                       duty: uint16, clkDiv: uint16 = 0,
                       clkSrc: PwmClkSrc = pwmClkXclk) =
  ## Configure a PWM channel.
  ## `period`: total period in clock ticks (0-65535)
  ## `duty`: duty cycle in ticks (0 to period)
  ## `clkDiv`: clock prescaler (0 = /1)

  # Stop during configuration
  regSet(PwmMc0Config0, 1'u32 shl PwmStopEn)

  # Set clock divider and source
  var cfg0 = regRead(PwmMc0Config0)
  cfg0 = (cfg0 and not PwmClkDivMask) or clkDiv.uint32
  cfg0 = (cfg0 and not PwmRegClkSelMask) or (clkSrc.uint32 shl PwmRegClkSelShift)
  regWrite(PwmMc0Config0, cfg0)

  # Set period
  regModify(PwmMc0Period, PwmPeriodMask, period.uint32)

  # Set thresholds (low = 0, high = duty for simple duty cycle)
  regWrite(threAddr(ch), duty.uint32 shl PwmThrehShift)

  # Enable positive output for this channel
  let chBit = ch.uint32 * 4
  regSet(PwmMc0Config1, 1'u32 shl chBit)  # PEN

proc setDuty*(pwm: Pwm, ch: PwmChannel, duty: uint16) =
  ## Set duty cycle (high threshold). Low threshold stays at 0.
  regModify(threAddr(ch), PwmThrehMask, duty.uint32 shl PwmThrehShift)

proc setThresholds*(pwm: Pwm, ch: PwmChannel, low, high: uint16) =
  ## Set both low and high thresholds for asymmetric waveforms.
  regWrite(threAddr(ch), low.uint32 or (high.uint32 shl PwmThrehShift))

proc setPeriod*(pwm: Pwm, period: uint16) =
  regModify(PwmMc0Period, PwmPeriodMask, period.uint32)

proc setDeadTime*(pwm: Pwm, ch: PwmChannel, dtg: uint8) =
  ## Set dead-time for complementary outputs (in clock ticks).
  let shift = ch.uint32 * 8
  regModify(PwmMc0DeadTime, 0xFF'u32 shl shift, dtg.uint32 shl shift)

# =============================================================================
# Channel control
# =============================================================================
proc start*(pwm: Pwm) =
  ## Start PWM (clear stop enable).
  regClear(PwmMc0Config0, 1'u32 shl PwmStopEn)

proc stop*(pwm: Pwm, graceful: bool = true) =
  ## Stop PWM.
  if graceful:
    regSet(PwmMc0Config0, 1'u32 shl PwmStopMode)
  else:
    regClear(PwmMc0Config0, 1'u32 shl PwmStopMode)
  regSet(PwmMc0Config0, 1'u32 shl PwmStopEn)

proc isStopped*(pwm: Pwm): bool =
  (regRead(PwmMc0Config0) and (1'u32 shl PwmStsStop)) != 0

proc enableOutput*(pwm: Pwm, ch: PwmChannel, positive: bool = true, negative: bool = false) =
  ## Enable positive and/or negative output for a channel.
  let chBit = ch.uint32 * 4
  if positive: regSet(PwmMc0Config1, 1'u32 shl chBit)        # PEN
  else: regClear(PwmMc0Config1, 1'u32 shl chBit)
  if negative: regSet(PwmMc0Config1, 1'u32 shl (chBit + 2))  # NEN
  else: regClear(PwmMc0Config1, 1'u32 shl (chBit + 2))

proc setPolarity*(pwm: Pwm, ch: PwmChannel, invertPositive: bool = false,
                  invertNegative: bool = false) =
  let pBit = 16 + ch.uint32 * 2
  if invertPositive: regSet(PwmMc0Config1, 1'u32 shl pBit)
  else: regClear(PwmMc0Config1, 1'u32 shl pBit)
  if invertNegative: regSet(PwmMc0Config1, 1'u32 shl (pBit + 1))
  else: regClear(PwmMc0Config1, 1'u32 shl (pBit + 1))

proc softwareBreak*(pwm: Pwm, enable: bool) =
  if enable: regSet(PwmMc0Config0, 1'u32 shl PwmSwBreakEn)
  else: regClear(PwmMc0Config0, 1'u32 shl PwmSwBreakEn)

# =============================================================================
# Interrupts
# =============================================================================
proc enableInterrupt*(pwm: Pwm, intBit: uint32) =
  regSet(PwmMc0IntEn, 1'u32 shl intBit)

proc disableInterrupt*(pwm: Pwm, intBit: uint32) =
  regClear(PwmMc0IntEn, 1'u32 shl intBit)

proc clearInterrupt*(pwm: Pwm, intBit: uint32) =
  regSet(PwmMc0IntClear, 1'u32 shl intBit)

proc readInterruptStatus*(pwm: Pwm): uint32 =
  regRead(PwmMc0IntSts)

# =============================================================================
# Convenience: set duty cycle as percentage
# =============================================================================
proc setDutyPercent*(pwm: Pwm, ch: PwmChannel, percent: uint32) =
  let period = regRead(PwmMc0Period) and PwmPeriodMask
  let duty = (period * min(percent, 100)) div 100
  pwm.setDuty(ch, duty.uint16)
