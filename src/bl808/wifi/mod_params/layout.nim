from ../host_table_layout import WifiHostModParamsOffset, WifiHostHtCapOffset

const
  BlHwModParamsOff* = WifiHostModParamsOffset
  BlHwHtCapOff* = WifiHostHtCapOffset

  HtCapCapOff* = 0'u
  HtCapHtSupportedOff* = 2'u
  HtCapMcsRxMaskOff* = 6'u
  HtCapMcsRxHighestOff* = 16'u

  BlModParamsPhyCfgOff* = 8'u
  BlModParamsMcsMapOff* = 4'u
  BlModParamsSgiOff* = 16'u
  BlModParamsHtOnOff* = 0'u

  Ieee80211HtCapRxStbcShift* = 8
  Ieee80211HtCapSgi20* = 0x0020'u16
  Ieee80211HtCapSmPs* = 0x000c'u16
