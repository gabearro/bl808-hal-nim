## M0 WiFi HAL feature test.
##
## WiFi credentials are supplied by hardware validation with:
##   -d:WifiSsid=<ssid> -d:WifiPassword=<password>

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/mmio
import bl808/wifi
import bl808/panicoverride
import bl808/kernel/alloc
when defined(bl808WifiNimFw):
  import bl808/kernel/jtaglog

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  WifiSsid {.strdefine.} = ""
  WifiPassword {.strdefine.} = ""
  WifiChannel {.intdefine.} = 0
  WifiPreInitDebugDelayMs {.intdefine.} = 0
  WifiScanDebugDelayMs {.intdefine.} = 0
  WifiRfVerboseDump {.booldefine.} = false
  WifiScanOnly {.booldefine.} = false
  WifiExpectConnectFailure {.booldefine.} = false
  WifiKeepaliveFrames {.intdefine.} = 0
  WifiKeepaliveQosNull {.booldefine.} = false
  WifiExpectedConnectStatus {.intdefine.} = 8
  WifiExpectedConnectReason {.intdefine.} = 15
  WifiStatusAssociateFailure = 5
  WifiStatusDeauthByApWhenConnecting = 6
  WifiStatusPskHandshakeTimeout = 8
  WifiReasonPreviousAuthenticationInvalid = 2
  WifiReasonAssociationDenied = 12
  WifiReasonFourWayHandshakeTimeout = 15

var
  console: Uart
  passed = 0
  failed = 0

proc check(label: string, ok: bool) =
  withInterruptsDisabled:
    console.flushTx()
    discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
    discard console.sendLine(label)
    console.flushTx()
  if ok: inc passed else: inc failed

proc wifiCredentialFailureMatches(status, reason: cint): bool =
  if status == WifiExpectedConnectStatus and reason == WifiExpectedConnectReason:
    return true
  # Different APs surface bad credentials at different phases. Treat only the
  # known wrong-key outcomes as credential failures; do not accept arbitrary
  # nonzero connect errors.
  (status == WifiStatusAssociateFailure and
    reason == WifiReasonAssociationDenied) or
  (status == WifiStatusDeauthByApWhenConnecting and
    reason == WifiReasonPreviousAuthenticationInvalid) or
  (status == WifiStatusPskHandshakeTimeout and
    reason == WifiReasonFourWayHandshakeTimeout)

proc printResult() =
  withInterruptsDisabled:
    console.flushTx()
    discard console.sendString("Result: ")
    console.sendHex32(passed.uint32)
    discard console.sendString(" passed, ")
    console.sendHex32(failed.uint32)
    discard console.sendLine(" failed")
    if failed == 0:
      discard console.sendLine("=== Test Complete ===")
    console.flushTx()

proc dumpReg(label: string, address: uint) =
  discard console.sendString(label)
  discard console.sendString("=")
  console.sendHex32(regRead(address))
  discard console.sendString(" ")

when defined(bl808WifiNimFw):
  proc sendHex8(value: uint8) =
    const hexDigits = "0123456789ABCDEF"
    discard console.sendByte(hexDigits[((value shr 4) and 0xF).int].uint8)
    discard console.sendByte(hexDigits[(value and 0xF).int].uint8)

  proc sendAsciiByte(value: uint8) =
    if value >= 32'u8 and value <= 126'u8:
      discard console.sendByte(value)
    else:
      discard console.sendByte('.'.uint8)

  proc dumpScanDiag() =
    var count = bl808_wifi_backend_scan_diag_count()
    discard console.sendString("[WIFI] scan diag count=")
    console.sendHex32(count)
    discard console.sendLine("")
    var i = 0'u32
    while i < count:
      var ssidLen: uint8
      var ssid: array[33, uint8]
      var channel: uint8
      var rssi: int8
      var auth: uint8
      var cipher: uint8
      var bssid: array[6, uint8]
      let rc = bl808_wifi_backend_scan_diag_get(i, addr ssidLen, addr ssid[0],
                                               addr channel, addr rssi,
                                               addr auth, addr cipher,
                                               addr bssid[0])
      if rc == 0:
        discard console.sendString("[WIFI] scan diag idx=")
        console.sendHex32(i)
        discard console.sendString(" ch=")
        console.sendHex32(channel.uint32)
        discard console.sendString(" rssi=")
        console.sendHex32(cast[uint8](rssi).uint32)
        discard console.sendString(" auth=")
        console.sendHex32(auth.uint32)
        discard console.sendString(" cipher=")
        console.sendHex32(cipher.uint32)
        discard console.sendString(" bssid=")
        for j in 0 ..< 6:
          if j > 0:
            discard console.sendByte(':'.uint8)
          sendHex8(bssid[j])
        discard console.sendString(" ssid=")
        if ssidLen > 32'u8:
          ssidLen = 32'u8
        for j in 0 ..< ssidLen.int:
          sendAsciiByte(ssid[j])
        discard console.sendLine("")
      inc i

