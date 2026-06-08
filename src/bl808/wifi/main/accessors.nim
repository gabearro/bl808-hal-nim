template ptrAt(base: pointer; off: uint): pointer =
  cast[pointer](cast[uint](base) + off)

proc hwPtr(): ptr BlHw {.inline.} =
  addr wifi_hw

proc hwRaw(): pointer {.inline.} =
  cast[pointer](addr wifi_hw)

proc zero(p: pointer; n: Natural) {.inline.} =
  discard c_memset(p, 0, n.csize_t)

proc loadPtr(base: pointer; off: uint): pointer {.inline.} =
  cast[ptr pointer](ptrAt(base, off))[]

proc storePtr(base: pointer; off: uint; value: pointer) {.inline.} =
  cast[ptr pointer](ptrAt(base, off))[] = value

proc loadU8(base: pointer; off: uint): uint8 {.inline.} =
  cast[ptr uint8](ptrAt(base, off))[]

proc storeU8(base: pointer; off: uint; value: uint8) {.inline.} =
  cast[ptr uint8](ptrAt(base, off))[] = value

proc loadI8(base: pointer; off: uint): int8 {.inline.} =
  cast[ptr int8](ptrAt(base, off))[]

proc loadU32(base: pointer; off: uint): uint32 {.inline.} =
  cast[ptr uint32](ptrAt(base, off))[]

proc storeU16(base: pointer; off: uint; value: uint16) {.inline.} =
  cast[ptr uint16](ptrAt(base, off))[] = value

proc storeU32(base: pointer; off: uint; value: uint32) {.inline.} =
  cast[ptr uint32](ptrAt(base, off))[] = value

proc storeI32(base: pointer; off: uint; value: int32) {.inline.} =
  cast[ptr int32](ptrAt(base, off))[] = value

proc vifAt(index: uint): pointer {.inline.} =
  ptrAt(hwRaw(), BlHwVifTableOff + index * BlVifSize)

proc staAt(index: uint): pointer {.inline.} =
  ptrAt(hwRaw(), BlHwStaTableOff + index * BlStaSize)

proc netifHwaddr(netif: ptr Netif): ptr uint8 {.inline.} =
  cast[ptr uint8](ptrAt(cast[pointer](netif), NetifHwaddrOff))

proc initListHead(base: pointer; off: uint) =
  let list = ptrAt(base, off)
  storePtr(list, 0'u, list)
  storePtr(list, sizeof(pointer).uint, list)
