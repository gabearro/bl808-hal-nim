## M0-owned admission queue for *unstarted* full-VM jobs. Requests and replies
## travel through the existing bounded XRAM ipcbridge slots. Only the owner
## mutates this table; no cross-core atomic operation or native stack move is
## required. A thief must prepare its local wasm_scheduler task and receive a
## successful start acknowledgement before it executes one guest instruction.
##
## Soft jobs require a clock-qualified worker. Hard reservations stay local.

import ./wasm_runtime
when defined(wasmSoftStealing):
  import ./[wasm_rt_clock, wasm_rt_policy]

const
  WasmStealWireTag* = 0x5753'u16
  WasmStealWireMagic* = 0x5357'u16
  WasmStealWireVersion* = when defined(wasmSoftStealing): 10'u8 else: 9'u8
  WasmStealRequestBytes* = 40
  WasmStealResponseBytes* = when defined(wasmSoftStealing): 160 else: 104
  WasmStealMaxJobs* {.intdefine.} = 8
  WasmStealNameBytes* = 32
  WasmStealMaxArgs* = 4
  WasmStealM0* = 1'u32
  WasmStealD0* = 2'u32
  WasmStealLP* = 4'u32
  WasmStealAllCores* = WasmStealM0 or WasmStealD0 or WasmStealLP
  WasmStealDirectPsram* = 1'u16 shl 0
  WasmStealPagedBacking* = 1'u16 shl 1
  WasmStealDirectSd* = 1'u16 shl 2
  WasmStealApplicationResources* = 0xFF00'u16
    ## Firmware images agree on the meaning of bits 8–15. Workers advertise
    ## them only for initialized dependencies available on that worker.
  WasmStealResourceMask* = WasmStealDirectPsram or WasmStealPagedBacking or
    WasmStealDirectSd or WasmStealApplicationResources

when defined(wasmSoftStealing):
  type WasmStealSoftSpec* = object
    ## Absolute M0 release/deadline and durations in M0 ticks.
    releaseTick*, deadlineTick*, budgetTicks*, maxSliceTicks*: uint64
    overrun*: WasmRtOverrun

type
  WasmStealOp* = enum
    wsoHello = 1
    wsoClaim = 2
    wsoStart = 3
    wsoRelease = 4
    wsoFinish = 5
    wsoDecline = 6
    wsoOffer = 7
    wsoReadOutcome = 8
    wsoAckOutcome = 9
    wsoCancel = 10
    wsoCheckHandoff = 11
    wsoAuthorizeHandoff = 12
    wsoAcceptHandoff = 13
    wsoProbeHandoff = 14

  WasmStealStatus* = enum
    wssOk = 0
    wssEmpty = 1
    wssInvalid = 2
    wssStale = 3
    wssNoCapacity = 4
    wssBusy = 5

  WasmStealState* = enum
    wstEmpty
    wstQueued
    wstClaimed
    wstStarted
    wstComplete
    wstHandoff

  WasmStealOutcomeKind* = enum
    wokNone
    wokReturned
    wokTrapped
    wokKilled
    wokTaskLost
    wokAdmissionExpired
    wokDeadline
    wokWorkerStopped
    wokCanceled

  WasmStealOutcome* = object
    kind*: WasmStealOutcomeKind
    detail*: uint32  ## i32 return bits or a trap code, according to kind.
    fuelUsed*: uint32
    workerCoreBit*: uint32

  WasmStealJob* = object
    jobId*: uint32
    sourceCoreBit*: uint32
    slot*: uint32
    exportName*: array[WasmStealNameBytes, char]
    argCount*: uint8
    args*: array[WasmStealMaxArgs, int32]
    affinityMask*: uint32
    requiredBackends*: uint32
    requiredHostInterfaces*: uint32
    requiredResources*: uint16
    maxMemoryPages*: uint32
    maxFuel*: uint32
    when defined(wasmSoftStealing):
      soft*: WasmStealSoftSpec

  WasmStealRequest* = object
    op*: WasmStealOp
    ownerEpoch*: uint32
    peerBootId*: uint32
    peerSession*: uint32
    peerCoreBit*: uint32
    claimToken*: uint32
    jobId*: uint32
    outcome*: WasmStealOutcome
    handoffCoreBit*: uint32
    handoffSession*: uint32
    handoffFuelUsed*: uint32
    backendMask*: uint32
    hostInterfaceMask*: uint32
    maxMemoryPages*: uint32
    resourceMask*: uint16
    fullInterpreter*: bool
    when defined(wasmSoftStealing):
      acceptSoft*: bool

  WasmStealResponse* = object
    status*: WasmStealStatus
    ownerEpoch*: uint32
    peerSession*: uint32
    claimToken*: uint32
    job*: WasmStealJob
    outcome*: WasmStealOutcome
    when defined(wasmSoftStealing):
      ownerReceiveTick*, ownerSendTick*: uint64
      ownerTicksPerUs*: uint32

  WasmStealTelemetry* = object
    offered*: uint32
    claims*: uint32
    starts*: uint32
    completed*: uint32
    leaseRequeues*: uint32
    peerResetRequeues*: uint32
    staleRequests*: uint32
    operatorRetirements*: uint32
    dependencyDeclines*: uint32
    acknowledgedOutcomes*: uint32
    abandonedOffers*: uint32
    handoffsAuthorized*: uint32
    handoffsAccepted*: uint32
    when defined(wasmSoftStealing):
      expiredSoftJobs*: uint32

  WasmStealClock* = proc(): uint64 {.nimcall.}

  WasmStealHandoff = object
    sourceCoreBit, sourceSession, sourceToken: uint32
    targetCoreBit, targetSession, fuelUsed: uint32

  WasmStealEntry = object
    state: WasmStealState
    job: WasmStealJob
    sequence: uint32
    sourceSession: uint32
    outcome: WasmStealOutcome
    claimantCoreBit: uint32
    claimantSession: uint32
    claimToken: uint32
    leaseUntil: uint64
    declinedCoreMask: uint32
    handoff: WasmStealHandoff
    migratedFuelUsed: uint32

  WasmStealPeer = object
    bootId: uint32
    session: uint32
    lastOfferTicket: uint32
    lastOfferedJobId: uint32
    lastAcknowledgedJobId: uint32
    lastFinishToken: uint32
    lastFinishedJobId: uint32
    lastFinishOutcome: WasmStealOutcome

  WasmStealBroker* = object
    ownerEpoch*: uint32
    leaseTicks*: uint64
    nextJobId: uint32
    nextToken: uint32
    sequence: uint32
    peers: array[3, WasmStealPeer]
    entries: array[WasmStealMaxJobs, WasmStealEntry]
    telemetry*: WasmStealTelemetry

