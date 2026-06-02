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
when defined(bl808WifiVendor):
  import bl808/kernel/jtaglog

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  WifiSsid {.strdefine.} = ""
  WifiPassword {.strdefine.} = ""
  WifiChannel {.intdefine.} = 0
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

when defined(bl808WifiVendor):
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
    var count = bl808_wifi_vendor_scan_diag_count()
    discard console.sendString("[WIFI] scan diag count=")
    console.sendHex32(count)
    discard console.sendLine("")
    if count > 8'u32:
      count = 8'u32
    var i = 0'u32
    while i < count:
      var ssidLen: uint8
      var ssid: array[33, uint8]
      var channel: uint8
      var rssi: int8
      var auth: uint8
      var cipher: uint8
      var bssid: array[6, uint8]
      let rc = bl808_wifi_vendor_scan_diag_get(i, addr ssidLen, addr ssid[0],
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
  var rxl_cntrl_env {.importc.}: array[7, uint32]
  var rx_hwdesc_env {.importc.}: array[2, uint32]

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
  var nimfw_dbg_scan_key_mgmt      {.importc.}: uint32
  var nimfw_dbg_scan_at            {.importc.}: uint32
  var nimfw_dbg_scan_smf           {.importc.}: uint32
  var nimfw_dbg_scan_caps          {.importc.}: uint32
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

  when defined(bl808WifiVendor):
    hwValidationLogReset()

  discard console.sendLine("")
  discard console.sendLine("=== BL808 WiFi HAL Test ===")

  let credsOk = WifiSsid.len > 0 and WifiPassword.len > 0
  let initOk = wifiInit() == wifiOk
  when defined(bl808WifiNimFw):
    discard console.sendLine("[WIFI-NIMFW] bl_init done")
  when not WifiScanOnly:
    check("wifi credentials supplied", credsOk)
  check("wifi init", initOk)

  var iface = wifi_mgmr_sta_enable()
  check("wifi sta enable", iface != nil)
  check("wifi scan", wifi_mgmr_scan(addr iface, nil) == 0)
  when defined(bl808WifiVendor):
    for _ in 0 ..< 30000:
      bl808_wifi_vendor_poll(8)
      if bl808_wifi_vendor_scan_done_count() > 0'u32:
        break
      delayUs(1000)
    for _ in 0 ..< 500:
      bl808_wifi_vendor_poll(8)
      delayUs(1000)
    discard console.sendString("[WIFI] scan items=")
    console.sendHex32(bl808_wifi_vendor_scan_count())
    discard console.sendString(" done=")
    console.sendHex32(bl808_wifi_vendor_scan_done_count())
    discard console.sendString(" macirq=")
    console.sendHex32(bl808_wifi_vendor_mac_irq_count())
    discard console.sendString(" poll=")
    console.sendHex32(bl808_wifi_vendor_mac_poll_irq_count())
    discard console.sendString(" trap=")
    console.sendHex32(bl808_wifi_vendor_mac_trap_irq_count())
    discard console.sendString(" ipc=")
    console.sendHex32(bl808_wifi_vendor_ipc_trap_irq_count())
    discard console.sendString(" ipcpoll=")
    console.sendHex32(bl808_wifi_vendor_ipc_poll_irq_count())
    discard console.sendLine("")
    when defined(bl808WifiNimFwDiag):
      dumpScanDiag()
      dumpWifiRxDebug()
    elif not defined(bl808WifiNimFw):
      dumpWifiMacRegs()
    check("wifi scan complete", bl808_wifi_vendor_scan_done_count() > 0'u32)
    check("wifi scan results", bl808_wifi_vendor_scan_count() > 0'u32)

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
  when defined(bl808WifiVendor):
    when WifiExpectConnectFailure:
      discard console.sendString("[WIFI] connect failure status=")
    else:
      discard console.sendString("[WIFI] connect status=")
    console.sendHex32(bl808_wifi_vendor_last_status().uint32)
    discard console.sendString(" reason=")
    console.sendHex32(bl808_wifi_vendor_last_reason().uint32)
    discard console.sendLine("")
  when defined(bl808WifiNimFwDiag):
    dumpNimFwTxCounters()
  when WifiExpectConnectFailure:
    check("wifi connect expected failure", connectResult != wifiOk)
    when defined(bl808WifiVendor):
      let failureStatus = bl808_wifi_vendor_last_status()
      let failureReason = bl808_wifi_vendor_last_reason()
      check("wifi credential failure classified",
            wifiCredentialFailureMatches(failureStatus, failureReason))
    discard wifiDisconnect()
  else:
    let connectOk = connectResult == wifiOk
    when defined(bl808WifiNimFw):
      if not connectOk:
        dumpNimFwTxCounters()
    check("wifi connect", connectOk)
    when defined(bl808WifiVendor):
      check("wifi connect status", bl808_wifi_vendor_last_status() == 0)
      check("wifi connect reason", bl808_wifi_vendor_last_reason() == 0)
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
