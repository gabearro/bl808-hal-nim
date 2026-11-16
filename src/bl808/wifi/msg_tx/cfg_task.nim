proc bl_send_cfg_task_req*(blHw: ptr BlHw; ops, task, element, typ: uint32;
                           arg1, arg2: pointer): cint {.exportc, cdecl.} =
  if ops == 0'u32 and (arg1 == nil or typ notin [1'u32, 7'u32]):
    return -2
  let req = blMsgZalloc(CFG_START_REQ, TASK_CFG, DRV_TASK_ID, SizeCfgStartReq)
  if req == nil: return -Enomem
  storeU32(req, CfgOpsOff, ops)
  case ops
  of 0'u32:
    storeU32(req, CfgSetTaskOff, task)
    storeU32(req, CfgSetElementOff, element)
    storeU32(req, CfgSetTypeOff, typ)
    storeU32(req, CfgSetLengthOff,
             cast[uint32](utils_tlv_bl_pack_auto(cast[ptr uint32](ptrAt(req, CfgSetBufOff)), 8, cast[uint16](typ), arg1)))
  of 3'u32:
    storeU32(req, CfgSetTaskOff, task)
    storeU32(req, CfgSetElementOff, element)
    storeU32(req, CfgSetLengthOff, 0)
  else:
    discard
  blSendMsg(blHw, req, 1, CFG_START_CFM, nil)
