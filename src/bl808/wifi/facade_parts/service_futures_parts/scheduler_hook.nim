## CPS owns Wi-Fi service when this hook is installed. Interrupts and host
## notifications enqueue one callback; timers and a bounded safety deadline
## cover work without a notification. The synchronous API still uses the
## paced wifiServicePump entry.

const
  WifiServiceBackstopUs* {.intdefine.} = 10_000
  WifiServiceRetryUs = 1_000'u64
  WifiServiceTimerGraceUs = 250'u64
  WifiServiceMaxFullBursts = 8

var
  wifiServiceHookInstalled: bool
  wifiServiceActivePeriodUs: uint64 = 1_000'u64
  wifiServiceWakePosted: bool
  wifiServiceRunning: bool
  wifiServiceWakeDuringRun: bool
  wifiServiceFullBursts: int
  wifiServiceStalled: bool

when defined(radioDiag):
  type WifiServiceTiming* = object
    callbacks*, fullBudgetCallbacks*, slowCallbacks*: uint32
    maxRounds*, maxCallbackUs*, maxBackendUs*, maxTxUs*, maxCompletionUs*: uint32
    totalCallbackUs*, totalBackendUs*: uint64

  var wifiServiceTiming: WifiServiceTiming

  proc wifiServiceTimingSnapshot*(): WifiServiceTiming = wifiServiceTiming

  proc wifiServiceTimingReset*() =
    wifiServiceTiming = default(WifiServiceTiming)

  proc wifiServiceElapsedUs(startTick: uint64): uint32 {.inline.} =
    uint32(min(ticksToUs(readTick() - startTick), high(uint32).uint64))

proc wifiServiceRunPosted()
proc wifiServicePollHook(now: uint64): uint64

proc wifiRxServicePending(): bool =
  const
    RxControlEvent = 1'u32 shl 20
    RxUploadEvent = 1'u32 shl 23
  (ke_evt_field_get() and (RxControlEvent or RxUploadEvent)) != 0

proc wifiServiceWake() {.cdecl.} =
  ## The scheduler can take posted RX work at a callback boundary. Both queues
  ## report admission, so the coalescing flag only tracks work actually posted.
  withInterruptsDisabled:
    if wifiServiceRunning:
      wifiServiceWakeDuringRun = true
    elif not wifiServiceWakePosted and
        (tryPostPriorityFromIsr(wifiServiceRunPosted, wifiRxServicePending) or
         tryPostFromIsr(wifiServiceRunPosted)):
      wifiServiceWakePosted = true

