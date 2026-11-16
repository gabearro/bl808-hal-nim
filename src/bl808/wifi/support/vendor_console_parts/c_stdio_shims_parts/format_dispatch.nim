type
  VendorFormatLength = enum
    vfDefault, vfChar, vfShort, vfLong, vfLongLong, vfIntMax, vfSize, vfPtrdiff
  VendorFormatFlag = enum vfLeft, vfZero, vfPlus, vfSpace, vfAlternate
  VendorFormatSpec = object
    flags: set[VendorFormatFlag]
    width: uint32
    precision: int32
    length: VendorFormatLength
    conversion: char
  VendorFormatOutput = object
    buffer: ptr UncheckedArray[char]
    capacity, count: uint64
    console, failed: bool

proc vendorFormatSigned(cursor: pointer; kind: cuint): int64
  {.importc: "bl808_nim_vendor_arg_signed", cdecl, nodecl.}
proc vendorFormatUnsigned(cursor: pointer; kind: cuint): uint64
  {.importc: "bl808_nim_vendor_arg_unsigned", cdecl, nodecl.}
proc vendorFormatString(cursor: pointer): cstring
  {.importc: "bl808_nim_vendor_arg_string", cdecl, nodecl.}
proc vendorFormatPointer(cursor: pointer): uint
  {.importc: "bl808_nim_vendor_arg_pointer", cdecl, nodecl.}

const VendorFormatCountLimit = high(cint).uint64

proc vendorFormatRepeat(output: var VendorFormatOutput; value: char; amount: uint64) =
  if output.failed:
    return
  if amount > VendorFormatCountLimit - output.count:
    output.failed = true
    return
  if output.console:
    for index in 0'u64 ..< amount:
      vendorPrintChar(value)
  elif output.capacity > 0 and output.count < output.capacity - 1:
    let stored = min(amount, output.capacity - 1 - output.count)
    for index in 0'u64 ..< stored:
      output.buffer[(output.count + index).uint] = value
  output.count += amount

proc vendorFormatChar(output: var VendorFormatOutput; value: char) {.inline.} =
  vendorFormatRepeat(output, value, 1)

proc vendorFormatNumber(format: cstring; position: var int; value: var uint32): bool =
  value = 0
  while format[position] in {'0'..'9'}:
    let digit = (ord(format[position]) - ord('0')).uint32
    if value > (high(cint).uint32 - digit) div 10:
      return false
    value = value * 10 + digit
    inc position
  true

proc vendorFormatInteger(output: var VendorFormatOutput; value: uint64;
                         negative: bool; spec: VendorFormatSpec) =
  let radix = case spec.conversion
    of 'o': 8'u64
    of 'x', 'X', 'p': 16'u64
    else: 10'u64
  let upper = spec.conversion == 'X'
  var digits {.noinit.}: array[64, char]
  var digitCount = 0
  var remaining = value
  if remaining == 0 and (spec.precision != 0 or spec.conversion == 'p'):
    digits[0] = '0'
    digitCount = 1
  while remaining != 0:
    let digit = (remaining mod radix).int
    digits[digitCount] = char(if digit < 10: ord('0') + digit
      elif upper: ord('A') + digit - 10 else: ord('a') + digit - 10)
    inc digitCount
    remaining = remaining div radix
  var minimumDigits = max(spec.precision, 0).uint64
  if spec.conversion == 'o' and vfAlternate in spec.flags:
    if digitCount == 0 or digits[digitCount - 1] != '0':
      minimumDigits = max(minimumDigits, digitCount.uint64 + 1)
  var sign = '\0'
  if spec.conversion in {'d', 'i'}:
    if negative: sign = '-'
    elif vfPlus in spec.flags: sign = '+'
    elif vfSpace in spec.flags: sign = ' '
  let prefix = spec.conversion == 'p' or
    (spec.conversion in {'x', 'X'} and vfAlternate in spec.flags and value != 0)
  let contentSize = max(minimumDigits, digitCount.uint64) +
    (if sign != '\0': 1'u64 else: 0'u64) + (if prefix: 2'u64 else: 0'u64)
  let padding = if spec.width.uint64 > contentSize: spec.width.uint64 - contentSize else: 0'u64
  let zeroPadding = vfZero in spec.flags and vfLeft notin spec.flags and spec.precision < 0
  if vfLeft notin spec.flags and not zeroPadding:
    vendorFormatRepeat(output, ' ', padding)
  if sign != '\0': vendorFormatChar(output, sign)
  if prefix:
    vendorFormatChar(output, '0')
    vendorFormatChar(output, if upper: 'X' else: 'x')
  if zeroPadding: vendorFormatRepeat(output, '0', padding)
  if minimumDigits > digitCount.uint64:
    vendorFormatRepeat(output, '0', minimumDigits - digitCount.uint64)
  for index in countdown(digitCount - 1, 0):
    vendorFormatChar(output, digits[index])
  if vfLeft in spec.flags: vendorFormatRepeat(output, ' ', padding)

