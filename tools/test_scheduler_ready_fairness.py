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
template withInterruptsDisabled(body: untyped) = body
proc enableInterrupts() = inc interruptEnables
proc drainIsrCompletions() = discard
proc isrBridgePendingCompletions(): int = 0
proc readTick(): uint64 = tick
proc reprogramNextDeadline(s: Scheduler) = discard
proc fireExpiredTimers(s: var Scheduler) =
  if timerPending and tick >= 1:
    timerPending = false
    trace.add("timer")
proc faultCheckStackGuard(): bool = true
const FaultReasonStackGuard = 0
proc faultHalt(reason: int; a, b, c: uint) = doAssert false
var timerIsrFired = false
proc wfi() =
  doAssert allowSleep and scheduler.ready.len == 0
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
'''


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_scheduler_ready_batches_preserve_hook_and_timer_progress(tmp_path: Path, mode: str) -> None:
    sched = (ROOT / "src/bl808/kernel/sched.nim").read_text()
    code = sched[sched.index("const\n"):sched.index("# ===", sched.index("proc addSchedulerTimedPollHook*"))]
    code += PLATFORM
    for name in ("post", "postFromIsr", "drainIsrPending", "runReadyCallbacks",
                 "runPollHooks", "runTimedPollHooks", "hasUntimedPollHooks",
                 "hasDueTimedPollHooks", "runSchedulerIteration", "pollScheduler",
                 "runScheduler"):
        code += procedure(sched, name).split("\n# ===", 1)[0] + "\n"
    run_program(tmp_path, mode, code + CHECKS)
