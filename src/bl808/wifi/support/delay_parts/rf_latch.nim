const
  WifiRfTxPowerReg = 0x200010B4'u32
  WifiRfTxcalLatchMask = 0x01100000'u32

proc serviceWifiRfCalibrationLatch() =
  ## The BL808 RF archive calls udelay while polling TXCAL latch bits.  BLE's
  ## reference-equivalent delay hook clears those same live latches; mirror it
  ## only during WiFi RF bring-up so stale latch state cannot wedge cold init.
  when defined(bl808WifiUseBl808Rf):
    if nimWifiDbgRfLatchServiceEnabled == 0'u32:
      return
    var txcal = regRead32(WifiRfTxPowerReg)
    nimWifiDbgRfTxcalBefore = txcal
    if (txcal and WifiRfTxcalLatchMask) != 0'u32:
      inc nimWifiDbgRfTxcalLatchCount
      txcal = txcal and not WifiRfTxcalLatchMask
      regWrite32(WifiRfTxPowerReg, txcal)
    nimWifiDbgRfTxcalAfter = regRead32(WifiRfTxPowerReg)

proc nim_wifi_rf_latch_service_enable*(enable: uint32) {.exportc, cdecl.} =
  nimWifiDbgRfLatchServiceEnabled = enable
