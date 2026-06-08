proc bl_main_event_handle*(param: cint; txFcField: ptr KeTxFc) {.exportc, cdecl.} =
  if param == 0:
    bl_irq_bottomhalf(hwPtr())
  bl_tx_try_flush(param, txFcField)

proc bl_main_lowlevel_init*() {.exportc, cdecl.} =
  discard bl_irqs_init(hwPtr())

proc bl_main_tx_still_free*(): cint {.exportc, cdecl.} =
  ipc_host_txdesc_left(loadPtr(hwRaw(), BlHwIpcEnvOff), 0, 0)
