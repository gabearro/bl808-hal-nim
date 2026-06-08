proc c_memset(s: pointer; c: cint; n: csize_t): pointer
  {.importc: "memset", header: "<string.h>", cdecl.}
proc c_memcpy(dest, src: pointer; n: csize_t): pointer
  {.importc: "memcpy", header: "<string.h>", cdecl.}
proc bl_os_printf(fmt: cstring)
  {.importc, header: "bl_os_private.h", cdecl, varargs.}
proc bl_os_log_info(fmt: cstring)
  {.importc, header: "bl_os_private.h", cdecl, varargs.}
proc netifapi_netif_set_link_up(netif: ptr Netif)
  {.importc, header: "<lwip/netifapi.h>", cdecl.}
proc netifapi_netif_set_link_down(netif: ptr Netif)
  {.importc, header: "<lwip/netifapi.h>", cdecl.}
proc netifapi_netif_set_addr(netif: ptr Netif; ipaddr, netmask, gw: pointer): cint
  {.importc, header: "<lwip/netifapi.h>", cdecl.}
proc aos_post_event(`type`, code, value: cint): cint
  {.importc, header: "<aos/yloop.h>", cdecl.}
proc bl_tx_cntrl_link_up(sta: ptr BlSta) {.importc, cdecl, header: "bl_tx.h".}
proc bl_tx_cntrl_link_down(sta: ptr BlSta) {.importc, cdecl, header: "bl_tx.h".}
proc mac_vsie_find(baseAddr: uint32; buflen: uint16; oui: pointer; ouilen: uint8): uint32
  {.importc, cdecl, header: "bl60x_fw_api.h".}
proc mac_ie_find(baseAddr: uint32; buflen: uint16; ieId: uint8): uint32
  {.importc, cdecl, header: "bl60x_fw_api.h".}
proc wpa_parse_wpa_ie_wrapper(wpaIe: pointer; wpaIeLen: csize_t; data: ptr WifiWpaIe): cint
  {.importc, cdecl.}
