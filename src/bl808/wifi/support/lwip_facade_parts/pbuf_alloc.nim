when not defined(bl808WifiRealLwip):
  proc pbuf_alloc*(layer: PbufLayer; length: uint16; ptype: PbufType): ptr Pbuf {.exportc, cdecl.} =
    discard layer; discard ptype
    let mem = c_calloc(1, PbufSize.csize_t + PbufDefaultHeadroom.csize_t + length.csize_t)
    if mem == nil: return nil
    storePtr(mem, PbufPayloadOff, ptrAt(mem, PbufSize + PbufDefaultHeadroom))
    storeU16(mem, PbufLenOff, length)
    storeU16(mem, PbufTotLenOff, length)
    storeU16(mem, PbufRefOff, 1)
    cast[ptr Pbuf](mem)

  proc pbuf_alloced_custom*(layer: PbufLayer; length: uint16; ptype: PbufType; p: ptr PbufCustom;
                            payloadMem: pointer; payloadMemLen: uint16): ptr Pbuf {.exportc, cdecl.} =
    discard layer; discard ptype; discard payloadMemLen
    if p == nil: return nil
    zero(cast[pointer](p), PbufSize)
    storePtr(cast[pointer](p), PbufPayloadOff, payloadMem)
    storeU16(cast[pointer](p), PbufLenOff, length)
    storeU16(cast[pointer](p), PbufTotLenOff, length)
    storeU16(cast[pointer](p), PbufRefOff, 1)
    cast[ptr Pbuf](p)

  proc pbuf_free*(p: ptr Pbuf): uint8 {.exportc, cdecl.} =
    var cur = cast[pointer](p)
    while cur != nil:
      let next = loadPtr(cur, PbufNextOff)
      let refCount = loadU16(cur, PbufRefOff)
      if refCount > 1'u16:
        storeU16(cur, PbufRefOff, refCount - 1'u16)
        return 0
      if (loadU8(cur, PbufFlagsOff) and PbufFlagIsCustom) != 0:
        let fn = cast[PbufFreeFn](loadPtr(cur, PbufCustomFreeOff))
        if fn != nil: fn(cast[ptr Pbuf](cur))
      else:
        c_free(cur)
      cur = next
    1

  proc pbuf_ref*(p: ptr Pbuf) {.exportc, cdecl.} =
    if p != nil: storeU16(cast[pointer](p), PbufRefOff, loadU16(cast[pointer](p), PbufRefOff) + 1)
