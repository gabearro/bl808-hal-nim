# Private allocation tails leave the one-byte request ABI unchanged.
type
  SmAbortIdentity = object
    connection: pointer
    vifEpoch: uint32
    vifIndex: uint8
    valid: bool
  SmAbortTag = object
    next: ptr SmAbortTag
    header: ptr KeMsgHdr
    identity: SmAbortIdentity
    captured: bool

var smAbortTags {.wifiCtrl.}: ptr SmAbortTag

proc smAbortStorageLength(id: uint16; destination: uint8; length: uint32): uint32 =
  if id != SM_CONNECT_ABORT_REQ or destination != TASK_SM or length == 0:
    return length
  const alignment = alignof(SmAbortTag).uint32
  const overhead = KeMsgTailSlack + alignment - 1 + sizeof(SmAbortTag).uint32
  if length > high(uint32) - overhead: return high(uint32)
  ((length + KeMsgTailSlack + alignment - 1) and not (alignment - 1)) +
    sizeof(SmAbortTag).uint32

proc smAbortRegister(header: ptr KeMsgHdr) =
  if header.id != SM_CONNECT_ABORT_REQ or header.destId != TASK_SM or header.paramLen == 0:
    return
  const alignment = alignof(SmAbortTag).uint32
  let offset = (header.paramLen + KeMsgTailSlack + alignment - 1) and not (alignment - 1)
  let tag = cast[ptr SmAbortTag](cast[uint](keMsgPayload(header)) + offset.uint)
  let saved = irqSave()
  tag[] = SmAbortTag(next: smAbortTags, header: header)
  smAbortTags = tag
  irqRestore(saved)

proc smAbortForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr smAbortTags
  while link[] != nil:
    if link[].header == header:
      link[] = link[].next
      return
    link = addr link[].next

proc smAbortCapture(request: pointer): SmAbortIdentity =
  let saved = irqSave()
  defer: irqRestore(saved)
  var tag = smAbortTags
  while tag != nil:
    if keMsgPayload(tag.header) == request:
      if tag.header.id != SM_CONNECT_ABORT_REQ or tag.header.destId != TASK_SM or
          tag.header.paramLen != 1:
        return
      let vifIndex = cast[ptr uint8](request)[]
      if not tag.captured:
        tag.captured = true
        if vifIndex < MAX_VIFS.uint8:
          let connection = smEnvView().connectInfo
          let vif = vifChannelForIdx(vifIndex)
          tag.identity = SmAbortIdentity(connection: connection, vifIndex: vifIndex,
            vifEpoch: rxVifEpochs[vifIndex], valid:
              vif.vifIdx == vifIndex and vif.vifType == VIF_TYPE_STA and
              (connection == nil or connectInfoView(connection).vifIdx == vifIndex))
      result = tag.identity
      if result.vifIndex != vifIndex: result.valid = false
      return
    tag = tag.next

proc smAbortCurrent(identity: SmAbortIdentity): bool =
  identity.valid and identity.vifIndex < MAX_VIFS.uint8 and
    smEnvView().connectInfo == identity.connection and
    rxVifEpochs[identity.vifIndex] == identity.vifEpoch and
    vifChannelForIdx(identity.vifIndex).vifIdx == identity.vifIndex and
    vifChannelForIdx(identity.vifIndex).vifType == VIF_TYPE_STA and
    (identity.connection == nil or
      connectInfoView(identity.connection).vifIdx == identity.vifIndex)

proc smAbortCaptureMessage(header: ptr KeMsgHdr) =
  if header.id == SM_CONNECT_ABORT_REQ and header.destId == TASK_SM:
    discard smAbortCapture(keMsgPayload(header))
