proc vendorPrintChar(c: char) =
  when defined(bl808AllcoreWasmHttp) and not defined(bl808WifiUartTrace):
    when defined(bl808WifiValidationLog):
      hw_validation_log_byte(c.uint8)
    return
  let fifo = cast[ptr uint32](UartFifoCfg1.uint)
  let data = cast[ptr uint32](UartWdata.uint)
  var timeout: uint32
  if c == '\n':
    when defined(bl808WifiValidationLog):
      hw_validation_log_byte('\r'.uint8)
    timeout = 1_000_000
    while (fifo[] and 0x3f'u32) == 0 and timeout != 0:
      dec timeout
    data[] = '\r'.uint32
  when defined(bl808WifiValidationLog):
    hw_validation_log_byte(c.uint8)
  timeout = 1_000_000
  while (fifo[] and 0x3f'u32) == 0 and timeout != 0:
    dec timeout
  data[] = c.uint8.uint32

proc vendorPutsRaw(s: cstring) =
  if s == nil:
    return
  var charIndex = 0
  while s[charIndex] != '\0':
    vendorPrintChar(s[charIndex])
    inc charIndex
