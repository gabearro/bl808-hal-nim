const
  TaskMM = 0'u16
  TaskScanu = 2'u16
  TaskMe = 3'u16
  TaskSm = 4'u16
  TaskApm = 5'u16
  TaskCfg = 8'u16

  MmChannelSwitchI = 50'u16
  MmChannelPreSwitchI = 51'u16
  MmRemainOnChannelExpI = 54'u16
  MmPsChangeI = 55'u16
  MmTrafficReqI = 56'u16
  MmChannelSurveyI = 60'u16
  MmRssiStatusI = 67'u16
  ScanuStartCfmI = 1'u16
  ScanuJoinCfmI = 3'u16
  ScanuResultI = 4'u16
  MeTkipMicFailureI = 4'u16
  MeTxCreditsUpdateI = 9'u16
  SmConnectI = 2'u16
  SmDisconnectI = 5'u16
  SmStaAddI = 10'u16
  ApmStaAddI = 4'u16
  ApmStaDelI = 5'u16
