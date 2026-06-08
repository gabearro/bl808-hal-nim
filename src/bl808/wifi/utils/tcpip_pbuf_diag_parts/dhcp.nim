## DHCP option parsing used by RX diagnostics.

proc dhcpMessageType(eth: pointer; len: uint16): uint8 =
  if len.uint <= 282'u or loadBe32(eth, 278'u) != 0x63825363'u32:
    return 0'u8
  var off = 282'u
  while off + 1 < len.uint:
    let opt = loadU8(eth, off)
    if opt == 0xff'u8:
      break
    if opt == 0'u8:
      inc off
      continue
    let optLen = loadU8(eth, off + 1)
    if off + 2'u + optLen.uint > len.uint:
      break
    if opt == 53'u8 and optLen >= 1'u8:
      return loadU8(eth, off + 2)
    off += 2'u + optLen.uint
  0'u8
