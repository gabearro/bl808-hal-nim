proc bl_main_if_remove*(vifIndex: uint8): cint {.exportc, cdecl.} =
  if vifIndex.uint >= NxVirtDevMax:
    return -1
  let vif = vifAt(vifIndex.uint)
  discard bl_send_remove_if(hwPtr(), loadU8(vif, BlVifVifIdxOff))
  zero(vif, BlVifSize.int)
  0

proc bl_main_raw_send*(pkt: ptr uint8; len: cint): cint {.exportc, cdecl.} =
  bl_send_scanu_raw_send(hwPtr(), pkt, len)

proc bl_main_if_add*(isSta: cint; netif: ptr Netif; vifIndex: ptr uint8): cint
    {.exportc, cdecl.} =
  if netif == nil or vifIndex == nil:
    return -1
  var cfm: array[SizeMmAddIfCfm, uint8]
  zero(addr cfm[0], cfm.len)
  result = bl_send_add_if(hwPtr(), netifHwaddr(netif),
                          if isSta != 0: Nl80211IftypeStation else: Nl80211IftypeAp,
                          false, cast[ptr MmAddIfCfm](addr cfm[0]))
  if result != 0:
    return result
  if loadU8(addr cfm[0], AddIfStatusOff) != CoOk:
    return -Eio

  let vifId = if isSta != 0: BlVifSta else: BlVifAp
  let vif = vifAt(vifId)
  storeU8(vif, BlVifVifIdxOff, loadU8(addr cfm[0], AddIfInstNbrOff))
  storePtr(vif, BlVifDevOff, cast[pointer](netif))
  storeU8(vif, BlVifUpOff, 1'u8)
  storeU8(vif, BlVifLinksNumOff, 0'u8)
  vifIndex[] = vifId.uint8
