## Nim replacement for the small BL808 WiFi host IRQ bottom-half glue.

const
  IpcIrqE2aAll = 0x0000_07ff'u32
  BlHwIpcEnvOff = 0x30'u

var wifiIrqHw: pointer

proc ipc_host_get_rawstatus(env: pointer): uint32 {.importc, cdecl.}
proc ipc_host_irq(env: pointer; status: uint32) {.importc, cdecl.}
proc ipc_host_enable_irq(env: pointer; value: uint32) {.importc, cdecl.}

proc blHwIpcEnv(blHw: pointer): pointer {.inline.} =
  if blHw == nil:
    return nil
  cast[ptr pointer](cast[uint](blHw) + BlHwIpcEnvOff)[]

proc bl_irqs_init*(blHw: pointer): cint {.exportc, cdecl.} =
  wifiIrqHw = blHw
  0

proc bl_irqs_enable*(): cint {.exportc, cdecl.} =
  0

proc bl_irqs_disable*(): cint {.exportc, cdecl.} =
  0

proc bl_irq_bottomhalf*(blHw: pointer) {.exportc, cdecl.} =
  let ipcEnv = blHwIpcEnv(blHw)
  if ipcEnv == nil:
    return

  var status = ipc_host_get_rawstatus(ipcEnv)
  while true:
    while status != 0'u32:
      ipc_host_irq(ipcEnv, status)
      status = ipc_host_get_rawstatus(ipcEnv)

    ipc_host_enable_irq(ipcEnv, IpcIrqE2aAll)
    status = ipc_host_get_rawstatus(ipcEnv)
    if status == 0'u32:
      break
