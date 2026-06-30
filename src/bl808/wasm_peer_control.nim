## Shared-memory peer-core WASM task control.
##
## M0 writes compact command records for D0/LP into per-core mailboxes. Peer
## workers poll the mailbox from CPS, run the local WASM scheduler/control API,
## then publish a result in the same record. This is deliberately polling-first:
## it survives missed IPC edges and matches the all-core smoke's existing XRAM
## request style.

import ./wasm_control

when not (defined(bl808d0) or defined(bl808lp)):
  import ./wasm_os
  import ./wasm_store

when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  import ./core
  import ./memmap
  import ./mmio

  template peerFence() =
    core.fence()
else:
  const
    XramBase = 0x4000_0000'u
    PsramBase = 0x5000_0000'u

  proc regRead(address: uint): uint32 =
    discard address
    0'u32

  proc regWrite(address: uint, value: uint32) =
    discard address
    discard value

  proc dcacheFlushAll() = discard
  proc dcacheInvalidateAll() = discard
  proc fenceIo() = discard
  template peerFence() =
    discard

const
  WasmPeerControlMagic* = 0x5750_4354'u32 # "WPCT"
  WasmPeerControlD0Addr* = XramBase + 0x3E40'u
  WasmPeerControlLpAddr* = 0x40002D00'u
  WasmPeerControlD0ImageAddr* = PsramBase + 0x1_0000'u
  WasmPeerControlD0ImageMaxLen* = 64 * 1024'u32
  WasmPeerControlLpImageAddr* = 0x40002F00'u
  WasmPeerControlLpImageMaxLen* = 256'u32
  WasmPeerControlMaxArgs* = 8
  WasmPeerControlMaxExportNameLen* = 32
  WasmPeerControlMaxTaskRecords* = WasmSchedulerMaxTasks
  WasmPeerControlTimeoutPolls* {.intdefine.} = 200_000'u32

  PeerOffMagic = 0'u
  PeerOffSeq = 4'u
  PeerOffOpcode = 8'u
  PeerOffState = 12'u
  PeerOffSlot = 16'u
  PeerOffArgc = 20'u
  PeerOffFuel = 24'u
  PeerOffTaskId = 28'u
  PeerOffNameLen = 32'u
  PeerOffControlStatus = 36'u
  PeerOffSchedulerStatus = 40'u
  PeerOffTaskState = 44'u
  PeerOffValue = 48'u
  PeerOffTrapCode = 52'u
  PeerOffResumes = 56'u
  PeerOffYields = 60'u
  PeerOffFuelUsed = 64'u
  PeerOffFuelLimit = 68'u
  PeerOffArgs = 72'u
  PeerOffName = 104'u
  PeerOffImageAddr = 136'u
  PeerOffImageLen = 140'u
  PeerOffTaskCount = 144'u
  PeerOffTaskRecords = 148'u
  PeerTaskRecordWords = 9'u
  PeerTaskRecordBytes = PeerTaskRecordWords * 4'u

  PeerDebugStageClaimed = 0xD0C0_0001'u32
  PeerDebugStageReadHeader = 0xD0C0_0002'u32
  PeerDebugStageReadArgs = 0xD0C0_0003'u32
  PeerDebugStageReadName = 0xD0C0_0004'u32
  PeerDebugStageDispatch = 0xD0C0_0005'u32
  PeerDebugStageResult = 0xD0C0_0006'u32

type
  WasmPeerControlOpcode* = enum
    wasmPeerNoop
    wasmPeerStart
    wasmPeerResume
    wasmPeerRunScheduler
    wasmPeerKill
    wasmPeerStatus
    wasmPeerListTasks

  WasmPeerControlState* = enum
    wasmPeerIdle
    wasmPeerPending
    wasmPeerDone
    wasmPeerBusy
    wasmPeerBadRequest

when not (defined(bl808d0) or defined(bl808lp)):
  type
    WasmPeerTaskRecord* = object
      id*: uint32
      slot*: int32
      state*: WasmSchedulerTaskState
      value*: int32
      trapCode*: uint32
      resumes*: uint32
      yields*: uint32
      fuelUsed*: uint32
      fuelLimit*: uint32

    WasmPeerControlResult* = object
      ok*: bool
      timedOut*: bool
      badCore*: bool
      seq*: uint32
      core*: WasmOsCore
      opcode*: WasmPeerControlOpcode
      controlStatus*: WasmControlStatus
      schedulerStatus*: WasmSchedulerStatus
      taskState*: WasmSchedulerTaskState
      taskId*: uint32
      slot*: int32
      value*: int32
      trapCode*: uint32
      resumes*: uint32
      yields*: uint32
      fuelUsed*: uint32
      fuelLimit*: uint32
      taskCount*: uint32


