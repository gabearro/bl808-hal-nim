## Live all-core WASM+CPS concurrency smoke.

import bl808/startup
import bl808/core, bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart
import bl808/memmap
import bl808/flash
import bl808/kernel/alloc
import bl808/kernel/cps
import bl808/kernel/fault
import bl808/enclave/abi, bl808/enclave/enclave, bl808/enclave/partition
import bl808/enclave/services, bl808/enclave/vault
import bl808/pds
import bl808/tzc
import bl808/wasm_cps
import bl808/wasm_control
import bl808/wasm_live_smoke
import bl808/wasm_slot_smoke
import bl808/wasm_store
import bl808/wasm_task_smoke

when defined(bl808AllcoreWasmHttp):
  import bl808/wifi
  import bl808/kernel/clock
  import bl808/kernel/lwipcore
  import bl808/psram
  import bl808/wasm_cps_http
  import bl808/wasm_http
  import bl808/wasm_os
  import bl808/wasm_peer_control
  import cps/http/server/embedded
  import cps/http/server/embedded_router

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  WaitLoops = 200_000
  WifiSsid {.strdefine.} = "Frog"
  WifiPassword {.strdefine.} = "6509171272"
  WifiChannel {.intdefine.} = 0
  WifiFallbackSsid {.strdefine.} = ""
  WifiFallbackChannel {.intdefine.} = 0
  WifiFallbackAfterAttempts {.intdefine.} = 2
  WpaCompletedState = 10'u32
  StaticIpA {.intdefine.} = 0
  StaticIpB {.intdefine.} = 0
  StaticIpC {.intdefine.} = 0
  StaticIpD {.intdefine.} = 0
  StaticNetmaskA {.intdefine.} = 255
  StaticNetmaskB {.intdefine.} = 255
  StaticNetmaskC {.intdefine.} = 255
  StaticNetmaskD {.intdefine.} = 0
  StaticGatewayA {.intdefine.} = 0
  StaticGatewayB {.intdefine.} = 0
  StaticGatewayC {.intdefine.} = 0
  StaticGatewayD {.intdefine.} = 0
  StaticIpAfterDhcpAttempts {.intdefine.} = 3
  HttpPort {.intdefine.} = 80
  AllcoreHttpHoldPeerCoresBeforeWifi {.intdefine.} = 0
  AllcoreHttpWifiResetSettleUs {.intdefine.} = 250_000'u64
  AllcoreHttpWifiPostLwipSettleUs {.intdefine.} = 1_000_000'u64
  WifiConnectRetryDelayUs = 10_000_000'u64
  HttpListenRetryDelayUs = 1_000_000'u64
  DhcpTimeoutMs = 30_000'u32
  HttpRequestBufferLen = 2048
  MachwStatusReg = 0x24B0004C'u
  MachwRxControlReg = 0x24B00060'u
  LpWramBootGateAddr = WramBase + 0x21000'u
  LpWramBootGate = [
    0x220502B7'u32, 0x40003337'u32, 0xC0830313'u32, 0x1A0003B7'u32,
    0x0E038393'u32, 0x00732023'u32, 0x0FF0000F'u32, 0x0002A503'u32,
    0x574C55B7'u32, 0x35458593'u32, 0x02B50063'u32, 0x40003637'u32,
    0xC0460613'u32, 0x00062683'u32, 0x00168693'u32, 0x00D62023'u32,
    0x0FF0000F'u32, 0xFD9FF06F'u32, 0x1A0003B7'u32, 0x0E138393'u32,
    0x00732023'u32, 0x0FF0000F'u32, 0x58080537'u32, 0x00052583'u32,
    0x40003637'u32, 0xC0C60613'u32, 0x00B62023'u32, 0x0FF0000F'u32,
    0x0000100F'u32, 0x00050067'u32,
  ]

var
  console: Uart
  heartbeat = 0'u32
  passed = 0
  failed = 0
  scratch {.align: 16.}: array[256, uint8]