proc put16(buf: var openArray[byte], at: int, v: uint16) {.inline.} =
  buf[at] = v.byte
  buf[at + 1] = (v shr 8).byte

proc put32(buf: var openArray[byte], at: int, v: uint32) {.inline.} =
  for i in 0 ..< 4: buf[at + i] = (v shr (i * 8)).byte

proc get16(buf: openArray[byte], at: int): uint16 {.inline.} =
  buf[at].uint16 or (buf[at + 1].uint16 shl 8)

proc get32(buf: openArray[byte], at: int): uint32 {.inline.} =
  for i in 0 ..< 4: result = result or (buf[at + i].uint32 shl (i * 8))

proc validCoreBit(bit: uint32): bool {.inline.} =
  bit == WasmStealM0 or bit == WasmStealD0 or bit == WasmStealLP

proc validWorkerOutcome(value: WasmStealOutcome): bool =
  case value.kind
  of wokReturned, wokTrapped: true
  of wokKilled: value.detail == 0
  of wokTaskLost, wokAdmissionExpired: value.detail == 0 and value.fuelUsed == 0
  else: false

proc returnedI32*(outcome: WasmStealOutcome): int32 =
  doAssert outcome.kind == wokReturned
  cast[int32](outcome.detail)

when defined(wasmSoftStealing):
  proc put64(buf: var openArray[byte], at: int, v: uint64) {.inline.} =
    buf.put32(at, v.uint32)
    buf.put32(at + 4, (v shr 32).uint32)

  proc get64(buf: openArray[byte], at: int): uint64 {.inline.} =
    buf.get32(at).uint64 or (buf.get32(at + 4).uint64 shl 32)

proc encodeWasmStealRequest*(req: WasmStealRequest,
                             outBuf: var openArray[byte]): int =
  if outBuf.len < WasmStealRequestBytes or req.op == wsoOffer: return 0
  for i in 0 ..< WasmStealRequestBytes: outBuf[i] = 0
  outBuf.put16(0, WasmStealWireMagic)
  outBuf[2] = WasmStealWireVersion
  outBuf[3] = req.op.ord.byte
  outBuf.put32(4, req.ownerEpoch)
  outBuf.put32(8, req.peerBootId)
  outBuf.put32(12, req.peerSession)
  outBuf.put32(16, req.peerCoreBit)
  outBuf.put32(20, req.claimToken)
  if req.op == wsoFinish:
    if req.jobId == 0 or req.claimToken == 0 or not req.outcome.validWorkerOutcome(): return 0
    outBuf.put32(24, req.jobId)
    outBuf.put32(28, req.outcome.detail)
    outBuf.put32(32, req.outcome.fuelUsed)
    outBuf[36] = req.outcome.kind.ord.byte
    return WasmStealRequestBytes
  if req.op in {wsoReadOutcome, wsoAckOutcome, wsoCancel}:
    if req.jobId == 0 or req.claimToken != 0: return 0
    outBuf.put32(24, req.jobId)
    return WasmStealRequestBytes
  if req.op == wsoAuthorizeHandoff:
    if req.jobId == 0 or req.claimToken == 0 or req.handoffSession == 0 or
        not validCoreBit(req.handoffCoreBit): return 0
    outBuf.put32(24, req.jobId)
    outBuf.put32(28, req.handoffCoreBit)
    outBuf.put32(32, req.handoffSession)
    outBuf.put32(36, req.handoffFuelUsed)
    return WasmStealRequestBytes
  if req.op in {wsoProbeHandoff, wsoCheckHandoff, wsoAcceptHandoff}:
    # Currently only import-free core guests can cross a suspension point.
    if req.jobId == 0 or req.claimToken == 0 or req.hostInterfaceMask != 0 or
        not validCoreBit(req.handoffCoreBit): return 0
    outBuf.put32(24, req.jobId)
    outBuf.put32(28, req.backendMask)
    outBuf.put32(32, req.maxMemoryPages)
    outBuf[36] = req.fullInterpreter.byte
    outBuf[37] = req.handoffCoreBit.byte
    outBuf.put16(38, req.resourceMask)
    return WasmStealRequestBytes
  outBuf.put32(24, req.backendMask)
  outBuf.put32(28, req.hostInterfaceMask)
  outBuf.put32(32, req.maxMemoryPages)
  outBuf[36] = if req.fullInterpreter: 1'u8 else: 0'u8
  when defined(wasmSoftStealing):
    outBuf[37] = req.acceptSoft.byte
  outBuf.put16(38, req.resourceMask)
  WasmStealRequestBytes

