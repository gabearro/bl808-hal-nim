"""Checks for production-facing hardware validation manifest entries."""

from __future__ import annotations

import json
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = REPO_ROOT / "tools" / "hardware_validation.json"

BLE_NIM_PRODUCTION_TESTS = {
    "m0_ble_nim_controller_hal_test",
    "m0_ble_nim_controller_pure_central_hal_test",
    "m0_ble_nim_controller_pure_scan_hal_test",
    "m0_ble_wifi_nim_hal_test",
    "m0_ble_wifi_nim_scan_hal_test",
}

def _tests_by_name() -> dict[str, dict]:
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    return {test["name"]: test for test in data["tests"]}


def _all_defines(test: dict) -> dict[str, object]:
    merged: dict[str, object] = {}
    for build in test.get("build", []):
        merged.update(build.get("defines", {}))
    return merged


def test_production_ble_nim_tests_do_not_enable_vendor_ble_paths():
    tests = _tests_by_name()
    missing = BLE_NIM_PRODUCTION_TESTS.difference(tests)
    assert not missing

    for name in sorted(BLE_NIM_PRODUCTION_TESTS):
        assert "full" in tests[name].get("tiers", [])
        defines = _all_defines(tests[name])
        vendor_ble_defines = sorted(
            key for key in defines if key.startswith("bl808BleVendor")
        )
        assert vendor_ble_defines == [], (
            f"{name} must stay on the pure Nim BLE path; found "
            f"{vendor_ble_defines}"
        )
        assert "bl808BleNimBl606pPhyRf" not in defines
        for live_diag in ("bl808BleMidAdvLoopDiag", "bl808BleFinalAdvLoopDiag"):
            assert defines.get(live_diag) in (None, "0", 0, False), (
                f"{name} must not enable live connection diagnostics in full-tier "
                f"validation; found {live_diag}={defines.get(live_diag)!r}"
            )


def test_manifest_does_not_enable_vendor_ble_or_wifi_paths():
    tests = _tests_by_name()
    for name, test in tests.items():
        defines = _all_defines(test)
        vendor_defines = sorted(
            key for key in defines
            if key.startswith("bl808BleVendor") or
            key.startswith("bl808WifiVendor")
        )
        assert vendor_defines == [], (
            f"{name} must stay on pure Nim BLE/WiFi paths; found "
            f"{vendor_defines}"
        )


def test_pure_nim_central_scan_validation_is_not_vendor_assisted():
    test = _tests_by_name()["m0_ble_nim_controller_pure_scan_hal_test"]
    assert "full" in test.get("tiers", [])
    defines = _all_defines(test)
    assert defines.get("BleCentralScanOnly") == "1"
    assert defines.get("bl808BleNimPureCentral") == "1"
    assert all(
        not key.startswith("bl808BleVendor")
        for key in defines
    )


def test_pure_nim_central_connect_validation_is_not_vendor_assisted():
    test = _tests_by_name()["m0_ble_nim_controller_pure_central_hal_test"]
    assert "full" in test.get("tiers", [])
    defines = _all_defines(test)
    assert defines.get("bl808BleNimPureCentral") == "1"
    assert defines.get("bl808BleNimPureConnection") == "1"
    assert defines.get("bl808BleNimManualConnTx") == "1"
    assert defines.get("BleCentralScanOnly") is None
    assert all(
        not key.startswith("bl808BleVendor")
        for key in defines
    )


def test_pure_nim_central_connect_snapshot_captures_btble_and_clic_state():
    test = _tests_by_name()["m0_ble_nim_controller_pure_central_hal_test"]
    snapshot = test.get("jtag_snapshot", [])

    for command in (
        "reg a0",
        "reg a1",
        "reg a2",
        "reg a3",
        "reg a4",
        "reg a5",
        "reg t0",
        "reg t1",
        "mdw 0x28000000 20",
        "mdw 0x28000018 6",
        "mdw 0x28000024 1",
        "mdw 0x28000100 8",
        "mdw 0x28010000 32",
        "mdw 0xe0801050 8",
        "mdw 0xe08010c0 8",
        "mdw 0xe08010e0 8",
        "mdw 0xe0801100 8",
        "mdw 0xe0801120 8",
        "mdw 0x20000050 6",
    ):
        assert command in snapshot


