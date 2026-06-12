proc sm_assoc_req_send_pre*(param: pointer) {.exportc, cdecl.}
proc sm_send_next_bss_param*(param: pointer) {.exportc, cdecl.}
proc me_build_capability*(param: pointer): uint16 {.exportc, cdecl.}
proc txl_frame_push_force*(param: pointer, ac: uint8) {.exportc, cdecl.}
proc txl_transmit_trigger*() {.exportc, cdecl.}
proc txl_cntrl_clear_ac*(ac: uint8) {.exportc, cdecl.}
proc apm_send_next_bss_param*(param: pointer) {.exportc, cdecl.}
proc apm_embedded_enabled*(vifEntry: pointer): bool {.exportc, cdecl, noinline.}
proc me_add_ie_customer*(buf: pointer, ieData: pointer = nil,
                         length: uint32 = 0): uint32 {.exportc, cdecl.}
proc apm_bcn_set*(param: pointer) {.exportc, cdecl.}
proc vif_mgmt_get_first_ap_inf*(): pointer {.exportc, cdecl.}
proc sm_handle_connection*(vifIdxOrFlag: uint32, status: uint32, callbackCtx: pointer, failureFn: pointer) {.exportc, cdecl.}
proc sm_connect_ind*(statusCode: uint16, reasonCode: uint16) {.exportc, cdecl, noinline.}
proc sm_deauth_send*(param: pointer, reason: uint16) {.exportc, cdecl.}
proc sm_get_bss_params*(selectedBssResultOut: ptr pointer, selectedBssChannelOut: ptr pointer): bool {.exportc, cdecl.}
proc sm_scan_bss*(bssid: pointer, ssid: pointer, chanInfo: pointer) {.exportc, cdecl.}
proc sm_join_bss*(bssid: pointer, ssid: pointer, joinInfo: pointer, flag: uint32) {.exportc, cdecl.}
proc me_beacon_check*(vifIdx: uint8, frameDesc: pointer, iesBase: pointer) {.exportc, cdecl.}
proc rc_update_bw_nss_max*(staIdx: uint8, nss: uint8, groupCnt: uint8) {.exportc, cdecl.}
proc me_build_deauthenticate*(buf: pointer, reason: uint16): uint32 {.exportc, cdecl, noinline.}
proc me_build_beacon*(buf: pointer, vifIdx: uint8, lenOut: ptr uint16,
                     flagsOut: ptr uint8, hiddenSsid: uint8): uint32 {.exportc, cdecl.}
proc me_build_authenticate*(buf: pointer, authAlgo: uint16, authSeq: uint16,
    statusCode: uint16, challengeText: pointer): uint32 {.exportc, cdecl, noinline.}
proc me_build_associate_rsp_impl(buf: pointer, staEntry: pointer,
    statusCode: uint16, aid: uint16): uint32 {.exportc: "me_build_associate_rsp", cdecl.}
# Nim-side proc alias so existing callers that cast the function pointer still work:
proc me_build_associate_rsp*(buf: pointer, p1: pointer = nil, p2: uint16 = 0, p3: uint16 = 0): uint32 {.inline.} =
  me_build_associate_rsp_impl(buf, p1, p2, p3)
proc me_build_sae_authenticate*(buf: pointer, authAlgo: uint16, authSeq: uint16, statusCode: uint16, vifIdx: uint32): uint32 {.exportc, cdecl.}
proc me_build_probe_rsp*(buf: pointer, vifIdx: uint8,
    lenOut: ptr uint16): uint32 {.exportc, cdecl.}
proc vif_mgmt_entry_init*(vifEntry: pointer) {.exportc, cdecl.}
proc vif_mgmt_add_to_list*(vifEntry: pointer) {.exportc, cdecl.}
proc vif_mgmt_bcn_to_prog*(vifEntry: pointer) {.exportc, cdecl.}
proc vif_mgmt_bcn_to_evt*(vifEntry: pointer) {.exportc, cdecl.}

