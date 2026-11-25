"""Exercise the station cleanup (state 10) over the real ME/MM exchanges.

The harness runs the real station_cleanup.nim, station_sm.nim's request
procs (smSendReserved, smSend, smStaleRequest, smTakeReply, smTakeAnswer),
ME's control exchange, the ME and MM repliers and SM's answer handlers over a
model kernel queue. The cleanup's retry timer is SM's guard (smOwn.guard);
the drain fires it like an expired MM timer.
"""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_ap_start import program_source
from test_wifi_disconnect_tx import FW, ROOT, SM_WAIT, procedure, station_sm_source

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
  smSaQuery: tuple[serial: uint32, armed: bool]
  onIrqRestore: proc()
  recycleOnFree, recycledHeader: pointer
proc smCleanupVifLive(): bool
proc smCleanupCancel()
proc smDeferredCancel() = discard
proc smBssCancel() = discard
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
  removed, deleteNames: seq[uint8]
  listed: array[7, bool]  ## the station is in its VIF's station list
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
proc deleteStation(index: uint8) =
  ## A deletion of station `index` starts: its epoch moves on and a queued
  ## MM_STA_DEL_REQ for it no longer names it (staDeleteCancelQueued).
  inc stationEpochs[index]
  for queue in [addr keMsgQueueSent, addr keMsgQueueSaved]:
    var node = queue.first
    while node != nil:
      if node.id == MM_STA_DEL_REQ and cast[ptr uint8](keMsgPayload(node))[] == index:
        cast[ptr uint8](keMsgPayload(node))[] = 0xFF
      node = node.next
proc ke_msg_try_alloc(id: uint16; dst, src: uint8; n: uint32): pointer =
  result = ke_msg_alloc(id, dst, src, n)
  if allocationHook != nil:
    let action = allocationHook
    allocationHook = nil
    action()
proc mmStaDelReqView(p: pointer): ptr MmStaDelReqPayload = cast[ptr MmStaDelReqPayload](p)
proc retireVif(index: uint8) =
  ## vif_mgmt_unregister: the VIF's epoch moves on and the memset of its entry
  ## empties its station list. Its stations stay valid.
  inc rxVifEpochs[index]
  for station in 0 ..< stations.len:
    if stations[station].instNbr == index: listed[station] = false
proc mm_sta_del(index: uint8) =
  if index >= 7: return
  removed.add(index)
  listed[index] = false
  stations[index].valid = 0
  for vif in vifs.mitems:
    if vif.vifType == VIF_TYPE_STA and vif.staIdx == index: vif.staIdx = 255
proc mmStaDelTry(index: uint8; saved: uint32): bool =
  ## staMgmtBeginRemoval finds a station only in its VIF's station list; a
  ## valid station missing from it cannot be deleted.
  if index >= 7: return true
  if not listed[index]: return stations[index].valid == 0
  mm_sta_del(index)
  true
proc mmStaDelRetryPending(index: uint8): bool = false
proc mmStaDelQueueRetryLocked(index: uint8; saved: uint32) =
  doAssert false, "the station delete was saved for a retry that can never succeed"
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
proc smBssNext(): bool = true
proc stationDisconnected(reason: uint8) {.cdecl.} =
  doAssert reason == 0
  inc callbackCalls
  if disconnectedHook != nil:
    let action = disconnectedHook
    disconnectedHook = nil
    action()
proc driveOne()
proc retryDue(): bool
proc fireRetry()
proc wifiEventPendingWork(): bool = keMsgQueueSent.first != nil
proc wifiKernelTimerPendingWork(): bool = false
proc wifiMmTimerPendingWork(): bool = retryDue()
proc wifiMessagePendingWork(): bool = keMsgQueueSent.first != nil
proc wifiDispatchScheduledEvent(): bool =
  if retryDue():
    fireRetry()
    return true
  result = wifiEventPendingWork()
  if result: driveOne()
'''

DRIVER = r'''
proc cleanupActive(): bool = smOwn.teardown == tdCleanup

proc retryDue(): bool =
  ## The cleanup's retry timer is armed; the model's MAC time has passed it.
  smGuardArmed and smOwn.teardown == tdCleanup