proc decodeWasmStealRequest*(buf: openArray[byte],
                             req: var WasmStealRequest): bool =
  if buf.len != WasmStealRequestBytes or
      buf.get16(0) != WasmStealWireMagic or
      buf[2] != WasmStealWireVersion or
      buf[3] < wsoHello.ord.byte or buf[3] > wsoProbeHandoff.ord.byte or
      buf[3] == wsoOffer.ord.byte:
    return false
  req = WasmStealRequest(op: WasmStealOp(buf[3]), ownerEpoch: buf.get32(4),
    peerBootId: buf.get32(8), peerSession: buf.get32(12),
    peerCoreBit: buf.get32(16), claimToken: buf.get32(20))
  if req.op == wsoFinish:
    if req.claimToken == 0 or buf.get32(24) == 0 or buf[36] > wokCanceled.ord.byte or
        buf[37] != 0 or buf.get16(38) != 0:
      return false
    req.jobId = buf.get32(24)
    req.outcome = WasmStealOutcome(kind: WasmStealOutcomeKind(buf[36]),
      detail: buf.get32(28), fuelUsed: buf.get32(32))
    return req.outcome.validWorkerOutcome()
  if req.op in {wsoReadOutcome, wsoAckOutcome, wsoCancel}:
    req.jobId = buf.get32(24)
    return req.jobId != 0 and req.claimToken == 0 and buf.get32(28) == 0 and
      buf.get32(32) == 0 and buf.get32(36) == 0
  if req.op == wsoAuthorizeHandoff:
    req.jobId = buf.get32(24)
    req.handoffCoreBit = buf.get32(28)
    req.handoffSession = buf.get32(32)
    req.handoffFuelUsed = buf.get32(36)
    return req.jobId != 0 and req.claimToken != 0 and req.handoffSession != 0 and
      validCoreBit(req.handoffCoreBit)
  if req.op in {wsoProbeHandoff, wsoCheckHandoff, wsoAcceptHandoff}:
    if buf[36] > 1 or not validCoreBit(buf[37].uint32) or
        (buf.get16(38) and not WasmStealResourceMask) != 0:
      return false
    req.jobId = buf.get32(24)
    req.backendMask = buf.get32(28)
    req.maxMemoryPages = buf.get32(32)
    req.resourceMask = buf.get16(38)
    req.fullInterpreter = buf[36] == 1
    req.handoffCoreBit = buf[37].uint32
    return req.jobId != 0 and req.claimToken != 0
  if buf[36] > 1 or (buf.get16(38) and not WasmStealResourceMask) != 0:
    return false
  when defined(wasmSoftStealing):
    if buf[37] > 1 or (buf[37] != 0 and buf[3] notin {wsoHello.ord.byte, wsoClaim.ord.byte}):
      return false
  else:
    if buf[37] != 0: return false
  req.backendMask = buf.get32(24)
  req.hostInterfaceMask = buf.get32(28)
  req.maxMemoryPages = buf.get32(32)
  req.resourceMask = buf.get16(38)
  req.fullInterpreter = buf[36] == 1
  when defined(wasmSoftStealing):
    req.acceptSoft = buf[37] == 1
  true

proc encodeWasmStealResponse*(resp: WasmStealResponse,
                              outBuf: var openArray[byte]): int =
  if outBuf.len < WasmStealResponseBytes: return 0
  for i in 0 ..< WasmStealResponseBytes: outBuf[i] = 0
  outBuf.put16(0, WasmStealWireMagic)
  outBuf[2] = WasmStealWireVersion
  outBuf[3] = resp.status.ord.byte
  outBuf.put32(4, resp.ownerEpoch)
  outBuf.put32(8, resp.peerSession)
  outBuf.put32(12, resp.claimToken)
  outBuf.put32(16, resp.job.jobId)
  if resp.outcome.kind != wokNone:
    outBuf[25] = resp.outcome.kind.ord.byte
    outBuf.put32(28, resp.outcome.detail)
    outBuf.put32(32, resp.outcome.fuelUsed)
    outBuf.put32(36, resp.outcome.workerCoreBit)
    return WasmStealResponseBytes
  outBuf.put32(20, resp.job.slot)
  outBuf[24] = resp.job.argCount
  outBuf.put32(28, resp.job.affinityMask)
  outBuf.put32(32, resp.job.requiredBackends)
  outBuf.put32(36, resp.job.requiredHostInterfaces)
  outBuf.put32(40, resp.job.maxMemoryPages)
  outBuf.put32(44, resp.job.maxFuel)
  for i in 0 ..< WasmStealNameBytes:
    outBuf[48 + i] = resp.job.exportName[i].byte
  for i in 0 ..< WasmStealMaxArgs:
    outBuf.put32(80 + i * 4, cast[uint32](resp.job.args[i]))
  outBuf.put32(WasmStealResponseBytes - 8, resp.job.sourceCoreBit)
  outBuf.put16(WasmStealResponseBytes - 4, resp.job.requiredResources)
  when defined(wasmSoftStealing):
    outBuf.put64(96, resp.job.soft.releaseTick)
    outBuf.put64(104, resp.job.soft.deadlineTick)
    outBuf.put64(112, resp.job.soft.budgetTicks)
    outBuf.put64(120, resp.job.soft.maxSliceTicks)
    outBuf.put64(128, resp.ownerReceiveTick)
    outBuf.put64(136, resp.ownerSendTick)
    outBuf.put32(144, resp.ownerTicksPerUs)
    outBuf[148] = resp.job.soft.overrun.ord.byte
  WasmStealResponseBytes

