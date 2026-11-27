"""Exercise actual scheduler timer capacity and WiFi timeout cancellation."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT, procedure

SCHED = ROOT / "src/bl808/kernel/sched.nim"
FACADE = ROOT / "src/bl808/wifi/facade_parts"


def source() -> str:
    scheduler = SCHED.read_text()
    code = f'import "{ROOT / "src/bl808/kernel/runtime"}"\n'
    code += scheduler[scheduler.index("const\n"):scheduler.index("proc setSchedulerPollHook*")]
    code += scheduler[scheduler.index("var\n  timerIsrFired*"):scheduler.index("proc timerIsrHandler")]
    code += r'''
var now, hardwareDeadline: uint64
var fired: seq[int]
var interruptsDisabled: bool
template withInterruptsDisabled(body: untyped) =
  block:
    let saved = interruptsDisabled
    interruptsDisabled = true
    try:
      body
    finally:
      interruptsDisabled = saved
const FaultReasonManual = 0
proc readTick(): uint64 = now
proc setDeadline(deadline: uint64) = hardwareDeadline = deadline
proc clearDeadline() = hardwareDeadline = 0
proc deadlineFromNowMs(ms: uint64): uint64 = now + ms * 1000
proc deadlineFromNow(us: uint64): uint64 = now + us
proc faultHalt(reason: int; tag, count, value: uint) {.noreturn.} =
  raise newException(ValueError, "timer pool exhausted")
'''
    for name in ["heapLen", "allocTimerEntry", "releaseTimerEntry", "heapPush",
                 "heapRemove", "heapPop", "heapPeekDeadline", "reprogramNextDeadline",
                 "addTimer", "addTimerMs", "addTimerUs", "cancelTimer",
                 "tryPostPriorityFromIsr", "runPriorityCallback", "fireExpiredTimers"]:
        if name == "heapRemove" and "proc heapRemove(" not in scheduler:
            continue
        text = scheduler
        if name == "reprogramNextDeadline":
            text = scheduler[scheduler.rindex("proc reprogramNextDeadline("):]
        code += procedure(text, name).split("\n# =====", 1)[0] + "\n"
    code += r'''
type WifiError = enum wifiOk, wifiFail
type WifiScanStage = enum wifiScanUnavailable, wifiScanPending, wifiScanTimedOut
var
  wifiScanFuture: CpsFuture[uint32]
  wifiConnectFuture, wifiStaIdleFuture, wifiDisconnectFuture: CpsFuture[WifiError]
  wifiScanTimer, wifiConnectTimer, wifiStaIdleTimer, wifiDisconnectTimer: TimerId
  wifiDisconnectIssuePending: bool
  wifiDisconnectIssueTimeoutMs: uint32
proc wifiBackendUsesEventFutures(): bool = true
proc wifiBackendConnected(): bool = false
proc wifiCompletePendingEvents() = discard
proc noteWifiScan(stage: WifiScanStage; count: uint32) = discard
proc bl808_wifi_backend_signal_work() = discard
'''
    code += (FACADE / "service_futures_parts/completions.nim").read_text()
    code += (FACADE / "service_futures_parts/waits.nim").read_text()
    return code + r'''
proc usedCount(): int =
  for used in timerPoolUsed:
    if used: inc result
proc assertHeap() =
  doAssert scheduler.timers.len == usedCount()
  for i, entry in scheduler.timers:
    doAssert entry != nil and entry.id != 0 and entry.callback != nil
    if i > 0: doAssert scheduler.timers[(i - 1) div 2].deadline <= entry.deadline
    for j in 0 ..< i: doAssert scheduler.timers[j] != entry
proc reset() =
  scheduler = default(Scheduler)
  for i in 0 ..< MaxSchedulerTimers:
    timerPool[i] = default(TimerEntryObj)
    timerPoolUsed[i] = false
  scheduler.nextTimerId = 1
  schedulerTimedPollHookCount = 0
  now = 0
  hardwareDeadline = 0
  timerIsrFired = false
  firedTimerDeadline = 0
  fired.setLen(0)
  wifiScanFuture = nil
  wifiConnectFuture = nil
  wifiScanTimer = 0
  wifiConnectTimer = 0
proc schedule(deadline: uint64; value: int): TimerId =
  addTimer(deadline, proc() = fired.add(value))
'''


CASES = {
    "wifi_churn": r'''
reset()
for i in 0 ..< MaxSchedulerTimers * 4:
  let scan = wifiBeginScanWait(30_000)
  doAssert not scan.finished
  completeWifiScan(i.uint32)
  doAssert scan.finished and scan.read() == i.uint32
  let join = wifiBeginConnectWait(30_000)
  completeWifiConnect(wifiOk)
  doAssert join.finished and join.read() == wifiOk
doAssert usedCount() == 0 and scheduler.timers.len == 0
doAssert hardwareDeadline == 0
''',
    "cancel_every_slot": r'''
for removed in 0 ..< MaxSchedulerTimers:
  reset()
  var ids: array[MaxSchedulerTimers, TimerId]
  for i in 0 ..< MaxSchedulerTimers:
    ids[i] = schedule((MaxSchedulerTimers - i).uint64, i)
  assertHeap()
  cancelTimer(ids[removed])
  doAssert usedCount() == MaxSchedulerTimers - 1
  assertHeap()
  discard schedule(100, 100)
  assertHeap()
  now = 200
  fireExpiredTimers(scheduler)
  doAssert fired.len == MaxSchedulerTimers and removed notin fired
  for i in 1 ..< fired.len - 1: doAssert fired[i - 1] > fired[i]
  doAssert fired[^1] == 100 and usedCount() == 0
''',
    "wake_deadlines": r'''
reset()
let late = schedule(300, 3)
let early = schedule(100, 1)
let middle = schedule(200, 2)
doAssert hardwareDeadline == 100
cancelTimer(early)
doAssert hardwareDeadline == 200
cancelTimer(middle)
doAssert hardwareDeadline == 300
cancelTimer(late)
doAssert hardwareDeadline == 0
cancelTimer(0)
cancelTimer(late)
doAssert usedCount() == 0
schedulerTimedPollHookCount = 1
schedulerTimedPollHooks[0].hook = proc(tick: uint64): uint64 = tick + 100
schedulerTimedPollHooks[0].deadline = 150
let timer = schedule(100, 1)
cancelTimer(timer)
doAssert hardwareDeadline == 150, "cancellation dropped a timed service wakeup"
''',
    "callback_cancellation": r'''
reset()
var later: TimerId
discard addTimer(100, proc() =
  fired.add(1)
  cancelTimer(later)
  discard schedule(100, 3))
later = schedule(100, 2)
now = 100
fireExpiredTimers(scheduler)
doAssert fired == @[1, 3] and usedCount() == 0
reset()
var self: TimerId
self = addTimer(10, proc() =
  cancelTimer(self)
  fired.add(1))
now = 10
fireExpiredTimers(scheduler)
doAssert fired == @[1] and usedCount() == 0
''',
    "priority_between_timers": r'''
reset()
proc ready(): bool = true
proc priority() =
  doAssert not interruptsDisabled
  fired.add(2)
discard addTimer(5, proc() =
  fired.add(1)
  withInterruptsDisabled:
    doAssert tryPostPriorityFromIsr(priority, ready))
discard schedule(6, 3)
now = 6
fireExpiredTimers(scheduler)
doAssert fired == @[1, 2, 3] and usedCount() == 0
''',
    "mixed_deadlines": r'''
for seed in 1 .. 30:
  reset()
  var ids: array[MaxSchedulerTimers, TimerId]
  var deadlines: array[MaxSchedulerTimers, uint64]
  for i in 0 ..< ids.len:
    deadlines[i] = ((i * 17 + seed * 11) mod 101 + 1).uint64
    ids[i] = schedule(deadlines[i], i)
  for i in 0 ..< ids.len:
    if (i + seed) mod 3 == 0:
      cancelTimer(ids[i])
      assertHeap()
  for tick in 0'u64 .. 102:
    now = tick
    fireExpiredTimers(scheduler)
    assertHeap()
  for i in 0 ..< ids.len:
    doAssert (i in fired) == ((i + seed) mod 3 != 0)
  for i in 1 ..< fired.len:
    doAssert deadlines[fired[i - 1]] <= deadlines[fired[i]]
  doAssert usedCount() == 0
''',
    "closure_cleanup_reentry": r'''
reset()
var cleaned: int
type CleanupToken = object
  armed: bool
proc `=destroy`(token: var CleanupToken) =
  if token.armed:
    token.armed = false
    inc cleaned
    doAssert usedCount() == MaxSchedulerTimers - 1
    discard schedule(5, 999)
proc callbackWithCleanup(): proc() =
  let token = new CleanupToken
  token.armed = true
  result = proc() = doAssert token.armed
proc scheduleCleanup(): TimerId = addTimer(1, callbackWithCleanup())
let removed = scheduleCleanup()
for i in 1 ..< MaxSchedulerTimers:
  discard schedule(100, i)
cancelTimer(removed)
doAssert cleaned == 1 and usedCount() == MaxSchedulerTimers
assertHeap()
doAssert hardwareDeadline == 5
now = 100
fireExpiredTimers(scheduler)
doAssert fired.len == MaxSchedulerTimers and fired[0] == 999
doAssert cleaned == 1 and usedCount() == 0
''',
    "full_pool_reschedule": r'''
reset()
discard addTimer(1, proc() =
  fired.add(0)
  discard schedule(2, 999))
for i in 1 ..< MaxSchedulerTimers:
  discard schedule(100, i)
now = 1
fireExpiredTimers(scheduler)
assertHeap()
doAssert fired == @[0] and usedCount() == MaxSchedulerTimers
now = 2
fireExpiredTimers(scheduler)
doAssert fired == @[0, 999]
now = 100
fireExpiredTimers(scheduler)
doAssert fired.len == MaxSchedulerTimers + 1 and usedCount() == 0
''',
    "active_limit": r'''
reset()
var first: TimerId
for i in 0 ..< MaxSchedulerTimers:
  let id = schedule(100, i)
  if i == 0: first = id
var exhausted = false
try:
  discard schedule(200, 99)
except ValueError:
  exhausted = true
doAssert exhausted and usedCount() == MaxSchedulerTimers
assertHeap()
cancelTimer(first)
discard schedule(200, 99)
assertHeap()
now = 200
fireExpiredTimers(scheduler)
doAssert fired.len == MaxSchedulerTimers and 0 notin fired and 99 in fired
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_timer_capacity(tmp_path: Path, mode: str, case: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "timer_capacity.nim"
    path.write_text(source() + CASES[case])
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run(
        [nim, "c", "-r", "--mm:arc", "--skipParentCfg:on", "--skipProjCfg:on",
         "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}",
         f"-o:{tmp_path / 'test'}", *flags[mode], str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout
