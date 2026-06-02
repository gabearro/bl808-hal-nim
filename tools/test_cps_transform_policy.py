from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_cps_transform_supports_when_await_dispatch():
    transform = (ROOT / "src/bl808/kernel/transform.nim").read_text()
    assert "skWhenDispatch" in transform
    assert "s.kind == nnkWhenStmt and hasNestedAwait(s)" in transform
    assert "nnkWhenStmt.newTree()" in transform


def test_cps_transform_treats_underscore_await_binding_as_discard():
    transform = (ROOT / "src/bl808/kernel/transform.nim").read_text()
    assert "proc awaitTargetName" in transform
    assert 'if result == "_":' in transform
    assert 'result = ""' in transform


def test_runtime_can_read_completed_void_future_for_typed_cps_awaits():
    runtime = (ROOT / "src/bl808/kernel/runtime.nim").read_text()
    assert "proc read*(fut: CpsVoidFuture)" in runtime
    assert "raise fut.error" in runtime


def test_scheduler_timer_heap_does_not_copy_closure_entries():
    sched = (ROOT / "src/bl808/kernel/sched.nim").read_text()
    assert "TimerEntryObj = object" in sched
    assert "TimerEntry = ptr TimerEntryObj" in sched
    assert "MaxSchedulerTimers*" in sched
    assert "callback: proc() {.closure.}" in sched
    assert "proc releaseTimerEntry(entry: TimerEntry)" in sched
    assert "SchedulerTimedPollHook*" in sched
    assert "proc addSchedulerTimedPollHook*" in sched
    assert "proc hasUntimedPollHooks()" in sched
    assert "proc hasDueTimedPollHooks(now: uint64)" in sched
    assert "not hasUntimedPollHooks()" in sched


def test_ble_wifi_mixed_example_uses_cps_service_tasks():
    example = (ROOT / "examples/m0_ble_wifi_hal_test.nim").read_text()
    assert "proc mainWorkflow(): CpsVoidFuture {.cps.}" in example
    assert "discard bleHostServiceTask(BlePollDelayUs.uint32, BlePollIterations.uint32)" in example
    assert "wifiInstallServiceHook()" in example
    assert "wifiConfigureServiceHook(WifiBleCoexServicePeriodUs.uint32" in example
    assert "bleInstallHostServiceHook(BlePollDelayUs.uint32, BlePollIterations.uint32)" in example
    assert "runScheduler()" in example


def test_ble_wifi_coexistence_mode_keeps_sta_connected_during_ble():
    example = (ROOT / "examples/m0_ble_wifi_hal_test.nim").read_text()
    assert "WifiBleSimultaneous {.booldefine.} = false" in example
    assert "check(\"wifi still connected before ble\", wifiStaAssociated())" in example
    assert "check(\"wifi still connected during ble advertising\", wifiStaAssociated())" in example
    assert "check(\"wifi still connected after ble\", wifiStaAssociated())" in example

    simultaneous_wifi = example.split("when WifiBleSimultaneous:", 1)[1].split(
        "when defined(WifiTransitionDiag):", 1
    )[0]
    assert "return" in simultaneous_wifi
    assert "wifiDisconnectAsync" not in simultaneous_wifi


def test_hardware_manifest_has_active_ble_wifi_coex_test():
    manifest = (ROOT / "tools/hardware_validation.json").read_text()
    assert '"name": "m0_ble_wifi_nim_coex_hal_test"' in manifest
    assert '"name": "m0_ble_wifi_nim_coex_long_hal_test"' in manifest
    assert '"WifiBleSimultaneous": "1"' in manifest
    assert '"[PASS] wifi still connected during ble advertising"' in manifest
    assert '"[PASS] wifi still connected after ble"' in manifest
    assert '"[PASS] wifi tx during ble connection"' in manifest
    assert '"mdw {sym:nimfw_dbg_nullframe_ack_ok} 1"' in manifest
    assert '"mdw {sym:nimfw_dbg_nullframe_ack_fail} 1"' in manifest


def test_mixed_ble_wifi_harness_has_no_vendor_path_branches():
    harness = (ROOT / "examples/m0_ble_wifi_hal_test.nim").read_text()
    assert "bl808BleVendor" not in harness
    assert "bl808WifiVendor" not in harness
    assert "bleblob" not in harness
    assert "when defined(bl808WifiNimFw)" not in harness
    assert "when not defined(bl808WifiNimFw)" not in harness


