type
  SmDeferredOwner = object
    connection, channel: pointer
    serial, vifEpoch, linkEpoch: uint32
    entryState: uint16
    vifIndex: uint8
  SmDeferredLocation = enum
    smDeferredBuilding, smDeferredParked, smDeferredQueued,
    smDeferredExecuting, smDeferredRetired
  SmDeferredTag = object
    next: ptr SmDeferredTag
    header: ptr KeMsgHdr
    owner: SmDeferredOwner
    state, sequence: uint16
    hasChallenge: bool
    location: SmDeferredLocation

var
  smDeferredSerial {.wifiCtrl.}: uint32
  smDeferredTags {.wifiCtrl.}: ptr SmDeferredTag

proc smDeferredTagFor(payload: pointer): ptr SmDeferredTag =
  var tag = smDeferredTags
  while tag != nil:
    if keMsgPayload(tag.header) == payload: return tag
    tag = tag.next

proc smDeferredForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr smDeferredTags
  while link[] != nil:
    if link[].header == header:
      if chanEnvView().deferredMsg == keMsgPayload(link[].header):
        chanEnvView().deferredMsg = nil
      link[] = link[].next
      return
    link = addr link[].next

proc smDeferredAttemptAt(owner: SmDeferredOwner; state: uint16): bool =
  owner.serial == smDeferredSerial and owner.connection != nil and
    smEnvView().connectInfo == owner.connection and
    owner.vifIndex < MAX_VIFS.uint8 and
    rxVifEpochs[owner.vifIndex] == owner.vifEpoch and
    vifChannelForIdx(owner.vifIndex).vifIdx == owner.vifIndex and
    vifChannelForIdx(owner.vifIndex).vifType == VIF_TYPE_STA and
    ke_state_get(TASK_SM) == state

proc smDeferredBindingCurrent(owner: SmDeferredOwner): bool =
  owner.channel != nil and chanCtxtLinkEpochs[owner.vifIndex] == owner.linkEpoch and
    vifChannelForIdx(owner.vifIndex).chanCtxt == owner.channel

proc smDeferredProceed(owner: SmDeferredOwner; state: uint16): bool =
  if not smDeferredAttemptAt(owner, state): return false
  if smDeferredBindingCurrent(owner): return true
  # No response timer exists yet. Complete this attempt instead of leaving SM
  # in a pre-TX state or reusing its peer and challenge on another binding.
  sm_connect_ind(WLAN_FW_AUTH_OR_ASSOC_RESPONSE_TIMEOUT_FAILURE, 0xFFFF)

proc smDeferredAbortable(vifIndex: uint8; state: uint16): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  var tag = smDeferredTags
  while tag != nil:
    if tag.owner.vifIndex == vifIndex and tag.state == state and
        smDeferredAttemptAt(tag.owner, state):
      if tag.location == smDeferredExecuting: return false
      if tag.location in {smDeferredParked, smDeferredQueued}: result = true
    tag = tag.next

proc smDeferredDetach(): ptr KeMsgHdr =
  # Queued/executing messages remain owned by the kernel dispatcher.
  chanEnvView().deferredMsg = nil
  var tag = smDeferredTags
  while tag != nil:
    if tag.location == smDeferredParked:
      tag.location = smDeferredRetired
      return tag.header
    tag = tag.next

proc smDeferredCancel() =
  let saved = irqSave()
  inc smDeferredSerial
  let retired = smDeferredDetach()
  irqRestore(saved)
  if retired != nil: ke_msg_free(retired)

proc smDeferredCapture(connection: pointer; vifIndex: uint8): SmDeferredOwner =
  let saved = irqSave()
  inc smDeferredSerial
  result = SmDeferredOwner(connection: connection, vifIndex: vifIndex,
    channel: vifChannelForIdx(vifIndex).chanCtxt,
    serial: smDeferredSerial, vifEpoch: rxVifEpochs[vifIndex],
    linkEpoch: chanCtxtLinkEpochs[vifIndex], entryState: ke_state_get(TASK_SM))
  let retired = smDeferredDetach()
  irqRestore(saved)
  if retired != nil: ke_msg_free(retired)

