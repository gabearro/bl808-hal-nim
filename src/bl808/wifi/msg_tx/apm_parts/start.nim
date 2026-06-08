proc fillCountryIe(buf: pointer): uint8 =
  if channelNumDefault == 0:
    return 0
  storeU8(buf, 0, 7)
  storeU8(buf, 1, 6)
  storeU8(buf, 2, countryCode0)
  storeU8(buf, 3, countryCode1)
  storeU8(buf, 4, 32)
  storeU8(buf, 5, 1)
  storeU8(buf, 6, channelNumDefault.uint8)
  storeU8(buf, 7, countryMaxPower)
  8

proc bl_send_apm_start_req*(blHw: ptr BlHw; cfm: ptr ApmStartCfmObj; ssid, password: cstring;
                            channel: cint; vifIndex, hiddenSsid: uint8;
                            bcnInt: uint16): cint {.exportc, cdecl.} =
  let req = blMsgZalloc(APM_START_REQ, TASK_APM, DRV_TASK_ID, SizeApmStartReq)
  if req == nil: return -Enomem
  let freq = phy_channel_to_freq(NL80211_BAND_2GHZ, channel)
  storeU8(req, ApmChanOff + ScanChanBandOff, NL80211_BAND_2GHZ)
  storeU16(req, ApmChanOff + ScanChanFreqOff, freq)
  storeU32(req, ApmCenterFreq1Off, freq.uint32)
  storeU32(req, ApmCenterFreq2Off, 0)
  storeU8(req, ApmChWidthOff, PHY_CHNL_BW_20)
  storeU8(req, ApmHiddenSsidOff, hiddenSsid)
  storeU32(req, ApmBcnAddrOff, 0)
  storeU16(req, ApmBcnLenOff, 0)
  storeU16(req, ApmTimOftOff, 0)
  storeU16(req, ApmBcnIntOff, bcnInt)
  storeU32(req, ApmFlagsOff, 0x08)
  storeU16(req, ApmCtrlPortEthertypeOff, swap16(ETH_P_PAE))
  storeU8(req, ApmTimLenOff, 6)
  storeU8(req, ApmVifIdxOff, vifIndex)
  let passLen = if password == nil: 0'u else: c_strlen(password).uint
  storeU8(req, ApmSecTypeOff, if passLen != 0: 1'u8 else: 0'u8)
  storeU8(req, ApmEmbEnabledOff, 1)
  if ssid != nil:
    let ssidLen = min(c_strlen(ssid).uint, 32'u)
    copyMem(ptrAt(req, ApmSsidOff + MacSsidArrayOff), ssid, ssidLen)
    storeU8(req, ApmSsidOff + MacSsidLengthOff, ssidLen.uint8)
  if passLen != 0:
    copyMem(ptrAt(req, ApmPhraseOff), password, min(passLen, 64'u))
  let rates = [0x82'u8, 0x84, 0x8b, 0x96, 0x12, 0x24, 0x48, 0x6c,
               0x0c, 0x18, 0x30, 0x60]
  storeU8(req, ApmRateSetOff + MacRatesetLengthOff, rates.len.uint8)
  copyMem(ptrAt(req, ApmRateSetOff + MacRatesetArrayOff), unsafeAddr rates[0], rates.len.uint)
  storeU8(req, ApmBeaconPeriodOff, 1)
  storeU8(req, ApmQosSupportedOff, 1)
  storeU8(req, ApmBcnBufLenOff, fillCountryIe(ptrAt(req, ApmBcnBufOff)))
  blSendMsg(blHw, req, 1, APM_START_CFM, cfm)
