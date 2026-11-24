## Compile-only check: bare-metal JIT memory must not pull in POSIX mmap.
import cps/wasm/jit/memory

var region: array[64, uint64]

proc refuse(ctx: pointer, writable: bool): bool {.nimcall.} =
  discard ctx
  discard writable
  false

proc jitRegionTargetCheck*() {.exportc.} =
  var pool = initJitMemPoolIn(addr region[0], sizeof(region), refuse)
  discard pool.alloc(8)
  invalidateICache(addr region[0], 8)
  pool.destroy()
