proc observeDhcpUdpChecksum(ethernetFrameBytes: ptr UncheckedArray[uint8];
                            ethernetFrameLength: uint32): bool =
  const IpOff = 14'u
  if ethernetFrameLength < 42'u32 or loadBe16(ethernetFrameBytes, 12'u) != 0x0800'u16:
    return false
  let versionIhl = ethernetFrameBytes[IpOff]
  if (versionIhl shr 4) != 4'u8 or ethernetFrameBytes[IpOff + 9'u] != 17'u8:
    return false
  let ipHeaderLength = (versionIhl and 0x0f'u8).uint * 4'u
  if ipHeaderLength < 20'u or ethernetFrameLength.uint < IpOff + ipHeaderLength + 8'u:
    return false
  let udpHeaderOffset = IpOff + ipHeaderLength
  let srcPort = loadBe16(ethernetFrameBytes, udpHeaderOffset)
  let dstPort = loadBe16(ethernetFrameBytes, udpHeaderOffset + 2'u)
  if not ((srcPort == 68'u16 and dstPort == 67'u16) or
          (srcPort == 67'u16 and dstPort == 68'u16)):
    return false
  let udpLen = loadBe16(ethernetFrameBytes, udpHeaderOffset + 4'u)
  if udpLen < 8'u16 or ethernetFrameLength.uint < udpHeaderOffset + udpLen.uint:
    return false
  # lwIP owns the packet. Keep the historical before/after fields equal.
  let inputChecksum = loadBe16(ethernetFrameBytes, udpHeaderOffset + 6'u).uint32
  let verification = verifyUdpPacket(ethernetFrameBytes, IpOff, udpHeaderOffset, udpLen).uint32
  nimFwDbgDhcpUdpChecksumBefore = inputChecksum
  nimFwDbgDhcpUdpChecksumCalc = checksumUdpPacket(ethernetFrameBytes, IpOff,
                                                 udpHeaderOffset, udpLen, true).uint32
  nimFwDbgDhcpUdpChecksumAfter = inputChecksum
  nimFwDbgDhcpUdpChecksumVerifyBefore = verification
  nimFwDbgDhcpUdpChecksumVerifyAfter = verification
  true

proc udpChecksumFieldFromEthernet(ethernetFrameBytes: ptr UncheckedArray[uint8];
                                  ethernetFrameLength: uint32): uint16 =
  const IpOff = 14'u
  if ethernetFrameLength < 42'u32 or loadBe16(ethernetFrameBytes, 12'u) != 0x0800'u16:
    return 0'u16
  let versionIhl = ethernetFrameBytes[IpOff]
  if (versionIhl shr 4) != 4'u8:
    return 0'u16
  let ipHeaderLength = (versionIhl and 0x0f'u8).uint * 4'u
  if ipHeaderLength < 20'u or ethernetFrameLength.uint < IpOff + ipHeaderLength + 8'u:
    return 0'u16
  loadBe16(ethernetFrameBytes, IpOff + ipHeaderLength + 6'u)
