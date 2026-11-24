"""Exercise cooperative WiFi adapter timers and workqueue notifications."""

from pathlib import Path

import pytest

from test_wifi_adapter_waits import SUPPORT, source as adapter_source
from test_wifi_message_allocation import run_program


def source() -> str:
    return adapter_source() + r'''
type IrqHandler = proc() {.cdecl.}
proc bl808_register_trap_handler(n: uint32; handler: IrqHandler) = discard
proc bl808_enable_peripheral_irq(n: uint32; enable: int) = discard
proc bl808_disable_peripheral_irq(n: uint32) = discard
var osTimerHead: ptr SimpleTimer
''' + (SUPPORT / "os_adapter_parts/irq_timers.nim").read_text()


CASES = {
    "workqueue_notifies_task": r'''
let work = osWorkqueueCreate()
doAssert work == osTaskGetCurrent() and work != nil
doAssert osWorkqueueSubmit(work, nil, nil, 0) == 0
doAssert osTaskNotifications == 1
osTaskWait(work, 0)
doAssert osTaskNotifications == 0
doAssert osWorkqueueSubmit(nil, nil, nil, 0) == 1
doAssert osWorkqueueSubmit(cast[pointer](2), nil, nil, 0) == 1
doAssert osTaskNotifications == 0
''',
    "timer_once": r'''
var fired = 0
proc callback(arg: pointer) {.cdecl.} =
  doAssert interrupts and arg == addr fired
  inc fired
let timer = osTimerCreate(cast[pointer](callback), addr fired)
doAssert timer != nil and osTimerStartOnce(timer, 0, 1_000_001) == 0
clock = 999
osTimerPoll()
doAssert fired == 0
clock = 1000
osTimerPoll()
doAssert fired == 1
clock = 5000
osTimerPoll()
doAssert fired == 1
doAssert osTimerDelete(timer, 0) == 1 and frees == 1
''',
    "timer_periodic_and_restart": r'''
var fired = 0
proc callback(arg: pointer) {.cdecl.} = inc fired
let timer = osTimerCreate(cast[pointer](callback), nil)
doAssert osTimerStartPeriodic(timer, 0, 2_000_000) == 0
clock = 2000
osTimerPoll()
doAssert fired == 1
clock = 6000
osTimerPoll()
doAssert fired == 2
clock = 7999
osTimerPoll()
doAssert fired == 2
clock = 8000
osTimerPoll()
doAssert fired == 3
doAssert osTimerStartOnce(timer, 0, 1_000_000) == 0
clock = 9000
osTimerPoll()
doAssert fired == 4
clock = 10_000
osTimerPoll()
doAssert fired == 4
doAssert osTimerDelete(timer, 0) == 1
''',
    "timer_callback_deletes_self": r'''
var timer: pointer
var fired = 0
proc callback(arg: pointer) {.cdecl.} =
  inc fired
  doAssert interrupts
  doAssert osTimerDelete(timer, 0) == 1
  doAssert frees == 0
timer = osTimerCreate(cast[pointer](callback), nil)
doAssert osTimerStartOnce(timer, 0, 1_000_000) == 0
clock = 1000
osTimerPoll()
doAssert fired == 1 and frees == 1 and osTimerHead == nil
''',
    "timer_callback_restarts_self": r'''
var timer: pointer
var fired = 0
proc callback(arg: pointer) {.cdecl.} =
  inc fired
  if fired == 1:
    doAssert osTimerStartOnce(timer, 0, 2_000_000) == 0
timer = osTimerCreate(cast[pointer](callback), nil)
doAssert osTimerStartOnce(timer, 0, 1_000_000) == 0
clock = 1000
osTimerPoll()
doAssert fired == 1
clock = 2999
osTimerPoll()
doAssert fired == 1
clock = 3000
osTimerPoll()
doAssert fired == 2
doAssert osTimerDelete(timer, 0) == 1
''',
    "timer_callback_cancels_other": r'''
var canceled: pointer
var firstFired, canceledFired: int
proc first(arg: pointer) {.cdecl.} =
  inc firstFired
  doAssert osTimerDelete(canceled, 0) == 1
proc second(arg: pointer) {.cdecl.} = inc canceledFired
canceled = osTimerCreate(cast[pointer](second), nil)
let firstTimer = osTimerCreate(cast[pointer](first), nil)
doAssert osTimerStartOnce(canceled, 0, 1_000_000) == 0
doAssert osTimerStartOnce(firstTimer, 0, 1_000_000) == 0
clock = 1000
osTimerPoll()
doAssert firstFired == 1 and canceledFired == 0 and frees == 1
doAssert osTimerDelete(firstTimer, 0) == 1
''',
    "timer_invalid_and_clock_failure": r'''
proc callback(arg: pointer) {.cdecl.} = discard
doAssert osTimerCreate(nil, nil) == nil
failAllocation = true
doAssert osTimerCreate(cast[pointer](callback), nil) == nil
failAllocation = false
doAssert osTimerStartOnce(nil, 1, 0) == 1
doAssert osTimerDelete(nil, 0) == 0
let timer = osTimerCreate(cast[pointer](callback), nil)
doAssert osTimerStartOnce(timer, -1, 0) == 1
doAssert osTimerStartOnce(timer, 0, -1) == 1
doAssert osTimerStartOnce(timer, 0, 1_000_000_000) == 1
doAssert osTimerStartPeriodic(timer, 0, 0) == 1
clockAvailable = false
doAssert osTimerStartOnce(timer, 1, 0) == 1
clockAvailable = true
doAssert osTimerStartOnce(timer, 0, 1) == 0
clock = 1000
clockAvailable = false
osTimerPoll()
doAssert cast[ptr SimpleTimer](timer).active
clockAvailable = true
osTimerPoll()
doAssert not cast[ptr SimpleTimer](timer).active
doAssert osTimerDelete(timer, 0) == 1
''',
    "timer_clock_wrap": r'''
var fired = 0
proc callback(arg: pointer) {.cdecl.} = inc fired
clock = high(uint64) - 500
let timer = osTimerCreate(cast[pointer](callback), nil)
doAssert osTimerStartOnce(timer, 0, 1_000_000) == 0
clock = high(uint64)
osTimerPoll()
doAssert fired == 0
clock = 499
osTimerPoll()
doAssert fired == 1
doAssert osTimerDelete(timer, 0) == 1
''',
    "timer_callback_exception": r'''
var timer: pointer
proc callback(arg: pointer) {.cdecl.} =
  doAssert osTimerDelete(timer, 0) == 1
  raise newException(ValueError, "timer callback")
timer = osTimerCreate(cast[pointer](callback), nil)
doAssert osTimerStartOnce(timer, 0, 1_000_000) == 0
clock = 1000
try:
  osTimerPoll()
  doAssert false
except ValueError:
  discard
doAssert frees == 1 and osTimerHead == nil
''',
    "timer_budget_fairness": r'''
var fired: array[20, int]
var timers: array[20, pointer]
proc callback(arg: pointer) {.cdecl.} = inc cast[ptr int](arg)[]
for i in 0 ..< timers.len:
  timers[i] = osTimerCreate(cast[pointer](callback), addr fired[i])
  doAssert osTimerStartPeriodic(timers[i], 0, 1_000_000) == 0
clock = 1000
osTimerPoll()
var total = 0
for count in fired:
  total += count
doAssert total == 16
clock = 2000
osTimerPoll()
for count in fired:
  doAssert count >= 1
for timer in timers:
  doAssert osTimerDelete(timer, 0) == 1
doAssert frees == timers.len
''',
    "timer_nested_poll_does_not_reenter": r'''
var timer: pointer
var fired = 0
proc callback(arg: pointer) {.cdecl.} =
  inc fired
  if fired == 1:
    doAssert osTimerStartPeriodic(timer, 0, 1_000_000) == 0
    clock = 2000
    osTimerPoll()
    doAssert fired == 1
timer = osTimerCreate(cast[pointer](callback), nil)
doAssert osTimerStartOnce(timer, 0, 1_000_000) == 0
clock = 1000
osTimerPoll()
doAssert fired == 1
osTimerPoll()
doAssert fired == 2
doAssert osTimerDelete(timer, 0) == 1
''',
    "timer_poll_defers_with_irqs_masked": r'''
var fired = 0
proc callback(arg: pointer) {.cdecl.} =
  doAssert interrupts
  inc fired
let timer = osTimerCreate(cast[pointer](callback), nil)
doAssert osTimerStartOnce(timer, 0, 1_000_000) == 0
clock = 1000
interrupts = false
osTimerPoll()
doAssert fired == 0
interrupts = true
osTimerPoll()
doAssert fired == 1
doAssert osTimerDelete(timer, 0) == 1
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_adapter_timer(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case] + r'''
doAssert live.len == 0
doAssert interrupts and saves == restores
''')


def test_timer_poll_is_wired_into_backend() -> None:
    assert "osTimerPoll()" in (SUPPORT / "backend_runtime_parts/poll.nim").read_text()
