proc bl808_wifi_backend_init(conf: ptr WifiConf): cint
  {.importc: "bl808_wifi_backend_init", cdecl.}
proc bl808_wifi_backend_poll*(iterations: uint32)
  {.importc: "bl808_wifi_backend_poll", cdecl.}
proc bl808_wifi_backend_set_work_hook*(hook: proc() {.cdecl.})
  {.importc: "bl808_wifi_backend_set_work_hook", cdecl.}
proc bl808_wifi_backend_signal_work*()
  {.importc: "bl808_wifi_backend_signal_work", cdecl.}
proc bl808_wifi_backend_service*(maxRounds: uint32): uint32
  {.importc: "bl808_wifi_backend_service", cdecl.}
proc bl808_wifi_backend_work_pending*(): bool
  {.importc: "bl808_wifi_backend_work_pending", cdecl.}
proc bl808_wifi_backend_next_delay_us*(): uint64
  {.importc: "bl808_wifi_backend_next_delay_us", cdecl.}
proc bl808_wifi_backend_connected*(): cint
  {.importc: "bl808_wifi_backend_connected", cdecl.}
proc bl808_wifi_backend_connect_done*(): cint
  {.importc: "bl808_wifi_backend_connect_done", cdecl.}
proc bl808_wifi_backend_disconnect_done*(): cint
  {.importc: "bl808_wifi_backend_disconnect_done", cdecl.}
proc bl808_wifi_backend_last_status*(): cint
  {.importc: "bl808_wifi_backend_last_status", cdecl.}
proc bl808_wifi_backend_last_reason*(): cint
  {.importc: "bl808_wifi_backend_last_reason", cdecl.}

proc wifi_mgmr_init*(conf: ptr WifiConf): cint {.cdecl.} =
  let backendStatus = bl808_wifi_backend_init(conf)
  wifiInitialized = backendStatus == 0
  backendStatus
