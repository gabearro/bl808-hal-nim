proc tpc_update_tx_power*(vifIdx: uint8) {.exportc, cdecl.}
proc bl_tpc_power_table_get*(powerTable: ptr array[38, int8]) {.exportc, cdecl.}
proc bl_pwr_find*(levels: pointer, count: uint32): uint32 {.exportc, cdecl.}
proc ps_traffic_status_update*(vifIdx: uint8, status: uint32) {.exportc, cdecl.}
proc ps_dpsm_update*(enable: uint32) {.exportc, cdecl.}
proc chan_tbtt_switch_evt*() {.exportc, cdecl.}
proc chan_conn_less_delay_evt*() {.exportc, cdecl.}
proc chan_cde_evt*() {.exportc, cdecl.}
proc chan_ctxt_op_evt*() {.exportc, cdecl.}
proc chan_survey_timer_end*() {.exportc, cdecl.}
proc bam_init*() {.exportc, cdecl.}
proc bl_reset_evt*() {.exportc, cdecl.}
proc ke_task_schedule*() {.exportc, cdecl.}
proc ke_timer_schedule*() {.exportc, cdecl.}
proc ipc_emb_msg_evt*() {.exportc, cdecl.}
proc mm_hw_idle_evt*() {.exportc, cdecl.}
proc mm_tbtt_evt*() {.exportc, cdecl.}
proc rxu_swdesc_upload_evt*() {.exportc, cdecl.}
proc rxl_dma_evt*() {.exportc, cdecl.}
proc rxu_cntrl_evt*() {.exportc, cdecl.}
proc txl_cfm_evt*() {.exportc, cdecl.}
proc bl_event_handle*(evtType: uint32) {.exportc, cdecl.}
proc bl_fw_statistic_dump*() {.exportc, cdecl.}
proc me_init_rate*(staEntry: pointer) {.exportc, cdecl.}
proc me_init_bcmc_rate*(staEntry: pointer) {.exportc, cdecl.}
proc me_update_buffer_control*(sta: pointer): pointer {.exportc, cdecl.}
proc sm_assoc_done*(aid: uint16) {.exportc, cdecl.}
proc scanu_frame_handler*(frame: pointer, len: uint32) {.exportc, cdecl.}
proc scanu_find_result*(bssid: pointer, allocIfMissing: uint8 = 0): pointer {.exportc, cdecl.}
proc find_wpa_rsn_ie*(ieBuf: pointer, ieLen: uint32, wpaOut: ptr pointer, rsnOut: ptr pointer) {.exportc, cdecl.}
proc phy_channel_to_freq*(band: uint8, channel: uint8): uint16 {.weakExport, cdecl, noinline.}
proc phy_freq_to_channel*(band: uint8, freq: uint16): uint8 {.weakExport, cdecl.}
proc me_freq_to_chan_ptr*(band: uint8, freq: uint16): pointer {.exportc, cdecl.}
proc me_extract_rate_set*(ieBuf: pointer, ieLen: uint32, rateOut: pointer) {.exportc, cdecl.}
proc me_legacy_rate_bitfield_build*(rates: pointer, count: uint8): uint32 {.exportc, cdecl.}
proc me_legacy_ridx_min*(bitfield: uint32): uint8 {.exportc, cdecl.}
proc me_legacy_ridx_max*(bitfield: uint32): uint8 {.exportc, cdecl.}

const
  WifiHwPollLimit = 100_000'u32
  WifiMachwSoftResetReg = 0x24B08050'u32

var
  nimFwDbgHwWaitTimeoutCount* {.wifiCtrl, exportc: "nimfw_dbg_hw_wait_timeout_count".}: uint32
  nimFwDbgHwWaitLastReg* {.wifiCtrl, exportc: "nimfw_dbg_hw_wait_last_reg".}: uint32
  nimFwDbgHwWaitLastMask* {.wifiCtrl, exportc: "nimfw_dbg_hw_wait_last_mask".}: uint32
  nimFwDbgAssertErrCount* {.wifiCtrl, exportc: "nimfw_dbg_assert_err_count".}: uint32
  nimFwDbgAssertErrLastLine* {.wifiCtrl, exportc: "nimfw_dbg_assert_err_last_line".}: uint32
  nimFwDbgAssertErrLastFile* {.wifiCtrl, exportc: "nimfw_dbg_assert_err_last_file".}: uint32

proc noteHwWaitTimeout(reg, mask: uint32) {.inline.} =
  inc nimFwDbgHwWaitTimeoutCount
  nimFwDbgHwWaitLastReg = reg
  nimFwDbgHwWaitLastMask = mask

proc noteAssertErr(file: cstring, line: cint) {.inline.} =
  inc nimFwDbgAssertErrCount
  nimFwDbgAssertErrLastLine = cast[uint32](line)
  nimFwDbgAssertErrLastFile = cast[uint32](cast[uint](file))

proc waitRegMaskClear(reg: uint, mask: uint32,
                      limit: uint32 = WifiHwPollLimit): bool =
  result = radioWaitRegMaskClear(reg, mask, limit)
  if not result:
    noteHwWaitTimeout(reg.uint32, mask)

proc waitRegMaskSet(reg: uint, mask: uint32,
                    limit: uint32 = WifiHwPollLimit): bool =
  result = radioWaitRegMaskSet(reg, mask, limit)
  if not result:
    noteHwWaitTimeout(reg.uint32, mask)

