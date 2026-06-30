"""Checks for production-facing hardware validation manifest entries."""

from __future__ import annotations

import json
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = REPO_ROOT / "tools" / "hardware_validation.json"
MAKEFILE = REPO_ROOT / "Makefile"

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


def _manifest() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


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


def test_npu_smoke_manifest_requires_recovered_overlay_markers_and_fault_rejection():
    manifest = _manifest()
    test = {item["name"]: item for item in manifest["tests"]}["m0_npu_smoke_test"]
    required = test.get("required", [])
    forbidden = manifest.get("defaults", {}).get("forbidden", []) + test.get("forbidden", [])

    assert "full" in test.get("tiers", [])
    assert test["build"] == [
        {
            "id": "kernel",
            "core": "bl808m0",
            "source": "examples/m0_npu_smoke_test.nim",
            "flash": "m0",
        }
    ]
    for marker in (
        "=== BL808 NPU Smoke Test ===",
        "[PASS] NPU clock enabled",
        "[PASS] NPU reset cycle released",
        "[PASS] NPU SRAM released",
        "[PASS] NPU AW QoS set",
        "[PASS] NPU read limiter",
        "[PASS] NPU instruction stream configured",
        "[PASS] NPU layer setup keeps instruction addr",
        "[PASS] NPU unsigned input reset",
        "[PASS] NPU execution state stopped",
        "[PASS] NPU decoded conv eligibility",
        "[PASS] NPU odd stride workaround",
        "[PASS] NPU CPU total first weight layer",
        "[PASS] NPU CPU total first bias layer",
        "[PASS] NPU CPU total no first weight",
        "[PASS] NPU CPU total no first bias",
        "[PASS] NPU materialize fit detail",
        "[PASS] NPU materialize weight required",
        "[PASS] NPU materialize bias required",
        "[PASS] NPU materialize temporary required",
        "[PASS] NPU materialize temporary provided",
        "[PASS] NPU layer run unsupported",
        "[PASS] NPU smoke complete",
    ):
        assert marker in required

    for marker in ("[FAIL]", "[FAULT]", "panic", "trap_entry", "fatal:"):
        assert marker in forbidden


def test_npu_route_smoke_manifest_requires_focused_route_markers():
    manifest = _manifest()
    test = {item["name"]: item for item in manifest["tests"]}["m0_npu_route_smoke_test"]
    required = test.get("required", [])
    forbidden = manifest.get("defaults", {}).get("forbidden", []) + test.get("forbidden", [])

    assert "full" in test.get("tiers", [])
    assert test["build"] == [
        {
            "id": "kernel",
            "core": "bl808m0",
            "source": "examples/m0_npu_route_smoke_test.nim",
            "flash": "m0",
        }
    ]
    for marker in (
        "=== BL808 NPU Route Smoke Test ===",
        "[PASS] NPU route TFLite parsed route supported",
        "[PASS] NPU route TFLite parsed route fits",
        "[PASS] NPU route TFLite parsed route streams",
        "[PASS] NPU route TFLite parsed route channels",
        "[PASS] NPU route TFLite parsed route output",
        "[PASS] NPU route TFLite parsed route max supported",
        "[PASS] NPU route TFLite parsed route max fits",
        "[PASS] NPU route TFLite parsed route max streams",
        "[PASS] NPU route TFLite parsed route max channels",
        "[PASS] NPU route TFLite parsed route max output",
        "[PASS] NPU route TFLite parsed route W supported",
        "[PASS] NPU route TFLite parsed route W fits",
        "[PASS] NPU route TFLite parsed route W streams",
        "[PASS] NPU route TFLite parsed route W channels",
        "[PASS] NPU route TFLite parsed route W output",
        "[PASS] NPU route descriptor emit fits",
        "[PASS] NPU route descriptor second output",
        "[PASS] NPU route descriptor short preserved",
        "[PASS] NPU route smoke complete",
    ):
        assert marker in required

    for marker in ("[FAIL]", "[FAULT]", "panic", "trap_entry", "fatal:"):
        assert marker in forbidden


