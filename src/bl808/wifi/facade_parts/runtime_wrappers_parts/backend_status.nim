proc wifiBackendPoll(count: uint32) {.inline.} =
  bl808_wifi_backend_poll(count)

proc wifiBackendConnected(): bool {.inline.} =
  bl808_wifi_backend_connected() != 0

proc wifiBackendScanDone(): bool {.inline.} =
  bl808_wifi_backend_scan_done_count() > 0'u32

proc wifiBackendScanCount(): uint32 {.inline.} =
  bl808_wifi_backend_scan_count()

proc wifiBackendConnectDone(): bool {.inline.} =
  bl808_wifi_backend_connect_done() != 0

proc wifiBackendDisconnectDone(): bool {.inline.} =
  bl808_wifi_backend_disconnect_done() != 0

proc wifiBackendUsesEventFutures(): bool {.inline.} =
  true

proc wifiBackendStaDisconnect(): cint {.inline.} =
  wifi_mgmr_sta_disconnect()

proc wifiBackendStaConnectAbort(): cint {.inline.} =
  wifi_mgmr_sta_connect_abort()
