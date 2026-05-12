## Structured task management for the BL808 kernel.
##
## Tasks wrap CPS futures with names and cancellation:
##
##   let t = spawn computeValue(42), "compute"
##   let result: int = await t       # await the task's future
##   echo t.name                     # "compute"
##
##   let vt = spawn backgroundWork(), "bg"
##   vt.cancel()                     # cancel the task
##
## `spawn` is syntactic sugar — it starts the CPS proc (which runs
## through the trampoline to its first await) and returns a Task handle.

import ./runtime

# =============================================================================
# Task types
# =============================================================================

type
  Task*[T] = ref object
    ## A named handle to a running CPS computation.
    future*: CpsFuture[T]
    name*: string

  VoidTask* = ref object
    ## A named handle to a void CPS computation.
    future*: CpsVoidFuture
    name*: string

# =============================================================================
# Task constructors
# =============================================================================

proc spawn*[T](fut: CpsFuture[T], name: string = ""): Task[T] =
  ## Create a named task from a CPS future.
  ## The CPS proc has already started running (to its first await).
  Task[T](future: fut, name: name)

proc spawn*(fut: CpsVoidFuture, name: string = ""): VoidTask =
  VoidTask(future: fut, name: name)

# =============================================================================
# Make Task[T] awaitable — provide the ident-resolved CPS interface
# =============================================================================

proc finished*[T](t: Task[T]): bool {.inline.} =
  t.future.finished

proc finished*(t: VoidTask): bool {.inline.} =
  t.future.finished

proc read*[T](t: Task[T]): T {.inline.} =
  t.future.read()

proc hasError*[T](t: Task[T]): bool {.inline.} =
  t.future.hasError()

proc hasError*(t: VoidTask): bool {.inline.} =
  t.future.hasError()

proc getError*[T](t: Task[T]): ref CatchableError {.inline.} =
  t.future.getError()

proc getError*(t: VoidTask): ref CatchableError {.inline.} =
  t.future.getError()

proc addCallback*[T](t: Task[T], cb: proc() {.closure.}) {.inline.} =
  t.future.addCallback(cb)

proc addCallback*(t: VoidTask, cb: proc() {.closure.}) {.inline.} =
  t.future.addCallback(cb)

# =============================================================================
# Task control
# =============================================================================

proc cancel*[T](t: Task[T]) =
  ## Cancel the task's underlying future.
  cancel(t.future)

proc cancel*(t: VoidTask) =
  cancel(t.future)

proc isCancelled*[T](t: Task[T]): bool {.inline.} =
  t.future.isCancelled

proc isCancelled*(t: VoidTask): bool {.inline.} =
  t.future.isCancelled

# =============================================================================
# Task group — structured concurrency
# =============================================================================

type
  TaskGroup* = ref object
    ## A group of void tasks. `awaitAll` blocks until every task completes.
    tasks: seq[VoidTask]
    name: string

proc newTaskGroup*(name: string = ""): TaskGroup =
  TaskGroup(tasks: @[], name: name)

proc add*(tg: TaskGroup, t: VoidTask) =
  tg.tasks.add(t)

proc add*(tg: TaskGroup, fut: CpsVoidFuture, name: string = "") =
  tg.tasks.add(spawn(fut, name))

proc len*(tg: TaskGroup): int {.inline.} = tg.tasks.len

proc awaitAll*(tg: TaskGroup): CpsVoidFuture =
  ## Return a future that completes when all tasks in the group finish.
  if tg.tasks.len == 0:
    return completedLocalVoidFuture()

  let combined = newLocalCpsVoidFuture()
  var remaining = tg.tasks.len

  for t in tg.tasks:
    let fut = t.future
    addCallback(fut, proc() =
      if combined.finished:
        return
      if fut.hasError:
        fail(combined, fut.getError)
        return
      dec remaining
      if remaining == 0:
        complete(combined)
    )

  combined

proc cancelAll*(tg: TaskGroup) =
  for t in tg.tasks:
    cancel(t)
