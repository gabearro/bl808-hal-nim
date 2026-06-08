proc cancelWifiTimer(timerId: var TimerId) =
  if timerId != 0'u32:
    cancelTimer(timerId)
    timerId = 0'u32

proc completeWifiScan(value: uint32) =
  if wifiScanFuture != nil and not wifiScanFuture.finished:
    complete(wifiScanFuture, value)
  cancelWifiTimer(wifiScanTimer)
  wifiScanFuture = nil

proc completeWifiConnect(value: WifiError) =
  if wifiConnectFuture != nil and not wifiConnectFuture.finished:
    complete(wifiConnectFuture, value)
  cancelWifiTimer(wifiConnectTimer)
  wifiConnectFuture = nil

proc completeWifiStaIdle(value: WifiError) =
  if wifiStaIdleFuture != nil and not wifiStaIdleFuture.finished:
    complete(wifiStaIdleFuture, value)
  cancelWifiTimer(wifiStaIdleTimer)
  wifiStaIdleFuture = nil

proc completeWifiDisconnect(value: WifiError) =
  if wifiDisconnectFuture != nil and not wifiDisconnectFuture.finished:
    complete(wifiDisconnectFuture, value)
  cancelWifiTimer(wifiDisconnectTimer)
  wifiDisconnectFuture = nil
  wifiDisconnectIssuePending = false
  wifiDisconnectIssueTimeoutMs = 0'u32
