type
  ChanSwitchOwners = object
    linked: set[range[0 .. MAX_VIFS - 1]]
    bindings, vifs: array[MAX_VIFS, uint32]
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
    owners: ChanSwitchOwners
    published, claimed: bool

var
  chanSwitchTags {.wifiCtrl.}: ptr ChanSwitchTag
  chanSwitchActive {.wifiCtrl.}: ptr ChanSwitchTag
  chanSwitchCallback {.wifiCtrl.}: ptr ChanSwitchTag
  chanSwitchIdleHome: tuple[context: ChanSwitchContext; owners: ChanSwitchOwners]

proc chanSwitchOwners(context: ChanSwitchContext): ChanSwitchOwners =
  if not context.captured or context.index >= 3: return
  for i in 0 ..< MAX_VIFS:
    if vifChannelForIdx(i.uint8).chanCtxt == context.target:
      result.linked.incl(i)
      result.bindings[i] = chanCtxtLinkEpochs[i]
      result.vifs[i] = rxVifEpochs[i]

proc chanSwitchOwnersCurrent(owners: ChanSwitchOwners; target: pointer): bool =
  for i in owners.linked:
    if vifChannelForIdx(i.uint8).chanCtxt != target or
        chanCtxtLinkEpochs[i] != owners.bindings[i] or rxVifEpochs[i] != owners.vifs[i]:
      return false
  true

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

proc chanSwitchContextCurrent(context: ChanSwitchContext; checkDefinition = true): bool =
  if not context.captured or context.index >= chanCtxtEpochs.len.uint8: return false
  let ctxt = chanCtxtForIdx(context.index)
  context.target == cast[pointer](ctxt) and
    ctxt.contextIndexOrMarker == context.index and
    chanCtxtEpochs[context.index] == context.epoch and
    (not checkDefinition or ctxt.channel == context.definition)

proc chanSwitchTagFor(header: ptr KeMsgHdr): ptr ChanSwitchTag =
  var tag = chanSwitchTags
  while tag != nil:
    if tag.header == header: return tag
    tag = tag.next

proc chanSwitchDropState(target: pointer;
                         context = default(ChanSwitchContext);
                         owners = default(ChanSwitchOwners)) =
  let env = chanEnvView()
  if target != nil and env.scheduledCtxt == target:
    env.scheduledCtxt = nil
    env.switchPending = 0
    env.scanDelayCount = 0
    env.connlessDelayCount = 0
    if chanSwitchOwnersCurrent(owners, target) and
        chanSwitchContextCurrent(context, checkDefinition = owners.linked == {}):
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
        chanSwitchDropState(tag.destination.target, tag.destination, tag.owners)
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
    chanSwitchDropState(tag.destination.target, tag.destination, tag.owners)
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
  let owners = chanSwitchOwners(context)
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
  tag[] = ChanSwitchTag(next: chanSwitchTags, header: header, destination: context, owners: owners)
  chanSwitchTags = tag

proc chanSwitchPublish(request: pointer): bool =
  let tag = chanSwitchTagFor(keMsgHdrFromPayload(request))
  if tag == nil or chanSwitchActive != nil or
      not chanSwitchContextCurrent(tag.destination) or
      not chanSwitchOwnersCurrent(tag.owners, tag.destination.target) or
      chanEnvView().scheduledCtxt != tag.destination.target: return false
  tag.published = true
  chanProtectionInvalidate()
  chanSwitchActive = tag
  true

