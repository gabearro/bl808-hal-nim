proc vendorPrintU32(value: uint32; base: uint32) =
  var remainingValue = value
  var reverseDigits: array[11, char]
  var pos = 0
  if remainingValue == 0:
    vendorPrintChar('0')
    return
  while remainingValue != 0 and pos < reverseDigits.len:
    let digit = remainingValue mod base
    reverseDigits[pos] = char(if digit < 10: ord('0') + digit.int else: ord('A') + digit.int - 10)
    inc pos
    remainingValue = remainingValue div base
  while pos > 0:
    dec pos
    vendorPrintChar(reverseDigits[pos])