# Forward declarations for channel management helpers
proc chan_distribute_slots*() {.exportc, cdecl.}
proc chan_tbtt_insert*(tbttNode: pointer) {.exportc, cdecl.}
proc scanu_cached_scanresult_clear*() {.exportc, cdecl.}
proc chan_update_tx_power*(ctxt: pointer) {.exportc, cdecl.}
proc vif_mgmt_send_postponed_frame*(vifEntry: pointer) {.exportc, cdecl.}
proc rxl_timer_int_handler*() {.exportc, cdecl.}
proc rxl_cntrl_evt*() {.exportc, cdecl.}
proc scanu_scan_next*() {.exportc, cdecl.}
proc chan_tbtt_schedule*(tbttEntry: pointer) {.exportc, cdecl.}
proc chan_send_scanning_stop*(chanEnvPtr: pointer) {.exportc, cdecl.}
proc chan_upd_ctxt_status*(chanCtxtPtr: pointer, newStatus: uint8) {.exportc, cdecl.}
proc scan_send_cancel_cfm*(status: uint8) {.exportc, cdecl, noinline.}
proc chan_goto_idle_cb*() {.exportc, cdecl.}
proc chan_sta_tx_cfm*(param: pointer) {.exportc, cdecl.}
proc chan_ap_tx_cfm*(param: pointer) {.exportc, cdecl.}
proc chan_switch_start*(chanCtxt: pointer) {.exportc, cdecl.}
proc chan_get_next_chan*(): pointer {.exportc, cdecl.}
proc chan_conn_less_delay_prog*() {.exportc, cdecl.}
proc mm_force_idle_req*() {.exportc, cdecl.}
proc mm_back_to_host_idle*() {.exportc, cdecl.}
proc phy_mdm_isr*() {.exportc, cdecl.}
proc phy_rc_isr*() {.exportc, cdecl.}
proc intc_spurious*() {.exportc, cdecl.}

# Forward declarations for security/station management helpers called before definition
proc mm_sec_machwkey_del*(keyIdx: uint8) {.exportc, cdecl.}
proc mm_sec_machwaddr_del*(staIdx: uint8) {.exportc, cdecl.}
proc apm_tx_int_ps_clear*(vifEntry: pointer, staIdx: uint8) {.exportc, cdecl.}
proc vif_mgmt_del_key*(vifEntry: pointer, keySlot: uint8) {.exportc, cdecl, noinline.}
proc sta_mgmt_del_key*(staIdx: uint8, keyIdx: uint8) {.exportc, cdecl.}
proc apm_send_mlme*(vifEntry: pointer, frameType: uint16, destAddr: pointer, callback: pointer, callbackArg: pointer, extraParam: pointer) {.exportc, cdecl.}
proc apm_sta_add*(param: pointer): uint8 {.exportc, cdecl.}
proc apm_sta_fw_delete*(staIdx: uint8, vifIdx: uint8, reason: uint16) {.exportc, cdecl.}
proc bl_wifi_set_sta_key_internal*(vifIdx: uint8, staIdx: uint8, alg: uint32,
    keyIdx: int32, setTx: int32, seqData: pointer, seqLen: csize_t,
    keyData: pointer, keyLen: csize_t, pairwise: bool): cint {.exportc, cdecl.}
# Forward declarations for station/beacon management helpers
proc sta_mgmt_entry_init*(staEntry: pointer) {.exportc, cdecl.}
proc sta_mgmt_postponed_desc_release*(staEntry: pointer, flag: uint32): uint32 {.exportc, cdecl.}
proc sta_mgmt_aging_postponed_desc*(staEntry: pointer, maxCount: uint32): uint32 {.exportc, cdecl.}
proc sta_mgmt_send_postponed_frame*(vifEntry: pointer, staEntry: pointer, maxCount: uint32): uint32 {.exportc, cdecl.}
proc vif_mgmt_bcn_recv*(vifEntry: pointer) {.exportc, cdecl.}
proc ps_check_beacon*(rxHdr: pointer, unused: uint32, vifEntry: pointer) {.exportc, cdecl.}
proc mm_bcn_transmitted*(vifEntry: pointer) {.exportc, cdecl.}
proc mm_active*() {.exportc, cdecl.}
proc td_start*(vifIdx: uint8) {.exportc, cdecl.}
proc mm_bcn_init_vif*(vifEntry: pointer) {.exportc, cdecl.}
proc mm_hw_ap_info_set*(vifIdx: uint8) {.exportc, cdecl.}
proc mm_hw_info_set*(macAddr: pointer) {.exportc, cdecl.}
proc txl_cntrl_halt_ac*(ac: uint8) {.exportc, cdecl.}
proc txl_cntrl_flush_ac*(ac: uint8) {.exportc, cdecl.}
proc txl_cntrl_tx_check*(vifEntry: pointer): bool {.exportc, cdecl.}
proc rxl_reset*() {.exportc, cdecl.}
proc txl_reset*() {.exportc, cdecl.}
proc chan_tbtt_switch_update*(vifEntry: pointer, tbttTime: uint32) {.exportc, cdecl.}
proc chan_is_on_channel*(vifEntry: pointer): bool {.exportc, cdecl, noinline.}
proc chan_get_dominant_chan*(): pointer {.exportc, cdecl, noinline.}
proc chan_pre_switch_channel*(ctxt: pointer) {.exportc, cdecl.}
proc ps_check_tbtt*(vifEntry: pointer) {.exportc, cdecl.}
proc mm_bcn_transmit*(vifIdx: uint8) {.exportc, cdecl.}
proc chan_is_on_operational_channel*(vifEntry: pointer): bool {.exportc, cdecl, noinline.}
proc phy_get_channel_raw*(info: pointer, index: uint8)
    {.exportc: "phy_get_channel", cdecl.}
