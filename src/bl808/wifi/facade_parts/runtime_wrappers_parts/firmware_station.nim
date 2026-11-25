proc wifiNimFirmwareStaIdle(): bool {.inline.} =
  sm_state == SmIdleState

proc wifiNimFirmwareStaDisconnected(): bool {.inline.} =
  not wifiBackendConnected() and wifiNimFirmwareStaIdle()

proc wifiNimFirmwareIssueDisconnect(): cint {.inline.} =
  let state = sm_state
  # The public waits still require both link-down and SM idle. Don't send a
  # new command for a teardown that already owns the station.
  if state == SmDisconnectingState:
    return 0
  if not wifiBackendConnected():
    if state == SmIdleState: return 0
    return wifiBackendStaConnectAbort()
  wifiBackendStaDisconnect()

proc wifiNimFirmwareDisconnectNeedsDrain(): bool {.inline.} =
  true

proc wifiNimFirmwarePruneScanCache(ssid: string) {.inline.} =
  wifi_nimfw_prune_scan_raw_cache_for_ssid(ssid.cstring, ssid.len.uint32)

proc wifiNimFirmwareServiceTx(count: uint32) {.inline.} =
  # One firmware step; refused while another one is running.
  wifi_nimfw_service_tx(count)
