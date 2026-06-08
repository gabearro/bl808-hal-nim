import
  host_interfaces,
  layout

var wifiIrqHw: pointer

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
