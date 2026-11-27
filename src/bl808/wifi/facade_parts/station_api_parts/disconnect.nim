const WifiDisconnectPollLimit {.intdefine.} = 10_000

proc wifiWaitStaIdleAsync(timeoutMs: uint32 = 2_000): CpsFuture[WifiError] =
  if wifiNimFirmwareStaIdle():
    return completedLocalFuture(wifiOk)
  if wifiStaIdleFuture != nil and not wifiStaIdleFuture.finished:
    return wifiStaIdleFuture
  cancelWifiTimer(wifiStaIdleTimer)
  let fut = newLocalCpsFuture[WifiError]()
  wifiStaIdleFuture = fut
  if timeoutMs != 0'u32:
    wifiStaIdleTimer = addTimerMs(timeoutMs.uint64, proc() =
      completeWifiStaIdle(wifiFail)
    )
  wifiCompletePendingEvents()
  return fut

proc wifiIssueDisconnectAsync(timeoutMs: uint32 = 10_000): CpsFuture[WifiError] =
  if not wifiBackendUsesEventFutures():
    let disconnectIssueStatus = wifiNimFirmwareIssueDisconnect()
    return completedLocalFuture(if disconnectIssueStatus == 0: wifiOk else: wifiFail)
  cancelWifiTimer(wifiDisconnectTimer)
  let fut = newLocalCpsFuture[WifiError]()
  wifiDisconnectFuture = fut
  wifiDisconnectIssuePending = true
  wifiDisconnectIssueTimeoutMs = timeoutMs
  bl808_wifi_backend_signal_work()
  return fut

proc wifiDisconnect*(): WifiError =
  wifiBackendPoll(8)
  if wifiNimFirmwareStaDisconnected(): return wifiOk
  wifiDisconnectTrace("[DC] enter\n")
  let status = wifiNimFirmwareIssueDisconnect()
  wifiDisconnectTraceRc("[DC] sta_disconnect rc=", status)
  if status != 0: return wifiFail
  if not wifiNimFirmwareDisconnectNeedsDrain(): return wifiOk
  for iteration in 0 ..< WifiDisconnectPollLimit:
    wifiBackendPoll(8)
    if wifiNimFirmwareStaDisconnected(): return wifiOk
  wifiFail

proc wifiDisconnectAsync*(timeoutMs: uint32 = 10_000): CpsFuture[WifiError] =
  if wifiDisconnectFuture != nil and not wifiDisconnectFuture.finished:
    return failedLocalFuture[WifiError](
      newException(CatchableError, "WiFi disconnect already pending"))
  wifiWakeServiceOrPump()
  if not wifiBackendConnected() and wifiNimFirmwareStaIdle():
    return completedLocalFuture(wifiOk)
  if wifiBackendUsesEventFutures():
    if wifiStaIdleFuture != nil and not wifiStaIdleFuture.finished:
      return failedLocalFuture[WifiError](
        newException(CatchableError, "WiFi disconnect already pending"))
    wifiWakeServiceOrPump(64)
  return wifiIssueDisconnectAsync(timeoutMs)
