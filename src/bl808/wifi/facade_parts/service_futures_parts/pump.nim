proc wifiServiceWanted(): bool =
  let hasPending =
    (wifiScanFuture != nil and not wifiScanFuture.finished) or
    (wifiConnectFuture != nil and not wifiConnectFuture.finished) or
    (wifiStaIdleFuture != nil and not wifiStaIdleFuture.finished) or
    (wifiDisconnectFuture != nil and not wifiDisconnectFuture.finished) or
    wifiDisconnectIssuePending
  # The peer indication can clear the host link before SM's cleanup replies
  # or station-delete retry timer arrive. Keep servicing that firmware owner.
  hasPending or sm_state == SmDisconnectingState or
    wifiApEnabled or wifiBackendConnected()

proc wifiServicePump*(iterations: uint32 = 8'u32) {.cdecl.} =
  ## Compatibility entry for callers that cannot yield. The scheduler hook
  ## below uses a separate service entry without a busy-wait delay.
  if not wifiServiceWanted():
    return
  let count = if iterations == 0'u32: 1'u32 else: iterations
  wifiBackendPoll(count)
  wifiNimFirmwareServiceTx(count)
  wifiCompletePendingEvents()
