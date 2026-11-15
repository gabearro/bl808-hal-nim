proc bl_rx_sm_connect_ind_cb_register*(env: pointer; cb: ConnectCb): cint {.exportc, cdecl.} =
  setCallback(cbSmConnect, cb, env)
  0

proc bl_rx_sm_connect_ind_cb_unregister*(env: pointer; cb: ConnectCb): cint {.exportc, cdecl.} =
  clearCallback(cbSmConnect)
  0

proc bl_rx_sm_disconnect_ind_cb_register*(env: pointer; cb: DisconnectCb): cint {.exportc, cdecl.} =
  setCallback(cbSmDisconnect, cb, env)
  0

proc bl_rx_sm_disconnect_ind_cb_unregister*(env: pointer; cb: DisconnectCb): cint {.exportc, cdecl.} =
  clearCallback(cbSmDisconnect)
  0
