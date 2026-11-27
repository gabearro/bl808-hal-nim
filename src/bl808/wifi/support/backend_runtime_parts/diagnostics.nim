proc bl808_wifi_backend_scan_count*(): uint32 {.exportc, cdecl.} =
  scanItemCount

when defined(radioDiag):
  proc bl808_wifi_backend_cps_compat_counts*(snapshot: ptr array[3, uint32])
      {.exportc, cdecl.} =
    snapshot[] = [wifiCpsNestedWaitPolls, wifiCpsSleepPolls, wifiCpsLegacyPollCalls]

  proc bl808_wifi_backend_cps_compat_reset*() {.exportc, cdecl.} =
    wifiCpsNestedWaitPolls = 0
    wifiCpsSleepPolls = 0
    wifiCpsLegacyPollCalls = 0

proc bl808_wifi_backend_scan_done_count*(): uint32 {.exportc, cdecl.} =
  scanDoneCount

proc bl808_wifi_backend_scan_confirmation*(): uint32 {.exportc, cdecl.} =
  scanConfirmationStatus

proc bl808_wifi_backend_record_scan_confirmation*(status: uint32) {.exportc, cdecl.} =
  scanConfirmationStatus = status

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
