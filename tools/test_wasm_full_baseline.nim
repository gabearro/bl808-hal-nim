import bl808/wasm_full_baseline
import cps/wasm/[flash_image, runtime_int]

doAssert runWasmFullBaseline() == WasmFullBaselineOk
var compactRejected = false
try:
  let module = parseFlashWasmModule(WasmFullBaselineModule)
  var vm = initIntWasmVM()
  let moduleIdx = vm.instantiateFlashIntOnly(module)
  discard vm.invokeI32(moduleIdx, "indirect", [20'i32, 22'i32])
except CatchableError:
  compactRejected = true
doAssert compactRejected, "the legacy compact path unexpectedly ran the full corpus"
echo "full WASM baseline PASS: i32, f64, and call_indirect"
