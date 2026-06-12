when not defined(bl808WifiRealLwip):
  proc pbufTakeAtImpl(targetPbuf: ptr Pbuf; sourceData: pointer; length, offset: uint16): int8 {.exportc: "bl808_nim_pbuf_take_at_impl", cdecl.} =
    if targetPbuf == nil or sourceData == nil or loadPtr(cast[pointer](targetPbuf), PbufPayloadOff) == nil:
      return -1
    if offset.uint32 + length.uint32 > loadU16(cast[pointer](targetPbuf), PbufLenOff).uint32:
      return -1
    copyMem(ptrAt(loadPtr(cast[pointer](targetPbuf), PbufPayloadOff), offset.uint), sourceData, length.uint)
    0

  proc pbufTakeImpl(targetPbuf: ptr Pbuf; sourceData: pointer; length: uint16): int8 {.exportc: "bl808_nim_pbuf_take_impl", cdecl.} =
    pbufTakeAtImpl(targetPbuf, sourceData, length, 0'u16)

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
    var tailSearchNode = cast[pointer](head)
    while loadPtr(tailSearchNode, PbufNextOff) != nil: tailSearchNode = loadPtr(tailSearchNode, PbufNextOff)
    storePtr(tailSearchNode, PbufNextOff, cast[pointer](tail))
    if tail != nil:
      storeU16(cast[pointer](head), PbufTotLenOff, loadU16(cast[pointer](head), PbufTotLenOff) + loadU16(cast[pointer](tail), PbufTotLenOff))

  proc pbuf_header*(pbuf: ptr Pbuf; inc: int16): uint8 {.exportc, cdecl.} =
    if pbuf == nil: return 1
    let pbufStorage = cast[pointer](pbuf)
    let payload = cast[uint](loadPtr(pbufStorage, PbufPayloadOff))
    if inc > 0 and (loadU8(pbufStorage, PbufFlagsOff) and PbufFlagIsCustom) == 0:
      let pbufStart = cast[uint](pbufStorage) + PbufSize.uint
      if payload < pbufStart + inc.uint:
        return 1
    let nextPayload =
      if inc >= 0:
        cast[pointer](payload - inc.uint)
      else:
        cast[pointer](payload + uint(-inc))
    if inc < 0 and loadU16(pbufStorage, PbufLenOff).int < -inc.int:
      return 1
    storePtr(pbufStorage, PbufPayloadOff, nextPayload)
    storeU16(pbufStorage, PbufLenOff, uint16(loadU16(pbufStorage, PbufLenOff).int + inc.int))
    storeU16(pbufStorage, PbufTotLenOff, uint16(loadU16(pbufStorage, PbufTotLenOff).int + inc.int))
    0
