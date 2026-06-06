"""Policy checks for BLE central validation defaults."""

from __future__ import annotations

import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_name_based_central_connect_rediscover_defaults_to_no_stale_retries():
    source = REPO_ROOT / "src" / "bl808" / "ble.nim"
    text = source.read_text(encoding="utf-8")

    assert "BleCentralPeerConnectRetries {.intdefine.}: int = 0" in text
    assert "rediscover by name after each failed attempt" in text


def test_macos_ble_helper_defaults_to_launchservices_with_bundle_override():
    source = REPO_ROOT / "tools" / "run_macos_ble_helper.py"
    text = source.read_text(encoding="utf-8")

    assert 'BUNDLE_ID = "dev.bl808hal.MacOSBLEHelper"' in text
    assert 'Path.home()' in text
    assert '/ "Library"' in text
    assert '/ "Application Support"' in text
    assert '/ "bl808-hal"' in text
    assert '/ "MacOSBLEHelper.app"' in text
    assert 'os.environ.get("BL808_MACOS_BLE_HELPER_LAUNCH", "open")' in text
    assert 'launch_with_open = launch_mode == "open"' in text
    assert "newest_mtime([SOURCE])" in text


def test_hardware_validation_host_actions_use_bundle_launch_by_default():
    source = REPO_ROOT / "tools" / "hw_validate.py"
    text = source.read_text(encoding="utf-8")

    assert 'env.setdefault("BL808_MACOS_BLE_HELPER_LAUNCH", "open")' in text
    assert 'env.setdefault("BL808_MACOS_BLE_HELPER_LAUNCH", "direct")' not in text


def test_legacy_python_ble_connect_uses_macos_helper_by_default():
    source = REPO_ROOT / "tools" / "ble_connect_validate.py"
    text = source.read_text(encoding="utf-8")

    assert "def should_use_macos_helper()" in text
    assert 'os.environ.get("BL808_BLE_CONNECT_VALIDATE_BACKEND", "")' in text
    assert 'return sys.platform == "darwin"' in text
    assert "def run_macos_helper(args: argparse.Namespace) -> int:" in text
    assert '"run_macos_ble_helper.py"' in text
    assert 'if should_use_macos_helper():' in text
    assert "return run_macos_helper(args)" in text


def test_onchip_hci_bridge_callback_is_module_level():
    source = REPO_ROOT / "src" / "bl808" / "ble.nim"
    text = source.read_text(encoding="utf-8")

    assert "proc bleHostBridge(pktType: uint8" in text
    init_body = text.split("proc bt_onchiphci_interface_init*", 1)[1].split(
        "proc bt_onchiphci_send*", 1
    )[0]
    assert "proc bridge(" not in init_body
    assert "bt_onchiphci_interface_init(bleHostBridge)" in init_body


def test_macos_ble_helper_starts_corebluetooth_after_app_runloop():
    source = REPO_ROOT / "tools" / "macos_ble_helper.swift"
    text = source.read_text(encoding="utf-8")

    assert "final class HelperAppDelegate" in text
    assert "applicationDidFinishLaunching" in text
    assert "func start()" in text
    assert "task.start()" in text
    assert "CBCentralManagerOptionShowPowerAlertKey" in text
    assert "CBPeripheralManagerOptionShowPowerAlertKey" in text


def test_macos_ble_helper_is_signed_with_bluetooth_entitlement_by_default():
    source = REPO_ROOT / "tools" / "run_macos_ble_helper.py"
    text = source.read_text(encoding="utf-8")

    entitlements_body = text.split("def expected_entitlements()", 1)[1].split(
        "def info_plist_matches", 1
    )[0]
    assert '"com.apple.security.device.bluetooth": True' in entitlements_body
    assert 'os.environ.get("BL808_MACOS_BLE_HELPER_SANDBOX"' in entitlements_body

    non_sandbox_branch = entitlements_body.split(
        'os.environ.get("BL808_MACOS_BLE_HELPER_SANDBOX"', 1
    )[1].split('entitlements["com.apple.security.app-sandbox"]', 1)[0]
    assert "return entitlements" in non_sandbox_branch


def test_reset_nim_controller_state_keeps_ready_ble_core_warm():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    reset_body = text.split("proc resetNimControllerState() =", 1)[1].split(
        "proc localAddrBytes", 1
    )[0]
    assert "let irqState = btbleIrqSave()" in reset_body
    assert "btbleIrqRestore(irqState)" in reset_body
    assert "quiesceM0PolledBleClicSources()" in reset_body
    assert "if nim_ble_core_ready:" in reset_body
    assert "writeBtbleInterruptMask(0)" in reset_body
    assert "nimDisableM0RfClicIrq()" in reset_body
    assert "resetBtbleAdvRxRing()" in reset_body
    assert "regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, 0xFFFFFFFF'u32)" in reset_body
    assert "else:\n    initBleCoreRegisters()" in reset_body


def test_hci_and_controller_reset_use_reference_rwip_reset_path():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    hci_reset_body = text.split("of HciOpReset:", 1)[1].split(
        "of HciOpDisconnect:", 1
    )[0]
    assert "rwip_reset()" in hci_reset_body
    assert "resetNimControllerState()" not in hci_reset_body
    assert "bleSettleAfterHciReset()" not in hci_reset_body

    controller_reset_body = text.split("proc ble_controller_reset*", 1)[1].split(
        "proc BTBLE_ROM_hook_init", 1
    )[0]
    assert "rwip_reset()" in controller_reset_body
    assert "bflbble_reset()" not in controller_reset_body

    rwip_reset_body = text.split("proc rwip_reset*", 1)[1].split(
        "proc rwip_isr", 1
    )[0]
    assert "let irqState = btbleIrqSave()" in rwip_reset_body
    assert "btbleIrqRestore(irqState)" in rwip_reset_body

    rwip_core_body = text.split("proc rwipResetCore() =", 1)[1].split(
        "proc rwip_reset", 1
    )[0]
    assert "ble_ke_flush()" in rwip_core_body
    assert rwip_core_body.index("hci_reset()") < rwip_core_body.index("bflbble_reset()")
    assert "bflbip_reset()" in rwip_core_body
    assert "ea_init()" in rwip_core_body
    assert "resetNimControllerState()" in rwip_core_body
    assert "bleSettleAfterHciReset()" in rwip_core_body


def test_m0_ble_reset_masks_rf_top_source_interrupts():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    init_body = text.split("proc bflbble_init*()", 1)[1].split(
        "proc bflbble_reset*()", 1
    )[0]
    reset_body = text.split("proc bflbble_reset*()", 1)[1].split(
        "proc bflbble_sleep_check*()", 1
    )[0]
    quiesce_body = text.split("proc quiesceM0PolledBleClicSources()", 1)[1].split(
        "proc btbleIrqSave", 1
    )[0]

    assert "nimDisableM0RfClicIrq()" in init_body
    assert "nimDisableM0RfClicIrq()" in reset_body
    assert "not bl808BleNimRuntimeClicIrq" in quiesce_body
    assert "nimDisableM0RfClicIrq()" in quiesce_body
    assert "nimDisableM0BleClicIrq()" in quiesce_body


def test_m0_startup_clears_stale_pds_wake_status_before_clic_init():
    source = REPO_ROOT / "src" / "bl808" / "startup.nim"
    text = source.read_text(encoding="utf-8")

    assert "when defined(bl808m0) or defined(bl808lp):\n  import pds" in text
    system_init = text.split("proc systemInit*() =", 1)[1]
    m0_branch = system_init.split("when defined(bl808m0):", 1)[1].split(
        "elif defined(bl808d0):", 1
    )[0]
    assert "pdsConfigureLpMtimerClock()" in m0_branch
    assert "pdsClearIrq()" in m0_branch
    assert m0_branch.index("pdsConfigureLpMtimerClock()") < m0_branch.index(
        "pdsClearIrq()"
    )
    assert m0_branch.index("pdsClearIrq()") < m0_branch.index("clicInit()")


def test_ble_central_timeouts_use_kernel_clock_abstraction():
    source = REPO_ROOT / "src" / "bl808" / "ble.nim"
    text = source.read_text(encoding="utf-8")

    assert "kernel/clock" in text
    assert "kernel/cps" in text
    timing_body = text.split("proc monotonicMs", 1)[1].split(
        "proc startCentralDiscoveryScan", 1
    )[0]
    assert "ticksToMs(readTick())" in timing_body
    assert "proc elapsedMsSince(startedAtMs: uint64): uint32" in timing_body
    assert "clicReadMtime()" not in timing_body

    connect_body = text.split("proc bleCentralConnectByName*", 1)[1].split(
        "proc bleDisconnectCurrent*", 1
    )[0]
    assert "let startedAtMs = monotonicMs()" in connect_body
    assert "elapsedMsSince(startedAtMs)" in connect_body
    assert "clicReadMtime()" not in connect_body


def test_ble_rf_delay_service_clears_txcal_latch_without_faking_fcal_ready():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    service_body = text.split("proc serviceBleRfCalibrationLatch() =", 1)[1].split(
        "proc bleRfDelayUs", 1
    )[0]
    assert "var txcal = regRead(BleRfTxPowerReg.uint)" in service_body
    assert "txcal = txcal and not BleRfTxcalLatchMask" in service_body
    assert "regWrite(BleRfTxPowerReg.uint, txcal)" in service_body
    assert "fcal = fcal or BleRfFcalReadyMask" not in service_body
    assert "regWrite(BleRfFcalReg.uint, fcal)" not in service_body
    assert "if (fcal and BleRfFcalReadyMask) != 0'u32:" in service_body
    assert "inc nim_ble_rf_fcal_ready_count" in service_body
    assert "inc nim_ble_rf_txcal_latch_count" in service_body


def test_ble_rf_init_and_channel_retune_settle_calibration_latches():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    delay_body = text.split("proc bleRfDelayUs", 1)[1].split(
        "proc settleBleRfCalibrationLatches", 1
    )[0]
    assert delay_body.count("serviceBleRfCalibrationLatch()") >= 2
    assert delay_body.index("serviceBleRfCalibrationLatch()") < delay_body.index(
        "delayUs(us)"
    )

    settle_body = text.split("proc settleBleRfCalibrationLatches", 1)[1].split(
        "proc writeBleMemoryWords", 1
    )[0]
    assert "bleRfDelayUs(10)" in settle_body
    assert "serviceBleRfCalibrationLatch()" in settle_body

    channel_body = text.split("proc configureBleRfChannelMhz", 1)[1].split(
        "proc configureBlePhy1M", 1
    )[0]
    rf_channel_body = text.split("proc bleRfChannelMhz", 1)[1].split(
        "proc applyBleRfChannelOptimize", 1
    )[0]
    optimize_body = text.split("proc applyBleRfChannelOptimize", 1)[1].split(
        "proc bleRfLegacyScanChannelMhz", 1
    )[0]
    assert "elif channel <= 10'u16:" in rf_channel_body
    assert "2404'u16 + channel * 2'u16" in rf_channel_body
    assert "elif channel < 37'u16:" in rf_channel_body
    assert "2406'u16 + channel * 2'u16" in rf_channel_body
    assert "BleRfOptimizeReg = 0x200010D0'u32" in text
    assert "BleRfOptimizeMidBandFirstMhz = 2452'u16" in text
    assert "BleRfOptimizeMidBandLastMhz = 2472'u16" in text
    assert "BleRegInit(address: 0x24C00818'u32, value: 0x01880C06'u32)" in text
    assert "BleRegInit(address: 0x24C0081C'u32, value: 0x00000F0F'u32)" in text
    assert "BleRegInit(address: 0x24C00820'u32, value: 0x0000130D'u32)" in text
    assert "BleRegInit(address: 0x24C00824'u32, value: 0x0000010D'u32)" in text
    assert "BleRegInit(address: 0x24C0083C'u32, value: 0x04920492'u32)" in text
    assert "BleRegInit(address: 0x24C00860'u32, value: 0x00007F03'u32)" in text
    assert "BleRfPower4DbmTxCal = 0x0010C222'u32" in text
    assert "BleRegInit(address: 0x200010B4'u32, value: BleRfPower4DbmTxCal)" in text
    assert "0x0002A222'u32" not in text
    assert "0x0010331F'u32" not in text
    assert "0x0210031F'u32" not in text
    assert "word = word and not BleRfOptimizeMidBandMask" in optimize_body
    assert "word = word or BleRfOptimizeMidBandMask" in optimize_body
    assert "applyBleRfChannelOptimize(channelMhz)" in channel_body
    assert "settleBleRfCalibrationLatches()" in channel_body
    assert channel_body.index("settleBleRfCalibrationLatches()") < channel_body.index(
        "nimDisableM0RfClicIrq()"
    )


def test_ble_phy_memory_loader_uses_typed_ldpc_agc_overlay():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "BlePhyMemoryRegs {.packed.} = object" in text
    assert "doAssert offsetof(BlePhyMemoryRegs, memMode) == 0x824" in text
    assert "doAssert offsetof(BlePhyMemoryRegs, ldpcMode) == 0x834" in text
    assert "doAssert offsetof(BlePhyMemoryRegs, agcMemGate) == 0x874" in text
    assert "doAssert offsetof(BlePhyMemoryRegs, ldpcCtrlB340) == 0xB340" in text
    assert "doAssert offsetof(BlePhyMemoryRegs, ldpcCtrlB344) == 0xB344" in text
    assert "doAssert offsetof(BlePhyMemoryRegs, ldpcCtrlB348) == 0xB348" in text
    assert "doAssert offsetof(BlePhyMemoryRegs, agcLoad) == 0xB390" in text

    load_body = text.split("proc loadBlePhyMemories() =", 1)[1].split(
        "proc bleRfChannelMhz", 1
    )[0]
    assert "let phyMem = blePhyMemoryRegs()" in load_body
    assert "bleRegOrPtr(addr phyMem.agcLoad, BlePhyAgcLoadEnableMask)" in load_body
    assert "bleRegOrPtr(addr phyMem.agcMemGate, BlePhyAgcMemGateMask)" in load_body
    assert "bleRegUpdatePtr(addr phyMem.ldpcMode, BlePhyLdpcLoadModeMask" in load_body
    assert "bleRegStorePtr(addr phyMem.ldpcCtrlB340, 0'u32)" in load_body
    assert "bleRegStorePtr(addr phyMem.ldpcCtrlB344, 0'u32)" in load_body
    assert "bleRegStorePtr(addr phyMem.ldpcCtrlB348, 0'u32)" in load_body
    assert "bleRegClearPtr(addr phyMem.memMode, BlePhyLdpcMemSelectMask)" in load_body
    assert "writeBleMemoryWords(blerfdata.BleLdpcMemBase, blerfdata.BleLdpcMem" in load_body
    for raw in (
        "0x24C0B340",
        "0x24C0B344",
        "0x24C0B348",
        "BlePhyMemModeReg.uint",
        "BlePhyLdpcModeReg",
        "BlePhyAgcMemGateReg.uint",
        "BlePhyAgcLoadReg.uint",
    ):
        assert raw not in load_body


