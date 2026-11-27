## Cooperative scheduler for flash-backed compact WASM programs.
##
## The scheduler owns live VM handles and resumable task contexts. It is small
## on purpose: one core-local table, fixed task capacity, and explicit fuel
## slices. Transports such as HTTP or enclave services can build policy on top
## without re-instantiating programs for every resume.

import ./wasm_manager
import cps/wasm/runtime_int
import cps/wasm/types
when defined(bl808WasmRtPolicy):
  import ./wasm_rt_policy
when defined(bl808WasmFullScheduler):
  import ./wasm_full_manager
  import ./enclave/sha256
  import cps/wasm/runtime
  when defined(wasmChunkedMemory):
    import cps/wasm/linear_memory

const FullSchedulerAtomicWait* = defined(bl808WasmFullScheduler) and
  defined(wasmSharedCoreTypes) and defined(wasmAtomicWait)

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
  WasmSchedulerClock* = proc(): uint64 {.nimcall.}

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
    wasmSchedBackingFailed
    wasmSchedRestorePending

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
    wasmTaskBlockedMemory
    wasmTaskMigrating
    wasmTaskBlockedAtomic

  WasmTaskMigrationStatus* = enum
    wasmMigrationOk
    wasmMigrationNoTask
    wasmMigrationBadState
    wasmMigrationUnsupported
    wasmMigrationTooLarge
    wasmMigrationWrongModule
    wasmMigrationInvalidSnapshot
    wasmMigrationOpenFailed
    wasmMigrationNoSlot
    wasmMigrationPending
    wasmMigrationBackingFailed

  WasmTaskMigration* = object
    ## Transport-neutral, bounded guest state. The receiver must have the
    ## same CRC-checked immutable module in its own flash mapping.
    status*: WasmTaskMigrationStatus
    slot*: uint32
    fuelLimit*: uint32
    fuelUsed*: uint32
    bytes*: seq[byte]
    when defined(bl808WasmFullScheduler):
      staged*: WasmPortableStaging

  WasmTaskMigrationRole = enum
    wmrNone
    wmrSource
    wmrDestination

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
    resumes: uint32
    yields: uint32
    fuelUsed: uint32
    fuelLimit: uint32
    maxMemoryPages*: uint16  # per-instance memory quota (0 = use module default)
    lastTrapCode*: uint32    # reason of the most recent terminal transition
    trapReapCountdown*: uint8 # reaper passes until a trapped slot is reclaimed
    lastPc*: int             # interpreter pc at previous resume (watchdog)
    stalledSlices*: uint8    # resume slices with no pc advance (watchdog)
    when defined(bl808WasmFullScheduler):
      ## A slot holds one runtime kind at a time. Keeping both the compact
      ## label array and the full continuation in every slot consumed most of
      ## LP's 16 KiB writable budget even when only one full task was active.
      case full: bool
      of true:
        fullHandle: FullWasmProgramHandle
        fullContinuation: WasmContinuation
        fullFuncAddr: int
        fullArgs: seq[WasmValue]
        fullResult: int32
        fullTrapCode: uint32
        migrationRole: WasmTaskMigrationRole
        portableMigrationDisabled: bool
        retainTrappedTask: bool
        when defined(wasmStreamMigration):
          migrationStream: ref WasmPortableStream
        when defined(wasmChunkedMemory):
          migrationCapture: ref WasmPortableCapture
          migrationRestore: ref tuple[state: WasmPortableRestore, bytes: seq[byte],
                                      staged: WasmPortableStaging]
      of false:
        handle: WasmProgramHandle
        task: IntWasmTask
    else:
      handle: WasmProgramHandle
      task: IntWasmTask

when defined(bl808WasmFullScheduler) and defined(wasmChunkedMemory):
  type WasmSchedulerMemoryTelemetry* = object
    found*: bool
    fullInterpreter*: bool
    guestPages*: uint32
    committedChunks*: uint32
    residentChunks*: uint32
    backedChunks*: uint32
    pageIns*: uint32
    pageOuts*: uint32
    wouldBlock*: uint32
    backingFailures*: uint32
    pageInTicks*: uint64
    pageOutTicks*: uint64
    maxPageInTicks*: uint64
    maxPageOutTicks*: uint64
    completedFaults*: uint32
    maxFaultWaitTicks*: uint64
    when WasmTieredFramesEnabled:
      sramResidentChunks*, psramResidentChunks*: uint32

var
  tasks: array[WasmSchedulerMaxTasks, WasmSchedulerTask]
  nextTaskId = 1'u32
  schedulerDebugHook: proc(stage: uint32) {.nimcall.}

when FullSchedulerAtomicWait:
  type WasmSchedulerAtomicTicks* = proc(ns: uint64): uint64 {.nimcall.}
  var schedulerAtomicClock: WasmAtomicClock
  when defined(bl808WasmRtPolicy):
    var schedulerAtomicTicks: WasmSchedulerAtomicTicks

  proc setWasmSchedulerAtomicClock*(clock: WasmAtomicClock,
      durationToTicks: WasmSchedulerAtomicTicks = nil) =
    ## Configure once at boot with the timed scheduler's clock domain.
    schedulerAtomicClock = clock
    when defined(bl808WasmRtPolicy):
      schedulerAtomicTicks = durationToTicks

proc schedulerTaskRunnable(task: var WasmSchedulerTask): bool =
  if not task.used: return false
  when FullSchedulerAtomicWait:
    if task.state == wasmTaskBlockedAtomic:
      return task.fullHandle.vm[].executionRunnable(task.fullContinuation)
  task.state in {wasmTaskReady, wasmTaskYielded}

when defined(bl808WasmRtPolicy):
  var
    rtPolicy: WasmRtPolicy
    rtConfigured: bool
    rtDispatchActive: bool
    rtWakeHook: proc() {.nimcall.}

