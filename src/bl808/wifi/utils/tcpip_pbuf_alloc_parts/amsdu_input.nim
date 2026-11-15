const AmsduRfc1042 = [0xAA'u8, 0xAA, 3, 0, 0, 0]

proc copyAmsduBytes(p: ptr Pbuf; destination: pointer;
                    length, offset: uint16): uint16 =
  var current = p
  var skip = offset.uint32
  while current != nil and result < length:
    if skip >= current.len.uint32:
      skip -= current.len.uint32
    else:
      if current.payload == nil:
        return result
      let count = min(current.len.uint32 - skip, (length - result).uint32)
      copyMem(cast[pointer](cast[uint](destination) + result.uint),
              cast[pointer](cast[uint](current.payload) + skip.uint), count.int)
      result += count.uint16
      skip = 0
    current = current.next

proc amsduSnapPrefix(data: openArray[uint8]; bridge = false): bool =
  for i in 0 ..< 6:
    let expected = if bridge and i == 5: 0xF8'u8 else: AmsduRfc1042[i]
    if data[i] != expected:
      return false
  true

proc readAmsduSubframe(aggregate: ptr Pbuf; offset: uint32;
                      header: var array[14, uint8]; payloadLen,
                      nextOffset: var uint32): bool =
  let total = aggregate.tot_len.uint32
  if offset > total or total - offset < 14 or
      copyAmsduBytes(aggregate, addr header[0], 14, offset.uint16) != 14:
    return false
  payloadLen = (header[12].uint32 shl 8) or header[13].uint32
  if payloadLen == 0 or payloadLen > 2304 or payloadLen > total - offset - 14:
    return false
  # Reject SNAP-like destinations anywhere in an aggregate, not only first.
  if amsduSnapPrefix(header) or (header[6] and 1) != 0:
    return false
  let frameEnd = offset + 14 + payloadLen
  if frameEnd == total:
    nextOffset = total
  else:
    let padding = (4'u32 - ((14 + payloadLen) and 3)) and 3
    if total - frameEnd < padding + 14:
      return false
    nextOffset = frameEnd + padding
  true

proc inputAmsdu(aggregate: ptr Pbuf; delivery: RxNetifDelivery): cint =
  ## Takes ownership of the copied aggregate; each output has separate storage.
  if aggregate == nil:
    return -1
  defer: discard pbuf_free(aggregate)
  var header: array[14, uint8]
  var offset, payloadLen, nextOffset: uint32
  # Validate all subframe boundaries before delivering any part of the packet.
  while offset < aggregate.tot_len.uint32:
    if not readAmsduSubframe(aggregate, offset, header, payloadLen, nextOffset):
      return -1
    offset = nextOffset
  if offset == 0:
    return -1

  var scratch: array[256, uint8]
  offset = 0
  while offset < aggregate.tot_len.uint32:
    block:
      let saved = csrReadMstatus()
      disableInterrupts()
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      defer:
        {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
        if (saved and 8) != 0: enableInterrupts()
      if not rxDeliveryCurrent(delivery):
        return -1
    if not readAmsduSubframe(aggregate, offset, header, payloadLen, nextOffset):
      return -1
    var payloadOffset = offset + 14
    var snap: array[8, uint8]
    if payloadLen >= 8 and
        copyAmsduBytes(aggregate, addr snap[0], 8, payloadOffset.uint16) == 8:
      let protocol = (snap[6].uint16 shl 8) or snap[7].uint16
      let rfc1042 = amsduSnapPrefix(snap)
      let bridge = amsduSnapPrefix(snap, bridge = true)
      if (rfc1042 and protocol notin [0x8137'u16, 0x80F3'u16]) or bridge:
        header[12] = snap[6]
        header[13] = snap[7]
        payloadOffset += 8
        payloadLen -= 8
    let frame = pbuf_alloc(PbufRaw, (14 + payloadLen).uint16, PbufRam)
    if frame == nil:
      inc nimFwDbgPbufAllocFail
      return -1
    var copied = pbuf_take_at(frame, addr header[0], 14, 0) == 0
    var remaining = payloadLen
    var outputOffset = 14'u16
    while copied and remaining > 0:
      let count = min(remaining, scratch.len.uint32).uint16
      copied = copyAmsduBytes(aggregate, addr scratch[0], count,
                                 payloadOffset.uint16) == count and
        pbuf_take_at(frame, addr scratch[0], count, outputOffset) == 0
      remaining -= count.uint32
      payloadOffset += count.uint32
      outputOffset += count
    if not copied:
      inc nimFwDbgPbufTakeFail
      discard pbuf_free(frame)
      return -1
    discard noteEthernetInput(frame)
    if deliverRxPacket(frame, delivery) == rxDeliveryStale:
      return -1
    offset = nextOffset
  0
