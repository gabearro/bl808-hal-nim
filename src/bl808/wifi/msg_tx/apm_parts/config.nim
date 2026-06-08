proc bl_send_apm_conf_max_sta_req*(blHw: ptr BlHw; maxStaSupported: uint8): cint
    {.exportc, cdecl.} =
  let req = blMsgZalloc(APM_CONF_MAX_STA_REQ, TASK_APM, DRV_TASK_ID,
                        SizeApmConfMaxStaReq)
  if req == nil: return -Enomem
  storeU8(req, 0, maxStaSupported)
  blSendMsg(blHw, req, 1, APM_CONF_MAX_STA_CFM, nil)
