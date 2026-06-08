proc wifi_mgmr_scan*(data: pointer; cb: ScanCompleteCb): cint {.exportc, cdecl.} =
  discard data
  if cb != nil: discard
  if not staEnabled: return -1
  var bssid: array[6, uint8]
  for i in 0 ..< 6: bssid[i] = 0xff
  scanDoneCount = 0
  scanItemCount = 0
  scanDiagReset()
  result = bl_main_scan(cast[ptr Netif](ifaceNetif(staIface())), nil, 0, cast[ptr MacAddr](addr bssid[0]), nil, ScanActive, 120000)
  vendorPutsRaw("[WIFI] scan start rc=")
  if result < 0:
    vendorPutsRaw("-")
    vendorPrintU32(uint32(-result), 10)
  else:
    vendorPrintU32(result.uint32, 10)
  vendorPutsRaw("\r\n")

proc wifi_mgmr_sta_connect*(iface: ptr pointer; ssid, psk, pmk: cstring; mac: ptr uint8;
                            band: uint8; chanId: uint8): cint {.exportc, cdecl.} =
  discard iface
  if not staEnabled or ssid == nil: return -1
  let ssidLen = c_strlen(ssid)
  let pskLen = if psk != nil: c_strlen(psk) else: 0.csize_t
  let pmkLen = if pmk != nil: c_strlen(pmk) else: 0.csize_t
  let freq = wifiChannelToFreq(chanId)
  connectDone = -1
  lastStatusCode = -1
  disconnectDone = 0
  const flags = WifiConnectDefault or WifiConnectPmfCapable
  result = bl_main_connect(cast[ptr uint8](ssid), ssidLen.cint,
                           cast[ptr uint8](psk), pskLen.cint,
                           cast[ptr uint8](pmk), pmkLen.cint,
                           nil, 0, freq, flags)
  discard mac
  discard band

proc wifi_mgmr_sta_disconnect*(): cint {.exportc, cdecl.} =
  if not staEnabled: return -1
  result = bl_main_disconnect()
  vendorPollFor(4000)
