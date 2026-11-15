proc blRxSmDisconnectInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  let callback = snapshotCallback(cbSmDisconnect)
  inc nimFwDbgRxSmDisc
  var indNew: array[WifiDiscEventSize.int, uint8]
  var transition: StationRxTransition
  var addrAny: uint32
  block:
    let saved = callbackIrqSave()
    defer: callbackIrqRestore(saved)
    if blHw == nil or msg == nil: return -1
    let vif = vifAt(blHw, BlVifSta)
    if loadU8(vif, BlVifLinksNumOff) == 0: return -1
    let station = loadU8(vif, BlVifFixedStaIdxOff)
    if station >= NxRemoteStaStoreMax: return -1
    transition = beginStationRxTransition(blHw, station)
    if not transition.valid: return -1
    let ind = msgParam(msg)
    zero(addr indNew[0], indNew.len.uint)
    storeU16(addr indNew[0], WifiDiscStatusOff, loadU16(ind, SmDiscStatusOff))
    storeU16(addr indNew[0], WifiDiscReasonOff, loadU16(ind, SmDiscReasonOff))
    storeU8(addr indNew[0], WifiDiscVifOff, BlVifSta.uint8)
    storeI32(addr indNew[0], WifiDiscFtOverDsOff, loadU8(ind, SmDiscFtOverDsOff).int32)
    copyMem(ptrAt(addr indNew[0], WifiDiscDiagnoseOff), ptrAt(ind, SmDiscDiagnoseOff), DiagnoseSize)
    inc nimFwDbgRxSmSeq
    nimFwDbgRxSmDiscSeq = nimFwDbgRxSmSeq
    nimFwDbgRxSmDiscMeta = loadU16(ind, SmDiscStatusOff).uint32 or
      (loadU16(ind, SmDiscReasonOff).uint32 shl 16)
    nimFwDbgRxSmDiscVif = loadU8(vif, BlVifLinksNumOff).uint32 or
      (transition.fixedStation.uint32 shl 8) or
      (loadU8(vif, BlVifFcChanOff).uint32 shl 16) or
      (loadU8(vif, BlVifStaPsOff).uint32 shl 24)
    let discSta = staAt(blHw, transition.fixedStation.uint)
    nimFwDbgRxSmDiscSta = loadU8(discSta, BlStaIsUsedOff).uint32 or
      (loadU8(discSta, BlStaStaIdxOff).uint32 shl 8) or
      (loadU8(discSta, BlStaVifIdxOff).uint32 shl 16) or
      (loadU8(discSta, BlStaQosOff).uint32 shl 24)

  let event = addr indNew[0]
  bl_os_printf("[RX]   sm_disconnect_ind\r\n       status_code %u\r\n       802.11 reason_code %u\r\n",
               loadU16(event, WifiDiscStatusOff).cuint, loadU16(event, WifiDiscReasonOff).cuint)
  bl_os_printf("[RX]   disconnect reason: %s\r\n", smStatusStr(loadU16(event, WifiDiscStatusOff)))
  bl_os_printf("[RX]   vif_idx %u\r\n", BlVifSta.cuint)
  bl_os_printf("[RX]   ft_over_ds %u\r\n", loadU32(event, WifiDiscFtOverDsOff).cuint)
  bl_os_printf("[RX]   tlv_ptr first %p\r\n", loadPtr(event, WifiDiscDiagnoseOff))
  block:
    let saved = callbackIrqSave()
    defer: callbackIrqRestore(saved)
    if not stationRxTransitionCurrent(transition): return 0
    let vif = vifAt(blHw, BlVifSta)
    let sta = staAt(blHw, transition.fixedStation.uint)
    if loadU8(sta, BlStaIsUsedOff) != 0:
      storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) - 1)
      storeU8(vif, BlVifFcChanOff, 0)
      storeU8(vif, BlVifStaPsOff, PsModeOff)
      storeU8(sta, BlStaIsUsedOff, 0)
      bl_tx_cntrl_link_down(cast[ptr BlSta](sta))
  var notify: bool
  block:
    let saved = callbackIrqSave()
    defer: callbackIrqRestore(saved)
    if not stationRxTransitionCurrent(transition): return 0
    notify = claimCallback(cbSmDisconnect, callback)
  if notify:
    callback.handler(callback.context, cast[ptr WifiEventSmDisconnect](addr indNew[0]))
  if stationRxNetifCurrent(transition):
    netifapi_netif_set_link_down(cast[ptr Netif](transition.netif))
  if stationRxNetifCurrent(transition):
    addrAny = 0
    discard netifapi_netif_set_addr(cast[ptr Netif](transition.netif), addr addrAny, addr addrAny, addr addrAny)
  0
