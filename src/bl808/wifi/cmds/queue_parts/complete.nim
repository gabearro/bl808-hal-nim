proc cmdComplete(cmdMgr, cmd: pointer) =
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] complete cmd=%p id=0x%x req=0x%x flags=0x%x result=%d q=%u\r\n",
             cmd, loadU16(cmd, CmdReqidOff - 2'u).cuint, loadU16(cmd, CmdReqidOff).cuint,
             loadU16(cmd, CmdFlagsOff).cuint, loadI32(cmd, CmdResultOff).cint,
             loadU32(cmdMgr, MgrQueueSzOff).cuint)
  storeU32(cmdMgr, MgrQueueSzOff, loadU32(cmdMgr, MgrQueueSzOff) - 1'u32)
  listDel(cmd)
  let flags = loadU16(cmd, CmdFlagsOff) or RwnxCmdFlagDone
  storeU16(cmd, CmdFlagsOff, flags)
  if (flags and RwnxCmdFlagNonblock) != 0'u16:
    osFree(cmd)
  elif waitComplete(flags):
    storeI32(cmd, CmdResultOff, 0'i32)
    osEventSend(loadPtr(cmd, CmdCompleteOff), 1'u32)
