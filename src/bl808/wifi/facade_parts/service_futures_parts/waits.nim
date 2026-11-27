proc wifiBeginScanWait(timeoutMs: uint32): CpsFuture[uint32] =
  if not wifiBackendUsesEventFutures():
    noteWifiScan(wifiScanUnavailable, 0'u32)
    return completedLocalFuture(0'u32)
  cancelWifiTimer(wifiScanTimer)
  let fut = newLocalCpsFuture[uint32]()
  wifiScanFuture = fut
  noteWifiScan(wifiScanPending, 0'u32)
  if timeoutMs != 0'u32:
    wifiScanTimer = addTimerMs(timeoutMs.uint64, proc() =
      noteWifiScan(wifiScanTimedOut, 0'u32)
      completeWifiScan(0'u32)
    )
  wifiCompletePendingEvents()
  bl808_wifi_backend_signal_work()
  # Return the local, not the global: the pump above may have completed+nil'd
  # the global, but `fut` is the real (now-finished) future the await needs.
  return fut

proc wifiBeginConnectWait(timeoutMs: uint32): CpsFuture[WifiError] =
  if not wifiBackendUsesEventFutures():
    return completedLocalFuture(if wifiBackendConnected(): wifiOk else: wifiFail)
  cancelWifiTimer(wifiConnectTimer)
  let fut = newLocalCpsFuture[WifiError]()
  wifiConnectFuture = fut
  if timeoutMs != 0'u32:
    wifiConnectTimer = addTimerMs(timeoutMs.uint64, proc() =
      completeWifiConnect(wifiFail)
    )
  wifiCompletePendingEvents()
  bl808_wifi_backend_signal_work()
  return fut
