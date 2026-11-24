## Bounded DHCP identity for diagnostics; this is not the DHCP receiver.

const DhcpTracePrefixSize* = 384

type DhcpWireTrace* = object
  present*, xidValid*: bool
  xid*: uint32
  kind*: uint8

proc parseDhcpWire*(frame: pointer; available, wireLen: uint;
                    reply: bool): DhcpWireTrace =
  let limit = min(min(available, wireLen), DhcpTracePrefixSize.uint)
  if frame == nil or limit < 42: return
  let b = cast[ptr UncheckedArray[uint8]](frame)
  template be16(i: uint): uint = (b[i].uint shl 8) or b[i + 1].uint
  if be16(12) != 0x0800 or (b[14] shr 4) != 4 or b[23] != 17 or
      (be16(20) and 0x3FFF) != 0:
    return
  let ihl = (b[14] and 15).uint * 4
  let total = be16(16)
  let udp = 14 + ihl
  if ihl < 20 or limit < udp + 8 or total < ihl + 8 or total > wireLen - 14:
    return
  let udpLen = be16(udp + 4)
  let clientPort = if reply: udp + 2 else: udp
  let serverPort = if reply: udp else: udp + 2
  if udpLen < 8 or udpLen > total - ihl or
      be16(clientPort) != 68 or be16(serverPort) != 67:
    return
  result.present = true
  let bootp = udp + 8
  let endAt = min(udp + udpLen, limit)
  var option = bootp + 240
  if endAt < option or b[bootp] != (if reply: 2 else: 1) or
      be16(bootp + 236) != 0x6382 or be16(bootp + 238) != 0x5363:
    return
  result.xidValid = true
  result.xid = (be16(bootp + 4).uint32 shl 16) or be16(bootp + 6).uint32
  while option < endAt:
    let code = b[option]
    inc option
    if code == 255: return
    if code == 0: continue
    if option == endAt: return
    let len = b[option].uint
    inc option
    if len > endAt - option: return
    if code == 53 and len == 1:
      result.kind = b[option]
      return
    option += len