def test_ble_rf_lo_fcal_search_direction_matches_reference():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    search_body = text.split("proc chooseBleRfBaseFcalCode", 1)[1].split(
        "proc runBleRfPriLoFcal", 1
    )[0]
    low_branch = search_body.split("if count < BleRfLoFcalLowCount:", 1)[1].split(
        "elif count > BleRfLoFcalHighCount:", 1
    )[0]
    high_branch = search_body.split("elif count > BleRfLoFcalHighCount:", 1)[1].split(
        "else:", 1
    )[0]

    assert "uint32(code) - uint32(bit)" in low_branch
    assert "uint32(code) + uint32(bit)" in high_branch


def test_ble_rf_lo_fcal_uses_reference_txcal_control_register():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "BleRfTxPowerReg = 0x200010B4'u32" in text
    assert "BleRfTxcalCtrlReg = 0x200010B8'u32" in text

    fcal_body = text.split("proc prepareBleRfPriLoFcal", 1)[1].split(
        "proc chooseBleRfBaseFcalCode", 1
    )[0]
    assert "regClear32(BleRfTxcalCtrlReg, 0x00003000'u32)" in fcal_body
    assert "regOr(BleRfTxcalCtrlReg, 0x00010000'u32)" in fcal_body
    assert "regClear32(BleRfTxcalCtrlReg, 0x00010000'u32)" in fcal_body
    assert "regClear32(BleRfTxPowerReg, 0x00003000'u32)" not in fcal_body
    assert "regOr(BleRfTxPowerReg, 0x00010000'u32)" not in fcal_body


def test_ble_rf_init_ports_bl606p_reference_fixed_register_phases():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "type\n  BleRegInit = object" in text
    assert "BleRegMaskInit = object" in text
    assert "BleRfPriStaticInit: array" in text
    assert "BleRfPriGainInit: array" in text
    assert "BleRfPriTxPowerRegisterBase: array[43, uint32]" in text
    assert "BleRfPriTxcalParams: array[BleRfTxcalSearchRecords, array[5, uint32]]" in text
    assert "BleRfCalibDataSize = sizeof(BleRfCalibData)" in text
    assert "doAssert BleRfCalibDataSize == 168" in text
    assert "BleRfPriCalSavedRegs: array[29, uint32]" in text
    assert "BleRfChannelDivTable40M: array[BleRfLoChannelCount, uint32]" in text
    assert "BleRfChannelCntTable40M: array[BleRfLoChannelCount, uint16]" in text
    assert "BleRfFcalWaitLimit = 5000" in text
    assert "BleRfRoscalWaitLimit = 10000" in text
    assert "BleRfRccalWaitLimit = 10000" in text
    assert "BleRfTxcalWaitLimit = 10000" in text
    assert "proc runBleRfPriRoscal" in text
    assert "proc chooseBleRfRoscalCode" in text
    assert "proc runBleRfPriRccal" in text
    assert "proc chooseBleRfRccalCode" in text
    assert "proc runBleRfPriTxcal" in text
    assert "proc searchBleRfTxcalParam" in text
    assert "proc writeBleRfTxcalParam" in text

    for needle in [
        "BleRfPriInit64Reg = 0x20001064'u32",
        "BleRfPriTxcalDcReg = 0x2000106C'u32",
        "BleRfPriInitD4Reg = 0x200010D4'u32",
        "BleRfPriModeCtrlReg = 0x20001030'u32",
        "BleRfRoscalCtrlReg = 0x2000107C'u32",
        "BleRfRbbRccalReg = 0x20001080'u32",
        "BleRfRoscalReg0 = 0x20001168'u32",
        "BleRfMeasureCtrlReg = 0x20001618'u32",
        "BleRfRccalCapabilityMask = 0x00000400'u32",
        "BleRfRccalDoneMode = 0x000C0000'u32",
        "BleRfTxcalDoneMode = 0x00F00000'u32",
        "BleRfTxcalParam2Mask = 0x007FF000'u32",
        "BleRfTxcalParam2EnableBit = 0x00800000'u32",
        "BleRfMeasureFrequencyShift = 10",
        "(regRead(BleRfPriInit64Reg.uint) and 0x0FC3FFFF'u32) or",
        "regOr(BleRfPriInit64Reg, 0x00400000'u32)",
        "(regRead(BleRfPriTxcalDcReg.uint) and not 0x00000007'u32) or",
        "0x50000000'u32",
        "BleRegMaskInit(address: BleRfPriModeCtrlReg",
        "BleRegMaskInit(address: BleRfTxcalCtrlReg",
        "keepMask: 0xFFFE0008'u32, setMask: 0x00004C2C'u32",
        "keepMask: 0xFFF0F00F'u32, setMask: 0x00F013C1'u32",
        "keepMask: 0xC00007FF'u32, setMask: 0xD037D000'u32",
        "keepMask: 0xFFFFFFFF'u32, setMask: 0x00008080'u32",
        "0x004524D4'u32, 0x0028E3D0'u32, 0x135FC000'u32, 0x00000000'u32",
        "0x00003189'u32, 0x11FC0000'u32, 0x00000000'u32, 0x115C0000'u32",
        "0x20001004'u32, 0x2000102C'u32, 0x2000101C'u32, 0x20001030'u32",
        "0x14088889'u32, 0x14111111'u32, 0x1419999A'u32, 0x14222222'u32",
        "0xA6EB'u16, 0xA732'u16, 0xA779'u16, 0xA7C0'u16, 0xA808'u16",
    ]:
        assert needle in text

    init_body = text.split("proc configureBleRf1M", 1)[1].split(
        "when defined(bl808m0) and defined(bl808WifiNimFw):", 1
    )[0]
    assert "applyBleRfPriStaticInit()" in init_body
    assert "writeBleRegInit(BleRf1MInit)" in init_body
    assert "runBleRfPriLoCalibration()" in init_body
    assert "runBleRfPriRoscal()" in init_body
    assert "runBleRfPriRccal()" in init_body
    assert "runBleRfPriTxcal()" in init_body
    assert "applyBleRfPriGainInit()" in init_body
    assert "applyBleRfPriTxPowerTableInit()" in init_body
    assert "applyBleRfVcoTableFromCal()" in init_body
    assert "BleRfFcalReadyValue" not in text
    assert "regWrite(BleRfFcalReg.uint, BleRfFcalReadyValue)" not in init_body
    assert init_body.index("applyBleRfPriStaticInit()") < init_body.index(
        "writeBleRegInit(BleRf1MInit)"
    )
    assert init_body.index("writeBleRegInit(BleRf1MInit)") < init_body.index(
        "runBleRfPriLoCalibration()"
    )
    assert init_body.index("runBleRfPriLoCalibration()") < init_body.index(
        "runBleRfPriRoscal()"
    )
    assert init_body.index("runBleRfPriRoscal()") < init_body.index(
        "runBleRfPriRccal()"
    )
    assert init_body.index("runBleRfPriRccal()") < init_body.index(
        "runBleRfPriTxcal()"
    )
    assert init_body.index("runBleRfPriTxcal()") < init_body.index(
        "applyBleRfPriGainInit()"
    )
    assert init_body.index("applyBleRfPriGainInit()") < init_body.index(
        "applyBleRfPriTxPowerTableInit()"
    )
    assert init_body.index("applyBleRfPriTxPowerTableInit()") < init_body.index(
        "applyBleRfVcoTableFromCal()"
    )


def test_ble_role_starts_do_not_rerun_full_rf_calibration():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "var bleRf1MConfigured: bool" in text
    ensure_body = text.split("proc ensureBleRf1MConfigured() =", 1)[1].split(
        "when defined(bl808m0) and defined(bl808WifiNimFw):", 1
    )[0]
    assert "if not bleRf1MConfigured:" in ensure_body
    assert "configureBleRf1M()" in ensure_body

    for body in [
        text.split("proc programNimInitiator", 1)[1].split(
            "proc handleNimInitiatorAdvRx", 1
        )[0],
        text.split("proc programNimScanning", 1)[1].split(
            "proc programNimAdvertising", 1
        )[0],
        text.split("proc programNimAdvertising", 1)[1].split(
            "proc hciCommandStatusEvent", 1
        )[0],
    ]:
        assert "ensureBleRf1MConfigured()" in body
        assert "configureBleRf1M()" not in body

    assert "proc programVendorLldInitiator" not in text
    assert "proc programVendorLldScan" not in text


def test_wireless_domain_reset_invalidates_ble_rf_ready_cache():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "proc invalidateBleRf1MConfig() {.inline.} =" in text
    prepare_body = text.split("proc prepareWirelessDomain() =", 1)[1].split(
        "proc configureBtPriorityPta", 1
    )[0]
    assert "invalidateBleRf1MConfig()" in prepare_body

    reclaim_body = text.split("proc bleNimReclaimRfForBle*", 1)[1].split(
        "# ---------------------------------------------------------------------------",
        1,
    )[0]
    assert reclaim_body.index("prepareWirelessDomain()") < reclaim_body.index(
        "configureBleRf1M()"
    )


def test_ble_connection_handoff_preserves_rx_descriptor_ring():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "proc prepareBtbleConnectionRxRingForHandoff()" in text
    prepare_body = text.split("proc prepareBtbleConnectionRxRingForHandoff()", 1)[1].split(
        "proc currentBtbleHalfUs", 1
    )[0]
    assert "resetBtbleAdvRxRing()" not in prepare_body
    assert "writeBtbleRxDescHeadIndex(0)" not in prepare_body
    assert "nim_lld_rx_desc_idx = lld_env[14] and 0x07'u8" in prepare_body
    assert "nim_lld_rx_desc_active = 0" in prepare_body
    assert "syncBtbleRxDescHeadToLldEnv" not in text

    peripheral_handoff = text.split(
        "proc startNimConnectionFromConnectInd", 1
    )[1].split("proc handleNimConnectInd", 1)[0]
    assert "prepareBtbleConnectionRxRingForHandoff()" in peripheral_handoff
    assert "0x0000013E'u32" not in peripheral_handoff

    central_handoff = text.rsplit("proc startNimInitiatorConnection", 1)[1].split(
        "proc nimInitServiceDeferredHandoff", 1
    )[0]
    assert "prepareBtbleConnectionRxRingForHandoff()" in central_handoff
    assert "0x0000013E'u32" not in central_handoff

    init_body = text.split("proc configureBleRf1M", 1)[1].split(
        "when defined(bl808m0) and defined(bl808WifiNimFw):", 1
    )[0]
    assert "settleBleRfCalibrationLatches()" in init_body
    assert init_body.index("settleBleRfCalibrationLatches()") < init_body.index(
        "nimDisableM0RfClicIrq()"
    )


def test_lld_rxdesc_free_matches_sdk_head_advance_semantics():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    body = text.split("proc lld_rxdesc_free*", 1)[1].split(
        "when bl808BleNimManualConnTx:", 1
    )[0]
    assert "discard desc" in body
    assert "if nim_lld_rx_desc_active != 0" not in body
    assert "let cur = lld_env[14] and 0x07'u8" in body
    assert "let descAddr = nimLldRxDescAddr(cur)" in body
    assert "write16(descAddr, status and not 0x8000'u16)" in body
    assert "lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)" in body
    assert "nim_lld_rx_desc_active = 0'u8" in body


def test_hci_reset_preserves_public_identity_address_for_advertising():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "nim_public_addr*: array[6, uint8]" in text
    assert "nim_public_addr_valid*: bool" in text

    reset_body = text.split("proc resetNimControllerState() =", 1)[1].split(
        "proc localAddrBytes", 1
    )[0]
    assert "nim_local_addr_valid = false" in reset_body
    assert "nim_public_addr_valid = false" not in reset_body

    addr_select = text.split("proc selectedLocalAddrByte", 1)[1].split(
        "proc expectedAdvAddrByte", 1
    )[0]
    assert "(ownAddrType and 0x01'u8) != 0'u8 and nim_local_addr_valid" in addr_select
    assert "nim_public_addr_valid" in addr_select
    assert "fallbackLocalAddrByte(idx)" in addr_select
    assert "controllerPublicAddrByte" not in text

    set_bd_addr = text.split("proc lld_util_set_bd_address", 1)[1].split(
        "proc lld_util_get_local_offset", 1
    )[0]
    assert "nim_public_addr[i] = addr_in.data[i]" in set_bd_addr
    assert "nim_public_addr_valid = true" in set_bd_addr

    get_bd_addr = text.split("proc lld_util_get_bd_address", 1)[1].split(
        "proc lld_util_set_bd_address", 1
    )[0]
    assert "if nim_public_addr_valid: nim_public_addr[i]" in get_bd_addr
    assert "else: fallbackLocalAddrByte(i)" in get_bd_addr

    assert "localAddrBytes(addr pdu[2], nim_adv_params[5])" in text
    assert "localAddrBytes(addr addrBytes[0], nim_adv_params[5])" in text


def test_default_advertising_puts_name_in_primary_adv_when_it_fits():
    source = REPO_ROOT / "src" / "bl808" / "ble.nim"
    text = source.read_text(encoding="utf-8")

    split_body = text.split("proc encodeDefaultAdvAndScanRspData", 1)[1].split(
        "proc advIntervalOrDefault", 1
    )[0]
    start_body = text.split("proc bt_le_adv_start", 1)[1].split(
        "proc bt_le_adv_stop", 1
    )[0]

    assert "appendAdByte(advPayload, advPos, BleAdTypeFlags" in split_body
    assert "appendAdName(advPayload, advPos, completeOnly = true)" in split_body
    assert "scanRsp[0] = 0" in split_body
    assert "appendAdName(scanRsp, scanPos)" in split_body
    assert "advPayload[0] = uint8(advPos - 1)" in split_body
    assert "let useDefaultSplit = adLen == 0 and sdLen == 0" in start_body
    assert "encodeDefaultAdvAndScanRspData(advPayload, scanRsp)" in start_body


def test_ble_host_uses_static_random_identity_by_default():
    source = REPO_ROOT / "src" / "bl808" / "ble.nim"
    text = source.read_text(encoding="utf-8")

    assert "bl808BleUseRandomAddr* {.booldefine.}: bool = false" in text
    assert "bl808BleUseStaticRandomIdentity* {.booldefine.}: bool = true" in text
    assert "BleUseRandomIdentity =" in text
    assert "sec.trngReadAll(words)" in text
    assert "bleStaticRandomIdentityConfigured = true" in text
    assert "(bleStaticRandomIdentity[5] and 0x3F'u8) or 0xC0'u8" in text
    assert "proc staticRandomIdentityPayloadValid" in text
    assert "randomAddr = [" not in text

    configure_body = text.split("proc configureRandomAddress", 1)[1].split(
        "proc copyAddr", 1
    )[0]
    assert "when BleUseRandomIdentity:" in configure_body
    assert "generateStaticRandomIdentity()" in configure_body
    assert "HciOpLeSetRandomAddress" in configure_body

    start_body = text.split("proc bt_le_adv_start", 1)[1].split(
        "proc bt_le_adv_stop", 1
    )[0]
    assert "when BleUseRandomIdentity:" in start_body
    assert "advParams[5] = 0x01'u8" in start_body


