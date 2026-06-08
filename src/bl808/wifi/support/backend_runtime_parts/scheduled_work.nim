proc vendorDrainScheduledWork() =
  # The SDK has independent host/firmware tasks. This port runs both sides on
  # M0, so each poll drains bounded queued work instead of relying on UART or
  # unrelated delays to pace command ACK/CFM delivery.
  var budget = 16
  while budget > 0:
    dec budget
    var didWork = false
    if bl808WifiBackendHostIpcStatus() != 0:
      inc ipcPollIrqCount
      bl_irq_handler()
      didWork = true
    if keEvtField != 0:
      wifi_main_poll_once()
      didWork = true
    if hostPollEnabled and loadPtr(wifiHwRaw(), 48) != nil:
      if bl808WifiBackendHostIpcStatus() != 0:
        didWork = true
      bl_main_event_handle(0, nil)
    if not didWork and bl808WifiBackendHostIpcStatus() == 0 and keEvtField == 0:
      break
