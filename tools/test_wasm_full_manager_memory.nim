import std/os
import bl808/[wasm_full_manager, wasm_manager, wasm_store]
import cps/wasm/[linear_memory, runtime, types]

type FactoryContext = object
  memory: ref LinearMemory

proc makeMemory(ctx: pointer, memType: MemType): ref LinearMemory =
  let owner = cast[ptr FactoryContext](ctx)
  doAssert memType.limits.min == 1 and memType.limits.hasMax and
    memType.limits.max == 1
  owner.memory

let guest = readFile(paramStr(1))
var image = newSeq[byte](WasmProgramHeaderLen.int + guest.len)
doAssert initWasmProgramImage(
  cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
  guest.toOpenArrayByte(0, guest.len - 1)) == wasmProgramOk
var memory: ref LinearMemory
new(memory)
doAssert memory[].initLinearMemory(LinearMemoryConfig(
  initialPages: 1, maxPages: 1, admissionPages: 1,
  maxCommittedChunks: 2, residentChunks: 2)) == lmOk
var owner = FactoryContext(memory: memory)
var handle: FullWasmProgramHandle
doAssert handle.openFullWasmProgramImage(
  cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
  maxMemoryPages = 1, memoryFactory = makeMemory,
  memoryFactoryContext = addr owner) == wasmManagerOk
let zero = handle.vm[].invoke(handle.moduleIdx, "grow", [wasmI32(0)])
doAssert zero.len == 1 and zero[0].i32 == 1
let denied = handle.vm[].invoke(handle.moduleIdx, "grow", [wasmI32(1)])
doAssert denied.len == 1 and denied[0].i32 == -1
doAssert memory[].currentPages() == 1
handle.close()
echo "full WASM store memory quota PASS: chunk factory and 64 KiB page limit"
