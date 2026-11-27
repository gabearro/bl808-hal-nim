proc wifiConnect*(ssid, password: string, channel: uint8 = 0): WifiError =
  ## Connect to a WiFi AP.
  wifiNimFirmwarePruneScanCache(ssid)
  let connectStartStatus = wifi_mgmr_sta_connect(
    addr staIface, ssid.cstring, password.cstring,
    nil, nil, 0, channel)
  if connectStartStatus != 0:
    return wifiFail
  if wifiBackendUsesEventFutures():
    for _ in 0 ..< 30_000:
      wifiBackendPoll(8)
      wifiNimFirmwareServiceTx(8)
      if wifiBackendConnectDone():
        break
  return if wifiBackendConnected(): wifiOk else: wifiFail

var wifiPmkPrepareActive: bool

when defined(bl808m0):
  const WifiPmkRoundsPerTurn* {.intdefine.} = 64

  proc wifiConnectWithPreparedPmk(ssid, password: string;
                                  channel: uint8;
                                  timeoutMs: uint32): CpsFuture[WifiError] {.cps.} =
    ## Derive the WPA2 PMK in CPS turns before submitting the connection.
    ## The firmware still receives its original passphrase and SSID; its
    ## PBKDF2 call consumes the exact-match PMK cached by this task.
    clearPreparedWpa2Pmk()
    let passBytes = cast[ptr UncheckedArray[uint8]](password.cstring)
    let ssidBytes = cast[ptr UncheckedArray[uint8]](ssid.cstring)
    var deriver = new Wpa2PmkDeriver
    if not deriver[].startWpa2PmkDeriver(
        passBytes.toOpenArray(0, password.len - 1),
        ssidBytes.toOpenArray(0, ssid.len - 1)):
      wifiPmkPrepareActive = false
      return wifiFail
    while true:
      when defined(radioDiag):
        let sliceStart = readTick()
      let step = deriver[].stepWpa2PmkDeriver(WifiPmkRoundsPerTurn)
      when defined(radioDiag):
        wpa2PmkNoteSlice(uint32(min(ticksToUs(readTick() - sliceStart),
                                    high(uint32).uint64)))
      case step
      of pmkReady:
        break
      of pmkFailed:
        wifiPmkPrepareActive = false
        return wifiFail
      of pmkPending:
        await yieldNow()
    if not deriver[].cachePreparedWpa2Pmk(
        passBytes.toOpenArray(0, password.len - 1),
        ssidBytes.toOpenArray(0, ssid.len - 1)):
      wifiPmkPrepareActive = false
      return wifiFail
    wifiNimFirmwarePruneScanCache(ssid)
    let connectStartStatus = wifi_mgmr_sta_connect(
      addr staIface, ssid.cstring, password.cstring,
      nil, nil, 0, channel)
    if connectStartStatus != 0:
      clearPreparedWpa2Pmk()
      wifiPmkPrepareActive = false
      return wifiFail
    let wait = wifiBeginConnectWait(timeoutMs)
    wifiPmkPrepareActive = false
    let outcome = await wait
    clearPreparedWpa2Pmk()
    return outcome

proc wifiConnectAsync*(ssid, password: string,
                       channel: uint8 = 0,
                       timeoutMs: uint32 = 30_000): CpsFuture[WifiError] =
  if (wifiConnectFuture != nil and not wifiConnectFuture.finished) or
      wifiPmkPrepareActive:
    return failedLocalFuture[WifiError](
      newException(CatchableError, "WiFi connect already pending"))
  if wifiServiceHookInstalled and password.len in 8..63 and ssid.len in 1..32:
    wifiPmkPrepareActive = true
    return wifiConnectWithPreparedPmk(ssid, password, channel, timeoutMs)
  wifiNimFirmwarePruneScanCache(ssid)
  let connectStartStatus = wifi_mgmr_sta_connect(
    addr staIface, ssid.cstring, password.cstring,
    nil, nil, 0, channel)
  if connectStartStatus != 0:
    return completedLocalFuture(wifiFail)
  return wifiBeginConnectWait(timeoutMs)
