proc wifiInit*(): WifiError =
  ## Initialize WiFi subsystem. Call once at startup.
  var conf: WifiConf
  let initStatus = wifi_mgmr_init(addr conf)
  if initStatus != 0: return wifiFail
  staIface = wifi_mgmr_sta_enable()
  if staIface == nil: return wifiFail
  wifiOk

proc wifiInitAsync*(): CpsFuture[WifiError] {.cps.} =
  return wifiInit()
