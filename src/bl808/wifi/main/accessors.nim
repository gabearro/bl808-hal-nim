template ptrAt(base: pointer; byteOffset: uint): pointer =
  cast[pointer](cast[uint](base) + byteOffset)

proc hwPtr(): ptr BlHw {.inline.} =
  addr wifi_hw

proc hwRaw(): pointer {.inline.} =
  cast[pointer](addr wifi_hw)

proc zero(memory: pointer; byteCount: Natural) {.inline.} =
  discard c_memset(memory, 0, byteCount.csize_t)

proc loadPtr(base: pointer; byteOffset: uint): pointer {.inline.} =
  cast[ptr pointer](ptrAt(base, byteOffset))[]

proc storePtr(base: pointer; byteOffset: uint; value: pointer) {.inline.} =
  cast[ptr pointer](ptrAt(base, byteOffset))[] = value

proc loadU8(base: pointer; byteOffset: uint): uint8 {.inline.} =
  cast[ptr uint8](ptrAt(base, byteOffset))[]

proc storeU8(base: pointer; byteOffset: uint; value: uint8) {.inline.} =
  cast[ptr uint8](ptrAt(base, byteOffset))[] = value

proc loadI8(base: pointer; byteOffset: uint): int8 {.inline.} =
  cast[ptr int8](ptrAt(base, byteOffset))[]

proc loadU32(base: pointer; byteOffset: uint): uint32 {.inline.} =
  cast[ptr uint32](ptrAt(base, byteOffset))[]

proc storeU16(base: pointer; byteOffset: uint; value: uint16) {.inline.} =
  cast[ptr uint16](ptrAt(base, byteOffset))[] = value

proc storeU32(base: pointer; byteOffset: uint; value: uint32) {.inline.} =
  cast[ptr uint32](ptrAt(base, byteOffset))[] = value

proc storeI32(base: pointer; byteOffset: uint; value: int32) {.inline.} =
  cast[ptr int32](ptrAt(base, byteOffset))[] = value

proc vifAt(index: uint): pointer {.inline.} =
  ptrAt(hwRaw(), BlHwVifTableOff + index * BlVifSize)

proc staAt(index: uint): pointer {.inline.} =
  ptrAt(hwRaw(), BlHwStaTableOff + index * BlStaSize)

proc netifHwaddr(netif: ptr Netif): ptr uint8 {.inline.} =
  cast[ptr uint8](ptrAt(cast[pointer](netif), NetifHwaddrOff))

proc initListHead(base: pointer; listHeadByteOffset: uint) =
  let list = ptrAt(base, listHeadByteOffset)
  storePtr(list, 0'u, list)
  storePtr(list, sizeof(pointer).uint, list)
