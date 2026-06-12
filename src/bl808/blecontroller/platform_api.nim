# ======================== BFLBBLE (Platform BLE) ==========================
# ---------------------------------------------------------------------------

proc bflbble_init*() {.exportc, cdecl.} =
  ## Initialize the BLE platform-facing controller state.
  blePlatformInitMark(0x300'u32)
  when defined(bl808m0):
    nimDisableM0RfClicIrq()
    nimDisableM0BleClicIrq()
  blePlatformInitMark(0x301'u32)
  prepareWirelessDomain()
  blePlatformInitMark(0x302'u32)
  configureBtPriorityPta()
  blePlatformInitMark(0x303'u32)
  em_buf_init()
  blePlatformInitMark(0x304'u32)
  lld_init(false)
  blePlatformInitMark(0x305'u32)
  bleSettleAfterLldInit()
  blePlatformInitMark(0x306'u32)
  llc_init()
  blePlatformInitMark(0x307'u32)
  llm_init()
  blePlatformInitMark(0x308'u32)
  regWrite((BLE_BASE + 0x050'u32).uint, 0'u32)
  bleVolatileCounterInc(addr nim_ble_bflbble_init_return_count)

proc bflbble_reset*() {.exportc, cdecl.} =
  ## Reset BLE hardware and link-layer state, matching the vendor reset order.
  when defined(bl808m0):
    nimDisableM0RfClicIrq()
    nimDisableM0BleClicIrq()
  lld_core_reset()
  lld_init(true)
  llc_reset()
  llm_init()
  em_buf_init()
  nim_ble_core_ready = false
  initBleCoreRegisters()

proc bflbble_enable_runtime_irqs*() {.exportc, cdecl.} =
  ## Enable runtime BLE/RF interrupt delivery after controller state is ready.
  when defined(bl808m0):
    nimEnableM0BleRuntimeIrqs()

proc bflbble_sleep_check*(): bool {.exportc, cdecl.} =
  return ble_ke_sleep_check()

proc bflbble_activity_ongoing_check*(): bool {.exportc, cdecl.} =
  return ea_env_list.first != nil

proc bflbble_version*(): uint32 {.exportc, cdecl.} =
  return regRead(BLE_BASE + BLE_VERSION_OFFSET)

proc ble_dbg_isr_count*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_isr_count

proc ble_dbg_isr_stat_or*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_isr_stat_or

proc ble_dbg_stat20_count*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_stat20_count

proc ble_dbg_stat8000_count*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_stat8000_count

proc bflbble_isr_clear*() {.exportc, cdecl.} =
  ## Clear all BLE interrupts
  let stat = regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET)
  regWrite(BLE_BASE + BTBLE_INTACK_OFFSET, stat)

proc bflbble_isr*() {.exportc, cdecl.} =
  ## BLE interrupt service routine
  when defined(bl808BleConnectTrace) and defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    if nim_conn_started:
      bleTrace("[CON] isr enter\r\n")
  serviceBleRfCalibrationLatch()
  let stat = regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET)
  let detail = regRead(BLE_BASE + BTBLE_INTDETAIL_OFFSET)
  let swPending = nim_btble_sw_pending or (stat and 0x00000008'u32) != 0
  var legacySchedulerPending = (stat and 0x00008000'u32) != 0
  when defined(bl808m0) and not bl808BleNimRuntimeClicIrq:
    legacySchedulerPending =
      legacySchedulerPending or ((detail and 0x0000001E'u32) != 0)
  var ackStat = stat
  if legacySchedulerPending:
    ackStat = ackStat or 0x00008000'u32
  let observedStat =
    if legacySchedulerPending: stat or 0x00008000'u32 else: stat
  inc nim_ble_dbg_isr_count
  nim_ble_dbg_isr_stat_or = nim_ble_dbg_isr_stat_or or observedStat
  if (observedStat and 0x20'u32) != 0:
    inc nim_ble_dbg_stat20_count
  if (observedStat and 0x8000'u32) != 0:
    inc nim_ble_dbg_stat8000_count
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    serviceNimArbCallbacks()
  when defined(bl808m0) and
      (bl808BleNimConnectionEnabled or
       bl808BleNimPureCentral):
    when bl808BleNimSchProg:
      if swPending and skipFlag != 0'u8:
        inc nim_sch_prog_skip_count
        nimSchProgSkipIsr(uint8(nimSchProgSkipIndex and 0x0F'u32))
        skipFlag = 0'u8
    if legacySchedulerPending:
      inc nim_sch_prog_fifo_count
      nimSchProgFifoIsr()
      when bl808BleNimPureConnection:
        nimConnServiceDeferredSchedule()
      when defined(bl808m0) and
          bl808BleNimConnectionEnabled:
        serviceNimArbCallbacks()
  # Acknowledge all interrupts
  regWrite(BLE_BASE + BTBLE_INTACK_OFFSET, ackStat)
  when defined(bl808m0):
    serviceNimArbTimer()
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if (stat and 0x8000'u32) != 0 or nim_conn_started:
      serviceNimConnectionLlcpRxDescriptors()
  var serviceAdvRx = legacySchedulerPending
  when defined(bl808m0):
    # The vendor scan arbiter can complete RX descriptors without leaving a
    # scheduler FIFO bit visible to the cooperative poller.  Poll while scanning
    # so LE advertising reports are not stranded in EM.
    if nim_scan_enabled:
      serviceAdvRx = true
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    # In cooperative M0 builds the BTBLE RX descriptor done bit can arrive
    # without a FIFO interrupt status bit; poll the advertising RX ring while
    # advertising so SCAN_REQ/CONNECT_IND PDUs are not left queued in EM.
    if nim_adv_enabled:
      serviceAdvRx = true
    if nim_conn_started:
      serviceAdvRx = false
  if serviceAdvRx:
    when defined(bl808BleConnectTrace) and defined(bl808m0) and
        bl808BleNimConnectionEnabled:
      if nim_conn_started:
        bleTrace("[CON] before advrx\r\n")
    serviceBtbleAdvRxDescriptors()
    when defined(bl808m0) and bl808BleNimConnectionEnabled and
        not bl808BleNimRuntimeClicIrq:
      serviceQueuedNimConnectInd()
    when defined(bl808m0) and bl808BleNimConnectionEnabled:
      nimConnMark(0x220'u32)
    when defined(bl808BleConnectTrace) and defined(bl808m0) and
        bl808BleNimConnectionEnabled:
      if nim_conn_started:
        bleTrace("[CON] after advrx\r\n")
  when defined(bl808m0) and
      bl808BleNimSchProg and not bl808BleNimRuntimeClicIrq:
    if not legacySchedulerPending:
      nimSchProgElapsedIsr()
  when defined(bl808m0) and bl808BleNimPureCentral:
    bleControllerServiceScan()
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    serviceNimArbCallbacks()
  when not (defined(bl808m0) and bl808BleNimConnectionEnabled):
    if (stat and 0x20'u32) != 0:
      regClear32(BLE_BASE + BTBLE_INTMASK_OFFSET, BtbleIntEventTarget)
    if (stat and 0x40'u32) != 0:
      regClear32(BLE_BASE + BTBLE_INTMASK_OFFSET, 0x00000040'u32)
    if (stat and 0x80'u32) != 0:
      regClear32(BLE_BASE + BTBLE_INTMASK_OFFSET, 0x00000080'u32)
  if swPending:
    nim_btble_sw_pending = false
    if (stat and 0x08'u32) != 0:
      regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, BtbleIntSw)
    when not (defined(bl808m0) and not bl808BleNimRuntimeClicIrq):
      regClear32(BLE_BASE + BTBLE_INTMASK_OFFSET, BtbleIntSw)
  when bl808BleNimPureConnection:
    nimConnServiceSupervisionTimeout()
    nimConnServiceMissedEventFallback()
    nimConnServiceDeferredSchedule()
  if nim_adv_enabled and
      ((stat and 0x20'u32) != 0 or btbleTargetExpired(nim_adv_target_half_us)):
    pushBtbleAdvProgram()
    scheduleBtbleEvent()
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    if nim_adv_enabled:
      write16(BTBLE_EM_BASE + 0x150'u32, 0x0008'u16)
  when defined(bl808BleConnectTrace) and defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    if nim_conn_started:
      bleTrace("[CON] isr exit\r\n")
      write16(BTBLE_EM_BASE + 0x152'u32, 0'u16)

  # Process interrupt sources
  if (stat and 0x01) != 0:
    ea_finetimer_isr()
  if (stat and 0x02) != 0:
    lld_evt_slot_isr()
  if (stat and 0x04) != 0:
    lld_evt_rx_isr()
  if (stat and 0x08) != 0:
    lld_evt_end_isr()
  if (stat and 0x10) != 0:
    lld_evt_timer_isr()
  if (stat and 0x20) != 0:
    lld_crypt_isr()
  serviceBleRfCalibrationLatch()

proc bleNimDbgIsrCount*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_isr_count

proc bleNimDbgIsrStatOr*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_isr_stat_or

proc bleNimDbgStat20Count*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_stat20_count

proc bleNimDbgStat8000Count*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_stat8000_count

proc bleNimDbgPushCount*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_push_count

proc bleNimDbgRxReadyCount*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_ready_count

proc bleNimDbgRxScanReqCount*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_scan_req_count

proc bleNimDbgRxScanReqMatchCount*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_scan_req_match_count

proc bleNimDbgRxScanReqLastScanA0*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_scan_req_last_scana0

proc bleNimDbgRxScanReqLastScanA1*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_scan_req_last_scana1

proc bleNimDbgRxScanReqLastAdvA0*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_scan_req_last_adva0

proc bleNimDbgRxScanReqLastAdvA1*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_scan_req_last_adva1

proc bleNimDbgRxConnectIndCount*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_connect_ind_count

proc bleNimDbgRxLastHeader*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_last_header

proc bleNimDbgRxLastStatus*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_last_status

proc bleNimDbgRxLastDesc*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_last_desc

proc bleNimDbgRxLastBuf*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_last_buf

proc bleNimDbgVendorConStarted*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_conn_started: 1'u32 else: 0'u32
  else:
    0'u32

proc bleNimPeripheralConnEventCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_evt_count
  else:
    0'u32

proc bleNimPeripheralConnHandle*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_evt_handle
  else:
    0'u32

proc bleNimPeripheralConnPeerA0*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_evt_peer_a0
  else:
    0'u32

proc bleNimPeripheralConnPeerA1*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_evt_peer_a1
  else:
    0'u32

proc bleNimPeripheralConnPeerType*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_evt_peer_type
  else:
    0'u32

proc bleNimPeripheralDiscEventCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_disc_evt_count
  else:
    0'u32

proc bleNimPeripheralDiscReason*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_disc_evt_reason
  else:
    0'u32

proc bleNimPeripheralDiscSource*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_disc_evt_source
  else:
    0'u32

proc bleNimDbgVendorLlcpRxCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_rx_count
  else:
    0'u32

proc bleNimPeripheralLastRxEventCounter*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active:
      nim_conn_state.lastRxEventCounter.uint32
    else:
      0'u32
  else:
    0'u32

proc bleNimDbgVendorLlcpTxCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_tx_count
  else:
    0'u32

proc bleNimDbgVendorLlcpTxQueued*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_tx_queued
  else:
    0'u32

proc bleNimDbgVendorLlcpTxDropped*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_tx_dropped
  else:
    0'u32

proc bleNimDbgVendorLlcpLastOpcode*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_last_opcode
  else:
    0'u32

proc bleNimDbgVendorLlcpLastStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_last_status
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_alloc_count
  else:
    0'u32

proc bleNimDbgVendorLlcpFreeCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_free_count
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocLastLen*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_alloc_last_len
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocLastPtr*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_alloc_last_ptr
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocLastEmoff*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_alloc_last_emoff
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocLastLenField*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_alloc_last_len_field
  else:
    0'u32

proc bleNimDbgVendorLlcpFreeLastRaw*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_free_last_raw
  else:
    0'u32

proc bleNimDbgVendorLlcpFreeManualCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_free_manual_count
  else:
    0'u32

proc bleNimDbgVendorLlcpFreeHeapCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_free_heap_count
  else:
    0'u32

proc bleNimDbgVendorAclEmptyTxCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_acl_empty_tx_count
  else:
    0'u32

proc bleNimDbgVendorAclEmptyTxPending*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_acl_empty_tx_pending
  else:
    0'u32

proc bleNimDbgVendorAclEmptyLastStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_acl_empty_last_status
  else:
    0'u32

proc bleNimDbgVendorConLastStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_status
  else:
    0'u32

proc bleNimDbgVendorConLastRxClock*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_rx_clock
  else:
    0'u32

proc bleNimDbgVendorConLastRxFine*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_rx_fine
  else:
    0'u32

proc bleNimDbgVendorConLastAnchor*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_anchor
  else:
    0'u32

proc bleNimDbgVendorConLastWinOffset*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_win_offset
  else:
    0'u32

proc bleNimDbgVendorConLastInterval*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_interval
  else:
    0'u32

proc bleNimDbgVendorConLastTimeout*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_timeout
  else:
    0'u32

proc bleNimDbgVendorConLastAccessAddr*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_access_addr
  else:
    0'u32

proc bleNimDbgVendorConLastCrcInit*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_crcinit
  else:
    0'u32

proc bleNimDbgVendorConnStage*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleConnStageDiag:
    nim_conn_stage
  else:
    0'u32

proc bleNimDbgVendorConnStageRa*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleConnStageDiag:
    nim_conn_stage_ra
  else:
    0'u32

proc bleNimDbgVendorConnStageSp*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleConnStageDiag:
    nim_conn_stage_sp
  else:
    0'u32

proc bleNimDbgVendorConnStageMepc*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleConnStageDiag:
    nim_conn_stage_mepc
  else:
    0'u32

proc bleNimDbgVendorConnStageMcause*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleConnStageDiag:
    nim_conn_stage_mcause
  else:
    0'u32

proc bleNimDbgVendorConnStageMark*(stage: uint32) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleConnStageDiag:
    nimConnMark(stage)
  else:
    discard stage

proc bleNimDbgVendorLldConStartCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_con_start_count
  else:
    0'u32

proc bleNimDbgVendorLldConStartStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_con_start_status
  else:
    0'u32

proc bleNimDbgVendorLldConStartParamWord*(paramWordIndex: uint32): uint32
    {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    let paramByteOffset = (paramWordIndex and 0x0F'u32) * 4'u32
    uint32(nim_lld_con_start_param[paramByteOffset.int]) or
      (uint32(nim_lld_con_start_param[paramByteOffset.int + 1]) shl 8) or
      (uint32(nim_lld_con_start_param[paramByteOffset.int + 2]) shl 16) or
      (uint32(nim_lld_con_start_param[paramByteOffset.int + 3]) shl 24)
  else:
    0'u32

proc bleNimDbgLldRxCheckCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_check_count
  else:
    0'u32

proc bleNimDbgLldRxCheckHitCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_check_hit_count
  else:
    0'u32

proc bleNimDbgLldRxCheckMissCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_check_miss_count
  else:
    0'u32

proc bleNimDbgLldRxFreeCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_free_count
  else:
    0'u32

proc bleNimDbgLldRxLastIdx*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_last_idx
  else:
    0'u32

proc bleNimDbgLldRxLastEnvIdx*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_last_env_idx
  else:
    0'u32

proc bleNimDbgLldRxLastStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_last_status
  else:
    0'u32

proc bleNimDbgLldRxLastHeader*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_last_header
  else:
    0'u32

proc bleNimDbgLldRxLastMeta*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_last_meta
  else:
    0'u32

proc bleNimDbgConnDeferredScheduleCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimPureConnection:
    nim_conn_deferred_schedule_count
  else:
    0'u32

proc bleNimDbgConnRxStatusRejectCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimPureConnection:
    nim_conn_rx_status_reject_count
  else:
    0'u32

proc bleNimDbgConnRxLastRejectedStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimPureConnection:
    nim_conn_rx_last_rejected_status
  else:
    0'u32

proc bleNimDbgConnRxLastRejectedHeader*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimPureConnection:
    nim_conn_rx_last_rejected_header
  else:
    0'u32

proc bleNimDbgLldRxDescActive*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_desc_active.uint32
  else:
    0'u32

proc bleNimDbgVendorSchProgFifoCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    nim_sch_prog_fifo_count
  else:
    0'u32

proc bleNimDbgVendorSchProgSkipCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    nim_sch_prog_skip_count
  else:
    0'u32

proc bleNimDbgVendorArbSwCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    nim_arb_sw_count
  else:
    0'u32

proc bleNimDbgVendorArbEventStartCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    nim_arb_event_start_count
  else:
    0'u32

proc bleNimDbgVendorArbSetCount*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorArbLastTargetCoarse*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorArbLastTargetFine*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorArbDueTargetCoarse*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorArbDueTargetFine*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorArbDueNowCoarse*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorArbDueNowFine*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorSliceAddCount*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorSliceRemoveCount*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorSliceLastTypeCon*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorSliceLastInterval*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorSliceLastAnchor*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorSliceLastOffset*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorWrapArbInsertCount*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorWrapArbInsertStatus*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorWrapArbInsertLast*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorWrapProgPushCount*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorWrapProgPushLast*(): uint32 {.exportc, cdecl.} =
  0'u32

# ---------------------------------------------------------------------------
# ======================== BFLBIP (Platform IP) ============================
# ---------------------------------------------------------------------------

proc bflbip_init*() {.exportc, cdecl.} =
  bflbip_prevent_sleep_mask = 0
  bflbip_sleep_enabled = false
  bflbip_ext_wakeup = false
  bflbip_sw_wakeup_cnt = 0
  bflbip_sleep_dur_cnt = 0
  bflbip_sleep_stat_cnt = 0
  bflbip_wakeup_delay = 0

proc bflbip_reset*() {.exportc, cdecl.} =
  bflbip_init()

proc bflbip_version*(): uint32 {.exportc, cdecl.} =
  return bflbble_version()

proc bleControllerServiceNonblocking(): bool

proc bflbip_schedule*() {.exportc, cdecl.} =
  when defined(bl808BleConnectTrace) and defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    if nim_conn_started:
      bleTrace("[CON] before sched\r\n")
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    serviceQueuedNimConnectInd()
  discard bleControllerServiceNonblocking()
  when defined(bl808BleConnectTrace) and defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    if nim_conn_started:
      bleTrace("[CON] after sched\r\n")

proc bflbip_get_sw_wakup_cnt*(): uint32 {.exportc, cdecl.} =
  return bflbip_sw_wakeup_cnt

proc bflbip_get_sleep_dur_cnt*(): uint32 {.exportc, cdecl.} =
  return bflbip_sleep_dur_cnt

proc bflbip_get_sleep_stat_cnt*(): uint32 {.exportc, cdecl.} =
  return bflbip_sleep_stat_cnt

proc bflbip_sleep*(): bool {.exportc, cdecl.} =
  ## Check and enter sleep if possible
  if not bflbip_sleep_enabled:
    return false
  if bflbip_prevent_sleep_mask != 0:
    return false
  if not ble_ke_sleep_check():
    return false
  # Enter sleep
  lld_sleep_enter()
  inc bflbip_sleep_stat_cnt
  return true

proc bflbip_check_wakeup_boundary*(): bool {.exportc, cdecl.} =
  return true

proc bflbip_prevent_sleep_set*(mask: uint32) {.exportc, cdecl.} =
  bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask or mask

proc bflbip_prevent_sleep_clear*(mask: uint32) {.exportc, cdecl.} =
  bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask and not mask

proc bflbip_get_prevent_sleep*(): uint32 {.exportc, cdecl.} =
  return bflbip_prevent_sleep_mask

proc bflbip_sleep_enable*(en: bool) {.exportc, cdecl.} =
  bflbip_sleep_enabled = en

proc bflbip_ext_wakeup_enable*(en: bool) {.exportc, cdecl.} =
  bflbip_ext_wakeup = en

proc bflbip_sleep_lpcycles_2_us*(lpcycles: uint32): uint32 {.exportc, cdecl.} =
  ## Convert low-power clock cycles to microseconds
  ## Assumes 32.768 kHz LP clock: 1 cycle = ~30.5 us
  return (lpcycles * 3051) div 100

proc bflbip_us_2_lpcycles*(us: uint32): uint32 {.exportc, cdecl.} =
  ## Convert microseconds to low-power clock cycles
  return (us * 100) div 3051

proc bflbip_wakeup*() {.exportc, cdecl.} =
  lld_sleep_wakeup()
  inc bflbip_sw_wakeup_cnt

proc bflbip_wakeup_end*() {.exportc, cdecl.} =
  lld_sleep_wakeup_end()

proc bflbip_wakeup_delay_set*(delay: uint32) {.exportc, cdecl.} =
  bflbip_wakeup_delay = delay

proc bflbip_wlcoex_set*(en: bool) {.exportc, cdecl.} =
  bflbip_wlcoex_cfg = if en: 1'u32 else: 0'u32
  lld_wlcoex_set(en)

proc bflbip_eif_get*(): pointer {.exportc, cdecl.} =
  ## Get external interface structure pointer
  return nil

# ---------------------------------------------------------------------------
# ======================== BLE CONTROLLER API ==============================
# ---------------------------------------------------------------------------

proc bdaddr_init*() {.exportc, cdecl.}
proc ble_controller_task_init*(cfg: pointer) {.exportc, cdecl.}
proc ecc_init*() {.exportc, cdecl.}

proc bleControllerInitInternal(cfg: pointer) =
  blePlatformInitMark(0x400'u32)
  when defined(bl808m0):
    nimDisableM0RfClicIrq()
    nimDisableM0BleClicIrq()
  bflbip_init()
  blePlatformInitMark(0x401'u32)
  ble_ke_init()
  blePlatformInitMark(0x402'u32)
  hci_init(false)
  blePlatformInitMark(0x403'u32)
  bflbble_init()
  blePlatformInitMark(0x404'u32)
  ecc_init()
  blePlatformInitMark(0x405'u32)
  lld_sleep_init()
  blePlatformInitMark(0x406'u32)
  lld_evt_init()
  blePlatformInitMark(0x407'u32)
  bdaddr_init()
  blePlatformInitMark(0x408'u32)
  ble_controller_task_init(cfg)
  blePlatformInitMark(0x409'u32)
  bflbble_enable_runtime_irqs()
  blePlatformInitMark(0x40E'u32)

proc ble_controller_init*(taskPriority: uint8) {.exportc, cdecl.} =
  ## Initialize the BLE controller.
  discard taskPriority
  bleControllerInitInternal(nil)

proc ble_controller_deinit*() {.exportc, cdecl.} =
  ## De-initialize the BLE controller
  ble_ke_flush()
  if ble_controller_task_handle != nil:
    ble_vTaskDelete(ble_controller_task_handle)
    ble_controller_task_handle = nil

proc ble_controller_task_init*(cfg: pointer) {.exportc, cdecl.} =
  ## Initialize the BLE controller task
  bflb_main_queue_handle = ble_xQueueCreate(20, 8)

proc ble_controller_get_lib_ver*(): cstring {.exportc, cdecl.} =
  return ble_controller_lib_ver

proc ble_controller_set_tx_pwr*(pwr: cint) {.exportc, cdecl.} =
  ble_tx_pwr = pwr.int8

proc ble_controller_get_tx_pwr*(): int8 {.exportc, cdecl.} =
  return ble_tx_pwr

proc ble_controller_set_debug_level*(level: uint32) {.exportc, cdecl.} =
  ble_debug_level = level

proc ble_controller_get_debug_level*(): uint32 {.exportc, cdecl.} =
  return ble_debug_level

proc ble_controller_set_scan_filter_table_size*(size: uint8): int8
    {.exportc, cdecl.} =
  ble_scan_filter_table_size = size
  0'i8

proc ble_controller_fix_scan_chan*(chan: uint8) {.exportc, cdecl.} =
  ble_scan_chan_fixed = chan

proc ble_controller_disable_adv_random_delay*(disable: bool)
    {.exportc, cdecl.} =
  ble_adv_random_delay_disabled = disable

proc ble_controller_notify_adv_discarded*(cb: proc(count: uint32) {.cdecl.}) {.exportc, cdecl.} =
  ble_adv_discarded_callback = cb

proc ble_controller_program_ongoing*(): bool {.exportc, cdecl.} =
  return ble_programming_ongoing != nil and ble_programming_ongoing[] != 0

proc ble_controller_sleep*(maxSleepCycles: int32): int32 {.exportc, cdecl.} =
  if bflbip_sleep():
    maxSleepCycles
  else:
    0'i32

proc ble_controller_wakeup*() {.exportc, cdecl.} =
  bflbip_wakeup()

proc ble_controller_sleep_restore*() {.exportc, cdecl.} =
  bflbip_wakeup_end()

proc ble_controller_sleep_is_ongoing*(): bool {.exportc, cdecl.} =
  false

proc ble_controller_update_adv_scan_aa*() {.exportc, cdecl.} =
  lld_update_adv_scan_aa()

proc coDjobAnyPending(): bool

proc bleEventPendingWork(): bool {.inline.} =
  ble_ke_event_get_all() != 0'u32

proc bleMessagePendingWork(): bool {.inline.} =
  ke_msg_queue.first != nil

proc bleMessageEventPending(): bool {.inline.} =
  (ble_ke_event_get_all() and BleKeMessageEventBit) != 0

proc bleHiddenMessagePendingWork(): bool {.inline.} =
  bleMessagePendingWork() and not bleMessageEventPending()

proc bleMainQueuePendingWork(): bool {.inline.} =
  bleQueuePending(bflb_main_queue_handle)

proc bleDrainKernelEvents(): bool {.inline.} =
  if not bleEventPendingWork():
    return false
  ble_ke_event_schedule()
  true

proc bleControllerHasPendingWork(): bool =
  result = bleHciResetSettlePending() or bleEventPendingWork() or bleKeTimerPendingWork() or
    bleMessagePendingWork() or bleMainQueuePendingWork() or
    coDjobAnyPending()
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    result = result or nimArbCallbackPending()

proc bleDrainMainQueueMessage(): bool =
  if bflb_main_queue_handle == nil:
    return false
  var mainQueueMessage: array[8, uint8]
  let receiveStatus = ble_xQueueReceive(bflb_main_queue_handle, addr mainQueueMessage[0], 0)
  if receiveStatus != 1 or mainQueueMessage[0] != 1:
    return false
  let queuedPayload = cast[pointer](cast[ptr uint32](addr mainQueueMessage[4])[])
  if queuedPayload != nil:
    let hdr = getMsgHeader(queuedPayload)
    ble_ke_msg_free(hdr)
  true

proc bleDrainScheduledWork(): bool =
  if bleHciResetSettlePending():
    inc nim_ble_hci_reset_settle_yield_count
    return true
  if bleKeTimerPendingWork():
    result = true
    ble_ke_timer_schedule()
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nimArbCallbackPending():
      result = true
      serviceNimArbCallbacks()
  if bleDrainKernelEvents():
    result = true
  if bleHiddenMessagePendingWork():
    result = true
    ble_ke_task_schedule()

proc bleControllerServiceStep(blockWhenIdle = false): bool =
  ## Service one BLE controller scheduler turn. The pure Nim queue receive path
  ## is nonblocking, so CPS callers can use this without pinning the scheduler.
  result = bleControllerHasPendingWork()
  if bleDrainMainQueueMessage():
    result = true
  if bleDrainScheduledWork():
    result = true
  if blockWhenIdle and not result:
    discard bflbip_sleep()
    result = bleControllerHasPendingWork()

proc bleControllerServiceNonblocking(): bool =
  bleControllerServiceStep()

proc bleControllerServiceBlockingIdle(): bool =
  bleControllerServiceStep(blockWhenIdle = true)

proc blecontroller_service_step*(blockWhenIdle: uint8 = 0'u8) {.exportc, cdecl.} =
  discard bleControllerServiceStep(blockWhenIdle != 0'u8)

proc blecontroller_poll_once*() {.exportc, cdecl.} =
  discard bleControllerServiceNonblocking()

proc blecontroller_main*() {.exportc, cdecl.} =
  ## Main BLE controller loop
  while true:
    discard bleControllerServiceBlockingIdle()

# ---------------------------------------------------------------------------
# ======================== BLE_DBG / ASSERT ================================
# ---------------------------------------------------------------------------

proc ble_assert_err*(file: cstring, line: uint32) {.exportc, cdecl.} =
  ## Fatal assertion
  discard

proc ble_assert_param*(a0: uint32, a1: uint32, a2: cstring, a3: uint32) {.exportc, cdecl.} =
  discard

proc ble_assert_warn*(file: cstring, line: uint32) {.exportc, cdecl.} =
  ## Non-fatal warning assertion
  discard

proc ble_dbg_platform_reset_complete*(status: uint32) {.exportc, cdecl.} =
  discard

proc ble_fur_debug_info*() {.exportc, cdecl.} =
  discard

proc ble_get_deep_sleep_stat*(): uint32 {.exportc, cdecl.} =
  return ble_deep_sleep_stat

proc dump_data*(data: pointer, len: uint32) {.exportc, cdecl.} =
  ## Debug data dump (no-op in production)
  discard

proc coex_dump_ble*(buf: pointer, len: uint32) {.exportc, cdecl.} =
  discard

# ---------------------------------------------------------------------------
# ======================== PLATFORM ========================================
# ---------------------------------------------------------------------------

proc platform_reset*(reason: uint32) {.exportc, cdecl.} =
  ## Platform reset handler
  ## From disasm: disables interrupts, then checks for magic values
  discard disableInterrupts()
  if reason == 0xC3C3C3C3'u32 or reason == 0xA5A5A5A5'u32:
    return  # Soft reset already handled
  # Hard reset: jump to address 0
  discard

proc BLE_ROM_patch*() {.exportc, cdecl.} =
  ## Apply ROM patches - sets up patch function pointer(s)
  discard

proc BLE_ROM_hook_init*() {.exportc, cdecl.} =
  ## Initialize ROM hook function pointer(s)
  ## From disasm: stores a sequence of function pointer(s)
  discard

proc get_stack_usage*(): uint16 {.exportc, cdecl.} =
  ## Calculate stack usage by scanning for sentinel byte 0xBB
  return 0

# ---------------------------------------------------------------------------
# ======================== BFLB_MAIN =======================================
# ---------------------------------------------------------------------------

proc bflb_main_task_post*(fn: pointer, arg: pointer): bool {.exportc, cdecl.} =
  if fn == nil:
    return false
  if bflb_main_queue_handle == nil:
    return false
  var msg: array[3, uint32]
  msg[0] = 1  # message type
  msg[1] = cast[uint32](fn)
  msg[2] = cast[uint32](arg)
  let sendStatus = ble_xQueueSend(bflb_main_queue_handle, addr msg[0], 0)
  return sendStatus == 1

proc bflb_main_task_post_from_fw*(fn: pointer, arg: pointer) {.exportc, cdecl.} =
  ## Post task from firmware context
  var msg_buf: array[8, uint8]
  msg_buf[0] = 2  # type = firmware post
  if bflb_main_queue_handle != nil:
    var woken: uint32 = 0
    discard ble_xQueueSendFromISR(bflb_main_queue_handle, addr msg_buf[0], addr woken)
    if woken == 1:
      ble_portYIELD_FROM_ISR()
  else:
    discard

proc bflb_main_task_post_from_isr*(fn: pointer, arg: pointer) {.exportc, cdecl.} =
  ## Post task from ISR context
  var msg_buf: array[8, uint8]
  msg_buf[0] = 2  # type
  if bflb_main_queue_handle != nil:
    var woken: uint32 = 0
    discard ble_xQueueSendFromISR(bflb_main_queue_handle, addr msg_buf[0], addr woken)
    if woken == 1:
      ble_portYIELD_FROM_ISR()

proc bflb_main_check_task_valid*(): bool {.exportc, cdecl.} =
  return ble_controller_task_handle != nil

proc bflb_main_get_task_priority*(): uint8 {.exportc, cdecl.} =
  if ble_controller_task_handle == nil:
    return 0
  return uint8(ble_uxTaskPriorityGet(ble_controller_task_handle) and 0xFF)

# ---------------------------------------------------------------------------
# ======================== BDADDR / MAC ====================================
# ---------------------------------------------------------------------------

proc bl_read_mac_addr*(mac: ptr uint8) {.exportc, cdecl.} =
  ## Read MAC address from eFuse
  let efuseMacLowWord = regRead(0x40007014'u)
  let efuseMacHighWord = regRead(0x40007018'u)
  let macBytes = cast[ptr UncheckedArray[uint8]](mac)
  for lowWordByteIndex in 0 ..< 4:
    macBytes[lowWordByteIndex] =
      uint8((efuseMacLowWord shr (lowWordByteIndex * 8)) and 0xFF'u32)
  for highWordByteIndex in 0 ..< 2:
    macBytes[4 + highWordByteIndex] =
      uint8((efuseMacHighWord shr (highWordByteIndex * 8)) and 0xFF'u32)
  # Check if all zero or all 0x01 => use default
  var efuseMacAllZero = true
  var efuseMacAllOnesSentinel = true
  for macByteIndex in 0 ..< 6:
    let macByte = macBytes[macByteIndex]
    if macByte != 0:
      efuseMacAllZero = false
    if macByte != 1:
      efuseMacAllOnesSentinel = false
  if efuseMacAllZero or efuseMacAllOnesSentinel:
    # Use default MAC
    let fallbackBleMac = [0xC0'u8, 0x01, 0x02, 0x03, 0x04, 0x05]
    discard c_memcpy(mac, unsafeAddr fallbackBleMac[0], 6)

proc bdaddr_init*() {.exportc, cdecl.} =
  ## Initialize BD address from stored/eFuse MAC
  var publicAddress: BdAddr
  bl_read_mac_addr(addr publicAddress.bytes[0])
  # Increment first byte by 1 as the BLE address
  publicAddress.bytes[0] = publicAddress.bytes[0] + 1
  llm_util_set_public_addr(addr publicAddress)

# ---------------------------------------------------------------------------
# ======================== BLE RF ==========================================
# ---------------------------------------------------------------------------

proc ble_rf_init*() {.exportc, cdecl.} =
  rf_pwr_offset = 0
  rf_pwr_max = 0

proc ble_rf_set_pwr_offset_table*(table: ptr int8) {.exportc, cdecl.} =
  rf_pwr_offset_table = table

proc ble_rf_get_pwr_offset*(channel: uint8): int8 {.exportc, cdecl.} =
  if rf_pwr_offset_table != nil and channel < 40:
    return cast[ptr UncheckedArray[int8]](rf_pwr_offset_table)[channel]
  return 0

proc ble_rf_set_tx_channel*(channel: uint16) {.exportc, cdecl.} =
  configureBleRfChannelMhz(bleRfChannelMhz(channel))

proc bl_channel_calc_threshold*(ch_assess: pointer, threshold: ptr int8): uint8 {.exportc, cdecl.} =
  return 0

# ---------------------------------------------------------------------------
# ======================== ON-CHIP HCI =====================================
# ---------------------------------------------------------------------------

proc bt_onchiphci_interface_init*(cb: OnChipHciRecvCb): uint8 {.exportc, cdecl.} =
  discard c_memset(addr onchiphci_env[0], 0, sizeof(onchiphci_env).csize_t)
  onchiphci_recv_cb = cb
  nim_hci_debug_stage = 0x4200'u32
  nim_hci_debug_cb = cast[uint32](cast[uint](cb))
  0

proc handleOnchipHciCommandBuffer(data: pointer, len: uint16): uint8 =
  nim_hci_debug_stage = 0x4300'u32
  nim_hci_debug_len = len.uint32
  if data == nil or len < 3:
    return 0x12'u8
  let opcode = hciRawOpcode(data)
  let paramLen = hciRawParamLen(data)
  nim_hci_debug_stage = 0x4310'u32
  nim_hci_debug_opcode = opcode.uint32
  nim_hci_debug_len = paramLen.uint32
  if len < uint16(paramLen.int + 3):
    return 0x12'u8
  let params =
    if paramLen == 0: nil
    else: hciRawParams(data)
  let status = completeHciCommand(opcode, params, paramLen)
  nim_hci_debug_stage = 0x4320'u32
  nim_hci_debug_status = status.uint32
  when defined(bl808m0):
    bleCentralDebugMark(0x910'u32, (uint32(opcode) shl 8) or uint32(status))
  status

proc bt_onchiphci_send_raw*(data: pointer, len: uint16): bool =
  nim_hci_debug_stage = 0x4400'u32
  nim_hci_debug_len = len.uint32
  bleCentralDebugMark(0x920'u32, uint32(len))
  let ok = handleOnchipHciCommandBuffer(data, len) == 0
  nim_hci_debug_stage = 0x4410'u32
  nim_hci_debug_status = if ok: 0'u32 else: 1'u32
  when defined(bl808m0):
    bleCentralDebugMark(0x921'u32, if ok: 1'u32 else: 0'u32)
  ok

proc bt_onchiphci_send*(pktType: uint8, destId: uint16,
                        pkt: pointer): int8 {.exportc, cdecl.} =
  discard destId
  if pkt == nil:
    return -1'i8
  case pktType
  of BtHciCmd:
    let cmd = cast[ptr OnChipHciCmd](pkt)
    discard completeHciCommand(cmd.opcode, cmd.params, cmd.paramLen)
    return 0'i8
  of BtHciAclData:
    let acl = cast[ptr OnChipHciAclDataTx](pkt)
    let status = hciAclTxDataStatus(acl.conhdl, acl.pbBcFlag,
                                    acl.buffer, acl.len)
    return if status == HciStatusSuccess: 0'i8 else: -1'i8
  else:
    return -1'i8

proc bt_onchiphci_send_buffer*(data: pointer, len: uint16): bool {.cdecl.} =
  if data == nil or len < 3:
    return false
  handleOnchipHciCommandBuffer(data, len) == 0

proc bt_onchiphci_handle_rx_acl*(param: pointer, hostBufData: ptr uint8): uint8
    {.exportc, cdecl.} =
  discard param
  discard hostBufData
  0

# ---------------------------------------------------------------------------
# ======================== ECC CRYPTO ======================================
# ---------------------------------------------------------------------------

proc eccGenerateSecretKey(secret: ptr uint8): bool =
  bleP256Mark(0x00000100'u32)
  if secret == nil:
    bleP256Mark(0x00000101'u32)
    return false
  var tries = 32
  while tries > 0:
    bleP256Mark(0x00000110'u32)
    if not bleFillRandomBytes(secret, ECC_KEY_LEN):
      discard c_memset(secret, 0, ECC_KEY_LEN.csize_t)
      bleP256Mark(0x00000111'u32)
      return false
    bleP256Mark(0x00000120'u32)
    if bleP256IsValidScalarLe(secret):
      discard c_memcpy(addr ecc_private_key[0], secret, ECC_KEY_LEN.csize_t)
      bleP256Mark(0x00000130'u32)
      return true
    dec tries
  discard c_memset(secret, 0, ECC_KEY_LEN.csize_t)
  bleP256Mark(0x000001FF'u32)
  false

proc p256ControllerScalarMultLe(secret, pointX, pointY, outX, outY: ptr uint8): bool =
  bleP256ScalarMultLe(secret, pointX, pointY, outX, outY)

proc p256ControllerBaseMultLe(secret, outX, outY: ptr uint8): bool =
  bleP256ScalarBaseMultLe(secret, outX, outY)

proc ecc_init*() {.exportc, cdecl.} =
  discard c_memset(addr ecc_env[0], 0, sizeof(ecc_env).csize_t)
  discard c_memset(addr ecc_private_key[0], 0, ECC_KEY_LEN.csize_t)
  ecc_ongoing = false

proc ecc_is_valid_point*(point: ptr EccPoint256): bool {.exportc, cdecl.} =
  if point == nil:
    return false
  bleP256IsValidPublicKeyLe(addr point.x[0], addr point.y[0])

proc ecc_generate_key256*(op: uint32, secret: ptr uint8, pointX: ptr uint8,
                          pointY: ptr uint8, publicKey: ptr EccPoint256,
                          resultCb: pointer) {.exportc, cdecl.} =
  discard op
  discard resultCb
  ecc_ongoing = true
  if secret == nil or publicKey == nil:
    ecc_ongoing = false
    return
  let ok =
    if pointX == nil or pointY == nil:
      p256ControllerBaseMultLe(secret, addr publicKey.x[0], addr publicKey.y[0])
    else:
      p256ControllerScalarMultLe(secret, pointX, pointY, addr publicKey.x[0],
                                 addr publicKey.y[0])
  if ok:
    discard c_memcpy(addr ecc_private_key[0], secret, ECC_KEY_LEN.csize_t)
  else:
    discard c_memset(publicKey, 0, sizeof(EccPoint256).csize_t)
  ecc_ongoing = false

proc ecc_abort_key256_generation*() {.exportc, cdecl.} =
  ecc_ongoing = false

proc ecc_gen_new_public_key*(secret: ptr uint8, public_key: ptr EccPoint256) {.exportc, cdecl.} =
  if secret == nil or public_key == nil:
    return
  if p256ControllerBaseMultLe(secret, addr public_key.x[0], addr public_key.y[0]):
    discard c_memcpy(addr ecc_private_key[0], secret, ECC_KEY_LEN.csize_t)
  else:
    discard c_memset(public_key, 0, sizeof(EccPoint256).csize_t)

proc ecc_gen_new_secret_key*(secret: ptr uint8) {.exportc, cdecl.} =
  discard eccGenerateSecretKey(secret)

proc ecc_get_debug_Keys*(secret: ptr uint8, public_key: ptr EccPoint256) {.exportc, cdecl.} =
  if secret != nil:
    discard c_memcpy(secret, unsafeAddr BleP256DebugPrivateKeyLe[0],
                     ECC_KEY_LEN.csize_t)
    discard c_memcpy(addr ecc_private_key[0], secret, ECC_KEY_LEN.csize_t)
  if public_key != nil:
    discard c_memcpy(addr public_key.x[0], unsafeAddr BleP256DebugPublicKeyXLe[0],
                     ECC_KEY_LEN.csize_t)
    discard c_memcpy(addr public_key.y[0], unsafeAddr BleP256DebugPublicKeyYLe[0],
                     ECC_KEY_LEN.csize_t)

proc ecc_get_private_key*(key: ptr uint8) {.exportc, cdecl.} =
  if key != nil:
    discard c_memcpy(key, addr ecc_private_key[0], ECC_KEY_LEN.csize_t)

proc notEqual256*(a: ptr uint8, b: ptr uint8): bool {.exportc, cdecl.} =
  return c_memcmp(a, b, ECC_KEY_LEN.csize_t) != 0

proc bigHexInversion256*(input: ptr uint8, output: ptr uint8) {.exportc, cdecl.} =
  if not bleP256InverseFieldLe(input, output) and output != nil:
    discard c_memset(output, 0, ECC_KEY_LEN.csize_t)

proc GF_Point_Jacobian_To_Affine256*(point: ptr uint8) {.exportc, cdecl.} =
  ## Convert Jacobian to Affine coordinates
  bleP256JacobianToAffineInPlace(point)

# ---------------------------------------------------------------------------
