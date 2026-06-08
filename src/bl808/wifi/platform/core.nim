import
  ../../mmio,
  host_interfaces,
  layout

var ipc_shenv* {.exportc.}: pointer

proc blHwIpcEnv(blHw: pointer): pointer {.inline.} =
  cast[ptr pointer](cast[uint](blHw) + BlHwIpcEnvOff)[]

proc bl_platform_on*(blHw: pointer): cint {.exportc, cdecl.} =
  ipc_shenv = cast[pointer](addr ipc_shared_env)
  result = bl_ipc_init(blHw, ipc_shenv)
  if result != 0:
    return result
  regWrite(IpcEmb2AppAck, 0xffff_ffff'u32)

proc bl_platform_off*(blHw: pointer) {.exportc, cdecl.} =
  if blHw == nil:
    return
  let ipcEnv = blHwIpcEnv(blHw)
  ipc_host_disable_irq(ipcEnv, IpcIrqE2aAll)
