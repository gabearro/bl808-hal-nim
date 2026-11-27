## M0/D0/LP client for the unstarted full-VM job queue. The client
## prepares a normal local wasm_scheduler task, acknowledges ownership, then
## exposes its task ID. The caller drives that task with the existing scheduler
## and later reports completion. Poll only from the core's kernel loop.

when not defined(bl808m0) and not defined(bl808d0) and not defined(bl808lp) and
    not defined(wasmStealHostTest):
  {.error: "WASM steal clients run on M0, D0, or LP".}
when not defined(bl808WasmFullScheduler):
  {.error: "WASM stealing requires the full task scheduler".}

import ./[wasm_full_manager, wasm_manager, wasm_runtime, wasm_scheduler,
  wasm_steal_broker]
when defined(wasmSoftStealing):
  when not defined(bl808WasmRtPolicy):
    {.error: "soft stealing requires the local WASM RT policy".}
  import ./[wasm_rt_clock, wasm_rt_policy]
  when defined(wasmStealHostTest):
    var
      wasmStealClockNow*: WasmStealClock
      wasmStealClockRate*: proc(): uint32 {.nimcall.}
    template localClockTick(): uint64 = wasmStealClockNow()
    template localClockRate(): uint32 = wasmStealClockRate()
  else:
    import ./kernel/clock
    template localClockTick(): uint64 = readTick()
    template localClockRate(): uint32 = min(clockGetTickRate(), high(uint32).uint64).uint32

when defined(wasmStealHostTest):
  when defined(wasmStealClientQemu):
    import ./kernel/runtime
  else:
    import cps/runtime
  type WasmStealRpc* = proc(request: openArray[byte], response: pointer,
    responseBytes: int, responseLen: ptr int,
    timeoutMs: uint64): CpsVoidFuture {.nimcall.}
  var
    wasmStealRpc*: WasmStealRpc
    wasmStealPrepareHook*: proc(job: WasmStealJob,
      admission: FullWasmAdmission, memoryFactory: FullMemoryFactory,
      memoryFactoryContext: pointer): WasmSchedulerResult
elif defined(bl808m0):
  import ./wasm_steal_server
  import ./kernel/runtime
else:
  import ./ipc
  import ./kernel/[cps, ipcbridge]
  when defined(bl808lp):
    import ./kernel/lp_local_atomic

when defined(wasmSoftStealing):
  type WasmSoftStealTelemetry* = object
    clockSamples*, rejectedSamples*, rejectedJobs*: uint32
    maxRoundTripTicks*, maxUncertaintyTicks*: uint64

type
  StealPreparation = enum
    stpRetry
    stpDependencyUnavailable
    stpReady

  WasmStealClientState* = enum
    wscIdle
    wscPending
    wscNoJob
    wscReady
    wscFailed
    wscFinishRetry
    wscHandoffChecked
    wscHandoffRetry

  WasmStealClaim* = object
    ownerEpoch*, jobId*, token*: uint32

  WasmStealClient* = object
    state*: WasmStealClientState
    taskId*: uint32
    jobId*: uint32
    ownerEpoch*: uint32
    peerSession*: uint32
    bootId*: uint32
    coreBit*: uint32
    capabilities*: WasmRuntimeCapabilities
    maxMemoryPages*: uint32
    timeoutMs*: uint64
    offerStatus*: WasmStealStatus
    offeredJobId*: uint32
    outcomeStatus*: WasmStealStatus
    outcome*: WasmStealOutcome
    outcomeJobId*: uint32
    offerTicket: uint32
    claimAfterHello: bool
    hostBindings: seq[FullWasmHostBinding]
    resourceMask: uint16
    when defined(wasmChunkedMemory):
      memoryFactory: FullMemoryFactory
      memoryFactoryContext: pointer
    claimToken: uint32
    pendingOp: WasmStealOp
    pendingFuture: CpsVoidFuture
    when defined(bl808m0) and not defined(wasmStealHostTest):
      localReply: bool
    rejectedAfterStart: bool
    when defined(wasmSoftStealing):
      clockLimits: WasmClockLimits
      correlation: WasmClockCorrelation
      probeNonce, probeRate: uint32
      probeSend: uint64
      softRelease, softDeadline, softBudget: uint64
      softTelemetry*: WasmSoftStealTelemetry
    responseLen: int
    requestBuf: array[WasmStealRequestBytes, byte]
    responseBuf: array[WasmStealResponseBytes, byte]
    when defined(wasmManagedMigration):
      handoffClaim: WasmStealClaim
      handoffJob*: WasmStealJob
      handoffStatus*: WasmStealStatus
      handoffTaskId: uint32
      handoffSourceCore: uint32

