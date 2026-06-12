proc wifiCompletePendingEvents() =
  if wifiScanFuture != nil and not wifiScanFuture.finished and
      wifiBackendScanDone():
    completeWifiScan(wifiBackendScanCount())
  if wifiConnectFuture != nil and not wifiConnectFuture.finished and
      wifiBackendConnectDone():
    completeWifiConnect(if wifiBackendConnected(): wifiOk else: wifiFail)
  if wifiStaIdleFuture != nil and not wifiStaIdleFuture.finished and
      wifiNimFirmwareStaIdle():
    completeWifiStaIdle(wifiOk)
  if wifiDisconnectIssuePending and wifiDisconnectFuture != nil and
      not wifiDisconnectFuture.finished:
    wifiDisconnectIssuePending = false
    let disconnectIssueStatus = wifiNimFirmwareIssueDisconnect()
    if disconnectIssueStatus != 0:
      completeWifiDisconnect(wifiFail)
    elif wifiDisconnectIssueTimeoutMs != 0'u32:
      wifiDisconnectTimer = addTimerMs(
        wifiDisconnectIssueTimeoutMs.uint64,
        proc() = completeWifiDisconnect(wifiFail))
  if wifiDisconnectFuture != nil and not wifiDisconnectFuture.finished:
    if wifiBackendDisconnectDone() or wifiNimFirmwareStaIdle():
      completeWifiDisconnect(wifiOk)
