type
  SmCleanupTag = object
    next: ptr SmCleanupTag
    header: ptr KeMsgHdr
    serial: uint32
    responseId: uint16
    responseSource: uint8
    command: bool

  SmCleanupOperation = object
    session: RxHostSession
    serial, stationEpoch, channelBinding: uint32
    vifIndex, station: uint8
    active, replyReserved, notified, awaiting, lost: bool
    disconnectIndication: bool
    status, reason: uint16
    step: int
    needed: array[4, bool]
    request, reply, connectionInfo, indication, discardedIndication: pointer
    bss: CoList

var
  smCleanup {.wifiCtrl.}: SmCleanupOperation
  smCleanupSerial {.wifiCtrl.}: uint32
  smCleanupTags {.wifiCtrl.}: ptr SmCleanupTag
  smCleanupServicing {.wifiCtrl.}: bool

const
  SmCleanupRequests = [ME_SET_PS_DISABLE_REQ, MM_SET_VIF_STATE_REQ,
                       MM_STA_DEL_REQ, ME_SET_ACTIVE_REQ]
  SmCleanupResponses = [ME_SET_PS_DISABLE_CFM, MM_SET_VIF_STATE_CFM,
                        MM_STA_DEL_CFM, ME_SET_ACTIVE_CFM]
  SmCleanupLengths = [MeSetPsDisableReqPayloadSize, MmSetVifStateReqPayloadSize,
                      MmStaDelReqPayloadSize, MeSetActiveReqPayloadSize]

proc smCleanupOwnsStation(station, vif: uint8; epoch: uint32): bool =
  staDeleteIsCurrent(station, epoch) and staInfoForIdx(station).instNbr == vif

proc smCleanupTagFor(header: ptr KeMsgHdr): ptr SmCleanupTag =
  var tag = smCleanupTags
  while tag != nil:
    if tag.header == header: return tag
    tag = tag.next

proc smCleanupForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr smCleanupTags
  while link[] != nil:
    if link[].header == header:
      let payload = keMsgPayload(link[].header)
      link[] = link[].next
      # The awaited request was consumed while its reply was still reserved,
      # or the reply was freed undelivered: no confirmation will arrive.
      if smCleanup.active and smCleanup.awaiting and
          (payload == smCleanup.reply or
           (payload == smCleanup.request and smCleanup.replyReserved)):
        smCleanup.lost = true
      return
    link = addr link[].next

proc smCleanupCurrent(serial: uint32): bool =
  smCleanup.active and smCleanup.serial == serial and
    rxHostSessionCurrent(smCleanup.session) and
    vifChannelForIdx(smCleanup.vifIndex).vifType == VIF_TYPE_STA and
    ke_state_get(TASK_SM) == SmDisconnectingState

proc smCleanupAlloc(index: int; reply: bool; serial: uint32): pointer =
  let wireLength = if reply: 0'u32 else: SmCleanupLengths[index]
  const alignment = alignof(SmCleanupTag).uint32
  let offset = (wireLength + KeMsgTailSlack + alignment - 1) and not (alignment - 1)
  let source = if index in [0, 3]: TASK_ME else: TASK_MM
  let id = if reply: SmCleanupResponses[index] else: SmCleanupRequests[index]
  result = ke_msg_try_alloc(id, (if reply: TASK_SM else: source),
                            (if reply: source else: TASK_SM),
                            offset + sizeof(SmCleanupTag).uint32)
  if result == nil: return
  let header = keMsgHdrFromPayload(result)
  header.paramLen = wireLength
  let tag = cast[ptr SmCleanupTag](cast[uint](result) + offset.uint)
  tag[] = SmCleanupTag(header: header, serial: serial,
    responseId: SmCleanupResponses[index], responseSource: source, command: not reply)
  tag.next = smCleanupTags
  smCleanupTags = tag

proc smCleanupOwnsRequest(request: pointer): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  request != nil and smCleanupTagFor(keMsgHdrFromPayload(request)) != nil