def test_npu_model_smoke_manifest_requires_focused_previous_activation_markers():
    manifest = _manifest()
    test = {item["name"]: item for item in manifest["tests"]}["m0_npu_model_smoke_test"]
    required = test.get("required", [])
    required_any = [
        marker
        for group in test.get("required_any", [])
        for marker in group
    ]
    forbidden = manifest.get("defaults", {}).get("forbidden", []) + test.get("forbidden", [])

    assert "full" in test.get("tiers", [])
    assert test.get("defines", {}).get("HwValidationLogCapacity") == "32768"
    assert test.get("defines", {}).get("HwValidationLogExternalBuffer") == "1"
    assert test.get("defines", {}).get("bl808LargeStack") == "1"
    assert test["build"] == [
        {
            "id": "kernel",
            "core": "bl808m0",
            "source": "examples/m0_npu_model_smoke_test.nim",
            "flash": "m0",
        }
    ]
    for marker in (
        "=== BL808 NPU Model Smoke Test ===",
        "[PASS] NPU model fixed plan supported",
        "[PASS] NPU model fixed plan weight bytes",
        "[PASS] NPU model fixed plan output",
        "[PASS] NPU model fixed sequential preflight",
        "[PASS] NPU model fixed sequential valid",
        "[PASS] NPU model fixed sequential output",
        "[PASS] NPU model fixed e2e valid",
        "[PASS] NPU model fixed e2e first block",
        "[PASS] NPU model fixed compare trailing",
        "[PASS] NPU model fixed sequential short blocked",
        "[PASS] NPU model TFLite plan supported",
        "[PASS] NPU model TFLite plan bias bytes",
        "[PASS] NPU model TFLite plan output",
        "[PASS] NPU model TFLite sequential preflight",
        "[PASS] NPU model TFLite sequential valid",
        "[PASS] NPU model TFLite sequential output",
        "[PASS] NPU model TFLite e2e valid",
        "[PASS] NPU model TFLite e2e first block",
        "[PASS] NPU model TFLite compare trailing",
        "[PASS] NPU model TFLite sequential short blocked",
        "[PASS] NPU model MNIST TFLite oracle valid",
        "[PASS] NPU model MNIST TFLite oracle input scale bits",
        "[PASS] NPU model MNIST TFLite oracle fully connected wiring",
        "[PASS] NPU model MNIST TFLite support metadata",
        "[PASS] NPU model MNIST TFLite support fc reference",
        "[PASS] NPU model MNIST TFLite support output pending",
        "[PASS] NPU model MNIST TFLite support block",
        "[PASS] NPU model MNIST converter dependency plan",
        "[PASS] NPU model MNIST converter dependency missing",
        "[PASS] NPU model MNIST converter dependency classes",
        "[PASS] NPU model MNIST converter dependency first",
        "[PASS] NPU model MNIST converter artifact regeneration plan",
        "[PASS] NPU model MNIST converter artifact regeneration blocked",
        "[PASS] NPU model MNIST converter artifact regeneration static",
        "[PASS] NPU model MNIST converter artifact regeneration block",
        "[PASS] NPU model MNIST toolchain SRAM readiness evidence",
        "[PASS] NPU model MNIST toolchain SRAM readiness patch size",
        "[PASS] NPU model MNIST toolchain SRAM readiness active slots",
        "[PASS] NPU model MNIST toolchain SRAM readiness spare slots",
        "[PASS] NPU model MNIST toolchain SRAM readiness persistent fit",
        "[PASS] NPU model MNIST toolchain SRAM readiness output blocked",
        "[PASS] NPU model TFLite fully connected reference fits",
        "[PASS] NPU model parsed single fixed diagnostics valid",
        "[PASS] NPU model parsed single fixed diagnostics readiness block",
        "[PASS] NPU model parsed layer fixed diagnostics valid",
        "[PASS] NPU model parsed layer fixed diagnostics reference block",
        "[PASS] NPU model parsed single fixed diagnostics stream block",
        "[PASS] NPU model parsed single TFLite diagnostics valid",
        "[PASS] NPU model parsed single TFLite diagnostics readiness block",
        "[PASS] NPU model parsed layer TFLite diagnostics valid",
        "[PASS] NPU model parsed layer TFLite diagnostics reference block",
        "[PASS] NPU model parsed single TFLite diagnostics stream block",
        "[PASS] NPU model fixed previous shortcut preflight",
        "[PASS] NPU model fixed previous shortcut executed",
        "[PASS] NPU model fixed previous shortcut valid",
        "[PASS] NPU model fixed previous shortcut completed",
        "[PASS] NPU model fixed previous shortcut streams",
        "[PASS] NPU model fixed previous shortcut scratch",
        "[PASS] NPU model fixed previous shortcut output",
        "[PASS] NPU model TFLite previous shortcut preflight",
        "[PASS] NPU model TFLite previous shortcut executed",
        "[PASS] NPU model TFLite previous shortcut valid",
        "[PASS] NPU model TFLite previous shortcut completed",
        "[PASS] NPU model TFLite previous shortcut streams",
        "[PASS] NPU model TFLite previous shortcut scratch",
        "[PASS] NPU model TFLite previous shortcut output",
        "[PASS] NPU model run prepared ready",
        "[PASS] NPU model run prepared first block none",
        "[PASS] NPU model run sequence configurable",
        "[PASS] NPU model run sequence first block none",
        "[PASS] NPU model run sequence readiness first block none",
        "[PASS] NPU model run sequence cache ranges",
        "[PASS] NPU model run sequence blocked first block config",
        "[PASS] NPU model run sequence blocked config first block weight",
        "[PASS] NPU model run state sequence configurable",
        "[PASS] NPU model weight kernel dispatch evidence",
        "[PASS] NPU model weight kernel dispatch 3x3",
        "[PASS] NPU model weight kernel dispatch 3x3 dilated",
        "[PASS] NPU model weight kernel dispatch 5x5",
        "[PASS] NPU model weight kernel dispatch 7x7",
        "[PASS] NPU model weight kernel dispatch unsupported",
        "[PASS] NPU model weight kernel dispatch zero pack",
        "[PASS] NPU model weight kernel dispatch unaligned",
        "[PASS] NPU model weight kernel dispatch short buffer",
        "[PASS] NPU model weight kernel dispatch first bytes",
        "[PASS] NPU model weight kernel dispatch padding bytes",
        "[PASS] NPU model weight kernel dispatch cursors",
        "[PASS] NPU model run execution complete",
        "[PASS] NPU model run execution no first failure",
        "[PASS] NPU model run execution first block none",
        "[PASS] NPU model run execution sequence first block none",
        "[PASS] NPU model run execution wait timeout",
        "[PASS] NPU model run state execution complete",
        "[PASS] NPU model run missing blocked",
        "[PASS] NPU model run missing first block storage",
        "[PASS] NPU model run failing captured",
        "[PASS] NPU model run failing first block execution",
        "[PASS] NPU model run failing wait timeout",
        "[PASS] NPU model run failing status",
        "[PASS] NPU model resource first block none",
        "[PASS] NPU model resource readiness first block none",
        "[PASS] NPU model resource first block CPU weights",
        "[PASS] NPU model resource readiness first block CPU weights",
        "[PASS] NPU model workspace first block none",
        "[PASS] NPU model workspace readiness first block none",
        "[PASS] NPU model workspace address projection OCRAM",
        "[PASS] NPU model workspace address projection WRAM",
        "[PASS] NPU model workspace address projection unsupported",
        "[PASS] NPU model workspace bind state typed",
        "[PASS] NPU model workspace bind first block",
        "[PASS] NPU model workspace bind hardware base",
        "[PASS] NPU model workspace bind short first block",
        "[PASS] NPU model workspace bind empty first block",
        "[PASS] NPU model workspace clear first block none",
        "[PASS] NPU model workspace clear fit first block none",
        "[PASS] NPU model instruction workspace first block none",
        "[PASS] NPU model instruction workspace readiness first block none",
        "[PASS] NPU model instruction workspace first block stream",
        "[PASS] NPU model instruction workspace first block segment",
        "[PASS] NPU model instruction workspace first block buffer",
        "[PASS] NPU model layer instruction workspace first block none",
        "[PASS] NPU model layer instruction workspace store first block none",
        "[PASS] NPU model layer workspace first block none",
        "[PASS] NPU model layer workspace instruction first block none",
        "[PASS] NPU model layer workspace weight first block none",
        "[PASS] NPU model workspace materialize first block none",
        "[PASS] NPU model workspace execute complete",
        "[PASS] NPU model workspace execute first block none",
        "[PASS] NPU model workspace execute readiness first block none",
        "[PASS] NPU model workspace execute weight cursor",
        "[PASS] NPU model workspace execute instruction stored",
        "[PASS] NPU model workspace missing blocked",
        "[PASS] NPU model workspace failing captured",
        "[PASS] NPU model workspace failing first block execution",
        "[PASS] NPU model workspace failing wait timeout",
        "[PASS] NPU model workspace failing status",
        "[PASS] NPU model workspace first block instruction",
        "[PASS] NPU model workspace readiness first block instruction",
        "[PASS] NPU model workspace clear first block buffer",
        "[PASS] NPU model workspace clear fit first block instruction",
        "[PASS] NPU model workspace short blocked count",
        "[PASS] NPU model workspace short blocked captured",
        "[PASS] NPU model workspace short readiness first block workspace",
        "[PASS] NPU model workspace short first block materialization",
        "[PASS] NPU model workspace short blocked first block",
        "[PASS] NPU model workspace short blocked instruction first block",
        "[PASS] NPU model parsed workspace seeded",
        "[PASS] NPU model parsed workspace executable",
        "[PASS] NPU model parsed workspace first block none",
        "[PASS] NPU model parsed workspace complete",
        "[PASS] NPU model parsed workspace instruction stored",
        "[PASS] NPU model parsed workspace execution first block none",
        "[PASS] NPU model parsed workspace missing blocked",
        "[PASS] NPU model parsed workspace missing first block forward",
        "[PASS] NPU model parsed workspace failing captured",
        "[PASS] NPU model parsed workspace failing wait timeout",
        "[PASS] NPU model parsed workspace failing status",
        "[PASS] NPU model clock compose enabled",
        "[PASS] NPU model clock config plan into matches",
        "[PASS] NPU model clock config plan valid",
        "[PASS] NPU model clock config plan source",
        "[PASS] NPU model clock config plan divider",
        "[PASS] NPU model clock config plan preserves",
        "[PASS] NPU model clock compose gate preserves",
        "[PASS] NPU model clock gate plan preserves",
        "[PASS] NPU model clock enable register plan preserves",
        "[PASS] NPU model clock status enabled",
        "[PASS] NPU model clock status divider",
        "[PASS] NPU model clock status unknown source",
        "[PASS] NPU model SRAM compose release",
        "[PASS] NPU model SRAM release plan into matches",
        "[PASS] NPU model SRAM release plan first write",
        "[PASS] NPU model SRAM release plan latch write",
        "[PASS] NPU model init clock select plan preserves",
        "[PASS] NPU model runtime init register plan source select",
        "[PASS] NPU model codec qos compose aw",
        "[PASS] NPU model codec qos plan into matches",
        "[PASS] NPU model codec qos plan encoded",
        "[PASS] NPU model codec qos plan preserves",
        "[PASS] NPU model bus limiter plan into matches",
        "[PASS] NPU model bus limiter compose read",
        "[PASS] NPU model reset compose asserted",
        "[PASS] NPU model reset line plan asserted",
        "[PASS] NPU model reset pulse plan into matches",
        "[PASS] NPU model reset pulse plan delay",
        "[PASS] NPU model SRAM status blocked",
        "[PASS] NPU model SRAM status released",
        "[PASS] NPU model SRAM status selected",
        "[PASS] NPU model reset status asserted",
        "[PASS] NPU model reset status released",
        "[PASS] NPU model wrapper state idle",
        "[PASS] NPU model wrapper state configured runnable",
        "[PASS] NPU model wrapper state started",
        "[PASS] NPU model interrupt status pending",
        "[PASS] NPU model interrupt clear requested",
        "[PASS] NPU model interrupt GLB route evidence",
        "[PASS] NPU model interrupt GLB route MCU aggregate",
        "[PASS] NPU model interrupt GLB route demux required",
        "[PASS] NPU model interrupt GLB route polling",
        "[PASS] NPU model interrupt MM aggregate catalog no named subroute",
        "[PASS] NPU model interrupt MM aggregate raw decode",
        "[PASS] NPU model interrupt MM aggregate pending",
        "[PASS] NPU model interrupt MM aggregate none",
        "[PASS] NPU model interrupt MM aggregate route catalog",
        "[PASS] NPU model interrupt MM aggregate demux unknown",
        "[PASS] NPU model interrupt MM aggregate polling preserved",
        "[PASS] NPU model interrupt MM aggregate SDK helper evidence",
        "[PASS] NPU model interrupt MM aggregate SDK helper bank",
        "[PASS] NPU model interrupt MM aggregate SDK helper clear",
        "[PASS] NPU model interrupt MM aggregate SDK helper unmask",
        "[PASS] NPU model int cfg decode commands",
        "[PASS] NPU model int cfg decode relu",
        "[PASS] NPU model int cfg command plan clear",
        "[PASS] NPU model start transition plan first start",
        "[PASS] NPU model start transition plan resume",
        "[PASS] NPU model stop transition plan command",
        "[PASS] NPU model stop wrapper valid",
        "[PASS] NPU model stop wrapper command",
        "[PASS] NPU model stop wrapper no error",
        "[PASS] NPU model stop wrapper cold stop",
        "[PASS] NPU model tf cfg decode enabled",
        "[PASS] NPU model tf cfg compose enabled",
        "[PASS] NPU model general cfg compose image mode",
        "[PASS] NPU model int cfg compose relu clamp",
        "[PASS] NPU model net param field relu clamp",
        "[PASS] NPU model net param field tensorflow valid",
        "[PASS] NPU model net param register plan into matches",
        "[PASS] NPU model net param register plan valid",
        "[PASS] NPU model net param register plan unsigned",
        "[PASS] NPU model net param register plan relu clamp",
        "[PASS] NPU model net param register plan tensorflow",
        "[PASS] NPU model net param register plan clear",
        "[PASS] NPU model activation table base fits",
        "[PASS] NPU model activation table base encoded",
        "[PASS] NPU model activation table base decode valid",
        "[PASS] NPU model activation table base register valid",
        "[PASS] NPU model activation table base rejects overflow",
        "[PASS] NPU model general cfg decode unsigned",
        "[PASS] NPU model general cfg decode image mode",
        "[PASS] NPU model general cfg decode idle",
        "[PASS] NPU model general cfg decode image mode unknown",
        "[PASS] NPU model activation table word valid",
        "[PASS] NPU model activation table word register offset",
        "[PASS] NPU model activation table word register address",
        "[PASS] NPU model activation table word encoded",
        "[PASS] NPU model activation table word decode valid",
        "[PASS] NPU model activation table word rejects overflow",
        "[PASS] NPU model activation table word overflow offset",
        "[PASS] NPU model register snapshot image mode known",
        "[PASS] NPU model register snapshot activation index",
        "[PASS] NPU model register snapshot int commands",
        "[PASS] NPU model register snapshot relu decode",
        "[PASS] NPU model register snapshot tensorflow decode",
        "[PASS] NPU model register snapshot image mode unknown",
        "[PASS] NPU model instruction stream register plan into matches",
        "[PASS] NPU model instruction stream register plan configured",
        "[PASS] NPU model instruction stream register plan zero buffers",
        "[PASS] NPU model instruction stream register plan empty stream",
        "[PASS] NPU model layer buffer register plan optional writes",
        "[PASS] NPU model input buffer register plan writes",
        "[PASS] NPU model launch register plan optional writes",
        "[PASS] NPU model launch register plan input write",
        "[PASS] NPU model layer config register plan first layer",
        "[PASS] NPU model layer config register plan reset unsigned",
        "[PASS] NPU model conv facade first block stream",
        "[PASS] NPU model conv facade dimensions representable",
        "[PASS] NPU model conv facade apply stream cleared",
        "[PASS] NPU model conv facade apply first block",
        "[PASS] NPU model conv facade evidence",
        "[PASS] NPU model conv facade evidence plan address",
        "[PASS] NPU model conv facade evidence apply address",
        "[PASS] NPU model conv facade evidence register addresses",
        "[PASS] NPU model conv facade evidence output plan only",
        "[PASS] NPU model conv facade evidence dimensions",
        "[PASS] NPU model conv facade evidence stream required",
        "[PASS] NPU model conv facade evidence not runnable",
        "[PASS] NPU model conv facade evidence stream cleared",
        "[PASS] NPU model conv facade evidence apply matches",
        "[PASS] NPU model conv facade evidence boundary",
        "[PASS] NPU model conv facade first block address",
        "[PASS] NPU model conv facade empty apply first block",
        "[PASS] NPU model conv facade invalid dimensions classified",
        "[PASS] NPU model conv facade invalid first block",
        "[PASS] NPU model layer run readiness blocked",
        "[PASS] NPU model layer run readiness unblocked",
        "[PASS] NPU model layer run result first block",
        "[PASS] NPU model layer run result status",
        "[PASS] NPU model instruction stream guard evidence",
        "[PASS] NPU model instruction stream guard configured state",
        "[PASS] NPU model instruction stream guard configured runnable",
        "[PASS] NPU model instruction stream guard configured first block",
        "[PASS] NPU model instruction stream guard configured timeout",
        "[PASS] NPU model instruction stream guard configured match",
        "[PASS] NPU model instruction stream guard facade cleared",
        "[PASS] NPU model instruction stream guard cleared timeout",
        "[PASS] NPU model instruction stream guard cleared blocked",
        "[PASS] NPU model instruction stream guard invalidated stream",
        "[PASS] NPU model instruction stream guard run blocked",
        "[PASS] NPU model instruction stream guard wait plan",
        "[PASS] NPU model instruction stream guard boundary",
        "[PASS] NPU model busy status busy",
        "[PASS] NPU model busy status idle",
        "[PASS] NPU model configured invalid no first failure",
        "[PASS] NPU model configured state no first failure",
        "[PASS] NPU model configured wait unsupported",
        "[PASS] NPU model configured wait timeout",
        "[PASS] NPU model configured wait not started",
        "[PASS] NPU model configured run wait timeout",
        "[PASS] NPU model configured run SDK lock",
        "[PASS] NPU model configured run stop policy",
        "[PASS] NPU model configured run status",
        "[PASS] NPU model configured invalid blocked",
        "[PASS] NPU model configured state blocked",
        "[PASS] NPU model completion ok status",
        "[PASS] NPU model runtime SDK interrupt semaphore",
        "[PASS] NPU model runtime active polling",
        "[PASS] NPU model runtime lifecycle cold init",
        "[PASS] NPU model runtime lifecycle repeated init noop",
        "[PASS] NPU model runtime lifecycle initialized destroy clear",
        "[PASS] NPU model runtime lifecycle cold destroy noop",
        "[PASS] NPU model release plan valid",
        "[PASS] NPU model release plan cn frees",
        "[PASS] NPU model release plan layer overflow",
        "[PASS] NPU model release plan cn overflow",
        "[PASS] NPU model completion plan timeout",
        "[PASS] NPU model completion result timeout",
        "[PASS] NPU model completion polling wait no polls",
        "[PASS] NPU model completion polling wait trace",
        "[PASS] NPU model cache range count",
        "[PASS] NPU model cache first address",
        "[PASS] NPU model cache overflow blocked",
        "[PASS] NPU model cache apply last address",
        "[PASS] NPU model cache execute overflow blocked",
        "[PASS] NPU model cache execute overflow not started",
        "[PASS] NPU model cache execute overflow status",
        "[PASS] NPU model forward weights materialized",
        "[PASS] NPU model forward weights byte",
        "[PASS] NPU model forward route skips weights",
        "[PASS] NPU model weight workspace first block none",
        "[PASS] NPU model weight workspace readiness first block none",
        "[PASS] NPU model weight workspace first block weight",
        "[PASS] NPU model weight workspace first block bias",
        "[PASS] NPU model weight workspace first block buffer",
        "[PASS] NPU model weight workspace blocked model first block layer",
        "[PASS] NPU model weight workspace blocked first block storage",
        "[PASS] NPU model weight workspace blocked workspace first block buffer",
        "[PASS] NPU model forward weights blocked",
        "[PASS] NPU model forward temp byte",
        "[PASS] NPU model TFLite pad diagnostics spatial",
        "[PASS] NPU model TFLite pad diagnostics channel block",
        "[PASS] NPU model TFLite pad diagnostics output block",
        "[PASS] NPU model TFLite transpose diagnostics spatial",
        "[PASS] NPU model TFLite transpose diagnostics permutation block",
        "[PASS] NPU model TFLite transpose diagnostics output block",
        "[PASS] NPU model NMSIS maxpool diagnostics valid",
        "[PASS] NPU model NMSIS maxpool diagnostics input shape block",
        "[PASS] NPU model NMSIS maxpool diagnostics output shape block",
        "[PASS] NPU model NMSIS maxpool diagnostics window block",
        "[PASS] NPU model NMSIS maxpool diagnostics input block",
        "[PASS] NPU model NMSIS maxpool diagnostics output block",
        "[PASS] NPU model fixed maxpool diagnostics valid",
        "[PASS] NPU model fixed maxpool diagnostics kernel block",
        "[PASS] NPU model fixed maxpool diagnostics output block",
        "[PASS] NPU model TFLite maxpool diagnostics valid",
        "[PASS] NPU model TFLite maxpool diagnostics output block",
        "[PASS] NPU model avgpool diagnostics valid",
        "[PASS] NPU model avgpool diagnostics input stride block",
        "[PASS] NPU model avgpool diagnostics output block",
        "[PASS] NPU model TFLite mean diagnostics valid",
        "[PASS] NPU model TFLite mean diagnostics shift block",
        "[PASS] NPU model TFLite mean diagnostics output block",
        "[PASS] NPU model TFLite softmax diagnostics valid",
        "[PASS] NPU model TFLite softmax diagnostics input stride block",
        "[PASS] NPU model TFLite softmax diagnostics output block",
        "[PASS] NPU model TFLite transposelk diagnostics valid",
        "[PASS] NPU model TFLite transposelk diagnostics window block",
        "[PASS] NPU model TFLite transposelk diagnostics rolling stride block",
        "[PASS] NPU model TFLite transposelk diagnostics output block",
        "[PASS] NPU model TFLite pretransconv diagnostics valid",
        "[PASS] NPU model TFLite pretransconv diagnostics shape block",
        "[PASS] NPU model TFLite pretransconv diagnostics output block",
        "[PASS] NPU model TFLite dequantize diagnostics valid",
        "[PASS] NPU model TFLite dequantize diagnostics input block",
        "[PASS] NPU model TFLite dequantize diagnostics output block",
        "[PASS] NPU model TFLite logistic diagnostics valid",
        "[PASS] NPU model TFLite logistic diagnostics scale block",
        "[PASS] NPU model TFLite logistic diagnostics input block",
        "[PASS] NPU model TFLite logistic diagnostics output block",
        "[PASS] NPU model upsample diagnostics valid",
        "[PASS] NPU model upsample diagnostics shape block",
        "[PASS] NPU model upsample diagnostics output block",
        "[PASS] NPU model route upsample diagnostics valid",
        "[PASS] NPU model route upsample diagnostics channels block",
        "[PASS] NPU model route upsample diagnostics input2 block",
        "[PASS] NPU model route upsample diagnostics output block",
        "[PASS] NPU model route concat diagnostics valid",
        "[PASS] NPU model route concat diagnostics inactive block",
        "[PASS] NPU model route concat diagnostics input block",
        "[PASS] NPU model route concat diagnostics output block",
        "[PASS] NPU model route max diagnostics valid",
        "[PASS] NPU model route max diagnostics shape block",
        "[PASS] NPU model route max diagnostics input block",
        "[PASS] NPU model route max diagnostics output block",
        "[PASS] NPU model shortcut diagnostics valid",
        "[PASS] NPU model shortcut diagnostics shape block",
        "[PASS] NPU model shortcut diagnostics input1 block",
        "[PASS] NPU model shortcut diagnostics input2 block",
        "[PASS] NPU model shortcut diagnostics output block",
        "[PASS] NPU model TFLite shortcut diagnostics valid",
        "[PASS] NPU model TFLite shortcut diagnostics shift block",
        "[PASS] NPU model TFLite shortcut diagnostics activation block",
        "[PASS] NPU model TFLite shortcut diagnostics input1 block",
        "[PASS] NPU model TFLite shortcut diagnostics output block",
        "[PASS] NPU model TFLite route diagnostics valid",
        "[PASS] NPU model TFLite route diagnostics dispatch block",
        "[PASS] NPU model TFLite route diagnostics shift block",
        "[PASS] NPU model TFLite route diagnostics input shift block",
        "[PASS] NPU model TFLite route diagnostics channels block",
        "[PASS] NPU model TFLite route diagnostics output block",
        "[PASS] NPU model TFLite route max diagnostics valid",
        "[PASS] NPU model TFLite route max diagnostics shape block",
        "[PASS] NPU model TFLite route max diagnostics input shift block",
        "[PASS] NPU model TFLite route max diagnostics channels block",
        "[PASS] NPU model TFLite route max diagnostics output block",
        "[PASS] NPU model TFLite route W diagnostics valid",
        "[PASS] NPU model TFLite route W diagnostics axis block",
        "[PASS] NPU model TFLite route W diagnostics input shift block",
        "[PASS] NPU model TFLite route W diagnostics extent block",
        "[PASS] NPU model TFLite route W diagnostics output block",
        "[PASS] NPU model TFLite reshape diagnostics valid",
        "[PASS] NPU model TFLite reshape diagnostics input stride block",
        "[PASS] NPU model TFLite reshape diagnostics output stride block",
        "[PASS] NPU model TFLite reshape diagnostics input block",
        "[PASS] NPU model TFLite reshape diagnostics output block",
        "[PASS] NPU model matmul diagnostics valid",
        "[PASS] NPU model matmul diagnostics input block",
        "[PASS] NPU model matmul diagnostics weight block",
        "[PASS] NPU model matmul diagnostics bias block",
        "[PASS] NPU model matmul diagnostics output block",
        "[PASS] NPU model depthwise diagnostics valid",
        "[PASS] NPU model depthwise diagnostics input shape block",
        "[PASS] NPU model depthwise diagnostics output shape block",
        "[PASS] NPU model depthwise diagnostics input block",
        "[PASS] NPU model depthwise diagnostics kernel block",
        "[PASS] NPU model depthwise diagnostics bias block",
        "[PASS] NPU model depthwise diagnostics output block",
        "[PASS] NPU model fixed conv diagnostics valid",
        "[PASS] NPU model fixed conv diagnostics input shape block",
        "[PASS] NPU model fixed conv diagnostics kernel block",
        "[PASS] NPU model fixed conv diagnostics group block",
        "[PASS] NPU model fixed conv diagnostics input block",
        "[PASS] NPU model fixed conv diagnostics weight block",
        "[PASS] NPU model fixed conv diagnostics bias block",
        "[PASS] NPU model fixed conv diagnostics output block",
        "[PASS] NPU model fixed conv max diagnostics valid",
        "[PASS] NPU model fixed conv max diagnostics input shape block",
        "[PASS] NPU model fixed conv max diagnostics kernel block",
        "[PASS] NPU model fixed conv max diagnostics group block",
        "[PASS] NPU model fixed conv max diagnostics output shape block",
        "[PASS] NPU model fixed conv max diagnostics input block",
        "[PASS] NPU model fixed conv max diagnostics weight block",
        "[PASS] NPU model fixed conv max diagnostics bias block",
        "[PASS] NPU model fixed conv max diagnostics output block",
        "[PASS] NPU model fixed layer dispatch diagnostics valid",
        "[PASS] NPU model fixed layer dispatch diagnostics conv block",
        "[PASS] NPU model fixed layer dispatch diagnostics unsupported block",
        "[PASS] NPU model TFLite layer dispatch diagnostics valid",
        "[PASS] NPU model TFLite layer dispatch diagnostics conv block",
        "[PASS] NPU model TFLite layer dispatch diagnostics reshape block",
        "[PASS] NPU model TFLite layer dispatch diagnostics unsupported block",
        "[PASS] NPU model TFLite layer dispatch diagnostics float valid",
        "[PASS] NPU model TFLite layer dispatch diagnostics float unsupported block",
        "[PASS] NPU model TFLite conv diagnostics valid",
        "[PASS] NPU model TFLite conv diagnostics input shape block",
        "[PASS] NPU model TFLite conv diagnostics output shape block",
        "[PASS] NPU model TFLite conv diagnostics input block",
        "[PASS] NPU model TFLite conv diagnostics kernel block",
        "[PASS] NPU model TFLite conv diagnostics bias block",
        "[PASS] NPU model TFLite conv diagnostics output block",
        "[PASS] NPU model TFLite scalar conv diagnostics valid",
        "[PASS] NPU model TFLite scalar conv diagnostics kernel support block",
        "[PASS] NPU model TFLite scalar conv diagnostics input shape block",
        "[PASS] NPU model TFLite scalar conv diagnostics group block",
        "[PASS] NPU model TFLite scalar conv diagnostics output shape block",
        "[PASS] NPU model TFLite scalar conv diagnostics input block",
        "[PASS] NPU model TFLite scalar conv diagnostics kernel block",
        "[PASS] NPU model TFLite scalar conv diagnostics bias block",
        "[PASS] NPU model TFLite scalar conv diagnostics output block",
        "[PASS] NPU model TFLite scalar conv max diagnostics valid",
        "[PASS] NPU model TFLite scalar conv max diagnostics kernel support block",
        "[PASS] NPU model TFLite scalar conv max diagnostics input shape block",
        "[PASS] NPU model TFLite scalar conv max diagnostics group block",
        "[PASS] NPU model TFLite scalar conv max diagnostics output shape block",
        "[PASS] NPU model TFLite scalar conv max diagnostics input block",
        "[PASS] NPU model TFLite scalar conv max diagnostics kernel block",
        "[PASS] NPU model TFLite scalar conv max diagnostics bias block",
        "[PASS] NPU model TFLite scalar conv max diagnostics output block",
        "[PASS] NPU model tensor input moved",
        "[PASS] NPU model tensor input buffer required",
        "[PASS] NPU model tensor input tensor required",
        "[PASS] NPU model tensor input move required",
        "[PASS] NPU model tensor input short blocked",
        "[PASS] NPU model tensor input short required",
        "[PASS] NPU model tensor input short provided",
        "[PASS] NPU model tensor input buffer blocked",
        "[PASS] NPU model tensor input buffer required short",
        "[PASS] NPU model tensor output moved",
        "[PASS] NPU model tensor output buffer required",
        "[PASS] NPU model tensor output tensor required",
        "[PASS] NPU model tensor output move required",
        "[PASS] NPU model workspace tensor input moved",
        "[PASS] NPU model workspace tensor output moved",
        "[PASS] NPU model workspace tensor segment first block",
        "[PASS] NPU model output validation valid",
        "[PASS] NPU model output validation first block",
        "[PASS] NPU model output validation reason none",
        "[PASS] NPU model output validation length match",
        "[PASS] NPU model output validation readiness valid",
        "[PASS] NPU model configured output validation valid",
        "[PASS] NPU model configured output validation length match",
        "[PASS] NPU model configured output validation first block",
        "[PASS] NPU model output helper valid",
        "[PASS] NPU model output helper length match",
        "[PASS] NPU model configured output helper valid",
        "[PASS] NPU model configured output helper first block",
        "[PASS] NPU model workspace output helper valid",
        "[PASS] NPU model workspace output helper readiness valid",
        "[PASS] NPU model workspace output helper readiness blocks",
        "[PASS] NPU model configured workspace output helper valid",
        "[PASS] NPU model output validation compare first mismatch",
        "[PASS] NPU model workspace output helper unbound first block",
        "[PASS] NPU model workspace output helper mismatch first block",
        "[PASS] NPU model workspace output helper mismatch index",
        "[PASS] NPU model workspace output helper mismatch expected",
        "[PASS] NPU model workspace output helper mismatch actual",
        "[PASS] NPU model workspace output helper mismatch direct",
        "[PASS] NPU model workspace output helper mismatch readiness",
        "[PASS] NPU model workspace explicit address into equal",
        "[PASS] NPU model workspace explicit zero address block",
        "[PASS] NPU model workspace explicit address bound",
        "[PASS] NPU model workspace explicit address first block",
        "[PASS] NPU model workspace explicit address readiness",
        "[PASS] NPU model workspace fixture readiness matches",
        "[PASS] NPU model workspace fixture output readiness",
        "[PASS] NPU model workspace fixture output evidence",
        "[PASS] NPU model workspace fixture classified",
        "[PASS] NPU model workspace fixture address block",
        "[PASS] NPU model workspace explicit fixture into equal",
        "[PASS] NPU model workspace explicit fixture valid",
        "[PASS] NPU model workspace explicit fixture first block",
        "[PASS] NPU model workspace explicit fixture address block",
        "[PASS] NPU model workspace fixture short first block",
        "[PASS] NPU model parsed workspace fixture readiness matches",
        "[PASS] NPU model parsed workspace fixture output readiness",
        "[PASS] NPU model parsed workspace fixture output evidence",
        "[PASS] NPU model parsed workspace fixture classified",
        "[PASS] NPU model parsed workspace fixture address block",
        "[PASS] NPU model parsed workspace explicit fixture valid",
        "[PASS] NPU model parsed workspace explicit fixture first block",
        "[PASS] NPU model parsed workspace explicit fixture address block",
        "[PASS] NPU model parsed workspace oracle reference valid",
        "[PASS] NPU model fixed workspace oracle reference valid",
        "[PASS] NPU model fixed workspace oracle projection valid",
        "[PASS] NPU model fixed workspace oracle projection block",
        "[PASS] NPU model fixed workspace oracle projection count",
        "[PASS] NPU model fixed workspace oracle expected byte",
        "[PASS] NPU model fixed workspace oracle projection short block",
        "[PASS] NPU model TFLite configured workspace oracle buffer classified",
        "[PASS] NPU model TFLite configured workspace oracle buffer execution gate",
        "[PASS] NPU model TFLite configured workspace oracle buffer terminal fields",
        "[PASS] NPU model TFLite configured workspace oracle projected accessor",
        "[PASS] NPU model TFLite configured workspace oracle buffer materialized classified",
        "[PASS] NPU model TFLite configured workspace oracle buffer materialized terminal fields",
        "[PASS] NPU model fixed configured workspace oracle buffer classified",
        "[PASS] NPU model fixed configured workspace oracle buffer execution gate",
        "[PASS] NPU model fixed configured workspace oracle buffer terminal fields",
        "[PASS] NPU model fixed configured workspace oracle projected accessor",
        "[PASS] NPU model fixed configured workspace oracle buffer materialized classified",
        "[PASS] NPU model fixed configured workspace oracle buffer materialized terminal fields",
        "[PASS] NPU model parsed configured workspace fixture exec guard block",
        "[PASS] NPU model parsed configured workspace fixture exec first",
        "[PASS] NPU model parsed configured workspace fixture exec sequence",
        "[PASS] NPU model parsed configured workspace fixture exec staged",
        "[PASS] NPU model parsed configured workspace fixture readiness exec",
        "[PASS] NPU model parsed configured workspace fixture exec run config gate",
        "[PASS] NPU model parsed configured workspace fixture readiness run config gate",
        "[PASS] NPU model parsed configured workspace fixture active runtime init evidence",
        "[PASS] NPU model parsed configured workspace fixture active runtime clock",
        "[PASS] NPU model parsed configured workspace fixture active runtime clock disabled",
        "[PASS] NPU model parsed configured workspace fixture active runtime clock source known",
        "[PASS] NPU model parsed configured workspace fixture active runtime clock source",
        "[PASS] NPU model parsed configured workspace fixture active runtime clock divider",
        "[PASS] NPU model parsed configured workspace fixture active codec qos evidence",
        "[PASS] NPU model parsed configured workspace fixture active codec qos aw",
        "[PASS] NPU model parsed configured workspace fixture active codec qos ar",
        "[PASS] NPU model parsed configured workspace fixture active codec qos encoded",
        "[PASS] NPU model parsed configured workspace fixture active codec bus evidence",
        "[PASS] NPU model parsed configured workspace fixture active codec bus pclk",
        "[PASS] NPU model parsed configured workspace fixture active codec bus thresholds",
        "[PASS] NPU model parsed configured workspace fixture active codec bus BLAI thresholds",
        "[PASS] NPU model parsed configured workspace fixture active runtime reset",
        "[PASS] NPU model parsed configured workspace fixture active runtime reset released",
        "[PASS] NPU model parsed configured workspace fixture active runtime reset not asserted",
        "[PASS] NPU model parsed configured workspace fixture active runtime SRAM",
        "[PASS] NPU model parsed configured workspace fixture active runtime SRAM released",
        "[PASS] NPU model parsed configured workspace fixture active runtime SRAM selected",
        "[PASS] NPU model parsed configured workspace fixture active runtime SRAM set self-cleared",
        "[PASS] NPU model parsed configured workspace fixture active runtime SDK boundary evidence",
        "[PASS] NPU model parsed configured workspace fixture active runtime SDK clock source",
        "[PASS] NPU model parsed configured workspace fixture active runtime SDK preserves clock",
        "[PASS] NPU model parsed configured workspace fixture active runtime local clock",
        "[PASS] NPU model parsed configured workspace fixture active runtime local reset",
        "[PASS] NPU model parsed configured workspace fixture active runtime local SRAM",
        "[PASS] NPU model parsed configured workspace fixture active runtime boundary explicit",
        "[PASS] NPU model parsed configured workspace fixture active activation table reset evidence",
        "[PASS] NPU model parsed configured workspace fixture active activation table reset raw",
        "[PASS] NPU model parsed configured workspace fixture active activation table reset decoded",
        "[PASS] NPU model parsed configured workspace fixture active int cfg command RMW",
        "[PASS] NPU model parsed configured workspace fixture active int cfg start command",
        "[PASS] NPU model parsed configured workspace fixture active int cfg resume command",
        "[PASS] NPU model parsed configured workspace fixture active int cfg stop command",
        "[PASS] NPU model parsed configured workspace fixture active int cfg clear command",
        "[PASS] NPU model parsed configured workspace fixture active classification evidence",
        "[PASS] NPU model parsed configured workspace fixture active materialized classified",
        "[PASS] NPU model parsed configured workspace fixture active materialization classification valid",
        "[PASS] NPU model parsed configured workspace fixture active materialization evidence",
        "[PASS] NPU model parsed configured workspace fixture active materialization storage layers",
        "[PASS] NPU model parsed configured workspace fixture active materialization expected layers",
        "[PASS] NPU model parsed configured workspace fixture active materialization skipped layers",
        "[PASS] NPU model parsed configured workspace fixture active materialization attempted layers",
        "[PASS] NPU model parsed configured workspace fixture active materialization ready layers",
        "[PASS] NPU model parsed configured workspace fixture active materialization no missing",
        "[PASS] NPU model parsed configured workspace fixture active materialization no blocked",
        "[PASS] NPU model parsed configured workspace fixture active materialization no first blocked",
        "[PASS] NPU model parsed configured workspace fixture active materialization last ready",
        "[PASS] NPU model parsed configured workspace fixture active materialization first none evidence",
        "[PASS] NPU model parsed configured workspace fixture active materialization readiness first block",
        "[PASS] NPU model parsed configured workspace fixture active materialization all ready mirror",
        "[PASS] NPU model parsed configured workspace fixture active materialization readiness ready",
        "[PASS] NPU model parsed configured workspace fixture active run classified",
        "[PASS] NPU model parsed configured workspace fixture active run first block known",
        "[PASS] NPU model parsed configured workspace fixture active run blocked capture",
        "[PASS] NPU model parsed configured workspace fixture active readiness run classified",
        "[PASS] NPU model parsed configured workspace fixture active run classification valid",
        "[PASS] NPU model parsed configured workspace fixture active classified",
        "[PASS] NPU model parsed configured workspace fixture active fixture first block",
        "[PASS] NPU model parsed configured workspace fixture active fixture first block known",
        "[PASS] NPU model parsed configured workspace fixture active output classified",
        "[PASS] NPU model parsed configured workspace fixture active fixture classification valid",
        "[PASS] NPU model parsed configured workspace fixture active terminal materialization none",
        "[PASS] NPU model parsed configured workspace fixture active terminal run sequence none",
        "[PASS] NPU model parsed configured workspace fixture active terminal run sequence not blocked",
        "[PASS] NPU model parsed configured workspace fixture active terminal readiness run sequence none",
        "[PASS] NPU model parsed configured workspace fixture active terminal fixture execution",
        "[PASS] NPU model parsed configured workspace fixture active terminal readiness fixture execution",
        "[PASS] NPU model parsed configured workspace fixture active terminal output deferred",
        "[PASS] NPU model parsed configured workspace fixture active terminal classification valid",
        "[PASS] NPU model parsed configured workspace fixture active terminal classification evidence",
        "[PASS] NPU model parsed configured workspace fixture active snapshot coherence evidence",
        "[PASS] NPU model parsed configured workspace fixture active snapshot coherent",
        "[PASS] NPU model parsed configured workspace fixture active snapshot state mirrors",
        "[PASS] NPU model parsed configured workspace fixture active snapshot materialized mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot bound mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot hardware addresses mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot input mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot run sequence mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot execution completed mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot output valid mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot output matched mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot block mirrors",
        "[PASS] NPU model parsed configured workspace fixture active snapshot materialization block mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot execution block mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot run sequence block mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot output block mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot execution mirrors",
        "[PASS] NPU model parsed configured workspace fixture active snapshot failed execution mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last execution started mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last execution status mirror",
        "[PASS] NPU model parsed configured workspace fixture active snapshot output evidence",
        "[PASS] NPU model parsed configured workspace fixture active snapshot counters",
        "[PASS] NPU model parsed configured workspace fixture active snapshot attempted layers",
        "[PASS] NPU model parsed configured workspace fixture active snapshot completed layers",
        "[PASS] NPU model parsed configured workspace fixture active snapshot failed layers",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first failed layer",
        "[PASS] NPU model parsed configured workspace fixture active snapshot expected elements",
        "[PASS] NPU model parsed configured workspace fixture active snapshot actual elements",
        "[PASS] NPU model parsed configured workspace fixture active snapshot compared elements",
        "[PASS] NPU model parsed configured workspace fixture active snapshot trailing elements",
        "[PASS] NPU model parsed configured workspace fixture active snapshot length match",
        "[PASS] NPU model parsed configured workspace fixture active snapshot mismatch count",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first mismatch",
        "[PASS] NPU model parsed configured workspace fixture active snapshot mismatch bytes",
        "[PASS] NPU model parsed configured workspace fixture active snapshot expected mismatch present",
        "[PASS] NPU model parsed configured workspace fixture active snapshot actual mismatch present",
        "[PASS] NPU model parsed configured workspace fixture active snapshot expected mismatch byte",
        "[PASS] NPU model parsed configured workspace fixture active snapshot actual mismatch byte",
        "[PASS] NPU model parsed configured workspace fixture active deferred output execution gate",
        "[PASS] NPU model parsed configured workspace fixture active deferred output execution incomplete",
        "[PASS] NPU model parsed configured workspace fixture active deferred output invalid",
        "[PASS] NPU model parsed configured workspace fixture active deferred output unmatched",
        "[PASS] NPU model parsed configured workspace fixture active deferred output zero expected",
        "[PASS] NPU model parsed configured workspace fixture active deferred output zero actual",
        "[PASS] NPU model parsed configured workspace fixture active deferred output zero compared",
        "[PASS] NPU model parsed configured workspace fixture active deferred output zero trailing",
        "[PASS] NPU model parsed configured workspace fixture active deferred output zero mismatch",
        "[PASS] NPU model parsed configured workspace fixture active deferred output no first mismatch",
        "[PASS] NPU model parsed configured workspace fixture active deferred output no mismatch bytes",
        "[PASS] NPU model parsed configured workspace fixture active deferred output mirrors",
        "[PASS] NPU model parsed configured workspace fixture active deferred output evidence",
        "[PASS] NPU model parsed configured workspace fixture active output blocked evidence",
        "[PASS] NPU model parsed configured workspace fixture active output blocked fixture gate",
        "[PASS] NPU model parsed configured workspace fixture active output blocked readiness gate",
        "[PASS] NPU model parsed configured workspace fixture active output blocked invalid",
        "[PASS] NPU model parsed configured workspace fixture active output blocked unmatched",
        "[PASS] NPU model parsed configured workspace fixture active output blocked readiness invalid",
        "[PASS] NPU model parsed configured workspace fixture active output blocked not moved",
        "[PASS] NPU model parsed configured workspace fixture active output blocked workspace block",
        "[PASS] NPU model parsed configured workspace fixture active output blocked validation block",
        "[PASS] NPU model parsed configured workspace fixture active output blocked model block",
        "[PASS] NPU model parsed configured workspace fixture active output blocked zero counters",
        "[PASS] NPU model parsed configured workspace fixture active output blocked no mismatch",
        "[PASS] NPU model parsed configured workspace fixture active output blocked deferred",
        "[PASS] NPU model parsed configured workspace fixture active snapshot terminal detail evidence",
        "[PASS] NPU model parsed configured workspace fixture active snapshot terminal detail",
        "[PASS] NPU model parsed configured workspace fixture active snapshot run-sequence detail",
        "[PASS] NPU model parsed configured workspace fixture active snapshot run-sequence first block",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first blocked layer",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first blocked run captured",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first blocked run config",
        "[PASS] NPU model parsed configured workspace fixture active snapshot execution terminal",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first failed started",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first failed status",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first failed timed out",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last completed",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last timed out",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last interrupt observed",
        "[PASS] NPU model parsed configured workspace fixture active snapshot runtime evidence",
        "[PASS] NPU model parsed configured workspace fixture active snapshot wait plans",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first failed wait plan",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last wait plan",
        "[PASS] NPU model parsed configured workspace fixture active snapshot cache results",
        "[PASS] NPU model parsed configured workspace fixture active snapshot workspace cache result",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last execution cache result",
        "[PASS] NPU model parsed configured workspace fixture active snapshot register captures",
        "[PASS] NPU model parsed configured workspace fixture active snapshot launch registers captured",
        "[PASS] NPU model parsed configured workspace fixture active snapshot started registers captured",
        "[PASS] NPU model parsed configured workspace fixture active snapshot launch registers",
        "[PASS] NPU model parsed configured workspace fixture active snapshot started registers",
        "[PASS] NPU model parsed configured workspace fixture active snapshot wait-exit registers",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first failed wait interrupt",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first failed wait MM aggregate",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first failed wait busy",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first failed wait clock",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last wait interrupt",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last wait MM aggregate",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last wait busy",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last wait clock",
        "[PASS] NPU model parsed configured workspace fixture active snapshot status decisions",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first failed status decision",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last status decision",
        "[PASS] NPU model parsed configured workspace fixture active snapshot completion side effects",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first failed interrupt cleared",
        "[PASS] NPU model parsed configured workspace fixture active snapshot first failed clock disabled",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last interrupt cleared",
        "[PASS] NPU model parsed configured workspace fixture active snapshot last clock disabled",
        "[PASS] NPU model parsed configured workspace fixture active snapshot run config readiness",
        "[PASS] NPU model parsed configured workspace fixture active snapshot run config readiness mirror",
        "[PASS] NPU model parsed configured workspace fixture active runtime mirror evidence",
        "[PASS] NPU model parsed configured workspace fixture active runtime mirror status",
        "[PASS] NPU model parsed configured workspace fixture active runtime mirror timed out",
        "[PASS] NPU model parsed configured workspace fixture active runtime mirror wait plan",
        "[PASS] NPU model parsed configured workspace fixture active runtime mirror wait interrupt",
        "[PASS] NPU model parsed configured workspace fixture active runtime mirror wait MM aggregate",
        "[PASS] NPU model parsed configured workspace fixture active runtime mirror wait busy",
        "[PASS] NPU model parsed configured workspace fixture active runtime mirror wait clock",
        "[PASS] NPU model parsed configured workspace fixture active runtime mirror status decision",
        "[PASS] NPU model parsed configured workspace fixture active runtime mirror interrupt cleared",
        "[PASS] NPU model parsed configured workspace fixture active runtime mirror clock disabled",
        "[PASS] NPU model parsed configured workspace fixture active runtime mirror source",
        "[PASS] NPU model parsed configured workspace fixture active completion policy evidence",
        "[PASS] NPU model parsed configured workspace fixture active completion policy wait plans",
        "[PASS] NPU model parsed configured workspace fixture active completion policy configured",
        "[PASS] NPU model parsed configured workspace fixture active completion policy timeout",
        "[PASS] NPU model parsed configured workspace fixture active completion policy clear enabled",
        "[PASS] NPU model parsed configured workspace fixture active completion policy disable clock",
        "[PASS] NPU model parsed configured workspace fixture active completion policy started",
        "[PASS] NPU model parsed configured workspace fixture active completion policy no interrupt",
        "[PASS] NPU model parsed configured workspace fixture active completion policy status configured",
        "[PASS] NPU model parsed configured workspace fixture active completion policy timed out",
        "[PASS] NPU model parsed configured workspace fixture active completion policy incomplete",
        "[PASS] NPU model parsed configured workspace fixture active completion policy status",
        "[PASS] NPU model parsed configured workspace fixture active completion policy no interrupt clear",
        "[PASS] NPU model parsed configured workspace fixture active completion policy clock disabled",
        "[PASS] NPU model parsed configured workspace fixture active polling wait actual polls",
        "[PASS] NPU model parsed configured workspace fixture active polling wait final clear",
        "[PASS] NPU model parsed configured workspace fixture active polling wait poll budget",
        "[PASS] NPU model parsed configured workspace fixture active polling wait trace",
        "[PASS] NPU model parsed configured workspace fixture active completion poll telemetry",
        "[PASS] NPU model parsed configured workspace fixture active completion poll count",
        "[PASS] NPU model parsed configured workspace fixture active completion poll exhausted",
        "[PASS] NPU model parsed configured workspace fixture active completion signal MM aggregate",
        "[PASS] NPU model parsed configured workspace fixture active completion signal MM subroute",
        "[PASS] NPU model parsed configured workspace fixture active MM aggregate wait-exit evidence",
        "[PASS] NPU model parsed configured workspace fixture active MM aggregate wait-exit catalog",
        "[PASS] NPU model parsed configured workspace fixture active MM aggregate wait-exit no BLAI",
        "[PASS] NPU model parsed configured workspace fixture active MM aggregate wait-exit pending class",
        "[PASS] NPU model parsed configured workspace fixture active MM aggregate wait-exit pending enum",
        "[PASS] NPU model parsed configured workspace fixture active MM aggregate wait-exit no named subroute",
        "[PASS] NPU model parsed configured workspace fixture active MM aggregate wait-exit subroute",
        "[PASS] NPU model parsed configured workspace fixture active MM aggregate SDK helper evidence",
        "[PASS] NPU model parsed configured workspace fixture active MM aggregate SDK helper bank",
        "[PASS] NPU model parsed configured workspace fixture active MM aggregate SDK helper clear",
        "[PASS] NPU model parsed configured workspace fixture active MM aggregate SDK helper unmask",
        "[PASS] NPU model parsed configured workspace fixture active completion route target MM aggregate",
        "[PASS] NPU model parsed configured workspace fixture active completion route target MM polling",
        "[PASS] NPU model parsed configured workspace fixture active route aggregate evidence",
        "[PASS] NPU model parsed configured workspace fixture active route aggregate live",
        "[PASS] NPU model parsed configured workspace fixture active route aggregate polling",
        "[PASS] NPU model parsed configured workspace fixture active route aggregate coherent",
        "[PASS] NPU model parsed configured workspace fixture active output equivalence frontier route aggregate",
        "[PASS] NPU model parsed configured workspace fixture active output equivalence frontier live route",
        "[PASS] NPU model parsed configured workspace fixture active completion-output handoff route aggregate",
        "[PASS] NPU model parsed configured workspace fixture active completion-output handoff live route",
        "[PASS] NPU model parsed configured workspace fixture active start edge evidence",
        "[PASS] NPU model parsed configured workspace fixture active start edge retained",
        "[PASS] NPU model parsed configured workspace fixture active start edge command",
        "[PASS] NPU model parsed configured workspace fixture active start edge idle",
        "[PASS] NPU model parsed configured workspace fixture active start edge no immediate edge",
        "[PASS] NPU model parsed configured workspace fixture active start edge no interrupt",
        "[PASS] NPU model parsed configured workspace fixture active start command surface evidence",
        "[PASS] NPU model parsed configured workspace fixture active start command surface general",
        "[PASS] NPU model parsed configured workspace fixture active start command surface int cfg",
        "[PASS] NPU model parsed configured workspace fixture active start command surface no busy",
        "[PASS] NPU model parsed configured workspace fixture active start command surface no interrupt",
        "[PASS] NPU model parsed configured workspace fixture active start command surface SDK",
        "[PASS] NPU model parsed configured workspace fixture active polling signal evidence",
        "[PASS] NPU model parsed configured workspace fixture active polling signal signal",
        "[PASS] NPU model parsed configured workspace fixture active polling signal budget",
        "[PASS] NPU model parsed configured workspace fixture active polling signal polling",
        "[PASS] NPU model parsed configured workspace fixture active polling signal active",
        "[PASS] NPU model parsed configured workspace fixture active polling signal source",
        "[PASS] NPU model parsed configured workspace fixture active polling signal full budget",
        "[PASS] NPU model parsed configured workspace fixture active polling signal final clear",
        "[PASS] NPU model parsed configured workspace fixture active polling signal no interrupt",
        "[PASS] NPU model parsed configured workspace fixture active polling signal timeout",
        "[PASS] NPU model parsed configured workspace fixture active polling signal missing",
        "[PASS] NPU model parsed configured workspace fixture active polling signal deferred",
        "[PASS] NPU model parsed configured workspace fixture active polling signal coherent",
        "[PASS] NPU model parsed configured workspace fixture active workspace WRAM evidence",
        "[PASS] NPU model parsed configured workspace fixture active workspace WRAM projected",
        "[PASS] NPU model parsed configured workspace fixture active workspace WRAM address projected",
        "[PASS] NPU model parsed configured workspace fixture active workspace WRAM address fits",
        "[PASS] NPU model parsed configured workspace fixture active workspace WRAM alias",
        "[PASS] NPU model parsed configured workspace fixture active workspace WRAM base",
        "[PASS] NPU model parsed configured workspace fixture active workspace WRAM segments",
        "[PASS] NPU model parsed configured workspace fixture active workspace WRAM instruction",
        "[PASS] NPU model parsed configured workspace fixture active workspace WRAM data",
        "[PASS] NPU model parsed configured workspace fixture active workspace WRAM weight",
        "[PASS] NPU model parsed configured workspace fixture active workspace WRAM bias",
        "[PASS] NPU model parsed configured workspace fixture active stream semantic evidence",
        "[PASS] NPU model parsed configured workspace fixture active stream raw word evidence",
        "[PASS] NPU model parsed configured workspace fixture active SDK stream walk",
        "[PASS] NPU model parsed configured workspace fixture active SDK stream side record",
        "[PASS] NPU model parsed configured workspace fixture active SDK stream layer record",
        "[PASS] NPU model parsed configured workspace fixture active SDK stream layer count",
        "[PASS] NPU model parsed configured workspace fixture active SDK stream stop",
        "[PASS] NPU model parsed configured workspace fixture active terminal control",
        "[PASS] NPU model parsed configured workspace fixture active terminal split bits",
        "[PASS] NPU model parsed configured workspace fixture active terminal descriptor halt clear",
        "[PASS] NPU model parsed configured workspace fixture active terminal stream end",
        "[PASS] NPU model parsed configured workspace fixture active terminal control coherent",
        "[PASS] NPU model parsed configured workspace fixture active toolchain run gate",
        "[PASS] NPU model parsed configured workspace fixture active toolchain run CPU projection",
        "[PASS] NPU model parsed configured workspace fixture toolchain run direct gate",
        "[PASS] NPU model parsed configured workspace fixture toolchain run non-square gate",
        "[PASS] NPU model parsed configured workspace fixture toolchain run stride2 kernel gate",
        "[PASS] NPU model parsed configured workspace fixture toolchain run stride2 parity gate",
        "[PASS] NPU model parsed configured workspace fixture active stream operand plan",
        "[PASS] NPU model parsed configured workspace fixture active operand c2 zero",
        "[PASS] NPU model parsed configured workspace fixture active operand no extra info",
        "[PASS] NPU model parsed configured workspace fixture active operand single input c2",
        "[PASS] NPU model parsed configured workspace fixture active operand no weight patch extra",
        "[PASS] NPU model parsed configured workspace fixture active operand no line patch extra",
        "[PASS] NPU model parsed configured workspace fixture active operand no grouped extra",
        "[PASS] NPU model parsed configured workspace fixture active operand no stride extra",
        "[PASS] NPU model parsed configured workspace fixture active operand no dilation extra",
        "[PASS] NPU model parsed configured workspace fixture active stream one layer",
        "[PASS] NPU model parsed configured workspace fixture active stream instruction count",
        "[PASS] NPU model parsed configured workspace fixture active stream decoded layer count",
        "[PASS] NPU model parsed configured workspace fixture active layer semantics",
        "[PASS] NPU model parsed configured workspace fixture active layer linear activation",
        "[PASS] NPU model parsed configured workspace fixture active layer data type",
        "[PASS] NPU model parsed configured workspace fixture active stream evidence",
        "[PASS] NPU model parsed configured workspace fixture active stream fetch plan fits",
        "[PASS] NPU model parsed configured workspace fixture active stream encode fits",
        "[PASS] NPU model parsed configured workspace fixture active stream bundle matches",
        "[PASS] NPU model parsed configured workspace fixture active stream bundle count bounds",
        "[PASS] NPU model parsed configured workspace fixture active stream bundle bytes equal",
        "[PASS] NPU model parsed configured workspace fixture active stream layer index bounds",
        "[PASS] NPU model parsed configured workspace fixture active stream no extra",
        "[PASS] NPU model parsed configured workspace fixture active stream no external info",
        "[PASS] NPU model parsed configured workspace fixture active stream default layer index",
        "[PASS] NPU model parsed configured workspace fixture active stream halt",
        "[PASS] NPU model parsed configured workspace fixture active stream type",
        "[PASS] NPU model parsed configured workspace fixture active stream w",
        "[PASS] NPU model parsed configured workspace fixture active stream h",
        "[PASS] NPU model parsed configured workspace fixture active stream c",
        "[PASS] NPU model parsed configured workspace fixture active stream c2",
        "[PASS] NPU model parsed configured workspace fixture active stream out c",
        "[PASS] NPU model parsed configured workspace fixture active stream size",
        "[PASS] NPU model parsed configured workspace fixture active stream slots",
        "[PASS] NPU model parsed configured workspace fixture active stream input slot",
        "[PASS] NPU model parsed configured workspace fixture active stream output slot",
        "[PASS] NPU model parsed configured workspace fixture active stream stride",
        "[PASS] NPU model parsed configured workspace fixture active stream stride step",
        "[PASS] NPU model parsed configured workspace fixture active stream dilation",
        "[PASS] NPU model parsed configured workspace fixture active stream groups",
        "[PASS] NPU model parsed configured workspace fixture active stream fractions",
        "[PASS] NPU model parsed configured workspace fixture active stream fdata",
        "[PASS] NPU model parsed configured workspace fixture active stream fweight",
        "[PASS] NPU model parsed configured workspace fixture active stream fbias",
        "[PASS] NPU model parsed configured workspace fixture active stream fout",
        "[PASS] NPU model parsed configured workspace fixture active stream activation",
        "[PASS] NPU model parsed configured workspace fixture active stream activation kind",
        "[PASS] NPU model parsed configured workspace fixture active stream TF output offset",
        "[PASS] NPU model parsed configured workspace fixture active decoded TFLite descriptor",
        "[PASS] NPU model parsed configured workspace fixture active TFLite input offsets",
        "[PASS] NPU model parsed configured workspace fixture active TFLite output shift",
        "[PASS] NPU model parsed configured workspace fixture active quant side",
        "[PASS] NPU model parsed configured workspace fixture active decoded quant",
        "[PASS] NPU model parsed configured workspace fixture active quant TFLite flag",
        "[PASS] NPU model parsed configured workspace fixture active quant input1 shift",
        "[PASS] NPU model parsed configured workspace fixture active quant input2 shift",
        "[PASS] NPU model parsed configured workspace fixture active quant multipliers",
        "[PASS] NPU model parsed configured workspace fixture active quant input1 multiplier",
        "[PASS] NPU model parsed configured workspace fixture active quant input2 multiplier",
        "[PASS] NPU model parsed configured workspace fixture active quant output multiplier",
        "[PASS] NPU model parsed configured workspace fixture active quant clamp",
        "[PASS] NPU model parsed configured workspace fixture active quant activation min",
        "[PASS] NPU model parsed configured workspace fixture active quant activation max",
        "[PASS] NPU model parsed configured workspace fixture active common control",
        "[PASS] NPU model parsed configured workspace fixture active decoded common",
        "[PASS] NPU model decoded extra instruction",
        "[PASS] NPU model decoded normal descriptor",
        "[PASS] NPU model parsed configured workspace fixture active common img in",
        "[PASS] NPU model parsed configured workspace fixture active common max check",
        "[PASS] NPU model parsed configured workspace fixture active common route bit",
        "[PASS] NPU model parsed configured workspace fixture active common mac bit",
        "[PASS] NPU model parsed configured workspace fixture active common mid layer",
        "[PASS] NPU model parsed configured workspace fixture active common mid out",
        "[PASS] NPU model parsed configured workspace fixture active common mid state",
        "[PASS] NPU model parsed configured workspace fixture active common upsample",
        "[PASS] NPU model parsed configured workspace fixture active common mac ext",
        "[PASS] NPU model parsed configured workspace fixture active common inst end",
        "[PASS] NPU model parsed configured workspace fixture active bundle plan",
        "[PASS] NPU model parsed configured workspace fixture active bundle fetch fits",
        "[PASS] NPU model parsed configured workspace fixture active bundle TFLite mode",
        "[PASS] NPU model parsed configured workspace fixture active bundle extra info",
        "[PASS] NPU model parsed configured workspace fixture active bundle encode fits",
        "[PASS] NPU model parsed configured workspace fixture active bundle end count",
        "[PASS] NPU model parsed configured workspace fixture active bundle bytes",
        "[PASS] NPU model parsed configured workspace fixture active run plan evidence",
        "[PASS] NPU model parsed configured workspace fixture active config SDK index",
        "[PASS] NPU model parsed configured workspace fixture active config layer index",
        "[PASS] NPU model parsed configured workspace fixture active config first layer",
        "[PASS] NPU model parsed configured workspace fixture active config reset input",
        "[PASS] NPU model parsed configured workspace fixture active config patch",
        "[PASS] NPU model parsed configured workspace fixture active config buffers",
        "[PASS] NPU model parsed configured workspace fixture active config instruction address",
        "[PASS] NPU model parsed configured workspace fixture active config weight address",
        "[PASS] NPU model parsed configured workspace fixture active config bias address",
        "[PASS] NPU model parsed configured workspace fixture active config data address",
        "[PASS] NPU model parsed configured workspace fixture active config first data cache",
        "[PASS] NPU model parsed configured workspace fixture active config first cache present",
        "[PASS] NPU model parsed configured workspace fixture active config first cache clean",
        "[PASS] NPU model parsed configured workspace fixture active config first cache offset",
        "[PASS] NPU model parsed configured workspace fixture active config first cache bytes",
        "[PASS] NPU model parsed configured workspace fixture active config patch register evidence",
        "[PASS] NPU model parsed configured workspace fixture active config patch register SDK write",
        "[PASS] NPU model parsed configured workspace fixture active config patch register imageSeg",
        "[PASS] NPU model parsed configured workspace fixture active data slot evidence",
        "[PASS] NPU model parsed configured workspace fixture active data slots",
        "[PASS] NPU model parsed configured workspace fixture active data slots distinct",
        "[PASS] NPU model parsed configured workspace fixture active data input offset",
        "[PASS] NPU model parsed configured workspace fixture active data output offset",
        "[PASS] NPU model parsed configured workspace fixture active data input fits",
        "[PASS] NPU model parsed configured workspace fixture active data output fits",
        "[PASS] NPU model parsed configured workspace fixture active input staged present",
        "[PASS] NPU model parsed configured workspace fixture active input staged byte",
        "[PASS] NPU model parsed configured workspace fixture active DATA mapping evidence",
        "[PASS] NPU model parsed configured workspace fixture active DATA mapping run plan",
        "[PASS] NPU model parsed configured workspace fixture active DATA mapping slots",
        "[PASS] NPU model parsed configured workspace fixture active DATA mapping patch",
        "[PASS] NPU model parsed configured workspace fixture active DATA mapping distinct",
        "[PASS] NPU model parsed configured workspace fixture active DATA mapping staged input",
        "[PASS] NPU model parsed configured workspace fixture active DATA mapping output",
        "[PASS] NPU model parsed configured workspace fixture active DATA mapping first cache",
        "[PASS] NPU model parsed configured workspace fixture active workspace byte evidence",
        "[PASS] NPU model parsed configured workspace fixture active workspace stream bytes",
        "[PASS] NPU model parsed configured workspace fixture active workspace instruction byte count",
        "[PASS] NPU model parsed configured workspace fixture active workspace instruction fits",
        "[PASS] NPU model parsed configured workspace fixture active workspace instruction bytes",
        "[PASS] NPU model parsed configured workspace fixture active workspace stream trailing",
        "[PASS] NPU model parsed configured workspace fixture active workspace trailing fits",
        "[PASS] NPU model parsed configured workspace fixture active workspace trailing zero",
        "[PASS] NPU model parsed configured workspace fixture active workspace weight bytes",
        "[PASS] NPU model parsed configured workspace fixture active workspace weight fits",
        "[PASS] NPU model parsed configured workspace fixture active workspace weight matches",
        "[PASS] NPU model parsed configured workspace fixture active workspace bias bytes",
        "[PASS] NPU model parsed configured workspace fixture active workspace bias aligned",
        "[PASS] NPU model parsed configured workspace fixture active workspace bias fits",
        "[PASS] NPU model parsed configured workspace fixture active workspace bias matches",
        "[PASS] NPU model parsed configured workspace fixture active packed weight evidence",
        "[PASS] NPU model parsed configured workspace fixture active weight plan",
        "[PASS] NPU model parsed configured workspace fixture active packed weight bytes",
        "[PASS] NPU model parsed configured workspace fixture active packed weight byte count",
        "[PASS] NPU model parsed configured workspace fixture active materialized weight byte count",
        "[PASS] NPU model parsed configured workspace fixture active weight cursor",
        "[PASS] NPU model parsed configured workspace fixture active packed weight tile",
        "[PASS] NPU model parsed configured workspace fixture active packed tile units",
        "[PASS] NPU model parsed configured workspace fixture active packed first weight present",
        "[PASS] NPU model parsed configured workspace fixture active packed first weight byte",
        "[PASS] NPU model parsed configured workspace fixture active packed first padding byte",
        "[PASS] NPU model parsed configured workspace fixture active packed last padding byte",
        "[PASS] NPU model parsed configured workspace fixture active bias pack",
        "[PASS] NPU model parsed configured workspace fixture active bias bytes",
        "[PASS] NPU model parsed configured workspace fixture active bias cursor",
        "[PASS] NPU model parsed configured workspace fixture active first bias present",
        "[PASS] NPU model parsed configured workspace fixture active first bias word",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp evidence",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp projected",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp address projected",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp address fits",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp address range",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp weight aligned",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias address",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp typed result",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp prepared",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp buffer fits",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp weight fits",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias aligned",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias fits",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp weight bytes",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias bytes",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias offset",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bytes",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp weight buffer present",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp weight buffer bytes",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias buffer present",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias buffer bytes",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp cache",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp weight cache",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp weight cache active",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp weight cache fits",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp weight cache applied",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp weight cache operation",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp weight cache address",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp weight cache bytes",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias cache",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias cache active",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias cache fits",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias cache applied",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias cache operation",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias cache address",
        "[PASS] NPU model parsed configured workspace fixture active SDK temp bias cache bytes",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge evidence",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge materialized",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge stream",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge bytes",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge temp",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge data mapping",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge run plan",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge instruction address",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge data address",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge weight address",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge bias address",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge instruction bytes",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge weight bytes",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge bias bytes",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge byte evidence",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge cache",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge addresses",
        "[PASS] NPU model parsed configured workspace fixture active launch bridge ready",
        "[PASS] NPU model parsed configured workspace fixture active launch/start register evidence",
        "[PASS] NPU model parsed configured workspace fixture active launch captured",
        "[PASS] NPU model parsed configured workspace fixture active launch snapshot captured",
        "[PASS] NPU model parsed configured workspace fixture active launch register evidence",
        "[PASS] NPU model parsed configured workspace fixture active launch inst",
        "[PASS] NPU model parsed configured workspace fixture active launch weight",
        "[PASS] NPU model parsed configured workspace fixture active launch bias",
        "[PASS] NPU model parsed configured workspace fixture active launch data",
        "[PASS] NPU model parsed configured workspace fixture active launch segment",
        "[PASS] NPU model parsed configured workspace fixture active launch unsigned input",
        "[PASS] NPU model parsed configured workspace fixture active launch tensorflow mode",
        "[PASS] NPU model parsed configured workspace fixture active launch reluN",
        "[PASS] NPU model parsed configured workspace fixture active launch net",
        "[PASS] NPU model parsed configured workspace fixture active launch int cfg start clean",
        "[PASS] NPU model parsed configured workspace fixture active launch int cfg resume clean",
        "[PASS] NPU model parsed configured workspace fixture active launch int cfg stop clean",
        "[PASS] NPU model parsed configured workspace fixture active launch int cfg clear clean",
        "[PASS] NPU model parsed configured workspace fixture active launch int cfg status clean",
        "[PASS] NPU model parsed configured workspace fixture active launch int cfg idle",
        "[PASS] NPU model parsed configured workspace fixture active start observed",
        "[PASS] NPU model parsed configured workspace fixture active started register evidence",
        "[PASS] NPU model parsed configured workspace fixture active started snapshot captured",
        "[PASS] NPU model parsed configured workspace fixture active started inst",
        "[PASS] NPU model parsed configured workspace fixture active started weight",
        "[PASS] NPU model parsed configured workspace fixture active started bias",
        "[PASS] NPU model parsed configured workspace fixture active started data",
        "[PASS] NPU model parsed configured workspace fixture active started segment",
        "[PASS] NPU model parsed configured workspace fixture active started unsigned input",
        "[PASS] NPU model parsed configured workspace fixture active started tensorflow mode",
        "[PASS] NPU model parsed configured workspace fixture active started reluN",
        "[PASS] NPU model parsed configured workspace fixture active started net",
        "[PASS] NPU model parsed configured workspace fixture active started int cfg resume clean",
        "[PASS] NPU model parsed configured workspace fixture active started int cfg stop clean",
        "[PASS] NPU model parsed configured workspace fixture active started int cfg clear clean",
        "[PASS] NPU model parsed configured workspace fixture active started int cfg status clean",
        "[PASS] NPU model parsed configured workspace fixture active started int cfg clean",
        "[PASS] NPU model parsed configured workspace fixture active snapshot started mirror",
        "[PASS] NPU model parsed configured workspace fixture active launch general cfg defaults",
        "[PASS] NPU model parsed configured workspace fixture active launch general cfg ftable",
        "[PASS] NPU model parsed configured workspace fixture active launch general cfg reserved",
        "[PASS] NPU model parsed configured workspace fixture active started general cfg defaults",
        "[PASS] NPU model parsed configured workspace fixture active started general cfg ftable",
        "[PASS] NPU model parsed configured workspace fixture active started general cfg idle",
        "[PASS] NPU model parsed configured workspace fixture active launch int cfg known fields",
        "[PASS] NPU model parsed configured workspace fixture active launch int cfg reserved",
        "[PASS] NPU model parsed configured workspace fixture active launch int cfg relu default",
        "[PASS] NPU model parsed configured workspace fixture active started int cfg known fields",
        "[PASS] NPU model parsed configured workspace fixture active started int cfg reserved",
        "[PASS] NPU model parsed configured workspace fixture active started int cfg relu default",
        "[PASS] NPU model parsed configured workspace fixture active launch retention evidence",
        "[PASS] NPU model parsed configured workspace fixture active launch retention captures",
        "[PASS] NPU model parsed configured workspace fixture active launch retention addresses",
        "[PASS] NPU model parsed configured workspace fixture active launch retention segment",
        "[PASS] NPU model parsed configured workspace fixture active launch retention net",
        "[PASS] NPU model parsed configured workspace fixture active launch retention launch commands",
        "[PASS] NPU model parsed configured workspace fixture active launch retention started commands",
        "[PASS] NPU model parsed configured workspace fixture active launch retention start observed",
        "[PASS] NPU model parsed configured workspace fixture active launch retention started mirror",
        "[PASS] NPU model parsed configured workspace fixture active cache evidence",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache fits",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache applied",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache inst",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache inst active",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache inst fits",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache inst applied",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache inst operation",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache inst address",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache inst bytes",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache weight",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache weight active",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache weight fits",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache weight applied",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache weight operation",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache weight address",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache weight bytes",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache bias",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache bias active",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache bias fits",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache bias applied",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache bias operation",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache bias address",
        "[PASS] NPU model parsed configured workspace fixture active workspace cache bias bytes",
        "[PASS] NPU model parsed configured workspace fixture active data cache plan",
        "[PASS] NPU model parsed configured workspace fixture active data cache clean",
        "[PASS] NPU model parsed configured workspace fixture active data cache count",
        "[PASS] NPU model parsed configured workspace fixture active data cache active",
        "[PASS] NPU model parsed configured workspace fixture active data cache fits",
        "[PASS] NPU model parsed configured workspace fixture active data cache applied",
        "[PASS] NPU model parsed configured workspace fixture active data cache operation",
        "[PASS] NPU model parsed configured workspace fixture active data cache address",
        "[PASS] NPU model parsed configured workspace fixture active data cache bytes",
        "[PASS] NPU model parsed configured workspace fixture active cache contract evidence",
        "[PASS] NPU model parsed configured workspace fixture active cache contract workspace active",
        "[PASS] NPU model parsed configured workspace fixture active cache contract workspace fits",
        "[PASS] NPU model parsed configured workspace fixture active cache contract workspace applied",
        "[PASS] NPU model parsed configured workspace fixture active cache contract workspace clean",
        "[PASS] NPU model parsed configured workspace fixture active cache contract workspace addresses",
        "[PASS] NPU model parsed configured workspace fixture active cache contract workspace bytes",
        "[PASS] NPU model parsed configured workspace fixture active cache contract workspace valid",
        "[PASS] NPU model parsed configured workspace fixture active cache contract data count",
        "[PASS] NPU model parsed configured workspace fixture active cache contract data clean",
        "[PASS] NPU model parsed configured workspace fixture active launch cache register evidence",
        "[PASS] NPU model parsed configured workspace fixture active launch cache register instruction",
        "[PASS] NPU model parsed configured workspace fixture active launch cache register data",
        "[PASS] NPU model parsed configured workspace fixture active launch cache register weight",
        "[PASS] NPU model parsed configured workspace fixture active launch cache register bias",
        "[PASS] NPU model parsed configured workspace fixture active launch cache register addresses",
        "[PASS] NPU model parsed configured workspace fixture active launch cache register bytes",
        "[PASS] NPU model parsed configured workspace fixture active launch SRAM address evidence",
        "[PASS] NPU model parsed configured workspace fixture active launch SRAM address registers",
        "[PASS] NPU model parsed configured workspace fixture active launch SRAM address instruction",
        "[PASS] NPU model parsed configured workspace fixture active launch SRAM address data",
        "[PASS] NPU model parsed configured workspace fixture active launch SRAM address weight",
        "[PASS] NPU model parsed configured workspace fixture active launch SRAM address bias",
        "[PASS] NPU model parsed configured workspace fixture active launch SRAM ownership",
        "[PASS] NPU model parsed configured workspace fixture active launch SRAM latch",
        "[PASS] NPU model parsed configured workspace fixture active launch WRAM span evidence",
        "[PASS] NPU model parsed configured workspace fixture active launch WRAM span bus",
        "[PASS] NPU model parsed configured workspace fixture active launch WRAM span instruction",
        "[PASS] NPU model parsed configured workspace fixture active launch WRAM span data",
        "[PASS] NPU model parsed configured workspace fixture active launch WRAM span weight",
        "[PASS] NPU model parsed configured workspace fixture active launch WRAM span bias",
        "[PASS] NPU model parsed configured workspace fixture active launch instruction fetch evidence",
        "[PASS] NPU model parsed configured workspace fixture active launch instruction fetch address",
        "[PASS] NPU model parsed configured workspace fixture active launch instruction fetch bytes",
        "[PASS] NPU model parsed configured workspace fixture active launch instruction fetch records",
        "[PASS] NPU model parsed configured workspace fixture active launch instruction fetch encoder",
        "[PASS] NPU model parsed configured workspace fixture active launch instruction fetch SDK walk",
        "[PASS] NPU model parsed configured workspace fixture active launch instruction fetch control",
        "[PASS] NPU model parsed configured workspace fixture active launch operand fetch evidence",
        "[PASS] NPU model parsed configured workspace fixture active launch operand fetch registers",
        "[PASS] NPU model parsed configured workspace fixture active launch operand fetch segment",
        "[PASS] NPU model parsed configured workspace fixture active launch operand fetch slots",
        "[PASS] NPU model parsed configured workspace fixture active launch operand fetch single input",
        "[PASS] NPU model parsed configured workspace fixture active launch operand fetch data",
        "[PASS] NPU model parsed configured workspace fixture active launch operand fetch weights",
        "[PASS] NPU model parsed configured workspace fixture active terminal gate evidence",
        "[PASS] NPU model parsed configured workspace fixture active terminal classified",
        "[PASS] NPU model parsed configured workspace fixture active terminal gate known",
        "[PASS] NPU model parsed configured workspace fixture active terminal valid flag",
        "[PASS] NPU model parsed configured workspace fixture active terminal evidence",
        "[PASS] NPU model parsed configured workspace fixture active terminal complete evidence",
        "[PASS] NPU model parsed configured workspace fixture active terminal materialization evidence",
        "[PASS] NPU model parsed configured workspace fixture active terminal binding evidence",
        "[PASS] NPU model parsed configured workspace fixture active terminal hardware-address evidence",
        "[PASS] NPU model parsed configured workspace fixture active terminal input evidence",
        "[PASS] NPU model parsed configured workspace fixture active terminal run-sequence evidence",
        "[PASS] NPU model parsed configured workspace fixture active terminal execution evidence",
        "[PASS] NPU model parsed configured workspace fixture active terminal output evidence",
        "[PASS] NPU model parsed configured workspace fixture active bus decode status",
        "[PASS] NPU model parsed configured workspace fixture active bus decode no MM error",
        "[PASS] NPU model parsed configured workspace fixture active bus decode no MCU error",
        "[PASS] NPU model parsed configured workspace fixture active bus decode no error",
        "[PASS] NPU model parsed configured workspace fixture active execution gate evidence",
        "[PASS] NPU model parsed configured workspace fixture active terminal execution gate",
        "[PASS] NPU model parsed configured workspace fixture active terminal execution",
        "[PASS] NPU model parsed configured workspace fixture active execution attempted",
        "[PASS] NPU model parsed configured workspace fixture active execution failed captured",
        "[PASS] NPU model parsed configured workspace fixture active execution started",
        "[PASS] NPU model parsed configured workspace fixture active execution incomplete",
        "[PASS] NPU model parsed configured workspace fixture active execution status evidence",
        "[PASS] NPU model parsed configured workspace fixture active execution timeout status",
        "[PASS] NPU model parsed configured workspace fixture active execution timeout timed out",
        "[PASS] NPU model parsed configured workspace fixture active execution unsupported status",
        "[PASS] NPU model parsed configured workspace fixture active execution busy status",
        "[PASS] NPU model parsed configured workspace fixture active execution ok status",
        "[PASS] NPU model parsed configured workspace fixture active execution non-ok status",
        "[PASS] NPU model parsed configured workspace fixture active engine progress evidence",
        "[PASS] NPU model parsed configured workspace fixture active engine progress terminal gate",
        "[PASS] NPU model parsed configured workspace fixture active engine progress run sequence",
        "[PASS] NPU model parsed configured workspace fixture active engine progress counters",
        "[PASS] NPU model parsed configured workspace fixture active engine progress attempted",
        "[PASS] NPU model parsed configured workspace fixture active engine progress no complete",
        "[PASS] NPU model parsed configured workspace fixture active engine progress failed",
        "[PASS] NPU model parsed configured workspace fixture active engine progress first failed",
        "[PASS] NPU model parsed configured workspace fixture active engine progress captured",
        "[PASS] NPU model parsed configured workspace fixture active engine progress started",
        "[PASS] NPU model parsed configured workspace fixture active engine progress incomplete",
        "[PASS] NPU model parsed configured workspace fixture active engine progress timeout",
        "[PASS] NPU model parsed configured workspace fixture active timeout evidence",
        "[PASS] NPU model parsed configured workspace fixture active timeout status evidence",
        "[PASS] NPU model parsed configured workspace fixture active timeout timed out evidence",
        "[PASS] NPU model parsed configured workspace fixture active timeout no interrupt evidence",
        "[PASS] NPU model parsed configured workspace fixture active timeout raw clear evidence",
        "[PASS] NPU model parsed configured workspace fixture active timeout command clean evidence",
        "[PASS] NPU model parsed configured workspace fixture active timeout busy or idle evidence",
        "[PASS] NPU model parsed configured workspace fixture active timeout busy raw evidence",
        "[PASS] NPU model parsed configured workspace fixture active timeout clock retained evidence",
        "[PASS] NPU model parsed configured workspace fixture active timeout status valid evidence",
        "[PASS] NPU model parsed configured workspace fixture active wait-exit evidence",
        "[PASS] NPU model parsed configured workspace fixture active wait-exit timeout",
        "[PASS] NPU model parsed configured workspace fixture active wait-exit no interrupt",
        "[PASS] NPU model parsed configured workspace fixture active wait-exit commands",
        "[PASS] NPU model parsed configured workspace fixture active wait-exit busy known",
        "[PASS] NPU model parsed configured workspace fixture active wait-exit AXI activity",
        "[PASS] NPU model parsed configured workspace fixture active wait-exit clock",
        "[PASS] NPU model parsed configured workspace fixture active wait-exit status",
        "[PASS] NPU model parsed configured workspace fixture active wait-exit mode evidence",
        "[PASS] NPU model parsed configured workspace fixture active wait-exit mode classified",
        "[PASS] NPU model parsed configured workspace fixture active wait-exit mode no interrupt",
        "[PASS] NPU model parsed configured workspace fixture active wait-exit mode evidence bits",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget evidence",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget policy",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget polling",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget timeout",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget wait-exit",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget configured",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget matches",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget terminal",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget exhausted",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget no interrupt",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget status",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget wait no interrupt",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget wait known",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget commands",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget clock",
        "[PASS] NPU model parsed configured workspace fixture active completion wait budget deterministic",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate evidence",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate budget",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate scope",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate frontier",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate handoff",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate timeout",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate no interrupt",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate live route",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate plan",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate readback",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate compare",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate primary",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate order",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate next",
        "[PASS] NPU model parsed configured workspace fixture active post-budget output gate coherent",
        "[PASS] NPU model parsed configured workspace fixture active gap output route evidence",
        "[PASS] NPU model parsed configured workspace fixture active gap output route live",
        "[PASS] NPU model parsed configured workspace fixture active gap output route reason",
        "[PASS] NPU model parsed configured workspace fixture active gap output route coherent",
        "[PASS] NPU model parsed configured workspace fixture active recovery route frontier evidence",
        "[PASS] NPU model parsed configured workspace fixture active recovery route frontier live route",
        "[PASS] NPU model parsed configured workspace fixture active recovery route frontier output gate",
        "[PASS] NPU model parsed configured workspace fixture active recovery route frontier coherent",
        "[PASS] NPU model parsed configured workspace fixture active completion route resolution evidence",
        "[PASS] NPU model parsed configured workspace fixture active completion route resolution live frontier",
        "[PASS] NPU model parsed configured workspace fixture active completion route resolution output gate",
        "[PASS] NPU model parsed configured workspace fixture active completion route resolution coherent",
        "[PASS] NPU model parsed configured workspace fixture active start clock evidence",
        "[PASS] NPU model parsed configured workspace fixture active start clock enabled",
        "[PASS] NPU model parsed configured workspace fixture active start clock source",
        "[PASS] NPU model parsed configured workspace fixture active start clock divider",
        "[PASS] NPU model parsed configured workspace fixture active start clock retained",
        "[PASS] NPU model parsed configured workspace fixture active start transition evidence",
        "[PASS] NPU model parsed configured workspace fixture active start transition first run",
        "[PASS] NPU model parsed configured workspace fixture active start transition command",
        "[PASS] NPU model parsed configured workspace fixture active start transition wrapper",
        "[PASS] NPU model parsed configured workspace fixture active start transition SDK",
        "[PASS] NPU model parsed configured workspace fixture active inference SDK sequence",
        "[PASS] NPU model parsed configured workspace fixture active inference SDK sequence pending",
        "[PASS] NPU model parsed configured workspace fixture active inference SDK sequence block",
        "[PASS] NPU model parsed configured workspace fixture active SDK forward sequence",
        "[PASS] NPU model parsed configured workspace fixture active SDK forward sequence deferred",
        "[PASS] NPU model parsed configured workspace fixture active SDK forward sequence block",
        "[PASS] NPU model parsed configured workspace fixture active CNN wrapper completion surface evidence",
        "[PASS] NPU model parsed configured workspace fixture active CNN wrapper completion surface standard clear",
        "[PASS] NPU model parsed configured workspace fixture active CNN wrapper completion surface candidate",
        "[PASS] NPU model parsed configured workspace fixture active CNN wrapper completion surface wrapper only",
        "[PASS] NPU model parsed configured workspace fixture active CNN wrapper completion surface conflict",
        "[PASS] NPU model parsed configured workspace fixture active CNN wrapper completion surface read only",
        "[PASS] NPU model parsed configured workspace fixture active CNN wrapper completion surface policy",
        "[PASS] NPU model parsed configured workspace fixture active CNN IRQ controller evidence",
        "[PASS] NPU model parsed configured workspace fixture active CNN IRQ controller line",
        "[PASS] NPU model parsed configured workspace fixture active CNN IRQ controller source",
        "[PASS] NPU model parsed configured workspace fixture active CNN IRQ controller alias",
        "[PASS] NPU model parsed configured workspace fixture active CNN IRQ controller pending",
        "[PASS] NPU model parsed configured workspace fixture active CNN IRQ controller disabled",
        "[PASS] NPU model parsed configured workspace fixture active CNN IRQ controller masked",
        "[PASS] NPU model parsed configured workspace fixture active CNN IRQ controller vector",
        "[PASS] NPU model parsed configured workspace fixture active CNN IRQ controller deferred",
        "[PASS] NPU model parsed configured workspace fixture active completion route binding safety evidence",
        "[PASS] NPU model parsed configured workspace fixture active completion route binding safety M0 alias",
        "[PASS] NPU model parsed configured workspace fixture active completion route binding safety suppressed",
        "[PASS] NPU model parsed configured workspace fixture active completion route binding safety next",
        "[PASS] NPU model parsed configured workspace fixture active completion route probe plan",
        "[PASS] NPU model parsed configured workspace fixture active completion route probe plan subroute",
        "[PASS] NPU model parsed configured workspace fixture active completion route probe plan action",
        "[PASS] NPU model parsed configured workspace fixture active completion route probe plan readback",
        "[PASS] NPU model parsed configured workspace fixture active output equivalence readiness coherent",
        "[PASS] NPU model MNIST TFLite active output validation evidence",
        "[PASS] NPU model MNIST TFLite active output validation completion",
        "[PASS] NPU model MNIST TFLite active output validation block",
        "[PASS] NPU model parsed configured workspace fixture active completion boundary evidence",
        "[PASS] NPU model parsed configured workspace fixture active completion boundary policy",
        "[PASS] NPU model parsed configured workspace fixture active completion boundary engine",
        "[PASS] NPU model parsed configured workspace fixture active completion boundary timeout",
        "[PASS] NPU model parsed configured workspace fixture active completion boundary deferred output",
        "[PASS] NPU model parsed configured workspace fixture active completion boundary no interrupt",
        "[PASS] NPU model parsed configured workspace fixture active completion boundary busy known",
        "[PASS] NPU model parsed configured workspace fixture active completion boundary output deferred",
        "[PASS] NPU model parsed configured workspace fixture active completion boundary remaining progress",
        "[PASS] NPU model parsed configured workspace fixture active completion gap evidence",
        "[PASS] NPU model parsed configured workspace fixture active completion gap boundary",
        "[PASS] NPU model parsed configured workspace fixture active completion gap wait-exit",
        "[PASS] NPU model parsed configured workspace fixture active completion gap output blocked",
        "[PASS] NPU model parsed configured workspace fixture active completion gap no interrupt",
        "[PASS] NPU model parsed configured workspace fixture active completion gap wait-exit known",
        "[PASS] NPU model parsed configured workspace fixture active completion gap output gate",
        "[PASS] NPU model parsed configured workspace fixture active completion gap remaining progress",
        "[PASS] NPU model parsed configured workspace fixture active BLAI TZMID missing evidence",
        "[PASS] NPU model parsed configured workspace fixture active BLAI TZMID missing precondition",
        "[PASS] NPU model parsed configured workspace fixture active BLAI TZMID configured evidence",
        "[PASS] NPU model parsed configured workspace fixture active BLAI TZMID configured group",
        "[PASS] NPU model parsed configured workspace fixture active BLAI TZMID configured lock",
        "[PASS] NPU model parsed configured workspace fixture active BLAI TZMID plan evidence",
        "[PASS] NPU model parsed configured workspace fixture active BLAI TZMID plan preserve",
        "[PASS] NPU model parsed configured workspace fixture active BLAI TZMID live evidence",
        "[PASS] NPU model parsed configured workspace fixture active BLAI TZMID live readable",
        "[PASS] NPU model parsed configured workspace fixture active BLAI TZMID live group bounded",
        "[PASS] NPU model parsed configured workspace fixture active BLAI TZMID live classification",
        "[PASS] NPU model parsed configured workspace fixture active execution timeout",
        "[PASS] NPU model parsed configured workspace fixture active wait no interrupt",
        "[PASS] NPU model parsed configured workspace fixture active wait int raw clear",
        "[PASS] NPU model parsed configured workspace fixture active wait int cfg resume clean",
        "[PASS] NPU model parsed configured workspace fixture active wait int cfg stop clean",
        "[PASS] NPU model parsed configured workspace fixture active wait int cfg clear clean",
        "[PASS] NPU model parsed configured workspace fixture active wait int cfg status clean",
        "[PASS] NPU model parsed configured workspace fixture active wait int cfg clean",
        "[PASS] NPU model parsed configured workspace fixture active wait int cfg known fields",
        "[PASS] NPU model parsed configured workspace fixture active wait int cfg reserved",
        "[PASS] NPU model parsed configured workspace fixture active wait int cfg relu default",
        "[PASS] NPU model parsed configured workspace fixture active wait axi write state",
        "[PASS] NPU model parsed configured workspace fixture active wait axi read state",
        "[PASS] NPU model parsed configured workspace fixture active wait idle",
        "[PASS] NPU model parsed configured workspace fixture active wait clock enabled",
        "[PASS] NPU model parsed configured workspace fixture active wait clock source known",
        "[PASS] NPU model parsed configured workspace fixture active wait clock source 320M",
        "[PASS] NPU model parsed configured workspace fixture active wait clock divider zero",
        "[PASS] NPU model parsed configured workspace fixture active wait clock source",
        "[PASS] NPU model SDK helper conv allocator",
        "[PASS] NPU model SDK helper conv allocator mid inactive",
        "[PASS] NPU model SDK helper conv allocator mid source",
        "[PASS] NPU model SDK helper softmax allocator mid source",
        "[PASS] NPU model SDK helper toolchain globals",
        "[PASS] NPU model SDK helper toolchain patch size",
        "[PASS] NPU model SDK helper toolchain max patches",
        "[PASS] NPU model SDK helper initial request forced channels",
        "[PASS] NPU model SDK helper initial request passthrough",
        "[PASS] NPU model SDK helper initial request blocked",
        "[PASS] NPU model SDK helper PSRAM allocate scratch",
        "[PASS] NPU model SDK helper patch search call prepare",
        "[PASS] NPU model SDK helper patch search call prepare inherited",
        "[PASS] NPU model SDK helper patch search call prepare blocked",
        "[PASS] NPU model SDK helper PSRAM input membership",
        "[PASS] NPU model SDK helper PSRAM input membership blocked",
        "[PASS] NPU model SDK helper PSRAM layer request",
        "[PASS] NPU model SDK helper PSRAM skip request",
        "[PASS] NPU model SDK helper PSRAM DSP request",
        "[PASS] NPU model SDK helper PSRAM DSP request blocked",
        "[PASS] NPU model SDK helper PSRAM DSP patch pair",
        "[PASS] NPU model SDK helper PSRAM DSP patch pair blocked",
        "[PASS] NPU model SDK helper PSRAM layer loop",
        "[PASS] NPU model SDK helper PSRAM layer loop blocked",
        "[PASS] NPU model SDK helper PSRAM TFLite request",
        "[PASS] NPU model SDK helper PSRAM TFLite request blocked",
        "[PASS] NPU model SDK helper PSRAM TFLite patch",
        "[PASS] NPU model SDK helper PSRAM TFLite patch blocked",
        "[PASS] NPU model SDK helper PSRAM request store",
        "[PASS] NPU model SDK helper PSRAM request store blocked",
        "[PASS] NPU model SDK helper set wei call",
        "[PASS] NPU model SDK helper set wei call blocked",
        "[PASS] NPU model SDK helper set wei return",
        "[PASS] NPU model SDK helper set wei return blocked",
        "[PASS] NPU model SDK helper PSRAM owner transfer",
        "[PASS] NPU model SDK helper PSRAM owner release",
        "[PASS] NPU model SDK helper PSRAM owner ignore",
        "[PASS] NPU model SDK helper PSRAM owner missing start",
        "[PASS] NPU model SDK helper PSRAM owner cleanup transfer",
        "[PASS] NPU model SDK helper PSRAM owner cleanup route flag",
        "[PASS] NPU model SDK helper PSRAM owner cleanup release",
        "[PASS] NPU model SDK helper PSRAM owner cleanup ignore",
        "[PASS] NPU model SDK helper PSRAM owner cleanup sweep transfer",
        "[PASS] NPU model SDK helper PSRAM owner cleanup sweep release",
        "[PASS] NPU model SDK helper PSRAM owner cleanup sweep blocked",
        "[PASS] NPU model SDK helper PSRAM post-search slot retain",
        "[PASS] NPU model SDK helper PSRAM post-search slot release",
        "[PASS] NPU model SDK helper PSRAM post-search slot ignore",
        "[PASS] NPU model SDK helper PSRAM post-search slot blocked",
        "[PASS] NPU model SDK helper PSRAM metadata discard",
        "[PASS] NPU model SDK helper PSRAM metadata discard banks",
        "[PASS] NPU model SDK helper PSRAM metadata discard banks blocked",
        "[PASS] NPU model SDK helper PSRAM metadata preserve",
        "[PASS] NPU model SDK helper PSRAM metadata discard blocked",
        "[PASS] NPU model SDK helper PSRAM fallback gate",
        "[PASS] NPU model SDK helper PSRAM fallback gate blocked",
        "[PASS] NPU model SDK helper PSRAM unassigned metadata",
        "[PASS] NPU model SDK helper PSRAM unassigned metadata banks",
        "[PASS] NPU model SDK helper PSRAM unassigned metadata banks blocked",
        "[PASS] NPU model SDK helper PSRAM unassigned metadata preserve",
        "[PASS] NPU model SDK helper PSRAM unassigned metadata blocked",
        "[PASS] NPU model SDK helper PSRAM fallback metadata select",
        "[PASS] NPU model SDK helper PSRAM fallback metadata banks",
        "[PASS] NPU model SDK helper PSRAM fallback metadata banks blocked",
        "[PASS] NPU model SDK helper PSRAM fallback metadata clear",
        "[PASS] NPU model SDK helper PSRAM fallback metadata preserve",
        "[PASS] NPU model SDK helper PSRAM fallback metadata blocked",
        "[PASS] NPU model SDK helper PSRAM split metadata",
        "[PASS] NPU model SDK helper PSRAM split metadata blocked",
        "[PASS] NPU model SDK helper set wei page conv",
        "[PASS] NPU model SDK helper set wei route gate",
        "[PASS] NPU model SDK helper set wei route gate blocked",
        "[PASS] NPU model SDK helper set wei route source",
        "[PASS] NPU model SDK helper set wei route source blocked",
        "[PASS] NPU model SDK helper set wei base offset",
        "[PASS] NPU model SDK helper set wei page routew",
        "[PASS] NPU model SDK helper set wei divisor routew",
        "[PASS] NPU model SDK helper set wei divisor special",
        "[PASS] NPU model SDK helper set wei store divisor",
        "[PASS] NPU model SDK helper set wei store auxiliary",
        "[PASS] NPU model SDK helper set wei store select",
        "[PASS] NPU model SDK helper set wei store select forced",
        "[PASS] NPU model SDK helper set wei pressure",
        "[PASS] NPU model SDK helper set wei pressure blocked",
        "[PASS] NPU model SDK helper set wei large flag masked",
        "[PASS] NPU model SDK helper set wei large flag threshold",
        "[PASS] NPU model SDK helper set wei large flag unmasked",
        "[PASS] NPU model SDK helper set wei large flag range",
        "[PASS] NPU model SDK helper set wei large split nondiv",
        "[PASS] NPU model SDK helper set wei large split divisible",
        "[PASS] NPU model SDK helper set wei large split invalid flag",
        "[PASS] NPU model SDK helper set wei large split capacity",
        "[PASS] NPU model SDK helper set wei large total valid",
        "[PASS] NPU model SDK helper set wei large total invalid split",
        "[PASS] NPU model SDK helper set wei large total overflow",
        "[PASS] NPU model SDK helper set wei lower flag masked",
        "[PASS] NPU model SDK helper set wei lower flag threshold",
        "[PASS] NPU model SDK helper set wei lower flag unmasked",
        "[PASS] NPU model SDK helper set wei lower flag divisor",
        "[PASS] NPU model SDK helper set wei lower flag overflow",
        "[PASS] NPU model SDK helper set wei lower split nondiv",
        "[PASS] NPU model SDK helper set wei lower split divisible",
        "[PASS] NPU model SDK helper set wei lower split invalid flag",
        "[PASS] NPU model SDK helper set wei lower split capacity",
        "[PASS] NPU model SDK helper set wei lower total valid",
        "[PASS] NPU model SDK helper set wei lower total invalid split",
        "[PASS] NPU model SDK helper set wei lower total overflow",
        "[PASS] NPU model SDK helper set wei no patch valid",
        "[PASS] NPU model SDK helper set wei no patch invalid",
        "[PASS] NPU model SDK helper set wei branch large",
        "[PASS] NPU model SDK helper set wei branch lower",
        "[PASS] NPU model SDK helper set wei branch no patch",
        "[PASS] NPU model SDK helper set wei branch large blocked",
        "[PASS] NPU model SDK helper set wei branch lower blocked",
        "[PASS] NPU model SDK helper set wei branch no patch blocked",
        "[PASS] NPU model SDK helper patch previous owner flag",
        "[PASS] NPU model SDK helper patch owner general",
        "[PASS] NPU model SDK helper patch owner dsp",
        "[PASS] NPU model SDK helper patch owner tflite",
        "[PASS] NPU model SDK helper patch dispatch",
        "[PASS] NPU model SDK helper patch dispatch dsp tflite",
        "[PASS] NPU model SDK helper patch search valid",
        "[PASS] NPU model SDK helper patch metadata general",
        "[PASS] NPU model SDK helper patch metadata apply general",
        "[PASS] NPU model SDK helper patch metadata dsp",
        "[PASS] NPU model SDK helper patch metadata apply dsp",
        "[PASS] NPU model SDK helper patch metadata tflite",
        "[PASS] NPU model SDK helper patch metadata apply tflite",
        "[PASS] NPU model SDK helper patch metadata apply blocked",
        "[PASS] NPU model SDK helper patch apply valid",
        "[PASS] NPU model SDK helper patch search start overflow",
        "[PASS] NPU model SDK helper conv stream",
        "[PASS] NPU model SDK helper conv resources",
        "[PASS] NPU model SDK helper conv transfer",
        "[PASS] NPU model SDK helper conv weight plan",
        "[PASS] NPU model SDK helper conv weights materialized",
        "[PASS] NPU model SDK helper conv run config",
        "[PASS] NPU model TFLite configured workspace oracle exec block",
        "[PASS] NPU model TFLite configured workspace oracle exec fixture block",
        "[PASS] NPU model TFLite configured workspace oracle readiness exec",
        "[PASS] NPU model TFLite configured workspace oracle exec terminal",
        "[PASS] NPU model TFLite configured workspace oracle exec top terminal",
        "[PASS] NPU model TFLite configured workspace oracle output readiness exec",
        "[PASS] NPU model TFLite configured workspace oracle equivalence exec",
        "[PASS] NPU model fixed configured workspace oracle exec block",
        "[PASS] NPU model fixed configured workspace oracle exec fixture block",
        "[PASS] NPU model fixed configured workspace oracle readiness exec",
        "[PASS] NPU model fixed configured workspace oracle exec terminal",
        "[PASS] NPU model fixed configured workspace oracle exec top terminal",
        "[PASS] NPU model fixed configured workspace oracle output readiness exec",
        "[PASS] NPU model fixed configured workspace oracle equivalence exec",
        "[PASS] NPU model TFLite workspace oracle into equal",
        "[PASS] NPU model TFLite workspace oracle valid",
        "[PASS] NPU model TFLite workspace oracle first block",
        "[PASS] NPU model TFLite workspace oracle reference block",
        "[PASS] NPU model TFLite workspace oracle fixture block",
        "[PASS] NPU model TFLite workspace oracle mismatches",
        "[PASS] NPU model TFLite workspace oracle readiness valid",
        "[PASS] NPU model TFLite workspace oracle output readiness valid",
        "[PASS] NPU model TFLite workspace raw projection valid",
        "[PASS] NPU model TFLite workspace raw compare valid",
        "[PASS] NPU model TFLite workspace raw projection short blocked",
        "[PASS] NPU model TFLite workspace raw mismatch diagnosed",
        "[PASS] NPU model TFLite workspace oracle address composed valid",
        "[PASS] NPU model TFLite workspace oracle address composed first block",
        "[PASS] NPU model TFLite workspace oracle address projection block",
        "[PASS] NPU model TFLite workspace oracle address validation block",
        "[PASS] NPU model TFLite workspace oracle address readiness valid",
        "[PASS] NPU model TFLite workspace oracle address output readiness valid",
        "[PASS] NPU model TFLite workspace oracle address mismatch readiness",
        "[PASS] NPU model TFLite workspace oracle address readiness expected",
        "[PASS] NPU model TFLite workspace oracle address readiness actual",
        "[PASS] NPU model TFLite workspace oracle address readiness mismatch fields",
        "[PASS] NPU model TFLite workspace oracle address output readiness mismatch",
        "[PASS] NPU model TFLite workspace oracle address short block",
        "[PASS] NPU model TFLite workspace oracle address readiness short",
        "[PASS] NPU model TFLite workspace oracle address output readiness short",
        "[PASS] NPU model fixed workspace oracle into equal",
        "[PASS] NPU model fixed workspace oracle valid",
        "[PASS] NPU model fixed workspace oracle first block",
        "[PASS] NPU model fixed workspace oracle reference block",
        "[PASS] NPU model fixed workspace oracle fixture block",
        "[PASS] NPU model fixed workspace oracle mismatches",
        "[PASS] NPU model fixed workspace oracle readiness valid",
        "[PASS] NPU model fixed workspace oracle output readiness valid",
        "[PASS] NPU model fixed workspace oracle address output readiness valid",
        "[PASS] NPU model fixed workspace oracle address mismatch readiness",
        "[PASS] NPU model fixed workspace oracle address readiness expected",
        "[PASS] NPU model fixed workspace oracle address readiness actual",
        "[PASS] NPU model fixed workspace oracle address readiness mismatch fields",
        "[PASS] NPU model fixed workspace oracle address output readiness mismatch",
        "[PASS] NPU model fixed workspace oracle address output readiness short",
        "[PASS] NPU model fixed workspace raw compare into equal",
        "[PASS] NPU model fixed workspace raw compare valid",
        "[PASS] NPU model fixed workspace raw compare first block",
        "[PASS] NPU model fixed workspace raw compare projection block",
        "[PASS] NPU model fixed workspace raw compare mismatches",
        "[PASS] NPU model fixed workspace raw compare short block",
        "[PASS] NPU model fixed workspace raw compare short expected",
        "[PASS] NPU model fixed workspace raw compare short output",
        "[PASS] NPU model fixed workspace raw compare short trailing",
        "[PASS] NPU model fixed raw byte negative value",
        "[PASS] NPU model fixed raw byte negative block",
        "[PASS] NPU model fixed raw byte negative compare",
        "[PASS] NPU model fixed raw byte mismatch block",
        "[PASS] NPU model fixed raw byte mismatch expected",
        "[PASS] NPU model fixed raw byte mismatch actual",
        "[PASS] NPU model fixed raw byte mismatch index",
        "[PASS] NPU model fixed raw byte mismatch top expected",
        "[PASS] NPU model fixed raw byte mismatch top actual",
        "[PASS] NPU model fixed raw byte trailing block",
        "[PASS] NPU model fixed raw byte trailing count",
        "[PASS] NPU model fixed raw byte trailing index",
        "[PASS] NPU model configured output validation blocked execution",
        "[PASS] NPU model output validation blocked compare",
        "[PASS] NPU model output validation mismatch index",
        "[PASS] NPU model output validation mismatch expected",
        "[PASS] NPU model output validation mismatch actual",
        "[PASS] NPU model output validation mismatch direct",
        "[PASS] NPU model output validation mismatch readiness",
        "[PASS] NPU model tensor output short blocked",
        "[PASS] NPU model tensor output short required",
        "[PASS] NPU model tensor output short provided",
        "[PASS] NPU model output validation blocked readback",
        "[PASS] NPU model smoke complete",
    ):
        assert marker in required or marker in required_any

    for marker in ("[FAIL]", "[FAULT]", "panic", "trap_entry", "fatal:"):
        assert marker in forbidden


