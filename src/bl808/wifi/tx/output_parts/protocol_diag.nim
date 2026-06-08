proc noteTxProtocol(pbuf: ptr PbufView; eth: ptr EthernetHeaderView; proto: uint16) =
  if proto == 0x0608'u16:
    inc nimFwDbgTxArp
  elif proto == 0x0008'u16 and pbuf.len.uint32 >= 42'u32:
    let raw = cast[ptr UncheckedArray[uint8]](pbuf.payload)
    let ihl = (raw[14] and 0x0F'u8).uint32 * 4'u32
    let l4Off = 14'u32 + ihl
    if ihl >= 20'u32 and l4Off + 8'u32 <= pbuf.len.uint32 and raw[23] == 17'u8:
      let srcPort = loadBe16(raw, l4Off)
      let dstPort = loadBe16(raw, l4Off + 2'u32)
      inc nimFwDbgTxUdp
      nimFwDbgTxUdpPorts = srcPort.uint32 or (dstPort.uint32 shl 16)
      nimFwDbgTxUdpIp =
        raw[26].uint32 or (raw[27].uint32 shl 8) or
        (raw[30].uint32 shl 16) or (raw[31].uint32 shl 24)
      if srcPort == 65001'u16 or dstPort == 65001'u16:
        inc nimFwDbgTxUdpProbe
    elif ihl >= 20'u32 and l4Off + 14'u32 < pbuf.len.uint32 and raw[23] == 6'u8:
      let srcPort = loadBe16(raw, l4Off)
      let dstPort = loadBe16(raw, l4Off + 2'u32)
      inc nimFwDbgTxTcp
      nimFwDbgTxTcpFlags =
        raw[l4Off + 13'u32].uint32 or
        (srcPort.uint32 shl 8) or
        (dstPort.uint32 shl 24)
      if srcPort == 80'u16 or dstPort == 80'u16:
        inc nimFwDbgTxTcp80
