## Cross-build this one image source for M0, D0, and LP. It runs the exact
## same guest bytes through cps/wasm/runtime on every core.

import bl808/[startup, core, mmio, wasm_runtime, wasm_full_baseline]
import bl808/kernel/alloc
when defined(bl808m0) or defined(bl808d0):
  import bl808/memmap

when defined(bl808m0):
  const StatusAddr = XramBase + 0x3F10'u
elif defined(bl808d0):
  const StatusAddr = XramBase + 0x3F20'u
elif defined(bl808lp):
  const StatusAddr = 0x40002E90'u
else:
  {.error: "select a BL808 core".}

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  regWrite(StatusAddr, 0x57464D7F'u32)
  var memory: WasmFullBaselineMemory
  let status = runWasmFullBaseline(addr memory)
  regWrite(StatusAddr + 4'u, wasmRuntimeCapabilityWord())
  regWrite(StatusAddr + 8'u, memory.peakBytes)
  regWrite(StatusAddr + 12'u, memory.instanceBytes)
  regWrite(StatusAddr, status)
  when defined(bl808d0):
    dcacheFlushAll()
    fenceIo()
  while true:
    wfi()
