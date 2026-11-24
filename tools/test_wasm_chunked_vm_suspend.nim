import std/os
import cps/wasm/[binary, linear_memory, runtime, types, validate]

type
  Backing = object
    pages: array[5, array[WasmMemoryChunkBytes.int, byte]]
  FactoryContext = object
    memory: ref LinearMemory

proc readPage(ctx: pointer, slot: uint32,
              dst: ptr UncheckedArray[byte]): bool =
  let backing = cast[ptr Backing](ctx)
  if slot >= backing.pages.len.uint32: return false
  copyMem(dst, addr backing.pages[slot.int][0], WasmMemoryChunkBytes.int)
  true

proc writePage(ctx: pointer, slot: uint32,
               src: ptr UncheckedArray[byte]): bool =
  let backing = cast[ptr Backing](ctx)
  if slot >= backing.pages.len.uint32: return false
  copyMem(addr backing.pages[slot.int][0], src, WasmMemoryChunkBytes.int)
  true

proc makeMemory(ctx: pointer, memType: MemType): ref LinearMemory =
  let owner = cast[ptr FactoryContext](ctx)
  doAssert memType.limits.min == 1 and memType.limits.max == 2
  owner.memory

let bytes = readFile(paramStr(1))
let module = decodeModule(bytes.toOpenArrayByte(0, bytes.len - 1))
validateModule(module)
var backing: Backing
var memory: ref LinearMemory
new(memory)
doAssert memory[].initLinearMemory(LinearMemoryConfig(
  initialPages: 1, maxPages: 2, admissionPages: 2,
  maxCommittedChunks: 5, residentChunks: 1),
  LinearMemoryBacking(ctx: addr backing, slots: 5,
    readPage: readPage, writePage: writePage)) == lmOk
var owner = FactoryContext(memory: memory)
var vm = initWasmVM()
vm.setMemoryBackendFactory(makeMemory, addr owner)
let moduleIdx = vm.instantiate(module, [])
doAssert vm.invoke(moduleIdx, "grow", [wasmI32(1)])[0].i32 == 1
let funcAddr = vm.getExport(moduleIdx, "cross_page").idx
var continuation: WasmContinuation
var values: seq[WasmValue]
var faults = 0
var slices = 0
while true:
  values = vm.executeSlice(funcAddr, [], continuation, 10)
  if continuation.status == wesComplete: break
  case continuation.status
  of wesMemoryBlocked:
    doAssert memory[].pendingFault().pending
    inc faults
    doAssert vm.serviceExecutionMemoryFault(continuation) == lmOk
  of wesYielded:
    inc slices
  else:
    doAssert false
  doAssert faults < 20 and slices < 20
doAssert faults >= 2
doAssert values.len == 1 and values[0].kind == wvkI32 and
  values[0].i32 == 305419896'i32
doAssert vm.callStackTop == 0 and vm.valueStackTop == 0
doAssert memory[].stats().pageOuts > 0 and memory[].stats().pageIns > 0

let bulkFunc = vm.getExport(moduleIdx, "bulk").idx
var bulkContinuation: WasmContinuation
var bulkValues: seq[WasmValue]
var bulkFaults = 0
while true:
  bulkValues = vm.executeSlice(bulkFunc, [], bulkContinuation, 10)
  if bulkContinuation.status == wesComplete: break
  case bulkContinuation.status
  of wesMemoryBlocked:
    inc bulkFaults
    doAssert vm.serviceExecutionMemoryFault(bulkContinuation) == lmOk
  of wesYielded:
    discard
  else:
    doAssert false
  doAssert bulkFaults < 100
doAssert bulkFaults > 0 and bulkValues.len == 1 and
  bulkValues[0].kind == wvkI32 and bulkValues[0].i32 == 90
echo "full WASM fault suspension PASS: scalar and bulk, one frame"