def test_peripheral_connect_snapshots_capture_adv_windows_and_txcal():
    tests = _tests_by_name()

    nim_snapshot = tests["m0_ble_nim_controller_hal_test"].get("jtag_snapshot", [])
    for command in (
        "mdw 0x28000110 1",
        "mdw 0x28000800 80",
        "mdw 0x28000970 16",
        "mdw 0x28010000 32",
        "mdw 0x28010120 32",
        "mdw 0x28010558 16",
        "mdb 0x28010a2c 64",
        "mdb 0x28010a4c 64",
        "mdw 0x280009c0 8",
        "mdw {sym:nim_ble_rf_pri_txcal_count} 1",
        "mdw {sym:nim_ble_rf_txcal_wait_timeout_count} 1",
        "mdw {sym:nim_ble_rf_txcal_search_count} 1",
        "mdw {sym:nim_ble_rf_txcal_word0_log} 8",
        "mdw {sym:nim_ble_rf_txcal_word1_log} 8",
        "mdw {sym:nim_ble_rf_txcal_power_log} 8",
    ):
        assert command in nim_snapshot

    vendor_snapshot = tests["m0_ble_bl606p_hal_test"].get("jtag_snapshot", [])
    for command in (
        "mdw 0x28010120 32",
        "mdw 0x28010558 16",
        "mdb 0x28010a2c 64",
        "mdb 0x28010a52 64",
    ):
        assert command in vendor_snapshot


def test_mixed_ble_wifi_snapshots_capture_connection_failure_state():
    tests = _tests_by_name()

    for name in (
        "m0_ble_wifi_nim_hal_test",
        "m0_ble_wifi_nim_coex_long_hal_test",
        "m0_ble_wifi_nim_scan_hal_test",
    ):
        snapshot = tests[name].get("jtag_snapshot", [])
        for command in (
            "reg pc",
            "reg mepc",
            "reg mcause",
            "mdw {sym:nim_ble_dbg_rx_connect_ind_count} 1",
            "mdw {sym:nim_connect_ind_pending} 1",
            "mdw {sym:nim_connect_ind_queued_count} 1",
            "mdw {sym:nim_connect_ind_service_count} 1",
            "mdw {sym:nim_connect_ind_return_count} 1",
            "mdw {sym:nim_adv_sch_event_active} 1",
            "mdw {sym:nim_conn_start_return_count} 1",
            "mdb {sym:nim_adv_enabled} 1",
            "mdb {sym:nim_adv_data_len} 1",
            "mdb {sym:nim_scan_rsp_data_len} 1",
            "mdb {sym:nim_adv_params} 15",
            "mdb {sym:nim_adv_data} 31",
            "mdb {sym:nim_scan_rsp_data} 31",
            "mdw {sym:nim_adv_sch_program_count} 1",
            "mdw {sym:nim_adv_sch_event_count} 1",
            "mdw {sym:nim_adv_sch_end_count} 1",
            "mdw {sym:nim_adv_sch_last_event} 1",
            "mdw {sym:nim_vendor_lld_con_start_count} 2",
        ):
            assert command in snapshot

        if name != "m0_ble_wifi_nim_coex_long_hal_test":
            for command in (
                "mdw {sym:nim_vendor_lld_con_start_param} 12",
                "mdw {sym:nim_conn_sched_delta_log} 8",
                "mdw {sym:nim_conn_sched_channel_log} 8",
                "mdw {sym:nim_lld_rx_last_status} 1",
                "mdw {sym:nim_conn_rx_status_reject_count} 1",
                "mdw {sym:nim_llcp_tx_count} 1",
                "mdw {sym:nim_llcp_rx_count} 1",
                "mdw {sym:nim_llcp_rx_malformed_count} 1",
                "mdw {sym:nim_acl_rx_count} 1",
                "mdw {sym:nim_acl_rx_drop_count} 1",
                "mdw {sym:nim_vendor_llcp_rx_count} 1",
                "mdw 0x28010000 32",
            ):
                assert command in snapshot


def test_mixed_ble_wifi_jtag_flash_keeps_runtime_jtag():
    tests = _tests_by_name()

    for name in ("m0_ble_wifi_nim_hal_test", "m0_ble_wifi_nim_scan_hal_test"):
        test = tests[name]
        assert test.get("jtag_flash_reset_capture") is True
        assert test.get("jtag_flash_runtime_jtag") is True


def test_runtime_jtag_reset_capture_does_not_require_startup_banner():
    tests = _tests_by_name()

    for name, test in tests.items():
        if not (
            test.get("jtag_flash_reset_capture") is True
            and test.get("jtag_flash_runtime_jtag") is True
        ):
            continue
        required = test.get("required", [])
        assert not any(marker.startswith("=== BL808") for marker in required), name


def test_pure_nim_central_host_advertiser_is_stable():
    tests = _tests_by_name()
    for name in (
        "m0_ble_nim_controller_pure_scan_hal_test",
        "m0_ble_nim_controller_pure_central_hal_test",
    ):
        actions = tests[name].get("pre_host_actions", [])
        assert actions, f"{name} must start the macOS advertiser"
        cmd = actions[0].get("cmd", [])
        assert "--restart-interval" not in cmd
