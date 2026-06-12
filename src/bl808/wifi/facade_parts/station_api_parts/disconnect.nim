proc wifiWaitStaIdleAsync(timeoutMs: uint32 = 2_000): CpsFuture[WifiError] =
  if wifiNimFirmwareStaIdle():
    return completedLocalFuture(wifiOk)
  if wifiStaIdleFuture != nil and not wifiStaIdleFuture.finished:
    return wifiStaIdleFuture
  wifiStaIdleFuture = newLocalCpsFuture[WifiError]()
  if timeoutMs != 0'u32:
    wifiStaIdleTimer = addTimerMs(timeoutMs.uint64, proc() =
      completeWifiStaIdle(wifiFail)
    )
  wifiCompletePendingEvents()
  return wifiStaIdleFuture

proc wifiIssueDisconnectAsync(timeoutMs: uint32 = 10_000): CpsFuture[WifiError] =
  if not wifiBackendUsesEventFutures():
    let disconnectIssueStatus = wifiNimFirmwareIssueDisconnect()
    return completedLocalFuture(if disconnectIssueStatus == 0: wifiOk else: wifiFail)
  wifiDisconnectFuture = newLocalCpsFuture[WifiError]()
  wifiDisconnectIssuePending = true
  wifiDisconnectIssueTimeoutMs = timeoutMs
  return wifiDisconnectFuture

proc wifiDisconnect*(): WifiError =
  wifiBackendPoll(8)
  if not wifiBackendConnected():
    return wifiOk
  if wifiNimFirmwareDisconnectNeedsDrain():
    wifiDisconnectTrace("[DC] enter\n")
    wifiBackendPoll(64)
    wifiDisconnectTrace("[DC] poll64 done\n")
    for _ in 0 ..< 2000:
      if wifiNimFirmwareStaIdle():
        break
      wifiBackendPoll(8)
    wifiDisconnectTrace("[DC] pre-loop done\n")
  let disconnectStatus = wifiBackendStaDisconnect()
  if wifiNimFirmwareDisconnectNeedsDrain():
    wifiDisconnectTraceRc("[DC] sta_disconnect rc=", disconnectStatus.cint)
    if disconnectStatus != 0:
      return wifiFail
    var loopIter: int = 0
    for _ in 0 ..< 10_000:
      wifiBackendPoll(8)
      if wifiNimFirmwareStaIdle():
        return wifiOk
      inc loopIter
      if (loopIter mod 500) == 0:
        wifiDisconnectTraceRc("[DC-poll] iter=", loopIter.cint)
        wifiDisconnectTraceRc("[DC-poll] sm_state=",
                              if wifiNimFirmwareStaIdle(): 0.cint else: 1.cint)
        wifiDisconnectTraceRc("[DC-poll] disc_done=",
                              if wifiBackendDisconnectDone(): 1.cint else: 0.cint)
    return wifiFail
  else:
    if disconnectStatus == 0: wifiOk else: wifiFail

proc wifiDisconnectAsync*(timeoutMs: uint32 = 10_000): CpsFuture[WifiError] =
  if wifiDisconnectFuture != nil and not wifiDisconnectFuture.finished:
    return failedLocalFuture[WifiError](
      newException(CatchableError, "WiFi disconnect already pending"))
  wifiServicePump()
  if not wifiBackendConnected():
    return completedLocalFuture(wifiOk)
  if wifiBackendUsesEventFutures():
    if wifiStaIdleFuture != nil and not wifiStaIdleFuture.finished:
      return failedLocalFuture[WifiError](
        newException(CatchableError, "WiFi disconnect already pending"))
    wifiServicePump(64)
  return wifiIssueDisconnectAsync(timeoutMs)
