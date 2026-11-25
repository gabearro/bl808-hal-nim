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
  SM_SA_QUERY_TIMEOUT_IND_MSG = 0x1009'u16
  SCAN_PROBE_TIMER = 0x407'u16
  TASK_SCAN = 1'u8
  TASK_SM = 4'u8
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
    stamp: uint32
  KeTimerMutation = object
    previous: ptr KeTimerMutation
    id: uint16
    task: uint8
    cancelled: bool
var
  keTimerQueue: CoList
  keTimerMutationTop: ptr KeTimerMutation
  keTimerScheduling, keTimerExpiryCurrent: bool
  keTimerExpiryKey: tuple[id: uint16, task: uint8]
  now: uint32
  enabled = true
  failAlloc, missingAllocator: bool
  assertions, allocations, frees: int
  events: uint32
  live: seq[pointer]
  delivered: seq[tuple[id: uint16, task: uint8]]
  saExpiries: seq[uint32]
  hardware: seq[tuple[id: uint16, time: uint32]]
  onAlloc, onFree, onHardware, onMessage, onEvent: proc()
  onExpiryAlloc: proc()
  failExpiryId: uint16
  # The payload comes first: a stamped expiry's stamp is written there.
  expiringMessage: tuple[stamp: uint32, id: uint16, task: uint8]
  deliveredStamps, deliveredLengths: seq[uint32]
  expiringLength: uint32
  messageOwned: bool
  expiryMessageFrees: int
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
proc heapFree(p: pointer) {.cdecl.} =
  doAssert p != nil
  let index = live.find(p)
  doAssert index >= 0, "timer entry freed twice"
  live.delete(index)
  inc frees
  dealloc(p)
  invoke(onFree)
