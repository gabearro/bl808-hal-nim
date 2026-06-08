proc blRxSmConnectInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  let ind = msgParam(msg)
  var indNew: array[WifiConnEventSize.int, uint8]
  bl_os_printf("[RX] Connection Status\r\n")
  bl_os_printf("[RX]   status_code %u\r\n", loadU16(ind, SmConnStatusOff).cuint)
  bl_os_printf("[RX]   reason_code %u\r\n", loadU16(ind, SmConnReasonOff).cuint)
  bl_os_printf("[RX]   connect result: %s\r\n", smStatusStr(loadU16(ind, SmConnStatusOff)))
  bl_os_printf("[RX]   MAC %02X:%02X:%02X:%02X:%02X:%02X\r\n",
               loadU8(ind, SmConnBssidOff + 0).cuint, loadU8(ind, SmConnBssidOff + 1).cuint,
               loadU8(ind, SmConnBssidOff + 2).cuint, loadU8(ind, SmConnBssidOff + 3).cuint,
               loadU8(ind, SmConnBssidOff + 4).cuint, loadU8(ind, SmConnBssidOff + 5).cuint)
  bl_os_printf("[RX]   vif_idx %u\r\n", BlVifSta.cuint)
  bl_os_printf("[RX]   ap_idx %u\r\n", loadU8(ind, SmConnApIdxOff).cuint)
  bl_os_printf("[RX]   ch_idx %u\r\n", loadU8(ind, SmConnChIdxOff).cuint)
  bl_os_printf("[RX]   qos %u\r\n", loadU8(ind, SmConnQosOff).cuint)
  bl_os_printf("[RX]   acm %u\r\n", loadU8(ind, SmConnAcmOff).cuint)
  bl_os_printf("[RX]   assoc_req_ie_len %u\r\n", loadU16(ind, SmConnAssocReqLenOff).cuint)
  bl_os_printf("[RX]   assoc_rsp_ie_len %u\r\n", loadU16(ind, SmConnAssocRspLenOff).cuint)
  bl_os_printf("[RX]   aid %u\r\n", loadU16(ind, SmConnAidOff).cuint)
  bl_os_printf("[RX]   band %u\r\n", loadU8(ind, SmConnBandOff).cuint)
  bl_os_printf("[RX]   center_freq %u\r\n", loadU16(ind, SmConnCenterFreqOff).cuint)
  bl_os_printf("[RX]   width %u\r\n", loadU8(ind, SmConnWidthOff).cuint)
  bl_os_printf("[RX]   center_freq1 %u\r\n", loadU32(ind, SmConnCenterFreq1Off).cuint)
  bl_os_printf("[RX]   center_freq2 %u\r\n", loadU32(ind, SmConnCenterFreq2Off).cuint)
  bl_os_printf("[RX]   tlv_ptr first %p\r\n", loadPtr(ind, SmConnDiagnoseOff))

  zero(addr indNew[0], indNew.len.uint)
  storeU16(addr indNew[0], WifiConnStatusOff, loadU16(ind, SmConnStatusOff))
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
  if cbSmConnect != nil:
    cbSmConnect(cbSmConnectEnv, cast[ptr WifiEventSmConnect](addr indNew[0]))

  let vif = vifAt(blHw, BlVifSta)
  if loadU16(ind, SmConnStatusOff) != 0:
    if loadU8(vif, BlVifLinksNumOff) != 0:
      storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) - 1)
      storeU8(vif, BlVifFcChanOff, 0)
      storeU8(vif, BlVifStaPsOff, PsModeOff)
      let sta = staAt(blHw, loadU8(vif, BlVifFixedStaIdxOff).uint)
      storeU8(sta, BlStaIsUsedOff, 0)
      bl_tx_cntrl_link_down(cast[ptr BlSta](sta))
      let dev = loadPtr(vif, BlVifDevOff)
      if dev != nil:
        netifapi_netif_set_link_down(cast[ptr Netif](dev))
  else:
    let dev = loadPtr(vif, BlVifDevOff)
    if dev != nil:
      netifapi_netif_set_link_up(cast[ptr Netif](dev))
    else:
      bl_os_printf("[RX]  -------- CRITICAL when check netif. ptr is %p:%p\r\n", vif, dev)
  0