proc nimVendorFormat(buffer: pointer; capacity: csize_t; format: cstring;
                     cursor: pointer; console: uint32): cint
    {.exportc: "bl808_nim_vendor_format", cdecl.} =
  ## Integer/string printf subset used by WiFi. Unsupported conversions fail
  ## before consuming their argument; all rendering is allocation-free.
  var output = VendorFormatOutput(buffer: cast[ptr UncheckedArray[char]](buffer),
    capacity: capacity.uint64, console: console != 0)
  if not output.console and capacity != 0 and buffer == nil:
    return -1
  var position = 0
  while format != nil and format[position] != '\0' and not output.failed:
    if format[position] != '%':
      vendorFormatChar(output, format[position])
      inc position
      continue
    inc position
    if format[position] == '%':
      vendorFormatChar(output, '%')
      inc position
      continue
    var spec = VendorFormatSpec(precision: -1)
    while format[position] in {'-', '0', '+', ' ', '#'}:
      case format[position]
      of '-': spec.flags.incl(vfLeft)
      of '0': spec.flags.incl(vfZero)
      of '+': spec.flags.incl(vfPlus)
      of ' ': spec.flags.incl(vfSpace)
      else: spec.flags.incl(vfAlternate)
      inc position
    if format[position] == '*':
      let width = vendorFormatSigned(cursor, 0)
      let magnitude = if width < 0: 0'u64 - cast[uint64](width) else: width.uint64
      if magnitude > VendorFormatCountLimit:
        output.failed = true
        break
      spec.width = magnitude.uint32
      if width < 0: spec.flags.incl(vfLeft)
      inc position
    elif not vendorFormatNumber(format, position, spec.width):
      output.failed = true
      break
    if format[position] == '.':
      inc position
      if format[position] == '*':
        spec.precision = vendorFormatSigned(cursor, 0).int32
        inc position
      else:
        var precision: uint32
        if not vendorFormatNumber(format, position, precision):
          output.failed = true
          break
        spec.precision = precision.int32
    case format[position]
    of 'h':
      inc position
      if format[position] == 'h':
        spec.length = vfChar
        inc position
      else: spec.length = vfShort
    of 'l':
      inc position
      if format[position] == 'l':
        spec.length = vfLongLong
        inc position
      else: spec.length = vfLong
    of 'j':
      spec.length = vfIntMax
      inc position
    of 'z':
      spec.length = vfSize
      inc position
    of 't':
      spec.length = vfPtrdiff
      inc position
    else: discard
    spec.conversion = format[position]
    case spec.conversion
    of 'd', 'i':
      let value = vendorFormatSigned(cursor, spec.length.ord.cuint)
      let magnitude = if value < 0: 0'u64 - cast[uint64](value) else: value.uint64
      vendorFormatInteger(output, magnitude, value < 0, spec)
    of 'u', 'o', 'x', 'X':
      vendorFormatInteger(output, vendorFormatUnsigned(cursor, spec.length.ord.cuint), false, spec)
    of 'p':
      if spec.length != vfDefault:
        output.failed = true
      else:
        vendorFormatInteger(output, vendorFormatPointer(cursor).uint64, false, spec)
    of 's', 'c':
      if spec.length != vfDefault:
        output.failed = true
      else:
        var text: cstring
        var character: char
        var length = 1'u64
        if spec.conversion == 's':
          text = vendorFormatString(cursor)
          if text == nil: text = cstring("(null)")
          length = 0
          while (spec.precision < 0 or length < spec.precision.uint64) and text[length.uint] != '\0':
            inc length
        else:
          character = cast[uint8](vendorFormatSigned(cursor, 0)).char
        let padding = if spec.width.uint64 > length: spec.width.uint64 - length else: 0'u64
        if vfLeft notin spec.flags: vendorFormatRepeat(output, ' ', padding)
        if spec.conversion == 'c': vendorFormatChar(output, character)
        else:
          for index in 0'u64 ..< length: vendorFormatChar(output, text[index.uint])
        if vfLeft in spec.flags: vendorFormatRepeat(output, ' ', padding)
    else:
      output.failed = true
    if not output.failed: inc position
  if not output.console and output.capacity != 0:
    output.buffer[min(output.count, output.capacity - 1).uint] = '\0'
  if output.failed: -1.cint else: output.count.cint