proc blOpsFunc(index: int): pointer =
  if index == 188: return cast[pointer](heapFree)
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
proc ke_msg_try_alloc(id: uint16; task, source: uint8; length: uint32): pointer =
  doAssert source == 0xFF and length in [0'u32, 4'u32] and not messageOwned
  if failExpiryId != 0 and id == failExpiryId: return nil
  expiringMessage = (0'u32, id, task)
  expiringLength = length
  messageOwned = true
  invoke(onExpiryAlloc)
  addr expiringMessage
proc ke_msg_alloc(id: uint16; task, source: uint8; length: uint32): pointer =
  result = ke_msg_try_alloc(id, task, source, length)
  if result == nil: assert_err("ke_msg.c", "ke_msg.c", 48)
proc keMsgHdrFromPayload(p: pointer): pointer = p
proc ke_msg_free(p: pointer) =
  doAssert p == (addr expiringMessage) and messageOwned
  messageOwned = false
  inc expiryMessageFrees
proc ke_msg_send(p: pointer) =
  doAssert p == (addr expiringMessage) and messageOwned
  delivered.add((expiringMessage.id, expiringMessage.task))
  deliveredStamps.add(expiringMessage.stamp)
  deliveredLengths.add(expiringLength)
  messageOwned = false
  invoke(onMessage)
proc smSaQueryQueueTimeout(serial: uint32) = saExpiries.add(serial)
'''

FLUSH_PLATFORM = r'''
const
  TASK_NONE = 0xFF'u8
  MAX_VIFS = 2
var
  keMsgQueueSent, keMsgQueueSaved: CoList
  keSavedReschedTask: uint8
  keSavedReschedMask: uint32
  keSavedReschedRemaining: array[10, uint32]
template smSaQueryResetScope() = discard
proc mmConfigCancelIdle() = discard
proc scanDwellReset() = discard
proc chanSwitchReset() = discard
proc smActivationCancel() = discard
proc smBssCancel() = discard
proc smCleanupCancel() = discard
proc smDeferredCancel() = discard
proc smAbandon() = discard
proc mmPsModeCancel() = discard
proc meControlReset() = discard
proc apmCancelPendingForVif(i: uint8) = discard
proc mm_bcn_flush_updates(send: bool) = discard
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
    "sa_query_keeps_serial_when_rearmed": r'''
doAssert ke_timer_try_set(SM_SA_QUERY_TIMEOUT_IND_MSG, TASK_SM, 100, stamp = 29)
onFree = proc() =
  doAssert saExpiries == @[29'u32]
  doAssert ke_timer_try_set(SM_SA_QUERY_TIMEOUT_IND_MSG, TASK_SM, 200, stamp = 30)
now = 100
ke_timer_schedule()
doAssert saExpiries == @[29'u32] and delivered.len == 0
now = 300
ke_timer_schedule()
doAssert saExpiries == @[29'u32, 30] and delivered.len == 0 and live.len == 0
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
    "locked_clear_detaches_before_free": r'''
ke_timer_set(1, 4, 100)
onFree = proc() =
  doAssert enabled and queueIds().len == 0
  ke_timer_set(1, 4, 200)
let saved = irqSave()
keTimerClearLocked(1, 4, saved)
doAssert enabled and queueIds() == @[1'u16] and deadline(1) == 200
doAssert live.len == 1
now = 201
ke_timer_schedule()
doAssert delivered == @[(1'u16, 4'u8)] and live.len == 0
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
  onExpiryAlloc = proc() = doAssert enabled == initial
  onMessage = proc() = doAssert not enabled
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
    "flush_during_expiry_allocation": r'''
ke_timer_set(1, 4, 100)
now = 100
onExpiryAlloc = proc() =
  ke_flush()
  ke_timer_set(1, 4, 200)
ke_timer_schedule()
doAssert delivered.len == 0 and expiryMessageFrees == 1 and not messageOwned
doAssert frees == 1 and live.len == 1 and deadline(1) == 300
now = 300
ke_timer_schedule()
doAssert delivered == @[(1'u16, 4'u8)] and expiryMessageFrees == 1
doAssert frees == 2 and live.len == 0
''',
    "clear_during_expiry_allocation": r'''
ke_timer_set(SCAN_PROBE_TIMER, TASK_SCAN, 100)
now = 100
onExpiryAlloc = proc() =
  doAssert not ke_timer_active(SCAN_PROBE_TIMER, TASK_SCAN)
  ke_timer_clear(SCAN_PROBE_TIMER, TASK_SCAN)
ke_timer_schedule()
doAssert delivered.len == 0, "canceled probe expiry escaped the allocator"
doAssert expiryMessageFrees == 1 and not messageOwned and live.len == 0
''',
    "rearm_during_expiry_allocation": r'''
ke_timer_set(SCAN_PROBE_TIMER, TASK_SCAN, 100)
now = 100
onExpiryAlloc = proc() = ke_timer_set(SCAN_PROBE_TIMER, TASK_SCAN, 200)
ke_timer_schedule()
doAssert delivered.len == 0, "superseded probe expiry reached the replacement dwell"
doAssert expiryMessageFrees == 1 and deadline(SCAN_PROBE_TIMER, TASK_SCAN) == 300
now = 300
ke_timer_schedule()
doAssert delivered == @[(SCAN_PROBE_TIMER, TASK_SCAN)] and live.len == 0
''',
    "unrelated_clear_during_expiry_allocation": r'''
ke_timer_set(SCAN_PROBE_TIMER, TASK_SCAN, 100)
now = 100
onExpiryAlloc = proc() =
  ke_timer_clear(SCAN_PROBE_TIMER, TASK_SM)
  ke_timer_clear(SCAN_PROBE_TIMER + 1, TASK_SCAN)
ke_timer_schedule()
doAssert delivered == @[(SCAN_PROBE_TIMER, TASK_SCAN)]
doAssert expiryMessageFrees == 0 and not messageOwned and live.len == 0
''',
    "optional_probe_expiry_out_of_memory": r'''
ke_timer_set(SCAN_PROBE_TIMER, TASK_SCAN, 100)
ke_timer_set(2, TASK_SM, 100)
failExpiryId = SCAN_PROBE_TIMER
now = 100
ke_timer_schedule()
doAssert assertions == 0, "losing an optional probe requested firmware recovery"
doAssert delivered == @[(2'u16, TASK_SM)] and not messageOwned and live.len == 0
''',
    "stamped_expiry_carries_stamp": r'''
doAssert ke_timer_try_set(2, TASK_SM, 100, stamp = 7)
ke_timer_set(3, TASK_SM, 100)
now = 100
ke_timer_schedule()
doAssert delivered == @[(2'u16, TASK_SM), (3'u16, TASK_SM)]
doAssert deliveredStamps == @[7'u32, 0] and deliveredLengths == @[4'u32, 0]
# Out of memory: the stamped expiry is retried on the same entry, stamp kept.
doAssert ke_timer_try_set(2, TASK_SM, 100, stamp = 9)
failExpiryId = 2
now = 200
ke_timer_schedule()
doAssert delivered.len == 2 and live.len == 1 and assertions == 0
failExpiryId = 0
now = 1200
ke_timer_schedule()
doAssert delivered[^1] == (2'u16, TASK_SM) and deliveredStamps[^1] == 9 and live.len == 0
''',
    "ordinary_expiry_out_of_memory": r'''
ke_timer_set(2, TASK_SM, 100)
failExpiryId = 2
now = 100
ke_timer_schedule()
# Retried on the same entry 1 ms later; no recovery, and the expiry is kept.
doAssert assertions == 0 and delivered.len == 0 and live.len == 1
doAssert cast[ptr KeTimerEntry](keTimerQueue.first).time == 1100
failExpiryId = 0
now = 1100
ke_timer_schedule()
doAssert delivered == @[(2'u16, TASK_SM)] and live.len == 0 and assertions == 0
''',
}

MUTATIONS = {
    "order": ("let diff = ta.time - tb.time", "let diff = tb.time - ta.time", "ordering"),
    "newer_mutation": ("  keTimerCancelMutations(id, task)", "  discard", "same_key_set"),
    "reset": ("if all or (operation.id == id and operation.task == task):", "if not all and (operation.id == id and operation.task == task):", "reset_during_allocation"),
    "budget": ("while drained < WifiTimerDrainLimit:", "while drained <= WifiTimerDrainLimit:", "drain_budget"),
    "unowned_expiry": ("if all or keTimerExpiryKey == (id, task):", "if all:", "rearm_during_expiry_allocation"),
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
    for name in ["ke_timer_set", "keTimerClearLocked", "ke_timer_clear", "keTimerExpired", "keTimerRequeue", "ke_timer_schedule",
                 "ke_timer_active"]:
        code += procedure(kernel, name)
    code += FLUSH_PLATFORM + procedure(kernel, "ke_flush")
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
