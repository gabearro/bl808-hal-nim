## Managed WASM program lifecycle over the flash-backed slot store.
##
## This is the surface intended for loaders such as SD/exFAT or HTTP: install
## bytes into a managed slot, open a slot into the compact VM, invoke exported
## functions, then close the handle without copying raw code out of XIP flash.

import ./memmap
import ./wasm_store
import cps/wasm/runtime_int

type
  WasmProgramManagerError* = enum
    wasmManagerOk
    wasmManagerStoreError
    wasmManagerNoSlot
    wasmManagerNotLoaded
    wasmManagerInstantiateFailed
    wasmManagerInvokeFailed

  WasmProgramInstallResult* = object
    status*: WasmProgramManagerError
    storeError*: WasmProgramError
    slot*: int32

  WasmProgramRunResult* = object
    status*: WasmProgramManagerError
    trapError*: WasmProgramError
    value*: int32

  WasmProgramHandle* = object
    loaded*: bool
    slot*: int32
    moduleIdx*: int
    program*: LoadedWasmProgram
    vm*: IntWasmVM

proc okInstall(slot: int32): WasmProgramInstallResult =
  WasmProgramInstallResult(status: wasmManagerOk, slot: slot)

proc storeInstall(err: WasmProgramError, slot = -1'i32): WasmProgramInstallResult =
  WasmProgramInstallResult(status: wasmManagerStoreError, storeError: err, slot: slot)

proc installWasmProgram*(slot: uint32, wasm: openArray[byte],
                         generation = 1'u32,
                         flags = 0'u32): WasmProgramInstallResult =
  ## Install one parseable `.wasm` image into a fixed flash slot.
  initWasmProgramStore()
  let err = writeWasmProgramSlot(slot, wasm, generation = generation, flags = flags)
  if err != wasmProgramOk:
    return storeInstall(err, slot.int32)
  okInstall(slot.int32)

proc installWasmProgramAuto*(wasm: openArray[byte], outSlot: var uint32,
                             startIndex = 0'u32,
                             generation = 1'u32,
                             flags = 0'u32): WasmProgramInstallResult =
  ## Install into the first erased slot at or after `startIndex`.
  ##
  ## Erased slots are detected from the flash header, so callers can reserve
  ## low slots for built-in programs by choosing a non-zero start index.
  initWasmProgramStore()
  let found = findEmptyWasmProgramSlot(startIndex)
  if found < 0:
    return WasmProgramInstallResult(status: wasmManagerNoSlot, slot: -1)
  outSlot = found.uint32
  result = installWasmProgram(outSlot, wasm, generation = generation, flags = flags)
  if result.status == wasmManagerOk:
    result.slot = found

proc close*(handle: var WasmProgramHandle) =
  handle.program.unload()
  handle = WasmProgramHandle(slot: -1, moduleIdx: -1, vm: initIntWasmVM())

proc openWasmProgramSlot*(handle: var WasmProgramHandle,
                          slot: uint32): WasmProgramManagerError =
  ## Load one flash-backed slot and instantiate it in a fresh compact VM.
  handle.close()
  var program: LoadedWasmProgram
  let loadErr = loadWasmProgramSlot(slot, program)
  if loadErr != wasmProgramOk or not program.loaded:
    return wasmManagerStoreError

  var vm = initIntWasmVM()
  var moduleIdx: int
  try:
    moduleIdx = vm.instantiateFlashIntOnly(program.module)
  except CatchableError:
    program.unload()
    return wasmManagerInstantiateFailed

  handle.loaded = true
  handle.slot = slot.int32
  handle.moduleIdx = moduleIdx
  handle.program = program
  handle.vm = vm
  wasmManagerOk

proc openWasmProgramImage*(handle: var WasmProgramHandle,
                           base: ptr UncheckedArray[byte],
                           len: uint32): WasmProgramManagerError =
  ## Host/test and staging-buffer variant that opens a header+payload image.
  handle.close()
  var program: LoadedWasmProgram
  let loadErr = loadWasmProgramFromView(base, len, program)
  if loadErr != wasmProgramOk or not program.loaded:
    return wasmManagerStoreError

  var vm = initIntWasmVM()
  var moduleIdx: int
  try:
    moduleIdx = vm.instantiateFlashIntOnly(program.module)
  except CatchableError:
    program.unload()
    return wasmManagerInstantiateFailed

  handle.loaded = true
  handle.slot = -1
  handle.moduleIdx = moduleIdx
  handle.program = program
  handle.vm = vm
  wasmManagerOk

proc invokeI32*(handle: var WasmProgramHandle, exportName: string,
                args: openArray[int32]): WasmProgramRunResult =
  if not handle.loaded:
    return WasmProgramRunResult(status: wasmManagerNotLoaded)
  try:
    result.value = handle.vm.invokeI32(handle.moduleIdx, exportName, args)
    result.status = wasmManagerOk
  except CatchableError:
    result.status = wasmManagerInvokeFailed

proc unloadWasmProgramSlot*(slot: uint32): WasmProgramInstallResult =
  ## Remove one installed program by erasing its flash slot.
  initWasmProgramStore()
  let err = eraseWasmProgramSlot(slot)
  if err != wasmProgramOk:
    return storeInstall(err, slot.int32)
  okInstall(slot.int32)

proc countPresentWasmPrograms*(): uint32 =
  ## Count valid, checksum-clean slots currently visible in flash.
  for index in 0'u32 ..< Ox64WasmSlotCount.uint32:
    if queryWasmProgramSlot(index).state == wasmSlotPresent:
      inc result

proc collectWasmProgramSlots*(slots: var openArray[WasmProgramSlotInfo]): uint32 =
  ## Copy slot metadata into caller storage, returning the number written.
  for index in 0'u32 ..< Ox64WasmSlotCount.uint32:
    if result >= slots.len.uint32:
      break
    slots[result.int] = queryWasmProgramSlot(index)
    inc result
