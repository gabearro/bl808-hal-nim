## BL808 Timer and Watchdog driver.
##
## Timer0 at 0x2000A500 (MCU subsystem, M0/LP)
## Timer1 at 0x30009000 (MM subsystem, D0)
##
## Each timer block has 2 timer channels (CH2, CH3) and a watchdog (WDT).
## Each channel has 3 match compare values.

import mmio, memmap

# =============================================================================
# Timer register offsets
# =============================================================================
const
  TimerTccr*        = 0x00'u  # Timer clock control
  TimerTmr2_0*      = 0x10'u  # Timer2 match value 0
  TimerTmr2_1*      = 0x14'u  # Timer2 match value 1
  TimerTmr2_2*      = 0x18'u  # Timer2 match value 2
  TimerTmr3_0*      = 0x1C'u  # Timer3 match value 0
  TimerTmr3_1*      = 0x20'u  # Timer3 match value 1
  TimerTmr3_2*      = 0x24'u  # Timer3 match value 2
  TimerTcr2*        = 0x2C'u  # Timer2 control
  TimerTcr3*        = 0x30'u  # Timer3 control
  TimerTsr2*        = 0x38'u  # Timer2 status
  TimerTsr3*        = 0x3C'u  # Timer3 status
  TimerTier2*       = 0x44'u  # Timer2 interrupt enable
  TimerTier3*       = 0x48'u  # Timer3 interrupt enable
  TimerTplvr2*      = 0x50'u  # Timer2 preload value
  TimerTplvr3*      = 0x54'u  # Timer3 preload value
  TimerTplcr2*      = 0x5C'u  # Timer2 preload control
  TimerTplcr3*      = 0x60'u  # Timer3 preload control
  TimerWmer*        = 0x64'u  # Watchdog match enable
  TimerWmr*         = 0x68'u  # Watchdog match value
  TimerWvr*         = 0x6C'u  # Watchdog counter value
  TimerWsr*         = 0x70'u  # Watchdog status
  TimerTicr2*       = 0x78'u  # Timer2 interrupt clear
  TimerTicr3*       = 0x7C'u  # Timer3 interrupt clear
  TimerWicr*        = 0x80'u  # Watchdog interrupt clear
  TimerTcer*        = 0x84'u  # Timer counter enable
  TimerTcmr*        = 0x88'u  # Timer counter mode
  TimerTilr2*       = 0x90'u  # Timer2 interrupt level
  TimerTilr3*       = 0x94'u  # Timer3 interrupt level
  TimerWcr*         = 0x98'u  # Watchdog control
  TimerWfar*        = 0x9C'u  # Watchdog feed access
  TimerWsar*        = 0xA0'u  # Watchdog starve access
  TimerTcvwr2*      = 0xA8'u  # Timer2 counter value read
  TimerTcvwr3*      = 0xAC'u  # Timer3 counter value read
  TimerTcdr*        = 0xBC'u  # Timer clock divider

# =============================================================================
# Timer clock control (TCCR) fields
# =============================================================================
const
  TccrClk2SrcShift* = 2    # Timer2 clock source [3:2]
  TccrClk2SrcMask*  = 0x03'u32 shl 2
  TccrClk3SrcShift* = 5    # Timer3 clock source [6:5]
  TccrClk3SrcMask*  = 0x03'u32 shl 5

# =============================================================================
# Timer counter enable (TCER) fields
# =============================================================================
const
  TcerTimer2En*     = 1    # Timer2 counter enable
  TcerTimer3En*     = 2    # Timer3 counter enable

# =============================================================================
# Types
# =============================================================================
type
  TimerId* = enum
    timer0  # MCU subsystem
    timer1  # MM subsystem

  TimerChannel* = enum
    timerCh2
    timerCh3

  TimerClkSrc* = enum
    timerClkFclk   = 0   # System clock
    timerClk32k    = 1   # 32 KHz
    timerClk1k     = 2   # 1 KHz (from 32K divider)
    timerClkXtal   = 3   # Crystal clock

  TimerCountMode* = enum
    timerPreload   = 0   # Preload mode (auto-reload)
    timerFreeRun   = 1   # Free-running mode

  Timer* = object
    base: uint
    id: TimerId

# =============================================================================
# Timer base address
# =============================================================================
proc timerBase(id: TimerId): uint =
  case id
  of timer0: Timer0Base
  of timer1: Timer1Base

# =============================================================================
# Initialization
# =============================================================================
proc initTimer*(id: TimerId): Timer =
  result.base = timerBase(id)
  result.id = id

# =============================================================================
# Channel configuration
# =============================================================================
proc setClockSource*(timer: Timer, ch: TimerChannel, src: TimerClkSrc) =
  case ch
  of timerCh2:
    regModify(timer.base + TimerTccr, TccrClk2SrcMask, src.uint32 shl TccrClk2SrcShift)
  of timerCh3:
    regModify(timer.base + TimerTccr, TccrClk3SrcMask, src.uint32 shl TccrClk3SrcShift)

