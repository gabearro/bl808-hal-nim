proc wifi_mgmr_sta_enable*(): pointer {.exportc, cdecl.} =
  if not wifiStarted: return nil
  if staEnabled: return staIface()
  let iface = staIface()
  let nif = ifaceNetif(iface)
  var zeroIp: uint32
  var mac: array[6, uint8]
  storeI32(iface, WifiIfaceModeOff, 0)
  discard bl_wifi_mac_addr_get(addr mac[0])
  copyMem(ptrAt(iface, WifiIfaceMacOff), addr mac[0], 6)
  when not defined(bl808WifiRealLwip):
    copyMem(ptrAt(nif, NetifHwaddrOff), addr mac[0], 6)
  discard netifapi_netif_add(cast[ptr Netif](nif), cast[ptr Ip4Addr](addr zeroIp), cast[ptr Ip4Addr](addr zeroIp), cast[ptr Ip4Addr](addr zeroIp),
                             nil, bl606a0_wifi_netif_init, tcpip_input)
  when defined(bl808WifiRealLwip):
    copyMem(netifHwaddr(nif), addr mac[0], 6)
    realNetifSetName(cast[ptr Netif](nif), 's', 't')
  else:
    storeU8(nif, NetifNameOff, 's'.uint8)
    storeU8(nif, NetifNameOff + 1, 't'.uint8)
  netif_set_default(cast[ptr Netif](nif))
  netif_set_up(cast[ptr Netif](nif))
  var addIfCfm: array[MmAddIfCfmSize.int, uint8]
  for _ in 0 ..< 20:
    zero(addr addIfCfm[0], MmAddIfCfmSize)
    let addIfRequestStatus =
      bl_send_add_if(cast[ptr BlHw](addr wifi_hw), netifHwaddr(nif),
                     Nl80211IftypeStation, false, addr addIfCfm[0])
    let addIfConfirmStatus = loadU8(addr addIfCfm[0], MmAddIfStatusOff)
    if addIfRequestStatus == 0 and addIfConfirmStatus == CoOk.uint8:
      let vif = vifAt(BlVifSta)
      let inst = loadU8(addr addIfCfm[0], MmAddIfInstNbrOff)
      storeU8(vif, BlVifVifIdxOff, inst)
      storePtr(vif, BlVifDevOff, nif)
      storeU8(vif, BlVifUpOff, 1)
      storeU8(vif, BlVifLinksNumOff, 0)
      storeU8(iface, WifiIfaceVifIndexOff, BlVifSta.uint8)
      staEnabled = true
      vendorPollFor(2000)
      return iface
    vendorPollFor(4000)
  nil

proc wifi_mgmr_sta_netif_get*(): ptr Netif {.exportc, cdecl.} =
  cast[ptr Netif](ifaceNetif(staIface()))

proc wifi_mgmr_ap_netif_get*(): ptr Netif {.exportc, cdecl.} =
  cast[ptr Netif](ifaceNetif(apIface()))
