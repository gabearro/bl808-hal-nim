## Sleep, event group, event notification, and task adapter callbacks.

proc osSleepUs(duration: uint64) =
  if duration == 0:
    return
  var remaining = duration
  var previous: uint64
  var hadClock = sampleMtimeUs(previous)
  while remaining != 0:
    let quantum = min(remaining, 100'u64).uint32
    vendorPollOnce()
    delayMtimeUs(quantum)
    var now: uint64
    let hasClock = sampleMtimeUs(now)
    var elapsed = quantum.uint64
    if hadClock and hasClock:
      let observed = now - previous
      if cast[int64](observed) > 0:
        elapsed = max(elapsed, observed)
    # A completed delay also supplies progress when the clock is unavailable.
    remaining -= min(remaining, elapsed)
    previous = now
    hadClock = hasClock

proc osMsleep(ms: clong): cint {.cdecl.} =
  if ms <= 0:
    return 1
  osSleepUs(ms.uint64 * 1000'u64)
  1

proc osSleep(seconds: cuint): cint {.cdecl.} =
  osSleepUs(seconds.uint64 * 1000000'u64)
  1

proc osEventGroupCreate(): pointer {.cdecl.} = c_calloc(1, sizeof(SimpleEventGroup).csize_t)
proc osEventGroupDelete(event: pointer) {.cdecl.} = osObjectDelete(event)
proc osEventGroupSend(event: pointer; bits: uint32): uint32 {.cdecl.} =
  if not osObjectRetain(event):
    return 0
  defer: osObjectRelease(event)
  let g = cast[ptr SimpleEventGroup](event)
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  if g.header.deleted:
    return 0
  g.bits = g.bits or bits
  var clearMask = 0'u32
  var waiter = g.waiters
  while waiter != nil:
    if not waiter.ready and osEventMatches(g.bits, waiter.mask, waiter.waitForAll):
      waiter.value = g.bits
      waiter.ready = true
      if waiter.clearOnExit:
        clearMask = clearMask or waiter.mask
    waiter = waiter.next
  # All matching waits receive the same pre-clear snapshot.
  g.bits = g.bits and not clearMask
  g.bits
proc osEventGroupWait(event: pointer; bitsToWaitFor: uint32; clearOnExit, waitForAll: cint;
                      blockTimeTick: uint32): uint32 {.cdecl.} =
  if not osObjectRetain(event):
    return 0
  defer: osObjectRelease(event)
  let g = cast[ptr SimpleEventGroup](event)
  var waiter = OsEventWaiter(mask: bitsToWaitFor, clearOnExit: clearOnExit != 0,
    waitForAll: waitForAll != 0)
  var linked = false
  defer:
    if linked:
      let saved = osEnterCritical()
      if g.waiters == addr waiter:
        g.waiters = waiter.next
      else:
        var previous = g.waiters
        while previous != nil:
          if previous.next == addr waiter:
            previous.next = waiter.next
            break
          previous = previous.next
      osExitCritical(saved)
  var state = osWaitState(blockTimeTick)
  var waitMore = blockTimeTick != 0
  while true:
    block:
      let saved = osEnterCritical()
      defer: osExitCritical(saved)
      if waiter.ready:
        return waiter.value
      if g.header.deleted:
        return 0
      let snapshot = g.bits
      if osEventMatches(snapshot, bitsToWaitFor, waiter.waitForAll):
        if waiter.clearOnExit:
          g.bits = g.bits and not bitsToWaitFor
        return snapshot
      if not waitMore:
        return snapshot
      if not linked:
        waiter.next = g.waiters
        g.waiters = addr waiter
        linked = true
    waitMore = osWaitAgain(state)

proc osEventRegister(t: cint; cb, arg: pointer): cint {.cdecl.} =
  discard t; discard cb; discard arg; 0
proc osEventNotify(evt, value: cint): cint {.cdecl.} =
  aos_post_event(2'u16, (evt.uint32 and 0xFFFF'u32).uint16,
                 cast[uint32](value).culong)
proc osTaskCreate(name: cstring; entry: pointer; stackDepth: uint32; param: pointer;
                  prio: uint32; taskHandle: pointer): cint {.cdecl.} =
  discard name; discard entry; discard stackDepth; discard param; discard prio; discard taskHandle
  # No scheduler exists here; never report a FreeRTOS task as ready.
  -1
proc osTaskDelete(taskHandle: pointer) {.cdecl.} = discard taskHandle
proc osTaskGetCurrent(): pointer {.cdecl.} = addr osTaskNotifications
proc osTaskNotifyCreate(): pointer {.cdecl.} = osTaskGetCurrent()
proc osTaskNotify(taskHandle: pointer) {.cdecl.} =
  # The cooperative M0 adapter has one current execution context, not RTOS tasks.
  if taskHandle != osTaskGetCurrent():
    return
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  osTaskNotifications = osTaskNotifications + 1'u32
proc osTaskWait(taskHandle: pointer; tick: uint32) {.cdecl.} =
  discard taskHandle
  var state = osWaitState(tick)
  var waitMore = tick != 0
  while true:
    block:
      let saved = osEnterCritical()
      defer: osExitCritical(saved)
      if osTaskNotifications != 0:
        osTaskNotifications = 0
        return
      if not waitMore:
        return
    waitMore = osWaitAgain(state)
proc osNoopVoid() {.cdecl.} = discard
