## CPS integration for the cooperative WASM scheduler.
##
## OS tasks should use this module so every VM slice returns to the HAL CPS
## scheduler. That prevents long-running WASM programs from starving timers,
## ISR completions, networking, SD, UART, or other kernel CPS tasks.

import ./kernel/cps
import ./wasm_control

export wasm_control

when not (defined(bl808d0) or defined(bl808lp)):
  # The reaper poll hooks are registered against the kernel CPS scheduler.
  # They run wherever the scheduler loop runs; for the all-core HTTP image that
  # is M0, which owns the multi-task table. D0/LP drive single WASM tasks via
  # runWasmTaskCps and are bounded by its maxSlices cap instead.
  import ./kernel/sched
  import ./kernel/clock

const
  WasmCpsDefaultSliceFuel* {.intdefine.} = 16'u32
  WasmCpsDefaultMaxSlices* {.intdefine.} = 512'u32
  WasmCpsReapPeriodMs* {.intdefine.} = 100'u64
    ## Wall-clock period between scheduler reaper passes (trap-slot reclamation
    ## + soft no-forward-progress watchdog).

when not (defined(bl808d0) or defined(bl808lp)):
  var wasmReapersInstalled = false
    ## MUST be zero-initialized (no {.noinit.}): a garbage non-zero value would
    ## either skip reaper registration entirely or leave the install in a
    ## half-state. Plain bool init to false is correct and deterministic.

  proc wasmReaperPoll(now: uint64): uint64 =
    ## Top-level reaper hook. Kept as a named proc (not an inline closure) so it
    ## carries no captured environment — the scheduler invokes it via a closure
    ## proc type, and a nil/garbage env pointer would fault on a near-nil store.
    discard reapTrappedSlots()
    discard reapStuckTasks()
    deadlineFromNowMs(WasmCpsReapPeriodMs)

  proc ensureWasmReapersInstalled() =
    ## Register the trap-slot reaper and the soft watchdog once, lazily, on the
    ## first CPS WASM drive. The hard hardware-watchdog backstop is deliberately
    ## NOT armed here: with resetOnTimeout=true (its default) a WDT trip resets
    ## the whole core, contradicting "a watchdog trip can never crash the core".
    ## It stays deferred until a proven margin over worst-case single-resume.
    ##
    ## Build with -d:bl808WasmNoReaper to skip registration entirely (isolation
    ## lever for diagnosing scheduler poll-hook interactions; the trapped-slot
    ## leak fix still works via direct stopWasmTask/kill paths, only the periodic
    ## reclamation + soft watchdog are disabled).
    when not defined(bl808WasmNoReaper):
      if wasmReapersInstalled:
        return
      wasmReapersInstalled = true
      discard addSchedulerTimedPollHook(wasmReaperPoll,
                                        deadlineFromNowMs(WasmCpsReapPeriodMs))

proc wasmTaskTerminal(state: WasmSchedulerTaskState): bool {.inline.} =
  state in {wasmTaskExited, wasmTaskTrapped, wasmTaskKilled}

proc runWasmTaskCps*(taskId: uint32,
                     sliceFuel = WasmCpsDefaultSliceFuel,
                     maxSlices = WasmCpsDefaultMaxSlices): CpsFuture[WasmControlTaskResult] {.cps.} =
  ## Drive one existing WASM task from the HAL CPS scheduler.
  ##
  ## Each iteration runs at most `sliceFuel` VM instructions, then awaits
  ## `yieldNow()`. The VM therefore advances as a CPS task instead of a private
  ## busy loop.
  when not (defined(bl808d0) or defined(bl808lp)):
    ensureWasmReapersInstalled()
  var last = getWasmProgramTask(taskId)
  var slices = 0'u32
  while last.status == wasmControlOk and not wasmTaskTerminal(last.taskState) and
      slices < maxSlices:
    last = resumeWasmProgramTask(taskId, sliceFuel)
    inc slices
    if last.status == wasmControlOk and not wasmTaskTerminal(last.taskState):
      await yieldNow()
  if slices >= maxSlices and last.status == wasmControlOk and
      not wasmTaskTerminal(last.taskState):
    discard killWasmProgramTask(taskId)
    last = getWasmProgramTask(taskId)
    if last.status == wasmControlOk:
      last.status = wasmControlRunError
      last.schedulerStatus = wasmSchedQuotaExceeded
  return last

proc startAndRunWasmProgramTaskCps*(slot: uint32,
                                    exportName: string,
                                    args: openArray[int32],
                                    sliceFuel = WasmCpsDefaultSliceFuel,
                                    maxSlices = WasmCpsDefaultMaxSlices,
                                    maxTotalFuel = WasmSchedulerDefaultMaxTotalFuel):
    CpsFuture[WasmControlTaskResult] {.cps.} =
  ## Start a task and drive it cooperatively through the HAL CPS scheduler.
  let started = startWasmProgramTaskI32(
    slot,
    exportName,
    args,
    maxTotalFuel = maxTotalFuel,
  )
  if started.status != wasmControlOk:
    return started
  return await runWasmTaskCps(started.taskId, sliceFuel, maxSlices)
