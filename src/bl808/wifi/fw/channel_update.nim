# Request identity is private to the allocation, not part of the MM payload.
type
  ChanUpdateTag = object
    next: ptr ChanUpdateTag
    header: ptr KeMsgHdr
    request: MmChanCtxtUpdatePayload
    contextEpoch, vifEpoch, bindingEpoch, wireLength: uint32
    source, vifIndex: uint8
    captured, valid, vifBound: bool

var chanUpdateTags {.wifiCtrl.}: ptr ChanUpdateTag

proc chanUpdateStorageLength(id: uint16; destination: uint8; length: uint32): uint32 =
  if id != MM_CHAN_CTXT_UPDATE_REQ or destination != TASK_MM:
    return length
  const alignment = alignof(ChanUpdateTag).uint32
  const extra = KeMsgTailSlack + alignment - 1 + sizeof(ChanUpdateTag).uint32
  if length > high(uint32) - extra:
    return high(uint32)
  ((length + KeMsgTailSlack + alignment - 1) and not (alignment - 1)) +
    sizeof(ChanUpdateTag).uint32

proc chanUpdateRegister(header: ptr KeMsgHdr) =
  if header.id != MM_CHAN_CTXT_UPDATE_REQ or header.destId != TASK_MM:
    return
  const alignment = alignof(ChanUpdateTag).uint32
  let offset = (header.paramLen + KeMsgTailSlack + alignment - 1) and not (alignment - 1)
  let tag = cast[ptr ChanUpdateTag](cast[uint](keMsgPayload(header)) + offset.uint)
  let saved = irqSave()
  tag[] = ChanUpdateTag(next: chanUpdateTags, header: header)
  chanUpdateTags = tag
  irqRestore(saved)

proc chanUpdateTagFor(header: ptr KeMsgHdr): ptr ChanUpdateTag =
  var tag = chanUpdateTags
  while tag != nil:
    if tag.header == header:
      return tag
    tag = tag.next

proc chanUpdateForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr chanUpdateTags
  while link[] != nil:
    if link[].header == header:
      link[] = link[].next
      return
    link = addr link[].next

proc chanUpdateCaptureMessage(header: ptr KeMsgHdr) =
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = chanUpdateTagFor(header)
  if tag == nil or tag.captured:
    return
  tag.captured = true
  if header.id != MM_CHAN_CTXT_UPDATE_REQ or header.destId != TASK_MM or
      header.paramLen < MmChanCtxtUpdatePayloadSize:
    return
  tag.request = cast[ptr MmChanCtxtUpdatePayload](keMsgPayload(header))[]
  let index = tag.request.ctxtIdx
  if index >= MAX_CHAN_CTXT.uint8 or chanCtxtForIdx(index).contextIndexOrMarker != index:
    return
  tag.contextEpoch = chanCtxtEpochs[index]
  tag.source = header.srcId
  tag.wireLength = header.paramLen
  tag.valid = true

proc chanUpdateAdmit(request: pointer): bool =
  if request == nil:
    return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(request)
  let tag = chanUpdateTagFor(header)
  # Direct nonqueued callers do not have allocation metadata.
  if tag == nil:
    return true
  if not tag.captured or not tag.valid or header.id != MM_CHAN_CTXT_UPDATE_REQ or
      header.destId != TASK_MM or header.srcId != tag.source or
      header.paramLen != tag.wireLength:
    return false
  let index = tag.request.ctxtIdx
  if cast[ptr MmChanCtxtUpdatePayload](request)[] != tag.request or
      chanCtxtEpochs[index] != tag.contextEpoch or
      chanCtxtForIdx(index).contextIndexOrMarker != index:
    return false
  not tag.vifBound or (rxVifEpochs[tag.vifIndex] == tag.vifEpoch and
    chanCtxtLinkEpochs[tag.vifIndex] == tag.bindingEpoch and
    vifChannelForIdx(tag.vifIndex).chanCtxt == cast[pointer](chanCtxtForIdx(index)))

proc chanUpdateBindVif(request: pointer; vifIndex: uint8): bool =
  if request == nil or vifIndex >= MAX_VIFS.uint8:
    return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(request)
  chanUpdateCaptureMessage(header)
  let tag = chanUpdateTagFor(header)
  if tag == nil or not tag.valid:
    return false
  if tag.vifBound:
    return tag.vifIndex == vifIndex and chanUpdateAdmit(request)
  let vif = vifChannelForIdx(vifIndex)
  if vif.vifIdx != vifIndex or
      vif.chanCtxt != cast[pointer](chanCtxtForIdx(tag.request.ctxtIdx)):
    return false
  tag.vifIndex = vifIndex
  tag.vifEpoch = rxVifEpochs[vifIndex]
  tag.bindingEpoch = chanCtxtLinkEpochs[vifIndex]
  tag.vifBound = true
  chanUpdateAdmit(request)
