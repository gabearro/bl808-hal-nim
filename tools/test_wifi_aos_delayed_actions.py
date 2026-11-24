"""Exercise poll-driven AOS delayed actions in the Nim WiFi adapter."""

from pathlib import Path

import pytest

from test_wifi_adapter_waits import SUPPORT
from test_wifi_aos_events import source
from test_wifi_message_allocation import run_program


CASES = {
    "negative_delay_precedes_zero": r'''
var seen: seq[int]
proc action(arg: pointer) {.cdecl.} = seen.add(cast[ptr int](arg)[])
var zero = 0
var minusOne = 1
var minusFive = 5
doAssert aos_post_delayed_action(0, cast[pointer](action), addr zero) == 0
doAssert aos_post_delayed_action(-1, cast[pointer](action), addr minusOne) == 0
doAssert aos_post_delayed_action(-5, cast[pointer](action), addr minusFive) == 0
aosPollDelayedActions()
doAssert seen == @[5, 1, 0]
''',
    "deadline_and_fifo_order": r'''
var seen: seq[int]
proc action(arg: pointer) {.cdecl.} = seen.add(cast[ptr int](arg)[])
var first = 1
var second = 2
var third = 3
doAssert aos_post_delayed_action(10, cast[pointer](action), addr first) == 0
doAssert aos_post_delayed_action(5, cast[pointer](action), addr second) == 0
doAssert aos_post_delayed_action(5, cast[pointer](action), addr third) == 0
clock = 4000
aosPollDelayedActions()
doAssert seen.len == 0
clock = 5000
aosPollDelayedActions()
doAssert seen == @[2, 3]
clock = 10_000
aosPollDelayedActions()
doAssert seen == @[2, 3, 1]
''',
    "cancel_only_first_match": r'''
var calls = 0
proc action(arg: pointer) {.cdecl.} = inc calls
let fn = cast[pointer](action)
doAssert aos_post_delayed_action(5, fn, nil) == 0
doAssert aos_post_delayed_action(5, fn, nil) == 0
aos_cancel_delayed_action(5, fn, nil)
doAssert aosDelayedCount == 1
clock = 5000
aosPollDelayedActions()
doAssert calls == 1
doAssert aos_post_delayed_action(10, fn, nil) == 0
doAssert aos_post_delayed_action(20, fn, nil) == 0
aos_cancel_delayed_action(-1, fn, nil)
doAssert aosDelayedCount == 1
clock = 25_000
aosPollDelayedActions()
doAssert calls == 2
''',
    "nested_poll_is_serial": r'''
var calls: seq[int]
proc second(arg: pointer) {.cdecl.} = calls.add(2)
proc first(arg: pointer) {.cdecl.} =
  calls.add(1)
  doAssert aos_post_delayed_action(0, cast[pointer](second), nil) == 0
  aosPollDelayedActions()
  doAssert calls == @[1]
doAssert aos_post_delayed_action(0, cast[pointer](first), nil) == 0
aosPollDelayedActions()
doAssert calls == @[1, 2]
''',
    "masked_and_clock_failure": r'''
var calls = 0
proc action(arg: pointer) {.cdecl.} =
  doAssert interrupts
  inc calls
clockAvailable = false
doAssert aos_post_delayed_action(1, cast[pointer](action), nil) == -5
clockAvailable = true
doAssert aos_post_delayed_action(1, cast[pointer](action), nil) == 0
clock = 1000
interrupts = false
aosPollDelayedActions()
doAssert calls == 0 and aosDelayedCount == 1
interrupts = true
clockAvailable = false
aosPollDelayedActions()
doAssert calls == 0
clockAvailable = true
aosPollDelayedActions()
doAssert calls == 1
doAssert aos_post_delayed_action(0, nil, nil) == -22
''',
    "capacity_and_budget": r'''
var calls = 0
proc action(arg: pointer) {.cdecl.} = inc calls
for i in 0 ..< AosDelayedActionCapacity:
  doAssert aos_post_delayed_action(0, cast[pointer](action), nil) == 0
doAssert aos_post_delayed_action(0, cast[pointer](action), nil) == -12
aosPollDelayedActions()
doAssert calls == 16 and aosDelayedCount == 16
aosPollDelayedActions()
doAssert calls == AosDelayedActionCapacity and aosDelayedCount == 0
''',
    "callback_cancels_pending_action": r'''
var calls: seq[int]
proc canceled(arg: pointer) {.cdecl.} = calls.add(2)
proc first(arg: pointer) {.cdecl.} =
  calls.add(1)
  aos_cancel_delayed_action(-1, cast[pointer](canceled), nil)
doAssert aos_post_delayed_action(0, cast[pointer](first), nil) == 0
doAssert aos_post_delayed_action(0, cast[pointer](canceled), nil) == 0
aosPollDelayedActions()
doAssert calls == @[1]
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_delayed_action(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case] + r'''
doAssert aosDelayedCount == 0 and not aosDelayedDispatching
doAssert aosEventCount == 0 and not aosDispatching
doAssert live.len == 0 and interrupts and saves == restores
''')


def test_backend_polls_delayed_actions() -> None:
    assert "aosPollDelayedActions()" in (
        SUPPORT / "backend_runtime_parts/poll.nim"
    ).read_text()
