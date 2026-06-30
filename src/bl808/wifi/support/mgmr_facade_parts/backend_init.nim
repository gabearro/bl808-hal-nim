proc bl808_wifi_backend_init*(conf: ptr WifiConf): cint {.exportc, cdecl.} =
  var local: array[8, uint8]
  if wifiStarted: return 0
  bl808WifiBackendTrace("backend_init setup_bl_ops")
  setupBlOps()
  bl808WifiBackendTrace("backend_init setup_hosal")
  setupHosal()
  bl808WifiBackendTrace("backend_init zero_mgmr")
  zero(mgmrRaw(), sizeof(WifiMgmr).uint)
  bl808WifiBackendTrace("backend_init country")
  zero(addr local[0], local.len.uint)
  local[0] = 'U'.uint8
  local[1] = 'S'.uint8
  if conf != nil and loadU8(conf, WifiConfCountryOff) != 0:
    local[0] = loadU8(conf, WifiConfCountryOff)
    local[1] = if loadU8(conf, WifiConfCountryOff + 1) != 0: loadU8(conf, WifiConfCountryOff + 1) else: 'S'.uint8
  bl808WifiBackendTrace("backend_init fw_start")
  bl808WifiBackendFwStart()
  bl808WifiBackendTrace("backend_init bl606a0_wifi_init")
  hostPollEnabled = true
  result = bl606a0_wifi_init(cast[ptr WifiConf](addr local[0]))
  if result == 0:
    bl808WifiBackendTrace("backend_init phy_up")
    let phy = bl_main_phy_up()
    if phy != 0: result = phy
    vendorPollFor(2000)
  bl808WifiBackendTrace("backend_init mgmr_finalize")
  wifiStarted = result == 0
  storeU8(mgmrRaw(), MgmrReadyOff, 1)
  storeU16(mgmrRaw(), MgmrApBcnIntOff, 100)
  storeI32(mgmrRaw(), MgmrApInfoTtlOff, -1)
  storeI32(mgmrRaw(), MgmrScanItemTimeoutOff, WifiMgmrConfigScanItemTimeout)
  storePtr(mgmrRaw(), MgmrScanItemsLockOff, osMutexCreate())
  let stat = ptrAt(mgmrRaw(), MgmrStatInfoOff)
  storePtr(stat, StatDiagnoseLockOff, osMutexCreate())
  storePtr(stat, StatDiagnoseGetLockOff, osMutexCreate())
  discard bl_rx_sm_connect_ind_cb_register(nil, connectCb)
  discard bl_rx_sm_disconnect_ind_cb_register(nil, disconnectCb)
  discard bl_rx_beacon_ind_cb_register(nil, beaconCb)
  discard bl_rx_event_register(nil, eventCb)
