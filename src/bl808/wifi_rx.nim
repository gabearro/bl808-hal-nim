## Nim replacement for the BL808 WiFi host RX/event dispatch path in bl_rx.c.

when defined(bl808m0) and defined(bl808WifiNimFw):
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/include".}

  const
    TaskMM = 0'u16
    TaskScanu = 2'u16
    TaskMe = 3'u16
    TaskSm = 4'u16
    TaskApm = 5'u16
    TaskCfg = 8'u16

    MmChannelSwitchI = 50'u16
    MmChannelPreSwitchI = 51'u16
    MmRemainOnChannelExpI = 54'u16
    MmPsChangeI = 55'u16
    MmTrafficReqI = 56'u16
    MmChannelSurveyI = 60'u16
    MmRssiStatusI = 67'u16
    ScanuStartCfmI = 1'u16
    ScanuJoinCfmI = 3'u16
    ScanuResultI = 4'u16
    MeTkipMicFailureI = 4'u16
    MeTxCreditsUpdateI = 9'u16
    SmConnectI = 2'u16
    SmDisconnectI = 5'u16
    SmStaAddI = 10'u16
    ApmStaAddI = 4'u16
    ApmStaDelI = 5'u16

    BlVifSta = 0'u
    BlVifAp = 1'u
    NxRemoteStaStoreMax = 3'u8
    PsModeOff = 0'u8
    StaQosCapa = 1'u32

    BlHwCmdMgrOff = 0'u
    BlHwVifTableOff = 60'u
    BlHwStaTableOff = 100'u
    CmdMgrMsgindOff = 36'u
    BlVifSize = 20'u
    BlVifDevOff = 8'u
    BlVifLinksNumOff = 14'u
    BlVifFixedStaIdxOff = 15'u
    BlVifFcChanOff = 16'u
    BlVifStaPsOff = 17'u
    BlStaSize = 40'u
    BlStaAddrOff = 16'u
    BlStaIsUsedOff = 22'u
    BlStaStaIdxOff = 23'u
    BlStaVifIdxOff = 24'u
    BlStaFcPsOff = 26'u
    BlStaQosOff = 27'u
    BlStaRssiOff = 28'u
    BlStaDataRateOff = 29'u
    BlStaTsfloOff = 32'u
    BlStaTsfhiOff = 36'u

    IpcMsgIdOff = 0'u
    IpcMsgParamOff = 8'u
    MsgIndexMask = 1023'u16

    MmChanSwitchChanOff = 0'u
    MmRssiRssiOff = 2'u
    ScanuLengthOff = 0'u
    ScanuRssiOff = 24'u
    ScanuPpmAbsOff = 25'u
    ScanuPpmRelOff = 26'u
    ScanuPayloadOff = 32'u

    SmConnStatusOff = 0'u
    SmConnReasonOff = 2'u
    SmConnBssidOff = 4'u
    SmConnApIdxOff = 12'u
    SmConnChIdxOff = 13'u
    SmConnQosOff = 14'u
    SmConnAcmOff = 15'u
    SmConnAssocReqLenOff = 16'u
    SmConnAssocRspLenOff = 18'u
    SmConnAidOff = 820'u
    SmConnBandOff = 822'u
    SmConnCenterFreqOff = 824'u
    SmConnWidthOff = 826'u
    SmConnCenterFreq1Off = 828'u
    SmConnCenterFreq2Off = 832'u
    SmConnDiagnoseOff = 852'u
    SmDiscStatusOff = 0'u
    SmDiscReasonOff = 2'u
    SmDiscFtOverDsOff = 5'u
    SmDiscDiagnoseOff = 8'u
    SmStaAddApIdxOff = 1'u
    SmStaAddQosOff = 2'u

    ApmFlagsOff = 0'u
    ApmStaAddrOff = 4'u
    ApmStaIdxOff = 11'u
    ApmRssiOff = 12'u
    ApmTsfloOff = 16'u
    ApmTsfhiOff = 20'u
    ApmDataRateOff = 24'u
    ApmDelStatusOff = 0'u
    ApmDelReasonOff = 2'u
    ApmDelStaIdxOff = 4'u

    WifiConnEventSize = 44'u
    WifiConnStatusOff = 0'u
    WifiConnReasonOff = 2'u
    WifiConnBssidOff = 4'u
    WifiConnVifOff = 10'u
    WifiConnApOff = 11'u
    WifiConnChOff = 12'u
    WifiConnQosOff = 16'u
    WifiConnAidOff = 20'u
    WifiConnBandOff = 22'u
    WifiConnCenterFreqOff = 24'u
    WifiConnWidthOff = 26'u
    WifiConnCenterFreq1Off = 28'u
    WifiConnCenterFreq2Off = 32'u
    WifiConnDiagnoseOff = 36'u
    WifiDiscEventSize = 20'u
    WifiDiscStatusOff = 0'u
    WifiDiscReasonOff = 2'u
    WifiDiscVifOff = 4'u
    WifiDiscFtOverDsOff = 8'u
    WifiDiscDiagnoseOff = 12'u
    WifiBeaconEventSize = 64'u
    WifiBeaconModeOff = 0'u
    WifiBeaconBssidOff = 4'u
    WifiBeaconSsidOff = 10'u
    WifiBeaconRssiOff = 43'u
    WifiBeaconPpmAbsOff = 44'u
    WifiBeaconPpmRelOff = 45'u
    WifiBeaconChannelOff = 46'u
    WifiBeaconAuthOff = 47'u
    WifiBeaconCipherOff = 48'u
    WifiBeaconSsidLenOff = 56'u
    WifiBeaconWpsOff = 60'u
    WifiBeaconGroupCipherOff = 61'u

    WifiEventChannelSwitch = 0'u32
    WifiEventScanDone = 1'u32
    WifiEventScanDoneOnJoin = 2'u32
    WifiModeB = 0x01'u32
    WifiModeG = 0x04'u32
    WifiModeN24 = 0x08'u32
    AuthOpen = 0'u8
    AuthWep = 1'u8
    AuthWpaPsk = 2'u8
    AuthWpa2Psk = 3'u8
    AuthWpaWpa2Psk = 4'u8
    AuthWpa3Sae = 6'u8
    AuthWpa2PskWpa3Sae = 7'u8
    CipherWep = 1'u8
    CipherAes = 2'u8
    CipherTkip = 3'u8
    CipherTkipAes = 4'u8

    WlanCapabilityPrivacy = 1'u16 shl 4
    IeIdSsid = 0'u8
    IeIdDsChannel = 3'u8
    MacEltIdHtCapa = 45'u8
    MacEltIdExtRates = 50'u8
    MacEltIdRsn = 48'u8
    MacInfoEltLenOff = 1'u
    MacInfoEltInfoOff = 2'u32
    WifiCipherTkip = 3'i32
    WifiCipherCcmp = 4'i32
    WifiCipherTkipCcmp = 5'i32
    WpaProtoWpa = 1'i32
    WpaProtoRsn = 2'i32
    WpaKeyMgmtPsk = 2'i32
    WpaKeyMgmtPskSha256 = 256'i32
    WpaKeyMgmtSae = 1024'i32

    Ieee80211FctlFtype = 0x000c'u16
    Ieee80211FctlStype = 0x00f0'u16
    Ieee80211StypeProbeResp = 0x0050'u16
    Ieee80211StypeBeacon = 0x0080'u16
    MgmtFrameControlOff = 0'u
    MgmtBssidOff = 16'u
    MgmtBeaconCapabOff = 34'u
    MgmtBeaconVariableOff = 36'u

    EvWifi = 2.cint
    CodeWifiOnApStaAdd = 21.cint
    CodeWifiOnApStaDel = 22.cint
    DiagnoseSize = 8'u

  type
    BlHw {.importc: "struct bl_hw", header: "bl_defs.h".} = object
    BlSta {.importc: "struct bl_sta", header: "bl_defs.h".} = object
    Netif {.importc: "struct netif", header: "<lwip/netif.h>".} = object
    BlRxInfo {.importc: "bl_rx_info_t", header: "bl_main.h".} = object
    WifiEventSmConnect {.importc: "struct wifi_event_sm_connect_ind", header: "bl_main.h".} = object
    WifiEventSmDisconnect {.importc: "struct wifi_event_sm_disconnect_ind", header: "bl_main.h".} = object
    WifiEventBeacon {.importc: "struct wifi_event_beacon_ind", header: "bl_main.h".} = object
    WifiEvent {.importc: "struct wifi_event", header: "bl_main.h".} = object
    MsgCbProc = proc(blHw, cmd, msg: pointer): cint {.cdecl.}
    CmdMsgindProc = proc(cmdMgr, msg: pointer; cb: MsgCbProc): cint {.cdecl.}
    ConnectCb = proc(env: pointer; ind: ptr WifiEventSmConnect) {.cdecl.}
    DisconnectCb = proc(env: pointer; ind: ptr WifiEventSmDisconnect) {.cdecl.}
    BeaconCb = proc(env: pointer; ind: ptr WifiEventBeacon) {.cdecl.}
    ProbeRespCb = proc(env: pointer; timestamp: int64) {.cdecl.}
    PktCb = proc(env: pointer; pkt: ptr uint8; len: cint; info: ptr BlRxInfo) {.cdecl.}
    PktAdvCb = proc(env, pktWrap: pointer; info: ptr BlRxInfo) {.cdecl.}
    RssiCb = proc(env: pointer; rssi: int8) {.cdecl.}
    EventCb = proc(env: pointer; event: ptr WifiEvent) {.cdecl.}
    WifiWpaIe {.bycopy.} = object
      proto: cint
      pairwiseCipher: cint
      groupCipher: cint
      keyMgmt: cint
      capabilities: cint
      numPmkid: csize_t
      pmkid: pointer
      mgmtGroupCipher: cint

  {.emit: "extern struct bl_hw wifi_hw;".}
  var wifi_hw {.importc, header: "bl_defs.h".}: BlHw

  var cbSmConnect: ConnectCb
  var cbSmConnectEnv: pointer
  var cbSmDisconnect: DisconnectCb
  var cbSmDisconnectEnv: pointer
  var cbBeacon: BeaconCb
  var cbBeaconEnv: pointer
  var cbProbeResp: ProbeRespCb
  var cbProbeRespEnv: pointer
  var cbPkt: PktCb
  var cbPktAdv: PktAdvCb
  var cbPktEnv: pointer
  var cbRssi: RssiCb
  var cbRssiEnv: pointer
  var cbEvent: EventCb
  var cbEventEnv: pointer
  var nimFwDbgRxSmStaAdd* {.exportc: "nimfw_dbg_rx_sm_sta_add".}: uint32
  var nimFwDbgRxSmStaAddMeta* {.exportc: "nimfw_dbg_rx_sm_sta_add_meta".}: uint32
  var nimFwDbgRxSmStaAddVif* {.exportc: "nimfw_dbg_rx_sm_sta_add_vif".}: uint32
  var nimFwDbgRxSmStaAddSta* {.exportc: "nimfw_dbg_rx_sm_sta_add_sta".}: uint32
  var nimFwDbgRxSmStaAddError* {.exportc: "nimfw_dbg_rx_sm_sta_add_error".}: uint32
  var nimFwDbgRxSmDisc* {.exportc: "nimfw_dbg_rx_sm_disc".}: uint32
  var nimFwDbgRxSmSeq* {.exportc: "nimfw_dbg_rx_sm_seq".}: uint32
  var nimFwDbgRxSmStaAddSeq* {.exportc: "nimfw_dbg_rx_sm_sta_add_seq".}: uint32
  var nimFwDbgRxSmDiscSeq* {.exportc: "nimfw_dbg_rx_sm_disc_seq".}: uint32
  var nimFwDbgRxSmDiscMeta* {.exportc: "nimfw_dbg_rx_sm_disc_meta".}: uint32
  var nimFwDbgRxSmDiscVif* {.exportc: "nimfw_dbg_rx_sm_disc_vif".}: uint32
  var nimFwDbgRxSmDiscSta* {.exportc: "nimfw_dbg_rx_sm_disc_sta".}: uint32

  proc c_memset(s: pointer; c: cint; n: csize_t): pointer
    {.importc: "memset", header: "<string.h>", cdecl.}
  proc c_memcpy(dest, src: pointer; n: csize_t): pointer
    {.importc: "memcpy", header: "<string.h>", cdecl.}
  proc bl_os_printf(fmt: cstring)
    {.importc, header: "bl_os_private.h", cdecl, varargs.}
  proc bl_os_log_info(fmt: cstring)
    {.importc, header: "bl_os_private.h", cdecl, varargs.}
  proc netifapi_netif_set_link_up(netif: ptr Netif)
    {.importc, header: "<lwip/netifapi.h>", cdecl.}
  proc netifapi_netif_set_link_down(netif: ptr Netif)
    {.importc, header: "<lwip/netifapi.h>", cdecl.}
  proc netifapi_netif_set_addr(netif: ptr Netif; ipaddr, netmask, gw: pointer): cint
    {.importc, header: "<lwip/netifapi.h>", cdecl.}
  proc aos_post_event(`type`, code, value: cint): cint
    {.importc, header: "<aos/yloop.h>", cdecl.}
  proc bl_tx_cntrl_link_up(sta: ptr BlSta) {.importc, cdecl, header: "bl_tx.h".}
  proc bl_tx_cntrl_link_down(sta: ptr BlSta) {.importc, cdecl, header: "bl_tx.h".}
  proc mac_vsie_find(baseAddr: uint32; buflen: uint16; oui: pointer; ouilen: uint8): uint32
    {.importc, cdecl, header: "bl60x_fw_api.h".}
  proc mac_ie_find(baseAddr: uint32; buflen: uint16; ieId: uint8): uint32
    {.importc, cdecl, header: "bl60x_fw_api.h".}
  proc wpa_parse_wpa_ie_wrapper(wpaIe: pointer; wpaIeLen: csize_t; data: ptr WifiWpaIe): cint
    {.importc, cdecl.}

  template ptrAt(base: pointer; off: uint): pointer =
    cast[pointer](cast[uint](base) + off)

  proc hwRaw(): pointer {.inline.} = cast[pointer](addr wifi_hw)
  proc loadPtr(base: pointer; off: uint): pointer {.inline.} = cast[ptr pointer](ptrAt(base, off))[]
  proc loadU8(base: pointer; off: uint): uint8 {.inline.} = cast[ptr uint8](ptrAt(base, off))[]
  proc storeU8(base: pointer; off: uint; value: uint8) {.inline.} = cast[ptr uint8](ptrAt(base, off))[] = value
  proc loadI8(base: pointer; off: uint): int8 {.inline.} = cast[ptr int8](ptrAt(base, off))[]
  proc storeI8(base: pointer; off: uint; value: int8) {.inline.} = cast[ptr int8](ptrAt(base, off))[] = value
  proc loadU16(base: pointer; off: uint): uint16 {.inline.} = cast[ptr uint16](ptrAt(base, off))[]
  proc storeU16(base: pointer; off: uint; value: uint16) {.inline.} = cast[ptr uint16](ptrAt(base, off))[] = value
  proc loadU32(base: pointer; off: uint): uint32 {.inline.} = cast[ptr uint32](ptrAt(base, off))[]
  proc storeU32(base: pointer; off: uint; value: uint32) {.inline.} = cast[ptr uint32](ptrAt(base, off))[] = value
  proc storeI32(base: pointer; off: uint; value: int32) {.inline.} = cast[ptr int32](ptrAt(base, off))[] = value
  proc copyMem(dest, src: pointer; n: uint) {.inline.} =
    discard c_memcpy(dest, src, n.csize_t)
  proc zero(dest: pointer; n: uint) {.inline.} =
    discard c_memset(dest, 0, n.csize_t)

  proc vifAt(hw: pointer; idx: uint): pointer {.inline.} =
    ptrAt(ptrAt(hw, BlHwVifTableOff), idx * BlVifSize)

  proc staAt(hw: pointer; idx: uint): pointer {.inline.} =
    ptrAt(ptrAt(hw, BlHwStaTableOff), idx * BlStaSize)

  proc msgParam(msg: pointer): pointer {.inline.} =
    ptrAt(msg, IpcMsgParamOff)

  proc msgTask(id: uint16): uint16 {.inline.} = id shr 10
  proc msgIndex(id: uint16): uint16 {.inline.} = id and MsgIndexMask

  proc isBeacon(fc: uint16): bool {.inline.} =
    (fc and (Ieee80211FctlFtype or Ieee80211FctlStype)) == Ieee80211StypeBeacon

  proc isProbeResp(fc: uint16): bool {.inline.} =
    (fc and (Ieee80211FctlFtype or Ieee80211FctlStype)) == Ieee80211StypeProbeResp

  proc notifyEventChannelSwitch(channel: cint) =
    var buffer: array[8, uint8]
    zero(addr buffer[0], buffer.len.uint)
    storeU32(addr buffer[0], 0, WifiEventChannelSwitch)
    storeI32(addr buffer[0], 4, channel.int32)
    if cbEvent != nil:
      cbEvent(cbEventEnv, cast[ptr WifiEvent](addr buffer[0]))

  proc notifyEventScanDone(joinScan: bool) =
    var buffer: array[8, uint8]
    zero(addr buffer[0], buffer.len.uint)
    storeU32(addr buffer[0], 0, if joinScan: WifiEventScanDoneOnJoin else: WifiEventScanDone)
    storeU32(addr buffer[0], 4, 272'u32)
    if cbEvent != nil:
      cbEvent(cbEventEnv, cast[ptr WifiEvent](addr buffer[0]))

  proc findIeSsid(buffer: pointer; length: cint; outSsid: pointer; ssidLen: ptr cint): cint =
    var i = 0
    var p = buffer
    while i < length:
      let elemLen = loadU8(p, 1).cint
      if loadU8(p, 0) == IeIdSsid:
        if elemLen > 32:
          return -1
        ssidLen[] = elemLen
        copyMem(outSsid, ptrAt(p, 2), elemLen.uint)
        storeU8(outSsid, elemLen.uint, 0)
        return 0
      i += elemLen + 2
      p = ptrAt(p, (elemLen + 2).uint)
    -1

  proc findIeDs(buffer: pointer; length: cint; outChannel: ptr uint8): cint =
    var i = 0
    var p = buffer
    while i < length:
      let elemLen = loadU8(p, 1).cint
      if loadU8(p, 0) == IeIdDsChannel:
        if elemLen > 32:
          return -1
        outChannel[] = loadU8(p, 2)
        return 0
      i += elemLen + 2
      p = ptrAt(p, (elemLen + 2).uint)
    -1

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
    discard findIeSsid(variable, length.cint, ptrAt(addr indNew[0], WifiBeaconSsidOff), addr ssidLen)
    discard findIeDs(variable, length.cint, addr channel)
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

  proc blRxChanSwitchInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
    notifyEventChannelSwitch(loadU8(msgParam(msg), MmChanSwitchChanOff).cint)
    0

  proc blCommonInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
    0

  proc blRxRssiStatusInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
    let ind = msgParam(msg)
    if cbRssi != nil:
      cbRssi(cbRssiEnv, loadI8(ind, MmRssiRssiOff))
    0

  proc blRxScanuStartCfm(blHw, cmd, msg: pointer): cint {.cdecl.} =
    notifyEventScanDone(false)
    0

  proc blRxScanuJoinCfm(blHw, cmd, msg: pointer): cint {.cdecl.} =
    notifyEventScanDone(true)
    0

  proc blRxScanuResultInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
    let ind = msgParam(msg)
    let mgmt = ptrAt(ind, ScanuPayloadOff)
    let fc = loadU16(mgmt, MgmtFrameControlOff)
    if isBeacon(fc):
      rxHandleBeacon(ind, mgmt)
    elif isProbeResp(fc):
      rxHandleProbeResp(ind, mgmt)
    else:
      bl_os_printf("Bug Scan IND?\r\n")
    0

  proc smStatusStr(statusCode: uint16): cstring =
    case statusCode
    of 0: "sm connect ind ok"
    of 1: "tx auth frame alloc failure"
    of 2: "Authentication failure"
    of 3: "Auth response but auth algo failure"
    of 4: "tx assoc frame alloc failure"
    of 5: "Association failure"
    of 6: "deauth by AP when connecting"
    of 7: "deauth by AP when connected"
    of 8: "Passwd error, 4-way handshake timeout"
    of 9: "Passwd error, tx deauth frame transmit failure"
    of 10: "Passwd error, tx deauth frame allocate failure"
    of 11: "auth or associate frame response timeout failure"
    of 12: "SSID error, scan no bssid and channel"
    of 13: "create channel context failure when join network"
    of 14: "join network failure"
    of 15: "add sta failure"
    of 16: "ap beacon loss"
    of 17: "network security no match"
    of 18: "wep network psk len error"
    of 19: "user disconnect and send deauth"
    of 20: "user disconnect but no send deauth"
    of 21: "fw disconnect(tx nullframe failures)"
    of 22: "fw disconnect(traffic loss)"
    of 23: "user connect abort and send deauth"
    of 24: "user connect abort without sending deauth"
    of 25: "user connect abort when joining network"
    of 26: "user connect abort when scanning"
    else: "Unknown Code"

  proc apmStatusStr(statusCode: uint16): cstring =
    case statusCode
    of 0: "apm connect ind ok"
    of 1: "User delete STA"
    of 2: "STA send deauth to AP"
    of 3: "STA send disassociate to AP"
    of 4: "timeout and delete connection"
    of 5: "Delete STA for new connection"
    else: "Unknown Code"

  proc wifi_mgmr_get_sm_status_code_str*(statusCode: uint16): cstring {.exportc, cdecl.} =
    smStatusStr(statusCode)

  proc wifi_mgmr_get_apm_status_code_str*(statusCode: uint16): cstring {.exportc, cdecl.} =
    apmStatusStr(statusCode)

  proc blRxSmConnectInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
    let ind = msgParam(msg)
    var indNew: array[WifiConnEventSize.int, uint8]
    bl_os_printf("[RX] Connection Status\r\n")
    bl_os_printf("[RX]   status_code %u\r\n", loadU16(ind, SmConnStatusOff).cuint)
    bl_os_printf("[RX]   reason_code %u\r\n", loadU16(ind, SmConnReasonOff).cuint)
    bl_os_printf("[RX]   connect result: %s\r\n", smStatusStr(loadU16(ind, SmConnStatusOff)))
    bl_os_printf("[RX]   MAC %02X:%02X:%02X:%02X:%02X:%02X\r\n",
                 loadU8(ind, SmConnBssidOff + 0).cuint, loadU8(ind, SmConnBssidOff + 1).cuint,
                 loadU8(ind, SmConnBssidOff + 2).cuint, loadU8(ind, SmConnBssidOff + 3).cuint,
                 loadU8(ind, SmConnBssidOff + 4).cuint, loadU8(ind, SmConnBssidOff + 5).cuint)
    bl_os_printf("[RX]   vif_idx %u\r\n", BlVifSta.cuint)
    bl_os_printf("[RX]   ap_idx %u\r\n", loadU8(ind, SmConnApIdxOff).cuint)
    bl_os_printf("[RX]   ch_idx %u\r\n", loadU8(ind, SmConnChIdxOff).cuint)
    bl_os_printf("[RX]   qos %u\r\n", loadU8(ind, SmConnQosOff).cuint)
    bl_os_printf("[RX]   acm %u\r\n", loadU8(ind, SmConnAcmOff).cuint)
    bl_os_printf("[RX]   assoc_req_ie_len %u\r\n", loadU16(ind, SmConnAssocReqLenOff).cuint)
    bl_os_printf("[RX]   assoc_rsp_ie_len %u\r\n", loadU16(ind, SmConnAssocRspLenOff).cuint)
    bl_os_printf("[RX]   aid %u\r\n", loadU16(ind, SmConnAidOff).cuint)
    bl_os_printf("[RX]   band %u\r\n", loadU8(ind, SmConnBandOff).cuint)
    bl_os_printf("[RX]   center_freq %u\r\n", loadU16(ind, SmConnCenterFreqOff).cuint)
    bl_os_printf("[RX]   width %u\r\n", loadU8(ind, SmConnWidthOff).cuint)
    bl_os_printf("[RX]   center_freq1 %u\r\n", loadU32(ind, SmConnCenterFreq1Off).cuint)
    bl_os_printf("[RX]   center_freq2 %u\r\n", loadU32(ind, SmConnCenterFreq2Off).cuint)
    bl_os_printf("[RX]   tlv_ptr first %p\r\n", loadPtr(ind, SmConnDiagnoseOff))

    zero(addr indNew[0], indNew.len.uint)
    storeU16(addr indNew[0], WifiConnStatusOff, loadU16(ind, SmConnStatusOff))
    storeU16(addr indNew[0], WifiConnReasonOff, loadU16(ind, SmConnReasonOff))
    copyMem(ptrAt(addr indNew[0], WifiConnBssidOff), ptrAt(ind, SmConnBssidOff), 6)
    storeU8(addr indNew[0], WifiConnVifOff, BlVifSta.uint8)
    storeU8(addr indNew[0], WifiConnApOff, loadU8(ind, SmConnApIdxOff))
    storeU8(addr indNew[0], WifiConnChOff, loadU8(ind, SmConnChIdxOff))
    storeI32(addr indNew[0], WifiConnQosOff, loadU8(ind, SmConnQosOff).int32)
    storeU16(addr indNew[0], WifiConnAidOff, loadU16(ind, SmConnAidOff))
    storeU8(addr indNew[0], WifiConnBandOff, loadU8(ind, SmConnBandOff))
    storeU16(addr indNew[0], WifiConnCenterFreqOff, loadU16(ind, SmConnCenterFreqOff))
    storeU8(addr indNew[0], WifiConnWidthOff, loadU8(ind, SmConnWidthOff))
    storeU32(addr indNew[0], WifiConnCenterFreq1Off, loadU32(ind, SmConnCenterFreq1Off))
    storeU32(addr indNew[0], WifiConnCenterFreq2Off, loadU32(ind, SmConnCenterFreq2Off))
    copyMem(ptrAt(addr indNew[0], WifiConnDiagnoseOff), ptrAt(ind, SmConnDiagnoseOff), DiagnoseSize)
    if cbSmConnect != nil:
      cbSmConnect(cbSmConnectEnv, cast[ptr WifiEventSmConnect](addr indNew[0]))

    let vif = vifAt(blHw, BlVifSta)
    if loadU16(ind, SmConnStatusOff) != 0:
      if loadU8(vif, BlVifLinksNumOff) != 0:
        storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) - 1)
        storeU8(vif, BlVifFcChanOff, 0)
        storeU8(vif, BlVifStaPsOff, PsModeOff)
        let sta = staAt(blHw, loadU8(vif, BlVifFixedStaIdxOff).uint)
        storeU8(sta, BlStaIsUsedOff, 0)
        bl_tx_cntrl_link_down(cast[ptr BlSta](sta))
        let dev = loadPtr(vif, BlVifDevOff)
        if dev != nil:
          netifapi_netif_set_link_down(cast[ptr Netif](dev))
    else:
      let dev = loadPtr(vif, BlVifDevOff)
      if dev != nil:
        netifapi_netif_set_link_up(cast[ptr Netif](dev))
      else:
        bl_os_printf("[RX]  -------- CRITICAL when check netif. ptr is %p:%p\r\n", vif, dev)
    0

  proc blRxSmDisconnectInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
    inc nimFwDbgRxSmDisc
    let ind = msgParam(msg)
    let vif = vifAt(blHw, BlVifSta)
    var indNew: array[WifiDiscEventSize.int, uint8]
    var addrAny: uint32
    inc nimFwDbgRxSmSeq
    nimFwDbgRxSmDiscSeq = nimFwDbgRxSmSeq
    nimFwDbgRxSmDiscMeta = loadU16(ind, SmDiscStatusOff).uint32 or
      (loadU16(ind, SmDiscReasonOff).uint32 shl 16)
    nimFwDbgRxSmDiscVif = loadU8(vif, BlVifLinksNumOff).uint32 or
      (loadU8(vif, BlVifFixedStaIdxOff).uint32 shl 8) or
      (loadU8(vif, BlVifFcChanOff).uint32 shl 16) or
      (loadU8(vif, BlVifStaPsOff).uint32 shl 24)
    let discSta = staAt(blHw, loadU8(vif, BlVifFixedStaIdxOff).uint)
    nimFwDbgRxSmDiscSta = loadU8(discSta, BlStaIsUsedOff).uint32 or
      (loadU8(discSta, BlStaStaIdxOff).uint32 shl 8) or
      (loadU8(discSta, BlStaVifIdxOff).uint32 shl 16) or
      (loadU8(discSta, BlStaQosOff).uint32 shl 24)
    bl_os_printf("[RX]   sm_disconnect_ind\r\n       status_code %u\r\n       802.11 reason_code %u\r\n",
                 loadU16(ind, SmDiscStatusOff).cuint, loadU16(ind, SmDiscReasonOff).cuint)
    bl_os_printf("[RX]   disconnect reason: %s\r\n", smStatusStr(loadU16(ind, SmDiscStatusOff)))
    bl_os_printf("[RX]   vif_idx %u\r\n", BlVifSta.cuint)
    bl_os_printf("[RX]   ft_over_ds %u\r\n", loadU8(ind, SmDiscFtOverDsOff).cuint)
    bl_os_printf("[RX]   tlv_ptr first %p\r\n", loadPtr(ind, SmDiscDiagnoseOff))
    if loadU8(vif, BlVifLinksNumOff) == 0:
      bl_os_printf("[WF] Error: illegal sm_sta_del, links_num is 0!\r\n")
      return -1
    let sta = staAt(blHw, loadU8(vif, BlVifFixedStaIdxOff).uint)
    if loadU8(sta, BlStaIsUsedOff) != 0:
      storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) - 1)
      storeU8(vif, BlVifFcChanOff, 0)
      storeU8(vif, BlVifStaPsOff, PsModeOff)
      storeU8(sta, BlStaIsUsedOff, 0)
      bl_tx_cntrl_link_down(cast[ptr BlSta](sta))
    if cbSmDisconnect != nil:
      zero(addr indNew[0], indNew.len.uint)
      storeU16(addr indNew[0], WifiDiscStatusOff, loadU16(ind, SmDiscStatusOff))
      storeU16(addr indNew[0], WifiDiscReasonOff, loadU16(ind, SmDiscReasonOff))
      storeU8(addr indNew[0], WifiDiscVifOff, BlVifSta.uint8)
      storeI32(addr indNew[0], WifiDiscFtOverDsOff, loadU8(ind, SmDiscFtOverDsOff).int32)
      copyMem(ptrAt(addr indNew[0], WifiDiscDiagnoseOff), ptrAt(ind, SmDiscDiagnoseOff), DiagnoseSize)
      cbSmDisconnect(cbSmDisconnectEnv, cast[ptr WifiEventSmDisconnect](addr indNew[0]))
    let dev = loadPtr(vif, BlVifDevOff)
    if dev != nil:
      netifapi_netif_set_link_down(cast[ptr Netif](dev))
      addrAny = 0
      discard netifapi_netif_set_addr(cast[ptr Netif](dev), addr addrAny, addr addrAny, addr addrAny)
    0

  proc blRxSmStaAddInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
    let ind = msgParam(msg)
    let vif = vifAt(blHw, BlVifSta)
    inc nimFwDbgRxSmStaAdd
    inc nimFwDbgRxSmSeq
    nimFwDbgRxSmStaAddSeq = nimFwDbgRxSmSeq
    nimFwDbgRxSmStaAddMeta = loadU8(ind, SmStaAddApIdxOff).uint32 or
      (loadU8(ind, SmStaAddQosOff).uint32 shl 8) or
      (loadU8(vif, BlVifLinksNumOff).uint32 shl 16) or
      (loadU8(vif, BlVifFixedStaIdxOff).uint32 shl 24)
    if loadU8(vif, BlVifLinksNumOff) > 0:
      inc nimFwDbgRxSmStaAddError
      bl_os_printf("[WF] Error: illegal sm_sta_add, sta_idx: %d\r\n", loadU8(ind, SmStaAddApIdxOff).cint)
      return -1
    storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) + 1)
    storeU8(vif, BlVifFcChanOff, 0)
    storeU8(vif, BlVifFixedStaIdxOff, loadU8(ind, SmStaAddApIdxOff))
    let sta = staAt(blHw, loadU8(ind, SmStaAddApIdxOff).uint)
    storeU8(sta, BlStaStaIdxOff, loadU8(ind, SmStaAddApIdxOff))
    storeU8(sta, BlStaVifIdxOff, BlVifSta.uint8)
    storeU8(sta, BlStaQosOff, loadU8(ind, SmStaAddQosOff))
    storeU8(sta, BlStaFcPsOff, 0)
    storeU8(sta, BlStaIsUsedOff, 1)
    nimFwDbgRxSmStaAddVif = loadU8(vif, BlVifLinksNumOff).uint32 or
      (loadU8(vif, BlVifFixedStaIdxOff).uint32 shl 8) or
      (loadU8(vif, BlVifFcChanOff).uint32 shl 16) or
      (loadU8(vif, BlVifStaPsOff).uint32 shl 24)
    nimFwDbgRxSmStaAddSta = loadU8(sta, BlStaIsUsedOff).uint32 or
      (loadU8(sta, BlStaStaIdxOff).uint32 shl 8) or
      (loadU8(sta, BlStaVifIdxOff).uint32 shl 16) or
      (loadU8(sta, BlStaQosOff).uint32 shl 24)
    bl_tx_cntrl_link_up(cast[ptr BlSta](sta))
    0

  proc blRxApmStaAddInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
    let ind = msgParam(msg)
    bl_os_printf("[WF] APM_STA_ADD_IND\r\n")
    bl_os_printf("[WF]    flags %08X\r\n", loadU32(ind, ApmFlagsOff).cuint)
    bl_os_printf("[WF]    MAC %02X:%02X:%02X:%02X:%02X:%02X\r\n",
                 loadU8(ind, ApmStaAddrOff + 0).cuint, loadU8(ind, ApmStaAddrOff + 1).cuint,
                 loadU8(ind, ApmStaAddrOff + 2).cuint, loadU8(ind, ApmStaAddrOff + 3).cuint,
                 loadU8(ind, ApmStaAddrOff + 4).cuint, loadU8(ind, ApmStaAddrOff + 5).cuint)
    bl_os_printf("[WF]    vif_idx %u\r\n", BlVifAp.cuint)
    bl_os_printf("[WF]    sta_idx %u\r\n", loadU8(ind, ApmStaIdxOff).cuint)
    bl_os_log_info("[WF]    tsflo: 0x%lx\r\n", loadU32(ind, ApmTsfloOff).culong)
    bl_os_log_info("[WF]    tsfhi: 0x%lx\r\n", loadU32(ind, ApmTsfhiOff).culong)
    bl_os_log_info("[WF]    rssi: %d\r\n", loadI8(ind, ApmRssiOff).cint)
    bl_os_log_info("[WF]    data rate: 0x%x\r\n", loadU8(ind, ApmDataRateOff).cuint)
    let staIdx = loadU8(ind, ApmStaIdxOff)
    if staIdx >= NxRemoteStaStoreMax:
      bl_os_printf("[WF]    Error: Potential illegal sta_idx: %d\r\n", staIdx.cint)
      return -1
    var sta = staAt(blHw, staIdx.uint)
    if loadU8(sta, BlStaIsUsedOff) != 0:
      bl_os_log_info("[WF]    Warning: sta_idx already used: %d\r\n", staIdx.cint)
    copyMem(ptrAt(sta, BlStaAddrOff), ptrAt(ind, ApmStaAddrOff), 6)
    storeU8(sta, BlStaQosOff, if (loadU32(ind, ApmFlagsOff) and StaQosCapa) != 0: 1 else: 0)
    storeU8(sta, BlStaStaIdxOff, staIdx)
    storeU8(sta, BlStaVifIdxOff, BlVifAp.uint8)
    storeI8(sta, BlStaRssiOff, loadI8(ind, ApmRssiOff))
    storeU32(sta, BlStaTsfloOff, loadU32(ind, ApmTsfloOff))
    storeU32(sta, BlStaTsfhiOff, loadU32(ind, ApmTsfhiOff))
    storeU8(sta, BlStaDataRateOff, loadU8(ind, ApmDataRateOff))
    storeU8(sta, BlStaFcPsOff, 0)
    storeU8(sta, BlStaIsUsedOff, 1)
    bl_tx_cntrl_link_up(cast[ptr BlSta](sta))
    let vif = vifAt(blHw, BlVifAp)
    if loadU8(vif, BlVifLinksNumOff) == 0:
      storeU8(vif, BlVifFcChanOff, 0)
      sta = staAt(hwRaw(), loadU8(vif, BlVifFixedStaIdxOff).uint)
      if (loadU32(ind, ApmFlagsOff) and StaQosCapa) == 0:
        storeU8(sta, BlStaQosOff, 0)
      storeU8(sta, BlStaFcPsOff, 0)
      storeU8(sta, BlStaIsUsedOff, 1)
      bl_tx_cntrl_link_up(cast[ptr BlSta](sta))
      storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) + 1)
      let dev = loadPtr(vif, BlVifDevOff)
      if dev != nil:
        netifapi_netif_set_link_up(cast[ptr Netif](dev))
    else:
      storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) + 1)
    discard aos_post_event(EvWifi, CodeWifiOnApStaAdd, staIdx.cint)
    0

  proc blRxApmStaDelInd(blHw, cmd, msg: pointer): cint {.cdecl.} =
    let ind = msgParam(msg)
    let staIdx = loadU8(ind, ApmDelStaIdxOff)
    let vif = vifAt(blHw, BlVifAp)
    bl_os_printf("[WF] APM_STA_DEL_IND\r\n")
    bl_os_printf("[WF]    sta_idx %u\r\n", staIdx.cuint)
    bl_os_printf("[WF]    statuts_code %u\r\n", loadU16(ind, ApmDelStatusOff).cuint)
    bl_os_printf("[WF]    reason_code %u\r\n", loadU16(ind, ApmDelReasonOff).cuint)
    bl_os_printf("[RX]    disconnect reason: %s\r\n", apmStatusStr(loadU16(ind, ApmDelStatusOff)))
    if staIdx >= NxRemoteStaStoreMax or loadU8(vif, BlVifLinksNumOff) == 0:
      bl_os_printf("[WF]    Error: Potential illegal sta_idx: %d, or no link_num\r\n", staIdx.cint)
      return -1
    var sta = staAt(blHw, staIdx.uint)
    if loadU8(sta, BlStaIsUsedOff) == 0:
      bl_os_log_info("[WF]    Warning: sta_idx already empty: %d\r\n", staIdx.cint)
    storeU8(sta, BlStaIsUsedOff, 0)
    bl_tx_cntrl_link_down(cast[ptr BlSta](sta))
    storeU8(vif, BlVifLinksNumOff, loadU8(vif, BlVifLinksNumOff) - 1)
    bl_os_printf("[WF]    links_num %u\r\n", loadU8(vif, BlVifLinksNumOff).cuint)
    if loadU8(vif, BlVifLinksNumOff) == 0:
      storeU8(vif, BlVifFcChanOff, 0)
      sta = staAt(hwRaw(), loadU8(vif, BlVifFixedStaIdxOff).uint)
      storeU8(sta, BlStaIsUsedOff, 0)
      bl_tx_cntrl_link_down(cast[ptr BlSta](sta))
      let dev = loadPtr(vif, BlVifDevOff)
      if dev != nil:
        netifapi_netif_set_link_down(cast[ptr Netif](dev))
    discard aos_post_event(EvWifi, CodeWifiOnApStaDel, staIdx.cint)
    0

  proc rxHandlerFor(id: uint16): MsgCbProc =
    let task = msgTask(id)
    let index = msgIndex(id)
    case task
    of TaskMM:
      case index
      of MmChannelSwitchI: blRxChanSwitchInd
      of MmChannelPreSwitchI, MmRemainOnChannelExpI, MmPsChangeI,
         MmTrafficReqI, MmChannelSurveyI: blCommonInd
      of MmRssiStatusI: blRxRssiStatusInd
      else: nil
    of TaskScanu:
      case index
      of ScanuStartCfmI: blRxScanuStartCfm
      of ScanuJoinCfmI: blRxScanuJoinCfm
      of ScanuResultI: blRxScanuResultInd
      else: nil
    of TaskMe:
      case index
      of MeTkipMicFailureI, MeTxCreditsUpdateI: blCommonInd
      else: nil
    of TaskSm:
      case index
      of SmConnectI: blRxSmConnectInd
      of SmDisconnectI: blRxSmDisconnectInd
      of SmStaAddI: blRxSmStaAddInd
      else: nil
    of TaskApm:
      case index
      of ApmStaAddI: blRxApmStaAddInd
      of ApmStaDelI: blRxApmStaDelInd
      else: nil
    of TaskCfg:
      nil
    else:
      nil

  proc dispatchMsg(blHw, msg: pointer) =
    let cmdMgr = ptrAt(blHw, BlHwCmdMgrOff)
    let msgind = cast[CmdMsgindProc](loadPtr(cmdMgr, CmdMgrMsgindOff))
    if msgind != nil:
      let cb = rxHandlerFor(loadU16(msg, IpcMsgIdOff))
      discard msgind(cmdMgr, msg, cb)

  proc bl_rx_handle_msg*(blHw: ptr BlHw; msg: pointer) {.exportc, cdecl.} =
    dispatchMsg(cast[pointer](blHw), msg)

  proc bl_rx_e2a_handler*(arg: pointer) {.exportc, cdecl.} =
    dispatchMsg(hwRaw(), arg)

  proc bl_rx_pkt_cb*(pkt: ptr uint8; len: cint; pktWrap: pointer; info: ptr BlRxInfo) {.exportc, cdecl.} =
    if cbPkt != nil:
      cbPkt(cbPktEnv, pkt, len, info)
    if cbPktAdv != nil:
      cbPktAdv(cbPktEnv, pktWrap, info)

  proc bl_rx_sm_connect_ind_cb_register*(env: pointer; cb: ConnectCb): cint {.exportc, cdecl.} =
    cbSmConnect = cb
    cbSmConnectEnv = env
    0

  proc bl_rx_sm_connect_ind_cb_unregister*(env: pointer; cb: ConnectCb): cint {.exportc, cdecl.} =
    cbSmConnect = nil
    cbSmConnectEnv = nil
    0

  proc bl_rx_sm_disconnect_ind_cb_register*(env: pointer; cb: DisconnectCb): cint {.exportc, cdecl.} =
    cbSmDisconnect = cb
    cbSmDisconnectEnv = env
    0

  proc bl_rx_sm_disconnect_ind_cb_unregister*(env: pointer; cb: DisconnectCb): cint {.exportc, cdecl.} =
    cbSmDisconnect = nil
    cbSmDisconnectEnv = nil
    0

  proc bl_rx_beacon_ind_cb_register*(env: pointer; cb: BeaconCb): cint {.exportc, cdecl.} =
    cbBeacon = cb
    cbBeaconEnv = env
    0

  proc bl_rx_beacon_ind_cb_unregister*(env: pointer; cb: BeaconCb): cint {.exportc, cdecl.} =
    cbBeacon = nil
    cbBeaconEnv = nil
    0

  proc bl_rx_probe_resp_ind_cb_register*(env: pointer; cb: ProbeRespCb): cint {.exportc, cdecl.} =
    cbProbeResp = cb
    cbProbeRespEnv = env
    0

  proc bl_rx_probe_resp_ind_cb_unregister*(env: pointer; cb: ProbeRespCb): cint {.exportc, cdecl.} =
    cbProbeResp = nil
    cbProbeRespEnv = nil
    0

  proc bl_rx_pkt_cb_register*(env: pointer; cb: PktCb): cint {.exportc, cdecl.} =
    cbPkt = cb
    cbPktEnv = env
    0

  proc bl_rx_pkt_cb_unregister*(env: pointer): cint {.exportc, cdecl.} =
    cbPkt = nil
    cbPktEnv = nil
    0

  proc bl_rx_pkt_adv_cb_register*(env: pointer; cb: PktAdvCb): cint {.exportc, cdecl.} =
    cbPktAdv = cb
    cbPktEnv = env
    0

  proc bl_rx_pkt_adv_cb_unregister*(env: pointer): cint {.exportc, cdecl.} =
    cbPktAdv = nil
    cbPktEnv = nil
    0

  proc bl_rx_rssi_cb_register*(env: pointer; cb: RssiCb): cint {.exportc, cdecl.} =
    cbRssi = cb
    cbRssiEnv = env
    0

  proc bl_rx_rssi_cb_unregister*(env: pointer; cb: RssiCb): cint {.exportc, cdecl.} =
    cbRssi = nil
    cbRssiEnv = nil
    0

  proc bl_rx_event_register*(env: pointer; cb: EventCb): cint {.exportc, cdecl.} =
    cbEvent = cb
    cbEventEnv = env
    0

  proc bl_rx_event_unregister*(env: pointer): cint {.exportc, cdecl.} =
    cbEvent = nil
    cbEventEnv = nil
    0
