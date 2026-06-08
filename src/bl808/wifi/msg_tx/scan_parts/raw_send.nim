proc bl_send_scanu_raw_send*(blHw: ptr BlHw; pkt: ptr uint8; len: cint): cint
    {.exportc, cdecl.} =
  var cfm: array[1, uint8]
  let req = blMsgZalloc(SCANU_RAW_SEND_REQ, TASK_SCANU, DRV_TASK_ID, SizeScanuRawSendReq)
  if req == nil: return -Enomem
  storePtr(req, ScanuRawPktOff, pkt)
  storeU32(req, ScanuRawLenOff, len.uint32)
  blSendMsg(blHw, req, 1, SCANU_RAW_SEND_CFM, addr cfm[0])
