## Reused channel, SSID, rate-set, and HT capability payload fragments.

const
  ScanChanSize = 6'u
  ScanChanFreqOff = 0'u
  ScanChanBandOff = 2'u
  ScanChanFlagsOff = 3'u
  ScanChanTxPowerOff = 4'u

  MacSsidLengthOff = 0'u
  MacSsidArrayOff = 1'u
  MacSsidSize = 34'u
  MacRatesetLengthOff = 0'u
  MacRatesetArrayOff = 1'u

  MacHtCapInfoOff = 0'u
  MacHtAmpduOff = 2'u
  MacHtMcsRateOff = 3'u
  MacHtExtCapOff = 20'u
  MacHtBeamformOff = 24'u
  MacHtAselOff = 28'u
