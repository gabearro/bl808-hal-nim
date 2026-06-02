## Bare-metal CPS Runtime for BL808
##
## Provides the core types and execution machinery for continuation-passing
## style async programming on bare metal. This module is a minimal,
## OS-independent reimplementation of the CPS runtime interface that the
## transform macro expects.
##
## No imports of std/locks, std/os, std/atomics, std/sysatomics.
## All futures use the local-fast path (no atomic operations).

# =============================================================================
# Constants
# =============================================================================
const
  FutureStatePending* = 0
  FutureStateDone* = 1
  FutureStateCancelled* = 2

# =============================================================================
# Core types
# =============================================================================
type
  CancellationError* = object of CatchableError
    ## Raised when a future or task is cancelled.

  TimeoutError* = object of CatchableError
    ## Raised when a bounded wait expires before the operation completes.

  CpsContractError* = object of CatchableError
    ## Raised when CPS-generated code violates required control-flow contracts.

  ContinuationState* = enum
    csRunning    ## Currently executing
    csSuspended  ## Waiting for external event
    csFinished   ## Completed successfully
    csError      ## Completed with an error

  FuturePerfMode* = enum
    fpSharedSafe
    fpLocalFast

  # Stub runtime types for transform bindSym compatibility
  RuntimeFlavor* = enum
    rfCurrentThread
    rfMultiThread

  CpsRuntime* = ref object
    id*: int64
    flavor*: RuntimeFlavor

  RuntimeHandle* = object
    runtime*: CpsRuntime

  RuntimeGuard* = object
    prev*: CpsRuntime
    active*: bool

  Continuation* = ref object of RootObj
    ## Base type for all CPS continuations.
    fn*: proc(c: sink Continuation): Continuation {.nimcall.}
    state*: ContinuationState
    runtimeOwner*: CpsRuntime

  CpsFuture*[T] = ref object
    ## A future value produced by a CPS computation.
    value: T
    error: ref CatchableError
    state: int  # FutureStatePending, FutureStateDone, FutureStateCancelled
    inlineCb: proc() {.closure.}
    callbacks: seq[proc() {.closure.}]
    rootContinuation: pointer  # for cancellation support

  CpsVoidFuture* = ref object
    ## A future for void-returning CPS computations.
    error: ref CatchableError
    state: int
    inlineCb: proc() {.closure.}
    callbacks: seq[proc() {.closure.}]
    rootContinuation: pointer

# =============================================================================
# Runtime context stubs
# =============================================================================
var baremetalRuntime: CpsRuntime = nil

proc currentRuntime*(): RuntimeHandle =
  if baremetalRuntime == nil:
    baremetalRuntime = CpsRuntime(id: 1, flavor: rfCurrentThread)
  RuntimeHandle(runtime: baremetalRuntime)

proc setCurrentRuntime*(rt: CpsRuntime) =
  baremetalRuntime = rt

proc mainRuntime*(): RuntimeHandle = currentRuntime()

proc toHandle*(rt: CpsRuntime): RuntimeHandle =
  RuntimeHandle(runtime: rt)

proc isNil*(h: RuntimeHandle): bool {.inline.} =
  h.runtime.isNil

proc enter*(handle: RuntimeHandle): RuntimeGuard =
  result.prev = baremetalRuntime
  result.active = true
  baremetalRuntime = handle.runtime

proc leave*(guard: var RuntimeGuard) =
  if guard.active:
    guard.active = false
    baremetalRuntime = guard.prev

template withRuntime*(handle: RuntimeHandle, body: untyped): untyped =
  block:
    var guard = enter(handle)
    try:
      body
    finally:
      leave(guard)

# =============================================================================
# Future constructors (local — no atomics)
# =============================================================================
proc newLocalCpsFuture*[T](): CpsFuture[T] =
  CpsFuture[T](state: FutureStatePending)

proc newLocalCpsVoidFuture*(): CpsVoidFuture =
  CpsVoidFuture(state: FutureStatePending)

# Shared versions are aliases on bare metal (single-core per scheduler)
proc newCpsFuture*[T](): CpsFuture[T] =
  newLocalCpsFuture[T]()

proc newCpsVoidFuture*(): CpsVoidFuture =
  newLocalCpsVoidFuture()

