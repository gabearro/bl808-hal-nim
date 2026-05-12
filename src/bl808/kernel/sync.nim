## Async synchronization primitives for the BL808 kernel.
##
## All primitives are cooperative — no locks, no atomics.
## Safe only within a single-core scheduler context.
##
##   let sem = newAsyncSemaphore(3)
##   await sem.acquire()   # blocks if no permits
##   sem.release()
##
##   let mtx = newAsyncMutex()
##   await mtx.lock()
##   # critical section
##   mtx.unlock()
##
##   let evt = newAsyncEvent()
##   await evt.wait()      # blocks until set
##   evt.set()             # wakes all waiters

import ./runtime

# =============================================================================
# AsyncSemaphore
# =============================================================================

type
  AsyncSemaphore* = ref object
    permits: int
    maxPermits: int
    waiters: seq[CpsVoidFuture]
    closed: bool

proc newAsyncSemaphore*(permits: int, maxPermits: int = high(int)): AsyncSemaphore =
  ## Create a counting semaphore with `permits` initial permits.
  ## `maxPermits` bounds over-release when a bounded semaphore is desired.
  assert permits >= 0, "semaphore permits must be non-negative"
  assert maxPermits >= permits, "semaphore maxPermits must cover initial permits"
  AsyncSemaphore(
    permits: permits,
    maxPermits: maxPermits,
    waiters: @[],
    closed: false,
  )

proc acquire*(sem: AsyncSemaphore): CpsVoidFuture =
  ## Acquire a permit. Returns a pre-completed future if a permit is
  ## available immediately; otherwise the returned future blocks until
  ## a permit is released.
  if sem.closed:
    return failedLocalVoidFuture(
      newException(IOError, "semaphore closed"))
  if sem.permits > 0:
    dec sem.permits
    return completedLocalVoidFuture()
  let f = newLocalCpsVoidFuture()
  sem.waiters.add(f)
  f

proc release*(sem: AsyncSemaphore) =
  ## Release a permit. Wakes the oldest waiter if any are blocked;
  ## otherwise increments the permit count.
  if sem.closed:
    return
  # Skip cancelled/completed waiters
  while sem.waiters.len > 0:
    let w = sem.waiters[0]
    sem.waiters.delete(0)
    if not w.finished:
      complete(w)
      return
  if sem.permits < sem.maxPermits:
    inc sem.permits

proc tryAcquire*(sem: AsyncSemaphore): bool =
  ## Non-blocking acquire. Returns true if a permit was obtained.
  if sem.closed:
    return false
  if sem.permits > 0:
    dec sem.permits
    true
  else:
    false

proc availablePermits*(sem: AsyncSemaphore): int {.inline.} =
  sem.permits

proc waitersCount*(sem: AsyncSemaphore): int {.inline.} =
  sem.waiters.len

proc close*(sem: AsyncSemaphore) =
  ## Close the semaphore. All pending and future acquires fail.
  sem.closed = true
  for w in sem.waiters:
    if not w.finished:
      fail(w, newException(IOError, "semaphore closed"))
  sem.waiters.setLen(0)

# =============================================================================
# AsyncMutex
# =============================================================================

type
  AsyncMutex* = ref object
    locked: bool
    waiters: seq[CpsVoidFuture]

proc newAsyncMutex*(): AsyncMutex =
  AsyncMutex(locked: false, waiters: @[])

proc lock*(mtx: AsyncMutex): CpsVoidFuture =
  ## Acquire the mutex. If already locked, the returned future blocks
  ## until the current holder calls unlock().
  if not mtx.locked:
    mtx.locked = true
    return completedLocalVoidFuture()
  let f = newLocalCpsVoidFuture()
  mtx.waiters.add(f)
  f

proc unlock*(mtx: AsyncMutex) =
  ## Release the mutex. Wakes the next waiter if any.
  while mtx.waiters.len > 0:
    let w = mtx.waiters[0]
    mtx.waiters.delete(0)
    if not w.finished:
      complete(w)
      return
  mtx.locked = false

proc tryLock*(mtx: AsyncMutex): bool =
  ## Non-blocking lock attempt.
  if not mtx.locked:
    mtx.locked = true
    true
  else:
    false

proc isLocked*(mtx: AsyncMutex): bool {.inline.} = mtx.locked

template withLock*(mtx: AsyncMutex, body: untyped) =
  ## Convenience template for `{.cps.}` procs. Cannot be used directly
  ## since it contains `await`. Use the explicit lock/unlock pattern in
  ## CPS procs instead.
  ##
  ## For non-CPS code, use tryLock + unlock.
  block:
    body

# =============================================================================
# AsyncEvent
# =============================================================================

type
  AsyncEvent* = ref object
    flag: bool
    waiters: seq[CpsVoidFuture]

proc newAsyncEvent*(): AsyncEvent =
  AsyncEvent(flag: false, waiters: @[])

proc wait*(evt: AsyncEvent): CpsVoidFuture =
  ## Wait for the event to be set. If already set, returns immediately.
  if evt.flag:
    return completedLocalVoidFuture()
  let f = newLocalCpsVoidFuture()
  evt.waiters.add(f)
  f

proc set*(evt: AsyncEvent) =
  ## Set the event, waking all waiters.
  evt.flag = true
  for w in evt.waiters:
    if not w.finished:
      complete(w)
  evt.waiters.setLen(0)

proc clear*(evt: AsyncEvent) =
  ## Clear the event. Future wait() calls will block.
  evt.flag = false

proc isSet*(evt: AsyncEvent): bool {.inline.} = evt.flag

proc waitersCount*(evt: AsyncEvent): int {.inline.} =
  evt.waiters.len

# =============================================================================
# AsyncBarrier
# =============================================================================

type
  AsyncBarrier* = ref object
    threshold: int
    count: int
    waiters: seq[CpsVoidFuture]

proc newAsyncBarrier*(parties: int): AsyncBarrier =
  ## Create a barrier that releases when `parties` tasks arrive.
  AsyncBarrier(threshold: parties, count: 0, waiters: @[])

proc arrive*(barrier: AsyncBarrier): CpsVoidFuture =
  ## Signal arrival at the barrier. When the last party arrives,
  ## all waiters are released.
  inc barrier.count
  if barrier.count >= barrier.threshold:
    # Release all
    for w in barrier.waiters:
      if not w.finished:
        complete(w)
    barrier.waiters.setLen(0)
    barrier.count = 0
    return completedLocalVoidFuture()
  let f = newLocalCpsVoidFuture()
  barrier.waiters.add(f)
  f
