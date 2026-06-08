proc netifStatusCallback(netif: ptr Netif) {.cdecl.} =
  if netif == nil or netif.ip_addr.addr32 == 0'u32:
    trace("status ip update")
    discard wifi_mgmr_api_ip_update()
  else:
    trace("status ip got")
    discard wifi_mgmr_api_ip_got()

proc bl606a0_wifi_netif_init*(netif: ptr Netif): ErrT {.exportc, cdecl.} =
  trace("netif init")
  if netif == nil:
    return ErrIf
  netif.hostname = cast[cstring](addr wifiMgmr.hostname[0])
  netif.hwaddr_len = EtharpHwaddrLen
  netif.mtu = 1500'u16
  netif.flags = NetifFlagBroadcast or NetifFlagEtharp or NetifFlagIgmp
  netif.output = etharp_output
  netif.linkoutput = wifiTx
  netif_set_status_callback(netif, netifStatusCallback)
  ErrOk
