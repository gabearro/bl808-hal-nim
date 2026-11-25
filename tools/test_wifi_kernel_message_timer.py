"""Exercise kernel reply ownership and overdue timer-head handoff."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def reply_source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    return r'''
type KeMsgHdr = object
  next: pointer
  id: uint16
  destId, srcId: uint8
  paramLen: uint32
type Message = object
  header: KeMsgHdr
  payload: array[4, uint8]
var
  request: Message
  replyByte: uint8
  meControlCommand, apmStartRequest: pointer
  smOwns, cleanupOwns: bool
  meCalls, apmCalls, genericCalls, ownerLookups: int
  smCalls, cleanupCalls: int
  rejectOwner: bool
  allocatedId: uint16
  allocatedDest, allocatedSrc: uint8
  allocatedLength: uint32
proc payload(): pointer = addr request.payload[0]
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  doAssert p == payload()
  addr request.header
proc meTakeControlReply(p: pointer; id: uint16; length: uint32): pointer =
  inc meCalls
  doAssert p == payload()
  if rejectOwner: return nil
  addr replyByte
proc smAwaits(p: pointer): bool =
  inc ownerLookups
  smOwns
proc smCleanupOwnsRequest(p: pointer): bool =
  inc ownerLookups
  cleanupOwns
proc smTakeReply(p: pointer; id: uint16): pointer =
  inc smCalls
  if rejectOwner: nil else: addr replyByte
proc smCleanupTakeReply(p: pointer; id: uint16; length: uint32): pointer =
  inc cleanupCalls
  if rejectOwner: nil else: addr replyByte
proc apmTakeStartReply(p: pointer; id: uint16; length: uint32): pointer =
  inc apmCalls
  if rejectOwner: nil else: addr replyByte
proc ke_msg_alloc(id: uint16; dest, src: uint8; length: uint32): pointer =
  inc genericCalls
  allocatedId = id
  allocatedDest = dest
  allocatedSrc = src
  allocatedLength = length
  addr replyByte
proc reset() =
  meControlCommand = nil
  apmStartRequest = nil
  smOwns = false
  cleanupOwns = false
  meCalls = 0
  apmCalls = 0
  genericCalls = 0
  ownerLookups = 0
  smCalls = 0
  cleanupCalls = 0
  rejectOwner = false
  request.header = KeMsgHdr(id: 0x1234, destId: 3, srcId: 9, paramLen: 4)
''' + procedure(kernel, "ke_msg_alloc_reply")


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_owned_reply_rejection_never_falls_back(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, reply_source() + r'''
reset()
meControlCommand = payload()
rejectOwner = true
doAssert ke_msg_alloc_reply(payload(), 0x1235, 0) == nil
doAssert meCalls == 1 and ownerLookups == 0 and genericCalls == 0

reset()
apmStartRequest = payload()
rejectOwner = true
doAssert ke_msg_alloc_reply(payload(), 0x1401, 1) == nil
doAssert apmCalls == 1 and genericCalls == 0

for owner in 0 .. 1:
  reset()
  rejectOwner = true
  if owner == 0: smOwns = true
  else: cleanupOwns = true
  doAssert ke_msg_alloc_reply(payload(), 0x1235, 0) == nil
  doAssert genericCalls == 0 and meCalls == 0
  doAssert smCalls + cleanupCalls == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_unowned_and_accepted_replies_keep_routing(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, reply_source() + r'''
reset()
doAssert ke_msg_alloc_reply(payload(), 0x1235, 2) == addr replyByte
doAssert genericCalls == 1 and allocatedId == 0x1235
doAssert allocatedDest == 9 and allocatedSrc == 3 and allocatedLength == 2

reset()
meControlCommand = payload()
doAssert ke_msg_alloc_reply(payload(), 0x1235, 0) == addr replyByte
doAssert meCalls == 1 and genericCalls == 0 and ownerLookups == 0

reset()
doAssert ke_msg_alloc_reply(nil, 0x1235, 0) == nil
doAssert meCalls == 0 and genericCalls == 0 and ownerLookups == 0
''')


def timer_source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    return r'''
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
const KE_EVT_KE_TIMER = 0x20000000'u32
var
  keTimerQueue: CoList
  keTimerMutationTop: ptr KeTimerMutation
  first, second: KeTimerEntry
  now, events, hardwareTarget: uint32
  frees, diagnostics: int
  interrupts = true
proc irqSave(): uint32 =
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = saved != 0
proc cmp_timer_id(elem: ptr CoListHdr; param: pointer): bool {.cdecl.} =
  let entry = cast[ptr KeTimerEntry](elem)
  let key = cast[uint](param).uint32
  entry.id == (key shr 16).uint16 and entry.taskId == (key and 0xFF).uint8
proc ke_queue_extract(queue: ptr CoList;
                      cmpFn: proc(elem: ptr CoListHdr; param: pointer): bool {.cdecl.};
                      param: pointer): ptr CoListHdr =
  doAssert not interrupts and queue.first != nil and cmpFn(queue.first, param)
  result = queue.first
  queue.first = result.next
  if queue.first == nil: queue.last = nil
  result.next = nil
proc ke_timer_hw_set(entry: ptr KeTimerEntry) =
  doAssert not interrupts
  hardwareTarget = if entry == nil: 0'u32 else: entry.time
proc macTimeNow(): uint32 = now
proc ke_evt_set(bit: uint32) =
  doAssert bit == KE_EVT_KE_TIMER and not interrupts
  events = events or bit
proc assert_err(condition, file: cstring; line: cint) =
  doAssert line == 214
  inc diagnostics
proc platformFree(p: pointer) =
  doAssert p == (addr first) and interrupts
  inc frees
proc setup(secondTime, currentTime: uint32) =
  first = KeTimerEntry(id: 0x40, taskId: 3, time: 100)
  second = KeTimerEntry(id: 0x41, taskId: 3, time: secondTime)
  first.next = addr second
  keTimerQueue = CoList(first: cast[ptr CoListHdr](addr first),
                        last: cast[ptr CoListHdr](addr second))
  keTimerMutationTop = nil
  now = currentTime
  events = 0
  hardwareTarget = 100
  frees = 0
  diagnostics = 0
  interrupts = true
''' + "\n".join(procedure(kernel, name) for name in (
        "keTimerCancelMutations", "keTimerBeginMutation",
        "keTimerEndMutation", "keTimerClearLocked", "ke_timer_clear"))


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_clear_head_schedules_overdue_successor(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, timer_source() + r'''
setup(200, 250)
ke_timer_clear(0x40, 3)
doAssert events == KE_EVT_KE_TIMER and hardwareTarget == 200
doAssert diagnostics == 1 and frees == 1 and interrupts
doAssert keTimerMutationTop == nil
doAssert keTimerQueue.first == cast[ptr CoListHdr](addr second)

setup(200, 150)
ke_timer_clear(0x40, 3)
doAssert events == 0 and hardwareTarget == 200
doAssert diagnostics == 0 and frees == 1 and interrupts
''')
