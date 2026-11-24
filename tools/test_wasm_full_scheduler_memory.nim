import std/os
import bl808/[wasm_scheduler, wasm_store]
import cps/wasm/[linear_memory, types]

type
  Backing = object
    pages: array[3, array[WasmMemoryChunkBytes.int, byte]]
    failWrite: bool
    deferred: bool
    ready: bool
    pending: bool
    tick: uint64
  FactoryContext = object
    memory: ref LinearMemory

proc readPage(ctx: pointer, slot: uint32,
              dst: ptr UncheckedArray[byte]): bool =
  let backing = cast[ptr Backing](ctx)
  if slot >= backing.pages.len.uint32: return false
  backing.tick += 7
  copyMem(dst, addr backing.pages[slot.int][0], WasmMemoryChunkBytes.int)
  true

proc writePage(ctx: pointer, slot: uint32,
               src: ptr UncheckedArray[byte]): bool =
  let backing = cast[ptr Backing](ctx)
  if backing.failWrite or slot >= backing.pages.len.uint32: return false
  backing.tick += 11
  copyMem(addr backing.pages[slot.int][0], src, WasmMemoryChunkBytes.int)
  true

proc backingTick(ctx: pointer): uint64 =
  cast[ptr Backing](ctx).tick

proc deferredWrite(ctx: pointer, slot: uint32,
                   src: ptr UncheckedArray[byte]): LinearMemoryStatus =
  let backing = cast[ptr Backing](ctx)
  if not backing.ready:
    backing.pending = true
    return lmWouldBlock
  backing.pending = false
  backing.ready = false
  if writePage(ctx, slot, src): lmOk else: lmBackingWriteFailed

proc makeMemory(ctx: pointer, memType: MemType): ref LinearMemory =
  let owner = cast[ptr FactoryContext](ctx)
  doAssert memType.limits.min == 2 and memType.limits.max == 2
  owner.memory

proc freshMemory(backing: ptr Backing): ref LinearMemory =
  new(result)
  let provider = if backing.deferred:
    LinearMemoryBacking(ctx: backing, slots: 3,
      readPage: readPage, writePageStatus: deferredWrite,
      tick: backingTick)
  else:
    LinearMemoryBacking(ctx: backing, slots: 3,
      readPage: readPage, writePage: writePage,
      tick: backingTick)
  doAssert result[].initLinearMemory(LinearMemoryConfig(
    initialPages: 2, maxPages: 2, admissionPages: 2,
    maxCommittedChunks: 3, residentChunks: 1), provider) == lmOk

let guest = readFile(paramStr(1))
var image = newSeq[byte](WasmProgramHeaderLen.int + guest.len)
doAssert initWasmProgramImage(
  cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
  guest.toOpenArrayByte(0, guest.len - 1)) == wasmProgramOk
let base = cast[ptr UncheckedArray[byte]](addr image[0])

resetWasmScheduler()
var backing: Backing
var owner = FactoryContext(memory: freshMemory(addr backing))
let started = startFullWasmImageTaskI32(base, image.len.uint32,
  "cross_page", [], maxTotalFuel = 64, maxMemoryPages = 2,
  memoryFactory = makeMemory, memoryFactoryContext = addr owner)
doAssert started.status == wasmSchedOk
var current = started
var faults = 0
var slices = 0
while current.state in {wasmTaskReady, wasmTaskYielded, wasmTaskBlockedMemory}:
  if current.state == wasmTaskBlockedMemory:
    inc faults
    doAssert serviceWasmTaskMemoryFault(started.id).state == wasmTaskYielded
    current = getWasmTask(started.id)
  else:
    inc slices
    current = resumeWasmTask(started.id, 10)
  doAssert faults < 20 and slices < 20
doAssert faults >= 2 and current.status == wasmSchedOk and
  current.state == wasmTaskExited and current.result == 305419896'i32
doAssert owner.memory[].stats().pageOuts > 0 and
  owner.memory[].stats().pageIns > 0
let memoryTelemetry = getWasmTaskMemoryTelemetry(started.id)
doAssert memoryTelemetry.found and memoryTelemetry.fullInterpreter and
  memoryTelemetry.guestPages == 2 and memoryTelemetry.pageOuts > 0 and
  memoryTelemetry.pageIns > 0 and
  memoryTelemetry.maxPageInTicks == 7 and
  memoryTelemetry.maxPageOutTicks == 11 and
  memoryTelemetry.completedFaults > 0
doAssert killWasmTask(started.id).state == wasmTaskKilled

var failedBacking: Backing
failedBacking.failWrite = true
var failedOwner = FactoryContext(memory: freshMemory(addr failedBacking))
let failed = startFullWasmImageTaskI32(base, image.len.uint32,
  "cross_page", [], maxTotalFuel = 64, maxMemoryPages = 2,
  memoryFactory = makeMemory, memoryFactoryContext = addr failedOwner)
doAssert failed.status == wasmSchedOk
let first = resumeWasmTask(failed.id, 10)
doAssert first.state == wasmTaskBlockedMemory
let ioFailure = serviceWasmTaskMemoryFault(failed.id)
doAssert ioFailure.status == wasmSchedBackingFailed and
  ioFailure.state == wasmTaskTrapped
doAssert getWasmTaskMemoryTelemetry(failed.id).backingFailures == 1
for _ in 0 .. WasmTaskTrapReapPolls:
  discard reapTrappedSlots()
doAssert getWasmTask(failed.id).status == wasmSchedNoTask

var deferredBacking: Backing
deferredBacking.deferred = true
var deferredOwner = FactoryContext(memory: freshMemory(addr deferredBacking))
let deferred = startFullWasmImageTaskI32(base, image.len.uint32,
  "cross_page", [], maxTotalFuel = 64, maxMemoryPages = 2,
  memoryFactory = makeMemory, memoryFactoryContext = addr deferredOwner)
doAssert deferred.status == wasmSchedOk
var pending = deferred
var deferredFaults = 0
while pending.state in {wasmTaskReady, wasmTaskYielded, wasmTaskBlockedMemory}:
  if pending.state == wasmTaskBlockedMemory:
    let service = serviceWasmTaskMemoryFault(deferred.id)
    if deferredBacking.pending:
      doAssert service.state == wasmTaskBlockedMemory
      deferredBacking.ready = true
    else:
      doAssert service.state in {wasmTaskBlockedMemory, wasmTaskYielded}
    inc deferredFaults
  else:
    pending = resumeWasmTask(deferred.id, 10)
  pending = getWasmTask(deferred.id)
  doAssert deferredFaults < 20
doAssert deferredFaults > 1 and pending.state == wasmTaskExited and
  pending.result == 305419896'i32
doAssert killWasmTask(deferred.id).state == wasmTaskKilled
echo "full WASM task fault service PASS: exact resume and failed backing"
