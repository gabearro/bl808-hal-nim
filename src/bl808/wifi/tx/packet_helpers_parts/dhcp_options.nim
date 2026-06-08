proc dhcpMsgTypeFromEthernet(raw: ptr UncheckedArray[uint8]; len: uint32): uint8 =
  if len <= 282'u32 or loadBe32(raw, 278'u) != 0x63825363'u32:
    return 0'u8
  var off = 282'u
  while off + 1'u < len.uint:
    let opt = raw[off]
    if opt == 0xff'u8:
      break
    if opt == 0'u8:
      inc off
      continue
    let optLen = raw[off + 1'u]
    if off + 2'u + optLen.uint > len.uint:
      break
    if opt == 53'u8 and optLen >= 1'u8:
      return raw[off + 2'u]
    off += 2'u + optLen.uint
  0'u8
