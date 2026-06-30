## Flash-backed WASM scheduler smoke helpers.

import ./wasm_control
import ./wasm_store
import ./wasm_task_smoke

const
  WasmSchedulerSmokeOk* = 0x57535300'u32
  WasmSchedulerSmokeInstallFailed* = 0x57535301'u32
  WasmSchedulerSmokeStartFailed* = 0x57535302'u32
  WasmSchedulerSmokeTimeout* = 0x57535303'u32
  WasmSchedulerSmokeResultMismatch* = 0x57535304'u32
  WasmSchedulerSmokeNoYield* = 0x57535305'u32
  WasmSchedulerSmokeKillFailed* = 0x57535306'u32
  WasmSchedulerSmokeQuotaFailed* = 0x57535307'u32
  WasmSchedulerSmokeBlockFailed* = 0x57535308'u32

proc runWasmSchedulerSmoke*(slot: uint32): uint32 =
  resetWasmScheduler()
  discard unloadWasmProgram(slot)
  let install = installWasmProgramBytes(
    slot,
    SumModule,
    generation = 3'u32,
    flags = 0'u32,
  )
  if install.status != wasmControlOk:
    return WasmSchedulerSmokeInstallFailed

  let a = startWasmProgramTaskI32(slot, "sum", [10'i32])
  let b = startWasmProgramTaskI32(slot, "sum", [12'i32])
  if a.status != wasmControlOk or b.status != wasmControlOk or a.taskId == b.taskId:
    return WasmSchedulerSmokeStartFailed

  var aInfo: WasmControlTaskResult
  var bInfo: WasmControlTaskResult
  for _ in 0 ..< 256:
    discard runWasmProgramScheduler(3'u32, 2'u32)
    aInfo = getWasmProgramTask(a.taskId)
    bInfo = getWasmProgramTask(b.taskId)
    if aInfo.status != wasmControlOk or bInfo.status != wasmControlOk:
      return WasmSchedulerSmokeStartFailed
    if aInfo.taskState == wasmTaskExited and bInfo.taskState == wasmTaskExited:
      if aInfo.value != 45'i32 or bInfo.value != 66'i32:
        return WasmSchedulerSmokeResultMismatch
      if aInfo.yields < TaskSwitchMin or bInfo.yields < TaskSwitchMin:
        return WasmSchedulerSmokeNoYield
      let killed = killWasmProgramTask(a.taskId)
      if killed.status != wasmControlOk:
        return WasmSchedulerSmokeKillFailed
      discard killWasmProgramTask(b.taskId)

      let quota = startWasmProgramTaskI32(slot, "sum", [100'i32], maxTotalFuel = 4'u32)
      if quota.status != wasmControlOk:
        return WasmSchedulerSmokeQuotaFailed
      discard resumeWasmProgramTask(quota.taskId, 3'u32)
      let quotaExceeded = resumeWasmProgramTask(quota.taskId, 3'u32)
      if quotaExceeded.status != wasmControlRunError or
          quotaExceeded.schedulerStatus != wasmSchedQuotaExceeded or
          quotaExceeded.taskState != wasmTaskTrapped:
        return WasmSchedulerSmokeQuotaFailed
      discard killWasmProgramTask(quota.taskId)

      let blocked = startWasmProgramTaskI32(slot, "sum", [4'i32])
      if blocked.status != wasmControlOk:
        return WasmSchedulerSmokeBlockFailed
      let blockResult = blockWasmTask(blocked.taskId, wasmTaskBlockedSd)
      if blockResult.status != wasmSchedOk or blockResult.state != wasmTaskBlockedSd:
        return WasmSchedulerSmokeBlockFailed
      let blockedResume = resumeWasmProgramTask(blocked.taskId, 3'u32)
      if blockedResume.status == wasmControlOk:
        return WasmSchedulerSmokeBlockFailed
      let unblockResult = unblockWasmTask(blocked.taskId)
      if unblockResult.status != wasmSchedOk or unblockResult.state != wasmTaskYielded:
        return WasmSchedulerSmokeBlockFailed
      discard killWasmProgramTask(blocked.taskId)

      discard unloadWasmProgram(slot)
      return WasmSchedulerSmokeOk

  WasmSchedulerSmokeTimeout
