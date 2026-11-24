proc wifiApReleaseInterface(): cint =
  let iface = apIface()
  result = bl_main_if_remove(BlVifAp.uint8)
  if result == 0:
    apRegistered = false
    wifiRemoveApNetif(cast[ptr Netif](ifaceNetif(iface)))

proc wifiApRegisterInterface(): cint =
  let iface = apIface()
  let netif = cast[ptr Netif](ifaceNetif(iface))
  var ip = 0x010BA8C0'u32 # 192.168.11.1 (pinned manager's default)
  var mask = 0x00FFFFFF'u32
  var gateway = 0'u32
  let address = cast[ptr Ip4Addr](addr ip)
  let netmask = cast[ptr Ip4Addr](addr mask)
  let gw = cast[ptr Ip4Addr](addr gateway)
  if netifapi_netif_add(netif, address, netmask, gw, nil,
                       bl606a0_wifi_netif_init, tcpip_input) != 0:
    return -1
  var mac: array[6, uint8]
  copyMem(addr mac[0], netifHwaddr(ifaceNetif(staIface())), 6)
  mac[5] = mac[5] xor 1'u8 # The shared BL808 MAC mask permits this bit.
  copyMem(netifHwaddr(netif), addr mac[0], 6)
  copyMem(ptrAt(iface, WifiIfaceMacOff), addr mac[0], 6)
  when defined(bl808WifiRealLwip):
    realNetifSetName(netif, 'a', 'p')
  else:
    storeU8(netif, NetifNameOff, 'a'.uint8)
    storeU8(netif, NetifNameOff + 1, 'p'.uint8)
    discard netifapi_netif_set_addr(netif, address, netmask, gw)
  var index: uint8
  result = bl_main_if_add(0, netif, addr index)
  if result != 0:
    wifiRemoveApNetif(netif)
    return
  storeI32(iface, WifiIfaceModeOff, 1)
  storeU8(iface, WifiIfaceVifIndexOff, index)
  apRegistered = true

proc wifi_mgmr_ap_start*(iface: ptr pointer; ssid: cstring; hiddenSsid: cint; passwd: cstring; channel: cint): cint {.exportc, cdecl.} =
  discard iface
  if not staEnabled or ssid == nil or channel <= 0 or
      channel > bl_msg_get_channel_nums(): return -1
  if not beginStationControl(): return -16
  defer: endStationControl()
  if apEnabled: return -16
  if apRegistered:
    result = wifiApReleaseInterface()
    if result != 0: return
  result = wifiApRegisterInterface()
  if result != 0: return
  result = bl_main_apm_start(ssid, passwd, channel, hiddenSsid.uint8, loadU16(mgmrRaw(), MgmrApBcnIntOff))
  if result != 0:
    discard wifiApReleaseInterface()
    return
  apEnabled = true
  let netif = cast[ptr Netif](ifaceNetif(apIface()))
  netif_set_up(netif)
  netif_set_link_up(netif)

proc wifi_mgmr_ap_stop*(iface: ptr pointer): cint {.exportc, cdecl.} =
  discard iface
  if not apRegistered: return -1
  if not beginStationControl(): return -16
  defer: endStationControl()
  if apEnabled:
    result = bl_main_apm_stop()
    if result != 0: return
    apEnabled = false
    netif_set_link_down(cast[ptr Netif](ifaceNetif(apIface())))
  return wifiApReleaseInterface()
