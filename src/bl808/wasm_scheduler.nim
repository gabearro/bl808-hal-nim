## Cooperative scheduler for flash-backed compact WASM programs.
##
## The scheduler owns live VM handles and resumable task contexts. It is small
## on purpose: one core-local table, fixed task capacity, and explicit fuel
## slices. Transports such as HTTP or enclave services can build policy on top
## without re-instantiating programs for every resume.

import ./wasm_manager
import cps/wasm/runtime_int

const
  WasmSchedulerMaxTasks* {.intdefine.} = 8
  WasmSchedulerDefaultFuel* {.intdefine.} = 64'u32
  WasmSchedulerDefaultMaxTotalFuel* {.intdefine.} = 4096'u32

type
  WasmSchedulerStatus* = enum
    wasmSchedOk
    wasmSchedNoTask
    wasmSchedNoSlot
    wasmSchedBadTask
    wasmSchedBadState
    wasmSchedOpenFailed
    wasmSchedInitFailed
    wasmSchedTrap
    wasmSchedQuotaExceeded

  WasmSchedulerTaskState* = enum
    wasmTaskEmpty
    wasmTaskReady
    wasmTaskRunning
    wasmTaskYielded
    wasmTaskExited
    wasmTaskTrapped
    wasmTaskKilled
    wasmTaskBlockedHttp
    wasmTaskBlockedSd
    wasmTaskBlockedIpc
    wasmTaskBlockedTimer
    wasmTaskBlockedEnclave

  WasmSchedulerResult* = object
    status*: WasmSchedulerStatus
    managerError*: WasmProgramManagerError
    id*: uint32
    slot*: int32
    state*: WasmSchedulerTaskState
    result*: int32
    trapCode*: uint32
    resumes*: uint32
    yields*: uint32
    fuelUsed*: uint32
    fuelLimit*: uint32

  WasmSchedulerTaskInfo* = object
    id*: uint32
    slot*: int32
    state*: WasmSchedulerTaskState
    result*: int32
    trapCode*: uint32
    resumes*: uint32
    yields*: uint32
    fuelUsed*: uint32
    fuelLimit*: uint32

  WasmSchedulerTask = object
    used: bool
    id: uint32
    slot: int32
    state: WasmSchedulerTaskState
    handle: WasmProgramHandle
    task: IntWasmTask
    resumes: uint32
    yields: uint32
    fuelUsed: uint32
    fuelLimit: uint32

var
  tasks: array[WasmSchedulerMaxTasks, WasmSchedulerTask]
  nextTaskId = 1'u32
  schedulerDebugHook: proc(stage: uint32) {.nimcall.}

proc setWasmSchedulerDebugHook*(hook: proc(stage: uint32) {.nimcall.}) =
  schedulerDebugHook = hook

proc schedulerDebugStage(stage: uint32) {.inline.} =
  if schedulerDebugHook != nil:
    schedulerDebugHook(stage)

proc toSchedulerState(state: IntWasmTaskState): WasmSchedulerTaskState =
  case state
  of intTaskReady: wasmTaskReady
  of intTaskRunning: wasmTaskRunning
  of intTaskYielded: wasmTaskYielded
  of intTaskExited: wasmTaskExited
  of intTaskTrapped: wasmTaskTrapped

proc clearSlot(index: int) =
  if index < 0 or index >= tasks.len:
    return
  tasks[index].handle.close()
  tasks[index] = WasmSchedulerTask()

proc findTaskIndex(id: uint32): int =
  for i in 0 ..< tasks.len:
    if tasks[i].used and tasks[i].id == id:
      return i
  -1

proc findFreeTaskIndex(): int =
  for i in 0 ..< tasks.len:
    if not tasks[i].used:
      return i
  -1

proc snapshot(t: WasmSchedulerTask, status = wasmSchedOk): WasmSchedulerResult =
  WasmSchedulerResult(
    status: status,
    id: t.id,
    slot: t.slot,
    state: t.state,
    result: t.task.result,
    trapCode: t.task.trapCode,
    resumes: t.resumes,
    yields: t.yields,
    fuelUsed: t.fuelUsed,
    fuelLimit: t.fuelLimit,
  )

proc resetWasmScheduler*() =
  for i in 0 ..< tasks.len:
    clearSlot(i)
  nextTaskId = 1'u32

