## Opt-in CPU accounting and flight recorder for the M0 FreeNetRadio build.
## The host tool decodes this fixed little-endian layout. Only completed
## captures are exported. Change ProfileVersion when the layout changes.

import ../[core, hpm, memmap, mmio]

const
  ProfileVersion = 3'u32
  ProfileEvents = 2048
  ProfileIrqCount* = 80
  RadioProfileLateUs {.intdefine.} = 15_000
  WaitBounds = [0'u32, 50, 100, 250, 500, 1_000, 2_000, 4_000, 8_000,
                12_000, 15_000, 20_000, 40_000, 80_000]

type
  ProfileRegion* = enum
    prAudio, prDecode, prDraw, prFlushStart, prFlushEnd, prStream, prHttp,
    prControls, prNtp, prNetwork, prWifiService, prWifiBackend, prWifiFirmware,
    prWifiDeferredTx, prIrq

  ProfileSpan* = object
    session, tick, cycles, instructions: uint32

  ProfileWait* = object
    session, due: uint32

  ProfileTotals = object
    wallUs, cycles, instructions, workCycles: uint64
    calls, work, maxUs, callsWithWork: uint32

  ProfileEvent = object
    atUs, durationUs, value: uint32
    kind, detail: uint16

  ProfileHeader = object
    magic, version, session, elapsedUs: uint32
    wfiUs, wfiCalls, regionCount, traceCapacity: uint32
    eventCount, eventNext, overwritten, traceRequested: uint32
    trigger, triggerAtUs, queueMin, lateUs: uint32
    underruns, irqCount: uint32

  ProfileCapture = object
    header: ProfileHeader
    totals: array[ProfileRegion, ProfileTotals]
    irqs: array[ProfileIrqCount, ProfileTotals]
    sleepDelay, yieldDelay: array[WaitBounds.len + 1, uint32]
    events: array[ProfileEvents, ProfileEvent]
    hardwareCounters: HpmSnapshot
    hardwareEventMask, hardwareReserved: uint32

const
  EventSpan = 1'u16
  EventWait = 2'u16
  EventQueue = 3'u16
  EventTrigger = 4'u16
  TriggerLate = 1'u32
  TriggerUnderrun = 2'u32

static:
  doAssert sizeof(ProfileHeader) == 72 and sizeof(ProfileTotals) == 48
  doAssert sizeof(ProfileEvent) == 16 and sizeof(ProfileCapture) == 37_608
  doAssert RadioProfileLateUs in 1 .. 120_000_000

var
  capture: ptr ProfileCapture
  running, tracing: bool
  startedAt, durationUs, session: uint32
  readers: int
  hpmStarted: HpmSnapshot
  hpmConfig: HpmConfig

proc wallTick(): uint32 {.inline.} =
  ## The BL808 M0 timer runs at 1 MHz. Unsigned deltas handle wrap within a
  ## window, which is limited to two minutes by the HTTP entry point.
  regRead(ClicMtimeBase)

proc cycleLow(): uint32 {.inline.} =
  {.emit: ["asm volatile(\"csrr %0, mcycle\" : \"=r\"(", result, ") :: \"memory\");"].}

proc instretLow(): uint32 {.inline.} =
  {.emit: ["asm volatile(\"csrr %0, minstret\" : \"=r\"(", result, ") :: \"memory\");"].}

proc recordingProfile*(): bool {.inline.} = running

proc startProfile*(windowMs: uint32; recordTrace: bool): bool =
  if running or readers != 0 or windowMs notin 100'u32 .. 120_000'u32: return false
  if capture == nil:
    capture = createShared(ProfileCapture)
    if capture == nil: return false
  # No readers or writers own the buffer here.
  zeroMem(capture, sizeof(ProfileCapture))
  inc session
  if session == 0: inc session
  capture.header = ProfileHeader(magic: 0x46525042'u32, version: ProfileVersion,
    session: session, regionCount: (ord(high(ProfileRegion)) + 1).uint32,
    traceCapacity: ProfileEvents.uint32, traceRequested: recordTrace.uint32,
    queueMin: high(uint32), lateUs: RadioProfileLateUs.uint32,
    irqCount: ProfileIrqCount.uint32)
  durationUs = windowMs * 1000
  withInterruptsDisabled:
    hpmConfig = enableHpm()
    capture.hardwareEventMask = hpmConfig.eventMask
    readHpm(hpmStarted, hpmConfig)
    startedAt = wallTick()
    tracing = recordTrace
    running = true
  true

