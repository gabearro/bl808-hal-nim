proc fillCountryIe(countryIeOut: pointer): uint8 =
  if channelNumDefault == 0:
    return 0
  storeU8(countryIeOut, 0, 7)
  storeU8(countryIeOut, 1, 6)
  storeU8(countryIeOut, 2, countryCode0)
  storeU8(countryIeOut, 3, countryCode1)
  storeU8(countryIeOut, 4, 32)
  storeU8(countryIeOut, 5, 1)
  storeU8(countryIeOut, 6, channelNumDefault.uint8)
  storeU8(countryIeOut, 7, countryMaxPower)
  8

proc bl_send_apm_start_req*(blHw: ptr BlHw; cfm: ptr ApmStartCfmObj; ssid, password: cstring;
                            channel: cint; vifIndex, hiddenSsid: uint8;
                            bcnInt: uint16): cint {.exportc, cdecl.} =
  let apmStartReq = blMsgZalloc(APM_START_REQ, TASK_APM, DRV_TASK_ID, SizeApmStartReq)
  if apmStartReq == nil: return -Enomem
  let freq = phy_channel_to_freq(NL80211_BAND_2GHZ, channel)
  storeU8(apmStartReq, ApmChanOff + ScanChanBandOff, NL80211_BAND_2GHZ)
  storeU16(apmStartReq, ApmChanOff + ScanChanFreqOff, freq)
  storeU32(apmStartReq, ApmCenterFreq1Off, freq.uint32)
  storeU32(apmStartReq, ApmCenterFreq2Off, 0)
  storeU8(apmStartReq, ApmChWidthOff, PHY_CHNL_BW_20)
  storeU8(apmStartReq, ApmHiddenSsidOff, hiddenSsid)
  storeU32(apmStartReq, ApmBcnAddrOff, 0)
  storeU16(apmStartReq, ApmBcnLenOff, 0)
  storeU16(apmStartReq, ApmTimOftOff, 0)
  storeU16(apmStartReq, ApmBcnIntOff, bcnInt)
  storeU32(apmStartReq, ApmFlagsOff, 0x08)
  storeU16(apmStartReq, ApmCtrlPortEthertypeOff, swap16(ETH_P_PAE))
  storeU8(apmStartReq, ApmTimLenOff, 6)
  storeU8(apmStartReq, ApmVifIdxOff, vifIndex)
  let passLen = if password == nil: 0'u else: c_strlen(password).uint
  storeU8(apmStartReq, ApmSecTypeOff, if passLen != 0: 1'u8 else: 0'u8)
  storeU8(apmStartReq, ApmEmbEnabledOff, 1)
  if ssid != nil:
    let ssidLen = min(c_strlen(ssid).uint, 32'u)
    copyMem(ptrAt(apmStartReq, ApmSsidOff + MacSsidArrayOff), ssid, ssidLen)
    storeU8(apmStartReq, ApmSsidOff + MacSsidLengthOff, ssidLen.uint8)
  if passLen != 0:
    copyMem(ptrAt(apmStartReq, ApmPhraseOff), password, min(passLen, 64'u))
  let rates = [0x82'u8, 0x84, 0x8b, 0x96, 0x12, 0x24, 0x48, 0x6c,
               0x0c, 0x18, 0x30, 0x60]
  storeU8(apmStartReq, ApmRateSetOff + MacRatesetLengthOff, rates.len.uint8)
  copyMem(ptrAt(apmStartReq, ApmRateSetOff + MacRatesetArrayOff), unsafeAddr rates[0], rates.len.uint)
  storeU8(apmStartReq, ApmBeaconPeriodOff, 1)
  storeU8(apmStartReq, ApmQosSupportedOff, 1)
  storeU8(apmStartReq, ApmBcnBufLenOff, fillCountryIe(ptrAt(apmStartReq, ApmBcnBufOff)))
  blSendMsg(blHw, apmStartReq, 1, APM_START_CFM, cfm)