proc smCleanupAdmitRequest(request: pointer): bool =
  if request == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = smCleanupTagFor(keMsgHdrFromPayload(request))
  if tag == nil: return true
  if not tag.command or not smCleanupCurrent(tag.serial): return false
  if tag.header.id == MM_STA_DEL_REQ and
      not smCleanupOwnsStation(smCleanup.station, smCleanup.vifIndex, smCleanup.stationEpoch) and
      not mmStaDelOwned(smCleanup.station, smCleanup.vifIndex, smCleanup.stationEpoch):
    cast[ptr MmStaDelReqPayload](request).staIdx = 0xFF
  true

proc smCleanupTakeReply(request: pointer; id: uint16; length: uint32): pointer =
  let saved = irqSave()
  defer: irqRestore(saved)
  if request == nil or request != smCleanup.request or length != 0 or
      not smCleanup.replyReserved or
      not smCleanupCurrent(smCleanup.serial) or
      id != SmCleanupResponses[smCleanup.step]:
    return nil
  smCleanup.replyReserved = false
  smCleanup.reply

proc smCleanupPayloadOwned(payload: pointer; serial: uint32): bool =
  if payload == nil: return false
  let tag = smCleanupTagFor(keMsgHdrFromPayload(payload))
  tag != nil and tag.serial == serial

proc smCleanupCancel() =
  let saved = irqSave()
  defer: irqRestore(saved)
  let retired = smCleanup
  smCleanup = default(SmCleanupOperation)
  inc smCleanupSerial
  template owns(payload: pointer): bool = smCleanupPayloadOwned(payload, retired.serial)
  if retired.request != nil or retired.reply != nil:
    if (meControlCommand == retired.request and owns(retired.request)) or
        (meControlReply == retired.reply and owns(retired.reply)):
      meControlReset()
      if meControlCommand == nil and meControlReply == nil and mmPsModeRequest == nil:
        ke_state_set(TASK_ME, MeIdleState)
    else:
      if owns(retired.request): meCancelQueuedPayload(retired.request)
      # Extracting the request can free and recycle another queued allocation.
      if not retired.replyReserved and retired.reply != retired.request and owns(retired.reply):
        meCancelQueuedPayload(retired.reply)
  if retired.replyReserved and owns(retired.reply):
    ke_msg_free(keMsgHdrFromPayload(retired.reply))
  if retired.connectionInfo != nil:
    ke_msg_free(keMsgHdrFromPayload(retired.connectionInfo))
  if retired.indication != nil:
    ke_msg_free(keMsgHdrFromPayload(retired.indication))
  if retired.discardedIndication != nil:
    ke_msg_free(keMsgHdrFromPayload(retired.discardedIndication))
  var pending = retired.bss
  while pending.first != nil:
    ke_msg_free(co_list_pop_front(addr pending))

proc smCleanupNeedsService(): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  smCleanup.active and not txlResetting() and
    (not smCleanup.awaiting or smCleanup.lost or
     not smCleanupCurrent(smCleanup.serial))