def test_pure_ble_controller_does_not_link_vendor_rf_library():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "bl606p_phyrf" not in text
    assert 'importc: "rf_init"' not in text
    assert "bl808BleNimBl606pPhyRf" not in text


def test_pure_ble_rf_table_preserves_connection_em_config_byte():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "BtbleRfEmConfigWord = 0x2000'u16" in text
    assert "BtbleRfRssiFloorDbm = -40'i8" in text
    assert "BtbleRfCalibrationWord = 0xBAC4'u16" in text
    assert "doAssert offsetof(BtbleRfTableView, reserved08) == 0x08" in text
    assert "doAssert offsetof(BtbleRfTableView, reserved0C) == 0x0C" in text
    assert "doAssert offsetof(BtbleRfTableView, txpwrMaxSet) == 0x10" in text
    assert "doAssert offsetof(BtbleRfTableView, txpwrMaxGet) == 0x14" in text
    assert "doAssert offsetof(BtbleRfTableView, txpwrDbmGet) == 0x1C" in text
    assert "doAssert offsetof(BtbleRfTableView, regRead) == 0x2C" in text
    assert "doAssert offsetof(BtbleRfTableView, emConfigWord) == 0x38" in text
    assert "doAssert offsetof(BtbleRfTableView, rssiFloorDbm) == 0x3D" in text
    assert "doAssert offsetof(BtbleRfTableView, calibrationWord) == 0x3E" in text
    assert "BleMacPhyRegs {.packed.} = object" in text
    assert "BlePhyCtrlRegs {.packed.} = object" in text
    assert "BlePhyAgcRegs {.packed.} = object" in text
    assert "doAssert offsetof(BleMacPhyRegs, sleepCtrl) == 0x30" in text
    assert "doAssert offsetof(BleMacPhyRegs, reset880) == 0x880" in text
    assert "doAssert offsetof(BleMacPhyRegs, reset89c) == 0x89C" in text
    assert "doAssert offsetof(BleMacPhyRegs, settle980) == 0x980" in text
    assert "doAssert offsetof(BleMacPhyRegs, settle98c) == 0x98C" in text
    assert "doAssert offsetof(BleMacPhyRegs, trim9c0) == 0x9C0" in text
    assert "doAssert offsetof(BlePhyCtrlRegs, phyCtrl08) == 0x08" in text
    assert "doAssert offsetof(BlePhyCtrlRegs, phyCtrl8c) == 0x8C" in text
    assert "doAssert offsetof(BlePhyAgcRegs, agcCtrl84) == 0x84" in text

    init_body = text.split("proc btble_rf_init", 1)[1].split(
        "# ---------------------------------------------------------------------------", 1
    )[0]
    sleep_body = text.split("proc nimRfSleep", 1)[1].split(
        "proc nimRfReset", 1
    )[0]
    reset_body = text.split("proc nimRfReset", 1)[1].split(
        "proc nimRfForceAgcEnable", 1
    )[0]
    assert "proc nimRfTxpwrDbmGet(cs: uint8, high: uint8): int8 {.cdecl.}" in text
    assert "table.reserved08 = nil" in init_body
    assert "table.reserved0C = nil" in init_body
    assert "table.txpwrMaxGet = cast[pointer](nimBleRfTxpowerMaxGet)" in init_body
    assert "table.emConfigWord = BtbleRfEmConfigWord" in init_body
    assert "table.rssiFloorDbm = BtbleRfRssiFloorDbm" in init_body
    assert "table.calibrationWord = BtbleRfCalibrationWord" in init_body
    assert "regStore(addr bleMacPhyRegs().sleepCtrl" in sleep_body
    assert "0x28000030" not in sleep_body
    assert "let mac = bleMacPhyRegs()" in reset_body
    assert "let phy = blePhyCtrlRegs()" in reset_body
    assert "let agc = blePhyAgcRegs()" in reset_body
    assert "regStore(addr mac.reset880" in reset_body
    assert "regUpdateField(addr mac.reset890" in reset_body
    assert "regStore(addr mac.trim9c0" in reset_body
    assert "regStore(addr agc.agcCtrl84" in reset_body
    assert "regUpdateField(addr phy.phyCtrl8c" in reset_body
    assert "regStore(addr phy.phyCtrl08" in reset_body
    for raw in (
        "0x28000880",
        "0x2800088C",
        "0x28000890",
        "0x280009C0",
        "0x20002C84",
        "0x2000288C",
        "0x20002808",
        "0x28000980",
    ):
        assert raw not in reset_body

    program_em = text.split("proc nimConnProgramEm", 1)[1].split(
        "proc nimConnProgramChannel", 1
    )[0]
    assert "volatileStore(addr event.rfConfig, uint16(rwip_rf[NimConnRfConfigIndex]))" in (
        program_em
    )


def test_pure_ble_legacy_advertiser_uses_known_good_em_words():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "BtbleLegacyAdvEventHeaderBase = 0x0020'u16" in text
    assert "BtbleLegacyAdvEventWord124 = 0xE3F5'u16" in text
    assert "BtbleLegacyAdvWord138 = 0xF102'u16" in text
    assert "BtbleLegacyAdvWord13C = 0xBD86'u16" in text
    assert "BtbleLegacyAdvControl = 0x11842182'u32" in text
    assert "BtbleLegacyAdvTimingHigh = 0x1338'u16" in text
    assert "BtbleLegacyAdvTimingLow = 0x3FD1'u16" in text
    assert "BtbleLegacyAdvTail = 0xE745'u16" in text
    assert "BtbleLegacyAdvTxDescFlags = 0xF84F'u16" in text
    assert "BtbleLegacyAdvTxTailLow = 0x4592'u16" in text
    assert "BtbleLegacyAdvTxTailHigh = 0x7B9F'u16" in text
    assert "BtbleLegacyAdvRxTailLow = 0x8EEC'u16" in text
    assert "BtbleLegacyAdvRxTailHigh = 0x51FB'u16" in text
    assert "BtbleScanRspDataOffset = 0x0A4C'u32" in text
    assert "BtbleLegacyScanRspEmptyPtr = 0x0000'u16" in text
    assert "BtbleLegacyScanRspEmptyTail = 0x2601'u16" in text
    assert "BtbleLegacyScanRspDataTail = 0x2601'u16" in text


def test_legacy_advertising_uses_spec_random_adv_delay():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "BleLegacyAdvDelayMaxHalfUs = 20_000'u32" in text
    assert "proc nextLegacyAdvDelayHalfUs" in text
    assert "ble_adv_random_delay_disabled" in text
    delay_body = text.split("proc nextLegacyAdvDelayHalfUs", 1)[1].split(
        "proc pushBtbleAdvProgram", 1
    )[0]
    assert "currentBtbleTime()" in delay_body
    assert "nim_ble_dbg_isr_count" in delay_body
    assert "BleLegacyAdvDelayMaxHalfUs div 8'u32" in delay_body

    schedule_body = text.split("proc scheduleBtbleEvent", 1)[1].split(
        "proc btbleTargetExpired", 1
    )[0]
    assert "nimAdvIntervalHalfUs() + nextLegacyAdvDelayHalfUs()" in schedule_body


def test_legacy_advertising_chsel_matches_supported_features():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "const bl808BleNimPeripheralChSel2* {.booldefine.}: bool = true" in text
    assert "NimBleFeatureChannelSelectionAlgorithm2 = 1'u64 shl 14" in text
    assert "NimBleExperimentalLeFeatures =" in text
    assert "NimBleLegacyAdvChSelBit =" in text

    feature_body = text.split("NimBleExperimentalLeFeatures =", 1)[1].split(
        "NimBleLegacyAdvChSelBit =", 1
    )[0]
    assert "when bl808BleNimPeripheralChSel2" in feature_body
    assert "NimBleFeatureChannelSelectionAlgorithm2" in feature_body

    chsel_body = text.split("NimBleLegacyAdvChSelBit =", 1)[1].split(
        "NimBleLe1MPhy", 1
    )[0]
    assert "when bl808BleNimPeripheralChSel2" in chsel_body
    assert "0x0020'u16" in chsel_body
    assert "0'u16" in chsel_body

    adv_body = text.split("proc programBtbleLegacyAdv", 1)[1].split(
        "proc btbleDelayTicksToSlots", 1
    )[0]
    assert "let advHeaderFlags = NimBleLegacyAdvChSelBit or txAdd" in adv_body
    assert "let eventAddrType = uint16(nim_adv_params[5] and 0x01'u8)" in adv_body
    assert "let advEventHeader = BtbleLegacyAdvEventHeaderBase or eventAddrType" in adv_body
    assert "let scanRspHeaderFlags = 0x0004'u16 or txAdd" in adv_body
    assert "write16(BTBLE_EM_BASE + 0x13A'u32, 0'u16)" not in adv_body
    assert "((pduLen and 0x00FF'u16) shl 8) or advHeaderFlags" in adv_body
    assert (
        "((scanRspPduLen and 0x00FF'u16) shl 8) or scanRspHeaderFlags"
        in adv_body
    )
    assert "if scanRspLen == 0:" in adv_body
    assert "write16(BTBLE_EM_BASE + 0x56C'u32, BtbleLegacyScanRspEmptyPtr)" in (
        adv_body
    )
    assert "write16(BTBLE_EM_BASE + 0x56E'u32, BtbleLegacyScanRspEmptyTail)" in (
        adv_body
    )
    assert "write16(BTBLE_EM_BASE + 0x56C'u32, BtbleScanRspDataOffset.uint16)" in (
        adv_body
    )
    assert "write16(BTBLE_EM_BASE + 0x56E'u32, BtbleLegacyScanRspDataTail)" in (
        adv_body
    )
    assert "((pduLen and 0x00FF'u16) shl 8) or 0x0020'u16" not in adv_body


def test_pure_ble_scanner_uses_vendor_scan_activity_words():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "proc btbleIrqSave(): uint" in text
    assert "core.csrReadMstatus()" in text
    assert "core.csrWriteMstatus(saved)" in text
    assert "NimScanPassiveActivityWord = 0x0008'u16" in text
    assert "NimScanActiveActivityWord = 0x0009'u16" in text
    assert "NimScanReqTxDescPtr = 0x039C'u16" in text
    assert "NimScanReqTxDescOffset = uint32(NimScanReqTxDescPtr) shl 2" in text
    assert "NimScanReqPduLen = 12'u16" in text
    assert "var nim_scan_req_peer_addr_type* {.exportc.}: uint32" in text
    assert "proc nimScanActivityWord(): uint16" in text
    assert "proc programBtbleScanReqTxDesc()" in text
    assert (
        "nim_scan_req_peer_addr_type =\n"
        "          uint32((header shr 6) and 0x0001'u16)"
    ) in text

    scan_body = text.split("proc programBtbleLegacyScanEm", 1)[1].split(
        "proc programBtbleLegacyInitiatorEm", 1
    )[0]
    assert "write16(em + 0x00'u32, nimScanActivityWord())" in scan_body
    assert "if nimScanActive(): NimScanReqTxDescPtr else: 0'u16" in scan_body
    assert "programBtbleScanReqTxDesc()" in scan_body
    assert "write16(em + 0x00'u32, 0x0208'u16)" not in scan_body

    tx_desc_body = text.split("proc programBtbleScanReqTxDesc()", 1)[1].split(
        "proc nimScanIntervalSlots", 1
    )[0]
    assert "BTBLE_EM_BASE + NimScanReqTxDescOffset" in tx_desc_body
    assert "write16(desc + 0x00'u32, 0'u16)" in tx_desc_body
    assert "if nimScanActive(): nimScanReqHeader() else: 0'u16" in tx_desc_body
    assert "write16(desc + 0x04'u32, 0'u16)" in tx_desc_body
    assert "countup(0'u32, 0x0E'u32" not in tx_desc_body

    header_body = text.split("proc nimScanReqHeader(): uint16", 1)[1].split(
        "proc programBtbleScanReqTxDesc()", 1
    )[0]
    assert "let txAdd = uint16(nim_scan_params[5] and 0x01'u8) shl 6" in header_body
    assert (
        "let rxAdd = uint16(nim_scan_req_peer_addr_type and 0x01'u32) shl 7"
        in header_body
    )


def test_pure_ble_initiator_programs_connect_ind_tx_descriptor():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "NimInitConnectIndPduType = 0x0005'u16" in text
    assert "NimInitTxDescPtr = 0x0304'u16" in text
    assert "NimInitTxDescOffset = uint32(NimInitTxDescPtr) shl 2" in text
    assert "proc nimInitConnectIndHeader(): uint16" in text
    assert "proc programBtbleInitTxDesc()" in text

    header_body = text.split("proc nimInitConnectIndHeader(): uint16", 1)[1].split(
        "proc nimInitBuildConnReqData", 1
    )[0]
    assert "uint16(NimInitConnectIndPayloadLen) shl 8" in header_body
    assert "NimInitConnectIndPduType" in header_body
    assert "computeConnectIndHeaderFlags()" in header_body

    desc_body = text.split("proc programBtbleInitTxDesc()", 1)[1].split(
        "proc nimInitRecordRx", 1
    )[0]
    assert "BTBLE_EM_BASE + NimInitTxDescOffset" in desc_body
    assert "write16(desc + 0x00'u32, 0'u16)" in desc_body
    assert "write16(desc + 0x02'u32, nimInitConnectIndHeader())" in desc_body
    assert "write16(desc + 0x04'u32, NimInitConnReqDataOffset0)" in desc_body

    init_body = text.split("proc programBtbleLegacyInitiatorEm", 1)[1].split(
        "when defined(BleDebugCounters):", 1
    )[0]
    assert "nimInitWriteConnReqData()" in init_body
    assert "programBtbleInitTxDesc()" in init_body
    assert "write16(em + 0x24'u32, NimInitTxDescPtr)" in init_body
    assert "write16(em + 0x3A'u32, 0'u16)" in init_body


def test_pure_ble_initiator_reschedules_skipped_programs_without_rx_drain():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "NimInitMinLeadSlots = 32'u32" in text

    done_body = text.split("proc nimInitEventDone", 1)[1].split(
        "proc nimInitWindowDoneDeadline", 1
    )[0]
    assert "event == 4'u8" not in done_body

    callback_body = text.split("proc nimInitSchProgCb", 1)[1].split(
        "proc nimInitRequestRxDescriptorService", 1
    )[0]
    skip_branch = callback_body.split("elif event == 4'u8:", 1)[1].split(
        "if nimInitEventDone(event):", 1
    )[0]
    assert "pushNimInitiatorProgram(nimInitRescheduleLeadSlots())" in skip_branch
    assert "nimInitRequestRxDescriptorService" not in skip_branch


