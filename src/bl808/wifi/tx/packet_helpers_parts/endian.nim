proc isDhcpUdp(eth: ptr EthernetHeaderView): bool {.inline.} =
  if eth.ethertype != 0x0008'u16:
    return false
  let ip = ipv4HeaderAt(eth)
  if ip.protocol != 17'u8:
    return false
  let udp = udpHeaderAt(ip)
  udp != nil and (udp.srcPort == 0x4400'u16 or udp.dstPort == 0x4300'u16)

proc loadBe16(packetBytes: ptr UncheckedArray[uint8]; byteOffset: uint): uint16 {.inline.} =
  (packetBytes[byteOffset].uint16 shl 8) or packetBytes[byteOffset + 1'u].uint16

proc loadBe32(packetBytes: ptr UncheckedArray[uint8]; byteOffset: uint): uint32 {.inline.} =
  (packetBytes[byteOffset].uint32 shl 24) or
    (packetBytes[byteOffset + 1'u].uint32 shl 16) or
    (packetBytes[byteOffset + 2'u].uint32 shl 8) or
    packetBytes[byteOffset + 3'u].uint32

proc storeBe16(packetBytes: ptr UncheckedArray[uint8]; byteOffset: uint;
               value: uint16) {.inline.} =
  packetBytes[byteOffset] = (value shr 8).uint8
  packetBytes[byteOffset + 1'u] = value.uint8
