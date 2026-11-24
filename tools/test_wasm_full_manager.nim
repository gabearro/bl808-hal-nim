import bl808/[wasm_full_baseline, wasm_full_manager, wasm_manager, wasm_store]
import cps/wasm/[runtime, types]

var image = newSeq[byte](WasmProgramHeaderLen.int + WasmFullBaselineModule.len)
doAssert initWasmProgramImage(
  cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
  WasmFullBaselineModule) == wasmProgramOk
var handle: FullWasmProgramHandle
doAssert handle.openFullWasmProgramImage(
  cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32) == wasmManagerOk
doAssert handle.loaded and handle.vm != nil
doAssert handle.program.module.image.bytes ==
  cast[ptr UncheckedArray[byte]](addr image[WasmProgramHeaderLen.int])
doAssert handle.program.module.sections.len == 0
let f64Result = handle.vm[].invoke(handle.moduleIdx, "f64bits", [])
doAssert f64Result.len == 1 and f64Result[0].kind == wvkI64 and
  cast[uint64](f64Result[0].i64) == 0x400e_0000_0000_0000'u64

let funcAddr = handle.fullExportFuncAddr("indirect")
var continuation: WasmContinuation
var values: seq[WasmValue]
var yields = 0
while true:
  values = handle.vm[].executeSlice(funcAddr,
    [wasmI32(20), wasmI32(22)], continuation, 2)
  if continuation.status == wesComplete: break
  doAssert continuation.status == wesYielded
  inc yields
  doAssert yields < 30
doAssert yields > 0 and values.len == 1 and values[0].kind == wvkI32 and
  values[0].i32 == 42
handle.close()
doAssert not handle.loaded and handle.vm == nil

image[^1] = image[^1] xor 1'u8
doAssert handle.openFullWasmProgramImage(
  cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32) ==
  wasmManagerStoreError
doAssert not handle.loaded
echo "full WASM store adapter PASS: CRC, XIP view, f64, sliced indirect call"