def test_npu_parse_smoke_manifest_requires_focused_parser_markers():
    manifest = _manifest()
    test = {item["name"]: item for item in manifest["tests"]}["m0_npu_parse_smoke_test"]
    required = test.get("required", [])
    forbidden = manifest.get("defaults", {}).get("forbidden", []) + test.get("forbidden", [])

    assert "full" in test.get("tiers", [])
    assert test["build"] == [
        {
            "id": "kernel",
            "core": "bl808m0",
            "source": "examples/m0_npu_parse_smoke_test.nim",
            "flash": "m0",
        }
    ]
    for marker in (
        "=== BL808 NPU Parse Smoke Test ===",
        "[PASS] NPU parse base complete",
        "[PASS] NPU parse base multiplier bits",
        "[PASS] NPU parse bit reinterpret signed",
        "[PASS] NPU parse base route multiplier",
        "[PASS] NPU parse net params tflite",
        "[PASS] NPU parse yolo sidecar active",
        "[PASS] NPU parse yolo bias",
        "[PASS] NPU parse extra basic unsupported kind",
        "[PASS] NPU parse extra sidecar active",
        "[PASS] NPU parse extra quant2 multiplier",
        "[PASS] NPU parse extra high complete",
        "[PASS] NPU parse extra high route7 channels",
        "[PASS] NPU parse extra high quant7 multiplier",
        "[PASS] NPU parse float input scale",
        "[PASS] NPU parse ssd input3 scale",
        "[PASS] NPU parse dispatch state route",
        "[PASS] NPU parse eligibility state sidecars preserved",
        "[PASS] NPU parse encoded state ready",
        "[PASS] NPU parse eligibility state odd stride reason",
        "[PASS] NPU parse forward blocked not ready",
        "[PASS] NPU parse forward ready",
        "[PASS] NPU parse forward plan workspace",
        "[PASS] NPU parse forward execute ready",
        "[PASS] NPU parse forward short workspace blocked",
        "[PASS] NPU parse release complete",
        "[PASS] NPU parse release stale counters reset",
        "[PASS] NPU parse release state complete",
        "[PASS] NPU parse release state sidecar preserved",
        "[PASS] NPU parse release state graph three",
        "[PASS] NPU parse release overflow first",
        "[PASS] NPU parse shape transpose updated",
        "[PASS] NPU parse shape transpose block",
        "[PASS] NPU parse shape state transpose updated",
        "[PASS] NPU parse shape state sidecar preserved",
        "[PASS] NPU parse shape transposelk updated",
        "[PASS] NPU parse shape transposelk block",
        "[PASS] NPU parse shape pad updated",
        "[PASS] NPU parse shape pad block",
        "[PASS] NPU parse shape state pad updated",
        "[PASS] NPU parse shape state yolo preserved",
        "[PASS] NPU parse shape pad no bias reason",
        "[PASS] NPU parse shape pad invalid fit",
        "[PASS] NPU parse shape pad invalid reason",
        "[PASS] NPU parse shape unsupported blocked",
        "[PASS] NPU parse shape unsupported reason",
        "[PASS] NPU parse shape transposelk invalid reason",
        "[PASS] NPU parse execute preencoded",
        "[PASS] NPU parse execute readiness",
        "[PASS] NPU parse execute resource layers",
        "[PASS] NPU parse execute layer count",
        "[PASS] NPU parse execute stale blocked",
        "[PASS] NPU parse execute stale reason",
        "[PASS] NPU parse execute complete",
        "[PASS] NPU parse execute weight cursor",
        "[PASS] NPU parse execute state preencoded",
        "[PASS] NPU parse execute state complete",
        "[PASS] NPU parse execute state stale blocked",
        "[PASS] NPU parse execute state stale reason",
        "[PASS] NPU parse execute missing blocked",
        "[PASS] NPU parse execute short workspace blocked",
        "[PASS] NPU parse encode allocator fits",
        "[PASS] NPU parse encode allocator encoded",
        "[PASS] NPU parse encode allocator multiplier",
        "[PASS] NPU parse encode allocator fail blocked",
        "[PASS] NPU parse encode allocator fail branch",
        "[PASS] NPU parse operands second input c2",
        "[PASS] NPU parse operands combo flat guard",
        "[PASS] NPU parse operands combo line extra",
        "[PASS] NPU parse instruction bundle count",
        "[PASS] NPU parse instruction encode tflite first",
        "[PASS] NPU parse instruction encode short preserved",
        "[PASS] NPU parse allocator high branch",
        "[PASS] NPU parse allocator high ctrl size",
        "[PASS] NPU parse allocator psram branch",
        "[PASS] NPU parse allocator psram pressure",
        "[PASS] NPU parse allocator psram ctrl size",
        "[PASS] NPU parse allocator route line fits",
        "[PASS] NPU parse allocator route line start",
        "[PASS] NPU parse allocator route line ctrl last",
        "[PASS] NPU parse fetch growth fits",
        "[PASS] NPU parse fetch growth attempts",
        "[PASS] NPU parse fetch growth count",
        "[PASS] NPU parse smoke complete",
    ):
        assert marker in required

    for marker in ("[FAIL]", "[FAULT]", "panic", "trap_entry", "fatal:"):
        assert marker in forbidden


