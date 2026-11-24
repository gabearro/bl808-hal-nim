proc bl_send_scanu_raw_send*(blHw: ptr BlHw; pkt: ptr uint8; len: cint): cint
    {.exportc, cdecl.} =
  var cfm: uint32  # SCANU_RAW_SEND_CFM carries one 32-bit result
  let req = blMsgZalloc(SCANU_RAW_SEND_REQ, TASK_SCANU, DRV_TASK_ID, SizeScanuRawSendReq)
  if req == nil: return -Enomem
  storePtr(req, ScanuRawPktOff, pkt)
  storeU32(req, ScanuRawLenOff, len.uint32)
  result = blSendMsg(blHw, req, 1, SCANU_RAW_SEND_CFM, addr cfm)
  # The firmware confirms with a nonzero result when it refuses the frame.
  if result == 0 and cfm != 0: result = -Ebusy
