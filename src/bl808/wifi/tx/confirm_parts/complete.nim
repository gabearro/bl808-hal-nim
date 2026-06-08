proc bl_tx_cfm*(pthis, hostId: pointer): cint {.exportc, cdecl.} =
  {.emit: "{ extern volatile unsigned int nimfw_dbg_bl_tx_cfm; nimfw_dbg_bl_tx_cfm++; }".}
  discard pthis
  let buf = txbufHostBuf(hostId)
  let txhdr = bufferAt(buf, alignPads(buf).uint)
  let eth = bufferAt(buf, PbufLinkEncapsulationHlen.uint)
  let ethHdr = ethernetHeaderAt(eth)
  let ethTypeBytes = ethHdr.ethertype
  if ethTypeBytes == 0x8e88'u16 or ethTypeBytes == 0x888e'u16:
    {.emit: "{ extern volatile unsigned int nimfw_dbg_bl_tx_cfm_eapol; nimfw_dbg_bl_tx_cfm_eapol++; }".}
  let value = txHdrView(txhdr).status
  if value == 0'u32:
    bl_os_printf("[TX] FW return status is NULL!!!\n\r")

  let ret = txCheckRet(txHdrVifType(txhdr), if isBcMc(ethHdr.dst[0]): 1'u8 else: 0'u8, value)
  logDhcpTxConfirm(ethHdr, txhdr, ret, value)

  let sta = staAt(txHdrStaId(txhdr).int)
  let staO = staView(sta)
  let linksNum = vifView(staVif(sta)).linksNum
  if repushTxConfirmIfNeeded(txhdr, sta, staO, linksNum, ret, value):
    return 0

  let cb = cast[TxCallback](txHdrView(txhdr).cfmCb)
  let cbArg = txHdrView(txhdr).cfmArg
  logEapolTxConfirm(ethHdr, txhdr, cb, ethTypeBytes, ret, value)
  if cb != nil:
    {.emit: "{ extern volatile unsigned int nimfw_dbg_bl_tx_cfm_cb; nimfw_dbg_bl_tx_cfm_cb++; }".}
  ipc_host_txbuf_free(hostId)
  txCntrlStaTriggerPending = txCntrlStaTriggerPending or bitSta(staO.staIdx)
  if cb != nil:
    cb(cbArg, ret > 0)
  ret.cint
