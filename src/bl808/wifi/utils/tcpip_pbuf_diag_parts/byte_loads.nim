## Byte-order helpers for packet diagnostics.

proc loadBe16(base: pointer; off: uint): uint16 {.inline.} =
  (loadU8(base, off).uint16 shl 8) or loadU8(base, off + 1).uint16

proc loadBe32(base: pointer; off: uint): uint32 {.inline.} =
  (loadU8(base, off).uint32 shl 24) or
  (loadU8(base, off + 1).uint32 shl 16) or
  (loadU8(base, off + 2).uint32 shl 8) or
  loadU8(base, off + 3).uint32

proc loadLe32Bytes(base: pointer; off: uint): uint32 {.inline.} =
  loadU8(base, off).uint32 or
  (loadU8(base, off + 1).uint32 shl 8) or
  (loadU8(base, off + 2).uint32 shl 16) or
  (loadU8(base, off + 3).uint32 shl 24)