when defined(bl808AllcoreWasmHttp):
  type
    HttpClientState = object
      pcb: ptr TcpPcb
      pending: uint32
      keepOpen: bool
      closeRequested: bool
      upgraded: bool
      wsPath: string
      wsRxBuffer: string

  const
    HttpClientPoolLen = 4

  {.emit: """/*TYPESECTION*/
extern char __wifi_rx_ram_start[], __wifi_rx_ram_end[];
extern char __psram_bss_start[], __psram_bss_end[];
static unsigned long __wifi_rx_ram_start_addr(void){return (unsigned long)__wifi_rx_ram_start;}
static unsigned long __wifi_rx_ram_end_addr(void){return (unsigned long)__wifi_rx_ram_end;}
static unsigned long __psram_bss_start_addr(void){return (unsigned long)__psram_bss_start;}
static unsigned long __psram_bss_end_addr(void){return (unsigned long)__psram_bss_end;}
""".}
  {.pragma: httpPsramBss, codegenDecl: "$# $# __attribute__((section(\".psrambss\"), aligned(16), used))".}

  var
    httpListenPcb: ptr TcpPcb
    httpClients: array[HttpClientPoolLen, HttpClientState]
    httpRequestBuffer {.httpPsramBss.}: array[HttpRequestBufferLen, byte]
    httpBodyScratch = ""
    httpResponseScratch = ""
    httpRequests = 0'u32
    httpWasmRequests = 0'u32
    httpWriteFailures = 0'u32
    httpCloseFailures = 0'u32
    httpIp = 0'u32
    httpM0WasmStatus = 0'u32
    httpM0WasmAddValue = 0'i32
    httpM0WasmSumValue = 0'i32
    httpEnclaveWasmStatus = 0'u32
    httpEnclaveWasmAddValue = 0'i32
    httpEnclaveHeartbeat = 0'u32

  var
    nimfw_dbg_tcpip_input_calls {.importc.}: uint32
    nimfw_dbg_tcpip_input_ok {.importc.}: uint32
    nimfw_dbg_tcpip_input_fail {.importc.}: uint32
    nimfw_dbg_tcpip_input_arp {.importc.}: uint32
    nimfw_dbg_tcpip_input_tcp {.importc.}: uint32
    nimfw_dbg_tcpip_input_tcp80 {.importc.}: uint32
    nimfw_dbg_tcpip_input_last_ports {.importc.}: uint32
    nimfw_dbg_tcpip_input_last_ip {.importc.}: uint32
    httpEnclaveWasmSumValue = 0'i32
    nimfw_dbg_mac_irq_last_int_raw {.importc.}: uint32
    nimfw_dbg_mac_irq_last_gen_raw {.importc.}: uint32
    nimfw_dbg_mac_irq_last_rxctrl {.importc.}: uint32
    nimfw_dbg_mac_irq_last_hd {.importc.}: uint32
    nimfw_dbg_mac_irq_last_pd {.importc.}: uint32
    nimfw_dbg_rxl_snap_hd {.importc.}: uint32
    nimfw_dbg_rxl_snap_pd {.importc.}: uint32
    nimfw_dbg_rxl_snap_hw_hd {.importc.}: uint32
    nimfw_dbg_rxl_snap_hw_pd {.importc.}: uint32
    nimfw_dbg_rxl_snap_irq_raw {.importc.}: uint32
    nimfw_dbg_rxl_snap_gen_raw {.importc.}: uint32
    nimfw_dbg_rxl_snap_rxctrl_raw {.importc.}: uint32
    nimfw_dbg_rxl_snap_status_raw {.importc.}: uint32
    nimfw_dbg_rxl_snap_hd_status {.importc.}: uint32
    nimfw_dbg_rxl_snap_pd_status {.importc.}: uint32

    nimfw_dbg_scan_start_rxctrl {.importc.}: uint32
    nimfw_dbg_scan_start_irq_raw {.importc.}: uint32
    nimfw_dbg_scan_start_gen_raw {.importc.}: uint32
    nimfw_dbg_scan_end_rxctrl {.importc.}: uint32
    nimfw_dbg_scan_end_irq_raw {.importc.}: uint32
    nimfw_dbg_scan_end_gen_raw {.importc.}: uint32
    nimfw_dbg_scan_req_chan_meta {.importc.}: uint32
    nimfw_dbg_scan_req_chan_freq {.importc.}: uint32
    nimfw_dbg_scan_cache_find {.importc.}: uint32
    nimfw_dbg_scan_cache_hit {.importc.}: uint32
    nimfw_dbg_scan_cache_candidates {.importc.}: uint32
    nimfw_dbg_scan_cache_selected_slot {.importc.}: uint32
    nimfw_dbg_scan_cache_selected_meta {.importc.}: uint32
    nimfw_dbg_scan_cache_selected_bssid_lo {.importc.}: uint32
    nimfw_dbg_scan_cache_selected_bssid_hi {.importc.}: uint32
    nimfw_dbg_mac_hw_lo {.importc.}: uint32
    nimfw_dbg_mac_hw_hi {.importc.}: uint32
    nimfw_dbg_bssid_hw_lo {.importc.}: uint32
    nimfw_dbg_bssid_hw_hi {.importc.}: uint32
    nimfw_dbg_scan_cache_failure_marks {.importc.}: uint32
    nimfw_dbg_scan_cache_failure_count {.importc.}: uint32
    nimfw_dbg_scan_key_mgmt {.importc.}: uint32
    nimfw_dbg_scan_at {.importc.}: uint32
    nimfw_dbg_scan_smf {.importc.}: uint32
    nimfw_dbg_scan_caps {.importc.}: uint32
    nimfw_dbg_sm_chan_ctx_req0 {.importc.}: uint32
    nimfw_dbg_sm_chan_ctx_req1 {.importc.}: uint32
    nimfw_dbg_sm_chan_ctx_ptrs {.importc.}: uint32
    nimfw_dbg_sm_chan_ctx_result {.importc.}: uint32
    nimfw_dbg_chan_scan_chan_meta {.importc.}: uint32
    nimfw_dbg_chan_scan_chan_freq {.importc.}: uint32
    nimfw_dbg_chan_pre_chan_meta {.importc.}: uint32
    nimfw_dbg_chan_pre_chan_freq {.importc.}: uint32
    nimfw_dbg_dhcp_tx {.importc.}: uint32
    nimfw_dbg_dhcp_tx_msg {.importc.}: uint32
    nimfw_dbg_dhcp_cfm_ok {.importc.}: uint32
    nimfw_dbg_dhcp_cfm_fail {.importc.}: uint32
    nimfw_dbg_tx_sec_hdr_calls {.importc.}: uint32
    nimfw_dbg_tx_sec_hdr_no_keymat {.importc.}: uint32
    nimfw_dbg_tx_sec_hdr_no_keyslot {.importc.}: uint32
    nimfw_dbg_tx_sec_hdr_cipher {.importc.}: uint32
    nimfw_dbg_tx_sec_hdr_len {.importc.}: uint32
    nimfw_dbg_tx_sec_hdr_append {.importc.}: uint32
    nimfw_dbg_tx_sec_hdr_miss_meta {.importc.}: uint32
    nimfw_dbg_tx_sec_hdr_miss_len {.importc.}: uint32
    nimfw_dbg_tx_sec_hdr_miss_keymat {.importc.}: uint32
    nimfw_dbg_tx_sec_hdr_sta_key0 {.importc.}: uint32
    nimfw_dbg_tx_sec_hdr_sta_key1 {.importc.}: uint32
    nimfw_dbg_tx_sec_hdr_sta_key2 {.importc.}: uint32
    nimfw_dbg_dhcp_tx_sec {.importc.}: uint32
    nimfw_dbg_dhcp_tx_sec_hdr0 {.importc.}: uint32
    nimfw_dbg_dhcp_tx_sec_hdr1 {.importc.}: uint32
    nimfw_dbg_dhcp_tx_sec_key {.importc.}: uint32
    nimfw_dbg_dhcp_tx_sec_ctl {.importc.}: uint32
    nimfw_dbg_tcpip_input_dhcp_rx {.importc.}: uint32
    nimfw_dbg_lwip_dhcp_recv_count {.importc.}: uint32
    nimfw_dbg_lwip_dhcp_offer_count {.importc.}: uint32
    sm_state {.importc.}: uint16
    nimfw_dbg_assert_err_count {.importc.}: uint32
    nimfw_dbg_assert_err_last_line {.importc.}: uint32
    nimfw_dbg_hw_wait_timeout_count {.importc.}: uint32
    nimfw_dbg_hw_wait_last_reg {.importc.}: uint32
    nimfw_dbg_bss_in {.importc.}: uint32
    nimfw_dbg_bss_ssid_result {.importc.}: uint32
    nimfw_dbg_bss_directed {.importc.}: uint32
    nimfw_dbg_bss_out {.importc.}: uint32
    nimfw_dbg_bss_chan_fix_meta {.importc.}: uint32
    nimfw_dbg_bss_selected_freq {.importc.}: uint32
    nimfw_dbg_ssid_search {.importc.}: uint32
    nimfw_dbg_ssid_entries {.importc.}: uint32
    nimfw_dbg_ssid_hits {.importc.}: uint32
    nimfw_dbg_auth_tx_len {.importc.}: uint32
    nimfw_dbg_auth_tx_meta {.importc.}: uint32
    nimfw_dbg_auth_tx_desc {.importc.}: uint32
    nimfw_dbg_auth_tx_raw {.importc.}: array[96, uint8]
    nimfw_dbg_auth_rxctrl {.importc.}: uint32
    nimfw_dbg_txtrig_entry {.importc.}: uint32
    nimfw_dbg_txtrig_acready {.importc.}: uint32
    nimfw_dbg_txtrig_zero {.importc.}: uint32
    nimfw_dbg_txtrig_loops {.importc.}: uint32
    nimfw_dbg_txtrig_yield {.importc.}: uint32
    nimfw_dbg_txtrig_yield_ac {.importc.}: uint32
    nimfw_dbg_txtrig_yield_head {.importc.}: uint32
    nimfw_dbg_txtrig_desc {.importc.}: uint32
    nimfw_dbg_txtrig_status {.importc.}: uint32
    nimfw_dbg_txtrig_notready {.importc.}: uint32
    nimfw_dbg_txtrig_nodesc {.importc.}: uint32
    nimfw_dbg_txint_enter {.importc.}: uint32
    nimfw_dbg_txint_last_cb {.importc.}: uint32
    nimfw_dbg_txint_last_fc {.importc.}: uint32
    nimfw_dbg_txint_ready {.importc.}: uint32
    nimfw_dbg_txint_psok {.importc.}: uint32
    nimfw_dbg_txint_push {.importc.}: uint32
    nimfw_dbg_txint_release {.importc.}: uint32
    nimfw_dbg_txint_postpone {.importc.}: uint32
    nimfw_dbg_txint_meta {.importc.}: uint32
    nimfw_dbg_txint_chan {.importc.}: uint32
    nimfw_dbg_txint_queue {.importc.}: uint32
    nimfw_dbg_txint_hw {.importc.}: uint32
    nimfw_dbg_pay_backup {.importc.}: uint32
    nimfw_dbg_pay_desc {.importc.}: uint32
    nimfw_dbg_pay_payload {.importc.}: uint32
    nimfw_dbg_pay_empty {.importc.}: uint32
    nimfw_dbg_pay_nonempty {.importc.}: uint32
    nimfw_dbg_pay_trig {.importc.}: uint32
    nimfw_dbg_pay_tx_status {.importc.}: uint32
    nimfw_dbg_pay_tx_agg {.importc.}: uint32
    nimfw_dbg_pay_tx_dma {.importc.}: uint32
    nimfw_dbg_pay_tx_current {.importc.}: uint32
    nimfw_dbg_pay_tx_thd {.importc.}: uint32
    nimfw_dbg_pay_tx_head {.importc.}: uint32
    nimfw_dbg_probe_pay_meta {.importc.}: uint32
    nimfw_dbg_probe_pay_desc {.importc.}: uint32
    nimfw_dbg_probe_pay_link {.importc.}: uint32
    nimfw_dbg_probe_pay_hw {.importc.}: uint32
    nimfw_dbg_probe_pay_thd {.importc.}: uint32
    nimfw_dbg_probe_pay_len {.importc.}: uint32
    nimfw_dbg_probe_pay_hw0 {.importc.}: uint32
    nimfw_dbg_probe_pay_hw1 {.importc.}: uint32
    nimfw_dbg_probe_pay_hw2 {.importc.}: uint32
    nimfw_dbg_probe_pay_hw3 {.importc.}: uint32
    nimfw_dbg_probe_pay_link0 {.importc.}: uint32
    nimfw_dbg_probe_pay_link1 {.importc.}: uint32
    nimfw_dbg_probe_pay_hw_start {.importc.}: uint32
    nimfw_dbg_probe_pay_hw_end {.importc.}: uint32
    nimfw_dbg_probe_pay_hw_frame_len {.importc.}: uint32
    nimfw_dbg_probe_pay_hw_status {.importc.}: uint32
    nimfw_dbg_probe_pay_hw_ctrl {.importc.}: uint32
    nimfw_dbg_probe_pay_hw_chain {.importc.}: uint32
    nimfw_dbg_probe_pay_hw_retry_limit_control {.importc.}: uint32
    nimfw_dbg_probe_pay_hw_ack_policy_control {.importc.}: uint32
    nimfw_dbg_auth_pay_meta {.importc.}: uint32
    nimfw_dbg_auth_pay_len {.importc.}: uint32
    nimfw_dbg_auth_pay_hw0 {.importc.}: uint32
    nimfw_dbg_auth_pay_hw1 {.importc.}: uint32
    nimfw_dbg_auth_pay_hw2 {.importc.}: uint32
    nimfw_dbg_auth_pay_hw3 {.importc.}: uint32
    nimfw_dbg_assoc_pay_meta {.importc.}: uint32
    nimfw_dbg_assoc_pay_len {.importc.}: uint32
    nimfw_dbg_assoc_pay_hw0 {.importc.}: uint32
    nimfw_dbg_assoc_pay_hw1 {.importc.}: uint32
    nimfw_dbg_assoc_pay_hw2 {.importc.}: uint32
    nimfw_dbg_assoc_pay_hw3 {.importc.}: uint32
    nimfw_dbg_sta_tx_channel_source {.importc.}: uint32
    nimfw_dbg_sta_tx_channel_req0 {.importc.}: uint32
    nimfw_dbg_sta_tx_channel_req1 {.importc.}: uint32
    nimfw_dbg_sta_tx_channel_vif {.importc.}: uint32
    nimfw_dbg_auth_hw_pre_push {.importc.}: array[32, uint32]
    nimfw_dbg_auth_rf_pre_push {.importc.}: array[8, uint32]
    nimfw_dbg_auth_cfm_status {.importc.}: uint32
    nimfw_dbg_auth_cfm_hw_status {.importc.}: uint32
    nimfw_dbg_auth_cfm_thd_flags {.importc.}: uint32
    nimfw_dbg_auth_cfm_ack_ok16 {.importc.}: uint32
    nimfw_dbg_auth_cfm_ack_ok23 {.importc.}: uint32
    nimfw_dbg_auth_cfm_ack_fail {.importc.}: uint32
    nimfw_dbg_auth_cfm_meta {.importc.}: uint32
    nimfw_dbg_auth_cfm_desc {.importc.}: uint32
    nimfw_dbg_auth_cfm_fc {.importc.}: uint32
    nimfw_dbg_auth_cfm_push {.importc.}: uint32
    nimfw_dbg_auth_mgt_seen {.importc.}: uint32
    nimfw_dbg_auth_mgt_accept {.importc.}: uint32
    nimfw_dbg_auth_mgt_reject {.importc.}: uint32
    nimfw_dbg_auth_mgt_msg {.importc.}: uint32
    nimfw_dbg_auth_mgt_last0 {.importc.}: uint32
    nimfw_dbg_auth_mgt_last1 {.importc.}: uint32
    nimfw_dbg_mgt_seen {.importc.}: uint32
    nimfw_dbg_mgt_accept {.importc.}: uint32
    nimfw_dbg_mgt_reject {.importc.}: uint32
    nimfw_dbg_mgt_msg {.importc.}: uint32
    nimfw_dbg_mgt_last_fc {.importc.}: uint32
    nimfw_dbg_mgt_last0 {.importc.}: uint32
    nimfw_dbg_mgt_last1 {.importc.}: uint32
    nimfw_dbg_mgt_drop_reason {.importc.}: uint32
    nimfw_dbg_mgt_subtype_counts {.importc.}: array[16, uint32]
    nimfw_dbg_mgt_auth_last_fc {.importc.}: uint32
    nimfw_dbg_mgt_assoc_last_fc {.importc.}: uint32
    nimfw_dbg_mgt_assoc_rsp_seen {.importc.}: uint32
    nimfw_dbg_tx_seq_last {.importc.}: uint32
    nimfw_dbg_tx_seq_counter {.importc.}: uint32
    nimfw_dbg_rxl_frame_seen {.importc.}: uint32
    nimfw_dbg_rxl_last_hwflags {.importc.}: uint32
    nimfw_dbg_rxl_last_fc {.importc.}: uint32
    nimfw_dbg_rxl_mgmt_seen {.importc.}: uint32
    nimfw_dbg_rxl_mgmt_last {.importc.}: uint32
    nimfw_dbg_rxl_auth_like_seen {.importc.}: uint32
    nimfw_dbg_rxl_auth_like_hwflags {.importc.}: uint32
    nimfw_dbg_rxl_auth_like_fc {.importc.}: uint32
    nimfw_dbg_rxu_auth_seen {.importc.}: uint32
    nimfw_dbg_rxu_auth_last0 {.importc.}: uint32
    nimfw_dbg_rxu_auth_last1 {.importc.}: uint32
    nimfw_dbg_rxu_drop_sta_inactive {.importc.}: uint32
    nimfw_dbg_rxu_assoc_mgmt {.importc.}: uint32
    nimfw_dbg_rxu_frame_valid {.importc.}: uint32
    nimfw_dbg_rxu_drop_invalid {.importc.}: uint32
    nimfw_dbg_rxu_upload_evt {.importc.}: uint32
    nimfw_dbg_rxu_upload_entry {.importc.}: uint32
    nimfw_dbg_rxu_upload_tcpip_ok {.importc.}: uint32
    nimfw_dbg_rxu_upload_tcpip_fail {.importc.}: uint32
    nimfw_dbg_rxu_assoc_data {.importc.}: uint32
    nimfw_dbg_rxu_assoc_upload_ready {.importc.}: uint32
    nimfw_dbg_rxu_assoc_ip {.importc.}: uint32
    nimfw_dbg_rxu_assoc_arp {.importc.}: uint32
    nimfw_dbg_rxu_assoc_tcp {.importc.}: uint32
    nimfw_dbg_rxu_assoc_tcp80 {.importc.}: uint32
    nimfw_dbg_rxu_assoc_last_ip_proto {.importc.}: uint32
    nimfw_dbg_rxu_assoc_last_tcp_ports {.importc.}: uint32
    nimfw_dbg_rxu_assoc_last_tcp_flags {.importc.}: uint32
    nimfw_dbg_rxu_drop_ftype {.importc.}: uint32
    nimfw_dbg_rxu_drop_null {.importc.}: uint32
    nimfw_dbg_rxu_drop_dup {.importc.}: uint32
    nimfw_dbg_rxu_drop_pn {.importc.}: uint32
    nimfw_dbg_rxu_prot_type {.importc.}: uint32
    nimfw_dbg_rxu_prot_key {.importc.}: uint32
    nimfw_dbg_rxu_prot_slot_meta {.importc.}: uint32
    nimfw_dbg_rxu_prot_slot_key0 {.importc.}: uint32
    nimfw_dbg_rxu_prot_slot_key1 {.importc.}: uint32
    nimfw_dbg_rxu_prot_slot_key2 {.importc.}: uint32
    nimfw_dbg_rxu_prot_slot_key3 {.importc.}: uint32
    nimfw_dbg_rxu_sw_ccmp_attempt {.importc.}: uint32
    nimfw_dbg_rxu_sw_ccmp_ok {.importc.}: uint32
    nimfw_dbg_rxu_sw_ccmp_fail {.importc.}: uint32
    nimfw_dbg_rxu_sw_ccmp_len {.importc.}: uint32
    nimfw_dbg_rxu_prot_pn_lo {.importc.}: uint32
    nimfw_dbg_rxu_prot_pn_hi {.importc.}: uint32
    nimfw_dbg_rxu_pn_meta {.importc.}: uint32
    nimfw_dbg_rxu_pn_stored_lo {.importc.}: uint32
    nimfw_dbg_rxu_pn_stored_hi {.importc.}: uint32
    nimfw_dbg_rxu_pn_next_lo {.importc.}: uint32
    nimfw_dbg_rxu_pn_next_hi {.importc.}: uint32
    nimfw_dbg_rxu_snap_lo {.importc.}: uint32
    nimfw_dbg_rxu_snap_hi {.importc.}: uint32
    nimfw_dbg_tcpip_input_no_forward {.importc.}: uint32
    nimfw_dbg_tcpip_input_no_vif {.importc.}: uint32
    nimfw_dbg_tcpip_input_no_netif {.importc.}: uint32
    nimfw_dbg_tcpip_input_no_pbuf {.importc.}: uint32
    nimfw_dbg_tcpip_input_no_pbuf_stage {.importc.}: uint32
    nimfw_dbg_tcpip_input_no_pbuf_status {.importc.}: uint32
    nimfw_dbg_tcpip_input_no_pbuf_flags {.importc.}: uint32
    nimfw_dbg_tcpip_input_no_pbuf_meta {.importc.}: uint32
    nimfw_dbg_tcpip_input_no_pbuf_pkt {.importc.}: uint32
    nimfw_dbg_tcpip_input_mpdu_conv {.importc.}: uint32
    nimfw_dbg_tcpip_input_mpdu_fail {.importc.}: uint32
    nimfw_dbg_tcpip_input_mpdu_fail_counts {.importc.}: uint32
    nimfw_dbg_tcpip_input_mpdu_fail_detail_lo {.importc.}: uint32
    nimfw_dbg_tcpip_input_mpdu_fail_detail_hi {.importc.}: uint32
    nimfw_dbg_tcpip_input_mpdu_last0 {.importc.}: uint32
    nimfw_dbg_tcpip_input_mpdu_last1 {.importc.}: uint32
    nimfw_dbg_tcpip_input_mpdu_last2 {.importc.}: uint32
    nimfw_dbg_tcpip_input_frame_last0 {.importc.}: uint32
    nimfw_dbg_tcpip_input_frame_last1 {.importc.}: uint32
    nimfw_dbg_tcpip_input_frame_src0 {.importc.}: uint32
    nimfw_dbg_tcpip_input_frame_src1 {.importc.}: uint32
    nimfw_dbg_tcpip_input_frame_src2 {.importc.}: uint32
    nimfw_dbg_tcpip_input_frame_src3 {.importc.}: uint32
    nimfw_dbg_tcpip_input_frame_pbuf0 {.importc.}: uint32
    nimfw_dbg_tcpip_input_frame_pbuf1 {.importc.}: uint32
    nimfw_dbg_tcpip_input_frame_pbuf2 {.importc.}: uint32
    nimfw_dbg_tcpip_input_frame_pbuf3 {.importc.}: uint32
    nimfw_dbg_tcpip_input_frame_ethertype {.importc.}: uint32
    nimfw_dbg_tcpip_input_udp {.importc.}: uint32
    nimfw_dbg_tcpip_input_dhcp_meta {.importc.}: uint32
    nimfw_dbg_tcpip_input_dhcp_xid {.importc.}: uint32
    nimfw_dbg_tcpip_input_dhcp_yiaddr {.importc.}: uint32
    nimfw_dbg_tcpip_input_dhcp_ch0 {.importc.}: uint32
    nimfw_dbg_tcpip_input_dhcp_ch1 {.importc.}: uint32
    nimfw_dbg_auth_sm_dispatch {.importc.}: uint32
    nimfw_dbg_auth_sm_state {.importc.}: uint32
    nimfw_dbg_auth_handler {.importc.}: uint32
    nimfw_dbg_auth_handler_last {.importc.}: uint32
    nimfw_dbg_auth_open_success {.importc.}: uint32
    nimfw_dbg_preauth_sta_req {.importc.}: uint32
    nimfw_dbg_preauth_sta_req_meta {.importc.}: uint32
    nimfw_dbg_preauth_sta_req_bssid0 {.importc.}: uint32
    nimfw_dbg_preauth_sta_req_bssid1 {.importc.}: uint32
    nimfw_dbg_preauth_sta_add_entry {.importc.}: uint32
    nimfw_dbg_preauth_sta_add_meta {.importc.}: uint32
    nimfw_dbg_preauth_sta_add_exit {.importc.}: uint32
    nimfw_dbg_preauth_sta_add_result {.importc.}: uint32
    nimfw_dbg_preauth_sta_cfm {.importc.}: uint32
    nimfw_dbg_preauth_sta_cfm_meta {.importc.}: uint32
    nimfw_dbg_assoc_req_send {.importc.}: uint32
    nimfw_dbg_assoc_req_meta {.importc.}: uint32
    nimfw_dbg_assoc_req_desc {.importc.}: uint32
    nimfw_dbg_assoc_req_raw {.importc.}: array[128, uint8]
    nimfw_dbg_assoc_cfm_status {.importc.}: uint32
    nimfw_dbg_assoc_cfm_hw_status {.importc.}: uint32
    nimfw_dbg_assoc_cfm_thd_flags {.importc.}: uint32
    nimfw_dbg_assoc_cfm_ack_ok16 {.importc.}: uint32
    nimfw_dbg_assoc_cfm_ack_ok23 {.importc.}: uint32
    nimfw_dbg_assoc_cfm_ack_fail {.importc.}: uint32
    nimfw_dbg_assoc_cfm_meta {.importc.}: uint32
    nimfw_dbg_assoc_cfm_push {.importc.}: uint32
    nimfw_dbg_assoc_rsp_status {.importc.}: uint32
    nimfw_dbg_set_vif_state {.importc.}: uint32
    nimfw_dbg_set_vif_state_new {.importc.}: uint32
    nimfw_dbg_set_vif_state_act {.importc.}: uint32
    nimfw_dbg_assoc_done {.importc.}: uint32
    nimfw_dbg_sm_rsp_timeout {.importc.}: uint32
    nimfw_dbg_sm_rsp_timeout_state {.importc.}: uint32
    nimfw_dbg_sm_rsp_timeout_rxctrl {.importc.}: uint32
    nimfw_dbg_ack_fallback_auth {.importc.}: uint32
    nimfw_dbg_ack_fallback_assoc {.importc.}: uint32
    nimfw_dbg_ack_fallback_last {.importc.}: uint32
    nimfw_dbg_wparsn_set {.importc.}: uint32
    nimfw_dbg_wparsn_len {.importc.}: uint32
    nimfw_dbg_vif_ielen_assoc {.importc.}: uint32
    nimfw_wpa_pending_mask {.importc.}: uint32
    nimfw_dbg_setkey0 {.importc.}: uint32
    nimfw_dbg_setkey1 {.importc.}: uint32
    nimfw_dbg_setkey2 {.importc.}: uint32
    nimfw_dbg_setkey3 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_calls {.importc.}: uint32
    nimfw_dbg_machwkey_wr_group {.importc.}: uint32
    nimfw_dbg_machwkey_wr_pair {.importc.}: uint32
    nimfw_dbg_machwkey_wr_last0 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_last1 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_pair0 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_pair1 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_pair2 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_pair3 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_pair4 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_pair5 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_pair_ctrl {.importc.}: uint32
    nimfw_dbg_machwkey_wr_pre0 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_pre1 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_pre2 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_pre3 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_ctrl_before {.importc.}: uint32
    nimfw_dbg_machwkey_wr_ctrl_after_write {.importc.}: uint32
    nimfw_dbg_machwkey_wr_write_wait {.importc.}: uint32
    nimfw_dbg_machwkey_wr_read_wait {.importc.}: uint32
    nimfw_dbg_machwkey_wr_group0 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_group1 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_group2 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_group3 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_group_ctrl {.importc.}: uint32
    nimfw_dbg_machwkey_wr_group_read0 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_group_read1 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_group_read2 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_group_read3 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_group_read_ctrl {.importc.}: uint32
    nimfw_dbg_machwkey_wr_read0 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_read1 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_read2 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_read3 {.importc.}: uint32
    nimfw_dbg_machwkey_wr_read_ctrl {.importc.}: uint32
    nimfw_dbg_sta_add_key_calls {.importc.}: uint32
    nimfw_dbg_sta_add_key_meta {.importc.}: uint32
    nimfw_dbg_sta_add_key_ptrs0 {.importc.}: uint32
    nimfw_dbg_sta_add_key_ptrs1 {.importc.}: uint32
    nimfw_dbg_sta_add_key_ptrs2 {.importc.}: uint32
    nimfw_dbg_sta_tbtt_skip {.importc.}: uint32
    nimfw_dbg_sta_tbtt_giveup {.importc.}: uint32
    nimfw_dbg_eapol_in {.importc.}: uint32
    nimfw_dbg_eapol_dropped {.importc.}: uint32
    nimfw_dbg_eapol_fwd {.importc.}: uint32
    nimfw_dbg_vif_wpastate {.importc.}: uint32
    nimfw_dbg_eapol_cb_inv {.importc.}: uint32
    nimfw_dbg_eapol_cb_null {.importc.}: uint32
    nimfw_dbg_sm_state_eapol {.importc.}: uint32
    nimfw_dbg_supp_rx_eapol {.importc.}: uint32
    nimfw_dbg_supp_tx_eapol {.importc.}: uint32
    nimfw_dbg_eth_tx_eapol {.importc.}: uint32
    nimfw_dbg_bl_output_eapol {.importc.}: uint32
    nimfw_dbg_bl_tx_cfm_eapol {.importc.}: uint32
    nimfw_dbg_eapol_cfm_count {.importc.}: uint32
    nimfw_dbg_eapol_cfm_ack_ok {.importc.}: uint32
    nimfw_dbg_eapol_cfm_ack_fail {.importc.}: uint32
    nimfw_dbg_eapol_cfm_status {.importc.}: uint32
    nimfw_dbg_eapol_cfm_ring_idx {.importc.}: uint32
    nimfw_dbg_eapol_cfm_status_log {.importc.}: array[4, uint32]
    nimfw_dbg_eapol_cfm_meta_log {.importc.}: array[4, uint32]
    nimfw_dbg_eapol_cfm_key_log {.importc.}: array[4, uint32]
    nimfw_dbg_eapol_cfm_replay_log {.importc.}: array[4, uint32]
    nimfw_dbg_eapol_cfm_cb_log {.importc.}: array[4, uint32]
    nimfw_dbg_eapol_tx_desc_bytes {.importc.}: uint32
    nimfw_dbg_eapol_tx_hdr0 {.importc.}: uint32
    nimfw_dbg_eapol_tx_hdr1 {.importc.}: uint32
    nimfw_dbg_eapol_tx_hdr2 {.importc.}: uint32
    nimfw_dbg_eapol_tx_hdr3 {.importc.}: uint32
    nimfw_dbg_eapol_tx_addr_hi {.importc.}: uint32
    nimfw_dbg_eapol_tx_policy {.importc.}: uint32
    nimfw_dbg_eapol_tx_buf_desc {.importc.}: uint32
    nimfw_dbg_eapol_tx_hw_desc {.importc.}: uint32
    nimfw_dbg_eapol_tx_rate0 {.importc.}: uint32
    nimfw_dbg_eapol_tx_rate1 {.importc.}: uint32
    nimfw_dbg_eapol_tx_rate2 {.importc.}: uint32
    nimfw_dbg_eapol_tx_rate3 {.importc.}: uint32
    nimfw_dbg_eapol_tx_link0 {.importc.}: uint32
    nimfw_dbg_eapol_tx_link1 {.importc.}: uint32
    nimfw_dbg_send_4of4_tx {.importc.}: uint32
    nimfw_dbg_send_4of4_cb {.importc.}: uint32
    nimfw_dbg_install_ptk {.importc.}: uint32
    nimfw_dbg_m4_tx_state {.importc.}: uint32
    nimfw_dbg_m4_cb_ptr {.importc.}: uint32
    nimfw_dbg_cfm_cb_ptr_last {.importc.}: uint32
    nimfw_dbg_cfm_last_ethertype {.importc.}: uint32
    nimfw_dbg_wpa_state {.importc.}: uint32
    nimfw_dbg_wpa_rx_state {.importc.}: uint32
    nimfw_dbg_wpa_tx_state {.importc.}: uint32
    nimfw_dbg_wpa_deauth {.importc.}: uint32
    nimfw_dbg_connloss {.importc.}: uint32
    nimfw_dbg_crypto_captured {.importc.}: uint32
    nimfw_dbg_crypto_bssid {.importc.}: array[6, uint8]
  proc bl808WpaCurrentState(): uint32 {.importc: "bl808_wpa_current_state", cdecl.}
  when defined(bl808AllcoreWasmHttpJtagGate):
    var allcoreHttpWifiJtagGate* {.exportc: "allcore_http_wifi_jtag_gate".}: uint32

    proc waitAllcoreHttpWifiJtagGate(): CpsVoidFuture {.cps.} =
      allcoreHttpWifiJtagGate = 0x57494649'u32 # "WIFI"
      discard console.sendLine("[M0] allcore_http_wifi_jtag_gate_wait")
      while regRead(cast[uint](addr allcoreHttpWifiJtagGate)) == 0x57494649'u32:
        await sleepUs(10_000'u64)
      discard console.sendLine("[M0] allcore_http_wifi_jtag_gate_release")
  else:
    proc waitAllcoreHttpWifiJtagGate(): CpsVoidFuture =
      completedVoidFuture()

proc buf(): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](addr scratch[0])

proc pass(msg: string) =
  discard console.sendString("[PASS] ")
  discard console.sendLine(msg)
  inc passed

proc fail(msg: string, code: uint32 = 0) =
  discard console.sendString("[FAIL] ")
  discard console.sendString(msg)
  if code != 0:
    discard console.sendString(" code=")
    console.sendHex32(code)
  discard console.sendLine("")
  inc failed

proc printHex(label: string, value: uint32) =
  discard console.sendString(label)
  console.sendHex32(value)
  discard console.sendLine("")

