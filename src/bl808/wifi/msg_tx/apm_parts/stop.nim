proc bl_send_apm_stop_req*(blHw: ptr BlHw; vifIdx: uint8): cint {.exportc, cdecl.} =
  let req = blMsgZalloc(APM_STOP_REQ, TASK_APM, DRV_TASK_ID, SizeApmStopReq)
  if req == nil: return -Enomem
  storeU8(req, 0, vifIdx)
  blSendMsg(blHw, req, 1, APM_STOP_CFM, nil)