def test_wifi_async_lifecycle_uses_event_futures_not_poll_loops():
    wifi = (ROOT / "src/bl808/wifi.nim").read_text()
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    wifi_support = (ROOT / "src/bl808/wifi_support.nim").read_text()
    assert "wifiCompletePendingEvents()" in wifi
    assert "proc wifiInstallServiceHook*" in wifi
    assert "proc wifiConfigureServiceHook*" in wifi
    assert "proc wifiSetBleCoexistenceMode*" in wifi
    assert "proc wifiStaKeepaliveAckOkCount*" in wifi
    assert "addSchedulerTimedPollHook(wifiServicePollHook, readTick())" in wifi
    assert "wifiScanFuture = newLocalCpsFuture[uint32]()" in wifi
    assert "wifiConnectFuture = newLocalCpsFuture[WifiError]()" in wifi
    assert "wifiDisconnectFuture = newLocalCpsFuture[WifiError]()" in wifi
    assert "proc wifi_main_service_step*" in wifi_fw
    assert "proc wifi_main_poll_once*" in wifi_fw
    assert "WifiMainServiceMode = enum" in wifi_fw
    assert "wifiServiceNonblocking" in wifi_fw
    assert "wifiServiceBlockingIdle" in wifi_fw
    assert "proc wifiMainServiceStep(mode: WifiMainServiceMode): bool" in wifi_fw
    assert "proc wifiMainHasPendingWork(): bool" in wifi_fw
    assert "proc wifiMainModeFromAbi(blockWhenIdle: uint8): WifiMainServiceMode" in wifi_fw
    assert "wifiMainModeFromAbi(blockWhenIdle)" in wifi_fw
    assert "keEvtField != 0" in wifi_fw
    assert "result = wifiMainHasPendingWork()" in wifi_fw
    assert "KeTaskInitSpec = object" in wifi_fw
    assert "let taskSpecs = [" in wifi_fw
    assert "for spec in taskSpecs:" in wifi_fw
    assert "if mode == wifiServiceBlockingIdle and not result:" in wifi_fw
    assert "wifiMainServiceStep(wifiServiceBlockingIdle)" in wifi_fw
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()
    assert "proc blecontroller_service_step*" in ble
    assert "proc blecontroller_poll_once*" in ble
    assert "BleControllerServiceMode = enum" in ble
    assert "bleServiceNonblocking" in ble
    assert "bleServiceMainLoop" in ble
    assert "proc bleControllerServiceStep(mode: BleControllerServiceMode): bool" in ble
    assert "proc bleControllerHasPendingWork(): bool" in ble
    assert "proc bleControllerModeFromAbi(blockWhenIdle: uint8): BleControllerServiceMode" in ble
    assert "bleControllerModeFromAbi(blockWhenIdle)" in ble
    assert "ble_ke_event_get_all() != 0'u32" in ble
    assert "result = bleControllerHasPendingWork()" in ble
    assert "bleControllerServiceStep(bleServiceNonblocking)" in ble
    assert "bleControllerServiceStep(bleServiceMainLoop)" in ble
    ble_step = ble.split("proc bleControllerServiceStep", 1)[1].split(
        "proc blecontroller_service_step*", 1
    )[0]
    assert "ble_xQueueReceive(bflb_main_queue_handle, addr msg_buf[0], 0)" in ble_step
    assert "high(uint32)" not in ble_step
    assert "while true:" not in ble_step
    assert "proc wifi_main_poll_once() {.importc, cdecl.}" in wifi_support
    poll_once_body = wifi_support.split("proc vendorPollOnce()", 1)[1].split(
        "proc vendorPollFor", 1
    )[0]
    assert "wifi_main_poll_once()" in poll_once_body
    assert "ipc_emb_wait()" not in poll_once_body

    scan_body = wifi.split("proc wifiScanAsync*", 1)[1].split(
        "proc wifiConnect*", 1
    )[0]
    connect_body = wifi.split("proc wifiConnectAsync*", 1)[1].split(
        "when defined(bl808WifiNimFw) and defined(bl808WifiNimFwDiag)", 1
    )[0]
    disconnect_body = wifi.split("proc wifiDisconnectAsync*", 1)[1].split(
        "proc wifiStartAp*", 1
    )[0]
    for body in (scan_body, connect_body, disconnect_body):
        assert "await sleep" not in body
        assert "while waited <" not in body


