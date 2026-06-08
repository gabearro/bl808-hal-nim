var ipc_shared_env* {.importc.}: uint8

proc bl_ipc_init*(blHw, ipcSharedMem: pointer): cint {.importc, cdecl.}
proc ipc_host_disable_irq*(env: pointer; value: uint32) {.importc, cdecl.}
