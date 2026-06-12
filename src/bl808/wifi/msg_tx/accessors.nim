template ptrAt(base: pointer; byteOffset: uint): pointer =
  cast[pointer](cast[uint](base) + byteOffset)

proc opPtr(operationSlotByteOffset: uint): pointer {.inline.} =
  cast[ptr pointer](cast[uint](addr g_bl_ops_funcs) + operationSlotByteOffset)[]

proc osMalloc(size: uint): pointer {.inline.} =
  let allocFn = cast[MallocProc](opPtr(OpMallocOff))
  if allocFn == nil: nil else: allocFn(size.csize_t)

proc osFree(memory: pointer) {.inline.} =
  let freeFn = cast[FreeProc](opPtr(OpFreeOff))
  if freeFn != nil:
    freeFn(memory)

proc zero(memory: pointer; byteCount: uint) {.inline.} =
  discard c_memset(memory, 0, byteCount.csize_t)

proc copyMem(dest, source: pointer; byteCount: uint) {.inline.} =
  if dest != nil and source != nil and byteCount != 0:
    discard c_memcpy(dest, source, byteCount.csize_t)

proc loadPtr(base: pointer; byteOffset: uint): pointer {.inline.} =
  cast[ptr pointer](ptrAt(base, byteOffset))[]

proc storePtr(base: pointer; byteOffset: uint; value: pointer) {.inline.} =
  cast[ptr pointer](ptrAt(base, byteOffset))[] = value

proc loadU8(base: pointer; byteOffset: uint): uint8 {.inline.} =
  cast[ptr uint8](ptrAt(base, byteOffset))[]

proc storeU8(base: pointer; byteOffset: uint; value: uint8) {.inline.} =
  cast[ptr uint8](ptrAt(base, byteOffset))[] = value

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

proc swap16(value: uint16): uint16 {.inline.} =
  ((value and 0x00ff'u16) shl 8) or (value shr 8)

proc smControlPortEthertype(crypto: pointer): uint16 {.inline.} =
  ## The SDK connect parameters use numeric ETH_P_* values, while the LMAC
  ## station gate stores the byte-swapped request halfword before comparing it
  ## to the on-wire EtherType from TX descriptors.
  let configured =
    if crypto == nil: 0'u16
    else: loadU16(crypto, CryptoControlEthertypeOff)
  if configured == 0'u16: swap16(ETH_P_PAE) else: swap16(configured)
