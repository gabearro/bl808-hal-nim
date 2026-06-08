proc blRxChanSwitchInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  notifyEventChannelSwitch(loadU8(msgParam(msg), MmChanSwitchChanOff).cint)
  0

proc blCommonInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  0

proc blRxRssiStatusInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
  let ind = msgParam(msg)
  if cbRssi != nil:
    cbRssi(cbRssiEnv, loadI8(ind, MmRssiRssiOff))
  0

proc blRxScanuStartCfm(blHw, cmd, msg: pointer): cint {.cdecl.} =
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