proc chanSwitchAdmit(request: pointer): bool =
  if request == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = chanSwitchTagFor(keMsgHdrFromPayload(request))
  if tag == nil: return true
  let header = tag.header
  if tag != chanSwitchActive or not tag.published or tag.claimed or
      header.id != MM_FORCE_IDLE_REQ_MSG or header.destId != TASK_MM or
      header.srcId != TASK_NONE or header.paramLen != 4 or
      cast[ptr pointer](request)[] != cast[pointer](chan_goto_idle_cb) or
      chanEnvView().scheduledCtxt != tag.destination.target or
      not chanSwitchOwnersCurrent(tag.owners, tag.destination.target): return false
  if chanSwitchContextCurrent(tag.destination): return true
  # MM can update a linked home channel in place while its idle request waits.
  # Retain the allocation, bindings, and original status for rollback.
  if tag.owners.linked == {} or not chanSwitchContextCurrent(tag.destination, checkDefinition = false) or
      chanCtxtAt(tag.destination.target).linkCount == 0:
    return false
  tag.destination.definition = chanCtxtAt(tag.destination.target).channel
  true

proc chanSwitchIdleHomeCurrent(): bool =
  let env = chanEnvView()
  let home = chanSwitchIdleHome.context
  env.currentCtxt == home.target and env.scheduledCtxt == nil and chanSwitchActive == nil and
    chanSwitchContextCurrent(home) and chanSwitchOwnersCurrent(chanSwitchIdleHome.owners, home.target)

proc chanSwitchTrackIdle(request: pointer; state: uint16): uint32 =
  result = mmConfigIdle.epoch
  if state != MM_ACTIVE_STATE.uint16: return
  let header = keMsgHdrFromPayload(request)
  let tag = chanSwitchTagFor(header)
  if tag == nil or tag != chanSwitchActive: return
  let home = chanSwitchCapture(chanEnvView().currentCtxt)
  let owners = chanSwitchOwners(home)
  if owners.linked == {}: return
  let mode = regRead(MACHW_STATE_CNTRL_REG) and 0xF'u32
  if mode == 0 or mmConfigIdle.epoch != result or not chanSwitchAdmit(request): return
  chanSwitchIdleHome = (home, owners)
  result = mmConfigTrackIdle(header, mode.uint8, state.uint8, chanSwitchIdleHomeCurrent)

proc chanSwitchCallbackCurrent(): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = chanSwitchCallback
  chanProtectionCallbackCurrent() and (tag == nil or (tag == chanSwitchActive and
    chanSwitchContextCurrent(tag.destination) and
    chanSwitchOwnersCurrent(tag.owners, tag.destination.target) and
    (tag.source.target == nil or chanSwitchContextCurrent(tag.source))))

proc chanSwitchSelectTarget(target: pointer): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  if chanSwitchCallback == nil: return chanProtectionSelectTarget(target)
  let tag = chanSwitchCallback
  if tag != chanSwitchActive or not chanSwitchContextCurrent(tag.destination) or
      not chanSwitchOwnersCurrent(tag.owners, tag.destination.target) or
      (tag.source.target != nil and not chanSwitchContextCurrent(tag.source)): return false
  let destination = chanSwitchCapture(target)
  if not destination.captured: return false
  if not chanProtectionSelectTarget(target): return false
  if target != tag.destination.target:
    tag.destination = destination
    tag.owners = chanSwitchOwners(destination)
  true

proc chanSwitchInvoke(request: pointer): bool =
  var tag, previous: ptr ChanSwitchTag
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    tag = chanSwitchTagFor(keMsgHdrFromPayload(request))
    if tag == nil: return false
    if not chanSwitchAdmit(request): return true
    tag.source = chanSwitchCapture(chanEnvView().currentCtxt)
    if chanEnvView().currentCtxt != nil and not tag.source.captured: return true
    tag.claimed = true
    previous = chanSwitchCallback
    chanSwitchCallback = tag
  defer:
    let saved = irqSave()
    defer: irqRestore(saved)
    let current = chanSwitchCallbackCurrent()
    chanSwitchCallback = previous
    if chanSwitchActive == tag:
      let env = chanEnvView()
      # Only protection frames may legitimately leave a claimed switch pending.
      if not current or (env.scheduledCtxt == tag.destination.target and
          env.scanDelayCount == 0 and env.connlessDelayCount == 0):
        chanSwitchCancel(tag.destination.target)
      else:
        chanSwitchActive = nil
  if chanSwitchCallbackCurrent(): chan_goto_idle_cb()
  true