def test_wifi_firmware_hardware_waits_are_bounded_for_cps_runtime():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    assert "WifiHwPollLimit = 100_000'u32" in wifi_fw
    assert "nimfw_dbg_hw_wait_timeout_count" in wifi_fw
    assert "proc waitRegMaskClear" in wifi_fw
    assert "proc waitRegMaskSet" in wifi_fw
    assert "proc waitRegLowNibbleClear" in wifi_fw
    assert "proc waitRegLowNibbleEquals" in wifi_fw
    assert "proc waitMacSoftResetClear" in wifi_fw

    hal_body = wifi_fw.split("proc hal_machw_init*", 1)[1].split(
        "proc hal_machw_idle_req*", 1
    )[0]
    sec_body = wifi_fw.split(
        "proc mm_sec_machwaddr_wr*(vifIdx: uint8, addr_ptr: pointer, idx: uint8): uint8 {.exportc, cdecl, discardable.} =",
        1,
    )[1].split(
        "proc mm_sec_macrx_ind*", 1
    )[0]
    key_get_body = wifi_fw.split("proc mm_sec_machwkey_get*", 1)[1].split(
        "proc mm_sec_keydump*", 1
    )[0]
    ps_body = wifi_fw.split("proc wait_mac_goto_prestate*", 1)[1].split(
        "proc ps_disable_cfm_handle*", 1
    )[0]
    idle_body = wifi_fw.split("proc wait_mac_goto_idle*", 1)[1].split(
        "proc wait_mac_goto_prestate*", 1
    )[0]
    wakeup_body = wifi_fw.split("proc wakeup_from_doze_pre*", 1)[1].split(
        "proc ps_disable_cfm_handle*", 1
    )[0]
    search_body = wifi_fw.split("proc hal_machw_search_addr*", 1)[1].split(
        "proc hal_machw_monitor_mode*", 1
    )[0]
    duration_body = wifi_fw.split(
        "proc hal_machw_rx_duration*", 1
    )[1].split("proc element_notify_status_enabled*", 1)[0]
    halt_ac_body = wifi_fw.split(
        "proc txl_cntrl_halt_ac*(ac: uint8) {.exportc, cdecl.} =",
        1,
    )[1].split("proc txl_cntrl_flush_ac*", 1)[0]

    assert hal_body.count("waitMacSoftResetClear()") >= 2
    assert "waitRegLowNibbleClear(MACHW_STATE_CNTRL_REG)" in hal_body
    assert "waitRegMaskClear(KEY_CTRL, 0x40000000'u32)" in sec_body
    assert "waitRegMaskClear(KEY_CTRL, 0x80000000'u32)" in key_get_body
    assert "waitRegLowNibbleEquals(MACHW_STATE_CNTRL_REG" in ps_body
    assert "waitRegLowNibbleClear(MACHW_STATE_CNTRL_REG)" in ps_body
    assert "while (status and 0x04'u32) == 0 and macTimeNow() - startTime < timeout:" in idle_body
    assert "while true:" not in idle_body
    assert "while (status and 0x04'u32) == 0 and macTimeNow() - startTime < timeout:" in wakeup_body
    assert "while true:" not in wakeup_body
    assert "waitRegMaskClear(MACHW_BASE + 0x0C4'u, 0x20000000'u32)" in search_body
    assert "return 0xFF'u32" in search_body
    assert "waitRegMaskSet(MACHW_INTC_BASE + 0x168'u, 0x40000'u32)" in duration_body
    assert "return 500" in duration_body
    assert "while (regRead(MACHW_INTC_BASE + 0x168'u)" not in duration_body
    for mask in [
        "0x10000'u32",
        "0x20000'u32",
        "0x40000'u32",
        "0x80000'u32",
        "0x03'u32",
    ]:
        assert f"waitRegMaskClear(MACHW_TX_TRIG_STAT, {mask})" in halt_ac_body
    assert "while true:" not in halt_ac_body


def test_wifi_tx_descriptor_update_does_not_hard_trap_cps_runtime():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    thd_body = wifi_fw.split("proc txl_buffer_update_thd*", 1)[1].split(
        "proc txl_cfm_init*", 1
    )[0]

    assert "nimfw_dbg_tx_thd_nobuf" in wifi_fw
    assert "nimfw_dbg_tx_thd_nobuf_desc" in wifi_fw
    assert "while true: discard" not in thd_body
    assert "inc nimFwDbgTxThdNoBuffer" in thd_body
    assert "nimFwDbgTxThdNoBufferDesc = pointerAddrU32(param)" in thd_body
    assert "hwDesc.status = 0" in thd_body
    assert "hwDesc.controlFlags = 0" in thd_body
    assert "return" in thd_body


def test_wifi_apm_sta_add_confirm_does_not_trap_scheduler():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    apm_body = wifi_fw.split("proc apm_sta_add_cfm_handler*", 1)[1].split(
        "{.emit: \"__attribute__((optimize(\\\"crossjumping\\\"))) void apm_sta_del_req_handler",
        1,
    )[0]

    assert "nimfw_dbg_apm_sta_add_noslot" in wifi_fw
    assert "nimfw_dbg_apm_sta_add_noslot_sta" in wifi_fw
    assert "sb zero" not in apm_body
    assert "ebreak" not in apm_body
    assert "assert_err" not in apm_body
    assert "inc nimFwDbgApmStaAddNoSlot" in apm_body
    assert "nimFwDbgApmStaAddNoSlotSta = staIdx.uint32" in apm_body


def test_wifi_assert_err_requests_reset_without_blocking_scheduler():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    assert_body = wifi_fw.split(
        "proc assert_err*(cond: cstring, file: cstring, line: cint) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc assert_rec*", 1
    )[0]

    assert "nimfw_dbg_assert_err_count" in wifi_fw
    assert "nimfw_dbg_assert_err_last_line" in wifi_fw
    assert "nimfw_dbg_assert_err_last_file" in wifi_fw
    assert "proc noteAssertErr" in wifi_fw
    assert "noteAssertErr(file, line)" in assert_body
    assert "while true:" not in assert_body
    assert "discard  # Hang on fatal error" not in assert_body
    assert "hal_machw_disable_int()" in assert_body
    assert "ke_evt_set(0x80000000'u32)" in assert_body


def test_wifi_tx_confirm_event_yields_under_backlog():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    cfm_body = wifi_fw.split(
        "proc txl_cfm_evt*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_cfm_flush*", 1
    )[0]

    assert "WifiTxCfmDrainLimit = 16'u32" in wifi_fw
    assert "nimfw_dbg_cfm_evt_yield" in wifi_fw
    assert "nimfw_dbg_cfm_evt_yield_ac" in wifi_fw
    assert "proc txlCfmPending(acList: ptr CoList): bool" in wifi_fw
    assert "var drained = 0'u32" in cfm_body
    assert "while drained < WifiTxCfmDrainLimit and txlCfmPending(acList):" in cfm_body
    assert "while true:" not in cfm_body
    assert "inc drained" in cfm_body
    assert "if txlCfmPending(acList):" in cfm_body
    assert "inc nimFwDbgCfmEvtYield" in cfm_body
    assert "nimFwDbgCfmEvtYieldAc = acIdx" in cfm_body
    assert "ke_evt_set(evtField)" in cfm_body


