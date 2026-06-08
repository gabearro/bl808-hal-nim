proc etharp_output(netif: ptr Netif; p: ptr Pbuf; ipaddr: ptr Ip4Addr): ErrT
  {.importc, cdecl, header: "<netif/etharp.h>".}
proc netif_set_status_callback(netif: ptr Netif; cb: NetifStatusCallbackFn)
  {.importc, cdecl, header: "<lwip/netif.h>".}
proc bl_output(blHw: pointer; isSta: cint; p: ptr Pbuf; customCfm: ptr BlTxCfm): ErrT
  {.importc, cdecl, header: "bl_tx.h".}
proc bl_main_rtthread_start(blHw: ptr pointer): cint
  {.importc, cdecl, header: "bl_main.h".}
proc bl_msg_update_channel_cfg(countryCode: cstring)
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_msg_get_channel_nums(): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_wifi_clock_enable(): cint {.importc, cdecl.}
proc bl_wifi_mac_addr_get(mac: ptr uint8): cint {.importc, cdecl.}
proc arch_delay_us(us: uint32) {.importc, cdecl.}
proc wifi_mgmr_sta_netif_get(): ptr Netif {.importc, cdecl.}
proc wifi_mgmr_api_ip_update(): cint {.importc, cdecl.}
proc wifi_mgmr_api_ip_got(): cint {.importc, cdecl.}

when defined(bl808WifiNimDriverTrace):
  proc c_printf(fmt: cstring): cint
    {.importc: "printf", header: "<stdio.h>", cdecl, varargs, discardable.}
