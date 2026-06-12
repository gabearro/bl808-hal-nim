proc ipc_host_txbuf_get*(env: pointer): pointer {.exportc, cdecl.} =
  if env == nil:
    return nil
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
  let usedIdx = loadU32(env, EnvTxdescUsedIdxOff)
  let freeIdx = loadU32(env, EnvTxdescFreeIdxOff)
  cint(NxTxDescCnt - (freeIdx - usedIdx))

proc ipc_host_txdesc_push*(env, hostId: pointer) {.exportc, cdecl.} =
  if env == nil:
    return
  let freeList = loadPtr(env, EnvListFreeOff)
  let txdesc = listPopFront(freeList)
  if txdesc == nil:
    return
  inc nimFwDbgIpcHostTxDescPush
  storeU32(txdesc, TxdescHostReadyOff, 0xffff_ffff'u32)
  storePtr(txdesc, TxdescHostHostIdOff, hostId)
  listPushBack(loadPtr(env, EnvListOngoingOff), txdesc)
  regWrite(IpcApp2EmbTrigger, 1'u32 shl IpcIrqA2eTxDescFirstBit)