proc waitRegLowNibbleClear(reg: uint,
                           limit: uint32 = WifiHwPollLimit): bool =
  var remaining = limit
  while (regRead(reg) and 0x3F'u32) != 0:
    if remaining == 0:
      noteHwWaitTimeout(reg.uint32, 0x3F'u32)
      return false
    dec remaining
  true

proc waitRegLowNibbleEquals(reg: uint, value: uint32,
                            limit: uint32 = WifiHwPollLimit): bool =
  let expected = value and 0x3F'u32
  var remaining = limit
  while (regRead(reg) and 0x3F'u32) != expected:
    if remaining == 0:
      noteHwWaitTimeout(reg.uint32, 0x3F'u32 or (expected shl 8))
      return false
    dec remaining
  true

proc waitMacSoftResetClear(limit: uint32 = WifiHwPollLimit): bool =
  var remaining = limit
  while blmac_soft_reset_getf() != 0:
    if remaining == 0:
      noteHwWaitTimeout(WifiMachwSoftResetReg, 0xFF'u32)
      return false
    dec remaining
  true

proc dsParamFreq(band: uint8, ds: ptr DsParamSetIeView): uint16 {.inline.} =
  phy_channel_to_freq(band, ds.currentChannel)
proc me_bw_check*(param: pointer) {.exportc, cdecl.}
proc me_rate_translate*(rateConfig: uint32): uint32 {.exportc, cdecl.}
proc rc_check*(staIdx: uint8) {.exportc, cdecl.}
proc rc_calc_tp*(entry: pointer, stats: pointer): uint32 {.exportc, cdecl.}
proc rc_update_counters*(staIdx: uint8, attemptCount: uint32, successCount: uint32) {.exportc, cdecl.}
proc rc_init*(staEntry: pointer) {.exportc, cdecl.}
proc rc_init_bcmc_rate*(staEntry: pointer, band: uint32) {.exportc, cdecl.}
proc mfp_compute_bip*(key: pointer, frame: pointer, frameLen: uint32,
    extraParam: uint32): uint64 {.exportc, cdecl.}
proc mfp_protect_mgmt_frame*(frameDesc: pointer, fc: uint32, action: uint32 = 0): uint32 {.exportc, cdecl, noinline.}
proc mfp_add_mgmt_mic*(frameDesc: pointer, bodyLen: uint32, totalLen: uint32): uint32 {.exportc, cdecl.}
proc me_extract_power_constraint*(ieBuf: pointer, ieLen: uint32, out_ptr: pointer) {.exportc, cdecl.}
proc me_extract_country_reg*(ieBuf: pointer, ieLen: uint32, out_ptr: pointer) {.exportc, cdecl.}
proc vif_mgmt_get_vif*(vifIdx: uint8): pointer {.exportc, cdecl, noinline.}
proc tpc_update_vif_tx_power*(vifEntry: pointer, txPowerElem: pointer, rateParam: pointer) {.exportc, cdecl.}
proc tpc_get_vif_tx_power_vs_rate*(vifIdx: uint8, rate: uint32): int8 {.exportc, cdecl.}
proc mac_ie_find*(buf: pointer, bufLen: uint32, ieId: uint8): pointer {.exportc, cdecl.}
proc mac_vsie_find*(buf: pointer, bufLen: uint32, oui: pointer, ouiLen: uint8): pointer {.exportc, cdecl.}
proc ke_msg_forward_and_change_id*(param: pointer, newId: uint16, destId: uint8, srcId: uint8) {.exportc, cdecl.}
proc c_memcmp(a, b: pointer, n: csize_t): cint {.importc: "memcmp", header: "<string.h>".}
proc ipc_emb_msg_handler*() {.exportc, cdecl.}

# Forward declarations for RC internal helpers
proc rc_get_mcs_index*(rateConfig: uint16): uint8 {.exportc, cdecl.}
proc rc_get_nss*(rateConfig: uint16): uint8 {.exportc, cdecl, noinline.}
proc rc_check_valid_rate*(stats: pointer, rateConfig: uint16): uint8 {.exportc, cdecl.}
proc rc_check_rate_duplicated*(stats: pointer, rateConfig: uint16): uint8 {.exportc, cdecl.}
proc rc_get_initial_rate_config*(stats: pointer): uint16 {.exportc, cdecl.}
proc rc_get_lowest_rate_config*(stats: pointer): uint16 {.exportc, cdecl.}
proc rc_new_random_rate*(stats: pointer): uint16 {.exportc, cdecl.}
proc rc_update_retry_chain*(stats: pointer, param: pointer) {.exportc, cdecl.}
proc rc_update_stats*(stats: pointer, needUpdate: uint8): uint8 {.exportc, cdecl.}
proc rc_set_previous_mcs_index*(stats: pointer, rateConfig: uint16): uint16 {.exportc, cdecl.}
proc rc_set_next_mcs_index*(stats: pointer, rateConfig: uint16): uint16 {.exportc, cdecl.}
proc rc_sort_samples_tp*(stats: pointer, tpArray: pointer) {.exportc, cdecl.}
proc rc_calc_prob_ewma*(entry: pointer) {.exportc, cdecl.}
proc rc_get_duration*(rateConfig: uint32, length: uint32): uint32 {.exportc, cdecl.}
