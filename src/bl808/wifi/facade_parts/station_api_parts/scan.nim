proc wifiScanAsync*(timeoutMs: uint32 = 30_000): CpsFuture[uint32] =
  if staIface == nil:
    return completedLocalFuture(0'u32)
  if wifiScanFuture != nil and not wifiScanFuture.finished:
    return failedLocalFuture[uint32](
      newException(CatchableError, "WiFi scan already pending"))
  let scanStartStatus = wifi_mgmr_scan(addr staIface, nil)
  if scanStartStatus != 0:
    return completedLocalFuture(0'u32)
  return wifiBeginScanWait(timeoutMs)
