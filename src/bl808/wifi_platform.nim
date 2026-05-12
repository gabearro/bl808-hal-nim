## Nim replacement for the small BL808 WiFi platform-on/off glue.

import mmio

const
  IpcEmb2AppAck = 0x2480_0008'u
  IpcIrqE2aAll = 0x0000_07ff'u32
  BlHwIpcEnvOff = 0x30'u

var ipc_shared_env {.importc.}: uint8
var ipc_shenv* {.exportc.}: pointer

proc bl_ipc_init(blHw, ipcSharedMem: pointer): cint {.importc, cdecl.}
proc ipc_host_disable_irq(env: pointer; value: uint32) {.importc, cdecl.}

proc bl_platform_on*(blHw: pointer): cint {.exportc, cdecl.} =
  ipc_shenv = cast[pointer](addr ipc_shared_env)
  result = bl_ipc_init(blHw, ipc_shenv)
  if result != 0:
    return result
  regWrite(IpcEmb2AppAck, 0xffff_ffff'u32)

proc bl_platform_off*(blHw: pointer) {.exportc, cdecl.} =
  if blHw == nil:
    return
  let ipcEnv = cast[ptr pointer](cast[uint](blHw) + BlHwIpcEnvOff)[]
  ipc_host_disable_irq(ipcEnv, IpcIrqE2aAll)
