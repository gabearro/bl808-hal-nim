proc bl_send_monitor_enable*(blHw: ptr BlHw; cfm: ptr MmMonitorCfmObj): cint
    {.exportc, cdecl.} =
  let req = blMsgZalloc(MM_MONITOR_REQ, TASK_MM, DRV_TASK_ID, SizeMmMonitorReq)
  if req == nil: return -Enomem
  storeU32(req, 0, 1'u32)
  blSendMsg(blHw, req, 1, MM_MONITOR_CFM, cfm)

proc bl_send_monitor_disable*(blHw: ptr BlHw; cfm: ptr MmMonitorCfmObj): cint
    {.exportc, cdecl.} =
  let req = blMsgZalloc(MM_MONITOR_REQ, TASK_MM, DRV_TASK_ID, SizeMmMonitorReq)
  if req == nil: return -Enomem
  storeU32(req, 0, 0'u32)
  blSendMsg(blHw, req, 1, MM_MONITOR_CFM, cfm)

proc bl_send_beacon_interval_set*(blHw: ptr BlHw; cfm: ptr MmBeaconCfmObj;
                                  beaconInt: uint16): cint {.exportc, cdecl.} =
  let req = blMsgZalloc(MM_SET_BEACON_INT_REQ, TASK_MM, DRV_TASK_ID, SizeMmBeaconIntReq)
  if req == nil: return -Enomem
  storeU16(req, 0, beaconInt)
  blSendMsg(blHw, req, 1, MM_SET_BEACON_INT_CFM, cfm)

proc bl_send_monitor_channel_set*(blHw: ptr BlHw; cfm: ptr MmMonitorChannelCfmObj;
                                  channel, use40Mhz: cint): cint {.exportc, cdecl.} =
  let req = blMsgZalloc(MM_MONITOR_CHANNEL_REQ, TASK_MM, DRV_TASK_ID,
                        SizeMmMonitorChannelReq)
  if req == nil: return -Enomem
  storeU16(req, 0, phy_channel_to_freq(PHY_BAND_2G4, channel))
  blSendMsg(blHw, req, 1, MM_MONITOR_CHANNEL_CFM, cfm)
