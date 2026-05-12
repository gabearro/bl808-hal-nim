## Nim replacement for the BL808 WiFi HOSAL forwarding wrapper.
##
## Platform-specific callbacks still live behind `g_wifi_hosal_funcs`; this
## module removes the SDK C forwarding translation unit from Nim firmware builds.

type
  EfuseReadMac = proc(mac: ptr uint8): cint {.cdecl.}
  RfTurn = proc(arg: pointer): cint {.cdecl.}
  AdcDeviceGet = proc(): pointer {.cdecl.}
  AdcTsenValueGet = proc(adc: pointer): cint {.cdecl.}
  PmInit = proc(): cint {.cdecl.}
  PmEventRegister = proc(event: cint; code, capBit: uint32; priority: uint16;
                         ops, arg: pointer; enable: cint): cint {.cdecl.}
  PmCapacitySet = proc(level: cint): cint {.cdecl.}
  PmPostEvent = proc(event: cint; code: uint32; retval: ptr uint32): cint {.cdecl.}
  PmEventSwitch = proc(event: cint; code: uint32; enable: cint): cint {.cdecl.}

  WifiHosalFuncs {.bycopy.} = object
    efuseReadMac: EfuseReadMac
    rfTurnOn: RfTurn
    rfTurnOff: RfTurn
    adcDeviceGet: AdcDeviceGet
    adcTsenValueGet: AdcTsenValueGet
    pmInit: PmInit
    pmEventRegister: PmEventRegister
    pmDeinit: PmInit
    pmStateRun: PmInit
    pmCapacitySet: PmCapacitySet
    pmPostEvent: PmPostEvent
    pmEventSwitch: PmEventSwitch

var g_wifi_hosal_funcs {.importc.}: WifiHosalFuncs

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
