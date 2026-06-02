## Per-core cooperative scheduler for the BL808 kernel.
##
## Drives CPS green threads via a simple run loop:
##   1. Drain ISR-posted callbacks
##   2. Fire expired timers (tickless — only programs next deadline)
##   3. Run all ready callbacks (CPS continuation steps)
##   4. WFI until next event
##
## There is one global `scheduler` instance per core.
## All public API is safe to call from task context.
## `postFromIsr` is the only proc safe to call from interrupt context.

import ../core, ../irq
import ./clock
import ./fault
import ./isrbridge

const
  MaxIsrPendingCallbacks* = 32
    ## Fixed ISR callback queue depth. postFromIsr drops callbacks after this
    ## limit and records an overflow count instead of allocating in interrupt
    ## context.
  MaxSchedulerTimers* = 32
    ## Bounded timer heap backing store. Timer entries carry closures, so the
    ## heap stores stable pointers to these slots instead of copying entries.
  MaxSchedulerTimedPollHooks* = 8
    ## Bounded count of scheduler-owned timed poll hooks.

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
  Scheduler* = object
    ready: seq[proc() {.closure.}]
      ## Callbacks ready to run this iteration.
    isrPending: array[MaxIsrPendingCallbacks, proc() {.closure.}]
      ## Fixed queue of callbacks posted from ISR context.
    isrHead, isrTail, isrCount: int
    isrOverflow: uint64
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
      entry.callback = nil
      entry.deadline = 0
      entry.id = 0
      entry.cancelled = false
      timerPoolUsed[i] = false
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

proc heapPop(s: var Scheduler): TimerEntry =
  result = s.timers[0]
  let last = s.timers.len - 1
  s.timers[0] = s.timers[last]
  s.timers.setLen(last)
  if s.timers.len == 0: return
  # Sift down
  var i = 0
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

proc schedulerInit*() =
  ## Initialize the scheduler. Call once at boot after heapInit().
  scheduler.ready = @[]
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

  # Register the machine timer ISR and enable it
  registerTrapHandler(MachineTimerIrq, timerIsrHandler)
  enableTimerIrq()

# =============================================================================
# Posting callbacks
# =============================================================================

proc post*(cb: proc() {.closure.}) =
  ## Schedule a callback to run on the next scheduler iteration.
  ## Safe to call from task context only.
  scheduler.ready.add(cb)

proc postFromIsr*(cb: proc() {.closure.}) =
  ## Schedule a callback from ISR context.
  ## The callback will be drained into the ready queue on the next iteration.
  ## Interrupts must already be disabled when calling this.
  if scheduler.isrCount >= MaxIsrPendingCallbacks:
    scheduler.isrOverflow.inc
    return
  scheduler.isrPending[scheduler.isrHead] = cb
  scheduler.isrHead = (scheduler.isrHead + 1) mod MaxIsrPendingCallbacks
  scheduler.isrCount.inc

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

proc cancelTimer*(id: TimerId) =
  ## Cancel a pending timer. The callback will not fire.
  ## O(n) scan — acceptable for typical timer counts.
  for i in 0 ..< scheduler.timers.len:
    if scheduler.timers[i].id == id:
      scheduler.timers[i].cancelled = true
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
    let entry = s.heapPop()
    if not entry.cancelled:
      entry.callback()
      s.totalTimersFired += 1
    releaseTimerEntry(entry)
    now = readTick()
    if interruptDeadline > now:
      now = interruptDeadline

proc runReadyCallbacks(s: var Scheduler) =
  ## Run all callbacks currently in the ready queue.
  ## Callbacks may enqueue more callbacks (via CPS continuation chains),
  ## so we iterate until the queue is empty.
  while s.ready.len > 0:
    # Snapshot and clear — callbacks may add to ready during execution
    let batch = move s.ready
    s.ready = @[]
    for i in 0 ..< batch.len:
      batch[i]()
      s.totalCallbacks += 1
    # Drain any ISR callbacks that arrived while running
    withInterruptsDisabled:
      s.drainIsrPending()

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
    schedulerPollHook()
  for hook in schedulerPollHooks:
    if hook != nil:
      hook()

proc runTimedPollHooks(now: uint64) =
  for i in 0 ..< schedulerTimedPollHookCount:
    if schedulerTimedPollHooks[i].hook != nil and
        schedulerTimedPollHooks[i].deadline != 0'u64 and
        schedulerTimedPollHooks[i].deadline <= now:
      schedulerTimedPollHooks[i].deadline =
        schedulerTimedPollHooks[i].hook(now)

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

proc runScheduler*() {.noreturn.} =
  ## Enter the scheduler main loop. Does not return.
  ##
  ## This replaces the `while true: wfi()` idle loop in main().
  ## All CPS tasks are driven by callbacks flowing through this loop.
  scheduler.running = true
  enableInterrupts()
  while true:
    scheduler.totalTicks += 1

    # 1. Drain ISR-posted callbacks + ISR completion ring
    withInterruptsDisabled:
      scheduler.drainIsrPending()
    drainIsrCompletions()

    # 2. Fire expired timers → these complete futures → enqueue CPS callbacks
    scheduler.fireExpiredTimers()

    # 3. Run all ready callbacks
    scheduler.runReadyCallbacks()

    # 4. Run poll hooks (IPC, watchdog, networking, etc.)
    runPollHooks()
    runTimedPollHooks(readTick())
    if not faultCheckStackGuard():
      faultHalt(FaultReasonStackGuard, 0'u, 0'u, 0'u)

    # 5. Re-check timers and ISR completions (callbacks may have added new ones)
    drainIsrCompletions()
    scheduler.fireExpiredTimers()

    # 6. Program next deadline and sleep. If a timer is pending, the
    # compare interrupt wakes WFI; spinning until the deadline wastes power
    # and starves lower-power validation of the real idle path.
    scheduler.reprogramNextDeadline()
    var shouldSleep = false
    withInterruptsDisabled:
      shouldSleep = scheduler.ready.len == 0 and scheduler.isrCount == 0 and
                    isrBridgePendingCompletions() == 0 and not timerIsrFired and
                    not hasUntimedPollHooks() and
                    not hasDueTimedPollHooks(readTick())
    if shouldSleep:
      withInterruptsDisabled:
        shouldSleep = scheduler.ready.len == 0 and scheduler.isrCount == 0 and
                      isrBridgePendingCompletions() == 0 and not timerIsrFired and
                      not hasUntimedPollHooks() and
                      not hasDueTimedPollHooks(readTick())
      if shouldSleep:
        wfi()

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
