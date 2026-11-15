proc wifiNimFirmwareStaIdle(): bool {.inline.} =
  sm_state == 0'u16

proc wifiNimFirmwareStaDisconnected(): bool {.inline.} =
  not wifiBackendConnected() and wifiNimFirmwareStaIdle()

proc wifiNimFirmwareIssueDisconnect(): cint {.inline.} =
  if not wifiBackendConnected() and not wifiNimFirmwareStaIdle():
    return wifiBackendStaConnectAbort()
  wifiBackendStaDisconnect()

proc wifiNimFirmwareDisconnectNeedsDrain(): bool {.inline.} =
  true

proc wifiNimFirmwarePruneScanCache(ssid: string) {.inline.} =
  wifi_nimfw_prune_scan_raw_cache_for_ssid(ssid.cstring, ssid.len.uint32)

proc wifiNimFirmwareServiceTx(count: uint32) {.inline.} =
  discard wifi_nimfw_service_sta_postponed(count)
  for _ in 0'u32 ..< count:
    txl_transmit_trigger()
    txl_frame_evt()