proc initWasmStealClient*(client: var WasmStealClient,
                          bootId: uint32, maxMemoryPages: uint32,
                          hostInterfaceMask = 0'u32,
                          timeoutMs = 5000'u64,
                          hostBindings: seq[FullWasmHostBinding] = @[],
                          resourceMask = 0'u16,
                          hostCore = wasmCoreD0,
                          memoryFactory: FullMemoryFactory = nil,
                          memoryFactoryContext: pointer = nil): bool =
  if client.state in {wscPending, wscReady, wscFinishRetry, wscHandoffChecked, wscHandoffRetry} or
      (client.pendingFuture != nil and not client.pendingFuture.finished):
    return false
  var caps = wasmRuntimeCapabilities()
  when defined(wasmStealHostTest):
    if caps.core == wasmCoreUnknown: caps.core = hostCore
  if bootId == 0 or timeoutMs == 0 or not caps.fullInterpreter or
      (caps.executionBackends and WasmBackendInterpreter) == 0:
    return false
  let bit = wasmStealCoreBit(caps.core)
  if bit == 0 or not wasmStealResourcesAllowed(bit, resourceMask): return false
  if memoryFactory == nil and (memoryFactoryContext != nil or
      (resourceMask and WasmStealPagedBacking) != 0): return false
  when not defined(wasmChunkedMemory):
    if memoryFactory != nil: return false
  when defined(bl808WasmRtPolicy):
    # This binding API has no measured host-call bound for deadline slots.
    if hostBindings.len != 0: return false
  var available = 0'u32
  for i, binding in hostBindings:
    if binding.interfaceBit == 0 or
        (binding.interfaceBit and (binding.interfaceBit - 1)) != 0 or
        binding.moduleName.len == 0 or binding.fieldName.len == 0 or
        binding.callback == nil:
      return false
    for j in 0 ..< i:
      if hostBindings[j].moduleName == binding.moduleName and
          hostBindings[j].fieldName == binding.fieldName:
        return false
    available = available or binding.interfaceBit
  if (hostInterfaceMask and available) != hostInterfaceMask: return false
  caps.hostInterfaceMask = if hostInterfaceMask == 0: available else: hostInterfaceMask
  client = WasmStealClient(state: wscIdle, bootId: bootId, coreBit: bit,
    capabilities: caps, maxMemoryPages: maxMemoryPages,
    timeoutMs: timeoutMs, hostBindings: hostBindings, resourceMask: resourceMask)
  when defined(wasmChunkedMemory):
    client.memoryFactory = memoryFactory
    client.memoryFactoryContext = memoryFactoryContext
  true

when defined(wasmManagedMigration) and defined(wasmChunkedMemory):
  proc registeredWasmStealMemory*(client: var WasmStealClient):
      tuple[factory: FullMemoryFactory, context: pointer] {.inline.} =
    (client.memoryFactory, client.memoryFactoryContext)

when defined(wasmSoftStealing):
  proc enableWasmSoftStealing*(client: var WasmStealClient, limits: WasmClockLimits): bool =
    if client.state in {wscPending, wscReady} or client.bootId == 0 or
        not limits.validWasmClockLimits() or not wasmRtSchedulerReady():
      return false
    when defined(wasmStealHostTest):
      if wasmStealClockNow == nil or wasmStealClockRate == nil: return false
    client.clockLimits = limits
    client.correlation = WasmClockCorrelation()
    true

  proc wantsSoft(client: WasmStealClient): bool {.inline.} =
    client.clockLimits.maxAgeTicks != 0 and wasmRtSchedulerReady()

  proc freshClock(client: WasmStealClient, now: uint64): bool {.inline.} =
    client.correlation.isFreshWasmClock(now, client.ownerEpoch, client.peerSession, localClockRate())

  proc softWindowFits(client: WasmStealClient): bool =
    if client.softDeadline == 0: return true
    let now = localClockTick()
    let start = max(now, client.softRelease)
    client.wantsSoft() and client.freshClock(now) and start < client.softDeadline and
      client.softBudget <= client.softDeadline - start

