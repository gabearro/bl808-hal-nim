proc ipcHostMsgAckHandler(env: pointer; scope: ptr IpcHostDispatchScope) =
  let ack = block:
    let saved = ipcHostIrqSave()
    defer: ipcHostIrqRestore(saved)
    if scope == nil or not ipcHostDispatchCurrent(scope[], env): return
    let hostId = loadPtr(env, EnvMsgA2eHostidOff)
    let shared = loadPtr(env, EnvSharedOff)
    if hostId == nil or shared == nil: return
    let sequence = loadU8(env, EnvMsgA2eCntOff)
    # Firmware replaces the shared source byte with its acceptance counter.
    if loadU8(shared, SharedMsgBodyOff + LmacMsgSrcIdOff) != sequence:
      inc nimFwDbgIpcMsgAckMismatch
      return
    let callback = cast[RecvInd](envCb(env, 16))
    let context = loadPtr(env, EnvPthisOff)
    storePtr(env, EnvMsgA2eHostidOff, nil)
    storeU8(env, EnvMsgA2eCntOff, sequence + 1'u8)
    (hostId: hostId, callback: callback, context: context)
  if scope.cancelled: return
  if ack.callback != nil:
    discard ack.callback(ack.context, ack.hostId)

proc ipcHostTxCfmHandler(env: pointer; scope: ptr IpcHostDispatchScope) =
  inc nimFwDbgIpcHostTxCfmHandler
  while not scope.cancelled:
    let completion = block:
      let saved = ipcHostIrqSave()
      defer: ipcHostIrqRestore(saved)
      if scope.cancelled: return
      let txdesc = listPopFront(loadPtr(env, EnvListCfmOff))
      if txdesc == nil: return
      let hostId = loadPtr(txdesc, TxdescHostHostIdOff)
      nimFwDbgIpcHostTxCfmLastHost = cast[uint32](cast[uint](hostId))
      (descriptor: txdesc, hostId: hostId,
       callback: cast[SendDataCfm](envCb(env, 0)),
       context: loadPtr(env, EnvPthisOff))
    if scope.cancelled: return
    if completion.callback != nil:
      when defined(bl808WifiDiagDhcpTxAttempts) or defined(bl808WifiDiagTcpPath):
        scope.txCompletion = completion.descriptor
        try: discard completion.callback(completion.context, completion.hostId)
        finally: scope.txCompletion = nil
      else:
        discard completion.callback(completion.context, completion.hostId)
    block:
      let saved = ipcHostIrqSave()
      defer: ipcHostIrqRestore(saved)
      if scope.cancelled: return
      inc nimFwDbgIpcHostTxCfmDrained
      storePtr(completion.descriptor, TxdescHostHostIdOff, nil)
      when defined(bl808WifiSplitTxSlots):
        # A flushed frame may have skipped primary DONE. Return its credit
        # here, and keep the DMA record through even a reentrant callback.
        let index = ipcHostTxDmaIndex(completion.descriptor)
        discard returnTxHostSlot(index)
        txDmaFree = txDmaFree or (1'u32 shl index)
      else:
        listPushBack(loadPtr(env, EnvListFreeOff), completion.descriptor)
      inc ipcHostTxResources.releases

proc ipcHostDbgHandler(env: pointer; scope: ptr IpcHostDispatchScope) =
  let debugHostSlotIndex = loadU8(env, EnvDbgIdxOff).uint
  let hostId = loadPtr(env, EnvDbgArrayOff + debugHostSlotIndex * 8'u)
  while not scope.cancelled:
    let status = callRecvDbg(env, hostId)
    if scope.cancelled or status != 0'u8: return

proc ipc_host_irq*(env: pointer; statusIn: uint32) {.exportc, cdecl.} =
  if env == nil:
    return
  inc nimFwDbgIpcHostIrq

  var scope: IpcHostDispatchScope
  if not beginIpcHostDispatch(scope, env): return
  defer: endIpcHostDispatch(scope)
  if scope.cancelled: return

  regWrite(IpcEmb2AppAck, statusIn)
  let status = statusIn or regRead(IpcEmb2AppStatus)
  nimFwDbgIpcHostIrqStatus = status

  if (status and IpcIrqE2aTxCfm) != 0'u32:
    inc nimFwDbgIpcHostTxCfmIrq
    for txCfmQueueIndex in 0 ..< IpcTxQueueCnt:
      if (status and (1'u32 shl (txCfmQueueIndex + IpcIrqE2aTxCfmPos))) != 0'u32:
        ipcHostTxCfmHandler(env, addr scope)
        if scope.cancelled: return

  if (status and IpcIrqE2aMsgAck) != 0'u32:
    ipcHostMsgAckHandler(env, addr scope)
    if scope.cancelled: return
  if (status and IpcIrqE2aRadar) != 0'u32:
    discard
  if (status and IpcIrqE2aDbg) != 0'u32:
    ipcHostDbgHandler(env, addr scope)
    if scope.cancelled: return
  if (status and IpcIrqE2aTbttPrim) != 0'u32:
    callTbtt(env, 24)
    if scope.cancelled: return
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
