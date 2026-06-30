## D0 WebAssembly VM smoke test.

import bl808/startup
import bl808/core, bl808/memmap, bl808/mmio
import bl808/kernel/alloc
import bl808/wasm_runtime
import bl808/wasm_smoke
import bl808/wasm_task_smoke
when defined(bl808D0MmuOs):
  import bl808/mmu

const
  D0WasmStatusAddr* = XramBase + 0x3E80'u
  D0WasmCapsAddr* = XramBase + 0x3E84'u
  D0WasmTaskStatusAddr* = XramBase + 0x3E88'u
  D0WasmMmuStatusAddr* = XramBase + 0x3E8C'u
  D0WasmMmuEntered* = 1'u32 shl 0
  D0WasmMmuSatp* = 1'u32 shl 1
  D0WasmMmuDone* = 1'u32 shl 2

when defined(bl808D0MmuOs):
  var d0WasmSupervisorStack {.align: 16.}: array[4096, uint8]

proc runD0WasmSmokeBody() {.noreturn.} =
  heapInit()
  when defined(bl808D0MmuOs):
    var mmuStatus = D0WasmMmuEntered
    if d0MmuEnabled():
      mmuStatus = mmuStatus or D0WasmMmuSatp
    regWrite(D0WasmMmuStatusAddr, mmuStatus)
    dcacheFlushAll()
    fenceIo()
  let status = runWasmSmoke()
  regWrite(D0WasmCapsAddr, wasmRuntimeCapabilityWord())
  regWrite(D0WasmStatusAddr, status)
  dcacheFlushAll()
  fenceIo()
  let taskStatus = runWasmTaskSmoke()
  regWrite(D0WasmTaskStatusAddr, taskStatus)
  when defined(bl808D0MmuOs):
    regWrite(D0WasmMmuStatusAddr, regRead(D0WasmMmuStatusAddr) or D0WasmMmuDone)
  dcacheFlushAll()
  fenceIo()
  while true:
    wfi()

when defined(bl808D0MmuOs):
  proc d0WasmSupervisorMain() {.cdecl, exportc, noreturn.} =
    runD0WasmSmokeBody()

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  when defined(bl808D0MmuOs):
    regWrite(D0WasmMmuStatusAddr, 0)
    dcacheFlushAll()
    fenceIo()
    initD0KernelPageTables()
    configureD0SupervisorTraps()
    openD0SupervisorPmp()
    enableD0Sv39()
    let stackTop =
      (cast[uint](addr d0WasmSupervisorStack[d0WasmSupervisorStack.high]) + 1'u) and
      not 15'u
    enterSupervisor(cast[uint](d0WasmSupervisorMain), stackTop)
  else:
    runD0WasmSmokeBody()
