proc noteDhcpTx(txPbufView: ptr PbufView; ethernetHeader: ptr EthernetHeaderView; etherType: uint16) =
  if isDhcpUdp(ethernetHeader):
    let ipv4Header = ipv4HeaderAt(ethernetHeader)
    let udpHeader = udpHeaderAt(ipv4Header)
    inc nimFwDbgDhcpTx
    nimFwDbgDhcpTxEth = etherType.uint32 or (ipv4Header.protocol.uint32 shl 16)
    nimFwDbgDhcpTxPorts = udpHeader.srcPort.uint32 or (udpHeader.dstPort.uint32 shl 16)
    nimFwDbgDhcpTxLen = txPbufView.totLen.uint32
    nimFwDbgDhcpTxSrcLo = cast[ptr uint32](addr ethernetHeader.src[0])[]
    nimFwDbgDhcpTxSrcHi = cast[ptr uint16](addr ethernetHeader.src[4])[].uint32
    let ethernetFrameBytes = cast[ptr UncheckedArray[uint8]](txPbufView.payload)
    let msgType = dhcpMsgTypeFromEthernet(ethernetFrameBytes, txPbufView.len.uint32)
    if msgType != 0'u8:
      discard repairDhcpUdpChecksum(ethernetFrameBytes, txPbufView.len.uint32)
      if msgType == 3'u8:
        nimFwDbgDhcpReqUdpChecksumBefore = nimFwDbgDhcpUdpChecksumBefore
        nimFwDbgDhcpReqUdpChecksumCalc = nimFwDbgDhcpUdpChecksumCalc
        nimFwDbgDhcpReqUdpChecksumAfter = nimFwDbgDhcpUdpChecksumAfter
        nimFwDbgDhcpReqUdpChecksumVerifyBefore = nimFwDbgDhcpUdpChecksumVerifyBefore
        nimFwDbgDhcpReqUdpChecksumVerifyAfter = nimFwDbgDhcpUdpChecksumVerifyAfter
        nimFwDbgDhcpReqUdpChecksumAtCopy =
          udpChecksumFieldFromEthernet(ethernetFrameBytes, txPbufView.len.uint32).uint32
    if msgType < nimFwDbgDhcpTxMsgHist.len.uint8:
      inc nimFwDbgDhcpTxMsgHist[msgType]
    nimFwDbgDhcpTxMsg =
      msgType.uint32 or
      (if txPbufView.len.uint32 > 49'u32: loadBe32(ethernetFrameBytes, 46'u) shl 8 else: 0'u32)
    let rawLimit =
      if txPbufView.len.uint32 < nimFwDbgDhcpTxRaw.len.uint32:
        txPbufView.len.uint32
      else:
        nimFwDbgDhcpTxRaw.len.uint32
    if msgType == 3'u8 or nimFwDbgDhcpTxRawLen == 0'u32:
      nimFwDbgDhcpTxRawLen =
        if txPbufView.totLen.uint32 < rawLimit: txPbufView.totLen.uint32 else: rawLimit
      for dhcpTxRawByteIndex in 0 ..< nimFwDbgDhcpTxRawLen.int:
        nimFwDbgDhcpTxRaw[dhcpTxRawByteIndex] =
          ethernetFrameBytes[dhcpTxRawByteIndex]
      if msgType == 3'u8:
        nimFwDbgDhcpReqUdpChecksumAtCopy =
          udpChecksumFieldFromEthernet(ethernetFrameBytes, txPbufView.len.uint32).uint32
    if msgType == 3'u8:
      nimFwDbgDhcpRequestTxBreakpoint()
    nimFwDbgDhcpTxBreakpoint()