proc decodeStealEnvelope(buf: openArray[byte], resp: var WasmStealResponse,
                         maxStatus: uint8): bool =
  if buf.len != WasmStealResponseBytes or
      buf.get16(0) != WasmStealWireMagic or
      buf[2] != WasmStealWireVersion or
      buf[3] > maxStatus or buf[24] > WasmStealMaxArgs or
      buf[25] != 0 or buf[26] != 0 or buf[27] != 0 or
      (buf.get16(WasmStealResponseBytes - 4) and not WasmStealResourceMask) != 0 or
      buf.get16(WasmStealResponseBytes - 2) != 0:
    return false
  resp = WasmStealResponse(ownerEpoch: buf.get32(4), peerSession: buf.get32(8),
    claimToken: buf.get32(12))
  resp.job.jobId = buf.get32(16)
  resp.job.sourceCoreBit = buf.get32(WasmStealResponseBytes - 8)
  resp.job.requiredResources = buf.get16(WasmStealResponseBytes - 4)
  resp.job.slot = buf.get32(20)
  resp.job.argCount = buf[24]
  resp.job.affinityMask = buf.get32(28)
  resp.job.requiredBackends = buf.get32(32)
  resp.job.requiredHostInterfaces = buf.get32(36)
  resp.job.maxMemoryPages = buf.get32(40)
  resp.job.maxFuel = buf.get32(44)
  for i in 0 ..< WasmStealNameBytes:
    resp.job.exportName[i] = buf[48 + i].char
  for i in 0 ..< WasmStealMaxArgs:
    resp.job.args[i] = cast[int32](buf.get32(80 + i * 4))
  when defined(wasmSoftStealing):
    if buf[148] > wrStop.ord.byte or buf[149] != 0 or buf[150] != 0 or buf[151] != 0:
      return false
    resp.job.soft = WasmStealSoftSpec(releaseTick: buf.get64(96), deadlineTick: buf.get64(104),
      budgetTicks: buf.get64(112), maxSliceTicks: buf.get64(120), overrun: WasmRtOverrun(buf[148]))
    resp.ownerReceiveTick = buf.get64(128)
    resp.ownerSendTick = buf.get64(136)
    resp.ownerTicksPerUs = buf.get32(144)
  true

proc decodeWasmStealResponse*(buf: openArray[byte],
                             resp: var WasmStealResponse): bool =
  if buf.len != WasmStealResponseBytes: return false
  if buf[25] != 0:
    if buf.get16(0) != WasmStealWireMagic or buf[2] != WasmStealWireVersion or
        buf[3] != wssOk.ord.byte or buf[25] > wokCanceled.ord.byte or
        buf.get32(12) != 0 or buf.get32(16) == 0:
      return false
    for i in 20 ..< buf.len:
      if i != 25 and (i < 28 or i >= 40) and buf[i] != 0: return false
    let kind = WasmStealOutcomeKind(buf[25])
    let core = buf.get32(36)
    let value = WasmStealOutcome(kind: kind, detail: buf.get32(28),
      fuelUsed: buf.get32(32), workerCoreBit: core)
    if kind in {wokCanceled, wokDeadline}:
      if core != 0 or value.detail != 0 or value.fuelUsed != 0: return false
    elif not validCoreBit(core) or
        (kind == wokWorkerStopped and (value.detail != 0 or value.fuelUsed != 0)) or
        (kind != wokWorkerStopped and not value.validWorkerOutcome()):
      return false
    resp = WasmStealResponse(ownerEpoch: buf.get32(4), peerSession: buf.get32(8),
      job: WasmStealJob(jobId: buf.get32(16)), outcome: value)
    return true
  if not buf.decodeStealEnvelope(resp, wssBusy.ord.byte): return false
  resp.status = WasmStealStatus(buf[3])
  true

proc encodeWasmStealOffer*(req: WasmStealRequest, job: WasmStealJob,
                          outBuf: var openArray[byte]): int =
  ## Reuse the job envelope and the worker's reply buffer. The transport
  ## consumes the request bytes before it can write its reply.
  if req.op != wsoOffer or req.claimToken == 0 or
      job.jobId != 0 or job.sourceCoreBit != 0:
    return 0
  var envelope = WasmStealResponse(ownerEpoch: req.ownerEpoch,
    peerSession: req.peerSession, claimToken: req.claimToken, job: job)
  envelope.job.jobId = req.peerBootId
  envelope.job.sourceCoreBit = req.peerCoreBit
  result = envelope.encodeWasmStealResponse(outBuf)
  if result != 0: outBuf[3] = wsoOffer.ord.byte