def test_pure_ble_peripheral_uses_reference_transmit_window_timing():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "NimConnTrackedRxWindowHalfUs = 2500'u32" in text
    assert "NimConnPeripheralAcquireRxEvents = 4'u8" in text
    assert "NimConnInitialPeripheralScheduleLeadSlots" not in text
    assert "proc btbleAdvRxFine(desc: uint32): uint16 {.inline.}" in text
    assert "read16(desc + 0x0C'u32) and 0x03FF'u16" in text
    assert "proc btbleAdvRxClock(desc: uint32): uint32 {.inline.}" in text
    assert "read16(desc + 0x08'u32).uint32" in text
    assert "proc btbleConnRxFine(desc: uint32): uint16 {.inline.}" in text
    assert "proc btbleConnRxClock(desc: uint32): uint32 {.inline.}" in text
    assert "proc nimConnExpandClock(rawClock, referenceClock: uint32): uint32" in text
    assert "proc nimConnPeripheralAcquired(): bool" in text
    assert "rxAcquiredEvents: uint8" in text
    assert "nim_conn_rx_acquire_events* {.exportc.}: uint32" in text
    assert "proc nimConnEffectiveRxWindowHalfUs" not in text
    assert "intervalHalfUs" not in text

    start_body = text.split(
        "proc nimLldConStart(conhdl: uint16, params: pointer): uint8 {.cdecl.} =",
        1,
    )[1].split(
        "proc nimLldConLlcpTx", 1
    )[0]
    direct_branch = start_body.split(
        "if p[36] != 0'u8:", 1
    )[1].split("else:", 1)[1].split(
        "let scaIdx = p[22]", 1
    )[0]
    assert "nim_conn_state.directAnchorMode = p[36] == 0'u8" in start_body
    assert "if nim_conn_state.centralRole: 0'u32" in direct_branch
    assert "else: uint32(p[7]) * NimConnHalfUsPerConnWindowUnit" in direct_branch

    schedule_body = text.split("proc nimConnScheduleTarget", 1)[1].split(
        "proc nimConnRxSyncPosition", 1
    )[0]
    assert "let windowHalfUs = nim_conn_state.rxWindowHalfUs" in schedule_body
    assert "lld_rx_timing_compute" in schedule_body
    assert "windowHalfUs)" in schedule_body
    assert "NimConnLe1mSyncPosition = 0x0007'u16" in text
    assert "NimConnCodedSyncPosition = 0x0038'u16" in text
    assert "nimConnRxTimingControl" not in text
    assert "proc nimConnRxWindowControl(rxTimingHalfUs: uint32): uint16" in text
    assert "(rxTimingHalfUs + 1'u32) shr 1" in text
    assert "if half >= 0x4000'u32:" in text
    assert "0x8000'u16 or" in text
    program_em_body = text.split("proc nimConnProgramEm", 1)[1].split(
        "proc nimConnProgramChannel", 1
    )[0]
    program_rx_body = text.split("proc nimConnProgramRxTiming", 1)[1].split(
        "proc nimConnTxOctets", 1
    )[0]
    assert "volatileStore(addr event.rxSync, nimConnRxSyncPosition())" in program_em_body
    assert "not nim_conn_state.directAnchorMode" in program_rx_body
    assert "nim_conn_state.rxTimingHalfUs != 0'u32" in program_rx_body
    assert "nimConnRxWindowControl(nim_conn_state.rxTimingHalfUs)" in program_rx_body
    assert "else:\n          nimConnRxSyncPosition()" in program_rx_body
    assert "write16(nimConnEmAddr(conhdl, 0x1E'u32), timing)" in program_rx_body

    rx_anchor_body = text.split("proc nimConnAnchorFromRxTimestamp", 1)[1].split(
        "proc nimConnScheduleTarget", 1
    )[0]
    assert "Match the lld_con_frm_cbk timing recovery path" in rx_anchor_body
    assert "nimConnExpandClock(rawClock, nim_conn_state.nextAnchor)" in rx_anchor_body
    assert "NimConnHalfUsPerHalfSlot - 1'u32" in rx_anchor_body
    assert "int32(syncPos) * 2'i32" in rx_anchor_body
    assert "nimConnNormalizeFine(clock, fine)" in rx_anchor_body

    conn_schedule_body = text.split("proc nimConnSchedule() =", 1)[1].split(
        "proc nimConnObserveRxHeader", 1
    )[0]
    assert "delta > leadSlots" in conn_schedule_body
    assert "let earliestTarget =" not in conn_schedule_body
    assert "nimConnHalfUsToHalfSlotsCeil" not in text
    assert "intervalSlots * NimConnHalfUsPerHalfSlot" not in schedule_body
    assert "p[0x18] = rwip_priority[10]" in conn_schedule_body
    assert "p[0x1A] = 0'u8" in conn_schedule_body
    assert "p[0x1B] = 0x1F'u8" in conn_schedule_body
    assert "p[0x18] = uint8(nim_conn_state.handle" not in conn_schedule_body

    observe_body = text.split("proc nimConnObserveRxHeader", 1)[1].split(
        "proc nimConnEventDone", 1
    )[0]
    assert "let firstRxInEvent =" in observe_body
    assert "not nim_conn_state.rxObserved" in observe_body
    assert "lastRxEventCounter != nim_conn_state.eventCounter" in observe_body
    assert "if rxClock != 0'u32 and firstRxInEvent:" in observe_body
    assert "if nim_conn_state.centralRole:" in observe_body
    assert "nimConnExpandClock(rxClock, nim_conn_state.nextAnchor)" in observe_body
    assert "nim_conn_state.timingReferenceClock = observedClock" in observe_body
    assert "let consecutive =" in observe_body
    assert "if not consecutive:" in observe_body
    assert "nimConnAnchorFromRxTimestamp(rxClock, rxFine, observedFine)" in observe_body
    assert "nim_conn_state.anchorFine = observedFine" in observe_body
    assert "nim_conn_state.rxAcquiredEvents = 1'u8" in observe_body
    assert "nim_conn_rx_acquire_reset_count" in observe_body
    assert "if nimConnPeripheralAcquired() and" in observe_body
    assert "nim_conn_state.rxWindowHalfUs = NimConnTrackedRxWindowHalfUs" in observe_body
    assert "nimConnObserveRxHeader(header, rxClock, rxFine)" in text
    assert "let rxFine = btbleConnRxFine(desc)" in text
    assert "let rxClock = btbleConnRxClock(desc)" in text


def test_rwip_priority_tables_match_sdk_reference_bytes():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    tables = re.findall(
        r"var rwip_priority\* \{\.exportc\.\}: array\[32, uint8\] =\n\s+\[(.*?)\]",
        text,
        re.S,
    )
    assert len(tables) == 2
    for table in tables:
        collapsed = " ".join(table.split())
        assert (
            "0x28'u8, 0x08, 0x60, 0x08, 0x50, 0x08, 0x70, 0x08, "
            "0x80, 0x08, 0xA0, 0x08, 0xA0, 0x08, 0x28, 0x08, "
            "0x50, 0x08, 0x60, 0x08, 0x50, 0x08"
        ) in collapsed
        assert "0x28, 0x1E" not in collapsed


def test_rwip_timing_defaults_match_sdk_reference_fallbacks():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "RwipDefaultProgramDelaySlots = 3'u16" in text
    assert "RwipDefaultMaxDriftPpm = 500'u32" in text
    assert (
        text.count(
            "var rwip_prog_delay* {.exportc.}: uint16 = "
            "RwipDefaultProgramDelaySlots"
        )
        == 2
    )
    assert text.count(
        "proc rwip_current_drift_get*(): uint32 {.exportc, cdecl.} =\n"
        "    RwipDefaultMaxDriftPpm"
    ) == 2
    assert text.count(
        "proc rwip_max_drift_get*(sca: uint8): uint32 {.exportc, cdecl.} =\n"
        "    discard sca\n"
        "    RwipDefaultMaxDriftPpm"
    ) == 2

    dummy_get = text.split("proc rwipParamDummyGet", 1)[1].split(
        "proc rwipParamDummySet", 1
    )[0]
    dummy_set = text.split("proc rwipParamDummySet", 1)[1].split(
        "proc rwipParamDummyDel", 1
    )[0]
    dummy_del = text.split("proc rwipParamDummyDel", 1)[1].split(
        "var rwip_param", 1
    )[0]
    assert "1'u8" in dummy_get
    assert "1'u8" in dummy_set
    assert "1'u8" in dummy_del


def test_sch_prog_fifo_marks_mac_done_after_event_end():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "var rwip_mac_done* {.exportc.}: uint8" in text
    assert "proc rwip_mac_done_set*() {.exportc, cdecl.} =" in text
    assert "rwip_mac_done = 1'u8" in text

    fifo_body = text.split("proc sch_prog_fifo_isr*", 1)[1].split(
        "proc sch_prog_init*", 1
    )[0]
    assert (
        "if (stat and 0x00000002'u32) != 0:\n"
        "        sch_prog_end_isr(eventSlot)\n"
        "        rwip_mac_done_set()"
    ) in fifo_body

    init_body = text.split("proc sch_prog_init*", 1)[1].split(
        "proc sch_prog_push*", 1
    )[0]
    assert "rwip_mac_done = 0" in init_body


def test_pure_ble_connection_programs_rf_channel_indexes():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")
    irq_text = (REPO_ROOT / "src" / "bl808" / "irq.nim").read_text(
        encoding="utf-8"
    )

    assert "NimConnTxDescBaseOffset = 0x0558'u16" in text
    assert "NimConnTxDescPerHandleStride = 0x0070'u16" in text
    assert "NimConnTxDescStride = 0x0010'u16" in text
    assert "emUnmappedChannel: uint8" in text
    assert "NimM0RfTop0IrqRaw = 21'u32" in text
    assert "NimM0RfTop1IrqRaw = 22'u32" in text
    assert "NimM0BleIrqConnRaw = 48'u32" in text
    assert "NimM0BleIrqConnAlias = 64'u32" in text
    assert "NimM0BleIrqRaw = 56'u32" in text
    assert "NimM0BleIrqSchedulerRaw = 61'u32" in text
    assert "NimM0BtIrqRaw = 62'u32" in text
    assert "NimM0BleIrqAlias = 72'u32" in text
    assert "GlbMcuIntMask0* = GlbBase + 0x58'u" in irq_text
    assert "GlbMcuIntClear0* = GlbBase + 0x60'u" in irq_text
    assert "proc m0McuIntMaskAndClearSource*(irq: uint32)" in irq_text
    assert "m0McuIntUnmaskSource(irq)" in irq_text
    assert "m0McuIntMaskSource(irq)" in irq_text
    assert "m0McuIntClearSource(irq)" in irq_text
    generic_disable_body = text.split("proc nimDisableM0ClicIrq", 1)[1].split(
        "proc nimDisableM0BleClicIrq", 1
    )[0]
    assert "m0McuIntMaskAndClearSource(irq)" in generic_disable_body
    ble_disable_body = text.split("proc nimDisableM0BleClicIrq()", 1)[1].split(
        "proc nimDisableM0RfClicIrq()", 1
    )[0]
    for irq_name in [
        "NimM0BleIrqConnRaw",
        "NimM0BleIrqConnAlias",
        "NimM0BleIrqRaw",
        "NimM0BleIrqSchedulerRaw",
        "NimM0BtIrqRaw",
        "NimM0BleIrqAlias",
    ]:
        assert f"nimDisableM0ClicIrq({irq_name})" in ble_disable_body
    assert "proc nimDisableM0RfClicIrq()" in text
    disable_body = text.split("proc nimDisableM0RfClicIrq()", 1)[1].split(
        "const", 1
    )[0]
    assert "m0McuIntMaskAndClearSource(NimM0RfTop0IrqRaw)" in disable_body
    assert "m0McuIntMaskAndClearSource(NimM0RfTop1IrqRaw)" in disable_body
    assert "proc nimConnTxDescBaseOffsetForHandle(handle: uint16): uint16" in text
    assert "uint32(handle and 0x00FF'u16) *" in text
    assert "uint32(NimConnTxDescPerHandleStride)" in text
    assert (
        "nim_conn_state.txDescBaseOffset = nimConnTxDescBaseOffsetForHandle(conhdl)"
        in text
    )
    assert "nim_conn_state.txDescBaseOffset + uint16((slot and 1'u8) shl 4)" in text
    assert "proc nimConnAdvanceCsa1ChannelState(eventDelta: uint16)" in text
    advance_body = text.split(
        "proc nimConnAdvanceCsa1ChannelState(eventDelta: uint16)", 1
    )[1].split("proc nimConnMappedChannel", 1)[0]
    assert "CSA#1 advances" in advance_body
    assert "unmapped channel state" in advance_body
    assert "BTBLE engine applies the connection" in advance_body
    assert "channel map from EM for the actual data channel" in advance_body

    program_em = text.split("proc nimConnProgramEm", 1)[1].split(
        "proc nimConnProgramChannel", 1
    )[0]
    assert (
        "volatileStore(addr event.crcInitLow,\n        uint16(nim_conn_state.crcInit and 0xFFFF'u32))"
        in program_em
    )
    assert "uint16((nim_conn_state.crcInit shr 16) and 0x00FF'u32)" in program_em
    assert "NimConnChannelSelect2Bit" not in program_em
    assert "crcHigh = crcHigh or" not in program_em

    program_channel = text.split("proc nimConnProgramChannel", 1)[1].split(
        "proc nimConnClockAhead", 1
    )[0]
    assert "proc nimConnProgramChannel(conhdl: uint16): uint8" in text
    assert "if nim_conn_state.channelSelection2:" in program_channel
    assert "NimConnCsa2ChannelField" not in text
    assert "NimConnCsa2DirectChannelField" not in text
    assert "NimConnCsa2TimingChannelField" not in text
    select_channel = text.split("proc nimConnSelectChannel", 1)[1].split(
        "proc nimConnApplyPendingChannelMap", 1
    )[0]
    assert "prn mod 37" not in select_channel
    assert "let unmapped = uint8((uint32(prn) * 37'u32) shr 16)" in select_channel
    assert "nim_conn_state.lastUnmappedChannel = unmapped" in select_channel
    assert (
        "if nim_conn_state.emUnmappedChannel <= 36'u8:" in select_channel
    )
    assert (
        "nim_conn_state.lastUnmappedChannel =\n"
        "        if nim_conn_state.emUnmappedChannel <= 36'u8:"
    ) in select_channel
    assert (
        "nimConnAdvanceCsa1Unmapped(nim_conn_state.emUnmappedChannel, 1'u16)"
        not in select_channel
    )
    assert "nimConnMappedChannel(nim_conn_state.lastUnmappedChannel)" in select_channel
    assert "let emUnmappedChannel =" not in program_channel
    start_body = text.split("proc nimLldConStart", 1)[1].split(
        "let scaIdx = p[22]", 1
    )[0]
    assert "nim_conn_state.hopIncrement = p[21] and 0x1F'u8" in start_body
    assert "nim_conn_state.emUnmappedChannel = nimConnHopIncrement()" in start_body
    assert (
        start_body.index("nim_conn_state.hopIncrement = p[21] and 0x1F'u8")
        < start_body.index("nim_conn_state.emUnmappedChannel = nimConnHopIncrement()")
        < start_body.index("nim_conn_state.channelSelection2 = p[38] != 0'u8")
    )
    assert "nimConnEmChannelField" not in text
    assert "let emChannel =" in program_channel
    assert (
        "if nim_conn_state.channelSelection2:\n"
        "          0'u8"
    ) in program_channel
    assert (
        "elif nim_conn_state.lastUnmappedChannel <= 36'u8:\n"
        "          nim_conn_state.lastUnmappedChannel"
    ) in program_channel
    assert "let channelField =" in program_channel
    assert "if emChannel <= 36'u8: emChannel else: 0'u8" in program_channel
    assert "nimConnEmUnmappedChannelIndex" not in text
    assert "proc nimConnTuneRfChannel" not in text
    assert "bl808BleNimConnManualRfTune" not in text
    assert "configureBleRfChannelMhz" not in program_channel
    assert "bleRfChannelMhz" not in program_channel
    assert "discard channel" not in program_channel
    assert "channelWord = channelWord or NimConnChannelSelect2Bit" in program_channel
    assert "write16(nimConnEmAddr(conhdl, 0x18'u32), channelWord)" in program_channel

    schedule_body = text.split("proc nimConnSchedule() =", 1)[1].split(
        "proc nimConnObserveRxHeader", 1
    )[0]
    advance_body = text.split("proc nimConnAdvanceEventForSchedule", 1)[1].split(
        "proc nimConnSchedule", 1
    )[0]
    assert "nimConnAdvanceCsa1ChannelState(1'u16)" in advance_body
    assert "var now = currentBtbleTime()" in schedule_body
    assert "discard nimConnProgramChannel(nim_conn_state.handle)" in schedule_body
    assert "nimConnTuneRfChannel" not in schedule_body
    assert "let tunedDelta = (targetClock - now) and 0x0FFFFFFF'u32" not in (
        schedule_body
    )
    assert schedule_body.index("discard nimConnProgramChannel(nim_conn_state.handle)") < (
        schedule_body.index("sch_prog_push(addr nim_conn_sch_prog[0])")
    )

    connect_handoff = text.split(
        "proc startNimConnectionFromConnectInd", 1
    )[1].split("proc serviceQueuedNimConnectInd", 1)[0]
    assert "NimConnConnectIndTransmitWindowDelayHalfSlots = 4'u32" in text
    assert "NimConnAdvTypeTimingBit = 0x10'u16" in text
    assert (
        "NimConnLegacyAdvEventProps: array[5, uint16] = [\n"
        "      0x13'u16, 0x1D'u16, 0x12'u16, 0x10'u16, 0x15'u16\n"
        "    ]"
    ) in text
    assert "proc nimConnLegacyAdvLeadSelector(): uint8 {.inline.}" in text
    assert "proc nimConnLegacyAdvActiveProps(): uint16 {.inline.}" in text
    assert "let advType = nim_adv_params[4]" in text
    assert "nim_adv_event_props*: uint16" in text
    assert "if nim_adv_event_props != 0'u16: nim_adv_event_props" in text
    assert "nim_adv_event_props = NimConnLegacyAdvEventProps[0]" in text
    assert "nim_adv_event_props = 0" in text
    assert "NimConnLegacyAdvEventProps[advType.int]" in text
    active_props_body = text.split(
        "proc nimConnLegacyAdvActiveProps(): uint16 {.inline.}", 1
    )[1].split("proc nimConnLegacyAdvLeadSelector", 1)[0]
    assert "read16(BTBLE_EM_BASE + 0x55A'u32)" not in active_props_body
    assert "uint8((props xor NimConnAdvTypeTimingBit) and 0x00FF'u16)" in text
    assert "props xor NimConnAdvTypeTimingBit) shr 4" not in text
    assert "let firstAnchor = (baseClock +" in connect_handoff
    assert "winOffset * NimConnHalfSlotsPerConnIntervalUnit +" in connect_handoff
    assert "NimConnConnectIndTransmitWindowDelayHalfSlots" in connect_handoff
    assert "let directAnchor = addBtbleClockSlots(\n      firstAnchor," in (
        connect_handoff
    )
    timing_path = connect_handoff.split("when bl808BleNimConTimingPath:", 1)[
        1
    ].split("else:", 1)[0]
    assert "nimConnectTiming(baseClock, rxFine, rateIdx, timingClock, timingFine)" in (
        timing_path
    )
    assert "putLe32(outp, 28, timingClock)" in timing_path
    assert "NimConnConnectIndTransmitWindowDelayHalfSlots" not in timing_path
    assert "outp[39] = nimConnLegacyAdvLeadSelector()" in connect_handoff
    assert "outp[38] = uint8((header shr 5) and 0x01'u16)" in connect_handoff
    assert "outp[39] = nimConnLegacyAdvLeadSelector()" in connect_handoff
    assert "let rxFine = btbleAdvRxFine(desc)" in text
    assert "let rxClock = btbleAdvRxClock(desc)" in text

    init_body = text.split("proc bleControllerInitInternal", 1)[1].split(
        "proc ble_controller_init", 1
    )[0]
    bflbble_body = text.split("proc bflbble_init*", 1)[1].split(
        "proc bflbble_reset*", 1
    )[0]
    rwip_init_body = text.split("proc rwip_init", 1)[1].split(
        "proc rwip_reset", 1
    )[0]
    assert "NimBlePostLldInitSettleUs = 1000'u32" in text
    assert "proc bleSettleAfterLldInit()" in text
    assert "lld_init(false)\n  blePlatformInitMark(0x305'u32)" in bflbble_body
    assert "blePlatformInitMark(0x305'u32)\n  bleSettleAfterLldInit()" in (
        bflbble_body
    )
    assert bflbble_body.index("bleSettleAfterLldInit()") < bflbble_body.index(
        "llc_init()"
    )
    assert bflbble_body.index("llc_init()") < bflbble_body.index("llm_init()")
    assert init_body.index("ble_ke_init()") < init_body.index("hci_init(false)")
    assert init_body.index("hci_init(false)") < init_body.index("bflbble_init()")
    assert init_body.index("ble_controller_task_init(cfg)") < init_body.index(
        "bflbble_enable_runtime_irqs()"
    )
    assert "blePlatformInitMark(0x40E'u32)" in init_body
    assert "lld_init(initType != 0)\n  bleSettleAfterLldInit()" in rwip_init_body


