## LP worker for the shared flash-slot WASM smoke test.

import bl808/startup
import bl808/core, bl808/mmio
import bl808/kernel/alloc
import bl808/wasm_runtime
import bl808/wasm_slot_smoke

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  let status = runWasmSlotRequest(WasmSlotLpRequestAddr)
  regWrite(WasmSlotLpCapsAddr, wasmRuntimeCapabilityWord())
  regWrite(WasmSlotLpStatusAddr, status)
  while true:
    wfi()
