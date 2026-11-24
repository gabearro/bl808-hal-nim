## A deadline ends a full-interpreter slice at a guest instruction boundary.
## This uses a synthetic clock; it is not an Ox64 jitter measurement.
import bl808/wasm_full_baseline
import cps/wasm/[binary, runtime, types, validate]

var vm = initWasmVM()
let module = decodeModule(WasmFullBaselineModule)
validateModule(module)
let moduleIndex = vm.instantiate(module, [])
let address = vm.getExport(moduleIndex, "indirect").idx
var now = 0'u64
proc tick(): uint64 {.nimcall.} =
  result = now
  inc now

var continuation: WasmContinuation
let args = [wasmI32(20), wasmI32(22)]
let early = vm.executeSlice(address, args, continuation, 64,
  deadlineClock = tick, deadlineTick = 3)
doAssert early.len == 0 and continuation.status == wesYielded
doAssert continuation.instructions > 0 and continuation.instructions < 64
let consumed = continuation.instructions
let final = vm.executeSlice(address, args, continuation, 64,
  deadlineClock = tick, deadlineTick = 100)
doAssert final.len == 1 and final[0].kind == wvkI32 and final[0].i32 == 42
doAssert continuation.status == wesComplete and
  continuation.instructions > consumed
vm.destroyWasmVM()
echo "full WASM wall deadline PASS: instruction-boundary yield and resume"
