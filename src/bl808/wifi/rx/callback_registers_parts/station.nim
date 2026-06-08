proc bl_rx_sm_connect_ind_cb_register*(env: pointer; cb: ConnectCb): cint {.exportc, cdecl.} =
  cbSmConnect = cb
  cbSmConnectEnv = env
  0

proc bl_rx_sm_connect_ind_cb_unregister*(env: pointer; cb: ConnectCb): cint {.exportc, cdecl.} =
  cbSmConnect = nil
  cbSmConnectEnv = nil
  0

proc bl_rx_sm_disconnect_ind_cb_register*(env: pointer; cb: DisconnectCb): cint {.exportc, cdecl.} =
  cbSmDisconnect = cb
  cbSmDisconnectEnv = env
  0

proc bl_rx_sm_disconnect_ind_cb_unregister*(env: pointer; cb: DisconnectCb): cint {.exportc, cdecl.} =
  cbSmDisconnect = nil
  cbSmDisconnectEnv = nil
  0
