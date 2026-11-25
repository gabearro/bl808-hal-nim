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
  sm_reconn_dominant_flag: uint32
  interruptsEnabled = true
  failEveryAllocation: bool
  allocationLimit = high(int)
  txResetInProgress: bool
  fakeMacState: uint32
  allocationHook, disconnectedHook, indicationHook, freeHook, scanRemoveHook, timerClearHook: proc()
  smStateHook: proc()
  smSaQuery: tuple[serial: uint32]
  onIrqRestore: proc()
  recycleOnFree, recycledHeader: pointer
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
    primaryFreq, centerFreq: uint16
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
  chanCtxtLinkEpochs: array[2, uint32]
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
proc keTimerClearLocked(id: uint16; task: uint8; saved: uint32) =
  doAssert task == TASK_SM and not interruptsEnabled
  timerClears.add(id)
  irqRestore(saved)
  if timerClearHook != nil: timerClearHook()
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
proc mmStaDelTry(index: uint8; saved: uint32): bool =
  mm_sta_del(index)
  true
proc mmStaDelRetryPending(index: uint8): bool = false
proc mmStaDelQueueRetryLocked(index: uint8; saved: uint32) = doAssert false
proc mmStaDelOwned(index, vif: uint8; epoch: uint32): bool = false
proc chan_ctxt_unlink(index: uint8) =
  inc unlinks
  inc chanCtxtLinkEpochs[index]
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
proc sm_send_next_bss_param() = inc starts
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
proc wifiResetEventPending(): bool = false
proc wifiDispatchScheduledEvent(): bool =
  result = wifiEventPendingWork()
  if result: driveOne()
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
    "established_supplicant_failure": r'''
let completedJoin = sm.connectInfo
sm.connectInfo = nil
ke_msg_free(keMsgHdrFromPayload(completedJoin))
smState = SmIdleState
stations[2].valid = 1
stations[2].instNbr = 0
smRetireEstablishedSupplicantLink(2, 15)
doAssert notifications.len == 1 and notifications[0].status == 8 and notifications[0].reason == 15
smRetireEstablishedSupplicantLink(2, 15)
doAssert notifications.len == 1
drain()
completed()
smRetireEstablishedSupplicantLink(2, 15)
doAssert notifications.len == 1 and smState == SmIdleState
''',
    "disconnect": r'''
sm.saQueryActive = 1
sm_reconn_dominant_flag = 1
indicationHook = proc() =
  doAssert rxHostStationIndicationTop != nil
  doAssert rxHostStationIndicationTop.session.vif == 0
sm_disconnect_process(addr vifs[0], 19, 3)
doAssert sm.saQueryActive == 0
doAssert sm_reconn_dominant_flag == 0
doAssert timerClears == @[SM_SA_QUERY_TIMEOUT_IND_MSG]
doAssert smState == 10 and notifications.len == 1 and callbackCalls == 1
doAssert commands.len == 0 and keMsgQueueSent.first.id == ME_SET_PS_DISABLE_REQ
drain()
completed()
doAssert notifications.len == 1 and notifications[0].status == 19 and notifications[0].reason == 3
''',
    "disconnect_callback_can_finish_cleanup": r'''
var finishedInside = false
indicationHook = proc() =
  doAssert smCleanup.step == 0 and smCleanup.awaiting and interruptsEnabled
  for _ in 0 ..< 24:
    if not smCleanup.active: break
    discard wifiDrainScheduledWork()
  doAssert not smCleanup.active and smState == SmIdleState
  doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
  finishedInside = true
sm_disconnect_process(addr vifs[0], 19, 3)
doAssert finishedInside and notifications.len == 1
doAssert not smCleanupServicing and rxHostStationIndicationTop == nil
completed()
''',
    "disconnect_timer_replacement": r'''
let connection = sm.connectInfo
sm.saQueryActive = 1
sm_reconn_dominant_flag = 1
timerClearHook = proc() =
  doAssert sm.saQueryActive == 0
  doAssert sm_reconn_dominant_flag == 1
  inc rxVifEpochs[0]
  sm.saQueryActive = 1
sm_disconnect_process(addr vifs[0], 7, 7)
doAssert timerClears == @[SM_SA_QUERY_TIMEOUT_IND_MSG]
doAssert sm.saQueryActive == 1 and sm.connectInfo == connection
doAssert sm_reconn_dominant_flag == 1
doAssert not smCleanup.active and notifications.len == 0 and callbackCalls == 0
doAssert vifs[0].state == 1 and vifs[0].staIdx == 2
doAssert vifs[0].chanCtxt == (addr cleanupChannel) and interruptsEnabled
timerClearHook = nil
sm_disconnect_process(addr vifs[0], 7, 7)
doAssert sm_reconn_dominant_flag == 0
drain()
completed()
doAssert notifications.len == 1 and notifications[0].status == 7 and notifications[0].reason == 7
''',
    "disconnect_detaches_timer_before_unlock": r'''
let owner = SmDisconnectHandoff(peer: mmCaptureVif(addr vifs[0]),
  connection: sm.connectInfo, resetEpoch: txResetEpoch, state: SmDisconnectingState)
sm.saQueryActive = 1
var replacementArmed = false
onIrqRestore = proc() =
  doAssert timerClears == @[SM_SA_QUERY_TIMEOUT_IND_MSG]
  inc rxVifEpochs[0]
  sm.saQueryActive = 1
  replacementArmed = true
smDisconnectOwned(owner, 7, 7)
doAssert replacementArmed and interruptsEnabled and sm.saQueryActive == 1
doAssert not smCleanup.active and callbackCalls == 0 and notifications.len == 0
doAssert sm.connectInfo == owner.connection and vifs[0].state == 1
ke_msg_free(keMsgHdrFromPayload(sm.connectInfo))
doAssert allocated.len == 0
''',
    "query_serial_owns_cleanup_across_timer_clear": r'''
smSaQuery.serial = 41
let stale = SmDisconnectHandoff(peer: mmCaptureVif(addr vifs[0]),
  connection: sm.connectInfo, resetEpoch: txResetEpoch, state: SmDisconnectingState,
  saQuerySerial: 40)
sm.saQueryActive = 1
smDisconnectOwned(stale, 7, 7)
doAssert timerClears.len == 0 and sm.saQueryActive == 1 and not smCleanup.active

var current = stale
current.saQuerySerial = 41
timerClearHook = proc() =
  doAssert interruptsEnabled and sm.saQueryActive == 0
  inc smSaQuery.serial
  sm.saQueryActive = 1
smDisconnectOwned(current, 7, 7)
doAssert timerClears == @[SM_SA_QUERY_TIMEOUT_IND_MSG]
doAssert sm.saQueryActive == 1 and smSaQuery.serial == 42
doAssert not smCleanup.active and callbackCalls == 0 and notifications.len == 0

timerClearHook = nil
current.saQuerySerial = 42
smDisconnectOwned(current, 7, 7)
drain()
completed()
doAssert notifications.len == 1 and notifications[0].status == 7 and notifications[0].reason == 7
''',
    "cleanup_only": r'''
sm_reconn_dominant_flag = 1
sm_delete_resources(addr vifs[0])
doAssert sm_reconn_dominant_flag == 1
doAssert smState == 10
drain()
completed()
doAssert notifications.len == 0
''',
    "limited_live_messages": r'''
allocationLimit = 3
sm_disconnect_process(addr vifs[0], 19, 3)
doAssert smCleanup.awaiting and smCleanup.step == 0
doAssert notifications.len == 1 and callbackCalls == 1
drain()
completed()
doAssert notifications.len == 1
''',
    "defer_while_tx_resets": r'''
txResetInProgress = true
sm_disconnect_process(addr vifs[0], 19, 3)
doAssert smCleanup.active and smState == SmDisconnectingState
doAssert not smCleanupNeedsService() and keMsgQueueSent.first == nil
smCleanupService()
doAssert notifications.len == 0 and commands.len == 0 and keMsgQueueSent.first == nil
txResetInProgress = false
doAssert smCleanupNeedsService()
smCleanupService()
drain()
completed()
doAssert notifications.len == 1 and notifications[0].status == 19
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
doAssert mmPsModeRequest != nil and smState == 10 and notifications.len == 1
doAssert not smCleanupNeedsService() and callbackCalls == 1
mmPsModeComplete()
drain()
completed()
''',
    "disconnect_pending_station_delete": r'''
vifApConfig(addr vifs[0]).securityFlags = 3
vifApConfig(addr vifs[1]).securityFlags = 7
indicationHook = proc() =
  doAssert smState == 10 and smCleanup.active and smCleanup.awaiting
  doAssert smCleanup.indication == nil
  doAssert keMsgQueueSent.first.id == ME_SET_PS_DISABLE_REQ
  doAssert callbackCalls == 1
  doAssert vifs[0].chanCtxt == nil and unlinks == 1,
    "link loss notified before the old channel detached"
  doAssert vifApConfig(addr vifs[0]).securityFlags == 0,
    "link loss notified before the retiring VIF flags cleared"
  doAssert vifApConfig(addr vifs[1]).securityFlags == 7
sm_disconnect_process(addr vifs[0], 7, 7)
while keMsgQueueSent.first.id != MM_STA_DEL_CFM: driveOne()
let held = co_list_pop_front(addr keMsgQueueSent)
doAssert smState == 10 and smCleanup.active and smCleanup.awaiting
doAssert smCleanup.step == 2 and removed == @[2'u8] and unlinks == 1
doAssert notifications.len == 1 and notifications[0].status == 7 and notifications[0].reason == 7
doAssert not wifiMainHasPendingWork()
smCleanupService()
doAssert notifications.len == 1 and smState == 10
co_list_push_back(addr keMsgQueueSent, held)
drain()
completed()
doAssert notifications.len == 1
''',
    "disconnect_indication_replaces_session": r'''
indicationHook = proc() =
  doAssert smState == 10 and smCleanup.indication == nil
  doAssert unlinks == 1
  inc rxVifEpochs[0]
  inc chanCtxtLinkEpochs[0]
  vifs[0].chanCtxt = addr cleanupChannel
  vifApConfig(addr vifs[0]).securityFlags = 9
  smState = 0
sm_disconnect_process(addr vifs[0], 7, 7)
doAssert notifications.len == 1 and smCleanupNeedsService()
smCleanupService()
while keMsgQueueSent.first != nil: driveOne()
doAssert not smCleanup.active and smState == 0 and unlinks == 1 and removed.len == 0
doAssert vifs[0].chanCtxt == addr cleanupChannel
doAssert vifApConfig(addr vifs[0]).securityFlags == 9
doAssert allocated.len == 0 and smCleanupTags == nil
''',
    "channel_rebound_before_detach": r'''
# Recycle the same channel pointer during the WPA callback; pointer
# equality alone cannot distinguish the replacement binding.
disconnectedHook = proc() =
  doAssert vifs[0].chanCtxt == (addr cleanupChannel) and unlinks == 0
  inc chanCtxtLinkEpochs[0]
sm_disconnect_process(addr vifs[0], 7, 7)
drain()
doAssert notifications.len == 1 and removed == @[2'u8]
doAssert vifs[0].chanCtxt == (addr cleanupChannel) and unlinks == 0,
  "stale cleanup detached a replacement channel"
doAssert allocated.len == 0 and smCleanupTags == nil
''',
    "wrong_reply": r'''
sm_delete_resources(addr vifs[0])
doAssert smCleanup.replyReserved
discard smCleanupConsumeReply(smCleanup.reply)
doAssert smCleanup.step == 0 and smCleanup.awaiting
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
driveOne()
doAssert smCleanup.step == nextStep and smCleanup.awaiting and not smCleanup.replyReserved
me_set_ps_disable_cfm_handler_sm(p)
doAssert smCleanup.step == nextStep
ke_msg_free(h)
drain()
completed()
''',
    "activation_saved_behind_disconnect_reply": r'''
me.activeMask = 1
sm_disconnect_process(addr vifs[0], 7, 7)
while keMsgQueueSent.first.id != ME_SET_ACTIVE_REQ: driveOne()
mmState = MM_IDLE
driveOne()
doAssert meState == MeBusyState and keMsgQueueSent.first.id == MM_SET_IDLE_REQ

let next = newMessage(ME_SET_ACTIVE_REQ, TASK_ME, TASK_API, 2)
cast[ptr array[2, uint8]](next)[] = [1'u8, 1]
ke_msg_send(next)
driveOne() # The fake MAC reports idle, appending MM_SET_IDLE_CFM.
driveOne() # ME is still busy, so the competing activation is saved.
doAssert keMsgQueueSaved.first == keMsgHdrFromPayload(next)
doAssert keMsgQueueSent.first.id == MM_SET_IDLE_CFM
driveOne()
doAssert keMsgQueueSent.first.id == ME_SET_ACTIVE_CFM,
  "saved ME work overtook the final disconnect confirmation"
doAssert smState == SmDisconnectingState
driveOne()
doAssert smState == SmIdleState and not smCleanup.active
doAssert keMsgQueueSent.first == keMsgHdrFromPayload(next)
drain()
doAssert me.activeMask == 2 and allocated.len == 0 and smCleanupTags == nil
''',
    "activation_waits_for_mac_idle_event": r'''
me.activeMask = 1
sm_disconnect_process(addr vifs[0], 7, 7)
while keMsgQueueSent.first.id != ME_SET_ACTIVE_REQ: driveOne()
mmState = 1
fakeMacState = 1
driveOne()
let idleRequest = keMsgQueueSent.first
doAssert idleRequest.id == MM_SET_IDLE_REQ
driveOne()
doAssert mmState == TaskGoingIdleState and idleRequests == 1
doAssert keMsgQueueSaved.first == idleRequest and smCleanup.awaiting and smCleanup.step == 3

let next = newMessage(ME_SET_ACTIVE_REQ, TASK_ME, TASK_API, 2)
cast[ptr array[2, uint8]](next)[] = [1'u8, 1]
ke_msg_send(next)
driveOne()
doAssert keMsgQueueSaved.last == keMsgHdrFromPayload(next)
ke_msg_send(newMessage(MM_SET_IDLE_CFM, TASK_ME, TASK_MM, 0))
driveOne()
doAssert meState == MeBusyState and mmState == TaskGoingIdleState
doAssert smState == SmDisconnectingState and smCleanup.awaiting
doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == idleRequest

fakeMacState = 0
idleEventBits = KE_EVT_IDLE
mm_hw_idle_evt()
doAssert idleEventBits == 0 and mmState == MM_IDLE
doAssert keMsgQueueSent.first == idleRequest and keMsgQueueSaved.first == keMsgHdrFromPayload(next)
driveOne()
doAssert keMsgQueueSent.first.id == MM_SET_IDLE_CFM
driveOne()
doAssert keMsgQueueSent.first.id == ME_SET_ACTIVE_CFM
doAssert smState == SmDisconnectingState
driveOne()
doAssert smState == SmIdleState and not smCleanup.active
doAssert keMsgQueueSent.first == keMsgHdrFromPayload(next)
drain()
doAssert me.activeMask == 2 and allocated.len == 0 and smCleanupTags == nil
doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
''',
    "external_me_reply_restarts_control": r'''
ke_msg_free(keMsgHdrFromPayload(sm.connectInfo))
sm.connectInfo = nil
smState = SmIdleState
me.activeMask = 1
mmState = MM_IDLE
let dropping = newMessage(ME_SET_ACTIVE_REQ, TASK_ME, TASK_API, 2)
cast[ptr array[2, uint8]](dropping)[] = [0'u8, 0]
ke_msg_send(dropping)
driveOne()
driveOne()
var replacement: pointer
indicationHook = proc() =
  doAssert meState == MeBusyState and meControlReply == nil
  meControlReset()
  ke_state_set(TASK_ME, MeIdleState)
  replacement = newMessage(ME_SET_ACTIVE_REQ, TASK_ME, TASK_API, 2)
  cast[ptr array[2, uint8]](replacement)[] = [1'u8, 1]
  doAssert me_set_active_req_handler(replacement) == KeMsgNoFree
driveOne()
doAssert meState == MeBusyState and meControlCommand == replacement
drain()
doAssert meState == MeIdleState and me.activeMask == 2 and allocated.len == 0
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
    "retired_vif_releases_saved_connect": r'''
