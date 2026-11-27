## Portable full-task handoff over the existing 504-byte XRAM IPC payloads.
## The destination stages at most one checksummed guest snapshot. It never
## runs the task before an explicit commit, and it never copies native frames.

when not defined(bl808WasmFullScheduler):
  {.error: "WASM migration requires the full task scheduler".}

import ./[wasm_full_manager, wasm_runtime, wasm_scheduler]
import cps/wasm/runtime
when defined(wasmManagedMigration):
  import ./[wasm_steal_broker, wasm_steal_client]

const
  WasmMigrationWireTag* = 0x5747'u16
  WasmMigrationWireMagic* = 0x474D'u16
  WasmMigrationWireVersion* = when defined(wasmManagedMigration): 5'u8 else: 2'u8
  WasmMigrationWirePayloadBytes* = 504
  WasmMigrationWireHeaderBytes* = when defined(wasmManagedMigration): 56 else: 44
  WasmMigrationWirePartBytes* =
    WasmMigrationWirePayloadBytes - WasmMigrationWireHeaderBytes
  WasmMigrationWireReplyBytes* = when defined(wasmManagedMigration): 28 else: 24
  WasmMigrationMaxSnapshotBytes* =
    (when defined(bl808lp): 512 else: 4096)

type
  WasmMigrationWireOp* = enum
    mwoHello = 1
    mwoBegin = 2
    mwoPart = 3
    mwoPrepare = 4
    mwoCommit = 5
    mwoAbort = 6
    mwoQuery = 7
    mwoBeginStream = 8

  WasmMigrationWireStatus* = enum
    mwsOk = 0
    mwsInvalid = 1
    mwsStaleEpoch = 2
    mwsStaleTransfer = 3
    mwsBusy = 4
    mwsOutOfOrder = 5
    mwsTooLarge = 6
    mwsPrepareFailed = 7
    mwsBadState = 8
    mwsPending = 9
    mwsBackingFailed = 10
    mwsRelayPending = 11

  WasmMigrationWireState* = enum
    mwIdle
    mwReceiving
    mwPreparing
    mwPrepared
    mwActive
    mwPrepareFailed
    mwCommitting

  WasmMigrationWireRequest* = object
    op*: WasmMigrationWireOp
    receiverEpoch*: uint32
    sourceBootId*: uint32
    transferId*: uint32
    slot*: uint32
    fuelLimit*: uint32
    fuelUsed*: uint32
    affinityMask*: uint32
    totalBytes*: uint32
    offset*: uint32
    count*: uint16
    sourceCoreBit*: uint16
    when defined(wasmManagedMigration):
      claim*: WasmStealClaim
      relayViaM0*: bool

  WasmMigrationWireReply* = object
    status*: WasmMigrationWireStatus
    state*: WasmMigrationWireState
    receiverEpoch*: uint32
    transferId*: uint32
    nextOffset*: uint32
    taskId*: uint32
    when defined(wasmManagedMigration):
      checkedSession*: uint32

  WasmMigrationReceiver* = object
    epoch*: uint32
    coreBit*: uint32
    maxSnapshotBytes*: uint32
    maxMemoryPages: uint32
    when defined(wasmChunkedMemory):
      memoryFactory: FullMemoryFactory
      memoryFactoryContext: pointer
    leaseTicks*: uint64
    lastActivityTick*: uint64
    state*: WasmMigrationWireState
    sourceBootId: uint32
    sourceCoreBit: uint16
    transferId: uint32
    slot: uint32
    fuelLimit: uint32
    fuelUsed: uint32
    affinityMask: uint32
    totalBytes: uint32
    received: uint32
    taskId*: uint32
    dropPending: bool
    staging: WasmPortableStaging
    when defined(wasmManagedMigration):
      worker: ptr WasmStealClient
      claim: WasmStealClaim
      checkedSession: uint32
      checking: bool
      accepting: bool
      completed: tuple[bootId: uint32, coreBit: uint16, transferId, taskId: uint32,
                       claim: WasmStealClaim]
    when defined(wasmStreamMigration):
      streamed: bool
    when defined(wasmStorageMigration):
      partOffset: uint32
      partCount: uint16
      partReady: bool
      partStatus: WasmMigrationWireStatus
    bytes: array[WasmMigrationMaxSnapshotBytes, byte]

when defined(wasmMigrationWireHostTest):
  var wasmMigrationPrepareHook*:
    proc(migration: WasmTaskMigration, maxMemoryPages: uint32,
         memoryFactory: FullMemoryFactory, memoryFactoryContext: pointer,
         enforceMemoryQuota: bool): WasmSchedulerResult {.nimcall.}

