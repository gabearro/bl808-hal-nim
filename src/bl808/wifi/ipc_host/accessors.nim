template ptrAt(base: pointer; byteOffset: uint): pointer =
  cast[pointer](cast[uint](base) + byteOffset)

proc loadPtr(base: pointer; byteOffset: uint): pointer {.inline.} =
  cast[ptr pointer](ptrAt(base, byteOffset))[]

proc storePtr(base: pointer; byteOffset: uint; value: pointer) {.inline.} =
  cast[ptr pointer](ptrAt(base, byteOffset))[] = value

proc loadU8(base: pointer; byteOffset: uint): uint8 {.inline.} =
  cast[ptr uint8](ptrAt(base, byteOffset))[]

proc storeU8(base: pointer; byteOffset: uint; value: uint8) {.inline.} =
  cast[ptr uint8](ptrAt(base, byteOffset))[] = value

proc loadU32(base: pointer; byteOffset: uint): uint32 {.inline.} =
  cast[ptr uint32](ptrAt(base, byteOffset))[]

proc storeU32(base: pointer; byteOffset: uint; value: uint32) {.inline.} =
  cast[ptr uint32](ptrAt(base, byteOffset))[] = value

proc roundUp4(value: uint32): uint32 {.inline.} =
  (value + 3'u32) and not 3'u32
