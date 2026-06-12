proc noteTxProtocol(txPbufView: ptr PbufView; etherType: uint16) =
  if etherType == 0x0608'u16:
    inc nimFwDbgTxArp
  elif etherType == 0x0008'u16 and txPbufView.len.uint32 >= 42'u32:
    let ethernetFrameBytes = cast[ptr UncheckedArray[uint8]](txPbufView.payload)
    let ihl = (ethernetFrameBytes[14] and 0x0F'u8).uint32 * 4'u32
    let l4Off = 14'u32 + ihl
    if ihl >= 20'u32 and l4Off + 8'u32 <= txPbufView.len.uint32 and ethernetFrameBytes[23] == 17'u8:
      let srcPort = loadBe16(ethernetFrameBytes, l4Off)
      let dstPort = loadBe16(ethernetFrameBytes, l4Off + 2'u32)
      inc nimFwDbgTxUdp
      nimFwDbgTxUdpPorts = srcPort.uint32 or (dstPort.uint32 shl 16)
      nimFwDbgTxUdpIp =
        ethernetFrameBytes[26].uint32 or (ethernetFrameBytes[27].uint32 shl 8) or
        (ethernetFrameBytes[30].uint32 shl 16) or (ethernetFrameBytes[31].uint32 shl 24)
      if srcPort == 65001'u16 or dstPort == 65001'u16:
        inc nimFwDbgTxUdpProbe
    elif ihl >= 20'u32 and l4Off + 14'u32 < txPbufView.len.uint32 and ethernetFrameBytes[23] == 6'u8:
      let srcPort = loadBe16(ethernetFrameBytes, l4Off)
      let dstPort = loadBe16(ethernetFrameBytes, l4Off + 2'u32)
      inc nimFwDbgTxTcp
      nimFwDbgTxTcpFlags =
        ethernetFrameBytes[l4Off + 13'u32].uint32 or
        (srcPort.uint32 shl 8) or
        (dstPort.uint32 shl 24)
      if srcPort == 80'u16 or dstPort == 80'u16:
        inc nimFwDbgTxTcp80
