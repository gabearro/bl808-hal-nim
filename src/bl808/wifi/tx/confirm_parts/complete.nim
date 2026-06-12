proc bl_tx_cfm*(callbackContext, hostTxBuffer: pointer): cint {.exportc, cdecl.} =
  {.emit: "{ extern volatile unsigned int nimfw_dbg_bl_tx_cfm; nimfw_dbg_bl_tx_cfm++; }".}
  discard callbackContext
  let txPayloadStorage = txbufHostBuf(hostTxBuffer)
  let txHeaderPtr = bufferAt(txPayloadStorage, alignPads(txPayloadStorage).uint)
  let ethernetFramePtr = bufferAt(txPayloadStorage, PbufLinkEncapsulationHlen.uint)
  let ethernetHeader = ethernetHeaderAt(ethernetFramePtr)
  let etherType = ethernetHeader.ethertype
  if etherType == 0x8e88'u16 or etherType == 0x888e'u16:
    {.emit: "{ extern volatile unsigned int nimfw_dbg_bl_tx_cfm_eapol; nimfw_dbg_bl_tx_cfm_eapol++; }".}
  let txStatusWord = txHdrView(txHeaderPtr).status
  if txStatusWord == 0'u32:
    bl_os_printf("[TX] FW return status is NULL!!!\n\r")

  let txConfirmResult = txCheckRet(
    txHdrVifType(txHeaderPtr), if isBcMc(ethernetHeader.dst[0]): 1'u8 else: 0'u8, txStatusWord)
  logDhcpTxConfirm(ethernetHeader, txHeaderPtr, txConfirmResult, txStatusWord)

  let station = staAt(txHdrStaId(txHeaderPtr).int)
  let stationState = staView(station)
  let stationLinkCount = vifView(staVif(station)).linksNum
  if repushTxConfirmIfNeeded(txHeaderPtr, station, stationState, stationLinkCount, txConfirmResult, txStatusWord):
    return 0

  let txConfirmCallback = cast[TxCallback](txHdrView(txHeaderPtr).cfmCb)
  let txConfirmCallbackArg = txHdrView(txHeaderPtr).cfmArg
  logEapolTxConfirm(
    ethernetHeader, txHeaderPtr, txConfirmCallback, etherType, txConfirmResult, txStatusWord)
  if txConfirmCallback != nil:
    {.emit: "{ extern volatile unsigned int nimfw_dbg_bl_tx_cfm_cb; nimfw_dbg_bl_tx_cfm_cb++; }".}
  ipc_host_txbuf_free(hostTxBuffer)
  txCntrlStaTriggerPending = txCntrlStaTriggerPending or bitSta(stationState.staIdx)
  if txConfirmCallback != nil:
    txConfirmCallback(txConfirmCallbackArg, txConfirmResult > 0)
  txConfirmResult.cint
