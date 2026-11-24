proc blRxChanSwitchInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  notifyEventChannelSwitch(loadU8(msgParam(msg), MmChanSwitchChanOff).cint)
  0

proc blCommonInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  0

proc blRxRssiStatusInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  let callback = snapshotCallback(cbRssi)
  let ind = msgParam(msg)
  if callback.handler != nil:
    let rssi = loadI8(ind, MmRssiRssiOff)
    if claimCallback(cbRssi, callback):
      callback.handler(callback.context, rssi)
  0

proc blRxScanuStartCfm(blHw, cmd, msg: pointer): cint {.cdecl.} =
  let status = if msg != nil and loadU32(msg, IpcMsgParamLenOff) != 0:
      loadU8(msgParam(msg), 0).uint32
    else:
      high(uint32)
  # Publish before the legacy callback can complete the async scan.
  bl808_wifi_backend_record_scan_confirmation(status)
  when defined(bl808WifiDiagWarmScan):
    firmware.nimFwDbgWarmScanHostStatus = status
    inc firmware.nimFwDbgWarmScan.host_replies
  notifyEventScanDone(false)
  0

proc blRxScanuJoinCfm(blHw, cmd, msg: pointer): cint {.cdecl.} =
  notifyEventScanDone(true)
  0

proc blRxScanuResultInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  let ind = msgParam(msg)
  let mgmt = ptrAt(ind, ScanuPayloadOff)
  let fc = loadU16(mgmt, MgmtFrameControlOff)
  if isBeacon(fc):
    rxHandleBeacon(ind, mgmt)
  elif isProbeResp(fc):
    rxHandleProbeResp(ind, mgmt)
  else:
    bl_os_printf("Bug Scan IND?\r\n")
  0
