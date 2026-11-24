proc checkActivationPeer(hw: pointer; station: uint8; token: uint32; retire: bool): bool =
  let saved = callbackIrqSave()
  defer: callbackIrqRestore(saved)
  if hw == nil or station >= NxRemoteStaMax or token != stationRxSerial: return false
  let vif = vifAt(hw, BlVifSta)
  let sta = staAt(hw, station.uint)
  if loadU8(vif, BlVifLinksNumOff) != 1 or loadU8(vif, BlVifFixedStaIdxOff) != station or
      loadU8(sta, BlStaIsUsedOff) == 0 or loadU8(sta, BlStaStaIdxOff) != station: return false
  if not retire: return true
  inc stationRxSerial
  storeU8(vif, BlVifLinksNumOff, 0)
  storeU8(vif, BlVifFcChanOff, 0)
  storeU8(vif, BlVifStaPsOff, PsModeOff)
  storeU8(sta, BlStaIsUsedOff, 0)
  bl_tx_cntrl_link_down(cast[ptr BlSta](sta))
  true

proc blRxSmStaAddInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  let saved = callbackIrqSave()
  defer: callbackIrqRestore(saved)
  if blHw == nil or msg == nil: return -1
  let ind = msgParam(msg)
  let vif = vifAt(blHw, BlVifSta)
  let station = loadU8(ind, SmStaAddApIdxOff)
  if station >= NxRemoteStaMax: return -1
  let firmwareVif = loadU8(vif, BlVifVifIdxOff)
  if not firmware.smActivationAcceptPeer(ind, firmwareVif, station): return -1
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
  var transition = beginStationRxTransition(blHw, station)
  if not transition.valid: return -1
  storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) + 1)
  storeU8(vif, BlVifFcChanOff, 0)
  storeU8(vif, BlVifFixedStaIdxOff, station)
  transition.fixedStation = station
  let sta = staAt(blHw, station.uint)
  storeU8(sta, BlStaStaIdxOff, station)
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
  firmware.smActivationTrackPeer(ind, blHw, transition.serial, checkActivationPeer)
  bl_tx_cntrl_link_up(cast[ptr BlSta](sta))
  if stationRxTransitionCurrent(transition):
    discard firmware.smActivationAcceptPeer(ind, firmwareVif, station, linked = true)
  0