def test_pure_central_runtime_clic_routes_ble_scheduler_to_nim_isr():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "proc bflbble_isr*() {.exportc, cdecl.}" in text

    handler_body = text.split(
        "proc nimM0BleRuntimeIrqHandler() {.cdecl.}", 1
    )[1].split("proc nimEnableM0BleRuntimeIrq", 1)[0]
    assert "bflbble_isr()" in handler_body

    enable_one = text.split("proc nimEnableM0BleRuntimeIrq", 1)[1].split(
        "proc nimEnableM0BleRuntimeIrqs", 1
    )[0]
    assert "registerTrapHandler(irq, nimM0BleRuntimeIrqHandler)" in enable_one
    assert "m0McuIntUnmaskSource(irq)" in enable_one
    assert "clicClearPending(irq)" in enable_one
    assert "clicSetAttr(irq, clicDefaultAttr())" in enable_one
    assert "clicSetLevel(irq, 1)" in enable_one
    assert "clicEnableIrq(irq)" in enable_one

    enable_all = text.split("proc nimEnableM0BleRuntimeIrqs", 1)[1].split(
        "const", 1
    )[0]
    for irq_name in [
        "NimM0RfTop0IrqRaw",
        "NimM0RfTop1IrqRaw",
        "NimM0BleIrqConnRaw",
        "NimM0BleIrqConnAlias",
        "NimM0BleIrqRaw",
        "NimM0BleIrqSchedulerRaw",
        "NimM0BtIrqRaw",
        "NimM0BleIrqAlias",
    ]:
        assert f"nimEnableM0BleRuntimeIrq({irq_name})" in enable_all
    assert "core.csrWriteMie(core.csrReadMie() or (1'u shl 11))" in enable_all
    assert "core.enableInterrupts()" in enable_all

    init_body = text.split("proc bflbble_init*", 1)[1].split(
        "proc bflbble_reset*", 1
    )[0]
    reset_body = text.split("proc bflbble_reset*", 1)[1].split(
        "proc bflbble_enable_runtime_irqs", 1
    )[0]
    enable_export_body = text.split("proc bflbble_enable_runtime_irqs*", 1)[
        1
    ].split(
        "proc bflbble_sleep_check", 1
    )[0]
    controller_body = text.split("proc bleControllerInitInternal", 1)[1].split(
        "proc ble_controller_init", 1
    )[0]
    rwip_reset_body = text.split("proc rwip_reset*", 1)[1].split(
        "proc rwip_isr", 1
    )[0]
    assert "nimEnableM0BleRuntimeIrqs()" not in init_body
    assert "nimEnableM0BleRuntimeIrqs()" not in reset_body
    assert "nimEnableM0BleRuntimeIrqs()" in enable_export_body
    assert "nimEnableM0BleRuntimeIrqs(false)" in rwip_reset_body
    assert controller_body.index("ble_controller_task_init(cfg)") < (
        controller_body.index("bflbble_enable_runtime_irqs()")
    )


def test_pure_ble_connection_em_duration_matches_lld_time_update_units():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "NimConnEventDurationMarginUs = 290'u32" in text
    assert "NimConnPacketDurationMarginUnits" not in text
    assert "proc nimConnEffectivePacketTimeUs" in text
    assert "let airtime = uint32(ble_util_pkt_dur_in_us(octets, rate))" in text
    assert "limit != 0'u32 and limit < airtime" in text

    duration_body = text.split("proc nimConnEventDurationHalfUs", 1)[1].split(
        "proc nimConnProgramPacketDurations", 1
    )[0]
    assert "NimConnEventDurationMarginUs" in duration_body
    assert "* 2'u32" in duration_body
    assert "0xFFFF'u16" in duration_body

    program_body = text.split("proc nimConnProgramPacketDurations", 1)[1].split(
        "proc nimConnDataHeader", 1
    )[0]
    assert "nimConnTxOctets(), nimConnTxTime()" in program_body
    assert "nimConnRxOctets(), nimConnRxTime()" in program_body
    assert "let durationHalfUs = nimConnEventDurationHalfUs(" in program_body
    assert "proc nimConnPacketDurationUnits" not in text
    assert "div 40'u32" not in program_body
    assert (
        "write16(nimConnEmAddr(conhdl, 0x2E'u32), durationHalfUs)"
        in program_body
    )
    assert (
        "write16(nimConnEmAddr(conhdl, 0x30'u32), durationHalfUs)"
        in program_body
    )

    assert "proc nimConnPacketEventDurationHalfUs" in text
    assert "proc nimConnScheduleDurationHalfUs" in text
    schedule_body = text.split("proc nimConnSchedule() =", 1)[1].split(
        "proc nimConnObserveRxHeader", 1
    )[0]
    duration_body = text.split("proc nimConnScheduleDurationHalfUs", 1)[1].split(
        "proc nimConnDataHeader", 1
    )[0]
    assert "nimConnPacketEventDurationHalfUs()" in duration_body
    assert "+ nim_conn_state.rxTimingHalfUs" in duration_body
    assert "nim_conn_state.rxTimingHalfUs shr 1" not in duration_body
    assert "nimConnScheduleDurationHalfUs()" in schedule_body
    assert "NimConnScheduleDurationHalfUs" not in text


def test_pure_ble_connection_tx_descriptor_header_leaves_sequence_to_hardware():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "NimConnDataHeaderMoreDataBit = 0x0010'u16" in text
    assert "NimConnDataHeaderNesnBit" not in text
    assert "NimConnDataHeaderSnBit" not in text

    header_body = text.split("proc nimConnDataHeader", 1)[1].split(
        "proc nimConnEventReached", 1
    )[0]
    assert "Match vendor lld_con_tx_prog" in header_body
    assert "payload length" in header_body
    assert "BTBLE connection engine owns NESN/SN insertion" in header_body
    assert "uint16(pduLen) shl 8" in header_body
    assert "uint16(llid and 0x03'u8)" in header_body
    assert "NimConnDataHeaderMoreDataBit" in header_body
    assert "nim_conn_state.txNesn" not in header_body
    assert "nim_conn_state.txSeq" not in header_body


def test_pure_ble_connection_tx_descriptors_keep_valid_empty_pdu_armed():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    init_body = text.split("proc nimConnInitTxDescriptors", 1)[1].split(
        "proc nimConnEventReached", 1
    )[0]
    assert "Match vendor lld_con_start" in init_body
    assert "descriptors software-owned" in init_body
    assert "nimConnResetTxDesc(firstOff, secondOff)" in init_body
    assert "nimConnResetTxDesc(secondOff, firstOff)" in init_body
    assert "write16(nimConnEmAddr(conhdl, 0x24'u32), nimConnEmDescPtr(firstOff))" in (
        init_body
    )

    tx_body = text.split("proc nimConnProgramTxDescriptors", 1)[1].split(
        "proc nimConnArmPendingHostAclTx", 1
    )[0]
    assert "let aclEmptyPending = nim_acl_empty_tx_pending != 0'u32" in tx_body
    assert "if not llcpPending and not aclPayloadPending and not aclEmptyPending:" not in tx_body
    assert "var llid = NimDataLlIdContinuation" in tx_body
    assert "var pduLen = 0'u8" in tx_body
    assert "elif aclPayloadPending or aclEmptyPending:" in tx_body
    assert "nimConnArmTxDesc(descOff, nextOff, NimConnEmptyDataEmOffset, header)" in (
        tx_body
    )

    program_em = text.split("proc nimConnProgramEm", 1)[1].split(
        "proc nimConnProgramChannel", 1
    )[0]
    assert "nimConnInitTxDescriptors(conhdl)" in program_em
    assert program_em.index("nimConnInitTxDescriptors(conhdl)") < program_em.index(
        "nimConnProgramTxDescriptors()"
    )


def test_pure_ble_connection_schedules_reference_em_channel_path():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "NimConnMaxScheduleAheadSlots" not in text
    schedule_body = text.split("proc nimConnSchedule() =", 1)[1].split(
        "proc nimConnObserveRxHeader", 1
    )[0]
    assert "delta > NimConnMaxScheduleAheadSlots" not in schedule_body
    assert "nim_conn_state.reschedulePending = true" not in schedule_body
    assert "requestBtbleSwInterrupt()" not in schedule_body
    assert "nimConnTuneRfChannel" not in schedule_body
    assert "let eventChannel =" not in schedule_body
    assert schedule_body.index("nimConnProgramChannel(nim_conn_state.handle)") < (
        schedule_body.index("nimConnProgramRxTiming(nim_conn_state.handle)")
    )


