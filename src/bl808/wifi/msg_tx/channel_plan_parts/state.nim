var channelNumDefault: int32
var countryCode0: uint8
var countryCode1: uint8
var countryMaxPower: uint8

proc channelFreq(index: int): uint16 {.inline.} =
  if index == 13: 2484'u16 else: (2412 + index * 5).uint16

proc passiveScanFlag(flags: uint32): uint8 {.inline.} =
  if (flags and (IEEE80211_CHAN_NO_IR or IEEE80211_CHAN_RADAR)) != 0'u32:
    SCAN_PASSIVE_BIT
  else:
    0'u8