proc put16(buf: var openArray[byte], at: int, value: uint16) {.inline.} =
  buf[at] = value.byte
  buf[at + 1] = (value shr 8).byte

proc put32(buf: var openArray[byte], at: int, value: uint32) {.inline.} =
  for i in 0 ..< 4: buf[at + i] = (value shr (8 * i)).byte

proc get16(buf: openArray[byte], at: int): uint16 {.inline.} =
  buf[at].uint16 or (buf[at + 1].uint16 shl 8)

proc get32(buf: openArray[byte], at: int): uint32 {.inline.} =
  for i in 0 ..< 4: result = result or (buf[at + i].uint32 shl (8 * i))

when defined(wasmManagedMigration):
  const MigrationRelayBit = 1'u16 shl 15

  proc wasmMigrationRelayTarget*(sourceCoreBit: uint16): uint16 =
    case sourceCoreBit
    of WasmStealD0.uint16: WasmStealLP.uint16
    of WasmStealLP.uint16: WasmStealD0.uint16
    else: 0

  proc wasmMigrationRelayIngress*(request: openArray[byte]): bool {.inline.} =
    request.len >= WasmMigrationWireHeaderBytes and
      (request.get16(42) and MigrationRelayBit) != 0

proc encodeWasmMigrationRequestHeader*(req: WasmMigrationWireRequest,
                                       outBuf: var openArray[byte]): int =
  let payload = if req.op == mwoPart: req.count.int else: 0
  if outBuf.len < WasmMigrationWireHeaderBytes + payload or
      payload > WasmMigrationWirePartBytes:
    return 0
  for i in 0 ..< WasmMigrationWireHeaderBytes: outBuf[i] = 0
  outBuf.put16(0, WasmMigrationWireMagic)
  outBuf[2] = WasmMigrationWireVersion
  outBuf[3] = req.op.ord.byte
  outBuf.put32(4, req.receiverEpoch)
  outBuf.put32(8, req.sourceBootId)
  outBuf.put32(12, req.transferId)
  outBuf.put32(16, req.slot)
  outBuf.put32(20, req.fuelLimit)
  outBuf.put32(24, req.fuelUsed)
  outBuf.put32(28, req.affinityMask)
  outBuf.put32(32, req.totalBytes)
  outBuf.put32(36, req.offset)
  outBuf.put16(40, req.count)
  outBuf.put16(42, req.sourceCoreBit)
  when defined(wasmManagedMigration):
    if req.relayViaM0:
      if wasmMigrationRelayTarget(req.sourceCoreBit) == 0: return 0
      outBuf.put16(42, req.sourceCoreBit or MigrationRelayBit)
    outBuf.put32(44, req.claim.ownerEpoch)
    outBuf.put32(48, req.claim.jobId)
    outBuf.put32(52, req.claim.token)
  WasmMigrationWireHeaderBytes + payload

proc encodeWasmMigrationRequest*(req: WasmMigrationWireRequest,
                                 data: openArray[byte],
                                 outBuf: var openArray[byte]): int =
  if data.len != (if req.op == mwoPart: req.count.int else: 0): return 0
  result = req.encodeWasmMigrationRequestHeader(outBuf)
  if result == 0: return
  for i in 0 ..< data.len:
    outBuf[WasmMigrationWireHeaderBytes + i] = data[i]

proc decodeWasmMigrationRequest*(buf: openArray[byte],
                                 req: var WasmMigrationWireRequest): bool =
  if buf.len < WasmMigrationWireHeaderBytes or
      buf.len > WasmMigrationWirePayloadBytes or
      buf.get16(0) != WasmMigrationWireMagic or
      buf[2] != WasmMigrationWireVersion or
      buf[3] < mwoHello.ord.byte or buf[3] > mwoBeginStream.ord.byte:
    return false
  req = WasmMigrationWireRequest(op: WasmMigrationWireOp(buf[3]),
    receiverEpoch: buf.get32(4), sourceBootId: buf.get32(8),
    transferId: buf.get32(12), slot: buf.get32(16),
    fuelLimit: buf.get32(20), fuelUsed: buf.get32(24),
    affinityMask: buf.get32(28), totalBytes: buf.get32(32),
    offset: buf.get32(36), count: buf.get16(40),
    sourceCoreBit: buf.get16(42))
  when defined(wasmManagedMigration):
    req.relayViaM0 = (req.sourceCoreBit and MigrationRelayBit) != 0
    req.sourceCoreBit = req.sourceCoreBit and not MigrationRelayBit
    if req.relayViaM0 and wasmMigrationRelayTarget(req.sourceCoreBit) == 0: return false
    req.claim = WasmStealClaim(ownerEpoch: buf.get32(44),
      jobId: buf.get32(48), token: buf.get32(52))
    if req.claim != WasmStealClaim() and
        (req.claim.ownerEpoch == 0 or req.claim.jobId == 0 or req.claim.token == 0):
      return false
  if req.sourceCoreBit != 1 and req.sourceCoreBit != 2 and
      req.sourceCoreBit != 4:
    return false
  if req.op == mwoPart:
    req.count > 0 and req.count.int <= WasmMigrationWirePartBytes and
      buf.len == WasmMigrationWireHeaderBytes + req.count.int
  else:
    req.count == 0 and req.offset == 0 and
      buf.len == WasmMigrationWireHeaderBytes