def test_pure_ble_connection_tx_confirm_uses_descriptor_completion():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "txAckDescOff: uint16" in text
    complete_helper = text.split("proc nimConnTxDescriptorComplete", 1)[1].split(
        "proc nimConnInitTxDescriptors", 1
    )[0]
    assert "Reference lld_con_frm_cbk" in complete_helper
    assert "NimConnTxDescSoftwareOwned" in complete_helper
    assert "nim_conn_state.txAckDescOff" in complete_helper

    tx_body = text.split("proc nimConnProgramTxDescriptors", 1)[1].split(
        "proc nimConnArmPendingHostAclTx", 1
    )[0]
    assert "not nimConnTxDescriptorComplete()" in tx_body
    assert "nim_conn_state.txAckDescOff = descOff" in tx_body

    complete_body = text.split("proc nimConnCompleteManualTx", 1)[1].split(
        "proc nimConnEventDone", 1
    )[0]
    assert text.count("nimConnTxDescriptorComplete()") >= 3
    assert "nim_conn_state.txAckObserved or nimConnTxDescriptorComplete()" in (
        complete_body
    )
    assert complete_body.count("nim_conn_state.txAckDescOff = 0'u16") >= 2


def test_pure_ble_llcp_filters_malformed_control_pdus():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "proc nimLlcpRxPduValid(opcode: uint8, pduLen: uint16): bool" in text
    assert "let expected = nimLlcpWireLength(opcode)" in text
    assert "return pduLen == expected.uint16" in text
    assert "LlcpPlausibleFutureOpcodeMax = 0x3F'u8" in text
    assert "nim_llcp_rx_malformed_count" in text
    assert text.count("nimLlcpRxPduValid(opcode,") >= 5
    assert text.count("nimLlcpRecordMalformed(") >= 5


def test_pure_ble_llcp_rejects_unadvertised_optional_procedures():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "proc nimBlePhyUpdateSupported(): bool" in text
    assert "NimBleFeatureLePing" not in text.split(
        "NimBleConservativeLeFeatures =", 1
    )[1].split("proc nimBleFeatureByte", 1)[0]
    assert "NimBleFeatureDataPacketLengthExtension" not in text.split(
        "NimBleConservativeLeFeatures =", 1
    )[1].split("proc nimBleFeatureByte", 1)[0]

    phy_req_branch = text.split("of LlcpPhyReq:", 1)[1].split(
        "of LlcpPingReq:", 1
    )[0]
    assert "if nimBlePhyUpdateSupported():" in phy_req_branch
    assert "nimLlcpBuildUnsupportedFeatureRsp(opcode)" in phy_req_branch

    ping_req_branch = text.split("of LlcpPingReq:", 1)[1].split(
        "of LlcpEncReq", 1
    )[0]
    assert "nimBleLocalFeatureSupported(NimBleFeatureLePing)" in ping_req_branch
    assert "nimLlcpBuildUnsupportedFeatureRsp(opcode)" in ping_req_branch


def test_llc_procedure_state_helpers_match_vendor_proc_env_abi():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "proc llc_proc_state_get*(procEnv: pointer): uint8" in text
    assert (
        "proc llc_proc_state_set*(procEnv: pointer, conhdl: uint16, state: uint8)"
        in text
    )
    state_get = text.split("proc llc_proc_state_get*", 1)[1].split(
        "proc llc_proc_state_set*", 1
    )[0]
    state_set = text.split("proc llc_proc_state_set*", 1)[1].split(
        "proc llc_proc_timer_pause_set", 1
    )[0]
    assert "cast[ptr UncheckedArray[uint8]](procEnv)[5]" in state_get
    assert "cast[ptr UncheckedArray[uint8]](procEnv)[5] = state" in state_set


def test_authenticated_payload_timeout_path_is_real_nim_not_zero_stub():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "abiNoopHandler(llc_auth_payl_nearly_to_handler)" not in text
    assert "abiNoopHandler(llc_auth_payl_real_to_handler)" not in text
    assert "LlcAuthPayloadNearlyTimerId = 0x0102'u16" in text
    assert "LlcAuthPayloadRealTimerId = 0x0103'u16" in text
    assert "HciEvtAuthenticatedPayloadTimeoutExpired = 0x57'u16" in text

    ping_set = text.split("proc llc_le_ping_set*", 1)[1].split(
        "proc phy_upd_proc_start", 1
    )[0]
    assert "llcAuthPayloadNearMargin(env, timeout)" in ping_set
    assert "llcEnvWrite16(env, LlcEnvAuthPayloadRealToOff, timeout - margin)" in ping_set
    assert "llcArmAuthPayloadTimers(conhdl, env)" in ping_set

    nearly = text.split("proc llc_auth_payl_nearly_to_handler*", 1)[1].split(
        "proc llc_auth_payl_real_to_handler*", 1
    )[0]
    assert "not llcEnvConnectionOpen(env) or not llcEnvEncrypted(env)" in nearly
    assert "llc_proc_init(procEnv, LlcProcLePing" in nearly
    assert "llc_proc_reg(conhdl, 0'u8, procEnv)" in nearly

    real = text.split("proc llc_auth_payl_real_to_handler*", 1)[1].split(
        "proc llc_cleanup*", 1
    )[0]
    assert "sendHostEvent(HciEvtAuthenticatedPayloadTimeoutExpired" in real
    assert "llcArmAuthPayloadTimers(conhdl, env)" in real


def test_pure_ble_feature_response_uses_peer_intersection():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    build_pdu = text.split("proc nimLlcpBuildFeaturePdu", 1)[1].split(
        "proc nimLlcpBuildLengthPdu", 1
    )[0]
    assert "features: uint64" in build_pdu
    assert "nimBleFeatureByte(features, i)" in build_pdu

    used_features = text.split("proc nimLlcpUsedFeaturesForPeer", 1)[1].split(
        "proc nimLlcpRecordUsedFeatures", 1
    )[0]
    assert "nim_llcp_state.peerFeaturesKnown" in used_features
    assert "NimBleConservativeLeFeatures and" in used_features
    assert "nim_llcp_state.peerFeatures" in used_features

    request_send = text.split("proc llc_llcp_feats_req_pdu_send", 1)[1].split(
        "proc llc_llcp_feats_rsp_pdu_send", 1
    )[0]
    assert "nimLlcpBuildFeaturePdu(LlcpFeatureReq)" in request_send

    response_builder = text.split("proc nimLlcpBuildFeatureRsp", 1)[1].split(
        "proc nimLlcpBuildPhyRsp", 1
    )[0]
    assert "let features = nimLlcpUsedFeaturesForPeer()" in response_builder
    assert "nimLlcpRecordUsedFeatures(features)" in response_builder
    assert "nimLlcpBuildFeaturePdu(LlcpFeatureRsp, features)" in response_builder


def test_pure_ble_connection_does_not_reprocess_duplicate_data_pdus():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    observe_body = text.split("proc nimConnObserveRxHeader", 1)[1].split(
        "proc nimConnSupervisionExpired", 1
    )[0]
    assert "rxPayloadFresh: bool" in text
    assert "let payloadFresh = peerSn == nim_conn_state.rxNextExpectedSeq" in (
        observe_body
    )
    assert "nim_conn_state.rxPayloadFresh = payloadFresh" in observe_body
    assert "if payloadFresh:" in observe_body

    service_body = text.split(
        "proc serviceNimConnectionLlcpRxDescriptors", 1
    )[1].split("when not defined(bl808m0):", 1)[0]
    assert "var payloadFresh = true" in service_body
    assert "payloadFresh = nim_conn_state.rxPayloadFresh" in service_body
    assert "if payloadFresh:\n            nimLlcpRecordRx" in service_body
    assert "if payloadFresh:\n            if sendHostAclData" in service_body


def test_pure_ble_connection_accepts_done_rx_link_status_before_payload():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "NimRxDescLinkMask = 0x7FFF'u16" in text
    assert "NimRxDescConnErrorMask" not in text
    assert "NimRxDescConnSyncMiss" not in text
    helper = text.split("proc connRxStatusAcceptsPayload", 1)[1].split(
        "proc rejectConnRxDescriptor", 1
    )[0]
    assert "(status and NimRxDescDone) != 0'u16" in helper
    assert "0x8116/0x811e are not" in helper
    assert "NimRxDescLinkMask" in text
    assert "nim_conn_rx_status_reject_count" in text
    assert text.count("not connRxStatusAcceptsPayload(status)") >= 3
    assert text.count("status and NimRxDescLinkMask") >= 8

    service_body = text.split(
        "proc serviceNimConnectionLlcpRxDescriptors", 1
    )[1].split("when not defined(bl808m0):", 1)[0]
    assert service_body.index("if not connRxStatusAcceptsPayload(status):") < (
        service_body.index("if not validConnDataHeader(header):")
    )
    assert "rejectConnRxDescriptor(desc, status, header, cur)" in service_body


def test_pure_ble_connection_drains_rx_inside_rx_callback():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    callback_body = text.split("proc nimConnSchProgCb", 1)[1].split(
        "proc nimLldConStart", 1
    )[0]
    rx_branch = callback_body.split("of 2'u8:", 1)[1].split(
        "of 0'u8, 1'u8, 4'u8, 7'u8, 0xFF'u8:", 1
    )[0]
    assert "serviceNimConnectionLlcpRxDescriptors()" in rx_branch
    assert "LLD connection frame callback drains RX descriptors" in rx_branch

    event_done_body = text.split("proc nimConnEventDone", 1)[1].split(
        "proc nimConnServiceSupervisionTimeout", 1
    )[0]
    assert "serviceNimConnectionLlcpRxDescriptors()" in event_done_body
    assert "nimConnAdvanceCsa1ChannelState(1'u16)" in event_done_body


def test_pure_ble_peripheral_primes_startup_version_procedure():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    prime_body = text.split("proc nimLlcpPrimeStartup", 1)[1].split(
        "proc nimLlcpTrySendStartup", 1
    )[0]
    assert "when bl808BleNimPureConnection:" in prime_body
    assert "nimLlcpConfigCount(bl808BleNimStartupLlcpRetries)" in prime_body
    assert "nim_llcp_state.versionProcedureStarted = false" in prime_body

    try_send_body = text.split("proc nimLlcpTrySendStartup", 1)[1].split(
        "proc nimLlcpObservePdu", 1
    )[0]
    assert "nim_conn_state.active and nim_conn_state.centralRole and" in try_send_body
    assert "not nim_conn_state.rxObserved" in try_send_body

    version_branch = text.split("of LlcpVersionInd:", 1)[1].split(
        "of LlcpLengthReq:", 1
    )[0]
    assert "if not nim_llcp_state.versionProcedureStarted:" in version_branch
    assert "nimLlcpBuildVersionInd()" in version_branch
    assert "nimLlcpQueuePdu(conhdl, rsp)" in version_branch


def test_polled_m0_ble_roles_use_interrupt_mask_helper():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "const bl808BleNimUseClicIrq* {.booldefine.}: bool = false" in text
    assert "const bl808BleNimRuntimeClicIrq =" in text
    assert "bl808BleNimUseClicIrq or bl808BleNimPureCentral" in text
    assert "const bl808BleNimDeferConnectInd* {.booldefine.}: bool = true" in text
    assert "writeBtbleInterruptMask(BtbleIntAdvertising)" in text
    assert "writeBtbleInterruptMask(BtbleIntConnection)" in text
    assert "enableBtbleInterruptMaskBits(BtbleIntEventTarget)" in text
    time_init = text.split("proc initBtbleTimeRegisters", 1)[1].split(
        "proc currentBtbleTime", 1
    )[0]
    assert "writeBtbleInterruptMask(0)" in time_init
    assert "writeBtbleInterruptMask(BtbleIntLegacyScheduler)" not in time_init

    assert "regWrite((BLE_BASE + 0x018'u32).uint, 0x00008026'u32)" not in text
    assert "regWrite((BLE_BASE + 0x018'u32).uint, 0x000080A6'u32)" not in text
    assert "regWrite((BLE_BASE + 0x018'u32).uint, 0x0000800E'u32)" not in text
    assert "regOr(BLE_BASE + 0x018'u32, 0x00000020'u32)" not in text

    interrupt_body = text.split(
        "proc bflbble_isr*() {.exportc, cdecl.} =", 1
    )[1].split(
        "proc bleControllerPoll", 1
    )[0]
    assert "serviceBtbleAdvRxDescriptors()" in interrupt_body
    assert "not bl808BleNimRuntimeClicIrq" in interrupt_body
    assert "serviceQueuedNimConnectInd()" in interrupt_body

    irq_restore = text.split("proc btbleIrqRestore", 1)[1].split(
        "proc swResetCfg0", 1
    )[0]
    assert "when defined(bl808m0) and not bl808BleNimRuntimeClicIrq:" in irq_restore
    assert "disableM0ClicDeliveryForPolledBle()" in irq_restore
    assert "core.csrWriteMstatus(saved)" in irq_restore


