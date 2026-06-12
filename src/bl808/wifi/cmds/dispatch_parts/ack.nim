proc cmdMgrLlind(cmdMgr, cmd: pointer): cint {.cdecl.} =
  var acked: pointer = nil
  var nextCmd: pointer = nil
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] ack enter hostid=%p tkn=%u flags=0x%x\r\n",
             cmd, loadU32(cmd, CmdTknOff).cuint, loadU16(cmd, CmdFlagsOff).cuint)
  cmdMgrLock(cmdMgr)
  let head = ptrAt(cmdMgr, MgrCmdsOff)
  var queuedCmd = listNext(head)
  while queuedCmd != head:
    if acked == nil:
      if loadU32(queuedCmd, CmdTknOff) == loadU32(cmd, CmdTknOff):
        acked = queuedCmd
        queuedCmd = listNext(queuedCmd)
        continue
    if (loadU16(queuedCmd, CmdFlagsOff) and RwnxCmdFlagWaitPush) != 0'u16:
      nextCmd = queuedCmd
      break
    queuedCmd = listNext(queuedCmd)

  if acked != nil:
    when defined(bl808WifiCmdTrace):
      c_printf("[WIFI-CMD] ack found acked=%p hostid=%p tkn=%u\r\n",
               acked, cmd, loadU32(cmd, CmdTknOff).cuint)
    let flags = loadU16(cmd, CmdFlagsOff) and not RwnxCmdFlagWaitAck
    storeU16(cmd, CmdFlagsOff, flags)
    if waitComplete(flags):
      cmdComplete(cmdMgr, cmd)

  if nextCmd != nil:
    storeU16(nextCmd, CmdFlagsOff, loadU16(nextCmd, CmdFlagsOff) and not RwnxCmdFlagWaitPush)
    pushCmdToFirmware(cmdMgr, nextCmd)
  cmdMgrUnlock(cmdMgr)
  0
