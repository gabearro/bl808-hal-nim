var
  wifiServiceHookInstalled: bool
  wifiServiceHookPeriodTicks: uint64 = usToTicks(1000'u64)
  wifiServiceHookIterations: uint32 = 8'u32

proc wifiServicePollHook(now: uint64): uint64 =
  wifiServicePump(wifiServiceHookIterations)
  now + wifiServiceHookPeriodTicks

proc wifiConfigureServiceHook*(periodUs: uint32 = 1000'u32,
                               iterations: uint32 = 8'u32) =
  ## Configure the scheduler-owned WiFi pump cadence without allocating a CPS
  ## sleep future on every service tick.
  wifiServiceHookPeriodTicks =
    if periodUs == 0'u32: 1'u64 else: usToTicks(periodUs.uint64)
  wifiServiceHookIterations =
    if iterations == 0'u32: 1'u32 else: iterations

proc wifiInstallServiceHook*(periodUs: uint32 = 1000'u32,
                             iterations: uint32 = 8'u32) =
  ## Install the high-frequency WiFi control-plane pump as a scheduler poll
  ## hook. Timed scheduler hooks wake from WFI only when service is due.
  wifiConfigureServiceHook(periodUs, iterations)
  if not wifiServiceHookInstalled:
    wifiServiceHookInstalled =
      addSchedulerTimedPollHook(wifiServicePollHook, readTick())
