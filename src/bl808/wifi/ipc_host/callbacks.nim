proc envCb(callbackEnv: pointer; callbackSlotByteOffset: uint): pointer {.inline.} =
  loadPtr(callbackEnv, callbackSlotByteOffset)

proc callSendDataCfm(callbackEnv, hostId: pointer) {.inline.} =
  let sendDataConfirm = cast[SendDataCfm](envCb(callbackEnv, 0))
  if sendDataConfirm != nil:
    discard sendDataConfirm(loadPtr(callbackEnv, EnvPthisOff), hostId)

proc callRecvMsgAck(callbackEnv, hostId: pointer) {.inline.} =
  let messageAckIndication = cast[RecvInd](envCb(callbackEnv, 16))
  if messageAckIndication != nil:
    discard messageAckIndication(loadPtr(callbackEnv, EnvPthisOff), hostId)

proc callRecvDbg(callbackEnv, hostId: pointer): uint8 {.inline.} =
  let debugIndication = cast[RecvInd](envCb(callbackEnv, 20))
  if debugIndication == nil:
    return 1
  debugIndication(loadPtr(callbackEnv, EnvPthisOff), hostId)

proc callTbtt(callbackEnv: pointer; callbackSlotByteOffset: uint) {.inline.} =
  let tbttIndication = cast[TbttInd](envCb(callbackEnv, callbackSlotByteOffset))
  if tbttIndication != nil:
    tbttIndication(loadPtr(callbackEnv, EnvPthisOff))
