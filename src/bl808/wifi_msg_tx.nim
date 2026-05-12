## Nim replacement for the BL808 WiFi host message request builders.

when defined(bl808m0) and defined(bl808WifiVendor) and defined(bl808WifiNimFw):
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/include".}

  const
    Enomem = 12.cint
    Ebusy = 16.cint
    Eintr = 4'i32

    RwnxCmdFlagNonblock = 1'u16 shl 0
    RwnxCmdFlagReqCfm = 1'u16 shl 1

    OpMallocOff = 184'u
    OpFreeOff = 188'u

    BlHwIpcEnvOff = 48'u
    BlHwVifTableOff = 60'u
    BlHwModParamsOff = 220'u
    BlHwHtCapOff = 224'u
    BlVifSize = 20'u
    BlVifVifIdxOff = 13'u

    BlModParamsUapsdTimeoutOff = 12'u
    BlModParamsListenItvOff = 20'u
    BlModParamsListenBcmcOff = 24'u
    BlModParamsLpClkPpmOff = 28'u
    BlModParamsPsOnOff = 32'u
    BlModParamsTxLftOff = 36'u
    BlModParamsUapsdQueuesOff = 44'u

    HtCapCapOff = 0'u
    HtCapMcsOff = 6'u

    LmacMsgIdOff = 0'u
    LmacMsgDestIdOff = 2'u
    LmacMsgSrcIdOff = 3'u
    LmacMsgParamLenOff = 4'u
    LmacMsgParamOff = 8'u
    LmacMsgHeaderLen = 8'u

    BlCmdSize = 36'u
    BlCmdIdOff = 8'u
    BlCmdReqidOff = 10'u
    BlCmdA2eMsgOff = 12'u
    BlCmdE2aMsgOff = 16'u
    BlCmdFlagsOff = 24'u
    BlCmdResultOff = 32'u
    BlHwCmdMgrQueueOff = 28'u

    SizeMmMonitorReq = 4'u16
    SizeMmBeaconIntReq = 4'u16
    SizeMmMonitorChannelReq = 4'u16
    SizeMeConfigReq = 52'u16
    SizeMeChanConfigReq = 86'u16
    SizeMeRcSetRateReq = 6'u16
    SizeMmStartReq = 72'u16
    SizeMmAddIfReq = 8'u16
    SizeMmRemoveIfReq = 1'u16
    SizeScanuStartReq = 320'u16
    SizeScanuRawSendReq = 8'u16
    SizeSmConnectReq = 192'u16
    SizeSmDisconnectReq = 1'u16
    SizeSmConnectAbortReq = 1'u16
    SizeMmSetPsModeReq = 1'u16
    SizeMmSetDenoiseReq = 1'u16
    SizeApmStartReq = 236'u16
    SizeApmStopReq = 1'u16
    SizeApmStaDelReq = 2'u16
    SizeApmConfMaxStaReq = 1'u16
    SizeCfgStartReq = 36'u16
    SizeMmSetChannelReq = 10'u16

    ScanChanSize = 6'u
    ScanChanFreqOff = 0'u
    ScanChanBandOff = 2'u
    ScanChanFlagsOff = 3'u
    ScanChanTxPowerOff = 4'u

    MacSsidLengthOff = 0'u
    MacSsidArrayOff = 1'u
    MacSsidSize = 34'u
    MacRatesetLengthOff = 0'u
    MacRatesetArrayOff = 1'u

    MeConfigHtCapOff = 0'u
    MeConfigTxLftOff = 44'u
    MeConfigHtSuppOff = 46'u
    MeConfigVhtSuppOff = 47'u
    MeConfigPsOnOff = 48'u
    MacHtCapInfoOff = 0'u
    MacHtAmpduOff = 2'u
    MacHtMcsRateOff = 3'u
    MacHtExtCapOff = 20'u
    MacHtBeamformOff = 24'u
    MacHtAselOff = 28'u

    MeChanChan2G4Off = 0'u
    MeChanCountOff = 84'u
    MeRcStaIdxOff = 0'u
    MeRcFixedRateOff = 2'u
    MeRcPowerTableReqOff = 4'u
    MmStartPhyCfgOff = 0'u
    MmStartUapsdTimeoutOff = 64'u
    MmStartLpClkAccuracyOff = 68'u
    MmAddIfTypeOff = 0'u
    MmAddIfAddrOff = 1'u
    MmAddIfP2pOff = 7'u
    MmRemoveIfInstOff = 0'u

    ScanuChanOff = 0'u
    ScanuSsidOff = 252'u
    ScanuBssidOff = 286'u
    ScanuMacOff = 292'u
    ScanuAddIesOff = 300'u
    ScanuAddIeLenOff = 304'u
    ScanuVifIdxOff = 306'u
    ScanuChanCntOff = 307'u
    ScanuSsidCntOff = 308'u
    ScanuNoCckOff = 309'u
    ScanuDurationOff = 316'u
    ScanuRawPktOff = 0'u
    ScanuRawLenOff = 4'u

    SmSsidOff = 0'u
    SmBssidOff = 34'u
    SmChanOff = 40'u
    SmFlagsOff = 48'u
    SmCtrlPortEthertypeOff = 52'u
    SmListenIntervalOff = 54'u
    SmDontWaitBcmcOff = 56'u
    SmAuthTypeOff = 57'u
    SmUapsdQueuesOff = 58'u
    SmVifIdxOff = 59'u
    SmSupplicantEnabledOff = 61'u
    SmPhraseOff = 62'u
    SmPhrasePmkOff = 126'u

    ApmBasicRatesOff = 0'u
    ApmChanOff = 14'u
    ApmCenterFreq1Off = 20'u
    ApmCenterFreq2Off = 24'u
    ApmChWidthOff = 28'u
    ApmHiddenSsidOff = 29'u
    ApmBcnAddrOff = 32'u
    ApmBcnLenOff = 36'u
    ApmTimOftOff = 38'u
    ApmBcnIntOff = 40'u
    ApmFlagsOff = 44'u
    ApmCtrlPortEthertypeOff = 48'u
    ApmTimLenOff = 50'u
    ApmVifIdxOff = 51'u
    ApmEmbEnabledOff = 52'u
    ApmRateSetOff = 53'u
    ApmBeaconPeriodOff = 66'u
    ApmQosSupportedOff = 67'u
    ApmSsidOff = 68'u
    ApmSecTypeOff = 102'u
    ApmPhraseOff = 103'u
    ApmBcnBufLenOff = 168'u
    ApmBcnBufOff = 169'u

    CfgOpsOff = 0'u
    CfgSetTaskOff = 4'u
    CfgSetElementOff = 8'u
    CfgSetTypeOff = 12'u
    CfgSetLengthOff = 16'u
    CfgSetBufOff = 20'u

    MmSetChannelBandOff = 0'u
    MmSetChannelTypeOff = 1'u
    MmSetChannelPrim20Off = 2'u
    MmSetChannelCenter1Off = 4'u
    MmSetChannelCenter2Off = 6'u
    MmSetChannelIndexOff = 8'u
    MmSetChannelTxPowerOff = 9'u

    ConnChannelOff = 0'u
    ConnBssidOff = 56'u
    ConnSsidOff = 64'u
    ConnSsidLenOff = 68'u
    ConnAuthTypeOff = 72'u
    ConnMfpOff = 84'u
    ConnCryptoOff = 88'u
    ConnKeyOff = 148'u
    ConnPmkOff = 152'u
    ConnKeyLenOff = 156'u
    ConnPmkLenOff = 157'u
    ConnFlagsOff = 160'u
    ConnChanBandOff = 0'u
    ConnChanFreqOff = 2'u
    ConnChanFlagsOff = 8'u
    CryptoCipherGroupOff = 4'u
    CryptoNCiphersOff = 8'u
    CryptoCiphers0Off = 12'u
    CryptoControlPortOff = 44'u
    CryptoControlEthertypeOff = 46'u
    CryptoControlNoEncOff = 48'u

    ScanParaChannelsOff = 0'u
    ScanParaChannelNumOff = 4'u
    ScanParaBssidOff = 8'u
    ScanParaSsidOff = 12'u
    ScanParaMacOff = 16'u
    ScanParaModeOff = 20'u
    ScanParaDurationOff = 24'u

    MM_RESET_REQ = 0'u16
    MM_RESET_CFM = 1'u16
    MM_START_REQ = 2'u16
    MM_START_CFM = 3'u16
    MM_VERSION_REQ = 4'u16
    MM_VERSION_CFM = 5'u16
    MM_ADD_IF_REQ = 6'u16
    MM_ADD_IF_CFM = 7'u16
    MM_REMOVE_IF_REQ = 8'u16
    MM_REMOVE_IF_CFM = 9'u16
    MM_SET_CHANNEL_REQ = 14'u16
    MM_SET_CHANNEL_CFM = 15'u16
    MM_SET_BEACON_INT_REQ = 16'u16
    MM_SET_BEACON_INT_CFM = 17'u16
    MM_DENOISE_REQ = 30'u16
    MM_SET_PS_MODE_REQ = 31'u16
    MM_SET_PS_MODE_CFM = 32'u16
    MM_TIM_UPDATE_REQ = 48'u16
    MM_BFMER_ENABLE_REQ = 63'u16
    MM_MONITOR_REQ = 70'u16
    MM_MONITOR_CFM = 71'u16
    MM_MONITOR_CHANNEL_REQ = 72'u16
    MM_MONITOR_CHANNEL_CFM = 73'u16
    SCANU_START_REQ = 2048'u16
    SCANU_RAW_SEND_REQ = 2053'u16
    SCANU_RAW_SEND_CFM = 2054'u16
    ME_CONFIG_REQ = 3072'u16
    ME_CONFIG_CFM = 3073'u16
    ME_CHAN_CONFIG_REQ = 3074'u16
    ME_CHAN_CONFIG_CFM = 3075'u16
    ME_RC_SET_RATE_REQ = 3084'u16
    ME_TRAFFIC_IND_REQ = 3082'u16
    SM_CONNECT_REQ = 4096'u16
    SM_CONNECT_CFM = 4097'u16
    SM_DISCONNECT_REQ = 4099'u16
    SM_DISCONNECT_CFM = 4100'u16
    SM_CONNECT_ABORT_REQ = 4103'u16
    SM_CONNECT_ABORT_CFM = 4104'u16
    APM_START_REQ = 5120'u16
    APM_START_CFM = 5121'u16
    APM_STOP_REQ = 5122'u16
    APM_STOP_CFM = 5123'u16
    APM_STA_DEL_REQ = 5127'u16
    APM_STA_DEL_CFM = 5128'u16
    APM_CONF_MAX_STA_REQ = 5129'u16
    APM_CONF_MAX_STA_CFM = 5130'u16
    CFG_START_REQ = 8192'u16
    CFG_START_CFM = 8193'u16

    TASK_MM = 0'u8
    TASK_SCANU = 2'u8
    TASK_ME = 3'u8
    TASK_SM = 4'u8
    TASK_APM = 5'u8
    TASK_CFG = 8'u8
    DRV_TASK_ID = 100'u8

    MM_STA = 0'u8
    MM_IBSS = 1'u8
    MM_AP = 2'u8
    MM_MESH_POINT = 3'u8
    NL80211_IFTYPE_ADHOC = 1.cint
    NL80211_IFTYPE_STATION = 2.cint
    NL80211_IFTYPE_AP = 3.cint
    NL80211_IFTYPE_AP_VLAN = 4.cint
    NL80211_IFTYPE_MESH_POINT = 7.cint
    NL80211_BAND_2GHZ = 0'u8
    PHY_BAND_2G4 = 0'u8
    PHY_CHNL_BW_20 = 0'u8
    SCAN_PASSIVE = 0'u8
    SCAN_PASSIVE_BIT = 1'u8
    SCAN_DISABLED_BIT = 2'u8
    SCAN_CHANNEL_2G4 = 14
    DISABLE_HT = 4'u32
    CONTROL_PORT_HOST = 1'u32
    CONTROL_PORT_NO_ENC = 2'u32
    WPA_WPA2_IN_USE = 8'u32
    MFP_IN_USE = 16'u32
    NL80211_MFP_REQUIRED = 1'u32
    NL80211_AUTHTYPE_AUTOMATIC = 8'u32
    NL80211_AUTHTYPE_OPEN_SYSTEM = 0'u8
    WLAN_CIPHER_SUITE_WEP40 = 0x000f_ac01'u32
    WLAN_CIPHER_SUITE_TKIP = 0x000f_ac02'u32
    WLAN_CIPHER_SUITE_WEP104 = 0x000f_ac05'u32

    IEEE80211_CHAN_DISABLED = 1'u32 shl 0
    IEEE80211_CHAN_NO_IR = 1'u32 shl 1
    IEEE80211_CHAN_RADAR = 1'u32 shl 3

  type
    BlHw {.importc: "struct bl_hw", header: "bl_defs.h".} = object
    BlOpsFuncs {.importc: "bl_ops_funcs_t", header: "bl_os_adapter.h".} = object
    Cfg80211ConnectParams {.importc: "struct cfg80211_connect_params",
                            header: "cfg80211.h".} = object
    MmMonitorCfmObj {.importc: "struct mm_monitor_cfm", header: "lmac_msg.h".} = object
    MmMonitorChannelCfmObj {.importc: "struct mm_monitor_channel_cfm",
                          header: "lmac_msg.h".} = object
    MmBeaconCfmObj {.importc: "struct mm_set_beacon_int_cfm",
                  header: "lmac_msg.h".} = object
    MmVersionCfmObj {.importc: "struct mm_version_cfm", header: "lmac_msg.h".} = object
    MmAddIfCfmObj {.importc: "struct mm_add_if_cfm", header: "lmac_msg.h".} = object
    SmConnectCfmObj {.importc: "struct sm_connect_cfm", header: "lmac_msg.h".} = object
    SmAbortCfmObj {.importc: "struct sm_connect_abort_cfm", header: "lmac_msg.h".} = object
    ApmStartCfmObj {.importc: "struct apm_start_cfm", header: "lmac_msg.h".} = object
    ApmStaDelCfmObj {.importc: "struct apm_sta_del_cfm", header: "lmac_msg.h".} = object
    ScanuPara = object

    MallocProc = proc(size: csize_t): pointer {.cdecl.}
    FreeProc = proc(p: pointer) {.cdecl.}
    CmdQueueProc = proc(cmdMgr, cmd: pointer): cint {.cdecl.}

  var g_bl_ops_funcs {.importc, header: "bl_os_adapter.h".}: BlOpsFuncs

  proc c_memset(s: pointer; c: cint; n: csize_t): pointer
    {.importc: "memset", header: "<string.h>", cdecl.}
  proc c_memcpy(dest, src: pointer; n: csize_t): pointer
    {.importc: "memcpy", header: "<string.h>", cdecl.}
  proc c_memcmp(a, b: pointer; n: csize_t): cint
    {.importc: "memcmp", header: "<string.h>", cdecl.}
  proc c_strlen(s: cstring): csize_t
    {.importc: "strlen", header: "<string.h>", cdecl.}
  proc bl_os_printf(fmt: cstring)
    {.importc, header: "bl_os_private.h", cdecl, varargs.}
  proc utils_tlv_bl_pack_auto(buf: ptr uint32; bufSz: cint; typ: uint16;
                              arg1: pointer): uint32
    {.importc, header: "utils_tlv_bl.h", cdecl.}
  proc bl808_wifi_vendor_poll(iterations: cuint) {.importc, cdecl.}

  template ptrAt(base: pointer; off: uint): pointer =
    cast[pointer](cast[uint](base) + off)

  proc opPtr(off: uint): pointer {.inline.} =
    cast[ptr pointer](cast[uint](addr g_bl_ops_funcs) + off)[]

  proc osMalloc(size: uint): pointer {.inline.} =
    let fn = cast[MallocProc](opPtr(OpMallocOff))
    if fn == nil: nil else: fn(size.csize_t)

  proc osFree(p: pointer) {.inline.} =
    let fn = cast[FreeProc](opPtr(OpFreeOff))
    if fn != nil:
      fn(p)

  proc zero(p: pointer; n: uint) {.inline.} =
    discard c_memset(p, 0, n.csize_t)

  proc copyMem(dest, src: pointer; n: uint) {.inline.} =
    if dest != nil and src != nil and n != 0:
      discard c_memcpy(dest, src, n.csize_t)

  proc loadPtr(base: pointer; off: uint): pointer {.inline.} =
    cast[ptr pointer](ptrAt(base, off))[]

  proc storePtr(base: pointer; off: uint; value: pointer) {.inline.} =
    cast[ptr pointer](ptrAt(base, off))[] = value

  proc loadU8(base: pointer; off: uint): uint8 {.inline.} =
    cast[ptr uint8](ptrAt(base, off))[]

  proc storeU8(base: pointer; off: uint; value: uint8) {.inline.} =
    cast[ptr uint8](ptrAt(base, off))[] = value

  proc loadU16(base: pointer; off: uint): uint16 {.inline.} =
    cast[ptr uint16](ptrAt(base, off))[]

  proc storeU16(base: pointer; off: uint; value: uint16) {.inline.} =
    cast[ptr uint16](ptrAt(base, off))[] = value

  proc loadU32(base: pointer; off: uint): uint32 {.inline.} =
    cast[ptr uint32](ptrAt(base, off))[]

  proc storeU32(base: pointer; off: uint; value: uint32) {.inline.} =
    cast[ptr uint32](ptrAt(base, off))[] = value

  proc loadI32(base: pointer; off: uint): int32 {.inline.} =
    cast[ptr int32](ptrAt(base, off))[]

  proc storeI32(base: pointer; off: uint; value: int32) {.inline.} =
    cast[ptr int32](ptrAt(base, off))[] = value

  var channelNumDefault: int32
  var countryCode0: uint8
  var countryCode1: uint8
  var countryMaxPower: uint8

  proc channelFreq(index: int): uint16 {.inline.} =
    if index == 13: 2484'u16 else: (2412 + index * 5).uint16

  proc passiveScanFlag(flags: uint32): uint8 {.inline.} =
    if (flags and (IEEE80211_CHAN_NO_IR or IEEE80211_CHAN_RADAR)) != 0'u32:
      SCAN_PASSIVE_BIT
    else:
      0'u8

  proc channelCountFor(code: cstring): int32 =
    if code != nil and code[0] == 'J' and code[1] == 'P':
      14
    elif code != nil and code[0] == 'U' and code[1] == 'S':
      11
    elif code != nil and code[0] == 'E' and code[1] == 'U':
      13
    elif code != nil and code[0] == 'C' and code[1] == 'N':
      13
    else:
      -1

  proc bl_msg_update_channel_cfg*(code: cstring) {.exportc, cdecl.} =
    let count = channelCountFor(code)
    if count < 0:
      channelNumDefault = 14
      countryCode0 = 'C'.uint8
      countryCode1 = 'N'.uint8
      countryMaxPower = 20
      bl_os_printf("[WF] %s NOT found, using General instead, num of channel %d\r\n",
                   code, channelNumDefault)
    else:
      channelNumDefault = count
      countryCode0 = code[0].uint8
      countryCode1 = code[1].uint8
      countryMaxPower = 20
      bl_os_printf("[WF] country code %s used, num of channel %d\r\n",
                   code, channelNumDefault)

  proc bl_msg_get_channel_nums*(): cint {.exportc, cdecl.} =
    channelNumDefault.cint

  proc bl_get_fixed_channels_is_valid*(channels: ptr uint16; channelNum: uint16): cint
      {.exportc, cdecl.} =
    if channelNum == 0:
      return 0
    for i in 0 ..< channelNum.int:
      let channel = cast[ptr UncheckedArray[uint16]](channels)[i]
      if channel == 0'u16 or channel > channelNumDefault.uint16:
        return 0
    1

  proc phy_channel_to_freq*(band: uint8; channel: cint): uint16 {.exportc, cdecl.} =
    if band == PHY_BAND_2G4:
      if channel < 1 or channel > 14:
        0xffff'u16
      elif channel == 14:
        2484'u16
      else:
        (2407 + channel * 5).uint16
    else:
      0xffff'u16

  proc phy_freq_to_channel*(band: uint8; freq: uint16): uint8 {.exportc, cdecl.} =
    if band == PHY_BAND_2G4:
      if freq < 2412'u16 or freq > 2484'u16:
        0'u8
      elif freq == 2484'u16:
        14'u8
      else:
        ((freq - 2407'u16) div 5'u16).uint8
    else:
      0'u8

  proc blMsgZalloc(id: uint16; dest, src: uint8; paramLen: uint16): pointer =
    let msg = osMalloc(LmacMsgHeaderLen + paramLen.uint)
    if msg == nil:
      bl_os_printf("%s: msg allocation failed\n", "bl_msg_zalloc")
      return nil
    zero(msg, LmacMsgHeaderLen + paramLen.uint)
    storeU16(msg, LmacMsgIdOff, id)
    storeU8(msg, LmacMsgDestIdOff, dest)
    storeU8(msg, LmacMsgSrcIdOff, src)
    storeU16(msg, LmacMsgParamLenOff, paramLen)
    ptrAt(msg, LmacMsgParamOff)

  proc isNonBlockingMsg(id: uint16): bool {.inline.} =
    id == MM_TIM_UPDATE_REQ or id == ME_RC_SET_RATE_REQ or
      id == MM_BFMER_ENABLE_REQ or id == ME_TRAFFIC_IND_REQ or
      id == SM_DISCONNECT_REQ

  proc blSendMsg(blHw: ptr BlHw; msgParams: pointer; reqcfm: cint;
                 reqid: uint16; cfm: pointer): cint =
    let hw = cast[pointer](blHw)
    let msg = ptrAt(msgParams, 0'u - LmacMsgHeaderLen)
    if loadPtr(hw, BlHwIpcEnvOff) == nil:
      bl_os_printf("%s: bypassing (restart must have failed)\r\n", "bl_send_msg")
      osFree(msg)
      return -Ebusy

    let cmd = osMalloc(BlCmdSize)
    if cmd == nil:
      osFree(msg)
      bl_os_printf("%s: failed to allocate mem for cmd, size is %d\r\n",
                   "bl_send_msg", BlCmdSize.cint)
      return -Enomem
    zero(cmd, BlCmdSize)

    let id = loadU16(msg, LmacMsgIdOff)
    storeI32(cmd, BlCmdResultOff, Eintr)
    storeU16(cmd, BlCmdIdOff, id)
    storeU16(cmd, BlCmdReqidOff, reqid)
    storePtr(cmd, BlCmdA2eMsgOff, msg)
    storePtr(cmd, BlCmdE2aMsgOff, cfm)
    var flags = 0'u16
    let nonblock = isNonBlockingMsg(id)
    if nonblock:
      flags = flags or RwnxCmdFlagNonblock
    if reqcfm != 0:
      flags = flags or RwnxCmdFlagReqCfm
    storeU16(cmd, BlCmdFlagsOff, flags)

    let queue = cast[CmdQueueProc](loadPtr(hw, BlHwCmdMgrQueueOff))
    var ret = if queue == nil: -Ebusy else: queue(hw, cmd)
    if not nonblock:
      osFree(cmd)
    else:
      ret = loadI32(cmd, BlCmdResultOff).cint
    ret

  proc sendEmpty(blHw: ptr BlHw; id: uint16; dest: uint8; reqcfm: cint;
                 reqid: uint16; cfm: pointer): cint =
    let req = blMsgZalloc(id, dest, DRV_TASK_ID, 0)
    if req == nil: -Enomem else: blSendMsg(blHw, req, reqcfm, reqid, cfm)

  proc fillScanChan(req: pointer; off: uint; index: int; flags: uint8; txPower: uint8) =
    storeU16(req, off + ScanChanFreqOff, channelFreq(index))
    storeU8(req, off + ScanChanBandOff, NL80211_BAND_2GHZ)
    storeU8(req, off + ScanChanFlagsOff, flags)
    storeU8(req, off + ScanChanTxPowerOff, txPower)

  proc staVifIdx(blHw: ptr BlHw): uint8 {.inline.} =
    loadU8(ptrAt(cast[pointer](blHw), BlHwVifTableOff), BlVifVifIdxOff)

  proc bl_send_reset*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
    sendEmpty(blHw, MM_RESET_REQ, TASK_MM, 1, MM_RESET_CFM, nil)

  proc bl_send_monitor_enable*(blHw: ptr BlHw; cfm: ptr MmMonitorCfmObj): cint
      {.exportc, cdecl.} =
    let req = blMsgZalloc(MM_MONITOR_REQ, TASK_MM, DRV_TASK_ID, SizeMmMonitorReq)
    if req == nil: return -Enomem
    storeU32(req, 0, 1'u32)
    blSendMsg(blHw, req, 1, MM_MONITOR_CFM, cfm)

  proc bl_send_monitor_disable*(blHw: ptr BlHw; cfm: ptr MmMonitorCfmObj): cint
      {.exportc, cdecl.} =
    let req = blMsgZalloc(MM_MONITOR_REQ, TASK_MM, DRV_TASK_ID, SizeMmMonitorReq)
    if req == nil: return -Enomem
    storeU32(req, 0, 0'u32)
    blSendMsg(blHw, req, 1, MM_MONITOR_CFM, cfm)

  proc bl_send_beacon_interval_set*(blHw: ptr BlHw; cfm: ptr MmBeaconCfmObj;
                                    beaconInt: uint16): cint {.exportc, cdecl.} =
    let req = blMsgZalloc(MM_SET_BEACON_INT_REQ, TASK_MM, DRV_TASK_ID, SizeMmBeaconIntReq)
    if req == nil: return -Enomem
    storeU16(req, 0, beaconInt)
    blSendMsg(blHw, req, 1, MM_SET_BEACON_INT_CFM, cfm)

  proc bl_send_monitor_channel_set*(blHw: ptr BlHw; cfm: ptr MmMonitorChannelCfmObj;
                                    channel, use40Mhz: cint): cint {.exportc, cdecl.} =
    let req = blMsgZalloc(MM_MONITOR_CHANNEL_REQ, TASK_MM, DRV_TASK_ID,
                          SizeMmMonitorChannelReq)
    if req == nil: return -Enomem
    storeU16(req, 0, phy_channel_to_freq(PHY_BAND_2G4, channel))
    blSendMsg(blHw, req, 1, MM_MONITOR_CHANNEL_CFM, cfm)

  proc bl_send_version_req*(blHw: ptr BlHw; cfm: ptr MmVersionCfmObj): cint
      {.exportc, cdecl.} =
    sendEmpty(blHw, MM_VERSION_REQ, TASK_MM, 1, MM_VERSION_CFM, cfm)

  proc bl_send_me_config_req*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
    let req = blMsgZalloc(ME_CONFIG_REQ, TASK_ME, DRV_TASK_ID, SizeMeConfigReq)
    if req == nil: return -Enomem
    let hw = cast[pointer](blHw)
    let htCap = ptrAt(hw, BlHwHtCapOff)
    let modp = loadPtr(hw, BlHwModParamsOff)
    bl_os_printf("[ME] HT supp %d, VHT supp %d\r\n", 1, 0)
    storeU8(req, MeConfigHtSuppOff, 1)
    storeU8(req, MeConfigVhtSuppOff, 0)
    storeU16(req, MeConfigHtCapOff + MacHtCapInfoOff, loadU16(htCap, HtCapCapOff))
    storeU8(req, MeConfigHtCapOff + MacHtAmpduOff, 3)
    copyMem(ptrAt(req, MeConfigHtCapOff + MacHtMcsRateOff), ptrAt(htCap, HtCapMcsOff), 16)
    storeU16(req, MeConfigHtCapOff + MacHtExtCapOff, 0)
    storeU32(req, MeConfigHtCapOff + MacHtBeamformOff, 0)
    storeU8(req, MeConfigHtCapOff + MacHtAselOff, 0)
    if modp != nil:
      storeU8(req, MeConfigPsOnOff, loadU8(modp, BlModParamsPsOnOff))
      storeU16(req, MeConfigTxLftOff, loadI32(modp, BlModParamsTxLftOff).uint16)
    blSendMsg(blHw, req, 1, ME_CONFIG_CFM, nil)

  proc bl_send_me_chan_config_req*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
    let req = blMsgZalloc(ME_CHAN_CONFIG_REQ, TASK_ME, DRV_TASK_ID, SizeMeChanConfigReq)
    if req == nil: return -Enomem
    var count = channelNumDefault
    if count > SCAN_CHANNEL_2G4: count = SCAN_CHANNEL_2G4
    for i in 0 ..< count:
      fillScanChan(req, MeChanChan2G4Off + i.uint * ScanChanSize, i, 0, 20)
      storeU8(req, MeChanCountOff, (i + 1).uint8)
    blSendMsg(blHw, req, 1, ME_CHAN_CONFIG_CFM, nil)

  proc bl_send_me_rate_config_req*(blHw: ptr BlHw; staIdx: uint8;
                                   fixedRateCfg: uint16): cint {.exportc, cdecl.} =
    let req = blMsgZalloc(ME_RC_SET_RATE_REQ, TASK_ME, DRV_TASK_ID, SizeMeRcSetRateReq)
    if req == nil: return -Enomem
    storeU8(req, MeRcStaIdxOff, staIdx)
    storeU16(req, MeRcFixedRateOff, fixedRateCfg)
    storeU16(req, MeRcPowerTableReqOff, 1)
    blSendMsg(blHw, req, 0, 0, nil)

  proc bl_send_start*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
    let req = blMsgZalloc(MM_START_REQ, TASK_MM, DRV_TASK_ID, SizeMmStartReq)
    if req == nil: return -Enomem
    let modp = loadPtr(cast[pointer](blHw), BlHwModParamsOff)
    storeU32(req, MmStartPhyCfgOff, 1)
    if modp != nil:
      storeU32(req, MmStartUapsdTimeoutOff, loadI32(modp, BlModParamsUapsdTimeoutOff).uint32)
      storeU16(req, MmStartLpClkAccuracyOff, loadI32(modp, BlModParamsLpClkPpmOff).uint16)
    blSendMsg(blHw, req, 1, MM_START_CFM, nil)

  proc bl_send_add_if*(blHw: ptr BlHw; mac: ptr uint8; iftype: cint; p2p: bool;
                       cfm: ptr MmAddIfCfmObj): cint {.exportc, cdecl.} =
    if iftype == NL80211_IFTYPE_AP_VLAN:
      return -1
    let req = blMsgZalloc(MM_ADD_IF_REQ, TASK_MM, DRV_TASK_ID, SizeMmAddIfReq)
    if req == nil: return -Enomem
    copyMem(ptrAt(req, MmAddIfAddrOff), mac, 6)
    case iftype
    of NL80211_IFTYPE_STATION:
      storeU8(req, MmAddIfTypeOff, MM_STA)
    of NL80211_IFTYPE_ADHOC:
      storeU8(req, MmAddIfTypeOff, MM_IBSS)
    of NL80211_IFTYPE_AP:
      storeU8(req, MmAddIfTypeOff, MM_AP)
    of NL80211_IFTYPE_MESH_POINT:
      storeU8(req, MmAddIfTypeOff, MM_MESH_POINT)
    else:
      storeU8(req, MmAddIfTypeOff, MM_STA)
    if p2p:
      storeU8(req, MmAddIfP2pOff, 1)
    blSendMsg(blHw, req, 1, MM_ADD_IF_CFM, cfm)

  proc bl_send_remove_if*(blHw: ptr BlHw; instNbr: uint8): cint {.exportc, cdecl.} =
    let req = blMsgZalloc(MM_REMOVE_IF_REQ, TASK_MM, DRV_TASK_ID, SizeMmRemoveIfReq)
    if req == nil: return -Enomem
    storeU8(req, MmRemoveIfInstOff, instNbr)
    blSendMsg(blHw, req, 1, MM_REMOVE_IF_CFM, nil)

  proc bl_send_scanu_req*(blHw: ptr BlHw; scanuPara: ptr ScanuPara): cint
      {.exportc, cdecl.} =
    let req = blMsgZalloc(SCANU_START_REQ, TASK_SCANU, DRV_TASK_ID, SizeScanuStartReq)
    if req == nil: return -Enomem
    let sp = cast[pointer](scanuPara)
    storeU8(req, ScanuVifIdxOff, 0)
    let fixedCount = loadU16(sp, ScanParaChannelNumOff)
    let chanCnt = if fixedCount == 0'u16: channelNumDefault.uint8 else: fixedCount.uint8
    storeU8(req, ScanuChanCntOff, chanCnt)
    storeU8(req, ScanuSsidCntOff, 1)
    var chanFlags = 0'u8
    let ssid = loadPtr(sp, ScanParaSsidOff)
    if ssid != nil and loadU8(ssid, MacSsidLengthOff) != 0'u8:
      let ssidLen = loadU8(ssid, MacSsidLengthOff)
      storeU8(req, ScanuSsidOff + MacSsidLengthOff, ssidLen)
      copyMem(ptrAt(req, ScanuSsidOff + MacSsidArrayOff), ptrAt(ssid, MacSsidArrayOff), ssidLen.uint)
    else:
      storeU8(req, ScanuSsidOff + MacSsidLengthOff, 0)
      if loadU8(sp, ScanParaModeOff) == SCAN_PASSIVE:
        chanFlags = chanFlags or SCAN_PASSIVE_BIT
    let bssid = loadPtr(sp, ScanParaBssidOff)
    if bssid != nil:
      copyMem(ptrAt(req, ScanuBssidOff), bssid, 6)
    let mac = loadPtr(sp, ScanParaMacOff)
    if mac != nil:
      copyMem(ptrAt(req, ScanuMacOff), mac, 6)
    storeU8(req, ScanuNoCckOff, 1)
    storeU16(req, ScanuAddIeLenOff, 0)
    storePtr(req, ScanuAddIesOff, nil)
    let channels = loadPtr(sp, ScanParaChannelsOff)
    for i in 0 ..< chanCnt.int:
      let index =
        if fixedCount == 0'u16:
          i
        elif channels != nil:
          cast[ptr UncheckedArray[uint16]](channels)[i].int - 1
        else:
          i
      fillScanChan(req, ScanuChanOff + i.uint * ScanChanSize, index, chanFlags, 0)
    storeU32(req, ScanuDurationOff, loadU32(sp, ScanParaDurationOff))
    blSendMsg(blHw, req, 0, 0, nil)

  proc bl_send_scanu_raw_send*(blHw: ptr BlHw; pkt: ptr uint8; len: cint): cint
      {.exportc, cdecl.} =
    var cfm: array[1, uint8]
    let req = blMsgZalloc(SCANU_RAW_SEND_REQ, TASK_SCANU, DRV_TASK_ID, SizeScanuRawSendReq)
    if req == nil: return -Enomem
    storePtr(req, ScanuRawPktOff, pkt)
    storeU32(req, ScanuRawLenOff, len.uint32)
    blSendMsg(blHw, req, 1, SCANU_RAW_SEND_CFM, addr cfm[0])

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

  proc bl_send_sm_connect_req*(blHw: ptr BlHw; sme: ptr Cfg80211ConnectParams;
                               cfm: ptr SmConnectCfmObj): cint {.exportc, cdecl.} =
    let req = blMsgZalloc(SM_CONNECT_REQ, TASK_SM, DRV_TASK_ID, SizeSmConnectReq)
    if req == nil: return -Enomem
    let smeRaw = cast[pointer](sme)
    let crypto = ptrAt(smeRaw, ConnCryptoOff)
    var flags = loadU32(smeRaw, ConnFlagsOff)
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
    storeU16(req, SmCtrlPortEthertypeOff, 0x8e88'u16)

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

  proc bl_send_sm_disconnect_req*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
    bl808_wifi_vendor_poll(64)
    let req = blMsgZalloc(SM_DISCONNECT_REQ, TASK_SM, DRV_TASK_ID, SizeSmDisconnectReq)
    if req == nil: return -Enomem
    storeU8(req, 0, staVifIdx(blHw))
    blSendMsg(blHw, req, 1, SM_DISCONNECT_CFM, nil)

  proc bl_send_sm_connect_abort_req*(blHw: ptr BlHw; cfm: ptr SmAbortCfmObj): cint
      {.exportc, cdecl.} =
    let req = blMsgZalloc(SM_CONNECT_ABORT_REQ, TASK_SM, DRV_TASK_ID, SizeSmConnectAbortReq)
    if req == nil: return -Enomem
    storeU8(req, 0, staVifIdx(blHw))
    blSendMsg(blHw, req, 1, SM_CONNECT_ABORT_CFM, cfm)

  proc bl_send_mm_powersaving_req*(blHw: ptr BlHw; mode: cint): cint
      {.exportc, cdecl.} =
    let req = blMsgZalloc(MM_SET_PS_MODE_REQ, TASK_MM, DRV_TASK_ID, SizeMmSetPsModeReq)
    if req == nil: return -Enomem
    storeU8(req, 0, mode.uint8)
    blSendMsg(blHw, req, 1, MM_SET_PS_MODE_CFM, nil)

  proc bl_send_mm_denoise_req*(blHw: ptr BlHw; mode: cint): cint {.exportc, cdecl.} =
    let req = blMsgZalloc(MM_DENOISE_REQ, TASK_MM, DRV_TASK_ID, SizeMmSetDenoiseReq)
    if req == nil: return -Enomem
    storeU8(req, 0, mode.uint8)
    blSendMsg(blHw, req, 1, MM_SET_PS_MODE_CFM, nil)

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
    storeU16(req, ApmCtrlPortEthertypeOff, 0x8e88'u16)
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

  proc bl_send_apm_stop_req*(blHw: ptr BlHw; vifIdx: uint8): cint {.exportc, cdecl.} =
    let req = blMsgZalloc(APM_STOP_REQ, TASK_APM, DRV_TASK_ID, SizeApmStopReq)
    if req == nil: return -Enomem
    storeU8(req, 0, vifIdx)
    blSendMsg(blHw, req, 1, APM_STOP_CFM, nil)

  proc bl_send_apm_sta_del_req*(blHw: ptr BlHw; cfm: ptr ApmStaDelCfmObj;
                                staIdx, vifIdx: uint8): cint {.exportc, cdecl.} =
    let req = blMsgZalloc(APM_STA_DEL_REQ, TASK_APM, DRV_TASK_ID, SizeApmStaDelReq)
    if req == nil: return -Enomem
    storeU8(req, 0, vifIdx)
    storeU8(req, 1, staIdx)
    blSendMsg(blHw, req, 1, APM_STA_DEL_CFM, cfm)

  proc bl_send_apm_conf_max_sta_req*(blHw: ptr BlHw; maxStaSupported: uint8): cint
      {.exportc, cdecl.} =
    let req = blMsgZalloc(APM_CONF_MAX_STA_REQ, TASK_APM, DRV_TASK_ID,
                          SizeApmConfMaxStaReq)
    if req == nil: return -Enomem
    storeU8(req, 0, maxStaSupported)
    blSendMsg(blHw, req, 1, APM_CONF_MAX_STA_CFM, nil)

  proc bl_send_cfg_task_req*(blHw: ptr BlHw; ops, task, element, typ: uint32;
                             arg1, arg2: pointer): cint {.exportc, cdecl.} =
    let req = blMsgZalloc(CFG_START_REQ, TASK_CFG, DRV_TASK_ID, SizeCfgStartReq)
    if req == nil: return -Enomem
    storeU32(req, CfgOpsOff, ops)
    case ops
    of 1'u32:
      storeU32(req, CfgSetTaskOff, task)
      storeU32(req, CfgSetElementOff, element)
      storeU32(req, CfgSetTypeOff, typ)
      storeU32(req, CfgSetLengthOff,
               utils_tlv_bl_pack_auto(cast[ptr uint32](ptrAt(req, CfgSetBufOff)), 8, typ.uint16, arg1))
    of 4'u32:
      storeU32(req, CfgSetTaskOff, task)
      storeU32(req, CfgSetElementOff, element)
      storeU32(req, CfgSetLengthOff, 0)
    else:
      discard
    blSendMsg(blHw, req, 1, CFG_START_CFM, nil)

  proc bl_send_channel_set_req*(blHw: ptr BlHw; channel: cint): cint {.exportc, cdecl.} =
    var cfm: array[1, uint8]
    let req = blMsgZalloc(MM_SET_CHANNEL_REQ, TASK_MM, DRV_TASK_ID, SizeMmSetChannelReq)
    if req == nil: return -Enomem
    let freq = phy_channel_to_freq(PHY_BAND_2G4, channel)
    storeU8(req, MmSetChannelBandOff, PHY_BAND_2G4)
    storeU8(req, MmSetChannelTypeOff, PHY_CHNL_BW_20)
    storeU16(req, MmSetChannelPrim20Off, freq)
    storeU16(req, MmSetChannelCenter1Off, freq)
    storeU16(req, MmSetChannelCenter2Off, freq)
    storeU8(req, MmSetChannelIndexOff, 0)
    storeU8(req, MmSetChannelTxPowerOff, 15)
    blSendMsg(blHw, req, 1, MM_SET_CHANNEL_CFM, addr cfm[0])
