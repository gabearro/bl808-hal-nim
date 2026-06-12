proc bl_tx_try_flush*(param: cint; txFcField: ptr KeTxFc) {.exportc, cdecl.} =
  {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_flush_enter; nimfw_dbg_tx_flush_enter++; }".}
  var staTrigger = 0'u32
  if param != 0 and txFcField != nil:
    staTrigger = txCntrlUpdateFc(cast[pointer](txFcField))

  staTrigger = staTrigger or txCntrlStaTriggerPending
  txCntrlStaTriggerPending = 0
  bl_os_enter_critical()
  staTrigger = staTrigger or txCntrlStaTrigger
  txCntrlStaTrigger = 0
  bl_os_exit_critical()

  for remoteStaIndex in 0 ..< NxRemoteStaStoreMax:
    if staTrigger == 0'u32:
      break
    let sta = staAt(remoteStaIndex)
    let staO = staView(sta)
    if (staTrigger and bitSta(remoteStaIndex)) == 0'u32 or not txCntrlCheckFc(sta):
      continue

    while not listEmpty(cast[pointer](addr staO.pendingList)):
      let txdescHost = ipc_host_txdesc_get(hwView().ipcEnv)
      if txdescHost == nil:
        bl_os_printf("[TX] no more txdesc, wait!\n\r")
        break
      let txhdr = listPopFront(cast[pointer](addr staO.pendingList))
      if txhdr == nil:
        break
      txPush(sta, txdescHost, txHdrView(txhdr).pbuf, txhdr)

    while not listEmpty(cast[pointer](addr staO.waitingList)):
      let txdescHost = ipc_host_txdesc_get(hwView().ipcEnv)
      if txdescHost == nil:
        {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_nodesc; nimfw_dbg_tx_nodesc++; }".}
        bl_os_printf("[TX] no more txdesc, wait!\n\r")
        break
      let txbuf = ipc_host_txbuf_get(hwView().ipcEnv)
      if txbuf == nil:
        {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_nobuf; nimfw_dbg_tx_nobuf++; }".}
        bl_os_printf("[TX] no more txbuf, wait!\n\r")
        break
      bl_os_enter_critical()
      let txhdr = listPopFront(cast[pointer](addr staO.waitingList))
      bl_os_exit_critical()
      if txhdr == nil:
        ipc_host_txbuf_free(txbuf)
        break
      {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_push_calls; nimfw_dbg_tx_push_calls++; }".}
      txPush(sta, txdescHost, txbuf, txhdr)
