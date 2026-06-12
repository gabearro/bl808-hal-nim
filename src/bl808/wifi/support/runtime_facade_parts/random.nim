proc vendorRandomU32(): uint32 =
  var randomState = vendorRandomState
  randomState = randomState xor (randomState shl 13)
  randomState = randomState xor (randomState shr 17)
  randomState = randomState xor (randomState shl 5)
  vendorRandomState = if randomState != 0: randomState else: 0x6d2b_79f5'u32
  vendorRandomState

proc os_random*(): culong {.exportc, cdecl.} = vendorRandomU32().culong

proc os_get_random*(randomBytes: ptr uint8; length: csize_t): cint {.exportc, cdecl.} =
  if randomBytes == nil: return -1
  for randomByteIndex in 0 ..< length.int:
    if (randomByteIndex and 3) == 0:
      discard vendorRandomU32()
    cast[ptr uint8](ptrAt(randomBytes, randomByteIndex.uint))[] =
      uint8(vendorRandomState shr ((randomByteIndex and 3) * 8))
  0
