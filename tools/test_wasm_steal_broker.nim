import bl808/[wasm_full_baseline, wasm_runtime, wasm_scheduler,
  wasm_steal_broker, wasm_store]

proc makeJob(name: string, mask: uint32): WasmStealJob =
  doAssert name.len > 0 and name.len < WasmStealNameBytes
  for i, c in name: result.exportName[i] = c
  result.slot = 1
  result.argCount = 2
  result.args[0] = 20
  result.args[1] = 22
  result.affinityMask = mask
  result.requiredBackends = WasmBackendInterpreter
  result.maxFuel = 64

proc exchange(broker: var WasmStealBroker, request: WasmStealRequest,
              now: uint64, routedSourceBit = 0'u32): WasmStealResponse =
  var reqBuf: array[WasmStealRequestBytes, byte]
  var respBuf: array[WasmStealResponseBytes, byte]
  doAssert request.encodeWasmStealRequest(reqBuf) == WasmStealRequestBytes
  doAssert broker.processWasmStealWire(reqBuf, respBuf, now, routedSourceBit) ==
    WasmStealResponseBytes
  doAssert respBuf.decodeWasmStealResponse(result)

var broker: WasmStealBroker
doAssert broker.initWasmStealBroker(99, 50)
var firstId: uint32
doAssert broker.offerWasmStealJob(makeJob("indirect", 6), firstId) == wssOk
doAssert firstId != 0

var lp = WasmStealRequest(op: wsoHello, peerBootId: 7,
  peerCoreBit: 4, fullInterpreter: true,
  backendMask: WasmBackendInterpreter)
doAssert broker.exchange(lp, 1, routedSourceBit = 2).status == wssInvalid
let hello = broker.exchange(lp, 1)
doAssert hello.status == wssOk and hello.peerSession != 0 and
  hello.ownerEpoch == 99
lp.op = wsoClaim
lp.ownerEpoch = hello.ownerEpoch
lp.peerSession = hello.peerSession
lp.fullInterpreter = false
doAssert broker.exchange(lp, 2).status == wssEmpty
lp.fullInterpreter = true
let claimed = broker.exchange(lp, 3)
doAssert claimed.status == wssOk and claimed.job.jobId == firstId and
  claimed.job.argCount == 2 and claimed.job.exportName[0] == 'i' and
  claimed.claimToken != 0
doAssert broker.stateOfWasmStealJob(firstId) == wstClaimed
doAssert broker.exchange(lp, 4).status == wssEmpty

# A thief prepares its own ordinary full-VM task. It must not resume until
# the owner accepts wsoStart; no native continuation crosses the IPC wire.
var image = newSeq[byte](WasmProgramHeaderLen.int + WasmFullBaselineModule.len)
doAssert initWasmProgramImage(
  cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
  WasmFullBaselineModule) == wasmProgramOk
resetWasmScheduler()
let prepared = startFullWasmImageTaskI32(
  cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
  "indirect", claimed.job.args.toOpenArray(0, 1),
  maxTotalFuel = claimed.job.maxFuel)
doAssert prepared.status == wasmSchedOk and prepared.state == wasmTaskReady
lp.op = wsoStart
lp.claimToken = claimed.claimToken
doAssert broker.exchange(lp, 5).status == wssOk
doAssert broker.exchange(lp, 6).status == wssOk # lost-ack retry
var current = prepared
for _ in 0 ..< 32:
  if current.state notin {wasmTaskReady, wasmTaskYielded}: break
  current = resumeWasmTask(prepared.id, 2)
doAssert current.status == wasmSchedOk and current.state == wasmTaskExited and
  current.result == 42
discard killWasmTask(prepared.id)
lp.op = wsoFinish
lp.jobId = firstId
lp.outcome = WasmStealOutcome(kind: wokReturned, detail: 42, fuelUsed: current.fuelUsed)
doAssert broker.exchange(lp, 7).status == wssOk
doAssert broker.stateOfWasmStealJob(firstId) == wstEmpty

# The owner returns only compatible jobs; a peer reboot invalidates an
# unstarted claim and any old claim token.
var secondId: uint32
var second = makeJob("indirect", 6)
second.maxMemoryPages = 2
second.requiredHostInterfaces = 8
doAssert broker.offerWasmStealJob(second, secondId) == wssOk
lp.op = wsoClaim
lp.claimToken = 0
doAssert broker.exchange(lp, 8).status == wssEmpty
lp.maxMemoryPages = 2
lp.hostInterfaceMask = 8
let pending = broker.exchange(lp, 9)
doAssert pending.status == wssOk and pending.job.jobId == secondId
lp.op = wsoHello
lp.peerBootId = 8
lp.peerSession = 0
let restarted = broker.exchange(lp, 10)
doAssert restarted.status == wssOk and
  restarted.peerSession != pending.peerSession
lp.op = wsoStart
lp.peerBootId = 7
lp.peerSession = pending.peerSession
lp.claimToken = pending.claimToken
doAssert broker.exchange(lp, 11).status == wssStale
doAssert broker.stateOfWasmStealJob(secondId) == wstQueued

var tombstoneId: uint32
doAssert broker.offerWasmStealJob(makeJob("indirect", 4), tombstoneId) == wssOk
lp.peerBootId = 8
lp.peerSession = restarted.peerSession
lp.op = wsoClaim
lp.claimToken = 0
lp.hostInterfaceMask = 0
lp.maxMemoryPages = 0
let tombstoneClaim = broker.exchange(lp, 12)
doAssert tombstoneClaim.status == wssOk and
  tombstoneClaim.job.jobId == tombstoneId
lp.op = wsoStart
lp.claimToken = tombstoneClaim.claimToken
doAssert broker.exchange(lp, 13).status == wssOk
lp.op = wsoHello
lp.peerBootId = 9
lp.peerSession = 0
discard broker.exchange(lp, 14)
doAssert broker.stateOfWasmStealJob(tombstoneId) == wstStarted
doAssert not broker.retireStoppedWasmStealJob(tombstoneId, false)
doAssert broker.retireStoppedWasmStealJob(tombstoneId, true)

# D0 can claim the requeued work. Expired leases also requeue, but an old
# start acknowledgement is rejected so the guest cannot run twice.
var d0 = WasmStealRequest(op: wsoHello, peerBootId: 23,
  peerCoreBit: 2, fullInterpreter: true,
  backendMask: WasmBackendInterpreter, hostInterfaceMask: 8,
  maxMemoryPages: 2)
let d0Hello = broker.exchange(d0, 15)
d0.op = wsoClaim
d0.ownerEpoch = d0Hello.ownerEpoch
d0.peerSession = d0Hello.peerSession
let d0Claim = broker.exchange(d0, 16)
doAssert d0Claim.status == wssOk and d0Claim.job.jobId == secondId
broker.reapWasmStealLeases(66)
doAssert broker.stateOfWasmStealJob(secondId) == wstQueued
d0.op = wsoStart
d0.claimToken = d0Claim.claimToken
doAssert broker.exchange(d0, 67).status == wssStale
doAssert broker.telemetry.claims == 4 and broker.telemetry.starts == 2 and
  broker.telemetry.completed == 1 and broker.telemetry.leaseRequeues == 1 and
  broker.telemetry.peerResetRequeues == 1 and
  broker.telemetry.operatorRetirements == 1
echo "WASM steal broker PASS: compatible claim, full VM start, lease and reset"

doAssert broker.initWasmStealBroker(101, 50)
var local = WasmStealRequest(op: wsoHello, peerBootId: 3, peerCoreBit: WasmStealM0,
  fullInterpreter: true, backendMask: WasmBackendInterpreter,
  resourceMask: WasmStealDirectSd, maxMemoryPages: 1)
let localHello = broker.exchange(local, 1, WasmStealM0)
local.ownerEpoch = localHello.ownerEpoch
local.peerSession = localHello.peerSession
var forStorage = makeJob("indirect", WasmStealAllCores)
forStorage.requiredResources = WasmStealDirectSd
forStorage.maxMemoryPages = 1
d0.op = wsoHello
let d0Session = broker.exchange(d0, 1, WasmStealD0)
d0.op = wsoOffer
d0.ownerEpoch = d0Session.ownerEpoch
d0.peerSession = d0Session.peerSession
d0.claimToken = 1
var offerBuf, respBuf: array[WasmStealResponseBytes, byte]
doAssert d0.encodeWasmStealOffer(forStorage, offerBuf) == WasmStealResponseBytes
doAssert broker.processWasmStealWire(offerBuf, respBuf, 2, WasmStealLP) ==
  WasmStealResponseBytes
var reply: WasmStealResponse
doAssert respBuf.decodeWasmStealResponse(reply) and reply.status == wssInvalid
doAssert broker.telemetry.offered == 0
doAssert broker.processWasmStealWire(offerBuf, respBuf, 2, WasmStealD0) ==
  WasmStealResponseBytes
doAssert respBuf.decodeWasmStealResponse(reply) and reply.status == wssOk
let routedId = reply.job.jobId
doAssert routedId != 0

d0.op = wsoClaim
d0.resourceMask = WasmStealDirectSd
doAssert broker.exchange(d0, 3, WasmStealD0).status == wssEmpty
local.op = wsoClaim
let storageClaim = broker.exchange(local, 3, WasmStealM0)
doAssert storageClaim.status == wssOk and storageClaim.job.jobId == routedId and
  storageClaim.job.sourceCoreBit == WasmStealD0 and
  storageClaim.job.requiredResources == WasmStealDirectSd
local.op = wsoStart
local.claimToken = storageClaim.claimToken
local.resourceMask = 0
doAssert broker.exchange(local, 4, WasmStealM0).status == wssStale
doAssert broker.stateOfWasmStealJob(routedId) == wstClaimed
local.op = wsoRelease
doAssert broker.exchange(local, 4, WasmStealM0).status == wssOk
doAssert broker.stateOfWasmStealJob(routedId) == wstQueued
forStorage.affinityMask = WasmStealLP
doAssert broker.offerWasmStealJob(forStorage, firstId) == wssInvalid
echo "WASM steal routing PASS: authenticated origin, impossible resources and start recheck"

# Cancel wins a race with start while the worker's claim is still dormant.
local.op = wsoClaim
local.resourceMask = WasmStealDirectSd
let dormant = broker.exchange(local, 5, WasmStealM0)
doAssert dormant.status == wssOk and dormant.job.jobId == routedId
d0.op = wsoCancel
d0.jobId = routedId
d0.claimToken = 0
doAssert broker.exchange(d0, 6, WasmStealD0).status == wssOk
local.op = wsoStart
local.claimToken = dormant.claimToken
doAssert broker.exchange(local, 7, WasmStealM0).status == wssStale
d0.op = wsoReadOutcome
doAssert broker.exchange(d0, 7, WasmStealD0).outcome.kind == wokCanceled
d0.op = wsoAckOutcome
doAssert broker.exchange(d0, 7, WasmStealD0).status == wssOk

proc offerStorage(ticket: uint32, now: uint64): uint32 =
  var descriptor = forStorage
  descriptor.affinityMask = WasmStealM0
  var req = d0
  req.op = wsoOffer
  req.claimToken = ticket
  doAssert req.encodeWasmStealOffer(descriptor, offerBuf) == WasmStealResponseBytes
  doAssert broker.processWasmStealWire(offerBuf, respBuf, now, WasmStealD0) ==
    WasmStealResponseBytes
  doAssert respBuf.decodeWasmStealResponse(reply) and reply.status == wssOk
  reply.job.jobId

let workerResetJob = offerStorage(2, 8)
local.op = wsoClaim
let beforeReset = broker.exchange(local, 9, WasmStealM0)
doAssert beforeReset.job.jobId == workerResetJob
local.op = wsoStart
local.claimToken = beforeReset.claimToken
doAssert broker.exchange(local, 10, WasmStealM0).status == wssOk
local.op = wsoHello
inc local.peerBootId
local.peerSession = broker.exchange(local, 11, WasmStealM0).peerSession
doAssert broker.stateOfWasmStealJob(workerResetJob) == wstStarted
doAssert not broker.retireStoppedWasmStealJob(workerResetJob, false)
doAssert broker.retireStoppedWasmStealJob(workerResetJob, true)
d0.jobId = workerResetJob
d0.op = wsoReadOutcome
let stoppedReply = broker.exchange(d0, 12, WasmStealD0)
doAssert stoppedReply.status == wssOk and stoppedReply.outcome.kind == wokWorkerStopped and
  stoppedReply.outcome.workerCoreBit == WasmStealM0
d0.op = wsoAckOutcome
doAssert broker.exchange(d0, 12, WasmStealD0).status == wssOk

let sourceResetJob = offerStorage(3, 13)
local.op = wsoClaim
let sourceResetClaim = broker.exchange(local, 14, WasmStealM0)
doAssert sourceResetClaim.job.jobId == sourceResetJob
local.op = wsoStart
local.claimToken = sourceResetClaim.claimToken
doAssert broker.exchange(local, 15, WasmStealM0).status == wssOk
d0.op = wsoHello
inc d0.peerBootId
d0.peerSession = broker.exchange(d0, 16, WasmStealD0).peerSession
doAssert broker.stateOfWasmStealJob(sourceResetJob) == wstStarted
local.op = wsoFinish
local.jobId = sourceResetJob
local.outcome = WasmStealOutcome(kind: wokReturned, detail: high(uint32), fuelUsed: 10)
doAssert broker.exchange(local, 17, WasmStealM0).status == wssOk
doAssert broker.stateOfWasmStealJob(sourceResetJob) == wstEmpty
doAssert broker.exchange(local, 18, WasmStealM0).status == wssOk
local.outcome.detail = 99
doAssert broker.exchange(local, 18, WasmStealM0).status == wssInvalid
d0.op = wsoReadOutcome
d0.jobId = sourceResetJob
doAssert broker.exchange(d0, 19, WasmStealD0).status == wssStale
echo "WASM steal outcome PASS: cancel/start race, peer resets and exact finish replay"
