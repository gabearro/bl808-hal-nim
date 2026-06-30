type MpduEthernetView = object
  frame: pointer
  snap: pointer
  firstLen: uint32
  macLen: uint32
  snapOffset: uint32
  payloadStart: uint32
  firstPayloadLen: uint32
  totalLen: uint32
  frameControl: uint16

proc findUploadSnapOffset(frame: pointer; frameAvail, preferredOffset: uint32): uint32 =
  if preferredOffset + 8'u32 <= frameAvail:
    let snap = ptrAt(frame, preferredOffset.uint)
    if loadU8(snap, 0) == 0xAA'u8 and loadU8(snap, 1) == 0xAA'u8 and
        loadU8(snap, 2) == 0x03'u8 and loadU8(snap, 3) == 0'u8 and
        loadU8(snap, 4) == 0'u8 and
        (loadU8(snap, 5) == 0'u8 or loadU8(snap, 5) == 0xF8'u8):
      return preferredOffset

  var offset = 24'u32
  while offset + 8'u32 <= frameAvail and offset <= 72'u32:
    let snap = ptrAt(frame, offset.uint)
    if loadU8(snap, 0) == 0xAA'u8 and loadU8(snap, 1) == 0xAA'u8 and
        loadU8(snap, 2) == 0x03'u8 and loadU8(snap, 3) == 0'u8 and
        loadU8(snap, 4) == 0'u8 and
        (loadU8(snap, 5) == 0'u8 or loadU8(snap, 5) == 0xF8'u8):
      return offset
    inc offset

  preferredOffset

proc loadMpduEthernetView(msduOffset: uint32; pkt: pointer;
                          view: var MpduEthernetView): bool =
  if pkt == nil:
    noteMpduFail(1)
    return false
  let firstLen = loadU16(pkt, WifiPktLenOff).uint32
  view.firstLen = firstLen
  nimFwDbgTcpipInputMpduLast0 = firstLen or (msduOffset shl 16)
  if firstLen == 0:
    noteMpduFail(2)
    return false
  if firstLen <= msduOffset:
    noteMpduFail(3)
    return false
  let frame = cast[pointer](loadU32(pkt, WifiPktPktOff).uint + msduOffset)
  view.frame = frame
  let frameAvail = firstLen - msduOffset
  if frameAvail < 32:
    noteMpduFail(3)
    return false

  let fc = loadU16(frame, 0)
  view.frameControl = fc
  let macLen = macDataHeaderLen(fc)
  view.macLen = macLen
  nimFwDbgTcpipInputMpduLast1 = fc.uint32 or (macLen shl 16)
  if frameAvail < macLen + 8:
    noteMpduFail(4)
    return false

  let snapOffset = findUploadSnapOffset(frame, frameAvail, macLen)
  view.snapOffset = snapOffset
  let snap = ptrAt(frame, snapOffset.uint)
  view.snap = snap
  nimFwDbgTcpipInputMpduLast2 = loadU8(snap, 0).uint32 or
    (loadU8(snap, 1).uint32 shl 8) or
    (loadU8(snap, 2).uint32 shl 16) or
    (loadU8(snap, 3).uint32 shl 24)
  if loadU8(snap, 0) != 0xAA'u8 or loadU8(snap, 1) != 0xAA'u8 or
      loadU8(snap, 2) != 0x03'u8 or loadU8(snap, 3) != 0'u8 or
      loadU8(snap, 4) != 0'u8 or loadU8(snap, 5) != 0'u8:
    noteMpduFail(5)
    return false

  let payloadStart = snapOffset + 8
  view.payloadStart = payloadStart
  let firstPayloadLen = firstLen - payloadStart
  view.firstPayloadLen = firstPayloadLen
  var totalLen = 14'u32 + firstPayloadLen
  for wifiPacketFragmentIndex in 1 ..< WifiPktFragCount:
    let fragLen =
      loadU16(pkt, WifiPktLenOff + uint(wifiPacketFragmentIndex * 2)).uint32
    if fragLen == 0:
      break
    totalLen += fragLen
  view.totalLen = totalLen
  if totalLen > 0xffff'u32:
    noteMpduFail(6)
    return false
  true
