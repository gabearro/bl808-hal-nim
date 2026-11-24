import bl808/[wasm_full_baseline, wasm_full_manager, wasm_scheduler, wasm_steal_broker,
  wasm_steal_client, wasm_store]
import cps/runtime
import std/os
when defined(wasmSoftStealing):
  import bl808/[wasm_rt_clock, wasm_rt_policy]
  var
    clockMode, corruptSample, invalidateStart: bool
    localNow, replyTick: uint64
    lastPrepared: uint32
  proc localTick(): uint64 {.nimcall.} = localNow
  proc ownerReplyTick(): uint64 {.nimcall.} = replyTick
  proc tickRate(): uint32 {.nimcall.} = 1
else:
  import bl808/wasm_runtime
  import cps/wasm/types

var broker: WasmStealBroker
var now = 1'u64
var rejectPreparation = false
var dropOfferReply = false
var dropFinishReply = false
var dropAckReply = false
var routedSource = 0'u32
var image = newSeq[byte](WasmProgramHeaderLen.int + WasmFullBaselineModule.len)
doAssert initWasmProgramImage(
  cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
  WasmFullBaselineModule) == wasmProgramOk
doAssert broker.initWasmStealBroker(17, 100)

proc fakeRpc(request: openArray[byte], response: pointer,
             responseBytes: int, responseLen: ptr int,
             timeoutMs: uint64): CpsVoidFuture =
  discard timeoutMs
  result = newCpsVoidFuture()
  let dst = cast[ptr UncheckedArray[byte]](response)
  let op = request[3]
  let isOffer = request.len == WasmStealResponseBytes and op == wsoOffer.ord.byte
  var size: int
  when defined(wasmSoftStealing):
    if clockMode:
      var req: WasmStealRequest
      if not isOffer: doAssert request.decodeWasmStealRequest(req)
      let ownerReceive = localNow + 50_006
      replyTick = ownerReceive + 1
      size = broker.processWasmStealWire(request,
        dst.toOpenArray(0, responseBytes - 1), ownerReceive, 2, ownerReplyTick, 1)
      if not isOffer and req.op == wsoHello:
        localNow += 30
        if corruptSample: dst[12] = dst[12] xor 1
      else:
        inc localNow
      if not isOffer and req.op == wsoStart and lastPrepared != 0:
        let dormant = getWasmTask(lastPrepared)
        doAssert dormant.state == wasmTaskBlockedIpc and dormant.resumes == 0
        doAssert resumeWasmTask(lastPrepared).status == wasmSchedBadState
        if invalidateStart: localNow += 500
    else:
      size = broker.processWasmStealWire(request,
        dst.toOpenArray(0, responseBytes - 1), now, routedSource)
  else:
    size = broker.processWasmStealWire(
      request, dst.toOpenArray(0, responseBytes - 1), now, routedSource)
  inc now
  if (isOffer and dropOfferReply) or
      (op == wsoFinish.ord.byte and dropFinishReply) or
      (op == wsoAckOutcome.ord.byte and dropAckReply):
    result.fail(newException(IOError, "lost steal reply"))
  elif size != WasmStealResponseBytes:
    result.fail(newException(IOError, "bad steal RPC"))
  else:
    responseLen[] = size
    result.complete()

proc prepare(job: WasmStealJob, admission: FullWasmAdmission): WasmSchedulerResult =
  if rejectPreparation:
    return WasmSchedulerResult(status: wasmSchedOpenFailed)
  var name = ""
  for c in job.exportName:
    if c == '\0': break
    name.add(c)
  result = startFullWasmImageTaskI32(
    cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
    name, job.args.toOpenArray(0, job.argCount.int - 1),
    maxTotalFuel = job.maxFuel, slotLabel = job.slot.int32,
    maxMemoryPages = job.maxMemoryPages, requireNoStart = true,
    admission = admission, allowPortableMigration = false, retainTrappedTask = true)
  when defined(wasmSoftStealing): lastPrepared = result.id

proc makeJob(): WasmStealJob =
  var job: WasmStealJob
  for i, c in "indirect": job.exportName[i] = c
  job.slot = 2
  job.argCount = 2
  job.args[0] = 20
  job.args[1] = 22
  job.affinityMask = 2
  job.requiredBackends = 1
  job.maxFuel = 64
  job