proc startWasmTaskI32*(slot: uint32, exportName: string,
                       args: openArray[int32],
                       maxTotalFuel = WasmSchedulerDefaultMaxTotalFuel): WasmSchedulerResult =
  schedulerDebugStage(0xD0D0_0001'u32)
  let index = findFreeTaskIndex()
  schedulerDebugStage(0xD0D0_0002'u32)
  if index < 0:
    return WasmSchedulerResult(status: wasmSchedNoSlot, id: 0, slot: slot.int32)

  var handle: WasmProgramHandle
  schedulerDebugStage(0xD0D0_0003'u32)
  let openErr = handle.openWasmProgramSlot(slot)
  schedulerDebugStage(0xD0D0_0004'u32)
  if openErr != wasmManagerOk:
    return WasmSchedulerResult(
      status: wasmSchedOpenFailed,
      managerError: openErr,
      id: 0,
      slot: slot.int32,
    )

  var task: IntWasmTask
  schedulerDebugStage(0xD0D0_0005'u32)
  try:
    task = handle.vm.initIntWasmTaskI32(handle.moduleIdx, exportName, args)
    schedulerDebugStage(0xD0D0_0006'u32)
  except CatchableError:
    handle.close()
    schedulerDebugStage(0xD0D0_0007'u32)
    return WasmSchedulerResult(status: wasmSchedInitFailed, id: 0, slot: slot.int32)

  let id = nextTaskId
  inc nextTaskId
  if nextTaskId == 0:
    nextTaskId = 1
  tasks[index] = WasmSchedulerTask(
    used: true,
    id: id,
    slot: slot.int32,
    state: wasmTaskReady,
    handle: handle,
    task: task,
    fuelLimit: maxTotalFuel,
  )
  schedulerDebugStage(0xD0D0_0008'u32)
  snapshot(tasks[index])

proc startWasmImageTaskI32*(base: ptr UncheckedArray[byte], len: uint32,
                            exportName: string, args: openArray[int32],
                            maxTotalFuel = WasmSchedulerDefaultMaxTotalFuel,
                            slotLabel = -1'i32): WasmSchedulerResult =
  schedulerDebugStage(0xD0D1_0001'u32)
  let index = findFreeTaskIndex()
  schedulerDebugStage(0xD0D1_0002'u32)
  if index < 0:
    return WasmSchedulerResult(status: wasmSchedNoSlot, id: 0, slot: slotLabel)

  var handle: WasmProgramHandle
  schedulerDebugStage(0xD0D1_0003'u32)
  let openErr = handle.openWasmProgramImage(base, len)
  schedulerDebugStage(0xD0D1_0004'u32)
  if openErr != wasmManagerOk:
    return WasmSchedulerResult(
      status: wasmSchedOpenFailed,
      managerError: openErr,
      id: 0,
      slot: slotLabel,
    )

  var task: IntWasmTask
  schedulerDebugStage(0xD0D1_0005'u32)
  try:
    task = handle.vm.initIntWasmTaskI32(handle.moduleIdx, exportName, args)
    schedulerDebugStage(0xD0D1_0006'u32)
  except CatchableError:
    handle.close()
    schedulerDebugStage(0xD0D1_0007'u32)
    return WasmSchedulerResult(status: wasmSchedInitFailed, id: 0, slot: slotLabel)

  let id = nextTaskId
  inc nextTaskId
  if nextTaskId == 0:
    nextTaskId = 1
  tasks[index] = WasmSchedulerTask(
    used: true,
    id: id,
    slot: slotLabel,
    state: wasmTaskReady,
    handle: handle,
    task: task,
    fuelLimit: maxTotalFuel,
  )
  schedulerDebugStage(0xD0D1_0008'u32)
  snapshot(tasks[index])

proc resumeWasmTask*(id: uint32,
                     fuel = WasmSchedulerDefaultFuel): WasmSchedulerResult =
  let index = findTaskIndex(id)
  if index < 0:
    return WasmSchedulerResult(status: wasmSchedNoTask, id: id)
  if tasks[index].state in {wasmTaskExited, wasmTaskTrapped, wasmTaskKilled}:
    return snapshot(tasks[index], wasmSchedBadState)
  if tasks[index].state in {wasmTaskBlockedHttp, wasmTaskBlockedSd, wasmTaskBlockedIpc,
      wasmTaskBlockedTimer, wasmTaskBlockedEnclave}:
    return snapshot(tasks[index], wasmSchedBadState)
  if tasks[index].fuelLimit != 0 and
      (fuel > tasks[index].fuelLimit or
       tasks[index].fuelUsed > tasks[index].fuelLimit - fuel):
    tasks[index].state = wasmTaskTrapped
    tasks[index].task.state = intTaskTrapped
    tasks[index].task.trapCode = wasmSchedQuotaExceeded.ord.uint32
    return snapshot(tasks[index], wasmSchedQuotaExceeded)

  let state = tasks[index].handle.vm.resumeIntWasmTask(tasks[index].task, fuel)
  inc tasks[index].resumes
  tasks[index].fuelUsed += fuel
  tasks[index].state = state.toSchedulerState()
  if tasks[index].state == wasmTaskYielded:
    inc tasks[index].yields
  if tasks[index].state == wasmTaskTrapped:
    return snapshot(tasks[index], wasmSchedTrap)
  snapshot(tasks[index])

proc runWasmScheduler*(fuelPerTask = WasmSchedulerDefaultFuel,
                       maxResumes = 32'u32): uint32 =
  ## Resume ready/yielded tasks in table order. Returns the number of resumes.
  var count = 0'u32
  while count < maxResumes:
    var progressed = false
    for i in 0 ..< tasks.len:
      if count >= maxResumes:
        break
      if tasks[i].used and tasks[i].state in {wasmTaskReady, wasmTaskYielded}:
        discard resumeWasmTask(tasks[i].id, fuelPerTask)
        inc count
        progressed = true
    if not progressed:
      break
  count

proc killWasmTask*(id: uint32): WasmSchedulerResult =
  let index = findTaskIndex(id)
  if index < 0:
    return WasmSchedulerResult(status: wasmSchedNoTask, id: id)
  tasks[index].state = wasmTaskKilled
  result = snapshot(tasks[index])
  clearSlot(index)
  result.state = wasmTaskKilled

proc blockWasmTask*(id: uint32, blockedState: WasmSchedulerTaskState): WasmSchedulerResult =
  let index = findTaskIndex(id)
  if index < 0:
    return WasmSchedulerResult(status: wasmSchedNoTask, id: id)
  if blockedState notin {wasmTaskBlockedHttp, wasmTaskBlockedSd, wasmTaskBlockedIpc,
      wasmTaskBlockedTimer, wasmTaskBlockedEnclave}:
    return snapshot(tasks[index], wasmSchedBadState)
  if tasks[index].state notin {wasmTaskReady, wasmTaskYielded}:
    return snapshot(tasks[index], wasmSchedBadState)
  tasks[index].state = blockedState
  snapshot(tasks[index])

proc unblockWasmTask*(id: uint32): WasmSchedulerResult =
  let index = findTaskIndex(id)
  if index < 0:
    return WasmSchedulerResult(status: wasmSchedNoTask, id: id)
  if tasks[index].state notin {wasmTaskBlockedHttp, wasmTaskBlockedSd, wasmTaskBlockedIpc,
      wasmTaskBlockedTimer, wasmTaskBlockedEnclave}:
    return snapshot(tasks[index], wasmSchedBadState)
  tasks[index].state = wasmTaskYielded
  snapshot(tasks[index])

proc getWasmTask*(id: uint32): WasmSchedulerResult =
  let index = findTaskIndex(id)
  if index < 0:
    return WasmSchedulerResult(status: wasmSchedNoTask, id: id)
  snapshot(tasks[index])

proc collectWasmTasks*(outTasks: var openArray[WasmSchedulerTaskInfo]): uint32 =
  for i in 0 ..< tasks.len:
    if result >= outTasks.len.uint32:
      break
    if tasks[i].used:
      outTasks[result.int] = WasmSchedulerTaskInfo(
        id: tasks[i].id,
        slot: tasks[i].slot,
        state: tasks[i].state,
        result: tasks[i].task.result,
        trapCode: tasks[i].task.trapCode,
        resumes: tasks[i].resumes,
        yields: tasks[i].yields,
        fuelUsed: tasks[i].fuelUsed,
        fuelLimit: tasks[i].fuelLimit,
      )
      inc result