when not (defined(bl808d0) or defined(bl808lp)):
  var peerControlSeq = 1'u32

when not (defined(bl808d0) or defined(bl808lp)):
  proc peerMailboxBase*(core: WasmOsCore): uint =
    case core
    of wasmOsCoreD0: WasmPeerControlD0Addr
    of wasmOsCoreLP: WasmPeerControlLpAddr
    else: 0'u

proc peerArgAddr(base: uint, index: int): uint =
  base + PeerOffArgs + index.uint * 4'u

proc peerNameAddr(base: uint, index: int): uint =
  base + PeerOffName + index.uint

proc peerTaskRecordAddr(base: uint, index: int, word: uint): uint =
  base + PeerOffTaskRecords + index.uint * PeerTaskRecordBytes + word * 4'u

proc publishBarrier() {.inline.} =
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    dcacheFlushAll()
    fenceIo()

proc consumeBarrier() {.inline.} =
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    dcacheInvalidateAll()
    peerFence()

when not (defined(bl808d0) or defined(bl808lp)):
  proc readPeerResult(base: uint, core: WasmOsCore, seq: uint32,
                      opcode: WasmPeerControlOpcode): WasmPeerControlResult =
    result.core = core
    result.seq = seq
    result.opcode = opcode
    result.slot = cast[int32](regRead(base + PeerOffSlot))
    result.taskId = regRead(base + PeerOffTaskId)
    result.controlStatus = WasmControlStatus(regRead(base + PeerOffControlStatus))
    result.schedulerStatus = WasmSchedulerStatus(regRead(base + PeerOffSchedulerStatus))
    result.taskState = WasmSchedulerTaskState(regRead(base + PeerOffTaskState))
    result.value = cast[int32](regRead(base + PeerOffValue))
    result.trapCode = regRead(base + PeerOffTrapCode)
    result.resumes = regRead(base + PeerOffResumes)
    result.yields = regRead(base + PeerOffYields)
    result.fuelUsed = regRead(base + PeerOffFuelUsed)
    result.fuelLimit = regRead(base + PeerOffFuelLimit)
    result.taskCount = regRead(base + PeerOffTaskCount)
    if opcode == wasmPeerListTasks and result.taskCount == 0'u32:
      result.taskCount = result.taskId
    result.ok = result.controlStatus == wasmControlOk

  proc readPeerTaskRecord*(core: WasmOsCore, index: int,
                           record: var WasmPeerTaskRecord): bool =
    let base = peerMailboxBase(core)
    if base == 0 or index < 0 or index >= WasmPeerControlMaxTaskRecords:
      return false
    consumeBarrier()
    if regRead(base + PeerOffMagic) != WasmPeerControlMagic:
      return false
    record.id = regRead(peerTaskRecordAddr(base, index, 0))
    record.slot = cast[int32](regRead(peerTaskRecordAddr(base, index, 1)))
    record.state = WasmSchedulerTaskState(regRead(peerTaskRecordAddr(base, index, 2)))
    record.value = cast[int32](regRead(peerTaskRecordAddr(base, index, 3)))
    record.trapCode = regRead(peerTaskRecordAddr(base, index, 4))
    record.resumes = regRead(peerTaskRecordAddr(base, index, 5))
    record.yields = regRead(peerTaskRecordAddr(base, index, 6))
    record.fuelUsed = regRead(peerTaskRecordAddr(base, index, 7))
    record.fuelLimit = regRead(peerTaskRecordAddr(base, index, 8))
    true

