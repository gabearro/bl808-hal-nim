## Nim replacement for the BL808 WiFi host-driver top-level glue in bl_main.c.
##
## This module owns the global `wifi_hw` object and exports the bl_main_*
## entry points while lower message/TX/RX units are still being ported.

when defined(bl808m0) and defined(bl808WifiVendor) and defined(bl808WifiNimFw):
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/include".}

  const
    IpcIrqE2aAll = 0x0000_07ff'u32
    Eio = 5.cint
    Einprogress = 115.cint
    Ealready = 114.cint

    CoOk = 0'u8
    CoBusy = 8'u8
    CoOpInProgress = 9'u8

    Nl80211IftypeStation = 2.cint
    Nl80211IftypeAp = 3.cint
    Nl80211AuthtypeAutomatic = 8'u32
    WlanCipherSuiteCcmp = 0x000f_ac04'u32
    EthPPae = 0x888e'u16

    BlVifSta = 0'u
    BlVifAp = 1'u
    NxVirtDevMax = 2'u
    NxRemoteStaStoreMax = 3'u

    BlHwIpcEnvOff = 48'u
    BlHwVifsOff = 52'u
    BlHwVifTableOff = 60'u
    BlHwStaTableOff = 100'u
    BlHwModParamsOff = 220'u

    BlVifSize = 20'u
    BlVifDevOff = 8'u
    BlVifUpOff = 12'u
    BlVifVifIdxOff = 13'u
    BlVifLinksNumOff = 14'u
    BlVifFixedStaIdxOff = 15'u
    BlVifFcChanOff = 16'u
    BlVifStaPsOff = 17'u

    BlStaSize = 40'u
    BlStaAddrOff = 16'u
    BlStaIsUsedOff = 22'u
    BlStaStaIdxOff = 23'u
    BlStaVifIdxOff = 24'u
    BlStaQosOff = 27'u
    BlStaRssiOff = 28'u
    BlStaRateOff = 29'u
    BlStaTsfloOff = 32'u
    BlStaTsfhiOff = 36'u

    NetifHwaddrOff = 58'u

    SizeCfg80211Connect = 240
    ConnChannelOff = 0'u
    ConnBssidOff = 56'u
    ConnSsidOff = 64'u
    ConnSsidLenOff = 68'u
    ConnAuthTypeOff = 72'u
    ConnCryptoOff = 88'u
    ConnKeyOff = 148'u
    ConnPmkOff = 152'u
    ConnKeyLenOff = 156'u
    ConnPmkLenOff = 157'u
    ConnFlagsOff = 160'u
    ChanBandOff = 0'u
    ChanFreqOff = 2'u
    ChanFlagsOff = 8'u
    CryptoCipherGroupOff = 4'u
    CryptoNCiphersOff = 8'u
    CryptoCiphers0Off = 12'u
    CryptoControlPortOff = 44'u
    CryptoControlEthertypeOff = 46'u
    CryptoControlNoEncOff = 48'u

    SizeScanuPara = 28
    ScanChannelsOff = 0'u
    ScanChannelNumOff = 4'u
    ScanBssidOff = 8'u
    ScanSsidOff = 12'u
    ScanMacOff = 16'u
    ScanModeOff = 20'u
    ScanDurationOff = 24'u

    SizeMmAddIfCfm = 2
    AddIfStatusOff = 0'u
    AddIfInstNbrOff = 1'u

    SizeApmStartCfm = 4
    ApmStartStatusOff = 0'u
    ApmStartChIdxOff = 2'u
    ApmStartBcmcIdxOff = 3'u

    SizeApmStaDelCfm = 3
    ApmStaDelStatusOff = 0'u

    SizeSmConnectCfm = 1
    SmConnectStatusOff = 0'u
    SizeSmAbortCfm = 1
    SmAbortStatusOff = 0'u

    SizeMmVersionCfm = 24
    SizeMmMonitorCfm = 40
    SizeMmMonitorChannelCfm = 40
    SizeMmBeaconCfm = 1

    ApmInfoStaIdxOff = 0'u
    ApmInfoIsUsedOff = 1'u
    ApmInfoStaMacOff = 2'u
    ApmInfoTsfhiOff = 8'u
    ApmInfoTsfloOff = 12'u
    ApmInfoRssiOff = 16'u
    ApmInfoRateOff = 20'u

  type
    BlHw {.importc: "struct bl_hw", header: "bl_defs.h".} = object
    BlModParams {.importc: "struct bl_mod_params", header: "bl_mod_params.h".} = object
    Netif {.importc: "struct netif", header: "<lwip/netif.h>".} = object
    MacAddr {.importc: "struct mac_addr", header: "lmac_msg.h".} = object
    MacSsid {.importc: "struct mac_ssid", header: "lmac_msg.h".} = object
    KeTxFc {.importc: "struct ke_tx_fc", header: "lmac_msg.h".} = object
    Cfg80211ConnectParams {.importc: "struct cfg80211_connect_params",
                            header: "cfg80211.h".} = object
    MmAddIfCfm {.importc: "struct mm_add_if_cfm", header: "lmac_msg.h".} = object
    MmVersionCfm {.importc: "struct mm_version_cfm", header: "lmac_msg.h".} = object
    MmMonitorCfm {.importc: "struct mm_monitor_cfm", header: "lmac_msg.h".} = object
    MmMonitorChannelCfm {.importc: "struct mm_monitor_channel_cfm",
                          header: "lmac_msg.h".} = object
    MmBeaconCfm {.importc: "struct mm_set_beacon_int_cfm",
                  header: "lmac_msg.h".} = object
    SmConnectCfm {.importc: "struct sm_connect_cfm", header: "lmac_msg.h".} = object
    SmAbortCfm {.importc: "struct sm_connect_abort_cfm", header: "lmac_msg.h".} = object
    ApmStartCfm {.importc: "struct apm_start_cfm", header: "lmac_msg.h".} = object
    ApmStaDelCfm {.importc: "struct apm_sta_del_cfm", header: "lmac_msg.h".} = object
    ScanuPara {.importc: "struct bl_send_scanu_para", header: "bl_msg_tx.h".} = object

  {.emit: "struct bl_hw wifi_hw;".}
  var wifi_hw {.importc, header: "bl_defs.h".}: BlHw
  var bl_mod_params {.importc, header: "bl_mod_params.h".}: BlModParams

  ## Direct-UART trace helpers — `cfg_trace(char*)` and `cfg_trace_rc(char*,int)`
  ## are kept available as extern C symbols so any wifi_* module can drop in
  ## prints without going through the wifi-blob log routing (which is
  ## char-write-blind and gets clobbered by PHY printf chatter). Poll
  ## FIFO-free status before each byte so traces survive concurrent emits.
  {.emit: """
static void cfg_putc(char c) {
  volatile unsigned int *fifo = (volatile unsigned int *)0x2000a088;
  volatile unsigned int *cfg  = (volatile unsigned int *)0x2000a084;
  unsigned int t = 200000u;
  while (((*cfg) & 0x3fu) == 0u && t--) {}
  *fifo = (unsigned int)(unsigned char)c;
}
void cfg_trace(char *s) {
  while (*s) cfg_putc(*s++);
}
void cfg_trace_rc(char *s, int v) {
  while (*s) cfg_putc(*s++);
  unsigned int u = (unsigned int)v;
  for (int sh = 28; sh >= 0; sh -= 4) {
    unsigned int n = (u >> sh) & 0xf;
    cfg_putc((char)(n < 10 ? ('0' + n) : ('a' + n - 10)));
  }
  cfg_putc('\r'); cfg_putc('\n');
}
""".}

  proc c_memset(s: pointer; c: cint; n: csize_t): pointer
    {.importc: "memset", header: "<string.h>", cdecl.}
  proc c_memcpy(dest, src: pointer; n: csize_t): pointer
    {.importc: "memcpy", header: "<string.h>", cdecl.}

  proc bl_send_reset(blHw: ptr BlHw): cint {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_version_req(blHw: ptr BlHw; cfm: ptr MmVersionCfm): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_me_config_req(blHw: ptr BlHw): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_me_chan_config_req(blHw: ptr BlHw): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_me_rate_config_req(blHw: ptr BlHw; staIdx: uint8; fixedRateCfg: uint16): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_start(blHw: ptr BlHw): cint {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_add_if(blHw: ptr BlHw; mac: ptr uint8; iftype: cint; p2p: bool;
                      cfm: ptr MmAddIfCfm): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_remove_if(blHw: ptr BlHw; instNbr: uint8): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_scanu_req(blHw: ptr BlHw; scanuPara: ptr ScanuPara): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_scanu_raw_send(blHw: ptr BlHw; pkt: ptr uint8; len: cint): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_sm_connect_req(blHw: ptr BlHw; sme: ptr Cfg80211ConnectParams;
                              cfm: ptr SmConnectCfm): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_sm_connect_abort_req(blHw: ptr BlHw; cfm: ptr SmAbortCfm): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_sm_disconnect_req(blHw: ptr BlHw): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_mm_powersaving_req(blHw: ptr BlHw; mode: cint): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_mm_denoise_req(blHw: ptr BlHw; mode: cint): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_channel_set_req(blHw: ptr BlHw; channel: cint): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_monitor_enable(blHw: ptr BlHw; cfm: ptr MmMonitorCfm): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_monitor_disable(blHw: ptr BlHw; cfm: ptr MmMonitorCfm): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_monitor_channel_set(blHw: ptr BlHw; cfm: ptr MmMonitorChannelCfm;
                                   channel, use40Mhz: cint): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_beacon_interval_set(blHw: ptr BlHw; cfm: ptr MmBeaconCfm;
                                   beaconInt: uint16): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_apm_start_req(blHw: ptr BlHw; cfm: ptr ApmStartCfm; ssid, password: cstring;
                             channel: cint; vifIndex, hiddenSsid: uint8;
                             bcnInt: uint16): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_apm_stop_req(blHw: ptr BlHw; vifIdx: uint8): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_apm_sta_del_req(blHw: ptr BlHw; cfm: ptr ApmStaDelCfm;
                               staIdx, vifIdx: uint8): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_apm_conf_max_sta_req(blHw: ptr BlHw; maxStaSupported: uint8): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_send_cfg_task_req(blHw: ptr BlHw; ops, task, element, typ: uint32;
                            arg1, arg2: pointer): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_msg_update_channel_cfg(code: cstring) {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_msg_get_channel_nums(): cint {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_get_fixed_channels_is_valid(channels: ptr uint16; channelNum: uint16): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}

  proc bl_platform_on(blHw: ptr BlHw): cint {.importc, cdecl, header: "bl_platform.h".}
  proc bl_handle_dynparams(blHw: ptr BlHw): cint {.importc, cdecl, header: "bl_mod_params.h".}
  proc bl_irqs_init(blHw: ptr BlHw): cint {.importc, cdecl, header: "bl_irqs.h".}
  proc bl_irq_bottomhalf(blHw: ptr BlHw) {.importc, cdecl, header: "bl_irqs.h".}
  proc bl_tx_try_flush(param: cint; txFcField: ptr KeTxFc) {.importc, cdecl, header: "bl_tx.h".}
  proc ipc_host_enable_irq(env: pointer; value: uint32)
    {.importc, cdecl, header: "ipc_host.h".}
  proc ipc_host_txdesc_left(env: pointer; queueIdx, userPos: cint): cint
    {.importc, cdecl, header: "ipc_host.h".}
  proc bl_wifi_enable_irq(): cint {.importc, cdecl.}
  proc bl_os_msleep(ms: uint32) {.importc, cdecl, header: "bl_os_private.h".}

  template ptrAt(base: pointer; off: uint): pointer =
    cast[pointer](cast[uint](base) + off)

  proc hwPtr(): ptr BlHw {.inline.} =
    addr wifi_hw

  proc hwRaw(): pointer {.inline.} =
    cast[pointer](addr wifi_hw)

  proc bl_cfg80211_connect*(blHw: ptr BlHw; sme: ptr Cfg80211ConnectParams): cint
      {.exportc, cdecl.}

  proc zero(p: pointer; n: Natural) {.inline.} =
    discard c_memset(p, 0, n.csize_t)

  proc loadPtr(base: pointer; off: uint): pointer {.inline.} =
    cast[ptr pointer](ptrAt(base, off))[]

  proc storePtr(base: pointer; off: uint; value: pointer) {.inline.} =
    cast[ptr pointer](ptrAt(base, off))[] = value

  proc loadU8(base: pointer; off: uint): uint8 {.inline.} =
    cast[ptr uint8](ptrAt(base, off))[]

  proc storeU8(base: pointer; off: uint; value: uint8) {.inline.} =
    cast[ptr uint8](ptrAt(base, off))[] = value

  proc loadI8(base: pointer; off: uint): int8 {.inline.} =
    cast[ptr int8](ptrAt(base, off))[]

  proc loadU32(base: pointer; off: uint): uint32 {.inline.} =
    cast[ptr uint32](ptrAt(base, off))[]

  proc storeU16(base: pointer; off: uint; value: uint16) {.inline.} =
    cast[ptr uint16](ptrAt(base, off))[] = value

  proc storeU32(base: pointer; off: uint; value: uint32) {.inline.} =
    cast[ptr uint32](ptrAt(base, off))[] = value

  proc storeI32(base: pointer; off: uint; value: int32) {.inline.} =
    cast[ptr int32](ptrAt(base, off))[] = value

  proc vifAt(index: uint): pointer {.inline.} =
    ptrAt(hwRaw(), BlHwVifTableOff + index * BlVifSize)

  proc staAt(index: uint): pointer {.inline.} =
    ptrAt(hwRaw(), BlHwStaTableOff + index * BlStaSize)

  proc netifHwaddr(netif: ptr Netif): ptr uint8 {.inline.} =
    cast[ptr uint8](ptrAt(cast[pointer](netif), NetifHwaddrOff))

  proc initListHead(base: pointer; off: uint) =
    let list = ptrAt(base, off)
    storePtr(list, 0'u, list)
    storePtr(list, sizeof(pointer).uint, list)

  proc bl_open*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
    discard blHw
    0

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

  proc bl_main_denoise*(mode: cint): cint {.exportc, cdecl.} =
    bl_send_mm_denoise_req(hwPtr(), mode)

  proc bl_main_monitor*(): cint {.exportc, cdecl.} =
    var cfm: array[SizeMmMonitorCfm, uint8]
    zero(addr cfm[0], cfm.len)
    discard bl_send_monitor_enable(hwPtr(), cast[ptr MmMonitorCfm](addr cfm[0]))
    0

  proc bl_main_monitor_disable*(): cint {.exportc, cdecl.} =
    var cfm: array[SizeMmMonitorCfm, uint8]
    zero(addr cfm[0], cfm.len)
    discard bl_send_monitor_disable(hwPtr(), cast[ptr MmMonitorCfm](addr cfm[0]))
    0

  proc bl_main_phy_up*(): cint {.exportc, cdecl.} =
    if bl_send_start(hwPtr()) != 0: -1 else: 0

  proc bl_main_channel_set*(channel: cint): cint {.exportc, cdecl.} =
    discard bl_send_channel_set_req(hwPtr(), channel)
    0

  proc bl_main_monitor_channel_set*(channel, use40Mhz: cint): cint {.exportc, cdecl.} =
    var cfm: array[SizeMmMonitorChannelCfm, uint8]
    zero(addr cfm[0], cfm.len)
    discard bl_send_monitor_channel_set(hwPtr(), cast[ptr MmMonitorChannelCfm](addr cfm[0]),
                                        channel, use40Mhz)
    0

  proc bl_main_beacon_interval_set*(beaconInt: uint16): cint {.exportc, cdecl.} =
    var cfm: array[SizeMmBeaconCfm, uint8]
    zero(addr cfm[0], cfm.len)
    discard bl_send_beacon_interval_set(hwPtr(), cast[ptr MmBeaconCfm](addr cfm[0]), beaconInt)
    0

  proc bl_main_if_remove*(vifIndex: uint8): cint {.exportc, cdecl.} =
    if vifIndex.uint >= NxVirtDevMax:
      return -1
    let vif = vifAt(vifIndex.uint)
    discard bl_send_remove_if(hwPtr(), loadU8(vif, BlVifVifIdxOff))
    zero(vif, BlVifSize.int)
    0

  proc bl_main_raw_send*(pkt: ptr uint8; len: cint): cint {.exportc, cdecl.} =
    bl_send_scanu_raw_send(hwPtr(), pkt, len)

  proc bl_main_rate_config*(staIdx: uint8; fixedRateCfg: uint16): cint {.exportc, cdecl.} =
    bl_send_me_rate_config_req(hwPtr(), staIdx, fixedRateCfg)

  proc bl_main_set_country_code*(countryCode: cstring): cint {.exportc, cdecl.} =
    bl_msg_update_channel_cfg(countryCode)
    discard bl_send_me_chan_config_req(hwPtr())
    0

  proc bl_main_get_channel_nums*(): cint {.exportc, cdecl.} =
    bl_msg_get_channel_nums()

  proc bl_main_if_add*(isSta: cint; netif: ptr Netif; vifIndex: ptr uint8): cint
      {.exportc, cdecl.} =
    if netif == nil or vifIndex == nil:
      return -1
    var cfm: array[SizeMmAddIfCfm, uint8]
    zero(addr cfm[0], cfm.len)
    result = bl_send_add_if(hwPtr(), netifHwaddr(netif),
                            if isSta != 0: Nl80211IftypeStation else: Nl80211IftypeAp,
                            false, cast[ptr MmAddIfCfm](addr cfm[0]))
    if result != 0:
      return result
    if loadU8(addr cfm[0], AddIfStatusOff) != CoOk:
      return -Eio

    let vifId = if isSta != 0: BlVifSta else: BlVifAp
    let vif = vifAt(vifId)
    storeU8(vif, BlVifVifIdxOff, loadU8(addr cfm[0], AddIfInstNbrOff))
    storePtr(vif, BlVifDevOff, cast[pointer](netif))
    storeU8(vif, BlVifUpOff, 1'u8)
    storeU8(vif, BlVifLinksNumOff, 0'u8)
    vifIndex[] = vifId.uint8

  proc bl_main_apm_start*(ssid, password: cstring; channel: cint; hiddenSsid: uint8;
                          bcnInt: uint16): cint {.exportc, cdecl.} =
    var cfm: array[SizeApmStartCfm, uint8]
    zero(addr cfm[0], cfm.len)
    let apVif = vifAt(BlVifAp)
    result = bl_send_apm_start_req(hwPtr(), cast[ptr ApmStartCfm](addr cfm[0]), ssid, password,
                                   channel, loadU8(apVif, BlVifVifIdxOff), hiddenSsid, bcnInt)
    let bcmcIdx = loadU8(addr cfm[0], ApmStartBcmcIdxOff)
    if bcmcIdx.uint < NxRemoteStaStoreMax:
      storeU8(apVif, BlVifFixedStaIdxOff, bcmcIdx)
      let sta = staAt(bcmcIdx.uint)
      storeU8(sta, BlStaVifIdxOff, BlVifAp.uint8)
      storeU8(sta, BlStaStaIdxOff, bcmcIdx)
      storeU8(sta, BlStaQosOff, 1'u8)

  proc bl_main_apm_stop*(): cint {.exportc, cdecl.} =
    bl_send_apm_stop_req(hwPtr(), loadU8(vifAt(BlVifAp), BlVifVifIdxOff))

  proc bl_main_apm_sta_cnt_get*(staCnt: ptr uint8): cint {.exportc, cdecl.} =
    if staCnt == nil:
      return -1
    staCnt[] = NxRemoteStaStoreMax.uint8
    0

  proc bl_main_apm_sta_info_get*(apmStaInfo: pointer; idx: uint8): cint {.exportc, cdecl.} =
    if apmStaInfo == nil or idx.uint >= NxRemoteStaStoreMax:
      return -1
    let sta = staAt(idx.uint)
    if loadU8(sta, BlStaIsUsedOff) == 0'u8:
      return 0
    storeU8(apmStaInfo, ApmInfoStaIdxOff, loadU8(sta, BlStaStaIdxOff))
    storeU8(apmStaInfo, ApmInfoIsUsedOff, loadU8(sta, BlStaIsUsedOff))
    discard c_memcpy(ptrAt(apmStaInfo, ApmInfoStaMacOff), ptrAt(sta, BlStaAddrOff), 6)
    storeU32(apmStaInfo, ApmInfoTsfhiOff, loadU32(sta, BlStaTsfhiOff))
    storeU32(apmStaInfo, ApmInfoTsfloOff, loadU32(sta, BlStaTsfloOff))
    storeI32(apmStaInfo, ApmInfoRssiOff, loadI8(sta, BlStaRssiOff).int32)
    storeU8(apmStaInfo, ApmInfoRateOff, loadU8(sta, BlStaRateOff))
    0

  proc bl_main_apm_sta_delete*(staIdx: uint8): cint {.exportc, cdecl.} =
    if staIdx.uint >= NxRemoteStaStoreMax:
      return -1
    let sta = staAt(staIdx.uint)
    let vifIdx = loadU8(sta, BlStaVifIdxOff)
    if vifIdx.uint >= NxVirtDevMax:
      return -1
    var cfm: array[SizeApmStaDelCfm, uint8]
    zero(addr cfm[0], cfm.len)
    discard bl_send_apm_sta_del_req(hwPtr(), cast[ptr ApmStaDelCfm](addr cfm[0]), staIdx,
                                    loadU8(vifAt(vifIdx.uint), BlVifVifIdxOff))
    if loadU8(addr cfm[0], ApmStaDelStatusOff) != 0'u8:
      return -1
    zero(sta, BlStaSize.int)
    0

  proc bl_main_apm_remove_all_sta*(): cint {.exportc, cdecl.} =
    for i in 0'u ..< NxRemoteStaStoreMax:
      if loadU8(staAt(i), BlStaIsUsedOff) == 1'u8:
        discard bl_main_apm_sta_delete(i.uint8)
    0

  proc bl_main_conf_max_sta*(maxStaSupported: uint8): cint {.exportc, cdecl.} =
    bl_send_apm_conf_max_sta_req(hwPtr(), maxStaSupported)

  proc bl_main_cfg_task_req*(ops, task, element, typ: uint32; arg1, arg2: pointer): cint
      {.exportc, cdecl.} =
    bl_send_cfg_task_req(hwPtr(), ops, task, element, typ, arg1, arg2)

  proc bl_main_scan*(netif: ptr Netif; fixedChannels: ptr uint16; channelNum: uint16;
                     bssid: ptr MacAddr; ssid: ptr MacSsid; scanMode: uint8;
                     durationScan: uint32): cint {.exportc, cdecl.} =
    if netif == nil:
      return -1
    var scanu: array[SizeScanuPara, uint8]
    zero(addr scanu[0], scanu.len)
    storePtr(addr scanu[0], ScanChannelsOff, cast[pointer](fixedChannels))
    storeU16(addr scanu[0], ScanChannelNumOff, channelNum)
    storePtr(addr scanu[0], ScanBssidOff, cast[pointer](bssid))
    storePtr(addr scanu[0], ScanSsidOff, cast[pointer](ssid))
    storePtr(addr scanu[0], ScanMacOff, cast[pointer](netifHwaddr(netif)))
    storeU8(addr scanu[0], ScanModeOff, scanMode)
    storeU32(addr scanu[0], ScanDurationOff, durationScan)

    if channelNum == 0'u16:
      storePtr(addr scanu[0], ScanChannelsOff, nil)
      discard bl_send_scanu_req(hwPtr(), cast[ptr ScanuPara](addr scanu[0]))
    elif bl_get_fixed_channels_is_valid(fixedChannels, channelNum) != 0:
      discard bl_send_scanu_req(hwPtr(), cast[ptr ScanuPara](addr scanu[0]))
    0

  proc bl_main_connect_abort*(status: ptr uint8): cint {.exportc, cdecl.} =
    if status == nil:
      return -1
    var cfm: array[SizeSmAbortCfm, uint8]
    zero(addr cfm[0], cfm.len)
    discard bl_send_sm_connect_abort_req(hwPtr(), cast[ptr SmAbortCfm](addr cfm[0]))
    status[] = loadU8(addr cfm[0], SmAbortStatusOff)
    0

  proc cfg80211_init(blHw: ptr BlHw): cint =
    if blHw == nil:
      return -1
    let raw = cast[pointer](blHw)
    initListHead(raw, BlHwVifsOff)
    storePtr(raw, BlHwModParamsOff, cast[pointer](addr bl_mod_params))

    result = bl_platform_on(blHw)
    if result != 0:
      return result
    ipc_host_enable_irq(loadPtr(raw, BlHwIpcEnvOff), IpcIrqE2aAll)
    discard bl_wifi_enable_irq()

    result = bl_send_reset(blHw)
    if result != 0:
      return result
    bl_os_msleep(5'u32)

    var versionCfm: array[SizeMmVersionCfm, uint8]
    zero(addr versionCfm[0], versionCfm.len)
    result = bl_send_version_req(blHw, cast[ptr MmVersionCfm](addr versionCfm[0]))
    if result != 0:
      return result
    result = bl_handle_dynparams(blHw)
    if result != 0:
      return result
    discard bl_send_me_config_req(blHw)
    discard bl_send_me_chan_config_req(blHw)

  proc bl_cfg80211_connect*(blHw: ptr BlHw; sme: ptr Cfg80211ConnectParams): cint =
    var cfm: array[SizeSmConnectCfm, uint8]
    zero(addr cfm[0], cfm.len)
    result = bl_send_sm_connect_req(blHw, sme, cast[ptr SmConnectCfm](addr cfm[0]))
    if result != 0:
      return result
    case loadU8(addr cfm[0], SmConnectStatusOff)
    of CoOk:
      result = 0
    of CoBusy:
      result = -Einprogress
    of CoOpInProgress:
      result = -Ealready
    else:
      result = -Eio

  proc bl_cfg80211_disconnect*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
    bl_send_sm_disconnect_req(blHw)

  proc bl_main_event_handle*(param: cint; txFcField: ptr KeTxFc) {.exportc, cdecl.} =
    if param == 0:
      bl_irq_bottomhalf(hwPtr())
    bl_tx_try_flush(param, txFcField)

  proc bl_main_lowlevel_init*() {.exportc, cdecl.} =
    discard bl_irqs_init(hwPtr())

  proc bl_main_tx_still_free*(): cint {.exportc, cdecl.} =
    ipc_host_txdesc_left(loadPtr(hwRaw(), BlHwIpcEnvOff), 0, 0)

  proc bl_main_rtthread_start*(blHwOut: ptr ptr BlHw): cint {.exportc, cdecl.} =
    if blHwOut == nil:
      return -1
    bl_main_lowlevel_init()
    blHwOut[] = hwPtr()
    result = cfg80211_init(hwPtr())
    if result != 0:
      return result
    result = bl_open(blHwOut[])
