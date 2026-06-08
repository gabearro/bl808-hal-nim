proc envCb(env: pointer; off: uint): pointer {.inline.} =
  loadPtr(env, off)

proc callSendDataCfm(env, hostId: pointer) {.inline.} =
  let fn = cast[SendDataCfm](envCb(env, 0))
  if fn != nil:
    discard fn(loadPtr(env, EnvPthisOff), hostId)

proc callRecvMsgAck(env, hostId: pointer) {.inline.} =
  let fn = cast[RecvInd](envCb(env, 16))
  if fn != nil:
    discard fn(loadPtr(env, EnvPthisOff), hostId)

proc callRecvDbg(env, hostId: pointer): uint8 {.inline.} =
  let fn = cast[RecvInd](envCb(env, 20))
  if fn == nil:
    return 1
  fn(loadPtr(env, EnvPthisOff), hostId)

proc callTbtt(env: pointer; off: uint) {.inline.} =
  let fn = cast[TbttInd](envCb(env, off))
  if fn != nil:
    fn(loadPtr(env, EnvPthisOff))
