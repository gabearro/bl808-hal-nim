type
  SmBssTag = object
    next: ptr SmBssTag
    header: ptr KeMsgHdr
    serial: uint32
    index: uint8
    command: bool

  SmBssOperation = object
    owner: SmTxBuildContext
    serial: uint32
    step: int
    active, awaiting, replyIssued, lost: bool
    request, reply: pointer
    replies: array[9, pointer]

const
  SmBssRequests = [ME_SET_PS_DISABLE_REQ, MM_SET_BSSID_REQ, MM_SET_BASIC_RATES_REQ,
    MM_SET_BEACON_INT_REQ, MM_SET_EDCA_REQ, MM_SET_EDCA_REQ, MM_SET_EDCA_REQ,
    MM_SET_EDCA_REQ, ME_SET_ACTIVE_REQ]
  SmBssSources = [TASK_ME, TASK_MM, TASK_MM, TASK_MM, TASK_MM, TASK_MM,
    TASK_MM, TASK_MM, TASK_ME]
  SmBssLengths = [MeSetPsDisableReqPayloadSize, MmSetBssidReqPayloadSize,
    MmSetBasicRatesReqPayloadSize, MmSetBeaconIntReqPayloadSize,
    MmSetEdcaReqPayloadSize, MmSetEdcaReqPayloadSize, MmSetEdcaReqPayloadSize,
    MmSetEdcaReqPayloadSize, MeSetActiveReqPayloadSize]

var
  smBss {.wifiCtrl.}: SmBssOperation
  smBssSerial {.wifiCtrl.}: uint32
  smBssTags {.wifiCtrl.}: ptr SmBssTag

proc smBssTagFor(header: ptr KeMsgHdr): ptr SmBssTag =
  var tag = smBssTags
  while tag != nil:
    if tag.header == header: return tag
    tag = tag.next

proc smBssForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr smBssTags
  while link[] != nil:
    if link[].header == header:
      let payload = keMsgPayload(link[].header)
      link[] = link[].next
      if smBss.request == payload:
        smBss.request = nil
        if not smBss.replyIssued: smBss.lost = true
      if smBss.reply == payload:
        smBss.reply = nil
        smBss.lost = true
      return
    link = addr link[].next

proc smBssCurrent(serial: uint32): bool =
  smBss.active and not smBss.lost and smBss.serial == serial and
    smTxOwnerCurrent(smBss.owner)

proc smBssNewSerial(): uint32 =
  let saved = irqSave()
  defer: irqRestore(saved)
  inc smBssSerial
  smBssSerial

proc smBssAlloc(index: int; serial: uint32; reply: bool): pointer =
  let length = if reply: 0'u32 else: SmBssLengths[index]
  const alignment = alignof(SmBssTag).uint32
  let offset = (length + KeMsgTailSlack + alignment - 1) and not (alignment - 1)
  let id = SmBssRequests[index] + (if reply: 1'u16 else: 0'u16)
  let source = SmBssSources[index]
  result = ke_msg_try_alloc(id, (if reply: TASK_SM else: source),
    (if reply: source else: TASK_SM), offset + sizeof(SmBssTag).uint32)
  if result == nil: return
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(result)
  header.paramLen = length
  let tag = cast[ptr SmBssTag](cast[uint](result) + offset.uint)
  tag[] = SmBssTag(next: smBssTags, header: header, serial: serial,
    index: index.uint8, command: not reply)
  smBssTags = tag

proc smBssCancel() =
  let saved = irqSave()
  defer: irqRestore(saved)
  if not smBss.active: return
  let retired = smBss
  var pending = smEnvView().pendingBssParams
  smBss = default(SmBssOperation)
  co_list_init(addr smEnvView().pendingBssParams)
  # Published messages may already be executing. Only extract queued ones;
  # their tags remain valid until the normal consumer frees each allocation.
  if not smBssCancelControl(retired.request, retired.reply, retired.owner.identity.vif):
    meCancelQueuedPayload(retired.request)
    if retired.replyIssued: meCancelQueuedPayload(retired.reply)
  while pending.first != nil:
    ke_msg_free(co_list_pop_front(addr pending))
  for reply in retired.replies:
    if reply != nil: ke_msg_free(keMsgHdrFromPayload(reply))