def test_npu_make_target_probes_anchor_before_existing_anchor_flash():
    makefile = MAKEFILE.read_text(encoding="utf-8")
    target = makefile.split("hw-npu-smoke-anchor: venv", 1)[1].split("\nhw-", 1)[0]

    probe = "--uart-anchor-probe"
    install = "--test m0_uart_flash_anchor --uart-anchor-flash"
    smoke = "--test m0_npu_smoke_test --uart-anchor-flash --uart-anchor-existing"
    route_smoke = "--test m0_npu_route_smoke_test --uart-anchor-flash --uart-anchor-existing"
    model_smoke = "--test m0_npu_model_smoke_test --uart-anchor-flash --uart-anchor-existing"
    parse_smoke = "--test m0_npu_parse_smoke_test --uart-anchor-flash --uart-anchor-existing"

    assert probe in target
    assert install in target
    assert smoke in target
    assert route_smoke in target
    assert model_smoke in target
    assert parse_smoke in target
    assert (
        target.index(probe)
        < target.index(install)
        < target.index(smoke)
        < target.index(route_smoke)
        < target.index(model_smoke)
        < target.index(parse_smoke)
    )
    assert target.count("--uart-anchor-runtime-jtag") >= 5
    assert target.count("--jtag-memory-log") >= 4


