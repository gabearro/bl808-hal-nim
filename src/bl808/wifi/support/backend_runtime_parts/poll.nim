when defined(radioDiag):
  const WifiPollTimingSlots = 11
  var wifiPollPhaseMaxUs: array[WifiPollTimingSlots, uint32]

  proc wifiPollRecordPhase(slot: int; startUs: uint64) {.inline.} =
    let elapsed = uint32(min(readMtimeUs() - startUs, high(uint32).uint64))
    wifiPollPhaseMaxUs[slot] = max(wifiPollPhaseMaxUs[slot], elapsed)

  proc bl808_wifi_backend_phase_timing_snapshot*(snapshot: ptr array[WifiPollTimingSlots, uint32])
      {.exportc, cdecl.} =
    snapshot[] = wifiPollPhaseMaxUs

  proc bl808_wifi_backend_phase_timing_reset*() {.exportc, cdecl.} =
    wifiPollPhaseMaxUs = default(array[WifiPollTimingSlots, uint32])

proc vendorPollOnce() =
  when defined(radioDiag):
    let pollStart = readMtimeUs()
  if fwStarted:
    when defined(radioDiag):
      let embStart = readMtimeUs()
    bl808WifiBackendPollEmbEvents()
    when defined(radioDiag):
      wifiPollRecordPhase(0, embStart)
    # MAC interrupt servicing stands in for the trap, so it also runs from
    # a poll made inside a firmware step.
    when defined(radioDiag):
      let macStart = readMtimeUs()
    bl808WifiBackendPollMacIrq()
    when defined(radioDiag):
      wifiPollRecordPhase(1, macStart)
    # Inside a firmware step (a host callback waiting or sleeping), the
    # firmware is not reentered: wifi_main_poll_once refuses and the host
    # queue work below waits for the next poll.
    when defined(radioDiag):
      let mainStart = readMtimeUs()
    wifi_main_poll_once()
    when defined(radioDiag):
      wifiPollRecordPhase(2, mainStart)
    if not wifi_nimfw_step_active():
      when defined(radioDiag):
        let scheduledStart = readMtimeUs()
      vendorDrainScheduledWork()
      when defined(radioDiag):
        wifiPollRecordPhase(3, scheduledStart)
        let mgmrStart = readMtimeUs()
      discard mgmrPmProcessOne()
      when defined(radioDiag):
        wifiPollRecordPhase(4, mgmrStart)
  elif hostPollEnabled and loadPtr(wifiHwRaw(), 48) != nil:
    when defined(radioDiag):
      let hostStart = readMtimeUs()
    bl_main_event_handle(0, nil)
    when defined(radioDiag):
      wifiPollRecordPhase(5, hostStart)
  when defined(radioDiag):
    let timerStart = readMtimeUs()
  osTimerPoll()
  when defined(radioDiag):
    wifiPollRecordPhase(6, timerStart)
    let eventsStart = readMtimeUs()
  aosPollEvents()
  when defined(radioDiag):
    wifiPollRecordPhase(7, eventsStart)
    let delayedStart = readMtimeUs()
  aosPollDelayedActions()
  when defined(radioDiag):
    wifiPollRecordPhase(8, delayedStart)
    wifiPollRecordPhase(10, pollStart)

proc vendorPollFor(iterations: uint32) =
  var pollsRemaining = iterations
  while pollsRemaining != 0:
    dec pollsRemaining
    vendorPollOnce()
    delayMtimeUs(100)

proc bl808_wifi_backend_poll*(iterations: cuint) {.exportc, cdecl.} =
  when defined(radioDiag):
    if wifiSchedulerWorkHook != nil:
      inc wifiCpsLegacyPollCalls
  vendorPollFor(if iterations == 0: 1'u32 else: iterations.uint32)

proc bl808_wifi_backend_next_delay_us*(): uint64 {.exportc, cdecl.} =
  ## Relative mtime deadline for the host-side timers. Firmware MAC timers
  ## have their own hardware interrupt and are handled by the facade.
  var nowUs: uint64
  if not sampleMtimeUs(nowUs):
    return high(uint64)
  min(osTimerNextDelayUs(nowUs), aosNextDelayedDelayUs(nowUs))

proc vendorWorkPending(): bool =
  ## A service round is useful when there is an interrupt, queued work or a
  ## due host timer. Only inspect Wi-Fi registers after firmware startup.
  if fwStarted:
    if wifi_pm_wake_pending():
      return false
    if (regRead32(IpcEmb2AppStatus) and IpcA2eMsgBit) != 0 or
        (regRead32(MacIrqStatus0) or regRead32(MacIrqStatus1)) != 0 or
        (regRead32(MachwIrqRaw) and regRead32(MachwIrqUnmask)) != 0 or
        bl808WifiBackendHostIpcStatus() != 0 or
        wifi_nimfw_work_pending() or mgmrPmPending():
      return true
  if aosEventsPending():
    return true
  bl808_wifi_backend_next_delay_us() == 0

proc bl808_wifi_backend_work_pending*(): bool {.exportc, cdecl.} =
  vendorWorkPending()

proc bl808_wifi_backend_service*(maxRounds: uint32): uint32
    {.exportc, cdecl.} =
  ## CPS owns the service cadence: one backend pass per scheduler turn. The
  ## bounded loop remains only for callers without an installed CPS hook.
  if wifiSchedulerWorkHook != nil:
    vendorPollOnce()
    when defined(radioDiag):
      let pendingStart = readMtimeUs()
      discard vendorWorkPending()
      wifiPollRecordPhase(9, pendingStart)
    return 1'u32
  let budget = min(max(maxRounds, 1'u32), 32'u32)
  while result < budget:
    vendorPollOnce()
    inc result
    when defined(radioDiag):
      let pendingStart = readMtimeUs()
    let pending = vendorWorkPending()
    when defined(radioDiag):
      wifiPollRecordPhase(9, pendingStart)
    if not pending:
      break
