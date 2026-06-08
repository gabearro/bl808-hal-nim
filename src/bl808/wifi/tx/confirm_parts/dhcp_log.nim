proc logDhcpTxConfirm(ethHdr: ptr EthernetHeaderView; txhdr: pointer; ret: int; value: uint32) =
  if not isDhcpUdp(ethHdr):
    return
  inc nimFwDbgDhcpCfm
  nimFwDbgDhcpCfmStatus = value
  let ringIdx = nimFwDbgDhcpCfmRingIdx and 7'u32
  nimFwDbgDhcpCfmRingIdx = nimFwDbgDhcpCfmRingIdx + 1'u32
  nimFwDbgDhcpCfmStatusLog[ringIdx] = value
  nimFwDbgDhcpCfmMetaLog[ringIdx] =
    (cast[uint32](ret) and 0xff'u32) or
    (txHdrVifType(txhdr).uint32 shl 8) or
    ((if isBcMc(ethHdr.dst[0]): 1'u32 else: 0'u32) shl 16) or
    (txHdrRepush(txhdr).uint32 shl 24)
  if (value and FrameSuccessfulTxBit) != 0'u32:
    inc nimFwDbgDhcpCfmAckOk
  else:
    inc nimFwDbgDhcpCfmAckFail
  if ret > 0:
    inc nimFwDbgDhcpCfmOk
  else:
    inc nimFwDbgDhcpCfmFail
