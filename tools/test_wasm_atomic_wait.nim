import std/[json, os, strutils]
import bl808/[wasm_rt_kernel, wasm_rt_policy, wasm_scheduler, wasm_store]
import cps/wasm/[binary, component, runtime, types, validate]
when defined(wasmChunkedMemory):
  import cps/wasm/linear_memory

let manifest = paramStr(1)
let directory = manifest.parentDir()
var oracle = initWasmVM()
var moduleIndex = -1
var runtimeChecks, rejected: int
for command in parseFile(manifest)["commands"]:
  let kind = command["type"].getStr()
  case kind
  of "module", "assert_invalid":
    let bytes = cast[seq[byte]](readFile(directory / command["filename"].getStr()))
    let module = decodeModule(bytes)
    if kind == "module":
      validateModule(module)
      moduleIndex = oracle.instantiate(module, [])
    else:
      try:
        validateModule(module)
        raiseAssert "atomic validation accepted an invalid instruction"
      except ValidationError:
        inc rejected
  of "assert_return", "assert_trap":
    let action = command["action"]
    var args: seq[WasmValue]
    for item in action["args"]:
      let value = item["value"].getStr()
      let bits = if value.startsWith("-"): cast[uint64](parseBiggestInt(value))
        else: parseBiggestUInt(value).uint64
      args.add(if item["type"].getStr() == "i64": wasmI64(cast[int64](bits))
        else: wasmI32(cast[int32](bits)))
    try:
      let values = oracle.invoke(moduleIndex, action["field"].getStr(), args)
      doAssert kind == "assert_return" and values.len == 1
      doAssert values[0].i32 == command["expected"][0]["value"].getStr().parseInt().int32
    except WasmTrap as error:
      doAssert kind == "assert_trap" and error.msg.contains(command["text"].getStr()), error.msg
    inc runtimeChecks
  else: raiseAssert "unexpected WAST command: " & kind
doAssert runtimeChecks == 10 and rejected == 3

type WaitTurn = object
  continuation: WasmContinuation
  arena: WasmExecutionArena
  entry: int

proc resume(vm: var WasmVM, turn: var WaitTurn, args: openArray[WasmValue]): seq[WasmValue] =
  vm.swapWasmExecutionArena(turn.arena)
  defer: vm.swapWasmExecutionArena(turn.arena)
  vm.executeSlice(turn.entry, args, turn.continuation, 16)

var now = 100'u64
proc tick(): uint64 = now
let wasm = cast[seq[byte]](readFile(directory / "cases.0.wasm"))
var vm = initWasmVM()
vm.setWasmAtomicClock(tick)
let index = vm.instantiate(decodeModule(wasm), [])
let unrelated = vm.instantiate(decodeModule(wasm), [])
let wait32 = vm.getExport(index, "wait32").idx
let wait64 = vm.getExport(index, "wait64").idx
proc issue(turn: var WaitTurn, entry, offset: int, timeout: int64) =
  turn = WaitTurn(entry: entry, arena: initWasmExecutionArena())
  let expected = if entry == wait64: wasmI64(0) else: wasmI32(0)
  doAssert vm.resume(turn, [wasmI32(offset.int32), expected, wasmI64(timeout)]).len == 0
  doAssert turn.continuation.status == wesAtomicBlocked and turn.continuation.instructions > 0

proc wake(offset, count: int32): int32 =
  vm.invoke(index, "notify", [wasmI32(offset), wasmI32(count)])[0].i32