def test_d0_npu_start_probe_manifest_requires_two_image_d0_launch_markers():
    manifest = _manifest()
    test = {item["name"]: item for item in manifest["tests"]}["d0_npu_start_probe"]
    required = test.get("required", [])
    forbidden = manifest.get("defaults", {}).get("forbidden", []) + test.get("forbidden", [])

    assert "full" in test.get("tiers", [])
    assert test["build"] == [
        {
            "id": "kernel",
            "core": "bl808m0",
            "source": "examples/m0_d0_npu_start_probe.nim",
            "flash": "m0",
        },
        {
            "id": "d0",
            "core": "bl808d0",
            "source": "examples/d0_npu_start_probe.nim",
            "flash": "d0",
        },
    ]
    for marker in (
        "=== BL808 D0 NPU Start Probe ===",
        "[PASS] D0 NPU probe started",
        "[PASS] D0 NPU probe buffers ready",
        "[PASS] D0 NPU probe configured",
        "[PASS] D0 NPU probe start attempted",
        "[PASS] D0 NPU probe command idle sampled",
        "[PASS] D0 NPU probe bus decode clean",
        "[PASS] D0 NPU probe output moved",
        "[PASS] D0 NPU start probe complete",
        "[PASS] D0 NPU typed status evidence",
        "[PASS] D0 NPU typed output movement",
        "[PASS] D0 NPU typed model output still unvalidated",
        "[PASS] D0 NPU typed movement without oracle",
        "[PASS] D0 NPU IRQ binding ready",
        "[PASS] D0 NPU IRQ binding applied",
        "[PASS] D0 NPU typed probe stream decoded",
        "[PASS] D0 NPU probe terminal end bit decoded",
        "[PASS] D0 NPU output moved without completion edge",
        "[PASS] D0 NPU active-weight experiment classified",
        "[PASS] D0 NPU active-weight experiment moved DATA",
        "=== Test Complete ===",
    ):
        assert marker in required

    for marker in ("[FAIL]", "[FAULT]", "panic", "trap_entry", "fatal:"):
        assert marker in forbidden


