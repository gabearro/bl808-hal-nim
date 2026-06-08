proc bl606a0_wifi_init*(conf: ptr WifiConfC): cint {.exportc, cdecl.} =
  trace("wifi init")
  var mac: array[6, uint8]
  discard bl_wifi_mac_addr_get(addr mac[0])
  setHostname(addr mac[0])

  if conf != nil:
    bl_msg_update_channel_cfg(cast[cstring](addr conf.country_code[0]))
    wifiMgmr.country_code[0] = conf.country_code[0]
    wifiMgmr.country_code[1] = conf.country_code[1]
  else:
    bl_msg_update_channel_cfg("US")
    wifiMgmr.country_code[0] = 'U'.cchar
    wifiMgmr.country_code[1] = 'S'.cchar
  wifiMgmr.country_code[2] = 0.cchar

  discard bl_wifi_clock_enable()
  bl606a0StaHw = nil
  result = bl_main_rtthread_start(addr bl606a0StaHw)
  wifiMgmr.channel_nums = bl_msg_get_channel_nums()
