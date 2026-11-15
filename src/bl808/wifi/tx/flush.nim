type
  TxFlushStatus = enum
    txEmpty, txPublished, txNoDescriptor, txNoBuffer, txCancelled
  TxFlushResult = object
    status: TxFlushStatus
    source: pointer

proc txFlushOne(station: pointer; pending: bool;
                scope: var hostIpc.IpcHostDispatchScope): TxFlushResult =
  let saved = hostIpc.ipcHostIrqSave()
  defer: hostIpc.ipcHostIrqRestore(saved)
  let env = hwView().ipcEnv
  if not hostIpc.ipcHostDispatchCurrent(scope, env):
    result.status = txCancelled
    return
  if not txCntrlCheckFc(station):
    return
  let sta = staView(station)
  let queue = if pending: cast[pointer](addr sta.pendingList)
              else: cast[pointer](addr sta.waitingList)
  if listEmpty(queue):
    return
  let descriptor = ipc_host_txdesc_get(env)
  if descriptor == nil:
    result.status = txNoDescriptor
    return
  var buffer: pointer
  if not pending:
    buffer = ipc_host_txbuf_get(env)
    if buffer == nil:
      result.status = txNoBuffer
      return
  let header = listPopFront(queue)
  if header == nil:
    if buffer != nil:
      ipc_host_txbuf_free(buffer)
    return
  let packet = txHdrView(header).pbuf
  if pending:
    buffer = packet
  # No callback may run between peeking the free descriptor and publishing it.
  txPush(station, descriptor, buffer, header)
  result.status = txPublished
  if packet != buffer:
    result.source = packet

proc bl_tx_try_flush*(param: cint; txFcField: ptr KeTxFc) {.exportc, cdecl.} =
  {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_flush_enter; nimfw_dbg_tx_flush_enter++; }".}
  var scope: hostIpc.IpcHostDispatchScope
  if not hostIpc.beginIpcHostDispatch(scope, hwView().ipcEnv): return
  defer: hostIpc.endIpcHostDispatch(scope)
  let staTrigger = block:
    let saved = hostIpc.ipcHostIrqSave()
    defer: hostIpc.ipcHostIrqRestore(saved)
    if not hostIpc.ipcHostDispatchCurrent(scope, hwView().ipcEnv): return
    var triggers = 0'u32
    if param != 0 and txFcField != nil:
      triggers = txCntrlUpdateFc(cast[pointer](txFcField))
    triggers = triggers or txCntrlStaTriggerPending or txCntrlStaTrigger
    txCntrlStaTriggerPending = 0
    txCntrlStaTrigger = 0
    triggers

  for remoteStaIndex in 0 ..< NxRemoteStaStoreMax:
    if (staTrigger and bitSta(remoteStaIndex)) == 0'u32:
      continue
    let sta = staAt(remoteStaIndex)
    for pending in [true, false]:
      while true:
        let flushed = txFlushOne(sta, pending, scope)
        case flushed.status
        of txEmpty:
          break
        of txCancelled:
          return
        of txNoDescriptor:
          {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_nodesc; nimfw_dbg_tx_nodesc++; }".}
          bl_os_printf("[TX] no more txdesc, wait!\n\r")
          break
        of txNoBuffer:
          {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_nobuf; nimfw_dbg_tx_nobuf++; }".}
          bl_os_printf("[TX] no more txbuf, wait!\n\r")
          break
        of txPublished:
          if not pending:
            {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_push_calls; nimfw_dbg_tx_push_calls++; }".}
            {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_flush_push; nimfw_dbg_tx_flush_push++; }".}
          if flushed.source != nil:
            discard pbuf_free(cast[ptr Pbuf](flushed.source))