proc mm_rx_filter_set*() {.exportc, cdecl.}
proc apm_tx_int_ps_check*(txDesc: pointer): bool {.exportc, cdecl.}
proc apm_tx_int_ps_get_postpone*(vifEntry: pointer, staEntry: pointer, postponeFlag: ptr uint32): pointer {.exportc, cdecl.}
proc txl_frame_send_null_frame*(staIdx: uint8, cfmCallback: pointer, cfmArg: uint32): uint8 {.exportc, cdecl, discardable.}
proc txl_frame_send_qosnull_frame*(staIdx: uint8, qosCtrl: uint16,
  cfmCallback: pointer, cfmArg: uint32): uint8 {.exportc, cdecl, discardable.}
proc txl_frame_release*(param: pointer) {.exportc, cdecl.}
proc txl_int_fake_transfer*(txDesc: pointer, queueIdx: uint32) {.exportc, cdecl.}
proc txl_payload_handle_backup*(param: pointer) {.exportc, cdecl.}
proc txl_machdr_format*(param: pointer) {.exportc, cdecl.}
proc txu_cntrl_tkip_mic_append*(txdesc: pointer) {.exportc, cdecl.}
proc txl_frame_init_desc*(desc: pointer, linkDesc: pointer, hwDesc: pointer, payloadDesc: pointer) {.exportc, cdecl.}
proc txl_frame_cfm*(param: pointer) {.exportc, cdecl.}
proc txl_frame_evt*() {.exportc, cdecl.}
proc ps_check_tx_frame*(vifIdx: uint8, staIdx: uint8): bool {.exportc, cdecl.}

