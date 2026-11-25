"""Replay station teardown's real MM retry timer and dispatch handler."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_mm_timer_lifetime import source as mm_timer_source


PLATFORM = r'''
const
  TASK_MM = 0'u8
  TASK_SM = 4'u8
  MM_STA_DEL_REQ = 12'u16
  MM_STA_DEL_CFM = 13'u16
  STA_MGMT_FREE_STAS = 5
  MmStaDelReqPayloadSize = 1'u32
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint
type
  KeMsgHdr = object
    link: CoListHdr
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Payload = object
    staIdx: uint8
  Request = object
    hdr: KeMsgHdr
    payload: Payload
var
  failures: array[STA_MGMT_FREE_STAS, int]
  stationEpochs: array[STA_MGMT_FREE_STAS, uint32]
  mmStaDelRetryEpochs: array[STA_MGMT_FREE_STAS, uint32]
  attempts: seq[uint8]
  afterAttempt: proc()
  wakes: int
  keMsgQueueSaved, sent: CoList
  request: Request
proc macTimeNow(): uint32 = now
proc staDeleteEpoch(index: uint8): uint32 = stationEpochs[index]
proc txlResetting(): bool = false
proc smStaleRequest(p: pointer): bool = false
proc smCleanupAdmitRequest(p: pointer): bool = true
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - offsetof(Request, payload).uint)
proc mmStaDelReqView(p: pointer): ptr Payload = cast[ptr Payload](p)
proc ke_msg_send(p: pointer) =
  co_list_push_back(addr sent, cast[ptr CoListHdr](keMsgHdrFromPayload(p)))
proc mmStaDelTry(index: uint8; saved: uint32): bool =
  doAssert not enabled
  attempts.add(index)
  irqRestore(saved)
  try: invoke(afterAttempt)
  finally: discard irqSave()
  if failures[index] == 0: return true
  dec failures[index]
  false
proc ke_reschedule_saved_messages(task: uint8): bool =
  doAssert task == TASK_MM
  inc wakes
  while keMsgQueueSaved.first != nil:
    co_list_push_back(addr sent, co_list_pop_front(addr keMsgQueueSaved))
    result = true
proc mmStaDelRetryCb(env: pointer) {.cdecl.}
'''

CASES = {
    "coalesced_deadline": r'''
now = high(uint32) - 15000
mmStaDelQueueRetry(2)
let firstDue = now + 100000'u32
doAssert mmStaDelRetryTimer.expiry == firstDue
for i in 0 ..< 4:
  now += 10000
  mmStaDelQueueRetry((i mod 2 + 2).uint8)
  doAssert mmStaDelRetryTimer.expiry == firstDue, "later delete deferred earlier retry"
now = firstDue
mm_timer_schedule()
doAssert attempts == @[2'u8, 3] and mmStaDelRetryMask == 0
doAssert mm_timer_list.first == nil
''',
    "expiry_before_handler_returns": r'''
request.hdr = KeMsgHdr(id: MM_STA_DEL_REQ, destId: TASK_MM,
                        srcId: TASK_SM, paramLen: 1)
request.payload.staIdx = 2
failures[2] = 1
onHardware = proc() =
  now = mmStaDelRetryTimer.expiry
  mm_timer_schedule()
let handled = mm_sta_del_req_handler(addr request.payload)
if handled == KeMsgSaved: co_list_push_back(addr keMsgQueueSaved, addr request.hdr.link)
doAssert attempts == @[2'u8, 2] and mm_timer_list.first == nil
doAssert sent.first == addr request.hdr.link, "expiry missed the save publication"
doAssert keMsgQueueSaved.first == nil
discard co_list_pop_front(addr sent)
doAssert mm_sta_del_req_handler(addr request.payload) == KeMsgNoFree
doAssert sent.first == (addr request.hdr.link) and sent.last == sent.first
doAssert request.hdr.id == MM_STA_DEL_CFM and request.hdr.paramLen == 0
doAssert request.hdr.srcId == TASK_MM and request.hdr.destId == TASK_SM
''',
    "popped_before_reset": r'''
mmStaDelQueueRetry(2)
now = mmStaDelRetryTimer.expiry
onClearEvent = proc() =
  onRestore = proc() =
    mm_timer_init()
    mmStaDelQueueRetry(3)
mm_timer_schedule()
doAssert attempts.len == 0, "old popped expiry spent the replacement retry"
doAssert mmStaDelRetryMask == 8 and mmStaDelRetryTimer.expiry == 200000
now = 200000
mm_timer_schedule()
doAssert attempts == @[3'u8] and mmStaDelRetryMask == 0
doAssert mm_timer_list.first == nil
''',
    "slot_reused_before_expiry": r'''
mmStaDelQueueRetry(2)
mmStaDelQueueRetry(3)
inc stationEpochs[2]
now = mmStaDelRetryTimer.expiry
mm_timer_schedule()
doAssert attempts == @[3'u8], "retry reached a reused station index"
doAssert mmStaDelRetryMask == 0 and mm_timer_list.first == nil
''',
    "reset_after_first_retry": r'''
mmStaDelQueueRetry(2)
mmStaDelQueueRetry(3)
failures[2] = 1
now = mmStaDelRetryTimer.expiry
afterAttempt = proc() =
  mm_timer_init()
  mmStaDelQueueRetry(3)
mm_timer_schedule()
doAssert attempts == @[2'u8], "old retry batch continued after MM reset"
doAssert wakes == 0, "old retry batch woke new MM work"
doAssert mmStaDelRetryMask == 8 and mmStaDelRetryTimer.expiry == 200000
now = 200000
mm_timer_schedule()
doAssert attempts == @[2'u8, 3] and wakes == 1 and mmStaDelRetryMask == 0
''',
    "slot_reused_after_first_retry": r'''
mmStaDelQueueRetry(2)
mmStaDelQueueRetry(3)
now = mmStaDelRetryTimer.expiry
afterAttempt = proc() =
  inc stationEpochs[3]
  mmStaDelQueueRetry(3)
mm_timer_schedule()
doAssert attempts == @[2'u8], "old batch reached the replacement before its own expiry"
doAssert mmStaDelRetryMask == 8 and mmStaDelRetryTimer.expiry == 200000
now = 200000
mm_timer_schedule()
doAssert attempts == @[2'u8, 3] and mmStaDelRetryMask == 0
''',
    "rearm_preserves_remaining_batch": r'''
mmStaDelQueueRetry(2)
mmStaDelQueueRetry(3)
failures[2] = 1
now = mmStaDelRetryTimer.expiry
mm_timer_schedule()
doAssert attempts == @[2'u8, 3] and mmStaDelRetryMask == 4
doAssert mmStaDelRetryTimer.expiry == 200000
now = 200000
mm_timer_schedule()
doAssert attempts == @[2'u8, 3, 2] and mmStaDelRetryMask == 0
''',
}


@pytest.mark.parametrize("mode", ["checked", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_station_delete_retry(tmp_path: Path, mode: str, case: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    code = mm_timer_source() + procedure(kernel, "co_list_push_back") + PLATFORM
    code += procedure(kernel, "mmTimerActiveDelivery")
    code += procedure(kernel, "ke_msg_forward_and_change_id")
    code += procedure(kernel, "mmStaDelRetryPending")
    code += procedure(kernel, "mmStaDelQueueRetryLocked")
    code += """
proc mmStaDelQueueRetry(index: uint8) =
  let saved = irqSave()
  defer: irqRestore(saved)
  mmStaDelQueueRetryLocked(index, saved)
"""
    code += procedure(kernel[kernel.index("proc mm_sta_del*"):], "mmStaDelRetryCb")
    code += procedure(tasks, "mm_sta_del_req_handler")
    run_program(tmp_path, mode, code + CASES[case])