proc smBssCanBegin(): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  if smBss.active and not smBssCurrent(smBss.serial): smBssCancel()
  not smBss.active and smEnvView().pendingBssParams.first == nil

proc smBssStart(owner: SmTxBuildContext; serial: uint32;
                replies: array[9, pointer]): bool =
  if smBss.active or not smTxOwnerCurrent(owner): return false
  smBss = SmBssOperation(owner: owner, serial: serial, replies: replies, active: true)
  true

proc smBssOwnsRequest(request: pointer): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  request != nil and smBssTagFor(keMsgHdrFromPayload(request)) != nil

proc smBssAdmitRequest(request: pointer): bool =
  if request == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = smBssTagFor(keMsgHdrFromPayload(request))
  if tag == nil: return true
  let current = smBssCurrent(tag.serial)
  result = tag.command and current and smBss.awaiting and
    request == smBss.request and tag.index.int == smBss.step
  if not current and smBss.active and smBss.serial == tag.serial:
    smBssCancel()

proc smBssAdmitControlReply(reply: pointer): bool =
  if reply == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let tag = smBssTagFor(keMsgHdrFromPayload(reply))
  if tag == nil: return true
  let current = smBssCurrent(tag.serial)
  result = not tag.command and current and smBss.awaiting and
    smBss.replyIssued and reply == smBss.reply and tag.index.int == smBss.step
  if not current and smBss.active and smBss.serial == tag.serial:
    smBssCancel()

proc smBssTakeReply(request: pointer; id: uint16; length: uint32): pointer =
  let saved = irqSave()
  defer: irqRestore(saved)
  if not smBssAdmitRequest(request) or not smBss.active or length != 0 or
      id != SmBssRequests[smBss.step] + 1 or smBss.replyIssued:
    return nil
  result = smBss.replies[smBss.step]
  smBss.replies[smBss.step] = nil
  smBss.replyIssued = result != nil

proc smBssSendNext() =
  let saved = irqSave()
  defer: irqRestore(saved)
  let serial = smBss.serial
  if not smBssCurrent(serial):
    smBssCancel()
    return
  if smBss.awaiting: return
  if smBss.step >= SmBssRequests.len: return
  let node = co_list_pop_front(addr smEnvView().pendingBssParams)
  if node == nil:
    smBssCancel()
    return
  let header = cast[ptr KeMsgHdr](node)
  let tag = smBssTagFor(header)
  if tag == nil or not tag.command or tag.serial != serial or
      tag.index.int != smBss.step or header.id != SmBssRequests[smBss.step] or
      header.paramLen != SmBssLengths[smBss.step] or header.srcId != TASK_SM or
      header.destId != SmBssSources[smBss.step]:
    smBssCancel()
    ke_msg_free(node)
    return
  smBss.request = keMsgPayload(header)
  smBss.reply = smBss.replies[smBss.step]
  smBss.replyIssued = false
  smBss.awaiting = true
  ke_msg_send(smBss.request)

proc smBssConsumeReply(reply: pointer): bool =
  if reply == nil: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(reply)
  let tag = smBssTagFor(header)
  if tag == nil or tag.command or not smBssCurrent(tag.serial) or
      not smBss.awaiting or not smBss.replyIssued or reply != smBss.reply or
      tag.index.int != smBss.step or header.id != SmBssRequests[smBss.step] + 1 or
      header.srcId != SmBssSources[smBss.step] or header.destId != TASK_SM or
      header.paramLen != 0:
    return false
  smBss.request = nil
  smBss.reply = nil
  smBss.awaiting = false
  smBss.replyIssued = false
  inc smBss.step
  if smBss.step == SmBssRequests.len: smBss.active = false
  true

proc smBssNeedsService(): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  smBss.active and not smBssCurrent(smBss.serial)

proc smBssService() =
  let saved = irqSave()
  defer: irqRestore(saved)
  if smBssNeedsService(): smBssCancel()
