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

WIFI_NIM_RF_TESTS = {
    "m0_wifi_nimfw_scan_hal_test",
    "m0_wifi_nimfw_hal_test",
    "m0_wifi_nimfw_keepalive_hal_test",
    "m0_wifi_nimfw_qosnull_keepalive_hal_test",
    "m0_wifi_nimfw_bad_password_hal_test",
    "m0_wifi_lwip_smoke",
    "m0_wifi_nimfw_boot_test",
    "m0_ble_wifi_nim_coex_hal_test",
    "m0_ble_wifi_nim_coex_long_hal_test",
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


def test_nim_wifi_validation_uses_pure_bl808_rf_path():
    tests = _tests_by_name()
    missing = WIFI_NIM_RF_TESTS.difference(tests)
    assert not missing

    for name in sorted(WIFI_NIM_RF_TESTS):
        defines = _all_defines(tests[name])
        assert defines.get("bl808WifiNimFw") == "1"
        assert defines.get("bl808WifiUseBl808Rf") == "1", name


def test_nim_wifi_connect_snapshot_captures_rf70_rf88_rfd0_trace_state():
    snapshot = _tests_by_name()["m0_wifi_nimfw_hal_test"].get("jtag_snapshot", [])
    for command in (
        "mdw {sym:nim_wifi_rf_breakpoint_tag} 1",
        "mdw {sym:nim_wifi_rf_breakpoint_count} 1",
        "mdw {sym:nim_wifi_rf_stage_snapshot_count} 1",
        "mdw {sym:nim_wifi_rf_stage_tag_log} 8",
        "mdw {sym:nim_wifi_rf_stage_rf70_log} 8",
        "mdw {sym:nim_wifi_rf_stage_rf88_log} 8",
        "mdw {sym:nim_wifi_rf_stage_rfd0_log} 8",
        "mdw {sym:nim_wifi_rf_optimize_channel_log} 8",
        "mdw {sym:nim_wifi_rf_optimize_device_log} 8",
        "mdw {sym:nim_wifi_rf_optimize_rfd0_log} 8",
        "mdw {sym:nim_wifi_rf_optimize_rf70_log} 8",
        "mdw {sym:nim_wifi_rf_optimize_nibble_log} 8",
        "mdw {sym:nim_wifi_rf_pri_txcal_count} 1",
        "mdw {sym:nim_wifi_rf_pri_rxcal_count} 1",
        "mdw {sym:nim_wifi_rf_bz_txcal_word0_log} 9",
        "mdw {sym:nim_wifi_rf_bz_txcal_word1_log} 9",
        "mdw {sym:nim_wifi_rf_bz_txcal_ok_mask_log} 9",
        "mdw 0x20001070 1",
        "mdw 0x20001088 1",
        "mdw 0x200010D0 1",
    ):
        assert command in snapshot


def test_nim_wifi_cold_scan_validation_exercises_cold_rf_init_path():
    test = _tests_by_name()["m0_wifi_nimfw_cold_scan_hal_test"]
    assert "experimental" in test.get("tiers", [])

    defines = _all_defines(test)
    assert defines.get("bl808WifiNimFw") == "1"
    assert defines.get("bl808WifiUseBl808Rf") == "1"
    assert defines.get("bl808WifiRfColdInit") == "1"
    assert defines.get("WifiScanOnly") == "1"

    snapshot = test.get("jtag_snapshot", [])
    for command in (
        "mdw {sym:nimfw_dbg_rf_phase} 1",
        "mdw {sym:nimfw_dbg_rf_restore} 1",
        "mdw {sym:nimfw_dbg_rf_api_mode} 1",
        "mdw {sym:nimfw_dbg_phy_init_count} 1",
        "mdw {sym:nimfw_dbg_phy_init_phase} 1",
        "mdw {sym:nimfw_dbg_phy_modem_version} 1",
        "mdw {sym:nimfw_dbg_phy_clock_count} 1",
        "mdw {sym:nimfw_dbg_phy_agc_copy_count} 1",
        "mdw {sym:nimfw_dbg_phy_agc_source_first} 1",
        "mdw {sym:nimfw_dbg_phy_agc_source_last} 1",
        "mdw {sym:nimfw_dbg_phy_agc_dest_first} 1",
        "mdw {sym:nimfw_dbg_phy_agc_dest_last} 1",
        "mdw {sym:nimfw_dbg_phy_wifi_ldpc_absent} 1",
        "mdw {sym:nim_wifi_rf_fixed_val_count} 1",
        "mdw {sym:nim_wifi_rf_fixed_val_device} 1",
        "mdw {sym:nim_wifi_rf_fixed_val_branch} 1",
        "mdw {sym:nim_wifi_rf_fixed_val_rf70} 1",
        "mdw {sym:nim_wifi_rf_fixed_val_rf88} 1",
        "mdw {sym:nim_wifi_rf_fixed_val_rfd0} 1",
        "mdw {sym:nim_wifi_rf_fixed_val_rf814} 1",
        "mdw {sym:nim_wifi_rf_fixed_val_rfa0} 1",
        "mdw {sym:nim_wifi_rf_rf70_replay_apply_count} 1",
        "mdw {sym:nim_wifi_rf_rf70_replay_reason} 1",
        "mdw {sym:nim_wifi_rf_rf70_replay_reg_before} 1",
        "mdw {sym:nim_wifi_rf_rf70_replay_reg_after} 1",
        "mdw {sym:nim_wifi_rf_rf70_replay_cal_word3_before} 1",
        "mdw {sym:nim_wifi_rf_rf70_replay_cal_word4_before} 1",
        "mdw {sym:nim_wifi_rf_rf70_replay_cal_word3_after} 1",
        "mdw {sym:nim_wifi_rf_rf70_replay_cal_word4_after} 1",
        "mdw {sym:nim_wifi_rf_rf70_txcal_window_mask} 1",
        "mdw {sym:nim_wifi_rf_rf70_txcal_window0_nibble} 1",
        "mdw {sym:nim_wifi_rf_rf70_txcal_window1_nibble} 1",
        "mdw {sym:nim_wifi_rf_rf70_txcal_window2_nibble} 1",
        "mdw {sym:nim_wifi_rf_rf70_txcal_search_count} 1",
        "mdw {sym:nim_wifi_rf_rf70_txcal_search_ok_mask} 1",
        "mdw {sym:nim_wifi_rf_rf70_txcal_search_best_nibble} 3",
        "mdw {sym:nim_wifi_rf_rf70_txcal_search_runner_nibble} 3",
        "mdw {sym:nim_wifi_rf_rf70_txcal_search_best_sample} 3",
        "mdw {sym:nim_wifi_rf_rf70_txcal_search_runner_sample} 3",
        "mdw {sym:nim_wifi_rf_rf70_txcal_search_ctrl} 3",
        "mdw {sym:nim_wifi_rf_rf70_txcal_search_mode} 3",
        "mdw {sym:nim_wifi_rf_rf70_txcal_search_i_raw} 3",
        "mdw {sym:nim_wifi_rf_rf70_txcal_candidate_ok_mask} 3",
        "mdw {sym:nim_wifi_rf_rf70_txcal_candidate_sample} 48",
        "mdw {sym:nim_wifi_rf_pre_rf70_txcal_amp} 1",
        "mdw {sym:nim_wifi_rf_pre_rf70_txcal_amp_mean} 1",
        "mdw {sym:nim_wifi_rf_pre_rf70_rf70} 1",
        "mdw {sym:nim_wifi_rf_pre_rf70_rf6c} 1",
        "mdw {sym:nim_wifi_rf_pre_rf70_rf120c} 1",
        "mdw {sym:nim_wifi_rf_pre_rf70_rf1214} 1",
        "mdw {sym:nim_wifi_rf_pre_rf70_rf1218} 1",
        "mdw {sym:nim_wifi_rf_pre_rf70_rf1618} 1",
        "mdw {sym:nim_wifi_rf_pre_rf70_rf161c} 1",
        "mdw {sym:nim_wifi_rf_stage_rf70_log} 8",
        "mdw {sym:nim_wifi_rf_stage_rf88_log} 8",
        "mdw {sym:nim_wifi_rf_stage_rfd0_log} 8",
        "mdw 0x20001070 1",
        "mdw 0x20001088 1",
        "mdw 0x200010D0 1",
    ):
        assert command in snapshot


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


def test_wifi_lwip_smoke_requires_dhcp_local_icmp_and_public_icmp_diagnostics():
    test = _tests_by_name()["m0_wifi_lwip_smoke"]
    defines = _all_defines(test)
    required = test.get("required", [])
    snapshot = test.get("jtag_snapshot", [])

    assert defines.get("bl808WifiNimFw") == "1"
    assert defines.get("bl808WifiRealLwip") == "1"
    assert defines.get("bl808WifiRxPbufInput") == "1"
    assert defines.get("WifiIcmpTargetA", {}).get("default") == 1
    assert defines.get("WifiIcmpTargetB", {}).get("default") == 1
    assert defines.get("WifiIcmpTargetC", {}).get("default") == 1
    assert defines.get("WifiIcmpTargetD", {}).get("default") == 1
    assert "@e2e dhcp:ok" in required
    assert "@e2e icmp:start dst=0x01010101" in required
    assert "@e2e icmp:ok" in required
    for command in [
        "mdw {sym:nimfw_dbg_dhcp_tx_final_break_hits} 1",
        "mdw {sym:nimfw_dbg_dhcp_tx_final_desc0} 1",
        "mdw {sym:nimfw_dbg_dhcp_tx_final_hw_len} 1",
        "mdw {sym:nimfw_dbg_dhcp_tx_final_hthd_next} 1",
        "mdw {sym:nimfw_dbg_dhcp_tx_final_pthd_end} 1",
        "mdw {sym:nimfw_dbg_dhcp_tx_break_hits} 1",
        "mdw {sym:nimfw_dbg_dhcp_request_tx_break_hits} 1",
        "mdw {sym:nimfw_dbg_dhcp_tx_msg_hist} 8",
        "mdw {sym:nimfw_dbg_icmp_tx_target} 1",
        "mdw {sym:nimfw_dbg_icmp_tx_rc} 1",
        "mdw {sym:nimfw_dbg_icmp_tcpip_ok_before} 1",
        "mdw {sym:nimfw_dbg_icmp_tcpip_ok_after} 1",
        "mdw {sym:nimfw_dbg_icmp_cb_count} 1",
        "mdw {sym:nimfw_dbg_icmp_cb_ip0} 1",
        "mdw {sym:nimfw_dbg_icmp_cb_reject} 1",
        "mdw {sym:nimfw_dbg_dhcp_udp_csum_repair} 1",
        "mdw {sym:nimfw_dbg_dhcp_udp_csum_vafter} 1",
        "mdw {sym:nimfw_dbg_dhcp_req_udp_csum_at_copy} 1",
        "mdw 0x24C00824 1",
        "mdw 0x24C00834 1",
        "mdw 0x24C09000 32",
        "mdw 0x24C0A000 32",
        "mdw 0x24C0B390 1",
    ]:
        assert command in snapshot


def test_wifi_http_server_example_uses_pure_nim_wifi_and_real_lwip():
    test = _tests_by_name()["m0_wifi_http_server"]
    defines = _all_defines(test)
    required = test.get("required", [])

    assert defines.get("bl808WifiNimFw") == "1"
    assert defines.get("bl808WifiUseBl808Rf") == "1"
    assert defines.get("bl808WifiRealLwip") == "1"
    assert defines.get("bl808WifiRealLwipTcp") == "1"
    assert defines.get("bl808WifiRxPbufInput") == "1"
    assert defines.get("WifiSsid", {}).get("env") == "BL808_WIFI_SSID"
    assert defines.get("WifiPassword", {}).get("secret_env") == "BL808_WIFI_PASSWORD"
    assert "WifiChannel" not in defines
    assert defines.get("HttpPort", {}).get("default") == 80
    assert defines.get("UdpEchoPort", {}).get("default") == 65000
    assert defines.get("UdpProbeTargetA", {}).get("default") == 0
    assert defines.get("UdpProbeTargetB", {}).get("default") == 0
    assert defines.get("UdpProbeTargetC", {}).get("default") == 0
    assert defines.get("UdpProbeTargetD", {}).get("default") == 0
    assert defines.get("UdpProbePort", {}).get("default") == 65001
    assert "@e2e scan:ok" in required
    assert "@e2e dhcp:ok" in required
    assert "@e2e tcp:start" in required
    assert "proto=udp" in required
    assert "Ready for HTTP/1.1 and UDP echo client requests" in required
    assert "[PASS] lwIP TCP HTTP/1.1 response" in required
    assert "[PASS] lwIP UDP echo bytes=" in required
    host_actions = test.get("host_actions", [])
    assert len(host_actions) == 1
    host = host_actions[0]
    assert host.get("after_marker") == "Ready for HTTP/1.1 and UDP echo client requests"
    assert host.get("cmd") == [
        "{python}",
        "tools/probe_wifi_lwip_tcp_udp.py",
        "--ip",
        "{e2e:dhcp:ok:ip}",
        "--http-port",
        "80",
        "--udp-port",
        "65000",
        "--timeout",
        "10",
    ]
    assert "[PASS] lwIP TCP HTTP/1.1 response" in host.get("required", [])
    assert "[PASS] lwIP UDP echo bytes=" in host.get("required", [])

    example = (REPO_ROOT / "examples/m0_wifi_http_server.nim").read_text()
    for expected in [
        "import bl808/kernel/lwipcore",
        "lwipInit()",
        'proc nimHttpRecv(arg, pcb, p: pointer; err: ErrT): ErrT',
        'exportc: "nim_http_recv"',
        "tcpBind(pcb, addr any, port)",
        "tcpAcceptShim(cast[pointer](listenPcb))",
        "wifiConnect(WifiSsid, WifiPassword, 0'u8)",
        "scanDiagHasFreshResult()",
        'HttpGreeting = "Hello World! from Nim on BL808"',
        "DhcpTimeoutMs = 30_000'u32",
        "proc bl_wifi_mac_addr_get(mac: ptr uint8): cint",
        "HTTP/1.1 200 OK",
        "Content-Length: ",
        "buildHttpBody(rxLen)",
        "buildHttpHeader(body.len)",
        "appendText(result, \"device=BL808\\n\")",
        "appendText(result, \"device_mac=\")",
        "appendMac(result, deviceMac)",
        "appendText(result, \"scan_diag=\")",
        "udpBind(pcb, addr any, port)",
        "udpRecv(pcb, nimUdpRecv, nil)",
        "sendUdpProbe()",
        "pollNetwork()",
        'exportc: "nim_udp_probe_send_count"',
        'exportc: "nim_udp_recv_count"',
        "phaseMark(Phase.tcp, Kind.ok)",
    ]:
        assert expected in example


def test_wifi_validation_targets_do_not_pin_scan_channel():
    manifest_text = MANIFEST.read_text()
    assert "BL808_WIFI_CHANNEL" not in manifest_text

    for name, test in _tests_by_name().items():
        defines = _all_defines(test)
        assert "WifiChannel" not in defines, name


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