def test_m0_npu_start_probe_manifest_requires_synthetic_route_markers():
    manifest = _manifest()
    test = {item["name"]: item for item in manifest["tests"]}["m0_npu_start_probe"]
    required = test.get("required", [])
    forbidden = manifest.get("defaults", {}).get("forbidden", []) + test.get("forbidden", [])

    assert "full" in test.get("tiers", [])
    assert test["build"] == [
        {
            "id": "kernel",
            "core": "bl808m0",
            "source": "examples/m0_npu_start_probe.nim",
            "flash": "m0",
        }
    ]
    for marker in (
        "=== BL808 M0 NPU Start Probe ===",
        "[PASS] M0 NPU probe buffers ready",
        "[PASS] M0 NPU SDK D0 boot clock control decoded",
        "[PASS] M0 NPU SDK D0 boot clock control plan decoded",
        "[PASS] M0 NPU SDK D0 boot VRAM route decoded",
        "[PASS] M0 NPU probe configured",
        "[PASS] M0 NPU synthetic stream decoded",
        "[PASS] M0 NPU synthetic terminal end bit",
        "[PASS] M0 NPU probe start attempted",
        "[PASS] M0 NPU probe input coherent",
        "[PASS] M0 NPU probe command status decoded",
        "[PASS] M0 NPU probe bus decode clean",
        "[PASS] M0 NPU synthetic D0 route contrast classified",
        "[PASS] M0 NPU synthetic active-weight stream gated DATA",
        "[PASS] M0 NPU synthetic address projection ready",
        "[PASS] M0 NPU projected probe configured",
        "[PASS] M0 NPU projected probe start attempted",
        "[PASS] M0 NPU projected probe input coherent",
        "[PASS] M0 NPU projected probe command status decoded",
        "[PASS] M0 NPU projected probe bus decode clean",
        "[PASS] M0 NPU synthetic address alias contrast classified",
        "[PASS] M0 NPU projected synthetic stream gated DATA",
        "[PASS] M0 NPU DRAM probe buffers ready",
        "[PASS] M0 NPU DRAM probe configured",
        "[PASS] M0 NPU DRAM probe start attempted",
        "[PASS] M0 NPU DRAM probe input coherent",
        "[PASS] M0 NPU DRAM probe command status decoded",
        "[PASS] M0 NPU DRAM probe bus decode clean",
        "[PASS] M0 NPU DRAM completion surface classified",
        "[PASS] M0 NPU synthetic DRAM contrast classified",
        "[PASS] M0 NPU forced IRQ binding applied",
        "[PASS] M0 NPU forced IRQ DRAM probe configured",
        "[PASS] M0 NPU forced IRQ DRAM probe start attempted",
        "[PASS] M0 NPU forced IRQ DRAM probe input coherent",
        "[PASS] M0 NPU forced IRQ DRAM probe command status decoded",
        "[PASS] M0 NPU forced IRQ DRAM probe bus decode clean",
        "[PASS] M0 NPU forced IRQ DRAM contrast classified",
        "[PASS] M0 NPU D0 boot clock control applied",
        "[PASS] M0 NPU D0 boot clock DRAM probe configured",
        "[PASS] M0 NPU D0 boot clock DRAM probe start attempted",
        "[PASS] M0 NPU D0 boot clock DRAM probe input coherent",
        "[PASS] M0 NPU D0 boot clock DRAM probe command status decoded",
        "[PASS] M0 NPU D0 boot clock DRAM probe bus decode clean",
        "[PASS] M0 NPU D0 boot clock DRAM contrast classified",
        "[PASS] M0 NPU D0 boot VRAM route applied",
        "[PASS] M0 NPU D0 boot VRAM route DRAM configuration sampled",
        "[PASS] M0 NPU D0 boot VRAM route DRAM configuration blocked",
        "[PASS] M0 NPU start probe complete",
        "=== Test Complete ===",
    ):
        assert marker in required

    for marker in ("[FAIL]", "[FAULT]", "panic", "trap_entry", "fatal:"):
        assert marker in forbidden


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
        "m0_ble_wifi_nim_coex_hal_test",
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
    assert "[PASS] lwIP WASM HTTP install/invoke/delete" in required
    assert "[PASS] lwIP UDP echo bytes=" in required
    assert "[PASS] lwIP HTTP diagnostics reflect UDP RX/TX" in required
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
    assert "[PASS] lwIP WASM HTTP install/invoke/delete" in host.get("required", [])
    assert "[PASS] lwIP UDP echo bytes=" in host.get("required", [])
    assert "[PASS] lwIP HTTP diagnostics reflect UDP RX/TX" in host.get("required", [])

    example = (REPO_ROOT / "examples/m0_wifi_http_server.nim").read_text()
    probe = (REPO_ROOT / "tools/probe_wifi_lwip_tcp_udp.py").read_text()
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
        "handleWasmHttpBytes(",
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

    for expected in [
        "def parse_http_diagnostics(response: str) -> dict[str, str]:",
        "diagnostics = parse_http_diagnostics(response)",
        "response_after_udp = tcp_http_probe(host, args.http_port, args.timeout)",
        'require_int_at_least(diagnostics_after_udp, "http_requests", 2)',
        'require_int_at_least(diagnostics_after_udp, "udp_rx_packets", 1)',
        'require_int_at_least(diagnostics_after_udp, "udp_tx_packets", 1)',
        '"[PASS] lwIP HTTP diagnostics reflect UDP RX/TX"',
    ]:
        assert expected in probe


