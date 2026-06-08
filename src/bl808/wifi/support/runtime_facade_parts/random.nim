proc vendorRandomU32(): uint32 =
  var x = vendorRandomState
  x = x xor (x shl 13)
  x = x xor (x shr 17)
  x = x xor (x shl 5)
  vendorRandomState = if x != 0: x else: 0x6d2b_79f5'u32
  vendorRandomState

proc os_random*(): culong {.exportc, cdecl.} = vendorRandomU32().culong

proc os_get_random*(buf: ptr uint8; length: csize_t): cint {.exportc, cdecl.} =
  if buf == nil: return -1
  for i in 0 ..< length.int:
    if (i and 3) == 0: discard vendorRandomU32()
    cast[ptr uint8](ptrAt(buf, i.uint))[] = uint8(vendorRandomState shr ((i and 3) * 8))
  0
