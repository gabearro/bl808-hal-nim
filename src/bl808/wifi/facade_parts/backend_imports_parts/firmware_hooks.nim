var sm_state {.importc.}: uint16

proc txl_transmit_trigger*() {.importc, cdecl.}
proc txl_frame_evt*() {.importc, cdecl.}
proc wifi_nimfw_prune_scan_raw_cache_for_ssid*(ssid: cstring,
                                               ssidLen: uint32)
  {.importc, cdecl.}
proc wifi_nimfw_set_sta_tx_channel_prepare_enabled*(enabled: uint32)
  {.importc, cdecl.}
proc wifi_nimfw_prepare_sta_tx_channel*() {.importc, cdecl.}
proc wifi_nimfw_set_ble_wifi_role_window_enabled*(enabled: uint32)
  {.importc, cdecl.}
proc wifi_nimfw_set_keepalive_qosnull_enabled*(enabled: uint32)
  {.importc, cdecl.}
proc rwip_wlcoex_set*(enabled: bool) {.importc, cdecl.}

proc bl_main_disconnect*(): cint {.importc, cdecl.}
