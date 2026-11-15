proc ipc_host_msg_push*(env, msgBuf: pointer; len: uint16): cint {.exportc, cdecl.} =
  if env == nil or msgBuf == nil:
    return -1
  let copyLen = len.uint32
  if copyLen < LmacMsgHeaderSize or roundUp4(copyLen) > SharedMsgBodySize:
    return -1
  let saved = ipcHostIrqSave()
  defer: ipcHostIrqRestore(saved)
  let sharedEnv = loadPtr(env, EnvSharedOff)
  let msg = loadPtr(msgBuf, BlCmdA2eMsgOff)
  if sharedEnv == nil or msg == nil:
    return -1
  if loadPtr(env, EnvMsgA2eHostidOff) != nil:
    return -1
  if loadU32(msg, LmacMsgParamLenOff) != copyLen - LmacMsgHeaderSize:
    return -1

  discard c_memcpy(ptrAt(sharedEnv, SharedMsgBodyOff), msg, copyLen.csize_t)
  # Alignment padding belongs to shared storage, not the caller's allocation.
  let padding = roundUp4(copyLen) - copyLen
  if padding != 0:
    discard c_memset(ptrAt(sharedEnv, SharedMsgBodyOff + copyLen.uint), 0, padding.csize_t)
  storePtr(env, EnvMsgA2eHostidOff, msgBuf)
  regWrite(IpcApp2EmbTrigger, IpcIrqA2eMsg)
  0

proc ipc_host_patt_addr_push*(env: pointer; patternAddr: uint32) {.exportc, cdecl.} =
  if env == nil:
    return
  let sharedEnv = loadPtr(env, EnvSharedOff)
  if sharedEnv != nil:
    storeU32(sharedEnv, SharedPatternAddrOff, patternAddr)

proc ipc_host_get_status*(env: pointer): uint32 {.exportc, cdecl.} =
  discard env
  regRead(IpcEmb2AppStatus)

proc ipc_host_get_rawstatus*(env: pointer): uint32 {.exportc, cdecl.} =
  discard env
  regRead(IpcEmb2AppRawStatus)
