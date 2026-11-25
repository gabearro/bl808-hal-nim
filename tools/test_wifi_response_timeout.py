"""Exercise the SM auth/assoc response deadline through the real kernel timer.

The deadline belongs to the SM operation that armed it (smArmResponse): the
kernel timer entry keeps the operation's stamp and the SM_RSP_TIMEOUT_IND it
posts carries it. sm_rsp_timeout_ind_handler acts only on an expiry whose
stamp is the live operation's, so leaving state 6 or 8 (any smGo) makes an
earlier deadline stale, and nothing else does.
"""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure, station_sm_source
from test_wifi_message_allocation import run_program


PLATFORM = r'''
{.pragma: wifiCtrl.}
const
  MAX_VIFS = 2
  TASK_SCAN = 1'u8
  TASK_SM = 4'u8
  SCAN_PROBE_TIMER = 0x407'u16
  SM_RSP_TIMEOUT_IND = 0x1006'u16
  SM_SA_QUERY_TIMEOUT_IND_MSG = 0x1009'u16
  SmIdleState = 0'u16
  SmAuthenticatingState = 6'u16
  SmAssocRspState = 8'u16
  SmDisconnectingState = 10'u16
  WLAN_FW_AUTH_OR_ASSOC_RESPONSE_TIMEOUT_FAILURE = 11'u16
  MACHW_RX_CNTRL_REG = 0'u
  KE_TIMER_MAX_DELAY = 0x11E1A2FF'u32
  WifiTimerDrainLimit = 8'u32
  KE_EVT_KE_TIMER = 0x20000000'u32
  KE_EVT_KE_MESSAGE = 0x08000000'u32
  KeMsgConsumed = 0.cint
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
  KeMsgHdr = object
    next: ptr CoListHdr
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Connection = object
    vifIdx, retry: uint8
  Callbacks = object
    authTimeout: pointer
var
  connection, replacement: Connection
  sm: tuple[connectInfo: pointer, authRetryLimit: uint32]
  callbacks: Callbacks
  wpa_cbs: pointer
  state: uint16
  now, events: uint32
  enabled = true
  live: seq[pointer]
  keTimerQueue, messages: CoList
  keTimerMutationTop: ptr KeTimerMutation
  keTimerScheduling, keTimerExpiryCurrent: bool
  keTimerExpiryKey: tuple[id: uint16, task: uint8]
  rxVifEpochs: array[2, uint32]
  txResetEpoch: uint32
  stationEpochs: array[7, uint32]
  authRetries, assocRetries, callbackCalls, failures, reads, allocations: int
  allocationFailures: int
  failAlloc: bool
  onAlloc, onFree, onMessage, onTimeout: proc()
  nimFwDbgKeTimerYield, nimFwDbgKeTimerYieldHead: uint32
  nimFwDbgSmRspTimeout, nimFwDbgSmRspTimeoutState, nimFwDbgSmRspTimeoutRxCtrl: uint32
  nimFwDbgAuthCfmAckOk16, nimFwDbgAssocReqSend, nimFwDbgAssocCfmAckOk23: uint32
  nimFwDbgAuthOpenSuccess: uint32
  authFallback, assocFallback: int
proc invoke(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
proc irqSave(): uint32 =
  result = if enabled: 8'u32 else: 0'u32
  enabled = false
proc irqRestore(saved: uint32) = enabled = (saved and 8) != 0
proc heapAlloc(size: uint32): pointer {.cdecl.} =
  inc allocations
  if not failAlloc:
    result = alloc0(size.int)
    live.add(result)
  invoke(onAlloc)
proc heapFree(p: pointer) =
  let index = live.find(p)
  doAssert index >= 0, "allocation released twice"
  live.delete(index)
  dealloc(p)
  invoke(onFree)
proc blOpsFunc(index: int): pointer =
  doAssert index == 0xB8
  cast[pointer](heapAlloc)
template platformFree(p: pointer) = heapFree(p)
proc smEnvView(): ptr typeof(sm) = addr sm
proc connectInfoAuthRetry(p: pointer): ptr uint8 = addr cast[ptr Connection](p).retry
proc macTimeNow(): uint32 = now
proc ke_state_get(task: uint8): uint16 = state
proc ke_state_set(task: uint8; value: uint16) =
  doAssert task == TASK_SM
  state = value
proc assert_err(a, b: cstring; line: cint) =
  doAssert (a == "ke_msg.c" and line == 48) or (a == "ke_timer.c" and line == 128)
  inc allocationFailures
proc ke_timer_hw_set(p: ptr KeTimerEntry) = discard
proc ke_evt_set(bits: uint32) = events = events or bits
proc ke_evt_clear(bits: uint32) = events = events and not bits
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc keMsgPayload(p: ptr KeMsgHdr): pointer = cast[pointer](cast[uint](p) + sizeof(KeMsgHdr).uint)
proc smSaQueryQueueTimeout(serial: uint32) = doAssert false
proc ke_msg_free(p: pointer) = heapFree(p)
proc ke_msg_try_alloc(id: uint16; destId, srcId: uint8; length: uint32): pointer =
  let p = cast[ptr KeMsgHdr](heapAlloc(sizeof(KeMsgHdr).uint32 + length))
  if p == nil: return nil
  p.id = id
  p.destId = destId
  p.srcId = srcId
  p.paramLen = length
  keMsgPayload(p)
proc ke_msg_alloc(id: uint16; destId, srcId: uint8; length: uint32): pointer =
  result = ke_msg_try_alloc(id, destId, srcId, length)
  if result == nil: inc allocationFailures
proc co_list_push_back*(list: ptr CoList; elem: ptr CoListHdr) {.exportc, cdecl, noinline.}
proc ke_msg_send(p: pointer) =
  co_list_push_back(addr messages, cast[ptr CoListHdr](keMsgHdrFromPayload(p)))
  ke_evt_set(KE_EVT_KE_MESSAGE)
  invoke(onMessage)
proc regRead(address: uint): uint32 =
  inc reads
  0
proc nimFwTrace2U32(label: string; a, b: uint32) = discard
proc nimFwConnectTrace2U32(label: string; a, b: uint32) = discard
proc wpaCallbacks(): ptr Callbacks = addr callbacks
proc authTimeout() {.cdecl.} =
  inc callbackCalls
  invoke(onTimeout)
proc sm_connect_ind(status, reason: uint16) =
  doAssert status == 11 and reason == 0xFFFF
  inc failures
proc sm_auth_handler(p: pointer) = inc authFallback
proc sm_assoc_done(aid: uint16) = inc assocFallback
'''

