"""Exercise response timer publication, queued delivery, and retry ownership."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
{.pragma: wifiCtrl.}
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_STA = 0'u8
  TASK_SCAN = 1'u8
  TASK_SM = 4'u8
  SCAN_PROBE_TIMER = 0x407'u16
  SM_RSP_TIMEOUT_IND = 0x1006'u16
  SM_SA_QUERY_TIMEOUT_IND_MSG = 0x1009'u16
  SmAuthenticatingState = 6'u16
  SmAssocRspState = 8'u16
  WLAN_FW_AUTH_OR_ASSOC_RESPONSE_TIMEOUT_FAILURE = 11'u16
  MACHW_RX_CNTRL_REG = 0'u
  KE_TIMER_MAX_DELAY = 0x11E1A2FF'u32
  WifiTimerDrainLimit = 8'u32
  KE_EVT_KE_TIMER = 0x20000000'u32
  KE_EVT_KE_MESSAGE = 0x08000000'u32
  KeMsgConsumed = 0.cint
  KeMsgTailSlack = 4'u32
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
  KeTimerGuard = proc(context: pointer): bool {.nimcall.}
  KeMsgHdr = object
    next: ptr CoListHdr
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Connection = object
    vifIdx, retry: uint8
  Vif = object
    vifIdx, vifType, staIdx: uint8
  Callbacks = object
    authTimeout: pointer
var
  connection, replacement: Connection
  vif: Vif
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
  smTxSerials: array[2, uint32]
  authRetries, assocRetries, callbackCalls, failures, reads, allocations: int
  allocationFailures: int
  failAlloc: bool
  onAlloc, onFree, onMessage, onRead, onTrace, onTimeout, onTime: proc()
  nimFwDbgKeTimerYield, nimFwDbgKeTimerYieldHead: uint32
  nimFwDbgSmRspTimeout, nimFwDbgSmRspTimeoutState, nimFwDbgSmRspTimeoutRxCtrl: uint32
  nimFwDbgAssocReqSend, nimFwDbgAssocCfmAckOk16, nimFwDbgAssocCfmAckOk23: uint32
  nimFwDbgAuthOpenSuccess, nimFwDbgAssocDone, nimFwDbgAckFallbackAssoc: uint32
  nimFwDbgAckFallbackLast, nimFwDbgAuthCfmAckOk16, nimFwDbgAuthCfmAckOk23: uint32
  nimFwDbgAckFallbackAuth: uint32
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
proc connectInfoView(p: pointer): ptr Connection = cast[ptr Connection](p)
proc connectInfoAuthRetry(p: pointer): ptr uint8 = addr connectInfoView(p).retry
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index == 1
  addr vif
proc staDeleteEpoch(index: uint8): uint32 =
  if index < 7: stationEpochs[index] else: 0
proc macTimeNow(): uint32 =
  invoke(onTime)
  now
proc ke_state_get(task: uint8): uint16 = state
proc assert_err(a, b: cstring; line: cint) =
  doAssert (a == "ke_msg.c" and line == 48) or (a == "ke_timer.c" and line == 128)
  inc allocationFailures
proc ke_timer_hw_set(p: ptr KeTimerEntry) = discard
proc ke_evt_set(bits: uint32) = events = events or bits
proc ke_evt_clear(bits: uint32) = events = events and not bits
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc keMsgPayload(p: ptr KeMsgHdr): pointer = cast[pointer](cast[uint](p) + sizeof(KeMsgHdr).uint)
proc smRspTimerForget(header: pointer)
proc smSaQueryQueueTimeout(serial: uint32) = doAssert false
proc ke_timer_try_set(taskId: uint16; instId: uint8; delay: uint32;
                      guard: KeTimerGuard = nil; context: pointer = nil;
                      continuationUs: uint64 = 0; stamp: uint32 = 0): bool
proc ke_msg_free(p: pointer) =
  smRspTimerForget(p)
  heapFree(p)
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
proc ke_msg_send_basic(id: uint16; destId, srcId: uint8) =
  let p = ke_msg_try_alloc(id, destId, srcId, 0)
  if p != nil: ke_msg_send(p)
proc regRead(address: uint): uint32 =
  inc reads
  invoke(onRead)
  0
proc nimFwTrace2U32(label: string; a, b: uint32) = invoke(onTrace)
proc nimFwConnectTrace2U32(label: string; a, b: uint32) = invoke(onTrace)
proc wpaCallbacks(): ptr Callbacks = addr callbacks
proc authTimeout() {.cdecl.} =
  inc callbackCalls
  invoke(onTimeout)
proc sm_auth_send_pre(sequence: uint16; challenge: pointer) = inc authRetries
proc sm_assoc_req_send_pre() = inc assocRetries
proc sm_connect_ind(status, reason: uint16) =
  doAssert status == 11 and reason == 0xFFFF
  inc failures
proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, size.int)
  p
proc sm_auth_handler(p: pointer) =
  doAssert keMsgHdrFromPayload(p).paramLen == sizeof(SmAuthFrameView).uint32
  let frame = cast[ptr SmAuthFrameView](p)
  doAssert frame.frameLen == 6 and frame.authAlgo == 0 and frame.authSeq == 2
  let dispatch = cast[ptr RxuMgtDispatchView](p)
  doAssert dispatch.frameCtrl == 0xB0 and dispatch.vifIdx == 1
  inc authFallback
proc sm_assoc_done(aid: uint16) = inc assocFallback
proc setup() =
  doAssert live.len == 0
  connection = Connection(vifIdx: 1)
  replacement = Connection(vifIdx: 1)
  sm = (connectInfo: cast[pointer](addr connection), authRetryLimit: 3'u32)
  vif = Vif(vifIdx: 1, vifType: 0, staIdx: 2)
  rxVifEpochs = [1'u32, 1]
  stationEpochs = [0'u32, 0, 1, 0, 0, 0, 0]
  smTxSerials = [0'u32, 3]
  callbacks.authTimeout = cast[pointer](authTimeout)
  wpa_cbs = addr callbacks
  state = 6
  now = 100
  authRetries = 0
  assocRetries = 0
  callbackCalls = 0
  failures = 0
  reads = 0
  authFallback = 0
  assocFallback = 0
  nimFwDbgAssocReqSend = 0
  nimFwDbgAssocCfmAckOk16 = 0
  nimFwDbgAuthOpenSuccess = 0
  nimFwDbgAuthCfmAckOk16 = 0
'''


HELPERS = r'''
proc currentOwner(): SmTxBuildContext =
  SmTxBuildContext(connection: sm.connectInfo, state: state,
    serial: smTxSerials[1], identity: TxSessionIdentity(captured: true,
      vif: 1, station: 2, vifEpoch: rxVifEpochs[1], stationEpoch: stationEpochs[2],
      resetEpoch: txResetEpoch))
proc expire() =
  ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 50)
  now = 151
  ke_timer_schedule()
  doAssert messages.first != nil
proc takeMessage(): pointer =
  let node = co_list_pop_front(addr messages)
  doAssert node != nil
  keMsgPayload(cast[ptr KeMsgHdr](node))
proc deliver(p: pointer) =
  doAssert sm_rsp_timeout_ind_handler(p) == KeMsgConsumed
  ke_msg_free(keMsgHdrFromPayload(p))
proc replaceConnection() =
  sm.connectInfo = addr replacement
  inc rxVifEpochs[1]
  inc smTxSerials[1]
  state = 6
  ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 200)
proc finish() =
  onAlloc = nil
  onFree = nil
  onMessage = nil
  onRead = nil
  onTrace = nil
  onTimeout = nil
  onTime = nil
  when declared(smRspTimerReset): smRspTimerReset()
  while keTimerQueue.first != nil: heapFree(co_list_pop_front(addr keTimerQueue))
  while messages.first != nil: ke_msg_free(co_list_pop_front(addr messages))
  doAssert live.len == 0 and keTimerMutationTop == nil and not keTimerScheduling
  when declared(smRspTags): doAssert smRspTags == nil
'''


def source(trace: bool = False, fallback: bool = False) -> str:
    code = ("{.define: bl808WifiConnectTrace.}\n" if trace else "")
    if fallback:
        code += "{.define: bl808WifiAckDrivenMgmtFallback.}\n"
    code += layouts("TxSessionIdentity", "SmTxBuildContext", "SmAuthFrameView", "RxuMgtDispatchView") + PLATFORM
    code += "\nproc rxuMgtDispatchView(p: pointer): ptr RxuMgtDispatchView = cast[ptr RxuMgtDispatchView](p)\n"
    response = FW / "station_response_timeout.nim"
    if response.exists():
        code += procedure((FW / "station_tx_build.nim").read_text(), "smTxSessionCurrent")
        code += procedure((FW / "station_tx_build.nim").read_text(), "smTxOwnerCurrent")
        code += response.read_text()
    else:
        code += "\nproc smRspTimerForget(header: pointer) = discard\n"
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ["co_list_pop_front", "co_list_insert", "co_list_push_back", "ke_queue_extract",
                 "cmp_abs_time", "cmp_timer_id", "keTimerCancelMutations", "keTimerBeginMutation",
                 "keTimerEndMutation", "ke_timer_try_set", "ke_timer_set", "keTimerClearLocked", "ke_timer_clear",
                 "keTimerExpired", "keTimerRequeue", "ke_timer_schedule", "ke_timer_active"]:
        code += procedure(kernel, name).split("\nconst\n", 1)[0] + "\n"
    code += procedure((FW / "task_handlers.nim").read_text(), "sm_rsp_timeout_ind_handler")
    return code + HELPERS


CASES = {
    "private_tag_alignment": r'''
for lowBits in 0'u ..< 32'u:
  let message = cast[pointer](0x1000'u + lowBits)
  let tag = cast[uint](smRspTagAt(message))
  let alignment = alignof(SmRspTimeoutTag).uint
  let offset = tag - cast[uint](message)
  doAssert tag mod alignment == 0
  doAssert offset >= KeMsgTailSlack.uint
  doAssert offset < KeMsgTailSlack.uint + alignment
setup()
expire()
doAssert cast[uint](smRspTags) mod alignof(SmRspTimeoutTag).uint == 0
deliver(takeMessage())
''',
    "comeback_full_duration_and_clock_wrap": r'''
setup()
state = 8
now = high(uint32) - 100
doAssert smRspTimerSetComeback(currentOwner(), high(uint32))
var elapsed = 0'u64
var chunks = 0
while messages.first == nil:
  let timer = cast[ptr KeTimerEntry](keTimerQueue.first)
  doAssert timer != nil
  let delta = timer.time - now
  doAssert delta > 0 and delta <= KE_TIMER_MAX_DELAY
  elapsed += delta.uint64
  now = timer.time
  ke_timer_schedule()
  inc chunks
  doAssert chunks < 15000
  doAssert assocRetries == 0 and connection.retry == 0
doAssert elapsed == high(uint32).uint64 * 1024
doAssert chunks > 1
deliver(takeMessage())
doAssert assocRetries == 1 and connection.retry == 1
''',
    "comeback_zero_interval": r'''
setup()
state = 8
doAssert smRspTimerSetComeback(currentOwner(), 0)
now += 1
ke_timer_schedule()
deliver(takeMessage())
doAssert assocRetries == 1
''',
    "comeback_early_dispatch": r'''
setup()
state = 8
doAssert smRspTimerSetComeback(currentOwner(), 128)
let deadline = cast[ptr KeTimerEntry](keTimerQueue.first).time
now = deadline - 20
ke_timer_schedule()
doAssert messages.first == nil and keTimerQueue.first != nil
doAssert cast[ptr KeTimerEntry](keTimerQueue.first).time == deadline
now = deadline
ke_timer_schedule()
deliver(takeMessage())
doAssert assocRetries == 1
''',
    "comeback_late_chunk": r'''
setup()
state = 8
doAssert smRspTimerSetComeback(currentOwner(), 1000000)
now += KE_TIMER_MAX_DELAY + 999
ke_timer_schedule()
doAssert messages.first == nil
let timer = cast[ptr KeTimerEntry](keTimerQueue.first)
doAssert timer.time - now == KE_TIMER_MAX_DELAY
var elapsed = (KE_TIMER_MAX_DELAY + 999).uint64
while messages.first == nil:
  let next = cast[ptr KeTimerEntry](keTimerQueue.first)
  elapsed += (next.time - now).uint64
  now = next.time
  ke_timer_schedule()
doAssert elapsed == 1000000'u64 * 1024
deliver(takeMessage())
doAssert assocRetries == 1
''',
    "comeback_cancel_between_chunks": r'''
setup()
state = 8
doAssert smRspTimerSetComeback(currentOwner(), 1000000)
now = cast[ptr KeTimerEntry](keTimerQueue.first).time
ke_timer_schedule()
doAssert messages.first == nil
ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
doAssert keTimerQueue.first == nil and live.len == 0
''',
    "comeback_replacement_during_chunk_allocation": r'''
setup()
state = 8
doAssert smRspTimerSetComeback(currentOwner(), 1000000)
now = cast[ptr KeTimerEntry](keTimerQueue.first).time
onAlloc = replaceConnection
ke_timer_schedule()
doAssert messages.first == nil and allocationFailures == 0
doAssert cast[ptr KeTimerEntry](keTimerQueue.first).time == now + 200
''',
    "comeback_chunk_allocation_failure": r'''
setup()
state = 8
doAssert smRspTimerSetComeback(currentOwner(), 1000000)
now = cast[ptr KeTimerEntry](keTimerQueue.first).time
failAlloc = true
ke_timer_schedule()
# Out of memory: the deadline is kept on the same entry and retried.
doAssert messages.first == nil and keTimerQueue.first != nil
''',
    "comeback_new_timer_during_clock_read": r'''
setup()
state = 8
doAssert smRspTimerSetComeback(currentOwner(), 1000000)
let old = cast[ptr KeTimerEntry](co_list_pop_front(addr keTimerQueue))
now = old.time
onTime = proc() = ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 200)
doAssert smRspTimerDispatch(old)
heapFree(old)
doAssert cast[ptr KeTimerEntry](keTimerQueue.first).time == now + 200
doAssert messages.first == nil
''',
    "comeback_requires_association_owner": r'''
setup()
doAssert not smRspTimerSetComeback(currentOwner(), 1)
state = 8
var owner = currentOwner()
inc stationEpochs[2]
doAssert not smRspTimerSetComeback(owner, 1)
doAssert live.len == 0
''',
    "replacement_connection": r'''
setup()
expire()
let old = takeMessage()
replaceConnection()
deliver(old)
doAssert authRetries == 0 and assocRetries == 0 and failures == 0
doAssert replacement.retry == 0
''',
    "callback_replacement": r'''
setup()
expire()
onTimeout = replaceConnection
deliver(takeMessage())
doAssert callbackCalls == 1 and authRetries == 0 and replacement.retry == 0
''',
    "clear_queued_event": r'''
setup()
expire()
ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
deliver(takeMessage())
doAssert authRetries == 0 and connection.retry == 0 and reads == 0
''',
    "rearm_same_connection": r'''
setup()
expire()
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 200)
deliver(takeMessage())
doAssert authRetries == 0 and connection.retry == 0 and reads == 0
now = 400
ke_timer_schedule()
deliver(takeMessage())
doAssert authRetries == 1 and connection.retry == 1
''',
    "reset_queued_event": r'''
setup()
expire()
smRspTimerReset()
deliver(takeMessage())
doAssert authRetries == 0 and connection.retry == 0 and reads == 0
''',
    "phase_change": r'''
setup()
expire()
state = 8
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 100)
deliver(takeMessage())
doAssert authRetries == 0 and assocRetries == 0 and connection.retry == 0
now = 300
ke_timer_schedule()
deliver(takeMessage())
doAssert assocRetries == 1 and connection.retry == 1 and callbackCalls == 0
''',
    "duplicate_and_untracked": r'''
setup()
expire()
let event = takeMessage()
let header = keMsgHdrFromPayload(event)
doAssert header.id == SM_RSP_TIMEOUT_IND and header.destId == TASK_SM
doAssert header.srcId == 0xFF and header.paramLen == 0
doAssert sm_rsp_timeout_ind_handler(event) == 0
doAssert sm_rsp_timeout_ind_handler(event) == 0
doAssert authRetries == 1 and connection.retry == 1
ke_msg_free(header)
let untracked = ke_msg_alloc(SM_RSP_TIMEOUT_IND, TASK_SM, 0xFF, 0)
deliver(untracked)
doAssert authRetries == 1 and connection.retry == 1
''',
    "valid_retry_and_failure": r'''
setup()
expire()
deliver(takeMessage())
doAssert authRetries == 1 and connection.retry == 1 and callbackCalls == 1
connection.retry = 3
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 100)
now = 300
ke_timer_schedule()
deliver(takeMessage())
doAssert failures == 1 and authRetries == 1 and callbackCalls == 1
''',
    "allocator_replacement": r'''
setup()
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 50)
onAlloc = replaceConnection
now = 151
ke_timer_schedule()
doAssert messages.first == nil and authRetries == 0
doAssert ke_timer_active(SM_RSP_TIMEOUT_IND, TASK_SM)
''',
    "free_replacement": r'''
setup()
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 50)
onFree = replaceConnection
now = 151
ke_timer_schedule()
deliver(takeMessage())
doAssert authRetries == 0 and replacement.retry == 0
''',
    "send_replacement": r'''
setup()
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 50)
onMessage = replaceConnection
now = 151
ke_timer_schedule()
deliver(takeMessage())
doAssert authRetries == 0 and replacement.retry == 0
''',
    "read_replacement": r'''
setup()
expire()
onRead = replaceConnection
deliver(takeMessage())
doAssert authRetries == 0 and replacement.retry == 0 and connection.retry == 0
''',
    "callback_rearms_same_owner": r'''
setup()
expire()
onTimeout = proc() = ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 200)
deliver(takeMessage())
doAssert callbackCalls == 1 and authRetries == 0 and connection.retry == 1
''',
    "invalid_owner": r'''
setup()
sm.connectInfo = nil
doAssert not ke_timer_try_set(SM_RSP_TIMEOUT_IND, TASK_SM, 100)
doAssert live.len == 0
sm.connectInfo = addr connection
connection.vifIdx = 2
doAssert not ke_timer_try_set(SM_RSP_TIMEOUT_IND, TASK_SM, 100)
doAssert live.len == 0
connection.vifIdx = 1
state = 0
doAssert not ke_timer_try_set(SM_RSP_TIMEOUT_IND, TASK_SM, 100)
doAssert live.len == 0
''',
    "owner_loss_before_expiry": r'''
setup()
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 50)
inc stationEpochs[2]
now = 151
ke_timer_schedule()
doAssert messages.first == nil and live.len == 0
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
expire()
deliver(takeMessage())
doAssert not enabled and authRetries == 1
enabled = true
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 100)
now = 300
ke_timer_schedule()
deliver(takeMessage())
doAssert enabled and authRetries == 2
''',
    "malformed_header": r'''
setup()
expire()
let p = takeMessage()
let h = keMsgHdrFromPayload(p)
let original = h[]
for field in 0..3:
  case field
  of 0: h.id = 7
  of 1: h.destId = 3
  of 2: h.srcId = 4
  else: h.paramLen = 1
  doAssert sm_rsp_timeout_ind_handler(p) == 0 and authRetries == 0
  h[] = original
deliver(p)
doAssert authRetries == 1
''',
    "owner_fields_independent": r'''
for change in 0..6:
  setup()
  expire()
  case change
  of 0: sm.connectInfo = addr replacement
  of 1: inc rxVifEpochs[1]
  of 2: inc stationEpochs[2]
  of 3: vif.staIdx = 3
  of 4: vif.vifType = 2
  of 5: state = 8
  else: inc smTxSerials[1]
  deliver(takeMessage())
  doAssert authRetries == 0 and assocRetries == 0 and reads == 0
  finish()
''',
    "guard_rejection": r'''
setup()
var current = true
proc guard(context: pointer): bool = current
onAlloc = proc() = current = false
doAssert not ke_timer_try_set(SM_RSP_TIMEOUT_IND, TASK_SM, 100, guard)
doAssert live.len == 0 and keTimerQueue.first == nil
current = true
expire()
deliver(takeMessage())
doAssert authRetries == 1
''',
    "serial_wrap": r'''
setup()
smRspSerial = high(uint32)
expire()
doAssert smRspSerial != 0
deliver(takeMessage())
doAssert authRetries == 1
''',
    "allocator_clear": r'''
setup()
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 50)
onAlloc = proc() = ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
now = 151
ke_timer_schedule()
doAssert messages.first == nil and live.len == 0
''',
    "message_allocation_failure": r'''
setup()
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 50)
failAlloc = true
now = 151
ke_timer_schedule()
# Out of memory: the same entry is queued again 1 ms later, with no assert.
doAssert messages.first == nil and live.len == 1
doAssert cast[ptr KeTimerEntry](keTimerQueue.first).time == now + 1000
failAlloc = false
now += 1001
ke_timer_schedule()
doAssert messages.first != nil and keTimerQueue.first == nil
doAssert authRetries == 0 and failures == 0
''',
    "allocation_failure_after_replacement": r'''
setup()
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 50)
failAlloc = true
onAlloc = proc() =
  failAlloc = false
  replaceConnection()
now = 151
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
    state = SmAssocRspState
    ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 100)
  else:
    deliver(payload)
  if messages.first == nil: ke_evt_clear(KE_EVT_KE_MESSAGE)

setup()
keEvtHandlers[2].handler = cast[pointer](timerEvent)
keEvtHandlers[4].handler = cast[pointer](messageEvent)
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 50)
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
def test_response_timeout_trace_reentry(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(trace=True) + r'''
setup()
expire()
onTrace = replaceConnection
deliver(takeMessage())
doAssert authRetries == 0 and replacement.retry == 0 and connection.retry == 0
finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_confirmation_cannot_replace_a_management_response(tmp_path: Path, mode: str) -> None:
    # Exercise the old diagnostic define too: neither the real ACK nor the
    # status formerly mistaken for an ACK may manufacture a response.
    run_program(tmp_path, mode, source(fallback=True) + r'''
setup()
expire()
nimFwDbgAuthCfmAckOk16 = 1
deliver(takeMessage())
doAssert authFallback == 0 and authRetries == 1
finish()
setup()
state = 8
expire()
nimFwDbgAssocReqSend = 1
nimFwDbgAssocCfmAckOk23 = 1
nimFwDbgAuthOpenSuccess = 1
deliver(takeMessage())
doAssert assocFallback == 0 and assocRetries == 1
finish()
setup()
expire()
nimFwDbgAuthCfmAckOk16 = 1
onRead = replaceConnection
deliver(takeMessage())
doAssert authFallback == 0 and authRetries == 0
finish()
''')
