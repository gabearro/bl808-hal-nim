proc fillScanChan(req: pointer; off: uint; index: int; flags: uint8; txPower: uint8) =
  storeU16(req, off + ScanChanFreqOff, channelFreq(index))
  storeU8(req, off + ScanChanBandOff, NL80211_BAND_2GHZ)
  storeU8(req, off + ScanChanFlagsOff, flags)
  storeU8(req, off + ScanChanTxPowerOff, txPower)
