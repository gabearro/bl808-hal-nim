proc wifi_mgmr_sta_enable*(): WifiInterface {.importc, cdecl.}
  ## Enable STA mode. Returns interface handle.

proc wifi_mgmr_sta_connect*(iface: ptr WifiInterface,
                            ssid: cstring, psk: cstring, pmk: cstring,
                            mac: ptr uint8, band: uint8, chan_id: uint8): cint
  {.importc, cdecl.}

proc wifi_mgmr_sta_disconnect*(): cint {.importc, cdecl.}

proc wifi_mgmr_sta_connect_abort*(): cint {.importc, cdecl.}

proc wifi_mgmr_scan*(iface: ptr WifiInterface, cb: pointer): cint
  {.importc, cdecl.}

proc wifi_mgmr_ap_start*(iface: ptr WifiInterface,
                         ssid: cstring, hiddenSsid: cint,
                         passwd: cstring, channel: cint): cint
  {.importc, cdecl.}

proc wifi_mgmr_ap_stop*(iface: ptr WifiInterface): cint
  {.importc, cdecl.}

proc wifi_mgmr_sta_netif_get*(): pointer {.importc, cdecl.}
  ## Returns struct netif* (lwIP network interface for STA).
