# SM's activation of the association (state 9).
#
# smAssocDone starts it (smActivationStart): SM enters state 9 and sends,
# one at a time, MM_SET_VIF_STATE_REQ (the VIF goes active with its AID),
# MM_SET_PS_OPTIONS_REQ and, when the control port opens at once,
# ME_SET_PS_DISABLE_REQ. Each goes out with smSendReserved, so its answer
# needs no allocation and always arrives (station_sm.nim), and each answer
# sends the next request (smActivationConfirmed). Pinned
# mm_set_vif_state_cfm_handler sends the last two without waiting for them.
# After the last answer SM tells the host the AP station is ready
# (SM_STA_ADD_IND) and reports the connection, or, on a protected network,
# waits in state 9 for the supplicant. The removal of the STA VIF ends that
# wait too (smStaVifRetired): the removal deinitialises the supplicant.
#
# The activation belongs to the state-9 operation that started it and is
# live while that operation is (smActivationLive). Every end of the attempt
# leaves state 9; its teardown withdraws a TX peer published to the host
# (smActivationCancel).
#
# A WPA2-PSK station's TX peer is published at the VIF confirmation, before
# the PS requests, so that the host can answer the AP's first EAPOL message.
# An M1 that arrives before the peer is published is kept
# (smActivationRetainM1) and replayed once it is.