proc makeRequest(client: WasmStealClient, op: WasmStealOp): WasmStealRequest =
  WasmStealRequest(op: op,
    ownerEpoch: client.ownerEpoch, peerBootId: client.bootId,
    peerSession: client.peerSession, peerCoreBit: client.coreBit,
    claimToken: client.claimToken,
    backendMask: client.capabilities.executionBackends,
    hostInterfaceMask: client.capabilities.hostInterfaceMask,
    maxMemoryPages: client.maxMemoryPages,
    resourceMask: client.resourceMask,
    fullInterpreter: client.capabilities.fullInterpreter)

proc exchange(client: var WasmStealClient, request: openArray[byte]): bool =
  client.responseLen = 0
  when defined(wasmStealHostTest):
    if wasmStealRpc == nil: return false
    client.pendingFuture = wasmStealRpc(request,
      addr client.responseBuf[0], client.responseBuf.len,
      addr client.responseLen, client.timeoutMs)
    client.pendingFuture != nil
  elif defined(bl808m0):
    client.responseLen = processLocalM0WasmStealWire(request, client.responseBuf)
    client.localReply = client.responseLen == WasmStealResponseBytes
    client.localReply
  else:
    client.pendingFuture = ipcCallTo(ipcM0, WasmStealWireTag,
      request, addr client.responseBuf[0], client.responseBuf.len,
      addr client.responseLen, timeoutMs = client.timeoutMs)
    client.pendingFuture != nil

