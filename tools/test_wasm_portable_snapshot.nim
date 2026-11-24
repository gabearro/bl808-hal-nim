import std/os
import bl808/enclave/sha256
import cps/wasm/[binary, validate, runtime, types]
when defined(wasmChunkedMemory):
  import cps/wasm/linear_memory
  import wasm_migration_state_fixture

  type SnapshotBacking = array[3, array[WasmMemoryChunkBytes.int, byte]]

  proc readPage(ctx: pointer, slot: uint32,
                dst: ptr UncheckedArray[byte]): bool =
    let backing = cast[ptr SnapshotBacking](ctx)
    if slot >= backing[].len.uint32: return false
    copyMem(dst, addr backing[][slot][0], WasmMemoryChunkBytes.int)
    true

  proc writePage(ctx: pointer, slot: uint32,
                 src: ptr UncheckedArray[byte]): bool =
    let backing = cast[ptr SnapshotBacking](ctx)
    if slot >= backing[].len.uint32: return false
    copyMem(addr backing[][slot][0], src, WasmMemoryChunkBytes.int)
    true

  proc pagedFactory(ctx: pointer, memType: MemType): ref LinearMemory =
    new(result)
    let pages = memType.limits.max
    if result[].initLinearMemory(LinearMemoryConfig(initialPages: memType.limits.min,
        maxPages: pages, admissionPages: pages, maxCommittedChunks: 3, residentChunks: 1),
        LinearMemoryBacking(ctx: ctx, slots: 3, readPage: readPage, writePage: writePage)) != lmOk:
      return nil

  proc checkPagedSource(module: WasmModule, digest: array[32, byte]) =
    var backing: SnapshotBacking
    var source = initWasmVM()
    source.setMemoryBackendFactory(pagedFactory, addr backing)
    let index = source.instantiate(module, [])
    let entry = source.getExport(index, "run").idx
    var running: WasmContinuation
    var faults = 0
    while running.instructions < WasmMutableInstructionsBeforeCapture.uint64:
      let fuel = WasmMutableInstructionsBeforeCapture - running.instructions.uint32
      discard source.executeSlice(entry, [], running, fuel)
      if running.status == wesMemoryBlocked:
        inc faults
        doAssert faults <= 4
        doAssert source.serviceExecutionMemoryFault(running) == lmOk
        # A resolved fault can make the scheduler runnable while the WASM
        # memory instruction still has uncommitted transfer progress.
        doAssert running.status == wesYielded
        doAssert source.capturePortableSnapshot(running, digest).status == wpsNotSuspended
      else:
        doAssert running.status == wesYielded
    let memory = source.getMemory(index).chunked
    let stats = memory[].stats()
    doAssert stats.pageOuts == 2 and stats.residentChunks == 1 and faults == 2
    let snapshot = source.capturePortableSnapshot(running, digest, 512)
    doAssert snapshot.status == wpsOk and memory[].stats() == stats
    var destination = initWasmVM()
    let moduleIdx = destination.instantiateForRestore(module)
    var resumed: WasmContinuation
    doAssert destination.restorePortableSnapshot(resumed, snapshot.bytes, digest) == wpsOk
    let target = destination.getExport(moduleIdx, "run").idx
    doAssert destination.executeSlice(target, [], resumed, 64)[0].i32 == WasmMutableResult

proc corruptStoreWithValidChecksum(bytes: var seq[byte]) =
  # Last byte is a passive data segment's dropped flag. Frame the invalid
  # value correctly to exercise store validation after the memory records.
  bytes[^1] = 2
  var crc = high(uint32)
  for i, value in bytes:
    if i in 60 .. 63: continue
    crc = crc xor value.uint32
    for _ in 0 ..< 8:
      let polynomial = if (crc and 1) != 0: 0xEDB8_8320'u32 else: 0'u32
      crc = (crc shr 1) xor polynomial
  crc = not crc
  for i in 0 ..< 4: bytes[60 + i] = (crc shr (i * 8)).byte

