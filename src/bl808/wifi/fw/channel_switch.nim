type
  ChanSwitchContext = object
    target: pointer
    definition: ChanCtxtDefView
    epoch: uint32
    index: uint8
    status: uint8
    captured: bool
  ChanSwitchTag = object
    next: ptr ChanSwitchTag
    header: ptr KeMsgHdr
    destination, source: ChanSwitchContext
    published, claimed: bool

var
  chanSwitchTags {.wifiCtrl.}: ptr ChanSwitchTag
  chanSwitchActive {.wifiCtrl.}: ptr ChanSwitchTag
  chanSwitchCallback {.wifiCtrl.}: ptr ChanSwitchTag

proc chanSwitchCapture(target: pointer): ChanSwitchContext =
  if target == nil: return
  for index in 0'u8 ..< 5:
    if target != cast[pointer](chanCtxtForIdx(index)): continue
    let ctxt = chanCtxtForIdx(index)
    if ctxt.contextIndexOrMarker != index: return
    result = ChanSwitchContext(target: target, definition: ctxt.channel,
      index: index, status: ctxt.status, captured: true)
    result.epoch = chanCtxtEpochs[index]
    return

proc chanSwitchContextCurrent(context: ChanSwitchContext): bool =
  if not context.captured or context.index >= chanCtxtEpochs.len.uint8: return false
  let ctxt = chanCtxtForIdx(context.index)
  context.target == cast[pointer](ctxt) and
    ctxt.contextIndexOrMarker == context.index and
    chanCtxtEpochs[context.index] == context.epoch and
    ctxt.channel.band == context.definition.band and
    ctxt.channel.chanType == context.definition.chanType and
    ctxt.channel.primFreq == context.definition.primFreq and
    ctxt.channel.centerFreq1 == context.definition.centerFreq1 and
    ctxt.channel.centerFreq2 == context.definition.centerFreq2

proc chanSwitchTagFor(header: ptr KeMsgHdr): ptr ChanSwitchTag =
  var tag = chanSwitchTags
  while tag != nil:
    if tag.header == header: return tag
    tag = tag.next

proc chanSwitchDropState(target: pointer;
                         context = default(ChanSwitchContext)) =
  let env = chanEnvView()
  if target != nil and env.scheduledCtxt == target:
    env.scheduledCtxt = nil
    env.switchPending = 0
    env.scanDelayCount = 0
    env.connlessDelayCount = 0
    if chanSwitchContextCurrent(context):
      chanCtxtAt(target).status = context.status
    mm_timer_clear(chanCtxtOpTimer())

proc chanSwitchForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr chanSwitchTags
  while link[] != nil:
    if link[].header == header:
      let tag = link[]
      link[] = tag.next
      if chanSwitchActive == tag:
        chanSwitchActive = nil
        chanSwitchDropState(tag.destination.target, tag.destination)
      return
    link = addr link[].next

proc chanSwitchCancel(target: pointer = nil) =
  let saved = irqSave()
  defer: irqRestore(saved)
  let protectionTarget = chanProtectionCancel(target)
  let tag = chanSwitchActive
  if tag != nil and (target == nil or tag.destination.target == target or
      (tag.claimed and tag.source.target == target)):
    let request = keMsgPayload(tag.header)
    chanSwitchActive = nil
    chanSwitchDropState(tag.destination.target, tag.destination)
    meCancelQueuedPayload(request)
  elif protectionTarget != nil:
    chanSwitchDropState(protectionTarget)
  elif target != nil:
    chanSwitchDropState(target)
  else:
    chanSwitchDropState(chanEnvView().scheduledCtxt)

proc chanSwitchRetire(target: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  if chanEnvView().currentCtxt == target: chanEnvView().currentCtxt = nil
  chanSwitchCancel(target)

proc chanSwitchAllocate(target: pointer): pointer =
  let context = chanSwitchCapture(target)
  if not context.captured: return nil
  const alignment = alignof(ChanSwitchTag).uint
  let extra = KeMsgTailSlack + (alignment - 1).uint32 + sizeof(ChanSwitchTag).uint32
  result = ke_msg_try_alloc(MM_FORCE_IDLE_REQ_MSG, TASK_MM, TASK_NONE, 4 + extra)
  if result == nil: return
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(result)
  header.paramLen = 4
  cast[ptr pointer](result)[] = cast[pointer](chan_goto_idle_cb)
  let start = cast[uint](result) + 4 + KeMsgTailSlack.uint
  let tag = cast[ptr ChanSwitchTag]((start + alignment - 1) and not (alignment - 1))
  tag[] = ChanSwitchTag(next: chanSwitchTags, header: header, destination: context)
  chanSwitchTags = tag

proc chanSwitchPublish(request: pointer): bool =
  let tag = chanSwitchTagFor(keMsgHdrFromPayload(request))
  if tag == nil or chanSwitchActive != nil or
      not chanSwitchContextCurrent(tag.destination) or
      chanEnvView().scheduledCtxt != tag.destination.target: return false
  tag.published = true
  chanProtectionInvalidate()
  chanSwitchActive = tag
  true

proc chanSwitchAdmit(request: pointer): bool =
  if request == nil: return false
  let tag = chanSwitchTagFor(keMsgHdrFromPayload(request))
  if tag == nil: return true
  let header = tag.header
  tag == chanSwitchActive and tag.published and not tag.claimed and
    header.id == MM_FORCE_IDLE_REQ_MSG and header.destId == TASK_MM and
    header.srcId == TASK_NONE and header.paramLen == 4 and
    cast[ptr pointer](request)[] == cast[pointer](chan_goto_idle_cb) and
    chanEnvView().scheduledCtxt == tag.destination.target and
    chanSwitchContextCurrent(tag.destination)

proc chanSwitchCallbackCurrent(): bool =
  let tag = chanSwitchCallback
  chanProtectionCallbackCurrent() and (tag == nil or (tag == chanSwitchActive and
    chanSwitchContextCurrent(tag.destination) and
    (tag.source.target == nil or chanSwitchContextCurrent(tag.source))))

proc chanSwitchSelectTarget(target: pointer): bool =
  if chanSwitchCallback == nil: return chanProtectionSelectTarget(target)
  let tag = chanSwitchCallback
  if tag != chanSwitchActive or not chanSwitchContextCurrent(tag.destination) or
      (tag.source.target != nil and not chanSwitchContextCurrent(tag.source)): return false
  let destination = chanSwitchCapture(target)
  if not destination.captured: return false
  if not chanProtectionSelectTarget(target): return false
  tag.destination = destination
  true

proc chanSwitchInvoke(request: pointer): bool =
  let tag = chanSwitchTagFor(keMsgHdrFromPayload(request))
  if tag == nil: return false
  if not chanSwitchAdmit(request): return true
  tag.source = chanSwitchCapture(chanEnvView().currentCtxt)
  if chanEnvView().currentCtxt != nil and not tag.source.captured: return true
  tag.claimed = true
  let previous = chanSwitchCallback
  chanSwitchCallback = tag
  defer:
    let current = chanSwitchCallbackCurrent()
    chanSwitchCallback = previous
    if chanSwitchActive == tag:
      if current: chanSwitchActive = nil
      else: chanSwitchCancel(tag.destination.target)
  if chanSwitchCallbackCurrent(): chan_goto_idle_cb()
  true
