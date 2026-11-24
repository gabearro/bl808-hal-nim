const
  BlVifSta = 0'u
  BlVifAp = 1'u
  NxVirtDevMax = WifiHostVifCount.uint8
  NxRemoteStaMax = WifiHostPeerCount.uint8
  NxRemoteStaStoreMax = WifiHostStaTableCount.uint8
  PsModeOff = 0'u8
  StaQosCapa = 1'u32

  BlHwCmdMgrOff = 0'u
  BlHwVifTableOff = 60'u
  BlHwStaTableOff = WifiHostStaTableOffset
  CmdMgrMsgindOff = 36'u
  BlVifSize = 20'u
  BlVifDevOff = 8'u
  BlVifUpOff = 12'u
  BlVifVifIdxOff = 13'u
  BlVifLinksNumOff = 14'u
  BlVifFixedStaIdxOff = 15'u
  BlVifFcChanOff = 16'u
  BlVifStaPsOff = 17'u
  BlStaSize = WifiHostStaEntrySize
  BlStaAddrOff = 16'u
  BlStaIsUsedOff = 22'u
  BlStaStaIdxOff = 23'u
  BlStaVifIdxOff = 24'u
  BlStaFcPsOff = 26'u
  BlStaQosOff = 27'u
  BlStaRssiOff = 28'u
  BlStaDataRateOff = 29'u
  BlStaTsfloOff = 32'u
  BlStaTsfhiOff = 36'u

  IpcMsgIdOff = 0'u
  IpcMsgParamLenOff = 4'u
  IpcMsgParamOff = 8'u
  MsgIndexMask = 1023'u16
