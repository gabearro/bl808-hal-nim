## Per-core cooperative scheduler for the BL808 kernel.
##
## Drives CPS green threads via a simple run loop:
##   1. Drain ISR-posted callbacks
##   2. Fire expired timers (tickless — only programs next deadline)
##   3. Run priority IRQ work and one ready batch (CPS continuation steps)
##   4. Run poll hooks and recheck timers before considering WFI
##
## There is one global `scheduler` instance per core.
## All public API is safe to call from task context.
## The ISR posting APIs are safe to call from interrupt context.

import ../core, ../irq
import ./clock
import ./fault
import ./isrbridge
when defined(bl808m0) and defined(radioProfiler):
  import ./profiler

const
  MaxIsrPendingCallbacks* = 32
    ## Fixed ISR callback queue depth. postFromIsr drops callbacks after this
    ## limit and records an overflow count instead of allocating in interrupt
    ## context.
  MaxSchedulerTimers* {.intdefine.} = 32
    ## Bounded timer heap backing store. Timer entries carry closures, so the
    ## heap stores stable pointers to these slots instead of copying entries.
  MaxSchedulerTimedPollHooks* = 8
    ## Bounded count of scheduler-owned timed poll hooks.

static:
  doAssert MaxSchedulerTimers >= 1 and MaxSchedulerTimers <= 32

# =============================================================================
# Timer heap entry
# =============================================================================

type
  TimerId* = uint32

  TimerEntryObj = object
    deadline: uint64
    id: TimerId
    callback: proc() {.closure.}
    cancelled: bool

  TimerEntry = ptr TimerEntryObj

# =============================================================================
# Scheduler state
# =============================================================================

type
  SchedulerPriorityCallback* = proc() {.nimcall.}
  SchedulerPriorityReady* = proc(): bool {.nimcall.}

  Scheduler* = object
    ready: seq[proc() {.closure.}]
      ## Callbacks ready to run this iteration.
    readySpare: seq[proc() {.closure.}]
      ## Reused storage for the next ready batch.
    isrPending: array[MaxIsrPendingCallbacks, proc() {.closure.}]
      ## Fixed queue of callbacks posted from ISR context.
    isrHead, isrTail, isrCount: int
    isrOverflow: uint64
    priorityCallback: SchedulerPriorityCallback
    priorityReady: SchedulerPriorityReady
    priorityRan: bool
    timers: seq[TimerEntry]
      ## Min-heap ordered by deadline.
    nextTimerId: TimerId
    running*: bool
    totalTicks: uint64
      ## Number of scheduler loop iterations.
    totalCallbacks: uint64
      ## Total callbacks executed.
    totalTimersFired: uint64
      ## Total timer callbacks fired.

var scheduler*: Scheduler
  ## The global scheduler for this core.

when defined(radioDiag) or defined(radioCpuMeter):
  type SchedulerCpuTiming* = object
    elapsedUs*, wfiUs*, wfiCalls*: uint64

  # The raw ticks are also readable through JTAG in a build without HTTP
  # diagnostics, so the CPU meter does not need the radioDiag hot-path probes.
  var schedulerCpuEpochTick* {.exportc.}: uint64
  var schedulerCpuNowTick* {.exportc.}: uint64
  var schedulerWfiTicks* {.exportc.}: uint64
  var schedulerWfiCalls* {.exportc.}: uint64

  proc schedulerCpuTimingReset*() =
    schedulerCpuEpochTick = readTick()
    schedulerCpuNowTick = schedulerCpuEpochTick
    schedulerWfiTicks = 0
    schedulerWfiCalls = 0

  proc schedulerCpuTimingSnapshot*(): SchedulerCpuTiming =
    SchedulerCpuTiming(
      elapsedUs: ticksToUs(readTick() - schedulerCpuEpochTick),
      wfiUs: ticksToUs(schedulerWfiTicks),
      wfiCalls: schedulerWfiCalls)

