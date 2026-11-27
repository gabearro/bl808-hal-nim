const WifiHostScheduledWorkBudget* {.intdefine.} = 16
  ## Bare-loop callers keep the original drain budget. A CPS work hook
  ## switches each call to one host/firmware step so other ready tasks run.

when defined(radioDiag):
  var wifiScheduledWorkMaxUs: array[6, uint32]

  proc wifiScheduledRecord(slot: int; startUs: uint64) {.inline.} =
    let elapsed = uint32(min(readMtimeUs() - startUs, high(uint32).uint64))
    wifiScheduledWorkMaxUs[slot] = max(wifiScheduledWorkMaxUs[slot], elapsed)

  proc bl808_wifi_backend_drain_timing_snapshot*(snapshot: ptr array[6, uint32])
      {.exportc, cdecl.} =
    snapshot[] = wifiScheduledWorkMaxUs

  proc bl808_wifi_backend_drain_timing_reset*() {.exportc, cdecl.} =
    wifiScheduledWorkMaxUs = default(array[6, uint32])

proc vendorScheduledWorkStep(): bool =
  ## Run one host/firmware handoff. Return whether another step may be useful.
  when defined(radioDiag):
    let stepStart = readMtimeUs()
  var didWork = false
  if bl808WifiBackendHostIpcStatus() != 0:
    inc ipcPollIrqCount
    when defined(radioDiag):
      let irqStart = readMtimeUs()
    bl_irq_handler()
    when defined(radioDiag):
      wifiScheduledRecord(0, irqStart)
    didWork = true
  # vendorPollOnce already ran one firmware event before this handoff. CPS
  # should return to the scheduler before dispatching another; the pending
  # event will wake its next turn. Bare-loop callers keep the original drain.
  if wifiSchedulerWorkHook == nil and ke_evt_field_get() != 0:
    when defined(radioDiag):
      let firmwareStart = readMtimeUs()
    wifi_main_poll_once()
    when defined(radioDiag):
      wifiScheduledRecord(1, firmwareStart)
    didWork = true
  if hostPollEnabled and loadPtr(wifiHwRaw(), 48) != nil:
    if bl808WifiBackendHostIpcStatus() != 0:
      didWork = true
    when defined(radioDiag):
      let hostStart = readMtimeUs()
    bl_main_event_handle(0, nil)
    when defined(radioDiag):
      wifiScheduledRecord(2, hostStart)
  when defined(radioDiag):
    wifiScheduledRecord(3, stepStart)
  didWork or bl808WifiBackendHostIpcStatus() != 0 or ke_evt_field_get() != 0

proc vendorDrainScheduledWork() =
  ## CPS gets one handoff, then decides from work and timer signals when to
  ## run the next. Bare-loop callers retain the old bounded drain for ABI
  ## compatibility; it is never entered with a CPS work hook installed.
  when defined(radioDiag):
    let drainStart = readMtimeUs()
  var steps: uint32
  if not wifi_pm_wake_pending():
    if wifiSchedulerWorkHook != nil:
      inc steps
      discard vendorScheduledWorkStep()
    else:
      var budget = max(WifiHostScheduledWorkBudget, 1)
      while budget > 0 and not wifi_pm_wake_pending():
        inc steps
        dec budget
        if not vendorScheduledWorkStep():
          break
  when defined(radioDiag):
    wifiScheduledRecord(4, drainStart)
    wifiScheduledWorkMaxUs[5] = max(wifiScheduledWorkMaxUs[5], steps)