proc stopProfile*() =
  if running:
    withInterruptsDisabled:
      capture.header.elapsedUs = wallTick() - startedAt
      readHpm(capture.hardwareCounters, hpmConfig)
      for event in low(HpmSnapshot) .. high(HpmSnapshot):
        if (hpmConfig.eventMask and (1'u32 shl ord(event))) != 0:
          capture.hardwareCounters[event] -= hpmStarted[event]
      running = false
      tracing = false

proc expireProfile*() =
  if running and wallTick() - startedAt >= durationUs: stopProfile()

proc borrowProfile*(size: var int): pointer =
  if capture != nil and not running:
    inc readers
    size = sizeof(ProfileCapture)
    result = capture

proc releaseProfile*() =
  dec readers

proc appendEvent(event: ProfileEvent) {.raises: [].} =
  ## The caller serializes task and IRQ writers.
  let header = addr capture.header
  capture.events[header.eventNext] = event
  header.eventNext = (header.eventNext + 1) mod ProfileEvents.uint32
  if header.eventCount < ProfileEvents.uint32: inc header.eventCount
  else: inc header.overwritten

proc beginProfileSpan*(): ProfileSpan {.inline.} =
  if running:
    result.session = session
    result.tick = wallTick()
    result.instructions = instretLow()
    result.cycles = cycleLow()

proc endProfileSpan*(span: ProfileSpan; region: ProfileRegion; work = 0'u32;
                     detail = 0'u16; trace = false) {.raises: [].} =
  if span.session == 0 or not running or span.session != session: return
  let cycles = cycleLow() - span.cycles
  let instructions = instretLow() - span.instructions
  let elapsed = wallTick() - span.tick
  withInterruptsDisabled:
    let totals =
      if region == prIrq: addr capture.irqs[detail]
      else: addr capture.totals[region]
    totals.wallUs += elapsed
    totals.cycles += cycles
    totals.instructions += instructions
    inc totals.calls
    totals.work += work
    totals.maxUs = max(totals.maxUs, elapsed)
    if work != 0:
      inc totals.callsWithWork
      totals.workCycles += cycles
    if tracing and (trace or elapsed >= 200):
      # For IRQ spans the value carries the vector number. Other spans report
      # their work count, except Wi-Fi service which reports the wake source.
      let value =
        if region in {prIrq, prWifiService}: detail.uint32
        else: work
      appendEvent(ProfileEvent(atUs: span.tick - startedAt, durationUs: elapsed,
        kind: EventSpan, detail: region.uint16, value: value))

proc beginProfileIdle*(): uint32 {.inline.} =
  if running: wallTick() else: 0'u32

proc endProfileIdle*(tick: uint32) {.inline.} =
  ## The scheduler calls both sides of WFI with interrupts masked.
  if running:
    capture.header.wfiUs += wallTick() - tick
    inc capture.header.wfiCalls

proc beginProfileWait*(deadline: uint32): ProfileWait {.inline.} =
  if running: ProfileWait(session: session, due: deadline) else: ProfileWait()

proc triggerTrace(reason, atUs, value: uint32) =
  if tracing:
    capture.header.trigger = reason
    capture.header.triggerAtUs = atUs
    appendEvent(ProfileEvent(atUs: atUs, kind: EventTrigger,
      detail: reason.uint16, value: value))
    tracing = false

proc endProfileWait*(wait: ProfileWait; yielded: bool) =
  if wait.session == 0 or not running or wait.session != session: return
  let tick = wallTick()
  let late = max(cast[int32](tick - wait.due), 0).uint32
  var bucket = 0
  while bucket < WaitBounds.len and late > WaitBounds[bucket]: inc bucket
  withInterruptsDisabled:
    if yielded: inc capture.yieldDelay[bucket]
    else: inc capture.sleepDelay[bucket]
    if tracing:
      let atUs = tick - startedAt
      # A capture can start while the audio task is already asleep. Tokens
      # are only issued during the matching capture, so their due is in-window.
      appendEvent(ProfileEvent(atUs: atUs, durationUs: late, kind: EventWait,
        detail: yielded.uint16))
      if late >= RadioProfileLateUs.uint32:
        triggerTrace(TriggerLate, atUs, late)

proc profileAudioQueue*(frames: uint32; underrun = false) =
  if running:
    capture.header.queueMin = min(capture.header.queueMin, frames)
    if underrun: inc capture.header.underruns
    if tracing:
      let atUs = wallTick() - startedAt
      withInterruptsDisabled:
        appendEvent(ProfileEvent(atUs: atUs, kind: EventQueue, value: frames))
        if underrun: triggerTrace(TriggerUnderrun, atUs, frames)
