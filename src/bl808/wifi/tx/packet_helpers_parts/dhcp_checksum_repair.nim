proc repairDhcpUdpChecksum(raw: ptr UncheckedArray[uint8]; len: uint32): uint8 =
  const IpOff = 14'u
  if len < 42'u32 or loadBe16(raw, 12'u) != 0x0800'u16:
    return 0'u8
  let versionIhl = raw[IpOff]
  if (versionIhl shr 4) != 4'u8 or raw[IpOff + 9'u] != 17'u8:
    return 0'u8
  let ihl = (versionIhl and 0x0f'u8).uint * 4'u
  if ihl < 20'u or len.uint < IpOff + ihl + 8'u:
    return 0'u8
  let udpOff = IpOff + ihl
  let srcPort = loadBe16(raw, udpOff)
  let dstPort = loadBe16(raw, udpOff + 2'u)
  if not ((srcPort == 68'u16 and dstPort == 67'u16) or
          (srcPort == 67'u16 and dstPort == 68'u16)):
    return 0'u8
  let udpLen = loadBe16(raw, udpOff + 4'u)
  if udpLen < 8'u16 or len.uint < udpOff + udpLen.uint:
    return 0'u8
  let before = loadBe16(raw, udpOff + 6'u)
  let verifyBefore = verifyUdpPacket(raw, IpOff, udpOff, udpLen)
  let calc = checksumUdpPacket(raw, IpOff, udpOff, udpLen, true)
  storeBe16(raw, udpOff + 6'u, calc)
  let verifyAfter = verifyUdpPacket(raw, IpOff, udpOff, udpLen)
  inc nimFwDbgDhcpUdpChecksumRepair
  nimFwDbgDhcpUdpChecksumBefore = before.uint32
  nimFwDbgDhcpUdpChecksumCalc = calc.uint32
  nimFwDbgDhcpUdpChecksumAfter = loadBe16(raw, udpOff + 6'u).uint32
  nimFwDbgDhcpUdpChecksumVerifyBefore = verifyBefore.uint32
  nimFwDbgDhcpUdpChecksumVerifyAfter = verifyAfter.uint32
  1'u8

proc udpChecksumFieldFromEthernet(raw: ptr UncheckedArray[uint8]; len: uint32): uint16 =
  const IpOff = 14'u
  if len < 42'u32 or loadBe16(raw, 12'u) != 0x0800'u16:
    return 0'u16
  let versionIhl = raw[IpOff]
  if (versionIhl shr 4) != 4'u8:
    return 0'u16
  let ihl = (versionIhl and 0x0f'u8).uint * 4'u
  if ihl < 20'u or len.uint < IpOff + ihl + 8'u:
    return 0'u16
  loadBe16(raw, IpOff + ihl + 6'u)
