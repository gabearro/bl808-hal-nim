proc utils_bin2hex*(dst: cstring; src: pointer; srcLen: csize_t) {.exportc, cdecl.} =
  const hex = "0123456789abcdef"
  let sourceBytes = cast[ptr UncheckedArray[uint8]](src)
  let hexOutputChars = cast[ptr UncheckedArray[char]](dst)
  for sourceByteIndex in 0 ..< srcLen.int:
    hexOutputChars[sourceByteIndex * 2] =
      hex[int(sourceBytes[sourceByteIndex] shr 4)]
    hexOutputChars[sourceByteIndex * 2 + 1] =
      hex[int(sourceBytes[sourceByteIndex] and 15)]
  hexOutputChars[srcLen.int * 2] = '\0'

proc utils_tlv_bl_unpack_auto*(buf: ptr uint32; bufSz: cint; typ: uint16; arg1: pointer): cint {.exportc, cdecl.} =
  discard buf; discard bufSz; discard typ; discard arg1; 0

proc utils_tlv_bl_pack_auto*(buf: ptr uint32; bufSz: cint; typ: uint16; arg1: pointer): cint {.exportc, cdecl.} =
  discard buf; discard bufSz; discard typ; discard arg1; 0

proc utils_crc32_stream_init*(ctx: pointer) {.exportc, cdecl.} = zero(ctx, 4)

proc utils_crc32_stream_feed_block*(ctx: pointer; data: ptr uint8; length: uint32) {.exportc, cdecl.} =
  var crc = cast[ptr uint32](ctx)
  for crcInputByteIndex in 0'u32 ..< length:
    crc[] = (crc[] shl 5) xor (crc[] shr 27) xor
      cast[ptr uint8](ptrAt(data, crcInputByteIndex.uint))[]

proc utils_crc32_stream_results*(ctx: pointer): uint32 {.exportc, cdecl.} =
  cast[ptr uint32](ctx)[]