proc offer(): uint32 =
  doAssert broker.offerWasmStealJob(makeJob(), result) == wssOk

wasmStealRpc = fakeRpc
wasmStealPrepareHook = prepare
resetWasmScheduler()
var client: WasmStealClient
doAssert client.initWasmStealClient(123, 0)

let first = offer()
doAssert client.beginWasmSteal()
var polls = 0
while client.state == wscPending and polls < 10:
  discard client.pollWasmSteal()
  inc polls
doAssert client.state == wscReady and client.taskId != 0 and
  client.jobId == first and broker.stateOfWasmStealJob(first) == wstStarted
doAssert not client.finishWasmSteal() # Cannot finish an unrun task.
var task = getWasmTask(client.taskId)
task = resumeWasmTask(client.taskId, 1)
doAssert task.state == wasmTaskYielded
doAssert captureWasmTaskMigration(task.id).status == wasmMigrationUnsupported
doAssert beginWasmTaskMigrationCapture(task.id).status == wasmMigrationUnsupported
while task.state in {wasmTaskReady, wasmTaskYielded}:
  task = resumeWasmTask(client.taskId, 2)
doAssert task.state == wasmTaskExited and task.result == 42
doAssert client.finishWasmSteal()
doAssert client.pollWasmSteal() == wscIdle
doAssert broker.stateOfWasmStealJob(first) == wstEmpty
discard killWasmTask(task.id)

# A preparation failure releases the claim before any guest instruction runs.
let second = offer()
rejectPreparation = true
doAssert client.beginWasmSteal()
polls = 0
while client.state == wscPending and polls < 10:
  discard client.pollWasmSteal()
  inc polls
doAssert client.state == wscFailed and
  broker.stateOfWasmStealJob(second) == wstQueued
rejectPreparation = false
doAssert client.beginWasmSteal()
polls = 0
while client.state == wscPending and polls < 10:
  discard client.pollWasmSteal()
  inc polls
doAssert client.state == wscReady and client.jobId == second
task = getWasmTask(client.taskId)
while task.state in {wasmTaskReady, wasmTaskYielded}:
  task = resumeWasmTask(client.taskId, 2)
doAssert task.state == wasmTaskExited and task.result == 42
doAssert client.finishWasmSteal()
doAssert client.pollWasmSteal() == wscIdle
discard killWasmTask(task.id)
echo "WASM steal client PASS: prepared full task, ack, release and finish"

