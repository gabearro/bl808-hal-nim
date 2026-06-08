proc wifiInit*(): WifiError =
  ## Initialize WiFi subsystem. Call once at startup.
  var conf: WifiConf
  let rc = wifi_mgmr_init(addr conf)
  if rc != 0: return wifiFail
  staIface = wifi_mgmr_sta_enable()
  if staIface == nil: return wifiFail
  wifiOk

proc wifiInitAsync*(): CpsFuture[WifiError] {.cps.} =
  return wifiInit()
