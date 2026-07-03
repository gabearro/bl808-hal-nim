proc cancelWifiTimer(timerId: var TimerId) =
  if timerId != 0'u32:
    cancelTimer(timerId)
    timerId = 0'u32

# complete() synchronously DRIVES THE AWAITING CPS CONTINUATION FORWARD (env.fn =
# nextStep; run(env)). If the module-global future slot still points at this same
# CpsFuture when the continuation resumes, the object has TWO live ARC owners (the
# reassignable global + the await closure's captured `awaitFut`) while the resumed
# loop allocates the next iteration's futures/closures/strings into the churning
# 64 KB heap -> one owner frees the object, the aliased owner survives and later
# increfs it -> nimIncRef reads a reused-slot value (0xA1E1xxxx) -> load fault.
# (Same --mm:arc closure-capture aliasing class as embedded_router.nim:417.)
# So: SNAPSHOT the future, DROP the global co-owner + RETIRE the timer BEFORE
# resuming; complete() runs last with no reassignable alias of `fut` live.
proc completeWifiScan(value: uint32) =
  let fut = wifiScanFuture
  wifiScanFuture = nil
  cancelWifiTimer(wifiScanTimer)
  if fut != nil and not fut.finished:
    complete(fut, value)

proc completeWifiConnect(value: WifiError) =
  let fut = wifiConnectFuture
  wifiConnectFuture = nil
  cancelWifiTimer(wifiConnectTimer)
  if fut != nil and not fut.finished:
    complete(fut, value)

proc completeWifiStaIdle(value: WifiError) =
  let fut = wifiStaIdleFuture
  wifiStaIdleFuture = nil
  cancelWifiTimer(wifiStaIdleTimer)
  if fut != nil and not fut.finished:
    complete(fut, value)

proc completeWifiDisconnect(value: WifiError) =
  let fut = wifiDisconnectFuture
  wifiDisconnectFuture = nil
  cancelWifiTimer(wifiDisconnectTimer)
  wifiDisconnectIssuePending = false
  wifiDisconnectIssueTimeoutMs = 0'u32
  if fut != nil and not fut.finished:
    complete(fut, value)
