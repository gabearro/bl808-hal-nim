import std/[os, strutils]
import cps/wasm/[binary, runtime, types, validate]
when defined(wasmChunkedMemory):
  import cps/wasm/linear_memory

  type Backing = array[4, array[WasmMemoryChunkBytes.int, byte]]
  type Backings = array[2, Backing]
  var backings: Backings
  var memories: array[2, ref LinearMemory]

  proc readPage(ctx: pointer, slot: uint32, dst: ptr UncheckedArray[byte]): bool =
    let pages = cast[ptr Backing](ctx)
    if slot >= pages[].len.uint32: return false
    copyMem(dst, addr pages[][slot][0], WasmMemoryChunkBytes.int)
    true

  proc writePage(ctx: pointer, slot: uint32, src: ptr UncheckedArray[byte]): bool =
    let pages = cast[ptr Backing](ctx)
    if slot >= pages[].len.uint32: return false
    copyMem(addr pages[][slot][0], src, WasmMemoryChunkBytes.int)
    true

  proc memoryFactory(ctx: pointer, memType: MemType): ref LinearMemory =
    let idx = memType.limits.max.int - 1
    doAssert idx in 0..1 and memType.limits.min == 1
    new(result)
    doAssert result[].initLinearMemory(LinearMemoryConfig(initialPages: 1,
      maxPages: memType.limits.max, admissionPages: memType.limits.max,
      maxCommittedChunks: 4, residentChunks: 1), LinearMemoryBacking(
      ctx: addr backings[idx], slots: 4, readPage: readPage, writePage: writePage)) == lmOk
    memories[idx] = result

proc expectInvalid(module: WasmModule, allowMultipleMemories: bool, diagnostic: string) =
  try:
    validateModule(module, allowMultipleMemories = allowMultipleMemories)
    doAssert false, "accepted an invalid memory index or profile"
  except ValidationError as err:
    doAssert diagnostic in err.msg, err.msg

let raw = readFile(paramStr(1))
template bytes: untyped = raw.toOpenArrayByte(0, raw.high)
for optimize in [false, true]:
  var module = decodeModule(bytes, optimize = optimize)
  module.expectInvalid(false, "at most one memory")
  validateModule(module, allowMultipleMemories = true)
  var vm = initWasmVM()
  when defined(wasmChunkedMemory):
    vm.setMemoryBackendFactory(memoryFactory)
  let idx = vm.instantiate(module, [])
  doAssert vm.invoke(idx, "size-first", [])[0].i32 == 1
  doAssert vm.invoke(idx, "size-second", [])[0].i32 == 1
  doAssert vm.invoke(idx, "grow-second", [])[0].i32 == 1
  doAssert vm.invoke(idx, "size-first", [])[0].i32 == 1
  doAssert vm.invoke(idx, "size-second", [])[0].i32 == 2
  doAssert vm.invoke(idx, "indexed-load", [wasmI32(512)])[0].i32 == 0x77
  discard vm.invoke(idx, "indexed-store", [wasmI32(42)])
  doAssert vm.invoke(idx, "indexed-load", [wasmI32(32)])[0].i32 == 42
  when defined(wasmChunkedMemory):
    var continuation: WasmContinuation
    let fn = vm.getExport(idx, "boundary").idx
    var faults = 0
    for _ in 0..16:
      let results = vm.executeSlice(fn, [], continuation, 2)
      case continuation.status
      of wesComplete:
        doAssert results[0].i32 == 0x12345678
        break
      of wesMemoryBlocked:
        doAssert memories[1][].pendingFault().pending and not memories[0][].pendingFault().pending
        doAssert vm.serviceExecutionMemoryFault(continuation) == lmOk
        inc faults
      of wesYielded: discard
      else: doAssert false
    doAssert continuation.status == wesComplete and faults > 0
  else:
    doAssert vm.invoke(idx, "boundary", [])[0].i32 == 0x12345678
  doAssert vm.invoke(idx, "copy", [])[0].i32 == 0x445b5a44
  try:
    discard vm.invoke(idx, "dropped-zero-length", [])
    doAssert false, "allowed a nonzero offset into a dropped segment"
  except WasmTrap as err:
    doAssert "out of bounds" in err.msg
  vm.destroyWasmVM()
  for code in module.codes.mitems:
    for instr in code.code.code.mitems:
      if instr.op == opI32Load and instr.pad == 1:
        instr.pad = 2
  module.expectInvalid(true, "invalid memory index")
echo "full interpreter multi-memory PASS: decoding, validation, indexed fault, growth and bulk transfers"
