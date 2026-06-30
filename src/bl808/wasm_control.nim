## Loader-facing WASM program control surface.
##
## This module is intentionally transport-neutral. A UART shell, HTTP handler,
## or SD-card installer can translate requests into these operations while the
## flash slot format and compact VM stay behind `wasm_manager`.

import ./memmap
import ./wasm_runtime
import ./wasm_manager
import ./wasm_scheduler
import ./wasm_store

when not (defined(bl808d0) or defined(bl808lp)):
  import ./wasm_os

export wasm_runtime
export wasm_scheduler

type
  WasmControlStatus* = enum
    wasmControlOk
    wasmControlBadSlot
    wasmControlNoSlot
    wasmControlStoreError
    wasmControlRunError

  WasmControlSlot* = object
    index*: uint32
    state*: WasmProgramSlotState
    imageLen*: uint32
    generation*: uint32
    flags*: uint32
    checksum*: uint32
    validation*: WasmProgramError

  WasmControlResult* = object
    status*: WasmControlStatus
    managerError*: WasmProgramManagerError
    storeError*: WasmProgramError
    slot*: int32
    value*: int32

  WasmControlTaskResult* = object
    status*: WasmControlStatus
    schedulerStatus*: WasmSchedulerStatus
    managerError*: WasmProgramManagerError
    taskId*: uint32
    slot*: int32
    taskState*: WasmSchedulerTaskState
    value*: int32
    trapCode*: uint32
    resumes*: uint32
    yields*: uint32
    fuelUsed*: uint32
    fuelLimit*: uint32

proc controlFromInstall(r: WasmProgramInstallResult): WasmControlResult =
  result.slot = r.slot
  result.managerError = r.status
  result.storeError = r.storeError
  case r.status
  of wasmManagerOk:
    result.status = wasmControlOk
  of wasmManagerNoSlot:
    result.status = wasmControlNoSlot
  else:
    result.status = wasmControlStoreError

proc slotToControl(info: WasmProgramSlotInfo): WasmControlSlot =
  WasmControlSlot(
    index: info.slot.index,
    state: info.state,
    imageLen: info.header.imageLen,
    generation: info.header.generation,
    flags: info.header.flags,
    checksum: info.header.wasmProgramChecksum,
    validation: info.validation,
  )

proc listWasmPrograms*(outSlots: var openArray[WasmControlSlot]): uint32 =
  ## Fill `outSlots` with fixed store slot metadata.
  for index in 0'u32 ..< Ox64WasmSlotCount.uint32:
    if result >= outSlots.len.uint32:
      break
    outSlots[result.int] = slotToControl(queryWasmProgramSlot(index))
    inc result

