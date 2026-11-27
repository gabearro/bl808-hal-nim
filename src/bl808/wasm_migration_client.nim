## Asynchronous source side of portable full-VM handoff. Poll it from the
## ordinary kernel loop. The source is frozen before the first RPC; it is
## retired before the activation commit is sent to the destination.

when not defined(bl808WasmFullScheduler):
  {.error: "WASM migration requires the full task scheduler".}

import ./[wasm_migration_wire, wasm_scheduler, wasm_runtime]
import cps/wasm/runtime
when defined(wasmManagedMigration):
  import ./[wasm_steal_broker, wasm_steal_client]
when defined(wasmMigrationClientHostTest):
  import cps/runtime
  type WasmMigrationRpc* = proc(request: openArray[byte], response: pointer,
    responseBytes: int, responseLen: ptr int,
    timeoutMs: uint64): CpsVoidFuture {.nimcall.}
  var wasmMigrationRpc*: WasmMigrationRpc
else:
  import ./ipc
  import ./kernel/[cps, ipcbridge]
  when defined(bl808lp):
    import ./kernel/lp_local_atomic

const
  WasmMigrationRpcRetries* {.intdefine.} = 3
  WasmMigrationTimeoutMsDefault* {.intdefine.} = 5000

type
  WasmMigrationClientState* = enum
    wmcIdle
    wmcPending
    wmcComplete
    wmcFailed
    wmcUncertain

  WasmMigrationClientTelemetry* = object
    started*: uint32
    fragments*: uint32
    retries*: uint32
    prepared*: uint32
    committed*: uint32
    failures*: uint32
    uncertain*: uint32
    bytes*: uint32
    when defined(wasmManagedMigration):
      relayPolls*: uint32

  WasmMigrationClient* = object
    state*: WasmMigrationClientState
    sourceTaskId*: uint32
    targetCoreBit*: uint32
    sourceCoreBit*: uint16
    sourceBootId*: uint32
    receiverEpoch*: uint32
    transferId*: uint32
    affinityMask*: uint32
    timeoutMs*: uint64
    startTick*: uint64
    maxTransferTicks*: uint64
    telemetry*: WasmMigrationClientTelemetry
    nextTransferId: uint32
    retired: bool
    when defined(wasmManagedMigration):
      worker: ptr WasmStealClient
      claim: WasmStealClaim
      awaitingAuthority: bool
    pendingOp: WasmMigrationWireOp
    retries: uint8
    offset: uint32
    partCount: uint16
    when defined(wasmStreamMigration):
      streamLimit: uint32
      streamDone: bool
    snapshot: WasmTaskMigration
    future: CpsVoidFuture
    responseLen: int
    requestBuf: array[WasmMigrationWirePayloadBytes, byte]
    responseBuf: array[WasmMigrationWireReplyBytes, byte]

proc validRoute(sourceBit, targetBit: uint32): bool =
  when defined(wasmManagedMigration):
    if sourceBit != 1 and targetBit != 1:
      return sourceBit in [2'u32, 4'u32] and
        wasmMigrationRelayTarget(sourceBit.uint16).uint32 == targetBit
  (sourceBit == 1 and (targetBit == 2 or targetBit == 4)) or
    ((sourceBit == 2 or sourceBit == 4) and targetBit == 1)

when defined(wasmManagedMigration):
  proc usesRelay(client: WasmMigrationClient): bool {.inline.} =
    client.sourceCoreBit != 1 and client.targetCoreBit != 1

