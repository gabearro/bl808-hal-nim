## JIT executable memory management. Bare-metal targets require a caller-owned
## bounded region and explicit platform protection/cache-maintenance hooks.

when not defined(bl808kernel) and not defined(wasmJitQemu):
  const
    PROT_READ = 0x01
    PROT_WRITE = 0x02
    PROT_EXEC = 0x04
    MAP_PRIVATE = 0x0002
    MAP_ANON = when defined(macosx): 0x1000 else: 0x0020
    MAP_JIT = when defined(macosx): 0x0800 else: 0x0000

  proc mmap(address: pointer, length: csize_t, prot: cint, flags: cint,
            fd: cint, offset: clong): pointer {.importc, header: "<sys/mman.h>".}
  proc munmap(address: pointer, length: csize_t): cint {.importc, header: "<sys/mman.h>".}

when defined(macosx) and not defined(bl808kernel) and not defined(wasmJitQemu):
  proc pthread_jit_write_protect_np(enabled: cint) {.importc, header: "<pthread.h>".}
  proc sys_icache_invalidate(start: pointer, length: csize_t) {.importc, header: "<libkern/OSCacheControl.h>".}
elif not defined(bl808kernel) and not defined(wasmJitQemu):
  proc builtinClearCache(first, last: pointer) {.importc: "__builtin___clear_cache", nodecl.}

when defined(bl808kernel) and (defined(bl808m0) or defined(bl808d0)):
  import bl808/core

const
  JitPageSize* = 4096
  DefaultJitPoolSize* = 1024 * 1024

type
  JitRegionControl* = proc(ctx: pointer, writable: bool): bool {.nimcall, gcsafe.}

  JitMemPool* = object
    base*: ptr UncheckedArray[byte]
    capacity*: int                    # total bytes allocated
    used*: int                        # bytes used so far
    sideData*: seq[pointer]           # heap allocations tied to pool lifetime
    ownsMapping: bool
    regionControl: JitRegionControl
    regionContext: pointer

  JitCode* = object
    ## A compiled function's executable code
    address*: pointer   # start address of the code
    size*: int          # size in bytes
    numLocals*: int     # total locals needed (may exceed WASM locals for Tier 2 result slots)

proc initJitMemPool*(size: int = DefaultJitPoolSize): JitMemPool =
  when defined(bl808kernel) or defined(wasmJitQemu):
    discard size
    raise newException(OSError, "bare-metal JIT requires a bounded executable region")
  else:
    if size <= 0 or size > high(int) - (JitPageSize - 1):
      raise newException(OSError, "invalid JIT memory pool size")
    let aligned = (size + JitPageSize - 1) and not (JitPageSize - 1)
    let p = mmap(nil, aligned.csize_t,
                 PROT_READ or PROT_WRITE or PROT_EXEC,
                 MAP_PRIVATE or MAP_ANON or MAP_JIT,
                 -1, 0)
    if cast[int](p) == -1:
      raise newException(OSError, "mmap failed for JIT memory pool")
    result.base = cast[ptr UncheckedArray[byte]](p)
    result.capacity = aligned
    result.ownsMapping = true

