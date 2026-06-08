proc wifi_mgmr_ap_start*(iface: ptr pointer; ssid: cstring; hiddenSsid: cint; passwd: cstring; channel: cint): cint {.exportc, cdecl.} =
  discard iface
  if not staEnabled or ssid == nil or channel <= 0: return -1
  result = bl_main_apm_start(ssid, passwd, channel, hiddenSsid.uint8, loadU16(mgmrRaw(), MgmrApBcnIntOff))
  apEnabled = result == 0

proc wifi_mgmr_ap_stop*(iface: ptr pointer): cint {.exportc, cdecl.} =
  discard iface
  if not apEnabled: return -1
  apEnabled = false
  bl_main_apm_stop()
