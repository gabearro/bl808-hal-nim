"""Model admission, retry pacing, and fair drain of an accepted peer cleanup."""

from itertools import product
import os
from pathlib import Path
import random

import pytest

from test_wifi_connect_admission import cleanup_pump_source
from test_wifi_message_allocation import run_program


DRIVER = r'''
const RetryUs = 100_000'u64
type Phase = enum queued, waiting, done

proc exercise(trace: string; wrap: bool): string =
  setup()
  let before = (attempts: deleteAttempts, confirmations: deleteConfirmations,
                notifications: notifications.len, removals: removed.len)
  let start = if wrap: high(uint32) - 42 else: 1000'u32
  var elapsed, due: uint64
  var phase = queued
  var attempts = 0
  retryNow = start
  hostConnected = true
  failDeletion = true
  indicationHook = proc() = hostConnected = false
  sm_disconnect_process(addr vifs[0], 7, 7)
  defer:
    # Each replay starts from a clean fixture, even when the pump is mutated.
    failDeletion = false
    if retryArmed: retryNow = mmStaDelRetryTimer.expiry
    for _ in 0 ..< 16: discard wifiDrainScheduledWork()
    doAssert smOwn.teardown == tdNone and allocated.len == 0

  proc observe(): string =
    if deleteAttempts - before.attempts != attempts: return "hardware-attempt-count"
    if hostConnected or notifications.len - before.notifications != 1 or
        notifications[^1].status != 7 or notifications[^1].reason != 7:
      return "disconnect-notification"
    if (smState == SmIdleState) != (phase == done) or
        (smOwn.teardown == tdCleanup) != (phase != done):
      return "cleanup-owner"
    if deleteConfirmations - before.confirmations != (phase == done).int or
        removed.len - before.removals != (phase == done).int:
      return "terminal-count"
    if retryArmed != (phase == waiting): return "retry-armed"
    if retryArmed and mmStaDelRetryTimer.expiry != start + due.uint32:
      return "retry-deadline"
    if phase == done and (allocated.len != 0 or keMsgQueueSaved.first != nil):
      return "retired-work"
    if not interruptsEnabled: return "irq-state"

  # A fair suffix recovers the hardware, advances past the retry deadline,
  # and gives the firmware service with no public waiter.
  for action in trace & "rep":
    case action
    of 'b': failDeletion = true
    of 'r': failDeletion = false
    of 'd': elapsed += RetryUs - 1
    of 'e': elapsed += RetryUs
    of 't': inc elapsed
    of 'w': discard ke_reschedule_saved_messages(TASK_MM)
    of 'p':
      if phase == queued or (phase == waiting and elapsed >= due):
        inc attempts
        if failDeletion:
          phase = waiting
          due = elapsed + RetryUs
        else:
          phase = done
      wifiServicePump(16)
    else: doAssert false
    retryNow = start + elapsed.uint32
    let failure = observe()
    if failure != "": return failure
  if phase != done: return "fair-delivery-stalled"

proc check(trace: string; wrap: bool) =
  let issue = exercise(trace, wrap)
  if issue == "": return
  var minimal = trace
  var i = 0
  while i < minimal.len:
    let candidate = minimal[0 ..< i] & minimal[i + 1 .. ^1]
    if exercise(candidate, wrap) == issue: minimal = candidate
    else: inc i
  doAssert false, issue & " wrap=" & $wrap & " trace=" & trace & " minimized=" & minimal
'''


def source() -> str:
    fixture = cleanup_pump_source()
    assert fixture.count("\nsetup()\n") == 1
    return fixture.replace("\nsetup()\n", "\n", 1) + DRIVER


def test_cleanup_retry_schedules(tmp_path: Path) -> None:
    seed = int(os.environ.get("BL808_WIFI_MODEL_SEED", "808"))
    steps = int(os.environ.get("BL808_WIFI_MODEL_STEPS", "256"))
    rng = random.Random(seed)
    actions = "brdetwp"
    short = ["p" + "".join(events) for events in product(actions, repeat=3)]
    long = ["p" + "".join(rng.choices(alphabet, k=steps))
            for alphabet in (actions.replace("r", ""), actions)]
    cases = ["", "pwp", "pedptp", *long, *short]
    calls = "\n".join(f'check("{trace}", {str(i % 2 == 0).lower()})'
                      for i, trace in enumerate(cases))
    try:
        run_program(tmp_path, "checked", source() + calls)
    except AssertionError as exc:
        raise AssertionError(f"seed={seed} steps={steps}\n{exc}") from exc


@pytest.mark.parametrize("mutation,trace,issue", [
    ("ignore-backoff", "pwp", "hardware-attempt-count"),
    ("stop-at-link-down", "p", "hardware-attempt-count"),
])
def test_cleanup_model_detects_original_failures(tmp_path: Path, mutation: str,
                                               trace: str, issue: str) -> None:
    code = source()
    before, after = {
        "ignore-backoff": ("mmStaDelRetryPending(staIdx) or not mmStaDelTry",
                           "not mmStaDelTry"),
        "stop-at-link-down": ("not hasPending and sm_state != SmDisconnectingState and",
                              "not hasPending and"),
    }[mutation]
    assert code.count(before) == 1
    code = code.replace(before, after, 1)
    run_program(tmp_path, "checked", code +
                f'\ndoAssert exercise("{trace}", true) == "{issue}"\n')
