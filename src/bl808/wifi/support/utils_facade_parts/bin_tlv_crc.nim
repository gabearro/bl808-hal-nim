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
  if typ != 1 and typ != 7:
    return -2
  if arg1 == nil or (bufSz >= 4 and buf == nil):
    return -2
  # The SDK publishes these defaults even when the input is too short.
  var value = if typ == 1: 1'u32 else: 0'u32
  if bufSz >= 4:
    copyMem(addr value, buf, sizeof(value))
  if typ == 1:
    cast[ptr uint8](arg1)[] = (value != 0).uint8
  else:
    copyMem(arg1, addr value, sizeof(value))
  if bufSz < 4: -1 else: 4

proc utils_tlv_bl_pack_auto*(buf: ptr uint32; bufSz: cint; typ: uint16; arg1: pointer): cint {.exportc, cdecl.} =
  if typ != 1 and typ != 7:
    return -2
  if bufSz < 4:
    return -1
  if buf == nil or arg1 == nil:
    return -2
  var value: uint32
  if typ == 1:
    value = (cast[ptr uint8](arg1)[] != 0).uint32
  else:
    copyMem(addr value, arg1, sizeof(value))
  copyMem(buf, addr value, sizeof(value))
  4

const WifiCrc32Table = block:
  var table: array[256, uint32]
  for index in 0 ..< table.len:
    var value = index.uint32
    for bit in 0 ..< 8:
      value = if (value and 1) != 0:
        (value shr 1) xor 0xEDB88320'u32
      else:
        value shr 1
    table[index] = value
  table

proc utils_crc32_stream_init*(ctx: pointer) {.exportc, cdecl.} =
  cast[ptr uint32](ctx)[] = high(uint32)

proc utils_crc32_stream_feed_block*(ctx: pointer; data: ptr uint8; length: uint32) {.exportc, cdecl.} =
  var crc = cast[ptr uint32](ctx)
  for crcInputByteIndex in 0'u32 ..< length:
    let value = cast[ptr uint8](ptrAt(data, crcInputByteIndex.uint))[]
    let tableIndex = ((crc[] xor value.uint32) and 0xFF'u32).int
    crc[] = WifiCrc32Table[tableIndex] xor (crc[] shr 8)

proc utils_crc32_stream_results*(ctx: pointer): uint32 {.exportc, cdecl.} =
  cast[ptr uint32](ctx)[] xor high(uint32)
