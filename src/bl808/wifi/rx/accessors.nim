template ptrAt(base: pointer; off: uint): pointer =
  cast[pointer](cast[uint](base) + off)

proc hwRaw(): pointer {.inline.} = cast[pointer](addr wifi_hw)
proc loadPtr(base: pointer; off: uint): pointer {.inline.} = cast[ptr pointer](ptrAt(base, off))[]
proc loadU8(base: pointer; off: uint): uint8 {.inline.} = cast[ptr uint8](ptrAt(base, off))[]
proc storeU8(base: pointer; off: uint; value: uint8) {.inline.} = cast[ptr uint8](ptrAt(base, off))[] = value
proc loadI8(base: pointer; off: uint): int8 {.inline.} = cast[ptr int8](ptrAt(base, off))[]
proc storeI8(base: pointer; off: uint; value: int8) {.inline.} = cast[ptr int8](ptrAt(base, off))[] = value
proc loadU16(base: pointer; off: uint): uint16 {.inline.} = cast[ptr uint16](ptrAt(base, off))[]
proc storeU16(base: pointer; off: uint; value: uint16) {.inline.} = cast[ptr uint16](ptrAt(base, off))[] = value
proc loadU32(base: pointer; off: uint): uint32 {.inline.} = cast[ptr uint32](ptrAt(base, off))[]
proc storeU32(base: pointer; off: uint; value: uint32) {.inline.} = cast[ptr uint32](ptrAt(base, off))[] = value
proc storeI32(base: pointer; off: uint; value: int32) {.inline.} = cast[ptr int32](ptrAt(base, off))[] = value
proc copyMem(dest, src: pointer; n: uint) {.inline.} =
  discard c_memcpy(dest, src, n.csize_t)
proc zero(dest: pointer; n: uint) {.inline.} =
  discard c_memset(dest, 0, n.csize_t)

proc vifAt(hw: pointer; idx: uint): pointer {.inline.} =
  ptrAt(ptrAt(hw, BlHwVifTableOff), idx * BlVifSize)

proc staAt(hw: pointer; idx: uint): pointer {.inline.} =
  ptrAt(ptrAt(hw, BlHwStaTableOff), idx * BlStaSize)

proc msgParam(msg: pointer): pointer {.inline.} =
  ptrAt(msg, IpcMsgParamOff)

proc msgTask(id: uint16): uint16 {.inline.} = id shr 10
proc msgIndex(id: uint16): uint16 {.inline.} = id and MsgIndexMask
