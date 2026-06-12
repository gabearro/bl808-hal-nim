## DHCP option parsing used by RX diagnostics.

proc dhcpMessageType(ethernetFrame: pointer; ethernetFrameLength: uint16): uint8 =
  if ethernetFrameLength.uint <= 282'u or loadBe32(ethernetFrame, 278'u) != 0x63825363'u32:
    return 0'u8
  var dhcpOptionOffset = 282'u
  while dhcpOptionOffset + 1 < ethernetFrameLength.uint:
    let dhcpOptionCode = loadU8(ethernetFrame, dhcpOptionOffset)
    if dhcpOptionCode == 0xff'u8:
      break
    if dhcpOptionCode == 0'u8:
      inc dhcpOptionOffset
      continue
    let dhcpOptionLength = loadU8(ethernetFrame, dhcpOptionOffset + 1)
    if dhcpOptionOffset + 2'u + dhcpOptionLength.uint > ethernetFrameLength.uint:
      break
    if dhcpOptionCode == 53'u8 and dhcpOptionLength >= 1'u8:
      return loadU8(ethernetFrame, dhcpOptionOffset + 2)
    dhcpOptionOffset += 2'u + dhcpOptionLength.uint
  0'u8
