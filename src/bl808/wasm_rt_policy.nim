## Bounded core-local dispatch policy for WASM tasks. All times are monotonic
## ticks from the calling core. Clock correlation is required before a release
## or deadline from another core can be used here.
##
## Hard reservations are cyclic slots in one frame. Admission requires a
## resident working set, bounded imports, and no peer or flash dependency.
## The caller must establish a measured worst-case slice time and invoke the
## dispatcher often enough to meet start jitter; this policy alone cannot
## make a cooperative interpreter or shared bus hard real-time.

const WasmRtMaxJobs* {.intdefine.} = 8

type
  WasmRtClass* = enum
    wrBestEffort
    wrSoft
    wrHard

  WasmRtOverrun* = enum
    wrContinue
    wrDemote
    wrStop

  WasmRtStatus* = enum
    wrOk
    wrInvalid
    wrNoCapacity
    wrWrongCore
    wrUnsafeHardSlot
    wrSlotOverlap

  WasmRtAction* = enum
    wrKeepRunning
    wrDemoteJob
    wrStopJob

  WasmRtSpec* = object
    class*: WasmRtClass
    releaseTick*: uint64
    deadlineTick*: uint64
      ## Hard jobs use a frame-relative deadline offset (zero means the
      ## reserved slot end). Soft jobs use an absolute deadline.
    budgetTicks*: uint64
    maxSliceTicks*: uint64
    startJitterTicks*: uint64
    affinityMask*: uint32
    slotOffsetTicks*: uint64
    slotLengthTicks*: uint64
    overrun*: WasmRtOverrun
    residentWorkingSet*: bool
    boundedImports*: bool
    noPeerDependency*: bool
    noFlashMutation*: bool

  WasmRtTelemetry* = object
    starts*: uint32
    runs*: uint32
    missedReservations*: uint32
    deadlineMisses*: uint32
    startJitterMisses*: uint32
    sliceOverruns*: uint32
    budgetOverruns*: uint32
    hardFaults*: uint32
    maxStartJitterTicks*: uint64
    maxSliceTicks*: uint64

  WasmRtJob = object
    id: uint32
    spec: WasmRtSpec
    firstStarted: bool
    deadlineCounted: bool
    budgetCounted: bool
    usedTicks: uint64
    observedFrameStart: uint64
    hasObservedFrame: bool
    nextUnreportedFrame: uint64
    startedFrame: uint64
    hasStartedFrame: bool

  WasmRtPolicy* = object
    coreBit: uint32
    frameEpoch: uint64
    frameTicks: uint64
    jobs: array[WasmRtMaxJobs, WasmRtJob]
    telemetry: WasmRtTelemetry

proc initWasmRtPolicy*(policy: var WasmRtPolicy, coreBit: uint32,
                       frameEpoch, frameTicks: uint64): WasmRtStatus =
  if coreBit == 0 or (coreBit and (coreBit - 1)) != 0 or frameTicks == 0:
    return wrInvalid
  policy = WasmRtPolicy(coreBit: coreBit, frameEpoch: frameEpoch,
                        frameTicks: frameTicks)
  wrOk

proc findJob(policy: WasmRtPolicy, id: uint32): int {.inline.} =
  for i in 0 ..< policy.jobs.len:
    if policy.jobs[i].id == id: return i
  -1

proc frameStart(policy: WasmRtPolicy, now: uint64): uint64 {.inline.}

