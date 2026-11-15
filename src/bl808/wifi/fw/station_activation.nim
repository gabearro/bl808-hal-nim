type
  SmActivationTag = object
    next: ptr SmActivationTag
    header: ptr KeMsgHdr
    serial: uint32
    index: uint8
    command: bool
  SmActivationOperation = object
    owner: SmTxBuildContext
    indication: pointer
    prepared: SmActivationPrepared
    request, reply: pointer
    step: int
    active, awaiting, replyIssued, skipPsDisable, lost, supplicantReady: bool

const
  # Confirm hardware setup before publishing station readiness. All tracking
  # stays outside the vendor wire payloads and survives ME's in-place forwarding.
  SmActivationRequests = [MM_SET_VIF_STATE_REQ, MM_SET_PS_OPTIONS_REQ,
                           ME_SET_PS_DISABLE_REQ]
  SmActivationSources = [TASK_MM, TASK_MM, TASK_ME]
  SmActivationLengths = [MmSetVifStateReqPayloadSize, MmSetPsOptionsReqPayloadSize,
                          MeSetPsDisableReqPayloadSize]

var
  smActivation {.wifiCtrl.}: SmActivationOperation
  smActivationSerial {.wifiCtrl.}: uint32
  smActivationTags {.wifiCtrl.}: ptr SmActivationTag

proc smActivationOwnerCurrent(owner: SmTxBuildContext; indication: pointer): bool =
  if not smAssocOwnerCurrent(owner, indication) or indication == nil: return false
  let station = owner.identity.station
  station < STA_INFO_TAB_ENTRIES.uint8 and staInfoForIdx(station).valid != 0 and
    staInfoForIdx(station).instNbr == owner.identity.vif

proc smActivationCurrent(serial: uint32): bool =
  smActivation.active and not smActivation.lost and
    smActivation.prepared.serial == serial and serial == smActivationSerial and
    smActivationOwnerCurrent(smActivation.owner, smActivation.indication)

proc smActivationTagFor(header: ptr KeMsgHdr): ptr SmActivationTag =
  var tag = smActivationTags
  while tag != nil:
    if tag.header == header: return tag
    tag = tag.next

proc smActivationForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr smActivationTags
  while link[] != nil:
    if link[].header == header:
      let tag = link[]
      let message = keMsgPayload(tag.header)
      link[] = tag.next
      if not smActivation.active or tag.serial != smActivation.prepared.serial: return
      if smActivation.request == message:
        smActivation.request = nil
        if not smActivation.replyIssued: smActivation.lost = true
      if smActivation.reply == message:
        smActivation.reply = nil
        smActivation.lost = true
      for index in 0 ..< SmActivationRequests.len:
        if smActivation.prepared.requests[index] == message:
          smActivation.prepared.requests[index] = nil
          smActivation.lost = true
        if smActivation.prepared.replies[index] == message:
          smActivation.prepared.replies[index] = nil
          smActivation.lost = true
      return
    link = addr link[].next

proc smActivationReleasePrepared(prepared: var SmActivationPrepared) =
  let retired = prepared
  prepared = default(SmActivationPrepared)
  for message in retired.requests:
    if message != nil: ke_msg_free(keMsgHdrFromPayload(message))
  for message in retired.replies:
    if message != nil: ke_msg_free(keMsgHdrFromPayload(message))
  if retired.stationInd != nil: ke_msg_free(keMsgHdrFromPayload(retired.stationInd))

proc smActivationCancel() =
  let saved = irqSave()
  defer: irqRestore(saved)
  if not smActivation.active: return
  var retired = smActivation
  smActivation = default(SmActivationOperation)
  inc smActivationSerial
  if not smActivationCancelControl(retired.request, retired.reply, retired.owner):
    meCancelQueuedPayload(retired.request)
    meCancelQueuedPayload(retired.reply)
  smActivationReleasePrepared(retired.prepared)

