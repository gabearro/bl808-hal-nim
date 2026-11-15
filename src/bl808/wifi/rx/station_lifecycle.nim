type StationRxTransition = object
  hw, netif: pointer
  serial: uint32
  session: firmware.RxHostSession
  firmwareVif, fixedStation, up: uint8
  valid: bool

# The M0 host has one station interface; a nested event supersedes its caller.
var stationRxSerial: uint32

proc beginStationRxTransition(hw: pointer; station: uint8): StationRxTransition =
  let saved = callbackIrqSave()
  defer: callbackIrqRestore(saved)
  if hw == nil or (station != 0xFF and station >= NxRemoteStaStoreMax):
    return
  let vif = vifAt(hw, BlVifSta)
  let firmwareVif = loadU8(vif, BlVifVifIdxOff)
  if firmwareVif >= NxVirtDevMax:
    return
  let session = firmware.captureRxHostSession(firmwareVif, station)
  if not firmware.rxHostSessionCurrent(session):
    return
  inc stationRxSerial
  StationRxTransition(hw: hw, netif: loadPtr(vif, BlVifDevOff),
    serial: stationRxSerial, session: session, firmwareVif: firmwareVif,
    fixedStation: loadU8(vif, BlVifFixedStaIdxOff),
    up: loadU8(vif, BlVifUpOff), valid: true)

proc stationRxTransitionCurrent(transition: StationRxTransition): bool =
  let saved = callbackIrqSave()
  defer: callbackIrqRestore(saved)
  if not transition.valid or transition.serial != stationRxSerial or
      not firmware.rxHostSessionCurrent(transition.session):
    return false
  let vif = vifAt(transition.hw, BlVifSta)
  loadPtr(vif, BlVifDevOff) == transition.netif and
    loadU8(vif, BlVifVifIdxOff) == transition.firmwareVif and
    loadU8(vif, BlVifFixedStaIdxOff) == transition.fixedStation and
    loadU8(vif, BlVifUpOff) == transition.up

proc stationRxNetifCurrent(transition: StationRxTransition): bool =
  # This admits one synchronous call, not all later operations on the netif.
  transition.netif != nil and stationRxTransitionCurrent(transition)
