proc scanDiagReset() = zero(addr scanDiag[0], sizeof(scanDiag).uint)

proc scanDiagStore(ind: pointer) =
  if ind == nil: return
  let len = loadI32(ind, WifiBeaconSsidLenOff)
  if len < 0 or len > 32: return
  let slot = (scanItemCount mod VendorScanDiagMax.uint32).int
  zero(addr scanDiag[slot], sizeof(ScanDiagItem).uint)
  scanDiag[slot].used = 1
  scanDiag[slot].ssidLen = len.uint8
  if len > 0:
    copyMem(addr scanDiag[slot].ssid[0], ptrAt(ind, WifiBeaconSsidOff), len.uint)
  copyMem(addr scanDiag[slot].bssid[0], ptrAt(ind, WifiBeaconBssidOff), 6)
  scanDiag[slot].channel = loadU8(ind, WifiBeaconChannelOff)
  scanDiag[slot].rssi = loadI8(ind, WifiBeaconRssiOff)
  scanDiag[slot].auth = loadU8(ind, WifiBeaconAuthOff)
  scanDiag[slot].cipher = loadU8(ind, WifiBeaconCipherOff)

proc bl808_wifi_backend_scan_diag_count*(): uint32 {.exportc, cdecl.} =
  if scanItemCount < VendorScanDiagMax.uint32: scanItemCount else: VendorScanDiagMax.uint32

proc bl808_wifi_backend_scan_diag_get*(index: uint32; ssidLen, ssid, channel: pointer;
                                      rssi, auth, cipher, bssid: pointer): cint {.exportc, cdecl.} =
  if index >= bl808_wifi_backend_scan_diag_count(): return -1
  let start = if scanItemCount > VendorScanDiagMax.uint32: scanItemCount mod VendorScanDiagMax.uint32 else: 0'u32
  let slot = ((start + index) mod VendorScanDiagMax.uint32).int
  if scanDiag[slot].used == 0: return -1
  if ssidLen != nil: cast[ptr uint8](ssidLen)[] = scanDiag[slot].ssidLen
  if ssid != nil: copyMem(ssid, addr scanDiag[slot].ssid[0], scanDiag[slot].ssid.len.uint)
  if channel != nil: cast[ptr uint8](channel)[] = scanDiag[slot].channel
  if rssi != nil: cast[ptr int8](rssi)[] = scanDiag[slot].rssi
  if auth != nil: cast[ptr uint8](auth)[] = scanDiag[slot].auth
  if cipher != nil: cast[ptr uint8](cipher)[] = scanDiag[slot].cipher
  if bssid != nil: copyMem(bssid, addr scanDiag[slot].bssid[0], scanDiag[slot].bssid.len.uint)
  0

proc wifiChannelToFreq(channel: uint8): uint16 =
  if channel >= 1 and channel <= 13: uint16(2407 + channel.uint16 * 5)
  elif channel == 14: 2484'u16
  else: 0'u16
