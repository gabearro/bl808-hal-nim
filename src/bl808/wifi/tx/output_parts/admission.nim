proc txPbufAdmissible(packet: pointer): bool =
  let first = pbufView(packet)
  if first == nil or first.len < EthHdrSize or
      first.totLen < EthHdrSize or
      first.totLen > TxBufferPayloadSize - PbufLinkEncapsulationHlen:
    return false
  var remaining = first.totLen.uint32
  var current = packet
  var slow = packet
  var advanceSlow = false
  while current != nil:
    let segment = pbufView(current)
    if segment.totLen.uint32 != remaining or segment.len.uint32 > remaining or
        (segment.len != 0 and segment.payload == nil):
      return false
    remaining -= segment.len.uint32
    current = segment.next
    # A slower cursor catches cycles even when zero-length segments occur.
    if advanceSlow:
      slow = pbufView(slow).next
    advanceSlow = not advanceSlow
    if current != nil and current == slow:
      return false
  remaining == 0
