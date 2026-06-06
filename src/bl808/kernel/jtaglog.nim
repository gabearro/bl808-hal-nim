## RAM-backed validation log for JTAG capture.
##
## This mirrors console bytes into a fixed-size ring buffer with exported
## symbols so tools/hw_validate.py can recover logs even when UART TX is not
## physically visible to the host.

const
  HwValidationLogMagic* = 0x474C544A'u32 # "JTLG" little-endian
  HwValidationLogCapacity* {.intdefine.} = 8192

var
  hwValidationLogMagic* {.exportc: "hw_validation_log_magic".}: uint32 =
    HwValidationLogMagic
  hwValidationLogCapacity* {.exportc: "hw_validation_log_capacity".}: uint32 =
    HwValidationLogCapacity
  hwValidationLogWrite* {.exportc: "hw_validation_log_write".}: uint32 = 0
  hwValidationLogWrapped* {.exportc: "hw_validation_log_wrapped".}: uint32 = 0
  hwValidationLogBuffer* {.exportc: "hw_validation_log_buffer".}:
    array[HwValidationLogCapacity, uint8]

proc hwValidationLogReset*() {.exportc: "hw_validation_log_reset", cdecl.} =
  hwValidationLogMagic = HwValidationLogMagic
  hwValidationLogCapacity = HwValidationLogCapacity
  hwValidationLogWrite = 0
  hwValidationLogWrapped = 0

proc hwValidationLogByte*(b: uint8) {.exportc: "hw_validation_log_byte", cdecl.} =
  if hwValidationLogMagic != HwValidationLogMagic:
    hwValidationLogReset()
  let pos = hwValidationLogWrite mod HwValidationLogCapacity
  hwValidationLogBuffer[pos.int] = b
  var next = pos + 1
  if next >= HwValidationLogCapacity.uint32:
    next = 0
    hwValidationLogWrapped = 1
  hwValidationLogWrite = next

proc hwValidationLogBytes*(data: pointer, len: uint32)
    {.exportc: "hw_validation_log_bytes", cdecl.} =
  if data == nil:
    return
  let raw = cast[ptr UncheckedArray[uint8]](data)
  for i in 0'u32 ..< len:
    hwValidationLogByte(raw[i])
