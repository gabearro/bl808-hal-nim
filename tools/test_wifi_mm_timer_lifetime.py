"""Exercise MM timer mutation, dispatch, and hardware-programming ownership."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
{.pragma: wifiCtrl.}
const
  MACHW_TIMLO_REG = 0'u
  MACHW_ABS_TIMER_REG = 1'u
  MACHW_INTC_BASE = 0x1000'u
  KE_EVT_MM_TIMER = 0x40000000'u32
  WifiTimerDrainLimit = 8'u32
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  MmTimerElemView = object
    next: ptr CoListHdr
    callback: pointer
    env, expiry: uint32
  MmTimerView = MmTimerElemView
  MmStaDeletion = object
    active: bool
var
  mm_timer_list: CoList
  mmTimerRevision: uint32
  mmStaDelRetryMask: uint8
  mmStaDelRetryReset: uint32
  mmStaDelRetryTimer: MmTimerView
  mmStaDeletions: array[5, MmStaDeletion]
  timers: array[4, MmTimerElemView]
  now, events, hardwareDeadline, unmask: uint32
  enabled = true
  hardware: seq[tuple[index: int, expiry: uint32]]
  registerWrites: seq[tuple[address: uint, value: uint32]]
  delivered: seq[uint]
  onRead, onHardware, onClearEvent, onSetEvent, onCallback, onRestore: proc()
  onTrace: proc(tag: string)
  nimFwDbgMmTimerYield, nimFwDbgMmTimerYieldHead: uint32
proc invoke(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
proc irqSave(): uint32 =
  result = if enabled: 8'u32 else: 0'u32
  enabled = false
proc irqRestore(saved: uint32) =
  enabled = (saved and 8) != 0
  if enabled: invoke(onRestore)
proc regRead(address: uint): uint32 =
  if address == MACHW_TIMLO_REG:
    result = now
    invoke(onRead)
  elif address == MACHW_ABS_TIMER_REG: result = hardwareDeadline
  else: result = unmask
proc regWrite(address: uint; value: uint32) =
  registerWrites.add((address, value))
  if address == MACHW_ABS_TIMER_REG: hardwareDeadline = value
  else: unmask = value
proc nimFwTrace2U32(tag: string; a, b: uint32) =
  if onTrace != nil: onTrace(tag)
proc mmTimerAt(p: pointer): ptr MmTimerElemView = cast[ptr MmTimerElemView](p)
proc mmTimerHdr(p: ptr MmTimerElemView): ptr CoListHdr = cast[ptr CoListHdr](p)
proc timerIndex(p: pointer): int =
  for index in 0..<timers.len:
    if p == addr timers[index]: return index
  -1
proc mm_timer_hw_set(p: pointer) =
  hardware.add((timerIndex(p), if p == nil: 0'u32 else: mmTimerAt(p).expiry))
  invoke(onHardware)
proc ke_evt_set(bits: uint32) =
  events = events or bits
  invoke(onSetEvent)
proc ke_evt_clear(bits: uint32) =
  events = events and not bits
  invoke(onClearEvent)
proc assert_err(a, b: cstring; line: cint) = doAssert false
proc chanTimerInvalidate(timer: pointer = nil) = discard
proc chanTimerArming(timer: pointer) = discard
proc chanTimerPublished(timer: pointer) = discard
proc chanTimerCapture(timer: pointer): uint32 = 0
proc chanTimerDispatch(timer, callback, argument: pointer; serial: uint32): bool = false
proc expired(p: pointer) {.cdecl.} =
  delivered.add(cast[uint](p))
  invoke(onCallback)
'''


def source(real_hardware: bool = False) -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = PLATFORM
    if real_hardware:
        code = code.replace(procedure(code, "mm_timer_hw_set"),
                            procedure(kernel, "mm_timer_hw_set"), 1)
    if "proc mmTimerCancelMutations(" in kernel:
        layout = (FW / "layout_types.nim").read_text()
        code += "type\n  MmTimerMutation" + layout.split(
            "  MmTimerMutation", 1)[1].split("\n\n", 1)[0] + "\n"
        code += "var mmTimerMutationTop: ptr MmTimerMutation\nvar mmTimerScheduling: bool\n"
        for name in ["mmTimerCancelMutations", "mmTimerBeginMutation", "mmTimerEndMutation"]:
            code += procedure(kernel, name)
    for name in ["co_list_init", "co_list_pop_front", "co_list_extract", "co_list_insert",
                 "cmp_mm_timer_time", "mm_timer_init", "mmTimerSetLocked", "mm_timer_set",
                 "mmTimerClearLocked", "mm_timer_clear",
                 "mmTimerExpired", "mm_timer_schedule"]:
        body = procedure(kernel, name)
        if name == "mm_timer_schedule":
            body = body.split("\ntype\n", 1)[0].split("\nvar\n", 1)[0]
        code += body
    return code + r'''
proc setup() =
  onRead = nil
  onHardware = nil
  onClearEvent = nil
  onSetEvent = nil
  onCallback = nil
  onRestore = nil
  onTrace = nil
  enabled = true
  mm_timer_init()
  timers = default(typeof(timers))
  for index in 0..<timers.len:
    timers[index].callback = cast[pointer](expired)
    timers[index].env = (index + 1).uint32
  now = 0
  events = 0
  hardwareDeadline = 0
  unmask = 0
  nimFwDbgMmTimerYield = 0
  nimFwDbgMmTimerYieldHead = 0
  hardware.setLen(0)
  registerWrites.setLen(0)
  delivered.setLen(0)
proc queueIds(): seq[uint] =
  var node = mm_timer_list.first
  while node != nil:
    doAssert result.len < timers.len, "MM timer queue cycle"
    doAssert timerIndex(node) >= 0
    result.add(mmTimerAt(node).env.uint)
    node = node.next
proc finish() =
  onRead = nil
  onHardware = nil
  onClearEvent = nil
  onSetEvent = nil
  onCallback = nil
  onRestore = nil
  onTrace = nil
  mm_timer_init()
  when declared(mmTimerMutationTop): doAssert mmTimerMutationTop == nil
  when declared(mmTimerScheduling): doAssert not mmTimerScheduling
setup()
'''

SERVICE_PLATFORM = r'''
const
  KE_EVT_MAX = 26
  KE_EVT_RESET = 0x80000000'u32
  KE_EVT_KE_TIMER = 0x20000000'u32
  KE_EVT_KE_MESSAGE = 0x08000000'u32
  KE_EVT_RXREADY = 0x00100000'u32
type KeTimerEntry = object
  time: uint32
var
  kernelTimer: KeTimerEntry
  keTimerQueue: CoList
  keEvtHandlers: array[KE_EVT_MAX, tuple[handler, param: pointer]]
  beacons, kernelCallbacks, resets: int
  registrations, scans, taskMessages: int
  registrationReady, scanReady, messageReady, holdReset, registrationPostsReset: bool
proc keEnvEventField(): ptr uint32 = addr events
proc macTimeNow(): uint32 = regRead(MACHW_TIMLO_REG)
# The first two polled services in wifiDrainScheduledWork's order stand in
# for any: "registration" runs first and can post a reset, "scan" second.
proc smActivationNeedsService(): bool = registrationReady
proc smBssNeedsService(): bool = scanReady
proc smCleanupNeedsService(): bool = false
proc smActivationService() =
  registrationReady = false
  inc registrations
  if registrationPostsReset:
    ke_evt_set(KE_EVT_RESET)
proc smBssService() =
  scanReady = false
  inc scans
proc smCleanupService() = discard
proc wifiMessagePendingWork(): bool = messageReady
proc ke_task_schedule() =
  messageReady = false
  inc taskMessages
  ke_evt_clear(KE_EVT_KE_MESSAGE)
'''

SERVICE_CHECKS = r'''
proc ke_timer_schedule() =
  ke_evt_clear(KE_EVT_KE_TIMER)
  if keTimerExpired(cast[ptr KeTimerEntry](keTimerQueue.first)):
    inc kernelCallbacks
    keTimerQueue.first = nil
proc mmEvent(arg: pointer) {.cdecl.} = mm_timer_schedule()
proc keEvent(arg: pointer) {.cdecl.} = ke_timer_schedule()
proc taskEvent(arg: pointer) {.cdecl.} = ke_task_schedule()
proc resetEvent(arg: pointer) {.cdecl.} =
  inc resets
  if holdReset: return
  events = 0
  mm_timer_init()
  keTimerQueue.first = nil
proc beaconRx(arg: pointer) {.cdecl.} =
  inc beacons
  ke_evt_clear(KE_EVT_RXREADY)
  # The admitted Beacon clears its VIF's keep-alive timer.
  mm_timer_clear(addr timers[0])

proc armServiceTimers(start, deadline: uint32) =
  setup()
  now = start
  mm_timer_set(addr timers[0], deadline)
  kernelTimer.time = deadline
  keTimerQueue.first = cast[ptr CoListHdr](addr kernelTimer)
  beacons = 0
  kernelCallbacks = 0
  resets = 0
  registrations = 0
  scans = 0
  taskMessages = 0
  registrationReady = false
  scanReady = false
  messageReady = false
  holdReset = false
  registrationPostsReset = false

keEvtHandlers[0].handler = cast[pointer](resetEvent)
keEvtHandlers[1].handler = cast[pointer](mmEvent)
keEvtHandlers[2].handler = cast[pointer](keEvent)
keEvtHandlers[4].handler = cast[pointer](taskEvent)
keEvtHandlers[11].handler = cast[pointer](beaconRx)
for deadline in [1000'u32, 20'u32]:
  armServiceTimers(deadline - 100, deadline)
  now = deadline - 25
  let earlyWork = wifiMainHasPendingWork()
  ke_evt_set(KE_EVT_RXREADY)
  doAssert wifiDrainScheduledWork()
  doAssert beacons == 1 and delivered.len == 0 and queueIds().len == 0
  doAssert not earlyWork, "future fallback timers are not work"
  doAssert kernelCallbacks == 0 and keTimerQueue.first != nil
  now = deadline
  doAssert wifiMainHasPendingWork() and wifiDrainScheduledWork()
  doAssert kernelCallbacks == 1
  doAssert not wifiMainHasPendingWork()

  armServiceTimers(deadline - 100, deadline)
  now = deadline
  ke_evt_set(KE_EVT_RESET)
  doAssert wifiDrainScheduledWork()
  doAssert resets == 1 and delivered.len == 0 and kernelCallbacks == 0
  doAssert not wifiDrainScheduledWork()

  armServiceTimers(deadline - 100, deadline)
  now = deadline
  ke_evt_set(KE_EVT_MM_TIMER or KE_EVT_KE_TIMER)
  doAssert wifiDrainScheduledWork()
  doAssert delivered == @[1'u] and kernelCallbacks == 0
  doAssert events == KE_EVT_KE_TIMER
  doAssert wifiDrainScheduledWork() and kernelCallbacks == 1
  doAssert not wifiDrainScheduledWork()

  armServiceTimers(deadline - 100, deadline)
  now = deadline
  doAssert wifiDrainScheduledWork()
  doAssert delivered == @[1'u] and kernelCallbacks == 0
  doAssert events == 0, "recovery must not leave a synthetic event pending"
  doAssert wifiDrainScheduledWork() and kernelCallbacks == 1
  doAssert not wifiDrainScheduledWork()

  armServiceTimers(deadline - 100, deadline)
  now = deadline
  onCallback = proc() = kernelTimer.time = now + 25
  doAssert wifiDrainScheduledWork()
  doAssert delivered == @[1'u] and kernelCallbacks == 0
  doAssert not wifiDrainScheduledWork()
  now += 25
  doAssert wifiDrainScheduledWork() and kernelCallbacks == 1

  armServiceTimers(deadline - 100, deadline)
  now = deadline - 25
  ke_evt_set(KE_EVT_MM_TIMER or KE_EVT_RXREADY)
  doAssert wifiDrainScheduledWork()
  doAssert delivered == @[1'u] and beacons == 0 and kernelCallbacks == 0
  doAssert wifiDrainScheduledWork() and beacons == 1

  armServiceTimers(deadline - 100, deadline)
  now = deadline - 25
  ke_evt_set(KE_EVT_KE_TIMER or KE_EVT_RXREADY)
  doAssert wifiDrainScheduledWork()
  doAssert delivered.len == 0 and beacons == 0 and kernelCallbacks == 1
  doAssert wifiDrainScheduledWork() and beacons == 1 and queueIds().len == 0

  armServiceTimers(deadline - 100, deadline)
  registrationReady = true
  messageReady = true
  holdReset = true
  ke_evt_set(KE_EVT_RESET)
  doAssert wifiDrainScheduledWork()
  doAssert resets == 1 and events == KE_EVT_RESET
  doAssert registrations == 0 and taskMessages == 0
  holdReset = false
  doAssert wifiDrainScheduledWork() and resets == 2
  doAssert registrations == 0 and taskMessages == 0
  doAssert wifiDrainScheduledWork()
  doAssert registrations == 1 and taskMessages == 1 and events == 0

  armServiceTimers(deadline - 100, deadline)
  registrationReady = true
  scanReady = true
  registrationPostsReset = true
  messageReady = true
  doAssert wifiDrainScheduledWork()
  doAssert registrations == 1 and resets == 1 and scans == 0 and taskMessages == 0
  doAssert wifiDrainScheduledWork()
  doAssert scans == 1 and taskMessages == 1

  armServiceTimers(deadline - 100, deadline)
  messageReady = true
  ke_evt_set(KE_EVT_RXREADY)
  doAssert wifiDrainScheduledWork()
  doAssert taskMessages == 1 and beacons == 0 and events == KE_EVT_RXREADY
  doAssert wifiDrainScheduledWork() and beacons == 1 and events == 0
finish()
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_timer_poll_services_only_due_fallbacks(tmp_path: Path, mode: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    service = (FW / "task_init_main.nim").read_text()
    code = source() + SERVICE_PLATFORM
    for name in ("keTimerExpired", "eventIndex32", "keDispatchEvent"):
        code += procedure(kernel, name)
    boundary = SERVICE_CHECKS.index("proc mmEvent")
    code += SERVICE_CHECKS[:boundary]
    for name in ("wifiEventPendingWork", "wifiKernelTimerPendingWork",
                 "wifiMmTimerPendingWork", "wifiResetEventPending", "wifiMainHasPendingWork",
                 "wifiDispatchScheduledEvent",
                 "wifiDrainScheduledWork"):
        code += procedure(service, name)
    run_program(tmp_path, mode, code + SERVICE_CHECKS[boundary:])


CASES = {
    "bounded_head_churn": r'''
mm_timer_set(addr timers[0], 100)
var reprograms = 0
proc moveHead() =
  inc reprograms
  doAssert reprograms <= WifiTimerDrainLimit.int + 1
  now += 100
  mm_timer_set(addr timers[0], now + 100)
  onHardware = moveHead
onHardware = moveHead
mm_timer_schedule()
doAssert reprograms == WifiTimerDrainLimit.int + 1
doAssert delivered.len == 0 and queueIds() == @[1'u]
''',
    "expiry_during_programming": r'''
for due in [100'u32, 151]:
  setup()
  mm_timer_set(addr timers[0], 100)
  onHardware = proc() = now = due
  mm_timer_schedule()
  doAssert delivered == @[1'u] and queueIds().len == 0
  setup()
  onHardware = proc() = now = due
  mm_timer_set(addr timers[0], 100)
  doAssert events == KE_EVT_MM_TIMER
  mm_timer_schedule()
  doAssert delivered == @[1'u] and queueIds().len == 0
''',
    "early_expiry_boundary": r'''
for target in [149'u32, 150, 151]:
  setup()
  mm_timer_set(addr timers[0], target)
  now = 100
  mm_timer_schedule()
  doAssert delivered.len == (target == 149).int
  doAssert queueIds().len == (target != 149).int
''',
    "past_clamp_after_trace": r'''
now = 100
onTrace = proc(tag: string) =
  onTrace = nil
  now = 500
mm_timer_set(addr timers[0], 90)
doAssert timers[0].expiry == 3500
''',
    "revision_wrap": r'''
mmTimerRevision = high(uint32)
mm_timer_set(addr timers[0], 100)
doAssert mmTimerRevision == 0 and queueIds() == @[1'u]
''',
    "expiry_cancels_old_set": r'''
onHardware = proc() =
  now = 151
  onCallback = proc() = mm_timer_set(addr timers[0], 500)
  mm_timer_schedule()
mm_timer_set(addr timers[0], 100)
doAssert delivered == @[1'u] and queueIds() == @[1'u]
doAssert timers[0].expiry == 500
''',
    "clear_during_set_trace": r'''
onTrace = proc(tag: string) =
  onTrace = nil
  mm_timer_clear(addr timers[0])
mm_timer_set(addr timers[0], 100)
doAssert queueIds().len == 0
''',
    "reset_during_set_trace": r'''
onTrace = proc(tag: string) =
  onTrace = nil
  mm_timer_init()
mm_timer_set(addr timers[0], 100)
doAssert queueIds().len == 0
''',
    "replace_during_set_trace": r'''
onTrace = proc(tag: string) =
  onTrace = nil
  mm_timer_set(addr timers[0], 500)
mm_timer_set(addr timers[0], 100)
doAssert queueIds() == @[1'u] and timers[0].expiry == 500
''',
    "replace_during_second_trace": r'''
onTrace = proc(tag: string) =
  if tag == "[WIFI-NIMFW] mm_timer_set timer ":
    onTrace = nil
    mm_timer_set(addr timers[0], 500)
mm_timer_set(addr timers[0], 100)
doAssert queueIds() == @[1'u] and timers[0].expiry == 500
''',
    "other_timer_during_set": r'''
onTrace = proc(tag: string) =
  onTrace = nil
  mm_timer_set(addr timers[1], 50)
mm_timer_set(addr timers[0], 100)
doAssert queueIds() == @[2'u, 1]
''',
    "clear_during_set_read": r'''
onRead = proc() = mm_timer_clear(addr timers[0])
mm_timer_set(addr timers[0], 100)
doAssert queueIds().len == 0
''',
    "replace_head_during_hardware": r'''
mm_timer_set(addr timers[0], 100)
onHardware = proc() =
  mm_timer_clear(addr timers[0])
  mm_timer_set(addr timers[1], 500)
  now = 150
mm_timer_schedule()
doAssert delivered.len == 0 and queueIds() == @[2'u]
''',
    "rearm_head_during_hardware": r'''
mm_timer_set(addr timers[0], 100)
onHardware = proc() =
  mm_timer_set(addr timers[0], 500)
  now = 150
mm_timer_schedule()
doAssert delivered.len == 0 and queueIds() == @[1'u] and timers[0].expiry == 500
''',
    "reset_during_hardware": r'''
mm_timer_set(addr timers[0], 100)
onHardware = proc() =
  mm_timer_init()
  now = 150
mm_timer_schedule()
doAssert delivered.len == 0 and queueIds().len == 0
''',
    "clear_head_during_read": r'''
mm_timer_set(addr timers[0], 100)
mm_timer_set(addr timers[1], 500)
now = 150
onRead = proc() = mm_timer_clear(addr timers[0])
mm_timer_schedule()
doAssert delivered.len == 0 and queueIds() == @[2'u]
''',
    "reset_in_event_clear": r'''
mm_timer_set(addr timers[0], 100)
now = 150
onClearEvent = proc() = mm_timer_init()
mm_timer_schedule()
doAssert delivered.len == 0 and queueIds().len == 0
''',
    "ordering_and_update": r'''
mm_timer_set(addr timers[0], 300)
mm_timer_set(addr timers[1], 100)
mm_timer_set(addr timers[2], 200)
doAssert queueIds() == @[2'u, 3, 1]
mm_timer_set(addr timers[0], 50)
doAssert queueIds() == @[1'u, 2, 3]
now = 151
mm_timer_schedule()
doAssert delivered == @[1'u, 2, 3] and queueIds().len == 0
''',
    "clear_rearms": r'''
mm_timer_set(addr timers[0], 100)
onHardware = proc() = mm_timer_set(addr timers[0], 500)
mm_timer_clear(addr timers[0])
doAssert queueIds() == @[1'u] and timers[0].expiry == 500
''',
    "callback_rearms": r'''
mm_timer_set(addr timers[0], 100)
now = 151
onCallback = proc() = mm_timer_set(addr timers[0], 500)
mm_timer_schedule()
doAssert delivered == @[1'u] and queueIds() == @[1'u]
''',
    "retire_popped_delivery": r'''
for change in 0 .. 3:
  setup()
  mm_timer_set(addr timers[0], 100)
  now = 151
  onClearEvent = proc() =
    onRestore = proc() =
      let claim = mmTimerMutationTop
      doAssert claim != nil and claim.delivering and claim.timer == addr timers[0]
      doAssert not claim.cancelled
      case change
      of 0: mm_timer_clear(addr timers[0])
      of 1: mm_timer_set(addr timers[0], 500)
      of 2: mm_timer_init()
      else: mm_timer_set(addr timers[1], 500)
      doAssert mmTimerMutationTop == claim
      doAssert claim.cancelled == (change != 3)
  onCallback = proc() =
    doAssert mmTimerMutationTop != nil and mmTimerMutationTop.delivering
    doAssert mmTimerMutationTop.cancelled == (change != 3)
  mm_timer_schedule()
  doAssert delivered == @[1'u] and mmTimerMutationTop == nil and enabled
  let remaining = case change
    of 1: @[1'u]
    of 3: @[2'u]
    else: newSeq[uint]()
  doAssert queueIds() == remaining
''',
    "recursive_schedule_budget": r'''
proc repeat() =
  now += 100
  mm_timer_set(addr timers[0], now)
  onCallback = repeat
  mm_timer_schedule()
mm_timer_set(addr timers[0], 100)
now = 151
onCallback = repeat
mm_timer_schedule()
doAssert delivered.len == WifiTimerDrainLimit.int
doAssert queueIds() == @[1'u] and (events and KE_EVT_MM_TIMER) != 0
''',
    "callback_clears_next": r'''
mm_timer_set(addr timers[0], 100)
mm_timer_set(addr timers[1], 110)
now = 151
onCallback = proc() = mm_timer_clear(addr timers[1])
mm_timer_schedule()
doAssert delivered == @[1'u] and queueIds().len == 0
''',
    "callback_resets": r'''
mm_timer_set(addr timers[0], 100)
mm_timer_set(addr timers[1], 110)
now = 151
onCallback = proc() = mm_timer_init()
mm_timer_schedule()
doAssert delivered == @[1'u] and queueIds().len == 0
''',
    "past_deadline_and_wrap": r'''
now = 100
mm_timer_set(addr timers[0], 90)
doAssert timers[0].expiry == 3100
setup()
now = 0xFFFFFFF0'u32
mm_timer_set(addr timers[0], now + 300)
mm_timer_set(addr timers[1], now + 100)
doAssert queueIds() == @[2'u, 1]
now = 0x60
mm_timer_schedule()
doAssert delivered == @[2'u] and queueIds() == @[1'u]
''',
    "null_callback": r'''
timers[0].callback = nil
mm_timer_set(addr timers[0], 100)
mm_timer_set(addr timers[1], 110)
now = 151
mm_timer_schedule()
doAssert delivered == @[2'u] and queueIds().len == 0
''',
    "interrupt_state": r'''
for initial in [false, true]:
  setup()
  enabled = initial
  onTrace = proc(tag: string) = doAssert enabled == initial
  mm_timer_set(addr timers[0], 100)
  doAssert enabled == initial
  now = 151
  onCallback = proc() = doAssert enabled == initial
  mm_timer_schedule()
  doAssert enabled == initial and delivered == @[1'u]
''',
    "nil_inputs": r'''
mm_timer_set(nil, 100)
mm_timer_clear(nil)
doAssert queueIds().len == 0 and hardware.len == 0
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mm_timer_lifetime(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case] + "\nfinish()\n")


@pytest.mark.parametrize("action", ["clear", "replace", "reset", "insert_tail", "clear_tail", "rearm_tail"])
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mm_timer_hardware_replacement(tmp_path: Path, action: str, mode: str) -> None:
    checks = r'''
BEFORE
onTrace = proc(tag: string) =
  if tag == "[WIFI-NIMFW] mm_timer_hw_set ":
    onTrace = nil
    ACTION
mm_timer_set(addr timers[0], 100)
CHECK
finish()
'''
    before, operation, check = {
        "clear": ("", "mm_timer_clear(addr timers[0])",
                  "doAssert queueIds().len == 0 and (unmask and 0x80) == 0"),
        "replace": ("", "mm_timer_set(addr timers[1], 50)",
                    "doAssert queueIds() == @[2'u, 1] and hardwareDeadline == 50"),
        "reset": ("", "mm_timer_init()", "doAssert queueIds().len == 0 and (unmask and 0x80) == 0"),
        "insert_tail": ("", "mm_timer_set(addr timers[1], 200)",
                        "doAssert queueIds() == @[1'u, 2] and hardwareDeadline == 100 and (unmask and 0x80) != 0"),
        "clear_tail": ("mm_timer_set(addr timers[1], 200)", "mm_timer_clear(addr timers[1])",
                       "doAssert queueIds() == @[1'u] and hardwareDeadline == 100 and (unmask and 0x80) != 0"),
        "rearm_tail": ("mm_timer_set(addr timers[1], 200)", "mm_timer_set(addr timers[1], 300)",
                       "doAssert queueIds() == @[1'u, 2] and hardwareDeadline == 100 and timers[1].expiry == 300"),
    }[action]
    checks = checks.replace("BEFORE", before).replace("ACTION", operation).replace("CHECK", check)
    run_program(tmp_path, mode, source(real_hardware=True) + checks)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mm_timer_stale_snapshot_does_not_override_new_head(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_hardware=True) + r'''
onClearEvent = proc() =
  onRestore = proc() = mm_timer_set(addr timers[0], 100)
mm_timer_schedule()
doAssert queueIds() == @[1'u]
doAssert hardwareDeadline == 100 and (unmask and 0x80) != 0
mm_timer_set(addr timers[1], 50)
doAssert queueIds() == @[2'u, 1]
mm_timer_hw_set(addr timers[0])
doAssert hardwareDeadline == 50 and (unmask and 0x80) != 0
finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mm_timer_already_unmasked_writes_only_deadline(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_hardware=True) + r'''
mm_timer_set(addr timers[0], 100)
doAssert (unmask and 0x80) != 0
registerWrites.setLen(0)
mm_timer_hw_set(addr timers[0])
doAssert registerWrites == @[(MACHW_ABS_TIMER_REG, 100'u32)]
finish()
''')
