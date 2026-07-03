proc wifiBeginScanWait(timeoutMs: uint32): CpsFuture[uint32] =
  if not wifiBackendUsesEventFutures():
    return completedLocalFuture(0'u32)
  let fut = newLocalCpsFuture[uint32]()
  wifiScanFuture = fut
  if timeoutMs != 0'u32:
    wifiScanTimer = addTimerMs(timeoutMs.uint64, proc() =
      completeWifiScan(0'u32)
    )
  wifiCompletePendingEvents()
  # Return the local, not the global: the pump above may have completed+nil'd
  # the global, but `fut` is the real (now-finished) future the await needs.
  return fut

proc wifiBeginConnectWait(timeoutMs: uint32): CpsFuture[WifiError] =
  if not wifiBackendUsesEventFutures():
    return completedLocalFuture(if wifiBackendConnected(): wifiOk else: wifiFail)
  let fut = newLocalCpsFuture[WifiError]()
  wifiConnectFuture = fut
  if timeoutMs != 0'u32:
    wifiConnectTimer = addTimerMs(timeoutMs.uint64, proc() =
      completeWifiConnect(wifiFail)
    )
  wifiCompletePendingEvents()
  return fut
