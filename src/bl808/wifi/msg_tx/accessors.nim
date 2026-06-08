template ptrAt(base: pointer; off: uint): pointer =
  cast[pointer](cast[uint](base) + off)

proc opPtr(off: uint): pointer {.inline.} =
  cast[ptr pointer](cast[uint](addr g_bl_ops_funcs) + off)[]

proc osMalloc(size: uint): pointer {.inline.} =
  let fn = cast[MallocProc](opPtr(OpMallocOff))
  if fn == nil: nil else: fn(size.csize_t)

proc osFree(p: pointer) {.inline.} =
  let fn = cast[FreeProc](opPtr(OpFreeOff))
  if fn != nil:
    fn(p)

proc zero(p: pointer; n: uint) {.inline.} =
  discard c_memset(p, 0, n.csize_t)

proc copyMem(dest, src: pointer; n: uint) {.inline.} =
  if dest != nil and src != nil and n != 0:
    discard c_memcpy(dest, src, n.csize_t)

proc loadPtr(base: pointer; off: uint): pointer {.inline.} =
  cast[ptr pointer](ptrAt(base, off))[]

proc storePtr(base: pointer; off: uint; value: pointer) {.inline.} =
  cast[ptr pointer](ptrAt(base, off))[] = value

proc loadU8(base: pointer; off: uint): uint8 {.inline.} =
  cast[ptr uint8](ptrAt(base, off))[]

proc storeU8(base: pointer; off: uint; value: uint8) {.inline.} =
  cast[ptr uint8](ptrAt(base, off))[] = value

proc loadU16(base: pointer; off: uint): uint16 {.inline.} =
  cast[ptr uint16](ptrAt(base, off))[]

proc storeU16(base: pointer; off: uint; value: uint16) {.inline.} =
  cast[ptr uint16](ptrAt(base, off))[] = value

proc loadU32(base: pointer; off: uint): uint32 {.inline.} =
  cast[ptr uint32](ptrAt(base, off))[]

proc storeU32(base: pointer; off: uint; value: uint32) {.inline.} =
  cast[ptr uint32](ptrAt(base, off))[] = value

proc loadI32(base: pointer; off: uint): int32 {.inline.} =
  cast[ptr int32](ptrAt(base, off))[]

proc storeI32(base: pointer; off: uint; value: int32) {.inline.} =
  cast[ptr int32](ptrAt(base, off))[] = value

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
