proc noteDhcpTx(pbuf: ptr PbufView; eth: ptr EthernetHeaderView; proto: uint16) =
  if isDhcpUdp(eth):
    let ip = ipv4HeaderAt(eth)
    let udp = udpHeaderAt(ip)
    inc nimFwDbgDhcpTx
    nimFwDbgDhcpTxEth = proto.uint32 or (ip.protocol.uint32 shl 16)
    nimFwDbgDhcpTxPorts = udp.srcPort.uint32 or (udp.dstPort.uint32 shl 16)
    nimFwDbgDhcpTxLen = pbuf.totLen.uint32
    nimFwDbgDhcpTxSrcLo = cast[ptr uint32](addr eth.src[0])[]
    nimFwDbgDhcpTxSrcHi = cast[ptr uint16](addr eth.src[4])[].uint32
    let raw = cast[ptr UncheckedArray[uint8]](pbuf.payload)
    let msgType = dhcpMsgTypeFromEthernet(raw, pbuf.len.uint32)
    if msgType != 0'u8:
      discard repairDhcpUdpChecksum(raw, pbuf.len.uint32)
      if msgType == 3'u8:
        nimFwDbgDhcpReqUdpChecksumBefore = nimFwDbgDhcpUdpChecksumBefore
        nimFwDbgDhcpReqUdpChecksumCalc = nimFwDbgDhcpUdpChecksumCalc
        nimFwDbgDhcpReqUdpChecksumAfter = nimFwDbgDhcpUdpChecksumAfter
        nimFwDbgDhcpReqUdpChecksumVerifyBefore = nimFwDbgDhcpUdpChecksumVerifyBefore
        nimFwDbgDhcpReqUdpChecksumVerifyAfter = nimFwDbgDhcpUdpChecksumVerifyAfter
        nimFwDbgDhcpReqUdpChecksumAtCopy =
          udpChecksumFieldFromEthernet(raw, pbuf.len.uint32).uint32
    if msgType < nimFwDbgDhcpTxMsgHist.len.uint8:
      inc nimFwDbgDhcpTxMsgHist[msgType]
    nimFwDbgDhcpTxMsg =
      msgType.uint32 or
      (if pbuf.len.uint32 > 49'u32: loadBe32(raw, 46'u) shl 8 else: 0'u32)
    let rawLimit =
      if pbuf.len.uint32 < nimFwDbgDhcpTxRaw.len.uint32:
        pbuf.len.uint32
      else:
        nimFwDbgDhcpTxRaw.len.uint32
    if msgType == 3'u8 or nimFwDbgDhcpTxRawLen == 0'u32:
      nimFwDbgDhcpTxRawLen =
        if pbuf.totLen.uint32 < rawLimit: pbuf.totLen.uint32 else: rawLimit
      for i in 0 ..< nimFwDbgDhcpTxRawLen.int:
        nimFwDbgDhcpTxRaw[i] = raw[i]
      if msgType == 3'u8:
        nimFwDbgDhcpReqUdpChecksumAtCopy =
          udpChecksumFieldFromEthernet(raw, pbuf.len.uint32).uint32
    if msgType == 3'u8:
      nimFwDbgDhcpRequestTxBreakpoint()
    nimFwDbgDhcpTxBreakpoint()
