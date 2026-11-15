proc allocMonitorPbuf(hwhdr, pkt: pointer; msduOffset: uint32;
                      info: var BlRxInfo): ptr Pbuf =
  # Copy the DMA-owned bytes before enabling application callbacks.
  let saved = csrReadMstatus()
  disableInterrupts()
  # CSR helpers alone do not prevent compiler reordering of ordinary loads.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    if (saved and 8) != 0:
      enableInterrupts()
  if hwhdr == nil or pkt == nil:
    return nil
  let length = loadU16(hwhdr, 0)
  if length == 0 or msduOffset >= WifiPktFragmentSize:
    return nil
  var fragments: array[WifiPktFragCount, tuple[data: pointer, length: uint16]]
  var available = 0'u32
  var ended = false
  for index in 0 ..< WifiPktFragCount:
    let fragmentLength = loadU16(pkt, WifiPktLenOff + (index * 2).uint).uint32
    if fragmentLength == 0:
      ended = true
      continue
    if ended or fragmentLength > WifiPktFragmentSize:
      return nil
    let data = cast[pointer](loadU32(pkt, WifiPktPktOff + (index * 4).uint).uint)
    if data == nil:
      return nil
    let offset = if index == 0: msduOffset else: 0'u32
    if offset >= fragmentLength:
      return nil
    fragments[index] = (ptrAt(data, offset.uint), (fragmentLength - offset).uint16)
    available += fragmentLength - offset
  if length.uint32 > available:
    return nil
  info.rssi = cast[int8](loadU8(hwhdr, 23))
  info.legRate = ((loadU16(hwhdr, 12) shr 12) and 15).uint8
  info.formatMod = (loadU8(hwhdr, 18) and 7).uint8
  result = pbuf_alloc(PbufRaw, length, PbufRam)
  if result == nil:
    return nil
  if result.payload == nil or result.next != nil or
      result.len != length or result.tot_len != length:
    discard pbuf_free(result)
    return nil
  var copied = 0'u16
  for fragment in fragments:
    let count = min(fragment.length, length - copied)
    if count != 0 and pbuf_take_at(result, fragment.data, count, copied) != 0:
      discard pbuf_free(result)
      return nil
    copied += count
    if copied == length:
      break

proc inputMonitorFrame(hwhdr, pkt: pointer; msduOffset: uint32;
                       lease: ptr firmware.RxHostLease = nil): cint =
  inc nimFwDbgTcpipInputMpdu
  var info: BlRxInfo
  let packet = block:
    let saved = csrReadMstatus()
    disableInterrupts()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    defer:
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      if (saved and 8) != 0: enableInterrupts()
    if lease != nil and not firmware.rxHostLeaseCurrent(lease[]):
      return -1
    allocMonitorPbuf(hwhdr, pkt, msduOffset, info)
  if packet == nil:
    inc nimFwDbgMonitorInputFail
    return -1
  # Both monitor callbacks borrow this pbuf. An advanced consumer may retain
  # it with pbuf_ref; the driver's reference is always released on return.
  defer: discard pbuf_free(packet)
  if lease != nil and not firmware.rxHostLeaseCurrent(lease[]):
    return -1
  bl_rx_pkt_cb(cast[ptr uint8](packet.payload), packet.tot_len.cint,
               cast[pointer](packet), addr info)
  inc nimFwDbgMonitorInputOk
  0
