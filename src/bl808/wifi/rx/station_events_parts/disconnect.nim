proc blRxSmDisconnectInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  inc nimFwDbgRxSmDisc
  let ind = msgParam(msg)
  let vif = vifAt(blHw, BlVifSta)
  var indNew: array[WifiDiscEventSize.int, uint8]
  var addrAny: uint32
  inc nimFwDbgRxSmSeq
  nimFwDbgRxSmDiscSeq = nimFwDbgRxSmSeq
  nimFwDbgRxSmDiscMeta = loadU16(ind, SmDiscStatusOff).uint32 or
    (loadU16(ind, SmDiscReasonOff).uint32 shl 16)
  nimFwDbgRxSmDiscVif = loadU8(vif, BlVifLinksNumOff).uint32 or
    (loadU8(vif, BlVifFixedStaIdxOff).uint32 shl 8) or
    (loadU8(vif, BlVifFcChanOff).uint32 shl 16) or
    (loadU8(vif, BlVifStaPsOff).uint32 shl 24)
  let discSta = staAt(blHw, loadU8(vif, BlVifFixedStaIdxOff).uint)
  nimFwDbgRxSmDiscSta = loadU8(discSta, BlStaIsUsedOff).uint32 or
    (loadU8(discSta, BlStaStaIdxOff).uint32 shl 8) or
    (loadU8(discSta, BlStaVifIdxOff).uint32 shl 16) or
    (loadU8(discSta, BlStaQosOff).uint32 shl 24)
  bl_os_printf("[RX]   sm_disconnect_ind\r\n       status_code %u\r\n       802.11 reason_code %u\r\n",
               loadU16(ind, SmDiscStatusOff).cuint, loadU16(ind, SmDiscReasonOff).cuint)
  bl_os_printf("[RX]   disconnect reason: %s\r\n", smStatusStr(loadU16(ind, SmDiscStatusOff)))
  bl_os_printf("[RX]   vif_idx %u\r\n", BlVifSta.cuint)
  bl_os_printf("[RX]   ft_over_ds %u\r\n", loadU8(ind, SmDiscFtOverDsOff).cuint)
  bl_os_printf("[RX]   tlv_ptr first %p\r\n", loadPtr(ind, SmDiscDiagnoseOff))
  if loadU8(vif, BlVifLinksNumOff) == 0:
    bl_os_printf("[WF] Error: illegal sm_sta_del, links_num is 0!\r\n")
    return -1
  let sta = staAt(blHw, loadU8(vif, BlVifFixedStaIdxOff).uint)
  if loadU8(sta, BlStaIsUsedOff) != 0:
    storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) - 1)
    storeU8(vif, BlVifFcChanOff, 0)
    storeU8(vif, BlVifStaPsOff, PsModeOff)
    storeU8(sta, BlStaIsUsedOff, 0)
    bl_tx_cntrl_link_down(cast[ptr BlSta](sta))
  if cbSmDisconnect != nil:
    zero(addr indNew[0], indNew.len.uint)
    storeU16(addr indNew[0], WifiDiscStatusOff, loadU16(ind, SmDiscStatusOff))
    storeU16(addr indNew[0], WifiDiscReasonOff, loadU16(ind, SmDiscReasonOff))
    storeU8(addr indNew[0], WifiDiscVifOff, BlVifSta.uint8)
    storeI32(addr indNew[0], WifiDiscFtOverDsOff, loadU8(ind, SmDiscFtOverDsOff).int32)
    copyMem(ptrAt(addr indNew[0], WifiDiscDiagnoseOff), ptrAt(ind, SmDiscDiagnoseOff), DiagnoseSize)
    cbSmDisconnect(cbSmDisconnectEnv, cast[ptr WifiEventSmDisconnect](addr indNew[0]))
  let dev = loadPtr(vif, BlVifDevOff)
  if dev != nil:
    netifapi_netif_set_link_down(cast[ptr Netif](dev))
    addrAny = 0
    discard netifapi_netif_set_addr(cast[ptr Netif](dev), addr addrAny, addr addrAny, addr addrAny)
  0
