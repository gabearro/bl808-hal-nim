proc rxHandleBeacon(ind, mgmt: pointer) =
  var indNew: array[WifiBeaconEventSize.int, uint8]
  var ssidLen: cint
  var channel: uint8
  var wpaIe: WifiWpaIe
  var rsnIe: WifiWpaIe
  var parsed: array[2, WifiWpaIe]
  var parsedLen = 0
  zero(addr indNew[0], indNew.len.uint)
  let variable = ptrAt(mgmt, MgmtBeaconVariableOff)
  let varAddr = cast[uint32](cast[uint](variable))
  let length = loadU16(ind, ScanuLengthOff)
  let varLen = length - MgmtBeaconVariableOff.uint16
  discard findIeSsid(variable, varLen.cint,
                     ptrAt(addr indNew[0], WifiBeaconSsidOff), addr ssidLen)
  discard findIeDs(variable, varLen.cint, addr channel)
  storeI32(addr indNew[0], WifiBeaconSsidLenOff, ssidLen.int32)
  storeU8(addr indNew[0], WifiBeaconChannelOff, channel)

  var ouiWps = [0x00'u8, 0x50'u8, 0xF2'u8, 0x04'u8]
  storeU8(addr indNew[0], WifiBeaconWpsOff,
          if mac_vsie_find(varAddr, varLen, addr ouiWps[0], 4) != 0'u32: 1'u8 else: 0'u8)
  if mac_ie_find(varAddr, varLen, MacEltIdHtCapa) != 0'u32:
    storeU32(addr indNew[0], WifiBeaconModeOff, WifiModeB or WifiModeG or WifiModeN24)
  elif mac_ie_find(varAddr, varLen, MacEltIdExtRates) != 0'u32:
    storeU32(addr indNew[0], WifiBeaconModeOff, WifiModeB or WifiModeG)
  else:
    storeU32(addr indNew[0], WifiBeaconModeOff, WifiModeB)

  if (loadU16(mgmt, MgmtBeaconCapabOff) and WlanCapabilityPrivacy) != 0:
    let rsnAddr = mac_ie_find(varAddr, varLen, MacEltIdRsn)
    if rsnAddr != 0'u32:
      let rsnLen = loadU8(cast[pointer](rsnAddr.uint), MacInfoEltLenOff).uint + MacInfoEltInfoOff
      zero(addr rsnIe, sizeof(WifiWpaIe).uint)
      discard wpa_parse_wpa_ie_wrapper(cast[pointer](rsnAddr.uint), rsnLen.csize_t, addr rsnIe)
      parsed[parsedLen] = rsnIe
      inc parsedLen
    var ouiWpa = [0x00'u8, 0x50'u8, 0xF2'u8, 0x01'u8]
    let wpaAddr = mac_vsie_find(varAddr, varLen, addr ouiWpa[0], 4)
    if wpaAddr != 0'u32 and parsedLen < 2:
      let wpaLen = loadU8(cast[pointer](wpaAddr.uint), MacInfoEltLenOff).uint + MacInfoEltInfoOff
      zero(addr wpaIe, sizeof(WifiWpaIe).uint)
      discard wpa_parse_wpa_ie_wrapper(cast[pointer](wpaAddr.uint), wpaLen.csize_t, addr wpaIe)
      parsed[parsedLen] = wpaIe
      inc parsedLen
    setCipherFlags(addr indNew[0], addr parsed[0], parsedLen)
  else:
    storeU8(addr indNew[0], WifiBeaconAuthOff, AuthOpen)

  storeI8(addr indNew[0], WifiBeaconRssiOff, loadI8(ind, ScanuRssiOff))
  storeI8(addr indNew[0], WifiBeaconPpmAbsOff, loadI8(ind, ScanuPpmAbsOff))
  storeI8(addr indNew[0], WifiBeaconPpmRelOff, loadI8(ind, ScanuPpmRelOff))
  copyMem(ptrAt(addr indNew[0], WifiBeaconBssidOff), ptrAt(mgmt, MgmtBssidOff), 6)
  if cbBeacon != nil:
    cbBeacon(cbBeaconEnv, cast[ptr WifiEventBeacon](addr indNew[0]))

proc rxHandleProbeResp(ind, mgmt: pointer) =
  rxHandleBeacon(ind, mgmt)
