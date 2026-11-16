template cfgEntry(taskId: uint32; element, valueType: uint16;
                  label: cstring; storage, notifier: untyped): CfgApiElementEntryView =
  CfgApiElementEntryView(id: taskId, subId: element, typeId: valueType,
    name: cast[pointer](cstring(label)), valueStorage: cast[pointer](storage),
    setHandler: cast[pointer](cfg_api_element_general_set),
    getHandler: cast[pointer](cfg_api_element_general_get),
    notifyHandler: cast[pointer](notifier))

# The pinned archive registers eight MM, three SCAN and two SM records.
cfgApiEntries = [
  cfgEntry(0, 0, 1, "Keep Alive On/Off Status", addr mmEnvView().flagsHigh, element_notify),
  cfgEntry(0, 1, 7, "Keep Alive Frame last received", addr mmEnvView().keepAliveTimestamp, element_notify),
  cfgEntry(0, 2, 7, "Keep Alive Frame Counter", addr mmEnvView().keepAliveCounter, element_notify),
  cfgEntry(0, 3, 7, "Accept All Beacon for VIF_STA", addr mmEnvView().rxPromiscUploadFlag, element_notify),
  cfgEntry(0, 4, 7, "Accept All Beacon for VIF_AP", addr mmEnvView().apPromiscUploadFlag, element_notify),
  cfgEntry(0, 5, 7, "Beacon Timeout", addr mmEnvView().keepAliveInterval, element_notify),
  cfgEntry(0, 6, 7, "PSM TBTT Pre-time", addr mmEnvView().tbttPreDuration, element_notify),
  cfgEntry(0, 7, 7, "PS NULL TX TIMEOUT", addr blPsParamsView().txNullTimeout, element_notify),
  cfgEntry(1, 0, 7, "duration for passive scan", addr scan_env.passiveDuration, element_notify_status_enabled),
  cfgEntry(1, 1, 7, "duration for active scan", addr scan_env.activeDuration, element_notify_status_enabled),
  cfgEntry(1, 2, 7, "duration for active join scan", addr scan_env.joinActiveDuration, element_notify_status_enabled),
  cfgEntry(4, 0, 7, "Auth/Assoc Retry Limit", addr smEnvView().authRetryLimit, element_notify_status_enabled),
  cfgEntry(4, 1, 7, "Reconnect Dominant Trigger Flag", addr sm_reconn_dominant_flag, element_notify_status_enabled)
]
