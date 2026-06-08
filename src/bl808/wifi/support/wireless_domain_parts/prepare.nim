proc bl808WifiBackendPrepareWirelessDomain() =
  var prepared {.global.}: bool
  if prepared:
    bl808WifiBackendEnableWirelessClocks()
    return
  regUpdate32(GlbBase + 0x60c'u32, 0xff, 0)
  bl808WifiBackendPowerOnXtalWifiPll()
  bl808WifiBackendConfigureDigClock()
  bl808WifiBackendEnableWirelessClocks()
  # Vendor WiFi bring-up resets only the WiFi wireless block here. The BLE
  # helper also resets BTDM/BLE2, but doing that in WiFi init can disturb the
  # shared RF latch state before RF/PHY calibration.
  bl808WifiBackendSwResetCfg0(4)
  bl808WifiBackendConfigureDigClock()
  bl808WifiBackendEnableWirelessClocks()
  prepared = true
