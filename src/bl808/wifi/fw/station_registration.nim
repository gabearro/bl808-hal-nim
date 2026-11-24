# Tags live beyond the public payload and are retired with their message.
type
  SmRegistrationTag = object
    next: ptr SmRegistrationTag
    header: ptr KeMsgHdr
    owner: SmTxBuildContext
    indication, reply: pointer
    response: MmStaAddCfmPayload
    channel: ChanCtxtLease
    stationEpochs: array[STA_MGMT_FREE_STAS, uint32]
    stationEpoch: uint32
    station: uint8
    command, published, processing, finished, claimed, handedOff: bool
  SmRegistrationLoss = object
    owner: SmTxBuildContext
    indication: pointer
    pending: bool
  SmRegistrationRetired = object
    epoch: uint32
    vif: uint8
    pending: bool

var
  smRegistrationTags {.wifiCtrl.}: ptr SmRegistrationTag
  smRegistrationLoss {.wifiCtrl.}: SmRegistrationLoss
  smRegistrationRetired {.wifiCtrl.}: array[STA_MGMT_FREE_STAS, SmRegistrationRetired]
  smRegistrationChannels {.wifiCtrl.}: array[MAX_CHAN_CTXT * (MAX_VIFS + 1), ChanCtxtLease]

proc smRegistrationTagFor(header: ptr KeMsgHdr): ptr SmRegistrationTag =
  var tag = smRegistrationTags
  while tag != nil:
    if tag.header == header: return tag
    tag = tag.next

proc smRegistrationChannelCurrent(tag: ptr SmRegistrationTag): bool =
  not tag.channel.held or chanLeaseCurrent(tag.channel)

proc smRegistrationPreserveAcrossChannelReset(previous: uint32) =
  # Linking a join channel can queue its idle request before MM_STA_ADD_REQ.
  # The successful TX drain retires frames, not this pending control exchange.
  var tag = smRegistrationTags
  while tag != nil:
    if tag.published and not tag.processing and not tag.claimed and
        tag.owner.identity.resetEpoch == previous and tag.channel.linked and
        chanLeaseCurrent(tag.channel):
      var owner = tag.owner
      owner.identity.resetEpoch = txResetEpoch
      if smScanOwnerCurrent(owner, tag.indication):
        tag.owner = owner
        if tag.command and tag.reply != nil:
          let reply = smRegistrationTagFor(keMsgHdrFromPayload(tag.reply))
          if reply != nil:
            reply.owner = owner
    tag = tag.next

proc smRegistrationRememberLoss(tag: ptr SmRegistrationTag) =
  var owner = tag.owner
  # A failure still belongs to the connection after its station is retired.
  owner.identity.station = 0xFF
  owner.identity.stationEpoch = staDeleteEpoch(0xFF)
  if smScanOwnerCurrent(owner, tag.indication):
    smRegistrationLoss = SmRegistrationLoss(owner: owner,
      indication: tag.indication, pending: true)

proc smRegistrationForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr smRegistrationTags
  while link[] != nil:
    if link[].header == header:
      let tag = link[]
      link[] = tag.next
      let reply = tag.reply
      tag.reply = nil
      if tag.command:
        if tag.published and not tag.finished: smRegistrationRememberLoss(tag)
      elif not tag.handedOff:
        if tag.station < STA_MGMT_FREE_STAS.uint8 and
            staDeleteIsCurrent(tag.station, tag.stationEpoch) and
            staInfoForIdx(tag.station).instNbr == tag.owner.identity.vif:
          smRegistrationRetired[tag.station] = SmRegistrationRetired(
            epoch: tag.stationEpoch, vif: tag.owner.identity.vif, pending: true)
        if tag.published: smRegistrationRememberLoss(tag)
      if not tag.handedOff and chanLeaseCurrent(tag.channel):
        let channel = tag.channel
        let slot = channel.index.int * (MAX_VIFS + 1) +
          (if channel.linked: channel.vif.int else: MAX_VIFS)
        smRegistrationChannels[slot] = channel
      if reply != nil: ke_msg_free(keMsgHdrFromPayload(reply))
      return
    link = addr link[].next

proc smRegistrationAllocMessage(command: bool; owner: SmTxBuildContext;
                                 indication: pointer): pointer =
  let length = if command: MmStaAddReqPayloadSize else: MmStaAddCfmPayloadSize
  const alignment = alignof(SmRegistrationTag).uint
  let extra = KeMsgTailSlack + (alignment - 1).uint32 + sizeof(SmRegistrationTag).uint32
  result = ke_msg_try_alloc((if command: MM_STA_ADD_REQ else: MM_STA_ADD_CFM),
    (if command: TASK_MM else: TASK_SM), (if command: TASK_SM else: TASK_MM), length + extra)
  if result == nil: return
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(result)
  header.paramLen = length
  let start = cast[uint](result) + length.uint + KeMsgTailSlack.uint
  let tag = cast[ptr SmRegistrationTag]((start + alignment - 1) and not (alignment - 1))
  tag[] = SmRegistrationTag(next: smRegistrationTags, header: header,
    owner: owner, indication: indication, command: command, station: 0xFF)
  smRegistrationTags = tag

proc smRegistrationAllocate(owner: SmTxBuildContext; indication: pointer): pointer =
  if not smScanOwnerCurrent(owner, indication): return nil
  var expected = owner
  expected.state = SmAddingChanState
  result = smRegistrationAllocMessage(true, expected, indication)
  if result == nil: return
  if not smScanOwnerCurrent(owner, indication):
    ke_msg_free(keMsgHdrFromPayload(result))
    return nil
  let reply = smRegistrationAllocMessage(false, expected, indication)
  smRegistrationTagFor(keMsgHdrFromPayload(result)).reply = reply
  if reply == nil or not smScanOwnerCurrent(owner, indication):
    ke_msg_free(keMsgHdrFromPayload(result))
    return nil

