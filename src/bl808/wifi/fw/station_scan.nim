type
  SmScanTag = object
    next: ptr SmScanTag
    header: ptr KeMsgHdr
    owner: SmTxBuildContext
    indication, reply: pointer
    responseId: uint16
    command, published, claimed: bool
  SmScanLost = object
    owner: SmTxBuildContext
    indication: pointer
    status: uint16
    pending: bool

var
  smScanTags {.wifiCtrl.}: ptr SmScanTag
  smScanLost {.wifiCtrl.}: SmScanLost

proc smScanTagFor(header: ptr KeMsgHdr): ptr SmScanTag =
  var tag = smScanTags
  while tag != nil:
    if tag.header == header: return tag
    tag = tag.next

proc smScanOwnerCurrent(owner: SmTxBuildContext; indication: pointer): bool =
  indication != nil and smTxOwnerCurrent(owner) and
    smEnvView().connectIndMsg == indication

proc smScanForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr smScanTags
  while link[] != nil:
    if link[].header == header:
      let tag = link[]
      link[] = tag.next
      let reply = tag.reply
      tag.reply = nil
      if tag.published and not tag.claimed and
          smScanOwnerCurrent(tag.owner, tag.indication):
        smScanLost = SmScanLost(owner: tag.owner, indication: tag.indication,
          status: (if tag.responseId == SCANU_START_CFM:
            WLAN_FW_SCAN_NO_BSSID_AND_CHANNEL.uint16 else: WLAN_FW_JOIN_NETWORK_FAILURE.uint16),
          pending: true)
      if reply != nil: ke_msg_free(keMsgHdrFromPayload(reply))
      return
    link = addr link[].next

proc smScanAllocMessage(id: uint16; command: bool; owner: SmTxBuildContext;
                        indication: pointer): pointer =
  let length = if command: ScanuStartReqPayloadSize else: StatusCfmPayloadSize
  const alignment = alignof(SmScanTag).uint
  let extra = KeMsgTailSlack + (alignment - 1).uint32 + sizeof(SmScanTag).uint32
  result = ke_msg_try_alloc(id, (if command: TASK_SCANU else: TASK_SM),
    (if command: TASK_SM else: TASK_SCANU), length + extra)
  if result == nil: return
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(result)
  header.paramLen = length
  let start = cast[uint](result) + length.uint + KeMsgTailSlack.uint
  let tag = cast[ptr SmScanTag]((start + alignment - 1) and not (alignment - 1))
  tag[] = SmScanTag(next: smScanTags, header: header, owner: owner,
    indication: indication, responseId: (if command: id + 1 else: id), command: command)
  smScanTags = tag

proc smScanAlloc(owner: SmTxBuildContext; indication: pointer;
                 id, nextState: uint16): pointer =
  if not smScanOwnerCurrent(owner, indication): return nil
  var expected = owner
  expected.state = nextState
  result = smScanAllocMessage(id, true, expected, indication)
  if result == nil: return
  if not smScanOwnerCurrent(owner, indication):
    ke_msg_free(keMsgHdrFromPayload(result))
    return nil
  let reply = smScanAllocMessage(id + 1, false, expected, indication)
  smScanTagFor(keMsgHdrFromPayload(result)).reply = reply
  if reply == nil or not smScanOwnerCurrent(owner, indication):
    ke_msg_free(keMsgHdrFromPayload(result))
    return nil

proc smScanPublish(request: pointer): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = smScanTagFor(keMsgHdrFromPayload(request))
  if tag == nil or not tag.command or not smScanOwnerCurrent(tag.owner, tag.indication):
    return false
  tag.published = true
  true

proc smScanOwnsRequest(request: pointer): bool =
  if request == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = smScanTagFor(keMsgHdrFromPayload(request))
  tag != nil and tag.command

proc smScanAdmitRequest(request: pointer): bool =
  if request == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(request)
  let tag = smScanTagFor(header)
  if tag == nil: return true
  tag.command and tag.published and not tag.claimed and
    header.id + 1 == tag.responseId and header.destId == TASK_SCANU and
    header.srcId == TASK_SM and header.paramLen == ScanuStartReqPayloadSize and
    smScanOwnerCurrent(tag.owner, tag.indication)

proc smScanCompletionAlloc(request: pointer; id: uint16; destination: uint8): pointer =
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = if request == nil: nil else: smScanTagFor(keMsgHdrFromPayload(request))
  if tag == nil:
    return ke_msg_alloc(id, destination, TASK_SCANU, StatusCfmPayloadSize)
  if not tag.command or not tag.published or tag.claimed or
      tag.responseId != id or destination != TASK_SM: return nil
  tag.claimed = true
  result = tag.reply
  tag.reply = nil
  if not smScanOwnerCurrent(tag.owner, tag.indication):
    if result != nil: ke_msg_free(keMsgHdrFromPayload(result))
    return nil
  if result != nil: smScanTagFor(keMsgHdrFromPayload(result)).published = true

proc smScanAcceptReply(reply: pointer; id: uint16): bool =
  if reply == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(reply)
  let tag = smScanTagFor(header)
  if tag == nil or tag.command or not tag.published or tag.claimed or
      tag.responseId != id or header.id != id or header.srcId != TASK_SCANU or
      header.destId != TASK_SM or header.paramLen != StatusCfmPayloadSize or
      not smScanOwnerCurrent(tag.owner, tag.indication): return false
  tag.claimed = true
  if statusCfmView(reply).status != 0:
    sm_connect_ind((if id == SCANU_START_CFM: WLAN_FW_SCAN_NO_BSSID_AND_CHANNEL.uint16
                    else: WLAN_FW_JOIN_NETWORK_FAILURE.uint16), 0xFFFF)
    return false
  true

proc smScanNeedsService(): bool =
  smScanLost.pending

proc smScanService() =
  let saved = irqSave()
  defer: irqRestore(saved)
  let lost = smScanLost
  smScanLost = default(SmScanLost)
  if lost.pending and smScanOwnerCurrent(lost.owner, lost.indication):
    sm_connect_ind(lost.status, 0xFFFF)
