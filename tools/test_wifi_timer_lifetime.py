"""Exercise timer ordering, reentrant mutation, and entry ownership."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure

PLATFORM = r'''
const
  KE_TIMER_MAX_DELAY = 0x11E1A2FF'u32
  WifiTimerDrainLimit = 8'u32
  KE_EVT_KE_TIMER = 0x40'u32
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  KeTimerEntry = object
    next: ptr KeTimerEntry
    id: uint16
    taskId: uint8
    time: uint32
  KeTimerMutation = object
    previous: ptr KeTimerMutation
    id: uint16
    task: uint8
    cancelled: bool
  KeTimerGuard = proc(context: pointer): bool {.nimcall.}
var
  keTimerQueue: CoList
  keTimerMutationTop: ptr KeTimerMutation
  keTimerScheduling: bool
  now: uint32
  enabled = true
  failAlloc, missingAllocator: bool
  assertions, allocations, frees: int
  events: uint32
  live: seq[pointer]
  delivered: seq[tuple[id: uint16, task: uint8]]
  hardware: seq[tuple[id: uint16, time: uint32]]
  onAlloc, onFree, onHardware, onMessage, onEvent: proc()
  nimFwDbgKeTimerYield, nimFwDbgKeTimerYieldHead: uint32
proc invoke(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
proc irqSave(): uint32 =
  result = if enabled: 8'u32 else: 0'u32
  enabled = false
proc irqRestore(saved: uint32) = enabled = (saved and 8) != 0
proc macTimeNow(): uint32 = now
proc assert_err(a, b: cstring; line: cint) = inc assertions
proc heapAlloc(size: uint32): pointer {.cdecl.} =
  inc allocations
  if not failAlloc:
    result = alloc0(max(size.int, sizeof(KeTimerEntry)))
    live.add(result)
  invoke(onAlloc)
proc heapFree(p: pointer) =
  doAssert p != nil
  let index = live.find(p)
  doAssert index >= 0, "timer entry freed twice"
  live.delete(index)
  inc frees
  dealloc(p)
  invoke(onFree)
proc blOpsFunc(index: int): pointer =
  doAssert index == 0xB8
  if missingAllocator: return nil
  cast[pointer](heapAlloc)
template platformFree(p: pointer) = heapFree(p)
proc ke_timer_hw_set(p: ptr KeTimerEntry) =
  if p == nil: hardware.add((0'u16, 0'u32))
  else:
    doAssert live.find(p) >= 0, "hardware programming used a released timer"
    hardware.add((p.id, p.time))
  invoke(onHardware)
proc ke_evt_set(bits: uint32) =
  events = events or bits
  invoke(onEvent)
proc ke_evt_clear(bits: uint32) = events = events and not bits
proc ke_msg_send_basic(id: uint16; task, source: uint8) =
  doAssert source == 0xFF
  delivered.add((id, task))
  invoke(onMessage)
proc smRspTimerBegin(id: uint16; task: uint8; continuationUs: uint64): uint32 = 0
proc smRspTimerAbort(serial: uint32) = discard
proc smRspTimerPublish(id: uint16; task: uint8; serial: uint32;
                       entry: ptr KeTimerEntry): bool = true
proc smRspTimerClear(id: uint16; task: uint8) = discard
proc smRspTimerDispatch(entry: ptr KeTimerEntry): bool = false
'''

HELPERS = r'''
proc queueIds(): seq[uint16] =
  var node = cast[ptr KeTimerEntry](keTimerQueue.first)
  while node != nil:
    doAssert result.len < 100, "timer queue cycle"
    doAssert live.find(node) >= 0, "timer queue contains a released entry"
    result.add(node.id)
    node = node.next
proc deadline(id: uint16; task = 4'u8): uint32 =
  var node = cast[ptr KeTimerEntry](keTimerQueue.first)
  while node != nil:
    if node.id == id and node.taskId == task: return node.time
    node = node.next
  doAssert false, "timer not found"
proc flushTimers() =
  keTimerCancelMutations(all = true)
  while keTimerQueue.first != nil:
    let p = co_list_pop_front(addr keTimerQueue)
    platformFree(p)
proc finish() =
  onAlloc = nil
  onFree = nil
  onHardware = nil
  onMessage = nil
  onEvent = nil
  flushTimers()
  doAssert live.len == 0 and keTimerMutationTop == nil and not keTimerScheduling
'''

CASES = {
    "ordering": r'''
now = 1000
ke_timer_set(1, 4, 100)
ke_timer_set(2, 4, 300)
ke_timer_set(3, 4, 200)
doAssert queueIds() == @[1'u16, 3, 2], "later deadline precedes an earlier timer"
now = 1100
ke_timer_schedule()
doAssert delivered == @[(1'u16, 4'u8)]
doAssert queueIds() == @[3'u16, 2]
''',
    "same_key_set": r'''
now = 1000
onAlloc = proc() = ke_timer_set(1, 4, 200)
ke_timer_set(1, 4, 100)
doAssert queueIds() == @[1'u16] and deadline(1) == 1200,
  "older allocation replaced the newer timer"
doAssert live.len == 1
''',
    "same_key_clear": r'''
onAlloc = proc() = ke_timer_clear(1, 4)
ke_timer_set(1, 4, 100)
doAssert queueIds().len == 0 and live.len == 0,
  "older allocation revived a cleared timer"
''',
    "reset_during_allocation": r'''
onAlloc = proc() = flushTimers()
ke_timer_set(1, 4, 100)
doAssert queueIds().len == 0 and live.len == 0
''',
    "different_key": r'''
now = 1000
onAlloc = proc() = ke_timer_set(2, 4, 200)
ke_timer_set(1, 4, 100)
doAssert queueIds() == @[1'u16, 2] and live.len == 2
''',
    "different_task": r'''
onAlloc = proc() = ke_timer_set(1, 3, 200)
ke_timer_set(1, 4, 100)
doAssert queueIds() == @[1'u16, 1] and live.len == 2
doAssert deadline(1, 4) == 100 and deadline(1, 3) == 200
''',
    "clear_during_hardware": r'''
onHardware = proc() = ke_timer_clear(1, 4)
ke_timer_set(1, 4, 100)
doAssert queueIds().len == 0 and live.len == 0
''',
    "replace_during_hardware": r'''
onHardware = proc() = ke_timer_set(1, 4, 200)
ke_timer_set(1, 4, 100)
doAssert queueIds() == @[1'u16] and deadline(1) == 200 and live.len == 1
''',
    "clear_reentrant_free": r'''
ke_timer_set(1, 4, 100)
onFree = proc() = ke_timer_set(1, 4, 200)
ke_timer_clear(1, 4)
doAssert queueIds() == @[1'u16] and deadline(1) == 200 and live.len == 1
''',
    "expires_during_programming": r'''
ke_timer_set(1, 4, 100)
now = 0
onHardware = proc() = now = 101
ke_timer_schedule()
doAssert delivered == @[(1'u16, 4'u8)] and live.len == 0
''',
    "schedule_head_replacement": r'''
ke_timer_set(1, 4, 100)
onHardware = proc() =
  ke_timer_clear(1, 4)
  ke_timer_set(2, 4, 200)
ke_timer_schedule()
doAssert delivered.len == 0 and queueIds() == @[2'u16]
''',
    "message_rearms": r'''
ke_timer_set(1, 4, 10)
now = 11
onMessage = proc() = ke_timer_set(1, 4, 200)
ke_timer_schedule()
doAssert delivered == @[(1'u16, 4'u8)]
doAssert queueIds() == @[1'u16] and deadline(1) == 211 and live.len == 1
''',
    "allocation_failure": r'''
failAlloc = true
ke_timer_set(1, 4, 100)
doAssert assertions == 1 and live.len == 0 and queueIds().len == 0
''',
    "invalid_delay": r'''
ke_timer_set(1, 4, 0)
ke_timer_set(2, 4, KE_TIMER_MAX_DELAY + 1)
doAssert assertions == 2 and live.len == 0 and allocations == 0
''',
    "update": r'''
ke_timer_set(1, 4, 100)
ke_timer_set(2, 4, 200)
ke_timer_set(1, 4, 300)
doAssert queueIds() == @[2'u16, 1] and deadline(1) == 300
doAssert allocations == 2 and live.len == 2
ke_timer_set(1, 4, 50)
doAssert queueIds() == @[1'u16, 2] and allocations == 2
''',
    "equal_deadline": r'''
for id in 1'u16 .. 5:
  ke_timer_set(id, 4, 100)
doAssert queueIds() == @[1'u16, 2, 3, 4, 5]
''',
    "wrap": r'''
now = 0xFFFFFFF0'u32
ke_timer_set(1, 4, 300)
ke_timer_set(2, 4, 100)
ke_timer_set(3, 4, 200)
doAssert queueIds() == @[2'u16, 3, 1]
now = 0x60
ke_timer_schedule()
doAssert delivered == @[(2'u16, 4'u8)]
''',
    "clear_missing": r'''
ke_timer_set(1, 4, 100)
ke_timer_clear(2, 4)
ke_timer_clear(1, 3)
doAssert queueIds() == @[1'u16] and frees == 0
ke_timer_clear(1, 4)
doAssert queueIds().len == 0 and frees == 1
''',
    "drain_budget": r'''
proc rearm() =
  now += 100
  ke_timer_set(1, 4, 1)
  onMessage = rearm
onMessage = rearm
ke_timer_set(1, 4, 1)
now = 100
ke_timer_schedule()
doAssert delivered.len == WifiTimerDrainLimit.int
doAssert queueIds() == @[1'u16] and (events and KE_EVT_KE_TIMER) != 0
doAssert nimFwDbgKeTimerYield == 1
''',
    "recursive_schedule": r'''
proc rearmAndDrain() =
  now += 100
  ke_timer_set(1, 4, 1)
  onMessage = rearmAndDrain
  ke_timer_schedule()
onMessage = rearmAndDrain
ke_timer_set(1, 4, 1)
now = 100
ke_timer_schedule()
doAssert delivered.len == WifiTimerDrainLimit.int and live.len == 1
''',
    "interrupt_state": r'''
for initial in [false, true]:
  enabled = initial
  onAlloc = proc() = doAssert enabled == initial
  ke_timer_set(1, 4, 100)
  doAssert enabled == initial
  onFree = proc() = doAssert enabled == initial
  ke_timer_clear(1, 4)
  doAssert enabled == initial
  ke_timer_set(1, 4, 100)
  now += 101
  onMessage = proc() = doAssert enabled == initial
  onFree = proc() = doAssert enabled == initial
  ke_timer_schedule()
  doAssert enabled == initial and live.len == 0
enabled = true
''',
    "ordered_boundaries": r'''
for base in [0'u32, 0x7FFFFFFF'u32, 0xFFFFFF00'u32]:
  now = base
  for index, delay in [300'u32, 1000, 100, 500, 100, KE_TIMER_MAX_DELAY]:
    ke_timer_set((index + 1).uint16, 4, delay)
  doAssert queueIds() == @[3'u16, 5, 1, 4, 2, 6]
  flushTimers()
''',
    "new_head_during_clear": r'''
ke_timer_set(1, 4, 100)
ke_timer_set(2, 4, 200)
onHardware = proc() =
  ke_timer_clear(2, 4)
  ke_timer_set(3, 4, 300)
ke_timer_clear(1, 4)
doAssert queueIds() == @[3'u16] and assertions == 0
''',
    "fallible_set": r'''
failAlloc = true
doAssert not ke_timer_try_set(1, 4, 100)
doAssert assertions == 0 and live.len == 0
failAlloc = false
doAssert ke_timer_try_set(1, 4, 100)
doAssert not ke_timer_try_set(2, 4, 0)
doAssert queueIds() == @[1'u16]
''',
    "missing_allocator": r'''
missingAllocator = true
ke_timer_set(1, 4, 100)
doAssert assertions == 1 and allocations == 0 and live.len == 0
''',
    "guard_rejected": r'''
var valid = false
proc current(p: pointer): bool = cast[ptr bool](p)[]
doAssert not ke_timer_try_set(1, 4, 100, current, addr valid)
doAssert allocations == 0 and live.len == 0 and queueIds().len == 0
''',
    "guard_after_allocation": r'''
var valid = true
proc current(p: pointer): bool = cast[ptr bool](p)[]
onAlloc = proc() = valid = false
doAssert not ke_timer_try_set(1, 4, 100, current, addr valid)
doAssert allocations == 1 and live.len == 0 and queueIds().len == 0
''',
    "guard_after_publication": r'''
var valid = true
proc current(p: pointer): bool = cast[ptr bool](p)[]
ke_timer_set(2, 4, 200)
onHardware = proc() = valid = false
doAssert not ke_timer_try_set(1, 4, 100, current, addr valid)
doAssert queueIds() == @[2'u16] and live.len == 1
doAssert hardware[^1] == (2'u16, 200'u32)
''',
    "guard_preserves_replacement": r'''
var valid = true
proc current(p: pointer): bool = cast[ptr bool](p)[]
onHardware = proc() =
  valid = false
  ke_timer_set(1, 4, 300)
doAssert not ke_timer_try_set(1, 4, 100, current, addr valid)
doAssert queueIds() == @[1'u16] and deadline(1) == 300 and live.len == 1
''',
    "guard_during_retirement": r'''
var valid = true
proc current(p: pointer): bool = cast[ptr bool](p)[]
onAlloc = proc() = valid = false
onFree = proc() = ke_timer_set(1, 4, 300)
doAssert not ke_timer_try_set(1, 4, 100, current, addr valid)
doAssert queueIds() == @[1'u16] and deadline(1) == 300 and live.len == 1
''',
}

MUTATIONS = {
    "order": ("let diff = ta.time - tb.time", "let diff = tb.time - ta.time", "ordering"),
    "newer_mutation": ("  keTimerCancelMutations(id, task)", "  discard", "same_key_set"),
    "reset": ("if all or (operation.id == id and operation.task == task):", "if not all and (operation.id == id and operation.task == task):", "reset_during_allocation"),
    "budget": ("while drained < WifiTimerDrainLimit:", "while drained <= WifiTimerDrainLimit:", "drain_budget"),
}


def program_source(mutation: str = "") -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = PLATFORM
    for name in ["co_list_pop_front", "co_list_insert", "ke_queue_extract",
                 "cmp_abs_time", "cmp_timer_id"]:
        code += procedure(kernel, name).split("\nconst\n", 1)[0] + "\n"
    for name in ["keTimerCancelMutations", "keTimerBeginMutation", "keTimerEndMutation", "ke_timer_try_set"]:
        if "proc " + name in kernel:
            code += procedure(kernel, name)
    if "proc keTimerCancelMutations" not in kernel:
        code += "\nproc keTimerCancelMutations(id = 0'u16; task = 0'u8; all = false) = discard\n"
    for name in ["ke_timer_set", "ke_timer_clear", "keTimerExpired", "ke_timer_schedule", "ke_timer_active"]:
        code += procedure(kernel, name)
    code += HELPERS
    if mutation:
        old, new, _ = MUTATIONS[mutation]
        assert code.count(old) == 1
        code = code.replace(old, new, 1)
    return code


def run_case(tmp_path: Path, case: str, mode: str, mutation: str = "") -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "timer.nim"
    path.write_text(program_source(mutation) + "\n" + CASES[case] + "\nfinish()\n")
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}[mode]
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--checks:on", *flags, f"--nimcache:{tmp_path / 'cache'}",
        f"-o:{tmp_path / 'check'}", str(path)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if mutation:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
    else:
        assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_timer_lifetime(tmp_path: Path, case: str, mode: str) -> None:
    run_case(tmp_path, case, mode)


@pytest.mark.parametrize("mutation", MUTATIONS)
def test_timer_guards(tmp_path: Path, mutation: str) -> None:
    run_case(tmp_path, MUTATIONS[mutation][2], "checked", mutation)


def test_timer_reset_hooks() -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ["ke_init", "ke_flush"]:
        assert "keTimerCancelMutations(all = true)" in procedure(kernel, name)
