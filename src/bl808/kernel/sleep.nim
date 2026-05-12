## CPS-compatible sleep primitives for the BL808 kernel.
##
## Usage in a `{.cps.}` proc:
##   await sleepMs(500)   # suspend for 500 milliseconds
##   await sleepUs(100)   # suspend for 100 microseconds
##   await sleepTicks(n)  # suspend for n raw timer ticks
##
## Each proc returns a `CpsVoidFuture` that completes when the
## deadline expires. The scheduler's timer heap drives the wakeup.

import ./runtime
import ./clock
import ./sched

# =============================================================================
# Core sleep — deadline-based
# =============================================================================

proc sleepUntil*(deadline: uint64): CpsVoidFuture =
  ## Return a future that completes at the given absolute tick deadline.
  let f = newLocalCpsVoidFuture()
  let timerId = addTimer(deadline, proc() = complete(f))
  addCallback(f, proc() =
    if f.isCancelled:
      cancelTimer(timerId)
  )
  f

proc sleepTicks*(ticks: uint64): CpsVoidFuture =
  ## Return a future that completes after `ticks` timer ticks from now.
  sleepUntil(readTick() + ticks)

# =============================================================================
# Millisecond / microsecond sleep
# =============================================================================

proc sleepMs*(ms: uint64): CpsVoidFuture =
  ## Return a future that completes after `ms` milliseconds.
  sleepTicks(msToTicks(ms))

proc sleepUs*(us: uint64): CpsVoidFuture =
  ## Return a future that completes after `us` microseconds.
  sleepTicks(usToTicks(us))

# =============================================================================
# Yield — reschedule without delay
# =============================================================================

proc yieldNow*(): CpsVoidFuture =
  ## Return a future that completes on the next scheduler iteration.
  ## Use this to cooperatively yield to other tasks.
  let f = newLocalCpsVoidFuture()
  post(proc() = complete(f))
  f

# =============================================================================
# Timeout wrappers
# =============================================================================

proc withTimeout*[T](inner: CpsFuture[T], timeoutMs: uint64,
                     message: string = "operation timed out"): CpsFuture[T] =
  ## Return a future that mirrors `inner`, but fails with TimeoutError if it
  ## does not finish before `timeoutMs`. A timeout cancels the inner future so
  ## driver-side cleanup callbacks can release any pending state.
  if timeoutMs == 0 or inner.finished:
    return inner

  let outer = newLocalCpsFuture[T]()
  let timerId = addTimerMs(timeoutMs, proc() =
    if not outer.finished:
      fail(outer, newException(TimeoutError, message))
      if not inner.finished:
        cancel(inner)
  )

  inner.addCallback(proc() =
    if outer.finished:
      return
    cancelTimer(timerId)
    if inner.hasError:
      fail(outer, inner.getError)
    else:
      complete(outer, inner.read())
  )

  outer.addCallback(proc() =
    if outer.isCancelled:
      cancelTimer(timerId)
      if not inner.finished:
        cancel(inner)
  )

  outer

proc withTimeout*(inner: CpsVoidFuture, timeoutMs: uint64,
                  message: string = "operation timed out"): CpsVoidFuture =
  ## Void future variant of withTimeout.
  if timeoutMs == 0 or inner.finished:
    return inner

  let outer = newLocalCpsVoidFuture()
  let timerId = addTimerMs(timeoutMs, proc() =
    if not outer.finished:
      fail(outer, newException(TimeoutError, message))
      if not inner.finished:
        cancel(inner)
  )

  inner.addCallback(proc() =
    if outer.finished:
      return
    cancelTimer(timerId)
    if inner.hasError:
      fail(outer, inner.getError)
    else:
      complete(outer)
  )

  outer.addCallback(proc() =
    if outer.isCancelled:
      cancelTimer(timerId)
      if not inner.finished:
        cancel(inner)
  )

  outer
