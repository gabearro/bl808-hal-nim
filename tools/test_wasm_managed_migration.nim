import bl808/[wasm_full_manager, wasm_migration_client, wasm_migration_corpus,
  wasm_migration_relay, wasm_migration_wire, wasm_runtime, wasm_scheduler, wasm_steal_broker,
  wasm_steal_client, wasm_store]
import cps/runtime
when defined(wasmChunkedMemory):
  import std/os
  import cps/wasm/[linear_memory, types]

var broker: WasmStealBroker
var receiver: WasmMigrationReceiver
var relay: WasmMigrationRelay
var sender: WasmMigrationClient
var workers: array[3, WasmStealClient]
var route: uint32
var now = 1'u64
var loseAuthorize, loseAccept: bool
var loseForwardedPart, loseRelayedCommit: bool
var forwardedParts: int
var probeDuringAuthorize: bool
var rebootBeforeAuthorize: bool
var expireOnLostAuthorization: bool
var sourceTask: uint32
var image = newSeq[byte](WasmProgramHeaderLen.int + WasmMigrationModule.len)
var base = cast[ptr UncheckedArray[byte]](addr image[0])
doAssert initWasmProgramImage(base, image.len.uint32, WasmMigrationModule) == wasmProgramOk

proc brokerRpc(req: openArray[byte], dest: pointer, capacity: int,
                length: ptr int, timeout: uint64): CpsVoidFuture =
  let target = cast[ptr UncheckedArray[byte]](dest)
  let op = req[3]
  inc now
  if op == wsoAuthorizeHandoff.ord.byte and rebootBeforeAuthorize:
    rebootBeforeAuthorize = false
    var authorization: WasmStealRequest
    doAssert req.decodeWasmStealRequest(authorization) and
      authorization.handoffCoreBit == WasmStealLP
    let hello = broker.processWasmSteal(WasmStealRequest(op: wsoHello,
      peerCoreBit: WasmStealLP, peerBootId: workers[2].bootId + 1), now)
    doAssert hello.status == wssOk and hello.peerSession != authorization.handoffSession
  if op == wsoAuthorizeHandoff.ord.byte and probeDuringAuthorize:
    probeDuringAuthorize = false
    var authorization: WasmStealRequest
    doAssert req.decodeWasmStealRequest(authorization)
    let third = addr workers[2]
    doAssert third[].coreBit != route and third[].coreBit != authorization.handoffCoreBit
    let probe = broker.processWasmSteal(WasmStealRequest(op: wsoProbeHandoff,
      ownerEpoch: third[].ownerEpoch, peerBootId: third[].bootId,
      peerSession: third[].peerSession, peerCoreBit: third[].coreBit,
      jobId: authorization.jobId, claimToken: authorization.claimToken,
      backendMask: WasmBackendInterpreter, fullInterpreter: true,
      handoffCoreBit: route), now)
    doAssert probe.status == wssOk
  length[] = broker.processWasmStealWire(req, target.toOpenArray(0, capacity - 1), now, route)
  result = newCpsVoidFuture()
  if op == wsoAuthorizeHandoff.ord.byte:
    doAssert getWasmTask(sourceTask).state == wasmTaskMigrating
    doAssert resumeWasmTask(sourceTask).status == wasmSchedBadState
    if loseAuthorize:
      loseAuthorize = false
      if expireOnLostAuthorization:
        expireOnLostAuthorization = false
        now += sender.maxTransferTicks
      result.fail(newException(IOError, "lost authorization reply"))
      return
  if op == wsoAcceptHandoff.ord.byte and loseAccept:
    loseAccept = false
    result.fail(newException(IOError, "lost activation grant"))
    return
  result.complete()