proc smActivationCancelConnection(connection: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  if connection != nil and smActivation.active and smActivation.owner.connection == connection:
    smActivationCancel()

proc smActivationAlloc(index: int; serial: uint32; reply: bool): pointer =
  let length = if reply: 0'u32 else: SmActivationLengths[index]
  const alignment = alignof(SmActivationTag).uint
  let extra = KeMsgTailSlack + (alignment - 1).uint32 + sizeof(SmActivationTag).uint32
  result = ke_msg_try_alloc(SmActivationRequests[index] + (if reply: 1'u16 else: 0'u16),
    (if reply: TASK_SM else: SmActivationSources[index]),
    (if reply: SmActivationSources[index] else: TASK_SM), length + extra)
  if result == nil: return
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(result)
  header.paramLen = length
  let start = cast[uint](result) + length.uint + KeMsgTailSlack.uint
  let tag = cast[ptr SmActivationTag]((start + alignment - 1) and not (alignment - 1))
  tag[] = SmActivationTag(next: smActivationTags, header: header, serial: serial,
    index: index.uint8, command: not reply)
  smActivationTags = tag

proc smActivationPrepare(owner: SmTxBuildContext; indication: pointer;
                         aid: uint16; prepared: var SmActivationPrepared): bool =
  if not smActivationOwnerCurrent(owner, indication): return false
  if smActivation.active and not smActivationCurrent(smActivation.prepared.serial):
    smActivationCancel()
  if smActivation.active or not smActivationOwnerCurrent(owner, indication): return false
  inc smActivationSerial
  prepared.serial = smActivationSerial
  for index in 0 ..< SmActivationRequests.len:
    prepared.requests[index] = smActivationAlloc(index, prepared.serial, false)
    if prepared.requests[index] == nil or prepared.serial != smActivationSerial or
        not smActivationOwnerCurrent(owner, indication): return false
    prepared.replies[index] = smActivationAlloc(index, prepared.serial, true)
    if prepared.replies[index] == nil or prepared.serial != smActivationSerial or
        not smActivationOwnerCurrent(owner, indication): return false
  prepared.stationInd = ke_msg_try_alloc(SM_STA_ADD_IND, TASK_API, TASK_SM,
                                        SmStaAddIndPayloadSize)
  if prepared.stationInd == nil or prepared.serial != smActivationSerial or
      not smActivationOwnerCurrent(owner, indication): return false
  cast[ptr MmSetVifStateReqPayload](prepared.requests[0])[] =
    MmSetVifStateReqPayload(aid: aid, state: 1, vifIdx: owner.identity.vif)
  true

proc smActivationOwnsRequest(request: pointer): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  request != nil and smActivationTagFor(keMsgHdrFromPayload(request)) != nil

proc smActivationAdmitRequest(request: pointer): bool =
  if request == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(request)
  let tag = smActivationTagFor(header)
  if tag == nil: return true
  if not tag.command or not smActivationCurrent(tag.serial) or not smActivation.awaiting or
      tag.serial != smActivation.prepared.serial or tag.index.int != smActivation.step or
      smActivation.request != request: return false
  let index = tag.index.int
  if index == 2 and header.id == MM_SET_PS_MODE_REQ:
    return request == meControlCommand and meControlFinalId == ME_SET_PS_DISABLE_CFM and
      header.srcId == TASK_ME and header.destId == TASK_MM and header.paramLen == 1
  if header.id != SmActivationRequests[index] or header.srcId != TASK_SM or
      header.destId != SmActivationSources[index] or
      header.paramLen != SmActivationLengths[index]: return false
  let vif = smActivation.owner.identity.vif
  case index
  of 0:
    let payload = cast[ptr MmSetVifStateReqPayload](request)
    payload.vifIdx == vif and payload.state == 1
  of 1: cast[ptr MmSetPsOptionsReqPayload](request).vifIdx == vif
  else:
    let payload = cast[ptr MeSetPsDisableReqPayload](request)
    payload.vifIdx == vif and payload.disable == 0

proc smActivationAdmitControlReply(reply: pointer): bool =
  if reply == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(reply)
  let tag = smActivationTagFor(header)
  if tag == nil: return true
  not tag.command and tag.index == 2 and smActivationCurrent(tag.serial) and
    smActivation.awaiting and smActivation.replyIssued and smActivation.reply == reply and
    tag.serial == smActivation.prepared.serial and header.id == MM_SET_PS_MODE_CFM and
    header.srcId == TASK_MM and header.destId == TASK_ME and header.paramLen == 0

proc smActivationTakeReply(request: pointer; id: uint16; length: uint32): pointer =
  let saved = irqSave()
  defer: irqRestore(saved)
  if request != smActivation.request or not smActivationAdmitRequest(request) or length != 0 or
      not smActivation.active or smActivation.replyIssued or
      id != SmActivationRequests[smActivation.step] + 1: return nil
  result = smActivation.prepared.replies[smActivation.step]
  smActivation.prepared.replies[smActivation.step] = nil
  smActivation.replyIssued = result != nil

proc smActivationSendReady(owner: SmTxBuildContext; indication: pointer;
                           message: var pointer): bool =
  if message == nil or not smActivationOwnerCurrent(owner, indication): return false
  let vifIdx = owner.identity.vif
  let vif = vifChannelForIdx(vifIdx)
  let staIdx = vif.staIdx
  let wpaFlags = vifApConfig(vif).securityFlags
  cast[ptr SmStaAddIndPayload](message)[] = SmStaAddIndPayload(
    vifIdx: vifIdx, staIdx: staIdx, wpa: (wpaFlags and 1).uint8)
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] sta_add_ind ",
      vifIdx.uint32 or (staIdx.uint32 shl 8) or ((wpaFlags and 1).uint32 shl 16),
      vifSecurity(vif).connected.uint32)
  let saved = irqSave()
  defer: irqRestore(saved)
  if not smActivationOwnerCurrent(owner, indication): return false
  let payload = message
  message = nil
  ke_msg_send(payload)
  true

