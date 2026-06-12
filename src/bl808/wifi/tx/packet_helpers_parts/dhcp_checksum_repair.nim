proc repairDhcpUdpChecksum(ethernetFrameBytes: ptr UncheckedArray[uint8];
                           ethernetFrameLength: uint32): uint8 =
  const IpOff = 14'u
  if ethernetFrameLength < 42'u32 or loadBe16(ethernetFrameBytes, 12'u) != 0x0800'u16:
    return 0'u8
  let versionIhl = ethernetFrameBytes[IpOff]
  if (versionIhl shr 4) != 4'u8 or ethernetFrameBytes[IpOff + 9'u] != 17'u8:
    return 0'u8
  let ipHeaderLength = (versionIhl and 0x0f'u8).uint * 4'u
  if ipHeaderLength < 20'u or ethernetFrameLength.uint < IpOff + ipHeaderLength + 8'u:
    return 0'u8
  let udpHeaderOffset = IpOff + ipHeaderLength
  let srcPort = loadBe16(ethernetFrameBytes, udpHeaderOffset)
  let dstPort = loadBe16(ethernetFrameBytes, udpHeaderOffset + 2'u)
  if not ((srcPort == 68'u16 and dstPort == 67'u16) or
          (srcPort == 67'u16 and dstPort == 68'u16)):
    return 0'u8
  let udpLen = loadBe16(ethernetFrameBytes, udpHeaderOffset + 4'u)
  if udpLen < 8'u16 or ethernetFrameLength.uint < udpHeaderOffset + udpLen.uint:
    return 0'u8
  let checksumBeforeRepair = loadBe16(ethernetFrameBytes, udpHeaderOffset + 6'u)
  let verifyBefore = verifyUdpPacket(ethernetFrameBytes, IpOff, udpHeaderOffset, udpLen)
  let repairedChecksum = checksumUdpPacket(ethernetFrameBytes, IpOff, udpHeaderOffset, udpLen, true)
  storeBe16(ethernetFrameBytes, udpHeaderOffset + 6'u, repairedChecksum)
  let verifyAfter = verifyUdpPacket(ethernetFrameBytes, IpOff, udpHeaderOffset, udpLen)
  inc nimFwDbgDhcpUdpChecksumRepair
  nimFwDbgDhcpUdpChecksumBefore = checksumBeforeRepair.uint32
  nimFwDbgDhcpUdpChecksumCalc = repairedChecksum.uint32
  nimFwDbgDhcpUdpChecksumAfter = loadBe16(ethernetFrameBytes, udpHeaderOffset + 6'u).uint32
  nimFwDbgDhcpUdpChecksumVerifyBefore = verifyBefore.uint32
  nimFwDbgDhcpUdpChecksumVerifyAfter = verifyAfter.uint32
  1'u8

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
