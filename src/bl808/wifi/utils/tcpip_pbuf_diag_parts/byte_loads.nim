## Byte-order helpers for packet diagnostics.

proc loadBe16(base: pointer; byteOffset: uint): uint16 {.inline.} =
  (loadU8(base, byteOffset).uint16 shl 8) or loadU8(base, byteOffset + 1).uint16

proc loadBe32(base: pointer; byteOffset: uint): uint32 {.inline.} =
  (loadU8(base, byteOffset).uint32 shl 24) or
  (loadU8(base, byteOffset + 1).uint32 shl 16) or
  (loadU8(base, byteOffset + 2).uint32 shl 8) or
  loadU8(base, byteOffset + 3).uint32

proc loadLe32Bytes(base: pointer; byteOffset: uint): uint32 {.inline.} =
  loadU8(base, byteOffset).uint32 or
  (loadU8(base, byteOffset + 1).uint32 shl 8) or
  (loadU8(base, byteOffset + 2).uint32 shl 16) or
  (loadU8(base, byteOffset + 3).uint32 shl 24)
