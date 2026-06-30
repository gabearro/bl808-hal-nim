## LP WebAssembly VM smoke test.

import bl808/startup
import bl808/core, bl808/mmio
import bl808/kernel/alloc
import bl808/wasm_runtime
import bl808/wasm_smoke
import bl808/wasm_task_smoke

const
  LpWasmStatusAddr* = 0x40002E80'u
  LpWasmCapsAddr* = 0x40002E88'u
  LpWasmTaskStatusAddr* = 0x40002E8C'u

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  let status = runWasmSmoke()
  regWrite(LpWasmCapsAddr, wasmRuntimeCapabilityWord())
  regWrite(LpWasmStatusAddr, status)
  let taskStatus = runWasmTaskSmoke()
  regWrite(LpWasmTaskStatusAddr, taskStatus)
  while true:
    wfi()
