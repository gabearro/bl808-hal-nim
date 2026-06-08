proc wifiServicePump*(iterations: uint32 = 8'u32) {.cdecl.} =
  ## One bounded WiFi control-plane service step. The MAC/firmware timing
  ## remains below this layer; CPS callers use this instead of ad hoc polls.
  let hasPending =
    (wifiScanFuture != nil and not wifiScanFuture.finished) or
    (wifiConnectFuture != nil and not wifiConnectFuture.finished) or
    (wifiStaIdleFuture != nil and not wifiStaIdleFuture.finished) or
    (wifiDisconnectFuture != nil and not wifiDisconnectFuture.finished) or
    wifiDisconnectIssuePending
  if not hasPending and not wifiApEnabled and not wifiBackendConnected():
    return
  let count = if iterations == 0'u32: 1'u32 else: iterations
  wifiBackendPoll(count)
  wifiNimFirmwareServiceTx(count)
  wifiCompletePendingEvents()

proc wifiServiceTask*(periodUs: uint32 = 1000'u32,
                      iterations: uint32 = 8'u32): CpsVoidFuture {.cps.} =
  let delay = if periodUs == 0'u32: 1'u32 else: periodUs
  while true:
    wifiServicePump(iterations)
    await sleepUs(delay.uint64)
