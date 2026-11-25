# SM's cleanup of an ended attempt or link (state 10, after any
# deauthentication wait).
#
# smTeardown calls smCleanupBegin, which claims the link: it takes the
# attempt's messages out of sm_env and frees them, keeping the indication to
# send, enters state 10 and sends the first of the requests of pinned
# sm_delete_resources. As in the BSS batch they go out one at a time, and
# each answer sends the next (smCleanupNext):
#
#   0  ME_SET_PS_DISABLE_REQ(0)
#   1  MM_SET_VIF_STATE_REQ(0)   when the VIF is active
#   2  MM_STA_DEL_REQ            when the VIF has its AP station
#   3  ME_SET_ACTIVE_REQ(0)
#
# Each goes out with smSendReserved, and MM_STA_DEL_REQ, which MM answers in
# place, with smSend, so every answer arrives (station_sm.nim). If the VIF
# is removed meanwhile, vif_mgmt_unregister ends the cleanup at once
# (smStaVifRetired), so every request it sends names a VIF that is there.
# The supplicant is told before the first request; after it, the VIF leaves
# its channel, loses its security flags and a disconnect's SM_DISCONNECT_IND
# is sent. After the last answer SM goes idle and a failed attempt's
# SM_CONNECT_IND is sent.
#
# A step whose messages cannot be allocated, or that comes during a TX
# reset, runs again 10 ms later from SM's state-10 timer (smCleanupRetry).
# No step is skipped.

type
  SmCleanupOperation = object
    session: RxHostSession  ## the VIF released, and its indication's host session
    stationEpoch, channelBinding: uint32
    vif, station: uint8
    step: int               ## the request in flight or the next to send
    needed: array[4, bool]
    notified: bool          ## the supplicant has been told
    disconnect: bool        ## SM_DISCONNECT_IND follows the first request
    status, reason: uint16  ## SM_DISCONNECT_IND's
    indication: pointer     ## the attempt's SM_CONNECT_IND, or SM_DISCONNECT_IND

var smCleanup {.wifiCtrl.}: SmCleanupOperation

const
  SmCleanupRequests = [ME_SET_PS_DISABLE_REQ, MM_SET_VIF_STATE_REQ,
                       MM_STA_DEL_REQ, ME_SET_ACTIVE_REQ]
  SmCleanupTasks = [TASK_ME, TASK_MM, TASK_MM, TASK_ME]
  SmCleanupLengths = [MeSetPsDisableReqPayloadSize, MmSetVifStateReqPayloadSize,
                      MmStaDelReqPayloadSize, MeSetActiveReqPayloadSize]
  SmCleanupRetryUs = 10_000'u32

proc smCleanupOwnsStation(station, vif: uint8; epoch: uint32): bool =
  staDeleteIsCurrent(station, epoch) and staInfoForIdx(station).instNbr == vif

proc smCleanupCancel() =
  ## smAbandon: forget the cleanup and free the indication it holds.
  let indication = smCleanup.indication
  smCleanup = default(SmCleanupOperation)
  if indication != nil: ke_msg_free(keMsgHdrFromPayload(indication))

proc smCleanupNext()

proc smCleanupRetryExpired(env: pointer) {.cdecl.} =
  if smOwn.teardown == tdCleanup and opCurrent(smOwn.op, opEnvStamp(env)):
    smCleanupNext()

proc smCleanupRetry() =
  ## Run the step again in 10 ms.
  smOwn.guard.callback = cast[pointer](smCleanupRetryExpired)
  smOwn.guard.env = smOwn.op.serial
  mm_timer_set(addr smOwn.guard, macTimeNow() + SmCleanupRetryUs)

