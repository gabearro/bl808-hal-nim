"""Run the BL808 scheduler loop with a ready queue that keeps refilling."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type StopScheduler = object of CatchableError
var trace: seq[string]
var tick: uint64
var timerPending, allowSleep: bool
var interruptEnables: int
var interruptsDisabled: bool
template withInterruptsDisabled(body: untyped) =
  block:
    let saved = interruptsDisabled
    interruptsDisabled = true
    try:
      body
    finally:
      interruptsDisabled = saved
proc enableInterrupts() = inc interruptEnables
proc drainIsrCompletions() = discard
proc isrBridgePendingCompletions(): int = 0
proc readTick(): uint64 = tick
proc reprogramNextDeadline(s: Scheduler) = discard
proc runPriorityCallback(s: var Scheduler; earlyOnly: static bool)
proc fireExpiredTimers(s: var Scheduler) =
  if timerPending and tick >= 1:
    timerPending = false
    trace.add("timer")
    s.priorityRan = false
    s.runPriorityCallback(earlyOnly = true)
proc faultCheckStackGuard(): bool = true
const FaultReasonStackGuard = 0
proc faultHalt(reason: int; a, b, c: uint) = doAssert false
var timerIsrFired = false
proc wfi() =
  # The final ready check and WFI must share one masked interval. Otherwise
  # a timer can fire and clear its compare between them, then WFI can sleep.
  doAssert interruptsDisabled and allowSleep and scheduler.ready.len == 0
  raise newException(StopScheduler, "idle")
'''

CHECKS = r'''
proc runUntilStopped() =
  try:
    runScheduler()
  except StopScheduler:
    discard

var runs = 0
proc yieldingTask() =
  trace.add("ready")
  inc runs
  if runs < 3: post(yieldingTask)

timerPending = true
post(yieldingTask)
post(proc() =
  trace.add("peer")
  postFromIsr(proc() = trace.add("isr")))

addSchedulerPollHook(proc() =
  trace.add("poll")
  inc tick
  if tick == 1: post(proc() = trace.add("hook post"))
  if tick == 3: raise newException(StopScheduler, "sampled three batches"))
doAssert addSchedulerTimedPollHook(proc(now: uint64): uint64 =
  trace.add("timed poll")
  return 0, 1)
runUntilStopped()
doAssert trace == @["ready", "peer", "poll", "timed poll", "timer",
                    "ready", "isr", "hook post", "poll", "ready", "poll"]
doAssert scheduler.totalCallbacks == 6

# Without poll hooks, a continuation in the next batch still prevents WFI.
scheduler = default(Scheduler)
schedulerPollHooks = @[]
schedulerTimedPollHookCount = 0
allowSleep = true
trace.setLen(0)
post(proc() =
  trace.add("first")
  post(proc() = trace.add("second")))
runUntilStopped()
doAssert scheduler.totalTicks == 2 and trace == @["first", "second"]

# A resident app returns to its host between batches, without WFI/IRQ changes.
scheduler = default(Scheduler)
allowSleep = false
interruptEnables = 0
trace.setLen(0)
tick = 0
timerPending = true
post(proc() =
  trace.add("first")
  post(proc() = trace.add("second")))
addSchedulerPollHook(proc() =
  trace.add("poll")
  inc tick)
pollScheduler()
doAssert trace == @["first", "poll", "timer"] and scheduler.ready.len == 1
pollScheduler()
doAssert trace == @["first", "poll", "timer", "second", "poll"]
doAssert scheduler.totalTicks == 2 and interruptEnables == 0

# Priority work posted by a callback can run before the next ready callback.
# A repeat post coalesces, and a self-repost leaves room for ordinary work.
scheduler = default(Scheduler)
schedulerPollHooks = @[]
trace.setLen(0)
var priorityRuns = 0
proc eligible(): bool = true
proc other() = doAssert false
proc priority() =
  doAssert not interruptsDisabled
  trace.add("priority")
  inc priorityRuns
  if priorityRuns < 3:
    withInterruptsDisabled:
      doAssert tryPostPriorityFromIsr(priority, eligible)
post(proc() =
  trace.add("first")
  withInterruptsDisabled:
    doAssert tryPostPriorityFromIsr(priority, eligible)
    doAssert tryPostPriorityFromIsr(priority, eligible)
    doAssert not tryPostPriorityFromIsr(other, eligible))
post(proc() = trace.add("second"))
pollScheduler()
doAssert trace == @["first", "priority", "second", "priority"]
doAssert scheduler.priorityCallback != nil and scheduler.totalCallbacks == 4
allowSleep = true
runUntilStopped()
doAssert trace == @["first", "priority", "second", "priority", "priority"]
doAssert scheduler.totalCallbacks == 5

# The priority slot alone must keep the core awake across a self-repost.
scheduler = default(Scheduler)
trace.setLen(0)
priorityRuns = 1
withInterruptsDisabled:
  doAssert tryPostPriorityFromIsr(priority, eligible)
runUntilStopped()
doAssert trace == @["priority", "priority"] and scheduler.totalTicks == 2

# A wake that is not urgent runs after the ready batch, even with no timer.
trace.setLen(0)
proc regular() = trace.add("regular")
post(proc() = trace.add("ready"))
withInterruptsDisabled:
  doAssert tryPostPriorityFromIsr(regular, nil)
pollScheduler()
doAssert trace == @["ready", "regular"]
'''


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_scheduler_ready_batches_preserve_hook_and_timer_progress(tmp_path: Path, mode: str) -> None:
    sched = (ROOT / "src/bl808/kernel/sched.nim").read_text()
    code = sched[sched.index("const\n"):sched.index("# ===", sched.index("proc addSchedulerTimedPollHook*"))]
    code += PLATFORM
    for name in ("post", "tryPostFromIsr", "postFromIsr", "tryPostPriorityFromIsr",
                 "drainIsrPending", "runPriorityCallback", "runReadyCallbacks",
                 "runPollHooks", "runTimedPollHooks", "hasUntimedPollHooks",
                 "hasDueTimedPollHooks", "runSchedulerIteration", "pollScheduler",
                 "runScheduler"):
        code += procedure(sched, name).split("\n# ===", 1)[0] + "\n"
    run_program(tmp_path, mode, code + CHECKS)