def test_wifi_tx_confirm_flush_uses_explicit_list_drain_condition():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    flush_body = wifi_fw.split(
        "proc txl_cfm_flush*() {.exportc, cdecl, noinline.} =",
        1,
    )[1].split(
        "proc txl_cfm_flush_desc*",
        1,
    )[0]

    assert "while cfmList.first != nil:" in flush_body
    assert "while true:" not in flush_body
    assert "txl_frame_evt()" in flush_body
    assert "ipc_emb_txcfm_ind(1'u32 shl acIdx)" in flush_body


def test_wifi_tx_trigger_yields_under_descriptor_backlog():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    trigger_body = wifi_fw.split(
        "proc txl_transmit_trigger*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_current_desc_get*", 1
    )[0]

    assert "WifiTxTriggerDrainLimit = 16'u32" in wifi_fw
    assert "nimfw_dbg_txtrig_yield" in wifi_fw
    assert "nimfw_dbg_txtrig_yield_ac" in wifi_fw
    assert "nimfw_dbg_txtrig_yield_head" in wifi_fw
    assert "proc txlTriggerPending(acCtrl: ptr TxControlAcView): bool" in wifi_fw
    assert "var drained = 0'u32" in trigger_body
    assert "while drained < WifiTxTriggerDrainLimit:" in trigger_body
    assert "while true:" not in trigger_body
    assert "inc drained" in trigger_body
    assert "if txlTriggerPending(acCtrl):" in trigger_body
    assert "inc nimFwDbgTxTrigYield" in trigger_body
    assert "nimFwDbgTxTrigYieldAc = ac" in trigger_body
    assert "nimFwDbgTxTrigYieldHead = pointerAddrU32(cast[pointer](acCtrl.pending.first))" in trigger_body
    assert "blmac_abs_timer_set(ac, ipcBase + TX_TIMEOUT_LOCAL[ac])" in trigger_body
    yield_body = trigger_body.split("if txlTriggerPending(acCtrl):", 1)[1]
    assert "regWrite(MACHW_TX_TRIG_STAT" not in yield_body


def test_wifi_tx_frame_event_yields_under_backlog():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    frame_body = wifi_fw.split(
        "proc txl_frame_evt*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_frame_send_null_frame*", 1
    )[0]

    assert "WifiTxFrameDrainLimit = 16'u32" in wifi_fw
    assert "nimfw_dbg_frame_evt_yield" in wifi_fw
    assert "nimfw_dbg_frame_evt_yield_head" in wifi_fw
    assert "proc txlFrameConfirmPending(frameEnv: ptr TxFrameEnvView): bool" in wifi_fw
    assert "var drained = 0'u32" in frame_body
    assert "while drained < WifiTxFrameDrainLimit and txlFrameConfirmPending(frameEnv):" in frame_body
    assert "while true:" not in frame_body
    assert "if txlFrameConfirmPending(frameEnv):" in frame_body
    assert "inc nimFwDbgFrameEvtYield" in frame_body
    assert "nimFwDbgFrameEvtYieldHead =" in frame_body
    assert "ke_evt_set(0x00080000'u32)" in frame_body
    assert "inc drained" in frame_body
    retry_body = frame_body.split("if desc.retryFlag != 0:", 1)[1].split(
        "continue  # re-process", 1
    )[0]
    assert "inc drained" in retry_body


def test_wifi_tx_frame_get_uses_explicit_retry_condition():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    get_body = wifi_fw.split(
        "proc txl_frame_get*(length: uint32): pointer {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_frame_push*",
        1,
    )[0]

    assert "var retryAllocation = true" in get_body
    assert "while retryAllocation:" in get_body
    assert "retryAllocation = false" in get_body
    assert "retryAllocation = true" in get_body
    assert "while true:" not in get_body
    assert "return cast[pointer](freeNode)" in get_body
    assert get_body.rstrip().endswith("nil")


def test_wifi_rx_timer_handler_yields_under_descriptor_backlog():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    rx_body = wifi_fw.split(
        "proc rxl_timer_int_handler*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rxl_timeout_int_handler*", 1
    )[0]

    assert "WifiRxTimerDrainLimit = 16'u32" in wifi_fw
    assert "nimfw_dbg_rx_timer_yield" in wifi_fw
    assert "nimfw_dbg_rx_timer_yield_head" in wifi_fw
    assert "proc submittedRxReady(desc: pointer): bool" in wifi_fw
    assert "var drained = 0'u32" in rx_body
    assert "template scheduleQueuedRx()" in rx_body
    assert "while drained < WifiRxTimerDrainLimit and submittedRxReady(env.submittedHead):" in rx_body
    assert "while true:" not in rx_body
    assert "if submittedRxReady(env.submittedHead):" in rx_body
    assert "inc nimFwDbgRxTimerYield" in rx_body
    assert "nimFwDbgRxTimerYieldHead = pointerAddrU32(env.submittedHead)" in rx_body
    assert "scheduleQueuedRx()" in rx_body
    assert "regWrite(0x24B0807C'u, 0x000A0000'u32)" in rx_body
    assert "inc drained" in rx_body