proc smCleanupNext() =
  ## Send the next request the link needs, or finish: SM goes idle and the
  ## indication is sent.
  while smCleanup.step < SmCleanupRequests.len and not smCleanup.needed[smCleanup.step]:
    inc smCleanup.step
  let index = smCleanup.step
  if index == SmCleanupRequests.len:
    let indication = smCleanup.indication
    let session = smCleanup.session
    smCleanup = default(SmCleanupOperation)
    smGo(SmIdleState)
    if indication != nil: rxHostSendStationIndication(indication, session)
    return
  if txlResetting():
    smCleanupRetry()
    return
  if not smCleanup.notified:
    smCleanup.notified = true
    let callback = if wpa_cbs == nil: nil else: wpaCallbacks().stationDisconnected
    if callback != nil:
      cast[proc(reason: uint8) {.cdecl.}](callback)(0)
      if smOwn.teardown != tdCleanup: return  # The host ran sm_init.
  if smCleanup.disconnect and smCleanup.indication == nil:
    let message = ke_msg_try_alloc(SM_DISCONNECT_IND, TASK_API, TASK_SM,
                                   SmDisconnectProcessIndPayloadSize)
    if message == nil:
      smCleanupRetry()
      return
    let indication = cast[ptr SmDisconnectProcessIndPayload](message)
    indication.status = smCleanup.status
    indication.reason = smCleanup.reason
    indication.vifIdx = smCleanup.vif
    smCleanup.indication = message
  let request = ke_msg_try_alloc(SmCleanupRequests[index], SmCleanupTasks[index],
                                 TASK_SM, SmCleanupLengths[index])
  if request == nil:
    smCleanupRetry()
    return
  let vif = smCleanup.vif
  case index
  of 0:
    cast[ptr MeSetPsDisableReqPayload](request)[] =
      MeSetPsDisableReqPayload(disable: 0, vifIdx: vif)
  of 1:
    cast[ptr MmSetVifStateReqPayload](request)[] =
      MmSetVifStateReqPayload(aid: 0, state: 0, vifIdx: vif)
  of 2:
    cast[ptr MmStaDelReqPayload](request).staIdx =
      if smCleanupOwnsStation(smCleanup.station, vif, smCleanup.stationEpoch): smCleanup.station
      else: 0xFF'u8
  else:
    nimFwWpaPendingMask = nimFwWpaPendingMask and not (1'u32 shl vif)
    cast[ptr MeSetActiveReqPayload](request)[] =
      MeSetActiveReqPayload(active: 0, vifIdx: vif)
  if index == 2:
    smSend(request)
  elif not smSendReserved(request):
    smCleanupRetry()
    return
  if index != 0: return
  # The VIF leaves its channel and drops its flags before the host hears of it.
  let entry = vifChannelForIdx(vif)
  if chanCtxtLinkEpochs[vif] == smCleanup.channelBinding and entry.chanCtxt != nil:
    chan_ctxt_unlink(vif)
  vifApConfig(entry).securityFlags = 0
  if smCleanup.disconnect:
    let indication = smCleanup.indication
    smCleanup.indication = nil
    smCleanup.disconnect = false
    rxHostSendStationIndication(indication, smCleanup.session)

proc smCleanupConfirmed() =
  ## SM took the answer to the cleanup's request in flight: send the next.
  inc smCleanup.step
  smCleanupNext()

proc smCleanupCfmHandler(reply: pointer): cint {.cdecl.} =
  ## MM_STA_DEL_CFM: MM's answer, in place, to the cleanup's station delete.
  if smTakeAnswer(reply): smCleanupConfirmed()
  KeMsgConsumed

proc smCleanupBegin(vifEntry: pointer; indication: pointer = nil;
                    disconnected = false; status = 0'u16; reason = 0'u16): bool =
  ## smTeardown's cleanup phase: claim the link on `vifEntry` (nil: the
  ## attempt's VIF, or a STA VIF that still holds a station, a channel or an
  ## active state), enter state 10 and send the first request. False when no
  ## STA VIF is left to clean up.
  let sm = smEnvView()
  var vif: ptr VifChannelView
  for index in 0'u8 ..< MAX_VIFS.uint8:
    let candidate = vifChannelForIdx(index)
    if candidate.vifType != VIF_TYPE_STA or candidate.vifIdx != index: continue
    if (vifEntry != nil and vifEntry == candidate) or
        (vifEntry == nil and sm.connectInfo != nil and
         connectInfoView(sm.connectInfo).vifIdx == index) or
        (vifEntry == nil and sm.connectInfo == nil and
         (candidate.state != 0 or candidate.staIdx != 0xFF or candidate.chanCtxt != nil)):
      vif = candidate
      break
  if vif == nil: return false
  if disconnected:
    sm_reconn_dominant_flag = 0
  let stationEpoch = staDeleteEpoch(vif.staIdx)
  if not smCleanupOwnsStation(vif.staIdx, vif.vifIdx, stationEpoch):
    vif.staIdx = 0xFF
  inc nimFwDbgDisconnectInd
  let connection = sm.connectInfo
  let discarded = if sm.connectIndMsg == indication: nil else: sm.connectIndMsg
  smCleanup = SmCleanupOperation(vif: vif.vifIdx, station: vif.staIdx,
    session: captureRxHostSession(vif.vifIdx, 0xFF),
    stationEpoch: stationEpoch, channelBinding: chanCtxtLinkEpochs[vif.vifIdx],
    needed: [true, vif.state != 0, vif.staIdx != 0xFF, true],
    indication: indication, disconnect: disconnected, status: status, reason: reason)
  sm.connectInfo = nil
  sm.connectIndMsg = nil
  sm.cancelRequested = 0
  sm.joinBssFlag = 0
  sm.deauthPending = 0
  sm.scanResultIndex = 0xFFFFFFFF'u32
  smConnecting = false
  smGo(SmDisconnectingState, tdCleanup)
  smOwn.vif = vif.vifIdx
  smActivationCancel()
  smBssCancel()
  if connection != nil: ke_msg_free(keMsgHdrFromPayload(connection))
  if discarded != nil: ke_msg_free(keMsgHdrFromPayload(discarded))
  smCleanupNext()
  true
