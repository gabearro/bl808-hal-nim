template ptrAt*(base: pointer; off: uint): pointer =
  cast[pointer](cast[uint](base) + off)

proc loadPtr*(base: pointer; off: uint): pointer {.inline.} =
  cast[ptr pointer](ptrAt(base, off))[]

proc loadI32*(base: pointer; off: uint): int32 {.inline.} =
  cast[ptr int32](ptrAt(base, off))[]

proc storeI32*(base: pointer; off: uint; value: int32) {.inline.} =
  cast[ptr int32](ptrAt(base, off))[] = value

proc loadU8*(base: pointer; off: uint): uint8 {.inline.} =
  cast[ptr uint8](ptrAt(base, off))[]

proc storeU8*(base: pointer; off: uint; value: uint8) {.inline.} =
  cast[ptr uint8](ptrAt(base, off))[] = value

proc loadU16*(base: pointer; off: uint): uint16 {.inline.} =
  cast[ptr uint16](ptrAt(base, off))[]

proc storeU16*(base: pointer; off: uint; value: uint16) {.inline.} =
  cast[ptr uint16](ptrAt(base, off))[] = value
