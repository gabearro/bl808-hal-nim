## One guest corpus and one interpreter path for M0, D0, and LP.
## The f64 and indirect-call cases cannot execute on the old LP compact VM.

import cps/wasm/[binary, runtime, types, validate]
when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  import ./kernel/alloc
when defined(bl808lp):
  import ./wasm_lp_softfloat

type WasmFullBaselineMemory* = object
  validationBytes*: uint32
  vmBytes*: uint32
  instanceBytes*: uint32
  peakBytes*: uint32

const
  WasmFullBaselineOk* = 0x57464D00'u32
  WasmFullBaselineDecodeFailed* = 0x57464D01'u32
  WasmFullBaselineValidateFailed* = 0x57464D02'u32
  WasmFullBaselineInstantiateFailed* = 0x57464D03'u32
  WasmFullBaselineAddFailed* = 0x57464D04'u32
  WasmFullBaselineF64Failed* = 0x57464D05'u32
  WasmFullBaselineIndirectFailed* = 0x57464D06'u32
  # tools/wasm_full_baseline.wat, compiled with wat2wasm.
  WasmFullBaselineModule* = [
    byte 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0b, 0x02, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
    0x60, 0x00, 0x01, 0x7e, 0x03, 0x04, 0x03, 0x00, 0x01,
    0x00, 0x04, 0x04, 0x01, 0x70, 0x00, 0x01, 0x07, 0x1c,
    0x03, 0x07, 0x66, 0x36, 0x34, 0x62, 0x69, 0x74, 0x73,
    0x00, 0x01, 0x08, 0x69, 0x6e, 0x64, 0x69, 0x72, 0x65,
    0x63, 0x74, 0x00, 0x02, 0x03, 0x61, 0x64, 0x64, 0x00,
    0x00, 0x09, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01,
    0x00, 0x0a, 0x2c, 0x03, 0x07, 0x00, 0x20, 0x00, 0x20,
    0x01, 0x6a, 0x0b, 0x16, 0x00, 0x44, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0xf8, 0x3f, 0x44, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x02, 0x40, 0xa0, 0xbd, 0x0b, 0x0b,
    0x00, 0x20, 0x00, 0x20, 0x01, 0x41, 0x00, 0x11, 0x00,
    0x00, 0x0b
  ]

proc usedBytes(): uint32 =
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    heapStats().usedBytes.uint32
  else:
    0'u32

proc increase(now, before: uint32): uint32 {.inline.} =
  if now >= before: now - before else: 0'u32

proc runWasmFullBaseline*(memory: ptr WasmFullBaselineMemory = nil): uint32 =
  let initialUsed = if memory != nil: usedBytes() else: 0'u32
  if memory != nil:
    memory[] = WasmFullBaselineMemory()
  var module: WasmModule
  try:
    module = decodeModule(WasmFullBaselineModule)
  except CatchableError:
    return WasmFullBaselineDecodeFailed
  try:
    validateModule(module)
  except CatchableError:
    return WasmFullBaselineValidateFailed
  let afterValidation = if memory != nil: usedBytes() else: 0'u32
  if memory != nil:
    memory.validationBytes = increase(afterValidation, initialUsed)

  var vm = initWasmVM()
  let afterVmInit = if memory != nil: usedBytes() else: 0'u32
  if memory != nil:
    memory.vmBytes = increase(afterVmInit, afterValidation)
  var moduleIdx: int
  try:
    moduleIdx = vm.instantiate(module, [])
  except CatchableError:
    return WasmFullBaselineInstantiateFailed
  if memory != nil:
    memory.instanceBytes = increase(usedBytes(), afterVmInit)

  try:
    let values = vm.invoke(moduleIdx, "add", [wasmI32(19), wasmI32(23)])
    if values.len != 1 or values[0].kind != wvkI32 or values[0].i32 != 42:
      return WasmFullBaselineAddFailed
  except CatchableError:
    return WasmFullBaselineAddFailed

  try:
    let values = vm.invoke(moduleIdx, "f64bits", [])
    if values.len != 1 or values[0].kind != wvkI64 or
        cast[uint64](values[0].i64) != 0x400e_0000_0000_0000'u64:
      return WasmFullBaselineF64Failed
  except CatchableError:
    return WasmFullBaselineF64Failed

  try:
    let values = vm.invoke(moduleIdx, "indirect", [wasmI32(20), wasmI32(22)])
    if values.len != 1 or values[0].kind != wvkI32 or values[0].i32 != 42:
      return WasmFullBaselineIndirectFailed
  except CatchableError:
    return WasmFullBaselineIndirectFailed
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    if memory != nil:
      memory.peakBytes = heapStats().highWaterBytes.uint32
  WasmFullBaselineOk
