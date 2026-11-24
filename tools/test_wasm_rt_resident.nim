## A concrete hard-slot guest with one pinned, resident memory chunk and no
## imports, bulk operations, SD, cross-core IPC, or flash mutations.
## Synthetic ticks only exercise admission and dispatch policy.
import std/os
import bl808/[wasm_rt_policy, wasm_scheduler, wasm_store]
import cps/wasm/[linear_memory, types]

type FactoryContext = object
  memory: ref LinearMemory

proc makeMemory(ctx: pointer, memType: MemType): ref LinearMemory =
  let owner = cast[ptr FactoryContext](ctx)
  doAssert memType.limits.min == 1 and memType.limits.hasMax and
    memType.limits.max == 1
  owner.memory

proc freshMemory(pinned: bool): ref LinearMemory =
  new(result)
  doAssert result[].initLinearMemory(LinearMemoryConfig(
    initialPages: 1, maxPages: 1, admissionPages: 1,
    maxCommittedChunks: 1, residentChunks: 1)) == lmOk
  if pinned:
    doAssert result[].pinRange(256, 4, writable = true) == lmOk
    doAssert result[].hardResidentReady()

let guest = readFile(paramStr(1))
var image = newSeq[byte](WasmProgramHeaderLen.int + guest.len)
doAssert initWasmProgramImage(
  cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
  guest.toOpenArrayByte(0, guest.len - 1)) == wasmProgramOk
let base = cast[ptr UncheckedArray[byte]](addr image[0])

var now = 0'u64
proc tick(): uint64 {.nimcall.} =
  result = now
  inc now

resetWasmScheduler()
doAssert initWasmRtScheduler(1, 0, 100) == wrOk
var owner = FactoryContext(memory: freshMemory(true))
let started = startFullWasmImageTaskI32(base, image.len.uint32,
  "hard-slot", [], maxTotalFuel = 64, maxMemoryPages = 1,
  memoryFactory = makeMemory, memoryFactoryContext = addr owner)
doAssert started.status == wasmSchedOk
let hard = WasmRtSpec(class: wrHard, releaseTick: 0, deadlineTick: 80,
  budgetTicks: 50, maxSliceTicks: 30, startJitterTicks: 5,
  affinityMask: 1, slotOffsetTicks: 0, slotLengthTicks: 60,
  residentWorkingSet: true, boundedImports: true,
  noPeerDependency: true, noFlashMutation: true)
doAssert admitWasmTaskRt(started.id, hard) == wrOk
doAssert runWasmSchedulerRt(tick, 30, fuelPerTask = 64) == 1
let completed = getWasmTask(started.id)
doAssert completed.status == wasmSchedOk and
  completed.state == wasmTaskExited and completed.result == 305419899'i32
let memory = getWasmTaskMemoryTelemetry(started.id)
doAssert memory.found and memory.fullInterpreter and
  memory.committedChunks == 1 and memory.residentChunks == 1 and
  memory.pageIns == 0 and memory.pageOuts == 0 and
  memory.wouldBlock == 0 and memory.backingFailures == 0
doAssert wasmSchedulerRtTelemetry().hardFaults == 0
discard killWasmTask(started.id)

var unpinned = FactoryContext(memory: freshMemory(false))
let unsafe = startFullWasmImageTaskI32(base, image.len.uint32,
  "hard-slot", [], maxTotalFuel = 64, maxMemoryPages = 1,
  memoryFactory = makeMemory, memoryFactoryContext = addr unpinned)
doAssert unsafe.status == wasmSchedOk
doAssert admitWasmTaskRt(unsafe.id, hard) == wrUnsafeHardSlot
discard killWasmTask(unsafe.id)

let unboundedGuest = readFile(paramStr(2))
var unboundedImage = newSeq[byte](WasmProgramHeaderLen.int + unboundedGuest.len)
doAssert initWasmProgramImage(
  cast[ptr UncheckedArray[byte]](addr unboundedImage[0]),
  unboundedImage.len.uint32,
  unboundedGuest.toOpenArrayByte(0, unboundedGuest.len - 1)) == wasmProgramOk
var unboundedOwner = FactoryContext(memory: freshMemory(true))
let unbounded = startFullWasmImageTaskI32(
  cast[ptr UncheckedArray[byte]](addr unboundedImage[0]),
  unboundedImage.len.uint32, "hard-slot", [], maxTotalFuel = 64,
  maxMemoryPages = 1, memoryFactory = makeMemory,
  memoryFactoryContext = addr unboundedOwner)
doAssert unbounded.status == wasmSchedOk
doAssert admitWasmTaskRt(unbounded.id, hard) == wrUnsafeHardSlot
discard killWasmTask(unbounded.id)
echo "WASM RT resident hard slot PASS: pinned chunk, no fault, unsafe rejection"
