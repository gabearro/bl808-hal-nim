## Nim replacement for the remaining bare-metal WiFi support glue.
##
## This replaces src/bl808/wifi_vendor_support.c for NimFW builds. It owns the
## OS-adapter function table, minimal lwIP/pbuf shims, WiFi manager facade, and
## host/firmware polling loop used by the hardware validation tests.

when defined(bl808m0) and defined(bl808WifiVendor) and defined(bl808WifiNimFw):
  import wifi_fw

  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/include".}

  const
    Bl808IrqBase = 16'u32
    Bl808IrqWifi = Bl808IrqBase + 54'u32
    Bl808IrqWifiIpcPublic = Bl808IrqBase + 63'u32

    GlbBase = 0x2000_0000'u32
    UartFifoCfg1 = 0x2000_A084'u32
    UartWdata = 0x2000_A088'u32
    MtimeBase = 0xE000_BFF8'u32
    IntcPend = 0x4000_0010'u32
    IpcEmb2AppAck = 0x2480_0008'u32
    IpcEmb2AppRawStatus = 0x2480_0004'u32
    IpcEmb2AppStatus = 0x2480_0104'u32
    IpcApp2EmbAck = 0x2480_010C'u32
    IpcA2eMsgBit = 1'u32 shl 1
    KeEvtIpcEmbMsg = 0x1000_0000'u32
    MacIrqStatus0 = 0x2491_0000'u32
    MacIrqStatus1 = 0x2491_0004'u32
    MachwIrqRaw = 0x24B0_806C'u32
    MachwIrqUnmask = 0x24B0_8074'u32
    BcnStatus = 0x24B0_0400'u32
    CoexCtrl = 0x2492_0004'u32
    RfStatusCtrl = 0x2490_0084'u32
    MacRfStatus = 0x24B0_0120'u32
    MacRfActiveBit = 0x0008_0000'u32

    VendorScanDiagMax = 8
    VendorVifEntrySize = 1512'u
    VendorVifMacOff = 80'u
    CfgVirtDevMax = 2'u8
    BlVifSta = 0'u
    BlVifAp = 1'u
    BlHwVifTableOff = 60'u
    BlVifSize = 20'u
    BlVifDevOff = 8'u
    BlVifUpOff = 12'u
    BlVifVifIdxOff = 13'u
    BlVifLinksNumOff = 14'u

    NetifSize = 84'u
    NetifStateOff = 36'u
    NetifInputOff = 16'u
    NetifIpOff = 4'u
    NetifNetmaskOff = 8'u
    NetifGwOff = 12'u
    NetifFlagsOff = 65'u
    NetifStatusCbOff = 28'u
    NetifHwaddrOff = 58'u
    NetifNameOff = 66'u
    NetifFlagUp = 0x01'u8
    NetifFlagLinkUp = 0x04'u8

    PbufSize = 16'u
    PbufNextOff = 0'u
    PbufPayloadOff = 4'u
    PbufTotLenOff = 8'u
    PbufLenOff = 10'u
    PbufFlagsOff = 13'u
    PbufRefOff = 14'u
    PbufCustomFreeOff = 16'u
    PbufFlagIsCustom = 0x02'u8

    MgmrStaOff = 8'u
    MgmrApOff = 128'u
    MgmrReadyOff = 3800'u
    MgmrApBcnIntOff = 3806'u
    MgmrApInfoTtlOff = 3812'u
    MgmrScanItemTimeoutOff = 3824'u
    MgmrScanItemsLockOff = 648'u
    MgmrStatInfoOff = 3672'u
    WifiIfaceModeOff = 0'u
    WifiIfaceVifIndexOff = 4'u
    WifiIfaceMacOff = 5'u
    WifiIfaceNetifOff = 32'u
    StatStatusOff = 0'u
    StatReasonOff = 2'u
    StatDiagnoseLockOff = 112'u
    StatDiagnoseGetLockOff = 116'u
    WifiMgmrConfigScanItemTimeout = 15000'i32

    WifiConfCountryOff = 0'u
    CoOk = 0
    MmAddIfCfmSize = 2'u
    MmAddIfStatusOff = 0'u
    MmAddIfInstNbrOff = 1'u
    Nl80211IftypeStation = 2.cint
    ScanActive = 1'u8
    WifiConnectPmfCapable = 1'u32 shl 9
    WifiConnectDefault = 1'u32 shl 31

    WifiEventScanDone = 1'u32
    WifiConnStatusOff = 0'u
    WifiConnReasonOff = 2'u
    WifiDiscStatusOff = 0'u
    WifiDiscReasonOff = 2'u
    WifiBeaconSsidOff = 10'u
    WifiBeaconRssiOff = 43'u
    WifiBeaconChannelOff = 46'u
    WifiBeaconAuthOff = 47'u
    WifiBeaconCipherOff = 48'u
    WifiBeaconSsidLenOff = 56'u
    WifiBeaconGroupCipherOff = 61'u
    WifiBeaconBssidOff = 4'u

    OpVersionOff = 0'u
    OpPrintfOff = 4'u
    OpPutsOff = 8'u
    OpAssertOff = 12'u
    OpInitOff = 16'u
    OpEnterCriticalOff = 20'u
    OpExitCriticalOff = 24'u
    OpMsleepOff = 28'u
    OpSleepOff = 32'u
    OpEventGroupCreateOff = 36'u
    OpEventGroupDeleteOff = 40'u
    OpEventGroupSendOff = 44'u
    OpEventGroupWaitOff = 48'u
    OpEventRegisterOff = 52'u
    OpEventNotifyOff = 56'u
    OpTaskCreateOff = 60'u
    OpTaskDeleteOff = 64'u
    OpTaskGetCurrentOff = 68'u
    OpTaskNotifyCreateOff = 72'u
    OpTaskNotifyOff = 76'u
    OpTaskWaitOff = 80'u
    OpLockGaintOff = 84'u
    OpUnlockGaintOff = 88'u
    OpIrqAttachOff = 92'u
    OpIrqEnableOff = 96'u
    OpIrqDisableOff = 100'u
    OpWorkqueueCreateOff = 104'u
    OpWorkqueueSubmitHpOff = 108'u
    OpWorkqueueSubmitLpOff = 112'u
    OpTimerCreateOff = 116'u
    OpTimerDeleteOff = 120'u
    OpTimerStartOnceOff = 124'u
    OpTimerStartPeriodicOff = 128'u
    OpSemCreateOff = 132'u
    OpSemDeleteOff = 136'u
    OpSemTakeOff = 140'u
    OpSemGiveOff = 144'u
    OpMutexCreateOff = 148'u
    OpMutexDeleteOff = 152'u
    OpMutexLockOff = 156'u
    OpMutexUnlockOff = 160'u
    OpQueueCreateOff = 164'u
    OpQueueDeleteOff = 168'u
    OpQueueSendWaitOff = 172'u
    OpQueueSendOff = 176'u
    OpQueueRecvOff = 180'u
    OpMallocOff = 184'u
    OpFreeOff = 188'u
    OpZallocOff = 192'u
    OpGetTimeMsOff = 196'u
    OpGetTickOff = 200'u
    OpLogWriteOff = 204'u
    OpTaskNotifyIsrOff = 208'u
    OpYieldFromIsrOff = 212'u
    OpMsToTickOff = 216'u
    OpSetTimeoutOff = 220'u
    OpCheckTimeoutOff = 224'u
    BlOsAdapterVersion = 1'u32
    BlOsWaitingForever = 0xffff_ffff'u32

  type
    WifiConf {.importc: "wifi_conf_t", header: "include/wifi_mgmr_ext.h".} = object
    BlOpsFuncs {.importc: "bl_ops_funcs_t", header: "bl_os_adapter.h".} = object
    WifiMgmr {.importc: "wifi_mgmr_t", header: "wifi_mgmr.h".} = object
    Netif {.importc: "struct netif", header: "<lwip/netif.h>".} = object
    Pbuf {.importc: "struct pbuf", header: "<lwip/pbuf.h>".} = object
    PbufCustom {.importc: "struct pbuf_custom", header: "<lwip/pbuf.h>".} = object
    PbufLayer {.importc: "pbuf_layer", header: "<lwip/pbuf.h>".} = enum
      pbufLayerDummy
    PbufType {.importc: "pbuf_type", header: "<lwip/pbuf.h>".} = enum
      pbufTypeDummy
    Ip4Addr {.importc: "ip4_addr_t", header: "<lwip/ip4_addr.h>".} = object
    UtilsList {.importc: "struct utils_list", header: "utils_list.h".} = object
    UtilsListHdr {.importc: "struct utils_list_hdr", header: "utils_list.h".} = object
    ConstUtilsList {.importc: "const struct utils_list", header: "utils_list.h".} = object
    ConstUtilsListHdr {.importc: "const struct utils_list_hdr", header: "utils_list.h".} = object
    MacAddr {.importc: "struct mac_addr", header: "lmac_msg.h".} = object
    MacSsid {.importc: "struct mac_ssid", header: "lmac_msg.h".} = object
    BlHw {.importc: "struct bl_hw", header: "bl_defs.h".} = object
    PmEvent {.importc: "enum PM_EVEMT", header: "bl_pm.h".} = enum
      pmEventDummy
    PmLevel {.importc: "enum PM_LEVEL", header: "bl_pm.h".} = enum
      pmLevelDummy
    PmEventAble {.importc: "enum PM_EVENT_ABLE", header: "bl_pm.h".} = enum
      pmEventAbleDummy
    PmCb {.importc: "bl_pm_cb_t", header: "bl_pm.h".} = proc(arg: pointer): cint {.cdecl.}
    UtilsListCmp = proc(a, b: ptr ConstUtilsListHdr): cint {.cdecl.}
    ScanCompleteCb = proc(data, param: pointer) {.cdecl.}
    NetifInitFn = proc(netif: ptr Netif): int8 {.cdecl.}
    NetifInputFn = proc(p: ptr Pbuf; netif: ptr Netif): int8 {.cdecl.}
    NetifVoidFn = proc(netif: ptr Netif) {.cdecl.}
    NetifErrFn = proc(netif: ptr Netif): int8 {.cdecl.}
    PbufFreeFn = proc(p: ptr Pbuf) {.cdecl.}
    IrqHandler = proc() {.cdecl.}
    ConnectCb = proc(env, ind: pointer) {.cdecl.}
    DisconnectCb = proc(env, ind: pointer) {.cdecl.}
    BeaconCb = proc(env, ind: pointer) {.cdecl.}
    EventCb = proc(env, event: pointer) {.cdecl.}
    WifiHosalFuncs {.importc: "wifi_hosal_funcs_t", header: "wifi_hosal.h", bycopy.} = object
      efuseReadMac {.importc: "efuse_read_mac".}: proc(mac: ptr uint8): cint {.cdecl.}
      rfTurnOn {.importc: "rf_turn_on".}: proc(arg: pointer): cint {.cdecl.}
      rfTurnOff {.importc: "rf_turn_off".}: proc(arg: pointer): cint {.cdecl.}
      adcDeviceGet {.importc: "adc_device_get".}: proc(): pointer {.cdecl.}
      adcTsenValueGet {.importc: "adc_tsen_value_get".}: proc(adc: pointer): cint {.cdecl.}
      pmInit {.importc: "pm_init".}: proc(): cint {.cdecl.}
      pmEventRegister {.importc: "pm_event_register".}: proc(event: PmEvent; code, capBit: uint32; priority: uint16;
                            ops: PmCb; arg: pointer; enable: PmEventAble): cint {.cdecl.}
      pmDeinit {.importc: "pm_deinit".}: proc(): cint {.cdecl.}
      pmStateRun {.importc: "pm_state_run".}: proc(): cint {.cdecl.}
      pmCapacitySet {.importc: "pm_capacity_set".}: proc(level: PmLevel): cint {.cdecl.}
      pmPostEvent {.importc: "pm_post_event".}: proc(event: PmEvent; code: uint32; retval: ptr uint32): cint {.cdecl.}
      pmEventSwitch {.importc: "pm_event_switch".}: proc(event: PmEvent; code: uint32; enable: PmEventAble): cint {.cdecl.}
    ScanDiagItem = object
      used: uint8
      ssidLen: uint8
      ssid: array[33, uint8]
      bssid: array[6, uint8]
      channel: uint8
      rssi: int8
      auth: uint8
      cipher: uint8
    SimpleEventGroup = object
      bits: uint32
    SimpleQueue = object
      itemSize: uint32
      depth: uint32
      readIdx: uint32
      writeIdx: uint32

  {.emit: "extern struct bl_hw wifi_hw;".}
  var wifi_hw {.importc, header: "bl_defs.h".}: BlHw
  var ipc_shared_env {.importc, header: "ipc_shared.h".}: uint8
  var ke_env {.importc.}: array[1, uint32]
  var vif_info_tab {.importc.}: array[CfgVirtDevMax.int * VendorVifEntrySize.int, uint8]
  var gBlOpsFuncsStorage {.exportc: "g_bl_ops_funcs".}: BlOpsFuncs
  var wifiMgmr* {.exportc.}: WifiMgmr
  var g_wifi_hosal_funcs* {.exportc.}: WifiHosalFuncs

  var wifiStarted: bool
  var hostPollEnabled: bool
  var fwStarted: bool
  var staEnabled: bool
  var apEnabled: bool
  var connectDone = -1'i32
  var disconnectDone: int32
  var scanDoneCount: uint32
  var scanItemCount: uint32
  var macIrqCount: uint32
  var macPollIrqCount: uint32
  var macTrapIrqCount: uint32
  var ipcTrapIrqCount: uint32
  var ipcPollIrqCount: uint32
  var lastStatusCode = -1'i32
  var lastReasonCode = -1'i32
  var scanDiag: array[VendorScanDiagMax, ScanDiagItem]
  var vendorRandomState = 0x6d2b_79f5'u32

  proc c_malloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>", cdecl.}
  proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>", cdecl.}
  proc c_calloc(count, size: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>", cdecl.}
  proc c_realloc(p: pointer; size: csize_t): pointer {.importc: "realloc", header: "<stdlib.h>", cdecl.}
  proc c_memset(s: pointer; c: cint; n: csize_t): pointer {.importc: "memset", header: "<string.h>", cdecl.}
  proc c_memcpy(dest, src: pointer; n: csize_t): pointer {.importc: "memcpy", header: "<string.h>", cdecl.}
  proc c_strlen(s: cstring): csize_t {.importc: "strlen", header: "<string.h>", cdecl.}
  proc tlsf_get_used(): csize_t {.importc, cdecl.}
  proc tlsf_get_total(): csize_t {.importc, cdecl.}
  proc tlsf_get_largest_free(): csize_t {.importc, cdecl.}
  proc tlsf_get_alloc_fail_count(): csize_t {.importc, cdecl.}
  proc hw_validation_log_byte(b: uint8) {.importc, cdecl.}

  proc bl808_register_trap_handler(irq: uint32; handler: IrqHandler) {.importc, cdecl.}
  proc bl808_enable_peripheral_irq(irq: uint32; level: uint8) {.importc, cdecl.}
  proc bl808_disable_peripheral_irq(irq: uint32) {.importc, cdecl.}
  proc bl606a0_wifi_init(conf: ptr WifiConf): cint {.importc, cdecl.}
  proc bl606a0_wifi_netif_init(netif: ptr Netif): int8 {.importc, cdecl.}
  proc bl_main_if_add(isSta: cint; netif: ptr Netif; vifIndex: ptr uint8): cint {.importc, cdecl.}
  proc bl_send_add_if(blHw: ptr BlHw; mac: ptr uint8; iftype: cint; p2p: bool; cfm: pointer): cint {.importc, cdecl.}
  proc bl_main_scan(netif: ptr Netif; fixedChannels: ptr uint16; channelNum: uint16;
                    bssid: ptr MacAddr; ssid: ptr MacSsid; scanMode: uint8;
                    durationScan: uint32): cint {.importc, cdecl.}
  proc bl_main_connect(ssid: ptr uint8; ssidLen: cint; psk: ptr uint8; pskLen: cint;
                       pmk: ptr uint8; pmkLen: cint; mac: ptr uint8; band: uint8;
                       freq: uint16; flags: uint32): cint {.importc, cdecl.}
  proc bl_main_disconnect(): cint {.importc, cdecl.}
  proc bl_main_phy_up(): cint {.importc, cdecl.}
  proc bl_main_apm_start(ssid, password: cstring; channel: cint; hiddenSsid: uint8;
                         bcnInt: uint16): cint {.importc, cdecl.}
  proc bl_main_apm_stop(): cint {.importc, cdecl.}
  proc wifi_hosal_rf_turn_on(arg: pointer): cint {.importc, cdecl.}
  proc mpif_clk_init() {.importc, cdecl.}
  proc sysctrl_init() {.importc, cdecl.}
  proc intc_init() {.importc, cdecl.}
  proc ipc_emb_init() {.importc, cdecl.}
  proc bl_init() {.importc, cdecl.}
  proc bl_pm_ops_register() {.importc, cdecl.}
  proc ipc_emb_wait() {.importc, cdecl.}
  proc ke_evt_set(events: uint32) {.importc, cdecl.}
  proc ke_evt_schedule() {.importc, cdecl.}
  proc bl_irq_handler() {.importc, cdecl.}
  proc bl_main_event_handle(param: cint; txFcField: pointer) {.importc, cdecl.}
  proc mac_irq() {.importc, cdecl.}
  proc hal_machw_gen_handler() {.importc, cdecl.}
  proc rf_init(xtalFreqHz: uint32) {.importc, cdecl.}
  proc phy_powroffset_set(powerOffset: ptr int8) {.importc, cdecl.}
  proc bl_tpc_update_power_rate_11b(p: ptr int8) {.importc, cdecl.}
  proc bl_tpc_update_power_rate_11g(p: ptr int8) {.importc, cdecl.}
  proc bl_tpc_update_power_rate_11n(p: ptr int8) {.importc, cdecl.}
  proc bl_rx_sm_connect_ind_cb_register(env: pointer; cb: ConnectCb): cint {.importc, cdecl.}
  proc bl_rx_sm_disconnect_ind_cb_register(env: pointer; cb: DisconnectCb): cint {.importc, cdecl.}
  proc bl_rx_beacon_ind_cb_register(env: pointer; cb: BeaconCb): cint {.importc, cdecl.}
  proc bl_rx_event_register(env: pointer; cb: EventCb): cint {.importc, cdecl.}
  proc txl_frame_dump() {.importc, cdecl.}
  proc txl_cfm_dump() {.importc, cdecl.}

  template ptrAt(base: pointer; off: uint): pointer =
    cast[pointer](cast[uint](base) + off)
  proc loadPtr(base: pointer; off: uint): pointer {.inline.} = cast[ptr pointer](ptrAt(base, off))[]
  proc storePtr(base: pointer; off: uint; value: pointer) {.inline.} = cast[ptr pointer](ptrAt(base, off))[] = value
  proc loadU8(base: pointer; off: uint): uint8 {.inline.} = cast[ptr uint8](ptrAt(base, off))[]
  proc storeU8(base: pointer; off: uint; value: uint8) {.inline.} = cast[ptr uint8](ptrAt(base, off))[] = value
  proc loadI8(base: pointer; off: uint): int8 {.inline.} = cast[ptr int8](ptrAt(base, off))[]
  proc storeU16(base: pointer; off: uint; value: uint16) {.inline.} = cast[ptr uint16](ptrAt(base, off))[] = value
  proc loadU16(base: pointer; off: uint): uint16 {.inline.} = cast[ptr uint16](ptrAt(base, off))[]
  proc storeU32(base: pointer; off: uint; value: uint32) {.inline.} = cast[ptr uint32](ptrAt(base, off))[] = value
  proc loadU32(base: pointer; off: uint): uint32 {.inline.} = cast[ptr uint32](ptrAt(base, off))[]
  proc loadI32(base: pointer; off: uint): int32 {.inline.} = cast[ptr int32](ptrAt(base, off))[]
  proc storeI32(base: pointer; off: uint; value: int32) {.inline.} = cast[ptr int32](ptrAt(base, off))[] = value
  proc regRead32(reg: uint32): uint32 {.inline.} = cast[ptr uint32](reg.uint)[]
  proc regWrite32(reg, value: uint32) {.inline.} = cast[ptr uint32](reg.uint)[] = value
  proc regUpdate32(reg, mask, value: uint32) {.inline.} =
    let cur = regRead32(reg)
    regWrite32(reg, (cur and not mask) or (value and mask))
  proc zero(p: pointer; n: uint) {.inline.} = discard c_memset(p, 0, n.csize_t)
  proc copyMem(dest, src: pointer; n: uint) {.inline.} = discard c_memcpy(dest, src, n.csize_t)
  proc wifiHwRaw(): pointer {.inline.} = cast[pointer](addr wifi_hw)
  proc mgmrRaw(): pointer {.inline.} = cast[pointer](addr wifiMgmr)
  proc staIface(): pointer {.inline.} = ptrAt(mgmrRaw(), MgmrStaOff)
  proc apIface(): pointer {.inline.} = ptrAt(mgmrRaw(), MgmrApOff)
  proc ifaceNetif(iface: pointer): pointer {.inline.} = ptrAt(iface, WifiIfaceNetifOff)
  proc netifHwaddr(netif: pointer): ptr uint8 {.inline.} = cast[ptr uint8](ptrAt(netif, NetifHwaddrOff))
  proc vifAt(idx: uint): pointer {.inline.} = ptrAt(ptrAt(wifiHwRaw(), BlHwVifTableOff), idx * BlVifSize)

  proc vendorPrintChar(c: char)
  proc vendorPutsRaw(s: cstring)
  proc vendorPrintU32(value: uint32; base: uint32)
  proc vendorPollOnce()
  proc osMsleep(ms: clong): cint {.cdecl.}
  proc bl_wifi_clock_enable*(): cint {.exportc, cdecl.}
  proc bl_wifi_enable_irq*(): cint {.exportc, cdecl.}
  proc bl_wifi_mac_addr_get*(mac: ptr uint8): cint {.exportc, cdecl.}
  proc pbuf_free*(p: ptr Pbuf): uint8 {.exportc, cdecl.}
  proc bl_pm_init*(): cint {.exportc, cdecl.}
  proc bl_pm_deinit*(): cint {.exportc, cdecl.}
  proc bl_pm_state_run*(): cint {.exportc, cdecl.}
  proc bl_pm_capacity_set*(level: PmLevel): cint {.exportc, cdecl.}
  proc bl_pm_event_register*(event: PmEvent; code, capBit: uint32; priority: uint16; ops: PmCb; arg: pointer; enable: PmEventAble): cint {.exportc, cdecl.}
  proc pm_post_event*(event: PmEvent; code: uint32; retval: ptr uint32): cint {.exportc, cdecl.}
  proc bl_pm_event_switch*(event: PmEvent; code: uint32; enable: PmEventAble): cint {.exportc, cdecl.}

  proc rawDelay(loops: uint32) =
    for _ in 0'u32 ..< loops:
      {.emit: "__asm__ volatile(\"nop\");".}

  proc readMtimeUs(): uint64 =
    let mtime = cast[ptr UncheckedArray[uint32]](MtimeBase.uint)
    var hi1, lo, hi2: uint32
    while true:
      hi1 = mtime[1]
      lo = mtime[0]
      hi2 = mtime[1]
      if hi1 == hi2:
        break
    (uint64(hi1) shl 32) or uint64(lo)

  proc delayMtimeUs(us: uint32) =
    var now = readMtimeUs()
    var last = now
    let deadline = now + us.uint64
    var staleReads: uint32
    while int64(now - deadline) < 0:
      rawDelay(32)
      now = readMtimeUs()
      if now == last:
        inc staleReads
        if staleReads > 1024:
          rawDelay(us * 96'u32 + 2048'u32)
          return
      else:
        last = now
        staleReads = 0

  proc arch_delay_us*(us: uint32) {.exportc, cdecl.} = delayMtimeUs(us)
  proc udelay*(us: uint32) {.exportc, cdecl.} = arch_delay_us(us)
  proc wrapWaitUs*(us: uint32) {.exportc: "__wrap_wait_us", cdecl.} = arch_delay_us(us)

  proc vendorPrintChar(c: char) =
    let fifo = cast[ptr uint32](UartFifoCfg1.uint)
    let data = cast[ptr uint32](UartWdata.uint)
    var timeout: uint32
    if c == '\n':
      when defined(bl808WifiVendorValidationLog):
        hw_validation_log_byte('\r'.uint8)
      timeout = 1_000_000
      while (fifo[] and 0x3f'u32) == 0 and timeout != 0:
        dec timeout
      data[] = '\r'.uint32
    when defined(bl808WifiVendorValidationLog):
      hw_validation_log_byte(c.uint8)
    timeout = 1_000_000
    while (fifo[] and 0x3f'u32) == 0 and timeout != 0:
      dec timeout
    data[] = c.uint8.uint32

  proc vendorPutsRaw(s: cstring) =
    if s == nil:
      return
    var i = 0
    while s[i] != '\0':
      vendorPrintChar(s[i])
      inc i

  proc nimVendorPrintChar(c: char) {.exportc: "bl808_nim_vendor_print_char", cdecl.} =
    vendorPrintChar(c)

  proc nimVendorPutsRaw(s: cstring) {.exportc: "bl808_nim_vendor_puts_raw", cdecl.} =
    vendorPutsRaw(s)

  proc validationPutsRaw(s: cstring) =
    when not defined(bl808WifiVendorValidationLog):
      if s == nil:
        return
      var i = 0
      while s[i] != '\0':
        hw_validation_log_byte(s[i].uint8)
        inc i
    else:
      discard s

  proc vendorPrintU32(value: uint32; base: uint32) =
    var v = value
    var buf: array[11, char]
    var pos = 0
    if v == 0:
      vendorPrintChar('0')
      return
    while v != 0 and pos < buf.len:
      let d = v mod base
      buf[pos] = char(if d < 10: ord('0') + d.int else: ord('A') + d.int - 10)
      inc pos
      v = v div base
    while pos > 0:
      dec pos
      vendorPrintChar(buf[pos])

  {.emit: """
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>

extern void bl808_nim_vendor_print_char(char c);
extern void bl808_nim_vendor_puts_raw(char *s);

static void bl808_nim_vendor_print_u32(uint32_t value, uint32_t base) {
  char buf[11];
  unsigned int pos = 0;
  if (value == 0) {
    bl808_nim_vendor_print_char('0');
    return;
  }
  while (value && pos < sizeof(buf)) {
    uint32_t d = value % base;
    buf[pos++] = (char)(d < 10 ? ('0' + d) : ('A' + d - 10));
    value /= base;
  }
  while (pos) {
    bl808_nim_vendor_print_char(buf[--pos]);
  }
}

static void bl808_nim_vendor_vprintf(const char *fmt, va_list ap) {
  const char *p = fmt;
  if (!fmt) return;
  while (p && *p) {
    if (*p != '%') {
      bl808_nim_vendor_print_char(*p++);
      continue;
    }
    p++;
    while (*p == '0' || *p == '-' || *p == '+' || *p == ' ' || *p == '#') p++;
    while (*p >= '0' && *p <= '9') p++;
    if (*p == 'l') {
      p++;
      if (*p == 'l') p++;
    }
    switch (*p) {
    case 's':
      bl808_nim_vendor_puts_raw(va_arg(ap, const char *));
      break;
    case 'd':
    case 'i': {
      int v = va_arg(ap, int);
      if (v < 0) {
        bl808_nim_vendor_print_char('-');
        v = -v;
      }
      bl808_nim_vendor_print_u32((uint32_t)v, 10);
      break;
    }
    case 'u':
      bl808_nim_vendor_print_u32(va_arg(ap, unsigned int), 10);
      break;
    case 'p':
      bl808_nim_vendor_puts_raw("0x");
      bl808_nim_vendor_print_u32((uint32_t)(uintptr_t)va_arg(ap, void *), 16);
      break;
    case 'x':
    case 'X':
      bl808_nim_vendor_print_u32(va_arg(ap, unsigned int), 16);
      break;
    case 'c':
      bl808_nim_vendor_print_char((char)va_arg(ap, int));
      break;
    case '%':
      bl808_nim_vendor_print_char('%');
      break;
    default:
      bl808_nim_vendor_print_char('%');
      if (*p) bl808_nim_vendor_print_char(*p);
      break;
    }
    if (*p) p++;
  }
}

__attribute__((weak)) int printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  bl808_nim_vendor_vprintf(fmt, ap);
  va_end(ap);
  return 0;
}

__attribute__((weak)) int puts(const char *s) {
  bl808_nim_vendor_puts_raw(s);
  bl808_nim_vendor_puts_raw("\r\n");
  return 0;
}

int snprintf(char *str, size_t size, const char *fmt, ...) {
  (void)fmt;
  if (str && size) str[0] = 0;
  return 0;
}

void bl808_nim_os_printf(char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  bl808_nim_vendor_vprintf(fmt, ap);
  va_end(ap);
}

void bl808_nim_os_log_write(uint32_t level, char *tag, char *file,
                            int line, char *fmt, ...) {
  (void)level;
  (void)tag;
  (void)file;
  (void)line;
  va_list ap;
  va_start(ap, fmt);
  bl808_nim_vendor_vprintf(fmt, ap);
  va_end(ap);
}
""".}

  proc osPrintf(fmt: cstring) {.importc: "bl808_nim_os_printf", cdecl, varargs.}
  proc osPuts(s: cstring) {.cdecl.} = vendorPutsRaw(s)
  proc osAssert(file: cstring; line: cint; fn: cstring; expr: cstring) {.cdecl.} =
    vendorPutsRaw("[WIFI] assert ")
    vendorPutsRaw(file)
    vendorPrintChar(':')
    vendorPrintU32(line.uint32, 10)
    vendorPrintChar(' ')
    vendorPutsRaw(fn)
    vendorPrintChar(' ')
    vendorPutsRaw(expr)
    vendorPutsRaw("\r\n")
    while true:
      rawDelay(1000)

  proc osEnterCritical(): uint32 {.cdecl.} = 0
  proc osExitCritical(level: uint32) {.cdecl.} = discard level

  proc osMsleep(ms: clong): cint {.cdecl.} =
    let deadline = readMtimeUs() + uint64(ms) * 1000'u64
    while int64(readMtimeUs() - deadline) < 0:
      vendorPollOnce()
      delayMtimeUs(100)
    0

  proc osSleep(seconds: cuint): cint {.cdecl.} = osMsleep(clong(seconds) * 1000)

  proc osEventGroupCreate(): pointer {.cdecl.} = c_calloc(1, sizeof(SimpleEventGroup).csize_t)
  proc osEventGroupDelete(event: pointer) {.cdecl.} = c_free(event)
  proc osEventGroupSend(event: pointer; bits: uint32): uint32 {.cdecl.} =
    if event == nil: return 0
    let g = cast[ptr SimpleEventGroup](event)
    g.bits = g.bits or bits
    g.bits
  proc osEventGroupWait(event: pointer; bitsToWaitFor: uint32; clearOnExit, waitForAll: cint;
                        blockTimeTick: uint32): uint32 {.cdecl.} =
    if event == nil:
      return 0
    let g = cast[ptr SimpleEventGroup](event)
    var loops = if blockTimeTick != 0: blockTimeTick * 64'u32 else: 1'u32
    while blockTimeTick == BlOsWaitingForever or loops != 0:
      let bits = g.bits and bitsToWaitFor
      let matched = if waitForAll != 0: bits == bitsToWaitFor else: bits != 0
      if matched:
        if clearOnExit != 0:
          g.bits = g.bits and not bitsToWaitFor
        return bits
      if blockTimeTick != BlOsWaitingForever:
        dec loops
      vendorPollOnce()
      rawDelay(128)
    0

  proc osEventRegister(t: cint; cb, arg: pointer): cint {.cdecl.} = discard t; discard cb; discard arg; 0
  proc osEventNotify(evt, value: cint): cint {.cdecl.} = discard evt; discard value; 0
  proc osTaskCreate(name: cstring; entry: pointer; stackDepth: uint32; param: pointer;
                    prio: uint32; taskHandle: pointer): cint {.cdecl.} =
    discard name; discard entry; discard stackDepth; discard param; discard prio; discard taskHandle; 0
  proc osTaskDelete(taskHandle: pointer) {.cdecl.} = discard taskHandle
  proc osTaskGetCurrent(): pointer {.cdecl.} = cast[pointer](1)
  proc osTaskNotifyCreate(): pointer {.cdecl.} = cast[pointer](1)
  proc osTaskNotify(taskHandle: pointer) {.cdecl.} = discard taskHandle
  proc osTaskWait(taskHandle: pointer; tick: uint32) {.cdecl.} = discard taskHandle; discard osEventGroupWait(nil, 0, 0, 0, tick)
  proc osNoopVoid() {.cdecl.} = discard
  proc osIrqAttach(n: int32; f, arg: pointer) {.cdecl.} =
    discard arg
    if f != nil and n >= 0:
      bl808_register_trap_handler(n.uint32, cast[IrqHandler](f))
  proc osIrqEnable(n: int32) {.cdecl.} =
    if n >= 0: bl808_enable_peripheral_irq(n.uint32, 1)
  proc osIrqDisable(n: int32) {.cdecl.} =
    if n >= 0: bl808_disable_peripheral_irq(n.uint32)
  proc osWorkqueueCreate(): pointer {.cdecl.} = nil
  proc osWorkqueueSubmit(work, worker, argv: pointer; tick: clong): cint {.cdecl.} =
    discard work; discard worker; discard argv; discard tick; 0
  proc osTimerCreate(fn, argv: pointer): pointer {.cdecl.} = discard fn; discard argv; c_calloc(1, 4)
  proc osTimerDelete(timer: pointer; tick: uint32): cint {.cdecl.} = discard tick; c_free(timer); 0
  proc osTimerStart(timer: pointer; tSec, tNsec: clong): cint {.cdecl.} =
    discard timer; discard tSec; discard tNsec; 0
  proc osSemCreate(init: uint32): pointer {.cdecl.} =
    result = c_calloc(1, sizeof(SimpleEventGroup).csize_t)
    if result != nil: cast[ptr SimpleEventGroup](result).bits = init
  proc osSemDelete(sem: pointer) {.cdecl.} = c_free(sem)
  proc osSemTake(sem: pointer; tick: uint32): int32 {.cdecl.} =
    if osEventGroupWait(sem, 1, 1, 1, tick) != 0: 0 else: -1
  proc osSemGive(sem: pointer): int32 {.cdecl.} = discard osEventGroupSend(sem, 1); 0
  proc osMutexCreate(): pointer {.cdecl.} = cast[pointer](1)
  proc osMutexDelete(mutex: pointer) {.cdecl.} = discard mutex
  proc osMutexLock(mutex: pointer): int32 {.cdecl.} = discard mutex; 0
  proc osMutexUnlock(mutex: pointer): int32 {.cdecl.} = discard mutex; 0

  proc osQueueCreate(queueLen, itemSize: uint32): pointer {.cdecl.} =
    let total = sizeof(SimpleQueue).uint + queueLen.uint * itemSize.uint
    result = c_calloc(1, total.csize_t)
    if result != nil:
      let q = cast[ptr SimpleQueue](result)
      q.itemSize = itemSize
      q.depth = queueLen
  proc osQueueDelete(queue: pointer) {.cdecl.} = c_free(queue)
  proc osQueueSendWait(queue, item: pointer; length, ticks: uint32; prio: cint): cint {.cdecl.} =
    discard ticks; discard prio
    if queue == nil: return -1
    let q = cast[ptr SimpleQueue](queue)
    if item == nil or length != q.itemSize or (q.writeIdx - q.readIdx) >= q.depth:
      return -1
    let slot = ptrAt(queue, sizeof(SimpleQueue).uint + (q.writeIdx mod q.depth).uint * q.itemSize.uint)
    copyMem(slot, item, q.itemSize.uint)
    inc q.writeIdx
    0
  proc osQueueSend(queue, item: pointer; length: uint32): cint {.cdecl.} =
    osQueueSendWait(queue, item, length, 0, 0)
  proc osQueueRecv(queue, item: pointer; length, tick: uint32): cint {.cdecl.} =
    if queue == nil or item == nil: return -1
    let q = cast[ptr SimpleQueue](queue)
    if length != q.itemSize: return -1
    var loops = if tick != 0: tick else: 1'u32
    while tick == BlOsWaitingForever or loops != 0:
      if q.readIdx != q.writeIdx:
        let slot = ptrAt(queue, sizeof(SimpleQueue).uint + (q.readIdx mod q.depth).uint * q.itemSize.uint)
        copyMem(item, slot, q.itemSize.uint)
        inc q.readIdx
        return 0
      if tick != BlOsWaitingForever:
        dec loops
      vendorPollOnce()
      rawDelay(128)
    -1

  proc osMalloc(size: cuint): pointer {.cdecl.} =
    result = c_malloc(size.csize_t)
    if result == nil:
      vendorPutsRaw("[WIFI] malloc fail size=")
      vendorPrintU32(size.uint32, 10)
      vendorPutsRaw(" used=")
      vendorPrintU32(tlsf_get_used().uint32, 10)
      vendorPutsRaw(" total=")
      vendorPrintU32(tlsf_get_total().uint32, 10)
      vendorPutsRaw(" largest=")
      vendorPrintU32(tlsf_get_largest_free().uint32, 10)
      vendorPutsRaw(" fails=")
      vendorPrintU32(tlsf_get_alloc_fail_count().uint32, 10)
      vendorPutsRaw("\r\n")
  proc osFree(p: pointer) {.cdecl.} = c_free(p)
  proc osZalloc(size: cuint): pointer {.cdecl.} = c_calloc(1, size.csize_t)
  proc osGetTimeMs(): uint64 {.cdecl.} = readMtimeUs() div 1000'u64
  proc osGetTick(): uint32 {.cdecl.} = osGetTimeMs().uint32
  proc osLogWrite(level: uint32; tag, file: cstring; line: cint; fmt: cstring)
      {.importc: "bl808_nim_os_log_write", cdecl, varargs.}
  proc osTaskNotifyIsr(taskHandle: pointer): cint {.cdecl.} = discard taskHandle; 0
  proc osYieldFromIsr(xYield: cint) {.cdecl.} = discard xYield
  proc osMsToTick(ms: cuint): cuint {.cdecl.} = ms
  proc osSetTimeout(): pointer {.cdecl.} = cast[pointer](osGetTick().uint)
  proc osCheckTimeout(timeout: pointer; ticksToWait: ptr uint32): cint {.cdecl.} =
    discard timeout
    if ticksToWait != nil and ticksToWait[] != 0:
      dec ticksToWait[]
      return 0
    1

  proc setupBlOps() =
    let base = cast[pointer](addr g_bl_ops_funcs)
    storeU32(base, OpVersionOff, BlOsAdapterVersion)
    storePtr(base, OpPrintfOff, cast[pointer](osPrintf))
    storePtr(base, OpPutsOff, cast[pointer](osPuts))
    storePtr(base, OpAssertOff, cast[pointer](osAssert))
    storePtr(base, OpInitOff, nil)
    storePtr(base, OpEnterCriticalOff, cast[pointer](osEnterCritical))
    storePtr(base, OpExitCriticalOff, cast[pointer](osExitCritical))
    storePtr(base, OpMsleepOff, cast[pointer](osMsleep))
    storePtr(base, OpSleepOff, cast[pointer](osSleep))
    storePtr(base, OpEventGroupCreateOff, cast[pointer](osEventGroupCreate))
    storePtr(base, OpEventGroupDeleteOff, cast[pointer](osEventGroupDelete))
    storePtr(base, OpEventGroupSendOff, cast[pointer](osEventGroupSend))
    storePtr(base, OpEventGroupWaitOff, cast[pointer](osEventGroupWait))
    storePtr(base, OpEventRegisterOff, cast[pointer](osEventRegister))
    storePtr(base, OpEventNotifyOff, cast[pointer](osEventNotify))
    storePtr(base, OpTaskCreateOff, cast[pointer](osTaskCreate))
    storePtr(base, OpTaskDeleteOff, cast[pointer](osTaskDelete))
    storePtr(base, OpTaskGetCurrentOff, cast[pointer](osTaskGetCurrent))
    storePtr(base, OpTaskNotifyCreateOff, cast[pointer](osTaskNotifyCreate))
    storePtr(base, OpTaskNotifyOff, cast[pointer](osTaskNotify))
    storePtr(base, OpTaskWaitOff, cast[pointer](osTaskWait))
    storePtr(base, OpLockGaintOff, cast[pointer](osNoopVoid))
    storePtr(base, OpUnlockGaintOff, cast[pointer](osNoopVoid))
    storePtr(base, OpIrqAttachOff, cast[pointer](osIrqAttach))
    storePtr(base, OpIrqEnableOff, cast[pointer](osIrqEnable))
    storePtr(base, OpIrqDisableOff, cast[pointer](osIrqDisable))
    storePtr(base, OpWorkqueueCreateOff, cast[pointer](osWorkqueueCreate))
    storePtr(base, OpWorkqueueSubmitHpOff, cast[pointer](osWorkqueueSubmit))
    storePtr(base, OpWorkqueueSubmitLpOff, cast[pointer](osWorkqueueSubmit))
    storePtr(base, OpTimerCreateOff, cast[pointer](osTimerCreate))
    storePtr(base, OpTimerDeleteOff, cast[pointer](osTimerDelete))
    storePtr(base, OpTimerStartOnceOff, cast[pointer](osTimerStart))
    storePtr(base, OpTimerStartPeriodicOff, cast[pointer](osTimerStart))
    storePtr(base, OpSemCreateOff, cast[pointer](osSemCreate))
    storePtr(base, OpSemDeleteOff, cast[pointer](osSemDelete))
    storePtr(base, OpSemTakeOff, cast[pointer](osSemTake))
    storePtr(base, OpSemGiveOff, cast[pointer](osSemGive))
    storePtr(base, OpMutexCreateOff, cast[pointer](osMutexCreate))
    storePtr(base, OpMutexDeleteOff, cast[pointer](osMutexDelete))
    storePtr(base, OpMutexLockOff, cast[pointer](osMutexLock))
    storePtr(base, OpMutexUnlockOff, cast[pointer](osMutexUnlock))
    storePtr(base, OpQueueCreateOff, cast[pointer](osQueueCreate))
    storePtr(base, OpQueueDeleteOff, cast[pointer](osQueueDelete))
    storePtr(base, OpQueueSendWaitOff, cast[pointer](osQueueSendWait))
    storePtr(base, OpQueueSendOff, cast[pointer](osQueueSend))
    storePtr(base, OpQueueRecvOff, cast[pointer](osQueueRecv))
    storePtr(base, OpMallocOff, cast[pointer](osMalloc))
    storePtr(base, OpFreeOff, cast[pointer](osFree))
    storePtr(base, OpZallocOff, cast[pointer](osZalloc))
    storePtr(base, OpGetTimeMsOff, cast[pointer](osGetTimeMs))
    storePtr(base, OpGetTickOff, cast[pointer](osGetTick))
    storePtr(base, OpLogWriteOff, cast[pointer](osLogWrite))
    storePtr(base, OpTaskNotifyIsrOff, cast[pointer](osTaskNotifyIsr))
    storePtr(base, OpYieldFromIsrOff, cast[pointer](osYieldFromIsr))
    storePtr(base, OpMsToTickOff, cast[pointer](osMsToTick))
    storePtr(base, OpSetTimeoutOff, cast[pointer](osSetTimeout))
    storePtr(base, OpCheckTimeoutOff, cast[pointer](osCheckTimeout))

  proc hosalRetZero(arg: pointer): cint {.cdecl.} = discard arg; 0
  proc hosalAdcDeviceGet(): pointer {.cdecl.} = nil
  proc setupHosal() =
    g_wifi_hosal_funcs.efuseReadMac = bl_wifi_mac_addr_get
    g_wifi_hosal_funcs.rfTurnOn = hosalRetZero
    g_wifi_hosal_funcs.rfTurnOff = hosalRetZero
    g_wifi_hosal_funcs.adcDeviceGet = hosalAdcDeviceGet
    g_wifi_hosal_funcs.adcTsenValueGet = hosalRetZero
    g_wifi_hosal_funcs.pmInit = bl_pm_init
    g_wifi_hosal_funcs.pmEventRegister = bl_pm_event_register
    g_wifi_hosal_funcs.pmDeinit = bl_pm_deinit
    g_wifi_hosal_funcs.pmStateRun = bl_pm_state_run
    g_wifi_hosal_funcs.pmCapacitySet = bl_pm_capacity_set
    g_wifi_hosal_funcs.pmPostEvent = pm_post_event
    g_wifi_hosal_funcs.pmEventSwitch = bl_pm_event_switch

  proc scanDiagReset() = zero(addr scanDiag[0], sizeof(scanDiag).uint)
  proc scanDiagStore(ind: pointer) =
    if ind == nil: return
    let len = loadI32(ind, WifiBeaconSsidLenOff)
    if len < 0 or len > 32: return
    let slot = (scanItemCount mod VendorScanDiagMax.uint32).int
    zero(addr scanDiag[slot], sizeof(ScanDiagItem).uint)
    scanDiag[slot].used = 1
    scanDiag[slot].ssidLen = len.uint8
    if len > 0:
      copyMem(addr scanDiag[slot].ssid[0], ptrAt(ind, WifiBeaconSsidOff), len.uint)
    copyMem(addr scanDiag[slot].bssid[0], ptrAt(ind, WifiBeaconBssidOff), 6)
    scanDiag[slot].channel = loadU8(ind, WifiBeaconChannelOff)
    scanDiag[slot].rssi = loadI8(ind, WifiBeaconRssiOff)
    scanDiag[slot].auth = loadU8(ind, WifiBeaconAuthOff)
    scanDiag[slot].cipher = loadU8(ind, WifiBeaconCipherOff)

  proc bl808_wifi_vendor_scan_diag_count*(): uint32 {.exportc, cdecl.} =
    if scanItemCount < VendorScanDiagMax.uint32: scanItemCount else: VendorScanDiagMax.uint32

  proc bl808_wifi_vendor_scan_diag_get*(index: uint32; ssidLen, ssid, channel: pointer;
                                        rssi, auth, cipher, bssid: pointer): cint {.exportc, cdecl.} =
    if index >= bl808_wifi_vendor_scan_diag_count(): return -1
    let start = if scanItemCount > VendorScanDiagMax.uint32: scanItemCount mod VendorScanDiagMax.uint32 else: 0'u32
    let slot = ((start + index) mod VendorScanDiagMax.uint32).int
    if scanDiag[slot].used == 0: return -1
    if ssidLen != nil: cast[ptr uint8](ssidLen)[] = scanDiag[slot].ssidLen
    if ssid != nil: copyMem(ssid, addr scanDiag[slot].ssid[0], scanDiag[slot].ssid.len.uint)
    if channel != nil: cast[ptr uint8](channel)[] = scanDiag[slot].channel
    if rssi != nil: cast[ptr int8](rssi)[] = scanDiag[slot].rssi
    if auth != nil: cast[ptr uint8](auth)[] = scanDiag[slot].auth
    if cipher != nil: cast[ptr uint8](cipher)[] = scanDiag[slot].cipher
    if bssid != nil: copyMem(bssid, addr scanDiag[slot].bssid[0], scanDiag[slot].bssid.len.uint)
    0

  proc wifiChannelToFreq(channel: uint8): uint16 =
    if channel >= 1 and channel <= 13: uint16(2407 + channel.uint16 * 5)
    elif channel == 14: 2484'u16
    else: 0'u16

  proc bl808WifiVendorSwResetCfg0(bit: uint32) =
    let reg = GlbBase + 0x540'u32
    let mask = 1'u32 shl bit
    regWrite32(reg, regRead32(reg) and not mask)
    discard regRead32(reg)
    regWrite32(reg, regRead32(reg) or mask)
    discard regRead32(reg)
    regWrite32(reg, regRead32(reg) and not mask)
    discard regRead32(reg)

  proc bl808WifiVendorEnableWirelessClocks() =
    regWrite32(GlbBase + 0x580'u32, regRead32(GlbBase + 0x580'u32) or ((1'u32 shl 5) or (1'u32 shl 6) or (1'u32 shl 7)))
    regWrite32(GlbBase + 0x584'u32, regRead32(GlbBase + 0x584'u32) or (1'u32 shl 1))
    regWrite32(GlbBase + 0x588'u32, regRead32(GlbBase + 0x588'u32) or ((1'u32 shl 4) or (1'u32 shl 8) or (1'u32 shl 10)))
    regUpdate32(GlbBase + 0x3B0'u32, 0x0f, 1)

  proc bl808WifiVendorConfigureDigClock() =
    let reg = GlbBase + 0x250'u32
    var v = regRead32(reg)
    let dig32 = v and (1'u32 shl 12)
    v = v and not ((1'u32 shl 24) or (1'u32 shl 12))
    regWrite32(reg, v)
    v = regRead32(reg)
    v = (v and not (3'u32 shl 28)) or (1'u32 shl 28)
    regWrite32(reg, v)
    v = regRead32(reg)
    v = (v and not (0x7f'u32 shl 16)) or (0x4e'u32 shl 16) or (1'u32 shl 25) or (1'u32 shl 24) or dig32
    regWrite32(reg, v)

  proc bl808WifiVendorPowerOnXtalWifiPll() =
    let aon = 0x2000_F000'u32
    let hbn = 0x2000_F000'u32
    let mmGlb = 0x3000_7000'u32
    regWrite32(aon + 0x880'u32, regRead32(aon + 0x880'u32) or 0x37'u32)
    arch_delay_us(120)
    regWrite32(hbn + 0x10c'u32, (regRead32(hbn + 0x10c'u32) and 0xffff_0000'u32) or 0x5804'u32)
    if (regRead32(GlbBase + 0x810'u32) and (1'u32 shl 10)) != 0:
      regWrite32(GlbBase + 0x824'u32, regRead32(GlbBase + 0x824'u32) or (1'u32 shl 12))
      regWrite32(GlbBase + 0x830'u32, regRead32(GlbBase + 0x830'u32) or 0x8000_003e'u32)
      regWrite32(GlbBase + 0x090'u32, regRead32(GlbBase + 0x090'u32) or 1)
      regWrite32(mmGlb, regRead32(mmGlb) or 1)
      return
    regUpdate32(GlbBase + 0x810'u32, (1'u32 shl 10) or (1'u32 shl 9), 0)
    regUpdate32(GlbBase + 0x814'u32, (0x0f'u32 shl 8) or (0x03'u32 shl 16), (2'u32 shl 8) or (1'u32 shl 16))
    regUpdate32(GlbBase + 0x818'u32, (1'u32 shl 8) or (0x03'u32 shl 6) or (0x03'u32 shl 4), 2'u32 shl 4)
    regUpdate32(GlbBase + 0x81c'u32, (1'u32 shl 0) or (1'u32 shl 8) or (0x03'u32 shl 12) or (0x03'u32 shl 14) or (0x07'u32 shl 16), (1'u32 shl 8) or (2'u32 shl 12) or (1'u32 shl 14) or (3'u32 shl 16))
    regUpdate32(GlbBase + 0x820'u32, 0x03, 1)
    regUpdate32(GlbBase + 0x824'u32, 0x07, 5)
    regUpdate32(GlbBase + 0x828'u32, 0x03ff_ffff'u32 or (1'u32 shl 28) or (1'u32 shl 31), 0x0180_0000'u32 or (1'u32 shl 28) or (1'u32 shl 31))
    regWrite32(GlbBase + 0x810'u32, regRead32(GlbBase + 0x810'u32) or (1'u32 shl 9))
    arch_delay_us(3)
    regWrite32(GlbBase + 0x810'u32, regRead32(GlbBase + 0x810'u32) or (1'u32 shl 10))
    arch_delay_us(3)
    for bit in [0'u32, 2'u32]:
      regWrite32(GlbBase + 0x810'u32, regRead32(GlbBase + 0x810'u32) or (1'u32 shl bit))
      arch_delay_us(2)
      regWrite32(GlbBase + 0x810'u32, regRead32(GlbBase + 0x810'u32) and not (1'u32 shl bit))
      arch_delay_us(2)
      regWrite32(GlbBase + 0x810'u32, regRead32(GlbBase + 0x810'u32) or (1'u32 shl bit))
    regWrite32(GlbBase + 0x824'u32, regRead32(GlbBase + 0x824'u32) or (1'u32 shl 12))
    regWrite32(GlbBase + 0x830'u32, regRead32(GlbBase + 0x830'u32) or 0x8000_003e'u32)
    arch_delay_us(75)
    regWrite32(GlbBase + 0x090'u32, regRead32(GlbBase + 0x090'u32) or 1)
    regWrite32(mmGlb, regRead32(mmGlb) or 1)

  proc bl808WifiVendorPrepareWirelessDomain() =
    var prepared {.global.}: bool
    if prepared:
      bl808WifiVendorEnableWirelessClocks()
      return
    regUpdate32(GlbBase + 0x60c'u32, 0xff, 0)
    bl808WifiVendorPowerOnXtalWifiPll()
    bl808WifiVendorConfigureDigClock()
    bl808WifiVendorEnableWirelessClocks()
    bl808WifiVendorSwResetCfg0(4)
    bl808WifiVendorConfigureDigClock()
    bl808WifiVendorEnableWirelessClocks()
    prepared = true

  proc bl808WifiVendorPollEmbEvents() =
    if (regRead32(IpcEmb2AppStatus) and IpcA2eMsgBit) != 0:
      ke_evt_set(KeEvtIpcEmbMsg)
  proc bl808WifiVendorClearEmbIpc() = regWrite32(IpcApp2EmbAck, 0xffff_ffff'u32)
  proc bl808WifiVendorClearHostIpc() = regWrite32(IpcEmb2AppAck, 0xffff_ffff'u32)
  proc bl808WifiVendorHostIpcStatus(): uint32 = regRead32(IpcEmb2AppRawStatus)

  proc bl808WifiVendorDriveRfStatus() =
    var rfCtrl = regRead32(RfStatusCtrl)
    if (regRead32(MacRfStatus) and MacRfActiveBit) != 0:
      rfCtrl = rfCtrl or 0x01'u32
    else:
      rfCtrl = rfCtrl and not 0x01'u32
    regWrite32(RfStatusCtrl, rfCtrl)

  proc bl808WifiVendorPollMacIrq() =
    var guard = 32
    while guard > 0:
      dec guard
      let platformPending = regRead32(MacIrqStatus0) or regRead32(MacIrqStatus1)
      let machwPending = regRead32(MachwIrqRaw) and regRead32(MachwIrqUnmask)
      if platformPending == 0 and machwPending == 0:
        break
      inc macIrqCount
      inc macPollIrqCount
      if platformPending != 0: mac_irq() else: hal_machw_gen_handler()

  proc bl808WifiVendorMacIrqTrampoline() {.cdecl.} =
    inc macIrqCount
    inc macTrapIrqCount
    mac_irq()
  proc bl808WifiVendorIpcIrqTrampoline() {.cdecl.} =
    inc ipcTrapIrqCount
    bl_irq_handler()

  proc bl808WifiVendorApplyHighPowerProfile() =
    var ch: array[14, int8]
    var pwr11b = [0x1c'i8, 0x1c'i8, 0x1c'i8, 0x1c'i8]
    var pwr11g = [0x1c'i8, 0x1c'i8, 0x1c'i8, 0x1c'i8, 0x1c'i8, 0x1c'i8, 0x1c'i8, 0x1c'i8]
    var pwr11n = [0x1c'i8, 0x1c'i8, 0x1c'i8, 0x1c'i8, 0x1c'i8, 0x1c'i8, 0x1c'i8, 0x1c'i8]
    phy_powroffset_set(addr ch[0])
    bl_tpc_update_power_rate_11b(addr pwr11b[0])
    bl_tpc_update_power_rate_11g(addr pwr11g[0])
    bl_tpc_update_power_rate_11n(addr pwr11n[0])

  proc bl808WifiVendorTrace(step: cstring) =
    validationPutsRaw("[WIFI-NIMFW] ")
    validationPutsRaw(step)
    validationPutsRaw("\r\n")
    vendorPutsRaw("[WIFI-NIMFW] ")
    vendorPutsRaw(step)
    vendorPutsRaw("\r\n")

  proc bl808WifiVendorFwStart() =
    if fwStarted: return
    setupBlOps()
    setupHosal()
    discard bl_wifi_clock_enable()
    let irqState = osEnterCritical()
    regWrite32(IntcPend, regRead32(IntcPend) or 0x10)
    arch_delay_us(100)
    regWrite32(IntcPend, regRead32(IntcPend) and not 0x10'u32)
    arch_delay_us(100)
    osExitCritical(irqState)
    bl808WifiVendorTrace("wifi_hosal_rf_turn_on begin")
    discard wifi_hosal_rf_turn_on(nil)
    bl808WifiVendorTrace("wifi_hosal_rf_turn_on done")
    bl808WifiVendorTrace("rf_init begin")
    rf_init(40_000_000)
    bl808WifiVendorTrace("rf_init done")
    bl808WifiVendorTrace("high_power_profile begin")
    bl808WifiVendorApplyHighPowerProfile()
    bl808WifiVendorTrace("high_power_profile done")
    bl808WifiVendorTrace("mpif_clk_init begin")
    mpif_clk_init()
    bl808WifiVendorTrace("mpif_clk_init done")
    bl808WifiVendorTrace("sysctrl_init begin")
    sysctrl_init()
    bl808WifiVendorTrace("sysctrl_init done")
    bl808WifiVendorTrace("intc_init begin")
    intc_init()
    bl808WifiVendorTrace("intc_init done")
    bl808WifiVendorTrace("ipc_emb_init begin")
    ipc_emb_init()
    bl808WifiVendorTrace("ipc_emb_init done")
    bl808WifiVendorClearEmbIpc()
    bl808WifiVendorClearHostIpc()
    bl808WifiVendorTrace("bl_init begin")
    bl_init()
    bl808WifiVendorTrace("bl_init done")
    bl808WifiVendorTrace("bl_pm_ops_register begin")
    bl_pm_ops_register()
    bl808WifiVendorTrace("bl_pm_ops_register done")
    regWrite32(BcnStatus + 4, 0x0024_f037'u32)
    regWrite32(BcnStatus, regRead32(BcnStatus) or 0x01)
    regWrite32(BcnStatus, regRead32(BcnStatus) and not 0x01'u32)
    regWrite32(BcnStatus, 0x68)
    regWrite32(BcnStatus, regRead32(BcnStatus) or 0x01)
    regWrite32(BcnStatus, regRead32(BcnStatus) and not 0x20'u32)
    regWrite32(CoexCtrl, 0x5010_001f'u32)
    fwStarted = true

  proc vendorPollOnce() =
    if fwStarted:
      bl808WifiVendorPollEmbEvents()
      bl808WifiVendorPollMacIrq()
      bl808WifiVendorDriveRfStatus()
      if bl808WifiVendorHostIpcStatus() != 0:
        inc ipcPollIrqCount
        bl_irq_handler()
      bl_sleep_schedule()
      if ke_env[0] == 0:
        ipc_emb_wait()
      ke_evt_schedule()
    if hostPollEnabled and loadPtr(wifiHwRaw(), 48) != nil:
      bl_main_event_handle(0, nil)

  proc vendorPollFor(iterations: uint32) =
    var i = iterations
    while i != 0:
      dec i
      vendorPollOnce()
      delayMtimeUs(100)

  proc bl808_wifi_vendor_poll*(iterations: cuint) {.exportc, cdecl.} =
    vendorPollFor(if iterations == 0: 1'u32 else: iterations.uint32)
  proc bl808_wifi_vendor_connected*(): cint {.exportc, cdecl.} =
    if connectDone == 0: 1 else: 0
  proc bl808_wifi_vendor_connect_done*(): cint {.exportc, cdecl.} =
    if connectDone >= 0: 1 else: 0
  proc bl808_wifi_vendor_disconnect_done*(): cint {.exportc, cdecl.} =
    if disconnectDone != 0: 1 else: 0
  proc bl808_wifi_vendor_last_status*(): cint {.exportc, cdecl.} = lastStatusCode.cint
  proc bl808_wifi_vendor_last_reason*(): cint {.exportc, cdecl.} = lastReasonCode.cint
  proc bl808_wifi_vendor_scan_count*(): uint32 {.exportc, cdecl.} = scanItemCount
  proc bl808_wifi_vendor_scan_done_count*(): uint32 {.exportc, cdecl.} = scanDoneCount
  proc bl808_wifi_vendor_mac_irq_count*(): uint32 {.exportc, cdecl.} = macIrqCount
  proc bl808_wifi_vendor_mac_poll_irq_count*(): uint32 {.exportc, cdecl.} = macPollIrqCount
  proc bl808_wifi_vendor_mac_trap_irq_count*(): uint32 {.exportc, cdecl.} = macTrapIrqCount
  proc bl808_wifi_vendor_ipc_trap_irq_count*(): uint32 {.exportc, cdecl.} = ipcTrapIrqCount
  proc bl808_wifi_vendor_ipc_poll_irq_count*(): uint32 {.exportc, cdecl.} = ipcPollIrqCount

  proc bl_wifi_clock_enable*(): cint {.exportc, cdecl.} =
    bl808WifiVendorPrepareWirelessDomain()
    let reg = GlbBase + 0x3b0'u32
    regWrite32(reg, (regRead32(reg) and not 0x0f'u32) or 1)
    0

  proc bl_wifi_enable_irq*(): cint {.exportc, cdecl.} =
    bl808_register_trap_handler(Bl808IrqWifi, bl808WifiVendorMacIrqTrampoline)
    bl808_register_trap_handler(Bl808IrqWifiIpcPublic, bl808WifiVendorIpcIrqTrampoline)
    bl808_enable_peripheral_irq(Bl808IrqWifi, 1)
    bl808_enable_peripheral_irq(Bl808IrqWifiIpcPublic, 1)
    0

  proc bl_wifi_mac_addr_get*(mac: ptr uint8): cint {.exportc, cdecl.} =
    let fallback = [0x18'u8, 0xB9'u8, 0x05'u8, 0x00'u8, 0x00'u8, 0x01'u8]
    if mac != nil:
      copyMem(mac, unsafeAddr fallback[0], 6)
    0

  proc netifapi_netif_add*(netif: ptr Netif; ipaddr, netmask, gw: ptr Ip4Addr;
                           state: pointer; init: NetifInitFn; input: NetifInputFn): int8 {.exportc, cdecl.} =
    discard ipaddr; discard netmask; discard gw
    if netif == nil: return -1
    storePtr(cast[pointer](netif), NetifStateOff, state)
    storePtr(cast[pointer](netif), NetifInputOff, cast[pointer](input))
    if init != nil: init(netif) else: 0
  proc netifapi_netif_common*(netif: ptr Netif; voidfunc: NetifVoidFn; errtfunc: NetifErrFn): int8 {.exportc, cdecl.} =
    if voidfunc != nil: voidfunc(netif)
    if errtfunc != nil: errtfunc(netif) else: 0
  proc netifapi_netif_set_addr*(netif: ptr Netif; ipaddr, netmask, gw: ptr Ip4Addr): int8 {.exportc, cdecl.} =
    if netif == nil: return -1
    if ipaddr != nil: storeU32(cast[pointer](netif), NetifIpOff, loadU32(cast[pointer](ipaddr), 0))
    if netmask != nil: storeU32(cast[pointer](netif), NetifNetmaskOff, loadU32(cast[pointer](netmask), 0))
    if gw != nil: storeU32(cast[pointer](netif), NetifGwOff, loadU32(cast[pointer](gw), 0))
    0
  proc netif_set_default*(netif: ptr Netif) {.exportc, cdecl.} = discard netif
  proc netifapi_netif_set_default*(netif: ptr Netif) {.exportc, cdecl.} = netif_set_default(netif)
  proc netif_set_up*(netif: ptr Netif) {.exportc, cdecl.} =
    if netif != nil: storeU8(cast[pointer](netif), NetifFlagsOff, loadU8(cast[pointer](netif), NetifFlagsOff) or NetifFlagUp)
  proc netifapi_netif_set_up*(netif: ptr Netif) {.exportc, cdecl.} = netif_set_up(netif)
  proc netif_set_link_up*(netif: ptr Netif) {.exportc, cdecl.} =
    if netif != nil: storeU8(cast[pointer](netif), NetifFlagsOff, loadU8(cast[pointer](netif), NetifFlagsOff) or NetifFlagLinkUp)
  proc netif_set_link_down*(netif: ptr Netif) {.exportc, cdecl.} =
    if netif != nil: storeU8(cast[pointer](netif), NetifFlagsOff, loadU8(cast[pointer](netif), NetifFlagsOff) and not NetifFlagLinkUp)
  proc netifapi_netif_set_link_up*(netif: ptr Netif) {.exportc, cdecl.} = netif_set_link_up(netif)
  proc netifapi_netif_set_link_down*(netif: ptr Netif) {.exportc, cdecl.} = netif_set_link_down(netif)
  proc netif_set_status_callback*(netif: ptr Netif; cb: NetifVoidFn) {.exportc, cdecl.} =
    if netif != nil: storePtr(cast[pointer](netif), NetifStatusCbOff, cast[pointer](cb))
  proc tcpip_input*(p: ptr Pbuf; inp: ptr Netif): int8 {.exportc, cdecl.} =
    discard inp
    discard pbuf_free(p)
    0
  proc etharp_output*(netif: ptr Netif; q: ptr Pbuf; ipaddr: ptr Ip4Addr): int8 {.exportc, cdecl.} =
    discard netif; discard q; discard ipaddr; 0
  {.emit: """
#include <lwip/ip4_addr.h>
u32_t ipaddr_addr(const char *cp) { (void)cp; return 0; }
char *ip4addr_ntoa(const ip4_addr_t *addr) { (void)addr; return "0.0.0.0"; }
unsigned long inet_addr(const char *cp) { return ipaddr_addr(cp); }
""".}

  proc pbuf_alloc*(layer: PbufLayer; length: uint16; ptype: PbufType): ptr Pbuf {.exportc, cdecl.} =
    discard layer; discard ptype
    let mem = c_calloc(1, PbufSize.csize_t + length.csize_t)
    if mem == nil: return nil
    storePtr(mem, PbufPayloadOff, ptrAt(mem, PbufSize))
    storeU16(mem, PbufLenOff, length)
    storeU16(mem, PbufTotLenOff, length)
    storeU16(mem, PbufRefOff, 1)
    cast[ptr Pbuf](mem)
  proc pbuf_alloced_custom*(layer: PbufLayer; length: uint16; ptype: PbufType; p: ptr PbufCustom;
                            payloadMem: pointer; payloadMemLen: uint16): ptr Pbuf {.exportc, cdecl.} =
    discard layer; discard ptype; discard payloadMemLen
    if p == nil: return nil
    zero(cast[pointer](p), PbufSize)
    storePtr(cast[pointer](p), PbufPayloadOff, payloadMem)
    storeU16(cast[pointer](p), PbufLenOff, length)
    storeU16(cast[pointer](p), PbufTotLenOff, length)
    storeU16(cast[pointer](p), PbufRefOff, 1)
    cast[ptr Pbuf](p)
  proc pbuf_free*(p: ptr Pbuf): uint8 {.exportc, cdecl.} =
    var cur = cast[pointer](p)
    while cur != nil:
      let next = loadPtr(cur, PbufNextOff)
      if (loadU8(cur, PbufFlagsOff) and PbufFlagIsCustom) != 0:
        let fn = cast[PbufFreeFn](loadPtr(cur, PbufCustomFreeOff))
        if fn != nil: fn(cast[ptr Pbuf](cur))
      else:
        c_free(cur)
      cur = next
    1
  proc pbuf_ref*(p: ptr Pbuf) {.exportc, cdecl.} =
    if p != nil: storeU16(cast[pointer](p), PbufRefOff, loadU16(cast[pointer](p), PbufRefOff) + 1)
  proc pbufTakeImpl(buf: ptr Pbuf; dataptr: pointer; length: uint16): int8 {.exportc: "bl808_nim_pbuf_take_impl", cdecl.} =
    if buf == nil or dataptr == nil or loadPtr(cast[pointer](buf), PbufPayloadOff) == nil or length > loadU16(cast[pointer](buf), PbufLenOff):
      return -1
    copyMem(loadPtr(cast[pointer](buf), PbufPayloadOff), dataptr, length.uint)
    0
  {.emit: """
#include <lwip/pbuf.h>
err_t pbuf_take(struct pbuf *buf, const void *dataptr, u16_t len) {
  return bl808_nim_pbuf_take_impl(buf, (void *)dataptr, len);
}
""".}
  proc pbuf_cat*(head, tail: ptr Pbuf) {.exportc, cdecl.} =
    if head == nil: return
    var p = cast[pointer](head)
    while loadPtr(p, PbufNextOff) != nil: p = loadPtr(p, PbufNextOff)
    storePtr(p, PbufNextOff, cast[pointer](tail))
    if tail != nil:
      storeU16(cast[pointer](head), PbufTotLenOff, loadU16(cast[pointer](head), PbufTotLenOff) + loadU16(cast[pointer](tail), PbufTotLenOff))
  proc pbuf_header*(p: ptr Pbuf; inc: int16): uint8 {.exportc, cdecl.} =
    if p == nil: return 1
    let raw = cast[pointer](p)
    let payload = cast[uint](loadPtr(raw, PbufPayloadOff))
    let nextPayload =
      if inc >= 0:
        cast[pointer](payload - inc.uint)
      else:
        cast[pointer](payload + uint(-inc))
    storePtr(raw, PbufPayloadOff, nextPayload)
    storeU16(raw, PbufLenOff, uint16(loadU16(raw, PbufLenOff).int + inc.int))
    storeU16(raw, PbufTotLenOff, uint16(loadU16(raw, PbufTotLenOff).int + inc.int))
    0

  proc aos_post_event*(`type`: uint16; code: uint16; value: culong): cint {.exportc, cdecl.} = discard `type`; discard code; discard value; 0
  proc aos_register_event_filter*(`type`: uint16; cb, privateData: pointer): cint {.exportc, cdecl.} = discard `type`; discard cb; discard privateData; 0
  proc aos_post_delayed_action*(ms: cint; action, arg: pointer): cint {.exportc, cdecl.} = discard ms; discard action; discard arg; 0
  proc bl_pm_init*(): cint {.exportc, cdecl.} = 0
  proc bl_pm_deinit*(): cint {.exportc, cdecl.} = 0
  proc bl_pm_state_run*(): cint {.exportc, cdecl.} = 0
  proc bl_pm_capacity_set*(level: PmLevel): cint {.exportc, cdecl.} = discard level; 0
  proc bl_pm_event_register*(event: PmEvent; code, capBit: uint32; priority: uint16; ops: PmCb; arg: pointer; enable: PmEventAble): cint {.exportc, cdecl.} =
    discard event; discard code; discard capBit; discard priority; discard arg; discard enable
    if ops != nil: discard
    0
  proc bl_pm_event_switch*(event: PmEvent; code: uint32; enable: PmEventAble): cint {.exportc, cdecl.} = discard event; discard code; discard enable; 0
  proc pm_post_event*(event: PmEvent; code: uint32; retval: ptr uint32): cint {.exportc, cdecl.} =
    discard event; discard code
    if retval != nil: retval[] = 0
    0

  type OsTime {.bycopy.} = object
    sec: clong
    usec: clong
  proc os_sleep*(sec: clong; usec: clong) {.exportc, cdecl.} =
    var ms = sec * 1000 + usec div 1000
    if ms <= 0: ms = 1
    discard osMsleep(ms)
  proc os_get_time*(t: ptr OsTime): cint {.exportc, cdecl.} =
    if t == nil: return -1
    let ms = osGetTimeMs()
    t.sec = clong(ms div 1000)
    t.usec = clong((ms mod 1000) * 1000)
    0
  proc vendorRandomU32(): uint32 =
    var x = vendorRandomState
    x = x xor (x shl 13)
    x = x xor (x shr 17)
    x = x xor (x shl 5)
    vendorRandomState = if x != 0: x else: 0x6d2b_79f5'u32
    vendorRandomState
  proc os_random*(): culong {.exportc, cdecl.} = vendorRandomU32().culong
  proc os_get_random*(buf: ptr uint8; length: csize_t): cint {.exportc, cdecl.} =
    if buf == nil: return -1
    for i in 0 ..< length.int:
      if (i and 3) == 0: discard vendorRandomU32()
      cast[ptr uint8](ptrAt(buf, i.uint))[] = uint8(vendorRandomState shr ((i and 3) * 8))
    0

  proc wpa_supplicant_malloc*(size: csize_t): pointer {.exportc, cdecl.} = c_malloc(size)
  proc wpa_supplicant_realloc*(p: pointer; size: csize_t): pointer {.exportc, cdecl.} = c_realloc(p, size)
  proc wpa_supplicant_zalloc*(nmemb, size: csize_t): pointer {.exportc, cdecl.} = c_calloc(nmemb, size)
  proc wpa_supplicant_free*(p: pointer) {.exportc, cdecl.} = c_free(p)
  proc wpa_supplicant_bzero*(s: pointer; n: csize_t) {.exportc, cdecl.} = zero(s, n.uint)
  proc pvPortMalloc*(size: csize_t): pointer {.exportc, cdecl.} = c_malloc(size)
  proc pvPortRealloc*(p: pointer; size: csize_t): pointer {.exportc, cdecl.} = c_realloc(p, size)
  proc pvPortCalloc*(count, size: csize_t): pointer {.exportc, cdecl.} = c_calloc(count, size)
  proc vPortFree*(p: pointer) {.exportc, cdecl.} = c_free(p)
  proc vTaskDelay*(ticks: uint32) {.exportc, cdecl.} = discard osMsleep(clong(if ticks != 0: ticks else: 1))
  proc xTaskGetTickCount*(): uint32 {.exportc, cdecl.} = osGetTick()
  proc assertFunc*(file: cstring; line: cint; fn: cstring; expr: cstring) {.exportc: "__assert_func", cdecl.} = osAssert(file, line, fn, expr)

  proc utils_bin2hex*(dst: cstring; src: pointer; srcLen: csize_t) {.exportc, cdecl.} =
    const hex = "0123456789abcdef"
    let input = cast[ptr UncheckedArray[uint8]](src)
    let outp = cast[ptr UncheckedArray[char]](dst)
    for i in 0 ..< srcLen.int:
      outp[i * 2] = hex[int(input[i] shr 4)]
      outp[i * 2 + 1] = hex[int(input[i] and 15)]
    outp[srcLen.int * 2] = '\0'
  proc utils_tlv_bl_unpack_auto*(buf: ptr uint32; bufSz: cint; typ: uint16; arg1: pointer): cint {.exportc, cdecl.} =
    discard buf; discard bufSz; discard typ; discard arg1; 0
  proc utils_tlv_bl_pack_auto*(buf: ptr uint32; bufSz: cint; typ: uint16; arg1: pointer): cint {.exportc, cdecl.} =
    discard buf; discard bufSz; discard typ; discard arg1; 0
  proc utils_crc32_stream_init*(ctx: pointer) {.exportc, cdecl.} = zero(ctx, 4)
  proc utils_crc32_stream_feed_block*(ctx: pointer; data: ptr uint8; length: uint32) {.exportc, cdecl.} =
    var crc = cast[ptr uint32](ctx)
    for i in 0'u32 ..< length:
      crc[] = (crc[] shl 5) xor (crc[] shr 27) xor cast[ptr uint8](ptrAt(data, i.uint))[]
  proc utils_crc32_stream_results*(ctx: pointer): uint32 {.exportc, cdecl.} = cast[ptr uint32](ctx)[]

  proc utils_list_init*(list: ptr UtilsList) {.exportc, cdecl.} =
    let raw = cast[pointer](list)
    storePtr(raw, 0, nil)
    storePtr(raw, 4, nil)
  proc utils_list_push_back*(list: ptr UtilsList; hdr: ptr UtilsListHdr) {.exportc, cdecl.} =
    let listRaw = cast[pointer](list)
    let hdrRaw = cast[pointer](hdr)
    storePtr(hdrRaw, 0, nil)
    let last = loadPtr(listRaw, 4)
    if last != nil: storePtr(last, 0, hdrRaw) else: storePtr(listRaw, 0, hdrRaw)
    storePtr(listRaw, 4, hdrRaw)
  proc utils_list_push_front*(list: ptr UtilsList; hdr: ptr UtilsListHdr) {.exportc, cdecl.} =
    let listRaw = cast[pointer](list)
    let hdrRaw = cast[pointer](hdr)
    storePtr(hdrRaw, 0, loadPtr(listRaw, 0))
    storePtr(listRaw, 0, hdrRaw)
    if loadPtr(listRaw, 4) == nil: storePtr(listRaw, 4, hdrRaw)
  proc utils_list_pop_front*(list: ptr UtilsList): ptr UtilsListHdr {.exportc, cdecl.} =
    let listRaw = cast[pointer](list)
    result = cast[ptr UtilsListHdr](loadPtr(listRaw, 0))
    if result != nil:
      let resultRaw = cast[pointer](result)
      storePtr(listRaw, 0, loadPtr(resultRaw, 0))
      if loadPtr(listRaw, 0) == nil: storePtr(listRaw, 4, nil)
      storePtr(resultRaw, 0, nil)
  proc utils_list_remove*(list: ptr UtilsList; prev, element: ptr UtilsListHdr) {.exportc, cdecl.} =
    let listRaw = cast[pointer](list)
    let prevRaw = cast[pointer](prev)
    let elementRaw = cast[pointer](element)
    if element == nil: return
    if prev != nil: storePtr(prevRaw, 0, loadPtr(elementRaw, 0))
    elif loadPtr(listRaw, 0) == elementRaw: storePtr(listRaw, 0, loadPtr(elementRaw, 0))
    else: return
    if loadPtr(listRaw, 4) == elementRaw: storePtr(listRaw, 4, prevRaw)
    storePtr(elementRaw, 0, nil)
  proc utils_list_extract*(list: ptr UtilsList; hdr: ptr UtilsListHdr) {.exportc, cdecl.} =
    let listRaw = cast[pointer](list)
    let hdrRaw = cast[pointer](hdr)
    var prev: pointer
    var cur = loadPtr(listRaw, 0)
    while cur != nil:
      if cur == hdrRaw:
        utils_list_remove(list, cast[ptr UtilsListHdr](prev), cast[ptr UtilsListHdr](cur))
        return
      prev = cur
      cur = loadPtr(cur, 0)
  proc utils_list_find*(list: ptr UtilsList; hdr: ptr UtilsListHdr): cint {.exportc, cdecl.} =
    let listRaw = cast[pointer](list)
    let hdrRaw = cast[pointer](hdr)
    var cur = loadPtr(listRaw, 0)
    while cur != nil:
      if cur == hdrRaw: return 1
      cur = loadPtr(cur, 0)
    0
  proc utils_list_insert*(list: ptr UtilsList; element: ptr UtilsListHdr; cmp: UtilsListCmp) {.exportc, cdecl.} =
    let listRaw = cast[pointer](list)
    let elementRaw = cast[pointer](element)
    var prev: pointer
    var cur = loadPtr(listRaw, 0)
    while cur != nil and cmp != nil and
        cmp(cast[ptr ConstUtilsListHdr](element), cast[ptr ConstUtilsListHdr](cur)) == 0:
      prev = cur
      cur = loadPtr(cur, 0)
    if prev != nil:
      storePtr(elementRaw, 0, cur)
      storePtr(prev, 0, elementRaw)
      if cur == nil:
        storePtr(listRaw, 4, elementRaw)
    else:
      utils_list_push_front(list, element)
  proc utils_list_insert_after*(list: ptr UtilsList; prevElement, element: ptr UtilsListHdr) {.exportc, cdecl.} =
    if prevElement == nil:
      utils_list_push_front(list, element)
    elif utils_list_find(list, prevElement) != 0:
      let listRaw = cast[pointer](list)
      let prevRaw = cast[pointer](prevElement)
      let elementRaw = cast[pointer](element)
      storePtr(elementRaw, 0, loadPtr(prevRaw, 0))
      storePtr(prevRaw, 0, elementRaw)
      if loadPtr(listRaw, 4) == prevRaw: storePtr(listRaw, 4, elementRaw)
  proc utils_list_insert_before*(list: ptr UtilsList; nextElement, element: ptr UtilsListHdr) {.exportc, cdecl.} =
    let listRaw = cast[pointer](list)
    let nextRaw = cast[pointer](nextElement)
    let elementRaw = cast[pointer](element)
    var prev: pointer
    var cur = loadPtr(listRaw, 0)
    while cur != nil:
      if cur == nextRaw:
        if prev != nil:
          storePtr(elementRaw, 0, cur)
          storePtr(prev, 0, elementRaw)
        else:
          utils_list_push_front(list, element)
        return
      prev = cur
      cur = loadPtr(cur, 0)
  proc utils_list_concat*(list1, list2: ptr UtilsList) {.exportc, cdecl.} =
    let list1Raw = cast[pointer](list1)
    let list2Raw = cast[pointer](list2)
    if loadPtr(list2Raw, 0) == nil: return
    if loadPtr(list1Raw, 4) != nil: storePtr(loadPtr(list1Raw, 4), 0, loadPtr(list2Raw, 0))
    else: storePtr(list1Raw, 0, loadPtr(list2Raw, 0))
    storePtr(list1Raw, 4, loadPtr(list2Raw, 4))
    utils_list_init(list2)
  proc utils_list_cnt*(list: ptr ConstUtilsList): cuint {.exportc, cdecl.} =
    var cur = loadPtr(cast[pointer](list), 0)
    while cur != nil:
      inc result
      cur = loadPtr(cur, 0)
  proc utils_list_pool_init*(list: ptr UtilsList; pool: pointer; elmtSize: csize_t; elmtCnt: cuint; defaultValue: pointer) {.exportc, cdecl.} =
    utils_list_init(list)
    var cur = pool
    for _ in 0'u32 ..< elmtCnt.uint32:
      if defaultValue != nil: copyMem(cur, defaultValue, elmtSize.uint) else: zero(cur, elmtSize.uint)
      utils_list_push_back(list, cast[ptr UtilsListHdr](cur))
      cur = ptrAt(cur, elmtSize.uint)

  proc connectCb(env, ind: pointer) {.cdecl.} =
    discard env
    lastStatusCode = loadU16(ind, WifiConnStatusOff).int32
    lastReasonCode = loadU16(ind, WifiConnReasonOff).int32
    connectDone = lastStatusCode
    let stat = ptrAt(mgmrRaw(), MgmrStatInfoOff)
    storeU16(stat, StatStatusOff, lastStatusCode.uint16)
    storeU16(stat, StatReasonOff, lastReasonCode.uint16)
  proc disconnectCb(env, ind: pointer) {.cdecl.} =
    discard env
    disconnectDone = 1
    connectDone = -1
    if ind != nil:
      lastStatusCode = loadU16(ind, WifiDiscStatusOff).int32
      lastReasonCode = loadU16(ind, WifiDiscReasonOff).int32
  proc beaconCb(env, ind: pointer) {.cdecl.} =
    discard env
    scanDiagStore(ind)
    inc scanItemCount
    vendorPutsRaw("[WIFI] scan item ch=")
    vendorPrintU32(if ind != nil: loadU8(ind, WifiBeaconChannelOff).uint32 else: 0, 10)
    vendorPutsRaw(" rssi=")
    if ind != nil and loadI8(ind, WifiBeaconRssiOff) < 0:
      vendorPutsRaw("-")
      vendorPrintU32(uint32(-loadI8(ind, WifiBeaconRssiOff).int), 10)
    else:
      vendorPrintU32(if ind != nil: loadI8(ind, WifiBeaconRssiOff).uint32 else: 0, 10)
    vendorPutsRaw("\r\n")
  proc eventCb(env, event: pointer) {.cdecl.} =
    discard env
    if event != nil and loadU32(event, 0) == WifiEventScanDone:
      inc scanDoneCount
      vendorPutsRaw("[WIFI] scan done\r\n")

  proc bl808_wifi_vendor_init*(conf: ptr WifiConf): cint {.exportc, cdecl.} =
    var local: array[8, uint8]
    if wifiStarted: return 0
    setupBlOps()
    setupHosal()
    zero(mgmrRaw(), sizeof(WifiMgmr).uint)
    zero(addr local[0], local.len.uint)
    local[0] = 'U'.uint8
    local[1] = 'S'.uint8
    if conf != nil and loadU8(conf, WifiConfCountryOff) != 0:
      local[0] = loadU8(conf, WifiConfCountryOff)
      local[1] = if loadU8(conf, WifiConfCountryOff + 1) != 0: loadU8(conf, WifiConfCountryOff + 1) else: 'S'.uint8
    bl808WifiVendorFwStart()
    hostPollEnabled = true
    result = bl606a0_wifi_init(cast[ptr WifiConf](addr local[0]))
    if result == 0:
      let phy = bl_main_phy_up()
      if phy != 0: result = phy
      vendorPollFor(2000)
    wifiStarted = result == 0
    storeU8(mgmrRaw(), MgmrReadyOff, 1)
    storeU16(mgmrRaw(), MgmrApBcnIntOff, 100)
    storeI32(mgmrRaw(), MgmrApInfoTtlOff, -1)
    storeI32(mgmrRaw(), MgmrScanItemTimeoutOff, WifiMgmrConfigScanItemTimeout)
    storePtr(mgmrRaw(), MgmrScanItemsLockOff, osMutexCreate())
    let stat = ptrAt(mgmrRaw(), MgmrStatInfoOff)
    storePtr(stat, StatDiagnoseLockOff, osMutexCreate())
    storePtr(stat, StatDiagnoseGetLockOff, osMutexCreate())
    discard bl_rx_sm_connect_ind_cb_register(nil, connectCb)
    discard bl_rx_sm_disconnect_ind_cb_register(nil, disconnectCb)
    discard bl_rx_beacon_ind_cb_register(nil, beaconCb)
    discard bl_rx_event_register(nil, eventCb)

  proc wifi_mgmr_sta_enable*(): pointer {.exportc, cdecl.} =
    if not wifiStarted: return nil
    if staEnabled: return staIface()
    let iface = staIface()
    let nif = ifaceNetif(iface)
    var zeroIp: uint32
    var mac: array[6, uint8]
    storeI32(iface, WifiIfaceModeOff, 0)
    discard bl_wifi_mac_addr_get(addr mac[0])
    copyMem(ptrAt(iface, WifiIfaceMacOff), addr mac[0], 6)
    copyMem(ptrAt(nif, NetifHwaddrOff), addr mac[0], 6)
    discard netifapi_netif_add(cast[ptr Netif](nif), cast[ptr Ip4Addr](addr zeroIp), cast[ptr Ip4Addr](addr zeroIp), cast[ptr Ip4Addr](addr zeroIp),
                               nil, bl606a0_wifi_netif_init, tcpip_input)
    storeU8(nif, NetifNameOff, 's'.uint8)
    storeU8(nif, NetifNameOff + 1, 't'.uint8)
    netif_set_default(cast[ptr Netif](nif))
    netif_set_up(cast[ptr Netif](nif))
    var addIfCfm: array[MmAddIfCfmSize.int, uint8]
    for _ in 0 ..< 20:
      zero(addr addIfCfm[0], MmAddIfCfmSize)
      let rc = bl_send_add_if(cast[ptr BlHw](addr wifi_hw), netifHwaddr(nif),
                              Nl80211IftypeStation, false, addr addIfCfm[0])
      if rc == 0 and loadU8(addr addIfCfm[0], MmAddIfStatusOff) == CoOk.uint8:
        let vif = vifAt(BlVifSta)
        let inst = loadU8(addr addIfCfm[0], MmAddIfInstNbrOff)
        storeU8(vif, BlVifVifIdxOff, inst)
        storePtr(vif, BlVifDevOff, nif)
        storeU8(vif, BlVifUpOff, 1)
        storeU8(vif, BlVifLinksNumOff, 0)
        storeU8(iface, WifiIfaceVifIndexOff, BlVifSta.uint8)
        staEnabled = true
        vendorPollFor(2000)
        return iface
      vendorPollFor(4000)
    nil

  proc wifi_mgmr_sta_netif_get*(): ptr Netif {.exportc, cdecl.} = cast[ptr Netif](ifaceNetif(staIface()))
  proc wifi_mgmr_ap_netif_get*(): ptr Netif {.exportc, cdecl.} = cast[ptr Netif](ifaceNetif(apIface()))

  proc wifi_mgmr_scan*(data: pointer; cb: ScanCompleteCb): cint {.exportc, cdecl.} =
    discard data
    if cb != nil: discard
    if not staEnabled: return -1
    var bssid: array[6, uint8]
    for i in 0 ..< 6: bssid[i] = 0xff
    scanDoneCount = 0
    scanItemCount = 0
    scanDiagReset()
    result = bl_main_scan(cast[ptr Netif](ifaceNetif(staIface())), nil, 0, cast[ptr MacAddr](addr bssid[0]), nil, ScanActive, 120000)
    vendorPutsRaw("[WIFI] scan start rc=")
    if result < 0:
      vendorPutsRaw("-")
      vendorPrintU32(uint32(-result), 10)
    else:
      vendorPrintU32(result.uint32, 10)
    vendorPutsRaw("\r\n")

  proc wifi_mgmr_sta_connect*(iface: ptr pointer; ssid, psk, pmk: cstring; mac: ptr uint8;
                              band: uint8; chanId: uint8): cint {.exportc, cdecl.} =
    discard iface
    if not staEnabled or ssid == nil: return -1
    let ssidLen = c_strlen(ssid)
    let pskLen = if psk != nil: c_strlen(psk) else: 0.csize_t
    let pmkLen = if pmk != nil: c_strlen(pmk) else: 0.csize_t
    let freq = wifiChannelToFreq(chanId)
    connectDone = -1
    lastStatusCode = -1
    disconnectDone = 0
    result = bl_main_connect(cast[ptr uint8](ssid), ssidLen.cint,
                             cast[ptr uint8](psk), pskLen.cint,
                             cast[ptr uint8](pmk), pmkLen.cint,
                             nil, 0, freq, WifiConnectDefault or WifiConnectPmfCapable)
    discard mac
    discard band

  proc wifi_mgmr_sta_disconnect*(): cint {.exportc, cdecl.} =
    if not staEnabled: return -1
    result = bl_main_disconnect()
    vendorPollFor(4000)

  proc wifi_mgmr_ap_start*(iface: ptr pointer; ssid: cstring; hiddenSsid: cint; passwd: cstring; channel: cint): cint {.exportc, cdecl.} =
    discard iface
    if not staEnabled or ssid == nil or channel <= 0: return -1
    result = bl_main_apm_start(ssid, passwd, channel, hiddenSsid.uint8, loadU16(mgmrRaw(), MgmrApBcnIntOff))
    apEnabled = result == 0

  proc wifi_mgmr_ap_stop*(iface: ptr pointer): cint {.exportc, cdecl.} =
    discard iface
    if not apEnabled: return -1
    apEnabled = false
    bl_main_apm_stop()

  proc wifi_mgmr_api_ip_update*(): cint {.exportc, cdecl.} = 0
  proc wifi_mgmr_api_ip_got*(): cint {.exportc, cdecl.} = 0
  proc wifi_mgmr_ext_dump_needed*(): cint {.exportc, cdecl.} = 0
  proc wifi_mgmr_scan_complete_notify*(): cint {.exportc, cdecl.} =
    inc scanDoneCount
    vendorPutsRaw("[WIFI] scan complete notify\r\n")
    0
  proc wifi_netif_dhcp_start*(netif: ptr Netif): cint {.exportc, cdecl.} = discard netif; 0
  proc wifi_netif_dhcp_stop*(netif: ptr Netif): cint {.exportc, cdecl.} = discard netif; 0
