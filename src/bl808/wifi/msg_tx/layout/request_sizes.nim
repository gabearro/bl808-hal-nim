## Firmware request payload sizes.

const
  SizeMmMonitorReq = 4'u16
  SizeMmBeaconIntReq = 4'u16
  SizeMmMonitorChannelReq = 4'u16
  SizeMeConfigReq = 52'u16
  SizeMeChanConfigReq = 86'u16
  SizeMeRcSetRateReq = 6'u16
  SizeMmStartReq = 72'u16
  SizeMmAddIfReq = 8'u16
  SizeMmRemoveIfReq = 1'u16
  SizeScanuStartReq = 320'u16
  SizeScanuRawSendReq = 8'u16
  SizeSmConnectReq = 192'u16
  SizeSmDisconnectReq = 1'u16
  SizeSmConnectAbortReq = 1'u16
  SizeMmSetPsModeReq = 1'u16
  SizeMmSetDenoiseReq = 1'u16
  SizeApmStartReq = 236'u16
  SizeApmStopReq = 1'u16
  SizeApmStaDelReq = 2'u16
  SizeApmConfMaxStaReq = 1'u16
  SizeCfgStartReq = 36'u16
  SizeMmSetChannelReq = 10'u16
