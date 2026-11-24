"""Exercise timeout ownership/elapsed ticks and cooperative task notifications."""

from pathlib import Path

import pytest

from test_wifi_adapter_waits import SUPPORT, source as adapter_source
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source(events: str | None = None, memory: str | None = None,
           ipc: str | None = None) -> str:
    memory = memory if memory is not None else (SUPPORT / "os_adapter_parts/memory_timeouts.nim").read_text()
    ipc = ipc if ipc is not None else (FW / "ipc_embedded.nim").read_text()
    code = adapter_source(events=events) + r'''
proc c_malloc(size: csize_t): pointer = c_calloc(1, size)
proc readMtimeUs(): uint64 =
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  inc samples
  clock
'''
    for name in ["osFree", "osGetTimeMs", "osGetTick", "osTaskNotifyIsr", "osYieldFromIsr",
                 "osSetTimeout", "osCheckTimeout"]:
        code += procedure(memory, name)
    code += r'''
var
  ipcEmbEnv: pointer
  ipc_emb_counter, pendingEvents: uint32
  assertions, disableCalls, serviceSteps, drains: int
  missingOperationSlot = -1
proc blOpsFunc(offset: int): pointer =
  if offset == missingOperationSlot: return nil
  case offset
  of 0x44: cast[pointer](osTaskGetCurrent)
  of 0x4C: cast[pointer](osTaskNotify)
  of 0x50: cast[pointer](osTaskWait)
  else: raiseAssert "unexpected operation slot"
proc assert_err(condition, file: cstring; line: cint) = inc assertions
proc assert_rec(condition, file: cstring; line: cint) = inc assertions
proc ipc_host_disable_irq_e2a() = inc disableCalls
proc ke_evt_set(bits: uint32) = pendingEvents = pendingEvents or bits
'''
    code += procedure(ipc, "ipc_emb_notify") + procedure(ipc, "ipc_emb_wait")
    code += procedure((FW / "platform_bl.nim").read_text(), "bl_irq_handler")
    code += r'''
const BlNapWaking = 2'u32
var napScheduleState: uint32
proc wifiUpdateMacPlCtrl() = inc serviceSteps
proc bl_sleep_schedule() = discard
proc wifiMainHasPendingWork(): bool = pendingEvents != 0
proc wifiDrainScheduledWork(): bool =
  inc drains
  result = pendingEvents != 0
  pendingEvents = 0
'''
    main = (FW / "task_init_main.nim").read_text()
    for name in ["wifiWaitForWorkIfIdle", "wifiMainServiceStep", "wifiMainServiceNonblocking",
                 "wifi_main_poll_once"]:
        code += procedure(main, name)
    return code


