proc fillScanChan(scanRequest: pointer; channelEntryByteOffset: uint; channelIndex: int; scanFlags: uint8; txPower: uint8) =
  storeU16(scanRequest, channelEntryByteOffset + ScanChanFreqOff, channelFreq(channelIndex))
  storeU8(scanRequest, channelEntryByteOffset + ScanChanBandOff, NL80211_BAND_2GHZ)
  storeU8(scanRequest, channelEntryByteOffset + ScanChanFlagsOff, scanFlags)
  storeU8(scanRequest, channelEntryByteOffset + ScanChanTxPowerOff, txPower)
