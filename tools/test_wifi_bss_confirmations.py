"""Run the BSS parameter batch across the real ME forwarding and SM handlers.

The harness compiles the real station_bss.nim, station_sm.nim's request
procs, ME's control exchange (meReserveControl, meForwardControl,
meCompleteControl, meTakeControlReply), ke_msg_alloc_reply and the SM
confirmation handlers. MM is a model that answers every request it gets
(ke_msg_send_basic_reply), or holds a forwarded ME command until told.
"""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure, station_sm_source
from test_wifi_message_allocation import run_program
from test_wifi_sm_bss_allocation import PLATFORM


EXTRA = r'''
const
  KeMsgNoFree = 1.cint
  MeBusyState = 1'u16
  TASK_NONE = 0xFF'u8
  SmIdleState = 0'u16
  SmDisconnectingState = 10'u16
  ME_SET_PS_DISABLE_CFM = ME_SET_PS_DISABLE_REQ + 1
  ME_SET_ACTIVE_CFM = ME_SET_ACTIVE_REQ + 1
  MM_SET_IDLE_REQ = 26'u16
  MM_SET_IDLE_CFM = 27'u16
  MM_SET_PS_MODE_REQ = 31'u16
  MM_SET_PS_MODE_CFM = 32'u16
type SmTxBuildContext = object
var
  keMsgQueueSent, keMsgQueueSaved: CoList
  me: tuple[requesterId, psOn: uint8, activeMask, psDisableMask: uint32]
  meState: uint16
  meControlCommand, meControlReply: pointer
  meControlReplyReady: bool
  meConfigInProgress: bool
  meControlEpoch: uint32
  meControlExpectedId, meControlFinalId: uint16
  meControlRequester: uint8
  apmStartRequest: pointer
  authStarts, deauths, activations: int
  applied: seq[uint16]
  confirmations: seq[uint16]
  holdMM: bool
  heldMM: pointer
  smRequests: seq[pointer]  # the batch's requests, as SM sent them
proc meEnvView(): ptr typeof(me) = addr me
proc controlStateGet(task: uint8): uint16 =
  if task == TASK_SM: state else: meState
proc releaseSavedControl(task: uint8)
proc controlStateSet(task: uint8; value: uint16) =
  if task == TASK_SM:
    state = value
    inc stateChanges
    if stateHook != nil: stateHook()
  else: meState = value
  releaseSavedControl(task)
proc smCleanupAdmitRequest(p: pointer): bool = true
proc smCleanupConsumeReply(p: pointer): bool = false
proc smCleanupTakeReply(p: pointer; id: uint16; length: uint32): pointer = nil
proc apmTakeStartReply(p: pointer; id: uint16; length: uint32): pointer = nil
proc smActivationConfirmed() = inc activations
proc smTxBegin(connection: pointer): SmTxBuildContext = discard
proc smTxEnd(build: var SmTxBuildContext) = discard
proc smDeauthSend(build: var SmTxBuildContext) = inc deauths
proc sm_auth_start() =
  inc authStarts
  state = 6
proc ke_msg_alloc_reply*(request: pointer; id: uint16; length: uint32): pointer
proc meTakeControlReply(request: pointer; id: uint16; length: uint32): pointer
'''


