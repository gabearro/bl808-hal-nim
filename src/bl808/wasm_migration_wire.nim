## Portable full-task handoff over the existing 504-byte XRAM IPC payloads.
## The destination stages at most one checksummed guest snapshot. It never
## runs the task before an explicit commit, and it never copies native frames.

when not defined(bl808WasmFullScheduler):
  {.error: "WASM migration requires the full task scheduler".}

import ./[wasm_full_manager, wasm_runtime, wasm_scheduler]
import cps/wasm/runtime

const
  WasmMigrationWireTag* = 0x5747'u16
  WasmMigrationWireMagic* = 0x474D'u16
  WasmMigrationWireVersion* = 2'u8
  WasmMigrationWirePayloadBytes* = 504
  WasmMigrationWireHeaderBytes* = 44
  WasmMigrationWirePartBytes* =
    WasmMigrationWirePayloadBytes - WasmMigrationWireHeaderBytes
  WasmMigrationWireReplyBytes* = 24
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

  WasmMigrationWireState* = enum
    mwIdle
    mwReceiving
    mwPreparing
    mwPrepared
    mwActive
    mwPrepareFailed

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

  WasmMigrationWireReply* = object
    status*: WasmMigrationWireStatus
    state*: WasmMigrationWireState
    receiverEpoch*: uint32
    transferId*: uint32
    nextOffset*: uint32
    taskId*: uint32

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
    proc(migration: WasmTaskMigration): WasmSchedulerResult {.nimcall.}

proc put16(buf: var openArray[byte], at: int, value: uint16) {.inline.} =
  buf[at] = value.byte
  buf[at + 1] = (value shr 8).byte

proc put32(buf: var openArray[byte], at: int, value: uint32) {.inline.} =
  for i in 0 ..< 4: buf[at + i] = (value shr (8 * i)).byte

proc get16(buf: openArray[byte], at: int): uint16 {.inline.} =
  buf[at].uint16 or (buf[at + 1].uint16 shl 8)

proc get32(buf: openArray[byte], at: int): uint32 {.inline.} =
  for i in 0 ..< 4: result = result or (buf[at + i].uint32 shl (8 * i))

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
  WasmMigrationWireReplyBytes

proc decodeWasmMigrationReply*(buf: openArray[byte],
                               reply: var WasmMigrationWireReply): bool =
  if buf.len != WasmMigrationWireReplyBytes or
      buf.get16(0) != WasmMigrationWireMagic or
      buf[2] != WasmMigrationWireVersion or
      buf[3] > mwsBackingFailed.ord.byte or
      buf[16] > mwPrepareFailed.ord.byte or
      buf[17] != 0 or buf[18] != 0 or buf[19] != 0:
    return false
  reply = WasmMigrationWireReply(status: WasmMigrationWireStatus(buf[3]),
    receiverEpoch: buf.get32(4), transferId: buf.get32(8),
    nextOffset: buf.get32(12), state: WasmMigrationWireState(buf[16]),
    taskId: buf.get32(20))
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
  when defined(wasmStreamMigration):
    receiver.streamed = false
  when defined(wasmStorageMigration):
    receiver.partCount = 0
  receiver.lastActivityTick = 0

proc reapWasmMigrationReceiver*(receiver: var WasmMigrationReceiver,
                                nowTick: uint64): bool =
  ## A stalled, uncommitted transfer holds only a bounded lease. An active
  ## migrated task is never killed or replayed because its source reset.
  if receiver.state in {mwIdle, mwActive} or
      nowTick < receiver.lastActivityTick or
      nowTick - receiver.lastActivityTick < receiver.leaseTicks:
    return false
  if receiver.taskId != 0:
    discard discardPreparedWasmTaskMigration(receiver.taskId)
  receiver.clearTransfer()
  true

proc finishWasmMigrationReceiver*(receiver: var WasmMigrationReceiver): bool =
  ## Release the single transfer slot after the activated task terminates.
  if receiver.state != mwActive or receiver.taskId == 0: return false
  let task = getWasmTask(receiver.taskId)
  if task.state notin {wasmTaskExited, wasmTaskTrapped, wasmTaskKilled} and
      task.status != wasmSchedNoTask:
    return false
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
    receiver.totalBytes == req.totalBytes

proc storagePartPending(receiver: WasmMigrationReceiver): bool {.inline.} =
  when defined(wasmStorageMigration):
    receiver.partCount != 0 and not receiver.partReady
  else: false

proc needsWasmMigrationService*(receiver: WasmMigrationReceiver): bool {.inline.} =
  receiver.state == mwPreparing or receiver.dropPending or receiver.storagePartPending()

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
        when defined(wasmMigrationWireHostTest):
          if wasmMigrationPrepareHook == nil:
            task = WasmSchedulerResult(status: wasmSchedInitFailed)
          else:
            task = wasmMigrationPrepareHook(migration)
        elif defined(wasmChunkedMemory):
          task = prepareFullWasmMigrationSlot(move migration, receiver.maxMemoryPages,
            receiver.memoryFactory, receiver.memoryFactoryContext, allowPagedRestore = true)
        else:
          task = prepareFullWasmMigrationSlot(move migration, receiver.maxMemoryPages)
    except CatchableError:
      task = WasmSchedulerResult(status: wasmSchedInitFailed)
  if task.status == wasmSchedRestorePending and task.state == wasmTaskMigrating:
    receiver.taskId = task.id
    return mwsPending
  if task.status != wasmSchedOk or task.state != wasmTaskMigrating:
    if receiver.taskId != 0: discard discardPreparedWasmTaskMigration(receiver.taskId)
    receiver.taskId = 0
    receiver.state = mwPrepareFailed
    return mwsPrepareFailed
  receiver.taskId = task.id
  receiver.state = mwPrepared
  mwsOk

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
  if routedSourceBit != 0 and req.sourceCoreBit != routedSourceBit:
    reply.status = mwsInvalid
    return reply.encodeWasmMigrationReply(response)
  if req.op == mwoHello:
    if req.sourceBootId != 0 and receiver.state in
        {mwReceiving, mwPreparing, mwPrepared, mwPrepareFailed} and
        receiver.sourceCoreBit == req.sourceCoreBit and
        receiver.sourceBootId != req.sourceBootId:
      if receiver.taskId != 0:
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
      when defined(wasmStreamMigration):
        receiver.streamed = streamed
      receiver.lastActivityTick = nowTick
      receiver.state = mwReceiving
  elif receiver.state == mwIdle or not receiver.sameTransfer(req):
    reply.status = mwsStaleTransfer
  elif receiver.dropPending:
    reply.status = mwsPending
  else:
    case req.op
    of mwoPart:
      if receiver.state != mwReceiving:
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
      elif receiver.state != mwReceiving or not complete or receiver.storagePartPending():
        reply.status = mwsBadState
      else:
        receiver.state = mwPreparing
        reply.status = mwsPending
    of mwoCommit:
      if receiver.state == mwActive:
        discard  # Idempotent commit after a lost reply.
      elif receiver.state != mwPrepared or receiver.taskId == 0 or
          activateWasmTaskMigration(receiver.taskId) != wasmMigrationOk:
        reply.status = mwsBadState
      else:
        receiver.state = mwActive
    of mwoAbort:
      if receiver.state == mwActive:
        reply.status = mwsBadState
      elif receiver.taskId != 0:
        receiver.dropPending = true
        reply.status = mwsPending
      else:
        receiver.clearTransfer()
    of mwoQuery:
      if receiver.state == mwPreparing: reply.status = mwsPending
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
  reply.encodeWasmMigrationReply(response)