when defined(wasmSoftStealing):
  proc offerSoft(release, deadline: uint64, budget = 50'u64): uint32 =
    var job = makeJob()
    job.soft = WasmStealSoftSpec(releaseTick: release, deadlineTick: deadline,
      budgetTicks: budget, maxSliceTicks: 10, overrun: wrStop)
    doAssert broker.offerWasmStealJob(job, result) == wssOk

  proc driveSoft(client: var WasmStealClient) =
    for _ in 0 ..< 8:
      if client.state != wscPending: break
      discard client.pollWasmSteal()
    doAssert client.state != wscPending

  clockMode = true
  localNow = 10_000
  wasmStealClockNow = localTick
  wasmStealClockRate = tickRate
  doAssert broker.initWasmStealBroker(19, 100)
  doAssert initWasmRtScheduler(2, localNow, 1000) == wrOk
  doAssert client.enableWasmSoftStealing(WasmClockLimits(maxRoundTripTicks: 64,
    maxAgeTicks: 100, maxProjectionTicks: 10_000, maxUncertaintyTicks: 64))

  let fallback = offer()
  let late = offerSoft(60_220, 60_700)
  let early = offerSoft(60_200, 60_500)
  doAssert client.beginWasmSteal()
  client.driveSoft()
  doAssert client.state == wscReady and client.jobId == early
  doAssert broker.stateOfWasmStealJob(late) == wstQueued and
    broker.stateOfWasmStealJob(fallback) == wstQueued
  doAssert client.softTelemetry.clockSamples == 1 and
    client.softTelemetry.maxRoundTripTicks == 30 and client.softTelemetry.maxUncertaintyTicks == 33
  let work = client.taskId
  doAssert resumeWasmTask(work).status == wasmSchedBadState and runWasmScheduler() == 0
  doAssert nextWasmSchedulerRtWakeTick(localNow, 0) == 10_225
  localNow = 10_224
  doAssert runWasmSchedulerRt(localTick, 0) == 0
  localNow = 10_225
  doAssert runWasmSchedulerRt(localTick, 0) == 1
  doAssert getWasmTask(work).state == wasmTaskExited and getWasmTask(work).result == 42
  doAssert client.finishWasmSteal()
  client.driveSoft()
  doAssert client.state == wscIdle and broker.stateOfWasmStealJob(early) == wstEmpty
  discard killWasmTask(work)

  # Failed clock proof leaves soft work queued and lets best effort proceed.
  corruptSample = true
  doAssert client.beginWasmSteal()
  client.driveSoft()
  doAssert client.state == wscReady and client.jobId == fallback and
    client.softTelemetry.rejectedSamples == 1 and broker.stateOfWasmStealJob(late) == wstQueued
  let other = resumeWasmTask(client.taskId)
  doAssert other.state == wasmTaskExited and other.result == 42
  doAssert client.finishWasmSteal()
  client.driveSoft()
  discard killWasmTask(other.id)
  corruptSample = false

  # Local preparation is dormant and a delayed ownership acknowledgment
  # has to revalidate the clock sample before releasing the task.
  invalidateStart = true
  doAssert client.beginWasmSteal()
  client.driveSoft()
  doAssert client.state == wscFailed and broker.stateOfWasmStealJob(late) == wstEmpty
  doAssert getWasmTask(lastPrepared).status == wasmSchedNoTask and
    client.softTelemetry.rejectedJobs == 1
  invalidateStart = false

  let ownerNow = localNow + 50_000
  let tight = offerSoft(ownerNow, ownerNow + 70, budget = 60)
  doAssert client.beginWasmSteal()
  client.driveSoft()
  doAssert client.state == wscFailed and broker.stateOfWasmStealJob(tight) == wstQueued
  broker.reapWasmStealLeases(ownerNow + 70)
  doAssert broker.stateOfWasmStealJob(tight) == wstEmpty and broker.telemetry.expiredSoftJobs == 1

  # A new owner epoch cannot inherit the previous correlation or claims.
  doAssert client.beginWasmSteal()
  doAssert broker.initWasmStealBroker(20, 100)
  client.driveSoft()
  doAssert client.state == wscFailed

  doAssert paramCount() == 1
  let startModule = cast[seq[byte]](readFile(paramStr(1)))
  var startImage = newSeq[byte](WasmProgramHeaderLen.int + startModule.len)
  let startBase = cast[ptr UncheckedArray[byte]](addr startImage[0])
  doAssert initWasmProgramImage(startBase, startImage.len.uint32, startModule) == wasmProgramOk
  doAssert startFullWasmImageTaskI32(startBase, startImage.len.uint32,
    "run", [], requireNoStart = true).status == wasmSchedOpenFailed
  let normal = startFullWasmImageTaskI32(startBase, startImage.len.uint32, "run", [])
  doAssert resumeWasmTask(normal.id).result == 42
  resetWasmScheduler()
  let next = startFullWasmImageTaskI32(startBase, startImage.len.uint32, "run", [])
  doAssert next.status == wasmSchedOk and next.id != normal.id
  doAssert killWasmTask(normal.id).status == wasmSchedNoTask
  doAssert resumeWasmTask(next.id).result == 42
  discard killWasmTask(next.id)

  doAssert client.beginWasmStealSession()
  client.driveSoft()
  let deadline = localNow + 50_200
  var unclaimed = makeJob()
  unclaimed.soft = WasmStealSoftSpec(releaseTick: deadline - 100,
    deadlineTick: deadline, budgetTicks: 50, maxSliceTicks: 10, overrun: wrStop)
  doAssert client.beginWasmStealOffer(unclaimed, 1, broker.ownerEpoch)
  client.driveSoft()
  doAssert client.offerStatus == wssOk
  let overdue = client.offeredJobId
  broker.reapWasmStealLeases(deadline)
  doAssert client.beginWasmStealReadOutcome(overdue, broker.ownerEpoch)
  client.driveSoft()
  doAssert client.outcomeStatus == wssOk and client.outcome.kind == wokDeadline and
    client.outcome.workerCoreBit == 0 and client.outcome.fuelUsed == 0
  doAssert client.beginWasmStealAckOutcome(overdue, broker.ownerEpoch)
  client.driveSoft()
  doAssert client.outcomeStatus == wssOk and broker.stateOfWasmStealJob(overdue) == wstEmpty
  echo "WASM soft steal PASS: EDF, conservative release, bad sample, stale ACK and fallback"

else:
  proc drive(worker: var WasmStealClient) =
    for _ in 0 ..< 10:
      if worker.state != wscPending: return
      discard worker.pollWasmSteal()
    doAssert worker.state != wscPending

  proc connect(worker: var WasmStealClient) =
    routedSource = worker.coreBit
    doAssert worker.beginWasmStealSession()
    worker.drive()
    doAssert worker.state == wscIdle and worker.ownerEpoch == broker.ownerEpoch

  proc submit(worker: var WasmStealClient, job: WasmStealJob,
              ticket: uint32): uint32 =
    routedSource = worker.coreBit
    doAssert worker.beginWasmStealOffer(job, ticket, broker.ownerEpoch)
    worker.drive()
    doAssert worker.state == wscIdle and worker.offerStatus == wssOk
    worker.offeredJobId

  proc claim(worker: var WasmStealClient) =
    routedSource = worker.coreBit
    doAssert worker.beginWasmSteal()
    worker.drive()

  proc finishJob(worker: var WasmStealClient, id: uint32, loseReply = false) =
    doAssert worker.state == wscReady and worker.jobId == id
    var task = getWasmTask(worker.taskId)
    while task.state in {wasmTaskReady, wasmTaskYielded}:
      task = resumeWasmTask(worker.taskId, 2)
    doAssert task.state == wasmTaskExited and task.result == 42
    dropFinishReply = loseReply
    doAssert worker.finishWasmSteal()
    worker.drive()
    doAssert worker.state == (if loseReply: wscFinishRetry else: wscIdle)
    doAssert broker.stateOfWasmStealJob(id) == wstComplete
    discard killWasmTask(task.id)
    dropFinishReply = false

  proc readOutcome(worker: var WasmStealClient, id: uint32): WasmStealStatus =
    routedSource = worker.coreBit
    doAssert worker.beginWasmStealReadOutcome(id, broker.ownerEpoch)
    worker.drive()
    doAssert worker.state == wscIdle and worker.outcomeJobId == id
    worker.outcomeStatus

  proc acknowledge(worker: var WasmStealClient, id: uint32, loseReply = false) =
    routedSource = worker.coreBit
    dropAckReply = loseReply
    doAssert worker.beginWasmStealAckOutcome(id, broker.ownerEpoch)
    worker.drive()
    dropAckReply = false
    if loseReply:
      doAssert worker.state == wscFailed
      worker.connect()
    else:
      doAssert worker.state == wscIdle and worker.outcomeStatus == wssOk
    doAssert broker.stateOfWasmStealJob(id) == wstEmpty

  proc expectReturn(source: var WasmStealClient, id, core: uint32) =
    doAssert source.readOutcome(id) == wssOk and
      source.outcome.kind == wokReturned and source.outcome.returnedI32() == 42 and
      source.outcome.fuelUsed > 0 and source.outcome.workerCoreBit == core

  proc loadImage(path: string) =
    let module = cast[seq[byte]](readFile(path))
    image = newSeq[byte](WasmProgramHeaderLen.int + module.len)
    doAssert initWasmProgramImage(cast[ptr UncheckedArray[byte]](addr image[0]),
      image.len.uint32, module) == wasmProgramOk

  doAssert broker.initWasmStealBroker(21, 100)
  const cores = [wasmCoreM0, wasmCoreD0, wasmCoreLP]
  var workers: array[cores.len, WasmStealClient]
  for i, core in cores:
    doAssert workers[i].initWasmStealClient(uint32(i + 1), 0, hostCore = core)
    workers[i].connect()
  for source in 0 ..< workers.len:
    var ticket = 0'u32
    for target in 0 ..< workers.len:
      if source == target: continue
      inc ticket
      var job = makeJob()
      job.affinityMask = workers[target].coreBit
      let id = workers[source].submit(job, ticket)
      doAssert workers[source].submit(job, ticket) == id
      doAssert workers[source].readOutcome(id) == wssEmpty
      workers[source].claim()
      doAssert workers[source].state == wscNoJob
      workers[target].claim()
      let firstRoute = source == 0 and target == 1
      workers[target].finishJob(id, loseReply = firstRoute)
      doAssert firstRoute or workers[target].readOutcome(id) == wssStale
      workers[source].expectReturn(id, workers[target].coreBit)
      workers[source].expectReturn(id, workers[target].coreBit)
      workers[source].acknowledge(id, loseReply = firstRoute)
      if firstRoute:
        workers[source].acknowledge(id) # Repeat the acknowledged removal.
        routedSource = workers[target].coreBit
        doAssert workers[target].finishWasmSteal() # Worker can retry after source ACK.
        workers[target].drive()
        doAssert workers[target].state == wscIdle
  doAssert broker.telemetry.offered == 6 and broker.telemetry.completed == 6 and
    broker.telemetry.acknowledgedOutcomes == 6
  echo "WASM steal any-core PASS: all six handoffs and source acknowledgments"

  # A lost offer reply can be recovered with the same ticket. An M0 reset
  # requires explicit acceptance of the new epoch.
  var job = makeJob()
  routedSource = workers[0].coreBit
  dropOfferReply = true
  let ownerEpoch = broker.ownerEpoch
  doAssert workers[0].beginWasmStealOffer(job, 3, ownerEpoch)
  workers[0].drive()
  doAssert workers[0].state == wscFailed and broker.telemetry.offered == 7
  dropOfferReply = false
  workers[0].connect()
  let recovered = workers[0].submit(job, 3)
  doAssert broker.telemetry.offered == 7
  workers[1].claim()
  workers[1].finishJob(recovered)
  workers[0].expectReturn(recovered, WasmStealD0)
  workers[0].acknowledge(recovered)
  doAssert broker.initWasmStealBroker(ownerEpoch + 1, 100)
  workers[0].connect()
  doAssert not workers[0].beginWasmStealOffer(job, 3, ownerEpoch)

  workers[1].connect()
  workers[2].connect()
  var trapJob = makeJob()
  trapJob.maxFuel = 1
  let trapped = workers[0].submit(trapJob, 1)
  workers[1].claim()
  doAssert workers[1].state == wscReady
  routedSource = workers[0].coreBit
  doAssert workers[0].beginWasmStealCancel(trapped, broker.ownerEpoch)
  workers[0].drive()
  doAssert workers[0].outcomeStatus == wssBusy
  let trappedTaskId = workers[1].taskId
  doAssert resumeWasmTask(trappedTaskId, 1).state == wasmTaskYielded
  let stopped = resumeWasmTask(trappedTaskId, 1)
  doAssert stopped.state == wasmTaskTrapped and stopped.trapCode != 0
  for _ in 0 .. WasmTaskTrapReapPolls: discard reapTrappedSlots()
  doAssert getWasmTask(trappedTaskId).state == wasmTaskTrapped
  routedSource = workers[1].coreBit
  doAssert workers[1].finishWasmSteal()
  workers[1].drive()
  discard killWasmTask(trappedTaskId)
  doAssert workers[0].readOutcome(trapped) == wssOk and
    workers[0].outcome.kind == wokTrapped and workers[0].outcome.detail == stopped.trapCode and
    workers[0].outcome.fuelUsed == 1

  # A completed job retains its reserved slot until acknowledged.
  for ticket in 2'u32 .. WasmStealMaxJobs.uint32:
    discard workers[0].submit(job, ticket)
  routedSource = workers[0].coreBit
  doAssert workers[0].beginWasmStealOffer(job, WasmStealMaxJobs.uint32 + 1, broker.ownerEpoch)
  workers[0].drive()
  doAssert workers[0].offerStatus == wssNoCapacity
  workers[0].acknowledge(trapped)
  let canceled = workers[0].submit(job, WasmStealMaxJobs.uint32 + 1)
  doAssert workers[2].readOutcome(canceled) == wssStale
  routedSource = workers[0].coreBit
  doAssert workers[0].beginWasmStealCancel(canceled, broker.ownerEpoch)
  workers[0].drive()
  doAssert workers[0].outcomeStatus == wssOk
  doAssert workers[0].readOutcome(canceled) == wssOk and workers[0].outcome.kind == wokCanceled
  workers[0].acknowledge(canceled)
  doAssert workers[0].initWasmStealClient(11, 0, hostCore = wasmCoreM0)
  workers[0].connect()
  doAssert broker.telemetry.abandonedOffers == WasmStealMaxJobs.uint32 - 1
  echo "WASM steal outcome PASS: retained trap, capacity and cancellation"

  if paramCount() != 0:
    doAssert paramCount() == 2
    const d0Service = 1'u32 shl 17
    var hostCalls = 0
    proc add(args: openArray[WasmValue]): seq[WasmValue] =
      inc hostCalls
      @[wasmI32(args[0].i32 + args[1].i32)]
    let service = FullWasmHostBinding(interfaceBit: d0Service,
      moduleName: "ox64", fieldName: "d0-service",
      signature: FuncType(params: @[vtI32, vtI32], results: @[vtI32]), callback: add)
    doAssert not workers[2].initWasmStealClient(5, 0, hostCore = wasmCoreLP,
      resourceMask = WasmStealDirectPsram)
    doAssert not workers[2].initWasmStealClient(5, 0, hostCore = wasmCoreLP,
      hostInterfaceMask = d0Service)
    doAssert workers[1].initWasmStealClient(7, 0, hostCore = wasmCoreD0,
      hostBindings = @[service], resourceMask = WasmStealDirectPsram)
    doAssert workers[2].initWasmStealClient(9, 0, hostCore = wasmCoreLP)
    workers[1].connect()
    workers[2].connect()
    loadImage(paramStr(1))
    job.affinityMask = WasmStealAllCores
    job.requiredHostInterfaces = d0Service
    job.requiredResources = WasmStealDirectPsram
    # D0 offers the job. LP and M0 both lack its service and resource.
    let dependent = workers[1].submit(job, 1)
    for index in [2, 0]:
      workers[index].claim()
      doAssert workers[index].state == wscNoJob
    doAssert hostCalls == 0
    workers[1].claim()
    doAssert hostCalls == 0
    workers[1].finishJob(dependent)
    workers[1].acknowledge(dependent)
    doAssert hostCalls == 1

    # The same interface bit alone does not guarantee a compatible import.
    # A wrong signature must decline this job and leave it runnable on D0.
    var wrong = service
    wrong.signature = FuncType(params: @[vtI32], results: @[vtI32])
    doAssert workers[2].initWasmStealClient(10, 0, hostCore = wasmCoreLP,
      hostBindings = @[wrong])
    workers[2].connect()
    job.requiredResources = 0
    let exact = workers[0].submit(job, 1)
    workers[2].claim()
    doAssert workers[2].state == wscNoJob and broker.telemetry.dependencyDeclines == 1
    workers[2].claim()
    doAssert workers[2].state == wscNoJob and broker.telemetry.dependencyDeclines == 1
    workers[1].claim()
    workers[1].finishJob(exact)
    workers[0].expectReturn(exact, WasmStealD0)
    workers[0].acknowledge(exact)
    doAssert hostCalls == 2

    # Omitting the dependency must never grant access to an available service.
    job.affinityMask = WasmStealD0
    job.requiredHostInterfaces = 0
    let undeclared = workers[2].submit(job, 1)
    workers[1].claim()
    doAssert workers[1].state == wscNoJob and broker.stateOfWasmStealJob(undeclared) == wstQueued
    doAssert hostCalls == 2

    loadImage(paramStr(2))
    let memBase = cast[ptr UncheckedArray[byte]](addr image[0])
    let noMemory = startFullWasmImageTaskI32(memBase, image.len.uint32, "run", [],
      admission = FullWasmAdmission(enforceMemoryQuota: true))
    doAssert noMemory.status == wasmSchedOk and resumeWasmTask(noMemory.id).result == -1
    discard killWasmTask(noMemory.id)
    let withMemory = startFullWasmImageTaskI32(memBase, image.len.uint32, "run", [],
      maxMemoryPages = 1, admission = FullWasmAdmission(enforceMemoryQuota: true))
    doAssert withMemory.status == wasmSchedOk and resumeWasmTask(withMemory.id).result == 0
    discard killWasmTask(withMemory.id)
    echo "WASM steal dependency PASS: core-local service, typed linking and zero-page quota"
