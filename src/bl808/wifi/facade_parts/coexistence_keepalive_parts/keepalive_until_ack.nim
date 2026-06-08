proc wifiSendStaKeepaliveUntilAckAsync*(
    targetAck, attemptBudget: uint32,
    periodMs: uint32 = 50'u32,
    busyRetryMs: uint32 = 10'u32,
    confirmDrainMs: uint32 = 500'u32,
    serviceIterations: uint32 = 1'u32): CpsFuture[WifiKeepaliveStats] {.cps.} =
  ## Send STA keepalive frames until the requested ACK count is observed or
  ## the attempt budget is exhausted. This is the CPS orchestration layer for
  ## coexistence tests; the TX primitive and bounded service pump stay sync.
  let ackBefore = wifiStaKeepaliveAckOkCount()
  let failBefore = wifiStaKeepaliveFailCount()
  let cfmBefore = wifiStaKeepaliveConfirmCount()
  let txPeriodUs =
    if periodMs == 0'u32: 1'u64 else: periodMs.uint64 * 1000'u64
  let busyPeriodUs =
    if busyRetryMs == 0'u32: 1'u64 else: busyRetryMs.uint64 * 1000'u64
  let count =
    if serviceIterations == 0'u32: 1'u32 else: serviceIterations
  var stats: WifiKeepaliveStats
  while wifiStaKeepaliveAckOkCount() - ackBefore < targetAck and
      stats.attempts < attemptBudget:
    inc stats.attempts
    wifiServicePump(count)
    var nextDelayUs = txPeriodUs
    case wifiSendStaKeepaliveFrame()
    of wifiOk:
      inc stats.frames
    of wifiBusy:
      inc stats.busy
      nextDelayUs = busyPeriodUs
    else:
      inc stats.failures
    wifiServicePump(count)
    await sleepUs(nextDelayUs)

  let confirmDeadline = readTick() + usToTicks(confirmDrainMs.uint64 * 1000'u64)
  while wifiStaKeepaliveConfirmCount() - cfmBefore < stats.frames and
      readTick() < confirmDeadline:
    wifiServicePump(count)
    await sleepUs(1000'u64)

  stats.ackDelta = wifiStaKeepaliveAckOkCount() - ackBefore
  stats.failDelta = wifiStaKeepaliveFailCount() - failBefore
  stats.cfmDelta = wifiStaKeepaliveConfirmCount() - cfmBefore
  return stats
