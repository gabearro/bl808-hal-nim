when defined(bl808WifiDiagDhcpTxAttempts):
  var dhcpCfmPolicyLog {.exportc: "nimfw_dbg_dhcp_cfm_policy_log".}: array[8, array[8, uint32]]
  var dhcpCfmXidLog {.exportc: "nimfw_dbg_dhcp_cfm_xid_log".}: array[8, uint32]
  var dhcpCfmAirLog {.exportc: "nimfw_dbg_dhcp_cfm_air_log".}: array[8, uint32]

proc logDhcpTxConfirm(ethHdr: ptr EthernetHeaderView; txhdr: pointer;
                      txConfirmResult: int; txStatusWord: uint32; hostId: pointer) =
  when defined(bl808WifiDiagDhcpTxAttempts):
    let length = txHdrLen(txhdr)
    if length notin PbufLinkEncapsulationHlen .. TxBufferPayloadSize: return
    let wireLen = (length - PbufLinkEncapsulationHlen).uint
    let dhcp = parseDhcpWire(ethHdr, min(wireLen, DhcpTracePrefixSize.uint), wireLen, false)
    if not dhcp.present: return
    let saved = hostIpc.ipcHostIrqSave()
    defer: hostIpc.ipcHostIrqRestore(saved)
  else:
    if not isDhcpUdp(ethHdr): return
  inc nimFwDbgDhcpCfm
  nimFwDbgDhcpCfmStatus = txStatusWord
  let ringIdx = nimFwDbgDhcpCfmRingIdx and 7'u32
  nimFwDbgDhcpCfmStatusLog[ringIdx] = txStatusWord
  nimFwDbgDhcpCfmMetaLog[ringIdx] =
    (cast[uint32](txConfirmResult) and 0xff'u32) or
    (txHdrVifType(txhdr).uint32 shl 8) or
    ((if isBcMc(ethHdr.dst[0]): 1'u32 else: 0'u32) shl 16) or
    (txHdrRepush(txhdr).uint32 shl 24)
  when defined(bl808WifiDiagDhcpTxAttempts):
    dhcpCfmXidLog[ringIdx] = dhcp.xid
    nimFwDbgDhcpCfmMetaLog[ringIdx] = nimFwDbgDhcpCfmMetaLog[ringIdx] or
      ((dhcp.kind.uint32 and 15) shl 18) or (dhcp.xidValid.uint32 shl 22)
    dhcpCfmPolicyLog[ringIdx] = default(array[8, uint32])
    dhcpCfmAirLog[ringIdx] = 0
    if (txStatusWord and (DescDoneTxBit or DescDoneSwTxBit)) == DescDoneTxBit:
      let wrapper = hostIpc.ipcHostTxCompletionWrapper(hostId)
      if wrapper != nil and bl808_wifi_copy_completed_tx_policy(wrapper,
          addr txHdrView(txhdr).status, addr dhcpCfmPolicyLog[ringIdx], nil,
          addr dhcpCfmAirLog[ringIdx]):
        nimFwDbgDhcpCfmMetaLog[ringIdx] = nimFwDbgDhcpCfmMetaLog[ringIdx] or (1'u32 shl 17)
    {.emit: "asm volatile(\"\" ::: \"memory\");".}
  nimFwDbgDhcpCfmRingIdx = nimFwDbgDhcpCfmRingIdx + 1'u32
  if (txStatusWord and FrameSuccessfulTxBit) != 0'u32:
    inc nimFwDbgDhcpCfmAckOk
  else:
    inc nimFwDbgDhcpCfmAckFail
  if txConfirmResult > 0:
    inc nimFwDbgDhcpCfmOk
  else:
    inc nimFwDbgDhcpCfmFail
