type
  SmRspTimeoutIdentity = object
    owner: SmTxBuildContext
    serial: uint32
    # Zero is a response deadline; otherwise this is remaining comeback time + 1.
    continuationUs: uint64
    captured: bool
  SmRspTimeoutTag = object
    next: ptr SmRspTimeoutTag
    header: ptr KeMsgHdr
    identity: SmRspTimeoutIdentity
    consumed: bool

var
  smRspSerial {.wifiCtrl.}: uint32
  smRspIdentity {.wifiCtrl.}: SmRspTimeoutIdentity
  smRspEntry {.wifiCtrl.}: ptr KeTimerEntry
  smRspTags {.wifiCtrl.}: ptr SmRspTimeoutTag
  smRspRequeue {.wifiCtrl.}: int

const
  SmRspRequeuePopped = 1
  SmRspRequeueRetired = 2

proc smRspNextSerial(): uint32 =
  inc smRspSerial
  if smRspSerial == 0: inc smRspSerial
  smRspSerial

proc smRspTimerReset() =
  let saved = irqSave()
  defer: irqRestore(saved)
  discard smRspNextSerial()
  smRspIdentity = default(SmRspTimeoutIdentity)
  smRspEntry = nil

proc smRspTimeoutCurrent(identity: SmRspTimeoutIdentity): bool =
  identity.captured and identity.serial == smRspSerial and
    smTxSessionCurrent(identity.owner)

proc smRspTimerBegin(id: uint16; task: uint8; continuationUs: uint64): uint32 =
  if id != SM_RSP_TIMEOUT_IND or task != TASK_SM: return 0
  let saved = irqSave()
  defer: irqRestore(saved)
  result = smRspNextSerial()
  smRspEntry = nil
  smRspIdentity = SmRspTimeoutIdentity(serial: result, continuationUs: continuationUs)
  let connection = smEnvView().connectInfo
  if connection == nil: return
  let vifIndex = connectInfoView(connection).vifIdx
  if vifIndex >= MAX_VIFS.uint8: return
  let vif = vifChannelForIdx(vifIndex)
  let station = vif.staIdx
  if station >= STA_INFO_TAB_ENTRIES.uint8 and station != 0xFF: return
  let state = ke_state_get(TASK_SM)
  if state != SmAuthenticatingState and state != SmAssocRspState: return
  let owner = SmTxBuildContext(connection: connection, state: state,
    serial: smTxSerials[vifIndex], identity: TxSessionIdentity(captured: true,
      vif: vifIndex, station: station, vifEpoch: rxVifEpochs[vifIndex],
      stationEpoch: staDeleteEpoch(station), resetEpoch: txResetEpoch))
  smRspIdentity.owner = owner
  smRspIdentity.captured = smTxOwnerCurrent(owner)

proc smRspTimerAbort(serial: uint32) =
  let saved = irqSave()
  defer: irqRestore(saved)
  if serial != 0 and serial == smRspSerial: smRspTimerReset()

proc smRspTimerPublish(id: uint16; task: uint8; serial: uint32;
                       entry: ptr KeTimerEntry): bool =
  if id != SM_RSP_TIMEOUT_IND or task != TASK_SM: return true
  if serial != smRspSerial or not smRspTimeoutCurrent(smRspIdentity): return false
  smRspEntry = entry
  true

proc smRspTimerClear(id: uint16; task: uint8) =
  if id == SM_RSP_TIMEOUT_IND and task == TASK_SM: smRspTimerReset()

proc smRspTimerForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr smRspTags
  while link[] != nil:
    if link[].header == header:
      link[] = link[].next
      return
    link = addr link[].next

proc smRspOwnerCurrent(context: pointer): bool =
  smTxSessionCurrent(cast[ptr SmTxBuildContext](context)[])

