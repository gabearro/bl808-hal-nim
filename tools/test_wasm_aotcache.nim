## The desktop AOT cache must reject stale or damaged native code before
## copying any bytes to an executable region. This test does not execute code.
import std/os
import cps/wasm/jit/[aotcache, memory]
when defined(arm64) or defined(aarch64):
  import cps/wasm/jit/codegen

type RegionState = object
  writes: int
  seals: int

proc protect(ctx: pointer, writable: bool): bool {.nimcall.} =
  let state = cast[ptr RegionState](ctx)
  if writable: inc state[].writes
  else: inc state[].seals
  true

proc rejects(body: proc() {.closure.}) =
  var rejected = false
  try: body()
  except IOError, OSError: rejected = true
  doAssert rejected

let directory = "build/wasm-aotcache-test"
createDir(directory)
let path = directory / "cache.wjc"
let moduleHash = fnv1a64([0'u8, 0x61, 0x73, 0x6d])
let good = AotCache(moduleHash: moduleHash,
  funcs: @[CachedFunc(funcIdx: 3, tier: 2, numLocals: 2,
                       code: newSeq[byte](32))])
writeCacheFile(path, good)
let loaded = readCacheFile(path, moduleHash)
doAssert loaded.funcs.len == 1 and loaded.funcs[0].code.len == 32

var region: array[16, uint64]
var state: RegionState
var pool = initJitMemPoolIn(addr region[0], sizeof(region), protect, addr state)
let jc = linkCachedFunc(pool, loaded.funcs[0], 0, @[])
doAssert jc.address == (addr region[0]) and pool.used == 32
doAssert state.writes == 1 and state.seals == 1
let used = pool.used
rejects(proc() =
  var bad = loaded.funcs[0]
  bad.relocs = @[Relocation(offset: 0, kind: relocCallCache, siteIdx: 0)]
  discard linkCachedFunc(pool, bad, 0, @[]))
doAssert pool.used == used and state.writes == 1
pool.destroy()

when defined(arm64) or defined(aarch64):
  var buf = initAsmBuffer()
  buf.loadImm64Fixed(x16, 0'u64)
  buf.emit(0xd503201f'u32) # NOP following the relocation site.
  doAssert buf.code.len == 5
  var code = newSeq[byte](buf.code.len * 4)
  copyMem(addr code[0], addr buf.code[0], code.len)
  let reloc = CachedFunc(funcIdx: 4, tier: 2, code: code,
    relocs: @[Relocation(offset: 0, kind: relocDispatch)])
  var patchRegion: array[8, uint64]
  var patchState: RegionState
  var patchPool = initJitMemPoolIn(addr patchRegion[0], sizeof(patchRegion),
                                   protect, addr patchState)
  let patched = linkCachedFunc(patchPool, reloc, 0x1122334455667788'u64, @[])
  let words = cast[ptr UncheckedArray[uint32]](patched.address)
  for i, chunk in [0x7788'u32, 0x5566'u32, 0x3344'u32, 0x1122'u32]:
    doAssert ((words[i] shr 5) and 0xffff'u32) == chunk
  doAssert words[4] == 0xd503201f'u32
  patchPool.destroy()

rejects(proc() = discard readCacheFile(path, moduleHash xor 1'u64))
rejects(proc() =
  var duplicate = good
  duplicate.funcs.add(duplicate.funcs[0])
  writeCacheFile(path, duplicate))
rejects(proc() =
  var bad = good
  bad.funcs[0].relocs = @[Relocation(offset: 30, kind: relocDispatch)]
  writeCacheFile(path, bad))

let bytes = readFile(path)
var damaged = bytes
damaged[16] = char(ord(damaged[16]) xor 1) # Native target identity.
writeFile(path, damaged)
rejects(proc() = discard readCacheFile(path, moduleHash))
damaged = bytes
damaged[45] = char(ord(damaged[45]) xor 1) # First code byte.
writeFile(path, damaged)
rejects(proc() = discard readCacheFile(path, moduleHash))
writeFile(path, bytes[0 ..< 10])
rejects(proc() = discard readCacheFile(path, moduleHash))
damaged = bytes
for i in 20 ..< 24: damaged[i] = char(255) # Function count before allocation.
writeFile(path, damaged)
rejects(proc() = discard readCacheFile(path, moduleHash))
writeFile(path, bytes)
doAssert readCacheFile(path, moduleHash).funcs.len == 1
echo "JIT AOT cache validation:ok"