proc snapshotRpc(req: openArray[byte], dest: pointer, capacity: int,
                  length: ptr int, timeout: uint64): CpsVoidFuture =
  let target = cast[ptr UncheckedArray[byte]](dest)
  inc now
  result = newCpsVoidFuture()
  if req.wasmMigrationRelayIngress():
    length[] = relay.processWasmMigrationRelay(req,
      target.toOpenArray(0, capacity - 1), route.uint16)
    var reply: WasmMigrationWireReply
    if loseRelayedCommit and req[3] == mwoCommit.ord.byte and
        target.toOpenArray(0, length[] - 1).decodeWasmMigrationReply(reply) and
        reply.status != mwsRelayPending:
      loseRelayedCommit = false
      result.fail(newException(IOError, "lost relay reply"))
      return
  else:
    length[] = receiver.processWasmMigrationWire(req,
      target.toOpenArray(0, capacity - 1), now, route.uint16)
  result.complete()

proc forwardRelayPacket(source, destination: uint32) =
  let packet = relay.wasmMigrationRelayPacket(source.uint16)
  if packet == nil: return
  let size = packet[].takeWasmMigrationRelayPacket()
  if size == 0: return
  if packet.request[3] == mwoPart.ord.byte: inc forwardedParts
  doAssert wasmMigrationRelayTarget(source.uint16).uint32 == destination
  inc now
  let replySize = receiver.processWasmMigrationWire(packet.request.toOpenArray(0, size - 1),
    packet.response, now, WasmStealM0.uint16)
  if loseForwardedPart and packet.request[3] == mwoPart.ord.byte:
    loseForwardedPart = false
    packet[].finishWasmMigrationRelayPacket(0)
  else:
    packet[].finishWasmMigrationRelayPacket(replySize)

proc prepareJob(job: WasmStealJob, admission: FullWasmAdmission,
                memoryFactory: FullMemoryFactory,
                memoryFactoryContext: pointer): WasmSchedulerResult =
  startFullWasmImageTaskI32(base, image.len.uint32, "run", [],
    maxTotalFuel = job.maxFuel, slotLabel = job.slot.int32,
    maxMemoryPages = job.maxMemoryPages,
    memoryFactory = memoryFactory, memoryFactoryContext = memoryFactoryContext,
    admission = admission, requireNoStart = true,
    allowPortableMigration = false, retainTrappedTask = true)

proc prepareSnapshot(migration: WasmTaskMigration, maxMemoryPages: uint32,
                     memoryFactory: FullMemoryFactory, memoryFactoryContext: pointer,
                     enforceMemoryQuota: bool): WasmSchedulerResult {.nimcall.} =
  prepareFullWasmMigrationImage(base, image.len.uint32, migration,
    maxMemoryPages, memoryFactory, memoryFactoryContext,
    allowPagedRestore = defined(wasmChunkedMemory), enforceMemoryQuota = enforceMemoryQuota)

proc pollWorker(worker: var WasmStealClient) =
  route = worker.coreBit
  for _ in 0 ..< 8:
    if worker.state != wscPending: return
    discard worker.pollWasmSteal()
  doAssert worker.state != wscPending

proc connect(worker: var WasmStealClient) =
  route = worker.coreBit
  doAssert worker.beginWasmStealSession()
  worker.pollWorker()
  doAssert worker.state == wscIdle

proc startJob(source, worker: var WasmStealClient, ticket: uint32,
               requiredResources = 0'u16, exportName = "run", maxMemoryPages = 0'u32): uint32 =
  var job = WasmStealJob(slot: 2, affinityMask: WasmStealAllCores,
    requiredBackends: WasmBackendInterpreter, maxFuel: 64,
    requiredResources: requiredResources, maxMemoryPages: maxMemoryPages)
  for i, c in exportName: job.exportName[i] = c
  route = source.coreBit
  doAssert source.beginWasmStealOffer(job, ticket, broker.ownerEpoch)
  source.pollWorker()
  doAssert source.offerStatus == wssOk
  route = worker.coreBit
  doAssert worker.beginWasmSteal()
  worker.pollWorker()
  doAssert worker.state == wscReady and worker.jobId == source.offeredJobId
  sourceTask = worker.taskId
  doAssert resumeWasmTask(sourceTask, 1).state == wasmTaskYielded
  source.offeredJobId

