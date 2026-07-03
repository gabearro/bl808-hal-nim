## Cooperative scheduler for flash-backed compact WASM programs.
##
## The scheduler owns live VM handles and resumable task contexts. It is small
## on purpose: one core-local table, fixed task capacity, and explicit fuel
## slices. Transports such as HTTP or enclave services can build policy on top
## without re-instantiating programs for every resume.

import ./wasm_manager
import cps/wasm/runtime_int
import cps/wasm/types

const
  WasmSchedulerMaxTasks* {.intdefine.} = 8
  WasmSchedulerDefaultFuel* {.intdefine.} = 64'u32
  WasmSchedulerDefaultMaxTotalFuel* {.intdefine.} = 4096'u32
  ## Trapped-task reaping. A task that traps stays in the table long enough for
  ## callers of resumeWasmTask to observe wasmTaskTrapped; reapTrappedSlots
  ## (a scheduler poll hook) then reclaims the slot after this many reaper
  ## passes, closing the previous "trapped slot leaks forever" leak.
  WasmTaskTrapReapPolls* {.intdefine.} = 3
  ## Soft watchdog: a yielded task whose interpreter pc did not advance for this
  ## many resume slices is making no forward progress and is force-stopped (the
  ## TASK, never the core). Override per build with -d:WasmCpsWatchdogMaxStall=N.
  WasmCpsWatchdogMaxStall* {.intdefine.} = 64

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
    wasmSchedWatchdog

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
    programId*: uint32     # installed-program slot this instance runs
    ownerCore*: uint8      # WasmOsCore ordinal (decoded by callers); 0 = unknown
    priority*: uint8       # reserved for future priority dispatch
    slot: int32
    state: WasmSchedulerTaskState
    handle: WasmProgramHandle
    task: IntWasmTask
    resumes: uint32
    yields: uint32
    fuelUsed: uint32
    fuelLimit: uint32
    maxMemoryPages*: uint16  # per-instance memory quota (0 = use module default)
    lastTrapCode*: uint32    # reason of the most recent terminal transition
    trapReapCountdown*: uint8 # reaper passes until a trapped slot is reclaimed
    lastPc*: int             # interpreter pc at previous resume (watchdog)
    stalledSlices*: uint8    # resume slices with no pc advance (watchdog)

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

proc clearSlotTeardown(index: int) =
  ## Deterministic, idempotent teardown of one task slot: close the loaded
  ## program view (which also drops the compact linear-memory seq) and zero the
  ## record. Safe to call on an already-empty slot — this is the single
  ## contract invoked from every terminal transition (exit/trap/kill/quota/
  ## watchdog) and from reapTrappedSlots, so trapped slots never leak.
  if index < 0 or index >= tasks.len:
    return
  if not tasks[index].used:
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
    clearSlotTeardown(i)
  nextTaskId = 1'u32

