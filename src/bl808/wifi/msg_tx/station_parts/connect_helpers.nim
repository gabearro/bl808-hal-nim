proc usePairwiseKey(crypto: pointer): bool {.inline.} =
  let group = loadU32(crypto, CryptoCipherGroupOff)
  group != WLAN_CIPHER_SUITE_WEP40 and group != WLAN_CIPHER_SUITE_WEP104

proc macIsSpecial(mac: pointer; value: uint8): bool =
  if mac == nil:
    return false
  for i in 0 ..< 6:
    if cast[ptr UncheckedArray[uint8]](mac)[i] != value:
      return false
  true