def test_connect_ind_handoff_waits_for_advertising_scheduler_end():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    adv_cb_body = text.split("proc nimSchProgCb", 1)[1].split(
        "proc pushBtbleAdvProgram", 1
    )[0]
    assert "nim_adv_sch_event_active = 0" in adv_cb_body
    assert "of 0'u8, 1'u8, 4'u8, 7'u8, 0xFF'u8:" in adv_cb_body

    adv_push_body = text.split("proc pushBtbleAdvProgram", 1)[1].split(
        "proc scheduleBtbleEvent", 1
    )[0]
    assert "nim_adv_sch_event_active = 1" in adv_push_body
    assert "sch_prog_push(addr nim_sch_prog[0])" in adv_push_body

    queued_body = text.split("proc serviceQueuedNimConnectInd", 1)[1].split(
        "proc handleNimConnectInd", 1
    )[0]
    assert "if nim_adv_sch_event_active != 0'u32:" in queued_body
    assert "if nim_adv_enabled:" in queued_body
    assert "nim_adv_sch_event_active = 0" in queued_body
    assert "startNimConnectionFromConnectInd(" in queued_body

    handoff_quiesce = text.split(
        "proc quiesceNimAdvertisingForConnectionHandoff", 1
    )[1].split("proc btbleTargetExpired", 1)[0]
    assert "nim_adv_enabled = false" in handoff_quiesce
    assert "nim_adv_target_half_us = 0" in handoff_quiesce
    assert "nim_adv_sch_event_active = 0" in handoff_quiesce
    assert "BtbleEventTargetEnableBit = 0x00004000'u32" in text
    assert "regOr(BLE_BASE + 0x9C0'u32, BtbleEventTargetEnableBit)" in (
        handoff_quiesce
    )
    assert "regWrite((BLE_BASE + 0x9C0'u32).uint, 0'u32)" not in (
        handoff_quiesce
    )
    assert (
        "regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, BtbleIntEventTarget)"
        in handoff_quiesce
    )

    peripheral_handoff = text.split(
        "proc startNimConnectionFromConnectInd", 1
    )[1].split("proc serviceQueuedNimConnectInd", 1)[0]
    assert "quiesceNimAdvertisingForConnectionHandoff()" in peripheral_handoff
    assert peripheral_handoff.index(
        "quiesceNimAdvertisingForConnectionHandoff()"
    ) < peripheral_handoff.index("prepareBtbleConnectionRxRingForHandoff()")

    clic_delivery = text.split("proc disableM0ClicDeliveryForPolledBle", 1)[1].split(
        "proc quiesceM0PolledBleClicSources", 1
    )[0]
    assert "core.csrWriteMie(core.csrReadMie() and not (1'u shl 11))" in (
        clic_delivery
    )
    assert "core.disableInterrupts()" in clic_delivery
    quiesce_body = text.split("proc quiesceM0PolledBleClicSources", 1)[1].split(
        "proc btbleIrqSave", 1
    )[0]
    assert "disableM0ClicDeliveryForPolledBle()" in quiesce_body
    assert "nimDisableM0RfClicIrq()" in quiesce_body
    assert "nimDisableM0BleClicIrq()" in quiesce_body

    write_helper = text.split("proc writeBtbleInterruptMask", 1)[1].split(
        "proc enableBtbleInterruptMaskBits", 1
    )[0]
    assert "when defined(bl808m0) and not bl808BleNimRuntimeClicIrq:" in write_helper
    assert "nim_btble_polled_intmask = mask" in write_helper
    assert "quiesceM0PolledBleClicSources()" in write_helper
    assert "regWrite((BLE_BASE + BTBLE_INTMASK_OFFSET).uint, mask)" in write_helper
    assert "regWrite((BLE_BASE + BTBLE_INTMASK_OFFSET).uint, 0'u32)" not in write_helper

    enable_helper = text.split("proc enableBtbleInterruptMaskBits", 1)[1].split(
        "proc invokeOnChipHci", 1
    )[0]
    assert "when defined(bl808m0) and not bl808BleNimRuntimeClicIrq:" in enable_helper
    assert "nim_btble_polled_intmask = nim_btble_polled_intmask or mask" in enable_helper
    assert "quiesceM0PolledBleClicSources()" in enable_helper
    assert "regOr(BLE_BASE + BTBLE_INTMASK_OFFSET, mask)" in enable_helper
    assert "regWrite((BLE_BASE + BTBLE_INTMASK_OFFSET).uint, 0'u32)" not in enable_helper

    interrupt_body = text.split(
        "proc bflbble_isr*() {.exportc, cdecl.} =", 1
    )[1].split(
        "proc bleControllerPoll", 1
    )[0]
    assert "BTBLE_INTDETAIL_OFFSET = 0x24'u32" in text
    assert "let detail = regRead(BLE_BASE + BTBLE_INTDETAIL_OFFSET)" in interrupt_body
    assert "legacySchedulerPending" in interrupt_body
    assert "((detail and 0x0000001E'u32) != 0)" in interrupt_body
    assert "if legacySchedulerPending:" in interrupt_body
    assert "defined(bl808BleVendorLldScanProbe)" not in interrupt_body
    assert "if nim_scan_enabled:\n      serviceAdvRx = true" in interrupt_body
    assert "bleControllerServiceScan()" in interrupt_body
    assert "nimSchProgElapsedIsr()" in interrupt_body
    assert "not legacySchedulerPending" in interrupt_body


def test_pure_advertising_scheduler_uses_committed_fifo_slot_metadata():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "proc btbleAdvSlotTail" in text

    clear_body = text.split("proc clearBtbleProgramSlots", 1)[1].split(
        "const\n  BtbleRxDescRingBaseOffset", 1
    )[0]
    assert "for slot in 0'u32 ..< 18'u32:" in clear_body
    assert "btbleAdvSlotTail(slot)" in clear_body
    assert "if slot < 10'u32:" not in clear_body

    adv_push_body = text.split("proc pushBtbleAdvProgram", 1)[1].split(
        "proc scheduleBtbleEvent", 1
    )[0]
    schprog_body = adv_push_body.split("bl808BleNimSchProgEnabled:", 1)[1].split(
        "return", 1
    )[0]
    assert "let slot = uint32(schProgWriteIdx and 0x0F'u8)" in schprog_body
    assert "let slotTail = btbleAdvSlotTail(slot)" in schprog_body
    assert "BTBLE_EM_BASE + slot * 0x10'u32" in schprog_body
    assert "sch_prog_push(addr nim_sch_prog[0])" in schprog_body
    assert "mod 16'u32" in schprog_body
    assert "uint32(nim_adv_schedule_slot) mod 10'u32" not in schprog_body


def test_pure_scheduler_initializes_reference_slice_defaults():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    body = text.split("proc initBtbleLinkLayerRegisters", 1)[1].split(
        "proc initBleCoreRegisters", 1
    )[0]
    assert "sch_slice_params[0] = 0xFFFF'u16" in body
    assert "sch_slice_params[1] = 0xFFFF'u16" in body
    assert "sch_slice_params[2] = 0x57E4'u16" in body
    assert "sch_slice_params[3] = 0'u16" in body


def test_wireless_domain_preserves_wifi_only_when_coex_enabled():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    body = text.split("proc wifiMacLooksActive", 1)[1].split(
        "proc prepareWirelessDomain", 1
    )[0]
    assert "if nim_ble_wlcoex_enabled == 0'u32:" in body
    assert "return false" in body
    assert "MachwBcnStatus" in body


def test_pure_ble_controller_has_no_vendor_scan_or_init_scheduler_branches():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    for forbidden in [
        "normalizeVendorLldInitArbElement",
        "normalizeVendorLldScanArbElement",
        "programVendorLldInitiator",
        "programVendorLldScan",
        "vendorLldInitStart",
        "vendorLldScanStart",
        "nim_vendor_init_",
        "bl808BleVendorLldScanProbe",
        "bl808BleVendorLldInitProbe",
        "vendorZeroStub",
        "vendorLlcpHandler",
    ]:
        assert forbidden not in text

    arb_body = text.split("proc sch_arb_insert*", 1)[1].split(
        "proc sch_arb_remove*", 1
    )[0]
    assert "discard elt" in arb_body
    assert arb_body.rstrip().endswith("0")


def test_pure_ble_initiator_uses_hci_create_connection_params():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "proc programNimInitiator" in text
    init_body = text.split("proc programNimInitiator", 1)[1].split(
        "proc nimInitReleasePendingRxDesc", 1
    )[0]
    assert "nimInitValidCreateConnectionParams(params, paramLen)" in init_body
    assert "ensureBleRf1MConfigured()" in init_body
    assert "for i in 0 ..< nim_init_hci_params.len:" in init_body
    assert "nim_init_hci_params[i] = cast[ptr UncheckedArray[uint8]](params)[i]" in (
        init_body
    )
    assert "nim_scan_enabled = false" in init_body
    assert "nim_init_active = 1" in init_body
    assert "nimInitBuildConnReqData()" in init_body
    assert "pushNimInitiatorProgram()" in init_body


def test_polled_scheduler_services_elapsed_frame_ends():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    elapsed_body = text.split("proc sch_prog_elapsed_isr*", 1)[1].split(
        "proc sch_prog_init*", 1
    )[0]
    assert "currentBtbleTime()" in elapsed_body
    assert "schProgClockReached(now, schProgElapsedEndTarget[slot.int])" in (
        elapsed_body
    )
    assert "schProgFinishSlot(slot, 0'u8)" in elapsed_body
    assert "rwip_mac_done_set()" in elapsed_body

    push_body = text.split("proc sch_prog_push*", 1)[1].split(
        "proc nimSchProgInit", 1
    )[0]
    assert "schProgElapsedEndTarget[slot.int]" in push_body
    assert "schProgDurationSlots(dur)" in push_body
    assert "schProgElapsedEndArmed[slot.int] = 1" in push_body


def test_btble_command_waits_are_bounded_and_diagnostic():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "BtbleCommandPollLimit = 100_000'u32" in text
    assert "nim_btble_cmd_wait_timeout_count" in text
    assert "nim_btble_cmd_wait_last_reg" in text
    assert "proc waitBtbleCommandDone" in text

    helper_body = text.split("proc waitBtbleCommandDone", 1)[1].split(
        "proc bflbble_isr", 1
    )[0]
    assert "while (regRead(reg) and BtbleBusyBit) != 0'u32:" in helper_body
    assert "inc nim_btble_cmd_wait_timeout_count" in helper_body

    for forbidden in [
        "while (regRead((BLE_BASE + 0x000'u32).uint) and 0x80000000'u32)",
        "while (regRead((BLE_BASE + 0x100'u32).uint) and 0x80000000'u32)",
        "while (regRead((BLE_BASE + 0x800'u32).uint) and 0x80000000'u32)",
        "while (regRead(BLE_BASE + BLE_BASETIMECNT_OFFSET) and 0x80000000'u32)",
        "while true:\n    let v = regRead(BLE_BASE + BLE_BASETIMECNT_OFFSET)",
    ]:
        assert forbidden not in text

    for start, end in [
        ("proc initBtbleTimeRegisters() =", "proc currentBtbleTime"),
        ("proc currentBtbleTime(): uint32 =", "proc currentBtbleHalfUs"),
        ("proc currentBtbleHalfUs(): uint32 =", "proc requestBtbleSwInterrupt"),
        ("proc resetBtbleLinkLayerCore() =", "proc writeBtbleAdvRxDescHeadIndex"),
        (
            "proc ea_time_get_halfslot_rounded*(): uint32 {.exportc, cdecl.} =",
            "proc ea_time_get_slot_rounded",
        ),
        (
            'proc patch_ke_time*(): uint32 {.exportc: "_patch_ke_time", cdecl.} =',
            "proc ble_ke_time*",
        ),
    ]:
        body = text.split(start, 1)[1].split(end, 1)[0]
        assert "waitBtbleCommandDone" in body

    patch_ke_time_body = text.split(
        'proc patch_ke_time*(): uint32 {.exportc: "_patch_ke_time", cdecl.} =',
        1,
    )[1].split("proc ble_ke_time*", 1)[0]
    assert "waitBtbleCommandDone((BLE_BASE + BLE_BASETIMECNT_OFFSET).uint" in patch_ke_time_body
    assert "while true:" not in patch_ke_time_body


def test_host_hci_events_are_drained_outside_controller_callback():
    source = REPO_ROOT / "src" / "bl808" / "ble.nim"
    text = source.read_text(encoding="utf-8")

    bridge_body = text.split("proc bleHostBridge", 1)[1].split(
        "proc bt_onchiphci_interface_init", 1
    )[0]
    poll_body = text.split("proc blePollHostEvents*", 1)[1].split(
        "proc handleDisconnectionComplete", 1
    )[0]

    assert "enqueueHciHostEvent(pktType, srcId, param, paramLen)" in bridge_body
    assert "hciRecvCb(cbParam, cbLen)" not in bridge_body
    assert "drainHciHostEvents()" in poll_body
    assert "hciDispatchPktType == HciPktAclData" in text
    assert "resetHciEventQueue()" in text.split(
        "proc bt_onchiphci_interface_init*", 1
    )[1].split("proc bt_onchiphci_send*", 1)[0]


def test_central_poll_loop_drains_queued_hci_events():
    source = REPO_ROOT / "src" / "bl808" / "ble.nim"
    text = source.read_text(encoding="utf-8")

    poll_body = text.split("proc bleBackendPollCentralController", 1)[1].split(
        "proc pollCentralController", 1
    )[0]
    assert "blecontroller.bleControllerDrainScanReports()" in poll_body
    assert poll_body.count("drainHciHostEvents()") >= 2
    assert poll_body.index("blecontroller.bleControllerDrainScanReports()") < poll_body.index(
        "drainHciHostEvents()"
    )


def test_central_connect_waits_after_successful_create_connection():
    source = REPO_ROOT / "src" / "bl808" / "ble.nim"
    text = source.read_text(encoding="utf-8")

    create_le_body = text.split("proc bt_conn_create_le*", 1)[1].split(
        "proc bt_conn_disconnect*", 1
    )[0]
    assert "drainHciHostEvents()" in create_le_body
    assert "defined(bl808BleVendor)" not in create_le_body
    assert create_le_body.index("hciCommandOk(HciOpLeCreateConnection") < create_le_body.index(
        "drainHciHostEvents()"
    )

    connect_body = text.split("proc bleCentralConnectByName*", 1)[1].split(
        "proc bleDisconnectCurrent*", 1
    )[0]
    create_body = connect_body.split(
        "if bt_conn_create_le(addr bleCentralPeer, addr connParam) == nil:", 1
    )[1].split("delayUs(1000)", 1)[0]
    failed_create_body, after_failed_return = create_body.split("return -1", 1)
    successful_create_body = create_body.split(
        "ble_central_debug_stage = 0x5540'u32", 1
    )[1]

    assert "bleConnPending = false" in failed_create_body
    assert "ble_central_debug_stage = 0x5540'u32" in after_failed_return
    assert "return -1" not in successful_create_body
    assert "connectStarted = true" in successful_create_body
    assert "bleConnPending = false" not in successful_create_body


def test_central_connect_delivers_connected_callback_before_success_return():
    source = REPO_ROOT / "src" / "bl808" / "ble.nim"
    text = source.read_text(encoding="utf-8")

    assert "bleConnConnectedNotified: bool" in text
    notify_body = text.split("proc notifyConnected", 1)[1].split(
        "proc notifyDisconnected", 1
    )[0]
    assert "bleConnConnectedNotified = true" in notify_body

    connect_body = text.split("proc bleCentralConnectByName*", 1)[1].split(
        "proc bleDisconnectCurrent*", 1
    )[0]
    success_branch = connect_body.split("if bleCentralConnected:", 1)[1].split(
        "when defined(BleCentralReturnAfterHandoffForSnapshot):", 1
    )[0]
    assert "if not bleConnConnectedNotified:" in success_branch
    assert "notifyConnected(bleConn.status)" in success_branch
    assert success_branch.index("notifyConnected(bleConn.status)") < success_branch.index(
        "return 0"
    )


def test_central_disconnect_wait_drains_queued_hci_events():
    source = REPO_ROOT / "src" / "bl808" / "ble.nim"
    text = source.read_text(encoding="utf-8")

    disconnect_body = text.split("proc bleDisconnectCurrent*", 1)[1].split(
        "# =============================================================================", 1
    )[0]
    assert "bt_conn_disconnect(addr bleConn, reason)" in disconnect_body
    assert (
        "bt_conn_disconnect(addr bleConn, reason) != 0:\n"
        "      return -1\n"
        "    drainHciHostEvents()"
        in disconnect_body
    )
    assert "bleBackendServiceDisconnectWait()" in disconnect_body
    assert "defined(bl808BleVendor)" not in disconnect_body


def test_hci_disconnect_stops_pure_connection_scheduler_state():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    disconnect_complete = text.split("proc sendDisconnectComplete", 1)[1].split(
        "when defined(bl808m0):", 1
    )[0]
    assert "clearNimConnectionStateForDisconnect(reason)" in disconnect_complete
    assert "nim_conn_active = false" in disconnect_complete
    assert "nim_conn_handle = 0" in disconnect_complete

    cleanup = text.split("proc clearNimConnectionStateForDisconnect", 1)[1].split(
        "proc noteNimPeripheralDisconnectedFrom", 1
    )[0]
    assert "nim_conn_started = false" in cleanup
    assert "nim_init_active = 0" in cleanup
    assert "nim_conn_state.active = false" in cleanup
    assert "nim_conn_state.reschedulePending = false" in cleanup
    assert "nim_llcp_tx_pending = 0" in cleanup
    assert "writeBtbleInterruptMask(0)" in cleanup

    hci_disconnect = text.split("of HciOpDisconnect:", 1)[1].split(
        "of HciOpLeSetRandomAddress:", 1
    )[0]
    assert "sendDisconnectComplete(handle, req.reason)" in hci_disconnect


