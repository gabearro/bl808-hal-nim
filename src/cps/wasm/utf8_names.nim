## Strict UTF-8 scalar-value encoding, including overlong/surrogate limits.
func validWasmName*(value: string): bool =
  var i = 0
  while i < value.len:
    let first = uint8(value[i])
    if first < 0x80: inc i; continue
    let count = if first in 0xc2'u8..0xdf'u8: 2
      elif first in 0xe0'u8..0xef'u8: 3
      elif first in 0xf0'u8..0xf4'u8: 4
      else: 0
    if count == 0 or count > value.len-i: return false
    let second = uint8(value[i+1])
    if second < 0x80 or second > 0xbf: return false
    if (first == 0xe0 and second < 0xa0) or (first == 0xed and second >= 0xa0) or
        (first == 0xf0 and second < 0x90) or (first == 0xf4 and second >= 0x90): return false
    for j in 2..<count:
      if uint8(value[i+j]) < 0x80 or uint8(value[i+j]) > 0xbf: return false
    i += count
  true

iterator utf8Scalars*(value: string): uint32 =
  ## Iterate a string already checked by validWasmName.
  var pos = 0
  while pos < value.len:
    let first = ord(value[pos])
    inc pos
    if first < 0x80:
      yield first.uint32
    else:
      let more = if first < 0xe0: 1 elif first < 0xf0: 2 else: 3
      var scalar = uint32(first and (0x7f shr (more + 1)))
      for _ in 0 ..< more:
        scalar = (scalar shl 6) or uint32(ord(value[pos]) and 0x3f)
        inc pos
      yield scalar

proc appendUtf8Scalar*(value: var string, scalar: uint32) =
  ## The caller supplies a Unicode scalar, excluding surrogate code points.
  if scalar < 0x80:
    value.add(char(scalar))
  else:
    let more = if scalar < 0x800: 1 elif scalar < 0x10000: 2 else: 3
    let prefix = case more
      of 1: 0xc0'u32
      of 2: 0xe0'u32
      else: 0xf0'u32
    value.add(char(prefix or (scalar shr (6 * more))))
    for i in countdown(more - 1, 0):
      value.add(char(0x80'u32 or ((scalar shr (6 * i)) and 0x3f'u32)))