# =============================================================================
# Pre-completed / pre-failed future constructors
# =============================================================================
proc completedLocalFuture*[T](val: T): CpsFuture[T] =
  result = CpsFuture[T](state: FutureStateDone)
  result.value = val

proc completedLocalVoidFuture*(): CpsVoidFuture =
  CpsVoidFuture(state: FutureStateDone)

proc completedFuture*[T](val: T): CpsFuture[T] =
  completedLocalFuture[T](val)

proc completedVoidFuture*(): CpsVoidFuture =
  completedLocalVoidFuture()

proc failedLocalFuture*[T](err: ref CatchableError): CpsFuture[T] =
  result = CpsFuture[T](state: FutureStateDone)
  result.error = err

proc failedLocalVoidFuture*(err: ref CatchableError): CpsVoidFuture =
  result = CpsVoidFuture(state: FutureStateDone)
  result.error = err

proc failedFuture*[T](err: ref CatchableError): CpsFuture[T] =
  failedLocalFuture[T](err)

proc failedVoidFuture*(err: ref CatchableError): CpsVoidFuture =
  failedLocalVoidFuture(err)

# =============================================================================
# Future state queries (ident-resolved at call site)
# =============================================================================
proc finished*[T](fut: CpsFuture[T]): bool {.inline.} =
  fut.state != FutureStatePending

proc finished*(fut: CpsVoidFuture): bool {.inline.} =
  fut.state != FutureStatePending

proc hasError*[T](fut: CpsFuture[T]): bool {.inline.} =
  fut.error != nil

proc hasError*(fut: CpsVoidFuture): bool {.inline.} =
  fut.error != nil

proc getError*[T](fut: CpsFuture[T]): ref CatchableError {.inline.} =
  fut.error

proc getError*(fut: CpsVoidFuture): ref CatchableError {.inline.} =
  fut.error

proc read*[T](fut: CpsFuture[T]): T =
  ## Read the value of a completed future. Raises if the future has an error.
  if fut.error != nil:
    raise fut.error
  fut.value

proc read*(fut: CpsVoidFuture) =
  ## Read a completed void future. Raises if the future has an error.
  if fut.error != nil:
    raise fut.error

proc isCancelled*[T](fut: CpsFuture[T]): bool {.inline.} =
  fut.state == FutureStateCancelled

proc isCancelled*(fut: CpsVoidFuture): bool {.inline.} =
  fut.state == FutureStateCancelled

# =============================================================================
# Callback registration (ident-resolved at call site)
# =============================================================================
proc addCallback*[T](fut: CpsFuture[T], cb: proc() {.closure.}) =
  ## Register a callback to fire when the future completes.
  ## If the future is already done, fires immediately.
  if fut.state != FutureStatePending:
    cb()
    return
  if fut.inlineCb == nil:
    fut.inlineCb = cb
  else:
    fut.callbacks.add(cb)

proc addCallback*(fut: CpsVoidFuture, cb: proc() {.closure.}) =
  if fut.state != FutureStatePending:
    cb()
    return
  if fut.inlineCb == nil:
    fut.inlineCb = cb
  else:
    fut.callbacks.add(cb)

# =============================================================================
# Fire callbacks (internal)
# =============================================================================
proc fireCallbacks[T](fut: CpsFuture[T]) =
  if fut.inlineCb != nil:
    var cb: proc() {.closure.}
    cb = fut.inlineCb
    fut.inlineCb = nil
    cb()
  if fut.callbacks.len > 0:
    # Fire in reverse order (LIFO, matching cps-impl behavior)
    var i = fut.callbacks.len - 1
    while i >= 0:
      fut.callbacks[i]()
      dec i
    fut.callbacks.setLen(0)

proc fireCallbacks(fut: CpsVoidFuture) =
  if fut.inlineCb != nil:
    var cb: proc() {.closure.}
    cb = fut.inlineCb
    fut.inlineCb = nil
    cb()
  if fut.callbacks.len > 0:
    var i = fut.callbacks.len - 1
    while i >= 0:
      fut.callbacks[i]()
      dec i
    fut.callbacks.setLen(0)

