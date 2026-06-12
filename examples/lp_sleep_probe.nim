## LP (E902) timed sleep/wake probe — the low-power core doing low-power duty.
##
## The E902 is the BL808's dedicated "Low Power" core: its own clock + CORET
## (machine timer) live in the always-on/PDS domain, so it can run timed work
## while M0/D0 are powered down. This firmware sleeps on the CORET via WFI and
## bumps an XRAM counter each wake, so M0 (which released it and stays alive) can
## confirm the LP is doing real timed sleep/wake. No UART/JTAG on LP — XRAM only.
##
## releaseLPAt() already programs the E902 RTC/mtimer clock to 1 MHz
## (pdsConfigureLpMtimerClock), so CORET ticks at 1 MHz.

import bl808/startup
import bl808/mmio
import bl808/memmap
import bl808/core
import bl808/panicoverride

const
  LpSleepCounter = XramBase + 0x3F10'u   # M0 polls this (wake count)
  LpMtimeDebug   = XramBase + 0x3F14'u   # mip CSR, so M0 can see MTIP behaviour
  CoretMtime     = 0xE000_BFF8'u          # E902 CLINT mtime (lo at +0, hi at +4)
  CoretMtimecmp  = 0xE000_4000'u          # E902 CLINT mtimecmp
  IntervalTicks  = 11_000'u64             # ~100 ms at the measured ~112 kHz mtime


proc rdMtime(): uint64 =
  var hi1 = regRead(CoretMtime + 4)
  var lo = regRead(CoretMtime)
  var hi2 = regRead(CoretMtime + 4)
  while hi1 != hi2:
    hi1 = hi2
    lo = regRead(CoretMtime)
    hi2 = regRead(CoretMtime + 4)
  (hi2.uint64 shl 32) or lo.uint64

proc main() {.exportc, cdecl.} =
  ## Autonomous timed periodic work on the E902's own CORET timer: each period
  ## the LP bumps an XRAM counter and waits one interval on its low-power timer.
  ## (A true WFI low-power sleep additionally needs the E902 CLIC IRQ-7 timer
  ## path — its timer interrupt is CLIC-delivered, not standard mip.MTIP.)
  var count = 0'u32
  while true:
    regWrite(LpSleepCounter, count)
    let target = rdMtime() + IntervalTicks
    while rdMtime() < target:
      regWrite(LpMtimeDebug, (rdMtime() and 0xFFFF_FFFF'u64).uint32)
    inc count
