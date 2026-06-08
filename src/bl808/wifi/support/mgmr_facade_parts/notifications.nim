proc wifi_mgmr_api_ip_update*(): cint {.exportc, cdecl.} = 0
proc wifi_mgmr_api_ip_got*(): cint {.exportc, cdecl.} = 0
proc wifi_mgmr_ext_dump_needed*(): cint {.exportc, cdecl.} = 0

proc wifi_mgmr_scan_complete_notify*(): cint {.exportc, cdecl.} =
  inc scanDoneCount
  vendorPutsRaw("[WIFI] scan complete notify\r\n")
  0

proc wifi_netif_dhcp_start*(netif: ptr Netif): cint {.exportc, cdecl.} =
  discard netif
  0

proc wifi_netif_dhcp_stop*(netif: ptr Netif): cint {.exportc, cdecl.} =
  discard netif
  0
