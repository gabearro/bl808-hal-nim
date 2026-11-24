## Cross-compilation only; no hardware execution or admission claim.
import cps/wasm/[types, binary, validate, flash_image, runtime]

proc zkbuildModuleValidationTypecheck*(module: ptr WasmModule): bool {.exportc.} =
  try:
    validateModule(module[])
    true
  except ValidationError:
    false

proc zkbuildModuleDecodeTypecheck*(data: ptr UncheckedArray[byte], length: int): bool {.exportc.} =
  if length <= 0: return false
  try:
    let module = decodeModule(data.toOpenArray(0, length-1), optimize = false)
    validateModule(module)
    true
  except WasmDecodeError, ValidationError:
    false

proc zkbuildFlashDecodeTypecheck*(data: ptr UncheckedArray[byte], length: int): bool {.exportc.} =
  if length <= 0: return false
  try:
    discard parseFlashWasmModule(data.toOpenArray(0, length-1))
    true
  except FlashWasmError:
    false

proc zkbuildFullRuntimeTypecheck*(vm: ptr WasmVM, moduleIndex: int): int32 {.exportc.} =
  vm[].invoke(moduleIndex, "run", [])[0].i32

proc zkbuildFullRuntimeInstantiationTypecheck*(vm: ptr WasmVM, module: ptr WasmModule): int {.exportc.} =
  vm[].instantiate(module[], [])