proc wasmStealCoreBit*(core: WasmRuntimeCore): uint32 =
  case core
  of wasmCoreM0: WasmStealM0
  of wasmCoreD0: WasmStealD0
  of wasmCoreLP: WasmStealLP
  else: 0

proc wasmStealResourcesAllowed*(coreBit: uint32, mask: uint16): bool =
  validCoreBit(coreBit) and (mask and not WasmStealResourceMask) == 0 and
    ((mask and WasmStealDirectPsram) == 0 or coreBit != WasmStealLP) and
    ((mask and WasmStealDirectSd) == 0 or coreBit == WasmStealM0)

proc coreIndex(bit: uint32): int {.inline.} =
  if bit == 1: 0 elif bit == 2: 1 else: 2

proc nextNonzero(value: var uint32): uint32 {.inline.} =
  inc value
  if value == 0: inc value
  value

proc initWasmStealBroker*(broker: var WasmStealBroker,
                          ownerEpoch: uint32, leaseTicks: uint64): bool =
  if ownerEpoch == 0 or leaseTicks == 0: return false
  broker = WasmStealBroker(ownerEpoch: ownerEpoch, leaseTicks: leaseTicks)
  true

proc validJob(job: WasmStealJob): bool =
  if job.argCount > WasmStealMaxArgs or job.affinityMask == 0 or
      (job.affinityMask and not WasmStealAllCores) != 0 or job.maxFuel == 0 or
      (job.requiredResources and not WasmStealResourceMask) != 0 or
      (job.requiredBackends and WasmBackendInterpreter) == 0 or
      job.exportName[0] == '\0': return false
  var hasEligibleCore = false
  for bit in [WasmStealM0, WasmStealD0, WasmStealLP]:
    if (job.affinityMask and bit) != 0 and
        wasmStealResourcesAllowed(bit, job.requiredResources):
      hasEligibleCore = true
      break
  if not hasEligibleCore: return false
  when defined(wasmSoftStealing):
    let spec = job.soft
    if spec.deadlineTick != 0:
      if spec.releaseTick >= spec.deadlineTick or
          spec.maxSliceTicks == 0 or spec.maxSliceTicks > spec.budgetTicks or
          spec.budgetTicks > spec.deadlineTick - spec.releaseTick:
        return false
    elif spec != WasmStealSoftSpec():
      return false
  for i in 0 ..< WasmStealNameBytes:
    if job.exportName[i] == '\0': return true
  false

proc enqueue(broker: var WasmStealBroker, job: WasmStealJob,
             sourceBit, sourceSession: uint32, outId: var uint32): WasmStealStatus =
  ## The job is portable input only: a flash slot, export, and scalar args.
  ## No VM instance, native stack, WIT resource, or writable memory is shared.
  if broker.ownerEpoch == 0 or not validJob(job) or job.jobId != 0 or
      job.sourceCoreBit != 0:
    return wssInvalid
  for entry in broker.entries.mitems:
    if entry.state == wstEmpty:
      var offered = job
      offered.jobId = broker.nextJobId.nextNonzero()
      offered.sourceCoreBit = sourceBit
      broker.sequence = broker.sequence.nextNonzero()
      entry = WasmStealEntry(state: wstQueued, job: offered,
        sequence: broker.sequence, sourceSession: sourceSession)
      outId = offered.jobId
      inc broker.telemetry.offered
      return wssOk
  wssNoCapacity

proc offerWasmStealJob*(broker: var WasmStealBroker, job: WasmStealJob,
                        outId: var uint32): WasmStealStatus =
  ## Local fire-and-forget offer. Sources that need outcomes use wsoOffer.
  broker.enqueue(job, WasmStealM0, 0, outId)

proc requeueClaim(entry: var WasmStealEntry) =
  entry.state = wstQueued
  entry.claimantCoreBit = 0
  entry.claimantSession = 0
  entry.claimToken = 0
  entry.leaseUntil = 0

proc storeOutcome(entry: var WasmStealEntry, outcome: WasmStealOutcome) =
  if entry.sourceSession == 0:
    entry = WasmStealEntry()
  else:
    entry.state = wstComplete
    entry.outcome = outcome
    entry.claimToken = 0
    entry.leaseUntil = 0

proc reapWasmStealLeases*(broker: var WasmStealBroker, now: uint64) =
  for entry in broker.entries.mitems:
    when defined(wasmSoftStealing):
      if entry.state in {wstQueued, wstClaimed} and
          entry.job.soft.deadlineTick != 0 and entry.job.soft.deadlineTick <= now:
        entry.storeOutcome(WasmStealOutcome(kind: wokDeadline))
        inc broker.telemetry.expiredSoftJobs
        continue
    if entry.state == wstClaimed and now >= entry.leaseUntil:
      entry.requeueClaim()
      inc broker.telemetry.leaseRequeues

