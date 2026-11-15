proc cmdMgrLlind(cmdMgr, cmd: pointer): cint {.cdecl.} =
  cmdMgrLock(cmdMgr)
  if cmdIsQueued(cmdMgr, cmd):
    let flags = loadU16(cmd, CmdFlagsOff) and not RwnxCmdFlagWaitAck
    storeU16(cmd, CmdFlagsOff, flags)
    if waitComplete(flags): cmdComplete(cmdMgr, cmd)
    # Completion can dispatch nested work; select from the current list.
    pushNextCommand(cmdMgr)
  cmdMgrUnlock(cmdMgr)
  0
