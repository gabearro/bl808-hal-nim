import std/os
import cps/wasm/[binary, linear_memory, runtime, types, validate]

type FactoryContext = object
  memory: ref LinearMemory

type Backing = object
  pages: array[10, array[WasmMemoryChunkBytes.int, byte]]

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
  let context = cast[ptr FactoryContext](ctx)
  doAssert memType.limits.min == 1 and memType.limits.max == 2
  context.memory

proc resultI32(vm: var WasmVM, moduleIdx: int,
               exportName: string, args: openArray[WasmValue]): int32 =
  let values = vm.invoke(moduleIdx, exportName, args)
  doAssert values.len == 1 and values[0].kind == wvkI32
  values[0].i32

let file = paramStr(1)
let bytes = readFile(file)
let module = decodeModule(bytes.toOpenArrayByte(0, bytes.len - 1))
validateModule(module)

var memory: ref LinearMemory
new(memory)
var backing: Backing
doAssert memory[].initLinearMemory(LinearMemoryConfig(
  initialPages: 1, maxPages: 2, admissionPages: 2,
  maxCommittedChunks: 10, residentChunks: 2),
  LinearMemoryBacking(ctx: addr backing, slots: 10,
    readPage: readPage, writePage: writePage)) == lmOk
var context = FactoryContext(memory: memory)
var vm = initWasmVM()
vm.setMemoryBackendFactory(makeMemory, addr context)
let idx = vm.instantiate(module, [])
doAssert vm.getMemory(idx).memCurrentPages() == 1
doAssert vm.resultI32(idx, "grow", [wasmI32(1)]) == 1
doAssert vm.getMemory(idx).memCurrentPages() == 2
doAssert vm.resultI32(idx, "grow", [wasmI32(1)]) == -1
doAssert vm.resultI32(idx, "cross_page", []) == 305419896
doAssert vm.resultI32(idx, "bulk", []) == 90
var swapped: array[4, byte]
doAssert memory[].readAt(65535,
  cast[ptr UncheckedArray[byte]](addr swapped[0]), 4, allowIo = true) == lmOk
doAssert swapped == [0x78'u8, 0x56, 0x34, 0x12]
doAssert vm.resultI32(idx, "cross_page", []) == 305419896
doAssert memory[].stats().committedChunks >= 3
doAssert memory[].stats().pageOuts > 0 and memory[].stats().pageIns > 0
echo "full WASM chunked VM PASS: grow, page-boundary load/store, bulk memory"
