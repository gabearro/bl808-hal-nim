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
var
  mm_timer_list: CoList
  mmTimerRevision: uint32
  timers: array[4, MmTimerElemView]
  now, events, hardwareDeadline, unmask: uint32
  enabled = true
  hardware: seq[tuple[index: int, expiry: uint32]]
  delivered: seq[uint]
  onRead, onHardware, onClearEvent, onSetEvent, onCallback: proc()
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
proc irqRestore(saved: uint32) = enabled = (saved and 8) != 0
proc regRead(address: uint): uint32 =
  if address == MACHW_TIMLO_REG:
    result = now
    invoke(onRead)
  elif address == MACHW_ABS_TIMER_REG: result = hardwareDeadline
  else: result = unmask
proc regWrite(address: uint; value: uint32) =
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
  onTrace = nil
  mm_timer_init()
  when declared(mmTimerMutationTop): doAssert mmTimerMutationTop == nil
  when declared(mmTimerScheduling): doAssert not mmTimerScheduling
setup()
'''


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
mm_timer_set(addr timers[0], 100)
onHardware = proc() = now = 151
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