var first, second, third: WaitTurn
first.issue(wait64, 0, -1)
second.issue(wait32, 0, -1)
third.issue(wait32, 4, 500)
doAssert wake(0, 0) == 0 and wake(8, -1) == 0
doAssert vm.invoke(unrelated, "notify", [wasmI32(0), wasmI32(-1)])[0].i32 == 0
discard vm.invoke(index, "store", [wasmI32(0), wasmI64(42)])
doAssert not vm.executionRunnable(first.continuation)
let waitingFuel = first.continuation.instructions
doAssert vm.resume(first, []).len == 0 and first.continuation.instructions == waitingFuel
doAssert wake(0, 1) == 1
doAssert vm.executionRunnable(first.continuation) and not vm.executionRunnable(second.continuation)
doAssert vm.resume(first, [])[0].i32 == 0
doAssert wake(0, -1) == 1 and vm.resume(second, [])[0].i32 == 0
doAssert wake(0, -1) == 0
doAssert vm.executionAtomicRemainingNs(third.continuation) == 500
now = 599
doAssert vm.executionAtomicRemainingNs(third.continuation) == 1
now = 600
doAssert wake(4, -1) == 0 and vm.executionRunnable(third.continuation)
doAssert vm.resume(third, [])[0].i32 == 2

first.issue(wait32, 4, -1)
var stale = first.continuation
try:
  discard vm.executeSlice(wait32, [], first.continuation, 16)
  raiseAssert "atomic continuation resumed on the wrong arena"
except WasmTrap as error:
  doAssert error.msg.contains("stale interpreter atomic continuation")
vm.swapWasmExecutionArena(first.arena)
vm.abortExecution(first.continuation)
vm.swapWasmExecutionArena(first.arena)
doAssert wake(4, -1) == 0
doAssert first.continuation.status == wesReady
discard vm.resume(first, [wasmI32(4), wasmI32(0), wasmI64(-1)])
vm.swapWasmExecutionArena(first.arena)
try:
  discard vm.executeSlice(wait32, [], stale, 16)
  raiseAssert "cancelled continuation resumed a newly parked arena"
except WasmTrap as error:
  doAssert error.msg.contains("stale interpreter atomic continuation")
vm.abortExecution(first.continuation)
vm.swapWasmExecutionArena(first.arena)

var queued: array[WasmMaxAtomicWaiters, WaitTurn]
for turn in queued.mitems: turn.issue(wait32, 4, -1)
var extra: WaitTurn
try:
  extra.issue(wait32, 4, -1)
  raiseAssert "atomic queue accepted more than its configured capacity"
except WasmTrap as error:
  doAssert error.msg.contains("atomic wait capacity exhausted")
vm.swapWasmExecutionArena(extra.arena)
vm.abortExecution(extra.continuation)
vm.swapWasmExecutionArena(extra.arena)
doAssert wake(4, -1) == WasmMaxAtomicWaiters.int32
for turn in queued.mitems:
  doAssert vm.resume(turn, [])[0].i32 == 0

