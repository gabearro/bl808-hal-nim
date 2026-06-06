## M0 WiFi lwIP smoke test (Iter 2.A.0 follow-up).
##
## Build with:
##   make m0 FILE=examples/m0_wifi_lwip_smoke.nim \
##     NIM="nim -d:bl808kernel -d:bl808WifiNimFw \
##              -d:WifiSsid=Frog -d:WifiPassword=<wifi-password>"
##
## Per attempt: scan -> auth -> 4whs -> assoc (synthetic) -> DHCP ->
## ICMP echo to the configured target.
##
## Pass for the soak (after Task 2): >=1 of N attempts reaches icmp:ok.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/wifi
import bl808/panicoverride
import bl808/kernel/alloc
import bl808/kernel/clock
import bl808/kernel/e2e_marker
import bl808/kernel/e2e_runner
import bl808/kernel/lwipcore
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
  WifiIcmpTargetA {.intdefine.} = 1
  WifiIcmpTargetB {.intdefine.} = 1
  WifiIcmpTargetC {.intdefine.} = 1
  WifiIcmpTargetD {.intdefine.} = 1
  AttemptsTotal {.intdefine.} = 3
  GatewayIcmpAttempts {.intdefine.} = 3
  DhcpTimeoutMs = 10_000'u32

# IPv4 field accessors. The netif struct has nested ip_addr_t fields whose
# layout is version-sensitive; an {.emit:} block sidesteps the binding question.
proc netifIp4(netif: ptr Netif): uint32 =
  var v: uint32 = 0
  {.emit: "`v` = ((struct netif*)`netif`)->ip_addr.addr;".}
  v

proc netifGw4(netif: ptr Netif): uint32 =
  var v: uint32 = 0
  {.emit: "`v` = ((struct netif*)`netif`)->gw.addr;".}
  v

