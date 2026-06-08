proc wifiNimFirmwareSetBleCoexMode(mode: uint32) {.inline.} =
  coex_pta_force_autocontrol_set(mode)
  rwip_wlcoex_set(mode != wifiBleCoexWifiAlwaysOn)
  wifi_nimfw_set_sta_tx_channel_prepare_enabled(
    if mode == wifiBleCoexWifiPriority: 1'u32 else: 0'u32)
  wifi_nimfw_set_ble_wifi_role_window_enabled(
    if mode == wifiBleCoexWifiPriority: 1'u32 else: 0'u32)

proc wifiNimFirmwareReclaimStaTxChannel() {.inline.} =
  wifi_nimfw_prepare_sta_tx_channel()
