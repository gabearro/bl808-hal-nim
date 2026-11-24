const
  RwnxCmdMaxQueued = 8'u32
  RwnxCmdFlagNonblock = 1'u16 shl 0
  RwnxCmdFlagReqCfm = 1'u16 shl 1
  RwnxCmdFlagWaitPush = 1'u16 shl 2
  RwnxCmdFlagWaitAck = 1'u16 shl 3
  RwnxCmdFlagWaitCfm = 1'u16 shl 4
  RwnxCmdFlagDone = 1'u16 shl 5
  RwnxCmdFlagCallback = 1'u16 shl 6
  RwnxCmdMgrStateCrashed = 2'u32
  RwnxCmdMgrStateDraining = 3'u32

  # The cooperative adapter treats a wait tick as 1 ms. A timed-out command
  # still owned by the mailbox survives until ACK.
  WifiCmdWaitTicks {.intdefine.} = 200'u32

  Eintr = 4'i32
  Eio = 5'i32
  Enomem = 12'i32
  Einval = 22'i32
  Epipe = 32'i32
  Emsgsize = 90'i32
  Etimedout = 110'i32
  CmdMaxParamLen = 500'u32

  BlHwIpcEnvOff = 0x30'u
  CmdIpcSharedOff = 32'u
  CmdIpcOwnerOff = 88'u

  MgrStateOff = 0'u
  MgrNextTknOff = 4'u
  MgrQueueSzOff = 8'u
  MgrMaxQueueSzOff = 12'u
  MgrCmdsOff = 16'u
  MgrLockOff = 24'u
  MgrQueueOff = 28'u
  MgrLlindOff = 32'u
  MgrMsgindOff = 36'u
  MgrPrintOff = 40'u
  MgrDrainOff = 44'u

  CmdReqidOff = 10'u
  CmdA2eMsgOff = 12'u
  CmdE2aMsgOff = 16'u
  CmdTknOff = 20'u
  CmdFlagsOff = 24'u
  CmdCompleteOff = 28'u
  CmdResultOff = 32'u

  LmacMsgParamLenOff = 4'u
  LmacMsgHeaderLen = 8'u16

  IpcE2aMsgIdOff = 0'u
  IpcE2aMsgParamLenOff = 4'u
  IpcE2aMsgParamOff = 8'u

  OpEventGroupCreateOff = 36'u
  OpEventGroupDeleteOff = 40'u
  OpEventGroupSendOff = 44'u
  OpEventGroupWaitOff = 48'u
  OpMutexCreateOff = 148'u
  OpMutexLockOff = 156'u
  OpMutexUnlockOff = 160'u
  OpFreeOff = 188'u
