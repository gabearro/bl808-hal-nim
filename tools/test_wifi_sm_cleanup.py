"""Exercise station cleanup with production ME/MM transactions and reply ownership."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_ap_start import program_source
from test_wifi_disconnect_tx import FW, ROOT, procedure

PREFIX = r'''
{.pragma: wifiCtrl.}
const
  TASK_SM = 4'u8
  VIF_TYPE_STA = 0'u8
  SmIdleState = 0'u16
  SmSettingBssState = 4'u16
  SmDisconnectingState = 10'u16
  SM_ACTIVATING_STATE = 9'u16
  MM_STA_DEL_REQ = 12'u16
  MM_STA_DEL_CFM = 13'u16
  SM_DISCONNECT_IND = 0x1005'u16
  SM_CONNECT_IND_MSG = 0x1002'u16
  SM_SA_QUERY_TIMEOUT_IND_MSG = 0x1009'u16
  KeMsgTailSlack = 4'u32
var
  smState = 10'u16
  interruptsEnabled = true
  failEveryAllocation: bool
  allocationHook, disconnectedHook, indicationHook, freeHook, scanRemoveHook: proc()
proc smCleanupForget(header: pointer)
proc smCleanupOwnsRequest(request: pointer): bool
proc smCleanupAdmitRequest(request: pointer): bool
proc smCleanupTakeReply(request: pointer; id: uint16; length: uint32): pointer
proc smCleanupConsumeReply(reply: pointer): bool
proc smCleanupCancel()
proc smDeferredCancel() = discard
proc smBssCancel() = discard
proc smBssNeedsService(): bool = false
proc smBssService() = discard
proc smBssConsumeReply(p: pointer): bool = false
proc smCleanupService()
proc chan_ctxt_unlink(index: uint8)
'''

PLATFORM = r'''
type
  SmEnv = object
    connectInfo, connectIndMsg: pointer
    pendingBssParams: CoList
    cancelRequested, joinBssFlag, deauthPending, saQueryActive: uint8
    scanResultIndex: uint32
  SmTxBuildContext = object
    connection: pointer
    state: uint16
    identity: tuple[captured: bool]
  RxHostSession = object
    vif: uint8
    epoch: uint32
  MeStaDelReqPayload = object
    staIdx: uint8
  MmStaDelReqPayload = MeStaDelReqPayload
  SmDisconnectProcessIndPayload = object
    status, reason: uint16
    vifIdx: uint8
    padding: array[11, uint8]
const
  MmStaDelReqPayloadSize = 1'u32
  SmDisconnectProcessIndPayloadSize = 16'u32
var
  sm: SmEnv
  stationEpochs: array[7, uint32]
  commands: seq[uint16]
  removed: seq[uint8]
  callbackCalls, starts, unlinks: int
  smConnecting: bool
  nimFwWpaPendingMask: uint32
  nimFwDbgDisconnectInd, nimFwDbgDisconnectProcess: uint32
  nimFwDbgActiveCfmBadState, nimFwDbgActiveCfmLastState: uint32
  notifications: seq[SmDisconnectProcessIndPayload]
  cleanupChannel: Context
proc smEnvView(): ptr SmEnv = addr sm
proc connectInfoView(p: pointer): ptr tuple[vifIdx: uint8] = cast[ptr tuple[vifIdx: uint8]](p)
proc captureRxHostSession(vif, station: uint8): RxHostSession =
  RxHostSession(vif: vif, epoch: rxVifEpochs[vif])
proc rxHostSessionCurrent(session: RxHostSession): bool = rxVifEpochs[session.vif] == session.epoch
proc staDeleteEpoch(index: uint8): uint32 =
  if index < stationEpochs.len.uint8: stationEpochs[index] else: 0
proc staDeleteIsCurrent(index: uint8; epoch: uint32): bool =
  index < stationEpochs.len.uint8 and stationEpochs[index] == epoch
proc ke_msg_try_alloc(id: uint16; dst, src: uint8; n: uint32): pointer =
  result = ke_msg_alloc(id, dst, src, n)
  if allocationHook != nil:
    let action = allocationHook
    allocationHook = nil
    action()
proc mmStaDelReqView(p: pointer): ptr MmStaDelReqPayload = cast[ptr MmStaDelReqPayload](p)
proc mm_sta_del(index: uint8) =
  if index >= 7: return
  removed.add(index)
  for vif in vifs.mitems:
    if vif.vifType == VIF_TYPE_STA and vif.staIdx == index: vif.staIdx = 255
proc chan_ctxt_unlink(index: uint8) =
  inc unlinks
  vifs[index].chanCtxt = nil
proc smConnectIndPayloadAt(p: pointer): ptr SmConnectIndPayload = cast[ptr SmConnectIndPayload](p)
proc scanu_rm_exist_ssid(p: pointer; index: uint8) =
  if scanRemoveHook != nil:
    let action = scanRemoveHook
    scanRemoveHook = nil
    action()
proc sm_auth_start() = inc starts
proc sm_deauth_send() = inc starts
proc smTxBegin(connection: pointer): SmTxBuildContext =
  SmTxBuildContext(connection: connection, state: ke_state_get(TASK_SM),
    identity: (captured: connection != nil))
proc smTxOwnerCurrent(build: SmTxBuildContext): bool =
  sm.connectInfo == build.connection and ke_state_get(TASK_SM) == build.state
proc smTxEnd(build: var SmTxBuildContext) = discard
proc smDeauthSend(build: var SmTxBuildContext) = sm_deauth_send()
proc sm_send_next_bss_param(p: pointer) = inc starts
proc stationDisconnected(reason: uint8) {.cdecl.} =
  doAssert reason == 0
  inc callbackCalls
  if disconnectedHook != nil:
    let action = disconnectedHook
    disconnectedHook = nil
    action()
proc driveOne()
proc wifiEventPendingWork(): bool = keMsgQueueSent.first != nil
proc wifiKernelTimerPendingWork(): bool = false
proc wifiMmTimerPendingWork(): bool = false
proc wifiMessagePendingWork(): bool = keMsgQueueSent.first != nil
proc wifiHiddenMessagePendingWork(): bool = false
proc ke_timer_schedule() = discard
proc mm_timer_schedule() = discard
proc ke_evt_schedule() =
  if keMsgQueueSent.first != nil: driveOne()
proc ke_task_schedule() = discard
'''

DRIVER = r'''
proc driveOne() =
  let h = co_list_pop_front(addr keMsgQueueSent)
  doAssert h != nil
  let p = keMsgPayload(h)
  var result = KeMsgConsumed
  if h.destId == TASK_SM:
    doAssert h.paramLen == 0
    case h.id
    of ME_SET_PS_DISABLE_CFM: me_set_ps_disable_cfm_handler_sm(p)
    of ME_SET_ACTIVE_CFM: me_set_active_cfm_handler_sm(p)
    of MM_STA_DEL_CFM: result = smCleanupCfmHandler(p)
    of MM_SET_VIF_STATE_CFM: discard smCleanupConsumeReply(p)
    else: doAssert false, "unexpected SM reply"
  elif h.destId == TASK_ME:
    if h.srcId == TASK_SM: doAssert h.paramLen == 2
    case h.id
    of ME_SET_PS_DISABLE_REQ:
      commands.add(h.id)
      result = me_set_ps_disable_req_handler(p)
    of ME_SET_ACTIVE_REQ:
      commands.add(h.id)
      result = me_set_active_req_handler(p)
    of MM_SET_IDLE_CFM: result = mm_set_idle_cfm_handler(p)
    of MM_SET_PS_MODE_CFM: result = mm_set_ps_mode_cfm_handler(p)
    else: doAssert false, "unexpected ME message"
  else:
    doAssert h.destId == TASK_MM
    case h.id
    of MM_STA_DEL_REQ:
      doAssert h.paramLen == 1
      commands.add(h.id)
      result = mm_sta_del_req_handler(p)
    of MM_SET_VIF_STATE_REQ:
      doAssert h.paramLen == 4
      commands.add(h.id)
      if smCleanupAdmitRequest(p):
        let req = cast[ptr MmSetVifStateReqPayload](p)
        doAssert req.state == 0 and req.aid == 0
        vifs[req.vifIdx].state = req.state
        ke_msg_send_basic_reply(p, MM_SET_VIF_STATE_CFM)
    of MM_SET_IDLE_REQ: result = mm_set_idle_req_handler(p)
    of MM_SET_PS_MODE_REQ: result = mm_set_ps_mode_req_handler(p)
    else: doAssert false, "unexpected MM message"
  if result == KeMsgConsumed: ke_msg_free(h)
  elif result == KeMsgSaved: co_list_push_back(addr keMsgQueueSaved, h)
  else: doAssert result == KeMsgNoFree

proc drain() =
  var steps = 0
  while wifiMainHasPendingWork():
    inc steps
    doAssert steps <= 40, "cleanup stopped making progress"
    discard wifiDrainScheduledWork()
  doAssert not smCleanup.active
  doAssert smState == 0 and starts == 0 and interruptsEnabled

proc setup() =
  vifs[0] = VifChannelView(vifIdx: 0, vifType: VIF_TYPE_STA, state: 1,
                         staIdx: 2, chanCtxt: addr cleanupChannel)
  vifs[1] = VifChannelView(vifIdx: 1, vifType: VIF_TYPE_AP, state: 1,
                         staIdx: 6, chanCtxt: cast[pointer](2))
  rxVifEpochs = [1'u32, 1]
  stationEpochs[2] = 7
  sm.connectInfo = newMessage(0x1000, TASK_SM, TASK_API, 32)
  sm.scanResultIndex = 0xFFFFFFFF'u32
  cast[ptr uint8](sm.connectInfo)[] = 0
  callbacks.stationDisconnected = cast[pointer](stationDisconnected)
  wpa_cbs = addr callbacks
  me.psOn = 1
  me.activeMask = 3
  me.psDisableMask = 3
  me.requesterId = TASK_NONE
  nimFwWpaPendingMask = 3

proc completed(expectedCleanups = 1'u32) =
  doAssert nimFwDbgDisconnectInd == expectedCleanups
  doAssert commands == @[ME_SET_PS_DISABLE_REQ, MM_SET_VIF_STATE_REQ,
                        MM_STA_DEL_REQ, ME_SET_ACTIVE_REQ]
  doAssert callbackCalls == 1 and removed == @[2'u8] and unlinks == 1
  doAssert me.activeMask == 2 and me.psDisableMask == 2
  doAssert vifs[0].state == 0 and vifs[0].staIdx == 255 and vifs[0].chanCtxt == nil
  doAssert vifs[1].state == 1 and vifs[1].staIdx == 6
  doAssert vifs[1].chanCtxt == cast[pointer](2)
  doAssert allocated.len == 0 and smCleanupTags == nil
setup()
'''

CASES = {
    "disconnect": r'''
sm.saQueryActive = 1
sm_disconnect_process(addr vifs[0], 19, 3)
doAssert sm.saQueryActive == 0
doAssert timerClears == @[SM_SA_QUERY_TIMEOUT_IND_MSG]
doAssert smState == 10 and notifications.len == 0 and callbackCalls == 1
doAssert commands.len == 0 and keMsgQueueSent.first.id == ME_SET_PS_DISABLE_REQ
drain()
completed()
doAssert notifications.len == 1 and notifications[0].status == 19 and notifications[0].reason == 3
''',
    "cleanup_only": r'''
sm_delete_resources(addr vifs[0])
doAssert smState == 10
drain()
completed()
doAssert notifications.len == 0
''',
    "inactive": r'''
vifs[0].state = 0
vifs[0].staIdx = 255
vifs[0].chanCtxt = nil
sm_delete_resources(nil)
drain()
doAssert commands == @[ME_SET_PS_DISABLE_REQ, ME_SET_ACTIVE_REQ]
doAssert callbackCalls == 1 and removed.len == 0 and unlinks == 0
doAssert me.activeMask == 2 and me.psDisableMask == 2 and allocated.len == 0
''',
    "ps_delayed": r'''
psDeferred = true
sm_disconnect_process(addr vifs[0], 19, 3)
driveOne()
driveOne()
doAssert mmPsModeRequest != nil and smState == 10 and notifications.len == 0
doAssert not smCleanupNeedsService() and callbackCalls == 1
mmPsModeComplete()
drain()
completed()
''',
    "wrong_reply": r'''
sm_delete_resources(addr vifs[0])
while keMsgQueueSent.first.destId != TASK_SM: driveOne()
let h = co_list_pop_front(addr keMsgQueueSent)
let p = keMsgPayload(h)
let original = h[]
h.srcId = TASK_API
me_set_ps_disable_cfm_handler_sm(p)
doAssert smCleanup.step == 0 and smCleanup.awaiting
h[] = original
h.id = ME_SET_ACTIVE_CFM
me_set_active_cfm_handler_sm(p)
doAssert smCleanup.step == 0 and smCleanup.awaiting
h[] = original
h.paramLen = 1
me_set_ps_disable_cfm_handler_sm(p)
doAssert smCleanup.step == 0 and smCleanup.awaiting
h[] = original
me_set_ps_disable_cfm_handler_sm(p)
let nextStep = smCleanup.step
me_set_ps_disable_cfm_handler_sm(p)
doAssert smCleanup.step == nextStep
ke_msg_free(h)
drain()
completed()
''',
    "queued_cancel": r'''
sm_delete_resources(addr vifs[0])
let held = co_list_pop_front(addr keMsgQueueSent)
smCleanupCancel()
inc rxVifEpochs[0]
smState = 0
doAssert me_set_ps_disable_req_handler(keMsgPayload(held)) == KeMsgConsumed
ke_msg_free(held)
doAssert me.psDisableMask == 3 and me.activeMask == 3
doAssert allocated.len == 0 and smCleanupTags == nil
''',
    "late_reply": r'''
sm_delete_resources(addr vifs[0])
while keMsgQueueSent.first.destId != TASK_SM: driveOne()
let held = co_list_pop_front(addr keMsgQueueSent)
smCleanupCancel()
inc rxVifEpochs[0]
smState = 0
doAssert smCleanupBegin(addr vifs[0])
let serial = smCleanup.serial
me_set_ps_disable_cfm_handler_sm(keMsgPayload(held))
doAssert smCleanup.serial == serial and smCleanup.step == 0 and smCleanup.awaiting
ke_msg_free(held)
drain()
doAssert allocated.len == 0 and me.activeMask == 2 and starts == 0
''',
    "cancel_ps_pending": r'''
psDeferred = true
sm_delete_resources(addr vifs[0])
driveOne()
driveOne()
doAssert meState == MeBusyState and mmPsModeRequest != nil
smCleanupCancel()
doAssert meState == MeIdleState and mmPsModeRequest == nil
doAssert allocated.len == 0 and smCleanupTags == nil
''',
    "rebind_allocation": r'''
allocationHook = proc() =
  inc rxVifEpochs[0]
  smState = 0
sm_delete_resources(addr vifs[0])
doAssert smCleanupNeedsService()
smCleanupService()
doAssert not smCleanup.active and smState == 0
doAssert callbackCalls == 0 and commands.len == 0 and allocated.len == 0
''',
    "rebind_callback": r'''
disconnectedHook = proc() =
  inc rxVifEpochs[0]
  smState = 0
sm_delete_resources(addr vifs[0])
doAssert callbackCalls == 1 and commands.len == 0
smCleanupService()
doAssert not smCleanup.active and smState == 0 and allocated.len == 0
''',
    "nested_cleanup": r'''
disconnectedHook = proc() =
  let serial = smCleanup.serial
  sm_delete_resources(addr vifs[0])
  doAssert smCleanup.serial == serial
sm_delete_resources(addr vifs[0])
drain()
completed()
''',
    "station_reuse": r'''
sm_delete_resources(addr vifs[0])
while keMsgQueueSent.first.id != MM_STA_DEL_REQ: driveOne()
inc stationEpochs[2]
drain()
doAssert removed.len == 0 and vifs[0].staIdx == 2
doAssert me.activeMask == 2 and allocated.len == 0
''',
    "station_wrong_vif": r'''
stations[2].instNbr = 1
sm_delete_resources(addr vifs[0])
drain()
doAssert removed.len == 0 and vifs[0].staIdx == 255
doAssert stations[2].instNbr == 1 and vifs[1].staIdx == 6
doAssert commands == @[ME_SET_PS_DISABLE_REQ, MM_SET_VIF_STATE_REQ, ME_SET_ACTIVE_REQ]
doAssert unlinks == 1 and me.activeMask == 2 and allocated.len == 0
''',
    "station_changes_vif_before_delete": r'''
sm_delete_resources(addr vifs[0])
while keMsgQueueSent.first.id != MM_STA_DEL_REQ: driveOne()
stations[2].instNbr = 1
drain()
doAssert removed.len == 0 and vifs[0].staIdx == 2
doAssert stations[2].instNbr == 1 and vifs[1].staIdx == 6
doAssert me.activeMask == 2 and allocated.len == 0
''',
    "invalid_station_index": r'''
vifs[0].staIdx = 200
sm_delete_resources(addr vifs[0])
drain()
doAssert removed.len == 0 and vifs[0].staIdx == 255
doAssert commands == @[ME_SET_PS_DISABLE_REQ, MM_SET_VIF_STATE_REQ, ME_SET_ACTIVE_REQ]
doAssert unlinks == 1 and me.activeMask == 2 and allocated.len == 0
''',
    "connect_failure": r'''
let indication = newMessage(0x1002, TASK_API, TASK_SM, 860)
sm.connectIndMsg = indication
doAssert smCleanupBegin(addr vifs[0], indication)
doAssert sm.connectInfo == nil and sm.connectIndMsg == nil and smState == 10
drain()
doAssert controlReplies.len == 1 and controlReplies[0].id == 0x1002
completed()
''',
    "persistent_pressure": r'''
failEveryAllocation = true
sm_delete_resources(addr vifs[0])
for attempt in 0 ..< 3:
  doAssert wifiMainHasPendingWork()
  discard wifiDrainScheduledWork()
doAssert smState == 10 and callbackCalls == 0 and commands.len == 0
doAssert vifs[0].state == 1 and me.activeMask == 3 and allocated.len == 0
failEveryAllocation = false
drain()
completed()
''',
    "actual_connect_failure": r'''
sm.connectIndMsg = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
sm_connect_ind(8, 15)
doAssert smState == 10 and sm.connectInfo == nil and sm.connectIndMsg == nil
drain()
completed()
doAssert controlReplies.len == 1 and controlReplies[0].id == SM_CONNECT_IND_MSG
''',
    "success_callback_replacement": r'''
sm.connectIndMsg = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
var replacementConnection, replacementIndication: pointer
indicationHook = proc() =
  doAssert sm.connectInfo == nil and sm.connectIndMsg == nil
  replacementConnection = newMessage(0x1000, TASK_SM, TASK_API, 32)
  replacementIndication = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
  sm.connectInfo = replacementConnection
  sm.connectIndMsg = replacementIndication
  inc rxVifEpochs[0]
  smState = 4
sm_connect_ind(0, 0)
doAssert sm.connectInfo == replacementConnection and sm.connectIndMsg == replacementIndication
doAssert allocated.len == 2 and callbackCalls == 0 and smState == 4
ke_msg_free(keMsgHdrFromPayload(replacementConnection))
ke_msg_free(keMsgHdrFromPayload(replacementIndication))
''',
    "success_free_replacement": r'''
sm.connectIndMsg = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
var replacementConnection, replacementIndication: pointer
freeHook = proc() =
  replacementConnection = newMessage(0x1000, TASK_SM, TASK_API, 32)
  replacementIndication = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
  sm.connectInfo = replacementConnection
  sm.connectIndMsg = replacementIndication
  inc rxVifEpochs[0]
  smState = 4
sm_connect_ind(0, 0)
doAssert sm.connectInfo == replacementConnection and sm.connectIndMsg == replacementIndication
doAssert controlReplies.len == 0 and allocated.len == 2
ke_msg_free(keMsgHdrFromPayload(replacementConnection))
ke_msg_free(keMsgHdrFromPayload(replacementIndication))
''',
    "failure_scan_replacement": r'''
sm.connectIndMsg = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
sm.scanResultIndex = 0
var replacementConnection, replacementIndication: pointer
scanRemoveHook = proc() =
  ke_msg_free(keMsgHdrFromPayload(sm.connectInfo))
  ke_msg_free(keMsgHdrFromPayload(sm.connectIndMsg))
  replacementConnection = newMessage(0x1000, TASK_SM, TASK_API, 32)
  replacementIndication = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
  sm.connectInfo = replacementConnection
  sm.connectIndMsg = replacementIndication
  sm.scanResultIndex = 42
  inc rxVifEpochs[0]
  smState = 4
sm_connect_ind(8, 15)
doAssert sm.connectInfo == replacementConnection and sm.connectIndMsg == replacementIndication
doAssert sm.scanResultIndex == 42 and smState == 4 and not smCleanup.active
ke_msg_free(keMsgHdrFromPayload(replacementConnection))
ke_msg_free(keMsgHdrFromPayload(replacementIndication))
''',
    "reply_callback_replacement": r'''
indicationHook = proc() =
  doAssert smState == 0 and not smCleanup.active
  sm.connectInfo = newMessage(0x1000, TASK_SM, TASK_API, 32)
  doAssert smCleanupBegin(addr vifs[0])
sm_disconnect_process(addr vifs[0], 19, 3)
drain()
doAssert callbackCalls == 2 and notifications.len == 1 and allocated.len == 0
''',
    "callback_irq": r'''
disconnectedHook = proc() = doAssert interruptsEnabled
sm_delete_resources(addr vifs[0])
drain()
completed()
''',
    "no_callbacks": r'''
wpa_cbs = nil
sm_delete_resources(addr vifs[0])
drain()
doAssert callbackCalls == 0 and me.activeMask == 2 and allocated.len == 0
''',
    "invalid_vif": r'''
doAssert not smCleanupBegin(addr vifs[1])
doAssert not smCleanupBegin(cast[pointer](123))
doAssert callbackCalls == 0 and allocated.len == 1
ke_msg_free(keMsgHdrFromPayload(sm.connectInfo))
''',
    "cleanup_nil_active": r'''
ke_msg_free(keMsgHdrFromPayload(sm.connectInfo))
sm.connectInfo = nil
sm_delete_resources(nil)
drain()
completed()
''',
    "replacement_during_allocation": r'''
allocationHook = proc() =
  smCleanupCancel()
  inc rxVifEpochs[0]
  smState = 0
  sm.connectInfo = newMessage(0x1000, TASK_SM, TASK_API, 32)
  doAssert smCleanupBegin(addr vifs[0])
sm_delete_resources(addr vifs[0])
drain()
completed(2)
''',
    "preserve_disabled_irq": r'''
interruptsEnabled = false
disconnectedHook = proc() = doAssert not interruptsEnabled
sm_delete_resources(addr vifs[0])
var steps = 0
while wifiMainHasPendingWork():
  inc steps
  doAssert steps < 40
  discard wifiDrainScheduledWork()
doAssert not interruptsEnabled and smState == 0
completed()
''',
}

for allocation in range(1, 9):
    CASES[f"allocation_{allocation}"] = f'''
failAt = kernelAllocations + {allocation}
sm_disconnect_process(addr vifs[0], 19, 3)
doAssert smState == 10 and callbackCalls == 0 and commands.len == 0
doAssert vifs[0].state == 1 and me.activeMask == 3 and me.psDisableMask == 3
doAssert allocated.len == 0 and smCleanupTags == nil
failAt = 0
drain()
completed()
doAssert notifications.len == 1
'''


def program(case: str, mutation: str | None = None) -> str:
    code = program_source()
    code = code.replace(procedure(code, "chan_ctxt_unlink"), "")
    code = code.replace("    contextIndexOrMarker, invalidMarker: uint8",
                        "    contextIndexOrMarker, invalidMarker: uint8\n    channel: ChanCtxtDefView")
    for stub in [
        "proc smCleanupOwnsRequest(request: pointer): bool = false\n",
        "proc smCleanupTakeReply(request: pointer; id: uint16; length: uint32): pointer = nil\n",
        "proc smCleanupAdmitRequest(request: pointer): bool = true\n",
    ]:
        assert stub in code
        code = code.replace(stub, "")
    code = code.replace("    vifIdx, vifType, state, beaconEnabled: uint8",
                        "    vifIdx, vifType, state, beaconEnabled, staIdx, wmmAcFlags: uint8")
    code = code.replace("    beaconRegister, apStopped: pointer",
                        "    beaconRegister, apStopped, stationDisconnected: pointer")
    code = code.replace("  if kernelAllocations == failAt: return nil",
                        "  if failEveryAllocation or kernelAllocations == failAt: return nil")
    code = code.replace("proc ke_msg_free(h: pointer) =\n",
                        "proc ke_msg_free(h: pointer) =\n  smCleanupForget(h)\n")
    code = code.replace("  free(h)\n", "  free(h)\n  if freeHook != nil:\n    let action = freeHook\n    freeHook = nil\n    action()\n")
    code = code.replace("  if task == TASK_APM: state = value",
                        "  if task == TASK_SM: smState = value\n  elif task == TASK_APM: state = value")
    code = code.replace("  if task == TASK_APM: state elif task == TASK_MM: mmState else: meState",
                        "  if task == TASK_SM: smState elif task == TASK_APM: state elif task == TASK_MM: mmState else: meState")
    code = code.replace("proc irqSave(): uint32 = 8", "proc irqSave(): uint32 =\n  result = if interruptsEnabled: 8'u32 else: 0'u32\n  interruptsEnabled = false")
    code = code.replace("proc irqRestore(saved: uint32) = doAssert saved == 8",
                        "proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0")
    code = code.replace("  if h.destId >= TASK_API:\n", "  if h.destId >= TASK_API:\n    captureNotification(p)\n")
    code = code.replace("doAssert task == TASK_APM", "doAssert task in [TASK_APM, TASK_SM]")
    layout = (FW / "layout_types.nim").read_text()
    payload = "type\n  SmConnectIndPayload" + layout.split("  SmConnectIndPayload", 1)[1].split("\n\n  ", 1)[0] + "\n"
    code = PREFIX + "proc captureNotification(p: pointer)\n" + code + payload + PLATFORM
    code += """
