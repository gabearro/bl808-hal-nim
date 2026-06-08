proc bl_send_sm_disconnect_req*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
  bl808_wifi_backend_poll(64)
  let req = blMsgZalloc(SM_DISCONNECT_REQ, TASK_SM, DRV_TASK_ID, SizeSmDisconnectReq)
  if req == nil: return -Enomem
  storeU8(req, 0, staVifIdx(blHw))
  blSendMsg(blHw, req, 1, SM_DISCONNECT_CFM, nil)

proc bl_send_sm_connect_abort_req*(blHw: ptr BlHw; cfm: ptr SmAbortCfmObj): cint
    {.exportc, cdecl.} =
  let req = blMsgZalloc(SM_CONNECT_ABORT_REQ, TASK_SM, DRV_TASK_ID, SizeSmConnectAbortReq)
  if req == nil: return -Enomem
  storeU8(req, 0, staVifIdx(blHw))
  blSendMsg(blHw, req, 1, SM_CONNECT_ABORT_CFM, cfm)
