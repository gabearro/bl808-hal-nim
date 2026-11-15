proc wifi_mgmr_ap_start*(iface: ptr pointer; ssid: cstring; hiddenSsid: cint; passwd: cstring; channel: cint): cint {.exportc, cdecl.} =
  discard iface
  if not staEnabled or ssid == nil or channel <= 0: return -1
  if not beginStationControl(): return -16
  defer: endStationControl()
  result = bl_main_apm_start(ssid, passwd, channel, hiddenSsid.uint8, loadU16(mgmrRaw(), MgmrApBcnIntOff))
  if result == 0: apEnabled = true

proc wifi_mgmr_ap_stop*(iface: ptr pointer): cint {.exportc, cdecl.} =
  discard iface
  if not apEnabled: return -1
  if not beginStationControl(): return -16
  defer: endStationControl()
  result = bl_main_apm_stop()
  if result == 0: apEnabled = false
