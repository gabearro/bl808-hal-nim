proc bl_send_reset*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
  sendEmpty(blHw, MM_RESET_REQ, TASK_MM, 1, MM_RESET_CFM, nil)

proc bl_send_version_req*(blHw: ptr BlHw; cfm: ptr MmVersionCfmObj): cint
    {.exportc, cdecl.} =
  sendEmpty(blHw, MM_VERSION_REQ, TASK_MM, 1, MM_VERSION_CFM, cfm)

proc bl_send_start*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
  let req = blMsgZalloc(MM_START_REQ, TASK_MM, DRV_TASK_ID, SizeMmStartReq)
  if req == nil: return -Enomem
  let modp = loadPtr(cast[pointer](blHw), BlHwModParamsOff)
  storeU32(req, MmStartPhyCfgOff, 1)
  if modp != nil:
    storeU32(req, MmStartUapsdTimeoutOff, loadI32(modp, BlModParamsUapsdTimeoutOff).uint32)
    storeU16(req, MmStartLpClkAccuracyOff, loadI32(modp, BlModParamsLpClkPpmOff).uint16)
  blSendMsg(blHw, req, 1, MM_START_CFM, nil)