def test_wifi_rx_control_event_uses_explicit_frame_batch_limit():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    rx_body = wifi_fw.split(
        "proc rxl_cntrl_evt*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rxl_timer_int_handler*",
        1,
    )[0]

    assert "var loopCount: int = 5" in rx_body
    assert "while loopCount > 0:" in rx_body
    assert "while true:" not in rx_body
    assert "dec loopCount" in rx_body
    assert "if loopCount <= 0:" in rx_body
    assert "ke_evt_set(0x00100000'u32)" in rx_body


def test_wifi_rx_mpdu_free_uses_explicit_descriptor_chain_condition():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    free_body = wifi_fw.split(
        "proc rxl_mpdu_free*(desc: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rxl_mpdu_transfer*",
        1,
    )[0]

    assert "while curHw != 0:" in free_body
    assert "while true:" not in free_body
    assert "curHw = cast[uint](nextHw)" in free_body
    assert 'assert_rec("rxl_hwdesc.c", "rxl_hwdesc.c", 872)' in free_body


def test_wifi_channel_tbtt_reschedule_uses_explicit_list_drain_condition():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    tbtt_body = wifi_fw.split(
        "proc chan_tbtt_schedule*(tbttEntry: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc chan_goto_idle_cb*",
        1,
    )[0]

    assert "while tbttList.first != nil:" in tbtt_body
    assert "while true:" not in tbtt_body
    assert "chan_tbtt_insert(tbttEntry)" in tbtt_body
    assert "chan_tbtt_insert(cast[pointer](entry))" in tbtt_body


def test_wifi_ipc_message_event_yields_under_host_backlog():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    ipc_body = wifi_fw.split(
        "proc ipc_emb_msg_evt*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc ipc_emb_radar_event_ind*", 1
    )[0]

    assert "WifiIpcMsgDrainLimit = 8'u32" in wifi_fw
    assert "nimfw_dbg_ipc_msg_yield" in wifi_fw
    assert "nimfw_dbg_ipc_msg_yield_status" in wifi_fw
    assert "proc ipcMessagePending(status: uint32, msgBit: uint32): bool" in wifi_fw
    assert "var drained = 0'u32" in ipc_body
    assert "while drained < WifiIpcMsgDrainLimit and ipcMessagePending(ipcStatus, IPC_MSG_BIT):" in ipc_body
    assert "while true:" not in ipc_body
    assert "inc drained" in ipc_body
    assert "if ipcMessagePending(ipcStatus, IPC_MSG_BIT):" in ipc_body
    assert "inc nimFwDbgIpcMsgYield" in ipc_body
    assert "nimFwDbgIpcMsgYieldStatus = ipcStatus" in ipc_body
    assert "return" in ipc_body
    yield_body = ipc_body.split("if ipcMessagePending(ipcStatus, IPC_MSG_BIT):", 1)[1].split("return", 1)[0]
    assert "ke_evt_clear(0x10000000'u32)" not in yield_body
    assert "regWrite(IPC_EMB_UNMASK_SET, IPC_MSG_BIT)" not in yield_body


def test_wifi_saved_messages_reschedule_in_bounded_batches():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    resched_body = wifi_fw.split("proc ke_reschedule_saved_messages", 1)[1].split(
        "proc ke_task_local*", 1
    )[0]
    state_body = wifi_fw.split("proc ke_state_set*", 1)[1].split(
        "proc ke_state_get*", 1
    )[0]
    schedule_body = wifi_fw.split("proc ke_task_schedule*", 1)[1].split(
        "proc ke_task_sm_activating*", 1
    )[0]

    assert "WifiSavedMsgDrainLimit = 8'u32" in wifi_fw
    assert "keSavedReschedTask* {.wifiCtrl.}: uint8 = TASK_NONE" in wifi_fw
    assert "nimfw_dbg_saved_msg_yield" in wifi_fw
    assert "nimfw_dbg_saved_msg_yield_task" in wifi_fw
    assert "proc ke_saved_queue_has_dest" in wifi_fw
    assert "while moved < limit:" in resched_body
    assert "keSavedReschedTask = taskId" in resched_body
    assert "inc nimFwDbgSavedMsgYield" in resched_body
    assert "nimFwDbgSavedMsgYieldTask = taskId.uint32" in resched_body
    assert "ke_evt_set(KE_EVT_KE_MESSAGE)" in resched_body
    assert "discard ke_reschedule_saved_messages(taskId)" in state_body
    assert "while true:" not in state_body
    assert "keSavedReschedTask != TASK_NONE" in schedule_body
    assert "discard ke_reschedule_saved_messages(keSavedReschedTask)" in schedule_body
    assert "ke_evt_clear(KE_EVT_KE_MESSAGE)" in schedule_body


def test_wifi_kernel_flush_uses_explicit_queue_drain_conditions():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    flush_body = wifi_fw.split(
        "proc ke_flush*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "# ###########################################################################\n#                      KERNEL: TASK / STATE",
        1,
    )[0]

    assert "while keMsgQueueSent.first != nil:" in flush_body
    assert "while keMsgQueueSaved.first != nil:" in flush_body
    assert "while keTimerQueue.first != nil:" in flush_body
    assert "while true:" not in flush_body
    assert "ke_evt_clear(0xFFFFFFFF'u32)" in flush_body


