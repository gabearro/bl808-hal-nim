proc vendorPrintU32(value: uint32; base: uint32) =
  var v = value
  var buf: array[11, char]
  var pos = 0
  if v == 0:
    vendorPrintChar('0')
    return
  while v != 0 and pos < buf.len:
    let d = v mod base
    buf[pos] = char(if d < 10: ord('0') + d.int else: ord('A') + d.int - 10)
    inc pos
    v = v div base
  while pos > 0:
    dec pos
    vendorPrintChar(buf[pos])
