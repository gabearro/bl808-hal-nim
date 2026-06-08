template ptrAt(base: pointer; off: uint): pointer =
  cast[pointer](cast[uint](base) + off)

proc loadPtr(base: pointer; off: uint): pointer {.inline.} =
  cast[ptr pointer](ptrAt(base, off))[]

proc storePtr(base: pointer; off: uint; value: pointer) {.inline.} =
  cast[ptr pointer](ptrAt(base, off))[] = value

proc loadU8(base: pointer; off: uint): uint8 {.inline.} =
  cast[ptr uint8](ptrAt(base, off))[]

proc storeU8(base: pointer; off: uint; value: uint8) {.inline.} =
  cast[ptr uint8](ptrAt(base, off))[] = value

proc loadU32(base: pointer; off: uint): uint32 {.inline.} =
  cast[ptr uint32](ptrAt(base, off))[]

proc storeU32(base: pointer; off: uint; value: uint32) {.inline.} =
  cast[ptr uint32](ptrAt(base, off))[] = value

proc roundUp4(value: uint32): uint32 {.inline.} =
  (value + 3'u32) and not 3'u32
