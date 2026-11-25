proc vendorPollOnce() =
  if fwStarted:
    bl808WifiBackendPollEmbEvents()
    # MAC interrupt servicing stands in for the trap, so it also runs from
    # a poll made inside a firmware step.
    bl808WifiBackendPollMacIrq()
    # Inside a firmware step (a host callback waiting or sleeping), the
    # firmware is not reentered: wifi_main_poll_once refuses and the host
    # queue work below waits for the next poll.
    wifi_main_poll_once()
    if not wifi_nimfw_step_active():
      vendorDrainScheduledWork()
      discard mgmrPmProcessOne()
  elif hostPollEnabled and loadPtr(wifiHwRaw(), 48) != nil:
    bl_main_event_handle(0, nil)
  osTimerPoll()
  aosPollEvents()
  aosPollDelayedActions()

proc vendorPollFor(iterations: uint32) =
  var pollsRemaining = iterations
  while pollsRemaining != 0:
    dec pollsRemaining
    vendorPollOnce()
    delayMtimeUs(100)

proc bl808_wifi_backend_poll*(iterations: cuint) {.exportc, cdecl.} =
  vendorPollFor(if iterations == 0: 1'u32 else: iterations.uint32)