proc finishJob(source, worker: var WasmStealClient, id: uint32, expected = 42'i32) =
  let task = resumeWasmTask(worker.taskId, 64)
  doAssert task.state == wasmTaskExited and task.result == expected and task.fuelUsed > 1
  route = worker.coreBit
  doAssert worker.finishWasmSteal()
  worker.pollWorker()
  doAssert worker.state == wscIdle
  discard killWasmTask(task.id)
  route = source.coreBit
  doAssert source.beginWasmStealReadOutcome(id, broker.ownerEpoch)
  source.pollWorker()
  doAssert source.outcomeStatus == wssOk and source.outcome.returnedI32() == expected and
    source.outcome.workerCoreBit == worker.coreBit and source.outcome.fuelUsed == task.fuelUsed
  doAssert source.beginWasmStealAckOutcome(id, broker.ownerEpoch)
  source.pollWorker()
  doAssert source.outcomeStatus == wssOk and broker.stateOfWasmStealJob(id) == wstEmpty

proc driveTransfer(worker, dest: var WasmStealClient,
                    completeBeforeReply: ptr WasmStealClient,
                    forwardPackets: bool): WasmMigrationClientState =
  let jobId = worker.jobId
  for _ in 0 ..< 50:
    if forwardPackets: forwardRelayPacket(worker.coreBit, dest.coreBit)
    if receiver.needsWasmMigrationService():
      route = dest.coreBit
      let status = receiver.serviceWasmMigrationReceiver()
      doAssert status in {mwsOk, mwsPending, mwsPrepareFailed}
      if receiver.taskId != 0 and receiver.state != mwActive:
        doAssert resumeWasmTask(receiver.taskId).status == wasmSchedBadState
      elif receiver.state == mwActive and completeBeforeReply != nil:
        doAssert getWasmTask(receiver.taskId).fuelUsed == 1
        finishJob(completeBeforeReply[], dest, jobId)
        doAssert receiver.finishWasmMigrationReceiver()
    route = worker.coreBit
    result = sender.pollWasmTaskMigration(now)
    if result != wmcPending: return
  doAssert false, "managed migration did not finish"

proc transfer(worker, dest: var WasmStealClient,
               completeBeforeReply: ptr WasmStealClient = nil,
               forwardPackets = true, streaming = false): WasmMigrationClientState =
  doAssert receiver.initWasmMigrationReceiver(900 + dest.coreBit, dest.coreBit)
  doAssert receiver.bindWasmMigrationWorker(addr dest)
  doAssert sender.initWasmMigrationClient(worker.bootId, dest.coreBit, WasmStealAllCores,
    sourceCoreBit = worker.coreBit, maxTransferTicks = (if forwardPackets: 1000 else: 20))
  doAssert sender.bindWasmMigrationSourceWorker(addr worker)
  route = worker.coreBit
  if streaming:
    when defined(wasmStreamMigration):
      doAssert sender.beginWasmTaskStreamingMigration(worker.taskId, now, 512)
    else:
      doAssert false, "streaming requires wasmStreamMigration"
  else:
    doAssert sender.beginWasmTaskMigration(worker.taskId, now)
  driveTransfer(worker, dest, completeBeforeReply, forwardPackets)

doAssert broker.initWasmStealBroker(17, 500)
wasmStealRpc = brokerRpc
wasmStealPrepareHook = prepareJob
wasmMigrationRpc = snapshotRpc
wasmMigrationPrepareHook = prepareSnapshot
resetWasmScheduler()
const d0LocalResource = 1'u16 shl 15
doAssert workers[0].initWasmStealClient(20, 0, hostCore = wasmCoreM0,
  resourceMask = WasmStealDirectPsram)
doAssert workers[1].initWasmStealClient(21, 0, hostCore = wasmCoreD0,
  resourceMask = WasmStealDirectPsram or d0LocalResource)
doAssert workers[2].initWasmStealClient(22, 0, hostCore = wasmCoreLP)
for worker in workers.mitems: worker.connect()

let steered = startJob(workers[2], workers[1], 1)
let previous = workers[1].currentWasmStealClaim()
doAssert captureWasmTaskMigration(sourceTask).status == wasmMigrationUnsupported
loseAuthorize = true
loseAccept = true
probeDuringAuthorize = true
doAssert transfer(workers[1], workers[0]) == wmcComplete
doAssert not loseAuthorize and not loseAccept and not probeDuringAuthorize
doAssert workers[1].state == wscIdle and getWasmTask(sourceTask).status == wasmSchedNoTask
let moved = workers[0].currentWasmStealClaim()
doAssert moved.jobId == previous.jobId and moved.token != previous.token
doAssert broker.telemetry.handoffsAuthorized == 1 and broker.telemetry.handoffsAccepted == 1
doAssert getWasmTask(receiver.taskId).fuelUsed == 1

let staleFinish = broker.processWasmSteal(WasmStealRequest(op: wsoFinish,
  ownerEpoch: broker.ownerEpoch, peerBootId: workers[1].bootId,
  peerSession: workers[1].peerSession, peerCoreBit: WasmStealD0,
  claimToken: previous.token, jobId: previous.jobId,
  outcome: WasmStealOutcome(kind: wokReturned, detail: 99, fuelUsed: 1)), now)
doAssert staleFinish.status == wssStale
finishJob(workers[2], workers[0], steered)
doAssert receiver.finishWasmMigrationReceiver()

discard startJob(workers[1], workers[0], 1)
doAssert transfer(workers[0], workers[2], addr workers[1]) == wmcComplete
doAssert receiver.state == mwIdle
doAssert broker.telemetry.handoffsAuthorized == 2 and broker.telemetry.handoffsAccepted == 2

let pinned = startJob(workers[1], workers[0], 2, WasmStealDirectPsram)
doAssert transfer(workers[0], workers[2]) == wmcFailed
doAssert workers[0].jobId == pinned and getWasmTask(sourceTask).state == wasmTaskYielded
doAssert broker.telemetry.handoffsAuthorized == 2
finishJob(workers[1], workers[0], pinned)

let wrongEntry = startJob(workers[1], workers[0], 3, exportName = "wrong")
doAssert transfer(workers[0], workers[2]) == wmcFailed
doAssert workers[0].jobId == wrongEntry and getWasmTask(sourceTask).state == wasmTaskYielded
doAssert receiver.taskId == 0 and workers[2].state == wscIdle
doAssert broker.telemetry.handoffsAuthorized == 2
finishJob(workers[1], workers[0], wrongEntry)

discard startJob(workers[1], workers[2], 4)
doAssert transfer(workers[2], workers[0], addr workers[1]) == wmcComplete
discard startJob(workers[2], workers[0], 2)
doAssert transfer(workers[0], workers[1], addr workers[2]) == wmcComplete
doAssert broker.telemetry.handoffsAuthorized == 4 and broker.telemetry.handoffsAccepted == 4

discard startJob(workers[0], workers[1], 1)
loseForwardedPart = true
loseRelayedCommit = true
doAssert transfer(workers[1], workers[2], addr workers[0]) == wmcComplete
doAssert not loseForwardedPart and not loseRelayedCommit
doAssert sender.telemetry.relayPolls > 0 and sender.telemetry.retries == 1
discard startJob(workers[0], workers[2], 2)
doAssert transfer(workers[2], workers[1], addr workers[0]) == wmcComplete
doAssert sender.telemetry.relayPolls > 0
doAssert broker.telemetry.handoffsAuthorized == 6 and broker.telemetry.handoffsAccepted == 6

let d0Only = startJob(workers[0], workers[1], 3, d0LocalResource)
let partsBeforeRejection = forwardedParts
doAssert transfer(workers[1], workers[2]) == wmcFailed
doAssert forwardedParts == partsBeforeRejection and sender.telemetry.fragments == 0 and
  receiver.state == mwIdle
doAssert transfer(workers[1], workers[0]) == wmcFailed
doAssert sender.telemetry.fragments == 0 and receiver.state == mwIdle
doAssert workers[1].jobId == d0Only and getWasmTask(sourceTask).state == wasmTaskYielded
finishJob(workers[0], workers[1], d0Only)

let timedOut = startJob(workers[0], workers[1], 4)
doAssert transfer(workers[1], workers[2], forwardPackets = false) == wmcFailed
doAssert workers[1].jobId == timedOut and getWasmTask(sourceTask).state == wasmTaskYielded
doAssert sender.telemetry.relayPolls > 0 and broker.telemetry.handoffsAuthorized == 6
finishJob(workers[0], workers[1], timedOut)
echo "managed WASM migration PASS: all six routes, lost replies, fuel, outcome, dependencies and entry check"

when defined(wasmStreamMigration):
  let restricted = startJob(workers[0], workers[1], 5, d0LocalResource)
  let before = forwardedParts
  doAssert transfer(workers[1], workers[2], streaming = true) == wmcFailed
  doAssert forwardedParts == before and receiver.state == mwIdle
  finishJob(workers[0], workers[1], restricted)
  discard startJob(workers[0], workers[1], 6)
  doAssert transfer(workers[1], workers[2], addr workers[0], streaming = true) == wmcComplete
  doAssert forwardedParts > before
  echo "WASM migration stream PASS: dependency check precedes snapshot production"

let unknownGrant = startJob(workers[0], workers[1], 7)
loseAuthorize = true
expireOnLostAuthorization = true
doAssert transfer(workers[1], workers[2]) == wmcUncertain
doAssert not loseAuthorize and not expireOnLostAuthorization and
  broker.stateOfWasmStealJob(unknownGrant) == wstHandoff
doAssert getWasmTask(sourceTask).state == wasmTaskMigrating and
  resumeWasmTask(sourceTask).status == wasmSchedBadState
doAssert sender.retryWasmMigrationCommit(now)
doAssert driveTransfer(workers[1], workers[2], addr workers[0], true) == wmcComplete
doAssert getWasmTask(sourceTask).status == wasmSchedNoTask
echo "WASM migration retry PASS: ambiguous authorization froze the source until recovery"

let targetReset = startJob(workers[0], workers[1], 8)
let liveClaim = workers[1].currentWasmStealClaim()
let authorizedBeforeReset = broker.telemetry.handoffsAuthorized
rebootBeforeAuthorize = true
doAssert transfer(workers[1], workers[2]) == wmcFailed
doAssert not rebootBeforeAuthorize and broker.stateOfWasmStealJob(targetReset) == wstStarted
doAssert workers[1].state == wscReady and workers[1].currentWasmStealClaim() == liveClaim
doAssert getWasmTask(sourceTask).state == wasmTaskYielded and
  broker.telemetry.handoffsAuthorized == authorizedBeforeReset
finishJob(workers[0], workers[1], targetReset)
echo "WASM migration reset PASS: source resumed after the prepared LP session changed"

block relayRouting:
  var independentRelay: WasmMigrationRelay
  var request, other: array[WasmMigrationWirePayloadBytes, byte]
  var payload: array[WasmMigrationWirePartBytes, byte]
  for i in 0 ..< payload.len: payload[i] = ((i xor (i shr 8)) and 255).byte
  let first = WasmMigrationWireRequest(op: mwoPart, sourceBootId: 20,
    receiverEpoch: 123, transferId: 17, count: payload.len.uint16,
    sourceCoreBit: WasmStealD0.uint16, relayViaM0: true)
  var second = first
  second.sourceCoreBit = WasmStealLP.uint16
  doAssert first.encodeWasmMigrationRequest(payload, request) == request.len
  doAssert second.encodeWasmMigrationRequest(payload, other) == other.len
  var reply: array[WasmMigrationWireReplyBytes, byte]
  var decoded: WasmMigrationWireReply
  doAssert independentRelay.processWasmMigrationRelay(request, reply, WasmStealLP.uint16) == reply.len
  doAssert reply.decodeWasmMigrationReply(decoded) and decoded.status == mwsInvalid
  doAssert independentRelay.processWasmMigrationRelay(request, reply, WasmStealD0.uint16) == reply.len
  doAssert reply.decodeWasmMigrationReply(decoded) and decoded.status == mwsRelayPending
  doAssert independentRelay.processWasmMigrationRelay(other, reply, WasmStealLP.uint16) == reply.len
  doAssert reply.decodeWasmMigrationReply(decoded) and decoded.status == mwsRelayPending
  let d0 = independentRelay.wasmMigrationRelayPacket(WasmStealD0.uint16)
  let lp = independentRelay.wasmMigrationRelayPacket(WasmStealLP.uint16)
  doAssert d0[].takeWasmMigrationRelayPacket() == request.len
  doAssert lp[].takeWasmMigrationRelayPacket() == other.len
  doAssert d0[].takeWasmMigrationRelayPacket() == 0
  doAssert d0.request == request and lp.request == other
  let response = WasmMigrationWireReply(status: mwsOk, state: mwReceiving,
    receiverEpoch: 123, transferId: 17, nextOffset: payload.len.uint32)
  doAssert response.encodeWasmMigrationReply(d0.response) == d0.response.len
  d0[].finishWasmMigrationRelayPacket(d0.response.len)
  doAssert independentRelay.processWasmMigrationRelay(request, reply, WasmStealD0.uint16) == reply.len
  doAssert reply.decodeWasmMigrationReply(decoded) and decoded == response
  doAssert lp[].takeWasmMigrationRelayPacket() == 0 # D0's reply leaves LP's in-flight packet alone.
  doAssert receiver.coreBit == WasmStealLP
  doAssert receiver.processWasmMigrationWire(request, reply, now, WasmStealD0.uint16) == reply.len
  doAssert reply.decodeWasmMigrationReply(decoded) and decoded.status == mwsInvalid
  doAssert receiver.processWasmMigrationWire(other, reply, now, WasmStealM0.uint16) == reply.len
  doAssert reply.decodeWasmMigrationReply(decoded) and decoded.status == mwsInvalid
echo "WASM migration relay PASS: independent directions and exact source/destination routes"

when defined(wasmChunkedMemory):
  proc pageFactory(ctx: pointer, memory: MemType): ref LinearMemory {.nimcall.} =
    inc cast[ptr int](ctx)[]
    doAssert memory.limits.min == 0 and memory.limits.hasMax and memory.limits.max == 1
    new(result)
    doAssert result[].initLinearMemory(LinearMemoryConfig(maxPages: 1,
      admissionPages: 1, maxCommittedChunks: 1, residentChunks: 1)) == lmOk

  if paramCount() != 0:
    doAssert paramCount() == 1
    let module = cast[seq[byte]](readFile(paramStr(1)))
    image = newSeq[byte](WasmProgramHeaderLen.int + module.len)
    base = cast[ptr UncheckedArray[byte]](addr image[0])
    doAssert initWasmProgramImage(base, image.len.uint32, module) == wasmProgramOk
    var sourceFactories, destinationFactories: int
    doAssert workers[1].initWasmStealClient(30, 1, hostCore = wasmCoreD0,
      resourceMask = WasmStealPagedBacking, memoryFactory = pageFactory,
      memoryFactoryContext = addr sourceFactories)
    # The earlier simulated reboot updated the broker only. Start the LP
    # worker here with new local state, as the restored core would.
    if receiver.taskId != 0:
      doAssert discardPreparedWasmTaskMigration(receiver.taskId) == wasmMigrationOk
    receiver = WasmMigrationReceiver()
    workers[2] = WasmStealClient()
    doAssert workers[2].initWasmStealClient(31, 1, hostCore = wasmCoreLP,
      resourceMask = WasmStealPagedBacking, memoryFactory = pageFactory,
      memoryFactoryContext = addr destinationFactories)
    workers[1].connect()
    workers[2].connect()
    let paged = startJob(workers[0], workers[1], 9, WasmStealPagedBacking,
      maxMemoryPages = 1)
    doAssert sourceFactories == 1 and destinationFactories == 0
    doAssert transfer(workers[1], workers[0]) == wmcFailed
    doAssert sender.telemetry.fragments == 0 and destinationFactories == 0 and
      getWasmTask(sourceTask).state == wasmTaskYielded
    doAssert transfer(workers[1], workers[2]) == wmcComplete
    doAssert sourceFactories == 1 and destinationFactories == 1
    finishJob(workers[0], workers[2], paged, expected = 0)
    doAssert receiver.finishWasmMigrationReceiver()
    echo "WASM migration backing PASS: D0 to LP restored using LP's registered factory"