proc initWasmMigrationClient*(client: var WasmMigrationClient,
                              sourceBootId, targetCoreBit,
                              affinityMask: uint32,
                              timeoutMs = WasmMigrationTimeoutMsDefault.uint64,
                              maxTransferTicks = 30_000_000'u64,
                              sourceCoreBit = 0'u32): bool =
  if client.state in {wmcPending, wmcUncertain} or
      (client.future != nil and not client.future.finished): return false
  let caps = wasmRuntimeCapabilities()
  let actualCoreBit = if caps.core == wasmCoreM0: 1'u32
                      elif caps.core == wasmCoreD0: 2'u32
                      elif caps.core == wasmCoreLP: 4'u32
                      else: 0'u32
  let coreBit = when defined(wasmMigrationClientHostTest):
    if sourceCoreBit != 0: sourceCoreBit else: actualCoreBit
  else:
    actualCoreBit
  if sourceBootId == 0 or timeoutMs == 0 or maxTransferTicks == 0 or
      not caps.fullInterpreter or not validRoute(coreBit, targetCoreBit) or
      (affinityMask and targetCoreBit) == 0 or
      (affinityMask and not 7'u32) != 0:
    return false
  when not defined(wasmMigrationClientHostTest):
    if sourceCoreBit != 0 and sourceCoreBit != coreBit: return false
  client = WasmMigrationClient(state: wmcIdle,
    sourceBootId: sourceBootId, sourceCoreBit: coreBit.uint16,
    targetCoreBit: targetCoreBit, affinityMask: affinityMask,
    timeoutMs: timeoutMs, maxTransferTicks: maxTransferTicks)
  true

when defined(wasmStorageMigration):
  proc encodeBackedPart(req: WasmMigrationWireRequest, view: WasmPortableStaging,
                        outBuf: var openArray[byte]): int =
    var buf: array[WasmMigrationWirePartBytes, byte]
    if not view.readPortableRange(req.offset.int, addr buf[0], req.count.int): return 0
    req.encodeWasmMigrationRequest(buf.toOpenArray(0, req.count.int - 1), outBuf)

proc streaming(client: WasmMigrationClient): bool {.inline.} =
  when defined(wasmStreamMigration): client.streamLimit != 0
  else: false

proc transferCapacity(client: WasmMigrationClient): uint32 {.inline.} =
  when defined(wasmStreamMigration):
    if client.streaming(): return client.streamLimit
  client.snapshot.migrationView().len.uint32

proc exchangeEncoded(client: var WasmMigrationClient): bool =
  let size = WasmMigrationWireHeaderBytes + client.partCount.int
  client.responseLen = 0
  when defined(wasmMigrationClientHostTest):
    if wasmMigrationRpc == nil: return false
    client.future = wasmMigrationRpc(
      client.requestBuf.toOpenArray(0, size - 1),
      addr client.responseBuf[0], client.responseBuf.len,
      addr client.responseLen, client.timeoutMs)
  else:
    let target = if client.targetCoreBit == 1 or
        (when defined(wasmManagedMigration): client.usesRelay() else: false):
      ipcM0
    elif client.targetCoreBit == 2:
      ipcD0
    else:
      ipcLP
    client.future = ipcCallTo(target, WasmMigrationWireTag,
      client.requestBuf.toOpenArray(0, size - 1),
      addr client.responseBuf[0], client.responseBuf.len,
      addr client.responseLen, timeoutMs = client.timeoutMs)
  client.future != nil

proc send(client: var WasmMigrationClient,
          op: WasmMigrationWireOp): bool =
  let view = client.snapshot.migrationView()
  let count = if op == mwoPart:
    if client.streaming():
      client.partCount
    else:
      if not view.hasPortableStaging() or client.offset >= view.len.uint32: return false
      min(WasmMigrationWirePartBytes, view.len - client.offset.int).uint16
  else:
    0'u16
  var req = WasmMigrationWireRequest(op: op,
    receiverEpoch: client.receiverEpoch,
    sourceBootId: client.sourceBootId,
    sourceCoreBit: client.sourceCoreBit,
    transferId: client.transferId,
    slot: client.snapshot.slot,
    fuelLimit: client.snapshot.fuelLimit,
    fuelUsed: client.snapshot.fuelUsed,
    affinityMask: client.affinityMask,
    totalBytes: client.transferCapacity(),
    offset: if op == mwoPart: client.offset else: 0'u32,
    count: count)
  when defined(wasmManagedMigration):
    req.claim = client.claim
    req.relayViaM0 = client.usesRelay()
  let size = if op == mwoPart:
    if count == 0: return false
    if client.streaming():
      req.encodeWasmMigrationRequestHeader(client.requestBuf)
    elif view.usesPortableBacking():
      when defined(wasmStorageMigration): req.encodeBackedPart(view, client.requestBuf)
      else: 0
    else:
      req.encodeWasmMigrationRequest(
        view.data.toOpenArray(client.offset.int,
          client.offset.int + count.int - 1), client.requestBuf)
  else:
    req.encodeWasmMigrationRequest([], client.requestBuf)
  if size == 0: return false
  client.pendingOp = op
  client.partCount = count
  client.exchangeEncoded()

proc failBeforeRetire(client: var WasmMigrationClient) =
  if client.sourceTaskId != 0 and not client.retired:
    discard cancelWasmTaskMigration(client.sourceTaskId)
  if client.future != nil and client.future.finished: client.future = nil
  client.snapshot = WasmTaskMigration()
  client.state = wmcFailed
  inc client.telemetry.failures

proc uncertain(client: var WasmMigrationClient) =
  ## A lost authorization or commit must leave the source non-runnable.
  if client.future != nil and client.future.finished: client.future = nil
  client.state = wmcUncertain
  inc client.telemetry.uncertain

proc canBegin(client: WasmMigrationClient, sourceTaskId: uint32): bool =
  client.state in {wmcIdle, wmcComplete, wmcFailed} and
    client.sourceBootId != 0 and sourceTaskId != 0 and
    (client.future == nil or client.future.finished)

proc startTransfer(client: var WasmMigrationClient, sourceTaskId: uint32,
                   nowTick: uint64, captured: sink WasmTaskMigration) =
  client.future = nil
  client.snapshot = move captured
  client.sourceTaskId = sourceTaskId
  inc client.nextTransferId
  if client.nextTransferId == 0: inc client.nextTransferId
  client.transferId = client.nextTransferId
  client.receiverEpoch = 0
  client.offset = 0
  client.retired = false
  when defined(wasmManagedMigration):
    client.awaitingAuthority = false
  client.retries = 0
  client.startTick = nowTick
  client.state = wmcPending
  inc client.telemetry.started

when defined(wasmManagedMigration):
  proc bindWasmMigrationSourceWorker*(client: var WasmMigrationClient,
                                       worker: ptr WasmStealClient): bool =
    if client.state notin {wmcIdle, wmcComplete, wmcFailed} or worker == nil or
        worker[].coreBit != client.sourceCoreBit.uint32 or
        worker[].bootId != client.sourceBootId:
      return false
    client.worker = worker
    true

  proc selectBrokerClaim(client: var WasmMigrationClient, sourceTaskId: uint32): bool =
    client.claim = WasmStealClaim()
    if client.worker == nil: return true
    if sourceTaskId != client.worker[].taskId: return false
    client.claim = client.worker[].currentWasmStealClaim()
    client.claim.token != 0

proc beginWasmTaskMigration*(client: var WasmMigrationClient,
                             sourceTaskId: uint32,
                             nowTick: uint64, staging = WasmPortableStaging()): bool =
  ## Without a workspace, use the route's inline limit. A caller providing a
  ## workspace owns its lifetime through the transfer, including retries.
  if not client.canBegin(sourceTaskId): return false
  let maxBytes = if staging.hasPortableStaging(): staging.len elif client.targetCoreBit == 4 or
      client.sourceCoreBit == 4: 512 else: 4096
  when defined(wasmManagedMigration):
    if not client.selectBrokerClaim(sourceTaskId): return false
    var captured = if client.claim.token != 0:
      beginBrokerWasmTaskMigrationCapture(sourceTaskId, maxBytes, staging)
    else:
      beginWasmTaskMigrationCapture(sourceTaskId, maxBytes, staging)
  else:
    var captured = beginWasmTaskMigrationCapture(sourceTaskId, maxBytes, staging)
  if captured.status notin {wasmMigrationOk, wasmMigrationPending}: return false
  let pending = captured.status == wasmMigrationPending
  when defined(wasmStreamMigration):
    client.streamLimit = 0
    client.streamDone = false
  client.startTransfer(sourceTaskId, nowTick, move captured)
  if pending: return true
  if not client.send(mwoHello):
    client.failBeforeRetire()
    return false
  true

when defined(wasmStreamMigration):
  proc beginWasmTaskStreamingMigration*(client: var WasmMigrationClient,
      sourceTaskId: uint32, nowTick: uint64, maxSnapshotBytes: int): bool =
    ## The receiver reserves this upper bound. The producer subsequently
    ## streams into the existing request buffer, retaining a chunk until ACK.
    if not client.canBegin(sourceTaskId): return false
    when defined(wasmManagedMigration):
      if not client.selectBrokerClaim(sourceTaskId): return false
      var captured = beginWasmTaskMigrationStream(sourceTaskId, maxSnapshotBytes,
        brokerManaged = client.claim.token != 0)
    else:
      var captured = beginWasmTaskMigrationStream(sourceTaskId, maxSnapshotBytes)
    if captured.status != wasmMigrationOk: return false
    client.streamLimit = maxSnapshotBytes.uint32
    client.streamDone = false
    client.startTransfer(sourceTaskId, nowTick, move captured)
    if client.send(mwoHello): return true
    client.failBeforeRetire()
    false

  proc nextStreamPart(client: var WasmMigrationClient): bool =
    if client.streamDone: return client.send(mwoPrepare)
    var count: int
    let status = readWasmTaskMigrationStream(client.sourceTaskId,
      client.requestBuf.toOpenArray(WasmMigrationWireHeaderBytes, WasmMigrationWirePayloadBytes - 1),
      count)
    if status notin {wasmMigrationOk, wasmMigrationPending}: return false
    client.streamDone = status == wasmMigrationOk
    if count == 0:
      if client.streamDone: return client.send(mwoPrepare)
      return true
    client.partCount = count.uint16
    client.send(mwoPart)

proc nextPartOrPrepare(client: var WasmMigrationClient): bool =
  when defined(wasmStreamMigration):
    if client.streaming(): return client.nextStreamPart()
  if client.offset.int < client.snapshot.migrationView().len:
    client.send(mwoPart)
  else:
    client.send(mwoPrepare)

proc prepared(client: var WasmMigrationClient, checkedSession: uint32): bool =
  when defined(wasmManagedMigration):
    if client.claim.token != 0:
      if not client.worker[].beginWasmStealAuthorizeHandoff(client.targetCoreBit, checkedSession):
        client.failBeforeRetire()
        return false
      client.awaitingAuthority = true
      inc client.telemetry.prepared
      return true
  if retireWasmTaskMigration(client.sourceTaskId) != wasmMigrationOk:
    client.failBeforeRetire()
    return false
  client.retired = true
  inc client.telemetry.prepared
  if not client.send(mwoCommit):
    client.uncertain()
    return false
  true

proc pollWasmTaskMigration*(client: var WasmMigrationClient,
                            nowTick: uint64): WasmMigrationClientState =
  if client.state != wmcPending:
    return client.state
  if nowTick >= client.startTick and
      nowTick - client.startTick >= client.maxTransferTicks:
    if client.retired or (when defined(wasmManagedMigration): client.awaitingAuthority else: false):
      client.uncertain()
    else: client.failBeforeRetire()
    return client.state
  when defined(wasmManagedMigration):
    if client.awaitingAuthority:
      case client.worker[].pollWasmSteal()
      of wscPending: discard
      of wscHandoffRetry: discard client.worker[].retryWasmStealHandoff()
      of wscIdle:
        client.retired = true
        client.awaitingAuthority = false
        if not client.send(mwoCommit): client.uncertain()
      of wscReady:
        if client.worker[].handoffStatus == wssBusy:
          client.awaitingAuthority = false
          client.failBeforeRetire()
        else: client.uncertain()
      else: client.uncertain()
      return client.state
  if client.future == nil:
    when defined(wasmStreamMigration):
      if client.streaming():
        if client.nextStreamPart(): return wmcPending
        client.failBeforeRetire()
        return client.state
    when defined(wasmChunkedMemory):
      var capture = pollWasmTaskMigrationCapture(client.sourceTaskId)
      if capture.status == wasmMigrationPending: return wmcPending
      if capture.status == wasmMigrationOk:
        client.snapshot = move capture
        if client.send(mwoHello): return wmcPending
    client.failBeforeRetire()
    return client.state
  if not client.future.finished: return wmcPending
  if client.future.getError() != nil:
    client.future = nil
    if client.retries < WasmMigrationRpcRetries.uint8:
      inc client.retries
      inc client.telemetry.retries
      if client.exchangeEncoded(): return wmcPending
    if client.retired: client.uncertain()
    else: client.failBeforeRetire()
    return client.state
  var reply: WasmMigrationWireReply
  if client.responseLen != WasmMigrationWireReplyBytes or
      not client.responseBuf.decodeWasmMigrationReply(reply):
    if client.retired: client.uncertain()
    else: client.failBeforeRetire()
    return client.state
  let op = client.pendingOp
  let checkedSession = when defined(wasmManagedMigration): reply.checkedSession else: 0'u32
  client.future = nil
  client.retries = 0
  when defined(wasmManagedMigration):
    if reply.status == mwsRelayPending:
      if client.usesRelay() and reply.receiverEpoch == client.receiverEpoch and
          reply.transferId == client.transferId and reply.state == mwIdle and
          reply.nextOffset == 0 and reply.taskId == 0 and reply.checkedSession == 0:
        inc client.telemetry.relayPolls
        if client.exchangeEncoded(): return wmcPending
      if client.retired: client.uncertain()
      else: client.failBeforeRetire()
      return client.state
  if op != mwoHello and (reply.receiverEpoch != client.receiverEpoch or
      reply.transferId != client.transferId) and
      reply.status notin {mwsStaleEpoch, mwsStaleTransfer}:
    if client.retired: client.uncertain()
    else: client.failBeforeRetire()
    return client.state
  if reply.status in {mwsStaleEpoch, mwsStaleTransfer, mwsBusy,
      mwsInvalid, mwsOutOfOrder, mwsTooLarge, mwsPrepareFailed, mwsBadState, mwsBackingFailed}:
    if client.retired: client.uncertain()
    else: client.failBeforeRetire()
    return client.state
  when defined(wasmManagedMigration):
    if op in {mwoBegin, mwoBeginStream} and client.claim.token != 0 and
        reply.status == mwsPending and reply.state == mwReceiving and
        reply.nextOffset == 0 and checkedSession == 0:
      if not client.send(op): client.failBeforeRetire()
      return client.state
  var sent = false
  case op
  of mwoHello:
    if reply.status == mwsPending:
      sent = client.send(mwoHello)
      if not sent: client.failBeforeRetire()
      return client.state
    if reply.status != mwsOk or reply.receiverEpoch == 0:
      client.failBeforeRetire()
      return client.state
    client.receiverEpoch = reply.receiverEpoch
    sent = client.send(if client.streaming(): mwoBeginStream else: mwoBegin)
  of mwoBeginStream:
    if not client.streaming() or reply.status != mwsOk or
        reply.state != mwReceiving or reply.nextOffset != 0 or
        (when defined(wasmManagedMigration): client.claim.token != 0 and checkedSession == 0
         else: false):
      client.failBeforeRetire()
      return client.state
    sent = client.nextPartOrPrepare()
  of mwoBegin:
    if reply.status != mwsOk or reply.state notin
        {mwReceiving, mwPreparing, mwPrepared} or
        (when defined(wasmManagedMigration):
           client.claim.token != 0 and reply.state == mwReceiving and checkedSession == 0
         else: false) or
        reply.nextOffset > client.snapshot.migrationView().len.uint32:
      client.failBeforeRetire()
      return client.state
    client.offset = reply.nextOffset
    sent = if reply.state == mwPrepared: client.prepared(checkedSession)
           elif reply.state == mwPreparing: client.send(mwoQuery)
           else: client.nextPartOrPrepare()
  of mwoPart:
    let partEnd = client.offset + client.partCount.uint32
    if reply.status == mwsPending and reply.state == mwReceiving and
        reply.nextOffset in client.offset..partEnd:
      sent = client.send(mwoPart)
    elif reply.status != mwsOk or reply.state != mwReceiving or
        reply.nextOffset < partEnd or reply.nextOffset > client.transferCapacity() or
        (client.streaming() and reply.nextOffset != partEnd):
      client.failBeforeRetire()
      return client.state
    else:
      client.offset = reply.nextOffset
      inc client.telemetry.fragments
      client.telemetry.bytes += client.partCount.uint32
      sent = client.nextPartOrPrepare()
  of mwoPrepare, mwoQuery:
    if reply.status == mwsPending and reply.state in {mwPreparing, mwCommitting}:
      sent = client.send(mwoQuery)
    elif reply.status == mwsOk and reply.state == mwPrepared:
      sent = if client.retired: client.send(mwoCommit)
             else: client.prepared(checkedSession)
    elif client.retired and reply.status == mwsOk and reply.state == mwActive:
      client.state = wmcComplete
      client.snapshot = WasmTaskMigration()
      inc client.telemetry.committed
      return client.state
    else:
      if client.retired: client.uncertain()
      else: client.failBeforeRetire()
      return client.state
  of mwoCommit:
    if reply.status == mwsPending and reply.state == mwCommitting:
      if not client.send(mwoQuery): client.uncertain()
      return client.state
    if reply.status == mwsOk and reply.state == mwActive:
      client.state = wmcComplete
      client.snapshot = WasmTaskMigration()
      inc client.telemetry.committed
      return client.state
    if client.retired: client.uncertain()
    else: client.failBeforeRetire()
    return client.state
  of mwoAbort:
    if client.retired: client.uncertain()
    else: client.failBeforeRetire()
    return client.state
  if not sent and client.state == wmcPending:
    if client.retired: client.uncertain()
    else: client.failBeforeRetire()
  client.state

proc retryWasmMigrationCommit*(client: var WasmMigrationClient,
                               nowTick: uint64): bool =
  ## Resolve an uncertain authorization or query the same destination
  ## epoch and transfer after an uncertain commit.
  if client.state != wmcUncertain or
      not (client.retired or (when defined(wasmManagedMigration): client.awaitingAuthority else: false)) or
      client.receiverEpoch == 0 or
      (client.future != nil and not client.future.finished):
    return false
  client.future = nil
  client.state = wmcPending
  client.retries = 0
  client.startTick = nowTick
  when defined(wasmManagedMigration):
    if client.awaitingAuthority: return true
  if not client.send(mwoQuery):
    client.uncertain()
    return false
  true
