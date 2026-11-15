proc ipc_host_txbuf_get*(env: pointer): pointer {.exportc, cdecl.} =
  if env == nil:
    return nil
  let saved = ipcHostIrqSave()
  defer: ipcHostIrqRestore(saved)
  let txbuf = loadPtr(env, EnvTxbufOff)
  if txbuf == nil:
    return nil
  for txBufferSlotIndex in 0'u ..< NxTxDescCnt.uint:
    let txBufferSlot = ptrAt(txbuf, txBufferSlotIndex * SharedTxbufSize)
    if loadU32(txBufferSlot, 0) == 0'u32:
      storeU32(txBufferSlot, 0, 1'u32)
      return txBufferSlot

proc ipc_host_txbuf_free*(txBufferSlot: pointer) {.exportc, cdecl.} =
  if txBufferSlot != nil:
    storeU32(txBufferSlot, 0, 0'u32)

proc ipc_host_txdesc_get*(env: pointer): pointer {.exportc, cdecl.} =
  if env == nil:
    inc nimFwDbgIpcHostTxDescGetNil
    return nil
  result = listPick(loadPtr(env, EnvListFreeOff))
  if result == nil:
    inc nimFwDbgIpcHostTxDescGetNil

proc ipc_host_txdesc_left*(env: pointer; queueIdx, userPos: cint): cint {.exportc, cdecl.} =
  discard queueIdx
  discard userPos
  if env == nil:
    return 0
  let saved = ipcHostIrqSave()
  defer: ipcHostIrqRestore(saved)
  let freeList = loadPtr(env, EnvListFreeOff)
  if freeList == nil:
    return 0
  var current = loadPtr(freeList, 0)
  var last: pointer
  while current != nil and result < NxTxDescCnt.cint:
    inc result
    last = current
    current = loadPtr(current, 0)
  if current != nil or loadPtr(freeList, 4) != last:
    return 0

proc ipc_host_txdesc_push*(env, hostId: pointer) {.exportc, cdecl.} =
  inc nimFwDbgIpcTxPushEnter
  if env == nil:
    inc nimFwDbgIpcTxPushEnvNil
    return
  let saved = ipcHostIrqSave()
  defer: ipcHostIrqRestore(saved)
  let freeList = loadPtr(env, EnvListFreeOff)
  nimFwDbgIpcFreeHead = cast[uint32](cast[uint](listPick(freeList)))
  let txdesc = listPopFront(freeList)
  if txdesc == nil:
    inc nimFwDbgIpcTxPushPopNil
    return
  inc nimFwDbgIpcHostTxDescPush
  storeU32(txdesc, TxdescHostReadyOff, 0xffff_ffff'u32)
  storePtr(txdesc, TxdescHostHostIdOff, hostId)
  listPushBack(loadPtr(env, EnvListOngoingOff), txdesc)
  regWrite(IpcApp2EmbTrigger, 1'u32 shl IpcIrqA2eTxDescFirstBit)
