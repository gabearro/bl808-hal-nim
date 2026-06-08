proc bl_main_connect*(ssid: ptr uint8; ssidLen: cint; psk: ptr uint8; pskLen: cint;
                      pmk: ptr uint8; pmkLen: cint; mac: ptr uint8; band: uint8;
                      freq: uint16; flags: uint32): cint {.exportc, cdecl.} =
  var sme: array[SizeCfg80211Connect, uint8]
  zero(addr sme[0], sme.len)
  storePtr(addr sme[0], ConnSsidOff, cast[pointer](ssid))
  storePtr(addr sme[0], ConnKeyOff, cast[pointer](psk))
  storePtr(addr sme[0], ConnPmkOff, cast[pointer](pmk))
  storeU32(addr sme[0], ConnSsidLenOff, ssidLen.uint32)
  storeU32(addr sme[0], ConnAuthTypeOff, Nl80211AuthtypeAutomatic)
  storeU8(addr sme[0], ConnKeyLenOff, pskLen.uint8)
  storeU8(addr sme[0], ConnPmkLenOff, pmkLen.uint8)
  storeU32(addr sme[0], ConnFlagsOff, flags)

  if pskLen > 0 or pmkLen > 0:
    let crypto = ptrAt(addr sme[0], ConnCryptoOff)
    storeU32(crypto, CryptoCipherGroupOff, WlanCipherSuiteCcmp)
    storeU32(crypto, CryptoNCiphersOff, 1'u32)
    storeU32(crypto, CryptoCiphers0Off, WlanCipherSuiteCcmp)
    storeU8(crypto, CryptoControlPortOff, 0'u8)
    storeU16(crypto, CryptoControlEthertypeOff, EthPPae)
    storeU8(crypto, CryptoControlNoEncOff, 0'u8)

  if mac != nil:
    storePtr(addr sme[0], ConnBssidOff, cast[pointer](mac))
  if freq > 0'u16:
    let chan = ptrAt(addr sme[0], ConnChannelOff)
    storeU32(chan, ChanBandOff, band.uint32)
    storeU16(chan, ChanFreqOff, freq)
    storeU32(chan, ChanFlagsOff, 0'u32)

  discard bl_cfg80211_connect(hwPtr(), cast[ptr Cfg80211ConnectParams](addr sme[0]))
  0

proc bl_main_disconnect*(): cint {.exportc, cdecl.} =
  discard bl_send_sm_disconnect_req(hwPtr())
  0

proc bl_main_powersaving*(mode: cint): cint {.exportc, cdecl.} =
  result = bl_send_mm_powersaving_req(hwPtr(), mode)
  if result == 0:
    storeU8(vifAt(BlVifSta), BlVifStaPsOff, mode.uint8)

proc bl_main_powersaving_get*(): cint {.exportc, cdecl.} =
  loadU8(vifAt(BlVifSta), BlVifStaPsOff).cint

proc bl_main_sta_is_connected*(): cint {.exportc, cdecl.} =
  if loadU8(vifAt(BlVifSta), BlVifLinksNumOff) > 0'u8: 1 else: 0