CASES = {
    "timeout_owned_at_boot": r'''
clock = 0
let timeout = osSetTimeout()
doAssert timeout != nil and allocations == 1
doAssert lastAllocation == sizeof(SimpleTimeout).uint64
doAssert cast[ptr SimpleTimeout](timeout).lastMilliseconds == 0
var ticks = 10'u32
doAssert osCheckTimeout(timeout, addr ticks) == 0 and ticks == 10
osFree(timeout)
doAssert frees == 1
''',
    "timeout_elapsed_not_calls": r'''
clock = 1999
let timeout = osSetTimeout()
var ticks = 10'u32
for i in 0 ..< 100:
  doAssert osCheckTimeout(timeout, addr ticks) == 0 and ticks == 10
clock = 2000
doAssert osCheckTimeout(timeout, addr ticks) == 0 and ticks == 9
clock = 5999
doAssert osCheckTimeout(timeout, addr ticks) == 0 and ticks == 6
clock = 10999
doAssert osCheckTimeout(timeout, addr ticks) == 0 and ticks == 1
clock = 11000
doAssert osCheckTimeout(timeout, addr ticks) == 1 and ticks == 0
doAssert osCheckTimeout(timeout, addr ticks) == 1 and ticks == 0
doAssert polls == 0 and allocations == 1
osFree(timeout)
''',
    "timeout_boundaries": r'''
for budget in [0'u32, 1, 2, 0xFFFFFFFE'u32]:
  for offset in [-1'i64, 0, 1]:
    clock = 123000
    let timeout = osSetTimeout()
    var ticks = budget
    let elapsed = max(0'i64, budget.int64 + offset).uint64
    clock += elapsed * 1000
    let expired = elapsed >= budget.uint64
    doAssert osCheckTimeout(timeout, addr ticks) == expired.cint
    doAssert ticks == (if expired: 0'u32 else: budget - elapsed.uint32)
    osFree(timeout)
''',
    "timeout_tick_wraps": r'''
for start in [0xFFFFFFFE'u64, 0x1FFFFFFFE'u64, 0x400000001'u64]:
  clock = start * 1000
  let timeout = osSetTimeout()
  var ticks = 10'u32
  clock += 5 * 1000
  doAssert osCheckTimeout(timeout, addr ticks) == 0 and ticks == 5
  clock += 5 * 1000
  doAssert osCheckTimeout(timeout, addr ticks) == 1 and ticks == 0
  osFree(timeout)
for elapsed in [0x100000000'u64, 0x200000003'u64]:
  clock = 123000
  let timeout = osSetTimeout()
  var ticks = high(uint32) - 1
  clock += elapsed * 1000
  doAssert osCheckTimeout(timeout, addr ticks) == 1 and ticks == 0
  osFree(timeout)
''',
    "timeout_forever": r'''
clock = 123000
let timeout = osSetTimeout()
let stamp = cast[ptr SimpleTimeout](timeout).lastMilliseconds
var ticks = BlOsWaitingForever
clock += 0x300000000'u64 * 1000
let before = samples
doAssert osCheckTimeout(timeout, addr ticks) == 0 and ticks == BlOsWaitingForever
doAssert samples == before and cast[ptr SimpleTimeout](timeout).lastMilliseconds == stamp
osFree(timeout)
''',
    "timeout_independent": r'''
clock = 100000
let first = osSetTimeout()
clock += 3000
let second = osSetTimeout()
doAssert first != second
var a = 10'u32
var b = 10'u32
clock += 2000
doAssert osCheckTimeout(second, addr b) == 0 and b == 8
doAssert osCheckTimeout(first, addr a) == 0 and a == 5
clock += 1000
doAssert osCheckTimeout(first, addr a) == 0 and a == 4
doAssert osCheckTimeout(second, addr b) == 0 and b == 7
osFree(first)
osFree(second)
''',
    "timeout_invalid_allocation": r'''
failAllocation = true
doAssert osSetTimeout() == nil
var ticks = 123'u32
doAssert osCheckTimeout(nil, addr ticks) == 1 and ticks == 0
doAssert osCheckTimeout(nil, nil) == 1
doAssert allocations == 1 and samples == 0
failAllocation = false
let timeout = osSetTimeout()
doAssert osCheckTimeout(timeout, nil) == 1
osFree(timeout)
''',
    "timeout_irq_state": r'''
for enabled in [false, true]:
  interrupts = enabled
  let timeout = osSetTimeout()
  var ticks = 1'u32
  doAssert osCheckTimeout(timeout, addr ticks) == 0
  doAssert interrupts == enabled
  clock += 1000
  doAssert osCheckTimeout(timeout, addr ticks) == 1 and ticks == 0
  doAssert interrupts == enabled
  osFree(timeout)
interrupts = true
''',
    "notification_handle_identity": r'''
let task = osTaskGetCurrent()
doAssert task != nil and task == cast[pointer](addr osTaskNotifications)
doAssert task == osTaskNotifyCreate()
osTaskNotify(task)
doAssert osTaskNotifications == 1
doAssert osTaskNotifyCreate() == task and osTaskNotifications == 1
doAssert allocations == 0
osTaskWait(task, 0)
''',
    "notification_clear_all": r'''
let task = osTaskNotifyCreate()
for i in 0 ..< 20: osTaskNotify(task)
doAssert osTaskNotifications == 20
osTaskWait(task, 1)
doAssert osTaskNotifications == 0 and polls == 0 and samples == 0
osTaskWait(task, 0)
doAssert polls == 0
osTaskNotify(task)
osTaskWait(nil, 0)  # The SDK take consumes the current task, not this parameter.
doAssert osTaskNotifications == 0
''',
    "notification_timeout_wakeup": r'''
let task = osTaskNotifyCreate()
osTaskWait(task, 2)
doAssert polls == 20 and delayed == 2000
pollHook = proc() = osTaskNotify(task)
osTaskWait(task, BlOsWaitingForever)
doAssert polls == 21 and osTaskNotifications == 0
polls = 0
pollHook = proc() =
  if polls == 10: osTaskNotify(task)
osTaskWait(task, 1)
doAssert polls == 10 and osTaskNotifications == 0
''',
    "notification_isr_masked": r'''
let task = osTaskNotifyCreate()
interrupts = false
doAssert osTaskNotifyIsr(task) == 0
doAssert osTaskNotifications == 1 and not interrupts
osYieldFromIsr(1)
osTaskWait(task, BlOsWaitingForever)
doAssert osTaskNotifications == 0 and not interrupts
osTaskWait(task, BlOsWaitingForever)
doAssert polls == 0 and samples == 0 and not interrupts
interrupts = true
''',
    "notification_foreign_handle": r'''
osTaskNotify(nil)
osTaskNotify(cast[pointer](1))
doAssert osTaskNotifyIsr(nil) == 0
doAssert osTaskNotifications == 0 and polls == 0
''',
    "notification_counter_wrap": r'''
osTaskNotifications = high(uint32) - 1
let task = osTaskNotifyCreate()
osTaskNotify(task)
doAssert osTaskNotifications == high(uint32)
osTaskNotify(task)
doAssert osTaskNotifications == 0
osTaskNotify(task)
osTaskWait(task, 0)
doAssert osTaskNotifications == 0
''',
    "notification_exception_cleanup": r'''
let task = osTaskNotifyCreate()
pollHook = proc() = raise newException(ValueError, "poll")
try:
  osTaskWait(task, 1)
  doAssert false
except ValueError: discard
doAssert interrupts and osTaskNotifications == 0
pollHook = nil
osTaskNotify(task)
osTaskWait(task, 0)
doAssert osTaskNotifications == 0
''',
    "ipc_notification_bridge": r'''
ipcEmbEnv = osTaskNotifyCreate()
pollHook = proc() = bl_irq_handler()
ipc_emb_wait()
doAssert ipc_emb_counter == 1 and polls == 1
doAssert disableCalls == 1 and pendingEvents == 0x80 and assertions == 0
doAssert osTaskNotifications == 0
interrupts = false
bl_irq_handler()
bl_irq_handler()
doAssert osTaskNotifications == 2
ipc_emb_wait()
doAssert ipc_emb_counter == 2 and osTaskNotifications == 0 and not interrupts
interrupts = true
''',
    "ipc_missing_task_or_callback": r'''
ipc_emb_counter = 0
ipcEmbEnv = nil
ipc_emb_notify(1)
ipc_emb_wait()
doAssert assertions == 2 and ipc_emb_counter == 0
doAssert osTaskNotifications == 0 and polls == 0
ipcEmbEnv = osTaskNotifyCreate()
missingOperationSlot = 0x4C
ipc_emb_notify(1)
missingOperationSlot = 0x50
ipc_emb_wait()
doAssert assertions == 4 and ipc_emb_counter == 0
doAssert osTaskNotifications == 0 and polls == 0
missingOperationSlot = -1
ipc_emb_notify(1)
ipc_emb_wait()
doAssert assertions == 4 and ipc_emb_counter == 1
doAssert osTaskNotifications == 0
''',
    "nonblocking_service_preserved": r'''
ipcEmbEnv = osTaskNotifyCreate()
maxPolls = 0
wifi_main_poll_once()
doAssert polls == 0 and ipc_emb_counter == 0 and serviceSteps == 1 and drains == 1
bl_irq_handler()
doAssert osTaskNotifications == 1
wifi_main_poll_once()
doAssert polls == 0 and ipc_emb_counter == 0 and serviceSteps == 2 and drains == 2
doAssert pendingEvents == 0 and osTaskNotifications == 1
osTaskWait(ipcEmbEnv, 0)
doAssert osTaskNotifications == 0
''',
    "blocking_service_explicit": r'''
ipcEmbEnv = osTaskNotifyCreate()
pollHook = proc() = bl_irq_handler()
doAssert wifiMainServiceStep(blockWhenIdle = true)
doAssert polls == 1 and ipc_emb_counter == 1 and serviceSteps == 1 and drains == 1
doAssert pendingEvents == 0 and osTaskNotifications == 0
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_task_timeouts(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case] + r'''
doAssert live.len == 0
doAssert interrupts and saves == restores
''')