proc admitWasmRtJob*(policy: var WasmRtPolicy, id: uint32,
                     spec: WasmRtSpec): WasmRtStatus =
  if id == 0 or policy.frameTicks == 0 or policy.findJob(id) >= 0 or
      spec.affinityMask == 0 or spec.maxSliceTicks == 0 or
      (spec.class != wrHard and spec.deadlineTick != 0 and
       spec.deadlineTick <= spec.releaseTick):
    return wrInvalid
  if (spec.affinityMask and policy.coreBit) == 0: return wrWrongCore
  if spec.class == wrHard:
    if not (spec.residentWorkingSet and spec.boundedImports and
            spec.noPeerDependency and spec.noFlashMutation) or
        spec.budgetTicks == 0 or spec.slotLengthTicks == 0 or
        spec.budgetTicks > spec.slotLengthTicks or
        spec.maxSliceTicks > spec.slotLengthTicks or
        spec.slotOffsetTicks >= policy.frameTicks or
        spec.slotLengthTicks > policy.frameTicks - spec.slotOffsetTicks or
        spec.startJitterTicks > spec.slotLengthTicks or
        (spec.deadlineTick != 0 and
         (spec.deadlineTick > policy.frameTicks or
          spec.deadlineTick < spec.slotOffsetTicks + spec.slotLengthTicks)):
      return wrUnsafeHardSlot
    let finish = spec.slotOffsetTicks + spec.slotLengthTicks
    for job in policy.jobs:
      if job.id != 0 and job.spec.class == wrHard:
        let otherFinish = job.spec.slotOffsetTicks + job.spec.slotLengthTicks
        if spec.slotOffsetTicks < otherFinish and job.spec.slotOffsetTicks < finish:
          return wrSlotOverlap
  elif spec.class == wrSoft and spec.deadlineTick == 0:
    return wrInvalid
  else:
    if spec.slotOffsetTicks != 0 or spec.slotLengthTicks != 0:
      return wrInvalid
  for job in policy.jobs.mitems:
    if job.id == 0:
      job = WasmRtJob(id: id, spec: spec)
      if spec.class == wrHard:
        job.nextUnreportedFrame = policy.frameStart(
          max(policy.frameEpoch, spec.releaseTick))
        if job.nextUnreportedFrame > high(uint64) - policy.frameTicks:
          job = WasmRtJob()
          return wrInvalid
        if spec.releaseTick >= job.nextUnreportedFrame +
            spec.slotOffsetTicks + spec.slotLengthTicks:
          job.nextUnreportedFrame += policy.frameTicks
      return wrOk
  wrNoCapacity

proc removeWasmRtJob*(policy: var WasmRtPolicy, id: uint32) =
  let i = policy.findJob(id)
  if i >= 0: policy.jobs[i] = WasmRtJob()

proc hasWasmRtJob*(policy: WasmRtPolicy, id: uint32): bool {.inline.} =
  policy.findJob(id) >= 0

proc pollWasmRtPolicy*(policy: var WasmRtPolicy, now: uint64) =
  ## Account for expired soft jobs and completed hard slots even with no
  ## runnable task. A poll can cover several skipped frames at once.
  if policy.frameTicks == 0: return
  for job in policy.jobs.mitems:
    if job.id == 0: continue
    if job.spec.class == wrSoft and not job.deadlineCounted and
        now > job.spec.deadlineTick:
      job.deadlineCounted = true
      inc policy.telemetry.deadlineMisses
    if job.spec.class != wrHard: continue
    let slotEndOffset = job.spec.slotOffsetTicks + job.spec.slotLengthTicks
    if job.nextUnreportedFrame > high(uint64) - slotEndOffset: continue
    let firstEnd = job.nextUnreportedFrame + slotEndOffset
    if now < firstEnd: continue
    let completedBeforeLast = (now - firstEnd) div policy.frameTicks
    let completed = completedBeforeLast + 1'u64
    let lastFrame = job.nextUnreportedFrame +
      completedBeforeLast * policy.frameTicks
    var missed = completed
    if job.hasStartedFrame and job.startedFrame >= job.nextUnreportedFrame and
        job.startedFrame <= lastFrame:
      dec missed
    job.nextUnreportedFrame = if lastFrame <= high(uint64) - policy.frameTicks:
      lastFrame + policy.frameTicks else: high(uint64)
    let room = high(uint32).uint64 - policy.telemetry.missedReservations.uint64
    policy.telemetry.missedReservations += min(missed, room).uint32

proc contains(runnable: openArray[uint32], id: uint32): bool {.inline.} =
  for candidate in runnable:
    if candidate == id: return true
  false

proc frameStart(policy: WasmRtPolicy, now: uint64): uint64 {.inline.} =
  if now < policy.frameEpoch: return policy.frameEpoch
  now - ((now - policy.frameEpoch) mod policy.frameTicks)

proc activeHardSlot(policy: WasmRtPolicy, now: uint64): int =
  if now < policy.frameEpoch: return -1
  let phase = now - policy.frameStart(now)
  for i in 0 ..< policy.jobs.len:
    let job = policy.jobs[i]
    if job.id != 0 and job.spec.class == wrHard and
        phase >= job.spec.slotOffsetTicks and
        phase < job.spec.slotOffsetTicks + job.spec.slotLengthTicks:
      return i
  -1

