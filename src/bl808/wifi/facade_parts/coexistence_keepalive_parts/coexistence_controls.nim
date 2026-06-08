proc wifiSetBleCoexistenceMode*(mode: uint32) =
  ## Configure WiFi/BLE PTA priority while STA WiFi remains active.
  ## Use wifiBleCoexWifiPriority when WiFi must actively transmit during BLE
  ## activity; use wifiBleCoexBtPriority for BLE-preferred windows.
  wifiNimFirmwareSetBleCoexMode(mode)

proc wifiReclaimStaTxChannel*() =
  ## Restore the STA TX RF/channel programming after another radio user, such
  ## as BLE, has borrowed the shared RF path.
  wifiNimFirmwareReclaimStaTxChannel()
