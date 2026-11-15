proc bl_rx_beacon_ind_cb_register*(env: pointer; cb: BeaconCb): cint {.exportc, cdecl.} =
  setCallback(cbBeacon, cb, env)
  0

proc bl_rx_beacon_ind_cb_unregister*(env: pointer; cb: BeaconCb): cint {.exportc, cdecl.} =
  clearCallback(cbBeacon)
  0

proc bl_rx_probe_resp_ind_cb_register*(env: pointer; cb: ProbeRespCb): cint {.exportc, cdecl.} =
  setCallback(cbProbeResp, cb, env)
  0

proc bl_rx_probe_resp_ind_cb_unregister*(env: pointer; cb: ProbeRespCb): cint {.exportc, cdecl.} =
  clearCallback(cbProbeResp)
  0
