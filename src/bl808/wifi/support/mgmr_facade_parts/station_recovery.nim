const WifiStaRecoveryPollLimit {.intdefine.} = 20_000

type StationControlIdentity = object
  hostVif, netif: pointer
  vifIndex: uint8
  mac: array[6, uint8]
  session: RxHostSession
  captured: bool

var
  stationControlBusy: bool
  nimfwDbgStaRecoveryStage* {.exportc: "nimfw_dbg_sta_recovery_stage".}: uint32
  nimfwDbgStaRecoveryResult* {.exportc: "nimfw_dbg_sta_recovery_result".}: int32

proc beginStationControl(): bool =
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  if stationControlBusy: return false
  stationControlBusy = true
  true

proc endStationControl() =
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  stationControlBusy = false

proc stationBindingStatus(identity: StationControlIdentity): cint =
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  if not identity.captured or not wifiStarted or not staEnabled or
      vifAt(BlVifSta) != identity.hostVif or
      ifaceNetif(staIface()) != identity.netif or
      loadPtr(identity.hostVif, BlVifDevOff) != identity.netif or
      loadU8(identity.hostVif, BlVifUpOff) == 0 or
      loadU8(identity.hostVif, BlVifVifIdxOff) != identity.vifIndex or
      not rxHostSessionCurrent(identity.session): return -1
  let mac = netifHwaddr(identity.netif)
  if mac == nil: return -1
  for index in 0 ..< identity.mac.len:
    if cast[ptr UncheckedArray[uint8]](mac)[index] != identity.mac[index]: return -1
  vif_mgmt_sta_status(identity.vifIndex, unsafeAddr identity.mac[0])

proc captureStationControl(): StationControlIdentity =
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  if not wifiStarted or not staEnabled: return
  result.hostVif = vifAt(BlVifSta)
  result.netif = ifaceNetif(staIface())
  result.vifIndex = loadU8(result.hostVif, BlVifVifIdxOff)
  if result.netif == nil or result.vifIndex >= CfgVirtDevMax: return
  let mac = netifHwaddr(result.netif)
  if mac == nil: return
  for index in 0 ..< result.mac.len:
    result.mac[index] = cast[ptr UncheckedArray[uint8]](mac)[index]
  result.session = captureRxHostSession(result.vifIndex, 0xFF)
  result.captured = true
  if stationBindingStatus(result) < 0: result.captured = false

proc wifi_mgmr_recover_terminal_connect_failure(forJoin = false): cint =
  ## Called while station-control admission is held. Abort completion, rather
  ## than a global MAC reset, establishes when this interface can be reused.
  nimfwDbgStaRecoveryStage = 1
  defer: nimfwDbgStaRecoveryResult = result.int32
  discard wifiCmdMgrRecoverIfCrashed(cast[pointer](addr wifi_hw))
  if not wifiCmdMgrReady(cast[pointer](addr wifi_hw)): return -32
  let identity = captureStationControl()
  let initialStatus = stationBindingStatus(identity)
  if initialStatus < 0: return -32
  if connectDone <= 0 and sm_state == 0 and (not forJoin or initialStatus == 0):
    nimfwDbgStaRecoveryStage = 5
    return 0

  nimfwDbgStaRecoveryStage = 2
  disconnectDone = 0
  if sm_state == 0 and initialStatus != 0:
    result = bl_main_disconnect()
  else:
    var status = 0xFF'u8
    result = bl_main_connect_abort(addr status)
  if result != 0: return

  nimfwDbgStaRecoveryStage = 3
  for attempt in 0 ..< WifiStaRecoveryPollLimit:
    vendorPollFor(1)
    let bindingStatus = stationBindingStatus(identity)
    if bindingStatus < 0 or not wifiCmdMgrReady(cast[pointer](addr wifi_hw)): return -32
    if sm_state == 0 and bindingStatus == 0 and connectDone != 0 and
        loadU8(identity.hostVif, BlVifLinksNumOff) == 0:
      connectDone = -1
      disconnectDone = 1
      nimfwDbgStaRecoveryStage = 5
      return 0
  return -110