def test_wifi_validation_targets_do_not_pin_scan_channel():
    manifest_text = MANIFEST.read_text()
    assert "BL808_WIFI_CHANNEL" not in manifest_text

    for name, test in _tests_by_name().items():
        defines = _all_defines(test)
        assert "WifiChannel" not in defines, name


def test_wasm_sd_store_target_exercises_exfat_repository_workflow():
    test = _tests_by_name()["m0_wasm_sd_store_test"]
    required = test.get("required", [])
    assert "[PASS] WASM program saved to SD" in required
    assert "[PASS] WASM program listed on SD" in required
    assert "[PASS] WASM program installed from SD" in required
    assert "[PASS] WASM program invoked from SD-installed slot" in required
    assert "[PASS] HTTP saved WASM program to SD repository" in required
    assert "[PASS] HTTP listed SD WASM repository" in required
    assert "[PASS] HTTP installed SD WASM program into flash slot" in required
    assert "[PASS] HTTP invoked SD-installed WASM program" in required
    assert "[PASS] HTTP deleted WASM program from SD repository" in required

    example = (REPO_ROOT / "examples/m0_wasm_sd_store_test.nim").read_text()
    for expected in [
        "saveWasmProgramToSd(",
        "listWasmProgramsOnSd(",
        "installWasmProgramFromSd(",
        "runWasmProgramI32(",
        '"/wasm/repository/"',
        '"/wasm/programs/2/invoke/add"',
    ]:
        assert expected in example

    http = (REPO_ROOT / "src/bl808/wasm_http.nim").read_text()
    for expected in [
        'RepositoryPath = "/wasm/repository"',
        "proc parseRepositoryPath",
        "proc parseRepositoryInstallPath",
        "saveWasmProgramToSd(",
        "installNamedWasmProgramFromSd(",
        "deleteWasmProgramFromSd(",
    ]:
        assert expected in http

    sd_store = (REPO_ROOT / "src/bl808/wasm_sd_store.nim").read_text()
    for expected in [
        'WasmSdProgramDir* = "0:/programs"',
        "proc validWasmSdName*",
        "proc saveWasmProgramToSd*",
        "proc listWasmProgramsOnSd*",
        "proc installNamedWasmProgramFromSd*",
        "proc installWasmProgramFromSdStreamed*",
        "flashWrite(programSlot.flashOffset + WasmProgramHeaderLen + offset",
        "parseFlashWasmModule(",
    ]:
        assert expected in sd_store


def test_wasm_manager_target_exposes_runtime_capabilities():
    test = _tests_by_name()["m0_wasm_manager_test"]
    defines = _all_defines(test)
    assert defines.get("bl808WasmCompact") == "1"
    required = test.get("required", [])
    assert "[PASS] manager runtime capabilities exposed" in required
    assert "[PASS] http adapter exposed WASM capabilities" in required

    runtime = (REPO_ROOT / "src/bl808/wasm_runtime.nim").read_text()
    for expected in [
        "WasmRuntimeCapabilities*",
        "proc wasmRuntimeCapabilities*",
        "proc wasmRuntimeCapabilityWord*",
        "softwareF32*",
        "supportsF64*",
    ]:
        assert expected in runtime

    http = (REPO_ROOT / "src/bl808/wasm_http.nim").read_text()
    for expected in [
        'CapabilitiesPath = "/wasm/capabilities"',
        "proc capabilitiesResponse()",
        "wasmRuntimeCapabilities()",
    ]:
        assert expected in http

    example = (REPO_ROOT / "examples/m0_wasm_manager_test.nim").read_text()
    scheduler_smoke = (REPO_ROOT / "src/bl808/wasm_scheduler_smoke.nim").read_text()
    for expected in [
        "let caps = wasmRuntimeCapabilities()",
        "caps.core != wasmCoreM0",
        '"/wasm/capabilities"',
        "runWasmSchedulerSmoke",
        '"/wasm/programs/4/start/add"',
        '"/wasm/tasks/run"',
        '"/wasm/tasks"',
    ]:
        assert expected in example
    for expected in [
        "WasmSchedulerSmokeQuotaFailed",
        "WasmSchedulerSmokeBlockFailed",
        "wasmSchedQuotaExceeded",
        "wasmTaskBlockedSd",
    ]:
        assert expected in scheduler_smoke

    test = _tests_by_name()["m0_wasm_manager_test"]
    required = test.get("required", [])
    assert "[PASS] manager scheduled WASM tasks cooperatively" in required
    assert "[PASS] http adapter started WASM task" in required
    assert "[PASS] http adapter ran WASM scheduler" in required
    assert "[PASS] http adapter listed WASM tasks" in required


def test_wasm_cps_scheduler_target_prevents_runtime_starvation():
    test = _tests_by_name()["m0_wasm_cps_scheduler_test"]
    defines = _all_defines(test)
    assert defines.get("bl808WasmCompact") == "1"
    required = test.get("required", [])
    assert "[PASS] CPS WASM program installed" in required
    assert "[PASS] CPS drove WASM task without starving scheduler" in required
    assert "[PASS] CPS WASM quota trap surfaced" in required

    cps_runner = (REPO_ROOT / "src/bl808/wasm_cps.nim").read_text()
    for expected in [
        "proc runWasmTaskCps*",
        "await yieldNow()",
        "resumeWasmProgramTask",
        "CpsFuture[WasmControlTaskResult]",
        "return await runWasmTaskCps",
    ]:
        assert expected in cps_runner

    example = (REPO_ROOT / "examples/m0_wasm_cps_scheduler_test.nim").read_text()
    for expected in [
        "import bl808/kernel/cps",
        "heartbeatTask",
        "startAndRunWasmProgramTaskCps",
        "heartbeatTicks < 4'u32",
        "runScheduler()",
    ]:
        assert expected in example


