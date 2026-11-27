## Cooperative waits and lifetime pins for opaque adapter objects.

type OsWaitState = object
  remainingUs, previous: uint64
  forever, started, hadClock: bool

proc osWaitState(ticks: uint32): OsWaitState =
  OsWaitState(remainingUs: ticks.uint64 * 1000'u64,
    forever: ticks == BlOsWaitingForever)

proc osWaitAgain(state: var OsWaitState): bool =
  when defined(radioDiag):
    if wifiSchedulerWorkHook != nil:
      inc wifiCpsNestedWaitPolls
  if not state.forever and state.remainingUs == 0:
    return false
  let saved = osEnterCritical()
  osExitCritical(saved)
  # A callback may complete an operation in a critical section, but not block.
  if (saved and 8'u32) == 0:
    return false
  if not state.started:
    state.hadClock = sampleMtimeUs(state.previous)
    state.started = true
  let quantum = if state.forever: 100'u32
                else: min(state.remainingUs, 100'u64).uint32
  vendorPollOnce()
  delayMtimeUs(quantum)
  var now: uint64
  let hasClock = sampleMtimeUs(now)
  var elapsed = quantum.uint64
  if state.hadClock and hasClock:
    let observed = now - state.previous
    if cast[int64](observed) > 0:
      elapsed = max(elapsed, observed)
  if not state.forever:
    state.remainingUs -= min(state.remainingUs, elapsed)
  state.previous = now
  state.hadClock = hasClock
  # Even the last quantum must be followed by a condition check.
  true

proc osObjectRetain(handle: pointer): bool =
  if handle == nil:
    return false
  let header = cast[ptr OsObjectHeader](handle)
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  if header.deleted or header.users == high(uint32):
    return false
  inc header.users
  true

proc osObjectRelease(handle: pointer) =
  let header = cast[ptr OsObjectHeader](handle)
  let saved = osEnterCritical()
  dec header.users
  let dispose = header.deleted and header.users == 0
  osExitCritical(saved)
  if dispose:
    c_free(handle)

proc osObjectDelete(handle: pointer) =
  if handle == nil:
    return
  let header = cast[ptr OsObjectHeader](handle)
  let saved = osEnterCritical()
  header.deleted = true
  let dispose = header.users == 0
  osExitCritical(saved)
  if dispose:
    c_free(handle)

proc osEventMatches(value, mask: uint32; waitForAll: bool): bool =
  if waitForAll: (value and mask) == mask
  else: (value and mask) != 0