def test_wifi_list_and_postpone_helpers_use_explicit_loop_conditions():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    extract_body = wifi_fw.split("proc co_list_extract*", 1)[1].split(
        "proc co_list_find*", 1
    )[0]
    bcn_body = wifi_fw.split(
        "proc mm_bcn_transmitted*(vifEntry: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc mm_bcn_update*(vifEntry: pointer): pointer {.exportc, cdecl, noinline.} =",
        1,
    )[0]
    postpone_body = wifi_fw.split(
        "proc apm_tx_int_ps_get_postpone*(vifEntry: pointer, staEntry: pointer, postponeFlag: ptr uint32): pointer {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc apm_tx_int_ps_clear*(vifEntry: pointer, staIdx: uint8) {.exportc, cdecl.} =",
        1,
    )[0]

    assert "while cur.next != nil:" in extract_body
    assert "while true:" not in extract_body
    assert "while timQueue.first != nil:" in bcn_body
    assert "while true:" not in bcn_body
    assert "while cur != nil:" in postpone_body
    assert "assert_warn(\"apm.c\", \"apm.c\", 377)" in postpone_body
    assert "return nil" in postpone_body
    assert "while true:" not in postpone_body


def test_wifi_send_postponed_frames_uses_explicit_budget_condition():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    service_body = wifi_fw.split(
        "proc sta_mgmt_send_postponed_frame*(vifEntry: pointer, staEntry: pointer, maxCount: uint32): uint32 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc sta_mgmt_entry_init*",
        1,
    )[0]

    assert "while sta.postponedList.first != nil and (maxCount == 0 or count < maxCount):" in service_body
    assert "while true:" not in service_body
    assert "discard sta_mgmt_postponed_desc_release(staEntry, 0)" in service_body
    assert "return count" in service_body


def test_wifi_notifier_chain_uses_shared_explicit_list_helpers():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    insert_body = wifi_fw.split("proc notifier_chain_insert_ordered", 1)[1].split(
        "proc notifier_chain_remove", 1
    )[0]
    remove_body = wifi_fw.split("proc notifier_chain_remove", 1)[1].split(
        "proc notifier_chain_regsiter*", 1
    )[0]
    register_body = wifi_fw.split(
        "proc notifier_chain_regsiter*(chain: ptr CoList, notifier: ptr CoListHdr) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc notifier_chain_regsiter_fromCritical*", 1
    )[0]
    register_critical_body = wifi_fw.split(
        "proc notifier_chain_regsiter_fromCritical*(chain: ptr CoList, notifier: ptr CoListHdr) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc notifier_chain_unregsiter*", 1
    )[0]
    unregister_body = wifi_fw.split(
        "proc notifier_chain_unregsiter*(chain: ptr CoList, notifier: ptr CoListHdr) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc notifier_chain_unregsiter_fromCritical*", 1
    )[0]
    unregister_critical_body = wifi_fw.split(
        "proc notifier_chain_unregsiter_fromCritical*(chain: ptr CoList, notifier: ptr CoListHdr) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc notifier_chain_call*", 1
    )[0]

    assert "while cur != nil:" in insert_body
    assert "while true:" not in insert_body
    assert "while cur != nil:" in remove_body
    assert "while true:" not in remove_body
    assert "notifier_chain_insert_ordered(cast[ptr pointer](addr chain.first), notifier)" in register_body
    assert "notifier_chain_insert_ordered(cast[ptr pointer](addr chain.first), notifier)" in register_critical_body
    assert "notifier_chain_remove(cast[ptr pointer](addr chain.first), notifier)" in unregister_body
    assert "notifier_chain_remove(cast[ptr pointer](addr chain.first), notifier)" in unregister_critical_body
    for body in [
        register_body,
        register_critical_body,
        unregister_body,
        unregister_critical_body,
    ]:
        assert "while true:" not in body


def test_wifi_rate_control_random_sample_selection_is_bounded():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    helper_body = wifi_fw.split("proc rc_pick_non_duplicate_rate", 1)[1].split(
        "proc rcRateEntryTp", 1
    )[0]
    init_body = wifi_fw.split(
        "proc rc_init*(staEntry: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rc_check*(staIdx: uint8) {.exportc, cdecl.} =",
        1,
    )[0]
    update_body = wifi_fw.split(
        "proc rc_update_bw_nss_max*(staIdx: uint8, nss: uint8, groupCnt: uint8) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rc_update_preamble_type*",
        1,
    )[0]

    assert "RcRandomRateAttemptLimit = 64" in wifi_fw
    assert "while tries < RcRandomRateAttemptLimit:" in helper_body
    assert "rc_new_random_rate(stats)" in helper_body
    assert "rc_check_rate_duplicated(stats, randomRate) == 0" in helper_body
    assert "return candidate" in helper_body
    assert "0xFFFF'u16" in helper_body
    assert "let randomRate = rc_pick_non_duplicate_rate(stats)" in init_body
    assert "let randomRate = rc_pick_non_duplicate_rate(rcStats)" in update_body
    assert "while true:" not in update_body


