proc allocFramePbuf(msduOffset: uint32; pkt: pointer): ptr Pbuf =
  if pkt == nil:
    return nil
  let saved = csrReadMstatus()
  disableInterrupts()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    if (saved and 8) != 0:
      enableInterrupts()
  if msduOffset >= WifiPktFragmentSize:
    return nil
  var fragments: array[WifiPktFragCount, tuple[data: pointer, length: uint16]]
  var ended = false
  for index in 0 ..< WifiPktFragCount:
    let fragmentLength = loadU16(pkt, WifiPktLenOff + (index * 2).uint).uint32
    if fragmentLength == 0:
      if index == 0:
        return nil
      ended = true
      continue
    if ended or fragmentLength > WifiPktFragmentSize:
      return nil
    let address = loadU32(pkt, WifiPktPktOff + (index * 4).uint)
    if address == 0 or address > high(uint32) - (fragmentLength - 1):
      return nil
    let offset = if index == 0: msduOffset else: 0'u32
    if offset >= fragmentLength:
      return nil
    fragments[index] = (cast[pointer](address.uint + offset.uint),
                        (fragmentLength - offset).uint16)

  # Diagnostics and copies use only validated DMA ranges while IRQs are masked.
  noteUploadScan(pkt, msduOffset)
  let firstLen = loadU16(pkt, WifiPktLenOff)
  let firstPayload = fragments[0].data
  let firstPayloadLen = fragments[0].length
  nimFwDbgTcpipInputFrameLast1 = firstPayloadLen.uint32 or (firstLen.uint32 shl 16)
  if firstPayloadLen >= 16'u16:
    nimFwDbgTcpipInputFrameSrc0 = loadLe32Bytes(firstPayload, 0)
    nimFwDbgTcpipInputFrameSrc1 = loadLe32Bytes(firstPayload, 4)
    nimFwDbgTcpipInputFrameSrc2 = loadLe32Bytes(firstPayload, 8)
    nimFwDbgTcpipInputFrameSrc3 = loadLe32Bytes(firstPayload, 12)
  result = pbuf_alloc(PbufRaw, firstPayloadLen, PbufRam)
  if result == nil:
    inc nimFwDbgPbufAllocFail
    return nil
  if pbuf_take(result, firstPayload, firstPayloadLen) != 0'i8:
    inc nimFwDbgPbufTakeFail
    discard pbuf_free(result)
    return nil

  for index in 1 ..< WifiPktFragCount:
    let fragLen = fragments[index].length
    if fragLen == 0'u16:
      break
    let fragPayload = fragments[index].data
    let frag = pbuf_alloc(PbufRaw, fragLen, PbufRam)
    if frag == nil:
      inc nimFwDbgPbufAllocFail
      discard pbuf_free(result)
      return nil
    if pbuf_take(frag, fragPayload, fragLen) != 0'i8:
      inc nimFwDbgPbufTakeFail
      discard pbuf_free(frag)
      discard pbuf_free(result)
      return nil
    pbuf_cat(result, frag)