SENDERS = r'''
proc resend(waiting: uint16) =
  # sm_auth_send / sm_assoc_req_send: a new operation in the waiting state,
  # with its own deadline.
  doAssert smArmResponse(smGo(waiting), 0x7D000)
proc sm_auth_send_pre(sequence: uint16; challenge: pointer) =
  inc authRetries
  resend(SmAuthenticatingState)
proc sm_assoc_req_send_pre() =
  inc assocRetries
  resend(SmAssocRspState)
'''

HELPERS = r'''
proc setup(waiting = SmAuthenticatingState) =
  doAssert live.len == 0
  connection = Connection(vifIdx: 1)
  replacement = Connection(vifIdx: 1)
  sm = (connectInfo: cast[pointer](addr connection), authRetryLimit: 3'u32)
  callbacks.authTimeout = cast[pointer](authTimeout)
  wpa_cbs = addr callbacks
  smOwn = default(typeof(smOwn))
  state = SmIdleState
  now = 100
  authRetries = 0
  assocRetries = 0
  callbackCalls = 0
  failures = 0
  reads = 0
  authFallback = 0
  assocFallback = 0
  failAlloc = false
  discard smGo(waiting)
proc arm(delayUs = 50'u64): uint32 =
  ## The waiting state's sender: a new operation and its deadline.
  result = smGo(state)
  doAssert smArmResponse(result, delayUs)
proc takeMessage(): pointer =
  let node = co_list_pop_front(addr messages)
  doAssert node != nil
  keMsgPayload(cast[ptr KeMsgHdr](node))
proc expire(): pointer =
  ## Run the clock to the queued deadline and return its posted expiry.
  let timer = cast[ptr KeTimerEntry](keTimerQueue.first)
  doAssert timer != nil and timer.id == SM_RSP_TIMEOUT_IND
  now = timer.time
  ke_timer_schedule()
  takeMessage()
proc deliver(p: pointer) =
  doAssert sm_rsp_timeout_ind_handler(p) == KeMsgConsumed
  ke_msg_free(keMsgHdrFromPayload(p))
proc replaceAttempt() =
  ## A later attempt reaches state 6 and arms its own deadline.
  sm.connectInfo = addr replacement
  discard smGo(SmIdleState)
  doAssert smArmResponse(smGo(SmAuthenticatingState), 200)
proc finish() =
  onAlloc = nil
  onFree = nil
  onMessage = nil
  onTimeout = nil
  while keTimerQueue.first != nil: heapFree(co_list_pop_front(addr keTimerQueue))
  while messages.first != nil: ke_msg_free(co_list_pop_front(addr messages))
  doAssert live.len == 0 and keTimerMutationTop == nil and not keTimerScheduling
'''