const
  SmM1FixedLength = 99  # 4-byte EAPOL header and 95-byte key descriptor.
  SmM1PmkidHeader = [0xdd'u8, 20, 0, 0x0f, 0xac, 4]
  SmM1PmkidLength = SmM1PmkidHeader.len + 16

type
  SmFirstM1 = object
    length: uint8
    source: array[6, uint8]
    bytes: array[SmM1FixedLength + SmM1PmkidLength, uint8]
  SmPeerPublication = object
    payload: pointer
    linked: bool
  SmPeerLease = object
    host: pointer
    token: uint32
    check: proc(host: pointer; station: uint8; token: uint32; retire: bool): bool {.nimcall.}
  SmActivationOperation = object
    stamp: uint32  ## the state-9 operation the activation belongs to
    vif, station: uint8
    stationEpoch: uint32
    aid: uint16
    step: int      ## the request in flight; SmActivationRequests.len when done
    firstM1: SmFirstM1
    peerLease: SmPeerLease
    initialKeyRevision: uint64
    pskPeer, peerPublished, skipPsDisable, supplicantReady: bool

const
  SmActivationRequests = [MM_SET_VIF_STATE_REQ, MM_SET_PS_OPTIONS_REQ,
                           ME_SET_PS_DISABLE_REQ]
  SmActivationTasks = [TASK_MM, TASK_MM, TASK_ME]
  SmActivationLengths = [MmSetVifStateReqPayloadSize, MmSetPsOptionsReqPayloadSize,
                          MeSetPsDisableReqPayloadSize]

var
  smActivation {.wifiCtrl.}: SmActivationOperation
  smPublishingPeer {.wifiCtrl.}: ptr SmPeerPublication

proc smActivationLive(): bool =
  ## The activation belongs to SM's live operation.
  opCurrent(smOwn.op, smActivation.stamp)

proc smActivationOrdinaryPsk(vifIdx: uint8): bool =
  let security = vifSecurity(vifChannelForIdx(vifIdx))
  let connection = connectInfoView(smEnvView().connectInfo)
  security.connected != 0 and security.cipher in [2'u8, 3] and
    security.keyMgmt in [WifiKeyMgmtPsk, WifiKeyMgmtPskSha256] and
    smEnvView().state != 2 and connection.authType == 0 and
    connection.ctrlPortEthertype == 0x8E88'u16

proc smActivationAcceptPeer*(payload: pointer; vif, station: uint8;
                             linked = false): bool =
  # External KE messages are dispatched synchronously, with the same payload.
  # Only the exact station-add currently being sent can acknowledge link-up.
  let publication = smPublishingPeer
  if publication == nil or publication.payload != payload: return true
  if not smActivationLive() or smActivation.vif != vif or
      smActivation.station != station: return false
  if linked: publication.linked = true
  true

proc smActivationTrackPeer*(payload, host: pointer; token: uint32;
    check: proc(host: pointer; station: uint8; token: uint32; retire: bool): bool {.nimcall.}) =
  let publication = smPublishingPeer
  if publication != nil and publication.payload == payload and smActivationLive():
    smActivation.peerLease = SmPeerLease(host: host, token: token, check: check)

proc smActivationHostPeer(op: SmActivationOperation; retire = false): bool {.inline.} =
  let lease = op.peerLease
  lease.check != nil and lease.check(lease.host, op.station, lease.token, retire)

proc smActivationEapolReady(vif, station: uint8): bool =
  if not smActivation.pskPeer or smActivation.vif != vif or
      smActivation.station != station: return true
  smActivation.peerPublished and smActivationHostPeer(smActivation) and smActivationLive()

proc smActivationRetainM1(vif, station: uint8; source: array[6, uint8];
                          data: pointer; length: uint32): bool =
  # RXU has validated the EAPOL body length and plaintext FromDS addressing.
  # Both supported forms fit entirely in the first RX buffer.
  if not smActivation.pskPeer or smActivation.peerPublished or
      smActivation.station != station or smActivation.vif != vif or
      not smActivationLive() or not smActivationOrdinaryPsk(vif) or
      rxKeyLastChanged[station] != smActivation.initialKeyRevision or
      staInfoForIdx(station).keyHolder != nil or staInfoForIdx(station).macAddr != source or
      data == nil or length notin [SmM1FixedLength.uint32,
                                  (SmM1FixedLength + SmM1PmkidLength).uint32]: return false
  let key = cast[ptr UncheckedArray[uint8]](data)
  # Key Info: pairwise and ACK only, with descriptor version 1, 2 or 3.
  if key[0] notin [1'u8, 2, 3] or key[1] != 3 or key[4] notin [2'u8, 254] or
      key[5] != 0 or key[6] notin [0x89'u8, 0x8a, 0x8b] or
      key[97] != 0 or key[98].uint32 != length - SmM1FixedLength: return false
  if length != SmM1FixedLength and (key[4] != 2 or not equalMem(
      addr key[SmM1FixedLength], unsafeAddr SmM1PmkidHeader[0], SmM1PmkidHeader.len)): return false
  if smActivation.firstM1.length != 0:
    return smActivation.firstM1.length.uint32 == length and
      equalMem(addr smActivation.firstM1.bytes[0], data, length.int)
  smActivation.firstM1.source = source
  copyMem(addr smActivation.firstM1.bytes[0], data, length.int)
  smActivation.firstM1.length = length.uint8
  true

proc smActivationCancel() =
  ## The attempt ended before its activation finished: withdraw a TX peer
  ## already published to the host.
  let retired = smActivation
  smActivation = default(SmActivationOperation)
  if retired.peerLease.check != nil:
    if staDeleteIsCurrent(retired.station, retired.stationEpoch):
      staInfoForIdx(retired.station).controlPortState = 0
    discard smActivationHostPeer(retired, retire = true)

proc smActivationFail() =
  when defined(bl808WifiDiagWarmScan): nimFwDbgWarmAssocFailure = warmAssocActivation
  sm_connect_ind(WLAN_FW_ASSOCIATE_FAIILURE.uint16, 0xFFFF)

proc smStaAddInd(vifIdx: uint8): pointer =
  ## SM_STA_ADD_IND, which tells the host that the AP station of VIF `vifIdx`
  ## is ready, or nil without memory. The host handles it inside ke_msg_send.
  result = ke_msg_try_alloc(SM_STA_ADD_IND, TASK_API, TASK_SM, SmStaAddIndPayloadSize)
  if result == nil: return
  let vif = vifChannelForIdx(vifIdx)
  let staIdx = vif.staIdx
  let wpaFlags = vifApConfig(vif).securityFlags
  cast[ptr SmStaAddIndPayload](result)[] = SmStaAddIndPayload(
    vifIdx: vifIdx, staIdx: staIdx, wpa: (wpaFlags and 1).uint8)
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] sta_add_ind ",
      vifIdx.uint32 or (staIdx.uint32 shl 8) or ((wpaFlags and 1).uint32 shl 16),
      vifSecurity(vif).connected.uint32)

proc smStaAddIndSend(vifIdx: uint8): bool =
  ## Send smStaAddInd; false without memory for it.
  let message = smStaAddInd(vifIdx)
  if message == nil: return false
  ke_msg_send(message)
  true

proc smActivationNotifyCurrent(): bool =
  ## sm_connection_sta_add_ind: tell the host the attempt's AP station is
  ## ready, in state 9.
  let connection = smEnvView().connectInfo
  if connection == nil or ke_state_get(TASK_SM) != SM_ACTIVATING_STATE: return false
  let vifIdx = connectInfoView(connection).vifIdx
  if vifIdx >= MAX_VIFS.uint8: return false
  if smActivationLive() and smActivation.pskPeer: return smActivation.peerPublished
  result = smStaAddIndSend(vifIdx)
  if not result:
    when defined(bl808WifiDiagWarmScan): nimFwDbgWarmAssocFailure = warmAssocPeerIndication
    sm_connect_ind(WLAN_FW_ASSOCIATE_FAIILURE.uint16, 0xFFFF)

proc smActivationConsumeSuccess(station: uint8): bool =
  ## The supplicant's success during the activation: the connection is
  ## reported when the activation finishes.
  if not smActivationLive(): return false
  if station == smActivation.station:
    smActivation.supplicantReady = true
  true

proc smActivationFinish() =
  ## Every request is answered: the station is published and the connection
  ## reported, or SM waits for the supplicant.
  if smActivation.peerPublished:
    if not smActivationHostPeer(smActivation):
      smActivationFail()
      return
  else:
    if not smStaAddIndSend(smActivation.vif):
      smActivationFail()
      return
    if not smActivationLive(): return
  let vifIdx = smActivation.vif
  let station = smActivation.station
  let supplicantReady = smActivation.supplicantReady
  smActivation = default(SmActivationOperation)
  if supplicantReady: staInfoForIdx(station).controlPortState = 2
  let securityState = vifSecurity(vifChannelForIdx(vifIdx))
  nimFwDbgVifSecType = securityState.cipher.uint32
  if securityState.cipher <= 1'u8 or supplicantReady:
    inc nimFwDbgConnectIndPrePath
    sm_connect_ind(0, 0)

proc smActivationNext() =
  ## Send the request of the current step, or finish after the last.
  if smActivation.step == 2 and smActivation.skipPsDisable: inc smActivation.step
  let index = smActivation.step
  if index == SmActivationRequests.len:
    smActivationFinish()
    return
  let request = ke_msg_try_alloc(SmActivationRequests[index], SmActivationTasks[index],
                                 TASK_SM, SmActivationLengths[index])
  if request == nil:
    smActivationFail()
    return
  let vif = smActivation.vif
  case index
  of 0:
    cast[ptr MmSetVifStateReqPayload](request)[] =
      MmSetVifStateReqPayload(aid: smActivation.aid, state: 1, vifIdx: vif)
  of 1:
    let connection = connectInfoView(smEnvView().connectInfo)
    cast[ptr MmSetPsOptionsReqPayload](request)[] = MmSetPsOptionsReqPayload(
      vifIdx: vif, listenInterval: connection.listenInterval, options: connection.psOptions)
  else:
    cast[ptr MeSetPsDisableReqPayload](request)[] =
      MeSetPsDisableReqPayload(disable: 0, vifIdx: vif)
  if not smSendReserved(request): smActivationFail()

proc smActivationStart(vif, station: uint8; aid: uint16; notifyWps: bool) =
  ## The association is accepted: enter state 9 and send its first request.
  smActivationCancel()
  smActivation = SmActivationOperation(vif: vif, station: station,
    stationEpoch: staDeleteEpoch(station), aid: aid,
    pskPeer: smActivationOrdinaryPsk(vif),
    initialKeyRevision: rxKeyLastChanged[station])
  smActivation.stamp = smGo(SM_ACTIVATING_STATE)
  smEnvView().saQueryActive = 0
  ke_timer_clear(SM_SA_QUERY_TIMEOUT_IND_MSG, TASK_SM)
  if notifyWps and wps_cbs != nil:
    let callback = wpsCallbacks().staAddConfirm
    if callback != nil:
      cast[proc() {.cdecl.}](callback)()
      if not smActivationLive(): return
  if vifSecurity(vifChannelForIdx(vif)).cipher >= 2'u8:
    nimFwWpaPendingMask = nimFwWpaPendingMask or (1'u32 shl vif)
  inc nimFwDbgAssocDone
  smActivationNext()

proc smActivationApply(): bool =
  ## The VIF is active: open the station's control port as configured, set
  ## the RX filter and publish a WPA2-PSK station's TX peer.
  let vifIdx = smActivation.vif
  let staIdx = smActivation.station
  let vif = vifChannelForIdx(vifIdx)
  let sta = staInfoForIdx(staIdx)
  let keyPointerFlags = vifKeyPointers(vif).flags
  let securityState = vifSecurity(vif)
  let configuredControlPortState = 2'u8 - (keyPointerFlags and 1).uint8
  let wpaPending = securityState.cipher >= 2 and
    (nimFwWpaPendingMask and (1'u32 shl vifIdx)) != 0
  let controlPortState = if wpaPending: 1'u8 else: configuredControlPortState
  if not smActivation.pskPeer: sta.controlPortState = controlPortState
  sta.rateWord = lmacGateHalfword(connectInfoView(smEnvView().connectInfo).ctrlPortEthertype)
  # RX control is shared. The AP filter also admits the frames needed by STA.
  if vifMgmtEnvView().apCount == 0:
    let mm = mmEnvView()
    mm.rxFilterBase = if mm.rxPromiscUploadFlag != 0: 0x3503A58C'u32 else: 0x3503858C'u32
    mm_rx_filter_set()
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] vif_state_cfm ",
      vifIdx.uint32 or (staIdx.uint32 shl 8), controlPortState.uint32)
  smActivation.skipPsDisable = configuredControlPortState != 2
  if smActivation.pskPeer:
    # The host links the peer while it handles the indication
    # (smActivationAcceptPeer, smActivationTrackPeer).
    if not smActivationOrdinaryPsk(vifIdx): return false
    let message = smStaAddInd(vifIdx)
    if message == nil: return false
    var publication = SmPeerPublication(payload: message)
    smPublishingPeer = addr publication
    ke_msg_send(message)
    smPublishingPeer = nil
    if not publication.linked or not smActivationLive() or
        not smActivationHostPeer(smActivation): return false
    smActivation.peerPublished = true
    sta.controlPortState = controlPortState
  true

proc smActivationConfirmed() =
  ## SM took the answer to the activation's request in flight. The attempt
  ## ends if its AP station has been deleted meanwhile. (The removal of its
  ## STA VIF has ended it already: smStaVifRetired.)
  if not staDeleteIsCurrent(smActivation.station, smActivation.stationEpoch):
    smActivationFail()
    return
  let step = smActivation.step
  inc smActivation.step
  if step == 0:
    if not smActivationApply():
      smActivationFail()
      return
    if smActivation.firstM1.length != 0:
      # WPA may allocate and queue M2, or end the attempt, from here.
      let pending = smActivation.firstM1
      smActivation.firstM1.length = 0
      let station = smActivation.station
      let sta = staInfoForIdx(station)
      if not smActivationHostPeer(smActivation):
        smActivationFail()
        return
      if rxKeyLastChanged[station] == smActivation.initialKeyRevision and
          sta.keyHolder == nil and sta.macAddr == pending.source and
          smActivationOrdinaryPsk(smActivation.vif):
        sm_handle_eapol_input(station, unsafeAddr pending.source[0],
                              unsafeAddr pending.bytes[0], pending.length.uint16)
        if not smActivationLive(): return
  smActivationNext()