template notifyWasmRtScheduleChanged() =
  when defined(bl808WasmRtPolicy):
    if rtWakeHook != nil and not rtDispatchActive:
      rtWakeHook()

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
  when defined(bl808WasmRtPolicy):
    rtPolicy.removeWasmRtJob(tasks[index].id)
  when defined(bl808WasmFullScheduler):
    if tasks[index].full:
      when defined(wasmStreamMigration):
        if tasks[index].migrationStream != nil:
          tasks[index].migrationStream[].cancelPortableStream()
      when defined(wasmChunkedMemory):
        if tasks[index].migrationCapture != nil:
          tasks[index].migrationCapture[].cancelPortableCapture()
        if tasks[index].migrationRestore != nil:
          tasks[index].fullHandle.vm[].cancelPortableRestore(tasks[index].migrationRestore.state)
      if tasks[index].fullHandle.vm != nil:
        tasks[index].fullHandle.vm[].abortExecution(tasks[index].fullContinuation)
      tasks[index].fullHandle.close()
    else:
      tasks[index].handle.close()
  else:
    tasks[index].handle.close()
  tasks[index] = WasmSchedulerTask()
  notifyWasmRtScheduleChanged()

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
  when defined(bl808WasmFullScheduler):
    let taskResult = if t.full: t.fullResult else: t.task.result
    let trapCode = if t.full: t.fullTrapCode else: t.task.trapCode
  else:
    let taskResult = t.task.result
    let trapCode = t.task.trapCode
  WasmSchedulerResult(
    status: status,
    id: t.id,
    slot: t.slot,
    state: t.state,
    result: taskResult,
    trapCode: trapCode,
    resumes: t.resumes,
    yields: t.yields,
    fuelUsed: t.fuelUsed,
    fuelLimit: t.fuelLimit,
  )