proc writePeerResult(base: uint, seq: uint32, r: WasmControlTaskResult) =
  regWrite(base + PeerOffTaskId, r.taskId)
  regWrite(base + PeerOffSlot, cast[uint32](r.slot))
  regWrite(base + PeerOffControlStatus, r.status.ord.uint32)
  regWrite(base + PeerOffSchedulerStatus, r.schedulerStatus.ord.uint32)
  regWrite(base + PeerOffTaskState, r.taskState.ord.uint32)
  regWrite(base + PeerOffValue, cast[uint32](r.value))
  regWrite(base + PeerOffTrapCode, r.trapCode)
  regWrite(base + PeerOffResumes, r.resumes)
  regWrite(base + PeerOffYields, r.yields)
  regWrite(base + PeerOffFuelUsed, r.fuelUsed)
  regWrite(base + PeerOffFuelLimit, r.fuelLimit)
  regWrite(base + PeerOffSeq, seq)
  regWrite(base + PeerOffState, wasmPeerDone.ord.uint32)
  publishBarrier()

proc writePeerBadRequest(base: uint, seq: uint32) =
  regWrite(base + PeerOffControlStatus, wasmControlBadSlot.ord.uint32)
  regWrite(base + PeerOffSchedulerStatus, wasmSchedBadTask.ord.uint32)
  regWrite(base + PeerOffSeq, seq)
  regWrite(base + PeerOffState, wasmPeerBadRequest.ord.uint32)
  publishBarrier()

proc writePeerDebugStage(base: uint, stage: uint32) =
  regWrite(base + PeerOffControlStatus, stage)
  publishBarrier()

