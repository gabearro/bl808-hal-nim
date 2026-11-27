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
  when defined(bl808WifiSplitTxSlots):
    for packet in extraTxPackets.mitems:
      if packet[0] == 0:
        packet[0] = 1
        return addr packet[0]
    inc txPacketPoolStalls

proc ipc_host_txbuf_free*(txBufferSlot: pointer) {.exportc, cdecl.} =
  if txBufferSlot == nil: return
  let saved = ipcHostIrqSave()
  defer: ipcHostIrqRestore(saved)
  if loadU32(txBufferSlot, 0) != 0'u32:
    storeU32(txBufferSlot, 0, 0'u32)
    inc ipcHostTxResources.releases

proc ipc_host_txdesc_get*(env: pointer): pointer {.exportc, cdecl.} =
  if env == nil:
    inc nimFwDbgIpcHostTxDescGetNil
    return nil
  result = listPick(loadPtr(env, EnvListFreeOff))
  when defined(bl808WifiSplitTxSlots):
    if result != nil:
      if txDmaFree == 0:
        inc txDmaPoolStalls
        result = nil
      else:
        result = addr txDmaRecords[firstSetBit(txDmaFree) - 1][0]
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
  const hostSlots = (when defined(bl808WifiSplitTxSlots): WifiTxHostSlotCount
                     else: NxTxDescCnt.int)
  while current != nil and result < hostSlots.cint:
    inc result
    last = current
    current = loadPtr(current, 0)
  if current != nil or loadPtr(freeList, 4) != last:
    return 0
  when defined(bl808WifiSplitTxSlots):
    result = min(result, countSetBits(txDmaFree).cint)

proc ipc_host_txdesc_push*(env, hostId: pointer) {.exportc, cdecl.} =
  inc nimFwDbgIpcTxPushEnter
  if env == nil:
    inc nimFwDbgIpcTxPushEnvNil
    return
  let saved = ipcHostIrqSave()
  defer: ipcHostIrqRestore(saved)
  let freeList = loadPtr(env, EnvListFreeOff)
  nimFwDbgIpcFreeHead = cast[uint32](cast[uint](listPick(freeList)))
  when defined(bl808WifiSplitTxSlots):
    if txDmaFree == 0:
      inc nimFwDbgIpcTxPushPopNil
      return
  let credit = listPopFront(freeList)
  if credit == nil:
    inc nimFwDbgIpcTxPushPopNil
    return
  when defined(bl808WifiSplitTxSlots):
    # txPush prepared the free record under this same IRQ lock.
    let index = firstSetBit(txDmaFree) - 1
    let txdesc = cast[pointer](addr txDmaRecords[index][0])
    txDmaCredit[index] = credit
    txDmaFree = txDmaFree and not (1'u32 shl index)
    txDmaPeak = max(txDmaPeak, (WifiTxDmaRecordCount - countSetBits(txDmaFree)).uint32)
  else:
    let txdesc = credit
  inc nimFwDbgIpcHostTxDescPush
  storeU32(txdesc, TxdescHostReadyOff, 0xffff_ffff'u32)
  storePtr(txdesc, TxdescHostHostIdOff, hostId)
  listPushBack(loadPtr(env, EnvListOngoingOff), txdesc)
  regWrite(IpcApp2EmbTrigger, 1'u32 shl IpcIrqA2eTxDescFirstBit)
