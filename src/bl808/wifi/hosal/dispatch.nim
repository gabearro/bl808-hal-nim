import callback_table

proc wifi_hosal_efuse_read_mac*(mac: ptr uint8): cint {.exportc, cdecl.} =
  if g_wifi_hosal_funcs.efuseReadMac == nil: -1
  else: g_wifi_hosal_funcs.efuseReadMac(mac)

proc wifi_hosal_rf_turn_on*(arg: pointer = nil): cint {.exportc, cdecl.} =
  if g_wifi_hosal_funcs.rfTurnOn == nil: -1
  else: g_wifi_hosal_funcs.rfTurnOn(arg)

proc wifi_hosal_rf_turn_off*(arg: pointer = nil): cint {.exportc, cdecl.} =
  if g_wifi_hosal_funcs.rfTurnOff == nil: -1
  else: g_wifi_hosal_funcs.rfTurnOff(arg)

proc wifi_hosal_adc_device_get*(): pointer {.exportc, cdecl.} =
  if g_wifi_hosal_funcs.adcDeviceGet == nil: nil
  else: g_wifi_hosal_funcs.adcDeviceGet()

proc wifi_hosal_adc_tsen_value_get*(adc: pointer): cint {.exportc, cdecl.} =
  if g_wifi_hosal_funcs.adcTsenValueGet == nil: -1
  else: g_wifi_hosal_funcs.adcTsenValueGet(adc)

proc wifi_hosal_pm_init*(): cint {.exportc, cdecl.} =
  if g_wifi_hosal_funcs.pmInit == nil: -1
  else: g_wifi_hosal_funcs.pmInit()

proc wifi_hosal_pm_event_register*(event: cint; code, capBit: uint32;
                                   priority: uint16; ops, arg: pointer;
                                   enable: cint): cint {.exportc, cdecl.} =
  if g_wifi_hosal_funcs.pmEventRegister == nil: -1
  else:
    g_wifi_hosal_funcs.pmEventRegister(event, code, capBit, priority, ops, arg, enable)

proc wifi_hosal_pm_deinit*(): cint {.exportc, cdecl.} =
  if g_wifi_hosal_funcs.pmDeinit == nil: -1
  else: g_wifi_hosal_funcs.pmDeinit()

proc wifi_hosal_pm_state_run*(): cint {.exportc, cdecl.} =
  if g_wifi_hosal_funcs.pmStateRun == nil: -1
  else: g_wifi_hosal_funcs.pmStateRun()

proc wifi_hosal_pm_capacity_set*(level: cint): cint {.exportc, cdecl.} =
  if g_wifi_hosal_funcs.pmCapacitySet == nil: -1
  else: g_wifi_hosal_funcs.pmCapacitySet(level)

proc wifi_hosal_pm_post_event*(event: cint; code: uint32; retval: ptr uint32): cint
    {.exportc, cdecl.} =
  if g_wifi_hosal_funcs.pmPostEvent == nil: -1
  else: g_wifi_hosal_funcs.pmPostEvent(event, code, retval)

proc wifi_hosal_pm_event_switch*(event: cint; code: uint32; enable: cint): cint
    {.exportc, cdecl.} =
  if g_wifi_hosal_funcs.pmEventSwitch == nil: -1
  else: g_wifi_hosal_funcs.pmEventSwitch(event, code, enable)