proc checkMutable(bytes: seq[byte]) =
  let digest = sha256(bytes)
  let module = decodeModule(bytes)
  validateModule(module)
  var source = initWasmVM()
  let sourceModule = source.instantiate(module, [])
  let root = source.getExport(sourceModule, "run").idx
  var running: WasmContinuation
  discard source.executeSlice(root, [], running, 17)
  doAssert running.status == wesYielded
  doAssert source.capturePortableSnapshot(running, digest, 120).status == wpsTooLarge
  let snapshot = source.capturePortableSnapshot(running, digest, 512)
  doAssert snapshot.status == wpsOk and snapshot.bytes[4] == 2

  when defined(wasmChunkedMemory):
    var small = initWasmVM()
    var frames = 2'u32
    small.setMemoryBackendFactory(mutableMemoryFactory, addr frames)
    let smallModule = small.instantiateForRestore(module)
    var rejected: WasmContinuation
    doAssert small.restorePortableSnapshot(rejected, snapshot.bytes, digest) == wpsInvalidSnapshot
    doAssert small.getMemory(smallModule).chunked[].currentPages() == 1
    doAssert small.getGlobal(smallModule, 0).value.i32 == 1 and small.callStackTop == 0

  var dest = initWasmVM()
  when defined(wasmChunkedMemory):
    dest.setMemoryBackendFactory(mutableMemoryFactory)
  let destModule = dest.instantiateForRestore(module)
  let function = dest.getExport(destModule, "run").idx
  var resumed: WasmContinuation
  var badStore = snapshot.bytes
  badStore.corruptStoreWithValidChecksum()
  doAssert dest.restorePortableSnapshot(resumed, badStore, digest) == wpsInvalidSnapshot
  doAssert dest.getMemory(destModule).memCurrentPages() == 1
  doAssert dest.getGlobal(destModule, 0).value.i32 == 1 and dest.callStackTop == 0
  doAssert dest.getTable(destModule, 0).elems.len == 1 and not dest.store.datas[1].dropped
  doAssert dest.restorePortableSnapshot(resumed, snapshot.bytes, digest) == wpsOk
  doAssert dest.getMemory(destModule).memCurrentPages() == 2
  doAssert dest.getGlobal(destModule, 0).value.i32 == 7
  doAssert dest.getTable(destModule, 0).elems.len == 2
  doAssert dest.executeSlice(function, [], resumed, 64)[0].i32 == 16_909_075
  doAssert resumed.status == wesComplete
  doAssert dest.store.elems[0].dropped and dest.store.datas[1].dropped
  when defined(wasmChunkedMemory):
    checkPagedSource(module, digest)
    # A flat source packs the cross-page value into one run. A one-frame
    # destination must resume that same run at the byte following the fault.
    var disk: SnapshotBacking
    var cold = initWasmVM()
    cold.setMemoryBackendFactory(pagedFactory, addr disk)
    let coldModule = cold.instantiateForRestore(module)
    var continuation: WasmContinuation
    var pending: WasmPortableRestore
    doAssert cold.beginPortableRestore(continuation, badStore, digest, pending) == wpsInvalidSnapshot
    doAssert cold.getMemory(coldModule).memCurrentPages() == 1 and
      cold.getMemory(coldModule).chunked[].stats().pageOuts == 0
    doAssert cold.beginPortableRestore(continuation, snapshot.bytes, digest, pending) == wpsPending
    var status = wpsPending
    var polls = 0
    while status == wpsPending:
      doAssert polls < 8 and continuation.status == wesReady
      status = cold.pollPortableRestore(continuation, snapshot.bytes, pending)
      inc polls
    doAssert status == wpsOk and continuation.status == wesYielded
    doAssert cold.getMemory(coldModule).chunked[].stats().pageOuts == 2
    let coldEntry = cold.getExport(coldModule, "run").idx
    var output: seq[WasmValue]
    for _ in 0 ..< 16:
      output = cold.executeSlice(coldEntry, [], continuation, 64)
      if continuation.status == wesComplete: break
      doAssert continuation.status == wesMemoryBlocked
      doAssert cold.serviceExecutionMemoryFault(continuation) == lmOk
    doAssert continuation.status == wesComplete and output[0].i32 == WasmMutableResult
  echo "portable WASM mutable state:ok bytes=", snapshot.bytes.len

proc main() =
  doAssert paramCount() == 2
  let bytes = cast[seq[byte]](readFile(paramStr(1)))
  let digest = sha256(bytes)
  let module = decodeModule(bytes)
  validateModule(module)
  var source = initWasmVM()
  var destination = initWasmVM()
  let sourceModule = source.instantiate(module, [])
  let destModule = destination.instantiate(module, [])
  let sourceFunc = source.getExport(sourceModule, "deep").idx
  let destFunc = destination.getExport(destModule, "deep").idx
  doAssert sourceFunc == destFunc
  var running: WasmContinuation
  doAssert source.capturePortableSnapshot(running, digest).status ==
    wpsNotSuspended
  for _ in 0 ..< 8:
    discard source.executeSlice(sourceFunc, [], running, 5)
    doAssert running.status == wesYielded
  doAssert source.callStackTop > 1
  let snapshot = source.capturePortableSnapshot(running, digest)
  doAssert snapshot.status == wpsOk and
    snapshot.bytes.len <= WasmPortableMaxBytes
  var wrongDigest = digest
  wrongDigest[0] = wrongDigest[0] xor 1
  var migrated: WasmContinuation
  doAssert destination.restorePortableSnapshot(migrated,
    snapshot.bytes, wrongDigest) == wpsWrongModule
  doAssert destination.callStackTop == 0
  var damaged = snapshot.bytes
  damaged[^1] = damaged[^1] xor 1
  doAssert destination.restorePortableSnapshot(migrated,
    damaged, digest) == wpsInvalidSnapshot
  doAssert destination.callStackTop == 0
  doAssert destination.restorePortableSnapshot(migrated,
    snapshot.bytes, digest) == wpsOk
  doAssert migrated.status == wesYielded and
    migrated.instructions == running.instructions
  source.abortExecution(running)
  doAssert running.status == wesReady
  var final: seq[WasmValue]
  var slices = 0
  while migrated.status == wesYielded and slices < 100:
    final = destination.executeSlice(destFunc, [], migrated, 8)
    inc slices
  doAssert migrated.status == wesComplete and
    final.len == 1 and final[0].i32 == 42
  echo "portable WASM suspension and restore:ok bytes=", snapshot.bytes.len
  checkMutable(cast[seq[byte]](readFile(paramStr(2))))

main()
