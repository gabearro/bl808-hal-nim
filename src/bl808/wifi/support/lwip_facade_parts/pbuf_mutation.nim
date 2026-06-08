when not defined(bl808WifiRealLwip):
  proc pbufTakeAtImpl(buf: ptr Pbuf; dataptr: pointer; length, offset: uint16): int8 {.exportc: "bl808_nim_pbuf_take_at_impl", cdecl.} =
    if buf == nil or dataptr == nil or loadPtr(cast[pointer](buf), PbufPayloadOff) == nil:
      return -1
    if offset.uint32 + length.uint32 > loadU16(cast[pointer](buf), PbufLenOff).uint32:
      return -1
    copyMem(ptrAt(loadPtr(cast[pointer](buf), PbufPayloadOff), offset.uint), dataptr, length.uint)
    0

  proc pbufTakeImpl(buf: ptr Pbuf; dataptr: pointer; length: uint16): int8 {.exportc: "bl808_nim_pbuf_take_impl", cdecl.} =
    pbufTakeAtImpl(buf, dataptr, length, 0'u16)

  {.emit: """
#include <lwip/pbuf.h>
err_t pbuf_take(struct pbuf *buf, const void *dataptr, u16_t len) {
return bl808_nim_pbuf_take_impl(buf, (void *)dataptr, len);
}
err_t pbuf_take_at(struct pbuf *buf, const void *dataptr, u16_t len, u16_t offset) {
return bl808_nim_pbuf_take_at_impl(buf, (void *)dataptr, len, offset);
}
""".}

  proc pbuf_cat*(head, tail: ptr Pbuf) {.exportc, cdecl.} =
    if head == nil: return
    var p = cast[pointer](head)
    while loadPtr(p, PbufNextOff) != nil: p = loadPtr(p, PbufNextOff)
    storePtr(p, PbufNextOff, cast[pointer](tail))
    if tail != nil:
      storeU16(cast[pointer](head), PbufTotLenOff, loadU16(cast[pointer](head), PbufTotLenOff) + loadU16(cast[pointer](tail), PbufTotLenOff))

  proc pbuf_header*(p: ptr Pbuf; inc: int16): uint8 {.exportc, cdecl.} =
    if p == nil: return 1
    let raw = cast[pointer](p)
    let payload = cast[uint](loadPtr(raw, PbufPayloadOff))
    if inc > 0 and (loadU8(raw, PbufFlagsOff) and PbufFlagIsCustom) == 0:
      let pbufStart = cast[uint](raw) + PbufSize.uint
      if payload < pbufStart + inc.uint:
        return 1
    let nextPayload =
      if inc >= 0:
        cast[pointer](payload - inc.uint)
      else:
        cast[pointer](payload + uint(-inc))
    if inc < 0 and loadU16(raw, PbufLenOff).int < -inc.int:
      return 1
    storePtr(raw, PbufPayloadOff, nextPayload)
    storeU16(raw, PbufLenOff, uint16(loadU16(raw, PbufLenOff).int + inc.int))
    storeU16(raw, PbufTotLenOff, uint16(loadU16(raw, PbufTotLenOff).int + inc.int))
    0
