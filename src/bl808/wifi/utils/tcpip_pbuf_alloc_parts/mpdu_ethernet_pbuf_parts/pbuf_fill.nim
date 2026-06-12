proc freeFailedMpduPbuf(pbuf: ptr Pbuf; reason: uint32): ptr Pbuf =
  inc nimFwDbgPbufTakeFail
  noteMpduFail(reason)
  discard pbuf_free(pbuf)
  nil

proc allocAndFillMpduEthernetPbuf(pkt: pointer; view: MpduEthernetView;
                                  ethHdr: var array[14, uint8]): ptr Pbuf =
  let totalLen = view.totalLen
  result = pbuf_alloc(PbufRaw, totalLen.uint16, PbufRam)
  if result == nil:
    inc nimFwDbgPbufAllocFail
    noteMpduFail(6)
    return nil
  if pbuf_take_at(result, addr ethHdr[0], 14'u16, 0'u16) != 0'i8:
    return freeFailedMpduPbuf(result, 7)

  var pbufOff = 14'u16
  if view.firstPayloadLen != 0:
    let firstPayload = ptrAt(view.frame, view.payloadStart.uint)
    if pbuf_take_at(result, firstPayload, view.firstPayloadLen.uint16,
                    pbufOff) != 0'i8:
      return freeFailedMpduPbuf(result, 8)
    pbufOff = uint16(pbufOff.uint32 + view.firstPayloadLen)
  for wifiPacketFragmentIndex in 1 ..< WifiPktFragCount:
    let fragLen = loadU16(pkt, WifiPktLenOff + uint(wifiPacketFragmentIndex * 2))
    if fragLen == 0'u16:
      break
    let fragPayload = cast[pointer](loadU32(pkt, WifiPktPktOff + uint(wifiPacketFragmentIndex * 4)).uint)
    if pbuf_take_at(result, fragPayload, fragLen, pbufOff) != 0'i8:
      return freeFailedMpduPbuf(result, 8)
    pbufOff = uint16(pbufOff.uint32 + fragLen.uint32)
  nimFwDbgTcpipInputMpduFail = 0