proc setClockDiv*(timer: Timer, ch: TimerChannel, divider: uint32) =
  ## Set clock divider for a channel (0-255, actual divider = value + 1).
  ## Timer2 divider is at bits [7:0], Timer3 at bits [15:8].
  case ch
  of timerCh2:
    regModify(timer.base + TimerTcdr, 0xFF'u32, divider and 0xFF)
  of timerCh3:
    regModify(timer.base + TimerTcdr, 0xFF'u32 shl 8, (divider and 0xFF) shl 8)

proc setCountMode*(timer: Timer, ch: TimerChannel, mode: TimerCountMode) =
  let bit = case ch
    of timerCh2: 1'u32
    of timerCh3: 2'u32
  if mode == timerFreeRun:
    regSet(timer.base + TimerTcmr, bit)
  else:
    regClear(timer.base + TimerTcmr, bit)

proc setPreloadValue*(timer: Timer, ch: TimerChannel, value: uint32) =
  case ch
  of timerCh2: regWrite(timer.base + TimerTplvr2, value)
  of timerCh3: regWrite(timer.base + TimerTplvr3, value)

proc setMatchValue*(timer: Timer, ch: TimerChannel, matchIdx: range[0..2], value: uint32) =
  ## Set one of the three match compare values for a channel.
  let offset = case ch
    of timerCh2: TimerTmr2_0 + matchIdx.uint * 4
    of timerCh3: TimerTmr3_0 + matchIdx.uint * 4
  regWrite(timer.base + offset, value)

# =============================================================================
# Channel control
# =============================================================================
proc enable*(timer: Timer, ch: TimerChannel) =
  let bit = case ch
    of timerCh2: TcerTimer2En
    of timerCh3: TcerTimer3En
  regSet(timer.base + TimerTcer, 1'u32 shl bit)

proc disable*(timer: Timer, ch: TimerChannel) =
  let bit = case ch
    of timerCh2: TcerTimer2En
    of timerCh3: TcerTimer3En
  regClear(timer.base + TimerTcer, 1'u32 shl bit)

proc readCounter*(timer: Timer, ch: TimerChannel): uint32 =
  case ch
  of timerCh2: regRead(timer.base + TimerTcvwr2)
  of timerCh3: regRead(timer.base + TimerTcvwr3)

# =============================================================================
# Interrupts
# =============================================================================
proc enableInterrupt*(timer: Timer, ch: TimerChannel, matchIdx: range[0..2]) =
  let offset = case ch
    of timerCh2: TimerTier2
    of timerCh3: TimerTier3
  regSet(timer.base + offset, 1'u32 shl matchIdx.uint32)

proc disableInterrupt*(timer: Timer, ch: TimerChannel, matchIdx: range[0..2]) =
  let offset = case ch
    of timerCh2: TimerTier2
    of timerCh3: TimerTier3
  regClear(timer.base + offset, 1'u32 shl matchIdx.uint32)

proc clearInterrupt*(timer: Timer, ch: TimerChannel, matchIdx: range[0..2]) =
  let offset = case ch
    of timerCh2: TimerTicr2
    of timerCh3: TimerTicr3
  regWrite(timer.base + offset, 1'u32 shl matchIdx.uint32)

proc readStatus*(timer: Timer, ch: TimerChannel): uint32 =
  case ch
  of timerCh2: regRead(timer.base + TimerTsr2)
  of timerCh3: regRead(timer.base + TimerTsr3)

# =============================================================================
# Simple periodic timer setup
# =============================================================================
proc setupPeriodic*(timer: Timer, ch: TimerChannel, periodTicks: uint32,
                    clkSrc: TimerClkSrc = timerClkFclk) =
  ## Configure a channel for periodic interrupt at the given tick count.
  ## Fires on match compare 0.
  timer.disable(ch)
  timer.setClockSource(ch, clkSrc)
  timer.setCountMode(ch, timerPreload)
  timer.setPreloadValue(ch, 0)
  timer.setMatchValue(ch, 0, periodTicks)
  timer.setMatchValue(ch, 1, 0xFFFF_FFFF'u32)  # Unused
  timer.setMatchValue(ch, 2, 0xFFFF_FFFF'u32)  # Unused
  timer.clearInterrupt(ch, 0)
  timer.enableInterrupt(ch, 0)
  timer.enable(ch)

# =============================================================================
# Watchdog
# =============================================================================
const
  WmerWdtEn*   = 0    # Watchdog enable bit in WMER
  WmerWdtRst*  = 1    # Watchdog reset enable (1 = reset on timeout)

proc wdtEnable*(timer: Timer, matchValue: uint32, resetOnTimeout: bool = true) =
  ## Enable the watchdog timer with the given timeout value.
  regWrite(timer.base + TimerWmr, matchValue)
  var wmer = 1'u32 shl WmerWdtEn
  if resetOnTimeout:
    wmer = wmer or (1'u32 shl WmerWdtRst)
  regWrite(timer.base + TimerWmer, wmer)

proc wdtDisable*(timer: Timer) =
  regClear(timer.base + TimerWmer, 1'u32 shl WmerWdtEn)

proc wdtFeed*(timer: Timer) =
  ## Feed (kick) the watchdog to prevent timeout.
  ## Must write magic sequences to WFAR then WSAR.
  regWrite(timer.base + TimerWfar, 0xBABA_0000'u32)
  regWrite(timer.base + TimerWsar, 0x5A5A_0000'u32)

proc wdtReadCounter*(timer: Timer): uint32 =
  regRead(timer.base + TimerWvr)

proc wdtClearInterrupt*(timer: Timer) =
  regWrite(timer.base + TimerWicr, 1'u32)
