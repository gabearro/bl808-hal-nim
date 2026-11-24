## D0 DRAM/XIP capacity check for the shared Tier-2 compiler. The protection hook
## deliberately rejects code publication; this is not a runnable JIT image.

when not defined(bl808d0) or not defined(bl808kernel):
  {.error: "build this check for D0 firmware".}

import bl808/[startup, core, wasm_full_baseline, wasm_runtime, mmio, memmap]
import bl808/kernel/alloc
import cps/wasm/[binary, validate]
import cps/wasm/jit/[memory, pipeline, codegen_rv64]

static:
  doAssert WasmD0NativeStackBytes >= 16384,
    "D0 JIT compilation exceeded the normal 8 KiB stack on QEMU"

const StatusAddr = XramBase + 0x3F20'u
var codeRegion {.align: 4096.}: array[512, uint64]

proc denyPublication(ctx: pointer, writable: bool): bool {.nimcall.} =
  discard ctx
  discard writable
  false

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  regWrite(StatusAddr, 0x574A_7F00'u32)
  let module = decodeModule(WasmFullBaselineModule)
  validateModule(module)
  var pool = initJitMemPoolIn(addr codeRegion[0], sizeof(codeRegion),
    denyPublication)
  var denied = false
  try:
    discard pool.compileTier2Rv64(module, 0, 0,
      target = rv64BL808D0VerifiedTarget)
  except OSError:
    denied = true
  pool.destroy()
  regWrite(StatusAddr + 4'u, heapStats().highWaterBytes.uint32)
  regWrite(StatusAddr, if denied: 0x574A_0000'u32 else: 0x574A_0001'u32)
  fenceIo()
  while true: wfi()