WORKER = r'''
proc consumeReply(p: pointer) =
  let header = keMsgHdrFromPayload(p)
  confirmations.add(header.id)
  case header.id
  of ME_SET_PS_DISABLE_CFM: doAssert me_set_ps_disable_cfm_handler_sm(p) == KeMsgConsumed
  of ME_SET_ACTIVE_CFM: doAssert me_set_active_cfm_handler_sm(p) == KeMsgConsumed
  else: doAssert mm_bss_param_setting_handler(p) == KeMsgConsumed

proc answerMM(p: pointer) =
  ## MM's model: apply the request and answer it.
  applied.add(keMsgHdrFromPayload(p).id)
  ke_msg_send_basic_reply(p, keMsgHdrFromPayload(p).id + 1)

proc dispatchOne(): bool =
  let node = co_list_pop_front(addr keMsgQueueSent)
  if node == nil: return false
  let header = cast[ptr KeMsgHdr](node)
  let p = keMsgPayload(header)
  var outcome = KeMsgConsumed
  if header.destId == TASK_SM:
    consumeReply(p)
  elif header.destId == TASK_ME:
    case header.id
    of ME_SET_PS_DISABLE_REQ: outcome = me_set_ps_disable_req_handler(p)
    of ME_SET_ACTIVE_REQ: outcome = me_set_active_req_handler(p)
    else: outcome = meCompleteControl(p, header.id)
  else:
    doAssert header.destId == TASK_MM
    if smStaleRequest(p): discard
    elif holdMM and p == meControlCommand:
      heldMM = p
      outcome = KeMsgNoFree
    else: answerMM(p)
  if outcome == KeMsgConsumed: ke_msg_free(header)
  elif outcome == KeMsgSaved: co_list_push_back(addr keMsgQueueSaved, header)
  true

proc releaseMM() =
  ## MM completes the forwarded command it held (mmPsModeComplete).
  let p = heldMM
  doAssert p != nil
  heldMM = nil
  holdMM = false
  answerMM(p)
  ke_msg_free(keMsgHdrFromPayload(p))

proc queueSent() =
  let p = sent[^1]
  if keMsgHdrFromPayload(p).srcId == TASK_SM: smRequests.add(p)
  co_list_push_back(addr keMsgQueueSent, keMsgHdrFromPayload(p))

proc drain() =
  var count = 0
  while dispatchOne():
    inc count
    doAssert count < 64

proc begin() =
  doAssert allocated.len == 0 and keMsgQueueSent.first == nil
  setup()
  me = (requesterId: TASK_NONE, psOn: 1'u8, activeMask: 0'u32, psDisableMask: 0'u32)
  meState = MeIdleState
  meControlCommand = nil
  meControlReply = nil
  meControlReplyReady = false
  meConfigInProgress = false
  applied.setLen(0)
  confirmations.setLen(0)
  authStarts = 0
  deauths = 0
  activations = 0
  holdMM = false
  heldMM = nil
  smRequests.setLen(0)
  sendHook = queueSent
  sm_set_bss_param()

proc takeAnswer(): pointer =
  ## Dispatch until a message for SM heads the queue, and take it.
  var count = 0
  while true:
    let header = cast[ptr KeMsgHdr](keMsgQueueSent.first)
    doAssert header != nil
    if header.destId == TASK_SM:
      discard co_list_pop_front(addr keMsgQueueSent)
      return keMsgPayload(header)
    doAssert dispatchOne()
    inc count
    doAssert count < 64

proc answerFor(step: int): pointer =
  ## The answer to the batch's request `step`; earlier answers are handled.
  while true:
    result = takeAnswer()
    if smRequests.len == step + 1: return
    consumeReply(result)
    ke_msg_free(keMsgHdrFromPayload(result))

proc endAttempt() =
  ## The attempt's teardown: SM leaves state 4 and the unsent requests go.
  discard smGo(SmDisconnectingState)
  smBssCancel()

proc assertQuiet() =
  doAssert allocated.len == 0 and keMsgQueueSent.first == nil
  doAssert keMsgQueueSaved.first == nil
  doAssert meControlCommand == nil and meControlReply == nil and meState == MeIdleState
  doAssert smOwn.request == nil and smOwn.reply == nil and smOwn.answer == nil

proc assertFinished() =
  doAssert authStarts == 1 and state == 6 and sm.pendingBssParams.first == nil
  assertQuiet()
'''


