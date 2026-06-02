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


def test_wifi_async_lifecycle_uses_event_futures_not_poll_loops():
    wifi = (ROOT / "src/bl808/wifi.nim").read_text()
    assert "wifiCompletePendingEvents()" in wifi
    assert "proc wifiInstallServiceHook*" in wifi
    assert "proc wifiConfigureServiceHook*" in wifi
    assert "proc wifiSetBleCoexistenceMode*" in wifi
    assert "proc wifiStaKeepaliveAckOkCount*" in wifi
    assert "addSchedulerTimedPollHook(wifiServicePollHook, readTick())" in wifi
    assert "wifiScanFuture = newLocalCpsFuture[uint32]()" in wifi
    assert "wifiConnectFuture = newLocalCpsFuture[WifiError]()" in wifi
    assert "wifiDisconnectFuture = newLocalCpsFuture[WifiError]()" in wifi

    scan_body = wifi.split("proc wifiScanAsync*", 1)[1].split(
        "proc wifiConnect*", 1
    )[0]
    connect_body = wifi.split("proc wifiConnectAsync*", 1)[1].split(
        "when defined(bl808WifiVendor) and defined(bl808WifiNimFwDiag)", 1
    )[0]
    disconnect_body = wifi.split("proc wifiDisconnectAsync*", 1)[1].split(
        "proc wifiStartAp*", 1
    )[0]
    for body in (scan_body, connect_body, disconnect_body):
        assert "await sleep" not in body
        assert "while waited <" not in body


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