def test_cross_core_wasm_smokes_expose_runtime_capability_profiles():
    tests = _tests_by_name()
    glb = (REPO_ROOT / "src/bl808/glb.nim").read_text()
    assert "D0FlashCopyBytes* = 256'u * 1024'u" in glb

    m0 = tests["m0_wasm_smoke_test"]
    assert "[PASS] M0 WASM runtime capabilities match M0 profile" in m0.get("required", [])
    assert "[PASS] M0 WASM task context switching smoke passed" in m0.get("required", [])
    m0_example = (REPO_ROOT / "examples/m0_wasm_smoke_test.nim").read_text()
    for expected in [
        "ExpectedM0WasmCaps",
        "wasmCoreM0",
        "wasmRuntimeCapabilityWord()",
        "runWasmTaskSmoke()",
    ]:
        assert expected in m0_example

    d0 = tests["d0_wasm_smoke_test"]
    assert "[PASS] D0 WASM runtime capabilities match D0 profile" in d0.get("required", [])
    assert "[PASS] D0 WASM task context switching smoke passed" in d0.get("required", [])
    d0_helper = (REPO_ROOT / "examples/m0_d0_wasm_smoke_test.nim").read_text()
    d0_worker = (REPO_ROOT / "examples/d0_wasm_smoke_test.nim").read_text()
    for expected in [
        "D0WasmCapsAddr",
        "D0WasmTaskStatusAddr",
        "ExpectedD0WasmCaps",
        "wasmCoreD0",
        "wasmRuntimeCapabilityWord()",
        "runWasmTaskSmoke()",
    ]:
        assert expected in d0_helper or expected in d0_worker

    lp = tests["lp_wasm_smoke_test"]
    assert "[PASS] LP WASM runtime capabilities match LP compact profile" in lp.get("required", [])
    assert "[PASS] LP WASM task context switching smoke passed" in lp.get("required", [])
    assert lp.get("jtag_flash_chunk_size") == 1024
    lp_helper = (REPO_ROOT / "examples/m0_lp_wasm_smoke_test.nim").read_text()
    lp_worker = (REPO_ROOT / "examples/lp_wasm_smoke_test.nim").read_text()
    for expected in [
        "LpWasmCapsAddr",
        "LpWasmTaskStatusAddr",
        "ExpectedLpWasmCaps",
        "wasmCoreLP",
        "wasmRuntimeCapabilityWord()",
        "runWasmTaskSmoke()",
    ]:
        assert expected in lp_helper or expected in lp_worker


def test_enclave_wasm_smoke_exercises_task_context_switching():
    tests = _tests_by_name()
    test = tests["m0_enclave_wasm_smoke_test"]
    assert "[PASS] enclave WASM task context switching smoke passed" in test.get("required", [])

    example = (REPO_ROOT / "examples/m0_enclave_wasm_smoke_test.nim").read_text()
    for expected in [
        "import bl808/wasm_task_smoke",
        "runWasmTaskSmoke()",
        "WasmTaskSmokeOk",
    ]:
        assert expected in example


def test_allcore_wasm_slot_smoke_requires_compact_runtime_profiles():
    test = _tests_by_name()["allcore_wasm_slot_smoke_test"]
    required = test.get("required", [])
    assert "[PASS] M0 WASM slot runtime capabilities match compact profile" in required
    assert "[PASS] M0 invoked shared WASM slot" in required
    assert "[PASS] D0 WASM slot runtime capabilities match compact profile" in required
    assert "[PASS] LP WASM slot runtime capabilities match compact profile" in required
    for build in test.get("build", []):
        if build.get("core") in {"bl808d0", "bl808lp"}:
            assert build.get("defines", {}).get("bl808WasmCompact") == "1"

    example = (REPO_ROOT / "examples/m0_allcore_wasm_slot_smoke_test.nim").read_text()
    for expected in [
        "ExpectedM0CompactCaps",
        "ExpectedD0CompactCaps",
        "ExpectedLpCompactCaps",
        "runWasmSlotSmoke()",
        "WasmSlotD0CapsAddr",
        "WasmSlotLpCapsAddr",
    ]:
        assert expected in example


def test_allcore_wasm_cps_live_target_exercises_all_cores_and_enclave():
    test = _tests_by_name()["allcore_wasm_cps_live_test"]
    required = test.get("required", [])
    for expected in [
        "[PASS] M0 executed multiple WASM programs under CPS",
        "[PASS] enclave executed multiple WASM programs under CPS load",
        "[PASS] D0 executed multiple WASM programs under CPS",
        "[PASS] LP executed multiple WASM programs under CPS",
    ]:
        assert expected in required
    assert test.get("jtag_flash_chunk_size") == 1024

    defines = _all_defines(test)
    assert defines.get("bl808WasmCompact") == "1"
    assert defines.get("bl808enclave") == "true"

    m0 = (REPO_ROOT / "examples/m0_allcore_wasm_cps_live_test.nim").read_text()
    d0 = (REPO_ROOT / "examples/d0_wasm_cps_live_worker.nim").read_text()
    lp = (REPO_ROOT / "examples/lp_wasm_cps_live_worker.nim").read_text()
    for expected in [
        "startAndRunWasmProgramTaskCps",
        "heartbeatTask",
        "svcWasmTaskStartI32",
        "svcWasmInvokeI32",
        "releaseD0()",
        "releaseLPAt(LpWramBootGateAddr)",
        "pdsSetLpL1cRange(FlashXipBase + Ox64LPBootOffset",
        "pdsDisableLpL1c()",
        "sfCtrlSetLpImageOffsetToGroup1()",
        "sfCtrlRestoreXip()",
        "writeWasmSlotInvokeRequest(WasmSlotD0RequestAddr",
        "writeWasmSlotInvokeRequest(WasmSlotLpRequestAddr",
        "regWrite(WasmLiveLpStartAddr, WasmLiveLpStartMagic)",
        "await m0Task",
        "await enclaveTask",
        "await d0Task",
        "await lpTask",
    ]:
        assert expected in m0
    for source in [d0, lp]:
        assert "import bl808/kernel/cps" in source
        assert "startAndRunWasmProgramTaskCps" in source
        assert "heartbeatTask" in source
        assert "runScheduler()" in source
    assert "WasmLiveLpStartMagic" in lp

    partition = (REPO_ROOT / "src/bl808/enclave/partition.nim").read_text()
    for expected in [
        "import ../mmio, ../memmap, ../tzc, ../pmp, ../flash_layout",
        "let lpRaw = lpRuntimeMappedFlashSpan()",
        "let wasmMcuXip = peerMcuXipFlashSpan()",
        "let wasmRaw = wasmRepositoryRawFlashSpan()",
        "let lpFlash = lpRuntimeXipSpan()",
        "tzcConfigureWindowRegion(tzcWinSf, 0",
        "tzcConfigureWindowRegion(tzcWinSf, 1",
        "tzcConfigureWindowRegion(tzcWinSf, 2",
        "tzcConfigureWindowRegion(tzcWinSf, 3",
        "tzcSetSfCtrlGroups(tzcSfCr, {0.TzcAuthGroup, 1.TzcAuthGroup}",
        "tzcSetSfCtrlGroups(tzcSfSec, {0.TzcAuthGroup, 1.TzcAuthGroup}",
        "tzcSetSfCtrlModeArb(lock = p.lock)",
        "tzcSetNsecSfCtrlModeArb(lock = p.lock)",
        "tzcSetNsecMasterGroup(m, 0, lock = p.lock)",
        "{0.TzcAuthGroup, 1.TzcAuthGroup}",
    ]:
        assert expected in partition
    flash = (REPO_ROOT / "src/bl808/flash.nim").read_text()
    assert "import mmio, memmap, flash_layout" in flash
    assert "when defined(bl808d0) or defined(bl808lp):" in flash
    assert "regRead(SfCtrlImageOffset1)" in flash
    assert "flashXipAddrForCore(offset, mappedOffset)" in flash
    assert "LpRuntimeFlashOffset - Ox64LPBootOffset.uint32" in flash
    flash_layout = (REPO_ROOT / "src/bl808/flash_layout.nim").read_text()
    for expected in [
        "WasmRepositoryFlashOffset* = Ox64WasmStoreOffset.uint32",
        "McuXipAliasBase* = FlashXipBase",
        "D0XipAliasBase* = FlashXipBase",
        "D0FlashRemapAliasBase* = FlashRemapBase",
        "LpRuntimeFlashOffset* = 0x0C_0000'u32",
        "LpRuntimeFlashLen* = (Ox64D0BootOffset - LpRuntimeFlashOffset.uint).uint32",
        "proc flashXipAddrForCore*",
        "if offset >= mappedOffset:",
        "flashXipBaseForCore() + uint(offset - mappedOffset)",
        "proc lpRuntimeFlashSpan*",
        "proc lpRuntimeMappedFlashSpan*",
        "proc lpRuntimeXipSpan*",
        "proc wasmRepositoryRawFlashSpan*",
        "proc peerMcuXipFlashSpan*",
        "proc peerD0WasmFlashSpan*",
    ]:
        assert expected in flash_layout

    probe = _tests_by_name()["allcore_wasm_cps_live_d0_flash_probe"]
    assert "D0_status=0x574C5607" in probe.get("required", [])
    probe_d0 = [b for b in probe.get("build", []) if b.get("core") == "bl808d0"][0]
    assert probe_d0.get("defines", {}).get("bl808LiveD0FlashProbeOnly") == "1"
    harness = (REPO_ROOT / "tools/hw_validate.py").read_text()
    assert "JTAG_FLASH_LP_OFFSET = 0x0C0000" in harness


def test_allcore_wasm_http_manager_keeps_enclave_and_validated_wifi_memory():
    test = _tests_by_name()["allcore_wasm_http_manager_test"]
    required = test.get("required", [])
    for expected in [
        "[PASS] enclave executed multiple WASM programs under CPS load",
        "[PASS] D0 executed multiple WASM programs under CPS",
        "[PASS] LP executed multiple WASM programs under CPS",
        "[M0] allcore_http_dhcp_observed_lease",
        "Ready for all-core WASM HTTP manager requests",
    ]:
        assert expected in required
    assert test.get("jtag_flash_chunk_size") == 1024

    defines = _all_defines(test)
    for name in [
        "bl808AllcoreWasmHttp",
        "bl808WasmCompact",
        "bl808WifiNimFw",
        "bl808WifiUseBl808Rf",
        "bl808WifiRealLwip",
        "bl808WifiRealLwipTcp",
        "bl808WifiRxPbufInput",
        "bl808WifiConnectCacheHint",
    ]:
        assert defines.get(name) == "1"
    assert defines.get("HwValidationLogExternalBuffer") == "1"
    assert defines.get("bl808WifiRfWb03AuthTxSettleUs") == "5000"
    assert defines.get("bl808enclave") == "true"
    assert defines.get("bl808EnclaveWram") == "true"
    assert defines.get("WifiSsid") == "Frog"
    assert defines.get("WifiPassword") == "6509171272"
    assert defines.get("StaticIpA") == "192"
    assert defines.get("StaticIpB") == "168"
    assert defines.get("StaticIpC") == "1"
    assert defines.get("StaticIpD") == "223"
    assert defines.get("StaticGatewayA") == "192"
    assert defines.get("StaticGatewayB") == "168"
    assert defines.get("StaticGatewayC") == "1"
    assert defines.get("StaticGatewayD") == "254"
    assert defines.get("StaticIpAfterDhcpAttempts") == "1"
    assert "WifiChannel" not in defines

    m0 = (REPO_ROOT / "examples/m0_allcore_wasm_cps_live_test.nim").read_text()
    linker = (REPO_ROOT / "src/linker/bl808_m0_allcore_http.ld").read_text()
    layout_types = (REPO_ROOT / "src/bl808/wifi/fw/layout_types.nim").read_text()
    for expected in [
        "initAllcoreHttpMemory()",
        "psramInit(psram64mb, psramBurst64)",
        "handleWasmCpsHttpTransport",
        "await enclaveTask",
        "holdD0Reset()",
        "holdLPReset()",
        "wifiInstallServiceHook",
        "await wifiScanAsync",
        "wifiConnectAsync(",
        "bl808WpaCurrentState()",
        "WpaCompletedState = 10'u32",
        "Ready for all-core WASM HTTP manager requests",
    ]:
        assert expected in m0
    assert "WifiChannel {.intdefine.} = 0" in m0
    assert "WifiChannel.uint8" in m0
    for expected in [
        "HEAP_RAM (rw)  : ORIGIN = 0x50000000",
        "WIFI_RAM (rw)  : ORIGIN = 0x22030000",
        ".wifirxram",
        "__wifi_rx_ram_start",
        "__wifi_rx_ram_end",
        ".psrambss",
        ".wifibss",
        "RAMFUNC  (rwx) : ORIGIN = 0x2204F000, LENGTH = 4K",
        "RAM      (rwx) : ORIGIN = 0x62020000, LENGTH = 56K",
        "_stack_size = 10K",
        "*(.jtaglog .jtaglog.*)",
        "__wifi_rx_ram_end <= __wifi_bss_end",
        "_ebss <= _sstack - 1024",
    ]:
        assert expected in linker
    assert "when defined(bl808AllcoreWasmHttp)" in layout_types
    assert 'section(\\".wifirxram\\")' in layout_types
    wifi_state = (REPO_ROOT / "src/bl808/wifi/support/state.nim").read_text()
    assert "section(\\\".psrambss\\\")" in wifi_state
    assert "var scanDiag {.allcoreHttpPsramBss.}" in wifi_state
    assert "var scanCache {.allcoreHttpPsramBss.}" in wifi_state
    partition = (REPO_ROOT / "src/bl808/enclave/partition.nim").read_text()
    for expected in [
        "lnkWifiBssStart()",
        "lnkWifiBssEnd()",
        "tzcConfigureWindowRegion(tzcWindowForCachedRam(lnkWifiBssStart()), 1",
        "lnkWifiRxRamStart()",
        "lnkWifiRxRamEnd()",
        "tzcConfigureWindowRegion(tzcWinWram, 1",
        "{tzcMasterM0, tzcMasterWifi, tzcMasterDma0, tzcMasterDma1}",
    ]:
        assert expected in partition
    tzc = (REPO_ROOT / "src/bl808/tzc.nim").read_text()
    assert "tzcWinPsramA" in tzc
    assert "TzcSecPsramACtrl" in tzc


def test_enclave_wasm_store_target_exercises_service_abi_contract():
    test = _tests_by_name()["m0_enclave_wasm_store_test"]
    required = test.get("required", [])
    assert "[PASS] report WASM runtime capabilities through enclave service" in required
    assert "[PASS] install WASM bytes through enclave service" in required
    assert "[PASS] invoke enclave-installed WASM slot" in required
    assert "[PASS] unload WASM slot through enclave service" in required
    assert "[PASS] invoke flash-backed WASM slot through enclave service" in required
    assert "[PASS] start WASM task through enclave service" in required
    assert "[PASS] resume WASM task through enclave service" in required
    assert "[PASS] report WASM task status through enclave service" in required
    assert "[PASS] reap WASM task through enclave service" in required
    assert "[PASS] reject malformed WASM enclave invoke request" in required
    assert "[PASS] report bad WASM slot through enclave service" in required
    assert "[PASS] seal flash-backed WASM result status" in required

    example = (REPO_ROOT / "examples/m0_enclave_wasm_store_test.nim").read_text()
    for expected in [
        "svcWasmInvokeI32",
        "svcWasmCapabilities",
        "svcWasmInstallBytes",
        "svcWasmUnloadSlot",
        "svcWasmTaskStartI32",
        "svcWasmTaskResume",
        "svcWasmTaskStatus",
        "svcWasmTaskKill",
        "rdU32(buf(), 36) != 0'u32",
        "rdU32(buf(), 40) != 0'u32",
        "testEnclaveWasmInstallInvokeUnload",
        "testEnclaveWasmTaskLifecycle",
        "testEnclaveWasmCapabilities",
        "testEnclaveWasmInvokeBadRequest",
        "testEnclaveWasmInvokeBadSlot",
        "svcBadRequest",
        "wasmControlBadSlot",
    ]:
        assert expected in example


def test_enclave_wasm_ecall_target_exercises_real_ecall_service():
    test = _tests_by_name()["m0_enclave_wasm_ecall_test"]
    defines = _all_defines(test)
    assert defines.get("bl808enclave") == "true"
    assert defines.get("bl808WasmCompact") == "true"
    required = test.get("required", [])
    assert "[PASS] installed WASM slot for U-mode ecall" in required
    assert "[PASS] U-mode invoked WASM through enclave ecall" in required
    assert "[PASS] U-mode managed WASM slot through enclave ecall" in required

    example = (REPO_ROOT / "examples/m0_enclave_wasm_ecall_test.nim").read_text()
    for expected in [
        "installWasmSlotSmoke()",
        "svcWasmCapabilities.uint32",
        "svcWasmInvokeI32.uint32",
        "svcWasmInstallBytes.uint32",
        "svcWasmUnloadSlot.uint32",
        "SvcReportManage",
        "wasmControlOk.ord.uint32",
        "callerUmodeAppCtx()",
        "enclaveRunUmode(umodeAppAddr())",
    ]:
        assert expected in example


def test_d0_enclave_wasm_ipc_target_exercises_peer_service_transport():
    test = _tests_by_name()["m0_d0_enclave_wasm_ipc_test"]
    builds = test.get("build", [])
    assert [b.get("core") for b in builds] == ["bl808m0", "bl808d0"]
    assert _all_defines(test).get("bl808enclave") == "true"
    required = test.get("required", [])
    assert "[PASS] D0 managed WASM through enclave IPC" in required

    m0 = (REPO_ROOT / "examples/m0_d0_enclave_wasm_ipc_test.nim").read_text()
    for expected in [
        "enclaveInit(defaultPartition(lock = true), rkSoftDev)",
        "enclaveIpcPoll()",
        "releaseD0()",
        "D0 managed WASM through enclave IPC",
    ]:
        assert expected in m0

    d0 = (REPO_ROOT / "examples/d0_enclave_wasm_ipc_client.nim").read_text()
    for expected in [
        "svcWasmCapabilities",
        "svcWasmInstallBytes",
        "svcWasmInvokeI32",
        "svcWasmUnloadSlot",
        "ipcSendMessage(ipcM0, SvcIpcTagBase + svc.uint16",
    ]:
        assert expected in d0


def test_lp_enclave_wasm_ipc_target_exercises_peer_service_transport():
    test = _tests_by_name()["m0_lp_enclave_wasm_ipc_test"]
    builds = test.get("build", [])
    assert [b.get("core") for b in builds] == ["bl808m0", "bl808lp"]
    assert _all_defines(test).get("bl808enclave") == "true"
    assert test.get("jtag_flash_chunk_size") == 1024
    required = test.get("required", [])
    assert "[PASS] LP managed WASM through enclave IPC" in required

    m0 = (REPO_ROOT / "examples/m0_lp_enclave_wasm_ipc_test.nim").read_text()
    for expected in [
        "enclaveInit(defaultPartition(lock = true), rkSoftDev)",
        "enclaveIpcPoll()",
        "releaseLP()",
        "LP managed WASM through enclave IPC",
    ]:
        assert expected in m0

    lp = (REPO_ROOT / "examples/lp_enclave_wasm_ipc_client.nim").read_text()
    for expected in [
        "svcWasmCapabilities",
        "svcWasmInstallBytes",
        "svcWasmInvokeI32",
        "svcWasmUnloadSlot",
        "sendM0RequestFast(SvcIpcTagBase + svc.uint16",
    ]:
        assert expected in lp


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
