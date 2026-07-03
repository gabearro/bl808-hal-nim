const
  RwnxCmdMaxQueued = 8'u32
  RwnxCmdFlagNonblock = 1'u16 shl 0
  RwnxCmdFlagReqCfm = 1'u16 shl 1
  RwnxCmdFlagWaitPush = 1'u16 shl 2
  RwnxCmdFlagWaitAck = 1'u16 shl 3
  RwnxCmdFlagWaitCfm = 1'u16 shl 4
  RwnxCmdFlagDone = 1'u16 shl 5
  RwnxCmdMgrStateCrashed = 2'u32

  # Bounded wait (in os-event "ticks") for a blocking command's CFM. The blob
  # waited FOREVER (BlOsWaitingForever) here; when the RF/MAC is dead after a
  # reconnect's bl_send_reset the CFM never arrives and the whole cooperative
  # scheduler hangs (JTAG-confirmed: rawDelay<-osEventGroupWait<-cmd-mgr wait,
  # blocking a reconnect permanently). osEventGroupWait spins loops =
  # blockTimeTick*64 iterations of vendorPollOnce()+rawDelay(128), reading NO
  # mtime, so this bound is immune to the reconnect mtime-clock freeze. A
  # healthy CFM sets the event bit and returns immediately, so this only bounds
  # the DEAD case and never false-times-out a live command. On expiry the
  # cmd-mgr marks itself Crashed + returns Etimedout (enqueue.nim), so the
  # recovery returns to the scheduler instead of wedging. Calibrated so one
  # dead wait stays a few seconds and 3x is well under the WDT window.
  WifiCmdWaitTicks {.intdefine.} = 200'u32

  Eintr = 4'i32
  Enomem = 12'i32
  Epipe = 32'i32
  Etimedout = 110'i32

  BlHwIpcEnvOff = 0x30'u

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
