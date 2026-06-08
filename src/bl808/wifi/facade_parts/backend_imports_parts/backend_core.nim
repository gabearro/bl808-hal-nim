proc bl808_wifi_backend_init(conf: ptr WifiConf): cint
  {.importc: "bl808_wifi_backend_init", cdecl.}
proc bl808_wifi_backend_poll*(iterations: uint32)
  {.importc: "bl808_wifi_backend_poll", cdecl.}
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
  let rc = bl808_wifi_backend_init(conf)
  wifiInitialized = rc == 0
  rc
