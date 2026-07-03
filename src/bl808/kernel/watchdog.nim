## Hardware watchdog integration for the BL808 kernel.
##
## Kicks the WDT from the scheduler poll hook every iteration.
## If the scheduler stalls (a task loops without yielding), the
## WDT isn't kicked and the hardware resets the system.
##
##   watchdogInit(timer0, timeoutMs = 5000)
##   runScheduler()  # WDT kicked automatically each loop

import ../timer
import ./sched

var
  wdtTimer: Timer
  wdtActive: bool = false
  wdtFeeds: uint64 = 0

proc watchdogInit*(id: timer.TimerId = timer0, timeoutMs: uint32 = 5000) =
  ## Enable the hardware watchdog with the given timeout.
  ## Installs a scheduler poll hook that kicks the WDT every iteration.
  ## Chains with any existing poll hook.
  wdtTimer = initTimer(id)
  # WDT clock source = f32k, the always-on 32 kHz AON oscillator. The previous
  # choice (wdtClk1k = "1K from the 32K divider") is documented in the SDK as
  # "Only for Timer not for Watchdog" and — critically — it shares the clock
  # domain that the WiFi RF/PLL reconnect GATES, which freezes the WDT counter
  # exactly when we need it (JTAG: WVR stuck at 0x4E27 just past match, WdtEn
  # self-cleared, no reset). f32k is the HW default for cs_wdt and is not gated
  # by the WiFi reconnect. /32 -> ~1.024 kHz so the 16-bit match value stays
  # ~1 tick/ms. WMR is 16-bit (max 65535 ticks -> ~64 s), so clamp the timeout.
  setWdtClockSource(wdtTimer, wdtClk32k)
  setWdtClockDiv(wdtTimer, 31)
  wdtEnable(wdtTimer, min(timeoutMs, 60_000'u32), resetOnTimeout = true)
  wdtActive = true

  addSchedulerPollHook(proc() =
    if wdtActive:
      wdtFeed(wdtTimer)
      wdtFeeds.inc
  )

proc watchdogDisable*() =
  ## Disable the watchdog. The poll hook still runs but skips the feed.
  wdtDisable(wdtTimer)
  wdtActive = false

proc watchdogFeedCount*(): uint64 = wdtFeeds
  ## Number of times the WDT has been kicked since init.

proc watchdogCounter*(): uint32 =
  ## Current WDT counter value (0 in QEMU since timer is stubbed).
  if not wdtActive:
    return 0
  wdtReadCounter(wdtTimer)

proc watchdogIsActive*(): bool = wdtActive
  ## Whether the WDT is currently enabled.
