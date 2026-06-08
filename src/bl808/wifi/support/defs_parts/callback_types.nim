## Function pointer signatures shared by support submodules.

type
  PmCb {.importc: "bl_pm_cb_t", header: "bl_pm.h".} = proc(arg: pointer): cint {.cdecl.}
  UtilsListCmp = proc(a, b: ptr ConstUtilsListHdr): cint {.cdecl.}
  ScanCompleteCb = proc(data, param: pointer) {.cdecl.}
  NetifInitFn = proc(netif: ptr Netif): int8 {.cdecl.}
  NetifInputFn = proc(p: ptr Pbuf; netif: ptr Netif): int8 {.cdecl.}
  NetifVoidFn = proc(netif: ptr Netif) {.cdecl.}
  NetifErrFn = proc(netif: ptr Netif): int8 {.cdecl.}
  PbufFreeFn = proc(p: ptr Pbuf) {.cdecl.}
  IrqHandler = proc() {.cdecl.}
  ConnectCb = proc(env, ind: pointer) {.cdecl.}
  DisconnectCb = proc(env, ind: pointer) {.cdecl.}
  BeaconCb = proc(env, ind: pointer) {.cdecl.}
  EventCb = proc(env, event: pointer) {.cdecl.}
  WifiHosalFuncs {.importc: "wifi_hosal_funcs_t", header: "wifi_hosal.h", bycopy.} = object
    efuseReadMac {.importc: "efuse_read_mac".}: proc(mac: ptr uint8): cint {.cdecl.}
    rfTurnOn {.importc: "rf_turn_on".}: proc(arg: pointer): cint {.cdecl.}
    rfTurnOff {.importc: "rf_turn_off".}: proc(arg: pointer): cint {.cdecl.}
    adcDeviceGet {.importc: "adc_device_get".}: proc(): pointer {.cdecl.}
    adcTsenValueGet {.importc: "adc_tsen_value_get".}: proc(adc: pointer): cint {.cdecl.}
    pmInit {.importc: "pm_init".}: proc(): cint {.cdecl.}
    pmEventRegister {.importc: "pm_event_register".}: proc(event: PmEvent; code, capBit: uint32; priority: uint16;
                          ops: PmCb; arg: pointer; enable: PmEventAble): cint {.cdecl.}
    pmDeinit {.importc: "pm_deinit".}: proc(): cint {.cdecl.}
    pmStateRun {.importc: "pm_state_run".}: proc(): cint {.cdecl.}
    pmCapacitySet {.importc: "pm_capacity_set".}: proc(level: PmLevel): cint {.cdecl.}
    pmPostEvent {.importc: "pm_post_event".}: proc(event: PmEvent; code: uint32; retval: ptr uint32): cint {.cdecl.}
    pmEventSwitch {.importc: "pm_event_switch".}: proc(event: PmEvent; code: uint32; enable: PmEventAble): cint {.cdecl.}
