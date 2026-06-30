## CPS integration for the cooperative WASM scheduler.
##
## OS tasks should use this module so every VM slice returns to the HAL CPS
## scheduler. That prevents long-running WASM programs from starving timers,
## ISR completions, networking, SD, UART, or other kernel CPS tasks.

import ./kernel/cps
import ./wasm_control

export wasm_control

const
  WasmCpsDefaultSliceFuel* {.intdefine.} = 16'u32
  WasmCpsDefaultMaxSlices* {.intdefine.} = 512'u32

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
