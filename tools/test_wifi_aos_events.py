"""Exercise the Nim WiFi AOS event queue and OS-adapter handoff."""

from pathlib import Path

import pytest

from test_wifi_adapter_waits import SUPPORT, source as adapter_source
from test_wifi_message_allocation import run_program


def source() -> str:
    forward = r'''
proc aos_post_event*(`type`, code: uint16; value: culong): cint {.exportc, cdecl.}
'''
    return adapter_source(event_post=forward) + r'''
proc readMtimeUs(): uint64 = clock
''' + (SUPPORT / "runtime_facade_parts/events.nim").read_text() + r'''
const EventPostSuccess = sizeof(AosInputEvent).cint
'''


CASES = {
    "filter_order_and_urgent": r'''
var seen: seq[int]
proc wifi(event: ptr AosInputEvent; priv: pointer) {.cdecl.} =
  doAssert interrupts and event.time == 0
  doAssert event.eventType == 2 and event.value in [7.culong, 9.culong]
  seen.add(100 + event.code.int)
proc allEvents(event: ptr AosInputEvent; priv: pointer) {.cdecl.} =
  seen.add(200 + event.code.int)
doAssert aos_register_event_filter(2, cast[pointer](wifi), nil) == 0
doAssert aos_register_event_filter(0, cast[pointer](allEvents), nil) == 0
clock = 123_000
doAssert aos_post_event(2, 1, 7) == EventPostSuccess
doAssert aos_post_event(0x8002, 2, 9) == EventPostSuccess
doAssert aos_post_event(3, 3, 11) == EventPostSuccess
aosPollEvents()
doAssert seen == @[102, 202, 101, 201, 203]
''',
    "os_notify_delivers_wifi_event": r'''
var seen = false
proc callback(event: ptr AosInputEvent; priv: pointer) {.cdecl.} =
  doAssert event.eventType == 2 and event.code == 21
  doAssert event.value == 0xFFFF_FFFF.culong
  seen = true
doAssert aos_register_event_filter(2, cast[pointer](callback), nil) == 0
doAssert osEventNotify(21, -1) == EventPostSuccess
doAssert not seen
aosPollEvents()
doAssert seen
''',
    "filter_changes_are_snapshot": r'''
var seen: seq[int]
proc third(event: ptr AosInputEvent; priv: pointer) {.cdecl.} = seen.add(3)
proc first(event: ptr AosInputEvent; priv: pointer) {.cdecl.} =
  seen.add(1)
  doAssert aos_unregister_event_filter(2, cast[pointer](first), nil) == 0
  doAssert aos_register_event_filter(2, cast[pointer](third), nil) == 0
proc second(event: ptr AosInputEvent; priv: pointer) {.cdecl.} = seen.add(2)
doAssert aos_register_event_filter(2, cast[pointer](first), nil) == 0
doAssert aos_register_event_filter(2, cast[pointer](second), nil) == 0
doAssert aos_post_event(2, 1, 0) == EventPostSuccess
doAssert aos_post_event(2, 2, 0) == EventPostSuccess
aosPollEvents()
doAssert seen == @[1, 2, 2, 3]
''',
    "queue_capacity_and_budget": r'''
var seen: seq[int]
proc callback(event: ptr AosInputEvent; priv: pointer) {.cdecl.} =
  seen.add(event.code.int)
doAssert aos_register_event_filter(0, cast[pointer](callback), nil) == 0
for i in 0 ..< AosEventQueueCapacity:
  doAssert aos_post_event(2, i.uint16, 0) == EventPostSuccess
doAssert aos_post_event(2, 99, 0) == -1
aosPollEvents()
doAssert seen.len == 16 and aosEventCount == 48
doAssert aos_post_event(2, 64, 0) == EventPostSuccess
for i in 0 ..< 4:
  aosPollEvents()
doAssert seen.len == 65 and aosEventCount == 0
for i in 0 ..< 65:
  doAssert seen[i] == i
''',
    "nested_and_masked_poll": r'''
var seen: seq[int]
proc callback(event: ptr AosInputEvent; priv: pointer) {.cdecl.} =
  doAssert interrupts
  seen.add(event.code.int)
  if event.code == 1:
    doAssert aos_post_event(2, 2, 0) == EventPostSuccess
    aosPollEvents()
    doAssert seen == @[1]
doAssert aos_register_event_filter(2, cast[pointer](callback), nil) == 0
doAssert aos_post_event(2, 1, 0) == EventPostSuccess
interrupts = false
aosPollEvents()
doAssert seen.len == 0 and aosEventCount == 1
interrupts = true
aosPollEvents()
doAssert seen == @[1, 2]
''',
    "filter_capacity_and_unregistration": r'''
proc callback(event: ptr AosInputEvent; priv: pointer) {.cdecl.} = discard
doAssert aos_register_event_filter(2, nil, nil) == -22
for i in 0 ..< AosEventFilterCapacity:
  doAssert aos_register_event_filter(i.uint16, cast[pointer](callback), nil) == 0
doAssert aos_register_event_filter(2, cast[pointer](callback), nil) == -12
doAssert aos_unregister_event_filter(99, cast[pointer](callback), nil) == -22
doAssert aos_unregister_event_filter(7, cast[pointer](callback), nil) == 0
doAssert aos_register_event_filter(99, cast[pointer](callback), nil) == 0
''',
    "callback_exception_releases_dispatch": r'''
var count = 0
proc callback(event: ptr AosInputEvent; priv: pointer) {.cdecl.} =
  inc count
  if count == 1:
    raise newException(ValueError, "event callback")
doAssert aos_register_event_filter(2, cast[pointer](callback), nil) == 0
doAssert aos_post_event(2, 1, 0) == EventPostSuccess
doAssert aos_post_event(2, 2, 0) == EventPostSuccess
try:
  aosPollEvents()
  doAssert false
except ValueError:
  discard
doAssert not aosDispatching
# --exceptions:goto can surface a C ABI callback error after the loop drains.
doAssert (aosEventCount == 1 and count == 1) or
  (aosEventCount == 0 and count == 2)
aosPollEvents()
doAssert count == 2
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_aos_events(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case] + r'''
doAssert aosEventCount == 0 and not aosDispatching
doAssert live.len == 0 and interrupts and saves == restores
''')


def test_backend_polls_events() -> None:
    assert "aosPollEvents()" in (SUPPORT / "backend_runtime_parts/poll.nim").read_text()
