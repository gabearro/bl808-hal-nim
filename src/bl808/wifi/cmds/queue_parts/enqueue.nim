proc cmdMgrQueue(cmdMgr, cmd: pointer): cint {.cdecl.} =
  # The private queue consumes both allocations on every return path.
  let error = if cmdMgr == nil: Einval else: cmdMessageError(cmd)
  if error != 0:
    releaseOwnedCommand(cmd)
    return -error
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] queue cmd=%p id=0x%x req=0x%x flags=0x%x\r\n",
             cmd, loadU16(cmd, CmdReqidOff - 2).cuint,
             loadU16(cmd, CmdReqidOff).cuint, loadU16(cmd, CmdFlagsOff).cuint)
  let nonblock = (loadU16(cmd, CmdFlagsOff) and RwnxCmdFlagNonblock) != 0
  let event = if nonblock: nil else: osEventCreate()
  if not nonblock and event == nil:
    releaseOwnedCommand(cmd)
    return -Enomem

  cmdMgrLock(cmdMgr)
  var rejected = 0'i32
  if not cmdMgrAccepting(cmdMgr): rejected = Epipe
  elif loadU32(cmdMgr, MgrQueueSzOff) >= RwnxCmdMaxQueued or
      loadU32(cmdMgr, MgrQueueSzOff) >= loadU32(cmdMgr, MgrMaxQueueSzOff):
    rejected = Enomem
  if rejected != 0:
    cmdMgrUnlock(cmdMgr)
    if event != nil: osEventDelete(event)
    releaseOwnedCommand(cmd)
    return -rejected

  let head = ptrAt(cmdMgr, MgrCmdsOff)
  var deferred = false
  if not listEmpty(head):
    deferred = (loadU16(listPrev(head), CmdFlagsOff) and
      (RwnxCmdFlagWaitAck or RwnxCmdFlagWaitPush)) != 0
  var flags = loadU16(cmd, CmdFlagsOff) or RwnxCmdFlagWaitAck
  if deferred: flags = flags or RwnxCmdFlagWaitPush
  if (flags and RwnxCmdFlagReqCfm) != 0: flags = flags or RwnxCmdFlagWaitCfm
  storeU16(cmd, CmdFlagsOff, flags)
  storePtr(cmd, CmdCompleteOff, event)
  storeI32(cmd, CmdResultOff, if nonblock: 0'i32 else: Eintr)
  storeU32(cmd, CmdTknOff, loadU32(cmdMgr, MgrNextTknOff))
  storeU32(cmdMgr, MgrNextTknOff, loadU32(cmdMgr, MgrNextTknOff) + 1)
  listAddTail(cmd, head)
  storeU32(cmdMgr, MgrQueueSzOff, loadU32(cmdMgr, MgrQueueSzOff) + 1)
  let status = if deferred: 0.cint else: pushCmdToFirmware(cmdMgr, cmd)
  cmdMgrUnlock(cmdMgr)
  if nonblock: return status

  discard osEventWait(event, 1)
  cmdMgrLock(cmdMgr)
  if (loadU16(cmd, CmdFlagsOff) and RwnxCmdFlagDone) == 0:
    cmdMgrAbort(cmdMgr, cmd, Etimedout)
  let completionError = loadI32(cmd, CmdResultOff)
  let pending = cmdIsQueued(cmdMgr, cmd) and cmdMailboxOwner(cmdMgr) == cmd
  storePtr(cmd, CmdCompleteOff, nil)
  if pending:
    # The waiter may return, but the mailbox still owns this command address.
    storeU16(cmd, CmdFlagsOff, loadU16(cmd, CmdFlagsOff) or RwnxCmdFlagNonblock)
  cmdMgrUnlock(cmdMgr)
  osEventDelete(event)
  if not pending: osFree(cmd)
  -completionError