def test_clic_startup_matches_reference_vector_return_semantics():
    source = REPO_ROOT / "src" / "bl808" / "startup.nim"
    text = source.read_text(encoding="utf-8")

    assert "void (*const __trap_vector_table[128])(void)" in text
    assert '[0 ... 127] = __clic_interrupt_handler' in text
    assert "void __clic_interrupt_handler(void)" in text
    assert '".rept 128\\n"' not in text
    assert '"j __clic_interrupt_handler\\n"' not in text

    lp_vector_handler = text.split(
        "void __clic_interrupt_handler(void) {\n    asm volatile", 1
    )[1].split("# LP E902", 1)[0]
    assert '"call trap_vector_entry\\n"' in lp_vector_handler
    assert '"mret\\n"' in lp_vector_handler
    assert '"ret\\n"' not in lp_vector_handler

    m0_vector_handler = text.split(
        "# M0 (RV32I) trap handler", 1
    )[1].split("when defined(bl808TrapFrameDiag):", 1)[0]
    assert '"call trap_vector_entry\\n"' in m0_vector_handler
    assert '".word 0x0040000b\\n"' not in m0_vector_handler
    assert '".word 0x0050000b\\n"' not in m0_vector_handler
    assert '"sw ra, 0(sp)\\n"' in m0_vector_handler
    assert '"sw s0, 24(sp)\\n"' in m0_vector_handler
    assert '"sw s11, 100(sp)\\n"' in m0_vector_handler
    assert '"csrr t0, mscratch\\n"' in m0_vector_handler
    assert '"csrw mscratch, t0\\n"' in m0_vector_handler
    assert '"lw ra, 0(sp)\\n"' in m0_vector_handler
    assert '"lw s0, 24(sp)\\n"' in m0_vector_handler
    assert '"lw s11, 100(sp)\\n"' in m0_vector_handler
    assert '"mret\\n"' in m0_vector_handler
    assert '"call trap_entry\\n"' not in m0_vector_handler

    m0_spush_disable = text.split(
        "/* Match the SDK SystemInit: disable SPUSH/SPSWAP for ipush/ipop. */",
        1,
    )[1].split("/* Set CLIC vector bases", 1)[0]
    m0_clic_start = text.split(
        "/* Set CLIC vector bases: mtvt handles vector IRQs, mtvec handles exceptions. */",
        1,
    )[1].split("/* Clear BSS */", 1)[0]
    assert (
        '        /* Match the SDK SystemInit: disable SPUSH/SPSWAP for ipush/ipop. */'
        in text
    )
    assert (
        '"csrr t0, 0x7e1\\n"\n'
        '        "li t1, ~(0x3 << 16)\\n"\n'
        '        "and t0, t0, t1\\n"\n'
        '        "csrw 0x7e1, t0\\n"'
        in m0_spush_disable
    )
    assert (
        '        /* Set CLIC vector bases'
        in text
    )
    assert '"la t0, __trap_vector_table\\n"' in m0_clic_start
    assert '"csrw 0x307, t0\\n"' in m0_clic_start
    assert (
        '"la t0, __trap_handler\\n"\n'
        '        "ori t0, t0, 0x3\\n"'
        in m0_clic_start
    )
    assert '"ori t0, t0, 0x3\\n"' in m0_clic_start


def test_clic_init_uses_reference_vector_attributes():
    irq_source = REPO_ROOT / "src" / "bl808" / "irq.nim"
    irq_text = irq_source.read_text(encoding="utf-8")
    ble_source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    ble_text = ble_source.read_text(encoding="utf-8")

    assert "ClicAttrNonVector* = 0x00'u8" in irq_text
    assert "ClicAttrVector* = 0x01'u8" in irq_text
    assert "proc clicDefaultAttr*(): uint8" in irq_text
    default_attr = irq_text.split("proc clicDefaultAttr*", 1)[1].split(
        "proc m0McuIntSourceIndex", 1
    )[0]
    assert "when defined(bl808directtrap):" in default_attr
    assert "ClicAttrNonVector" in default_attr
    assert "ClicAttrVector" in default_attr

    init_body = irq_text.split("proc clicInit*() =", 1)[1].split(
        "const IrqMExt", 1
    )[0]
    assert "clicSetAttr(i, clicDefaultAttr())" in init_body
    assert "clicSetAttr(i, 0)" not in init_body

    disable_body = ble_text.split("proc nimDisableM0ClicIrq", 1)[1].split(
        "proc nimDisableM0BleClicIrq", 1
    )[0]
    assert "clicSetAttr(irq, clicDefaultAttr())" in disable_body
    assert "clicSetAttr(irq, 0)" not in disable_body


def test_clic_vector_interrupts_do_not_share_exception_pending_scan():
    source = REPO_ROOT / "src" / "bl808" / "irq.nim"
    text = source.read_text(encoding="utf-8")

    assert "proc vectorTrapEntry*" in text
    vector_body = text.split("proc vectorTrapEntry*", 1)[1].split(
        "proc defaultTrapEntry*", 1
    )[0]
    assert "dispatchClicVectorInterrupt((cause and 0x3FF'u).uint32)" in vector_body

    trap_body = text.split("proc defaultTrapEntry*", 1)[1].split(
        "else:\n    lastTrapCause", 1
    )[0]
    assert "clicClaimPending" not in trap_body
    assert "clicClearDisabledPending" not in trap_body
    assert "cause and 0x30000000'u" not in trap_body
    assert "if isInterrupt:" in trap_body
    assert "dispatchClicVectorInterrupt(irqCode)" in trap_body


def test_ble_diag_time_sampling_is_opt_in():
    source = REPO_ROOT / "examples" / "m0_ble_hal_test.nim"
    text = source.read_text(encoding="utf-8")

    assert "bl808BleDiagSampleTime {.booldefine.}: bool = false" in text
    sample_body = text.split("proc sampleBleTime() =", 1)[1].split(
        "proc bleDbgReg32", 1
    )[0]
    assert "when bl808BleDiagSampleTime:" in sample_body
    assert "0x80000000'u32" in sample_body


def test_m0_linker_reserves_top_of_ram_stack_margin():
    source = REPO_ROOT / "src" / "linker" / "bl808_m0.ld"
    text = source.read_text(encoding="utf-8")

    assert "ORIGIN = 0x62020000, LENGTH = 64K" in text
    assert "0x62053xxx can alias" in text
    assert "LENGTH = 208K" not in text
    assert "_stack_top_reserve = 512;" in text
    assert "LENGTH(RAM) - _stack_top_reserve - _stack_size" in text
    assert "LENGTH(RAM) - _stack_top_reserve" in text


def test_m0_ble_p256_uses_pka_for_secret_scalar_work_not_public_validation():
    ble = (REPO_ROOT / "src" / "bl808" / "ble.nim").read_text(encoding="utf-8")
    blep256 = (REPO_ROOT / "src" / "bl808" / "blep256.nim").read_text(
        encoding="utf-8"
    )

    assert "import blep256" in ble
    assert "p256IsValidPublicKeyLe" not in ble
    assert "bl808BleP256UsePka* {.booldefine.}: bool = true" in blep256
    assert "proc bleP256IsValidPublicKeyLe*(x, y: ptr uint8): bool" in blep256
    assert "p256IsValidPublicKeyLe(x, y)" in blep256
    assert "not p256IsValidPublicKeyLe(pointX, pointY)" not in blep256


def test_ble_scheduler_program_path_uses_pure_nim_names():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    for forbidden in [
        "bl808BleWrapLldConStartDiag",
        "__real_vendor_lld_con_start",
        "__wrap_vendor_lld_con_start",
        "vendorSchProgInit",
        "vendorSchProgFifoIsr",
        "vendorSchProgSkipIsr",
        "vendorSchProgPush",
        "vendorSchProgElapsedIsr",
        "vendorSchProgSkipIndex",
        "vendorProgWrite16",
        "vendorProgWrite32",
        "vendorLldConStart",
        "vendorLldConDataTx",
        "vendorLldConLlcpTx",
        "startVendorLldConnectionFromConnectInd",
        "handleVendorConnectInd",
        "serviceQueuedVendorConnectInd",
        "serviceVendorArbTimer",
        "activeVendorConnectionHandle",
        "noteVendorRxDescConsumed",
        "refreshVendorSyncPositions",
        "vendorConnectTiming",
        "runVendorArbCallback",
        "queueVendorArbCallback",
        "serviceVendorArbCallbacks",
        "drainVendorInitPeerComplete",
        "initVendorRwipRfTable",
        "recordVendorPeripheralPeer",
        "noteVendorPeripheralConnected",
        "noteVendorAdvertiserConnected",
        "noteVendorPeripheralDisconnectedFrom",
        "noteVendorPeripheralDisconnected",
        "handleVendorLldMessage",
        "serviceVendorConnectionLlcpRxDescriptors",
        "proc vendorLlcStart(",
        "VendorLlcpState",
        "VendorLlcpPdu",
        "NimVendorLlcpTxEmOffset",
        "NimVendorAclTxEmOffset",
        "NimVendorRxDescDone",
        "NimVendorDataLlIdControl",
        "vendorRecordLlcpRx",
        "vendorLlcpRxPduValid",
        "vendorBuildFeaturePdu",
        "vendorQueueLlcpPdu",
        "vendorPrimeStartupLlcp",
        "vendorTrySendStartupLlcp",
        "vendorHandleConsumedLlcp",
        "NimVendorLlcStartEnvView",
        "VendorLldConStartParamsView",
        "VendorLlcControllerDefaultsView",
        "VendorLlcStartParamsView",
        "VendorLldAdvParamsView",
        "VendorLldScanParamsView",
        "VendorLldInitParamsView",
        "vendorOverlay",
        "nimVendorSchProgCb",
        "var nim_vendor_sch_prog",
        "addr nim_vendor_sch_prog",
        "nim_vendor_lld_adv_params",
        "nim_vendor_lld_adv_rand_state",
        "nimVendorLlcMsgWord",
        "printNimVendorLlcMsg",
        "nimVendorReadRa",
        "nimVendorReadSp",
        "nimVendorConnMark",
    ]:
        assert forbidden not in text

    for expected in [
        "proc nimSchProgCb(arg0: uint32, ctx: pointer,",
        "proc nimSchProgInit(initType: uint8)",
        "proc nimSchProgFifoIsr()",
        "proc nimSchProgSkipIsr(idx: uint8)",
        "proc nimSchProgPush(prog: pointer)",
        "proc nimSchProgElapsedIsr()",
        'var nimSchProgSkipIndex {.exportc: "m_sw_skip_et_idx".}: uint32',
        "proc schProgWrite16(off: int, value: uint16)",
        "proc schProgWrite32(off: int, value: uint32)",
        "proc nimLldConStart(conhdl: uint16, params: pointer): uint8",
        "proc nimLldConDataTx(conhdl: uint16, buf: pointer): uint8",
        "proc nimLldConLlcpTx(conhdl: uint16, buf: pointer): uint8",
        "proc lld_con_data_tx*(conhdl: uint16, buf: pointer): uint8",
        "proc lld_con_llcp_tx*(conhdl: uint16, buf: pointer): uint8",
        "proc startNimConnectionFromConnectInd(descIdx: uint8,",
        "proc handleNimConnectInd(descIdx: uint8,",
        "proc serviceQueuedNimConnectInd()",
        "proc serviceNimArbTimer()",
        "proc activeNimConnectionHandle(): uint16",
        "proc noteNimRxDescConsumed(idx: uint32)",
        "proc refreshNimSyncPositions()",
        "proc nimConnectTiming(baseClock: uint32",
        "proc runNimArbCallback(cb: SchArbStartCb",
        "proc queueNimArbCallback(cb: SchArbStartCb",
        "proc serviceNimArbCallbacks()",
        "proc drainNimInitPeerComplete(): bool",
        "proc initNimRwipRfTable()",
        "proc recordNimPeripheralPeer(conhdl: uint16,",
        "proc noteNimPeripheralConnected(conhdl: uint16)",
        "proc noteNimAdvertiserConnected(raw: ptr UncheckedArray[uint8],",
        "proc noteNimPeripheralDisconnectedFrom(source: uint32, reason: uint8)",
        "proc noteNimPeripheralDisconnected(reason: uint8)",
        "proc handleNimLldMessage(param: pointer): bool",
        "proc serviceNimConnectionLlcpRxDescriptors()",
        "proc nimLlcStart(conhdl: uint16, params: pointer): uint8",
        '{.exportc: "vendor_llc_start", cdecl.}',
        "NimLlcpState = object",
        "NimLlcpPdu = object",
        "NimLlcpTxEmOffset = 0x0788'u16",
        "NimAclTxEmOffset = 0x0A20'u16",
        "NimRxDescDone = 0x8000'u16",
        "NimDataLlIdControl = 0x03'u8",
        "proc nimLlcpRecordRx(header: uint16, dataOff: uint16, pduLen: uint16)",
        "proc nimLlcpRxPduValid(opcode: uint8, pduLen: uint16): bool",
        "proc nimLlcpBuildFeaturePdu(",
        "proc nimLlcpQueuePdu(conhdl: uint16, pdu: ptr UncheckedArray[uint8],",
        "proc nimLlcpPrimeStartup()",
        "proc nimLlcpTrySendStartup(conhdl: uint16)",
        "proc nimLlcpHandleConsumed(conhdl: uint16,",
        "NimLlcStartEnvView {.packed.} = object",
        "NimLldConStartParamsView {.packed.} = object",
        "NimLlcControllerDefaultsView {.packed.} = object",
        "NimLlcStartParamsView {.packed.} = object",
        "NimLldAdvParamsView {.packed.} = object",
        "NimLldScanParamsView {.packed.} = object",
        "NimLldInitParamsView {.packed.} = object",
        "controllerOverlay*: array[28, uint8]",
        "var nim_sch_prog_fifo_count* {.exportc: \"nim_vendor_sch_prog_fifo_count\".}: uint32",
        "var nim_llc_msg* {.exportc: \"nim_vendor_llc_msg\".}: array[64, uint8]",
        "proc nimConnMark(stage: uint32) {.inline.}",
    ]:
        assert expected in text

    for line in text.splitlines():
        if "nim_vendor_" in line:
            assert "exportc:" in line


def test_ble_ke_heap_end_uses_typed_byte_overlay():
    source = REPO_ROOT / "src" / "bl808" / "blecontroller.nim"
    text = source.read_text(encoding="utf-8")
    body = text.split(
        "proc btble_ke_mem_init*(mtype: uint8, heap: ptr uint8, size: uint16)",
        1,
    )[1].split("proc btble_ke_mem_is_empty*", 1)[0]

    assert "ke_mem_heap_end = addr cast[ptr UncheckedArray[uint8]](heap)[size.int]" in body
    assert "cast[uint](heap) + size.uint" not in body
