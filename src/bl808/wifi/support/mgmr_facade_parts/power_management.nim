const MgmrPmQueueCapacity = 16

var
  mgmrPmModes: array[MgmrPmQueueCapacity, cint]
  mgmrPmReadIndex, mgmrPmWriteIndex, mgmrPmCount: int
  mgmrPmDispatchActive: bool
  mgmrPmStartRegistered, mgmrPmStopRegistered: bool

proc wifi_mgmr_api_fw_powersaving*(mode: cint): cint {.exportc, cdecl.} =
  if not wifiStarted:
    return -1
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  if mgmrPmCount == MgmrPmQueueCapacity:
    return -1
  mgmrPmModes[mgmrPmWriteIndex] = mode
  mgmrPmWriteIndex = (mgmrPmWriteIndex + 1) mod MgmrPmQueueCapacity
  inc mgmrPmCount
  0

proc mgmrPmProcessOne(): bool =
  if not wifiStarted:
    return false
  let saved = osEnterCritical()
  if mgmrPmDispatchActive or mgmrPmCount == 0:
    osExitCritical(saved)
    return false
  let mode = mgmrPmModes[mgmrPmReadIndex]
  mgmrPmReadIndex = (mgmrPmReadIndex + 1) mod MgmrPmQueueCapacity
  dec mgmrPmCount
  mgmrPmDispatchActive = true
  osExitCritical(saved)
  discard bl_main_powersaving(mode)
  let finished = osEnterCritical()
  mgmrPmDispatchActive = false
  osExitCritical(finished)
  true

proc wifi_mgmr_sta_pm_ops*(arg: pointer): cint {.exportc, cdecl.} =
  discard wifi_mgmr_api_fw_powersaving(cast[uint](arg).cint)
  0

proc wifi_mgmr_pm_ops_register*(): cint {.exportc, cdecl.} =
  if not mgmrPmStartRegistered:
    if wifi_hosal_pm_event_register(cast[PmEvent](0), 0, 1, 8,
        wifi_mgmr_sta_pm_ops, cast[pointer](2'u), cast[PmEventAble](1)) != 0:
      return -1
    mgmrPmStartRegistered = true
  if not mgmrPmStopRegistered:
    if wifi_hosal_pm_event_register(cast[PmEvent](0), 1, 1, 6,
        wifi_mgmr_sta_pm_ops, nil, cast[PmEventAble](1)) != 0:
      return -1
    mgmrPmStopRegistered = true
  0

proc wifi_mgmr_fw_affair_ops*(): cint {.exportc, cdecl.} =
  let beaconLoss = wifi_hosal_pm_event_switch(cast[PmEvent](3), 0,
    cast[PmEventAble](1))
  let nullData = wifi_hosal_pm_event_switch(cast[PmEvent](4), 1,
    cast[PmEventAble](1))
  let wakeFailure = wifi_hosal_pm_event_switch(cast[PmEvent](2), 0,
    cast[PmEventAble](1))
  if beaconLoss == 0 and nullData == 0 and wakeFailure == 0: 0 else: -1

proc wifi_mgmr_sta_ps_enter*(psLevel: uint32): cint {.exportc, cdecl.} =
  if not wifiStarted or psLevel > 6'u32:
    return -1
  if wifi_hosal_pm_capacity_set(cast[PmLevel](psLevel)) != 0:
    return -1
  wifi_hosal_pm_post_event(cast[PmEvent](0), 0, nil)

proc wifi_mgmr_sta_ps_exit*(): cint {.exportc, cdecl.} =
  if not wifiStarted:
    return -1
  discard wifi_hosal_pm_post_event(cast[PmEvent](0), 1, nil)
  0