proc ticksUntilHard(policy: WasmRtPolicy, now: uint64): uint64 =
  let untilEpoch = if now < policy.frameEpoch: policy.frameEpoch - now else: 0'u64
  let phase = if untilEpoch == 0: now - policy.frameStart(now) else: 0'u64
  result = high(uint64)
  for job in policy.jobs:
    if job.id == 0 or job.spec.class != wrHard: continue
    let untilStart = if untilEpoch != 0:
      min(high(uint64) - untilEpoch, job.spec.slotOffsetTicks) + untilEpoch
    elif phase < job.spec.slotOffsetTicks:
      job.spec.slotOffsetTicks - phase
    else:
      let nextFrame = policy.frameTicks - phase
      if job.spec.slotOffsetTicks > high(uint64) - nextFrame:
        high(uint64)
      else:
        nextFrame + job.spec.slotOffsetTicks
    if untilStart < result: result = untilStart

proc dispatchCutoffTick*(policy: WasmRtPolicy, id: uint32,
                         now: uint64): uint64 =
  ## A full interpreter may stop at this core-local tick before it crosses
  ## into the next reservation. Within a hard slot, stop at its end. Outside
  ## hard slots, stop at the next hard slot's start. The caller still needs a
  ## measured bound for one instruction and every host call.
  if policy.frameTicks == 0: return high(uint64)
  let hard = policy.activeHardSlot(now)
  if hard >= 0 and policy.jobs[hard].id == id:
    let remaining = policy.jobs[hard].spec.slotOffsetTicks +
                    policy.jobs[hard].spec.slotLengthTicks
    let frame = policy.frameStart(now)
    return if remaining > high(uint64) - frame:
      high(uint64) else: frame + remaining
  let untilHard = policy.ticksUntilHard(now)
  if untilHard == high(uint64) or untilHard > high(uint64) - now:
    high(uint64)
  else:
    now + untilHard

proc chooseWasmRtJob*(policy: WasmRtPolicy, runnable: openArray[uint32],
                      now, fallbackMaxSliceTicks: uint64): uint32 =
  ## Return zero to idle. In an active hard slot, other jobs cannot run even
  ## when the reserved task is blocked or has not been released yet.
  if policy.frameTicks == 0: return 0
  let hard = policy.activeHardSlot(now)
  if hard >= 0:
    let job = policy.jobs[hard]
    let slotEnd = policy.dispatchCutoffTick(job.id, now)
    if now >= job.spec.releaseTick and job.id in runnable and
        job.spec.maxSliceTicks <= slotEnd - now:
      return job.id
    return 0

  let slack = policy.ticksUntilHard(now)
  var bestDeadline = high(uint64)
  for id in runnable:
    let i = policy.findJob(id)
    if i < 0: continue
    let job = policy.jobs[i]
    if job.spec.class == wrSoft and now >= job.spec.releaseTick and
        job.spec.maxSliceTicks <= slack and
        (result == 0 or job.spec.deadlineTick < bestDeadline):
      bestDeadline = job.spec.deadlineTick
      result = id
  if result != 0: return
  for id in runnable:
    let i = policy.findJob(id)
    if i >= 0:
      let job = policy.jobs[i]
      if job.spec.class == wrBestEffort and now >= job.spec.releaseTick and
          job.spec.maxSliceTicks <= slack:
        return id
    elif fallbackMaxSliceTicks > 0 and fallbackMaxSliceTicks <= slack:
      return id

