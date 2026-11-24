proc noteDhcpTx(txPbufView: ptr PbufView; ethernetHeader: ptr EthernetHeaderView; etherType: uint16) =
  if etherType != 0x0008'u16: return
  let dhcp = parseDhcpWire(txPbufView.payload, txPbufView.len.uint, txPbufView.totLen.uint, false)
  if not dhcp.present: return
  let ipv4Header = ipv4HeaderAt(ethernetHeader)
  let udpHeader = udpHeaderAt(ipv4Header)
  inc nimFwDbgDhcpTx
  nimFwDbgDhcpTxEth = etherType.uint32 or (ipv4Header.protocol.uint32 shl 16)
  nimFwDbgDhcpTxPorts = udpHeader.srcPort.uint32 or (udpHeader.dstPort.uint32 shl 16)
  nimFwDbgDhcpTxLen = txPbufView.totLen.uint32
  let src = ethernetHeader.src
  nimFwDbgDhcpTxSrcLo = src[0].uint32 or (src[1].uint32 shl 8) or
    (src[2].uint32 shl 16) or (src[3].uint32 shl 24)
  nimFwDbgDhcpTxSrcHi = src[4].uint32 or (src[5].uint32 shl 8)
  let ethernetFrameBytes = cast[ptr UncheckedArray[uint8]](txPbufView.payload)
  let msgType = dhcp.kind
  if msgType != 0'u8:
    let inspected = observeDhcpUdpChecksum(ethernetFrameBytes, txPbufView.len.uint32)
    if msgType == 3'u8:
      let field = udpChecksumFieldFromEthernet(ethernetFrameBytes, txPbufView.len.uint32).uint32
      # An incomplete first pbuf still exposes the field, but cannot verify it.
      const Unavailable = high(uint32)
      nimFwDbgDhcpReqUdpChecksumBefore = field
      nimFwDbgDhcpReqUdpChecksumAfter = field
      nimFwDbgDhcpReqUdpChecksumAtCopy = field
      nimFwDbgDhcpReqUdpChecksumCalc = if inspected: nimFwDbgDhcpUdpChecksumCalc else: Unavailable
      nimFwDbgDhcpReqUdpChecksumVerifyBefore =
        if inspected: nimFwDbgDhcpUdpChecksumVerifyBefore else: Unavailable
      nimFwDbgDhcpReqUdpChecksumVerifyAfter = nimFwDbgDhcpReqUdpChecksumVerifyBefore
  if msgType.int < nimFwDbgDhcpTxMsgHist.len:
    inc nimFwDbgDhcpTxMsgHist[msgType]
  nimFwDbgDhcpTxMsg = msgType.uint32 or (dhcp.xid shl 8)
  if msgType == 3'u8 or nimFwDbgDhcpTxRawLen == 0'u32:
    nimFwDbgDhcpTxRawLen = min(txPbufView.len.uint32, nimFwDbgDhcpTxRaw.len.uint32)
    for dhcpTxRawByteIndex in 0 ..< nimFwDbgDhcpTxRawLen.int:
      nimFwDbgDhcpTxRaw[dhcpTxRawByteIndex] =
        ethernetFrameBytes[dhcpTxRawByteIndex]
  if msgType == 3'u8:
    nimFwDbgDhcpRequestTxBreakpoint()
  nimFwDbgDhcpTxBreakpoint()
