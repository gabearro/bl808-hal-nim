proc cmdMgrQueue(cmdMgr, cmd: pointer): cint {.cdecl.} =
  var deferPush = false
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] queue enter cmd=%p id=0x%x req=0x%x flags=0x%x q=%u\r\n",
             cmd, loadU16(cmd, CmdReqidOff - 2'u).cuint, loadU16(cmd, CmdReqidOff).cuint,
             loadU16(cmd, CmdFlagsOff).cuint, loadU32(cmdMgr, MgrQueueSzOff).cuint)
  cmdMgrLock(cmdMgr)

  if loadU32(cmdMgr, MgrStateOff) == RwnxCmdMgrStateCrashed:
    storeI32(cmd, CmdResultOff, Epipe)
    cmdMgrUnlock(cmdMgr)
    return -Epipe

  let head = ptrAt(cmdMgr, MgrCmdsOff)
  if not listEmpty(head):
    if loadU32(cmdMgr, MgrQueueSzOff) == loadU32(cmdMgr, MgrMaxQueueSzOff):
      storeI32(cmd, CmdResultOff, Enomem)
      cmdMgrUnlock(cmdMgr)
      return -Enomem
    let last = listPrev(head)
    if (loadU16(last, CmdFlagsOff) and (RwnxCmdFlagWaitAck or RwnxCmdFlagWaitPush)) != 0'u16:
      storeU16(cmd, CmdFlagsOff, loadU16(cmd, CmdFlagsOff) or RwnxCmdFlagWaitPush)
      deferPush = true

  var flags = loadU16(cmd, CmdFlagsOff) or RwnxCmdFlagWaitAck
  if (flags and RwnxCmdFlagReqCfm) != 0'u16:
    flags = flags or RwnxCmdFlagWaitCfm
  storeU16(cmd, CmdFlagsOff, flags)
  storeU32(cmd, CmdTknOff, loadU32(cmdMgr, MgrNextTknOff))
  storeU32(cmdMgr, MgrNextTknOff, loadU32(cmdMgr, MgrNextTknOff) + 1'u32)
  storeI32(cmd, CmdResultOff, Eintr)
  if (flags and RwnxCmdFlagNonblock) == 0'u16:
    storePtr(cmd, CmdCompleteOff, osEventCreate())

  listAddTail(cmd, head)
  storeU32(cmdMgr, MgrQueueSzOff, loadU32(cmdMgr, MgrQueueSzOff) + 1'u32)
  cmdMgrUnlock(cmdMgr)

  if not deferPush:
    pushCmdToFirmware(cmdMgr, cmd)

  if (loadU16(cmd, CmdFlagsOff) and RwnxCmdFlagNonblock) == 0'u16:
    let bits = osEventWait(loadPtr(cmd, CmdCompleteOff), 1'u32)
    when defined(bl808WifiCmdTrace):
      c_printf("[WIFI-CMD] wait done cmd=%p bits=0x%x flags=0x%x result=%d\r\n",
               cmd, bits.cuint, loadU16(cmd, CmdFlagsOff).cuint,
               loadI32(cmd, CmdResultOff).cint)
    if (bits and 1'u32) == 0'u32:
      cmdMgrLock(cmdMgr)
      storeU32(cmdMgr, MgrStateOff, RwnxCmdMgrStateCrashed)
      if (loadU16(cmd, CmdFlagsOff) and RwnxCmdFlagDone) == 0'u16:
        storeI32(cmd, CmdResultOff, Etimedout)
        cmdComplete(cmdMgr, cmd)
      cmdMgrUnlock(cmdMgr)
    osEventDelete(loadPtr(cmd, CmdCompleteOff))
  else:
    storeI32(cmd, CmdResultOff, 0'i32)
  0
