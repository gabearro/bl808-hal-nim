proc dhcpMsgTypeFromEthernet(ethernetFrameBytes: ptr UncheckedArray[uint8]; ethernetFrameLength: uint32): uint8 =
  if ethernetFrameLength <= 282'u32 or loadBe32(ethernetFrameBytes, 278'u) != 0x63825363'u32:
    return 0'u8
  var dhcpOptionOffset = 282'u
  while dhcpOptionOffset + 1'u < ethernetFrameLength.uint:
    let dhcpOptionCode = ethernetFrameBytes[dhcpOptionOffset]
    if dhcpOptionCode == 0xff'u8:
      break
    if dhcpOptionCode == 0'u8:
      inc dhcpOptionOffset
      continue
    let dhcpOptionLength = ethernetFrameBytes[dhcpOptionOffset + 1'u]
    if dhcpOptionOffset + 2'u + dhcpOptionLength.uint > ethernetFrameLength.uint:
      break
    if dhcpOptionCode == 53'u8 and dhcpOptionLength >= 1'u8:
      return ethernetFrameBytes[dhcpOptionOffset + 2'u]
    dhcpOptionOffset += 2'u + dhcpOptionLength.uint
  0'u8
