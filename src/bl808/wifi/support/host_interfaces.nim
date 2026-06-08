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
proc ke_evt_set(events: uint32) {.importc, cdecl.}
proc wifi_main_poll_once() {.importc, cdecl.}
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
