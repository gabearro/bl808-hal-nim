import bl808/[wasm_full_manager, wasm_manager, wasm_store]
import cps/wasm/[runtime, types]
when defined(wasmSharedCoreTypes) and defined(wasmChunkedMemory):
  import cps/wasm/linear_memory

when defined(wasmAtomicWaitProbe):
  const AtomicWaitGuest = staticRead("../build/wasm-full-baseline/atomic-wait/cases.2.wasm")
elif defined(wasmSharedMemoryProbe):
  const SharedMemoryGuest =
    staticRead("../build/wasm-full-baseline/shared-core-types/memories.0.wasm")
  const SharedDataGuest =
    staticRead("../build/wasm-full-baseline/shared-core-types/shared-data-draft.wasm")
  const LinearAtomicGuest =
    staticRead("../build/wasm-full-baseline/shared-core-types/linear-atomics.0.wasm")
elif defined(wasmFunctionReferencesProbe):
  const FunctionReferenceGuest = when defined(wasmSharedCoreTypes):
    staticRead("../build/wasm-full-baseline/shared-core-types/cases.0.wasm")
  else:
    staticRead("../build/wasm-full-baseline/function-references/cases.0.wasm")
  when defined(wasmSharedCoreTypes):
    const SharedTableGuest =
      staticRead("../build/wasm-full-baseline/shared-core-types/tables.0.wasm")
    const AtomicGlobalGuest =
      staticRead("../build/wasm-full-baseline/shared-core-types/atomics-acqrel.wasm")

template withFlashGuest(module: openArray[byte], handle, factory, body: untyped) =
  ## Go through the same checked XIP-view adapter used by admitted tasks.
  var image = newSeq[byte](WasmProgramHeaderLen.int + module.len)
  let base = cast[ptr UncheckedArray[byte]](addr image[0])
  if initWasmProgramImage(base, image.len.uint32, module) != wasmProgramOk: return false
  var handle: FullWasmProgramHandle
  if handle.openFullWasmProgramImage(base, image.len.uint32,
      memoryFactory = factory) != wasmManagerOk: return false
  defer: handle.close()
  body

proc checkFunctionReferenceImage*(module: openArray[byte]): bool =
  withFlashGuest(module, handle, nil):
    let direct = handle.fullExportFuncAddr("call")
    let tail = handle.fullExportFuncAddr("tail")
    let value = handle.vm[].execute(direct, [wasmI32(21)])
    if value.len != 1 or value[0].i32 != 42: return false
    var continuation: WasmContinuation
    var answer = handle.vm[].executeSlice(tail, [wasmI32(1024)], continuation, 19)
    var slices = 1
    while continuation.status == wesYielded and slices < 1024:
      inc slices
      answer = handle.vm[].executeSlice(tail, [], continuation, 19)
    result = continuation.status == wesComplete and answer.len == 1 and
      answer[0].i32 == 1024 and slices > 1

when defined(wasmSharedCoreTypes):
  proc checkSharedTableImage*(module: openArray[byte]): bool =
    withFlashGuest(module, handle, nil):
      let run = handle.fullExportFuncAddr("run")
      let initialize = handle.fullExportFuncAddr("initialize")
      let value = handle.vm[].execute(run, [wasmI32(21)])
      if value.len != 1 or value[0].i32 != 42: return false
      let initialized = handle.vm[].execute(initialize, [])
      result = initialized.len == 1 and initialized[0].i32 == 42

  proc checkGlobalAtomicImage*(module: openArray[byte]): bool =
    withFlashGuest(module, handle, nil):
      let entry = handle.fullExportFuncAddr("atomic")
      var continuation: WasmContinuation
      for _ in 0 ..< 32:
        let answer = handle.vm[].executeSlice(entry, [], continuation, 1)
        case continuation.status
        of wesComplete: return answer.len == 1 and answer[0].i32 == 42
        of wesYielded: discard
        else: return false
      return false

when defined(wasmSharedCoreTypes) and defined(wasmChunkedMemory):
  proc sharedMemoryFactory(context: pointer, memory: MemType): ref LinearMemory =
    if not memory.limits.shared or not memory.limits.hasMax: return nil
    new(result)
    if result[].initLinearMemory(LinearMemoryConfig(initialPages: memory.limits.min,
        maxPages: memory.limits.max, admissionPages: memory.limits.max,
        maxCommittedChunks: 2, residentChunks: 2)) != lmOk:
      return nil

  proc checkSharedMemoryImage*(module: openArray[byte], entry: string, pages: int): bool =
    withFlashGuest(module, handle, sharedMemoryFactory):
      let function = handle.fullExportFuncAddr(entry)
      let answer = handle.vm[].execute(function, [])
      if answer.len != 1 or answer[0].i32 != 42: return false
      let memory = addr handle.vm[].getMemory(handle.moduleIdx)
      let usage = memory[].chunked[].stats()
      result = memory[].memCurrentPages() == pages and
        usage.residentChunks == pages.uint32 and usage.committedChunks == pages.uint32

when defined(wasmAtomicWaitProbe):
  proc runFunctionReferenceProbe*(): bool =
    withFlashGuest(AtomicWaitGuest.toOpenArrayByte(0, AtomicWaitGuest.high), handle,
        sharedMemoryFactory):
      let vm = addr handle.vm[]
      let waiter = handle.fullExportFuncAddr("wait")
      let notifier = handle.fullExportFuncAddr("notify")
      var turn: WasmContinuation
      discard vm[].executeSlice(waiter, [], turn, 16)
      if turn.status != wesAtomicBlocked or vm[].executionRunnable(turn): return false
      var arena = initWasmExecutionArena()
      vm[].swapWasmExecutionArena(arena)
      var notified: seq[WasmValue]
      try: notified = vm[].execute(notifier, [])
      finally: vm[].swapWasmExecutionArena(arena)
      if notified.len != 1 or notified[0].i32 != 1: return false
      let resumed = vm[].executeSlice(waiter, [], turn, 16)
      result = turn.status == wesComplete and resumed.len == 1 and resumed[0].i32 == 0
elif defined(wasmSharedMemoryProbe):
  proc runFunctionReferenceProbe*(): bool =
    checkSharedMemoryImage(SharedMemoryGuest.toOpenArrayByte(0, SharedMemoryGuest.high),
      "crosses", 2) and
      checkSharedMemoryImage(SharedDataGuest.toOpenArrayByte(0, SharedDataGuest.high),
        "initialize", 1) and
      checkSharedMemoryImage(LinearAtomicGuest.toOpenArrayByte(0, LinearAtomicGuest.high),
        "atomics", 2)
elif defined(wasmFunctionReferencesProbe):
  proc runFunctionReferenceProbe*(): bool =
    if not checkFunctionReferenceImage(FunctionReferenceGuest.toOpenArrayByte(
      0, FunctionReferenceGuest.high)): return false
    when defined(wasmSharedCoreTypes):
      checkSharedTableImage(SharedTableGuest.toOpenArrayByte(0, SharedTableGuest.high)) and
        checkGlobalAtomicImage(AtomicGlobalGuest.toOpenArrayByte(0, AtomicGlobalGuest.high))
    else: true
