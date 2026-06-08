proc blMsgZalloc(id: uint16; dest, src: uint8; paramLen: uint16): pointer =
  let msg = osMalloc(LmacMsgHeaderLen + paramLen.uint)
  if msg == nil:
    bl_os_printf("%s: msg allocation failed\n", "bl_msg_zalloc")
    return nil
  zero(msg, LmacMsgHeaderLen + paramLen.uint)
  storeU16(msg, LmacMsgIdOff, id)
  storeU8(msg, LmacMsgDestIdOff, dest)
  storeU8(msg, LmacMsgSrcIdOff, src)
  storeU16(msg, LmacMsgParamLenOff, paramLen)
  ptrAt(msg, LmacMsgParamOff)

proc isNonBlockingMsg(id: uint16): bool {.inline.} =
  id == MM_TIM_UPDATE_REQ or id == ME_RC_SET_RATE_REQ or
    id == MM_BFMER_ENABLE_REQ or id == ME_TRAFFIC_IND_REQ or
    id == SM_DISCONNECT_REQ

proc blSendMsg(blHw: ptr BlHw; msgParams: pointer; reqcfm: cint;
               reqid: uint16; cfm: pointer): cint =
  let hw = cast[pointer](blHw)
  let msg = ptrAt(msgParams, 0'u - LmacMsgHeaderLen)
  if loadPtr(hw, BlHwIpcEnvOff) == nil:
    bl_os_printf("%s: bypassing (restart must have failed)\r\n", "bl_send_msg")
    osFree(msg)
    return -Ebusy

  let cmd = osMalloc(BlCmdSize)
  if cmd == nil:
    osFree(msg)
    bl_os_printf("%s: failed to allocate mem for cmd, size is %d\r\n",
                 "bl_send_msg", BlCmdSize.cint)
    return -Enomem
  zero(cmd, BlCmdSize)

  let id = loadU16(msg, LmacMsgIdOff)
  storeI32(cmd, BlCmdResultOff, Eintr)
  storeU16(cmd, BlCmdIdOff, id)
  storeU16(cmd, BlCmdReqidOff, reqid)
  storePtr(cmd, BlCmdA2eMsgOff, msg)
  storePtr(cmd, BlCmdE2aMsgOff, cfm)
  var flags = 0'u16
  let nonblock = isNonBlockingMsg(id)
  if nonblock:
    flags = flags or RwnxCmdFlagNonblock
  if reqcfm != 0:
    flags = flags or RwnxCmdFlagReqCfm
  storeU16(cmd, BlCmdFlagsOff, flags)

  let queue = cast[CmdQueueProc](loadPtr(hw, BlHwCmdMgrQueueOff))
  var ret = if queue == nil: -Ebusy else: queue(hw, cmd)
  if not nonblock:
    osFree(cmd)
  else:
    ret = loadI32(cmd, BlCmdResultOff).cint
  ret

proc sendEmpty(blHw: ptr BlHw; id: uint16; dest: uint8; reqcfm: cint;
               reqid: uint16; cfm: pointer): cint =
  let req = blMsgZalloc(id, dest, DRV_TASK_ID, 0)
  if req == nil: -Enomem else: blSendMsg(blHw, req, reqcfm, reqid, cfm)

proc staVifIdx(blHw: ptr BlHw): uint8 {.inline.} =
  loadU8(ptrAt(cast[pointer](blHw), BlHwVifTableOff), BlVifVifIdxOff)
