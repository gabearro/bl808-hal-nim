proc bl_main_denoise*(mode: cint): cint {.exportc, cdecl.} =
  bl_send_mm_denoise_req(hwPtr(), mode)

proc bl_main_monitor*(): cint {.exportc, cdecl.} =
  var cfm: array[SizeMmMonitorCfm, uint8]
  zero(addr cfm[0], cfm.len)
  discard bl_send_monitor_enable(hwPtr(), cast[ptr MmMonitorCfm](addr cfm[0]))
  0

proc bl_main_monitor_disable*(): cint {.exportc, cdecl.} =
  var cfm: array[SizeMmMonitorCfm, uint8]
  zero(addr cfm[0], cfm.len)
  discard bl_send_monitor_disable(hwPtr(), cast[ptr MmMonitorCfm](addr cfm[0]))
  0

proc bl_main_phy_up*(): cint {.exportc, cdecl.} =
  if bl_send_start(hwPtr()) != 0: -1 else: 0

proc bl_main_channel_set*(channel: cint): cint {.exportc, cdecl.} =
  discard bl_send_channel_set_req(hwPtr(), channel)
  0

proc bl_main_monitor_channel_set*(channel, use40Mhz: cint): cint {.exportc, cdecl.} =
  var cfm: array[SizeMmMonitorChannelCfm, uint8]
  zero(addr cfm[0], cfm.len)
  discard bl_send_monitor_channel_set(hwPtr(), cast[ptr MmMonitorChannelCfm](addr cfm[0]),
                                      channel, use40Mhz)
  0

proc bl_main_beacon_interval_set*(beaconInt: uint16): cint {.exportc, cdecl.} =
  var cfm: array[SizeMmBeaconCfm, uint8]
  zero(addr cfm[0], cfm.len)
  discard bl_send_beacon_interval_set(hwPtr(), cast[ptr MmBeaconCfm](addr cfm[0]), beaconInt)
  0
