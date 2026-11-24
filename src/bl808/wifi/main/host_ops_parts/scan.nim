proc bl_main_scan*(netif: ptr Netif; fixedChannels: ptr uint16; channelNum: uint16;
                   bssid: ptr MacAddr; ssid: ptr MacSsid; scanMode: uint8;
                   durationScan: uint32): cint {.exportc, cdecl.} =
  if netif == nil:
    return -1
  if channelNum != 0 and bl_get_fixed_channels_is_valid(fixedChannels, channelNum) == 0:
    return -22 # EINVAL
  var scanu: array[SizeScanuPara, uint8]
  zero(addr scanu[0], scanu.len)
  if channelNum != 0:
    storePtr(addr scanu[0], ScanChannelsOff, cast[pointer](fixedChannels))
  storeU16(addr scanu[0], ScanChannelNumOff, channelNum)
  storePtr(addr scanu[0], ScanBssidOff, cast[pointer](bssid))
  storePtr(addr scanu[0], ScanSsidOff, cast[pointer](ssid))
  storePtr(addr scanu[0], ScanMacOff, cast[pointer](netifHwaddr(netif)))
  storeU8(addr scanu[0], ScanModeOff, scanMode)
  storeU32(addr scanu[0], ScanDurationOff, durationScan)

  bl_send_scanu_req(hwPtr(), cast[ptr ScanuPara](addr scanu[0]))
