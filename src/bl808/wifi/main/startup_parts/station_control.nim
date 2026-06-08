proc bl_cfg80211_connect*(blHw: ptr BlHw; sme: ptr Cfg80211ConnectParams): cint =
  var cfm: array[SizeSmConnectCfm, uint8]
  zero(addr cfm[0], cfm.len)
  result = bl_send_sm_connect_req(blHw, sme, cast[ptr SmConnectCfm](addr cfm[0]))
  if result != 0:
    return result
  case loadU8(addr cfm[0], SmConnectStatusOff)
  of CoOk:
    result = 0
  of CoBusy:
    result = -Einprogress
  of CoOpInProgress:
    result = -Ealready
  else:
    result = -Eio

proc bl_cfg80211_disconnect*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
  bl_send_sm_disconnect_req(blHw)