proc fireRetry() =
  smGuardArmed = false
  cast[proc(env: pointer) {.cdecl.}](smOwn.guard.callback)(cast[pointer](smOwn.guard.env.uint))

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
    of MM_SET_VIF_STATE_CFM: discard mm_set_vif_state_cfm_handler(p)
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
      deleteNames.add(cast[ptr uint8](p)[])
      result = mm_sta_del_req_handler(p)
    of MM_SET_VIF_STATE_REQ:
      # mm_hw_config_handler's entry check and its state-0 branch.
      doAssert h.paramLen == 4
      commands.add(h.id)
      if not smStaleRequest(p):
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
  doAssert not cleanupActive() and not smGuardArmed
  doAssert smState == 0 and starts == 0 and interruptsEnabled

proc setup() =
  vifs[0] = VifChannelView(vifIdx: 0, vifType: VIF_TYPE_STA, state: 1,
                         staIdx: 2, chanCtxt: addr cleanupChannel)
  vifs[1] = VifChannelView(vifIdx: 1, vifType: VIF_TYPE_AP, state: 1,
                         staIdx: 6, chanCtxt: cast[pointer](2))
  rxVifEpochs = [1'u32, 1]
  stationEpochs[2] = 7
  stations[2].instNbr = 0
  stations[2].valid = 1
  listed[2] = true
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
  doAssert allocated.len == 0 and smOwn.answer == nil and smOwn.reply == nil
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
# The host's handler of SM_DISCONNECT_IND drives the firmware to the end of
# the cleanup; the cleanup does nothing after sending it.
var finishedInside = false
indicationHook = proc() =
  doAssert smCleanup.step == 0 and smOwn.answer != nil and interruptsEnabled
  for _ in 0 ..< 24:
    if not cleanupActive(): break
    discard wifiDrainScheduledWork()
  doAssert not cleanupActive() and smState == SmIdleState
  doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
  finishedInside = true
sm_disconnect_process(addr vifs[0], 19, 3)
doAssert finishedInside and notifications.len == 1
doAssert rxHostStationIndicationTop == nil and smState == SmIdleState
completed()
''',
    "disconnect_ends_sa_query": r'''
# Every teardown ends SA Query first: the link it probes is going away.
sm.saQueryActive = 1
smSaQuery.armed = true
sm_reconn_dominant_flag = 1
sm_disconnect_process(addr vifs[0], 7, 7)
doAssert timerClears == @[SM_SA_QUERY_TIMEOUT_IND_MSG]
doAssert sm.saQueryActive == 0 and not smSaQuery.armed
doAssert sm_reconn_dominant_flag == 0 and cleanupActive() and smState == 10
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
doAssert smOwn.answer != nil and smCleanup.step == 0
doAssert notifications.len == 1 and callbackCalls == 1
drain()
completed()
doAssert notifications.len == 1
''',
    # A step reached during a TX reset waits for the retry timer.
    "defer_while_tx_resets": r'''
txResetInProgress = true
sm_disconnect_process(addr vifs[0], 19, 3)
doAssert cleanupActive() and smState == SmDisconnectingState and smGuardArmed
doAssert keMsgQueueSent.first == nil and allocated.len == 0
fireRetry()
doAssert smGuardArmed and notifications.len == 0 and callbackCalls == 0
doAssert commands.len == 0 and keMsgQueueSent.first == nil
txResetInProgress = false
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
doAssert not wifiMainHasPendingWork() and callbackCalls == 1
mmPsModeComplete()
drain()
completed()
''',
    "disconnect_pending_station_delete": r'''
vifApConfig(addr vifs[0]).securityFlags = 3
vifApConfig(addr vifs[1]).securityFlags = 7
indicationHook = proc() =
  doAssert smState == 10 and cleanupActive() and smOwn.answer != nil
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
doAssert smState == 10 and cleanupActive() and smOwn.answer == keMsgPayload(held)
doAssert smCleanup.step == 2 and removed == @[2'u8] and unlinks == 1
doAssert notifications.len == 1 and notifications[0].status == 7 and notifications[0].reason == 7
# Nothing else moves the cleanup: it waits for this answer.
doAssert not wifiMainHasPendingWork() and smState == 10
co_list_push_back(addr keMsgQueueSent, held)
drain()
completed()
doAssert notifications.len == 1
''',
    # The VIF is removed and its slot registered again while the host handles
    # SM_DISCONNECT_IND. The cleanup still finishes: the repliers answer its
    # requests for the retired VIF without applying them. The station delete
    # names the old link's station, which the removal left valid but out of
    # any VIF's list, and MM answers it without trying to delete it.
    "vif_retired_mid_cleanup": r'''
indicationHook = proc() =
  doAssert smState == 10 and smCleanup.indication == nil and unlinks == 1
  retireVif(0)
  inc chanCtxtLinkEpochs[0]
  vifs[0].chanCtxt = addr cleanupChannel
  vifApConfig(addr vifs[0]).securityFlags = 9
sm_disconnect_process(addr vifs[0], 7, 7)
doAssert notifications.len == 1 and cleanupActive()
drain()
doAssert commands == @[ME_SET_PS_DISABLE_REQ, MM_SET_VIF_STATE_REQ,
                       MM_STA_DEL_REQ, ME_SET_ACTIVE_REQ]
doAssert smState == 0 and unlinks == 1 and deleteNames == @[2'u8]
doAssert removed.len == 0 and stations[2].valid == 1
doAssert vifs[0].state == 1 and me.activeMask == 3 and me.psDisableMask == 3,
  "a request was applied to the retired VIF"
doAssert vifs[0].chanCtxt == addr cleanupChannel
doAssert vifApConfig(addr vifs[0]).securityFlags == 9
doAssert notifications.len == 1 and allocated.len == 0
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
doAssert allocated.len == 0
''',
    # Only the answer SM waits on moves the cleanup: a copy at another
    # address, or the same answer delivered twice, changes nothing.
    "wrong_reply": r'''
sm_delete_resources(addr vifs[0])
while keMsgQueueSent.first.destId != TASK_SM: driveOne()
let h = co_list_pop_front(addr keMsgQueueSent)
let p = keMsgPayload(h)
doAssert smOwn.answer == p and h.id == ME_SET_PS_DISABLE_CFM
let copy = newMessage(ME_SET_PS_DISABLE_CFM, TASK_SM, TASK_ME, 0)
me_set_ps_disable_cfm_handler_sm(copy)
me_set_active_cfm_handler_sm(copy)
discard mm_set_vif_state_cfm_handler(copy)
discard smCleanupCfmHandler(copy)
doAssert smCleanup.step == 0 and smOwn.answer == p and keMsgQueueSent.first == nil
ke_msg_free(keMsgHdrFromPayload(copy))
me_set_ps_disable_cfm_handler_sm(p)
let nextStep = smCleanup.step
doAssert nextStep == 1 and smOwn.answer != p
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
doAssert smState == SmIdleState and not cleanupActive()
doAssert keMsgQueueSent.first == keMsgHdrFromPayload(next)
drain()
doAssert me.activeMask == 2 and allocated.len == 0
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
doAssert keMsgQueueSaved.first == idleRequest and smOwn.answer != nil and smCleanup.step == 3

let next = newMessage(ME_SET_ACTIVE_REQ, TASK_ME, TASK_API, 2)
cast[ptr array[2, uint8]](next)[] = [1'u8, 1]
ke_msg_send(next)
driveOne()
doAssert keMsgQueueSaved.last == keMsgHdrFromPayload(next)
ke_msg_send(newMessage(MM_SET_IDLE_CFM, TASK_ME, TASK_MM, 0))
driveOne()
doAssert meState == MeBusyState and mmState == TaskGoingIdleState
doAssert smState == SmDisconnectingState and smOwn.answer != nil
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
doAssert smState == SmIdleState and not cleanupActive()
doAssert keMsgQueueSent.first == keMsgHdrFromPayload(next)
drain()
doAssert me.activeMask == 2 and allocated.len == 0
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
    # sm_init with the cleanup's request queued: the replier drops it.
    "queued_cancel": r'''
sm_delete_resources(addr vifs[0])
let held = co_list_pop_front(addr keMsgQueueSent)
smCleanupCancel()
smGo(SmIdleState)
doAssert allocated.len == 1, "the reserved reply outlived the operation"
doAssert me_set_ps_disable_req_handler(keMsgPayload(held)) == KeMsgConsumed
ke_msg_free(held)
doAssert me.psDisableMask == 3 and me.activeMask == 3
doAssert allocated.len == 0 and keMsgQueueSent.first == nil
''',
    # The VIF is retired while ME forwards the first request to MM. The
    # forward completes; the rest is answered unapplied and the cleanup ends.
    "retired_vif_finishes_cleanup": r'''
psDeferred = true
sm_disconnect_process(addr vifs[0], 7, 7)
driveOne()
driveOne()
doAssert smOwn.answer != nil and smState == SmDisconnectingState
doAssert mmPsModeRequest != nil and meState == MeBusyState
let reconnect = newMessage(0x1000, TASK_SM, TASK_API, 32)
co_list_push_back(addr keMsgQueueSaved, keMsgHdrFromPayload(reconnect))
# The quiesced invalidation is the epoch boundary used by VIF unregister,
# whose memset of the entry empties its station list.
rxInvalidateQuiescentVif(0, 0)
vifs[0].vifType = 4
listed[2] = false
mmPsModeComplete()
var steps = 0
while keMsgQueueSent.first != nil and keMsgQueueSent.first != keMsgHdrFromPayload(reconnect):
  inc steps
  doAssert steps < 40
  driveOne()
doAssert smState == SmIdleState and not cleanupActive() and interruptsEnabled
doAssert mmPsModeRequest == nil and meState == MeIdleState
doAssert keMsgQueueSaved.first == nil and keMsgQueueSent.first == keMsgHdrFromPayload(reconnect)
doAssert notifications.len == 1 and callbackCalls == 1 and removed.len == 0
doAssert deleteNames == @[2'u8] and stations[2].valid == 1
doAssert vifs[0].state == 1 and me.activeMask == 3 and me.psDisableMask == 2
ke_msg_free(co_list_pop_front(addr keMsgQueueSent))
doAssert allocated.len == 0
''',
    # The replier frees the request once it has taken SM's reply, and SM no
    # longer holds it: a host request at the same address gets its own reply.
    "retired_request_address_reused": r'''
me.psOn = 0
sm_delete_resources(addr vifs[0])
let retiredRequest = smOwn.request
recycleOnFree = keMsgHdrFromPayload(retiredRequest)
driveOne()
doAssert keMsgQueueSent.first.id == ME_SET_PS_DISABLE_CFM
doAssert smOwn.request == nil and smOwn.reply == nil and smOwn.answer != nil

let replacement = newMessage(ME_SET_ACTIVE_REQ, TASK_ME, TASK_API, 2)
doAssert replacement == retiredRequest and recycledHeader == nil
doAssert not smAwaits(replacement), "a message at a freed request's address was taken for SM's"
cast[ptr array[2, uint8]](replacement)[] = [0'u8, 0]
ke_msg_send(replacement)
drain()
doAssert allocated.len == 0 and meState == MeIdleState and me.activeMask == 2
var hostReplies = 0
for reply in controlReplies:
  if reply.id == ME_SET_ACTIVE_CFM and reply.dst == TASK_API: inc hostReplies
doAssert hostReplies == 1
''',
    # A late answer from an operation sm_init ended does not move the next
    # teardown's cleanup.
    "late_reply": r'''
sm_delete_resources(addr vifs[0])
while keMsgQueueSent.first.destId != TASK_SM: driveOne()
let held = co_list_pop_front(addr keMsgQueueSent)
smCleanupCancel()
smGo(SmIdleState)
inc rxVifEpochs[0]
doAssert smCleanupBegin(addr vifs[0])
let fresh = smOwn.answer
me_set_ps_disable_cfm_handler_sm(keMsgPayload(held))
doAssert smCleanup.step == 0 and smOwn.answer == fresh
ke_msg_free(held)
drain()
doAssert allocated.len == 0 and me.activeMask == 2 and starts == 0
''',
    # sm_init while ME forwards the cleanup's request: ME and MM finish it
    # and SM ignores the answer. This models sm_init alone; on MM_RESET_REQ
    # me_init resets ME's exchange (meControlReset) just before it.
    "cancel_ps_pending": r'''
psDeferred = true
sm_delete_resources(addr vifs[0])
driveOne()
driveOne()
doAssert meState == MeBusyState and mmPsModeRequest != nil
smCleanupCancel()
smGo(SmIdleState)
mmPsModeComplete()
while keMsgQueueSent.first != nil: driveOne()
doAssert meState == MeIdleState and mmPsModeRequest == nil and me.psDisableMask == 2
doAssert smState == SmIdleState and commands == @[ME_SET_PS_DISABLE_REQ]
doAssert allocated.len == 0
''',
    # The supplicant's callback runs sm_init: the cleanup sends nothing more.
    "callback_runs_sm_init": r'''
disconnectedHook = proc() =
  smCleanupCancel()
  smGo(SmIdleState)
sm_disconnect_process(addr vifs[0], 7, 7)
doAssert callbackCalls == 1 and commands.len == 0 and keMsgQueueSent.first == nil
doAssert smState == SmIdleState and not cleanupActive() and not smGuardArmed
doAssert notifications.len == 0 and allocated.len == 0
''',
    "nested_cleanup": r'''
disconnectedHook = proc() =
  doAssert not smTeardown(addr vifs[0])
  doAssert smCleanup.step == 0 and cleanupActive()
sm_delete_resources(addr vifs[0])
drain()
completed()
''',
    # The station is deleted (and may be added again) while the cleanup's
    # delete is queued: the queued request no longer names it.
    "station_reuse": r'''
sm_delete_resources(addr vifs[0])
while keMsgQueueSent.first.id != MM_STA_DEL_REQ: driveOne()
deleteStation(2)
drain()
doAssert removed.len == 0 and vifs[0].staIdx == 2
doAssert me.activeMask == 2 and allocated.len == 0
''',
    # The station is deleted (and its index taken again) before the cleanup
    # reaches its delete: the delete it sends names no station.
    "station_deleted_before_its_step": r'''
sm_delete_resources(addr vifs[0])
doAssert smCleanup.step == 0 and keMsgQueueSent.first.id == ME_SET_PS_DISABLE_REQ
deleteStation(2)
drain()
doAssert deleteNames == @[0xFF'u8] and removed.len == 0
doAssert stations[2].valid == 1 and listed[2]
doAssert me.activeMask == 2 and allocated.len == 0
''',
    # The VIF is removed before the first step runs (the cleanup began during
    # a TX reset). The supplicant is not told, the channel and the security
    # flags are left alone, every request is answered unapplied, and the
    # cleanup still finishes and sends its indication.
    "vif_retired_before_first_step": r'''
txResetInProgress = true
vifApConfig(addr vifs[0]).securityFlags = 9
sm_disconnect_process(addr vifs[0], 19, 3)
doAssert cleanupActive() and smGuardArmed and commands.len == 0
retireVif(0)
txResetInProgress = false
drain()
doAssert callbackCalls == 0, "the supplicant of a removed VIF was told"
doAssert unlinks == 0 and vifs[0].chanCtxt == addr cleanupChannel
doAssert vifApConfig(addr vifs[0]).securityFlags == 9
doAssert commands == @[ME_SET_PS_DISABLE_REQ, MM_SET_VIF_STATE_REQ,
                       MM_STA_DEL_REQ, ME_SET_ACTIVE_REQ]
doAssert removed.len == 0 and vifs[0].state == 1
doAssert me.activeMask == 3 and me.psDisableMask == 3
doAssert notifications.len == 1 and notifications[0].status == 19 and allocated.len == 0
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
    # No memory at all: the supplicant is told once, nothing is sent, and the
    # retry timer runs the step again until memory returns.
    "persistent_pressure": r'''
failEveryAllocation = true
sm_delete_resources(addr vifs[0])
for attempt in 0 ..< 3:
  doAssert wifiMainHasPendingWork() and smGuardArmed
  discard wifiDrainScheduledWork()
doAssert smState == 10 and callbackCalls == 1 and commands.len == 0
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
    "failure_removes_scan_result_before_claim": r'''
# The failed attempt's scan result is dropped while SM still holds the
# attempt; the cleanup then claims it. The removal only frees a cached frame.
sm.connectIndMsg = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
sm.scanResultIndex = 0
let attempt = sm.connectInfo
scanRemoveHook = proc() =
  doAssert sm.connectInfo == attempt and not cleanupActive() and smState == SmSettingBssState
smState = SmSettingBssState
sm_connect_ind(8, 15)
doAssert sm.scanResultIndex == 0xFFFFFFFF'u32 and sm.connectInfo == nil
doAssert cleanupActive() and smState == SmDisconnectingState
drain()
completed()
doAssert controlReplies.len == 1 and controlReplies[0].id == SM_CONNECT_IND_MSG
''',
    "failure_publishes_state_after_claim": r'''
# State 10 becomes visible only once the cleanup owns the attempt.
smState = SmSettingBssState
sm.connectIndMsg = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
var observed = false
smStateHook = proc() =
  smStateHook = nil
  doAssert smState == SmDisconnectingState
  doAssert cleanupActive() and sm.connectInfo == nil and sm.connectIndMsg == nil,
    "state 10 published before the cleanup claimed the attempt"
  observed = true
sm_connect_ind(8, 15)
doAssert observed
sm_connect_ind(9, 15)
doAssert cleanupActive(), "a second end of the attempt restarted the teardown"
drain()
completed()
doAssert controlReplies.len == 1
''',
    "reply_callback_replacement": r'''
sm.connectIndMsg = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
indicationHook = proc() =
  doAssert smState == 0 and not cleanupActive()
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

# The first step allocates SM_DISCONNECT_IND (1), its request (2) and the
# request's reply (3). Without one of them nothing is sent; the indication
# allocated already is kept for the retry.
for allocation in range(1, 4):
    CASES[f"allocation_{allocation}"] = f'''
failAt = kernelAllocations + {allocation}
sm_disconnect_process(addr vifs[0], 19, 3)
doAssert smState == 10 and callbackCalls == 1 and commands.len == 0
doAssert vifs[0].state == 1 and me.activeMask == 3 and me.psDisableMask == 3
doAssert allocated.len == {0 if allocation == 1 else 1} and smGuardArmed and smOwn.answer == nil
failAt = 0
drain()
completed()
doAssert notifications.len == 1
'''

# Later steps: the request (4, 6, 7) or its reply (5, 8) of step 1, 2 or 3.
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
doAssert kernelAllocations == failAt and cleanupActive()
doAssert smState == 10 and smCleanup.step == {step} and smOwn.answer == nil and smGuardArmed
doAssert commands == order[0 ..< {step}] and unlinks == 1
doAssert allocated.len == 0
doAssert notifications.len == 1 and callbackCalls == 1
failAt = 0
drain()
completed()
doAssert notifications.len == 1
'''


SM_PROCS = ("smGo", "smSend", "smSendReserved", "smAwaits", "smAttemptStaVif",
            "smRequestVifLive", "smStaleRequest", "smTakeReply", "smTakeAnswer",
            "smDeauthConfirmed", "smDeauthVif", "smTeardownUnclaimed", "smTeardown")

# The guard each mutation removes, and the case that must then fail.
MUTATIONS = {
    "power_save": ("needed: [true, vif.state != 0,", "needed: [false, vif.state != 0,", "disconnect"),
    "callback": ("    if callback != nil:\n", "    if false:\n", "disconnect"),
    "late_answer": ("  if answer == nil or answer != smOwn.answer: return false",
                    "  if answer == nil: return false", "late_reply"),
    "dropped_request": ("  if not smAwaits(request): return true", "  if not smAwaits(request): return false",
                        "queued_cancel"),
    "retired_vif": ("  if smOwn.teardown == tdCleanup: return smCleanupVifLive()",
                    "  if smOwn.teardown == tdCleanup: return true", "vif_retired_mid_cleanup"),
    "binding": ("if chanCtxtLinkEpochs[vif] == smCleanup.channelBinding and entry.chanCtxt != nil:",
                "if entry.chanCtxt != nil:", "channel_rebound_before_detach"),
    "reset_retry": ("  if txlResetting():\n    smCleanupRetry()\n    return\n", "", "defer_while_tx_resets"),
    "callback_end": ("      if smOwn.teardown != tdCleanup: return  # The host ran sm_init.\n", "",
                     "callback_runs_sm_init"),
    "station_named": ("      if smCleanupOwnsStation(smCleanup.station, vif, smCleanup.stationEpoch): smCleanup.station\n"
                      "      else: 0xFF'u8\n", "      smCleanup.station\n", "station_deleted_before_its_step"),
    "retired_callback": ("if wpa_cbs == nil or not smCleanupVifLive(): nil", "if wpa_cbs == nil: nil",
                         "vif_retired_before_first_step"),
    "retired_effects": ("  if smCleanupVifLive():\n    # The VIF leaves", "  if true:\n    # The VIF leaves",
                        "vif_retired_before_first_step"),
    "retired_delete": ("    if not smRequestVifLive(): mmStaDelReqView(param).staIdx = 0xFF\n", "",
                       "vif_retired_mid_cleanup"),
    "reply_hand_out": ("  smOwn.reply = nil\n  smOwn.request = nil\n  let header = keMsgHdrFromPayload(result)",
                       "  smOwn.reply = nil\n  let header = keMsgHdrFromPayload(result)",
                       "retired_request_address_reused"),
}


def program(case: str, mutation: str | None = None) -> str:
    code = program_source()
    code = code.replace("proc txlResetting(): bool = false",
                        "proc txlResetting(): bool = txResetInProgress")
    code = code.replace(procedure(code, "chan_ctxt_unlink"), "")
    code = code.replace("    contextIndexOrMarker, invalidMarker: uint8",
                        "    contextIndexOrMarker, invalidMarker: uint8\n    channel: ChanCtxtDefView")
    # The real station_sm.nim request procs replace the AP fixture's stubs.
    for stub, declaration in [
        ("proc smStaleRequest(request: pointer): bool = false\n", "proc smStaleRequest(request: pointer): bool\n"),
        ("proc smAwaits(request: pointer): bool = false\n", "proc smAwaits(request: pointer): bool\n"),
        ("proc smTakeReply(request: pointer; id: uint16): pointer = nil\n",
         "proc smTakeReply(request: pointer; id: uint16): pointer\n"),
    ]:
        assert stub in code
        code = code.replace(stub, declaration)
    code = code.replace("    vifIdx, vifType, state, beaconEnabled: uint8",
                        "    vifIdx, vifType, state, beaconEnabled, staIdx, wmmAcFlags: uint8")
    code = code.replace("    beaconRegister, apStopped: pointer",
                        "    beaconRegister, apStopped, stationDisconnected: pointer")
    code = code.replace("  if kernelAllocations == failAt: return nil",
                        "  if failEveryAllocation or kernelAllocations == failAt or "
                        "allocated.len >= allocationLimit: return nil")
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
    for name in ("MmVifIdentity",):
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
    station = (FW / "scan_station_ap_me.nim").read_text()
    code += ("proc smCleanupBegin(vifEntry: pointer; indication: pointer = nil;\n"
             "                    disconnected = false; status = 0'u16; reason = 0'u16): bool\n")
    code += procedure((FW / "station_sa_query.nim").read_text(), "smSaQueryEnd")
    code += station_sm_source(*SM_PROCS) + SM_WAIT
    code += (FW / "station_cleanup.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    for name in ["me_set_active_cfm_handler_sm", "me_set_ps_disable_cfm_handler_sm",
                 "mm_set_vif_state_cfm_handler", "mm_sta_del_req_handler", "sm_delete_resources"]:
        code += procedure(tasks, name)
    for name in ("sm_disconnect_process", "smConnectEnd", "sm_connect_ind"):
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
    if mutation:
        before, after, _ = MUTATIONS[mutation]
        assert code.count(before) == 1, mutation
        code = code.replace(before, after)
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


@pytest.mark.parametrize("mutation", MUTATIONS)
def test_cleanup_guards(tmp_path: Path, mutation: str) -> None:
    run_native(tmp_path, program(MUTATIONS[mutation][2], mutation), "checked", True)


def test_cleanup_is_not_polled_or_forgotten() -> None:
    """The cleanup sends through station_sm.nim and is moved only by its
    answers and its retry timer: the main loop does not poll it, ke_msg_free
    and ke_msg_alloc_reply do not track its messages, and no MM or ME handler
    checks them except through smStaleRequest and smAwaits."""
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    sender = procedure(kernel, "ke_msg_send")
    # A message delivered to the host is retired by ke_msg_free.
    assert "ke_msg_free(hdr)" in sender.split("bl_rx_e2a_handler(", 1)[1]
    for name in ("ke_msg_free", "ke_msg_alloc_reply"):
        assert "smCleanup" not in procedure(kernel, name), name
    main = (FW / "task_init_main.nim").read_text()
    assert "smCleanup" not in main
    tasks = (FW / "task_handlers.nim").read_text()
    assert "smCleanupAdmitRequest" not in tasks and "smCleanupConsumeReply" not in tasks
    cleanup = (FW / "station_cleanup.nim").read_text()
    assert "smSendReserved(request)" in cleanup and "smSend(request)" in cleanup
    assert "ke_msg_send(" not in cleanup and "meControlReset" not in cleanup
