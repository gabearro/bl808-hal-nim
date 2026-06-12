template ptrAt(base: pointer; byteOffset: uint): pointer =
  cast[pointer](cast[uint](base) + byteOffset)

proc opPtr(operationSlotByteOffset: uint): pointer {.inline.} =
  cast[ptr pointer](cast[uint](addr g_bl_ops_funcs) + operationSlotByteOffset)[]

proc loadPtr(base: pointer; byteOffset: uint): pointer {.inline.} =
  cast[ptr pointer](ptrAt(base, byteOffset))[]

proc storePtr(base: pointer; byteOffset: uint; value: pointer) {.inline.} =
  cast[ptr pointer](ptrAt(base, byteOffset))[] = value

proc loadU16(base: pointer; byteOffset: uint): uint16 {.inline.} =
  cast[ptr uint16](ptrAt(base, byteOffset))[]

proc storeU16(base: pointer; byteOffset: uint; value: uint16) {.inline.} =
  cast[ptr uint16](ptrAt(base, byteOffset))[] = value

proc loadU32(base: pointer; byteOffset: uint): uint32 {.inline.} =
  cast[ptr uint32](ptrAt(base, byteOffset))[]

proc storeU32(base: pointer; byteOffset: uint; value: uint32) {.inline.} =
  cast[ptr uint32](ptrAt(base, byteOffset))[] = value

proc loadI32(base: pointer; byteOffset: uint): int32 {.inline.} =
  cast[ptr int32](ptrAt(base, byteOffset))[]

proc storeI32(base: pointer; byteOffset: uint; value: int32) {.inline.} =
  cast[ptr int32](ptrAt(base, byteOffset))[] = value
