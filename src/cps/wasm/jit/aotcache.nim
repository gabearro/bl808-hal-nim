## Persistent AOT JIT code cache.
##
## Serialises compiled Tier-2 machine-code blobs to disk so they can be
## re-loaded on the next run without going through the full optimising
## pipeline.  A per-module FNV-1a hash is used as the cache key — if the
## module changes the cache is silently discarded.
##
## Format (little-endian, no padding):
##   Header:
##     magic    : u32  = 0x57414A43  ("WAJC")
##     version  : u32  = 5
##     hash     : u64  (FNV-1a 64 of module bytes)
##     target   : u32  (native ISA, pointer ABI, and OS identity)
##     numFuncs : u32
##   Per-function record (repeated numFuncs times):
##     funcIdx  : u32
##     tier     : u8   (1 = baseline, 2 = optimising)
##     numLocals: u32
##     codeSize : u32
##     numRelocs: u32
##     checksum : u32  (CRC-32 of code and relocation records)
##     code     : codeSize bytes
##     relocs   : numRelocs × Relocation
##   Relocation:
##     offset   : u32  (byte offset within code where imm64 address lives)
##     kind     : u8   (0 = dispatch-func, 1 = call-indirect cache slot N)
##     siteIdx  : u32  (for kind=1: call_indirect site index; 0 otherwise)
##
## Absolute addresses embedded in the code are patched on load:
##   kind=0  → patched with the current address of tier2CallIndirectDispatch
##   kind=1  → patched with a freshly-allocated CallIndirectCache*

import std/[os, streams, strutils]
import memory
import relocation
export relocation

