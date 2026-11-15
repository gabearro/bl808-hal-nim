var
  nimFwDbgCmdFailed* {.exportc: "nimfw_dbg_cmd_failed".}: uint32
  nimFwDbgCmdLastError* {.exportc: "nimfw_dbg_cmd_last_error".}: int32

proc cmdMgrAccepting(cmdMgr: pointer): bool {.inline.} =
  loadU32(cmdMgr, MgrStateOff) notin
    [RwnxCmdMgrStateCrashed, RwnxCmdMgrStateDraining]

proc cmdMailboxOwner(cmdMgr: pointer): pointer {.inline.} =
  let env = loadPtr(cmdMgr, BlHwIpcEnvOff)
  if env == nil: nil else: loadPtr(env, CmdIpcOwnerOff)

proc cmdIsQueued(cmdMgr, cmd: pointer): bool =
  if cmd == nil: return false
  let head = ptrAt(cmdMgr, MgrCmdsOff)
  var node = listNext(head)
  for index in 0 ..< RwnxCmdMaxQueued.int:
    if node == head or node == nil: return false
    if node == cmd: return true
    node = listNext(node)

proc cmdUnlink(cmdMgr, cmd: pointer) =
  listDel(cmd)
  let count = loadU32(cmdMgr, MgrQueueSzOff)
  if count != 0: storeU32(cmdMgr, MgrQueueSzOff, count - 1)

proc takeCmdSource(cmd: pointer): pointer {.inline.} =
  result = loadPtr(cmd, CmdA2eMsgOff)
  storePtr(cmd, CmdA2eMsgOff, nil)

proc releaseOwnedCommand(cmd: pointer) =
  if cmd == nil: return
  let source = takeCmdSource(cmd)
  if source != nil: osFree(source)
  osFree(cmd)

proc cmdMessageError(cmd: pointer): int32 =
  if cmd == nil: return Einval
  let source = loadPtr(cmd, CmdA2eMsgOff)
  if source == nil: return Einval
  if loadU32(source, LmacMsgParamLenOff) > CmdMaxParamLen: return Emsgsize

proc finishCommand(cmdMgr, cmd: pointer; error: int32) =
  if not cmdIsQueued(cmdMgr, cmd): return
  var flags = loadU16(cmd, CmdFlagsOff)
  if (flags and RwnxCmdFlagDone) == 0:
    storeI32(cmd, CmdResultOff, error)
    if error != 0:
      inc nimFwDbgCmdFailed
      nimFwDbgCmdLastError = error
  flags = (flags or RwnxCmdFlagDone) and
    not (RwnxCmdFlagWaitPush or RwnxCmdFlagWaitCfm)
  let pending = cmdMailboxOwner(cmdMgr) == cmd
  if not pending:
    flags = flags and not RwnxCmdFlagWaitAck
    cmdUnlink(cmdMgr, cmd)
  storeU16(cmd, CmdFlagsOff, flags)
  if error != 0: storePtr(cmd, CmdE2aMsgOff, nil)
  let source = takeCmdSource(cmd)
  let event = loadPtr(cmd, CmdCompleteOff)
  let nonblock = (flags and RwnxCmdFlagNonblock) != 0
  # Keep a published command alive until its ACK, and a callback's command
  # alive until that callback returns. Neither retains the caller's buffer.
  if not pending and nonblock and (flags and RwnxCmdFlagCallback) == 0:
    osFree(cmd)
  elif not nonblock and event != nil:
    osEventSend(event, 1)
  if source != nil: osFree(source)

proc cmdMgrAbort(cmdMgr, primary: pointer; error: int32) =
  if loadU32(cmdMgr, MgrStateOff) == RwnxCmdMgrStateDraining: return
  storeU32(cmdMgr, MgrStateOff, RwnxCmdMgrStateDraining)
  let head = ptrAt(cmdMgr, MgrCmdsOff)
  for attempt in 0 ..< RwnxCmdMaxQueued.int:
    var node = listNext(head)
    while node != head and (loadU16(node, CmdFlagsOff) and RwnxCmdFlagDone) != 0:
      node = listNext(node)
    if node == head: break
    finishCommand(cmdMgr, node, if node == primary: error else: Epipe)
  storeU32(cmdMgr, MgrStateOff, RwnxCmdMgrStateCrashed)
