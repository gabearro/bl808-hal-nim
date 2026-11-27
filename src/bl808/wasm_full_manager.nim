## Full-interpreter adapter for the existing CRC-checked WASM slot store.
## The compact manager remains available for legacy programs. This adapter
## owns a native VM instance while retaining the original XIP payload view.

import ./wasm_manager
import ./wasm_store
when defined(bl808lp) and defined(bl808WasmFull):
  ## The RV32E toolchain has no compatible libgcc multilib for the full
  ## interpreter. Link the verified local compiler-rt/math lowering for every
  ## LP full-task build, including ones without the baseline test module.
  import ./wasm_lp_softfloat
import cps/wasm/[binary, flash_image, runtime, types, validate]
when defined(wasmChunkedMemory):
  type FullMemoryFactory* = MemoryBackendFactory
else:
  type FullMemoryFactory* = pointer

type
  FullWasmHostBinding* = object
    interfaceBit*: uint32
    moduleName*, fieldName*: string
    signature*: FuncType
    callback*: HostFunc

  FullWasmAdmission* = object
    enforceMemoryQuota*: bool
    requireMemoryFactory*: bool
    allowedHostInterfaces*: uint32
    hostBindings*: seq[FullWasmHostBinding]

  FullWasmImportError = object of CatchableError

  FullWasmProgramHandle* = object
    loaded*: bool
    slot*: int32
    moduleIdx*: int
    program*: LoadedWasmProgram
    vm*: ref WasmVM

proc close*(handle: var FullWasmProgramHandle) =
  if handle.vm != nil:
    handle.vm[].destroyWasmVM()
  handle.program.unload()
  handle = FullWasmProgramHandle(slot: -1, moduleIdx: -1)

proc resolveFullHostImports(module: WasmModule, admission: FullWasmAdmission):
    seq[(string, string, ExternalVal)] =
  for imp in module.imports:
    var found = false
    if imp.kind == ikFunc:
      for binding in admission.hostBindings:
        if binding.moduleName != imp.module or binding.fieldName != imp.name: continue
        if binding.interfaceBit != 0 and
            (admission.allowedHostInterfaces and binding.interfaceBit) == binding.interfaceBit and
            binding.callback != nil and binding.signature == module.types[imp.funcTypeIdx.int]:
          result.add((imp.module, imp.name, ExternalVal(kind: ekFunc,
            funcType: binding.signature, hostFunc: binding.callback)))
          found = true
        break
    if not found:
      raise newException(FullWasmImportError, "unsupported full WASM import: " & imp.module & "." & imp.name)

proc openLoaded(handle: var FullWasmProgramHandle,
                program: var LoadedWasmProgram,
                maxMemoryPages: uint32,
                memoryFactory: FullMemoryFactory,
                memoryFactoryContext: pointer,
                restoreSnapshot, requireNoStart: bool,
                admission: FullWasmAdmission): WasmProgramManagerError =
  if not program.loaded or program.module.image.bytes == nil or
      program.module.image.len <= 0:
    program.unload()
    return wasmManagerStoreError
  try:
    let image = program.module.image
    # Only the verified view is needed for full decoding. On LP the two
    # decoded representations cannot coexist with admitted guest frames.
    program.module = FlashWasmModule(image: image)
    var module = decodeModule(image.bytes.toOpenArray(0, image.len - 1))
    validateModule(module)
    if requireNoStart and module.startFunc >= 0:
      # A steal candidate must not execute guest code during preparation.
      program.unload()
      return wasmManagerInstantiateFailed
    # A guest-declared maximum may exceed the host admission quota. Lowering
    # it is allowed by memory.grow's failure semantics and prevents growth
    # past the admitted number of 64 KiB pages.
    if maxMemoryPages != 0 or admission.enforceMemoryQuota:
      for memory in module.memories.mitems:
        if memory.limits.min > maxMemoryPages:
          program.unload()
          return wasmManagerInstantiateFailed
        if not memory.limits.hasMax or memory.limits.max > maxMemoryPages:
          memory.limits.hasMax = true
          memory.limits.max = maxMemoryPages
    let imports = if restoreSnapshot: @[] else: module.resolveFullHostImports(admission)
    # M0 and LP cannot fit a flat 64 KiB Wasm page in local writable RAM.
    const nativeNeedsFactory = defined(bl808m0) or defined(bl808lp)
    if (nativeNeedsFactory or admission.requireMemoryFactory) and
        module.memories.len > 0 and memoryFactory == nil:
      program.unload()
      return wasmManagerDependencyUnavailable
    when not defined(wasmChunkedMemory):
      if memoryFactory != nil:
        program.unload()
        return wasmManagerInstantiateFailed
    var vm: ref WasmVM
    new(vm)
    vm[] = initWasmVM()
    when defined(wasmChunkedMemory):
      if memoryFactory != nil:
        vm[].setMemoryBackendFactory(memoryFactory, memoryFactoryContext)
    let moduleIdx = if restoreSnapshot: vm[].instantiateForRestore(move module)
                    else: vm[].instantiateOwned(move module, imports)
    handle.loaded = true
    handle.slot = program.slot.index.int32
    handle.moduleIdx = moduleIdx
    handle.vm = vm
    handle.program = move program
    wasmManagerOk
  except FullWasmImportError:
    program.unload()
    wasmManagerDependencyUnavailable
  except CatchableError:
    program.unload()
    wasmManagerInstantiateFailed

proc openFullWasmProgramSlot*(handle: var FullWasmProgramHandle,
                              slot: uint32,
                              maxMemoryPages = 0'u32,
                              memoryFactory: FullMemoryFactory = nil,
                              memoryFactoryContext: pointer = nil,
                              restoreSnapshot = false,
                              requireNoStart = false,
                              admission = FullWasmAdmission()): WasmProgramManagerError =
  handle.close()
  var program: LoadedWasmProgram
  if loadWasmProgramSlot(slot, program) != wasmProgramOk:
    return wasmManagerStoreError
  result = handle.openLoaded(program, maxMemoryPages,
    memoryFactory, memoryFactoryContext, restoreSnapshot, requireNoStart, admission)
  if result == wasmManagerOk: handle.slot = slot.int32

proc openFullWasmProgramImage*(handle: var FullWasmProgramHandle,
                               base: ptr UncheckedArray[byte], len: uint32,
                               maxMemoryPages = 0'u32,
                               memoryFactory: FullMemoryFactory = nil,
                               memoryFactoryContext: pointer = nil,
                               restoreSnapshot = false,
                               requireNoStart = false,
                               admission = FullWasmAdmission()): WasmProgramManagerError =
  ## Host and staged-image variant of the same store and full-VM path.
  handle.close()
  var program: LoadedWasmProgram
  if loadWasmProgramFromView(base, len, program) != wasmProgramOk:
    return wasmManagerStoreError
  result = handle.openLoaded(program, maxMemoryPages,
    memoryFactory, memoryFactoryContext, restoreSnapshot, requireNoStart, admission)
  if result == wasmManagerOk: handle.slot = -1

proc fullExportFuncAddr*(handle: var FullWasmProgramHandle,
                         name: string): int =
  if not handle.loaded or handle.vm == nil:
    raise newException(WasmTrap, "full WASM program not loaded")
  let exported = handle.vm[].getExport(handle.moduleIdx, name)
  if exported.kind != ekFunc:
    raise newException(WasmTrap, "full WASM export is not a function")
  exported.idx
