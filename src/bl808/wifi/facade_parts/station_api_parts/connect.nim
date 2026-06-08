proc wifiConnect*(ssid, password: string, channel: uint8 = 0): WifiError =
  ## Connect to a WiFi AP.
  wifiNimFirmwarePruneScanCache(ssid)
  let rc = wifi_mgmr_sta_connect(
    addr staIface, ssid.cstring, password.cstring,
    nil, nil, 0, channel)
  if rc != 0:
    return wifiFail
  if wifiBackendUsesEventFutures():
    for _ in 0 ..< 30_000:
      wifiBackendPoll(8)
      wifiNimFirmwareServiceTx(8)
      if wifiBackendConnectDone():
        break
  return if wifiBackendConnected(): wifiOk else: wifiFail

proc wifiConnectAsync*(ssid, password: string,
                       channel: uint8 = 0,
                       timeoutMs: uint32 = 30_000): CpsFuture[WifiError] =
  if wifiConnectFuture != nil and not wifiConnectFuture.finished:
    return failedLocalFuture[WifiError](
      newException(CatchableError, "WiFi connect already pending"))
  wifiNimFirmwarePruneScanCache(ssid)
  let rc = wifi_mgmr_sta_connect(
    addr staIface, ssid.cstring, password.cstring,
    nil, nil, 0, channel)
  if rc != 0:
    return completedLocalFuture(wifiFail)
  return wifiBeginConnectWait(timeoutMs)