proc smActivationNotifyCurrent(): bool =
  let connection = smEnvView().connectInfo
  if connection == nil: return false
  let vifIndex = connectInfoView(connection).vifIdx
  if vifIndex >= MAX_VIFS.uint8: return false
  let station = vifChannelForIdx(vifIndex).staIdx
  if station >= STA_INFO_TAB_ENTRIES.uint8: return false
  let owner = SmTxBuildContext(connection: connection, state: ke_state_get(TASK_SM),
    serial: smTxSerials[vifIndex], identity: TxSessionIdentity(captured: true,
      vif: vifIndex, station: station, vifEpoch: rxVifEpochs[vifIndex],
      stationEpoch: staDeleteEpoch(station), resetEpoch: txResetEpoch))
  let indication = smEnvView().connectIndMsg
  if owner.state != SM_ACTIVATING_STATE or
      not smActivationOwnerCurrent(owner, indication): return false
  var message = ke_msg_try_alloc(SM_STA_ADD_IND, TASK_API, TASK_SM, SmStaAddIndPayloadSize)
  defer:
    if message != nil: ke_msg_free(keMsgHdrFromPayload(message))
  if message == nil:
    if smActivationOwnerCurrent(owner, indication):
      sm_connect_ind(WLAN_FW_ASSOCIATE_FAIILURE.uint16, 0xFFFF)
    return false
  smActivationSendReady(owner, indication, message)

proc smActivationFail(serial: uint32) =
  if not smActivation.active or smActivation.prepared.serial != serial: return
  let owner = smActivation.owner
  let indication = smActivation.indication
  smActivationCancel()
  if smActivationOwnerCurrent(owner, indication):
    sm_connect_ind(WLAN_FW_ASSOCIATE_FAIILURE.uint16, 0xFFFF)

proc smActivationConsumeSuccess(station: uint8): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  if not smActivationCurrent(smActivation.prepared.serial): return false
  # A result for another station cannot complete this attempt.
  if station == smActivation.owner.identity.station:
    smActivation.supplicantReady = true
  true

proc smActivationFinish(serial: uint32) =
  if not smActivationCurrent(serial): return
  let owner = smActivation.owner
  let indication = smActivation.indication
  var unused = smActivation.prepared
  var message = unused.stationInd
  unused.stationInd = nil
  smActivation.prepared = SmActivationPrepared(serial: serial)
  defer:
    if message != nil: ke_msg_free(keMsgHdrFromPayload(message))
  smActivationReleasePrepared(unused)
  if not smActivationCurrent(serial): return
  if not smActivationSendReady(owner, indication, message):
    smActivationFail(serial)
    return
  if not smActivationCurrent(serial): return
  let supplicantReady = smActivation.supplicantReady
  smActivation = default(SmActivationOperation)
  inc smActivationSerial
  if supplicantReady: staInfoForIdx(owner.identity.station).controlPortState = 2
  let securityState = vifSecurity(vifChannelForIdx(owner.identity.vif))
  nimFwDbgVifSecType = securityState.cipher.uint32
  if securityState.cipher <= 1'u8 or supplicantReady:
    inc nimFwDbgConnectIndPrePath
    sm_connect_ind(0, 0)

