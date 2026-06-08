proc bl_rx_beacon_ind_cb_register*(env: pointer; cb: BeaconCb): cint {.exportc, cdecl.} =
  cbBeacon = cb
  cbBeaconEnv = env
  0

proc bl_rx_beacon_ind_cb_unregister*(env: pointer; cb: BeaconCb): cint {.exportc, cdecl.} =
  cbBeacon = nil
  cbBeaconEnv = nil
  0

proc bl_rx_probe_resp_ind_cb_register*(env: pointer; cb: ProbeRespCb): cint {.exportc, cdecl.} =
  cbProbeResp = cb
  cbProbeRespEnv = env
  0

proc bl_rx_probe_resp_ind_cb_unregister*(env: pointer; cb: ProbeRespCb): cint {.exportc, cdecl.} =
  cbProbeResp = nil
  cbProbeRespEnv = nil
  0
