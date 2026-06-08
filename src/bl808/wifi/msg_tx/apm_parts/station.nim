proc bl_send_apm_sta_del_req*(blHw: ptr BlHw; cfm: ptr ApmStaDelCfmObj;
                              staIdx, vifIdx: uint8): cint {.exportc, cdecl.} =
  let req = blMsgZalloc(APM_STA_DEL_REQ, TASK_APM, DRV_TASK_ID, SizeApmStaDelReq)
  if req == nil: return -Enomem
  storeU8(req, 0, vifIdx)
  storeU8(req, 1, staIdx)
  blSendMsg(blHw, req, 1, APM_STA_DEL_CFM, cfm)