proc smRegistrationOwnChannel(request: pointer; lease: var ChanCtxtLease): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = smRegistrationTagFor(keMsgHdrFromPayload(request))
  if tag == nil or not tag.command or tag.published or tag.channel.held or
      not lease.linked or lease.vif != tag.owner.identity.vif or
      not chanLeaseCurrent(lease): return false
  tag.channel = lease
  lease = default(ChanCtxtLease)
  true

proc smRegistrationPublish(request: pointer): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = smRegistrationTagFor(keMsgHdrFromPayload(request))
  if tag == nil or not tag.command or not smScanOwnerCurrent(tag.owner, tag.indication):
    return false
  tag.published = true
  true

proc smRegistrationAdmitRequest(request: pointer): bool =
  if request == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(request)
  let tag = smRegistrationTagFor(header)
  if tag == nil: return true
  tag.command and tag.published and not tag.finished and
    header.id == MM_STA_ADD_REQ and header.srcId == TASK_SM and
    header.destId == TASK_MM and header.paramLen == MmStaAddReqPayloadSize and
    cast[ptr MmStaAddReqPayload](request).vifIdx == tag.owner.identity.vif and
    smScanOwnerCurrent(tag.owner, tag.indication) and smRegistrationChannelCurrent(tag)

proc smRegistrationTakeReply(request: pointer): pointer =
  if request == nil: return nil
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(request)
  let tag = smRegistrationTagFor(header)
  if tag == nil:
    return ke_msg_alloc(MM_STA_ADD_CFM, header.srcId, header.destId,
                        MmStaAddCfmPayloadSize)
  if not smRegistrationAdmitRequest(request) or tag.processing: return nil
  tag.processing = true
  for index in 0 ..< STA_MGMT_FREE_STAS:
    tag.stationEpochs[index] = staDeleteEpoch(index.uint8)
  result = tag.reply
  tag.reply = nil

proc smRegistrationComplete(request, reply: pointer): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = smRegistrationTagFor(keMsgHdrFromPayload(request))
  if tag == nil: return true
  if not tag.command or not tag.processing or tag.finished: return false
  tag.finished = true
  let responseTag = smRegistrationTagFor(keMsgHdrFromPayload(reply))
  if responseTag == nil or responseTag.command: return false
  responseTag.channel = tag.channel
  tag.channel = default(ChanCtxtLease)
  let response = cast[ptr MmStaAddCfmPayload](reply)
  let index = response.staIdx
  if response.status == 0:
    if index < STA_MGMT_FREE_STAS.uint8 and
        staDeleteIsCurrent(index, tag.stationEpochs[index]) and
        staInfoForIdx(index).instNbr == tag.owner.identity.vif:
      responseTag.station = index
      responseTag.stationEpoch = tag.stationEpochs[index]
      discard smTxBindStation(responseTag.owner, index)
    else:
      response[] = MmStaAddCfmPayload(status: 1, staIdx: 0xFF, hwStaIdx: 0xFF)
  if not smScanOwnerCurrent(tag.owner, tag.indication) or
      not smRegistrationChannelCurrent(responseTag): return false
  responseTag.response = response[]
  responseTag.published = true
  true

proc smRegistrationClaim(reply: pointer; owner: var SmTxBuildContext;
                          indication: var pointer): bool =
  if reply == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(reply)
  let tag = smRegistrationTagFor(header)
  if tag == nil or tag.command or not tag.published or tag.claimed or
      header.id != MM_STA_ADD_CFM or header.srcId != TASK_MM or
      header.destId != TASK_SM or header.paramLen != MmStaAddCfmPayloadSize or
      cast[ptr MmStaAddCfmPayload](reply)[] != tag.response or
      not smScanOwnerCurrent(tag.owner, tag.indication) or
      not smRegistrationChannelCurrent(tag): return false
  tag.claimed = true
  if tag.response.status != 0:
    tag.handedOff = true
    tag.channel = default(ChanCtxtLease)
    sm_connect_ind(15, 0xFFFF)
    return false
  if tag.station >= STA_MGMT_FREE_STAS.uint8 or
      not staDeleteIsCurrent(tag.station, tag.stationEpoch): return false
  owner = tag.owner
  indication = tag.indication
  true

proc smRegistrationHandoff(reply: pointer): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = smRegistrationTagFor(keMsgHdrFromPayload(reply))
  if tag == nil or not tag.claimed or not smScanOwnerCurrent(tag.owner, tag.indication) or
      not smRegistrationChannelCurrent(tag):
    return false
  tag.handedOff = true
  tag.channel = default(ChanCtxtLease)
  true

proc smRegistrationNeedsService(): bool =
  if smRegistrationLoss.pending: return true
  for retired in smRegistrationRetired:
    if retired.pending: return true
  for channel in smRegistrationChannels:
    if channel.held: return true
  false

proc smRegistrationService() =
  let saved = irqSave()
  defer: irqRestore(saved)
  let loss = smRegistrationLoss
  let retired = smRegistrationRetired
  var channels = smRegistrationChannels
  smRegistrationLoss = default(SmRegistrationLoss)
  smRegistrationRetired = default(typeof(smRegistrationRetired))
  smRegistrationChannels = default(typeof(smRegistrationChannels))
  for index, entry in retired:
    if entry.pending and staDeleteIsCurrent(index.uint8, entry.epoch) and
        staInfoForIdx(index.uint8).instNbr == entry.vif:
      mm_sta_del(index.uint8)
  for channel in channels.mitems: chanLeaseRelease(channel)
  if loss.pending and smScanOwnerCurrent(loss.owner, loss.indication):
    sm_connect_ind(15, 0xFFFF)
