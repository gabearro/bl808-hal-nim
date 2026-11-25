"""Keep every state-transition task pending across bounded saved-message batches."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  KeMsgHdr = object
    next: ptr CoListHdr
    id: uint16
    destId, srcId: uint8
  KeTaskDesc = object
    stateCount, instanceCount: uint16
    statePtr: ptr uint16
  RxEnv = object
    processingFlag: uint8
    queue: CoList
const
  WifiSavedMsgDrainLimit = 8'u32
  KE_EVT_KE_MESSAGE = 0x08000000'u32
  MM_IDLE = 0'u8
  MAX_VIFS = 2
var
  keMsgQueueSent, keMsgQueueSaved: CoList
  keTimerQueue: CoList
  keSavedReschedTask = TASK_NONE
  keSavedReschedMask: uint16
  keSavedReschedRemaining: array[TASK_API.int, uint32]
  keTaskDescs: array[10, KeTaskDesc]
  states: array[10, uint16]
  messages: array[80, KeMsgHdr]
  nextMessage: int
  delivered: seq[uint16]
  interrupts = true
  events: uint32
  mmState: uint8
  rx: RxEnv
  nimFwDbgSavedMsgYield, nimFwDbgSavedMsgYieldTask: uint32
  freed: int
  onEvent: proc()
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc ke_evt_set(bits: uint32) =
  events = events or bits
  if onEvent != nil: onEvent()
proc ke_evt_clear(bits: uint32) = events = events and not bits
proc assert_err(condition, file: cstring; line: cint) =
  doAssert false, "unexpected task diagnostic"
proc ke_task_local(task: uint8): bool = task <= TASK_LAST_EMB
proc rxlCntrlEnvView(): ptr RxEnv = addr rx
proc encodedArgU8(p: pointer): uint8 = cast[uint](p).uint8
proc keTimerCancelMutations(all: bool) = discard
proc smActivationCancel() = discard
proc mmConfigCancelIdle() = discard
proc chanSwitchReset() = discard
proc scanRelease(failed = false) = discard
proc smRspTimerReset() = discard
template smSaQueryResetScope() = discard
proc smBssCancel() = discard
proc smCleanupCancel() = discard
proc smDeferredCancel() = discard
proc smAbandon() = discard
proc mmPsModeCancel() = discard
proc meControlReset() = discard
proc apmCancelPendingForVif(vif: uint8) = discard
proc mm_bcn_flush_updates(restore: bool) = discard
proc ke_msg_free(p: pointer) = inc freed
proc blOpsFunc(offset: int): pointer = nil
'''


def source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = (FW.parent / "fw_messages/tasks.nim").read_text() + PLATFORM
    for name in ("co_list_init", "co_list_push_back", "co_list_pop_front", "ke_init", "ke_flush", "ke_queue_extract",
                 "cmp_dest_id", "ke_saved_queue_count_dest", "keUpdateSavedReschedule", "keDrainSavedMessages",
                 "ke_reschedule_saved_messages", "ke_state_set",
                 "keResumeSavedMessagesIfIdle", "keUpdateMessageEventAfterSchedule"):
        if f"proc {name}(" in kernel or f"proc {name}*(" in kernel:
            code += procedure(kernel, name)
    code += procedure((FW / "task_init_main.nim").read_text(), "wifiMessagePendingWork")
    return code + r'''
proc setup() =
  keMsgQueueSent = default(CoList)
  keMsgQueueSaved = default(CoList)
  keSavedReschedTask = TASK_NONE
  keSavedReschedMask = 0
  keSavedReschedRemaining = default(typeof(keSavedReschedRemaining))
  states = default(typeof(states))
  messages = default(typeof(messages))
  nextMessage = 0
  delivered.setLen(0)
  events = 0
  freed = 0
  onEvent = nil
  interrupts = true
  for index in 0 ..< states.len:
    keTaskDescs[index] = KeTaskDesc(stateCount: 3, instanceCount: 1,
                                  statePtr: addr states[index])
proc save(task: uint8; count: int) =
  for _ in 0 ..< count:
    doAssert nextMessage < messages.len
    let message = addr messages[nextMessage]
    message[] = KeMsgHdr(id: nextMessage.uint16, destId: task)
    inc nextMessage
    co_list_push_back(addr keMsgQueueSaved, cast[ptr CoListHdr](message))
proc step(resave: uint8 = TASK_NONE): bool =
  keResumeSavedMessagesIfIdle()
  let node = co_list_pop_front(addr keMsgQueueSent)
  if node == nil:
    keUpdateMessageEventAfterSchedule()
    return false
  let message = cast[ptr KeMsgHdr](node)
  if message.destId == resave:
    co_list_push_back(addr keMsgQueueSaved, node)
  else:
    delivered.add(message.id)
  keUpdateMessageEventAfterSchedule()
  true
proc drain() =
  var count = 0
  while step():
    inc count
    doAssert count <= messages.len
  doAssert keMsgQueueSent.first == nil
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_two_state_transitions_keep_both_remainders(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for first in [TASK_MM, TASK_SM]:
  setup()
  save(TASK_MM, 9)
  save(TASK_SM, 9)
  let second = if first == TASK_MM: TASK_SM else: TASK_MM
  ke_state_set(first, 1)
  ke_state_set(second, 1)
  doAssert wifiMessagePendingWork()
  drain()
  doAssert delivered.len == 18, "a task's remainder was forgotten"
  doAssert keMsgQueueSaved.first == nil and keSavedReschedTask == TASK_NONE
  doAssert keSavedReschedMask == 0 and (events and KE_EVT_KE_MESSAGE) == 0
  doAssert not wifiMessagePendingWork()
  doAssert interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_busy_task_does_not_starve_other_ready_tasks(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
save(TASK_MM, 17)
save(TASK_SM, 17)
save(TASK_CFG, 9)
ke_state_set(TASK_CFG, 1)
ke_state_set(TASK_SM, 1)
ke_state_set(TASK_MM, 1)
for _ in 0 ..< 70:
  discard step(TASK_MM)
doAssert delivered.len == 26, "a re-saved task starved another pending task"
doAssert keSavedReschedTask == TASK_NONE and events == 0
doAssert not step(), "a busy message was retried without a new state transition"
ke_state_set(TASK_MM, 2)
drain()
doAssert delivered.len == 43 and keMsgQueueSaved.first == nil
doAssert keSavedReschedTask == TASK_NONE and events == 0 and interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pending_set_preserves_unready_messages_and_batch_limit(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
save(TASK_MM, 17)
save(TASK_SM, 9)
ke_state_set(TASK_MM, 1)
var sent = keMsgQueueSent.first
var count = 0
while sent != nil:
  inc count
  sent = sent.next
doAssert count == WifiSavedMsgDrainLimit.int
drain()
doAssert delivered.len == 17 and keSavedReschedTask == TASK_NONE
doAssert keMsgQueueSaved.first == cast[ptr CoListHdr](addr messages[17])
doAssert events == 0
ke_state_set(TASK_SM, 1)
drain()
doAssert delivered.len == 26 and keMsgQueueSaved.first == nil
doAssert interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_explicit_retries_do_not_lose_another_task(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
save(TASK_MM, 18)
save(TASK_SM, 10)
discard ke_reschedule_saved_messages(TASK_MM, 1)
discard ke_reschedule_saved_messages(TASK_SM, 0)
doAssert keSavedReschedTask != TASK_NONE
drain()
doAssert delivered.len == 28 and keMsgQueueSaved.first == nil
doAssert keSavedReschedTask == TASK_NONE and events == 0 and interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_clears_every_pending_task(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
save(TASK_MM, 9)
save(TASK_SM, 9)
ke_state_set(TASK_MM, 1)
ke_state_set(TASK_SM, 1)
ke_flush()
doAssert freed == 18 and events == 0
doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
doAssert keSavedReschedMask == 0 and keSavedReschedTask == TASK_NONE
for remaining in keSavedReschedRemaining: doAssert remaining == 0
keSavedReschedMask = 0x1FF
keSavedReschedTask = TASK_MM
keSavedReschedRemaining[0] = 7
ke_init()
doAssert keSavedReschedMask == 0 and keSavedReschedTask == TASK_NONE
for remaining in keSavedReschedRemaining: doAssert remaining == 0
doAssert not step() and interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_event_reentry_preserves_newer_pending_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for action in 0 .. 2:
  setup()
  save(TASK_MM, 17)
  save(TASK_SM, 9)
  onEvent = proc() =
    onEvent = nil
    case action
    of 0: ke_state_set(TASK_SM, 1)
    of 1:
      ke_state_set(TASK_MM, 2)
      ke_state_set(TASK_SM, 1)
    else: ke_flush()
  ke_state_set(TASK_MM, 1)
  drain()
  doAssert not wifiMessagePendingWork() and keSavedReschedTask == TASK_NONE
  doAssert events == 0 and interrupts
  if action == 2:
    doAssert delivered.len == 0 and freed == 26
  else:
    doAssert delivered.len == 26 and keMsgQueueSaved.first == nil
setup()
save(TASK_MM, 9)
ke_state_set(TASK_MM, 1)
let beforeMask = keSavedReschedMask
let beforeQuota = keSavedReschedRemaining
for task in [9'u8, 10'u8, 255'u8]:
  doAssert not ke_reschedule_saved_messages(task)
  doAssert keSavedReschedMask == beforeMask and keSavedReschedRemaining == beforeQuota
drain()
doAssert delivered.len == 9 and not wifiMessagePendingWork()
''')
