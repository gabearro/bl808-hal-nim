import subprocess
import shutil
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def llvm_objdump_cmd():
    return shutil.which("llvm-objdump") or "/opt/homebrew/opt/llvm/bin/llvm-objdump"


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


def test_ble_bt_priority_pta_uses_single_masked_update_helper():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()
    body = ble.split(
        "proc configureBtPriorityPta()", 1
    )[1].split(
        "type\n  BleRegInit", 1
    )[0]

    for expected in [
        "proc updatePtaCtrl(keepMask, setMask: uint32)",
        "let reg = (volatileLoad(ptaReg(PtaCtrl)) and keepMask) or setMask",
        "volatileStore(ptaReg(PtaCtrl), reg)",
        "updatePtaCtrl(not 1'u32, 0'u32)",
        "updatePtaCtrl(0xFFF7FFFF'u32, 0x00080000'u32)",
        "updatePtaCtrl(0xFFFBFFFF'u32, 0x00040000'u32)",
        "updatePtaCtrl(0xFFFDFFFF'u32, 0'u32)",
        "updatePtaCtrl(0xFFFEFFFF'u32, 0'u32)",
    ]:
        assert expected in body

    assert body.count("volatileLoad(ptaReg(PtaCtrl))") == 1
    assert body.count("volatileStore(ptaReg(PtaCtrl), reg)") == 1
    assert "var reg = volatileLoad(cast[ptr uint32](PtaCtrl))" not in body


def test_wifi_pta_autocontrol_uses_single_masked_update_helper():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    body = wifi_fw.rsplit(
        "proc coex_pta_force_autocontrol_set*", 1
    )[1].split(
        "# ###########################################################################", 1
    )[0]

    for expected in [
        "ptaCoexClear()",
        "ptaCoexUpdateControl(0xFFF7FFFF'u32, 0x00080000'u32)",
        "ptaCoexUpdateControl(0xFFFBFFFF'u32, 0x00040000'u32)",
        "ptaCoexUpdateControl(0xFFFDFFFF'u32, 0x00020000'u32)",
        "ptaCoexUpdateControl(0xFFFEFFFF'u32, 0x00010000'u32)",
        "wlanCoexWriteControl(wlanCoexControl() or 0x01'u32)",
    ]:
        assert expected in body

    assert body.count("var reg = volatileLoad(cast[ptr uint32](PTA_CTRL))") == 0
    assert body.count("volatileStore(cast[ptr uint32](PTA_CTRL), reg)") == 0
    assert "proc updateCoexReg" not in body


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
    assert "WifiMainServiceMode = enum" not in wifi_fw
    assert "wifiServiceNonblocking" not in wifi_fw
    assert "wifiServiceBlockingIdle" not in wifi_fw
    assert "proc wifiMainServiceStep(blockWhenIdle = false): bool" in wifi_fw
    assert "proc wifiMainServiceNonblocking(): bool" in wifi_fw
    assert "proc wifiMainServiceBlockingIdle(): bool" in wifi_fw
    assert "proc wifiMainHasPendingWork(): bool" in wifi_fw
    assert "proc wifiMainHasPendingWork(): bool {.inline.}" not in wifi_fw
    assert "proc wifiEventPendingWork(): bool {.inline.}" in wifi_fw
    assert "proc wifiKernelTimerPendingWork(): bool {.inline.}" in wifi_fw
    assert "proc wifiMmTimerPendingWork(): bool {.inline.}" in wifi_fw
    assert "proc wifiMessagePendingWork(): bool {.inline.}" in wifi_fw
    assert "proc wifiMessageEventPending(): bool {.inline.}" in wifi_fw
    assert "proc wifiHiddenMessagePendingWork(): bool {.inline.}" in wifi_fw
    assert "proc wifiMainModeFromAbi" not in wifi_fw
    assert "proc wifiUpdateMacPlCtrl() {.inline.}" in wifi_fw
    assert "proc wifiWaitForWorkIfIdle(blockWhenIdle, hasWork: bool): bool" in wifi_fw
    assert "proc wifiDrainScheduledWork(): bool" in wifi_fw
    assert "wifiMainServiceStep(blockWhenIdle != 0'u8)" in wifi_fw
    assert "keEvtField != 0" in wifi_fw
    assert "wifiEventPendingWork() or wifiKernelTimerPendingWork() or" in wifi_fw
    assert "wifiMmTimerPendingWork() or wifiMessagePendingWork()" in wifi_fw
    assert "wifiMessagePendingWork() and not wifiMessageEventPending()" in wifi_fw
    assert "result = wifiMainHasPendingWork()" in wifi_fw
    assert "KeTaskInitSpec = object" in wifi_fw
    assert "let taskSpecs = [" in wifi_fw
    assert "for spec in taskSpecs:" in wifi_fw
    assert "if blockWhenIdle and not result:" in wifi_fw
    assert "wifiMainServiceStep(blockWhenIdle = true)" in wifi_fw
    assert "discard wifiMainServiceNonblocking()" in wifi_fw
    wifi_main_body = wifi_fw.split(
        "proc wifi_main*(param: pointer) {.exportc, cdecl.} =", 1
    )[1]
    assert "discard wifiMainServiceBlockingIdle()" in wifi_main_body
    sleep_body = wifi_fw.split("proc bl_sleep_schedule*() {.exportc, cdecl.} =", 1)[
        1
    ].split("proc bl_nap_calculate*", 1)[0]
    assert "if wifiMainHasPendingWork():" in sleep_body
    assert sleep_body.index("if wifiMainHasPendingWork():") < sleep_body.index(
        "elif pmState != 0:"
    )
    wifi_step = wifi_fw.split(
        "proc wifiMainServiceStep(blockWhenIdle = false): bool =", 1
    )[1].split(
        "proc wifi_main_service_step*", 1
    )[0]
    assert "wifiUpdateMacPlCtrl()" in wifi_step
    assert "result = wifiWaitForWorkIfIdle(blockWhenIdle, wifiMainHasPendingWork())" in wifi_step
    assert "if wifiDrainScheduledWork():" in wifi_step
    assert "ke_timer_schedule()" not in wifi_step
    assert "mm_timer_schedule()" not in wifi_step
    assert "ke_task_schedule()" not in wifi_step
    assert "ke_evt_schedule()" not in wifi_step
    assert "macTimeNow()" not in wifi_step
    assert "ipc_emb_wait()" not in wifi_step
    wifi_drain = wifi_fw.split("proc wifiDrainScheduledWork(): bool =", 1)[1].split(
        "proc wifiMainServiceStep", 1
    )[0]
    assert "if wifiKernelTimerPendingWork():" in wifi_drain
    assert "ke_timer_schedule()" in wifi_drain
    assert "if wifiMmTimerPendingWork():" in wifi_drain
    assert "mm_timer_schedule()" in wifi_drain
    assert "if wifiHiddenMessagePendingWork():" in wifi_drain
    assert "ke_task_schedule()" in wifi_drain
    assert wifi_drain.index("ke_evt_schedule()") < wifi_drain.index(
        "if wifiHiddenMessagePendingWork():"
    )
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()
    assert "proc blecontroller_service_step*" in ble
    assert "proc blecontroller_poll_once*" in ble
    assert "BleControllerServiceMode = enum" not in ble
    assert "bleServiceNonblocking" not in ble
    assert "bleServiceMainLoop" not in ble
    assert "proc bleControllerServiceStep(blockWhenIdle = false): bool" in ble
    assert "proc bleControllerHasPendingWork(): bool" in ble
    assert "proc bleEventPendingWork(): bool {.inline.}" in ble
    assert "proc bleMessagePendingWork(): bool {.inline.}" in ble
    assert "proc bleMessageEventPending(): bool {.inline.}" in ble
    assert "proc bleHiddenMessagePendingWork(): bool {.inline.}" in ble
    assert "proc bleQueuePending(q: pointer): bool {.inline.}" in ble
    assert "proc bleMainQueuePendingWork(): bool {.inline.}" in ble
    assert "proc bleDrainKernelEvents(): bool {.inline.}" in ble
    assert "proc bleDrainMainQueueMessage(): bool" in ble
    assert "proc bleDrainScheduledWork(): bool" in ble
    assert "proc coDjobAnyPending(): bool" in ble
    assert "BleKeMessageEventId = 2'u8" in ble
    assert "BleKeMessageEventBit = 1'u32 shl 2" in ble
    assert "proc bleControllerModeFromAbi" not in ble
    assert "bleControllerModeFromAbi(blockWhenIdle)" not in ble
    assert "ble_ke_event_get_all() != 0'u32" in ble
    assert "bleEventPendingWork() or bleKeTimerPendingWork() or" in ble
    assert "bleMessagePendingWork() or bleMainQueuePendingWork()" in ble
    assert "coDjobAnyPending()" in ble
    assert "(ble_ke_event_get_all() and BleKeMessageEventBit) != 0" in ble
    assert "bleMessagePendingWork() and not bleMessageEventPending()" in ble
    assert "result = bleControllerHasPendingWork()" in ble
    assert "proc bleControllerServiceNonblocking(): bool" in ble
    assert "proc bleControllerServiceBlockingIdle(): bool" in ble
    assert "bleControllerServiceStep()" in ble
    assert "bleControllerServiceStep(blockWhenIdle = true)" in ble
    assert "bleControllerServiceStep(blockWhenIdle != 0'u8)" in ble
    assert "discard bleControllerServiceBlockingIdle()" in ble
    assert "discard mode" not in ble
    assert "discard blockWhenIdle" not in ble
    bflbip_body = ble.split("proc bflbip_schedule*() {.exportc, cdecl.} =", 1)[
        1
    ].split("proc bflbip_get_sw_wakup_cnt*", 1)[0]
    assert "serviceQueuedNimConnectInd()" in bflbip_body
    assert "discard bleControllerServiceNonblocking()" in bflbip_body
    assert "ble_ke_event_schedule()" not in bflbip_body
    rwip_body = ble.split("proc rwip_schedule*() {.exportc, cdecl.} =", 1)[1].split(
        "proc rwip_sleep*", 1
    )[0]
    assert "discard bleControllerServiceNonblocking()" in rwip_body
    assert "ble_ke_event_schedule()" not in rwip_body
    ble_step = ble.split("proc bleControllerServiceStep(blockWhenIdle = false): bool", 1)[1].split(
        "proc blecontroller_service_step*", 1
    )[0]
    assert "if bleDrainMainQueueMessage():" in ble_step
    assert "if bleDrainScheduledWork():" in ble_step
    assert "if blockWhenIdle and not result:" in ble_step
    assert "discard bflbip_sleep()" in ble_step
    assert "result = bleControllerHasPendingWork()" in ble_step
    assert "ble_xQueueReceive(bflb_main_queue_handle, addr msg_buf[0], 0)" not in ble_step
    assert "ble_ke_event_schedule()" not in ble_step
    assert "ble_ke_task_schedule()" not in ble_step
    ble_drain = ble.split("proc bleDrainScheduledWork(): bool =", 1)[1].split(
        "proc bleControllerServiceStep", 1
    )[0]
    assert "if bleKeTimerPendingWork():" in ble_drain
    assert "ble_ke_timer_schedule()" in ble_drain
    assert "if not bleEventPendingWork():\n    return false" in ble
    assert "if bleDrainKernelEvents():" in ble_drain
    assert "if bleHiddenMessagePendingWork():" in ble_drain
    assert "ble_ke_task_schedule()" in ble_drain
    assert "ble_ke_event_schedule()" not in ble_drain
    kernel_event_body = ble.split("proc bleDrainKernelEvents(): bool {.inline.}", 1)[1].split(
        "proc bleControllerHasPendingWork", 1
    )[0]
    assert "ble_ke_event_schedule()" in kernel_event_body
    assert "return false" in kernel_event_body
    assert "true" in kernel_event_body
    assert "high(uint32)" not in ble_step
    assert "while true:" not in ble_step
    assert "proc wifi_main_poll_once() {.importc, cdecl.}" in wifi_support
    assert "proc ke_evt_schedule() {.importc, cdecl.}" not in wifi_support
    poll_once_body = wifi_support.split("proc vendorPollOnce()", 1)[1].split(
        "proc vendorPollFor", 1
    )[0]
    assert "wifi_main_poll_once()" in poll_once_body
    assert "ipc_emb_wait()" not in poll_once_body
    drain_body = wifi_support.split("proc vendorDrainScheduledWork()", 1)[1].split(
        "proc vendorPollOnce()", 1
    )[0]
    assert "wifi_main_poll_once()" in drain_body
    assert "ke_evt_schedule()" not in drain_body

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


def test_wifi_sync_connect_services_nim_firmware_tx():
    wifi = (ROOT / "src/bl808/wifi.nim").read_text()

    body = wifi.split(
        "proc wifiConnect*(ssid, password: string, channel: uint8 = 0): WifiError =",
        1,
    )[1].split(
        "proc wifiConnectAsync*",
        1,
    )[0]
    wait_body = body.split("if wifiBackendUsesEventFutures():", 1)[1]

    assert "wifiBackendPoll(8)" in wait_body
    assert "wifiNimFirmwareServiceTx(8)" in wait_body
    assert wait_body.index("wifiBackendPoll(8)") < wait_body.index(
        "wifiNimFirmwareServiceTx(8)"
    )
    assert wait_body.index("wifiNimFirmwareServiceTx(8)") < wait_body.index(
        "if wifiBackendConnectDone():"
    )


def test_wifi_firmware_hardware_waits_are_bounded_for_cps_runtime():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    assert "WifiHwPollLimit = 100_000'u32" in wifi_fw
    assert "nimfw_dbg_hw_wait_timeout_count" in wifi_fw
    assert "proc waitRegMaskClear" in wifi_fw
    assert "proc waitRegMaskSet" in wifi_fw
    assert "proc waitRegLowNibbleClear" in wifi_fw
    assert "proc waitRegLowNibbleEquals" in wifi_fw
    assert "proc waitMacSoftResetClear" in wifi_fw
    assert "PsDozeEnvView {.packed.} = object" in wifi_fw
    assert "dozeInProgress*: uint32" in wifi_fw
    assert "preState*: uint8" in wifi_fw
    assert "doAssert offsetof(PsDozeEnvView, dozeInProgress) == 56" in wifi_fw
    assert "doAssert offsetof(PsDozeEnvView, preState) == 60" in wifi_fw
    assert "template psDozeEnvView(): ptr PsDozeEnvView" in wifi_fw

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
    doze_body = wifi_fw.split("proc set_mac_to_doze*", 1)[1].split(
        "proc wait_mac_goto_idle*", 1
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
    assert "MachwSecurityRegsView {.packed.} = object" in wifi_fw
    assert "doAssert offsetof(MachwSecurityRegsView, keyMaterial) == 0x0AC" in wifi_fw
    assert "doAssert offsetof(MachwSecurityRegsView, dataLow) == 0x0BC" in wifi_fw
    assert "doAssert offsetof(MachwSecurityRegsView, control) == 0x0C4" in wifi_fw
    assert "template machwSecurityRegs(): ptr MachwSecurityRegsView" in wifi_fw
    assert "WlanCoexRegsView {.packed.} = object" in wifi_fw
    assert "PtaCoexRegsView {.packed.} = object" in wifi_fw
    assert "doAssert offsetof(WlanCoexRegsView, pti) == 0x04" in wifi_fw
    assert "doAssert offsetof(PtaCoexRegsView, control2) == 0x028" in wifi_fw
    assert "doAssert offsetof(PtaCoexRegsView, mirror) == 0x404" in wifi_fw
    assert "doAssert offsetof(PtaCoexRegsView, clear) == 0x428" in wifi_fw
    assert "template wlanCoexRegs(): ptr WlanCoexRegsView" in wifi_fw
    assert "template ptaCoexRegs(): ptr PtaCoexRegsView" in wifi_fw
    assert "nimFwDbgBleWifiTxCfmBcn = wlanCoexControl()" in wifi_fw
    assert "ptaCoexWriteControl(WifiRoleCtrl)" in wifi_fw
    assert "ptaCoexUpdateControl(0xFFF7FFFF'u32, 0'u32)" in wifi_fw
    assert "wlanCoexWriteControl(wlanCoexControl() or 0x01'u32)" in wifi_fw
    assert "machwSecurityWriteAddress(mac.lo, mac.hi)" in sec_body
    assert "machwSecurityClearKeyMaterial()" in sec_body
    assert "waitMachwSecurityControlClear(0x40000000'u32)" in sec_body
    assert "waitMachwSecurityControlClear(0x80000000'u32)" in key_get_body
    for forbidden in [
        "cast[ptr uint32](KEY_MAT0)",
        "cast[ptr uint32](KEY_LO)",
        "cast[ptr uint32](KEY_CTRL)",
        "cast[ptr uint32](MACHW + 0x0AC'u)",
        "cast[ptr uint32](MACHW + 0x0BC'u)",
        "regRead(0x24B00400'u)",
        "regRead(0x24B00404'u)",
        "regRead(0x24B00408'u)",
        "MACHW_COEX_BASE",
        "cast[ptr uint32](PTA_REG)",
    ]:
        if forbidden.startswith("regRead") or forbidden in [
            "MACHW_COEX_BASE",
            "cast[ptr uint32](PTA_REG)",
        ]:
            assert forbidden not in wifi_fw
        else:
            assert forbidden not in sec_body
            assert forbidden not in key_get_body
    assert "waitRegLowNibbleEquals(MACHW_STATE_CNTRL_REG" in ps_body
    assert "waitRegLowNibbleClear(MACHW_STATE_CNTRL_REG)" in ps_body
    assert "psDozeEnvView().preState" in ps_body
    assert "psDozeEnvView().dozeInProgress = 1" in doze_body
    assert "psDozeEnvView().dozeInProgress = 0" in wakeup_body
    for forbidden in [
        "cast[ptr uint32](cast[uint](addr ps_env[0]) + 56)",
        "cast[ptr uint8](cast[uint](addr ps_env[0]) + 60)",
    ]:
        assert forbidden not in doze_body
        assert forbidden not in ps_body
        assert forbidden not in wakeup_body
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


def test_wifi_machwkey_delete_uses_vif_overlay_lookup():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split("proc mm_sec_machwkey_del*", 1)[1].split(
        "proc mm_sec_machwkey_get*", 1
    )[0]

    assert "let vif = vifChannelForIdx(hwIdx.uint8)" in body
    assert "vif_mgmt_del_key(cast[pointer](vif), vifSlot.uint8)" in body
    assert "let vif = vifChannelForIdx(vifIdx)" in body
    assert "vif_mgmt_del_key(cast[pointer](vif), vifSlot)" in body
    for forbidden in [
        "let vifTabBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifTabBase + hwIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vifEntry = vifTabBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "vif_mgmt_del_key(cast[pointer](vifEntry)",
    ]:
        assert forbidden not in body


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


def test_wifi_tx_control_ps_check_uses_positive_queueing_guard():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    push_body = wifi_fw.split(
        "proc txl_cntrl_push_int*(param: pointer, ac: uint8): uint8 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_cntrl_push_int_force*", 1
    )[0]

    assert "let psOk = apm_tx_int_ps_check(param)" in push_body
    assert "if psOk:" in push_body
    assert "return 1'u8" in push_body
    assert "PS check failed: fall through to the not-ready/postpone path." in push_body
    assert "if not psOk:" not in push_body
    assert "PS check failed: fall through to not-ready path\n      discard" not in push_body


def test_wifi_tx_control_uses_typed_vif_overlay_for_tx_check():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    push_body = wifi_fw.split(
        "proc txl_cntrl_push_int*(param: pointer, ac: uint8): uint8 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_cntrl_push_int_force*", 1
    )[0]

    assert "let vifTx = vifChannelForIdx(vifIdxTx)" in push_body
    assert "let vifEntryTx = cast[pointer](vifTx)" in push_body
    assert "let txReady = txl_cntrl_tx_check(vifEntryTx)" in push_body
    assert "let vifCtxtTrace = vifTx.chanCtxt" in push_body
    assert "let sta = staInfoForIdx(staInstNbr)" in push_body
    assert "let staEntry = cast[pointer](sta)" in push_body
    assert "pointerAddrU32(staEntry)" in push_body
    assert "apm_tx_int_ps_postpone(param, staEntry)" in push_body
    assert "nimFwDbgTxIntLastMeta =" in push_body
    assert "let chanEnvForDiag = chanEnvView()" in push_body
    assert "nimFwDbgTxIntLastChan =" in push_body
    assert "chanEnvForDiag.flags" in push_body
    assert "chanEnvForDiag.ctxtCount" in push_body
    assert "txControlAc(ac.uint32).pending.first" in push_body
    assert "nimFwDbgTxIntLastHw = pointerAddrU32(desc.hwDesc)" in push_body
    assert "inc nimFwDbgTxIntReady" in push_body
    assert "inc nimFwDbgTxIntPsOk" in push_body
    assert "inc nimFwDbgTxIntPush" in push_body
    assert "inc nimFwDbgTxIntRelease" in push_body
    assert "inc nimFwDbgTxIntPostpone" in push_body
    assert "cast[uint](addr vif_info_tab[0]) + vifIdxTx.uint * VIF_ENTRY_SIZE.uint" not in push_body
    assert "vifChannelAt(vifEntryTx).chanCtxt" not in push_body
    assert "let staTabBase = cast[uint](addr sta_info_tab[0])" not in push_body
    assert "let staEntry = staTabBase + staInstNbr.uint * STA_ENTRY_SIZE.uint" not in push_body
    assert "let sta = staInfoAt(staEntry)" not in push_body


def test_wifi_tx_push_uses_buffered_link_overlay_for_allocated_bufdesc():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc txl_cntrl_push*(param: pointer, ac: uint8): uint8 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_cntrl_push_int*", 1
    )[0]

    assert "doAssert offsetof(HostTxBufferedLinkView, txDesc) == 20" in wifi_fw
    assert "template hostTxBufferedLinkAt(p: pointer): ptr HostTxBufferedLinkView" in wifi_fw
    assert "hostTxBufferedLinkAt(bufDesc).txDesc = param" in body
    assert "cast[ptr pointer](cast[uint](bufDesc) + 20)" not in body


def test_wifi_tx_inline_buffer_helpers_use_desc_field_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    assert "doAssert offsetof(HostTxDescView, callback) == 208" in wifi_fw
    assert "template hostTxInlineBufferedLink(desc: ptr HostTxDescView): ptr HostTxBufferedLinkView =\n  cast[ptr HostTxBufferedLinkView](addr desc.callback)" in wifi_fw
    assert "template hostTxAuxWords(desc: ptr HostTxDescView): ptr HostTxAuxWordsView =\n  cast[ptr HostTxAuxWordsView](addr desc.callback)" in wifi_fw

    for forbidden in [
        "cast[ptr HostTxBufferedLinkView](cast[uint](desc) + 208'u)",
        "cast[ptr HostTxAuxWordsView](cast[uint](desc) + 208'u)",
    ]:
        assert forbidden not in wifi_fw


def test_wifi_tx_buffer_init_uses_typed_control_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc txl_buffer_init*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_buffer_reinit*", 1
    )[0]

    for expected in [
        "doAssert sizeof(TxBufferControlView) == 60",
        "template txBufferControlDescAt(idx: int): ptr TxBufferControlView",
        "template txBufferControlBcmcDescAt(idx: int): ptr TxBufferControlView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let d = txBufferControlDescAt(i)",
        "d.magic = 0xBADCAB1E'u32",
        "d.ntxConfig = phy_get_ntx().uint32 shl 14",
        "d.bwMask = (1'u32 shl (maskNtx + 1'u32)) - 1'u32",
        "d.policyWord = 0xFFFF0704'u32",
        "d.txPower = cast[int32](regRead(MACHW_RNG_REG) and 0xFF'u32)",
        "d.word52 = 0x2200'u32",
        "d.word56 = 0x003F0000'u32",
        "let d = txBufferControlBcmcDescAt(i)",
    ]:
        assert expected in body

    for forbidden in [
        "let d = cast[uint](addr txl_buffer_control_desc[0]) + i.uint * 60'u",
        "let d = cast[uint](addr txl_buffer_control_desc_bcmc[0]) + i.uint * 60'u",
        "cast[ptr uint32](d + 0)[]",
        "cast[ptr uint32](d + 4)[]",
        "cast[ptr uint32](d + 8)[]",
        "cast[ptr uint32](d + 12)[]",
        "cast[ptr uint32](d + 16)[]",
        "cast[ptr uint32](d + 20)[]",
        "cast[ptr uint32](d + 24)[]",
        "cast[ptr uint32](d + 28)[]",
        "cast[ptr uint32](d + 32)[]",
        "cast[ptr uint32](d + 36)[]",
        "cast[ptr uint32](d + 40)[]",
        "cast[ptr uint32](d + 44)[]",
        "cast[ptr uint32](d + 48)[]",
        "cast[ptr uint32](d + 52)[]",
        "cast[ptr uint32](d + 56)[]",
    ]:
        assert forbidden not in body


def test_wifi_tx_frame_init_uses_typed_mac_header_address():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    frame_init = wifi_fw.split(
        "proc txl_frame_init*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_frame_init_desc*", 1
    )[0]
    init_desc = wifi_fw.split(
        "proc txl_frame_init_desc*(desc: pointer, linkDesc: pointer, hwDesc: pointer, payloadDesc: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_frame_get*", 1
    )[0]

    assert "template hostTxLinkMacHdrAddr(link: ptr HostTxLinkDescView): uint" in wifi_fw
    assert "cast[uint](addr link.macHeader[0])" in wifi_fw
    assert "hostTxLinkMacHdrAddr(hostTxLinkDescAt(desc.bufDesc))" in wifi_fw
    assert "let link = txlFrameLinkDescAt(i)" in frame_init
    assert "hw.payloadStart = cast[uint32](hostTxLinkMacHdrAddr(link))" in frame_init
    assert "hw.payloadStart = cast[uint32](hostTxLinkMacHdrAddr(hostTxLinkDescAt(linkDesc)))" in init_desc

    for forbidden in [
        "hw.payloadStart = cast[uint32](linkDesc + 348'u)",
        "hw.payloadStart = cast[uint32](cast[uint](linkDesc) + 348)",
        "template hostTxMacHdrAddr(desc: ptr HostTxDescView): uint =\n  cast[uint](desc.bufDesc) + 348'u",
    ]:
        assert forbidden not in wifi_fw


def test_wifi_tx_frame_private_pools_use_typed_slot_tables():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    frame_init = wifi_fw.split(
        "proc txl_frame_init*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_frame_init_desc*", 1
    )[0]
    rebuild_body = wifi_fw.split(
        "proc txl_frame_rebuild_free_list()", 1,
    )[1].split(
        "proc txl_frame_free_list_pop", 1,
    )[0]

    for expected in [
        "TxlFrameDescSlotView {.packed.} = object",
        "TxlFrameLinkSlotView {.packed.} = object",
        "TxlFrameHwDescSlotView {.packed.} = object",
        "TxlFrameHwCfmSlotView {.packed.} = object",
        "TxlFramePayloadSlotView {.packed.} = object",
        "doAssert sizeof(TxlFrameDescSlotView) == 220",
        "doAssert sizeof(TxlFrameLinkSlotView) == 860",
        "doAssert sizeof(TxlFrameHwDescSlotView) == 72",
        "doAssert sizeof(TxlFrameHwCfmSlotView) == 20",
        "doAssert sizeof(TxlFramePayloadSlotView) == 60",
        "template txlFrameDescAt(idx: uint32): ptr HostTxDescView",
        "template txlFrameLinkDescAt(idx: uint32): ptr HostTxLinkDescView",
        "template txlFrameHwDescAt(idx: uint32): ptr HostTxHwDescView",
        "template txlFrameHwCfmAt(idx: uint32): ptr TxlFrameHwCfmSlotView",
        "template txlFramePayloadDescAt(idx: uint32): ptr TxBufferControlView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let descPtr = cast[pointer](txlFrameDescAt(i))",
        "let frameDesc = txlFrameDescAt(i)",
        "let link = txlFrameLinkDescAt(i)",
        "let hw = txlFrameHwDescAt(i)",
        "let hwCfm = txlFrameHwCfmAt(i)",
        "let payload = txlFramePayloadDescAt(i)",
        "discard c_memset(cast[pointer](frameDesc), 0, sizeof(TxlFrameDescSlotView).csize_t)",
        "frameDesc.bufDesc = cast[pointer](link)",
        "frameDesc.policy = cast[pointer](payload)",
        "frameDesc.hwDesc = cast[pointer](hw)",
        "hw.word0 = cast[uint32](cast[uint](hwCfm))",
        "txl_frame_free_list_push(cast[pointer](frameDesc))",
    ]:
        assert expected in frame_init + rebuild_body

    for forbidden in [
        "let descArrayBase = cast[uint](addr txl_frame_desc_storage[0])",
        "let linkPoolBase = cast[uint](addr txl_frame_pool[0])",
        "let hwPoolBase = cast[uint](addr txl_frame_hwdesc_pool[0])",
        "let hwCfmBase = cast[uint](addr txl_frame_hwdesc_cfms[0])",
        "let payloadPoolBase = cast[uint](addr txl_frame_buf_ctrl[0])",
        "let descBase = descArrayBase + i.uint * descSize.uint",
        "let linkDesc = linkPoolBase + i.uint * 860'u",
        "let hwDesc = hwPoolBase + i.uint * 72'u",
        "let hwCfm = hwCfmBase + i.uint * 20'u",
        "let payloadDesc = payloadPoolBase + i.uint * 60'u",
        "let descPtr = cast[pointer](base + i.uint * TxlFrameDescSize)",
    ]:
        assert forbidden not in frame_init
        assert forbidden not in rebuild_body


def test_wifi_tx_buffer_alloc_uses_typed_mac_header_body_pointer():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc txl_buffer_alloc*(param: pointer, queueIdx: uint32, flags: uint32): pointer {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_buffer_update_thd*", 1
    )[0]

    assert "template hostTxLinkMacHdrPtr(link: ptr HostTxLinkDescView; offset: uint): pointer" in wifi_fw
    assert "template hostTxLinkMacHdrPtr(link: ptr HostTxBufferedLinkView; offset: uint): pointer" in wifi_fw
    assert "cast[pointer](addr link.macHeader[offset.int])" in wifi_fw
    assert "let bufPtr = hostTxLinkMacHdrPtr(bufLink, hdrLen.uint)" in body
    assert "cast[pointer](cast[uint](addr bufLink.macHeader[0]) + hdrLen.uint)" not in body


def test_wifi_tx_buffer_alloc_copies_policy_with_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc txl_buffer_alloc*(param: pointer, queueIdx: uint32, flags: uint32): pointer {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_buffer_update_thd*", 1
    )[0]

    for expected in [
        "let bufferControl = txBufferControlAt(desc.policy)",
        "let rateTemplate = hostTxRateTemplate(bufLink)",
        "discard c_memcpy(addr bufLink.rateTemplate[0], bufferControl,\n                   sizeof(TxBufferControlView).csize_t)",
        "cast[uint32](cast[uint](bufferControl))",
    ]:
        assert expected in body

    for forbidden in [
        "let bufferControl = cast[uint](desc.policy)",
        "for i in 0'u32 ..< 15'u32:",
        "cast[ptr uint32](dmaBase + i * 4'u32)[]",
        "cast[ptr uint32](bufferControl + i.uint * 4'u)[]",
    ]:
        assert forbidden not in body


def test_wifi_eapol_retry_policy_uses_typed_rate_template():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    policy_body = wifi_fw.split(
        "proc txlApplyEapolRetryPolicy", 1
    )[1].split(
        "proc txl_buffer_alloc*", 1
    )[0]
    alloc_body = wifi_fw.split(
        "proc txl_buffer_alloc*(param: pointer, queueIdx: uint32, flags: uint32): pointer {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_buffer_update_thd*", 1
    )[0]

    assert "proc txlApplyEapolRetryPolicy(rate: ptr HostTxRateTemplateView)" in wifi_fw
    assert "proc txlApplyBootstrapDataRetryPolicy(rate: ptr HostTxRateTemplateView)" in wifi_fw
    assert "txlApplyEapolRetryPolicy(rate)" in policy_body

    for expected in [
        "rate.word24 = 0x8000040A'u32",
        "rate.word28 = 0x80001007'u32",
        "rate.word32 = 0x80000400'u32",
        "rate.txPower = 0x00000070'i32",
        "rate.word40 = 0x00000070'u32",
        "rate.word44 = 0x00000070'u32",
        "rate.word48 = 0x00000070'u32",
    ]:
        assert expected in policy_body

    for expected in [
        "let rateTemplate = hostTxRateTemplate(bufLink)",
        "txlApplyEapolRetryPolicy(rateTemplate)",
        "let isBootstrapData =",
        "protoFrameType == 0x0800'u16 or protoFrameType == 0x0806'u16",
        "txlApplyBootstrapDataRetryPolicy(rateTemplate)",
    ]:
        assert expected in alloc_body

    for forbidden in [
        "proc txlApplyEapolRetryPolicy(dmaBase: uint)",
        "txlApplyEapolRetryPolicy(dmaBase)",
        "cast[ptr uint32](dmaBase + 24'u)[]",
        "cast[ptr uint32](dmaBase + 28'u)[]",
        "cast[ptr uint32](dmaBase + 32'u)[]",
        "cast[ptr uint32](dmaBase + 36'u)[]",
        "cast[ptr uint32](dmaBase + 40'u)[]",
        "cast[ptr uint32](dmaBase + 44'u)[]",
        "cast[ptr uint32](dmaBase + 48'u)[]",
    ]:
        assert forbidden not in policy_body
        assert forbidden not in alloc_body


def test_wifi_apm_tx_ps_check_uses_typed_sta_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc apm_tx_int_ps_check*(txDesc: pointer): bool {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc apm_tx_int_ps_postpone*", 1
    )[0]

    assert "doAssert offsetof(StaInfoView, rateSet) == 32" in wifi_fw
    assert "let tx = apmTxDescPsAt(txDesc)" in body
    assert "let staRateInfo = staInfoAt(staPeerPtr).rateSet" in body
    assert "let linkDesc = hostTxLinkDescAt(staDescPtr)" in body
    assert "let vifType = vifChannelForIdx(0).vifType" in body
    assert "let psState = staInfoForIdx(staInstNbr).psMode" in body

    for forbidden in [
        "let staPeerU = cast[uint](staPeerPtr)",
        "cast[ptr uint16](staPeerU + 32)",
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "vifChannelAt(vifBase).vifType",
    ]:
        assert forbidden not in body


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
    assert "let acReady = txStatus and 0x7C0'u32" in trigger_body
    assert "let acReadyHigh = txStatus and 0x000F8000'u32" in trigger_body
    assert "if acReady == 0 and acReadyHigh == 0:" in trigger_body
    assert "var drained = 0'u32" in trigger_body
    assert "while drained < WifiTxTriggerDrainLimit:" in trigger_body
    assert "while true:" not in trigger_body
    assert "inc drained" in trigger_body
    assert "if txlTriggerPending(acCtrl):" in trigger_body
    assert "inc nimFwDbgTxTrigYield" in trigger_body


def test_wifi_tx_trigger_uses_typed_link_overlay_for_frame_control():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    trigger_body = wifi_fw.split(
        "proc txl_transmit_trigger*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_current_desc_get*", 1
    )[0]

    assert "let linkTrace = hostTxBufferedLinkAt(linkPtrTrace)" in trigger_body
    assert "linkTrace.macHeader[0]" in trigger_body
    assert "linkTrace.macHeader[1]" in trigger_body
    assert "linkUTrace + 348" not in trigger_body
    assert "linkUTrace + 349" not in trigger_body
    assert "nimFwDbgTxTrigYieldAc = ac" in trigger_body
    assert "nimFwDbgTxTrigYieldHead = pointerAddrU32(cast[pointer](acCtrl.pending.first))" in trigger_body
    assert "blmac_abs_timer_set(ac, ipcBase + TX_TIMEOUT_LOCAL[ac])" in trigger_body
    yield_body = trigger_body.split("if txlTriggerPending(acCtrl):", 1)[1]
    assert "regWrite(MACHW_TX_TRIG_STAT" not in yield_body


def test_wifi_machw_tx_queue_regs_use_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    payload_body = wifi_fw.split(
        "proc txl_payload_handle_backup*(param: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txlTriggerPending",
        1,
    )[0]
    trigger_body = wifi_fw.split(
        "proc txl_transmit_trigger*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_current_desc_get*",
        1,
    )[0]

    assert "MachwTxQueueRegsView {.packed.} = object" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, txStatus) == 0x78" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, readyAck) == 0x7C" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, txTrigger) == 0x180" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, dmaStatus) == 0x188" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, ac0Head) == 0x19C" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, ac3Head) == 0x1A8" in wifi_fw
    for helper in [
        "proc machwTxStatus(): uint32",
        "proc machwTxReadyAck(bits: uint32)",
        "proc machwTxTrigger(bits: uint32)",
        "proc machwTxDmaStatus(): uint32",
        "proc machwTxAggActive(): uint32",
        "proc machwTxAggSet(bits: uint32)",
        "proc machwTxAggActiveSet(bits: uint32)",
        "proc machwTxHeadValue(ac: uint32): uint32",
        "proc machwTxSetHead(ac: uint32; thd: pointer)",
    ]:
        assert helper in wifi_fw

    for raw_reg in [
        "0x24B08180",
        "0x24B08188",
        "0x24B08198",
        "0x24B0819C",
        "0x24B081A0",
        "0x24B081A4",
        "0x24B081A8",
        "0x24B08078",
        "0x24B0807C",
        "0x24B08088",
        "0x24B0808C",
        "MACHW_TX_STATUS_REG",
        "MACHW_TX_TRIG_STAT",
    ]:
        assert raw_reg not in payload_body
        assert raw_reg not in trigger_body

    assert "machwTxDmaStatus()" in payload_body
    assert "machwTxSetHead(ac, thdLink)" in payload_body
    assert "nimFwDbgPayTxHead = machwTxHeadValue(ac)" in payload_body
    assert "machwTxTrigger(trigBits)" in payload_body
    assert "machwTxTrigger(triggerVal)" in payload_body
    assert "machwTxAggSet(acBit)" in payload_body
    assert "machwTxAggActiveSet(acBit or aggOr)" in payload_body
    assert "let txStatus = machwTxStatus()" in trigger_body
    assert "machwTxReadyAck(readyBit)" in trigger_body
    assert "let intcStat = machwTxAggActive()" in trigger_body
    assert "machwTxAggActiveSet(intcStat and clearMask)" in trigger_body


def test_wifi_tx_buffer_eapol_trace_uses_typed_rate_template_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc txl_buffer_alloc*(param: pointer, queueIdx: uint32, flags: uint32): pointer {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_buffer_update_thd*",
        1,
    )[0]

    assert "let rateTemplate = hostTxRateTemplate(bufLink)" in body
    assert "rateTemplate.magic" in body
    assert "rateTemplate.ntxConfig" in body
    assert "rateTemplate.rateWord" in body
    assert "rateTemplate.txPower" in body
    assert "rateTemplate.word48" in body
    assert "let dmaBase = cast[uint](rateTemplate)" not in body
    assert "dmaBase + 4" not in body
    assert "dmaBase + 20" not in body
    assert "dmaBase + 36" not in body
    assert "dmaBase + 52" not in body


def test_wifi_txl_current_desc_get_uses_typed_hwdesc_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc txl_current_desc_get*(ac: uint8): pointer {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_reset*", 1
    )[0]

    assert "doAssert offsetof(HostTxHwDescView, magic) == 4" in wifi_fw
    assert "return cast[pointer](addr hostTxHwDescAt(txDesc).magic)" in body
    assert "return cast[pointer](cast[uint](txDesc) + 4)" not in body


def test_wifi_tx_frame_event_drains_pending_confirmations():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    frame_body = wifi_fw.split(
        "proc txl_frame_evt*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_frame_send_null_frame*", 1
    )[0]

    assert "proc txlFrameConfirmPending(frameEnv: ptr TxFrameEnvView): bool" in wifi_fw
    assert "while txlFrameConfirmPending(frameEnv):" in frame_body
    assert "while true:" not in frame_body
    assert "while drained < WifiTxFrameDrainLimit" not in frame_body
    assert "if txlFrameConfirmPending(frameEnv):" not in frame_body
    assert "inc nimFwDbgFrameEvtYield" not in frame_body
    assert "nimFwDbgFrameEvtYieldHead =" not in frame_body
    retry_body = frame_body.split("if desc.retryFlag != 0:", 1)[1].split(
        "continue  # re-process", 1
    )[0]
    assert "inc drained" not in retry_body


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
    assert "desc.bufDesc = cast[pointer](txlFrameLinkDescAt(idx))" in get_body
    assert "return cast[pointer](freeNode)" in get_body
    assert get_body.rstrip().endswith("nil")

    for forbidden in [
        "let linkPoolBase = cast[uint](addr txl_frame_pool[0])",
        "desc.bufDesc = cast[pointer](linkPoolBase + idx * 860'u)",
    ]:
        assert forbidden not in get_body


def test_wifi_tx_frame_push_uses_typed_mac_header_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    push_body = wifi_fw.split(
        "proc txl_frame_push*(param: pointer, ac: uint8): uint8 {.exportc, cdecl, noinline, discardable.} =",
        1,
    )[1].split(
        "proc txl_frame_push_force*", 1
    )[0]
    force_body = wifi_fw.split(
        "proc txl_frame_push_force*(param: pointer, ac: uint8) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_frame_cfm*", 1
    )[0]

    for body in [push_body, force_body]:
        assert "let hdr = macDataFrameAt(cast[pointer](thdField.uint))" in body
        assert "hdr.addr1[0]" in body
        assert "cast[ptr uint8](cast[uint](thdPtr) + 4)" not in body
        assert "let thdPtr = thdField" not in body

    assert "let typeBits = cast[uint8](hdr.frameControl and 0x000C'u16)" in push_body
    assert "cast[ptr uint8](cast[uint](thdPtr))[]" not in push_body
    assert "let thdByte4 =" not in force_body


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
    assert "proc rxlScheduleQueuedRx(env: ptr RxlCntrlEnvView)" in wifi_fw
    assert "var drained = 0'u32" in rx_body
    assert "template scheduleQueuedRx()" not in rx_body
    assert "while drained < WifiRxTimerDrainLimit and submittedRxReady(env.submittedHead):" in rx_body
    assert "while true:" not in rx_body
    assert "if submittedRxReady(env.submittedHead):" in rx_body
    assert "inc nimFwDbgRxTimerYield" in rx_body
    assert "nimFwDbgRxTimerYieldHead = pointerAddrU32(env.submittedHead)" in rx_body
    assert "rxlScheduleQueuedRx(env)" in rx_body
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
    assert "let swDesc = rxMpduDescView(curHwDesc).swDesc" in rx_body
    assert "cast[ptr pointer](cast[uint](curHwDesc) + 4)" not in rx_body


def test_wifi_rx_control_event_uses_typed_vif_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    rx_body = wifi_fw.split(
        "proc rxl_cntrl_evt*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rxl_timer_int_handler*",
        1,
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let vifEntry = cast[pointer](vif)",
        "apm_tx_int_ps_clear(vifEntry, staIdx)",
        "discard sta_mgmt_send_postponed_frame(vifEntry,",
        "let postVif = vifChannelForIdx(sta.instNbr)",
        "let postVifEntry = cast[pointer](postVif)",
        "td_pck_ind(postVif.vifIdx, 1)",
        "let pVif = postVifEntry",
        "if postVif.chanCtxt != nil:",
        "chan_tbtt_switch_update(pVif, postVif.tbttTimer.expiry)",
        "let postVif2 = vifChannelForIdx(sta.instNbr)",
        "postVif2.psBaCounter = postVif2.psBaCounter + 1",
    ]:
        assert expected in rx_body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntryU = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let postVifEntryU = vifBase + sta.instNbr.uint * VIF_ENTRY_SIZE.uint",
        "let postVif2 = vifBase + sta.instNbr.uint * VIF_ENTRY_SIZE.uint",
        "vifChannelAt(postVif2)",
        "cast[pointer](vifEntryU)",
    ]:
        assert forbidden not in rx_body


def test_wifi_rx_mpdu_free_uses_explicit_descriptor_chain_condition():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    free_body = wifi_fw.split(
        "proc rxl_mpdu_free*(desc: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rxl_mpdu_transfer*",
        1,
    )[0]

    assert "var curHw = rxDmaProgressDescAt(sw.bufferChain)" in free_body
    assert "while curHw != nil:" in free_body
    assert "while true:" not in free_body
    assert "let hwStatus = curHw.status" in free_body
    assert "curHw.usedFlag = 0" in free_body
    assert "curHw = rxDmaProgressDescAt(curHw.next)" in free_body
    assert 'assert_rec("rxl_hwdesc.c", "rxl_hwdesc.c", 872)' in free_body


def test_wifi_rxl_reset_uses_rxu_upload_list_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc rxl_reset*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rxl_hwdesc_dump*",
        1,
    )[0]

    assert "doAssert offsetof(RxuCntrlEnvView, uploadList) == 64" in wifi_fw
    assert "co_list_init(addr rxuCntrlEnvView().uploadList)" in body
    assert "rxu_cntrl_env + 0x40" not in body
    assert "{.emit:" not in body


def test_wifi_debug_snapshot_exports_unpacked_mac_rx_registers():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    smoke = (ROOT / "examples/m0_wifi_lwip_smoke.nim").read_text()

    body = wifi_fw.split(
        "proc wifi_nimfw_debug_snapshot*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc ke_timer_hw_set*",
        1,
    )[0]

    for symbol in [
        "nimfw_dbg_rxl_snap_int_unmask",
        "nimfw_dbg_rxl_snap_gen_unmask",
        "nimfw_dbg_rxl_snap_rxctrl_raw",
        "nimfw_dbg_rxl_snap_status_raw",
    ]:
        assert symbol in wifi_fw
        assert symbol in smoke

    assert "nimFwDbgRxlSnapIntUnmask = regRead(MACHW_INTC_UNMASK_REG)" in body
    assert "nimFwDbgRxlSnapGenUnmask = regRead(MACHW_INTC_IRQ_STAT_REG)" in body
    assert "nimFwDbgRxlSnapRxCtrlRaw = regRead(MACHW_RX_CNTRL_REG)" in body
    assert "nimFwDbgRxlSnapStatusRaw = regRead(MACHW_STATUS_REG)" in body
    assert "nimFwDbgRxlSnapHd = machwRxHdSubmittedHead()" in body
    assert "nimFwDbgRxlSnapPd = machwRxPdSubmittedHead()" in body
    assert "nimFwDbgRxlSnapHwHd = machwRxHwHdHead()" in body
    assert "nimFwDbgRxlSnapHwPd = machwRxHwPdHead()" in body
    for raw_reg in [
        "0x24B081B8",
        "0x24B081BC",
        "0x24B08548",
        "0x24B0854C",
    ]:
        assert raw_reg not in body
    assert "kvWrite(\"intmsk\", nimfw_dbg_rxl_snap_int_unmask)" in smoke
    assert "kvWrite(\"rxctrl\", nimfw_dbg_rxl_snap_rxctrl_raw)" in smoke


def test_wifi_smoke_dumps_auth_tx_raw_frame_snapshot():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    smoke = (ROOT / "examples/m0_wifi_lwip_smoke.nim").read_text()

    body = wifi_fw.split(
        "proc sm_auth_send*(authSeqNum: uint16, statusCode: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc sm_auth_send_pre*",
        1,
    )[0]

    for symbol in [
        "nimfw_dbg_auth_tx_len",
        "nimfw_dbg_auth_tx_meta",
        "nimfw_dbg_auth_tx_desc",
        "nimfw_dbg_auth_tx_raw",
    ]:
        assert symbol in wifi_fw
        assert symbol in smoke

    assert "nimFwDbgAuthTxRaw*       {.wifiCtrl, exportc: \"nimfw_dbg_auth_tx_raw\".}: array[96, uint8]" in wifi_fw
    assert "discard c_memcpy(addr nimFwDbgAuthTxRaw[0]," in body
    assert "cast[pointer](addr link.macHeader[0])" in body
    assert "kvWrite(\"auth_tx_len\", nimfw_dbg_auth_tx_len)" in smoke
    assert "kvWrite(\"auth_tx0\", loadLe32(nimfw_dbg_auth_tx_raw, 0))" in smoke
    assert "kvWrite(\"auth_tx28\", loadLe32(nimfw_dbg_auth_tx_raw, 28))" in smoke


def test_wifi_rate_retry_scan_uses_typed_rate_reset_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc rc_update_retry_chain*(stats: pointer, param: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rc_update_stats*",
        1,
    )[0]

    assert "template rcRateResetFields(stats: pointer, idx: uint16): ptr RcRateResetFieldsView" in wifi_fw
    assert "rcRateResetFields(stats, scanIdx.uint16).initialized = 0" in body
    assert "scanEntryBase + 15" not in body


def test_wifi_rx_hwdesc_init_uses_typed_descriptor_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    sw_body = wifi_fw.split(
        "proc rx_swdesc_init*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rxl_hwdesc_init*", 1
    )[0]
    init_body = wifi_fw.split(
        "proc rxl_hwdesc_init*(resetAll: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rxl_init*", 1
    )[0]
    append_body = wifi_fw.split(
        "proc rxl_hd_append*(desc: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rxl_pd_append*", 1
    )[0]
    pd_append_body = wifi_fw.split(
        "proc rxl_pd_append*(swdesc: pointer, prevDesc: pointer, pddesc: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rxl_frame_release*", 1
    )[0]

    for expected in [
        "MachwRxDmaRegsView {.packed.} = object",
        "doAssert offsetof(MachwRxDmaRegsView, trigger) == 0x180",
        "doAssert offsetof(MachwRxDmaRegsView, hdSubmittedHead) == 0x1B8",
        "doAssert offsetof(MachwRxDmaRegsView, pdSubmittedHead) == 0x1BC",
        "doAssert offsetof(MachwRxDmaRegsView, hdHwHead) == 0x548",
        "doAssert offsetof(MachwRxDmaRegsView, pdHwHead) == 0x54C",
        "template machwRxDmaRegs(): ptr MachwRxDmaRegsView",
        "proc machwRxDmaTrigger(bits: uint32)",
        "proc machwRxHdSubmittedHead(): uint32",
        "proc machwRxPdSubmittedHead(): uint32",
        "proc machwRxHwHdHead(): uint32",
        "proc machwRxHwPdHead(): uint32",
        "proc machwRxSetHdSubmittedHead(value: uint32)",
        "proc machwRxSetPdSubmittedHead(value: uint32)",
        "RxHeaderHwDescView {.packed.} = object",
        "RxSwTableDescView {.packed.} = object",
        "RxPayloadBufferView {.packed.} = object",
        "doAssert sizeof(RxHeaderHwDescView) == 100",
        "doAssert sizeof(RxSwTableDescView) == 24",
        "doAssert sizeof(RxPayloadHwDescView) == 52",
        "template rxHeaderHwDescAt(idx: int): ptr RxHeaderHwDescView",
        "template rxHeaderHwDescView(param: pointer): ptr RxHeaderHwDescView",
        "template rxSwTableDescAt(idx: int): ptr RxSwTableDescView",
        "template rxPayloadHwDescAt(idx: int): ptr RxPayloadHwDescView",
        "template rxPayloadBufferAt(idx: int): ptr RxPayloadBufferView",
    ]:
        assert expected in wifi_fw

    assert "rxSwTableDescAt(i).firstHeaderDesc = cast[pointer](rxHeaderHwDescAt(i))" in sw_body
    for expected in [
        "let hd = rxHeaderHwDescAt(i)",
        "let dmaOwned = hd.usedFlag",
        "cast[ptr RxHeaderHwDescView](hdPrev).next = cast[pointer](hd)",
        "hd.nextThd = 0",
        "hd.status = 0",
        "hd.flags = 0",
        "hd.swDesc = cast[uint32](rxSwTableDescAt(i))",
        "hd.magic = BAADF00D",
        "let pd = rxPayloadHwDescAt(i)",
        "let dmaOwned = pd.usedFlag",
        "cast[ptr RxPayloadHwDescView](pdPrev).next = cast[pointer](pd)",
        "let buf = rxPayloadBufferAt(i)",
        "pd.magic = C0DEDBAD",
        "pd.status = 0",
        "pd.bufferAddr = cast[uint32](addr buf.bytes[0])",
        "pd.bufferEnd = cast[uint32](addr buf.bytes[1735])",
        "pd.bufferStart = cast[uint32](addr buf.bytes[0])",
        "machwRxSetHdSubmittedHead(cast[uint32](hdHead))",
        "machwRxDmaTrigger(0x04000000'u32)",
        "machwRxSetPdSubmittedHead(cast[uint32](pdHead))",
        "machwRxDmaTrigger(0x08000000'u32)",
    ]:
        assert expected in init_body

    for expected in [
        "let hd = rxHeaderHwDescView(appendDesc)",
        "hd.next = nil",
        "hd.bufferAddr = 0",
        "hd.flags = 0",
        "hd.statusHalf = 0",
        "rxHeaderHwDescView(lastPtr).next = appendDesc",
        "let hwHead = machwRxHwHdHead()",
        "machwRxDmaTrigger(0x10000000'u32)",
    ]:
        assert expected in append_body

    for expected in [
        "let hwPdHead = machwRxHwPdHead()",
        "machwRxDmaTrigger(0x20000000'u32)",
    ]:
        assert expected in pd_append_body

    for forbidden in [
        "cast[ptr pointer](swBase + i * 24'u + 4'u)",
        "let hdAddr = hdBase + i.uint * HD_STRIDE.uint",
        "cast[ptr uint32](hdAddr + 96)",
        "cast[ptr pointer](cast[uint](hdPrev) + 4)",
        "cast[ptr uint32](hdAddr + 16)",
        "cast[ptr uint32](hdAddr + 20)",
        "cast[ptr uint32](hdAddr + 64)",
        "cast[ptr uint32](hdAddr + 24)",
        "cast[ptr uint32](hdAddr + 8)",
        "cast[ptr uint32](hdAddr + 12)",
        "cast[ptr uint32](hdAddr + 0)",
        "cast[ptr uint32](hdAddr + 4)",
        "cast[ptr uint16](hdAddr + 28)",
        "let pdAddr = cast[uint](addr rx_payload_desc[0]) + i.uint * PD_STRIDE.uint",
        "cast[ptr uint32](pdAddr + 20)",
        "cast[ptr pointer](cast[uint](pdPrev) + 4)",
        "cast[ptr uint32](pdAddr + 0)",
        "cast[ptr uint32](pdAddr + 4)",
        "cast[ptr uint32](pdAddr + 16)",
        "cast[ptr uint32](pdAddr + 8)",
        "cast[ptr uint32](pdAddr + 12)",
        "cast[ptr uint32](pdAddr + 24)",
        "0x24B081B8",
        "0x24B081BC",
        "0x24B08180",
    ]:
        assert forbidden not in sw_body
        assert forbidden not in init_body

    for forbidden in [
        "let dAddr = cast[uint](appendDesc)",
        "cast[ptr uint32](dAddr + 4)",
        "cast[ptr uint32](dAddr + 8)",
        "cast[ptr uint32](dAddr + 64)",
        "cast[ptr uint16](dAddr + 28)",
        "cast[ptr uint32](cast[uint](lastPtr) + 4)",
        "0x24B08548",
        "0x24B0854C",
        "0x24B08180",
    ]:
        assert forbidden not in append_body
        assert forbidden not in pd_append_body


def test_wifi_rxl_hwdesc_dump_uses_typed_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    dump_body = wifi_fw.split("proc rxl_hwdesc_dump*", 1)[1].split(
        "proc rxl_hd_append*", 1
    )[0]

    for expected in [
        "let hd = rxHeaderHwDescAt(i.int)",
        "hd.magic",
        "pointerAddrU32(hd.next)",
        "hd.statusHalf2",
        "hd.word44",
        "let pd = rxPayloadHwDescAt(i.int)",
        "pd.bufferEnd + 1 - pd.bufferStart",
        "pointerAddrU32(pd.next)",
    ]:
        assert expected in dump_body

    for forbidden in [
        "let hdBase = cast[uint](addr rx_dma_hdrdesc[0])",
        "let hdAddr = hdBase + i * 100",
        "let pdAddr = hdBase + 41'u * 100 + i * 52",
        "cast[ptr uint32](hdAddr +",
        "cast[ptr uint16](hdAddr +",
        "cast[ptr uint32](pdAddr +",
        "cast[ptr uint16](pdAddr +",
    ]:
        assert forbidden not in dump_body


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


def test_wifi_chan_get_next_uses_typed_vif_overlay_for_roc_lookup():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc chan_get_next_chan*(): pointer {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc chan_switch_start*", 1
    )[0]

    assert "let rocNode = chanTbttNodeAt(rocChan)" in body
    assert "if rocNode.state == 2:" in body
    assert "let rocDeadline = rocNode.targetTime" in body
    assert "best = vifChannelForIdx(rocNode.vifIdx).chanCtxt" in body
    assert "let cand = chanCtxtForIdx(i)" in body
    assert "if cand.status != 0:" in body
    assert "let candPrio = cand.opSlot" in body
    assert "best = cast[pointer](cand)" in body
    assert "let rocIdx = cast[ptr uint8](cast[uint](rocChan) + 8)[]" not in body
    assert "let rocType = cast[ptr uint8](cast[uint](rocChan) + 10)[]" not in body
    assert "let rocDeadline = cast[ptr uint32](cast[uint](rocChan) + 4)[]" not in body
    assert "let vifBase = cast[uint](addr vif_info_tab[0]) + rocIdx.uint * VIF_ENTRY_SIZE.uint" not in body
    assert "vifChannelAt(vifBase).chanCtxt" not in body
    assert "let chanBase = cast[uint](env)" not in body
    assert "let candBase = chanBase + 80" not in body
    assert "let candAddr = candBase + (i * 28).uint" not in body
    assert "cast[ptr uint8](candAddr + 22)[]" not in body
    assert "cast[ptr uint16](candAddr + 18)[]" not in body


def test_wifi_channel_tx_power_uses_typed_vif_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc chan_update_tx_power*", 1)[1].split(
        "proc chan_conn_less_delay_evt*", 1
    )[0]

    for expected in [
        "let vif0 = vifChannelForIdx(0)",
        "let vif0Ctxt = vif0.chanCtxt",
        "let p0 = vif0.txPower",
        "let p1 = vif0.maxTxPower",
        "let vif1 = vifChannelForIdx(1)",
        "let vif1Ctxt = vif1.chanCtxt",
        "let p0 = vif1.txPower",
        "let p1 = vif1.maxTxPower",
    ]:
        assert expected in body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "vifChannelAt(vifBase)",
        "let vif1 = vifBase + VIF_ENTRY_SIZE.uint",
        "vifChannelAt(vif1)",
    ]:
        assert forbidden not in body


def test_wifi_channel_scan_roc_slots_use_typed_context_pool_helpers():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    pre_body = wifi_fw.split(
        "proc chan_pre_switch_channel*(ctxt: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc chan_conn_less_delay_evt*",
        1,
    )[0]
    delay_body = wifi_fw.split(
        "proc chan_conn_less_delay_evt*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc chan_cde_evt*",
        1,
    )[0]
    roc_body = wifi_fw.split(
        "proc chan_roc_req*(param: pointer) {.exportc, cdecl, noinline.} =",
        1,
    )[1].split(
        "proc chan_bcn_to_evt*",
        1,
    )[0]

    assert "targetCtxt = cast[pointer](chanCtxtForIdx(3))" in pre_body
    assert "targetCtxt = cast[pointer](chanCtxtForIdx(4))" in pre_body
    assert "switchArg = cast[pointer](chanCtxtForIdx(3))" in delay_body
    assert "switchArg = cast[pointer](chanCtxtForIdx(4))" in delay_body
    assert "chan_switch_start(cast[pointer](chanCtxtForIdx(4)))" in roc_body

    for body in [pre_body, delay_body, roc_body]:
        assert "poolBase + 0x54" not in body
        assert "poolBase + 0x70" not in body
        assert "4 * CHAN_CTXT_SIZE.uint" not in body


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


def test_wifi_ipc_message_payload_copy_uses_typed_word_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    push_body = wifi_fw.split(
        "proc ipc_emb_msg_push*(msgDescPtr: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc ipc_emb_init*", 1
    )[0]
    evt_body = wifi_fw.split(
        "proc ipc_emb_msg_evt*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc ipc_emb_radar_event_ind*", 1
    )[0]

    for expected in [
        "IpcEmbMsgEnvelopeView {.packed.} = object",
        "desc*: IpcEmbMsgDescView",
        "payload*: UncheckedArray[uint8]",
        "IpcPayloadWordStreamView {.packed.} = object",
        "words*: UncheckedArray[uint32]",
        "doAssert offsetof(IpcEmbMsgEnvelopeView, desc) == 0",
        "doAssert offsetof(IpcEmbMsgEnvelopeView, payload) == 8",
        "template ipcPayloadWordStreamAt(payload: pointer): ptr IpcPayloadWordStreamView",
        "proc copyIpcPayloadWords(dst, src: pointer; byteLen: uint32)",
        "dstWords.words[wordIdx] = srcWords.words[wordIdx]",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let msg = cast[ptr IpcEmbMsgEnvelopeView](msgDescPtr)",
        "let msgDesc = addr msg.desc",
        "copyIpcPayloadWords(addr shared.payload[0], addr msg.payload[0],",
    ]:
        assert expected in push_body

    assert "copyIpcPayloadWords(keMsgPayload(hdr), addr shared.payload[0], msgParamLen)" in evt_body

    for forbidden in [
        "let paySrc = cast[uint](msgDescPtr) + IpcEmbMsgDescViewSize.uint",
        "let v = cast[ptr uint32](paySrc + cursor.uint)[]",
        "cast[ptr uint32](addr shared.payload[cursor])[] = v",
        "let srcWord = cast[ptr uint32](addr shared.payload[cursor])[]",
        "cast[ptr uint32](addr payload[cursor])[] = srcWord",
    ]:
        assert forbidden not in push_body
        assert forbidden not in evt_body


def test_wifi_ipc_tx_event_yields_under_host_descriptor_backlog():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    tx_body = wifi_fw.split(
        "proc ipc_emb_tx_evt*(ac: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc ipc_emb_cfmback_irq*", 1
    )[0]

    assert "WifiIpcTxDrainLimit = 16'u32" in wifi_fw
    assert "nimfw_dbg_ipc_tx_yield" in wifi_fw
    assert "nimfw_dbg_ipc_tx_yield_ac" in wifi_fw
    assert "nimfw_dbg_ipc_tx_yield_head" in wifi_fw
    assert "var drained = 0'u32" in tx_body
    assert "while drained < WifiIpcTxDrainLimit and wrapper != nil:" in tx_body
    assert "while wrapper != nil:" not in tx_body
    assert "while descPtr != nil:" not in tx_body
    assert "inc drained" in tx_body
    assert "if wrapper != nil:" in tx_body
    assert "inc nimFwDbgIpcTxYield" in tx_body
    assert "nimFwDbgIpcTxYieldAc = ac" in tx_body
    assert "nimFwDbgIpcTxYieldHead = pointerAddrU32(cast[pointer](wrapper))" in tx_body
    assert "ke_evt_set(eventMask)" in tx_body
    yield_body = tx_body.split("if wrapper != nil:", 1)[1].split(
        "# No more descriptors:", 1
    )[0]
    assert "volatileStore(cast[ptr uint32](0x2480010C'u), 256'u32)" not in yield_body


def test_wifi_saved_messages_reschedule_in_bounded_batches():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    hdr_body = wifi_fw.split("template keMsgHdrFromPayload*", 1)[1].split(
        "template keMsgPayload*", 1
    )[0]
    payload_body = wifi_fw.split("template keMsgPayload*", 1)[1].split(
        "template keMsgExternalPayload*", 1
    )[0]
    resched_body = wifi_fw.split("proc ke_reschedule_saved_messages", 1)[1].split(
        "proc ke_task_local*", 1
    )[0]
    state_body = wifi_fw.split("proc ke_state_set*", 1)[1].split(
        "proc ke_state_get*", 1
    )[0]
    schedule_body = wifi_fw.rsplit("proc ke_task_schedule*", 1)[1].split(
        "proc ke_task_sm_activating*", 1
    )[0]
    handler_body = wifi_fw.split("proc ke_handler_search*", 1)[1].split(
        "proc keResumeSavedMessagesIfIdle", 1
    )[0]

    assert "WifiSavedMsgDrainLimit = 8'u32" in wifi_fw
    assert "KeMsgConsumed = 0.cint" in wifi_fw
    assert "KeMsgNoFree = 1.cint" in wifi_fw
    assert "KeMsgSaved = 2.cint" in wifi_fw
    assert "return KeMsgConsumed" in wifi_fw
    assert "return KeMsgSaved" in wifi_fw
    assert "KeMsgEnvelope* {.packed.} = object" in wifi_fw
    assert "doAssert offsetof(KeMsgEnvelope, header) == 0" in wifi_fw
    assert "doAssert offsetof(KeMsgEnvelope, payload) == int(KeMsgHdrSize)" in wifi_fw
    assert "addr envelope.header" in hdr_body
    assert "addr envelope.payload[0]" in payload_body
    assert "cast[uint](param) - KeMsgHdrSize" not in hdr_body
    assert "cast[uint](hdr) + KeMsgHdrSize" not in payload_body
    assert "keSavedReschedTask* {.wifiCtrl.}: uint8 = TASK_NONE" in wifi_fw
    assert "nimfw_dbg_saved_msg_yield" in wifi_fw
    assert "nimfw_dbg_saved_msg_yield_task" in wifi_fw
    assert "proc ke_saved_queue_has_dest" in wifi_fw
    assert "KeMsgHandlerEntry* {.packed.} = object" in wifi_fw
    assert "keMsgHandlerEntryAt(table: pointer, idx: uint16): ptr KeMsgHandlerEntry" in wifi_fw
    assert "keMsgHandlerDescAt(table: pointer, state: uint16): ptr KeMsgHandlerDesc" in wifi_fw
    assert "let entry = keMsgHandlerEntryAt(table, i.uint16)" in handler_body
    assert "if uint16(entry.msgId) == msgId:" in handler_body
    assert "return entry.handler" in handler_body
    assert "let stateDesc = keMsgHandlerDescAt(desc.stateTable, curState)" in schedule_body
    assert "entryBase = cast[uint](table)" not in handler_body
    assert "cast[uint](desc.stateTable)" not in schedule_body
    assert "while moved < limit:" in resched_body
    assert "keSavedReschedTask = taskId" in resched_body
    assert "inc nimFwDbgSavedMsgYield" in resched_body
    assert "nimFwDbgSavedMsgYieldTask = taskId.uint32" in resched_body
    assert "ke_evt_set(KE_EVT_KE_MESSAGE)" in resched_body
    assert "discard ke_reschedule_saved_messages(taskId)" in state_body
    assert "while true:" not in state_body
    assert "proc keResumeSavedMessagesIfIdle()" in wifi_fw
    assert "proc keUpdateMessageEventAfterSchedule()" in wifi_fw
    assert "keResumeSavedMessagesIfIdle()" in schedule_body
    assert "keUpdateMessageEventAfterSchedule()" in schedule_body
    assert "rawRes >= KeMsgConsumed and rawRes <= KeMsgSaved" in schedule_body
    assert "KeMsgConsumed" in schedule_body
    assert "of KeMsgConsumed:" in schedule_body
    assert "of KeMsgNoFree:" in schedule_body
    assert "of KeMsgSaved:" in schedule_body
    assert "of 0:" not in schedule_body
    assert "of 1:" not in schedule_body
    assert "of 2:" not in schedule_body
    assert "discard ke_reschedule_saved_messages(keSavedReschedTask)" not in schedule_body
    assert "ke_evt_clear(KE_EVT_KE_MESSAGE)" not in schedule_body


def test_wifi_task_handlers_use_named_ke_message_statuses():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    def body(start, end):
        return wifi_fw.split(start, 1)[1].split(end, 1)[0]

    def assert_no_raw_scheduler_returns(handler_body):
        assert "return 0" not in handler_body
        assert "return 1" not in handler_body
        assert "return 2" not in handler_body

    mm_hw = body(
        "proc mm_hw_config_handler*",
        "{.emit: \"__attribute__((optimize(\\\"crossjumping\\\"))) int mm_set_idle_req_handler",
    )
    mm_set_idle = body(
        "proc mm_set_idle_req_handler*",
        "proc mm_set_idle_cfm_handler*",
    )
    mm_set_idle_cfm = body(
        "proc mm_set_idle_cfm_handler*",
        "proc mm_sta_add_req_handler*",
    )
    mm_set_ps_mode_cfm = body(
        "proc mm_set_ps_mode_cfm_handler*",
        "proc mm_set_ps_options_req_handler*",
    )
    mm_force_idle = body(
        "proc mm_force_idle_req_handler*",
        "proc mm_remain_on_channel_req_handler*",
    )
    scan_start = body(
        "proc scan_start_req_handler*",
        "proc scan_start_cfm_handler*",
    )
    scan_finish = body(
        "proc finishAcceptedScanStartReq*",
        "proc cacheScanuStartRequest*",
    )
    scanu_start = body(
        "proc scanu_start_req_handler*",
        "{.emit: \"__attribute__((optimize(\\\"crossjumping\\\"))) void scanu_start_cfm_handler",
    )
    sm_connect = body(
        "proc sm_connect_req_handler*",
        "proc sm_disconnect_req_handler*",
    )
    sm_disconnect = body(
        "proc sm_disconnect_req_handler*",
        "proc sm_connect_abort_req_handler*",
    )
    me_set_active = body(
        "proc me_set_active_req_handler*",
        "proc smSetActiveCfmStateAllowed",
    )
    me_set_ps_disable = body(
        "proc me_set_ps_disable_req_handler*",
        "proc me_set_ps_disable_cfm_handler_sm*",
    )

    assert "return KeMsgSaved" in mm_hw
    assert "return KeMsgConsumed" in mm_hw
    assert "return KeMsgSaved" in mm_set_idle
    assert "return KeMsgConsumed" in mm_set_idle
    assert "let connIdx = meEnvView().psMode" in mm_set_idle_cfm
    assert "let marker = meEnvView().psMode" in mm_set_ps_mode_cfm
    assert "return KeMsgSaved" in mm_force_idle
    assert "return KeMsgConsumed" in mm_force_idle

    assert "return finishAcceptedScanStartReq(param)" in scan_start
    assert "return KeMsgConsumed" in scan_start
    assert "return KeMsgNoFree" in scan_finish
    assert "if param == nil: return KeMsgConsumed" in scanu_start
    assert "return KeMsgNoFree" in scanu_start

    assert "if param == nil: return KeMsgConsumed" in sm_connect
    assert "return KeMsgSaved" in sm_connect
    assert "return KeMsgNoFree" in sm_connect
    assert "return KeMsgConsumed" in sm_connect
    assert "return KeMsgSaved" in sm_disconnect
    assert "return KeMsgConsumed" in sm_disconnect

    assert "return KeMsgSaved" in me_set_active
    assert "return KeMsgConsumed" in me_set_active
    assert "return KeMsgSaved" in me_set_ps_disable
    assert "return KeMsgConsumed" in me_set_ps_disable

    for handler_body in (
        mm_hw,
        mm_set_idle,
        mm_force_idle,
        scan_start,
        scan_finish,
        scanu_start,
        sm_connect,
        sm_disconnect,
        me_set_active,
        me_set_ps_disable,
    ):
        assert_no_raw_scheduler_returns(handler_body)

    for handler_body in (mm_set_idle_cfm, mm_set_ps_mode_cfm):
        assert "cast[ptr uint8](cast[uint](addr me_env[0]) + 0x7E)" not in handler_body
        assert "cast[ptr uint8](meBase + 0x7E)" not in handler_body


def test_wifi_connect_info_channel_hint_uses_typed_frequency_helper():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    bss_body = wifi_fw.rsplit(
        "proc sm_get_bss_params*", 1
    )[1].split(
        "proc sm_scan_bss*", 1
    )[0]
    connect_body = wifi_fw.split(
        "proc sm_connect_req_handler*", 1
    )[1].split(
        "proc sm_disconnect_req_handler*", 1
    )[0]

    for expected in [
        "proc connectInfoChannelFrequency(ci: ptr ConnectInfoView): uint16",
        "uint16(ci.channelHint[0]) or (uint16(ci.channelHint[1]) shl 8)",
        "proc connectInfoHasChannelHint(ci: ptr ConnectInfoView): bool",
        "freq != 0'u16 and freq != 0xFFFF'u16",
        "doAssert offsetof(ConnectInfoView, channelHint) == 40",
    ]:
        assert expected in wifi_fw

    assert bss_body.count("connectInfoHasChannelHint(ci)") == 3
    assert "if connectInfoHasChannelHint(req):" in connect_body

    for forbidden in [
        "let freqHint = connectInfoChannelFrequency(ci)",
        "let freqHint = connectInfoChannelFrequency(req)",
        "freqHint != 0xFFFF'u16",
    ]:
        assert forbidden not in bss_body
        assert forbidden not in connect_body

    for forbidden in [
        "cast[ptr uint16](addr ci.channelHint[0])[]",
        "cast[ptr uint16](addr req.channelHint[0])[]",
    ]:
        assert forbidden not in bss_body
        assert forbidden not in connect_body


def test_wifi_bss_params_falls_back_to_typed_directed_scan_result():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    helper_body = wifi_fw.split(
        "proc bestDirectedScanuResult()", 1
    )[1].split(
        "# ###########################################################################", 1
    )[0]
    bss_body = wifi_fw.rsplit(
        "proc sm_get_bss_params*", 1
    )[1].split(
        "proc sm_scan_bss*", 1
    )[0]

    for expected in [
        "proc bestDirectedScanuResult(): ptr ScanuResultEntry",
        "if scanu_env.directedFound == 0:",
        "let entry = addr scanu_env.entries[i]",
        "if entry.valid == 0 or entry.chanPtr == nil:",
        "if best == nil or entry.rssi > bestRssi:",
        "let directed = bestDirectedScanuResult()",
        "resultOut[] = cast[pointer](directed)",
        "chanPtrOut[] = directed.chanPtr",
    ]:
        assert expected in wifi_fw

    assert "rawMsgPtr" not in helper_body
    assert bss_body.index("let directed = bestDirectedScanuResult()") < \
        bss_body.index("elif connectInfoHasChannelHint(ci):")


def test_wifi_sta_join_channel_context_uses_typed_center_frequency_helpers():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc sm_add_chan_ctx*", 1
    )[1].split(
        "proc sm_send_next_bss_param*", 1
    )[0]

    for expected in [
        "proc vifChannelCenterFreq1(vif: ptr VifChannelView; fallback: uint16): uint16",
        "if freq == 0'u16: fallback else: freq",
        "proc vifChannelCenterFreq2(vif: ptr VifChannelView): uint16",
        "chanReq.centerFreq1 = vifChannelCenterFreq1(vif, chan.prim20Freq)",
        "chanReq.centerFreq2 = vifChannelCenterFreq2(vif)",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "chanReq.centerFreq1 = uint16(vif.channelFreqPair and 0xFFFF'u32)",
        "chanReq.centerFreq2 = uint16((vif.channelFreqPair shr 16) and 0xFFFF'u32)",
    ]:
        assert forbidden not in body


def test_wifi_chan_scan_request_uses_typed_channel_overlay_helpers():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc chan_scan_req*", 1
    )[1].split(
        "proc chan_roc_req*", 1
    )[0]

    for expected in [
        "proc chanScanDurationTicks(req: ptr ChanScanReqPayload): uint16",
        "template chanScanChannel(req: ptr ChanScanReqPayload): ptr ChanCtxtDefView",
        "requestVifIdx*: uint8",
        "doAssert offsetof(ChanScanPoolOverlay, requestVifIdx) == 21",
        "scan.requestVifIdx = scanReq.vifIdx",
        "scan.durationTicks = chanScanDurationTicks(scanReq)",
        "c_memcpy(addr scan.channel, chanScanChannel(scanReq),",
        "\"[WIFI-NIMFW] chan_scan_req duration \"",
        "\"[WIFI-NIMFW] chan_scan_req channel \"",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "let scanFreq = scanReq.duration",
        "\"[WIFI-NIMFW] chan_scan_req freq \"",
        "scan.durationTicks = (scanFreq shr 10).uint16",
        "c_memcpy(addr scan.channel, addr scanReq.band",
        "scan.band = scanReq.vifIdx",
    ]:
        assert forbidden not in body


def test_wifi_auth_rx_debug_counters_cover_classifier_dispatch_and_handler():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    smoke = (ROOT / "examples/m0_wifi_lwip_smoke.nim").read_text()

    for expected in [
        'exportc: "nimfw_dbg_auth_mgt_seen"',
        'exportc: "nimfw_dbg_auth_mgt_accept"',
        'exportc: "nimfw_dbg_auth_mgt_reject"',
        'exportc: "nimfw_dbg_auth_mgt_msg"',
        'exportc: "nimfw_dbg_auth_sm_dispatch"',
        'exportc: "nimfw_dbg_auth_handler"',
        "inc nimFwDbgAuthMgtSeen",
        "inc nimFwDbgAuthMgtAccepted",
        "inc nimFwDbgAuthMgtRejected",
        "inc nimFwDbgAuthMgtMsgSent",
        "inc nimFwDbgAuthSmDispatch",
        "inc nimFwDbgAuthHandler",
    ]:
        assert expected in wifi_fw

    for expected in [
        'kvWrite("auth_mgt"',
        'kvWrite("auth_mgt0"',
        'kvWrite("auth_mgt1"',
        'kvWrite("auth_sm"',
        'kvWrite("auth_h"',
    ]:
        assert expected in smoke


def test_wifi_lwip_smoke_dumps_dhcp_final_tx_chain():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    wifi_tx = (ROOT / "src/bl808/wifi_tx.nim").read_text()
    smoke = (ROOT / "examples/m0_wifi_lwip_smoke.nim").read_text()

    for expected in [
        'exportc: "nimfw_dbg_dhcp_tx_final_break_hits"',
        'exportc: "nimfw_dbg_dhcp_tx_final_desc0"',
        'exportc: "nimfw_dbg_dhcp_tx_final_hw_len"',
        'exportc: "nimfw_dbg_dhcp_tx_final_hthd_next"',
        'exportc: "nimfw_dbg_dhcp_tx_final_pthd_end"',
        'exportc: "nimfw_dbg_dhcp_tx_rate_raw"',
        'exportc: "nimfw_dbg_dhcp_tx_layout"',
        "captureDhcpTxRateRaw(rateTemplate)",
        "captureDhcpTxRateRaw(rateForDhcp)",
        "nimFwDbgDhcpTxFinalBreakpoint()",
    ]:
        assert expected in wifi_fw

    for expected in [
        'exportc: "nimfw_dbg_dhcp_cfm_ring_idx"',
        'exportc: "nimfw_dbg_dhcp_cfm_status_log"',
        'exportc: "nimfw_dbg_dhcp_cfm_meta_log"',
        'exportc: "nimfw_dbg_dhcp_cfm_ack_ok"',
        'exportc: "nimfw_dbg_dhcp_cfm_ack_fail"',
        'exportc: "nimfw_dbg_dhcp_request_tx_break_hits"',
        'exportc: "nimfw_dbg_dhcp_tx_msg_hist"',
        'exportc: "nimfw_dbg_dhcp_udp_csum_repair"',
        'exportc: "nimfw_dbg_dhcp_udp_csum_vafter"',
        'exportc: "nimfw_dbg_dhcp_req_udp_csum_at_copy"',
        'exportc: "nimfw_dbg_dhcp_request_tx_breakpoint"',
        "repairDhcpUdpChecksum(raw, pbuf.len.uint32)",
        "nimFwDbgDhcpCfmStatusLog[ringIdx]",
        "nimFwDbgDhcpCfmMetaLog[ringIdx]",
        "if (value and FrameSuccessfulTxBit) != 0'u32:",
        "inc nimFwDbgDhcpCfmAckOk",
        "inc nimFwDbgDhcpCfmAckFail",
        "nimFwDbgDhcpTxMsgHist[msgType]",
        "nimFwDbgDhcpRequestTxBreakpoint()",
    ]:
        assert expected in wifi_tx

    for expected in [
        'kvWrite("dhcp_fhit"',
        'kvWrite("dhcp_fdesc0"',
        'kvWrite("dhcp_fhw2"',
        'kvWrite("dhcp_fhh2"',
        'kvWrite("dhcp_fph1"',
        'kvWrite("dhcp_rr0"',
        'kvWrite("dhcp_rr12"',
        'kvWrite("dhcp_ly0"',
        'kvWrite("dhcp_ly7"',
        'kvWrite("eap_cfm"',
        'kvWrite("eap_cs0"',
        'kvWrite("eap_h0"',
        'kvWrite("eap_rate3"',
        'kvWrite("dhcp_ack"',
        'kvWrite("dhcp_cri"',
        'kvWrite("dhcp_cs0"',
        'kvWrite("dhcp_cm0"',
    ]:
        assert expected in smoke


def test_wifi_legacy_rate_diagnostic_define_disables_ht_advertising():
    msg_tx = (ROOT / "src/bl808/wifi_msg_tx.nim").read_text()

    config_body = msg_tx.split("proc bl_send_me_config_req*", 1)[1].split(
        "proc bl_send_me_chan_config_req*", 1
    )[0]
    connect_body = msg_tx.split("proc bl_send_sm_connect_req*", 1)[1].split(
        "proc bl_send_sm_disconnect_req*", 1
    )[0]

    assert "when defined(bl808WifiForceLegacyRates):" in config_body
    assert "0'u8" in config_body
    assert "storeU8(req, MeConfigHtSuppOff, htSupp)" in config_body
    assert 'bl_os_printf("[ME] HT supp %d, VHT supp %d\\r\\n", htSupp.cint, 0)' in config_body
    assert "when defined(bl808WifiForceLegacyRates):" in connect_body
    assert "flags = flags or DISABLE_HT" in connect_body


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
    vif_postpone_body = wifi_fw.split(
        "proc vif_mgmt_send_postponed_frame*(vifEntry: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc vif_mgmt_reset*() {.exportc, cdecl.} =",
        1,
    )[0]
    sta_register_body = wifi_fw.split(
        "proc sta_mgmt_register*(param: pointer, staIdxOut: ptr uint8): uint8 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc sta_mgmt_unregister*", 1
    )[0]
    sta_unregister_body = wifi_fw.split(
        "proc sta_mgmt_unregister*(staIdx: uint8) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc sta_mgmt_add_key*", 1
    )[0]
    sta_add_key_body = wifi_fw.split(
        "proc sta_mgmt_add_key*(param: pointer, hwKeyIdx: uint8) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc sta_mgmt_del_key*", 1
    )[0]
    chan_idle_body = wifi_fw.split(
        "proc chan_goto_idle_cb*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc chanConnLessDelay", 1
    )[0]

    assert "while cur.next != nil:" in extract_body
    assert "while true:" not in extract_body
    assert "while timQueue.first != nil:" in bcn_body
    assert "while true:" not in bcn_body
    assert "postponedStaHead*: pointer" in wifi_fw
    assert "doAssert offsetof(VifChannelView, postponedStaHead) == 340" in wifi_fw
    assert "template vifPostponedStaList(vif: ptr VifChannelView): ptr CoList =\n  cast[ptr CoList](addr vif.postponedStaHead)" in wifi_fw
    assert "var cur = vif.postponedStaHead" in vif_postpone_body
    assert "let next = cast[pointer](cast[ptr CoListHdr](cur).next)" in vif_postpone_body
    assert "cast[ptr pointer](vif + 340)" not in vif_postpone_body
    assert "cast[ptr pointer](cast[uint](cur))" not in vif_postpone_body
    assert "let vif = vifChannelForIdx(instNbr)" in sta_register_body
    assert "let keyPtrs = vifKeyPointers(vif)" in sta_register_body
    assert "var staIdx = 0'u8" in sta_register_body
    assert "while staIdx < STA_MGMT_FREE_STAS.uint8 and staInfoForIdx(staIdx) != sta:" in sta_register_body
    assert "sta.txPolicy = cast[pointer](txBufferControlDescAt(staIdx.int))" in sta_register_body
    assert "sta.keyMat = cast[pointer](addr sta.keyHolder)" in sta_register_body
    assert "co_list_push_back(vifPostponedStaList(vif), cast[ptr CoListHdr](staEntry))" in sta_register_body

    assert "let vif = vifChannelForIdx(instNbr)" in sta_unregister_body
    assert "co_list_extract(vifPostponedStaList(vif), cast[ptr CoListHdr](sta))" in sta_unregister_body
    assert "of 1, 2:" in sta_add_key_body
    assert "let keySrcU = cast[uint](machwKeyWriteKeyTailPtr(req))" in sta_add_key_body
    assert "for i in 0 ..< 4:" in sta_add_key_body
    assert "for i in 0 ..< 8:" not in sta_add_key_body
    assert "if vif.postponedStaHead != nil:" in chan_idle_body
    for forbidden in [
        "let vifStaListAddr = vifOffset + 340 + vifTabBase",
        "let vifStaListAddr = vifBase + instNbr.uint * VIF_ENTRY_SIZE.uint + 340",
        "cast[ptr CoList](vifStaListAddr)",
        "let vifTabBase = cast[uint](addr vif_info_tab[0])",
        "let vifOffset = instNbr.uint * VIF_ENTRY_SIZE.uint",
        "let vifEntry = vifTabBase + vifOffset",
        "let keyPtrs = vifKeyPointersAt(vifEntry)",
        "let vif = vifChannelAt(vifEntry)",
        "let vifAddr = cast[uint](vif)",
        "cast[ptr pointer](vifAddr + 340)",
        "let staTabBase = cast[uint](addr sta_info_tab[0])",
        "let rawDiff = staEntry - staTabBase",
        "rawDiff div STA_ENTRY_SIZE.uint",
        "let txPolicyBase = cast[uint](addr txl_buffer_control_desc[0])",
        "sta.txPolicy = cast[pointer](txPolicyBase + staIdx.uint * 60'u)",
        "let postponedListAddr = staEntry + 240",
        "sta.keyMat = cast[pointer](postponedListAddr)",
    ]:
        assert forbidden not in sta_register_body
        assert forbidden not in sta_unregister_body
        assert forbidden not in chan_idle_body
    assert "while cur != nil:" in postpone_body
    assert "let curDesc = apmTxDescPsAt(cur)" in postpone_body
    assert "let frameTid = curDesc.tid" in postpone_body
    assert "curDesc.tid = cast[uint8]((psStatus and 3) + 3)" in postpone_body
    assert "let sTid = apmTxDescPsAt(scan).tid" in postpone_body
    assert "cast[ptr CoListHdr](cur).next" in postpone_body
    assert "assert_warn(\"apm.c\", \"apm.c\", 377)" in postpone_body
    assert "return nil" in postpone_body
    assert "while true:" not in postpone_body
    for forbidden in [
        "cast[ptr uint8](curU + 46)",
        "cast[ptr uint8](sU + 46)",
        "cast[ptr pointer](cast[uint](prev))",
        "cast[ptr pointer](sU)",
        "cast[ptr pointer](curU)",
    ]:
        assert forbidden not in postpone_body


def test_wifi_vif_unregister_uses_typed_vif_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc vif_mgmt_unregister*(vifIdx: uint8) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc vif_mgmt_add_key*", 1
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let vifEntry = cast[pointer](vif)",
        "let otherVif = vifChannelForIdx(otherVifIdx)",
        "let scanType = vifChannelForIdx(scanIdx).vifType",
        "let otherVifType = vifChannelForIdx(if vifIdx == 0: 1'u8 else: 0'u8).vifType",
        "discard c_memset(vifEntry, 0, VIF_ENTRY_SIZE.csize_t)",
        "vif.beaconTimeoutTimer.env = pointerAddrU32(vifEntry)",
    ]:
        assert expected in body

    for forbidden in [
        "let vifTabBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifTabBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "vifTabBase + otherVifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let scanVif = vifTabBase + scanIdx.uint * VIF_ENTRY_SIZE.uint",
        "vifChannelAt(scanVif)",
        "vifTabBase + (if vifIdx == 0: VIF_ENTRY_SIZE.uint else: 0)",
    ]:
        assert forbidden not in body


def test_wifi_send_postponed_frames_uses_explicit_budget_condition():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    service_body = wifi_fw.split(
        "proc sta_mgmt_send_postponed_frame*(vifEntry: pointer, staEntry: pointer, maxCount: uint32): uint32 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc sta_mgmt_entry_init*",
        1,
    )[0]
    release_body = wifi_fw.split(
        "proc sta_mgmt_postponed_desc_release*(staEntry: pointer, flag: uint32): uint32 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc sta_mgmt_aging_postponed_desc*", 1
    )[0]
    aging_body = wifi_fw.split(
        "proc sta_mgmt_aging_postponed_desc*(staEntry: pointer, maxCount: uint32): uint32 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "# ###########################################################################\n#                  TPC: TX Power Control",
        1,
    )[0]

    assert "while sta.postponedList.first != nil and (maxCount == 0 or count < maxCount):" in service_body
    assert "while true:" not in service_body
    assert "discard sta_mgmt_postponed_desc_release(staEntry, 0)" in service_body
    assert "return count" in service_body
    assert "let txDesc = hostTxDescAt(cur)" in release_body
    assert "let next = cast[pointer](cast[ptr CoListHdr](cur).next)" in release_body
    assert "let txTime = txDesc.pendingMacTime" in release_body
    assert "while true:" not in release_body
    assert "for i in 0'u8 ..< STA_INFO_TAB_ENTRIES.uint8:" in aging_body
    assert "let sta = staInfoForIdx(i)" in aging_body
    assert "sta_mgmt_postponed_desc_release(cast[pointer](sta), 0)" in aging_body
    for forbidden in [
        "let curU = cast[uint](cur)",
        "cast[ptr pointer](curU)",
        "cast[ptr uint32](curU + 84)",
    ]:
        assert forbidden not in release_body
    for forbidden in [
        "let staBase = cast[uint](addr sta_info_tab[0])",
        "let staEnd = staBase + (STA_INFO_TAB_ENTRIES * STA_ENTRY_SIZE).uint",
        "var cur = staBase",
        "while cur < staEnd:",
        "cur += STA_ENTRY_SIZE.uint",
    ]:
        assert forbidden not in aging_body


def test_wifi_ke_env_ps_flags_use_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    bl_event_body = wifi_fw.rsplit("proc bl_event_handle*", 1)[1].split(
        "proc bl_fw_statistic_dump*", 1
    )[0]
    postponed_body = wifi_fw.rsplit(
        "proc sta_mgmt_send_postponed_frame*(vifEntry: pointer, staEntry: pointer, maxCount: uint32): uint32 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc sta_mgmt_entry_init*", 1
    )[0]
    ps_body = wifi_fw.rsplit("proc ps_set_mode*", 1)[1].split(
        "proc ps_dpsm_update*", 1
    )[0]

    for expected in [
        "KeEnvPsFlagsView {.packed.} = object",
        "flags*: uint8",
        "apPending*: uint8",
        "otherPending*: uint8",
        "staPending*: uint8",
        "doAssert sizeof(KeEnvPsFlagsView) == 5",
        "doAssert offsetof(KeEnvPsFlagsView, apPending) == 1",
        "doAssert offsetof(KeEnvPsFlagsView, otherPending) == 3",
        "doAssert offsetof(KeEnvPsFlagsView, staPending) == 4",
        "template keEnvPsFlags(): ptr KeEnvPsFlagsView",
    ]:
        assert expected in wifi_fw

    assert "let keEnvFlags = keEnvPsFlags()" in bl_event_body
    assert "discard c_memset(keEnvFlags, 0, 5.csize_t)" in bl_event_body

    for expected in [
        "let ps = keEnvPsFlags()",
        "ps.flags = ps.flags or 2",
        "ps.apPending = 1",
        "ps.flags = ps.flags or 1",
        "ps.otherPending = 1",
    ]:
        assert expected in postponed_body

    for expected in [
        "let ps = keEnvPsFlags()",
        "ps.flags = ps.flags or 1",
        "ps.staPending = 1",
    ]:
        assert expected in ps_body

    for body in [bl_event_body, postponed_body, ps_body]:
        for forbidden in [
            "cast[pointer](cast[uint](addr ke_env[0]) + 28)",
            "let keEnvBase = cast[uint](addr ke_env[0])",
            "let keU = cast[uint](addr ke_env[0])",
            "cast[ptr uint8](keEnvBase + 28)",
            "cast[ptr uint8](keEnvBase + 29)",
            "cast[ptr uint8](keEnvBase + 31)",
            "cast[ptr uint8](keU + 28)",
            "cast[ptr uint8](keU + 32)",
        ]:
            assert forbidden not in body


def test_wifi_sta_ht_vht_param_uses_sta_info_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc me_set_sta_ht_vht_param*(staEntry: pointer, param: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "{.emit: \"__attribute__((optimize(\\\"crossjumping\\\"))) void* me_update_buffer_control(void*);\".}",
        1,
    )[0]

    for expected in [
        "bwConfigState*: uint8",
        "doAssert offsetof(StaInfoView, bwConfigState) == 312",
        "let sta = staInfoAt(staEntry)",
        "sta.bwConfigState = 0'u8",
        "sta.nssBwMax = 0'u8",
        "sta.htVhtConfig = configByte",
    ]:
        assert expected in wifi_fw if expected.startswith(("bwConfigState", "doAssert")) else expected in body

    for forbidden in [
        "let sta = cast[uint](staEntry)",
        "cast[ptr uint16](sta + 312)",
        "cast[ptr uint8](sta + 316)",
    ]:
        assert forbidden not in body


def test_wifi_beacon_transmit_uses_typed_frame_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc mm_bcn_transmit*", 1)[1].split(
        "proc mm_tim_update*", 1
    )[0]

    for expected in [
        "template vifApBeaconFrameDesc(vif: ptr VifChannelView): ptr TxlFrameDescView",
        "doAssert offsetof(TxlFrameDescView, vifIdx) == 47",
        "doAssert offsetof(TxlFrameDescView, staInfoIdx) == 49",
        "doAssert offsetof(HostTxHwDescView, frameLen) == 28",
        "hostTxHwDescAt(txDescPtr).frameLen = totalLen",
        "for entryVifIdx in 0'u8 ..< 2'u8:",
        "let vif = vifChannelForIdx(entryVifIdx)",
        "tpc_update_frame_tx_power(cast[pointer](vif), descForTpc)",
        "chan_is_on_operational_channel(cast[pointer](vif))",
        "let bcnDesc = vifApBeaconFrameDesc(vif)",
        "bcnDesc.vifIdx = staHwIdx",
        "bcnDesc.staInfoIdx = 0xFF'u8",
        "let bcnFrame = cast[pointer](bcnDesc)",
        "sta_mgmt_send_postponed_frame(cast[pointer](vif)",
    ]:
        assert expected in wifi_fw if expected.startswith(("template", "doAssert")) else expected in body

    for forbidden in [
        "var vifPtr = cast[ptr pointer](vifBase)[]",
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifBase + vifIdx.uint * VIF_ENTRY_SIZE",
        "let vif = vifChannelAt(vifEntry)",
        "tpc_update_frame_tx_power(cast[pointer](vifEntry), descForTpc)",
        "chan_is_on_operational_channel(cast[pointer](vifEntry))",
        "sta_mgmt_send_postponed_frame(cast[pointer](vifEntry)",
        "let descAddr = cast[uint](txDescPtr)",
        "cast[ptr uint32](descAddr + 28)",
        "cast[ptr uint8](vifEntry + 143)",
        "cast[ptr uint8](vifEntry + 145)",
    ]:
        assert forbidden not in body


def test_wifi_wpa_rsn_ie_and_beacon_update_use_typed_vif_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    rsn_body = wifi_fw.rsplit("proc mm_set_wpa_rsn_ie*", 1)[1].split(
        "proc mm_force_idle_req*", 1
    )[0]
    bcn_body = wifi_fw.rsplit("proc mm_bcn_update*", 1)[1].split(
        "proc mm_bcn_transmit*", 1
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let sec = vifSecurity(vif)",
        "sec.rsnIePtr = cast[uint32](ie)",
        "sec.rsnIeLen = ieLen",
    ]:
        assert expected in rsn_body

    for forbidden in [
        "let vifTab = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifTab + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let sec = vifSecurityAt(vifEntry)",
    ]:
        assert forbidden not in rsn_body

    assert "let vif = vifChannelForIdx(vifIdx)" in bcn_body
    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifE = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifE)",
    ]:
        assert forbidden not in bcn_body


def test_wifi_beacon_probe_builders_use_vif_overlay_directly():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    beacon_body = wifi_fw.rsplit("proc me_build_beacon*", 1)[1].split(
        "proc me_build_probe_rsp*", 1
    )[0]
    probe_body = wifi_fw.rsplit("proc me_build_probe_rsp*", 1)[1].split(
        "proc me_build_capability*", 1
    )[0]

    for expected in [
        "let frame = beaconFrameFixedView(buf)",
        "frame.frameControl = 0x0080'u16",
        "frame.duration = 0",
        "discard c_memcpy(addr frame.addr1[0], addr mac_addr_bcst_fwd[0], 6.csize_t)",
        "discard c_memcpy(addr frame.addr2[0], cast[pointer](addr vif.macAddr[0]), 6.csize_t)",
        "discard c_memcpy(addr frame.addr3[0], cast[pointer](addr vif.macAddr[0]), 6.csize_t)",
        "let meSeq = meBeaconSequence()",
        "var seqNum = meSeq.seqCounter",
        "meSeq.seqCounter = seqNum",
        "frame.seqCtrl = seqField",
        "frame.beaconInterval = bcnInt",
        "frame.capabilityInfo = capInfo",
        "let sec = vifSecurity(vif)",
        "me_add_ie_ht_oper(addr ieBuf, cast[pointer](vif))",
        "let cipherType = vifWpaCipher(vif)",
        "let chanCtxPtr = vif.chanCtxt",
    ]:
        assert expected in beacon_body

    for expected in [
        "me_add_ie_ht_oper(addr ieBuf, cast[pointer](vif))",
        "let chanCtxPtr = vif.chanCtxt",
    ]:
        assert expected in probe_body

    for forbidden in [
        "let vifBase = cast[uint](vif)",
        "vifSecurityAt(vifBase)",
        "vifWpaCipher(vifChannelAt(vifBase))",
        "vifChannelAt(vifBase).chanCtxt",
        "me_add_ie_ht_oper(addr ieBuf, cast[pointer](vifBase))",
    ]:
        assert forbidden not in beacon_body
        assert forbidden not in probe_body

    for forbidden in [
        "let p = cast[ptr UncheckedArray[uint8]](buf)",
        "p[0] = 0x80'u8",
        "p[22] = (seqField and 0xFF).uint8",
        "let bufU = cast[uint](buf)",
        "cast[ptr uint8](bufU + 32)",
        "cast[ptr uint8](bufU + 34)",
        "let meBase = cast[uint](addr me_env[0])",
        "cast[ptr uint16](meBase + 84)[]",
    ]:
        assert forbidden not in beacon_body

    for expected in [
        "MeBeaconSequenceOverlay {.packed.} = object",
        "seqCounter*: uint16",
        "doAssert offsetof(MeBeaconSequenceOverlay, seqCounter) == 84",
        "template meBeaconSequence(): ptr MeBeaconSequenceOverlay",
    ]:
        assert expected in wifi_fw


def test_wifi_sae_and_assoc_rsp_builders_use_typed_vif_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    sae_body = wifi_fw.rsplit("proc me_build_sae_authenticate*", 1)[1].split(
        "proc me_build_associate_req_impl", 1
    )[0]
    rsp_body = wifi_fw.rsplit("proc me_build_associate_rsp_impl", 1)[1].split(
        "proc me_build_beacon*", 1
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx.uint8)",
        "let saeCtx = cast[pointer](addr vif.macAddr[0])",
        "let body = cast[ptr AuthBodyDataView](buf)",
        "body.fixed.authAlgo = authAlgo",
        "body.fixed.authSeq = authSeq",
        "body.fixed.statusCode = statusCode",
        "discard c_memcpy(addr body.data[0], saeData, saeLen.csize_t)",
        "return saeLen + sizeof(AuthFixedBodyView).uint32",
    ]:
        assert expected in sae_body

    for expected in [
        "AuthBodyDataView {.packed.} = object",
        "data*: UncheckedArray[uint8]",
        "doAssert offsetof(AuthBodyDataView, data) == sizeof(AuthFixedBodyView)",
        "AssocRspFixedBodyView {.packed.} = object",
        "doAssert sizeof(AssocRspFixedBodyView) == 6",
        "BssMaxIdlePeriodIeView {.packed.} = object",
        "idlePeriod*: uint16",
        "idleOptions*: uint8",
        "doAssert sizeof(BssMaxIdlePeriodIeView) == 5",
        "doAssert offsetof(BssMaxIdlePeriodIeView, idlePeriod) == 2",
        "MmWmmParameterSourceView {.packed.} = object",
        "acBk*: uint32",
        "acBe*: uint32",
        "acVi*: uint32",
        "acVo*: uint32",
        "doAssert offsetof(MmWmmParameterSourceView, acBk) == 8",
        "doAssert offsetof(MmWmmParameterSourceView, idleOptions) == 26",
        "doAssert offsetof(VifChannelView, wmmQosInfo) == 452",
        "template mmWmmParameterSource(): ptr MmWmmParameterSourceView",
        "proc setLe32*(rec: var WmmAcParamRecord; value: uint32) {.inline.}",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let vif = vifChannelForIdx(vifIdx.uint8)",
        "let apCfg = vifApConfig(vif)",
        "let privacy = apCfg.privacyFlag",
        "let fixedRsp = cast[ptr AssocRspFixedBodyView](cast[pointer](writePtr))",
        "fixedRsp.capabilityInfo = capInfo",
        "fixedRsp.statusCode = statusCode",
        "let staAdd = cast[ptr ApmAssocStaAddIndPayload](cast[uint](aid))",
        "let aidVal = staAdd.aid",
        "fixedRsp.aid = aidField",
        "let ratesPtr = cast[pointer](addr staAdd.rateCount)",
        "let rateCount = staAdd.rateCount",
        "let staCap = staAdd.flags",
        "me_add_ie_ht_oper(buf, cast[pointer](vif))",
        "let bufPtrPtr = cast[ptr pointer](buf)",
        "let wmm = wmmParameterIeAt(bufPtrPtr[])",
        "let wmmSrc = mmWmmParameterSource()",
        "wmm.qosInfo = vif.wmmQosInfo",
        "wmm.ac[0].setLe32(wmmSrc.acBe)",
        "wmm.ac[1].setLe32(wmmSrc.acBk)",
        "wmm.ac[2].setLe32(wmmSrc.acVi)",
        "wmm.ac[3].setLe32(wmmSrc.acVo)",
        "bufPtrPtr[] = addr wmm.next[0]",
        "let bssMaxIdle = bssMaxIdlePeriodIeAt(bufPtrPtr[])",
        "bssMaxIdle.ie.id = 90'u8",
        "bssMaxIdle.idlePeriod = wmmSrc.idlePeriod",
        "bssMaxIdle.idleOptions = wmmSrc.idleOptions",
    ]:
        assert expected in rsp_body

    for forbidden in [
        "let vifTabBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifTabBase + vifIdx * VIF_ENTRY_SIZE.uint",
        "let saeCtx = cast[pointer](vifEntry + 80)",
        "cast[pointer](cast[uint](buf) + 6)",
        "modeByte452",
        "p[0] = (authAlgo and 0xFF).uint8",
        "p[1] = ((authAlgo shr 8) and 0xFF).uint8",
        "p[2] = (authSeq and 0xFF).uint8",
        "p[3] = ((authSeq shr 8) and 0xFF).uint8",
        "p[4] = (statusCode and 0xFF).uint8",
        "p[5] = ((statusCode shr 8) and 0xFF).uint8",
        "let privacy = cast[ptr uint8](vifEntry + 520)[]",
        "cast[ptr uint8](writePtr)[] = (capInfo and 0xFF).uint8",
        "cast[ptr uint8](writePtr + 1)[] = ((capInfo shr 8) and 0xFF).uint8",
        "cast[ptr uint8](writePtr + 2)[] = (statusCode and 0xFF).uint8",
        "cast[ptr uint8](writePtr + 3)[] = ((statusCode shr 8) and 0xFF).uint8",
        "let staEntryPtr = cast[uint](aid)",
        "cast[ptr uint16](staEntryPtr + 68)[]",
        "cast[ptr uint8](writePtr + 4)[] = (aidField and 0xFF).uint8",
        "cast[ptr uint8](writePtr + 5)[] = ((aidField shr 8) and 0xFF).uint8",
        "cast[pointer](staEntryPtr + 6)",
        "cast[ptr uint8](staEntryPtr + 6)[]",
        "cast[ptr uint32](staEntryPtr + 64)[]",
        "me_add_ie_ht_oper(buf, cast[pointer](vifEntry))",
        "let meEnvBase = cast[uint](addr me_env[0])",
        "cast[ptr uint8](meEnvBase + 452)",
        "cast[ptr uint32](meEnvBase + 12)",
        "cast[ptr uint32](wp + 10)",
        "cast[ptr uint8](bp + 0)",
        "cast[ptr uint16](meEnvBase + 24)",
    ]:
        assert forbidden not in sae_body
        assert forbidden not in rsp_body


def test_wifi_ssid_ie_builder_uses_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc me_add_ie_ssid*", 1)[1].split(
        "proc me_add_ie_supp_rates*", 1
    )[0]

    for expected in [
        "SsidIeView {.packed.} = object",
        "data*: UncheckedArray[uint8]",
        "template ssidIeAt(p: pointer): ptr SsidIeView",
        "doAssert offsetof(SsidIeView, data) == 2",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let ie = ssidIeAt(bufPtrPtr[])",
        "ie.ie.id = 0'u8",
        "ie.ie.len = ssidLen",
        "co_pack8p(addr ie.data[0], ssid, ssidLen.uint32)",
        "bufPtrPtr[] = addr ie.data[ssidLen]",
    ]:
        assert expected in body

    for forbidden in [
        "let p = cast[uint](bufPtrPtr[])",
        "cast[ptr uint8](p)[] = 0'u8",
        "cast[ptr uint8](p + 1)[] = ssidLen",
        "co_pack8p(cast[pointer](p + 2), ssid, ssidLen.uint32)",
        "bufPtrPtr[] = cast[pointer](p + total.uint)",
    ]:
        assert forbidden not in body


def test_wifi_capability_builder_uses_typed_vif_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc me_build_capability*", 1)[1].split(
        "# ME rate/capability helpers", 1
    )[0]

    assert "doAssert offsetof(VifChannelView, capabilityInfo) == 434" in wifi_fw
    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let vifType = vif.vifType",
        "let beaconCap = vif.capabilityInfo",
    ]:
        assert expected in body

    for forbidden in [
        "let vif = vifEntryAddr(vifIdx)",
        "let vifView = vifChannelAt(vif)",
        "let vifType = vifView.vifType",
        "cast[ptr uint16](vif + 434)",
    ]:
        assert forbidden not in body


def test_wifi_supported_rate_ies_use_typed_rate_set_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    bitfield_body = wifi_fw.rsplit("proc me_legacy_rate_bitfield_build*", 1)[1].split(
        "proc me_legacy_ridx_min*", 1
    )[0]
    basic_body = wifi_fw.rsplit("proc me_get_basic_rates*", 1)[1].split(
        "proc me_freq_to_chan_ptr*", 1
    )[0]
    supp_body = wifi_fw.rsplit("proc me_add_ie_supp_rates*", 1)[1].split(
        "proc me_add_ie_ext_supp_rates*", 1
    )[0]
    ext_body = wifi_fw.rsplit("proc me_add_ie_ext_supp_rates*", 1)[1].split(
        "proc me_add_ie_ds*", 1
    )[0]

    for expected in [
        "RateSetView {.packed.} = object",
        "rates*: UncheckedArray[uint8]",
        "MacIeDataView {.packed.} = object",
        "data*: UncheckedArray[uint8]",
        "doAssert offsetof(RateSetView, rates) == 1",
        "doAssert offsetof(MacIeDataView, data) == 2",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let rateSet = rateSetAt(rates)",
        "let rateCount = rateSet.count.int",
        "let rateByte = rateSet.rates[i] and 0x7F",
    ]:
        assert expected in bitfield_body

    for expected in [
        "let rateSet = rateSetAt(cast[pointer](vifIdx))",
        "let output = rateSetAt(outputBuf)",
        "output.count = 0",
        "let rateCount = rateSet.count",
        "let rate = rateSet.rates[i]",
        "let curCount = output.count",
        "output.rates[curCount] = rate",
        "output.count = curCount + 1",
    ]:
        assert expected in basic_body

    for expected in [
        "let rateSet = rateSetAt(rateSetPtr)",
        "let rateCount = rateSet.count",
        "let ie = macIeDataAt(bufPtrPtr[])",
        "ie.ie.id = 1'u8",
        "ie.ie.len = writeCount",
        "co_pack8p(addr ie.data[0], addr rateSet.rates[0], writeCount.uint32)",
        "bufPtrPtr[] = addr ie.data[writeCount]",
    ]:
        assert expected in supp_body

    for expected in [
        "let rateSet = rateSetAt(rateSetPtr)",
        "let ie = macIeDataAt(bufPtrPtr[])",
        "ie.ie.id = 50'u8",
        "ie.ie.len = extCount.uint8",
        "co_pack8p(addr ie.data[0], addr rateSet.rates[8], extCount.uint32)",
        "bufPtrPtr[] = addr ie.data[extCount]",
    ]:
        assert expected in ext_body

    for forbidden in [
        "cast[ptr uint8](rateSetPtr)[]",
        "let ratesArr = cast[ptr UncheckedArray[uint8]](rates)",
        "ratesArr[0]",
        "ratesArr[1 + i]",
        "let rateSetPtr = cast[uint](cast[pointer](vifIdx))",
        "let outU = cast[uint](outputBuf)",
        "cast[ptr uint8](outU)[]",
        "let dataStart = rateSetPtr + 1",
        "cast[ptr uint8](dataStart + i.uint)",
        "cast[ptr uint8](outU + curCount.uint + 1)",
        "cast[pointer](cast[uint](rateSetPtr) + 1)",
        "cast[pointer](cast[uint](rateSetPtr) + 9)",
        "cast[pointer](p + 2)",
        "cast[ptr uint8](p + 1)[]",
    ]:
        assert forbidden not in bitfield_body
        assert forbidden not in basic_body
        assert forbidden not in supp_body
        assert forbidden not in ext_body


def test_wifi_one_byte_ies_use_typed_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    ds_body = wifi_fw.rsplit("proc me_add_ie_ds*", 1)[1].split(
        "proc me_add_ie_erp*", 1
    )[0]
    erp_body = wifi_fw.rsplit("proc me_add_ie_erp*", 1)[1].split(
        "proc me_add_ie_ht_capa*", 1
    )[0]

    for expected in [
        "next*: UncheckedArray[uint8]",
        "OneByteMacIeView {.packed.} = object",
        "value*: uint8",
        "doAssert offsetof(DsParamSetIeView, next) == 3",
        "doAssert sizeof(OneByteMacIeView) == 3",
        "doAssert offsetof(OneByteMacIeView, value) == 2",
        "doAssert offsetof(OneByteMacIeView, next) == 3",
        "template oneByteMacIeAt(p: pointer): ptr OneByteMacIeView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let ds = dsParamSetIeAt(bufPtrPtr[])",
        "ds.ie.id = 3'u8",
        "ds.ie.len = 1'u8",
        "ds.currentChannel = channel",
        "bufPtrPtr[] = addr ds.next[0]",
    ]:
        assert expected in ds_body

    for expected in [
        "let erp = oneByteMacIeAt(bufPtrPtr[])",
        "erp.ie.id = 42'u8",
        "erp.ie.len = 1'u8",
        "erp.value = erpInfo",
        "bufPtrPtr[] = addr erp.next[0]",
    ]:
        assert expected in erp_body

    for forbidden in [
        "let p = cast[uint](bufPtrPtr[])",
        "cast[ptr uint8](p)[]",
        "cast[ptr uint8](p + 1)[]",
        "cast[ptr uint8](p + 2)[]",
        "cast[pointer](p + 3)",
    ]:
        assert forbidden not in ds_body
        assert forbidden not in erp_body


def test_wifi_tim_ie_builder_uses_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc me_add_ie_tim*", 1)[1].split(
        "proc me_add_ie_csa*", 1
    )[0]

    for expected in [
        "TimIeView {.packed.} = object",
        "dtimCount*: uint8",
        "dtimPeriod*: uint8",
        "bitmapControl*: uint8",
        "partialBitmap*: UncheckedArray[uint8]",
        "doAssert offsetof(TimIeView, partialBitmap) == 5",
        "template timIeAt(p: pointer): ptr TimIeView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let tim = timIeAt(bufPtr[])",
        "tim.ie.id = 5'u8",
        "tim.ie.len = 4'u8",
        "tim.dtimCount = 0'u8",
        "tim.dtimPeriod = dtimBitmap",
        "tim.bitmapControl = 0'u8",
        "tim.partialBitmap[0] = 0'u8",
        "bufPtr[] = addr tim.partialBitmap[1]",
    ]:
        assert expected in body

    for forbidden in [
        "let p = cast[uint](bufPtr[])",
        "cast[ptr uint8](p + 0)[]",
        "cast[ptr uint8](p + 1)[]",
        "cast[ptr uint8](p + 2)[]",
        "cast[ptr uint8](p + 3)[]",
        "cast[ptr uint8](p + 4)[]",
        "cast[ptr uint8](p + 5)[]",
        "cast[pointer](p + 6)",
    ]:
        assert forbidden not in body


def test_wifi_ht_capability_ie_builder_uses_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc me_add_ie_ht_capa*", 1)[1].split(
        "proc me_add_ie_ht_oper*", 1
    )[0]

    for expected in [
        "HtCapIeView {.packed.} = object",
        "capInfo*: uint16",
        "ampduParams*: uint8",
        "mcsSet*: array[16, uint8]",
        "extCap*: uint16",
        "txBfCapsLo*: uint16",
        "aselCap*: uint8",
        "next*: UncheckedArray[uint8]",
        "doAssert offsetof(HtCapIeView, next) == 28",
        "template htCapIeAt(p: pointer): ptr HtCapIeView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let ht = htCapIeAt(bufPtrPtr[])",
        "ht.ie.id = 45'u8",
        "ht.ie.len = 26'u8",
        "ht.capInfo = htCapInfo",
        "ht.ampduParams = me.htCaps[2]",
        "co_pack8p(addr ht.mcsSet[0], cast[pointer](addr me.htCaps[3]), 16)",
        "ht.extCap = htExtCap",
        "cast[pointer](addr ht.txBfCapsLo)",
        "ht.aselCap = me.htCaps[28]",
        "bufPtrPtr[] = addr ht.next[0]",
    ]:
        assert expected in body

    for forbidden in [
        "let p = cast[uint](bufPtrPtr[])",
        "cast[ptr uint8](p)[]",
        "cast[ptr uint8](p + 1)[]",
        "cast[ptr uint8](p + 2)[]",
        "cast[ptr uint8](p + 3)[]",
        "cast[ptr uint8](p + 4)[]",
        "cast[pointer](p + 5)",
        "cast[ptr uint8](p + 21)[]",
        "cast[ptr uint8](p + 22)[]",
        "cast[pointer](p + 23)",
        "cast[ptr uint8](p + 27)[]",
        "cast[pointer](p + 28)",
    ]:
        assert forbidden not in body


def test_wifi_ht_operation_ie_builder_uses_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc me_add_ie_ht_oper*", 1)[1].split(
        "proc me_add_ie_rsn*", 1
    )[0]

    for expected in [
        "HtOperIeView {.packed.} = object",
        "primaryChannel*: uint8",
        "secondaryOffset*: uint8",
        "htProtection*: uint8",
        "operationMode*: array[3, uint8]",
        "basicMcsSet*: array[16, uint8]",
        "doAssert offsetof(HtOperIeView, basicMcsSet) == 8",
        "doAssert sizeof(HtOperIeView) == 24",
        "doAssert offsetof(HtOperIeView, next) == 24",
        "template htOperIeAt(p: pointer): ptr HtOperIeView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let oper = htOperIeAt(bufPtrPtr[])",
        "oper.ie.id = 61'u8",
        "oper.ie.len = 22'u8",
        "oper.primaryChannel = chanNum",
        "oper.secondaryOffset = secOffset",
        "oper.htProtection = 3'u8",
        "oper.operationMode = [0'u8, 0, 0]",
        "oper.basicMcsSet = [0xFF'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]",
        "bufPtrPtr[] = addr oper.next[0]",
    ]:
        assert expected in body

    for forbidden in [
        "let p = cast[uint](bufPtrPtr[])",
        "cast[ptr uint8](p)[]",
        "cast[ptr uint8](p + 1)[]",
        "cast[ptr uint8](p + 2)[]",
        "cast[ptr uint8](p + 3)[]",
        "cast[ptr uint8](p + 4)[]",
        "cast[ptr uint8](p + 5)[]",
        "cast[ptr uint8](p + 6)[]",
        "cast[ptr uint8](p + 7)[]",
        "cast[ptr uint8](p + 8)[]",
        "cast[ptr uint32](p + 9)[]",
        "cast[ptr uint32](p + 13)[]",
        "cast[ptr uint32](p + 17)[]",
        "cast[ptr uint16](p + 21)[]",
        "cast[ptr uint8](p + 23)[]",
        "cast[pointer](p + 24)",
    ]:
        assert forbidden not in body


def test_wifi_rsn_ie_builder_uses_typed_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc me_add_ie_rsn*", 1)[1].split(
        "{.emit: \"__attribute__((noipa)) unsigned long me_add_ie_wpa", 1
    )[0]

    for expected in [
        "RsnSuiteView {.packed.} = object",
        "suiteType*: uint8",
        "RsnCcmpPskIeView {.packed.} = object",
        "RsnTkipCcmpIeView {.packed.} = object",
        "pairwiseCipher*: array[2, RsnSuiteView]",
        "doAssert sizeof(RsnSuiteView) == 4",
        "doAssert sizeof(RsnCcmpPskIeView) == 22",
        "doAssert offsetof(RsnCcmpPskIeView, next) == 22",
        "doAssert sizeof(RsnTkipCcmpIeView) == 26",
        "doAssert offsetof(RsnTkipCcmpIeView, next) == 26",
        "template rsnCcmpPskIeAt(p: pointer): ptr RsnCcmpPskIeView",
        "template rsnTkipCcmpIeAt(p: pointer): ptr RsnTkipCcmpIeView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let bufPtrPtr = cast[ptr pointer](buf)",
        "let rsn = rsnCcmpPskIeAt(bufPtrPtr[])",
        "rsn.ie.id = 48'u8",
        "rsn.ie.len = 20'u8",
        "rsn.version = 1'u16",
        "rsn.groupCipher = RsnSuiteView(oui: [0'u8, 15'u8, 0xAC'u8], suiteType: 4'u8)",
        "rsn.pairwiseCount = 1'u16",
        "rsn.akmSuite = RsnSuiteView(oui: [0'u8, 15'u8, 0xAC'u8], suiteType: 2'u8)",
        "bufPtrPtr[] = addr rsn.next[0]",
        "let rsn = rsnTkipCcmpIeAt(bufPtrPtr[])",
        "rsn.ie.len = 24'u8",
        "rsn.groupCipher = RsnSuiteView(oui: [0'u8, 15'u8, 0xAC'u8], suiteType: 2'u8)",
        "rsn.pairwiseCount = 2'u16",
        "rsn.pairwiseCipher[1] = RsnSuiteView(oui: [0'u8, 15'u8, 0xAC'u8], suiteType: 4'u8)",
    ]:
        assert expected in body

    for forbidden in [
        "cast[ptr UncheckedArray[uint8]](cast[ptr pointer](buf)[])",
        "p[0]",
        "p[1]",
        "p[2]",
        "p[10]",
        "p[20]",
        "let pp = cast[ptr pointer](buf)",
        "cast[pointer](cast[uint](pp[]) + 22)",
        "cast[pointer](cast[uint](pp[]) + 26)",
    ]:
        assert forbidden not in body


def test_wifi_wpa_ie_builder_uses_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc me_add_ie_wpa*", 1)[1].split(
        "proc me_add_ie_tim*", 1
    )[0]

    for expected in [
        "WpaVendorIeView {.packed.} = object",
        "vendorType*: array[4, uint8]",
        "pairwiseCipher*: array[2, RsnSuiteView]",
        "doAssert offsetof(WpaVendorIeView, vendorType) == 2",
        "doAssert offsetof(WpaVendorIeView, akmCount) == 22",
        "doAssert sizeof(WpaVendorIeView) == 28",
        "doAssert offsetof(WpaVendorIeView, next) == 28",
        "template wpaVendorIeAt(p: pointer): ptr WpaVendorIeView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let wpa = wpaVendorIeAt(bufPtrPtr[])",
        "wpa.ie.id = 221'u8",
        "wpa.ie.len = 28'u8",
        "wpa.vendorType = [0x00'u8, 0x50'u8, 0xF2'u8, 0x01'u8]",
        "wpa.version = 1'u16",
        "wpa.groupCipher = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: 2'u8)",
        "wpa.pairwiseCount = 2'u16",
        "wpa.pairwiseCipher[0] = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: 2'u8)",
        "wpa.pairwiseCipher[1] = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: 4'u8)",
        "wpa.akmCount = 1'u16",
        "wpa.akmSuite = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: 2'u8)",
        "bufPtrPtr[] = addr wpa.next[2]",
    ]:
        assert expected in body

    for forbidden in [
        "let p = cast[uint](bufPtrPtr[])",
        "cast[ptr uint8](p + 0)[]",
        "cast[ptr uint8](p + 1)[]",
        "cast[ptr uint8](p + 2)[]",
        "cast[ptr uint8](p + 10)[]",
        "cast[ptr uint8](p + 20)[]",
        "cast[ptr uint8](p + 27)[]",
        "cast[pointer](p + 30)",
    ]:
        assert forbidden not in body


def test_wifi_inline_wpa_psk_vendor_ie_uses_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    helper_body = wifi_fw.rsplit("proc writeWpaPskVendorIe", 1)[1].split(
        "proc me_add_ie_tim*", 1
    )[0]
    beacon_body = wifi_fw.rsplit("proc me_build_beacon*", 1)[1].split(
        "proc me_build_probe_rsp*", 1
    )[0]
    probe_body = wifi_fw.rsplit("proc me_build_probe_rsp*", 1)[1].split(
        "proc me_build_add_ba_req*", 1
    )[0]

    for expected in [
        "WpaPskVendorIeView {.packed.} = object",
        "pairwiseCipher*: RsnSuiteView",
        "doAssert offsetof(WpaPskVendorIeView, akmCount) == 18",
        "doAssert sizeof(WpaPskVendorIeView) == 24",
        "doAssert offsetof(WpaPskVendorIeView, next) == 24",
        "template wpaPskVendorIeAt(p: pointer): ptr WpaPskVendorIeView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let wpa = wpaPskVendorIeAt(ieBuf)",
        "wpa.ie.id = 0xDD'u8",
        "wpa.ie.len = 22'u8",
        "wpa.vendorType = [0x00'u8, 0x50'u8, 0xF2'u8, 0x01'u8]",
        "wpa.groupCipher = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: cipherType)",
        "wpa.pairwiseCipher = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: cipherType)",
        "wpa.akmSuite = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: 2'u8)",
        "addr wpa.next[0]",
    ]:
        assert expected in helper_body

    for body in [beacon_body, probe_body]:
        assert "ieBuf = writeWpaPskVendorIe(ieBuf, cipherType)" in body
        for forbidden in [
            "let wpaBase = cast[uint](ieBuf)",
            "let wpaIeBase = cast[uint](ieBuf)",
            "cast[ptr uint8](wpaBase +",
            "cast[ptr uint8](wpaIeBase +",
            "cast[pointer](wpaBase + 24)",
            "cast[pointer](wpaIeBase + 24)",
        ]:
            assert forbidden not in body


def test_wifi_power_constraint_extractor_uses_typed_output_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc me_extract_power_constraint*", 1)[1].split(
        "proc me_11n_nss_max*", 1
    )[0]

    for expected in [
        "PowerConstraintOutputOverlay {.packed.} = object",
        "constraint*: uint8",
        "doAssert offsetof(PowerConstraintOutputOverlay, constraint) == 132",
        "template powerConstraintOutputAt(p: pointer): ptr PowerConstraintOutputOverlay",
        "powerConstraintOutputAt(out_ptr).constraint = constraintVal",
    ]:
        assert expected in wifi_fw if expected.startswith(("PowerConstraint", "constraint", "doAssert", "template")) else expected in body

    for forbidden in [
        "cast[ptr uint8](cast[uint](out_ptr) + 132)",
        "cast[uint](out_ptr) + 132",
    ]:
        assert forbidden not in body


def test_wifi_country_reg_extractor_uses_typed_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc me_extract_country_reg*", 1)[1].split(
        "proc me_extract_csa*", 1
    )[0]

    for expected in [
        "CountryRegOutputOverlay {.packed.} = object",
        "channelReg*: pointer",
        "CountryRegView {.packed.} = object",
        "environment*: uint8",
        "maxPower*: uint8",
        "CountryTripletView {.packed.} = object",
        "firstChan*: uint8",
        "numChan*: uint8",
        "doAssert offsetof(CountryRegOutputOverlay, channelReg) == 76",
        "doAssert offsetof(CountryRegView, environment) == 2",
        "doAssert offsetof(CountryRegView, maxPower) == 4",
        "doAssert sizeof(CountryTripletView) == 3",
        "template countryRegOutputAt(p: pointer): ptr CountryRegOutputOverlay",
        "template countryRegAt(p: pointer): ptr CountryRegView",
        "template countryTripletAt(p: pointer): ptr CountryTripletView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let chanReg = countryRegAt(countryRegOutputAt(out_ptr).channelReg)",
        "let envByte = chanReg.environment",
        "phy_freq_to_channel(chanReg.countryHalf.uint8, envStep.uint16)",
        "let countryIe = cast[ptr MacIeView](ie)",
        "let ieLength = countryIe.len",
        "let triplet = countryTripletAt(addr countryIe.macIePayload[payloadOff])",
        "var firstChan = triplet.firstChan",
        "while chanIdx != triplet.numChan:",
        "chanReg.maxPower = triplet.maxPower",
    ]:
        assert expected in body

    for forbidden in [
        "let outU = cast[uint](out_ptr)",
        "cast[ptr pointer](outU + 76)",
        "let chanRegU = cast[uint](chanRegBase)",
        "cast[ptr uint8](chanRegU + 2)",
        "cast[ptr uint16](chanRegU)",
        "let ieAddr = cast[uint](ie)",
        "cast[ptr uint8](ieAddr + 1)",
        "let tripletBase = ieAddr + pos.uint",
        "cast[ptr uint8](tripletBase + 1)",
        "cast[ptr uint8](tripletBase + 2)",
        "cast[ptr uint8](chanRegU + 4)",
    ]:
        assert forbidden not in body


def test_wifi_csa_ie_builder_uses_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    helper_body = wifi_fw.rsplit("proc writeCsaIe", 1)[1].split(
        "proc me_add_ie_tim*", 1
    )[0]
    beacon_body = wifi_fw.rsplit("proc me_build_beacon*", 1)[1].split(
        "proc me_build_probe_rsp*", 1
    )[0]
    probe_body = wifi_fw.rsplit("proc me_build_probe_rsp*", 1)[1].split(
        "proc me_build_add_ba_req*", 1
    )[0]
    csa_check_body = wifi_fw.rsplit("proc me_extract_csa*", 1)[1].split(
        "proc me_extract_power_constraint*", 1
    )[0]

    for expected in [
        "CsaIeView {.packed.} = object",
        "newChannel*: uint8",
        "switchCount*: uint8",
        "next*: UncheckedArray[uint8]",
        "doAssert offsetof(CsaIeView, newChannel) == 3",
        "doAssert offsetof(CsaIeView, switchCount) == 4",
        "doAssert offsetof(CsaIeView, next) == 5",
        "doAssert offsetof(ExtendedCsaIeView, newChannel) == 4",
        "doAssert offsetof(ExtendedCsaIeView, switchCount) == 5",
        "template csaIeAt(p: pointer): ptr CsaIeView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let csa = csaIeAt(ieBuf)",
        "csa.ie.id = 37'u8",
        "csa.ie.len = 3'u8",
        "csa.switchMode = switchMode",
        "csa.newChannel = newChannel",
        "csa.switchCount = switchCount",
        "addr csa.next[0]",
    ]:
        assert expected in helper_body

    for body in [beacon_body, probe_body]:
        assert "let csaChannel = ((csaFreq.int - 2412) div 5 + 1).uint8" in body
        assert "ieBuf = writeCsaIe(ieBuf, chanCtx.channel.txPower, csaChannel, csaCount)" in body
        for forbidden in [
            "var csaIe",
            "csaIe[0]",
            "csaIe[1]",
            "csaIe[2]",
            "csaIe[3]",
            "csaIe[4]",
            "co_pack8p(ieBuf, addr csaIe[0], 5)",
            "cast[pointer](cast[uint](ieBuf) + 5)",
        ]:
            assert forbidden not in body

    for expected in [
        "switchMode = ie.switchMode",
        "newChan = ie.newChannel",
        "switchCount = ie.switchCount",
    ]:
        assert expected in csa_check_body


def test_wifi_beacon_probe_variable_ie_copies_use_cursor_helper():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    beacon_body = wifi_fw.rsplit("proc me_build_beacon*", 1)[1].split(
        "proc me_build_probe_rsp*", 1
    )[0]
    probe_body = wifi_fw.rsplit("proc me_build_probe_rsp*", 1)[1].split(
        "proc me_build_add_ba_req*", 1
    )[0]

    for expected in [
        "proc ieCursorAfter(p: pointer; n: uint): pointer {.inline.}",
        "addr cast[ptr UncheckedArray[uint8]](p)[n]",
        "proc copyIeBytes(dst: pointer; src: pointer; n: uint): pointer {.inline.}",
        "ieCursorAfter(dst, n)",
    ]:
        assert expected in wifi_fw

    for expected in [
        "var ieBuf: pointer = beaconFrameIeBody(frame)",
        "ieBuf = copyIeBytes(ieBuf, wpaIePtr, wpaIeLen.uint)",
        "ieBuf = copyIeBytes(ieBuf, appIeBeaconPtr, appIeBeaconLen.uint)",
    ]:
        assert expected in beacon_body

    for expected in [
        "let frame = probeRspFixedBodyView(buf)",
        "frame.beaconInterval = bcnInt",
        "frame.capabilityInfo = capInfo",
        "var ieBuf: pointer = probeRspIeBody(frame)",
        "ieBuf = copyIeBytes(ieBuf, appIeProbeRespPtr, appIeProbeRespLen.uint)",
    ]:
        assert expected in probe_body

    for forbidden in [
        "var ieBuf: pointer = cast[pointer](cast[uint](buf) + 36)",
        "var ieBuf: pointer = cast[pointer](cast[uint](buf) + 12)",
        "let p = cast[ptr UncheckedArray[uint8]](buf)",
        "p[8] = (bcnInt and 0xFF).uint8",
        "p[9] = ((bcnInt shr 8) and 0xFF).uint8",
        "p[10] = (capInfo and 0xFF).uint8",
        "p[11] = ((capInfo shr 8) and 0xFF).uint8",
        "let wp = cast[uint](ieBuf)",
        "ieBuf = cast[pointer](wp + wpaIeLen.uint)",
        "ieBuf = cast[pointer](cast[uint](ieBuf) + appIeBeaconLen.uint)",
        "ieBuf = cast[pointer](cast[uint](ieBuf) + appIeProbeRespLen.uint)",
    ]:
        assert forbidden not in beacon_body
        assert forbidden not in probe_body


def test_wifi_assoc_rsp_handler_uses_scan_channel_overlay_for_tpc():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc sm_assoc_rsp_handler*", 1)[1].split(
        "proc sm_deauth_handler*", 1
    )[0]

    for expected in [
        "let chan = cast[ptr ScanChannelEntry](chanPtr)",
        "var tpcPower: uint8 = cast[ptr uint8](addr chan.txPower)[]",
        "TimeoutIntervalIeView {.packed.} = object",
        "intervalType*: uint8",
        "intervalValue*: array[4, uint8]",
        "doAssert offsetof(TimeoutIntervalIeView, intervalType) == 2",
        "doAssert offsetof(TimeoutIntervalIeView, intervalValue) == 3",
        "template timeoutIntervalIeAt(p: pointer): ptr TimeoutIntervalIeView",
        "let timeoutIe = timeoutIntervalIeAt(iePtr)",
        "if timeoutIe.ie.len == 5:",
        "if timeoutIe.intervalType == 3:",
        "let retry = timeoutIe.intervalValue",
        "(retry[2].uint32 shl 16)",
    ]:
        assert expected in wifi_fw if (
            "TimeoutIntervalIeView" in expected or
            expected in ("intervalType*: uint8", "intervalValue*: array[4, uint8]") or
            expected.startswith("doAssert") or
            expected.startswith("template ")
        ) else expected in body

    for forbidden in [
        "cast[ptr uint8](cast[uint](chanPtr) + 4)",
        "cast[ptr uint8](cast[uint](iePtr) + 1)",
        "cast[ptr uint8](cast[uint](iePtr) + 2)",
        "cast[ptr uint8](cast[uint](iePtr) + 3)",
        "cast[ptr uint8](cast[uint](iePtr) + 4)",
        "cast[ptr uint8](cast[uint](iePtr) + 5)",
        "let ouiType =",
        "let ouiSubtype =",
        "let retryBytes3 =",
        "let retryBytes4 =",
        "let retryBytes5 =",
    ]:
        assert forbidden not in body


def test_wifi_beacon_channel_reads_use_scan_channel_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    check_body = wifi_fw.rsplit("proc me_beacon_check*", 1)[1].split(
        "proc me_build_capability*", 1
    )[0]
    beacon_body = wifi_fw.rsplit("proc me_build_beacon*", 1)[1].split(
        "proc me_build_probe_rsp*", 1
    )[0]
    probe_body = wifi_fw.rsplit("proc me_build_probe_rsp*", 1)[1].split(
        "proc me_build_add_ba_req*", 1
    )[0]

    for expected in [
        "doAssert offsetof(StaInfoView, reserved338) == 338",
        "template staPowerConstraintOut(sta: ptr StaInfoView): pointer",
        "cast[pointer](addr sta.reserved338[10])",
        "let chan = if chanPtr != nil: cast[ptr ScanChannelEntry](chanPtr) else: nil",
        "let chanBand = if chan != nil: chan.band else: 0'u8",
        "let chanBw = cast[ptr uint8](addr chan.txPower)[]",
    ]:
        assert expected in wifi_fw if expected.startswith(("doAssert", "template", "cast[pointer](addr sta.")) else expected in check_body

    for expected in [
        "let staPowerConstraint = staPowerConstraintOut(staInfoForIdx(vifIdx))",
        "me_extract_power_constraint(cast[pointer](iesBuf), 0, staPowerConstraint)",
    ]:
        assert expected in check_body

    for expected in [
        "let chan = cast[ptr ScanChannelEntry](chanPtr)",
        "let chanFreq = chan.prim20Freq",
    ]:
        assert expected in beacon_body

    for expected in [
        "let chan = cast[ptr ScanChannelEntry](chanPtr)",
        "let chanFreq = chan.prim20Freq",
        "let chanBand = chan.band",
    ]:
        assert expected in probe_body

    for forbidden in [
        "cast[ptr uint8](cast[uint](chanPtr) + 2)",
        "cast[ptr uint8](cast[uint](chanPtr) + 4)",
        "cast[ptr uint16](chanPtr)[]",
        "let staTab = cast[uint](addr sta_info_tab[0])",
        "let staInfoOff = vifIdx.uint * STA_ENTRY_SIZE.uint + 348",
        "let staInfoBase = staTab + staInfoOff",
        "me_extract_power_constraint(cast[pointer](iesBuf), 0, cast[pointer](staInfoBase))",
    ]:
        assert forbidden not in check_body
        assert forbidden not in beacon_body
        assert forbidden not in probe_body


def test_wifi_auth_builder_uses_typed_fixed_body_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc me_build_authenticate*", 1)[1].split(
        "proc me_build_sae_authenticate*", 1
    )[0]

    for expected in [
        "AuthFixedBodyView {.packed.} = object",
        "AuthChallengeBodyView {.packed.} = object",
        "authAlgo*: uint16",
        "authSeq*: uint16",
        "statusCode*: uint16",
        "challengeTag*: uint8",
        "challengeLen*: uint8",
        "challengeText*: array[128, uint8]",
        "template authChallengeBodyAt(p: pointer): ptr AuthChallengeBodyView",
        "doAssert sizeof(AuthFixedBodyView) == 6",
        "doAssert offsetof(AuthFixedBodyView, authSeq) == 2",
        "doAssert offsetof(AuthFixedBodyView, statusCode) == 4",
        "doAssert sizeof(AuthChallengeBodyView) == 136",
        "doAssert offsetof(AuthChallengeBodyView, challengeTag) == 6",
        "doAssert offsetof(AuthChallengeBodyView, challengeLen) == 7",
        "doAssert offsetof(AuthChallengeBodyView, challengeText) == 8",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let fixed = cast[ptr AuthFixedBodyView](buf)",
        "fixed.authAlgo = authAlgo",
        "fixed.authSeq = authSeq",
        "fixed.statusCode = statusCode",
        "let challenge = authChallengeBodyAt(buf)",
        "challenge.challengeTag = 16",
        "challenge.challengeLen = 128",
        "challenge.challengeText[i] = src[i]",
    ]:
        assert expected in body

    for forbidden in [
        "p[0] = (authAlgo and 0xFF).uint8",
        "p[1] = ((authAlgo shr 8) and 0xFF).uint8",
        "p[2] = (authSeq and 0xFF).uint8",
        "p[3] = ((authSeq shr 8) and 0xFF).uint8",
        "p[4] = (statusCode and 0xFF).uint8",
        "p[5] = ((statusCode shr 8) and 0xFF).uint8",
        "let p = cast[ptr UncheckedArray[uint8]](buf)",
        "p[6] = 16",
        "p[7] = 128",
        "p[8 + i] = src[i]",
    ]:
        assert forbidden not in body


def test_wifi_deauth_builder_uses_typed_reason_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc me_build_deauthenticate*", 1)[1].split(
        "proc me_build_beacon*", 1
    )[0]

    for expected in [
        "ManagementReasonBodyView {.packed.} = object",
        "reason*: uint16",
        "template managementReasonBodyAt(p: pointer): ptr ManagementReasonBodyView",
        "doAssert sizeof(ManagementReasonBodyView) == 2",
        "doAssert offsetof(ManagementReasonBodyView, reason) == 0",
    ]:
        assert expected in wifi_fw

    for expected in [
        "managementReasonBodyAt(buf).reason = reason",
        "return 2",
    ]:
        assert expected in body

    for forbidden in [
        "let p = cast[ptr UncheckedArray[uint8]](buf)",
        "p[0] = (reason and 0xFF).uint8",
        "p[1] = ((reason shr 8) and 0xFF).uint8",
    ]:
        assert forbidden not in body


def test_wifi_assoc_req_builder_uses_typed_assoc_info_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc me_build_associate_req_impl", 1)[1].split(
        "proc me_build_associate_rsp_impl", 1
    )[0]

    for expected in [
        "VifAssocInfoOverlay {.packed.} = object",
        "ssidLen*: uint8",
        "ssidData*: array[49, uint8]",
        "basicRates*: array[13, uint8]",
        "modeByte104*: uint8",
        "securityFlags*: uint32",
        "rsnIePtr*: uint32",
        "rsnIeLen*: uint8",
        "WmmInfoIeView {.packed.} = object",
        "qosInfo*: uint8",
        "AssocReqFixedBodyView {.packed.} = object",
        "doAssert sizeof(AssocReqFixedBodyView) == 10",
        "doAssert offsetof(AssocReqFixedBodyView, reassocBssid) == 4",
        "doAssert offsetof(VifAssocInfoOverlay, ssidLen) == 38",
        "doAssert offsetof(VifAssocInfoOverlay, basicRates) == 88",
        "doAssert offsetof(VifAssocInfoOverlay, modeByte104) == 104",
        "doAssert offsetof(VifAssocInfoOverlay, securityFlags) == 136",
        "doAssert offsetof(VifAssocInfoOverlay, rsnIePtr) == 144",
        "doAssert sizeof(WmmInfoIeView) == 9",
        "doAssert offsetof(WmmInfoIeView, qosInfo) == 8",
        "template wmmInfoIeAt(p: pointer): ptr WmmInfoIeView",
        "template vifAssocInfo(info: pointer): ptr VifAssocInfoOverlay",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let assoc = vifAssocInfo(assocInfo)",
        "let secFlags = assoc.securityFlags",
        "let fixedReq = cast[ptr AssocReqFixedBodyView](buf)",
        "fixedReq.capabilityInfo = capInfo",
        "fixedReq.listenInterval = listenInt",
        "c_memcpy(addr fixedReq.reassocBssid[0], reassocBssid, 6.csize_t)",
        "cast[pointer](addr assoc.ssidData[0]), assoc.ssidLen)",
        "let ratesPtr = cast[pointer](addr assoc.basicRates[0])",
        "let rateCount = assoc.basicRates[0]",
        "let assocIeSrc = cast[pointer](assoc.rsnIePtr)",
        "let assocIeLen = assoc.rsnIeLen.uint32",
        "else: assoc.modeByte104",
        "let wmm = wmmInfoIeAt(cursor)",
        "wmm.ie.id = 0xDD'u8",
        "wmm.oui = [0x00'u8, 0x50, 0xF2]",
        "wmm.qosInfo = qosInfo",
        "cursor = addr wmm.next[0]",
        "totalLen += sizeof(WmmInfoIeView).uint32",
        "if meEnvView().htSupp != 0:",
    ]:
        assert expected in body

    for forbidden in [
        "let assoc = cast[ptr UncheckedArray[uint8]](assocInfo)",
        "let assocU = cast[uint](assocInfo)",
        "cast[ptr uint8](writePtr)[] = (capInfo and 0xFF).uint8",
        "cast[ptr uint8](writePtr + 1)[] = ((capInfo shr 8) and 0xFF).uint8",
        "cast[ptr uint8](writePtr + 2)[] = (listenInt and 0xFF).uint8",
        "cast[ptr uint8](writePtr + 3)[] = ((listenInt shr 8) and 0xFF).uint8",
        "cast[ptr uint16](writePtr + 4)[]",
        "cast[ptr uint16](writePtr + 6)[]",
        "cast[ptr uint16](writePtr + 8)[]",
        "cast[ptr uint32](assocU + 136)[]",
        "cast[pointer](assocU + 39)",
        "assoc[38]",
        "cast[pointer](assocU + 88)",
        "cast[ptr uint8](assocU + 88)[]",
        "cast[ptr pointer](assocU + 144)[]",
        "cast[ptr uint8](assocU + 148)[]",
        "cast[ptr uint8](cast[uint](addr me_env[0]) + 0x82)",
        "let meBase = cast[uint](addr me_env[0])",
        "cast[ptr uint8](meBase + 452)",
        "var wmmIe {.noinit.}: array[9, uint8]",
        "wmmIe[0] = 0xDD",
        "co_pack8p(cast[pointer](wp), addr wmmIe[0], 9)",
        "cursor = cast[pointer](wp + 9)",
        "let meEnvHtFlag =",
    ]:
        assert forbidden not in body


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
    call_body = wifi_fw.rsplit("proc notifier_chain_call*", 1)[1].split(
        "proc notifier_chain_call_fromeCritical*", 1
    )[0]
    call_critical_body = wifi_fw.rsplit(
        "proc notifier_chain_call_fromeCritical*", 1
    )[1].split("# ###########################################################################\n#                  Replay Counter", 1)[0]

    assert "NotifierNodeView {.packed.} = object" in wifi_fw
    assert "ElementNotifyContextView {.packed.} = object" in wifi_fw
    assert "template notifierNodeView(node: ptr CoListHdr): ptr NotifierNodeView" in wifi_fw
    assert "template elementNotifyContextAt(ctx: pointer): ptr ElementNotifyContextView" in wifi_fw
    assert "doAssert offsetof(NotifierNodeView, callback) == 0" in wifi_fw
    assert "doAssert offsetof(NotifierNodeView, next) == 4" in wifi_fw
    assert "doAssert offsetof(NotifierNodeView, priority) == 8" in wifi_fw
    assert "doAssert offsetof(ElementNotifyContextView, state) == 8" in wifi_fw
    assert "let newNode = notifierNodeView(notifier)" in insert_body
    assert "let curNode = notifierNodeView(cur)" in insert_body
    assert "newNode.next = cast[pointer](cur)" in insert_body
    assert "pos = addr curNode.next" in insert_body
    assert "notifierNodeView(notifier).next" in remove_body
    assert "pos = addr notifierNodeView(cur).next" in remove_body
    assert "let node = notifierNodeView(cur)" in call_body
    assert "node.callback" in call_body
    assert "node.next" in call_body
    assert "let node = notifierNodeView(cur)" in call_critical_body
    assert "node.callback" in call_critical_body
    assert "node.next" in call_critical_body
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
        call_body,
        call_critical_body,
    ]:
        assert "while true:" not in body

    notifier_bodies = insert_body + remove_body + call_body + call_critical_body
    for forbidden in [
        "cast[ptr int32](cast[uint](notifier) + 8)",
        "cast[ptr int32](cast[uint](cur) + 8)",
        "cast[ptr pointer](cast[uint](notifier) + 4)",
        "cast[ptr pointer](cast[uint](cur) + 4)",
        "cast[ptr pointer](cast[uint](cur))[]",
    ]:
        assert forbidden not in notifier_bodies

    notify_body = wifi_fw.rsplit("proc element_notify*", 1)[1].split(
        "proc is_cck_group*", 1
    )[0]
    assert "let ctxState = elementNotifyContextAt(ctx).state" in notify_body
    assert "cast[ptr pointer](cast[uint](ctx) + 8)" not in notify_body


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
    assert "proc bleKeEventYieldNeeded(drained, field: uint32): bool" in ble
    assert "var drained = 0'u32" in event_body
    assert "inc drained" in event_body
    assert "if bleKeEventYieldNeeded(drained, field):" in event_body
    assert "inc nim_ble_ke_event_yield_count" in event_body
    assert "nim_ble_ke_event_yield_field = field" in event_body
    assert "return" in event_body


def test_ble_timer_scheduler_yields_under_expired_backlog():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    timer_body = ble.split("proc patch_ble_ke_timer_schedule*", 1)[1].split(
        "proc ble_ke_timer_schedule*", 1
    )[0]
    service_body = ble.split("proc bleDrainScheduledWork(): bool =", 1)[1].split(
        "proc bleControllerServiceStep", 1
    )[0]

    assert "BleKeTimerDrainLimit = 8'u32" in ble
    assert "nim_ble_ke_timer_yield_count" in ble
    assert "nim_ble_ke_timer_yield_time" in ble
    assert "proc bleKeTimerExpired(timer: ptr KeTimer): bool {.inline.}" in ble
    assert "proc bleKeTimerPendingWork(): bool {.inline.}" in ble
    assert "var drained = 0'u32" in timer_body
    assert "while drained < BleKeTimerDrainLimit:" in timer_body
    assert "while ke_timer_list.first != nil:" not in timer_body
    assert "inc drained" in timer_body
    assert "if drained >= BleKeTimerDrainLimit and bleKeTimerExpired(next):" in timer_body
    assert "inc nim_ble_ke_timer_yield_count" in timer_body
    assert "nim_ble_ke_timer_yield_time = next.time" in timer_body
    assert "ble_ke_timer_hw_set(next)" in timer_body
    assert "bleKeTimerPendingWork()" in service_body
    assert "ble_ke_timer_schedule()" in service_body


def test_ble_hci_reset_settle_is_cps_state_not_busy_wait():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    settle_body = ble.split("proc bleArmHciResetSettle()", 1)[1].split(
        "proc bleHciResetSettlePending()", 1
    )[0]
    pending_body = ble.split("proc bleHciResetSettlePending()", 1)[1].split(
        "when defined(bl808BleConnectTrace)", 1
    )[0]
    has_work_body = ble.split("proc bleControllerHasPendingWork", 1)[1].split(
        "proc bleDrainMainQueueMessage", 1
    )[0]
    service_body = ble.split("proc bleDrainScheduledWork(): bool =", 1)[1].split(
        "proc bleControllerServiceStep", 1
    )[0]

    assert "proc bleSettleAfterHciReset" not in ble
    assert "while clicReadMtime()" not in ble
    assert "nim_ble_hci_reset_settle_pending" in ble
    assert "nim_ble_hci_reset_settle_yield_count" in ble
    assert "bleHciResetSettleDeadline =" in settle_body
    assert "nim_ble_hci_reset_settle_pending = 1" in settle_body
    assert "if clicReadMtime() < bleHciResetSettleDeadline:" in pending_body
    assert "nim_ble_hci_reset_settle_pending = 0" in pending_body
    assert "bleHciResetSettlePending() or bleEventPendingWork()" in has_work_body
    assert "if bleHciResetSettlePending():" in service_body
    assert "inc nim_ble_hci_reset_settle_yield_count" in service_body
    assert "return true" in service_body
    assert "bleArmHciResetSettle()" in ble


def test_ble_hci_cmd_status_uses_typed_descriptor_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    body = ble.split("proc hci_msg_cmd_status_exp*", 1)[1].split(
        "proc hci_msg_evt_get_hl_tl_dest*", 1
    )[0]
    evt_body = ble.split("proc hci_msg_evt_get_hl_tl_dest*", 1)[1].split(
        "proc led_init*", 1
    )[0]

    assert "HciCmdStatusDescView {.packed.} = object" in ble
    assert "expectedStatusWord*: uint32" in ble
    assert "doAssert sizeof(HciCmdStatusDescView) == 12" in ble
    assert "doAssert offsetof(HciCmdStatusDescView, expectedStatusWord) == 8" in ble
    assert "template hciCmdStatusDescView(desc: pointer): ptr HciCmdStatusDescView" in ble
    assert "HciEventRoutingView {.packed.} = object" in ble
    assert "eventCode*: uint8" in ble
    assert "route*: uint8" in ble
    assert "hostLid*: uint8" in ble
    assert "doAssert sizeof(HciEventRoutingView) == 3" in ble
    assert "doAssert offsetof(HciEventRoutingView, route) == 1" in ble
    assert "doAssert offsetof(HciEventRoutingView, hostLid) == 2" in ble
    assert "template hciEventRouting(evt: pointer): ptr HciEventRoutingView" in ble
    assert "hciCmdStatusDescView(desc).expectedStatusWord == 0'u32" in body
    assert "hciEventRouting(evt).route and 0x03'u8" in evt_body
    assert "hciEventRouting(evt).hostLid" in evt_body
    assert "cast[ptr uint32](cast[uint](desc) + 8'u)" not in body
    assert "cast[uint](desc)" not in body
    assert "cast[ptr UncheckedArray[uint8]](evt)[1]" not in evt_body
    assert "cast[ptr UncheckedArray[uint8]](evt)[2]" not in evt_body


def test_ble_raw_hci_rf_and_ecc_paths_use_typed_overlays():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    hci_helpers = ble.split("proc hciRawOpcode(data: pointer)", 1)[1].split(
        "template hciLeCreateConnReq", 1
    )[0]
    rf_body = ble.split("proc ble_rf_get_pwr_offset*", 1)[1].split(
        "proc ble_rf_set_tx_channel*", 1
    )[0]
    dhkey_body = ble.split("proc sendLeGenerateDhKeyComplete", 1)[1].split(
        "proc sendLeReadLocalP256PublicKeyComplete", 1
    )[0]

    for expected in [
        "HciRawCmdView {.packed.} = object",
        "opcode*: uint16",
        "paramLen*: uint8",
        "params*: UncheckedArray[uint8]",
        "doAssert offsetof(HciRawCmdView, paramLen) == 2",
        "doAssert offsetof(HciRawCmdView, params) == 3",
        "template hciRawCmd(data: pointer): ptr HciRawCmdView",
    ]:
        assert expected in ble

    for expected in [
        "hciRawCmd(data).opcode",
        "hciRawCmd(data).paramLen",
        "addr hciRawCmd(data).params[0]",
    ]:
        assert expected in hci_helpers

    assert "cast[ptr UncheckedArray[int8]](rf_pwr_offset_table)[channel]" in rf_body
    assert "let peerPoint = cast[ptr EccPoint256](params)" in dhkey_body
    assert "let peerY = addr peerPoint.y[0]" in dhkey_body

    for forbidden in [
        "cast[ptr uint8](cast[uint](data) + 3'u)",
        "cast[ptr int8](cast[uint](rf_pwr_offset_table) + channel.uint)",
        "cast[ptr uint8](cast[uint](params) + ECC_KEY_LEN.uint)",
    ]:
        assert forbidden not in hci_helpers + rf_body + dhkey_body


def test_ble_em_buffer_helpers_use_typed_descriptor_tables():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    helper_body = ble.split("proc emRxDescAt", 1)[1].split(
        "when defined(bl808m0) and bl808BleNimConnectionEnabled and",
        1,
    )[0]
    buffer_body = ble.split("proc em_buf_init*", 1)[1].split(
        "# ---------------------------------------------------------------------------\n# ======================== EA",
        1,
    )[0]

    for expected in [
        "EmBufRxFreeSlot* {.packed.} = object",
        "status*: uint16",
        "buf_ptr*: uint16",
        "doAssert sizeof(EmBufRxFreeSlot) == EM_BUF_RX_DESC_SIZE",
        "doAssert offsetof(EmBufRxFreeSlot, status) == 0",
        "doAssert offsetof(EmBufRxFreeSlot, buf_ptr) == 8",
        "template bleEmBytes(): ptr UncheckedArray[uint8]",
        "template btbleEmBytes(): ptr UncheckedArray[uint8]",
        "proc bleEmPointer(offset: uint16): pointer",
        "proc btbleEmBytePtr(offset: uint16): ptr uint8",
        "proc btbleEmPayload(offset: uint16): ptr UncheckedArray[uint8]",
        "proc btbleEmRead8(offset: uint16): uint8",
        "proc btbleEmWrite8(offset: uint16, value: uint8)",
        "proc copyBtbleEmBytes(dstOffset: uint16, src: ptr uint8, len: int)",
        "template emRxDescTableAt(base: uint32): ptr UncheckedArray[EmBufRxDesc]",
        "template emTxDescTableAt(base: uint32): ptr UncheckedArray[EmBufTxDesc]",
        "template emRxFreeTable(): ptr UncheckedArray[EmBufRxFreeSlot]",
        "cast[ptr UncheckedArray[EmBufRxFreeSlot]](bleEmPointer(0x35C'u16))",
        "proc emRxFreeSlotAt(idx: uint16): ptr EmBufRxFreeSlot",
    ]:
        assert expected in ble

    for expected in [
        "addr emRxDescTableAt(base)[idx]",
        "addr emTxDescTableAt(base)[idx]",
        "addr emRxFreeTable()[idx]",
        "addr emRxFreeSlotAt(idx).status",
        "addr emRxFreeSlotAt(idx).buf_ptr",
        "let desc = emRxDescAt(rx_base, i)",
        "volatileStore(addr desc.buf_ptr, buf_offset)",
        "volatileStore(addr emTxDescAt(tx_base, i).status, 0'u16)",
        "let status_ptr = emRxFreeStatusField(idx)",
        "let buf_ptr = emRxBufferPointerField(idx)",
    ]:
        assert expected in helper_body + buffer_body

    for forbidden in [
        "base + idx.uint32 * EM_BUF_RX_DESC_SIZE",
        "base + idx.uint32 * EM_BUF_TX_DESC_SIZE",
        "BLE_EM_BASE + 0x35C'u32 +",
        "BLE_EM_BASE + 0x364'u32 +",
        "idx.uint32 * EM_BUF_RX_DESC_SIZE",
    ]:
        assert forbidden not in helper_body

    for expected in [
        "let data = btbleEmBytePtr(dataOff)",
        "btbleEmPayload(dataOff)",
        "let opcode = btbleEmRead8(dataOff)",
        "btbleEmWrite8(NimAclTxEmOffset, 0'u8)",
        "btbleEmWrite8(NimLlcpTxEmOffset + i.uint16, pdu[i])",
        "copyBtbleEmBytes(NimAclTxEmOffset, cast[ptr uint8](data), len.int)",
        "return bleEmPointer(offset)",
    ]:
        assert expected in ble

    for forbidden in [
        "cast[ptr uint8](BTBLE_EM_BASE + dataOff.uint32)",
        "BTBLE_EM_BASE + dataOff.uint32",
        "BTBLE_EM_BASE + NimAclTxEmOffset.uint32",
        "BTBLE_EM_BASE + NimLlcpTxEmOffset.uint32",
        "BLE_EM_BASE + offset.uint32",
    ]:
        assert forbidden not in ble


def test_ble_vendor_llc_start_uses_typed_param_overlays():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    body = ble.split(
        'proc nimLlcStart(conhdl: uint16, params: pointer): uint8',
        1,
    )[1].split("proc llc_llcp_tx_check*", 1)[0]

    for expected in [
        "NimVendorLlcStartParamsView {.packed.} = object",
        "connIntervalMin*: uint16",
        "connIntervalMax*: uint16",
        "connLatency*: uint16",
        "peerFeatureSeed*: array[5, uint8]",
        "controllerDefaults*: NimLlcControllerDefaultsView",
        "template nimVendorLlcStartParams(params: pointer): ptr NimVendorLlcStartParamsView",
        "template nimLldConStartParams(params: pointer): ptr NimLldConStartParamsView",
        "doAssert sizeof(NimVendorLlcStartParamsView) == 56",
        "doAssert offsetof(NimVendorLlcStartParamsView, connIntervalMin) == 10",
        "doAssert offsetof(NimVendorLlcStartParamsView, connIntervalMax) == 12",
        "doAssert offsetof(NimVendorLlcStartParamsView, connLatency) == 14",
        "doAssert offsetof(NimVendorLlcStartParamsView, peerFeatureSeed) == 16",
        "doAssert offsetof(NimVendorLlcStartParamsView, peerRate) == 22",
        "doAssert offsetof(NimVendorLlcStartParamsView, timingFine) == 24",
        "doAssert offsetof(NimVendorLlcStartParamsView, timingClock) == 28",
        "doAssert offsetof(NimVendorLlcStartParamsView, anchorClock) == 32",
        "doAssert offsetof(NimVendorLlcStartParamsView, phyRate) == 36",
        "doAssert offsetof(NimVendorLlcStartParamsView, directAnchorMode) == 37",
        "doAssert offsetof(NimVendorLlcStartParamsView, peerRxAddrType) == 38",
        "doAssert offsetof(NimVendorLlcStartParamsView, controllerDefaults) == 40",
    ]:
        assert expected in ble

    for expected in [
        "let start = nimVendorLlcStartParams(params)",
        "envView.connIntervalMin = start.connIntervalMin",
        "envView.connIntervalMax = start.connIntervalMax",
        "envView.connLatency = start.connLatency",
        "envView.peerRate = start.peerRate",
        "cast[pointer](addr start.peerFeatureSeed[0])",
        "if start.phyRate < co_rate_to_phy.len.uint8",
        "envView.maxTxTime = start.controllerDefaults.maxTxTime",
        "let a = start.controllerDefaults.maxRxTime",
        "envView.minEventSpacing = start.controllerDefaults.minEventSpacing",
        "if start.directAnchorMode == 0'u8:",
        "envView.authPayloadTimeout = start.controllerDefaults.authPayloadTimeout",
        "envView.channelSelection = start.controllerDefaults.channelSelection",
        "let lld = nimLldConStartParams(addr lldParams[0])",
        "lld.accessAddress = start.accessAddress",
        "lld.crcInit = start.crcInit",
        "lld.transmitWindowSize = start.transmitWindowSize",
        "lld.windowOffset = start.windowOffset",
        "lld.interval = start.connIntervalMin",
        "lld.latency = start.connIntervalMax",
        "lld.supervisionTimeout = start.connLatency",
        "lld.channelMap = start.peerFeatureSeed",
        "lld.timingFine = start.timingFine",
        "lld.timingClock = start.timingClock",
        "lld.anchorClock = start.anchorClock",
        "lld.timingSelector = start.directAnchorMode",
        "lld.rate = start.phyRate",
        "lld.peerRxAddrType = start.peerRxAddrType",
    ]:
        assert expected in body

    for forbidden in [
        "let p = cast[ptr UncheckedArray[uint8]](params)",
        "getLe16(p, 10)",
        "getLe16(p, 12)",
        "getLe16(p, 14)",
        "p[22]",
        "addr p[16]",
        "p[36]",
        "getLe16(p, 40)",
        "getLe16(p, 42)",
        "getLe16(p, 44)",
        "p[46]",
        "p[47]",
        "p[37]",
        "p[48]",
        "p[54]",
        "getLe16(p, 50)",
        "getLe16(p, 52)",
        "let l = cast[ptr UncheckedArray[uint8]](addr lldParams[0])",
        "for i in 0 ..< 23:",
        "putLe16(l, 24",
        "putLe32(l, 28",
        "putLe32(l, 32",
        "l[36] = p[37]",
        "l[37] = p[36]",
        "putLe16(l, 38",
    ]:
        assert forbidden not in body


def test_ble_btble_rx_ring_uses_typed_descriptor_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    adv_body = ble.split("proc serviceBtbleAdvRxDescriptors", 1)[1].split(
        "proc resetBtbleLinkLayerCore", 1
    )[0]
    lld_body = ble.split("proc lld_rxdesc_buf_ready*", 1)[1].split(
        "when not defined(bl808m0):", 1
    )[0]
    timing_body = ble.split("proc btbleAdvRxFine", 1)[1].split(
        "when defined(bl808m0) and bl808BleNimPureCentral:", 1
    )[0]
    reset_body = ble.split("proc resetBtbleAdvRxRing", 1)[1].split(
        "proc prepareBtbleConnectionRxRingForHandoff", 1
    )[0]

    for expected in [
        "BtbleRxDescView* {.packed.} = object",
        "BtbleScanReqPduView* {.packed.} = object",
        "scanA*: BdAddr",
        "advA*: BdAddr",
        "doAssert sizeof(BtbleScanReqPduView) == 12",
        "doAssert offsetof(BtbleScanReqPduView, scanA) == 0",
        "doAssert offsetof(BtbleScanReqPduView, advA) == 6",
        "header*: uint16",
        "rxClock*: uint16",
        "meta*: uint16",
        "dataOffset*: uint16",
        "doAssert sizeof(BtbleRxDescView) == 0x20",
        "doAssert offsetof(BtbleRxDescView, header) == 0x04",
        "doAssert offsetof(BtbleRxDescView, rxClock) == 0x08",
        "doAssert offsetof(BtbleRxDescView, meta) == 0x0C",
        "doAssert offsetof(BtbleRxDescView, dataOffset) == 0x14",
        "template btbleRxDescAt(descAddr: uint32): ptr BtbleRxDescView",
        "proc btbleRxDescStatus(descAddr: uint32): uint16",
        "proc btbleRxDescHeader(descAddr: uint32): uint16",
        "proc btbleRxDescMeta(descAddr: uint32): uint16",
        "proc btbleRxDescDataOffset(descAddr: uint32): uint16",
        "proc btbleRxDescReset(descAddr, nextOffset, dataOffset: uint32)",
        "proc btbleRxDescClearDone(descAddr: uint32; status: uint16)",
        "proc btbleRxDescReleaseLink(descAddr: uint32; status: uint16)",
    ]:
        assert expected in ble

    for expected in [
        "btbleRxDescMeta(desc) and 0x03FF'u16",
        "btbleRxDescClock(desc).uint32",
        "volatileLoad(addr rxDesc.timing0).uint32",
    ]:
        assert expected in timing_body

    for expected in [
        "let desc = BTBLE_EM_BASE + btbleRxDescOffset(i)",
        "let nextOff = btbleRxDescOffset(i + 1'u32)",
        "let rxBuf = 0x0B0D'u32 + i * 0x104'u32",
        "btbleRxDescReset(desc, nextOff, rxBuf)",
    ]:
        assert expected in reset_body

    for expected in [
        "let desc = BTBLE_EM_BASE + btbleRxDescOffset(i)",
        "let status = btbleRxDescStatus(desc)",
        "let header = btbleRxDescHeader(desc)",
        "let buf = btbleRxDescDataOffset(desc)",
        "let meta = btbleRxDescMeta(desc)",
        "let scanReq = btbleScanReqPduAt(buf)",
        "nim_ble_dbg_rx_scan_req_last_scana0 = bdAddrLow(addr scanReq.scanA)",
        "nim_ble_dbg_rx_scan_req_last_adva0 = bdAddrLow(addr scanReq.advA)",
        "if scanReq.advA.data[j] != expectedAdvAddrByte(j):",
        "let payload = btbleEmPayload(buf)",
        "btbleRxDescClearDone(desc, status)",
    ]:
        assert expected in adv_body

    for expected in [
        "btbleRxDescSetDataOffset(nimLldRxDescAddr(idx), buf)",
        "let status = btbleRxDescStatus(desc)",
        "let header = btbleRxDescHeader(desc)",
        "let meta = btbleRxDescMeta(desc)",
        "btbleRxDescDataOffset(desc)",
        "let payload = btbleEmPayload(dataOff)",
        "btbleRxDescReleaseLink(desc, status)",
        "btbleRxDescClearDone(descAddr, status)",
    ]:
        assert expected in lld_body

    for forbidden in [
        "read16(desc + 0x04'u32)",
        "read16(desc + 0x08'u32)",
        "read16(desc + 0x0C'u32)",
        "read16(desc + 0x14'u32)",
        "read16(desc + NimRxDescHeaderOffset)",
        "read16(desc + NimRxDescDataOffsetOffset)",
        "write16(desc, status and NimRxDescLinkMask)",
        "write16(desc, status and not 0x8000'u16)",
        "write16(desc + 0x14'u32, buf)",
        "for off in countup(0'u32, 0x1E'u32, 2'u32):",
        "write16(desc + off, 0'u16)",
        "write16(desc, uint16((nextOff shr 2) and 0xFFFF'u32))",
        "write16(desc + 0x14'u32, uint16(rxBuf and 0xFFFF'u32))",
        "let payloadBase = BTBLE_EM_BASE + buf.uint32",
        "readBleAddrLow(payloadBase)",
        "readBleAddrHigh(payloadBase)",
        "readBleAddrLow(payloadBase + 6'u32)",
        "readBleAddrHigh(payloadBase + 6'u32)",
        "read8(payloadBase + 6'u32 + j.uint32)",
    ]:
        assert forbidden not in adv_body
        assert forbidden not in lld_body
        assert forbidden not in timing_body
        assert forbidden not in reset_body


def test_ble_scan_report_uses_typed_advertising_pdu_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    body = ble.split(
        "proc sendLeAdvertisingReportFromRxDesc(header: uint16, buf: uint16) =",
        1,
    )[1].split(
        "when bl808BleNimPureCentral:",
        1,
    )[0]

    for expected in [
        "BtbleAdvPduView* {.packed.} = object",
        "advA*: BdAddr",
        "data*: array[31, uint8]",
        "doAssert offsetof(BtbleAdvPduView, advA) == 0",
        "doAssert offsetof(BtbleAdvPduView, data) == 6",
        "template btbleAdvPduAt(buf: uint16): ptr BtbleAdvPduView",
        "let advPdu = btbleAdvPduAt(buf)",
        "evt[4 + i] = advPdu.advA.data[i]",
        "evt[11 + i] = advPdu.data[i]",
    ]:
        assert expected in ble if expected.startswith(("Btble", "advA", "data", "doAssert", "template")) else expected in body

    for forbidden in [
        "let payloadBase = BTBLE_EM_BASE + buf.uint32",
        "read8(payloadBase + i.uint32)",
        "read8(payloadBase + 6'u32 + i.uint32)",
    ]:
        assert forbidden not in body


def test_ble_legacy_scan_init_tx_descs_use_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    scan_body = ble.split("proc programBtbleScanReqTxDesc", 1)[1].split(
        "proc nimScanIntervalSlots", 1
    )[0]
    init_body = ble.split("proc programBtbleInitTxDesc", 1)[1].split(
        "proc nimInitRecordRx", 1
    )[0]

    for expected in [
        "template btbleLegacyTxDescAt(descAddr: uint32): ptr BtbleConnTxDescView",
        "proc btbleLegacyTxDescProgram(descAddr: uint32; status, header,",
        "let desc = btbleLegacyTxDescAt(descAddr)",
        "volatileStore(addr desc.status, status)",
        "volatileStore(addr desc.header, header)",
        "volatileStore(addr desc.dataOffset, dataOffset)",
    ]:
        assert expected in ble

    for expected in [
        "let desc = BTBLE_EM_BASE + NimScanReqTxDescOffset",
        "let header = if nimScanActive(): nimScanReqHeader() else: 0'u16",
        "btbleLegacyTxDescProgram(desc, 0'u16, header, 0'u16)",
    ]:
        assert expected in scan_body

    for expected in [
        "let desc = BTBLE_EM_BASE + NimInitTxDescOffset",
        "btbleLegacyTxDescProgram(",
        "desc, 0'u16, nimInitConnectIndHeader(), NimInitConnReqDataOffset0)",
    ]:
        assert expected in init_body

    for forbidden in [
        "write16(desc + 0x00'u32",
        "write16(desc + 0x02'u32",
        "write16(desc + 0x04'u32",
    ]:
        assert forbidden not in scan_body
        assert forbidden not in init_body


def test_ble_connection_tx_ring_uses_typed_descriptor_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    conn_body = ble.split("proc nimConnDescAddr", 1)[1].split(
        "proc nimConnEventReached", 1
    )[0]

    for expected in [
        "BtbleConnTxDescView* {.packed.} = object",
        "status*: uint16",
        "header*: uint16",
        "dataOffset*: uint16",
        "reserved06*: array[10, uint8]",
        "doAssert sizeof(BtbleConnTxDescView) == 0x10",
        "doAssert offsetof(BtbleConnTxDescView, status) == 0",
        "doAssert offsetof(BtbleConnTxDescView, header) == 0x02",
        "doAssert offsetof(BtbleConnTxDescView, dataOffset) == 0x04",
    ]:
        assert expected in ble

    for expected in [
        "template btbleConnTxDescAt(descAddr: uint32): ptr BtbleConnTxDescView",
        "proc btbleConnTxDescStatus(descAddr: uint32): uint16",
        "proc btbleConnTxDescSetStatus(descAddr: uint32; status: uint16)",
        "proc btbleConnTxDescSetHeader(descAddr: uint32; header: uint16)",
        "proc btbleConnTxDescSetDataOffset(descAddr: uint32; offset: uint16)",
        "proc btbleConnTxDescClear(descAddr: uint32; nextOff: uint16)",
        "btbleConnTxDescClear(desc, nextOff)",
        "btbleConnTxDescSetHeader(desc, descHeader)",
        "btbleConnTxDescSetDataOffset(desc, dataOff)",
        "btbleConnTxDescSetStatus(desc, nimConnDescStatus(nextOff, softwareOwned = false))",
        "btbleConnTxDescStatus(nimConnDescAddr(nim_conn_state.txAckDescOff))",
    ]:
        assert expected in conn_body

    for forbidden in [
        "write16(desc + 0x02'u32",
        "write16(desc + 0x04'u32",
        "write16(desc + 0x06'u32",
        "write16(desc + 0x08'u32",
        "write16(desc + 0x0A'u32",
        "write16(desc + 0x0C'u32",
        "write16(desc + 0x0E'u32",
        "read16(nimConnDescAddr(nim_conn_state.txAckDescOff))",
    ]:
        assert forbidden not in conn_body


def test_ble_lld_connection_start_uses_typed_param_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    anchor_body = ble.split("proc nimConnAnchorFromTiming", 1)[1].split(
        "proc nimConnAnchorFromRxTimestamp", 1
    )[0]
    start_body = ble.rsplit(
        "proc nimLldConStart(conhdl: uint16, params: pointer): uint8 {.cdecl.} =",
        1,
    )[1].split("proc nimLldConLlcpTx", 1)[0]

    for expected in [
        "centralRole*: uint8",
        "reserved41*: array[7, uint8]",
        "doAssert offsetof(NimLldConStartParamsView, centralRole) == 40",
        "template nimLldConStartParams(params: pointer): ptr NimLldConStartParamsView",
        "proc nimConnCrcInit(params: ptr NimLldConStartParamsView): uint32",
        "proc nimConnLegacyLeadSelector(params: ptr NimLldConStartParamsView): uint8",
        "proc nimConnChannelSelection2(params: ptr NimLldConStartParamsView): bool",
        "proc nimConnAnchorFromTiming(params: ptr NimLldConStartParamsView,",
    ]:
        assert expected in ble

    for expected in [
        "let rateIdx = params.rate",
        "var clock = params.timingClock and 0x0FFFFFFF'u32",
        "var fine = int32(params.timingFine) + int32(syncPos) * 2'i32",
        "uint32(params.transmitWindowSize) * NimConnHalfSlotsPerConnIntervalUnit",
        "uint32(params.windowOffset) * NimConnHalfSlotsPerConnIntervalUnit",
        "uint16(nimConnLegacyLeadSelector(params))",
    ]:
        assert expected in anchor_body

    for expected in [
        "let start = nimLldConStartParams(params)",
        "let snapshotBytes = cast[ptr UncheckedArray[uint8]](params)",
        "nim_lld_con_start_param[i] = snapshotBytes[i]",
        "nim_conn_state.centralRole = start.centralRole != 0'u8",
        "nim_conn_state.directAnchorMode = start.timingSelector == 0'u8",
        "nim_conn_state.accessAddress = start.accessAddress",
        "nim_conn_state.crcInit = nimConnCrcInit(start)",
        "uint32(start.interval) * NimConnHalfSlotsPerConnIntervalUnit",
        "uint32(start.supervisionTimeout) * NimConnHalfSlotsPerSupervisionUnit",
        "nim_conn_state.channelMap = start.channelMap",
        "nim_conn_state.hopIncrement = start.hopIncrement and 0x1F'u8",
        "nim_conn_state.channelSelection2 = nimConnChannelSelection2(start)",
        "nim_conn_state.rate = start.rate",
        "if start.rate.int < co_rate_to_phy.len:",
        "if start.timingSelector != 0'u8:",
        "start.timingClock and 0x0FFFFFFF'u32",
        "nimConnAnchorFromTiming(start, nim_conn_state.anchorFine)",
        "uint32(start.transmitWindowSize) * NimConnHalfUsPerConnWindowUnit",
        "start.anchorClock and 0x0FFFFFFF'u32",
        "let scaIdx = start.peerSleepClockAccuracy and 0x07'u8",
        "uint32(start.windowOffset) * NimConnHalfSlotsPerConnIntervalUnit",
    ]:
        assert expected in start_body

    for forbidden in [
        "nim_conn_state.centralRole = p[NimConnStartCentralRoleOffset] != 0'u8",
        "nim_conn_state.directAnchorMode = p[36] == 0'u8",
        "uint32(p[0]) or (uint32(p[1]) shl 8)",
        "uint32(p[4]) or (uint32(p[5]) shl 8)",
        "getLe16(p, 10)",
        "getLe16(p, 14)",
        "nim_conn_state.channelMap[i] = p[16 + i]",
        "nim_conn_state.hopIncrement = p[21] and 0x1F'u8",
        "nim_conn_state.channelSelection2 = p[38] != 0'u8",
        "nim_conn_state.rate = p[37]",
        "if p[37].int < co_rate_to_phy.len:",
        "if p[36] != 0'u8:",
        "nimConnAnchorFromTiming(p, nim_conn_state.anchorFine)",
        "uint32(p[7]) * NimConnHalfUsPerConnWindowUnit",
        "let scaIdx = p[22] and 0x07'u8",
        "getLe16(p, 8)",
    ]:
        assert forbidden not in start_body


def test_ble_llcp_fixed_pdus_use_typed_overlays():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    length_record_body = ble.split("proc nimLlcpRecordPeerDataLength", 1)[1].split(
        "proc nimLlcpConfigCount", 1
    )[0]
    length_build_body = ble.split("proc nimLlcpBuildLengthPdu", 1)[1].split(
        "proc nimLlcpBuildOpcodePdu", 1
    )[0]
    update_build_body = ble.split("proc nimLlcpBuildConnectionUpdateInd", 1)[1].split(
        "proc nimLlcpStartConnectionUpdate", 1
    )[0]
    update_start_body = ble.split("proc nimLlcpStartConnectionUpdate", 1)[1].split(
        "proc nimLlcpBuildChannelMapInd", 1
    )[0]
    channel_build_body = ble.split("proc nimLlcpBuildChannelMapInd", 1)[1].split(
        "proc nimLlcpBuildVersionInd", 1
    )[0]
    version_build_body = ble.split("proc nimLlcpBuildVersionInd", 1)[1].split(
        "proc nimLlcpBuildFeatureRsp", 1
    )[0]
    phy_rsp_body = ble.split("proc nimLlcpBuildPhyRsp", 1)[1].split(
        "proc nimLlcpBuildPingRsp", 1
    )[0]
    reject_ind_body = ble.split("proc nimLlcpBuildRejectInd", 1)[1].split(
        "proc nimLlcpBuildRejectExtInd", 1
    )[0]
    reject_ext_body = ble.split("proc nimLlcpBuildRejectExtInd", 1)[1].split(
        "proc nimLlcpBuildUnsupportedFeatureRsp", 1
    )[0]
    unknown_rsp_body = ble.split("proc nimLlcpBuildUnknownRsp", 1)[1].split(
        "proc nimLlcpBuildTerminateInd", 1
    )[0]
    terminate_body = ble.split("proc nimLlcpBuildTerminateInd", 1)[1].split(
        "proc nimLlcpRespond", 1
    )[0]
    update_receive_body = ble.rsplit("proc nimConnReceiveConnectionUpdateIndBytes", 1)[1].split(
        "proc nimConnReceivePhyUpdateIndBytes", 1
    )[0]
    channel_receive_body = ble.rsplit("proc nimConnReceiveChannelMapIndBytes", 1)[1].split(
        "proc nimConnReceiveChannelMapInd", 1
    )[0]

    for expected in [
        "NimLlcpLengthPduView {.packed.} = object",
        "maxRxOctets: uint16",
        "maxRxTime: uint16",
        "maxTxOctets: uint16",
        "maxTxTime: uint16",
        "NimLlcpConnectionUpdateIndView {.packed.} = object",
        "winSize: uint8",
        "winOffset: uint16",
        "interval: uint16",
        "latency: uint16",
        "timeout: uint16",
        "instant: uint16",
        "NimLlcpChannelMapIndView {.packed.} = object",
        "channelMap: array[5, uint8]",
        "NimLlcpVersionIndView {.packed.} = object",
        "version: uint8",
        "companyId: uint16",
        "subversion: uint16",
        "NimLlcpPhyPairPduView {.packed.} = object",
        "txPhys: uint8",
        "rxPhys: uint8",
        "NimLlcpRejectIndView {.packed.} = object",
        "errorCode: uint8",
        "NimLlcpRejectExtIndView {.packed.} = object",
        "rejectedOpcode: uint8",
        "NimLlcpUnknownRspView {.packed.} = object",
        "unknownOpcode: uint8",
        "NimLlcpTerminateIndView {.packed.} = object",
        "reason: uint8",
        "doAssert sizeof(NimLlcpLengthPduView) == 9",
        "doAssert offsetof(NimLlcpLengthPduView, maxRxOctets) == 1",
        "doAssert offsetof(NimLlcpLengthPduView, maxRxTime) == 3",
        "doAssert offsetof(NimLlcpLengthPduView, maxTxOctets) == 5",
        "doAssert offsetof(NimLlcpLengthPduView, maxTxTime) == 7",
        "doAssert sizeof(NimLlcpConnectionUpdateIndView) == 12",
        "doAssert offsetof(NimLlcpConnectionUpdateIndView, winOffset) == 2",
        "doAssert offsetof(NimLlcpConnectionUpdateIndView, interval) == 4",
        "doAssert offsetof(NimLlcpConnectionUpdateIndView, latency) == 6",
        "doAssert offsetof(NimLlcpConnectionUpdateIndView, timeout) == 8",
        "doAssert offsetof(NimLlcpConnectionUpdateIndView, instant) == 10",
        "doAssert sizeof(NimLlcpChannelMapIndView) == 8",
        "doAssert offsetof(NimLlcpChannelMapIndView, channelMap) == 1",
        "doAssert offsetof(NimLlcpChannelMapIndView, instant) == 6",
        "doAssert sizeof(NimLlcpVersionIndView) == 6",
        "doAssert offsetof(NimLlcpVersionIndView, version) == 1",
        "doAssert offsetof(NimLlcpVersionIndView, companyId) == 2",
        "doAssert offsetof(NimLlcpVersionIndView, subversion) == 4",
        "doAssert sizeof(NimLlcpPhyPairPduView) == 3",
        "doAssert offsetof(NimLlcpPhyPairPduView, txPhys) == 1",
        "doAssert offsetof(NimLlcpPhyPairPduView, rxPhys) == 2",
        "doAssert sizeof(NimLlcpRejectIndView) == 2",
        "doAssert offsetof(NimLlcpRejectIndView, errorCode) == 1",
        "doAssert sizeof(NimLlcpRejectExtIndView) == 3",
        "doAssert offsetof(NimLlcpRejectExtIndView, rejectedOpcode) == 1",
        "doAssert offsetof(NimLlcpRejectExtIndView, errorCode) == 2",
        "doAssert sizeof(NimLlcpUnknownRspView) == 2",
        "doAssert offsetof(NimLlcpUnknownRspView, unknownOpcode) == 1",
        "doAssert sizeof(NimLlcpTerminateIndView) == 2",
        "doAssert offsetof(NimLlcpTerminateIndView, reason) == 1",
        "template nimLlcpLengthPduAt(pdu: ptr UncheckedArray[uint8]): ptr NimLlcpLengthPduView",
        "template nimLlcpLengthPdu(pdu: var NimLlcpPdu): ptr NimLlcpLengthPduView",
        "template nimLlcpConnectionUpdateInd(pdu: var NimLlcpPdu): ptr NimLlcpConnectionUpdateIndView",
        "template nimLlcpConnectionUpdateIndAt(pdu: ptr UncheckedArray[uint8]): ptr NimLlcpConnectionUpdateIndView",
        "template nimLlcpChannelMapInd(pdu: var NimLlcpPdu): ptr NimLlcpChannelMapIndView",
        "template nimLlcpChannelMapIndAt(pdu: ptr UncheckedArray[uint8]): ptr NimLlcpChannelMapIndView",
        "template nimLlcpVersionInd(pdu: var NimLlcpPdu): ptr NimLlcpVersionIndView",
        "template nimLlcpPhyPairPdu(pdu: var NimLlcpPdu): ptr NimLlcpPhyPairPduView",
        "template nimLlcpRejectInd(pdu: var NimLlcpPdu): ptr NimLlcpRejectIndView",
        "template nimLlcpRejectExtInd(pdu: var NimLlcpPdu): ptr NimLlcpRejectExtIndView",
        "template nimLlcpUnknownRsp(pdu: var NimLlcpPdu): ptr NimLlcpUnknownRspView",
        "template nimLlcpTerminateInd(pdu: var NimLlcpPdu): ptr NimLlcpTerminateIndView",
    ]:
        assert expected in ble

    for expected in [
        "let lengthPdu = nimLlcpLengthPduAt(pdu)",
        "if lengthPdu.opcode != LlcpLengthReq and lengthPdu.opcode != LlcpLengthRsp:",
        "nimLlcpStorePeerDataLength(lengthPdu.maxRxOctets, lengthPdu.maxRxTime,",
        "lengthPdu.maxTxOctets, lengthPdu.maxTxTime)",
    ]:
        assert expected in length_record_body

    for expected in [
        "let body = nimLlcpLengthPdu(result)",
        "body.opcode = opcode",
        "body.maxRxOctets = NimBleLeMaxDataOctets",
        "body.maxRxTime = NimBleLeMaxDataTime",
        "body.maxTxOctets = nim_llcp_state.localTxOctets",
        "body.maxTxTime = nim_llcp_state.localTxTime",
    ]:
        assert expected in length_build_body

    for expected in [
        "let body = nimLlcpConnectionUpdateInd(result)",
        "body.opcode = LlcpConnectionUpdateInd",
        "body.winSize = 1'u8",
        "body.winOffset = 0'u16",
        "body.interval = interval",
        "body.latency = req.connLatency",
        "body.timeout = req.supervisionTimeout",
        "body.instant = instant",
    ]:
        assert expected in update_build_body

    for expected in [
        "let update = nimLlcpConnectionUpdateInd(pdu)",
        "update.winSize",
        "update.winOffset",
        "update.instant",
    ]:
        assert expected in update_start_body

    for expected in [
        "let update = nimLlcpConnectionUpdateIndAt(pdu)",
        "let interval = update.interval",
        "let latency = update.latency",
        "let timeout = update.timeout",
        "nimConnStorePendingConnectionUpdate(update.winSize, update.winOffset,",
        "interval, latency, timeout, update.instant, notifyHost = true)",
    ]:
        assert expected in update_receive_body

    for expected in [
        "let body = nimLlcpChannelMapInd(result)",
        "body.opcode = LlcpChannelMapInd",
        "nimBleCurrentChannelMap(cast[ptr UncheckedArray[uint8]](addr body.channelMap[0]))",
        "body.instant = instant",
    ]:
        assert expected in channel_build_body

    for expected in [
        "let body = nimLlcpVersionInd(result)",
        "body.opcode = LlcpVersionInd",
        "body.version = NimLlcpLocalVersion",
        "body.companyId = NimLlcpLocalCompanyId",
        "body.subversion = NimLlcpLocalSubversion",
    ]:
        assert expected in version_build_body

    for expected in [
        "let body = nimLlcpPhyPairPdu(result)",
        "body.opcode = LlcpPhyRsp",
        "body.txPhys = NimLlcpPhy1M",
        "body.rxPhys = NimLlcpPhy1M",
    ]:
        assert expected in phy_rsp_body

    for expected in [
        "let body = nimLlcpRejectInd(result)",
        "body.opcode = LlcpRejectInd",
        "body.errorCode = errorCode",
    ]:
        assert expected in reject_ind_body

    for expected in [
        "let body = nimLlcpRejectExtInd(result)",
        "body.opcode = LlcpRejectExtInd",
        "body.rejectedOpcode = rejectedOpcode",
        "body.errorCode = errorCode",
    ]:
        assert expected in reject_ext_body

    for expected in [
        "let body = nimLlcpUnknownRsp(result)",
        "body.opcode = LlcpUnknownRsp",
        "body.unknownOpcode = opcode",
    ]:
        assert expected in unknown_rsp_body

    for expected in [
        "let body = nimLlcpTerminateInd(result)",
        "body.opcode = LlcpTerminateInd",
        "body.reason = reason",
    ]:
        assert expected in terminate_body

    for expected in [
        "let body = nimLlcpChannelMapIndAt(pdu)",
        "nim_conn_state.pendingChannelMap[i] = body.channelMap[i]",
        "nim_conn_state.channelMapInstant = body.instant",
    ]:
        assert expected in channel_receive_body

    combined = (
        length_record_body
        + length_build_body
        + update_build_body
        + update_start_body
        + update_receive_body
        + channel_build_body
        + channel_receive_body
        + version_build_body
        + phy_rsp_body
        + reject_ind_body
        + reject_ext_body
        + unknown_rsp_body
        + terminate_body
    )
    for forbidden in [
        "getLe16(pdu, 1)",
        "getLe16(pdu, 3)",
        "getLe16(pdu, 5)",
        "getLe16(pdu, 7)",
        "getLe16(pdu, 2)",
        "getLe16(pdu, 4)",
        "getLe16(pdu, 6)",
        "getLe16(pdu, 8)",
        "uint16(pdu[10]) or (uint16(pdu[11]) shl 8)",
        "putLe16(raw, 1, NimBleLeMaxDataOctets)",
        "putLe16(raw, 3, NimBleLeMaxDataTime)",
        "putLe16(raw, 5, nim_llcp_state.localTxOctets)",
        "putLe16(raw, 7, nim_llcp_state.localTxTime)",
        "result.data[0] = LlcpConnectionUpdateInd",
        "result.data[1] = 1'u8",
        "putLe16(raw, 2, 0'u16)",
        "putLe16(raw, 4, interval)",
        "putLe16(raw, 6, req.connLatency)",
        "putLe16(raw, 8, req.supervisionTimeout)",
        "putLe16(raw, 10, instant)",
        "result.data[0] = LlcpChannelMapInd",
        "result.data[i + 1] = map[i]",
        "putLe16(cast[ptr UncheckedArray[uint8]](addr result.data[0]), 6",
        "nim_conn_state.pendingChannelMap[i] = pdu[i + 1]",
        "uint16(pdu[6]) or (uint16(pdu[7]) shl 8)",
        "getLe16(cast[ptr UncheckedArray[uint8]](addr pdu.data[0]), 2)",
        "getLe16(cast[ptr UncheckedArray[uint8]](addr pdu.data[0]), 10)",
        "result.data[0] = LlcpVersionInd",
        "result.data[1] = NimLlcpLocalVersion",
        "putLe16(cast[ptr UncheckedArray[uint8]](addr result.data[0]), 2",
        "putLe16(cast[ptr UncheckedArray[uint8]](addr result.data[0]), 4",
        "result.data[0] = LlcpPhyRsp",
        "result.data[1] = NimLlcpPhy1M",
        "result.data[2] = NimLlcpPhy1M",
        "result.data[0] = LlcpRejectInd",
        "result.data[1] = errorCode",
        "result.data[0] = LlcpRejectExtInd",
        "result.data[1] = rejectedOpcode",
        "result.data[2] = errorCode",
        "result.data[0] = LlcpUnknownRsp",
        "result.data[1] = opcode",
        "result.data[0] = LlcpTerminateInd",
        "result.data[1] = reason",
    ]:
        assert forbidden not in combined


def test_ble_connection_tx_elements_use_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    manual_tx_body = ble.split("when bl808BleNimManualConnTx:", 1)[1].split(
        "proc nimLlcpWireLength", 1
    )[0]
    conn_body = ble.rsplit("proc nimLldConLlcpTx", 1)[1].split(
        "proc startNimConnectionFromConnectInd", 1
    )[0]
    host_body = ble.split("proc hciAclTxDataStatus", 1)[1].split(
        "proc hciOwnedAclTxDataReceived", 1
    )[0]

    for expected in [
        "NimConnTxElementView {.packed.} = object",
        "reserved00: array[4, uint8]",
        "emOffset: uint16",
        "length: uint16",
        "doAssert sizeof(NimConnTxElementView) == 8",
        "doAssert offsetof(NimConnTxElementView, emOffset) == 4",
        "doAssert offsetof(NimConnTxElementView, length) == 6",
        "template nimConnTxElementAt(buf: pointer): ptr NimConnTxElementView",
        "proc nimConnTxElementInit(buf: pointer; emOffset, length: uint16)",
        "tx.emOffset = emOffset",
        "tx.length = length",
    ]:
        assert expected in ble

    for expected in [
        "nimConnTxElementInit(addr nim_acl_empty_tx_buf[0], NimAclTxEmOffset, 0'u16)",
        "nimConnTxElementInit(addr nim_llcp_tx_buf[0], NimLlcpTxEmOffset, len.uint16)",
    ]:
        assert expected in manual_tx_body

    for expected in [
        "let tx = nimConnTxElementAt(buf)",
        "nim_conn_state.txEmOffset = tx.emOffset",
        "nim_conn_state.txLen = uint8(tx.length)",
        "let len = tx.length",
        "nim_conn_state.txLen = uint8(len)",
    ]:
        assert expected in conn_body

    for expected in [
        "nimConnTxElementInit(addr nim_acl_host_tx_buf[0], NimAclTxEmOffset, len)",
    ]:
        assert expected in host_body

    combined = manual_tx_body + conn_body + host_body
    for forbidden in [
        "let txb = cast[ptr UncheckedArray[uint8]](addr nim_acl_empty_tx_buf[0])",
        "let txb = cast[ptr UncheckedArray[uint8]](addr nim_llcp_tx_buf[0])",
        "let txb = cast[ptr UncheckedArray[uint8]](addr nim_acl_host_tx_buf[0])",
        "putLe16(txb, 4, NimAclTxEmOffset)",
        "putLe16(txb, 4, NimLlcpTxEmOffset)",
        "putLe16(txb, 6, 0'u16)",
        "putLe16(txb, 6, len)",
        "txb[6] = len",
        "getLe16(raw, 4)",
        "getLe16(raw, 6)",
    ]:
        assert forbidden not in combined


def test_ble_llc_proc_env_uses_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    state_body = ble.split("proc llc_proc_state_get", 1)[1].split(
        "proc llc_proc_timer_pause_set", 1
    )[0]
    init_body = ble.split("proc llc_proc_init*", 1)[1].split(
        "proc Add2SelfBigHex256*", 1
    )[0]
    err_body = ble.split("proc llc_proc_err_ind*", 1)[1].split(
        "proc llc_proc_id_get*", 1
    )[0]
    id_body = ble.split("proc llc_proc_id_get*", 1)[1].split(
        "when defined(bl808m0) and bl808BleNimConnectionEnabled:", 1
    )[0]

    for expected in [
        "LlcProcEnvView {.packed.} = object",
        "errCallback: pointer",
        "procId: uint8",
        "state: uint8",
        "reserved06: uint8",
        "doAssert offsetof(LlcProcEnvView, errCallback) == 0",
        "doAssert offsetof(LlcProcEnvView, procId) == 4",
        "doAssert offsetof(LlcProcEnvView, state) == 5",
        "doAssert offsetof(LlcProcEnvView, reserved06) == 6",
        "template llcProcEnv(procEnv: pointer): ptr LlcProcEnvView",
    ]:
        assert expected in ble

    for expected in [
        "llcProcEnv(procEnv).state",
        "llcProcEnv(procEnv).state = state",
    ]:
        assert expected in state_body

    for expected in [
        "let env = llcProcEnv(procEnv)",
        "env.errCallback = cb",
        "env.procId = procId",
        "env.state = 0",
        "env.reserved06 = 0",
    ]:
        assert expected in init_body

    for expected in [
        "let procEnv = llc_proc_get(conhdl, procId)",
        "let cb = llcProcEnv(procEnv).errCallback",
    ]:
        assert expected in err_body

    for expected in [
        "llcProcEnv(env).procId",
        "llcProcEnv(env).procId = newProcId",
        "llcProcEnv(procEnv).procId = procId",
    ]:
        assert expected in id_body

    combined = state_body + init_body + err_body + id_body
    for forbidden in [
        "cast[ptr UncheckedArray[uint8]](procEnv)[5]",
        "cast[ptr UncheckedArray[uint8]](procEnv)[5] = state",
        "let raw = cast[ptr UncheckedArray[uint8]](procEnv)",
        "cast[ptr pointer](procEnv)[] = cb",
        "raw[4] = procId",
        "raw[5] = 0",
        "raw[6] = 0",
        "let cb = cast[ptr pointer](env)[]",
        "cast[ptr UncheckedArray[uint8]](env)[4]",
        "cast[ptr UncheckedArray[uint8]](env)[4] = newProcId",
        "cast[ptr UncheckedArray[uint8]](procEnv)[4] = procId",
    ]:
        assert forbidden not in combined


def test_ble_acl_indications_use_typed_overlays():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    hci_body = ble.split("proc hci_acl_data_handler*", 1)[1].split(
        "else:\n  abiNoopHandler(hci_acl_data_handler)", 1
    )[0]
    lld_body = ble.split("proc lld_acl_rx_ind_handler*", 1)[1].split(
        "proc lld_acl_tx_cfm_handler*", 1
    )[0]

    for expected in [
        "HciAclDataIndView {.packed.} = object",
        "handleFlags*: uint16",
        "length*: uint16",
        "dataAddr*: uint32",
        "LldAclRxIndView {.packed.} = object",
        "bufRef*: uint16",
        "llidFlags*: uint8",
        "doAssert sizeof(HciAclDataIndView) == 8",
        "doAssert offsetof(HciAclDataIndView, length) == 2",
        "doAssert offsetof(HciAclDataIndView, dataAddr) == 4",
        "doAssert sizeof(LldAclRxIndView) == 5",
        "doAssert offsetof(LldAclRxIndView, length) == 2",
        "doAssert offsetof(LldAclRxIndView, llidFlags) == 4",
        "template hciAclDataInd(param: pointer): ptr HciAclDataIndView",
        "template lldAclRxInd(param: pointer): ptr LldAclRxIndView",
    ]:
        assert expected in ble

    for expected in [
        "let ind = hciAclDataInd(param)",
        "let handleFlags = ind.handleFlags",
        "let len = ind.length",
        "let data = cast[ptr uint8](ind.dataAddr.uint)",
    ]:
        assert expected in hci_body

    for expected in [
        "let ind = lldAclRxInd(param)",
        "let bufRef = ind.bufRef",
        "let len = ind.length",
        "let llid = ind.llidFlags and 0x03'u8",
    ]:
        assert expected in lld_body

    combined = hci_body + lld_body
    for forbidden in [
        "let raw = cast[ptr UncheckedArray[uint8]](param)",
        "let handleFlags = getLe16(raw, 0)",
        "let len = getLe16(raw, 2)",
        "let bufRef = getLe16(raw, 0)",
        "uint32(raw[4]) or (uint32(raw[5]) shl 8)",
        "(uint32(raw[6]) shl 16) or (uint32(raw[7]) shl 24)",
        "let llid = raw[4] and 0x03'u8",
    ]:
        assert forbidden not in combined


def test_ble_host_acl_packet_builder_uses_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    body = ble.split("proc sendHostAclBytes", 1)[1].split(
        "proc sendHostAclData", 1
    )[0]

    for expected in [
        "HciAclHostPacketView {.packed.} = object",
        "handleFlags*: uint16",
        "length*: uint16",
        "payload*: UncheckedArray[uint8]",
        "doAssert offsetof(HciAclHostPacketView, handleFlags) == 0",
        "doAssert offsetof(HciAclHostPacketView, length) == 2",
        "doAssert offsetof(HciAclHostPacketView, payload) == 4",
        "let acl = cast[ptr HciAclHostPacketView](addr pkt[0])",
        "acl.handleFlags = hciHandle",
        "acl.length = len.uint16",
        "acl.payload[i] = src[i]",
    ]:
        assert expected in ble if expected.startswith(("Hci", "handle", "length", "payload", "doAssert")) else expected in body

    for forbidden in [
        "pkt[0] = uint8(hciHandle and 0x00FF'u16)",
        "pkt[1] = uint8((hciHandle shr 8) and 0x00FF'u16)",
        "pkt[2] = len",
        "pkt[3] = 0'u8",
        "pkt[4 + i] = src[i]",
    ]:
        assert forbidden not in body


def test_ble_disconnect_complete_event_uses_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    body = ble.split("proc sendDisconnectComplete", 1)[1].split(
        "proc drainNimScanReport", 1
    )[0]

    for expected in [
        "HciDisconnectCompleteEventView {.packed.} = object",
        "status*: uint8",
        "handle*: uint16",
        "reason*: uint8",
        "doAssert sizeof(HciDisconnectCompleteEventView) == 4",
        "doAssert offsetof(HciDisconnectCompleteEventView, handle) == 1",
        "doAssert offsetof(HciDisconnectCompleteEventView, reason) == 3",
        "let body = cast[ptr HciDisconnectCompleteEventView](addr evt[0])",
        "body.status = 0'u8",
        "body.handle = handle",
        "body.reason = reason",
    ]:
        assert expected in ble if expected.startswith(("Hci", "status", "handle", "reason", "doAssert")) else expected in body

    for forbidden in [
        "evt[0] = 0'u8",
        "evt[1] = uint8(handle and 0xFF)",
        "evt[2] = uint8((handle shr 8) and 0xFF)",
        "evt[3] = reason",
    ]:
        assert forbidden not in body


def test_ble_connection_complete_event_uses_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    body = ble.rsplit("proc sendLeConnectionCompleteStatusHandle", 1)[1].split(
        "proc sendLeConnectionCompleteStatus", 1
    )[0]

    for expected in [
        "HciLeConnectionCompleteEventView {.packed.} = object",
        "subevent*: uint8",
        "status*: uint8",
        "handle*: uint16",
        "role*: uint8",
        "peerAddrType*: uint8",
        "peerAddr*: BdAddr",
        "interval*: uint16",
        "latency*: uint16",
        "timeout*: uint16",
        "accuracy*: uint8",
        "doAssert sizeof(HciLeConnectionCompleteEventView) == 19",
        "doAssert offsetof(HciLeConnectionCompleteEventView, status) == 1",
        "doAssert offsetof(HciLeConnectionCompleteEventView, handle) == 2",
        "doAssert offsetof(HciLeConnectionCompleteEventView, role) == 4",
        "doAssert offsetof(HciLeConnectionCompleteEventView, peerAddrType) == 5",
        "doAssert offsetof(HciLeConnectionCompleteEventView, peerAddr) == 6",
        "doAssert offsetof(HciLeConnectionCompleteEventView, interval) == 12",
        "doAssert offsetof(HciLeConnectionCompleteEventView, latency) == 14",
        "doAssert offsetof(HciLeConnectionCompleteEventView, timeout) == 16",
        "doAssert offsetof(HciLeConnectionCompleteEventView, accuracy) == 18",
        "let body = cast[ptr HciLeConnectionCompleteEventView](addr evt[0])",
        "body.subevent = 0x01'u8",
        "body.status = status",
        "body.handle = handle",
        "body.role = role",
        "body.peerAddrType = req.peerAddrType",
        "body.peerAddr = req.peerAddr",
        "body.interval = req.connIntervalMin",
        "body.latency = req.connLatency",
        "body.timeout = req.supervisionTimeout",
        "body.accuracy = 0",
    ]:
        assert expected in ble if expected.startswith(("Hci", "subevent", "status", "handle", "role", "peerAddr", "interval", "latency", "timeout", "accuracy", "doAssert")) else expected in body

    for forbidden in [
        "evt[0] = 0x01'u8",
        "evt[1] = status",
        "evt[2] = uint8(handle and 0x00FF'u16)",
        "evt[3] = uint8((handle shr 8) and 0x00FF'u16)",
        "evt[4] = role",
        "evt[5] = req.peerAddrType",
        "evt[6 + i] = req.peerAddr.data[i]",
        "evt[12] = uint8(req.connIntervalMin and 0xFF'u16)",
        "evt[13] = uint8(req.connIntervalMin shr 8)",
        "evt[14] = uint8(req.connLatency and 0xFF'u16)",
        "evt[15] = uint8(req.connLatency shr 8)",
        "evt[16] = uint8(req.supervisionTimeout and 0xFF'u16)",
        "evt[17] = uint8(req.supervisionTimeout shr 8)",
        "evt[18] = 0",
    ]:
        assert forbidden not in body


def test_ble_encryption_change_event_uses_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    body = ble.rsplit("proc sendEncryptionChange", 1)[1].split(
        "proc sendRemoteVersionInfoComplete", 1
    )[0]

    for expected in [
        "HciEncryptionChangeEventView {.packed.} = object",
        "status*: uint8",
        "handle*: uint16",
        "enabled*: uint8",
        "doAssert sizeof(HciEncryptionChangeEventView) == 4",
        "doAssert offsetof(HciEncryptionChangeEventView, handle) == 1",
        "doAssert offsetof(HciEncryptionChangeEventView, enabled) == 3",
        "let body = cast[ptr HciEncryptionChangeEventView](addr evt[0])",
        "body.status = status",
        "body.handle = handle",
        "body.enabled = enabled",
    ]:
        assert expected in ble if expected.startswith(("Hci", "status", "handle", "enabled", "doAssert")) else expected in body

    for forbidden in [
        "var evt = [status, uint8(handle and 0xFF)",
        "uint8((handle shr 8) and 0xFF), enabled]",
    ]:
        assert forbidden not in body


def test_ble_remote_version_complete_event_uses_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    body = ble.rsplit("proc sendRemoteVersionInfoComplete", 1)[1].split(
        "proc sendLeConnectionUpdateComplete", 1
    )[0]

    for expected in [
        "HciRemoteVersionInfoCompleteEventView {.packed.} = object",
        "status*: uint8",
        "handle*: uint16",
        "version*: uint8",
        "companyId*: uint16",
        "subversion*: uint16",
        "doAssert sizeof(HciRemoteVersionInfoCompleteEventView) == 8",
        "doAssert offsetof(HciRemoteVersionInfoCompleteEventView, handle) == 1",
        "doAssert offsetof(HciRemoteVersionInfoCompleteEventView, version) == 3",
        "doAssert offsetof(HciRemoteVersionInfoCompleteEventView, companyId) == 4",
        "doAssert offsetof(HciRemoteVersionInfoCompleteEventView, subversion) == 6",
        "let body = cast[ptr HciRemoteVersionInfoCompleteEventView](addr evt[0])",
        "body.status = status",
        "body.handle = handle",
        "body.version = 0x09'u8",
        "body.companyId = 0x01BF'u16",
        "body.subversion = 0x0001'u16",
    ]:
        assert expected in ble if expected.startswith(("Hci", "status", "handle", "version", "companyId", "subversion", "doAssert")) else expected in body

    for forbidden in [
        "var evt = [",
        "uint8(handle and 0xFF)",
        "uint8((handle shr 8) and 0xFF)",
        "0xBF'u8, 0x01'u8",
        "0x01'u8, 0x00'u8",
    ]:
        assert forbidden not in body


def test_ble_connection_update_complete_event_uses_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    body = ble.rsplit("proc sendLeConnectionUpdateCompleteValues", 1)[1].split(
        "proc sendLeRemoteFeaturesComplete", 1
    )[0]

    for expected in [
        "HciLeConnectionUpdateCompleteEventView {.packed.} = object",
        "subevent*: uint8",
        "status*: uint8",
        "handle*: uint16",
        "interval*: uint16",
        "latency*: uint16",
        "timeout*: uint16",
        "doAssert sizeof(HciLeConnectionUpdateCompleteEventView) == 10",
        "doAssert offsetof(HciLeConnectionUpdateCompleteEventView, status) == 1",
        "doAssert offsetof(HciLeConnectionUpdateCompleteEventView, handle) == 2",
        "doAssert offsetof(HciLeConnectionUpdateCompleteEventView, interval) == 4",
        "doAssert offsetof(HciLeConnectionUpdateCompleteEventView, latency) == 6",
        "doAssert offsetof(HciLeConnectionUpdateCompleteEventView, timeout) == 8",
        "let body = cast[ptr HciLeConnectionUpdateCompleteEventView](addr evt[0])",
        "body.subevent = 0x03'u8",
        "body.status = status",
        "body.handle = handle",
        "body.interval = interval",
        "body.latency = latency",
        "body.timeout = timeout",
    ]:
        assert expected in ble if expected.startswith(("Hci", "subevent", "status", "handle", "interval", "latency", "timeout", "doAssert")) else expected in body

    for forbidden in [
        "evt[0] = 0x03'u8",
        "evt[1] = status",
        "evt[2] = uint8(handle and 0xFF)",
        "evt[3] = uint8((handle shr 8) and 0xFF)",
        "evt[4] = uint8(interval and 0xFF'u16)",
        "evt[5] = uint8(interval shr 8)",
        "evt[6] = uint8(latency and 0xFF'u16)",
        "evt[7] = uint8(latency shr 8)",
        "evt[8] = uint8(timeout and 0xFF'u16)",
        "evt[9] = uint8(timeout shr 8)",
    ]:
        assert forbidden not in body


def test_ble_le_phy_update_complete_event_uses_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    body = ble.rsplit("proc sendLePhyUpdateComplete", 1)[1].split(
        "proc sendLeEncryptComplete", 1
    )[0]

    for expected in [
        "HciLePhyUpdateCompleteEventView {.packed.} = object",
        "subevent*: uint8",
        "status*: uint8",
        "handle*: uint16",
        "txPhy*: uint8",
        "rxPhy*: uint8",
        "doAssert sizeof(HciLePhyUpdateCompleteEventView) == 6",
        "doAssert offsetof(HciLePhyUpdateCompleteEventView, status) == 1",
        "doAssert offsetof(HciLePhyUpdateCompleteEventView, handle) == 2",
        "doAssert offsetof(HciLePhyUpdateCompleteEventView, txPhy) == 4",
        "doAssert offsetof(HciLePhyUpdateCompleteEventView, rxPhy) == 5",
        "let body = cast[ptr HciLePhyUpdateCompleteEventView](addr evt[0])",
        "body.subevent = 0x0C'u8",
        "body.status = status",
        "body.handle = handle",
        "body.txPhy = txPhy",
        "body.rxPhy = rxPhy",
    ]:
        assert expected in ble if expected.startswith(("Hci", "subevent", "status", "handle", "txPhy", "rxPhy", "doAssert")) else expected in body

    for forbidden in [
        "var evt = [0x0C'u8, status, uint8(handle and 0xFF)",
        "uint8((handle shr 8) and 0xFF), txPhy, rxPhy]",
    ]:
        assert forbidden not in body


def test_ble_le_remote_features_complete_event_uses_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    body = ble.rsplit("proc sendLeRemoteFeaturesComplete", 1)[1].split(
        "proc sendLePhyUpdateComplete", 1
    )[0]

    for expected in [
        "HciLeRemoteFeaturesCompleteEventView {.packed.} = object",
        "subevent*: uint8",
        "status*: uint8",
        "handle*: uint16",
        "features*: array[8, uint8]",
        "doAssert sizeof(HciLeRemoteFeaturesCompleteEventView) == 12",
        "doAssert offsetof(HciLeRemoteFeaturesCompleteEventView, status) == 1",
        "doAssert offsetof(HciLeRemoteFeaturesCompleteEventView, handle) == 2",
        "doAssert offsetof(HciLeRemoteFeaturesCompleteEventView, features) == 4",
        "let body = cast[ptr HciLeRemoteFeaturesCompleteEventView](addr evt[0])",
        "body.subevent = 0x04'u8",
        "body.status = status",
        "body.handle = handle",
        "body.features[i] = nimBleFeatureByte(features, i)",
    ]:
        assert expected in ble if expected.startswith(("Hci", "subevent", "status", "handle", "features", "doAssert")) else expected in body

    for forbidden in [
        "var evt = [",
        "uint8(handle and 0xFF)",
        "uint8((handle shr 8) and 0xFF)",
        "evt[4 + i] = nimBleFeatureByte(features, i)",
    ]:
        assert forbidden not in body


def test_ble_connection_event_record_uses_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    helper_body = ble.split("template btbleConnEventAt", 1)[1].split(
        "proc nimConnDescAddr", 1
    )[0]
    program_body = ble.split("proc nimConnProgramEm", 1)[1].split(
        "proc nimConnProgramChannel", 1
    )[0]
    tx_body = ble.split("proc nimConnProgramTxDescriptors", 1)[1].split(
        "proc nimConnArmPendingHostAclTx", 1
    )[0]
    channel_body = ble.split("proc nimConnProgramChannel", 1)[1].split(
        "proc nimConnScheduleLeadSlotsForCurrentEvent", 1
    )[0]

    for expected in [
        "BtbleConnEventView* {.packed.} = object",
        "activityType*: uint16",
        "phyControl*: uint16",
        "accessAddrLow*: uint16",
        "channel*: uint16",
        "rxSync*: uint16",
        "txDescPtr*: uint16",
        "txDuration*: uint16",
        "channelMap01*: uint16",
        "rxTiming*: uint16",
        "eventCounter*: uint16",
        "doAssert sizeof(BtbleConnEventView) == 0x68",
        "doAssert offsetof(BtbleConnEventView, txDescPtr) == 0x24",
        "doAssert offsetof(BtbleConnEventView, eventCounter) == 0x60",
        "template btbleConnEventAt(eventAddr: uint32): ptr BtbleConnEventView",
    ]:
        assert expected in ble

    for expected in [
        "proc nimConnEventView(conhdl: uint16): ptr BtbleConnEventView",
        "proc nimConnEventSetRxSync(conhdl: uint16; timing: uint16)",
        "proc nimConnEventSetPacketDurations(conhdl: uint16;",
        "proc nimConnEventSetTxDescPtr(conhdl: uint16; descPtr: uint16)",
        "proc nimConnEventSetChannel(conhdl: uint16; channelWord: uint16)",
        "proc nimConnEventSetEventCounter(conhdl: uint16; eventCounter: uint16)",
    ]:
        assert expected in helper_body

    for expected in [
        "let event = nimConnEventView(conhdl)",
        "volatileStore(addr event.activityType, activityType)",
        "volatileStore(addr event.control,",
        "volatileStore(addr event.phyControl, phyControl)",
        "volatileStore(addr event.accessAddrLow,",
        "volatileStore(addr event.crcInitLow,",
        "volatileStore(addr event.rfConfig, uint16(rwip_rf[NimConnRfConfigIndex]))",
        "volatileStore(addr event.txDescPtr, nimConnEmDescPtr(nimConnTxDescOffset(0'u8)))",
        "volatileStore(addr event.channelMap01,",
        "volatileStore(addr event.rxTiming, NimConnRxTimingDefault)",
        "volatileStore(addr event.eventCounter, nim_conn_state.eventCounter)",
    ]:
        assert expected in program_body

    assert "nimConnEventSetTxDescPtr(nim_conn_state.handle, nimConnEmDescPtr(descOff))" in tx_body
    assert "nimConnEventSetChannel(conhdl, channelWord)" in channel_body
    assert "nimConnEventSetEventCounter(conhdl, nim_conn_state.eventCounter)" in channel_body
    assert "nimConnEventSetPacketDurations(conhdl, durationHalfUs)" in ble
    assert "nimConnEventSetRxSync(conhdl, timing)" in ble

    for forbidden in [
        "write16(nimConnEmAddr(conhdl, 0x1E'u32), timing)",
        "write16(nimConnEmAddr(conhdl, 0x2E'u32), durationHalfUs)",
        "write16(nimConnEmAddr(conhdl, 0x30'u32), durationHalfUs)",
        "write16(nimConnEmAddr(conhdl, 0x24'u32), nimConnEmDescPtr(firstOff))",
        "write16(nimConnEmAddr(nim_conn_state.handle, 0x24'u32)",
        "write16(nimConnEmAddr(conhdl, 0x18'u32), channelWord)",
        "write16(nimConnEmAddr(conhdl, 0x60'u32), nim_conn_state.eventCounter)",
        "write16(base + 0x00'u32, activityType)",
        "write16(base + 0x02'u32,",
        "write16(base + 0x06'u32, phyControl)",
        "write16(base + 0x0E'u32,",
        "write16(base + 0x10'u32,",
        "write16(base + 0x12'u32,",
        "write16(base + 0x14'u32, crcHigh)",
        "write16(base + 0x1A'u32,",
        "write16(base + 0x1C'u32, 1'u16)",
        "write16(base + 0x1E'u32,",
        "write16(base + 0x24'u32,",
        "write16(base + 0x32'u32,",
        "write16(base + 0x34'u32,",
        "write16(base + 0x36'u32,",
        "write16(base + 0x38'u32,",
        "write16(base + 0x3A'u32,",
        "write16(base + 0x60'u32,",
        "write16(base + 0x62'u32,",
        "write16(base + 0x64'u32,",
        "write16(base + 0x66'u32,",
    ]:
        assert forbidden not in helper_body
        assert forbidden not in program_body
        assert forbidden not in tx_body
        assert forbidden not in channel_body


def test_ble_llc_channel_maps_use_typed_overlays():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    llc_body = ble.split(
        "proc llc_ch_assess_get_current_ch_map*", 1
    )[1].split(
        "# ---------------------------------------------------------------------------\n# ======================== LLD",
        1,
    )[0]
    disconnect_body = ble.split(
        "proc llc_util_dicon_procedure*", 1
    )[1].split(
        "proc llc_util_get_free_conhdl*", 1
    )[0]
    llm_init_body = ble.split("proc llm_init*", 1)[1].split(
        "proc llm_ble_ready*", 1
    )[0]
    llm_master_body = ble.split("proc llm_master_ch_map_get*", 1)[1].split(
        "proc llm_rx_path_comp_get*", 1
    )[0]
    llm_update_body = ble.split("proc llm_ch_map_update*", 1)[1].split(
        "proc llm_ch_map_update_ind_handler*", 1
    )[0]

    for expected in [
        "LlcChannelAssessmentView {.packed.} = object",
        "flags*: uint16",
        "channelMap*: array[5, uint8]",
        "LlmChannelMapView {.packed.} = object",
        "localMap*: array[5, uint8]",
        "masterMap*: array[5, uint8]",
        "LlcDisconnectStateView {.packed.} = object",
        "reason*: uint8",
        "active*: uint8",
        "doAssert offsetof(LlcChannelAssessmentView, flags) == 344",
        "doAssert offsetof(LlcChannelAssessmentView, channelMap) == 346",
        "doAssert offsetof(LlcDisconnectStateView, reason) == 413",
        "doAssert offsetof(LlcDisconnectStateView, active) == 414",
        "doAssert offsetof(LlmChannelMapView, localMap) == 344",
        "doAssert offsetof(LlmChannelMapView, masterMap) == 349",
        "template llcChannelAssessment(env: ptr LlcConEnv): ptr LlcChannelAssessmentView",
        "template llcDisconnectState(env: ptr LlcConEnv): ptr LlcDisconnectStateView",
        "template llmChannelMaps(): ptr LlmChannelMapView",
    ]:
        assert expected in ble

    for expected in [
        "let assess = llcChannelAssessment(llc_env[conhdl])",
        "c_memcpy(map, addr assess.channelMap[0], 5)",
        "assess.flags = assess.flags or 0x0008'u16",
        "assess.flags = assess.flags and not 0x0008'u16",
        "c_memcpy(addr assess.channelMap[0], map, 5)",
    ]:
        assert expected in llc_body

    for expected in [
        "let maps = llmChannelMaps()",
        "maps.localMap[i] = 0xFF'u8",
        "maps.masterMap[i] = 0xFF'u8",
        "maps.localMap[4] = maps.localMap[4] and 0x1F'u8",
        "maps.masterMap[4] = maps.masterMap[4] and 0x1F'u8",
    ]:
        assert expected in llm_init_body

    assert "addr llmChannelMaps().masterMap[0]" in llm_master_body
    assert "let maps = llmChannelMaps()" in llm_update_body
    assert "nextMap[i] = maps.masterMap[i]" in llm_update_body
    assert "maps.localMap[i] = nextMap[i]" in llm_update_body
    assert "let disconnect = llcDisconnectState(llc_env[conhdl])" in disconnect_body
    assert "if disconnect.active != 0:" in disconnect_body
    assert "disconnect.reason = reason" in disconnect_body
    assert "disconnect.active = 1" in disconnect_body

    for forbidden in [
        "addr env.data[346]",
        "cast[ptr uint16](addr env.data[344])",
        "addr llc_env[conhdl].data[346]",
        "env.data[413]",
        "env.data[414]",
        "llm_env_data.data[344 + i]",
        "llm_env_data.data[349 + i]",
        "llm_env_data.data[348]",
        "llm_env_data.data[353]",
        "addr llm_env_data.data[349]",
    ]:
        assert forbidden not in llc_body
        assert forbidden not in llm_init_body
        assert forbidden not in llm_master_body
        assert forbidden not in llm_update_body
        assert forbidden not in disconnect_body


def test_ble_advertiser_connection_uses_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    note_body = ble.split("proc noteNimAdvertiserConnected", 1)[1].split(
        "proc clearNimConnectionStateForDisconnect", 1
    )[0]

    for expected in [
        "LlmAdvertiserConnView {.packed.} = object",
        "intervalMinSlots*: uint16",
        "intervalMaxSlots*: uint16",
        "intervalLatencyWord*: uint32",
        "supervisionMinSlots*: uint16",
        "supervisionMaxSlots*: uint16",
        "driftSlots*: uint16",
        "peerAddr*: BdAddr",
        "peerAddrType*: uint8",
        "connected*: uint8",
        "state*: uint8",
        "doAssert offsetof(LlmAdvertiserConnView, intervalMinSlots) == 24",
        "doAssert offsetof(LlmAdvertiserConnView, peerAddr) == 40",
        "doAssert offsetof(LlmAdvertiserConnView, state) == 72",
        "template llmAdvertiserConn(): ptr LlmAdvertiserConnView",
    ]:
        assert expected in ble

    for expected in [
        "let conn = llmAdvertiserConn()",
        "conn.peerAddr.data[i] = raw[i]",
        "conn.peerAddrType = uint8((header shr 6) and 0x01'u16)",
        "conn.connected = 1'u8",
        "conn.state = 9'u8",
        "conn.intervalMinSlots = uint16(interval * 4'u32)",
        "conn.intervalMaxSlots = uint16(interval * 4'u32)",
        "conn.intervalLatencyWord = 0x00040004'u32",
        "conn.supervisionMinSlots = uint16((latency + 1'u32) * interval)",
        "conn.supervisionMaxSlots = uint16((latency + 1'u32) * interval)",
        "conn.driftSlots = uint16(driftSlots and 0xFFFF'u32)",
    ]:
        assert expected in note_body

    for forbidden in [
        "llm_env_data.data[40 + i]",
        "llm_env_data.data[46]",
        "llm_env_data.data[47]",
        "llm_env_data.data[72]",
        "putLe16(cast[ptr UncheckedArray[uint8]](addr llm_env_data.data[0])",
        "putLe32(cast[ptr UncheckedArray[uint8]](addr llm_env_data.data[0])",
    ]:
        assert forbidden not in note_body


def test_ble_access_words_use_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    helper_body = ble.split("template btbleAccessWordsAt", 1)[1].split(
        "proc btbleProgramSlotAddr", 1
    )[0]
    init_body = ble.split("proc initBleCoreRegisters", 1)[1].split(
        "proc configureBleNimRadio", 1
    )[0]
    adv_body = ble.split("proc programBtbleLegacyAdv", 1)[1].split(
        "proc resetBtbleAdvRxRing", 1
    )[0]
    scan_body = ble.split("proc programBtbleLegacyScanEm", 1)[1].split(
        "proc programBtbleLegacyInitiatorEm", 1
    )[0]
    initiator_body = ble.split("proc programBtbleLegacyInitiatorEm", 1)[1].split(
        "when defined(BleDebugCounters):", 1
    )[0]

    for expected in [
        "BtbleAccessAddressWordsView* {.packed.} = object",
        "accessAddrLow*: uint16",
        "accessAddrHigh*: uint16",
        "crcInitLow*: uint16",
        "crcInitHigh*: uint16",
        "doAssert sizeof(BtbleAccessAddressWordsView) == 0x08",
        "doAssert offsetof(BtbleAccessAddressWordsView, accessAddrHigh) == 0x02",
        "doAssert offsetof(BtbleAccessAddressWordsView, crcInitLow) == 0x04",
        "doAssert offsetof(BtbleAccessAddressWordsView, crcInitHigh) == 0x06",
        "template btbleAccessWordsAt(emAddr: uint32): ptr BtbleAccessAddressWordsView",
        "proc writeBtbleDefaultAccessWords(emAddr: uint32)",
    ]:
        assert expected in ble

    for expected in [
        "volatileStore(addr words.accessAddrLow, 0xBED6'u16)",
        "volatileStore(addr words.accessAddrHigh, 0x8E89'u16)",
        "volatileStore(addr words.crcInitLow, 0x5555'u16)",
        "volatileStore(addr words.crcInitHigh, 0x0055'u16)",
    ]:
        assert expected in helper_body

    for expected, body in [
        ("writeBtbleDefaultAccessWords(BLE_EM_BASE + 0x0F0'u32)", init_body),
        ("writeBtbleDefaultAccessWords(BLE_EM_BASE + 0x14C'u32)", init_body),
        ("writeBtbleDefaultAccessWords(BTBLE_EM_BASE + 0x12E'u32)", adv_body),
        ("writeBtbleDefaultAccessWords(em + 0x0E'u32)", scan_body),
        ("writeBtbleDefaultAccessWords(em + 0x0E'u32)", initiator_body),
        ("writeBtbleDefaultAccessWords(em + 0x96'u32)", initiator_body),
    ]:
        assert expected in body

    for forbidden in [
        "write16(BLE_EM_BASE + 0x0F0'u32, 0xBED6'u16)",
        "write16(BLE_EM_BASE + 0x0F2'u32, 0x8E89'u16)",
        "write16(BLE_EM_BASE + 0x0F4'u32, 0x5555'u16)",
        "write16(BLE_EM_BASE + 0x14C'u32, 0xBED6'u16)",
        "write16(BLE_EM_BASE + 0x14E'u32, 0x8E89'u16)",
        "write16(BTBLE_EM_BASE + 0x12E'u32, 0xBED6'u16)",
        "write16(BTBLE_EM_BASE + 0x130'u32, 0x8E89'u16)",
        "write16(BTBLE_EM_BASE + 0x132'u32, 0x5555'u16)",
        "write16(BTBLE_EM_BASE + 0x134'u32, 0x0055'u16)",
        "write16(em + 0x0E'u32, 0xBED6'u16)",
        "write16(em + 0x10'u32, 0x8E89'u16)",
        "write16(em + 0x12'u32, 0x5555'u16)",
        "write16(em + 0x14'u32, 0x0055'u16)",
        "write16(em + 0x96'u32, 0xBED6'u16)",
        "write16(em + 0x98'u32, 0x8E89'u16)",
        "write16(em + 0x9A'u32, 0x5555'u16)",
        "write16(em + 0x9C'u32, 0x0055'u16)",
    ]:
        assert forbidden not in init_body
        assert forbidden not in adv_body
        assert forbidden not in scan_body
        assert forbidden not in initiator_body


def test_ble_scheduler_program_slots_use_typed_overlay():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    helper_body = ble.split("proc btbleProgramSlotAddr", 1)[1].split(
        "proc writeBtbleRxDescHeadIndex", 1
    )[0]
    scheduler_body = ble.split("when defined(bl808m0) and\n    bl808BleNimSchProgEnabled:", 1)[1].split(
        "proc nimSchProgInit", 1
    )[0]
    push_body = ble.split("proc sch_prog_push*", 1)[1].split(
        "proc nimSchProgInit", 1
    )[0]
    adv_push_body = ble.split("proc pushBtbleAdvProgram", 1)[1].split(
        "proc scheduleBtbleEvent", 1
    )[0]

    for expected in [
        "BtbleProgramSlotView* {.packed.} = object",
        "control*: uint16",
        "targetLow*: uint16",
        "targetHigh*: uint16",
        "fineBackoff*: uint16",
        "emPtr*: uint16",
        "duration*: uint16",
        "rates*: uint16",
        "tail*: uint16",
        "doAssert sizeof(BtbleProgramSlotView) == 0x10",
        "doAssert offsetof(BtbleProgramSlotView, targetLow) == 0x02",
        "doAssert offsetof(BtbleProgramSlotView, targetHigh) == 0x04",
        "doAssert offsetof(BtbleProgramSlotView, fineBackoff) == 0x06",
        "doAssert offsetof(BtbleProgramSlotView, emPtr) == 0x08",
        "doAssert offsetof(BtbleProgramSlotView, duration) == 0x0A",
        "doAssert offsetof(BtbleProgramSlotView, rates) == 0x0C",
        "doAssert offsetof(BtbleProgramSlotView, tail) == 0x0E",
        "SchProgRequestView* {.packed.} = object",
        "callback*: uint32",
        "targetTime*: uint32",
        "fineTime*: uint16",
        "duration*: uint32",
        "context*: uint32",
        "eventIndex*: uint8",
        "doAssert sizeof(SchProgRequestView) == 36",
        "doAssert offsetof(SchProgRequestView, eventIndex) == 0x1C",
    ]:
        assert expected in ble

    for expected in [
        "template btbleProgramSlotAt(slot: uint32): ptr BtbleProgramSlotView",
        "proc btbleProgramSlotControl(slot: uint32): uint16",
        "proc btbleProgramSlotTarget(slot: uint32): uint32",
        "proc btbleProgramSlotSetDisabled(slot: uint32)",
        "proc btbleProgramSlotClear(slot: uint32; tail: uint16)",
        "proc btbleProgramSlotProgram(slot: uint32; target: uint32; fineBackoff,",
        "proc btbleProgramSlotProgramRaw(slot: uint32; control, targetLow, targetHigh,",
        "volatileLoad(addr view.targetLow).uint32",
        "volatileStore(addr view.tail, tail)",
    ]:
        assert expected in helper_body

    for expected in [
        "btbleProgramSlotClear(slot,",
        "btbleProgramSlotTarget(uint32(slot and 0x0F'u8))",
        "let rawStatus = btbleProgramSlotControl(uint32(slot))",
        "btbleProgramSlotSetDisabled(uint32(slot))",
        "btbleProgramSlotSetDisabled(slot)",
    ]:
        assert expected in ble

    for expected in [
        "let slotU32 = uint32(slot)",
        "let req = cast[ptr SchProgRequestView](prog)",
        "let cbRaw = req.callback",
        "let target = req.targetTime",
        "let fine = req.fineTime",
        "let dur = req.duration",
        "let ctxRaw = req.context",
        "uint32(req.eventIndex) * 0x94'u32",
        "let tail = (btbleProgramSlotTail(slotU32) and 0xE0FF'u16) or",
        "btbleProgramSlotProgram(slotU32, target, fineBackoff, durHalf,",
    ]:
        assert expected in push_body

    for expected in [
        "btbleProgramSlotProgramRaw(slot, 0x281A'u16,",
        "btbleProgramSlotProgramRaw(directSlot, 0x2802'u16,",
        "uint16(clock and 0xFFFF'u32), 0'u16, 0x0270'u16, 0x0048'u16,",
        "0x085A'u16, uint16(slotTail and 0xFFFF'u32),",
        "0x085A'u16, uint16(directSlotTail and 0xFFFF'u32),",
    ]:
        assert expected in adv_push_body

    for forbidden in [
        "let slotAddr = BTBLE_EM_BASE + uint32(slot) * 0x10'u32",
        "let slotAddr = BTBLE_EM_BASE + slot * 0x10'u32",
        "let directSlotAddr = BTBLE_EM_BASE + directSlot * 0x10'u32",
        "read16(slotAddr + 0x02'u32)",
        "read16(slotAddr + 0x04'u32)",
        "read16(slotAddr + 0x0E'u32)",
        "write16(slotAddr + 0x02'u32",
        "write16(slotAddr + 0x04'u32",
        "write16(slotAddr + 0x06'u32",
        "write16(slotAddr + 0x08'u32",
        "write16(slotAddr + 0x0A'u32",
        "write16(slotAddr + 0x0C'u32",
        "write16(slotAddr + 0x0E'u32",
        "write16(directSlotAddr",
        "write16(directSlotAddr + 0x02'u32",
        "write16(directSlotAddr + 0x04'u32",
        "write16(directSlotAddr + 0x06'u32",
        "write16(directSlotAddr + 0x08'u32",
        "write16(directSlotAddr + 0x0A'u32",
        "write16(directSlotAddr + 0x0C'u32",
        "write16(directSlotAddr + 0x0E'u32",
        "schProgGet16(",
        "schProgGet32(",
        "p[24]",
        "p[25]",
        "p[26]",
        "p[27]",
        "p[28]",
        "p[29]",
        "p[30]",
        "p[31]",
        "p[32]",
        "p[33]",
    ]:
        assert forbidden not in scheduler_body
        assert forbidden not in push_body
        assert forbidden not in adv_push_body


def test_ble_arb_callbacks_are_bounded_and_cps_driven():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    arb_body = ble.split("proc serviceNimArbCallbacks()", 1)[1].split(
        "proc nimLldRxDescAddr", 1
    )[0]
    pending_body = ble.split("proc bleControllerHasPendingWork", 1)[1].split(
        "proc bleControllerServiceStep", 1
    )[0]
    service_body = ble.split("proc bleDrainScheduledWork(): bool =", 1)[1].split(
        "proc bleControllerServiceStep", 1
    )[0]

    assert "BleArbCallbackDrainLimit = 4'u32" in ble
    assert "nim_ble_arb_callback_yield_count" in ble
    assert "proc nimArbCallbackPending(): bool {.inline.}" in ble
    assert "var drained = 0'u32" in arb_body
    assert "while drained < BleArbCallbackDrainLimit and nimArbCallbackPending():" in arb_body
    assert "while nim_conn_arb_pending_cb != nil:" not in arb_body
    assert "inc drained" in arb_body
    assert "if nimArbCallbackPending():" in arb_body
    assert "inc nim_ble_arb_callback_yield_count" in arb_body
    assert "result = result or nimArbCallbackPending()" in pending_body
    assert "serviceNimArbCallbacks()" in service_body


def test_ble_task_scheduler_uses_shared_queue_event_helpers():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    schedule_body = ble.split("proc patch_ble_ke_task_schedule*", 1)[1].split(
        "proc ble_ke_task_schedule*", 1
    )[0]
    clear_body = ble.split("proc bleKeTaskClearEventIfQueueEmpty()", 1)[1].split(
        "proc bleKeTaskRescheduleIfQueued()", 1
    )[0]

    assert "proc bleKeTaskClearEventIfQueueEmpty()" in ble
    assert "proc bleKeTaskRescheduleIfQueued()" in ble
    assert "BleKeMessageEventId = 2'u8" in ble
    assert "BleKeMessageEventBit = 1'u32 shl 2" in ble
    assert "bleKeTaskClearEventIfQueueEmpty()" in schedule_body
    assert schedule_body.count("bleKeTaskRescheduleIfQueued()") == 3
    assert "ke_event_field = ke_event_field and not (1'u32 shl 2)" not in schedule_body
    assert "ke_event_field = ke_event_field and not BleKeMessageEventBit" in clear_body
    assert "if ke_msg_queue.first != nil:\n        ble_ke_event_set(2)" not in schedule_body
    assert "ble_ke_event_set(BleKeMessageEventId)" in ble
    assert "KeMsgConsumed* = 1'i32" in ble
    assert "KeMsgSaved* = 2'i32" in ble
    assert "return KeMsgConsumed" in ble
    assert "return KeMsgSaved" in ble
    assert "of KeMsgConsumed:" in schedule_body
    assert "of KeMsgSaved:" in schedule_body
    assert "of 1:  # KE_MSG_CONSUMED" not in schedule_body
    assert "of 2:  # KE_MSG_SAVED" not in schedule_body


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

    btble_rf_table = ble.split("BtbleRfTableView {.packed.} = object", 1)[1].split(
        "BleMacPhyRegs {.packed.} = object", 1
    )[0]
    btble_rf_init = ble.split("proc btble_rf_init*(rf: pointer) {.exportc, cdecl.} =", 1)[1].split(
        "when defined(bl808m0) and bl808BleNimConnectionEnabled:", 1
    )[0]
    txcal_body = ble.split("proc tuneBleRfTxcalSingenPower", 1)[1].split(
        "proc writeBleRfTxcalMixerCs", 1
    )[0]
    schedule_body = ble.split("proc nimConnSchedule() =", 1)[1].split(
        "nimConnProgramRxTiming", 1
    )[0]

    for expected in [
        "unusedCallback08*: pointer",
        "unusedCallback0c*: pointer",
        "unusedCallback18*: pointer",
        "unusedCallback28*: pointer",
        "emConfigPadding3a*: array[3, uint8]",
        "doAssert offsetof(BtbleRfTableView, unusedCallback08) == 0x08",
        "doAssert offsetof(BtbleRfTableView, unusedCallback0c) == 0x0C",
        "doAssert offsetof(BtbleRfTableView, unusedCallback18) == 0x18",
        "doAssert offsetof(BtbleRfTableView, unusedCallback28) == 0x28",
        "doAssert offsetof(BtbleRfTableView, emConfigPadding3a) == 0x3A",
    ]:
        assert expected in ble
    for expected in [
        "table.unusedCallback08 = nil",
        "table.unusedCallback0c = nil",
        "table.unusedCallback18 = nil",
        "table.unusedCallback28 = nil",
        "table.emConfigPadding3a = [0'u8, 0, 0]",
    ]:
        assert expected in btble_rf_init
    for forbidden in [
        "reserved08*",
        "reserved0C*",
        "reserved18*",
        "reserved28*",
        "reserved3A*",
    ]:
        assert forbidden not in btble_rf_table
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
    assert "proc coDjobPending(index: int): bool" in ble
    assert "proc coDjobAnyPending(): bool" in ble
    assert "for queue in co_djob_queues:" in ble
    assert "var drained = 0'u32" in djob_body
    assert "while drained < CoDjobDrainLimit:" in djob_body
    assert "while true:" not in djob_body
    assert "inc drained" in djob_body
    assert "if coDjobPending(index):" in djob_body
    assert "inc nim_ble_codjob_yield_count" in djob_body
    assert "nim_ble_codjob_yield_event = eventId.uint32" in djob_body
    assert "ble_ke_event_set(coDjobEventId(index))" in djob_body


def test_ble_sleep_check_uses_controller_pending_work_state():
    ble = (ROOT / "src/bl808/blecontroller.nim").read_text()

    sleep_body = ble.split(
        "proc patch_ble_ke_sleep_check*(): bool {.exportc: \"_patch_ble_ke_sleep_check\", cdecl.} =",
        1,
    )[1].split(
        "proc ble_ke_sleep_check*", 1
    )[0]

    assert "proc bleControllerHasPendingWork(): bool" in ble
    assert "return not bleControllerHasPendingWork()" in sleep_body
    assert "ke_event_field == 0 and ke_msg_queue.first == nil" not in sleep_body


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


def test_wifi_rf_bringup_dependency_is_explicit_and_objdump_recoverable():
    wifi = (ROOT / "src/bl808/wifi.nim").read_text()
    wifi_support = (ROOT / "src/bl808/wifi_support.nim").read_text()
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    bl808_rf = ROOT / "src/bl808/librf_bl808.a"
    bl606p_rf = (
        ROOT
        / "build/bl_iot_sdk_b773b3f/components/platform/soc/bl606p"
        / "bl606p_phyrf/lib/libbl606p_phyrf.a"
    )

    assert "proc rf_init*(xtalfreqHz: uint32)" in wifi
    assert "when defined(bl808WifiUseBl808Rf):" in wifi
    assert "-Wl,--wrap=phy_assert_err" in wifi
    assert "libbl606p_phyrf.a" in wifi
    assert "src/bl808/librf_bl808.a" not in wifi

    fw_start = wifi_support.split("proc bl808WifiBackendFwStart()", 1)[1].split(
        "proc wifiMainServiceBlockingIdle", 1
    )[0]
    assert fw_start.index("wifi_hosal_rf_turn_on begin") < fw_start.index(
        "wifi_rf_core_init begin"
    )
    assert fw_start.index("wifiRfCoreInit(40_000_000)") < fw_start.index(
        "high_power_profile begin"
    )
    assert "when defined(bl808WifiUseBl808Rf):" in fw_start
    assert "else:\n      bl808WifiBackendTrace(\"rf_init begin\")" in fw_start

    wifi_main = wifi_fw.split("proc wifi_main*", 1)[1].split(
        "proc wifi_main_init", 1
    )[0]
    assert wifi_main.index("wifi_hosal_rf_turn_on()") < wifi_main.index(
        "wifiRfCoreInit(40000000'u32)"
    )
    assert "WlRfConfig {.packed.} = object" in wifi_fw
    assert "doAssert offsetof(WlRfConfig, paramLoadCallback) == 200" in wifi_fw
    wl_rf_config = wifi_fw.split("WlRfConfig {.packed.} = object", 1)[1].split(
        "WlRfMemoryOverlay {.packed.} = object", 1
    )[0]
    for expected in (
        "enableParamLoadCallback: uint8",
        "requestFullCalibration: uint8",
        "enableCapcodeSetCallback: uint8",
        "paramLoadCallback: pointer",
        "capcodeSetCallback: pointer",
        "capcodeGetCallback: pointer",
        "channelFreqSeedPair0: uint32",
        "channelFreqSeedPair1: uint32",
        "channelFreqSeedPair2: uint32",
        "channelFreqSeedPadding: array[5, uint32]",
        "ratePowerTablePreamble: uint16",
        "ratePowerTable: array[106, uint8]",
        "ratePowerLimitDbm: uint8",
        "ratePowerTablePostamble: array[4, uint8]",
        "temperaturePowerCompPadding: uint16",
        "efuseTrimControl: uint32",
        "xtalCountWindowMin: uint32",
        "xtalCountWindowMax: uint32",
        "xtalDividerConfig: uint32",
        "xtalControlCode: uint32",
        "ceLoopScratch0: uint32",
        "pdLoopReserved12: uint8",
    ):
        assert expected in wifi_fw
    for forbidden in (
        "channelFreqPair0",
        "channelFreqPair1",
        "channelFreqPair2",
        "channelFreqPairPadding",
        "channelPowerTablePadding",
        "powerTableLimit",
        "powerTablePostamble",
        "enParamLoad",
        "enFullCal",
        "enCapcodeSet",
        "paramLoad:",
        "capcodeSet:",
        "capcodeGet:",
    ):
        assert forbidden not in wl_rf_config
    for vague_name in (
        "priByte9C",
        "priWordC0",
        "word04: uint32",
        "word08: uint32",
        "word0c: uint32",
        "word10: uint32",
        "rfReg1c8Value: uint32",
        "rfReg1ccValue: uint32",
        "rfReg1c4Value: uint32",
        "rfReg1c0Value: uint32",
        "loopWord0",
        "pdReserved12",
        "agcCtrl88",
        "agcCtrl8c",
        "dfeCtrl3bc",
        "dfeCtrl414",
        "phyCtrlC40",
        "phyCtrlC44",
    ):
        assert vague_name not in wifi_fw
    assert "WlRfMemoryOverlay {.packed.} = object" in wifi_fw
    assert "doAssert offsetof(WlRfMemoryOverlay, calib) == 212" in wifi_fw
    assert "doAssert offsetof(WlRfMemoryOverlay, env) == 532" in wifi_fw
    for expected in [
        "PhyEnvView {.packed.} = object",
        "initCfgWords: array[9, uint32]",
        "channelBandType: uint16",
        "primaryFreq: uint16",
        "centerFreq1: uint16",
        "centerFreq2OrTxPower: uint16",
        "txPowerAndReserved: uint16",
        "BbaRxVectorView {.packed.} = object",
        "rxFormatWord0: uint32",
        "rxFormatWord1Rate: uint8",
        "rssiDbm: uint8",
        "rxFormatWord1Mcs: uint8",
        "rxFormatWord1Flags: uint8",
        "carrierFreqOffset: uint16",
        "doAssert sizeof(PhyEnvView) == 48",
        "doAssert offsetof(PhyEnvView, initCfgWords) == 0",
        "doAssert offsetof(PhyEnvView, channelBandType) == 36",
        "doAssert offsetof(PhyEnvView, primaryFreq) == 38",
        "doAssert offsetof(PhyEnvView, centerFreq1) == 40",
        "doAssert offsetof(PhyEnvView, centerFreq2OrTxPower) == 42",
        "doAssert offsetof(PhyEnvView, txPowerAndReserved) == 44",
        "doAssert sizeof(BbaRxVectorView) == 24",
        "doAssert offsetof(BbaRxVectorView, rxFormatWord0) == 0",
        "doAssert offsetof(BbaRxVectorView, rxFormatWord1Rate) == 4",
        "doAssert offsetof(BbaRxVectorView, rssiDbm) == 5",
        "doAssert offsetof(BbaRxVectorView, carrierFreqOffset) == 0x16",
        "doAssert offsetof(WifiModemBlock, versionWord) == 0x0",
        "doAssert offsetof(WifiModemBlock, versionDfeCaps1c) == 0x1C",
        "doAssert offsetof(WifiModemBlock, versionDfeCaps24) == 0x24",
        "doAssert offsetof(WifiModemBlock, versionDfeCaps28) == 0x28",
        "doAssert offsetof(WifiModemBlock, versionScratch3c) == 0x3C",
        "doAssert offsetof(WifiModemBlock, preAgcCtrl324) == 0x324",
        "doAssert offsetof(WifiModemBlock, basebandDfeTimeout3bc) == 0x3BC",
        "doAssert offsetof(WifiModemBlock, basebandDfeEnable414) == 0x414",
        "doAssert offsetof(WifiModemBlock, versionFeatureCtrl800) == 0x800",
        "doAssert offsetof(WifiModemBlock, bandwidth20MGuard814) == 0x814",
        "doAssert offsetof(WifiModemBlock, bandwidth20MProfile820) == 0x820",
        "doAssert offsetof(WifiModemBlock, channelTypeCtrl824) == 0x824",
        "doAssert offsetof(WifiModemBlock, bandwidth20MProfile830) == 0x830",
        "doAssert offsetof(WifiModemBlock, bandwidth20MEnable834) == 0x834",
        "doAssert offsetof(WifiModemBlock, bandwidth20MSignal83c) == 0x83C",
        "doAssert offsetof(WifiModemBlock, bandwidth20MSignal840) == 0x840",
        "doAssert offsetof(WifiModemBlock, preAgcSignal844) == 0x844",
        "doAssert offsetof(WifiModemBlock, preAgcSignal848) == 0x848",
        "doAssert offsetof(WifiModemBlock, channelCenterRatio84c) == 0x84C",
        "doAssert offsetof(WifiModemBlock, bandwidth20MFilter860) == 0x860",
        "doAssert offsetof(WifiModemBlock, bandwidth20MGate874) == 0x874",
        "doAssert offsetof(WifiModemBlock, phyChannelPulse888) == 0x888",
        "doAssert offsetof(WifiModemBlock, preAgcDetect894) == 0x894",
        "doAssert offsetof(WifiModemBlock, groupMembership0) == 0x8A8",
        "doAssert offsetof(WifiModemBlock, groupMembership1) == 0x8AC",
        "doAssert offsetof(WifiModemBlock, userPosition) == 0x8B0",
        "doAssert offsetof(WifiModemBlock, aid) == 0x8C0",
        "doAssert offsetof(WifiModemBlock, aidMaskLo) == 0x8C4",
        "doAssert offsetof(WifiModemBlock, aidMaskHi) == 0x8C8",
        "doAssert offsetof(WifiModemBlock, preAgcTiming8d4) == 0x8D4",
        "doAssert offsetof(WifiModemBlock, preAgcTiming8d8) == 0x8D8",
        "doAssert offsetof(WifiModemBlock, preAgcTiming8e0) == 0x8E0",
        "doAssert offsetof(WifiModemBlock, preAgcTiming8e4) == 0x8E4",
        "doAssert offsetof(WifiModemBlock, channelModeCtrl930) == 0x930",
        "doAssert offsetof(WifiModemBlock, basebandRxPathCtrlC40) == 0xC40",
        "doAssert offsetof(WifiModemBlock, basebandRxPathCtrlC44) == 0xC44",
        "doAssert offsetof(WifiModemBlock, intStatusB41c) == 0xB41C",
        "doAssert offsetof(WifiModemBlock, intAckB420) == 0xB420",
        "doAssert offsetof(WifiModemBlock, rxGainTailCtrlC018) == 0xC018",
        "doAssert offsetof(WifiModemBlock, rxGainTimingC044) == 0xC044",
        "doAssert offsetof(WifiModemBlock, rxGainTable0C080) == 0xC080",
        "doAssert offsetof(WifiModemBlock, rxGainTable1C084) == 0xC084",
        "doAssert offsetof(WifiModemBlock, rxGainTable2C088) == 0xC088",
        "doAssert offsetof(RfRegBlock, txcalBias58) == 0x58",
        "doAssert offsetof(RfRegBlock, txcalGain64) == 0x64",
        "doAssert offsetof(RfRegBlock, txcalGain68) == 0x68",
        "doAssert offsetof(RfRegBlock, txcalDc6c) == 0x6C",
        "doAssert offsetof(PhyAgcBlock, sharedCopyWindow88) == 0x88",
        "doAssert offsetof(PhyAgcBlock, sharedCopyWindow8c) == 0x8C",
        "doAssert offsetof(MacPhyCtrlBlock, channelBandwidthCtrl310) == 0x310",
        "doAssert offsetof(CrmPhyClockBlock, phyClockSelect8) == 0x08",
        "doAssert offsetof(CrmPhyClockBlock, rfClockMux10) == 0x10",
        "doAssert offsetof(CrmPhyClockBlock, modemReset18) == 0x18",
        "doAssert offsetof(RfPllBlock, pllReset10) == 0x10",
        "doAssert offsetof(RfPllBlock, refdivCtrl14) == 0x14",
        "doAssert offsetof(RfPllBlock, loopFilter18) == 0x18",
        "doAssert offsetof(RfPllBlock, fractionalCtrl1c) == 0x1C",
        "doAssert offsetof(RfPllBlock, fractionalWord28) == 0x28",
        "doAssert offsetof(RfPllBlock, modeCtrl2c) == 0x2C",
        "doAssert offsetof(RfPllBlock, enableCtrl30) == 0x30",
        "doAssert offsetof(RfDfeInitBlock, dfeRfFixedCtrl814) == 0x814",
        "doAssert offsetof(RfDfeInitBlock, dfeTrim824) == 0x824",
        "doAssert offsetof(RfRegBlock, synthDfePathControl63c) == 0x63C",
        "doAssert offsetof(BbaAgcBlock, agcCoreEnable004) == 0x004",
        "doAssert offsetof(BbaAgcBlock, agcCoreCtrl100) == 0x100",
        "doAssert offsetof(BbaAgcBlock, agcCoreProfile364) == 0x364",
        "doAssert offsetof(BbaAgcBlock, pdComp36c) == 0x36C",
        "doAssert offsetof(BbaAgcBlock, agcCoreProfile370) == 0x370",
        "doAssert offsetof(BbaAgcBlock, agcCoreStage0B380) == 0x380",
        "doAssert offsetof(BbaAgcBlock, macActiveB384) == 0x384",
        "doAssert offsetof(BbaAgcBlock, agcCoreStage2B388) == 0x388",
        "doAssert offsetof(BbaAgcBlock, macActiveB38c) == 0x38C",
        "doAssert offsetof(BbaAgcBlock, pdGain390) == 0x390",
        "doAssert offsetof(BbaAgcBlock, agcCoreDetect394) == 0x394",
        "doAssert offsetof(BbaAgcBlock, agcCoreDetect398) == 0x398",
        "doAssert offsetof(BbaAgcBlock, macActiveB3a0) == 0x3A0",
        "doAssert offsetof(BbaAgcBlock, agcCoreWindow3a4) == 0x3A4",
        "doAssert offsetof(BbaAgcBlock, pdTiming3ac) == 0x3AC",
        "doAssert offsetof(BbaAgcBlock, macActiveB3bc) == 0x3BC",
        "doAssert offsetof(BbaAgcBlock, pdSlope3c0) == 0x3C0",
        "doAssert offsetof(BbaAgcBlock, macActiveB3c4) == 0x3C4",
        "doAssert offsetof(BbaAgcBlock, agcCoreTimeout414) == 0x414",
        "doAssert offsetof(BbaAgcBlock, macActiveC01c) == 0x101C",
        "doAssert offsetof(BbaAgcBlock, macActiveC020) == 0x1020",
        "doAssert offsetof(BbaAgcBlock, macActiveC02c) == 0x102C",
        "doAssert offsetof(BbaAgcBlock, agcCoreTableC80c) == 0x180C",
        "doAssert offsetof(BbaAgcBlock, pdCompC830) == 0x1830",
        "doAssert offsetof(BbaAgcBlock, pdCompRampC838) == 0x1838",
        "doAssert offsetof(BbaAgcBlock, pdCompRampC83c) == 0x183C",
        "doAssert offsetof(BbaAgcBlock, pdCompRampC840) == 0x1840",
    ]:
        assert expected in wifi_fw
    for expected in [
        "RfAuxCtrlBase = 0x20000500'u",
        "BbaAgcBase = 0x24C0B000'u",
        "cast[ptr RfAuxCtrlBlock](RfAuxCtrlBase)",
        "cast[ptr BbaAgcBlock](BbaAgcBase)",
    ]:
        assert expected in wifi_fw
    for forbidden in [
        "cast[ptr RfAuxCtrlBlock](0x20000500'u)",
        "cast[ptr BbaAgcBlock](0x24C0B000'u)",
    ]:
        assert forbidden not in wifi_fw
    assert 'var wlCfgGlobal* {.exportc: "wl_cfg".}: pointer' in wifi_fw
    assert "proc wl_rf_cfg_init*() {.exportc, cdecl.} =" in wifi_fw
    assert "proc wl_cfg_get(rmem: ptr WlRfMemoryOverlay): ptr WlRfConfig {.exportc, cdecl.} =" in wifi_fw
    assert "proc wl_cfg_get(rmem: ptr uint8): ptr WlRfConfig {.importc, cdecl.}" not in wifi_fw
    assert "proc modem_init_core*(xtalfreqHz, restore: uint32)" in wifi_fw
    assert "proc wifiRfCoreInit*(xtalfreqHz: uint32) {.exportc, cdecl, noinline.}" in wifi_fw
    for expected in [
        "RadioPhyMode* = enum",
        "wifiOnly = 1'u8",
        "bleOnly = 2'u8",
        "wifiBleCoex = 3'u8",
        "proc radioPhyModeFromApi(apiMode: uint8): RadioPhyMode {.inline.} =",
        "proc apiFromRadioPhyMode(mode: RadioPhyMode): uint8 {.inline.} =",
    ]:
        assert expected in wifi_fw
    assert "proc wlModeFromApi" not in wifi_fw
    assert "proc wifiRfCoreInitMode(xtalfreqHz: uint32, mode: RadioPhyMode) {.noinline.}" in wifi_fw
    rf_core_init = wifi_fw.split(
        "proc wifiRfCoreInitMode(xtalfreqHz: uint32, mode: RadioPhyMode) {.noinline.} =",
        1,
    )[1].split("proc wifiRfCoreInit*(xtalfreqHz: uint32) {.exportc, cdecl, noinline.} =", 1)[0]
    wifi_rf_core_export = wifi_fw.split(
        "proc wifiRfCoreInit*(xtalfreqHz: uint32) {.exportc, cdecl, noinline.} =",
        1,
    )[1].split("when defined(bl808WifiUseBl808Rf):", 1)[0]
    rfc_init_body = wifi_fw.split(
        "proc rfc_init*(xtalfreqHz: uint32, fullInit: uint32 = 1'u32) {.exportc, cdecl.} =",
        1,
    )[1].split("template rf_calib_data", 1)[0]
    vco_table_body = wifi_fw.split(
        "proc programRfcVcoTable() =",
        1,
    )[1].split("proc rf_dump_status*", 1)[0]
    rfc_bandwidth_body = wifi_fw.split(
        "proc rfc_config_bandwidth*(bandwidth: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfc_config_channel*", 1)[0]
    rfc_channel_body = wifi_fw.split(
        "proc rfc_config_channel*(channelMhz: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc modemInitCoreMode", 1)[0]
    rfc_modem_late_body = wifi_fw.split(
        "proc programRfcModemLateInit() =",
        1,
    )[1].split("proc modemInitCoreMode", 1)[0]
    rf_restore_body = wifi_fw.split(
        "proc rfPriRestoreCalReg() =",
        1,
    )[1].split("proc rfPriWriteTotalPowerComp", 1)[0]
    restore_cal_state_body = wifi_fw.split(
        "proc restoreRfPriCalState(state: RfPriCalState) =",
        1,
    )[1].split("proc rfPriConfigChannelForCal", 1)[0]
    save_cal_state_body = wifi_fw.split(
        "proc saveRfPriCalState(): RfPriCalState =",
        1,
    )[1].split("proc restoreRfPriCalState", 1)[0]
    total_power_comp_body = wifi_fw.split(
        "proc rfPriWriteTotalPowerComp(channelIndex: uint32) =",
        1,
    )[1].split("proc rf_pri_input_xtalfreq", 1)[0]
    xtal_input_body = wifi_fw.split(
        "proc rf_pri_input_xtalfreq(xtalfreqHz: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfPriXtalRefdivRatio", 1)[0]
    xtal_refdiv_body = wifi_fw.split(
        "proc rfPriXtalRefdivRatio(): uint32 {.inline.} =",
        1,
    )[1].split("proc rfPriXtalTenthsMhz", 1)[0]
    xtal_tenths_body = wifi_fw.split(
        "proc rfPriXtalTenthsMhz(): uint32 {.inline.} =",
        1,
    )[1].split("proc rfPriWifiPllConfig", 1)[0]
    efuse_init_body = wifi_fw.split(
        "proc rfPriEfuseInit() =",
        1,
    )[1].split("proc runRfPriFullCalRestoreBaseline", 1)[0]
    efuse_xtal_cap_body = wifi_fw.split(
        "proc rfPriApplyEfuseXtalCapTrim(cfg: ptr WlRfConfig;",
        1,
    )[1].split("proc rfPriApplyEfuseTxGainTrim", 1)[0]
    efuse_tx_gain_body = wifi_fw.split(
        "proc rfPriApplyEfuseTxGainTrim(cfg: ptr WlRfConfig) =",
        1,
    )[1].split("proc rfPriApplyEfuseDfeTrim", 1)[0]
    efuse_dfe_trim_body = wifi_fw.split(
        "proc rfPriApplyEfuseDfeTrim(cfg: ptr WlRfConfig) =",
        1,
    )[1].split("proc rfPriEfuseInit", 1)[0]
    notch_param_body = wifi_fw.split(
        "proc rfPriApplyNotchParam(channelMhz: uint32) =",
        1,
    )[1].split("proc rfPriApplyWb03Non40OptimizePll", 1)[0]
    wifi_pll_config_body = wifi_fw.split(
        "proc rfPriWifiPllConfig() =",
        1,
    )[1].split("proc rfPriEfuseInit", 1)[0]
    rf_optimize_body = wifi_fw.split(
        "proc rf_pri_optimize(channelMhz: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfc_config_channel*", 1)[0]
    rf_stage_snapshot_body = wifi_fw.split(
        "proc rfPriSnapshotStage(tag: uint32) =",
        1,
    )[1].split("proc writeRfPriFixedValueRegs", 1)[0]
    bz_txcal_snapshot_body = wifi_fw.split(
        "proc rfPriSnapshotBzTxcalState(tag: uint32) =",
        1,
    )[1].split("proc sampleRfTxcalAverage", 1)[0]
    rxcal_replay_body = wifi_fw.split(
        "proc rfPriReplayRxcalRegs() =",
        1,
    )[1].split("proc rfPriSeedRxcalRestoreLowHalves", 1)[0]
    phy_init_body = wifi_fw.split(
        "proc phy_init*(cfg: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split("var wlCalGlobal*", 1)[0]
    agc_core_body = wifi_fw.split(
        "proc bl808PhyProgramAgcCoreRegs() =",
        1,
    )[1].split("var phyRxGainOffsetVsTemperature", 1)[0]
    pre_agc_body = wifi_fw.split(
        "proc bl808PhyProgramPreAgcRegs() =",
        1,
    )[1].split("proc bl808PhyProgramAgcCopyTailRegs", 1)[0]
    agc_copy_tail_body = wifi_fw.split(
        "proc bl808PhyProgramAgcCopyTailRegs() =",
        1,
    )[1].split("proc bl808PhyProgramAgcCoreRegs", 1)[0]
    wl_init_body = wifi_fw.split(
        "proc wl_init*(): int8 {.exportc, cdecl.} =",
        1,
    )[1].split("proc channelPowerIndex", 1)[0]
    wl_cfg_init_body = wifi_fw.split(
        "proc wl_rf_cfg_init*() {.exportc, cdecl.} =",
        1,
    )[1].split("proc wl_cfg_get", 1)[0]
    modem_init_mode_body = wifi_fw.split(
        "proc modemInitCoreMode(xtalfreqHz, restoreExistingCalibration: uint32;",
        1,
    )[1].split("proc modem_init_core*", 1)[0]
    assert "proc configureWlRfConfig(cfg: ptr WlRfConfig; xtalfreqHz: uint32;" in wifi_fw
    assert "mode: RadioPhyMode; requestFullCalibration: uint8" in wifi_fw
    assert "cfg.paramLoadCallback = nil" in wifi_fw
    for expected in [
        "cfg.channelFreqSeedPair0 = 0x096C0100'u32",
        "cfg.channelFreqSeedPair1 = 0x098A097B'u32",
        "cfg.channelFreqSeedPair2 = 0x09A80999'u32",
        "cfg.channelFreqSeedPadding.mitems",
        "cfg.ratePowerTablePreamble = 0'u16",
        "cfg.ratePowerLimitDbm = 20'u8",
    ]:
        assert expected in wl_cfg_init_body
    assert "var wifiBl808RfInited: uint32" in wifi_fw
    assert "bl808WifiRfColdInit" not in wifi_fw
    assert (
        "let requestFullCalibration =\n"
        "        if wifiBl808RfInited == 0'u32: 1'u8 else: 0'u8"
    ) in rf_core_init
    assert (
        "let restoreExistingCalibration =\n"
        "      if wifiBl808RfInited == 0'u32: 0'u32 else: 1'u32"
    ) in rf_core_init
    assert "let restoreExistingCalibration = 1'u32" not in wifi_fw
    assert "let requestFullCalibration = 0'u8" not in wifi_fw
    assert "let restore = if wifiBl808RfInited" not in wifi_fw
    assert "let restore = 1'u32" not in wifi_fw
    assert "discard wl_init()" in wifi_fw
    assert "wifiBl808RfInited = 1'u32" in wifi_fw
    assert "when defined(bl808WifiUseBl808Rf):" in wifi_fw
    assert "proc phy_set_channel*(channel: ptr ChanCtxtDefView, force: uint32)" in wifi_fw
    assert "proc phy_set_channel_scalar*(band, chanType, primFreq, centerFreq1: uint32)" in wifi_fw
    assert '{.importc: "phy_set_channel", cdecl.}' in wifi_fw
    assert "proc phySetChannel*(channel: ptr ChanCtxtDefView) {.inline.} =" in wifi_fw
    assert "phy_set_channel(channel, 0'u32)" in wifi_fw
    assert "phy_set_channel_scalar(" in wifi_fw
    assert "channel.primFreq.uint32" in wifi_fw
    assert "channel.centerFreq1.uint32" in wifi_fw
    assert "var channel = ChanCtxtDefView(" in wifi_fw
    assert "phySetChannel(addr ctxt.channel)" in wifi_fw
    assert "proc phy_set_channel*(band: uint8, chanType: uint8" not in wifi_fw
    assert "extern void phy_init" not in wifi_fw
    assert "phy_init(0)" not in wifi_fw
    assert "template phyEnvByte(" not in wifi_fw
    assert "template phyEnvHalf(" not in wifi_fw
    assert "template phyEnvWord(" not in wifi_fw
    assert "template phyEnvViewPtr(): ptr PhyEnvView" in wifi_fw
    assert rf_core_init.index("wl_cfg_get(addr wifiBl808WlRmem)") < rf_core_init.index(
        "discard wl_init()"
    )
    assert "let cfg = wl_cfg_get(addr wifiBl808WlRmem)" in rfc_init_body
    assert "let wlFullCalibrationFlag =" in rfc_init_body
    assert "if fullInit != 0'u32: 1'u8 else: 0'u8" in rfc_init_body
    assert "configureWlRfConfig(" in rfc_init_body
    assert "wifiOnly" in rfc_init_body
    assert "wlFullCalibrationFlag)" in rfc_init_body
    assert "configureWlRfConfig(cfg, xtalfreqHz, mode, requestFullCalibration)" in rf_core_init
    assert "let apiMode = apiFromRadioPhyMode(mode)" in rf_core_init
    assert "nimFwDbgRfApiMode = apiMode.uint32" in rf_core_init
    assert "nimFwDbgRfRestore = restoreExistingCalibration" in rf_core_init
    assert '"[WIFI-CT] bl808_rf_modem ", xtalfreqHz, restoreExistingCalibration' in rf_core_init
    assert '"[WIFI-CT] bl808_rf_done ", xtalfreqHz, restoreExistingCalibration' in rf_core_init
    assert "wifiRfCoreInitMode(xtalfreqHz, wifiOnly)" in wifi_rf_core_export
    assert "let restoreExistingCalibration =" in wl_init_body
    assert "if cfg.requestFullCalibration != 0'u8: 0'u32 else: 1'u32" in wl_init_body
    assert (
        "modemInitCoreMode(\n      cfg.xtalfreqHz,\n      restoreExistingCalibration,"
    ) in wl_init_body
    assert "let apiMode = apiFromRadioPhyMode(mode)" in modem_init_mode_body
    assert "let xtalCfg = RfcXtalConfigTable[xtalIndex(xtalfreqHz)]" in modem_init_mode_body
    assert (
        "updateReg32(addr rf.rxMode220, 0xFBFFFFFF'u32, 0'u32)"
        in modem_init_mode_body
    )
    assert (
        "updateReg32(addr rf.rxMode220, 0xF7FFFFFF'u32, 0x08000000'u32)"
        in modem_init_mode_body
    )
    assert modem_init_mode_body.index(
        "updateReg32(addr rf.rxMode220, 0xFBFFFFFF'u32, 0'u32)"
    ) < modem_init_mode_body.index("rf_pri_input_xtalfreq(xtalfreqHz)")
    assert modem_init_mode_body.index(
        "updateReg32(addr rf.rxMode220, 0xF7FFFFFF'u32, 0x08000000'u32)"
    ) < modem_init_mode_body.index("rf_pri_input_xtalfreq(xtalfreqHz)")
    assert "restoreExistingCalibration == 0'u32" in modem_init_mode_body
    assert "proc modemInitCoreMode(xtalfreqHz, restore: uint32" not in wifi_fw
    assert "nimFwDbgRfApiMode = apiMode.uint32" in modem_init_mode_body
    assert "modemInitCoreMode(xtalfreqHz, restore, wifiOnly)" in wifi_fw
    assert "rf_pri_init(if restore == 0'u32: 1'u32 else: 0'u32, 1'u32)" not in modem_init_mode_body
    assert "if fullInit != 0'u32: 1'u8 else: 0'u8)" not in rfc_init_body
    assert rfc_init_body.index("discard wl_init()") < rfc_init_body.index("phy_init(nil)")
    assert "rf_init(xtalfreqHz)" not in rfc_init_body
    assert "modem_init_core(" not in rfc_init_body
    assert "RfPriCalState = object" in wifi_fw
    assert "RfPriCalSavedRegAddrs:" not in wifi_fw
    assert "RfPriCalSavedRegs:" not in wifi_fw
    assert "RfPriGainInit:" not in wifi_fw
    assert "writeRadioRegMaskInit(RfPriGainInit)" not in wifi_fw
    assert "proc rfRegRead(" not in wifi_fw
    assert "proc rfRegWrite(" not in wifi_fw
    assert "proc rfRegUpdate(" not in wifi_fw
    assert "proc readReg32(" not in wifi_fw
    assert "RfCtrlReg = 0x20001004'u32" not in wifi_fw
    assert not re.search(r"^\s*Rf[A-Za-z0-9]+Reg[A-Za-z0-9_]*\s*=\s*0x2000", wifi_fw, re.M)
    assert "RadioRegMaskInit = object" not in wifi_fw
    assert "proc writeRadioRegMaskInit(" not in wifi_fw
    assert "proc writeRadioMemoryWords(" not in wifi_fw
    assert "writeRadioMemoryWords(0x20001700'u32, words)" not in wifi_fw
    for expected in [
        "doAssert offsetof(RfRegBlock, calMixerStateF0) == 0xF0",
        "doAssert offsetof(RfRegBlock, calDfeState240) == 0x240",
        "doAssert offsetof(RfRegBlock, calDfeState244) == 0x244",
        "doAssert offsetof(RfDfeInitBlock, hbnCtrl30) == 0x30",
        "doAssert offsetof(RfTxPowerCompTableBlock, txPowerCompWords700) == 0x700",
        "RfTxPowerCompTableBlock {.packed.} = object",
        "txPowerCompWords700: array[43, uint32]",
        "template rfTxPowerCompTableRegs(): ptr RfTxPowerCompTableBlock",
        "proc writeRfTxPowerCompTable(words: openArray[uint32]) =",
        "volatileStore(addr table.txPowerCompWords700[i], word)",
        "writeRfTxPowerCompTable(txPowerTableWords)",
        "hbnCtrl30: uint32",
        "calDfeState240: uint32",
        "calDfeState244: uint32",
        "calMixerStateF0: uint32",
    ]:
        assert expected in wifi_fw
    for expected in [
        "let rf = rfRegs()",
        "let dfe = rfDfeInitRegs()",
        "result.synthCtrl2c = volatileLoad(addr rf.synthCtrl2c)",
        "result.hbnCtrl30 = volatileLoad(addr dfe.hbnCtrl30)",
        "result.calDfeState240 = volatileLoad(addr rf.calDfeState240)",
        "result.calDfeState244 = volatileLoad(addr rf.calDfeState244)",
        "result.calMixerStateF0 = volatileLoad(addr rf.calMixerStateF0)",
        "nimFwDbgRfCalSaveRf2c = result.synthCtrl2c",
        "nimFwDbgRfCalSaveRf88 = result.txcalDfe88",
    ]:
        assert expected in save_cal_state_body
    for expected in [
        "volatileStore(addr rf.synthCtrl2c, state.synthCtrl2c)",
        "volatileStore(addr dfe.hbnCtrl30, state.hbnCtrl30)",
        "volatileStore(addr rf.calDfeState240, state.calDfeState240)",
        "volatileStore(addr rf.calDfeState244, state.calDfeState244)",
        "volatileStore(addr rf.calMixerStateF0, state.calMixerStateF0)",
        "nimFwDbgRfCalRestoreRf2c = state.synthCtrl2c",
        "nimFwDbgRfCalRestoreRf88 = state.txcalDfe88",
    ]:
        assert expected in restore_cal_state_body
    for forbidden in [
        "for i, regAddr in RfPriCalSavedRegAddrs:",
        "result.words[i]",
        "state.words[i]",
        "rfRegRead(regAddr)",
        "rfRegWrite(regAddr",
    ]:
        assert forbidden not in save_cal_state_body
        assert forbidden not in restore_cal_state_body
    ble_controller = (ROOT / "src/bl808/blecontroller.nim").read_text()
    save_ble_cal_state_body = ble_controller.split(
        "proc saveBleRfPriCalState(): BleRfPriCalState =",
        1,
    )[1].split("proc restoreBleRfPriCalState", 1)[0]
    restore_ble_cal_state_body = ble_controller.split(
        "proc restoreBleRfPriCalState(state: BleRfPriCalState) =",
        1,
    )[1].split("proc waitBleRfFcalReady", 1)[0]
    assert "BleRfPriCalState = object" in ble_controller
    assert "BleRfPriCalSavedRegAddrs:" not in ble_controller
    assert "BleRfPriCalSavedRegs:" not in ble_controller
    for expected in [
        "BleRfRegBlock {.packed.} = object",
        "BleRfDfeInitBlock {.packed.} = object",
        "doAssert offsetof(BleRfRegBlock, synthCtrl2c) == 0x2C",
        "doAssert offsetof(BleRfRegBlock, rbbRccalCtrl80) == 0x80",
        "doAssert offsetof(BleRfRegBlock, rccalReplay84) == 0x84",
        "doAssert offsetof(BleRfRegBlock, calPathConfig8c) == 0x8C",
        "doAssert offsetof(BleRfRegBlock, channelCalStrobeB0) == 0xB0",
        "doAssert offsetof(BleRfRegBlock, channelCalStatusB4) == 0xB4",
        "doAssert offsetof(BleRfRegBlock, channelFcalConfigBc) == 0xBC",
        "doAssert offsetof(BleRfRegBlock, calMixerStateF0) == 0xF0",
        "doAssert offsetof(BleRfRegBlock, calDfeState240) == 0x240",
        "doAssert offsetof(BleRfRegBlock, calDfeState244) == 0x244",
        "doAssert offsetof(BleRfDfeInitBlock, hbnCtrl30) == 0x30",
        "template bleRfRegs(): ptr BleRfRegBlock",
        "template bleRfDfeInitRegs(): ptr BleRfDfeInitBlock",
        "rbbRccalCtrl80: uint32",
        "rccalReplay84: uint32",
        "calPathConfig8c: uint32",
        "channelCalStrobeB0: uint32",
        "channelCalStatusB4: uint32",
        "channelFcalConfigBc: uint32",
        "txcalParam70: uint32",
        "txcalGain68: uint32",
        "txcalDfe88: uint32",
    ]:
        assert expected in ble_controller
    for old_name in [
        "reserved084",
        "config8c",
        "configB0",
        "txPowerB4",
        "configBc",
    ]:
        assert old_name not in ble_controller
    for expected in [
        "let rf = bleRfRegs()",
        "let dfe = bleRfDfeInitRegs()",
        "result.synthCtrl2c = volatileLoad(addr rf.synthCtrl2c)",
        "result.hbnCtrl30 = volatileLoad(addr dfe.hbnCtrl30)",
        "result.rbbRccalCtrl80 = volatileLoad(addr rf.rbbRccalCtrl80)",
        "result.calPathConfig8c = volatileLoad(addr rf.calPathConfig8c)",
        "result.calDfeState240 = volatileLoad(addr rf.calDfeState240)",
        "result.calDfeState244 = volatileLoad(addr rf.calDfeState244)",
        "result.txcalDfe88 = volatileLoad(addr rf.txcalDfe88)",
    ]:
        assert expected in save_ble_cal_state_body
    for expected in [
        "volatileStore(addr rf.synthCtrl2c, state.synthCtrl2c)",
        "volatileStore(addr dfe.hbnCtrl30, state.hbnCtrl30)",
        "volatileStore(addr rf.rbbRccalCtrl80, state.rbbRccalCtrl80)",
        "volatileStore(addr rf.calPathConfig8c, state.calPathConfig8c)",
        "volatileStore(addr rf.calDfeState240, state.calDfeState240)",
        "volatileStore(addr rf.calDfeState244, state.calDfeState244)",
        "volatileStore(addr rf.txcalDfe88, state.txcalDfe88)",
    ]:
        assert expected in restore_ble_cal_state_body
    for forbidden in [
        "for i, regAddr in BleRfPriCalSavedRegAddrs:",
        "result.words[i]",
        "state.words[i]",
    ]:
        assert forbidden not in save_ble_cal_state_body
        assert forbidden not in restore_ble_cal_state_body
    for expected in [
        "doAssert offsetof(RfRegBlock, synthCtrl2c) == 0x2C",
        "doAssert offsetof(RfRegBlock, priModeCtrl30) == 0x30",
        "doAssert offsetof(RfRegBlock, baseCtrl1) == 0x04",
        "doAssert offsetof(RfRegBlock, calMode14) == 0x14",
        "doAssert offsetof(RfRegBlock, calCtrl1c) == 0x1C",
        "doAssert offsetof(RfRegBlock, capability20) == 0x20",
        "doAssert offsetof(RfRegBlock, scanSynthLatch34) == 0x34",
        "doAssert offsetof(RfRegBlock, scanSynthLatch40) == 0x40",
        "doAssert offsetof(RfRegBlock, rccalTone48) == 0x48",
        "doAssert offsetof(RfRegBlock, scanRxLatch4c) == 0x4C",
        "doAssert offsetof(RfRegBlock, xtalCapTrim5c) == 0x5C",
        "doAssert offsetof(RfRegBlock, rxcalPrep60) == 0x60",
        "doAssert offsetof(RfRegBlock, txcalParam70) == 0x70",
        "doAssert offsetof(RfRegBlock, txcalParam74) == 0x74",
        "doAssert offsetof(RfRegBlock, rxModeCalibrationGate78) == 0x78",
        "doAssert offsetof(RfRegBlock, roscalCtrl7c) == 0x7C",
        "doAssert offsetof(RfRegBlock, rbbRccalCtrl80) == 0x80",
        "doAssert offsetof(RfRegBlock, rccalReplay84) == 0x84",
        "doAssert offsetof(RfRegBlock, txcalDfe88) == 0x88",
        "doAssert offsetof(RfRegBlock, calPathCtrl90) == 0x90",
        "doAssert offsetof(RfRegBlock, bandwidthCtrl94) == 0x94",
        "doAssert offsetof(RfRegBlock, fcalCtrlA0) == 0xA0",
        "doAssert offsetof(RfRegBlock, acalCtrlA4) == 0xA4",
        "doAssert offsetof(RfRegBlock, calResultA8) == 0xA8",
        "doAssert offsetof(RfRegBlock, fcalAc) == 0xAC",
        "doAssert offsetof(RfRegBlock, channelCalStrobeB0) == 0xB0",
        "doAssert offsetof(RfRegBlock, channelCalStatusB4) == 0xB4",
        "doAssert offsetof(RfRegBlock, txcalCtrlB8) == 0xB8",
        "doAssert offsetof(RfRegBlock, channelFcalConfigBc) == 0xBC",
        "doAssert offsetof(RfRegBlock, sdmCtrlC0) == 0xC0",
        "doAssert offsetof(RfRegBlock, sdmDivC4) == 0xC4",
        "doAssert offsetof(RfRegBlock, rfPriBiasTrimCc) == 0xCC",
        "doAssert offsetof(RfRegBlock, optimizeCtrlD0) == 0xD0",
        "doAssert offsetof(RfRegBlock, rfBiasTrimD4) == 0xD4",
        "doAssert offsetof(RfRegBlock, rfCodeConfig110c) == 0x10C",
        "doAssert offsetof(RfRegBlock, vcoPairTable13c) == 0x13C",
        "doAssert offsetof(RfRegBlock, txcalDefaultProfile128) == 0x128",
        "doAssert offsetof(RfRegBlock, txcalDefaultProfile12c) == 0x12C",
        "doAssert offsetof(RfRegBlock, txcalDefaultProfile130) == 0x130",
        "doAssert offsetof(RfRegBlock, calModeDefault138) == 0x138",
        "doAssert offsetof(RfRegBlock, vcoPair2484Mhz164) == 0x164",
        "doAssert offsetof(RfRegBlock, roscalCal0) == 0x168",
        "doAssert offsetof(RfRegBlock, roscalCal1) == 0x16C",
        "doAssert offsetof(RfRegBlock, rxcalReplay) == 0x170",
        "doAssert offsetof(RfRegBlock, channelTuneGate228) == 0x228",
        "doAssert offsetof(RfRegBlock, channelFreqMhz264) == 0x264",
        "doAssert offsetof(RfRegBlock, channelTuneStrobe268) == 0x268",
        "doAssert offsetof(RfRegBlock, channelTuneCtrl26c) == 0x26C",
        "doAssert offsetof(RfRegBlock, xtalControlCode1c0) == 0x1C0",
        "doAssert offsetof(RfRegBlock, xtalDividerConfig1c4) == 0x1C4",
        "doAssert offsetof(RfRegBlock, xtalCountWindowMin1c8) == 0x1C8",
        "doAssert offsetof(RfRegBlock, xtalCountWindowMax1cc) == 0x1CC",
        "doAssert offsetof(RfRegBlock, calSingenCtrl20c) == 0x20C",
        "doAssert offsetof(RfRegBlock, calSingenAmpLo214) == 0x214",
        "doAssert offsetof(RfRegBlock, calSingenAmpHi218) == 0x218",
        "doAssert offsetof(RfRegBlock, calSingenMeasurePrep21c) == 0x21C",
        "doAssert offsetof(RfRegBlock, rxMode220) == 0x220",
        "doAssert offsetof(RfRegBlock, calDfeGate23c) == 0x23C",
        "doAssert offsetof(RfRegBlock, channelSequencer260) == 0x260",
        "doAssert offsetof(RfRegBlock, modemPathEnable504) == 0x504",
        "doAssert offsetof(RfRegBlock, pdCompLatchCtrl50c) == 0x50C",
        "doAssert offsetof(RfRegBlock, channelSequencer2c4) == 0x2C4",
        "doAssert offsetof(RfRegBlock, rfcSequencerBias400) == 0x400",
        "doAssert offsetof(RfRegBlock, modemPathEnable514) == 0x514",
        "doAssert offsetof(RfRegBlock, txcalTosdac600) == 0x600",
        "doAssert offsetof(RfRegBlock, scanSynthControl608) == 0x608",
        "doAssert offsetof(RfRegBlock, calMeasurePrep60c) == 0x60C",
        "doAssert offsetof(RfRegBlock, rxcalSearch614) == 0x614",
        "doAssert offsetof(RfRegBlock, measureCtrl618) == 0x618",
        "doAssert offsetof(RfRegBlock, measureMode61c) == 0x61C",
        "doAssert offsetof(RfRegBlock, measureI620) == 0x620",
        "doAssert offsetof(RfRegBlock, measureQ624) == 0x624",
        "doAssert offsetof(RfRegBlock, scanTxMeasureControl62c) == 0x62C",
        "doAssert offsetof(RfRegBlock, notchCtrl680) == 0x680",
        "doAssert offsetof(RfRegBlock, txPowerComp704) == 0x704",
        "doAssert offsetof(RfRegBlock, rfGainTable75c) == 0x75C",
        "doAssert offsetof(RfRegBlock, rfGainTable760) == 0x760",
        "doAssert offsetof(RfRegBlock, rfGainTable764) == 0x764",
        "doAssert offsetof(RfRegBlock, rfGainTable76c) == 0x76C",
        "doAssert offsetof(RfRegBlock, rfGainTable774) == 0x774",
        "doAssert offsetof(RfRegBlock, rfGainTable77c) == 0x77C",
        "doAssert offsetof(RfRegBlock, rfGainTable784) == 0x784",
        "doAssert offsetof(RfRegBlock, rfGainTable78c) == 0x78C",
        "doAssert offsetof(RfRegBlock, rfGainTable794) == 0x794",
        "doAssert offsetof(RfRegBlock, rfGainTable79c) == 0x79C",
        "doAssert offsetof(RfRegBlock, txPowerComp7ac) == 0x7AC",
        "doAssert offsetof(RfRegBlock, txPowerCompTail7bc) == 0x7BC",
        "doAssert offsetof(RfRegBlock, txPowerCompTail7c0) == 0x7C0",
        "doAssert offsetof(RfRegBlock, txPowerCompTail7c4) == 0x7C4",
        "doAssert offsetof(RfRegBlock, txPowerCompTail7c8) == 0x7C8",
        "doAssert offsetof(RfRegBlock, txPowerCompTail7cc) == 0x7CC",
        "doAssert offsetof(RfRegBlock, txPowerCompTail7d0) == 0x7D0",
        "doAssert offsetof(RfRegBlock, txPowerCompTail7d4) == 0x7D4",
        "doAssert offsetof(RfRegBlock, txPowerCompTail7d8) == 0x7D8",
        "doAssert offsetof(RfPllBlock, pllReset10) == 0x10",
        "doAssert offsetof(RfPllBlock, refdivCtrl14) == 0x14",
        "doAssert offsetof(RfPllBlock, loopFilter18) == 0x18",
        "doAssert offsetof(RfPllBlock, fractionalCtrl1c) == 0x1C",
        "doAssert offsetof(RfPllBlock, fractionalWord28) == 0x28",
        "doAssert offsetof(RfPllBlock, modeCtrl2c) == 0x2C",
        "doAssert offsetof(RfPllBlock, enableCtrl30) == 0x30",
        "doAssert offsetof(RfPllBlock, pllFixedDefault84) == 0x84",
        "doAssert offsetof(RfDfeInitBlock, dfeStaticCtrl820) == 0x820",
        "doAssert offsetof(RfDfeInitBlock, dfeRfFixedDefault884) == 0x884",
        "doAssert offsetof(PhyAgcBlock, rfcSettlingTimerA8) == 0xA8",
        "doAssert offsetof(RfAuxCtrlBlock, rfcAuxPathSelect540) == 0x40",
        "doAssert offsetof(RfAuxCtrlBlock, rfcAuxPathGate544) == 0x44",
    ]:
        assert expected in wifi_fw
    assert "modeCtrl: uint32" not in wifi_fw
    assert "synthCtrl: uint32" not in wifi_fw
    for old_name in [
        "init78",
        "init90",
        "init163c",
        "modemLateGate504",
        "modemLateGate514",
        "rfcLateCtrl260",
        "rfcLateCtrl2c4",
        "config8c",
        "configB0",
        "configB4",
        "configBc",
        "staticCtrlD4",
        "staticCtrl128",
        "staticCtrl12c",
        "staticCtrl130",
        "staticCtrl138",
        "fixedValCtrl110c",
        "fixedValLatch78",
        "fixedStaticConfigCc",
        "staticInitLatchD4",
        "fixedValByteLatch110c",
        "staticInitProfile128",
        "staticInitProfile12c",
        "staticInitProfile130",
        "staticInitLatch138",
        "fixedRxModeGate78",
        "rfPriStaticBiasCc",
        "staticRfBiasD4",
        "fixedRfCode110c",
        "staticTxcalProfile128",
        "staticTxcalProfile12c",
        "staticTxcalProfile130",
        "staticCalMode138",
        "modemBringupLatch504",
        "modemBringupLatch514",
        "synthLatch608",
        "synthDfeLatch63c",
        "scanTxLatch162c",
        "synthScanLatch608",
        "synthDfePathLatch63c",
        "scanTxMeasureLatch62c",
        "fixedPowerTail7bc",
        "txPowerFixedTail7bc",
        "pllFixedVal884",
        "dfeInit814",
        "dfeInit820",
        "dfeFixedVal884",
        "trace84",
        "trace4c",
        "trace162c",
        "configCc",
    ]:
        assert old_name not in wifi_fw
    assert "volatileStore(addr rf.vcoPairTable13c[i]" in vco_table_body
    assert "volatileStore(addr rf.vcoPair2484Mhz164" in vco_table_body
    for expected in [
        "addr rf.rbbRccalCtrl80",
        "addr rf.bandwidthCtrl94",
        "addr rf.scanSynthControl608",
        "addr rf.txcalDfe88",
        "addr rf.channelTuneGate228",
        "addr rf.roscalCtrl7c",
    ]:
        assert expected in rfc_bandwidth_body
    for expected in [
        "addr rf.channelTuneGate228",
        "addr rf.synthCtrl2c",
        "addr rf.channelFreqMhz264",
        "addr rf.channelTuneStrobe268",
        "addr rf.baseCtrl1",
        "addr rf.channelTuneCtrl26c",
    ]:
        assert expected in rfc_channel_body
    for forbidden in [
        "tuneGate228",
        "channelFreq264",
        "channelStrobe268",
        "channelTune26c",
        "rfcChannelSequencer260",
        "rfcChannelSequencer2c4",
        "RfBase + 0x13C'u",
        "RfBase + 0x164'u",
        "RfBase + 0x7C'u",
        "RfBase + 0x88'u",
        "RfBase + 0x94'u",
        "RfBase + 0x228'u",
        "RfBase + 0x264'u",
        "RfBase + 0x268'u",
        "RfBase + 0x26C'u",
        "RfBase + 0x608'u",
    ]:
        assert forbidden not in vco_table_body
        assert forbidden not in rfc_bandwidth_body
        assert forbidden not in rfc_channel_body
    assert "let rf = rfRegs()" in modem_init_mode_body
    assert "RfcModemLateUnknownInit:" not in wifi_fw
    assert "RfcModemLateInit:" not in wifi_fw
    assert "writeRadioRegMaskInit(RfcModemLateUnknownInit)" not in wifi_fw
    assert "writeRadioRegMaskInit(RfcModemLateInit)" not in wifi_fw
    assert "programRfcModemLateInit()" in modem_init_mode_body
    for expected in [
        "let rf = rfRegs()",
        "let bba = bbaAgcRegs()",
        "let phy = phyRegs()",
        "let aux = rfAuxCtrlRegs()",
        "addr rf.baseCtrl1",
        "addr rf.channelTuneCtrl26c",
        "addr rf.channelTuneStrobe268",
        "addr rf.synthCtrl2c",
        "addr rf.synthDfePathControl63c",
        "addr rf.rfcSequencerBias400",
        "addr aux.rfcAuxPathSelect540",
        "addr aux.rfcAuxPathGate544",
        "addr phy.rfcSettlingTimerA8",
        "addr rf.rxMode220",
        "addr rf.bandwidthCtrl94",
        "addr rf.rbbRccalCtrl80",
        "addr rf.channelSequencer260",
        "addr rf.channelSequencer2c4",
        "addr bba.macActiveC01c",
        "addr bba.macActiveC020",
        "addr bba.macActiveC02c",
    ]:
        assert expected in rfc_modem_late_body
    for forbidden in [
        "0x20001400'u32",
        "0x20000540'u32",
        "0x20000544'u32",
        "0x200028A8'u32",
        "rfcLateUnknown400",
        "rfcLateAuxCtrl540",
        "rfcLateAuxCtrl544",
        "rfcLatePhyCtrlA8",
    ]:
        assert forbidden not in wifi_fw
    for expected in [
        "addr rf.xtalControlCode1c0",
        "addr rf.xtalDividerConfig1c4",
        "addr rf.xtalCountWindowMin1c8",
        "addr rf.xtalCountWindowMax1cc",
        "addr rf.modemPathEnable504",
        "addr rf.modemPathEnable514",
    ]:
        assert expected in modem_init_mode_body
    for forbidden in [
        "RfBase + 0x1C0'u",
        "RfBase + 0x1C4'u",
        "RfBase + 0x1C8'u",
        "RfBase + 0x1CC'u",
        "RfBase + 0x504'u",
        "RfBase + 0x514'u",
    ]:
        assert forbidden not in modem_init_mode_body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.roscalCal0",
        "addr rf.roscalCal1",
        "addr rf.rccalReplay84",
        "addr rf.txcalParam70",
    ]:
        assert expected in rf_restore_body
    for forbidden in [
        "RfBase + 0x168'u",
        "RfBase + 0x16C'u",
        "RfBase + 0x084'u",
        "RfBase + 0x070'u",
    ]:
        assert forbidden not in rf_restore_body
    assert "let rf = rfRegs()" in restore_cal_state_body
    assert "addr rf.synthCtrl2c" in restore_cal_state_body
    assert "addr rf.txcalDfe88" in restore_cal_state_body
    assert "addr rf.calPathConfig8c" in restore_cal_state_body
    assert "RfSynthCtrlReg" not in restore_cal_state_body
    assert "rfRegRead(RfPriInit8cReg" not in restore_cal_state_body
    gain_init_body = wifi_fw.split("proc writeRfPriGainInit() =", 1)[1].split(
        "proc rfCalibSeedDefaultVcoIfEmpty", 1
    )[0]
    for expected in [
        "let rf = rfRegs()",
        "addr rf.rfGainTable760",
        "addr rf.rfGainTable75c",
        "addr rf.rfGainTable79c",
        "addr rf.rfGainTable794",
        "addr rf.rfGainTable78c",
        "addr rf.rfGainTable784",
        "addr rf.rfGainTable77c",
        "addr rf.rfGainTable774",
        "addr rf.rfGainTable76c",
        "addr rf.rfGainTable764",
        "addr rf.synthCtrl2c",
        "addr rf.synthDfePathControl63c",
    ]:
        assert expected in gain_init_body
    for forbidden in [
        "0x20001760'u32",
        "0x2000175C'u32",
        "0x2000179C'u32",
        "0x20001794'u32",
        "0x2000178C'u32",
        "0x20001784'u32",
        "0x2000177C'u32",
        "0x20001774'u32",
        "0x2000176C'u32",
        "0x20001764'u32",
        "RfSynthCtrlReg",
        "RfPriInit163cReg",
    ]:
        assert forbidden not in gain_init_body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.txPowerComp704",
        "addr rf.txPowerComp7ac",
    ]:
        assert expected in total_power_comp_body
    for forbidden in [
        "RfBase + 0x704'u",
        "RfBase + 0x7AC'u",
    ]:
        assert forbidden not in total_power_comp_body
    for expected in [
        "bl808RfPriXtal24mFlag: uint8",
        "bl808RfPriXtal26mFlag: uint8",
        "bl808RfPriXtal32mFlag: uint8",
        "bl808RfPriXtal38p4mFlag: uint8",
        "bl808RfPriXtal40mFlag: uint8 = 1",
        "bl808RfPriXtal52mFlag: uint8",
    ]:
        assert expected in wifi_fw
    xtal_index_body = wifi_fw.split(
        "proc xtalIndex(xtalfreqHz: uint32): uint32 {.inline.} =",
        1,
    )[1].split("proc crm_init", 1)[0]
    for expected in [
        "of WlXtal24M: 0'u32",
        "of WlXtal26M: 1'u32",
        "of WlXtal32M: 2'u32",
        "of WlXtal38P4M: 3'u32",
        "of WlXtal40M: 4'u32",
        "of WlXtal52M: 5'u32",
        "else: 5'u32",
    ]:
        assert expected in xtal_index_body
    for expected in [
        "private vendor flag",
        "bl808RfPriXtal24mFlag = 0",
        "bl808RfPriXtal26mFlag = 0",
        "bl808RfPriXtal32mFlag = 0",
        "bl808RfPriXtal38p4mFlag = 0",
        "bl808RfPriXtal40mFlag = 0",
        "bl808RfPriXtal52mFlag = 0",
        "of WlXtal24M:",
        "bl808RfPriXtal24mFlag = 1",
        "of WlXtal26M:",
        "bl808RfPriXtal26mFlag = 1",
        "of WlXtal32M:",
        "bl808RfPriXtal32mFlag = 1",
        "of WlXtal38P4M:",
        "bl808RfPriXtal38p4mFlag = 1",
        "of WlXtal40M:",
        "bl808RfPriXtal40mFlag = 1",
        "of WlXtal52M:",
        "bl808RfPriXtal52mFlag = 1",
    ]:
        assert expected in xtal_input_body
    assert "Remaining unknown" not in xtal_input_body
    assert "case bl808RfXtalIndex" not in xtal_refdiv_body
    assert "case bl808RfXtalIndex" not in xtal_tenths_body
    for expected in [
        "bl808RfPriXtal24mFlag != 0 or bl808RfPriXtal26mFlag != 0",
        "bl808RfPriXtal32mFlag != 0 or bl808RfPriXtal38p4mFlag != 0 or",
        "bl808RfPriXtal40mFlag != 0",
    ]:
        assert expected in xtal_refdiv_body
    for expected in [
        "if bl808RfPriXtal24mFlag != 0:",
        "elif bl808RfPriXtal26mFlag != 0:",
        "elif bl808RfPriXtal32mFlag != 0:",
        "elif bl808RfPriXtal38p4mFlag != 0:",
        "elif bl808RfPriXtal52mFlag != 0:",
    ]:
        assert expected in xtal_tenths_body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.txPowerComp704",
        "addr rf.txPowerComp7ac",
    ]:
        assert expected in efuse_init_body
    assert "addr rf.xtalCapTrim5c" in efuse_xtal_cap_body
    for forbidden in [
        "RfBase + 0x05C'u",
        "RfBase + 0x704'u",
        "RfBase + 0x7AC'u",
    ]:
        assert forbidden not in efuse_init_body
    assert "let rf = rfRegs()" in notch_param_body
    assert "addr rf.notchCtrl680" in notch_param_body
    assert "RfBase + 0x680'u" not in notch_param_body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.scanRxLatch4c",
        "addr rf.txcalParam70",
        "addr rf.roscalCtrl7c",
        "addr rf.rbbRccalCtrl80",
        "addr rf.txcalDfe88",
        "addr rf.fcalCtrlA0",
        "addr rf.optimizeCtrlD0",
        "addr rf.txcalTosdac600",
        "addr rf.scanTxMeasureControl62c",
        "addr rf.channelCalStrobeB0",
        "addr rf.channelCalStatusB4",
        "addr rf.channelFcalConfigBc",
    ]:
        assert expected in rf_stage_snapshot_body
    for forbidden in [
        "0x2000104C'u",
        "0x2000107C'u",
        "0x20001080'u",
        "RfPriTxcalDfeReg.uint",
        "0x200010A0'u",
        "RfOptimizeReg.uint",
        "0x20001600'u",
        "0x2000162C'u",
    ]:
        assert forbidden not in rf_stage_snapshot_body
    for body in [wifi_pll_config_body, rf_optimize_body]:
        assert "let rf = rfRegs()" in body
        assert "addr rf.optimizeCtrlD0" in body
        assert "rfRegRead(RfOptimizeReg" not in body
        assert "rfRegWrite(RfOptimizeReg" not in body
        assert "regRead(RfOptimizeReg.uint)" not in body
        assert "regWrite(RfOptimizeReg.uint" not in body
    assert "addr rf.txcalParam70" in rf_optimize_body
    assert "RfTxcalParamReg.uint" not in rf_optimize_body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.rccalTone48",
        "addr rf.scanRxLatch4c",
        "addr rf.txcalDfe88",
        "addr rf.txcalTosdac600",
        "addr rf.scanTxMeasureControl62c",
    ]:
        assert expected in bz_txcal_snapshot_body
    for forbidden in [
        "rfRegRead(0x20001048'u32)",
        "rfRegRead(0x2000104C'u32)",
        "rfRegRead(RfPriTxcalDfeReg)",
        "rfRegRead(0x20001600'u32)",
        "rfRegRead(0x2000162C'u32)",
    ]:
        assert forbidden not in bz_txcal_snapshot_body
    assert "let rf = rfRegs()" in rxcal_replay_body
    assert "addr rf.rxcalReplay[i]" in rxcal_replay_body
    assert "RfBase + 0x170'u" not in rxcal_replay_body
    sta_tx_prepare = wifi_fw.split(
        "proc wifi_nimfw_prepare_sta_tx_channel*() {.exportc, cdecl.} =",
        1,
    )[1].split("proc wifi_nimfw_coex_force_wifi_role*", 1)[0]
    assert "let reclaimNeeded = nim_ble_coex_wifi_rf_reclaim_needed() != 0'u32" in sta_tx_prepare
    assert "wifiRfCoreInitMode(40000000'u32, wifiBleCoex)" in sta_tx_prepare
    tx_payload_body = wifi_fw.split(
        "proc txl_payload_handle_backup*(param: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split("proc txlTriggerPending", 1)[0]
    assert 'exportc: "nimfw_dbg_sta_tx_rf_latch"' in wifi_fw
    assert "when declared(rfPriApplyWb03AuthTxLatches):" in tx_payload_body
    assert "typeForRfLatch == 2'u32" in tx_payload_body
    assert "inc nimFwDbgStaTxRfLatch" in tx_payload_body
    assert "rfPriApplyWb03AuthTxLatches()" in tx_payload_body
    assert "rwip_wlcoex_set*(en: bool)" in (ROOT / "src/bl808/blecontroller.nim").read_text()
    for phase in [
        "proc phyInitValidateClock() =",
        "proc phyInitProgramBasebandAndAgc() =",
        "proc phyInitProgramReceiveTail() =",
        "proc phyInitProgramInitialChannel() =",
    ]:
        assert phase in wifi_fw
    assert "phy_init+0x16..0x52" in wifi_fw
    assert "phy_init+0x5a..0x938" in wifi_fw
    assert "phy_init+0x93c..0x964" in wifi_fw
    initial_channel_body = wifi_fw.split(
        "proc phyInitProgramInitialChannel() =",
        1,
    )[1].split("proc phy_init*(cfg: pointer)", 1)[0]
    for expected in [
        "phy_init+0x976..0x9a2",
        "crm_clk_set(0)",
        "mdm_set_channel.constprop.0(2412, 2412, 0)",
        "rfc_config_bandwidth(0)",
        "rfc_config_channel(2412)",
        "phy_init+0x9a6..0x9fc",
        "crm_clk_set(0'u32)",
        "bl808MdmSetChannel(initial.primFreq.uint32, initial.centerFreq1.uint32,",
        "rfc_config_bandwidth(0'u32)",
        "rfc_config_channel(initial.centerFreq1.uint32)",
        "volatileStore(addr env.channelBandType",
    ]:
        assert expected in initial_channel_body
    crm_init_body = wifi_fw.split(
        "proc crm_init() {.exportc, cdecl.} =",
        1,
    )[1].split("proc crm_mdm_reset() {.exportc, cdecl.} =", 1)[0]
    crm_reset_body = wifi_fw.split(
        "proc crm_mdm_reset() {.exportc, cdecl.} =",
        1,
    )[1].split("proc crm_clk_set(bandwidth: uint32) {.exportc, cdecl.} =", 1)[0]
    crm_clk_body = wifi_fw.split(
        "proc crm_clk_set(bandwidth: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc signExtend", 1)[0]
    assert "addr crmPhyClockRegs().rfClockMux10" in crm_init_body
    assert "addr crmPhyClockRegs().modemReset18" in crm_reset_body
    assert "addr crmPhyClockRegs().phyClockSelect8" in crm_clk_body
    for body in [crm_init_body, crm_reset_body, crm_clk_body]:
        for forbidden in [
            "cast[ptr uint32](0x24940008'u)",
            "cast[ptr uint32](0x24940010'u)",
            "cast[ptr uint32](0x24940018'u)",
        ]:
            assert forbidden not in body
    assert "WifiAgcMemoryRam {.packed.} = object" in wifi_fw
    assert "words: array[512, uint32]" in wifi_fw
    assert "doAssert sizeof(WifiAgcMemoryRam) == 2048" in wifi_fw
    assert "doAssert offsetof(WifiAgcMemoryRam, words) == 0" in wifi_fw
    assert "WifiAgcMemoryBase = 0x24C0A000'u" in wifi_fw
    assert "WifiAgcMemoryWords = 512" in wifi_fw
    assert "template wifiAgcMemoryRegs(): ptr WifiAgcMemoryRam" in wifi_fw
    assert 'var agcmem* {.exportc: "agcmem".}: array[512, uint32]' in wifi_fw
    assert (
        'proc phy_ldpc_tx_supported(): bool {.importc: "phy_ldpc_tx_supported", cdecl.}'
        in wifi_fw
    )
    assert "External non-BL808 PHY fallback: reports whether TX LDPC is supported." in wifi_fw
    assert wifi_fw.index("when not defined(bl808WifiUseBl808Rf):") < wifi_fw.index(
        'proc phy_ldpc_tx_supported(): bool {.importc: "phy_ldpc_tx_supported", cdecl.}'
    )
    assert "proc copyAgcMemory() =" in wifi_fw
    assert "phy_init+0x452..0x470" in wifi_fw
    assert "0x24C09000 LDPC-memory load path" in wifi_fw
    assert "table load is BLE-only" in wifi_fw
    assert "no WiFi" in wifi_fw
    assert "LDPC memory image is present in the BL808 RF archive" in wifi_fw
    assert "static: doAssert agcmem.len == WifiAgcMemoryWords" in wifi_fw
    for expected in [
        'exportc: "nimfw_dbg_phy_init_count"',
        'exportc: "nimfw_dbg_phy_init_phase"',
        'exportc: "nimfw_dbg_phy_modem_version"',
        'exportc: "nimfw_dbg_phy_clock_count"',
        'exportc: "nimfw_dbg_phy_agc_copy_count"',
        'exportc: "nimfw_dbg_phy_agc_source_first"',
        'exportc: "nimfw_dbg_phy_agc_source_last"',
        'exportc: "nimfw_dbg_phy_agc_dest_first"',
        'exportc: "nimfw_dbg_phy_agc_dest_last"',
        'exportc: "nimfw_dbg_phy_wifi_ldpc_absent"',
        "nimFwDbgPhyInitPhase = 3'u32",
        "inc nimFwDbgPhyAgcCopyCount",
        "nimFwDbgPhyWifiLdpcAbsent = 1'u32",
        "nimFwDbgPhyAgcSourceFirst = agcmem[0]",
        "nimFwDbgPhyAgcSourceLast = agcmem[WifiAgcMemoryWords - 1]",
        "nimFwDbgPhyAgcDestFirst = volatileLoad(addr dst.words[0])",
        "nimFwDbgPhyAgcDestLast =",
    ]:
        assert expected in wifi_fw
    assert "let dst = wifiAgcMemoryRegs()" in wifi_fw
    assert "volatileStore(addr dst.words[i], src[i])" in wifi_fw
    assert "cast[ptr UncheckedArray[uint32]](AgcMemoryBase)" not in wifi_fw
    assert "copyAgcMemory()" in wifi_fw
    recovered_phy_body = wifi_fw.split(
        "proc bl808PhyProgramRecoveredRegs() =",
        1,
    )[1].split("proc bl808PhyProgramAgcCopyTailRegs()", 1)[0]
    assert "let mdm = wifiModemRegs()" in recovered_phy_body
    assert "let macPhy = macPhyCtrlRegs()" in recovered_phy_body
    for expected in [
        "let spatialStreamCountMinus1 =",
        "let txChainCountMinus1 =",
        "let heOrBandwidthProfile =",
        "let modemCapability21 =",
        "let modemCapability30 =",
    ]:
        assert expected in recovered_phy_body
    for forbidden in [
        "let modemBits11to8",
        "let modemBits15to12",
        "let modemBits7to4",
        "let modemBit22OrAc",
        "let modemBit21",
        "let modemBit30",
    ]:
        assert forbidden not in recovered_phy_body
    for expected in [
        "addr mdm.bandwidth20MProfile820",
        "addr mdm.versionFeatureCtrl800",
        "addr mdm.channelTypeCtrl824",
        "addr macPhy.channelBandwidthCtrl310",
        "addr mdm.channelModeCtrl930",
        "addr mdm.basebandDfeTimeout3bc",
        "addr mdm.basebandDfeEnable414",
        "addr mdm.basebandRxPathCtrlC40",
        "addr mdm.basebandRxPathCtrlC44",
    ]:
        assert expected in recovered_phy_body
    for forbidden in [
        "WifiModemBase + 0x820'u",
        "WifiModemBase + 0x800'u",
        "WifiModemBase + 0x824'u",
        "WifiModemBase + 0x930'u",
        "WifiModemBase + 0x3BC'u",
        "WifiModemBase + 0x414'u",
        "WifiModemBase + 0xC40'u",
        "WifiModemBase + 0xC44'u",
        "cast[ptr uint32](0x24B00310'u)",
    ]:
        assert forbidden not in recovered_phy_body
    mdm_channel_body = wifi_fw.split(
        "proc bl808MdmSetChannel(primFreq, centerFreq1, chanType: uint32) =",
        1,
    )[1].split("proc pulsePhyChannelRfWindow()", 1)[0]
    assert "let mdm = wifiModemRegs()" in mdm_channel_body
    assert "let macPhy = macPhyCtrlRegs()" in mdm_channel_body
    for expected in [
        "addr mdm.channelCenterRatio84c",
        "addr mdm.channelTypeCtrl824",
        "addr macPhy.channelBandwidthCtrl310",
        "addr mdm.bandwidth20MProfile820",
        "addr mdm.bandwidth20MProfile830",
        "addr mdm.bandwidth20MSignal83c",
        "addr mdm.bandwidth20MSignal840",
        "addr mdm.bandwidth20MFilter860",
        "addr mdm.bandwidth20MGate874",
        "addr mdm.bandwidth20MEnable834",
        "addr mdm.bandwidth20MGuard814",
    ]:
        assert expected in mdm_channel_body
    for forbidden in [
        "WifiModemBase + 0x84C'u",
        "WifiModemBase + 0x824'u",
        "WifiModemBase + 0x820'u",
        "WifiModemBase + 0x830'u",
        "WifiModemBase + 0x83C'u",
        "WifiModemBase + 0x840'u",
        "WifiModemBase + 0x860'u",
        "WifiModemBase + 0x874'u",
        "WifiModemBase + 0x834'u",
        "WifiModemBase + 0x814'u",
        "cast[ptr uint32](0x24B00310'u)",
    ]:
        assert forbidden not in mdm_channel_body
    channel_pulse_body = wifi_fw.split(
        "proc pulsePhyChannelRfWindow() =",
        1,
    )[1].split("proc phy_mdm_isr*", 1)[0]
    assert "addr wifiModemRegs().phyChannelPulse888" in channel_pulse_body
    assert "cast[ptr uint32](0x24C00888'u)" not in channel_pulse_body
    bba_rx_body = wifi_fw.split(
        "proc bba_loop(rxVector: pointer, frameType: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc modemVersionReg()", 1)[0]
    for expected in [
        "let rxv = bbaRxVecPtr(rxVector)",
        "addr rxv.rssiDbm",
        "proc bbaRxFormatWord1(rxv: ptr BbaRxVectorView): uint32",
        "addr rxv.rxFormatWord0",
        "addr rxv.rxFormatWord1Rate",
        "addr rxv.rxFormatWord1Mcs",
        "addr rxv.rxFormatWord1Flags",
        "addr rxv.carrierFreqOffset",
    ]:
        assert expected in bba_rx_body
    for forbidden in [
        "cast[ptr uint8](cast[uint](rxVector) + 5'u)",
        "cast[ptr uint16](cast[uint](rxVector) + 0x16'u)",
        "cast[ptr UncheckedArray[uint32]](rxVector)",
        "let byte5",
        "let half16",
    ]:
        assert forbidden not in bba_rx_body
    phy_mdm_isr_body = wifi_fw.split(
        "proc phy_mdm_isr*() {.exportc, cdecl.} =",
        1,
    )[1].split("proc phy_rc_isr*", 1)[0]
    phy_rc_isr_body = wifi_fw.split(
        "proc phy_rc_isr*() {.exportc, cdecl.} =",
        1,
    )[1].split("proc phy_get_version*", 1)[0]
    for body in [phy_mdm_isr_body, phy_rc_isr_body]:
        assert "let mdm = wifiModemRegs()" in body
        assert "addr mdm.intStatusB41c" in body
        assert "addr mdm.intAckB420" in body
        assert "WifiModemBase + 0xB41C'u" not in body
        assert "WifiModemBase + 0xB420'u" not in body
    phy_get_version_body = wifi_fw.split(
        "proc phy_get_version*(versionOut: pointer, buf: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split("proc phy_get_channel_raw*", 1)[0]
    assert "addr wifiModemRegs().versionScratch3c" in phy_get_version_body
    assert "WifiModemBase + 0x3C'u" not in phy_get_version_body
    phy_get_channel_body = wifi_fw.split(
        'proc phy_get_channel_raw*(info: pointer, index: uint8)\n'
        '      {.exportc: "phy_get_channel", cdecl.} =',
        1,
    )[1].split("proc phy_get_ntx*", 1)[0]
    assert "let env = phyEnvViewPtr()" in phy_get_channel_body
    for expected in [
        "addr env.channelBandType",
        "addr env.primaryFreq",
        "addr env.centerFreq1",
        "addr env.centerFreq2OrTxPower",
    ]:
        assert expected in phy_get_channel_body
    for forbidden in [
        "phyEnvWord(36'u)",
        "phyEnvWord(40'u)",
    ]:
        assert forbidden not in phy_get_channel_body
    phy_stop_body = wifi_fw.split(
        "proc phy_stop*() {.exportc, cdecl.} =",
        1,
    )[1].split("proc phy_mdm_reset*", 1)[0]
    assert "discard regRead(MACHW_STATE_CNTRL_REG)" in phy_stop_body
    assert "cast[ptr uint32](0x24B00038'u)" not in phy_stop_body
    phy_aid_body = wifi_fw.split(
        "proc phy_set_aid*(aid: uint16)",
        1,
    )[1].split("proc phy_set_group_id_info*", 1)[0]
    assert "addr mdm.aid" in phy_aid_body
    assert "addr mdm.aidMaskLo" in phy_aid_body
    assert "addr mdm.aidMaskHi" in phy_aid_body
    phy_group_body = wifi_fw.split(
        "proc phy_set_group_id_info*(membership: pointer, userPosition: pointer)",
        1,
    )[1].split("proc phy_update_power_table*", 1)[0]
    assert "addr mdm.groupMembership0" in phy_group_body
    assert "addr mdm.groupMembership1" in phy_group_body
    assert "addr mdm.userPosition[i]" in phy_group_body
    for forbidden in [
        "WifiModemBase + 0x8C0'u",
        "WifiModemBase + 0x8C4'u",
        "WifiModemBase + 0x8C8'u",
        "WifiModemBase + 0x8A8'u",
        "WifiModemBase + 0x8AC'u",
        "WifiModemBase + 0x8B0'u",
    ]:
        assert forbidden not in phy_aid_body
        assert forbidden not in phy_group_body
    bba_pd_gain_body = wifi_fw.split(
        "proc bbaSetPdGain(gain: uint32) =",
        1,
    )[1].split("proc bba_init()", 1)[0]
    assert "let mdm = wifiModemRegs()" in bba_pd_gain_body
    assert "let bba = bbaAgcRegs()" in bba_pd_gain_body
    assert "addr mdm.rxGainTimingC044" in bba_pd_gain_body
    for expected in [
        "addr bba.pdGain390",
        "addr bba.pdSlope3c0",
        "addr bba.pdComp36c",
        "addr bba.pdTiming3ac",
    ]:
        assert expected in bba_pd_gain_body
    assert "cast[ptr uint32](0x24C0C044'u)" not in bba_pd_gain_body
    for forbidden in [
        "cast[ptr uint32](0x24C0B390'u)",
        "cast[ptr uint32](0x24C0B3C0'u)",
        "cast[ptr uint32](0x24C0B36C'u)",
        "cast[ptr uint32](0x24C0B3AC'u)",
    ]:
        assert forbidden not in bba_pd_gain_body
    bba_init_body = wifi_fw.split(
        "proc bba_init() {.exportc, cdecl.} =",
        1,
    )[1].split("proc bba_reset()", 1)[0]
    bba_reset_body = wifi_fw.split(
        "proc bba_reset() {.exportc, cdecl.} =",
        1,
    )[1].split("proc bbaSetPdLatch", 1)[0]
    bba_pd_latch_body = wifi_fw.split(
        "proc bbaSetPdLatch(enable: bool) =",
        1,
    )[1].split("proc bbaUpdatePdComp", 1)[0]
    bba_update_pd_comp_body = wifi_fw.split(
        "proc bbaUpdatePdComp(target: uint8) =",
        1,
    )[1].split("proc bbaCeUpdateCapcode", 1)[0]
    for body in [bba_init_body, bba_reset_body, bba_update_pd_comp_body]:
        assert "let bba = bbaAgcRegs()" in body
        assert "addr bba.pdGain390" in body
        assert "addr bba.pdCompC830" in body
        assert "cast[ptr uint32](0x24C0B390'u)" not in body
        assert "cast[ptr uint32](0x24C0C830'u)" not in body
    for body in [bba_init_body, bba_reset_body, bba_pd_latch_body]:
        assert "let rf = rfRegs()" in body
        assert "addr rf.pdCompLatchCtrl50c" in body
        assert "cast[ptr uint32](0x2000150C'u)" not in body
    rxgain_body = wifi_fw.split(
        "proc rc2_config_rxgain*(offset: int8) {.exportc, cdecl.} =",
        1,
    )[1].split("proc bl808PhyProgramRxTailRegs()", 1)[0]
    assert "let mdm = wifiModemRegs()" in rxgain_body
    for expected in [
        "addr mdm.rxGainTable0C080",
        "addr mdm.rxGainTable1C084",
        "addr mdm.rxGainTable2C088",
    ]:
        assert expected in rxgain_body
    for forbidden in [
        "cast[ptr uint32](0x24C0C080'u)",
        "cast[ptr uint32](0x24C0C084'u)",
        "cast[ptr uint32](0x24C0C088'u)",
    ]:
        assert forbidden not in rxgain_body
    rx_tail_body = wifi_fw.split(
        "proc bl808PhyProgramRxTailRegs() =",
        1,
    )[1].split("proc bl808MdmSetChannel", 1)[0]
    assert "let rf = rfRegs()" in rx_tail_body
    assert "let mdm = wifiModemRegs()" in rx_tail_body
    assert "addr rf.channelTuneCtrl26c" in rx_tail_body
    assert "addr mdm.rxGainTailCtrlC018" in rx_tail_body
    assert "RfBase + 0x26C'u" not in rx_tail_body
    assert "cast[ptr uint32](0x24C0C018'u)" not in rx_tail_body
    assert "let clkCount = phyClockCountFromVersion(version)" in wifi_fw
    copy_phy_cfg_body = wifi_fw.split(
        "proc copyPhyInitCfg(cfg: pointer) =",
        1,
    )[1].split("proc copyAgcMemory()", 1)[0]
    for expected in [
        "let env = phyEnvViewPtr()",
        "addr env.initCfgWords[i]",
        "addr env.channelBandType",
        "addr env.primaryFreq",
        "addr env.centerFreq1",
        "addr env.centerFreq2OrTxPower",
    ]:
        assert expected in copy_phy_cfg_body
    for forbidden in [
        "phyEnvWord((i * 4).uint)",
        "phyEnvWord(36'u)",
        "phyEnvWord(40'u)",
    ]:
        assert forbidden not in copy_phy_cfg_body
    phy_update_power_body = wifi_fw.split(
        "proc phy_update_power_table*() {.exportc, cdecl.} =",
        1,
    )[1].split("proc phyEnvCenter2Word", 1)[0]
    assert "addr phyEnvViewPtr().channelBandType" in phy_update_power_body
    assert "phyEnvByte(37'u)" not in phy_update_power_body
    phy_set_channel_body = wifi_fw.split(
        "proc phy_set_channel*(channel: ptr ChanCtxtDefView, force: uint32)",
        1,
    )[1].split("proc phyInitValidateClock", 1)[0]
    for expected in [
        "let env = phyEnvViewPtr()",
        "addr env.channelBandType",
        "addr env.primaryFreq",
        "addr env.centerFreq1",
        "addr env.centerFreq2OrTxPower",
        "addr env.txPowerAndReserved",
    ]:
        assert expected in phy_set_channel_body
    for forbidden in [
        "phyEnvByte(37'u)",
        "phyEnvHalf(36'u)",
        "phyEnvHalf(38'u)",
        "phyEnvHalf(40'u)",
        "phyEnvHalf(42'u)",
        "phyEnvHalf(44'u)",
    ]:
        assert forbidden not in phy_set_channel_body
    assert phy_init_body.index("phyInitValidateClock()") < phy_init_body.index(
        "phyInitProgramBasebandAndAgc()"
    )
    assert phy_init_body.index("phyInitProgramBasebandAndAgc()") < phy_init_body.index(
        "phyInitProgramReceiveTail()"
    )
    assert phy_init_body.index("phyInitProgramReceiveTail()") < phy_init_body.index(
        "phyInitProgramInitialChannel()"
    )
    assert phy_init_body.index("phyInitProgramInitialChannel()") < phy_init_body.index(
        "copyPhyInitCfg(cfg)"
    )
    phy_baseband_body = wifi_fw.split(
        "proc phyInitProgramBasebandAndAgc() =",
        1,
    )[1].split("proc phyInitProgramReceiveTail", 1)[0]
    assert phy_baseband_body.index("bl808PhyProgramRecoveredRegs()") < phy_baseband_body.index(
        "bl808PhyProgramPreAgcRegs()"
    )
    assert phy_baseband_body.index("bl808PhyProgramPreAgcRegs()") < phy_baseband_body.index(
        "copyAgcMemory()"
    )
    assert phy_baseband_body.index("copyAgcMemory()") < phy_baseband_body.index(
        "bl808PhyProgramAgcCopyTailRegs()"
    )
    for expected in [
        "let mdm = wifiModemRegs()",
        "let bba = bbaAgcRegs()",
        "let crm = crmPhyClockRegs()",
        "addr mdm.preAgcCtrl324",
        "addr mdm.preAgcSignal848",
        "addr mdm.preAgcSignal844",
        "addr mdm.preAgcTiming8d4",
        "addr mdm.preAgcTiming8d8",
        "addr mdm.preAgcTiming8e0",
        "addr mdm.preAgcTiming8e4",
        "addr mdm.bandwidth20MGuard814",
        "addr mdm.preAgcDetect894",
        "addr mdm.bandwidth20MEnable834",
        "addr crm.rfClockMux10",
        "addr bba.macActiveC01c",
        "addr bba.agcCoreCtrl100",
        "addr bba.agcCoreTableC80c",
        "addr bba.pdGain390",
    ]:
        assert expected in pre_agc_body
    for expected in [
        "let bba = bbaAgcRegs()",
        "let crm = crmPhyClockRegs()",
        "addr bba.pdGain390",
        "addr crm.rfClockMux10",
    ]:
        assert expected in agc_copy_tail_body
    for forbidden in [
        "PhyInitBasebandPreAgcInit",
        "writeRadioRegMaskInitRange",
        "0x24C00324'u32",
        "0x24C00848'u32",
        "0x24C00844'u32",
        "0x24C008D4'u32",
        "0x24C008D8'u32",
        "0x24C008E0'u32",
        "0x24C008E4'u32",
        "0x24C00814'u32",
        "0x24C00894'u32",
        "0x24C0B100'u32",
        "0x24C0C80C'u32",
    ]:
        assert forbidden not in wifi_fw
    for expected in [
        "let bba = bbaAgcRegs()",
        "addr bba.agcCoreWindow3a4",
        "addr bba.agcCoreDetect394",
        "addr bba.agcCoreDetect398",
        "addr bba.agcCoreProfile364",
        "addr bba.agcCoreProfile370",
        "addr bba.agcCoreStage0B380",
        "addr bba.agcCoreStage2B388",
        "addr bba.pdCompRampC838",
        "addr bba.pdCompRampC83c",
        "addr bba.pdCompRampC840",
        "addr bba.agcCoreEnable004",
        "addr bba.agcCoreTimeout414",
    ]:
        assert expected in agc_core_body
    for forbidden in [
        "PhyInitAgcCoreInit",
        "0x24C0B3A4'u32",
        "0x24C0B394'u32",
        "0x24C0B398'u32",
        "0x24C0B364'u32",
        "0x24C0C838'u32",
        "0x24C0C83C'u32",
        "0x24C0C840'u32",
        "0x24C0B414'u32",
    ]:
        assert forbidden not in wifi_fw
    assert "proc wrapPhyAssertErr*(fileOrCond, condOrFile: cstring," in wifi_fw
    assert '{.exportc: "__wrap_phy_assert_err", cdecl, noinline.}' in wifi_fw
    assert 'nimFwConnectTrace2U32("[WIFI-CT] phy_assert "' in wifi_fw
    wrap_phy_assert_body = wifi_fw.split(
        "proc wrapPhyAssertErr*(fileOrCond, condOrFile: cstring",
        1,
    )[1].split("proc tpc_update_tx_power*", 1)[0]
    assert "let mdm = wifiModemRegs()" in wrap_phy_assert_body
    assert "volatileLoad(addr mdm.versionScratch3c)" in wrap_phy_assert_body
    assert "regRead(0x24C0003C'u32)" not in wrap_phy_assert_body
    assert "line == 586.cint or line == 0x20FA.cint or line == 0x2A60.cint" in wifi_fw
    blecontroller = (ROOT / "src/bl808/blecontroller.nim").read_text()
    blerfdata = (ROOT / "src/bl808/blerfdata.nim").read_text()
    assert "BleLdpcMemBase* = 0x24C09000'u32" in blerfdata
    assert "BleLdpcMem*: array[375, uint32]" in blerfdata
    assert "BleLdpcInitWords = 190" in blecontroller
    assert "BlePhyMemoryRegs {.packed.} = object" in blecontroller
    assert "doAssert offsetof(BlePhyMemoryRegs, ldpcMode) == 0x834" in blecontroller
    assert "bleRegUpdatePtr(addr phyMem.ldpcMode, BlePhyLdpcLoadModeMask" in blecontroller
    assert "bleRegStorePtr(addr phyMem.ldpcCtrlB340, 0'u32)" in blecontroller
    assert "bleRegClearPtr(addr phyMem.memMode, BlePhyLdpcMemSelectMask)" in blecontroller
    assert "writeBleMemoryWords(blerfdata.BleLdpcMemBase, blerfdata.BleLdpcMem" in blecontroller

    for archive in [bl808_rf, bl606p_rf]:
        symbols = subprocess.check_output(
            ["riscv64-unknown-elf-objdump", "-t", str(archive)],
            cwd=ROOT,
            text=True,
        )
        assert "rf_init" in symbols
        assert "rf_pri_init" in symbols

    bl808_symbols = subprocess.check_output(
        ["riscv64-unknown-elf-objdump", "-t", str(bl808_rf)],
        cwd=ROOT,
        text=True,
    )
    for symbol in [
        "rf_set_channel",
        "rf_dump_status",
        "rf_pri_full_cal",
        "rf_pri_txcal",
        "rf_pri_lo_fcal",
        "wl_rf_set_bz_target_power_table",
        "wl_cfg_get",
        "modem_init_core",
    ]:
        assert symbol in bl808_symbols
    assert "ldpcmem" not in bl808_symbols.lower()

    llvm_disasm = subprocess.check_output(
        [
            llvm_objdump_cmd(),
            "-dr",
            "--mattr=+xtheadba,+xtheadbb,+xtheadbs,+xtheadcondmov,+xtheadmac,+xtheadmemidx,+xtheadmempair,+xtheadsync",
            str(bl808_rf),
        ],
        cwd=ROOT,
        text=True,
    ).lower()
    assert "th.extu" in llvm_disasm
    assert "agcmem-0x24c0a000" in llvm_disasm
    assert "24c09000" not in llvm_disasm

    bl808_disasm = subprocess.check_output(
        ["riscv64-unknown-elf-objdump", "-d", "-C", str(bl808_rf)],
        cwd=ROOT,
        text=True,
    )
    for section in [
        "Disassembly of section .text.rf_init:",
        "Disassembly of section .text.rf_set_channel:",
        "Disassembly of section .text.rf_pri_full_cal:",
        "Disassembly of section .text.rf_pri_init:",
        "Disassembly of section .text.wl_cfg_get:",
        "Disassembly of section .text.modem_init_core:",
    ]:
        assert section in bl808_disasm

    rf_init = bl808_disasm.split("<rf_init>:", 1)[1].split(
        "Disassembly of section .text.rf_dump_status", 1
    )[0]
    assert "beqz" in rf_init
    assert "jalr" in rf_init
    assert "li\ta5,1" in rf_init or "li a5,1" in rf_init


def test_rf_symbol_provenance_checker_rejects_archive_fallbacks():
    checker = (ROOT / "tools/validate_rf_symbol_provenance.py").read_text()
    wifi_objdump = (ROOT / "tools/validate_wifi_fw_objdump.sh").read_text()
    hw_validate = (ROOT / "tools/hw_validate.py").read_text()

    for expected in [
        "FORBIDDEN_RF_ARCHIVE_MARKERS = [",
        '"librf_bl808.a"',
        '"libbl606p_phyrf.a"',
        '"bl606p_phyrf"',
        'parser.add_argument("--build-log", type=Path, action="append", default=[])',
        'parser.add_argument("--link-map", type=Path, action="append", default=[])',
        "def check_build_log(path: Path) -> list[str]:",
        "for marker in FORBIDDEN_RF_ARCHIVE_MARKERS if marker in text",
        "def check_link_map(path: Path) -> list[str]:",
        "forbidden RF archive member in link map",
        "no RF archive members extracted in link map",
        '".a(" not in stripped',
        "def check_wifi_phy_memory_init(archive: Path) -> list[str]:",
        "def check_wifi_object_phy_memory_init(obj: Path) -> list[str]:",
        "--check-wifi-phy-memory-init",
        "--rf-archive",
        "agcmem-0x24c0a000",
        "missing Nim AGC copy evidence to 0x24C0A000",
        "Nim WiFi PHY memory init copies agcmem and has no LDPC RAM path",
        "unexpected Nim WiFi LDPC RAM reference 0x24C09000",
        "failures.extend(check_wifi_object_phy_memory_init(args.wifi_object))",
        'missing = check_defined(args.wifi_object, WIFI_RF_SYMBOLS, "wifi-object")',
        'failures.extend(f"wifi-object:{symbol}" for symbol in missing)',
        'missing = check_defined(args.ble_object, BLE_RF_SYMBOLS, "ble-object")',
        'failures.extend(f"ble-object:{symbol}" for symbol in missing)',
        "24c09000",
        "unexpected WiFi ldpcmem symbol",
        "def check_elf_defined(\n    path: Path, symbols: list[str], label: str, required: bool",
        "parser.add_argument(\n        \"--require-elf-symbols\",",
        "parser.add_argument(\n        \"--require-wifi-elf-symbols\",",
        "parser.add_argument(\n        \"--require-ble-elf-symbols\",",
        "missing_required = check_elf_defined(",
        "HW_VALIDATION_OBJECTS = [",
        '"@pbl808@swifi_fw.nim.c.o"',
        '"@pbl808@sblecontroller.nim.c.o"',
        "def inferred_hw_validation_labels(elf: Path) -> set[str]:",
        "--infer-hw-validation-nimcache-objects",
        "inferred_hw_validation_labels(elf) if infer_required else set()",
        "def hw_validation_nimcache_object(elf: Path, object_name: str) -> Path | None:",
        "def check_hw_validation_nimcache_objects(",
        "check_hw_validation_nimcache_objects(",
        "check_wifi_phy_memory: bool",
        'missing = check_defined(obj, symbols, f"{elf} {label}-nimcache-object")',
        'failures.extend(f"{obj}:missing:{symbol}" for symbol in missing)',
        'if label == "wifi" and check_wifi_phy_memory:',
        "failures.extend(check_wifi_object_phy_memory_init(obj))",
        "args.check_wifi_phy_memory_init",
        "def add_hw_validation_test_inputs(",
        "--hw-validation-test",
        "--hw-validation-work-dir",
        "args.check_hw_validation_nimcache_objects = True",
        "args.infer_hw_validation_nimcache_objects = True",
        'work_dir / "bin" / test_name / "kernel.elf"',
        'work_dir / "logs" / f"{test_name}.kernel.build.log"',
        "check-hw-validation-nimcache-objects",
        "require-hw-validation-nimcache-objects",
        "require-hw-validation-wifi-nimcache-object",
        "require-hw-validation-ble-nimcache-object",
        "fail if any converted WiFi RF/PHY symbol is not defined in each ELF",
        "fail if any converted BLE/coex RF symbol is not defined in each ELF",
        "required_symbols.extend(WIFI_RF_SYMBOLS)",
        "required_symbols.extend(BLE_RF_SYMBOLS)",
        '"wl_rf_cfg_init"',
        '"wl_rmem_size_get"',
        '"wl_env_get"',
        '"rfc_config_bandwidth"',
        '"rfc_config_channel"',
        '"modem_init"',
        '"modem_restore"',
        '"rf_dump_status"',
        '"phy_get_mac_freq"',
        '"phy_get_version"',
        '"phy_get_channel"',
        '"phy_mdm_isr"',
        '"phy_rc_isr"',
        '"phy_ldpc_tx_supported"',
        '"phy_ldpc_rx_supported"',
        '"phy_set_channel"',
        '"phy_powroffset_set"',
        '"trpc_update_power"',
        '"trpc_get_default_power_idx"',
        '"rf_pri_init"',
        '"rf_pri_input_xtalfreq"',
        '"rf_pri_config_mode"',
        '"rf_pri_input_device_info"',
        '"rf_pri_update_param"',
        '"rf_pri_get_notch_param"',
        '"rf_pri_optimize"',
        '"rf_pri_set_channel_pwr_comp"',
        '"rf_pri_set_bandwidth"',
        '"rf_pri_get_vco_freq_cw"',
        '"rf_pri_get_vco_idac_cw"',
        '"ble_rf_init"',
        '"ble_rf_set_pwr_offset_table"',
        '"ble_rf_get_pwr_offset"',
        '"ble_rf_set_tx_channel"',
        '"rf_txpwr_dbm2cs"',
        '"rf_txpwr_cs2dbm"',
        '"nim_ble_coex_wifi_tx_window_enter"',
        '"nim_ble_coex_wifi_tx_window_leave"',
        '"nim_ble_coex_wifi_rf_reclaim_needed"',
        "defines retained RF/PHY symbols",
        "RF/PHY symbols not retained in ELF",
        "f\"{label} required\"",
    ]:
        assert expected in checker

    for expected in [
        "VALIDATE_RF_ELF",
        "VALIDATE_RF_HW_TEST",
        "VALIDATE_RF_HW_TESTS",
        "VALIDATE_RF_BUILD_LOG",
        "VALIDATE_RF_LINK_MAP",
        "VALIDATE_RF_REQUIRE_HW_NIMCACHE",
        "WiFi phy_init copies agcmem to 0x24C0A000 and has no LDPC RAM path",
        "rejects extracted RF archive members in the link map",
        "--check-hw-validation-nimcache-objects",
        "--hw-validation-test \"$VALIDATE_RF_HW_TEST\"",
        "IFS=',' read -r -a rf_hw_tests",
        "for rf_hw_test in \"${rf_hw_tests[@]}\"",
        "--require-hw-validation-wifi-nimcache-object",
        "inferred_map=\"${VALIDATE_RF_ELF%.elf}.map\"",
        "RF_ARGS+=(--link-map \"$inferred_map\")",
        'if [[ "$VALIDATE_RF_ELF" == */build/hw-validation/bin/*/kernel.elf ]]; then',
        "RF_ARGS+=(--infer-hw-validation-nimcache-objects)",
        'inferred_build_log="$(dirname "$(dirname "$(dirname "$VALIDATE_RF_ELF")")")/logs/${test_name}.kernel.build.log"',
        'RF_ARGS+=(--build-log "$inferred_build_log")',
        "--rf-archive src/bl808/librf_bl808.a --check-wifi-phy-memory-init",
        "RF/PHY symbol provenance:",
        "python3 tools/validate_rf_symbol_provenance.py",
        "RF_ARGS=(--wifi-object \"$NIM_BIN\")",
    ]:
        assert expected in wifi_objdump

    for expected in [
        'map_path = bin_dir / f"{build_id}.map"',
        'f"--passL:-Wl,-Map,{map_path}"',
    ]:
        assert expected in hw_validate


def test_rf_pri_fixed_value_wb03_branch_and_trace_targets_are_locked():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    manifest = (ROOT / "tools/hardware_validation.json").read_text()

    fixed_body = wifi_fw.split("proc writeRfPriFixedValueRegs() =", 1)[1].split(
        "proc rfPriApplyWb03RuntimeLatches()",
        1,
    )[0]
    wb03_runtime_latches_body = wifi_fw.split(
        "proc rfPriApplyWb03RuntimeLatches() =",
        1,
    )[1].split("var nim_wifi_rf_pri_txcal_count", 1)[0]
    wb03_rxcal_tosdac_latch_body = wifi_fw.split(
        "proc rfPriApplyWb03RxcalTosdacLatch() =",
        1,
    )[1].split("proc rfSignedByte", 1)[0]
    wb03_scan_latches_body = wifi_fw.split(
        "proc rfPriApplyWb03ScanRxLatches() =",
        1,
    )[1].split("proc rfPriPrepareWb03MacActiveScanState()", 1)[0]
    wb03_mac_active_body = wifi_fw.split(
        "proc rfPriPrepareWb03MacActiveScanState() =",
        1,
    )[1].split("proc rfPriApplyWb03AuthTxLatches()", 1)[0]
    wb03_auth_tx_latches_body = wifi_fw.split(
        "proc rfPriApplyWb03AuthTxLatches() =",
        1,
    )[1].split("proc rfPriCaptureWb03AuthTxPrePush()", 1)[0]
    wb03_auth_tx_capture_body = wifi_fw.split(
        "proc rfPriCaptureWb03AuthTxPrePush() =",
        1,
    )[1].split("proc captureAuthTxHwPrePush", 1)[0]
    wb03_rfc_entry_body = wifi_fw.split(
        "proc rfPriApplyWb03RfcEntryBaseline() =",
        1,
    )[1].split("proc rfPriApplyWb03ScanBaseline()", 1)[0]
    wb03_rfc_wait_body = wifi_fw.split(
        "proc rfPriWaitConfigIdleForWb03RfcEntry() =",
        1,
    )[1].split("proc rfPriApplyWb03RfcEntryBaseline()", 1)[0]
    wb03_scan_baseline_body = wifi_fw.split(
        "proc rfPriApplyWb03ScanBaseline() =",
        1,
    )[1].split("proc wlCfgU32", 1)[0]
    rf70_search_body = wifi_fw.split(
        "proc rfPriSearchRf70ReplayWindow(window: int): tuple[ok: bool, nibble: uint32] =",
        1,
    )[1].split("proc rfPriPopulateWb03TxcalRf70ReplayFieldsFromSearch", 1)[0]
    rf70_search_commit_body = wifi_fw.split(
        "proc rfPriPopulateWb03TxcalRf70ReplayFieldsFromSearch(): bool =",
        1,
    )[1].split("proc rfPriReplayWb03Rf70FromTxcalCalWords()", 1)[0]
    rf70_populate_body = wifi_fw.split(
        "proc rfPriPopulateWb03TxcalRf70ReplayFields() =",
        1,
    )[1].split("proc rfPriApplyWb03RccalSeed()", 1)[0]
    rf70_replay_body = wifi_fw.split(
        "proc rfPriReplayWb03Rf70FromTxcalCalWords() =",
        1,
    )[1].split("proc rfPriPopulateWb03TxcalRf70ReplayFields()", 1)[0]
    for expected in [
        'exportc: "nim_wifi_rf_rf70_txcal_search_best_nibble"',
        'exportc: "nim_wifi_rf_rf70_txcal_search_runner_nibble"',
        'exportc: "nim_wifi_rf_rf70_txcal_search_best_sample"',
        'exportc: "nim_wifi_rf_rf70_txcal_search_runner_sample"',
        "var bestNibble = 5'u32",
        "var runnerUpNibble = 5'u32",
        "var bestSample = low(int32)",
        "var runnerUpSample = low(int32)",
        "if sample.value > bestSample:",
        "runnerUpSample = bestSample",
        "runnerUpNibble = bestNibble",
        "elif sample.value > runnerUpSample:",
        "let adjacent =",
        "min(bestNibble, runnerUpNibble)",
        "bestNibble",
        "rfPriRecordRf70SearchWindow(\n      window, ok, bestNibble, runnerUpNibble, bestSample, runnerUpSample,",
    ]:
        assert expected in wifi_fw if expected.startswith("exportc") else expected in rf70_search_body
    assert "bl808WifiRfWb03ApplyMeasuredRf70Replay* {.booldefine.}: bool = false" in wifi_fw
    for expected in [
        "if bl808WifiRfWb03ApplyMeasuredRf70Replay:",
        "rfPriStoreRf70ReplayWindowNibbles(\n          window0.nibble, window1.nibble, window2.nibble)",
        "return true",
        "return false",
    ]:
        assert expected in rf70_search_commit_body
    for expected in [
        "Run the recovered strongest-candidate search for UART/JTAG visibility.",
        "Applying those measured replay windows is default-off",
        "RfPriRf70ReplayFieldsMeasuredFallback",
    ]:
        assert expected in rf70_populate_body
    for expected in [
        "RfCalibRf70ReplayLowBandWordIndex",
        "RfCalibRf70ReplayHighBandWordIndex",
        "RfCalibLoVcoHalfwordBase",
        "RfCalibTxcalRecordBaseWord",
        "proc rfCalibRf70ReplayLowBandWord()",
        "proc rfCalibRf70ReplayHighBandWord()",
        "let lowBandReplayWord = rfCalibRf70ReplayLowBandWord()",
        "let highBandReplayWord = rfCalibRf70ReplayHighBandWord()",
        "let lowBandReplayWordBefore = rfCalibRf70ReplayLowBandWord()",
        "let highBandReplayWordBefore = rfCalibRf70ReplayHighBandWord()",
    ]:
        assert expected in wifi_fw
    for vague_calib_access in [
        "rfCalibWord(3)",
        "rfCalibWord(4)",
        "rfCalibSetWord(3",
        "rfCalibSetWord(4",
        "RfPriTxcalRecordBaseWord",
        "rfCalibHalf(14 +",
        "let word3",
        "let word4",
        "let w8",
    ]:
        assert vague_calib_access not in wifi_fw
    for forbidden in [
        "BelowThreshold",
        "AboveThreshold",
        "rf70ReplaySearchBelow",
        "rf70ReplaySearchAbove",
        "sample.value <= -2048'i32",
        "not adjacent",
        "strongest sample below",
        "threshold/bracket",
    ]:
        assert forbidden not in rf70_search_body
    wait_fcal_ready_body = wifi_fw.split(
        "proc waitRfFcalReady(): bool =",
        1,
    )[1].split("proc sampleRfFcalCount()", 1)[0]
    sample_fcal_body = wifi_fw.split(
        "proc sampleRfFcalCount(): uint16 =",
        1,
    )[1].split("proc writeRfFcalCode", 1)[0]
    write_fcal_body = wifi_fw.split(
        "proc writeRfFcalCode(code: uint16) =",
        1,
    )[1].split("proc writeRfAcalCode", 1)[0]
    write_acal_body = wifi_fw.split(
        "proc writeRfAcalCode(code: uint16) =",
        1,
    )[1].split("proc vendorLikeRfAcalForFcal", 1)[0]
    prepare_lo_fcal_body = wifi_fw.split(
        "proc prepareRfPriLoFcal() =",
        1,
    )[1].split("proc chooseRfBaseFcalCode()", 1)[0]
    choose_lo_fcal_body = wifi_fw.split(
        "proc chooseRfBaseFcalCode(): uint16 =",
        1,
    )[1].split("proc runRfPriLoFcal()", 1)[0]
    run_lo_fcal_body = wifi_fw.split(
        "proc runRfPriLoFcal() =",
        1,
    )[1].split("proc prepareRfPriLoAcal()", 1)[0]
    prepare_lo_acal_body = wifi_fw.split(
        "proc prepareRfPriLoAcal() =",
        1,
    )[1].split("proc runRfPriLoAcal()", 1)[0]
    run_lo_acal_body = wifi_fw.split(
        "proc runRfPriLoAcal() =",
        1,
    )[1].split("proc saveRfPriCalState()", 1)[0]
    config_channel_cal_body = wifi_fw.split(
        "proc rfPriConfigChannelForCal(index: int) =",
        1,
    )[1].split("proc startRfPriTxDfeForCal()", 1)[0]
    start_tx_dfe_body = wifi_fw.split(
        "proc startRfPriTxDfeForCal() =",
        1,
    )[1].split("proc startRfPriRxDfeForCal()", 1)[0]
    start_rx_dfe_body = wifi_fw.split(
        "proc startRfPriRxDfeForCal() =",
        1,
    )[1].split("proc signedRfPowerMeasurement", 1)[0]
    prepare_txcal_body = wifi_fw.split(
        "proc prepareRfPriTxcal() =",
        1,
    )[1].split("proc prepareRfPriBzTxcal()", 1)[0]
    prepare_bz_txcal_body = wifi_fw.split(
        "proc prepareRfPriBzTxcal() =",
        1,
    )[1].split("proc runRfPriTxcal()", 1)[0]
    run_txcal_body = wifi_fw.split(
        "proc runRfPriTxcal() =",
        1,
    )[1].split("proc runRfPriBzTxcal()", 1)[0]
    run_bz_txcal_body = wifi_fw.split(
        "proc runRfPriBzTxcal() =",
        1,
    )[1].split("proc waitRfRxcalMeasurementReady()", 1)[0]
    bz_txcal_snapshot_body = wifi_fw.split(
        "proc rfPriSnapshotBzTxcalState(tag: uint32) =",
        1,
    )[1].split("proc rfCalibRf70ReplayLowBandWord()", 1)[0]
    store_txcal_record_body = wifi_fw.split(
        "proc storeRfTxcalRecord(index: int;",
        1,
    )[1].split("proc storeRfPriBzTxcalRecord", 1)[0]
    store_bz_txcal_record_body = wifi_fw.split(
        "proc storeRfPriBzTxcalRecord(index: int;",
        1,
    )[1].split("proc configureRfPriTxcalGain", 1)[0]
    apply_txcal_record_body = wifi_fw.split(
        "proc rfPriApplyTxcalRecordToTable(txPowerTableWords: var array[43, uint32],",
        1,
    )[1].split("proc rfPriApplyBzTxcalRecordToTable", 1)[0]
    apply_bz_txcal_record_body = wifi_fw.split(
        "proc rfPriApplyBzTxcalRecordToTable(txPowerTableWords: var array[43, uint32],",
        1,
    )[1].split("proc rfPriSeedBzTxcalFallbackRecords", 1)[0]
    seed_bz_txcal_body = wifi_fw.split(
        "proc rfPriSeedBzTxcalFallbackRecords() =",
        1,
    )[1].split("proc rfPriWriteTxPowerTable()", 1)[0]
    write_tx_power_table_body = wifi_fw.split(
        "proc rfPriWriteTxPowerTable() =",
        1,
    )[1].split("proc writeRfPriGainInit()", 1)[0]
    prepare_roscal_body = wifi_fw.split(
        "proc prepareRfPriRoscal() =",
        1,
    )[1].split("proc runRfPriRoscal()", 1)[0]
    apply_roscal_body = wifi_fw.split(
        "proc applyRfRoscalCodes(iCode, qCode: uint32) =",
        1,
    )[1].split("proc prepareRfPriRoscal()", 1)[0]
    run_roscal_body = wifi_fw.split(
        "proc runRfPriRoscal() =",
        1,
    )[1].split("proc waitRfRccalMeasurementReady()", 1)[0]
    wait_roscal_measure_body = wifi_fw.split(
        "proc waitRfRoscalMeasurementReady(): bool =",
        1,
    )[1].split("proc writeRfRoscalCandidate", 1)[0]
    write_roscal_candidate_body = wifi_fw.split(
        "proc writeRfRoscalCandidate(iBranch: bool, code: uint32) =",
        1,
    )[1].split("type\n    RfRoscalSample", 1)[0]
    sample_roscal_measure_body = wifi_fw.split(
        "proc sampleRfRoscalMeasurement(iBranch: bool): RfRoscalSample =",
        1,
    )[1].split("proc logRfRoscalSearch", 1)[0]
    prepare_rccal_body = wifi_fw.split(
        "proc prepareRfPriRccal() =",
        1,
    )[1].split("proc prepareRfPriRccalTone()", 1)[0]
    wait_rccal_measure_body = wifi_fw.split(
        "proc waitRfRccalMeasurementReady(): bool =",
        1,
    )[1].split("proc sampleRfRccalPower", 1)[0]
    prepare_rccal_tone_body = wifi_fw.split(
        "proc prepareRfPriRccalTone() =",
        1,
    )[1].split("proc logRfRccalSearch", 1)[0]
    sample_rccal_power_body = wifi_fw.split(
        "proc sampleRfRccalPower(): uint32 =",
        1,
    )[1].split("proc primeRfRccalPowerMeasurement()", 1)[0]
    prime_rccal_measure_body = wifi_fw.split(
        "proc primeRfRccalPowerMeasurement() =",
        1,
    )[1].split("proc writeRfRccalCode", 1)[0]
    write_rccal_body = wifi_fw.split(
        "proc writeRfRccalCode(code: uint32) =",
        1,
    )[1].split("proc writeRfRccalSearchCode", 1)[0]
    write_rccal_search_body = wifi_fw.split(
        "proc writeRfRccalSearchCode(code: uint32) =",
        1,
    )[1].split("proc prepareRfPriRccal()", 1)[0]
    run_rccal_body = wifi_fw.split(
        "proc runRfPriRccal() =",
        1,
    )[1].split("proc clampRfTxcalParam", 1)[0]
    txcal_singen_amp_body = wifi_fw.split(
        "proc writeRfTxcalSingenAmplitude(amp: uint32) =",
        1,
    )[1].split("proc sampleRfTxcalAverage", 1)[0]
    txcal_param_body = wifi_fw.split(
        "proc writeRfTxcalParam(paramInd: uint32, value: int32) =",
        1,
    )[1].split("proc waitRfTxcalMeasurementReady", 1)[0]
    txcal_average_body = wifi_fw.split(
        "proc sampleRfTxcalAverage(): tuple[ok: bool, value: int32] =",
        1,
    )[1].split("proc sampleRfTxcalAdcMean", 1)[0]
    txcal_adc_mean_body = wifi_fw.split(
        "proc sampleRfTxcalAdcMean(): tuple[ok: bool, value: int32] =",
        1,
    )[1].split("proc tuneRfTxcalSingenPower", 1)[0]
    txcal_search_stage_body = wifi_fw.split(
        "proc prepareRfTxcalSearchStage() =",
        1,
    )[1].split("proc sampleRfTxcalPower", 1)[0]
    txcal_gain_body = wifi_fw.split(
        "proc configureRfPriTxcalGain(setup: array[9, uint16],",
        1,
    )[1].split("proc configureRfPriTxcalGain(index: int", 1)[0]
    txcal_power_body = wifi_fw.split(
        "proc sampleRfTxcalPower(measFreq: uint32):",
        1,
    )[1].split("proc measureRfTxcalCandidate", 1)[0]
    wait_txcal_measure_body = wifi_fw.split(
        "proc waitRfTxcalMeasurementReady(): bool =",
        1,
    )[1].split("proc clampRfTxcalAmp", 1)[0]
    wait_rxcal_measure_body = wifi_fw.split(
        "proc waitRfRxcalMeasurementReady(): bool =",
        1,
    )[1].split("proc clampRfRxcalParam", 1)[0]
    rxcal_param_body = wifi_fw.split(
        "proc writeRfRxcalParam(paramInd: uint32, value: int32) =",
        1,
    )[1].split("proc sampleRfRxcalPower", 1)[0]
    rxcal_power_body = wifi_fw.split(
        "proc sampleRfRxcalPower(): tuple[ok: bool, power: uint32] =",
        1,
    )[1].split("proc measureRfRxcalCandidate", 1)[0]
    store_rxcal_record_body = wifi_fw.split(
        "proc storeRfRxcalRecord(index: int, p2, p3: int32, power: uint32) =",
        1,
    )[1].split("proc rfPriReplayRxcalRegs()", 1)[0]
    prepare_rxcal_body = wifi_fw.split(
        "proc prepareRfPriRxcal() =",
        1,
    )[1].split("proc runRfPriRxcal()", 1)[0]
    run_rxcal_body = wifi_fw.split(
        "proc runRfPriRxcal() =",
        1,
    )[1].split("proc rfPriApplyTxcalRecordToTable", 1)[0]
    efuse_init_body = wifi_fw.split(
        "proc rfPriEfuseInit() =",
        1,
    )[1].split("proc runRfPriFullCalRestoreBaseline", 1)[0]
    efuse_xtal_cap_body = wifi_fw.split(
        "proc rfPriApplyEfuseXtalCapTrim(cfg: ptr WlRfConfig;",
        1,
    )[1].split("proc rfPriApplyEfuseTxGainTrim", 1)[0]
    efuse_tx_gain_body = wifi_fw.split(
        "proc rfPriApplyEfuseTxGainTrim(cfg: ptr WlRfConfig) =",
        1,
    )[1].split("proc rfPriApplyEfuseDfeTrim", 1)[0]
    efuse_dfe_trim_body = wifi_fw.split(
        "proc rfPriApplyEfuseDfeTrim(cfg: ptr WlRfConfig) =",
        1,
    )[1].split("proc rfPriEfuseInit", 1)[0]
    rf_pri_init_body = wifi_fw.split(
        "proc rf_pri_init(coldInit, mode: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_txcal", 1)[0]
    wifi_pll_config_body = wifi_fw.split(
        "proc rfPriWifiPllConfig() =",
        1,
    )[1].split("proc rfPriEfuseInit", 1)[0]
    wb03_optimize_pll_body = wifi_fw.split(
        "proc rfPriApplyWb03Non40OptimizePll(channelMhz: uint32) =",
        1,
    )[1].split("proc rf_pri_optimize", 1)[0]

    for expected in [
        "RfCalibBzTxcalRecordBaseByte",
        "RfCalibBzTxcalRecordStrideBytes",
        "proc rfCalibBzTxcalRecordByteOffset(record: int)",
        "proc rfCalibBzTxcalRecordWord0(record: int)",
        "proc rfCalibBzTxcalRecordWord1(record: int)",
        "proc rfCalibStoreBzTxcalRecordWords(record: int; word0, word1: uint32)",
        "rfCalibBzTxcalRecordWord0(record)",
        "rfCalibBzTxcalRecordWord1(record)",
    ]:
        assert expected in wifi_fw
    for expected in [
        "param0, param1, param2, param3: int32",
        "packRfTxcalCalWord0(param0, param1, param2)",
        "packRfTxcalCalWord1(param3)",
        "txcalRecordWord0",
        "txcalRecordWord1",
        "bzTxcalRecordWord0",
        "bzTxcalRecordWord1",
    ]:
        assert expected in store_txcal_record_body + store_bz_txcal_record_body
    for expected in [
        "Vendor rf_pri_txcal_w2reg always writes these fields",
        "preserves base-table words for empty records until TXCAL is bit-for-bit",
        "let txcalParam0 = txcalRecordWord0 and 0x3F'u32",
        "let txcalParam1 = (txcalRecordWord0 shr 8) and 0x3F'u32",
        "let txcalParam2 = (txcalRecordWord0 shr 16) and 0x7FF'u32",
        "let txcalParam3 = txcalRecordWord1 and 0x3FF'u32",
        "if txcalRecordWord0 == 0'u32 and txcalRecordWord1 == 0'u32:",
        "txPowerTableWords[tableIndex]",
    ]:
        assert expected in apply_txcal_record_body
    for expected in [
        "Vendor rf_pri_bz_txcal_w2reg always writes these fields",
        "preserves base-table words for empty records until BZ TXCAL is validated",
        "let bzTxcalRecordWord0 = rfCalibBzTxcalRecordWord0(record)",
        "let bzTxcalRecordWord1 = rfCalibBzTxcalRecordWord1(record)",
        "let txcalParam0 = bzTxcalRecordWord0 and 0x3F'u32",
        "let txcalParam1 = (bzTxcalRecordWord0 shr 8) and 0x3F'u32",
        "let txcalParam2 = (bzTxcalRecordWord0 shr 16) and 0x07FF'u32",
        "let txcalParam3 = bzTxcalRecordWord1 and 0x03FF'u32",
        "if (txcalParam0 or txcalParam1 or txcalParam2 or txcalParam3) == 0'u32:",
        "txPowerTableWords[start]",
    ]:
        assert expected in apply_bz_txcal_record_body
    for expected in [
        "let bzTxcalRecordWord0 = rfCalibBzTxcalRecordWord0(record)",
        "let bzTxcalRecordWord1 = rfCalibBzTxcalRecordWord1(record)",
        "rfCalibStoreBzTxcalRecordWords(",
        "packRfTxcalCalWord0(0x20'i32, 0x20'i32, 0x400'i32)",
    ]:
        assert expected in seed_bz_txcal_body
    for expected in [
        "let wb03Xtal40 = rfPriIsWb03() and",
        "bl808RfXtalIndex == xtalIndex(WlXtal40M)",
        "if wb03Xtal40:",
        "RfPriWb03TxPowerRegisterBaseline",
        "RfPriTxPowerRegisterBase",
        "if rfCalibDataGlobal != nil and not wb03Xtal40:",
        "var txPowerTableWords =",
        "rfPriApplyTxcalRecordToTable(\n          txPowerTableWords, 3 + slot * 2, record)",
        "rfPriApplyBzTxcalRecordToTable(txPowerTableWords,",
        "writeRfTxPowerCompTable(txPowerTableWords)",
    ]:
        assert expected in write_tx_power_table_body
    for body in [
        bz_txcal_snapshot_body,
        store_bz_txcal_record_body,
        apply_bz_txcal_record_body,
        seed_bz_txcal_body,
    ]:
        for vague_bz_access in [
            "0xF8 +",
            "record * 8",
            "let offset =",
            "let p0",
            "let p1",
            "let p2",
            "let p3",
            "p0=0x20",
        ]:
            assert vague_bz_access not in body
    for expected in [
        "let txcalParam0Coarse =",
        "let txcalParam1Coarse =",
        "let txcalParam0Refined =",
        "let txcalParam1Refined =",
        "let txcalParam2Coarse =",
        "let txcalParam3Coarse =",
        "let txcalParam2Refined =",
        "let txcalParam3Refined =",
    ]:
        assert expected in run_txcal_body
        assert expected in run_bz_txcal_body
    for expected in [
        "RfPriTxcalRf70InitialSearchSeedNibble = 0xB'u32",
        "rf_pri_txcal+0x148..0x158 seeds RF70",
        "addr rf.txcalParam70",
        "RfPriTxcalRf70InitialSearchSeedNibble",
    ]:
        assert expected in wifi_fw if expected.startswith("RfPri") else expected in prepare_txcal_body
    assert prepare_txcal_body.index(
        "RfPriTxcalRf70InitialSearchSeedNibble"
    ) < prepare_txcal_body.index("preRf70TxcalParamReg = volatileLoad(addr rf.txcalParam70)")
    for expected in [
        "Vendor rf_pri_txcal+0x54c..0x6a0 prepares the post-RF70 TXCAL search",
        "one-shot RF64/RF58/RF21c/RF220 staging sequence",
        "updateReg32(addr rf.calSingenCtrl20c, 0xFC00_FFFF'u32, 0x0049_0000'u32)",
        "updateReg32(addr rf.calSingenAmpLo214, 0x003F_FFFF'u32, 0'u32)",
        "updateReg32(addr rf.calSingenAmpHi218, 0x003F_FFFF'u32, 0xC000_0000'u32)",
        "updateReg32(addr rf.rxcalPrep60, not 0x0000_0003'u32, 0x0000_0003'u32)",
        "updateReg32(addr rf.txcalGain64, 0x0FC3_FFFF'u32, 0x9030_0000'u32)",
        "updateReg32(addr rf.txcalBias58, 0xFFF8_FFFF'u32, 0x0004_0000'u32)",
        "updateReg32(addr rf.rccalTone48, 0xCE0F_FFFF'u32, 0x0077_0000'u32)",
        "updateReg32(addr rf.calPathConfig8c, not 0x0000_0030'u32, 0x0000_0010'u32)",
        "updateReg32(addr rf.txcalGain64, 0xF8FF_FFFF'u32, 0x0400_0000'u32)",
        "updateReg32(addr rf.txcalGain64, 0xFF83_FFFF'u32, 0xF040_0000'u32)",
        "updateReg32(addr rf.priModeCtrl30, 0xFFFE_FFFF'u32, 0'u32)",
        "updateReg32(addr rf.txcalBias58, 0xFFF8_FFFF'u32, 0x0001_0000'u32)",
        "updateReg32(addr rf.calSingenMeasurePrep21c, 0xEFFF_EFFF'u32, 0'u32)",
        "updateReg32(addr rf.calSingenAmpLo214, not 0x0000_07FF'u32, 0x0000_0010'u32)",
        "updateReg32(addr rf.calSingenAmpHi218, not 0x0000_07FF'u32, 0x0000_0010'u32)",
        "updateReg32(addr rf.calDfeGate23c, not 0x0004_0000'u32, 0x0004_0000'u32)",
        "updateReg32(addr rf.rxMode220, not 0x0000_0180'u32, 0'u32)",
        "updateReg32(addr rf.rxMode220, 0xFFFF_E7FF'u32, 0x0000_1082'u32)",
        "updateReg32(addr rf.rxMode220, not 0x0000_0010'u32, 0x0000_0100'u32)",
        "updateReg32(addr rf.calSingenCtrl20c, not 0x8000_0000'u32, 0'u32)",
        "updateReg32(addr rf.calSingenCtrl20c, not 0x8000_0000'u32, 0x8000_0000'u32)",
        "waitRfUs(10'u32)",
    ]:
        assert expected in txcal_search_stage_body
    assert "0x003D_0000'u32" not in txcal_search_stage_body
    for expected in [
        "let rxcalParam2Coarse =",
        "let rxcalParam3Coarse =",
        "let rxcalParam2Refined =",
        "let rxcalParam3Refined =",
    ]:
        assert expected in run_rxcal_body
    for body in [run_txcal_body, run_bz_txcal_body, run_rxcal_body]:
        for vague_search_result in [
            "let p0a",
            "let p1a",
            "let p2a",
            "let p3a",
            "let p0b",
            "let p1b",
            "let p2b",
            "let p3b",
            "p0b.value",
            "p1b.value",
            "p2b.value",
            "p3b.value",
        ]:
            assert vague_search_result not in body

    assert "Port of librf_bl808.a:rf_pri.c.o rf_pri_fixed_val_regs" in fixed_body
    assert "writeRfPriFixedCommonPreBranch()" in fixed_body
    assert "writeRfPriFixedCommonPostBranch()" in fixed_body
    assert "writeRfPriFixedPowerCompTailDefaults()" in fixed_body
    assert "RfPriFixedValPrefixInit:" not in wifi_fw
    assert "RfPriFixedValSuffixInit:" not in wifi_fw
    assert "writeRadioRegMaskInit(RfPriFixedValSuffixInit)" not in wifi_fw
    assert "RfPriStaticInit:" not in wifi_fw
    assert "writeRadioRegMaskInit(RfPriStaticInit)" not in wifi_fw
    assert "if rfPriIsWb03():" in fixed_body
    assert "0xFFFFFFE0'u32, 0x00000015'u32" in fixed_body
    assert "0xDFFFFFFF'u32, 0x00000000'u32" in fixed_body
    assert "0xFFFFFFE0'u32, 0x0000001B'u32" in fixed_body
    assert "0xFFFFFFFF'u32, 0x20000000'u32" in fixed_body
    assert fixed_body.index("0x00000015'u32") < fixed_body.index("0x0000001B'u32")
    assert "let rf = rfRegs()" in fixed_body
    assert "let dfe = rfDfeInitRegs()" in fixed_body
    assert "addr dfe.dfeRfFixedCtrl814" in fixed_body
    assert "addr rf.acalCtrlA4" in fixed_body
    assert "volatileLoad(addr dfe.dfeRfFixedCtrl814)" in fixed_body
    assert "volatileLoad(addr rf.acalCtrlA4)" in fixed_body
    assert "cast[ptr uint32](RfAcalCtrlReg.uint)" not in fixed_body
    assert "readReg32(RfAcalCtrlReg)" not in fixed_body
    assert "cast[ptr uint32](RfPriInitF814Reg.uint)" not in fixed_body
    assert "readReg32(RfPriInitF814Reg)" not in fixed_body
    fixed_prefix_body = wifi_fw.split(
        "proc writeRfPriFixedCommonPreBranch() =", 1
    )[1].split(
        "proc writeRfPriFixedCommonPostBranch() =", 1
    )[0]
    for expected in [
        "let rf = rfRegs()",
        "let pll = rfPllRegs()",
        "let dfe = rfDfeInitRegs()",
        "addr rf.calSingenMeasurePrep21c",
        "addr rf.bandwidthCtrl94",
        "addr rf.rxMode220",
        "addr rf.scanSynthControl608",
        "addr rf.synthDfePathControl63c",
        "addr rf.calPathCtrl90",
        "addr rf.measureCtrl618",
        "addr rf.modemPathEnable504",
        "addr dfe.dfeRfFixedDefault884",
        "addr dfe.dfeRfFixedCtrl814",
        "addr pll.pllFixedDefault84",
        "addr rf.rxModeCalibrationGate78",
        "addr pll.refdivCtrl14",
    ]:
        assert expected in fixed_prefix_body
    for forbidden in [
        "0x2000121C'u32",
        "0x20001094'u32",
        "0x20001608'u32",
        "RfRxModeReg",
        "RfPriInit163cReg",
        "RfPriInit90Reg",
        "RfPriInit1618Reg",
        "RfPriInit1504Reg",
        "RfPriInitF884Reg",
        "RfPriInitF814Reg",
        "RfPriInit884Reg",
        "RfPriInit78Reg",
        "RfPriInit814Reg",
    ]:
        assert forbidden not in fixed_prefix_body
    fixed_suffix_body = wifi_fw.split(
        "proc writeRfPriFixedCommonPostBranch() =", 1
    )[1].split(
        "proc writeRfPriFixedPowerCompTailDefaults() =", 1
    )[0]
    for expected in [
        "let rf = rfRegs()",
        "let dfe = rfDfeInitRegs()",
        "addr dfe.hbnCtrl30",
        "addr rf.priModeCtrl30",
        "addr dfe.dfeRfFixedDefault884",
        "addr rf.channelCalStrobeB0",
        "addr rf.rfPriBiasTrimCc",
        "addr rf.acalCtrlA4",
        "addr rf.txcalCtrlB8",
        "addr rf.calModeDefault138",
        "addr rf.channelCalStatusB4",
        "addr rf.calCtrl1c",
        "addr rf.baseCtrl1",
        "addr rf.rfCodeConfig110c",
        "addr rf.roscalCtrl7c",
        "addr rf.txcalDfe88",
        "addr rf.txcalParam70",
        "addr rf.txcalGain68",
        "addr rf.rfBiasTrimD4",
    ]:
        assert expected in fixed_suffix_body
    for forbidden in [
        "RfPriInitHbnReg",
        "RfPriModeCtrlReg",
        "RfPriInitF884Reg",
        "RfPriConfigB0Reg",
        "0x200010CC'u32",
        "RfAcalCtrlReg",
        "RfTxcalCtrlReg",
        "RfPriInit138Reg",
        "RfPriConfigB4Reg",
        "RfCalCtrlReg",
        "RfCtrlReg",
        "RfPriInit110cReg",
        "RfRoscalCtrlReg",
        "RfPriTxcalDfeReg",
        "RfTxcalParamReg",
        "RfPriInit68Reg",
        "RfPriInitD4Reg",
    ]:
        assert forbidden not in fixed_suffix_body
    fixed_tail_body = wifi_fw.split(
        "proc writeRfPriFixedPowerCompTailDefaults() =", 1
    )[1].split(
        "proc writeRfPriStaticInit() =", 1
    )[0]
    for expected in [
        "let rf = rfRegs()",
        "addr rf.txPowerCompTail7bc",
        "addr rf.txPowerCompTail7c0",
        "addr rf.txPowerCompTail7c4",
        "addr rf.txPowerCompTail7c8",
        "addr rf.txPowerCompTail7cc",
        "addr rf.txPowerCompTail7d0",
        "addr rf.txPowerCompTail7d4",
        "addr rf.txPowerCompTail7d8",
    ]:
        assert expected in fixed_tail_body
    for forbidden in [
        "0x200017BC'u32",
        "0x200017C0'u32",
        "0x200017C4'u32",
        "0x200017C8'u32",
        "0x200017CC'u32",
        "0x200017D0'u32",
        "0x200017D4'u32",
        "0x200017D8'u32",
    ]:
        assert forbidden not in wifi_fw
    static_init_body = wifi_fw.split("proc writeRfPriStaticInit() =", 1)[1].split(
        "proc writeRfPriFixedValueRegs() =", 1
    )[0]
    for expected in [
        "let rf = rfRegs()",
        "let pll = rfPllRegs()",
        "let dfe = rfDfeInitRegs()",
        "addr pll.enableCtrl30",
        "addr rf.rxMode220",
        "addr dfe.dfeStaticCtrl820",
        "addr dfe.hbnCtrl30",
        "addr rf.priModeCtrl30",
        "addr dfe.dfeRfFixedDefault884",
        "addr rf.rfPriBiasTrimCc",
        "addr rf.synthDfePathControl63c",
        "addr rf.txcalGain64",
        "addr rf.txcalDefaultProfile128",
        "addr rf.txcalDefaultProfile12c",
        "addr rf.txcalDefaultProfile130",
        "addr rf.rfBiasTrimD4",
        "addr rf.calPathCtrl90",
        "addr rf.txcalCtrlB8",
        "addr rf.calModeDefault138",
        "addr rf.calPathConfig8c",
        "addr rf.measureCtrl618",
    ]:
        assert expected in static_init_body
    for forbidden in [
        "RfPriInitPllReg",
        "RfRxModeReg",
        "RfPriInitDfeReg",
        "RfPriInitHbnReg",
        "RfPriModeCtrlReg",
        "RfPriInitF884Reg",
        "0x200010CC'u32",
        "RfPriInit163cReg",
        "RfPriInit64Reg",
        "RfPriInit128Reg",
        "RfPriInit12cReg",
        "RfPriInit130Reg",
        "RfPriInitD4Reg",
        "RfPriInit90Reg",
        "RfTxcalCtrlReg",
        "RfPriInit138Reg",
        "RfPriInit8cReg",
        "RfPriInit1618Reg",
    ]:
        assert forbidden not in static_init_body

    assert "cast[ptr uint32](RfPriInitDfeReg824.uint)" not in efuse_init_body
    for expected in [
        "proc rfPriEfuseXtalCapPairValid(cfg: ptr WlRfConfig): bool",
        "proc rfPriApplyEfuseXtalCapTrim(cfg: ptr WlRfConfig;",
        "let efuseXtalCapCode0 = cfg.efuseXtalCapCode0",
        "let efuseXtalCapCode1 = cfg.efuseXtalCapCode1",
        "rfPriEfuseXtalCapPairValid(cfg)",
        "addr rf.xtalCapTrim5c",
    ]:
        assert expected in wifi_fw if expected.startswith("proc ") else expected in efuse_xtal_cap_body
    for expected in [
        "let efuseTxGainByte = cfg.efuseTxGainComp",
        "bl808RfTxGainComp",
        "bl808RfTempPowerComp = rfSignedByte(cfg.temperaturePowerComp)",
    ]:
        assert expected in efuse_tx_gain_body
    for expected in [
        "let efuseDfeTrimNibble = cfg.efuseDfeTrim",
        "let dfe = rfDfeInitRegs()",
        "addr dfe.dfeTrim824",
    ]:
        assert expected in efuse_dfe_trim_body
    for expected in [
        "rfPriApplyEfuseXtalCapTrim(cfg, txCorrRegHigh, txCorrRegLow)",
        "rfPriApplyEfuseTxGainTrim(cfg)",
        "rfPriApplyEfuseDfeTrim(cfg)",
        "addr rf.txPowerComp704",
        "addr rf.txPowerComp7ac",
    ]:
        assert expected in efuse_init_body
    for vague_name in [
        "let cap0",
        "let cap1",
        "let pwrByte",
        "let dfeTrim",
        "Remaining unknown:",
    ]:
        assert vague_name not in efuse_init_body
    for expected in [
        "addr rfDfeInitRegs().dfeTrim824",
        "addr rf.calPathCtrl90",
        "addr rf.rxMode220",
        "addr rf.synthCtrl2c",
        "addr rf.synthDfePathControl63c",
        "writeRfPriStaticInit()",
        "writeRfPriGainInit()",
    ]:
        assert expected in rf_pri_init_body
    for expected in [
        "librf_bl808.a:rf_pri.c.o rf_pri_full_cal+0x36..0x5e",
        "librf_bl808.a:rf_pri.c.o rf_pri_txcal+0x316..0x52a",
        "librf_bl808.a:rf_pri.c.o rf_pri_restore_cal_reg+0x10c..0x1a8",
        "runRfPriRoscal",
        "runRfPriRccal",
        "preserve those RF[0x20] gates",
        "Callback-driven",
        "applying measured windows is default-off",
        "RF70/RFA0/RFB4 remain",
        "rf_pri_fixed_val_regs' WB03 branch",
        "JTAG/UART traces show RF88/RFD0",
    ]:
        assert expected in rf_pri_init_body
    for forbidden in [
        "cast[ptr uint32](RfPriInitDfeReg824.uint)",
        "cast[ptr uint32](RfPriInit90Reg.uint)",
        "cast[ptr uint32](RfRxModeReg.uint)",
        "cast[ptr uint32](RfSynthCtrlReg.uint)",
        "cast[ptr uint32](RfPriInit163cReg.uint)",
    ]:
        assert forbidden not in rf_pri_init_body

    for expected in [
            "doAssert offsetof(RfRegBlock, optimizeCtrlD0) == 0xD0",
        "proc nim_wifi_rf_stage_breakpoint*(tag: uint32)",
        "{.exportc, cdecl, noinline.}",
        "proc nim_wifi_rf_fixed_val_breakpoint*()",
        "proc nim_wifi_rf_pri_init_entry_breakpoint*()",
        "nim_wifi_rf_fixed_val_breakpoint()",
        "nim_wifi_rf_pri_init_entry_breakpoint()",
        "nimFwDbgRfPhyTraceRf70[idx]",
        "nimFwDbgRfPhyTraceRf88[idx]",
        "nimFwDbgRfPhyTraceRfd0[idx]",
        "nimFwDbgRfPhyTraceDevice[idx]",
        'exportc: "nimfw_dbg_rf_phy_trace_device"',
        "nim_wifi_rf_stage_rfd0_log",
        "nim_wifi_rf_optimize_channel_log",
        "nim_wifi_rf_optimize_device_log",
        "nim_wifi_rf_optimize_rfd0_log",
        "nim_wifi_rf_optimize_rf70_log",
        "nim_wifi_rf_optimize_nibble_log",
        "proc rfPriApplyWb03Non40OptimizePll(channelMhz: uint32)",
        "rf_pri_optimize+0x82..0x14e",
        "RfOptimizeWb03PllEdge0Mhz = 2452'u32",
        "RfOptimizeWb03PllEdge1Mhz = 2472'u32",
        "bl808WifiRfWb03ForceAuthTxLatches* {.booldefine.}: bool = true",
        "bl808WifiRfWb03AuthTxPulseLatch* {.booldefine.}: bool = true",
        "rfPriApplyWb03AuthTxLatches()",
      ]:
        assert expected in wifi_fw

    for body in [wifi_pll_config_body, wb03_optimize_pll_body]:
        assert "let pll = rfPllRegs()" in body
        assert "RfPriInitPll18Reg" not in body
        assert "RfPriInitPll1cReg" not in body
        assert "RfPriInitPll28Reg" not in body
        assert "RfPriInitPll2cReg" not in body
    for expected in [
        "addr pll.refdivCtrl14",
        "addr pll.fractionalWord28",
        "addr pll.modeCtrl2c",
        "addr pll.loopFilter18",
        "addr pll.fractionalCtrl1c",
        "addr pll.pllReset10",
        "addr pll.enableCtrl30",
    ]:
        assert expected in wifi_pll_config_body
    for expected in [
        "addr pll.loopFilter18",
        "addr pll.fractionalCtrl1c",
        "0x00000040'u32",
        "0x0005A000'u32",
    ]:
        assert expected in wb03_optimize_pll_body

    for expected in [
        "let rf = rfRegs()",
        "addr rf.txcalDfe88",
        "addr rf.acalCtrlA4",
    ]:
        assert expected in wb03_runtime_latches_body
    assert "cast[ptr uint32](RfPriTxcalDfeReg.uint)" not in wb03_runtime_latches_body
    assert "cast[ptr uint32](RfAcalCtrlReg.uint)" not in wb03_runtime_latches_body

    for expected in [
        "let rf = rfRegs()",
        "addr rf.txcalTosdac600",
        "RfPriWb03RxcalTosdacReplayMask",
    ]:
        assert expected in wb03_rxcal_tosdac_latch_body
    for forbidden in [
        "rfRegWrite(RfTxcalTosdacReg",
        "rfRegRead(RfTxcalTosdacReg",
    ]:
        assert forbidden not in wb03_rxcal_tosdac_latch_body

    for body in [
        wb03_scan_latches_body,
        wb03_rfc_entry_body,
        wb03_scan_baseline_body,
    ]:
        assert "addr rf.scanSynthControl608" in body
        assert "addr rf.txcalTosdac600" in body
        assert "addr rf.measureCtrl618" in body
        assert "addr rf.calPathConfig8c" in body
        assert "0x20001608'u32" not in body
        assert "rfRegWrite(RfTxcalTosdacReg" not in body
        assert "rfRegWrite(RfMeasureCtrlReg" not in body
        assert "rfRegWrite(RfPriInit8cReg" not in body
        assert "addr rf.channelFcalConfigBc" in body
        assert "rfRegWrite(RfPriConfigBcReg" not in body
    for body in [wb03_scan_latches_body, wb03_scan_baseline_body]:
        assert "addr rf.txcalDfe88" in body
        assert "addr rf.channelCalStatusB4" in body
        assert "rfRegWrite(RfPriTxcalDfeReg" not in body
        assert "rfRegWrite(RfPriConfigB4Reg" not in body
    assert "addr rf.fcalCtrlA0" in wb03_scan_latches_body
    assert "addr rf.calMode14" in wb03_scan_latches_body
    assert "addr rf.calCtrl1c" in wb03_scan_latches_body
    assert "rfRegWrite(RfFcalCtrlReg" not in wb03_scan_latches_body
    assert "RfCalModeReg" not in wb03_scan_latches_body
    assert "RfCalCtrlReg" not in wb03_scan_latches_body
    for body in [
        rf70_search_body,
        rf70_replay_body,
        wb03_scan_latches_body,
        wb03_mac_active_body,
        wb03_auth_tx_latches_body,
        prepare_txcal_body,
        prepare_rxcal_body,
    ]:
        assert "addr rf.txcalParam70" in body
        assert "rfRegRead(RfTxcalParamReg" not in body
        assert "rfRegWrite(RfTxcalParamReg" not in body
        assert "rfRegRead(RfPriInit70Reg" not in body
        assert "rfRegWrite(RfPriInit70Reg" not in body

    for body in [
        wait_fcal_ready_body,
        sample_fcal_body,
        write_fcal_body,
        write_acal_body,
        prepare_lo_fcal_body,
        choose_lo_fcal_body,
        run_lo_fcal_body,
        prepare_lo_acal_body,
        run_lo_acal_body,
        config_channel_cal_body,
    ]:
        assert "RfFcalReg" not in body
        assert "RfFcalCtrlReg" not in body
        assert "RfAcalCtrlReg" not in body
        assert "RfCalResultReg" not in body
        assert "RfSdm1Reg" not in body
        assert "RfSdm2Reg" not in body
    for body in [prepare_lo_fcal_body, run_lo_fcal_body,
                 prepare_lo_acal_body, run_lo_acal_body]:
        assert "addr rf.calMode14" in body
    for body in [prepare_lo_fcal_body, choose_lo_fcal_body,
                 config_channel_cal_body]:
        assert "addr rf.sdmCtrlC0" in body
    for body in [prepare_lo_fcal_body, run_lo_acal_body,
                 config_channel_cal_body]:
        assert "addr rf.sdmDivC4" in body
    for body in [prepare_lo_fcal_body, prepare_lo_acal_body]:
        for expected in [
            "let rf = rfRegs()",
            "addr rf.baseCtrl1",
            "addr rf.synthCtrl2c",
            "addr rf.priModeCtrl30",
            "addr rf.calCtrl1c",
        ]:
            assert expected in body
        for forbidden in [
            "RfCtrlReg",
            "RfSynthCtrlReg",
            "RfPriModeCtrlReg",
            "RfCalCtrlReg",
        ]:
            assert forbidden not in body
    for expected in [
        "addr rf.fcalAc",
        "addr rf.calResultA8",
    ]:
        assert expected in sample_fcal_body
    assert "addr rf.fcalAc" in wait_fcal_ready_body
    assert "addr rf.fcalCtrlA0" in write_fcal_body
    assert "addr rf.fcalCtrlA0" in write_acal_body
    for expected in [
        "addr rf.fcalCtrlA0",
        "addr rf.channelFcalConfigBc",
        "addr rf.txcalCtrlB8",
        "addr rf.channelCalStrobeB0",
        "addr rf.channelCalStatusB4",
    ]:
        assert expected in config_channel_cal_body
    for forbidden in [
        "RfTxcalCtrlReg",
        "RfPriConfigB0Reg",
        "RfPriConfigB4Reg",
        "RfPriConfigBcReg",
    ]:
        assert forbidden not in config_channel_cal_body
    for expected in [
        "addr rf.scanRxLatch4c",
        "addr rf.scanTxMeasureControl62c",
    ]:
        assert expected in wb03_scan_latches_body

    for body in [wb03_mac_active_body, wb03_auth_tx_latches_body]:
        assert "let rf = rfRegs()" in body
        assert "addr rf.txcalTosdac600" in body
        assert "addr rf.scanTxMeasureControl62c" in body
        assert "addr rf.fcalCtrlA0" in body
        assert "addr rf.roscalCtrl7c" in body
        assert "rfRegWrite(RfTxcalTosdacReg" not in body
        assert "rfRegWrite(RfFcalCtrlReg" not in body
        assert "rfRegWrite(RfRoscalCtrlReg" not in body
    assert "addr rf.txcalDfe88" in wb03_auth_tx_latches_body
    assert "rfRegWrite(RfPriTxcalDfeReg" not in wb03_auth_tx_latches_body
    assert "addr rf.calPathConfig8c" in wb03_auth_tx_capture_body
    assert "rfRegRead(RfPriInit8cReg" not in wb03_auth_tx_capture_body
    assert "addr rf.txcalDc6c" in wb03_mac_active_body
    assert "rfRegWrite(RfPriInit6cReg" not in wb03_mac_active_body
    assert "addr rf.calMode14" in wb03_mac_active_body
    assert "addr rf.calCtrl1c" in wb03_mac_active_body
    assert "RfCalModeReg" not in wb03_mac_active_body
    assert "RfCalCtrlReg" not in wb03_mac_active_body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.channelCalStrobeB0",
        "addr rf.channelCalStatusB4",
        "addr rf.txcalCtrlB8",
    ]:
        assert expected in wb03_rfc_wait_body
    for forbidden in [
        "rfRegRead(RfPriConfigB4Reg",
        "rfRegOr(RfPriConfigB0Reg",
        "rfRegClear(RfPriConfigB0Reg",
        "RfTxcalCtrlReg",
    ]:
        assert forbidden not in wb03_rfc_wait_body

    for body in [prepare_txcal_body, prepare_bz_txcal_body, prepare_rxcal_body]:
        assert "let rf = rfRegs()" in body
        assert "addr rf.calDfeGate23c" in body
        assert "0x2000123C'u32" not in body
        for expected in [
            "addr rf.baseCtrl1",
            "addr rf.synthCtrl2c",
            "addr rf.priModeCtrl30",
        ]:
            assert expected in body
        for forbidden in [
            "RfCtrlReg",
            "RfSynthCtrlReg",
            "RfPriModeCtrlReg",
        ]:
            assert forbidden not in body
    for body in [start_tx_dfe_body, start_rx_dfe_body]:
        assert "addr rf" in body
        assert "addr rf.rxMode220" in body
        assert "RfRxModeReg" not in body
        assert "rfRegClear(RfRxModeReg" not in body
        assert "rfRegWrite(RfRxModeReg" not in body
        assert "rfRegRead(RfRxModeReg" not in body
    for body in [prepare_txcal_body, prepare_bz_txcal_body]:
        for expected in [
            "addr rf.txcalDfe88",
            "addr rf.calCtrl1c",
            "addr rf.calSingenCtrl20c",
            "addr rf.calSingenAmpLo214",
            "addr rf.calSingenAmpHi218",
            "addr rf.rccalTone48",
            "addr rf.txcalGain64",
            "addr rf.txcalBias58",
        ]:
            assert expected in body
        for forbidden in [
            "rfRegOr(RfPriTxcalDfeReg, 0x80000000'u32)",
            "rfRegWrite(RfPriRccalSingenReg0",
            "rfRegWrite(RfPriRccalSingenReg1",
            "rfRegWrite(RfPriRccalSingenReg2",
            "rfRegClear(RfPriRccalSingenReg0",
            "rfRegOr(RfPriRccalSingenReg0",
            "rfRegWrite(RfPriRccalToneReg",
            "rfRegOr(RfPriInit64Reg",
            "rfRegWrite(RfPriInit64Reg",
            "rfRegRead(RfPriInit64Reg",
            "rfRegWrite(RfPriInit58Reg",
            "rfRegRead(RfPriInit58Reg",
            "RfCalCtrlReg",
        ]:
            assert forbidden not in body
    assert "addr rf.txcalDc6c" in prepare_txcal_body
    assert "addr rf.txcalGain68" in prepare_txcal_body
    assert "rfRegWrite(RfPriTxcalDcReg" not in prepare_txcal_body
    assert "rfRegRead(RfPriTxcalDcReg" not in prepare_txcal_body
    assert "rfRegWrite(RfPriInit68Reg" not in prepare_txcal_body
    assert "rfRegRead(RfPriInit68Reg" not in prepare_txcal_body
    assert "addr rf.calPathConfig8c" in prepare_bz_txcal_body
    assert "rfRegWrite(RfPriInit8cReg" not in prepare_bz_txcal_body
    assert "rfRegRead(RfPriInit8cReg" not in prepare_bz_txcal_body
    assert "addr rf.txcalGain64" in run_bz_txcal_body
    assert "rfRegWrite(RfPriInit64Reg" not in run_bz_txcal_body
    assert "rfRegRead(RfPriInit64Reg" not in run_bz_txcal_body
    assert "addr rf.measureMode61c" in prepare_txcal_body
    assert "rfRegWrite(RfMeasureModeReg" not in prepare_txcal_body
    for body in [run_txcal_body, run_bz_txcal_body, run_rxcal_body]:
        assert "let rf = rfRegs()" in body
        assert "addr rf.calMode14" in body
        assert "RfCalModeReg" not in body
    assert "addr rf.calCtrl1c" in run_bz_txcal_body
    assert "RfCalCtrlReg" not in run_bz_txcal_body

    for expected in [
        "let rf = rfRegs()",
        "addr rf.baseCtrl1",
        "addr rf.synthCtrl2c",
        "addr rf.priModeCtrl30",
        "addr rf.calCtrl1c",
        "addr rf.rxMode220",
        "addr rf.rccalTone48",
        "addr rf.roscalCtrl7c",
    ]:
        assert expected in prepare_roscal_body
    for forbidden in [
        "rfRegClear(RfRxModeReg",
        "rfRegWrite(RfRxModeReg",
        "RfCtrlReg",
        "RfSynthCtrlReg",
        "RfPriModeCtrlReg",
        "RfCalCtrlReg",
        "rfRegWrite(RfPriRccalToneReg",
        "rfRegClear(RfRoscalCtrlReg",
    ]:
        assert forbidden not in prepare_roscal_body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.roscalCal0",
        "addr rf.roscalCal1",
    ]:
        assert expected in apply_roscal_body
    for forbidden in ["RfRoscalReg0", "RfRoscalReg1"]:
        assert forbidden not in apply_roscal_body
    assert "let rf = rfRegs()" in write_roscal_candidate_body
    assert "addr rf.roscalCtrl7c" in write_roscal_candidate_body
    assert "RfRoscalCtrlReg" not in write_roscal_candidate_body
    assert "rfRegUpdate(RfRoscalCtrlReg" not in write_roscal_candidate_body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.capability20",
        "addr rf.calMode14",
        "RfRoscalCapabilityMask",
        "RfRoscalModeMask",
    ]:
        assert expected in run_roscal_body
    for forbidden in ["RfCapabilityReg", "RfCalModeReg"]:
        assert forbidden not in run_roscal_body
    for body in [
        wait_roscal_measure_body,
        wait_rccal_measure_body,
        wait_txcal_measure_body,
    ]:
        assert "let rf = rfRegs()" in body
        assert "addr rf.measureCtrl618" in body
        assert "rfRegRead(RfMeasureCtrlReg" not in body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.measureCtrl618",
        "addr rf.measureMode61c",
        "addr rf.measureI620",
        "addr rf.measureQ624",
    ]:
        assert expected in sample_roscal_measure_body
    for forbidden in [
        "rfRegClear(RfMeasureCtrlReg",
        "rfRegOr(RfMeasureCtrlReg",
        "rfRegWrite(RfMeasureModeReg",
        "rfRegRead(RfMeasureModeReg",
        "RfMeasureIReg",
        "RfMeasureQReg",
    ]:
        assert forbidden not in sample_roscal_measure_body

    for body in [prepare_rccal_body, prepare_rccal_tone_body]:
        assert "let rf = rfRegs()" in body
        for expected in [
            "addr rf.rccalTone48",
            "addr rf.calSingenCtrl20c",
            "addr rf.calSingenAmpLo214",
            "addr rf.calSingenAmpHi218",
            "addr rf.measureCtrl618",
        ]:
            assert expected in body
        for forbidden in [
            "rfRegWrite(RfPriRccalToneReg",
            "rfRegWrite(RfPriRccalSingenReg0",
            "rfRegWrite(RfPriRccalSingenReg1",
            "rfRegWrite(RfPriRccalSingenReg2",
            "rfRegClear(RfPriRccalSingenReg0",
            "rfRegOr(RfPriRccalSingenReg0",
        ]:
            assert forbidden not in body
    for expected in [
        "addr rf.baseCtrl1",
        "addr rf.synthCtrl2c",
        "addr rf.priModeCtrl30",
        "addr rf.calCtrl1c",
    ]:
        assert expected in prepare_rccal_body
    for forbidden in [
        "RfCtrlReg",
        "RfSynthCtrlReg",
        "RfPriModeCtrlReg",
        "RfCalCtrlReg",
    ]:
        assert forbidden not in prepare_rccal_body
    for body in [write_rccal_body, write_rccal_search_body]:
        assert "let rf = rfRegs()" in body
        assert "addr rf.rbbRccalCtrl80" in body
        assert "RfRbbRccalReg" not in body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.capability20",
        "addr rf.calMode14",
        "RfRccalCapabilityMask",
        "RfRccalModeMask",
        "RfRccalFailMode",
    ]:
        assert expected in run_rccal_body
    for forbidden in ["RfCapabilityReg", "RfCalModeReg"]:
        assert forbidden not in run_rccal_body
    for expected in [
        "addr rf.calMeasurePrep60c",
        "addr rf.measureMode61c",
    ]:
        assert expected in prepare_rccal_body
    for forbidden in [
        "rfRegClear(RfPriRccalMeasurePrepReg",
        "rfRegOr(RfPriRccalMeasurePrepReg",
        "rfRegWrite(RfMeasureCtrlReg",
        "rfRegClear(RfMeasureCtrlReg",
        "rfRegWrite(RfMeasureModeReg",
    ]:
        assert forbidden not in prepare_rccal_body

    for body in [
        sample_rccal_power_body,
        prime_rccal_measure_body,
        txcal_average_body,
        txcal_adc_mean_body,
        txcal_power_body,
    ]:
        assert "let rf = rfRegs()" in body
        assert "addr rf.measureCtrl618" in body
        for forbidden in [
            "rfRegClear(RfMeasureCtrlReg",
            "rfRegOr(RfMeasureCtrlReg",
            "rfRegWrite(RfMeasureCtrlReg",
            "rfRegRead(RfMeasureCtrlReg",
        ]:
            assert forbidden not in body
    for body in [sample_rccal_power_body, txcal_power_body]:
        assert "addr rf.measureI620" in body
        assert "addr rf.measureQ624" in body
        assert "rfRegRead(RfMeasureIReg" not in body
        assert "rfRegRead(RfMeasureQReg" not in body
    for body in [prime_rccal_measure_body, txcal_average_body, txcal_adc_mean_body]:
        assert "addr rf.measureMode61c" in body
        assert "rfRegWrite(RfMeasureModeReg" not in body
    for body in [txcal_average_body, txcal_adc_mean_body]:
        assert "addr rf.measureI620" in body
    for expected in [
        "addr rf.calSingenAmpLo214",
        "addr rf.calSingenAmpHi218",
        "addr rf.calSingenCtrl20c",
    ]:
        assert expected in txcal_singen_amp_body
    for forbidden in [
        "rfRegUpdate(RfPriRccalSingenReg",
        "rfRegClear(RfPriRccalSingenReg0",
        "rfRegOr(RfPriRccalSingenReg0",
    ]:
        assert forbidden not in txcal_singen_amp_body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.txcalParam74",
        "addr rf.txcalTosdac600",
    ]:
        assert expected in txcal_param_body
    for forbidden in [
        "rfRegUpdate(RfTxcalParam01Reg",
        "rfRegWrite(RfTxcalTosdacReg",
        "rfRegRead(RfTxcalTosdacReg",
    ]:
        assert forbidden not in txcal_param_body
    for expected in [
        "addr rf.calSingenCtrl20c",
        "addr rf.calSingenAmpLo214",
        "addr rf.calSingenAmpHi218",
        "addr rf.rccalTone48",
        "addr rf.calPathConfig8c",
        "addr rf.txcalGain64",
        "addr rf.txcalBias58",
    ]:
        assert expected in txcal_search_stage_body
    for forbidden in [
        "rfRegWrite(RfPriRccalSingenReg0",
        "rfRegWrite(RfPriRccalSingenReg1",
        "rfRegWrite(RfPriRccalSingenReg2",
        "rfRegWrite(RfPriRccalToneReg",
        "rfRegWrite(RfPriInit8cReg",
        "rfRegRead(RfPriInit8cReg",
        "rfRegWrite(RfPriInit64Reg",
        "rfRegRead(RfPriInit64Reg",
        "rfRegWrite(RfPriInit58Reg",
        "rfRegRead(RfPriInit58Reg",
    ]:
        assert forbidden not in txcal_search_stage_body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.rccalTone48",
        "addr rf.txcalDc6c",
        "addr rf.txcalGain64",
        "addr rf.txcalBias58",
        "addr rf.txcalGain68",
    ]:
        assert expected in txcal_gain_body
    for forbidden in [
        "rfRegWrite(RfPriRccalToneReg",
        "rfRegRead(RfPriRccalToneReg",
        "rfRegWrite(RfPriTxcalDcReg",
        "rfRegRead(RfPriTxcalDcReg",
        "rfRegWrite(RfPriInit64Reg",
        "rfRegRead(RfPriInit64Reg",
        "rfRegWrite(RfPriInit58Reg",
        "rfRegRead(RfPriInit58Reg",
        "rfRegWrite(RfPriInit68Reg",
        "rfRegRead(RfPriInit68Reg",
    ]:
        assert forbidden not in txcal_gain_body

    assert "let rf = rfRegs()" in wait_rxcal_measure_body
    assert "addr rf.measureCtrl618" in wait_rxcal_measure_body
    assert "rfRegRead(RfMeasureCtrlReg" not in wait_rxcal_measure_body
    assert "let rf = rfRegs()" in rxcal_param_body
    assert "addr rf.rxcalSearch614" in rxcal_param_body
    assert "rfRegRead(RfPriRxcalSearchReg" not in rxcal_param_body
    assert "rfRegWrite(RfPriRxcalSearchReg" not in rxcal_param_body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.measureCtrl618",
        "addr rf.measureI620",
        "addr rf.measureQ624",
    ]:
        assert expected in rxcal_power_body
    for forbidden in [
        "rfRegWrite(RfMeasureCtrlReg",
        "rfRegClear(RfMeasureCtrlReg",
        "rfRegOr(RfMeasureCtrlReg",
        "rfRegRead(RfMeasureIReg",
        "rfRegRead(RfMeasureQReg",
    ]:
        assert forbidden not in rxcal_power_body
    assert "let rf = rfRegs()" in store_rxcal_record_body
    assert "addr rf.rxcalReplay[index]" in store_rxcal_record_body
    for expected in [
        "let rxcalParam2ReplayWord = packRfRxcalWord0(p2)",
        "let rxcalParam3ReplayWord = packRfRxcalWord1(p3)",
        "let rxcalRecordBaseWord = 18 + index * 2",
        "rxcalParam2ReplayWord or rxcalParam3ReplayWord",
    ]:
        assert expected in store_rxcal_record_body
    for vague_name in [
        "let rxcalRecordWord0",
        "let rxcalRecordWord1",
        "let rxcalRecordBase =",
    ]:
        assert vague_name not in store_rxcal_record_body
    assert "RfPriRxcalReg0" not in store_rxcal_record_body
    assert "rfRegWrite(RfPriRxcalReg0" not in store_rxcal_record_body
    assert "rfRegRead(RfPriRxcalReg0" not in store_rxcal_record_body

    for expected in [
        "addr rf.baseCtrl1",
        "addr rf.synthCtrl2c",
        "addr rf.priModeCtrl30",
        "addr rf.channelFcalConfigBc",
        "addr rf.txcalCtrlB8",
        "addr rf.rxMode220",
        "addr rf.calPathCtrl90",
        "addr rf.txcalDfe88",
        "addr rf.rxcalPrep60",
        "addr rf.txcalGain64",
        "addr rf.txcalBias58",
        "addr rf.txcalGain68",
        "addr rf.rccalTone48",
        "addr rf.txcalTosdac600",
        "addr rf.txcalParam74",
        "addr rf.measureCtrl618",
        "addr rf.measureMode61c",
        "addr rf.rxcalSearch614",
        "addr rf.calSingenCtrl20c",
        "addr rf.calSingenAmpLo214",
        "addr rf.calSingenAmpHi218",
        "addr rf.calSingenMeasurePrep21c",
        "proc wlCfgWb03RxcalReplayA8Word()",
        "proc wlCfgWb03RxcalReplayAcWord()",
        "let rxcalReplayA8Word = wlCfgWb03RxcalReplayA8Word()",
        "let rxcalReplayAcWord = wlCfgWb03RxcalReplayAcWord()",
    ]:
        assert expected in wifi_fw if expected.startswith("proc ") else expected in prepare_rxcal_body
    for forbidden in [
        "0x200010BC'u32",
        "0x20001088'u32",
        "0x20001060'u32",
        "0x2000120C'u32",
        "0x20001214'u32",
        "0x20001218'u32",
        "0x2000121C'u32",
        "rfRegWrite(RfPriRccalToneReg",
        "RfCtrlReg",
        "RfSynthCtrlReg",
        "RfPriModeCtrlReg",
        "RfTxcalCtrlReg",
        "rfRegWrite(RfTxcalTosdacReg",
        "rfRegWrite(RfTxcalParam01Reg",
        "rfRegWrite(RfPriInit90Reg",
        "rfRegRead(RfPriInit90Reg",
        "rfRegOr(RfPriInit64Reg",
        "rfRegWrite(RfPriInit64Reg",
        "rfRegRead(RfPriInit64Reg",
        "rfRegWrite(RfPriInit58Reg",
        "rfRegRead(RfPriInit58Reg",
        "rfRegWrite(RfPriInit68Reg",
        "rfRegRead(RfPriInit68Reg",
        "rfRegWrite(RfMeasureModeReg",
        "rfRegWrite(RfMeasureCtrlReg",
        "rfRegWrite(RfPriRxcalSearchReg",
        "let cfgA8",
        "let cfgAc",
        "wlCfgU32(0xA8)",
        "wlCfgU32(0xAC)",
    ]:
        assert forbidden not in prepare_rxcal_body
    for expected in [
        "let rf = rfRegs()",
        "volatileStore(addr rf.rxcalSearch614, 0x00400000'u32)",
        "volatileStore(addr rf.measureCtrl618, 0x80000000'u32)",
    ]:
        assert expected in run_rxcal_body
    for forbidden in [
        "rfRegWrite(RfPriRxcalSearchReg, 0x00400000'u32)",
        "rfRegWrite(RfMeasureCtrlReg, 0x80000000'u32)",
    ]:
        assert forbidden not in run_rxcal_body

    for expected in [
        "let bba = bbaAgcRegs()",
        "addr bba.macActiveB340",
        "addr bba.macActiveB344",
        "addr bba.macActiveB368",
        "addr bba.pdComp36c",
        "addr bba.macActiveB384",
        "addr bba.macActiveB38c",
        "addr bba.pdGain390",
        "addr bba.macActiveB3a0",
        "addr bba.macActiveB3bc",
        "addr bba.macActiveB3c4",
        "addr bba.macActiveC01c",
        "addr bba.macActiveC020",
        "addr bba.macActiveC02c",
    ]:
        assert expected in wb03_mac_active_body
    for forbidden in [
        "cast[ptr uint32](0x24C0B340'u)",
        "cast[ptr uint32](0x24C0B344'u)",
        "cast[ptr uint32](0x24C0B368'u)",
        "cast[ptr uint32](0x24C0B36C'u)",
        "cast[ptr uint32](0x24C0B384'u)",
        "cast[ptr uint32](0x24C0B38C'u)",
        "cast[ptr uint32](0x24C0B390'u)",
        "cast[ptr uint32](0x24C0B3A0'u)",
        "cast[ptr uint32](0x24C0B3BC'u)",
        "cast[ptr uint32](0x24C0B3C4'u)",
        "cast[ptr uint32](0x24C0C01C'u)",
        "cast[ptr uint32](0x24C0C020'u)",
        "cast[ptr uint32](0x24C0C02C'u)",
    ]:
        assert forbidden not in wb03_mac_active_body
    rf_trace_body = wifi_fw.split(
        "proc rfPhyTraceCheckpoint(phase: uint32) =",
        1,
    )[1].split("proc rfPriTracePhase", 1)[0]
    for expected in [
        "let rf = rfRegs()",
        "let env = phyEnvViewPtr()",
        "let mdm = wifiModemRegs()",
        "addr env.channelBandType",
        "addr env.primaryFreq",
        "addr env.centerFreq1",
        "volatileLoad(addr rf.baseCtrl1)",
        "addr rf.synthCtrl2c",
        "addr rf.scanSynthLatch34",
        "addr rf.scanSynthLatch40",
        "addr rf.scanRxLatch4c",
        "addr rf.txcalParam70",
        "addr rf.txcalParam74",
        "addr rf.txcalDfe88",
        "addr rf.fcalCtrlA0",
        "addr rf.acalCtrlA4",
        "addr rf.channelFcalConfigBc",
        "addr rf.optimizeCtrlD0",
        "addr rf.rbbRccalCtrl80",
        "addr rf.rccalReplay84",
        "addr rf.calPathConfig8c",
        "addr rf.calPathCtrl90",
        "addr rf.channelCalStatusB4",
        "addr rf.txcalTosdac600",
        "addr rf.rxcalSearch614",
        "addr rf.measureCtrl618",
        "addr rf.scanTxMeasureControl62c",
        "addr rf.notchCtrl680",
        "addr rf.vcoPairTable13c[0]",
        "addr mdm.bandwidth20MProfile820",
        "addr mdm.channelTypeCtrl824",
        "addr mdm.bandwidth20MProfile830",
        "addr mdm.bandwidth20MGate874",
    ]:
        assert expected in rf_trace_body
    for forbidden in [
        "phyEnvWord(36'u)",
        "phyEnvHalf(38'u)",
        "phyEnvHalf(40'u)",
    ]:
        assert forbidden not in rf_trace_body
    for forbidden in [
        "WifiModemBase + 0x820'u",
        "WifiModemBase + 0x824'u",
        "WifiModemBase + 0x830'u",
        "WifiModemBase + 0x874'u",
        "cast[ptr uint32](0x20001004'u)",
        "cast[ptr uint32](0x20001034'u)",
        "cast[ptr uint32](0x20001040'u)",
        "addr rf.trace34",
        "addr rf.trace40",
        "cast[ptr uint32](0x2000104C'u)",
        "cast[ptr uint32](0x200010D0'u)",
        "cast[ptr uint32](0x20001080'u)",
        "cast[ptr uint32](0x20001084'u)",
        "cast[ptr uint32](0x2000162C'u)",
        "cast[ptr uint32](0x20001680'u)",
        "cast[ptr uint32](0x2000113C'u)",
        "readReg32(RfCtrlReg)",
        "readReg32(RfPriTrace34Reg)",
        "readReg32(RfPriTrace40Reg)",
        "readReg32(RfPriTrace4cReg)",
        "readReg32(RfTxcalParam01Reg)",
        "readReg32(RfPriTxcalDfeReg)",
        "readReg32(RfOptimizeReg)",
        "readReg32(RfPriTrace84Reg)",
        "readReg32(RfPriInit8cReg)",
        "readReg32(RfPriInit90Reg)",
        "readReg32(RfTxcalTosdacReg)",
        "readReg32(RfPriRxcalSearchReg)",
        "readReg32(RfMeasureCtrlReg)",
        "readReg32(RfPriTrace162cReg)",
        "readReg32(RfPriTrace1680Reg)",
        "readReg32(RfPriTrace113cReg)",
    ]:
        assert forbidden not in rf_trace_body

    wifi_hal = (ROOT / "examples/m0_wifi_hal_test.nim").read_text()
    assert "WifiRfVerboseDump {.booldefine.} = false" in wifi_hal
    assert "when (not WifiScanOnly) or WifiRfVerboseDump:" in wifi_hal
    assert "dumpRfTxcalTrace()" in wifi_hal

    for expected in [
        "--uart-anchor-flash",
        "--jtag-breakpoint-symbol",
        "--jtag-watchpoint-symbol",
        "mdw {sym:nimfw_dbg_rf_phy_trace_rf70} 64",
        "mdw {sym:nimfw_dbg_rf_phy_trace_rf88} 64",
        "mdw {sym:nimfw_dbg_rf_phy_trace_rfd0} 64",
        "mdw {sym:nimfw_dbg_rf_phy_trace_device} 64",
        "mdw {sym:nimfw_dbg_phy_init_count} 1",
        "mdw {sym:nimfw_dbg_phy_init_phase} 1",
        "mdw {sym:nimfw_dbg_phy_agc_copy_count} 1",
        "mdw {sym:nimfw_dbg_phy_agc_dest_first} 1",
        "mdw {sym:nimfw_dbg_phy_agc_dest_last} 1",
        "mdw {sym:nimfw_dbg_phy_wifi_ldpc_absent} 1",
        "mdw {sym:nim_wifi_rf_stage_rf70_log} 8",
        "mdw {sym:nim_wifi_rf_stage_rf88_log} 8",
        "mdw {sym:nim_wifi_rf_stage_rfd0_log} 8",
        "mdw {sym:nim_wifi_rf_optimize_channel_log} 8",
        "mdw {sym:nim_wifi_rf_optimize_rfd0_log} 8",
        "mdw {sym:nim_wifi_rf_optimize_rf70_log} 8",
        "bp_size = 2 if (address & 0x3) != 0 else 4",
        "args.jtag_watchpoint_symbol",
    ]:
        assert expected in manifest or expected in (
            ROOT / "tools/hw_validate.py"
        ).read_text()


def test_wifi_rx_tx_dhcp_path_uses_typed_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    wifi_tx = (ROOT / "src/bl808/wifi_tx.nim").read_text()
    lwip_smoke = (ROOT / "examples/m0_wifi_lwip_smoke.nim").read_text()
    e2e_runner = (ROOT / "src/bl808/kernel/e2e_runner.nim").read_text()
    assert "stopAfterSuccess = false" in e2e_runner
    assert "if stopAfterSuccess:\n        break" in e2e_runner
    assert (
        "e2eRun(AttemptsTotal, runOneAttempt, deinitForRetry, "
        "stopAfterSuccess = true)"
    ) in lwip_smoke
    assert "proc runIcmpEcho(targetAddress: uint32; requiredReply: bool)" in lwip_smoke
    assert "GatewayIcmpAttempts {.intdefine.} = 3" in lwip_smoke
    assert "var gatewayIcmpOk = false" in lwip_smoke
    assert "for _ in 0 ..< GatewayIcmpAttempts:" in lwip_smoke
    assert "gatewayIcmpOk = true" in lwip_smoke
    assert "let targetIcmpOk = runIcmpEcho(IcmpTargetAddress, false)" in lwip_smoke
    assert "return gatewayIcmpOk or targetIcmpOk" in lwip_smoke
    assert 'kvWrite("type", nimfw_dbg_icmp_cb_type_code)' in lwip_smoke
    assert "if not gatewayIcmpOk:\n    return false" not in lwip_smoke
    assert "discard runIcmpEcho(IcmpTargetAddress, false)" not in lwip_smoke
    assert 'kvWrite("required", uint32(requiredReply))' in lwip_smoke

    rx_body = wifi_fw.rsplit("proc rxu_cntrl_frame_handle*", 1)[1].split(
        "proc rxu_swdesc_upload_evt*", 1
    )[0]
    rx_upload_body = wifi_fw.rsplit("proc rxu_swdesc_upload_evt*", 1)[1].split(
        "# ###########################################################################",
        1,
    )[0]
    frame_build = wifi_fw.rsplit("proc txu_cntrl_frame_build*", 1)[1].split(
        "proc txu_cntrl_push*", 1
    )[0]
    tx_push = wifi_tx.split("proc txPush(", 1)[1].split(
        "proc bl_tx_cfm*", 1
    )[0]
    tx_cfm = wifi_tx.split("proc bl_tx_cfm*", 1)[1].split(
        "proc bl_tx_try_flush*", 1
    )[0]
    bl_output = wifi_tx.split("proc bl_output*", 1)[1].split(
        "proc bl_tx_cntrl_link_up*", 1
    )[0]
    tx_sec_key = wifi_fw.rsplit("proc txSecKeyFor", 1)[1].split(
        "proc txSecBumpPn", 1
    )[0]

    for expected in [
        "RxMsduSnapView {.packed.} = object",
        "proc rxMsduView(",
        "proc rxMsduPayload(",
        "proc rxSnapPrefixIs(",
        "proc rxSnapIsRfc1042(",
        "proc rxSnapIsBridgeTunnel(",
        "proc rxSnapTraceLo(",
        "proc rxSnapTraceHi(",
        "proc rxEthernetRewriteHeader(",
        "rxSecurityHeaderAt[TkipSecurityHeaderView]",
        "rxSecurityHeaderAt[CcmpSecurityHeaderView]",
        "TxSecurityKeyListView {.packed.} = object",
        "txSecurityKeyListAt(p: pointer): ptr TxSecurityKeyListView",
        "let keySlot = txSecurityKeyListAt(keyMatPtr).pairwiseKey",
        "pointerAddrU32(txSecurityKeyListAt(rateCtrl).pairwiseKey)",
        "let vif = vifChannelForIdx(vifIdx)",
        "let keyFlags = vifKeyPointers(vif).flags",
        "let vif = vifChannelForIdx(desc.vifIdx)",
        "if (vifKeyPointers(vif).flags and 0x02) != 0:",
        "let msdu = rxMsduView(frame, env.machdrLen)",
        "let hasRfc1042Snap = rxSnapIsRfc1042(addr msdu.snap)",
        "if hasRfc1042Snap and msdu.snap.ethertype == 0x8E88'u16:",
        "let msduSnap = rxMsdu(finalFrame, stripLen)",
        "let ethHdr = rxEthernetRewriteHeader(finalFrame, stripLen)",
        "stripLen = (stripLen.int - 6).uint8",
        "stripLen = (stripLen.int - 14).uint8",
        "let sta = staInfoForIdx(staIdx)",
        "let vifIdx = sta.instNbr",
        "let vif = vifChannelForIdx(vifIdx)",
        "let apVif = vifChannelAt(firstVif)",
        "addr apVif.macAddr[0]",
        "nimFwDbgRxuSnapLo",
        "nimFwDbgRxuSnapHi",
    ]:
        assert expected in wifi_fw

    for expected in [
        "when defined(bl808WifiRxPbufInput):",
        "tcpip_stack_input(",
        "rxl_mpdu_free(entry)",
        "uploadEnv.uploadCount = uploadEnv.uploadCount + desc.descCount.uint32",
    ]:
        assert expected in rx_upload_body

    for expected in [
        "BlHwView {.packed.} = object",
        "BlVifView {.packed.} = object",
        "BlStaView {.packed.} = object",
        "TxHdrView {.packed.} = object",
        "TxbufView {.packed.} = object",
        "TxdescHostView {.packed.} = object",
        "doAssert offsetof(TxHdrView, status) == int(TxHdrStatusOff)",
        "doAssert offsetof(TxdescHostView, upperHost) ==",
    ]:
        assert expected in wifi_tx

    for forbidden in [
        "cast[uint](msdu)",
        "cast[uint](finalFrame)",
        "cast[uint](rxuCtx)",
        "ptrAt(",
        "loadU8(",
        "loadU16(",
        "loadU32(",
        "storeU8(",
        "storeU16(",
        "storeU32(",
        "loadPtr(",
        "storePtr(",
    ]:
        assert forbidden not in rx_body
        assert forbidden not in frame_build
        assert forbidden not in tx_push
        assert forbidden not in tx_cfm
        assert forbidden not in bl_output

    assert "cast[uint](rateCtrl)" not in frame_build
    assert "let vifBase = cast[uint](addr vif_info_tab[0])" not in frame_build
    assert "let vifEntry = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint" not in frame_build
    assert "let vif = vifChannelAt(vifEntry)" not in frame_build
    assert "vifKeyPointersAt(vifEntry).flags" not in frame_build
    assert "let vifBase = cast[uint](addr vif_info_tab[0])" not in rx_body
    assert "let vifEntry = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint" not in rx_body
    assert "let vif = vifChannelAt(vifEntry)" not in rx_body
    assert "cast[uint](firstVif) + 80" not in rx_body
    assert "cast[uint](addr vif_info_tab[0])" not in tx_sec_key
    assert "desc.vifIdx.uint * VIF_ENTRY_SIZE.uint" not in tx_sec_key
    assert "vifKeyPointersAt(vifAddr).flags" not in tx_sec_key
    assert "var nimfw_dbg_sta_tx_rf_latch {.importc.}: uint32" in lwip_smoke
    assert 'kvWrite("tx_rf_latch", nimfw_dbg_sta_tx_rf_latch)' in lwip_smoke

    tx_check_ret = wifi_tx.split("proc txCheckRet", 1)[1].split(
        "proc nimFwDbgDhcpTxBreakpoint", 1
    )[0]
    assert "discard isSta" in tx_check_ret
    assert "(isGroupcast != 0'u8 and (value and DescDoneTxBit) != 0'u32)" in tx_check_ret
    assert "if isSta != 0'u8:" not in tx_check_ret


def test_wifi_security_rx_indication_uses_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc mm_sec_macrx_ind*", 1)[1].split(
        "proc mm_sec_machwkey_wr*", 1
    )[0]

    assert "SecMacRxIndView {.packed.} = object" in wifi_fw
    assert "staIdx*: uint8" in wifi_fw
    assert "length*: uint16" in wifi_fw
    assert "payload*: UncheckedArray[uint8]" in wifi_fw
    assert "doAssert offsetof(SecMacRxIndView, staIdx) == 0" in wifi_fw
    assert "doAssert offsetof(SecMacRxIndView, length) == 2" in wifi_fw
    assert "doAssert offsetof(SecMacRxIndView, payload) == 4" in wifi_fw
    assert "template secMacRxIndAt(p: pointer): ptr SecMacRxIndView" in wifi_fw
    assert "let ind = secMacRxIndAt(buf)" in body
    assert "ind.staIdx = staIdx" in body
    assert "ind.length = length" in body
    assert "c_memcpy(addr ind.payload[0], payload, length.csize_t)" in body
    assert "cast[ptr uint8](cast[uint](buf) + 0)" not in body
    assert "cast[ptr uint16](cast[uint](buf) + 2)" not in body
    assert "cast[pointer](cast[uint](buf) + 4)" not in body


def test_wifi_machw_key_control_word_uses_reference_switch_tables():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc mm_sec_machwkey_wr*", 1)[1].split(
        "proc mm_sec_machwkey_del*", 1
    )[0]

    for expected in [
        "let validCipherType = cipherType <= 3",
        "if not validCipherType:",
        "keyTypeForCtrl = 1",
        "if validCipherType:",
        "of 0: 0'u32",
        "of 1: 1'u32",
        "of 2: 0'u32",
        "of 3: 1'u32",
        "of 0: 1'u32",
        "of 1: 2'u32",
        "of 2: 3'u32",
        "of 3: 1'u32",
        "(keyTypeForCtrl shl 11)",
        "(hwCipherType shl 8)",
    ]:
        assert expected in body


def test_wifi_tcpip_input_converts_80211_mpdu_for_lwip():
    wifi_utils = (ROOT / "src/bl808/wifi_utils.nim").read_text()

    body = wifi_utils.rsplit("proc tcpip_stack_input*", 1)[1].split(
        "proc bl_utils_dump*", 1
    )[0]

    for expected in [
        "proc allocMpduEthernetPbuf(msduOffset: uint32; pkt: pointer): ptr Pbuf",
        "let macLen = macDataHeaderLen(fc)",
        "if (fc and 0x4000'u16) != 0:",
        "loadU8(snap, 0) != 0xAA'u8",
        "discard c_memcpy(addr ethHdr[0], da, 6.csize_t)",
        "discard c_memcpy(addr ethHdr[6], sa, 6.csize_t)",
        "ethHdr[12] = loadU8(snap, 6)",
        "ethHdr[13] = loadU8(snap, 7)",
        "proc pbuf_take_at(p: ptr Pbuf; dataptr: pointer; length, offset: uint16): ErrT",
        "let payloadStart = macLen + 8",
        "var totalLen = 14'u32 + firstPayloadLen",
        "PbufRam = 0x0280.cint",
        "result = pbuf_alloc(PbufRaw, totalLen.uint16, PbufRam)",
        "pbuf_take_at(result, addr ethHdr[0], 14'u16, 0'u16)",
        "let frame = cast[pointer](loadU32(pkt, WifiPktPktOff).uint + msduOffset)",
        "let frameAvail = firstLen - msduOffset",
        'exportc: "nimfw_dbg_tcpip_input_mpdu_fail_counts"',
        "allocMpduEthernetPbuf(msduOffset, pkt)",
        "(flags and RxFlagIs80211Mpdu) != 0'u32 and msduOffset == 0'u32",
        "let usedMpduInput = (flags and RxFlagIs80211Mpdu) != 0'u32 and msduOffset == 0'u32",
        "if msduOffset >= 14'u32: msduOffset - 14'u32",
        "allocFramePbuf(resolvedOffset, pkt)",
        'exportc: "nimfw_dbg_tcpip_input_mpdu_conv"',
        'exportc: "nimfw_dbg_tcpip_input_mpdu_fail"',
        'exportc: "nimfw_dbg_tcpip_input_mpdu_fail_detail_lo"',
        'exportc: "nimfw_dbg_tcpip_input_mpdu_fail_detail_hi"',
        "nimFwDbgTcpipInputMpduFailDetailLo += 1'u32 shl ((code - 1) * 8)",
        "nimFwDbgTcpipInputMpduFailDetailHi += 1'u32 shl ((code - 5) * 8)",
        'exportc: "nimfw_dbg_tcpip_input_mpdu_last0"',
        'exportc: "nimfw_dbg_tcpip_input_dhcp_rx"',
        'exportc: "nimfw_dbg_tcpip_input_dhcp_xid"',
        'exportc: "nimfw_dbg_tcpip_input_frame_last0"',
        'exportc: "nimfw_dbg_tcpip_input_frame_src0"',
        'exportc: "nimfw_dbg_tcpip_input_frame_pbuf0"',
        'exportc: "nimfw_dbg_tcpip_input_frame_ethertype"',
        "nimFwDbgTcpipInputFrameLast0 = resolvedOffset or (msduOffset shl 16)",
        "nimFwDbgTcpipInputFrameSrc0 = loadLe32Bytes(firstPayload, 0)",
        "nimFwDbgTcpipInputFramePbuf0 = loadLe32Bytes(eth, 0)",
        "nimFwDbgTcpipInputFrameEthType = etherType.uint32 or (p.len.uint32 shl 16)",
        'importc: "nimfw_dbg_pbuf_alloc_fail"',
        'importc: "nimfw_dbg_pbuf_take_fail"',
        "inc nimFwDbgPbufAllocFail",
        "inc nimFwDbgPbufTakeFail",
        "proc dhcpMessageType(eth: pointer; len: uint16): uint8",
        "proc noteEthernetInput(p: ptr Pbuf): bool",
        "if not noteEthernetInput(p) and",
        "not usedMpduInput and pkt != nil",
        "if msduOffset >= 4'u32: msduOffset - 4'u32",
        "p = allocMpduEthernetPbuf(mpduOffset, pkt)",
    ]:
        assert expected in wifi_utils

    assert "inc nimFwDbgTcpipInputMpdu\n        return -1" not in body

    smoke = (ROOT / "examples/m0_wifi_lwip_smoke.nim").read_text()
    lwipopts = (ROOT / "src/bl808/kernel/lwip_wifi_smoke/lwipopts.h").read_text()
    for expected in [
        "#define LWIP_HOOK_DHCP_APPEND_OPTIONS",
        "(msg)->flags = PP_HTONS(0x8000U)",
        "(msg_type) == DHCP_DISCOVER || (msg_type) == DHCP_REQUEST",
    ]:
        assert expected in lwipopts
    for expected in [
        "var nimfw_dbg_tcpip_input_frame_last0 {.importc.}: uint32",
        "var nimfw_dbg_tcpip_input_frame_src0 {.importc.}: uint32",
        "var nimfw_dbg_tcpip_input_frame_pbuf0 {.importc.}: uint32",
        'kvWrite("rx_fl0", nimfw_dbg_tcpip_input_frame_last0)',
        'kvWrite("rx_fs0", nimfw_dbg_tcpip_input_frame_src0)',
        'kvWrite("rx_fp0", nimfw_dbg_tcpip_input_frame_pbuf0)',
        'kvWrite("rx_fet", nimfw_dbg_tcpip_input_frame_ethertype)',
    ]:
        assert expected in smoke
    for expected in [
        'kvWrite("rx_mpdu"',
        'kvWrite("rx_mpfail"',
        'kvWrite("rx_mpfcnt"',
        'kvWrite("rx_mpflo"',
        'kvWrite("rx_mpfhi"',
        'kvWrite("rx_mpl0"',
        'kvWrite("rx_mpl1"',
        'kvWrite("rx_mpl2"',
        'kvWrite("pbuf_fail"',
        'kvWrite("rx_dhcprx"',
        'kvWrite("rx_ports"',
        'kvWrite("rx_dhcpx"',
        'kvWrite("rx_dhcpch0"',
        'kvWrite("lwip_dhcprx"',
        'kvWrite("lwip_dhcpc"',
        'kvWrite("lwip_dhcpo"',
        'kvWrite("lwip_dhcpcr"',
        'kvWrite("rxu_dup_n"',
        'kvWrite("rxu_dup_b"',
        'kvWrite("rxu_dupf0"',
        'kvWrite("rxu_dupsn1"',
        'kvWrite("rxu_dupi0"',
        'kvWrite("rxu_dupu0"',
        'kvWrite("rxu_dupd1"',
        'kvWrite("rxu_dupyi"',
        'kvWrite("rxu_dupmsg"',
        'kvWrite("rxu_dupsrv"',
        'kvWrite("rxu_pnd_n"',
        'kvWrite("rxu_pnd_fc"',
        'kvWrite("rxu_pnd_pn0"',
        'kvWrite("rxu_pnd_st0"',
        'kvWrite("rxu_pnd_msg"',
        'kvWrite("rxu_pnd_srv"',
        'kvWrite("dhcp_msg"',
        'kvWrite("dhcp_bhit"',
        'kvWrite("dhcp_rhit"',
        'kvWrite("dhcp_mh3"',
        'kvWrite("dhcp_usum_n"',
        'kvWrite("dhcp_usum_va"',
        'kvWrite("dhcp_rsum_cp"',
        'kvWrite("heap_used"',
        'kvWrite("heap_largest"',
        'kvWrite("heap_fail"',
    ]:
        assert expected in smoke

    fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    manifest = (ROOT / "tools/hardware_validation.json").read_text()
    for expected in [
        'exportc: "nimfw_dbg_rxu_dup_trace_count"',
        'exportc: "nimfw_dbg_rxu_dup_trace_fc"',
        'exportc: "nimfw_dbg_rxu_dup_trace_seq"',
        'exportc: "nimfw_dbg_rxu_dup_trace_cache"',
        'exportc: "nimfw_dbg_rxu_dup_trace_snap_lo"',
        'exportc: "nimfw_dbg_rxu_dup_trace_snap_hi"',
        'exportc: "nimfw_dbg_rxu_dup_trace_addr0"',
        'exportc: "nimfw_dbg_rxu_dup_trace_addr1"',
        'exportc: "nimfw_dbg_rxu_dup_trace_ip0"',
        'exportc: "nimfw_dbg_rxu_dup_trace_udp0"',
        'exportc: "nimfw_dbg_rxu_dup_trace_bootp0"',
        'exportc: "nimfw_dbg_rxu_dup_trace_bootp1"',
        'exportc: "nimfw_dbg_rxu_dup_trace_bootp_yiaddr"',
        'exportc: "nimfw_dbg_rxu_dup_trace_dhcp_msg"',
        'exportc: "nimfw_dbg_rxu_dup_trace_dhcp_server"',
        'exportc: "nimfw_dbg_rxu_dup_break_hits"',
        'exportc: "nimfw_dbg_rxu_pn_drop_trace_count"',
        'exportc: "nimfw_dbg_rxu_pn_drop_trace_fc"',
        'exportc: "nimfw_dbg_rxu_pn_drop_trace_pn_lo"',
        'exportc: "nimfw_dbg_rxu_pn_drop_trace_stored_lo"',
        'exportc: "nimfw_dbg_rxu_pn_drop_trace_dhcp_msg"',
        'exportc: "nimfw_dbg_rxu_pn_drop_trace_dhcp_server"',
        'exportc: "nimfw_dbg_rxu_pn_accept_trace_count"',
        'exportc: "nimfw_dbg_rxu_pn_accept_trace_stage"',
        'exportc: "nimfw_dbg_rxu_pn_accept_trace_pn_lo"',
        'exportc: "nimfw_dbg_rxu_pn_accept_trace_next_lo"',
        'exportc: "nimfw_dbg_rxu_pn_accept_trace_dhcp_msg"',
        'exportc: "nimfw_dbg_rxu_pn_accept_trace_dhcp_server"',
        'nimFwDbgRecordRxuPnDrop(frame, hwFlags, envSeq, env.tid',
        'nimFwDbgRecordRxuPnAccept(1\'u32, frame, hwFlags, envSeq, env.tid',
        'nimFwDbgRecordRxuPnAccept(4\'u32, frame, hwFlags, envSeq, env.tid',
        'nimFwDbgRecordRxuDupDrop(frame, hwFlags, envSeq, env.tid',
        'proc nimFwDbgRxuDupDropBreakpoint*()',
        "inc nimFwDbgRxuDupBreakHits",
        'exportc: "nimfw_dbg_rxu_dup_drop_breakpoint"',
    ]:
        assert expected in fw
    for expected in [
        "mdw {sym:nimfw_dbg_rxu_dup_trace_count} 1",
        "mdw {sym:nimfw_dbg_rxu_dup_break_hits} 1",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_fc} 8",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_seq} 8",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_cache} 8",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_snap_lo} 8",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_snap_hi} 8",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_addr0} 8",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_addr1} 8",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_ip0} 8",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_udp0} 8",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_bootp0} 8",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_bootp1} 8",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_bootp_yiaddr} 8",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_dhcp_msg} 8",
        "mdw {sym:nimfw_dbg_rxu_dup_trace_dhcp_server} 8",
        "mdw {sym:nimfw_dbg_rxu_pn_drop_trace_count} 1",
        "mdw {sym:nimfw_dbg_rxu_pn_drop_trace_fc} 8",
        "mdw {sym:nimfw_dbg_rxu_pn_drop_trace_pn_lo} 8",
        "mdw {sym:nimfw_dbg_rxu_pn_drop_trace_stored_lo} 8",
        "mdw {sym:nimfw_dbg_rxu_pn_drop_trace_dhcp_msg} 8",
        "mdw {sym:nimfw_dbg_rxu_pn_drop_trace_dhcp_server} 8",
        "mdw {sym:nimfw_dbg_rxu_pn_accept_trace_count} 1",
        "mdw {sym:nimfw_dbg_rxu_pn_accept_trace_stage} 8",
        "mdw {sym:nimfw_dbg_rxu_pn_accept_trace_pn_lo} 8",
        "mdw {sym:nimfw_dbg_rxu_pn_accept_trace_next_lo} 8",
        "mdw {sym:nimfw_dbg_rxu_pn_accept_trace_dhcp_msg} 8",
        "mdw {sym:nimfw_dbg_rxu_pn_accept_trace_dhcp_server} 8",
        "mdw {sym:nimfw_dbg_dhcp_tx_break_hits} 1",
        "mdw {sym:nimfw_dbg_dhcp_request_tx_break_hits} 1",
        "mdw {sym:nimfw_dbg_dhcp_tx_msg_hist} 8",
        "mdw {sym:nimfw_dbg_dhcp_udp_csum_repair} 1",
        "mdw {sym:nimfw_dbg_dhcp_udp_csum_vafter} 1",
        "mdw {sym:nimfw_dbg_dhcp_req_udp_csum_at_copy} 1",
        "mdw 0x24C00824 1",
        "mdw 0x24C00834 1",
        "mdw 0x24C00874 1",
        "mdw 0x24C09000 32",
        "mdw 0x24C0A000 32",
        "mdw 0x24C0B340 4",
        "mdw 0x24C0B390 1",
    ]:
        assert expected in manifest

    for expected in [
        "#define MEM_SIZE                       (8 * 1024)",
        "#define PBUF_POOL_SIZE                 24",
        "#define MEMP_NUM_PBUF                  24",
    ]:
        assert expected in lwipopts


def test_wifi_assoc_data_duplicate_filter_requires_retry_bit():
    fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    body = fw.split("proc rxu_cntrl_frame_handle*", 1)[1].split(
        "# .L171: EAPOL detection requires RFC1042 SNAP", 1
    )[0]
    duplicate_block = body.split("# Duplicate sequence check", 1)[1].split(
        "seqCachePtr[] = envSeq", 1
    )[0]
    assert "let retryFrame = (rawFC and 0x0800'u16) != 0" in duplicate_block
    assert "let protectedReplayChecked = (env.secFlags and 2) != 0" in duplicate_block
    assert "if retryFrame and not protectedReplayChecked and" in duplicate_block
    assert "seqCachePtr[] == envSeq and nimFwDbgRxuAssocUploadReady != 0" in duplicate_block
    assert "nimFwDbgRecordRxuDupDrop(frame, hwFlags, envSeq, env.tid" in duplicate_block


def test_wifi_igtk_install_uses_typed_machw_key_request():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc bl_wifi_set_igtk_internal*", 1)[1].split(
        "proc bl_wifi_get_sta_gtk*", 1
    )[0]

    for expected in [
        "MachwKeyWriteParamView {.packed.} = object",
        "macLen*: uint8",
        "macAddr*: array[6, uint8]",
        "doAssert offsetof(MachwKeyWriteParamView, macLen) == 40",
        "doAssert offsetof(MachwKeyWriteParamView, macAddr) == 44",
        "doAssert offsetof(MachwKeyWriteParamView, cipherType) == 52",
        "IgtkKeyWriteStackView {.packed.} = object",
        "resultByte*: uint8",
        "req*: MachwKeyWriteParamView",
        "doAssert sizeof(IgtkKeyWriteStackView) == 96",
        "doAssert offsetof(IgtkKeyWriteStackView, resultByte) == 39",
        "doAssert offsetof(IgtkKeyWriteStackView, req) == 40",
        "template machwKeyWriteParamView(param: pointer): ptr MachwKeyWriteParamView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let stack = cast[ptr IgtkKeyWriteStackView](addr keyBuf[0])",
        "let req = addr stack.req",
        "discard c_memset(cast[pointer](req), 0, sizeof(MachwKeyWriteParamView).csize_t)",
        "req.keyType = 0xFF'u8",
        "req.cipherType = 5",
        "req.keyIdx = vifIdx",
        "req.addrIdx = keyIdx",
        "req.keyLen = 16",
        "discard c_memcpy(addr req.keyWords[0], keyData, 16.csize_t)",
        "req.macLen = 6",
        "discard c_memcpy(addr req.macAddr[0], macAddr, 6.csize_t)",
        "mm_sec_machwkey_wr(cast[pointer](req))",
        "let resultByte = stack.resultByte",
        "discard sm_get_set_machwkey_index(0, vifIdx.uint32, cast[pointer](req), 5)",
    ]:
        assert expected in body

    for forbidden in [
        "let req = machwKeyWriteParamView(addr keyBuf[40])",
        "let resultByte = keyBuf[39]",
        "let bufAddr = cast[uint](addr keyBuf[0])",
        "cast[pointer](bufAddr + 40)",
        "cast[ptr uint8](bufAddr + 41)[]",
        "cast[ptr uint8](bufAddr + 92)[]",
        "cast[ptr uint8](bufAddr + 93)[]",
        "cast[ptr uint8](bufAddr + 40)[]",
        "cast[ptr uint8](bufAddr + 44)[]",
        "cast[pointer](bufAddr + 48)",
        "cast[ptr uint8](bufAddr + 80)[]",
        "cast[pointer](bufAddr + 84)",
    ]:
        assert forbidden not in body


def test_wifi_set_key_tkip_mic_swap_uses_typed_key_data_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc setKey(", 1)[1].split(
        "proc bl_wifi_set_ap_key_internal*", 1
    )[0]

    for expected in [
        "SupplicantTkipKeyDataView {.packed.} = object",
        "temporalKey*: array[16, uint8]",
        "micTx*: array[2, uint32]",
        "micRx*: array[2, uint32]",
        "doAssert sizeof(SupplicantTkipKeyDataView) == 32",
        "doAssert offsetof(SupplicantTkipKeyDataView, micTx) == 16",
        "doAssert offsetof(SupplicantTkipKeyDataView, micRx) == 24",
        "template supplicantTkipKeyData(req: ptr SupplicantKeyParamView): ptr SupplicantTkipKeyDataView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let tkip = supplicantTkipKeyData(req)",
        "let micTx = tkip.micTx",
        "tkip.micTx = tkip.micRx",
        "tkip.micRx = micTx",
        "req.translatedCipher = 1",
    ]:
        assert expected in body

    for forbidden in [
        "let micTx0 = cast[ptr uint32](addr req.keyData[16])[]",
        "let micTx1 = cast[ptr uint32](addr req.keyData[20])[]",
        "let micRx0 = cast[ptr uint32](addr req.keyData[24])[]",
        "let micRx1 = cast[ptr uint32](addr req.keyData[28])[]",
        "cast[ptr uint32](addr req.keyData[16])[]",
        "cast[ptr uint32](addr req.keyData[20])[]",
        "cast[ptr uint32](addr req.keyData[24])[]",
        "cast[ptr uint32](addr req.keyData[28])[]",
    ]:
        assert forbidden not in body


def test_wifi_cfg_api_element_set_uses_typed_entry_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    general_body = wifi_fw.rsplit("proc cfg_api_element_general_set*", 1)[1].split(
        "proc cfg_api_element_set*", 1
    )[0]
    set_body = wifi_fw.rsplit("proc cfg_api_element_set*", 1)[1].split(
        "proc dump_cfg_entries*", 1
    )[0]

    for expected in [
        "CfgApiElementEntryView {.packed.} = object",
        "id*: uint32",
        "subId*: uint16",
        "typeId*: uint16",
        "name*: pointer",
        "data*: pointer",
        "setHandler*: pointer",
        "doAssert sizeof(CfgApiElementEntryView) == 28",
        "doAssert offsetof(CfgApiElementEntryView, typeId) == 6",
        "doAssert offsetof(CfgApiElementEntryView, name) == 8",
        "doAssert offsetof(CfgApiElementEntryView, data) == 12",
        "doAssert offsetof(CfgApiElementEntryView, setHandler) == 16",
        "template cfgApiElementEntryAt(entry: pointer): ptr CfgApiElementEntryView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let cfg = cfgApiElementEntryAt(entry)",
        "let nameStr = cfg.name",
        "let typeId = cfg.typeId",
        "let dataPtr = cfg.data",
    ]:
        assert expected in general_body

    for expected in [
        "var entry {.noinit.}: CfgApiElementEntryView",
        "discard c_memset(addr entry, 0, sizeof(CfgApiElementEntryView).csize_t)",
        "entry.id = id",
        "entry.subId = subId",
        "entry.typeId = typeId",
        "entry.data = cast[pointer](addr cfgElements[id])",
        "entry.setHandler = cast[pointer](setFn)",
        "setFn(cast[pointer](addr entry), value)",
    ]:
        assert expected in set_body

    for forbidden in [
        "let entryU = cast[uint](entry)",
        "cast[ptr pointer](entryU + 8)[]",
        "cast[ptr uint16](entryU + 6)[]",
        "cast[ptr pointer](entryU + 12)[]",
        "var entry {.noinit.}: array[28, uint8]",
        "let entryAddr = cast[uint](addr entry[0])",
        "cast[ptr uint32](entryAddr)[]",
        "cast[ptr uint16](entryAddr + 4)[]",
        "cast[ptr uint16](entryAddr + 6)[]",
        "cast[ptr pointer](entryAddr + 12)[]",
    ]:
        assert forbidden not in general_body
        assert forbidden not in set_body


def test_wifi_mfp_uses_typed_vif_key_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    ignore_body = wifi_fw.rsplit("proc mfp_ignore_mgmt_frame*", 1)[1].split(
        "proc mfp_protect_mgmt_frame*", 1
    )[0]
    protect_body = wifi_fw.rsplit("proc mfp_protect_mgmt_frame*", 1)[1].split(
        "proc mfp_add_mgmt_mic*", 1
    )[0]
    mic_body = wifi_fw.rsplit("proc mfp_add_mgmt_mic*", 1)[1].split(
        "proc aes_encrypt_block*", 1
    )[0]

    for expected in [
        "template vifKeySlot(vif: ptr VifChannelView, slot: uint): ptr VifKeySlotView",
        "template vifKeyPointers(vif: ptr VifChannelView): ptr VifKeyPointersView",
        "MmIeView {.packed.} = object",
        "keyId*: uint16",
        "ipn*: array[6, uint8]",
        "mic*: array[8, uint8]",
        "template mmieAt(p: pointer): ptr MmIeView",
        "template mmieMicWords(ie: ptr MmIeView): ptr UncheckedArray[uint32]",
        "doAssert sizeof(MmIeView) == 18",
        "doAssert offsetof(MmIeView, keyId) == 2",
        "doAssert offsetof(MmIeView, ipn) == 4",
        "doAssert offsetof(MmIeView, mic) == 10",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let keyPtrs = vifKeyPointers(vif)",
        "let secCtxPtr = keyPtrs.groupKeyPtr",
        "let ieSearchStart = ieCursorAfter(frameBodyPtr, bodyOff.uint + 2)",
        "let mmie = mmieAt(mmiePtr)",
        "let keyId = mmie.keyId",
        "if vifKeySlot(vif, keyIdAdj.uint).installed == 0:",
        "let ipnLo = mmie.ipn[1].uint16 or (mmie.ipn[0].uint16 shl 8)",
        "let expectedMic = mmieMicWords(mmie)",
        "let bipKey = vifKeySlot(vif, 0)",
    ]:
        assert expected in ignore_body

    for expected in [
        "let mmie = mmieAt(ieCursorAfter(frameDesc, bodyLen.uint))",
        "mmie.ie.id = 76",
        "mmie.ie.len = 16",
        "mmie.keyId = sec.staIdx.uint16",
        "mmie.ipn[idx.int] = ipnByte",
        "let micWords = mmieMicWords(mmie)",
        "mmie.mic[idx.int] = ((micV shr (idx * 8)) and 0xFF'u64).uint8",
        "mmie.mic[idx.int] = ((micV2 shr (idx * 8)) and 0xFF'u64).uint8",
    ]:
        assert expected in mic_body

    for body in [protect_body, mic_body]:
        assert "let desc = hostTxDescAt(frameDesc)" in body
        assert "let vifIdx = desc.vifIdx" in body
        assert "let vif = vifChannelForIdx(vifIdx)" in body
        assert "cast[pointer](vifKeyPointers(vif).groupKeyPtr)" in body

    assert "let staIdx = desc.staInfoIdx" in protect_body
    assert "let fd = cast[ptr UncheckedArray[uint8]](frameDesc)" not in protect_body
    assert "let fd = cast[ptr UncheckedArray[uint8]](frameDesc)" not in mic_body
    assert "fd[47]" not in protect_body
    assert "fd[49]" not in protect_body
    assert "fd[47]" not in mic_body
    assert "fd[49]" not in mic_body

    for body in [ignore_body, protect_body, mic_body]:
        assert "cast[uint](addr vif_info_tab[0]) + vifIdx.uint * VIF_ENTRY_SIZE.uint" not in body
        assert "let vifBase = cast[uint](addr vif_info_tab[0])" not in body
        assert "let vifEntry = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint" not in body
        assert "vifKeyPointersAt(vifEntry" not in body
        assert "vifKeyPointersAt(vifEntryBase" not in body
        assert "vifKeySlotAt(vifEntryBase" not in body
        assert "let mmieU = cast[uint](mmiePtr)" not in body
        assert "cast[ptr uint8](mmieU +" not in body
        assert "cast[ptr uint32](mmieU +" not in body
        assert "let mmiePos = cast[uint](frameDesc) + bodyLen" not in body
        assert "cast[ptr uint32](mmiePos +" not in body


def test_wifi_tx_policy_writers_use_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    update_body = wifi_fw.split("proc me_update_buffer_control*", 1)[1].split(
        "proc me_tx_cfm_singleton*", 1
    )[0]
    init_body = wifi_fw.split("proc rc_init*(staEntry: pointer)", 1)[1].split(
        "{.emit: \"__attribute__((optimize(\\\"crossjumping\\\"))) void rc_check",
        1,
    )[0]
    bcmc_body = wifi_fw.split("proc rc_init_bcmc_rate*", 1)[1].split(
        "proc rc_check_fixed_rate_config*", 1
    )[0]
    policy_bodies = update_body + init_body + bcmc_body

    for expected in [
        "TxPolicyView {.packed.} = object",
        "retryRate*: array[4, uint32]",
        "txPower*: array[4, uint32]",
        "doAssert sizeof(TxPolicyView) == 60",
        "doAssert offsetof(TxPolicyView, bufferAddr) == 4",
        "doAssert offsetof(TxPolicyView, retryRate) == 20",
        "doAssert offsetof(TxPolicyView, txPower) == 36",
        "doAssert offsetof(TxPolicyView, edcaParam0) == 52",
        "doAssert offsetof(TxPolicyView, edcaParam1) == 56",
        "template txPolicyAt(p: pointer): ptr TxPolicyView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let policy = txPolicyAt(txPolicy)",
        "var policyWord = policy.bufferAddr",
        "rateWords[acIdx] = policy.retryRate[acIdx]",
        "txPowerWords[acIdx] = policy.txPower[acIdx]",
        "let vif = vifChannelForIdx(vifIdx)",
        "let vifHtCaps = vifHtCapabilities(vif)",
        "rcU8(rcStats, 0xBF) = vifHtCaps.mcsSet[12]",
        "let vifBitmap = vifHtCaps.mcsSet[acIdx]",
        "policy.bufferAddr = policyWord",
        "policy.retryRate[acIdx] = rateWords[acIdx]",
        "policy.txPower[acIdx] = txPowerWords[acIdx]",
    ]:
        assert expected in update_body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0]) + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vifRatePowerBase = vifBase + 0x15F'u",
        "cast[ptr uint8](vifBase + 0x16B'u)",
        "cast[ptr uint8](vifRatePowerBase + acIdx.uint)",
    ]:
        assert forbidden not in update_body

    for expected in [
        "policy.retryRate[i] = packed",
        "policy.status = 0xBADCAB1E'u32",
        "policy.bufferAddr = bufAddr",
        "policy.bufferMask = (1'u32 shl (ntx2.uint32 + 1'u32)) - 1'u32",
        "policy.packetType = pktType",
        "policy.controlInfo = 0xFFFF0704'u32",
        "policy.edcaParam0 = 0x2200'u32",
        "policy.edcaParam1 = cast[uint32](cast[uint](sta.vif))",
    ]:
        assert expected in init_body

    assert "for retry in mitems(policy.retryRate):" in bcmc_body
    assert "retry = rateConfig" in bcmc_body

    for forbidden in [
        "cast[ptr uint32](cast[uint](txPolicy) + 0)",
        "cast[ptr uint32](cast[uint](txPolicy) + 4)",
        "cast[ptr uint32](cast[uint](txPolicy) + 8)",
        "cast[ptr uint32](cast[uint](txPolicy) + 12)",
        "cast[ptr uint32](cast[uint](txPolicy) + 16)",
        "cast[ptr uint32](cast[uint](txPolicy) + 20",
        "cast[ptr uint32](cast[uint](txPolicy) + 24",
        "cast[ptr uint32](cast[uint](txPolicy) + 28",
        "cast[ptr uint32](cast[uint](txPolicy) + 32",
        "cast[ptr uint32](cast[uint](txPolicy) + 36",
        "cast[ptr uint32](cast[uint](txPolicy) + 52)",
        "cast[ptr uint32](cast[uint](txPolicy) + 56)",
    ]:
        assert forbidden not in policy_bodies


def test_wifi_tx_cfm_singleton_uses_typed_thd_flags():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc me_tx_cfm_singleton*(param: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc me_tx_cfm_ampdu*", 1
    )[0]

    assert "doAssert offsetof(HostTxThdEntryView, flags) == 16" in wifi_fw
    assert "let thd = hostTxHeadThd(hostTxHwDescAt(desc.hwDesc))" in body
    assert "let statusWord = thd.flags" in body
    assert "cast[ptr uint32](cast[uint](thd) + 16)" not in body
    assert "let thd = cast[ptr pointer](desc.hwDesc)[]" not in body


def test_wifi_txu_cfm_uses_typed_thd_confirm_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit(
        "proc txu_cntrl_cfm*(param: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txu_cntrl_tkip_mic_append*", 1
    )[0]

    for expected in [
        "HostTxThdConfirmView {.packed.} = object",
        "confirmType*: uint16",
        "reserved14*: uint16",
        "doAssert sizeof(HostTxThdConfirmView) == 20",
        "doAssert offsetof(HostTxThdConfirmView, confirmType) == 12",
        "doAssert offsetof(HostTxThdConfirmView, flags) == 16",
        "template hostTxThdConfirmAt(p: ptr HostTxThdEntryView): ptr HostTxThdConfirmView",
        "hostTxThdConfirmAt(thd).confirmType = 0x0101'u16",
    ]:
        assert expected in wifi_fw if expected.startswith(("HostTxThdConfirmView", "confirmType", "reserved14", "doAssert", "template")) else expected in body

    for forbidden in [
        "cast[ptr uint16](addr thd.payloadEnd)[]",
        "cast[ptr uint16](cast[uint](thd) + 12)",
        "cast[ptr uint16](cast[uint](thd) + 12'u)",
    ]:
        assert forbidden not in body


def test_wifi_rate_control_counters_use_typed_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    calc_body = wifi_fw.rsplit("proc rc_calc_tp*", 1)[1].split(
        "proc rc_update_counters*", 1
    )[0]
    update_body = wifi_fw.rsplit("proc rc_update_counters*", 1)[1].split(
        "proc rc_get_duration*", 1
    )[0]
    stats_body = wifi_fw.rsplit("proc rc_update_stats*", 1)[1].split(
        "proc rc_set_previous_mcs_index*", 1
    )[0]
    amsdu_body = wifi_fw.rsplit("proc me_tx_cfm_amsdu*", 1)[1].split(
        "# ME IE building functions", 1
    )[0]
    set_rate_body = wifi_fw.rsplit("proc me_rc_set_rate_req_handler*", 1)[1].split(
        "proc me_traffic_ind_req_handler*", 1
    )[0]
    bw_body = wifi_fw.rsplit("proc rc_update_bw_nss_max*", 1)[1].split(
        "proc rc_update_preamble_type*", 1
    )[0]
    preamble_body = wifi_fw.rsplit("proc rc_update_preamble_type*", 1)[1].split(
        "proc rc_init_bcmc_rate*", 1
    )[0]
    sort_body = wifi_fw.rsplit("proc rc_sort_samples_tp*", 1)[1].split(
        "proc rc_calc_prob_ewma*", 1
    )[0]

    for expected in [
        "RcRateEntryView {.packed.} = object",
        "attempts*: uint16",
        "failures*: uint16",
        "probEwma*: uint16",
        "rateConfig*: uint16",
        "RcRateResetFieldsView {.packed.} = object",
        "attempts0*: uint16",
        "oldProb*: uint8",
        "sampleSkipped*: uint8",
        "initialized*: uint8",
        "RcRetrySlotView {.packed.} = object",
        "rateIdx*: uint16",
        "RcStatsCounterView {.packed.} = object",
        "retrySlots*: array[4, RcRetrySlotView]",
        "totalAttempts*: uint16",
        "totalSuccess*: uint16",
        "reserved168*: array[2, uint8]",
        "avgAmpduLen*: uint16",
        "retryLimit*: uint8",
        "updateStage*: uint8",
        "nssMax*: uint8",
        "bwMax*: uint8",
        "legacyRateMap*: uint16",
        "fixedRate*: uint16",
        "doAssert sizeof(RcRateEntryView) == RC_RATE_ENTRY_SIZE",
        "doAssert offsetof(RcRateResetFieldsView, oldProb) == 5",
        "doAssert offsetof(RcRateResetFieldsView, sampleSkipped) == 6",
        "doAssert offsetof(RcRateResetFieldsView, initialized) == 7",
        "doAssert offsetof(RcStatsCounterView, retrySlots) == 128",
        "doAssert offsetof(RcStatsCounterView, totalAttempts) == RCS_TOTAL_ATTEMPTS",
        "doAssert offsetof(RcStatsCounterView, nssMax) == 187",
        "doAssert offsetof(RcStatsCounterView, bwMax) == 188",
        "doAssert offsetof(RcStatsCounterView, legacyRateMap) == RCS_RATE_MAP_L",
        "doAssert offsetof(RcStatsCounterView, fixedRate) == 198",
        "doAssert sizeof(RcStatsCounterView) == RC_STATS_SIZE",
        "template rcRateEntryAt(p: pointer): ptr RcRateEntryView",
        "template rcRateEntry(stats: pointer, idx: uint16): ptr RcRateEntryView",
        "template rcRateResetFields(stats: pointer, idx: uint16): ptr RcRateResetFieldsView",
        "template rcThroughputArray(tpArray: pointer): ptr UncheckedArray[uint32]",
        "template rcStatsCounters(stats: pointer): ptr RcStatsCounterView",
        "proc rcClearRateEntryTransientStats(stats: pointer; idx: uint16) {.inline.}",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let rateEntry = rcRateEntryAt(entry)",
        "let statsView = if stats != nil: rcStatsCounters(stats) else: nil",
        "let probEwma = rateEntry.probEwma",
        "let rateConfig = rateEntry.rateConfig",
        "let ampduLen = statsView.avgAmpduLen",
    ]:
        assert expected in calc_body

    for expected in [
        "let counters = rcStatsCounters(stats)",
        "counters.totalSuccess = counters.totalSuccess + 1",
        "counters.totalAttempts = counters.totalAttempts + 1",
        "while slotIdx < counters.retrySlots.len:",
        "let rateIdx = counters.retrySlots[slotIdx].rateIdx",
        "let entry = rcRateEntry(stats, rateIdx)",
        "entry.attempts = entryAttempts",
        "entry.failures = entryFailures",
        "if entry.attempts < entry.failures:",
        "let stage = counters.updateStage",
        "let retryLimit = counters.retryLimit",
    ]:
        assert expected in update_body

    for expected in [
        "let entry = rcRateEntry(stats, i.uint16)",
        "entry.attempts = 0",
        "entry.failures = 0",
    ]:
        assert expected in stats_body

    assert "let amsduLen = rcStatsCounters(rcStats).legacyRateMap" in amsdu_body
    assert "cast[ptr uint16](cast[uint](rcStats) + RCS_RATE_MAP_L)" not in amsdu_body

    for expected in [
        "let rc = rcStatsCounters(rcPtr)",
        "rc.fixedRate = 0xFFFF'u16",
        "var flags = rc.flags",
        "rc.flags = flags",
        "rc_update_bw_nss_max(staField40, rc.nssMax, rc.bwMax)",
        "rc.fixedRate = fixedRate",
    ]:
        assert expected in set_rate_body

    assert "rcClearRateEntryTransientStats(rcStats, i.uint16)" in bw_body

    for expected in [
        "let entry = rcRateEntry(stats, idx)",
        "var rateConfig = entry.rateConfig",
        "rcClearRateEntryTransientStats(stats, idx)",
        "entry.rateConfig = rateConfig",
    ]:
        assert expected in preamble_body

    for expected in [
        "let tp = rcThroughputArray(tpArray)",
        "let tp1 = tp[i]",
        "let tp0 = tp[i - 1]",
        "var tmp {.noinit.}: RcRateEntryView",
        "sizeof(RcRateEntryView).csize_t",
        "tp[i] = tp0",
        "tp[i - 1] = tp1",
    ]:
        assert expected in sort_body

    for forbidden in [
        "let entryPtr = cast[uint](entry)",
        "cast[ptr uint16](entryPtr + 8)",
        "cast[ptr uint16](entryPtr + 10)",
        "cast[ptr uint16](cast[uint](statsPtr) + RCS_AVG_AMPDU_LEN)",
        "let totalSuccess = rcU16(stats, RCS_TOTAL_SUCCESS)",
        "let totalAttempts = rcU16(stats, RCS_TOTAL_ATTEMPTS)",
        "var acOff: uint = 128",
        "let acEnd: uint = 160",
        "let entryBase = cast[uint](stats) + rateIdx.uint * RC_RATE_ENTRY_SIZE.uint",
        "cast[ptr uint16](entryBase + 4)",
        "cast[ptr uint16](entryBase + 6)",
        "rcU8(stats, RCS_UPDATE_STAGE)",
        "rcU8(stats, RCS_RETRY_LIMIT)",
    ]:
        assert forbidden not in calc_body
        assert forbidden not in update_body
        assert forbidden not in stats_body

    for forbidden in [
        "var entryOff = cast[uint](stats) + 4",
        "cast[ptr uint16](entryOff)[]",
        "cast[ptr uint16](entryOff + 2)[]",
        "entryOff += RC_RATE_ENTRY_SIZE.uint",
    ]:
        assert forbidden not in stats_body

    for forbidden in [
        "cast[ptr uint16](rcBase + 198)",
        "cast[ptr uint8](rcBase + 175)",
        "cast[ptr uint8](rcBase + 187)",
        "cast[ptr uint8](rcBase + 188)",
    ]:
        assert forbidden not in set_rate_body

    for forbidden in [
        "let rc = cast[uint](rcStats)",
        "let rc = cast[uint](stats)",
        "let entryBase = rc +",
        "cast[ptr uint8](entryBase + 6)",
        "cast[ptr uint8](entryBase + 7)",
        "cast[ptr uint16](entryBase + 0)",
        "cast[ptr uint8](entryBase + 5)",
        "rcU16(stats, idx.int * RC_RATE_ENTRY_SIZE + 10) = rateConfig",
    ]:
        assert forbidden not in bw_body
        assert forbidden not in preamble_body

    for forbidden in [
        "cast[ptr uint32](cast[uint](tpArray) + (i * 4).uint)",
        "cast[ptr uint32](cast[uint](tpArray) + ((i - 1) * 4).uint)",
        "var tmp {.noinit.}: array[12, uint8]",
        "12.csize_t",
    ]:
        assert forbidden not in sort_body

def test_wifi_vif_lookup_helper_uses_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc vif_mgmt_get_vif*", 1)[1].split(
        "proc vif_mgmt_get_first_ap_inf*", 1
    )[0]

    assert "return cast[pointer](vifChannelForIdx(vifIdx))" in body
    for forbidden in [
        "let vifTab = cast[uint](addr vif_info_tab[0])",
        "vifTab + vifIdx.uint * VIF_ENTRY_SIZE.uint",
    ]:
        assert forbidden not in body


def test_wifi_vif_add_key_uses_typed_key_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc vif_mgmt_add_key*", 1)[1].split(
        "proc vif_mgmt_del_key*", 1
    )[0]
    del_body = wifi_fw.rsplit("proc vif_mgmt_del_key*", 1)[1].split(
        "proc vif_mgmt_send_postponed_frame*", 1
    )[0]

    for expected in [
        "VifKeySlotTableOverlay {.packed.} = object",
        "doAssert offsetof(VifKeySlotTableOverlay, slots) == 528",
        "template vifKeySlotTable(vif: ptr VifChannelView): ptr VifKeySlotTableOverlay",
        "template vifKeySlot(vif: ptr VifChannelView, slot: uint): ptr VifKeySlotView",
        "template vifKeySlotPtr(vif: ptr VifChannelView, slot: uint): uint32",
        "let req = vifMgmtAddKeyParamView(param)",
        "let vif = vifChannelForIdx(keySlot)",
        "let keyView = vifKeySlot(vif, 0)",
        "let staReplay = vifKeySlot(vif, staIdx.uint)",
        "staReplay.replayCounters[i].pnLow = pnLo",
        "staReplay.replayCounters[i].pnHigh = pnHi",
        "let keyPtrs = vifKeyPointers(vif)",
        "keyPtrs.groupKeyPtr = vifKeySlotPtr(vif, 0)",
        "keyPtrs.defaultKeyPtr = vifKeySlotPtr(vif, 0)",
    ]:
        assert expected in wifi_fw if "template " in expected or "Overlay" in expected or "doAssert" in expected else expected in body

    for expected in [
        "doAssert offsetof(VifMgmtAddKeyParamView, tkipKeyMaterial) == 24",
        "doAssert offsetof(VifMgmtAddKeyParamView, pnLowBytes) == 44",
        "doAssert offsetof(VifMgmtAddKeyParamView, pnHighBytes) == 48",
        "doAssert offsetof(VifMgmtAddKeyParamView, cipherType) == 52",
        "doAssert offsetof(VifMgmtAddKeyParamView, keySlot) == 53",
        "doAssert offsetof(VifMgmtAddKeyParamView, spp) == 54",
        "doAssert offsetof(VifMgmtAddKeyParamView, hasRxPn) == 55",
        "proc vif_mgmt_add_key*(param: pointer, hwKeyIdx: uint8)",
    ]:
        assert expected in wifi_fw
    assert "keyView.keyIdx = hwKeyIdx" in body
    clear_idx = body.index("discard c_memset(cast[pointer](keyView), 0, 128.csize_t)")
    key_idx = body.index("keyView.keyIdx = hwKeyIdx")
    cipher_idx = body.index("keyView.cipherType = cipherType")
    assert clear_idx < key_idx < cipher_idx

    for expected in [
        "let vif = vifChannelAt(vifEntry)",
        "let keyView = vifKeySlot(vif, keySlotU)",
        "let keyPtrs = vifKeyPointers(vif)",
        "let thisKeyBase = vifKeySlotPtr(vif, keySlotU)",
        "let slotValid = vifKeySlot(vif, i).installed",
        "keyPtrs.defaultKeyPtr = vifKeySlotPtr(vif, i)",
        "let validFlag = vifKeySlot(vif, keySlotU + 4'u).installed",
    ]:
        assert expected in del_body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifOff = keySlot.uint * VIF_ENTRY_SIZE.uint",
        "let vifEntry = vifBase + vifOff",
        "let keyView = vifKeySlotAt(vifEntry, 0)",
        "let vifEntry = cast[uint](vif)",
        "let reorderBase = vifEntry + (staIdx.uint * 10 + 33) * 16",
        "let slotAddr = reorderBase + i.uint * 16",
        "cast[ptr uint32](slotAddr + 0)[]",
        "cast[ptr uint32](slotAddr + 4)[]",
        "vifOff + vifBase",
        "let keyPtrs = vifKeyPointersAt(vifEntry)",
        "let keyOffset = keySlotU * 160 + 528",
        "let thisKeyBase = vif + keyOffset",
        "cast[uint32](vif + i * 160 + 528)",
        "cast[ptr uint8](vif + keySlotU * 160 + 1323 - 528)",
    ]:
        assert forbidden not in body
        assert forbidden not in del_body


def test_wifi_vif_management_uses_typed_timer_and_bssid_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    init_body = wifi_fw.rsplit("proc vif_mgmt_init*", 1)[1].split(
        "proc vif_mgmt_register*", 1
    )[0]
    register_body = wifi_fw.rsplit("proc vif_mgmt_register*", 1)[1].split(
        "proc vif_mgmt_unregister*", 1
    )[0]
    unregister_body = wifi_fw.rsplit("proc vif_mgmt_unregister*", 1)[1].split(
        "proc vif_mgmt_add_key*", 1
    )[0]

    for expected in [
        "vif0View.beaconTimeoutTimer.callback = bcnToEvtAddr",
        "vif0View.beaconTimeoutTimer.env = cast[uint32](vif0)",
        "vif1View.beaconTimeoutTimer.callback = bcnToEvtAddr",
        "vif1View.beaconTimeoutTimer.env = cast[uint32](vif1Entry)",
    ]:
        assert expected in init_body

    for expected in [
        "vif.tbttNode.vifIdx = vifIdx",
        "var vifIdx = 0'u8",
        "while vifIdx < MAX_VIFS.uint8 and vifChannelForIdx(vifIdx) != vif:",
        "vif.tbttTimer.env = pointerAddrU32(vifEntry)",
        "vif.tbttTimer.callback = staTbttCb",
        "vif.keepAliveTimer.callback = bcnTimeoutCb",
        "vif.keepAliveTimer.env = pointerAddrU32(vifEntry)",
        "vif.securityTimer.callback = dataTimeoutCb",
        "vif.securityTimer.env = pointerAddrU32(vifEntry)",
    ]:
        assert expected in register_body

    for expected in [
        "let otherVif = vifChannelForIdx(otherVifIdx)",
        "otherVif.currentBssid[0].uint32",
        "otherVif.currentBssid[5].uint32 shl 8",
        "vif.beaconTimeoutTimer.callback = cast[pointer](vif_mgmt_bcn_to_evt)",
        "vif.beaconTimeoutTimer.env = pointerAddrU32(vifEntry)",
    ]:
        assert expected in unregister_body

    for forbidden in [
        "cast[ptr pointer](vif0 + 44)",
        "cast[ptr pointer](vif0 + 48)",
        "cast[ptr pointer](vif1Entry + 44)",
        "cast[ptr pointer](vif1Entry + 48)",
        "cast[ptr uint8](vifEntry + 76)",
        "cast[ptr uint32](vifEntry + 32)",
        "cast[ptr pointer](vifEntry + 28)",
        "cast[ptr pointer](vifEntry + 128 + 16)",
        "cast[ptr pointer](vifEntry + 128 + 20)",
        "cast[ptr pointer](vifEntry + 128 + 48)",
        "cast[ptr pointer](vifEntry + 128 + 52)",
        "cast[ptr uint16](vifEntry + 192)",
        "cast[ptr uint32](otherVif + 56)",
        "cast[ptr uint16](otherVif + 60)",
        "cast[ptr pointer](vifEntry + 44)",
        "cast[ptr pointer](vifEntry + 48)",
    ]:
        assert forbidden not in init_body
        assert forbidden not in register_body
        assert forbidden not in unregister_body

    for forbidden in [
        "let vifTabBase = cast[uint](addr vif_info_tab[0])",
        "let rawDiff = vifEntry - vifTabBase",
        "rawDiff div VIF_ENTRY_SIZE.uint",
    ]:
        assert forbidden not in register_body


def test_wifi_vif_overlay_helpers_use_field_anchors():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    for expected in [
        "doAssert offsetof(VifChannelView, reserved344) == 344",
        "doAssert offsetof(VifChannelView, edcaParams) == 456",
        "doAssert offsetof(VifSecurityOverlay, connected) == 0",
        "doAssert offsetof(VifHtCapabilitiesOverlay, capInfo) == 0",
        "doAssert offsetof(VifHtOperationOverlay, flags) == 0",
        "template vifSecurity(vif: ptr VifChannelView): ptr VifSecurityOverlay =\n  cast[ptr VifSecurityOverlay](addr vif.edcaParams[32])",
        "template vifHtCapabilities(vif: ptr VifChannelView): ptr VifHtCapabilitiesOverlay =\n  cast[ptr VifHtCapabilitiesOverlay](addr vif.reserved344[4])",
        "template vifHtOperation(vif: ptr VifChannelView): ptr VifHtOperationOverlay =\n  cast[ptr VifHtOperationOverlay](addr vif.edcaParams[20])",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "cast[ptr VifSecurityOverlay](cast[uint](vif) + 488)",
        "cast[ptr VifHtCapabilitiesOverlay](cast[uint](vif) + 348)",
        "cast[ptr VifHtOperationOverlay](cast[uint](vif) + 476)",
    ]:
        assert forbidden not in wifi_fw


def test_wifi_sta_bandwidth_overlay_uses_field_anchor():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    for expected in [
        "doAssert offsetof(StaInfoView, reserved74) == 74",
        "doAssert sizeof(StaBandwidthOverlay) == 56",
        "doAssert offsetof(StaBandwidthOverlay, rateInfoPtr) == 0",
        "template staBandwidthOverlay(sta: ptr StaInfoView): ptr StaBandwidthOverlay =\n  cast[ptr StaBandwidthOverlay](addr sta.reserved74[2])",
    ]:
        assert expected in wifi_fw

    assert "cast[ptr StaBandwidthOverlay](cast[uint](sta) + 76'u)" not in wifi_fw


def test_wifi_mm_sta_delete_uses_vif_overlay_pointer():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc mm_sta_del*(staIdx: uint8)", 1)[1].split(
        "proc mm_check_rssi*", 1
    )[0]

    assert "let vif = vifChannelForIdx(vifIdx)" in body
    assert "apm_tx_int_ps_clear(cast[pointer](vif), cast[uint8](psIdx))" in body
    assert "template mmEnvClearKeepAliveTimestampByte1()" in wifi_fw
    assert "mm.keepAliveTimestamp = mm.keepAliveTimestamp and not 0x0000FF00'u32" in wifi_fw
    assert "mmEnvClearKeepAliveTimestampByte1()  # clear byte at mm_env+41" in body
    assert "let vifEntry = cast[uint](vif)" not in body
    assert "apm_tx_int_ps_clear(cast[pointer](vifEntry), cast[uint8](psIdx))" not in body
    assert "cast[ptr UncheckedArray[uint8]](addr mmEnvView().keepAliveTimestamp)[1]" not in wifi_fw
    assert "mmEnvKeepAliveTimestampByte1() = 0" not in body


def test_wifi_ps_check_frame_uses_typed_mac_header():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc ps_check_frame*", 1)[1].split(
        "proc ps_check_tx_frame*", 1
    )[0]

    for expected in [
        "let hdr = macDataFrameAt(rxHdr)",
        "let frameCtrl = hdr.frameControl",
        "let addr1Group = hdr.addr1[0] and 1'u8",
        "if addr1Group != 0:",
        "Group-addressed frame: check if protected frame",
    ]:
        assert expected in body

    for forbidden in [
        "let fromDs = cast[ptr UncheckedArray[uint8]](rxHdr)[4]",
        "if (fromDs and 1) != 0:",
        "Check FromDS bit (bit 0 of rxHdr[4])",
    ]:
        assert forbidden not in body


def test_wifi_txu_push_uses_typed_vif_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc txu_cntrl_push*(param: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txu_cntrl_cfm*", 1
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let vifEntry = cast[pointer](vif)",
        "vif.psFlags = 1",
        "if not doDrop and not txl_cntrl_tx_check(vifEntry):",
        "vif.psFlags = 0",
    ]:
        assert expected in body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntryU = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "vifChannelAt(vifEntryU).psFlags",
        "txl_cntrl_tx_check(cast[pointer](vifEntryU))",
    ]:
        assert forbidden not in body


def test_wifi_null_frame_callbacks_use_pointer_addr_helper():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    beacon_body = wifi_fw.rsplit("proc mm_check_beacon*", 1)[1].split(
        "proc chan_bcn_detect_start*", 1
    )[0]
    ps_body = wifi_fw.rsplit("proc ps_set_mode*", 1)[1].split(
        "proc ps_check_tx_status_part0*", 1
    )[0]

    assert "pointerAddrU32(vifEntry)" in beacon_body
    assert "let csaChan = addr chanCtxtAt(csaCtxPtr).channel" in beacon_body
    assert "let csaCtxFreq = csaChan.primFreq" in beacon_body
    assert "dsParamFreq(csaChan.band, dsParamSetIeAt(dsIe))" in beacon_body
    assert "let vifU = cast[uint](vif)" not in beacon_body
    assert "cast[uint32](vifU)" not in beacon_body
    assert "let csaCtxU = cast[uint](csaCtxPtr)" not in beacon_body
    assert "cast[ptr uint16](csaCtxU + 6)" not in beacon_body
    assert "cast[ptr uint8](csaCtxU + 4)" not in beacon_body

    assert "pointerAddrU32(vifNode)" in ps_body
    assert "let vifU = cast[uint](vif)" not in ps_body
    assert "cast[uint32](vifU)" not in ps_body


def test_wifi_ps_set_mode_uses_typed_vif_confirmation_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    ps_body = wifi_fw.rsplit("proc ps_set_mode*", 1)[1].split(
        "proc ps_check_beacon*", 1
    )[0]

    for expected in [
        "let vifEntryDisable = cast[pointer](vifChannelForIdx(vifIdxForDisable))",
        "discard ps_disable_cfm_handle(vifEntryDisable)",
        "let vifEntryForPs = cast[pointer](vifChannelForIdx(vifIdxForPs))",
        "ps_enable_cfm_handle(vifEntryForPs)",
    ]:
        assert expected in ps_body

    for forbidden in [
        "cast[uint](addr vif_info_tab[0]) +",
        "vifIdxForDisable.uint * VIF_ENTRY_SIZE.uint",
        "vifIdxForPs.uint * VIF_ENTRY_SIZE.uint",
    ]:
        assert forbidden not in ps_body


def test_wifi_null_frame_and_postponed_service_use_typed_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    null_body = wifi_fw.split(
        "proc txl_frame_send_null_frame*(staIdx: uint8, cfmCallback: pointer, cfmArg: uint32): uint8 {.exportc, cdecl, discardable.} =",
        1,
    )[1].split(
        "const WifiTxFrameSuccessfulBit", 1
    )[0]
    qosnull_body = wifi_fw.rsplit(
        "proc txl_frame_send_qosnull_frame*(staIdx: uint8, qosCtrl: uint16,",
        1,
    )[1].split(
        "proc txl_frame_send_selfcts_frame*", 1
    )[0]
    service_body = wifi_fw.split(
        "proc wifi_nimfw_service_sta_postponed*(limit: uint32): uint32 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rfc_channel_ops*", 1
    )[0]
    count_body = wifi_fw.split(
        "proc wifi_nimfw_actual_postponed_count(): uint32 =",
        1,
    )[1].split(
        "proc wifi_nimfw_reconcile_postponed_count", 1
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let vifEntry = cast[pointer](vif)",
        "tpc_update_frame_tx_power(vifEntry, frame)",
    ]:
        assert expected in null_body
        assert expected in qosnull_body

    for expected in [
        "let vif = vifChannelForIdx(i)",
        "let vifEntry = cast[pointer](vif)",
        "let staEntry = cast[pointer](staInfoForIdx(vif.staIdx))",
        "if txl_cntrl_tx_check(vifEntry):",
        "let n = sta_mgmt_send_postponed_frame(vifEntry, staEntry, remaining)",
    ]:
        assert expected in service_body

    assert "for i in 0'u8 ..< STA_INFO_TAB_ENTRIES.uint8:" in count_body
    assert "let sta = staInfoForIdx(i)" in count_body
    assert "total += co_list_cnt(addr sta.postponedList)" in count_body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "vifChannelAt(vifEntry)",
        "cast[uint](addr vif_info_tab[0]) +",
        "cast[uint](addr sta_info_tab[0]) +",
    ]:
        assert forbidden not in null_body
        assert forbidden not in qosnull_body
        assert forbidden not in service_body
        assert forbidden not in count_body


def test_wifi_frame_active_scan_uses_typed_sta_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split("proc txl_frame_desc_active", 1)[1].split(
        "proc txl_frame_rebuild_free_list", 1
    )[0]

    assert "let sta = staInfoForIdx(i.uint8)" in body
    assert "txl_frame_list_contains(addr sta.postponedList, p)" in body
    for forbidden in [
        "let staBase = cast[uint](addr sta_info_tab[0])",
        "staInfoAt(staBase + i.uint * STA_ENTRY_SIZE.uint)",
        "cast[uint](addr sta_info_tab[0]) +",
    ]:
        assert forbidden not in body


def test_wifi_tpc_update_vif_tx_power_uses_typed_sta_list_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc tpc_update_vif_tx_power*", 1)[1].split(
        "proc tpc_get_vif_tx_power_vs_rate*", 1
    )[0]

    assert "var staNode = vif.postponedStaHead" in body
    assert "let sta = staInfoAt(staNode)" in body
    assert "sta.mmFlagsBytes[0] = sta.mmFlagsBytes[0] or 0x10" in body
    assert "staNode = cast[pointer](sta.link.next)" in body
    assert "let vifU = cast[uint](vifEntry)" not in body
    assert "cast[ptr pointer](vifU + 340)" not in body
    assert "cast[ptr uint8](staNodeU + 334)" not in body


def test_wifi_ap_start_uses_vif_overlay_for_channel_and_security():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc apm_start_req_handler*", 1)[1].split(
        "proc apm_stop_req_handler*", 1
    )[0]
    cfm_body = wifi_fw.rsplit("proc apm_start_cfm*", 1)[1].split(
        "proc apm_stop*", 1
    )[0]
    bss_body = wifi_fw.rsplit("proc apm_set_bss_param*", 1)[1].split(
        "proc apm_send_next_bss_param*", 1
    )[0]
    bcn_body = wifi_fw.rsplit("proc apm_bcn_set*", 1)[1].split(
        "proc apm_sta_add*", 1
    )[0]

    assert "template vifChannelTypeByte(vif: ptr VifChannelView): ptr uint8 =\n  cast[ptr uint8](addr vif.flags)" in wifi_fw
    assert "vifChannelTypeByte(vif)[] = req.channel.chanType" in body
    assert "let embedded = apm_embedded_enabled(cast[pointer](vif))" in body
    assert "let sec = vifSecurity(vif)" in body
    assert "let chan = cast[ptr ScanChannelEntry](chanPtrForTpc)" in body
    assert "tpcPowerByte = cast[ptr uint8](addr chan.txPower)[]" in body
    assert "tpc_update_vif_tx_power(\n     cast[pointer](vif)," in body
    assert "let vifBase = cast[uint](vif)" not in body
    assert "cast[ptr uint8](vifBase + 4)" not in body
    assert "cast[ptr uint8](cast[uint](chanPtrForTpc) + 4)" not in body
    assert "vifSecurityAt(vifBase)" not in body
    assert "cast[pointer](vifBase)" not in body

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "vifKeyPointers(vif).flags = apInfo.beaconRateInfo",
        "vif.psBaCounter = 0",
        "vif.apStartBeaconInterval = apInfo.vifBeaconInterval",
    ]:
        assert expected in cfm_body

    for forbidden in [
        "let vifEntry = vifEntryAddr(vifIdx)",
        "let vif = vifChannelAt(vifEntry)",
        "vifKeyPointersAt(vifEntry).flags",
    ]:
        assert forbidden not in cfm_body

    assert "let vif = vifChannelForIdx(vifIdx)" in bss_body
    assert "c_memcpy(addr req.bssid[0], cast[pointer](addr vif.macAddr[0]), 6)" in bss_body
    assert "let vif = vifChannelForIdx(instNbr)" in bcn_body
    assert "apm_embedded_enabled(cast[pointer](vif))" in bcn_body

    for body_part in [bss_body, bcn_body]:
        for forbidden in [
            "let vifTab = cast[uint](addr vif_info_tab[0])",
            "let vifTabBase = cast[uint](addr vif_info_tab[0])",
            "let vifEntry = vifTab + vifIdx.uint * VIF_ENTRY_SIZE.uint",
            "let vifEntry = vifTabBase + instNbr.uint * VIF_ENTRY_SIZE.uint",
            "let vif = vifChannelAt(vifEntry)",
            "apm_embedded_enabled(cast[pointer](vifEntry))",
        ]:
            assert forbidden not in body_part


def test_wifi_mm_state_handlers_use_vif_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    ps_options_body = wifi_fw.rsplit("proc mm_set_ps_options_req_handler*", 1)[1].split(
        "proc mm_set_vif_state_cfm_handler*", 1
    )[0]
    vif_state_body = wifi_fw.rsplit("proc mm_set_vif_state_cfm_handler*", 1)[1].split(
        "proc mm_bcn_change_req_handler*", 1
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "vif.listenInterval = req.listenInterval",
        "vif.psOptions = req.options",
    ]:
        assert expected in ps_options_body

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let staIdx = vif.staIdx",
        "let keyPointerFlags = vifKeyPointers(vif).flags",
        "let sec = vifSecurity(vif)",
    ]:
        assert expected in vif_state_body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0]) + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifBase)",
        "vifChannelAt(vifBase).staIdx",
        "vifKeyPointersAt(vifBase).flags",
        "vifSecurityAt(vifBase)",
    ]:
        assert forbidden not in ps_options_body
        assert forbidden not in vif_state_body


def test_wifi_tim_update_uses_vif_overlay_fields():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc mm_tim_update_proceed*", 1)[1].split(
        "proc mm_connection_loss_ind_handler*", 1
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "vif.timFlags = 1",
        "vif.timCount = timCount + 1",
        "vif.timMin = alignedByte",
        "vif.timMax = byteIdx.uint8",
        "vif.timLength = timLen",
    ]:
        assert expected in body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0]) + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifBase)",
        "cast[ptr uint8](vifBase + 330)",
        "cast[ptr uint16](vifBase + 320)",
        "cast[ptr uint8](vifBase + 328)",
        "cast[ptr uint8](vifBase + 329)",
        "cast[ptr uint16](vifBase + 318)",
    ]:
        assert forbidden not in body


def test_wifi_traffic_detection_timer_uses_vif_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc td_timer_end*", 1)[1].split(
        "proc phyif_utils_decode*", 1
    )[0]

    for expected in [
        "let vifIdx = td.vifIdx",
        "td.clearTrafficCounters()",
        "let vif = vifChannelForIdx(vifIdx)",
        "let vifConnected = vif.chanCtxt",
        "td.endActive = isActive",
    ]:
        assert expected in body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0]) + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vifConnected = vifChannelAt(vifBase).chanCtxt",
    ]:
        assert forbidden not in body


def test_wifi_txl_buffer_env_uses_typed_backup_queue_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    helpers_body = wifi_fw.split("template txlBufferEnvView()", 1)[1].split(
        "template hostTxMacHdrAddr", 1
    )[0]
    reinit_body = wifi_fw.split("proc txl_buffer_reinit*", 1)[1].split(
        "proc txl_buffer_reset*", 1
    )[0]
    reset_body = wifi_fw.split("proc txl_buffer_reset*", 1)[1].split(
        "proc txlApplyEapolRetryPolicy", 1
    )[0]
    backup_helpers = wifi_fw.split("template txBackupQueueHeadPtr", 1)[1].split(
        "template staInfoAt", 1
    )[0]
    txl_buffer_bodies = helpers_body + reinit_body + reset_body + backup_helpers

    for expected in [
        "TxlBackupQueueView {.packed.} = object",
        "first*: pointer",
        "last*: pointer",
        "TxlBufferEnvView {.packed.} = object",
        "reserved00*: array[180, uint8]",
        "backupQueues*: array[5, TxlBackupQueueView]",
        "doAssert sizeof(TxlBackupQueueView) == 8",
        "doAssert offsetof(TxlBackupQueueView, first) == 0",
        "doAssert offsetof(TxlBackupQueueView, last) == 4",
        "doAssert offsetof(TxlBufferEnvView, backupQueues) == 180",
        "4 * sizeof(TxlBackupQueueView) == 212",
        "offsetof(TxlBackupQueueView, last) == 216",
        "template txlBufferEnvView(): ptr TxlBufferEnvView",
        "addr txlBufferEnvView().backupQueues[queueIdx].first",
        "addr txlBufferEnvView().backupQueues[queueIdx].last",
    ]:
        assert expected in wifi_fw

    assert "txlBufferEnvView().backupQueues[0].first = nil" in reinit_body
    assert "txlBufferEnvView().backupQueues[0].last = nil" in reinit_body
    assert "txlBufferEnvView().backupQueues[0].first = nil" in reset_body
    assert "txlBufferEnvView().backupQueues[0].last = nil" in reset_body

    for forbidden in [
        "cast[ptr pointer](cast[uint](addr txl_buffer_env[0]) +",
        "cast[ptr uint32](cast[uint](addr txl_buffer_env[0]) + 180'u)",
        "cast[ptr uint32](cast[uint](addr txl_buffer_env[0]) + 184'u)",
    ]:
        assert forbidden not in txl_buffer_bodies


def test_wifi_txl_payload_backup_uses_typed_link_rate_fields():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.split(
        "proc txl_payload_handle_backup*(param: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_transmit_trigger*", 1
    )[0]
    tx_trigger_body = wifi_fw.split(
        "proc txl_transmit_trigger*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_current_desc_for_ac", 1
    )[0]

    for expected in [
        "let forceRate = hostTxRateTemplate(forceLink)",
        "forceRate.txPower = NimFwForcedMgmtTxPower.int32",
        "forceRate.word40 = NimFwForcedMgmtTxPower",
        "forceRate.word44 = NimFwForcedMgmtTxPower",
        "forceRate.word48 = NimFwForcedMgmtTxPower",
        "let vif = vifChannelForIdx(actual.vifIdx)",
        "let protFlags = vif.timFlags",
        "vif.timFlags = protFlags or 2",
        "vif.timFlags = protFlags and not 2'u8",
        "thd.word56 = linkDesc.word308",
        "thd.word36 = linkDesc.word312",
        "template hostTxThdAt(p: pointer): ptr HostTxThdEntryView",
        "hostTxThdAt(listFirst).next = thdLink",
        "nimFwTrace2U32(\"[WIFI-NIMFW] pay_rate \",\n                         linkDesc.word308,\n                         linkDesc.word312)",
    ]:
        assert expected in wifi_fw if expected.startswith("template ") else expected in body

    assert "let secStatus = cast[int32](hostTxHwDescAt(secThd).controlFlags)" in tx_trigger_body

    for forbidden in [
        "template hostTxLinkWord(",
        "template hostTxLinkWordAt(",
        "hostTxLinkWord(",
        "hostTxLinkWordAt(",
        "cast[ptr uint32](cast[uint](link) + byteOff)",
        "hostTxLinkWordAt(forceLink, 292'u)",
        "hostTxLinkWordAt(forceLink, 296'u)",
        "hostTxLinkWordAt(forceLink, 300'u)",
        "hostTxLinkWordAt(forceLink, 304'u)",
        "cast[ptr pointer](cast[uint](listFirst) + 4)",
    ]:
        assert forbidden not in wifi_fw

    assert "cast[ptr int32](cast[uint](secThd) + 60)" not in tx_trigger_body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifEntry)",
    ]:
        assert forbidden not in body


def test_wifi_txl_env_dump_uses_typed_descriptor_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    dump_body = wifi_fw.split(
        "proc txl_cntrl_env_dump*() {.exportc, cdecl, noinline.} =",
        1,
    )[1].split(
        "proc txl_payload_handle_backup*", 1
    )[0]
    push_int_body = wifi_fw.split(
        "proc txl_cntrl_push_int*(param: pointer, ac: uint8): uint8 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_cntrl_push_int_force*", 1
    )[0]

    for expected in [
        "link*: CoListHdr",
        "descWord4*: uint32",
        "doAssert offsetof(HostTxDescView, link) == 0",
        "doAssert offsetof(HostTxDescView, descWord4) == 4",
        "TxDumpRateDescView {.packed.} = object",
        "policy0*: array[4, uint32]",
        "policy1*: array[4, uint32]",
        "TxDumpBufferDescView {.packed.} = object",
        "template txDumpRateDescAt(p: pointer): ptr TxDumpRateDescView",
        "template txDumpBufferDescAt(p: pointer): ptr TxDumpBufferDescView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let curTrace = chanCtxtAt(curCtxtTrace)",
        "cur22Trace = curTrace.status",
        "cur23Trace = curTrace.idx",
        "cur25Trace = curTrace.altIdx",
    ]:
        assert expected in push_int_body

    for expected in [
        "let desc = hostTxDescAt(curDesc)",
        "let thd = desc.hwDesc",
        "let hw = hostTxHwDescAt(thd)",
        "let thdStatus = hw.confirmStatus",
        "curDesc = desc.link.next",
        "let descW4 = desc.descWord4",
        "let thdDataLen = hw.frameLen",
        "let thdW56 = hw.word56",
        "let thdW60 = hw.controlFlags",
        "let rateThdPtr = hw.chainedThd",
        "let rate = txDumpRateDescAt(rateThdPtr)",
        "for polVal in rate.policy0:",
        "for polVal in rate.policy1:",
        "nextRateThd = txDumpRateDescAt(nextRateThd).next",
        "let sub = txDumpBufferDescAt(subDesc)",
        "subDesc = sub.next",
    ]:
        assert expected in dump_body

    for forbidden in [
        "let curUTrace = cast[uint](curCtxtTrace)",
        "cast[ptr uint8](curUTrace + 22)",
        "cast[ptr uint8](curUTrace + 23)",
        "cast[ptr uint8](curUTrace + 25)",
    ]:
        assert forbidden not in push_int_body

    for forbidden in [
        "let curU = cast[uint](curDesc)",
        "cast[ptr pointer](curU + 112)",
        "cast[ptr pointer](curU)",
        "cast[ptr uint32](curU + 4)",
        "let thdU = cast[uint](thd)",
        "cast[ptr uint32](thdU + 28)",
        "cast[ptr uint32](thdU + 56)",
        "cast[ptr uint32](thdU + 60)",
        "cast[ptr pointer](thdU + 40)",
        "let rThdU = cast[uint](rateThdPtr)",
        "cast[ptr uint32](rThdU +",
        "let polAddr =",
        "let subU = cast[uint](subDesc)",
        "cast[ptr uint32](subU +",
        "cast[ptr pointer](subU + 4)",
    ]:
        assert forbidden not in dump_body


def test_wifi_disconnect_deauth_uses_typed_frame_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc sm_disconnect*(param: pointer)", 1)[1].split(
        "proc sm_delete_resources*", 1
    )[0]

    for expected in [
        "let ci = connectInfoView(smConnInfo)",
        "let desc = hostTxDescAt(txFrame)",
        "let hdr = hostTxDataHeader(desc)",
        "let frameBodyPtr = cast[pointer](hdr)",
        "hdr.seqCtrl = seqCtrl",
        "c_memcpy(addr hdr.addr1[0], addr ci.bssid[0], 6.csize_t)",
        "c_memcpy(addr hdr.addr2[0],",
        "c_memcpy(addr hdr.addr3[0], addr ci.bssid[0], 6.csize_t)",
        "desc.vifIdx = staIdx",
        "desc.staInfoIdx = vif.staIdx",
        "desc.callback = cast[pointer](sm_disconnect_deauth_cfm)",
        "let fcD = hdr.frameControl.uint32",
    ]:
        assert expected in body

    for forbidden in [
        "cast[pointer](cast[uint](txFrame) + 348)",
        "cast[uint](smConnInfo) + 4",
        "cast[pointer](cast[uint](txFrame) + 352)",
        "cast[pointer](cast[uint](txFrame) + 358)",
        "cast[pointer](cast[uint](txFrame) + 364)",
        "cast[ptr uint8](cast[uint](txFrame) + 47)",
        "cast[ptr uint8](cast[uint](txFrame) + 49)",
        "cast[ptr pointer](cast[uint](txFrame) + 208)",
        "cast[ptr uint8](cast[uint](frameBodyPtr) + 1)",
    ]:
        assert forbidden not in body


def test_wifi_sm_delete_resources_does_not_emit_host_indications():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc sm_delete_resources*", 1)[1].split(
        "proc sm_auth_assoc_send_according_chan*", 1
    )[0]

    for expected in [
        "status*: uint16",
        "reason*: uint16",
        "doAssert SmDisconnectIndPayloadSize == 12'u32",
        "Host indications are sent by sm_connect_ind or",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "ke_msg_alloc(SM_DISCONNECT_IND",
        "ke_msg_alloc(SM_CONNECT_IND_MSG",
        "ke_msg_send(discInd)",
        "ke_msg_send(connInd)",
    ]:
        assert forbidden not in body


def test_wifi_sm_deauth_send_uses_typed_frame_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc sm_deauth_send*", 1)[1].split(
        "proc sm_auth_send*", 1
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let desc = hostTxDescAt(frame)",
        "tpc_update_frame_tx_power(cast[pointer](vif), frame)",
        "let link = hostTxLinkDescAt(desc.bufDesc)",
        "let hdr = hostTxDataHeader(desc)",
        "hdr.frameControl = 0x00C0'u16",
        "hdr.duration = 0",
        "c_memcpy(addr hdr.addr1[0], bssidPtr, 6.csize_t)",
        "c_memcpy(addr hdr.addr2[0],",
        "c_memcpy(addr hdr.addr3[0], bssidPtr, 6.csize_t)",
        "hdr.seqCtrl = txl_get_seq_ctrl()",
        "desc.callbackArg = cast[pointer](vif)",
        "let bodyPtr = cast[pointer](addr link.macHeader[sizeof(MacDataFrameHeaderView)])",
        "let txDesc = hostTxHwDescAt(desc.hwDesc)",
    ]:
        assert expected in body

    for forbidden in [
        "let macHdr =",
        "cast[ptr uint8](macHdr +",
        "cast[pointer](macHdr +",
        "cast[uint](hdr) + sizeof(MacDataFrameHeaderView).uint",
        "let vifTab = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifTab + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifEntry)",
        "tpc_update_frame_tx_power(cast[pointer](vifEntry), frame)",
        "desc.callbackArg = cast[pointer](vifEntry)",
    ]:
        assert forbidden not in body


def test_wifi_sm_handle_connection_uses_typed_frame_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc sm_handle_connection*", 1)[1].split(
        "proc sm_disconnect_process*", 1
    )[0]

    for expected in [
        "let desc = hostTxDescAt(frame)",
        "let vif = vifChannelForIdx(vifIdx)",
        "tpc_update_frame_tx_power(cast[pointer](vif), frame)",
        "let link = hostTxLinkDescAt(desc.bufDesc)",
        "let hdr = hostTxDataHeader(desc)",
        "hdr.frameControl = 0x00C0'u16",
        "hdr.duration = 0",
        "c_memcpy(addr hdr.addr1[0], staMac, 6.csize_t)",
        "c_memcpy(addr hdr.addr2[0],",
        "c_memcpy(addr hdr.addr3[0], staMac, 6.csize_t)",
        "hdr.seqCtrl = seqCtrl",
        "let fc = hdr.frameControl",
        "let macHdrPtr = cast[pointer](hdr)",
        "let bodyStart = cast[pointer](addr link.macHeader[bodyOffset])",
        "let txDesc = hostTxHwDescAt(desc.hwDesc)",
        "txDesc.payloadEnd = payloadLen - 1 + totalLen.uint32",
        "txDesc.frameLen = totalLen.uint32 + 4",
        "desc.callbackArg = cast[pointer](vif)",
    ]:
        assert expected in body

    for forbidden in [
        "let macHdr = hostTxMacHdrAddr(desc)",
        "cast[ptr uint8](macHdr + 0)",
        "cast[ptr uint8](macHdr + 1)",
        "cast[ptr uint8](macHdr + 2)",
        "cast[ptr uint8](macHdr + 3)",
        "cast[pointer](macHdr + 4)",
        "cast[pointer](macHdr + 10)",
        "cast[pointer](macHdr + 16)",
        "cast[ptr uint8](macHdr + 22)",
        "cast[ptr uint8](macHdr + 23)",
        "cast[pointer](macHdr + 0)",
        "cast[pointer](macHdr + bodyOffset)",
        "cast[ptr uint32](txDesc + 20)",
        "cast[ptr uint32](txDesc + 24)",
        "cast[ptr uint32](txDesc + 28)",
        "let vifTab = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifTab + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifEntry)",
        "cast[pointer](vifEntry)",
    ]:
        assert forbidden not in body


def test_wifi_supplicant_deauth_uses_typed_frame_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc sm_handle_supplicant_result*", 1)[1].split(
        "proc sm_send_sa_query*", 1
    )[0]

    for expected in [
        "let desc = hostTxDescAt(frame)",
        "let vif = vifChannelForIdx(vifIdx)",
        "tpc_update_frame_tx_power(cast[pointer](vif), frame)",
        "let link = hostTxLinkDescAt(desc.bufDesc)",
        "let hdr = hostTxDataHeader(desc)",
        "let vif = vifChannelForIdx(vifIdx)",
        "tpc_update_frame_tx_power(cast[pointer](vif), frame)",
        "hdr.frameControl = 0x00C0'u16",
        "hdr.duration = 0",
        "c_memcpy(addr hdr.addr1[0],",
        "c_memcpy(addr hdr.addr2[0],\n                   addr vif.macAddr[0], 6.csize_t)",
        "c_memcpy(addr hdr.addr3[0],",
        "hdr.seqCtrl = seqCtrl",
        "desc.callback = cast[pointer](sm_supplicant_deauth_cfm)",
        "desc.callbackArg = cast[pointer](vif)",
        "desc.vifIdx = vifIdx",
        "desc.staInfoIdx = result_code",
        "let thd = hostTxHwDescAt(desc.hwDesc)",
        "thd.payloadEnd = payloadStart + 23 + bodyLen",
        "thd.frameLen = bodyLen + 28",
    ]:
        assert expected in body

    for forbidden in [
        "cast[ptr pointer](cast[uint](frame) + 108)",
        "cast[ptr pointer](cast[uint](frame) + 112)",
        "cast[ptr pointer](cast[uint](frame) + 208)",
        "cast[ptr pointer](cast[uint](frame) + 212)",
        "cast[ptr uint8](cast[uint](frame) + 47)",
        "cast[ptr uint8](cast[uint](frame) + 49)",
        "cast[ptr uint8](frameHdrBase + 348)",
        "cast[ptr uint8](frameHdrBase + 349)",
        "cast[ptr uint8](frameHdrBase + 350)",
        "cast[ptr uint8](frameHdrBase + 351)",
        "cast[pointer](frameHdrBase + 352)",
        "cast[pointer](frameHdrBase + 358)",
        "cast[pointer](frameHdrBase + 364)",
        "cast[ptr uint8](frameHdrBase + 370)",
        "cast[ptr uint8](frameHdrBase + 371)",
        "cast[pointer](frameHdrBase + 372)",
        "cast[pointer](vifEntryBase + 80)",
        "let vifTab = cast[uint](addr vif_info_tab[0])",
        "let vifEntryBase = vifTab + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifEntryBase)",
        "tpc_update_frame_tx_power(cast[pointer](vifEntryBase), frame)",
        "desc.callbackArg = cast[pointer](vifEntryBase)",
        "cast[ptr uint32](thdU + 20)",
        "cast[ptr uint32](thdU + 24)",
        "cast[ptr uint32](thdU + 28)",
    ]:
        assert forbidden not in body


def test_wifi_auth_assoc_tx_builders_use_typed_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    auth_body = wifi_fw.rsplit(
        "proc sm_auth_send*(authSeqNum: uint16, statusCode: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc sm_auth_send_pre*", 1
    )[0]
    assoc_body = wifi_fw.rsplit(
        "proc sm_assoc_req_send*(param: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc sm_assoc_req_send_pre*", 1
    )[0]

    assert "doAssert offsetof(VifChannelView, macAddr) == 80" in wifi_fw
    assert "doAssert offsetof(VifChannelView, bssid) == 380" in wifi_fw
    assert "doAssert offsetof(VifHtCapabilitiesOverlay, capInfo) == 0" in wifi_fw
    assert "let assocInfo = cast[pointer](vifHtCapabilities(vif))" in assoc_body
    assert "let assocInfo = cast[pointer](vifEntry + 348)" not in assoc_body

    for expected in [
        "AuthBodyTraceView {.packed.} = object",
        "doAssert sizeof(AuthBodyTraceView) == 8",
        "doAssert offsetof(AuthBodyTraceView, challengeTag) == 6",
        "doAssert offsetof(AuthBodyTraceView, challengeLen) == 7",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let authTrace = cast[ptr AuthBodyTraceView](authBodyPtr)",
        "authTrace.fixed.authAlgo.uint32 or (authTrace.fixed.authSeq.uint32 shl 16)",
        "authTrace.fixed.statusCode.uint32 or",
        "(authTrace.challengeTag.uint32 shl 16) or",
        "(authTrace.challengeLen.uint32 shl 24)",
    ]:
        assert expected in auth_body

    for expected in [
        "let assocFixed = cast[ptr AssocReqFixedBodyView](assocBodyPtr)",
        "assocFixed.capabilityInfo.uint32 or (assocFixed.listenInterval.uint32 shl 16)",
        "let assocTraceWord1 = cast[ptr uint32](addr assocFixed.reassocBssid[0])[]",
    ]:
        assert expected in assoc_body

    for body, fc_value in [
        (auth_body, "0x00B0'u16"),
        (assoc_body, "0"),
    ]:
        for expected in [
            "let vif = vifChannelForIdx(vifIdx)",
            "tpc_update_frame_tx_power(cast[pointer](vif), frame)",
            "let link = hostTxLinkDescAt(desc.bufDesc)",
            "let hdr = hostTxDataHeader(desc)",
            f"hdr.frameControl = {fc_value}",
            "hdr.duration = 0",
            "c_memcpy(addr hdr.addr1[0],",
            "c_memcpy(addr hdr.addr2[0],",
            "c_memcpy(addr hdr.addr3[0],",
            "hdr.seqCtrl =",
            "let thd = hostTxHwDescAt(desc.hwDesc)",
            "let thdBase = thd.payloadStart",
            "thd.payloadEnd =",
            "thd.frameLen =",
        ]:
            assert expected in body

        for forbidden in [
            "let bodyU = cast[uint](desc.bufDesc)",
            "let macHdr = cast[uint](desc.bufDesc)",
            "cast[ptr uint8](bodyU + 348)",
            "cast[ptr uint8](bodyU + 349)",
            "cast[ptr uint8](bodyU + 350)",
            "cast[ptr uint8](bodyU + 351)",
            "cast[pointer](bodyU + 352)",
            "cast[pointer](bodyU + 358)",
            "cast[pointer](bodyU + 364)",
            "cast[ptr uint8](bodyU + 370)",
            "cast[ptr uint8](bodyU + 371)",
            "cast[ptr uint8](macHdr + 348)",
            "cast[ptr uint8](macHdr + 349)",
            "cast[ptr uint8](macHdr + 350)",
            "cast[ptr uint8](macHdr + 351)",
            "cast[pointer](macHdr + 352)",
            "cast[pointer](macHdr + 358)",
            "cast[pointer](macHdr + 364)",
            "cast[ptr uint8](macHdr + 370)",
            "cast[ptr uint8](macHdr + 371)",
            "let thdPtr = desc.hwDesc",
            "let thdU = cast[uint](thdPtr)",
            "cast[ptr uint32](thdU + 20)",
            "cast[ptr uint32](thdU + 24)",
            "cast[ptr uint32](thdU + 28)",
            "let vifBase = cast[uint](addr vif_info_tab[0])",
            "let vifEntry = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
            "let vif = vifChannelAt(vifEntry)",
            "tpc_update_frame_tx_power(cast[pointer](vifEntry), frame)",
            "cast[ptr uint32](cast[uint](authBodyPtr) + 4)",
            "cast[ptr uint32](cast[uint](assocBodyPtr) + 4)",
        ]:
            assert forbidden not in body


def test_wifi_connect_ind_uses_typed_payload_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    connect_body = wifi_fw.rsplit("proc sm_connect_ind*", 1)[1].split(
        "proc sm_connect_abort_process*", 1
    )[0]
    assoc_tx_body = wifi_fw.rsplit("proc sm_assoc_req_send*", 1)[1].split(
        "proc sm_assoc_req_send_pre*", 1
    )[0]
    assoc_rsp_body = wifi_fw.rsplit("proc sm_assoc_rsp_handler*", 1)[1].split(
        "proc sm_deauth_handler*",
        1,
    )[0]

    for expected in [
        "SmConnectIndPayload {.packed.} = object",
        "statusCode*: uint16",
        "reasonCode*: uint16",
        "bssid*: array[6, uint8]",
        "assocIeBuffer*: array[800, uint8]",
        "chanBand*: uint8",
        "chanPrimFreq*: uint16",
        "chanType*: uint8",
        "chanCenterFreq1*: uint32",
        "chanCenterFreq2*: uint32",
        "doAssert offsetof(SmConnectIndPayload, assocIeBuffer) == 20",
        "doAssert offsetof(SmConnectIndPayload, chanBand) == 822",
        "template smConnectIndPayloadAt(param: pointer): ptr SmConnectIndPayload",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let ind = smConnectIndPayloadAt(msg)",
        "ind.vifIdx = vifIdx",
        "c_memcpy(addr ind.bssid[0], addr vif.bssid[0], 6.csize_t)",
        "ind.aid = vif.staIdx",
        "ind.channelStatus = 0",
        "ind.chanBand = chan.channel.band",
        "ind.chanPrimFreq = chan.channel.primFreq",
        "ind.chanType = chan.channel.chanType",
        "qosFlag = vif.wmmAcFlags",
        "ind.qosFlag = qosFlag",
        "ind.securityStatus = 0",
        "ind.statusCode = statusCode",
        "ind.reasonCode = reasonCode",
    ]:
        assert expected in connect_body

    assert "smConnectIndPayloadAt(smEnvSecond).assocReqIeLen = assocBodyLen" in assoc_tx_body
    assert "let ind = smConnectIndPayloadAt(smEnvSecond)" in assoc_rsp_body
    assert "let reqIeLen = ind.assocReqIeLen" in assoc_rsp_body
    assert "ind.assocRspIeLen = rspIeLen" in assoc_rsp_body
    assert "addr ind.assocIeBuffer[reqIeLen.int]" in assoc_rsp_body
    assert "let vif = vifChannelForIdx(vifIdx)" in assoc_rsp_body
    assert "pointerAddrU32(cast[pointer](vif))" in assoc_rsp_body
    assert "let staEntry = cast[pointer](staInfoForIdx(staIdx))" in assoc_rsp_body
    assert "pointerAddrU32(staEntry)" in assoc_rsp_body
    assert "me_init_rate(staEntry)" in assoc_rsp_body

    for forbidden in [
        "cast[ptr uint8](m + 11)",
        "cast[ptr uint32](m + 4)",
        "cast[ptr uint16](m + 8)",
        "cast[ptr uint8](m + 12)",
        "cast[ptr uint8](m + 13)",
        "cast[ptr uint8](m + 822)",
        "cast[ptr uint16](m + 824)",
        "cast[ptr uint32](m + 828)",
        "cast[ptr uint32](m + 832)",
        "cast[ptr uint8](m + 826)",
        "cast[ptr uint16](smEnvSecU + 32)",
        "cast[ptr uint16](smEnvSecU + 34)",
        "cast[ptr uint8](m + 14)",
        "cast[ptr uint8](m + 15)",
        "cast[ptr uint8](m + 10)",
        "cast[ptr uint16](m + 0)",
        "cast[ptr uint16](m + 2)",
        "let vifTab = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifTab + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifEntry)",
        "let peerVifEntry = vifTab + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "vifChannelAt(peerVifEntry).wmmAcFlags",
    ]:
        assert forbidden not in connect_body

    for forbidden in [
        "cast[ptr uint16](cast[uint](smEnvSecond) + 16)",
        "let smSec = cast[uint](smEnvSecond)",
        "cast[ptr uint16](smSec + 16)",
        "cast[ptr uint16](smSec + 18)",
        "cast[pointer](smSec + 20'u + reqIeLen.uint)",
        "let staBase = cast[uint](addr sta_info_tab[0])",
        "let staEntrySize = STA_ENTRY_SIZE.uint",
        "let staDbgAddr = staBase + staIdx.uint * staEntrySize",
        "cast[pointer](staBase + staIdx.uint * staEntrySize)",
        "let vifTab = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifTab + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifEntry)",
        "cast[uint32](vifEntry)",
    ]:
        assert forbidden not in assoc_tx_body
        assert forbidden not in assoc_rsp_body


def test_wifi_sta_add_ind_uses_typed_vif_security_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc sm_connection_sta_add_ind*", 1)[1].split(
        "proc sm_connect_auth_assoc_req", 1
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let staIdx = vif.staIdx",
        "let wpaFlags = vifApConfig(vif).securityFlags",
        "vifSecurity(vif).connected.uint32",
    ]:
        assert expected in body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "vifChannelAt(vifEntry).staIdx",
        "vifApConfigAt(vifEntry).securityFlags",
        "vifSecurityAt(vifEntry).connected",
    ]:
        assert forbidden not in body


def test_wifi_sm_deauth_handler_uses_vif_bssid_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc sm_deauth_handler*", 1)[1].split(
        "proc sm_get_set_machwkey_index*", 1
    )[0]

    assert "doAssert offsetof(VifChannelView, bssid) == 380" in wifi_fw
    assert "let vif = vifChannelForIdx(vifIdx)" in body
    assert "if deauth.bssid[i] != vif.bssid[i]:" in body
    assert "if deauth.sa[i] != vif.macAddr[i]:" in body
    assert "sm_disconnect_process(cast[pointer](vif), 7, reason)" in body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifE = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifE)",
        "cast[ptr uint8](vifE + 380 + i.uint)",
        "cast[ptr uint8](vifE + 380)",
        "sm_disconnect_process(cast[pointer](vifE), 7, reason)",
    ]:
        assert forbidden not in body


def test_wifi_machw_key_index_uses_typed_vif_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc sm_get_set_machwkey_index*", 1)[1].split(
        "proc sm_handle_eapol_input*", 1
    )[0]

    for expected in [
        "VifMachwKeyIndexOverlay {.packed.} = object",
        "primaryPairwise*: uint8",
        "secondaryPairwise*: uint8",
        "group*: uint8",
        "doAssert offsetof(VifMachwKeyIndexOverlay, primaryPairwise) == 172",
        "doAssert offsetof(VifMachwKeyIndexOverlay, secondaryPairwise) == 173",
        "doAssert offsetof(VifMachwKeyIndexOverlay, group) == 174",
        "template vifMachwKeyIndexes(vif: ptr VifChannelView): ptr VifMachwKeyIndexOverlay",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let vif = vifChannelForIdx(vifIdx.uint8)",
        "let indexes = vifMachwKeyIndexes(vif)",
        "of 0: keyAddr = addr indexes.primaryPairwise",
        "of 1: keyAddr = addr indexes.secondaryPairwise",
        "of 2: keyAddr = addr indexes.group",
    ]:
        assert expected in body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifBase + vifIdx * VIF_ENTRY_SIZE.uint",
        "var keyOffset: uint",
        "keyOffset = 172",
        "keyOffset = 173",
        "keyOffset = 174",
        "cast[ptr uint8](vifEntry + keyOffset)",
    ]:
        assert forbidden not in body


def test_wifi_rxu_protected_key_uses_typed_key_table_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc rxuProtectedKey", 1)[1].split(
        "proc rxu_cntrl_protected_handle*", 1
    )[0]

    for expected in [
        "VifRxProtectedKeyTableOverlay {.packed.} = object",
        "slots*: UncheckedArray[VifKeySlotView]",
        "doAssert offsetof(VifRxProtectedKeyTableOverlay, slots) == 520",
        "template vifRxProtectedKeySlot(vif: ptr VifChannelView, slot: uint): ptr VifKeySlotView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let vif = vifChannelForIdx(env.vifIdx)",
        "return vifRxProtectedKeySlot(vif, keyIdx.uint)",
        "let sta = staInfoForIdx(env.staIdx)",
        "cast[ptr VifKeySlotView](addr sta.keyArea[0])",
    ]:
        assert expected in body

    for forbidden in [
        "let vifIdx = env.vifIdx",
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint + 520'u",
        "keyIdx.uint * 160'u",
    ]:
        assert forbidden not in body


def test_wifi_sta_mgmt_init_uses_typed_sta_and_vif_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc sta_mgmt_init*", 1)[1].split(
        "proc sta_mgmt_register*", 1
    )[0]

    for expected in [
        "let sta = staInfoForIdx(idx)",
        "sta_mgmt_entry_init(cast[pointer](sta))",
        "co_list_push_back(addr sta_info_env, cast[ptr CoListHdr](sta))",
        "let bcStaVif0 = staInfoForIdx(STA_MGMT_FREE_STAS.uint8)",
        "bcStaVif0.instNbr = 0",
        "bcStaVif0.rxNss = 0",
        "bcStaVif0.txPolicy = cast[pointer](txBufferControlBcmcDescAt(0))",
        "bcStaVif0.keyMat = cast[pointer](vifKeyPointers(vifChannelForIdx(0)))",
        "let bcStaVif1 = staInfoForIdx(STA_MGMT_FREE_STAS.uint8 + 1'u8)",
        "bcStaVif1.instNbr = 1",
        "bcStaVif1.rxNss = 0",
        "bcStaVif1.txPolicy = cast[pointer](txBufferControlBcmcDescAt(1))",
        "bcStaVif1.keyMat = cast[pointer](vifKeyPointers(vifChannelForIdx(1)))",
    ]:
        assert expected in body

    for forbidden in [
        "let staBase = cast[uint](addr sta_info_tab[0])",
        "let staEnd = staBase + STA_MGMT_FREE_STAS.uint * STA_ENTRY_SIZE.uint",
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "var cur = staBase",
        "cur += STA_ENTRY_SIZE.uint",
        "let bcStaVif0 = staBase + 0x730'u",
        "cast[ptr uint8](staBase + 0x757)",
        "let staEnvOffset0x800 = staBase + 0x800'u",
        "cast[ptr pointer](staEnvOffset0x800 + 112)",
        "cast[ptr pointer](staEnvOffset0x800 + 36)",
        "let bcStaVif1 = staBase + 0x8A0'u",
        "cast[ptr uint8](staBase + 0x8C7)",
        "let staEnvOffset0x980 = staBase + 0x980'u",
        "cast[ptr pointer](staEnvOffset0x980 + 96)",
        "cast[ptr pointer](staEnvOffset0x980 + 20)",
        "vifBase + 0x5D0",
        "vifBase + 0xBB8",
    ]:
        assert forbidden not in body


def test_wifi_assoc_bssid_accessor_uses_vif_bssid_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc bl_wifi_get_assoc_bssid_internal*", 1)[1].split(
        "proc bl_wifi_get_hostap_private_internal*", 1
    )[0]

    assert "doAssert offsetof(VifChannelView, bssid) == 380" in wifi_fw
    assert "let vif = vifChannelAt(vifEntry)" in body
    assert "c_memcpy(output, addr vif.bssid[0], 6.csize_t)" in body

    for forbidden in [
        "let bssidSrc = cast[pointer](cast[uint](vifEntry) + 380)",
        "c_memcpy(output, bssidSrc, 6)",
    ]:
        assert forbidden not in body


def test_wifi_scan_confirm_join_uses_vif_mac_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc scanu_start_cfm_handler*", 1)[1].split(
        "proc scanu_join_req_handler*", 1
    )[0]

    assert "doAssert offsetof(VifChannelView, macAddr) == 80" in wifi_fw
    assert "let vif = vifChannelAt(vifEntry)" in body
    assert "let vifMac = cast[pointer](addr vif.macAddr[0])" in body
    assert "sm_join_bss(vifMac, resultPtr, chanPtr, 0)" in body

    for forbidden in [
        "let vifMac = cast[pointer](cast[uint](vifEntry) + 80)",
        "cast[pointer](cast[uint](vifEntry) + 80)",
    ]:
        assert forbidden not in body


def test_wifi_scan_join_uses_vif_ht_key_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    req_body = wifi_fw.rsplit("proc scanu_join_req_handler*", 1)[1].split(
        "proc scanu_join_cfm_handler*", 1
    )[0]
    cfm_body = wifi_fw.rsplit("proc scanu_join_cfm_handler*", 1)[1].split(
        "proc sm_disconnect_req_handler*", 1
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "vifApConfig(vif).securityFlags = 0",
    ]:
        assert expected in req_body

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let apCfg = vifApConfig(vif)",
        "let htCap = vifHtCapabilities(vif).ampduParams",
        "vifKeyPointers(vif).flags = connFlags",
    ]:
        assert expected in cfm_body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0]) + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifBase)",
        "vifApConfigAt(vifBase).securityFlags = 0",
        "cast[ptr uint8](vifBase + 350)",
        "vifKeyPointersAt(vifBase).flags = connFlags",
    ]:
        assert forbidden not in req_body
        assert forbidden not in cfm_body


def test_wifi_mm_sta_add_confirm_uses_vif_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc mm_sta_add_cfm_handler*", 1)[1].split(
        "proc mm_sta_del_req_handler*", 1
    )[0]

    for expected in [
        "doAssert offsetof(VifChannelView, basicRates) == 436",
        "doAssert offsetof(VifHtCapabilitiesOverlay, capInfo) == 0",
        "let vif = vifChannelForIdx(vifIdx)",
        "let vifFlags = vifApConfig(vif).securityFlags",
        "c_memcpy(cast[pointer](addr sta.supportedRates[0]),\n                   addr vif.basicRates[0], 13.csize_t)",
        "c_memcpy(cast[pointer](addr sta.vhtCaps[0]),\n                     cast[pointer](vifHtCapabilities(vif)), 32.csize_t)",
        "me_set_sta_ht_vht_param(cast[pointer](sta), cast[pointer](vif))",
    ]:
        assert expected in wifi_fw if expected.startswith("doAssert") else expected in body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0]) + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifBase)",
        "let vifFlags = vifApConfigAt(vifBase).securityFlags",
        "me_set_sta_ht_vht_param(cast[pointer](sta), cast[pointer](vifBase))",
        "cast[pointer](vifBase + 436)",
        "cast[pointer](vifBase + 348)",
    ]:
        assert forbidden not in body


def test_wifi_me_sta_add_request_uses_vif_ht_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc me_sta_add_req_handler*", 1)[1].split(
        "proc me_sta_del_req_handler*", 1
    )[0]

    for expected in [
        "doAssert offsetof(VifHtCapabilitiesOverlay, capInfo) == 0",
        "let vif = vifChannelForIdx(staIdx)",
        "me_set_sta_ht_vht_param(cast[pointer](sta),\n                            cast[pointer](vifHtCapabilities(vif)))",
        "let nssFlag = (vifKeyPointers(vif).flags and 0xFF).uint8",
        "sta.rateWord = vif.apStartBeaconInterval",
    ]:
        assert expected in wifi_fw if expected.startswith("doAssert") else expected in body

    for forbidden in [
        "let vifEntryBase = cast[uint](addr vif_info_tab[0]) + staIdx.uint * 1512'u",
        "let vif = vifChannelAt(vifEntryBase)",
        "cast[pointer](vifEntryBase + 348)",
        "cast[ptr uint8](vifEntryBase + 0x5D8)",
        "cast[ptr uint16](vifEntryBase + 0x150)",
    ]:
        assert forbidden not in body


def test_wifi_rxu_pn_check_uses_typed_replay_counters():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc rxu_cntrl_check_pn*", 1)[1].split(
        "proc rxu_cntrl_desc_prepare*", 1
    )[0]

    for expected in [
        "VifKeySlotView {.packed.} = object",
        "replayCounters*: array[8, KeyReplayCounterView]",
        "cipherType*: uint8",
        "hasRxPn*: uint8",
        "doAssert offsetof(VifKeySlotView, replayCounters) == 0",
        "doAssert offsetof(VifKeySlotView, cipherType) == 152",
        "doAssert offsetof(VifKeySlotView, hasRxPn) == 156",
        "doAssert sizeof(KeyReplayCounterView) == 16",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let key = cast[ptr VifKeySlotView](secKeyPtr)",
        "let hasRxPn = key.hasRxPn",
        "if hasRxPn == 0:",
        "let entry = addr key.replayCounters[tid.int]",
        "let storedHi = entry.pnHigh",
        "let storedLo = entry.pnLow",
        "entry.pnLow = nextLo",
        "entry.pnHigh = nextHi",
        "let entry = addr key.replayCounters[adjTid.int]",
        "let entryAddr = cast[uint](entry)",
        "nimFwDbgRxuPnStoredLo = entry.pnLow",
        "nimFwDbgRxuPnStoredHi = entry.pnHigh",
    ]:
        assert expected in body

    for forbidden in [
        "let keyAddr = cast[uint](secKeyPtr)",
        "cast[ptr uint8](keyAddr + 156)[]",
        "let tidOffset = tid.uint * 16",
        "let entryAddr = keyAddr + tidOffset",
        "let entryAddr = keyAddr + adjTid.uint * 16",
        "let keyType = key.cipherType",
        "if keyType == 0:",
        "cast[ptr uint32](entryAddr)[]",
        "cast[ptr uint32](entryAddr + 4)[]",
        "nimFwDbgRxuPnStoredLo = cast[ptr uint32](entryAddr)[]",
        "nimFwDbgRxuPnStoredHi = cast[ptr uint32](entryAddr + 4)[]",
    ]:
        assert forbidden not in body


def test_wifi_rx_michael_mic_read_uses_typed_word_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc rxu_cntrl_frame_handle*", 1)[1].split(
        "proc rxu_swdesc_upload_evt*", 1
    )[0]

    for expected in [
        "RxMicWordsView {.packed.} = object",
        "lo*: uint32",
        "hi*: uint32",
        "doAssert sizeof(RxMicWordsView) == 8",
        "doAssert offsetof(RxMicWordsView, hi) == 4",
        "template rxMicWordsAt(p: uint): ptr RxMicWordsView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let micWords = rxMicWordsAt(micPtr)",
        "rxMic[0] = micWords.lo",
        "rxMic[1] = micWords.hi",
    ]:
        assert expected in body

    for forbidden in [
        "cast[ptr uint32](micPtr)[]",
        "cast[ptr uint32](micPtr + 4)[]",
    ]:
        assert forbidden not in body


def test_wifi_tx_sequence_assignment_uses_typed_sta_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc txu_cntrl_push*", 1)[1].split(
        "proc txu_cntrl_tkip_mic_append*", 1
    )[0]

    for expected in [
        "StaTxSequenceOverlay {.packed.} = object",
        "seqCounter*: uint16",
        "doAssert offsetof(StaTxSequenceOverlay, seqCounter) == 28",
        "template staTxSequence(sta: ptr StaInfoView): ptr StaTxSequenceOverlay",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let staSeq = staTxSequence(staInfoForIdx(staInfoForSeq))",
        "let seqNum = staSeq.seqCounter",
        "staSeq.seqCounter = nextSeq",
        "desc.seqAssigned = seqNum",
    ]:
        assert expected in body

    for forbidden in [
        "let staEntrySeq = cast[uint](staInfoForIdx(staInfoForSeq))",
        "let tidSeqBase = staEntrySeq + 24",
        "cast[ptr uint16](tidSeqBase + 4)[]",
    ]:
        assert forbidden not in body


def test_wifi_tx_trigger_dma_status_write_uses_typed_thd_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc txl_cntrl_tx_check*", 1)[1].split(
        "proc txl_reset*", 1
    )[0]

    for expected in [
        "HostTxHwDescView {.packed.} = object",
        "status*: uint32",
        "doAssert offsetof(HostTxHwDescView, status) == 16",
        "template hostTxHwDescAt(p: pointer): ptr HostTxHwDescView",
    ]:
        assert expected in wifi_fw

    assert "let dmaHead = hwDesc.word0.uint" in body
    assert "hostTxHwDescAt(cast[pointer](dmaHead)).status = thdStatus.uint32" in body
    assert "cast[ptr uint32](dmaHead + 16)[]" not in body


def test_wifi_rxu_mgt_ie_start_uses_typed_tail_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    helper_body = wifi_fw.rsplit("proc rxuMgtIndIeStart", 1)[1].split(
        "proc rxuMgtIndSsidLogPtr", 1
    )[0]

    for expected in [
        "ieData*: UncheckedArray[uint8]",
        "doAssert offsetof(RxuMgtIndView, ieData) == 68",
        "addr rxuMgtIndAt(p).ieData[0]",
    ]:
        assert expected in wifi_fw if expected.startswith(("ieData", "doAssert")) else expected in helper_body

    for forbidden in [
        "cast[pointer](cast[uint](p) + sizeof(RxuMgtIndView).uint)",
    ]:
        assert forbidden not in helper_body


def test_wifi_beacon_ie_body_uses_typed_tail_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    helper_body = wifi_fw.rsplit("template beaconFrameIeBody", 1)[1].split(
        "template htMcsNssPrefixView", 1
    )[0]

    for expected in [
        "ProbeRspFixedBodyView {.packed.} = object",
        "body*: UncheckedArray[uint8]",
        "doAssert offsetof(BeaconFrameFixedView, body) == 36",
        "doAssert sizeof(ProbeRspFixedBodyView) == 12",
        "doAssert offsetof(ProbeRspFixedBodyView, body) == 12",
    ]:
        assert expected in wifi_fw

    for expected in [
        "template probeRspFixedBodyView(param: pointer): ptr ProbeRspFixedBodyView",
        "template probeRspIeBody(frame: ptr ProbeRspFixedBodyView): pointer",
        "addr frame.body[0]",
    ]:
        assert expected in helper_body

    for forbidden in [
        "cast[pointer](cast[uint](frame) + sizeof(BeaconFrameFixedView).uint)",
    ]:
        assert forbidden not in helper_body


def test_wifi_scanu_directed_result_uses_vif_ht_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc scanu_frame_handler*", 1)[1].split(
        "proc bl_hw_rxhdr_get_status*", 1
    )[0]

    for expected in [
        "doAssert offsetof(VifHtCapabilitiesOverlay, capInfo) == 0",
        "let htCaps = vifHtCapabilities(vifView)",
        "let vSR = cast[pointer](htCaps)",
        "me_bw_check(vSR)",
        "me_extract_power_constraint(ieStart, ieLen, vSR)",
        "me_extract_country_reg(ieStart, ieLen, vSR)",
    ]:
        assert expected in wifi_fw if expected.startswith("doAssert") else expected in body

    for forbidden in [
        "let vSR = cast[uint](vif) + 348",
        "me_bw_check(cast[pointer](vSR))",
        "me_extract_power_constraint(ieStart, ieLen, cast[pointer](vSR))",
        "me_extract_country_reg(ieStart, ieLen, cast[pointer](vSR))",
    ]:
        assert forbidden not in body


def test_wifi_sa_query_tx_uses_typed_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    tx_body = wifi_fw.rsplit("proc sm_send_sa_query*", 1)[1].split(
        "proc sm_sa_query_handler*", 1
    )[0]
    rx_body = wifi_fw.rsplit("proc sm_sa_query_handler*", 1)[1].split(
        "proc sm_issue_sa_query_request*", 1
    )[0]

    for expected in [
        "SaQueryActionBodyView {.packed.} = object",
        "doAssert sizeof(SaQueryActionBodyView) == 4",
        "template saQueryActionBodyAt(p: pointer): ptr SaQueryActionBodyView",
        "let vif = vifChannelForIdx(vifIdx)",
        "let link = hostTxLinkDescAt(desc.bufDesc)",
        "let hdr = hostTxDataHeader(desc)",
        "hdr.frameControl = 0x00D0'u16",
        "hdr.duration = 0",
        "c_memcpy(addr hdr.addr1[0], addr sta.macAddr[0], 6.csize_t)",
        "c_memcpy(addr hdr.addr2[0], addr vif.macAddr[0], 6.csize_t)",
        "c_memcpy(addr hdr.addr3[0], addr sta.macAddr[0], 6.csize_t)",
        "hdr.seqCtrl = seqCtrl",
        "let body = saQueryActionBodyAt(addr link.macHeader[bodyOff])",
        "body.category = 8",
        "body.action = isTx",
        "body.transId = transId",
        "txu_cntrl_protect_mgmt_frame(frame, cast[pointer](hdr), 0)",
        "tpc_update_frame_tx_power(cast[pointer](vif), frame)",
    ]:
        assert expected in wifi_fw if expected.startswith(("SaQuery", "doAssert", "template")) else expected in tx_body

    for expected in [
        "let frame = smSaQueryFrameView(param)",
        "let vifIdx = frame.vifIdx",
        "let vif = vifChannelForIdx(vifIdx)",
        "let active = vif.state",
        "let vifType = vif.vifType",
    ]:
        assert expected in rx_body

    for forbidden in [
        "let macHdr = hostTxMacHdrAddr(desc)",
        "cast[ptr uint8](macHdr)",
        "cast[ptr uint8](macHdr + 1)",
        "cast[ptr uint8](macHdr + 2)",
        "cast[ptr uint8](macHdr + 3)",
        "cast[pointer](macHdr + 4)",
        "cast[pointer](macHdr + 10)",
        "cast[pointer](macHdr + 16)",
        "cast[ptr uint8](macHdr + 22)",
        "cast[ptr uint8](macHdr + 23)",
        "let realBody = macHdr + bodyOff.uint",
        "cast[ptr uint8](realBody)",
        "cast[ptr uint8](realBody + 1)",
        "cast[ptr uint8](realBody + 2)",
        "cast[ptr uint8](realBody + 3)",
        "txu_cntrl_protect_mgmt_frame(frame, cast[pointer](macHdr), 0)",
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifEntry)",
        "tpc_update_frame_tx_power(cast[pointer](vifEntry), frame)",
    ]:
        assert forbidden not in tx_body
        assert forbidden not in rx_body


def test_wifi_sa_query_timeout_uses_sta_vif_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc sm_sa_query_timeout_ind_handler*", 1)[1].split(
        "proc sm_disconnect*", 1
    )[0]

    for expected in [
        "let sta = staInfoForIdx(staIdx)",
        "let vif = vifChannelForIdx(vifIdx.uint8)",
        "cast[pointer](sta), vifIdx)",
        "sm_disconnect_process(cast[pointer](vif), 20, 0xFFFF'u16)",
    ]:
        assert expected in body

    for forbidden in [
        "let staBase = cast[uint](addr sta_info_tab[0])",
        "let staEntry = staBase + staIdx.uint * STA_ENTRY_SIZE.uint",
        "let vifBase = cast[uint](addr vif_info_tab[0]) + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "cast[pointer](staEntry)",
        "sm_disconnect_process(cast[pointer](vifBase), 20, 0xFFFF'u16)",
    ]:
        assert forbidden not in body


def test_wifi_ap_sta_fw_delete_uses_sta_mac_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc apm_sta_fw_delete*", 1)[1].split(
        "proc apm_probe_req_handler*", 1
    )[0]

    assert "let sta = staInfoForIdx(staIdx)" in body
    assert "let staMacAddr = cast[pointer](addr sta.macAddr[0])" in body
    assert "apm_sta_delete(cast[pointer](staIdx.uint))" in body
    for forbidden in [
        "let staBase = cast[uint](addr sta_info_tab[0])",
        "staBase + 4 + staIdx.uint * STA_ENTRY_SIZE.uint",
        "cast[uint](addr sta_info_tab[0]) +",
    ]:
        assert forbidden not in body


def test_wifi_auth_assoc_scheduler_uses_vif_overlay_pointer():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc sm_auth_assoc_send_according_chan*", 1)[1].split(
        "proc sm_supplicant_deauth_cfm*", 1
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let remaining = chan_ctxt_get_remaining_time_ms(cast[pointer](vif))",
        "remaining, pointerAddrU32(cast[pointer](vif)))",
    ]:
        assert expected in body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0]) + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "chan_ctxt_get_remaining_time_ms(cast[pointer](vifBase))",
        "cast[uint32](cast[uint](vifBase))",
    ]:
        assert forbidden not in body


def test_wifi_tbtt_switch_update_extracts_from_primary_tbtt_list():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc chan_tbtt_switch_update*", 1)[1].split(
        "proc chan_update_tx_power*", 1
    )[0]

    assert "co_list_extract(chanTbttPrimaryList(), chanTbttHdr(tbttNode))" in body
    assert "co_list_extract(addr chanEnvView().freeList, chanTbttHdr(tbttNode))" not in body


def test_wifi_chan_ctxt_unlink_removes_tbtt_without_reinserting_vif_node():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc chan_ctxt_unlink*", 1)[1].split(
        "proc chan_ctxt_update*", 1
    )[0]

    assert "co_list_extract(chanTbttPrimaryList(), tbttNode)" in body
    assert "chan_tbtt_schedule(nil)" in body
    assert "co_list_extract(addr env.freeList, tbttNode)" not in body
    assert "chan_tbtt_schedule(cast[pointer](addr vif.tbttNode))" not in body


def test_wifi_apm_send_mlme_uses_typed_frame_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc apm_send_mlme*", 1)[1].split(
        "proc aidListDelete", 1
    )[0]

    for expected in [
        "let link = hostTxLinkDescAt(desc.bufDesc)",
        "let hdr = hostTxDataHeader(desc)",
        "hdr.frameControl = frameType",
        "hdr.duration = 0",
        "c_memcpy(addr hdr.addr1[0], destAddr, 6.csize_t)",
        "c_memcpy(addr hdr.addr2[0], addr vif.macAddr[0], 6.csize_t)",
        "c_memcpy(addr hdr.addr3[0], addr vif.macAddr[0], 6.csize_t)",
        "hdr.seqCtrl = seqField",
        "let bodyBuf = cast[pointer](addr link.macHeader[sizeof(MacDataFrameHeaderView)])",
        "let txDesc = hostTxHwDescAt(desc.hwDesc)",
        "txDesc.payloadEnd = baseLen - 1 + totalLen",
        "txDesc.frameLen = totalLen + 4",
    ]:
        assert expected in body

    for forbidden in [
        "let thdU = cast[uint](desc.bufDesc)",
        "cast[ptr uint8](thdU + 348)",
        "cast[ptr uint8](thdU + 349)",
        "cast[ptr uint8](thdU + 350)",
        "cast[ptr uint8](thdU + 351)",
        "cast[pointer](thdU + 352)",
        "cast[pointer](thdU + 358)",
        "cast[pointer](thdU + 364)",
        "cast[ptr uint8](thdU + 370)",
        "cast[ptr uint8](thdU + 371)",
        "let bodyBuf = cast[pointer](thdU + 372)",
        "cast[pointer](thdU + 372 + bodyLen.uint)",
    ]:
        assert forbidden not in body


def test_wifi_ap_auth_disassoc_handlers_use_typed_vif_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    auth_body = wifi_fw.rsplit("proc apm_auth_handler*", 1)[1].split(
        "{.emit: \"__attribute__((optimize(\\\"crossjumping\\\"))) void apm_assoc_req_handler",
        1,
    )[0]
    disassoc_body = wifi_fw.rsplit("proc apm_disassoc_handler*", 1)[1].split(
        "proc apm_beacon_handler*", 1
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let chanCtxt = vif.chanCtxt",
        "vif.apChanSwitchPending = 1",
        "apm_send_mlme(cast[pointer](vif), 0xB0, staMac, nil, nil, nil)",
    ]:
        assert expected in auth_body

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "apm_send_mlme(cast[pointer](vif), 0xC0, staMac, nil, nil, nil)",
    ]:
        assert expected in disassoc_body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vifEntry = cast[pointer](vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint)",
        "let vif = vifChannelAt(vifEntry)",
        "apm_send_mlme(cast[pointer](vifEntry)",
        "apm_send_mlme(vifEntry",
    ]:
        assert forbidden not in auth_body
        assert forbidden not in disassoc_body


def test_wifi_ap_assoc_handler_uses_typed_vif_ap_config_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc apm_assoc_req_handler*", 1)[1].split(
        "proc apm_deauth_handler*", 1
    )[0]
    start_body = wifi_fw.rsplit("proc apm_start_req_handler*", 1)[1].split(
        "proc apm_stop_req_handler*", 1
    )[0]

    for expected in [
        "maxAssocRate*: uint16",
        "ssidData*: UncheckedArray[uint8]",
        "doAssert offsetof(VifApConfigOverlay, aidBitmapFeatureLow) == 60",
        "doAssert offsetof(VifApConfigOverlay, maxAssocRate) == 62",
        "doAssert offsetof(VifApConfigOverlay, privacyFlag) == 64",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let vifView = vifChannelForIdx(vifIdx)",
        "let apCfg = vifApConfig(vifView)",
        "let vifMaxRate = apCfg.maxAssocRate",
        "let vifSsidLen = apCfg.privacyFlag",
        "cast[pointer](addr apCfg.ssidData[0])",
        "if vifView.securityTimer.link.next != nil:",
        "let vifPtr = cast[pointer](vifView)",
    ]:
        assert expected in body

    assert "apCfg.aidBitmapFeatureLow = 0" in start_body
    assert "apCfg.maxAssocRate = 0xFFFF'u16" in start_body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifOff = vifIdx.uint * VIF_ENTRY_SIZE",
        "let vif = vifBase + vifOff",
        "let vifView = vifChannelAt(vif)",
        "let vifMaxRate = cast[ptr uint16](vif + 518)[]",
        "let vifSsidLen = cast[ptr uint8](vif + 520)[]",
        "cast[pointer](vif + 521)",
        "vifChannelAt(vif).securityTimer.link.next",
        "let vifPtr = cast[pointer](vif)",
        "apCfg.aidBitmapFeature = 0xFFFF0000'u32",
    ]:
        assert forbidden not in body
        assert forbidden not in start_body


def test_wifi_ap_probe_req_handler_uses_typed_ie_and_channel_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc apm_probe_req_handler*", 1)[1].split(
        "proc apm_auth_handler*", 1
    )[0]

    for expected in [
        "VifApProbeSsidOverlay {.packed.} = object",
        "hiddenSsidMode*: uint8",
        "ssidLen*: uint8",
        "ssidData*: UncheckedArray[uint8]",
        "doAssert offsetof(VifApProbeSsidOverlay, hiddenSsidMode) == 385",
        "doAssert offsetof(VifApProbeSsidOverlay, ssidLen) == 386",
        "doAssert offsetof(VifApProbeSsidOverlay, ssidData) == 387",
        "template vifApProbeSsid(vif: ptr VifChannelView): ptr VifApProbeSsidOverlay",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let vif =\n    if vifIdx == 0xFF:",
        "vifChannelAt(apVif)",
        "vifChannelForIdx(vifIdx)",
        "let apSsid = vifApProbeSsid(vif)",
        "let ssid = cast[ptr MacIeView](ssidIe)",
        "let ieLen = ssid.len",
        "let apSsidLen = apSsid.ssidLen",
        "cast[pointer](addr ssid.macIePayload[0])",
        "cast[pointer](addr apSsid.ssidData[0])",
        "if apSsid.hiddenSsidMode != 0:",
        "let rates = cast[ptr MacIeView](ratesIe)",
        "let rateVal = rates.macIePayload[0]",
        "let rateInfo = vif.operChan",
        "let chan = cast[ptr ScanChannelEntry](rateInfo)",
        "let band = chan.band",
        "apm_send_mlme(cast[pointer](vif), 0x50'u16,",
    ]:
        assert expected in body

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "var vifEntry: uint",
        "vifEntry = cast[uint](apVif)",
        "vifEntry = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifEntry)",
        "vif.supportedRatesLong[0]",
        "addr vif.supportedRatesLong[1]",
        "cast[ptr uint8](vifEntry + 385)",
        "vifChannelAt(vifEntry).operChan",
        "apm_send_mlme(cast[pointer](vifEntry), 0x50'u16,",
        "let ssidIeAddr = cast[uint](ssidIe)",
        "cast[ptr uint8](ssidIeAddr + 1)",
        "cast[pointer](ssidIeAddr + 2)",
        "let ratesAddr = cast[uint](ratesIe)",
        "cast[ptr uint8](ratesAddr + 2)",
        "cast[ptr uint8](cast[uint](rateInfo) + 2)",
    ]:
        assert forbidden not in body


def test_wifi_ap_eapol_dispatch_uses_typed_hostapd_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc apm_handle_eapol_input*", 1)[1].split(
        "proc apm_handle_auth_done*", 1
    )[0]

    for expected in [
        "VifMgmtHostapdOpsEnvView {.packed.} = object",
        "hostapdOps*: pointer",
        "VifHostapdPrivView {.packed.} = object",
        "hostapdPriv*: pointer",
        "HostapdOpsView {.packed.} = object",
        "eapolRx*: pointer",
        "doAssert offsetof(VifMgmtHostapdOpsEnvView, hostapdOps) == 12",
        "doAssert offsetof(VifHostapdPrivView, hostapdPriv) == 364",
        "doAssert offsetof(HostapdOpsView, eapolRx) == 44",
        "template vifMgmtHostapdOpsEnv(): ptr VifMgmtHostapdOpsEnvView",
        "template vifHostapdPrivAt(p: uint): ptr VifHostapdPrivView",
        "template vifHostapdPriv(vif: ptr VifChannelView): ptr VifHostapdPrivView",
        "template hostapdOpsAt(p: pointer): ptr HostapdOpsView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let vif = vifChannelForIdx(instNbr)",
        "let opsPtr = vifMgmtHostapdOpsEnv().hostapdOps",
        "let eapolHandler = hostapdOpsAt(opsPtr).eapolRx",
        "let vifPriv = vifHostapdPriv(vif).hostapdPriv",
    ]:
        assert expected in body

    for forbidden in [
        "cast[ptr pointer](cast[uint](addr vif_mgmt_env[0]) + 12)",
        "cast[ptr pointer](cast[uint](opsPtr) + 44)",
        "cast[ptr pointer](vifEntry + 364)",
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifBase + instNbr.uint * VIF_ENTRY_SIZE.uint",
        "let vifPriv = vifHostapdPrivAt(vifEntry).hostapdPriv",
    ]:
        assert forbidden not in body


def test_wifi_bam_air_action_uses_typed_frame_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc bam_send_air_action_frame*", 1)[1].split(
        "proc tdEntryForVif", 1
    )[0]

    for expected in [
        "let desc = hostTxDescAt(frame)",
        "let vif = vifChannelForIdx(vifIdx)",
        "tpc_update_frame_tx_power(cast[pointer](vif), frame)",
        "let link = hostTxLinkDescAt(desc.bufDesc)",
        "let hdr = hostTxDataHeader(desc)",
        "hdr.frameControl = 0x00D0'u16",
        "hdr.duration = 0",
        "c_memcpy(addr hdr.addr1[0], addr sta.macAddr[0], 6.csize_t)",
        "c_memcpy(addr hdr.addr2[0], addr vif.macAddr[0], 6.csize_t)",
        "hdr.seqCtrl = seqField",
        "desc.staInfoIdx = staIdx",
        "desc.vifIdx = vifIdx",
        "desc.hdrLen = 0",
        "desc.secTailLen = 0",
        "mfp_protect_mgmt_frame(frame, hdr.frameControl.uint32, 3'u32)",
        "txu_cntrl_protect_mgmt_frame(frame, cast[pointer](hdr), 24)",
        "let bodyPtr = cast[pointer](addr link.macHeader[hdrLen])",
        "let txDesc = hostTxHwDescAt(desc.hwDesc)",
        "txDesc.payloadEnd = oldPayLen + hdrLen - 1",
        "txDesc.frameLen = totalLen",
        "desc.callback = txCallback",
        "desc.callbackArg = cast[pointer](cast[uint](tid))",
    ]:
        assert expected in body

    for forbidden in [
        "let frameAddr = cast[uint](frame)",
        "let vifTabBase = cast[uint](addr vif_info_tab[0])",
        "let vifOff = vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vifEntry = vifTabBase + vifOff",
        "let vif = vifChannelAt(vifEntry)",
        "tpc_update_frame_tx_power(cast[pointer](vifEntry), frame)",
        "cast[ptr pointer](frameAddr + 108)",
        "let macHdr =",
        "cast[ptr uint8](macHdr +",
        "copy6(macHdr +",
        "cast[ptr uint8](frameAddr + 49)",
        "cast[ptr uint8](frameAddr + 47)",
        "cast[ptr uint8](frameAddr + 98)",
        "cast[ptr uint8](frameAddr + 100)",
        "cast[pointer](macHdr)",
        "cast[pointer](macHdr + hdrLen)",
        "let txDescPtr =",
        "cast[ptr uint32](txDescPtr + 20)",
        "cast[ptr uint32](txDescPtr + 24)",
        "cast[ptr uint32](txDescPtr + 28)",
        "cast[ptr pointer](frameAddr + 208)",
        "cast[ptr pointer](frameAddr + 212)",
    ]:
        assert forbidden not in body


def test_wifi_block_ack_action_builders_use_typed_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    req_body = wifi_fw.rsplit("proc me_build_add_ba_req*", 1)[1].split(
        "proc me_build_add_ba_rsp*", 1
    )[0]
    rsp_body = wifi_fw.rsplit("proc me_build_add_ba_rsp*", 1)[1].split(
        "proc me_build_del_ba*", 1
    )[0]
    del_body = wifi_fw.rsplit("proc me_build_del_ba*", 1)[1].split(
        "proc me_build_capability*", 1
    )[0]

    for expected in [
        "AddBaReqActionBodyView {.packed.} = object",
        "AddBaRspActionBodyView {.packed.} = object",
        "DelBaActionBodyView {.packed.} = object",
        "DelBaInfoView {.packed.} = object",
        "template addBaReqActionBodyAt(param: pointer): ptr AddBaReqActionBodyView",
        "template addBaRspActionBodyAt(param: pointer): ptr AddBaRspActionBodyView",
        "template delBaActionBodyAt(param: pointer): ptr DelBaActionBodyView",
        "template delBaInfoView(param: pointer): ptr DelBaInfoView",
        "doAssert sizeof(AddBaReqActionBodyView) == 9",
        "doAssert offsetof(AddBaReqActionBodyView, baParams) == 3",
        "doAssert offsetof(AddBaReqActionBodyView, timeout) == 5",
        "doAssert offsetof(AddBaReqActionBodyView, startSeq) == 7",
        "doAssert sizeof(AddBaRspActionBodyView) == 9",
        "doAssert offsetof(AddBaRspActionBodyView, statusCode) == 3",
        "doAssert offsetof(AddBaRspActionBodyView, baParams) == 5",
        "doAssert offsetof(AddBaRspActionBodyView, timeout) == 7",
        "doAssert sizeof(DelBaActionBodyView) == 6",
        "doAssert offsetof(DelBaActionBodyView, delbaParams) == 2",
        "doAssert offsetof(DelBaActionBodyView, reasonCode) == 4",
        "doAssert offsetof(DelBaInfoView, initiator) == 13",
        "doAssert offsetof(DelBaInfoView, tid) == 16",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let body = addBaReqActionBodyAt(buf)",
        "body.category = 3",
        "body.action = 0",
        "body.dialogToken = req.dialogToken",
        "body.baParams = amsdu or tid or bufSize",
        "body.timeout = req.timeout",
        "body.startSeq = req.ssn shl 4",
    ]:
        assert expected in req_body

    for expected in [
        "let body = addBaRspActionBodyAt(buf)",
        "body.category = 3",
        "body.action = 1",
        "body.dialogToken = dialogToken",
        "body.statusCode = statusCode",
        "body.baParams = baParams",
        "body.timeout = 0",
    ]:
        assert expected in rsp_body

    for expected in [
        "let body = delBaActionBodyAt(buf)",
        "body.category = 3",
        "body.action = 2",
        "let info = delBaInfoView(baInfo)",
        "delbaParams = info.tid.uint16 shl 12",
        "if info.initiator == 1:",
        "body.delbaParams = delbaParams",
        "body.reasonCode = reasonCode",
    ]:
        assert expected in del_body

    combined_body = req_body + rsp_body + del_body
    for forbidden in [
        "let p = cast[ptr UncheckedArray[uint8]](buf)",
        "p[0] = 3",
        "p[1] = 0",
        "p[1] = 1",
        "p[1] = 2",
        "p[3] = (baParams and 0xFF).uint8",
        "p[4] = ((baParams shr 8) and 0xFF).uint8",
        "p[7] = (ssnField and 0xFF).uint8",
        "let s = cast[ptr UncheckedArray[uint8]](baInfo)",
        "s[16]",
        "s[13]",
    ]:
        assert forbidden not in combined_body


def test_wifi_ipc_host_tx_queue_uses_typed_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    for expected in [
        "hostTxList*: ptr CoList",
        "hostTxCfmList*: ptr CoList",
        "template ipcSharedEnvView(): ptr IpcSharedEnvView",
        "template ipcEmbEnvView(): ptr IpcEmbEnvView",
        "template ipcHostTxWrapperAt(p: pointer): ptr IpcHostTxWrapperView",
        "template ipcHostTxWrapperFromDesc(desc: ptr HostTxDescView): ptr IpcHostTxWrapperView",
        "proc ipcHostTxHead(env: ptr IpcEmbEnvView): ptr IpcHostTxWrapperView",
        "template hostTxConfirmLinkWord(desc: ptr HostTxDescView): ptr uint32 =\n  addr ipcHostTxWrapperFromDesc(desc).active",
        "env.hostTxList.first",
        "offsetof(IpcHostTxWrapperView, txDesc).uint",
    ]:
        assert expected in wifi_fw

    init_body = wifi_fw.rsplit("proc ipc_emb_init*", 1)[1].split(
        "proc ipc_emb_notify*", 1
    )[0]
    tx_evt_body = wifi_fw.rsplit("proc ipc_emb_tx_evt*", 1)[1].split(
        "proc ipc_emb_cfmback_irq*", 1
    )[0]
    txcfm_body = wifi_fw.rsplit("proc ipc_emb_txcfm*", 1)[1].split(
        "proc ipc_emb_txcfm_ind*", 1
    )[0]

    for expected in [
        "let env = ipcEmbEnvView()",
        "let shared = ipcSharedEnvView()",
        "env.hostTxList = addr shared.hostTxListCursor",
        "env.hostTxCfmList = addr shared.hostTxCfmCursor",
    ]:
        assert expected in init_body

    for expected in [
        "let env = ipcEmbEnvView()",
        "var wrapper = ipcHostTxHead(env)",
        "let txDesc = addr wrapper.txDesc",
        "discard utils_list_pop_front(env.hostTxList)",
        "wrapper = ipcHostTxHead(env)",
    ]:
        assert expected in tx_evt_body

    for expected in [
        "let wrapper = ipcHostTxWrapperFromDesc(hostTxDescAt(desc))",
        "let env = ipcEmbEnvView()",
        "utils_list_push_back(env.hostTxCfmList, addr wrapper.link)",
    ]:
        assert expected in txcfm_body

    for forbidden in [
        "cast[ptr pointer](cast[uint](env.hostTxList))[]",
        "utils_list_pop_front(cast[ptr CoList](env.hostTxList))",
        "utils_list_push_back(cast[ptr CoList](env.hostTxCfmList)",
        "cast[uint](desc) - 12",
        "cast[ptr uint32](cast[uint](desc) - 4'u)",
        "env.hostTxList = cast[pointer]",
        "env.hostTxCfmList = cast[pointer]",
    ]:
        assert forbidden not in init_body
        assert forbidden not in tx_evt_body
        assert forbidden not in txcfm_body


def test_wifi_ipc_tx_ac_reset_uses_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    helper_body = wifi_fw.split("template ipcTxAcDescAt", 1)[1].split(
        "template hostTxLinkMacHdrAddr", 1
    )[0]
    reset_body = wifi_fw.split(
        "proc txl_reset*() {.exportc, cdecl.} =", 1
    )[1].split(
        "proc txl_machdr_format*", 1
    )[0]

    for expected in [
        "IPC_TX_AC_DESC_BASE* = 0x24A00080'u32",
        "IPC_TX_AC_DESC_STRIDE* = 16'u32",
        "IpcTxAcDescView {.packed.} = object",
        "descriptor*: uint32",
        "descPtr*: uint32",
        "sequence*: uint16",
        "busy*: uint8",
        "doAssert sizeof(IpcTxAcDescView) == 16",
        "doAssert IPC_TX_AC_DESC_STRIDE == sizeof(IpcTxAcDescView).uint32",
        "doAssert offsetof(IpcTxAcDescView, descPtr) == 4",
        "doAssert offsetof(IpcTxAcDescView, sequence) == 12",
        "doAssert offsetof(IpcTxAcDescView, busy) == 14",
        "template ipcTxAcDescAt(ac: uint32): ptr IpcTxAcDescView",
        "proc ipcTxAcDescClear(ac: uint32)",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let desc = ipcTxAcDescAt(ac)",
        "volatileStore(addr desc.descriptor, 0'u32)",
        "volatileStore(addr desc.busy, 0'u8)",
        "volatileStore(addr desc.sequence, 0'u16)",
    ]:
        assert expected in helper_body

    assert "ipcTxAcDescClear(ac)" in reset_body

    for forbidden in [
        "let ipcBase = 0x24A00080'u",
        "let ipcEnd = 0x24A00094'u",
        "var ipcOff = ipcBase",
        "let ipcDescPtr = cast[ptr uint32](ipcOff + 4)",
        "cast[ptr uint32](ipcOff)[] = 0",
        "cast[ptr uint8](ipcOff + 14)[] = 0",
        "cast[ptr uint16](ipcOff + 12)[] = 0",
        "ipcOff += 16",
    ]:
        assert forbidden not in reset_body


def test_wifi_scan_ssid_selection_has_typed_cache_fallback():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    helper_body = wifi_fw.split("proc scanuCachedSsidFor", 1)[1].split(
        '{.emit: "__attribute__((optimize(\\"crossjumping\\"))) void scanu_frame_handler',
        1,
    )[0]
    frame_body = wifi_fw.split("proc scanu_frame_handler*", 1)[1].split(
        "proc scanu_search_by_bssid*", 1
    )[0]
    search_body = wifi_fw.split("proc scanu_search_by_ssid*", 1)[1].split(
        "proc scanu_rm_exist_ssid*", 1
    )[0]
    clear_body = wifi_fw.split("proc scanu_cached_scanresult_clear*", 1)[1].split(
        "proc scanu_prune_scanresult_raw_frames", 1
    )[0]

    for expected in [
        "ScanuCachedSsid* = object",
        "valid*: uint8",
        "length*: uint8",
        "data*: array[32, uint8]",
        "scanuCachedSsids: array[SCANU_MAX_RESULT_ENTRIES, ScanuCachedSsid]",
    ]:
        assert expected in wifi_fw

    for expected in [
        "if (addr scanu_env.entries[i]) == entry:",
        "return addr scanuCachedSsids[i]",
        "proc scanuCacheSsid(entry: ptr ScanuResultEntry;",
        "proc scanuCachedSsidMatches(entry: ptr ScanuResultEntry;",
        "c_memcmp(searchData, addr cached.data[0], searchLen.csize_t) == 0",
    ]:
        assert expected in helper_body

    assert "scanuCacheSsid(entry, addr ssidScratch)" in frame_body
    assert "if not scanuCachedSsidMatches(entry, searchData, searchLen):" in search_body
    assert "scanuClearCachedSsid(e)" in clear_body


def test_wifi_tx_control_init_uses_ipc_descriptor_word_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    helper_body = wifi_fw.split("template ipcTxHwDescWordTable", 1)[1].split(
        "template hostTxLinkMacHdrAddr", 1
    )[0]
    init_body = wifi_fw.split(
        "proc txl_cntrl_init*() {.exportc, cdecl.} =", 1
    )[1].split(
        "proc txl_cntrl_tx_check*", 1
    )[0]

    for expected in [
        "IpcTxHwDescWordTableView {.packed.} = object",
        "descriptorWords*: array[NUM_TX_QUEUES, uint32]",
        "doAssert sizeof(IpcTxHwDescWordTableView) == NUM_TX_QUEUES * sizeof(uint32)",
        "doAssert offsetof(IpcTxHwDescWordTableView, descriptorWords) == 0",
        "template ipcTxHwDescWordTable(): ptr IpcTxHwDescWordTableView",
        "proc ipcTxHwDescWordAddrHalfword(ac: uint32): uint16",
    ]:
        assert expected in wifi_fw

    assert "addr ipcTxHwDescWordTable().descriptorWords[ac.int]" in helper_body
    assert "acCtrl.packetCount = ipcTxHwDescWordAddrHalfword(ac)" in init_body

    for forbidden in [
        "let hwDescAddr = (0x24A00080'u32 + ac * 4).uint16",
        "acCtrl.packetCount = hwDescAddr",
        "0x24A00080'u32 + ac * 4",
    ]:
        assert forbidden not in init_body


def test_wifi_pspoll_tx_uses_typed_frame_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc ps_send_pspoll*", 1)[1].split(
        "proc mac_recovery*", 1
    )[0]

    for expected in [
        "PsPollFrameHeaderView {.packed.} = object",
        "frameControl*: uint16",
        "aid*: uint16",
        "bssid*: array[6, uint8]",
        "transmitterAddr*: array[6, uint8]",
        "doAssert sizeof(PsPollFrameHeaderView) == 16",
        "doAssert offsetof(PsPollFrameHeaderView, bssid) == 4",
        "doAssert offsetof(PsPollFrameHeaderView, transmitterAddr) == 10",
        "template hostTxPsPollHeader(desc: ptr HostTxDescView): ptr PsPollFrameHeaderView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let desc = hostTxDescAt(txdesc)",
        "let hdr = hostTxPsPollHeader(desc)",
        "hdr.frameControl = 0x00A4'u16",
        "hdr.aid = aidWithBits",
        "c_memcpy(addr hdr.bssid[0], addr sta.macAddr[0], 6.csize_t)",
        "c_memcpy(addr hdr.transmitterAddr[0], addr vif.macAddr[0], 6.csize_t)",
        "let hwDesc = hostTxHwDescAt(desc.hwDesc)",
        "hwDesc.controlFlags = hwDesc.controlFlags or 0x10000053'u32",
        "desc.vifIdx = sta.instNbr",
        "desc.staInfoIdx = sta.infoIdx",
    ]:
        assert expected in body

    for forbidden in [
        "let txAddr = cast[uint](txdesc)",
        "cast[ptr pointer](txAddr + 0x6C)",
        "let hdrAddr = cast[uint](macHdr)",
        "cast[ptr uint8](hdrAddr + 0x15C)",
        "cast[ptr uint8](hdrAddr + 0x15D)",
        "cast[ptr uint8](hdrAddr + 0x15E)",
        "cast[ptr uint8](hdrAddr + 0x15F)",
        "cast[pointer](hdrAddr + 0x160)",
        "cast[pointer](hdrAddr + 0x166)",
        "cast[ptr pointer](txAddr + 0x70)",
        "cast[ptr uint32](swAddr + 0x3C)",
        "cast[ptr uint8](txAddr + 0x2F)",
        "cast[ptr uint8](txAddr + 0x31)",
    ]:
        assert forbidden not in body


def test_wifi_wpa_wps_callbacks_use_typed_overlays():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    for expected in [
        "WpsCallbacksView {.packed.} = object",
        "eapolHandler*: pointer",
        "staConnected*: pointer",
        "staAddConfirm*: pointer",
        "template wpsCallbacks(): ptr WpsCallbacksView",
        "doAssert offsetof(WpsCallbacksView, eapolHandler) == 4",
        "doAssert offsetof(WpsCallbacksView, staConnected) == 8",
        "doAssert offsetof(WpsCallbacksView, staAddConfirm) == 12",
        "deinit*: pointer",
        "eapolHandler*: pointer",
        "beaconRegister*: pointer",
        "apStopped*: pointer",
        "staAdd*: pointer",
        "authTimeout*: pointer",
        "doAssert offsetof(WpaCallbacksView, deinit) == 4",
        "doAssert offsetof(WpaCallbacksView, eapolHandler) == 20",
        "doAssert offsetof(WpaCallbacksView, beaconRegister) == 24",
        "doAssert offsetof(WpaCallbacksView, apStopped) == 28",
        "doAssert offsetof(WpaCallbacksView, staAdd) == 36",
        "doAssert offsetof(WpaCallbacksView, authTimeout) == 64",
    ]:
        assert expected in wifi_fw

    for expected in [
        "wpsCallbacks().staConnected",
        "wpaCallbacks().keyWrite",
        "wpsCallbacks().staAddConfirm",
        "wpsCallbacks().eapolHandler",
        "wpaCallbacks().eapolHandler",
        "wpaCallbacks().deinit",
        "wpaCallbacks().authTimeout",
        "wpaCallbacks().beaconRegister",
        "wpaCallbacks().apStopped",
        "wpaCallbacks().staAdd",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "cast[ptr pointer](cast[uint](wpsCbsPtr) + 8)",
        "cast[ptr pointer](cast[uint](wpaCbsPtr) + 12)",
        "cast[ptr pointer](cast[uint](wpsCbs) + 12)",
        "cast[ptr pointer](cast[uint](wps_cbs) + 4)",
        "cast[ptr pointer](cast[uint](wpa_cbs) + 20)",
        "cast[ptr pointer](cast[uint](wpaCbsPtr) + 4)",
        "cast[ptr pointer](cast[uint](wpa_cbs) + 64)",
        "cast[ptr pointer](cast[uint](wpa_cbs) + 24)",
        "cast[ptr pointer](cast[uint](wpa_cbs) + 28)",
        "cast[ptr pointer](cast[uint](wpaCbsPtr) + 36)",
    ]:
        assert forbidden not in wifi_fw


def test_wifi_wpa_beacon_register_param_uses_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc apm_start_req_handler*", 1)[1].split(
        "proc apm_stop_req_handler*", 1
    )[0]

    for expected in [
        "WpaBeaconRegisterParamView {.packed.} = object",
        "vifIdx*: uint8",
        "bssid*: array[6, uint8]",
        "rateCount*: uint32",
        "rates*: array[32, uint8]",
        "marker*: uint16",
        "ssid*: array[64, uint8]",
        "terminator*: uint8",
        "doAssert sizeof(WpaBeaconRegisterParamView) == 144",
        "doAssert offsetof(WpaBeaconRegisterParamView, bssid) == 1",
        "doAssert offsetof(WpaBeaconRegisterParamView, rateCount) == 40",
        "doAssert offsetof(WpaBeaconRegisterParamView, rates) == 44",
        "doAssert offsetof(WpaBeaconRegisterParamView, marker) == 76",
        "doAssert offsetof(WpaBeaconRegisterParamView, ssid) == 78",
        "doAssert offsetof(WpaBeaconRegisterParamView, terminator) == 142",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let beaconReg = cast[ptr WpaBeaconRegisterParamView](addr haBuf[0])",
        "beaconReg.vifIdx = req.vifIdx",
        "beaconReg.bssid = vif.bssid",
        "beaconReg.rateCount = rateCount.uint32",
        "c_memcpy(addr beaconReg.rates[0], addr vif.supportedRatesLong[1],",
        "beaconReg.marker = 0x0403'u16",
        "c_memcpy(addr beaconReg.ssid[0], ssidP, ssidLen)",
        "beaconReg.terminator = 0",
        "cast[proc(buf: pointer) {.cdecl.}](wpaBcnCb)(addr haBuf[0])",
    ]:
        assert expected in body

    for forbidden in [
        "haBuf[0] = req.vifIdx",
        "cast[ptr uint32](addr haBuf[1])[]",
        "cast[ptr uint16](addr haBuf[5])[]",
        "cast[ptr uint32](addr haBuf[40])[]",
        "c_memcpy(addr haBuf[44]",
        "cast[ptr uint16](addr haBuf[76])[]",
        "c_memcpy(addr haBuf[78]",
        "haBuf[142] = 0",
    ]:
        assert forbidden not in body


def test_wifi_wpa_key_write_param_uses_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc mm_sta_add*", 1)[1].split(
        "proc mm_sta_del*", 1
    )[0]

    for expected in [
        "WpaKeyWriteParamView {.packed.} = object",
        "vifIdx*: uint8",
        "staIdx*: uint8",
        "keyDataLen*: uint32",
        "keyMaterial*: array[38, uint8]",
        "ssid*: array[64, uint8]",
        "quickConn*: uint8",
        "doAssert sizeof(WpaKeyWriteParamView) == 128",
        "doAssert offsetof(WpaKeyWriteParamView, staIdx) == 1",
        "doAssert offsetof(WpaKeyWriteParamView, keyDataLen) == 16",
        "doAssert offsetof(WpaKeyWriteParamView, keyMaterial) == 20",
        "doAssert offsetof(WpaKeyWriteParamView, ssid) == 58",
        "doAssert offsetof(WpaKeyWriteParamView, quickConn) == 125",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let keyReq = cast[ptr WpaKeyWriteParamView](addr keyBuf[0])",
        "keyReq.vifIdx = vif.vifIdx",
        "keyReq.staIdx = staIdxOut[]",
        "keyReq.keyDataLen = keyDataLen.uint32",
        "keyReq.quickConn = req.quickConn",
        "c_memcpy(addr keyReq.keyMaterial[0],",
        "addr vif.supportedRatesLong[1],",
        "c_memcpy(addr keyReq.ssid[0], ssidSrc, ssidLen)",
        "discard kwCb(addr keyBuf[0])",
    ]:
        assert expected in body

    for forbidden in [
        "keyBuf[0] = vif.vifIdx",
        "keyBuf[1] = staIdxOut[]",
        "cast[ptr uint32](addr keyBuf[16])[]",
        "keyBuf[125] = req.quickConn",
        "c_memcpy(addr keyBuf[20]",
        "c_memcpy(addr keyBuf[58]",
    ]:
        assert forbidden not in body


def test_wifi_wep_key_write_param_uses_typed_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    body = wifi_fw.rsplit("proc mm_sta_add*", 1)[1].split(
        "proc mm_sta_del*", 1
    )[0]

    for expected in [
        "WepKeyWriteParamView {.packed.} = object",
        "selector*: uint16",
        "keyLen*: uint8",
        "keyData*: array[44, uint8]",
        "cipherMode*: uint8",
        "instNbr*: uint8",
        "doAssert sizeof(WepKeyWriteParamView) == 56",
        "doAssert offsetof(WepKeyWriteParamView, keyLen) == 4",
        "doAssert offsetof(WepKeyWriteParamView, keyData) == 8",
        "doAssert offsetof(WepKeyWriteParamView, cipherMode) == 52",
        "doAssert offsetof(WepKeyWriteParamView, instNbr) == 53",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let wepReq = cast[ptr WepKeyWriteParamView](addr wepBuf[0])",
        "wepReq.instNbr = instNbr",
        "wepReq.selector = 0xFF00'u16",
        "wepReq.keyLen = keyLen",
        "wepReq.cipherMode = (if keyLen == 5: 0'u8 else: 3'u8)",
        "c_memcpy(addr wepReq.keyData[0], wepKeyStr, keyLen.csize_t)",
        "wepReq.cipherMode = (if keyLen == 26: 3'u8 else: 0'u8)",
        "let hexChars = cast[ptr UncheckedArray[uint8]](wepKeyStr)",
        "let hi = ascii_to_hex(hexChars[i])",
        "let lo = ascii_to_hex(hexChars[i + 1])",
        "wepReq.keyData[i div 2] = (hi shl 4) or lo",
        "wepReq.keyLen = keyLen shr 1",
        "mm_sec_machwkey_wr(addr wepBuf[0])",
    ]:
        assert expected in body

    for forbidden in [
        "wepBuf[53] = instNbr",
        "cast[ptr uint16](addr wepBuf[0])[]",
        "wepBuf[4] = keyLen",
        "wepBuf[52]",
        "c_memcpy(addr wepBuf[8]",
        "let srcBase = cast[uint](wepKeyStr)",
        "cast[ptr uint8](srcBase + i.uint)[]",
        "cast[ptr uint8](srcBase + i.uint + 1)[]",
        "wepBuf[8 + (i div 2)]",
        "wepBuf[4] = keyLen shr 1",
    ]:
        assert forbidden not in body


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


def test_wifi_hsu_michael_exports_are_real_pure_nim_wrappers():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    block_body = wifi_fw.split("proc michael_block*", 1)[1].split(
        "proc me_mic_init*", 1
    )[0]
    mic_init_body = wifi_fw.split("proc me_mic_init*", 1)[1].split(
        "{.emit: \"__attribute__((optimize(\\\"crossjumping\\\"))) void me_mic_calc",
        1,
    )[0]
    mic_calc_body = wifi_fw.split("proc me_mic_calc*", 1)[1].split(
        "proc me_mic_end*", 1
    )[0]
    mic_end_body = wifi_fw.split("proc me_mic_end*", 1)[1].split(
        "# ###########################################################################\n#                   RC: Rate Control",
        1,
    )[0]
    init_body = wifi_fw.split("proc hsu_michael_init*", 1)[1].split(
        "proc hsu_michael_calc*", 1
    )[0]
    calc_body = wifi_fw.split("proc hsu_michael_calc*", 1)[1].split(
        "proc hsu_michael_end*", 1
    )[0]
    end_body = wifi_fw.split("proc hsu_michael_end*", 1)[1].split(
        "# ###########################################################################",
        1,
    )[0]

    assert "MichaelMicContextView {.packed.} = object" in wifi_fw
    assert "left*: uint32" in wifi_fw
    assert "right*: uint32" in wifi_fw
    assert "pending*: uint32" in wifi_fw
    assert "nBytes*: uint8" in wifi_fw
    assert "doAssert sizeof(MichaelMicContextView) == 16" in wifi_fw
    assert "doAssert offsetof(MichaelMicContextView, pending) == 8" in wifi_fw
    assert "doAssert offsetof(MichaelMicContextView, nBytes) == 12" in wifi_fw
    assert "template michaelMicContextAt(p: pointer): ptr MichaelMicContextView" in wifi_fw
    assert "let mic = michaelMicContextAt(ctx)" in block_body
    assert "var L = mic.left" in block_body
    assert "var R = mic.right" in block_body
    assert "mic.left = R" in block_body
    assert "mic.right = L" in block_body
    assert "let mic = michaelMicContextAt(ctx)" in mic_init_body
    assert "mic.left = cast[ptr uint32](key)[]" in mic_init_body
    assert "mic.right = cast[ptr UncheckedArray[uint32]](key)[1]" in mic_init_body
    assert "mic.pending = 0" in mic_init_body
    assert "mic.nBytes = 0" in mic_init_body
    assert "var nBytes = mic.nBytes" in mic_calc_body
    assert "var pending = mic.pending" in mic_calc_body
    assert "mic.pending = pending" in mic_calc_body
    assert "mic.nBytes = nBytes" in mic_calc_body
    assert "let nBytes = mic.nBytes" in mic_end_body
    assert "let pending = mic.pending" in mic_end_body

    mic_bodies = block_body + mic_init_body + mic_calc_body + mic_end_body
    for forbidden in [
        "cast[ptr uint32](cast[uint](ctx) + 4)",
        "cast[ptr uint32](cast[uint](ctx) + 8)",
        "cast[ptr uint8](cast[uint](ctx) + 12)",
        "ctxAddr + 8",
        "ctxAddr + 12",
        "cast[uint](ctx)",
    ]:
        assert forbidden not in mic_bodies

    assert "var hsuMichaelCtx: array[16, uint8]" in wifi_fw
    assert "discard c_memcpy(addr hsuMichaelCtx[0], key, 8.csize_t)" in init_body
    assert "me_mic_calc(addr hsuMichaelCtx[0], data, dataLen)" in calc_body
    assert "me_mic_end(addr hsuMichaelCtx[0])" in end_body
    assert "discard c_memcpy(mic, addr hsuMichaelCtx[0], 8.csize_t)" in end_body
    assert "discard\n" not in init_body
    assert "discard\n" not in calc_body
    assert "discard\n" not in end_body


def test_wifi_tkip_group_mic_path_is_explicit_reference_return():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    body = wifi_fw.rsplit("proc txu_cntrl_tkip_mic_append*", 1)[1].split(
        "proc txu_cntrl_protect_mgmt_frame*", 1
    )[0]

    for expected in [
        "TkipMicKeyAreaView {.packed.} = object",
        "scratch*: pointer",
        "keyMaterial*: array[8, uint8]",
        "doAssert sizeof(TkipMicKeyAreaView) == 32",
        "doAssert offsetof(TkipMicKeyAreaView, scratch) == 4",
        "doAssert offsetof(TkipMicKeyAreaView, keyMaterial) == 24",
        "template tkipMicKeyArea(key: ptr VifKeySlotView;",
    ]:
        assert expected in wifi_fw

    assert "Group-key/other TKIP modes follow the reference path" in body
    assert "no immediate software MIC is appended" in body
    assert "let micArea = tkipMicKeyArea(key, micKeyOff)" in body
    assert "if micArea.scratch != nil:" in body
    assert "micArea.scratch = cast[pointer](scratch)" in body
    assert "let keyMaterial = cast[pointer](addr micArea.keyMaterial[0])" in body
    assert "let bodyStart = hostTxLinkMacHdrPtr(link, 26'u)" in body
    assert "me_mic_calc(micCtxPtr, bodyStart, bodyLen.uint32)" in body
    assert "# Group key MIC: similar but with different addresses" not in body
    assert "let bodyStart = linkAddr + 348 + 26" not in body
    assert "let frameHdr = cast[uint](payloadPtr) + 348" not in body
    assert "let txPayloadEnd = desc.bufDesc" not in body
    assert "let endOff = cast[ptr uint32](linkAddr + 76)[]" not in body
    assert "let keyAddr = cast[uint](keySlot)" not in body
    assert "let micAreaBase = keyAddr + micKeyOff - 24" not in body
    assert "cast[ptr pointer](micAreaBase + 4)[]" not in body
    assert "cast[ptr pointer](micAreaBase + 4)[] = cast[pointer](scratch)" not in body
    assert "let keyMaterial = cast[pointer](keyAddr + micKeyOff)" not in body
    assert "\n    discard\n" not in body


def test_wifi_mgmt_protection_uses_typed_frame_control_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    body = wifi_fw.rsplit("proc txu_cntrl_protect_mgmt_frame*", 1)[1].split(
        "# ###########################################################################\n#                   RX LAYER",
        1,
    )[0]

    for expected in [
        "MacFrameControlView {.packed.} = object",
        "frameControl*: uint16",
        "doAssert sizeof(MacFrameControlView) == 2",
        "doAssert offsetof(MacFrameControlView, frameControl) == 0",
        "template macFrameControlAt(p: pointer): ptr MacFrameControlView",
        "let fc = macFrameControlAt(hdrPtr)",
        "fc.frameControl = fc.frameControl or 0x4000'u16",
    ]:
        assert expected in wifi_fw if "proc " not in expected else expected in body

    for forbidden in [
        "let fc0 = cast[ptr uint8](hdrAddr)[]",
        "let fc1 = cast[ptr uint8](hdrAddr + 1)[]",
        "let fc16 = fc0.uint16 or (fc1.uint16 shl 8)",
        "let protFc = fc16 or 0x4000'u16",
        "cast[ptr uint8](hdrAddr)[] = cast[uint8](protFc and 0xFF)",
        "cast[ptr uint8](hdrAddr + 1)[] = cast[uint8]((protFc shr 8) and 0xFF)",
    ]:
        assert forbidden not in body


def test_wifi_rx_mgt_copy_uses_typed_cursor_and_word_overlay():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    body = wifi_fw.rsplit("proc rxu_mgt_frame_check*", 1)[1].split(
        "# ###########################################################################\n#                  SCAN TASK",
        1,
    )[0]

    for expected in [
        "template rxFrameWords(frame: pointer): ptr UncheckedArray[uint32]",
        "proc rxFrameCursor(frame: pointer; offset: uint): pointer {.inline.}",
        "proc copyRoundedRxWords(dst: pointer; src: pointer; byteLen: uint16) {.inline.}",
        "let frameHdr = cast[pointer](frame)",
        "copySrc = rxFrameCursor(copySrc, machdrLen.uint)",
        "rxFrameWords(copySrc)[0]",
        "rxFrameWords(copySrc)[1]",
        "rxFrameWords(copySrc)[2]",
        "copyRoundedRxWords(addr ind.body[0], copySrc, copyLen)",
    ]:
        assert expected in wifi_fw if expected.startswith(("template ", "proc ")) else expected in body

    for forbidden in [
        "let frameHdr = cast[uint](frame)",
        "copySrc = copySrc + machdrLen.uint",
        "let dst = cast[uint](addr ind.body[0])",
        "let src = copySrc",
        "cast[ptr uint32](dst + w * 4)[]",
        "cast[ptr uint32](src + w * 4)[]",
        "cast[ptr uint32](copySrc + 4)[]",
        "cast[ptr uint32](copySrc + 8)[]",
    ]:
        assert forbidden not in body


def test_wifi_mm_rx_upload_flags_are_named_by_effect():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()
    hw_info_body = wifi_fw.rsplit("proc mm_hw_info_set*", 1)[1].split(
        "proc mm_hw_ap_info_set*", 1
    )[0]
    hw_ap_body = wifi_fw.rsplit("proc mm_hw_ap_info_set*", 1)[1].split(
        "proc mm_hw_ap_info_reset*", 1
    )[0]
    mgt_body = wifi_fw.rsplit("proc rxu_mgt_frame_check*", 1)[1].split(
        "# ###########################################################################\n#                  SCAN TASK",
        1,
    )[0]

    for expected in [
        "rxPromiscUploadFlag*: uint32",
        "apPromiscUploadFlag*: uint32",
        "doAssert offsetof(MmEnvView, rxPromiscUploadFlag) == 44",
        "doAssert offsetof(MmEnvView, apPromiscUploadFlag) == 48",
        "if mm.rxPromiscUploadFlag != 0:",
        "if mm.apPromiscUploadFlag != 0:",
    ]:
        assert expected in wifi_fw

    assert "if mm.rxPromiscUploadFlag != 0:" in hw_info_body
    assert "if mm.apPromiscUploadFlag != 0:" in hw_ap_body
    assert "(mm.rxPromiscUploadFlag or mm.apPromiscUploadFlag) != 0" in mgt_body

    for forbidden in [
        "uploadWord44",
        "mm.word48",
        "offsetof(MmEnvView, word48)",
        "staPromiscUploadFlag",
    ]:
        assert forbidden not in wifi_fw


def test_wifi_set_active_confirm_handlers_use_state_predicates():
    wifi_fw = (ROOT / "src/bl808/wifi_fw.nim").read_text()

    assert "proc smSetActiveCfmStateAllowed(): bool {.inline.}" in wifi_fw
    assert "proc apmSetActiveCfmStateAllowed(): bool {.inline.}" in wifi_fw
    assert "if not smSetActiveCfmStateAllowed():" in wifi_fw
    assert "if not apmSetActiveCfmStateAllowed():" in wifi_fw

    sm_handler = wifi_fw.split("proc me_set_active_cfm_handler_sm*", 1)[1].split(
        "proc me_set_active_cfm_handler_apm*", 1
    )[0]
    apm_handler = wifi_fw.split("proc me_set_active_cfm_handler_apm*", 1)[1].split(
        "{.emit:", 1
    )[0]
    assert "\n    discard\n" not in sm_handler
    assert "\n    discard\n" not in apm_handler


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
