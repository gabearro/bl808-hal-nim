proc blRxSmStaAddInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  let ind = msgParam(msg)
  let vif = vifAt(blHw, BlVifSta)
  inc nimFwDbgRxSmStaAdd
  inc nimFwDbgRxSmSeq
  nimFwDbgRxSmStaAddSeq = nimFwDbgRxSmSeq
  nimFwDbgRxSmStaAddMeta = loadU8(ind, SmStaAddApIdxOff).uint32 or
    (loadU8(ind, SmStaAddQosOff).uint32 shl 8) or
    (loadU8(vif, BlVifLinksNumOff).uint32 shl 16) or
    (loadU8(vif, BlVifFixedStaIdxOff).uint32 shl 24)
  if loadU8(vif, BlVifLinksNumOff) > 0:
    inc nimFwDbgRxSmStaAddError
    bl_os_printf("[WF] Error: illegal sm_sta_add, sta_idx: %d\r\n", loadU8(ind, SmStaAddApIdxOff).cint)
    return -1
  storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) + 1)
  storeU8(vif, BlVifFcChanOff, 0)
  storeU8(vif, BlVifFixedStaIdxOff, loadU8(ind, SmStaAddApIdxOff))
  let sta = staAt(blHw, loadU8(ind, SmStaAddApIdxOff).uint)
  storeU8(sta, BlStaStaIdxOff, loadU8(ind, SmStaAddApIdxOff))
  storeU8(sta, BlStaVifIdxOff, BlVifSta.uint8)
  storeU8(sta, BlStaQosOff, loadU8(ind, SmStaAddQosOff))
  storeU8(sta, BlStaFcPsOff, 0)
  storeU8(sta, BlStaIsUsedOff, 1)
  nimFwDbgRxSmStaAddVif = loadU8(vif, BlVifLinksNumOff).uint32 or
    (loadU8(vif, BlVifFixedStaIdxOff).uint32 shl 8) or
    (loadU8(vif, BlVifFcChanOff).uint32 shl 16) or
    (loadU8(vif, BlVifStaPsOff).uint32 shl 24)
  nimFwDbgRxSmStaAddSta = loadU8(sta, BlStaIsUsedOff).uint32 or
    (loadU8(sta, BlStaStaIdxOff).uint32 shl 8) or
    (loadU8(sta, BlStaVifIdxOff).uint32 shl 16) or
    (loadU8(sta, BlStaQosOff).uint32 shl 24)
  bl_tx_cntrl_link_up(cast[ptr BlSta](sta))
  0