proc encodeWasmMigrationReply*(reply: WasmMigrationWireReply,
                               outBuf: var openArray[byte]): int =
  if outBuf.len < WasmMigrationWireReplyBytes: return 0
  for i in 0 ..< WasmMigrationWireReplyBytes: outBuf[i] = 0
  outBuf.put16(0, WasmMigrationWireMagic)
  outBuf[2] = WasmMigrationWireVersion
  outBuf[3] = reply.status.ord.byte
  outBuf.put32(4, reply.receiverEpoch)
  outBuf.put32(8, reply.transferId)
  outBuf.put32(12, reply.nextOffset)
  outBuf[16] = reply.state.ord.byte
  outBuf.put32(20, reply.taskId)
  when defined(wasmManagedMigration):
    outBuf.put32(24, reply.checkedSession)
  WasmMigrationWireReplyBytes

proc decodeWasmMigrationReply*(buf: openArray[byte],
                               reply: var WasmMigrationWireReply): bool =
  if buf.len != WasmMigrationWireReplyBytes or
      buf.get16(0) != WasmMigrationWireMagic or
      buf[2] != WasmMigrationWireVersion or
      buf[3] > (when defined(wasmManagedMigration): mwsRelayPending.ord.byte
                else: mwsBackingFailed.ord.byte) or
      buf[16] > (when defined(wasmManagedMigration): mwCommitting.ord.byte
                 else: mwPrepareFailed.ord.byte) or
      buf[17] != 0 or buf[18] != 0 or buf[19] != 0:
    return false
  reply = WasmMigrationWireReply(status: WasmMigrationWireStatus(buf[3]),
    receiverEpoch: buf.get32(4), transferId: buf.get32(8),
    nextOffset: buf.get32(12), state: WasmMigrationWireState(buf[16]),
    taskId: buf.get32(20))
  when defined(wasmManagedMigration):
    reply.checkedSession = buf.get32(24)
  true

