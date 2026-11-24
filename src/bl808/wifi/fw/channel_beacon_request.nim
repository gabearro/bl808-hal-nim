# Beacon request identity lives after the wire payload in the same allocation.
type
  ChanBcnRequestTag = object
    next: ptr ChanBcnRequestTag
    header: ptr KeMsgHdr
    identity: MmVifIdentity
    lease: ChanCtxtLease
    request: MmRemainOnChannelReqPayload
    interval, resetEpoch: uint32
    published, claimed: bool

var
  chanBcnRequestTags {.wifiCtrl.}: ptr ChanBcnRequestTag
  chanBcnPendingRequest {.wifiCtrl.}: ptr ChanBcnRequestTag

proc chanBcnRequestTagFor(header: ptr KeMsgHdr): ptr ChanBcnRequestTag =
  var tag = chanBcnRequestTags
  while tag != nil:
    if tag.header == header: return tag
    tag = tag.next

proc chanBcnRequestReleasePending(tag: ptr ChanBcnRequestTag; clearFlag: bool) =
  if tag != nil and chanBcnPendingRequest == tag:
    chanBcnPendingRequest = nil
    if clearFlag:
      let env = chanEnvView()
      env.flags = env.flags and not 0x40'u8

proc chanBcnRequestCurrent(tag: ptr ChanBcnRequestTag): bool =
  if not mmStaOwnerCurrent(tag.identity) or
      not chanLeaseCurrent(tag.lease) or
      tag.identity.station >= STA_INFO_TAB_ENTRIES.uint8:
    return false
  let sta = staInfoForIdx(tag.identity.station)
  sta.valid != 0 and sta.instNbr == tag.identity.index and
    sta.initialRateConfig == tag.interval and
    chanCtxtForIdx(tag.lease.index).channel == tag.request.channel and
    chanEnvView().ctxtCount > 1

proc chanBcnRequestAllocate(identity: MmVifIdentity; lease: ChanCtxtLease;
                           channel: ChanCtxtDefView; interval, resetEpoch: uint32): pointer =
  const alignment = alignof(ChanBcnRequestTag).uint
  const extra = KeMsgTailSlack + (alignment - 1).uint32 + sizeof(ChanBcnRequestTag).uint32
  result = ke_msg_alloc(0x34, 0, 0, MmRemainOnChannelReqPayloadSize + extra)
  if result == nil: return
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(result)
  header.paramLen = MmRemainOnChannelReqPayloadSize
  let start = cast[uint](result) + MmRemainOnChannelReqPayloadSize.uint + KeMsgTailSlack.uint
  let tag = cast[ptr ChanBcnRequestTag]((start + alignment - 1) and not (alignment - 1))
  tag[] = default(ChanBcnRequestTag)
  tag.next = chanBcnRequestTags
  tag.header = header
  tag.identity = identity
  tag.lease = lease
  tag.interval = interval
  tag.resetEpoch = resetEpoch
  tag.request.vifIdx = identity.index
  tag.request.durationMs = (interval - 5000'u32) div 1000
  tag.request.channel = channel
  chanBcnRequestTags = tag

proc chanBcnRequestPrune() =
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = chanBcnPendingRequest
  if tag != nil and not tag.claimed and
      (not chanBcnRequestCurrent(tag) or (chanEnvView().flags and 0x40) == 0):
    chanBcnRequestReleasePending(tag, true)

proc chanBcnRequestWireCurrent(tag: ptr ChanBcnRequestTag): bool =
  let header = tag.header
  header.id == 0x34 and header.destId == 0 and header.srcId == 0 and
    header.paramLen == MmRemainOnChannelReqPayloadSize and
    equalMem(keMsgPayload(header), addr tag.request, sizeof(tag.request))

proc chanBcnRequestPublish(p: pointer): bool =
  if p == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  chanBcnRequestPrune()
  let tag = chanBcnRequestTagFor(keMsgHdrFromPayload(p))
  if tag == nil or tag.published or not chanBcnRequestCurrent(tag) or
      not chanBcnRequestWireCurrent(tag): return false
  let env = chanEnvView()
  if chanBcnPendingRequest != nil or (env.flags and 0x40) != 0 or env.ctxtCount < 2:
    return false
  tag.published = true
  chanBcnPendingRequest = tag
  env.flags = env.flags or 0x40
  true

proc chanBcnRequestAdmit(p: pointer): bool =
  if p == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = chanBcnRequestTagFor(keMsgHdrFromPayload(p))
  if tag == nil: return true
  if tag.claimed: return false
  result = tag.published and chanBcnPendingRequest == tag and
    (chanEnvView().flags and 0x40) != 0 and
    chanBcnRequestCurrent(tag) and chanBcnRequestWireCurrent(tag)
  if not result: chanBcnRequestReleasePending(tag, true)

proc chanBcnRequestClaim(p: pointer; taskId: uint8): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  if not chanBcnRequestAdmit(p): return false
  let tag = chanBcnRequestTagFor(keMsgHdrFromPayload(p))
  if tag != nil:
    if taskId != 0:
      chanBcnRequestReleasePending(tag, true)
      return false
    tag.claimed = true
  true

proc chanBcnRequestFinish(p: pointer; status: uint8) =
  if p == nil: return
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = chanBcnRequestTagFor(keMsgHdrFromPayload(p))
  if tag != nil and tag.claimed:
    # An accepted ROC owns the flag until its operation completes.
    chanBcnRequestReleasePending(tag, status != 0)

proc chanBcnRequestForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr chanBcnRequestTags
  while link[] != nil:
    let tag = link[]
    if tag.header == header:
      chanBcnRequestReleasePending(tag, true)
      link[] = tag.next
      return
    link = addr tag.next

proc chanBcnRequestReset() =
  let saved = irqSave()
  defer: irqRestore(saved)
  chanBcnRequestReleasePending(chanBcnPendingRequest, true)
