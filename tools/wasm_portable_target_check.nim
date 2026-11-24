## Link-only check for the explicit byte-format capture and restore functions.
import cps/wasm/runtime

var vm: WasmVM
var continuation: WasmContinuation
var digest: array[32, byte]

proc wasmPortableTargetCheck*(): WasmPortableStatus {.exportc.} =
  let snapshot = vm.capturePortableSnapshot(continuation, digest)
  if snapshot.status != wpsOk: return snapshot.status
  vm.restorePortableSnapshot(continuation, snapshot.bytes, digest)
