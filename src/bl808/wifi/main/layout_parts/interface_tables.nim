const
  BlVifSta = 0'u
  BlVifAp = 1'u
  NxVirtDevMax = WifiHostVifCount.uint
  NxRemoteStaStoreMax = WifiHostStaTableCount.uint

  BlHwIpcEnvOff = 48'u
  BlHwVifsOff = 52'u
  BlHwVifTableOff = 60'u
  BlHwStaTableOff = WifiHostStaTableOffset
  BlHwModParamsOff = WifiHostModParamsOffset

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
  BlStaQosOff = 27'u
  BlStaRssiOff = 28'u
  BlStaRateOff = 29'u
  BlStaTsfloOff = 32'u
  BlStaTsfhiOff = 36'u

  NetifHwaddrOff = 58'u
