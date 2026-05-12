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
  # Use 1kHz clock so match value is directly in milliseconds
  setWdtClockSource(wdtTimer, wdtClk1k)
  setWdtClockDiv(wdtTimer, 0)
  wdtEnable(wdtTimer, timeoutMs, resetOnTimeout = true)
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
