proc blRxSmConnectInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  let callback = snapshotCallback(cbSmConnect)
  var indNew: array[WifiConnEventSize.int, uint8]
  var transition: StationRxTransition
  var status, assocReqLen, assocRspLen: uint16
  var acm: uint8
  block:
    let saved = callbackIrqSave()
    defer: callbackIrqRestore(saved)
    if blHw == nil or msg == nil:
      return -1
    let vif = vifAt(blHw, BlVifSta)
    let ind = msgParam(msg)
    if not firmware.rxHostClaimStationIndication(ind, loadU8(vif, BlVifVifIdxOff)):
      return 0
    let station = if loadU8(vif, BlVifLinksNumOff) != 0:
                    loadU8(vif, BlVifFixedStaIdxOff) else: 0xFF'u8
    if loadU8(vif, BlVifLinksNumOff) != 0 and station >= NxRemoteStaMax:
      return -1
    transition = beginStationRxTransition(blHw, station)
    if not transition.valid:
      return -1
    status = loadU16(ind, SmConnStatusOff)
    assocReqLen = loadU16(ind, SmConnAssocReqLenOff)
    assocRspLen = loadU16(ind, SmConnAssocRspLenOff)
    acm = loadU8(ind, SmConnAcmOff)
    zero(addr indNew[0], indNew.len.uint)
    storeU16(addr indNew[0], WifiConnStatusOff, status)
    storeU16(addr indNew[0], WifiConnReasonOff, loadU16(ind, SmConnReasonOff))
    copyMem(ptrAt(addr indNew[0], WifiConnBssidOff), ptrAt(ind, SmConnBssidOff), 6)
    storeU8(addr indNew[0], WifiConnVifOff, BlVifSta.uint8)
    storeU8(addr indNew[0], WifiConnApOff, loadU8(ind, SmConnApIdxOff))
    storeU8(addr indNew[0], WifiConnChOff, loadU8(ind, SmConnChIdxOff))
    storeI32(addr indNew[0], WifiConnQosOff, loadU8(ind, SmConnQosOff).int32)
    storeU16(addr indNew[0], WifiConnAidOff, loadU16(ind, SmConnAidOff))
    storeU8(addr indNew[0], WifiConnBandOff, loadU8(ind, SmConnBandOff))
    storeU16(addr indNew[0], WifiConnCenterFreqOff, loadU16(ind, SmConnCenterFreqOff))
    storeU8(addr indNew[0], WifiConnWidthOff, loadU8(ind, SmConnWidthOff))
    storeU32(addr indNew[0], WifiConnCenterFreq1Off, loadU32(ind, SmConnCenterFreq1Off))
    storeU32(addr indNew[0], WifiConnCenterFreq2Off, loadU32(ind, SmConnCenterFreq2Off))
    copyMem(ptrAt(addr indNew[0], WifiConnDiagnoseOff), ptrAt(ind, SmConnDiagnoseOff), DiagnoseSize)

  let event = addr indNew[0]
  bl_os_printf("[RX] Connection Status\r\n")
  bl_os_printf("[RX]   status_code %u\r\n", status.cuint)
  bl_os_printf("[RX]   reason_code %u\r\n", loadU16(event, WifiConnReasonOff).cuint)
  bl_os_printf("[RX]   connect result: %s\r\n", smStatusStr(status))
  bl_os_printf("[RX]   MAC %02X:%02X:%02X:%02X:%02X:%02X\r\n",
               loadU8(event, WifiConnBssidOff + 0).cuint, loadU8(event, WifiConnBssidOff + 1).cuint,
               loadU8(event, WifiConnBssidOff + 2).cuint, loadU8(event, WifiConnBssidOff + 3).cuint,
               loadU8(event, WifiConnBssidOff + 4).cuint, loadU8(event, WifiConnBssidOff + 5).cuint)
  bl_os_printf("[RX]   vif_idx %u\r\n", BlVifSta.cuint)
  bl_os_printf("[RX]   ap_idx %u\r\n", loadU8(event, WifiConnApOff).cuint)
  bl_os_printf("[RX]   ch_idx %u\r\n", loadU8(event, WifiConnChOff).cuint)
  bl_os_printf("[RX]   qos %u\r\n", loadU32(event, WifiConnQosOff).cuint)
  bl_os_printf("[RX]   acm %u\r\n", acm.cuint)
  bl_os_printf("[RX]   assoc_req_ie_len %u\r\n", assocReqLen.cuint)
  bl_os_printf("[RX]   assoc_rsp_ie_len %u\r\n", assocRspLen.cuint)
  bl_os_printf("[RX]   aid %u\r\n", loadU16(event, WifiConnAidOff).cuint)
  bl_os_printf("[RX]   band %u\r\n", loadU8(event, WifiConnBandOff).cuint)
  bl_os_printf("[RX]   center_freq %u\r\n", loadU16(event, WifiConnCenterFreqOff).cuint)
  bl_os_printf("[RX]   width %u\r\n", loadU8(event, WifiConnWidthOff).cuint)
  bl_os_printf("[RX]   center_freq1 %u\r\n", loadU32(event, WifiConnCenterFreq1Off).cuint)
  bl_os_printf("[RX]   center_freq2 %u\r\n", loadU32(event, WifiConnCenterFreq2Off).cuint)
  bl_os_printf("[RX]   tlv_ptr first %p\r\n", loadPtr(event, WifiConnDiagnoseOff))

  var notify: bool
  block:
    let saved = callbackIrqSave()
    defer: callbackIrqRestore(saved)
    if not stationRxTransitionCurrent(transition): return 0
    notify = claimCallback(cbSmConnect, callback)
  if notify:
    callback.handler(callback.context, cast[ptr WifiEventSmConnect](addr indNew[0]))

  var linkDown: bool
  block:
    let saved = callbackIrqSave()
    defer: callbackIrqRestore(saved)
    if not stationRxTransitionCurrent(transition): return 0
    let vif = vifAt(blHw, BlVifSta)
    if status != 0 and loadU8(vif, BlVifLinksNumOff) != 0:
      storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) - 1)
      storeU8(vif, BlVifFcChanOff, 0)
      storeU8(vif, BlVifStaPsOff, PsModeOff)
      let sta = staAt(blHw, transition.fixedStation.uint)
      storeU8(sta, BlStaIsUsedOff, 0)
      linkDown = true
      bl_tx_cntrl_link_down(cast[ptr BlSta](sta))
  if linkDown: retireStationDhcp(transition)
  if stationRxNetifCurrent(transition):
    if status == 0:
      netifapi_netif_set_link_up(cast[ptr Netif](transition.netif))
    elif linkDown:
      netifapi_netif_set_link_down(cast[ptr Netif](transition.netif))
  elif status == 0 and stationRxTransitionCurrent(transition):
    bl_os_printf("[RX]  -------- CRITICAL when check netif. ptr is %p:%p\r\n",
                 vifAt(blHw, BlVifSta), transition.netif)
  0