def test_wifi_kernel_timer_scheduler_yields_under_expired_backlog():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    timer_body = wifi_fw.split(
        "proc ke_timer_schedule*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc ke_timer_active*", 1
    )[0]

    assert "WifiTimerDrainLimit = 8'u32" in wifi_fw
    assert "nimfw_dbg_ke_timer_yield" in wifi_fw
    assert "nimfw_dbg_ke_timer_yield_head" in wifi_fw
    assert "proc keTimerExpired(entry: ptr KeTimerEntry): bool" in wifi_fw
    assert "var drained = 0'u32" in timer_body
    assert "while drained < WifiTimerDrainLimit:" in timer_body
    assert "while true:" not in timer_body
    assert "inc drained" in timer_body
    assert "nimFwDbgKeTimerYieldHead = next.time" in timer_body
    assert "if keTimerExpired(next):" in timer_body
    assert "inc nimFwDbgKeTimerYield" in timer_body
    assert "ke_evt_set(KE_EVT_KE_TIMER)" in timer_body
    assert "ke_timer_hw_set(next)" in timer_body
    assert "ke_timer_hw_set(nil)" in timer_body


def test_wifi_mm_timer_scheduler_yields_under_expired_backlog():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    timer_body = wifi_fw.split(
        "proc mm_timer_schedule*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "# ###########################################################################\n#                     CHANNEL MANAGEMENT",
        1,
    )[0]

    assert "WifiTimerDrainLimit = 8'u32" in wifi_fw
    assert "nimfw_dbg_mm_timer_yield" in wifi_fw
    assert "nimfw_dbg_mm_timer_yield_head" in wifi_fw
    assert "proc mmTimerExpired(node: ptr CoListHdr): bool" in wifi_fw
    assert "var drained = 0'u32" in timer_body
    assert "while drained < WifiTimerDrainLimit:" in timer_body
    assert "while true:" not in timer_body
    assert "inc drained" in timer_body
    assert "nimFwDbgMmTimerYieldHead = nextTimer.expiry" in timer_body
    assert "if mmTimerExpired(next):" in timer_body
    assert "inc nimFwDbgMmTimerYield" in timer_body
    assert "ke_evt_set(KE_EVT_MM_TIMER)" in timer_body
    assert "mm_timer_hw_set(cast[pointer](next))" in timer_body
    assert "mm_timer_hw_set(nil)" in timer_body


def test_ble_event_scheduler_yields_under_backlog():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    event_body = ble.split("proc patch_ble_ke_event_schedule*", 1)[1].split(
        "proc ble_ke_event_schedule*", 1
    )[0]

    assert "BleKeEventDrainLimit = 8'u32" in ble
    assert "nim_ble_ke_event_yield_count" in ble
    assert "nim_ble_ke_event_yield_field" in ble
    assert "var drained = 0'u32" in event_body
    assert "inc drained" in event_body
    assert "if drained >= BleKeEventDrainLimit and field != 0:" in event_body
    assert "inc nim_ble_ke_event_yield_count" in event_body
    assert "nim_ble_ke_event_yield_field = field" in event_body
    assert "return" in event_body


def test_ble_scan_reports_drain_in_bounded_host_poll_batches():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()
    ble_host = (ROOT / "src/bl808/ble.nim").read_text()

    drain_body = ble.split("proc bleControllerDrainScanReports*", 1)[1].split(
        "proc scanEventTypeFromPdu", 1
    )[0]
    pump_body = ble_host.split("proc bleBackendServicePump()", 1)[1].split(
        "proc bleHostServicePump*", 1
    )[0]

    assert "BleScanReportDrainLimit = 2'u32" in ble
    assert "nim_ble_scan_report_yield_count" in ble
    assert "nim_ble_scan_report_yield_pending" in ble
    assert "proc pendingScanReportsReady(): bool" in ble
    assert "var drained = 0'u32" in drain_body
    assert "while pendingScanReportsReady() and drained < BleScanReportDrainLimit:" in drain_body
    assert "drained < BleScanReportDrainLimit" in drain_body
    assert "inc drained" in drain_body
    assert "inc nim_ble_scan_report_yield_count" in drain_body
    assert "nim_ble_scan_report_yield_pending = nim_pending_scan_report_count.uint32" in drain_body
    assert "if pendingScanReportsReady():" in drain_body
    assert "blecontroller.bleControllerDrainScanReports()" in pump_body


def test_ble_hci_format_parser_uses_explicit_terminator_loop():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    format_body = ble.split("proc hciUtilCopyByFormat", 1)[1].split(
        "proc hci_util_pack*", 1
    )[0]

    assert "while fmt[fmtOff] != 0'u8:" in format_body
    assert "while true:" not in format_body
    assert "if ch == 0:" not in format_body


def test_ble_rf_and_connection_convergence_loops_are_explicit():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    txcal_body = ble.split("proc tuneBleRfTxcalSingenPower", 1)[1].split(
        "proc writeBleRfTxcalMixerCs", 1
    )[0]
    schedule_body = ble.split("proc nimConnSchedule() =", 1)[1].split(
        "nimConnProgramRxTiming", 1
    )[0]

    assert "var tuning = true" in txcal_body
    assert "while tuning:" in txcal_body
    assert "while true:" not in txcal_body
    assert "var scheduled = false" in schedule_body
    assert "while not scheduled:" in schedule_body
    assert "scheduled = true" in schedule_body
    assert "while true:" not in schedule_body