def source() -> str:
    code = PLATFORM
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ["co_list_pop_front", "co_list_insert", "co_list_push_back", "ke_queue_extract",
                 "cmp_abs_time", "cmp_timer_id", "keTimerCancelMutations", "keTimerBeginMutation",
                 "keTimerEndMutation", "ke_timer_try_set", "ke_timer_set", "keTimerClearLocked", "ke_timer_clear",
                 "keTimerExpired", "keTimerRequeue", "ke_timer_schedule", "ke_timer_active"]:
        code += procedure(kernel, name).split("\nconst\n", 1)[0] + "\n"
    code += station_sm_source("smGo", "smArmResponse", "smResponseExpiry") + SENDERS
    code += procedure((FW / "task_handlers.nim").read_text(), "sm_rsp_timeout_ind_handler")
    return code + HELPERS


CASES = {
    "valid_retry_and_failure": r'''
setup()
let stamp = arm()
let expiry = expire()
let header = keMsgHdrFromPayload(expiry)
doAssert header.id == SM_RSP_TIMEOUT_IND and header.destId == TASK_SM
doAssert header.srcId == 0xFF and header.paramLen == 4
doAssert cast[ptr uint32](expiry)[] == stamp
deliver(expiry)
doAssert authRetries == 1 and connection.retry == 1 and callbackCalls == 1
connection.retry = 3
deliver(expire())
doAssert failures == 1 and authRetries == 1 and callbackCalls == 1
''',
    "association_retry": r'''
setup(SmAssocRspState)
discard arm()
deliver(expire())
doAssert assocRetries == 1 and authRetries == 0 and connection.retry == 1
doAssert callbackCalls == 0 and state == SmAssocRspState
''',
    "earlier_operation_is_stale": r'''
# Every state change, a re-entry of the same state included, ends the wait.
for next in [SmIdleState, SmAuthenticatingState, SmAssocRspState, SmDisconnectingState]:
  setup()
  discard arm()
  let old = expire()
  discard smGo(next)
  deliver(old)
  doAssert authRetries == 0 and assocRetries == 0 and failures == 0
  doAssert connection.retry == 0 and reads == 0
  finish()
''',
    "restart_retires_queued_deadline": r'''
# A deauth in state 6 restarts authentication while the old expiry is queued.
setup()
discard arm()
let old = expire()
discard arm(200)
deliver(old)
doAssert authRetries == 0 and connection.retry == 0 and reads == 0
deliver(expire())
doAssert authRetries == 1 and connection.retry == 1
''',
    "clear_then_transition": r'''
# A response clears the deadline, as in the blob, then takes its transition.
# ke_timer_clear cannot recall an expiry already posted; the transition does.
setup()
discard arm()
let old = expire()
ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
discard smGo(SmAssocRspState)
deliver(old)
doAssert authRetries == 0 and assocRetries == 0 and connection.retry == 0
''',
    "deadline_ignores_tx_and_slot_epochs": r'''
# SMCONN-F1 / txrx F2: a TX reset, or any slot epoch, is not the attempt.
setup()
discard arm()
inc txResetEpoch
inc rxVifEpochs[1]
inc stationEpochs[2]
deliver(expire())
doAssert authRetries == 1 and connection.retry == 1
''',
    "duplicate_and_untracked": r'''
setup()
discard arm()
let event = expire()
doAssert sm_rsp_timeout_ind_handler(event) == KeMsgConsumed
doAssert sm_rsp_timeout_ind_handler(event) == KeMsgConsumed
doAssert authRetries == 1 and connection.retry == 1
ke_msg_free(keMsgHdrFromPayload(event))
let untracked = ke_msg_alloc(SM_RSP_TIMEOUT_IND, TASK_SM, 0xFF, 0)
deliver(untracked)
doAssert authRetries == 1 and connection.retry == 1
doAssert sm_rsp_timeout_ind_handler(nil) == KeMsgConsumed and authRetries == 1
''',
    "wrong_payload_length": r'''
setup()
discard arm()
let p = expire()
let h = keMsgHdrFromPayload(p)
for length in [0'u32, 3, 5]:
  h.paramLen = length
  doAssert sm_rsp_timeout_ind_handler(p) == 0 and authRetries == 0
h.paramLen = 4
deliver(p)
doAssert authRetries == 1
''',
    "stale_stamp_is_not_armed": r'''
setup()
let stale = smOwn.op.serial
discard smGo(SmAuthenticatingState)
doAssert not smArmResponse(stale, 100)
doAssert live.len == 0 and keTimerQueue.first == nil
''',
    "callback_ends_attempt": r'''
setup()
discard arm()
onTimeout = proc() = discard smGo(SmDisconnectingState)
deliver(expire())
doAssert callbackCalls == 1 and authRetries == 0 and connection.retry == 1
''',
    "comeback_is_bounded": r'''
# An association comeback (status 30) longer than the longest kernel timer
# is cut to it, so a spoofed interval cannot hold state 8 for weeks.
setup(SmAssocRspState)
now = high(uint32) - 100
doAssert smArmResponse(smGo(SmAssocRspState), high(uint32).uint64 * 1024)
let timer = cast[ptr KeTimerEntry](keTimerQueue.first)
doAssert timer != nil and timer.time - now == KE_TIMER_MAX_DELAY
deliver(expire())
doAssert assocRetries == 1 and connection.retry == 1
''',
    "comeback_cancelled": r'''
setup(SmAssocRspState)
doAssert smArmResponse(smGo(SmAssocRspState), 1_000_000'u64 * 1024)
let old = expire()
discard smGo(SmIdleState)
deliver(old)
doAssert assocRetries == 0 and failures == 0 and keTimerQueue.first == nil
''',
    "allocator_replacement": r'''
setup()
discard arm()
onAlloc = replaceAttempt
now = 150
ke_timer_schedule()
doAssert messages.first == nil and authRetries == 0
doAssert ke_timer_active(SM_RSP_TIMEOUT_IND, TASK_SM)
''',
    "send_replacement": r'''
setup()
discard arm()
onMessage = replaceAttempt
now = 150
ke_timer_schedule()
deliver(takeMessage())
doAssert authRetries == 0 and replacement.retry == 0 and connection.retry == 0
''',
    "other_timer_unchanged": r'''
setup()
ke_timer_set(7, 3, 50)
now = 151
ke_timer_schedule()
let p = takeMessage()
let h = keMsgHdrFromPayload(p)
doAssert h.id == 7 and h.destId == 3 and h.srcId == 0xFF and h.paramLen == 0
ke_msg_free(h)
''',
    "interrupt_state": r'''
setup()
enabled = false
discard arm()
deliver(expire())
doAssert not enabled and authRetries == 1
enabled = true
deliver(expire())
doAssert enabled and authRetries == 2
''',
    "serial_wrap": r'''
setup()
smOwn.op.serial = high(uint32)
let stamp = arm()
doAssert stamp != 0
deliver(expire())
doAssert authRetries == 1
''',
    "allocator_clear": r'''
setup()
discard arm()
onAlloc = proc() = ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
now = 150
ke_timer_schedule()
doAssert messages.first == nil and live.len == 0
''',
    "message_allocation_failure": r'''
setup()
let stamp = arm()
failAlloc = true
now = 150
ke_timer_schedule()
# Out of memory: the same entry is queued again 1 ms later, with no assert.
doAssert messages.first == nil and live.len == 1 and allocationFailures == 0
doAssert cast[ptr KeTimerEntry](keTimerQueue.first).time == now + 1000
doAssert cast[ptr KeTimerEntry](keTimerQueue.first).stamp == stamp
failAlloc = false
now += 1001
ke_timer_schedule()
doAssert messages.first != nil and keTimerQueue.first == nil
deliver(takeMessage())
doAssert authRetries == 1 and failures == 0
''',
    "allocation_failure_after_replacement": r'''
setup()
discard arm()
failAlloc = true
onAlloc = proc() =
  failAlloc = false
  replaceAttempt()
now = 150
ke_timer_schedule()
doAssert allocationFailures == 0, "old allocation failure requested recovery for a replacement"
doAssert messages.first == nil and ke_timer_active(SM_RSP_TIMEOUT_IND, TASK_SM)
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_response_timeout(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case] + "\nfinish()\n")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_auth_success_precedes_timeout_enqueued_by_timer_priority(tmp_path: Path, mode: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = source() + r'''
const
  KE_EVT_MAX = 26
  AuthSuccessFixture = 0x20'u16
var keEvtHandlers: array[KE_EVT_MAX, tuple[handler, param: pointer]]
proc keEnvEventField(): ptr uint32 = addr events
'''
    for name in ("eventIndex32", "keDispatchEvent", "ke_evt_schedule"):
        code += procedure(kernel, name)
    run_program(tmp_path, mode, code + r'''
proc timerEvent(arg: pointer) {.cdecl.} = ke_timer_schedule()
proc messageEvent(arg: pointer) {.cdecl.} =
  let payload = takeMessage()
  let header = keMsgHdrFromPayload(payload)
  if header.id == AuthSuccessFixture:
    # A successful auth response in the single-channel path starts association.
    ke_msg_free(header)
    ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
    doAssert smArmResponse(smGo(SmAssocRspState), 100)
  else:
    deliver(payload)
  if messages.first == nil: ke_evt_clear(KE_EVT_KE_MESSAGE)

setup()
keEvtHandlers[2].handler = cast[pointer](timerEvent)
keEvtHandlers[4].handler = cast[pointer](messageEvent)
discard arm()
let auth = ke_msg_alloc(AuthSuccessFixture, TASK_SM, 0xFF, 0)
ke_msg_send(auth)
now = 150
ke_evt_set(KE_EVT_KE_TIMER)
ke_evt_schedule()
doAssert state == SmAuthenticatingState and keTimerQueue.first == nil
doAssert messages.first == cast[ptr CoListHdr](keMsgHdrFromPayload(auth))
doAssert messages.first != messages.last
doAssert cast[ptr KeMsgHdr](messages.last).id == SM_RSP_TIMEOUT_IND
doAssert events == KE_EVT_KE_MESSAGE
ke_evt_schedule()
doAssert state == SmAssocRspState and messages.first == messages.last
ke_evt_schedule()
doAssert events == 0 and messages.first == nil
doAssert assocRetries == 0 and authRetries == 0 and connection.retry == 0
now = 250
ke_evt_set(KE_EVT_KE_TIMER)
ke_evt_schedule()
ke_evt_schedule()
doAssert assocRetries == 1 and authRetries == 0 and connection.retry == 1
doAssert events == 0
finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_confirmation_cannot_replace_a_management_response(tmp_path: Path, mode: str) -> None:
    # Exercise the old diagnostic define too: neither the real ACK nor the
    # status formerly mistaken for an ACK may manufacture a response.
    run_program(tmp_path, mode, "{.define: bl808WifiAckDrivenMgmtFallback.}\n" + source() + r'''
setup()
discard arm()
nimFwDbgAuthCfmAckOk16 = 1
deliver(expire())
doAssert authFallback == 0 and authRetries == 1
finish()
setup(SmAssocRspState)
discard arm()
nimFwDbgAssocReqSend = 1
nimFwDbgAssocCfmAckOk23 = 1
nimFwDbgAuthOpenSuccess = 1
deliver(expire())
doAssert assocFallback == 0 and assocRetries == 1
finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_response_timeout_trace_build(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, "{.define: bl808WifiConnectTrace.}\n" + source() + r'''
setup()
discard arm()
deliver(expire())
doAssert authRetries == 1
finish()
''')
