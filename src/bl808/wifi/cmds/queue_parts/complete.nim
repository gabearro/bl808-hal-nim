proc cmdComplete(cmdMgr, cmd: pointer) =
  finishCommand(cmdMgr, cmd, 0)