def source() -> str:
    platform = "proc controlStateGet(task: uint8): uint16\n"
    platform += "proc controlStateSet(task: uint8; value: uint16)\n" + PLATFORM
    for name, replacement in {
        "ke_state_get": "proc ke_state_get(task: uint8): uint16 = controlStateGet(task)\n",
        "ke_state_set": "proc ke_state_set(task: uint8; value: uint16) = controlStateSet(task, value)\n",
    }.items():
        platform = platform.replace(procedure(platform, name), replacement)
    platform = platform.replace("proc setup() =", station_sm_source(
        "smGo", "smSendReserved", "smAwaits", "smAttemptStaVif", "smStaleRequest",
        "smTakeReply", "smTakeAnswer") + "proc setup() =", 1)
    platform = "proc ke_msg_send_basic_reply*(request: pointer; id: uint16)\n" + platform
    names = ["MeSetPsDisableReqPayload", "MmSetBssidReqPayload", "MmSetBasicRatesReqPayload",
             "MmSetBeaconIntReqPayload", "MeSetActiveReqPayload", "MmSetEdcaReqPayload"]
    code = layouts(*names)
    code += "const\n" + "".join(f"  {name}Size = sizeof({name}).uint32\n" for name in names)
    code += platform + EXTRA
    code += (FW / "station_bss.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    task = (FW / "task_handlers.nim").read_text()
    code += procedure(kernel, "ke_queue_extract")
    code += r'''
proc releaseSavedControl(task: uint8) =
  proc matches(node: ptr CoListHdr; destination: pointer): bool {.cdecl.} =
    cast[ptr KeMsgHdr](node).destId == cast[uint](destination).uint8
  while true:
    let node = ke_queue_extract(addr keMsgQueueSaved, matches, cast[pointer](task.uint))
    if node == nil: break
    co_list_push_back(addr keMsgQueueSent, node)
'''
    for name in ["meTakeControlReply", "meReserveControl", "meForwardControl", "meBeginControl",
                 "meCompleteControl"]:
        code += procedure(task, name)
    code += procedure(kernel, "ke_msg_alloc_reply") + procedure(kernel, "ke_msg_send_basic_reply")
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code += procedure(scan, "sm_send_next_bss_param") + procedure(scan, "sm_set_bss_param")
    for name in ["me_set_ps_disable_req_handler", "me_set_active_req_handler",
                 "mm_bss_param_setting_handler", "me_set_ps_disable_cfm_handler_sm",
                 "me_set_active_cfm_handler_sm"]:
        code += procedure(task, name)
    return code + WORKER


CASES = {
    # The forwarded ME requests answer with the reply SM reserved: nothing is
    # allocated beyond the nine requests and their nine replies.
    "complete_forwarded_exchange": r'''
begin()
doAssert allocated.len == 10 and calls == 10
drain()
assertFinished()
doAssert calls == 18, "a confirmation was allocated by a replier"
doAssert applied == @[MM_SET_PS_MODE_REQ, MM_SET_BSSID_REQ, MM_SET_BASIC_RATES_REQ,
  MM_SET_BEACON_INT_REQ, MM_SET_EDCA_REQ, MM_SET_EDCA_REQ, MM_SET_EDCA_REQ,
  MM_SET_EDCA_REQ, MM_SET_IDLE_REQ]
doAssert confirmations == @[ME_SET_PS_DISABLE_CFM, 21'u16, 19, 17, 23, 23, 23, 23, ME_SET_ACTIVE_CFM]
doAssert me.psDisableMask == 2 and me.activeMask == 2 and deauths == 0
''',
    # Confirmations SM does not hold change nothing.
    "unrelated_confirmations": r'''
begin()
let before = smRequests.len
for id in [17'u16, 19, 21, 23, ME_SET_PS_DISABLE_CFM, ME_SET_ACTIVE_CFM]:
  let p = ke_msg_alloc(id, TASK_SM, TASK_MM, 0)
  consumeReply(p)
  doAssert smRequests.len == before and authStarts == 0 and activations == 0
  ke_msg_free(keMsgHdrFromPayload(p))
drain()
assertFinished()
''',
    # The attempt ends while an answer is queued: SM ignores it.
    "stale_answer_every_step": r'''
for step in 0..8:
  begin()
  let answer = answerFor(step)
  endAttempt()
  let before = smRequests.len
  consumeReply(answer)
  doAssert smRequests.len == before and authStarts == 0 and state == SmDisconnectingState
  ke_msg_free(keMsgHdrFromPayload(answer))
  drain()
  assertQuiet()
''',
    "duplicate_answer_every_step": r'''
for step in 0..8:
  begin()
  let answer = answerFor(step)
  consumeReply(answer)
  let before = (smRequests.len, authStarts)
  consumeReply(answer)
  doAssert (smRequests.len, authStarts) == before
  ke_msg_free(keMsgHdrFromPayload(answer))
  drain()
  assertFinished()
''',
    # The attempt ends while ME's forward of the first or last request is with
    # MM. The exchange completes as in the blob (no cancellation): ME goes
    # idle with the mask the request set, and SM ignores the answer. The
    # teardown's own ME requests (station_cleanup.nim) undo the masks.
    "attempt_ends_during_forward": r'''
for last in [false, true]:
  begin()
  if last:
    while smRequests.len < 9:
      let answer = takeAnswer()
      consumeReply(answer)
      ke_msg_free(keMsgHdrFromPayload(answer))
  holdMM = true
  drain()
  doAssert heldMM != nil and meState == MeBusyState
  endAttempt()
  releaseMM()
  drain()
  doAssert authStarts == 0 and state == SmDisconnectingState
  if last: doAssert me.activeMask == 2
  else: doAssert me.psDisableMask == 2
  assertQuiet()
''',
    # The attempt ends before ME runs the request: ME drops it unapplied.
    "stale_request_before_dispatch": r'''
begin()
let request = keMsgPayload(cast[ptr KeMsgHdr](co_list_pop_front(addr keMsgQueueSent)))
endAttempt()
doAssert me_set_ps_disable_req_handler(request) == KeMsgConsumed
ke_msg_free(keMsgHdrFromPayload(request))
doAssert applied.len == 0 and me.psDisableMask == 0 and meState == MeIdleState
assertQuiet()
''',
    # The attempt's STA VIF is retired while SM's request waits for its
    # replier: the replier answers it unapplied (no MM write, no ME mask bit)
    # and SM ends the attempt at that answer, the last one included.
    "vif_retired_before_the_replier_runs": r'''
for step in 0..8:
  begin()
  while smRequests.len < step + 1: doAssert dispatchOne()
  let before = (applied.len, me.psDisableMask, me.activeMask)
  vif.vifType = 2
  drain()
  doAssert (applied.len, me.psDisableMask, me.activeMask) == before,
    "request " & $step & " was applied to the retired VIF"
  doAssert failures == @[(14'u16, 0xFFFF'u16)] and smRequests.len == step + 1
  doAssert authStarts == 0 and state == SmDisconnectingState
  endAttempt()
  assertQuiet()
''',
    # The STA VIF is retired while MM holds ME's forward of the first or the
    # last request: ME and MM finish it and SM ends the attempt at the answer.
    # (The mask bit the forward set stays set when no cleanup runs; clearing
    # it belongs with vif_mgmt_unregister telling SM, stage 9g.)
    "vif_retired_during_forward": r'''
for last in [false, true]:
  begin()
  if last:
    while smRequests.len < 9:
      let answer = takeAnswer()
      consumeReply(answer)
      ke_msg_free(keMsgHdrFromPayload(answer))
  holdMM = true
  drain()
  doAssert heldMM != nil and meState == MeBusyState
  vif.vifType = 2
  releaseMM()
  drain()
  doAssert failures == @[(14'u16, 0xFFFF'u16)] and authStarts == 0
  doAssert state == SmDisconnectingState
  endAttempt()
  assertQuiet()
''',
    # A request saved while ME is busy still gets its answer.
    "saved_while_me_busy": r'''
begin()
meState = MeBusyState
doAssert dispatchOne() and keMsgQueueSaved.first != nil
controlStateSet(TASK_ME, MeIdleState)
drain()
assertFinished()
''',
    "synchronous_reply_dispatch": r'''
begin()
sendHook = proc() =
  queueSent()
  doAssert dispatchOne()
drain()
assertFinished()
''',
    "interrupt_preservation": r'''
for enabled in [false, true]:
  begin()
  interruptsEnabled = enabled
  drain()
  assertFinished()
  doAssert interruptsEnabled == enabled
''',
    # ME's forward of SM's ME_SET_PS_DISABLE_REQ takes the reserved reply once;
    # MM's confirmation and ME's are that message.
    "forward_carries_the_reserved_reply": r'''
begin()
let request = keMsgPayload(cast[ptr KeMsgHdr](co_list_pop_front(addr keMsgQueueSent)))
let reserved = smOwn.reply
doAssert me_set_ps_disable_req_handler(request) == KeMsgNoFree
doAssert meControlReply == reserved and smOwn.reply == nil and smOwn.answer == reserved
doAssert not smAwaits(request) and meControlCommand == request
doAssert keMsgPayload(cast[ptr KeMsgHdr](co_list_pop_front(addr keMsgQueueSent))) == request
answerMM(request)
ke_msg_free(keMsgHdrFromPayload(request))
let answer = takeAnswer()
doAssert answer == reserved and keMsgHdrFromPayload(answer).id == ME_SET_PS_DISABLE_CFM
consumeReply(answer)
ke_msg_free(keMsgHdrFromPayload(answer))
doAssert smRequests.len == 2
drain()
assertFinished()
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bss_confirmations(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


def test_bss_batch_has_no_loss_machinery() -> None:
    """The batch is SM's live request and its reserved reply; the repliers
    check SM once at entry. Nothing tracks, forgets, cancels or services it."""
    task = (FW / "task_handlers.nim").read_text()
    for name in ["mm_hw_config_handler", "mm_set_ps_options_req_handler",
                 "me_set_active_req_handler", "me_set_ps_disable_req_handler"]:
        assert "smStaleRequest(param)" in procedure(task, name), name
    for name in ["mm_bss_param_setting_handler", "me_set_ps_disable_cfm_handler_sm",
                 "me_set_active_cfm_handler_sm"]:
        assert "smTakeAnswer(param)" in procedure(task, name), name
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    assert "smBss" not in procedure(kernel, "ke_msg_free")
    assert "smTakeReply(request, id)" in procedure(kernel, "ke_msg_alloc_reply")
    assert "smBssCancel()" in procedure((FW / "scan_station_ap_me.nim").read_text(), "sm_init")
    assert "smBssCancel()" in procedure((FW / "station_cleanup.nim").read_text(), "smCleanupBegin")
    loop = (FW / "task_init_main.nim").read_text()
    assert "smBss" not in procedure(loop, "wifiMainHasPendingWork")
    assert "smBss" not in procedure(loop, "wifiDrainScheduledWork")
    sources = "".join(path.read_text() for path in FW.rglob("*.nim"))
    for gone in ["smBssForget", "smBssTags", "smBssNeedsService", "smBssService",
                 "smBssCancelControl", "smBssAdmitRequest", "smBssTakeReply", "smBssSerial"]:
        assert gone not in sources, gone