proc compatibleWasmStealJob*(job: WasmStealJob, req: WasmStealRequest): bool =
  req.fullInterpreter and (job.affinityMask and req.peerCoreBit) != 0 and
    (job.requiredBackends and req.backendMask) == job.requiredBackends and
    (job.requiredHostInterfaces and req.hostInterfaceMask) ==
      job.requiredHostInterfaces and
    wasmStealResourcesAllowed(req.peerCoreBit, req.resourceMask) and
    (job.requiredResources and req.resourceMask) == job.requiredResources and
    job.maxMemoryPages <= req.maxMemoryPages

proc processOutcomeRequest(broker: var WasmStealBroker, peer: int,
                            req: WasmStealRequest, reply: var WasmStealResponse) =
  reply.job.jobId = req.jobId
  if req.jobId == 0:
    reply.status = wssInvalid
    return
  if req.op == wsoAckOutcome and broker.peers[peer].lastAcknowledgedJobId == req.jobId:
    return
  for entry in broker.entries.mitems:
    if entry.state == wstEmpty or entry.job.jobId != req.jobId or
        entry.job.sourceCoreBit != req.peerCoreBit or entry.sourceSession != req.peerSession:
      continue
    if req.op == wsoCancel:
      case entry.state
      of wstQueued, wstClaimed:
        entry.storeOutcome(WasmStealOutcome(kind: wokCanceled))
      of wstComplete:
        if entry.outcome.kind != wokCanceled: reply.status = wssBusy
      else:
        reply.status = wssBusy
    elif entry.state != wstComplete:
      reply.status = wssEmpty
    elif req.op == wsoReadOutcome:
      reply.outcome = entry.outcome
    else:
      broker.peers[peer].lastAcknowledgedJobId = req.jobId
      entry = WasmStealEntry()
      inc broker.telemetry.acknowledgedOutcomes
    return
  reply.status = wssStale
  inc broker.telemetry.staleRequests

proc processFinish(broker: var WasmStealBroker, peer: int, req: WasmStealRequest,
                   reply: var WasmStealResponse) =
  if req.jobId == 0 or req.claimToken == 0 or not req.outcome.validWorkerOutcome():
    reply.status = wssInvalid
    return
  var outcome = req.outcome
  outcome.workerCoreBit = req.peerCoreBit
  let worker = addr broker.peers[peer]
  if req.claimToken == worker.lastFinishToken and req.jobId == worker.lastFinishedJobId:
    if outcome != worker.lastFinishOutcome:
      reply.status = wssInvalid
    else:
      reply.job.jobId = req.jobId
      reply.claimToken = req.claimToken
    return
  for entry in broker.entries.mitems:
    if entry.state != wstStarted or entry.job.jobId != req.jobId or
        entry.claimToken != req.claimToken or entry.claimantCoreBit != req.peerCoreBit or
        entry.claimantSession != req.peerSession:
      continue
    if outcome.fuelUsed > entry.job.maxFuel or
        (outcome.kind in {wokReturned, wokTrapped, wokKilled} and
         outcome.fuelUsed < entry.migratedFuelUsed):
      reply.status = wssInvalid
      return
    worker.lastFinishToken = req.claimToken
    worker.lastFinishedJobId = req.jobId
    worker.lastFinishOutcome = outcome
    entry.storeOutcome(outcome)
    reply.job.jobId = req.jobId
    reply.claimToken = req.claimToken
    inc broker.telemetry.completed
    return
  reply.status = wssStale
  inc broker.telemetry.staleRequests

proc transferable(job: WasmStealJob): bool =
  if job.requiredHostInterfaces != 0: return false
  when defined(wasmSoftStealing):
    if job.soft.deadlineTick != 0: return false
  true

proc processHandoff(broker: var WasmStealBroker, req: WasmStealRequest,
                   reply: var WasmStealResponse) =
  reply.job.jobId = req.jobId
  if req.jobId == 0 or req.claimToken == 0:
    reply.status = wssInvalid
    return
  for entry in broker.entries.mitems:
    if entry.state notin {wstStarted, wstHandoff} or entry.job.jobId != req.jobId:
      continue
    if not entry.job.transferable():
      reply.status = wssInvalid
      return
    let handoff = entry.handoff
    case req.op
    of wsoProbeHandoff, wsoCheckHandoff:
      if entry.state != wstStarted or entry.claimToken != req.claimToken or
          entry.claimantCoreBit == req.peerCoreBit or entry.claimantCoreBit != req.handoffCoreBit or
          broker.peers[entry.claimantCoreBit.coreIndex()].session != entry.claimantSession:
        break
      if not entry.job.compatibleWasmStealJob(req):
        reply.status = wssInvalid
        return
      if req.op == wsoCheckHandoff:
        entry.handoff = WasmStealHandoff(sourceCoreBit: entry.claimantCoreBit,
          sourceSession: entry.claimantSession, sourceToken: entry.claimToken,
          targetCoreBit: req.peerCoreBit, targetSession: req.peerSession)
      reply.job = entry.job
      reply.claimToken = req.claimToken
      return
    of wsoAuthorizeHandoff:
      let matchesPrepared = handoff.sourceToken == req.claimToken and
        handoff.sourceCoreBit == req.peerCoreBit and
        handoff.sourceSession == req.peerSession and handoff.targetCoreBit == req.handoffCoreBit and
        handoff.targetSession == req.handoffSession and handoff.targetSession != 0
      if not matchesPrepared: break
      if entry.state == wstStarted and entry.claimToken == req.claimToken and
          entry.claimantCoreBit == req.peerCoreBit and entry.claimantSession == req.peerSession:
        if broker.peers[handoff.targetCoreBit.coreIndex()].session != handoff.targetSession:
          # The obsolete session cannot receive a later retry of this handoff.
          reply.status = wssBusy
          reply.claimToken = req.claimToken
          return
        if req.handoffFuelUsed < entry.migratedFuelUsed or
            req.handoffFuelUsed >= entry.job.maxFuel:
          reply.status = wssInvalid
          return
        entry.handoff.fuelUsed = req.handoffFuelUsed
        entry.state = wstHandoff
        inc broker.telemetry.handoffsAuthorized
      elif handoff.fuelUsed != req.handoffFuelUsed:
        break
      reply.claimToken = req.claimToken
      return
    of wsoAcceptHandoff:
      if handoff.sourceToken != req.claimToken or handoff.targetCoreBit != req.peerCoreBit or
          handoff.targetSession != req.peerSession or handoff.sourceCoreBit != req.handoffCoreBit:
        break
      if not entry.job.compatibleWasmStealJob(req):
        reply.status = wssInvalid
        return
      if entry.state == wstHandoff:
        entry.claimantCoreBit = req.peerCoreBit
        entry.claimantSession = req.peerSession
        entry.claimToken = broker.nextToken.nextNonzero()
        entry.migratedFuelUsed = handoff.fuelUsed
        entry.state = wstStarted
        inc broker.telemetry.handoffsAccepted
      elif entry.claimantCoreBit != req.peerCoreBit or
          entry.claimantSession != req.peerSession or entry.claimToken == req.claimToken:
        reply.status = wssBusy
        return
      reply.job = entry.job
      reply.claimToken = entry.claimToken
      return
    else:
      break
  reply.status = wssStale
  inc broker.telemetry.staleRequests