when defined(bl808AllcoreWasmHttp):
  proc wifiRxRamStart(): uint {.importc: "__wifi_rx_ram_start_addr", nodecl.}
  proc wifiRxRamEnd(): uint {.importc: "__wifi_rx_ram_end_addr", nodecl.}
  proc psramBssStart(): uint {.importc: "__psram_bss_start_addr", nodecl.}
  proc psramBssEnd(): uint {.importc: "__psram_bss_end_addr", nodecl.}

  proc initAllcoreHttpMemory() =
    psramInit(psram64mb, psramBurst64)
    psramEnable()
    var cursor = psramBssStart()
    var limit = psramBssEnd()
    while cursor < limit:
      regWrite(cursor, 0)
      cursor += 4'u

    cursor = wifiRxRamStart()
    limit = wifiRxRamEnd()
    while cursor < limit:
      regWrite(cursor, 0)
      cursor += 4'u
    dcacheFlushAll()
    fenceIo()

  proc requestStartsWith(data: openArray[byte], prefix: string): bool =
    if data.len < prefix.len:
      return false
    for i in 0 ..< prefix.len:
      if data[i] != byte(prefix[i]):
        return false
    true

  proc requestTargetsWasm(data: openArray[byte]): bool =
    data.requestStartsWith("GET /wasm/") or
      data.requestStartsWith("POST /wasm/") or
      data.requestStartsWith("DELETE /wasm/")

  proc tryFastAllcoreHttpResponse(data: openArray[byte],
                                  response: var string): bool

  proc allcoreHttpRootBody(): string =
    "BL808 all-core WASM manager\n" &
      "ip=" & $((httpIp shr 0) and 0xFF'u32) & "." &
        $((httpIp shr 8) and 0xFF'u32) & "." &
        $((httpIp shr 16) and 0xFF'u32) & "." &
        $((httpIp shr 24) and 0xFF'u32) & "\n" &
      "http_requests=" & $httpRequests & "\n" &
      "wasm_requests=" & $httpWasmRequests & "\n" &
      "server=cps/http\n" &
      "routes=/wasm/capabilities,/wasm/cores,/wasm/programs,/wasm/tasks,/wasm/repository,/wasm/net/status,/wasm/events/stream\n"

  proc writeStringResponse(tcp: ptr TcpPcb, response: string): ErrT =
    if response.len == 0:
      return ErrOk
    if response.len > uint16.high.int:
      return ErrMem
    tcpWrite(
      tcp,
      cast[pointer](unsafeAddr response[0]),
      response.len.uint16,
      TcpWriteFlagCopy)

  proc allocHttpClient(pcb: ptr TcpPcb): ptr HttpClientState =
    for i in 0 ..< httpClients.len:
      if httpClients[i].pcb == nil:
        httpClients[i].pcb = pcb
        httpClients[i].pending = 0
        httpClients[i].keepOpen = false
        httpClients[i].closeRequested = false
        httpClients[i].upgraded = false
        httpClients[i].wsPath.setLen(0)
        httpClients[i].wsRxBuffer.setLen(0)
        return addr httpClients[i]
    nil

  proc releaseHttpClient(ctx: ptr HttpClientState) =
    if ctx != nil:
      ctx.pcb = nil
      ctx.pending = 0
      ctx.keepOpen = false
      ctx.closeRequested = false
      ctx.upgraded = false
      ctx.wsPath.setLen(0)
      ctx.wsRxBuffer.setLen(0)

  proc closeHttpClient(ctx: ptr HttpClientState): ErrT =
    if ctx == nil or ctx.pcb == nil:
      return ErrOk
    let tcp = ctx.pcb
    tcpRecv(tcp, nil)
    tcpSent(tcp, nil)
    tcpErr(tcp, nil)
    tcpArg(tcp, nil)
    if tcpClose(tcp) != ErrOk:
      inc httpCloseFailures
      tcpAbort(tcp)
      releaseHttpClient(ctx)
      return ErrAbrt
    releaseHttpClient(ctx)
    ErrOk

  proc abortHttpClient(ctx: ptr HttpClientState): ErrT =
    if ctx == nil or ctx.pcb == nil:
      return ErrAbrt
    let tcp = ctx.pcb
    tcpRecv(tcp, nil)
    tcpSent(tcp, nil)
    tcpErr(tcp, nil)
    tcpArg(tcp, nil)
    tcpAbort(tcp)
    releaseHttpClient(ctx)
    ErrAbrt

  proc allcoreHttpSent(arg: pointer, pcb: ptr TcpPcb, len: uint16): ErrT {.cdecl.} =
    discard pcb
    let ctx = cast[ptr HttpClientState](arg)
    if ctx == nil:
      return ErrOk
    if len.uint32 >= ctx.pending:
      ctx.pending = 0
    else:
      ctx.pending -= len.uint32
    if ctx.pending == 0 and (ctx.closeRequested or not ctx.keepOpen):
      return closeHttpClient(ctx)
    ErrOk

  proc allcoreWriteTransport(ctx: ptr HttpClientState, data: string): bool =
    if ctx == nil or ctx.pcb == nil:
      return false
    if data.len == 0:
      return true
    if data.len > uint16.high.int:
      return false
    let rc = tcpWrite(ctx.pcb, cast[pointer](unsafeAddr data[0]),
                      data.len.uint16, TcpWriteFlagCopy)
    if rc == ErrOk:
      ctx.pending += data.len.uint32
      discard tcpOutput(ctx.pcb)
      true
    else:
      inc httpWriteFailures
      false

  proc allcoreCloseTransport(ctx: ptr HttpClientState) =
    if ctx == nil:
      return
    ctx.closeRequested = true
    ctx.keepOpen = false
    ctx.upgraded = false
    if ctx.pending == 0:
      discard closeHttpClient(ctx)

  proc requestHeaderEnd(data: openArray[byte]): int =
    if data.len < 4:
      return -1
    for i in 0 .. data.len - 4:
      if data[i] == byte('\r') and data[i + 1] == byte('\n') and
          data[i + 2] == byte('\r') and data[i + 3] == byte('\n'):
        return i
    -1

  proc requestPath(data: openArray[byte]): string =
    var firstSpace = -1
    var secondSpace = -1
    var i = 0
    while i < data.len:
      if data[i] == byte(' '):
        if firstSpace < 0:
          firstSpace = i
        else:
          secondSpace = i
          break
      if data[i] == byte('\r') or data[i] == byte('\n'):
        break
      inc i
    if firstSpace >= 0 and secondSpace > firstSpace + 1:
      result = newString(secondSpace - firstSpace - 1)
      for j in 0 ..< result.len:
        result[j] = char(data[firstSpace + 1 + j])

  proc containsText(haystack, needle: string): bool =
    if needle.len == 0:
      return true
    if haystack.len < needle.len:
      return false
    for i in 0 .. haystack.len - needle.len:
      var matched = true
      for j in 0 ..< needle.len:
        if haystack[i + j] != needle[j]:
          matched = false
          break
      if matched:
        return true
    false

  proc requestWantsWebSocket(data: openArray[byte]): bool =
    let endIdx = requestHeaderEnd(data)
    if endIdx < 0:
      return false
    var lower = newString(endIdx)
    for i in 0 ..< endIdx:
      let ch = char(data[i])
      lower[i] =
        if ch >= 'A' and ch <= 'Z': char(ord(ch) + 32)
        else: ch
    lower.containsText("upgrade: websocket") and
      lower.containsText("connection:") and
      lower.containsText("upgrade")

  type WsFrameParseStatus = enum
    wfpsComplete,
    wfpsNeedMore,
    wfpsBad

  proc parseClientWsFrame(data: string, opcode: var uint8,
                          payload: var string,
                          consumed: var int): WsFrameParseStatus =
    if data.len < 6:
      return wfpsNeedMore
    let b0 = uint8(ord(data[0]))
    let b1 = uint8(ord(data[1]))
    if (b0 and 0x70'u8) != 0:
      return wfpsBad
    if (b1 and 0x80'u8) == 0:
      return wfpsBad
    opcode = b0 and 0x0F'u8
    var pos = 2
    var payloadLen = int(b1 and 0x7F'u8)
    if payloadLen == 126:
      if data.len < pos + 2 + 4:
        return wfpsNeedMore
      payloadLen = (ord(data[pos]) shl 8) or ord(data[pos + 1])
      pos += 2
    elif payloadLen == 127:
      return wfpsBad
    if data.len < pos + 4 + payloadLen:
      return wfpsNeedMore
    var mask: array[4, uint8]
    for i in 0 ..< 4:
      mask[i] = uint8(ord(data[pos + i]))
    pos += 4
    payload = newString(payloadLen)
    for i in 0 ..< payloadLen:
      payload[i] = char(uint8(ord(data[pos + i])) xor mask[i mod 4])
    consumed = pos + payloadLen
    wfpsComplete

  proc allcoreHttpRecv(arg: pointer, pcb: ptr TcpPcb, p: ptr Pbuf,
                       err: ErrT): ErrT {.cdecl.} =
    let ctx = cast[ptr HttpClientState](arg)
    if pcb == nil:
      if p != nil:
        discard pbufFree(p)
      return ErrOk
    if err != ErrOk:
      if p != nil:
        discard pbufFree(p)
      return abortHttpClient(ctx)
    if p == nil:
      return closeHttpClient(ctx)

    let rxLen = pbufTotLen(p)
    tcpRecved(pcb, rxLen)
    let copyLen =
      if rxLen.uint32 > httpRequestBuffer.len.uint32:
        httpRequestBuffer.len.uint16
      else:
        rxLen
    let copied = pbufCopyPartial(
      p,
      cast[pointer](addr httpRequestBuffer[0]),
      copyLen,
      0)
    discard pbufFree(p)

    httpResponseScratch.setLen(0)
    if ctx != nil and ctx.upgraded and copied == copyLen and copyLen > 0:
      for i in 0 ..< copyLen.int:
        ctx.wsRxBuffer.add char(httpRequestBuffer[i])
      while ctx.wsRxBuffer.len > 0:
        var opcode: uint8
        var payload = ""
        var consumed = 0
        let parsed = parseClientWsFrame(ctx.wsRxBuffer, opcode, payload, consumed)
        if parsed == wfpsNeedMore:
          break
        if parsed == wfpsBad:
          allcoreCloseTransport(ctx)
          return ErrOk
        if consumed >= ctx.wsRxBuffer.len:
          ctx.wsRxBuffer.setLen(0)
        else:
          ctx.wsRxBuffer = ctx.wsRxBuffer[consumed .. ^1]
        let writer = proc(data: string): bool {.closure.} =
          allcoreWriteTransport(ctx, data)
        let closer = proc() {.closure.} =
          allcoreCloseTransport(ctx)
        if opcode == 0x8'u8:
          allcoreCloseTransport(ctx)
          return ErrOk
        elif opcode == 0x9'u8:
          discard allcoreWriteTransport(ctx, webSocketFrame(payload, 0xA'u8))
          return ErrOk
        elif opcode == 0x1'u8 or opcode == 0x2'u8:
          let resp = handleWasmCpsWebSocketMessage(ctx.wsPath, payload,
            allcoreHttpRootBody(), writer, closer)
          if resp.control != rcHandled and resp.body.len > 0:
            discard allcoreWriteTransport(ctx, webSocketFrame(resp.body, 0x1'u8))
        elif opcode != 0xA'u8:
          allcoreCloseTransport(ctx)
          return ErrOk
      return ErrOk
    elif copied == copyLen and copyLen > 0:
      if httpRequestBuffer.toOpenArray(0, copyLen.int - 1).requestTargetsWasm():
        inc httpWasmRequests
      if not tryFastAllcoreHttpResponse(
          httpRequestBuffer.toOpenArray(0, copyLen.int - 1), httpResponseScratch):
        let wantsWs = httpRequestBuffer.toOpenArray(0, copyLen.int - 1).requestWantsWebSocket()
        let path = requestPath(httpRequestBuffer.toOpenArray(0, copyLen.int - 1))
        if ctx != nil:
          tcpSent(pcb, allcoreHttpSent)
        let writer = proc(data: string): bool {.closure.} =
          allcoreWriteTransport(ctx, data)
        let closer = proc() {.closure.} =
          allcoreCloseTransport(ctx)
        let resp = handleWasmCpsHttpTransport(
          httpRequestBuffer.toOpenArray(0, copyLen.int - 1),
          allcoreHttpRootBody(), writer, closer)
        if resp.control == rcHandled:
          if ctx != nil and ctx.pcb == nil:
            return ErrOk
          if ctx != nil and not ctx.closeRequested:
            ctx.keepOpen = true
            if wantsWs:
              ctx.upgraded = true
              ctx.wsPath = path
          if tcpOutput(pcb) == ErrOk:
            inc httpRequests
            return ErrOk
          inc httpWriteFailures
          return abortHttpClient(ctx)
        httpResponseScratch = buildResponseString(resp)
    else:
      discard tryFastAllcoreHttpResponse([], httpResponseScratch)
    let rc = writeStringResponse(pcb, httpResponseScratch)

    if rc == ErrOk:
      if ctx != nil:
        ctx.pending = httpResponseScratch.len.uint32
        ctx.keepOpen = false
      tcpSent(pcb, allcoreHttpSent)
      if tcpOutput(pcb) == ErrOk:
        inc httpRequests
      else:
        inc httpWriteFailures
        return abortHttpClient(ctx)
    else:
      inc httpWriteFailures
      return abortHttpClient(ctx)
    ErrOk

  proc allcoreHttpAccept(arg: pointer, newPcb: ptr TcpPcb,
                         err: ErrT): ErrT {.cdecl.} =
    discard arg
    if err != ErrOk or newPcb == nil:
      return ErrOk
    let ctx = allocHttpClient(newPcb)
    if ctx == nil:
      tcpAbort(newPcb)
      return ErrAbrt
    tcpArg(newPcb, cast[pointer](ctx))
    tcpSent(newPcb, allcoreHttpSent)
    tcpRecv(newPcb, allcoreHttpRecv)
    ErrOk

  proc netifIp4(netif: ptr Netif): uint32 =
    var v: uint32 = 0
    {.emit: "`v` = ((struct netif*)`netif`)->ip_addr.addr;".}
    v

  proc writeDecByte(v: uint8) =
    let hundreds = v div 100'u8
    let tens = (v div 10'u8) mod 10'u8
    let ones = v mod 10'u8
    if hundreds != 0:
      discard console.sendByte((ord('0') + hundreds.int).uint8)
    if hundreds != 0 or tens != 0:
      discard console.sendByte((ord('0') + tens.int).uint8)
    discard console.sendByte((ord('0') + ones.int).uint8)

  proc writeIp4(ip: uint32) =
    writeDecByte(((ip shr 0) and 0xFF'u32).uint8)
    discard console.sendByte('.'.uint8)
    writeDecByte(((ip shr 8) and 0xFF'u32).uint8)
    discard console.sendByte('.'.uint8)
    writeDecByte(((ip shr 16) and 0xFF'u32).uint8)
    discard console.sendByte('.'.uint8)
    writeDecByte(((ip shr 24) and 0xFF'u32).uint8)

  proc ssidMatches(bytes: ptr uint8; length: uint8; name: static[string]): bool =
    if length.int != name.len:
      return false
    let view = cast[ptr UncheckedArray[uint8]](bytes)
    for i in 0 ..< name.len:
      if view[i] != name[i].uint8:
        return false
    true

  proc dumpMatchingScanEntries(): uint32 =
    let count = bl808_wifi_backend_scan_diag_count()
    var printed = 0'u32
    var ssidLen: uint8
    var ssid: array[33, uint8]
    var channel: uint8
    var rssi: int8
    var auth: uint8
    var cipher: uint8
    var bssid: array[6, uint8]
    var i = 0'u32
    while i < count and printed < 8'u32:
      if bl808_wifi_backend_scan_diag_get(i, addr ssidLen, addr ssid[0],
          addr channel, addr rssi, addr auth, addr cipher, addr bssid[0]) == 0:
        if ssidMatches(addr ssid[0], ssidLen, WifiSsid):
          let bssidLo =
            bssid[0].uint32 or (bssid[1].uint32 shl 8) or
            (bssid[2].uint32 shl 16) or (bssid[3].uint32 shl 24)
          let bssidHi = bssid[4].uint32 or (bssid[5].uint32 shl 8)
          let meta =
            channel.uint32 or (cast[uint8](rssi).uint32 shl 8) or
            (auth.uint32 shl 16) or (cipher.uint32 shl 24)
          printHex("[M0] allcore_http_scan_match_slot=", i)
          printHex("[M0] allcore_http_scan_match_meta=", meta)
          printHex("[M0] allcore_http_scan_match_bssid_lo=", bssidLo)
          printHex("[M0] allcore_http_scan_match_bssid_hi=", bssidHi)
          inc printed
      inc i
    printHex("[M0] allcore_http_scan_match_count=", printed)
    printed

  proc nowMs(): uint32 {.inline.} =
    (kernel_read_tick_ms() and 0xffffffff'u64).uint32

  proc pollNetwork() {.inline.} =
    bl808_wifi_backend_poll(64)
    discard wifi_nimfw_service_sta_postponed(8)
    for _ in 0 ..< 8:
      txl_transmit_trigger()
      txl_frame_evt()
    sysCheckTimeouts()

  proc announceHttpIp(netif: ptr Netif) =
    discard etharpGratuitous(netif)
    for _ in 0 ..< 8:
      pollNetwork()

  proc observedDhcpIp(): IpAddr =
    let yiaddr = nimfw_dbg_tcpip_input_dhcp_yiaddr
    ip4Addr(((yiaddr shr 24) and 0xFF'u32).uint8,
            ((yiaddr shr 16) and 0xFF'u32).uint8,
            ((yiaddr shr 8) and 0xFF'u32).uint8,
            (yiaddr and 0xFF'u32).uint8)

  proc applyObservedDhcpLease(netif: ptr Netif): bool =
    let yiaddr = nimfw_dbg_tcpip_input_dhcp_yiaddr
    if yiaddr == 0'u32 or yiaddr == 0xFFFFFFFF'u32:
      return false
    var observedIp = observedDhcpIp()
    var observedMask = ip4Addr(255'u8, 255'u8, 255'u8, 0'u8)
    var observedGw =
      when StaticGatewayA != 0:
        ip4Addr(StaticGatewayA.uint8, StaticGatewayB.uint8,
                StaticGatewayC.uint8, StaticGatewayD.uint8)
      else:
        ip4Addr(((yiaddr shr 24) and 0xFF'u32).uint8,
                ((yiaddr shr 16) and 0xFF'u32).uint8,
                ((yiaddr shr 8) and 0xFF'u32).uint8,
                1'u8)
    netifSetAddr(netif, addr observedIp, addr observedMask, addr observedGw)
    printHex("[M0] allcore_http_dhcp_observed_lease=", netifIp4(netif))
    announceHttpIp(netif)
    true

  proc dumpAllcoreHttpRuntimeDiag() =
    printHex("[M0] allcore_http_runtime_http=", httpRequests)
    printHex("[M0] allcore_http_runtime_wasm=", httpWasmRequests)
    printHex("[M0] allcore_http_runtime_close_fail=", httpCloseFailures)
    printHex("[M0] allcore_http_runtime_write_fail=", httpWriteFailures)
    printHex("[M0] allcore_http_runtime_tcpip_calls=", nimfw_dbg_tcpip_input_calls)
    printHex("[M0] allcore_http_runtime_tcpip_ok=", nimfw_dbg_tcpip_input_ok)
    printHex("[M0] allcore_http_runtime_tcpip_fail=", nimfw_dbg_tcpip_input_fail)
    printHex("[M0] allcore_http_runtime_arp=", nimfw_dbg_tcpip_input_arp)
    printHex("[M0] allcore_http_runtime_tcp=", nimfw_dbg_tcpip_input_tcp)
    printHex("[M0] allcore_http_runtime_tcp80=", nimfw_dbg_tcpip_input_tcp80)
    printHex("[M0] allcore_http_runtime_ports=", nimfw_dbg_tcpip_input_last_ports)
    printHex("[M0] allcore_http_runtime_ip=", nimfw_dbg_tcpip_input_last_ip)
    printHex("[M0] allcore_http_runtime_hw_rxctrl=", regRead(MachwRxControlReg))
    printHex("[M0] allcore_http_runtime_hw_status=", regRead(MachwStatusReg))
    printHex("[M0] allcore_http_runtime_rxl_seen=", nimfw_dbg_rxl_frame_seen)
    printHex("[M0] allcore_http_runtime_rxu_valid=", nimfw_dbg_rxu_frame_valid)
    printHex("[M0] allcore_http_runtime_rxu_data=", nimfw_dbg_rxu_assoc_data)
    printHex("[M0] allcore_http_runtime_rxu_ip=", nimfw_dbg_rxu_assoc_ip)
    printHex("[M0] allcore_http_runtime_rxu_arp=", nimfw_dbg_rxu_assoc_arp)
    printHex("[M0] allcore_http_runtime_rxu_tcp=", nimfw_dbg_rxu_assoc_tcp)
    printHex("[M0] allcore_http_runtime_rxu_tcp80=", nimfw_dbg_rxu_assoc_tcp80)
    printHex("[M0] allcore_http_runtime_rxu_upload_ready=", nimfw_dbg_rxu_assoc_upload_ready)
    printHex("[M0] allcore_http_runtime_rxu_upload_evt=", nimfw_dbg_rxu_upload_evt)
    printHex("[M0] allcore_http_runtime_rxu_upload_entry=", nimfw_dbg_rxu_upload_entry)
    printHex("[M0] allcore_http_runtime_rxu_upload_ok=", nimfw_dbg_rxu_upload_tcpip_ok)
    printHex("[M0] allcore_http_runtime_rxu_upload_fail=", nimfw_dbg_rxu_upload_tcpip_fail)
    printHex("[M0] allcore_http_runtime_rxu_last_proto=", nimfw_dbg_rxu_assoc_last_ip_proto)
    printHex("[M0] allcore_http_runtime_rxu_last_ports=", nimfw_dbg_rxu_assoc_last_tcp_ports)
    printHex("[M0] allcore_http_runtime_rxu_last_flags=", nimfw_dbg_rxu_assoc_last_tcp_flags)
    printHex("[M0] allcore_http_runtime_rxu_drop_invalid=", nimfw_dbg_rxu_drop_invalid)
    printHex("[M0] allcore_http_runtime_rxu_drop_inactive=", nimfw_dbg_rxu_drop_sta_inactive)
    printHex("[M0] allcore_http_runtime_rxu_drop_ftype=", nimfw_dbg_rxu_drop_ftype)
    printHex("[M0] allcore_http_runtime_rxu_drop_null=", nimfw_dbg_rxu_drop_null)
    printHex("[M0] allcore_http_runtime_rxu_drop_dup=", nimfw_dbg_rxu_drop_dup)
    printHex("[M0] allcore_http_runtime_rxu_drop_pn=", nimfw_dbg_rxu_drop_pn)
    printHex("[M0] allcore_http_runtime_rxu_prot_type=", nimfw_dbg_rxu_prot_type)
    printHex("[M0] allcore_http_runtime_rxu_prot_key=", nimfw_dbg_rxu_prot_key)
    printHex("[M0] allcore_http_runtime_rxu_prot_slot_meta=", nimfw_dbg_rxu_prot_slot_meta)
    printHex("[M0] allcore_http_runtime_rxu_prot_slot_key0=", nimfw_dbg_rxu_prot_slot_key0)
    printHex("[M0] allcore_http_runtime_rxu_prot_slot_key1=", nimfw_dbg_rxu_prot_slot_key1)
    printHex("[M0] allcore_http_runtime_rxu_prot_slot_key2=", nimfw_dbg_rxu_prot_slot_key2)
    printHex("[M0] allcore_http_runtime_rxu_prot_slot_key3=", nimfw_dbg_rxu_prot_slot_key3)
    printHex("[M0] allcore_http_runtime_rxu_sw_ccmp_attempt=", nimfw_dbg_rxu_sw_ccmp_attempt)
    printHex("[M0] allcore_http_runtime_rxu_sw_ccmp_ok=", nimfw_dbg_rxu_sw_ccmp_ok)
    printHex("[M0] allcore_http_runtime_rxu_sw_ccmp_fail=", nimfw_dbg_rxu_sw_ccmp_fail)
    printHex("[M0] allcore_http_runtime_rxu_sw_ccmp_len=", nimfw_dbg_rxu_sw_ccmp_len)
    printHex("[M0] allcore_http_runtime_rxu_prot_pn_lo=", nimfw_dbg_rxu_prot_pn_lo)
    printHex("[M0] allcore_http_runtime_rxu_prot_pn_hi=", nimfw_dbg_rxu_prot_pn_hi)
    printHex("[M0] allcore_http_runtime_rxu_pn_meta=", nimfw_dbg_rxu_pn_meta)
    printHex("[M0] allcore_http_runtime_rxu_pn_stored_lo=", nimfw_dbg_rxu_pn_stored_lo)
    printHex("[M0] allcore_http_runtime_rxu_pn_stored_hi=", nimfw_dbg_rxu_pn_stored_hi)
    printHex("[M0] allcore_http_runtime_rxu_pn_next_lo=", nimfw_dbg_rxu_pn_next_lo)
    printHex("[M0] allcore_http_runtime_rxu_pn_next_hi=", nimfw_dbg_rxu_pn_next_hi)
    printHex("[M0] allcore_http_runtime_rxu_snap_lo=", nimfw_dbg_rxu_snap_lo)
    printHex("[M0] allcore_http_runtime_rxu_snap_hi=", nimfw_dbg_rxu_snap_hi)
    printHex("[M0] allcore_http_runtime_tcpip_nfwd=", nimfw_dbg_tcpip_input_no_forward)
    printHex("[M0] allcore_http_runtime_tcpip_novif=", nimfw_dbg_tcpip_input_no_vif)
    printHex("[M0] allcore_http_runtime_tcpip_nonetif=", nimfw_dbg_tcpip_input_no_netif)
    printHex("[M0] allcore_http_runtime_tcpip_nopbuf=", nimfw_dbg_tcpip_input_no_pbuf)
    printHex("[M0] allcore_http_runtime_tcpip_np_stage=", nimfw_dbg_tcpip_input_no_pbuf_stage)
    printHex("[M0] allcore_http_runtime_tcpip_np_status=", nimfw_dbg_tcpip_input_no_pbuf_status)
    printHex("[M0] allcore_http_runtime_tcpip_np_flags=", nimfw_dbg_tcpip_input_no_pbuf_flags)
    printHex("[M0] allcore_http_runtime_tcpip_np_meta=", nimfw_dbg_tcpip_input_no_pbuf_meta)
    printHex("[M0] allcore_http_runtime_tcpip_np_pkt=", nimfw_dbg_tcpip_input_no_pbuf_pkt)
    printHex("[M0] allcore_http_runtime_tcpip_mpdu_conv=", nimfw_dbg_tcpip_input_mpdu_conv)
    printHex("[M0] allcore_http_runtime_tcpip_mpdu_fail=", nimfw_dbg_tcpip_input_mpdu_fail)
    printHex("[M0] allcore_http_runtime_tcpip_mpdu_counts=", nimfw_dbg_tcpip_input_mpdu_fail_counts)
    printHex("[M0] allcore_http_runtime_tcpip_mpdu_dlo=", nimfw_dbg_tcpip_input_mpdu_fail_detail_lo)
    printHex("[M0] allcore_http_runtime_tcpip_mpdu_dhi=", nimfw_dbg_tcpip_input_mpdu_fail_detail_hi)
    printHex("[M0] allcore_http_runtime_tcpip_mpdu_last0=", nimfw_dbg_tcpip_input_mpdu_last0)
    printHex("[M0] allcore_http_runtime_tcpip_mpdu_last1=", nimfw_dbg_tcpip_input_mpdu_last1)
    printHex("[M0] allcore_http_runtime_tcpip_mpdu_last2=", nimfw_dbg_tcpip_input_mpdu_last2)
    printHex("[M0] allcore_http_runtime_tcpip_frame_last0=", nimfw_dbg_tcpip_input_frame_last0)
    printHex("[M0] allcore_http_runtime_tcpip_frame_last1=", nimfw_dbg_tcpip_input_frame_last1)
    printHex("[M0] allcore_http_runtime_tcpip_frame_src0=", nimfw_dbg_tcpip_input_frame_src0)
    printHex("[M0] allcore_http_runtime_tcpip_frame_src1=", nimfw_dbg_tcpip_input_frame_src1)
    printHex("[M0] allcore_http_runtime_tcpip_frame_src2=", nimfw_dbg_tcpip_input_frame_src2)
    printHex("[M0] allcore_http_runtime_tcpip_frame_src3=", nimfw_dbg_tcpip_input_frame_src3)
    printHex("[M0] allcore_http_runtime_tcpip_pbuf0=", nimfw_dbg_tcpip_input_frame_pbuf0)
    printHex("[M0] allcore_http_runtime_tcpip_pbuf1=", nimfw_dbg_tcpip_input_frame_pbuf1)
    printHex("[M0] allcore_http_runtime_tcpip_pbuf2=", nimfw_dbg_tcpip_input_frame_pbuf2)
    printHex("[M0] allcore_http_runtime_tcpip_pbuf3=", nimfw_dbg_tcpip_input_frame_pbuf3)
    printHex("[M0] allcore_http_runtime_tcpip_ethertype=", nimfw_dbg_tcpip_input_frame_ethertype)
    printHex("[M0] allcore_http_runtime_tcpip_udp=", nimfw_dbg_tcpip_input_udp)
    printHex("[M0] allcore_http_runtime_tcpip_dhcp_rx=", nimfw_dbg_tcpip_input_dhcp_rx)
    printHex("[M0] allcore_http_runtime_tcpip_dhcp_meta=", nimfw_dbg_tcpip_input_dhcp_meta)
    printHex("[M0] allcore_http_runtime_tcpip_dhcp_xid=", nimfw_dbg_tcpip_input_dhcp_xid)
    printHex("[M0] allcore_http_runtime_tcpip_dhcp_yiaddr=", nimfw_dbg_tcpip_input_dhcp_yiaddr)
    printHex("[M0] allcore_http_runtime_tcpip_dhcp_ch0=", nimfw_dbg_tcpip_input_dhcp_ch0)
    printHex("[M0] allcore_http_runtime_tcpip_dhcp_ch1=", nimfw_dbg_tcpip_input_dhcp_ch1)

  proc dumpAllcoreHttpScanDiag() =
    printHex("[M0] allcore_http_mac_irq=", bl808_wifi_backend_mac_irq_count())
    printHex("[M0] allcore_http_mac_irq_trap=", bl808_wifi_backend_mac_trap_irq_count())
    printHex("[M0] allcore_http_ipc_irq=", bl808_wifi_backend_ipc_trap_irq_count())
    printHex("[M0] allcore_http_scan_start_rx=", nimfw_dbg_scan_start_rxctrl)
    printHex("[M0] allcore_http_scan_end_rx=", nimfw_dbg_scan_end_rxctrl)
    printHex("[M0] allcore_http_scan_start_irq=", nimfw_dbg_scan_start_irq_raw)
    printHex("[M0] allcore_http_scan_end_irq=", nimfw_dbg_scan_end_irq_raw)
    printHex("[M0] allcore_http_scan_start_gen=", nimfw_dbg_scan_start_gen_raw)
    printHex("[M0] allcore_http_scan_end_gen=", nimfw_dbg_scan_end_gen_raw)
    printHex("[M0] allcore_http_scan_req_meta=", nimfw_dbg_scan_req_chan_meta)
    printHex("[M0] allcore_http_scan_req_freq=", nimfw_dbg_scan_req_chan_freq)
    printHex("[M0] allcore_http_cache_find=", nimfw_dbg_scan_cache_find)
    printHex("[M0] allcore_http_cache_hit=", nimfw_dbg_scan_cache_hit)
    printHex("[M0] allcore_http_cache_candidates=", nimfw_dbg_scan_cache_candidates)
    printHex("[M0] allcore_http_cache_slot=", nimfw_dbg_scan_cache_selected_slot)
    printHex("[M0] allcore_http_cache_meta=", nimfw_dbg_scan_cache_selected_meta)
    printHex("[M0] allcore_http_cache_bssid_lo=", nimfw_dbg_scan_cache_selected_bssid_lo)
    printHex("[M0] allcore_http_cache_bssid_hi=", nimfw_dbg_scan_cache_selected_bssid_hi)
    printHex("[M0] allcore_http_cache_fail_marks=", nimfw_dbg_scan_cache_failure_marks)
    printHex("[M0] allcore_http_cache_fail_count=", nimfw_dbg_scan_cache_failure_count)
    printHex("[M0] allcore_http_scan_key_mgmt=", nimfw_dbg_scan_key_mgmt)
    printHex("[M0] allcore_http_scan_at=", nimfw_dbg_scan_at)
    printHex("[M0] allcore_http_scan_smf=", nimfw_dbg_scan_smf)
    printHex("[M0] allcore_http_scan_caps=", nimfw_dbg_scan_caps)
    printHex("[M0] allcore_http_sm_chan_req0=", nimfw_dbg_sm_chan_ctx_req0)
    printHex("[M0] allcore_http_sm_chan_req1=", nimfw_dbg_sm_chan_ctx_req1)
    printHex("[M0] allcore_http_sm_chan_ptrs=", nimfw_dbg_sm_chan_ctx_ptrs)
    printHex("[M0] allcore_http_sm_chan_result=", nimfw_dbg_sm_chan_ctx_result)
    printHex("[M0] allcore_http_chan_meta=", nimfw_dbg_chan_scan_chan_meta)
    printHex("[M0] allcore_http_chan_freq=", nimfw_dbg_chan_scan_chan_freq)
    printHex("[M0] allcore_http_pre_chan_meta=", nimfw_dbg_chan_pre_chan_meta)
    printHex("[M0] allcore_http_pre_chan_freq=", nimfw_dbg_chan_pre_chan_freq)
    printHex("[M0] allcore_http_irq_raw=", nimfw_dbg_mac_irq_last_int_raw)
    printHex("[M0] allcore_http_irq_gen=", nimfw_dbg_mac_irq_last_gen_raw)
    printHex("[M0] allcore_http_irq_rxctrl=", nimfw_dbg_mac_irq_last_rxctrl)
    printHex("[M0] allcore_http_irq_hd=", nimfw_dbg_mac_irq_last_hd)
    printHex("[M0] allcore_http_irq_pd=", nimfw_dbg_mac_irq_last_pd)
    printHex("[M0] allcore_http_rx_hd=", nimfw_dbg_rxl_snap_hd)
    printHex("[M0] allcore_http_rx_pd=", nimfw_dbg_rxl_snap_pd)
    printHex("[M0] allcore_http_rx_hw_hd=", nimfw_dbg_rxl_snap_hw_hd)
    printHex("[M0] allcore_http_rx_hw_pd=", nimfw_dbg_rxl_snap_hw_pd)
    printHex("[M0] allcore_http_rx_irq=", nimfw_dbg_rxl_snap_irq_raw)
    printHex("[M0] allcore_http_rx_gen=", nimfw_dbg_rxl_snap_gen_raw)
    printHex("[M0] allcore_http_rx_ctrl=", nimfw_dbg_rxl_snap_rxctrl_raw)
    printHex("[M0] allcore_http_rx_status=", nimfw_dbg_rxl_snap_status_raw)
    printHex("[M0] allcore_http_rx_hd_status=", nimfw_dbg_rxl_snap_hd_status)
    printHex("[M0] allcore_http_rx_pd_status=", nimfw_dbg_rxl_snap_pd_status)

  proc dumpAllcoreHttpConnectDiag() =
    printHex("[M0] allcore_http_sm_state=", sm_state.uint32)
    printHex("[M0] allcore_http_assert_count=", nimfw_dbg_assert_err_count)
    printHex("[M0] allcore_http_assert_line=", nimfw_dbg_assert_err_last_line)
    printHex("[M0] allcore_http_hw_wait_timeouts=", nimfw_dbg_hw_wait_timeout_count)
    printHex("[M0] allcore_http_hw_wait_reg=", nimfw_dbg_hw_wait_last_reg)
    printHex("[M0] allcore_http_cache_find=", nimfw_dbg_scan_cache_find)
    printHex("[M0] allcore_http_cache_hit=", nimfw_dbg_scan_cache_hit)
    printHex("[M0] allcore_http_cache_candidates=", nimfw_dbg_scan_cache_candidates)
    printHex("[M0] allcore_http_cache_slot=", nimfw_dbg_scan_cache_selected_slot)
    printHex("[M0] allcore_http_cache_meta=", nimfw_dbg_scan_cache_selected_meta)
    printHex("[M0] allcore_http_cache_bssid_lo=", nimfw_dbg_scan_cache_selected_bssid_lo)
    printHex("[M0] allcore_http_cache_bssid_hi=", nimfw_dbg_scan_cache_selected_bssid_hi)
    printHex("[M0] allcore_http_cache_fail_marks=", nimfw_dbg_scan_cache_failure_marks)
    printHex("[M0] allcore_http_cache_fail_count=", nimfw_dbg_scan_cache_failure_count)
    printHex("[M0] allcore_http_scan_key_mgmt=", nimfw_dbg_scan_key_mgmt)
    printHex("[M0] allcore_http_scan_at=", nimfw_dbg_scan_at)
    printHex("[M0] allcore_http_scan_smf=", nimfw_dbg_scan_smf)
    printHex("[M0] allcore_http_scan_caps=", nimfw_dbg_scan_caps)
    printHex("[M0] allcore_http_sm_chan_req0=", nimfw_dbg_sm_chan_ctx_req0)
    printHex("[M0] allcore_http_sm_chan_req1=", nimfw_dbg_sm_chan_ctx_req1)
    printHex("[M0] allcore_http_sm_chan_ptrs=", nimfw_dbg_sm_chan_ctx_ptrs)
    printHex("[M0] allcore_http_sm_chan_result=", nimfw_dbg_sm_chan_ctx_result)
    printHex("[M0] allcore_http_bss_in=", nimfw_dbg_bss_in)
    printHex("[M0] allcore_http_bss_ssid=", nimfw_dbg_bss_ssid_result)
    printHex("[M0] allcore_http_bss_directed=", nimfw_dbg_bss_directed)
    printHex("[M0] allcore_http_bss_out=", nimfw_dbg_bss_out)
    printHex("[M0] allcore_http_bss_chan_meta=", nimfw_dbg_bss_chan_fix_meta)
    printHex("[M0] allcore_http_bss_freq=", nimfw_dbg_bss_selected_freq)
    printHex("[M0] allcore_http_ssid_search=", nimfw_dbg_ssid_search)
    printHex("[M0] allcore_http_ssid_entries=", nimfw_dbg_ssid_entries)
    printHex("[M0] allcore_http_ssid_hits=", nimfw_dbg_ssid_hits)
    printHex("[M0] allcore_http_auth_tx_len=", nimfw_dbg_auth_tx_len)
    printHex("[M0] allcore_http_auth_tx_meta=", nimfw_dbg_auth_tx_meta)
    printHex("[M0] allcore_http_auth_tx_desc=", nimfw_dbg_auth_tx_desc)
    printHex("[M0] allcore_http_auth_raw0=", cast[ptr uint32](addr nimfw_dbg_auth_tx_raw[0])[])
    printHex("[M0] allcore_http_auth_raw4=", cast[ptr uint32](addr nimfw_dbg_auth_tx_raw[4])[])
    printHex("[M0] allcore_http_auth_raw8=", cast[ptr uint32](addr nimfw_dbg_auth_tx_raw[8])[])
    printHex("[M0] allcore_http_auth_raw12=", cast[ptr uint32](addr nimfw_dbg_auth_tx_raw[12])[])
    printHex("[M0] allcore_http_auth_raw16=", cast[ptr uint32](addr nimfw_dbg_auth_tx_raw[16])[])
    printHex("[M0] allcore_http_auth_raw20=", cast[ptr uint32](addr nimfw_dbg_auth_tx_raw[20])[])
    printHex("[M0] allcore_http_auth_raw24=", cast[ptr uint32](addr nimfw_dbg_auth_tx_raw[24])[])
    printHex("[M0] allcore_http_auth_rxctrl=", nimfw_dbg_auth_rxctrl)
    printHex("[M0] allcore_http_auth_own_lo=", nimfw_dbg_mac_hw_lo)
    printHex("[M0] allcore_http_auth_own_hi=", nimfw_dbg_mac_hw_hi)
    printHex("[M0] allcore_http_auth_bssid_lo=", nimfw_dbg_bssid_hw_lo)
    printHex("[M0] allcore_http_auth_bssid_hi=", nimfw_dbg_bssid_hw_hi)
    printHex("[M0] allcore_http_txtrig_entry=", nimfw_dbg_txtrig_entry)
    printHex("[M0] allcore_http_txtrig_acready=", nimfw_dbg_txtrig_acready)
    printHex("[M0] allcore_http_txtrig_zero=", nimfw_dbg_txtrig_zero)
    printHex("[M0] allcore_http_txtrig_loops=", nimfw_dbg_txtrig_loops)
    printHex("[M0] allcore_http_txtrig_yield=", nimfw_dbg_txtrig_yield)
    printHex("[M0] allcore_http_txtrig_yield_ac=", nimfw_dbg_txtrig_yield_ac)
    printHex("[M0] allcore_http_txtrig_yield_head=", nimfw_dbg_txtrig_yield_head)
    printHex("[M0] allcore_http_txtrig_desc=", nimfw_dbg_txtrig_desc)
    printHex("[M0] allcore_http_txtrig_status=", nimfw_dbg_txtrig_status)
    printHex("[M0] allcore_http_txtrig_notready=", nimfw_dbg_txtrig_notready)
    printHex("[M0] allcore_http_txtrig_nodesc=", nimfw_dbg_txtrig_nodesc)
    printHex("[M0] allcore_http_txint_enter=", nimfw_dbg_txint_enter)
    printHex("[M0] allcore_http_txint_last_cb=", nimfw_dbg_txint_last_cb)
    printHex("[M0] allcore_http_txint_last_fc=", nimfw_dbg_txint_last_fc)
    printHex("[M0] allcore_http_txint_ready=", nimfw_dbg_txint_ready)
    printHex("[M0] allcore_http_txint_psok=", nimfw_dbg_txint_psok)
    printHex("[M0] allcore_http_txint_push=", nimfw_dbg_txint_push)
    printHex("[M0] allcore_http_txint_release=", nimfw_dbg_txint_release)
    printHex("[M0] allcore_http_txint_postpone=", nimfw_dbg_txint_postpone)
    printHex("[M0] allcore_http_txint_meta=", nimfw_dbg_txint_meta)
    printHex("[M0] allcore_http_txint_chan=", nimfw_dbg_txint_chan)
    printHex("[M0] allcore_http_txint_queue=", nimfw_dbg_txint_queue)
    printHex("[M0] allcore_http_txint_hw=", nimfw_dbg_txint_hw)
    printHex("[M0] allcore_http_pay_backup=", nimfw_dbg_pay_backup)
    printHex("[M0] allcore_http_pay_desc=", nimfw_dbg_pay_desc)
    printHex("[M0] allcore_http_pay_payload=", nimfw_dbg_pay_payload)
    printHex("[M0] allcore_http_pay_empty=", nimfw_dbg_pay_empty)
    printHex("[M0] allcore_http_pay_nonempty=", nimfw_dbg_pay_nonempty)
    printHex("[M0] allcore_http_pay_trig=", nimfw_dbg_pay_trig)
    printHex("[M0] allcore_http_pay_tx_status=", nimfw_dbg_pay_tx_status)
    printHex("[M0] allcore_http_pay_tx_agg=", nimfw_dbg_pay_tx_agg)
    printHex("[M0] allcore_http_pay_tx_dma=", nimfw_dbg_pay_tx_dma)
    printHex("[M0] allcore_http_pay_tx_current=", nimfw_dbg_pay_tx_current)
    printHex("[M0] allcore_http_pay_tx_thd=", nimfw_dbg_pay_tx_thd)
    printHex("[M0] allcore_http_pay_tx_head=", nimfw_dbg_pay_tx_head)
    printHex("[M0] allcore_http_probe_pay_meta=", nimfw_dbg_probe_pay_meta)
    printHex("[M0] allcore_http_probe_pay_desc=", nimfw_dbg_probe_pay_desc)
    printHex("[M0] allcore_http_probe_pay_link=", nimfw_dbg_probe_pay_link)
    printHex("[M0] allcore_http_probe_pay_hw=", nimfw_dbg_probe_pay_hw)
    printHex("[M0] allcore_http_probe_pay_thd=", nimfw_dbg_probe_pay_thd)
    printHex("[M0] allcore_http_probe_pay_len=", nimfw_dbg_probe_pay_len)
    printHex("[M0] allcore_http_probe_pay_hw0=", nimfw_dbg_probe_pay_hw0)
    printHex("[M0] allcore_http_probe_pay_hw1=", nimfw_dbg_probe_pay_hw1)
    printHex("[M0] allcore_http_probe_pay_hw2=", nimfw_dbg_probe_pay_hw2)
    printHex("[M0] allcore_http_probe_pay_hw3=", nimfw_dbg_probe_pay_hw3)
    printHex("[M0] allcore_http_probe_pay_link0=", nimfw_dbg_probe_pay_link0)
    printHex("[M0] allcore_http_probe_pay_link1=", nimfw_dbg_probe_pay_link1)
    printHex("[M0] allcore_http_probe_pay_hw_start=", nimfw_dbg_probe_pay_hw_start)
    printHex("[M0] allcore_http_probe_pay_hw_end=", nimfw_dbg_probe_pay_hw_end)
    printHex("[M0] allcore_http_probe_pay_hw_frame_len=", nimfw_dbg_probe_pay_hw_frame_len)
    printHex("[M0] allcore_http_probe_pay_hw_status=", nimfw_dbg_probe_pay_hw_status)
    printHex("[M0] allcore_http_probe_pay_hw_ctrl=", nimfw_dbg_probe_pay_hw_ctrl)
    printHex("[M0] allcore_http_probe_pay_hw_chain=", nimfw_dbg_probe_pay_hw_chain)
    printHex("[M0] allcore_http_probe_pay_hw_retry=", nimfw_dbg_probe_pay_hw_retry_limit_control)
    printHex("[M0] allcore_http_probe_pay_hw_ack=", nimfw_dbg_probe_pay_hw_ack_policy_control)
    printHex("[M0] allcore_http_auth_pay_meta=", nimfw_dbg_auth_pay_meta)
    printHex("[M0] allcore_http_auth_pay_len=", nimfw_dbg_auth_pay_len)
    printHex("[M0] allcore_http_auth_pay_hw0=", nimfw_dbg_auth_pay_hw0)
    printHex("[M0] allcore_http_auth_pay_hw1=", nimfw_dbg_auth_pay_hw1)
    printHex("[M0] allcore_http_auth_pay_hw2=", nimfw_dbg_auth_pay_hw2)
    printHex("[M0] allcore_http_auth_pay_hw3=", nimfw_dbg_auth_pay_hw3)
    printHex("[M0] allcore_http_assoc_pay_meta=", nimfw_dbg_assoc_pay_meta)
    printHex("[M0] allcore_http_assoc_pay_len=", nimfw_dbg_assoc_pay_len)
    printHex("[M0] allcore_http_assoc_pay_hw0=", nimfw_dbg_assoc_pay_hw0)
    printHex("[M0] allcore_http_assoc_pay_hw1=", nimfw_dbg_assoc_pay_hw1)
    printHex("[M0] allcore_http_assoc_pay_hw2=", nimfw_dbg_assoc_pay_hw2)
    printHex("[M0] allcore_http_assoc_pay_hw3=", nimfw_dbg_assoc_pay_hw3)
    printHex("[M0] allcore_http_sta_tx_chan_src=", nimfw_dbg_sta_tx_channel_source)
    printHex("[M0] allcore_http_sta_tx_chan_req0=", nimfw_dbg_sta_tx_channel_req0)
    printHex("[M0] allcore_http_sta_tx_chan_req1=", nimfw_dbg_sta_tx_channel_req1)
    printHex("[M0] allcore_http_sta_tx_chan_vif=", nimfw_dbg_sta_tx_channel_vif)
    printHex("[M0] allcore_http_auth_hw0=", nimfw_dbg_auth_hw_pre_push[0])
    printHex("[M0] allcore_http_auth_hw1=", nimfw_dbg_auth_hw_pre_push[1])
    printHex("[M0] allcore_http_auth_hw2=", nimfw_dbg_auth_hw_pre_push[2])
    printHex("[M0] allcore_http_auth_hw3=", nimfw_dbg_auth_hw_pre_push[3])
    printHex("[M0] allcore_http_auth_hw4=", nimfw_dbg_auth_hw_pre_push[4])
    printHex("[M0] allcore_http_auth_hw5=", nimfw_dbg_auth_hw_pre_push[5])
    printHex("[M0] allcore_http_auth_hw6=", nimfw_dbg_auth_hw_pre_push[6])
    printHex("[M0] allcore_http_auth_hw7=", nimfw_dbg_auth_hw_pre_push[7])
    printHex("[M0] allcore_http_auth_hw8=", nimfw_dbg_auth_hw_pre_push[8])
    printHex("[M0] allcore_http_auth_hw9=", nimfw_dbg_auth_hw_pre_push[9])
    printHex("[M0] allcore_http_auth_hw10=", nimfw_dbg_auth_hw_pre_push[10])
    printHex("[M0] allcore_http_auth_hw11=", nimfw_dbg_auth_hw_pre_push[11])
    printHex("[M0] allcore_http_auth_hw12=", nimfw_dbg_auth_hw_pre_push[12])
    printHex("[M0] allcore_http_auth_hw13=", nimfw_dbg_auth_hw_pre_push[13])
    printHex("[M0] allcore_http_auth_hw14=", nimfw_dbg_auth_hw_pre_push[14])
    printHex("[M0] allcore_http_auth_hw15=", nimfw_dbg_auth_hw_pre_push[15])
    printHex("[M0] allcore_http_auth_hw16=", nimfw_dbg_auth_hw_pre_push[16])
    printHex("[M0] allcore_http_auth_hw17=", nimfw_dbg_auth_hw_pre_push[17])
    printHex("[M0] allcore_http_auth_hw18=", nimfw_dbg_auth_hw_pre_push[18])
    printHex("[M0] allcore_http_auth_hw19=", nimfw_dbg_auth_hw_pre_push[19])
    printHex("[M0] allcore_http_auth_hw20=", nimfw_dbg_auth_hw_pre_push[20])
    printHex("[M0] allcore_http_auth_hw21=", nimfw_dbg_auth_hw_pre_push[21])
    printHex("[M0] allcore_http_auth_hw22=", nimfw_dbg_auth_hw_pre_push[22])
    printHex("[M0] allcore_http_auth_hw23=", nimfw_dbg_auth_hw_pre_push[23])
    printHex("[M0] allcore_http_auth_hw24=", nimfw_dbg_auth_hw_pre_push[24])
    printHex("[M0] allcore_http_auth_hw25=", nimfw_dbg_auth_hw_pre_push[25])
    printHex("[M0] allcore_http_auth_hw26=", nimfw_dbg_auth_hw_pre_push[26])
    printHex("[M0] allcore_http_auth_hw27=", nimfw_dbg_auth_hw_pre_push[27])
    printHex("[M0] allcore_http_auth_hw28=", nimfw_dbg_auth_hw_pre_push[28])
    printHex("[M0] allcore_http_auth_hw29=", nimfw_dbg_auth_hw_pre_push[29])
    printHex("[M0] allcore_http_auth_hw30=", nimfw_dbg_auth_hw_pre_push[30])
    printHex("[M0] allcore_http_auth_hw31=", nimfw_dbg_auth_hw_pre_push[31])
    printHex("[M0] allcore_http_auth_rf0=", nimfw_dbg_auth_rf_pre_push[0])
    printHex("[M0] allcore_http_auth_rf1=", nimfw_dbg_auth_rf_pre_push[1])
    printHex("[M0] allcore_http_auth_rf2=", nimfw_dbg_auth_rf_pre_push[2])
    printHex("[M0] allcore_http_auth_rf3=", nimfw_dbg_auth_rf_pre_push[3])
    printHex("[M0] allcore_http_auth_rf4=", nimfw_dbg_auth_rf_pre_push[4])
    printHex("[M0] allcore_http_auth_rf5=", nimfw_dbg_auth_rf_pre_push[5])
    printHex("[M0] allcore_http_auth_rf6=", nimfw_dbg_auth_rf_pre_push[6])
    printHex("[M0] allcore_http_auth_rf7=", nimfw_dbg_auth_rf_pre_push[7])
    printHex("[M0] allcore_http_auth_cfm_status=", nimfw_dbg_auth_cfm_status)
    printHex("[M0] allcore_http_auth_cfm_hw=", nimfw_dbg_auth_cfm_hw_status)
    printHex("[M0] allcore_http_auth_cfm_thd=", nimfw_dbg_auth_cfm_thd_flags)
    printHex("[M0] allcore_http_auth_cfm_ack16=", nimfw_dbg_auth_cfm_ack_ok16)
    printHex("[M0] allcore_http_auth_cfm_ack23=", nimfw_dbg_auth_cfm_ack_ok23)
    printHex("[M0] allcore_http_auth_cfm_ack_fail=", nimfw_dbg_auth_cfm_ack_fail)
    printHex("[M0] allcore_http_auth_cfm_meta=", nimfw_dbg_auth_cfm_meta)
    printHex("[M0] allcore_http_auth_cfm_desc=", nimfw_dbg_auth_cfm_desc)
    printHex("[M0] allcore_http_auth_cfm_fc=", nimfw_dbg_auth_cfm_fc)
    printHex("[M0] allcore_http_auth_cfm_push=", nimfw_dbg_auth_cfm_push)
    printHex("[M0] allcore_http_auth_mgt_seen=", nimfw_dbg_auth_mgt_seen)
    printHex("[M0] allcore_http_auth_mgt_accept=", nimfw_dbg_auth_mgt_accept)
    printHex("[M0] allcore_http_auth_mgt_reject=", nimfw_dbg_auth_mgt_reject)
    printHex("[M0] allcore_http_auth_mgt_msg=", nimfw_dbg_auth_mgt_msg)
    printHex("[M0] allcore_http_auth_mgt_last0=", nimfw_dbg_auth_mgt_last0)
    printHex("[M0] allcore_http_auth_mgt_last1=", nimfw_dbg_auth_mgt_last1)
    printHex("[M0] allcore_http_mgt_seen=", nimfw_dbg_mgt_seen)
    printHex("[M0] allcore_http_mgt_accept=", nimfw_dbg_mgt_accept)
    printHex("[M0] allcore_http_mgt_reject=", nimfw_dbg_mgt_reject)
    printHex("[M0] allcore_http_mgt_msg=", nimfw_dbg_mgt_msg)
    printHex("[M0] allcore_http_mgt_last_fc=", nimfw_dbg_mgt_last_fc)
    printHex("[M0] allcore_http_mgt_last0=", nimfw_dbg_mgt_last0)
    printHex("[M0] allcore_http_mgt_last1=", nimfw_dbg_mgt_last1)
    printHex("[M0] allcore_http_mgt_drop=", nimfw_dbg_mgt_drop_reason)
    printHex("[M0] allcore_http_mgt_subtype_auth=", nimfw_dbg_mgt_subtype_counts[11])
    printHex("[M0] allcore_http_mgt_subtype_assoc_rsp=", nimfw_dbg_mgt_subtype_counts[1])
    printHex("[M0] allcore_http_mgt_subtype_reassoc_rsp=", nimfw_dbg_mgt_subtype_counts[3])
    printHex("[M0] allcore_http_mgt_auth_last_fc=", nimfw_dbg_mgt_auth_last_fc)
    printHex("[M0] allcore_http_mgt_assoc_last_fc=", nimfw_dbg_mgt_assoc_last_fc)
    printHex("[M0] allcore_http_mgt_assoc_rsp_seen=", nimfw_dbg_mgt_assoc_rsp_seen)
    printHex("[M0] allcore_http_tx_seq_last=", nimfw_dbg_tx_seq_last)
    printHex("[M0] allcore_http_tx_seq_counter=", nimfw_dbg_tx_seq_counter)
    printHex("[M0] allcore_http_rxl_frame_seen=", nimfw_dbg_rxl_frame_seen)
    printHex("[M0] allcore_http_rxl_last_hwflags=", nimfw_dbg_rxl_last_hwflags)
    printHex("[M0] allcore_http_rxl_last_fc=", nimfw_dbg_rxl_last_fc)
    printHex("[M0] allcore_http_rxl_mgmt_seen=", nimfw_dbg_rxl_mgmt_seen)
    printHex("[M0] allcore_http_rxl_mgmt_last=", nimfw_dbg_rxl_mgmt_last)
    printHex("[M0] allcore_http_rxl_auth_like_seen=", nimfw_dbg_rxl_auth_like_seen)
    printHex("[M0] allcore_http_rxl_auth_like_hwflags=", nimfw_dbg_rxl_auth_like_hwflags)
    printHex("[M0] allcore_http_rxl_auth_like_fc=", nimfw_dbg_rxl_auth_like_fc)
    printHex("[M0] allcore_http_rxu_auth_seen=", nimfw_dbg_rxu_auth_seen)
    printHex("[M0] allcore_http_rxu_auth_last0=", nimfw_dbg_rxu_auth_last0)
    printHex("[M0] allcore_http_rxu_auth_last1=", nimfw_dbg_rxu_auth_last1)
    printHex("[M0] allcore_http_rxu_drop_sta_inactive=", nimfw_dbg_rxu_drop_sta_inactive)
    printHex("[M0] allcore_http_rxu_assoc_mgmt=", nimfw_dbg_rxu_assoc_mgmt)
    printHex("[M0] allcore_http_rxu_frame_valid=", nimfw_dbg_rxu_frame_valid)
    printHex("[M0] allcore_http_rxu_drop_invalid=", nimfw_dbg_rxu_drop_invalid)
    printHex("[M0] allcore_http_auth_sm_dispatch=", nimfw_dbg_auth_sm_dispatch)
    printHex("[M0] allcore_http_auth_sm_state=", nimfw_dbg_auth_sm_state)
    printHex("[M0] allcore_http_auth_handler=", nimfw_dbg_auth_handler)
    printHex("[M0] allcore_http_auth_handler_last=", nimfw_dbg_auth_handler_last)
    printHex("[M0] allcore_http_auth_open_success=", nimfw_dbg_auth_open_success)
    printHex("[M0] allcore_http_preauth_sta_req=", nimfw_dbg_preauth_sta_req)
    printHex("[M0] allcore_http_preauth_sta_req_meta=", nimfw_dbg_preauth_sta_req_meta)
    printHex("[M0] allcore_http_preauth_sta_req_bssid0=", nimfw_dbg_preauth_sta_req_bssid0)
    printHex("[M0] allcore_http_preauth_sta_req_bssid1=", nimfw_dbg_preauth_sta_req_bssid1)
    printHex("[M0] allcore_http_preauth_sta_add_entry=", nimfw_dbg_preauth_sta_add_entry)
    printHex("[M0] allcore_http_preauth_sta_add_meta=", nimfw_dbg_preauth_sta_add_meta)
    printHex("[M0] allcore_http_preauth_sta_add_exit=", nimfw_dbg_preauth_sta_add_exit)
    printHex("[M0] allcore_http_preauth_sta_add_result=", nimfw_dbg_preauth_sta_add_result)
    printHex("[M0] allcore_http_preauth_sta_cfm=", nimfw_dbg_preauth_sta_cfm)
    printHex("[M0] allcore_http_preauth_sta_cfm_meta=", nimfw_dbg_preauth_sta_cfm_meta)
    printHex("[M0] allcore_http_assoc_req=", nimfw_dbg_assoc_req_send)
    printHex("[M0] allcore_http_assoc_req_meta=", nimfw_dbg_assoc_req_meta)
    printHex("[M0] allcore_http_assoc_req_desc=", nimfw_dbg_assoc_req_desc)
    printHex("[M0] allcore_http_assoc_raw0=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[0])[])
    printHex("[M0] allcore_http_assoc_raw4=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[4])[])
    printHex("[M0] allcore_http_assoc_raw8=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[8])[])
    printHex("[M0] allcore_http_assoc_raw12=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[12])[])
    printHex("[M0] allcore_http_assoc_raw16=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[16])[])
    printHex("[M0] allcore_http_assoc_raw20=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[20])[])
    printHex("[M0] allcore_http_assoc_raw24=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[24])[])
    printHex("[M0] allcore_http_assoc_raw28=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[28])[])
    printHex("[M0] allcore_http_assoc_raw32=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[32])[])
    printHex("[M0] allcore_http_assoc_raw36=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[36])[])
    printHex("[M0] allcore_http_assoc_raw40=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[40])[])
    printHex("[M0] allcore_http_assoc_raw44=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[44])[])
    printHex("[M0] allcore_http_assoc_raw48=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[48])[])
    printHex("[M0] allcore_http_assoc_raw52=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[52])[])
    printHex("[M0] allcore_http_assoc_raw56=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[56])[])
    printHex("[M0] allcore_http_assoc_raw60=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[60])[])
    printHex("[M0] allcore_http_assoc_raw64=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[64])[])
    printHex("[M0] allcore_http_assoc_raw68=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[68])[])
    printHex("[M0] allcore_http_assoc_raw72=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[72])[])
    printHex("[M0] allcore_http_assoc_raw76=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[76])[])
    printHex("[M0] allcore_http_assoc_raw80=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[80])[])
    printHex("[M0] allcore_http_assoc_raw84=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[84])[])
    printHex("[M0] allcore_http_assoc_raw88=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[88])[])
    printHex("[M0] allcore_http_assoc_raw92=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[92])[])
    printHex("[M0] allcore_http_assoc_raw96=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[96])[])
    printHex("[M0] allcore_http_assoc_raw100=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[100])[])
    printHex("[M0] allcore_http_assoc_raw104=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[104])[])
    printHex("[M0] allcore_http_assoc_raw108=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[108])[])
    printHex("[M0] allcore_http_assoc_raw112=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[112])[])
    printHex("[M0] allcore_http_assoc_raw116=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[116])[])
    printHex("[M0] allcore_http_assoc_raw120=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[120])[])
    printHex("[M0] allcore_http_assoc_raw124=", cast[ptr uint32](addr nimfw_dbg_assoc_req_raw[124])[])
    printHex("[M0] allcore_http_assoc_cfm_status=", nimfw_dbg_assoc_cfm_status)
    printHex("[M0] allcore_http_assoc_cfm_hw=", nimfw_dbg_assoc_cfm_hw_status)
    printHex("[M0] allcore_http_assoc_cfm_thd=", nimfw_dbg_assoc_cfm_thd_flags)
    printHex("[M0] allcore_http_assoc_cfm_ack16=", nimfw_dbg_assoc_cfm_ack_ok16)
    printHex("[M0] allcore_http_assoc_cfm_ack23=", nimfw_dbg_assoc_cfm_ack_ok23)
    printHex("[M0] allcore_http_assoc_cfm_ack_fail=", nimfw_dbg_assoc_cfm_ack_fail)
    printHex("[M0] allcore_http_assoc_cfm_meta=", nimfw_dbg_assoc_cfm_meta)
    printHex("[M0] allcore_http_assoc_cfm_push=", nimfw_dbg_assoc_cfm_push)
    printHex("[M0] allcore_http_assoc_rsp_status=", nimfw_dbg_assoc_rsp_status)
    printHex("[M0] allcore_http_set_vif_state=", nimfw_dbg_set_vif_state)
    printHex("[M0] allcore_http_set_vif_state_new=", nimfw_dbg_set_vif_state_new)
    printHex("[M0] allcore_http_set_vif_state_act=", nimfw_dbg_set_vif_state_act)
    printHex("[M0] allcore_http_assoc_done=", nimfw_dbg_assoc_done)
    printHex("[M0] allcore_http_sm_rsp_timeout=", nimfw_dbg_sm_rsp_timeout)
    printHex("[M0] allcore_http_sm_rsp_timeout_state=", nimfw_dbg_sm_rsp_timeout_state)
    printHex("[M0] allcore_http_sm_rsp_timeout_rxctrl=", nimfw_dbg_sm_rsp_timeout_rxctrl)
    printHex("[M0] allcore_http_ack_fallback_auth=", nimfw_dbg_ack_fallback_auth)
    printHex("[M0] allcore_http_ack_fallback_assoc=", nimfw_dbg_ack_fallback_assoc)
    printHex("[M0] allcore_http_ack_fallback_last=", nimfw_dbg_ack_fallback_last)
    printHex("[M0] allcore_http_wparsn_set=", nimfw_dbg_wparsn_set)
    printHex("[M0] allcore_http_wparsn_len=", nimfw_dbg_wparsn_len)
    printHex("[M0] allcore_http_vif_ielen_assoc=", nimfw_dbg_vif_ielen_assoc)
    printHex("[M0] allcore_http_wpa_pending=", nimfw_wpa_pending_mask)
    printHex("[M0] allcore_http_setkey0=", nimfw_dbg_setkey0)
    printHex("[M0] allcore_http_setkey1=", nimfw_dbg_setkey1)
    printHex("[M0] allcore_http_setkey2=", nimfw_dbg_setkey2)
    printHex("[M0] allcore_http_setkey3=", nimfw_dbg_setkey3)
    printHex("[M0] allcore_http_machwkey_calls=", nimfw_dbg_machwkey_wr_calls)
    printHex("[M0] allcore_http_machwkey_group=", nimfw_dbg_machwkey_wr_group)
    printHex("[M0] allcore_http_machwkey_pair=", nimfw_dbg_machwkey_wr_pair)
    printHex("[M0] allcore_http_machwkey_last0=", nimfw_dbg_machwkey_wr_last0)
    printHex("[M0] allcore_http_machwkey_last1=", nimfw_dbg_machwkey_wr_last1)
    printHex("[M0] allcore_http_machwkey_pair0=", nimfw_dbg_machwkey_wr_pair0)
    printHex("[M0] allcore_http_machwkey_pair1=", nimfw_dbg_machwkey_wr_pair1)
    printHex("[M0] allcore_http_machwkey_pair2=", nimfw_dbg_machwkey_wr_pair2)
    printHex("[M0] allcore_http_machwkey_pair3=", nimfw_dbg_machwkey_wr_pair3)
    printHex("[M0] allcore_http_machwkey_pair4=", nimfw_dbg_machwkey_wr_pair4)
    printHex("[M0] allcore_http_machwkey_pair5=", nimfw_dbg_machwkey_wr_pair5)
    printHex("[M0] allcore_http_machwkey_pair_ctrl=", nimfw_dbg_machwkey_wr_pair_ctrl)
    printHex("[M0] allcore_http_machwkey_pre0=", nimfw_dbg_machwkey_wr_pre0)
    printHex("[M0] allcore_http_machwkey_pre1=", nimfw_dbg_machwkey_wr_pre1)
    printHex("[M0] allcore_http_machwkey_pre2=", nimfw_dbg_machwkey_wr_pre2)
    printHex("[M0] allcore_http_machwkey_pre3=", nimfw_dbg_machwkey_wr_pre3)
    printHex("[M0] allcore_http_machwkey_ctrl_before=", nimfw_dbg_machwkey_wr_ctrl_before)
    printHex("[M0] allcore_http_machwkey_ctrl_after_write=", nimfw_dbg_machwkey_wr_ctrl_after_write)
    printHex("[M0] allcore_http_machwkey_write_wait=", nimfw_dbg_machwkey_wr_write_wait)
    printHex("[M0] allcore_http_machwkey_read_wait=", nimfw_dbg_machwkey_wr_read_wait)
    printHex("[M0] allcore_http_machwkey_group0=", nimfw_dbg_machwkey_wr_group0)
    printHex("[M0] allcore_http_machwkey_group1=", nimfw_dbg_machwkey_wr_group1)
    printHex("[M0] allcore_http_machwkey_group2=", nimfw_dbg_machwkey_wr_group2)
    printHex("[M0] allcore_http_machwkey_group3=", nimfw_dbg_machwkey_wr_group3)
    printHex("[M0] allcore_http_machwkey_group_ctrl=", nimfw_dbg_machwkey_wr_group_ctrl)
    printHex("[M0] allcore_http_machwkey_group_read0=", nimfw_dbg_machwkey_wr_group_read0)
    printHex("[M0] allcore_http_machwkey_group_read1=", nimfw_dbg_machwkey_wr_group_read1)
    printHex("[M0] allcore_http_machwkey_group_read2=", nimfw_dbg_machwkey_wr_group_read2)
    printHex("[M0] allcore_http_machwkey_group_read3=", nimfw_dbg_machwkey_wr_group_read3)
    printHex("[M0] allcore_http_machwkey_group_read_ctrl=", nimfw_dbg_machwkey_wr_group_read_ctrl)
    printHex("[M0] allcore_http_machwkey_read0=", nimfw_dbg_machwkey_wr_read0)
    printHex("[M0] allcore_http_machwkey_read1=", nimfw_dbg_machwkey_wr_read1)
    printHex("[M0] allcore_http_machwkey_read2=", nimfw_dbg_machwkey_wr_read2)
    printHex("[M0] allcore_http_machwkey_read3=", nimfw_dbg_machwkey_wr_read3)
    printHex("[M0] allcore_http_machwkey_read_ctrl=", nimfw_dbg_machwkey_wr_read_ctrl)
    printHex("[M0] allcore_http_sta_add_key_calls=", nimfw_dbg_sta_add_key_calls)
    printHex("[M0] allcore_http_sta_add_key_meta=", nimfw_dbg_sta_add_key_meta)
    printHex("[M0] allcore_http_sta_add_key_ptrs0=", nimfw_dbg_sta_add_key_ptrs0)
    printHex("[M0] allcore_http_sta_add_key_ptrs1=", nimfw_dbg_sta_add_key_ptrs1)
    printHex("[M0] allcore_http_sta_add_key_ptrs2=", nimfw_dbg_sta_add_key_ptrs2)
    printHex("[M0] allcore_http_tbtt_skip=", nimfw_dbg_sta_tbtt_skip)
    printHex("[M0] allcore_http_tbtt_giveup=", nimfw_dbg_sta_tbtt_giveup)
    printHex("[M0] allcore_http_eapol_in=", nimfw_dbg_eapol_in)
    printHex("[M0] allcore_http_eapol_drop=", nimfw_dbg_eapol_dropped)
    printHex("[M0] allcore_http_eapol_fwd=", nimfw_dbg_eapol_fwd)
    printHex("[M0] allcore_http_vif_wpa=", nimfw_dbg_vif_wpastate)
    printHex("[M0] allcore_http_eapol_cb_inv=", nimfw_dbg_eapol_cb_inv)
    printHex("[M0] allcore_http_eapol_cb_null=", nimfw_dbg_eapol_cb_null)
    printHex("[M0] allcore_http_sm_eapol=", nimfw_dbg_sm_state_eapol)
    printHex("[M0] allcore_http_supp_rx=", nimfw_dbg_supp_rx_eapol)
    printHex("[M0] allcore_http_supp_tx=", nimfw_dbg_supp_tx_eapol)
    printHex("[M0] allcore_http_eth_tx_eapol=", nimfw_dbg_eth_tx_eapol)
    printHex("[M0] allcore_http_bl_out_eapol=", nimfw_dbg_bl_output_eapol)
    printHex("[M0] allcore_http_bl_cfm_eapol=", nimfw_dbg_bl_tx_cfm_eapol)
    printHex("[M0] allcore_http_eapol_cfm=", nimfw_dbg_eapol_cfm_count)
    printHex("[M0] allcore_http_eapol_ack_ok=", nimfw_dbg_eapol_cfm_ack_ok)
    printHex("[M0] allcore_http_eapol_ack_fail=", nimfw_dbg_eapol_cfm_ack_fail)
    printHex("[M0] allcore_http_eapol_cfm_status=", nimfw_dbg_eapol_cfm_status)
    printHex("[M0] allcore_http_eapol_cfm_ring=", nimfw_dbg_eapol_cfm_ring_idx)
    printHex("[M0] allcore_http_eapol_cfm_st0=", nimfw_dbg_eapol_cfm_status_log[0])
    printHex("[M0] allcore_http_eapol_cfm_st1=", nimfw_dbg_eapol_cfm_status_log[1])
    printHex("[M0] allcore_http_eapol_cfm_st2=", nimfw_dbg_eapol_cfm_status_log[2])
    printHex("[M0] allcore_http_eapol_cfm_st3=", nimfw_dbg_eapol_cfm_status_log[3])
    printHex("[M0] allcore_http_eapol_cfm_meta0=", nimfw_dbg_eapol_cfm_meta_log[0])
    printHex("[M0] allcore_http_eapol_cfm_meta1=", nimfw_dbg_eapol_cfm_meta_log[1])
    printHex("[M0] allcore_http_eapol_cfm_meta2=", nimfw_dbg_eapol_cfm_meta_log[2])
    printHex("[M0] allcore_http_eapol_cfm_meta3=", nimfw_dbg_eapol_cfm_meta_log[3])
    printHex("[M0] allcore_http_eapol_cfm_key0=", nimfw_dbg_eapol_cfm_key_log[0])
    printHex("[M0] allcore_http_eapol_cfm_key1=", nimfw_dbg_eapol_cfm_key_log[1])
    printHex("[M0] allcore_http_eapol_cfm_key2=", nimfw_dbg_eapol_cfm_key_log[2])
    printHex("[M0] allcore_http_eapol_cfm_key3=", nimfw_dbg_eapol_cfm_key_log[3])
    printHex("[M0] allcore_http_eapol_cfm_rep0=", nimfw_dbg_eapol_cfm_replay_log[0])
    printHex("[M0] allcore_http_eapol_cfm_rep1=", nimfw_dbg_eapol_cfm_replay_log[1])
    printHex("[M0] allcore_http_eapol_cfm_rep2=", nimfw_dbg_eapol_cfm_replay_log[2])
    printHex("[M0] allcore_http_eapol_cfm_rep3=", nimfw_dbg_eapol_cfm_replay_log[3])
    printHex("[M0] allcore_http_eapol_cfm_cb0=", nimfw_dbg_eapol_cfm_cb_log[0])
    printHex("[M0] allcore_http_eapol_cfm_cb1=", nimfw_dbg_eapol_cfm_cb_log[1])
    printHex("[M0] allcore_http_eapol_cfm_cb2=", nimfw_dbg_eapol_cfm_cb_log[2])
    printHex("[M0] allcore_http_eapol_cfm_cb3=", nimfw_dbg_eapol_cfm_cb_log[3])
    printHex("[M0] allcore_http_eapol_tx_desc=", nimfw_dbg_eapol_tx_desc_bytes)
    printHex("[M0] allcore_http_eapol_tx_hdr0=", nimfw_dbg_eapol_tx_hdr0)
    printHex("[M0] allcore_http_eapol_tx_hdr1=", nimfw_dbg_eapol_tx_hdr1)
    printHex("[M0] allcore_http_eapol_tx_hdr2=", nimfw_dbg_eapol_tx_hdr2)
    printHex("[M0] allcore_http_eapol_tx_hdr3=", nimfw_dbg_eapol_tx_hdr3)
    printHex("[M0] allcore_http_eapol_tx_addr_hi=", nimfw_dbg_eapol_tx_addr_hi)
    printHex("[M0] allcore_http_eapol_tx_policy=", nimfw_dbg_eapol_tx_policy)
    printHex("[M0] allcore_http_eapol_tx_buf_desc=", nimfw_dbg_eapol_tx_buf_desc)
    printHex("[M0] allcore_http_eapol_tx_hw_desc=", nimfw_dbg_eapol_tx_hw_desc)
    printHex("[M0] allcore_http_eapol_tx_rate0=", nimfw_dbg_eapol_tx_rate0)
    printHex("[M0] allcore_http_eapol_tx_rate1=", nimfw_dbg_eapol_tx_rate1)
    printHex("[M0] allcore_http_eapol_tx_rate2=", nimfw_dbg_eapol_tx_rate2)
    printHex("[M0] allcore_http_eapol_tx_rate3=", nimfw_dbg_eapol_tx_rate3)
    printHex("[M0] allcore_http_eapol_tx_link0=", nimfw_dbg_eapol_tx_link0)
    printHex("[M0] allcore_http_eapol_tx_link1=", nimfw_dbg_eapol_tx_link1)
    printHex("[M0] allcore_http_send_4of4_tx=", nimfw_dbg_send_4of4_tx)
    printHex("[M0] allcore_http_send_4of4_cb=", nimfw_dbg_send_4of4_cb)
    printHex("[M0] allcore_http_install_ptk=", nimfw_dbg_install_ptk)
    printHex("[M0] allcore_http_m4_tx_state=", nimfw_dbg_m4_tx_state)
    printHex("[M0] allcore_http_m4_cb_ptr=", nimfw_dbg_m4_cb_ptr)
    printHex("[M0] allcore_http_cfm_cb_ptr=", nimfw_dbg_cfm_cb_ptr_last)
    printHex("[M0] allcore_http_cfm_ethertype=", nimfw_dbg_cfm_last_ethertype)
    printHex("[M0] allcore_http_wpa_state=", nimfw_dbg_wpa_state)
    printHex("[M0] allcore_http_wpa_current_state=", bl808WpaCurrentState())
    printHex("[M0] allcore_http_wpa_rx_state=", nimfw_dbg_wpa_rx_state)
    printHex("[M0] allcore_http_wpa_tx_state=", nimfw_dbg_wpa_tx_state)
    printHex("[M0] allcore_http_wpa_deauth=", nimfw_dbg_wpa_deauth)
    printHex("[M0] allcore_http_connloss=", nimfw_dbg_connloss)
    printHex("[M0] allcore_http_crypto_captured=", nimfw_dbg_crypto_captured)
    printHex("[M0] allcore_http_crypto_bssid0=", cast[ptr uint32](addr nimfw_dbg_crypto_bssid[0])[])
    printHex("[M0] allcore_http_crypto_bssid1=", cast[ptr uint16](addr nimfw_dbg_crypto_bssid[4])[].uint32)

  proc startAllcoreHttpServer(port: uint16): bool =
    let pcb = tcpNew()
    if pcb == nil:
      return false
    var any = ipAddrAny()
    let bindRc = tcpBind(pcb, addr any, port)
    if bindRc != ErrOk:
      tcpAbort(pcb)
      return false
    httpListenPcb = tcpListen(pcb)
    if httpListenPcb == nil:
      tcpAbort(pcb)
      return false
    tcpAccept(httpListenPcb, allcoreHttpAccept)
    true

proc installLpWramBootGate() =
  var cursor = LpWramBootGateAddr
  for word in LpWramBootGate:
    regWrite(cursor, word)
    cursor += 4'u
  dcacheFlushAll()
  fenceI()
  fenceIo()

proc sharedRead32(address: uint): uint32 =
  dcacheFlushAll()
  dcacheInvalidateAll()
  core.fence()
  regRead(address)

when defined(bl808AllcoreWasmHttp):
  proc appendDecU32(dst: var string, value: uint32) =
    var digits: array[10, char]
    var n = value
    var count = 0
    while true:
      digits[count] = char(ord('0') + int(n mod 10'u32))
      inc count
      n = n div 10'u32
      if n == 0:
        break
    while count > 0:
      dec count
      dst.add(digits[count])

  proc appendDecI32(dst: var string, value: int32) =
    if value < 0:
      dst.add("-")
      dst.appendDecU32(uint32(-(int64(value))))
    else:
      dst.appendDecU32(uint32(value))

  proc appendJsonU32(dst: var string, value: uint32) =
    dst.appendDecU32(value)

  proc appendJsonI32(dst: var string, value: int32) =
    dst.appendDecI32(value)

  proc appendJsonBool(dst: var string, value: bool) =
    if value:
      dst.add("true")
    else:
      dst.add("false")

  proc appendPeerDebugJson(dst: var string, base: uint) =
    dst.add("{\"magic\":")
    dst.appendJsonU32(sharedRead32(base + 0'u))
    dst.add(",\"seq\":")
    dst.appendJsonU32(sharedRead32(base + 4'u))
    dst.add(",\"opcode\":")
    dst.appendJsonU32(sharedRead32(base + 8'u))
    dst.add(",\"state\":")
    dst.appendJsonU32(sharedRead32(base + 12'u))
    dst.add(",\"slot\":")
    dst.appendJsonU32(sharedRead32(base + 16'u))
    dst.add(",\"argc\":")
    dst.appendJsonU32(sharedRead32(base + 20'u))
    dst.add(",\"fuel\":")
    dst.appendJsonU32(sharedRead32(base + 24'u))
    dst.add(",\"taskId\":")
    dst.appendJsonU32(sharedRead32(base + 28'u))
    dst.add(",\"controlStatus\":")
    dst.appendJsonU32(sharedRead32(base + 36'u))
    dst.add(",\"schedulerStatus\":")
    dst.appendJsonU32(sharedRead32(base + 40'u))
    dst.add(",\"taskState\":")
    dst.appendJsonU32(sharedRead32(base + 44'u))
    dst.add(",\"value\":")
    dst.appendJsonI32(cast[int32](sharedRead32(base + 48'u)))
    dst.add(",\"imageAddr\":")
    dst.appendJsonU32(sharedRead32(base + 136'u))
    dst.add(",\"imageLen\":")
    dst.appendJsonU32(sharedRead32(base + 140'u))
    dst.add("}")

  proc wasmLiveStatusName(status: uint32): string =
    case status
    of 0'u32: "pending"
    of WasmLiveOk: "ok"
    of WasmLiveInstallFailed: "install_failed"
    of WasmLiveAddFailed: "add_failed"
    of WasmLiveSumFailed: "sum_failed"
    of WasmLiveHeartbeatStarved: "heartbeat_starved"
    of WasmLiveEnclaveFailed: "enclave_failed"
    of WasmLiveTimeout: "timeout"
    of WasmLiveProbeOnly: "probe_only"
    else: "unknown"

  proc appendAllcoreCoreJson(dst: var string, name: string, status, hb: uint32,
                             addValue, sumValue, expectedSum: int32) =
    let ok = status == WasmLiveOk and hb >= WasmLiveMinHeartbeat and
      addValue == 42'i32 and sumValue == expectedSum
    dst.add("{\"name\":\"")
    dst.add(name)
    dst.add("\",\"status\":")
    dst.appendJsonU32(status)
    dst.add(",\"statusName\":\"")
    dst.add(wasmLiveStatusName(status))
    dst.add("\"")
    dst.add(",\"heartbeat\":")
    dst.appendJsonU32(hb)
    dst.add(",\"add\":")
    dst.appendJsonI32(addValue)
    dst.add(",\"sum\":")
    dst.appendJsonI32(sumValue)
    dst.add(",\"expectedSum\":")
    dst.appendJsonI32(expectedSum)
    dst.add(",\"ok\":")
    dst.appendJsonBool(ok)
    dst.add("}")

  proc appendAllcorePeerCoreJson(dst: var string, name: string, status, hb: uint32,
                                 addValue, sumValue, expectedSum: int32,
                                 peerBase: uint, probe2, probe3: uint32) =
    appendAllcoreCoreJson(dst, name, status, hb, addValue, sumValue, expectedSum)
    if dst.len > 0 and dst[dst.len - 1] == '}':
      dst.setLen(dst.len - 1)
      dst.add(",\"peerMailbox\":")
      dst.appendPeerDebugJson(peerBase)
      dst.add(",\"peerProbe2\":")
      dst.appendJsonU32(probe2)
      dst.add(",\"peerProbe3\":")
      dst.appendJsonU32(probe3)
      dst.add("}")

  proc appendAllcoreCoreStatusJson(dst: var string) =
    let d0Status = sharedRead32(WasmLiveD0StatusAddr)
    let d0Heartbeat = sharedRead32(WasmLiveD0HeartbeatAddr)
    let d0Add = cast[int32](sharedRead32(WasmLiveD0AddValueAddr))
    let d0Sum = cast[int32](sharedRead32(WasmLiveD0SumValueAddr))
    let d0Probe2 = sharedRead32(WasmLiveD0Probe2Addr)
    let d0Probe3 = sharedRead32(WasmLiveD0Probe3Addr)
    let lpStatus = sharedRead32(WasmLiveLpStatusAddr)
    let lpHeartbeat = sharedRead32(WasmLiveLpHeartbeatAddr)
    let lpAdd = cast[int32](sharedRead32(WasmLiveLpAddValueAddr))
    let lpSum = cast[int32](sharedRead32(WasmLiveLpSumValueAddr))

    dst.add("[")
    dst.appendAllcoreCoreJson("m0", httpM0WasmStatus, heartbeat,
                              httpM0WasmAddValue, httpM0WasmSumValue, 190'i32)
    dst.add(",")
    dst.appendAllcorePeerCoreJson("d0", d0Status, d0Heartbeat, d0Add, d0Sum,
                                  120'i32, WasmPeerControlD0Addr,
                                  d0Probe2, d0Probe3)
    dst.add(",")
    dst.appendAllcorePeerCoreJson("lp", lpStatus, lpHeartbeat, lpAdd, lpSum,
                                  66'i32, WasmPeerControlLpAddr, 0'u32, 0'u32)
    dst.add(",")
    dst.appendAllcoreCoreJson("enclave", httpEnclaveWasmStatus,
                              httpEnclaveHeartbeat,
                              httpEnclaveWasmAddValue,
                              httpEnclaveWasmSumValue, 91'i32)
    dst.add("]")

  proc allcoreCoreStatusJson(): string =
    result = ""
    result.appendAllcoreCoreStatusJson()

  proc appendIp4(dst: var string, ip: uint32) =
    dst.appendDecU32((ip shr 0) and 0xFF'u32)
    dst.add(".")
    dst.appendDecU32((ip shr 8) and 0xFF'u32)
    dst.add(".")
    dst.appendDecU32((ip shr 16) and 0xFF'u32)
    dst.add(".")
    dst.appendDecU32((ip shr 24) and 0xFF'u32)

  proc appendAllcoreNetStatusJson(dst: var string) =
    dst.add("{\"available\":true,\"status\":\"listening\",\"ip\":\"")
    dst.appendIp4(httpIp)
    dst.add("\",\"httpRequests\":")
    dst.appendJsonU32(httpRequests)
    dst.add(",\"wasmRequests\":")
    dst.appendJsonU32(httpWasmRequests)
    dst.add("}")

  proc allcoreNetStatusJson(): string =
    result = ""
    result.appendAllcoreNetStatusJson()

  proc appendAllcoreRootBody(dst: var string) =
    dst.add("BL808 all-core WASM manager\nip=")
    dst.appendIp4(httpIp)
    dst.add("\nhttp_requests=")
    dst.appendDecU32(httpRequests)
    dst.add("\nwasm_requests=")
    dst.appendDecU32(httpWasmRequests)
    dst.add("\nserver=cps/http\n")
    dst.add("routes=/wasm/capabilities,/wasm/cores,/wasm/programs,/wasm/tasks,/wasm/repository,/wasm/net/status,/wasm/events/stream\n")

  proc appendAllcoreCapabilitiesJson(dst: var string) =
    dst.add("{\"core\":1,\"compact\":true,\"flashBacked\":true,\"softwareF32\":true,")
    dst.add("\"supportsI32\":true,\"supportsF32\":true,\"supportsF64\":false,")
    dst.add("\"supportsImports\":false,\"cores\":")
    dst.appendAllcoreCoreStatusJson()
    dst.add("}")

  proc appendAllcoreSlotJson(dst: var string, slot: WasmControlSlot) =
    dst.add("{\"index\":")
    dst.appendJsonU32(slot.index)
    dst.add(",\"state\":")
    dst.appendJsonU32(slot.state.ord.uint32)
    dst.add(",\"imageLen\":")
    dst.appendJsonU32(slot.imageLen)
    dst.add(",\"generation\":")
    dst.appendJsonU32(slot.generation)
    dst.add(",\"flags\":")
    dst.appendJsonU32(slot.flags)
    dst.add(",\"checksum\":")
    dst.appendJsonU32(slot.checksum)
    dst.add(",\"validation\":")
    dst.appendJsonU32(slot.validation.ord.uint32)
    dst.add("}")

  proc appendAllcoreProgramsJson(dst: var string) =
    var slots: array[Ox64WasmSlotCount, WasmControlSlot]
    let count = listWasmPrograms(slots)
    dst.add("{\"slots\":[")
    for i in 0 ..< count.int:
      if i != 0:
        dst.add(",")
      dst.appendAllcoreSlotJson(slots[i])
    dst.add("]}")

  proc appendAllcoreTaskJson(dst: var string, task: WasmSchedulerTaskInfo) =
    dst.add("{\"id\":")
    dst.appendJsonU32(task.id)
    dst.add(",\"slot\":")
    dst.appendJsonI32(task.slot)
    dst.add(",\"state\":")
    dst.appendJsonU32(task.state.ord.uint32)
    dst.add(",\"value\":")
    dst.appendJsonI32(task.result)
    dst.add(",\"trap\":")
    dst.appendJsonU32(task.trapCode)
    dst.add(",\"resumes\":")
    dst.appendJsonU32(task.resumes)
    dst.add(",\"yields\":")
    dst.appendJsonU32(task.yields)
    dst.add(",\"fuelUsed\":")
    dst.appendJsonU32(task.fuelUsed)
    dst.add(",\"fuelLimit\":")
    dst.appendJsonU32(task.fuelLimit)
    dst.add("}")

  proc appendAllcoreTasksJson(dst: var string) =
    var tasks: array[WasmSchedulerMaxTasks, WasmSchedulerTaskInfo]
    let count = collectWasmTasks(tasks)
    dst.add("{\"tasks\":[")
    for i in 0 ..< count.int:
      if i != 0:
        dst.add(",")
      dst.appendAllcoreTaskJson(tasks[i])
    dst.add("]}")

  proc appendHttpResponse(dst: var string, contentType: string, body: string) =
    dst.add("HTTP/1.1 200 OK\r\nContent-Type: ")
    dst.add(contentType)
    dst.add("\r\nConnection: close\r\nContent-Length: ")
    dst.appendDecU32(uint32(body.len))
    dst.add("\r\n\r\n")
    dst.add(body)

  proc tryFastAllcoreHttpResponse(data: openArray[byte],
                                  response: var string): bool =
    httpBodyScratch.setLen(0)
    if data.len == 0 or data.requestStartsWith("GET / "):
      httpBodyScratch.appendAllcoreRootBody()
      response.appendHttpResponse("text/plain", httpBodyScratch)
      return true
    if data.requestStartsWith("GET /wasm/net/status "):
      httpBodyScratch.appendAllcoreNetStatusJson()
      response.appendHttpResponse("application/json", httpBodyScratch)
      return true
    if data.requestStartsWith("GET /wasm/cores "):
      httpBodyScratch.add("{\"cores\":")
      httpBodyScratch.appendAllcoreCoreStatusJson()
      httpBodyScratch.add("}")
      response.appendHttpResponse("application/json", httpBodyScratch)
      return true
    if data.requestStartsWith("GET /wasm/capabilities "):
      httpBodyScratch.appendAllcoreCapabilitiesJson()
      response.appendHttpResponse("application/json", httpBodyScratch)
      return true
    if data.requestStartsWith("GET /wasm/programs "):
      httpBodyScratch.appendAllcoreProgramsJson()
      response.appendHttpResponse("application/json", httpBodyScratch)
      return true
    if data.requestStartsWith("GET /wasm/tasks "):
      httpBodyScratch.appendAllcoreTasksJson()
      response.appendHttpResponse("application/json", httpBodyScratch)
      return true
    false

proc putWasmInvokeReq(slot: uint32, a, b: int32): int =
  let name = "add"
  wrU32(buf(), 0, slot)
  wrU32(buf(), 4, name.len.uint32)
  wrU32(buf(), 8, 2)
  wrU32(buf(), 12, cast[uint32](a))
  wrU32(buf(), 16, cast[uint32](b))
  for i in 0 ..< name.len:
    buf()[20 + i] = name[i].uint8
  20 + name.len

proc putWasmTaskReq(slot: uint32, n: int32): int =
  let name = "sum"
  wrU32(buf(), 0, slot)
  wrU32(buf(), 4, name.len.uint32)
  wrU32(buf(), 8, 1)
  wrU32(buf(), 12, cast[uint32](n))
  for i in 0 ..< name.len:
    buf()[16 + i] = name[i].uint8
  16 + name.len

proc bumpHeartbeat(counter: var uint32) {.inline.} =
  if counter < high(uint32):
    inc counter
  else:
    counter = WasmLiveMinHeartbeat

when defined(bl808AllcoreWasmHttp):
  proc putEnclaveWasmStartReq(slot: uint32, exportName: string,
                              args: openArray[int32]): int =
    wrU32(buf(), 0, slot)
    wrU32(buf(), 4, exportName.len.uint32)
    wrU32(buf(), 8, args.len.uint32)
    for i in 0 ..< args.len:
      wrU32(buf(), 12 + i * 4, cast[uint32](args[i]))
    let nameOff = 12 + args.len * 4
    for i in 0 ..< exportName.len:
      buf()[nameOff + i] = exportName[i].uint8
    nameOff + exportName.len

  proc enclaveTaskResultFromBuffer(core: WasmOsCore, opcode: WasmPeerControlOpcode,
                                   seq, slot, taskId: uint32): WasmPeerControlResult =
    WasmPeerControlResult(
      ok: rdU32(buf(), 0) == wasmControlOk.ord.uint32,
      seq: seq,
      core: core,
      opcode: opcode,
      controlStatus: WasmControlStatus(rdU32(buf(), 0)),
      schedulerStatus: WasmSchedulerStatus(rdU32(buf(), 4)),
      taskId: rdU32(buf(), 8),
      slot: cast[int32](rdU32(buf(), 12)),
      taskState: WasmSchedulerTaskState(rdU32(buf(), 16)),
      value: cast[int32](rdU32(buf(), 20)),
      trapCode: rdU32(buf(), 24),
      resumes: rdU32(buf(), 28),
      yields: rdU32(buf(), 32),
      fuelUsed: rdU32(buf(), 36),
      fuelLimit: rdU32(buf(), 40),
    )

  proc enclaveControlProvider(opcode: WasmPeerControlOpcode,
                              slot, taskId, fuel: uint32,
                              exportName: string,
                              args: openArray[int32]): WasmPeerControlResult =
    const EnclaveHttpSeq = 0xE001'u32
    var svc: SvcId
    var reqLen = 0
    case opcode
    of wasmPeerStart:
      svc = svcWasmTaskStartI32
      reqLen = putEnclaveWasmStartReq(slot, exportName, args)
    of wasmPeerResume:
      svc = svcWasmTaskResume
      wrU32(buf(), 0, taskId)
      wrU32(buf(), 4, fuel)
      reqLen = 8
    of wasmPeerStatus:
      svc = svcWasmTaskStatus
      wrU32(buf(), 0, taskId)
      reqLen = 4
    of wasmPeerKill:
      svc = svcWasmTaskKill
      wrU32(buf(), 0, taskId)
      reqLen = 4
    else:
      return WasmPeerControlResult(
        badCore: true,
        core: wasmOsCoreEnclave,
        opcode: opcode,
        seq: EnclaveHttpSeq,
        slot: slot.int32,
        taskId: taskId,
      )
    let resp = enclaveDispatch(callerUmodeAppCtx(), svc, reqLen, buf(), scratch.len)
    bumpHeartbeat(httpEnclaveHeartbeat)
    if resp[0] != svcOk or resp[1] != 44:
      return WasmPeerControlResult(
        core: wasmOsCoreEnclave,
        opcode: opcode,
        seq: EnclaveHttpSeq,
        controlStatus: wasmControlRunError,
        schedulerStatus: wasmSchedBadState,
        taskId: taskId,
        slot: slot.int32,
        trapCode: resp[0].ord.uint32,
      )
    enclaveTaskResultFromBuffer(wasmOsCoreEnclave, opcode, EnclaveHttpSeq, slot, taskId)

proc heartbeatTask(): CpsVoidFuture {.cps.} =
  while heartbeat < 512'u32:
    bumpHeartbeat(heartbeat)
    await yieldNow()

proc m0WasmTask(): CpsVoidFuture {.cps.} =
  let addRun = runWasmProgramI32(WasmLiveAddSlot, "add", [21'i32, 21'i32])
  if addRun.status != wasmControlOk or addRun.value != 42'i32:
    when defined(bl808AllcoreWasmHttp):
      httpM0WasmStatus = WasmLiveAddFailed
      httpM0WasmAddValue = addRun.value
    fail("M0 live WASM add program", addRun.status.ord.uint32)
    return
  when defined(bl808AllcoreWasmHttp):
    httpM0WasmAddValue = addRun.value

  let sumRun = await startAndRunWasmProgramTaskCps(
    WasmLiveSumSlot,
    "sum",
    [20'i32],
    sliceFuel = 2'u32,
    maxSlices = 256'u32,
    maxTotalFuel = 2048'u32,
  )
  if sumRun.status != wasmControlOk or sumRun.taskState != wasmTaskExited or
      sumRun.value != 190'i32:
    when defined(bl808AllcoreWasmHttp):
      httpM0WasmStatus = WasmLiveSumFailed
      httpM0WasmSumValue = sumRun.value
    fail("M0 live WASM sum program", sumRun.trapCode)
    return
  when defined(bl808AllcoreWasmHttp):
    httpM0WasmSumValue = sumRun.value
  discard killWasmProgramTask(sumRun.taskId)

  if heartbeat < WasmLiveMinHeartbeat:
    when defined(bl808AllcoreWasmHttp):
      httpM0WasmStatus = WasmLiveHeartbeatStarved
    fail("M0 CPS heartbeat starved by WASM", heartbeat)
  else:
    when defined(bl808AllcoreWasmHttp):
      httpM0WasmStatus = WasmLiveOk
    pass("M0 executed multiple WASM programs under CPS")

proc enclaveWasmTask(): CpsVoidFuture {.cps.} =
  let reqLen = putWasmInvokeReq(WasmLiveAddSlot, 22'i32, 20'i32)
  let invokeResp =
    enclaveDispatch(callerUmodeAppCtx(), svcWasmInvokeI32, reqLen, buf(), scratch.len)
  when defined(bl808AllcoreWasmHttp):
    bumpHeartbeat(httpEnclaveHeartbeat)
  if invokeResp[0] != svcOk or invokeResp[1] != 16 or
      rdU32(buf(), 0) != wasmControlOk.ord.uint32 or
      cast[int32](rdU32(buf(), 12)) != 42'i32:
    when defined(bl808AllcoreWasmHttp):
      httpEnclaveWasmStatus = WasmLiveAddFailed
      httpEnclaveWasmAddValue = cast[int32](rdU32(buf(), 12))
    fail("enclave live WASM add program", rdU32(buf(), 0))
    return
  when defined(bl808AllcoreWasmHttp):
    httpEnclaveWasmAddValue = cast[int32](rdU32(buf(), 12))

  await yieldNow()

  let taskReqLen = putWasmTaskReq(WasmLiveSumSlot, 14'i32)
  let startResp =
    enclaveDispatch(callerUmodeAppCtx(), svcWasmTaskStartI32,
                    taskReqLen, buf(), scratch.len)
  when defined(bl808AllcoreWasmHttp):
    bumpHeartbeat(httpEnclaveHeartbeat)
  let taskId = rdU32(buf(), 8)
  if startResp[0] != svcOk or startResp[1] != 44 or
      rdU32(buf(), 0) != wasmControlOk.ord.uint32 or taskId == 0:
    when defined(bl808AllcoreWasmHttp):
      httpEnclaveWasmStatus = WasmLiveSumFailed
    fail("enclave live WASM task start", rdU32(buf(), 0))
    return

  var done = false
  for _ in 0 ..< 64:
    wrU32(buf(), 0, taskId)
    wrU32(buf(), 4, 3'u32)
    let resumeResp =
      enclaveDispatch(callerUmodeAppCtx(), svcWasmTaskResume, 8, buf(), scratch.len)
    when defined(bl808AllcoreWasmHttp):
      bumpHeartbeat(httpEnclaveHeartbeat)
    if resumeResp[0] != svcOk or resumeResp[1] != 44:
      when defined(bl808AllcoreWasmHttp):
        httpEnclaveWasmStatus = WasmLiveSumFailed
      fail("enclave live WASM task resume transport")
      return
    if rdU32(buf(), 16) == wasmTaskExited.ord.uint32:
      done = cast[int32](rdU32(buf(), 20)) == 91'i32
      when defined(bl808AllcoreWasmHttp):
        httpEnclaveWasmSumValue = cast[int32](rdU32(buf(), 20))
      break
    await yieldNow()

  wrU32(buf(), 0, taskId)
  discard enclaveDispatch(callerUmodeAppCtx(), svcWasmTaskKill, 4, buf(), scratch.len)
  when defined(bl808AllcoreWasmHttp):
    bumpHeartbeat(httpEnclaveHeartbeat)

  if done:
    when defined(bl808AllcoreWasmHttp):
      httpEnclaveWasmStatus = WasmLiveOk
    pass("enclave executed multiple WASM programs under CPS load")
  else:
    when defined(bl808AllcoreWasmHttp):
      httpEnclaveWasmStatus = WasmLiveSumFailed
    fail("enclave live WASM task result")

proc waitPeer(name: string, statusAddr, heartbeatAddr, addAddr, sumAddr: uint,
              expectedSum: int32): CpsVoidFuture {.cps.} =
  var loops = 0
  while loops < WaitLoops:
    let status = sharedRead32(statusAddr)
    if status != 0:
      let hb = sharedRead32(heartbeatAddr)
      let addValue = cast[int32](sharedRead32(addAddr))
      let sumValue = cast[int32](sharedRead32(sumAddr))
      printHex("  " & name & "_status=", status)
      printHex("  " & name & "_heartbeat=", hb)
      printHex("  " & name & "_add_detail=", cast[uint32](addValue))
      printHex("  " & name & "_sum_detail=", cast[uint32](sumValue))
      if name == "D0":
        printHex("  D0_probe2=", sharedRead32(WasmLiveD0Probe2Addr))
        printHex("  D0_probe3=", sharedRead32(WasmLiveD0Probe3Addr))
      if status == WasmLiveOk and hb >= WasmLiveMinHeartbeat and
          addValue == 42'i32 and sumValue == expectedSum:
        pass(name & " executed multiple WASM programs under CPS")
      else:
        fail(name & " live WASM CPS worker", status)
      return
    inc loops
    await yieldNow()
  printHex("  " & name & "_status=", sharedRead32(statusAddr))
  printHex("  " & name & "_heartbeat=", sharedRead32(heartbeatAddr))
  printHex("  " & name & "_add_detail=", sharedRead32(addAddr))
  printHex("  " & name & "_sum_detail=", sharedRead32(sumAddr))
  if name == "D0":
    printHex("  D0_probe2=", sharedRead32(WasmLiveD0Probe2Addr))
    printHex("  D0_probe3=", sharedRead32(WasmLiveD0Probe3Addr))
  if name == "LP":
    let rec = faultRecordSnapshot()
    printHex("  LP_fault_magic=", rec.magic)
    printHex("  LP_fault_core=", rec.core)
    printHex("  LP_fault_reason=", rec.reason)
    printHex("  LP_fault_cause=", rec.causeLo)
    printHex("  LP_fault_epc=", rec.epcLo)
    printHex("  LP_fault_tval=", rec.tvalLo)
  fail(name & " live WASM CPS worker timeout", WasmLiveTimeout)

when defined(bl808AllcoreWasmHttp):
  proc runAllcoreHttpManagerAfterSmoke(): CpsVoidFuture {.cps.} =
    if failed != 0:
      return
    when AllcoreHttpHoldPeerCoresBeforeWifi != 0:
      discard console.sendLine("[M0] allcore_http_hold_d0_begin")
      holdD0Reset()
      discard console.sendLine("[M0] allcore_http_hold_d0_done")
      discard console.sendLine("[M0] allcore_http_hold_lp_begin")
      holdLPReset()
      discard console.sendLine("[M0] allcore_http_hold_lp_done")
    else:
      discard console.sendLine("[M0] allcore_http_peer_cores_left_running")
    discard console.sendLine("[M0] allcore_http_wifi_reset_settle_begin")
    await sleepUs(AllcoreHttpWifiResetSettleUs)
    discard console.sendLine("[M0] allcore_http_wifi_reset_settle_done")
    discard console.sendLine("[M0] Starting all-core WASM HTTP manager")
    discard console.sendLine("[M0] allcore_http_lwip_init_begin")
    lwipInit()
    discard console.sendLine("[M0] allcore_http_lwip_init_done")
    discard console.sendLine("[M0] allcore_http_wifi_post_lwip_settle_begin")
    await sleepUs(AllcoreHttpWifiPostLwipSettleUs)
    discard console.sendLine("[M0] allcore_http_wifi_post_lwip_settle_done")
    when defined(bl808AllcoreWasmHttpJtagGate):
      await waitAllcoreHttpWifiJtagGate()
    discard console.sendLine("[M0] allcore_http_wifi_init_begin")
    if wifiInit() != wifiOk:
      discard console.sendLine("[FAIL] all-core HTTP wifi init")
      return
    discard console.sendLine("[M0] allcore_http_wifi_init_done")
    wifiInstallServiceHook(periodUs = 1000'u32, iterations = 16'u32)
    var connectAttempts = 0'u32
    while true:
      inc connectAttempts
      printHex("[M0] allcore_http_wifi_attempt=", connectAttempts)
      discard console.sendLine("[M0] allcore_http_wifi_scan_begin")
      let scanItems = await wifiScanAsync(30_000'u32)
      printHex("[M0] allcore_http_wifi_scan_items=", scanItems)
      printHex("[M0] allcore_http_wifi_scan_done=", bl808_wifi_backend_scan_done_count())
      printHex("[M0] allcore_http_wifi_scan_diag=", bl808_wifi_backend_scan_diag_count())
      let scanMatches = dumpMatchingScanEntries()
      dumpAllcoreHttpScanDiag()
      if scanMatches == 0'u32:
        discard console.sendLine("[M0] allcore_http_wifi_scan_no_match_retry")
        await sleepUs(WifiConnectRetryDelayUs)
        continue
      if scanItems == 0'u32 and nimfw_dbg_scan_cache_candidates == 0'u32:
        discard console.sendLine("[M0] allcore_http_wifi_scan_empty_retry")
        await sleepUs(WifiConnectRetryDelayUs)
        continue
      elif scanItems == 0'u32:
        discard console.sendLine("[M0] allcore_http_wifi_scan_empty_cache_connect")

      discard console.sendLine("[M0] allcore_http_wifi_connect_begin")
      let useFallback =
        WifiFallbackSsid.len > 0 and
        connectAttempts > WifiFallbackAfterAttempts.uint32
      let connectSsid = if useFallback: WifiFallbackSsid else: WifiSsid
      let connectChannel =
        if useFallback and WifiFallbackChannel > 0:
          WifiFallbackChannel.uint8
        else:
          WifiChannel.uint8
      if useFallback:
        discard console.sendLine("[M0] allcore_http_wifi_fallback_ssid")
      let connectResult = await wifiConnectAsync(
        connectSsid, WifiPassword, connectChannel, 30_000'u32)
      if connectResult == wifiOk:
        let wpaDeadline = nowMs() + 10_000'u32
        while bl808WpaCurrentState() != WpaCompletedState and nowMs() < wpaDeadline:
          pollNetwork()
          await yieldNow()
        printHex("[M0] allcore_http_wpa_ready_state=", bl808WpaCurrentState())
        if bl808WpaCurrentState() != WpaCompletedState:
          printHex("[M0] allcore_http_wifi_status=", bl808_wifi_backend_last_status().uint32)
          printHex("[M0] allcore_http_wifi_reason=", bl808_wifi_backend_last_reason().uint32)
          dumpAllcoreHttpConnectDiag()
          discard console.sendLine("[M0] allcore_http_wpa_not_ready_retry")
          let discResult = await wifiDisconnectAsync(10_000'u32)
          printHex("[M0] allcore_http_wpa_retry_disconnect=", discResult.uint32)
          await sleepUs(WifiConnectRetryDelayUs)
          continue
        printHex("[M0] allcore_http_wifi_status=", bl808_wifi_backend_last_status().uint32)
        printHex("[M0] allcore_http_wifi_reason=", bl808_wifi_backend_last_reason().uint32)
        dumpAllcoreHttpConnectDiag()
        break
      printHex("[M0] allcore_http_wifi_status=", bl808_wifi_backend_last_status().uint32)
      printHex("[M0] allcore_http_wifi_reason=", bl808_wifi_backend_last_reason().uint32)
      printHex("[M0] allcore_http_scan_done=", bl808_wifi_backend_scan_done_count())
      printHex("[M0] allcore_http_scan_items=", bl808_wifi_backend_scan_count())
      printHex("[M0] allcore_http_scan_diag=", bl808_wifi_backend_scan_diag_count())
      dumpAllcoreHttpConnectDiag()
      discard console.sendLine("[M0] allcore_http_wifi_connect_retry")
      await sleepUs(WifiConnectRetryDelayUs)
    discard console.sendLine("[M0] allcore_http_wifi_connect_done")
    var netifRaw = wifiGetNetif()
    while netifRaw == nil:
      discard console.sendLine("[M0] allcore_http_netif_missing_retry")
      await sleepUs(WifiConnectRetryDelayUs)
      netifRaw = wifiGetNetif()
    let netif = cast[ptr Netif](netifRaw)

    var dhcpAttempts = 0'u32
    var usingStaticIp = false
    while netifIp4(netif) == 0'u32:
      discard console.sendLine("[M0] allcore_http_dhcp_start_begin")
      if dhcpStart(netif) != ErrOk:
        discard console.sendLine("[M0] allcore_http_dhcp_start_retry")
        await sleepUs(WifiConnectRetryDelayUs)
        continue
      discard console.sendLine("[M0] allcore_http_dhcp_start_done")
      let deadline = nowMs() + DhcpTimeoutMs
      while netifIp4(netif) == 0'u32 and nowMs() < deadline:
        pollNetwork()
        await yieldNow()
      if netifIp4(netif) == 0'u32:
        printHex("[M0] allcore_http_dhcp_tx=", nimfw_dbg_dhcp_tx)
        printHex("[M0] allcore_http_dhcp_tx_msg=", nimfw_dbg_dhcp_tx_msg)
        printHex("[M0] allcore_http_dhcp_cfm_ok=", nimfw_dbg_dhcp_cfm_ok)
        printHex("[M0] allcore_http_dhcp_cfm_fail=", nimfw_dbg_dhcp_cfm_fail)
        printHex("[M0] allcore_http_tx_sec_calls=", nimfw_dbg_tx_sec_hdr_calls)
        printHex("[M0] allcore_http_tx_sec_no_keymat=", nimfw_dbg_tx_sec_hdr_no_keymat)
        printHex("[M0] allcore_http_tx_sec_no_keyslot=", nimfw_dbg_tx_sec_hdr_no_keyslot)
        printHex("[M0] allcore_http_tx_sec_cipher=", nimfw_dbg_tx_sec_hdr_cipher)
        printHex("[M0] allcore_http_tx_sec_len=", nimfw_dbg_tx_sec_hdr_len)
        printHex("[M0] allcore_http_tx_sec_append=", nimfw_dbg_tx_sec_hdr_append)
        printHex("[M0] allcore_http_tx_sec_miss_meta=", nimfw_dbg_tx_sec_hdr_miss_meta)
        printHex("[M0] allcore_http_tx_sec_miss_len=", nimfw_dbg_tx_sec_hdr_miss_len)
        printHex("[M0] allcore_http_tx_sec_miss_keymat=", nimfw_dbg_tx_sec_hdr_miss_keymat)
        printHex("[M0] allcore_http_tx_sec_sta_key0=", nimfw_dbg_tx_sec_hdr_sta_key0)
        printHex("[M0] allcore_http_tx_sec_sta_key1=", nimfw_dbg_tx_sec_hdr_sta_key1)
        printHex("[M0] allcore_http_tx_sec_sta_key2=", nimfw_dbg_tx_sec_hdr_sta_key2)
        printHex("[M0] allcore_http_dhcp_tx_sec=", nimfw_dbg_dhcp_tx_sec)
        printHex("[M0] allcore_http_dhcp_tx_sec_hdr0=", nimfw_dbg_dhcp_tx_sec_hdr0)
        printHex("[M0] allcore_http_dhcp_tx_sec_hdr1=", nimfw_dbg_dhcp_tx_sec_hdr1)
        printHex("[M0] allcore_http_dhcp_tx_sec_key=", nimfw_dbg_dhcp_tx_sec_key)
        printHex("[M0] allcore_http_dhcp_tx_sec_ctl=", nimfw_dbg_dhcp_tx_sec_ctl)
        printHex("[M0] allcore_http_dhcp_rx=", nimfw_dbg_tcpip_input_dhcp_rx)
        printHex("[M0] allcore_http_lwip_dhcp_rx=", nimfw_dbg_lwip_dhcp_recv_count)
        printHex("[M0] allcore_http_lwip_dhcp_offer=", nimfw_dbg_lwip_dhcp_offer_count)
        dumpAllcoreHttpRuntimeDiag()
        inc dhcpAttempts
        if applyObservedDhcpLease(netif):
          usingStaticIp = false
          break
        dhcpStop(netif)
        if StaticIpA != 0 and dhcpAttempts >= StaticIpAfterDhcpAttempts.uint32:
          var staticIp = ip4Addr(StaticIpA.uint8, StaticIpB.uint8,
                                 StaticIpC.uint8, StaticIpD.uint8)
          var staticMask = ip4Addr(StaticNetmaskA.uint8, StaticNetmaskB.uint8,
                                   StaticNetmaskC.uint8, StaticNetmaskD.uint8)
          var staticGw = ip4Addr(StaticGatewayA.uint8, StaticGatewayB.uint8,
                                 StaticGatewayC.uint8, StaticGatewayD.uint8)
          netifSetAddr(netif, addr staticIp, addr staticMask, addr staticGw)
          usingStaticIp = true
          discard console.sendLine("[M0] allcore_http_static_ip_fallback")
          announceHttpIp(netif)
          break
        discard console.sendLine("[M0] allcore_http_dhcp_timeout_retry")
        await sleepUs(WifiConnectRetryDelayUs)
    discard console.sendLine("[M0] allcore_http_dhcp_done")
    httpIp = netifIp4(netif)
    if httpIp != 0'u32:
      printHex("[M0] allcore_http_dhcp_observed_lease=", httpIp)
      announceHttpIp(netif)
    while true:
      discard console.sendLine("[M0] allcore_http_listen_begin")
      if startAllcoreHttpServer(HttpPort.uint16):
        break
      discard console.sendLine("[M0] allcore_http_listen_retry")
      await sleepUs(HttpListenRetryDelayUs)
    discard console.sendLine("[M0] allcore_http_listen_done")
    discard console.sendString("All-core WASM HTTP manager: http://")
    writeIp4(httpIp)
    discard console.sendString("/")
    discard console.sendLine("")
    if usingStaticIp:
      discard console.sendLine("[M0] allcore_http_static_arp_announce")
      announceHttpIp(netif)
    dumpAllcoreHttpRuntimeDiag()
    discard console.sendLine("Ready for all-core WASM HTTP manager requests")
    var lastArpMs = nowMs()
    var lastDiagMs = lastArpMs
    while true:
      pollNetwork()
      bumpHeartbeat(heartbeat)
      if httpEnclaveWasmStatus == WasmLiveOk:
        bumpHeartbeat(httpEnclaveHeartbeat)
      let currentMs = nowMs()
      if httpIp != 0'u32 and currentMs - lastArpMs >= 1000'u32:
        discard etharpGratuitous(netif)
        lastArpMs = currentMs
      if currentMs - lastDiagMs >= 5000'u32:
        dumpAllcoreHttpRuntimeDiag()
        lastDiagMs = currentMs
      await yieldNow()
else:
  proc runAllcoreHttpManagerAfterSmoke(): CpsVoidFuture {.cps.} =
    discard

proc mainWorkflow(): CpsVoidFuture {.cps.} =
  discard heartbeatTask()

  let addInstall = installWasmSlotSmoke(WasmLiveAddSlot)
  if addInstall != WasmSlotSmokeOk:
    fail("install live add WASM slot", addInstall)
    return
  pass("installed live add WASM program")

  discard unloadWasmProgram(WasmLiveSumSlot)
  let sumInstall = installWasmProgramBytes(WasmLiveSumSlot, SumModule, generation = 9'u32)
  if sumInstall.status != wasmControlOk:
    fail("install live sum WASM slot", sumInstall.status.ord.uint32)
    return
  pass("installed live sum WASM program")

  regWrite(WasmLiveD0StatusAddr, 0)
  regWrite(WasmLiveD0HeartbeatAddr, 0)
  regWrite(WasmLiveD0AddValueAddr, 0)
  regWrite(WasmLiveD0SumValueAddr, 0)
  regWrite(WasmLiveD0Probe2Addr, 0)
  regWrite(WasmLiveD0Probe3Addr, 0)
  regWrite(WasmLiveLpStatusAddr, 0)
  regWrite(WasmLiveLpHeartbeatAddr, 0)
  regWrite(WasmLiveLpAddValueAddr, 0)
  regWrite(WasmLiveLpSumValueAddr, 0)
  regWrite(WasmLiveLpStartAddr, 0)
  when defined(bl808AllcoreWasmHttp):
    initPeerWasmControlMailbox(WasmPeerControlD0Addr)
    initPeerWasmControlMailbox(WasmPeerControlLpAddr)
  faultClearRecord()
  writeWasmSlotInvokeRequest(WasmSlotD0RequestAddr, WasmLiveAddSlot,
                             "add", [19'i32, 23'i32], 42'i32)
  writeWasmSlotInvokeRequest(WasmSlotLpRequestAddr, WasmLiveAddSlot,
                             "add", [18'i32, 24'i32], 42'i32)
  dcacheFlushAll()
  fenceIo()

  mmPowerOn()
  pdsSetLpL1cRange(FlashXipBase + Ox64LPBootOffset,
                   FlashXipBase + Ox64D0BootOffset)
  pdsDisableLpL1c()
  installLpWramBootGate()
  discard console.sendLine("[M0] Releasing live LP WASM CPS worker")
  releaseLPAt(LpWramBootGateAddr)

  let initOk = enclaveInit(defaultPartition(lock = false), rkSoftDev)
  if initOk:
    pass("live enclave initialized")
  else:
    fail("live enclave init")
    return
  printHex("[M0] tzc_sec_tzmid=", regRead(TzcSecBmxTzmid))
  printHex("[M0] tzc_nsec_tzmid=", regRead(TzcNsecBmxTzmid))
  printHex("[M0] tzc_sec_bmx_s1=", regRead(TzcSecBmxS1))
  printHex("[M0] tzc_sec_bmx_s2=", regRead(TzcSecBmxS2))
  printHex("[M0] tzc_sec_sf_ctrl=", regRead(TzcSecSfCtrl))
  printHex("[M0] tzc_sec_se_ctrl1=", regRead(TzcSecSeCtrl1))
  printHex("[M0] tzc_sec_sf_r0=", regRead(TzcSecSfR0))
  printHex("[M0] tzc_sec_sf_r3=", regRead(TzcSecSfR3))
  printHex("[M0] tzc_sec_sf_msb=", regRead(TzcSecSfRMsb))
  printHex("[M0] tzc_nsec_sf_ctrl=", regRead(TzcNsecSfCtrl))
  printHex("[M0] tzc_nsec_se_ctrl1=", regRead(TzcNsecSeCtrl1))
  printHex("[M0] tzc_nsec_sf_r0=", regRead(TzcNsecSfR0))
  printHex("[M0] tzc_nsec_sf_r3=", regRead(TzcNsecSfR0 + 12'u))
  printHex("[M0] tzc_nsec_sf_msb=", regRead(TzcNsecSfRMsb))
  printHex("[M0] sf_cfg1_before_lp_xip=", regRead(SfCtrlCfg1))
  printHex("[M0] sf_id0_offset=", regRead(SfCtrlImageOffset0))
  printHex("[M0] sf_id1_offset_before=", regRead(SfCtrlImageOffset1))

  sfCtrlSetLpImageOffsetToGroup1()
  sfCtrlRestoreXip()
  printHex("[M0] sf_cfg1_after_lp_xip=", regRead(SfCtrlCfg1))
  printHex("[M0] sf_id1_offset_after=", regRead(SfCtrlImageOffset1))
  regWrite(WasmLiveLpStartAddr, WasmLiveLpStartMagic)
  dcacheFlushAll()
  fenceIo()

  discard console.sendLine("[M0] Releasing live D0 WASM CPS worker")
  releaseD0()

  let m0Task = m0WasmTask()
  let enclaveTask = enclaveWasmTask()
  let d0Task = waitPeer("D0", WasmLiveD0StatusAddr, WasmLiveD0HeartbeatAddr,
                        WasmLiveD0AddValueAddr, WasmLiveD0SumValueAddr, 120'i32)
  let lpTask = waitPeer("LP", WasmLiveLpStatusAddr, WasmLiveLpHeartbeatAddr,
                        WasmLiveLpAddValueAddr, WasmLiveLpSumValueAddr, 66'i32)

  await m0Task
  await enclaveTask
  await d0Task
  await lpTask
  when defined(bl808AllcoreWasmHttp):
    initPeerWasmControlMailbox(WasmPeerControlD0Addr)
    initPeerWasmControlMailbox(WasmPeerControlLpAddr)

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0 and heartbeat >= WasmLiveMinHeartbeat:
    discard console.sendLine("=== Test Complete ===")
  else:
    discard console.sendLine("=== Test Failed ===")

  await runAllcoreHttpManagerAfterSmoke()

proc main() {.exportc, cdecl.} =
  systemInit()
  when defined(bl808AllcoreWasmHttp):
    initAllcoreHttpMemory()
    setWasmHttpCoreStatusProvider(allcoreCoreStatusJson)
    setWasmHttpNetStatusProvider(allcoreNetStatusJson)
    setWasmHttpEnclaveControlProvider(enclaveControlProvider)
  heapInit()
  schedulerInit()
  enableAllPeriphClocks()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud,
    dataBits: data8,
    stopBits: stop1,
    parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 Live All-Core WASM CPS Test ===")
  initWasmProgramStore()
  discard mainWorkflow()
  runScheduler()
