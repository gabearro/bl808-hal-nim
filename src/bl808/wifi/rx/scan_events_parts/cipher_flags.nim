proc setCipherFlags(scanIndication: pointer; parsedWpaIes: ptr WifiWpaIe;
                    parsedIeCount: int) =
  var tkip = false
  var ccmp = false
  var groupTkip = false
  var groupCcmp = false
  for parsedIeIndex in 0 ..< parsedIeCount:
    let parsedIe = ptrAt(cast[pointer](parsedWpaIes), uint(parsedIeIndex) * sizeof(WifiWpaIe).uint)
    let proto = cast[ptr cint](ptrAt(parsedIe, 0))[]
    let pairwise = cast[ptr cint](ptrAt(parsedIe, 4))[]
    let group = cast[ptr cint](ptrAt(parsedIe, 8))[]
    let keyMgmt = cast[ptr cint](ptrAt(parsedIe, 12))[]
    if proto == WpaProtoWpa:
      storeU8(scanIndication, WifiBeaconAuthOff, AuthWpaPsk)
    elif proto == WpaProtoRsn:
      if (keyMgmt and (WpaKeyMgmtPsk or WpaKeyMgmtPskSha256)) != 0:
        storeU8(scanIndication, WifiBeaconAuthOff, AuthWpa2Psk)
        if (keyMgmt and WpaKeyMgmtSae) != 0:
          storeU8(scanIndication, WifiBeaconAuthOff, AuthWpa2PskWpa3Sae)
      elif (keyMgmt and WpaKeyMgmtSae) != 0:
        storeU8(scanIndication, WifiBeaconAuthOff, AuthWpa3Sae)
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
  if parsedIeCount == 2:
    storeU8(scanIndication, WifiBeaconAuthOff, AuthWpaWpa2Psk)
  elif parsedIeCount == 0:
    storeU8(scanIndication, WifiBeaconAuthOff, AuthWep)
    storeU8(scanIndication, WifiBeaconCipherOff, CipherWep)
  if ccmp:
    storeU8(scanIndication, WifiBeaconCipherOff, CipherAes)
  if tkip:
    storeU8(scanIndication, WifiBeaconCipherOff, CipherTkip)
  if tkip and ccmp:
    storeU8(scanIndication, WifiBeaconCipherOff, CipherTkipAes)
  if groupCcmp:
    storeU8(scanIndication, WifiBeaconGroupCipherOff, CipherAes)
  if groupTkip:
    storeU8(scanIndication, WifiBeaconGroupCipherOff, CipherTkip)
  if groupTkip and groupCcmp:
    storeU8(scanIndication, WifiBeaconGroupCipherOff, CipherTkipAes)