when defined(radioDiag):
  type SchedulerTiming* = object
    maxIterationUs*, maxReadyBatchUs*, maxReadyCallbackUs*: uint32
    maxTimerCallbackUs*, maxPollHookUs*, maxTimedHookUs*: uint32
    maxReadyBatchLen*, longIterations*: uint32
    maxTimerLatenessUs*, maxBetweenIterationsUs*, lateTimersOver15ms*: uint32

  type SchedulerSlowTurn* = object
    ## A bounded trace of turns that keep every ready task waiting >15 ms.
    ## Fixed-size fields make the ring readable through OpenOCD `mdw`.
    atMs*, totalUs*, firstTimersUs*, readyUs*, timedUs*, lastTimersUs*: uint32
    wifiUs*, readyMaxUs*, timerMaxUs*, readyCount*: uint32

  # Slow turns are recorded infrequently. Keep the trace outside cached OCRAM
  # on Wi-Fi application builds so the TX pools can grow without taking stack.
  when defined(bl808m0) and defined(bl808WifiApp):
    {.pragma: schedulerTraceRam, codegenDecl: "$# $# __attribute__((section(\".wifibss.scheduler_diag\"), aligned(16)))".}
  else:
    {.pragma: schedulerTraceRam.}

  var schedulerTiming: SchedulerTiming
  var schedulerSlowTurns* {.schedulerTraceRam.}: array[32, SchedulerSlowTurn]
  var schedulerSlowCount*: uint32
  var lastIterationEndTick: uint64
  var iterationWifiUs, iterationReadyMaxUs, iterationTimerMaxUs: uint32
  var iterationReadyCount: uint32

  proc schedulerTimingSnapshot*(): SchedulerTiming = schedulerTiming

  proc schedulerTimingReset*() =
    schedulerTiming = default(SchedulerTiming)
    schedulerSlowTurns = default(array[32, SchedulerSlowTurn])
    schedulerSlowCount = 0

  proc schedulerTimingAddWifiUs*(elapsedUs: uint32) =
    iterationWifiUs += elapsedUs

  proc schedulerElapsedUs(startTick: uint64): uint32 {.inline.} =
    uint32(min(ticksToUs(readTick() - startTick), high(uint32).uint64))

var
  timerPool: array[MaxSchedulerTimers, TimerEntryObj]
  timerPoolUsed: array[MaxSchedulerTimers, bool]

type
  SchedulerPollHook* = proc() {.closure.}
    ## Optional per-iteration polling hook signature.
  SchedulerTimedPollHook* = proc(now: uint64): uint64 {.closure.}
    ## Timed poll hook. Called when its deadline expires. Return the next
    ## absolute tick deadline, or 0 to disable future timed polling.
  TimedPollHookEntry = object
    hook: SchedulerTimedPollHook
    deadline: uint64

var schedulerPollHook*: SchedulerPollHook = nil
  ## Legacy single poll hook. Prefer addSchedulerPollHook for subsystems.

var schedulerPollHooks: seq[SchedulerPollHook]
  ## Additional hooks called each scheduler iteration for polling-based I/O.

var
  schedulerTimedPollHooks: array[MaxSchedulerTimedPollHooks, TimedPollHookEntry]
  schedulerTimedPollHookCount: int

proc setSchedulerPollHook*(hook: SchedulerPollHook) =
  ## Register/replace the legacy scheduler polling hook.
  schedulerPollHook = hook

proc addSchedulerPollHook*(hook: SchedulerPollHook) =
  ## Add a scheduler polling hook without replacing existing subsystems.
  if hook != nil:
    schedulerPollHooks.add(hook)

