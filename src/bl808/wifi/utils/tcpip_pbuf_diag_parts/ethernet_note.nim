## Ethernet, ARP, IPv4, UDP, TCP, and DHCP RX classification diagnostics.

proc noteEthernetInput(p: ptr Pbuf): bool =
  if p == nil or p.payload == nil or p.len < 14'u16:
    return false
  let eth = p.payload
  let etherType = loadBe16(eth, 12)
  nimFwDbgTcpipInputFramePbuf0 = loadLe32Bytes(eth, 0)
  nimFwDbgTcpipInputFramePbuf1 = loadLe32Bytes(eth, 4)
  nimFwDbgTcpipInputFramePbuf2 = loadLe32Bytes(eth, 8)
  nimFwDbgTcpipInputFramePbuf3 = loadLe32Bytes(eth, 12)
  nimFwDbgTcpipInputFrameEthType = etherType.uint32 or (p.len.uint32 shl 16)
  case etherType
  of 0x0800'u16:
    nimFwDbgTcpipInputEth += 1
    result = true
    if p.len >= 34'u16:
      nimFwDbgTcpipInputLastIp =
        loadU8(eth, 26).uint32 or
        (loadU8(eth, 27).uint32 shl 8) or
        (loadU8(eth, 30).uint32 shl 16) or
        (loadU8(eth, 31).uint32 shl 24)
      let ihl = (loadU8(eth, 14) and 0x0F'u8).uint32 * 4'u32
      let l4Off = 14'u32 + ihl
      if ihl >= 20'u32 and l4Off + 4'u32 <= p.len.uint32:
        if loadU8(eth, 23) == 6'u8:
          inc nimFwDbgTcpipInputTcp
          let srcPort = loadBe16(eth, l4Off.uint)
          let dstPort = loadBe16(eth, l4Off.uint + 2'u)
          nimFwDbgTcpipInputLastPorts = srcPort.uint32 or (dstPort.uint32 shl 16)
          if l4Off + 14'u32 < p.len.uint32:
            nimFwDbgTcpipInputTcpFlags =
              loadU8(eth, l4Off.uint + 13'u).uint32 or
              (srcPort.uint32 shl 8) or
              (dstPort.uint32 shl 24)
          if dstPort == 80'u16 or srcPort == 80'u16:
            inc nimFwDbgTcpipInputTcp80
        elif loadU8(eth, 23) == 17'u8 and l4Off + 8'u32 <= p.len.uint32:
          nimFwDbgTcpipInputUdp += 1
          let srcPort = loadBe16(eth, l4Off.uint)
          let dstPort = loadBe16(eth, l4Off.uint + 2'u)
          nimFwDbgTcpipInputLastPorts = srcPort.uint32 or (dstPort.uint32 shl 16)
          if srcPort == 67'u16 and dstPort == 68'u16:
            inc nimFwDbgTcpipInputDhcpRx
            if p.len >= 282'u16:
              let msgType = dhcpMessageType(eth, p.len)
              nimFwDbgTcpipInputDhcpMeta =
                loadU8(eth, 42).uint32 or
                (loadU8(eth, 44).uint32 shl 8) or
                (msgType.uint32 shl 16) or
                (loadBe16(eth, 52).uint32 shl 24)
              nimFwDbgTcpipInputDhcpXid = loadBe32(eth, 46)
              nimFwDbgTcpipInputDhcpYiaddr = loadBe32(eth, 58)
              nimFwDbgTcpipInputDhcpCh0 = loadBe32(eth, 70)
              nimFwDbgTcpipInputDhcpCh1 = loadBe16(eth, 74).uint32
  of 0x0806'u16:
    inc nimFwDbgTcpipInputArp
    nimFwDbgTcpipInputEth += 1'u32 shl 8
    result = true
  else:
    nimFwDbgTcpipInputEth += 1'u32 shl 16
    result = false
