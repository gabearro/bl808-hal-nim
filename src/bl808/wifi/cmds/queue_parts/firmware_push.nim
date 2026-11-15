proc pushCmdToFirmware(cmdMgr, cmd: pointer): cint =
  let error = cmdMessageError(cmd)
  if error != 0:
    cmdMgrAbort(cmdMgr, cmd, error)
    return -error
  let source = loadPtr(cmd, CmdA2eMsgOff)
  let length = LmacMsgHeaderLen + loadU32(source, LmacMsgParamLenOff).uint16
  let status = ipc_host_msg_push(loadPtr(cmdMgr, BlHwIpcEnvOff), cmd, length)
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] push cmd=%p len=%u status=%d\r\n", cmd, length.cuint, status)
  if status != 0:
    cmdMgrAbort(cmdMgr, cmd, Eio)
    return -Eio
  discard takeCmdSource(cmd)
  osFree(source)
  0

proc pushNextCommand(cmdMgr: pointer) =
  if not cmdMgrAccepting(cmdMgr) or cmdMailboxOwner(cmdMgr) != nil: return
  let head = ptrAt(cmdMgr, MgrCmdsOff)
  var node = listNext(head)
  while node != head:
    let flags = loadU16(node, CmdFlagsOff)
    if (flags and RwnxCmdFlagWaitPush) != 0:
      storeU16(node, CmdFlagsOff, flags and not RwnxCmdFlagWaitPush)
      discard pushCmdToFirmware(cmdMgr, node)
      return
    node = listNext(node)