proc startWasmTaskI32*(slot: uint32, exportName: string,
                       args: openArray[int32],
                       maxTotalFuel = WasmSchedulerDefaultMaxTotalFuel,
                       priority = 0'u8, ownerCore = 0'u8,
                       maxMemoryPages = 0'u16): WasmSchedulerResult =
  schedulerDebugStage(0xD0D0_0001'u32)
  let index = findFreeTaskIndex()
  schedulerDebugStage(0xD0D0_0002'u32)
  if index < 0:
    return WasmSchedulerResult(status: wasmSchedNoSlot, id: 0, slot: slot.int32)

  var handle: WasmProgramHandle
  schedulerDebugStage(0xD0D0_0003'u32)
  let openErr = handle.openWasmProgramSlot(slot, maxMemoryPages = maxMemoryPages)
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
    programId: slot,
    ownerCore: ownerCore,
    priority: priority,
    slot: slot.int32,
    state: wasmTaskReady,
    handle: handle,
    task: task,
    fuelLimit: maxTotalFuel,
    maxMemoryPages: maxMemoryPages,
  )
  schedulerDebugStage(0xD0D0_0008'u32)
  snapshot(tasks[index])

proc startWasmImageTaskI32*(base: ptr UncheckedArray[byte], len: uint32,
                            exportName: string, args: openArray[int32],
                            maxTotalFuel = WasmSchedulerDefaultMaxTotalFuel,
                            slotLabel = -1'i32,
                            priority = 0'u8, ownerCore = 0'u8,
                            maxMemoryPages = 0'u16): WasmSchedulerResult =
  schedulerDebugStage(0xD0D1_0001'u32)
  let index = findFreeTaskIndex()
  schedulerDebugStage(0xD0D1_0002'u32)
  if index < 0:
    return WasmSchedulerResult(status: wasmSchedNoSlot, id: 0, slot: slotLabel)

  var handle: WasmProgramHandle
  schedulerDebugStage(0xD0D1_0003'u32)
  let openErr = handle.openWasmProgramImage(base, len, maxMemoryPages = maxMemoryPages)
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
    programId: slotLabel.uint32,
    ownerCore: ownerCore,
    priority: priority,
    slot: slotLabel,
    state: wasmTaskReady,
    handle: handle,
    task: task,
    fuelLimit: maxTotalFuel,
    maxMemoryPages: maxMemoryPages,
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
    tasks[index].task.trapCode = wtQuota.ord.uint32
    tasks[index].lastTrapCode = tasks[index].task.trapCode
    tasks[index].trapReapCountdown = WasmTaskTrapReapPolls
    return snapshot(tasks[index], wasmSchedQuotaExceeded)

  tasks[index].lastPc = tasks[index].task.pc
  let state = tasks[index].handle.vm.resumeIntWasmTask(tasks[index].task, fuel)
  inc tasks[index].resumes
  tasks[index].fuelUsed += fuel
  tasks[index].state = state.toSchedulerState()
  if tasks[index].state == wasmTaskYielded:
    inc tasks[index].yields
    # No-forward-progress watchdog: a yielded task whose interpreter pc did not
    # advance is spinning in place. reapStuckTasks force-stops it once this
    # counter reaches WasmCpsWatchdogMaxStall.
    if tasks[index].task.pc == tasks[index].lastPc:
      if tasks[index].stalledSlices < 255'u8:
        inc tasks[index].stalledSlices
    else:
      tasks[index].stalledSlices = 0
  else:
    tasks[index].stalledSlices = 0
  if tasks[index].state == wasmTaskTrapped:
    tasks[index].lastTrapCode = tasks[index].task.trapCode
    tasks[index].trapReapCountdown = WasmTaskTrapReapPolls
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

proc stopWasmTask*(id: uint32, reason: WasmSchedulerStatus = wasmSchedOk):
    WasmSchedulerResult =
  ## Unified terminal teardown. Sets the terminal state, records the reason as a
  ## tombstone, snapshots the task for the caller, then deterministically tears
  ## the slot down via clearSlotTeardown. Idempotent: an unknown id is a no-op.
  let index = findTaskIndex(id)
  if index < 0:
    return WasmSchedulerResult(status: wasmSchedNoTask, id: id)
  if reason == wasmSchedWatchdog:
    tasks[index].task.trapCode = wtWatchdog.ord.uint32
    tasks[index].lastTrapCode = wtWatchdog.ord.uint32
  elif reason == wasmSchedQuotaExceeded:
    tasks[index].task.trapCode = wtQuota.ord.uint32
    tasks[index].lastTrapCode = wtQuota.ord.uint32
  elif reason != wasmSchedOk:
    tasks[index].lastTrapCode = reason.ord.uint32
  tasks[index].state = wasmTaskKilled
  tasks[index].task.state = intTaskTrapped
  result = snapshot(tasks[index], reason)
  clearSlotTeardown(index)
  result.state = wasmTaskKilled

proc killWasmTask*(id: uint32): WasmSchedulerResult =
  stopWasmTask(id, wasmSchedOk)

proc reapTrappedSlots*(): uint32 =
  ## Reclaim task slots that have been wasmTaskTrapped long enough for callers
  ## to observe the trap. Invoked as a scheduler timed poll hook so the previous
  ## "trapped slot leaks forever" behavior is closed without dropping trap
  ## visibility on the resuming call. Returns the number of slots reaped.
  for i in 0 ..< tasks.len:
    if tasks[i].used and tasks[i].state == wasmTaskTrapped:
      if tasks[i].trapReapCountdown == 0:
        clearSlotTeardown(i)
        inc result
      else:
        dec tasks[i].trapReapCountdown

proc reapStuckTasks*(): uint32 =
  ## Soft watchdog: force-stop tasks that are resumed but make no forward
  ## progress (interpreter pc unchanged across WasmCpsWatchdogMaxStall slices).
  ## Stops the TASK only — never touches the core. Returns the number stopped.
  for i in 0 ..< tasks.len:
    if tasks[i].used and tasks[i].state in {wasmTaskReady, wasmTaskYielded}:
      if tasks[i].stalledSlices >= WasmCpsWatchdogMaxStall:
        discard stopWasmTask(tasks[i].id, wasmSchedWatchdog)
        inc result

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
