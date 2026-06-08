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

  WifiHosalFuncs* {.bycopy.} = object
    efuseReadMac*: EfuseReadMac
    rfTurnOn*: RfTurn
    rfTurnOff*: RfTurn
    adcDeviceGet*: AdcDeviceGet
    adcTsenValueGet*: AdcTsenValueGet
    pmInit*: PmInit
    pmEventRegister*: PmEventRegister
    pmDeinit*: PmInit
    pmStateRun*: PmInit
    pmCapacitySet*: PmCapacitySet
    pmPostEvent*: PmPostEvent
    pmEventSwitch*: PmEventSwitch

var g_wifi_hosal_funcs* {.importc.}: WifiHosalFuncs
