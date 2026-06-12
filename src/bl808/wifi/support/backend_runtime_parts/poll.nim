proc vendorPollOnce() =
  if fwStarted:
    bl808WifiBackendPollEmbEvents()
    bl808WifiBackendPollMacIrq()
    bl808WifiBackendDriveRfStatus()
    wifi_main_poll_once()
    vendorDrainScheduledWork()
  elif hostPollEnabled and loadPtr(wifiHwRaw(), 48) != nil:
    bl_main_event_handle(0, nil)

proc vendorPollFor(iterations: uint32) =
  var pollsRemaining = iterations
  while pollsRemaining != 0:
    dec pollsRemaining
    vendorPollOnce()
    delayMtimeUs(100)

proc bl808_wifi_backend_poll*(iterations: cuint) {.exportc, cdecl.} =
  vendorPollFor(if iterations == 0: 1'u32 else: iterations.uint32)
