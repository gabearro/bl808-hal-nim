"""Run BSS setup across the real ME forwarding and SM confirmation handlers."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_sm_bss_allocation import PLATFORM


EXTRA = r'''
proc smActivationAdmitRequest(request: pointer): bool = true
proc smActivationAdmitControlReply(reply: pointer): bool = true
proc smActivationOwnsRequest(request: pointer): bool = false
proc smActivationTakeReply(request: pointer; id: uint16; length: uint32): pointer = nil
proc smActivationConfirm(reply: pointer; index: int): bool = false
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
  HW_ACTIVE = 3'u16
var
  keMsgQueueSent, keMsgQueueSaved: CoList
  me: tuple[requesterId, psOn: uint8, activeMask, psDisableMask: uint32]
  meState: uint16
  meControlReplyReady: bool
  meConfigInProgress: bool
  meControlEpoch: uint32
  meControlExpectedId, meControlFinalId: uint16
  meControlRequester: uint8
  apmStartRequest, apmStartReply, mmPsModeRequest: pointer
  mmPsModeTxResetEpoch: uint32
  apmStartReplyPublished: bool
  authStarts: int
  nimFwDbgActiveCfmBadState, nimFwDbgActiveCfmLastState: uint32
  applied: seq[uint16]
  confirmations: seq[uint16]
  replacement: Connection
let mac_ac2uapsd = [4'u8, 8, 2, 1]
proc meEnvView(): ptr typeof(me) = addr me
proc txlResetting(): bool = false
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
proc smCleanupOwnsRequest(p: pointer): bool = false
proc smCleanupAdmitRequest(p: pointer): bool = true
proc smCleanupConsumeReply(p: pointer): bool = false
proc smCleanupTakeReply(p: pointer; id: uint16; length: uint32): pointer = nil
proc apmTakeStartReply(p: pointer; id: uint16; length: uint32): pointer = nil
proc ke_msg_alloc_reply*(request: pointer; id: uint16; length: uint32): pointer
proc smBssCancelControl(request, reply: pointer; vifIndex: uint8): bool
'''


WORKER = r'''
proc smTxEnd(build: var SmTxBuildContext) = discard
proc smDeauthSend(build: var SmTxBuildContext) = discard
proc sm_auth_start() =
  inc authStarts
  state = 6

proc consumeReply(p: pointer) =
  let header = keMsgHdrFromPayload(p)
  confirmations.add(header.id)
  case header.id
  of ME_SET_PS_DISABLE_CFM: doAssert me_set_ps_disable_cfm_handler_sm(p) == KeMsgConsumed
  of ME_SET_ACTIVE_CFM: doAssert me_set_active_cfm_handler_sm(p) == KeMsgConsumed
  else: doAssert mm_bss_param_setting_handler(p) == KeMsgConsumed

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
    if smBssAdmitRequest(p):
      applied.add(header.id)
      ke_msg_send_basic_reply(p, header.id + 1)
  if outcome == KeMsgConsumed: ke_msg_free(header)
  elif outcome == KeMsgSaved: co_list_push_back(addr keMsgQueueSaved, header)
  true

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
  sendHook = proc() =
    co_list_push_back(addr keMsgQueueSent, keMsgHdrFromPayload(sent[^1]))
  sm_set_bss_param()

proc takeReply(step: int): pointer =
  var count = 0
  while true:
    let header = cast[ptr KeMsgHdr](keMsgQueueSent.first)
    doAssert header != nil
    if header.destId == TASK_SM and smBss.step == step:
      discard co_list_pop_front(addr keMsgQueueSent)
      return keMsgPayload(header)
    doAssert dispatchOne()
    inc count
    doAssert count < 64

proc changeConnection() =
  replacement = Connection(vifIdx: 1, qosInfo: 10)
  sm.connectInfo = addr replacement
  state = 3

proc assertFinished() =
  doAssert authStarts == 1 and state == 6
  doAssert not smBss.active and smBssTags == nil
  doAssert allocated.len == 0 and keMsgQueueSent.first == nil
  doAssert keMsgQueueSaved.first == nil
  doAssert meControlCommand == nil and meControlReply == nil
'''


def source() -> str:
    platform = "proc controlStateGet(task: uint8): uint16\n"
    platform += "proc controlStateSet(task: uint8; value: uint16)\n" + PLATFORM
    replacements = {
        "meControlReset": "proc meControlReset()\n",
        "meCancelQueuedPayload": "proc meCancelQueuedPayload(payload: pointer)\n",
        "smBssCancelControl": "",
        "ke_state_get": "proc ke_state_get(task: uint8): uint16 = controlStateGet(task)\n",
        "ke_state_set": "proc ke_state_set(task: uint8; value: uint16) = controlStateSet(task, value)\n",
    }
    for name, replacement in replacements.items():
        platform = platform.replace(procedure(platform, name), replacement)
    names = ["MeSetPsDisableReqPayload", "MmSetBssidReqPayload", "MmSetBasicRatesReqPayload",
             "MmSetBeaconIntReqPayload", "MeSetActiveReqPayload", "MmSetEdcaReqPayload"]
    code = layouts(*names, "TxSessionIdentity", "SmTxBuildContext")
    code += "const\n" + "".join(f"  {name}Size = sizeof({name}).uint32\n" for name in names)
    code += platform + EXTRA
    owner = (FW / "station_tx_build.nim").read_text()
    for name in ["smTxBeginForVif", "smTxBegin", "smTxOwnerCurrent", "smTxBindStation", "smTxSetOwnerState"]:
        code += procedure(owner, name)
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
    for name in ["meControlMessageMatches", "meCancelQueuedPayload", "mmPsModeCancel",
                 "meControlReset", "meTakeControlReply", "smBssCancelControl",
                 "meReserveControl", "meForwardControl", "meBeginControl", "meCompleteControl"]:
        code += procedure(task, name)
    code += procedure(kernel, "ke_msg_alloc_reply") + procedure(kernel, "ke_msg_send_basic_reply")
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code += procedure(scan, "sm_send_next_bss_param") + procedure(scan, "sm_set_bss_param")
    code += WORKER.split("proc consumeReply", 1)[0]
    for name in ["me_set_ps_disable_req_handler", "me_set_active_req_handler", "smSetActiveCfmStateAllowed",
                 "mm_bss_param_setting_handler", "me_set_ps_disable_cfm_handler_sm", "me_set_active_cfm_handler_sm"]:
        code += procedure(task, name)
    code += "proc consumeReply" + WORKER.split("proc consumeReply", 1)[1]
    return code


CASES = {
    "complete_forwarded_exchange": r'''
begin()
doAssert allocated.len == 18 and calls == 18
drain()
assertFinished()
doAssert calls == 18, "forwarding allocated a replacement confirmation"
doAssert applied == @[MM_SET_PS_MODE_REQ, MM_SET_BSSID_REQ, MM_SET_BASIC_RATES_REQ,
  MM_SET_BEACON_INT_REQ, MM_SET_EDCA_REQ, MM_SET_EDCA_REQ, MM_SET_EDCA_REQ,
  MM_SET_EDCA_REQ, MM_SET_IDLE_REQ]
doAssert confirmations == @[ME_SET_PS_DISABLE_CFM, 21'u16, 19, 17, 23, 23, 23, 23, ME_SET_ACTIVE_CFM]
''',
    "unrelated_confirmations": r'''
begin()
let before = sent.len
for id in [17'u16, 19, 21, 23, ME_SET_PS_DISABLE_CFM, ME_SET_ACTIVE_CFM]:
  let p = ke_msg_alloc(id, TASK_SM, TASK_MM, 0)
  consumeReply(p)
  doAssert sent.len == before and smBss.step == 0 and authStarts == 0
  ke_msg_free(keMsgHdrFromPayload(p))
drain()
assertFinished()
''',
    "stale_reply_every_step": r'''
for step in 0..8:
  begin()
  let old = takeReply(step)
  changeConnection()
  smBssCancel()
  sm_set_bss_param()
  let before = sent.len
  consumeReply(old)
  doAssert smBss.step == 0 and sent.len == before and authStarts == 0
  ke_msg_free(keMsgHdrFromPayload(old))
  drain()
  assertFinished()
''',
    "duplicate_reply_every_step": r'''
for step in 0..8:
  begin()
  let p = takeReply(step)
  consumeReply(p)
  let before = sent.len
  consumeReply(p)
  doAssert sent.len == before
  ke_msg_free(keMsgHdrFromPayload(p))
  drain()
  assertFinished()
''',
    "reply_metadata": r'''
for step in 0..8:
  for field in 0..3:
    begin()
    let p = takeReply(step)
    let header = keMsgHdrFromPayload(p)
    let original = header[]
    case field
    of 0: header.id = 0xFFFF
    of 1: header.srcId = TASK_API
    of 2: header.destId = TASK_ME
    else: header.paramLen = 1
    doAssert not smBssConsumeReply(p) and smBss.step == step
    header[] = original
    consumeReply(p)
    ke_msg_free(header)
    drain()
    assertFinished()
''',
    "cancel_forwarding_stages": r'''
for stage in 0..3:
  begin()
  for unused in 0..<stage: doAssert dispatchOne()
  smBssCancel()
  doAssert allocated.len == 0 and smBssTags == nil
  doAssert keMsgQueueSent.first == nil and meControlCommand == nil and meControlReply == nil
  doAssert authStarts == 0
begin()
doAssert dispatchOne()
mmPsModeRequest = keMsgPayload(cast[ptr KeMsgHdr](co_list_pop_front(addr keMsgQueueSent)))
smBssCancel()
doAssert allocated.len == 0 and mmPsModeRequest == nil and smBssTags == nil
''',
    "stale_control_reply": r'''
begin()
doAssert dispatchOne() and dispatchOne()
let p = keMsgPayload(cast[ptr KeMsgHdr](co_list_pop_front(addr keMsgQueueSent)))
changeConnection()
doAssert meCompleteControl(p, MM_SET_PS_MODE_CFM) == KeMsgConsumed
ke_msg_free(keMsgHdrFromPayload(p))
doAssert allocated.len == 0 and not smBss.active and authStarts == 0
sm_set_bss_param()
drain()
assertFinished()
''',
    "cancel_unfinished_masks": r'''
begin()
doAssert dispatchOne()
doAssert me.psDisableMask == 2
changeConnection()
smBssCancel()
doAssert me.psDisableMask == 0, "cancel retained the unfinished PS mask"
sm_set_bss_param()
drain()
assertFinished()
begin()
let p = takeReply(7)
consumeReply(p)
ke_msg_free(keMsgHdrFromPayload(p))
doAssert dispatchOne()
doAssert me.activeMask == 2
changeConnection()
smBssCancel()
doAssert me.activeMask == 0, "cancel retained the unfinished active mask"
sm_set_bss_param()
drain()
assertFinished()
''',
    "stale_request_before_dispatch": r'''
begin()
let p = keMsgPayload(cast[ptr KeMsgHdr](co_list_pop_front(addr keMsgQueueSent)))
changeConnection()
doAssert me_set_ps_disable_req_handler(p) == KeMsgConsumed
ke_msg_free(keMsgHdrFromPayload(p))
doAssert applied.len == 0 and allocated.len == 0 and not smBss.active
sm_set_bss_param()
drain()
assertFinished()
''',
    "owner_loss_and_dropped_reply": r'''
for reason in 0..7:
  begin()
  case reason
  of 0: inc rxVifEpochs[1]
  of 1: inc stationEpochs[2]
  of 2: state = 0
  of 3: vif.staIdx = 3
  of 4: discard smTxBegin(addr connection)
  of 5:
    let p = takeReply(0)
    ke_msg_free(keMsgHdrFromPayload(p))
  of 6: vif.vifType = 2
  else: ke_msg_free(co_list_pop_front(addr keMsgQueueSent))
  doAssert smBssNeedsService()
  smBssService()
  doAssert allocated.len == 0 and not smBss.active and smBssTags == nil
''',
    "reserved_reply_and_repeat_begin": r'''
begin()
doAssert not smBssConsumeReply(smBss.reply)
let before = calls
sm_set_bss_param()
doAssert calls == before
let p = takeReply(8)
doAssert sm.pendingBssParams.first == nil and smBss.active
sm_set_bss_param()
doAssert calls == before
consumeReply(p)
ke_msg_free(keMsgHdrFromPayload(p))
assertFinished()
''',
    "cleanup_retains_pending_list": r'''
begin()
var retained = sm.pendingBssParams
co_list_init(addr sm.pendingBssParams)
smBssCancel()
doAssert allocated.len == 8
while retained.first != nil: ke_msg_free(co_list_pop_front(addr retained))
doAssert allocated.len == 0 and smBssTags == nil
''',
    "interrupt_preservation": r'''
for enabled in [false, true]:
  begin()
  interruptsEnabled = enabled
  drain()
  assertFinished()
  doAssert interruptsEnabled == enabled
  begin()
  interruptsEnabled = enabled
  smBssCancel()
  doAssert interruptsEnabled == enabled and allocated.len == 0
''',
    "synchronous_reply_dispatch": r'''
begin()
sendHook = proc() =
  co_list_push_back(addr keMsgQueueSent, keMsgHdrFromPayload(sent[^1]))
  doAssert dispatchOne()
drain()
assertFinished()
''',
    "cancel_free_reentry": r'''
begin()
changeConnection()
freeHook = proc() =
  freeHook = nil
  sm_set_bss_param()
smBssCancel()
doAssert smBss.active and allocated.len == 18
drain()
assertFinished()
''',
    "duplicate_forwarded_request_and_control_reply": r'''
begin()
let request = keMsgPayload(cast[ptr KeMsgHdr](co_list_pop_front(addr keMsgQueueSent)))
doAssert me_set_ps_disable_req_handler(request) == KeMsgNoFree
doAssert keMsgPayload(cast[ptr KeMsgHdr](co_list_pop_front(addr keMsgQueueSent))) == request
ke_msg_send_basic_reply(request, MM_SET_PS_MODE_CFM)
doAssert dispatchOne()
let reply = takeReply(0)
consumeReply(reply)
doAssert not smBssAdmitRequest(request) and smBss.active and smBss.step == 1
doAssert meCompleteControl(reply, MM_SET_PS_MODE_CFM) == KeMsgConsumed
doAssert smBss.active and smBss.step == 1
ke_msg_free(keMsgHdrFromPayload(request))
ke_msg_free(keMsgHdrFromPayload(reply))
drain()
assertFinished()
''',
    "cancel_preserves_other_vif_masks": r'''
begin()
doAssert dispatchOne()
me.psDisableMask = me.psDisableMask or 1
smBssCancel()
doAssert me.psDisableMask == 1 and allocated.len == 0
begin()
let p = takeReply(7)
consumeReply(p)
ke_msg_free(keMsgHdrFromPayload(p))
doAssert dispatchOne()
me.activeMask = me.activeMask or 1
smBssCancel()
doAssert me.activeMask == 1 and allocated.len == 0
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bss_confirmations(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


def test_bss_runtime_hooks() -> None:
    task = (FW / "task_handlers.nim").read_text()
    for name in ["mm_hw_config_handler", "mm_set_idle_req_handler", "mm_set_ps_mode_req_handler",
                 "me_set_active_req_handler", "me_set_ps_disable_req_handler"]:
        assert "smBssAdmitRequest(param)" in procedure(task, name)
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    assert "smBssCancel()" in procedure(kernel, "ke_flush")
    assert "smBssForget(param)" in procedure(kernel, "ke_msg_free")
    assert "smBssCancel()" in procedure((FW / "scan_station_ap_me.nim").read_text(), "sm_init")
    assert "smBssCancel()" in procedure((FW / "station_cleanup.nim").read_text(), "smCleanupBegin")
    loop = (FW / "task_init_main.nim").read_text()
    assert "smBssNeedsService()" in procedure(loop, "wifiMainHasPendingWork")
    assert "smBssService()" in procedure(loop, "wifiDrainScheduledWork")