proc installWasmProgramBytes*(slot: uint32, wasm: openArray[byte],
                              generation = 1'u32,
                              flags = 0'u32): WasmControlResult =
  if slot >= Ox64WasmSlotCount.uint32:
    return WasmControlResult(status: wasmControlBadSlot, slot: slot.int32)
  controlFromInstall(installWasmProgram(slot, wasm, generation = generation, flags = flags))

proc installWasmProgramBytesAuto*(wasm: openArray[byte], outSlot: var uint32,
                                  startIndex = 0'u32,
                                  generation = 1'u32,
                                  flags = 0'u32): WasmControlResult =
  controlFromInstall(installWasmProgramAuto(
    wasm,
    outSlot,
    startIndex = startIndex,
    generation = generation,
    flags = flags,
  ))

proc runWasmProgramI32*(slot: uint32, exportName: string,
                        args: openArray[int32]): WasmControlResult =
  if slot >= Ox64WasmSlotCount.uint32:
    return WasmControlResult(status: wasmControlBadSlot, slot: slot.int32)
  var handle: WasmProgramHandle
  let openErr = handle.openWasmProgramSlot(slot)
  if openErr != wasmManagerOk:
    return WasmControlResult(status: wasmControlRunError,
                             managerError: openErr,
                             slot: slot.int32)
  let run = handle.invokeI32(exportName, args)
  handle.close()
  if run.status != wasmManagerOk:
    return WasmControlResult(status: wasmControlRunError,
                             managerError: run.status,
                             slot: slot.int32)
  WasmControlResult(status: wasmControlOk, slot: slot.int32, value: run.value)

proc unloadWasmProgram*(slot: uint32): WasmControlResult =
  if slot >= Ox64WasmSlotCount.uint32:
    return WasmControlResult(status: wasmControlBadSlot, slot: slot.int32)
  controlFromInstall(unloadWasmProgramSlot(slot))

proc controlFromTask(r: WasmSchedulerResult): WasmControlTaskResult =
  result.schedulerStatus = r.status
  result.managerError = r.managerError
  result.taskId = r.id
  result.slot = r.slot
  result.taskState = r.state
  result.value = r.result
  result.trapCode = r.trapCode
  result.resumes = r.resumes
  result.yields = r.yields
  result.fuelUsed = r.fuelUsed
  result.fuelLimit = r.fuelLimit
  case r.status
  of wasmSchedOk:
    result.status = wasmControlOk
  of wasmSchedNoSlot:
    result.status = wasmControlNoSlot
  of wasmSchedOpenFailed, wasmSchedInitFailed, wasmSchedTrap, wasmSchedQuotaExceeded:
    result.status = wasmControlRunError
  else:
    result.status = wasmControlBadSlot

proc startWasmProgramTaskI32*(slot: uint32, exportName: string,
                              args: openArray[int32],
                              maxTotalFuel = WasmSchedulerDefaultMaxTotalFuel): WasmControlTaskResult =
  if slot >= Ox64WasmSlotCount.uint32:
    return WasmControlTaskResult(status: wasmControlBadSlot, slot: slot.int32)
  result = controlFromTask(startWasmTaskI32(slot, exportName, args, maxTotalFuel))
  when not (defined(bl808d0) or defined(bl808lp)):
    if result.status == wasmControlOk:
      discard appendWasmOsEvent(wasmEventTaskStarted, taskId = result.taskId,
                                slot = result.slot, code = result.fuelLimit)
    elif result.status == wasmControlRunError:
      discard appendWasmOsTrap(currentWasmOsCore(), result.taskId, result.slot,
                               result.trapCode, result.fuelUsed, result.taskState)

proc startWasmProgramImageTaskI32*(base: ptr UncheckedArray[byte], len: uint32,
                                   slotLabel: uint32, exportName: string,
                                   args: openArray[int32],
                                   maxTotalFuel = WasmSchedulerDefaultMaxTotalFuel): WasmControlTaskResult =
  if base == nil or len == 0:
    return WasmControlTaskResult(status: wasmControlBadSlot,
                                 slot: slotLabel.int32)
  controlFromTask(startWasmImageTaskI32(base, len, exportName, args,
                                        maxTotalFuel, slotLabel.int32))

proc resumeWasmProgramTask*(taskId: uint32,
                            fuel = WasmSchedulerDefaultFuel): WasmControlTaskResult =
  result = controlFromTask(resumeWasmTask(taskId, fuel))
  when not (defined(bl808d0) or defined(bl808lp)):
    if result.status == wasmControlOk:
      case result.taskState
      of wasmTaskYielded:
        discard appendWasmOsEvent(wasmEventTaskYielded, taskId = result.taskId,
                                  slot = result.slot, code = result.fuelUsed)
      of wasmTaskExited:
        discard appendWasmOsEvent(wasmEventTaskExited, taskId = result.taskId,
                                  slot = result.slot, value = result.value,
                                  code = result.fuelUsed)
      of wasmTaskBlockedHttp, wasmTaskBlockedSd, wasmTaskBlockedIpc,
          wasmTaskBlockedTimer, wasmTaskBlockedEnclave:
        discard appendWasmOsEvent(wasmEventTaskBlocked, taskId = result.taskId,
                                  slot = result.slot, code = result.taskState.ord.uint32)
      else:
        discard
    elif result.schedulerStatus in {wasmSchedTrap, wasmSchedQuotaExceeded}:
      discard appendWasmOsTrap(currentWasmOsCore(), result.taskId, result.slot,
                               result.trapCode, result.fuelUsed, result.taskState)

proc runWasmProgramScheduler*(fuelPerTask = WasmSchedulerDefaultFuel,
                              maxResumes = 32'u32): uint32 =
  runWasmScheduler(fuelPerTask, maxResumes)

proc killWasmProgramTask*(taskId: uint32): WasmControlTaskResult =
  result = controlFromTask(killWasmTask(taskId))
  when not (defined(bl808d0) or defined(bl808lp)):
    if result.status == wasmControlOk:
      discard appendWasmOsEvent(wasmEventTaskKilled, taskId = result.taskId,
                                slot = result.slot)

proc getWasmProgramTask*(taskId: uint32): WasmControlTaskResult =
  controlFromTask(getWasmTask(taskId))
