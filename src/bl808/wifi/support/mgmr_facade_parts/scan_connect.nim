proc wifi_mgmr_prepare_join_after_scan(): cint =
  wifi_mgmr_recover_terminal_connect_failure(true)

proc wifi_mgmr_scan*(data: pointer; cb: ScanCompleteCb): cint {.exportc, cdecl.} =
  discard data
  if cb != nil: discard
  if not staEnabled: return -1
  if not beginStationControl(): return -16
  defer: endStationControl()
  result = wifi_mgmr_recover_terminal_connect_failure()
  if result != 0: return
  var broadcastBssid: array[6, uint8]
  for bssidByteIndex in 0 ..< broadcastBssid.len:
    broadcastBssid[bssidByteIndex] = 0xff
  scanDoneCount = 0
  scanItemCount = 0
  scanDiagReset()
  when defined(bl808WifiConnectCacheHint):
    scanCacheReset()
  result = bl_main_scan(cast[ptr Netif](ifaceNetif(staIface())), nil, 0,
                        cast[ptr MacAddr](addr broadcastBssid[0]), nil,
                        ScanActive, 0)
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
  if not beginStationControl(): return -16
  defer: endStationControl()
  nimfwDbgStaConnectStage = 1
  nimfwDbgStaConnectResult = 0xFFFF_FFFF'u32
  nimfwDbgStaConnectState = sm_state.uint32
  vendorPutsRaw("[WIFI] sta_connect enter\r\n")
  nimfwDbgStaConnectStage = 2
  result = wifi_mgmr_prepare_join_after_scan()
  if result != 0:
    vendorPutsRaw("[WIFI] sta_connect prepare fail\r\n")
    nimfwDbgStaConnectStage = 3
    nimfwDbgStaConnectState = sm_state.uint32
    nimfwDbgStaConnectResult = cast[uint32](result)
    return
  vendorPutsRaw("[WIFI] sta_connect prepare ok\r\n")
  nimfwDbgStaConnectStage = 4
  nimfwDbgStaConnectState = sm_state.uint32
  let ssidLen = c_strlen(ssid)
  let pskLen = if psk != nil: c_strlen(psk) else: 0.csize_t
  let pmkLen = if pmk != nil: c_strlen(pmk) else: 0.csize_t
  var freq = wifiChannelToFreq(chanId)
  nimfwDbgStaConnectFreq = freq.uint32 or (chanId.uint32 shl 16)
  var connectBssid: ptr uint8 = nil
  when defined(bl808WifiConnectCacheHint):
    var selectedBssid: array[6, uint8]
    var selectedChannel = 0'u8
    var selectedRssi = -128'i8
    connectBssid = if scannedBssidIsSpecific(mac): mac else: nil
    if scanCacheFind(ssid, ssidLen, mac, chanId, addr selectedBssid,
                     addr selectedChannel, addr selectedRssi):
      vendorPutsRaw("[WIFI] sta_connect cache hit\r\n")
      # Pin the join to the cache-selected BSSID. Letting the SM perform a
      # second SSID-only selection can make VIF/BSSID state diverge from the
      # auth frame target across retries when multiple APs share the SSID.
      connectBssid = addr selectedBssid[0]
      if freq == 0'u16:
        freq = wifiChannelToFreq(selectedChannel)
      nimfwDbgStaConnectFreq = freq.uint32 or (selectedChannel.uint32 shl 16)
    else:
      vendorPutsRaw("[WIFI] sta_connect cache miss\r\n")
  connectDone = -1
  lastStatusCode = -1
  disconnectDone = 0
  const flags = WifiConnectDefault or WifiConnectPmfCapable
  vendorPutsRaw("[WIFI] sta_connect dispatch\r\n")
  nimfwDbgStaConnectStage = 5
  if connectBssid != nil:
    nimfwDbgStaConnectBssidLo = loadU32(cast[pointer](connectBssid), 0)
    nimfwDbgStaConnectBssidHi = loadU16(cast[pointer](connectBssid), 4).uint32
  else:
    nimfwDbgStaConnectBssidLo = 0
    nimfwDbgStaConnectBssidHi = 0
  result = bl_main_connect(cast[ptr uint8](ssid), ssidLen.cint,
                           cast[ptr uint8](psk), pskLen.cint,
                           cast[ptr uint8](pmk), pmkLen.cint,
                           connectBssid, band, freq, flags)
  if result != 0 and connectDone < 0:
    connectDone = 8
    lastStatusCode = 8
    lastReasonCode = -1
  nimfwDbgStaConnectStage = 6
  nimfwDbgStaConnectResult = cast[uint32](result)
  nimfwDbgStaConnectState = sm_state.uint32
  vendorPutsRaw("[WIFI] sta_connect dispatched\r\n")
  discard mac

proc wifi_mgmr_sta_disconnect*(): cint {.exportc, cdecl.} =
  if not staEnabled: return -1
  if not beginStationControl(): return -16
  defer: endStationControl()
  disconnectDone = 0
  result = bl_main_disconnect()

proc wifi_mgmr_sta_connect_abort*(): cint {.exportc, cdecl.} =
  if not staEnabled: return -1
  if not beginStationControl(): return -16
  defer: endStationControl()
  disconnectDone = 0
  var status: uint8
  result = bl_main_connect_abort(addr status)