proc nowMs(): uint32 {.inline.} =
  (kernel_read_tick_ms() and 0xffffffff'u64).uint32

proc pollNetwork() {.inline.} =
  bl808_wifi_backend_poll(4)
  sysCheckTimeouts()

proc wifi_nimfw_tcpip_input_calls(): uint32 {.importc, cdecl.}
proc wifi_nimfw_tcpip_input_ok(): uint32 {.importc, cdecl.}
proc wifi_nimfw_tcpip_input_fail(): uint32 {.importc, cdecl.}
proc wifi_nimfw_tcpip_input_drop_flags(): uint32 {.importc, cdecl.}
proc wifi_nimfw_tcpip_input_no_pbuf(): uint32 {.importc, cdecl.}
proc wifi_nimfw_debug_snapshot() {.importc, cdecl.}

var nimfw_dbg_tcpip_input_mpdu_conv {.importc.}: uint32
var nimfw_dbg_tcpip_input_mpdu_fail {.importc.}: uint32
var nimfw_dbg_tcpip_input_mpdu_fail_counts {.importc.}: uint32
var nimfw_dbg_tcpip_input_mpdu_fail_detail_lo {.importc.}: uint32
var nimfw_dbg_tcpip_input_mpdu_fail_detail_hi {.importc.}: uint32
var nimfw_dbg_tcpip_input_mpdu_last0 {.importc.}: uint32
var nimfw_dbg_tcpip_input_mpdu_last1 {.importc.}: uint32
var nimfw_dbg_tcpip_input_mpdu_last2 {.importc.}: uint32
var nimfw_dbg_tcpip_input_eth {.importc.}: uint32
var nimfw_dbg_tcpip_input_udp {.importc.}: uint32
var nimfw_dbg_tcpip_input_dhcp_rx {.importc.}: uint32
var nimfw_dbg_tcpip_input_last_ports {.importc.}: uint32
var nimfw_dbg_tcpip_input_last_ip {.importc.}: uint32
var nimfw_dbg_tcpip_input_dhcp_meta {.importc.}: uint32
var nimfw_dbg_tcpip_input_dhcp_xid {.importc.}: uint32
var nimfw_dbg_tcpip_input_dhcp_yiaddr {.importc.}: uint32
var nimfw_dbg_tcpip_input_dhcp_ch0 {.importc.}: uint32
var nimfw_dbg_tcpip_input_dhcp_ch1 {.importc.}: uint32
var nimfw_dbg_tcpip_input_frame_last0 {.importc.}: uint32
var nimfw_dbg_tcpip_input_frame_last1 {.importc.}: uint32
var nimfw_dbg_tcpip_input_frame_src0 {.importc.}: uint32
var nimfw_dbg_tcpip_input_frame_src1 {.importc.}: uint32
var nimfw_dbg_tcpip_input_frame_src2 {.importc.}: uint32
var nimfw_dbg_tcpip_input_frame_src3 {.importc.}: uint32
var nimfw_dbg_tcpip_input_frame_pbuf0 {.importc.}: uint32
var nimfw_dbg_tcpip_input_frame_pbuf1 {.importc.}: uint32
var nimfw_dbg_tcpip_input_frame_pbuf2 {.importc.}: uint32
var nimfw_dbg_tcpip_input_frame_pbuf3 {.importc.}: uint32
var nimfw_dbg_tcpip_input_frame_ethertype {.importc.}: uint32
var nimfw_dbg_pbuf_alloc_fail {.importc.}: uint32
var nimfw_dbg_pbuf_take_fail {.importc.}: uint32
var nimfw_dbg_lwip_dhcp_recv_count {.importc.}: uint32
var nimfw_dbg_lwip_dhcp_recv_code {.importc.}: uint32
var nimfw_dbg_lwip_dhcp_recv_len {.importc.}: uint32
var nimfw_dbg_lwip_dhcp_recv_meta {.importc.}: uint32
var nimfw_dbg_lwip_dhcp_offer_count {.importc.}: uint32
var nimfw_dbg_lwip_dhcp_offer_code {.importc.}: uint32
var nimfw_dbg_lwip_dhcp_offer_server {.importc.}: uint32
var nimfw_dbg_lwip_dhcp_offer_ip {.importc.}: uint32
var nimfw_dbg_lwip_dhcp_select_count {.importc.}: uint32
var nimfw_dbg_lwip_dhcp_create_count {.importc.}: uint32
var nimfw_dbg_lwip_dhcp_create_meta {.importc.}: uint32
var nimfw_dbg_lwip_dhcp_create_hist {.importc.}: uint32
var nimfw_dbg_tx_push_calls {.importc.}: uint32
var nimfw_dbg_bl_tx_cfm {.importc.}: uint32
var nimfw_dbg_bl_output_drop {.importc.}: uint32
var nimfw_dbg_tx_nodesc {.importc.}: uint32
var nimfw_dbg_tx_nobuf {.importc.}: uint32
var nimfw_dbg_cfm_push {.importc.}: uint32
var nimfw_dbg_cfm_evt {.importc.}: uint32
var nimfw_dbg_frame_cfm {.importc.}: uint32
var nimfw_dbg_txint_enter {.importc.}: uint32
var nimfw_dbg_txint_ready {.importc.}: uint32
var nimfw_dbg_txint_psok {.importc.}: uint32
var nimfw_dbg_txint_push {.importc.}: uint32
var nimfw_dbg_txint_release {.importc.}: uint32
var nimfw_dbg_txint_postpone {.importc.}: uint32
var nimfw_dbg_txint_last_fc {.importc.}: uint32
var nimfw_dbg_txint_meta {.importc.}: uint32
var nimfw_dbg_txint_chan {.importc.}: uint32
var nimfw_dbg_txint_queue {.importc.}: uint32
var nimfw_dbg_txint_hw {.importc.}: uint32
var nimfw_dbg_txtrig_entry {.importc.}: uint32
var nimfw_dbg_txtrig_acready {.importc.}: uint32
var nimfw_dbg_txtrig_zero {.importc.}: uint32
var nimfw_dbg_txtrig_loops {.importc.}: uint32
var nimfw_dbg_txtrig_desc {.importc.}: uint32
var nimfw_dbg_txtrig_status {.importc.}: uint32
var nimfw_dbg_txtrig_notready {.importc.}: uint32
var nimfw_dbg_txtrig_nodesc {.importc.}: uint32
var nimfw_dbg_pay_backup {.importc.}: uint32
var nimfw_dbg_pay_desc {.importc.}: uint32
var nimfw_dbg_pay_payload {.importc.}: uint32
var nimfw_dbg_pay_empty {.importc.}: uint32
var nimfw_dbg_pay_nonempty {.importc.}: uint32
var nimfw_dbg_pay_trig {.importc.}: uint32
var nimfw_dbg_pay_tx_status {.importc.}: uint32
var nimfw_dbg_pay_tx_agg {.importc.}: uint32
var nimfw_dbg_pay_tx_dma {.importc.}: uint32
var nimfw_dbg_pay_tx_current {.importc.}: uint32
var nimfw_dbg_pay_tx_thd {.importc.}: uint32
var nimfw_dbg_pay_tx_head {.importc.}: uint32
var nimfw_dbg_probe_pay_meta {.importc.}: uint32
var nimfw_dbg_probe_pay_desc {.importc.}: uint32
var nimfw_dbg_probe_pay_link {.importc.}: uint32
var nimfw_dbg_probe_pay_hw {.importc.}: uint32
var nimfw_dbg_probe_pay_thd {.importc.}: uint32
var nimfw_dbg_probe_pay_len {.importc.}: uint32
var nimfw_dbg_probe_pay_hw0 {.importc.}: uint32
var nimfw_dbg_probe_pay_hw1 {.importc.}: uint32
var nimfw_dbg_probe_pay_hw2 {.importc.}: uint32
var nimfw_dbg_probe_pay_hw3 {.importc.}: uint32
var nimfw_dbg_probe_pay_link0 {.importc.}: uint32
var nimfw_dbg_probe_pay_link1 {.importc.}: uint32
var nimfw_dbg_probe_pay_hw_start {.importc.}: uint32
var nimfw_dbg_probe_pay_hw_end {.importc.}: uint32
var nimfw_dbg_probe_pay_hw_frame_len {.importc.}: uint32
var nimfw_dbg_probe_pay_hw_status {.importc.}: uint32
var nimfw_dbg_probe_pay_hw_ctrl {.importc.}: uint32
var nimfw_dbg_probe_pay_hw_chain {.importc.}: uint32
var nimfw_dbg_probe_pay_hw_word36 {.importc.}: uint32
var nimfw_dbg_probe_pay_hw_word56 {.importc.}: uint32
var nimfw_dbg_probe_pay_raw {.importc.}: array[96, uint8]
var nimfw_dbg_probe_ie_len {.importc.}: uint32
var nimfw_dbg_probe_ie_raw {.importc.}: array[64, uint8]
var nimfw_dbg_mac_irq {.importc.}: uint32
var nimfw_dbg_mac_irq_last {.importc.}: uint32
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
var nimfw_dbg_rxl_snap_mask {.importc.}: uint32
var nimfw_dbg_rxl_snap_rxctrl {.importc.}: uint32
var nimfw_dbg_rxl_snap_int_unmask {.importc.}: uint32
var nimfw_dbg_rxl_snap_gen_unmask {.importc.}: uint32
var nimfw_dbg_rxl_snap_rxctrl_raw {.importc.}: uint32
var nimfw_dbg_rxl_snap_status_raw {.importc.}: uint32
var nimfw_dbg_rxl_snap_irq_raw {.importc.}: uint32
var nimfw_dbg_rxl_snap_gen_raw {.importc.}: uint32
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
var nimfw_dbg_scan_start_phy_raw {.importc.}: array[4, uint32]
var nimfw_dbg_scan_end_phy_raw {.importc.}: array[4, uint32]
when defined(bl808WifiUseBl808Rf):
  var nim_wifi_rf_stage_snapshot_count {.importc.}: uint32
  var nim_wifi_rf_stage_tag_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rf70_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rf88_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rfd0_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rfa0_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rf1600_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rfb4_log {.importc.}: array[8, uint32]
  var nim_wifi_rf_stage_rfbc_log {.importc.}: array[8, uint32]
  var nimfw_dbg_rf_cal_save_count {.importc.}: uint32
  var nimfw_dbg_rf_cal_restore_count {.importc.}: uint32
  var nimfw_dbg_rf_cal_save_rf88 {.importc.}: uint32
  var nimfw_dbg_rf_cal_restore_rf88 {.importc.}: uint32
  var nimfw_dbg_rf_cal_restore_readback_rf88 {.importc.}: uint32
  var nimfw_dbg_rf_cal_restore_rf8c {.importc.}: uint32
var nimfw_dbg_tx_sec_hdr_calls {.importc.}: uint32
var nimfw_dbg_tx_sec_hdr_no_keymat {.importc.}: uint32
var nimfw_dbg_tx_sec_hdr_no_keyslot {.importc.}: uint32
var nimfw_dbg_tx_sec_hdr_cipher {.importc.}: uint32
var nimfw_dbg_tx_sec_hdr_len {.importc.}: uint32
var nimfw_dbg_tx_sec_hdr_append {.importc.}: uint32
var nimfw_dbg_tx_sec_hdr_miss_meta {.importc.}: uint32
var nimfw_dbg_tx_sec_hdr_miss_len {.importc.}: uint32
var nimfw_dbg_tx_sec_hdr_miss_keymat {.importc.}: uint32
var nimfw_dbg_sta_tx_rf_latch {.importc.}: uint32
var nimfw_dbg_dhcp_tx_desc_bytes {.importc.}: uint32
var nimfw_dbg_dhcp_tx_hdr0 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_hdr1 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_hdr2 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_sec {.importc.}: uint32
var nimfw_dbg_dhcp_tx_sec_hdr0 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_sec_hdr1 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_sec_key {.importc.}: uint32
var nimfw_dbg_dhcp_tx_sec_ctl {.importc.}: uint32
var nimfw_dbg_dhcp_tx_policy {.importc.}: uint32
var nimfw_dbg_dhcp_tx_buf_desc {.importc.}: uint32
var nimfw_dbg_dhcp_tx_hw_desc {.importc.}: uint32
var nimfw_dbg_dhcp_tx_rate0 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_rate1 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_rate2 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_rate3 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_rate_raw {.importc.}: array[13, uint32]
var nimfw_dbg_dhcp_tx_link0 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_link1 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_thd0 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_thd1 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_thd2 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_layout {.importc.}: array[8, uint32]
var nimfw_dbg_dhcp_tx_final_break_hits {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_desc0 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_desc1 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_buf0 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_len0 {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_hw_start {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_hw_end {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_hw_len {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_hw_flags {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_hthd_start {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_hthd_end {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_hthd_next {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_hthd_flags {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_pthd_start {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_pthd_end {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_pthd_next {.importc.}: uint32
var nimfw_dbg_dhcp_tx_final_pthd_flags {.importc.}: uint32
var nimfw_dbg_eapol_tx_desc_bytes {.importc.}: uint32
var nimfw_dbg_eapol_tx_hdr0 {.importc.}: uint32
var nimfw_dbg_eapol_tx_hdr1 {.importc.}: uint32
var nimfw_dbg_eapol_tx_hdr2 {.importc.}: uint32
var nimfw_dbg_eapol_tx_hdr3 {.importc.}: uint32
var nimfw_dbg_eapol_tx_addr_hi {.importc.}: uint32
var nimfw_dbg_eapol_tx_policy {.importc.}: uint32
var nimfw_dbg_eapol_tx_buf_desc {.importc.}: uint32
var nimfw_dbg_eapol_tx_hw_desc {.importc.}: uint32
var nimfw_dbg_eapol_tx_rate0 {.importc.}: uint32
var nimfw_dbg_eapol_tx_rate1 {.importc.}: uint32
var nimfw_dbg_eapol_tx_rate2 {.importc.}: uint32
var nimfw_dbg_eapol_tx_rate3 {.importc.}: uint32
var nimfw_dbg_eapol_tx_link0 {.importc.}: uint32
var nimfw_dbg_eapol_tx_link1 {.importc.}: uint32
var nimfw_dbg_dhcp_mac_raw_len {.importc.}: uint32
var nimfw_dbg_dhcp_mac_raw {.importc.}: array[96, uint8]
var nimfw_dbg_rxu_desc_prepare {.importc.}: uint32
var nimfw_dbg_rxu_upload_evt {.importc.}: uint32
var nimfw_dbg_rxu_upload_entry {.importc.}: uint32
var nimfw_dbg_rxu_upload_tcpip_ok {.importc.}: uint32
var nimfw_dbg_rxu_upload_tcpip_fail {.importc.}: uint32
var nimfw_dbg_rxu_upload_frame {.importc.}: uint32
var nimfw_dbg_rxu_frame_valid {.importc.}: uint32
var nimfw_dbg_rxu_assoc_data {.importc.}: uint32
var nimfw_dbg_rxu_assoc_eapol {.importc.}: uint32
var nimfw_dbg_rxu_assoc_upload_ready {.importc.}: uint32
var nimfw_dbg_rxu_assoc_mgmt {.importc.}: uint32
var nimfw_dbg_rxu_nonassoc_data {.importc.}: uint32
var nimfw_dbg_rxu_drop_invalid {.importc.}: uint32
var nimfw_dbg_rxu_drop_sta_inactive {.importc.}: uint32
var nimfw_dbg_rxu_drop_ftype {.importc.}: uint32
var nimfw_dbg_rxu_drop_null {.importc.}: uint32
var nimfw_dbg_rxu_drop_dup {.importc.}: uint32
var nimfw_dbg_rxu_drop_pn {.importc.}: uint32
var nimfw_dbg_rxu_prot_type {.importc.}: uint32
var nimfw_dbg_rxu_prot_key {.importc.}: uint32
var nimfw_dbg_rxu_prot_pn_lo {.importc.}: uint32
var nimfw_dbg_rxu_prot_pn_hi {.importc.}: uint32
var nimfw_dbg_rxu_pn_meta {.importc.}: uint32
var nimfw_dbg_rxu_pn_stored_lo {.importc.}: uint32
var nimfw_dbg_rxu_pn_stored_hi {.importc.}: uint32
var nimfw_dbg_rxu_pn_next_lo {.importc.}: uint32
var nimfw_dbg_rxu_pn_next_hi {.importc.}: uint32
var nimfw_dbg_rxu_data_fc {.importc.}: uint32
var nimfw_dbg_rxu_data_seq {.importc.}: uint32
var nimfw_dbg_rxu_last_hwflags {.importc.}: uint32
var nimfw_dbg_rxu_last_status {.importc.}: uint32
var nimfw_dbg_rxu_last_len {.importc.}: uint32
var nimfw_dbg_rxu_snap_lo {.importc.}: uint32
var nimfw_dbg_rxu_snap_hi {.importc.}: uint32
var nimfw_dbg_rxu_assoc_snap {.importc.}: uint32
var nimfw_dbg_rxu_assoc_ip {.importc.}: uint32
var nimfw_dbg_rxu_assoc_arp {.importc.}: uint32
var nimfw_dbg_rxu_assoc_other {.importc.}: uint32
var nimfw_dbg_rxu_drop_null_fc {.importc.}: uint32
var nimfw_dbg_rxu_drop_null_seq {.importc.}: uint32
var nimfw_dbg_rxu_drop_dup_fc {.importc.}: uint32
var nimfw_dbg_rxu_drop_dup_seq {.importc.}: uint32
var nimfw_dbg_rxu_dup_trace_count {.importc.}: uint32
var nimfw_dbg_rxu_dup_trace_fc {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_trace_seq {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_trace_cache {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_trace_snap_lo {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_trace_snap_hi {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_trace_addr0 {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_trace_addr1 {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_trace_ip0 {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_trace_udp0 {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_trace_bootp0 {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_trace_bootp1 {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_trace_bootp_yiaddr {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_trace_dhcp_msg {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_trace_dhcp_server {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_dup_break_hits {.importc.}: uint32
var nimfw_dbg_rxu_pn_drop_trace_count {.importc.}: uint32
var nimfw_dbg_rxu_pn_drop_trace_fc {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_drop_trace_seq {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_drop_trace_pn_lo {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_drop_trace_pn_hi {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_drop_trace_stored_lo {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_drop_trace_stored_hi {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_drop_trace_snap_lo {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_drop_trace_snap_hi {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_drop_trace_udp0 {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_drop_trace_bootp_yiaddr {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_drop_trace_dhcp_msg {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_drop_trace_dhcp_server {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_count {.importc.}: uint32
var nimfw_dbg_rxu_pn_accept_trace_stage {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_fc {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_seq {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_pn_lo {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_pn_hi {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_stored_lo {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_stored_hi {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_next_lo {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_next_hi {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_snap_lo {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_snap_hi {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_udp0 {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_bootp_yiaddr {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_dhcp_msg {.importc.}: array[8, uint32]
var nimfw_dbg_rxu_pn_accept_trace_dhcp_server {.importc.}: array[8, uint32]
var nimfw_dbg_setkey0 {.importc.}: uint32
var nimfw_dbg_setkey1 {.importc.}: uint32
var nimfw_dbg_setkey2 {.importc.}: uint32
var nimfw_dbg_setkey3 {.importc.}: uint32
var nimfw_dbg_machwkey_wr_calls {.importc.}: uint32
var nimfw_dbg_machwkey_wr_group {.importc.}: uint32
var nimfw_dbg_machwkey_wr_pair {.importc.}: uint32
var nimfw_dbg_machwkey_wr_last0 {.importc.}: uint32
var nimfw_dbg_machwkey_wr_last1 {.importc.}: uint32
var nimfw_dbg_machwkey_wr_pair0 {.importc.}: uint32
var nimfw_dbg_machwkey_wr_pair1 {.importc.}: uint32
var nimfw_dbg_machwkey_wr_pair2 {.importc.}: uint32
var nimfw_dbg_machwkey_wr_pair3 {.importc.}: uint32
var nimfw_dbg_machwkey_wr_pair4 {.importc.}: uint32
var nimfw_dbg_machwkey_wr_pair5 {.importc.}: uint32
var nimfw_dbg_machwkey_wr_pair_ctrl {.importc.}: uint32
var nimfw_dbg_sta_add_key_calls {.importc.}: uint32
var nimfw_dbg_sta_add_key_meta {.importc.}: uint32
var nimfw_dbg_sta_add_key_ptrs0 {.importc.}: uint32
var nimfw_dbg_sta_add_key_ptrs1 {.importc.}: uint32
var nimfw_dbg_sta_add_key_ptrs2 {.importc.}: uint32
var nimfw_dbg_tx_sec_hdr_sta_key0 {.importc.}: uint32
var nimfw_dbg_tx_sec_hdr_sta_key1 {.importc.}: uint32
var nimfw_dbg_tx_sec_hdr_sta_key2 {.importc.}: uint32
var nimfw_dbg_auth_mgt_seen {.importc.}: uint32
var nimfw_dbg_auth_mgt_accept {.importc.}: uint32
var nimfw_dbg_auth_mgt_reject {.importc.}: uint32
var nimfw_dbg_auth_mgt_msg {.importc.}: uint32
var nimfw_dbg_auth_mgt_last0 {.importc.}: uint32
var nimfw_dbg_auth_mgt_last1 {.importc.}: uint32
var nimfw_dbg_mgt_seen {.importc.}: uint32
var nimfw_dbg_mgt_accept {.importc.}: uint32
var nimfw_dbg_mgt_reject {.importc.}: uint32
var nimfw_dbg_mgt_msg {.importc.}: uint32
var nimfw_dbg_mgt_last_fc {.importc.}: uint32
var nimfw_dbg_mgt_last0 {.importc.}: uint32
var nimfw_dbg_mgt_last1 {.importc.}: uint32
var nimfw_dbg_mgt_drop_reason {.importc.}: uint32
var nimfw_dbg_auth_sm_dispatch {.importc.}: uint32
var nimfw_dbg_auth_sm_state {.importc.}: uint32
var nimfw_dbg_auth_handler {.importc.}: uint32
var nimfw_dbg_auth_handler_last {.importc.}: uint32
var nimfw_dbg_auth_tx_len {.importc.}: uint32
var nimfw_dbg_auth_tx_meta {.importc.}: uint32
var nimfw_dbg_auth_tx_desc {.importc.}: uint32
var nimfw_dbg_auth_tx_raw {.importc.}: array[96, uint8]
var nimfw_dbg_auth_cfm_push {.importc.}: uint32
var nimfw_dbg_auth_cfm_frame {.importc.}: uint32
var nimfw_dbg_auth_cfm_evt {.importc.}: uint32
var nimfw_dbg_auth_cfm_status {.importc.}: uint32
var nimfw_dbg_auth_cfm_hw_status {.importc.}: uint32
var nimfw_dbg_auth_cfm_desc {.importc.}: uint32
var nimfw_dbg_auth_cfm_meta {.importc.}: uint32
var nimfw_dbg_auth_cfm_fc {.importc.}: uint32
var nimfw_dbg_auth_open_success {.importc.}: uint32
var nimfw_dbg_assoc_req_send {.importc.}: uint32
var nimfw_dbg_assoc_req_meta {.importc.}: uint32
var nimfw_dbg_assoc_cfm_push {.importc.}: uint32
var nimfw_dbg_assoc_cfm_frame {.importc.}: uint32
var nimfw_dbg_assoc_cfm_evt {.importc.}: uint32
var nimfw_dbg_assoc_cfm_status {.importc.}: uint32
var nimfw_dbg_assoc_cfm_hw_status {.importc.}: uint32
var nimfw_dbg_assoc_cfm_desc {.importc.}: uint32
var nimfw_dbg_assoc_cfm_meta {.importc.}: uint32
var nimfw_dbg_assoc_cfm_fc {.importc.}: uint32
var nimfw_dbg_assoc_rsp_count {.importc.}: uint32
var nimfw_dbg_assoc_rsp_status {.importc.}: uint32
var nimfw_dbg_assoc_rsp_len {.importc.}: uint32
var nimfw_dbg_assoc_rsp_b0 {.importc.}: uint32
var nimfw_dbg_assoc_rsp_b4 {.importc.}: uint32
var nimfw_dbg_set_vif_state {.importc.}: uint32
var nimfw_dbg_set_vif_state_new {.importc.}: uint32
var nimfw_dbg_set_vif_state_act {.importc.}: uint32
var nimfw_dbg_assoc_done {.importc.}: uint32
var nimfw_dbg_vif_sectype {.importc.}: uint32
var nimfw_dbg_conn_ind_prepath {.importc.}: uint32
var nimfw_wpa_pending_mask {.importc.}: uint32
var nimfw_dbg_ptk_init_done {.importc.}: uint32
var nimfw_dbg_eapol_in {.importc.}: uint32
var nimfw_dbg_eapol_dropped {.importc.}: uint32
var nimfw_dbg_eapol_fwd {.importc.}: uint32
var nimfw_dbg_vif_wpastate {.importc.}: uint32
var nimfw_dbg_eapol_cb_inv {.importc.}: uint32
var nimfw_dbg_eapol_cb_null {.importc.}: uint32
var nimfw_dbg_sm_state_eapol {.importc.}: uint32
var nimfw_dbg_supp_rx_eapol {.importc.}: uint32
var nimfw_dbg_supp_tx_eapol {.importc.}: uint32
var nimfw_dbg_eth_tx_eapol {.importc.}: uint32
var nimfw_dbg_bl_output_eapol {.importc.}: uint32
var nimfw_dbg_eapol_tx_cb {.importc.}: uint32
var nimfw_dbg_wpa_deauth {.importc.}: uint32
var nimfw_dbg_eth_tx_ret {.importc.}: uint32
var nimfw_dbg_supp_tx_len {.importc.}: uint32
var nimfw_dbg_bl_tx_cfm_eapol {.importc.}: uint32
var nimfw_dbg_bl_tx_cfm_cb {.importc.}: uint32
var nimfw_dbg_cfm_cb_ptr_last {.importc.}: uint32
var nimfw_dbg_send_4of4_tx {.importc.}: uint32
var nimfw_dbg_send_4of4_cb {.importc.}: uint32
var nimfw_dbg_install_ptk {.importc.}: uint32
var nimfw_dbg_eapol_cfm_status {.importc.}: uint32
var nimfw_dbg_eapol_cfm_count {.importc.}: uint32
var nimfw_dbg_eapol_cfm_ack_ok {.importc.}: uint32
var nimfw_dbg_eapol_cfm_ack_fail {.importc.}: uint32
var nimfw_dbg_eapol_cfm_ring_idx {.importc.}: uint32
var nimfw_dbg_eapol_cfm_status_log {.importc.}: array[4, uint32]
var nimfw_dbg_eapol_cfm_meta_log {.importc.}: array[4, uint32]
var nimfw_dbg_eapol_cfm_key_log {.importc.}: array[4, uint32]
var nimfw_dbg_eapol_cfm_replay_log {.importc.}: array[4, uint32]
var nimfw_dbg_wpa_state {.importc.}: uint32
var nimfw_dbg_wpa_tx_state {.importc.}: uint32
var nimfw_dbg_wpa_rx_state {.importc.}: uint32
var nimfw_dbg_wpa_ptk_installed {.importc.}: uint32
var nimfw_dbg_m4_tx_state {.importc.}: uint32
var nimfw_dbg_m4_cb_ptr {.importc.}: uint32
var nimfw_dbg_scan_frame_seen {.importc.}: uint32
var nimfw_dbg_scan_frame_accept {.importc.}: uint32
var nimfw_dbg_scan_frame_last {.importc.}: uint32
var nimfw_dbg_scan_ssid_last {.importc.}: uint32
var nimfw_dbg_bss_in {.importc.}: uint32
var nimfw_dbg_bss_ssid_result {.importc.}: uint32
var nimfw_dbg_bss_directed {.importc.}: uint32
var nimfw_dbg_bss_out {.importc.}: uint32
var nimfw_dbg_ssid_search {.importc.}: uint32
var nimfw_dbg_ssid_entries {.importc.}: uint32
var nimfw_dbg_ssid_hits {.importc.}: uint32
var nimfw_dbg_dhcp_tx {.importc.}: uint32
var nimfw_dbg_dhcp_tx_eth {.importc.}: uint32
var nimfw_dbg_dhcp_tx_ports {.importc.}: uint32
var nimfw_dbg_dhcp_tx_len {.importc.}: uint32
var nimfw_dbg_dhcp_tx_src_lo {.importc.}: uint32
var nimfw_dbg_dhcp_tx_src_hi {.importc.}: uint32
var nimfw_dbg_dhcp_tx_msg {.importc.}: uint32
var nimfw_dbg_dhcp_tx_raw_len {.importc.}: uint32
var nimfw_dbg_dhcp_tx_raw {.importc.}: array[384, uint8]
var nimfw_dbg_dhcp_tx_break_hits {.importc.}: uint32
var nimfw_dbg_dhcp_request_tx_break_hits {.importc.}: uint32
var nimfw_dbg_dhcp_tx_msg_hist {.importc.}: array[8, uint32]
var nimfw_dbg_dhcp_udp_csum_repair {.importc.}: uint32
var nimfw_dbg_dhcp_udp_csum_before {.importc.}: uint32
var nimfw_dbg_dhcp_udp_csum_calc {.importc.}: uint32
var nimfw_dbg_dhcp_udp_csum_after {.importc.}: uint32
var nimfw_dbg_dhcp_udp_csum_vbefore {.importc.}: uint32
var nimfw_dbg_dhcp_udp_csum_vafter {.importc.}: uint32
var nimfw_dbg_dhcp_req_udp_csum_before {.importc.}: uint32
var nimfw_dbg_dhcp_req_udp_csum_calc {.importc.}: uint32
var nimfw_dbg_dhcp_req_udp_csum_after {.importc.}: uint32
var nimfw_dbg_dhcp_req_udp_csum_vbefore {.importc.}: uint32
var nimfw_dbg_dhcp_req_udp_csum_vafter {.importc.}: uint32
var nimfw_dbg_dhcp_req_udp_csum_at_copy {.importc.}: uint32
var nimfw_dbg_dhcp_cfm {.importc.}: uint32
var nimfw_dbg_dhcp_cfm_ok {.importc.}: uint32
var nimfw_dbg_dhcp_cfm_fail {.importc.}: uint32
var nimfw_dbg_dhcp_cfm_ack_ok {.importc.}: uint32
var nimfw_dbg_dhcp_cfm_ack_fail {.importc.}: uint32
var nimfw_dbg_dhcp_cfm_status {.importc.}: uint32
var nimfw_dbg_dhcp_cfm_ring_idx {.importc.}: uint32
var nimfw_dbg_dhcp_cfm_status_log {.importc.}: array[8, uint32]
var nimfw_dbg_dhcp_cfm_meta_log {.importc.}: array[8, uint32]
var nimfw_dbg_rc_update_calls {.importc.}: uint32
var nimfw_dbg_rc_update_meta {.importc.}: uint32
var nimfw_dbg_rc_update_args {.importc.}: uint32
var nimfw_dbg_rc_update_slot {.importc.}: uint32
var nimfw_dbg_rc_update_entry {.importc.}: uint32
var nimfw_dbg_rc_update_counts {.importc.}: uint32
var nimfw_dbg_rc_update_fail {.importc.}: uint32
var nimfw_dbg_tx_sta_lookup {.importc.}: uint32
var nimfw_dbg_tx_sta_lookup_fail {.importc.}: uint32
var nimfw_dbg_tx_sta_lookup_mode {.importc.}: uint32
var nimfw_dbg_tx_sta_lookup_vif {.importc.}: uint32
var nimfw_dbg_tx_sta_lookup_sta {.importc.}: uint32
var nimfw_dbg_tx_sta_lookup_result {.importc.}: uint32
var nimfw_dbg_tx_sta_lookup_eth {.importc.}: uint32
var nimfw_dbg_tx_sta_lookup_dst0 {.importc.}: uint32
var nimfw_dbg_tx_sta_lookup_dst1 {.importc.}: uint32
var nimfw_dbg_rx_sm_sta_add {.importc.}: uint32
var nimfw_dbg_rx_sm_sta_add_meta {.importc.}: uint32
var nimfw_dbg_rx_sm_sta_add_vif {.importc.}: uint32
var nimfw_dbg_rx_sm_sta_add_sta {.importc.}: uint32
var nimfw_dbg_rx_sm_sta_add_error {.importc.}: uint32
var nimfw_dbg_rx_sm_disc {.importc.}: uint32
var nimfw_dbg_rx_sm_seq {.importc.}: uint32
var nimfw_dbg_rx_sm_sta_add_seq {.importc.}: uint32
var nimfw_dbg_rx_sm_disc_seq {.importc.}: uint32
var nimfw_dbg_rx_sm_disc_meta {.importc.}: uint32
var nimfw_dbg_rx_sm_disc_vif {.importc.}: uint32
var nimfw_dbg_rx_sm_disc_sta {.importc.}: uint32
var nimfw_dbg_ipc_host_irq {.importc.}: uint32
var nimfw_dbg_ipc_host_irq_status {.importc.}: uint32
var nimfw_dbg_ipc_host_txcfm_irq {.importc.}: uint32
var nimfw_dbg_ipc_host_txcfm_handler {.importc.}: uint32
var nimfw_dbg_ipc_host_txcfm_drained {.importc.}: uint32
var nimfw_dbg_ipc_host_txcfm_host {.importc.}: uint32
var nimfw_dbg_ipc_host_txdesc_nil {.importc.}: uint32
var nimfw_dbg_ipc_host_txdesc_push {.importc.}: uint32

const
  IpProtoIcmp = 1'u8
  IcmpEchoRequest = 8'u8
  IcmpEchoReply = 0'u8
  IcmpTimeoutMs = 3_000'u32
  IcmpPacketBytes = 16'u16  # 8-byte ICMP header + 8-byte payload
  IcmpPayload: array[8, uint8] = [0x42'u8, 0x4C, 0x38, 0x30, 0x38, 0x2D, 0x4C, 0x53]
  IcmpTargetAddress =
    (uint32(WifiIcmpTargetA and 0xff)) or
    (uint32(WifiIcmpTargetB and 0xff) shl 8) or
    (uint32(WifiIcmpTargetC and 0xff) shl 16) or
    (uint32(WifiIcmpTargetD and 0xff) shl 24)

type
  IcmpEcho = object
    icmpType: uint8
    code: uint8
    checksum: uint16   # network byte order on the wire
    identifier: uint16 # network byte order on the wire
    sequence: uint16   # network byte order on the wire
    payload: array[8, uint8]
  IcmpState = object
    replied: bool
    rttMs: uint32
    seq: uint16        # host byte order, what we sent
    ident: uint16      # host byte order, what we sent
    txTickMs: uint32

var icmpState: IcmpState
var nimfw_dbg_icmp_tx_target* {.exportc.}: uint32
var nimfw_dbg_icmp_tx_rc* {.exportc.}: uint32
var nimfw_dbg_icmp_tx_ident_seq* {.exportc.}: uint32
var nimfw_dbg_icmp_tx_checksum* {.exportc.}: uint32
var nimfw_dbg_icmp_timeout_polls* {.exportc.}: uint32
var nimfw_dbg_icmp_tcpip_ok_before* {.exportc.}: uint32
var nimfw_dbg_icmp_tcpip_ok_after* {.exportc.}: uint32
var nimfw_dbg_icmp_cb_count* {.exportc.}: uint32
var nimfw_dbg_icmp_cb_total_len* {.exportc.}: uint32
var nimfw_dbg_icmp_cb_ip0* {.exportc.}: uint32
var nimfw_dbg_icmp_cb_ihl* {.exportc.}: uint32
var nimfw_dbg_icmp_cb_type_code* {.exportc.}: uint32
var nimfw_dbg_icmp_cb_ident_seq* {.exportc.}: uint32
var nimfw_dbg_icmp_cb_payload0* {.exportc.}: uint32
var nimfw_dbg_icmp_cb_addr* {.exportc.}: uint32
var nimfw_dbg_icmp_cb_reject* {.exportc.}: uint32

proc loadLe32[N: static[int]](bytes: var array[N, uint8], offset: int): uint32 {.inline.} =
  uint32(bytes[offset]) or
    (uint32(bytes[offset + 1]) shl 8) or
    (uint32(bytes[offset + 2]) shl 16) or
    (uint32(bytes[offset + 3]) shl 24)

proc txCfmBits(status: uint32): uint32 {.inline.} =
  (if (status and (1'u32 shl 31)) != 0'u32: 1'u32 else: 0'u32) or
    (if (status and (1'u32 shl 23)) != 0'u32: 2'u32 else: 0'u32) or
    (if (status and (1'u32 shl 16)) != 0'u32: 4'u32 else: 0'u32) or
    (if (status and (1'u32 shl 19)) != 0'u32: 8'u32 else: 0'u32) or
    (if (status and (1'u32 shl 20)) != 0'u32: 16'u32 else: 0'u32)

proc htons(v: uint16): uint16 {.inline.} =
  ((v shl 8) and 0xff00'u16) or ((v shr 8) and 0x00ff'u16)

proc inetChecksum(buf: ptr UncheckedArray[uint8], len: int): uint16 =
  ## RFC 1071 1's-complement checksum on a buffer (assumed even-length here).
  var sum: uint32 = 0
  var i = 0
  while i + 1 < len:
    let word = (uint32(buf[i]) shl 8) or uint32(buf[i+1])
    sum += word
    i += 2
  if i < len:
    sum += (uint32(buf[i]) shl 8)
  while (sum shr 16) != 0:
    sum = (sum and 0xffff'u32) + (sum shr 16)
  result = uint16((not sum) and 0xffff'u32)

proc icmpRecvCb(arg: pointer, pcb: ptr RawPcb, p: ptr Pbuf,
                address: ptr IpAddr): uint8 {.cdecl.} =
  ## Raw recv callback. lwIP delivers the packet with the IPv4 header still
  ## attached (LWIP_RAW=1 default). Skip past it via the IHL nibble.
  inc nimfw_dbg_icmp_cb_count
  nimfw_dbg_icmp_cb_reject = 0
  if address != nil:
    nimfw_dbg_icmp_cb_addr = address.address
  let totalLen = pbufTotLen(p)
  nimfw_dbg_icmp_cb_total_len = totalLen.uint32
  if totalLen < 20'u16 + 8'u16:
    nimfw_dbg_icmp_cb_reject = 1
    return 0
  var ipByte0: uint8
  discard pbufCopyPartial(p, addr ipByte0, 1'u16, 0'u16)
  nimfw_dbg_icmp_cb_ip0 = ipByte0.uint32
  let ihlBytes = uint16(ipByte0 and 0x0f) * 4'u16
  nimfw_dbg_icmp_cb_ihl = ihlBytes.uint32
  if ihlBytes < 20'u16 or totalLen < ihlBytes + 8'u16:
    nimfw_dbg_icmp_cb_reject = 2
    return 0
  var icmp: IcmpEcho
  discard pbufCopyPartial(p, addr icmp, sizeof(IcmpEcho).uint16, ihlBytes)
  nimfw_dbg_icmp_cb_type_code = icmp.icmpType.uint32 or
    (icmp.code.uint32 shl 8)
  nimfw_dbg_icmp_cb_ident_seq = htons(icmp.identifier).uint32 or
    (htons(icmp.sequence).uint32 shl 16)
  nimfw_dbg_icmp_cb_payload0 = loadLe32(icmp.payload, 0)
  if icmp.icmpType != IcmpEchoReply:
    nimfw_dbg_icmp_cb_reject = 3
    return 0
  if htons(icmp.identifier) != icmpState.ident:
    nimfw_dbg_icmp_cb_reject = 4
    return 0
  if htons(icmp.sequence) != icmpState.seq:
    nimfw_dbg_icmp_cb_reject = 5
    return 0
  for k in 0 ..< 8:
    if icmp.payload[k] != IcmpPayload[k]:
      nimfw_dbg_icmp_cb_reject = 6
      return 0
  icmpState.rttMs = nowMs() - icmpState.txTickMs
  icmpState.replied = true
  nimfw_dbg_icmp_cb_reject = 7
  discard pbufFree(p)
  return 1

proc runIcmpEcho(targetAddress: uint32; requiredReply: bool): bool {.nimcall.} =
  phaseMark(Phase.icmp, Kind.start):
    kvWrite("dst", targetAddress)
  nimfw_dbg_icmp_tx_target = targetAddress
  nimfw_dbg_icmp_tx_rc = 0xFFFF_FFFF'u32
  nimfw_dbg_icmp_tx_ident_seq = 0
  nimfw_dbg_icmp_tx_checksum = 0
  nimfw_dbg_icmp_timeout_polls = 0
  nimfw_dbg_icmp_tcpip_ok_before = wifi_nimfw_tcpip_input_ok()
  nimfw_dbg_icmp_tcpip_ok_after = nimfw_dbg_icmp_tcpip_ok_before
  nimfw_dbg_icmp_cb_count = 0
  nimfw_dbg_icmp_cb_total_len = 0
  nimfw_dbg_icmp_cb_ip0 = 0
  nimfw_dbg_icmp_cb_ihl = 0
  nimfw_dbg_icmp_cb_type_code = 0
  nimfw_dbg_icmp_cb_ident_seq = 0
  nimfw_dbg_icmp_cb_payload0 = 0
  nimfw_dbg_icmp_cb_addr = 0
  nimfw_dbg_icmp_cb_reject = 0
  icmpState.replied = false
  icmpState.ident = ((nowMs() and 0xffff'u32) or 1'u32).uint16
  icmpState.seq = 1'u16
  nimfw_dbg_icmp_tx_ident_seq = icmpState.ident.uint32 or
    (icmpState.seq.uint32 shl 16)
  icmpState.txTickMs = nowMs()

  let pcb = rawNew(IpProtoIcmp)
  if pcb == nil:
    phaseMark(Phase.icmp, Kind.fail):
      kvWrite("reason", "pcb_alloc")
      kvWrite("required", uint32(requiredReply))
    return not requiredReply
  rawRecv(pcb, icmpRecvCb, addr icmpState)

  var req: IcmpEcho
  req.icmpType = IcmpEchoRequest
  req.code = 0
  req.identifier = htons(icmpState.ident)
  req.sequence = htons(icmpState.seq)
  for i in 0 ..< 8:
    req.payload[i] = IcmpPayload[i]
  req.checksum = 0
  let arr = cast[ptr UncheckedArray[uint8]](addr req)
  req.checksum = htons(inetChecksum(arr, sizeof(IcmpEcho)))
  nimfw_dbg_icmp_tx_checksum = htons(req.checksum).uint32

  let pbuf = pbufAlloc(pbufRaw, IcmpPacketBytes, pbufRam)
  if pbuf == nil:
    rawRemove(pcb)
    phaseMark(Phase.icmp, Kind.fail):
      kvWrite("reason", "tx_failed")
      kvWrite("required", uint32(requiredReply))
    return not requiredReply
  discard pbufTake(pbuf, addr req, IcmpPacketBytes)
  var dstAddr: IpAddr
  dstAddr.address = targetAddress
  let txRc = rawSendto(pcb, pbuf, addr dstAddr)
  nimfw_dbg_icmp_tx_rc = cast[uint32](txRc)
  discard pbufFree(pbuf)
  if txRc != ErrOk:
    rawRemove(pcb)
    phaseMark(Phase.icmp, Kind.fail):
      kvWrite("reason", "tx_failed")
      kvWrite("rc", txRc.int32)
      kvWrite("required", uint32(requiredReply))
    return not requiredReply

  let icmpDeadline = nowMs() + IcmpTimeoutMs
  while not icmpState.replied:
    pollNetwork()
    inc nimfw_dbg_icmp_timeout_polls
    if nowMs() >= icmpDeadline:
      nimfw_dbg_icmp_tcpip_ok_after = wifi_nimfw_tcpip_input_ok()
      rawRemove(pcb)
      phaseMark(Phase.icmp, Kind.fail):
        kvWrite("reason", "recv_timeout")
        kvWrite("cb", nimfw_dbg_icmp_cb_count)
        kvWrite("rej", nimfw_dbg_icmp_cb_reject)
        kvWrite("ip0", nimfw_dbg_icmp_cb_ip0)
        kvWrite("type", nimfw_dbg_icmp_cb_type_code)
        kvWrite("tcpi", nimfw_dbg_icmp_tcpip_ok_after -
          nimfw_dbg_icmp_tcpip_ok_before)
        kvWrite("required", uint32(requiredReply))
      return not requiredReply
  nimfw_dbg_icmp_tcpip_ok_after = wifi_nimfw_tcpip_input_ok()
  rawRemove(pcb)
  phaseMark(Phase.icmp, Kind.ok):
    kvWrite("rtt_ms", icmpState.rttMs)
    kvWrite("seq", icmpState.seq)
    kvWrite("cb", nimfw_dbg_icmp_cb_count)
    kvWrite("dst", targetAddress)
  true

var console: Uart

proc setupConsole() =
  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

proc runOneAttempt(): bool {.nimcall.} =
  # Synthetic markers up through assoc (Iter 1 pattern: vendor blob's
  # wifiConnect collapses scan/auth/4whs/assoc into a single call).
  phaseMark(Phase.scan, Kind.start)
  let initRc = wifiInit()
  if initRc != wifiOk:
    phaseMark(Phase.scan, Kind.fail):
      kvWrite("reason", "init_failed")
    return false
  phaseMark(Phase.scan, Kind.ok)

  phaseMark(Phase.auth, Kind.start)
  let connectRc = wifiConnect(WifiSsid, WifiPassword, WifiChannel.uint8)
  if connectRc != wifiOk:
    wifi_nimfw_debug_snapshot()
    phaseMark(Phase.auth, Kind.fail):
      kvWrite("reason", "connect_failed")
      kvWrite("status", bl808_wifi_backend_last_status())
      kvWrite("code", bl808_wifi_backend_last_reason())
      kvWrite("auth_mgt", (nimfw_dbg_auth_mgt_seen and 0xff'u32) or
        ((nimfw_dbg_auth_mgt_accept and 0xff'u32) shl 8) or
        ((nimfw_dbg_auth_mgt_reject and 0xff'u32) shl 16) or
        ((nimfw_dbg_auth_mgt_msg and 0xff'u32) shl 24))
      kvWrite("auth_mgt0", nimfw_dbg_auth_mgt_last0)
      kvWrite("auth_mgt1", nimfw_dbg_auth_mgt_last1)
      kvWrite("mgt", (nimfw_dbg_mgt_seen and 0xff'u32) or
        ((nimfw_dbg_mgt_accept and 0xff'u32) shl 8) or
        ((nimfw_dbg_mgt_reject and 0xff'u32) shl 16) or
        ((nimfw_dbg_mgt_msg and 0xff'u32) shl 24))
      kvWrite("mgt_fc", nimfw_dbg_mgt_last_fc)
      kvWrite("mgt0", nimfw_dbg_mgt_last0)
      kvWrite("mgt1", nimfw_dbg_mgt_last1)
      kvWrite("mgt_drop", nimfw_dbg_mgt_drop_reason)
      kvWrite("auth_sm", (nimfw_dbg_auth_sm_dispatch and 0xffff'u32) or
        ((nimfw_dbg_auth_sm_state and 0xffff'u32) shl 16))
      kvWrite("auth_h", (nimfw_dbg_auth_handler and 0xffff'u32) or
        ((nimfw_dbg_auth_handler_last and 0xffff'u32) shl 16))
      kvWrite("auth_h2", nimfw_dbg_auth_handler_last)
      kvWrite("auth_open", nimfw_dbg_auth_open_success)
      kvWrite("auth_tx_len", nimfw_dbg_auth_tx_len)
      kvWrite("auth_tx_meta", nimfw_dbg_auth_tx_meta)
      kvWrite("auth_tx_desc", nimfw_dbg_auth_tx_desc)
      kvWrite("auth_cfm", (nimfw_dbg_auth_cfm_push and 0xff'u32) or
        ((nimfw_dbg_auth_cfm_frame and 0xff'u32) shl 8) or
        ((nimfw_dbg_auth_cfm_evt and 0xff'u32) shl 16))
      kvWrite("auth_cfm_st", nimfw_dbg_auth_cfm_status)
      kvWrite("auth_cfm_hw", nimfw_dbg_auth_cfm_hw_status)
      kvWrite("auth_cfm_desc", nimfw_dbg_auth_cfm_desc)
      kvWrite("auth_cfm_meta", nimfw_dbg_auth_cfm_meta)
      kvWrite("auth_cfm_fc", nimfw_dbg_auth_cfm_fc)
      kvWrite("assoc_req", nimfw_dbg_assoc_req_send)
      kvWrite("assoc_meta", nimfw_dbg_assoc_req_meta)
      kvWrite("assoc_cfm", (nimfw_dbg_assoc_cfm_push and 0xff'u32) or
        ((nimfw_dbg_assoc_cfm_frame and 0xff'u32) shl 8) or
        ((nimfw_dbg_assoc_cfm_evt and 0xff'u32) shl 16))
      kvWrite("assoc_cfm_st", nimfw_dbg_assoc_cfm_status)
      kvWrite("assoc_cfm_hw", nimfw_dbg_assoc_cfm_hw_status)
      kvWrite("assoc_cfm_desc", nimfw_dbg_assoc_cfm_desc)
      kvWrite("assoc_cfm_meta", nimfw_dbg_assoc_cfm_meta)
      kvWrite("assoc_cfm_fc", nimfw_dbg_assoc_cfm_fc)
      kvWrite("assoc_rsp", (nimfw_dbg_assoc_rsp_count and 0xffff'u32) or
        ((nimfw_dbg_assoc_rsp_status and 0xffff'u32) shl 16))
      kvWrite("assoc_len", nimfw_dbg_assoc_rsp_len)
      kvWrite("assoc_b0", nimfw_dbg_assoc_rsp_b0)
      kvWrite("assoc_b4", nimfw_dbg_assoc_rsp_b4)
      kvWrite("post_assoc", (nimfw_dbg_set_vif_state and 0xff'u32) or
        ((nimfw_dbg_set_vif_state_act and 0xff'u32) shl 8) or
        ((nimfw_dbg_assoc_done and 0xff'u32) shl 16) or
        ((nimfw_dbg_conn_ind_prepath and 0xff'u32) shl 24))
      kvWrite("vif_state", nimfw_dbg_set_vif_state_new)
      kvWrite("wpa_state", (nimfw_dbg_vif_sectype and 0xff'u32) or
        ((nimfw_wpa_pending_mask and 0xff'u32) shl 8) or
        ((nimfw_dbg_ptk_init_done and 0xff'u32) shl 16) or
        ((nimfw_dbg_vif_wpastate and 0xff'u32) shl 24))
      kvWrite("eapol", (nimfw_dbg_eapol_in and 0xff'u32) or
        ((nimfw_dbg_eapol_dropped and 0xff'u32) shl 8) or
        ((nimfw_dbg_eapol_fwd and 0xff'u32) shl 16) or
        ((nimfw_dbg_rxu_assoc_eapol and 0xff'u32) shl 24))
      kvWrite("eapol_cb", (nimfw_dbg_eapol_cb_inv and 0xff'u32) or
        ((nimfw_dbg_eapol_cb_null and 0xff'u32) shl 8) or
        ((nimfw_dbg_sm_state_eapol and 0xff'u32) shl 16) or
        ((nimfw_dbg_eapol_tx_cb and 0xff'u32) shl 24))
      kvWrite("supp_eap", (nimfw_dbg_supp_rx_eapol and 0xff'u32) or
        ((nimfw_dbg_supp_tx_eapol and 0xff'u32) shl 8) or
        ((nimfw_dbg_eth_tx_eapol and 0xff'u32) shl 16) or
        ((nimfw_dbg_bl_output_eapol and 0xff'u32) shl 24))
      kvWrite("wpa_deauth", (nimfw_dbg_wpa_deauth and 0xffff'u32) or
        ((nimfw_dbg_eth_tx_ret and 0xffff'u32) shl 16))
      kvWrite("blcfm", (nimfw_dbg_bl_tx_cfm and 0xff'u32) or
        ((nimfw_dbg_bl_tx_cfm_cb and 0xff'u32) shl 8) or
        ((nimfw_dbg_bl_tx_cfm_eapol and 0xff'u32) shl 16) or
        ((nimfw_dbg_eapol_cfm_count and 0xff'u32) shl 24))
      kvWrite("cfm_ack", (nimfw_dbg_eapol_cfm_ack_ok and 0xffff'u32) or
        ((nimfw_dbg_eapol_cfm_ack_fail and 0xffff'u32) shl 16))
      kvWrite("cfm_st", nimfw_dbg_eapol_cfm_status)
      kvWrite("cfm_cbp", nimfw_dbg_cfm_cb_ptr_last)
      kvWrite("eap_txd", nimfw_dbg_eapol_tx_desc_bytes)
      kvWrite("eap_h0", nimfw_dbg_eapol_tx_hdr0)
      kvWrite("eap_h1", nimfw_dbg_eapol_tx_hdr1)
      kvWrite("eap_h2", nimfw_dbg_eapol_tx_hdr2)
      kvWrite("eap_h3", nimfw_dbg_eapol_tx_hdr3)
      kvWrite("eap_ahi", nimfw_dbg_eapol_tx_addr_hi)
      kvWrite("eap_pol", nimfw_dbg_eapol_tx_policy)
      kvWrite("eap_buf", nimfw_dbg_eapol_tx_buf_desc)
      kvWrite("eap_hw", nimfw_dbg_eapol_tx_hw_desc)
      kvWrite("eap_rate0", nimfw_dbg_eapol_tx_rate0)
      kvWrite("eap_rate1", nimfw_dbg_eapol_tx_rate1)
      kvWrite("eap_rate2", nimfw_dbg_eapol_tx_rate2)
      kvWrite("eap_rate3", nimfw_dbg_eapol_tx_rate3)
      kvWrite("eap_link0", nimfw_dbg_eapol_tx_link0)
      kvWrite("eap_link1", nimfw_dbg_eapol_tx_link1)
      kvWrite("m4", (nimfw_dbg_send_4of4_tx and 0xff'u32) or
        ((nimfw_dbg_send_4of4_cb and 0xff'u32) shl 8) or
        ((nimfw_dbg_install_ptk and 0xff'u32) shl 16) or
        ((nimfw_dbg_supp_tx_len and 0xff'u32) shl 24))
      kvWrite("m4_state", (nimfw_dbg_m4_tx_state and 0xffff'u32) or
        ((nimfw_dbg_wpa_ptk_installed and 0xffff'u32) shl 16))
      kvWrite("m4_cbp", nimfw_dbg_m4_cb_ptr)
      kvWrite("wpa_sm", (nimfw_dbg_wpa_state and 0xff'u32) or
        ((nimfw_dbg_wpa_tx_state and 0xff'u32) shl 8) or
        ((nimfw_dbg_wpa_rx_state and 0xff'u32) shl 16))
      kvWrite("key0", nimfw_dbg_setkey0)
      kvWrite("key1", nimfw_dbg_setkey1)
      kvWrite("auth_tx0", loadLe32(nimfw_dbg_auth_tx_raw, 0))
      kvWrite("auth_tx4", loadLe32(nimfw_dbg_auth_tx_raw, 4))
      kvWrite("auth_tx8", loadLe32(nimfw_dbg_auth_tx_raw, 8))
      kvWrite("auth_tx12", loadLe32(nimfw_dbg_auth_tx_raw, 12))
      kvWrite("auth_tx16", loadLe32(nimfw_dbg_auth_tx_raw, 16))
      kvWrite("auth_tx20", loadLe32(nimfw_dbg_auth_tx_raw, 20))
      kvWrite("auth_tx24", loadLe32(nimfw_dbg_auth_tx_raw, 24))
      kvWrite("auth_tx28", loadLe32(nimfw_dbg_auth_tx_raw, 28))
      kvWrite("scan_bss", (nimfw_dbg_scan_frame_seen and 0xffff'u32) or
        ((nimfw_dbg_scan_frame_accept and 0xffff'u32) shl 16))
      kvWrite("scan_last", nimfw_dbg_scan_frame_last)
      kvWrite("scan_ssid", nimfw_dbg_scan_ssid_last)
      kvWrite("bss_in", nimfw_dbg_bss_in)
      kvWrite("bss_ssid", nimfw_dbg_bss_ssid_result)
      kvWrite("bss_dir", nimfw_dbg_bss_directed)
      kvWrite("bss_out", nimfw_dbg_bss_out)
      kvWrite("ssid_s", nimfw_dbg_ssid_search)
      kvWrite("ssid_hits", (nimfw_dbg_ssid_entries and 0xffff'u32) or
        ((nimfw_dbg_ssid_hits and 0xffff'u32) shl 16))
      kvWrite("tx_lmac", (nimfw_dbg_cfm_push and 0xff'u32) or
        ((nimfw_dbg_cfm_evt and 0xff'u32) shl 8) or
        ((nimfw_dbg_frame_cfm and 0xff'u32) shl 16))
      kvWrite("txint0", (nimfw_dbg_txint_enter and 0xff'u32) or
        ((nimfw_dbg_txint_ready and 0xff'u32) shl 8) or
        ((nimfw_dbg_txint_psok and 0xff'u32) shl 16) or
        ((nimfw_dbg_txint_push and 0xff'u32) shl 24))
      kvWrite("txint1", (nimfw_dbg_txint_release and 0xffff'u32) or
        ((nimfw_dbg_txint_postpone and 0xffff'u32) shl 16))
      kvWrite("txint_fc", nimfw_dbg_txint_last_fc)
      kvWrite("txint_meta", nimfw_dbg_txint_meta)
      kvWrite("txint_chan", nimfw_dbg_txint_chan)
      kvWrite("txint_q", nimfw_dbg_txint_queue)
      kvWrite("txint_hw", nimfw_dbg_txint_hw)
      kvWrite("txtrig0", (nimfw_dbg_txtrig_entry and 0xff'u32) or
        ((nimfw_dbg_txtrig_zero and 0xff'u32) shl 8) or
        ((nimfw_dbg_txtrig_loops and 0xffff'u32) shl 16))
      kvWrite("txtrig_stat", nimfw_dbg_txtrig_acready)
      kvWrite("txtrig_desc", nimfw_dbg_txtrig_desc)
      kvWrite("txtrig_thd", nimfw_dbg_txtrig_status)
      kvWrite("txtrig_ret", (nimfw_dbg_txtrig_notready and 0xffff'u32) or
        ((nimfw_dbg_txtrig_nodesc and 0xffff'u32) shl 16))
      kvWrite("pay0", (nimfw_dbg_pay_backup and 0xff'u32) or
        ((nimfw_dbg_pay_desc and 0xff'u32) shl 8) or
        ((nimfw_dbg_pay_payload and 0xff'u32) shl 16) or
        ((nimfw_dbg_pay_empty and 0xff'u32) shl 24))
      kvWrite("pay1", (nimfw_dbg_pay_nonempty and 0xffff'u32) or
        ((nimfw_dbg_pay_trig and 0xffff'u32) shl 16))
      kvWrite("pay_trig", nimfw_dbg_pay_trig)
      kvWrite("pay_stat", nimfw_dbg_pay_tx_status)
      kvWrite("pay_agg", nimfw_dbg_pay_tx_agg)
      kvWrite("pay_dma", nimfw_dbg_pay_tx_dma)
      kvWrite("pay_cur", nimfw_dbg_pay_tx_current)
      kvWrite("pay_thd", nimfw_dbg_pay_tx_thd)
      kvWrite("pay_head", nimfw_dbg_pay_tx_head)
      kvWrite("probe_meta", nimfw_dbg_probe_pay_meta)
      kvWrite("probe_desc", nimfw_dbg_probe_pay_desc)
      kvWrite("probe_link", nimfw_dbg_probe_pay_link)
      kvWrite("probe_hw", nimfw_dbg_probe_pay_hw)
      kvWrite("probe_thd", nimfw_dbg_probe_pay_thd)
      kvWrite("probe_len", nimfw_dbg_probe_pay_len)
      kvWrite("probe_hw0", nimfw_dbg_probe_pay_hw0)
      kvWrite("probe_hw1", nimfw_dbg_probe_pay_hw1)
      kvWrite("probe_hw2", nimfw_dbg_probe_pay_hw2)
      kvWrite("probe_hw3", nimfw_dbg_probe_pay_hw3)
      kvWrite("probe_l0", nimfw_dbg_probe_pay_link0)
      kvWrite("probe_l1", nimfw_dbg_probe_pay_link1)
      kvWrite("probe_hs", nimfw_dbg_probe_pay_hw_start)
      kvWrite("probe_he", nimfw_dbg_probe_pay_hw_end)
      kvWrite("probe_hl", nimfw_dbg_probe_pay_hw_frame_len)
      kvWrite("probe_hstat", nimfw_dbg_probe_pay_hw_status)
      kvWrite("probe_hctrl", nimfw_dbg_probe_pay_hw_ctrl)
      kvWrite("probe_hchain", nimfw_dbg_probe_pay_hw_chain)
      kvWrite("probe_h36", nimfw_dbg_probe_pay_hw_word36)
      kvWrite("probe_h56", nimfw_dbg_probe_pay_hw_word56)
      kvWrite("probe_ie_len", nimfw_dbg_probe_ie_len)
      kvWrite("probe_ie0", loadLe32(nimfw_dbg_probe_ie_raw, 0))
      kvWrite("probe_ie4", loadLe32(nimfw_dbg_probe_ie_raw, 4))
      kvWrite("probe_ie8", loadLe32(nimfw_dbg_probe_ie_raw, 8))
      kvWrite("probe_ie12", loadLe32(nimfw_dbg_probe_ie_raw, 12))
      kvWrite("probe_ie16", loadLe32(nimfw_dbg_probe_ie_raw, 16))
      kvWrite("probe_ie20", loadLe32(nimfw_dbg_probe_ie_raw, 20))
      kvWrite("probe0", loadLe32(nimfw_dbg_probe_pay_raw, 0))
      kvWrite("probe4", loadLe32(nimfw_dbg_probe_pay_raw, 4))
      kvWrite("probe8", loadLe32(nimfw_dbg_probe_pay_raw, 8))
      kvWrite("probe12", loadLe32(nimfw_dbg_probe_pay_raw, 12))
      kvWrite("probe16", loadLe32(nimfw_dbg_probe_pay_raw, 16))
      kvWrite("probe20", loadLe32(nimfw_dbg_probe_pay_raw, 20))
      kvWrite("probe24", loadLe32(nimfw_dbg_probe_pay_raw, 24))
      kvWrite("probe28", loadLe32(nimfw_dbg_probe_pay_raw, 28))
      kvWrite("probe32", loadLe32(nimfw_dbg_probe_pay_raw, 32))
      kvWrite("probe36", loadLe32(nimfw_dbg_probe_pay_raw, 36))
      kvWrite("probe40", loadLe32(nimfw_dbg_probe_pay_raw, 40))
      kvWrite("probe44", loadLe32(nimfw_dbg_probe_pay_raw, 44))
      kvWrite("probe48", loadLe32(nimfw_dbg_probe_pay_raw, 48))
      kvWrite("probe52", loadLe32(nimfw_dbg_probe_pay_raw, 52))
      kvWrite("probe56", loadLe32(nimfw_dbg_probe_pay_raw, 56))
      kvWrite("probe60", loadLe32(nimfw_dbg_probe_pay_raw, 60))
      kvWrite("irq", (nimfw_dbg_mac_irq and 0xffff'u32) or
        ((nimfw_dbg_machw_gen and 0xffff'u32) shl 16))
      kvWrite("irq_last", nimfw_dbg_mac_irq_last)
      kvWrite("machw", nimfw_dbg_machw_status)
      kvWrite("gen", nimfw_dbg_machw_gen_status)
      kvWrite("rxl_evt", (nimfw_dbg_rxl_timer_evt and 0xff'u32) or
        ((nimfw_dbg_rxl_cntrl_evt and 0xff'u32) shl 8) or
        ((nimfw_dbg_rxl_dma_evt and 0xff'u32) shl 16) or
        ((nimfw_dbg_rxl_timer_ready and 0xff'u32) shl 24))
      kvWrite("rxl_head", nimfw_dbg_rxl_timer_head)
      kvWrite("rxl_q", nimfw_dbg_rxl_cntrl_head)
      kvWrite("rxhd", nimfw_dbg_rxl_snap_hd)
      kvWrite("rxpd", nimfw_dbg_rxl_snap_pd)
      kvWrite("rxhw0", nimfw_dbg_rxl_snap_hw_hd)
      kvWrite("rxhw1", nimfw_dbg_rxl_snap_hw_pd)
      kvWrite("rxmask", nimfw_dbg_rxl_snap_mask)
      kvWrite("rxctl", nimfw_dbg_rxl_snap_rxctrl)
      kvWrite("intmsk", nimfw_dbg_rxl_snap_int_unmask)
      kvWrite("genmsk", nimfw_dbg_rxl_snap_gen_unmask)
      kvWrite("irqraw", nimfw_dbg_rxl_snap_irq_raw)
      kvWrite("genraw", nimfw_dbg_rxl_snap_gen_raw)
      kvWrite("rxctrl", nimfw_dbg_rxl_snap_rxctrl_raw)
      kvWrite("macstat", nimfw_dbg_rxl_snap_status_raw)
      kvWrite("rxhds", nimfw_dbg_rxl_snap_hd_status)
      kvWrite("rxpds", nimfw_dbg_rxl_snap_pd_status)
      kvWrite("scan_rx0", nimfw_dbg_scan_start_rxctrl)
      kvWrite("scan_irq0", nimfw_dbg_scan_start_irq_raw)
      kvWrite("scan_gen0", nimfw_dbg_scan_start_gen_raw)
      kvWrite("scan_rx1", nimfw_dbg_scan_end_rxctrl)
      kvWrite("scan_irq1", nimfw_dbg_scan_end_irq_raw)
      kvWrite("scan_gen1", nimfw_dbg_scan_end_gen_raw)
      kvWrite("scan_reqm", nimfw_dbg_scan_req_chan_meta)
      kvWrite("scan_reqf", nimfw_dbg_scan_req_chan_freq)
      kvWrite("chan_scm", nimfw_dbg_chan_scan_chan_meta)
      kvWrite("chan_scf", nimfw_dbg_chan_scan_chan_freq)
      kvWrite("chan_prm", nimfw_dbg_chan_pre_chan_meta)
      kvWrite("chan_prf", nimfw_dbg_chan_pre_chan_freq)
      kvWrite("phy0_0", nimfw_dbg_scan_start_phy_raw[0])
      kvWrite("phy0_1", nimfw_dbg_scan_start_phy_raw[1])
      kvWrite("phy0_2", nimfw_dbg_scan_start_phy_raw[2])
      kvWrite("phy0_3", nimfw_dbg_scan_start_phy_raw[3])
      kvWrite("phy1_0", nimfw_dbg_scan_end_phy_raw[0])
      kvWrite("phy1_1", nimfw_dbg_scan_end_phy_raw[1])
      kvWrite("phy1_2", nimfw_dbg_scan_end_phy_raw[2])
      kvWrite("phy1_3", nimfw_dbg_scan_end_phy_raw[3])
      when defined(bl808WifiUseBl808Rf):
        let rfStageCount = nim_wifi_rf_stage_snapshot_count
        let rfStageIdx =
          if rfStageCount == 0'u32: 0 else: int((rfStageCount - 1'u32) and 0x7'u32)
        kvWrite("rfst_n", rfStageCount)
        kvWrite("rfst_tag", nim_wifi_rf_stage_tag_log[rfStageIdx])
        kvWrite("rfst_70", nim_wifi_rf_stage_rf70_log[rfStageIdx])
        kvWrite("rfst_88", nim_wifi_rf_stage_rf88_log[rfStageIdx])
        kvWrite("rfst_d0", nim_wifi_rf_stage_rfd0_log[rfStageIdx])
        kvWrite("rfst_a0", nim_wifi_rf_stage_rfa0_log[rfStageIdx])
        kvWrite("rfst_1600", nim_wifi_rf_stage_rf1600_log[rfStageIdx])
        kvWrite("rfst_b4", nim_wifi_rf_stage_rfb4_log[rfStageIdx])
        kvWrite("rfst_bc", nim_wifi_rf_stage_rfbc_log[rfStageIdx])
        kvWrite("rfcal_n", (nimfw_dbg_rf_cal_save_count and 0xffff'u32) or
          ((nimfw_dbg_rf_cal_restore_count and 0xffff'u32) shl 16))
        kvWrite("rfcal_88", nimfw_dbg_rf_cal_save_rf88)
        kvWrite("rfcal_r88", nimfw_dbg_rf_cal_restore_rf88)
        kvWrite("rfcal_rb88", nimfw_dbg_rf_cal_restore_readback_rf88)
        kvWrite("rfcal_r8c", nimfw_dbg_rf_cal_restore_rf8c)
      kvWrite("rxu_valid", nimfw_dbg_rxu_frame_valid)
      kvWrite("rxu_data", (nimfw_dbg_rxu_assoc_data and 0xffff'u32) or
        ((nimfw_dbg_rxu_nonassoc_data and 0xffff'u32) shl 16))
      kvWrite("rxu_mgmt", nimfw_dbg_rxu_assoc_mgmt)
      kvWrite("rxu_drop0", (nimfw_dbg_rxu_drop_invalid and 0xff'u32) or
        ((nimfw_dbg_rxu_drop_sta_inactive and 0xff'u32) shl 8) or
        ((nimfw_dbg_rxu_drop_ftype and 0xff'u32) shl 16) or
        ((nimfw_dbg_rxu_drop_null and 0xff'u32) shl 24))
      kvWrite("rxu_drop1", (nimfw_dbg_rxu_drop_dup and 0xffff'u32) or
        ((nimfw_dbg_rxu_drop_pn and 0xffff'u32) shl 16))
    return false
  phaseMark(Phase.auth, Kind.ok)
  phaseMark(Phase.ph4whs, Kind.start)
  phaseMark(Phase.ph4whs, Kind.ok)
  phaseMark(Phase.assoc, Kind.start)
  phaseMark(Phase.assoc, Kind.ok)

  # DHCP.
  phaseMark(Phase.dhcp, Kind.start)
  let netifRaw = wifiGetNetif()
  if netifRaw == nil:
    phaseMark(Phase.dhcp, Kind.fail):
      kvWrite("reason", "no_netif")
    return false
  let netif = cast[ptr Netif](netifRaw)
  let dhcpRc = dhcpStart(netif)
  if dhcpRc != ErrOk:
    phaseMark(Phase.dhcp, Kind.fail):
      kvWrite("reason", "dhcp_start")
      kvWrite("rc", dhcpRc.int32)
    return false
  let dhcpDeadline = nowMs() + DhcpTimeoutMs
  while netifIp4(netif) == 0:
    pollNetwork()
    if nowMs() >= dhcpDeadline:
      phaseMark(Phase.dhcp, Kind.fail):
        kvWrite("reason", "timeout")
        kvWrite("rx_calls", wifi_nimfw_tcpip_input_calls())
        kvWrite("rx_ok", wifi_nimfw_tcpip_input_ok())
        kvWrite("rx_fail", wifi_nimfw_tcpip_input_fail())
        kvWrite("rx_drops", wifi_nimfw_tcpip_input_drop_flags())
        kvWrite("rx_no_pbuf", wifi_nimfw_tcpip_input_no_pbuf())
        kvWrite("rx_mpdu", nimfw_dbg_tcpip_input_mpdu_conv)
        kvWrite("rx_mpfail", nimfw_dbg_tcpip_input_mpdu_fail)
        kvWrite("rx_mpfcnt", nimfw_dbg_tcpip_input_mpdu_fail_counts)
        kvWrite("rx_mpflo", nimfw_dbg_tcpip_input_mpdu_fail_detail_lo)
        kvWrite("rx_mpfhi", nimfw_dbg_tcpip_input_mpdu_fail_detail_hi)
        kvWrite("rx_mpl0", nimfw_dbg_tcpip_input_mpdu_last0)
        kvWrite("rx_mpl1", nimfw_dbg_tcpip_input_mpdu_last1)
        kvWrite("rx_mpl2", nimfw_dbg_tcpip_input_mpdu_last2)
        kvWrite("pbuf_fail", (nimfw_dbg_pbuf_alloc_fail and 0xffff'u32) or
          ((nimfw_dbg_pbuf_take_fail and 0xffff'u32) shl 16))
        kvWrite("rx_eth", nimfw_dbg_tcpip_input_eth)
        kvWrite("rx_udp", nimfw_dbg_tcpip_input_udp)
        kvWrite("rx_dhcprx", nimfw_dbg_tcpip_input_dhcp_rx)
        kvWrite("rx_ports", nimfw_dbg_tcpip_input_last_ports)
        kvWrite("rx_ip", nimfw_dbg_tcpip_input_last_ip)
        kvWrite("rx_dhcpm", nimfw_dbg_tcpip_input_dhcp_meta)
        kvWrite("rx_dhcpx", nimfw_dbg_tcpip_input_dhcp_xid)
        kvWrite("rx_dhcpyi", nimfw_dbg_tcpip_input_dhcp_yiaddr)
        kvWrite("rx_dhcpch0", nimfw_dbg_tcpip_input_dhcp_ch0)
        kvWrite("rx_dhcpch1", nimfw_dbg_tcpip_input_dhcp_ch1)
        kvWrite("rx_fl0", nimfw_dbg_tcpip_input_frame_last0)
        kvWrite("rx_fl1", nimfw_dbg_tcpip_input_frame_last1)
        kvWrite("rx_fs0", nimfw_dbg_tcpip_input_frame_src0)
        kvWrite("rx_fs1", nimfw_dbg_tcpip_input_frame_src1)
        kvWrite("rx_fs2", nimfw_dbg_tcpip_input_frame_src2)
        kvWrite("rx_fs3", nimfw_dbg_tcpip_input_frame_src3)
        kvWrite("rx_fp0", nimfw_dbg_tcpip_input_frame_pbuf0)
        kvWrite("rx_fp1", nimfw_dbg_tcpip_input_frame_pbuf1)
        kvWrite("rx_fp2", nimfw_dbg_tcpip_input_frame_pbuf2)
        kvWrite("rx_fp3", nimfw_dbg_tcpip_input_frame_pbuf3)
        kvWrite("rx_fet", nimfw_dbg_tcpip_input_frame_ethertype)
        kvWrite("lwip_dhcprx", nimfw_dbg_lwip_dhcp_recv_count)
        kvWrite("lwip_dhcpc", nimfw_dbg_lwip_dhcp_recv_code)
        kvWrite("lwip_dhcpl", nimfw_dbg_lwip_dhcp_recv_len)
        kvWrite("lwip_dhcpm", nimfw_dbg_lwip_dhcp_recv_meta)
        kvWrite("lwip_dhcpo", nimfw_dbg_lwip_dhcp_offer_count)
        kvWrite("lwip_dhcpoc", nimfw_dbg_lwip_dhcp_offer_code)
        kvWrite("lwip_dhcpos", nimfw_dbg_lwip_dhcp_offer_server)
        kvWrite("lwip_dhcpoi", nimfw_dbg_lwip_dhcp_offer_ip)
        kvWrite("lwip_dhcps", nimfw_dbg_lwip_dhcp_select_count)
        kvWrite("lwip_dhcpcr", nimfw_dbg_lwip_dhcp_create_count)
        kvWrite("lwip_dhcpcm", nimfw_dbg_lwip_dhcp_create_meta)
        kvWrite("lwip_dhcpch", nimfw_dbg_lwip_dhcp_create_hist)
        let hs = heapStats()
        kvWrite("heap_used", hs.usedBytes.uint32)
        kvWrite("heap_free", hs.freeBytes.uint32)
        kvWrite("heap_hi", hs.highWaterBytes.uint32)
        kvWrite("heap_min", hs.minFreeBytes.uint32)
        kvWrite("heap_largest", hs.largestFreeBytes.uint32)
        kvWrite("heap_fail", hs.allocFailCount.uint32)
        kvWrite("heap_bad", (hs.invalidFreeCount.uint32 and 0xffff'u32) or
          ((hs.canaryFailCount.uint32 and 0xffff'u32) shl 16))
        kvWrite("tx_push", nimfw_dbg_tx_push_calls)
        kvWrite("tx_cfm", nimfw_dbg_bl_tx_cfm)
        kvWrite("tx_drop", nimfw_dbg_bl_output_drop)
        kvWrite("tx_sta_lu", nimfw_dbg_tx_sta_lookup)
        kvWrite("tx_sta_luf", nimfw_dbg_tx_sta_lookup_fail)
        kvWrite("tx_sta_mode", nimfw_dbg_tx_sta_lookup_mode)
        kvWrite("tx_sta_vif", nimfw_dbg_tx_sta_lookup_vif)
        kvWrite("tx_sta_sta", nimfw_dbg_tx_sta_lookup_sta)
        kvWrite("tx_sta_res", nimfw_dbg_tx_sta_lookup_result)
        kvWrite("tx_sta_eth", nimfw_dbg_tx_sta_lookup_eth)
        kvWrite("tx_sta_dst0", nimfw_dbg_tx_sta_lookup_dst0)
        kvWrite("tx_sta_dst1", nimfw_dbg_tx_sta_lookup_dst1)
        kvWrite("rx_sm_sta", nimfw_dbg_rx_sm_sta_add)
        kvWrite("rx_sm_stam", nimfw_dbg_rx_sm_sta_add_meta)
        kvWrite("rx_sm_vif", nimfw_dbg_rx_sm_sta_add_vif)
        kvWrite("rx_sm_sta2", nimfw_dbg_rx_sm_sta_add_sta)
        kvWrite("rx_sm_err", nimfw_dbg_rx_sm_sta_add_error)
        kvWrite("rx_sm_disc", nimfw_dbg_rx_sm_disc)
        kvWrite("rx_sm_seq", nimfw_dbg_rx_sm_seq)
        kvWrite("rx_sm_addseq", nimfw_dbg_rx_sm_sta_add_seq)
        kvWrite("rx_sm_dseq", nimfw_dbg_rx_sm_disc_seq)
        kvWrite("rx_sm_dmeta", nimfw_dbg_rx_sm_disc_meta)
        kvWrite("rx_sm_dvif", nimfw_dbg_rx_sm_disc_vif)
        kvWrite("rx_sm_dsta", nimfw_dbg_rx_sm_disc_sta)
        kvWrite("tx_wait", (nimfw_dbg_tx_nodesc and 0xffff'u32) or
          ((nimfw_dbg_tx_nobuf and 0xffff'u32) shl 16))
        kvWrite("tx_lmac", (nimfw_dbg_cfm_push and 0xff'u32) or
          ((nimfw_dbg_cfm_evt and 0xff'u32) shl 8) or
          ((nimfw_dbg_frame_cfm and 0xff'u32) shl 16))
        kvWrite("tx_sec", (nimfw_dbg_tx_sec_hdr_calls and 0xff'u32) or
          ((nimfw_dbg_tx_sec_hdr_append and 0xff'u32) shl 8) or
          ((nimfw_dbg_tx_sec_hdr_cipher and 0xff'u32) shl 16) or
          ((nimfw_dbg_tx_sec_hdr_len and 0xff'u32) shl 24))
        kvWrite("tx_sec_drop", (nimfw_dbg_tx_sec_hdr_no_keymat and 0xffff'u32) or
          ((nimfw_dbg_tx_sec_hdr_no_keyslot and 0xffff'u32) shl 16))
        kvWrite("tx_sec_miss", nimfw_dbg_tx_sec_hdr_miss_meta)
        kvWrite("tx_sec_mlen", nimfw_dbg_tx_sec_hdr_miss_len)
        kvWrite("tx_sec_mkey", nimfw_dbg_tx_sec_hdr_miss_keymat)
        kvWrite("tx_rf_latch", nimfw_dbg_sta_tx_rf_latch)
        kvWrite("eap_cfm", (nimfw_dbg_eapol_cfm_count and 0xff'u32) or
          ((nimfw_dbg_eapol_cfm_ack_ok and 0xff'u32) shl 8) or
          ((nimfw_dbg_eapol_cfm_ack_fail and 0xff'u32) shl 16))
        kvWrite("eap_cfs", nimfw_dbg_eapol_cfm_status)
        kvWrite("eap_cri", nimfw_dbg_eapol_cfm_ring_idx)
        kvWrite("eap_cs0", nimfw_dbg_eapol_cfm_status_log[0])
        kvWrite("eap_cs1", nimfw_dbg_eapol_cfm_status_log[1])
        kvWrite("eap_cs2", nimfw_dbg_eapol_cfm_status_log[2])
        kvWrite("eap_cs3", nimfw_dbg_eapol_cfm_status_log[3])
        kvWrite("eap_cm0", nimfw_dbg_eapol_cfm_meta_log[0])
        kvWrite("eap_cm1", nimfw_dbg_eapol_cfm_meta_log[1])
        kvWrite("eap_cm2", nimfw_dbg_eapol_cfm_meta_log[2])
        kvWrite("eap_cm3", nimfw_dbg_eapol_cfm_meta_log[3])
        kvWrite("eap_ck0", nimfw_dbg_eapol_cfm_key_log[0])
        kvWrite("eap_ck1", nimfw_dbg_eapol_cfm_key_log[1])
        kvWrite("eap_ck2", nimfw_dbg_eapol_cfm_key_log[2])
        kvWrite("eap_ck3", nimfw_dbg_eapol_cfm_key_log[3])
        kvWrite("eap_rp0", nimfw_dbg_eapol_cfm_replay_log[0])
        kvWrite("eap_rp1", nimfw_dbg_eapol_cfm_replay_log[1])
        kvWrite("eap_rp2", nimfw_dbg_eapol_cfm_replay_log[2])
        kvWrite("eap_rp3", nimfw_dbg_eapol_cfm_replay_log[3])
        kvWrite("eap_txd", nimfw_dbg_eapol_tx_desc_bytes)
        kvWrite("eap_h0", nimfw_dbg_eapol_tx_hdr0)
        kvWrite("eap_h1", nimfw_dbg_eapol_tx_hdr1)
        kvWrite("eap_h2", nimfw_dbg_eapol_tx_hdr2)
        kvWrite("eap_h3", nimfw_dbg_eapol_tx_hdr3)
        kvWrite("eap_ahi", nimfw_dbg_eapol_tx_addr_hi)
        kvWrite("eap_pol", nimfw_dbg_eapol_tx_policy)
        kvWrite("eap_buf", nimfw_dbg_eapol_tx_buf_desc)
        kvWrite("eap_hw", nimfw_dbg_eapol_tx_hw_desc)
        kvWrite("eap_rate0", nimfw_dbg_eapol_tx_rate0)
        kvWrite("eap_rate1", nimfw_dbg_eapol_tx_rate1)
        kvWrite("eap_rate2", nimfw_dbg_eapol_tx_rate2)
        kvWrite("eap_rate3", nimfw_dbg_eapol_tx_rate3)
        kvWrite("eap_link0", nimfw_dbg_eapol_tx_link0)
        kvWrite("eap_link1", nimfw_dbg_eapol_tx_link1)
        kvWrite("dhcp_txd", nimfw_dbg_dhcp_tx_desc_bytes)
        kvWrite("dhcp_th0", nimfw_dbg_dhcp_tx_hdr0)
        kvWrite("dhcp_th1", nimfw_dbg_dhcp_tx_hdr1)
        kvWrite("dhcp_th2", nimfw_dbg_dhcp_tx_hdr2)
        kvWrite("dhcp_tsec", nimfw_dbg_dhcp_tx_sec)
        kvWrite("dhcp_sech0", nimfw_dbg_dhcp_tx_sec_hdr0)
        kvWrite("dhcp_sech1", nimfw_dbg_dhcp_tx_sec_hdr1)
        kvWrite("dhcp_seck", nimfw_dbg_dhcp_tx_sec_key)
        kvWrite("dhcp_secc", nimfw_dbg_dhcp_tx_sec_ctl)
        kvWrite("dhcp_pol", nimfw_dbg_dhcp_tx_policy)
        kvWrite("dhcp_buf", nimfw_dbg_dhcp_tx_buf_desc)
        kvWrite("dhcp_hw", nimfw_dbg_dhcp_tx_hw_desc)
        kvWrite("dhcp_rate0", nimfw_dbg_dhcp_tx_rate0)
        kvWrite("dhcp_rate1", nimfw_dbg_dhcp_tx_rate1)
        kvWrite("dhcp_rate2", nimfw_dbg_dhcp_tx_rate2)
        kvWrite("dhcp_rate3", nimfw_dbg_dhcp_tx_rate3)
        kvWrite("dhcp_rr0", nimfw_dbg_dhcp_tx_rate_raw[0])
        kvWrite("dhcp_rr1", nimfw_dbg_dhcp_tx_rate_raw[1])
        kvWrite("dhcp_rr2", nimfw_dbg_dhcp_tx_rate_raw[2])
        kvWrite("dhcp_rr3", nimfw_dbg_dhcp_tx_rate_raw[3])
        kvWrite("dhcp_rr4", nimfw_dbg_dhcp_tx_rate_raw[4])
        kvWrite("dhcp_rr5", nimfw_dbg_dhcp_tx_rate_raw[5])
        kvWrite("dhcp_rr6", nimfw_dbg_dhcp_tx_rate_raw[6])
        kvWrite("dhcp_rr7", nimfw_dbg_dhcp_tx_rate_raw[7])
        kvWrite("dhcp_rr8", nimfw_dbg_dhcp_tx_rate_raw[8])
        kvWrite("dhcp_rr9", nimfw_dbg_dhcp_tx_rate_raw[9])
        kvWrite("dhcp_rr10", nimfw_dbg_dhcp_tx_rate_raw[10])
        kvWrite("dhcp_rr11", nimfw_dbg_dhcp_tx_rate_raw[11])
        kvWrite("dhcp_rr12", nimfw_dbg_dhcp_tx_rate_raw[12])
        kvWrite("dhcp_link0", nimfw_dbg_dhcp_tx_link0)
        kvWrite("dhcp_link1", nimfw_dbg_dhcp_tx_link1)
        kvWrite("dhcp_thd0", nimfw_dbg_dhcp_tx_thd0)
        kvWrite("dhcp_thd1", nimfw_dbg_dhcp_tx_thd1)
        kvWrite("dhcp_thd2", nimfw_dbg_dhcp_tx_thd2)
        kvWrite("dhcp_ly0", nimfw_dbg_dhcp_tx_layout[0])
        kvWrite("dhcp_ly1", nimfw_dbg_dhcp_tx_layout[1])
        kvWrite("dhcp_ly2", nimfw_dbg_dhcp_tx_layout[2])
        kvWrite("dhcp_ly3", nimfw_dbg_dhcp_tx_layout[3])
        kvWrite("dhcp_ly4", nimfw_dbg_dhcp_tx_layout[4])
        kvWrite("dhcp_ly5", nimfw_dbg_dhcp_tx_layout[5])
        kvWrite("dhcp_ly6", nimfw_dbg_dhcp_tx_layout[6])
        kvWrite("dhcp_ly7", nimfw_dbg_dhcp_tx_layout[7])
        kvWrite("dhcp_fhit", nimfw_dbg_dhcp_tx_final_break_hits)
        kvWrite("dhcp_fdesc0", nimfw_dbg_dhcp_tx_final_desc0)
        kvWrite("dhcp_fdesc1", nimfw_dbg_dhcp_tx_final_desc1)
        kvWrite("dhcp_fbuf0", nimfw_dbg_dhcp_tx_final_buf0)
        kvWrite("dhcp_flen0", nimfw_dbg_dhcp_tx_final_len0)
        kvWrite("dhcp_fhw0", nimfw_dbg_dhcp_tx_final_hw_start)
        kvWrite("dhcp_fhw1", nimfw_dbg_dhcp_tx_final_hw_end)
        kvWrite("dhcp_fhw2", nimfw_dbg_dhcp_tx_final_hw_len)
        kvWrite("dhcp_fhw3", nimfw_dbg_dhcp_tx_final_hw_flags)
        kvWrite("dhcp_fhh0", nimfw_dbg_dhcp_tx_final_hthd_start)
        kvWrite("dhcp_fhh1", nimfw_dbg_dhcp_tx_final_hthd_end)
        kvWrite("dhcp_fhh2", nimfw_dbg_dhcp_tx_final_hthd_next)
        kvWrite("dhcp_fhh3", nimfw_dbg_dhcp_tx_final_hthd_flags)
        kvWrite("dhcp_fph0", nimfw_dbg_dhcp_tx_final_pthd_start)
        kvWrite("dhcp_fph1", nimfw_dbg_dhcp_tx_final_pthd_end)
        kvWrite("dhcp_fph2", nimfw_dbg_dhcp_tx_final_pthd_next)
        kvWrite("dhcp_fph3", nimfw_dbg_dhcp_tx_final_pthd_flags)
        kvWrite("rc_upd", nimfw_dbg_rc_update_calls)
        kvWrite("rc_meta", nimfw_dbg_rc_update_meta)
        kvWrite("rc_args", nimfw_dbg_rc_update_args)
        kvWrite("rc_slot", nimfw_dbg_rc_update_slot)
        kvWrite("rc_entry", nimfw_dbg_rc_update_entry)
        kvWrite("rc_counts", nimfw_dbg_rc_update_counts)
        kvWrite("rc_fail", nimfw_dbg_rc_update_fail)
        kvWrite("dhcp_mac_len", nimfw_dbg_dhcp_mac_raw_len)
        kvWrite("dhcp_mac00", loadLe32(nimfw_dbg_dhcp_mac_raw, 0))
        kvWrite("dhcp_mac04", loadLe32(nimfw_dbg_dhcp_mac_raw, 4))
        kvWrite("dhcp_mac08", loadLe32(nimfw_dbg_dhcp_mac_raw, 8))
        kvWrite("dhcp_mac12", loadLe32(nimfw_dbg_dhcp_mac_raw, 12))
        kvWrite("dhcp_mac16", loadLe32(nimfw_dbg_dhcp_mac_raw, 16))
        kvWrite("dhcp_mac20", loadLe32(nimfw_dbg_dhcp_mac_raw, 20))
        kvWrite("dhcp_mac24", loadLe32(nimfw_dbg_dhcp_mac_raw, 24))
        kvWrite("dhcp_mac28", loadLe32(nimfw_dbg_dhcp_mac_raw, 28))
        kvWrite("dhcp_mac32", loadLe32(nimfw_dbg_dhcp_mac_raw, 32))
        kvWrite("dhcp_mac36", loadLe32(nimfw_dbg_dhcp_mac_raw, 36))
        kvWrite("dhcp_mac40", loadLe32(nimfw_dbg_dhcp_mac_raw, 40))
        kvWrite("dhcp_mac44", loadLe32(nimfw_dbg_dhcp_mac_raw, 44))
        kvWrite("dhcp_mac48", loadLe32(nimfw_dbg_dhcp_mac_raw, 48))
        kvWrite("dhcp_mac52", loadLe32(nimfw_dbg_dhcp_mac_raw, 52))
        kvWrite("dhcp_mac56", loadLe32(nimfw_dbg_dhcp_mac_raw, 56))
        kvWrite("dhcp_mac60", loadLe32(nimfw_dbg_dhcp_mac_raw, 60))
        kvWrite("dhcp_mac64", loadLe32(nimfw_dbg_dhcp_mac_raw, 64))
        kvWrite("dhcp_mac68", loadLe32(nimfw_dbg_dhcp_mac_raw, 68))
        kvWrite("dhcp_mac72", loadLe32(nimfw_dbg_dhcp_mac_raw, 72))
        kvWrite("dhcp_mac76", loadLe32(nimfw_dbg_dhcp_mac_raw, 76))
        kvWrite("dhcp_mac80", loadLe32(nimfw_dbg_dhcp_mac_raw, 80))
        kvWrite("dhcp_mac84", loadLe32(nimfw_dbg_dhcp_mac_raw, 84))
        kvWrite("dhcp_mac88", loadLe32(nimfw_dbg_dhcp_mac_raw, 88))
        kvWrite("dhcp_mac92", loadLe32(nimfw_dbg_dhcp_mac_raw, 92))
        kvWrite("rxu_sched", nimfw_dbg_rxu_desc_prepare)
        kvWrite("rxu_evt", nimfw_dbg_rxu_upload_evt)
        kvWrite("rxu_entry", nimfw_dbg_rxu_upload_entry)
        kvWrite("rxu_frame", nimfw_dbg_rxu_upload_frame)
        kvWrite("rxu_tcpip", (nimfw_dbg_rxu_upload_tcpip_ok and 0xffff'u32) or
          ((nimfw_dbg_rxu_upload_tcpip_fail and 0xffff'u32) shl 16))
        kvWrite("rxu_valid", nimfw_dbg_rxu_frame_valid)
        kvWrite("rxu_data", (nimfw_dbg_rxu_assoc_data and 0xffff'u32) or
          ((nimfw_dbg_rxu_nonassoc_data and 0xffff'u32) shl 16))
        kvWrite("rxu_eapol", nimfw_dbg_rxu_assoc_eapol)
        kvWrite("rxu_upready", nimfw_dbg_rxu_assoc_upload_ready)
        kvWrite("rxu_mgmt", nimfw_dbg_rxu_assoc_mgmt)
        kvWrite("rxu_drop0", (nimfw_dbg_rxu_drop_invalid and 0xff'u32) or
          ((nimfw_dbg_rxu_drop_sta_inactive and 0xff'u32) shl 8) or
          ((nimfw_dbg_rxu_drop_ftype and 0xff'u32) shl 16) or
          ((nimfw_dbg_rxu_drop_null and 0xff'u32) shl 24))
        kvWrite("rxu_drop1", (nimfw_dbg_rxu_drop_dup and 0xffff'u32) or
          ((nimfw_dbg_rxu_drop_pn and 0xffff'u32) shl 16))
        kvWrite("rxu_prot", nimfw_dbg_rxu_prot_type)
        kvWrite("rxu_key", nimfw_dbg_rxu_prot_key)
        kvWrite("rxu_pn0", nimfw_dbg_rxu_prot_pn_lo)
        kvWrite("rxu_pn1", nimfw_dbg_rxu_prot_pn_hi)
        kvWrite("rxu_pn_meta", nimfw_dbg_rxu_pn_meta)
        kvWrite("rxu_pn_st0", nimfw_dbg_rxu_pn_stored_lo)
        kvWrite("rxu_pn_st1", nimfw_dbg_rxu_pn_stored_hi)
        kvWrite("rxu_pn_n0", nimfw_dbg_rxu_pn_next_lo)
        kvWrite("rxu_pn_n1", nimfw_dbg_rxu_pn_next_hi)
        kvWrite("rxu_data_fc", nimfw_dbg_rxu_data_fc)
        kvWrite("rxu_data_seq", nimfw_dbg_rxu_data_seq)
        kvWrite("rxu_hw", nimfw_dbg_rxu_last_hwflags)
        kvWrite("rxu_hs", nimfw_dbg_rxu_last_status)
        kvWrite("rxu_hlen", nimfw_dbg_rxu_last_len)
        kvWrite("rxu_snap0", nimfw_dbg_rxu_snap_lo)
        kvWrite("rxu_snap1", nimfw_dbg_rxu_snap_hi)
        kvWrite("rxu_l3", (nimfw_dbg_rxu_assoc_snap and 0xff'u32) or
          ((nimfw_dbg_rxu_assoc_ip and 0xff'u32) shl 8) or
          ((nimfw_dbg_rxu_assoc_arp and 0xff'u32) shl 16) or
          ((nimfw_dbg_rxu_assoc_other and 0xff'u32) shl 24))
        kvWrite("rxu_null_fc", nimfw_dbg_rxu_drop_null_fc)
        kvWrite("rxu_null_seq", nimfw_dbg_rxu_drop_null_seq)
        kvWrite("rxu_dup_fc", nimfw_dbg_rxu_drop_dup_fc)
        kvWrite("rxu_dup_seq", nimfw_dbg_rxu_drop_dup_seq)
        kvWrite("rxu_dup_n", nimfw_dbg_rxu_dup_trace_count)
        kvWrite("rxu_dup_b", nimfw_dbg_rxu_dup_break_hits)
        if nimfw_dbg_rxu_dup_trace_count != 0:
          let rxuDupIdx = int((nimfw_dbg_rxu_dup_trace_count - 1'u32) and 7'u32)
          kvWrite("rxu_dupf0", nimfw_dbg_rxu_dup_trace_fc[rxuDupIdx])
          kvWrite("rxu_dups0", nimfw_dbg_rxu_dup_trace_seq[rxuDupIdx])
          kvWrite("rxu_dupc0", nimfw_dbg_rxu_dup_trace_cache[rxuDupIdx])
          kvWrite("rxu_dupsn0", nimfw_dbg_rxu_dup_trace_snap_lo[rxuDupIdx])
          kvWrite("rxu_dupsn1", nimfw_dbg_rxu_dup_trace_snap_hi[rxuDupIdx])
          kvWrite("rxu_dupa0", nimfw_dbg_rxu_dup_trace_addr0[rxuDupIdx])
          kvWrite("rxu_dupa1", nimfw_dbg_rxu_dup_trace_addr1[rxuDupIdx])
          kvWrite("rxu_dupi0", nimfw_dbg_rxu_dup_trace_ip0[rxuDupIdx])
          kvWrite("rxu_dupu0", nimfw_dbg_rxu_dup_trace_udp0[rxuDupIdx])
          kvWrite("rxu_dupd0", nimfw_dbg_rxu_dup_trace_bootp0[rxuDupIdx])
          kvWrite("rxu_dupd1", nimfw_dbg_rxu_dup_trace_bootp1[rxuDupIdx])
          kvWrite("rxu_dupyi", nimfw_dbg_rxu_dup_trace_bootp_yiaddr[rxuDupIdx])
          kvWrite("rxu_dupmsg", nimfw_dbg_rxu_dup_trace_dhcp_msg[rxuDupIdx])
          kvWrite("rxu_dupsrv", nimfw_dbg_rxu_dup_trace_dhcp_server[rxuDupIdx])
        kvWrite("rxu_pnd_n", nimfw_dbg_rxu_pn_drop_trace_count)
        if nimfw_dbg_rxu_pn_drop_trace_count != 0:
          let rxuPnIdx = int((nimfw_dbg_rxu_pn_drop_trace_count - 1'u32) and 7'u32)
          kvWrite("rxu_pnd_fc", nimfw_dbg_rxu_pn_drop_trace_fc[rxuPnIdx])
          kvWrite("rxu_pnd_seq", nimfw_dbg_rxu_pn_drop_trace_seq[rxuPnIdx])
          kvWrite("rxu_pnd_pn0", nimfw_dbg_rxu_pn_drop_trace_pn_lo[rxuPnIdx])
          kvWrite("rxu_pnd_pn1", nimfw_dbg_rxu_pn_drop_trace_pn_hi[rxuPnIdx])
          kvWrite("rxu_pnd_st0", nimfw_dbg_rxu_pn_drop_trace_stored_lo[rxuPnIdx])
          kvWrite("rxu_pnd_st1", nimfw_dbg_rxu_pn_drop_trace_stored_hi[rxuPnIdx])
          kvWrite("rxu_pnd_sn0", nimfw_dbg_rxu_pn_drop_trace_snap_lo[rxuPnIdx])
          kvWrite("rxu_pnd_sn1", nimfw_dbg_rxu_pn_drop_trace_snap_hi[rxuPnIdx])
          kvWrite("rxu_pnd_udp", nimfw_dbg_rxu_pn_drop_trace_udp0[rxuPnIdx])
          kvWrite("rxu_pnd_yi", nimfw_dbg_rxu_pn_drop_trace_bootp_yiaddr[rxuPnIdx])
          kvWrite("rxu_pnd_msg", nimfw_dbg_rxu_pn_drop_trace_dhcp_msg[rxuPnIdx])
          kvWrite("rxu_pnd_srv", nimfw_dbg_rxu_pn_drop_trace_dhcp_server[rxuPnIdx])
        kvWrite("rxu_pna_n", nimfw_dbg_rxu_pn_accept_trace_count)
        if nimfw_dbg_rxu_pn_accept_trace_count != 0:
          let rxuPnaIdx = int((nimfw_dbg_rxu_pn_accept_trace_count - 1'u32) and 7'u32)
          kvWrite("rxu_pna_stg", nimfw_dbg_rxu_pn_accept_trace_stage[rxuPnaIdx])
          kvWrite("rxu_pna_fc", nimfw_dbg_rxu_pn_accept_trace_fc[rxuPnaIdx])
          kvWrite("rxu_pna_seq", nimfw_dbg_rxu_pn_accept_trace_seq[rxuPnaIdx])
          kvWrite("rxu_pna_pn0", nimfw_dbg_rxu_pn_accept_trace_pn_lo[rxuPnaIdx])
          kvWrite("rxu_pna_pn1", nimfw_dbg_rxu_pn_accept_trace_pn_hi[rxuPnaIdx])
          kvWrite("rxu_pna_st0", nimfw_dbg_rxu_pn_accept_trace_stored_lo[rxuPnaIdx])
          kvWrite("rxu_pna_st1", nimfw_dbg_rxu_pn_accept_trace_stored_hi[rxuPnaIdx])
          kvWrite("rxu_pna_nx0", nimfw_dbg_rxu_pn_accept_trace_next_lo[rxuPnaIdx])
          kvWrite("rxu_pna_nx1", nimfw_dbg_rxu_pn_accept_trace_next_hi[rxuPnaIdx])
          kvWrite("rxu_pna_sn0", nimfw_dbg_rxu_pn_accept_trace_snap_lo[rxuPnaIdx])
          kvWrite("rxu_pna_sn1", nimfw_dbg_rxu_pn_accept_trace_snap_hi[rxuPnaIdx])
          kvWrite("rxu_pna_udp", nimfw_dbg_rxu_pn_accept_trace_udp0[rxuPnaIdx])
          kvWrite("rxu_pna_yi", nimfw_dbg_rxu_pn_accept_trace_bootp_yiaddr[rxuPnaIdx])
          kvWrite("rxu_pna_msg", nimfw_dbg_rxu_pn_accept_trace_dhcp_msg[rxuPnaIdx])
          kvWrite("rxu_pna_srv", nimfw_dbg_rxu_pn_accept_trace_dhcp_server[rxuPnaIdx])
        kvWrite("setkey0", nimfw_dbg_setkey0)
        kvWrite("setkey1", nimfw_dbg_setkey1)
        kvWrite("setkey2", nimfw_dbg_setkey2)
        kvWrite("setkey3", nimfw_dbg_setkey3)
        kvWrite("mkey_wr", (nimfw_dbg_machwkey_wr_calls and 0xff'u32) or
          ((nimfw_dbg_machwkey_wr_group and 0xff'u32) shl 8) or
          ((nimfw_dbg_machwkey_wr_pair and 0xff'u32) shl 16))
        kvWrite("mkey_l0", nimfw_dbg_machwkey_wr_last0)
        kvWrite("mkey_l1", nimfw_dbg_machwkey_wr_last1)
        kvWrite("mkey_p0", nimfw_dbg_machwkey_wr_pair0)
        kvWrite("mkey_p1", nimfw_dbg_machwkey_wr_pair1)
        kvWrite("mkey_p2", nimfw_dbg_machwkey_wr_pair2)
        kvWrite("mkey_p3", nimfw_dbg_machwkey_wr_pair3)
        kvWrite("mkey_p4", nimfw_dbg_machwkey_wr_pair4)
        kvWrite("mkey_p5", nimfw_dbg_machwkey_wr_pair5)
        kvWrite("mkey_pc", nimfw_dbg_machwkey_wr_pair_ctrl)
        kvWrite("sta_key", nimfw_dbg_sta_add_key_calls)
        kvWrite("sta_keym", nimfw_dbg_sta_add_key_meta)
        kvWrite("sta_keyp0", nimfw_dbg_sta_add_key_ptrs0)
        kvWrite("sta_keyp1", nimfw_dbg_sta_add_key_ptrs1)
        kvWrite("sta_keyp2", nimfw_dbg_sta_add_key_ptrs2)
        kvWrite("tx_stakey0", nimfw_dbg_tx_sec_hdr_sta_key0)
        kvWrite("tx_stakey1", nimfw_dbg_tx_sec_hdr_sta_key1)
        kvWrite("tx_stakey2", nimfw_dbg_tx_sec_hdr_sta_key2)
        kvWrite("dhcp_tx", nimfw_dbg_dhcp_tx)
        kvWrite("dhcp_eth", nimfw_dbg_dhcp_tx_eth)
        kvWrite("dhcp_ports", nimfw_dbg_dhcp_tx_ports)
        kvWrite("dhcp_len", nimfw_dbg_dhcp_tx_len)
        kvWrite("dhcp_src0", nimfw_dbg_dhcp_tx_src_lo)
        kvWrite("dhcp_src1", nimfw_dbg_dhcp_tx_src_hi)
        kvWrite("dhcp_msg", nimfw_dbg_dhcp_tx_msg)
        kvWrite("dhcp_bhit", nimfw_dbg_dhcp_tx_break_hits)
        kvWrite("dhcp_rhit", nimfw_dbg_dhcp_request_tx_break_hits)
        kvWrite("dhcp_mh0", nimfw_dbg_dhcp_tx_msg_hist[0])
        kvWrite("dhcp_mh1", nimfw_dbg_dhcp_tx_msg_hist[1])
        kvWrite("dhcp_mh2", nimfw_dbg_dhcp_tx_msg_hist[2])
        kvWrite("dhcp_mh3", nimfw_dbg_dhcp_tx_msg_hist[3])
        kvWrite("dhcp_mh4", nimfw_dbg_dhcp_tx_msg_hist[4])
        kvWrite("dhcp_mh5", nimfw_dbg_dhcp_tx_msg_hist[5])
        kvWrite("dhcp_usum_n", nimfw_dbg_dhcp_udp_csum_repair)
        kvWrite("dhcp_usum_b", nimfw_dbg_dhcp_udp_csum_before)
        kvWrite("dhcp_usum_c", nimfw_dbg_dhcp_udp_csum_calc)
        kvWrite("dhcp_usum_a", nimfw_dbg_dhcp_udp_csum_after)
        kvWrite("dhcp_usum_vb", nimfw_dbg_dhcp_udp_csum_vbefore)
        kvWrite("dhcp_usum_va", nimfw_dbg_dhcp_udp_csum_vafter)
        kvWrite("dhcp_rsum_b", nimfw_dbg_dhcp_req_udp_csum_before)
        kvWrite("dhcp_rsum_c", nimfw_dbg_dhcp_req_udp_csum_calc)
        kvWrite("dhcp_rsum_a", nimfw_dbg_dhcp_req_udp_csum_after)
        kvWrite("dhcp_rsum_vb", nimfw_dbg_dhcp_req_udp_csum_vbefore)
        kvWrite("dhcp_rsum_va", nimfw_dbg_dhcp_req_udp_csum_vafter)
        kvWrite("dhcp_rsum_cp", nimfw_dbg_dhcp_req_udp_csum_at_copy)
        kvWrite("dhcp_raw_len", nimfw_dbg_dhcp_tx_raw_len)
        kvWrite("dhcp_raw00", loadLe32(nimfw_dbg_dhcp_tx_raw, 0))
        kvWrite("dhcp_raw04", loadLe32(nimfw_dbg_dhcp_tx_raw, 4))
        kvWrite("dhcp_raw08", loadLe32(nimfw_dbg_dhcp_tx_raw, 8))
        kvWrite("dhcp_raw12", loadLe32(nimfw_dbg_dhcp_tx_raw, 12))
        kvWrite("dhcp_raw16", loadLe32(nimfw_dbg_dhcp_tx_raw, 16))
        kvWrite("dhcp_raw20", loadLe32(nimfw_dbg_dhcp_tx_raw, 20))
        kvWrite("dhcp_raw24", loadLe32(nimfw_dbg_dhcp_tx_raw, 24))
        kvWrite("dhcp_raw28", loadLe32(nimfw_dbg_dhcp_tx_raw, 28))
        kvWrite("dhcp_raw32", loadLe32(nimfw_dbg_dhcp_tx_raw, 32))
        kvWrite("dhcp_raw36", loadLe32(nimfw_dbg_dhcp_tx_raw, 36))
        kvWrite("dhcp_raw40", loadLe32(nimfw_dbg_dhcp_tx_raw, 40))
        kvWrite("dhcp_raw44", loadLe32(nimfw_dbg_dhcp_tx_raw, 44))
        kvWrite("dhcp_raw48", loadLe32(nimfw_dbg_dhcp_tx_raw, 48))
        kvWrite("dhcp_raw52", loadLe32(nimfw_dbg_dhcp_tx_raw, 52))
        kvWrite("dhcp_raw56", loadLe32(nimfw_dbg_dhcp_tx_raw, 56))
        kvWrite("dhcp_raw60", loadLe32(nimfw_dbg_dhcp_tx_raw, 60))
        kvWrite("dhcp_raw64", loadLe32(nimfw_dbg_dhcp_tx_raw, 64))
        kvWrite("dhcp_raw68", loadLe32(nimfw_dbg_dhcp_tx_raw, 68))
        kvWrite("dhcp_raw72", loadLe32(nimfw_dbg_dhcp_tx_raw, 72))
        kvWrite("dhcp_raw76", loadLe32(nimfw_dbg_dhcp_tx_raw, 76))
        kvWrite("dhcp_raw80", loadLe32(nimfw_dbg_dhcp_tx_raw, 80))
        kvWrite("dhcp_raw84", loadLe32(nimfw_dbg_dhcp_tx_raw, 84))
        kvWrite("dhcp_raw88", loadLe32(nimfw_dbg_dhcp_tx_raw, 88))
        kvWrite("dhcp_raw92", loadLe32(nimfw_dbg_dhcp_tx_raw, 92))
        kvWrite("dhcp_raw96", loadLe32(nimfw_dbg_dhcp_tx_raw, 96))
        kvWrite("dhcp_raw100", loadLe32(nimfw_dbg_dhcp_tx_raw, 100))
        kvWrite("dhcp_raw104", loadLe32(nimfw_dbg_dhcp_tx_raw, 104))
        kvWrite("dhcp_raw108", loadLe32(nimfw_dbg_dhcp_tx_raw, 108))
        kvWrite("dhcp_raw112", loadLe32(nimfw_dbg_dhcp_tx_raw, 112))
        kvWrite("dhcp_raw116", loadLe32(nimfw_dbg_dhcp_tx_raw, 116))
        kvWrite("dhcp_raw120", loadLe32(nimfw_dbg_dhcp_tx_raw, 120))
        kvWrite("dhcp_raw124", loadLe32(nimfw_dbg_dhcp_tx_raw, 124))
        kvWrite("dhcp_raw128", loadLe32(nimfw_dbg_dhcp_tx_raw, 128))
        kvWrite("dhcp_raw132", loadLe32(nimfw_dbg_dhcp_tx_raw, 132))
        kvWrite("dhcp_raw136", loadLe32(nimfw_dbg_dhcp_tx_raw, 136))
        kvWrite("dhcp_raw140", loadLe32(nimfw_dbg_dhcp_tx_raw, 140))
        kvWrite("dhcp_raw144", loadLe32(nimfw_dbg_dhcp_tx_raw, 144))
        kvWrite("dhcp_raw148", loadLe32(nimfw_dbg_dhcp_tx_raw, 148))
        kvWrite("dhcp_raw152", loadLe32(nimfw_dbg_dhcp_tx_raw, 152))
        kvWrite("dhcp_raw156", loadLe32(nimfw_dbg_dhcp_tx_raw, 156))
        kvWrite("dhcp_raw160", loadLe32(nimfw_dbg_dhcp_tx_raw, 160))
        kvWrite("dhcp_raw164", loadLe32(nimfw_dbg_dhcp_tx_raw, 164))
        kvWrite("dhcp_raw168", loadLe32(nimfw_dbg_dhcp_tx_raw, 168))
        kvWrite("dhcp_raw172", loadLe32(nimfw_dbg_dhcp_tx_raw, 172))
        kvWrite("dhcp_raw176", loadLe32(nimfw_dbg_dhcp_tx_raw, 176))
        kvWrite("dhcp_raw180", loadLe32(nimfw_dbg_dhcp_tx_raw, 180))
        kvWrite("dhcp_raw184", loadLe32(nimfw_dbg_dhcp_tx_raw, 184))
        kvWrite("dhcp_raw188", loadLe32(nimfw_dbg_dhcp_tx_raw, 188))
        kvWrite("dhcp_raw192", loadLe32(nimfw_dbg_dhcp_tx_raw, 192))
        kvWrite("dhcp_raw196", loadLe32(nimfw_dbg_dhcp_tx_raw, 196))
        kvWrite("dhcp_raw200", loadLe32(nimfw_dbg_dhcp_tx_raw, 200))
        kvWrite("dhcp_raw204", loadLe32(nimfw_dbg_dhcp_tx_raw, 204))
        kvWrite("dhcp_raw208", loadLe32(nimfw_dbg_dhcp_tx_raw, 208))
        kvWrite("dhcp_raw212", loadLe32(nimfw_dbg_dhcp_tx_raw, 212))
        kvWrite("dhcp_raw216", loadLe32(nimfw_dbg_dhcp_tx_raw, 216))
        kvWrite("dhcp_raw220", loadLe32(nimfw_dbg_dhcp_tx_raw, 220))
        kvWrite("dhcp_raw224", loadLe32(nimfw_dbg_dhcp_tx_raw, 224))
        kvWrite("dhcp_raw228", loadLe32(nimfw_dbg_dhcp_tx_raw, 228))
        kvWrite("dhcp_raw232", loadLe32(nimfw_dbg_dhcp_tx_raw, 232))
        kvWrite("dhcp_raw236", loadLe32(nimfw_dbg_dhcp_tx_raw, 236))
        kvWrite("dhcp_raw240", loadLe32(nimfw_dbg_dhcp_tx_raw, 240))
        kvWrite("dhcp_raw244", loadLe32(nimfw_dbg_dhcp_tx_raw, 244))
        kvWrite("dhcp_raw248", loadLe32(nimfw_dbg_dhcp_tx_raw, 248))
        kvWrite("dhcp_raw252", loadLe32(nimfw_dbg_dhcp_tx_raw, 252))
        kvWrite("dhcp_opt276", loadLe32(nimfw_dbg_dhcp_tx_raw, 276))
        kvWrite("dhcp_opt280", loadLe32(nimfw_dbg_dhcp_tx_raw, 280))
        kvWrite("dhcp_opt284", loadLe32(nimfw_dbg_dhcp_tx_raw, 284))
        kvWrite("dhcp_opt288", loadLe32(nimfw_dbg_dhcp_tx_raw, 288))
        kvWrite("dhcp_opt292", loadLe32(nimfw_dbg_dhcp_tx_raw, 292))
        kvWrite("dhcp_opt296", loadLe32(nimfw_dbg_dhcp_tx_raw, 296))
        kvWrite("dhcp_opt300", loadLe32(nimfw_dbg_dhcp_tx_raw, 300))
        kvWrite("dhcp_opt304", loadLe32(nimfw_dbg_dhcp_tx_raw, 304))
        kvWrite("dhcp_opt308", loadLe32(nimfw_dbg_dhcp_tx_raw, 308))
        kvWrite("dhcp_opt312", loadLe32(nimfw_dbg_dhcp_tx_raw, 312))
        kvWrite("dhcp_opt316", loadLe32(nimfw_dbg_dhcp_tx_raw, 316))
        kvWrite("dhcp_opt320", loadLe32(nimfw_dbg_dhcp_tx_raw, 320))
        kvWrite("dhcp_opt324", loadLe32(nimfw_dbg_dhcp_tx_raw, 324))
        kvWrite("dhcp_opt328", loadLe32(nimfw_dbg_dhcp_tx_raw, 328))
        kvWrite("dhcp_opt332", loadLe32(nimfw_dbg_dhcp_tx_raw, 332))
        kvWrite("dhcp_opt336", loadLe32(nimfw_dbg_dhcp_tx_raw, 336))
        kvWrite("dhcp_opt340", loadLe32(nimfw_dbg_dhcp_tx_raw, 340))
        kvWrite("dhcp_opt344", loadLe32(nimfw_dbg_dhcp_tx_raw, 344))
        kvWrite("dhcp_opt348", loadLe32(nimfw_dbg_dhcp_tx_raw, 348))
        kvWrite("dhcp_cfm", (nimfw_dbg_dhcp_cfm and 0xff'u32) or
          ((nimfw_dbg_dhcp_cfm_ok and 0xff'u32) shl 8) or
          ((nimfw_dbg_dhcp_cfm_fail and 0xff'u32) shl 16))
        kvWrite("dhcp_ack", (nimfw_dbg_dhcp_cfm_ack_ok and 0xffff'u32) or
          ((nimfw_dbg_dhcp_cfm_ack_fail and 0xffff'u32) shl 16))
        kvWrite("dhcp_cfs", nimfw_dbg_dhcp_cfm_status)
        kvWrite("dhcp_cfb", txCfmBits(nimfw_dbg_dhcp_cfm_status))
        kvWrite("dhcp_cri", nimfw_dbg_dhcp_cfm_ring_idx)
        kvWrite("dhcp_cs0", nimfw_dbg_dhcp_cfm_status_log[0])
        kvWrite("dhcp_cs1", nimfw_dbg_dhcp_cfm_status_log[1])
        kvWrite("dhcp_cs2", nimfw_dbg_dhcp_cfm_status_log[2])
        kvWrite("dhcp_cs3", nimfw_dbg_dhcp_cfm_status_log[3])
        kvWrite("dhcp_cs4", nimfw_dbg_dhcp_cfm_status_log[4])
        kvWrite("dhcp_cs5", nimfw_dbg_dhcp_cfm_status_log[5])
        kvWrite("dhcp_cs6", nimfw_dbg_dhcp_cfm_status_log[6])
        kvWrite("dhcp_cs7", nimfw_dbg_dhcp_cfm_status_log[7])
        kvWrite("dhcp_cm0", nimfw_dbg_dhcp_cfm_meta_log[0])
        kvWrite("dhcp_cm1", nimfw_dbg_dhcp_cfm_meta_log[1])
        kvWrite("dhcp_cm2", nimfw_dbg_dhcp_cfm_meta_log[2])
        kvWrite("dhcp_cm3", nimfw_dbg_dhcp_cfm_meta_log[3])
        kvWrite("dhcp_cm4", nimfw_dbg_dhcp_cfm_meta_log[4])
        kvWrite("dhcp_cm5", nimfw_dbg_dhcp_cfm_meta_log[5])
        kvWrite("dhcp_cm6", nimfw_dbg_dhcp_cfm_meta_log[6])
        kvWrite("dhcp_cm7", nimfw_dbg_dhcp_cfm_meta_log[7])
        kvWrite("ipc_irq", nimfw_dbg_ipc_host_irq)
        kvWrite("ipc_st", nimfw_dbg_ipc_host_irq_status)
        kvWrite("ipc_txc", (nimfw_dbg_ipc_host_txcfm_irq and 0xff'u32) or
          ((nimfw_dbg_ipc_host_txcfm_handler and 0xff'u32) shl 8) or
          ((nimfw_dbg_ipc_host_txcfm_drained and 0xffff'u32) shl 16))
        kvWrite("ipc_host", nimfw_dbg_ipc_host_txcfm_host)
        kvWrite("ipc_txd", (nimfw_dbg_ipc_host_txdesc_push and 0xffff'u32) or
          ((nimfw_dbg_ipc_host_txdesc_nil and 0xffff'u32) shl 16))
      return false
  let ip4 = netifIp4(netif)
  let gw4 = netifGw4(netif)
  phaseMark(Phase.dhcp, Kind.ok):
    kvWrite("ip", ip4)
    kvWrite("gw", gw4)

  # Run both probes. Some local gateways do not answer ICMP echo, while some AP
  # paths block public echo; either success proves ARP/TX/encrypted RX,
  # tcpip_stack_input, and the lwIP raw callback.
  var gatewayIcmpOk = false
  for _ in 0 ..< GatewayIcmpAttempts:
    if runIcmpEcho(gw4, false):
      gatewayIcmpOk = true
      break
  let targetIcmpOk = runIcmpEcho(IcmpTargetAddress, false)
  return gatewayIcmpOk or targetIcmpOk

proc deinitForRetry() {.nimcall.} =
  discard wifiDisconnect()

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  setupConsole()
  when defined(bl808WifiNimFw):
    hwValidationLogReset()
  e2eMarkerInit(addr console)
  discard console.sendLine("")
  discard console.sendLine("=== BL808 WiFi LwIP Smoke Test ===")
  lwipInit()
  e2eRun(AttemptsTotal, runOneAttempt, deinitForRetry, stopAfterSuccess = true)
  discard console.sendLine("=== BL808 LwIP Smoke Complete ===")

main()
