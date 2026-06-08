proc ipc_host_get_rawstatus*(env: pointer): uint32 {.importc, cdecl.}
proc ipc_host_irq*(env: pointer; status: uint32) {.importc, cdecl.}
proc ipc_host_enable_irq*(env: pointer; value: uint32) {.importc, cdecl.}