proc smCleanupService() =
  if not smCleanup.active or smCleanupServicing: return
  smCleanupServicing = true
  defer: smCleanupServicing = false
  let saved = irqSave()
  defer: irqRestore(saved)
  if txlResetting(): return
  let serial = smCleanup.serial
  template current(): bool = smCleanupCurrent(serial)
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  template publishIndication(indication, session: untyped) =
    # The message is no longer in the transaction. The synchronous host
    # callback may pump replies and finish this cleanup before it returns.
    smCleanupServicing = false
    try:
      outside: rxHostSendStationIndication(indication, session)
    finally:
      smCleanupServicing = true
  if not current():
    let releaseState = ke_state_get(TASK_SM) == SmDisconnectingState
    let cancelledSerial = smCleanupSerial + 1'u32
    smCleanupCancel()
    # Free/ME callbacks can install another owner before cancellation returns.
    if releaseState and smCleanupSerial == cancelledSerial and
        smEnvView().connectInfo == nil and ke_state_get(TASK_SM) == SmDisconnectingState:
      smGo(SmIdleState)
    return
  if smCleanup.lost:
    # Whether the lost step took effect is unknown. Carry on with the next
    # one so the disconnect still completes.
    let reserved = if smCleanup.replyReserved: smCleanup.reply else: nil
    smCleanup.lost = false
    smCleanup.request = nil
    smCleanup.reply = nil
    smCleanup.replyReserved = false
    smCleanup.awaiting = false
    inc smCleanup.step
    if reserved != nil:
      outside: ke_msg_free(keMsgHdrFromPayload(reserved))
      if not current(): return
  if smCleanup.connectionInfo != nil:
    let connection = smCleanup.connectionInfo
    smCleanup.connectionInfo = nil
    outside: ke_msg_free(keMsgHdrFromPayload(connection))
    if not current(): return
  if smCleanup.discardedIndication != nil:
    let indication = smCleanup.discardedIndication
    smCleanup.discardedIndication = nil
    outside: ke_msg_free(keMsgHdrFromPayload(indication))
    if not current(): return
  while smCleanup.bss.first != nil:
    let message = co_list_pop_front(addr smCleanup.bss)
    outside: ke_msg_free(message)
    if not current(): return
  while current() and not smCleanup.awaiting:
    if smCleanup.step == 4:
      let indication = smCleanup.indication
      let session = smCleanup.session
      smCleanup.indication = nil
      smCleanup.active = false
      smGo(SmIdleState)
      if indication != nil:
        publishIndication(indication, session)
      return
    let index = smCleanup.step
    if not smCleanup.needed[index]:
      inc smCleanup.step
      continue

    # Reserve only this step. A failure leaves earlier completed steps intact
    # and keeps the unpublished allocations local across reentrant callbacks.
    var request = smCleanupAlloc(index, false, serial)
    defer:
      if request != nil: ke_msg_free(keMsgHdrFromPayload(request))
    if request == nil or not current(): return
    var reply: pointer
    defer:
      if reply != nil: ke_msg_free(keMsgHdrFromPayload(reply))
    if index != 2:
      reply = smCleanupAlloc(index, true, serial)
      if reply == nil or not current(): return
    if smCleanup.disconnectIndication and smCleanup.indication == nil:
      let message = ke_msg_try_alloc(SM_DISCONNECT_IND, TASK_API, TASK_SM,
                                     SmDisconnectProcessIndPayloadSize)
      if message == nil: return
      if not current():
        ke_msg_free(keMsgHdrFromPayload(message))
        return
      smCleanup.indication = message
      let indication = cast[ptr SmDisconnectProcessIndPayload](message)
      indication.status = smCleanup.status
      indication.reason = smCleanup.reason
      indication.vifIdx = smCleanup.vifIndex
    if not smCleanup.notified:
      smCleanup.notified = true
      let callback = if wpa_cbs == nil: nil else: wpaCallbacks().stationDisconnected
      if callback != nil:
        outside: cast[proc(reason: uint8) {.cdecl.}](callback)(0)
        if not current(): return
    if index == 3:
      nimFwWpaPendingMask = nimFwWpaPendingMask and not (1'u32 shl smCleanup.vifIndex)
    if txlResetting(): return
    case index
    of 0:
      cast[ptr MeSetPsDisableReqPayload](request)[] =
        MeSetPsDisableReqPayload(disable: 0, vifIdx: smCleanup.vifIndex)
    of 1:
      cast[ptr MmSetVifStateReqPayload](request)[] =
        MmSetVifStateReqPayload(aid: 0, state: 0, vifIdx: smCleanup.vifIndex)
    of 2:
      cast[ptr MmStaDelReqPayload](request).staIdx =
        if smCleanupOwnsStation(smCleanup.station, smCleanup.vifIndex, smCleanup.stationEpoch): smCleanup.station
        else: 0xFF'u8
    else:
      cast[ptr MeSetActiveReqPayload](request)[] =
        MeSetActiveReqPayload(active: 0, vifIdx: smCleanup.vifIndex)
    smCleanup.request = request
    smCleanup.reply = if index == 2: request else: reply
    smCleanup.replyReserved = reply != nil
    smCleanup.awaiting = true
    let published = request
    request = nil
    reply = nil
    outside: ke_msg_send(published)
    if not current(): return
    if index == 0:
      # Retire the original binding and VIF flags before notifying the host.
      # The remaining confirmation gates still keep reconnect admission busy.
      let vifIndex = smCleanup.vifIndex
      if chanCtxtLinkEpochs[vifIndex] == smCleanup.channelBinding and
          vifChannelForIdx(vifIndex).chanCtxt != nil:
        chan_ctxt_unlink(vifIndex)
        if not current(): return
      vifApConfig(vifChannelForIdx(vifIndex)).securityFlags = 0
    if smCleanup.disconnectIndication and smCleanup.indication != nil:
      let indication = smCleanup.indication
      let session = smCleanup.session
      smCleanup.indication = nil
      smCleanup.disconnectIndication = false
      publishIndication(indication, session)

proc smCleanupConsumeReply(reply: pointer): bool =
  if reply == nil: return smCleanup.active
  let saved = irqSave()
  var advance = false
  defer:
    irqRestore(saved)
    if advance: smCleanupService()
  let header = keMsgHdrFromPayload(reply)
  let tag = smCleanupTagFor(header)
  if tag == nil: return smCleanup.active
  if not smCleanupCurrent(tag.serial) or not smCleanup.awaiting or smCleanup.replyReserved or
      reply != smCleanup.reply or header.id != tag.responseId or
      header.srcId != tag.responseSource or header.destId != TASK_SM or
      header.paramLen != 0:
    return true
  smCleanup.request = nil
  smCleanup.reply = nil
  smCleanup.awaiting = false
  inc smCleanup.step
  advance = true
  true

proc smCleanupCfmHandler(reply: pointer): cint {.cdecl.} =
  discard smCleanupConsumeReply(reply)
  KeMsgConsumed

proc smCleanupBegin(vifEntry: pointer; indication: pointer = nil;
                    disconnected = false; status = 0'u16; reason = 0'u16): bool =
  ## smTeardown's cleanup phase: claim the link, then publish state 10.
  let saved = irqSave()
  defer:
    irqRestore(saved)
    if result: smCleanupService()
  if smCleanup.active: return false
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
  inc smCleanupSerial
  let activationConnection = sm.connectInfo
  smCleanup = SmCleanupOperation(active: true, serial: smCleanupSerial,
    vifIndex: vif.vifIdx, station: vif.staIdx,
    session: captureRxHostSession(vif.vifIdx, 0xFF),
    stationEpoch: stationEpoch, channelBinding: chanCtxtLinkEpochs[vif.vifIdx],
    needed: [true, vif.state != 0, vif.staIdx != 0xFF, true],
    connectionInfo: sm.connectInfo, indication: indication,
    disconnectIndication: disconnected, status: status, reason: reason,
    bss: sm.pendingBssParams)
  sm.connectInfo = nil
  if indication == sm.connectIndMsg:
    sm.connectIndMsg = nil
  elif sm.connectIndMsg != nil:
    smCleanup.discardedIndication = sm.connectIndMsg
    sm.connectIndMsg = nil
  co_list_init(addr sm.pendingBssParams)
  sm.cancelRequested = 0
  sm.joinBssFlag = 0
  sm.deauthPending = 0
  sm.scanResultIndex = 0xFFFFFFFF'u32
  smConnecting = false
  smGo(SmDisconnectingState, tdCleanup)
  smActivationCancelConnection(activationConnection)
  smBssCancel()
  smDeferredCancel()
  true