# =============================================================================
# Future completion (bindSym-resolved from transform)
# =============================================================================
proc complete*[T](fut: CpsFuture[T], val: T) =
  ## Complete a typed future with a value.
  if fut.state != FutureStatePending: return
  fut.value = val
  fut.state = FutureStateDone
  fut.rootContinuation = nil
  fireCallbacks(fut)

proc complete*(fut: CpsVoidFuture) =
  ## Complete a void future.
  if fut.state != FutureStatePending: return
  fut.state = FutureStateDone
  fut.rootContinuation = nil
  fireCallbacks(fut)

proc fail*[T](fut: CpsFuture[T], err: ref CatchableError) =
  ## Fail a typed future with an error.
  if fut.state != FutureStatePending: return
  fut.error = err
  fut.state = FutureStateDone
  fut.rootContinuation = nil
  fireCallbacks(fut)

proc fail*(fut: CpsVoidFuture, err: ref CatchableError) =
  ## Fail a void future with an error.
  if fut.state != FutureStatePending: return
  fut.error = err
  fut.state = FutureStateDone
  fut.rootContinuation = nil
  fireCallbacks(fut)

# =============================================================================
# Root continuation tracking (for cancellation support)
# =============================================================================
proc setFutureRootContinuation*[T](fut: CpsFuture[T], c: Continuation) =
  fut.rootContinuation = cast[pointer](c)

proc setFutureRootContinuation*(fut: CpsVoidFuture, c: Continuation) =
  fut.rootContinuation = cast[pointer](c)

# =============================================================================
# Cancellation
# =============================================================================
proc cancel*[T](fut: CpsFuture[T]) =
  if fut.state != FutureStatePending: return
  if fut.rootContinuation != nil:
    let c = cast[Continuation](fut.rootContinuation)
    c.fn = nil
    c.state = csError
  fut.error = newException(CancellationError, "Future cancelled")
  fut.state = FutureStateCancelled
  fut.rootContinuation = nil
  fireCallbacks(fut)

proc cancel*(fut: CpsVoidFuture) =
  if fut.state != FutureStatePending: return
  if fut.rootContinuation != nil:
    let c = cast[Continuation](fut.rootContinuation)
    c.fn = nil
    c.state = csError
  fut.error = newException(CancellationError, "Future cancelled")
  fut.state = FutureStateCancelled
  fut.rootContinuation = nil
  fireCallbacks(fut)

# =============================================================================
# Trampoline (bindSym-resolved from transform)
# =============================================================================
proc run*(c: sink Continuation): Continuation {.discardable.} =
  ## Run a continuation chain to completion or suspension.
  ## The trampoline loop drives continuations without stack growth.
  result = c
  while not result.isNil:
    let fn = result.fn
    if fn.isNil:
      break
    result = fn(result)

# =============================================================================
# Continuation helpers
# =============================================================================
proc pass*(c: Continuation): Continuation {.inline.} =
  ## Return the continuation as-is for the trampoline to continue.
  c

proc halt*(c: Continuation): Continuation {.inline.} =
  ## Mark the continuation as finished and stop execution.
  c.fn = nil
  c.state = csFinished
  c

proc suspend*(c: Continuation): Continuation {.inline.} =
  ## Suspend the continuation (external event will resume it).
  c.fn = nil
  c.state = csSuspended
  c

# =============================================================================
# runCps — run a CPS future to completion (blocking)
# =============================================================================
proc runCps*[T](fut: CpsFuture[T]): T =
  ## Drive the event loop until the future completes (bare-metal: busy-wait).
  ## In practice, the scheduler should be used instead.
  while not fut.finished:
    discard  # bare-metal: should not be used; use scheduler
  fut.read()

proc runCps*(fut: CpsVoidFuture) =
  while not fut.finished:
    discard

# =============================================================================
# Combinators (minimal set for bare metal)
# =============================================================================
proc waitAll*(a, b: CpsVoidFuture): CpsVoidFuture =
  ## Returns a future that completes when both a and b complete.
  let combined = newLocalCpsVoidFuture()
  var remaining = 2
  let check = proc() =
    if combined.finished:
      return
    if a.hasError:
      fail(combined, a.getError)
      return
    if b.hasError:
      fail(combined, b.getError)
      return
    dec remaining
    if remaining == 0:
      complete(combined)
  addCallback(a, check)
  addCallback(b, check)
  combined
