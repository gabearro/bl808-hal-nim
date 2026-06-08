proc blRxApmStaAddInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  let ind = msgParam(msg)
  bl_os_printf("[WF] APM_STA_ADD_IND\r\n")
  bl_os_printf("[WF]    flags %08X\r\n", loadU32(ind, ApmFlagsOff).cuint)
  bl_os_printf("[WF]    MAC %02X:%02X:%02X:%02X:%02X:%02X\r\n",
               loadU8(ind, ApmStaAddrOff + 0).cuint, loadU8(ind, ApmStaAddrOff + 1).cuint,
               loadU8(ind, ApmStaAddrOff + 2).cuint, loadU8(ind, ApmStaAddrOff + 3).cuint,
               loadU8(ind, ApmStaAddrOff + 4).cuint, loadU8(ind, ApmStaAddrOff + 5).cuint)
  bl_os_printf("[WF]    vif_idx %u\r\n", BlVifAp.cuint)
  bl_os_printf("[WF]    sta_idx %u\r\n", loadU8(ind, ApmStaIdxOff).cuint)
  bl_os_log_info("[WF]    tsflo: 0x%lx\r\n", loadU32(ind, ApmTsfloOff).culong)
  bl_os_log_info("[WF]    tsfhi: 0x%lx\r\n", loadU32(ind, ApmTsfhiOff).culong)
  bl_os_log_info("[WF]    rssi: %d\r\n", loadI8(ind, ApmRssiOff).cint)
  bl_os_log_info("[WF]    data rate: 0x%x\r\n", loadU8(ind, ApmDataRateOff).cuint)
  let staIdx = loadU8(ind, ApmStaIdxOff)
  if staIdx >= NxRemoteStaStoreMax:
    bl_os_printf("[WF]    Error: Potential illegal sta_idx: %d\r\n", staIdx.cint)
    return -1
  var sta = staAt(blHw, staIdx.uint)
  if loadU8(sta, BlStaIsUsedOff) != 0:
    bl_os_log_info("[WF]    Warning: sta_idx already used: %d\r\n", staIdx.cint)
  copyMem(ptrAt(sta, BlStaAddrOff), ptrAt(ind, ApmStaAddrOff), 6)
  storeU8(sta, BlStaQosOff, if (loadU32(ind, ApmFlagsOff) and StaQosCapa) != 0: 1 else: 0)
  storeU8(sta, BlStaStaIdxOff, staIdx)
  storeU8(sta, BlStaVifIdxOff, BlVifAp.uint8)
  storeI8(sta, BlStaRssiOff, loadI8(ind, ApmRssiOff))
  storeU32(sta, BlStaTsfloOff, loadU32(ind, ApmTsfloOff))
  storeU32(sta, BlStaTsfhiOff, loadU32(ind, ApmTsfhiOff))
  storeU8(sta, BlStaDataRateOff, loadU8(ind, ApmDataRateOff))
  storeU8(sta, BlStaFcPsOff, 0)
  storeU8(sta, BlStaIsUsedOff, 1)
  bl_tx_cntrl_link_up(cast[ptr BlSta](sta))
  let vif = vifAt(blHw, BlVifAp)
  if loadU8(vif, BlVifLinksNumOff) == 0:
    storeU8(vif, BlVifFcChanOff, 0)
    sta = staAt(hwRaw(), loadU8(vif, BlVifFixedStaIdxOff).uint)
    if (loadU32(ind, ApmFlagsOff) and StaQosCapa) == 0:
      storeU8(sta, BlStaQosOff, 0)
    storeU8(sta, BlStaFcPsOff, 0)
    storeU8(sta, BlStaIsUsedOff, 1)
    bl_tx_cntrl_link_up(cast[ptr BlSta](sta))
    storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) + 1)
    let dev = loadPtr(vif, BlVifDevOff)
    if dev != nil:
      netifapi_netif_set_link_up(cast[ptr Netif](dev))
  else:
    storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) + 1)
  discard aos_post_event(EvWifi, CodeWifiOnApStaAdd, staIdx.cint)
  0

proc blRxApmStaDelInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  let ind = msgParam(msg)
  let staIdx = loadU8(ind, ApmDelStaIdxOff)
  let vif = vifAt(blHw, BlVifAp)
  bl_os_printf("[WF] APM_STA_DEL_IND\r\n")
  bl_os_printf("[WF]    sta_idx %u\r\n", staIdx.cuint)
  bl_os_printf("[WF]    statuts_code %u\r\n", loadU16(ind, ApmDelStatusOff).cuint)
  bl_os_printf("[WF]    reason_code %u\r\n", loadU16(ind, ApmDelReasonOff).cuint)
  bl_os_printf("[RX]    disconnect reason: %s\r\n", apmStatusStr(loadU16(ind, ApmDelStatusOff)))
  if staIdx >= NxRemoteStaStoreMax or loadU8(vif, BlVifLinksNumOff) == 0:
    bl_os_printf("[WF]    Error: Potential illegal sta_idx: %d, or no link_num\r\n", staIdx.cint)
    return -1
  var sta = staAt(blHw, staIdx.uint)
  if loadU8(sta, BlStaIsUsedOff) == 0:
    bl_os_log_info("[WF]    Warning: sta_idx already empty: %d\r\n", staIdx.cint)
  storeU8(sta, BlStaIsUsedOff, 0)
  bl_tx_cntrl_link_down(cast[ptr BlSta](sta))
  storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) - 1)
  bl_os_printf("[WF]    links_num %u\r\n", loadU8(vif, BlVifLinksNumOff).cuint)
  if loadU8(vif, BlVifLinksNumOff) == 0:
    storeU8(vif, BlVifFcChanOff, 0)
    sta = staAt(hwRaw(), loadU8(vif, BlVifFixedStaIdxOff).uint)
    storeU8(sta, BlStaIsUsedOff, 0)
    bl_tx_cntrl_link_down(cast[ptr BlSta](sta))
    let dev = loadPtr(vif, BlVifDevOff)
    if dev != nil:
      netifapi_netif_set_link_down(cast[ptr Netif](dev))
  discard aos_post_event(EvWifi, CodeWifiOnApStaDel, staIdx.cint)
  0
