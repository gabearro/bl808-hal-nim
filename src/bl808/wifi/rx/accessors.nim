template ptrAt(base: pointer; byteOffset: uint): pointer =
  cast[pointer](cast[uint](base) + byteOffset)

proc hwRaw(): pointer {.inline.} = cast[pointer](addr wifi_hw)
proc loadPtr(base: pointer; byteOffset: uint): pointer {.inline.} = cast[ptr pointer](ptrAt(base, byteOffset))[]
proc loadU8(base: pointer; byteOffset: uint): uint8 {.inline.} = cast[ptr uint8](ptrAt(base, byteOffset))[]
proc storeU8(base: pointer; byteOffset: uint; value: uint8) {.inline.} = cast[ptr uint8](ptrAt(base, byteOffset))[] = value
proc loadI8(base: pointer; byteOffset: uint): int8 {.inline.} = cast[ptr int8](ptrAt(base, byteOffset))[]
proc storeI8(base: pointer; byteOffset: uint; value: int8) {.inline.} = cast[ptr int8](ptrAt(base, byteOffset))[] = value
proc loadU16(base: pointer; byteOffset: uint): uint16 {.inline.} = cast[ptr uint16](ptrAt(base, byteOffset))[]
proc storeU16(base: pointer; byteOffset: uint; value: uint16) {.inline.} = cast[ptr uint16](ptrAt(base, byteOffset))[] = value
proc loadU32(base: pointer; byteOffset: uint): uint32 {.inline.} = cast[ptr uint32](ptrAt(base, byteOffset))[]
proc storeU32(base: pointer; byteOffset: uint; value: uint32) {.inline.} = cast[ptr uint32](ptrAt(base, byteOffset))[] = value
proc storeI32(base: pointer; byteOffset: uint; value: int32) {.inline.} = cast[ptr int32](ptrAt(base, byteOffset))[] = value
proc copyMem(dest, src: pointer; byteCount: uint) {.inline.} =
  discard c_memcpy(dest, src, byteCount.csize_t)
proc zero(dest: pointer; byteCount: uint) {.inline.} =
  discard c_memset(dest, 0, byteCount.csize_t)

proc vifAt(hw: pointer; vifIndex: uint): pointer {.inline.} =
  ptrAt(ptrAt(hw, BlHwVifTableOff), vifIndex * BlVifSize)

proc staAt(hw: pointer; stationIndex: uint): pointer {.inline.} =
  ptrAt(ptrAt(hw, BlHwStaTableOff), stationIndex * BlStaSize)

proc msgParam(msg: pointer): pointer {.inline.} =
  ptrAt(msg, IpcMsgParamOff)

proc msgTask(id: uint16): uint16 {.inline.} = id shr 10
proc msgIndex(id: uint16): uint16 {.inline.} = id and MsgIndexMask
