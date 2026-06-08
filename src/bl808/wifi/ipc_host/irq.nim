proc ipcHostMsgAckHandler(env: pointer) =
  let hostId = loadPtr(env, EnvMsgA2eHostidOff)
  if hostId == nil:
    return
  storePtr(env, EnvMsgA2eHostidOff, nil)
  storeU8(env, EnvMsgA2eCntOff, loadU8(env, EnvMsgA2eCntOff) + 1'u8)
  callRecvMsgAck(env, hostId)

proc ipcHostTxCfmHandler(env: pointer) =
  inc nimFwDbgIpcHostTxCfmHandler
  let cfmList = loadPtr(env, EnvListCfmOff)
  var txdesc = listPopFront(cfmList)
  while txdesc != nil:
    let hostId = loadPtr(txdesc, TxdescHostHostIdOff)
    nimFwDbgIpcHostTxCfmLastHost = cast[uint32](cast[uint](hostId))
    callSendDataCfm(env, hostId)
    inc nimFwDbgIpcHostTxCfmDrained
    storePtr(txdesc, TxdescHostHostIdOff, nil)
    listPushBack(loadPtr(env, EnvListFreeOff), txdesc)
    txdesc = listPopFront(cfmList)

proc ipcHostDbgHandler(env: pointer) =
  let idx = loadU8(env, EnvDbgIdxOff).uint
  let hostId = loadPtr(env, EnvDbgArrayOff + idx * 8'u)
  while callRecvDbg(env, hostId) == 0'u8:
    discard

proc ipc_host_irq*(env: pointer; statusIn: uint32) {.exportc, cdecl.} =
  if env == nil:
    return
  inc nimFwDbgIpcHostIrq

  regWrite(IpcEmb2AppAck, statusIn)
  let status = statusIn or regRead(IpcEmb2AppStatus)
  nimFwDbgIpcHostIrqStatus = status

  if (status and IpcIrqE2aTxCfm) != 0'u32:
    inc nimFwDbgIpcHostTxCfmIrq
    for i in 0 ..< IpcTxQueueCnt:
      if (status and (1'u32 shl (i + IpcIrqE2aTxCfmPos))) != 0'u32:
        ipcHostTxCfmHandler(env)

  if (status and IpcIrqE2aMsgAck) != 0'u32:
    ipcHostMsgAckHandler(env)
  if (status and IpcIrqE2aRadar) != 0'u32:
    discard
  if (status and IpcIrqE2aDbg) != 0'u32:
    ipcHostDbgHandler(env)
  if (status and IpcIrqE2aTbttPrim) != 0'u32:
    callTbtt(env, 24)
  if (status and IpcIrqE2aTbttSec) != 0'u32:
    callTbtt(env, 28)

proc ipc_host_enable_irq*(env: pointer; value: uint32) {.exportc, cdecl.} =
  discard env
  regWrite(IpcEmb2AppUnmaskSet, value)

proc ipc_host_disable_irq*(env: pointer; value: uint32) {.exportc, cdecl.} =
  discard env
  regWrite(IpcEmb2AppUnmaskClear, value)

proc ipc_host_disable_irq_e2a*() {.exportc, cdecl.} =
  regWrite(IpcEmb2AppUnmaskClear, IpcIrqE2aAll)