proc captureNotification(p: pointer) =
  if keMsgHdrFromPayload(p).id == SM_DISCONNECT_IND:
    notifications.add(cast[ptr SmDisconnectProcessIndPayload](p)[])
  if indicationHook != nil:
    let action = indicationHook
    indicationHook = nil
    action()
"""
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "co_list_init")
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "ke_msg_forward_and_change_id")
    cleanup = (FW / "station_cleanup.nim").read_text()
    if mutation:
        before, after = {
            "power_save": ("needed: [true, vif.state != 0,", "needed: [false, vif.state != 0,"),
            "callback": ("    if callback != nil:\n", "    if false:\n"),
            "busy": ("    smCleanup.awaiting = true\n", "    smCleanup.awaiting = true\n    ke_state_set(TASK_SM, SmIdleState)\n"),
            "request_owner": ("if not tag.command or not smCleanupCurrent(tag.serial): return false", "if not tag.command: return false"),
            "reply_owner": ("      reply != smCleanup.reply or header.id != tag.responseId or\n", "      header.id != tag.responseId or\n"),
            "reply_source": ("header.srcId != tag.responseSource or ", ""),
        }[mutation]
        assert before in cleanup, mutation
        cleanup = cleanup.replace(before, after)
    code += cleanup
    tasks = (FW / "task_handlers.nim").read_text()
    for name in ["smSetActiveCfmStateAllowed", "me_set_active_cfm_handler_sm",
                 "me_set_ps_disable_cfm_handler_sm", "mm_sta_del_req_handler", "sm_delete_resources"]:
        code += procedure(tasks, name)
    code += procedure((FW / "scan_station_ap_me.nim").read_text(), "sm_disconnect_process")
    code += procedure((FW / "scan_station_ap_me.nim").read_text(), "sm_connect_ind")
    runtime = (FW / "task_init_main.nim").read_text()
    code += procedure(runtime, "wifiMainHasPendingWork")
    code += procedure(runtime, "wifiDrainScheduledWork")
    return code + DRIVER + CASES[case]


def run_native(tmp_path: Path, code: str, mode: str, fails: bool = False) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    source = tmp_path / "sm_cleanup.nim"
    source.write_text(code)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}[mode]
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--checks:on", *flags, f"--nimcache:{tmp_path / 'cache'}",
        f"-o:{tmp_path / 'test'}", str(source)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if fails:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
    else:
        assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_cleanup(tmp_path: Path, case: str, mode: str) -> None:
    run_native(tmp_path, program(case), mode)


@pytest.mark.parametrize("mutation,case", [
    ("power_save", "disconnect"), ("callback", "disconnect"), ("busy", "disconnect"),
    ("request_owner", "queued_cancel"), ("reply_owner", "wrong_reply"), ("reply_source", "wrong_reply"),
])
def test_cleanup_guards(tmp_path: Path, mutation: str, case: str) -> None:
    run_native(tmp_path, program(case, mutation), "checked", True)


def test_external_message_release_forgets_cleanup_metadata() -> None:
    sender = procedure((FW / "kernel_mac_channel.nim").read_text(), "ke_msg_send")
    assert sender.index("smCleanupForget(cast[pointer](hdr))") < sender.index("opsFn(cast[pointer](hdr))")
