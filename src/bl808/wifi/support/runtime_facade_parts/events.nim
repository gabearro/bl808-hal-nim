const
  AosEventQueueCapacity = 64
  AosEventFilterCapacity = 16
  AosDelayedActionCapacity = 32
  AosEventUrgent = 0x8000'u16
  AosErrInvalid = -22.cint
  AosErrNoMemory = -12.cint
  AosErrClock = -5.cint

type
  AosInputEvent = object
    time: uint32
    eventType, code: uint16
    value, extra: culong
  AosEventFilter = object
    eventType: uint16
    callback, privateData: pointer
  AosDelayedAction = object
    deadlineMs: uint64
    delayMs: cint
    action, arg: pointer

static:
  doAssert offsetOf(AosInputEvent, eventType) == 4
  doAssert offsetOf(AosInputEvent, code) == 6
  doAssert offsetOf(AosInputEvent, value) == 8
  when sizeof(culong) == 4:
    doAssert offsetOf(AosInputEvent, extra) == 12
    doAssert sizeof(AosInputEvent) == 16

var
  aosEventQueue: array[AosEventQueueCapacity, AosInputEvent]
  aosEventHead, aosEventCount: int
  aosEventFilters: array[AosEventFilterCapacity, AosEventFilter]
  aosEventFilterCount: int
  aosDispatching: bool
  aosDelayedActions: array[AosDelayedActionCapacity, AosDelayedAction]
  aosDelayedCount: int
  aosDelayedDispatching: bool

proc aosEventsPending(): bool =
  aosEventCount != 0

proc aos_post_event*(`type`, code: uint16; value: culong): cint {.exportc, cdecl.} =
  let event = AosInputEvent(
    eventType: `type` and not AosEventUrgent,
    code: code,
    value: value)
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  if aosEventCount == AosEventQueueCapacity:
    return -1
  if (`type` and AosEventUrgent) != 0:
    aosEventHead = (aosEventHead + AosEventQueueCapacity - 1) mod AosEventQueueCapacity
    aosEventQueue[aosEventHead] = event
  else:
    let tail = (aosEventHead + aosEventCount) mod AosEventQueueCapacity
    aosEventQueue[tail] = event
  inc aosEventCount
  vendorNotifyWork()
  sizeof(AosInputEvent).cint

proc aos_register_event_filter*(`type`: uint16; cb, privateData: pointer): cint
    {.exportc, cdecl.} =
  if cb == nil:
    return AosErrInvalid
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  if aosEventFilterCount == AosEventFilterCapacity:
    return AosErrNoMemory
  aosEventFilters[aosEventFilterCount] =
    AosEventFilter(eventType: `type`, callback: cb, privateData: privateData)
  inc aosEventFilterCount
  0

proc aos_unregister_event_filter*(`type`: uint16; cb, privateData: pointer): cint
    {.exportc, cdecl.} =
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  for i in 0 ..< aosEventFilterCount:
    if aosEventFilters[i].eventType == `type` and
        aosEventFilters[i].callback == cb and
        aosEventFilters[i].privateData == privateData:
      for next in i + 1 ..< aosEventFilterCount:
        aosEventFilters[next - 1] = aosEventFilters[next]
      dec aosEventFilterCount
      aosEventFilters[aosEventFilterCount] = default(AosEventFilter)
      return 0
  AosErrInvalid

proc aosPollEvents() =
  let initialState = osEnterCritical()
  if aosDispatching or (initialState and 8'u32) == 0:
    osExitCritical(initialState)
    return
  aosDispatching = true
  osExitCritical(initialState)
  try:
    var budget = 16
    while budget != 0:
      dec budget
      let saved = osEnterCritical()
      if aosEventCount == 0:
        osExitCritical(saved)
        break
      var event = aosEventQueue[aosEventHead]
      aosEventHead = (aosEventHead + 1) mod AosEventQueueCapacity
      dec aosEventCount
      var filters: array[AosEventFilterCapacity, AosEventFilter]
      let filterCount = aosEventFilterCount
      for i in 0 ..< filterCount:
        filters[i] = aosEventFilters[i]
      osExitCritical(saved)
      for i in 0 ..< filterCount:
        if filters[i].eventType == 0'u16 or
            filters[i].eventType == event.eventType:
          cast[proc(event: ptr AosInputEvent; privateData: pointer) {.cdecl.}](
            filters[i].callback)(addr event, filters[i].privateData)
  finally:
    let saved = osEnterCritical()
    aosDispatching = false
    osExitCritical(saved)

proc aos_post_delayed_action*(ms: cint; action, arg: pointer): cint {.exportc, cdecl.} =
  if action == nil:
    return AosErrInvalid
  var nowUs: uint64
  if not sampleMtimeUs(nowUs):
    return AosErrClock
  # Preserve signed offsets so a negative delay sorts before a zero delay.
  let deadline = nowUs div 1000'u64 + cast[uint64](ms.int64)
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  if aosDelayedCount == AosDelayedActionCapacity:
    return AosErrNoMemory
  var pos = aosDelayedCount
  while pos > 0 and
      cast[int64](deadline - aosDelayedActions[pos - 1].deadlineMs) < 0:
    aosDelayedActions[pos] = aosDelayedActions[pos - 1]
    dec pos
  aosDelayedActions[pos] = AosDelayedAction(
    deadlineMs: deadline, delayMs: ms, action: action, arg: arg)
  inc aosDelayedCount
  vendorNotifyWork()
  0

proc aosNextDelayedDelayUs(nowUs: uint64): uint64 =
  ## The list is ordered. A negative delay wraps in storage, so compare it
  ## with the same signed-difference rule used by aosPollDelayedActions.
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  if aosDelayedCount == 0:
    return high(uint64)
  let remainingMs = cast[int64](aosDelayedActions[0].deadlineMs - nowUs div 1000'u64)
  if remainingMs <= 0: 0'u64 else: remainingMs.uint64 * 1000'u64

proc aos_cancel_delayed_action*(ms: cint; action, arg: pointer) {.exportc, cdecl.} =
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  for i in 0 ..< aosDelayedCount:
    if (ms == -1 or aosDelayedActions[i].delayMs == ms) and
        aosDelayedActions[i].action == action and
        aosDelayedActions[i].arg == arg:
      for next in i + 1 ..< aosDelayedCount:
        aosDelayedActions[next - 1] = aosDelayedActions[next]
      dec aosDelayedCount
      aosDelayedActions[aosDelayedCount] = default(AosDelayedAction)
      return

proc aosPollDelayedActions() =
  let initialState = osEnterCritical()
  if aosDelayedDispatching or (initialState and 8'u32) == 0:
    osExitCritical(initialState)
    return
  aosDelayedDispatching = true
  osExitCritical(initialState)
  try:
    var budget = 16
    while budget != 0:
      dec budget
      var nowUs: uint64
      if not sampleMtimeUs(nowUs):
        break
      let nowMs = nowUs div 1000'u64
      let saved = osEnterCritical()
      if aosDelayedCount == 0 or
          cast[int64](nowMs - aosDelayedActions[0].deadlineMs) < 0:
        osExitCritical(saved)
        break
      let due = aosDelayedActions[0]
      for i in 1 ..< aosDelayedCount:
        aosDelayedActions[i - 1] = aosDelayedActions[i]
      dec aosDelayedCount
      aosDelayedActions[aosDelayedCount] = default(AosDelayedAction)
      osExitCritical(saved)
      cast[proc(arg: pointer) {.cdecl.}](due.action)(due.arg)
  finally:
    let saved = osEnterCritical()
    aosDelayedDispatching = false
    osExitCritical(saved)
