proc bl_rx_rssi_cb_register*(env: pointer; cb: RssiCb): cint {.exportc, cdecl.} =
  cbRssi = cb
  cbRssiEnv = env
  0

proc bl_rx_rssi_cb_unregister*(env: pointer; cb: RssiCb): cint {.exportc, cdecl.} =
  cbRssi = nil
  cbRssiEnv = nil
  0

proc bl_rx_event_register*(env: pointer; cb: EventCb): cint {.exportc, cdecl.} =
  cbEvent = cb
  cbEventEnv = env
  0

proc bl_rx_event_unregister*(env: pointer): cint {.exportc, cdecl.} =
  cbEvent = nil
  cbEventEnv = nil
  0