proc smRspTimerSetComeback(owner: SmTxBuildContext; intervalTu: uint32): bool =
  if owner.state != SmAssocRspState or not smTxOwnerCurrent(owner): return false
  let duration = max(1'u64, intervalTu.uint64 * 1024)
  let chunk = min(duration, KE_TIMER_MAX_DELAY.uint64)
  var current = owner
  ke_timer_try_set(SM_RSP_TIMEOUT_IND, TASK_SM, chunk.uint32,
    smRspOwnerCurrent, addr current, duration - chunk + 1)

proc smRspTagAt(message: pointer): ptr SmRspTimeoutTag =
  # The BL808's 12-byte message header does not preserve 8-byte alignment.
  const mask = alignof(SmRspTimeoutTag).uint - 1
  let start = cast[uint](message) + KeMsgTailSlack.uint
  cast[ptr SmRspTimeoutTag]((start + mask) and not mask)

proc smRspTimerTakeRequeue(): int =
  ## Nonzero once after a dispatch that could not deliver its expiry:
  ## SmRspRequeuePopped while the kernel still holds the popped expiry, or
  ## SmRspRequeueRetired when a failed re-arm already retired it.
  result = smRspRequeue
  smRspRequeue = 0

proc smRspTimerDispatch(entry: ptr KeTimerEntry): bool =
  if entry.id != SM_RSP_TIMEOUT_IND or entry.taskId != TASK_SM: return false
  result = true
  var identity: SmRspTimeoutIdentity
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    if entry != smRspEntry or not smRspTimeoutCurrent(smRspIdentity): return
    identity = smRspIdentity
    smRspEntry = nil
  if identity.continuationUs != 0:
    var remaining = identity.continuationUs - 1
    let timeLeft = cast[int32](entry.time - macTimeNow())
    if timeLeft > 0:
      remaining += timeLeft.uint64
    elif timeLeft < 0:
      remaining -= min(remaining, (-timeLeft.int64).uint64)
    if remaining != 0:
      let saved = irqSave()
      defer: irqRestore(saved)
      if not smRspTimeoutCurrent(identity): return
      let chunk = min(remaining, KE_TIMER_MAX_DELAY.uint64)
      if not ke_timer_try_set(SM_RSP_TIMEOUT_IND, TASK_SM, chunk.uint32,
          smRspOwnerCurrent, addr identity.owner, remaining - chunk + 1) and
          smTxSessionCurrent(identity.owner):
        # No memory for the next chunk. The failed re-arm reset this deadline's
        # identity and retired the popped expiry; restore both and keep the
        # same entry as the deadline.
        identity.serial = smRspSerial
        smRspIdentity = identity
        smRspEntry = entry
        smRspRequeue = SmRspRequeueRetired
      return
  # The timer's connection identity is copied before the message allocator can
  # reenter. The frame used to arm it may have completed in the meantime.
  const alignment = alignof(SmRspTimeoutTag).uint32
  const extra = KeMsgTailSlack + alignment - 1
  let message = ke_msg_try_alloc(SM_RSP_TIMEOUT_IND, TASK_SM, 0xFF,
    extra + sizeof(SmRspTimeoutTag).uint32)
  let saved = irqSave()
  defer: irqRestore(saved)
  if not smRspTimeoutCurrent(identity):
    if message != nil: ke_msg_free(keMsgHdrFromPayload(message))
    return
  if message == nil:
    # No memory for the expiry message. The attempt still needs its deadline,
    # so the kernel puts this entry back instead of freeing it.
    smRspEntry = entry
    smRspRequeue = SmRspRequeuePopped
    return
  let header = keMsgHdrFromPayload(message)
  header.paramLen = 0
  let tag = smRspTagAt(message)
  tag[] = SmRspTimeoutTag(next: smRspTags, header: header, identity: identity)
  smRspTags = tag
  ke_msg_send(message)

proc smRspTimeoutCapture(message: pointer): SmRspTimeoutIdentity =
  if message == nil: return
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = keMsgHdrFromPayload(message)
  var tag = smRspTags
  while tag != nil:
    if tag.header == header:
      if tag.consumed or header.id != SM_RSP_TIMEOUT_IND or
          header.destId != TASK_SM or header.srcId != 0xFF or header.paramLen != 0 or
          not smRspTimeoutCurrent(tag.identity):
        return
      tag.consumed = true
      return tag.identity
    tag = tag.next