proc dumpWifiMacRegs() =
  discard console.sendString("[WIFI] mac ")
  dumpReg("pl0", 0x24910000'u)
  dumpReg("pl1", 0x24910004'u)
  dumpReg("plh", 0x24910040'u)
  dumpReg("raw", 0x24B0806C'u)
  dumpReg("msk", 0x24B08074'u)
  dumpReg("gen", 0x24B08084'u)
  dumpReg("gst", 0x24B08080'u)
  discard console.sendLine("")
  discard console.sendString("[WIFI] rxreg ")
  dumpReg("rxf", 0x24B00060'u)
  dumpReg("sta", 0x24B0004C'u)
  dumpReg("hds", 0x24B081B8'u)
  dumpReg("pds", 0x24B081BC'u)
  dumpReg("hdh", 0x24B08548'u)
  dumpReg("pdh", 0x24B0854C'u)
  discard console.sendLine("")

when defined(bl808WifiNimFw):
  const NimFwRfPhyTraceLen = 8
  var rxl_cntrl_env {.importc.}: array[7, uint32]
  var rx_hwdesc_env {.importc.}: array[2, uint32]
  proc wifi_nimfw_debug_snapshot() {.importc, cdecl.}
  var nimfw_dbg_mac_irq {.importc.}: uint32
  var nimfw_dbg_mac_irq_last {.importc.}: uint32
  var nimfw_dbg_mac_irq_slot50 {.importc.}: uint32
  var nimfw_dbg_mac_irq_slot52 {.importc.}: uint32
  var nimfw_dbg_mac_irq_slot53 {.importc.}: uint32
  var nimfw_dbg_mac_irq_slot54 {.importc.}: uint32
  var nimfw_dbg_mac_irq_slot_other {.importc.}: uint32
  var nimfw_dbg_mac_irq_last_handler {.importc.}: uint32
  var nimfw_dbg_mac_irq_last_int_raw {.importc.}: uint32
  var nimfw_dbg_mac_irq_last_gen_raw {.importc.}: uint32
  var nimfw_dbg_mac_irq_last_rxctrl {.importc.}: uint32
  var nimfw_dbg_mac_irq_last_hd {.importc.}: uint32
  var nimfw_dbg_mac_irq_last_pd {.importc.}: uint32
  var nimfw_dbg_machw_gen {.importc.}: uint32
  var nimfw_dbg_machw_status {.importc.}: uint32
  var nimfw_dbg_machw_gen_status {.importc.}: uint32
  var nimfw_dbg_rxl_timer_evt {.importc.}: uint32
  var nimfw_dbg_rxl_timer_ready {.importc.}: uint32
  var nimfw_dbg_rxl_timer_head {.importc.}: uint32
  var nimfw_dbg_rxl_cntrl_evt {.importc.}: uint32
  var nimfw_dbg_rxl_cntrl_head {.importc.}: uint32
  var nimfw_dbg_rxl_dma_evt {.importc.}: uint32
  var nimfw_dbg_rxl_snap_hd {.importc.}: uint32
  var nimfw_dbg_rxl_snap_pd {.importc.}: uint32
  var nimfw_dbg_rxl_snap_hw_hd {.importc.}: uint32
  var nimfw_dbg_rxl_snap_hw_pd {.importc.}: uint32
  var nimfw_dbg_rxl_snap_irq_raw {.importc.}: uint32
  var nimfw_dbg_rxl_snap_gen_raw {.importc.}: uint32
  var nimfw_dbg_rxl_snap_rxctrl_raw {.importc.}: uint32
  var nimfw_dbg_rxl_snap_status_raw {.importc.}: uint32
  var nimfw_dbg_rxl_snap_hd_status {.importc.}: uint32
  var nimfw_dbg_rxl_snap_pd_status {.importc.}: uint32
  var nimfw_dbg_scan_start_rxctrl {.importc.}: uint32
  var nimfw_dbg_scan_start_irq_raw {.importc.}: uint32
  var nimfw_dbg_scan_start_gen_raw {.importc.}: uint32
  var nimfw_dbg_scan_end_rxctrl {.importc.}: uint32
  var nimfw_dbg_scan_end_irq_raw {.importc.}: uint32
  var nimfw_dbg_scan_end_gen_raw {.importc.}: uint32
  var nimfw_dbg_scan_req_chan_meta {.importc.}: uint32
  var nimfw_dbg_scan_req_chan_freq {.importc.}: uint32
  var nimfw_dbg_chan_scan_chan_meta {.importc.}: uint32
  var nimfw_dbg_chan_scan_chan_freq {.importc.}: uint32
  var nimfw_dbg_chan_pre_chan_meta {.importc.}: uint32
  var nimfw_dbg_chan_pre_chan_freq {.importc.}: uint32
  var nimfw_dbg_mac_timing_e8 {.importc.}: uint32
  var nimfw_dbg_mac_timing_f0 {.importc.}: uint32
  var nimfw_dbg_mac_timing_f4 {.importc.}: uint32
  var nimfw_dbg_mac_timing_f8 {.importc.}: uint32
  var nimfw_dbg_mac_timing_104 {.importc.}: uint32
  var nimfw_dbg_scan_start_phy_raw {.importc.}: array[4, uint32]
  var nimfw_dbg_scan_end_phy_raw {.importc.}: array[4, uint32]
  var nimfw_dbg_rf_phy_trace_count {.importc.}: uint32
  var nimfw_dbg_rf_phy_trace_phase {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_device {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_chan_meta {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_chan_freq {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf70 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf74 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf2c {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf04 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf34 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf40 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf4c {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf88 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf90 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rfa0 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rfa4 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rfbc {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rfd0 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf80 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf84 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf8c {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rfb4 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf1600 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf1614 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf1618 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf162c {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf1680 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rf113c {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_phy820 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_phy824 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_phy830 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_phy874 {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_rxctrl {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_irqraw {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_genraw {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_hd {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_pd {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_hwhd {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_phy_trace_hwpd {.importc.}: array[NimFwRfPhyTraceLen, uint32]
  var nimfw_dbg_rf_cal_save_count {.importc.}: uint32
  var nimfw_dbg_rf_cal_restore_count {.importc.}: uint32
  var nimfw_dbg_rf_cal_save_rf88 {.importc.}: uint32
  var nimfw_dbg_rf_cal_restore_rf88 {.importc.}: uint32
  var nimfw_dbg_rf_cal_restore_readback_rf88 {.importc.}: uint32
  var nimfw_dbg_rf_cal_restore_rf8c {.importc.}: uint32
  var nimfw_dbg_rf_cal_save_rf2c {.importc.}: uint32
  var nimfw_dbg_rf_cal_restore_rf2c {.importc.}: uint32
  var nimfw_dbg_rf_cal_restore_readback_rf2c {.importc.}: uint32
  var nimfw_dbg_rf_phase {.importc.}: uint32
  var nimfw_dbg_rf_restore {.importc.}: uint32
  var nimfw_dbg_rf_api_mode {.importc.}: uint32
  var nimfw_dbg_phy_init_count {.importc.}: uint32
  var nimfw_dbg_phy_init_phase {.importc.}: uint32
  var nimfw_dbg_phy_modem_version {.importc.}: uint32
  var nimfw_dbg_phy_clock_count {.importc.}: uint32
  var nimfw_dbg_phy_agc_copy_count {.importc.}: uint32
  var nimfw_dbg_phy_agc_source_first {.importc.}: uint32
  var nimfw_dbg_phy_agc_source_last {.importc.}: uint32
  var nimfw_dbg_phy_agc_dest_first {.importc.}: uint32
  var nimfw_dbg_phy_agc_dest_last {.importc.}: uint32
  var nimfw_dbg_phy_wifi_ldpc_absent {.importc.}: uint32
  var nim_wifi_rf_fixed_val_count {.importc.}: uint32
  var nim_wifi_rf_fixed_val_device {.importc.}: uint32
  var nim_wifi_rf_fixed_val_branch {.importc.}: uint32
  var nim_wifi_rf_fixed_val_rf70 {.importc.}: uint32
  var nim_wifi_rf_fixed_val_rf88 {.importc.}: uint32
  var nim_wifi_rf_fixed_val_rfd0 {.importc.}: uint32
  var nim_wifi_rf_fixed_val_rf814 {.importc.}: uint32
  var nim_wifi_rf_fixed_val_rfa0 {.importc.}: uint32
  var nim_wifi_rf_rf70_replay_apply_count {.importc.}: uint32
  var nim_wifi_rf_rf70_replay_reason {.importc.}: uint32
  var nim_wifi_rf_rf70_replay_reg_before {.importc.}: uint32
  var nim_wifi_rf_rf70_replay_reg_after {.importc.}: uint32
  var nim_wifi_rf_rf70_replay_cal_word3_before {.importc.}: uint32
  var nim_wifi_rf_rf70_replay_cal_word4_before {.importc.}: uint32
  var nim_wifi_rf_rf70_replay_cal_word3_after {.importc.}: uint32
  var nim_wifi_rf_rf70_replay_cal_word4_after {.importc.}: uint32
  var nim_wifi_rf_rf70_txcal_window0_nibble {.importc.}: uint32
  var nim_wifi_rf_rf70_txcal_window1_nibble {.importc.}: uint32
  var nim_wifi_rf_rf70_txcal_window2_nibble {.importc.}: uint32
  var nim_wifi_rf_rf70_txcal_window_mask {.importc.}: uint32
  var nim_wifi_rf_rf70_txcal_search_count {.importc.}: uint32
  var nim_wifi_rf_rf70_txcal_search_ok_mask {.importc.}: uint32
  var nim_wifi_rf_rf70_txcal_search_best_nibble {.importc.}: array[3, uint32]
  var nim_wifi_rf_rf70_txcal_search_runner_nibble {.importc.}: array[3, uint32]
  var nim_wifi_rf_rf70_txcal_search_best_sample {.importc.}: array[3, uint32]
  var nim_wifi_rf_rf70_txcal_search_runner_sample {.importc.}: array[3, uint32]
  var nim_wifi_rf_rf70_txcal_search_ctrl {.importc.}: array[3, uint32]
  var nim_wifi_rf_rf70_txcal_search_mode {.importc.}: array[3, uint32]
  var nim_wifi_rf_rf70_txcal_search_i_raw {.importc.}: array[3, uint32]
  var nim_wifi_rf_rf70_txcal_candidate_ok_mask {.importc.}: array[3, uint32]
  var nim_wifi_rf_rf70_txcal_candidate_sample {.importc.}: array[48, uint32]
  var nim_wifi_rf_pri_txcal_count {.importc.}: uint32
  var nim_wifi_rf_pri_lo_fcal_count {.importc.}: uint32
  var nim_wifi_rf_pri_lo_acal_count {.importc.}: uint32
  var nim_wifi_rf_pri_roscal_count {.importc.}: uint32
  var nim_wifi_rf_pri_rccal_count {.importc.}: uint32
  var nim_wifi_rf_pri_rxcal_count {.importc.}: uint32
  var nim_wifi_rf_fcal_wait_timeout_count {.importc.}: uint32
  var nim_wifi_rf_roscal_wait_timeout_count {.importc.}: uint32
  var nim_wifi_rf_rccal_wait_timeout_count {.importc.}: uint32
  var nim_wifi_rf_txcal_wait_timeout_count {.importc.}: uint32
  var nim_wifi_rf_rxcal_wait_timeout_count {.importc.}: uint32
  var nim_wifi_rf_config_channel_wait_timeout_count {.importc.}: uint32
  var nim_wifi_rf_txcal_search_count {.importc.}: uint32
  var nim_wifi_rf_txcal_amp_search_count {.importc.}: uint32
  var nim_wifi_rf_rxcal_search_count {.importc.}: uint32
  var nim_wifi_rf_last_roscal_i {.importc.}: uint32
  var nim_wifi_rf_last_roscal_q {.importc.}: uint32
  var nim_wifi_rf_last_rccal_code {.importc.}: uint32
  var nim_wifi_rf_last_rccal_baseline {.importc.}: uint32
  var nim_wifi_rf_last_rccal_target {.importc.}: uint32
  var nim_wifi_rf_last_rccal_power {.importc.}: uint32
  var nim_wifi_rf_last_txcal_word0 {.importc.}: uint32
  var nim_wifi_rf_last_txcal_word1 {.importc.}: uint32
  var nim_wifi_rf_last_txcal_amp {.importc.}: uint32
  var nim_wifi_rf_last_txcal_amp_mean {.importc.}: uint32
  var nim_wifi_rf_last_txcal_tmxcs {.importc.}: uint32
  var nim_wifi_rf_last_txcal_tmxcs_power {.importc.}: uint32
  var nim_wifi_rf_pre_rf70_txcal_amp {.importc.}: uint32
  var nim_wifi_rf_pre_rf70_txcal_amp_mean {.importc.}: uint32
  var nim_wifi_rf_pre_rf70_rf70 {.importc.}: uint32
  var nim_wifi_rf_pre_rf70_rf6c {.importc.}: uint32
  var nim_wifi_rf_pre_rf70_rf120c {.importc.}: uint32
  var nim_wifi_rf_pre_rf70_rf1214 {.importc.}: uint32
  var nim_wifi_rf_pre_rf70_rf1218 {.importc.}: uint32
  var nim_wifi_rf_pre_rf70_rf1618 {.importc.}: uint32
  var nim_wifi_rf_pre_rf70_rf161c {.importc.}: uint32
  var nim_wifi_rf_last_rxcal_word0 {.importc.}: uint32
  var nim_wifi_rf_last_rxcal_word1 {.importc.}: uint32
  var nim_wifi_rf_last_rxcal_power {.importc.}: uint32
  var nim_wifi_rf_last_config_channel_index {.importc.}: uint32
  var nim_wifi_rf_last_config_channel_status {.importc.}: uint32
  var nim_wifi_rf_last_config_channel_fcal {.importc.}: uint32
  var nim_wifi_rf_last_config_channel_acal {.importc.}: uint32
  var nim_wifi_rf_last_config_channel_sdm2 {.importc.}: uint32
  var nim_wifi_rf_last_config_channel_b8 {.importc.}: uint32
  var nim_wifi_rf_last_config_channel_b0 {.importc.}: uint32
  var nim_wifi_rf_txcal_word0_log {.importc.}: array[18, uint32]
  var nim_wifi_rf_txcal_word1_log {.importc.}: array[18, uint32]
  var nim_wifi_rf_txcal_power_log {.importc.}: array[18, uint32]
  var nim_wifi_rf_txcal_amp_log {.importc.}: array[18, uint32]
  var nim_wifi_rf_txcal_sample_count {.importc.}: uint32
  var nim_wifi_rf_txcal_sample_param_log {.importc.}: array[48, uint32]
  var nim_wifi_rf_txcal_sample_candidate_log {.importc.}: array[48, uint32]
  var nim_wifi_rf_txcal_sample_freq_log {.importc.}: array[48, uint32]
  var nim_wifi_rf_txcal_sample_ctrl_log {.importc.}: array[48, uint32]
  var nim_wifi_rf_txcal_sample_i_log {.importc.}: array[48, uint32]
  var nim_wifi_rf_txcal_sample_q_log {.importc.}: array[48, uint32]
  var nim_wifi_rf_txcal_sample_power_log {.importc.}: array[48, uint32]
  var nim_wifi_rf_rxcal_word0_log {.importc.}: array[4, uint32]
  var nim_wifi_rf_rxcal_word1_log {.importc.}: array[4, uint32]
  var nim_wifi_rf_rxcal_power_log {.importc.}: array[4, uint32]
  var nim_wifi_rf_bz_txcal_snapshot_count {.importc.}: uint32
  var nim_wifi_rf_bz_txcal_snapshot_tag {.importc.}: uint32
  var nim_wifi_rf_bz_txcal_word0_log {.importc.}: array[9, uint32]
  var nim_wifi_rf_bz_txcal_word1_log {.importc.}: array[9, uint32]
  var nim_wifi_rf_bz_txcal_ok_mask_log {.importc.}: array[9, uint32]
  var nim_wifi_rf_bz_txcal_power_log {.importc.}: array[9, uint32]
  var nim_wifi_rf_bz_txcal_rf48_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_bz_txcal_rf4c_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_bz_txcal_rf88_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_bz_txcal_rf1600_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_bz_txcal_rf162c_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_bz_txcal_tag_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_snapshot_count {.importc.}: uint32
  var nim_wifi_rf_stage_tag_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rf4c_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rf70_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rf7c_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rf80_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rf88_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rfa0_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rfd0_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rf1600_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rf162c_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rfb0_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rfb4_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rfbc_log {.importc.}: array[8, uint32]

  proc dumpRfInitStageTrace() =
    discard console.sendString("[WIFI-NIMFW] rfstage snaps=")
    console.sendHex32(nim_wifi_rf_stage_snapshot_count)
    discard console.sendLine("")
    let count = nim_wifi_rf_stage_snapshot_count
    let n = if count < 8'u32: count.int else: 8
    let start = if count < 8'u32: 0'u32 else: count - 8'u32
    for off in 0 ..< n:
      let seq = start + off.uint32
      let idx = int(seq and 0x7'u32)
      discard console.sendString("[WIFI-NIMFW] rfstage idx=")
      console.sendHex32(seq)
      discard console.sendString(" tag=")
      console.sendHex32(nim_wifi_rf_stage_tag_log[idx])
      discard console.sendString(" r70=")
      console.sendHex32(nim_wifi_rf_stage_rf70_log[idx])
      discard console.sendString(" r7c=")
      console.sendHex32(nim_wifi_rf_stage_rf7c_log[idx])
      discard console.sendString(" r80=")
      console.sendHex32(nim_wifi_rf_stage_rf80_log[idx])
      discard console.sendString(" r88=")
      console.sendHex32(nim_wifi_rf_stage_rf88_log[idx])
      discard console.sendString(" rfa0=")
      console.sendHex32(nim_wifi_rf_stage_rfa0_log[idx])
      discard console.sendString(" rfd0=")
      console.sendHex32(nim_wifi_rf_stage_rfd0_log[idx])
      discard console.sendString(" rfb0=")
      console.sendHex32(nim_wifi_rf_stage_rfb0_log[idx])
      discard console.sendString(" rfb4=")
      console.sendHex32(nim_wifi_rf_stage_rfb4_log[idx])
      discard console.sendString(" rfbc=")
      console.sendHex32(nim_wifi_rf_stage_rfbc_log[idx])
      discard console.sendString(" r4c=")
      console.sendHex32(nim_wifi_rf_stage_rf4c_log[idx])
      discard console.sendString(" r1600=")
      console.sendHex32(nim_wifi_rf_stage_rf1600_log[idx])
      discard console.sendString(" r162c=")
      console.sendHex32(nim_wifi_rf_stage_rf162c_log[idx])
      discard console.sendLine("")

  proc dumpRfCalSummary() =
    discard console.sendString("[WIFI-NIMFW] rfcore phase=")
    console.sendHex32(nimfw_dbg_rf_phase)
    discard console.sendString(" restore=")
    console.sendHex32(nimfw_dbg_rf_restore)
    discard console.sendString(" api=")
    console.sendHex32(nimfw_dbg_rf_api_mode)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] phyinit count=")
    console.sendHex32(nimfw_dbg_phy_init_count)
    discard console.sendString(" phase=")
    console.sendHex32(nimfw_dbg_phy_init_phase)
    discard console.sendString(" version=")
    console.sendHex32(nimfw_dbg_phy_modem_version)
    discard console.sendString(" clk=")
    console.sendHex32(nimfw_dbg_phy_clock_count)
    discard console.sendString(" agc_copy=")
    console.sendHex32(nimfw_dbg_phy_agc_copy_count)
    discard console.sendString(" src0=")
    console.sendHex32(nimfw_dbg_phy_agc_source_first)
    discard console.sendString(" srcN=")
    console.sendHex32(nimfw_dbg_phy_agc_source_last)
    discard console.sendString(" dst0=")
    console.sendHex32(nimfw_dbg_phy_agc_dest_first)
    discard console.sendString(" dstN=")
    console.sendHex32(nimfw_dbg_phy_agc_dest_last)
    discard console.sendString(" wifi_ldpc_absent=")
    console.sendHex32(nimfw_dbg_phy_wifi_ldpc_absent)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] rffixed count=")
    console.sendHex32(nim_wifi_rf_fixed_val_count)
    discard console.sendString(" dev=")
    console.sendHex32(nim_wifi_rf_fixed_val_device)
    discard console.sendString(" branch=")
    console.sendHex32(nim_wifi_rf_fixed_val_branch)
    discard console.sendString(" r70=")
    console.sendHex32(nim_wifi_rf_fixed_val_rf70)
    discard console.sendString(" r88=")
    console.sendHex32(nim_wifi_rf_fixed_val_rf88)
    discard console.sendString(" rfd0=")
    console.sendHex32(nim_wifi_rf_fixed_val_rfd0)
    discard console.sendString(" r814=")
    console.sendHex32(nim_wifi_rf_fixed_val_rf814)
    discard console.sendString(" rfa0=")
    console.sendHex32(nim_wifi_rf_fixed_val_rfa0)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] rf70replay apply_count=")
    console.sendHex32(nim_wifi_rf_rf70_replay_apply_count)
    discard console.sendString(" reason=")
    console.sendHex32(nim_wifi_rf_rf70_replay_reason)
    discard console.sendString(" reg_before=")
    console.sendHex32(nim_wifi_rf_rf70_replay_reg_before)
    discard console.sendString(" reg_after=")
    console.sendHex32(nim_wifi_rf_rf70_replay_reg_after)
    discard console.sendString(" cal3_before=")
    console.sendHex32(nim_wifi_rf_rf70_replay_cal_word3_before)
    discard console.sendString(" cal4_before=")
    console.sendHex32(nim_wifi_rf_rf70_replay_cal_word4_before)
    discard console.sendString(" cal3_after=")
    console.sendHex32(nim_wifi_rf_rf70_replay_cal_word3_after)
    discard console.sendString(" cal4_after=")
    console.sendHex32(nim_wifi_rf_rf70_replay_cal_word4_after)
    discard console.sendString(" winmask=")
    console.sendHex32(nim_wifi_rf_rf70_txcal_window_mask)
    discard console.sendString(" w0=")
    console.sendHex32(nim_wifi_rf_rf70_txcal_window0_nibble)
    discard console.sendString(" w1=")
    console.sendHex32(nim_wifi_rf_rf70_txcal_window1_nibble)
    discard console.sendString(" w2=")
    console.sendHex32(nim_wifi_rf_rf70_txcal_window2_nibble)
    discard console.sendString(" search=")
    console.sendHex32(nim_wifi_rf_rf70_txcal_search_count)
    discard console.sendString(" okmask=")
    console.sendHex32(nim_wifi_rf_rf70_txcal_search_ok_mask)
    for i in 0 ..< 3:
      discard console.sendString(" best")
      discard console.sendString($i)
      discard console.sendString("=")
      console.sendHex32(nim_wifi_rf_rf70_txcal_search_best_nibble[i])
      discard console.sendString("/")
      console.sendHex32(nim_wifi_rf_rf70_txcal_search_best_sample[i])
      discard console.sendString(" runner")
      discard console.sendString($i)
      discard console.sendString("=")
      console.sendHex32(nim_wifi_rf_rf70_txcal_search_runner_nibble[i])
      discard console.sendString("/")
      console.sendHex32(nim_wifi_rf_rf70_txcal_search_runner_sample[i])
      discard console.sendString(" ctrl")
      discard console.sendString($i)
      discard console.sendString("=")
      console.sendHex32(nim_wifi_rf_rf70_txcal_search_ctrl[i])
      discard console.sendString(" mode")
      discard console.sendString($i)
      discard console.sendString("=")
      console.sendHex32(nim_wifi_rf_rf70_txcal_search_mode[i])
      discard console.sendString(" i")
      discard console.sendString($i)
      discard console.sendString("=")
      console.sendHex32(nim_wifi_rf_rf70_txcal_search_i_raw[i])
    discard console.sendLine("")
    for window in 0 ..< 3:
      discard console.sendString("[WIFI-NIMFW] rf70cand win=")
      console.sendHex32(window.uint32)
      discard console.sendString(" okmask=")
      console.sendHex32(nim_wifi_rf_rf70_txcal_candidate_ok_mask[window])
      for candidate in 0 ..< 16:
        discard console.sendString(" c")
        discard console.sendString($candidate)
        discard console.sendString("=")
        console.sendHex32(
          nim_wifi_rf_rf70_txcal_candidate_sample[window * 16 + candidate])
      discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] rf70setup amp=")
    console.sendHex32(nim_wifi_rf_pre_rf70_txcal_amp)
    discard console.sendString(" mean=")
    console.sendHex32(nim_wifi_rf_pre_rf70_txcal_amp_mean)
    discard console.sendString(" r70=")
    console.sendHex32(nim_wifi_rf_pre_rf70_rf70)
    discard console.sendString(" r6c=")
    console.sendHex32(nim_wifi_rf_pre_rf70_rf6c)
    discard console.sendString(" r120c=")
    console.sendHex32(nim_wifi_rf_pre_rf70_rf120c)
    discard console.sendString(" r1214=")
    console.sendHex32(nim_wifi_rf_pre_rf70_rf1214)
    discard console.sendString(" r1218=")
    console.sendHex32(nim_wifi_rf_pre_rf70_rf1218)
    discard console.sendString(" r1618=")
    console.sendHex32(nim_wifi_rf_pre_rf70_rf1618)
    discard console.sendString(" r161c=")
    console.sendHex32(nim_wifi_rf_pre_rf70_rf161c)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] rfcal state save=")
    console.sendHex32(nimfw_dbg_rf_cal_save_count)
    discard console.sendString(" restore=")
    console.sendHex32(nimfw_dbg_rf_cal_restore_count)
    discard console.sendString(" save88=")
    console.sendHex32(nimfw_dbg_rf_cal_save_rf88)
    discard console.sendString(" rest88=")
    console.sendHex32(nimfw_dbg_rf_cal_restore_rf88)
    discard console.sendString(" rb88=")
    console.sendHex32(nimfw_dbg_rf_cal_restore_readback_rf88)
    discard console.sendString(" rb8c=")
    console.sendHex32(nimfw_dbg_rf_cal_restore_rf8c)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] rfcal rf2c save=")
    console.sendHex32(nimfw_dbg_rf_cal_save_rf2c)
    discard console.sendString(" restore=")
    console.sendHex32(nimfw_dbg_rf_cal_restore_rf2c)
    discard console.sendString(" rb=")
    console.sendHex32(nimfw_dbg_rf_cal_restore_readback_rf2c)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] rfcal counts tx=")
    console.sendHex32(nim_wifi_rf_pri_txcal_count)
    discard console.sendString(" lof=")
    console.sendHex32(nim_wifi_rf_pri_lo_fcal_count)
    discard console.sendString(" loa=")
    console.sendHex32(nim_wifi_rf_pri_lo_acal_count)
    discard console.sendString(" ros=")
    console.sendHex32(nim_wifi_rf_pri_roscal_count)
    discard console.sendString(" rcc=")
    console.sendHex32(nim_wifi_rf_pri_rccal_count)
    discard console.sendString(" rx=")
    console.sendHex32(nim_wifi_rf_pri_rxcal_count)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] rfcal waits fcal=")
    console.sendHex32(nim_wifi_rf_fcal_wait_timeout_count)
    discard console.sendString(" ros=")
    console.sendHex32(nim_wifi_rf_roscal_wait_timeout_count)
    discard console.sendString(" rcc=")
    console.sendHex32(nim_wifi_rf_rccal_wait_timeout_count)
    discard console.sendString(" tx=")
    console.sendHex32(nim_wifi_rf_txcal_wait_timeout_count)
    discard console.sendString(" rx=")
    console.sendHex32(nim_wifi_rf_rxcal_wait_timeout_count)
    discard console.sendString(" ch=")
    console.sendHex32(nim_wifi_rf_config_channel_wait_timeout_count)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] rfcal search tx=")
    console.sendHex32(nim_wifi_rf_txcal_search_count)
    discard console.sendString(" txamp=")
    console.sendHex32(nim_wifi_rf_txcal_amp_search_count)
    discard console.sendString(" rx=")
    console.sendHex32(nim_wifi_rf_rxcal_search_count)
    discard console.sendString(" ros_i=")
    console.sendHex32(nim_wifi_rf_last_roscal_i)
    discard console.sendString(" ros_q=")
    console.sendHex32(nim_wifi_rf_last_roscal_q)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] rccal code=")
    console.sendHex32(nim_wifi_rf_last_rccal_code)
    discard console.sendString(" base=")
    console.sendHex32(nim_wifi_rf_last_rccal_baseline)
    discard console.sendString(" target=")
    console.sendHex32(nim_wifi_rf_last_rccal_target)
    discard console.sendString(" power=")
    console.sendHex32(nim_wifi_rf_last_rccal_power)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] chcal idx=")
    console.sendHex32(nim_wifi_rf_last_config_channel_index)
    discard console.sendString(" status=")
    console.sendHex32(nim_wifi_rf_last_config_channel_status)
    discard console.sendString(" fcal=")
    console.sendHex32(nim_wifi_rf_last_config_channel_fcal)
    discard console.sendString(" acal=")
    console.sendHex32(nim_wifi_rf_last_config_channel_acal)
    discard console.sendString(" sdm2=")
    console.sendHex32(nim_wifi_rf_last_config_channel_sdm2)
    discard console.sendString(" b8=")
    console.sendHex32(nim_wifi_rf_last_config_channel_b8)
    discard console.sendString(" b0=")
    console.sendHex32(nim_wifi_rf_last_config_channel_b0)
    discard console.sendLine("")

  proc dumpRxDesc(label: string, desc: uint32) =
    discard console.sendString(label)
    discard console.sendString("=")
    console.sendHex32(desc)
    if desc != 0:
      discard console.sendString(" n=")
      console.sendHex32(cast[ptr uint32](desc.uint + 4'u)[])
      discard console.sendString(" b=")
      console.sendHex32(cast[ptr uint32](desc.uint + 8'u)[])
      discard console.sendString(" sw=")
      console.sendHex32(cast[ptr uint32](desc.uint + 12'u)[])
      discard console.sendString(" st=")
      console.sendHex32(cast[ptr uint32](desc.uint + 64'u)[])
      discard console.sendString(" own=")
      console.sendHex32(cast[ptr uint32](desc.uint + 96'u)[])
    discard console.sendLine("")

  proc dumpWifiNimFwRxSnapshot() =
    wifi_nimfw_debug_snapshot()
    discard console.sendString("[WIFI-NIMFW] irq count=")
    console.sendHex32(nimfw_dbg_mac_irq)
    discard console.sendString(" last=")
    console.sendHex32(nimfw_dbg_mac_irq_last)
    discard console.sendString(" handler=")
    console.sendHex32(nimfw_dbg_mac_irq_last_handler)
    discard console.sendString(" s50=")
    console.sendHex32(nimfw_dbg_mac_irq_slot50)
    discard console.sendString(" s52=")
    console.sendHex32(nimfw_dbg_mac_irq_slot52)
    discard console.sendString(" s53=")
    console.sendHex32(nimfw_dbg_mac_irq_slot53)
    discard console.sendString(" s54=")
    console.sendHex32(nimfw_dbg_mac_irq_slot54)
    discard console.sendString(" other=")
    console.sendHex32(nimfw_dbg_mac_irq_slot_other)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] irq regs raw=")
    console.sendHex32(nimfw_dbg_mac_irq_last_int_raw)
    discard console.sendString(" genraw=")
    console.sendHex32(nimfw_dbg_mac_irq_last_gen_raw)
    discard console.sendString(" rxctrl=")
    console.sendHex32(nimfw_dbg_mac_irq_last_rxctrl)
    discard console.sendString(" hds=")
    console.sendHex32(nimfw_dbg_mac_irq_last_hd)
    discard console.sendString(" pds=")
    console.sendHex32(nimfw_dbg_mac_irq_last_pd)
    discard console.sendString(" machw=")
    console.sendHex32(nimfw_dbg_machw_status)
    discard console.sendString(" gen=")
    console.sendHex32(nimfw_dbg_machw_gen_status)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] rx snap hd=")
    console.sendHex32(nimfw_dbg_rxl_snap_hd)
    discard console.sendString(" pd=")
    console.sendHex32(nimfw_dbg_rxl_snap_pd)
    discard console.sendString(" hdh=")
    console.sendHex32(nimfw_dbg_rxl_snap_hw_hd)
    discard console.sendString(" pdh=")
    console.sendHex32(nimfw_dbg_rxl_snap_hw_pd)
    discard console.sendString(" hdst=")
    console.sendHex32(nimfw_dbg_rxl_snap_hd_status)
    discard console.sendString(" pdst=")
    console.sendHex32(nimfw_dbg_rxl_snap_pd_status)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] rx regs irqraw=")
    console.sendHex32(nimfw_dbg_rxl_snap_irq_raw)
    discard console.sendString(" genraw=")
    console.sendHex32(nimfw_dbg_rxl_snap_gen_raw)
    discard console.sendString(" rxctrl=")
    console.sendHex32(nimfw_dbg_rxl_snap_rxctrl_raw)
    discard console.sendString(" macstat=")
    console.sendHex32(nimfw_dbg_rxl_snap_status_raw)
    discard console.sendString(" rxl_evt=")
    console.sendHex32(nimfw_dbg_rxl_timer_evt)
    discard console.sendString("/")
    console.sendHex32(nimfw_dbg_rxl_timer_ready)
    discard console.sendString("/")
    console.sendHex32(nimfw_dbg_rxl_cntrl_evt)
    discard console.sendString("/")
    console.sendHex32(nimfw_dbg_rxl_dma_evt)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] scan regs start_rx=")
    console.sendHex32(nimfw_dbg_scan_start_rxctrl)
    discard console.sendString(" start_irq=")
    console.sendHex32(nimfw_dbg_scan_start_irq_raw)
    discard console.sendString(" start_gen=")
    console.sendHex32(nimfw_dbg_scan_start_gen_raw)
    discard console.sendString(" end_rx=")
    console.sendHex32(nimfw_dbg_scan_end_rxctrl)
    discard console.sendString(" end_irq=")
    console.sendHex32(nimfw_dbg_scan_end_irq_raw)
    discard console.sendString(" end_gen=")
    console.sendHex32(nimfw_dbg_scan_end_gen_raw)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] scan chan req_meta=")
    console.sendHex32(nimfw_dbg_scan_req_chan_meta)
    discard console.sendString(" req_freq=")
    console.sendHex32(nimfw_dbg_scan_req_chan_freq)
    discard console.sendString(" chan_meta=")
    console.sendHex32(nimfw_dbg_chan_scan_chan_meta)
    discard console.sendString(" chan_freq=")
    console.sendHex32(nimfw_dbg_chan_scan_chan_freq)
    discard console.sendString(" pre_meta=")
    console.sendHex32(nimfw_dbg_chan_pre_chan_meta)
    discard console.sendString(" pre_freq=")
    console.sendHex32(nimfw_dbg_chan_pre_chan_freq)
    discard console.sendString(" mac_e8=")
    console.sendHex32(nimfw_dbg_mac_timing_e8)
    discard console.sendString(" mac_f0=")
    console.sendHex32(nimfw_dbg_mac_timing_f0)
    discard console.sendString(" mac_f4=")
    console.sendHex32(nimfw_dbg_mac_timing_f4)
    discard console.sendString(" mac_f8=")
    console.sendHex32(nimfw_dbg_mac_timing_f8)
    discard console.sendString(" mac_104=")
    console.sendHex32(nimfw_dbg_mac_timing_104)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] scan phy start=")
    for i in 0 ..< 4:
      if i != 0:
        discard console.sendString("/")
      console.sendHex32(nimfw_dbg_scan_start_phy_raw[i])
    discard console.sendString(" end=")
    for i in 0 ..< 4:
      if i != 0:
        discard console.sendString("/")
      console.sendHex32(nimfw_dbg_scan_end_phy_raw[i])
    discard console.sendLine("")

  proc dumpRfPhyTrace() =
    let count = nimfw_dbg_rf_phy_trace_count
    discard console.sendString("[WIFI-NIMFW] rfphy trace count=")
    console.sendHex32(count)
    discard console.sendLine("")
    let n = if count < NimFwRfPhyTraceLen.uint32: count.int else: NimFwRfPhyTraceLen
    let start =
      if count < NimFwRfPhyTraceLen.uint32: 0'u32
      else: count - NimFwRfPhyTraceLen.uint32
    for off in 0 ..< n:
      let seq = start + off.uint32
      let idx = int(seq and (NimFwRfPhyTraceLen.uint32 - 1'u32))
      discard console.sendString("[WIFI-NIMFW] rfphy idx=")
      console.sendHex32(seq)
      discard console.sendString(" ph=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_phase[idx])
      discard console.sendString(" dev=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_device[idx])
      discard console.sendString(" meta=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_chan_meta[idx])
      discard console.sendString(" freq=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_chan_freq[idx])
      discard console.sendString(" r70=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf70[idx])
      discard console.sendString(" r74=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf74[idx])
      discard console.sendString(" r2c=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf2c[idx])
      discard console.sendString(" r04=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf04[idx])
      discard console.sendString(" r34=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf34[idx])
      discard console.sendString(" r40=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf40[idx])
      discard console.sendString(" r4c=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf4c[idx])
      discard console.sendString(" r88=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf88[idx])
      discard console.sendString(" r90=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf90[idx])
      discard console.sendString(" rfa0=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rfa0[idx])
      discard console.sendString(" rfa4=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rfa4[idx])
      discard console.sendString(" rfbc=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rfbc[idx])
      discard console.sendString(" rfd0=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rfd0[idx])
      discard console.sendLine("")
      discard console.sendString("[WIFI-NIMFW] rfphy ext=")
      console.sendHex32(seq)
      discard console.sendString(" r1600=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf1600[idx])
      discard console.sendString(" r1614=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf1614[idx])
      discard console.sendString(" r1618=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf1618[idx])
      discard console.sendString(" r162c=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf162c[idx])
      discard console.sendString(" r1680=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf1680[idx])
      discard console.sendString(" r113c=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf113c[idx])
      discard console.sendString(" p820=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_phy820[idx])
      discard console.sendString(" p824=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_phy824[idx])
      discard console.sendString(" p830=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_phy830[idx])
      discard console.sendString(" p874=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_phy874[idx])
      discard console.sendString(" rx=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rxctrl[idx])
      discard console.sendString(" irq=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_irqraw[idx])
      discard console.sendString(" gen=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_genraw[idx])
      discard console.sendString(" r80=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf80[idx])
      discard console.sendString(" r84=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf84[idx])
      discard console.sendString(" r8c=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rf8c[idx])
      discard console.sendString(" rb4=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_rfb4[idx])
      discard console.sendString(" hd=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_hd[idx])
      discard console.sendString(" pd=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_pd[idx])
      discard console.sendString(" hwhd=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_hwhd[idx])
      discard console.sendString(" hwpd=")
      console.sendHex32(nimfw_dbg_rf_phy_trace_hwpd[idx])
      discard console.sendLine("")

  proc dumpRfTxcalTrace() =
    discard console.sendString("[WIFI-NIMFW] txcal last w0=")
    console.sendHex32(nim_wifi_rf_last_txcal_word0)
    discard console.sendString(" w1=")
    console.sendHex32(nim_wifi_rf_last_txcal_word1)
    discard console.sendString(" amp=")
    console.sendHex32(nim_wifi_rf_last_txcal_amp)
    discard console.sendString(" mean=")
    console.sendHex32(nim_wifi_rf_last_txcal_amp_mean)
    discard console.sendString(" tmxcs=")
    console.sendHex32(nim_wifi_rf_last_txcal_tmxcs)
    discard console.sendString(" tmxp=")
    console.sendHex32(nim_wifi_rf_last_txcal_tmxcs_power)
    discard console.sendLine("")
    for idx in 0 ..< 18:
      discard console.sendString("[WIFI-NIMFW] txcal rec=")
      console.sendHex32(idx.uint32)
      discard console.sendString(" w0=")
      console.sendHex32(nim_wifi_rf_txcal_word0_log[idx])
      discard console.sendString(" w1=")
      console.sendHex32(nim_wifi_rf_txcal_word1_log[idx])
      discard console.sendString(" pwr=")
      console.sendHex32(nim_wifi_rf_txcal_power_log[idx])
      discard console.sendString(" amp=")
      console.sendHex32(nim_wifi_rf_txcal_amp_log[idx])
      discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] txcal samples=")
    console.sendHex32(nim_wifi_rf_txcal_sample_count)
    discard console.sendLine("")
    let sampleCount = nim_wifi_rf_txcal_sample_count
    let sampleStart =
      if sampleCount > 48'u32: sampleCount - 48'u32 else: 0'u32
    for n in sampleStart ..< sampleCount:
      let idx = int(n mod 48'u32)
      discard console.sendString("[WIFI-NIMFW] txcal sample=")
      console.sendHex32(n)
      discard console.sendString(" param=")
      console.sendHex32(nim_wifi_rf_txcal_sample_param_log[idx])
      discard console.sendString(" cand=")
      console.sendHex32(nim_wifi_rf_txcal_sample_candidate_log[idx])
      discard console.sendString(" freq=")
      console.sendHex32(nim_wifi_rf_txcal_sample_freq_log[idx])
      discard console.sendString(" ctrl=")
      console.sendHex32(nim_wifi_rf_txcal_sample_ctrl_log[idx])
      discard console.sendString(" i=")
      console.sendHex32(nim_wifi_rf_txcal_sample_i_log[idx])
      discard console.sendString(" q=")
      console.sendHex32(nim_wifi_rf_txcal_sample_q_log[idx])
      discard console.sendString(" pwr=")
      console.sendHex32(nim_wifi_rf_txcal_sample_power_log[idx])
      discard console.sendLine("")

  proc dumpRfBzTxcalTrace() =
    discard console.sendString("[WIFI-NIMFW] bz txcal snaps=")
    console.sendHex32(nim_wifi_rf_bz_txcal_snapshot_count)
    discard console.sendString(" tag=")
    console.sendHex32(nim_wifi_rf_bz_txcal_snapshot_tag)
    discard console.sendLine("")
    let count = nim_wifi_rf_bz_txcal_snapshot_count
    let n = if count < 8'u32: count.int else: 8
    let start = if count < 8'u32: 0'u32 else: count - 8'u32
    for off in 0 ..< n:
      let seq = start + off.uint32
      let idx = int(seq and 0x7'u32)
      discard console.sendString("[WIFI-NIMFW] bz snap=")
      console.sendHex32(seq)
      discard console.sendString(" tag=")
      console.sendHex32(nim_wifi_rf_bz_txcal_tag_log[idx])
      discard console.sendString(" r48=")
      console.sendHex32(nim_wifi_rf_bz_txcal_rf48_log[idx])
      discard console.sendString(" r4c=")
      console.sendHex32(nim_wifi_rf_bz_txcal_rf4c_log[idx])
      discard console.sendString(" r88=")
      console.sendHex32(nim_wifi_rf_bz_txcal_rf88_log[idx])
      discard console.sendString(" r1600=")
      console.sendHex32(nim_wifi_rf_bz_txcal_rf1600_log[idx])
      discard console.sendString(" r162c=")
      console.sendHex32(nim_wifi_rf_bz_txcal_rf162c_log[idx])
      discard console.sendLine("")
    for idx in 0 ..< 9:
      discard console.sendString("[WIFI-NIMFW] bz rec=")
      console.sendHex32(idx.uint32)
      discard console.sendString(" w0=")
      console.sendHex32(nim_wifi_rf_bz_txcal_word0_log[idx])
      discard console.sendString(" w1=")
      console.sendHex32(nim_wifi_rf_bz_txcal_word1_log[idx])
      discard console.sendString(" ok=")
      console.sendHex32(nim_wifi_rf_bz_txcal_ok_mask_log[idx])
      discard console.sendString(" pwr=")
      console.sendHex32(nim_wifi_rf_bz_txcal_power_log[idx])
      discard console.sendLine("")

  proc dumpRfRxcalTrace() =
    discard console.sendString("[WIFI-NIMFW] rxcal live r1168=")
    console.sendHex32(cast[ptr uint32](0x20001168'u)[])
    discard console.sendString(" r116c=")
    console.sendHex32(cast[ptr uint32](0x2000116C'u)[])
    discard console.sendString(" r1170=")
    console.sendHex32(cast[ptr uint32](0x20001170'u)[])
    discard console.sendString(" r1174=")
    console.sendHex32(cast[ptr uint32](0x20001174'u)[])
    discard console.sendString(" r1178=")
    console.sendHex32(cast[ptr uint32](0x20001178'u)[])
    discard console.sendString(" r117c=")
    console.sendHex32(cast[ptr uint32](0x2000117C'u)[])
    discard console.sendString(" last0=")
    console.sendHex32(nim_wifi_rf_last_rxcal_word0)
    discard console.sendString(" last1=")
    console.sendHex32(nim_wifi_rf_last_rxcal_word1)
    discard console.sendString(" pwr=")
    console.sendHex32(nim_wifi_rf_last_rxcal_power)
    discard console.sendLine("")
    for idx in 0 ..< 4:
      discard console.sendString("[WIFI-NIMFW] rxcal rec=")
      console.sendHex32(idx.uint32)
      discard console.sendString(" w0=")
      console.sendHex32(nim_wifi_rf_rxcal_word0_log[idx])
      discard console.sendString(" w1=")
      console.sendHex32(nim_wifi_rf_rxcal_word1_log[idx])
      discard console.sendString(" pwr=")
      console.sendHex32(nim_wifi_rf_rxcal_power_log[idx])
      discard console.sendLine("")

  var nimfw_dbg_pay_backup     {.importc.}: uint32
  var nimfw_dbg_pay_desc       {.importc.}: uint32
  var nimfw_dbg_pay_payload    {.importc.}: uint32
  var nimfw_dbg_pay_empty      {.importc.}: uint32
  var nimfw_dbg_pay_nonempty   {.importc.}: uint32
  var nimfw_dbg_pay_trig       {.importc.}: uint32
  var nimfw_dbg_txtrig_entry   {.importc.}: uint32
  var nimfw_dbg_frame_get      {.importc.}: uint32
  var nimfw_dbg_cfm_push       {.importc.}: uint32
  var nimfw_dbg_cfm_evt        {.importc.}: uint32
  var nimfw_dbg_frame_cfm      {.importc.}: uint32
  var nimfw_dbg_frame_release  {.importc.}: uint32
  var nimfw_dbg_txint_enter    {.importc.}: uint32
  var nimfw_dbg_txint_last_cb  {.importc.}: uint32
  var nimfw_dbg_txint_last_fc  {.importc.}: uint32
  var nimfw_dbg_txtrig_acready {.importc.}: uint32
  var nimfw_dbg_txtrig_zero    {.importc.}: uint32
  var nimfw_dbg_txtrig_loops   {.importc.}: uint32
  var nimfw_dbg_frame_evt_enter    {.importc.}: uint32
  var nimfw_dbg_frame_evt_pop      {.importc.}: uint32
  var nimfw_dbg_frame_evt_free     {.importc.}: uint32
  var nimfw_dbg_frame_evt_usedskip {.importc.}: uint32
  var nimfw_dbg_frame_evt_cb       {.importc.}: uint32
  var nimfw_dbg_frame_get_fails    {.importc.}: uint32
  var nimfw_dbg_frame_get_invalid  {.importc.}: uint32
  var nimfw_dbg_frame_get_invalid_ptr {.importc.}: uint32
  var nimfw_dbg_frame_get_invalid_next {.importc.}: uint32
  var nimfw_dbg_frame_free_rebuild {.importc.}: uint32
  var nimfw_dbg_frame_free_reclaimed {.importc.}: uint32
  var nimfw_dbg_frame_free_push_invalid {.importc.}: uint32
  var nimfw_dbg_tx_pending_invalid {.importc.}: uint32
  var nimfw_dbg_tx_pending_invalid_ptr {.importc.}: uint32
  var nimfw_dbg_nullframe_calls    {.importc.}: uint32
  var nimfw_dbg_nullframe_caller_ra {.importc.}: uint32
  var nimfw_dbg_nullframe_desc      {.importc.}: uint32
  var nimfw_dbg_nullframe_buf       {.importc.}: uint32
  var nimfw_dbg_nullframe_fc        {.importc.}: uint32
  var nimfw_dbg_nullframe_push_rc   {.importc.}: uint32
  var nimfw_dbg_nullframe_return    {.importc.}: uint32
  var nimfw_dbg_nullframe_vif_sta   {.importc.}: uint32
  var nimfw_dbg_nullframe_fake_seen {.importc.}: uint32
  var nimfw_dbg_nullframe_fake_qidx {.importc.}: uint32
  var nimfw_dbg_nullframe_fake_head_before {.importc.}: uint32
  var nimfw_dbg_nullframe_fake_tail_before {.importc.}: uint32
  var nimfw_dbg_nullframe_fake_head_after {.importc.}: uint32
  var nimfw_dbg_nullframe_fake_tail_after {.importc.}: uint32
  var nimfw_dbg_nullframe_fake_link {.importc.}: uint32
  var nimfw_dbg_nullframe_busy_txcheck {.importc.}: uint32
  var nimfw_dbg_nullframe_busy_pscheck {.importc.}: uint32
  var nimfw_dbg_nullframe_postponed {.importc.}: uint32
  var nimfw_dbg_nullframe_queued {.importc.}: uint32
  var nimfw_keepalive_inflight {.importc.}: uint32
  var nimfw_keepalive_target_cfm {.importc.}: uint32
  var nimfw_dbg_keepalive_rc {.importc.}: uint32
  var nimfw_dbg_keepalive_post_before {.importc.}: uint32
  var nimfw_dbg_keepalive_post_after {.importc.}: uint32
  var nimfw_dbg_keepalive_txint_before {.importc.}: uint32
  var nimfw_dbg_keepalive_txint_after {.importc.}: uint32
  var nimfw_dbg_keepalive_fake_before {.importc.}: uint32
  var nimfw_dbg_keepalive_fake_after {.importc.}: uint32
  var nimfw_dbg_keepalive_pay_before {.importc.}: uint32
  var nimfw_dbg_keepalive_pay_after {.importc.}: uint32
  var nimfw_dbg_keepalive_cb_before {.importc.}: uint32
  var nimfw_dbg_keepalive_cb_after {.importc.}: uint32
  var nimfw_dbg_sta_tbtt_enter     {.importc.}: uint32
  var nimfw_dbg_sta_tbtt_assoc     {.importc.}: uint32
  var nimfw_dbg_sta_tbtt_onchan    {.importc.}: uint32
  var nimfw_dbg_sta_tbtt_pc100     {.importc.}: uint32
  var nimfw_dbg_sta_tbtt_pcmax     {.importc.}: uint32
  var nimfw_dbg_set_vif_state      {.importc.}: uint32
  var nimfw_dbg_set_vif_state_new  {.importc.}: uint32
  var nimfw_dbg_set_vif_state_act  {.importc.}: uint32
  var nimfw_dbg_assoc_done         {.importc.}: uint32
  var nimfw_dbg_assoc_rsp_status   {.importc.}: uint32
  var nimfw_dbg_assoc_rsp_count    {.importc.}: uint32
  var nimfw_dbg_assoc_rsp_len      {.importc.}: uint32
  var nimfw_dbg_assoc_rsp_b0       {.importc.}: uint32
  var nimfw_dbg_assoc_rsp_b4       {.importc.}: uint32
  var nimfw_dbg_deauth             {.importc.}: uint32
  var nimfw_dbg_connloss           {.importc.}: uint32
  var nimfw_dbg_wparsn_set         {.importc.}: uint32
  var nimfw_dbg_wparsn_len         {.importc.}: uint32
  var nimfw_dbg_wparsn_ptr         {.importc.}: uint32
  var nimfw_dbg_vif_sectype        {.importc.}: uint32
  var nimfw_dbg_conn_ind_prepath   {.importc.}: uint32
  var nimfw_dbg_vif_ielen_assoc    {.importc.}: uint32
  var nimfw_dbg_ptk_init_done      {.importc.}: uint32
  var nimfw_dbg_keydata_decrypt_calls {.importc.}: uint32
  var nimfw_dbg_keydata_decrypt_len {.importc.}: uint32
  var nimfw_dbg_keydata_decrypt_out_len {.importc.}: uint32
  var nimfw_dbg_keydata_decrypt_ok {.importc.}: uint32
  var nimfw_dbg_keydata_decrypt_fail {.importc.}: uint32
  var nimfw_dbg_postponed_service_calls {.importc.}: uint32
  var nimfw_dbg_postponed_service_sent {.importc.}: uint32
  var nimfw_dbg_postponed_reconcile {.importc.}: uint32
  var nimfw_dbg_postponed_reconcile_old {.importc.}: uint32
  var nimfw_dbg_postponed_reconcile_new {.importc.}: uint32
  var nimfw_dbg_auto_null_skipped {.importc.}: uint32
  var nimfw_dbg_tx_stalled_internal_recover {.importc.}: uint32
  var nimfw_dbg_tx_recover_ac {.importc.}: uint32
  var nimfw_dbg_tx_recover_pending {.importc.}: uint32
  var nimfw_dbg_tx_recover_current_before {.importc.}: uint32
  var nimfw_dbg_tx_recover_current_after {.importc.}: uint32
  var nimfw_dbg_tx_recover_backup_before {.importc.}: uint32
  var nimfw_dbg_tx_recover_backup_after_fake {.importc.}: uint32
  var nimfw_dbg_tx_recover_backup_after_pay {.importc.}: uint32
  var nimfw_dbg_tx_recover_desc_buf {.importc.}: uint32
  var nimfw_dbg_tx_recover_desc_cb {.importc.}: uint32
  var nimfw_wpa_pending_mask       {.importc.}: uint32
  var nimfw_dbg_sta_tbtt_skip      {.importc.}: uint32
  var nimfw_dbg_sta_tbtt_giveup    {.importc.}: uint32
  var nimfw_dbg_eapol_in           {.importc.}: uint32
  var nimfw_dbg_eapol_dropped      {.importc.}: uint32
  var nimfw_dbg_eapol_fwd          {.importc.}: uint32
  var nimfw_dbg_vif_wpastate       {.importc.}: uint32
  var nimfw_dbg_eapol_cb_inv       {.importc.}: uint32
  var nimfw_dbg_eapol_cb_null      {.importc.}: uint32
  var nimfw_dbg_sm_state_eapol     {.importc.}: uint32
  var nimfw_dbg_supp_rx_eapol      {.importc.}: uint32
  var nimfw_dbg_supp_tx_eapol      {.importc.}: uint32
  var nimfw_dbg_eth_tx_eapol       {.importc.}: uint32
  var nimfw_dbg_bl_output_eapol    {.importc.}: uint32
  var nimfw_dbg_bl_output_drop     {.importc.}: uint32
  var nimfw_dbg_eapol_tx_cb        {.importc.}: uint32
  var nimfw_dbg_wpa_deauth         {.importc.}: uint32
  var nimfw_dbg_eth_tx_ret         {.importc.}: uint32
  var nimfw_dbg_pbuf_alloc_fail    {.importc.}: uint32
  var nimfw_dbg_pbuf_take_fail     {.importc.}: uint32
  var nimfw_dbg_supp_tx_len        {.importc.}: uint32
  var nimfw_dbg_tx_flush_enter     {.importc.}: uint32
  var nimfw_dbg_tx_push_calls      {.importc.}: uint32
  var nimfw_dbg_tx_nodesc          {.importc.}: uint32
  var nimfw_dbg_tx_nobuf           {.importc.}: uint32
  var nimfw_dbg_bl_tx_cfm          {.importc.}: uint32
  var nimfw_dbg_bl_tx_cfm_cb       {.importc.}: uint32
  var nimfw_dbg_bl_tx_cfm_eapol    {.importc.}: uint32
  var nimfw_dbg_wpa_state          {.importc.}: uint32
  var nimfw_dbg_wpa_tx_state       {.importc.}: uint32
  var nimfw_dbg_wpa_rx_state       {.importc.}: uint32
  var nimfw_dbg_wpa_ptk_installed  {.importc.}: uint32
  var nimfw_dbg_crypto_captured    {.importc.}: uint32
  var nimfw_dbg_crypto_pmk_len     {.importc.}: uint32
  var nimfw_dbg_crypto_ptk_len     {.importc.}: uint32
  var nimfw_dbg_crypto_pmk         {.importc.}: array[32, uint8]
  var nimfw_dbg_crypto_own         {.importc.}: array[6, uint8]
  var nimfw_dbg_crypto_bssid       {.importc.}: array[6, uint8]
  var nimfw_dbg_crypto_snonce      {.importc.}: array[32, uint8]
  var nimfw_dbg_crypto_anonce      {.importc.}: array[32, uint8]
  var nimfw_dbg_crypto_kck         {.importc.}: array[16, uint8]
  var nimfw_dbg_crypto_sha256      {.importc.}: uint32
  var nimfw_dbg_crypto_keymgmt     {.importc.}: uint32
  var nimfw_dbg_crypto_pairwise    {.importc.}: uint32
  var nimfw_dbg_crypto_prf_data    {.importc.}: array[76, uint8]
  var nimfw_dbg_selftest_hmac      {.importc.}: array[20, uint8]
  var nimfw_dbg_selftest_ran       {.importc.}: uint32
  var nimfw_dbg_vif_mac            {.importc.}: array[6, uint8]
  var nimfw_dbg_mac_hw_lo          {.importc.}: uint32
  var nimfw_dbg_mac_hw_hi          {.importc.}: uint32
  var nimfw_dbg_m2_len             {.importc.}: uint32
  var nimfw_dbg_m2_buf             {.importc.}: array[160, uint8]
  var nimfw_dbg_mic_kck            {.importc.}: array[16, uint8]
  var nimfw_dbg_mic_computed       {.importc.}: array[16, uint8]
  var nimfw_dbg_mic_frame_len      {.importc.}: uint32
  var nimfw_dbg_mic_ver            {.importc.}: uint32
  var nimfw_dbg_sae_build          {.importc.}: uint32
  var nimfw_dbg_sae_parse          {.importc.}: uint32
  var nimfw_dbg_sae_auth_algo      {.importc.}: uint32
  var nimfw_dbg_auth_tx_len        {.importc.}: uint32
  var nimfw_dbg_auth_tx_meta       {.importc.}: uint32
  var nimfw_dbg_auth_tx_desc       {.importc.}: uint32
  var nimfw_dbg_auth_tx_raw        {.importc.}: array[96, uint8]
  var nimfw_dbg_auth_rf_pre_push   {.importc.}: array[8, uint32]
  var nimfw_dbg_auth_hw_pre_push   {.importc.}: array[32, uint32]
  var nimfw_dbg_auth_cfm_push      {.importc.}: uint32
  var nimfw_dbg_auth_cfm_frame     {.importc.}: uint32
  var nimfw_dbg_auth_cfm_evt       {.importc.}: uint32
  var nimfw_dbg_auth_cfm_status    {.importc.}: uint32
  var nimfw_dbg_auth_cfm_hw_status {.importc.}: uint32
  var nimfw_dbg_auth_cfm_desc      {.importc.}: uint32
  var nimfw_dbg_auth_cfm_meta      {.importc.}: uint32
  var nimfw_dbg_auth_cfm_fc        {.importc.}: uint32
  var nimfw_dbg_assoc_cfm_push      {.importc.}: uint32
  var nimfw_dbg_assoc_cfm_frame     {.importc.}: uint32
  var nimfw_dbg_assoc_cfm_evt       {.importc.}: uint32
  var nimfw_dbg_assoc_cfm_status    {.importc.}: uint32
  var nimfw_dbg_assoc_cfm_hw_status {.importc.}: uint32
  var nimfw_dbg_assoc_cfm_desc      {.importc.}: uint32
  var nimfw_dbg_assoc_cfm_meta      {.importc.}: uint32
  var nimfw_dbg_assoc_cfm_fc        {.importc.}: uint32
  var nimfw_dbg_scan_key_mgmt      {.importc.}: uint32
  var nimfw_dbg_scan_at            {.importc.}: uint32
  var nimfw_dbg_scan_smf           {.importc.}: uint32
  var nimfw_dbg_scan_caps          {.importc.}: uint32
  var nimfw_dbg_scan_ssid_last     {.importc.}: uint32
  var nimfw_dbg_bss_in             {.importc.}: uint32
  var nimfw_dbg_bss_ssid_result    {.importc.}: uint32
  var nimfw_dbg_bss_directed       {.importc.}: uint32
  var nimfw_dbg_bss_out            {.importc.}: uint32
  var nimfw_dbg_bss_chan_fix_meta  {.importc.}: uint32
  var nimfw_dbg_bss_chan_fix_ptr   {.importc.}: uint32
  var nimfw_dbg_bss_chan_fix_raw   {.importc.}: uint32
  var nimfw_dbg_bss_rx_freq        {.importc.}: uint32
  var nimfw_dbg_bss_ds_freq        {.importc.}: uint32
  var nimfw_dbg_bss_selected_freq  {.importc.}: uint32
  var nimfw_dbg_sta_tx_channel_source {.importc.}: uint32
  var nimfw_dbg_sta_tx_channel_req0 {.importc.}: uint32
  var nimfw_dbg_sta_tx_channel_req1 {.importc.}: uint32
  var nimfw_dbg_sta_tx_channel_vif  {.importc.}: uint32
  var nimfw_dbg_sm_chan_ctx_req0    {.importc.}: uint32
  var nimfw_dbg_sm_chan_ctx_req1    {.importc.}: uint32
  var nimfw_dbg_sm_chan_ctx_ptrs    {.importc.}: uint32
  var nimfw_dbg_sm_chan_ctx_result  {.importc.}: uint32
  var nimfw_dbg_ssid_search        {.importc.}: uint32
  var nimfw_dbg_ssid_entries       {.importc.}: uint32
  var nimfw_dbg_ssid_hits          {.importc.}: uint32
  var nimfw_dbg_m4_tx_state        {.importc.}: uint32
  var nimfw_dbg_m4_cb_ptr          {.importc.}: uint32
  var nimfw_dbg_cfm_cb_ptr_last    {.importc.}: uint32
  var nimfw_dbg_cfm_last_ethertype {.importc.}: uint32
  var nimfw_dbg_send_4of4_tx       {.importc.}: uint32
  var nimfw_dbg_send_4of4_cb       {.importc.}: uint32
  var nimfw_dbg_install_ptk        {.importc.}: uint32
  var nimfw_dbg_eapol_cfm_status   {.importc.}: uint32
  var nimfw_dbg_eapol_cfm_count    {.importc.}: uint32
  var nimfw_dbg_eapol_cfm_ack_ok   {.importc.}: uint32
  var nimfw_dbg_eapol_cfm_ack_fail {.importc.}: uint32
  var nimfw_dbg_eapol_cfm_status_log {.importc.}: array[4, uint32]
  var nimfw_dbg_eapol_cfm_meta_log {.importc.}: array[4, uint32]
  var nimfw_dbg_eapol_cfm_key_log {.importc.}: array[4, uint32]
  var nimfw_dbg_eapol_cfm_replay_log {.importc.}: array[4, uint32]
  var nimfw_dbg_eapol_cfm_cb_log {.importc.}: array[4, uint32]
  var nimfw_dbg_disconnect_req     {.importc.}: uint32
  var nimfw_dbg_disconnect_req_state {.importc.}: uint32
  var nimfw_dbg_disconnect_process {.importc.}: uint32
  var nimfw_dbg_disconnect_ind     {.importc.}: uint32
  var nimfw_dbg_sm_state_final     {.importc.}: uint32
  # Dump disconnect counters after wifiDisconnect is attempted, since the
  # connect-time dumpNimFwTxCounters() fires before disconnect.

  proc dumpHexBytes(prefix: string, p: ptr UncheckedArray[uint8], n: int) =
    discard console.sendString(prefix)
    # Pack bytes into 4-byte words and use sendHex32 for clean hex output.
    var i = 0
    while i + 4 <= n:
      let w = p[i].uint32 or (p[i+1].uint32 shl 8) or
              (p[i+2].uint32 shl 16) or (p[i+3].uint32 shl 24)
      console.sendHex32(w)
      i += 4
    # Tail bytes (if any) — handle leftover 1..3 bytes
    if i < n:
      var w = 0'u32
      var shift = 0
      while i < n:
        w = w or (p[i].uint32 shl shift)
        shift += 8
        inc i
      console.sendHex32(w)
    discard console.sendLine("")

  proc ke_state_get(taskId: uint16): uint16 {.importc, cdecl.}

  proc rfReg(regAddr: uint): uint32 {.inline.} =
    cast[ptr uint32](regAddr)[]

  proc dumpNimFwDisconnectCounters() =
    nimfw_dbg_sm_state_final = ke_state_get(4'u16).uint32  # TASK_SM = 4
    discard console.sendString("[DISCONNECT] req=")
    console.sendHex32(nimfw_dbg_disconnect_req)
    discard console.sendString(" req_state=")
    console.sendHex32(nimfw_dbg_disconnect_req_state)
    discard console.sendString(" process=")
    console.sendHex32(nimfw_dbg_disconnect_process)
    discard console.sendString(" ind=")
    console.sendHex32(nimfw_dbg_disconnect_ind)
    discard console.sendString(" sm_state_final=")
    console.sendHex32(nimfw_dbg_sm_state_final)
    discard console.sendLine("")

  proc dumpNimFwTxCounters() =
    discard console.sendString("[WIFI-NIMFW] tx_counters frame_get=")
    console.sendHex32(nimfw_dbg_frame_get)
    discard console.sendString(" pay_backup=")
    console.sendHex32(nimfw_dbg_pay_backup)
    discard console.sendString(" pay_desc=")
    console.sendHex32(nimfw_dbg_pay_desc)
    discard console.sendString(" pay_payload=")
    console.sendHex32(nimfw_dbg_pay_payload)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters empty=")
    console.sendHex32(nimfw_dbg_pay_empty)
    discard console.sendString(" nonempty=")
    console.sendHex32(nimfw_dbg_pay_nonempty)
    discard console.sendString(" trig_last=")
    console.sendHex32(nimfw_dbg_pay_trig)
    discard console.sendString(" txtrig_entry=")
    console.sendHex32(nimfw_dbg_txtrig_entry)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters txtrig_loops=")
    console.sendHex32(nimfw_dbg_txtrig_loops)
    discard console.sendString(" txtrig_zero=")
    console.sendHex32(nimfw_dbg_txtrig_zero)
    discard console.sendString(" txtrig_acready=")
    console.sendHex32(nimfw_dbg_txtrig_acready)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters cfm_push=")
    console.sendHex32(nimfw_dbg_cfm_push)
    discard console.sendString(" cfm_evt=")
    console.sendHex32(nimfw_dbg_cfm_evt)
    discard console.sendString(" frame_cfm=")
    console.sendHex32(nimfw_dbg_frame_cfm)
    discard console.sendString(" frame_release=")
    console.sendHex32(nimfw_dbg_frame_release)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters txint_enter=")
    console.sendHex32(nimfw_dbg_txint_enter)
    discard console.sendString(" last_cb=")
    console.sendHex32(nimfw_dbg_txint_last_cb)
    discard console.sendString(" last_fc=")
    console.sendHex32(nimfw_dbg_txint_last_fc)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters auth_len=")
    console.sendHex32(nimfw_dbg_auth_tx_len)
    discard console.sendString(" meta=")
    console.sendHex32(nimfw_dbg_auth_tx_meta)
    discard console.sendString(" desc=")
    console.sendHex32(nimfw_dbg_auth_tx_desc)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters auth_cfm=")
    console.sendHex32((nimfw_dbg_auth_cfm_push and 0xff'u32) or
      ((nimfw_dbg_auth_cfm_frame and 0xff'u32) shl 8) or
      ((nimfw_dbg_auth_cfm_evt and 0xff'u32) shl 16))
    discard console.sendString(" st=")
    console.sendHex32(nimfw_dbg_auth_cfm_status)
    discard console.sendString(" hw=")
    console.sendHex32(nimfw_dbg_auth_cfm_hw_status)
    discard console.sendString(" desc=")
    console.sendHex32(nimfw_dbg_auth_cfm_desc)
    discard console.sendString(" meta=")
    console.sendHex32(nimfw_dbg_auth_cfm_meta)
    discard console.sendString(" fc=")
    console.sendHex32(nimfw_dbg_auth_cfm_fc)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters sta_tx_chan src=")
    console.sendHex32(nimfw_dbg_sta_tx_channel_source)
    discard console.sendString(" req0=")
    console.sendHex32(nimfw_dbg_sta_tx_channel_req0)
    discard console.sendString(" req1=")
    console.sendHex32(nimfw_dbg_sta_tx_channel_req1)
    discard console.sendString(" vif=")
    console.sendHex32(nimfw_dbg_sta_tx_channel_vif)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters sm_chan_ctx req0=")
    console.sendHex32(nimfw_dbg_sm_chan_ctx_req0)
    discard console.sendString(" req1=")
    console.sendHex32(nimfw_dbg_sm_chan_ctx_req1)
    discard console.sendString(" ptrs=")
    console.sendHex32(nimfw_dbg_sm_chan_ctx_ptrs)
    discard console.sendString(" result=")
    console.sendHex32(nimfw_dbg_sm_chan_ctx_result)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters assoc_cfm=")
    console.sendHex32((nimfw_dbg_assoc_cfm_push and 0xff'u32) or
      ((nimfw_dbg_assoc_cfm_frame and 0xff'u32) shl 8) or
      ((nimfw_dbg_assoc_cfm_evt and 0xff'u32) shl 16))
    discard console.sendString(" st=")
    console.sendHex32(nimfw_dbg_assoc_cfm_status)
    discard console.sendString(" hw=")
    console.sendHex32(nimfw_dbg_assoc_cfm_hw_status)
    discard console.sendString(" desc=")
    console.sendHex32(nimfw_dbg_assoc_cfm_desc)
    discard console.sendString(" meta=")
    console.sendHex32(nimfw_dbg_assoc_cfm_meta)
    discard console.sendString(" fc=")
    console.sendHex32(nimfw_dbg_assoc_cfm_fc)
    discard console.sendLine("")
    dumpHexBytes("[WIFI-NIMFW] tx_counters auth_raw=",
                 cast[ptr UncheckedArray[uint8]](addr nimfw_dbg_auth_tx_raw[0]),
                 32)
    discard console.sendString("[WIFI-NIMFW] tx_counters auth_host desc4=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[0])
    discard console.sendString(" cfm=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[1])
    discard console.sendString(" flen_seq=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[2])
    discard console.sendString(" idx=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[3])
    discard console.sendString(" buf0=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[4])
    discard console.sendString(" blen0=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[5])
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters auth_host ptime=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[6])
    discard console.sendString(" policy=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[7])
    discard console.sendString(" hqs=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[8])
    discard console.sendString(" txflags=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[9])
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters auth_thd st=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[10])
    discard console.sendString(" pstart=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[11])
    discard console.sendString(" pend=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[12])
    discard console.sendString(" flen=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[13])
    discard console.sendString(" w32=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[14])
    discard console.sendString(" w36=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[15])
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters auth_thd chain=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[16])
    discard console.sendString(" w44=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[17])
    discard console.sendString(" w48=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[18])
    discard console.sendString(" ctrl=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[19])
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters auth_thd w52=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[20])
    discard console.sendString(" w56=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[21])
    discard console.sendString(" cfm=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[22])
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters auth_rate magic=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[23])
    discard console.sendString(" ntx=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[24])
    discard console.sendString(" bw=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[25])
    discard console.sendString(" policy=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[26])
    discard console.sendString(" rate=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[27])
    discard console.sendString(" pwr=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[28])
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters auth_rate w40=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[29])
    discard console.sendString(" w44=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[30])
    discard console.sendString(" w48=")
    console.sendHex32(nimfw_dbg_auth_hw_pre_push[31])
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters rf_pre_push r70=")
    console.sendHex32(nimfw_dbg_auth_rf_pre_push[0])
    discard console.sendString(" r88=")
    console.sendHex32(nimfw_dbg_auth_rf_pre_push[1])
    discard console.sendString(" r8c=")
    console.sendHex32(nimfw_dbg_auth_rf_pre_push[2])
    discard console.sendString(" rfa0=")
    console.sendHex32(nimfw_dbg_auth_rf_pre_push[3])
    discard console.sendString(" rfb4=")
    console.sendHex32(nimfw_dbg_auth_rf_pre_push[4])
    discard console.sendString(" rfbc=")
    console.sendHex32(nimfw_dbg_auth_rf_pre_push[5])
    discard console.sendString(" rfd0=")
    console.sendHex32(nimfw_dbg_auth_rf_pre_push[6])
    discard console.sendString(" r1600=")
    console.sendHex32(nimfw_dbg_auth_rf_pre_push[7])
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters rf_live r70=")
    console.sendHex32(rfReg(0x20001070'u))
    discard console.sendString(" r88=")
    console.sendHex32(rfReg(0x20001088'u))
    discard console.sendString(" r8c=")
    console.sendHex32(rfReg(0x2000108C'u))
    discard console.sendString(" rfa0=")
    console.sendHex32(rfReg(0x200010A0'u))
    discard console.sendString(" rfb4=")
    console.sendHex32(rfReg(0x200010B4'u))
    discard console.sendString(" rfbc=")
    console.sendHex32(rfReg(0x200010BC'u))
    discard console.sendString(" rfd0=")
    console.sendHex32(rfReg(0x200010D0'u))
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters rf_live r1600=")
    console.sendHex32(rfReg(0x20001600'u))
    discard console.sendString(" r1608=")
    console.sendHex32(rfReg(0x20001608'u))
    discard console.sendString(" r1618=")
    console.sendHex32(rfReg(0x20001618'u))
    discard console.sendString(" r162c=")
    console.sendHex32(rfReg(0x2000162C'u))
    discard console.sendString(" p820=")
    console.sendHex32(rfReg(0x24C00820'u))
    discard console.sendString(" p824=")
    console.sendHex32(rfReg(0x24C00824'u))
    discard console.sendString(" p830=")
    console.sendHex32(rfReg(0x24C00830'u))
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters nullframe_fake_seen=")
    console.sendHex32(nimfw_dbg_nullframe_fake_seen)
    discard console.sendString(" qidx=")
    console.sendHex32(nimfw_dbg_nullframe_fake_qidx)
    discard console.sendString(" link=")
    console.sendHex32(nimfw_dbg_nullframe_fake_link)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters nullframe_fake_head_before=")
    console.sendHex32(nimfw_dbg_nullframe_fake_head_before)
    discard console.sendString(" tail_before=")
    console.sendHex32(nimfw_dbg_nullframe_fake_tail_before)
    discard console.sendString(" head_after=")
    console.sendHex32(nimfw_dbg_nullframe_fake_head_after)
    discard console.sendString(" tail_after=")
    console.sendHex32(nimfw_dbg_nullframe_fake_tail_after)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters nullframe_calls=")
    console.sendHex32(nimfw_dbg_nullframe_calls)
    discard console.sendString(" nullframe_ra=")
    console.sendHex32(nimfw_dbg_nullframe_caller_ra)
    discard console.sendString(" framegetfails=")
    console.sendHex32(nimfw_dbg_frame_get_fails)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters frame_invalid=")
    console.sendHex32(nimfw_dbg_frame_get_invalid)
    discard console.sendString(" ptr=")
    console.sendHex32(nimfw_dbg_frame_get_invalid_ptr)
    discard console.sendString(" next=")
    console.sendHex32(nimfw_dbg_frame_get_invalid_next)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters frame_rebuild=")
    console.sendHex32(nimfw_dbg_frame_free_rebuild)
    discard console.sendString(" reclaimed=")
    console.sendHex32(nimfw_dbg_frame_free_reclaimed)
    discard console.sendString(" push_invalid=")
    console.sendHex32(nimfw_dbg_frame_free_push_invalid)
    discard console.sendString(" pending_invalid=")
    console.sendHex32(nimfw_dbg_tx_pending_invalid)
    discard console.sendString(" pending_ptr=")
    console.sendHex32(nimfw_dbg_tx_pending_invalid_ptr)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters nullframe_desc=")
    console.sendHex32(nimfw_dbg_nullframe_desc)
    discard console.sendString(" buf=")
    console.sendHex32(nimfw_dbg_nullframe_buf)
    discard console.sendString(" fc=")
    console.sendHex32(nimfw_dbg_nullframe_fc)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters nullframe_push_rc=")
    console.sendHex32(nimfw_dbg_nullframe_push_rc)
    discard console.sendString(" return=")
    console.sendHex32(nimfw_dbg_nullframe_return)
    discard console.sendString(" vif_sta=")
    console.sendHex32(nimfw_dbg_nullframe_vif_sta)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters keepalive_busy_txcheck=")
    console.sendHex32(nimfw_dbg_nullframe_busy_txcheck)
    discard console.sendString(" busy_inflight=")
    console.sendHex32(nimfw_dbg_nullframe_busy_pscheck)
    discard console.sendString(" postponed=")
    console.sendHex32(nimfw_dbg_nullframe_postponed)
    discard console.sendString(" queued=")
    console.sendHex32(nimfw_dbg_nullframe_queued)
    discard console.sendString(" inflight=")
    console.sendHex32(nimfw_keepalive_inflight)
    discard console.sendString(" target=")
    console.sendHex32(nimfw_keepalive_target_cfm)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters keepalive_call rc=")
    console.sendHex32(nimfw_dbg_keepalive_rc)
    discard console.sendString(" post=")
    console.sendHex32(nimfw_dbg_keepalive_post_before)
    discard console.sendString("->")
    console.sendHex32(nimfw_dbg_keepalive_post_after)
    discard console.sendString(" txint=")
    console.sendHex32(nimfw_dbg_keepalive_txint_before)
    discard console.sendString("->")
    console.sendHex32(nimfw_dbg_keepalive_txint_after)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters keepalive_call fake=")
    console.sendHex32(nimfw_dbg_keepalive_fake_before)
    discard console.sendString("->")
    console.sendHex32(nimfw_dbg_keepalive_fake_after)
    discard console.sendString(" pay=")
    console.sendHex32(nimfw_dbg_keepalive_pay_before)
    discard console.sendString("->")
    console.sendHex32(nimfw_dbg_keepalive_pay_after)
    discard console.sendString(" cb=")
    console.sendHex32(nimfw_dbg_keepalive_cb_before)
    discard console.sendString("->")
    console.sendHex32(nimfw_dbg_keepalive_cb_after)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters set_vif_state=")
    console.sendHex32(nimfw_dbg_set_vif_state)
    discard console.sendString(" new=")
    console.sendHex32(nimfw_dbg_set_vif_state_new)
    discard console.sendString(" act=")
    console.sendHex32(nimfw_dbg_set_vif_state_act)
    discard console.sendString(" assoc_done=")
    console.sendHex32(nimfw_dbg_assoc_done)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters assoc_rsp_cnt=")
    console.sendHex32(nimfw_dbg_assoc_rsp_count)
    discard console.sendString(" status=")
    console.sendHex32(nimfw_dbg_assoc_rsp_status)
    discard console.sendString(" len=")
    console.sendHex32(nimfw_dbg_assoc_rsp_len)
    discard console.sendString(" b0=")
    console.sendHex32(nimfw_dbg_assoc_rsp_b0)
    discard console.sendString(" b4=")
    console.sendHex32(nimfw_dbg_assoc_rsp_b4)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters deauth=")
    console.sendHex32(nimfw_dbg_deauth)
    discard console.sendString(" connloss=")
    console.sendHex32(nimfw_dbg_connloss)
    discard console.sendString(" wparsn_set=")
    console.sendHex32(nimfw_dbg_wparsn_set)
    discard console.sendString(" len=")
    console.sendHex32(nimfw_dbg_wparsn_len)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters sectype=")
    console.sendHex32(nimfw_dbg_vif_sectype)
    discard console.sendString(" prepath=")
    console.sendHex32(nimfw_dbg_conn_ind_prepath)
    discard console.sendString(" assoc_ielen=")
    console.sendHex32(nimfw_dbg_vif_ielen_assoc)
    discard console.sendString(" ptk_done=")
    console.sendHex32(nimfw_dbg_ptk_init_done)
    discard console.sendString(" kde_calls=")
    console.sendHex32(nimfw_dbg_keydata_decrypt_calls)
    discard console.sendString(" kde_ok=")
    console.sendHex32(nimfw_dbg_keydata_decrypt_ok)
    discard console.sendString(" kde_fail=")
    console.sendHex32(nimfw_dbg_keydata_decrypt_fail)
    discard console.sendString(" wpa_mask=")
    console.sendHex32(nimfw_wpa_pending_mask)
    discard console.sendString(" tbtt_skip=")
    console.sendHex32(nimfw_dbg_sta_tbtt_skip)
    discard console.sendString(" giveup=")
    console.sendHex32(nimfw_dbg_sta_tbtt_giveup)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters eapol_in=")
    console.sendHex32(nimfw_dbg_eapol_in)
    discard console.sendString(" dropped=")
    console.sendHex32(nimfw_dbg_eapol_dropped)
    discard console.sendString(" fwd=")
    console.sendHex32(nimfw_dbg_eapol_fwd)
    discard console.sendString(" wpa_state=")
    console.sendHex32(nimfw_dbg_vif_wpastate)
    discard console.sendString(" cb_inv=")
    console.sendHex32(nimfw_dbg_eapol_cb_inv)
    discard console.sendString(" cb_null=")
    console.sendHex32(nimfw_dbg_eapol_cb_null)
    discard console.sendString(" sm_state=")
    console.sendHex32(nimfw_dbg_sm_state_eapol)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters supp_rx=")
    console.sendHex32(nimfw_dbg_supp_rx_eapol)
    discard console.sendString(" supp_tx=")
    console.sendHex32(nimfw_dbg_supp_tx_eapol)
    discard console.sendString(" eth_tx=")
    console.sendHex32(nimfw_dbg_eth_tx_eapol)
    discard console.sendString(" bl_out_eapol=")
    console.sendHex32(nimfw_dbg_bl_output_eapol)
    discard console.sendString(" out_drop=")
    console.sendHex32(nimfw_dbg_bl_output_drop)
    discard console.sendString(" tx_cb=")
    console.sendHex32(nimfw_dbg_eapol_tx_cb)
    discard console.sendString(" deauth=")
    console.sendHex32(nimfw_dbg_wpa_deauth)
    discard console.sendString(" eth_ret=")
    console.sendHex32(nimfw_dbg_eth_tx_ret)
    discard console.sendString(" alloc_fail=")
    console.sendHex32(nimfw_dbg_pbuf_alloc_fail)
    discard console.sendString(" take_fail=")
    console.sendHex32(nimfw_dbg_pbuf_take_fail)
    discard console.sendString(" supp_len=")
    console.sendHex32(nimfw_dbg_supp_tx_len)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters tx_flush=")
    console.sendHex32(nimfw_dbg_tx_flush_enter)
    discard console.sendString(" tx_push=")
    console.sendHex32(nimfw_dbg_tx_push_calls)
    discard console.sendString(" nodesc=")
    console.sendHex32(nimfw_dbg_tx_nodesc)
    discard console.sendString(" nobuf=")
    console.sendHex32(nimfw_dbg_tx_nobuf)
    discard console.sendString(" tx_cfm=")
    console.sendHex32(nimfw_dbg_bl_tx_cfm)
    discard console.sendString(" cfm_cb=")
    console.sendHex32(nimfw_dbg_bl_tx_cfm_cb)
    discard console.sendString(" cfm_eapol=")
    console.sendHex32(nimfw_dbg_bl_tx_cfm_eapol)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters wpa_state=")
    console.sendHex32(nimfw_dbg_wpa_state)
    discard console.sendString(" wpa_tx_state=")
    console.sendHex32(nimfw_dbg_wpa_tx_state)
    discard console.sendString(" wpa_rx_state=")
    console.sendHex32(nimfw_dbg_wpa_rx_state)
    discard console.sendString(" ptk_inst=")
    console.sendHex32(nimfw_dbg_wpa_ptk_installed)
    discard console.sendString(" kde_len=")
    console.sendHex32(nimfw_dbg_keydata_decrypt_len)
    discard console.sendString(" kde_out=")
    console.sendHex32(nimfw_dbg_keydata_decrypt_out_len)
    discard console.sendString(" crypto_cap=")
    console.sendHex32(nimfw_dbg_crypto_captured)
    discard console.sendString(" pmk_len=")
    console.sendHex32(nimfw_dbg_crypto_pmk_len)
    discard console.sendString(" ptk_len=")
    console.sendHex32(nimfw_dbg_crypto_ptk_len)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters postponed_reconcile=")
    console.sendHex32(nimfw_dbg_postponed_reconcile)
    discard console.sendString(" old=")
    console.sendHex32(nimfw_dbg_postponed_reconcile_old)
    discard console.sendString(" new=")
    console.sendHex32(nimfw_dbg_postponed_reconcile_new)
    discard console.sendString(" service_calls=")
    console.sendHex32(nimfw_dbg_postponed_service_calls)
    discard console.sendString(" service_sent=")
    console.sendHex32(nimfw_dbg_postponed_service_sent)
    discard console.sendString(" auto_null_skip=")
    console.sendHex32(nimfw_dbg_auto_null_skipped)
    discard console.sendString(" tx_recover=")
    console.sendHex32(nimfw_dbg_tx_stalled_internal_recover)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters recover ac=")
    console.sendHex32(nimfw_dbg_tx_recover_ac)
    discard console.sendString(" pending=")
    console.sendHex32(nimfw_dbg_tx_recover_pending)
    discard console.sendString(" current=")
    console.sendHex32(nimfw_dbg_tx_recover_current_before)
    discard console.sendString("->")
    console.sendHex32(nimfw_dbg_tx_recover_current_after)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters recover backup=")
    console.sendHex32(nimfw_dbg_tx_recover_backup_before)
    discard console.sendString("->")
    console.sendHex32(nimfw_dbg_tx_recover_backup_after_fake)
    discard console.sendString("->")
    console.sendHex32(nimfw_dbg_tx_recover_backup_after_pay)
    discard console.sendString(" desc_buf=")
    console.sendHex32(nimfw_dbg_tx_recover_desc_buf)
    discard console.sendString(" cb=")
    console.sendHex32(nimfw_dbg_tx_recover_desc_cb)
    discard console.sendLine("")
    if nimfw_dbg_crypto_captured != 0:
      discard console.sendString("[CRYPTO] sha256=")
      console.sendHex32(nimfw_dbg_crypto_sha256)
      discard console.sendString(" keymgmt=")
      console.sendHex32(nimfw_dbg_crypto_keymgmt)
      discard console.sendString(" pairwise=")
      console.sendHex32(nimfw_dbg_crypto_pairwise)
      discard console.sendLine("")
      dumpHexBytes("[CRYPTO] pmk=",
                   cast[ptr UncheckedArray[uint8]](addr nimfw_dbg_crypto_pmk[0]), 32)
      dumpHexBytes("[CRYPTO] own=",
                   cast[ptr UncheckedArray[uint8]](addr nimfw_dbg_crypto_own[0]), 6)
      dumpHexBytes("[CRYPTO] bssid=",
                   cast[ptr UncheckedArray[uint8]](addr nimfw_dbg_crypto_bssid[0]), 6)
      dumpHexBytes("[CRYPTO] snonce=",
                   cast[ptr UncheckedArray[uint8]](addr nimfw_dbg_crypto_snonce[0]), 32)
      dumpHexBytes("[CRYPTO] anonce=",
                   cast[ptr UncheckedArray[uint8]](addr nimfw_dbg_crypto_anonce[0]), 32)
      dumpHexBytes("[CRYPTO] kck=",
                   cast[ptr UncheckedArray[uint8]](addr nimfw_dbg_crypto_kck[0]), 16)
      dumpHexBytes("[CRYPTO] prf_data=",
                   cast[ptr UncheckedArray[uint8]](addr nimfw_dbg_crypto_prf_data[0]), 76)
      discard console.sendString("[CRYPTO] selftest_ran=")
      console.sendHex32(nimfw_dbg_selftest_ran)
      discard console.sendLine("")
      dumpHexBytes("[CRYPTO] selftest_hmac=",
                   cast[ptr UncheckedArray[uint8]](addr nimfw_dbg_selftest_hmac[0]), 20)
      dumpHexBytes("[CRYPTO] vif_mac=",
                   cast[ptr UncheckedArray[uint8]](addr nimfw_dbg_vif_mac[0]), 6)
      discard console.sendString("[CRYPTO] mac_hw_lo=")
      console.sendHex32(nimfw_dbg_mac_hw_lo)
      discard console.sendString(" mac_hw_hi=")
      console.sendHex32(nimfw_dbg_mac_hw_hi)
      discard console.sendString(" m2_len=")
      console.sendHex32(nimfw_dbg_m2_len)
      discard console.sendLine("")
      let m2_n = (if nimfw_dbg_m2_len < 160'u32: nimfw_dbg_m2_len.int else: 160)
      dumpHexBytes("[CRYPTO] m2=",
                   cast[ptr UncheckedArray[uint8]](addr nimfw_dbg_m2_buf[0]), m2_n)
      discard console.sendString("[CRYPTO] mic_frame_len=")
      console.sendHex32(nimfw_dbg_mic_frame_len)
      discard console.sendString(" mic_ver=")
      console.sendHex32(nimfw_dbg_mic_ver)
      discard console.sendLine("")
      dumpHexBytes("[CRYPTO] mic_kck=",
                   cast[ptr UncheckedArray[uint8]](addr nimfw_dbg_mic_kck[0]), 16)
      dumpHexBytes("[CRYPTO] mic_out=",
                   cast[ptr UncheckedArray[uint8]](addr nimfw_dbg_mic_computed[0]), 16)
      discard console.sendString("[SAE] build=")
      console.sendHex32(nimfw_dbg_sae_build)
      discard console.sendString(" parse=")
      console.sendHex32(nimfw_dbg_sae_parse)
      discard console.sendString(" auth_algo=")
      console.sendHex32(nimfw_dbg_sae_auth_algo)
      discard console.sendLine("")
      discard console.sendString("[SAE] scan_keymgmt=")
      console.sendHex32(nimfw_dbg_scan_key_mgmt)
      discard console.sendString(" scan_aT=")
      console.sendHex32(nimfw_dbg_scan_at)
      discard console.sendString(" scan_smF=")
      console.sendHex32(nimfw_dbg_scan_smf)
      discard console.sendString(" scan_caps=")
      console.sendHex32(nimfw_dbg_scan_caps)
      discard console.sendLine("")
      discard console.sendString("[BSS] in=")
      console.sendHex32(nimfw_dbg_bss_in)
      discard console.sendString(" ssid_result=")
      console.sendHex32(nimfw_dbg_bss_ssid_result)
      discard console.sendString(" directed=")
      console.sendHex32(nimfw_dbg_bss_directed)
      discard console.sendString(" out=")
      console.sendHex32(nimfw_dbg_bss_out)
      discard console.sendLine("")
      discard console.sendString("[BSS] chan_meta=")
      console.sendHex32(nimfw_dbg_bss_chan_fix_meta)
      discard console.sendString(" chan_ptr=")
      console.sendHex32(nimfw_dbg_bss_chan_fix_ptr)
      discard console.sendString(" raw=")
      console.sendHex32(nimfw_dbg_bss_chan_fix_raw)
      discard console.sendString(" ssid_last=")
      console.sendHex32(nimfw_dbg_scan_ssid_last)
      discard console.sendLine("")
      discard console.sendString("[BSS] freq rx=")
      console.sendHex32(nimfw_dbg_bss_rx_freq)
      discard console.sendString(" ds=")
      console.sendHex32(nimfw_dbg_bss_ds_freq)
      discard console.sendString(" selected=")
      console.sendHex32(nimfw_dbg_bss_selected_freq)
      discard console.sendLine("")
      discard console.sendString("[BSS] ssid_search=")
      console.sendHex32(nimfw_dbg_ssid_search)
      discard console.sendString(" entries=")
      console.sendHex32(nimfw_dbg_ssid_entries)
      discard console.sendString(" hits=")
      console.sendHex32(nimfw_dbg_ssid_hits)
      discard console.sendLine("")
    discard console.sendString("[BSS] in=")
    console.sendHex32(nimfw_dbg_bss_in)
    discard console.sendString(" ssid_result=")
    console.sendHex32(nimfw_dbg_bss_ssid_result)
    discard console.sendString(" directed=")
    console.sendHex32(nimfw_dbg_bss_directed)
    discard console.sendString(" out=")
    console.sendHex32(nimfw_dbg_bss_out)
    discard console.sendLine("")
    discard console.sendString("[BSS] chan_meta=")
    console.sendHex32(nimfw_dbg_bss_chan_fix_meta)
    discard console.sendString(" chan_ptr=")
    console.sendHex32(nimfw_dbg_bss_chan_fix_ptr)
    discard console.sendString(" raw=")
    console.sendHex32(nimfw_dbg_bss_chan_fix_raw)
    discard console.sendString(" ssid_last=")
    console.sendHex32(nimfw_dbg_scan_ssid_last)
    discard console.sendLine("")
    discard console.sendString("[BSS] freq rx=")
    console.sendHex32(nimfw_dbg_bss_rx_freq)
    discard console.sendString(" ds=")
    console.sendHex32(nimfw_dbg_bss_ds_freq)
    discard console.sendString(" selected=")
    console.sendHex32(nimfw_dbg_bss_selected_freq)
    discard console.sendLine("")
    discard console.sendString("[BSS] ssid_search=")
    console.sendHex32(nimfw_dbg_ssid_search)
    discard console.sendString(" entries=")
    console.sendHex32(nimfw_dbg_ssid_entries)
    discard console.sendString(" hits=")
    console.sendHex32(nimfw_dbg_ssid_hits)
    discard console.sendLine("")
    discard console.sendString("[M4] tx_state=")
    console.sendHex32(nimfw_dbg_m4_tx_state)
    discard console.sendString(" cb_ptr_supp=")
    console.sendHex32(nimfw_dbg_m4_cb_ptr)
    discard console.sendString(" cb_ptr_cfm=")
    console.sendHex32(nimfw_dbg_cfm_cb_ptr_last)
    discard console.sendString(" cfm_et=")
    console.sendHex32(nimfw_dbg_cfm_last_ethertype)
    discard console.sendString(" 4of4_tx=")
    console.sendHex32(nimfw_dbg_send_4of4_tx)
    discard console.sendString(" 4of4_cb=")
    console.sendHex32(nimfw_dbg_send_4of4_cb)
    discard console.sendString(" install=")
    console.sendHex32(nimfw_dbg_install_ptk)
    discard console.sendLine("")
    discard console.sendString("[EAPOL-CFM] count=")
    console.sendHex32(nimfw_dbg_eapol_cfm_count)
    discard console.sendString(" ack_ok=")
    console.sendHex32(nimfw_dbg_eapol_cfm_ack_ok)
    discard console.sendString(" ack_fail=")
    console.sendHex32(nimfw_dbg_eapol_cfm_ack_fail)
    discard console.sendString(" last_status=")
    console.sendHex32(nimfw_dbg_eapol_cfm_status)
    discard console.sendLine("")
    for eapolCfmLogIndex in 0 ..< 4:
      discard console.sendString("[EAPOL-CFM] log")
      console.sendHex32(eapolCfmLogIndex.uint32)
      discard console.sendString(" status=")
      console.sendHex32(nimfw_dbg_eapol_cfm_status_log[eapolCfmLogIndex])
      discard console.sendString(" meta=")
      console.sendHex32(nimfw_dbg_eapol_cfm_meta_log[eapolCfmLogIndex])
      discard console.sendString(" key=")
      console.sendHex32(nimfw_dbg_eapol_cfm_key_log[eapolCfmLogIndex])
      discard console.sendString(" replay=")
      console.sendHex32(nimfw_dbg_eapol_cfm_replay_log[eapolCfmLogIndex])
      discard console.sendString(" cb=")
      console.sendHex32(nimfw_dbg_eapol_cfm_cb_log[eapolCfmLogIndex])
      discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters sta_tbtt_enter=")
    console.sendHex32(nimfw_dbg_sta_tbtt_enter)
    discard console.sendString(" assoc=")
    console.sendHex32(nimfw_dbg_sta_tbtt_assoc)
    discard console.sendString(" onchan=")
    console.sendHex32(nimfw_dbg_sta_tbtt_onchan)
    discard console.sendString(" pc100=")
    console.sendHex32(nimfw_dbg_sta_tbtt_pc100)
    discard console.sendString(" pcmax=")
    console.sendHex32(nimfw_dbg_sta_tbtt_pcmax)
    discard console.sendLine("")
    discard console.sendString("[WIFI-NIMFW] tx_counters frame_evt_enter=")
    console.sendHex32(nimfw_dbg_frame_evt_enter)
    discard console.sendString(" pop=")
    console.sendHex32(nimfw_dbg_frame_evt_pop)
    discard console.sendString(" free=")
    console.sendHex32(nimfw_dbg_frame_evt_free)
    discard console.sendString(" usedskip=")
    console.sendHex32(nimfw_dbg_frame_evt_usedskip)
    discard console.sendString(" cb=")
    console.sendHex32(nimfw_dbg_frame_evt_cb)
    discard console.sendLine("")

  proc dumpWifiRxDebug() =
    dumpWifiMacRegs()
    discard console.sendString("[WIFI] rxenv ")
    discard console.sendString("q=")
    console.sendHex32(rxl_cntrl_env[0])
    discard console.sendString(" hd=")
    console.sendHex32(rxl_cntrl_env[2])
    discard console.sendString(" tail=")
    console.sendHex32(rxl_cntrl_env[3])
    discard console.sendString(" cur=")
    console.sendHex32(rxl_cntrl_env[4])
    discard console.sendString(" pdt=")
    console.sendHex32(rx_hwdesc_env[0])
    discard console.sendString(" pdc=")
    console.sendHex32(rx_hwdesc_env[1])
    discard console.sendLine("")
    dumpRxDesc("[WIFI] hdhead", rxl_cntrl_env[2])
    dumpRxDesc("[WIFI] hdcur", rxl_cntrl_env[4])

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  when defined(bl808WifiNimFw):
    hwValidationLogReset()

  discard console.sendLine("")
  discard console.sendLine("=== BL808 WiFi HAL Test ===")

  when WifiPreInitDebugDelayMs > 0:
    discard console.sendString("[WIFI] pre-init debug delay ms=")
    console.sendHex32(WifiPreInitDebugDelayMs.uint32)
    discard console.sendLine("")
    for _ in 0 ..< WifiPreInitDebugDelayMs:
      delayUs(1000)

  let credsOk = WifiSsid.len > 0 and WifiPassword.len > 0
  let initOk = wifiInit() == wifiOk
  when defined(bl808WifiNimFw):
    discard console.sendLine("[WIFI-NIMFW] bl_init done")
  when not WifiScanOnly:
    check("wifi credentials supplied", credsOk)
  check("wifi init", initOk)

  var iface = wifi_mgmr_sta_enable()
  check("wifi sta enable", iface != nil)
  when WifiScanDebugDelayMs > 0:
    discard console.sendString("[WIFI] scan debug delay ms=")
    console.sendHex32(WifiScanDebugDelayMs.uint32)
    discard console.sendLine("")
    for _ in 0 ..< WifiScanDebugDelayMs:
      delayUs(1000)
  check("wifi scan", wifi_mgmr_scan(addr iface, nil) == 0)
  when defined(bl808WifiNimFw):
    for _ in 0 ..< 30000:
      bl808_wifi_backend_poll(8)
      if bl808_wifi_backend_scan_done_count() > 0'u32:
        break
      delayUs(1000)
    for _ in 0 ..< 500:
      bl808_wifi_backend_poll(8)
      delayUs(1000)
    discard console.sendString("[WIFI] scan items=")
    console.sendHex32(bl808_wifi_backend_scan_count())
    discard console.sendString(" done=")
    console.sendHex32(bl808_wifi_backend_scan_done_count())
    discard console.sendString(" macirq=")
    console.sendHex32(bl808_wifi_backend_mac_irq_count())
    discard console.sendString(" poll=")
    console.sendHex32(bl808_wifi_backend_mac_poll_irq_count())
    discard console.sendString(" trap=")
    console.sendHex32(bl808_wifi_backend_mac_trap_irq_count())
    discard console.sendString(" ipc=")
    console.sendHex32(bl808_wifi_backend_ipc_trap_irq_count())
    discard console.sendString(" ipcpoll=")
    console.sendHex32(bl808_wifi_backend_ipc_poll_irq_count())
    discard console.sendLine("")
    dumpWifiNimFwRxSnapshot()
    dumpRfPhyTrace()
    when defined(bl808WifiUseBl808Rf):
      dumpRfInitStageTrace()
      dumpRfCalSummary()
      when (not WifiScanOnly) or WifiRfVerboseDump:
        dumpRfTxcalTrace()
        dumpRfBzTxcalTrace()
        dumpRfRxcalTrace()
    when defined(bl808WifiNimFwDiag):
      dumpScanDiag()
      dumpWifiRxDebug()
    elif not defined(bl808WifiNimFw):
      dumpWifiMacRegs()
    check("wifi scan complete", bl808_wifi_backend_scan_done_count() > 0'u32)
    check("wifi scan results", bl808_wifi_backend_scan_count() > 0'u32)

  when WifiScanOnly:
    check("wifi ap start", wifiStartAp("bl808-hal-ap", "12345678", 1) == wifiOk)
    check("wifi ap stop", wifiStopAp() == wifiOk)
    discard rfReadRevision()
    check("wifi rf revision read", true)
    printResult()
    return

  discard console.sendString("[WIFI] connecting ssid=")
  discard console.sendLine(WifiSsid)
  let connectResult = wifiConnect(WifiSsid, WifiPassword, WifiChannel.uint8)
  when defined(bl808WifiNimFw):
    when WifiExpectConnectFailure:
      discard console.sendString("[WIFI] connect failure status=")
    else:
      discard console.sendString("[WIFI] connect status=")
    console.sendHex32(bl808_wifi_backend_last_status().uint32)
    discard console.sendString(" reason=")
    console.sendHex32(bl808_wifi_backend_last_reason().uint32)
    discard console.sendLine("")
  when defined(bl808WifiNimFwDiag):
    dumpNimFwTxCounters()
  when WifiExpectConnectFailure:
    check("wifi connect expected failure", connectResult != wifiOk)
    when defined(bl808WifiNimFw):
      let failureStatus = bl808_wifi_backend_last_status()
      let failureReason = bl808_wifi_backend_last_reason()
      check("wifi credential failure classified",
            wifiCredentialFailureMatches(failureStatus, failureReason))
    discard wifiDisconnect()
  else:
    let connectOk = connectResult == wifiOk
    when defined(bl808WifiNimFw):
      if not connectOk:
        dumpNimFwTxCounters()
    check("wifi connect", connectOk)
    when defined(bl808WifiNimFw):
      check("wifi connect status", bl808_wifi_backend_last_status() == 0)
      check("wifi connect reason", bl808_wifi_backend_last_reason() == 0)
    check("wifi netif", wifiGetNetif() != nil)
    when defined(bl808WifiNimFw):
      when WifiKeepaliveFrames > 0:
        wifiSetStaKeepaliveQosNull(WifiKeepaliveQosNull)
        var txFrames = 0
        var txFailures = 0
        var txAttempts = 0
        while txFrames < WifiKeepaliveFrames and txAttempts < 5000:
          inc txAttempts
          var busy = false
          case wifiSendStaKeepaliveFrame()
          of wifiOk:
            inc txFrames
          of wifiBusy:
            busy = true
          else:
            inc txFailures
          let serviceRounds = if busy: 10 else: 250
          for _ in 0 ..< serviceRounds:
            wifiServicePump(8)
            delayUs(1000)
        var confirmPolls = 0
        while wifiStaKeepaliveConfirmCount() < txFrames.uint32 and
            confirmPolls < 5000:
          wifiServicePump(8)
          delayUs(1000)
          inc confirmPolls
        discard console.sendString("[WIFI] keepalive tx=")
        console.sendHex32(txFrames.uint32)
        discard console.sendString(" attempts=")
        console.sendHex32(txAttempts.uint32)
        discard console.sendString(" failures=")
        console.sendHex32(txFailures.uint32)
        discard console.sendString(" cfm=")
        console.sendHex32(wifiStaKeepaliveConfirmCount())
        discard console.sendString(" ack=")
        console.sendHex32(wifiStaKeepaliveAckOkCount())
        discard console.sendString(" nack=")
        console.sendHex32(wifiStaKeepaliveFailCount())
        discard console.sendLine("")
        let keepaliveOk =
          txFrames >= WifiKeepaliveFrames and
          txFailures == 0 and
          wifiStaKeepaliveAckOkCount() >= WifiKeepaliveFrames.uint32 and
          wifiStaKeepaliveFailCount() == 0
        if not keepaliveOk:
          dumpNimFwTxCounters()
        check("wifi keepalive tx ack", keepaliveOk)
    when defined(bl808WifiNimFwDiag):
      discard console.sendString("[DISCONNECT] pre sm_state=")
      console.sendHex32(ke_state_get(4'u16).uint32)
      discard console.sendLine("")
    let discResult = wifiDisconnect()
    when defined(bl808WifiNimFwDiag):
      discard console.sendString("[DISCONNECT] post sm_state=")
      console.sendHex32(ke_state_get(4'u16).uint32)
      discard console.sendLine("")
      dumpNimFwDisconnectCounters()
    check("wifi disconnect", discResult == wifiOk)
  check("wifi ap start", wifiStartAp("bl808-hal-ap", "12345678", 1) == wifiOk)
  check("wifi ap stop", wifiStopAp() == wifiOk)
  discard rfReadRevision()
  check("wifi rf revision read", true)

  printResult()