# Forward declarations for init sub-functions called from mm_init and others
proc ke_task_init*() {.exportc, cdecl.}
proc mm_env_init*() {.exportc, cdecl.}
proc mm_env_max_ampdu_duration_set*(duration: uint32) {.exportc, cdecl.}
proc vif_mgmt_init*() {.exportc, cdecl.}
proc td_init*() {.exportc, cdecl.}
proc ps_init*() {.exportc, cdecl.}
proc chan_init*() {.exportc, cdecl.}
proc scan_init*() {.exportc, cdecl.}
proc sta_mgmt_init*() {.exportc, cdecl.}
proc mm_bcn_init*() {.exportc, cdecl.}
proc mm_timer_init*() {.exportc, cdecl.}
proc mm_timer_set*(timer: pointer, targetTime: uint32) {.exportc, cdecl.}
proc mm_timer_clear*(timer: pointer) {.exportc, cdecl.}
proc mm_timer_schedule*() {.exportc, cdecl.}
proc txl_frame_init*() {.exportc, cdecl.}
proc txu_cntrl_cfm*(param: pointer) {.exportc, cdecl.}
proc ipc_emb_txcfm*(desc: pointer) {.exportc, cdecl.}
proc ipc_emb_txcfm_ind*(acBit: uint32 = 0) {.exportc, cdecl, noinline.}
proc txl_cntrl_init*() {.exportc, cdecl.}
proc txl_cntrl_env_dump*() {.exportc, cdecl, noinline.}
proc txl_frame_dump*() {.exportc, cdecl, noinline.}
proc rxl_hwdesc_dump*() {.exportc, cdecl, noinline.}
proc txl_cfm_dump*() {.exportc, cdecl, noinline.}
proc rxl_cntrl_dump*() {.exportc, cdecl, noinline.}
proc ipc_emb_dump*() {.exportc, cdecl, noinline.}
proc coex_dump_wifi*() {.exportc, cdecl.}
proc coex_dump_pta*() {.exportc, cdecl.}
proc bugkiller_fw_task_dump*() {.exportc, cdecl.}
proc puts_space*(buf: pointer, count: cint): pointer {.exportc: "_puts_space", cdecl, discardable.}
proc txl_cfm_init*() {.exportc, cdecl.}
proc txl_buffer_reinit*() {.exportc, cdecl.}
proc txl_hwdesc_reset*() {.exportc, cdecl, noinline.}
proc txl_buffer_init*() {.exportc, cdecl.}
proc txl_hwdesc_init*() {.exportc, cdecl, noinline.}
proc rxl_init*() {.exportc, cdecl.}
proc rxu_cntrl_init*() {.exportc, cdecl.}
proc hal_machw_init*() {.exportc, cdecl.}
proc hal_machw_reset*() {.exportc, cdecl.}
proc td_reset*(vifIdx: uint8) {.exportc, cdecl.}
# CRC utility functions (external, used by mm_check_beacon for beacon change detection)
proc utils_crc32_stream_init*(state: pointer) {.importc, cdecl.}
proc utils_crc32_stream_feed_block*(state: pointer, data: pointer, len: uint32) {.importc, cdecl.}
proc utils_crc32_stream_results*(state: pointer): uint32 {.importc, cdecl.}
# External host message handler (called by ke_msg_send for API tasks)
proc bl_rx_e2a_handler*(msgPtr: pointer) {.importc, cdecl.}
# Platform PM functions (external, called by bl_sleep_schedule)
proc wifi_hosal_pm_state_run*(): uint32 {.importc, cdecl.}
proc arch_delay_us*(us: uint32) {.importc, cdecl.}
proc nim_wifi_rf_latch_service_enable*(enable: uint32) {.importc, cdecl.}
proc wifi_hosal_pm_post_event*(typ: uint32, sev: uint32, resultPtr: pointer) {.importc, cdecl.}
proc utils_list_pop_front*(list: ptr CoList): ptr CoListHdr {.importc, cdecl.}
  ## External list pop (host-provided), used by ipc_emb_tx_evt instead of co_list_pop_front.
proc utils_list_push_back*(list: ptr CoList, elem: ptr CoListHdr) {.importc, cdecl.}
  ## External list push (host-provided), used by ipc_emb_txcfm instead of co_list_push_back.
# External IPC host function (called by bl_irq_handler to disable E2A IRQs)
proc ipc_host_disable_irq_e2a*() {.importc, cdecl.}
# External TRPC power control functions (called by bl_tpc_* wrappers)
proc trpc_power_get*(powerTable: pointer) {.exportc, cdecl.}
proc trpc_update_power*(powerTable: pointer) {.exportc, cdecl.}
proc trpc_update_power_11b*(powerTable: pointer) {.exportc, cdecl.}
proc trpc_update_power_11g*(powerTable: pointer) {.exportc, cdecl.}
proc trpc_update_power_11n*(powerTable: pointer) {.exportc, cdecl.}
proc phy_get_ntx*(): uint8 {.exportc, cdecl.}
proc phy_get_nss*(): uint8 {.exportc, cdecl.}
proc phy_ldpc_tx_supported*(): bool {.exportc, cdecl.}
proc phy_get_rf_gain_idx*(txPowerElem: pointer, rateParam: pointer)
    {.exportc, cdecl.}