proc nextWasmRtWakeTick*(policy: WasmRtPolicy, runnable: openArray[uint32],
                         now, fallbackMaxSliceTicks: uint64): uint64 =
  ## A zero deadline disarms the kernel hook. Immediate work is due at the
  ## current tick (or tick 1 at boot, since the kernel reserves zero).
  if policy.frameTicks == 0: return 0
  if policy.chooseWasmRtJob(runnable, now, fallbackMaxSliceTicks) != 0:
    return max(1'u64, now)
  let frame = policy.frameStart(now)
  let inHardSlot = policy.activeHardSlot(now) >= 0
  template consider(tickExpr: uint64) =
    let tick = tickExpr
    if tick > now and (result == 0 or tick < result):
      result = tick
  for job in policy.jobs:
    if job.id == 0: continue
    case job.spec.class
    of wrHard:
      let offset = job.spec.slotOffsetTicks
      let length = job.spec.slotLengthTicks
      let endOffset = offset + length
      if endOffset <= high(uint64) - job.nextUnreportedFrame and
          job.nextUnreportedFrame + endOffset <= now:
        return max(1'u64, now)
      if offset > high(uint64) - frame: continue
      let start = frame + offset
      if now < start:
        consider(start)
      elif length <= high(uint64) - start:
        let finish = start + length
        if now < finish:
          consider(finish)
          let release = job.spec.releaseTick
          if release > now and release <= finish - job.spec.maxSliceTicks and
              job.id in runnable:
            consider(release)
        elif policy.frameTicks <= high(uint64) - start:
          consider(start + policy.frameTicks)
    of wrSoft:
      if not job.deadlineCounted and job.spec.deadlineTick < high(uint64):
        if now > job.spec.deadlineTick: return max(1'u64, now)
        consider(job.spec.deadlineTick + 1)
      if not inHardSlot and job.id in runnable: consider(job.spec.releaseTick)
    of wrBestEffort:
      if not inHardSlot and job.id in runnable: consider(job.spec.releaseTick)

proc observeWasmRtRun*(policy: var WasmRtPolicy, id: uint32,
                       startTick, endTick: uint64,
                       memoryFault = false): WasmRtAction =
  ## Observe elapsed wall time after one cooperative VM slice. The caller
  ## must stop a hard task on wrStopJob and must never service its page fault
  ## inside the reserved slot.
  let i = policy.findJob(id)
  if i < 0 or endTick < startTick: return wrKeepRunning
  let spec = policy.jobs[i].spec
  policy.pollWasmRtPolicy(startTick)
  if spec.class == wrHard:
    let currentFrame = policy.frameStart(startTick)
    policy.jobs[i].startedFrame = currentFrame
    policy.jobs[i].hasStartedFrame = true
    if not policy.jobs[i].hasObservedFrame or
        policy.jobs[i].observedFrameStart != currentFrame:
      policy.jobs[i].observedFrameStart = currentFrame
      policy.jobs[i].hasObservedFrame = true
      policy.jobs[i].firstStarted = false
      policy.jobs[i].deadlineCounted = false
      policy.jobs[i].budgetCounted = false
      policy.jobs[i].usedTicks = 0
  let elapsed = endTick - startTick
  inc policy.telemetry.runs
  if elapsed > policy.telemetry.maxSliceTicks:
    policy.telemetry.maxSliceTicks = elapsed
  if not policy.jobs[i].firstStarted:
    policy.jobs[i].firstStarted = true
    inc policy.telemetry.starts
    if spec.class == wrHard:
      let slotStart = policy.frameStart(startTick) + spec.slotOffsetTicks
      let jitter = startTick - slotStart
      if jitter > policy.telemetry.maxStartJitterTicks:
        policy.telemetry.maxStartJitterTicks = jitter
      if jitter > spec.startJitterTicks:
        inc policy.telemetry.startJitterMisses
        result = wrStopJob
  let deadline = if spec.class == wrHard:
    policy.frameStart(startTick) +
      (if spec.deadlineTick != 0: spec.deadlineTick
       else: spec.slotOffsetTicks + spec.slotLengthTicks)
    else: spec.deadlineTick
  if deadline != 0 and endTick > deadline and
      not policy.jobs[i].deadlineCounted:
    policy.jobs[i].deadlineCounted = true
    inc policy.telemetry.deadlineMisses
    if spec.class == wrHard: result = wrStopJob
  if elapsed > spec.maxSliceTicks:
    inc policy.telemetry.sliceOverruns
    if spec.class == wrHard or spec.overrun == wrStop:
      result = wrStopJob
    elif spec.overrun == wrDemote and result != wrStopJob:
      result = wrDemoteJob
  policy.jobs[i].usedTicks = min(high(uint64) - elapsed,
                                 policy.jobs[i].usedTicks) + elapsed
  if spec.budgetTicks > 0 and policy.jobs[i].usedTicks > spec.budgetTicks and
      not policy.jobs[i].budgetCounted:
    policy.jobs[i].budgetCounted = true
    inc policy.telemetry.budgetOverruns
    if spec.class == wrHard or spec.overrun == wrStop:
      result = wrStopJob
    elif spec.overrun == wrDemote and result != wrStopJob:
      result = wrDemoteJob
  if spec.class == wrHard:
    let slotEnd = policy.frameStart(startTick) + spec.slotOffsetTicks +
                  spec.slotLengthTicks
    if endTick > slotEnd or memoryFault:
      if memoryFault: inc policy.telemetry.hardFaults
      result = wrStopJob
  if result == wrDemoteJob:
    policy.jobs[i].spec.class = wrBestEffort

proc wasmRtTelemetry*(policy: WasmRtPolicy): WasmRtTelemetry {.inline.} =
  policy.telemetry

proc wasmRtClass*(policy: WasmRtPolicy, id: uint32): WasmRtClass =
  let i = policy.findJob(id)
  if i >= 0: policy.jobs[i].spec.class else: wrBestEffort