proc initJitMemPoolIn*(base: pointer, size: int,
                       control: JitRegionControl,
                       context: pointer = nil): JitMemPool =
  ## The hook must remove execute permission before granting writes and must
  ## clean data cache and seal read/execute permission before returning true
  ## from the execute transition. A nil hook is never accepted.
  if base == nil or size <= 0 or (cast[uint](base) and 7'u) != 0 or
      control == nil:
    raise newException(OSError, "invalid bounded JIT region")
  result.base = cast[ptr UncheckedArray[byte]](base)
  result.capacity = size
  result.regionControl = control
  result.regionContext = context

proc destroy*(pool: var JitMemPool) =
  if pool.base != nil:
    when not defined(bl808kernel) and not defined(wasmJitQemu):
      if pool.ownsMapping:
        discard munmap(pool.base, pool.capacity.csize_t)
    pool.base = nil
    pool.capacity = 0
    pool.used = 0
  for p in pool.sideData:
    deallocShared(p)
  pool.sideData = @[]

proc enableWrite*(pool: JitMemPool) {.inline.} =
  ## Switch to write mode (disable execute protection)
  ## Required on Apple Silicon before writing JIT code
  if pool.regionControl != nil:
    if not pool.regionControl(pool.regionContext, true):
      raise newException(OSError, "JIT region write transition failed")
  elif pool.ownsMapping:
    when defined(macosx) and not defined(bl808kernel):
      pthread_jit_write_protect_np(0)
  else:
    raise newException(OSError, "JIT region has no protection hook")

proc enableExecute*(pool: JitMemPool) {.inline.} =
  ## Switch to execute mode (disable write protection)
  ## Required on Apple Silicon before executing JIT code
  if pool.regionControl != nil:
    if not pool.regionControl(pool.regionContext, false):
      raise newException(OSError, "JIT region execute transition failed")
  elif pool.ownsMapping:
    when defined(macosx) and not defined(bl808kernel):
      pthread_jit_write_protect_np(1)
  else:
    raise newException(OSError, "JIT region has no protection hook")

proc invalidateICache*(address: pointer, size: int) {.inline.} =
  ## Publish newly written code on this core. A peer must perform its own
  ## instruction-cache handoff before entering the region.
  when defined(wasmJitQemu):
    ## QEMU virt RAM is coherent in this semantic test. This does not model
    ## BL808 D-cache maintenance or prove executable-region protection.
    discard address
    discard size
    {.emit: "__asm__ volatile (\".word 0x0000100f\" ::: \"memory\");".}
  elif defined(bl808kernel) and (defined(bl808m0) or defined(bl808d0)):
    if address != nil and size > 0:
      core.dcacheCleanRange(cast[uint](address), size.uint)
      core.fence()
      core.icacheInvalidateAll()
      core.fenceI()
  elif defined(bl808kernel):
    discard address
    discard size
    {.emit: "__asm__ volatile (\".word 0x0000100f\" ::: \"memory\");".}
  elif defined(macosx):
    sys_icache_invalidate(address, size.csize_t)
  elif defined(amd64) or defined(i386):
    discard address
    discard size
  else:
    builtinClearCache(address, cast[pointer](cast[uint](address) + size.uint))

proc alloc*(pool: var JitMemPool, size: int): JitCode =
  ## Allocate a chunk of executable memory from the pool
  if pool.base == nil or size <= 0 or size > high(int) - 7:
    raise newException(OSError, "invalid JIT allocation")
  let aligned = (size + 7) and not 7
  if pool.used < 0 or pool.used > pool.capacity or
      aligned > pool.capacity - pool.used:
    raise newException(OSError, "JIT memory pool exhausted")
  result.address = pool.base[pool.used].addr
  result.size = aligned
  pool.used += aligned

proc writeCode*(pool: var JitMemPool, code: openArray[uint32]): JitCode =
  ## Write a sequence of 32-bit fixed-width instructions to the pool
  ## Returns the JitCode handle for the written code
  ## Handles W^X transitions automatically
  if code.len == 0 or code.len > high(int) div 4:
    raise newException(OSError, "invalid JIT code length")
  let byteSize = code.len * 4
  let previousUsed = pool.used
  result = pool.alloc(byteSize)
  try:
    pool.enableWrite()
    copyMem(result.address, code[0].unsafeAddr, byteSize)
    pool.enableExecute()
    invalidateICache(result.address, byteSize)
  except:
    # The caller never receives a handle to partially published code.
    # A failed protection transition must leave execution disabled.
    pool.used = previousUsed
    raise

proc remaining*(pool: JitMemPool): int =
  pool.capacity - pool.used

proc reset*(pool: var JitMemPool) =
  ## Reset the pool (free all allocations but keep the mmap)
  pool.used = 0