def test_ble_deferred_jobs_yield_under_backlog():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    djob_body = ble.split("proc coDjobRun", 1)[1].split(
        "proc coDjobRegister", 1
    )[0]

    assert "CoDjobDrainLimit = 8'u32" in ble
    assert "nim_ble_codjob_yield_count" in ble
    assert "nim_ble_codjob_yield_event" in ble
    assert "var drained = 0'u32" in djob_body
    assert "while drained < CoDjobDrainLimit:" in djob_body
    assert "while true:" not in djob_body
    assert "inc drained" in djob_body
    assert "let more = co_djob_queues[index].first != nil" in djob_body
    assert "inc nim_ble_codjob_yield_count" in djob_body
    assert "nim_ble_codjob_yield_event = eventId.uint32" in djob_body
    assert "ble_ke_event_set(coDjobEventId(index))" in djob_body


def test_wifi_firmware_is_pure_nim_without_sdk_vendor_links():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    for forbidden in [
        "{.passL:",
        "{.compile:",
        "build/inspect",
        "bl_iot_sdk",
        "bl808WifiVendor",
    ]:
        assert forbidden not in wifi_fw


def test_ble_wifi_firmware_have_no_vendor_when_branches():
    for relative in [
        "src/bl808/blecontroller.nim",
        "src/bl808/wifi_fw.nim",
    ]:
        source = ROOT / relative
        for line_number, line in enumerate(source.read_text().splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("when ") and (
                "Vendor" in stripped or "vendor" in stripped
            ):
                raise AssertionError(
                    f"{relative}:{line_number} still has vendor-gated branch: "
                    f"{stripped}"
                )


def test_pure_nim_wifi_firmware_has_no_backend_selection_guards():
    for relative in [
        "src/bl808/blecontroller.nim",
        "src/bl808/wifi_fw.nim",
        "examples/m0_ble_wifi_hal_test.nim",
    ]:
        source = ROOT / relative
        text = source.read_text()
        assert "when defined(bl808WifiNimFw)" not in text
        assert "when not defined(bl808WifiNimFw)" not in text


def test_wifi_firmware_task_state_transitions_use_named_constants():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    code_lines = [
        line.strip()
        for line in wifi_fw.splitlines()
        if not line.strip().startswith(("#", "##"))
    ]
    wifi_code = "\n".join(code_lines)

    for expected in [
        "TaskIdleState* = 0'u16",
        "TaskActiveState* = 1'u16",
        "TaskGoingIdleState* = 2'u16",
        "MeGoingIdleState* = 2'u16",
        "ApmIdleState* = 0'u16",
        "ApmActiveState* = 1'u16",
        "ApmStartingState* = 2'u16",
        "BamIdleState* = 0'u16",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "ke_state_set(0'u8, 0'u16)",
        "ke_state_set(4, 10)",
        "ke_state_set(TASK_APM, 0)",
        "ke_state_set(TASK_APM, 1)",
        "ke_state_set(TASK_APM, 2)",
        "ke_state_set(TASK_BAM, 0)",
        "ke_state_set(TASK_ME, 0)",
        "ke_state_set(TASK_ME, 1)",
        "ke_state_set(TASK_MM, 1)",
        "ke_state_set(TASK_MM, 2)",
        "ke_state_set(TASK_MM, 3)",
    ]:
        assert forbidden not in wifi_code

    for expected in [
        "ke_state_set(TASK_SM, SmDisconnectingState)",
        "ke_state_set(TASK_APM, ApmIdleState)",
        "ke_state_set(TASK_APM, ApmActiveState)",
        "ke_state_set(TASK_APM, ApmStartingState)",
        "ke_state_set(TASK_BAM, BamIdleState)",
        "ke_state_set(TASK_ME, MeIdleState)",
        "ke_state_set(TASK_ME, MeBusyState)",
        "ke_state_set(TASK_ME, MeGoingIdleState)",
        "ke_state_set(srcId, TaskGoingIdleState)",
        "ke_state_set(srcTask, TaskIdleState)",
    ]:
        assert expected in wifi_fw


def test_ble_peripheral_waits_are_completed_by_notifications():
    ble = (ROOT / "src/bl808/ble.nim").read_text()
    assert "completeBlePeripheralConnected(addr bleConn)" in ble
    assert "completeBlePeripheralDisconnected(reason)" in ble
    assert "proc bleInstallHostServiceHook*" in ble
    assert "addSchedulerTimedPollHook(bleHostServicePollHook, readTick())" in ble

    wait_connected = ble.split("proc bleWaitPeripheralConnected*", 1)[1].split(
        "proc bleWaitPeripheralDisconnected*", 1
    )[0]
    wait_disconnected = ble.split("proc bleWaitPeripheralDisconnected*", 1)[1].split(
        "proc bleCentralScan*", 1
    )[0]
    assert "newLocalCpsFuture[ptr BtConn]()" in wait_connected
    assert "newLocalCpsFuture[uint8]()" in wait_disconnected
    assert "await sleep" not in wait_connected
    assert "await sleep" not in wait_disconnected