proc smActivationSendNext(serial: uint32) =
  let saved = irqSave()
  defer: irqRestore(saved)
  if not smActivationCurrent(serial):
    smActivationFail(serial)
    return
  if smActivation.awaiting: return
  if smActivation.step == 2 and smActivation.skipPsDisable: inc smActivation.step
  if smActivation.step == SmActivationRequests.len:
    smActivationFinish(serial)
    return
  let index = smActivation.step
  let request = smActivation.prepared.requests[index]
  if request == nil:
    smActivationFail(serial)
    return
  let vifIndex = smActivation.owner.identity.vif
  if index == 1:
    let connection = connectInfoView(smActivation.owner.connection)
    cast[ptr MmSetPsOptionsReqPayload](request)[] = MmSetPsOptionsReqPayload(
      vifIdx: vifIndex, listenInterval: connection.listenInterval, options: connection.psOptions)
  elif index == 2:
    cast[ptr MeSetPsDisableReqPayload](request)[] =
      MeSetPsDisableReqPayload(disable: 0, vifIdx: vifIndex)
  smActivation.request = request
  smActivation.reply = smActivation.prepared.replies[index]
  smActivation.prepared.requests[index] = nil
  smActivation.awaiting = true
  smActivation.replyIssued = false
  ke_msg_send(request)

proc smActivationStart(owner: SmTxBuildContext; indication: pointer;
                       prepared: var SmActivationPrepared): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  if smActivation.active or owner.state != SM_ACTIVATING_STATE or
      prepared.serial != smActivationSerial or prepared.stationInd == nil or
      not smActivationOwnerCurrent(owner, indication): return false
  for index in 0 ..< SmActivationRequests.len:
    if prepared.requests[index] == nil or prepared.replies[index] == nil: return false
  smActivation = SmActivationOperation(owner: owner, indication: indication,
    prepared: prepared, active: true)
  let serial = prepared.serial
  let notifyWps = prepared.notifyWps
  prepared = default(SmActivationPrepared)
  if notifyWps and wps_cbs != nil:
    let callback = wpsCallbacks().staAddConfirm
    if callback != nil: cast[proc() {.cdecl.}](callback)()
    if not smActivationCurrent(serial):
      smActivationFail(serial)
      return true
  let vifIdx = owner.identity.vif
  if vifSecurity(vifChannelForIdx(vifIdx)).cipher >= 2'u8:
    nimFwWpaPendingMask = nimFwWpaPendingMask or (1'u32 shl vifIdx)
  inc nimFwDbgAssocDone
  smActivationSendNext(serial)
  true

proc smActivationApply(serial: uint32): bool =
  if not smActivationCurrent(serial): return false
  let owner = smActivation.owner
  let vifIdx = owner.identity.vif
  let staIdx = owner.identity.station
  let vif = vifChannelForIdx(vifIdx)
  let sta = staInfoForIdx(staIdx)
  let keyPointerFlags = vifKeyPointers(vif).flags
  let securityState = vifSecurity(vif)
  let configuredControlPortState = 2'u8 - (keyPointerFlags and 1).uint8
  let wpaPending = securityState.cipher >= 2 and
    (nimFwWpaPendingMask and (1'u32 shl vifIdx)) != 0
  let controlPortState = if wpaPending: 1'u8 else: configuredControlPortState
  sta.controlPortState = controlPortState
  sta.rateWord = lmacGateHalfword(connectInfoView(owner.connection).ctrlPortEthertype)
  let mm = mmEnvView()
  mm.rxFilterBase = if mm.rxPromiscUploadFlag != 0: 0x3503A58C'u32 else: 0x3503858C'u32
  mm_rx_filter_set()
  if not smActivationCurrent(serial): return false
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] vif_state_cfm ",
      vifIdx.uint32 or (staIdx.uint32 shl 8), controlPortState.uint32)
    if not smActivationCurrent(serial): return false
  smActivation.skipPsDisable = configuredControlPortState != 2
  true

proc smActivationConfirm(reply: pointer; index: int): bool =
  if reply == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(reply)
  let tag = smActivationTagFor(header)
  if tag == nil: return false
  let serial = tag.serial
  result = true
  if tag.command or index < 0 or index >= SmActivationRequests.len or
      not smActivationCurrent(serial) or not smActivation.awaiting or
      not smActivation.replyIssued or smActivation.reply != reply or
      tag.serial != smActivation.prepared.serial or tag.index.int != index or
      smActivation.step != index or header.id != SmActivationRequests[index] + 1 or
      header.srcId != SmActivationSources[index] or header.destId != TASK_SM or
      header.paramLen != 0: return
  smActivation.request = nil
  smActivation.reply = nil
  smActivation.awaiting = false
  smActivation.replyIssued = false
  inc smActivation.step
  if index == 0 and not smActivationApply(serial):
    smActivationFail(serial)
    return
  smActivationSendNext(serial)

proc smActivationNeedsService(): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  smActivation.active and not smActivationCurrent(smActivation.prepared.serial)

proc smActivationService() =
  let saved = irqSave()
  defer: irqRestore(saved)
  if smActivationNeedsService(): smActivationFail(smActivation.prepared.serial)
