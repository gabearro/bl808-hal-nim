proc bl_send_sm_connect_req*(blHw: ptr BlHw; sme: ptr Cfg80211ConnectParams;
                             cfm: ptr SmConnectCfmObj): cint {.exportc, cdecl.} =
  let req = blMsgZalloc(SM_CONNECT_REQ, TASK_SM, DRV_TASK_ID, SizeSmConnectReq)
  if req == nil: return -Enomem
  let smeRaw = cast[pointer](sme)
  let crypto = ptrAt(smeRaw, ConnCryptoOff)
  var flags = loadU32(smeRaw, ConnFlagsOff)
  when defined(bl808WifiForceLegacyRates):
    flags = flags or DISABLE_HT
  when defined(bl808WifiConnectCfg80211Flags):
    if loadU32(crypto, CryptoNCiphersOff) != 0'u32:
      let cipher = loadU32(crypto, CryptoCiphers0Off)
      if cipher == WLAN_CIPHER_SUITE_WEP40 or cipher == WLAN_CIPHER_SUITE_TKIP or
          cipher == WLAN_CIPHER_SUITE_WEP104:
        flags = flags or DISABLE_HT
    if loadU8(crypto, CryptoControlPortOff) != 0'u8:
      flags = flags or CONTROL_PORT_HOST
    if loadU8(crypto, CryptoControlNoEncOff) != 0'u8:
      flags = flags or CONTROL_PORT_NO_ENC
    if usePairwiseKey(crypto):
      flags = flags or WPA_WPA2_IN_USE
    if loadU32(smeRaw, ConnMfpOff) == NL80211_MFP_REQUIRED:
      flags = flags or MFP_IN_USE
  storeU16(req, SmCtrlPortEthertypeOff, smControlPortEthertype(crypto))

  let bssid = loadPtr(smeRaw, ConnBssidOff)
  if bssid != nil and not macIsSpecial(bssid, 0xff) and not macIsSpecial(bssid, 0):
    copyMem(ptrAt(req, SmBssidOff), bssid, 6)
  else:
    for i in 0 ..< 6:
      storeU8(req, SmBssidOff + i.uint, 0xff)

  storeU8(req, SmVifIdxOff, staVifIdx(blHw))
  if loadU16(smeRaw, ConnChannelOff + ConnChanFreqOff) != 0'u16:
    storeU8(req, SmChanOff + ScanChanBandOff, loadU8(smeRaw, ConnChannelOff + ConnChanBandOff))
    storeU16(req, SmChanOff + ScanChanFreqOff, loadU16(smeRaw, ConnChannelOff + ConnChanFreqOff))
    storeU8(req, SmChanOff + ScanChanFlagsOff,
            passiveScanFlag(loadU32(smeRaw, ConnChannelOff + ConnChanFlagsOff)))
  else:
    storeU16(req, SmChanOff + ScanChanFreqOff, 0xffff'u16)

  let ssid = loadPtr(smeRaw, ConnSsidOff)
  let ssidLen = loadU32(smeRaw, ConnSsidLenOff)
  if ssid != nil and ssidLen != 0'u32:
    copyMem(ptrAt(req, SmSsidOff + MacSsidArrayOff), ssid, min(ssidLen, 32'u32).uint)
  storeU8(req, SmSsidOff + MacSsidLengthOff, ssidLen.uint8)
  storeU32(req, SmFlagsOff, flags)

  let modp = loadPtr(cast[pointer](blHw), BlHwModParamsOff)
  if modp != nil:
    storeU16(req, SmListenIntervalOff, loadI32(modp, BlModParamsListenItvOff).uint16)
    storeU8(req, SmDontWaitBcmcOff, if loadU8(modp, BlModParamsListenBcmcOff) == 0: 1'u8 else: 0'u8)
    storeU8(req, SmUapsdQueuesOff, loadI32(modp, BlModParamsUapsdQueuesOff).uint8)
  let auth = loadU32(smeRaw, ConnAuthTypeOff)
  storeU8(req, SmAuthTypeOff,
          if auth == NL80211_AUTHTYPE_AUTOMATIC: NL80211_AUTHTYPE_OPEN_SYSTEM else: auth.uint8)
  storeU8(req, SmSupplicantEnabledOff, 1)

  let keyLen = loadU8(smeRaw, ConnKeyLenOff)
  let key = loadPtr(smeRaw, ConnKeyOff)
  if keyLen != 0 and key != nil:
    copyMem(ptrAt(req, SmPhraseOff), key, min(keyLen.uint, 64'u))
  let pmkLen = loadU8(smeRaw, ConnPmkLenOff)
  let pmk = loadPtr(smeRaw, ConnPmkOff)
  if pmkLen != 0 and pmk != nil:
    copyMem(ptrAt(req, SmPhrasePmkOff), pmk, min(pmkLen.uint, 64'u))

  blSendMsg(blHw, req, 1, SM_CONNECT_CFM, cfm)