proc addSchedulerTimedPollHook*(hook: SchedulerTimedPollHook;
                                firstDeadline: uint64 = 0'u64): bool =
  ## Add a timed scheduler polling hook. Timed hooks let subsystems do bounded
  ## high-frequency service without keeping the scheduler permanently awake.
  if hook == nil or schedulerTimedPollHookCount >= MaxSchedulerTimedPollHooks:
    return false
  schedulerTimedPollHooks[schedulerTimedPollHookCount] = TimedPollHookEntry(
    hook: hook,
    deadline: firstDeadline,
  )
  schedulerTimedPollHookCount.inc
  true

proc rescheduleSchedulerTimedPollHook*(hook: SchedulerTimedPollHook,
                                        deadline: uint64): bool =
  ## Change an installed hook from task context. Zero disarms it until the
  ## next call. The run loop includes the new deadline before entering WFI.
  if hook == nil: return false
  for i in 0 ..< schedulerTimedPollHookCount:
    if schedulerTimedPollHooks[i].hook == hook:
      schedulerTimedPollHooks[i].deadline = deadline
      return true
  false

# =============================================================================
# Min-heap operations on scheduler.timers
# =============================================================================

proc heapLen(s: Scheduler): int {.inline.} = s.timers.len

proc allocTimerEntry(deadline: uint64, id: TimerId,
                     callback: proc() {.closure.}): TimerEntry =
  for i in 0 ..< MaxSchedulerTimers:
    if not timerPoolUsed[i]:
      timerPoolUsed[i] = true
      timerPool[i] = TimerEntryObj(
        deadline: deadline,
        id: id,
        callback: callback,
        cancelled: false,
      )
      return addr timerPool[i]
  nil

proc releaseTimerEntry(entry: TimerEntry) =
  if entry == nil:
    return
  for i in 0 ..< MaxSchedulerTimers:
    if entry == addr timerPool[i]:
      var retiredCallback = move entry.callback
      entry.deadline = 0
      entry.id = 0
      entry.cancelled = false
      timerPoolUsed[i] = false
      retiredCallback = nil
      return

proc heapPush(s: var Scheduler, entry: TimerEntry) =
  s.timers.add(entry)
  # Sift up
  var i = s.timers.len - 1
  while i > 0:
    let parent = (i - 1) shr 1
    if s.timers[i].deadline < s.timers[parent].deadline:
      swap(s.timers[i], s.timers[parent])
      i = parent
    else:
      break

proc heapPeekDeadline(s: Scheduler): uint64 {.inline.} =
  s.timers[0].deadline

proc heapRemove(s: var Scheduler, index: int): TimerEntry =
  result = s.timers[index]
  let last = s.timers.len - 1
  if index == last:
    s.timers.setLen(last)
    return
  s.timers[index] = s.timers[last]
  s.timers.setLen(last)
  var i = index
  if i > 0 and s.timers[i].deadline < s.timers[(i - 1) shr 1].deadline:
    while i > 0:
      let parent = (i - 1) shr 1
      if s.timers[i].deadline >= s.timers[parent].deadline:
        break
      swap(s.timers[i], s.timers[parent])
      i = parent
    return
  # Sift down
  while true:
    let left = 2 * i + 1
    let right = 2 * i + 2
    var smallest = i
    if left < s.timers.len and
       s.timers[left].deadline < s.timers[smallest].deadline:
      smallest = left
    if right < s.timers.len and
       s.timers[right].deadline < s.timers[smallest].deadline:
      smallest = right
    if smallest == i: break
    swap(s.timers[i], s.timers[smallest])
    i = smallest

proc heapPop(s: var Scheduler): TimerEntry =
  s.heapRemove(0)

# =============================================================================
# Timer interrupt handler
# =============================================================================

var
  timerIsrFired*: bool = false
  programmedTimerDeadline: uint64 = 0
  firedTimerDeadline: uint64 = 0

proc timerIsrHandler() {.cdecl.} =
  ## Machine timer interrupt handler (cause 7).
  ## Clears the pending interrupt by pushing mtimecmp to max.
  ## The scheduler's main loop handles actually firing expired timers.
  firedTimerDeadline = programmedTimerDeadline
  programmedTimerDeadline = 0
  clearDeadline()
  timerIsrFired = true

# =============================================================================
# Scheduler init
# =============================================================================

proc schedulerInit*(pollingOnly: static bool = false) =
  ## Initialize the scheduler. Call once at boot after heapInit().
  when defined(radioDiag):
    schedulerTimingReset()
    lastIterationEndTick = 0'u64
  when defined(radioDiag) or defined(radioCpuMeter):
    schedulerCpuTimingReset()
  scheduler.ready = @[]
  scheduler.readySpare = @[]
  scheduler.timers = @[]
  schedulerPollHook = nil
  schedulerPollHooks = @[]
  schedulerTimedPollHookCount = 0
  for i in 0 ..< MaxSchedulerTimedPollHooks:
    schedulerTimedPollHooks[i].hook = nil
    schedulerTimedPollHooks[i].deadline = 0
  for i in 0 ..< MaxIsrPendingCallbacks:
    scheduler.isrPending[i] = nil
  scheduler.isrHead = 0
  scheduler.isrTail = 0
  scheduler.isrCount = 0
  scheduler.isrOverflow = 0
  scheduler.priorityCallback = nil
  scheduler.priorityReady = nil
  scheduler.priorityRan = false
  scheduler.nextTimerId = 1
  scheduler.running = false
  scheduler.totalTicks = 0
  scheduler.totalCallbacks = 0
  scheduler.totalTimersFired = 0
  for i in 0 ..< MaxSchedulerTimers:
    timerPoolUsed[i] = false
    timerPool[i].callback = nil
    timerPool[i].deadline = 0
    timerPool[i].id = 0
    timerPool[i].cancelled = false

  # Initialize the ISR bridge
  isrBridgeInit()

  when not pollingOnly:
    registerTrapHandler(MachineTimerIrq, timerIsrHandler)
    enableTimerIrq()

# =============================================================================
# Posting callbacks
# =============================================================================

proc post*(cb: proc() {.closure.}) =
  ## Schedule a callback to run on the next scheduler iteration.
  ## Safe to call from task context only.
  scheduler.ready.add(cb)

proc tryPostFromIsr*(cb: proc() {.closure.}): bool =
  ## Schedule a callback from ISR context.
  ## The callback will be drained into the ready queue on the next iteration.
  ## Interrupts must already be disabled when calling this.
  if scheduler.isrCount >= MaxIsrPendingCallbacks:
    scheduler.isrOverflow.inc
    return false
  scheduler.isrPending[scheduler.isrHead] = cb
  scheduler.isrHead = (scheduler.isrHead + 1) mod MaxIsrPendingCallbacks
  scheduler.isrCount.inc
  true

proc postFromIsr*(cb: proc() {.closure.}) =
  ## Compatibility entry for callers that do not need overflow recovery.
  discard tryPostFromIsr(cb)

proc tryPostPriorityFromIsr*(cb: SchedulerPriorityCallback;
                             ready: SchedulerPriorityReady): bool =
  ## Post bounded work to the scheduler's coalescing priority slot.
  ## With interrupts already masked, a repeat post of the same callback
  ## succeeds without taking another slot. A different producer can use
  ## the ordinary ISR queue when this slot is occupied.
  ## The ready predicate allows early execution at a callback boundary.
  ## Pending work also gets a turn at the end of a ready batch.
  if cb == nil: return false
  if scheduler.priorityCallback == nil:
    scheduler.priorityCallback = cb
    scheduler.priorityReady = ready
    return true
  scheduler.priorityCallback == cb

# =============================================================================
# Timer management
# =============================================================================

proc addTimer*(deadline: uint64, callback: proc() {.closure.}): TimerId =
  ## Schedule `callback` to fire at or after `deadline` (absolute tick count).
  ## Returns a timer ID that can be used to cancel it.
  let id = scheduler.nextTimerId
  scheduler.nextTimerId += 1
  let entry = allocTimerEntry(deadline, id, callback)
  if entry == nil:
    faultHalt(FaultReasonManual, 0x54494D52'u, scheduler.timers.len.uint, 0'u)
  scheduler.heapPush(entry)
  # If this timer is now the soonest, reprogram the hardware
  if scheduler.timers[0].id == id:
    programmedTimerDeadline = deadline
    setDeadline(deadline)
  id

proc addTimerMs*(ms: uint64, callback: proc() {.closure.}): TimerId =
  addTimer(deadlineFromNowMs(ms), callback)

proc addTimerUs*(us: uint64, callback: proc() {.closure.}): TimerId =
  addTimer(deadlineFromNow(us), callback)

proc reprogramNextDeadline(s: Scheduler) {.inline.}

proc cancelTimer*(id: TimerId) =
  ## Cancel a pending timer and release its slot. The callback will not fire.
  ## O(n) scan — acceptable for typical timer counts.
  for i in 0 ..< scheduler.timers.len:
    if scheduler.timers[i].id == id:
      let entry = scheduler.heapRemove(i)
      reprogramNextDeadline(scheduler)
      # Closure cleanup may schedule work; retire the heap entry first.
      releaseTimerEntry(entry)
      return

# =============================================================================
# Main scheduler loop
# =============================================================================

proc drainIsrPending(s: var Scheduler) {.inline.} =
  ## Move ISR-posted callbacks into the ready queue.
  ## Must be called with interrupts disabled.
  while s.isrCount > 0:
    let cb = s.isrPending[s.isrTail]
    s.isrPending[s.isrTail] = nil
    s.isrTail = (s.isrTail + 1) mod MaxIsrPendingCallbacks
    s.isrCount.dec
    if cb != nil:
      s.ready.add(cb)

proc runPriorityCallback(s: var Scheduler; earlyOnly: static bool) =
  let cb = s.priorityCallback
  if cb == nil or s.priorityRan: return
  when earlyOnly:
    if s.priorityReady == nil or not s.priorityReady(): return
  # A producer can post again as soon as we take the slot. Work posted by
  # the callback waits for an ordinary callback or a new scheduler turn.
  withInterruptsDisabled:
    s.priorityCallback = nil
    s.priorityReady = nil
  s.priorityRan = true
  cb()
  inc s.totalCallbacks

proc fireExpiredTimers(s: var Scheduler) =
  ## Pop and fire all timers whose deadline has passed.
  ## If the timer ISR fired but readTick appears stale in emulation, treat the
  ## programmed compare value as the effective current time.
  var now = readTick()
  var interruptDeadline = 0'u64
  if timerIsrFired:
    timerIsrFired = false
    interruptDeadline = firedTimerDeadline
    firedTimerDeadline = 0
    if interruptDeadline > now:
      now = interruptDeadline
  while s.heapLen > 0:
    if s.heapPeekDeadline > now:
      break
    when defined(radioDiag):
      let lateness = uint32(min(ticksToUs(now - s.heapPeekDeadline),
                                high(uint32).uint64))
      schedulerTiming.maxTimerLatenessUs = max(
        schedulerTiming.maxTimerLatenessUs, lateness)
      if lateness > 15_000'u32:
        inc schedulerTiming.lateTimersOver15ms
    let entry = s.heapPop()
    let shouldFire = not entry.cancelled
    var callback = move entry.callback
    # A callback may replace its own timer while every pool slot is occupied.
    releaseTimerEntry(entry)
    if shouldFire:
      when defined(radioDiag):
        let callbackStart = readTick()
      callback()
      when defined(radioDiag):
        let elapsed = schedulerElapsedUs(callbackStart)
        schedulerTiming.maxTimerCallbackUs = max(
          schedulerTiming.maxTimerCallbackUs, elapsed)
        iterationTimerMaxUs = max(iterationTimerMaxUs, elapsed)
      s.totalTimersFired += 1
      s.priorityRan = false
      s.runPriorityCallback(earlyOnly = true)
    callback = nil
    now = readTick()
    if interruptDeadline > now:
      now = interruptDeadline

proc runReadyCallbacks(s: var Scheduler) =
  ## Run the ready batch present on entry. Ordinary posts wait for the next
  ## iteration. Allow one bounded priority callback after each ready callback.
  if s.ready.len == 0: return
  when defined(radioDiag):
    let batchStart = readTick()
    schedulerTiming.maxReadyBatchLen = max(
      schedulerTiming.maxReadyBatchLen, s.ready.len.uint32)
  var batch = move s.ready
  s.ready = move s.readySpare
  for i in 0 ..< batch.len:
    when defined(radioDiag):
      let callbackStart = readTick()
    batch[i]()
    when defined(radioDiag):
      let elapsed = schedulerElapsedUs(callbackStart)
      schedulerTiming.maxReadyCallbackUs = max(
        schedulerTiming.maxReadyCallbackUs, elapsed)
      iterationReadyMaxUs = max(iterationReadyMaxUs, elapsed)
      inc iterationReadyCount
    s.totalCallbacks += 1
    s.priorityRan = false
    s.runPriorityCallback(earlyOnly = true)
  # Preserve the order of ISR work arriving during the batch and posts from hooks.
  withInterruptsDisabled:
    s.drainIsrPending()
  when defined(radioDiag):
    schedulerTiming.maxReadyBatchUs = max(
      schedulerTiming.maxReadyBatchUs, schedulerElapsedUs(batchStart))
  batch.setLen(0)
  s.readySpare = move batch

proc reprogramNextDeadline(s: Scheduler) {.inline.} =
  ## Set the hardware timer to fire at the next timer heap entry,
  ## or clear it if no timers are pending.
  var nextDeadline = 0'u64
  if s.heapLen > 0:
    nextDeadline = s.heapPeekDeadline
  for i in 0 ..< schedulerTimedPollHookCount:
    let deadline = schedulerTimedPollHooks[i].deadline
    if schedulerTimedPollHooks[i].hook != nil and deadline != 0'u64:
      if nextDeadline == 0'u64 or deadline < nextDeadline:
        nextDeadline = deadline
  if nextDeadline != 0'u64:
    programmedTimerDeadline = nextDeadline
    setDeadline(programmedTimerDeadline)
  else:
    programmedTimerDeadline = 0
    clearDeadline()

proc runPollHooks() =
  if schedulerPollHook != nil:
    when defined(radioDiag):
      let hookStart = readTick()
    schedulerPollHook()
    when defined(radioDiag):
      schedulerTiming.maxPollHookUs = max(
        schedulerTiming.maxPollHookUs, schedulerElapsedUs(hookStart))
  for hook in schedulerPollHooks:
    if hook != nil:
      when defined(radioDiag):
        let hookStart = readTick()
      hook()
      when defined(radioDiag):
        schedulerTiming.maxPollHookUs = max(
          schedulerTiming.maxPollHookUs, schedulerElapsedUs(hookStart))

proc runTimedPollHooks(now: uint64) =
  for i in 0 ..< schedulerTimedPollHookCount:
    if schedulerTimedPollHooks[i].hook != nil and
        schedulerTimedPollHooks[i].deadline != 0'u64 and
        schedulerTimedPollHooks[i].deadline <= now:
      when defined(radioDiag):
        let hookStart = readTick()
      schedulerTimedPollHooks[i].deadline =
        schedulerTimedPollHooks[i].hook(now)
      when defined(radioDiag):
        schedulerTiming.maxTimedHookUs = max(
          schedulerTiming.maxTimedHookUs, schedulerElapsedUs(hookStart))

proc hasUntimedPollHooks(): bool {.inline.} =
  if schedulerPollHook != nil:
    return true
  for hook in schedulerPollHooks:
    if hook != nil:
      return true
  false

proc hasDueTimedPollHooks(now: uint64): bool {.inline.} =
  for i in 0 ..< schedulerTimedPollHookCount:
    if schedulerTimedPollHooks[i].hook != nil and
        schedulerTimedPollHooks[i].deadline != 0'u64 and
        schedulerTimedPollHooks[i].deadline <= now:
      return true
  false

proc runSchedulerIteration(checkStack: static bool) =
  when defined(radioDiag):
    let iterationStart = readTick()
    iterationWifiUs = 0
    iterationReadyMaxUs = 0
    iterationTimerMaxUs = 0
    iterationReadyCount = 0
    if lastIterationEndTick != 0'u64:
      schedulerTiming.maxBetweenIterationsUs = max(
        schedulerTiming.maxBetweenIterationsUs,
        uint32(min(ticksToUs(iterationStart - lastIterationEndTick),
                   high(uint32).uint64)))
  scheduler.totalTicks += 1
  scheduler.priorityRan = false
  withInterruptsDisabled:
    scheduler.drainIsrPending()
  drainIsrCompletions()
  when defined(radioDiag):
    let firstTimersStart = readTick()
  scheduler.fireExpiredTimers()
  when defined(radioDiag):
    let firstTimersUs = schedulerElapsedUs(firstTimersStart)
    let readyStart = readTick()
  scheduler.runPriorityCallback(earlyOnly = true)
  scheduler.runReadyCallbacks()
  scheduler.runPriorityCallback(earlyOnly = false)
  when defined(radioDiag):
    let readyUs = schedulerElapsedUs(readyStart)
  runPollHooks()
  when defined(radioDiag):
    let timedStart = readTick()
  runTimedPollHooks(readTick())
  when defined(radioDiag):
    let timedUs = schedulerElapsedUs(timedStart)
  when checkStack:
    if not faultCheckStackGuard():
      faultHalt(FaultReasonStackGuard, 0'u, 0'u, 0'u)
  drainIsrCompletions()
  when defined(radioDiag):
    let lastTimersStart = readTick()
  scheduler.fireExpiredTimers()
  when defined(radioDiag):
    let lastTimersUs = schedulerElapsedUs(lastTimersStart)
    let elapsed = schedulerElapsedUs(iterationStart)
    schedulerTiming.maxIterationUs = max(schedulerTiming.maxIterationUs, elapsed)
    if elapsed > 15_000'u32:
      inc schedulerTiming.longIterations
      let slot = schedulerSlowCount mod schedulerSlowTurns.len.uint32
      schedulerSlowTurns[slot] = SchedulerSlowTurn(
        atMs: uint32(ticksToUs(iterationStart) div 1000),
        totalUs: elapsed, firstTimersUs: firstTimersUs, readyUs: readyUs,
        timedUs: timedUs, lastTimersUs: lastTimersUs,
        wifiUs: iterationWifiUs, readyMaxUs: iterationReadyMaxUs,
        timerMaxUs: iterationTimerMaxUs, readyCount: iterationReadyCount)
      inc schedulerSlowCount
    lastIterationEndTick = readTick()

proc pollScheduler*() =
  ## Run one ready batch and service timers without WFI or changing IRQ setup.
  ## Use with polling-only initialization when the host owns traps and stack.
  scheduler.running = true
  runSchedulerIteration(false)

proc runScheduler*() {.noreturn.} =
  ## Enter the scheduler main loop. Does not return.
  ##
  ## This replaces the `while true: wfi()` idle loop in main().
  ## All CPS tasks are driven by callbacks flowing through this loop.
  scheduler.running = true
  enableInterrupts()
  while true:
    when defined(radioDiag) or defined(radioCpuMeter):
      schedulerCpuNowTick = readTick()
    runSchedulerIteration(true)

    # Program next deadline and sleep. If a timer is pending, the
    # compare interrupt wakes WFI; spinning until the deadline wastes power
    # and starves lower-power validation of the real idle path.
    scheduler.reprogramNextDeadline()
    var shouldSleep = false
    withInterruptsDisabled:
      shouldSleep = scheduler.ready.len == 0 and scheduler.isrCount == 0 and
                    scheduler.priorityCallback == nil and
                    isrBridgePendingCompletions() == 0 and not timerIsrFired and
                    not hasUntimedPollHooks() and
                    not hasDueTimedPollHooks(readTick())
    if shouldSleep:
      withInterruptsDisabled:
        shouldSleep = scheduler.ready.len == 0 and scheduler.isrCount == 0 and
                      scheduler.priorityCallback == nil and
                      isrBridgePendingCompletions() == 0 and not timerIsrFired and
                      not hasUntimedPollHooks() and
                      not hasDueTimedPollHooks(readTick())
        # A pending, locally enabled interrupt wakes WFI with MIE clear.
        # Keep the final ready check and WFI together so the timer ISR
        # cannot clear the compare in between.
        if shouldSleep:
          when defined(bl808m0) and defined(radioProfiler):
            let profileIdle = beginProfileIdle()
          when defined(radioDiag) or defined(radioCpuMeter):
            let wfiStart = readTick()
          wfi()
          when defined(bl808m0) and defined(radioProfiler):
            endProfileIdle(profileIdle)
          when defined(radioDiag) or defined(radioCpuMeter):
            let wfiEnd = readTick()
            schedulerWfiTicks += wfiEnd - wfiStart
            schedulerCpuNowTick = wfiEnd
            inc schedulerWfiCalls

# =============================================================================
# Scheduler stats
# =============================================================================

type
  SchedulerStats* = object
    ticks*: uint64
    callbacksRun*: uint64
    timersFired*: uint64
    readyQueueLen*: int
    isrQueueLen*: int
    isrQueueOverflows*: uint64
    timerHeapLen*: int

proc schedulerStats*(): SchedulerStats =
  SchedulerStats(
    ticks: scheduler.totalTicks,
    callbacksRun: scheduler.totalCallbacks,
    timersFired: scheduler.totalTimersFired,
    readyQueueLen: scheduler.ready.len,
    isrQueueLen: scheduler.isrCount,
    isrQueueOverflows: scheduler.isrOverflow,
    timerHeapLen: scheduler.timers.len,
  )
