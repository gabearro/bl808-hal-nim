proc bl_rx_rssi_cb_register*(env: pointer; cb: RssiCb): cint {.exportc, cdecl.} =
  setCallback(cbRssi, cb, env)
  0

proc bl_rx_rssi_cb_unregister*(env: pointer; cb: RssiCb): cint {.exportc, cdecl.} =
  clearCallback(cbRssi)
  0

proc bl_rx_event_register*(env: pointer; cb: EventCb): cint {.exportc, cdecl.} =
  setCallback(cbEvent, cb, env)
  0

proc bl_rx_event_unregister*(env: pointer): cint {.exportc, cdecl.} =
  clearCallback(cbEvent)
  0