proc initPeerWasmControlMailbox*(base: uint) =
  ## Put a mailbox into a known idle state before a peer begins polling it.
  regWrite(base + PeerOffState, wasmPeerIdle.ord.uint32)
  regWrite(base + PeerOffOpcode, wasmPeerNoop.ord.uint32)
  regWrite(base + PeerOffSeq, 0'u32)
  regWrite(base + PeerOffSlot, 0'u32)
  regWrite(base + PeerOffArgc, 0'u32)
  regWrite(base + PeerOffFuel, 0'u32)
  regWrite(base + PeerOffTaskId, 0'u32)
  regWrite(base + PeerOffNameLen, 0'u32)
  regWrite(base + PeerOffControlStatus, wasmControlOk.ord.uint32)
  regWrite(base + PeerOffSchedulerStatus, wasmSchedOk.ord.uint32)
  regWrite(base + PeerOffTaskState, wasmTaskReady.ord.uint32)
  regWrite(base + PeerOffValue, 0'u32)
  regWrite(base + PeerOffTrapCode, 0'u32)
  regWrite(base + PeerOffResumes, 0'u32)
  regWrite(base + PeerOffYields, 0'u32)
  regWrite(base + PeerOffFuelUsed, 0'u32)
  regWrite(base + PeerOffFuelLimit, 0'u32)
  regWrite(base + PeerOffImageAddr, 0'u32)
  regWrite(base + PeerOffImageLen, 0'u32)
  regWrite(base + PeerOffTaskCount, 0'u32)
  for i in 0 ..< WasmPeerControlMaxArgs:
    regWrite(peerArgAddr(base, i), 0'u32)
  let namePtr = cast[ptr UncheckedArray[uint8]](peerNameAddr(base, 0))
  for i in 0 ..< WasmPeerControlMaxExportNameLen:
    namePtr[i] = 0'u8
  regWrite(base + PeerOffMagic, WasmPeerControlMagic)
  publishBarrier()

when not (defined(bl808d0) or defined(bl808lp)):
  proc nextPeerSeq(): uint32 =
    result = peerControlSeq
    inc peerControlSeq
    if peerControlSeq == 0:
      peerControlSeq = 1

when not (defined(bl808d0) or defined(bl808lp)):
  proc stagePeerWasmImage(core: WasmOsCore, slotIndex: uint32): tuple[address: uint32, len: uint32] =
    let stageAddr =
      case core
      of wasmOsCoreD0: WasmPeerControlD0ImageAddr
      of wasmOsCoreLP: WasmPeerControlLpImageAddr
      else: 0'u
    let maxLen =
      case core
      of wasmOsCoreD0: WasmPeerControlD0ImageMaxLen
      of wasmOsCoreLP: WasmPeerControlLpImageMaxLen
      else: 0'u32
    if stageAddr == 0'u or maxLen == 0'u32:
      return (0'u32, 0'u32)
    let slot = wasmProgramSlot(slotIndex)
    if not slot.valid:
      return (0'u32, 0'u32)
    let base = slot.xipPtr()
    if base == nil:
      return (0'u32, 0'u32)
    let header = readWasmProgramHeader(base)
    if validateWasmProgramHeader(slot, header) != wasmProgramOk:
      return (0'u32, 0'u32)
    let imageLen = header.headerLen.uint32 + header.imageLen
    if imageLen == 0 or imageLen > maxLen:
      return (0'u32, 0'u32)
    let dst = cast[ptr UncheckedArray[byte]](stageAddr)
    for i in 0'u32 ..< imageLen:
      dst[i.int] = base[i.int]
    publishBarrier()
    (stageAddr.uint32, imageLen)

  proc publishPeerRequest(base: uint, seq: uint32, opcode: WasmPeerControlOpcode,
                          slot, taskId, fuel, imageAddr, imageLen: uint32,
                          exportName: string,
                          args: openArray[int32]) =
    regWrite(base + PeerOffMagic, WasmPeerControlMagic)
    regWrite(base + PeerOffSeq, seq)
    regWrite(base + PeerOffOpcode, opcode.ord.uint32)
    regWrite(base + PeerOffSlot, slot)
    regWrite(base + PeerOffArgc, args.len.uint32)
    regWrite(base + PeerOffFuel, fuel)
    regWrite(base + PeerOffTaskId, taskId)
    regWrite(base + PeerOffImageAddr, imageAddr)
    regWrite(base + PeerOffImageLen, imageLen)
    let nameLen =
      if exportName.len > WasmPeerControlMaxExportNameLen: WasmPeerControlMaxExportNameLen
      else: exportName.len
    regWrite(base + PeerOffNameLen, nameLen.uint32)
    for i in 0 ..< WasmPeerControlMaxArgs:
      let value = if i < args.len: cast[uint32](args[i]) else: 0'u32
      regWrite(peerArgAddr(base, i), value)
    let namePtr = cast[ptr UncheckedArray[uint8]](peerNameAddr(base, 0))
    for i in 0 ..< WasmPeerControlMaxExportNameLen:
      namePtr[i] = if i < nameLen: exportName[i].uint8 else: 0'u8
    regWrite(base + PeerOffState, wasmPeerPending.ord.uint32)
    publishBarrier()

  proc dispatchPeerRequest*(core: WasmOsCore, opcode: WasmPeerControlOpcode,
                            slot = 0'u32, taskId = 0'u32,
                            exportName = "", args: openArray[int32] = [],
                            fuel = WasmSchedulerDefaultFuel,
                            timeoutPolls = WasmPeerControlTimeoutPolls): WasmPeerControlResult =
    when not (defined(bl808m0) or defined(bl808d0) or defined(bl808lp)):
      return WasmPeerControlResult(badCore: true, core: core, opcode: opcode,
                                   slot: slot.int32, taskId: taskId)
    let base = peerMailboxBase(core)
    if base == 0:
      return WasmPeerControlResult(badCore: true, core: core, opcode: opcode)
    if args.len > WasmPeerControlMaxArgs:
      return WasmPeerControlResult(badCore: true, core: core, opcode: opcode)

    let seq = nextPeerSeq()
    let staged =
      if opcode == wasmPeerStart:
        stagePeerWasmImage(core, slot)
      else:
        (0'u32, 0'u32)
    publishPeerRequest(base, seq, opcode, slot, taskId, fuel,
                       staged.address, staged.len, exportName, args)
    var polls = 0'u32
    while polls < timeoutPolls:
      consumeBarrier()
      if regRead(base + PeerOffMagic) == WasmPeerControlMagic and
          regRead(base + PeerOffSeq) == seq:
        let state = regRead(base + PeerOffState)
        if state == wasmPeerDone.ord.uint32 or state == wasmPeerBadRequest.ord.uint32:
          result = readPeerResult(base, core, seq, opcode)
          result.ok = result.ok and state == wasmPeerDone.ord.uint32
          return
      inc polls
    WasmPeerControlResult(timedOut: true, core: core, seq: seq, opcode: opcode,
                          slot: slot.int32, taskId: taskId)

proc servicePeerWasmControlCommand*(base: uint) =
  consumeBarrier()
  if regRead(base + PeerOffMagic) != WasmPeerControlMagic:
    return
  if regRead(base + PeerOffState) != wasmPeerPending.ord.uint32:
    return

  let seq = regRead(base + PeerOffSeq)
  let opcodeRaw = regRead(base + PeerOffOpcode)
  if opcodeRaw > wasmPeerListTasks.ord.uint32:
    writePeerBadRequest(base, seq)
    return
  let opcode = WasmPeerControlOpcode(opcodeRaw)
  let slot = regRead(base + PeerOffSlot)
  let taskId = regRead(base + PeerOffTaskId)
  let fuel = regRead(base + PeerOffFuel)
  let imageAddr = regRead(base + PeerOffImageAddr)
  let imageLen = regRead(base + PeerOffImageLen)
  let argc = regRead(base + PeerOffArgc).int
  let nameLen = regRead(base + PeerOffNameLen).int
  if argc < 0 or argc > WasmPeerControlMaxArgs or
      nameLen < 0 or nameLen > WasmPeerControlMaxExportNameLen:
    writePeerBadRequest(base, seq)
    return

  regWrite(base + PeerOffState, wasmPeerBusy.ord.uint32)
  publishBarrier()
  writePeerDebugStage(base, PeerDebugStageClaimed)

  var args: array[WasmPeerControlMaxArgs, int32]
  writePeerDebugStage(base, PeerDebugStageReadArgs)
  for i in 0 ..< argc:
    args[i] = cast[int32](regRead(peerArgAddr(base, i)))

  var exportName = newString(nameLen)
  let namePtr = cast[ptr UncheckedArray[uint8]](peerNameAddr(base, 0))
  writePeerDebugStage(base, PeerDebugStageReadName)
  for i in 0 ..< nameLen:
    exportName[i] = char(namePtr[i])

  writePeerDebugStage(base, PeerDebugStageDispatch)
  let taskResult =
    case opcode
    of wasmPeerStart:
      if imageAddr != 0'u32 and imageLen != 0'u32:
        let image = cast[ptr UncheckedArray[byte]](imageAddr.uint)
        if argc == 0:
          startWasmProgramImageTaskI32(image, imageLen, slot, exportName, [],
                                       maxTotalFuel = fuel)
        else:
          startWasmProgramImageTaskI32(image, imageLen, slot, exportName,
                                       toOpenArray(args, 0, argc - 1),
                                       maxTotalFuel = fuel)
      else:
        if argc == 0:
          startWasmProgramTaskI32(slot, exportName, [])
        else:
          startWasmProgramTaskI32(slot, exportName, toOpenArray(args, 0, argc - 1),
                                  maxTotalFuel = fuel)
    of wasmPeerResume:
      resumeWasmProgramTask(taskId, fuel)
    of wasmPeerRunScheduler:
      let resumes = runWasmProgramScheduler(fuel, slot)
      WasmControlTaskResult(status: wasmControlOk, schedulerStatus: wasmSchedOk,
                            taskId: taskId, slot: slot.int32, value: resumes.int32)
    of wasmPeerKill:
      killWasmProgramTask(taskId)
    of wasmPeerStatus:
      getWasmProgramTask(taskId)
    of wasmPeerListTasks:
      var tasks: array[WasmPeerControlMaxTaskRecords, WasmSchedulerTaskInfo]
      let count = collectWasmTasks(tasks)
      regWrite(base + PeerOffTaskCount, count)
      for i in 0 ..< min(count.int, WasmPeerControlMaxTaskRecords):
        regWrite(peerTaskRecordAddr(base, i, 0), tasks[i].id)
        regWrite(peerTaskRecordAddr(base, i, 1), cast[uint32](tasks[i].slot))
        regWrite(peerTaskRecordAddr(base, i, 2), tasks[i].state.ord.uint32)
        regWrite(peerTaskRecordAddr(base, i, 3), cast[uint32](tasks[i].result))
        regWrite(peerTaskRecordAddr(base, i, 4), tasks[i].trapCode)
        regWrite(peerTaskRecordAddr(base, i, 5), tasks[i].resumes)
        regWrite(peerTaskRecordAddr(base, i, 6), tasks[i].yields)
        regWrite(peerTaskRecordAddr(base, i, 7), tasks[i].fuelUsed)
        regWrite(peerTaskRecordAddr(base, i, 8), tasks[i].fuelLimit)
      WasmControlTaskResult(status: wasmControlOk, schedulerStatus: wasmSchedOk,
                            taskId: count, slot: slot.int32,
                            taskState: wasmTaskReady)
    else:
      WasmControlTaskResult(status: wasmControlBadSlot,
                            schedulerStatus: wasmSchedBadTask,
                            taskId: taskId, slot: slot.int32)
  writePeerDebugStage(base, PeerDebugStageResult)
  writePeerResult(base, seq, taskResult)
