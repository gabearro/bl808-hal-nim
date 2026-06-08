proc isDhcpUdp(eth: ptr EthernetHeaderView): bool {.inline.} =
  if eth.ethertype != 0x0008'u16:
    return false
  let ip = ipv4HeaderAt(eth)
  if ip.protocol != 17'u8:
    return false
  let udp = udpHeaderAt(ip)
  udp != nil and (udp.srcPort == 0x4400'u16 or udp.dstPort == 0x4300'u16)

proc loadBe16(p: ptr UncheckedArray[uint8]; off: uint): uint16 {.inline.} =
  (p[off].uint16 shl 8) or p[off + 1'u].uint16

proc loadBe32(p: ptr UncheckedArray[uint8]; off: uint): uint32 {.inline.} =
  (p[off].uint32 shl 24) or (p[off + 1'u].uint32 shl 16) or
    (p[off + 2'u].uint32 shl 8) or p[off + 3'u].uint32

proc storeBe16(p: ptr UncheckedArray[uint8]; off: uint; value: uint16) {.inline.} =
  p[off] = (value shr 8).uint8
  p[off + 1'u] = value.uint8