proc processWasmSteal*(broker: var WasmStealBroker,
                       req: WasmStealRequest, now: uint64,
                       offeredJob = WasmStealJob()): WasmStealResponse =
  result.ownerEpoch = broker.ownerEpoch
  if broker.ownerEpoch == 0 or not validCoreBit(req.peerCoreBit) or
      req.peerBootId == 0:
    result.status = wssInvalid
    return
  let peer = req.peerCoreBit.coreIndex()
  if req.op == wsoHello:
    if broker.peers[peer].bootId != req.peerBootId or
        broker.peers[peer].session == 0:
      for entry in broker.entries.mitems:
        entry.declinedCoreMask = entry.declinedCoreMask and not req.peerCoreBit
        if entry.job.sourceCoreBit == req.peerCoreBit and entry.sourceSession != 0:
          if entry.state in {wstStarted, wstHandoff}:
            # Keep the worker's claim until it finishes or is confirmed stopped.
            entry.sourceSession = 0
          else:
            entry = WasmStealEntry()
          inc broker.telemetry.abandonedOffers
        if entry.state == wstHandoff and entry.handoff.targetCoreBit == req.peerCoreBit:
          # Authorization is irrevocable. The exact boot that staged the
          # snapshot disappeared before it could take ownership.
          entry.storeOutcome(WasmStealOutcome(kind: wokWorkerStopped,
            workerCoreBit: req.peerCoreBit))
        if entry.state == wstClaimed and
            entry.claimantCoreBit == req.peerCoreBit:
          entry.requeueClaim()
          inc broker.telemetry.peerResetRequeues
      broker.peers[peer] = WasmStealPeer(bootId: req.peerBootId,
        session: broker.nextToken.nextNonzero())
    result.peerSession = broker.peers[peer].session
    return
  if req.ownerEpoch != broker.ownerEpoch or
      req.peerSession == 0 or
      req.peerSession != broker.peers[peer].session or
      req.peerBootId != broker.peers[peer].bootId:
    result.status = wssStale
    inc broker.telemetry.staleRequests
    return
  result.peerSession = req.peerSession
  broker.reapWasmStealLeases(now)
  case req.op
  of wsoOffer:
    let peerInfo = addr broker.peers[peer]
    result.claimToken = req.claimToken
    if req.claimToken == 0:
      result.status = wssInvalid
      return
    if req.claimToken == peerInfo.lastOfferTicket:
      result.job.jobId = peerInfo.lastOfferedJobId
      return
    if req.claimToken < peerInfo.lastOfferTicket:
      result.status = wssStale
      inc broker.telemetry.staleRequests
      return
    when defined(wasmSoftStealing):
      if offeredJob.soft.deadlineTick != 0 and offeredJob.soft.deadlineTick <= now:
        result.status = wssInvalid
        return
    result.status = broker.enqueue(offeredJob, req.peerCoreBit, req.peerSession,
      result.job.jobId)
    if result.status == wssOk:
      peerInfo.lastOfferTicket = req.claimToken
      peerInfo.lastOfferedJobId = result.job.jobId
  of wsoClaim:
    var selected = -1
    var bestSeq = high(uint32)
    when defined(wasmSoftStealing):
      var bestDeadline = 0'u64
    for i in 0 ..< broker.entries.len:
      let entry = broker.entries[i]
      if entry.state != wstQueued or (entry.declinedCoreMask and req.peerCoreBit) != 0 or
          not entry.job.compatibleWasmStealJob(req):
        continue
      when defined(wasmSoftStealing):
        let deadline = entry.job.soft.deadlineTick
        if deadline != 0 and not req.acceptSoft: continue
        if bestDeadline != deadline and
            (deadline == 0 or (bestDeadline != 0 and deadline > bestDeadline)):
          continue
        if bestDeadline == deadline and entry.sequence > bestSeq: continue
        bestDeadline = deadline
      else:
        if entry.sequence > bestSeq: continue
      bestSeq = entry.sequence
      selected = i
    if selected < 0:
      result.status = wssEmpty
      return
    let entry = addr broker.entries[selected]
    entry[].state = wstClaimed
    entry[].claimantCoreBit = req.peerCoreBit
    entry[].claimantSession = req.peerSession
    entry[].claimToken = broker.nextToken.nextNonzero()
    entry[].leaseUntil = if now > high(uint64) - broker.leaseTicks:
      high(uint64)
    else:
      now + broker.leaseTicks
    result.job = entry[].job
    result.claimToken = entry[].claimToken
    inc broker.telemetry.claims
  of wsoReadOutcome, wsoAckOutcome, wsoCancel:
    broker.processOutcomeRequest(peer, req, result)
  of wsoFinish:
    broker.processFinish(peer, req, result)
  of wsoProbeHandoff, wsoCheckHandoff, wsoAuthorizeHandoff, wsoAcceptHandoff:
    broker.processHandoff(req, result)
  of wsoStart, wsoRelease, wsoDecline:
    for entry in broker.entries.mitems:
      if entry.claimToken != 0 and entry.claimToken == req.claimToken and
          entry.claimantCoreBit == req.peerCoreBit and
          entry.claimantSession == req.peerSession:
        result.claimToken = req.claimToken
        result.job.jobId = entry.job.jobId
        if req.op == wsoStart:
          if entry.state == wstStarted:
            return  # Idempotent retry after a lost acknowledgement.
          if entry.state != wstClaimed or not entry.job.compatibleWasmStealJob(req):
            break
          entry.state = wstStarted
          inc broker.telemetry.starts
          return
        if req.op in {wsoRelease, wsoDecline} and entry.state == wstClaimed:
          if req.op == wsoDecline:
            entry.declinedCoreMask = entry.declinedCoreMask or req.peerCoreBit
            inc broker.telemetry.dependencyDeclines
          entry.requeueClaim()
          return
        break
    result.status = wssStale
    inc broker.telemetry.staleRequests
  of wsoHello:
    discard

