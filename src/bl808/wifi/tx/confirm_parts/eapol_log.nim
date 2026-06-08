proc logEapolTxConfirm(ethHdr: ptr EthernetHeaderView; txhdr: pointer; cb: TxCallback;
                       ethTypeBytes: uint16; ret: int; value: uint32) =
  if ethTypeBytes != 0x8e88'u16 and ethTypeBytes != 0x888e'u16:
    return

  {.emit: ["{ extern volatile unsigned int nimfw_dbg_cfm_cb_ptr_last; nimfw_dbg_cfm_cb_ptr_last = (unsigned int)", cb, "; extern volatile unsigned int nimfw_dbg_cfm_last_ethertype; nimfw_dbg_cfm_last_ethertype = (unsigned int)", ethTypeBytes, "; extern volatile unsigned int nimfw_dbg_eapol_cfm_status; nimfw_dbg_eapol_cfm_status = (unsigned int)", value, "; extern volatile unsigned int nimfw_dbg_eapol_cfm_count; nimfw_dbg_eapol_cfm_count++; }"].}
  let logIdx = nimFwDbgEapolCfmRingIdx and 0x03'u32
  nimFwDbgEapolCfmRingIdx = nimFwDbgEapolCfmRingIdx + 1'u32
  let eapol = cast[ptr UncheckedArray[uint8]](addr ethHdr.payload[0])
  let eapolLen = if txHdrLen(txhdr) >= LinkOffsetLen: txHdrLen(txhdr) - LinkOffsetLen else: 0'u16
  var keyInfo = 0'u32
  var replayLo = 0'u32
  var eapolKind = 0'u32
  if eapolLen >= 7'u16:
    keyInfo = loadBe16(eapol, 5'u).uint32
    eapolKind = eapol[1].uint32 or (eapol[4].uint32 shl 8)
  if eapolLen >= 17'u16:
    replayLo = loadBe32(eapol, 13'u)
  nimFwDbgEapolCfmStatusLog[logIdx] = value
  nimFwDbgEapolCfmMetaLog[logIdx] =
    eapolLen.uint32 or
    (if ret > 0: 1'u32 shl 16 else: 0'u32) or
    ((txHdrStaId(txhdr).uint32 and 0x0f'u32) shl 24) or
    ((txHdrRepush(txhdr).uint32 and 0x0f'u32) shl 28)
  nimFwDbgEapolCfmKeyLog[logIdx] = keyInfo or (eapolKind shl 16)
  nimFwDbgEapolCfmReplayLog[logIdx] = replayLo
  nimFwDbgEapolCfmCbLog[logIdx] = cast[uint](cb).uint32
  if ret > 0:
    {.emit: "{ extern volatile unsigned int nimfw_dbg_eapol_cfm_ack_ok; nimfw_dbg_eapol_cfm_ack_ok++; }".}
  else:
    {.emit: "{ extern volatile unsigned int nimfw_dbg_eapol_cfm_ack_fail; nimfw_dbg_eapol_cfm_ack_fail++; }".}
