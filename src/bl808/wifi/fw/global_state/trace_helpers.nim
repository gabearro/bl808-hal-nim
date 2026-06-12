const NimFwTraceEnabled =
  defined(bl808WifiNimFwTrace) or
  defined(bl808WifiScanTrace) or
  defined(bl808WifiVerboseConnect)

when NimFwTraceEnabled:
  proc c_puts(s: cstring): cint {.importc: "puts", header: "<stdio.h>", cdecl, discardable.}
  proc c_printf(fmt: cstring): cint {.importc: "printf", header: "<stdio.h>", cdecl, varargs, discardable.}

  proc nimFwTrace(s: cstring) {.inline.} =
    discard c_puts(s)

  proc nimFwTraceU32(prefix: cstring, value: uint32) {.inline.} =
    c_printf("%s0x%x\r\n", prefix, value)

  proc nimFwTrace2U32(prefix: cstring, a, b: uint32) {.inline.} =
    c_printf("%s0x%x 0x%x\r\n", prefix, a, b)
else:
  proc nimFwTrace(s: cstring) {.inline.} =
    discard s
  proc nimFwTraceU32(prefix: cstring, value: uint32) {.inline.} =
    discard prefix
    discard value
  proc nimFwTrace2U32(prefix: cstring, a, b: uint32) {.inline.} =
    discard prefix
    discard a
    discard b

when defined(bl808WifiConnectTrace):
  proc hwValidationLogByte(b: uint8) {.importc: "hw_validation_log_byte", cdecl.}

  proc nimFwConnectTraceText(s: cstring) {.inline.} =
    if s == nil: return
    let traceChars = cast[ptr UncheckedArray[char]](s)
    var charIndex = 0
    while traceChars[charIndex] != '\0':
      hwValidationLogByte(ord(traceChars[charIndex]).uint8)
      inc charIndex

  proc nimFwConnectTraceHex(value: uint32) {.inline.} =
    const hexChars = "0123456789ABCDEF"
    nimFwConnectTraceText("0x")
    var started = false
    for shift in countdown(28, 0, 4):
      let nibble = (value shr shift) and 0xF'u32
      if nibble != 0 or started or shift == 0:
        hwValidationLogByte(ord(hexChars[nibble.int]).uint8)
        started = true

  proc nimFwConnectTraceHexByte(value: uint8) {.inline.} =
    const hexChars = "0123456789ABCDEF"
    hwValidationLogByte(ord(hexChars[(value shr 4).int and 0xF]).uint8)
    hwValidationLogByte(ord(hexChars[(value and 0xF'u8).int]).uint8)

  proc nimFwConnectTrace2U32(prefix: cstring, a, b: uint32) {.inline.} =
    nimFwConnectTraceText(prefix)
    nimFwConnectTraceHex(a)
    hwValidationLogByte(ord(' ').uint8)
    nimFwConnectTraceHex(b)
    hwValidationLogByte(ord('\r').uint8)
    hwValidationLogByte(ord('\n').uint8)

  proc nimFwConnectTraceBytes(prefix: cstring; data: pointer; length, limit: uint32) {.inline.} =
    if data == nil: return
    let bytes = cast[ptr UncheckedArray[uint8]](data)
    var count = length
    if count > limit:
      count = limit
    nimFwConnectTraceText(prefix)
    nimFwConnectTraceHex(length)
    hwValidationLogByte(ord(' ').uint8)
    var byteIndex = 0'u32
    while byteIndex < count:
      if byteIndex != 0:
        hwValidationLogByte(ord(' ').uint8)
      nimFwConnectTraceHexByte(bytes[byteIndex])
      inc byteIndex
    hwValidationLogByte(ord('\r').uint8)
    hwValidationLogByte(ord('\n').uint8)

  proc nimFwConnectTraceHw(prefix: cstring) {.inline.} =
    nimFwConnectTrace2U32(prefix, regRead(MACHW_BASE + 0x10'u), regRead(MACHW_BASE + 0x14'u))
    nimFwConnectTrace2U32("[WIFI-CT] hw_bss ", regRead(MACHW_BASE + 0x20'u), regRead(MACHW_BASE + 0x24'u))
    nimFwConnectTrace2U32("[WIFI-CT] hw_rx ", regRead(MACHW_BASE + 0x60'u), regRead(MACHW_BASE + 0x4C'u))
    nimFwConnectTrace2U32("[WIFI-CT] hw_state ", regRead(MACHW_BASE + 0x38'u), regRead(MACHW_BASE + 0xC4'u))
else:
  proc nimFwConnectTrace2U32(prefix: cstring, a, b: uint32) {.inline.} =
    discard prefix
    discard a
    discard b
  proc nimFwConnectTraceBytes(prefix: cstring; data: pointer; length, limit: uint32) {.inline.} =
    discard prefix
    discard data
    discard length
    discard limit
  proc nimFwConnectTraceHw(prefix: cstring) {.inline.} =
    discard prefix

template nimFwMgmtFcTrace(fc: uint8): bool =
  ## Management frames have type bits [3:2] clear in the first FC byte.
  (fc and 0x0C'u8) == 0'u8