when defined(wasmChunkedMemory):
  type WaitBacking = object
    saved: array[2, array[WasmMemoryChunkBytes.int, byte]]
    memory: ref LinearMemory
  proc readChunk(ctx: pointer, slot: uint32, dst: ptr UncheckedArray[byte]): bool =
    let backing = cast[ptr WaitBacking](ctx)
    if slot >= backing.saved.len.uint32: return false
    copyMem(dst, addr backing.saved[slot][0], WasmMemoryChunkBytes.int)
    true
  proc writeChunk(ctx: pointer, slot: uint32, src: ptr UncheckedArray[byte]): bool =
    let backing = cast[ptr WaitBacking](ctx)
    if slot >= backing.saved.len.uint32: return false
    copyMem(addr backing.saved[slot][0], src, WasmMemoryChunkBytes.int)
    true
  proc pagedFactory(ctx: pointer, memory: MemType): ref LinearMemory =
    doAssert memory.limits.shared and memory.limits.min == 1
    cast[ptr WaitBacking](ctx).memory
  var paged = WaitBacking(memory: new(LinearMemory))
  doAssert paged.memory[].initLinearMemory(LinearMemoryConfig(initialPages: 1,
    maxPages: 1, admissionPages: 1, residentChunks: 1, maxCommittedChunks: 2),
    LinearMemoryBacking(ctx: addr paged, slots: 2, readPage: readChunk,
      writePage: writeChunk)) == lmOk
  var pagedVm = initWasmVM()
  pagedVm.setMemoryBackendFactory(pagedFactory, addr paged)
  let pagedIndex = pagedVm.instantiate(decodeModule(wasm), [])
  discard pagedVm.invoke(pagedIndex, "store", [wasmI32(0), wasmI64(42)])
  discard pagedVm.invoke(pagedIndex, "store",
    [wasmI32(WasmMemoryChunkBytes.int32), wasmI64(7)])
  var turn = WaitTurn(entry: pagedVm.getExport(pagedIndex, "wait64").idx,
    arena: initWasmExecutionArena())
  discard pagedVm.resume(turn, [wasmI32(0), wasmI64(42), wasmI64(-1)])
  doAssert turn.continuation.status == wesMemoryBlocked
  doAssert pagedVm.invoke(pagedIndex, "notify", [wasmI32(0), wasmI32(1)])[0].i32 == 0
  let before = turn.continuation.instructions
  doAssert pagedVm.serviceExecutionMemoryFault(turn.continuation) == lmOk
  discard pagedVm.resume(turn, [])
  doAssert turn.continuation.status == wesAtomicBlocked and
    turn.continuation.instructions == before + 1
  doAssert pagedVm.invoke(pagedIndex, "notify", [wasmI32(0), wasmI32(1)])[0].i32 == 1
  doAssert pagedVm.resume(turn, [])[0].i32 == 0
  echo "WASM paged atomic wait PASS: page-in before enrollment and one fuel charge"

# Exercise the actual tickless driver with a guest whose arena stays parked
# across kernel polls. The test driver uses one microsecond per tick.
var kernelTick, due: uint64
var installed: TestTimedHook
proc mockTick(): uint64 = kernelTick
proc install(hook: TestTimedHook, deadline: uint64): bool =
  installed = hook
  due = deadline
  true
proc rearm(hook: TestTimedHook, deadline: uint64): bool =
  if installed == nil or installed != hook: return false
  due = deadline
  true

var image = newSeq[byte](WasmProgramHeaderLen.int + wasm.len)
let base = cast[ptr UncheckedArray[byte]](addr image[0])
doAssert initWasmProgramImage(base, image.len.uint32, wasm) == wasmProgramOk
wasmRtTestTick = mockTick
wasmRtTestInstall = install
wasmRtTestRearm = rearm
kernelTick = 10
resetWasmScheduler()
doAssert initWasmRtScheduler(2, kernelTick, 100) == wrOk
doAssert attachWasmRtKernel(bestEffortMaxSliceTicks = 10)
let task = startFullWasmImageTaskI32(base, image.len.uint32, "timer", [])
doAssert task.status == wasmSchedOk and due == 10
doAssert admitWasmTaskRt(task.id, WasmRtSpec(class: wrHard)) == wrUnsafeHardSlot
due = installed(kernelTick)
doAssert getWasmTask(task.id).state == wasmTaskBlockedAtomic and due == 15
doAssert getWasmTask(task.id).fuelUsed == 4
doAssert captureWasmTaskMigration(task.id).status == wasmMigrationBadState
kernelTick = 14
doAssert nextWasmSchedulerRtWakeTick(kernelTick, 10) == 15
kernelTick = due
due = installed(kernelTick)
doAssert due == 0 and getWasmTask(task.id).state == wasmTaskExited
doAssert getWasmTask(task.id).result == 2
detachWasmRtKernel()
resetWasmScheduler()

let componentBytes = cast[seq[byte]](readFile(paramStr(2)))
let threaded = instantiateComponent(decodeComponent(componentBytes))
let returned = threaded.invoke("run", [])
doAssert returned.len == 1 and returned[0].bits == 42
threaded.closeComponent()
echo "WASM atomic wait PASS: FIFO, queue limit, timeout, arena ownership, tickless wake, Component guest threads"
