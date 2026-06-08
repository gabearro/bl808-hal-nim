## Host driver, command-manager, and LMAC message envelope layout.

const
  Enomem = 12.cint
  Ebusy = 16.cint
  Eintr = 4'i32

  RwnxCmdFlagNonblock = 1'u16 shl 0
  RwnxCmdFlagReqCfm = 1'u16 shl 1

  OpMallocOff = 184'u
  OpFreeOff = 188'u

  BlHwIpcEnvOff = 48'u
  BlHwVifTableOff = 60'u
  BlHwModParamsOff = 220'u
  BlHwHtCapOff = 224'u
  BlVifSize = 20'u
  BlVifVifIdxOff = 13'u

  BlModParamsUapsdTimeoutOff = 12'u
  BlModParamsListenItvOff = 20'u
  BlModParamsListenBcmcOff = 24'u
  BlModParamsLpClkPpmOff = 28'u
  BlModParamsPsOnOff = 32'u
  BlModParamsTxLftOff = 36'u
  BlModParamsUapsdQueuesOff = 44'u

  HtCapCapOff = 0'u
  HtCapMcsOff = 6'u

  LmacMsgIdOff = 0'u
  LmacMsgDestIdOff = 2'u
  LmacMsgSrcIdOff = 3'u
  LmacMsgParamLenOff = 4'u
  LmacMsgParamOff = 8'u
  LmacMsgHeaderLen = 8'u

  BlCmdSize = 36'u
  BlCmdIdOff = 8'u
  BlCmdReqidOff = 10'u
  BlCmdA2eMsgOff = 12'u
  BlCmdE2aMsgOff = 16'u
  BlCmdFlagsOff = 24'u
  BlCmdResultOff = 32'u
  BlHwCmdMgrQueueOff = 28'u
