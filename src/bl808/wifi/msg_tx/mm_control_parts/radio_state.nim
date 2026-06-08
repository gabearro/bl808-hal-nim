proc bl_send_mm_powersaving_req*(blHw: ptr BlHw; mode: cint): cint
    {.exportc, cdecl.} =
  let req = blMsgZalloc(MM_SET_PS_MODE_REQ, TASK_MM, DRV_TASK_ID, SizeMmSetPsModeReq)
  if req == nil: return -Enomem
  storeU8(req, 0, mode.uint8)
  blSendMsg(blHw, req, 1, MM_SET_PS_MODE_CFM, nil)

proc bl_send_mm_denoise_req*(blHw: ptr BlHw; mode: cint): cint {.exportc, cdecl.} =
  let req = blMsgZalloc(MM_DENOISE_REQ, TASK_MM, DRV_TASK_ID, SizeMmSetDenoiseReq)
  if req == nil: return -Enomem
  storeU8(req, 0, mode.uint8)
  blSendMsg(blHw, req, 1, MM_SET_PS_MODE_CFM, nil)