psDeferred = true
sm_disconnect_process(addr vifs[0], 7, 7)
driveOne()
driveOne()
doAssert smCleanup.awaiting and smState == SmDisconnectingState
doAssert mmPsModeRequest != nil and meState == MeBusyState
let reconnect = newMessage(0x1000, TASK_SM, TASK_API, 32)
co_list_push_back(addr keMsgQueueSaved, keMsgHdrFromPayload(reconnect))
# The quiesced invalidation is the epoch boundary used by VIF unregister.
rxInvalidateQuiescentVif(0, 0)
vifs[0].vifType = 4
doAssert smCleanupNeedsService()
smCleanupService()
doAssert smState == SmIdleState and not smCleanup.active and interruptsEnabled
doAssert mmPsModeRequest == nil and meState == MeIdleState
doAssert keMsgQueueSaved.first == nil and keMsgQueueSent.first == keMsgHdrFromPayload(reconnect)
doAssert notifications.len == 1 and callbackCalls == 1
ke_msg_free(co_list_pop_front(addr keMsgQueueSent))
doAssert allocated.len == 0 and smCleanupTags == nil
''',
    "retired_request_address_reused": r'''
# The ME no-transition branch queues a separate reply and consumes the request.
me.psOn = 0
sm_delete_resources(addr vifs[0])
let retiredRequest = smCleanup.request
recycleOnFree = keMsgHdrFromPayload(retiredRequest)
driveOne()
doAssert keMsgQueueSent.first.id == ME_SET_PS_DISABLE_CFM
doAssert smCleanup.awaiting and not smCleanup.replyReserved