proc smDeferredCreate(owner: SmDeferredOwner; state, sequence: uint16;
                      challenge: pointer): pointer =
  let wireLength = if challenge == nil: SmConnectAuthAssocReqPayloadSize
                   else: SmConnectAuthAssocChallengePayloadSize
  const alignment = alignof(SmDeferredTag).uint32
  let offset = (wireLength + KeMsgTailSlack + alignment - 1) and not (alignment - 1)
  result = ke_msg_try_alloc(SM_CONNECT_AUTH_ASSOC_REQ_MSG, TASK_SM, 0xFF,
                            offset + sizeof(SmDeferredTag).uint32)
  if result == nil:
    if smDeferredAttemptAt(owner, owner.entryState):
      sm_connect_ind(WLAN_FW_AUTH_OR_ASSOC_RESPONSE_TIMEOUT_FAILURE, 0xFFFF)
    return
  let header = keMsgHdrFromPayload(result)
  let saved = irqSave()
  if not smDeferredAttemptAt(owner, owner.entryState) or not smDeferredBindingCurrent(owner):
    irqRestore(saved)
    ke_msg_free(header)
    discard smDeferredProceed(owner, owner.entryState)
    return nil
  header.paramLen = wireLength
  let request = cast[ptr SmConnectAuthAssocReqPayload](result)
  request[] = SmConnectAuthAssocReqPayload(nextState: state, authSequence: sequence)
  if challenge != nil:
    let extended = cast[ptr SmConnectAuthAssocChallengePayload](result)
    discard c_memcpy(addr extended.challenge[0], challenge, extended.challenge.len.csize_t)
    request.challengeAddress = pointerAddrU32(addr extended.challenge[0])
  let tag = cast[ptr SmDeferredTag](cast[uint](result) + offset.uint)
  tag[] = SmDeferredTag(next: smDeferredTags, header: header, owner: owner,
    state: state, sequence: sequence, hasChallenge: challenge != nil)
  smDeferredTags = tag
  irqRestore(saved)

proc smDeferredPark(payload: pointer) =
  let saved = irqSave()
  let tag = smDeferredTagFor(payload)
  if tag == nil or tag.location != smDeferredBuilding:
    irqRestore(saved)
    return
  let owner = tag.owner
  if not smDeferredAttemptAt(owner, owner.entryState) or not smDeferredBindingCurrent(owner):
    tag.location = smDeferredRetired
    let header = tag.header
    irqRestore(saved)
    ke_msg_free(header)
    discard smDeferredProceed(owner, owner.entryState)
    return
  tag.location = smDeferredParked
  chanEnvView().deferredMsg = payload
  # Make state visible before ke_state_set can make saved work runnable.
  ke_state_set(TASK_SM, tag.state)
  irqRestore(saved)

proc smDeferredWake(vifEntry: pointer; unlinked: bool) =
  let saved = irqSave()
  let payload = chanEnvView().deferredMsg
  let tag = smDeferredTagFor(payload)
  if tag == nil or tag.location != smDeferredParked:
    irqRestore(saved)
    return
  if cast[pointer](vifChannelForIdx(tag.owner.vifIndex)) != vifEntry or
      (unlinked and smDeferredBindingCurrent(tag.owner)):
    irqRestore(saved)
    return
  if not smDeferredAttemptAt(tag.owner, tag.state):
    chanEnvView().deferredMsg = nil
    tag.location = smDeferredRetired
    let header = tag.header
    irqRestore(saved)
    ke_msg_free(header)
    return
  chanEnvView().deferredMsg = nil
  tag.location = smDeferredQueued
  irqRestore(saved)
  ke_msg_send(payload)

proc smDeferredPublish(vifEntry: pointer) =
  smDeferredWake(vifEntry, false)

proc smDeferredChannelUnlinked(vifIndex: uint8) =
  # An unlinked VIF may never get another activation. Let the SM dispatcher
  # report failure after channel teardown, using the parked command itself.
  smDeferredWake(cast[pointer](vifChannelForIdx(vifIndex)), true)

proc smDeferredDispatch(payload: pointer): cint =
  var challenge: array[128, uint8]
  let saved = irqSave()
  let tag = smDeferredTagFor(payload)
  if tag == nil or tag.location != smDeferredQueued or
      not smDeferredAttemptAt(tag.owner, tag.state):
    irqRestore(saved)
    return KeMsgConsumed
  let request = cast[ptr SmConnectAuthAssocReqPayload](payload)
  let extended = cast[ptr SmConnectAuthAssocChallengePayload](payload)
  let expectedLength = if tag.hasChallenge: SmConnectAuthAssocChallengePayloadSize
                       else: SmConnectAuthAssocReqPayloadSize
  let expectedAddress = if tag.hasChallenge: pointerAddrU32(addr extended.challenge[0]) else: 0'u32
  if tag.header.id != SM_CONNECT_AUTH_ASSOC_REQ_MSG or tag.header.destId != TASK_SM or
      tag.header.paramLen != expectedLength or request.nextState != tag.state or
      request.authSequence != tag.sequence or request.challengeAddress != expectedAddress:
    irqRestore(saved)
    return KeMsgConsumed
  let owner = tag.owner
  let state = tag.state
  let sequence = tag.sequence
  let hasChallenge = tag.hasChallenge
  if hasChallenge: challenge = extended.challenge
  tag.location = smDeferredExecuting
  irqRestore(saved)
  if smDeferredProceed(owner, state):
    if state == SmAuthStartingState:
      sm_auth_send(sequence, if hasChallenge: addr challenge[0] else: nil)
    elif state == SmAssociatingState:
      sm_assoc_req_send()
  let finishSaved = irqSave()
  let current = smDeferredTagFor(payload)
  if current != nil and current.owner.serial == owner.serial and
      current.location == smDeferredExecuting:
    current.location = smDeferredRetired
  irqRestore(finishSaved)
  KeMsgConsumed
