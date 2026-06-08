proc wifiStartAp*(ssid, password: string, channel: int = 1): WifiError =
  let rc = wifi_mgmr_ap_start(addr staIface, ssid.cstring,
                               0, password.cstring, channel.cint)
  if rc == 0:
    wifiApEnabled = true
    wifiOk
  else:
    wifiFail

proc wifiStartApAsync*(ssid, password: string,
                       channel: int = 1): CpsFuture[WifiError] {.cps.} =
  return wifiStartAp(ssid, password, channel)

proc wifiStopAp*(): WifiError =
  let rc = wifi_mgmr_ap_stop(addr staIface)
  if rc == 0:
    wifiApEnabled = false
    wifiOk
  else:
    wifiFail

proc wifiStopApAsync*(): CpsFuture[WifiError] {.cps.} =
  return wifiStopAp()

proc wifiGetNetif*(): pointer =
  ## Get the lwIP netif for the STA interface.
  ## Cast to `ptr NetIf` in your lwIP bindings.
  wifi_mgmr_sta_netif_get()
