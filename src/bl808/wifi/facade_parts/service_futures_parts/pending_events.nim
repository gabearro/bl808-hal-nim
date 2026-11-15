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
    let pending = wifiDisconnectFuture
    let timeout = wifiDisconnectIssueTimeoutMs
    wifiDisconnectIssuePending = false
    let disconnectIssueStatus = wifiNimFirmwareIssueDisconnect()
    if wifiDisconnectFuture != pending or pending.finished: return
    if disconnectIssueStatus != 0:
      completeWifiDisconnect(wifiFail)
      return
    elif timeout != 0'u32:
      wifiDisconnectTimer = addTimerMs(
        timeout.uint64,
        proc() = completeWifiDisconnect(wifiFail))
  if wifiDisconnectFuture != nil and not wifiDisconnectFuture.finished:
    if wifiNimFirmwareStaDisconnected():
      completeWifiDisconnect(wifiOk)
