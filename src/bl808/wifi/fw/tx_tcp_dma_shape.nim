proc txlTcpDmaShape(desc: ptr HostTxDescView; link: ptr HostTxLinkDescView;
                   hw: ptr HostTxHwDescView; packet: TcpPathPacket): uint32 =
  ## Record the advertised length and separate descriptor checks. The caller
  ## has the current singleton before giving it to DMA. Never chase its links.
  const
    hwBad = 1'u32 shl 0
    frameSizeBad = 1'u32 shl 1
    headerSpanBad = 1'u32 shl 2
    bufferSpanBad = 1'u32 shl 3
    chainBad = 1'u32 shl 4
    snapBad = 1'u32 shl 5
    excessIpBytes = 1'u32 shl 6
  var problems = 0'u32
  let head = addr link.headerThd
  let payload = addr link.payloadThd[0]
  let headerStart = pointerAddrU32(addr link.macHeader[0])
  let ipStart = desc.bufferPtrs[0]
  let ipBytes = desc.bufferLens[0]
  let headerBytes = link.headerLen
  template matchesSpan(lo, hi, start, count: uint32): bool =
    lo == start and count != 0 and hi >= start and hi - start == count - 1
  if hw.magic != 0xCAFEBABE'u32 or hw.status != pointerAddrU32(head) or
      hw.chainedThd != cast[pointer](hostTxRateTemplate(link)):
    problems = problems or hwBad
  if hw.frameLen != desc.hdrLen.uint32 + desc.seqPassthrough.uint32 + desc.secTailLen.uint32 + 4:
    problems = problems or frameSizeBad
  if headerBytes != desc.hdrLen.uint32 or
      not matchesSpan(head.payloadStart, head.payloadEnd, headerStart, headerBytes):
    problems = problems or headerSpanBad
  if ipBytes != desc.seqPassthrough.uint32 or
      not matchesSpan(payload.payloadStart, payload.payloadEnd, ipStart, ipBytes):
    problems = problems or bufferSpanBad
  if head.magic != 0xCAFEFADE'u32 or payload.magic != 0xCAFEFADE'u32 or
      head.next != payload or payload.next != nil:
    problems = problems or chainBad
  const snapIpv4 = [0xAA'u8, 0xAA, 0x03, 0, 0, 0, 0x08, 0]
  # The inline view has an unchecked tail. Only inspect the three-address
  # station header (optional QoS and link header, then the eight-byte SNAP).
  let baseHeader = (if desc.staIdx == 0xFF'u8: 24'u32 else: 26'u32) + snapIpv4.len.uint32
  if headerBytes notin [baseHeader, baseHeader + 4, baseHeader + 8]:
    problems = problems or snapBad
  else:
    for i, octet in snapIpv4:
      if link.macHeader[headerBytes.int - snapIpv4.len + i] != octet:
        problems = problems or snapBad
  # A minimum-size Ethernet frame may carry padding after IPv4.
  if ipBytes > 46 and ipBytes != packet.ipv4Length.uint32:
    problems = problems or excessIpBytes
  (min(hw.frameLen, 0xFFFF'u32)) or (problems shl 16)