proc rf_pri_input_xtalfreq(xtalfreqHz: uint32) {.exportc, cdecl.}
proc rf_pri_get_xtalfreq(): uint32 {.exportc, cdecl.}
proc rf_pri_xtalfreq() {.exportc, cdecl.}
proc rf_pri_init_calib_mem() {.exportc, cdecl.}
proc rf_pri_init(coldInit, mode: uint32) {.exportc, cdecl.}
proc rf_pri_config_mode(mode: uint32) {.exportc, cdecl.}
proc rf_pri_cfg_init() {.exportc, cdecl.}
proc rf_pri_input_device_info(deviceInfo: uint32) {.exportc, cdecl.}
proc rf_pri_input_chip_ver(chipVersion: uint32) {.exportc, cdecl.}
proc rf_pri_get_wl_cfg(): uint32 {.exportc, cdecl.}
proc rf_pri_get_txgain_max(): int32 {.exportc, cdecl.}
proc rf_pri_get_txgain_min(): int32 {.exportc, cdecl.}
proc rf_pri_roscal() {.exportc, cdecl.}
proc rf_pri_rccal() {.exportc, cdecl.}
proc rf_pri_manual_incremental_cal_start() {.exportc, cdecl.}
proc rf_pri_manual_incremental_cal_stop() {.exportc, cdecl.}
proc rf_pri_set_rcal_code(code0, code1: uint32) {.exportc, cdecl.}
proc rf_pri_save_state_before_cal() {.exportc, cdecl.}
proc rf_pri_restore_state_after_cal() {.exportc, cdecl.}
proc rf_pri_cw_start(targetPowerDbm: int32; channelMhz: uint32)
    {.exportc, cdecl.}
proc rf_pri_cw_stop() {.exportc, cdecl.}
proc rf_pri_lo_fcal() {.exportc, cdecl.}
proc rf_pri_lo_acal() {.exportc, cdecl.}
proc rf_pri_txcal() {.exportc, cdecl.}
proc rf_pri_bz_txcal() {.exportc, cdecl.}
proc rf_pri_rxcal() {.exportc, cdecl.}
proc rf_pri_full_cal() {.exportc, cdecl.}
proc rf_pri_restore_cal_reg() {.exportc, cdecl.}
proc rf_pri_update_param(channelMhz: uint32) {.exportc, cdecl.}
proc rf_pri_read(reg: ptr uint32): uint32 {.exportc, cdecl.}
proc rf_pri_optimize(channelMhz: uint32) {.exportc, cdecl.}
proc rf_pri_bz_optimize(channelMhz: uint32) {.exportc, cdecl.}
proc rf_pri_bz_optimize_restore() {.exportc, cdecl.}
proc rf_pri_input_channel_pwr_comp(comp: pointer) {.exportc, cdecl.}
proc rf_pri_input_channel_lp_pwr_comp(comp: pointer) {.exportc, cdecl.}
proc rf_pri_set_channel_lp_pwr_comp(channelIndex: uint32) {.exportc, cdecl.}
proc rf_pri_input_temp_comp_param(channels: pointer; highOffsets: pointer;
                                  lowOffsets: pointer; roomOffset: int16;
                                  enable: uint8) {.exportc, cdecl.}
proc rf_pri_set_temp_comp(sensorTemperatureC: int32) {.exportc, cdecl.}
proc rf_pri_input_bz_channel_pwr_comp(comp: pointer) {.exportc, cdecl.}
proc rf_pri_set_bz_channel_pwr_comp() {.exportc, cdecl.}
proc rf_pri_set_bz_temp_comp(sensorTemperatureC: int32) {.exportc, cdecl.}
proc rf_pri_get_bz_temp_mp_comp() {.exportc, cdecl.}
proc rf_pri_input_bz_target_power(targetPowerDbm: int32) {.exportc, cdecl.}
proc rf_pri_set_channel_pwr_comp(channelIndex: uint32) {.exportc, cdecl.}
proc rf_pri_set_bandwidth(bandwidthMhz: uint32) {.exportc, cdecl.}
proc rf_pri_get_vco_freq_cw(channelMhz: uint32): uint32 {.exportc, cdecl.}
proc rf_pri_get_vco_idac_cw(channelMhz: uint32): uint32 {.exportc, cdecl.}
proc rfc_config_bandwidth*(bandwidth: uint32) {.exportc, cdecl.}
proc rfc_config_channel*(channelMhz: uint32) {.exportc, cdecl.}
proc rfc_get_power_level*(rateClass: uint32; requestedPowerTenths: int32): uint32
    {.exportc, cdecl.}
proc rfc_power_meas*(clockSelect: uint32; offsetHz: int32;
                     sampleCount: uint32; measureFlags: uint32;
                     iOut, qOut: ptr int32) {.exportc, cdecl.}
proc rfc_sg_start*(frequencyHz: int32; amplitude: uint32;
                   signedQuadraturePath: uint32) {.exportc, cdecl.}
