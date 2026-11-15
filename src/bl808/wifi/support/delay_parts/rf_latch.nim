proc nim_wifi_rf_latch_service_enable*(enable: uint32) {.exportc, cdecl.} =
  ## Legacy diagnostic ABI. Delay hooks do not modify RF calibration status.
  nimWifiDbgRfLatchServiceEnabled = enable