const
  CacheMagic*   = 0x57414A43'u32   # "WAJC"
  CacheVersion* = 5'u32
  MaxCacheFuncs* = 4096
  MaxCacheCodeBytes* = 4 * 1024 * 1024
  MaxCacheFuncBytes* = 1024 * 1024
  MaxCacheRelocs* = 65536
  MaxCacheSites* = 65536'u32
  MaxCacheFileBytes* = 8 * 1024 * 1024
  CacheTarget* =
    (when defined(amd64): 1'u32
     elif defined(arm64) or defined(aarch64): 2'u32
     elif defined(riscv64): 3'u32
     elif defined(riscv32): 4'u32
     else: 0'u32) or
    (when sizeof(pointer) == 8: 0x100'u32 else: 0x200'u32) or
    (when defined(macosx): 0x10000'u32
     elif defined(linux): 0x20000'u32
     elif defined(windows): 0x30000'u32
     else: 0x40000'u32)

# ---------------------------------------------------------------------------
# Relocation records
# ---------------------------------------------------------------------------

type
  CachedFunc* = object
    funcIdx*:   uint32
    tier*:      uint8
    numLocals*: uint32
    code*:      seq[byte]
    relocs*:    seq[Relocation]

  AotCache* = object
    moduleHash*: uint64
    funcs*:      seq[CachedFunc]

proc crc32Byte(crc: uint32, b: byte): uint32 {.inline.} =
  result = crc xor b.uint32
  for _ in 0 ..< 8:
    result = (result shr 1) xor
      (if (result and 1) != 0: 0xedb88320'u32 else: 0'u32)

proc cacheChecksum(f: CachedFunc): uint32 =
  result = not 0'u32
  for b in f.code:
    result = crc32Byte(result, b)
  for r in f.relocs:
    for shift in [0, 8, 16, 24]:
      result = crc32Byte(result, byte(r.offset shr shift))
    result = crc32Byte(result, r.kind.uint8)
    for shift in [0, 8, 16, 24]:
      result = crc32Byte(result, byte(r.siteIdx shr shift))
  result = not result

proc validCachedFunc(f: CachedFunc): bool =
  when not (defined(amd64) or defined(arm64) or defined(aarch64)):
    # The current relocations encode x86 movabs or AArch64 MOVZ/MOVK.
    # RISC-V needs a different relocation/link contract.
    return false
  if f.tier != 2 or f.numLocals > 65536'u32 or
      f.code.len == 0 or f.code.len > MaxCacheFuncBytes or
      f.relocs.len > MaxCacheRelocs:
    return false
  for r in f.relocs:
    if r.kind == relocDispatch and r.siteIdx != 0: return false
    if r.kind == relocCallCache and r.siteIdx >= MaxCacheSites: return false
    when defined(arm64) or defined(aarch64):
      if (r.offset and 3) != 0 or
          r.offset.uint64 + 16'u64 > f.code.len.uint64: return false
    else:
      if r.offset.uint64 + 8'u64 > f.code.len.uint64: return false
  true

proc validCache(cache: AotCache): bool =
  if cache.funcs.len > MaxCacheFuncs: return false
  var total = 0
  var fileBytes = 24'u64
  for i, f in cache.funcs:
    if not validCachedFunc(f) or f.code.len > MaxCacheCodeBytes - total:
      return false
    total += f.code.len
    fileBytes += 21'u64 + f.code.len.uint64 + f.relocs.len.uint64 * 9'u64
    if fileBytes > MaxCacheFileBytes.uint64: return false
    for j in 0 ..< i:
      if cache.funcs[j].funcIdx == f.funcIdx: return false
  true

# ---------------------------------------------------------------------------
# Module hashing: FNV-1a 64-bit
# ---------------------------------------------------------------------------

proc fnv1a64*(data: openArray[byte]): uint64 =
  result = 0xcbf29ce484222325'u64
  for b in data:
    result = result xor b.uint64
    result = result * 0x00000100000001b3'u64

# ---------------------------------------------------------------------------
# Serialise
# ---------------------------------------------------------------------------

proc writeCacheFile*(path: string, cache: AotCache) =
  ## Write cache to *path* atomically (write to tmp, then rename).
  if not validCache(cache):
    raise newException(IOError, "Invalid JIT cache record")
  let tmp = path & ".tmp"
  let s = newFileStream(tmp, fmWrite)
  if s == nil:
    raise newException(IOError, "Cannot create cache file: " & tmp)
  try:
    s.write(CacheMagic)
    s.write(CacheVersion)
    s.write(cache.moduleHash)
    s.write(CacheTarget)
    s.write(cache.funcs.len.uint32)
    for f in cache.funcs:
      s.write(f.funcIdx)
      s.write(f.tier)
      s.write(f.numLocals)
      s.write(f.code.len.uint32)
      s.write(f.relocs.len.uint32)
      s.write(cacheChecksum(f))
      if f.code.len > 0:
        s.writeData(unsafeAddr f.code[0], f.code.len)
      for r in f.relocs:
        s.write(r.offset)
        s.write(r.kind.uint8)
        s.write(r.siteIdx)
  finally:
    s.close()
  moveFile(tmp, path)   # atomic on POSIX (same filesystem)

# ---------------------------------------------------------------------------
# Deserialise
# ---------------------------------------------------------------------------

proc readCacheFile*(path: string, expectedHash: uint64): AotCache =
  ## Read and verify cache.  Raises IOError on missing file, wrong format,
  ## or hash mismatch (caller should catch and treat as cache-miss).
  when not (defined(amd64) or defined(arm64) or defined(aarch64)):
    raise newException(IOError, "Native JIT cache unsupported on this ISA")
  if getFileSize(path) > MaxCacheFileBytes:
    raise newException(IOError, "JIT cache exceeds size limit")
  let s = newFileStream(path, fmRead)
  if s == nil:
    raise newException(IOError, "Cannot open cache file: " & path)
  defer: s.close()

  let magic   = s.readUInt32()
  let version = s.readUInt32()
  if magic != CacheMagic or version != CacheVersion:
    raise newException(IOError, "Cache format mismatch (stale cache?)")
  let storedHash = s.readUInt64()
  if storedHash != expectedHash:
    raise newException(IOError, "Cache module hash mismatch — recompiling")
  if s.readUInt32() != CacheTarget:
    raise newException(IOError, "Cache native target mismatch")

  let n = s.readUInt32().int
  if n < 0 or n > MaxCacheFuncs:
    raise newException(IOError, "Cache function count limit")
  result.moduleHash = storedHash
  result.funcs.setLen(n)
  var total = 0
  for i in 0 ..< n:
    let funcIdx  = s.readUInt32()
    let tier     = s.readUInt8()
    let nlocs    = s.readUInt32()
    let csz      = s.readUInt32().int
    let nrelocs  = s.readUInt32().int
    let checksum = s.readUInt32()
    if csz <= 0 or csz > MaxCacheFuncBytes or
        csz > MaxCacheCodeBytes - total or nrelocs < 0 or
        nrelocs > MaxCacheRelocs:
      raise newException(IOError, "Cache record size limit")
    total += csz
    var code: seq[byte]
    if csz > 0:
      code.setLen(csz)
      let got = s.readData(addr code[0], csz)
      if got != csz:
        raise newException(IOError, "Cache truncated reading func code")
    var relocs: seq[Relocation]
    relocs.setLen(nrelocs)
    for j in 0 ..< nrelocs:
      let off  = s.readUInt32()
      let rawKind = s.readUInt8()
      if rawKind > relocCallCache.uint8:
        raise newException(IOError, "Invalid cache relocation kind")
      let kind = RelocKind(rawKind)
      let si   = s.readUInt32()
      relocs[j] = Relocation(offset: off, kind: kind, siteIdx: si)
    result.funcs[i] = CachedFunc(funcIdx: funcIdx, tier: tier,
                                  numLocals: nlocs, code: code, relocs: relocs)
    if not validCachedFunc(result.funcs[i]) or
        cacheChecksum(result.funcs[i]) != checksum:
      raise newException(IOError, "Invalid JIT cache record checksum")
  if not validCache(result) or not s.atEnd():
    raise newException(IOError, "Invalid JIT cache contents")

# ---------------------------------------------------------------------------
# Link: copy code into JIT pool, apply relocations
# ---------------------------------------------------------------------------

proc patchAbsoluteAddr(dst: pointer, newVal: uint64) {.inline.} =
  ## Write a 64-bit absolute address into the code at *dst*.
  ##
  ## x86-64: the immediate sits inline as a native 64-bit value (10-byte
  ##         movabs encoding); just overwrite the 8 bytes.
  ##
  ## AArch64: the address is spread across 4 × MOVZ/MOVK instructions
  ##          (A64 encoding: bits[20:5] carry each 16-bit chunk).
  ##          We patch all 4 instructions in place.
  when defined(arm64) or defined(aarch64):
    # MOVZ / MOVK pattern emitted by loadImm64:
    #   MOVZ Xd, #imm0, LSL #0   — bits[20:5] = imm[15:0]
    #   MOVK Xd, #imm1, LSL #16  — bits[20:5] = imm[31:16]
    #   MOVK Xd, #imm2, LSL #32  — bits[20:5] = imm[47:32]
    #   MOVK Xd, #imm3, LSL #48  — bits[20:5] = imm[63:48]
    let instrs = cast[ptr UncheckedArray[uint32]](dst)
    let chunks: array[4, uint16] = [
      uint16(newVal and 0xFFFF),
      uint16((newVal shr 16) and 0xFFFF),
      uint16((newVal shr 32) and 0xFFFF),
      uint16((newVal shr 48) and 0xFFFF),
    ]
    for i in 0 ..< 4:
      # Clear old imm16 (bits 20:5) and write new chunk
      instrs[i] = (instrs[i] and 0xFFE0001F'u32) or
                  (uint32(chunks[i]) shl 5)
  else:
    # x86-64: 8-byte little-endian immediate at dst
    cast[ptr uint64](dst)[] = newVal

proc linkCachedFunc*(pool: var JitMemPool,
                     f: CachedFunc,
                     dispatchAddr: uint64,
                     siteMap: seq[pointer]): JitCode =
  ## Copy f.code into the pool, apply relocations, return JitCode.
  ## *dispatchAddr*  = address of tier2CallIndirectDispatch (cast[uint64])
  ## *siteMap*       = pre-allocated CallIndirectCache* per call_indirect site
  if not validCachedFunc(f):
    raise newException(IOError, "Invalid JIT cache function")
  for r in f.relocs:
    if r.kind == relocCallCache and
        (r.siteIdx.int >= siteMap.len or siteMap[r.siteIdx.int] == nil):
      raise newException(IOError, "Unresolved JIT cache relocation")

  let previousUsed = pool.used
  let jc = pool.alloc(f.code.len)
  try:
    pool.enableWrite()
    copyMem(jc.address, unsafeAddr f.code[0], f.code.len)

  # Apply relocations: patch the embedded absolute address at each site
    for r in f.relocs:
      let patchAddr = cast[pointer](cast[int](jc.address) + r.offset.int)
      case r.kind
      of relocDispatch:
        patchAbsoluteAddr(patchAddr, dispatchAddr)
      of relocCallCache:
        patchAbsoluteAddr(patchAddr, cast[uint64](siteMap[r.siteIdx.int]))

    pool.enableExecute()
    when not (defined(amd64) or defined(i386)):
      invalidateICache(jc.address, f.code.len)
  except:
    pool.used = previousUsed
    raise

  result = JitCode(address: jc.address, size: f.code.len,
                   numLocals: f.numLocals.int)

# ---------------------------------------------------------------------------
# Cache path helpers
# ---------------------------------------------------------------------------

proc defaultCacheDir*(): string =
  ## Returns ~/.cache/wasm-jit  (or $XDG_CACHE_HOME/wasm-jit if set).
  let xdg = getEnv("XDG_CACHE_HOME")
  if xdg.len > 0: return xdg / "wasm-jit"
  getHomeDir() / ".cache" / "wasm-jit"

proc cachePath*(cacheDir: string, moduleHash: uint64): string =
  ## Deterministic path for cache file: <dir>/<hex16>.wjc
  result = cacheDir / toHex(moduleHash, 16) & ".wjc"