let replacement = newMessage(ME_SET_ACTIVE_REQ, TASK_ME, TASK_API, 2)
doAssert replacement == retiredRequest and recycledHeader == nil
cast[ptr array[2, uint8]](replacement)[] = [0'u8, 0]
ke_msg_send(replacement)
inc rxVifEpochs[0]
smCleanupService()
doAssert not smCleanup.active and smState == SmIdleState
doAssert keMsgQueueSent.first == keMsgHdrFromPayload(replacement),
  "cleanup cancelled a different request at the released address"
doAssert allocated == @[replacement] and smCleanupTags == nil
while keMsgQueueSent.first != nil: driveOne()
doAssert allocated.len == 0 and meState == MeIdleState and me.activeMask == 2
''',
    "retired_vif_does_not_release_replacement": r'''
sm_delete_resources(addr vifs[0])
rxInvalidateQuiescentVif(0, 0)
var replacementSerial: uint32
freeHook = proc() =
  doAssert smCleanupBegin(addr vifs[0])
  replacementSerial = smCleanup.serial
smCleanupService()
doAssert replacementSerial != 0 and smCleanup.active and smCleanup.serial == replacementSerial
doAssert smState == SmDisconnectingState and interruptsEnabled
callbackCalls = 0
drain()
doAssert callbackCalls == 1 and allocated.len == 0 and smCleanupTags == nil
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
indicationHook = proc() =
  doAssert rxHostStationIndicationTop != nil
  doAssert rxHostStationIndicationTop.payload == indication
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
    "connect_indication_channel_cache": r'''
for linked in [true, false]:
  if not linked:
    setup()
    vifs[0].chanCtxt = nil
  sm.primaryFreq = 2412
  sm.centerFreq = 2412
  cleanupChannel.channel.primFreq = 2452
  cleanupChannel.channel.centerFreq1 = 2462
  sm.connectIndMsg = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
  let sent = smConnectIndPayloadAt(sm.connectIndMsg)
  sent.assocReqIeLen = 12
  sent.assocRspIeLen = 8
  for i in 0..<sent.assocIeBuffer.len: sent.assocIeBuffer[i] = (i mod 251).uint8
  let ies = sent.assocIeBuffer
  var notified = false
  indicationHook = proc() =
    doAssert sm.connectInfo == nil and sm.connectIndMsg == nil
    doAssert sent.assocReqIeLen == 12 and sent.assocRspIeLen == 8
    doAssert sent.assocIeBuffer == ies
    if linked:
      doAssert (sm.primaryFreq, sm.centerFreq) == (2452'u16, 2462'u16)
      doAssert sent.chanPrimFreq == 2452 and sent.chanCenterFreq1 == 2462
    else:
      doAssert (sm.primaryFreq, sm.centerFreq) == (2412'u16, 2412'u16)
      doAssert sent.chanPrimFreq == 0 and sent.chanCenterFreq1 == 0
    notified = true
  sm_connect_ind(0, 0)
  doAssert notified and allocated.len == 0
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
    "failure_state_replacement": r'''
smState = SmSettingBssState
sm.connectIndMsg = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
var replacementConnection, replacementIndication: pointer
smStateHook = proc() =
  doAssert smState == SmDisconnectingState
  smStateHook = nil
  ke_msg_free(keMsgHdrFromPayload(sm.connectInfo))
  ke_msg_free(keMsgHdrFromPayload(sm.connectIndMsg))
  replacementConnection = newMessage(0x1000, TASK_SM, TASK_API, 32)
  replacementIndication = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
  sm.connectInfo = replacementConnection
  sm.connectIndMsg = replacementIndication
  sm.scanResultIndex = 42
  inc rxVifEpochs[0]
  smState = SmSettingBssState
sm_connect_ind(8, 15)
doAssert sm.connectInfo == replacementConnection and sm.connectIndMsg == replacementIndication
doAssert sm.scanResultIndex == 42 and smState == SmSettingBssState and not smCleanup.active
doAssert allocated.len == 2 and callbackCalls == 0
ke_msg_free(keMsgHdrFromPayload(replacementConnection))
ke_msg_free(keMsgHdrFromPayload(replacementIndication))
''',
    "reply_callback_replacement": r'''
sm.connectIndMsg = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
indicationHook = proc() =
  doAssert smState == 0 and not smCleanup.active
  sm.connectInfo = newMessage(0x1000, TASK_SM, TASK_API, 32)
  doAssert smCleanupBegin(addr vifs[0])
sm_connect_ind(8, 15)
drain()
doAssert callbackCalls == 2 and notifications.len == 0 and allocated.len == 0
doAssert controlReplies.len == 1 and controlReplies[0].id == SM_CONNECT_IND_MSG
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
    "replacement_during_later_allocation": r'''
sm_disconnect_process(addr vifs[0], 19, 3)
while keMsgQueueSent.first.destId != TASK_SM: driveOne()
let first = smCleanup.serial
allocationHook = proc() =
  doAssert smCleanup.step == 1 and not smCleanup.awaiting
  smCleanupCancel()
  inc rxVifEpochs[0]
  smState = 0
  sm.connectInfo = newMessage(0x1000, TASK_SM, TASK_API, 32)
  doAssert smCleanupBegin(addr vifs[0])
driveOne()
doAssert smCleanup.active and smCleanup.serial != first and smCleanup.step == 0
doAssert smCleanup.request == nil and smCleanup.reply == nil and smCleanupTags == nil
doAssert notifications.len == 1 and callbackCalls == 1
doAssert commands == @[ME_SET_PS_DISABLE_REQ]
commands.setLen(0)
callbackCalls = 0
drain()
completed(2)
doAssert notifications.len == 1
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

for allocation in range(1, 4):
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

for allocation, step in [(4, 1), (5, 1), (6, 2), (7, 3), (8, 3)]:
    CASES[f"allocation_{allocation}"] = f'''
failAt = kernelAllocations + {allocation}
sm_disconnect_process(addr vifs[0], 19, 3)
let order = @[ME_SET_PS_DISABLE_REQ, MM_SET_VIF_STATE_REQ,
              MM_STA_DEL_REQ, ME_SET_ACTIVE_REQ]
for attempt in 0 ..< 20:
  if kernelAllocations >= failAt: break
  doAssert keMsgQueueSent.first != nil
  driveOne()
doAssert kernelAllocations == failAt and smCleanup.active
doAssert smState == 10 and smCleanup.step == {step} and not smCleanup.awaiting
doAssert commands == order[0 ..< {step}] and unlinks == 1
doAssert allocated.len == 0 and smCleanupTags == nil
doAssert notifications.len == 1 and callbackCalls == 1
failAt = 0
drain()
completed()
doAssert notifications.len == 1
'''


def program(case: str, mutation: str | None = None) -> str:
    code = program_source()
    code = code.replace("proc txlResetting(): bool = false",
                        "proc txlResetting(): bool = txResetInProgress")
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
                        "  if failEveryAllocation or kernelAllocations == failAt or "
                        "allocated.len >= allocationLimit: return nil")
    code = code.replace("proc ke_msg_free(h: pointer) =\n",
                        "proc ke_msg_free(h: pointer) =\n  smCleanupForget(h)\n")
    code = code.replace("  let h = cast[ptr Header](calloc(1, (sizeof(Header) + n.int).csize_t))",
                        "  let reused = recycledHeader\n  recycledHeader = nil\n"
                        "  let h = if reused != nil: cast[ptr Header](reused)\n"
                        "          else: cast[ptr Header](calloc(1, (sizeof(Header) + n.int).csize_t))")
    code = code.replace("  free(h)\n", "  if h == recycleOnFree:\n"
                        "    recycleOnFree = nil\n    recycledHeader = h\n"
                        "  else: free(h)\n"
                        "  if freeHook != nil:\n    let action = freeHook\n    freeHook = nil\n    action()\n")
    code = code.replace("  if task == TASK_APM: state = value",
                        "  if task == TASK_SM:\n    smState = value\n"
                        "    if smStateHook != nil: smStateHook()\n"
                        "  elif task == TASK_APM: state = value")
    code = code.replace("  if task == TASK_APM: state elif task == TASK_MM: mmState else: meState",
                        "  if task == TASK_SM: smState elif task == TASK_APM: state elif task == TASK_MM: mmState else: meState")
    code = code.replace("  if address == MACHW_STATE_CNTRL_REG: 0 else: 0x1234",
                        "  if address == MACHW_STATE_CNTRL_REG: fakeMacState else: 0x1234")
    code = code.replace("proc irqSave(): uint32 = 8", "proc irqSave(): uint32 =\n  result = if interruptsEnabled: 8'u32 else: 0'u32\n  interruptsEnabled = false")
    code = code.replace("proc irqRestore(saved: uint32) = doAssert saved == 8",
                        "proc irqRestore(saved: uint32) =\n  interruptsEnabled = (saved and 8) != 0\n"
                        "  if interruptsEnabled and onIrqRestore != nil:\n"
                        "    let action = onIrqRestore\n    onIrqRestore = nil\n    action()")
    code = code.replace("  if h.destId >= TASK_API:\n", "  if h.destId >= TASK_API:\n    captureNotification(p)\n")
    code = code.replace("doAssert task == TASK_APM", "doAssert task in [TASK_APM, TASK_SM]")
    code = code.replace("  timerClears.add(id)\n",
                        "  timerClears.add(id)\n  if timerClearHook != nil: timerClearHook()\n")
    layout = (FW / "layout_types.nim").read_text()
    payload = "type\n  SmConnectIndPayload" + layout.split("  SmConnectIndPayload", 1)[1].split("\n\n  ", 1)[0] + "\n"
    for name in ("MmVifIdentity", "SmDisconnectHandoff"):
        payload += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
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
    delivery = (FW / "rx_host_delivery.nim").read_text()
    code += """
template rxHostIrqSave(): uint32 = irqSave()
template rxHostIrqRestore(saved: uint32) = irqRestore(saved)
"""
    code += delivery[delivery.index("type RxHostStationIndication = object"):]
    for name in ("mmCaptureVif", "mmVifCurrent"):
        code += procedure((FW / "kernel_mac_channel.nim").read_text(), name)
    cleanup = (FW / "station_cleanup.nim").read_text()
    station = (FW / "scan_station_ap_me.nim").read_text()
    code += procedure(station, "smDisconnectHandoffCurrent")
    if mutation:
        before, after = {
            "power_save": ("needed: [true, vif.state != 0,", "needed: [false, vif.state != 0,"),
            "callback": ("    if callback != nil:\n", "    if false:\n"),
            "busy": ("    smCleanup.awaiting = true\n", "    smCleanup.awaiting = true\n    ke_state_set(TASK_SM, SmIdleState)\n"),
            "request_owner": ("if not tag.command or not smCleanupCurrent(tag.serial): return false", "if not tag.command: return false"),
            "reply_owner": ("      reply != smCleanup.reply or header.id != tag.responseId or\n", "      header.id != tag.responseId or\n"),
            "reply_reservation": ("not smCleanup.awaiting or smCleanup.replyReserved or", "not smCleanup.awaiting or"),
            "reply_source": ("header.srcId != tag.responseSource or ", ""),
        }[mutation]
        assert before in cleanup, mutation
        cleanup = cleanup.replace(before, after)
    code += cleanup
    tasks = (FW / "task_handlers.nim").read_text()
    for name in ["smSetActiveCfmStateAllowed", "me_set_active_cfm_handler_sm",
                 "me_set_ps_disable_cfm_handler_sm", "mm_sta_del_req_handler", "sm_delete_resources"]:
        code += procedure(tasks, name)
    for name in ("smDisconnectOwned", "sm_disconnect_process", "smConnectIndLocked", "sm_connect_ind"):
        code += procedure(station, name)
    if case == "established_supplicant_failure":
        code += "\nconst WLAN_FW_4WAY_HANDSHAKE_ERROR_PSK_TIMEOUT_FAILURE = 8\n"
        code += procedure(station, "smRetireEstablishedSupplicantLink")
    runtime = (FW / "task_init_main.nim").read_text()
    code += procedure(runtime, "wifiMainHasPendingWork")
    code += procedure(runtime, "wifiDrainScheduledWork")
    if case == "activation_waits_for_mac_idle_event":
        code += r'''
const KE_EVT_IDLE = 0x04000000'u32
const MM_GOING_TO_IDLE = TaskGoingIdleState
type IdlePhase = enum mmConfigNoIdle, mmConfigAwaitIdle, mmConfigIdleReady
var mmConfigIdle: tuple[phase: IdlePhase]
var idleEventBits: uint32
proc ke_evt_field_get(): uint32 = idleEventBits
proc ke_evt_clear(bits: uint32) = idleEventBits = idleEventBits and not bits
proc mmConfigResumeAbandonedIdle() = discard
'''
        code += procedure((FW / "kernel_mac_channel.nim").read_text(), "mm_hw_idle_evt")
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
    ("reply_reservation", "wrong_reply"),
])
def test_cleanup_guards(tmp_path: Path, mutation: str, case: str) -> None:
    run_native(tmp_path, program(case, mutation), "checked", True)


def test_external_message_release_forgets_cleanup_metadata() -> None:
    sender = procedure((FW / "kernel_mac_channel.nim").read_text(), "ke_msg_send")
    # A message delivered to the host is retired by ke_msg_free, which forgets it.
    assert "ke_msg_free(hdr)" in sender.split("bl_rx_e2a_handler(", 1)[1]
    assert "smCleanupForget(param)" in procedure((FW / "kernel_mac_channel.nim").read_text(), "ke_msg_free")
