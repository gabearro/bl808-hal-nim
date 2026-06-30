## D0 worker for the shared flash-slot WASM smoke test.

import bl808/startup
import bl808/core, bl808/mmio
import bl808/kernel/alloc
import bl808/wasm_runtime
import bl808/wasm_slot_smoke

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  let status = runWasmSlotRequest(WasmSlotD0RequestAddr)
  regWrite(WasmSlotD0CapsAddr, wasmRuntimeCapabilityWord())
  regWrite(WasmSlotD0StatusAddr, status)
  dcacheFlushAll()
  fenceIo()
  while true:
    wfi()
