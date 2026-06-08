proc bl808_wifi_backend_scan_count*(): uint32 {.exportc, cdecl.} =
  scanItemCount

proc bl808_wifi_backend_scan_done_count*(): uint32 {.exportc, cdecl.} =
  scanDoneCount

proc bl808_wifi_backend_mac_irq_count*(): uint32 {.exportc, cdecl.} =
  macIrqCount

proc bl808_wifi_backend_mac_poll_irq_count*(): uint32 {.exportc, cdecl.} =
  macPollIrqCount

proc bl808_wifi_backend_mac_trap_irq_count*(): uint32 {.exportc, cdecl.} =
  macTrapIrqCount

proc bl808_wifi_backend_ipc_trap_irq_count*(): uint32 {.exportc, cdecl.} =
  ipcTrapIrqCount

proc bl808_wifi_backend_ipc_poll_irq_count*(): uint32 {.exportc, cdecl.} =
  ipcPollIrqCount
