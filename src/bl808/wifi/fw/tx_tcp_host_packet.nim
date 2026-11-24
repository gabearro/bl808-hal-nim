proc txlObserveTcpHostPacket(desc: ptr HostTxDescView): TcpPathPacket =
  if txlHostSlot(desc) < 0:
    return
  # txPush places the single payload after the slot's ownership word,
  # 48-byte host encapsulation and 14-byte Ethernet header.
  const
    ethernetLength = 14'u
    ipv4Offset = 4'u + 48'u + ethernetLength
  let pool = cast[uint](addr ipcSharedEnv[0]) + SharedTxbufOff
  let ip = desc.bufferPtrs[0].uint
  let length = desc.bufferLens[0].uint
  let slotOffset = ip - pool
  if slotOffset div SharedTxbufSize >= txRateSampleTag.len.uint or
      slotOffset mod SharedTxbufSize != ipv4Offset or
      length != desc.seqPassthrough.uint or length > SharedTxbufSize - ipv4Offset:
    return
  let packet = observeTcpPath(cast[pointer](ip - ethernetLength),
    length + ethernetLength, length + ethernetLength)
  if (packet.ports and 0xFFFF) == WifiTcpPathPort.uint32 and
      packet.ports shr 16 notin [0'u32, WifiTcpPathPort.uint32]:
    return packet
