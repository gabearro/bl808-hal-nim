proc allocFramePbuf(msduOffset: uint32; pkt: pointer): ptr Pbuf =
  if pkt == nil:
    return nil
  let firstLen = loadU16(pkt, WifiPktLenOff)
  if firstLen.uint32 <= msduOffset:
    return nil
  let firstPayload = cast[pointer](loadU32(pkt, WifiPktPktOff).uint + msduOffset)
  let firstPayloadLen = uint16(firstLen.uint32 - msduOffset)
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

  for wifiPacketFragmentIndex in 1 ..< WifiPktFragCount:
    let fragLen = loadU16(pkt, WifiPktLenOff + uint(wifiPacketFragmentIndex * 2))
    if fragLen == 0'u16:
      break
    let fragPayload = cast[pointer](loadU32(pkt, WifiPktPktOff + uint(wifiPacketFragmentIndex * 4)).uint)
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
