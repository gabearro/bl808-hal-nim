proc setCipherFlags(indNew: pointer; parsed: ptr WifiWpaIe; parsedLen: int) =
  var tkip = false
  var ccmp = false
  var groupTkip = false
  var groupCcmp = false
  for i in 0 ..< parsedLen:
    let ie = ptrAt(cast[pointer](parsed), uint(i) * sizeof(WifiWpaIe).uint)
    let proto = cast[ptr cint](ptrAt(ie, 0))[]
    let pairwise = cast[ptr cint](ptrAt(ie, 4))[]
    let group = cast[ptr cint](ptrAt(ie, 8))[]
    let keyMgmt = cast[ptr cint](ptrAt(ie, 12))[]
    if proto == WpaProtoWpa:
      storeU8(indNew, WifiBeaconAuthOff, AuthWpaPsk)
    elif proto == WpaProtoRsn:
      if (keyMgmt and (WpaKeyMgmtPsk or WpaKeyMgmtPskSha256)) != 0:
        storeU8(indNew, WifiBeaconAuthOff, AuthWpa2Psk)
        if (keyMgmt and WpaKeyMgmtSae) != 0:
          storeU8(indNew, WifiBeaconAuthOff, AuthWpa2PskWpa3Sae)
      elif (keyMgmt and WpaKeyMgmtSae) != 0:
        storeU8(indNew, WifiBeaconAuthOff, AuthWpa3Sae)
    for cipher in [pairwise, group]:
      if cipher == WifiCipherTkip:
        tkip = true
        if cipher == group:
          groupTkip = true
      if cipher == WifiCipherCcmp:
        ccmp = true
        if cipher == group:
          groupCcmp = true
      if cipher == WifiCipherTkipCcmp:
        tkip = true
        ccmp = true
        if cipher == group:
          groupTkip = true
          groupCcmp = true
  if parsedLen == 2:
    storeU8(indNew, WifiBeaconAuthOff, AuthWpaWpa2Psk)
  elif parsedLen == 0:
    storeU8(indNew, WifiBeaconAuthOff, AuthWep)
    storeU8(indNew, WifiBeaconCipherOff, CipherWep)
  if ccmp:
    storeU8(indNew, WifiBeaconCipherOff, CipherAes)
  if tkip:
    storeU8(indNew, WifiBeaconCipherOff, CipherTkip)
  if tkip and ccmp:
    storeU8(indNew, WifiBeaconCipherOff, CipherTkipAes)
  if groupCcmp:
    storeU8(indNew, WifiBeaconGroupCipherOff, CipherAes)
  if groupTkip:
    storeU8(indNew, WifiBeaconGroupCipherOff, CipherTkip)
  if groupTkip and groupCcmp:
    storeU8(indNew, WifiBeaconGroupCipherOff, CipherTkipAes)
