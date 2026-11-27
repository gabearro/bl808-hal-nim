"""Exercise Wi-Fi's CPS wake path with a modeled scheduler and IRQ mask."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


HOOK = FW.parent / "facade_parts/service_futures_parts/scheduler_hook.nim"
KERNEL = FW / "kernel_mac_channel.nim"
SCHEDULED = FW.parent / "support/backend_runtime_parts/scheduled_work.nim"


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_scheduler_wakes_and_backstops(tmp_path: Path, mode: str) -> None:
    code = r'''
var
  now: uint64
  irqEnabled = true
  posted: seq[proc() {.closure.}]
  priority: proc() {.nimcall.}
  priorityReady: proc(): bool {.nimcall.}
  events: uint32
  priorityOccupied: bool
  postFails = false
  timedHook: proc(now: uint64): uint64 {.closure.}
  deadline: uint64
  workHook: proc() {.cdecl.}
  active, pending, wifiInitialized, pmWaking, notifyDuringService: bool
  reenterDuringService: bool
  firmwareDelay: int32 = high(int32)
  hostDelay = high(uint64)
  serviceCalls, txCalls, completions: int
  lastBudget: uint32

template withInterruptsDisabled(body: untyped) =
  block:
    let saved = irqEnabled
    irqEnabled = false
    body
    irqEnabled = saved

proc readTick(): uint64 = now
proc usToTicks(us: uint64): uint64 = us
proc tryPostFromIsr(cb: proc() {.closure.}): bool =
  doAssert not irqEnabled
  if postFails: return false
  posted.add(cb)
  true
proc tryPostPriorityFromIsr(cb: proc() {.nimcall.}; ready: proc(): bool {.nimcall.}): bool =
  doAssert not irqEnabled
  if priorityOccupied: return false
  doAssert priority == nil
  priority = cb
  priorityReady = ready
  true
proc ke_evt_field_get(): uint32 = events
proc addSchedulerTimedPollHook(hook: proc(now: uint64): uint64 {.closure.};
                               firstDeadline: uint64): bool =
  timedHook = hook
  deadline = firstDeadline
  true
proc rescheduleSchedulerTimedPollHook(
    hook: proc(now: uint64): uint64 {.closure.}; next: uint64): bool =
  doAssert timedHook != nil
  deadline = next
  true
proc bl808_wifi_backend_set_work_hook(hook: proc() {.cdecl.}) = workHook = hook
proc bl808_wifi_backend_signal_work() =
  if workHook != nil: workHook()
proc wifiServicePump(iterations: uint32) = discard iterations
proc bl808_wifi_backend_next_delay_us(): uint64 = hostDelay
proc bl808_wifi_backend_work_pending(): bool = pending
proc wifi_nimfw_next_timer_delay_us(): int32 = firmwareDelay
proc wifi_pm_wake_pending(): bool = pmWaking
proc wifiServiceWanted(): bool = active
proc wifiServiceRun(fromTimer: bool)
proc bl808_wifi_backend_service(maxRounds: uint32): uint32 =
  doAssert irqEnabled
  inc serviceCalls
  lastBudget = maxRounds
  if reenterDuringService:
    reenterDuringService = false
    wifiServiceRun(true)
    doAssert irqEnabled
  if notifyDuringService:
    notifyDuringService = false
    workHook()
  pending = false
  1
proc wifiNimFirmwareServiceTx(count: uint32) =
  doAssert count == 1
  inc txCalls
proc wifiCompletePendingEvents() =
  doAssert irqEnabled
  inc completions

proc runPosted() =
  if priority != nil:
    let cb = priority
    priority = nil
    cb()
    return
  doAssert posted.len > 0
  let cb = posted[0]
  posted.delete(0)
  cb()
'''
    code += HOOK.read_text()
    code += r'''
wifiInstallServiceHook()
doAssert workHook != nil and priority != nil and posted.len == 0 and deadline == 1
doAssert not priorityReady()
events = 1'u32 shl 20
doAssert priorityReady()
events = 1'u32 shl 23
doAssert priorityReady()
events = 1'u32 shl 24
doAssert not priorityReady()
# An expiring timer leaves an admitted wake for its posted callback.
doAssert timedHook(deadline) > 0 and serviceCalls == 0 and priority != nil
runPosted()
doAssert serviceCalls == 1 and completions == 1
doAssert deadline == 10_000 and txCalls == 0

# Multiple notifications occupy one priority slot.
workHook()
workHook()
workHook()
doAssert priority != nil and posted.len == 0
runPosted()
doAssert serviceCalls == 2 and priority == nil and posted.len == 0

# Active cadence, firmware timer, and host timer can each shorten the deadline.
active = true
wifiInitialized = true
wifiConfigureServiceHook(2_000, 100)
runPosted()
doAssert lastBudget == 1 and txCalls == 1 and deadline == 2_000
firmwareDelay = 100
workHook()
runPosted()
doAssert deadline == 350
firmwareDelay = high(int32)
hostDelay = 50
workHook()
runPosted()
doAssert deadline == 50

# A full ISR queue cannot latch the coalescing flag indefinitely. Its timed
# backstop still runs when work is pending.
active = false
hostDelay = high(uint64)
priorityOccupied = true
postFails = true
pending = true
workHook()
doAssert posted.len == 0
postFails = false
now = deadline
deadline = timedHook(now)
doAssert serviceCalls == 6 and deadline > now

# A busy priority slot falls back to the ordinary queue. Work notified
# during its callback gets another scheduler turn.
notifyDuringService = true
workHook()
runPosted()
doAssert posted.len == 1
runPosted()
doAssert posted.len == 0 and serviceCalls == 8

# Reentry must not return from inside an IRQ-disabled block.
priorityOccupied = false
reenterDuringService = true
workHook()
runPosted()
doAssert irqEnabled and posted.len == 0 and serviceCalls == 9
'''
    run_program(tmp_path, mode, code)


def test_kernel_event_transition_notifies_after_irq_restore(tmp_path: Path) -> None:
    code = r'''
var
  events: uint32
  irqEnabled = true
  notifications: int
template keEnvEventField(): ptr uint32 = addr events
proc irqSave(): uint32 =
  result = if irqEnabled: 8'u32 else: 0'u32
  irqEnabled = false
proc irqRestore(saved: uint32) = irqEnabled = (saved and 8'u32) != 0
proc nimFwTrace2U32(label: cstring; a, b: uint32) = discard
proc bl808_wifi_backend_signal_work() =
  doAssert irqEnabled
  inc notifications
'''
    code += procedure(KERNEL.read_text(), "ke_evt_set")
    code += r'''
ke_evt_set(1)
doAssert events == 1 and notifications == 1
ke_evt_set(1)
doAssert events == 1 and notifications == 1
ke_evt_set(2)
doAssert events == 3 and notifications == 2
'''
    run_program(tmp_path, "checked", code, defines=("bl808m0",))


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_cps_handoff_dispatches_one_firmware_event_per_turn(
    tmp_path: Path, mode: str
) -> None:
    code = r'''
var
  wifiSchedulerWorkHook: proc() {.cdecl.}
  hostPollEnabled = false
  ipcPollIrqCount: uint32
  events, firmwareCalls: int
proc wake() {.cdecl.} = discard
proc wifi_pm_wake_pending(): bool = false
proc bl808WifiBackendHostIpcStatus(): uint32 = 0
proc ke_evt_field_get(): uint32 = events.uint32
proc wifi_main_poll_once() =
  inc firmwareCalls
  dec events
proc bl_irq_handler() = discard
proc wifiHwRaw(): pointer = nil
proc loadPtr(base: pointer; offset: int): pointer = nil
proc bl_main_event_handle(a: int; b: pointer) = discard
'''
    code += SCHEDULED.read_text()
    code += r'''
# The caller's first firmware step and the host handoff share one CPS turn.
wifiSchedulerWorkHook = wake
events = 2
wifi_main_poll_once()
vendorDrainScheduledWork()
doAssert firmwareCalls == 1 and events == 1
wifi_main_poll_once()
vendorDrainScheduledWork()
doAssert firmwareCalls == 2 and events == 0

# Bare-loop callers still drain bounded queued firmware work.
wifiSchedulerWorkHook = nil
events = 2
firmwareCalls = 0
vendorDrainScheduledWork()
doAssert firmwareCalls == 2 and events == 0
'''
    run_program(tmp_path, mode, code)
