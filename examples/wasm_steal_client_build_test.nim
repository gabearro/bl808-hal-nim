## Worker for the unstarted full-VM queue. An offered flash slot must
## contain an i32 export. This image never writes flash.

when (not defined(bl808m0) and not defined(bl808d0) and not defined(bl808lp)) or
    not defined(bl808kernel) or
    not defined(bl808WasmFullScheduler):
  {.error: "build as the M0, D0, or LP full-VM kernel scheduler".}

import bl808/[startup, core, mmio, memmap, wasm_scheduler,
  wasm_steal_client]
import bl808/kernel/[alloc, clock, ipcbridge, sched]
when defined(wasmCrossCoreStealProbe):
  import bl808/wasm_steal_broker
when defined(bl808m0):
  import bl808/wasm_steal_server
when defined(wasmSoftStealing):
  import bl808/[wasm_rt_clock, wasm_rt_kernel, wasm_rt_policy]
when defined(bl808lp):
  import bl808/wasm_lp_softfloat

const
  StatusAddr = when defined(bl808lp): 0x40002EA0'u
               elif defined(bl808m0): XramBase + 0x2D40'u
               else: XramBase + 0x2D80'u
  StatusWaiting = 0x5753_447F'u32
  StatusPassed = 0x5753_4400'u32
  StatusFailed = 0x5753_4401'u32
  RetryTicks = 500_000'u64

var
  client: WasmStealClient
  nextClaimTick: uint64
  done: bool
  finishing: bool
  passed: bool
  finalValue: int32

when defined(wasmCrossCoreStealProbe):
  const StatusOffered = 0x5753_4402'u32
  type OfferPhase = enum
    opSubmit, opSubmitted, opRead, opReading, opAcknowledging
  var offerTarget: uint32
  var offerPhase: OfferPhase

  proc beginProbeOffer(): bool =
    var job = WasmStealJob(slot: 2, argCount: 2, affinityMask: offerTarget,
      requiredBackends: 1, maxFuel: 64)
    for i, c in "indirect": job.exportName[i] = c
    job.args[0] = 20
    job.args[1] = 22
    client.beginWasmStealOffer(job, 1, client.ownerEpoch)

proc publish(status: uint32, value = 0'i32) =
  regWrite(StatusAddr + 4'u, cast[uint32](value))
  when defined(wasmSoftStealing):
    regWrite(StatusAddr + 8'u, client.softTelemetry.clockSamples)
    regWrite(StatusAddr + 12'u, client.softTelemetry.maxRoundTripTicks.uint32)
    regWrite(StatusAddr + 16'u, client.softTelemetry.maxUncertaintyTicks.uint32)
    regWrite(StatusAddr + 20'u, heapStats().highWaterBytes.uint32)
  regWrite(StatusAddr, status)
  when defined(bl808d0):
    dcacheFlushAll()
  fenceIo()

when defined(wasmCrossCoreStealProbe):
  proc pollProbeOffer(now: uint64): bool =
    case offerPhase
    of opSubmit:
      if not beginProbeOffer(): return false
      offerPhase = opSubmitted
    of opSubmitted:
      if client.offerStatus != wssOk: return false
      publish(StatusOffered, cast[int32](client.offeredJobId))
      offerPhase = opRead
    of opRead:
      if now < nextClaimTick: return true
      if not client.beginWasmStealReadOutcome(client.offeredJobId, client.ownerEpoch):
        return false
      offerPhase = opReading
      nextClaimTick = now + RetryTicks
    of opReading:
      if client.outcomeStatus == wssEmpty:
        offerPhase = opRead
      elif client.outcomeStatus != wssOk:
        return false
      else:
        passed = client.outcome.kind == wokReturned and
          client.outcome.workerCoreBit == offerTarget and client.outcome.returnedI32() == 42
        if client.outcome.kind == wokReturned:
          finalValue = client.outcome.returnedI32()
        if not client.beginWasmStealAckOutcome(client.offeredJobId, client.ownerEpoch):
          return false
        offerPhase = opAcknowledging
    of opAcknowledging:
      done = true
      publish(if passed and client.outcomeStatus == wssOk: StatusPassed else: StatusFailed,
        finalValue)
    true

proc pollStealWorker() =
  if done: return
  let now = readTick()
  case client.state
  of wscIdle, wscNoJob:
    when defined(wasmCrossCoreStealProbe):
      if offerTarget != 0:
        if not pollProbeOffer(now):
          done = true
          publish(StatusFailed)
        return
    if finishing:
      done = true
      publish(if passed: StatusPassed else: StatusFailed, finalValue)
    elif now >= nextClaimTick:
      if not client.beginWasmSteal():
        done = true
        publish(StatusFailed)
      nextClaimTick = now + RetryTicks
  of wscPending:
    discard client.pollWasmSteal()
  of wscReady:
    let task = when defined(wasmSoftStealing): getWasmTask(client.taskId)
               else: resumeWasmTask(client.taskId, 8)
    if task.status == wasmSchedNoTask or task.state in {wasmTaskExited, wasmTaskTrapped}:
      passed = task.state == wasmTaskExited and task.result == 42
      finalValue = task.result
      if client.finishWasmSteal() or client.state == wscFinishRetry:
        discard killWasmTask(task.id)
        finishing = true
        nextClaimTick = now + RetryTicks
      else:
        done = true
        publish(StatusFailed)
  of wscFinishRetry:
    if now >= nextClaimTick:
      discard client.finishWasmSteal()
      nextClaimTick = now + RetryTicks
  of wscFailed:
    done = true
    publish(StatusFailed)

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  publish(StatusWaiting)
  schedulerInit()
  ipcBridgeInit()
  let bootId = when defined(wasmSoftStealing) or defined(wasmCrossCoreStealProbe):
                 regRead(StatusAddr + 0x20'u)
               else: (readTick() xor 0x4453_544C'u64).uint32 or 1'u32
  when defined(bl808m0):
    if not initM0WasmStealServer(2_000_000'u64, bootId):
      done = true
      publish(StatusFailed)
  if not client.initWasmStealClient(bootId, 0):
    done = true
    publish(StatusFailed)
  when defined(wasmSoftStealing):
    # Exploratory limits for the timed board probe. Device skew and RT
    # admission margins have to be measured for production use.
    if not done and (initWasmRtScheduler(client.coreBit, readTick(), usToTicks(100_000)) != wrOk or
        not attachWasmRtKernel(bestEffortMaxSliceTicks = usToTicks(25_000)) or
        not client.enableWasmSoftStealing(WasmClockLimits(maxRoundTripTicks: usToTicks(50_000),
          maxAgeTicks: usToTicks(250_000), maxProjectionTicks: usToTicks(4_000_000),
          maxUncertaintyTicks: usToTicks(100_000), relativeSkewPpm: 5_000))):
      done = true
      publish(StatusFailed)
  when defined(wasmCrossCoreStealProbe):
    offerTarget = regRead(StatusAddr + 0x24'u)
    if not done and offerTarget != 0:
      if (offerTarget != WasmStealM0 and offerTarget != WasmStealD0 and
          offerTarget != WasmStealLP) or offerTarget == client.coreBit or
          not client.beginWasmStealSession():
        done = true
        publish(StatusFailed)
  setSchedulerPollHook(pollStealWorker)
  runScheduler()
