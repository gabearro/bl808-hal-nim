## Canonical BLS12-381 scalar encoding, without big-integer or curve imports.
## The fixed-length borrow pass has no data-dependent early return.

const
  ScalarEncodingSize* = 32
  ScalarModulusBE*: array[ScalarEncodingSize, byte] = [
    0x73'u8, 0xed, 0xa7, 0x53, 0x29, 0x9d, 0x7d, 0x48,
    0x33, 0x39, 0xd8, 0x08, 0x09, 0xa1, 0xd8, 0x05,
    0x53, 0xbd, 0xa4, 0x02, 0xff, 0xfe, 0x5b, 0xfe,
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01]

func borrowByte(a, b: byte, incoming: uint16): uint16 {.inline.} =
  # Incoming is zero or one. The wide difference is in 0..511, so none
  # of these uint16 operations wrap, even with runtime checks enabled.
  1'u16 - ((0x100'u16 + a.uint16 - b.uint16 - incoming) shr 8)

func isCanonicalScalarEncoding*(bytes: openArray[byte]): bool =
  if bytes.len != ScalarEncodingSize: return false
  var borrow = 0'u16
  for i in countdown(ScalarEncodingSize-1, 0):
    borrow = borrowByte(bytes[i], ScalarModulusBE[i], borrow)
  borrow == 1

when defined(zkbuildScalarEncodingTest):
  func scalarBorrowStep*(a, b: byte, incoming: uint16): uint16 =
    borrowByte(a, b, incoming)