proc rfc_sg_stop*() {.exportc, cdecl.}
proc rfc_rf_fsm_force*(mode: uint32) {.exportc, cdecl.}
proc rfc_rc_fsm_force*(mode: uint32) {.exportc, cdecl.}
proc td_timer_evt*(env: pointer) {.exportc, cdecl.}
proc ps_uapsd_timer_handle*() {.exportc, cdecl.}
proc ps_tx_null_timer_handle*() {.exportc, cdecl.}
proc mm_ps_change_ind*(staIdx: uint8, psState: uint8) {.exportc, cdecl.}
proc ps_disable_cfm*(vifEntry: pointer, statusFlags: uint32) {.exportc, cdecl.}
  ## PS disable confirmation (sends MM_SET_PS_MODE_CFM).
  ## Forward declaration - implementation at PS section.
proc ps_enable_cfm*(vifEntry: pointer, status: uint32) {.exportc, cdecl.}
  ## PS enable confirmation. Forward declaration — impl at PS section.
proc ps_enable_cfm_handle*(vifEntry: pointer) {.exportc, cdecl, noinline.}
proc ps_disable_cfm_handle*(vifEntry: pointer): uint32 {.exportc, cdecl.}
proc sta_mgmt_add_key*(param: pointer, hwKeyIdx: uint8) {.exportc, cdecl.}
proc vif_mgmt_add_key*(param: pointer, hwKeyIdx: uint8) {.exportc, cdecl.}
proc replay_counter_validate*(param: pointer): bool {.exportc, cdecl.}
proc mm_tim_update_proceed*(param: pointer) {.exportc, cdecl, noinline.}
proc sm_disconnect*(param: pointer) {.exportc, cdecl.}
proc sm_issue_sa_query_request*() {.exportc, cdecl.}
proc coex_pta_force_autocontrol_set*(mode: uint32) {.exportc, cdecl.}
proc sm_delete_resources*(param: pointer = nil) {.exportc, cdecl.}
proc sm_auth_assoc_send_according_chan*(nextState: uint16 = 0, param1: uint16 = 0, param2: uint32 = 0) {.exportc, cdecl.}
proc apm_sta_delete*(param: pointer) {.exportc, cdecl.}
proc apm_tx_cfm_handler*(param: pointer) {.exportc, cdecl.}
proc cfm_raw_send*(param: pointer) {.exportc, cdecl.}
proc sm_supplicant_deauth_cfm*(param: pointer) {.exportc, cdecl.}
proc ps_check_frame*(rxHdr: pointer, frameFlags: uint32, vifEntry: pointer) {.exportc, cdecl.}
proc ps_send_pspoll*(vifEntry: pointer): uint8 {.exportc, cdecl, noinline.}
proc phy_set_channel*(channel: ptr ChanCtxtDefView, force: uint32)
    {.exportc, cdecl.}
  ## BL808 RF ABI: a0 points at the packed channel descriptor and a1 must
  ## be zero to apply it. Non-zero a1 returns without changing the PHY channel.

proc phySetChannel*(channel: ptr ChanCtxtDefView) {.inline.} =
  phy_set_channel(channel, 0'u32)

proc phySetChannel*(band: uint8, chanType: uint8, primFreq: uint16,
                    centerFreq1: uint16, centerFreq2: uint16,
                    txPower: uint8) {.inline.} =
  var channel = ChanCtxtDefView(
    band: band,
    chanType: chanType,
    primFreq: primFreq,
    centerFreq1: centerFreq1,
    centerFreq2: centerFreq2,
    txPower: txPower,
    phyEnvFlags: 0'u8)
  phySetChannel(addr channel)

proc packChannelMeta(channel: ptr ChanCtxtDefView): uint32 {.inline.} =
  channel.band.uint32 or
    (channel.chanType.uint32 shl 8) or
    (channel.txPower.uint8.uint32 shl 16)

proc packChannelFreq(channel: ptr ChanCtxtDefView): uint32 {.inline.} =
  channel.primFreq.uint32 or (channel.centerFreq1.uint32 shl 16)

proc snapshotPhyChannel(dst: var array[4, uint32]) {.inline.} =
  phy_get_channel_raw(cast[pointer](addr dst[0]), 0)
# External RF/PHY functions called from wifi_main (platform-provided)
proc phy_init*(cfg: pointer) {.exportc, cdecl.}
proc phy_get_version*(versionOut: pointer, buf: pointer) {.exportc, cdecl.}
proc wifi_hosal_rf_turn_on*() {.importc, cdecl.}