proc initWasmMigrationReceiver*(receiver: var WasmMigrationReceiver,
                                epoch, coreBit: uint32,
                                maxSnapshotBytes = WasmMigrationMaxSnapshotBytes,
                                leaseTicks = 30_000_000'u64,
                                maxMemoryPages = 0'u32,
                                memoryFactory: FullMemoryFactory = nil,
                                memoryFactoryContext: pointer = nil,
                                staging = WasmPortableStaging()): bool =
  ## A reserved region remains exclusively owned by this receiver, including
  ## during a pending prepare that borrows the bytes.
  let staged = staging.hasPortableStaging()
  let capacity = if staged: staging.len else: WasmMigrationMaxSnapshotBytes
  if epoch == 0 or (coreBit != 1'u32 and coreBit != 2'u32 and
      coreBit != 4'u32) or
      receiver.taskId != 0 or
      (staged and not staging.validPortableStaging()) or
      (not staged and staging.len != 0) or
      maxSnapshotBytes < 64 or
      maxSnapshotBytes > capacity or
      leaseTicks == 0 or
      not wasmRuntimeCapabilities().fullInterpreter:
    return false
  when not defined(wasmChunkedMemory):
    if memoryFactory != nil or memoryFactoryContext != nil: return false
  receiver = WasmMigrationReceiver(epoch: epoch, coreBit: coreBit,
    maxSnapshotBytes: maxSnapshotBytes.uint32, leaseTicks: leaseTicks,
    maxMemoryPages: maxMemoryPages, staging: staging)
  when defined(wasmChunkedMemory):
    receiver.memoryFactory = memoryFactory
    receiver.memoryFactoryContext = memoryFactoryContext
  true

proc clearTransfer(receiver: var WasmMigrationReceiver) =
  receiver.state = mwIdle
  receiver.sourceBootId = 0
  receiver.sourceCoreBit = 0
  receiver.transferId = 0
  receiver.slot = 0
  receiver.fuelLimit = 0
  receiver.fuelUsed = 0
  receiver.affinityMask = 0
  receiver.totalBytes = 0
  receiver.received = 0
  receiver.taskId = 0
  receiver.dropPending = false
  when defined(wasmManagedMigration):
    receiver.claim = WasmStealClaim()
    receiver.checkedSession = 0
    receiver.checking = false
    receiver.accepting = false
  when defined(wasmStreamMigration):
    receiver.streamed = false
  when defined(wasmStorageMigration):
    receiver.partCount = 0
  receiver.lastActivityTick = 0

proc reapWasmMigrationReceiver*(receiver: var WasmMigrationReceiver,
                                nowTick: uint64): bool =
  ## A stalled, uncommitted transfer holds only a bounded lease. An active
  ## migrated task is never killed or replayed because its source reset.
  if receiver.state in {mwIdle, mwActive, mwCommitting} or
      nowTick < receiver.lastActivityTick or
      nowTick - receiver.lastActivityTick < receiver.leaseTicks:
    return false
  when defined(wasmManagedMigration):
    if receiver.checking and receiver.state in {mwReceiving, mwPreparing, mwPrepared}:
      receiver.dropPending = true
      return true
  if receiver.taskId != 0:
    discard discardPreparedWasmTaskMigration(receiver.taskId)
  receiver.clearTransfer()
  true

proc finishWasmMigrationReceiver*(receiver: var WasmMigrationReceiver): bool =
  ## Release the single transfer slot after the activated task terminates.
  if receiver.state != mwActive or receiver.taskId == 0: return false
  when defined(wasmManagedMigration):
    if receiver.claim.token != 0 and receiver.worker[].jobId == receiver.claim.jobId:
      return false
  let task = getWasmTask(receiver.taskId)
  if task.state notin {wasmTaskExited, wasmTaskTrapped, wasmTaskKilled} and
      task.status != wasmSchedNoTask:
    return false
  when defined(wasmManagedMigration):
    if receiver.claim.token != 0:
      receiver.completed = (receiver.sourceBootId, receiver.sourceCoreBit,
        receiver.transferId, receiver.taskId, receiver.claim)
  receiver.clearTransfer()
  true

proc sameTransfer(receiver: WasmMigrationReceiver,
                  req: WasmMigrationWireRequest): bool =
  receiver.sourceBootId == req.sourceBootId and
    receiver.sourceCoreBit == req.sourceCoreBit and
    receiver.transferId == req.transferId and
    receiver.slot == req.slot and
    receiver.fuelLimit == req.fuelLimit and
    receiver.fuelUsed == req.fuelUsed and
    receiver.affinityMask == req.affinityMask and
    receiver.totalBytes == req.totalBytes and
    (when defined(wasmManagedMigration): receiver.claim == req.claim else: true)

proc storagePartPending(receiver: WasmMigrationReceiver): bool {.inline.} =
  when defined(wasmStorageMigration):
    receiver.partCount != 0 and not receiver.partReady
  else: false

proc needsWasmMigrationService*(receiver: WasmMigrationReceiver): bool {.inline.} =
  receiver.state in {mwPreparing, mwCommitting} or receiver.dropPending or
    receiver.storagePartPending() or
    (when defined(wasmManagedMigration):
      receiver.state == mwReceiving and receiver.claim.token != 0 and
        receiver.checkedSession == 0
    else: false)

when defined(wasmManagedMigration):
  proc bindWasmMigrationWorker*(receiver: var WasmMigrationReceiver,
                                 worker: ptr WasmStealClient): bool =
    if receiver.state != mwIdle or worker == nil or worker[].coreBit != receiver.coreBit:
      return false
    receiver.worker = worker
    true

  proc checkManagedDependencies(receiver: var WasmMigrationReceiver,
                                probeOnly: bool): WasmMigrationWireStatus =
    let worker = receiver.worker
    if not receiver.checking:
      if not worker[].beginWasmStealCheckHandoff(receiver.claim, receiver.sourceCoreBit.uint32,
          probeOnly = probeOnly):
        return mwsPrepareFailed
      receiver.checking = true
    case worker[].pollWasmSteal()
    of wscPending: mwsPending
    of wscHandoffChecked:
      let job = addr worker[].handoffJob
      if job.slot != receiver.slot or job.maxFuel != receiver.fuelLimit or
          job.affinityMask != receiver.affinityMask or
          (receiver.maxMemoryPages != 0 and job.maxMemoryPages > receiver.maxMemoryPages):
        discard worker[].cancelWasmStealCheckHandoff()
        receiver.checking = false
        return mwsPrepareFailed
      receiver.checkedSession = worker[].peerSession
      if probeOnly:
        discard worker[].cancelWasmStealCheckHandoff()
        receiver.checking = false
      mwsOk
    else:
      receiver.checking = false
      mwsPrepareFailed

  proc serviceManagedCommit(receiver: var WasmMigrationReceiver): WasmMigrationWireStatus =
    let worker = receiver.worker
    if not receiver.accepting:
      if not worker[].beginWasmStealAcceptHandoff(receiver.taskId):
        return mwsBadState
      receiver.accepting = true
    case worker[].pollWasmSteal()
    of wscPending: mwsPending
    of wscHandoffRetry:
      discard worker[].retryWasmStealHandoff()
      mwsPending
    of wscReady:
      if worker[].taskId != receiver.taskId or worker[].jobId != receiver.claim.jobId:
        return mwsBadState
      receiver.state = mwActive
      mwsOk
    of wscHandoffChecked:
      if worker[].handoffStatus != wssBusy: return mwsBadState
      receiver.accepting = false
      mwsPending
    else: mwsBadState

proc receiveStorage(receiver: var WasmMigrationReceiver): ptr UncheckedArray[byte] {.inline.} =
  if receiver.staging.data != nil: receiver.staging.data
  else: cast[ptr UncheckedArray[byte]](addr receiver.bytes[0])

when defined(wasmStorageMigration):
  proc queueStoragePart(receiver: var WasmMigrationReceiver, offset: uint32,
                        data: openArray[byte]): WasmMigrationWireStatus =
    if receiver.partCount == data.len.uint16 and receiver.partOffset == offset:
      for i, value in data:
        if receiver.bytes[i] != value: return mwsOutOfOrder
      return if receiver.partReady: receiver.partStatus else: mwsPending
    if receiver.storagePartPending() or receiver.state != mwReceiving:
      return mwsOutOfOrder
    copyMem(addr receiver.bytes[0], unsafeAddr data[0], data.len)
    receiver.partOffset = offset
    receiver.partCount = data.len.uint16
    receiver.partReady = false
    mwsPending

  proc serviceStoragePart(receiver: var WasmMigrationReceiver): WasmMigrationWireStatus =
    let count = receiver.partCount.int
    let offset = receiver.partOffset
    if offset == receiver.received:
      if not receiver.staging.writePortableRange(offset.int, addr receiver.bytes[0], count):
        return mwsBackingFailed
      receiver.received += receiver.partCount.uint32
    else:
      # Retried older fragments must match the file. Read from the scheduler,
      # never from the XRAM handler, and keep the pending payload intact.
      var buf: array[64, byte]
      var pos = 0
      while pos < count:
        let size = min(buf.len, count - pos)
        if not receiver.staging.readPortableRange(offset.int + pos, addr buf[0], size):
          return mwsBackingFailed
        for i in 0 ..< size:
          if receiver.bytes[pos + i] != buf[i]: return mwsOutOfOrder
        pos += size
    mwsOk

proc serviceWasmMigrationReceiver*(receiver: var WasmMigrationReceiver):
    WasmMigrationWireStatus =
  ## Run from the core's ordinary kernel loop, outside reserved hard slots.
  ## Validation, SHA-256 and instantiation are never performed in the IPC
  ## handler. The sender polls mwoQuery until this reaches a terminal state.
  if receiver.dropPending:
    when defined(wasmManagedMigration):
      if receiver.checking:
        if receiver.worker[].pollWasmSteal() == wscPending: return mwsPending
        discard receiver.worker[].cancelWasmStealCheckHandoff()
    if receiver.taskId != 0:
      discard discardPreparedWasmTaskMigration(receiver.taskId)
    receiver.clearTransfer()
    return mwsOk
  when defined(wasmStorageMigration):
    if receiver.storagePartPending():
      receiver.partStatus = receiver.serviceStoragePart()
      receiver.partReady = true
      if receiver.partStatus == mwsBackingFailed: receiver.state = mwPrepareFailed
      return receiver.partStatus
  when defined(wasmManagedMigration):
    if receiver.state == mwCommitting:
      result = receiver.serviceManagedCommit()
      if result == mwsBadState:
        discard discardPreparedWasmTaskMigration(receiver.taskId)
        discard receiver.worker[].cancelWasmStealCheckHandoff()
        receiver.taskId = 0
        receiver.state = mwPrepareFailed
      return
    if receiver.state == mwReceiving and receiver.claim.token != 0 and
        receiver.checkedSession == 0:
      result = receiver.checkManagedDependencies(probeOnly = true)
      if result == mwsPrepareFailed: receiver.state = mwPrepareFailed
      return
    if receiver.state == mwPreparing and receiver.claim.token != 0 and
        receiver.checkedSession == 0:
      result = receiver.checkManagedDependencies(probeOnly = false)
      if result == mwsPrepareFailed: receiver.state = mwPrepareFailed
      if result != mwsOk: return
  if receiver.state != mwPreparing: return mwsBadState
  var task: WasmSchedulerResult
  if receiver.taskId != 0:
    when defined(wasmChunkedMemory):
      task = pollFullWasmMigrationRestore(receiver.taskId)
    else:
      task = WasmSchedulerResult(status: wasmSchedInitFailed)
  else:
    var migration = WasmTaskMigration(status: wasmMigrationOk,
      slot: receiver.slot, fuelLimit: receiver.fuelLimit, fuelUsed: receiver.fuelUsed)
    if receiver.staging.hasPortableStaging():
      migration.staged = receiver.staging
      migration.staged.len = receiver.received.int
    else:
      migration.bytes = newSeq[byte](receiver.received.int)
      copyMem(addr migration.bytes[0], addr receiver.bytes[0], migration.bytes.len)
    try:
      if not migration.staged.sealPortableStaging():
        task = WasmSchedulerResult(status: wasmSchedBackingFailed)
      else:
        var pages = receiver.maxMemoryPages
        let managed = when defined(wasmManagedMigration): receiver.claim.token != 0 else: false
        var factory: FullMemoryFactory
        var factoryContext: pointer
        when defined(wasmChunkedMemory):
          factory = receiver.memoryFactory
          factoryContext = receiver.memoryFactoryContext
        when defined(wasmManagedMigration):
          if managed:
            pages = receiver.worker[].handoffJob.maxMemoryPages
            when defined(wasmChunkedMemory):
              let backing = receiver.worker[].registeredWasmStealMemory()
              if backing.factory != nil:
                factory = backing.factory
                factoryContext = backing.context
        when defined(wasmMigrationWireHostTest):
          if wasmMigrationPrepareHook == nil:
            task = WasmSchedulerResult(status: wasmSchedInitFailed)
          else:
            task = wasmMigrationPrepareHook(migration, pages, factory, factoryContext, managed)
        else:
          task = prepareFullWasmMigrationSlot(move migration, pages, factory,
            factoryContext, allowPagedRestore = defined(wasmChunkedMemory),
            enforceMemoryQuota = managed)
    except CatchableError:
      task = WasmSchedulerResult(status: wasmSchedInitFailed)
  if task.status == wasmSchedRestorePending and task.state == wasmTaskMigrating:
    receiver.taskId = task.id
    return mwsPending
  let wrongEntry = when defined(wasmManagedMigration):
    receiver.claim.token != 0 and task.status == wasmSchedOk and
      not preparedWasmMigrationEntryMatches(task.id, receiver.worker[].handoffJob.wasmStealExportName())
  else: false
  if wrongEntry or task.status != wasmSchedOk or task.state != wasmTaskMigrating:
    let discardedId = if receiver.taskId != 0: receiver.taskId else: task.id
    if discardedId != 0: discard discardPreparedWasmTaskMigration(discardedId)
    receiver.taskId = 0
    when defined(wasmManagedMigration):
      if receiver.checkedSession != 0: discard receiver.worker[].cancelWasmStealCheckHandoff()
    receiver.state = mwPrepareFailed
    return mwsPrepareFailed
  receiver.taskId = task.id
  receiver.state = mwPrepared
  return mwsOk

proc processWasmMigrationWire*(receiver: var WasmMigrationReceiver,
                               request: openArray[byte],
                               response: var openArray[byte],
                               nowTick = 0'u64, routedSourceBit = 0'u16): int =
  var req: WasmMigrationWireRequest
  if not request.decodeWasmMigrationRequest(req): return 0
  var reply = WasmMigrationWireReply(status: mwsOk,
    receiverEpoch: receiver.epoch, transferId: receiver.transferId,
    nextOffset: receiver.received, state: receiver.state,
    taskId: receiver.taskId)
  let wrongRoute = when defined(wasmManagedMigration):
    if req.relayViaM0:
      routedSourceBit != WasmStealM0.uint16 or
        receiver.coreBit != wasmMigrationRelayTarget(req.sourceCoreBit).uint32
    else:
      routedSourceBit != 0 and req.sourceCoreBit != routedSourceBit
  else:
    routedSourceBit != 0 and req.sourceCoreBit != routedSourceBit
  if wrongRoute:
    reply.status = mwsInvalid
    return reply.encodeWasmMigrationReply(response)
  when defined(wasmManagedMigration):
    let completed = addr receiver.completed
    if req.op in {mwoCommit, mwoQuery} and req.receiverEpoch == receiver.epoch and
        req.claim.token != 0 and req.claim == completed.claim and
        req.sourceBootId == completed.bootId and req.sourceCoreBit == completed.coreBit and
        req.transferId == completed.transferId:
      return WasmMigrationWireReply(status: mwsOk, state: mwActive,
        receiverEpoch: receiver.epoch, transferId: req.transferId,
        taskId: completed.taskId).encodeWasmMigrationReply(response)
  if req.op == mwoHello:
    if req.sourceBootId != 0 and receiver.state in
        {mwReceiving, mwPreparing, mwPrepared, mwPrepareFailed} and
        receiver.sourceCoreBit == req.sourceCoreBit and
        receiver.sourceBootId != req.sourceBootId:
      if receiver.taskId != 0 or
          (when defined(wasmManagedMigration): receiver.checking else: false):
        receiver.dropPending = true
        reply.status = mwsPending
      else:
        receiver.clearTransfer()
        reply.transferId = 0
        reply.nextOffset = 0
        reply.state = mwIdle
        reply.taskId = 0
    return reply.encodeWasmMigrationReply(response)
  if req.receiverEpoch == 0 or req.receiverEpoch != receiver.epoch:
    reply.status = mwsStaleEpoch
  elif req.sourceBootId == 0 or req.transferId == 0:
    reply.status = mwsInvalid
  elif req.op in {mwoBegin, mwoBeginStream}:
    let streamed = req.op == mwoBeginStream
    let minimum = when defined(wasmStreamMigration):
      if streamed: WasmPortableHeaderBytes + WasmPortableStreamFooterBytes else: WasmPortableHeaderBytes
    else: WasmPortableHeaderBytes
    if streamed and not defined(wasmStreamMigration):
      reply.status = mwsInvalid
    elif (when defined(wasmManagedMigration): req.claim.token != 0 and receiver.worker == nil else: false):
      reply.status = mwsInvalid
    elif req.totalBytes > receiver.maxSnapshotBytes:
      reply.status = mwsTooLarge
    elif req.totalBytes < minimum.uint32 or req.fuelLimit == 0 or
        req.fuelUsed >= req.fuelLimit or
        (req.affinityMask and receiver.coreBit) == 0 or
        (req.affinityMask and not 7'u32) != 0:
      reply.status = mwsInvalid
    elif receiver.state != mwIdle:
      if receiver.dropPending:
        reply.status = mwsBusy
      elif receiver.sameTransfer(req) and
          (when defined(wasmStreamMigration): receiver.streamed == streamed else: true):
        discard  # Idempotent begin after a lost reply.
      else:
        reply.status = mwsBusy
    else:
      receiver.sourceBootId = req.sourceBootId
      receiver.sourceCoreBit = req.sourceCoreBit
      receiver.transferId = req.transferId
      receiver.slot = req.slot
      receiver.fuelLimit = req.fuelLimit
      receiver.fuelUsed = req.fuelUsed
      receiver.affinityMask = req.affinityMask
      receiver.totalBytes = req.totalBytes
      receiver.received = 0
      when defined(wasmManagedMigration):
        receiver.claim = req.claim
      when defined(wasmStreamMigration):
        receiver.streamed = streamed
      receiver.lastActivityTick = nowTick
      receiver.state = mwReceiving
    when defined(wasmManagedMigration):
      if reply.status == mwsOk and receiver.claim.token != 0:
        if receiver.state == mwPrepareFailed: reply.status = mwsPrepareFailed
        elif receiver.state == mwReceiving and receiver.checkedSession == 0:
          reply.status = mwsPending
  elif receiver.state == mwIdle or not receiver.sameTransfer(req):
    reply.status = mwsStaleTransfer
  elif receiver.dropPending:
    reply.status = mwsPending
  else:
    case req.op
    of mwoPart:
      if receiver.state != mwReceiving or
          (when defined(wasmManagedMigration):
            receiver.claim.token != 0 and receiver.checkedSession == 0
          else: false):
        reply.status = mwsBadState
        when defined(wasmStorageMigration):
          if receiver.state == mwPrepareFailed and receiver.partReady and
              receiver.partStatus == mwsBackingFailed:
            reply.status = mwsBackingFailed
      elif req.offset > receiver.received or
          req.count.uint32 > (if req.offset == receiver.received:
            receiver.totalBytes - receiver.received else: receiver.received - req.offset):
        reply.status = mwsOutOfOrder
      else:
        template payload: untyped = request.toOpenArray(WasmMigrationWireHeaderBytes, request.high)
        if receiver.staging.usesPortableBacking():
          when defined(wasmStorageMigration):
            reply.status = receiver.queueStoragePart(req.offset, payload)
        else:
          let storage = receiver.receiveStorage()
          if req.offset == receiver.received:
            copyMem(addr storage[req.offset.int], unsafeAddr request[WasmMigrationWireHeaderBytes],
              req.count.int)
            receiver.received += req.count.uint32
          else:
            # A repeated fragment is accepted only when all bytes match.
            for i, value in payload:
              if storage[req.offset.int + i] != value:
                reply.status = mwsOutOfOrder
                break
    of mwoPrepare:
      let complete = when defined(wasmStreamMigration):
        if receiver.streamed:
          receiver.received >= (WasmPortableHeaderBytes + WasmPortableStreamFooterBytes).uint32
        else:
          receiver.received == receiver.totalBytes
      else:
        receiver.received == receiver.totalBytes
      if receiver.state == mwPrepared:
        discard  # Idempotent prepare.
      elif receiver.state == mwPreparing:
        reply.status = mwsPending
      elif receiver.state == mwPrepareFailed:
        reply.status = mwsPrepareFailed
      elif receiver.state != mwReceiving or not complete or receiver.storagePartPending() or
          (when defined(wasmManagedMigration):
            receiver.claim.token != 0 and receiver.checkedSession == 0
          else: false):
        reply.status = mwsBadState
      else:
        when defined(wasmManagedMigration):
          receiver.checkedSession = 0  # Recheck eligibility before preparing ownership.
        receiver.state = mwPreparing
        reply.status = mwsPending
    of mwoCommit:
      if receiver.state == mwActive:
        discard  # Idempotent commit after a lost reply.
      elif receiver.state == mwCommitting:
        reply.status = mwsPending
      elif (when defined(wasmManagedMigration):
          receiver.state == mwPrepared and receiver.claim.token != 0 and receiver.taskId != 0
          else: false):
        receiver.state = mwCommitting
        reply.status = mwsPending
      elif receiver.state != mwPrepared or receiver.taskId == 0 or
          activateWasmTaskMigration(receiver.taskId) != wasmMigrationOk:
        reply.status = mwsBadState
      else:
        receiver.state = mwActive
    of mwoAbort:
      if receiver.state in {mwActive, mwCommitting}:
        reply.status = mwsBadState
      elif receiver.taskId != 0 or
          (when defined(wasmManagedMigration): receiver.checking else: false):
        receiver.dropPending = true
        reply.status = mwsPending
      else:
        receiver.clearTransfer()
    of mwoQuery:
      if receiver.state in {mwPreparing, mwCommitting}: reply.status = mwsPending
      elif receiver.state == mwPrepareFailed: reply.status = mwsPrepareFailed
    of mwoHello, mwoBegin, mwoBeginStream:
      discard
  reply.transferId = receiver.transferId
  if reply.status in {mwsOk, mwsPending} and receiver.state notin
      {mwIdle, mwActive}:
    receiver.lastActivityTick = nowTick
  reply.nextOffset = receiver.received
  reply.state = receiver.state
  reply.taskId = receiver.taskId
  when defined(wasmManagedMigration):
    reply.checkedSession = receiver.checkedSession
    if req.op in {mwoBegin, mwoBeginStream} and reply.status == mwsPrepareFailed and
        receiver.received == 0 and receiver.checkedSession == 0:
      # A rejected preflight has no snapshot or worker reservation to keep.
      receiver.clearTransfer()
  reply.encodeWasmMigrationReply(response)