proc wifiServiceNextDeadline(): uint64 =
  let now = readTick()
  var delayUs = max(WifiServiceBackstopUs, 1).uint64
  if wifiServiceWanted():
    delayUs = min(delayUs, wifiServiceActivePeriodUs)
  if wifiServiceStalled or wifi_pm_wake_pending():
    delayUs = min(delayUs, WifiServiceRetryUs)
  if wifiInitialized:
    let firmwareDelay = wifi_nimfw_next_timer_delay_us()
    if firmwareDelay != high(int32):
      delayUs = min(delayUs, firmwareDelay.uint64 + WifiServiceTimerGraceUs)
  delayUs = min(delayUs, bl808_wifi_backend_next_delay_us())
  now + usToTicks(max(delayUs, 1'u64))

proc wifiServiceRun(fromTimer: bool) =
  when defined(radioProfiler):
    let profileService = beginProfileSpan()
  when defined(radioDiag):
    let callbackStart = readTick()
  var run = false
  withInterruptsDisabled:
    # A posted callback owns this wake even if the timer also becomes due.
    if not wifiServiceRunning and (not fromTimer or not wifiServiceWakePosted):
      wifiServiceRunning = true
      wifiServiceWakePosted = false
      wifiServiceWakeDuringRun = false
      run = true
  if not run:
    return

  if not fromTimer or wifiServiceWanted() or bl808_wifi_backend_work_pending():
    when defined(radioProfiler):
      let profileBackend = beginProfileSpan()
    when defined(radioDiag):
      let backendStart = readTick()
    let rounds = bl808_wifi_backend_service(1'u32)
    when defined(radioProfiler):
      endProfileSpan(profileBackend, prWifiBackend)
    when defined(radioDiag):
      let elapsed = wifiServiceElapsedUs(backendStart)
      wifiServiceTiming.totalBackendUs += elapsed.uint64
      wifiServiceTiming.maxBackendUs = max(wifiServiceTiming.maxBackendUs, elapsed)
      wifiServiceTiming.maxRounds = max(wifiServiceTiming.maxRounds, rounds)
      if rounds == 1'u32:
        inc wifiServiceTiming.fullBudgetCallbacks
    if wifiInitialized:
      # One TX round per service. A fresh completion or queued frame can wake
      # another run without holding the core in a fixed-count TX loop.
      when defined(radioDiag):
        let txStart = readTick()
      wifiNimFirmwareServiceTx(1)
      when defined(radioDiag):
        wifiServiceTiming.maxTxUs = max(wifiServiceTiming.maxTxUs,
                                        wifiServiceElapsedUs(txStart))

  var sawWake = false
  withInterruptsDisabled:
    sawWake = wifiServiceWakeDuringRun
    wifiServiceWakeDuringRun = false
    wifiServiceRunning = false
  # Completing a future can run its CPS continuation immediately. Do it after
  # releasing the service guard and the IRQ lock.
  when defined(radioDiag):
    let completionStart = readTick()
  wifiCompletePendingEvents()
  when defined(radioDiag):
    wifiServiceTiming.maxCompletionUs = max(wifiServiceTiming.maxCompletionUs,
                                            wifiServiceElapsedUs(completionStart))
  if sawWake or bl808_wifi_backend_work_pending():
    if wifiServiceFullBursts < WifiServiceMaxFullBursts:
      inc wifiServiceFullBursts
      wifiServiceWake()
    else:
      # A sticky hardware status bit must not turn a callback into a spin.
      wifiServiceStalled = true
  else:
    wifiServiceFullBursts = 0
    wifiServiceStalled = false
  when defined(radioProfiler):
    endProfileSpan(profileService, prWifiService, work = (not fromTimer).uint32,
                   detail = fromTimer.uint16, trace = true)
  when defined(radioDiag):
    let elapsed = wifiServiceElapsedUs(callbackStart)
    schedulerTimingAddWifiUs(elapsed)
    inc wifiServiceTiming.callbacks
    wifiServiceTiming.totalCallbackUs += elapsed.uint64
    wifiServiceTiming.maxCallbackUs = max(wifiServiceTiming.maxCallbackUs, elapsed)
    if elapsed > 15_000'u32:
      inc wifiServiceTiming.slowCallbacks

proc wifiServiceRunPosted() =
  wifiServiceRun(false)
  discard rescheduleSchedulerTimedPollHook(
    wifiServicePollHook, wifiServiceNextDeadline())

proc wifiServicePollHook(now: uint64): uint64 =
  discard now
  wifiServiceRun(true)
  wifiServiceNextDeadline()

proc wifiConfigureServiceHook*(periodUs: uint32 = 1000'u32) =
  ## CPS owns the burst size: one service step per scheduler turn. `periodUs`
  ## caps the interval while a station/AP or API waiter is active.
  wifiServiceActivePeriodUs = max(periodUs, 1'u32).uint64
  if wifiServiceHookInstalled:
    wifiServiceWake()

proc wifiConfigureServiceHook*(periodUs, iterations: uint32) =
  ## Source-compatible form for older callers; CPS no longer batches steps.
  discard iterations
  wifiConfigureServiceHook(periodUs)

proc wifiInstallServiceHook*(periodUs: uint32 = 1000'u32) =
  wifiConfigureServiceHook(periodUs)
  if not wifiServiceHookInstalled:
    wifiServiceHookInstalled =
      # Zero disarms a timed hook. Keep a recovery deadline even if the
      # initial ISR queue post is rejected while booting at tick zero.
      addSchedulerTimedPollHook(wifiServicePollHook, readTick() + 1'u64)
    if wifiServiceHookInstalled:
      bl808_wifi_backend_set_work_hook(wifiServiceWake)
      wifiServiceWake()

proc wifiInstallServiceHook*(periodUs, iterations: uint32) =
  discard iterations
  wifiInstallServiceHook(periodUs)

proc wifiWakeServiceOrPump(iterations: uint32 = 8'u32) =
  ## Async callers hand progress to CPS; bare-loop callers retain their
  ## synchronous compatibility pump.
  if wifiServiceHookInstalled:
    bl808_wifi_backend_signal_work()
  else:
    wifiServicePump(iterations)