proc resetWasmScheduler*() =
  # Keep local IDs increasing across a scheduler reset. An in-flight
  # ownership acknowledgement may still refer to a slot being torn down.
  for i in 0 ..< tasks.len:
    clearSlotTeardown(i)
  when defined(bl808WasmRtPolicy):
    rtPolicy = WasmRtPolicy()
    rtConfigured = false
    notifyWasmRtScheduleChanged()

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
  tasks[index] = WasmSchedulerTask()
  tasks[index].used = true
  tasks[index].id = id
  tasks[index].programId = slot
  tasks[index].ownerCore = ownerCore
  tasks[index].priority = priority
  tasks[index].slot = slot.int32
  tasks[index].state = wasmTaskReady
  tasks[index].handle = handle
  tasks[index].task = task
  tasks[index].fuelLimit = maxTotalFuel
  tasks[index].maxMemoryPages = maxMemoryPages
  schedulerDebugStage(0xD0D0_0008'u32)
  notifyWasmRtScheduleChanged()
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
  tasks[index] = WasmSchedulerTask()
  tasks[index].used = true
  tasks[index].id = id
  tasks[index].programId = slotLabel.uint32
  tasks[index].ownerCore = ownerCore
  tasks[index].priority = priority
  tasks[index].slot = slotLabel
  tasks[index].state = wasmTaskReady
  tasks[index].handle = handle
  tasks[index].task = task
  tasks[index].fuelLimit = maxTotalFuel
  tasks[index].maxMemoryPages = maxMemoryPages
  schedulerDebugStage(0xD0D1_0008'u32)
  notifyWasmRtScheduleChanged()
  snapshot(tasks[index])

when defined(bl808WasmFullScheduler):
  proc startFullHandleI32(handle: var FullWasmProgramHandle,
                          slotLabel: int32, exportName: string,
                          args: openArray[int32], maxTotalFuel: uint32,
                          priority, ownerCore: uint8,
                          maxMemoryPages: uint32,
                          allowPortableMigration, retainTrappedTask: bool): WasmSchedulerResult =
    let index = findFreeTaskIndex()
    if index < 0:
      handle.close()
      return WasmSchedulerResult(status: wasmSchedNoSlot, slot: slotLabel)
    if args.len > 8:
      handle.close()
      return WasmSchedulerResult(status: wasmSchedInitFailed, slot: slotLabel)
    var funcAddr: int
    try:
      funcAddr = handle.fullExportFuncAddr(exportName)
      let ft = handle.vm[].store.funcs[funcAddr].funcType
      if ft.params.len != args.len or ft.results.len != 1 or
          ft.results[0] != vtI32:
        raise newException(WasmTrap, "full task requires an i32 result")
      for param in ft.params:
        if param != vtI32:
          raise newException(WasmTrap, "full task requires i32 parameters")
    except CatchableError:
      handle.close()
      return WasmSchedulerResult(status: wasmSchedInitFailed, slot: slotLabel)
    var typedArgs = newSeq[WasmValue](args.len)
    for i in 0 ..< args.len:
      typedArgs[i] = wasmI32(args[i])
    let id = nextTaskId
    inc nextTaskId
    if nextTaskId == 0: nextTaskId = 1
    tasks[index] = WasmSchedulerTask(
      used: true, id: id, programId: slotLabel.uint32,
      ownerCore: ownerCore, priority: priority, slot: slotLabel,
      state: wasmTaskReady, full: true, fullHandle: move handle,
      fullFuncAddr: funcAddr, fullArgs: move typedArgs,
      portableMigrationDisabled: not allowPortableMigration,
      retainTrappedTask: retainTrappedTask,
      fuelLimit: maxTotalFuel,
      maxMemoryPages: min(maxMemoryPages, uint16.high.uint32).uint16,
    )
    notifyWasmRtScheduleChanged()
    snapshot(tasks[index])

  proc startFullWasmTaskI32*(slot: uint32, exportName: string,
                             args: openArray[int32],
                             maxTotalFuel = WasmSchedulerDefaultMaxTotalFuel,
                             priority = 0'u8, ownerCore = 0'u8,
                             maxMemoryPages = 0'u32,
                             memoryFactory: FullMemoryFactory = nil,
                             memoryFactoryContext: pointer = nil,
                             requireNoStart = false,
                             admission = FullWasmAdmission(),
                             allowPortableMigration = true,
                             retainTrappedTask = false): WasmSchedulerResult =
    ## Open a CRC-checked XIP slot into the same bounded task table.
    if findFreeTaskIndex() < 0:
      return WasmSchedulerResult(status: wasmSchedNoSlot, slot: slot.int32)
    var handle: FullWasmProgramHandle
    let openErr = handle.openFullWasmProgramSlot(slot, maxMemoryPages,
                                                memoryFactory,
                                                memoryFactoryContext,
                                                requireNoStart = requireNoStart,
                                                admission = admission)
    if openErr != wasmManagerOk:
      return WasmSchedulerResult(status: wasmSchedOpenFailed,
        managerError: openErr, slot: slot.int32)
    startFullHandleI32(handle, slot.int32, exportName, args, maxTotalFuel,
      priority, ownerCore, maxMemoryPages, allowPortableMigration, retainTrappedTask)

  proc startFullWasmImageTaskI32*(base: ptr UncheckedArray[byte], len: uint32,
                                  exportName: string, args: openArray[int32],
                                  maxTotalFuel = WasmSchedulerDefaultMaxTotalFuel,
                                  slotLabel = -1'i32,
                                  priority = 0'u8, ownerCore = 0'u8,
                                  maxMemoryPages = 0'u32,
                                  memoryFactory: FullMemoryFactory = nil,
                                  memoryFactoryContext: pointer = nil,
                                  requireNoStart = false,
                                  admission = FullWasmAdmission(),
                                  allowPortableMigration = true,
                                  retainTrappedTask = false): WasmSchedulerResult =
    ## Staging-buffer variant for host tests and approved image delivery.
    if findFreeTaskIndex() < 0:
      return WasmSchedulerResult(status: wasmSchedNoSlot, slot: slotLabel)
    var handle: FullWasmProgramHandle
    let openErr = handle.openFullWasmProgramImage(base, len, maxMemoryPages,
                                                 memoryFactory,
                                                memoryFactoryContext,
                                                 requireNoStart = requireNoStart,
                                                 admission = admission)
    if openErr != wasmManagerOk:
      return WasmSchedulerResult(status: wasmSchedOpenFailed,
        managerError: openErr, slot: slotLabel)
    startFullHandleI32(handle, slotLabel, exportName, args, maxTotalFuel,
      priority, ownerCore, maxMemoryPages, allowPortableMigration, retainTrappedTask)

  proc fullModuleDigest(handle: FullWasmProgramHandle): Sha256Digest =
    let image = handle.program.module.image
    if image.bytes == nil or image.len <= 0:
      raise newException(WasmTrap, "full task has no module image")
    sha256(image.bytes.toOpenArray(0, image.len - 1))

  proc migrationStatus(status: WasmPortableStatus): WasmTaskMigrationStatus =
    case status
    of wpsOk: wasmMigrationOk
    of wpsTooLarge: wasmMigrationTooLarge
    of wpsWrongModule: wasmMigrationWrongModule
    of wpsInvalidSnapshot: wasmMigrationInvalidSnapshot
    of wpsNotSuspended: wasmMigrationBadState
    of wpsUnsupportedState: wasmMigrationUnsupported
    of wpsPending: wasmMigrationPending
    of wpsBackingFailed: wasmMigrationBackingFailed

  proc migrationView*(migration: WasmTaskMigration): WasmPortableStaging {.inline.} =
    if migration.staged.hasPortableStaging(): migration.staged
    else: portableInputView(migration.bytes)

  proc freezeWasmTaskMigration(index: int, brokerManaged = false): WasmTaskMigrationStatus =
    if index < 0: return wasmMigrationNoTask
    let task = addr tasks[index]
    if not task[].full or task[].state != wasmTaskYielded or
        task[].migrationRole != wmrNone:
      return wasmMigrationBadState
    if (if brokerManaged:
          not task[].portableMigrationDisabled or not task[].retainTrappedTask
        else: task[].portableMigrationDisabled) or
        task[].slot < 0 or task[].fullHandle.vm == nil or
        task[].fullContinuation.instructions != task[].fuelUsed.uint64:
      return wasmMigrationUnsupported
    when defined(bl808WasmRtPolicy):
      if rtConfigured and rtPolicy.hasWasmRtJob(task[].id):
        return wasmMigrationUnsupported
    task[].migrationRole = wmrSource
    task[].state = wasmTaskMigrating
    notifyWasmRtScheduleChanged()
    wasmMigrationOk

  proc captureTaskMigration(id: uint32, maxBytes: int, staging: WasmPortableStaging,
                             allowAsync: static bool,
                             brokerManaged = false): WasmTaskMigration =
    let index = findTaskIndex(id)
    result.status = freezeWasmTaskMigration(index, brokerManaged)
    if result.status != wasmMigrationOk: return
    let task = addr tasks[index]
    defer:
      if result.status notin {wasmMigrationOk, wasmMigrationPending}:
        task[].migrationRole = wmrNone
        task[].state = wasmTaskYielded
        notifyWasmRtScheduleChanged()
    try:
      let digest = fullModuleDigest(task[].fullHandle)
      let vm = task[].fullHandle.vm
      var captured: WasmPortableSnapshot
      when defined(wasmChunkedMemory) and allowAsync:
        var capture: WasmPortableCapture
        defer: capture.cancelPortableCapture()
        let status = vm[].beginPortableCapture(task[].fullContinuation, digest, capture, maxBytes, staging)
        if status == wpsPending:
          new(task[].migrationCapture)
          task[].migrationCapture[] = move capture
          return WasmTaskMigration(status: wasmMigrationPending)
        captured = if status == wpsOk: capture.takePortableSnapshot()
                   else: WasmPortableSnapshot(status: status)
      else:
        captured = vm[].capturePortableSnapshot(task[].fullContinuation, digest, maxBytes, staging)
      result = WasmTaskMigration(status: migrationStatus(captured.status),
        slot: task[].slot.uint32, fuelLimit: task[].fuelLimit, fuelUsed: task[].fuelUsed,
        bytes: move captured.bytes, staged: captured.staged)
    except CatchableError:
      result.status = wasmMigrationUnsupported

  proc captureWasmTaskMigration*(id: uint32,
      maxBytes = WasmPortableMaxBytes, staging = WasmPortableStaging()): WasmTaskMigration =
    ## Freeze a yielded task synchronously. The caller may cancel before
    ## ownership commits and must retire the source before activation.
    captureTaskMigration(id, maxBytes, staging, false)

  proc beginWasmTaskMigrationCapture*(id: uint32,
      maxBytes = WasmPortableMaxBytes, staging = WasmPortableStaging()): WasmTaskMigration =
    ## Freeze the source before initiating any asynchronous snapshot reads.
    captureTaskMigration(id, maxBytes, staging, true)

  proc beginBrokerWasmTaskMigrationCapture*(id: uint32,
      maxBytes: int, staging: WasmPortableStaging): WasmTaskMigration =
    ## The broker client owns the suspended task until retirement.
    captureTaskMigration(id, maxBytes, staging, true, brokerManaged = true)

  when defined(wasmStreamMigration):
    proc beginWasmTaskMigrationStream*(id: uint32, maxBytes: int,
                                      brokerManaged = false): WasmTaskMigration =
      let index = findTaskIndex(id)
      result.status = freezeWasmTaskMigration(index, brokerManaged)
      if result.status != wasmMigrationOk: return
      let task = addr tasks[index]
      new(task[].migrationStream)
      try:
        let digest = fullModuleDigest(task[].fullHandle)
        result.status = migrationStatus(task[].fullHandle.vm[].beginPortableStream(
          task[].fullContinuation, digest, maxBytes, task[].migrationStream[]))
      except CatchableError:
        result.status = wasmMigrationUnsupported
      if result.status != wasmMigrationOk:
        task[].migrationStream[].cancelPortableStream()
        task[].migrationStream = nil
        task[].migrationRole = wmrNone
        task[].state = wasmTaskYielded
        notifyWasmRtScheduleChanged()
        return
      result.slot = task[].slot.uint32
      result.fuelLimit = task[].fuelLimit
      result.fuelUsed = task[].fuelUsed

    proc readWasmTaskMigrationStream*(id: uint32, dest: var openArray[byte],
                                     written: var int): WasmTaskMigrationStatus =
      written = 0
      let index = findTaskIndex(id)
      if index < 0: return wasmMigrationNoTask
      let task = addr tasks[index]
      if not task[].full or task[].state != wasmTaskMigrating or
          task[].migrationRole != wmrSource or task[].migrationStream == nil:
        return wasmMigrationBadState
      try:
        result = migrationStatus(task[].fullHandle.vm[].readPortableStream(
          task[].fullContinuation, task[].migrationStream[], dest, written))
      except CatchableError:
        result = wasmMigrationUnsupported
      if result != wasmMigrationPending:
        task[].migrationStream[].cancelPortableStream()
        task[].migrationStream = nil
        if result != wasmMigrationOk:
          written = 0
          task[].migrationRole = wmrNone
          task[].state = wasmTaskYielded
          notifyWasmRtScheduleChanged()

  when defined(wasmChunkedMemory):
    proc pollWasmTaskMigrationCapture*(id: uint32): WasmTaskMigration =
      let index = findTaskIndex(id)
      if index < 0: return WasmTaskMigration(status: wasmMigrationNoTask)
      let task = addr tasks[index]
      if not task[].full or task[].state != wasmTaskMigrating or
          task[].migrationRole != wmrSource or task[].migrationCapture == nil:
        return WasmTaskMigration(status: wasmMigrationBadState)
      let capture = task[].migrationCapture
      var status = wpsUnsupportedState
      try: status = task[].fullHandle.vm[].pollPortableCapture(capture[])
      except CatchableError: discard
      if status == wpsPending: return WasmTaskMigration(status: wasmMigrationPending)
      task[].migrationCapture = nil
      if status != wpsOk:
        capture[].cancelPortableCapture()
        task[].migrationRole = wmrNone
        task[].state = wasmTaskYielded
        notifyWasmRtScheduleChanged()
        return WasmTaskMigration(status: migrationStatus(status))
      var captured = capture[].takePortableSnapshot()
      WasmTaskMigration(status: wasmMigrationOk, slot: task[].slot.uint32,
        fuelLimit: task[].fuelLimit, fuelUsed: task[].fuelUsed,
        bytes: move captured.bytes, staged: captured.staged)

  proc cancelWasmTaskMigration*(id: uint32): WasmTaskMigrationStatus =
    ## Safe only before the destination is activated or a commit is sent.
    let index = findTaskIndex(id)
    if index < 0: return wasmMigrationNoTask
    if not tasks[index].full or tasks[index].state != wasmTaskMigrating or
        tasks[index].migrationRole != wmrSource:
      return wasmMigrationBadState
    when defined(wasmStreamMigration):
      if tasks[index].migrationStream != nil:
        tasks[index].migrationStream[].cancelPortableStream()
        tasks[index].migrationStream = nil
    when defined(wasmChunkedMemory):
      if tasks[index].migrationCapture != nil:
        tasks[index].migrationCapture[].cancelPortableCapture()
        tasks[index].migrationCapture = nil
    tasks[index].migrationRole = wmrNone
    tasks[index].state = wasmTaskYielded
    notifyWasmRtScheduleChanged()
    wasmMigrationOk

  proc retireWasmTaskMigration*(id: uint32): WasmTaskMigrationStatus =
    ## Retire the source before sending the remote activation commit. A lost
    ## commit can strand work, but cannot execute it twice.
    let index = findTaskIndex(id)
    if index < 0: return wasmMigrationNoTask
    if not tasks[index].full or tasks[index].state != wasmTaskMigrating or
        tasks[index].migrationRole != wmrSource:
      return wasmMigrationBadState
    when defined(wasmChunkedMemory):
      if tasks[index].migrationCapture != nil: return wasmMigrationBadState
    when defined(wasmStreamMigration):
      if tasks[index].migrationStream != nil: return wasmMigrationBadState
    clearSlotTeardown(index)
    wasmMigrationOk

  proc prepareFullMigrationHandle(handle: var FullWasmProgramHandle,
                                  slotLabel: int32,
                                  migration: sink WasmTaskMigration,
                                  allowPagedRestore: bool): WasmSchedulerResult =
    let index = findFreeTaskIndex()
    if index < 0:
      handle.close()
      return WasmSchedulerResult(status: wasmSchedNoSlot, slot: slotLabel)
    let view = migration.migrationView()
    let staged = migration.staged.hasPortableStaging()
    if migration.status != wasmMigrationOk or slotLabel < 0 or
        migration.slot != slotLabel.uint32 or not view.validPortableStaging() or
        (not staged and view.len > WasmPortableMaxBytes) or
        (staged and migration.bytes.len != 0) or
        (migration.fuelLimit != 0 and
         migration.fuelUsed >= migration.fuelLimit):
      handle.close()
      return WasmSchedulerResult(status: wasmSchedInitFailed, slot: slotLabel)
    var continuation: WasmContinuation
    var status: WasmPortableStatus
    when defined(wasmChunkedMemory):
      var pending: WasmPortableRestore
    try:
      let digest = fullModuleDigest(handle)
      when defined(wasmChunkedMemory):
        if allowPagedRestore:
          status = handle.vm[].beginPortableRestore(continuation, view, digest, pending)
        else:
          status = handle.vm[].restorePortableSnapshot(continuation, view, digest)
      else:
        status = handle.vm[].restorePortableSnapshot(continuation, view, digest)
      if status notin {wpsOk, wpsPending} or
          continuation.instructions != migration.fuelUsed.uint64:
        handle.close()
        return WasmSchedulerResult(
          status: if status == wpsBackingFailed: wasmSchedBackingFailed else: wasmSchedInitFailed,
          slot: slotLabel)
      let ft = handle.vm[].store.funcs[
        continuation.continuationEntryFuncAddr()].funcType
      if ft.results.len != 1 or ft.results[0] != vtI32:
        handle.close()
        return WasmSchedulerResult(status: wasmSchedInitFailed,
          slot: slotLabel)
    except CatchableError:
      handle.close()
      return WasmSchedulerResult(status: wasmSchedInitFailed,
        slot: slotLabel)
    let id = nextTaskId
    inc nextTaskId
    if nextTaskId == 0: nextTaskId = 1
    tasks[index] = WasmSchedulerTask(
      used: true, id: id, programId: migration.slot,
      slot: slotLabel, state: wasmTaskMigrating, full: true,
      fullHandle: move handle, fullContinuation: continuation,
      fullFuncAddr: continuation.continuationEntryFuncAddr(),
      migrationRole: wmrDestination,
      fuelLimit: migration.fuelLimit, fuelUsed: migration.fuelUsed)
    when defined(wasmChunkedMemory):
      if status == wpsPending:
        new(tasks[index].migrationRestore)
        tasks[index].migrationRestore.state = pending
        tasks[index].migrationRestore.staged = migration.staged
        tasks[index].migrationRestore.bytes = move migration.bytes
        return snapshot(tasks[index], wasmSchedRestorePending)
    snapshot(tasks[index])

  proc prepareFullWasmMigrationSlot*(migration: sink WasmTaskMigration,
      maxMemoryPages = 0'u32, memoryFactory: FullMemoryFactory = nil,
      memoryFactoryContext: pointer = nil, allowPagedRestore = false,
      enforceMemoryQuota = false): WasmSchedulerResult =
    ## Open the receiver's local CRC-checked slot and verify its module
    ## digest before creating a dormant task. It cannot run until activated.
    ## Keep a borrowed staging region immutable until prepare finishes or is canceled.
    if migration.slot > high(int32).uint32:
      return WasmSchedulerResult(status: wasmSchedInitFailed, slot: -1)
    let slotLabel = migration.slot.int32
    if findFreeTaskIndex() < 0:
      return WasmSchedulerResult(status: wasmSchedNoSlot,
        slot: slotLabel)
    var handle: FullWasmProgramHandle
    let openErr = handle.openFullWasmProgramSlot(migration.slot, maxMemoryPages,
      memoryFactory, memoryFactoryContext, restoreSnapshot = true,
      admission = FullWasmAdmission(enforceMemoryQuota: enforceMemoryQuota))
    if openErr != wasmManagerOk:
      return WasmSchedulerResult(status: wasmSchedOpenFailed,
        managerError: openErr, slot: slotLabel)
    prepareFullMigrationHandle(handle, slotLabel, move migration, allowPagedRestore)

  proc prepareFullWasmMigrationImage*(base: ptr UncheckedArray[byte],
      len: uint32, migration: sink WasmTaskMigration,
      maxMemoryPages = 0'u32, memoryFactory: FullMemoryFactory = nil,
      memoryFactoryContext: pointer = nil, allowPagedRestore = false,
      enforceMemoryQuota = false): WasmSchedulerResult =
    ## Staged-image form for host tests and approved image delivery. The
    ## same staging lifetime applies to a pending prepare.
    if migration.slot > high(int32).uint32:
      return WasmSchedulerResult(status: wasmSchedInitFailed, slot: -1)
    let slotLabel = migration.slot.int32
    if findFreeTaskIndex() < 0:
      return WasmSchedulerResult(status: wasmSchedNoSlot,
        slot: slotLabel)
    var handle: FullWasmProgramHandle
    let openErr = handle.openFullWasmProgramImage(base, len, maxMemoryPages,
      memoryFactory, memoryFactoryContext, restoreSnapshot = true,
      admission = FullWasmAdmission(enforceMemoryQuota: enforceMemoryQuota))
    if openErr != wasmManagerOk:
      return WasmSchedulerResult(status: wasmSchedOpenFailed,
        managerError: openErr, slot: slotLabel)
    prepareFullMigrationHandle(handle, slotLabel, move migration, allowPagedRestore)

  when defined(wasmChunkedMemory):
    proc pollFullWasmMigrationRestore*(id: uint32): WasmSchedulerResult =
      let index = findTaskIndex(id)
      if index < 0: return WasmSchedulerResult(status: wasmSchedNoTask, id: id)
      let task = addr tasks[index]
      if not task[].full or task[].state != wasmTaskMigrating or
          task[].migrationRole != wmrDestination or task[].migrationRestore == nil:
        return snapshot(task[], wasmSchedBadState)
      let pending = task[].migrationRestore
      var status = wpsUnsupportedState
      try:
        let view = if pending.staged.hasPortableStaging(): pending.staged
                   else: portableInputView(pending.bytes)
        status = task[].fullHandle.vm[].pollPortableRestore(task[].fullContinuation,
          view, pending.state)
      except CatchableError: discard
      case status
      of wpsPending: result = snapshot(task[], wasmSchedRestorePending)
      of wpsOk:
        task[].migrationRestore = nil
        result = snapshot(task[])
      else:
        result = snapshot(task[], wasmSchedBackingFailed)
        clearSlotTeardown(index)

  proc preparedWasmMigrationEntryMatches*(id: uint32, exportName: string): bool =
    let index = findTaskIndex(id)
    if index < 0: return false
    let task = addr tasks[index]
    if not task[].full or task[].state != wasmTaskMigrating or
        task[].migrationRole != wmrDestination or task[].fullHandle.vm == nil:
      return false
    try:
      task[].fullHandle.fullExportFuncAddr(exportName) == task[].fullFuncAddr
    except CatchableError:
      false

  proc activateWasmTaskMigration*(id: uint32,
                                  brokerOwnerCore = 0'u8): WasmTaskMigrationStatus =
    ## Call only after the source has irreversibly retired ownership.
    let index = findTaskIndex(id)
    if index < 0: return wasmMigrationNoTask
    if not tasks[index].full or tasks[index].state != wasmTaskMigrating or
        tasks[index].migrationRole != wmrDestination:
      return wasmMigrationBadState
    when defined(wasmChunkedMemory):
      if tasks[index].migrationRestore != nil: return wasmMigrationBadState
    if brokerOwnerCore != 0:
      tasks[index].portableMigrationDisabled = true
      tasks[index].retainTrappedTask = true
      tasks[index].ownerCore = brokerOwnerCore
    tasks[index].migrationRole = wmrNone
    tasks[index].state = wasmTaskYielded
    notifyWasmRtScheduleChanged()
    wasmMigrationOk

  proc discardPreparedWasmTaskMigration*(id: uint32): WasmTaskMigrationStatus =
    ## Drop a destination that never received the ownership commit.
    let index = findTaskIndex(id)
    if index < 0: return wasmMigrationNoTask
    if not tasks[index].full or tasks[index].state != wasmTaskMigrating or
        tasks[index].migrationRole != wmrDestination:
      return wasmMigrationBadState
    clearSlotTeardown(index)
    wasmMigrationOk

  proc resumeFullWasmTask(index: int, fuel: uint32,
                          deadlineClock: WasmSchedulerClock,
                          deadlineTick: uint64): WasmSchedulerResult =
    if fuel == 0:
      return snapshot(tasks[index], wasmSchedBadState)
    let remaining = if tasks[index].fuelLimit == 0: fuel
                    elif tasks[index].fuelUsed >= tasks[index].fuelLimit: 0'u32
                    else: tasks[index].fuelLimit - tasks[index].fuelUsed
    if remaining == 0:
      tasks[index].state = wasmTaskTrapped
      tasks[index].fullTrapCode = wtQuota.ord.uint32
      tasks[index].lastTrapCode = tasks[index].fullTrapCode
      tasks[index].trapReapCountdown = WasmTaskTrapReapPolls
      return snapshot(tasks[index], wasmSchedQuotaExceeded)
    let slice = min(fuel, remaining)
    let before = tasks[index].fullContinuation.instructions
    tasks[index].state = wasmTaskRunning
    var values: seq[WasmValue]
    var trapped = false
    try:
      when FullSchedulerAtomicWait:
        if tasks[index].fullContinuation.status != wesAtomicBlocked:
          tasks[index].fullHandle.vm[].setWasmAtomicClock(schedulerAtomicClock)
      values = tasks[index].fullHandle.vm[].executeSlice(
        tasks[index].fullFuncAddr, tasks[index].fullArgs,
        tasks[index].fullContinuation, slice,
        deadlineClock = deadlineClock, deadlineTick = deadlineTick)
    except CatchableError:
      trapped = true
    inc tasks[index].resumes
    let consumed = tasks[index].fullContinuation.instructions - before
    tasks[index].fuelUsed = min(uint32.high.uint64,
      tasks[index].fuelUsed.uint64 + consumed).uint32
    if trapped:
      tasks[index].fullHandle.vm[].abortExecution(tasks[index].fullContinuation)
      tasks[index].state = wasmTaskTrapped
      tasks[index].fullTrapCode = wtUnknown.ord.uint32
      tasks[index].lastTrapCode = tasks[index].fullTrapCode
      tasks[index].trapReapCountdown = WasmTaskTrapReapPolls
      return snapshot(tasks[index], wasmSchedTrap)
    case tasks[index].fullContinuation.status
    of wesYielded:
      tasks[index].state = wasmTaskYielded
      inc tasks[index].yields
      if consumed == 0:
        if tasks[index].stalledSlices < 255'u8: inc tasks[index].stalledSlices
      else:
        tasks[index].stalledSlices = 0
    of wesComplete:
      if values.len != 1 or values[0].kind != wvkI32:
        tasks[index].state = wasmTaskTrapped
        tasks[index].fullTrapCode = wtUnknown.ord.uint32
        tasks[index].lastTrapCode = tasks[index].fullTrapCode
        tasks[index].trapReapCountdown = WasmTaskTrapReapPolls
        return snapshot(tasks[index], wasmSchedTrap)
      tasks[index].fullResult = values[0].i32
      tasks[index].state = wasmTaskExited
      tasks[index].stalledSlices = 0
    of wesMemoryBlocked:
      tasks[index].state = wasmTaskBlockedMemory
      inc tasks[index].yields
      tasks[index].stalledSlices = 0
    of wesAtomicBlocked:
      tasks[index].state = wasmTaskBlockedAtomic
      if consumed != 0: inc tasks[index].yields
      tasks[index].stalledSlices = 0
    else:
      tasks[index].state = wasmTaskTrapped
      tasks[index].fullTrapCode = wtUnknown.ord.uint32
      tasks[index].lastTrapCode = tasks[index].fullTrapCode
      tasks[index].trapReapCountdown = WasmTaskTrapReapPolls
      return snapshot(tasks[index], wasmSchedTrap)
    snapshot(tasks[index])

  when defined(wasmChunkedMemory):
    proc serviceWasmTaskMemoryFault*(id: uint32): WasmSchedulerResult =
      ## Invoke from the backing owner after a full task blocked on a chunk.
      ## A failed SD/IPC service terminates that instance with a stable error.
      let index = findTaskIndex(id)
      if index < 0:
        return WasmSchedulerResult(status: wasmSchedNoTask, id: id)
      if not tasks[index].full or tasks[index].state != wasmTaskBlockedMemory:
        return snapshot(tasks[index], wasmSchedBadState)
      let status = tasks[index].fullHandle.vm[].serviceExecutionMemoryFault(
        tasks[index].fullContinuation)
      if status == lmOk:
        tasks[index].state = wasmTaskYielded
        notifyWasmRtScheduleChanged()
        return snapshot(tasks[index])
      if status == lmWouldBlock:
        ## An asynchronous backing transfer has started or is still in
        ## flight. Keep the guest suspended until the owner calls again.
        return snapshot(tasks[index])
      tasks[index].fullHandle.vm[].abortExecution(tasks[index].fullContinuation)
      tasks[index].state = wasmTaskTrapped
      tasks[index].fullTrapCode = wtUnknown.ord.uint32
      tasks[index].lastTrapCode = tasks[index].fullTrapCode
      tasks[index].trapReapCountdown = WasmTaskTrapReapPolls
      when defined(bl808WasmRtPolicy):
        rtPolicy.removeWasmRtJob(id)
        notifyWasmRtScheduleChanged()
      snapshot(tasks[index], wasmSchedBackingFailed)

proc resumeWasmTaskImpl(id, fuel: uint32, deadlineClock: WasmSchedulerClock,
                        deadlineTick: uint64): WasmSchedulerResult =
  let index = findTaskIndex(id)
  if index < 0:
    return WasmSchedulerResult(status: wasmSchedNoTask, id: id)
  if tasks[index].state in {wasmTaskExited, wasmTaskTrapped, wasmTaskKilled}:
    return snapshot(tasks[index], wasmSchedBadState)
  if tasks[index].state in {wasmTaskBlockedHttp, wasmTaskBlockedSd, wasmTaskBlockedIpc,
      wasmTaskBlockedTimer, wasmTaskBlockedEnclave, wasmTaskBlockedMemory,
      wasmTaskMigrating}:
    return snapshot(tasks[index], wasmSchedBadState)
  when FullSchedulerAtomicWait:
    if tasks[index].state == wasmTaskBlockedAtomic and not tasks[index].schedulerTaskRunnable():
      return snapshot(tasks[index], wasmSchedBadState)
  when defined(bl808WasmFullScheduler):
    if tasks[index].full:
      return resumeFullWasmTask(index, fuel, deadlineClock, deadlineTick)
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

proc resumeWasmTask*(id: uint32,
                     fuel = WasmSchedulerDefaultFuel,
                     deadlineClock: WasmSchedulerClock = nil,
                     deadlineTick = 0'u64): WasmSchedulerResult =
  when defined(bl808WasmRtPolicy):
    if rtConfigured and (rtWakeHook != nil or rtPolicy.hasWasmRtJob(id)):
      let index = findTaskIndex(id)
      if index >= 0: return snapshot(tasks[index], wasmSchedBadState)
  resumeWasmTaskImpl(id, fuel, deadlineClock, deadlineTick)

proc runWasmScheduler*(fuelPerTask = WasmSchedulerDefaultFuel,
                       maxResumes = 32'u32): uint32 =
  ## Resume ready/yielded tasks in table order. Returns the number of resumes.
  when defined(bl808WasmRtPolicy):
    if rtConfigured and rtWakeHook != nil: return 0
  var count = 0'u32
  while count < maxResumes:
    var progressed = false
    for i in 0 ..< tasks.len:
      if count >= maxResumes:
        break
      if tasks[i].schedulerTaskRunnable():
        when defined(bl808WasmRtPolicy):
          if rtConfigured and rtPolicy.hasWasmRtJob(tasks[i].id): continue
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
  when defined(bl808WasmFullScheduler):
    if tasks[index].full:
      if reason == wasmSchedWatchdog:
        tasks[index].fullTrapCode = wtWatchdog.ord.uint32
      elif reason == wasmSchedQuotaExceeded:
        tasks[index].fullTrapCode = wtQuota.ord.uint32
      elif reason != wasmSchedOk:
        tasks[index].fullTrapCode = reason.ord.uint32
      tasks[index].lastTrapCode = tasks[index].fullTrapCode
      tasks[index].state = wasmTaskKilled
      result = snapshot(tasks[index], reason)
      clearSlotTeardown(index)
      result.state = wasmTaskKilled
      return
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
      when defined(bl808WasmFullScheduler):
        if tasks[i].full and tasks[i].retainTrappedTask: continue
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
  notifyWasmRtScheduleChanged()
  snapshot(tasks[index])

proc unblockWasmTask*(id: uint32): WasmSchedulerResult =
  let index = findTaskIndex(id)
  if index < 0:
    return WasmSchedulerResult(status: wasmSchedNoTask, id: id)
  if tasks[index].state notin {wasmTaskBlockedHttp, wasmTaskBlockedSd, wasmTaskBlockedIpc,
      wasmTaskBlockedTimer, wasmTaskBlockedEnclave}:
    return snapshot(tasks[index], wasmSchedBadState)
  tasks[index].state = wasmTaskYielded
  notifyWasmRtScheduleChanged()
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
      let current = snapshot(tasks[i])
      outTasks[result.int] = WasmSchedulerTaskInfo(
        id: current.id,
        slot: current.slot,
        state: current.state,
        result: current.result,
        trapCode: current.trapCode,
        resumes: current.resumes,
        yields: current.yields,
        fuelUsed: current.fuelUsed,
        fuelLimit: current.fuelLimit,
      )
      inc result

when defined(bl808WasmFullScheduler) and defined(wasmChunkedMemory):
  proc getWasmTaskMemoryTelemetry*(id: uint32): WasmSchedulerMemoryTelemetry =
    let index = findTaskIndex(id)
    if index < 0: return
    result.found = true
    result.fullInterpreter = tasks[index].full
    if not tasks[index].full or tasks[index].fullHandle.vm == nil: return
    for memory in tasks[index].fullHandle.vm[].store.mems:
      if memory.chunked == nil: continue
      let stats = memory.chunked[].stats()
      result.guestPages += stats.guestPages
      result.committedChunks += stats.committedChunks
      result.residentChunks += stats.residentChunks
      when WasmTieredFramesEnabled:
        result.sramResidentChunks += stats.sramResidentChunks
        result.psramResidentChunks += stats.psramResidentChunks
      result.backedChunks += stats.backedChunks
      result.pageIns += stats.pageIns
      result.pageOuts += stats.pageOuts
      result.wouldBlock += stats.wouldBlock
      result.backingFailures += stats.backingFailures
      result.pageInTicks += min(stats.pageInTicks,
        high(uint64) - result.pageInTicks)
      result.pageOutTicks += min(stats.pageOutTicks,
        high(uint64) - result.pageOutTicks)
      result.maxPageInTicks = max(result.maxPageInTicks,
        stats.maxPageInTicks)
      result.maxPageOutTicks = max(result.maxPageOutTicks,
        stats.maxPageOutTicks)
      result.completedFaults += min(stats.completedFaults,
        high(uint32) - result.completedFaults)
      result.maxFaultWaitTicks = max(result.maxFaultWaitTicks,
        stats.maxFaultWaitTicks)

when defined(bl808WasmRtPolicy):
  proc initWasmRtScheduler*(coreBit: uint32, frameEpoch,
                            frameTicks: uint64): WasmRtStatus =
    ## Call once per core after resetWasmScheduler. Ticks must come from the
    ## same monotonic clock as runWasmSchedulerRt's callback.
    result = rtPolicy.initWasmRtPolicy(coreBit, frameEpoch, frameTicks)
    rtConfigured = result == wrOk
    notifyWasmRtScheduleChanged()

  proc admitWasmTaskRt*(id: uint32, spec: WasmRtSpec): WasmRtStatus =
    let index = findTaskIndex(id)
    if not rtConfigured or index < 0 or tasks[index].state in {
        wasmTaskExited, wasmTaskTrapped, wasmTaskKilled, wasmTaskMigrating}:
      return wrInvalid
    if spec.class == wrHard:
      # The compact runtime has no wall-clock instruction preemption. A full
      # task with host imports or allocation-sized bulk operations likewise
      # cannot establish a bounded hard slot from instruction fuel alone.
      when defined(bl808WasmFullScheduler):
        if not tasks[index].full or tasks[index].fullHandle.vm == nil:
          return wrUnsafeHardSlot
        let vm = tasks[index].fullHandle.vm
        for function in vm[].store.funcs:
          if function.isHost: return wrUnsafeHardSlot
          if function.code == nil: continue
          for instruction in function.code[].code:
            if instruction.op in {opMemoryGrow, opMemoryInit, opDataDrop,
                opMemoryCopy, opMemoryFill, opTableInit, opElemDrop,
                opTableCopy, opTableGrow, opTableFill, opMemoryAtomicWait32,
                opMemoryAtomicWait64, opMemoryAtomicNotify}:
              return wrUnsafeHardSlot
        for memory in vm[].store.mems:
          when defined(wasmChunkedMemory):
            if memory.chunked == nil or
                not memory.chunked[].hardResidentReady():
              return wrUnsafeHardSlot
          else:
            return wrUnsafeHardSlot
      else:
        return wrUnsafeHardSlot
    result = rtPolicy.admitWasmRtJob(id, spec)
    if result == wrOk: notifyWasmRtScheduleChanged()

  proc wasmSchedulerRtTelemetry*(): WasmRtTelemetry =
    rtPolicy.wasmRtTelemetry()

  proc collectRtRunnable(outIds: var array[WasmSchedulerMaxTasks, uint32]): int =
    for task in tasks.mitems:
      if task.schedulerTaskRunnable():
        outIds[result] = task.id
        inc result

  proc wasmRtSchedulerReady*(): bool {.inline.} = rtConfigured

  proc setWasmRtKernelWakeHook*(hook: proc() {.nimcall.}) =
    ## An attached kernel driver owns execution of tasks on this core.
    rtWakeHook = hook
    notifyWasmRtScheduleChanged()

  proc nextWasmSchedulerRtWakeTick*(now, fallbackMaxSliceTicks: uint64): uint64 =
    if not rtConfigured: return 0
    var runnable: array[WasmSchedulerMaxTasks, uint32]
    let count = collectRtRunnable(runnable)
    result = if count == 0: rtPolicy.nextWasmRtWakeTick([], now, fallbackMaxSliceTicks)
      else: rtPolicy.nextWasmRtWakeTick(runnable.toOpenArray(0, count - 1),
        now, fallbackMaxSliceTicks)
    when FullSchedulerAtomicWait:
      if schedulerAtomicTicks == nil: return
      for task in tasks.mitems:
        if not task.used or task.state != wasmTaskBlockedAtomic: continue
        let remaining = task.fullHandle.vm[].executionAtomicRemainingNs(task.fullContinuation)
        if remaining == uint64.high: continue
        if remaining == 0 and count > 0 and task.id in runnable.toOpenArray(0, count - 1):
          continue
        let delay = max(1'u64, schedulerAtomicTicks(remaining))
        let wake = now + min(delay, uint64.high - now)
        if result == 0 or wake < result: result = wake

  proc runWasmSchedulerRt*(clock: proc(): uint64 {.nimcall.},
                           fallbackMaxSliceTicks: uint64,
                           fuelPerTask = WasmSchedulerDefaultFuel,
                           maxResumes = 32'u32): uint32 =
    ## Schedule hard reservations, then soft jobs by earliest deadline, then
    ## best-effort work in measured slack. The clock is sampled around every
    ## slice; an overrun is detected after the slice, so a hard slot also
    ## requires a separately established worst-case bound for that slice.
    if not rtConfigured or rtDispatchActive or clock == nil or fuelPerTask == 0:
      return 0
    rtDispatchActive = true
    defer: rtDispatchActive = false
    while result < maxResumes:
      let startTick = clock()
      rtPolicy.pollWasmRtPolicy(startTick)
      var runnable: array[WasmSchedulerMaxTasks, uint32]
      let count = collectRtRunnable(runnable)
      if count == 0: break
      let id = rtPolicy.chooseWasmRtJob(
        runnable.toOpenArray(0, count - 1), startTick,
        fallbackMaxSliceTicks)
      if id == 0: break
      let cutoffTick = rtPolicy.dispatchCutoffTick(id, startTick)
      let taskResult = resumeWasmTaskImpl(id, fuelPerTask,
        deadlineClock = clock, deadlineTick = cutoffTick)
      let endTick = clock()
      let action = rtPolicy.observeWasmRtRun(id, startTick, endTick,
        memoryFault = taskResult.state == wasmTaskBlockedMemory)
      inc result
      let isHard = rtPolicy.wasmRtClass(id) == wrHard
      if action == wrStopJob or (isHard and taskResult.state in {
          wasmTaskBlockedHttp, wasmTaskBlockedSd, wasmTaskBlockedIpc,
          wasmTaskBlockedTimer, wasmTaskBlockedEnclave, wasmTaskBlockedMemory,
          wasmTaskBlockedAtomic}):
        discard stopWasmTask(id, wasmSchedQuotaExceeded)
      elif taskResult.state in {wasmTaskExited, wasmTaskTrapped, wasmTaskKilled}:
        rtPolicy.removeWasmRtJob(id)
