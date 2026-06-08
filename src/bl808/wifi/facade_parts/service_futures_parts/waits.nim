proc wifiBeginScanWait(timeoutMs: uint32): CpsFuture[uint32] =
  if not wifiBackendUsesEventFutures():
    return completedLocalFuture(0'u32)
  wifiScanFuture = newLocalCpsFuture[uint32]()
  if timeoutMs != 0'u32:
    wifiScanTimer = addTimerMs(timeoutMs.uint64, proc() =
      completeWifiScan(0'u32)
    )
  wifiCompletePendingEvents()
  return wifiScanFuture

proc wifiBeginConnectWait(timeoutMs: uint32): CpsFuture[WifiError] =
  if not wifiBackendUsesEventFutures():
    return completedLocalFuture(if wifiBackendConnected(): wifiOk else: wifiFail)
  wifiConnectFuture = newLocalCpsFuture[WifiError]()
  if timeoutMs != 0'u32:
    wifiConnectTimer = addTimerMs(timeoutMs.uint64, proc() =
      completeWifiConnect(wifiFail)
    )
  wifiCompletePendingEvents()
  return wifiConnectFuture