proc send(client: var WasmStealClient, op: WasmStealOp,
          jobId = 0'u32, outcome = WasmStealOutcome()): bool =
  var req = client.makeRequest(op)
  req.jobId = jobId
  req.outcome = outcome
  if op in {wsoReadOutcome, wsoAckOutcome, wsoCancel}: req.claimToken = 0
  when defined(wasmSoftStealing):
    if op == wsoHello:
      client.probeRate = 0
      if client.wantsSoft():
        inc client.probeNonce
        if client.probeNonce == 0: inc client.probeNonce
        client.probeRate = localClockRate()
        req.acceptSoft = true
        req.claimToken = client.probeNonce
    elif op == wsoClaim and client.wantsSoft():
      req.acceptSoft = client.freshClock(localClockTick())
  let size = req.encodeWasmStealRequest(client.requestBuf)
  if size != WasmStealRequestBytes: return false
  client.pendingOp = op
  when defined(wasmSoftStealing):
    if op == wsoHello and req.acceptSoft: client.probeSend = localClockTick()
  client.exchange(client.requestBuf)

proc fail(client: var WasmStealClient) =
  ## Kill a task that has never been exposed to the caller. A lost start
  ## acknowledgement may leave an owner tombstone but never duplicate work.
  if client.taskId != 0 and client.state != wscReady:
    discard killWasmTask(client.taskId)
  client.taskId = 0
  client.jobId = 0
  client.claimToken = 0
  client.ownerEpoch = 0
  client.peerSession = 0
  client.pendingFuture = nil
  when defined(bl808m0) and not defined(wasmStealHostTest):
    client.localReply = false
  client.rejectedAfterStart = false
  when defined(wasmSoftStealing):
    client.correlation = WasmClockCorrelation()
    client.softDeadline = 0
  client.state = wscFailed

proc finishRetry(client: var WasmStealClient) =
  client.pendingFuture = nil
  when defined(bl808m0) and not defined(wasmStealHostTest):
    client.localReply = false
  client.state = wscFinishRetry

proc sendFinish(client: var WasmStealClient, outcome: WasmStealOutcome): bool =
  client.state = wscPending
  if client.send(wsoFinish, client.jobId, outcome): return true
  client.finishRetry()
  false

proc beginWasmSteal*(client: var WasmStealClient): bool =
  if client.state notin {wscIdle, wscNoJob, wscFailed} or client.bootId == 0:
    return false
  client.state = wscPending
  client.claimAfterHello = true
  let useHello = client.peerSession == 0 or
    (when defined(wasmSoftStealing): client.wantsSoft() else: false)
  if not client.send(if useHello: wsoHello else: wsoClaim):
    client.fail()
    return false
  true

proc beginWasmStealSession*(client: var WasmStealClient): bool =
  ## Connect a submitter without claiming a job.
  if client.state notin {wscIdle, wscNoJob, wscFailed} or client.bootId == 0:
    return false
  client.state = wscPending
  client.claimAfterHello = false
  if client.send(wsoHello): return true
  client.fail()
  false

proc beginWasmStealOffer*(client: var WasmStealClient, job: WasmStealJob,
                          ticket, expectedOwnerEpoch: uint32): bool =
  ## Use a new increasing ticket for each offer, or the same ticket after
  ## an ambiguous reply. The ticket is scoped to this broker and peer boot.
  if client.state notin {wscIdle, wscNoJob} or client.peerSession == 0 or
      expectedOwnerEpoch == 0 or expectedOwnerEpoch != client.ownerEpoch:
    return false
  var req = client.makeRequest(wsoOffer)
  req.claimToken = ticket
  if req.encodeWasmStealOffer(job, client.responseBuf) != WasmStealResponseBytes:
    return false
  client.offerTicket = ticket
  client.offerStatus = wssStale
  client.offeredJobId = 0
  client.pendingOp = wsoOffer
  client.state = wscPending
  if client.exchange(client.responseBuf): return true
  client.fail()
  false

proc beginOutcomeRequest(client: var WasmStealClient, op: WasmStealOp,
                         jobId, expectedOwnerEpoch: uint32): bool =
  if client.state notin {wscIdle, wscNoJob} or client.peerSession == 0 or
      jobId == 0 or expectedOwnerEpoch == 0 or expectedOwnerEpoch != client.ownerEpoch:
    return false
  client.outcomeStatus = wssStale
  client.outcomeJobId = jobId
  client.outcome = WasmStealOutcome()
  client.state = wscPending
  if client.send(op, jobId): return true
  client.fail()
  false

proc beginWasmStealReadOutcome*(client: var WasmStealClient,
                                jobId, expectedOwnerEpoch: uint32): bool =
  ## wssEmpty means the job is still pending. wssOk returns a terminal outcome.
  client.beginOutcomeRequest(wsoReadOutcome, jobId, expectedOwnerEpoch)

proc beginWasmStealAckOutcome*(client: var WasmStealClient,
                               jobId, expectedOwnerEpoch: uint32): bool =
  ## Release the broker entry after the caller records the returned outcome.
  client.beginOutcomeRequest(wsoAckOutcome, jobId, expectedOwnerEpoch)

proc beginWasmStealCancel*(client: var WasmStealClient,
                           jobId, expectedOwnerEpoch: uint32): bool =
  ## Cancel before start. Read and acknowledge the canceled outcome as usual.
  client.beginOutcomeRequest(wsoCancel, jobId, expectedOwnerEpoch)

when defined(wasmManagedMigration):
  proc currentWasmStealClaim*(client: WasmStealClient): WasmStealClaim =
    if client.state == wscReady:
      WasmStealClaim(ownerEpoch: client.ownerEpoch, jobId: client.jobId,
        token: client.claimToken)
    else:
      WasmStealClaim()

  proc sendHandoffRequest(client: var WasmStealClient, req: WasmStealRequest): bool =
    if req.encodeWasmStealRequest(client.requestBuf) != WasmStealRequestBytes: return false
    client.pendingOp = req.op
    client.state = wscPending
    client.exchange(client.requestBuf)

  proc retryWasmStealHandoff*(client: var WasmStealClient): bool =
    if client.state != wscHandoffRetry: return false
    client.state = wscPending
    if client.exchange(client.requestBuf): return true
    client.state = wscHandoffRetry
    false

  proc beginWasmStealCheckHandoff*(client: var WasmStealClient,
                                   claim: WasmStealClaim, sourceCoreBit: uint32,
                                   probeOnly = false): bool =
    if client.state notin {wscIdle, wscNoJob} or client.peerSession == 0 or
        claim.ownerEpoch != client.ownerEpoch or claim.jobId == 0 or claim.token == 0:
      return false
    var req = client.makeRequest(if probeOnly: wsoProbeHandoff else: wsoCheckHandoff)
    req.jobId = claim.jobId
    req.claimToken = claim.token
    req.hostInterfaceMask = 0
    req.handoffCoreBit = sourceCoreBit
    client.handoffStatus = wssStale
    client.handoffJob = WasmStealJob()
    client.handoffClaim = claim
    client.handoffSourceCore = sourceCoreBit
    if client.sendHandoffRequest(req): return true
    client.fail()
    false

  proc cancelWasmStealCheckHandoff*(client: var WasmStealClient): bool =
    ## Call before the snapshot sender retires its task.
    if client.state != wscHandoffChecked: return false
    client.handoffJob = WasmStealJob()
    client.handoffClaim = WasmStealClaim()
    client.state = wscIdle
    true

  proc beginWasmStealAuthorizeHandoff*(client: var WasmStealClient,
                                       targetCoreBit, checkedSession: uint32): bool =
    ## Keep the source frozen until the broker confirms the handoff. Only
    ## an explicit refusal with the live source token permits resumption.
    if client.state != wscReady or client.taskId == 0 or checkedSession == 0 or
        targetCoreBit == client.coreBit or targetCoreBit notin
          [WasmStealM0, WasmStealD0, WasmStealLP]:
      return false
    let task = getWasmTask(client.taskId)
    if task.state != wasmTaskMigrating: return false
    var req = client.makeRequest(wsoAuthorizeHandoff)
    req.jobId = client.jobId
    req.handoffCoreBit = targetCoreBit
    req.handoffSession = checkedSession
    req.handoffFuelUsed = task.fuelUsed
    client.handoffStatus = wssStale
    if not client.sendHandoffRequest(req): client.state = wscHandoffRetry
    true

  proc beginWasmStealAcceptHandoff*(client: var WasmStealClient,
                                     preparedTaskId: uint32): bool =
    ## The receiver must first validate and restore the declared job, then
    ## observe the source commit. Only a broker grant may activate the task.
    if client.state != wscHandoffChecked or preparedTaskId == 0: return false
    let task = getWasmTask(preparedTaskId)
    if task.state != wasmTaskMigrating or task.slot < 0 or
        task.slot.uint32 != client.handoffJob.slot or
        task.fuelLimit != client.handoffJob.maxFuel: return false
    var req = client.makeRequest(wsoAcceptHandoff)
    req.jobId = client.handoffClaim.jobId
    req.claimToken = client.handoffClaim.token
    req.hostInterfaceMask = 0
    req.handoffCoreBit = client.handoffSourceCore
    client.handoffTaskId = preparedTaskId
    if not client.sendHandoffRequest(req): client.state = wscHandoffRetry
    true

proc wasmStealExportName*(job: WasmStealJob): string =
  var n = 0
  while n < WasmStealNameBytes and job.exportName[n] != '\0': inc n
  if n == 0 or n == WasmStealNameBytes: return ""
  result = newString(n)
  for i in 0 ..< n: result[i] = job.exportName[i]

when defined(wasmSoftStealing):
  proc translateSoft(client: var WasmStealClient, job: WasmStealJob,
                     spec: var WasmRtSpec): bool =
    if not client.wantsSoft(): return false
    let now = localClockTick()
    let rate = localClockRate()
    var release, deadline, budget, slice: WasmClockInterval
    if job.soft.releaseTick >= job.soft.deadlineTick or
        job.soft.maxSliceTicks == 0 or job.soft.maxSliceTicks > job.soft.budgetTicks or
        not client.correlation.mapWasmClockTick(job.soft.releaseTick, now,
          client.ownerEpoch, client.peerSession, rate, release) or
        not client.correlation.mapWasmClockTick(job.soft.deadlineTick, now,
          client.ownerEpoch, client.peerSession, rate, deadline) or
        not client.correlation.wasmClockDurationBounds(job.soft.budgetTicks, budget) or
        not client.correlation.wasmClockDurationBounds(job.soft.maxSliceTicks, slice):
      return false
    let start = max(now, release.latest)
    if start >= deadline.earliest or budget.latest > deadline.earliest - start or
        slice.latest > budget.earliest:
      return false
    client.softRelease = release.latest
    client.softDeadline = deadline.earliest
    client.softBudget = budget.latest
    client.softTelemetry.maxUncertaintyTicks = max(client.softTelemetry.maxUncertaintyTicks,
      max(release.latest - release.earliest, deadline.latest - deadline.earliest))
    spec = WasmRtSpec(class: wrSoft, releaseTick: release.latest,
      deadlineTick: deadline.earliest, budgetTicks: budget.earliest,
      maxSliceTicks: slice.latest, affinityMask: client.coreBit,
      overrun: job.soft.overrun)
    true

proc prepare(client: var WasmStealClient, job: WasmStealJob,
             memoryFactory: FullMemoryFactory,
             memoryFactoryContext: pointer): StealPreparation =
  let name = job.wasmStealExportName()
  if name.len == 0 or job.argCount > WasmStealMaxArgs or
      not job.compatibleWasmStealJob(client.makeRequest(wsoClaim)):
    return stpRetry
  when defined(wasmSoftStealing):
    client.softDeadline = 0
    var spec: WasmRtSpec
    if job.soft.deadlineTick != 0 and not client.translateSoft(job, spec):
      return stpRetry
  var started: WasmSchedulerResult
  let admission = FullWasmAdmission(enforceMemoryQuota: true,
    requireMemoryFactory: client.coreBit in [WasmStealM0, WasmStealLP],
    allowedHostInterfaces: job.requiredHostInterfaces, hostBindings: client.hostBindings)
  when defined(wasmStealHostTest):
    if wasmStealPrepareHook == nil: return stpRetry
    started = wasmStealPrepareHook(job, admission, memoryFactory, memoryFactoryContext)
  else:
    if job.argCount == 0:
      started = startFullWasmTaskI32(job.slot, name, [],
        maxTotalFuel = job.maxFuel, ownerCore = client.capabilities.core.ord.uint8,
        maxMemoryPages = job.maxMemoryPages,
        memoryFactory = memoryFactory,
        memoryFactoryContext = memoryFactoryContext, requireNoStart = true,
        admission = admission, allowPortableMigration = false, retainTrappedTask = true)
    else:
      started = startFullWasmTaskI32(job.slot, name,
        job.args.toOpenArray(0, job.argCount.int - 1),
        maxTotalFuel = job.maxFuel, ownerCore = client.capabilities.core.ord.uint8,
        maxMemoryPages = job.maxMemoryPages,
        memoryFactory = memoryFactory,
        memoryFactoryContext = memoryFactoryContext, requireNoStart = true,
        admission = admission, allowPortableMigration = false, retainTrappedTask = true)
  if started.managerError == wasmManagerDependencyUnavailable:
    return stpDependencyUnavailable
  if started.status != wasmSchedOk or started.state != wasmTaskReady:
    return stpRetry
  client.taskId = started.id
  client.jobId = job.jobId
  if blockWasmTask(started.id, wasmTaskBlockedIpc).status != wasmSchedOk:
    discard killWasmTask(started.id)
    return stpRetry
  when defined(wasmSoftStealing):
    if client.softDeadline != 0 and
        (not client.softWindowFits() or admitWasmTaskRt(started.id, spec) != wrOk):
      discard killWasmTask(started.id)
      return stpRetry
  stpReady

proc pollWasmSteal*(client: var WasmStealClient,
                    memoryFactory: FullMemoryFactory = nil,
                    memoryFactoryContext: pointer = nil): WasmStealClientState =
  if client.state != wscPending: return client.state
  when defined(bl808m0) and not defined(wasmStealHostTest):
    if not client.localReply: return client.state
    client.localReply = false
  else:
    if client.pendingFuture == nil or not client.pendingFuture.finished: return client.state
    if client.pendingFuture.getError() != nil:
      if client.pendingOp == wsoFinish: client.finishRetry()
      elif client.pendingOp in {wsoAuthorizeHandoff, wsoAcceptHandoff}:
        client.pendingFuture = nil
        client.state = wscHandoffRetry
      else: client.fail()
      return client.state
  var reply: WasmStealResponse
  if client.responseLen != WasmStealResponseBytes or
      not client.responseBuf.decodeWasmStealResponse(reply):
    if client.pendingOp == wsoFinish: client.finishRetry()
    elif client.pendingOp in {wsoAuthorizeHandoff, wsoAcceptHandoff}:
      client.pendingFuture = nil
      client.state = wscHandoffRetry
    else: client.fail()
    return client.state
  let op = client.pendingOp
  client.pendingFuture = nil
  if (op notin {wsoOffer, wsoReadOutcome, wsoAckOutcome, wsoCancel,
                wsoProbeHandoff, wsoCheckHandoff, wsoAuthorizeHandoff, wsoAcceptHandoff} and
       reply.status in {wssStale, wssInvalid}) or
      (op != wsoHello and
       (reply.ownerEpoch != client.ownerEpoch or
        reply.peerSession != client.peerSession)) or
      (op != wsoReadOutcome and reply.outcome.kind != wokNone):
    client.fail()
    return client.state
  case op
  of wsoHello:
    if reply.status != wssOk or reply.ownerEpoch == 0 or
        reply.peerSession == 0:
      client.fail()
    else:
      client.ownerEpoch = reply.ownerEpoch
      client.peerSession = reply.peerSession
      when defined(wasmSoftStealing):
        client.correlation = WasmClockCorrelation()
        if client.wantsSoft():
          let receive = localClockTick()
          let sample = WasmClockSample(localSend: client.probeSend,
            ownerReceive: reply.ownerReceiveTick, ownerSend: reply.ownerSendTick,
            localReceive: receive, localTicksPerUs: client.probeRate,
            ownerTicksPerUs: reply.ownerTicksPerUs, ownerEpoch: reply.ownerEpoch,
            peerSession: reply.peerSession)
          if client.probeRate == localClockRate() and reply.claimToken == client.probeNonce and
              client.correlation.initWasmClockCorrelation(sample, client.clockLimits):
            inc client.softTelemetry.clockSamples
            client.softTelemetry.maxRoundTripTicks = max(client.softTelemetry.maxRoundTripTicks,
              receive - client.probeSend)
          else:
            inc client.softTelemetry.rejectedSamples
      if client.claimAfterHello:
        if not client.send(wsoClaim): client.fail()
      else:
        client.state = wscIdle
  of wsoOffer:
    if reply.claimToken != client.offerTicket or
        (reply.status == wssOk) != (reply.job.jobId != 0):
      client.fail()
    else:
      client.offerStatus = reply.status
      client.offeredJobId = reply.job.jobId
      client.state = wscIdle
  of wsoReadOutcome, wsoAckOutcome, wsoCancel:
    let expectOutcome = op == wsoReadOutcome and reply.status == wssOk
    if reply.job.jobId != client.outcomeJobId or reply.claimToken != 0 or
        (reply.outcome.kind != wokNone) != expectOutcome:
      client.fail()
    else:
      client.outcomeStatus = reply.status
      client.outcome = reply.outcome
      client.state = wscIdle
  of wsoProbeHandoff, wsoCheckHandoff, wsoAuthorizeHandoff, wsoAcceptHandoff:
    when defined(wasmManagedMigration):
      client.handoffStatus = reply.status
      case op
      of wsoProbeHandoff, wsoCheckHandoff:
        if reply.status == wssOk and reply.job.jobId == client.handoffClaim.jobId and
            reply.claimToken == client.handoffClaim.token:
          client.handoffJob = reply.job
          client.state = wscHandoffChecked
        else:
          client.state = wscIdle
      of wsoAuthorizeHandoff:
        if reply.job.jobId != client.jobId or reply.claimToken != client.claimToken:
          client.fail()
        elif reply.status == wssBusy:
          client.state = wscReady
        elif reply.status == wssOk and retireWasmTaskMigration(client.taskId) == wasmMigrationOk:
          client.taskId = 0
          client.jobId = 0
          client.claimToken = 0
          client.state = wscIdle
        else:
          client.fail()
      of wsoAcceptHandoff:
        if reply.status == wssBusy:
          client.state = wscHandoffChecked
        elif reply.status == wssOk and reply.job.jobId == client.handoffClaim.jobId and
            reply.claimToken != 0 and reply.claimToken != client.handoffClaim.token:
          client.taskId = client.handoffTaskId
          client.jobId = reply.job.jobId
          client.claimToken = reply.claimToken
          client.handoffTaskId = 0
          if activateWasmTaskMigration(client.taskId,
              brokerOwnerCore = client.capabilities.core.ord.uint8) == wasmMigrationOk:
            client.state = wscReady
          else:
            discard discardPreparedWasmTaskMigration(client.taskId)
            client.rejectedAfterStart = true
            discard client.sendFinish(WasmStealOutcome(kind: wokTaskLost))
        else:
          client.state = wscHandoffChecked
      else: discard
    else:
      client.fail()
  of wsoClaim:
    if reply.status == wssEmpty:
      client.state = wscNoJob
    elif reply.status != wssOk or reply.claimToken == 0 or
        reply.job.jobId == 0:
      client.fail()
    else:
      client.claimToken = reply.claimToken
      let prepared = when defined(wasmChunkedMemory):
        if client.memoryFactory != nil:
          client.prepare(reply.job, client.memoryFactory, client.memoryFactoryContext)
        else:
          client.prepare(reply.job, memoryFactory, memoryFactoryContext)
      else:
        client.prepare(reply.job, memoryFactory, memoryFactoryContext)
      case prepared
      of stpReady:
        if not client.send(wsoStart): client.fail()
      of stpRetry, stpDependencyUnavailable:
        let decline = prepared == stpDependencyUnavailable
        when defined(wasmSoftStealing):
          if reply.job.soft.deadlineTick != 0: inc client.softTelemetry.rejectedJobs
        if not client.send(if decline: wsoDecline else: wsoRelease): client.fail()
  of wsoStart:
    if reply.status == wssOk and reply.claimToken == client.claimToken and
        reply.job.jobId == client.jobId:
      let usable = when defined(wasmSoftStealing): client.softWindowFits() else: true
      if usable and unblockWasmTask(client.taskId).status == wasmSchedOk:
        client.state = wscReady
      else:
        # Ownership has already transferred. Report a terminal job rather
        # than putting it back into the unstarted queue.
        when defined(wasmSoftStealing):
          if client.softDeadline != 0: inc client.softTelemetry.rejectedJobs
        discard killWasmTask(client.taskId)
        client.rejectedAfterStart = true
        let kind = when defined(wasmSoftStealing):
          (if not usable: wokAdmissionExpired else: wokTaskLost)
        else: wokTaskLost
        discard client.sendFinish(WasmStealOutcome(kind: kind))
    else:
      client.fail()
  of wsoRelease:
    client.fail()
  of wsoDecline:
    if reply.status == wssOk and reply.claimToken == client.claimToken:
      client.claimToken = 0
      client.state = wscNoJob
    else:
      client.fail()
  of wsoFinish:
    if reply.status == wssOk and reply.claimToken == client.claimToken and
        reply.job.jobId == client.jobId:
      if client.rejectedAfterStart:
        client.fail()
        return client.state
      client.taskId = 0
      client.jobId = 0
      client.claimToken = 0
      client.state = wscIdle
    else:
      client.fail()
  client.state

proc finishWasmSteal*(client: var WasmStealClient): bool =
  ## Capture a terminal local result or retry the same finish after an
  ## ambiguous reply. On retry the task can already have been reaped.
  if client.state == wscFinishRetry:
    client.state = wscPending
    if client.exchange(client.requestBuf): return true
    client.finishRetry()
    return false
  if client.state != wscReady or client.taskId == 0: return false
  let task = getWasmTask(client.taskId)
  var outcome = WasmStealOutcome(fuelUsed: task.fuelUsed)
  case task.state
  of wasmTaskExited:
    outcome.kind = wokReturned
    outcome.detail = cast[uint32](task.result)
  of wasmTaskTrapped:
    outcome.kind = wokTrapped
    outcome.detail = task.trapCode
  of wasmTaskKilled:
    outcome.kind = wokKilled
  else:
    if task.status != wasmSchedNoTask: return false
    outcome.kind = wokTaskLost
  client.sendFinish(outcome)