proc processWasmStealWire*(broker: var WasmStealBroker,
                           request: openArray[byte],
                           response: var openArray[byte],
                           now: uint64, routedSourceBit = 0'u32,
                           sampleClock: WasmStealClock = nil, ownerTicksPerUs = 0'u32): int =
  var req: WasmStealRequest
  var offeredJob: WasmStealJob
  if request.len == WasmStealResponseBytes and request[3] == wsoOffer.ord.byte:
    var envelope: WasmStealResponse
    if not request.decodeStealEnvelope(envelope, wsoOffer.ord.byte): return 0
    req = WasmStealRequest(op: wsoOffer, ownerEpoch: envelope.ownerEpoch,
      peerSession: envelope.peerSession, peerBootId: envelope.job.jobId,
      peerCoreBit: envelope.job.sourceCoreBit, claimToken: envelope.claimToken)
    offeredJob = envelope.job
    offeredJob.jobId = 0
    offeredJob.sourceCoreBit = 0
  elif not request.decodeWasmStealRequest(req):
    return 0
  if routedSourceBit != 0 and req.peerCoreBit != routedSourceBit:
    return WasmStealResponse(status: wssInvalid, ownerEpoch: broker.ownerEpoch).
      encodeWasmStealResponse(response)
  var reply = broker.processWasmSteal(req, now, offeredJob)
  when defined(wasmSoftStealing):
    if req.op == wsoHello and req.acceptSoft and req.claimToken != 0 and
        reply.status == wssOk and sampleClock != nil and
        ownerTicksPerUs in 1'u32..MaxWasmClockTicksPerUs:
      reply.claimToken = req.claimToken
      reply.ownerReceiveTick = now
      reply.ownerSendTick = sampleClock()
      reply.ownerTicksPerUs = ownerTicksPerUs
  reply.encodeWasmStealResponse(response)

proc stateOfWasmStealJob*(broker: WasmStealBroker,
                          jobId: uint32): WasmStealState =
  for entry in broker.entries:
    if entry.state != wstEmpty and entry.job.jobId == jobId:
      return entry.state
  wstEmpty

proc retireStoppedWasmStealJob*(broker: var WasmStealBroker,
                                jobId: uint32,
                                peerConfirmedStopped: bool): bool =
  ## After a separate health check proves the peer stopped, resolve the
  ## job without replaying it and report the failure to a live submitter.
  if not peerConfirmedStopped or jobId == 0: return false
  for entry in broker.entries.mitems:
    if entry.state in {wstStarted, wstHandoff} and entry.job.jobId == jobId:
      let worker = if entry.state == wstHandoff: entry.handoff.targetCoreBit
                   else: entry.claimantCoreBit
      entry.storeOutcome(WasmStealOutcome(kind: wokWorkerStopped,
        workerCoreBit: worker))
      inc broker.telemetry.operatorRetirements
      return true
  false
