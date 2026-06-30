import subprocess
import shutil
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def nim_source_with_includes(path: Path) -> str:
    lines = []
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("include "):
            include_name = stripped.split(None, 1)[1].split("#", 1)[0].strip()
            include_rel = include_name.replace(".", "/") + ".nim"
            include_path = path.parent / include_rel
            if not include_path.exists():
                include_path = ROOT / "src/bl808/wifi" / include_rel
            if include_path.exists():
                indent = line[: len(line) - len(line.lstrip())]
                included = nim_source_with_includes(include_path)
                lines.append("\n".join(indent + included_line for included_line in included.splitlines()))
                continue
        lines.append(line)
    return "\n".join(lines)


def wifi_fw_policy_source() -> str:
    return "\n".join(
        [
            nim_source_with_includes(ROOT / "src/bl808/wifi_fw.nim"),
            (ROOT / "src/bl808/radio_phy.nim").read_text(),
            nim_source_with_includes(ROOT / "src/bl808/wifi/fw_constants.nim"),
            nim_source_with_includes(ROOT / "src/bl808/wifi/fw_messages.nim"),
        ]
    )


def wifi_fw_policy_paths() -> list[Path]:
    return [
        ROOT / "src/bl808/wifi_fw.nim",
        *sorted((ROOT / "src/bl808/wifi/fw").glob("*.nim")),
    ]


def blecontroller_policy_source() -> str:
    return nim_source_with_includes(ROOT / "src/bl808/blecontroller.nim")

def blecontroller_policy_paths() -> list[Path]:
    return [
        ROOT / "src/bl808/blecontroller.nim",
        *sorted((ROOT / "src/bl808/blecontroller").glob("*.nim")),
    ]


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


def test_wifi_mod_params_alignment_fields_are_semantic():
    state = (ROOT / "src/bl808/wifi/mod_params/state.nim").read_text()

    for expected in [
        "htVhtAlignmentPadding: array[2, uint8]",
        "use2040AlignmentPadding: uint8",
        "listenBcmcAlignmentPadding: array[3, uint8]",
        "psOnAlignmentPadding: array[3, uint8]",
        "doAssert offsetof(BlModParams, htVhtAlignmentPadding) == 2",
        "doAssert offsetof(BlModParams, mcs_map) == 4",
        "doAssert offsetof(BlModParams, use2040AlignmentPadding) == 19",
        "doAssert offsetof(BlModParams, listenBcmcAlignmentPadding) == 25",
        "doAssert offsetof(BlModParams, psOnAlignmentPadding) == 33",
        "doAssert offsetof(BlModParams, uapsd_queues) == 44",
    ]:
        assert expected in state

    for forbidden in [
        "pad0:",
        "pad1:",
        "pad2:",
        "pad3:",
    ]:
        assert forbidden not in state


def test_ble_mac_address_read_uses_semantic_efuse_names():
    ble = blecontroller_policy_source()

    mac_body = ble.split("proc bl_read_mac_addr*", 1)[1].split(
        "proc bdaddr_init*", 1
    )[0]
    bdaddr_body = ble.split("proc bdaddr_init*", 1)[1].split(
        "# ---------------------------------------------------------------------------\n# ======================== BLE RF",
        1,
    )[0]

    for expected in [
        "let efuseMacLowWord = regRead(0x40007014'u)",
        "let efuseMacHighWord = regRead(0x40007018'u)",
        "for lowWordByteIndex in 0 ..< 4:",
        "macBytes[lowWordByteIndex] =",
        "efuseMacLowWord shr (lowWordByteIndex * 8)",
        "for highWordByteIndex in 0 ..< 2:",
        "macBytes[4 + highWordByteIndex] =",
        "efuseMacHighWord shr (highWordByteIndex * 8)",
        "var efuseMacAllZero = true",
        "var efuseMacAllOnesSentinel = true",
        "for macByteIndex in 0 ..< 6:",
        "let macByte = macBytes[macByteIndex]",
        "let fallbackBleMac = [0xC0'u8, 0x01, 0x02, 0x03, 0x04, 0x05]",
        "unsafeAddr fallbackBleMac[0]",
    ]:
        assert expected in mac_body

    for expected in [
        "var publicAddress: BdAddr",
        "bl_read_mac_addr(addr publicAddress.bytes[0])",
        "publicAddress.bytes[0] = publicAddress.bytes[0] + 1",
        "llm_util_set_public_addr(addr publicAddress)",
    ]:
        assert expected in bdaddr_body

    for forbidden in [
        "let lo =",
        "let hi =",
        "var all_zero",
        "var all_same",
        "let b =",
        "let default_mac",
        "addr_buf",
    ]:
        assert forbidden not in mac_body
        assert forbidden not in bdaddr_body


def test_ble_public_address_register_write_uses_semantic_word_names():
    ble = blecontroller_policy_source()

    body = ble.split("proc lld_util_set_bd_address*", 1)[1].split(
        "proc lld_util_get_local_offset*", 1
    )[0]

    for expected in [
        "let publicAddrLowWord = addr_in.bytes[0].uint32 or",
        "(addr_in.bytes[3].uint32 shl 24)",
        "let publicAddrHighWord = addr_in.bytes[4].uint32 or",
        "(addr_in.bytes[5].uint32 shl 8)",
        "regWrite(BLE_BASE + 0x24'u32, publicAddrLowWord)",
        "regWrite(BLE_BASE + 0x28'u32, publicAddrHighWord)",
        "for publicAddressByteIndex in 0 ..< nim_public_addr.len:",
        "nim_public_addr[publicAddressByteIndex] = addr_in.bytes[publicAddressByteIndex]",
    ]:
        assert expected in body

    for forbidden in [
        "let lo =",
        "let hi =",
        "nim_public_addr[i] = addr_in.bytes[i]",
        "regWrite(BLE_BASE + 0x24'u32, lo)",
        "regWrite(BLE_BASE + 0x28'u32, hi)",
    ]:
        assert forbidden not in body


def test_wifi_driver_hostname_clear_uses_semantic_byte_index_name():
    wifi_driver = nim_source_with_includes(ROOT / "src/bl808/wifi/driver.nim")

    body = wifi_driver.split("proc clearHostname()", 1)[1].split(
        "proc putHostnameChar", 1
    )[0]

    for expected in [
        "for hostnameByteIndex in 0 ..< wifiMgmr.hostname.len:",
        "wifiMgmr.hostname[hostnameByteIndex] = 0.cchar",
    ]:
        assert expected in body

    for forbidden in [
        "for i in 0 ..< wifiMgmr.hostname.len:",
        "wifiMgmr.hostname[i] = 0.cchar",
    ]:
        assert forbidden not in body


def test_wifi_runtime_random_uses_semantic_output_byte_index_name():
    random_facade = (
        ROOT / "src/bl808/wifi/support/runtime_facade_parts/random.nim"
    ).read_text()

    body = random_facade.split("proc os_get_random*", 1)[1]

    assert "proc os_get_random*(randomBytes: ptr uint8; length: csize_t): cint" in random_facade

    for expected in [
        "if randomBytes == nil: return -1",
        "for randomByteIndex in 0 ..< length.int:",
        "if (randomByteIndex and 3) == 0:",
        "ptrAt(randomBytes, randomByteIndex.uint)",
        "vendorRandomState shr ((randomByteIndex and 3) * 8)",
    ]:
        assert expected in body

    for forbidden in [
        "proc os_get_random*(buf: ptr uint8;",
        "if buf == nil: return -1",
        "for i in 0 ..< length.int:",
        "ptrAt(randomBytes, i.uint)",
        "vendorRandomState shr ((i and 3) * 8)",
    ]:
        assert forbidden not in body


def test_wifi_connect_info_fill_ssid_slot_uses_semantic_byte_indices():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split("proc connectInfoFillSsidSlot", 1)[1].split(
        "proc vifChannelCenterFreq1", 1
    )[0]

    for expected in [
        "for ssidSlotClearByteIndex in 0 ..< slot.ssidBytes.len:",
        "slot.ssidBytes[ssidSlotClearByteIndex] = 0",
        "let length = connectInfoSsidLen(ci)",
        "for ssidCopyByteIndex in 0 ..< length.int:",
        "slot.ssidBytes[ssidCopyByteIndex] = ci.ssid[ssidCopyByteIndex]",
    ]:
        assert expected in body

    for forbidden in [
        "for i in 0 ..< slot.ssidBytes.len:",
        "slot.ssidBytes[i] = 0",
        "for i in 0 ..< length.int:",
        "slot.ssidBytes[i] = ci.ssid[i]",
    ]:
        assert forbidden not in body


def test_wifi_mgmr_scan_uses_semantic_broadcast_bssid_names():
    scan_connect = (
        ROOT / "src/bl808/wifi/support/mgmr_facade_parts/scan_connect.nim"
    ).read_text()

    body = scan_connect.split("proc wifi_mgmr_scan*", 1)[1].split(
        "proc wifi_mgmr_sta_connect*", 1
    )[0]

    for expected in [
        "var broadcastBssid: array[6, uint8]",
        "for bssidByteIndex in 0 ..< broadcastBssid.len:",
        "broadcastBssid[bssidByteIndex] = 0xff",
        "cast[ptr MacAddr](addr broadcastBssid[0])",
    ]:
        assert expected in body

    for forbidden in [
        "var bssid: array[6, uint8]",
        "for i in 0 ..< 6:",
        "bssid[i] = 0xff",
        "addr bssid[0]",
    ]:
        assert forbidden not in body


def test_wifi_utils_bin2hex_uses_semantic_byte_and_output_names():
    bin_tlv_crc = (
        ROOT / "src/bl808/wifi/support/utils_facade_parts/bin_tlv_crc.nim"
    ).read_text()

    body = bin_tlv_crc.split("proc utils_bin2hex*", 1)[1].split(
        "proc utils_tlv_bl_unpack_auto*", 1
    )[0]
    crc_feed_body = bin_tlv_crc.split("proc utils_crc32_stream_feed_block*", 1)[1].split(
        "proc utils_crc32_stream_results*",
        1,
    )[0]

    for expected in [
        "let sourceBytes = cast[ptr UncheckedArray[uint8]](src)",
        "let hexOutputChars = cast[ptr UncheckedArray[char]](dst)",
        "for sourceByteIndex in 0 ..< srcLen.int:",
        "hexOutputChars[sourceByteIndex * 2] =",
        "hex[int(sourceBytes[sourceByteIndex] shr 4)]",
        "hexOutputChars[sourceByteIndex * 2 + 1] =",
        "hex[int(sourceBytes[sourceByteIndex] and 15)]",
        "hexOutputChars[srcLen.int * 2] = '\\0'",
    ]:
        assert expected in body

    for forbidden in [
        "let input =",
        "let outp =",
        "for i in 0 ..< srcLen.int:",
        "outp[i * 2]",
        "input[i]",
    ]:
        assert forbidden not in body

    for expected in [
        "for crcInputByteIndex in 0'u32 ..< length:",
        "ptrAt(data, crcInputByteIndex.uint)",
    ]:
        assert expected in crc_feed_body

    for forbidden in [
        "for i in 0'u32 ..< length:",
        "ptrAt(data, i.uint)",
    ]:
        assert forbidden not in crc_feed_body


def test_wifi_support_scan_diag_and_queue_slots_are_semantic():
    scan_diag = (ROOT / "src/bl808/wifi/support/scan_diag.nim").read_text()
    sync_queue = (
        ROOT / "src/bl808/wifi/support/os_adapter_parts/sync_queue.nim"
    ).read_text()

    store_body = scan_diag.split("proc scanDiagStore", 1)[1].split(
        "proc bl808_wifi_backend_scan_diag_count*",
        1,
    )[0]
    get_body = scan_diag.split("proc bl808_wifi_backend_scan_diag_get*", 1)[1].split(
        "proc wifiChannelToFreq",
        1,
    )[0]
    send_body = sync_queue.split("proc osQueueSendWait", 1)[1].split(
        "proc osQueueSend",
        1,
    )[0]
    recv_body = sync_queue.split("proc osQueueRecv", 1)[1]

    for expected in [
        "let scanDiagRingSlot = (scanItemCount mod VendorScanDiagMax.uint32).int",
        "scanDiag[scanDiagRingSlot].used = 1",
        "let ssidLength = loadI32(ind, WifiBeaconSsidLenOff)",
        "scanDiag[scanDiagRingSlot].ssidLen = ssidLength.uint8",
        "scanDiag[scanDiagRingSlot].channel = loadU8(ind, WifiBeaconChannelOff)",
    ]:
        assert expected in store_body

    for expected in [
        "let requestedScanDiagSlot = ((start + index) mod VendorScanDiagMax.uint32).int",
        "scanDiag[requestedScanDiagSlot].used",
        "scanDiag[requestedScanDiagSlot].ssidLen",
        "scanDiag[requestedScanDiagSlot].bssid",
    ]:
        assert expected in get_body

    for expected in [
        "let queueWriteStorageSlot =",
        "queueState.writeIdx mod queueState.depth",
        "copyMem(queueWriteStorageSlot, item, queueState.itemSize.uint)",
    ]:
        assert expected in send_body

    for expected in [
        "let queueReadStorageSlot =",
        "queueState.readIdx mod queueState.depth",
        "copyMem(item, queueReadStorageSlot, queueState.itemSize.uint)",
    ]:
        assert expected in recv_body

    for forbidden in [
        "let slot = (scanItemCount mod VendorScanDiagMax.uint32).int",
        "scanDiag[slot]",
        "let slot = ((start + index) mod VendorScanDiagMax.uint32).int",
        "let slot = ptrAt(queue",
        "copyMem(slot, item",
        "copyMem(item, slot",
        "scanDiag[scanDiagRingSlot].ssidLen = len.uint8",
    ]:
        assert forbidden not in store_body
        assert forbidden not in get_body
        assert forbidden not in send_body
        assert forbidden not in recv_body


def test_wifi_scan_connect_uses_vendor_style_cache_hint():
    scan_diag = (ROOT / "src/bl808/wifi/support/scan_diag.nim").read_text()
    callbacks = (
        ROOT / "src/bl808/wifi/support/mgmr_facade_parts/callbacks.nim"
    ).read_text()
    scan_connect = (
        ROOT / "src/bl808/wifi/support/mgmr_facade_parts/scan_connect.nim"
    ).read_text()

    cache_store_body = scan_diag.split("proc scanCacheStore", 1)[1].split(
        "proc scanCacheFind",
        1,
    )[0]
    cache_find_body = scan_diag.split("proc scanCacheFind", 1)[1].split(
        "proc scanDiagStore",
        1,
    )[0]
    scan_body = scan_connect.split("proc wifi_mgmr_scan*", 1)[1].split(
        "proc wifi_mgmr_sta_connect*",
        1,
    )[0]
    connect_body = scan_connect.split("proc wifi_mgmr_sta_connect*", 1)[1].split(
        "proc wifi_mgmr_sta_disconnect*",
        1,
    )[0]

    for expected in [
        "var scanCache {.allcoreHttpPsramBss.}: array[VendorScanDiagMax, ScanCacheItem]",
        "proc scannedBssidIsSpecific",
        "let supportedChannelCount = bl_msg_get_channel_nums()",
        "supportedChannelCount <= 0 or scannedChannel.cint > supportedChannelCount",
        "not scannedBssidIsSpecific(scannedBssid)",
        "scanCache[selectedScanCacheSlot].channel = scannedChannel",
        "scanCache[selectedScanCacheSlot].rssi = scannedRssi",
    ]:
        assert expected in scan_diag + (
            ROOT / "src/bl808/wifi/support/state.nim"
        ).read_text()

    for expected in [
        "scanCacheStore(ind)",
        "scanCacheReset()",
        "when defined(bl808WifiConnectCacheHint):",
        "ScanActive, 0)",
        "var connectBssid: ptr uint8 = nil",
        "connectBssid = if scannedBssidIsSpecific(mac): mac else: nil",
        "if scanCacheFind(ssid, ssidLen, mac, chanId, addr selectedBssid,",
        "connectBssid = addr selectedBssid[0]",
        "freq = wifiChannelToFreq(selectedChannel)",
        "connectBssid, band, freq, flags",
    ]:
        assert expected in callbacks + scan_body + connect_body

    for expected in [
        "let requireRequestedBssid = scannedBssidIsSpecific(requestedBssid)",
        "scanCache[scanCacheSlotIndex].channel != requestedChannel",
        "if scanCache[scanCacheSlotIndex].rssi.int > bestScanCacheRssi:",
        "selectedChannelOut[] = scanCache[bestScanCacheSlot].channel",
    ]:
        assert expected in cache_find_body

    for forbidden in [
        "nil, 0, freq, flags",
        "discard band",
    ]:
        assert forbidden not in connect_body


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
    ble = blecontroller_policy_source()
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
    wifi_fw = wifi_fw_policy_source()
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
    wifi = nim_source_with_includes(ROOT / "src/bl808/wifi.nim")
    wifi_fw = wifi_fw_policy_source()
    wifi_support = nim_source_with_includes(ROOT / "src/bl808/wifi/support.nim")
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
    nap_body = wifi_fw.split("proc bl_nap_calculate*", 1)[1].split(
        "proc bl_nap_call*", 1
    )[0]
    assert "if wifiMainHasPendingWork():" in sleep_body
    assert sleep_body.index("if wifiMainHasPendingWork():") < sleep_body.index(
        "elif pmState != 0:"
    )
    for expected in [
        "for machwTimerSlotIndex in 0'u32 ..< 9'u32:",
        "1'u32 shl machwTimerSlotIndex",
        "MACHW_BASE + 0x128'u + machwTimerSlotIndex * 4",
    ]:
        assert expected in nap_body
    for forbidden in [
        "for i in 0'u32 ..< 9'u32:",
        "1'u32 shl i",
        "MACHW_BASE + 0x128'u + i * 4",
    ]:
        assert forbidden not in nap_body
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
    ble = blecontroller_policy_source()
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
    assert "encodedParams*: array[15, uint8]" in ble
    assert "nim_adv_params[advertisingParamByteIndex] =" in ble
    assert "req.encodedParams[advertisingParamByteIndex]" in ble
    assert "nim_adv_params[i] = req.encodedParams[i]" not in ble
    assert "type BleQueue = object" in ble
    assert "capacity: uint32" in ble
    assert "headIndex: uint32" in ble
    assert "tailIndex: uint32" in ble
    assert "itemCount: uint32" in ble
    assert "itemStorage: array[20 * 8, uint8]" in ble
    assert "queue.itemCount >= queue.capacity" in ble
    assert "let itemByteOffset = queue.tailIndex * queue.itemSize" in ble
    assert "addr queue.itemStorage[itemByteOffset]" in ble
    assert "queue.headIndex = (queue.headIndex + 1) mod queue.capacity" in ble
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
    main_queue_body = ble.split("proc bleDrainMainQueueMessage(): bool =", 1)[1].split(
        "proc bleDrainScheduledWork", 1
    )[0]
    assert "var mainQueueMessage: array[8, uint8]" in main_queue_body
    assert "addr mainQueueMessage[0]" in main_queue_body
    assert "mainQueueMessage[0] != 1" in main_queue_body
    assert "let queuedPayload = cast[pointer](cast[ptr uint32](addr mainQueueMessage[4])[])" in main_queue_body
    assert "getMsgHeader(queuedPayload)" in main_queue_body
    assert "msg_buf" not in main_queue_body
    assert "let param =" not in main_queue_body
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
    wifi = nim_source_with_includes(ROOT / "src/bl808/wifi.nim")

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
    wifi_fw = wifi_fw_policy_source()

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
        "proc mm_sec_machwaddr_wr*(staIdx: uint8, keySlotRaw: pointer,\n"
        "                          unusedCompatArg: uint8): uint8 {.exportc, cdecl, discardable.} =",
        1,
    )[1].split(
        "proc mm_sec_macrx_ind*", 1
    )[0]
    key_get_body = wifi_fw.split("proc mm_sec_machwkey_get*", 1)[1].split(
        "proc mm_sec_keydump*", 1
    )[0]
    keydump_body = wifi_fw.split("proc mm_sec_keydump*", 1)[1].split(
        "proc mm_bcn_init*", 1
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
    machw_security_layout = wifi_fw.split(
        "MachwSecurityRegsView {.packed.} = object", 1
    )[1].split("WlanCoexRegsView {.packed.} = object", 1)[0]
    machw_security_clear_body = wifi_fw.split(
        "proc machwSecurityClearKeyMaterial()", 1
    )[1].split("proc machwSecurityWriteKeyMaterial", 1)[0]
    machw_security_write_body = wifi_fw.split(
        "proc machwSecurityWriteKeyMaterial", 1
    )[1].split("proc machwSecurityWriteControl", 1)[0]
    pta_coex_layout = wifi_fw.split(
        "PtaCoexRegsView {.packed.} = object", 1
    )[1].split("RcRateEntryView {.packed.} = object", 1)[0]

    assert hal_body.count("waitMacSoftResetClear()") >= 2
    assert "waitRegLowNibbleClear(MACHW_STATE_CNTRL_REG)" in hal_body
    assert "MachwSecurityRegsView {.packed.} = object" in wifi_fw
    assert "securityBaseToKeyMaterialPadding*: array[0xAC, uint8]" in wifi_fw
    assert "controlToKeyCountPadding*: array[0x10, uint8]" in wifi_fw
    assert (
        "doAssert offsetof(MachwSecurityRegsView, securityBaseToKeyMaterialPadding) == 0x000"
        in wifi_fw
    )
    assert "doAssert offsetof(MachwSecurityRegsView, keyMaterial) == 0x0AC" in wifi_fw
    assert "doAssert offsetof(MachwSecurityRegsView, dataLow) == 0x0BC" in wifi_fw
    assert "doAssert offsetof(MachwSecurityRegsView, control) == 0x0C4" in wifi_fw
    assert "doAssert offsetof(MachwSecurityRegsView, controlToKeyCountPadding) == 0x0C8" in wifi_fw
    assert "template machwSecurityRegs(): ptr MachwSecurityRegsView" in wifi_fw
    assert "for keyMaterialWordIndex in 0 ..< regs.keyMaterial.len:" in wifi_fw
    assert "volatileStore(addr regs.keyMaterial[keyMaterialWordIndex], 0'u32)" in wifi_fw
    assert (
        "volatileStore(addr regs.keyMaterial[keyMaterialWordIndex], words[keyMaterialWordIndex])"
        in wifi_fw
    )
    assert "WlanCoexRegsView {.packed.} = object" in wifi_fw
    assert "PtaCoexRegsView {.packed.} = object" in wifi_fw
    assert "doAssert offsetof(WlanCoexRegsView, pti) == 0x04" in wifi_fw
    assert "ptaBaseToControlPadding*: array[4, uint8]" in wifi_fw
    assert "controlToControl2Padding*: array[0x20, uint8]" in wifi_fw
    assert "control2ToMirrorPadding*: array[0x3D8, uint8]" in wifi_fw
    assert "mirrorToClearPadding*: array[0x20, uint8]" in wifi_fw
    assert "doAssert offsetof(PtaCoexRegsView, ptaBaseToControlPadding) == 0x000" in wifi_fw
    assert "doAssert offsetof(PtaCoexRegsView, controlToControl2Padding) == 0x008" in wifi_fw
    assert "doAssert offsetof(PtaCoexRegsView, control2) == 0x028" in wifi_fw
    assert "doAssert offsetof(PtaCoexRegsView, control2ToMirrorPadding) == 0x02C" in wifi_fw
    assert "doAssert offsetof(PtaCoexRegsView, mirror) == 0x404" in wifi_fw
    assert "doAssert offsetof(PtaCoexRegsView, mirrorToClearPadding) == 0x408" in wifi_fw
    assert "doAssert offsetof(PtaCoexRegsView, clear) == 0x428" in wifi_fw
    assert "template wlanCoexRegs(): ptr WlanCoexRegsView" in wifi_fw
    assert "template ptaCoexRegs(): ptr PtaCoexRegsView" in wifi_fw
    assert (
        "proc mm_sec_machwaddr_wr*(staIdx: uint8, keySlotRaw: pointer,\n"
        "                          unusedCompatArg: uint8): uint8 {.exportc, cdecl, discardable.} ="
        in wifi_fw
    )
    assert "proc mm_sec_machwaddr_wr*(vifIdx: uint8, addr_ptr: pointer, idx: uint8)" not in wifi_fw
    for forbidden in [
        "reserved000*",
        "reserved0c8*",
    ]:
        assert forbidden not in machw_security_layout
    for forbidden in [
        "for i in 0 ..< regs.keyMaterial.len:",
        "regs.keyMaterial[i]",
        "words[i]",
    ]:
        assert forbidden not in machw_security_clear_body
        assert forbidden not in machw_security_write_body
    for forbidden in [
        "reserved000*",
        "reserved008*",
        "reserved02c*",
        "reserved408*",
    ]:
        assert forbidden not in pta_coex_layout
    assert "nimFwDbgBleWifiTxCfmBcn = wlanCoexControl()" in wifi_fw
    assert "ptaCoexWriteControl(WifiRoleCtrl)" in wifi_fw
    assert "ptaCoexUpdateControl(0xFFF7FFFF'u32, 0'u32)" in wifi_fw
    assert "wlanCoexWriteControl(wlanCoexControl() or 0x01'u32)" in wifi_fw
    assert "machwSecurityWriteAddress(mac.lo, mac.hi)" in sec_body
    assert "machwSecurityClearKeyMaterial()" in sec_body
    assert "waitMachwSecurityControlClear(0x40000000'u32)" in sec_body
    assert "discard unusedCompatArg" in sec_body
    assert "staMacWords(staInfoForIdx(staIdx))" in sec_body
    assert "let hwStaIdx = ((staIdx.uint32 + 8) and 0xFF)" in sec_body
    assert "let keySlot = cast[uint32](keySlotRaw)" in sec_body
    assert "proc mm_sec_machwaddr_del*(staIdx: uint8)" in sec_body
    assert "proc mm_sec_machwaddr_del*(idx: uint8)" not in wifi_fw
    assert "# Compute HW station index: (staIdx + 8) & 0xFF" in sec_body
    assert "cast[uint32](addr_ptr)" not in sec_body
    assert "staInfoForIdx(vifIdx)" not in sec_body
    assert "waitMachwSecurityControlClear(0x80000000'u32)" in key_get_body
    assert "var keyTableIndex: int32 = 0" in keydump_body
    assert "while keyTableIndex <= keyCount:" in keydump_body
    assert "(keyTableIndex.uint32 shl 16) or READ_TRIGGER" in keydump_body
    assert "assert_err(\"mm_sec.c\", \"mm_sec.c\", keyTableIndex.cint)" in keydump_body
    assert "var idx: int32 = 0" not in keydump_body
    assert "idx.uint32 shl 16" not in keydump_body
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
            assert forbidden not in keydump_body
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
    assert "proc hal_machw_search_addr*(macAddrPtr: pointer, unusedCompatArg: uint32)" in wifi_fw
    assert "proc hal_machw_search_addr*(addr_ptr: pointer, idx: uint32)" not in wifi_fw
    assert "discard unusedCompatArg" in search_body
    assert "let addrView = macAddrAt(macAddrPtr)" in search_body
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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split("proc mm_sec_machwkey_del*", 1)[1].split(
        "proc mm_sec_machwkey_get*", 1
    )[0]

    assert "let vif = vifChannelForIdx(hwIdx.uint8)" in body
    assert "let pairwiseKeySlotOffset = keyIdx.int - topCount.int - 1" in body
    assert "let hwIdx = pairwiseKeySlotOffset div 2" in body
    assert "let vifSlot = 4 + (pairwiseKeySlotOffset and 1)" in body
    assert "vif_mgmt_del_key(cast[pointer](vif), vifSlot.uint8)" in body
    assert "let vif = vifChannelForIdx(vifIdx)" in body
    assert "vif_mgmt_del_key(cast[pointer](vif), vifSlot)" in body
    for forbidden in [
        "let vifTabBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifTabBase + hwIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vifEntry = vifTabBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "vif_mgmt_del_key(cast[pointer](vifEntry)",
        "let offset = keyIdx.int - topCount.int - 1",
    ]:
        assert forbidden not in body


def test_wifi_debug_puts_space_uses_semantic_padding_count_name():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split(
        "proc puts_space*(buf: pointer, count: cint): pointer {.exportc: \"_puts_space\", cdecl, discardable.} =",
        1,
    )[1].split(
        "# ###########################################################################",
        1,
    )[0]

    assert "var paddingByteCount: int32 = count" in body
    assert "if paddingByteCount < 0: paddingByteCount = 0" in body
    assert "while padOffset < paddingByteCount:" in body
    assert "bufU + paddingByteCount.uint" in body
    assert "var c: int32 = count" not in body
    assert "while padOffset < c:" not in body
    assert "bufU + c.uint" not in body


def test_wifi_debug_load_le32_uses_semantic_byte_view_name():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split("proc debugLoadLe32", 1)[1].split(
        "proc wifiRamPointer", 1
    )[0]

    assert "(debugWordPointer: pointer): uint32" in body
    assert "let debugBytes = cast[ptr UncheckedArray[uint8]](debugWordPointer)" in body
    assert "debugBytes[0].uint32 or (debugBytes[1].uint32 shl 8)" in body
    assert "(debugBytes[2].uint32 shl 16) or (debugBytes[3].uint32 shl 24)" in body
    assert "proc debugLoadLe32(p: pointer): uint32" not in body
    assert "let debugBytes = cast[ptr UncheckedArray[uint8]](p)" not in body
    assert "let b = cast[ptr UncheckedArray[uint8]](p)" not in body
    assert "b[0].uint32" not in body


def test_wifi_co_pack8p_uses_semantic_byte_copy_names():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split("proc co_pack8p*", 1)[1].split(
        "# ###########################################################################\n#                      KERNEL: EVENTS",
        1,
    )[0]

    assert "for byteOffset in 0'u32 ..< count:" in body
    assert "let sourceByte = cast[ptr uint8](cast[uint](src) + byteOffset)[]" in body
    assert "cast[ptr uint8](cast[uint](dst) + byteOffset)[] = sourceByte" in body
    assert "for i in 0'u32 ..< count:" not in body
    assert "let b = cast[ptr uint8]" not in body


def test_wifi_co_list_pool_and_pool_helpers_use_semantic_counts_and_node_indexes():
    wifi_fw = wifi_fw_policy_source()

    dlist_layout = wifi_fw.split("CoDlist* = object", 1)[1].split(
        "CoPoolNode* = object", 1
    )[0]
    pool_node_layout = wifi_fw.split("CoPoolNode* = object", 1)[1].split(
        "CoPool* = object", 1
    )[0]
    pool_layout = wifi_fw.split("CoPool* = object", 1)[1].split(
        "# Kernel message header", 1
    )[0]
    dlist_body = wifi_fw.split("proc co_dlist_init*", 1)[1].split(
        "# Pool operations", 1
    )[0]
    list_pool_body = wifi_fw.split("proc co_list_pool_init*", 1)[1].split(
        "# Double-linked list operations", 1
    )[0]
    pool_init_body = wifi_fw.split("proc co_pool_init*", 1)[1].split(
        "proc co_pool_alloc*", 1
    )[0]
    pool_alloc_body = wifi_fw.split("proc co_pool_alloc*", 1)[1].split(
        "proc co_pool_free*", 1
    )[0]
    pool_free_body = wifi_fw.split("proc co_pool_free*", 1)[1].split(
        "proc co_pack8p*", 1
    )[0]

    assert "elementCount*: uint32" in dlist_layout
    assert "element*: pointer" in pool_node_layout
    assert "freeNodeCount*: uint32" in pool_layout
    assert "cnt*: uint32" not in dlist_layout
    assert "data*: pointer" not in pool_node_layout
    assert "cnt*: uint32" not in pool_layout
    assert "list.elementCount = 0" in dlist_body
    assert "inc list.elementCount" in dlist_body
    assert "dec list.elementCount" in dlist_body
    assert ".cnt" not in dlist_body

    assert "for listPoolSlotIndex in 0'u32 ..< poolSize:" in list_pool_body
    assert "for i in 0'u32 ..< poolSize:" not in list_pool_body

    for expected in [
        "for poolNodeIndex in 0'u32 ..< elemCount:",
        "nodeBase + poolNodeIndex.uint * 8",
        "elemBase + poolNodeIndex.uint * elemSize.uint",
        "node.element = cast[pointer](elemBase + poolNodeIndex.uint * elemSize.uint)",
        "if poolNodeIndex + 1 < elemCount:",
        "nodeBase + (poolNodeIndex.uint + 1) * 8",
    ]:
        assert expected in pool_init_body

    for forbidden in [
        "for i in 0'u32 ..< elemCount:",
        "nodeBase + i.uint * 8",
        "elemBase + i.uint * elemSize.uint",
        "if i + 1 < elemCount:",
        "nodeBase + (i.uint + 1) * 8",
    ]:
        assert forbidden not in pool_init_body

    assert "for allocatedNodeIndex in 1'u32 ..< count:" in pool_alloc_body
    assert "for freedNodeIndex in 1'u32 ..< count:" in pool_free_body
    assert "pool.freeNodeCount = elemCount" in pool_init_body
    assert "if pool.freeNodeCount < count:" in pool_alloc_body
    assert "pool.freeNodeCount -= count" in pool_alloc_body
    assert "pool.freeNodeCount += count" in pool_free_body
    assert ".cnt" not in pool_init_body
    assert ".cnt" not in pool_alloc_body
    assert ".cnt" not in pool_free_body
    assert "for i in 1'u32 ..< count:" not in pool_alloc_body
    assert "for i in 1'u32 ..< count:" not in pool_free_body


def test_wifi_machw_sleep_and_crypto_helpers_use_semantic_loop_indexes():
    wifi_fw = wifi_fw_policy_source()

    sleep_body = wifi_fw.split("proc hal_machw_sleep_check*", 1)[1].split(
        "{.emit: \"__attribute__((optimize(\\\"crossjumping\\\"))) void hal_machw_gen_handler",
        1,
    )[0]
    xor_body = wifi_fw.split("proc xor_bytes*", 1)[1].split(
        "proc add_round_key*", 1
    )[0]
    round_key_body = wifi_fw.split("proc add_round_key*", 1)[1].split(
        "proc aes_cmac_shift_sub_key*", 1
    )[0]
    rate_map_body = wifi_fw.split("proc rcCountBitsInMap", 1)[1].split(
        "proc rcHighestBit", 1
    )[0]

    for expected in [
        "for accessCategoryIndex in 0'u32 ..< 10:",
        "let acBit = 1'u32 shl accessCategoryIndex",
        "MACHW_CHAN_STAT_BASE + accessCategoryIndex * 4",
    ]:
        assert expected in sleep_body
    for forbidden in [
        "for i in 0'u32 ..< 10:",
        "let acBit = 1'u32 shl i",
        "MACHW_CHAN_STAT_BASE + i * 4",
    ]:
        assert forbidden not in sleep_body

    for expected in [
        "for xorByteOffset in 0'u32 ..< count:",
        "cast[uint](src) + xorByteOffset",
        "cast[uint](dst) + xorByteOffset",
    ]:
        assert expected in xor_body
    for forbidden in [
        "for i in 0'u32 ..< count:",
        "cast[uint](src) + i",
        "cast[uint](dst) + i",
    ]:
        assert forbidden not in xor_body

    for expected in [
        "for roundKeyWordIndex in 0'u32 ..< 4:",
        "keyBase + roundKeyWordIndex * 4",
        "cast[uint](state) + roundKeyWordIndex * 4",
    ]:
        assert expected in round_key_body
    for forbidden in [
        "for i in 0'u32 ..< 4:",
        "keyBase + i * 4",
        "cast[uint](state) + i * 4",
    ]:
        assert forbidden not in round_key_body

    for expected in [
        "for rateMapBitIndex in fromBit .. toBit:",
        "rateMap and (1'u16 shl rateMapBitIndex)",
    ]:
        assert expected in rate_map_body
    for forbidden in [
        "for i in fromBit .. toBit:",
        "rateMap and (1'u16 shl i)",
    ]:
        assert forbidden not in rate_map_body


def test_wifi_tx_descriptor_update_does_not_hard_trap_cps_runtime():
    wifi_fw = wifi_fw_policy_source()

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
    for expected in [
        "var payloadThdCount = 0'u32",
        "var lastPayloadThdEntry: ptr HostTxThdEntryView = nil",
        "for payloadThdEntryIndex in 0 ..< desc.bufferPtrs.len:",
        "let payloadBufferStart = desc.bufferPtrs[payloadThdEntryIndex]",
        "if payloadThdCount == 0:",
        "let payloadThdEntry = addr linkDesc.payloadThd[payloadThdEntryIndex]",
        "payloadThdEntry.payloadStart = payloadBufferStart",
        "let payloadBufferLen = desc.bufferLens[payloadThdEntryIndex]",
        "payloadThdEntry.payloadEnd = payloadBufferStart + payloadBufferLen - 1",
        "lastPayloadThdEntry = payloadThdEntry",
        "payloadThdCount += 1",
        "payloadThdEntry.next = addr linkDesc.payloadThd[payloadThdEntryIndex + 1]",
        "if lastPayloadThdEntry != nil:",
    ]:
        assert expected in thd_body
    for forbidden in [
        "var count = 0'u32",
        "var lastEntry:",
        "for i in 0 ..< desc.bufferPtrs.len:",
        "let bufPtr = desc.bufferPtrs[i]",
        "if count == 0:",
        "let entry = addr linkDesc.payloadThd[i]",
        "let bufLen = desc.bufferLens[i]",
        "lastEntry = entry",
        "count += 1",
    ]:
        assert forbidden not in thd_body


def test_wifi_apm_sta_add_confirm_does_not_trap_scheduler():
    wifi_fw = wifi_fw_policy_source()

    apm_body = wifi_fw.split("proc apm_sta_add_cfm_handler*", 1)[1].split(
        "{.emit: \"__attribute__((optimize(\\\"crossjumping\\\"))) void apm_sta_del_req_handler",
        1,
    )[0]

    assert "nimfw_dbg_apm_sta_add_noslot" in wifi_fw
    assert "nimfw_dbg_apm_sta_add_noslot_sta" in wifi_fw
    assert "sb zero" not in apm_body
    assert "ebreak" not in apm_body
    assert "assert_err" not in apm_body
    assert "for apmStaAddSlotIndex in 0'u ..< 5'u:" in apm_body
    assert "let apmStaAddSlot = apmStaSlot(apmStaAddSlotIndex)" in apm_body
    assert "apmStaAddSlot.staIdx = staIdx" in apm_body
    assert "let stored = cast[uint32](apmStaAddSlot.staHandle)" in apm_body
    assert "for slotIdx in 0'u ..< 5'u:" not in apm_body
    assert "let slot = apmStaSlot(slotIdx)" not in apm_body
    assert "inc nimFwDbgApmStaAddNoSlot" in apm_body
    assert "nimFwDbgApmStaAddNoSlotSta = staIdx.uint32" in apm_body


def test_wifi_assert_err_requests_reset_without_blocking_scheduler():
    wifi_fw = wifi_fw_policy_source()

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


def test_wifi_scan_result_prefers_valid_ds_channel_over_stale_rx_frequency():
    wifi_fw = wifi_fw_policy_source()

    scan_body = wifi_fw.split(
        "# Channel from DS IE. Some RX indications carry a stale frequency",
        1,
    )[1].split(
        "# SSID filter loop", 1
    )[0]

    assert "let dsFreq = dsParamFreq(rx.band, ds)" in scan_body
    assert "if dsFreq != 0xFFFF'u16: dsFreq else: rx.freq" in scan_body
    assert "scanuCacheChannel(scanResultEntry, rx.band, selectedFreq)" in scan_body


def test_wifi_tx_confirm_event_yields_under_backlog():
    wifi_fw = wifi_fw_policy_source()

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


def test_wifi_tx_confirm_dump_uses_semantic_queue_count_name():
    wifi_fw = wifi_fw_policy_source()

    dump_body = wifi_fw.split(
        "proc txl_cfm_dump*() {.exportc, cdecl, noinline.} =",
        1,
    )[1].split(
        "proc txl_cfm_dma_int_handler_backup*",
        1,
    )[0]

    assert "for txConfirmQueueIndex in 0'u32 ..< 5'u32:" in dump_body
    assert "let listPtr = txCfmList(txConfirmQueueIndex)" in dump_body
    assert "let queuedConfirmCount = co_list_cnt(listPtr)" in dump_body
    assert "logFn(2, 0, \"txl_cfm.c\", 577, txConfirmQueueIndex, head, queuedConfirmCount)" in dump_body
    assert "let txHardwareStatus =" in dump_body
    assert "hostTxHwDescAt(hwDescPtr).status" in dump_body
    assert "logFn(2, 0, \"txl_cfm.c\", 585, node, txHardwareStatus)" in dump_body
    assert "for i in 0'u32 ..< 5'u32:" not in dump_body
    assert "let listPtr = txCfmList(i)" not in dump_body
    assert "let cnt = co_list_cnt(listPtr)" not in dump_body
    assert "logFn(2, 0, \"txl_cfm.c\", 577, i, head, cnt)" not in dump_body
    assert "let thdField16 =" not in dump_body


def test_wifi_tx_confirm_flush_uses_explicit_list_drain_condition():
    wifi_fw = wifi_fw_policy_source()

    flush_body = wifi_fw.split(
        "proc txl_cfm_flush*() {.exportc, cdecl, noinline.} =",
        1,
    )[1].split(
        "proc txl_cfm_flush_desc*",
        1,
    )[0]

    assert "while cfmList.first != nil:" in flush_body
    assert "var flushedHostConfirmCount: uint32 = 0" in flush_body
    assert "flushedHostConfirmCount += 1" in flush_body
    assert "while true:" not in flush_body
    assert "txl_frame_evt()" in flush_body
    assert "if flushedHostConfirmCount > 0:" in flush_body
    assert "ipc_emb_txcfm_ind(1'u32 shl acIdx)" in flush_body
    assert "var count: uint32 = 0" not in flush_body
    assert "count += 1" not in flush_body
    assert "if count > 0:" not in flush_body


def test_wifi_tx_control_ps_check_uses_positive_queueing_guard():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    for expected in [
        "ChanEnvView {.packed.} = object",
        "contextPointerPadding*: uint32",
        "tbttCallbackPadding*: array[8, uint8]",
        "cdeTimestampPadding*: array[4, uint8]",
        "ctxtOpCallbackPadding*: array[4, uint8]",
        "remainingTimePadding*: array[4, uint8]",
        "delayCallbackPadding*: array[4, uint8]",
        "timerStatePadding*: array[3, uint8]",
        "surveySnapshotPadding*: uint8",
        "doAssert offsetof(ChanEnvView, contextPointerPadding) == 44",
        "doAssert offsetof(ChanEnvView, tbttCallbackPadding) == 56",
        "doAssert offsetof(ChanEnvView, cdeTimestampPadding) == 76",
        "doAssert offsetof(ChanEnvView, delayCallbackPadding) == 100",
        "doAssert offsetof(ChanEnvView, timerStatePadding) == 105",
        "doAssert offsetof(ChanEnvView, surveySnapshotPadding) == 127",
    ]:
        assert expected in wifi_fw
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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    assert "doAssert offsetof(HostTxDescView, callback) == 208" in wifi_fw
    assert "doAssert offsetof(HostTxAuxWordsView, rateConfig) == 0" in wifi_fw
    assert "doAssert offsetof(HostTxAuxWordsView, navValue) == 4" in wifi_fw
    assert "template hostTxInlineBufferedLink(desc: ptr HostTxDescView): ptr HostTxBufferedLinkView =\n  cast[ptr HostTxBufferedLinkView](addr desc.callback)" in wifi_fw
    assert "template hostTxAuxWords(desc: ptr HostTxDescView): ptr HostTxAuxWordsView =\n  cast[ptr HostTxAuxWordsView](addr desc.callback)" in wifi_fw

    for forbidden in [
        "cast[ptr HostTxBufferedLinkView](cast[uint](desc) + 208'u)",
        "cast[ptr HostTxAuxWordsView](cast[uint](desc) + 208'u)",
        "aux.word0",
        "aux.word1",
    ]:
        assert forbidden not in wifi_fw


def test_wifi_tx_buffer_init_uses_typed_control_overlays():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split(
        "proc txl_buffer_init*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_buffer_reinit*", 1
    )[0]

    for expected in [
        "doAssert sizeof(TxBufferControlView) == 60",
        "template txBufferControlDescAt(txPolicySlotIndex: int): ptr TxBufferControlView",
        "template txBufferControlBcmcDescAt(bcmcPolicySlotIndex: int): ptr TxBufferControlView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "for staPolicySlotIndex in 0 ..< TX_BUFFER_POOL_SIZE:",
        "let staTxPolicyDesc = txBufferControlDescAt(staPolicySlotIndex)",
        "staTxPolicyDesc.magic = 0xBADCAB1E'u32",
        "staTxPolicyDesc.ntxConfig = phy_get_ntx().uint32 shl 14",
        "let ntxSpatialStreamCount = phy_get_ntx().uint32",
        "staTxPolicyDesc.bwMask = (1'u32 shl (ntxSpatialStreamCount + 1'u32)) - 1'u32",
        "staTxPolicyDesc.policyWord = 0xFFFF0704'u32",
        "staTxPolicyDesc.txPower = cast[int32](regRead(MACHW_RNG_REG) and 0xFF'u32)",
        "staTxPolicyDesc.ackPolicyControl = 0x2200'u32",
        "staTxPolicyDesc.retryLimitControl = 0x003F0000'u32",
        "for bcmcPolicySlotIndex in 0 ..< 2:",
        "let bcmcTxPolicyDesc = txBufferControlBcmcDescAt(bcmcPolicySlotIndex)",
        "bcmcTxPolicyDesc.bwMask = (1'u32 shl (ntxSpatialStreamCount + 1'u32)) - 1'u32",
    ]:
        assert expected in body

    for forbidden in [
        "for i in 0 ..< TX_BUFFER_POOL_SIZE:",
        "for i in 0 ..< 2:",
        "let d = txBufferControlDescAt(i)",
        "let d = txBufferControlBcmcDescAt(i)",
        "template txBufferControlDescAt(idx: int): ptr TxBufferControlView",
        "template txBufferControlBcmcDescAt(idx: int): ptr TxBufferControlView",
        "let maskNtx =",
        "maskNtx + 1'u32",
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
    wifi_fw = wifi_fw_policy_source()

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
    assert "let link = txlFrameLinkDescAt(frameDescSlotIndex)" in frame_init
    assert "hw.payloadStart = cast[uint32](hostTxLinkMacHdrAddr(link))" in frame_init
    assert "hw.payloadStart = cast[uint32](hostTxLinkMacHdrAddr(hostTxLinkDescAt(linkDesc)))" in init_desc

    for forbidden in [
        "let link = txlFrameLinkDescAt(i)",
        "hw.payloadStart = cast[uint32](linkDesc + 348'u)",
        "hw.payloadStart = cast[uint32](cast[uint](linkDesc) + 348)",
        "template hostTxMacHdrAddr(desc: ptr HostTxDescView): uint =\n  cast[uint](desc.bufDesc) + 348'u",
    ]:
        assert forbidden not in wifi_fw


def test_wifi_tx_frame_private_pools_use_typed_slot_tables():
    wifi_fw = wifi_fw_policy_source()

    host_tx_desc_layout = wifi_fw.split(
        "HostTxDescView {.packed.} = object", 1
    )[1].split("HostTxHwDescView {.packed.} = object", 1)[0]
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
        "linkDescriptorBytes*: array[860, uint8]",
        "TxlFrameHwDescSlotView {.packed.} = object",
        "hwDescTailPadding*: array[4, uint8]",
        "TxlFrameHwCfmSlotView {.packed.} = object",
        "confirmWords*: array[5, uint32]",
        "TxlFramePayloadSlotView {.packed.} = object",
        "doAssert sizeof(TxlFrameDescSlotView) == 220",
        "doAssert sizeof(TxlFrameLinkSlotView) == 860",
        "doAssert sizeof(TxlFrameHwDescSlotView) == 72",
        "doAssert sizeof(TxlFrameHwCfmSlotView) == 20",
        "doAssert offsetof(TxlFrameHwCfmSlotView, confirmWords) == 0",
        "doAssert sizeof(TxlFramePayloadSlotView) == 60",
        "doAssert offsetof(HostTxHwDescView, txConfirmDescPtr) == 0",
        "doAssert offsetof(HostTxHwDescView, secondaryTxHwDescPtr) == 8",
        "doAssert offsetof(HostTxHwDescView, secondaryDescToStatusPadding) == 12",
        "seqPassthroughToConfirmPadding*: array[2, uint8]",
        "pnScratchToSeqAssignedPadding*: array[2, uint8]",
        "seqAssignedToStaIdsPadding*: array[2, uint8]",
        "staIdsToBuffersPadding*: array[2, uint8]",
        "policyToLengthsPadding*: array[4, uint8]",
        "securityLengthsToDmaPadding*: array[3, uint8]",
        "aggPtrToRetryCountersPadding*: array[52, uint8]",
        "txFlagsToAggStoragePadding*: array[4, uint8]",
        "doAssert offsetof(HostTxDescView, seqPassthroughToConfirmPadding) == 14",
        "doAssert offsetof(HostTxDescView, pnScratchToSeqAssignedPadding) == 40",
        "doAssert offsetof(HostTxDescView, seqAssignedToStaIdsPadding) == 44",
        "doAssert offsetof(HostTxDescView, staIdsToBuffersPadding) == 50",
        "doAssert offsetof(HostTxDescView, policyToLengthsPadding) == 92",
        "doAssert offsetof(HostTxDescView, securityLengthsToDmaPadding) == 101",
        "doAssert offsetof(HostTxDescView, aggPtrToRetryCountersPadding) == 120",
        "doAssert offsetof(HostTxDescView, txFlagsToAggStoragePadding) == 184",
        "template txlFrameDescAt(frameDescIndex: uint32): ptr HostTxDescView",
        "template txlFrameLinkDescAt(frameDescIndex: uint32): ptr HostTxLinkDescView",
        "template txlFrameHwDescAt(frameDescIndex: uint32): ptr HostTxHwDescView",
        "template txlFrameHwCfmAt(frameDescIndex: uint32): ptr TxlFrameHwCfmSlotView",
        "template txlFramePayloadDescAt(frameDescIndex: uint32): ptr TxBufferControlView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "for frameDescIndex in 0'u32 ..< TxlFrameDescCount:",
        "let descPtr = cast[pointer](txlFrameDescAt(frameDescIndex))",
        "for frameDescSlotIndex in 0'u32 ..< TxlFrameDescCount:",
        "let frameDesc = txlFrameDescAt(frameDescSlotIndex)",
        "let link = txlFrameLinkDescAt(frameDescSlotIndex)",
        "let hw = txlFrameHwDescAt(frameDescSlotIndex)",
        "let hwCfm = txlFrameHwCfmAt(frameDescSlotIndex)",
        "let payload = txlFramePayloadDescAt(frameDescSlotIndex)",
        "discard c_memset(cast[pointer](frameDesc), 0, sizeof(TxlFrameDescSlotView).csize_t)",
        "frameDesc.bufDesc = cast[pointer](link)",
        "frameDesc.policy = cast[pointer](payload)",
        "frameDesc.hwDesc = cast[pointer](hw)",
        "hw.txConfirmDescPtr = cast[uint32](cast[uint](hwCfm))",
        "txl_frame_free_list_push(cast[pointer](frameDesc))",
    ]:
        assert expected in frame_init + rebuild_body

    for forbidden in [
        "let descArrayBase = cast[uint](addr txl_frame_desc_storage[0])",
        "let linkPoolBase = cast[uint](addr txl_frame_pool[0])",
        "let hwPoolBase = cast[uint](addr txl_frame_hwdesc_pool[0])",
        "let hwCfmBase = cast[uint](addr txl_frame_hwdesc_cfms[0])",
        "template txlFrameDescAt(idx: uint32): ptr HostTxDescView",
        "template txlFrameLinkDescAt(idx: uint32): ptr HostTxLinkDescView",
        "template txlFrameHwDescAt(idx: uint32): ptr HostTxHwDescView",
        "template txlFrameHwCfmAt(idx: uint32): ptr TxlFrameHwCfmSlotView",
        "template txlFramePayloadDescAt(idx: uint32): ptr TxBufferControlView",
        "let payloadPoolBase = cast[uint](addr txl_frame_buf_ctrl[0])",
        "let descBase = descArrayBase + i.uint * descSize.uint",
        "let linkDesc = linkPoolBase + i.uint * 860'u",
        "let hwDesc = hwPoolBase + i.uint * 72'u",
        "let hwCfm = hwCfmBase + i.uint * 20'u",
        "let payloadDesc = payloadPoolBase + i.uint * 60'u",
        "let descPtr = cast[pointer](base + i.uint * TxlFrameDescSize)",
        "let descPtr = cast[pointer](txlFrameDescAt(i))",
        "let frameDesc = txlFrameDescAt(i)",
        "let link = txlFrameLinkDescAt(i)",
        "let hw = txlFrameHwDescAt(i)",
        "let hwCfm = txlFrameHwCfmAt(i)",
        "let payload = txlFramePayloadDescAt(i)",
    ]:
        assert forbidden not in frame_init
        assert forbidden not in rebuild_body

    for forbidden in [
        "reserved14*",
        "reserved40*",
        "reserved44*",
        "reserved50*",
        "reserved92*",
        "reserved101*",
        "reserved120*",
        "reserved184*",
    ]:
        assert forbidden not in host_tx_desc_layout


def test_wifi_layout_slot_helpers_use_semantic_index_parameters():
    wifi_fw = wifi_fw_policy_source()

    for expected in [
        "template apmStaSlot(apmStaSlotIndex: uint): ptr ApmStaSlotOverlay",
        "cast[uint](addr apm_env[0]) + 80'u + apmStaSlotIndex * 16'u",
        "template scanSsidSlot(req: typed, ssidSlotIndex: int): ptr ScanSsidSlotView",
        "ssidSlotIndex.uint * ScanSsidSlotViewSize.uint",
        "template mmBcnTemplateByte(templateByteOffset: static[int]): untyped",
        "addr bcnEnvView().templatePtr)[templateByteOffset]",
        "template chanCtxtForIdx(channelContextIndex: uint8): ptr ChanCtxtView",
        "channelContextIndex.uint * sizeof(ChanCtxtView).uint",
        "template vifEntryAddr(vifIndex: uint8): uint",
        "vifIndex.uint * VIF_ENTRY_SIZE.uint",
        "template vifChannelForIdx(vifIndex: uint8): ptr VifChannelView",
        "vifChannelAt(vifEntryAddr(vifIndex))",
        "template vifApEdcaWord(apCfg: ptr VifApConfigOverlay,\n"
        "                       accessCategoryIndex: int): ptr uint32",
        "addr apCfg.edcaParams[accessCategoryIndex * 4]",
        "template txlFrameDescSlotAt(frameDescIndex: uint32): ptr TxlFrameDescSlotView",
        "addr txl_frame_desc_storage[0])[frameDescIndex]",
        "template txlFrameHwDescSlotAt(frameDescIndex: uint32): ptr TxlFrameHwDescSlotView",
        "addr txl_frame_hwdesc_pool[0])[frameDescIndex]",
        "template txlFrameLinkSlotAt(frameDescIndex: uint32): ptr TxlFrameLinkSlotView",
        "addr txl_frame_pool[0])[frameDescIndex]",
        "template txlFramePayloadSlotAt(frameDescIndex: uint32): ptr TxlFramePayloadSlotView",
        "addr txl_frame_buf_ctrl[0])[frameDescIndex]",
        "template staInfoForIdx(staIndex: uint8): ptr StaInfoView",
        "staIndex.uint * STA_ENTRY_SIZE.uint",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "template apmStaSlot(idx: uint): ptr ApmStaSlotOverlay",
        "template scanSsidSlot(req: typed, idx: int): ptr ScanSsidSlotView",
        "template mmBcnTemplateByte(idx: static[int]): untyped",
        "template chanCtxtForIdx(idx: uint8): ptr ChanCtxtView",
        "template vifEntryAddr(idx: uint8): uint",
        "template vifChannelForIdx(idx: uint8): ptr VifChannelView",
        "template vifApEdcaWord(apCfg: ptr VifApConfigOverlay, idx: int): ptr uint32",
        "template txlFrameDescSlotAt(idx: uint32): ptr TxlFrameDescSlotView",
        "template txlFrameHwDescSlotAt(idx: uint32): ptr TxlFrameHwDescSlotView",
        "template txlFrameLinkSlotAt(idx: uint32): ptr TxlFrameLinkSlotView",
        "template txlFramePayloadSlotAt(idx: uint32): ptr TxlFramePayloadSlotView",
        "template staInfoForIdx(idx: uint8): ptr StaInfoView",
    ]:
        assert forbidden not in wifi_fw


def test_wifi_tx_payload_debug_and_dump_loops_use_semantic_indexes():
    wifi_fw = wifi_fw_policy_source()

    payload_backup_body = wifi_fw.split(
        "proc txl_payload_handle_backup*(param: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txl_payload_handle*", 1
    )[0]
    frame_dump_body = wifi_fw.split(
        "proc txl_frame_dump*() {.exportc, cdecl, noinline.} =",
        1,
    )[1].split(
        "# Aliases for compatibility", 1
    )[0]

    for expected in [
        "for probePayloadByteIndex in 0 ..< nimFwDbgProbePayRaw.len:",
        "nimFwDbgProbePayRaw[probePayloadByteIndex] = 0",
    ]:
        assert expected in payload_backup_body

    for forbidden in [
        "for i in 0 ..< nimFwDbgProbePayRaw.len:",
        "nimFwDbgProbePayRaw[i] = 0",
    ]:
        assert forbidden not in payload_backup_body

    for expected in [
        "for frameDescSlotIndex in 0 ..< 4:",
        "let descAddr = descStorageBase + frameDescSlotIndex.uint * 220'u",
    ]:
        assert expected in frame_dump_body

    for forbidden in [
        "for i in 0 ..< 4:",
        "let descAddr = descStorageBase + i.uint * 220'u",
    ]:
        assert forbidden not in frame_dump_body


def test_wifi_tx_buffer_alloc_uses_typed_mac_header_body_pointer():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
        "retryRateControl0*: uint32",
        "retryRateControl1*: uint32",
        "retryRateControl2*: uint32",
        "retryTxPowerControl0*: uint32",
        "retryTxPowerControl1*: uint32",
        "retryTxPowerControl2*: uint32",
        "doAssert offsetof(HostTxRateTemplateView, retryRateControl0) == 24",
        "doAssert offsetof(HostTxRateTemplateView, retryRateControl1) == 28",
        "doAssert offsetof(HostTxRateTemplateView, retryRateControl2) == 32",
        "doAssert offsetof(HostTxRateTemplateView, retryTxPowerControl0) == 40",
        "doAssert offsetof(HostTxRateTemplateView, retryTxPowerControl1) == 44",
        "doAssert offsetof(HostTxRateTemplateView, retryTxPowerControl2) == 48",
        "doAssert offsetof(TxBufferControlView, retryRateControl0) == 24",
        "doAssert offsetof(TxBufferControlView, retryRateControl1) == 28",
        "doAssert offsetof(TxBufferControlView, retryRateControl2) == 32",
        "doAssert offsetof(TxBufferControlView, retryTxPowerControl0) == 40",
        "doAssert offsetof(TxBufferControlView, retryTxPowerControl1) == 44",
        "doAssert offsetof(TxBufferControlView, retryTxPowerControl2) == 48",
    ]:
        assert expected in wifi_fw

    for expected in [
        "rate.retryRateControl0 = 0x8000040A'u32",
        "rate.retryRateControl1 = 0x80001007'u32",
        "rate.retryRateControl2 = 0x80000400'u32",
        "rate.txPower = 0x00000070'i32",
        "rate.retryTxPowerControl0 = 0x00000070'u32",
        "rate.retryTxPowerControl1 = 0x00000070'u32",
        "rate.retryTxPowerControl2 = 0x00000070'u32",
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
        "rate.word24",
        "rate.word28",
        "rate.word32",
        "rate.word40",
        "rate.word44",
        "rate.word48",
    ]:
        assert forbidden not in policy_body
        assert forbidden not in alloc_body


def test_wifi_apm_tx_ps_check_uses_typed_sta_overlay():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split(
        "proc apm_tx_int_ps_check*(txDesc: pointer): bool {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc apm_tx_int_ps_postpone*", 1
    )[0]
    tx_ps_layout = wifi_fw.split(
        "ApmTxDescPsView {.packed.} = object", 1
    )[1].split("HostTxDescView {.packed.} = object", 1)[0]

    assert "doAssert offsetof(StaInfoView, rateSet) == 32" in wifi_fw
    assert "descBaseToStaPeerPadding*: array[4, uint8]" in wifi_fw
    assert "staPeerToStaInstPadding*: array[31, uint8]" in wifi_fw
    assert "staInstToTidPadding*: array[6, uint8]" in wifi_fw
    assert "deliveryPolicyToSubtypePadding*: uint8" in wifi_fw
    assert "postponeFlagsToPendingCountPadding*: array[16, uint8]" in wifi_fw
    assert "pendingCountToStaDescPadding*: array[38, uint8]" in wifi_fw
    assert "doAssert offsetof(ApmTxDescPsView, descBaseToStaPeerPadding) == 0" in wifi_fw
    assert "doAssert offsetof(ApmTxDescPsView, staPeerToStaInstPadding) == 8" in wifi_fw
    assert "doAssert offsetof(ApmTxDescPsView, staInstToTidPadding) == 40" in wifi_fw
    assert "doAssert offsetof(ApmTxDescPsView, deliveryPolicyToSubtypePadding) == 48" in wifi_fw
    assert "doAssert offsetof(ApmTxDescPsView, postponeFlagsToPendingCountPadding) == 52" in wifi_fw
    assert "doAssert offsetof(ApmTxDescPsView, pendingCountToStaDescPadding) == 70" in wifi_fw
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

    for forbidden in [
        "reserved0*",
        "reserved8*",
        "reserved40*",
        "reserved48*",
        "reserved52*",
        "reserved70*",
    ]:
        assert forbidden not in tx_ps_layout


def test_wifi_tx_trigger_yields_under_descriptor_backlog():
    wifi_fw = wifi_fw_policy_source()

    tx_control_env_layout = wifi_fw.split(
        "TxControlEnvView {.packed.} = object", 1
    )[1].split("TxCfmEnvView {.packed.} = object", 1)[0]
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
    assert "seqCounterToResetPadding*: array[2, uint8]" in wifi_fw
    assert "resetTailPadding*: array[3, uint8]" in wifi_fw
    assert "doAssert offsetof(TxControlEnvView, seqCounterToResetPadding) == 86" in wifi_fw
    assert "doAssert offsetof(TxControlEnvView, resetTailPadding) == 89" in wifi_fw
    assert "let acReady = txStatus and 0x7C0'u32" in trigger_body
    assert "let acReadyHigh = txStatus and 0x000F8000'u32" in trigger_body
    assert "if acReady == 0 and acReadyHigh == 0:" in trigger_body
    assert "var drained = 0'u32" in trigger_body
    assert "while drained < WifiTxTriggerDrainLimit:" in trigger_body
    assert "while true:" not in trigger_body
    assert "inc drained" in trigger_body
    assert "if txlTriggerPending(acCtrl):" in trigger_body
    assert "inc nimFwDbgTxTrigYield" in trigger_body
    assert "reserved86*" not in tx_control_env_layout
    assert "reserved89*" not in tx_control_env_layout


def test_wifi_tx_trigger_uses_typed_link_overlay_for_frame_control():
    wifi_fw = wifi_fw_policy_source()

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
    assert "proc blmac_abs_timer_set*(timerIndex: uint32, timerValue: uint32)" in wifi_fw
    assert "proc blmac_abs_timer_set*(idx: uint32, value: uint32)" not in wifi_fw
    assert "let timerAddr = MACHW_INTC_BASE + 0x128'u + timerIndex * 4" in wifi_fw
    assert "regWrite(timerAddr, timerValue)" in wifi_fw
    assert "blmac_abs_timer_set(ac, ipcBase + TX_TIMEOUT_LOCAL[ac])" in trigger_body
    yield_body = trigger_body.split("if txlTriggerPending(acCtrl):", 1)[1]
    assert "regWrite(MACHW_TX_TRIG_STAT" not in yield_body


def test_wifi_machw_tx_queue_regs_use_typed_overlay():
    wifi_fw = wifi_fw_policy_source()

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
    tx_queue_layout = wifi_fw.split(
        "MachwTxQueueRegsView {.packed.} = object", 1
    )[1].split("MachwRxDmaRegsView {.packed.} = object", 1)[0]

    assert "MachwTxQueueRegsView {.packed.} = object" in wifi_fw
    assert "txQueueBaseToStatusPadding*: array[0x78, uint8]" in wifi_fw
    assert "txAggActiveToTriggerPadding*: array[0xF0, uint8]" in wifi_fw
    assert "txTriggerToDmaStatusPadding*: uint32" in wifi_fw
    assert "dmaStatusToQueueHeadPadding*: array[12, uint8]" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, txQueueBaseToStatusPadding) == 0x00" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, txStatus) == 0x78" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, readyAck) == 0x7C" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, txAggActiveToTriggerPadding) == 0x90" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, txTrigger) == 0x180" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, txTriggerToDmaStatusPadding) == 0x184" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, dmaStatus) == 0x188" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, dmaStatusToQueueHeadPadding) == 0x18C" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, ac0Head) == 0x19C" in wifi_fw
    assert "doAssert offsetof(MachwTxQueueRegsView, ac3Head) == 0x1A8" in wifi_fw
    for forbidden in [
        "reserved000*",
        "reserved090*",
        "reserved184*",
        "reserved18c*",
    ]:
        assert forbidden not in tx_queue_layout
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
    wifi_fw = wifi_fw_policy_source()

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
    assert "rateTemplate.retryTxPowerControl2" in body
    assert "let dmaBase = cast[uint](rateTemplate)" not in body
    assert "dmaBase + 4" not in body
    assert "dmaBase + 20" not in body
    assert "dmaBase + 36" not in body
    assert "dmaBase + 52" not in body


def test_wifi_txl_current_desc_get_uses_typed_hwdesc_overlay():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    assert "let frameDescPoolIndex = txl_frame_desc_index(cast[pointer](freeNode))" in get_body
    assert "if frameDescPoolIndex < TxlFrameDescCount:" in get_body
    assert "desc.bufDesc = cast[pointer](txlFrameLinkDescAt(frameDescPoolIndex))" in get_body
    assert "return cast[pointer](freeNode)" in get_body
    assert get_body.rstrip().endswith("nil")

    for forbidden in [
        "let linkPoolBase = cast[uint](addr txl_frame_pool[0])",
        "desc.bufDesc = cast[pointer](linkPoolBase + idx * 860'u)",
        "let idx = txl_frame_desc_index(cast[pointer](freeNode))",
        "desc.bufDesc = cast[pointer](txlFrameLinkDescAt(idx))",
    ]:
        assert forbidden not in get_body


def test_wifi_tx_frame_push_uses_typed_mac_header_overlay():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    rxl_env_layout = wifi_fw.split(
        "RxlCntrlEnvView {.packed.} = object", 1
    )[1].split("RxHwDescEnvView {.packed.} = object", 1)[0]
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
    assert "let queuedRxMpduDesc = cast[pointer](cntrlEnv.queue.first)" in rx_body
    assert "if cntrlEnv.processingFlag != 0 or queuedRxMpduDesc == nil:" in rx_body
    assert "let swDesc = rxMpduDescView(queuedRxMpduDesc).swDesc" in rx_body
    assert "rxu_cntrl_frame_handle(queuedRxMpduDesc)" in rx_body
    assert "rxl_mpdu_free(queuedRxMpduDesc)" in rx_body
    assert "processingFlagTailPadding*: array[3, uint8]" in rxl_env_layout
    assert "doAssert offsetof(RxlCntrlEnvView, processingFlagTailPadding) == 25" in wifi_fw
    assert "statusTailPadding*: uint16" in wifi_fw
    assert "doAssert offsetof(RxHwDesc, statusTailPadding) == 14" in wifi_fw
    assert "cast[ptr pointer](cast[uint](queuedRxMpduDesc) + 4)" not in rx_body
    assert "curHwDesc" not in rx_body
    assert "reserved25*" not in rxl_env_layout
    assert "padding*: uint16" not in wifi_fw


def test_wifi_scheduler_scan_and_bam_alignment_fields_are_semantic():
    wifi_fw = wifi_fw_policy_source()

    tbtt_layout = wifi_fw.split(
        "ChanTbttNodeView {.packed.} = object", 1
    )[1].split("VifChannelView {.packed.} = object", 1)[0]
    bam_status_layout = wifi_fw.split(
        "BamTrafficStatusPayload {.packed.} = object", 1
    )[1].split("IpcEmbMsgDescView {.packed.} = object", 1)[0]
    scan_env_layout = wifi_fw.split(
        "ScanEnvObj* {.packed.} = object", 1
    )[1].split("ScanProbeReqIeObj* {.packed.} = object", 1)[0]

    for expected in [
        "stateTailPadding*: uint8",
        "doAssert offsetof(ChanTbttNodeView, stateTailPadding) == 11",
        "trafficStatusTailPadding*: array[53, uint8]",
        "doAssert offsetof(BamTrafficStatusPayload, trafficStatusTailPadding) == 3",
        "abortFlagDurationPadding*: uint8",
        "doAssert offsetof(ScanEnvObj, abortFlagDurationPadding) == 11",
    ]:
        assert expected in wifi_fw

    assert "reserved*: uint8" not in tbtt_layout
    assert "reserved*: array[53, uint8]" not in bam_status_layout
    assert "reserved*: uint8" not in scan_env_layout


def test_wifi_rx_control_event_uses_typed_vif_overlays():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    free_body = wifi_fw.split(
        "proc rxl_mpdu_free*(desc: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rxl_mpdu_transfer*",
        1,
    )[0]

    assert "var dmaProgressDesc = rxDmaProgressDescAt(sw.bufferChain)" in free_body
    assert "var previousDmaProgressDesc: ptr RxDmaProgressDescView = nil" in free_body
    assert "while dmaProgressDesc != nil:" in free_body
    assert "while true:" not in free_body
    assert "let dmaDescriptorStatus = dmaProgressDesc.status" in free_body
    assert "dmaProgressDesc.usedFlag = 0" in free_body
    assert "rx.curDesc = cast[pointer](dmaProgressDesc)" in free_body
    assert "rx.prevDesc = cast[pointer](previousDmaProgressDesc)" in free_body
    assert "dmaProgressDesc = rxDmaProgressDescAt(dmaProgressDesc.next)" in free_body
    assert 'assert_rec("rxl_hwdesc.c", "rxl_hwdesc.c", 872)' in free_body
    for forbidden in [
        "curHw",
        "prevHw",
        "hwStatus",
    ]:
        assert forbidden not in free_body


def test_wifi_rxl_reset_uses_rxu_upload_list_overlay():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split(
        "proc rxl_reset*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rxl_hwdesc_dump*",
        1,
    )[0]

    assert "doAssert offsetof(RxuCntrlEnvView, uploadList) == 64" in wifi_fw
    for expected in [
        "dstSecInfoPadding*: array[4, uint8]",
        "hwRxhdrSecKeyPadding*: uint32",
        "stripLenListPadding*: array[5, uint8]",
        "freeListBssidSeqPadding*: array[6, uint8]",
        "doAssert offsetof(RxuCntrlEnvView, dstSecInfoPadding) == 12",
        "doAssert offsetof(RxuCntrlEnvView, hwRxhdrSecKeyPadding) == 28",
        "doAssert offsetof(RxuCntrlEnvView, stripLenListPadding) == 51",
        "doAssert offsetof(RxuCntrlEnvView, freeListBssidSeqPadding) == 88",
    ]:
        assert expected in wifi_fw
    rxu_env_block = wifi_fw.split("RxuCntrlEnvView {.packed.} = object", 1)[1].split(
        "CcmpSecurityHeaderView {.packed.} = object", 1
    )[0]
    for forbidden in [
        "reserved12*: array[4, uint8]",
        "reserved28*: uint32",
        "reserved51*: array[5, uint8]",
        "reserved88*: array[6, uint8]",
    ]:
        assert forbidden not in rxu_env_block
    assert "co_list_init(addr rxuCntrlEnvView().uploadList)" in body
    assert "rxu_cntrl_env + 0x40" not in body
    assert "{.emit:" not in body


def test_wifi_debug_snapshot_exports_unpacked_mac_rx_registers():
    wifi_fw = wifi_fw_policy_source()
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
    wifi_fw = wifi_fw_policy_source()
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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split(
        "proc rc_update_retry_chain*(stats: pointer, param: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rc_update_stats*",
        1,
    )[0]
    max_prob_body = body.split(
        "# Step 4: Build retry chain entry 3 (max_prob) by walking rate table",
        1,
    )[1].split("# Store final retry chain results", 1)[0]

    assert "template rcRateResetFields(stats: pointer, rateEntryIndex: uint16): ptr RcRateResetFieldsView" in wifi_fw
    assert "rcRateResetFields(stats, scanIdx.uint16).initialized = 0" in body
    for expected in [
        "for rateEntryIndex in 0 ..< nRates.int:",
        "let entryProb = rcRateEntryProb(stats, rateEntryIndex)",
        "let entryTp = rcRateEntryTp(stats, rateEntryIndex)",
        "let entryRetry = rcRateEntryRetry(stats, rateEntryIndex)",
        "if rateEntryIndex.uint16 == maxTpIdx:",
        "let entryRateU16 = rcRateConfig(stats, rateEntryIndex)",
        "bestProbIdx = rateEntryIndex.uint16",
    ]:
        assert expected in max_prob_body
    for forbidden in [
        "for i in 0 ..< nRates.int:",
        "rcRateEntryProb(stats, i)",
        "rcRateEntryTp(stats, i)",
        "rcRateEntryRetry(stats, i)",
        "if i.uint16 == maxTpIdx:",
        "rcRateConfig(stats, i)",
        "bestProbIdx = i.uint16",
        "template rcRateResetFields(stats: pointer, idx: uint16): ptr RcRateResetFieldsView",
    ]:
        assert forbidden not in max_prob_body
        assert forbidden not in wifi_fw
    assert "scanEntryBase + 15" not in body


def test_wifi_rx_hwdesc_init_uses_typed_descriptor_overlays():
    wifi_fw = wifi_fw_policy_source()

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
    rx_dma_layout = wifi_fw.split(
        "MachwRxDmaRegsView {.packed.} = object", 1
    )[1].split("MachwSecurityRegsView {.packed.} = object", 1)[0]

    for expected in [
        "MachwRxDmaRegsView {.packed.} = object",
        "rxDmaBaseToTriggerPadding*: array[0x180, uint8]",
        "triggerToSubmittedHeadPadding*: array[0x34, uint8]",
        "submittedHeadToHwHeadPadding*: array[0x388, uint8]",
        "doAssert offsetof(MachwRxDmaRegsView, rxDmaBaseToTriggerPadding) == 0x000",
        "doAssert offsetof(MachwRxDmaRegsView, trigger) == 0x180",
        "doAssert offsetof(MachwRxDmaRegsView, triggerToSubmittedHeadPadding) == 0x184",
        "doAssert offsetof(MachwRxDmaRegsView, hdSubmittedHead) == 0x1B8",
        "doAssert offsetof(MachwRxDmaRegsView, pdSubmittedHead) == 0x1BC",
        "doAssert offsetof(MachwRxDmaRegsView, submittedHeadToHwHeadPadding) == 0x1C0",
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
        "rxHeaderTailPadding*: array[28, uint8]",
        "RxSwTableDescView {.packed.} = object",
        "tableEntryPadding*: uint32",
        "tableEntryTailPadding*: array[16, uint8]",
        "mpduLengthPadding*: array[2, uint8]",
        "frameControlPadding*: array[4, uint8]",
        "bufferOffsetPadding*: array[8, uint8]",
        "mpduDescPadding*: uint32",
        "payloadDescTailPadding*: array[22, uint8]",
        "frameRefPadding*: array[24, uint8]",
        "chainHeadPadding*: uint32",
        "progressDescPadding*: uint32",
        "progressStatusPadding*: array[8, uint8]",
        "statusPadding*: uint16",
        "RxPayloadBufferView {.packed.} = object",
        "doAssert sizeof(RxHeaderHwDescView) == 100",
        "doAssert offsetof(RxHeaderHwDescView, rxHeaderTailPadding) == 68",
        "doAssert sizeof(RxSwTableDescView) == 24",
        "doAssert offsetof(RxSwDescView, mpduLengthPadding) == 30",
        "doAssert offsetof(RxMpduDescView, mpduDescPadding) == 0",
        "doAssert sizeof(RxPayloadHwDescView) == 52",
        "doAssert offsetof(RxPayloadHwDescView, payloadDescTailPadding) == 30",
        "template rxHeaderHwDescAt(rxDescRingIndex: int): ptr RxHeaderHwDescView",
        "template rxHeaderHwDescView(param: pointer): ptr RxHeaderHwDescView",
        "template rxSwTableDescAt(rxDescRingIndex: int): ptr RxSwTableDescView",
        "template rxPayloadHwDescAt(rxDescRingIndex: int): ptr RxPayloadHwDescView",
        "template rxPayloadBufferAt(rxDescRingIndex: int): ptr RxPayloadBufferView",
    ]:
        assert expected in wifi_fw
    for forbidden in [
        "reserved000*",
        "reserved184*",
        "reserved1c0*",
        "template rxHeaderHwDescAt(idx: int): ptr RxHeaderHwDescView",
        "template rxSwTableDescAt(idx: int): ptr RxSwTableDescView",
        "template rxPayloadHwDescAt(idx: int): ptr RxPayloadHwDescView",
        "template rxPayloadBufferAt(idx: int): ptr RxPayloadBufferView",
    ]:
        assert forbidden not in rx_dma_layout

    assert "for rxSwTableIndex in 0 ..< 41:" in sw_body
    assert "rxSwTableDescAt(rxSwTableIndex).firstHeaderDesc =" in sw_body
    assert "cast[pointer](rxHeaderHwDescAt(rxSwTableIndex))" in sw_body
    for expected in [
        "for headerDescIndex in 0 ..< HD_COUNT:",
        "let hd = rxHeaderHwDescAt(headerDescIndex)",
        "let dmaOwned = hd.usedFlag",
        "cast[ptr RxHeaderHwDescView](hdPrev).next = cast[pointer](hd)",
        "hd.nextThd = 0",
        "hd.status = 0",
        "hd.flags = 0",
        "hd.swDesc = cast[uint32](rxSwTableDescAt(headerDescIndex))",
        "hd.magic = BAADF00D",
        "rxHeaderHwDescAt(headerDescIndex + 1)",
        "for payloadDescIndex in 0 ..< PD_COUNT:",
        "let pd = rxPayloadHwDescAt(payloadDescIndex)",
        "let dmaOwned = pd.usedFlag",
        "cast[ptr RxPayloadHwDescView](pdPrev).next = cast[pointer](pd)",
        "let payloadBuffer = rxPayloadBufferAt(payloadDescIndex)",
        "pd.magic = C0DEDBAD",
        "rxPayloadHwDescAt(payloadDescIndex + 1)",
        "pd.status = 0",
        "pd.bufferAddr = cast[uint32](addr payloadBuffer.payloadBytes[0])",
        "pd.bufferEnd = cast[uint32](addr payloadBuffer.payloadBytes[1735])",
        "pd.bufferStart = cast[uint32](addr payloadBuffer.payloadBytes[0])",
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
            "hd.tsfLow = 0",
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
        "rxSwTableDescAt(i).firstHeaderDesc",
        "let hd = rxHeaderHwDescAt(i)",
        "hd.swDesc = cast[uint32](rxSwTableDescAt(i))",
        "let pd = rxPayloadHwDescAt(i)",
        "let payloadBuffer = rxPayloadBufferAt(i)",
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
    wifi_fw = wifi_fw_policy_source()
    dump_body = wifi_fw.split("proc rxl_hwdesc_dump*", 1)[1].split(
        "proc rxl_hd_append*", 1
    )[0]

    for expected in [
        "for headerDescDumpIndex in 0'u32 ..< 41:",
        "let hd = rxHeaderHwDescAt(headerDescDumpIndex.int)",
        "headerDescDumpIndex, cast[pointer](hd)",
        "hd.magic",
        "pointerAddrU32(hd.next)",
        "hd.tsfLow",
        "hd.rxVector1c",
        "for payloadDescDumpIndex in 0'u32 ..< 41:",
        "let pd = rxPayloadHwDescAt(payloadDescDumpIndex.int)",
        "payloadDescDumpIndex, cast[pointer](pd)",
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
        "let hd = rxHeaderHwDescAt(i.int)",
        "let pd = rxPayloadHwDescAt(i.int)",
    ]:
        assert forbidden not in dump_body


def test_wifi_channel_tbtt_reschedule_uses_explicit_list_drain_condition():
    wifi_fw = wifi_fw_policy_source()

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
    assert "let poppedTbttListNode = co_list_pop_front(tbttList)" in tbtt_body
    assert "let tbttNode = chanTbttNodeAt(cast[pointer](poppedTbttListNode))" in tbtt_body
    assert "let tbttVifIdx = tbttNode.vifIdx" in tbtt_body
    assert "let previousTargetTime = tbttNode.targetTime" in tbtt_body
    assert "let missedTbttCount = tbttNode.priority" in tbtt_body
    assert "chan_tbtt_insert(cast[pointer](poppedTbttListNode))" in tbtt_body
    assert "let entry = co_list_pop_front(tbttList)" not in tbtt_body
    assert "let entryNode = chanTbttNodeAt(cast[pointer](entry))" not in tbtt_body
    assert "chan_tbtt_insert(cast[pointer](entry))" not in tbtt_body


def test_wifi_channel_tbtt_conflict_uses_semantic_clear_countdown_name():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split(
        "proc chan_tbtt_detect_conflict*(newTime: uint32, curTime: uint32): bool {.exportc, cdecl, noinline.} =",
        1,
    )[1].split(
        "proc chan_tbtt_insert*",
        1,
    )[0]

    assert "let tbttConflictClearCountdown = chanTbttConflictCounter()[]" in body
    assert "if tbttConflictClearCountdown > 0:" in body
    assert "chanTbttConflictCounter()[] = tbttConflictClearCountdown - 1" in body
    assert "if tbttConflictClearCountdown - 1 == 0:" in body
    assert "let cnt = chanTbttConflictCounter()[]" not in body
    assert "cnt - 1" not in body


def test_wifi_chan_get_next_uses_typed_vif_overlay_for_roc_lookup():
    wifi_fw = wifi_fw_policy_source()

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
    assert "for channelContextPoolIndex in 0'u8 .. 2'u8:" in body
    assert "let cand = chanCtxtForIdx(channelContextPoolIndex)" in body
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
    assert "let cand = chanCtxtForIdx(i)" not in body
    assert "cast[ptr uint8](candAddr + 22)[]" not in body
    assert "cast[ptr uint16](candAddr + 18)[]" not in body


def test_wifi_chan_ctxt_add_uses_semantic_pool_index_name():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split(
        "proc chan_ctxt_add*(param: pointer, ctxtIdxOut: ptr uint8): uint8 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc chan_ctxt_del*",
        1,
    )[0]

    assert "let chanCtxtPoolIndex =" in body
    assert "ctxt.contextIndexOrMarker = chanCtxtPoolIndex" in body
    assert "ctxtIdxOut[] = chanCtxtPoolIndex" in body
    assert "for existingChannelContextIndex in 0'u8 ..< 3:" in body
    assert "ctxtIdxOut[] = existingChannelContextIndex" in body
    assert "contextIndexOrMarker*: uint8" in wifi_fw
    assert "doAssert offsetof(ChanCtxtView, contextIndexOrMarker) == 23" in wifi_fw
    assert "let idx = ((cast[uint](ctxt) - poolBase)" not in body
    assert "ctxt.contextIndexOrMarker = idx" not in body
    assert "ctxt.idx" not in body
    assert "ctxtIdxOut[] = idx" not in body
    assert "for i in 0'u8 ..< 3:" not in body


def test_wifi_chan_init_uses_semantic_pool_index_name():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split("proc chan_init*", 1)[1].split(
        "proc chan_ctxt_add*",
        1,
    )[0]

    for expected in [
        "for chanCtxtPoolIndex in 0 ..< 5:",
        "let ctxt = chanCtxtAt(poolBase + chanCtxtPoolIndex.uint * sizeof(ChanCtxtView).uint)",
        "if chanCtxtPoolIndex <= 2:",
        "co_list_push_back(addr env.freeList, ctxt.chanCtxtHdr)",
    ]:
        assert expected in body

    for forbidden in [
        "for i in 0 ..< 5:",
        "poolBase + i.uint * sizeof(ChanCtxtView).uint",
        "if i <= 2:",
    ]:
        assert forbidden not in body


def test_wifi_channel_tx_power_uses_typed_vif_overlays():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc chan_update_tx_power*", 1)[1].split(
        "proc chan_conn_less_delay_evt*", 1
    )[0]

    for expected in [
        "let vif0 = vifChannelForIdx(0)",
        "let vif0Ctxt = vif0.chanCtxt",
        "let currentTxPower = vif0.txPower",
        "let maxTxPower = vif0.maxTxPower",
        "let vif1 = vifChannelForIdx(1)",
        "let vif1Ctxt = vif1.chanCtxt",
        "let currentTxPower = vif1.txPower",
        "let maxTxPower = vif1.maxTxPower",
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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
        "payloadWords*: UncheckedArray[uint32]",
        "doAssert offsetof(IpcEmbMsgEnvelopeView, desc) == 0",
        "doAssert offsetof(IpcEmbMsgEnvelopeView, payload) == 8",
        "template ipcPayloadWordStreamAt(payload: pointer): ptr IpcPayloadWordStreamView",
        "proc copyIpcPayloadWords(destPayload: pointer; sourcePayload: pointer; byteLen: uint32)",
        "destWords.payloadWords[payloadWordIndex] = sourceWords.payloadWords[payloadWordIndex]",
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
        "proc copyIpcPayloadWords(dst, src: pointer; byteLen: uint32)",
        "dstWords.payloadWords[wordIdx] = srcWords.payloadWords[wordIdx]",
        "let v = cast[ptr uint32](paySrc + cursor.uint)[]",
        "cast[ptr uint32](addr shared.payload[cursor])[] = v",
        "let srcWord = cast[ptr uint32](addr shared.payload[cursor])[]",
        "cast[ptr uint32](addr payload[cursor])[] = srcWord",
    ]:
        assert forbidden not in push_body
        assert forbidden not in evt_body


def test_wifi_ipc_tx_event_yields_under_host_descriptor_backlog():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    assert "handlerCountTailPadding*: uint16" in wifi_fw
    assert "doAssert offsetof(KeMsgHandlerDesc, handlerCountTailPadding) == 6" in wifi_fw
    assert (
        "keMsgHandlerEntryAt(table: pointer,\n"
        "                             handlerEntryIndex: uint16): ptr KeMsgHandlerEntry"
    ) in wifi_fw
    assert "keMsgHandlerDescAt(table: pointer, state: uint16): ptr KeMsgHandlerDesc" in wifi_fw
    assert "let messageHandlerEntry = keMsgHandlerEntryAt(table, handlerIndex.uint16)" in handler_body
    assert "if uint16(messageHandlerEntry.msgId) == msgId:" in handler_body
    assert "return messageHandlerEntry.handler" in handler_body
    assert "let entry = keMsgHandlerEntryAt(table, handlerIndex.uint16)" not in handler_body
    assert "let stateDesc = keMsgHandlerDescAt(desc.stateTable, curState)" in schedule_body
    assert "entryBase = cast[uint](table)" not in handler_body
    assert "keMsgHandlerEntryAt(table, i.uint16)" not in handler_body
    assert "keMsgHandlerEntryAt(table: pointer, idx: uint16)" not in wifi_fw
    assert "cast[uint](desc.stateTable)" not in schedule_body
    assert "padding*: uint16        # offset 6" not in wifi_fw
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
    assert "rawHandlerResult >= KeMsgConsumed and rawHandlerResult <= KeMsgSaved" in schedule_body
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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    channel_context_layout = wifi_fw.split(
        "ConnectInfoChannelContextOverlay {.packed.} = object", 1
    )[1].split("ApmStartInfoView {.packed.} = object", 1)[0]
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
        "credentialsToChannelTypePadding*: array[289, uint8]",
        "doAssert offsetof(ConnectInfoChannelContextOverlay, credentialsToChannelTypePadding) == 190",
        "doAssert offsetof(ConnectInfoChannelContextOverlay, chanType) == 479",
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
    assert "reserved190*" not in channel_context_layout

    for forbidden in [
        "cast[ptr uint16](addr ci.channelHint[0])[]",
        "cast[ptr uint16](addr req.channelHint[0])[]",
    ]:
        assert forbidden not in bss_body
        assert forbidden not in connect_body


def test_wifi_bss_params_falls_back_to_typed_directed_scan_result():
    wifi_fw = wifi_fw_policy_source()

    helper_body = wifi_fw.split(
        "proc bestDirectedScanuResult(searchData: pointer; searchLen: uint8)", 1
    )[1].split(
        "# ###########################################################################", 1
    )[0]
    bss_body = wifi_fw.rsplit(
        "proc sm_get_bss_params*", 1
    )[1].split(
        "proc sm_scan_bss*", 1
    )[0]

    for expected in [
        "proc bestDirectedScanuResult(searchData: pointer; searchLen: uint8)",
        "if scanu_env.directedFound == 0:",
        "for scanResultSlotIndex in 0 ..< SCANU_MAX_RESULT_ENTRIES:",
        "let scanResultEntry = addr scanu_env.entries[scanResultSlotIndex]",
        "if scanResultEntry.valid == 0 or scanResultChannelPtr(scanResultEntry) == nil:",
        "if not scanuCachedSsidMatches(scanResultEntry, searchData, searchLen):",
        "if best == nil or scanResultEntry.rssi > bestRssi:",
        "proc sm_get_bss_params*(selectedBssResultOut: ptr pointer, selectedBssChannelOut: ptr pointer): bool",
        "selectedBssResultOut[] = nil",
        "selectedBssChannelOut[] = nil",
        "let scanResultChannel = scanResultChannelPtr(bssidResultEntry)",
        "selectedBssChannelOut[] = scanResultChannel",
        "let ssidResultChannel = scanResultChannelPtr(ssidResultEntry)",
        "selectedBssChannelOut[] = ssidResultChannel",
        "let directed = bestDirectedScanuResult(cast[pointer](addr searchSlot.ssidBytes[0]),",
        "selectedBssResultOut[] = cast[pointer](directed)",
        "selectedBssChannelOut[] = scanResultChannelPtr(directed)",
    ]:
        assert expected in wifi_fw

    assert "rawMsgPtr" not in helper_body
    assert "let entry = addr scanu_env.entries[i]" not in helper_body
    assert "if entry.valid == 0 or entry.chanPtr == nil:" not in helper_body
    for forbidden in [
        "resultOut",
        "chanPtrOut",
        "let chanPtr = scanuResultAt(scanResult).chanPtr",
        "let chanPtr = scanuResultAt(ssidResult).chanPtr",
    ]:
        assert forbidden not in bss_body
    assert bss_body.index(
        "let directed = bestDirectedScanuResult(cast[pointer](addr searchSlot.ssidBytes[0]),"
    ) < \
        bss_body.index("elif connectInfoHasChannelHint(ci):")


def test_wifi_sta_join_channel_context_uses_typed_center_frequency_helpers():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split(
        "proc chan_scan_req*", 1
    )[1].split(
        "proc chan_roc_req*", 1
    )[0]

    for expected in [
        "proc chanScanDurationTicks(req: ptr ChanScanReqPayload): uint16",
        "template chanScanChannel(req: ptr ChanScanReqPayload): ptr ChanCtxtDefView",
        "vifIdxDurationPadding*: uint16",
        "bandPrimaryFreqPadding*: uint8",
        "txPowerPayloadTailPadding*: array[15, uint8]",
        "abortPayloadTailPadding*: array[19, uint8]",
        "doAssert offsetof(ChanScanReqPayload, vifIdxDurationPadding) == 2",
        "doAssert offsetof(ChanScanReqPayload, duration) == 4",
        "doAssert offsetof(ChanScanReqPayload, bandPrimaryFreqPadding) == 9",
        "doAssert offsetof(ChanScanReqPayload, prim20Freq) == 10",
        "doAssert offsetof(ChanScanReqPayload, txPowerPayloadTailPadding) == 17",
        "doAssert offsetof(ChanScanAbortPayload, abortPayloadTailPadding) == 1",
        "vifIdxToDurationPadding*: array[3, uint8]",
        "durationToActivePadding*: array[2, uint8]",
        "slotToRequestVifPadding*: uint8",
        "requestVifIdx*: uint8",
        "doAssert offsetof(ChanScanPoolOverlay, vifIdxToDurationPadding) == 11",
        "doAssert offsetof(ChanScanPoolOverlay, durationToActivePadding) == 16",
        "doAssert offsetof(ChanScanPoolOverlay, slotToRequestVifPadding) == 20",
        "doAssert offsetof(ChanScanPoolOverlay, requestVifIdx) == 21",
        "durationToStatePadding*: array[2, uint8]",
        "slotToBandPadding*: uint8",
        "doAssert offsetof(ChanRocOverlay, vifIdxToDurationPadding) == 1",
        "doAssert offsetof(ChanRocOverlay, durationToStatePadding) == 6",
        "doAssert offsetof(ChanRocOverlay, slotToBandPadding) == 10",
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

    chan_scan_layout = wifi_fw.split(
        "ChanScanReqPayload {.packed.} = object", 1
    )[1].split("ProbeReqFixedFrame", 1)[0]
    for forbidden in [
        "reserved0*: uint16",
        "reserved1*: uint8",
        "reserved2*: array[15, uint8]",
        "reserved*: array[19, uint8]",
    ]:
        assert forbidden not in chan_scan_layout

    scan_pool_layout = wifi_fw.split(
        "ChanScanPoolOverlay {.packed.} = object", 1
    )[1].split("ChanRocOverlay {.packed.} = object", 1)[0]
    roc_layout = wifi_fw.split(
        "ChanRocOverlay {.packed.} = object", 1
    )[1].split("ChanTbttNodeView {.packed.} = object", 1)[0]
    for forbidden in [
        "reserved99*",
        "reserved104*",
        "reserved108*",
    ]:
        assert forbidden not in scan_pool_layout
    for forbidden in [
        "reserved127*",
        "reserved132*",
        "reserved136*",
    ]:
        assert forbidden not in roc_layout


def test_wifi_channel_context_view_padding_is_semantic():
    wifi_fw = wifi_fw_policy_source()

    chan_ctxt_layout = wifi_fw.split(
        "ChanCtxtView {.packed.} = object",
        1,
    )[1].split("ChanScanPoolOverlay {.packed.} = object", 1)[0]

    for expected in [
        "invalidMarkerToSlotsPadding*: uint8",
        "altIdxTailPadding*: array[2, uint8]",
        "doAssert offsetof(ChanCtxtView, invalidMarkerToSlotsPadding) == 15",
        "doAssert offsetof(ChanCtxtView, schedSlot) == 16",
        "doAssert offsetof(ChanCtxtView, opSlot) == 18",
        "doAssert offsetof(ChanCtxtView, tbttSlot) == 20",
        "doAssert offsetof(ChanCtxtView, contextIndexOrMarker) == 23",
        "doAssert offsetof(ChanCtxtView, linkCount) == 24",
        "doAssert offsetof(ChanCtxtView, altIdxTailPadding) == 26",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "idx*: uint8",
        "doAssert offsetof(ChanCtxtView, idx) == 23",
        "reserved15*",
        "reserved26*",
    ]:
        assert forbidden not in chan_ctxt_layout


def test_wifi_channel_context_scheduler_uses_semantic_scan_credit_slot_name():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split(
        "proc chan_ctxt_op_evt*() {.exportc, cdecl.} =",
        1,
    )[1].split("proc chan_get_next_tbtt", 1)[0]

    assert "let scanCreditSlotDuration = env.ctxtCount.uint16 * 50" in body
    assert "ctxt.schedSlot = scanCreditSlotDuration" in body
    assert "let slot = env.ctxtCount.uint16 * 50" not in body
    assert "ctxt.schedSlot = slot\n" not in body


def test_wifi_scan_security_ie_store_uses_semantic_assoc_slot_name():
    scan_station = (ROOT / "src/bl808/wifi/fw/scan_station_ap_me.nim").read_text()
    body = scan_station.split("let effectiveCipher = securityState.cipher", 1)[
        1
    ].split("var notify", 1)[0]

    assert "let assocSecurityIeSlot =" in body
    assert "assocSecIeStore[assocSecurityIeSlot][0]" in body
    assert (
        "securityState.rsnIePtr =\n                cast[uint32](addr assocSecIeStore[assocSecurityIeSlot][0])"
        in body
    )
    assert "let slot = if vifView.vifIdx.int < MAX_VIFS" not in body
    assert "assocSecIeStore[slot][0]" not in body


def test_wifi_auth_rx_debug_counters_cover_classifier_dispatch_and_handler():
    wifi_fw = wifi_fw_policy_source()
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
    wifi_fw = wifi_fw_policy_source()
    wifi_tx = nim_source_with_includes(ROOT / "src/bl808/wifi/tx.nim")
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
        "repairDhcpUdpChecksum(ethernetFrameBytes, txPbufView.len.uint32)",
        "nimFwDbgDhcpCfmStatusLog[ringIdx]",
        "nimFwDbgDhcpCfmMetaLog[ringIdx]",
        "if (txStatusWord and FrameSuccessfulTxBit) != 0'u32:",
        "inc nimFwDbgDhcpCfmAckOk",
        "inc nimFwDbgDhcpCfmAckFail",
        "nimFwDbgDhcpTxMsgHist[msgType]",
        "var dhcpOptionOffset = 282'u",
        "let dhcpOptionCode = ethernetFrameBytes[dhcpOptionOffset]",
        "let dhcpOptionLength = ethernetFrameBytes[dhcpOptionOffset + 1'u]",
        "dhcpOptionOffset += 2'u + dhcpOptionLength.uint",
        "nimFwDbgDhcpRequestTxBreakpoint()",
        "for dhcpTxRawByteIndex in 0 ..< nimFwDbgDhcpTxRawLen.int:",
        "nimFwDbgDhcpTxRaw[dhcpTxRawByteIndex] =",
        "ethernetFrameBytes[dhcpTxRawByteIndex]",
    ]:
        assert expected in wifi_tx
    assert "var off = 282'u" not in wifi_tx
    assert "let opt = ethernetFrameBytes[off]" not in wifi_tx
    assert "for i in 0 ..< nimFwDbgDhcpTxRawLen.int:" not in wifi_tx
    assert "nimFwDbgDhcpTxRaw[i] = ethernetFrameBytes[i]" not in wifi_tx

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
    msg_tx = nim_source_with_includes(ROOT / "src/bl808/wifi/msg_tx.nim")

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


def test_wifi_apm_start_request_builder_uses_semantic_country_ie_names():
    msg_tx = nim_source_with_includes(ROOT / "src/bl808/wifi/msg_tx.nim")

    country_body = msg_tx.split("proc fillCountryIe", 1)[1].split(
        "proc bl_send_apm_start_req*", 1
    )[0]
    start_body = msg_tx.split("proc bl_send_apm_start_req*", 1)[1].split(
        "proc bl_send_apm_stop_req*", 1
    )[0]

    for expected in [
        "(countryIeOut: pointer): uint8",
        "storeU8(countryIeOut, 0, 7)",
        "storeU8(countryIeOut, 1, 6)",
        "storeU8(countryIeOut, 2, countryCode0)",
        "storeU8(countryIeOut, 6, channelNumDefault.uint8)",
        "storeU8(countryIeOut, 7, countryMaxPower)",
    ]:
        assert expected in country_body

    for expected in [
        "let apmStartReq = blMsgZalloc(APM_START_REQ, TASK_APM, DRV_TASK_ID, SizeApmStartReq)",
        "if apmStartReq == nil: return -Enomem",
        "storeU8(apmStartReq, ApmChanOff + ScanChanBandOff, NL80211_BAND_2GHZ)",
        "copyMem(ptrAt(apmStartReq, ApmSsidOff + MacSsidArrayOff), ssid, ssidLen)",
        "storeU8(apmStartReq, ApmBcnBufLenOff, fillCountryIe(ptrAt(apmStartReq, ApmBcnBufOff)))",
        "blSendMsg(blHw, apmStartReq, 1, APM_START_CFM, cfm)",
    ]:
        assert expected in start_body

    for forbidden in [
        "(buf: pointer): uint8",
        "storeU8(buf, 0, 7)",
        "storeU8(buf, 7, countryMaxPower)",
    ]:
        assert forbidden not in country_body

    for forbidden in [
        "let req = blMsgZalloc(APM_START_REQ, TASK_APM, DRV_TASK_ID, SizeApmStartReq)",
        "if req == nil: return -Enomem",
        "storeU8(req, ApmChanOff + ScanChanBandOff, NL80211_BAND_2GHZ)",
        "copyMem(ptrAt(req, ApmSsidOff + MacSsidArrayOff), ssid, ssidLen)",
        "fillCountryIe(ptrAt(req, ApmBcnBufOff))",
        "blSendMsg(blHw, req, 1, APM_START_CFM, cfm)",
    ]:
        assert forbidden not in start_body


def test_wifi_connect_bssid_loops_use_semantic_byte_names():
    connect_helpers = (
        ROOT / "src/bl808/wifi/msg_tx/station_parts/connect_helpers.nim"
    ).read_text()
    connect_request = (
        ROOT / "src/bl808/wifi/msg_tx/station_parts/connect_request.nim"
    ).read_text()

    helper_body = connect_helpers.split("proc macIsSpecial", 1)[1]
    request_body = connect_request.split("proc bl_send_sm_connect_req*", 1)[1]

    for expected in [
        "for macByteIndex in 0 ..< 6:",
        "cast[ptr UncheckedArray[uint8]](mac)[macByteIndex] != value",
    ]:
        assert expected in helper_body

    for expected in [
        "for bssidByteOffset in 0 ..< 6:",
        "storeU8(req, SmBssidOff + bssidByteOffset.uint, 0xff)",
    ]:
        assert expected in request_body

    for forbidden in [
        "for i in 0 ..< 6:",
        "cast[ptr UncheckedArray[uint8]](mac)[i]",
        "SmBssidOff + i.uint",
    ]:
        assert forbidden not in helper_body
        assert forbidden not in request_body


def test_wifi_kernel_flush_uses_explicit_queue_drain_conditions():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    sta_register_param_layout = wifi_fw.split(
        "StaMgmtRegisterParamView {.packed.} = object", 1
    )[1].split("ChanEnvView {.packed.} = object", 1)[0]

    assert "while currentNode.next != nil:" in extract_body
    assert "var nextNode = currentNode.next" in extract_body
    assert "cur.next" not in extract_body
    assert "while true:" not in extract_body
    assert "while timQueue.first != nil:" in bcn_body
    assert "while true:" not in bcn_body
    assert "postponedStaHead*: pointer" in wifi_fw
    assert "doAssert offsetof(VifChannelView, postponedStaHead) == 340" in wifi_fw
    assert "template vifPostponedStaList(vif: ptr VifChannelView): ptr CoList =\n  cast[ptr CoList](addr vif.postponedStaHead)" in wifi_fw
    assert "var postponedStaNode = vif.postponedStaHead" in vif_postpone_body
    assert "let nextPostponedStaNode = cast[pointer](cast[ptr CoListHdr](postponedStaNode).next)" in vif_postpone_body
    assert "cast[ptr pointer](vif + 340)" not in vif_postpone_body
    assert "cast[ptr pointer](cast[uint](postponedStaNode))" not in vif_postpone_body
    assert "let vif = vifChannelForIdx(instNbr)" in sta_register_body
    assert "let keyPtrs = vifKeyPointers(vif)" in sta_register_body
    assert "extFlagToAssocInfoPadding*: uint8" in wifi_fw
    assert "doAssert offsetof(StaMgmtRegisterParamView, extFlagToAssocInfoPadding) == 15" in wifi_fw
    assert "var staIdx = 0'u8" in sta_register_body
    assert "while staIdx < STA_MGMT_FREE_STAS.uint8 and staInfoForIdx(staIdx) != sta:" in sta_register_body
    assert "var postponedDescTimerAddr = staEntry + 338" in sta_register_body
    assert "for postponedDescSlotIndex in 0 ..< 9:" in sta_register_body
    assert "cast[ptr uint16](postponedDescTimerAddr)[] = 0xFFFF'u16" in sta_register_body
    assert "postponedDescTimerAddr += 4" in sta_register_body
    assert "sta.txPolicy = cast[pointer](txBufferControlDescAt(staIdx.int))" in sta_register_body
    assert "sta.keyMat = cast[pointer](addr sta.keyHolder)" in sta_register_body
    assert "co_list_push_back(vifPostponedStaList(vif), cast[ptr CoListHdr](staEntry))" in sta_register_body

    assert "let vif = vifChannelForIdx(instNbr)" in sta_unregister_body
    assert "co_list_extract(vifPostponedStaList(vif), cast[ptr CoListHdr](sta))" in sta_unregister_body
    assert "of 1, 2:" in sta_add_key_body
    assert "let temporalKeySrcU = cast[uint](machwKeyWriteKeyTailPtr(req))" in sta_add_key_body
    assert "let temporalKeyDstU = cast[uint](addr sta.keyTail[0])" in sta_add_key_body
    assert "for temporalKeyWordIndex in 0 ..< 4:" in sta_add_key_body
    assert "temporalKeyDstU + (temporalKeyWordIndex * 4).uint" in sta_add_key_body
    assert "temporalKeySrcU + (temporalKeyWordIndex * 4).uint" in sta_add_key_body
    assert "let keySrcU = cast[uint](machwKeyWriteKeyTailPtr(req))" not in sta_add_key_body
    assert "for i in 0 ..< 4:" not in sta_add_key_body
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
        "var descAddr = staEntry + 338",
        "for i in 0 ..< 9:",
        "cast[ptr uint16](descAddr)[]",
        "descAddr += 4",
        "let postponedListAddr = staEntry + 240",
        "sta.keyMat = cast[pointer](postponedListAddr)",
        "reserved15*",
    ]:
        assert forbidden not in sta_register_body
        assert forbidden not in sta_unregister_body
        assert forbidden not in chan_idle_body
    assert "while postponedTxDesc != nil:" in postpone_body
    assert "let postponedDesc = apmTxDescPsAt(postponedTxDesc)" in postpone_body
    assert "let frameTid = postponedDesc.tid" in postpone_body
    assert "postponedDesc.tid = cast[uint8]((psStatus and 3) + 3)" in postpone_body
    assert "let remainingTid = apmTxDescPsAt(remainingPostponedTxDesc).tid" in postpone_body
    assert "cast[ptr CoListHdr](postponedTxDesc).next" in postpone_body
    assert "assert_warn(\"apm.c\", \"apm.c\", 377)" in postpone_body
    assert "reserved15*" not in sta_register_param_layout
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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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

    assert "var postponedFramesSent: uint32 = 0" in service_body
    assert (
        "while sta.postponedList.first != nil and\n"
        "      (maxCount == 0 or postponedFramesSent < maxCount):"
    ) in service_body
    assert "while true:" not in service_body
    assert "discard sta_mgmt_postponed_desc_release(staEntry, 0)" in service_body
    assert "postponedFramesSent += 1" in service_body
    assert "return postponedFramesSent" in service_body
    assert "let txDesc = hostTxDescAt(postponedTxDesc)" in release_body
    assert "let nextPostponedTxDesc = cast[pointer](cast[ptr CoListHdr](postponedTxDesc).next)" in release_body
    assert "let txTime = txDesc.pendingMacTime" in release_body
    assert "while true:" not in release_body
    assert "for postponedStaIndex in 0'u8 ..< STA_INFO_TAB_ENTRIES.uint8:" in aging_body
    assert "let sta = staInfoForIdx(postponedStaIndex)" in aging_body
    assert "for i in 0'u8 ..< STA_INFO_TAB_ENTRIES.uint8:" not in aging_body
    assert "let sta = staInfoForIdx(i)" not in aging_body
    assert "sta_mgmt_postponed_desc_release(cast[pointer](sta), 0)" in aging_body
    for forbidden in [
        "var count: uint32 = 0",
        "count += 1",
        "return count",
        "count < maxCount",
    ]:
        assert forbidden not in service_body
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
    wifi_fw = wifi_fw_policy_source()

    ps_flags_layout = wifi_fw.split(
        "KeEnvPsFlagsView {.packed.} = object", 1
    )[1].split("TxControlAcView {.packed.} = object", 1)[0]
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
        "apToOtherPendingPadding*: uint8",
        "otherPending*: uint8",
        "staPending*: uint8",
        "doAssert sizeof(KeEnvPsFlagsView) == 5",
        "doAssert offsetof(KeEnvPsFlagsView, apPending) == 1",
        "doAssert offsetof(KeEnvPsFlagsView, apToOtherPendingPadding) == 2",
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
    assert "reserved30*" not in ps_flags_layout


def test_wifi_sta_ht_vht_param_uses_sta_info_overlay():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc mm_bcn_transmit*", 1)[1].split(
        "proc mm_tim_update*", 1
    )[0]

    for expected in [
        "template vifApBeaconFrameDesc(vif: ptr VifChannelView): ptr TxlFrameDescView",
        "frameDescPrefixPadding*: array[47, uint8]",
        "vifIdxPadding*: uint8",
        "stationInfoPadding*: array[48, uint8]",
        "retryCountPadding*: uint8",
        "statusBytePadding*: array[7, uint8]",
        "txHeaderPadding*: array[92, uint8]",
        "probeHeaderPadding*: array[16, uint8]",
        "payloadPtrPadding*: uint32",
        "doAssert offsetof(TxlFrameDescView, frameDescPrefixPadding) == 0",
        "doAssert offsetof(TxlFrameDescView, vifIdx) == 47",
        "doAssert offsetof(TxlFrameDescView, vifIdxPadding) == 48",
        "doAssert offsetof(TxlFrameDescView, staInfoIdx) == 49",
        "doAssert offsetof(TxlFrameDescView, stationInfoPadding) == 50",
        "doAssert offsetof(TxlFrameDescView, retryCountPadding) == 99",
        "doAssert offsetof(TxlFrameDescView, statusBytePadding) == 101",
        "doAssert offsetof(TxlFrameDescView, txHeaderPadding) == 116",
        "doAssert offsetof(TxlThdProbeView, probeHeaderPadding) == 0",
        "doAssert offsetof(TxlThdProbeView, payloadPtr) == 16",
        "doAssert offsetof(TxlThdProbeView, payloadPtrPadding) == 20",
        "doAssert offsetof(TxlThdProbeView, bufLen) == 24",
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
        if expected.startswith(("template", "doAssert")) or "*:" in expected:
            assert expected in wifi_fw
        else:
            assert expected in body

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    beacon_body = wifi_fw.rsplit("proc me_build_beacon*", 1)[1].split(
        "proc me_build_probe_rsp*", 1
    )[0]
    probe_body = wifi_fw.rsplit("proc me_build_probe_rsp*", 1)[1].split(
        "proc me_build_capability*", 1
    )[0]
    me_env_layout = wifi_fw.split(
        "MeEnvView {.packed.} = object", 1
    )[1].split("MeChannelConfigEntry {.packed.} = object", 1)[0]
    me_channel_entry_layout = wifi_fw.split(
        "MeChannelConfigEntry {.packed.} = object", 1
    )[1].split("MeChannelConfigView {.packed.} = object", 1)[0]
    me_channel_layout = wifi_fw.split(
        "MeChannelConfigView {.packed.} = object", 1
    )[1].split("MeBeaconSequenceOverlay {.packed.} = object", 1)[0]
    me_beacon_seq_layout = wifi_fw.split(
        "MeBeaconSequenceOverlay {.packed.} = object", 1
    )[1].split("MmEnvView {.packed.} = object", 1)[0]

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
        "MeEnvView {.packed.} = object",
        "psModeToDefaultKeyPadding*: uint8",
        "htCapabilityTailPadding*: array[2, uint8]",
        "doAssert offsetof(MeEnvView, psModeToDefaultKeyPadding) == 127",
        "doAssert offsetof(MeEnvView, htCapabilityTailPadding) == 134",
        "MeChannelConfigEntry {.packed.} = object",
        "freq*: uint16",
        "band*: uint8",
        "flags*: uint8",
        "txPower*: int8",
        "txPowerTailPadding*: uint8",
        "doAssert offsetof(MeChannelConfigEntry, band) == 2",
        "doAssert offsetof(MeChannelConfigEntry, flags) == 3",
        "doAssert offsetof(MeChannelConfigEntry, txPower) == 4",
        "doAssert offsetof(MeChannelConfigEntry, txPowerTailPadding) == 5",
        "MeChannelConfigView {.packed.} = object",
        "countTailPadding*: uint8",
        "doAssert offsetof(MeChannelConfigView, countTailPadding) == 85",
        "MeBeaconSequenceOverlay {.packed.} = object",
        "meEnvBaseToSeqCounterPadding*: array[84, uint8]",
        "doAssert offsetof(MeBeaconSequenceOverlay, meEnvBaseToSeqCounterPadding) == 0",
        "seqCounter*: uint16",
        "doAssert offsetof(MeBeaconSequenceOverlay, seqCounter) == 84",
        "template meBeaconSequence(): ptr MeBeaconSequenceOverlay",
    ]:
        assert expected in wifi_fw
    for forbidden in [
        "reserved127*",
        "reserved134*",
    ]:
        assert forbidden not in me_env_layout
    assert "data*: array[4, uint8]" not in me_channel_entry_layout
    assert "reserved85*" not in me_channel_layout
    assert "reserved00*" not in me_beacon_seq_layout


def test_wifi_sae_and_assoc_rsp_builders_use_typed_vif_overlays():
    wifi_fw = wifi_fw_policy_source()
    wmm_source_layout = wifi_fw.split(
        "MmWmmParameterSourceView {.packed.} = object", 1
    )[1].split("MmBcnEnvView {.packed.} = object", 1)[0]

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
        "discard c_memcpy(addr body.variablePayload[0], saeData, saeLen.csize_t)",
        "return saeLen + sizeof(AuthFixedBodyView).uint32",
    ]:
        assert expected in sae_body

    for expected in [
        "AuthBodyDataView {.packed.} = object",
        "variablePayload*: UncheckedArray[uint8]",
        "doAssert offsetof(AuthBodyDataView, variablePayload) == sizeof(AuthFixedBodyView)",
        "AssocRspFixedBodyView {.packed.} = object",
        "doAssert sizeof(AssocRspFixedBodyView) == 6",
        "BssMaxIdlePeriodIeView {.packed.} = object",
        "idlePeriod*: uint16",
        "idleOptions*: uint8",
        "doAssert sizeof(BssMaxIdlePeriodIeView) == 5",
        "doAssert offsetof(BssMaxIdlePeriodIeView, idlePeriod) == 2",
        "MmWmmParameterSourceView {.packed.} = object",
        "wmmSourceBaseToAcParamsPadding*: array[8, uint8]",
        "acBk*: uint32",
        "acBe*: uint32",
        "acVi*: uint32",
        "acVo*: uint32",
        "doAssert offsetof(MmWmmParameterSourceView, wmmSourceBaseToAcParamsPadding) == 0",
        "doAssert offsetof(MmWmmParameterSourceView, acBk) == 8",
        "doAssert offsetof(MmWmmParameterSourceView, idleOptions) == 26",
        "doAssert offsetof(VifChannelView, wmmQosInfo) == 452",
        "template mmWmmParameterSource(): ptr MmWmmParameterSourceView",
        "proc setLe32*(rec: var WmmAcParamRecord; value: uint32) {.inline.}",
    ]:
        assert expected in wifi_fw

    assert "reserved00*" not in wmm_source_layout

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc me_add_ie_ssid*", 1)[1].split(
        "proc me_add_ie_supp_rates*", 1
    )[0]

    for expected in [
        "SsidIeView {.packed.} = object",
        "ssidBytes*: UncheckedArray[uint8]",
        "template ssidIeAt(p: pointer): ptr SsidIeView",
        "doAssert offsetof(SsidIeView, ssidBytes) == 2",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let ie = ssidIeAt(bufPtrPtr[])",
        "ie.ie.id = 0'u8",
        "ie.ie.len = ssidLen",
        "co_pack8p(addr ie.ssidBytes[0], ssid, ssidLen.uint32)",
        "bufPtrPtr[] = addr ie.ssidBytes[ssidLen]",
    ]:
        assert expected in body

    for forbidden in [
        "data*: UncheckedArray[uint8]",
        "doAssert offsetof(SsidIeView, data) == 2",
        "ie.data",
        "let p = cast[uint](bufPtrPtr[])",
        "cast[ptr uint8](p)[] = 0'u8",
        "cast[ptr uint8](p + 1)[] = ssidLen",
        "co_pack8p(cast[pointer](p + 2), ssid, ssidLen.uint32)",
        "bufPtrPtr[] = cast[pointer](p + total.uint)",
    ]:
        assert forbidden not in body


def test_wifi_capability_builder_uses_typed_vif_overlay():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    bitfield_body = wifi_fw.rsplit("proc me_legacy_rate_bitfield_build*", 1)[1].split(
        "proc me_legacy_ridx_min*", 1
    )[0]
    min_rate_body = wifi_fw.rsplit("proc me_legacy_ridx_min*", 1)[1].split(
        "proc me_legacy_ridx_max*", 1
    )[0]
    max_rate_body = wifi_fw.rsplit("proc me_legacy_ridx_max*", 1)[1].split(
        "proc me_rate_bitfield_vht_build*", 1
    )[0]
    basic_body = wifi_fw.rsplit("proc me_get_basic_rates*", 1)[1].split(
        "proc me_freq_to_chan_ptr*", 1
    )[0]
    freq_body = wifi_fw.rsplit("proc me_freq_to_chan_ptr*", 1)[1].split(
        "proc me_extract_rate_set*", 1
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
        "payload*: UncheckedArray[uint8]",
        "doAssert offsetof(RateSetView, rates) == 1",
        "doAssert offsetof(MacIeDataView, payload) == 2",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let rateSet = rateSetAt(rates)",
        "let rateCount = rateSet.count.int",
        "let rateByte = rateSet.rates[rateIndex] and 0x7F",
    ]:
        assert expected in bitfield_body

    for expected in [
        "for legacyRateBitIndex in 0'u32 ..< 12:",
        "if ((bitfield shr legacyRateBitIndex) and 1) != 0:",
        "return legacyRateBitIndex.uint8",
    ]:
        assert expected in min_rate_body

    for expected in [
        "for legacyRateReverseBitIndex in countdown(11'i32, 0):",
        "if ((bitfield shr legacyRateReverseBitIndex.uint32) and 1) != 0:",
        "return legacyRateReverseBitIndex.uint8",
    ]:
        assert expected in max_rate_body

    for expected in [
        "for channelConfigIndex in 0 ..< chanConfig.count.int:",
        "let channelConfigEntry = addr chanConfig.entries[channelConfigIndex]",
        "if channelConfigEntry.freq == freq:",
        "return cast[pointer](channelConfigEntry)",
    ]:
        assert expected in freq_body

    for expected in [
        "let rateSet = rateSetAt(cast[pointer](vifIdx))",
        "let output = rateSetAt(outputBuf)",
        "output.count = 0",
        "let rateCount = rateSet.count",
        "let rate = rateSet.rates[rateIndex]",
        "let basicRateOutputCount = output.count",
        "output.rates[basicRateOutputCount] = rate",
        "output.count = basicRateOutputCount + 1",
    ]:
        assert expected in basic_body

    for expected in [
        "let rateSet = rateSetAt(rateSetPtr)",
        "let rateCount = rateSet.count",
        "let ie = macIeDataAt(bufPtrPtr[])",
        "ie.ie.id = 1'u8",
        "ie.ie.len = writeCount",
        "co_pack8p(addr ie.payload[0], addr rateSet.rates[0], writeCount.uint32)",
        "bufPtrPtr[] = addr ie.payload[writeCount]",
    ]:
        assert expected in supp_body

    for expected in [
        "let rateSet = rateSetAt(rateSetPtr)",
        "let ie = macIeDataAt(bufPtrPtr[])",
        "ie.ie.id = 50'u8",
        "ie.ie.len = extCount.uint8",
        "co_pack8p(addr ie.payload[0], addr rateSet.rates[8], extCount.uint32)",
        "bufPtrPtr[] = addr ie.payload[extCount]",
    ]:
        assert expected in ext_body

    for forbidden in [
        "cast[ptr uint8](rateSetPtr)[]",
        "data*: UncheckedArray[uint8]",
        "doAssert offsetof(MacIeDataView, data) == 2",
        "ie.data",
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
        "for i in 0'u32 ..< 12:",
        "if ((bitfield shr i) and 1) != 0:",
        "for i in countdown(11'i32, 0):",
        "if ((bitfield shr i.uint32) and 1) != 0:",
        "for i in 0 ..< chanConfig.count.int:",
        "let entry = addr chanConfig.entries[i]",
    ]:
        assert forbidden not in bitfield_body
        assert forbidden not in min_rate_body
        assert forbidden not in max_rate_body
        assert forbidden not in basic_body
        assert forbidden not in freq_body
        assert forbidden not in supp_body
        assert forbidden not in ext_body


def test_wifi_one_byte_ies_use_typed_overlays():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    output_layout = wifi_fw.split(
        "PowerConstraintOutputOverlay {.packed.} = object", 1
    )[1].split("CountryRegOutputOverlay {.packed.} = object", 1)[0]
    body = wifi_fw.rsplit("proc me_extract_power_constraint*", 1)[1].split(
        "proc me_11n_nss_max*", 1
    )[0]

    for expected in [
        "PowerConstraintOutputOverlay {.packed.} = object",
        "outputBaseToPowerConstraintPadding*: array[132, uint8]",
        "constraint*: uint8",
        "doAssert offsetof(PowerConstraintOutputOverlay, outputBaseToPowerConstraintPadding) == 0",
        "doAssert offsetof(PowerConstraintOutputOverlay, constraint) == 132",
        "template powerConstraintOutputAt(p: pointer): ptr PowerConstraintOutputOverlay",
        "powerConstraintOutputAt(out_ptr).constraint = constraintVal",
    ]:
        assert expected in wifi_fw if expected.startswith(("PowerConstraint", "outputBase", "constraint", "doAssert", "template")) else expected in body

    for forbidden in [
        "cast[ptr uint8](cast[uint](out_ptr) + 132)",
        "cast[uint](out_ptr) + 132",
    ]:
        assert forbidden not in body
    assert "reserved00*" not in output_layout


def test_wifi_country_reg_extractor_uses_typed_overlays():
    wifi_fw = wifi_fw_policy_source()

    output_layout = wifi_fw.split(
        "CountryRegOutputOverlay {.packed.} = object", 1
    )[1].split("CountryRegView {.packed.} = object", 1)[0]
    country_reg_layout = wifi_fw.split(
        "CountryRegView {.packed.} = object", 1
    )[1].split("CountryTripletView {.packed.} = object", 1)[0]
    body = wifi_fw.rsplit("proc me_extract_country_reg*", 1)[1].split(
        "proc me_extract_csa*", 1
    )[0]

    for expected in [
        "CountryRegOutputOverlay {.packed.} = object",
        "outputBaseToChannelRegPadding*: array[76, uint8]",
        "channelReg*: pointer",
        "CountryRegView {.packed.} = object",
        "environment*: uint8",
        "environmentToMaxPowerPadding*: uint8",
        "maxPower*: uint8",
        "CountryTripletView {.packed.} = object",
        "firstChan*: uint8",
        "numChan*: uint8",
        "doAssert offsetof(CountryRegOutputOverlay, outputBaseToChannelRegPadding) == 0",
        "doAssert offsetof(CountryRegOutputOverlay, channelReg) == 76",
        "doAssert offsetof(CountryRegView, environment) == 2",
        "doAssert offsetof(CountryRegView, environmentToMaxPowerPadding) == 3",
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
    assert "reserved00*" not in output_layout
    assert "reserved03*" not in country_reg_layout


def test_wifi_csa_ie_builder_uses_typed_overlay():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    beacon_body = wifi_fw.rsplit("proc me_build_beacon*", 1)[1].split(
        "proc me_build_probe_rsp*", 1
    )[0]
    probe_body = wifi_fw.rsplit("proc me_build_probe_rsp*", 1)[1].split(
        "proc me_build_add_ba_req*", 1
    )[0]

    for expected in [
        "proc ieCursorAfter(ieCursor: pointer; byteCount: uint): pointer {.inline.}",
        "addr cast[ptr UncheckedArray[uint8]](ieCursor)[byteCount]",
        "proc copyIeBytes(ieDestCursor: pointer; ieSourceBytes: pointer; byteCount: uint): pointer {.inline.}",
        "ieCursorAfter(ieDestCursor, byteCount)",
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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc sm_assoc_rsp_handler*", 1)[1].split(
        "proc sm_deauth_handler*", 1
    )[0]
    assoc_rsp_layout = wifi_fw.split(
        "SmAssocRspFrameView {.packed.} = object", 1
    )[1].split("AuthFixedBodyView {.packed.} = object", 1)[0]

    for expected in [
        "SmAssocRspFrameView {.packed.} = object",
        "macHeaderAssocBodyPadding*: array[30, uint8]",
        "doAssert offsetof(SmAssocRspFrameView, macHeaderAssocBodyPadding) == 2",
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
            "SmAssocRspFrameView" in expected or
            "macHeaderAssocBodyPadding" in expected or
            "TimeoutIntervalIeView" in expected or
            expected in ("intervalType*: uint8", "intervalValue*: array[4, uint8]") or
            expected.startswith("doAssert") or
            expected.startswith("template ")
        ) else expected in body

    assert "reserved02*" not in assoc_rsp_layout

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
    wifi_fw = wifi_fw_policy_source()

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
        "doAssert offsetof(StaInfoView, powerConstraintOutputStorage) == 338",
        "template staPowerConstraintOut(sta: ptr StaInfoView): pointer",
        "cast[pointer](addr sta.powerConstraintOutputStorage[10])",
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
    wifi_fw = wifi_fw_policy_source()

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
        "for challengeByteIndex in 0 ..< 128:",
        "challenge.challengeText[challengeByteIndex] = src[challengeByteIndex]",
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
        "challenge.challengeText[i] = src[i]",
    ]:
        assert forbidden not in body


def test_wifi_auth_handler_uses_semantic_auth_frame_overlay():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc sm_auth_handler*", 1)[1].split(
        "proc sm_assoc_rsp_handler*", 1
    )[0]
    auth_frame_layout = wifi_fw.split(
        "SmAuthFrameView {.packed.} = object", 1
    )[1].split("SmAssocRspFrameView {.packed.} = object", 1)[0]

    for expected in [
        "SmAuthFrameView {.packed.} = object",
        "macHeaderAuthBodyPadding*: array[30, uint8]",
        "sharedChallengeLen*: uint8",
        "doAssert offsetof(SmAuthFrameView, macHeaderAuthBodyPadding) == 2",
        "doAssert offsetof(SmAuthFrameView, sharedChallengeLen) == 39",
        "doAssert offsetof(SmAuthFrameView, sharedChallengeFirst) == 40",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let frame = smAuthFrameView(param)",
        "let statusCode = frame.statusCode",
        "frame.authAlgo.uint32 or (frame.authSeq.uint32 shl 16)",
        "let authAlgo = frame.authAlgo",
        "let saeSeq = frame.authSeq",
        "saeAuthFrameHandler(smAuthSaeBodyPtr(frame), frameLen - 6, saeSeq, nil)",
        "smAuthSharedChallengePtr(frame)",
    ]:
        assert expected in body

    for forbidden in [
        "reserved02*",
        "reserved39*",
    ]:
        assert forbidden not in auth_frame_layout


def test_wifi_deauth_builder_uses_typed_reason_overlay():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc me_build_associate_req_impl", 1)[1].split(
        "proc me_build_associate_rsp_impl", 1
    )[0]
    assoc_layout = wifi_fw.split(
        "VifAssocInfoOverlay {.packed.} = object", 1
    )[1].split("SecMacRxIndView {.packed.} = object", 1)[0]

    for expected in [
        "VifAssocInfoOverlay {.packed.} = object",
        "assocBaseToSsidPadding*: array[38, uint8]",
        "ssidLen*: uint8",
        "ssidData*: array[49, uint8]",
        "basicRates*: array[13, uint8]",
        "basicRatesToWmmQosPadding*: array[3, uint8]",
        "wmmQosInfo*: uint8",
        "wmmQosToSecurityFlagsPadding*: array[31, uint8]",
        "securityFlags*: uint32",
        "securityFlagsToRsnIePadding*: array[4, uint8]",
        "rsnIePtr*: uint32",
        "rsnIeLen*: uint8",
        "WmmInfoIeView {.packed.} = object",
        "qosInfo*: uint8",
        "AssocReqFixedBodyView {.packed.} = object",
        "doAssert sizeof(AssocReqFixedBodyView) == 10",
        "doAssert offsetof(AssocReqFixedBodyView, reassocBssid) == 4",
        "doAssert offsetof(VifAssocInfoOverlay, assocBaseToSsidPadding) == 0",
        "doAssert offsetof(VifAssocInfoOverlay, ssidLen) == 38",
        "doAssert offsetof(VifAssocInfoOverlay, basicRates) == 88",
        "doAssert offsetof(VifAssocInfoOverlay, basicRatesToWmmQosPadding) == 101",
        "doAssert offsetof(VifAssocInfoOverlay, wmmQosInfo) == 104",
        "doAssert offsetof(VifAssocInfoOverlay, wmmQosToSecurityFlagsPadding) == 105",
        "doAssert offsetof(VifAssocInfoOverlay, securityFlags) == 136",
        "doAssert offsetof(VifAssocInfoOverlay, securityFlagsToRsnIePadding) == 140",
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
        "else: assoc.wmmQosInfo",
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

    for forbidden in [
        "reserved00*",
        "reserved101*",
        "reserved105*",
        "reserved140*",
    ]:
        assert forbidden not in assoc_layout


def test_wifi_notifier_chain_uses_shared_explicit_list_helpers():
    wifi_fw = wifi_fw_policy_source()

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
    element_notify_layout = wifi_fw.split(
        "ElementNotifyContextView {.packed.} = object", 1
    )[1].split("KeEnvPsFlagsView {.packed.} = object", 1)[0]

    assert "ElementNotifyContextView {.packed.} = object" in wifi_fw
    assert "notifyBaseToStatePadding*: array[8, uint8]" in wifi_fw
    assert "template notifierNodeView(node: ptr CoListHdr): ptr NotifierNodeView" in wifi_fw
    assert "template elementNotifyContextAt(ctx: pointer): ptr ElementNotifyContextView" in wifi_fw
    assert "doAssert offsetof(NotifierNodeView, callback) == 0" in wifi_fw
    assert "doAssert offsetof(NotifierNodeView, next) == 4" in wifi_fw
    assert "doAssert offsetof(NotifierNodeView, priority) == 8" in wifi_fw
    assert "doAssert offsetof(ElementNotifyContextView, notifyBaseToStatePadding) == 0" in wifi_fw
    assert "doAssert offsetof(ElementNotifyContextView, state) == 8" in wifi_fw
    assert "let newNode = notifierNodeView(notifier)" in insert_body
    assert "let currentNode = notifierNodeView(currentNotifier)" in insert_body
    assert "newNode.next = cast[pointer](currentNotifier)" in insert_body
    assert "linkSlot = addr currentNode.next" in insert_body
    assert "notifierNodeView(notifier).next" in remove_body
    assert "linkSlot = addr notifierNodeView(currentNotifier).next" in remove_body
    assert "let notifierNode = notifierNodeView(currentNotifier)" in call_body
    assert "let nextNotifier = cast[ptr CoListHdr](notifierNode.next)" in call_body
    assert "notifierNode.callback" in call_body
    assert "currentNotifier = nextNotifier" in call_body
    assert "let notifierNode = notifierNodeView(currentNotifier)" in call_critical_body
    assert "notifierNode.callback" in call_critical_body
    assert "currentNotifier = cast[ptr CoListHdr](notifierNode.next)" in call_critical_body
    assert "while currentNotifier != nil:" in insert_body
    assert "while true:" not in insert_body
    assert "while currentNotifier != nil:" in remove_body
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
    assert "reserved00*" not in element_notify_layout


def test_wifi_rate_control_random_sample_selection_is_bounded():
    wifi_fw = wifi_fw_policy_source()

    delay_body = wifi_fw.split(
        "proc platformDelay(us: uint32) {.inline.} =",
        1,
    )[1].split(
        "# =============================================================================\n# RC helper",
        1,
    )[0]
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
    assert "var delayLoopBudget = us * 10'u32" in delay_body
    assert "while delayLoopBudget > 0:" in delay_body
    assert "dec delayLoopBudget" in delay_body
    assert "var cnt = us * 10'u32" not in delay_body
    assert "var fallbackRateIndex = lo" in helper_body
    assert "while fallbackRateIndex <= hi:" in helper_body
    assert "rateMap shr fallbackRateIndex" in helper_body
    assert "inc fallbackRateIndex" in helper_body
    assert "var idx = lo" not in helper_body


def test_wifi_rate_control_helpers_use_semantic_rate_field_names():
    wifi_fw = wifi_fw_policy_source()

    mcs_body = wifi_fw.split(
        "proc rc_get_mcs_index*(rateConfig: uint16): uint8 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rc_get_nss*",
        1,
    )[0]
    nss_body = wifi_fw.split(
        "proc rc_get_nss*(rateConfig: uint16): uint8 {.exportc, cdecl, noinline.} =",
        1,
    )[1].split(
        "proc rc_check_valid_rate*",
        1,
    )[0]
    valid_body = wifi_fw.split(
        "proc rc_check_valid_rate*(stats: pointer, rateConfig: uint16): uint8 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rc_new_random_rate*",
        1,
    )[0]
    duplicate_body = wifi_fw.split(
        "proc rc_check_rate_duplicated*(stats: pointer, rateConfig: uint16): uint8 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rc_get_initial_rate_config*",
        1,
    )[0]
    random_body = wifi_fw.split(
        "proc rc_new_random_rate*(stats: pointer): uint16 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rc_update_stats*",
        1,
    )[0]

    for body in [mcs_body, nss_body]:
        assert "let nssEncodingOffset =" in body
        assert "if nssEncodingOffset > 1:" in body
        assert "let idx =" not in body
        assert "if idx > 1:" not in body

    assert "let legacyRateBitIndex = rc_get_mcs_index(rateConfig)" in valid_body
    assert "return ((rateMap shr legacyRateBitIndex) and 1).uint8" in valid_body
    assert "let idx = rc_get_mcs_index(rateConfig)" not in valid_body
    assert "rateMap shr idx" not in valid_body
    assert "for rateEntryIndex in 0 ..< nRates.int:" in duplicate_body
    assert "rcRateConfig(stats, rateEntryIndex) == rateConfig" in duplicate_body
    assert "for i in 0 ..< nRates.int:" not in duplicate_body
    assert "rcRateConfig(stats, i) == rateConfig" not in duplicate_body

    assert random_body.count("let randomRateOffset =") == 2
    assert random_body.count("let candidateRateIndex =") == 2
    assert "rateMap shr candidateRateIndex" in random_body
    assert "var mcsIdx = candidateRateIndex.uint16" in random_body
    assert "let rndIdx =" not in random_body
    assert "let idx = lowest +" not in random_body
    assert "rateMap shr idx" not in random_body


def test_wifi_rate_control_highest_bit_uses_semantic_result_name():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split(
        "proc rcHighestBit(rateBitmapByte: uint8): uint8 =",
        1,
    )[1].split(
        "proc rcLowestConfiguredLegacyRate",
        1,
    )[0]

    assert "var highestSetBitIndex: uint8 = 0" in body
    assert "inc highestSetBitIndex" in body
    assert "return highestSetBitIndex" in body
    assert "proc rcHighestBit(val: uint8): uint8 =" not in wifi_fw
    assert "var idx: uint8 = 0" not in body
    assert "var remainingBits = val" not in body
    assert "return idx" not in body


def test_wifi_kernel_timer_scheduler_yields_under_expired_backlog():
    wifi_fw = wifi_fw_policy_source()

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
    assert "let expiredTimerEntry = cast[ptr KeTimerEntry](popped)" in timer_body
    assert "ke_msg_send_basic(expiredTimerEntry.id, expiredTimerEntry.taskId, 0xFF)" in timer_body
    assert "platformFree(cast[pointer](expiredTimerEntry))" in timer_body
    assert "let entry = cast[ptr KeTimerEntry](popped)" not in timer_body
    assert "inc drained" in timer_body
    assert "nimFwDbgKeTimerYieldHead = nextTimer.time" in timer_body
    assert "if keTimerExpired(nextTimer):" in timer_body
    assert "inc nimFwDbgKeTimerYield" in timer_body
    assert "ke_evt_set(KE_EVT_KE_TIMER)" in timer_body
    assert "ke_timer_hw_set(nextTimer)" in timer_body
    assert "ke_timer_hw_set(nil)" in timer_body


def test_wifi_rx_dispatch_uses_semantic_message_index_name():
    dispatch = (ROOT / "src/bl808/wifi/rx/dispatch.nim").read_text()
    body = dispatch.split("proc rxHandlerFor", 1)[1].split("proc dispatchMsg", 1)[0]

    assert "let taskMessageIndex = msgIndex(id)" in body
    assert body.count("case taskMessageIndex") == 5
    assert "let index = msgIndex(id)" not in body
    assert "case index" not in body


def test_wifi_mm_timer_scheduler_yields_under_expired_backlog():
    wifi_fw = wifi_fw_policy_source()

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
    assert "if mmTimerExpired(nextTimerNode):" in timer_body
    assert "inc nimFwDbgMmTimerYield" in timer_body
    assert "ke_evt_set(KE_EVT_MM_TIMER)" in timer_body
    assert "mm_timer_hw_set(cast[pointer](nextTimerNode))" in timer_body
    assert "mm_timer_hw_set(nil)" in timer_body
    assert "if mmTimerExpired(next):" not in timer_body
    assert "mm_timer_hw_set(cast[pointer](next))" not in timer_body


def test_ble_event_scheduler_yields_under_backlog():
    ble = blecontroller_policy_source()

    event_body = ble.split("proc patch_ble_ke_event_schedule*", 1)[1].split(
        "proc ble_ke_event_schedule*", 1
    )[0]

    assert "BleKeEventDrainLimit = 8'u32" in ble
    assert "nim_ble_ke_event_yield_count" in ble
    assert "nim_ble_ke_event_yield_field" in ble
    assert "proc bleKeEventYieldNeeded(drainedCount, pendingEventBits: uint32): bool" in ble
    assert "var drainedCount = 0'u32" in event_body
    assert "inc drainedCount" in event_body
    assert "if bleKeEventYieldNeeded(drainedCount, pendingEventBits):" in event_body
    assert "inc nim_ble_ke_event_yield_count" in event_body
    assert "nim_ble_ke_event_yield_field = pendingEventBits" in event_body
    assert "return" in event_body
    assert "proc bleKeEventYieldNeeded(drained, field: uint32): bool" not in ble
    assert "if bleKeEventYieldNeeded(drained, field):" not in event_body


def test_ble_timer_scheduler_yields_under_expired_backlog():
    ble = blecontroller_policy_source()

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
    assert "if drained >= BleKeTimerDrainLimit and bleKeTimerExpired(nextTimer):" in timer_body
    assert "inc nim_ble_ke_timer_yield_count" in timer_body
    assert "nim_ble_ke_timer_yield_time = nextTimer.time" in timer_body
    assert "ble_ke_timer_hw_set(nextTimer)" in timer_body
    assert "if drained >= BleKeTimerDrainLimit and bleKeTimerExpired(next):" not in timer_body
    assert "nim_ble_ke_timer_yield_time = next.time" not in timer_body
    assert "ble_ke_timer_hw_set(next)" not in timer_body
    assert "bleKeTimerPendingWork()" in service_body
    assert "ble_ke_timer_schedule()" in service_body


def test_ble_hci_reset_settle_is_cps_state_not_busy_wait():
    ble = blecontroller_policy_source()

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
    ble = blecontroller_policy_source()

    body = ble.split("proc hci_msg_cmd_status_exp*", 1)[1].split(
        "proc hci_msg_evt_get_hl_tl_dest*", 1
    )[0]
    evt_body = ble.split("proc hci_msg_evt_get_hl_tl_dest*", 1)[1].split(
        "proc led_init*", 1
    )[0]
    status_desc_block = ble.split("HciCmdStatusDescView {.packed.} = object", 1)[1].split(
        "HciRawCmdView {.packed.} = object", 1
    )[0]

    assert "HciCmdStatusDescView {.packed.} = object" in ble
    assert "statusDescriptorPrefixPadding*: array[8, uint8]" in ble
    assert "expectedStatusWord*: uint32" in ble
    assert "doAssert sizeof(HciCmdStatusDescView) == 12" in ble
    assert "doAssert offsetof(HciCmdStatusDescView, statusDescriptorPrefixPadding) == 0" in ble
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
    assert "reserved00*: array[8, uint8]" not in status_desc_block


def test_ble_raw_hci_rf_and_ecc_paths_use_typed_overlays():
    ble = blecontroller_policy_source()

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
    ble = blecontroller_policy_source()

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
        "EmBufNode* {.packed.} = object",
        "status*: uint16",
        "poolSlotIndex*: uint16",
        "emBufferOffset*: uint16",
        "doAssert sizeof(EmBufRxFreeSlot) == EM_BUF_RX_DESC_SIZE",
        "doAssert offsetof(EmBufRxFreeSlot, status) == 0",
        "doAssert offsetof(EmBufRxFreeSlot, emBufferOffset) == 8",
        "doAssert sizeof(EmBufNode) == 8",
        "doAssert offsetof(EmBufNode, poolSlotIndex) == 4",
        "doAssert offsetof(EmBufNode, emBufferOffset) == 6",
        "template bleEmBytes(): ptr UncheckedArray[uint8]",
        "template btbleEmBytes(): ptr UncheckedArray[uint8]",
        "proc bleEmPointer(offset: uint16): pointer",
        "proc btbleEmBytePtr(offset: uint16): ptr uint8",
        "proc btbleEmPayload(offset: uint16): ptr UncheckedArray[uint8]",
        "proc btbleEmRead8(offset: uint16): uint8",
        "proc btbleEmWrite8(offset: uint16, value: uint8)",
        "proc copyBtbleEmBytes(destEmOffset: uint16, sourceBytesPtr: ptr uint8, byteCount: int)",
        "template emRxDescTableAt(base: uint32): ptr UncheckedArray[EmBufRxDesc]",
        "template emTxDescTableAt(base: uint32): ptr UncheckedArray[EmBufTxDesc]",
        "template emRxFreeTable(): ptr UncheckedArray[EmBufRxFreeSlot]",
        "cast[ptr UncheckedArray[EmBufRxFreeSlot]](bleEmPointer(0x35C'u16))",
        "proc emRxFreeSlotAt(rxFreeSlotIndex: uint16): ptr EmBufRxFreeSlot",
    ]:
        assert expected in ble

    for expected in [
        "addr emRxDescTableAt(base)[rxDescIndex]",
        "addr emTxDescTableAt(base)[txDescIndex]",
        "addr emRxFreeTable()[rxFreeSlotIndex]",
        "addr emRxFreeSlotAt(rxFreeSlotIndex).status",
        "addr emRxFreeSlotAt(rxFreeSlotIndex).emBufferOffset",
        "for rxBufferSlotIndex in 0'u16 ..< EM_BUF_RX_COUNT:",
        "let desc = emRxDescAt(rx_base, rxBufferSlotIndex)",
        "let buf_offset = 0x3CC'u16 + rxBufferSlotIndex * EM_BUF_RX_DATA_SIZE.uint16",
        "volatileStore(addr desc.emBufferOffset, buf_offset)",
        "for txBufferSlotIndex in 0'u16 ..< EM_BUF_TX_COUNT.uint16:",
        "volatileStore(addr emTxDescAt(tx_base, txBufferSlotIndex).status, 0'u16)",
        "let statusField = emRxFreeStatusField(rxFreeSlotIndex)",
        "let bufferPointerField = emRxBufferPointerField(rxFreeSlotIndex)",
        "let emBufferOffset = volatileLoad(bufferPointerField)",
        "return bleEmPointer(emBufferOffset)",
        "let txEmBufferOffset = volatileLoad(addr txDesc.emBufferOffset)",
        "return bleEmPointer(txEmBufferOffset)",
        "let txPoolBufferOffset = txEmBufferOffset.uint32",
        "let poolDesc = emTxPoolDescForBufferOffset(txPoolBufferOffset)",
    ]:
        assert expected in helper_body + buffer_body

    for forbidden in [
        "base + idx.uint32 * EM_BUF_RX_DESC_SIZE",
        "base + idx.uint32 * EM_BUF_TX_DESC_SIZE",
        "BLE_EM_BASE + 0x35C'u32 +",
        "BLE_EM_BASE + 0x364'u32 +",
        "idx.uint32 * EM_BUF_RX_DESC_SIZE",
        "let offset = volatileLoad(bufferPointerField)",
        "let offset = volatileLoad(addr txDesc.emBufferOffset)",
        "let pool_idx = offset.uint32",
        "let pool_idx = txEmBufferOffset.uint32",
        "let desc = emRxDescAt(rx_base, i)",
        "volatileStore(addr emTxDescAt(tx_base, i).status, 0'u16)",
    ]:
        assert forbidden not in helper_body + buffer_body

    for expected in [
        "let data = btbleEmBytePtr(dataOff)",
        "btbleEmPayload(dataOff)",
        "let opcode = btbleEmRead8(dataOff)",
        "btbleEmWrite8(NimAclTxEmOffset, 0'u8)",
        "btbleEmWrite8(NimLlcpTxEmOffset + llcpTxPayloadByteIndex.uint16,",
        "pdu[llcpTxPayloadByteIndex]",
        "copyBtbleEmBytes(NimAclTxEmOffset, cast[ptr uint8](aclTxPayload), aclTxPayloadLen.int)",
        "cast[pointer](addr bleEmBytes()[offset])",
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
    ble = blecontroller_policy_source()

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
    ble = blecontroller_policy_source()

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
        "template btbleRxDescAt(rxDescAddress: uint32): ptr BtbleRxDescView",
        "proc btbleRxDescStatus(rxDescAddress: uint32): uint16",
        "proc btbleRxDescHeader(rxDescAddress: uint32): uint16",
        "proc btbleRxDescMeta(rxDescAddress: uint32): uint16",
        "proc btbleRxDescDataOffset(rxDescAddress: uint32): uint16",
        "proc btbleRxDescReset(rxDescAddress, nextDescEmOffset, rxDataEmOffset: uint32)",
        "proc btbleRxDescClearDone(rxDescAddress: uint32; status: uint16)",
        "proc btbleRxDescReleaseLink(rxDescAddress: uint32; status: uint16)",
    ]:
        assert expected in ble

    for expected in [
        "btbleRxDescMeta(desc) and 0x03FF'u16",
        "btbleRxDescClock(desc).uint32",
        "volatileLoad(addr rxDesc.timing0).uint32",
    ]:
        assert expected in timing_body

    for expected in [
            "let desc = BTBLE_EM_BASE + btbleRxDescOffset(advertisingRxDescIndex)",
            "let nextOff = btbleRxDescOffset(advertisingRxDescIndex + 1'u32)",
            "let rxBuf = 0x0B0D'u32 + advertisingRxDescIndex * 0x104'u32",
        "btbleRxDescReset(desc, nextOff, rxBuf)",
    ]:
        assert expected in reset_body

    for expected in [
            "let rxRingIndex = (rxRingStartIndex + step) and 0x07'u32",
            "let rxDescAddr = BTBLE_EM_BASE + btbleRxDescOffset(rxRingIndex)",
            "let rxStatus = btbleRxDescStatus(rxDescAddr)",
            "let rxHeader = btbleRxDescHeader(rxDescAddr)",
            "let rxDataOffset = btbleRxDescDataOffset(rxDescAddr)",
            "let scanReq = btbleScanReqPduAt(rxDataOffset)",
            "nim_ble_dbg_rx_scan_req_last_scana0 = bdAddrLow(addr scanReq.scanA)",
            "nim_ble_dbg_rx_scan_req_last_adva0 = bdAddrLow(addr scanReq.advA)",
            "if scanReq.advA.bytes[advAddrIndex] != expectedAdvAddrByte(advAddrIndex):",
            "let payload = btbleEmPayload(rxDataOffset)",
            "btbleRxDescClearDone(rxDescAddr, rxStatus)",
    ]:
        assert expected in adv_body

    for expected in [
            "btbleRxDescSetDataOffset(nimLldRxDescAddr(pendingRxDescRingIndex), buf)",
        "proc lld_rxdesc_check*(requestedRxDescIndex: uint8): pointer",
        "let status = btbleRxDescStatus(desc)",
        "let header = btbleRxDescHeader(desc)",
        "let meta = btbleRxDescMeta(desc)",
        "let rxDescMetaIndex = uint8((meta shr 11) and 0x001F'u16)",
        "if rxDescMetaIndex == (requestedRxDescIndex and 0x1F'u8):",
        "btbleRxDescDataOffset(desc)",
        "let payload = btbleEmPayload(dataOff)",
        "btbleRxDescReleaseLink(desc, status)",
        "btbleRxDescClearDone(descAddr, status)",
    ]:
        assert expected in lld_body

    for forbidden in [
        "proc lld_rxdesc_check*(idx: uint8): pointer",
        "let descIdx = uint8((meta shr 11) and 0x001F'u16)",
        "if descIdx == (idx and 0x1F'u8):",
    ]:
        assert forbidden not in lld_body

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
    ble = blecontroller_policy_source()

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
        "advPayload*: array[31, uint8]",
        "doAssert offsetof(BtbleAdvPduView, advA) == 0",
        "doAssert offsetof(BtbleAdvPduView, advPayload) == 6",
            "template btbleAdvPduAt(buf: uint16): ptr BtbleAdvPduView",
        "let advPdu = btbleAdvPduAt(buf)",
        "evt[4 + advertiserAddressByteIndex] =",
        "advPdu.advA.bytes[advertiserAddressByteIndex]",
        "advPdu.advPayload[advertisingDataByteIndex]",
    ]:
        assert expected in ble if expected.startswith(("Btble", "advA", "advPayload", "data", "doAssert", "template")) else expected in body
    assert "data*: array[31, uint8]" not in ble.split(
        "BtbleAdvPduView* {.packed.} = object", 1
    )[1].split("# ---------------------------------------------------------------------------", 1)[0]
    assert "advPdu.data" not in body

    for forbidden in [
        "let payloadBase = BTBLE_EM_BASE + buf.uint32",
        "read8(payloadBase + i.uint32)",
        "read8(payloadBase + 6'u32 + i.uint32)",
    ]:
        assert forbidden not in body


def test_ble_legacy_scan_init_tx_descs_use_typed_overlay():
    ble = blecontroller_policy_source()

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
    ble = blecontroller_policy_source()

    conn_body = ble.split("proc nimConnDescAddr", 1)[1].split(
        "proc nimConnEventReached", 1
    )[0]

    for expected in [
        "BtbleConnTxDescView* {.packed.} = object",
        "status*: uint16",
        "header*: uint16",
        "dataOffset*: uint16",
            "txPayloadTailPadding*: array[10, uint8]",
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
            "btbleConnTxDescClear(txDescAddress, nextDescEmOffset)",
            "btbleConnTxDescSetHeader(txDescAddress, descHeader)",
            "btbleConnTxDescSetDataOffset(txDescAddress, txDataEmOffset)",
            "btbleConnTxDescSetStatus(txDescAddress, nimConnDescStatus(nextDescEmOffset, softwareOwned = false))",
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
    ble = blecontroller_policy_source()

    anchor_body = ble.split("proc nimConnAnchorFromTiming", 1)[1].split(
        "proc nimConnAnchorFromRxTimestamp", 1
    )[0]
    start_body = ble.rsplit(
        "proc nimLldConStart(conhdl: uint16, params: pointer): uint8 {.cdecl.} =",
        1,
    )[1].split("proc nimLldConLlcpTx", 1)[0]
    con_start_diag_body = ble.split(
        "proc bleNimDbgVendorLldConStartParamWord*", 1
    )[1].split("proc bleNimDbgLldRxCheckCount*", 1)[0]

    for expected in [
        "centralRole*: uint8",
        "centralRolePadding*: array[7, uint8]",
        "doAssert offsetof(NimLldConStartParamsView, centralRole) == 40",
        "doAssert offsetof(NimLldConStartParamsView, centralRolePadding) == 41",
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
        "for connStartSnapshotByteIndex in 0 ..< nim_lld_con_start_param.len:",
        "nim_lld_con_start_param[connStartSnapshotByteIndex] =",
        "snapshotBytes[connStartSnapshotByteIndex]",
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

    for expected in [
        "paramWordIndex: uint32",
        "let paramByteOffset = (paramWordIndex and 0x0F'u32) * 4'u32",
        "nim_lld_con_start_param[paramByteOffset.int]",
        "nim_lld_con_start_param[paramByteOffset.int + 3]",
    ]:
        assert expected in con_start_diag_body
    for forbidden in [
        "word: uint32",
        "let base =",
        "nim_lld_con_start_param[base.int]",
    ]:
        assert forbidden not in con_start_diag_body

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


def test_ble_rx_clock_expansion_uses_semantic_low_halfword_name():
    ble = blecontroller_policy_source()

    conn_expand_body = ble.split("proc nimConnExpandClock", 1)[1].split(
        "proc nimConnAnchorFromRxTimestamp", 1
    )[0]
    init_expand_body = ble.split("proc nimInitExpandRxClock", 1)[1].split(
        "proc nimInitRxClock", 1
    )[0]

    for body in [conn_expand_body, init_expand_body]:
        assert "let rxClockLow16 = rawClock and 0x0000FFFF'u32" in body
        assert "var candidate = (reference and 0x0FFF0000'u32) or rxClockLow16" in body
        assert "rawLow" not in body


def test_ble_llcp_fixed_pdus_use_typed_overlays():
    ble = blecontroller_policy_source()

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
        "template nimLlcpLengthPduAt(llcpPdu: ptr UncheckedArray[uint8]): ptr NimLlcpLengthPduView",
        "template nimLlcpLengthPdu(llcpPdu: var NimLlcpPdu): ptr NimLlcpLengthPduView",
        "template nimLlcpConnectionUpdateInd(llcpPdu: var NimLlcpPdu): ptr NimLlcpConnectionUpdateIndView",
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
            "nim_conn_state.pendingChannelMap[channelMapByteIndex] =",
            "body.channelMap[channelMapByteIndex]",
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
    ble = blecontroller_policy_source()

    manual_tx_body = ble.split("when bl808BleNimManualConnTx:", 1)[1].split(
        "proc nimLlcpWireLength", 1
    )[0]
    conn_body = ble.rsplit("proc nimLldConLlcpTx", 1)[1].split(
        "proc startNimConnectionFromConnectInd", 1
    )[0]
    host_body = ble.split("proc hciAclTxDataStatus", 1)[1].split(
        "proc hciOwnedAclTxDataReceived", 1
    )[0]
    host_arm_body = ble.split("proc nimConnArmPendingHostAclTx", 1)[1].split(
        "proc nimConnProgramEm", 1
    )[0]
    tx_element_block = ble.split("NimConnTxElementView {.packed.} = object", 1)[1].split(
        "static:", 1
    )[0]

    for expected in [
        "NimConnTxElementView {.packed.} = object",
        "txElementPrefixPadding: array[4, uint8]",
        "emOffset: uint16",
        "length: uint16",
        "doAssert sizeof(NimConnTxElementView) == 8",
        "doAssert offsetof(NimConnTxElementView, txElementPrefixPadding) == 0",
        "doAssert offsetof(NimConnTxElementView, emOffset) == 4",
        "doAssert offsetof(NimConnTxElementView, length) == 6",
        "template nimConnTxElementAt(buf: pointer): ptr NimConnTxElementView",
        "proc nimConnTxElementInit(buf: pointer; emOffset, length: uint16)",
        "tx.emOffset = emOffset",
        "tx.length = length",
    ]:
        assert expected in ble
    assert "reserved00: array[4, uint8]" not in tx_element_block

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
        "let tx = nimConnTxElementAt(addr nim_acl_host_tx_buf[0])",
        "let len = tx.length",
        "nim_conn_state.txEmOffset = tx.emOffset",
    ]:
        assert expected in host_arm_body

    combined = manual_tx_body + conn_body + host_body + host_arm_body
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
    ble = blecontroller_policy_source()

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
        "statePadding: uint8",
        "doAssert offsetof(LlcProcEnvView, errCallback) == 0",
        "doAssert offsetof(LlcProcEnvView, procId) == 4",
        "doAssert offsetof(LlcProcEnvView, state) == 5",
        "doAssert offsetof(LlcProcEnvView, statePadding) == 6",
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
            "env.statePadding = 0",
        ]:
            assert expected in init_body

    for expected in [
        "let procEnv = llc_proc_get(conhdl, procId)",
        "let llcProcedureErrorCallback = llcProcEnv(procEnv).errCallback",
        "cast[LlcProcErrCallback](llcProcedureErrorCallback)(conhdl, status, param)",
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
    ble = blecontroller_policy_source()

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
    ble = blecontroller_policy_source()

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
        "acl.payload[aclPayloadByteIndex] = aclPayloadBytes[aclPayloadByteIndex]",
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
    ble = blecontroller_policy_source()

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
    ble = blecontroller_policy_source()

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
        "evt[6 + i] = req.peerAddr.bytes[i]",
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
    ble = blecontroller_policy_source()

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
    ble = blecontroller_policy_source()

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
    ble = blecontroller_policy_source()

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
    ble = blecontroller_policy_source()

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
    ble = blecontroller_policy_source()

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
        "for remoteFeatureByteIndex in 0 ..< 8:",
        "body.features[remoteFeatureByteIndex] =",
        "nimBleFeatureByte(features, remoteFeatureByteIndex)",
    ]:
        assert expected in ble if expected.startswith(("Hci", "subevent", "status", "handle", "features", "doAssert")) else expected in body

    for forbidden in [
        "var evt = [",
        "uint8(handle and 0xFF)",
        "uint8((handle shr 8) and 0xFF)",
        "body.features[i] = nimBleFeatureByte(features, i)",
        "evt[4 + i] = nimBleFeatureByte(features, i)",
    ]:
        assert forbidden not in body


def test_ble_connection_event_record_uses_typed_overlay():
    ble = blecontroller_policy_source()

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
    ble = blecontroller_policy_source()

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
    llm_event_mask_body = ble.split("proc llm_le_evt_mask_check*", 1)[1].split(
        "proc llm_get_connection_accept_timeout*", 1
    )[0]
    llm_master_body = ble.split("proc llm_master_ch_map_get*", 1)[1].split(
        "proc llm_rx_path_comp_get*", 1
    )[0]
    llm_update_body = ble.split("proc llm_ch_map_update*", 1)[1].split(
        "proc llm_ch_map_update_ind_handler*", 1
    )[0]
    llm_device_activity_body = ble.split("proc llmActivityStateByte", 1)[1].split(
        "proc llm_cmd_cmp_send*", 1
    )[0]

    for expected in [
        "LlcConEnv* = object",
        "storage*: array[420, uint8]",
        "llc_env_storage*: array[LLC_CON_MAX, LlcConEnv]",
        "LlcConnectionRuntimeView {.packed.} = object",
        "connInterval*: uint16",
        "connLatency*: uint16",
        "authPayloadTimeout*: uint16",
        "authPayloadRealTimeout*: uint16",
        "linkFlags*: uint16",
        "llcpStateFlags*: uint8",
        "LlcChannelAssessmentView {.packed.} = object",
        "flags*: uint16",
        "channelMap*: array[5, uint8]",
        "LlmChannelMapView {.packed.} = object",
        "localMap*: array[5, uint8]",
        "masterMap*: array[5, uint8]",
        "LlmRuntimeConfigView {.packed.} = object",
        "clockAccuracyMask*: uint32",
        "leEventMask*: array[8, uint8]",
        "connectionAcceptTimeout*: uint16",
        "suggestedMaxTxOctets*: uint16",
        "suggestedMaxTxTime*: uint16",
        "featureSet*: array[4, uint8]",
        "suggestedMaxRxOctets*: uint16",
        "rxPathCompensation*: int16",
        "txPathCompensation*: int16",
        "advertisingInterfaceMode*: uint8",
        "LlmActivitySlotView {.packed.} = object",
        "advertisingParamPtr*: uint32",
        "schedulerPlanElement*: array[24, uint8]",
        "peerAddr*: BdAddr",
        "peerAddrType*: uint8",
        "state*: uint8",
        "LlmDeviceListEntryView {.packed.} = object",
        "deviceAddr*: BdAddr",
        "addrType*: uint8",
        "flags*: uint8",
        "LlcDisconnectStateView {.packed.} = object",
        "reason*: uint8",
        "active*: uint8",
        "LldEvtEnv* = object",
        "storage*: array[256, uint8]",
        "lld_evt_env_storage*: array[512, uint8]",
        "LlmEnv* = object",
        "storage*: array[512, uint8]",
        "llm_env_storage*: LlmEnv",
        "doAssert offsetof(LlcConnectionRuntimeView, connInterval) == 14",
        "doAssert offsetof(LlcConnectionRuntimeView, authPayloadTimeout) == 58",
        "doAssert offsetof(LlcConnectionRuntimeView, linkFlags) == 128",
        "doAssert offsetof(LlcConnectionRuntimeView, llcpStateFlags) == 130",
        "doAssert offsetof(LlcChannelAssessmentView, flags) == 344",
        "doAssert offsetof(LlcChannelAssessmentView, channelMap) == 346",
        "doAssert offsetof(LlcDisconnectStateView, reason) == 413",
        "doAssert offsetof(LlcDisconnectStateView, active) == 414",
        "doAssert offsetof(LlmChannelMapView, localMap) == 344",
        "doAssert offsetof(LlmChannelMapView, masterMap) == 349",
        "doAssert offsetof(LlmRuntimeConfigView, leEventMask) == 4",
        "doAssert offsetof(LlmRuntimeConfigView, connectionAcceptTimeout) == 428",
        "doAssert offsetof(LlmRuntimeConfigView, suggestedMaxTxOctets) == 430",
        "doAssert offsetof(LlmRuntimeConfigView, featureSet) == 436",
        "doAssert offsetof(LlmRuntimeConfigView, suggestedMaxRxOctets) == 478",
        "doAssert offsetof(LlmRuntimeConfigView, rxPathCompensation) == 482",
        "doAssert offsetof(LlmRuntimeConfigView, txPathCompensation) == 484",
        "doAssert offsetof(LlmRuntimeConfigView, advertisingInterfaceMode) == 487",
        "doAssert sizeof(LlmActivitySlotView) == 64",
        "doAssert offsetof(LlmActivitySlotView, advertisingParamPtr) == 0",
        "doAssert offsetof(LlmActivitySlotView, schedulerPlanElement) == 4",
        "doAssert offsetof(LlmActivitySlotView, peerAddr) == 28",
        "doAssert offsetof(LlmActivitySlotView, peerAddrType) == 34",
        "doAssert offsetof(LlmActivitySlotView, state) == 60",
        "doAssert sizeof(LlmDeviceListEntryView) == 10",
        "doAssert offsetof(LlmDeviceListEntryView, deviceAddr) == 0",
        "doAssert offsetof(LlmDeviceListEntryView, addrType) == 8",
        "doAssert offsetof(LlmDeviceListEntryView, flags) == 9",
        "template llcConnectionRuntime(env: ptr LlcConEnv): ptr LlcConnectionRuntimeView",
        "template llcChannelAssessment(env: ptr LlcConEnv): ptr LlcChannelAssessmentView",
        "template llcDisconnectState(env: ptr LlcConEnv): ptr LlcDisconnectStateView",
        "template llmChannelMaps(): ptr LlmChannelMapView",
        "template llmRuntimeConfig(): ptr LlmRuntimeConfigView",
        "template llmActivitySlot(activityIndex: int): ptr LlmActivitySlotView",
        "addr llm_env_storage.storage[12])[activityIndex]",
        "template llmDeviceListEntry(deviceListIndex: int): ptr LlmDeviceListEntryView",
        "addr llm_env_storage.storage[356])[deviceListIndex]",
        "addr llm_env_storage.storage[12]",
        "addr llm_env_storage.storage[356]",
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
        "let runtimeCfg = llmRuntimeConfig()",
        "for leEventMaskByteIndex in 0 ..< hci_le_evt_mask.len:",
        "runtimeCfg.leEventMask[leEventMaskByteIndex] = hci_le_evt_mask[leEventMaskByteIndex]",
        "for dataChannelMapByteIndex in 0 ..< maps.localMap.len:",
        "maps.localMap[dataChannelMapByteIndex] = 0xFF'u8",
        "maps.masterMap[dataChannelMapByteIndex] = 0xFF'u8",
        "maps.localMap[4] = maps.localMap[4] and 0x1F'u8",
        "maps.masterMap[4] = maps.masterMap[4] and 0x1F'u8",
        "runtimeCfg.connectionAcceptTimeout = 0x1FA0'u16",
        "runtimeCfg.suggestedMaxTxOctets = 27'u16",
        "runtimeCfg.suggestedMaxTxTime = 0x0148'u16",
        "runtimeCfg.featureSet[0] = 0x07'u8",
        "runtimeCfg.suggestedMaxRxOctets = 0x0384'u16",
    ]:
        assert expected in llm_init_body
    for forbidden in [
        "runtimeCfg.leEventMask[i] = hci_le_evt_mask[i]",
        "maps.localMap[i] = 0xFF'u8",
        "maps.masterMap[i] = 0xFF'u8",
    ]:
        assert forbidden not in llm_init_body

    for expected in [
        "let eventMaskByteIndex = int(evtBit shr 3)",
        "if eventMaskByteIndex >= 8:",
        "let bitIdx = evtBit and 0x07'u8",
        "llmRuntimeConfig().leEventMask[eventMaskByteIndex]",
    ]:
        assert expected in llm_event_mask_body
    assert "byteIdx" not in llm_event_mask_body

    assert "addr llmChannelMaps().masterMap[0]" in llm_master_body
    assert "let maps = llmChannelMaps()" in llm_update_body
    assert "for masterChannelMapByteIndex in 0 ..< nextMap.len:" in llm_update_body
    assert "nextMap[masterChannelMapByteIndex] = maps.masterMap[masterChannelMapByteIndex]" in llm_update_body
    assert "for localChannelMapByteIndex in 0 ..< nextMap.len:" in llm_update_body
    assert "maps.localMap[localChannelMapByteIndex] = nextMap[localChannelMapByteIndex]" in llm_update_body
    assert "nextMap[i] = maps.masterMap[i]" not in llm_update_body
    assert "maps.localMap[i] = nextMap[i]" not in llm_update_body
    assert "let disconnect = llcDisconnectState(llc_env[conhdl])" in disconnect_body
    assert "if disconnect.active != 0:" in disconnect_body
    assert "disconnect.reason = reason" in disconnect_body
    assert "disconnect.active = 1" in disconnect_body

    for expected in [
        "llmDeviceListEntry(emptyDeviceListIndex).flags",
        "let deviceEntry = llmDeviceListEntry(deviceListIndex)",
        "deviceEntry.addrType == addrType",
        "co_bdaddr_compare(addr deviceEntry.deviceAddr, addrIn)",
        "let activity = llmActivitySlot(connectedActivityIndex)",
        "activity.state == 9'u8",
        "activity.peerAddrType xor addrType",
        "co_bdaddr_compare(addrIn, addr activity.peerAddr)",
        "discard c_memset(addr activity.peerAddr, 0, 32)",
        "llmActivityPlanElementPtr(activityId, false)",
        "llmActivityPlanElementPtr(activityId, true)",
        "activityStateByte[] = 0'u8",
        "activity.advertisingParamPtr",
        "advertisingParamAddr",
    ]:
        assert expected in llm_device_activity_body

    for forbidden in [
        "data*: array[420, uint8]",
        "data*: array[256, uint8]",
        "data*: array[512, uint8]",
        "llc_env_data*",
        "lld_evt_env_data*",
        "llm_env_data*",
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
        "llm_env_data.data[4 + i]",
        "llm_env_data.data[428]",
        "llm_env_data.data[429]",
        "llm_env_data.data[430]",
        "llm_env_data.data[432]",
        "llm_env_data.data[436]",
        "llm_env_data.data[478]",
        "llm_env_data.data[482]",
        "llm_env_data.data[484]",
        "llm_env_data.data[487]",
        "llm_env_data.data[365 + i * 10]",
        "llm_env_data.data[base + 9]",
        "llm_env_data.data[base + 8]",
        "llm_env_data.data[base + 32]",
        "llm_env_data.data[base + 6]",
        "llm_env_data.data[72 + i * 64]",
        "llm_env_data.data[40 + i * 64]",
        "template llmActivitySlot(idx: int): ptr LlmActivitySlotView",
        "template llmDeviceListEntry(idx: int): ptr LlmDeviceListEntryView",
        "let advParamPtrRaw",
        "deviceEntry.addr)",
        "deviceEntry.addr,",
        "deviceEntry.addr[",
    ]:
        assert forbidden not in llc_body
        assert forbidden not in llm_init_body
        assert forbidden not in llm_master_body
        assert forbidden not in llm_update_body
        assert forbidden not in disconnect_body
        assert forbidden not in llm_device_activity_body


def test_ble_trng_block_reader_uses_semantic_sample_indices():
    ble = blecontroller_policy_source()

    trng_body = ble.split("proc bleTrngReadBlock", 1)[1].split(
        "proc bleFillRandomBytesUnlocked", 1
    )[0]

    for expected in [
        "for trngDataWordIndex in 0 ..< 8:",
        "regRead(TrngData + uint(trngDataWordIndex * 4))",
        "for sampleByteIndex in 0 ..< 4:",
        "randomBlockBytes[trngDataWordIndex * 4 + sampleByteIndex]",
        "trngSampleWord shr (sampleByteIndex * 8)",
    ]:
        assert expected in trng_body

    for forbidden in [
        "for wordIndex in",
        "wordIndex * 4",
        "for byteIndex in",
        "byteIndex * 8",
    ]:
        assert forbidden not in trng_body


def test_ble_advertiser_connection_uses_typed_overlay():
    ble = blecontroller_policy_source()

    note_body = ble.split("proc noteNimAdvertiserConnected", 1)[1].split(
        "proc clearNimConnectionStateForDisconnect", 1
    )[0]
    conn_block = ble.split("LlmAdvertiserConnView {.packed.} = object", 1)[1].split(
        "NimLldAdvParamsView {.packed.} = object", 1
    )[0]

    for expected in [
        "LlmAdvertiserConnView {.packed.} = object",
        "advertiserConnPrefixPadding*: array[24, uint8]",
        "intervalMinSlots*: uint16",
        "intervalMaxSlots*: uint16",
        "intervalLatencyWord*: uint32",
        "supervisionMinSlots*: uint16",
        "supervisionMaxSlots*: uint16",
        "driftSlots*: uint16",
        "driftSlotsPadding*: array[2, uint8]",
        "peerAddr*: BdAddr",
        "peerAddrType*: uint8",
        "connected*: uint8",
        "connectionStatePadding*: array[24, uint8]",
        "state*: uint8",
        "doAssert offsetof(LlmAdvertiserConnView, advertiserConnPrefixPadding) == 0",
        "doAssert offsetof(LlmAdvertiserConnView, intervalMinSlots) == 24",
        "doAssert offsetof(LlmAdvertiserConnView, driftSlotsPadding) == 38",
        "doAssert offsetof(LlmAdvertiserConnView, peerAddr) == 40",
        "doAssert offsetof(LlmAdvertiserConnView, connectionStatePadding) == 48",
        "doAssert offsetof(LlmAdvertiserConnView, state) == 72",
        "template llmAdvertiserConn(): ptr LlmAdvertiserConnView",
    ]:
        assert expected in ble

    for expected in [
        "let conn = llmAdvertiserConn()",
        "conn.peerAddr.bytes[peerAddressByteIndex] =",
        "connectIndPayload[peerAddressByteIndex]",
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

    for forbidden in [
        "reserved0*: array[24, uint8]",
        "reserved38*: array[2, uint8]",
        "reserved48*: array[24, uint8]",
    ]:
        assert forbidden not in conn_block


def test_ble_access_words_use_typed_overlay():
    ble = blecontroller_policy_source()

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


def test_ble_legacy_adv_payload_copy_uses_semantic_payload_byte_name():
    ble = blecontroller_policy_source()

    body = ble.split("proc updateNimLegacyAdvPayload", 1)[1].split(
        "proc ble_hs_hci_cmd_send*", 1
    )[0]

    for expected in [
        "let advPayloadCopyLen = min(length.int, 31)",
        "let advPayloadBytes = cast[ptr UncheckedArray[uint8]](data)",
        "for payloadOffset in 0 ..< advPayloadCopyLen:",
        "let advertisingPayloadByte =",
        "advPayloadBytes[payloadOffset]",
        "read8(uint32(source) + payloadOffset.uint32)",
        "read8(BTBLE_EM_BASE + emOffset.uint32 + payloadOffset.uint32)",
        "nim_scan_rsp_data[payloadOffset] = advertisingPayloadByte",
        "nim_adv_data[payloadOffset] = advertisingPayloadByte",
    ]:
        assert expected in body

    for forbidden in [
        "let b =",
        "nim_scan_rsp_data[payloadOffset] = b",
        "nim_adv_data[payloadOffset] = b",
    ]:
        assert forbidden not in body


def test_ble_scheduler_program_slots_use_typed_overlay():
    ble = blecontroller_policy_source()

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

    end_isr_body = ble.split("proc sch_prog_end_isr*", 1)[1].split(
        "proc rwip_mac_done_set*", 1
    )[0]

    for expected in [
            "proc sch_prog_end_isr*(schedulerProgramIndex: uint8)",
            "let schedulerEndSlot = schedulerProgramIndex and 0x0F'u8",
            "btbleProgramSlotClear(schedulerProgramSlotIndex,",
            "btbleProgramSlotTarget(uint32(slot and 0x0F'u8))",
            "let slotControlWord = btbleProgramSlotControl(uint32(schedulerEndSlot))",
            "let slotEndStatusBits = (slotControlWord shr 3) and 0x0007'u16",
            "btbleProgramSlotSetDisabled(uint32(schedulerWifiCoexSlot))",
            "btbleProgramSlotSetDisabled(schedulerInitSlot)",
    ]:
        assert expected in ble
    for forbidden in [
        "proc sch_prog_end_isr*(idx: uint8)",
        "let schedulerEndSlot = idx and 0x0F'u8",
        "rawStatus",
        "let status =",
    ]:
        assert forbidden not in end_isr_body

    for expected in [
            "let schedulerWriteSlot = schProgWriteIdx and 0x0F'u8",
            "let schedulerWriteSlotU32 = uint32(schedulerWriteSlot)",
            "let req = cast[ptr SchProgRequestView](prog)",
            "let cbRaw = req.callback",
            "let target = req.targetTime",
            "let fine = req.fineTime",
            "let dur = req.duration",
            "let ctxRaw = req.context",
            "uint32(req.eventIndex) * 0x94'u32",
            "let tail = (btbleProgramSlotTail(schedulerWriteSlotU32) and 0xE0FF'u16) or",
            "btbleProgramSlotProgram(schedulerWriteSlotU32, target, fineBackoff, durHalf,",
    ]:
        assert expected in push_body

    for expected in [
            "btbleProgramSlotProgramRaw(advertisingSchedulerSlot, 0x281A'u16,",
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
    ble = blecontroller_policy_source()

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
    ble = blecontroller_policy_source()

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
    assert "kePendingEventBits = kePendingEventBits and not BleKeMessageEventBit" in clear_body
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
    ble = blecontroller_policy_source()
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
    ble = blecontroller_policy_source()

    format_body = ble.split("proc hciUtilCopyByFormat", 1)[1].split(
        "proc hci_util_pack*", 1
    )[0]

    assert "while formatBytes[formatOffset] != 0'u8:" in format_body
    assert "for fieldByteOffset in 0 ..< fieldSize:" in format_body
    assert "outputBytes[outputOffset + fieldByteOffset] =" in format_body
    assert "inputBytes[inputOffset + fieldByteOffset]" in format_body
    assert "while true:" not in format_body
    assert "if ch == 0:" not in format_body
    assert "for i in 0 ..< fieldSize:" not in format_body
    assert "outputBytes[outputOffset + i] = inputBytes[inputOffset + i]" not in format_body


def test_ble_rf_and_connection_convergence_loops_are_explicit():
    ble = blecontroller_policy_source()

    btble_rf_table = ble.split("BtbleRfTableView {.packed.} = object", 1)[1].split(
        "BleMacPhyRegs {.packed.} = object", 1
    )[0]
    btble_rf_init = ble.split("proc btble_rf_init*(rf: pointer) {.exportc, cdecl.} =", 1)[1].split(
        "when defined(bl808m0) and bl808BleNimConnectionEnabled:", 1
    )[0]
    ble_mac_phy_regs = ble.split("BleMacPhyRegs {.packed.} = object", 1)[1].split(
        "BlePhyCtrlRegs {.packed.} = object", 1
    )[0]
    ble_phy_ctrl_regs = ble.split("BlePhyCtrlRegs {.packed.} = object", 1)[1].split(
        "BlePhyAgcRegs {.packed.} = object", 1
    )[0]
    ble_phy_agc_regs = ble.split("BlePhyAgcRegs {.packed.} = object", 1)[1].split(
        "const\n    BtbleRfEmConfigFlags", 1
    )[0]
    nim_rf_reset_body = ble.split("proc nimRfReset() {.cdecl.} =", 1)[1].split(
        "proc nimRfForceAgcEnable", 1
    )[0]
    txcal_body = ble.split("proc tuneBleRfTxcalSingenPower", 1)[1].split(
        "proc writeBleRfTxcalMixerCs", 1
    )[0]
    schedule_body = ble.split("proc nimConnSchedule() =", 1)[1].split(
        "nimConnProgramRxTiming", 1
    )[0]

    for expected in [
        "unsupportedCallbackSlot08*: pointer",
        "unsupportedCallbackSlot0c*: pointer",
        "unsupportedCallbackSlot18*: pointer",
        "unsupportedCallbackSlot28*: pointer",
        "emConfigPadding3a*: array[3, uint8]",
        "doAssert offsetof(BtbleRfTableView, unsupportedCallbackSlot08) == 0x08",
        "doAssert offsetof(BtbleRfTableView, unsupportedCallbackSlot0c) == 0x0C",
        "doAssert offsetof(BtbleRfTableView, unsupportedCallbackSlot18) == 0x18",
        "doAssert offsetof(BtbleRfTableView, unsupportedCallbackSlot28) == 0x28",
        "doAssert offsetof(BtbleRfTableView, emConfigPadding3a) == 0x3A",
    ]:
        assert expected in ble
    for expected in [
        "rfResetTiming0*: uint32",
        "rfResetTiming1*: uint32",
        "rfResetTiming2*: uint32",
        "rfResetTiming3*: uint32",
        "rfResetGainWindow0*: uint32",
        "rfResetGainWindow1*: uint32",
        "rfResetGainWindow2*: uint32",
        "rfResetGainWindow3*: uint32",
        "rfPacketSettleTiming0*: uint32",
        "rfPacketSettleTiming3*: uint32",
        "analogTrimControl*: uint32",
        "doAssert offsetof(BleMacPhyRegs, rfResetTiming0) == 0x880",
        "doAssert offsetof(BleMacPhyRegs, rfResetGainWindow3) == 0x89C",
        "doAssert offsetof(BleMacPhyRegs, rfPacketSettleTiming0) == 0x980",
        "doAssert offsetof(BleMacPhyRegs, rfPacketSettleTiming3) == 0x98C",
        "doAssert offsetof(BleMacPhyRegs, analogTrimControl) == 0x9C0",
    ]:
        assert expected in ble
    for expected in [
        "rfResetInitControl*: uint32",
        "rfResetTuningControl*: uint32",
        "doAssert offsetof(BlePhyCtrlRegs, rfResetInitControl) == 0x08",
        "doAssert offsetof(BlePhyCtrlRegs, rfResetTuningControl) == 0x8C",
    ]:
        assert expected in ble
    for expected in [
        "resetAgcConfig*: uint32",
        "doAssert offsetof(BlePhyAgcRegs, resetAgcConfig) == 0x84",
    ]:
        assert expected in ble
    for expected in [
        "regStore(addr mac.rfResetTiming0, 0x00500350'u32)",
        "regStore(addr mac.rfResetGainWindow0, 0x04000703'u32)",
        "regUpdateField(addr mac.rfResetGainWindow2, 0xFF00FFFF'u32, 0x00870000'u32)",
        "regStore(addr mac.analogTrimControl,",
        "regStore(addr agc.resetAgcConfig, 0x1208102B'u32)",
        "regUpdateField(addr phy.rfResetTuningControl, 0xFF803FFF'u32,",
        "regStore(addr phy.rfResetInitControl, 0x0842001A'u32)",
        "regStore(addr mac.rfPacketSettleTiming0, 0x02120013'u32)",
    ]:
        assert expected in nim_rf_reset_body
    for expected in [
        "table.unsupportedCallbackSlot08 = nil",
        "table.unsupportedCallbackSlot0c = nil",
        "table.unsupportedCallbackSlot18 = nil",
        "table.unsupportedCallbackSlot28 = nil",
        "table.emConfigPadding3a = [0'u8, 0, 0]",
    ]:
        assert expected in btble_rf_init
    assert "unusedCallback" not in btble_rf_table
    for forbidden in [
        "reserved08*",
        "reserved0C*",
        "reserved18*",
        "reserved28*",
        "reserved3A*",
    ]:
        assert forbidden not in btble_rf_table
    for forbidden in [
        "reset880*",
        "reset884*",
        "reset888*",
        "reset88c*",
        "reset890*",
        "reset894*",
        "reset898*",
        "reset89c*",
        "settle980*",
        "settle984*",
        "settle988*",
        "settle98c*",
        "trim9c0*",
    ]:
        assert forbidden not in ble_mac_phy_regs
        assert forbidden.replace("*", "") not in nim_rf_reset_body
    for forbidden in [
        "resetInitCtrl08*",
        "resetTuningCtrl8c*",
    ]:
        assert forbidden not in ble_phy_ctrl_regs
        assert forbidden.replace("*", "") not in nim_rf_reset_body
    assert "resetAgcConfig84*" not in ble_phy_agc_regs
    assert "resetAgcConfig84" not in nim_rf_reset_body
    assert "var tuning = true" in txcal_body
    assert "while tuning:" in txcal_body
    assert "while true:" not in txcal_body
    assert "var scheduled = false" in schedule_body
    assert "while not scheduled:" in schedule_body
    assert "scheduled = true" in schedule_body
    assert "while true:" not in schedule_body


def test_ble_deferred_jobs_yield_under_backlog():
    ble = blecontroller_policy_source()

    djob_body = ble.split("proc coDjobRun", 1)[1].split(
        "proc coDjobRegister", 1
    )[0]

    assert "CoDjobDrainLimit = 8'u32" in ble
    assert "nim_ble_codjob_yield_count" in ble
    assert "nim_ble_codjob_yield_event" in ble
    assert "proc coDjobPending(deferredJobQueueIndex: int): bool" in ble
    assert "proc coDjobAnyPending(): bool" in ble
    assert "for queue in co_djob_queues:" in ble
    assert "var drained = 0'u32" in djob_body
    assert "while drained < CoDjobDrainLimit:" in djob_body
    assert "while true:" not in djob_body
    assert "inc drained" in djob_body
    assert "if coDjobPending(deferredJobQueueIndex):" in djob_body
    assert "inc nim_ble_codjob_yield_count" in djob_body
    assert "nim_ble_codjob_yield_event = eventId.uint32" in djob_body
    assert "ble_ke_event_set(coDjobEventId(deferredJobQueueIndex))" in djob_body


def test_ble_sleep_check_uses_controller_pending_work_state():
    ble = blecontroller_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    for forbidden in [
        "{.passL:",
        "{.compile:",
        "build/inspect",
        "bl_iot_sdk",
        "bl808WifiVendor",
    ]:
        assert forbidden not in wifi_fw


def test_wifi_firmware_does_not_link_sdk_ccmp_fallback():
    crypto_sources = (
        ROOT
        / "src/bl808/wifi/facade_parts/sdk_build_config_parts/crypto_sources.nim"
    ).read_text()

    for forbidden in [
        "aes-ccm.c",
        "aes-internal.c",
        "aes-internal-enc.c",
        "ccmp.c",
        "ccmp_decrypt",
    ]:
        assert forbidden not in crypto_sources

    rx_upper = (
        ROOT / "src/bl808/wifi/fw/rx_upper.nim"
    ).read_text()
    assert "nim_ccmp_decrypt(" in rx_upper
    assert "proc ccmp_decrypt" not in rx_upper
    assert " ccmp_decrypt(" not in rx_upper


def test_wifi_tpc_channel_power_offsets_use_semantic_locals():
    wifi_fw = wifi_fw_policy_source()

    full_update_body = wifi_fw.split(
        "proc bl_tpc_update_power_table*(powerTable: ptr array[38, int8])",
        1,
    )[1].split("proc bl_tpc_update_power_table_rate*", 1)[0]
    channel_update_body = wifi_fw.split(
        "proc bl_tpc_update_power_table_channel_offset*(powerTable: ptr array[38, int8])",
        1,
    )[1].split("proc bl_tpc_update_power_rate_11b*", 1)[0]
    table_get_body = wifi_fw.rsplit(
        "proc bl_tpc_power_table_get*(powerTable: ptr array[38, int8])",
        1,
    )[1].split("# ###########################################################################", 1)[0]

    for expected in [
        "for channelOffsetIndex in 0 ..< 14:",
        "let channelPowerOffset = powerTable[24 + channelOffsetIndex]",
        "tpcChannelOffsetTable[channelOffsetIndex] = channelPowerOffset",
        "tpcPowerTable[24 + channelOffsetIndex] = channelPowerOffset",
    ]:
        assert expected in full_update_body
        assert expected in channel_update_body

    assert "channelPowerOffset.int32 * 4'i32" in full_update_body
    assert "scaled[channelOffsetIndex] = cast[int8](channelPowerOffset.int32 * 4'i32)" in full_update_body
    assert "let scaledPhyOffset = channelPowerOffset.int32 * 4'i32" in channel_update_body
    assert "scaled[channelOffsetIndex] = cast[int8](scaledPhyOffset)" in channel_update_body
    assert 'printFn(cstring"pwr chan[%d] offset:%d\\r\\n", channelOffsetIndex.cint, scaledPhyOffset.cint)' in (
        channel_update_body
    )
    assert "for channelOffsetIndex in 0 ..< 14:" in table_get_body
    assert (
        "powerTable[24 + channelOffsetIndex] = tpcChannelOffsetTable[channelOffsetIndex]"
        in table_get_body
    )

    for forbidden in [
        "for i in 0 ..< 14:",
        "let channelPowerOffset = powerTable[24 + i]",
        "tpcChannelOffsetTable[i] = channelPowerOffset",
        "tpcPowerTable[24 + i] = channelPowerOffset",
        "scaled[i]",
        "i.cint, scaledPhyOffset.cint",
        "powerTable[24 + i] = tpcChannelOffsetTable[i]",
        "let offset = powerTable[24 + i]",
        "let phyOffset = offset.int32 * 4'i32",
        "tpcChannelOffsetTable[i] = offset",
    ]:
        assert forbidden not in full_update_body
        assert forbidden not in channel_update_body
        assert forbidden not in table_get_body


def test_wifi_rf_bringup_dependency_is_explicit_and_objdump_recoverable():
    wifi = nim_source_with_includes(ROOT / "src/bl808/wifi.nim")
    wifi_support = nim_source_with_includes(ROOT / "src/bl808/wifi/support.nim")
    wifi_fw = wifi_fw_policy_source()
    bl808_rf = ROOT / "src/bl808/librf_bl808.a"
    bl606p_rf = (
        ROOT
        / "build/bl_iot_sdk_b773b3f/components/platform/soc/bl606p"
        / "bl606p_phyrf/lib/libbl606p_phyrf.a"
    )
    assert "when defined(bl808WifiUseBl808Rf):" not in wifi
    assert "-Wl,--wrap=phy_assert_err" in wifi
    assert "elif defined(bl808WifiAllowLegacyBl606pRfFallback):" not in wifi
    assert "libbl606p_phyrf.a" not in wifi
    assert "bl606p_phyrf" not in wifi
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
    assert "when defined(bl808WifiUseBl808Rf):" not in fw_start
    assert "rf_init begin" not in fw_start

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
        "pdLoopToCeAccumulatorPadding0: uint8",
        "pdLoopToCeAccumulatorPadding1: uint8",
        "ceLoopTailPadding: uint8",
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
        "pdLoopReserved12",
        "pdLoopReserved13",
        "ceLoopReserved19",
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
        "WlLowPowerStatusEnv {.packed.} = object",
        "lastStatusCode: int8",
        "statusCodeToInactiveCountPadding: uint8",
        "inactiveUpdateCount: uint16",
        "lastUpdateContext: uint32",
        "statusValid: uint8",
        "validFlagTailPadding: array[2, uint8]",
        "doAssert sizeof(WlLowPowerStatusEnv) == 12",
        "doAssert offsetof(WlLowPowerStatusEnv, lastStatusCode) == 0",
        "doAssert offsetof(WlLowPowerStatusEnv, statusCodeToInactiveCountPadding) == 1",
        "doAssert offsetof(WlLowPowerStatusEnv, inactiveUpdateCount) == 2",
        "doAssert offsetof(WlLowPowerStatusEnv, lastUpdateContext) == 4",
        "doAssert offsetof(WlLowPowerStatusEnv, statusValid) == 9",
        "doAssert offsetof(WlLowPowerStatusEnv, validFlagTailPadding) == 10",
    ]:
        assert expected in wifi_fw
    for expected in [
        "PhyEnvView {.packed.} = object",
        "initCfgWords: array[9, uint32]",
        "channelBandType: uint16",
        "primaryFreq: uint16",
        "centerFreq1: uint16",
        "centerFreq2OrTxPower: uint16",
        "txPowerAndFlags: uint16",
        "txPowerFlagsTailPadding: array[2, uint8]",
        "RfcLpXtalConfig {.packed.} = object",
        "doAssert sizeof(RfcLpXtalConfig) == 16",
        "doAssert offsetof(RfcLpXtalConfig, xtalCountWindowMin) == 0",
        "doAssert offsetof(RfcLpXtalConfig, xtalCountWindowMax) == 4",
        "doAssert offsetof(RfcLpXtalConfig, xtalDividerConfig) == 8",
        "doAssert offsetof(RfcLpXtalConfig, xtalControlCode) == 12",
        'var rfcXtalCfg* {.align: 4, exportc: "rfc_xtal_cfg".}: array[6, RfcLpXtalConfig]',
        "doAssert sizeof(rfcXtalCfg) == 0x60",
        "xtalDividerConfig: 0x14400000'u32",
        "xtalControlCode: 0x0000097E'u32",
        "BbaRxVectorView {.packed.} = object",
        "rxFormatModeWord0: uint32",
        "rxFormatWord1Rate: uint8",
        "rssiDbm: uint8",
        "rxFormatWord1Mcs: uint8",
        "rxFormatWord1Flags: uint8",
        "rxFormatWord1ToCarrierOffsetPadding: array[14, uint8]",
        "carrierFreqOffset: uint16",
        "doAssert sizeof(PhyEnvView) == 48",
        "doAssert offsetof(PhyEnvView, initCfgWords) == 0",
        "doAssert offsetof(PhyEnvView, channelBandType) == 36",
        "doAssert offsetof(PhyEnvView, primaryFreq) == 38",
        "doAssert offsetof(PhyEnvView, centerFreq1) == 40",
        "doAssert offsetof(PhyEnvView, centerFreq2OrTxPower) == 42",
        "doAssert offsetof(PhyEnvView, txPowerAndFlags) == 44",
        "doAssert offsetof(PhyEnvView, txPowerFlagsTailPadding) == 46",
        "doAssert sizeof(BbaRxVectorView) == 24",
        "doAssert offsetof(BbaRxVectorView, rxFormatModeWord0) == 0",
        "doAssert offsetof(BbaRxVectorView, rxFormatWord1Rate) == 4",
        "doAssert offsetof(BbaRxVectorView, rssiDbm) == 5",
        "doAssert offsetof(BbaRxVectorView, rxFormatWord1ToCarrierOffsetPadding) == 8",
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
        "doAssert offsetof(WifiModemBlock, rxGainInitC040) == 0xC040",
        "doAssert offsetof(WifiModemBlock, rxGainTimingC044) == 0xC044",
        "doAssert offsetof(WifiModemBlock, rxGainTable0C080) == 0xC080",
        "doAssert offsetof(WifiModemBlock, rxGainTable1C084) == 0xC084",
        "doAssert offsetof(WifiModemBlock, rxGainTable2C088) == 0xC088",
        "doAssert offsetof(WifiModemBlock, lowPowerRxPathCtrlC814) == 0xC814",
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
        "doAssert offsetof(RfPllBlock, fractionalDividerWord28) == 0x28",
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
        "proc radioPhyModeFromApi*(apiMode: uint8): RadioPhyMode {.inline.} =",
        "proc apiFromRadioPhyMode*(mode: RadioPhyMode): uint8 {.inline.} =",
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
    )[1].split("proc rfc_init*", 1)[0]
    rfc_init_body = wifi_fw.split(
        "proc rfc_init*(xtalfreqHz: uint32, fullInit: uint32 = 1'u32) {.exportc, cdecl.} =",
        1,
    )[1].split("template rf_calib_data", 1)[0]
    rf_cal_debug_snapshot_body = wifi_fw.split(
        "proc snapshotWifiRfCalibData() =", 1
    )[1].split("proc mpif_clk_init*", 1)[0]
    vco_table_body = wifi_fw.split(
        "proc programRfcVcoTable() =",
        1,
    )[1].split("proc rf_dump_status*", 1)[0]
    rfc_bandwidth_body = wifi_fw.split(
        "proc rfc_config_bandwidth*(bandwidth: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfc_config_channel*", 1)[0]
    rfc_get_power_level_body = wifi_fw.split(
        "proc rfc_get_power_level*(rateClass: uint32; requestedPowerTenths: int32): uint32",
        1,
    )[1].split("proc rfc_apply_tx_dvga_offset", 1)[0]
    rfc_power_meas_body = wifi_fw.split(
        "iOut, qOut: ptr int32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfc_sg_start*", 1)[0]
    rfc_sg_start_body = wifi_fw.split(
        "signedQuadraturePath: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfc_sg_stop*", 1)[0]
    rfc_sg_stop_body = wifi_fw.split(
        "proc rfc_sg_stop*() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfc_rf_fsm_force*", 1)[0]
    rfc_rf_fsm_force_body = wifi_fw.split(
        "proc rfc_rf_fsm_force*(mode: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfc_rc_fsm_force*", 1)[0]
    rfc_rc_fsm_force_body = wifi_fw.split(
        "proc rfc_rc_fsm_force*(mode: uint32) {.exportc, cdecl.} =",
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
        "proc replayRfPriCalRegisters() =",
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
    vendor_save_cal_state_body = wifi_fw.split(
        "proc rf_pri_save_state_before_cal() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_restore_state_after_cal", 1)[0]
    vendor_restore_cal_state_body = wifi_fw.split(
        "proc rf_pri_restore_state_after_cal() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_cw_stop", 1)[0]
    rf_pri_cw_stop_body = wifi_fw.split(
        "proc rf_pri_cw_stop() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfPriConfigChannelForCal", 1)[0]
    total_power_comp_body = wifi_fw.split(
        "proc rfPriWriteTotalPowerComp(channelIndex: uint32) =",
        1,
    )[1].split("proc rf_pri_input_xtalfreq", 1)[0]
    lp_power_comp_body = wifi_fw.split(
        "proc rf_pri_set_channel_lp_pwr_comp(channelIndex: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_input_channel_lp_pwr_comp", 1)[0]
    input_channel_power_comp_body = wifi_fw.split(
        "proc rf_pri_input_channel_pwr_comp(comp: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_input_channel_lp_pwr_comp", 1)[0]
    input_lp_channel_power_comp_body = wifi_fw.split(
        "proc rf_pri_input_channel_lp_pwr_comp(comp: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_set_channel_lp_pwr_comp", 1)[0]
    input_temp_comp_body = wifi_fw.rsplit(
        "proc rf_pri_input_temp_comp_param(channels: pointer; highOffsets: pointer;",
        1,
    )[1].split("proc rf_pri_set_temp_comp", 1)[0]
    input_bz_channel_power_comp_body = wifi_fw.split(
        "proc rf_pri_input_bz_channel_pwr_comp(comp: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfPriRefreshBzChannelPowerComp", 1)[0]
    refresh_bz_channel_power_comp_body = wifi_fw.split(
        "proc rfPriRefreshBzChannelPowerComp(cfg: ptr WlRfConfig) =",
        1,
    )[1].split("proc rfPriClampBzChannelComp", 1)[0]
    pack_five_fields_body = wifi_fw.split(
        "proc rfPriPackFive6BitFields(values: array[5, int16]): uint32 =",
        1,
    )[1].split("proc rf_pri_set_bz_channel_pwr_comp", 1)[0]
    set_bz_channel_power_comp_body = wifi_fw.split(
        "proc rf_pri_set_bz_channel_pwr_comp() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfPriUpdateBzTempCorrAverage", 1)[0]
    write_bz_temp_comp_deltas_body = wifi_fw.split(
        "proc rfPriWriteBzTemperatureCompDeltas() =",
        1,
    )[1].split("proc rf_pri_set_bz_temp_comp", 1)[0]
    set_bz_temp_comp_body = wifi_fw.split(
        "proc rf_pri_set_bz_temp_comp(sensorTemperatureC: int32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_get_bz_temp_mp_comp", 1)[0]
    set_channel_power_comp_body = wifi_fw.split(
        "proc rf_pri_set_channel_pwr_comp(channelIndex: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_set_bandwidth", 1)[0]
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
    )[1].split("proc rf_pri_xtalfreq", 1)[0]
    rf_pri_xtalfreq_body = wifi_fw.split(
        "proc rf_pri_xtalfreq() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfPriEfuseXtalCapPairValid", 1)[0]
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
    wl_tcal_body = wifi_fw.split(
        "proc wl_rf_tcal_handler*(temperatureC: int32): int32 {.exportc, cdecl.} =",
        1,
    )[1].split("proc wl_rf_tcal_period_get", 1)[0]
    wl_lp_status_clear_body = wifi_fw.split(
        "proc wl_lp_status_clear*(context: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc wl_lp_status_update", 1)[0]
    wl_lp_init_body = wifi_fw.split(
        "proc wl_lp_init*(rmem: ptr WlRfMemoryOverlay; phyCfg: pointer): int32",
        1,
    )[1].split("proc wl_lp_status_clear", 1)[0]
    wl_lp_early_phy_body = wifi_fw.split(
        "proc wlLpProgramEarlyPhyRegs(xtalIndex: uint32) =",
        1,
    )[1].split("proc wl_lp_init", 1)[0]
    wl_lp_api_mode_branch_body = wifi_fw.split(
        "proc wlLpProgramApiModePhyBranchStart() =",
        1,
    )[1].split("proc wlLpProgramApiModeTuneAndAgcPrep", 1)[0]
    wl_lp_api_mode_active_body = wifi_fw.split(
        "proc wlLpApiModeActive(): bool {.inline.} =",
        1,
    )[1].split("proc wlLpProgramApiModePhyBranchStart", 1)[0]
    wl_lp_tune_agc_prep_body = wifi_fw.split(
        "proc wlLpProgramApiModeTuneAndAgcPrep(phyCfg: pointer) =",
        1,
    )[1].split("proc wlLpCopyAgcMemoryAndReleaseGate", 1)[0]
    wl_lp_agc_copy_body = wifi_fw.split(
        "proc wlLpCopyAgcMemoryAndReleaseGate() =",
        1,
    )[1].split("proc wlLpProgramAgcCoreRegs", 1)[0]
    wl_lp_agc_core_body = wifi_fw.split(
        "proc wlLpProgramAgcCoreRegs() =",
        1,
    )[1].split("proc wlLpProgramPostAgcPowerDetectTail", 1)[0]
    wl_lp_post_agc_tail_body = wifi_fw.split(
        "proc wlLpProgramPostAgcPowerDetectTail() =",
        1,
    )[1].split("proc wl_lp_init", 1)[0]
    wl_lp_status_update_body = wifi_fw.split(
        "proc wl_lp_status_update*(active: uint32; statusCode: int8;",
        1,
    )[1].split("proc rf_pri_init_calib_mem", 1)[0]
    rf_pri_cfg_init_body = wifi_fw.split(
        "proc rf_pri_cfg_init() {.exportc, cdecl.} =",
        1,
    )[1].split("proc wl_rf_cfg_init", 1)[0]
    rf_pri_get_xtalfreq_body = wifi_fw.split(
        "proc rf_pri_get_xtalfreq(): uint32 {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfPriXtalRefdivRatio", 1)[0]
    rf_pri_init_calib_mem_body = wifi_fw.split(
        "proc rf_pri_init_calib_mem() {.exportc, cdecl.} =",
        1,
    )[1].split("type\n    RfPriCalState", 1)[0]
    modem_init_mode_body = wifi_fw.split(
        "proc modemInitCoreMode(xtalfreqHz, restoreExistingCalibration: uint32;",
        1,
    )[1].split("proc modem_init_core*", 1)[0]
    assert "proc configureWlRfConfig(cfg: ptr WlRfConfig; xtalfreqHz: uint32;" in wifi_fw
    assert "mode: RadioPhyMode; requestFullCalibration: uint8" in wifi_fw
    assert "cfg.paramLoadCallback = nil" in wifi_fw
    for expected in [
        "proc wl_wlan_power_table_update*() {.exportc, cdecl.} =",
        "proc wl_rf_tcal_handler*(temperatureC: int32): int32 {.exportc, cdecl.} =",
        "proc wl_rf_tcal_period_get*(): int32 {.exportc, cdecl.} =",
        "proc wl_bz_rx_optimize*(channelMhz: uint32) {.exportc, cdecl.} =",
        "proc wl_bz_rx_optimize_restore*() {.exportc, cdecl.} =",
        "proc wl_rf_set_bz_target_power_table*(targetPowerDbm: int32)",
        "proc wl_rf_set_channel_pwr_comp*(channelIndex: uint32) {.exportc, cdecl.} =",
        "proc wl_wlan_bb_reset*() {.exportc, cdecl.} =",
        "proc wl_wlan_bb_pre_proc*(rxVector: pointer) {.exportc, cdecl.} =",
        "proc wl_wlan_bb_post_proc*(rxVector: pointer; frameType: uint32)",
        "proc wl_wlan_rssi_get*(rxVector: pointer): int8 {.exportc, cdecl.} =",
        "proc wl_wlan_ppm_get*(rxVector: pointer): int8 {.exportc, cdecl.} =",
        "proc wl_wlan_power_cfg_get*(rateClass, rateIndex: uint32): int8",
        "proc wl_154_power_cfg_get*(): int8 {.exportc, cdecl.} =",
        "proc wl_bt_power_cfg_get*(index: uint32): int8 {.exportc, cdecl.} =",
        "proc wl_ble_power_cfg_get*(): int8 {.exportc, cdecl.} =",
        "proc wl_lp_init*(rmem: ptr WlRfMemoryOverlay; phyCfg: pointer): int32",
        "proc wl_lp_status_update*(active: uint32; statusCode: int8;",
    ]:
        assert expected in wifi_fw
    assert "rf_pri_set_temp_comp(temperatureC)" in wl_tcal_body
    assert "rf_pri_set_bz_temp_comp(temperatureC)" in wl_tcal_body
    assert "1'i32" in wl_tcal_body
    assert "bba_reset()" in wifi_fw
    assert "bba_rssi_correction(rxVector)" in wifi_fw
    assert "bba_loop(rxVector, frameType)" in wifi_fw
    assert "calc_ppm(rxVector)" in wifi_fw
    for expected in [
        "wl_lp_init+0x0..0xa6",
        "wlCfgGlobal = cast[pointer](addr rmem.config)",
        "wlCalGlobal = cast[pointer](addr rmem.calib[0])",
        "wlEnvGlobal = cast[pointer](addr rmem.env[0])",
        "rfCalibDataGlobal = wlCalGlobal",
        "wlLpDefaultInit()",
        "rf_pri_input_xtalfreq(cfg.xtalfreqHz)",
        "rf_pri_init(0'u32, uint32(cfg.apiMode))",
        "let lpXtalIndex = wlLpXtalIndex(cfg.xtalfreqHz)",
        "wlLpProgramEarlyPhyRegs(lpXtalIndex)",
        "wlLpProgramApiModePhyBranchStart()",
        "wlLpProgramApiModeTuneAndAgcPrep(phyCfg)",
        "wlLpCopyAgcMemoryAndReleaseGate()",
        "wlLpProgramAgcCoreRegs()",
        "wlLpProgramPostAgcPowerDetectTail()",
        "phy_init(phyCfg)",
        "recovered lp_phy_init register phases",
        "hardware validation proves whether the fallback can be removed",
    ]:
        assert expected in wl_lp_init_body
    assert "Remaining unknown:" not in wl_lp_init_body
    assert "lp_default_init+0x0..0xb4" in wifi_fw
    for expected in [
        "lp_phy_init+0x0..0x16a",
        "let xtalConfigTableIndex =",
        "let xtalCfg = rfcXtalCfg[xtalConfigTableIndex]",
        "addr rf.xtalControlCode1c0",
        "xtalCfg.xtalControlCode and 0x00000FFF'u32",
        "addr rf.xtalDividerConfig1c4",
        "xtalCfg.xtalDividerConfig and 0x1FFFFFFF'u32",
        "addr rf.xtalCountWindowMin1c8",
        "addr rf.xtalCountWindowMax1cc",
        "let calWords = cast[ptr UncheckedArray[uint32]](wlCalGlobal)",
        "for vcoPairTableWordIndex in 0 ..< rf.vcoPairTable13c.len:",
        "volatileStore(addr rf.vcoPairTable13c[vcoPairTableWordIndex],",
        "calWords[vcoPairTableWordIndex + 7])",
        "volatileStore(addr rf.vcoPair2484Mhz164, calWords[17])",
        "addr rf.channelTuneStrobe268",
        "0x00001040'u32",
        "addr rf.channelTuneCtrl26c",
        "addr rf.scanSynthControl608",
        "0x20000000'u32",
    ]:
        assert expected in wl_lp_early_phy_body
    assert "let xtalCfg = rfcXtalCfg[idx]" not in wl_lp_early_phy_body
    for expected in [
        "lp_phy_init+0x184..0x236",
        "addr mdm.lowPowerRxPathCtrlC814",
        "not 0x00000003'u32",
        "not 0x0000003C'u32",
        "not 0x000003C0'u32",
        "addr mdm.rxGainInitC040",
        "0x00C00000'u32",
        "0x00018000'u32",
        "addr mdm.rxGainTimingC044",
        "0x00000800'u32",
        "rc2_config_rxgain(-5'i8)",
        "addr rf.channelTuneCtrl26c",
        "0x05000000'u32",
        "addr crm.modemReset18",
        "0x00000050'u32",
        "crm_init()",
        "crm_mdm_reset()",
    ]:
        assert expected in wl_lp_api_mode_branch_body
    assert "(cfg.apiMode and 0xFD'u8) == 1'u8" in wl_lp_api_mode_active_body
    for expected in [
        "lp_phy_init+0x236..0x35c",
        "addr mdm.preAgcCtrl324",
        "0x002D0000'u32",
        "addr crm.rfClockMux10",
        "0x08000000'u32",
        "volatileStore(addr bba.macActiveC01c, 0x000000A0'u32)",
        "addr bba.agcCoreTableC80c",
        "0xA8000000'u32",
        "addr rf.channelTuneGate228",
        "0x00000008'u32",
        "addr rf.synthCtrl2c",
        "0x00000040'u32",
        "0x00000200'u32",
        "0x00000001'u32",
        "addr rf.channelFreqMhz264",
        "pointerAddrU32(phyCfg) and 0x00000FFF'u32",
        "addr rf.channelTuneStrobe268",
        "0x00020000'u32",
        "waitRfUs(1'u32)",
        "addr rf.channelTuneCtrl26c",
        "0x00000002'u32",
        "addr bba.pdGain390",
        "0x00001000'u32",
        "0x20000000'u32",
    ]:
        assert expected in wl_lp_tune_agc_prep_body
    for expected in [
        "lp_phy_init+0x364..0x3a6",
        "copyAgcMemory()",
        "addr crm.rfClockMux10",
        "0xDFFFFFFF'u32",
        "addr bba.pdGain390",
        "0xFFFFEFFF'u32",
    ]:
        assert expected in wl_lp_agc_copy_body
    for expected in [
        "lp_phy_init+0x3a6..0x774",
        "register-identical to the typed main-PHY AGC core phase",
        "wlLpApiModeActive()",
        "bl808PhyProgramAgcCoreRegs()",
    ]:
        assert expected in wl_lp_agc_core_body
    for expected in [
        "agcCoreLowPowerThreshold304: uint32",
        "lowPowerPdThresholdC044: uint32",
        "lowPowerPdCompC834: uint32",
        "lowPowerPdCompC864: uint32",
        "lowPowerModemPathCtrl508: uint32",
        "lowPowerRfClockGate14: uint32",
        "lowPowerActiveLatch: uint8",
        "doAssert offsetof(BbaAgcBlock, agcCoreLowPowerThreshold304) == 0x304",
        "doAssert offsetof(BbaAgcBlock, lowPowerPdThresholdC044) == 0x1044",
        "doAssert offsetof(BbaAgcBlock, lowPowerPdCompC834) == 0x1834",
        "doAssert offsetof(BbaAgcBlock, lowPowerPdCompC864) == 0x1864",
        "doAssert offsetof(RfRegBlock, lowPowerModemPathCtrl508) == 0x508",
        "doAssert offsetof(CrmPhyClockBlock, lowPowerRfClockGate14) == 0x14",
        "doAssert offsetof(WlLowPowerStatusEnv, lowPowerActiveLatch) == 8",
    ]:
        assert expected in wifi_fw
    for expected in [
        "lp_phy_init+0x774..0x86c",
        "wlLpApiModeActive()",
        "addr bba.lowPowerPdCompC864",
        "0x0000C078'u32",
        "addr bba.pdGain390",
        "0xFFFFFF0F'u32",
        "addr bba.lowPowerPdCompC834",
        "0xFFFFFFFC'u32",
        "addr bba.agcCoreLowPowerThreshold304",
        "0xFFFF80FF'u32",
        "0x00004B00'u32",
        "crm_clk_set(0'u32)",
        "0xFFFFFEFF'u32",
        "0x00000200'u32",
        "addr bba.macActiveB3a0",
        "0x000000A8'u32",
        "addr bba.pdSlope3c0",
        "0x0000AB00'u32",
        "0x000000AB'u32",
        "addr bba.lowPowerPdThresholdC044",
        "0x00000600'u32",
        "addr bba.pdComp36c",
        "0x00000500'u32",
        "0x00000014'u32",
        "addr bba.pdCompC830",
        "0xFC0FFFFF'u32",
        "addr env.lowPowerActiveLatch",
        "addr rf.channelTuneCtrl26c",
        "waitRfUs(1'u32)",
        "addr rf.channelTuneGate228",
        "0xFFFFFFF7'u32",
    ]:
        assert expected in wl_lp_post_agc_tail_body
    for expected in [
        "volatileStore(addr rf.modemPathEnable504, 0x002C0000'u32)",
        "volatileStore(addr rf.lowPowerModemPathCtrl508, 0x003C0002'u32)",
        "volatileStore(addr rf.pdCompLatchCtrl50c, 0x003FFC02'u32)",
        "volatileStore(pdsSleepRetainMaskReg(), 0xFFFFFF00'u32)",
        "volatileStore(addr crm.rfClockMux10, 0'u32)",
        "volatileStore(addr crm.lowPowerRfClockGate14, 0'u32)",
        "cfg.apiMode != 1'u8",
        "addr rf.rfcSequencerBias400",
        "addr aux.rfcAuxPathSelect540",
        "addr aux.rfcAuxPathGate544",
    ]:
        assert expected in wifi_fw
    for forbidden in [
        "volatileStore(addr rf.reserved508, 0x003C0002'u32)",
        "volatileStore(addr crm.reserved014, 0'u32)",
    ]:
        assert forbidden not in wifi_fw
    for expected in [
        "wl_lp_status_clear+0x0..0x1a",
        "let env = wlLowPowerStatusEnv()",
        "env.inactiveUpdateCount = 0'u16",
        "env.lastStatusCode = cast[int8](0xA6'u8)",
        "env.lastUpdateContext = context",
        "env.statusValid = 0'u8",
    ]:
        assert expected in wl_lp_status_clear_body
    for forbidden in [
        "cast[ptr UncheckedArray[uint8]](wlEnvGlobal)[",
        "cast[ptr uint16](cast[uint](wlEnvGlobal)",
        "cast[ptr uint32](cast[uint](wlEnvGlobal)",
    ]:
        assert forbidden not in wl_lp_status_clear_body
    for expected in [
        "wl_lp_status_update+0x0..0x60",
        "let env = wlLowPowerStatusEnv()",
        "active == 0'u32",
        "env.inactiveUpdateCount >= 1'u16",
        "env.inactiveUpdateCount = 0'u16",
        "env.statusValid = 0'u8",
        "env.lastStatusCode = statusCode",
        "env.statusValid = 1'u8",
        "env.lastUpdateContext = context",
    ]:
        assert expected in wl_lp_status_update_body
    for forbidden in [
        "cast[ptr UncheckedArray[uint8]](wlEnvGlobal)[",
        "cast[ptr uint16](cast[uint](wlEnvGlobal)",
        "cast[ptr uint32](cast[uint](wlEnvGlobal)",
    ]:
        assert forbidden not in wl_lp_status_update_body
    wl_power_cfg_body = wifi_fw.split(
        "proc wl_wlan_power_cfg_get*(rateClass, rateIndex: uint32): int8",
        1,
    )[1].split("proc wl_rf_tcal_handler", 1)[0]
    trpc_default_power_body = wifi_fw.split(
        "proc trpc_get_default_power_idx(rateType: uint32, rateIdx: uint8): int8",
        1,
    )[1].split("proc trpc_get_power_idx", 1)[0]
    for expected in [
        "of 0'u32, 1'u32:",
        "adjusted = (rateIndex - 4'u32) and 0xFF'u32",
        "trpc_get_default_power_idx(group, adjusted.uint8)",
        "of 2'u32, 3'u32:",
        "trpc_get_default_power_idx(2'u32, rateIndex.uint8)",
        "of 4'u32:",
        "trpc_get_default_power_idx(3'u32, rateIndex.uint8)",
        "of 5'u32, 6'u32, 7'u32:",
        "trpc_get_default_power_idx(4'u32, rateIndex.uint8)",
        "wlInvalidPowerCfgIndex()",
    ]:
        assert expected in wl_power_cfg_body
    for expected in [
        "for cfgByteOffset in 0 ..< count:",
        "bytes[offset + cfgByteOffset] = value",
        "let txPowerVsRateTableIndex = int(rateType) * 10 + int(rateIdx)",
        "txPowerVsRateTableIndex >= trpcTxpwrVsRateTable.len",
        "trpcTxpwrVsRateTable[txPowerVsRateTableIndex]",
    ]:
        assert expected in wifi_fw if "cfgByteOffset" in expected else expected in trpc_default_power_body
    assert "for idx in 0 ..< count:" not in wifi_fw
    assert "bytes[offset + idx] = value" not in wifi_fw
    assert "let idx = int(rateType) * 10 + int(rateIdx)" not in trpc_default_power_body
    assert "trpcTxpwrVsRateTable[idx]" not in trpc_default_power_body
    assert "cfg.ratePowerTablePostamble[3]" in wifi_fw
    assert "cfg.ratePowerLimitDbm" in wifi_fw
    assert 'var trpcEnv* {.align: 4, exportc: "trpc_env".}: array[2, uint32]' in wifi_fw
    for expected in [
        "proc crm_get_cpu_freq*(): uint32 {.exportc, cdecl.} =",
        "50_000_000'u32",
        "proc rf_set_channel*(unusedBand: uint32, channelMhz: uint32)",
        "rfc_config_channel(channelMhz)",
        "proc rfc_wlan_mode_force*(mode: uint32) {.exportc, cdecl.} =",
        "mode <= 4'u32",
        "proc rfc_dump*() {.exportc, cdecl.} =",
        "rxModeDumpReadback224: uint32",
        "doAssert offsetof(RfRegBlock, rxModeDumpReadback224) == 0x224",
        "volatileLoad(addr rf.rxModeDumpReadback224)",
        "proc rfc_get_power_level*(rateClass: uint32; requestedPowerTenths: int32): uint32",
        "proc rfc_power_meas*(clockSelect: uint32; offsetHz: int32;",
    ]:
        assert expected in wifi_fw
    for expected in [
        "librf_bl808.a:rfc_helper.c.o rfc_config_power is ret-only",
        "librf_bl808.a:rfc_helper.c.o rfc_apply_tx_dvga_offset is ret-only",
        "librf_bl808.a:rfc_helper.c.o rfc_apply_tx_dvga is ret-only",
        "librf_bl808.a:rfc_helper.c.o rfc_apply_tx_power_offset is ret-only",
    ]:
        assert expected in wifi_fw
    for stale_provenance in [
        "librf_bl808.a:rfc.c.o rfc_config_power is ret-only",
        "librf_bl808.a:rfc.c.o rfc_apply_tx_dvga_offset is ret-only",
        "librf_bl808.a:rfc.c.o rfc_apply_tx_dvga is ret-only",
        "librf_bl808.a:rfc.c.o rfc_apply_tx_power_offset is ret-only",
    ]:
        assert stale_provenance not in wifi_fw
    for expected in [
        "rfc_get_power_level+0x0..0x4a",
        "if rateClass == 0'u32:",
        "elif rateClass == 1'u32:",
        "rfPriGetTxGainIndex(requestedPowerTenths, group) shl 2",
    ]:
        assert expected in rfc_get_power_level_body
    for expected in [
        "RfPriTxPowerRowTxGainTenthsIndex = 6",
        "RfPriTxPowerRowPowerThresholdTenthsIndex = 8",
        "proc rfPriGetTxGainIndex(requestedPowerTenths: int32;",
        "rf_pri_get_txgain_index(power, group)",
        "recovered BL602 implementation",
        "adjustedPower -= 30'i32",
        "let txPowerTableRowIndex = int(tableIndex)",
        "bl808RfTxPowerTable[txPowerTableRowIndex][RfPriTxPowerRowTxGainTenthsIndex]",
        "for txPowerTableRowIndex in 0 ..< rowCount:",
        "bl808RfTxPowerTable[txPowerTableRowIndex][RfPriTxPowerRowPowerThresholdTenthsIndex]",
        "bl808RfTxGainComp.int32",
        "return txPowerTableRowIndex.uint32",
        "15'u32",
    ]:
        assert expected in wifi_fw
    assert "let idx = int(tableIndex)" not in wifi_fw
    assert "for idx in 0 ..< rowCount:" not in wifi_fw
    for body, expected in [
        (rfc_power_meas_body, [
            "rfc_power_meas+0x0..0x1b2",
            "rfcPowerMeasureFrequencyWord(clockSelect, offsetHz)",
            "addr rf.measureCtrl618",
            "addr rf.measureMode61c",
            "addr rf.measureI620",
            "addr rf.measureQ624",
            "RfMeasureReadyMask",
            "signedRfAverageMeasurement",
            "if iOut != nil:",
            "if qOut != nil:",
        ]),
        (rfc_sg_start_body, [
            "rfc_sg_start+0x0..0x146",
            "let rf = rfRegs()",
            "let magnitudeHz",
            "let frequencyControl",
            "uint64(magnitudeHz) * 1024'u64",
            "80_000_000'u64",
            "let amplitudeCode",
            "if amplitude > 1023'u32: 1023'u32 else: amplitude",
            "let highPathPhase",
            "0x40000000'u32",
            "0xC0000000'u32",
            "addr rf.calSingenCtrl20c",
            "addr rf.calSingenMeasurePrep21c",
            "addr rf.calSingenAmpLo214",
            "addr rf.calSingenAmpHi218",
            "signedQuadraturePath != 0'u32",
        ]),
        (rfc_sg_stop_body, [
            "rfc_sg_stop+0x0..0x16",
            "addr rfRegs().calSingenCtrl20c",
            "not 0x80000000'u32",
        ]),
        (rfc_rf_fsm_force_body, [
            "rfc_rf_fsm_force+0x0..0x6a",
            "addr rf.channelTuneCtrl26c",
            "mode == 15'u32",
            "mode and 0x7'u32",
            "waitRfUs(20)",
            "0x8'u32",
        ]),
        (rfc_rc_fsm_force_body, [
            "rfc_rc_fsm_force+0x0..0xb0",
            "addr rf.baseCtrl1",
            "mode == 15'u32",
            "(mode shl 8) and 0x700'u32",
            "waitRfUs(20)",
            "0x800'u32",
        ]),
    ]:
        for item in expected:
            assert item in body
        for forbidden in [
            "regWrite(0x200010",
            "rfRegWrite(",
            "cast[ptr uint32](0x200010",
            "cast[ptr uint32](0x2000120C'u)",
            "cast[ptr uint32](0x20001210'u)",
            "cast[ptr uint32](0x20001214'u)",
            "cast[ptr uint32](0x20001218'u)",
            "cast[ptr uint32](0x2000121C'u)",
            "cast[ptr uint32](0x20001618'u)",
            "cast[ptr uint32](0x2000161C'u)",
            "cast[ptr uint32](0x20001620'u)",
            "cast[ptr uint32](0x20001624'u)",
        ]:
            assert forbidden not in body
    for expected in [
        "rf_pri_cfg_init+0x0..0x7a",
        "cfg.channelFreqSeedPair0 = 0x096C0100'u32",
        "cfg.channelFreqSeedPair1 = 0x098A097B'u32",
        "cfg.channelFreqSeedPair2 = 0x09A80999'u32",
        "cfg.channelFreqSeedPadding.mitems",
        "cfg.ratePowerTablePreamble = 0'u16",
        "cfg.ratePowerLimitDbm = 20'u8",
        "cfg.efuseTrimControl = 0x02000000'u32",
        "cfg.efuseTxGainComp = 0x01'u8",
        "cfg.efuseXtalCapCode0 = 0x80'u8",
        "cfg.efuseXtalCapCode1 = 0x80'u8",
        "cfg.efuseDfeTrim = 0x80'u8",
        "cfg.temperaturePowerComp = 35'u8",
        "cfg.temperaturePowerCompPadding = 0'u16",
        "cfg.channelPowerComp.mitems",
        "cfg.channelLowPowerComp.mitems",
    ]:
        assert expected in rf_pri_cfg_init_body
    for expected in [
        "rf_pri_get_xtalfreq",
        "WlXtal24M",
        "WlXtal26M",
        "WlXtal32M",
        "WlXtal38P4M",
        "WlXtal40M",
        "WlXtal52M",
        "0'u32",
    ]:
        assert expected in rf_pri_get_xtalfreq_body
    for expected in [
        "rf_calib_data.c.o rf_pri_init_calib_mem",
        "rfCalibDataGlobal = wlCalGlobal",
    ]:
        assert expected in rf_pri_init_calib_mem_body
    assert "seedWlCfgTxPowerDefaults()" in wl_cfg_init_body
    assert "rf_pri_cfg_init()" in wl_cfg_init_body
    assert "wlCfgSetU32(WlRfCfgRxcalA8Offset, WlRfCfgWb03RxcalA8Default)" in wl_cfg_init_body
    assert "wlCfgSetU32(WlRfCfgRxcalA8Offset" not in rf_pri_cfg_init_body
    assert "var wifiBl808RfInited: uint32" in wifi_fw
    assert "bl808WifiRfColdInit" not in wifi_fw
    assert (
        "let requestFullCalibration =\n"
        "      if wifiBl808RfInited == 0'u32: 1'u8 else: 0'u8"
    ) in rf_core_init
    assert (
        "let restoreExistingCalibration =\n"
        "    if wifiBl808RfInited == 0'u32: 0'u32 else: 1'u32"
    ) in rf_core_init
    assert "let restoreExistingCalibration = 1'u32" not in wifi_fw
    assert "let requestFullCalibration = 0'u8" not in wifi_fw
    assert "let restore = if wifiBl808RfInited" not in wifi_fw
    assert "let restore = 1'u32" not in wifi_fw
    assert "discard wl_init()" in wifi_fw
    assert "wifiBl808RfInited = 1'u32" in wifi_fw
    assert "bl808WifiUseBl808Rf" not in wifi_fw
    assert "bl808WifiAllowLegacyBl606pRfFallback" not in wifi_fw
    assert "libbl606p_phyrf.a" not in wifi_fw
    assert "bl606p_phyrf" not in wifi_fw
    assert "proc phy_set_channel*(channel: ptr ChanCtxtDefView, force: uint32)" in wifi_fw
    assert "proc phy_set_channel_scalar*(band, chanType, primFreq, centerFreq1: uint32)" not in wifi_fw
    assert '{.importc: "phy_set_channel", cdecl.}' not in wifi_fw
    assert "proc phySetChannel*(channel: ptr ChanCtxtDefView) {.inline.} =" in wifi_fw
    assert "phy_set_channel(channel, 0'u32)" in wifi_fw
    assert "phy_set_channel_scalar(" not in wifi_fw
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
        "modemInitCoreMode(\n    cfg.xtalfreqHz,\n    restoreExistingCalibration,"
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
        "let txPowerCompTable = rfTxPowerCompTableRegs()",
        "for txPowerCompWordIndex, txPowerCompWordValue in words:",
        "addr txPowerCompTable.txPowerCompWords700[txPowerCompWordIndex]",
        "txPowerCompWordValue",
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
    assert "RfPriVendorCalState = object" in wifi_fw
    for expected in [
        "bl808RfPriVendorCalState: RfPriVendorCalState",
        "calPathCtrl90: uint32",
        "rf_pri_save_state_before_cal+0x0..0x13a",
        "let rf = rfRegs()",
        "let dfe = rfDfeInitRegs()",
        "bl808RfPriVendorCalState.synthCtrl2c = volatileLoad(addr rf.synthCtrl2c)",
        "bl808RfPriVendorCalState.hbnCtrl30 = volatileLoad(addr dfe.hbnCtrl30)",
        "bl808RfPriVendorCalState.calPathCtrl90 = volatileLoad(addr rf.calPathCtrl90)",
        "bl808RfPriVendorCalState.rxMode220 = volatileLoad(addr rf.rxMode220)",
    ]:
        assert expected in wifi_fw if expected.startswith("bl808RfPriVendorCalState:") or expected == "calPathCtrl90: uint32" else expected in vendor_save_cal_state_body
    for expected in [
        "rf_pri_restore_state_after_cal+0x0..0x13a",
        "let rf = rfRegs()",
        "let dfe = rfDfeInitRegs()",
        "volatileStore(addr rf.synthCtrl2c, bl808RfPriVendorCalState.synthCtrl2c)",
        "volatileStore(addr dfe.hbnCtrl30, bl808RfPriVendorCalState.hbnCtrl30)",
        "volatileStore(addr rf.calPathCtrl90, bl808RfPriVendorCalState.calPathCtrl90)",
        "volatileStore(addr rf.rxMode220, bl808RfPriVendorCalState.rxMode220)",
    ]:
        assert expected in vendor_restore_cal_state_body
    assert "addr rf.calPathConfig8c" not in vendor_save_cal_state_body
    assert "volatileStore(addr rf.calPathConfig8c" not in vendor_restore_cal_state_body
    for expected in [
        "rf_pri_cw_stop+0x0..0x1a",
        "let rf = rfRegs()",
        "addr rf.rxMode220",
        "0xFFFFE67D'u32",
        "rf_pri_restore_state_after_cal()",
    ]:
        assert expected in rf_pri_cw_stop_body
    for forbidden in [
        "regWrite(0x20001220",
        "rfRegWrite(",
        "rfRegRead(",
    ]:
        assert forbidden not in rf_pri_cw_stop_body
    for forbidden in [
        "for i, regAddr in RfPriCalSavedRegAddrs:",
        "result.words[i]",
        "state.words[i]",
        "rfRegRead(regAddr)",
        "rfRegWrite(regAddr",
    ]:
        assert forbidden not in save_cal_state_body
        assert forbidden not in restore_cal_state_body
        assert forbidden not in vendor_save_cal_state_body
        assert forbidden not in vendor_restore_cal_state_body
    for expected in [
        "proc signedRfPowerMeasurement(measurementWord: uint32): int32",
        "let signedPowerSample = (measurementWord shr 9) and 0x0000FFFF'u32",
        "proc signedRfAverageMeasurement(measurementWord: uint32): int32",
        "let signedAverageSample = measurementWord and 0x01FF_FFFF'u32",
        "proc signedRfAverageAdcMean(measurementWord: uint32): int32",
        "let signedAdcMeanSample = (measurementWord shr 10) and 0x0000_7FFF'u32",
    ]:
        assert expected in wifi_fw
    for forbidden in [
        "proc signedRfPowerMeasurement(word: uint32)",
        "proc signedRfAverageMeasurement(word: uint32)",
        "proc signedRfAverageAdcMean(word: uint32)",
        "volatileStore(addr table.txPowerCompWords700[i], word)",
    ]:
        assert forbidden not in wifi_fw
    for expected in [
        "for rfCalDebugWordIndex in 0 ..< nimFwDbgRfCalWords.len:",
        "nimFwDbgRfCalWords[rfCalDebugWordIndex] = 0",
        "nimFwDbgRfCalWords[rfCalDebugWordIndex] = words[rfCalDebugWordIndex]",
    ]:
        assert expected in rf_cal_debug_snapshot_body
    for forbidden in [
        "for i in 0 ..< nimFwDbgRfCalWords.len:",
        "nimFwDbgRfCalWords[i]",
        "words[i]",
    ]:
        assert forbidden not in rf_cal_debug_snapshot_body
    ble_controller = blecontroller_policy_source()
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
        "baseCtrlToCalCtrlPadding: array[5, uint32]",
        "capabilityToSynthCtrlPadding: array[2, uint32]",
        "priModeToRccalTonePadding: array[5, uint32]",
        "rccalToneToTxcalBiasPadding: array[3, uint32]",
        "txcalBiasToTxcalGainPadding: array[2, uint32]",
        "txcalParamToRbbRccalPadding: array[3, uint32]",
        "calPathToFcalPadding: array[4, uint32]",
        "sdmDivToRfPriBiasTrimPadding: uint32",
        "rfBiasTrimToCalMixerStatePadding: array[6, uint32]",
        "calMixerStateToVcoPairTablePadding: array[18, uint32]",
        "roscalToCalSingenPadding: array[39, uint32]",
        "calSingenCtrlToAmpPadding: uint32",
        "calSingenAmpToRxModePadding: uint32",
        "rxModeToCalDfePadding: array[6, uint32]",
        "calDfeToTxcalTosdacPadding: array[238, uint32]",
        "txcalTosdacToMeasurePrepPadding: array[2, uint32]",
        "calMeasurePrepToMeasureCtrlPadding: array[2, uint32]",
        "dfeInitBaseToHbnCtrlPadding: array[12, uint32]",
        "doAssert offsetof(BleRfRegBlock, baseCtrlToCalCtrlPadding) == 0x08",
        "doAssert offsetof(BleRfRegBlock, synthCtrl2c) == 0x2C",
        "doAssert offsetof(BleRfRegBlock, priModeToRccalTonePadding) == 0x34",
        "doAssert offsetof(BleRfRegBlock, rbbRccalCtrl80) == 0x80",
        "doAssert offsetof(BleRfRegBlock, rccalReplay84) == 0x84",
        "doAssert offsetof(BleRfRegBlock, calPathConfig8c) == 0x8C",
        "doAssert offsetof(BleRfRegBlock, channelCalStrobeB0) == 0xB0",
        "doAssert offsetof(BleRfRegBlock, channelCalStatusB4) == 0xB4",
        "doAssert offsetof(BleRfRegBlock, channelFcalConfigBc) == 0xBC",
        "doAssert offsetof(BleRfRegBlock, calMixerStateF0) == 0xF0",
        "doAssert offsetof(BleRfRegBlock, calMixerStateToVcoPairTablePadding) == 0xF4",
        "doAssert offsetof(BleRfRegBlock, calDfeState240) == 0x240",
        "doAssert offsetof(BleRfRegBlock, calDfeState244) == 0x244",
        "doAssert offsetof(BleRfRegBlock, calDfeToTxcalTosdacPadding) == 0x248",
        "doAssert offsetof(BleRfDfeInitBlock, dfeInitBaseToHbnCtrlPadding) == 0x00",
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
    ble_rf_reg_layout = ble_controller.split(
        "BleRfRegBlock {.packed.} = object", 1
    )[1].split("BleRfDfeInitBlock {.packed.} = object", 1)[0]
    ble_rf_dfe_layout = ble_controller.split(
        "BleRfDfeInitBlock {.packed.} = object", 1
    )[1].split("const", 1)[0]
    for old_name in [
        "reserved008",
        "reserved024",
        "reserved034",
        "reserved04c",
        "reserved05c",
        "reserved074",
        "reserved090",
        "reserved0c8",
        "reserved0d8",
        "reserved0f4",
        "reserved170",
        "reserved210",
        "reserved21c",
        "reserved224",
        "reserved248",
        "reserved604",
        "reserved610",
    ]:
        assert old_name not in ble_rf_reg_layout
    assert "reserved000" not in ble_rf_dfe_layout
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
        "doAssert offsetof(RfRegBlock, rfGainOrBzTempComp784) == 0x784",
        "doAssert offsetof(RfRegBlock, bzTemperatureComp7b8) == 0x7B8",
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
        "doAssert offsetof(RfPllBlock, fractionalDividerWord28) == 0x28",
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
    rf_reg_layout = wifi_fw.split(
        "RfRegBlock {.packed.} = object", 1
    )[1].split(
        "WifiModemBlock {.packed.} = object", 1
    )[0]
    for expected in [
        "baseCtrlToCalModePadding: array[3, uint32]",
        "calModeToCalCtrlPadding: uint32",
        "capabilityToSynthPadding: array[2, uint32]",
        "scanSynthLatch34ToLatch40Padding: array[2, uint32]",
        "scanSynthLatch40ToRccalTonePadding: uint32",
        "scanRxLatchToTxcalBiasPadding: array[2, uint32]",
        "bandwidthToFcalPadding: array[2, uint32]",
        "rfBiasTrimToCalMixerStatePadding: array[6, uint32]",
        "calMixerStateToRfCodeConfigPadding: array[6, uint32]",
        "rfCodeConfigToTxcalDefaultProfilePadding: array[6, uint32]",
        "txcalDefaultProfileToCalModeDefaultPadding: uint32",
    ]:
        assert expected in rf_reg_layout
    for old_name in [
        "reserved008",
        "reserved018",
        "reserved024",
        "reserved038",
        "reserved044",
        "reserved050",
        "reserved098",
        "reserved0d8",
        "reserved0f4",
        "reserved110",
        "reserved134",
    ]:
        assert old_name not in rf_reg_layout
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
    for expected in [
        "for vcoPairRegisterIndex in 0'u ..< 10'u:",
        "volatileStore(addr rf.vcoPairTable13c[vcoPairRegisterIndex],",
    ]:
        assert expected in vco_table_body
    assert "volatileStore(addr rf.vcoPairTable13c[i]" not in vco_table_body
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
    seed_default_vco_body = wifi_fw.split(
        "proc rfCalibSeedDefaultVcoIfEmpty() =", 1
    )[1].split("proc rfCalibWriteDefaultVco40M", 1)[0]
    write_default_vco_body = wifi_fw.split(
        "proc rfCalibWriteDefaultVco40M() =", 1
    )[1].split("proc replayRfPriCalRegisters", 1)[0]
    for expected in [
        "let rf = rfRegs()",
        "addr rf.rfGainTable760",
        "addr rf.rfGainTable75c",
        "addr rf.rfGainTable79c",
        "addr rf.rfGainTable794",
        "addr rf.rfGainTable78c",
        "addr rf.rfGainOrBzTempComp784",
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
        "for defaultVcoCalHalfwordIndex in 0 ..< RfPriDefaultVcoCal40M.len:",
        "halfwords[defaultVcoCalHalfwordIndex + RfCalibLoVcoHalfwordBase]",
        "for defaultVcoCalHalfwordIndex, defaultVcoCalHalfwordValue in RfPriDefaultVcoCal40M:",
        "defaultVcoCalHalfwordValue",
    ]:
        assert expected in seed_default_vco_body
    for expected in [
        "for defaultVcoCalHalfwordIndex, defaultVcoCalHalfwordValue in RfPriDefaultVcoCal40M:",
        "halfwords[defaultVcoCalHalfwordIndex + RfCalibLoVcoHalfwordBase] =",
        "defaultVcoCalHalfwordValue",
    ]:
        assert expected in write_default_vco_body
    for body in [seed_default_vco_body, write_default_vco_body]:
        assert "halfwords[i + RfCalibLoVcoHalfwordBase]" not in body
        assert "for i, value in RfPriDefaultVcoCal40M:" not in body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.txPowerComp704",
        "addr rf.txPowerComp7ac",
        "let channelCompTableIndex = int(channelIndex - 1'u32)",
        "bl808RfChannelPowerComp[channelCompTableIndex]",
    ]:
        assert expected in total_power_comp_body
    for expected in [
        "let channelCompTableIndex = int(channelIndex - 1'u32)",
        "bl808RfChannelLpPowerComp[channelCompTableIndex]",
        "bl808RfChannelPowerComp[channelCompTableIndex]",
        "rfPriApplyLowPowerRuntimeDelta(delta)",
    ]:
        assert expected in lp_power_comp_body
    for forbidden in [
        "RfBase + 0x704'u",
        "RfBase + 0x7AC'u",
        "let idx = int(channelIndex - 1'u32)",
        "bl808RfChannelPowerComp[idx]",
    ]:
        assert forbidden not in total_power_comp_body
        assert forbidden not in lp_power_comp_body
    for expected in [
        "for channelPowerCompIndex in 0 ..< bl808RfChannelPowerComp.len:",
        "bl808RfChannelPowerComp[channelPowerCompIndex] =",
        "rfSignedByte(bytes[channelPowerCompIndex])",
    ]:
        assert expected in input_channel_power_comp_body
    for expected in [
        "for channelLowPowerCompIndex in 0 ..< bl808RfChannelLpPowerComp.len:",
        "bl808RfChannelLpPowerComp[channelLowPowerCompIndex] =",
        "rfSignedByte(bytes[channelLowPowerCompIndex])",
    ]:
        assert expected in input_lp_channel_power_comp_body
    for expected in [
        "for tempCompTableIndex in 0 ..< count:",
        "bl808RfTempChannels[tempCompTableIndex] = channelWords[tempCompTableIndex]",
        "bl808RfTempHighOffsets[tempCompTableIndex] = highWords[tempCompTableIndex]",
        "bl808RfTempLowOffsets[tempCompTableIndex] = lowWords[tempCompTableIndex]",
    ]:
        assert expected in input_temp_comp_body
    for expected in [
        "for bzChannelPowerCompIndex in 0 ..< bl808RfBzChannelPowerComp.len:",
        "bl808RfBzChannelPowerComp[bzChannelPowerCompIndex] =",
        "rfSignedByte(bytes[bzChannelPowerCompIndex])",
    ]:
        assert expected in input_bz_channel_power_comp_body
    for expected in [
        "for bzChannelPowerCompIndex in 0 ..< bl808RfBzChannelPowerComp.len:",
        "BzChannelPowerCompOffset + bzChannelPowerCompIndex",
    ]:
        assert expected in refresh_bz_channel_power_comp_body
    for body in [
        input_channel_power_comp_body,
        input_lp_channel_power_comp_body,
        input_temp_comp_body,
        input_bz_channel_power_comp_body,
        refresh_bz_channel_power_comp_body,
    ]:
        assert "for i in 0 ..<" not in body
        assert "[i]" not in body
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
        "rf_pri.c.o rf_pri_xtalfreq",
        "private PLL",
        "rfPriWifiPllConfig()",
    ]:
        assert expected in rf_pri_xtalfreq_body
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
        "let rfStageSnapshotSlot = int(nim_wifi_rf_stage_snapshot_count mod",
        "nim_wifi_rf_stage_tag_log[rfStageSnapshotSlot] = tag",
        "nim_wifi_rf_stage_rfd0_log[rfStageSnapshotSlot]",
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
        "let idx = int(nim_wifi_rf_stage_snapshot_count",
        "nim_wifi_rf_stage_tag_log[idx]",
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
    assert "let useHighBandTxcalReplayWindow = channelMhz >= RfOptimizeTxcalFirstMhz" in rf_optimize_body
    assert "if useHighBandTxcalReplayWindow:" in rf_optimize_body
    assert "uint32(useHighBandTxcalReplayWindow) shl 8" in rf_optimize_body
    assert "let useWord4 =" not in rf_optimize_body
    assert "if useWord4:" not in rf_optimize_body
    assert "RfTxcalParamReg.uint" not in rf_optimize_body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.rccalTone48",
        "addr rf.scanRxLatch4c",
        "addr rf.txcalDfe88",
        "addr rf.txcalTosdac600",
        "addr rf.scanTxMeasureControl62c",
        "let bzTxcalSnapshotSlot =",
        "nim_wifi_rf_bz_txcal_tag_log[bzTxcalSnapshotSlot] = tag",
        "nim_wifi_rf_bz_txcal_rf162c_log[bzTxcalSnapshotSlot]",
    ]:
        assert expected in bz_txcal_snapshot_body
    for forbidden in [
        "rfRegRead(0x20001048'u32)",
        "rfRegRead(0x2000104C'u32)",
        "rfRegRead(RfPriTxcalDfeReg)",
        "rfRegRead(0x20001600'u32)",
        "rfRegRead(0x2000162C'u32)",
        "let idx = int(nim_wifi_rf_bz_txcal_snapshot_count",
        "nim_wifi_rf_bz_txcal_tag_log[idx]",
    ]:
        assert forbidden not in bz_txcal_snapshot_body
    assert "let rf = rfRegs()" in rxcal_replay_body
    assert "for rxcalReplayRecordIndex in 0 ..< 4:" in rxcal_replay_body
    assert "addr rf.rxcalReplay[rxcalReplayRecordIndex]" in rxcal_replay_body
    assert "addr rf.rxcalReplay[i]" not in rxcal_replay_body
    assert "RfBase + 0x170'u" not in rxcal_replay_body
    sta_tx_prepare = wifi_fw.split(
        "proc wifi_nimfw_prepare_sta_tx_channel*() {.exportc, cdecl.} =",
        1,
    )[1].split("proc wifi_nimfw_coex_force_wifi_role*", 1)[0]
    assert "for staTxChannelVifIndex in 0'u8 ..< MAX_VIFS.uint8:" in sta_tx_prepare
    assert "let vif = vifChannelForIdx(staTxChannelVifIndex)" in sta_tx_prepare
    assert "for i in 0'u8 ..< MAX_VIFS.uint8:" not in sta_tx_prepare
    assert "let vif = vifChannelForIdx(i)" not in sta_tx_prepare
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
    assert "rwip_wlcoex_set*(en: bool)" in blecontroller_policy_source()
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
    assert "memoryWords: array[512, uint32]" in wifi_fw
    assert "doAssert sizeof(WifiAgcMemoryRam) == 2048" in wifi_fw
    assert "doAssert offsetof(WifiAgcMemoryRam, memoryWords) == 0" in wifi_fw
    assert "WifiAgcMemoryBase = 0x24C0A000'u" in wifi_fw
    assert "WifiAgcMemoryWords = 512" in wifi_fw
    assert "template wifiAgcMemoryRegs(): ptr WifiAgcMemoryRam" in wifi_fw
    assert 'var agcmem* {.exportc: "agcmem".}: array[512, uint32]' in wifi_fw
    assert (
        "proc phy_ldpc_tx_supported*(): bool {.exportc, cdecl.}"
        in wifi_fw
    )
    assert "Explicit legacy BL606P PHY fallback: reports whether TX LDPC is supported." not in wifi_fw
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
        "nimFwDbgPhyAgcDestFirst = volatileLoad(addr dst.memoryWords[0])",
        "nimFwDbgPhyAgcDestLast =",
    ]:
        assert expected in wifi_fw
    copy_phy_init_body = wifi_fw.split("proc copyPhyInitCfg(cfg: pointer) =", 1)[
        1
    ].split("proc copyAgcMemory() =", 1)[0]
    copy_agc_body = wifi_fw.split("proc copyAgcMemory() =", 1)[1].split(
        "proc bl808PhyProgramRecoveredRegs()", 1
    )[0]
    assert "let dst = wifiAgcMemoryRegs()" in copy_agc_body
    for expected in [
        "for phyInitConfigWordIndex in 0 ..< 9:",
        "volatileStore(addr env.initCfgWords[phyInitConfigWordIndex],",
        "words[phyInitConfigWordIndex])",
        "volatileStore(addr env.initCfgWords[phyInitConfigWordIndex], 0'u32)",
    ]:
        assert expected in copy_phy_init_body
    for expected in [
        "for agcMemoryWordIndex in 0 ..< WifiAgcMemoryWords:",
        "volatileStore(addr dst.memoryWords[agcMemoryWordIndex],",
        "src[agcMemoryWordIndex])",
    ]:
        assert expected in copy_agc_body
    for forbidden in [
        "for i in 0 ..< 9:",
        "volatileStore(addr env.initCfgWords[i], words[i])",
        "volatileStore(addr env.initCfgWords[i], 0'u32)",
    ]:
        assert forbidden not in copy_phy_init_body
    for forbidden in [
        "for i in 0 ..< WifiAgcMemoryWords:",
        "volatileStore(addr dst.memoryWords[i], src[i])",
    ]:
        assert forbidden not in copy_agc_body
    assert "cast[ptr UncheckedArray[uint32]](AgcMemoryBase)" not in wifi_fw
    assert "copyAgcMemory()" in wifi_fw
    phy_field_assert_body = wifi_fw.split(
        "proc validatePhyInitFieldFits(cond: cstring; value, shift, mask: uint32)",
        1,
    )[1].split("proc phyClockCountFromVersion", 1)[0]
    for expected in [
        "if (((value shl shift) and not mask) != 0'u32):",
        'wrapPhyAssertErr("phy.c", cond, 0x35C4.cint)',
    ]:
        assert expected in phy_field_assert_body
    recovered_phy_body = wifi_fw.split(
        "proc bl808PhyProgramRecoveredRegs() =",
        1,
    )[1].split("proc bl808PhyProgramAgcCopyTailRegs()", 1)[0]
    assert "Typed translation of librf_bl808.a:phy.c.o phy_init+0x5a..0x310" in recovered_phy_body
    assert "Partial translation" not in recovered_phy_body
    assert "let mdm = wifiModemRegs()" in recovered_phy_body
    assert "let macPhy = macPhyCtrlRegs()" in recovered_phy_body
    for expected in [
        "let spatialStreamCountMinus1 =",
        "let txChainCountMinus1 =",
        "let heOrBandwidthProfile =",
        "let modemCapability21 =",
        "let modemCapability30 =",
        "validatePhyInitFieldFits(",
        "(((uint32_t)rxnssmax << 4) & ~((uint32_t)0x00000070)) == 0",
        "(((uint32_t)rxndpnstsmax << 12) & ~((uint32_t)0x00007000)) == 0",
        "(((uint32_t)confnrx << 8) & ~((uint32_t)0x00000F00)) == 0",
        "(((uint32_t)txnssmax << 4) & ~((uint32_t)0x00000070)) == 0",
        "(((uint32_t)ntxmax << 20) & ~((uint32_t)0x00700000)) == 0",
        "(((uint32_t)maxsupportednss << 20) & ~((uint32_t)0x00700000)) == 0",
        "(((uint32_t)confntx << 4) & ~((uint32_t)0x000000F0)) == 0",
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
        "addr rxv.rxFormatModeWord0",
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
        '    {.exportc: "phy_get_channel", cdecl.} =',
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
    phy_vht_body = wifi_fw.split(
        "proc phy_vht_supported*(): bool {.exportc, cdecl.} =",
        1,
    )[1].split("proc phy_he_supported*", 1)[0]
    for expected in [
        "let version = modemVersionReg()",
        "((version shr 21) and 1'u32) != 0'u32",
        "((version shr 24) and 0x3'u32) != 0'u32",
    ]:
        assert expected in phy_vht_body
    assert "(modemVersionReg() and (1'u32 shl 16)) != 0" not in wifi_fw
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
    assert "if (aid.uint32 and not 0x7FF'u32) != 0'u32:" in phy_aid_body
    assert "(((uint32_t)hestaid << 0) & ~((uint32_t)0x000007FF)) == 0" in phy_aid_body
    assert "0x35C3.cint" in phy_aid_body
    assert "addr mdm.aid" in phy_aid_body
    assert "addr mdm.aidMaskLo" in phy_aid_body
    assert "addr mdm.aidMaskHi" in phy_aid_body
    assert "volatileStore(addr mdm.aid, aid.uint32)" in phy_aid_body
    assert "aid.uint32 and 0x7FF'u32" not in phy_aid_body
    phy_group_body = wifi_fw.split(
        "proc phy_set_group_id_info*(membership: pointer, userPosition: pointer)",
        1,
    )[1].split("proc phy_update_power_table*", 1)[0]
    assert "addr mdm.groupMembership0" in phy_group_body
    assert "addr mdm.groupMembership1" in phy_group_body
    assert "for groupUserPositionWordIndex in 0 ..< 4:" in phy_group_body
    assert "addr mdm.userPosition[groupUserPositionWordIndex]" in phy_group_body
    assert "src[groupUserPositionWordIndex]" in phy_group_body
    assert "addr mdm.userPosition[i]" not in phy_group_body
    assert "for i in 0 ..< 4:" not in phy_group_body
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
    trpc_copy_in_body = wifi_fw.split("proc trpcCopyTable(dstOffset: int, src: pointer, count: int) =", 1)[
        1
    ].split("proc trpcCopyFromWlCfg", 1)[0]
    trpc_copy_out_body = wifi_fw.split("proc trpcCopyTableOut(dst: pointer, srcOffset: int, count: int) =", 1)[
        1
    ].split("proc trpc_power_get*", 1)[0]
    for expected in [
        "for txPowerRateTableByteIndex in 0 ..< count:",
        "trpcTxpwrVsRateTable[dstOffset + txPowerRateTableByteIndex] =",
        "bytes[txPowerRateTableByteIndex]",
    ]:
        assert expected in trpc_copy_in_body
    for expected in [
        "for txPowerRateTableByteIndex in 0 ..< count:",
        "bytes[txPowerRateTableByteIndex] =",
        "trpcTxpwrVsRateTable[srcOffset + txPowerRateTableByteIndex]",
    ]:
        assert expected in trpc_copy_out_body
    for body in [trpc_copy_in_body, trpc_copy_out_body]:
        assert "for i in 0 ..< count:" not in body
        assert "bytes[i]" not in body
    bba_pd_gain_body = wifi_fw.split(
        "proc bbaProgramPdGain(gain: uint32) =",
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
    for expected in [
        'var bbaEnv* {.align: 4, exportc: "bba_env".}: BbaRuntimeState',
        "proc bba_get_pd_gain*(): uint8 {.exportc, cdecl.} =",
        "proc bba_get_pd_state*(): uint8 {.exportc, cdecl.} =",
        "proc bba_get_pd_mile*(): uint8 {.exportc, cdecl.} =",
        "proc bba_set_pd_gain*(gain: uint32) {.exportc, cdecl.} =",
        "proc bba_set_pd_ofdm*(enable: uint32) {.exportc, cdecl.} =",
        "proc bba_set_pd_dsss*(enable: uint32) {.exportc, cdecl.} =",
        "proc bba_set_pd_rssi*(rssiThreshold: uint32) {.exportc, cdecl.} =",
        "proc bba_set_pd_mile*(enable: uint32) {.exportc, cdecl.} =",
        "proc bba_set_pd_state*(state: uint32) {.exportc, cdecl.} =",
        "proc bba_get_pd_cfg*(ofdmOut, dsssOut, rssiOut: pointer) {.exportc, cdecl.} =",
        "proc bba_pd_reset*() {.exportc, cdecl.} =",
        "proc bba_ce_reset*() {.exportc, cdecl.} =",
        "proc bba_ce_update_capcode*() {.exportc, cdecl.} =",
        "proc bba_ce_loop*(rssi: int32, ppm: int32) {.exportc, cdecl.} =",
        "proc bba_pd_loop*(rssi: int32) {.exportc, cdecl.} =",
    ]:
        assert expected in wifi_fw
    bba_public_body = wifi_fw.split(
        "proc bba_get_pd_gain*(): uint8 {.exportc, cdecl.} =",
        1,
    )[1].split("proc bba_init()", 1)[0]
    for expected in [
        "volatileLoad(addr bbaState().pdGainCode)",
        "volatileLoad(addr bbaState().pdRssiState)",
        "volatileLoad(addr bbaState().pdCompLatch)",
        "bbaProgramPdGain(gain)",
        "addr bbaAgcRegs().pdGain390",
        "addr bbaAgcRegs().pdCompC830",
        "addr bbaAgcRegs().pdSlope3c0",
        "bbaSetPdLatch(enable != 0'u32)",
        "let saved = bbaIrqSave()",
        "let oldState = volatileLoad(addr bbaState().pdRssiState).uint32",
        "bba_set_pd_ofdm(1'u32)",
        "bba_set_pd_dsss(1'u32)",
        "bba_set_pd_ofdm(0'u32)",
        "bba_set_pd_dsss(0'u32)",
        "bbaSetPdLatch(false)",
        "bbaSetPdLatch(true)",
        "bbaProgramPdGain(0'u32)",
        "bbaProgramPdGain(1'u32)",
        "bbaProgramPdGain(2'u32)",
        "volatileStore(addr bbaState().pdRssiState, state.uint8)",
        "bbaIrqRestore(saved)",
        "volatileStore(addr bbaState().cePpmAccumulator, 0'u16)",
        "volatileStore(addr bbaState().ceUpdateInterval, 16'u8)",
        "bbaApplyCarrierErrorCapcode()",
        "bbaRunCarrierErrorLoop(rssi, ppm)",
        "bbaRunPowerDetectLoop(rssi)",
    ]:
        assert expected in bba_public_body
    for forbidden in [
        "cast[ptr uint32](0x24C0B390'u)",
        "cast[ptr uint32](0x24C0B3C0'u)",
        "cast[ptr uint32](0x24C0C830'u)",
        "cast[ptr uint32](0x2000150C'u)",
    ]:
        assert forbidden not in bba_public_body
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
    )[1].split("proc bbaApplyCarrierErrorCapcode", 1)[0]
    bba_carrier_error_capcode_body = wifi_fw.split(
        "proc bbaApplyCarrierErrorCapcode() =",
        1,
    )[1].split("proc bbaRunCarrierErrorLoop", 1)[0]
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
    for expected in [
        "let carrierErrorPpmOffset = signExtend(",
        "if carrierErrorPpmOffset == 0'i32:",
        "if carrierErrorPpmOffset > 0'i32:",
    ]:
        assert expected in bba_carrier_error_capcode_body
    assert "let offset = signExtend(" not in bba_carrier_error_capcode_body
    assert "if offset > 0'i32:" not in bba_carrier_error_capcode_body
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
    phy_get_antenna_body = wifi_fw.split(
        "proc phy_get_antenna_set*(): uint8 {.exportc, cdecl.} =",
        1,
    )[1].split("proc phy_switch_antenna_paths*", 1)[0]
    for expected in [
        "let rxChainCount = modemVersionReg() and 0xF'u32",
        "uint8((1'u32 shl rxChainCount) - 1'u32)",
    ]:
        assert expected in phy_get_antenna_body
    assert "proc phy_get_antenna_set*(): uint8 {.exportc, cdecl.} =\n    1'u8" not in wifi_fw
    copy_phy_cfg_body = wifi_fw.split(
        "proc copyPhyInitCfg(cfg: pointer) =",
        1,
    )[1].split("proc copyAgcMemory()", 1)[0]
    for expected in [
        "let env = phyEnvViewPtr()",
        "addr env.initCfgWords[phyInitConfigWordIndex]",
        "addr env.channelBandType",
        "addr env.primaryFreq",
        "addr env.centerFreq1",
        "addr env.centerFreq2OrTxPower",
    ]:
        assert expected in copy_phy_cfg_body
    for forbidden in [
        "phyEnvWord((i * 4).uint)",
        "addr env.initCfgWords[i]",
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
        "addr env.txPowerAndFlags",
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
    for expected in [
        "proc phy_assert_rec*(fileOrCond, condOrFile: cstring, line: cint)",
        "proc phy_assert_warn*(fileOrCond, condOrFile: cstring, line: cint)",
        "proc phy_assert_err*(fileOrCond, condOrFile: cstring, line: cint)",
        "wrapPhyAssertErr(fileOrCond, condOrFile, line)",
    ]:
        assert expected in wifi_fw
    assert "line == 586.cint or line == 0x20FA.cint or line == 0x2A60.cint" in wifi_fw
    blecontroller = blecontroller_policy_source()
    blerfdata = (ROOT / "src/bl808/blerfdata.nim").read_text()
    assert "BleLdpcMemBase* = 0x24C09000'u32" in blerfdata
    assert "BleLdpcMem*: array[375, uint32]" in blerfdata
    assert "BleLdpcInitWords = 190" in blecontroller
    assert "BlePhyMemoryRegs {.packed.} = object" in blecontroller
    assert "doAssert offsetof(BlePhyMemoryRegs, ldpcMode) == 0x834" in blecontroller
    assert "doAssert offsetof(BlePhyMemoryRegs, ldpcLoadAddress) == 0xB340" in blecontroller
    assert "doAssert offsetof(BlePhyMemoryRegs, ldpcLoadLength) == 0xB344" in blecontroller
    assert "doAssert offsetof(BlePhyMemoryRegs, ldpcLoadControl) == 0xB348" in blecontroller
    assert "bleRegUpdatePtr(addr phyMem.ldpcMode, BlePhyLdpcLoadModeMask" in blecontroller
    assert "bleRegStorePtr(addr phyMem.ldpcLoadAddress, 0'u32)" in blecontroller
    assert "bleRegStorePtr(addr phyMem.ldpcLoadLength, 0'u32)" in blecontroller
    assert "bleRegStorePtr(addr phyMem.ldpcLoadControl, 0'u32)" in blecontroller
    assert "bleRegClearPtr(addr phyMem.memMode, BlePhyLdpcMemSelectMask)" in blecontroller
    assert "writeBleMemoryWords(blerfdata.BleLdpcMemBase, blerfdata.BleLdpcMem" in blecontroller
    for forbidden in [
        "ldpcCtrlB340",
        "ldpcCtrlB344",
        "ldpcCtrlB348",
    ]:
        assert forbidden not in blecontroller

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


def test_wifi_state_environment_padding_names_are_semantic():
    wifi_fw = wifi_fw_policy_source()

    vif_mgmt_layout = wifi_fw.split(
        "VifMgmtEnvView {.packed.} = object", 1
    )[1].split("VifMgmtHostapdOpsEnvView {.packed.} = object", 1)[0]
    ps_env_layout = wifi_fw.split(
        "PsEnvView {.packed.} = object", 1
    )[1].split("PsDozeEnvView {.packed.} = object", 1)[0]
    ps_doze_layout = wifi_fw.split(
        "PsDozeEnvView {.packed.} = object", 1
    )[1].split("SmEnvView {.packed.} = object", 1)[0]
    sm_env_layout = wifi_fw.split(
        "SmEnvView {.packed.} = object", 1
    )[1].split("ApmEnvView {.packed.} = object", 1)[0]
    apm_env_layout = wifi_fw.split(
        "ApmEnvView {.packed.} = object", 1
    )[1].split("ApmStaSlotOverlay {.packed.} = object", 1)[0]
    apm_sta_slot_layout = wifi_fw.split(
        "ApmStaSlotOverlay {.packed.} = object", 1
    )[1].split("ConnectInfoView {.packed.} = object", 1)[0]

    for expected in [
        "primaryApIdxTailPadding*: uint8",
        "doAssert offsetof(VifMgmtEnvView, primaryApIdxTailPadding) == 19",
        "pendingCountToNullRetryPadding*: array[3, uint8]",
        "uapsdCallbackToActivityPadding*: array[8, uint8]",
        "psActivityToPeriodPadding*: array[2, uint8]",
        "uapsdStateToFlagsPadding*: array[3, uint8]",
        "deferredModeTailPadding*: array[2, uint8]",
        "preStateTailPadding*: array[3, uint8]",
        "connectModeToAuthRetryPadding*: array[3, uint8]",
        "stateToVendorIePadding*: array[3, uint8]",
        "vendorIeLenTailPadding*: array[2, uint8]",
        "pendingBssParamsToBeaconPadding*: array[4, uint8]",
        "slotBaseToMacPadding*: array[12, uint8]",
        "macToHandlePadding*: array[2, uint8]",
        "doAssert offsetof(PsEnvView, pendingCountToNullRetryPadding) == 9",
        "doAssert offsetof(PsEnvView, uapsdCallbackToActivityPadding) == 20",
        "doAssert offsetof(PsEnvView, psActivityToPeriodPadding) == 30",
        "doAssert offsetof(PsEnvView, uapsdStateToFlagsPadding) == 49",
        "doAssert offsetof(PsEnvView, deferredModeTailPadding) == 54",
        "doAssert offsetof(PsDozeEnvView, preStateTailPadding) == 61",
        "doAssert offsetof(SmEnvView, connectModeToAuthRetryPadding) == 21",
        "doAssert offsetof(SmEnvView, stateToVendorIePadding) == 45",
        "doAssert offsetof(SmEnvView, vendorIeLenTailPadding) == 54",
        "doAssert offsetof(ApmEnvView, pendingBssParamsToBeaconPadding) == 12",
        "doAssert offsetof(ApmStaSlotOverlay, slotBaseToMacPadding) == 0",
        "doAssert offsetof(ApmStaSlotOverlay, macToHandlePadding) == 18",
    ]:
        assert expected in wifi_fw

    assert "reserved19*" not in vif_mgmt_layout
    for forbidden in [
        "reserved09*",
        "reserved20*",
        "reserved30*",
        "reserved49*",
        "reserved54*",
    ]:
        assert forbidden not in ps_env_layout
    assert "reserved61*" not in ps_doze_layout
    for forbidden in [
        "reserved21*",
        "reserved45*",
        "reserved54*",
    ]:
        assert forbidden not in sm_env_layout
    assert "reserved12*" not in apm_env_layout
    assert "reserved00*" not in apm_sta_slot_layout
    assert "reserved18*" not in apm_sta_slot_layout


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
        "PRIMARY_WIFI_RF_PHY_ENTRYPOINTS = [",
        "def check_primary_wifi_entrypoints(path: Path, label: str) -> list[str]:",
        "PRIMARY_WIFI_RF_PHY_ENTRYPOINTS",
        'f"{label} primary WiFi RF/PHY entrypoints"',
        'missing = check_defined(args.wifi_object, WIFI_RF_SYMBOLS, "wifi-object")',
        'failures.extend(f"wifi-object:{symbol}" for symbol in missing)',
        'f"wifi-object:missing-primary:{symbol}"',
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
        'if label == "wifi":',
        'f"{obj}:missing-primary:{symbol}"',
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
        '"wl_wlan_power_table_update"',
        '"wl_rf_tcal_handler"',
        '"wl_rf_tcal_period_get"',
        '"wl_bz_rx_optimize"',
        '"wl_bz_rx_optimize_restore"',
        '"wl_rf_set_bz_target_power_table"',
        '"wl_rf_set_channel_pwr_comp"',
        '"wl_wlan_bb_reset"',
        '"wl_wlan_bb_pre_proc"',
        '"wl_wlan_bb_post_proc"',
        '"wl_wlan_rssi_get"',
        '"wl_wlan_ppm_get"',
        '"wl_wlan_power_cfg_get"',
        '"wl_154_power_cfg_get"',
        '"wl_bt_power_cfg_get"',
        '"wl_ble_power_cfg_get"',
        '"wl_init"',
        '"rf_init"',
        '"rfc_init"',
        '"modem_init_core"',
        '"phy_init"',
        '"rf_set_channel"',
        '"rfc_wlan_mode_force"',
        '"rfc_dump"',
        '"crm_get_cpu_freq"',
        '"phy_assert_err"',
        '"phy_assert_rec"',
        '"phy_assert_warn"',
        '"wl_rmem_size_get"',
        '"wl_env_get"',
        '"wl_lp_init"',
        '"wl_lp_status_clear"',
        '"wl_lp_status_update"',
        '"rfc_config_bandwidth"',
        '"rfc_config_channel"',
        '"modem_init"',
        '"modem_restore"',
        '"rf_dump_status"',
        '"rf_lo_isr"',
        '"rf_clkpll_isr"',
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
        '"bba_get_pd_cfg"',
        '"bba_get_pd_gain"',
        '"bba_get_pd_mile"',
        '"bba_get_pd_state"',
        '"bba_pd_reset"',
        '"bba_ce_reset"',
        '"bba_ce_update_capcode"',
        '"bba_ce_loop"',
        '"bba_pd_loop"',
        '"bba_set_pd_dsss"',
        '"bba_set_pd_gain"',
        '"bba_set_pd_mile"',
        '"bba_set_pd_ofdm"',
        '"bba_set_pd_rssi"',
        '"bba_set_pd_state"',
        '"rf_pri_init"',
        '"rf_pri_input_xtalfreq"',
        '"rf_pri_get_xtalfreq"',
        '"rf_pri_xtalfreq"',
        '"rf_pri_init_calib_mem"',
        '"rf_pri_config_mode"',
        '"rf_pri_cfg_init"',
        '"rf_pri_input_device_info"',
        '"rf_pri_input_chip_ver"',
        '"rf_pri_get_wl_cfg"',
        '"rf_pri_get_txgain_max"',
        '"rf_pri_get_txgain_min"',
        '"rf_pri_roscal"',
        '"rf_pri_rccal"',
        '"rf_pri_manual_incremental_cal_start"',
        '"rf_pri_manual_incremental_cal_stop"',
        '"rf_pri_set_rcal_code"',
        '"rf_pri_save_state_before_cal"',
        '"rf_pri_restore_state_after_cal"',
        '"rf_pri_cw_start"',
        '"rf_pri_cw_stop"',
        '"rf_pri_lo_fcal"',
        '"rf_pri_lo_acal"',
        '"rf_pri_txcal"',
        '"rf_pri_bz_txcal"',
        '"rf_pri_rxcal"',
        '"rf_pri_full_cal"',
        '"rf_pri_restore_cal_reg"',
        '"rf_pri_update_param"',
        '"rf_pri_read"',
        '"rf_pri_get_notch_param"',
        '"rf_pri_optimize"',
        '"rf_pri_bz_optimize"',
        '"rf_pri_bz_optimize_restore"',
        '"rf_pri_input_channel_pwr_comp"',
        '"rf_pri_input_channel_lp_pwr_comp"',
        '"rf_pri_set_channel_lp_pwr_comp"',
        '"rf_pri_input_temp_comp_param"',
        '"rf_pri_set_temp_comp"',
        '"rf_pri_input_bz_channel_pwr_comp"',
        '"rf_pri_set_bz_channel_pwr_comp"',
        '"rf_pri_set_bz_temp_comp"',
        '"rf_pri_get_bz_temp_mp_comp"',
        '"rf_pri_input_bz_target_power"',
        '"rf_pri_set_channel_pwr_comp"',
        '"rf_pri_set_channel_total_pwr_comp"',
        '"rf_pri_set_bandwidth"',
        '"rf_pri_get_vco_freq_cw"',
        '"rf_pri_get_vco_idac_cw"',
        '"rfc_config_power"',
        '"rfc_get_power_level"',
        '"rfc_power_meas"',
        '"rfc_apply_tx_dvga_offset"',
        '"rfc_apply_tx_dvga"',
        '"rfc_apply_tx_power_offset"',
        '"rfc_sg_start"',
        '"rfc_sg_stop"',
        '"rfc_rf_fsm_force"',
        '"rfc_rc_fsm_force"',
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
    wifi_fw = wifi_fw_policy_source()
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
    manual_incremental_cal_stop_body = wifi_fw.split(
        "proc rf_pri_manual_incremental_cal_stop() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_get_wl_cfg", 1)[0]
    cw_sdm_body = wifi_fw.split(
        "proc rfPriCwSdmDivWord(channelMhz: uint32): uint32 {.inline.} =",
        1,
    )[1].split("proc rfPriProgramCwChannel", 1)[0]
    cw_program_body = wifi_fw.split(
        "proc rfPriProgramCwChannel(channelMhz: uint32) =",
        1,
    )[1].split("proc rfPriStartCwDfeStrobes", 1)[0]
    cw_start_body = wifi_fw.split(
        "proc rf_pri_cw_start(targetPowerDbm: int32; channelMhz: uint32)",
        1,
    )[1].split("proc signedRfPowerMeasurement", 1)[0]
    square_rf_sample_body = wifi_fw.split(
        "proc squareRfSample(sample: int32): uint64",
        1,
    )[1].split("proc saturatingRfUint32", 1)[0]
    temp_power_comp_body = wifi_fw.split(
        "proc rfPriComputeTemperaturePowerCompForMhz(channelMhz: uint16;",
        1,
    )[1].split("proc rf_pri_set_channel_total_pwr_comp", 1)[0]
    vco_cal_word_body = wifi_fw.split(
        "proc rfPriVcoCalWord(channelMhz: uint32): uint32 =",
        1,
    )[1].split("proc rf_pri_get_vco_freq_cw", 1)[0]
    pack_five_fields_body = wifi_fw.split(
        "proc rfPriPackFive6BitFields(values: array[5, int16]): uint32 =",
        1,
    )[1].split("proc rf_pri_set_bz_channel_pwr_comp", 1)[0]
    set_bz_channel_power_comp_body = wifi_fw.split(
        "proc rf_pri_set_bz_channel_pwr_comp() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rfPriUpdateBzTempCorrAverage", 1)[0]
    write_bz_temp_comp_deltas_body = wifi_fw.split(
        "proc rfPriWriteBzTemperatureCompDeltas() =",
        1,
    )[1].split("proc rf_pri_set_bz_temp_comp", 1)[0]
    set_bz_temp_comp_body = wifi_fw.split(
        "proc rf_pri_set_bz_temp_comp(sensorTemperatureC: int32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_get_bz_temp_mp_comp", 1)[0]
    set_channel_power_comp_body = wifi_fw.split(
        "proc rf_pri_set_channel_pwr_comp(channelIndex: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_set_bandwidth", 1)[0]
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
    wb03_rccal_seed_body = wifi_fw.split(
        "proc rfPriApplyWb03RccalSeed() =",
        1,
    )[1].split("proc rfPriApplyWb03ScanRxLatches()", 1)[0]
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
        "rfPriRecordRf70SearchWindow(\n    window, ok, bestNibble, runnerUpNibble, bestSample, runnerUpSample,",
    ]:
        if expected.startswith("exportc"):
            assert expected in wifi_fw
        else:
            assert expected in rf70_search_body
    for expected in [
        "rf_pri_manual_incremental_cal_stop+0x0..0x1e",
        "let rf = rfRegs()",
        "addr rf.synthCtrl2c",
        "0x00000040'u32",
        "addr rf.baseCtrl1",
        "not 0x0000000C'u32",
        "0x00000004'u32",
        "addr rf.calCtrl1c",
        "0x00000060'u32",
    ]:
        assert expected in manual_incremental_cal_stop_body
    for forbidden in [
        "regWrite(0x2000102C",
        "regWrite(0x20001004",
        "regWrite(0x2000101C",
        "rfRegWrite(",
        "rfRegOr(",
    ]:
        assert forbidden not in manual_incremental_cal_stop_body
    for expected in [
        "uint64(channelMhz) * 40'u64 * (1'u64 shl 22)",
        "uint64(divisorTenths)",
        "0x3FFF_FFFF'u32",
    ]:
        assert expected in cw_sdm_body
    for expected in [
        "rf_pri_cw_start+0x1d2..0x25c",
        "let loCalHalfwordIndex = rfPriCwLoCalIndex(channelMhz)",
        "let fcalByte = uint32(rfLoFcal(loCalHalfwordIndex))",
        "let acalByte = uint32(rfLoAcal(loCalHalfwordIndex))",
        "addr rf.fcalCtrlA0",
        "addr rf.channelFcalConfigBc",
        "let sdmDivWord = rfPriCwSdmDivWord(channelMhz)",
        "nim_wifi_rf_cw_start_sdm_div = sdmDivWord",
        "addr rf.sdmDivC4",
        "addr rf.sdmCtrlC0",
        "not 0x00001000'u32",
    ]:
        assert expected in cw_program_body
    for forbidden in [
        "let index = rfPriCwLoCalIndex(channelMhz)",
        "rfLoFcal(index)",
        "rfLoAcal(index)",
        "nim_wifi_rf_last_config_channel_index = uint32(index)",
    ]:
        assert forbidden not in cw_program_body
    for expected in [
        "rf_pri_cw_start+0xe6..0x172",
        "720'u32",
        "780'u32",
        "960'u32",
        "1152'u32",
        "1200'u32",
        "1560'u32",
    ]:
        assert expected in wifi_fw
    assert "rfPriProgramCwChannel(channelMhz)" in cw_start_body
    assert "rfPriConfigChannelForCal(rfPriCwLoCalIndex(channelMhz))" not in cw_start_body
    assert "Remaining unknown" not in cw_start_body
    assert "let signedSample = int64(sample)" in square_rf_sample_body
    assert "uint64(signedSample * signedSample)" in square_rf_sample_body
    assert "let value = int64(sample)" not in square_rf_sample_body
    for expected in [
        "let tempChannelTableIndex = rfPriTempChannelTableIndex(channelMhz)",
        "let temperatureOffsetDivisor =",
        "bl808RfTempLowOffsets,\n        tempChannelTableIndex)",
        "bl808RfTempHighOffsets,\n        tempChannelTableIndex)",
        "if temperatureOffsetDivisor == 0'i16:",
        "div temperatureOffsetDivisor.int32",
    ]:
        assert expected in temp_power_comp_body
    assert "let index = rfPriTempChannelTableIndex(channelMhz)" not in temp_power_comp_body
    assert "let offset =" not in temp_power_comp_body
    assert "div offset.int32" not in temp_power_comp_body
    for expected in [
        "var loVcoHalfwordIndex =",
        "if loVcoHalfwordIndex > 20'u32:",
        "loVcoHalfwordIndex = 20'u32",
        "halfwords[loVcoHalfwordIndex + RfCalibLoVcoHalfwordBase.uint32]",
    ]:
        assert expected in vco_cal_word_body
    assert "var index =" not in vco_cal_word_body
    assert "halfwords[index + RfCalibLoVcoHalfwordBase.uint32]" not in vco_cal_word_body
    assert "bl808WifiRfWb03ApplyMeasuredRf70Replay* {.booldefine.}: bool = false" in wifi_fw
    for expected in [
        "if bl808WifiRfWb03ApplyMeasuredRf70Replay:",
        "for rf70ReplayWindowIndex in 0 ..< 3:",
        "rf70ReplaySearchBestNibble[rf70ReplayWindowIndex] = 0'u32",
        "rf70ReplayCandidateAverageSample[rf70ReplayWindowIndex * 16 + candidate] =",
        "rfPriStoreRf70ReplayWindowNibbles(\n        window0.nibble, window1.nibble, window2.nibble)",
        "return true",
        "return false",
    ]:
        assert expected in rf70_search_commit_body
    for forbidden in [
        "for i in 0 ..< 3:",
        "rf70ReplaySearchBestNibble[i] = 0'u32",
        "rf70ReplayCandidateAverageSample[i * 16 + candidate] = 0'u32",
    ]:
        assert forbidden not in rf70_search_commit_body
    for expected in [
        "Run the recovered strongest-candidate search for UART/JTAG visibility.",
        "Applying those measured replay windows is default-off",
        "RfPriRf70ReplayFieldsMeasuredFallback",
    ]:
        assert expected in rf70_populate_body
    for expected in [
        "proc rfPriApplyTxcalLowBandRf70ReplayNibble() =",
        "rf_pri_txcal+0x534..0x54a",
        "rf_calib_data+0x0c bits 27:24",
        "addr rfRegs().txcalParam70",
        "rfPriRf70ReplayWindow0Nibble()",
        "rfPriPopulateWb03TxcalRf70ReplayFields()\n  rfPriApplyTxcalLowBandRf70ReplayNibble()\n  discard chooseRfTxcalMixerCs()",
    ]:
        assert expected in wifi_fw if expected.startswith("proc ") else expected in wifi_fw
    for expected in [
        "RfCalibRf70ReplayLowBandWordIndex",
        "RfCalibRf70ReplayHighBandWordIndex",
        "RfCalibLoVcoHalfwordBase",
        "RfCalibTxcalRecordBaseWord",
        "proc rfCalibRf70ReplayLowBandWord()",
        "proc rfCalibRf70ReplayHighBandWord()",
        "proc rfCalibHasTxcalData(): bool",
        "for txcalReplayRecordWordIndex in 0 ..< RfPriTxcalSearchRecords * 2:",
        "rfCalibWord(RfCalibTxcalRecordBaseWord + txcalReplayRecordWordIndex)",
        "let lowBandReplayWord = rfCalibRf70ReplayLowBandWord()",
        "let highBandReplayWord = rfCalibRf70ReplayHighBandWord()",
        "let lowBandReplayWordBefore = rfCalibRf70ReplayLowBandWord()",
        "let highBandReplayWordBefore = rfCalibRf70ReplayHighBandWord()",
    ]:
        assert expected in wifi_fw
    rf_calib_has_txcal_body = wifi_fw.split(
        "proc rfCalibHasTxcalData(): bool =", 1
    )[1].split("proc saveRfPriCalState", 1)[0]
    for forbidden in [
        "for i in 0 ..< RfPriTxcalSearchRecords * 2:",
        "RfCalibTxcalRecordBaseWord + i",
    ]:
        assert forbidden not in rf_calib_has_txcal_body
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
    lo_calib_accessors = wifi_fw.split(
        "proc rfLoFcal(loChannelIndex: int)",
        1,
    )[1].split("proc rfCalibHasRestoreData()", 1)[0]
    rf_calib_has_restore_body = wifi_fw.split(
        "proc rfCalibHasRestoreData(): bool =",
        1,
    )[1].split("proc rfCalibHasTxcalData", 1)[0]
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
    assert "proc rfLoFcal(loChannelIndex: int)" in wifi_fw
    for expected in [
        "proc rfLoAcal(loChannelIndex: int)",
        "proc setRfLoAcal(loChannelIndex: int, acal: uint16)",
        "RfCalibLoVcoHalfwordBase + loChannelIndex",
        "let loCalibrationHalfwordIndex = RfCalibLoVcoHalfwordBase + loChannelIndex",
        "let packedLoCalibrationHalfword =",
        "rfCalibSetHalf(loCalibrationHalfwordIndex, packedLoCalibrationHalfword)",
    ]:
        assert expected in lo_calib_accessors
    for forbidden in [
        "proc rfLoFcal(index: int)",
        "proc rfLoAcal(index: int)",
        "proc setRfLoFcal(index: int",
        "proc setRfLoAcal(index: int",
        "let halfIndex = RfCalibLoVcoHalfwordBase + index",
        "rfCalibSetHalf(halfIndex, packedLoCalibrationHalfword)",
    ]:
        assert forbidden not in lo_calib_accessors
    for expected in [
        "for restoreDataWordIndex in [2, 3, 18, 19, 20, 21, 22, 23, 24, 25]:",
        "rfCalibWord(restoreDataWordIndex)",
    ]:
        assert expected in rf_calib_has_restore_body
    assert "for index in [2, 3, 18, 19, 20, 21, 22, 23, 24, 25]:" not in rf_calib_has_restore_body
    for expected in [
        "for loChannelCalIndex in 0 ..< RfLoChannelCount:",
        "var channelCountCrossingIndex = 0",
        "measured[channelCountCrossingIndex] < RfChannelCntTable40M[loChannelCalIndex]",
        "elif channelCountCrossingIndex == 0:",
        "elif channelCountCrossingIndex >= measuredLen:",
        "fcal = int(baseCode) + 1 - channelCountCrossingIndex",
        "setRfLoFcal(loChannelCalIndex, uint16(fcal))",
    ]:
        assert expected in run_lo_fcal_body
    for forbidden in [
        "for i in 0 ..< RfLoChannelCount:",
        "RfChannelCntTable40M[i]",
        "setRfLoFcal(i, uint16(fcal))",
    ]:
        assert forbidden not in run_lo_fcal_body
    assert "let value =" not in lo_calib_accessors
    assert "var offset = 0" not in run_lo_fcal_body
    prepare_lo_acal_body = wifi_fw.split(
        "proc prepareRfPriLoAcal() =",
        1,
    )[1].split("proc runRfPriLoAcal()", 1)[0]
    run_lo_acal_body = wifi_fw.split(
        "proc runRfPriLoAcal() =",
        1,
    )[1].split("proc saveRfPriCalState()", 1)[0]
    for expected in [
        "for loChannelCalIndex in 0 ..< RfLoChannelCount:",
        "uint32(rfLoFcal(loChannelCalIndex))",
        "RfChannelDivTable40M[loChannelCalIndex]",
        "vendorLikeRfAcalForFcal(rfLoFcal(loChannelCalIndex))",
        "setRfLoAcal(loChannelCalIndex, acal and 0x001F'u16)",
    ]:
        assert expected in run_lo_acal_body
    for forbidden in [
        "for i in 0 ..< RfLoChannelCount:",
        "rfLoFcal(i)",
        "RfChannelDivTable40M[i]",
        "setRfLoAcal(i, acal",
    ]:
        assert forbidden not in run_lo_acal_body
    config_channel_cal_body = wifi_fw.split(
        "proc rfPriConfigChannelForCal(loChannelIndex: int) =",
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
        "proc storeRfTxcalRecord(txcalRecordIndex: int;",
        1,
    )[1].split("proc storeRfPriBzTxcalRecord", 1)[0]
    store_bz_txcal_record_body = wifi_fw.split(
        "proc storeRfPriBzTxcalRecord(bzTxcalRecordIndex: int;",
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
    )[1].split("proc rfPriTxcalReplayRecordsComplete()", 1)[0]
    txcal_replay_complete_body = wifi_fw.split(
        "proc rfPriTxcalReplayRecordsComplete(): bool =",
        1,
    )[1].split("proc rfPriBzTxcalReplayRecordsComplete()", 1)[0]
    bz_txcal_replay_complete_body = wifi_fw.split(
        "proc rfPriBzTxcalReplayRecordsComplete(): bool =",
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
    rf_pri_roscal_body = wifi_fw.split(
        "proc rf_pri_roscal() {.exportc, cdecl.} =",
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
    log_roscal_search_body = wifi_fw.split(
        "proc logRfRoscalSearch(roscalSearchLogSlotIndex: var int,",
        1,
    )[1].split("proc chooseRfRoscalCode", 1)[0]
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
    log_rccal_search_body = wifi_fw.split(
        "proc logRfRccalSearch(rccalSearchLogSlotIndex: var int,",
        1,
    )[1].split("proc chooseRfRccalCode", 1)[0]
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
    choose_rccal_body = wifi_fw.split(
        "proc chooseRfRccalCode(): tuple[ok: bool, code: uint32] =",
        1,
    )[1].split("proc runRfPriRccal() =", 1)[0]
    run_rccal_body = wifi_fw.split(
        "proc runRfPriRccal() =",
        1,
    )[1].split("proc clampRfTxcalParam", 1)[0]
    rf_pri_rccal_body = wifi_fw.split(
        "proc rf_pri_rccal() {.exportc, cdecl.} =",
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
        "proc configureRfPriTxcalGain(txcalPowerSetup: array[9, uint16],",
        1,
    )[1].split("proc configureRfPriTxcalGain(txcalPowerSetupIndex: int", 1)[0]
    txcal_gain_wrapper_body = wifi_fw.split(
        "proc configureRfPriTxcalGain(txcalPowerSetupIndex: int",
        1,
    )[1].split("proc prepareRfPriTxcal()", 1)[0]
    txcal_power_body = wifi_fw.split(
        "proc sampleRfTxcalPower(measFreq: uint32):",
        1,
    )[1].split("proc measureRfTxcalCandidate", 1)[0]
    txcal_candidate_body = wifi_fw.split(
        "proc measureRfTxcalCandidate(paramInd: uint32, candidate: int32,",
        1,
    )[1].split("proc searchRfTxcalParam", 1)[0]
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
        "proc storeRfRxcalRecord(rxcalRecordIndex: int, rxcalParam2, rxcalParam3: int32",
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
    rf_pri_lo_fcal_body = wifi_fw.split(
        "proc rf_pri_lo_fcal() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_lo_acal", 1)[0]
    rf_pri_lo_acal_body = wifi_fw.split(
        "proc rf_pri_lo_acal() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_txcal", 1)[0]
    rf_pri_txcal_body = wifi_fw.split(
        "proc rf_pri_txcal() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_bz_txcal", 1)[0]
    rf_pri_bz_txcal_body = wifi_fw.split(
        "proc rf_pri_bz_txcal() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_rxcal", 1)[0]
    rf_pri_rxcal_body = wifi_fw.split(
        "proc rf_pri_rxcal() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_full_cal", 1)[0]
    rf_pri_full_cal_body = wifi_fw.split(
        "proc rf_pri_full_cal() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_restore_cal_reg", 1)[0]
    rf_pri_restore_cal_reg_body = wifi_fw.split(
        "proc rf_pri_restore_cal_reg() {.exportc, cdecl.} =",
        1,
    )[1].split("proc rf_pri_init", 1)[0]
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
    square_rf_sample_body = wifi_fw.split(
        "proc squareRfSample(sample: int32): uint64",
        1,
    )[1].split("proc saturatingRfUint32", 1)[0]
    temp_power_comp_body = wifi_fw.split(
        "proc rfPriComputeTemperaturePowerCompForMhz(channelMhz: uint16;",
        1,
    )[1].split("proc rf_pri_set_channel_total_pwr_comp", 1)[0]

    for expected in [
        "RfCalibBzTxcalRecordBaseByte",
        "RfCalibBzTxcalRecordStrideBytes",
        "proc rfCalibBzTxcalRecordByteOffset(bzTxcalRecordIndex: int)",
        "proc rfCalibBzTxcalRecordWord0(bzTxcalRecordIndex: int)",
        "proc rfCalibBzTxcalRecordWord1(bzTxcalRecordIndex: int)",
        "proc rfCalibStoreBzTxcalRecordWords(bzTxcalRecordIndex: int;",
        "bzTxcalPackedWord0,",
        "bzTxcalPackedWord1: uint32",
        "let bzTxcalRecordByteOffset =\n    rfCalibBzTxcalRecordByteOffset(bzTxcalRecordIndex)",
        "rfCalibByte(bzTxcalRecordByteOffset)",
        "rfCalibSetByte(bzTxcalRecordByteOffset",
        "bzTxcalPackedWord0",
        "bzTxcalPackedWord1",
        "for bzTxcalSnapshotRecordIndex in 0 ..< 9:",
        "rfCalibBzTxcalRecordWord0(bzTxcalSnapshotRecordIndex)",
        "rfCalibBzTxcalRecordWord1(bzTxcalSnapshotRecordIndex)",
    ]:
        assert expected in wifi_fw
    for forbidden in [
        "proc rfCalibBzTxcalRecordByteOffset(record: int)",
        "proc rfCalibBzTxcalRecordWord0(record: int)",
        "proc rfCalibBzTxcalRecordWord1(record: int)",
        "proc rfCalibStoreBzTxcalRecordWords(record: int; word0, word1: uint32)",
        "let bzTxcalRecordByteOffset = rfCalibBzTxcalRecordByteOffset(record)",
        "rfCalibBzTxcalRecordWord0(record)",
        "rfCalibBzTxcalRecordWord1(record)",
        "for record in 0 ..< 9:",
        "nim_wifi_rf_bz_txcal_word0_log[record]",
        "let offset = rfCalibBzTxcalRecordByteOffset(record)",
        "rfCalibByte(offset)",
        "rfCalibSetByte(offset,",
        "rfCalibSetByte(offset +",
    ]:
        assert forbidden not in wifi_fw
    for expected in [
        "let txcalRecordBaseWordIndex = txcalRecordIndex * 2",
        "RfCalibTxcalRecordBaseWord + txcalRecordBaseWordIndex",
        "wifiRfTxcalRecordWord0Log[txcalRecordIndex]",
        "nim_wifi_rf_txcal_power_log[txcalRecordIndex]",
        "rfCalibStoreBzTxcalRecordWords(\n    bzTxcalRecordIndex,",
        "nim_wifi_rf_bz_txcal_word0_log[bzTxcalRecordIndex]",
        "txcalParam0, txcalParam1: int32",
        "packRfTxcalCalWord0(txcalParam0, txcalParam1, txcalParam2)",
        "packRfTxcalCalWord1(txcalParam3)",
        "txcalRecordWord0",
        "txcalRecordWord1",
        "bzTxcalRecordWord0",
        "bzTxcalRecordWord1",
    ]:
        assert expected in store_txcal_record_body + store_bz_txcal_record_body
    for forbidden in [
        "proc storeRfTxcalRecord(index: int;",
        "proc storeRfPriBzTxcalRecord(index: int;",
        "let txcalRecordBase = index * 2",
        "wifiRfTxcalRecordWord0Log[index]",
        "nim_wifi_rf_bz_txcal_word0_log[index]",
    ]:
        assert forbidden not in store_txcal_record_body + store_bz_txcal_record_body
    for expected in [
        "for txcalSearchRecordIndex in 0 ..< RfPriTxcalSearchRecords:",
        "configureRfPriTxcalGain(txcalSearchRecordIndex,",
        "RfPriTxcalParams[txcalSearchRecordIndex]",
        "nim_wifi_rf_txcal_amp_log[txcalSearchRecordIndex] = amp",
        "storeRfTxcalRecord(\n      txcalSearchRecordIndex,",
    ]:
        assert expected in run_txcal_body
    for forbidden in [
        "for i in 0 ..< RfPriTxcalSearchRecords:",
        "configureRfPriTxcalGain(i, RfPriTxcalParams[i])",
        "nim_wifi_rf_txcal_amp_log[i] = amp",
        "storeRfTxcalRecord(\n      i,",
    ]:
        assert forbidden not in run_txcal_body
    for expected in [
        "for bzTxcalSearchRecordIndex in 0 ..< RfPriBzTxcalSearchRecords:",
        "RfPriBzTxcalPowerSetup[bzTxcalSearchRecordIndex]",
        "RfPriBzTxcalParams[bzTxcalSearchRecordIndex]",
        "nim_wifi_rf_bz_txcal_ok_mask_log[bzTxcalSearchRecordIndex] = okMask",
        "nim_wifi_rf_bz_txcal_power_log[bzTxcalSearchRecordIndex] =",
        "storeRfPriBzTxcalRecord(\n        bzTxcalSearchRecordIndex,",
        "storeRfPriBzTxcalRecord(bzTxcalSearchRecordIndex,",
    ]:
        assert expected in run_bz_txcal_body
    for forbidden in [
        "for i in 0 ..< RfPriBzTxcalSearchRecords:",
        "RfPriBzTxcalPowerSetup[i]",
        "RfPriBzTxcalParams[i]",
        "nim_wifi_rf_bz_txcal_ok_mask_log[i]",
        "nim_wifi_rf_bz_txcal_power_log[i]",
        "storeRfPriBzTxcalRecord(\n        i,",
        "storeRfPriBzTxcalRecord(i,",
    ]:
        assert forbidden not in run_bz_txcal_body
    for expected in [
        "for rxcalReplayRecordIndex in 0 ..< 4:",
        "storeRfRxcalRecord(\n      rxcalReplayRecordIndex,",
    ]:
        assert expected in run_rxcal_body
    for forbidden in [
        "for i in 0 ..< 4:",
        "storeRfRxcalRecord(\n      i,",
    ]:
        assert forbidden not in run_rxcal_body
    for expected in [
        "Vendor rf_pri_txcal_w2reg always writes these fields",
        "preserves base-table words for empty records until TXCAL is bit-for-bit",
        "txPowerTableWordIndex,",
        "txcalRecordIndex: int",
        "RfCalibTxcalRecordBaseWord + txcalRecordIndex * 2",
        "let txcalParam0 = txcalRecordWord0 and 0x3F'u32",
        "let txcalParam1 = (txcalRecordWord0 shr 8) and 0x3F'u32",
        "let txcalParam2 = (txcalRecordWord0 shr 16) and 0x7FF'u32",
        "let txcalParam3 = txcalRecordWord1 and 0x3FF'u32",
        "if txcalRecordWord0 == 0'u32 and txcalRecordWord1 == 0'u32:",
        "txPowerTableWords[txPowerTableWordIndex]",
    ]:
        assert expected in apply_txcal_record_body
    for forbidden in [
        "tableIndex, record: int",
        "RfCalibTxcalRecordBaseWord + record * 2",
        "txPowerTableWords[tableIndex]",
    ]:
        assert forbidden not in apply_txcal_record_body
    for expected in [
        "Vendor rf_pri_bz_txcal_w2reg always writes these fields",
        "preserves base-table words for empty records until BZ TXCAL is validated",
        "txPowerTableStartWordIndex,",
        "bzTxcalRecordIndex: int",
        "let bzTxcalRecordWord0 = rfCalibBzTxcalRecordWord0(bzTxcalRecordIndex)",
        "let bzTxcalRecordWord1 = rfCalibBzTxcalRecordWord1(bzTxcalRecordIndex)",
        "let txcalParam0 = bzTxcalRecordWord0 and 0x3F'u32",
        "let txcalParam1 = (bzTxcalRecordWord0 shr 8) and 0x3F'u32",
        "let txcalParam2 = (bzTxcalRecordWord0 shr 16) and 0x07FF'u32",
        "let txcalParam3 = bzTxcalRecordWord1 and 0x03FF'u32",
        "if (txcalParam0 or txcalParam1 or txcalParam2 or txcalParam3) == 0'u32:",
        "txPowerTableWords[txPowerTableStartWordIndex]",
    ]:
        assert expected in apply_bz_txcal_record_body
    for forbidden in [
        "start, record: int",
        "rfCalibBzTxcalRecordWord0(record)",
        "rfCalibBzTxcalRecordWord1(record)",
        "txPowerTableWords[start]",
    ]:
        assert forbidden not in apply_bz_txcal_record_body
    for expected in [
        "for bzTxcalFallbackRecordIndex in 0 ..< 9:",
        "let bzTxcalRecordWord0 =\n      rfCalibBzTxcalRecordWord0(bzTxcalFallbackRecordIndex)",
        "let bzTxcalRecordWord1 =\n      rfCalibBzTxcalRecordWord1(bzTxcalFallbackRecordIndex)",
        "rfCalibStoreBzTxcalRecordWords(",
        "bzTxcalFallbackRecordIndex,",
        "packRfTxcalCalWord0(0x20'i32, 0x20'i32, 0x400'i32)",
    ]:
        assert expected in seed_bz_txcal_body
    for forbidden in [
        "for record in 0 ..< 9:",
        "rfCalibBzTxcalRecordWord0(record)",
        "rfCalibStoreBzTxcalRecordWords(\n        record,",
    ]:
        assert forbidden not in seed_bz_txcal_body
    for expected in [
        "bl808WifiRfWb03ReplayCompleteTxPowerCal* {.booldefine.}: bool = false",
        "RfPriTxPowerReplayBaseOnly = 0x00000000'u32",
        "RfPriTxPowerReplayCalRecords = 0x00000001'u32",
        "RfPriTxPowerReplayWb03RestoreBaseline = 0x00000002'u32",
        "RfPriTxPowerReplayWb03CompleteRecords = 0x00000003'u32",
        "RfPriTxPowerSkipWb03TxcalIncomplete = 0x00000002'u32",
        "RfPriTxPowerSkipWb03BzTxcalIncomplete = 0x00000003'u32",
        "RfPriTxPowerSkipWb03OptInDisabled = 0x00000004'u32",
        "var nim_wifi_rf_tx_power_replay_mode* {.exportc.}: uint32",
        "var nim_wifi_rf_tx_power_replay_skip_reason* {.exportc.}: uint32",
        "var nim_wifi_rf_tx_power_txcal_complete* {.exportc.}: uint32",
        "var nim_wifi_rf_tx_power_bz_txcal_complete* {.exportc.}: uint32",
        "librf_bl808.a:rf_pri.c.o .data.tx_pwr_table_idx",
        "0000 0100 0200 0300 0400 0500 0600 0900 0a00 0b00 0c00 0d00 0e00",
        "librf_bl808.a:rf_pri.c.o .data.bz_tx_pwr_table_idx",
        "0100 0200 0300 0600",
    ]:
        assert expected in wifi_fw
    for expected in [
        "rf_calib_data+0x68",
        "indexed by .data.tx_pwr_table_idx",
        "for txcalReplayRecordIndex in RfPriTxcalReplayRecordIds:",
        "let txcalRecordWord0 =",
        "let txcalRecordWord1 =",
        "RfCalibTxcalRecordBaseWord + txcalReplayRecordIndex * 2",
        "if (txcalRecordWord0 or txcalRecordWord1) == 0'u32:",
        "return false",
        "true",
    ]:
        assert expected in txcal_replay_complete_body
    assert "for record in RfPriTxcalReplayRecordIds:" not in txcal_replay_complete_body
    for expected in [
        "rf_calib_data+0xf8",
        "indexed by .data.bz_tx_pwr_table_idx",
        "for bzTxcalReplayRecordIndex in bl808RfBzTargetPowerRecords:",
        "let bzTxcalRecordWord0 =\n      rfCalibBzTxcalRecordWord0(bzTxcalReplayRecordIndex)",
        "let bzTxcalRecordWord1 =\n      rfCalibBzTxcalRecordWord1(bzTxcalReplayRecordIndex)",
        "let txcalParam0 = bzTxcalRecordWord0 and 0x3F'u32",
        "let txcalParam1 = (bzTxcalRecordWord0 shr 8) and 0x3F'u32",
        "let txcalParam2 = (bzTxcalRecordWord0 shr 16) and 0x07FF'u32",
        "let txcalParam3 = bzTxcalRecordWord1 and 0x03FF'u32",
        "return false",
        "true",
    ]:
        assert expected in bz_txcal_replay_complete_body
    assert "for record in bl808RfBzTargetPowerRecords:" not in bz_txcal_replay_complete_body
    for expected in [
        "let wb03Xtal40 = rfPriIsWb03() and",
        "bl808RfXtalIndex == xtalIndex(WlXtal40M)",
        "let txcalRecordsComplete = rfPriTxcalReplayRecordsComplete()",
        "let bzTxcalRecordsComplete = rfPriBzTxcalReplayRecordsComplete()",
        "nim_wifi_rf_tx_power_txcal_complete",
        "nim_wifi_rf_tx_power_bz_txcal_complete",
        "let wb03CompleteCalReplayAllowed = wb03Xtal40 and",
        "bl808WifiRfWb03ReplayCompleteTxPowerCal and",
        "let useCalReplay = rfCalibDataGlobal != nil and",
        "let useWb03RestoreBaseline = wb03Xtal40 and",
        "if useWb03RestoreBaseline:",
        "nim_wifi_rf_tx_power_replay_mode =",
        "RfPriTxPowerReplayWb03RestoreBaseline",
        "RfPriTxPowerSkipWb03TxcalIncomplete",
        "RfPriTxPowerSkipWb03BzTxcalIncomplete",
        "RfPriTxPowerSkipWb03OptInDisabled",
        "RfPriTxPowerReplayWb03CompleteRecords",
        "RfPriTxPowerReplayCalRecords",
        "RfPriWb03TxPowerRegisterBaseline",
        "RfPriTxPowerRegisterBase",
        "if useCalReplay:",
        "var txPowerTableWords =",
        "for txPowerReplaySlotIndex, txcalRecordId in RfPriTxcalReplayRecordIds:",
        "rfPriApplyTxcalRecordToTable(\n        txPowerTableWords, 3 + txPowerReplaySlotIndex * 2, txcalRecordId)",
        "rfPriApplyBzTxcalRecordToTable(txPowerTableWords,",
        "writeRfTxPowerCompTable(txPowerTableWords)",
        "for bzTxcalTargetPowerSlotIndex in 0 ..< bl808RfBzTargetPowerRecords.len:",
        "RfPriBzTxcalTableStarts[bzTxcalTargetPowerSlotIndex]",
        "bl808RfBzTargetPowerRecords[bzTxcalTargetPowerSlotIndex]",
        "for txPowerIndexSlot in 7 ..< bl808RfTxPowerTableIndex.len:",
        "bl808RfTxPowerTableIndex[txPowerIndexSlot].int32",
        "bl808RfTxPowerTableIndex[txPowerIndexSlot] = shifted.int16",
    ]:
        assert expected in write_tx_power_table_body
    assert "for idx in 7 ..< bl808RfTxPowerTableIndex.len:" not in write_tx_power_table_body
    assert "bl808RfTxPowerTableIndex[idx]" not in write_tx_power_table_body
    assert "for slot, record in RfPriTxcalReplayRecordIds:" not in write_tx_power_table_body
    assert "for i in 0 ..< bl808RfBzTargetPowerRecords.len:" not in write_tx_power_table_body
    assert "bl808RfBzTargetPowerRecords[i]" not in write_tx_power_table_body
    for expected in [
        "for packedFieldIndex, value in values:",
        "shl (packedFieldIndex * 6)",
    ]:
        assert expected in pack_five_fields_body
    for forbidden in [
        "for i, value in values:",
        "shl (i * 6)",
    ]:
        assert forbidden not in pack_five_fields_body
    for expected in [
        "for bzChannelPowerCompIndex, rawComp in bl808RfBzChannelPowerComp:",
        "tempAdjusted[bzChannelPowerCompIndex] =",
        "txAdjusted[bzChannelPowerCompIndex] =",
    ]:
        assert expected in set_bz_channel_power_comp_body
    for forbidden in [
        "for i, rawComp in bl808RfBzChannelPowerComp:",
        "tempAdjusted[i]",
        "txAdjusted[i]",
    ]:
        assert forbidden not in set_bz_channel_power_comp_body
    for expected in [
        "for bzTempCompDeltaIndex in 0 ..< deltas.len:",
        "deltas[bzTempCompDeltaIndex] =",
        "bl808RfBzTempPowerComp[bzTempCompDeltaIndex]",
        "bl808RfBzAppliedTempComp[bzTempCompDeltaIndex]",
    ]:
        assert expected in write_bz_temp_comp_deltas_body
    for forbidden in [
        "for i in 0 ..< deltas.len:",
        "deltas[i]",
        "bl808RfBzTempPowerComp[i]",
        "bl808RfBzAppliedTempComp[i]",
    ]:
        assert forbidden not in write_bz_temp_comp_deltas_body
    for expected in [
        "for bzTempCompChannelIndex, channelMhz in BzTempCompChannelsMhz:",
        "bl808RfBzTempPowerComp[bzTempCompChannelIndex] =",
    ]:
        assert expected in set_bz_temp_comp_body
    for forbidden in [
        "for i, channelMhz in BzTempCompChannelsMhz:",
        "bl808RfBzTempPowerComp[i]",
    ]:
        assert forbidden not in set_bz_temp_comp_body
    for expected in [
        "for channelPowerCompIndex in 0 ..< 14:",
        "cfg.channelPowerComp[channelPowerCompIndex]",
        "cfg.channelLowPowerComp[channelPowerCompIndex]",
    ]:
        assert expected in set_channel_power_comp_body
    for forbidden in [
        "for i in 0 ..< 14:",
        "cfg.channelPowerComp[i]",
        "cfg.channelLowPowerComp[i]",
    ]:
        assert forbidden not in set_channel_power_comp_body
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
    for body, expected in [
        (rf_pri_lo_fcal_body, "runRfPriLoFcal()"),
        (rf_pri_lo_acal_body, "runRfPriLoAcal()"),
        (rf_pri_txcal_body, "runRfPriTxcal()"),
        (rf_pri_bz_txcal_body, "runRfPriBzTxcal()"),
        (rf_pri_rxcal_body, "runRfPriRxcal()"),
        (rf_pri_full_cal_body, "runRfPriFullCalRestoreBaseline()"),
        (rf_pri_restore_cal_reg_body, "replayRfPriCalRegisters()"),
    ]:
        assert "Public ABI wrapper for librf_bl808.a:rf_pri.c.o" in body
        assert expected in body
        assert "discard" not in body
        assert "regWrite(" not in body
        assert "rfRegWrite(" not in body
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
        "nimFwDbgRfPhyTraceRf70[rfPhyTraceSlot]",
        "nimFwDbgRfPhyTraceRf88[rfPhyTraceSlot]",
        "nimFwDbgRfPhyTraceRfd0[rfPhyTraceSlot]",
        "nimFwDbgRfPhyTraceDevice[rfPhyTraceSlot]",
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
        "addr pll.fractionalDividerWord28",
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
    assert "proc rfPriConfigChannelForCal(loChannelIndex: int)" in wifi_fw
    for expected in [
        "nim_wifi_rf_last_config_channel_index = uint32(loChannelIndex)",
        "let fcalByte = uint32(rfLoFcal(loChannelIndex))",
        "let acalByte = uint32(rfLoAcal(loChannelIndex))",
        "RfChannelDivTable40M[loChannelIndex]",
        "addr rf.fcalCtrlA0",
        "addr rf.channelFcalConfigBc",
        "addr rf.txcalCtrlB8",
        "addr rf.channelCalStrobeB0",
        "addr rf.channelCalStatusB4",
    ]:
        assert expected in config_channel_cal_body
    for forbidden in [
        "proc rfPriConfigChannelForCal(index: int)",
        "rfLoFcal(index)",
        "rfLoAcal(index)",
        "RfChannelDivTable40M[index]",
        "nim_wifi_rf_last_config_channel_index = uint32(index)",
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
    assert (
        wb03_auth_tx_latches_body.count(
            "volatileStore(addr rf.txcalDfe88, RfPriWb03ScanRf88Seed)"
        ) >= 2
    )
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
        "let wb03RccalReplayCode = RfPriWb03RccalRf80Seed and RfRccalCodeMask",
        "wb03RccalReplayCode or (wb03RccalReplayCode shl 6)",
        "(wb03RccalReplayCode shl 12) or (wb03RccalReplayCode shl 18)",
    ]:
        assert expected in wb03_rccal_seed_body
    assert "let value = RfPriWb03RccalRf80Seed" not in wb03_rccal_seed_body
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
    assert "runRfPriRoscal()" in rf_pri_roscal_body
    assert "addr rf.capability20" not in rf_pri_roscal_body
    for forbidden in ["RfCapabilityReg", "RfCalModeReg"]:
        assert forbidden not in run_roscal_body
    for expected in [
        "roscalSearchLogSlotIndex < nim_wifi_rf_roscal_search_log.len",
        "nim_wifi_rf_roscal_search_log[roscalSearchLogSlotIndex]",
        "inc roscalSearchLogSlotIndex",
    ]:
        assert expected in log_roscal_search_body
    for forbidden in [
        "proc logRfRoscalSearch(index: var int",
        "if index < nim_wifi_rf_roscal_search_log.len:",
        "nim_wifi_rf_roscal_search_log[index]",
        "inc index",
    ]:
        assert forbidden not in log_roscal_search_body
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
    for expected in [
        "let maskedRoscalCode = code and RfRoscalCodeMask",
        "maskedRoscalCode shl 8",
        "not RfRoscalQRegMask, maskedRoscalCode",
    ]:
        assert expected in write_roscal_candidate_body
    assert "let value =" not in write_roscal_candidate_body

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
        assert "let value =" not in body
    for expected in [
        "let maskedRccalCode = code and RfRccalCodeMask",
        "let packedRccalLaneWord = maskedRccalCode or",
        "RfRccalRegisterKeepMask) or packedRccalLaneWord",
        "maskedRccalCode or (maskedRccalCode shl 6)",
    ]:
        assert expected in write_rccal_body
    assert "let packed =" not in write_rccal_body
    for expected in [
        "let maskedRccalSearchCode = code and RfRccalCodeMask",
        "maskedRccalSearchCode shl 24",
        "maskedRccalSearchCode shl 8",
    ]:
        assert expected in write_rccal_search_body
    for expected in [
        "let rf = rfRegs()",
        "addr rf.capability20",
        "addr rf.calMode14",
        "RfRccalCapabilityMask",
        "RfRccalModeMask",
        "RfRccalFailMode",
    ]:
        assert expected in run_rccal_body
    assert "runRfPriRccal()" in rf_pri_rccal_body
    assert "addr rf.capability20" not in rf_pri_rccal_body
    for forbidden in ["RfCapabilityReg", "RfCalModeReg"]:
        assert forbidden not in run_rccal_body
    for expected in [
        "rccalSearchLogSlotIndex < nim_wifi_rf_rccal_search_log.len",
        "nim_wifi_rf_rccal_search_log[rccalSearchLogSlotIndex]",
        "nim_wifi_rf_rccal_power_log[rccalSearchLogSlotIndex] = power",
        "inc rccalSearchLogSlotIndex",
    ]:
        assert expected in log_rccal_search_body
    for forbidden in [
        "proc logRfRccalSearch(index: var int",
        "if index < nim_wifi_rf_rccal_search_log.len:",
        "nim_wifi_rf_rccal_search_log[index]",
        "nim_wifi_rf_rccal_power_log[index]",
        "inc index",
    ]:
        assert forbidden not in log_rccal_search_body
    for expected in [
        "for rccalSearchLogSlotIndex in 0 ..< nim_wifi_rf_rccal_search_log.len:",
        "nim_wifi_rf_rccal_search_log[rccalSearchLogSlotIndex] = 0",
        "nim_wifi_rf_rccal_power_log[rccalSearchLogSlotIndex] = 0",
    ]:
        assert expected in choose_rccal_body
    for forbidden in [
        "for i in 0 ..< nim_wifi_rf_rccal_search_log.len:",
        "nim_wifi_rf_rccal_search_log[i] = 0",
        "nim_wifi_rf_rccal_power_log[i] = 0",
    ]:
        assert forbidden not in choose_rccal_body
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
    for expected in [
        "let txcalSampleTraceSlot =",
        "nim_wifi_rf_txcal_sample_param_log[txcalSampleTraceSlot] = paramInd",
        "nim_wifi_rf_txcal_sample_power_log[txcalSampleTraceSlot] = sample.power",
    ]:
        assert expected in txcal_candidate_body
    for forbidden in [
        "let idx = int(nim_wifi_rf_txcal_sample_count",
        "nim_wifi_rf_txcal_sample_param_log[idx]",
        "nim_wifi_rf_txcal_sample_power_log[idx]",
    ]:
        assert forbidden not in txcal_candidate_body
    for body in [prime_rccal_measure_body, txcal_average_body, txcal_adc_mean_body]:
        assert "addr rf.measureMode61c" in body
        assert "rfRegWrite(RfMeasureModeReg" not in body
    for body in [txcal_average_body, txcal_adc_mean_body]:
        assert "addr rf.measureI620" in body
    for expected in [
        "addr rf.calSingenAmpLo214",
        "addr rf.calSingenAmpHi218",
        "addr rf.calSingenCtrl20c",
        "let maskedTxcalSingenAmplitude = amp and RfTxcalSingenAmplitudeMask",
        "maskedTxcalSingenAmplitude",
    ]:
        assert expected in txcal_singen_amp_body
    assert "let value =" not in txcal_singen_amp_body
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
        "txcalGainParams: array[7, uint32]",
        "let rf = rfRegs()",
        "txcalGainParams[3] and 0x03'u32",
        "((txcalGainParams[0] and 0x3F'u32) shl 28)",
        "((txcalGainParams[2] and 0x3F'u32) shl 18)",
        "(txcalGainParams[1] and 0x07'u32) shl 16",
        "((uint32(txcalPowerSetup[0]) and 0x03'u32) shl 28)",
        "((uint32(txcalPowerSetup[3]) and 0x1F'u32) shl 20)",
        "((txcalGainParams[5] and 0x07'u32) shl 16)",
        "(txcalGainParams[6] and 0x07'u32) shl 29",
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
        "proc configureRfPriTxcalGain(setup: array[9, uint16],",
        "param: array[7, uint32]",
        "param[3] and 0x03'u32",
        "uint32(setup[0])",
        "uint32(setup[3])",
    ]:
        assert forbidden not in txcal_gain_body
    for expected in [
        "RfPriTxcalPowerSetup[txcalPowerSetupIndex]",
        "txcalGainParams: array[7, uint32]",
        "configureRfPriTxcalGain(RfPriTxcalPowerSetup[txcalPowerSetupIndex],",
        "txcalGainParams)",
    ]:
        assert expected in txcal_gain_wrapper_body
    for forbidden in [
        "proc configureRfPriTxcalGain(index: int",
        "RfPriTxcalPowerSetup[index]",
        "param: array[7, uint32]",
    ]:
        assert forbidden not in txcal_gain_wrapper_body

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
    assert "addr rf.rxcalReplay[rxcalRecordIndex]" in store_rxcal_record_body
    for expected in [
        "let rxcalParam2ReplayWord = packRfRxcalWord0(rxcalParam2)",
        "let rxcalParam3ReplayWord = packRfRxcalWord1(rxcalParam3)",
        "let rxcalRecordBaseWord = 18 + rxcalRecordIndex * 2",
        "rxcalParam2ReplayWord or rxcalParam3ReplayWord",
        "wifiRfRxcalRecordWord0Log[rxcalRecordIndex]",
        "nim_wifi_rf_rxcal_power_log[rxcalRecordIndex]",
    ]:
        assert expected in store_rxcal_record_body
    for vague_name in [
        "proc storeRfRxcalRecord(index: int,",
        "addr rf.rxcalReplay[index]",
        "let rxcalRecordBaseWord = 18 + index * 2",
        "wifiRfRxcalRecordWord0Log[index]",
        "nim_wifi_rf_rxcal_power_log[index]",
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
        "let rfPhyTraceSlot =",
        "nimFwDbgRfPhyTraceRf70[rfPhyTraceSlot]",
        "nimFwDbgRfPhyTraceRf88[rfPhyTraceSlot]",
        "nimFwDbgRfPhyTraceRfd0[rfPhyTraceSlot]",
        "nimFwDbgRfPhyTraceDevice[rfPhyTraceSlot]",
    ]:
        assert expected in rf_trace_body
    for forbidden in [
        "phyEnvWord(36'u)",
        "phyEnvHalf(38'u)",
        "phyEnvHalf(40'u)",
        "let idx = int(nimFwDbgRfPhyTraceCount",
        "nimFwDbgRfPhyTraceRf70[idx]",
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
    wifi_fw = wifi_fw_policy_source()
    wifi_tx = nim_source_with_includes(ROOT / "src/bl808/wifi/tx.nim")
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

    sta_lookup_body = (
        ROOT / "src/bl808/wifi/tx/queue_parts/station_lookup.nim"
    ).read_text()
    tx_flush = wifi_tx.split("proc bl_tx_try_flush*", 1)[1].split(
        "proc bl_output*", 1
    )[0]
    for expected in [
        "for remoteStaIndex in 0 ..< NxRemoteStaStoreMax:",
        "if remoteStaIndex == bcmcStaIdx:",
        "let sta = staView(staAt(remoteStaIndex))",
        "nimFwDbgTxStaLookupResult = remoteStaIndex.uint32",
        "return remoteStaIndex",
    ]:
        assert expected in sta_lookup_body
    for forbidden in [
        "for i in 0 ..< NxRemoteStaStoreMax:",
        "if i == bcmcStaIdx:",
        "staAt(i)",
        "nimFwDbgTxStaLookupResult = i.uint32",
        "return i",
    ]:
        assert forbidden not in sta_lookup_body
        assert forbidden not in tx_flush
    for expected in [
        "for remoteStaIndex in 0 ..< NxRemoteStaStoreMax:",
        "let sta = staAt(remoteStaIndex)",
        "if (staTrigger and bitSta(remoteStaIndex)) == 0'u32",
    ]:
        assert expected in tx_flush

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
    tx_ccmp_header = wifi_fw.rsplit("proc writeTxCcmpHeader", 1)[1].split(
        "proc txSecControlTemplate", 1
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
        "CcmpSecurityHeaderView {.packed.} = object",
        "ccmpReservedZero*: uint8",
        "doAssert offsetof(CcmpSecurityHeaderView, ccmpReservedZero) == 2",
        "doAssert offsetof(CcmpSecurityHeaderView, keyId) == 3",
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
        "let frameTypeBits = frameControl and 0x000C",
        "if frameTypeBits != 0 and frameTypeBits != 8:",
        "let currentFrameControlFlags = swdesc.frameControlFlags",
        "currentFrameControlFlags or 2",
        "let frameControlFlagByte = (frameControl shr 8).uint8",
        "let retryFrame = (frameControlFlagByte and 0x08'u8) != 0",
        "RxuUploadEnvView {.packed.} = object",
        "uploadEnvBaseToCountPadding*: array[20, uint8]",
        "uploadCountTailPadding*: uint32",
        "RxlHwdescCallbackEnvView {.packed.} = object",
        "callbackEnvBaseToGetStatusPadding*: array[20, uint8]",
        "RxlSubmittedDescView {.packed.} = object",
        "submittedDescBasePadding*: uint32",
        "swDescToStatusPadding*: array[48, uint8]",
        "doAssert offsetof(RxuUploadEnvView, uploadEnvBaseToCountPadding) == 0",
        "doAssert offsetof(RxuUploadEnvView, uploadCountTailPadding) == 24",
        "doAssert offsetof(RxlHwdescCallbackEnvView, callbackEnvBaseToGetStatusPadding) == 0",
        "doAssert offsetof(RxlSubmittedDescView, submittedDescBasePadding) == 0",
        "doAssert offsetof(RxlSubmittedDescView, swDescToStatusPadding) == 16",
    ]:
        assert expected in wifi_fw
    for forbidden in [
        "let fType =",
        "if fType",
        "let curStat =",
        "let fcByte1 =",
    ]:
        assert forbidden not in rx_body
    for expected in [
        "ccmpHeader.pn0 = txDesc.pnScratch[0]",
        "ccmpHeader.pn1 = txDesc.pnScratch[1]",
        "ccmpHeader.ccmpReservedZero = 0",
        "ccmpHeader.keyId = ((txKey.staIdx and 0x03'u8) shl 6) or 0x20'u8",
        "ccmpHeader.pn2 = txDesc.pnScratch[2]",
    ]:
        assert expected in tx_ccmp_header
    assert "reservedOctet" not in tx_ccmp_header

    for expected in [
        "when defined(bl808WifiRxPbufInput):",
        "var uploadListNode = co_list_pop_front(addr env.uploadList)",
        "while uploadListNode != nil:",
        "tcpip_stack_input(",
        "rxl_mpdu_free(uploadListNode)",
        "var uploadPayloadHwDesc = cast[ptr RxPayloadHwDescView](swDesc.bufferChain)",
        "while remaining > 0 and uploadPayloadHwDesc != nil:",
        "dmaArray.bufferAddrs[dmaIdx] = uploadPayloadHwDesc.bufferAddr",
        "if uploadPayloadHwDesc.usedFlag != 0:",
        "uploadPayloadHwDesc.usedFlag = 1",
        "uploadPayloadHwDesc = cast[ptr RxPayloadHwDescView](uploadPayloadHwDesc.next)",
        "uploadEnv.uploadCount = uploadEnv.uploadCount + desc.descCount.uint32",
    ]:
        assert expected in rx_upload_body
    assert "curHwDesc" not in rx_upload_body
    assert "rxl_mpdu_free(entry)" not in rx_upload_body
    for overlay_name, next_overlay, forbidden_fields in [
        (
            "RxuUploadEnvView {.packed.} = object",
            "RxlHwdescCallbackEnvView {.packed.} = object",
            [
                "reserved00*: array[20, uint8]",
                "reserved24*: uint32",
            ],
        ),
        (
            "RxlHwdescCallbackEnvView {.packed.} = object",
            "RxlSubmittedDescView {.packed.} = object",
            ["reserved00*: array[20, uint8]"],
        ),
        (
            "RxlSubmittedDescView {.packed.} = object",
            "BeaconRxDescView {.packed.} = object",
            [
                "reserved00*: uint32",
                "reserved16*: array[48, uint8]",
            ],
        ),
    ]:
        overlay_block = wifi_fw.split(overlay_name, 1)[1].split(next_overlay, 1)[0]
        for forbidden in forbidden_fields:
            assert forbidden not in overlay_block

    for expected in [
        "BlHwView {.packed.} = object",
        "BlVifView {.packed.} = object",
        "BlStaView {.packed.} = object",
        "TxHdrView {.packed.} = object",
        "TxbufView {.packed.} = object",
        "txbufHeaderPadding*: array[4, uint8]",
        "packetLenPadding*: array[2, uint8]",
        "ethernetHeaderPadding*: array[12, uint8]",
        "chainedPbufPadding*: array[12, uint8]",
        "TxdescHostView {.packed.} = object",
        "txdescPrefixPadding*: array[12, uint8]",
        "hostDescPadding*: array[4, uint8]",
        "doAssert offsetof(TxHdrView, status) == int(TxHdrStatusOff)",
        "doAssert offsetof(TxdescHostView, hostDescPadding) ==",
        "doAssert offsetof(TxdescHostView, upperHost) ==",
        "addr txdescHostView(txDescriptor).hostDescPadding[0]",
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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc mm_sec_macrx_ind*", 1)[1].split(
        "proc mm_sec_machwkey_wr*", 1
    )[0]
    sec_rx_layout = wifi_fw.split(
        "SecMacRxIndView {.packed.} = object", 1
    )[1].split("ApmTxDescPsView {.packed.} = object", 1)[0]

    assert "SecMacRxIndView {.packed.} = object" in wifi_fw
    assert "staIdx*: uint8" in wifi_fw
    assert "staIdxToLengthPadding*: uint8" in wifi_fw
    assert "length*: uint16" in wifi_fw
    assert "payload*: UncheckedArray[uint8]" in wifi_fw
    assert "doAssert offsetof(SecMacRxIndView, staIdx) == 0" in wifi_fw
    assert "doAssert offsetof(SecMacRxIndView, staIdxToLengthPadding) == 1" in wifi_fw
    assert "doAssert offsetof(SecMacRxIndView, length) == 2" in wifi_fw
    assert "doAssert offsetof(SecMacRxIndView, payload) == 4" in wifi_fw
    assert "template secMacRxIndAt(p: pointer): ptr SecMacRxIndView" in wifi_fw
    assert "let ind = secMacRxIndAt(securityIndicationMsg)" in body
    assert "ind.staIdx = staIdx" in body
    assert "ind.length = length" in body
    assert "c_memcpy(addr ind.payload[0], payload, length.csize_t)" in body
    assert "cast[ptr uint8](cast[uint](buf) + 0)" not in body
    assert "cast[ptr uint16](cast[uint](buf) + 2)" not in body
    assert "cast[pointer](cast[uint](buf) + 4)" not in body
    assert "reserved01*" not in sec_rx_layout


def test_wifi_machw_key_control_word_uses_reference_switch_tables():
    wifi_fw = wifi_fw_policy_source()

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


def test_wifi_utils_index_lookup_uses_semantic_remote_sta_index():
    wifi_utils = nim_source_with_includes(ROOT / "src/bl808/wifi/utils.nim")

    body = wifi_utils.split("proc bl_utils_idx_lookup*", 1)[1].split(
        "when defined(bl808WifiRxPbufInput):",
        1,
    )[0]

    assert "proc bl_utils_idx_lookup*(blHw: ptr BlHw; stationMacAddr: ptr uint8)" in wifi_utils
    assert "proc bl_utils_idx_lookup*(blHw: ptr BlHw; mac: ptr uint8)" not in wifi_utils

    for expected in [
        "if blHw == nil or stationMacAddr == nil:",
        "let remoteStaTable = ptrAt(cast[pointer](blHw), BlHwStaTableOff)",
        "for remoteStaIndex in 0 ..< NxRemoteStaStoreMax:",
        "let remoteStaEntry = ptrAt(remoteStaTable, uint(remoteStaIndex) * BlStaSize)",
        "uint(remoteStaIndex) * BlStaSize",
        "c_memcmp(ptrAt(remoteStaEntry, BlStaAddrOff), stationMacAddr, 6) == 0",
        "return remoteStaIndex.cint",
    ]:
        assert expected in body

    for forbidden in [
        "if blHw == nil or mac == nil:",
        "let staTable = ptrAt(cast[pointer](blHw), BlHwStaTableOff)",
        "let sta = ptrAt(staTable, uint(remoteStaIndex) * BlStaSize)",
        "c_memcmp(ptrAt(sta, BlStaAddrOff), mac, 6) == 0",
        "for i in 0 ..< NxRemoteStaStoreMax:",
        "uint(i) * BlStaSize",
        "return i.cint",
    ]:
        assert forbidden not in body


def test_wifi_tcpip_input_converts_80211_mpdu_for_lwip():
    wifi_utils = nim_source_with_includes(ROOT / "src/bl808/wifi/utils.nim")

    body = wifi_utils.rsplit("proc tcpip_stack_input*", 1)[1].split(
        "proc bl_utils_dump*", 1
    )[0]
    upload_scan_body = wifi_utils.rsplit("proc noteUploadScan", 1)[1].split(
        "proc tcpip_stack_input*", 1
    )[0]
    no_pbuf_body = wifi_utils.rsplit("proc noteTcpipNoPbuf", 1)[1].split(
        "proc wifi_nimfw_tcpip_input_calls*", 1
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
        "for wifiPacketFragmentIndex in 1 ..< WifiPktFragCount:",
        "WifiPktLenOff + uint(wifiPacketFragmentIndex * 2)",
        "WifiPktPktOff + uint(wifiPacketFragmentIndex * 4)",
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
        "nimFwDbgTcpipInputFramePbuf0 = loadLe32Bytes(ethernetFrame, 0)",
        "nimFwDbgTcpipInputFrameEthType = etherType.uint32 or (inputPbuf.len.uint32 shl 16)",
        'importc: "nimfw_dbg_pbuf_alloc_fail"',
        'importc: "nimfw_dbg_pbuf_take_fail"',
        "inc nimFwDbgPbufAllocFail",
        "inc nimFwDbgPbufTakeFail",
            "proc dhcpMessageType(ethernetFrame: pointer; ethernetFrameLength: uint16): uint8",
            "var dhcpOptionOffset = 282'u",
            "let dhcpOptionCode = loadU8(ethernetFrame, dhcpOptionOffset)",
            "let dhcpOptionLength = loadU8(ethernetFrame, dhcpOptionOffset + 1)",
            "dhcpOptionOffset += 2'u + dhcpOptionLength.uint",
        "var ipHeaderSearchOffset = 0'u32",
        "let l4 = ipHeaderSearchOffset + ihl",
        "ipHeaderSearchOffset or (ihl shl 8)",
        "proc validEthernetAt(uploadFrameData: pointer; firstLen, ethernetHeaderOffset: uint32): bool",
        "let etherType = loadBe16(uploadFrameData, ethernetHeaderOffset.uint + 12'u)",
        "var ethernetHeaderSearchOffset = 0'u32",
        "if validEthernetAt(uploadFrameData, firstLen, ethernetHeaderSearchOffset):",
        "for scanRawByteIndex in 0 ..< nimFwDbgTcpipInputScanRaw.len:",
        "let scanRawByteOffset = ipHeaderSearchOffset + scanRawByteIndex.uint32",
        "nimFwDbgTcpipInputScanRaw[scanRawByteIndex] =",
        "loadU8(uploadFrameData, scanRawByteOffset.uint)",
        "proc noteEthernetInput(inputPbuf: ptr Pbuf): bool",
        "if not noteEthernetInput(inputPbuf) and",
        "not usedMpduInput and pkt != nil",
        "if msduOffset >= 4'u32: msduOffset - 4'u32",
        "inputPbuf = allocMpduEthernetPbuf(mpduOffset, pkt)",
    ]:
        assert expected in wifi_utils
    for expected in [
        "for noPbufRawByteIndex in 0 ..< nimFwDbgTcpipInputNoPbufRaw.len:",
        "nimFwDbgTcpipInputNoPbufRaw[noPbufRawByteIndex] = 0",
        "let uploadFrameData = cast[pointer](loadU32(pkt, WifiPktPktOff).uint)",
        "let noPbufRawCopyLimit =",
        "for noPbufRawByteIndex in 0 ..< noPbufRawCopyLimit:",
        "loadU8(uploadFrameData, noPbufRawByteIndex.uint)",
    ]:
        assert expected in no_pbuf_body

    assert "inc nimFwDbgTcpipInputMpdu\n        return -1" not in body
    for forbidden in [
        "for i in 1 ..< WifiPktFragCount:",
        "WifiPktLenOff + uint(i * 2)",
        "WifiPktPktOff + uint(i * 4)",
    ]:
        assert forbidden not in wifi_utils
    for forbidden in [
        "var off = 282'u",
        "let opt = loadU8(eth, off)",
        "var off = 0'u32",
        "let vihl = loadU8(uploadFrameData, off.uint)",
        "let l4 = off + ihl",
        "proc validEthernetAt(uploadFrameData: pointer; firstLen, off: uint32): bool",
        "for i in 0 ..< nimFwDbgTcpipInputScanRaw.len:",
        "let src = ipHeaderSearchOffset + i.uint32",
        "nimFwDbgTcpipInputScanRaw[i]",
    ]:
        assert forbidden not in upload_scan_body
    for forbidden in [
        "for i in 0 ..< nimFwDbgTcpipInputNoPbufRaw.len:",
        "nimFwDbgTcpipInputNoPbufRaw[i] = 0",
        "let raw = cast[pointer](loadU32(pkt, WifiPktPktOff).uint)",
        "let limit =",
        "for i in 0 ..< limit:",
        "loadU8(uploadFrameData, i.uint)",
    ]:
        assert forbidden not in no_pbuf_body

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

    fw = wifi_fw_policy_source()
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


def test_wifi_rx_debug_traces_use_semantic_ring_slot_names():
    wifi_fw = wifi_fw_policy_source()

    ipv4_preupload_body = wifi_fw.split("proc nimFwDbgRxuIpv4Preupload", 1)[1].split(
        "proc nimFwDbgRxuDhcpMsg", 1
    )[0]
    dup_trace_body = wifi_fw.split("proc nimFwDbgRecordRxuDupDrop", 1)[1].split(
        "proc nimFwDbgRecordRxuPnDrop", 1
    )[0]
    pn_drop_trace_body = wifi_fw.split("proc nimFwDbgRecordRxuPnDrop", 1)[1].split(
        "proc nimFwDbgRecordRxuPnAccept", 1
    )[0]
    pn_accept_trace_body = wifi_fw.split("proc nimFwDbgRecordRxuPnAccept", 1)[1].split(
        "proc rxu_cntrl_replay_check", 1
    )[0]

    for expected in [
        "for tcpRawClearByteIndex in 0 ..< 64:",
        "nimFwDbgRxuAssocTcpRaw[tcpRawClearByteIndex] = 0",
        "for tcpRawCopyByteIndex in 0'u32 ..< copyLen:",
        "nimFwDbgRxuAssocTcpRaw[tcpRawCopyByteIndex.int] = ipPayload[tcpRawCopyByteIndex]",
    ]:
        assert expected in ipv4_preupload_body
    for forbidden in [
        "for i in 0 ..< 64:",
        "nimFwDbgRxuAssocTcpRaw[i] = 0",
        "for i in 0'u32 ..< copyLen:",
        "nimFwDbgRxuAssocTcpRaw[i.int] = ipPayload[i]",
    ]:
        assert forbidden not in ipv4_preupload_body

    for expected in [
        "let dupTraceSlot = int(nimFwDbgRxuDupTraceCount mod RxuDupTraceEntries.uint32)",
        "nimFwDbgRxuDupTraceFc[dupTraceSlot]",
        "nimFwDbgRxuDupTraceDhcpServer[dupTraceSlot]",
    ]:
        assert expected in dup_trace_body
    for expected in [
        "let pnDropTraceSlot = int(nimFwDbgRxuPnDropTraceCount mod RxuPnDropTraceEntries.uint32)",
        "nimFwDbgRxuPnDropTraceFc[pnDropTraceSlot]",
        "nimFwDbgRxuPnDropTraceDhcpServer[pnDropTraceSlot]",
    ]:
        assert expected in pn_drop_trace_body
    for expected in [
        "let pnAcceptTraceSlot = int(nimFwDbgRxuPnAcceptTraceCount mod RxuPnAcceptTraceEntries.uint32)",
        "nimFwDbgRxuPnAcceptTraceStage[pnAcceptTraceSlot]",
        "nimFwDbgRxuPnAcceptTraceDhcpServer[pnAcceptTraceSlot]",
    ]:
        assert expected in pn_accept_trace_body
    for body in [dup_trace_body, pn_drop_trace_body, pn_accept_trace_body]:
        assert "let idx = int(nimFwDbgRxu" not in body


def test_wifi_assoc_data_duplicate_filter_requires_retry_bit():
    fw = wifi_fw_policy_source()
    body = fw.split("proc rxu_cntrl_frame_handle*", 1)[1].split(
        "# .L171: EAPOL detection requires RFC1042 SNAP", 1
    )[0]
    duplicate_block = body.split("# Duplicate sequence check", 1)[1].split(
        "seqCachePtr[] = envSeq", 1
    )[0]
    assert "let retryFrame = (frameControl and 0x0800'u16) != 0" in duplicate_block
    assert "let protectedReplayChecked = (env.secFlags and 2) != 0" in duplicate_block
    assert "if retryFrame and not protectedReplayChecked and" in duplicate_block
    assert "seqCachePtr[] == envSeq and nimFwDbgRxuAssocUploadReady != 0" in duplicate_block
    assert "nimFwDbgRecordRxuDupDrop(frame, hwFlags, envSeq, env.tid" in duplicate_block
    assert "rawFC" not in body
    assert "seqCtrlEntryTailPadding*: array[182, uint8]" in fw
    assert "doAssert offsetof(RxuQosSeqCacheEntryView, seqCtrlEntryTailPadding) == 2" in fw
    assert "staTableToQosSeqCachePadding*: array[169 * 184, uint8]" in fw
    assert (
        "doAssert offsetof(RxuQosSeqCacheTableOverlay, staTableToQosSeqCachePadding) == 0"
        in fw
    )
    assert "doAssert offsetof(RxuQosSeqCacheTableOverlay, entries) == 169 * 184" in fw
    cache_entry_layout = fw.split(
        "RxuQosSeqCacheEntryView {.packed.} = object", 1
    )[1].split("RxuQosSeqCacheTableOverlay {.packed.} = object", 1)[0]
    cache_table_layout = fw.split(
        "RxuQosSeqCacheTableOverlay {.packed.} = object", 1
    )[1].split("ApSelfStaStartOverlay {.packed.} = object", 1)[0]
    assert "reserved02*" not in cache_entry_layout
    assert "reservedBefore*" not in cache_table_layout


def test_wifi_igtk_install_uses_typed_machw_key_request():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc bl_wifi_set_igtk_internal*", 1)[1].split(
        "proc bl_wifi_get_sta_gtk*", 1
    )[0]
    machw_layout = wifi_fw.split(
        "MachwKeyWriteParamView {.packed.} = object", 1
    )[1].split("IgtkKeyWriteStackView {.packed.} = object", 1)[0]
    igtk_stack_layout = wifi_fw.split(
        "IgtkKeyWriteStackView {.packed.} = object", 1
    )[1].split("SupplicantKeyParamView {.packed.} = object", 1)[0]

    for expected in [
        "MachwKeyWriteParamView {.packed.} = object",
        "keyTypeLenPadding*: array[2, uint8]",
        "keyLenMaterialPadding*: array[3, uint8]",
        "temporalKeyTail*: array[16, uint8]",
        "macLen*: uint8",
        "macLenAddrPadding*: array[3, uint8]",
        "macAddr*: array[6, uint8]",
        "macAddrCipherPadding*: array[2, uint8]",
        "doAssert offsetof(MachwKeyWriteParamView, keyTypeLenPadding) == 2",
        "doAssert offsetof(MachwKeyWriteParamView, keyLenMaterialPadding) == 5",
        "doAssert offsetof(MachwKeyWriteParamView, macLen) == 40",
        "doAssert offsetof(MachwKeyWriteParamView, macLenAddrPadding) == 41",
        "doAssert offsetof(MachwKeyWriteParamView, macAddr) == 44",
        "doAssert offsetof(MachwKeyWriteParamView, macAddrCipherPadding) == 50",
        "doAssert offsetof(MachwKeyWriteParamView, cipherType) == 52",
        "IgtkKeyWriteStackView {.packed.} = object",
        "stackBaseToResultPadding*: array[39, uint8]",
        "resultByte*: uint8",
        "req*: MachwKeyWriteParamView",
        "doAssert sizeof(IgtkKeyWriteStackView) == 96",
        "doAssert offsetof(IgtkKeyWriteStackView, stackBaseToResultPadding) == 0",
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
        "reserved02*: array[2, uint8]",
        "reserved05*: array[3, uint8]",
        "reserved24*: array[16, uint8]",
        "reserved41*: array[3, uint8]",
        "reserved50*: array[2, uint8]",
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
    assert "reserved00*" not in igtk_stack_layout

    for forbidden in [
        "reserved02*",
        "reserved05*",
        "reserved24*",
        "reserved41*",
        "reserved50*",
    ]:
        assert forbidden not in machw_layout


def test_wifi_set_key_tkip_mic_swap_uses_typed_key_data_overlay():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc setKey(", 1)[1].split(
        "proc bl_wifi_set_ap_key_internal*", 1
    )[0]
    supplicant_layout = wifi_fw.split(
        "SupplicantKeyParamView {.packed.} = object", 1
    )[1].split("SupplicantTkipKeyDataView {.packed.} = object", 1)[0]

    for expected in [
        "SupplicantKeyParamView {.packed.} = object",
        "keyTypeLenPadding*: array[2, uint8]",
        "keyLenMaterialPadding*: array[3, uint8]",
        "macLenAddrPadding*: array[3, uint8]",
        "requestedCipher*: uint8",
        "doAssert offsetof(SupplicantKeyParamView, keyTypeLenPadding) == 2",
        "doAssert offsetof(SupplicantKeyParamView, keyLenMaterialPadding) == 5",
        "doAssert offsetof(SupplicantKeyParamView, macLenAddrPadding) == 41",
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
        "let tkip = supplicantTkipKeyData(keyDescriptor)",
        "let micTx = tkip.micTx",
        "tkip.micTx = tkip.micRx",
        "tkip.micRx = micTx",
        "keyDescriptor.translatedCipher = 1",
    ]:
        assert expected in body

    for forbidden in [
        "rawCipher*: uint8",
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

    assert "rawCipher*" not in supplicant_layout
    assert "reserved02*" not in supplicant_layout
    assert "reserved05*" not in supplicant_layout
    assert "reserved41*" not in supplicant_layout


def test_wifi_cfg_api_element_set_uses_typed_entry_overlay():
    wifi_fw = wifi_fw_policy_source()

    cfg_entry_layout = wifi_fw.split(
        "CfgApiElementEntryView {.packed.} = object", 1
    )[1].split("HostTxLinkDescView {.packed.} = object", 1)[0]
    general_body = wifi_fw.rsplit("proc cfg_api_element_general_set*", 1)[1].split(
        "proc cfg_api_element_set*", 1
    )[0]
    set_body = wifi_fw.rsplit("proc cfg_api_element_set*", 1)[1].split(
        "proc dump_cfg_entries*", 1
    )[0]
    dump_body = wifi_fw.rsplit("proc dump_cfg_entries*", 1)[1].split(
        "# ###########################################################################",
        1,
    )[0]
    timer_dump_body = wifi_fw.rsplit("proc bugkiller_fw_queue_timer_dump*", 1)[1].split(
        "proc cfg_api_element_dump*",
        1,
    )[0]

    for expected in [
        "CfgApiElementEntryView {.packed.} = object",
        "id*: uint32",
        "subId*: uint16",
        "typeId*: uint16",
        "name*: pointer",
        "valueStorage*: pointer",
        "setHandler*: pointer",
        "setHandlerTailPadding*: array[8, uint8]",
        "doAssert sizeof(CfgApiElementEntryView) == 28",
        "doAssert offsetof(CfgApiElementEntryView, typeId) == 6",
        "doAssert offsetof(CfgApiElementEntryView, name) == 8",
        "doAssert offsetof(CfgApiElementEntryView, valueStorage) == 12",
        "doAssert offsetof(CfgApiElementEntryView, setHandler) == 16",
        "doAssert offsetof(CfgApiElementEntryView, setHandlerTailPadding) == 20",
        "template cfgApiElementEntryAt(entry: pointer): ptr CfgApiElementEntryView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let cfg = cfgApiElementEntryAt(entry)",
        "let nameStr = cfg.name",
        "let typeId = cfg.typeId",
        "let valueStorage = cfg.valueStorage",
    ]:
        assert expected in general_body

    for expected in [
        "var cfgApiEntry {.noinit.}: CfgApiElementEntryView",
        "discard c_memset(addr cfgApiEntry, 0, sizeof(CfgApiElementEntryView).csize_t)",
        "cfgApiEntry.id = id",
        "cfgApiEntry.subId = subId",
        "cfgApiEntry.typeId = typeId",
        "cfgApiEntry.valueStorage = cast[pointer](addr cfgElements[id])",
        "cfgApiEntry.setHandler = cast[pointer](setFn)",
        "setFn(cast[pointer](addr cfgApiEntry), value)",
    ]:
        assert expected in set_body

    for expected in [
        "var timerQueueEntry = keTimerQueue.first",
        "while timerQueueEntry != nil:",
        "let timerQueueEntryAddr = cast[uint](timerQueueEntry)",
        "cast[ptr uint16](timerQueueEntryAddr + 4)[]",
        "cast[ptr uint8](timerQueueEntryAddr + 6)[]",
        "cast[ptr uint32](timerQueueEntryAddr + 8)[]",
        "cast[ptr CoListHdr](cast[ptr pointer](cast[uint](timerQueueEntry))[])",
    ]:
        assert expected in timer_dump_body

    for expected in [
        "for cfgElementIndex in 0'u32 ..< cfgCount:",
        "let entryAddr = cfgBase + cfgElementIndex * 28",
        'printf("entry %d:", cast[pointer](cfgElementIndex))',
    ]:
        assert expected in dump_body

    for forbidden in [
        "let entryU = cast[uint](entry)",
        "cast[ptr pointer](entryU + 8)[]",
        "cast[ptr uint16](entryU + 6)[]",
        "cast[ptr pointer](entryU + 12)[]",
        "data*: pointer",
        "let dataPtr = cfg.data",
        "cfgApiEntry.data = cast[pointer](addr cfgElements[id])",
        "var entry = keTimerQueue.first",
        "while entry != nil:",
        "let entryU = cast[uint](entry)",
        "var entry {.noinit.}: CfgApiElementEntryView",
        "discard c_memset(addr entry, 0, sizeof(CfgApiElementEntryView).csize_t)",
        "var entry {.noinit.}: array[28, uint8]",
        "let entryAddr = cast[uint](addr entry[0])",
        "cast[ptr uint32](entryAddr)[]",
        "cast[ptr uint16](entryAddr + 4)[]",
        "cast[ptr uint16](entryAddr + 6)[]",
        "cast[ptr pointer](entryAddr + 12)[]",
        "for i in 0'u32 ..< cfgCount:",
        "let entryAddr = cfgBase + i * 28",
        'printf("entry %d:", cast[pointer](i))',
    ]:
        assert forbidden not in general_body
        assert forbidden not in set_body
        assert forbidden not in dump_body
        assert forbidden not in timer_dump_body
    assert "reserved20*" not in cfg_entry_layout


def test_wifi_mfp_uses_typed_vif_key_overlays():
    wifi_fw = wifi_fw_policy_source()

    ignore_body = wifi_fw.rsplit("proc mfp_ignore_mgmt_frame*", 1)[1].split(
        "proc mfp_protect_mgmt_frame*", 1
    )[0]
    protect_body = wifi_fw.rsplit("proc mfp_protect_mgmt_frame*", 1)[1].split(
        "proc mfp_add_mgmt_mic*", 1
    )[0]
    mic_body = wifi_fw.rsplit("proc mfp_add_mgmt_mic*", 1)[1].split(
        "proc aes_encrypt_block*", 1
    )[0]
    mfp_layout = wifi_fw.split(
        "MfpMgmtFramePolicyView {.packed.} = object", 1
    )[1].split("RxuMgtDispatchView {.packed.} = object", 1)[0]

    for expected in [
        "MfpMgmtFramePolicyView {.packed.} = object",
        "frameCtrlBodyOffsetPadding*: array[6, uint8]",
        "vifIdxFlagsPadding*: array[25, uint8]",
        "doAssert offsetof(MfpMgmtFramePolicyView, frameCtrlBodyOffsetPadding) == 2",
        "doAssert offsetof(MfpMgmtFramePolicyView, vifIdxFlagsPadding) == 11",
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

    for forbidden in [
        "reserved02*",
        "reserved11*",
    ]:
        assert forbidden not in mfp_layout

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
        "mmie.ipn[ipnByteIndex.int] = ipnByte",
        "let micWords = mmieMicWords(mmie)",
        "mmie.mic[micLowByteIndex.int] = ((micV shr (micLowByteIndex * 8)) and 0xFF'u64).uint8",
        "mmie.mic[micHighByteIndex.int] = ((micV2 shr (micHighByteIndex * 8)) and 0xFF'u64).uint8",
    ]:
        assert expected in mic_body

    assert "var idx = 0'u32" not in mic_body
    assert "idx = 0" not in mic_body
    assert "idx = 4" not in mic_body

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
    wifi_fw = wifi_fw_policy_source()

    update_body = wifi_fw.split("proc me_update_buffer_control*", 1)[1].split(
        "proc me_tx_cfm_singleton*", 1
    )[0]
    init_body = wifi_fw.split("proc rc_init*(staEntry: pointer)", 1)[1].split(
        "{.emit: \"__attribute__((optimize(\\\"crossjumping\\\"))) void rc_check",
        1,
    )[0]
    init_retry_policy_body = init_body.split(
        "let retryIndexOffsets = [RCS_MAX_TP_IDX, RCS_MAX_TP2_IDX, RCS_MAX_PROB_IDX, RCS_RESERVED_U16]",
        1,
    )[1].split("# Read MACHW timestamp low for TX descriptor", 1)[0]
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
        "for retryPolicySlotIndex in 0 ..< 4:",
        "let retryIdx = rcU8(stats, retryIndexOffsets[retryPolicySlotIndex]).uint16",
        "policy.retryRate[retryPolicySlotIndex] = packed",
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
        "for i in 0 ..< 4:",
        "retryIndexOffsets[i]",
        "policy.retryRate[i] = packed",
    ]:
        assert forbidden not in init_retry_policy_body

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit(
        "proc txu_cntrl_cfm*(param: pointer) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc txu_cntrl_tkip_mic_append*", 1
    )[0]

    for expected in [
        "HostTxThdConfirmView {.packed.} = object",
        "confirmType*: uint16",
        "confirmTypePadding*: uint16",
        "doAssert sizeof(HostTxThdConfirmView) == 20",
        "doAssert offsetof(HostTxThdConfirmView, confirmType) == 12",
        "doAssert offsetof(HostTxThdConfirmView, confirmTypePadding) == 14",
        "doAssert offsetof(HostTxThdConfirmView, flags) == 16",
        "template hostTxThdConfirmAt(p: ptr HostTxThdEntryView): ptr HostTxThdConfirmView",
        "hostTxThdConfirmAt(thd).confirmType = 0x0101'u16",
    ]:
        assert expected in wifi_fw if expected.startswith(("HostTxThdConfirmView", "confirmType", "doAssert", "template")) else expected in body

    for forbidden in [
        "HostTxThdConfirmView {.packed.} = object\n    magic*: uint32\n    next*: pointer\n    payloadStart*: uint32\n    confirmType*: uint16\n    reserved14*: uint16",
        "cast[ptr uint16](addr thd.payloadEnd)[]",
        "cast[ptr uint16](cast[uint](thd) + 12)",
        "cast[ptr uint16](cast[uint](thd) + 12'u)",
    ]:
        assert forbidden not in body


def test_wifi_tx_security_header_uses_packet_number_word_names():
    wifi_fw = wifi_fw_policy_source()

    layout = wifi_fw.split(
        "TxSecurityHeaderView {.packed.} = object", 1
    )[1].split("TxPnScratchView {.packed.} = object", 1)[0]
    body = wifi_fw.rsplit(
        "proc txu_cntrl_sec_hdr_append*", 1
    )[1].split(
        "proc txu_cntrl_tkip_mic_append*", 1
    )[0]

    for expected in [
        "packetNumberLowWord*: uint16",
        "keyIdAndPacketNumberMidWord*: uint16",
        "tkipPacketNumberMidWord*: uint16",
        "tkipPacketNumberHighWord*: uint16",
        "doAssert sizeof(TxSecurityHeaderView) == 8",
        "doAssert offsetof(TxSecurityHeaderView, packetNumberLowWord) == 0",
        "doAssert offsetof(TxSecurityHeaderView, keyIdAndPacketNumberMidWord) == 2",
        "doAssert offsetof(TxSecurityHeaderView, tkipPacketNumberMidWord) == 4",
        "doAssert offsetof(TxSecurityHeaderView, tkipPacketNumberHighWord) == 6",
    ]:
        assert expected in wifi_fw

    for expected in [
        "securityHeader.packetNumberLowWord = packetNumber.lo",
        "securityHeader.keyIdAndPacketNumberMidWord =",
        "(keyIdByte.uint16 shl 14) or packetNumber.mid",
        "securityHeader.tkipPacketNumberMidWord = packetNumber.mid",
        "securityHeader.tkipPacketNumberHighWord = packetNumber.hi",
        "secWords.packetNumberLowWord.uint32 or",
        "(secWords.keyIdAndPacketNumberMidWord.uint32 shl 16)",
        "secWords.tkipPacketNumberMidWord.uint32 or",
        "(secWords.tkipPacketNumberHighWord.uint32 shl 16)",
    ]:
        assert expected in body

    for forbidden in [
        "w0*: uint16",
        "w1*: uint16",
        "w2*: uint16",
        "w3*: uint16",
    ]:
        assert forbidden not in layout

    for forbidden in [
        "securityHeader.w0",
        "securityHeader.w1",
        "securityHeader.w2",
        "securityHeader.w3",
        "secWords.w0",
        "secWords.w1",
        "secWords.w2",
        "secWords.w3",
        "offsetof(TxSecurityHeaderView, w0)",
        "offsetof(TxSecurityHeaderView, w3)",
    ]:
        assert forbidden not in wifi_fw


def test_wifi_rate_control_counters_use_typed_overlays():
    wifi_fw = wifi_fw_policy_source()

    calc_body = wifi_fw.rsplit("proc rc_calc_tp*", 1)[1].split(
        "proc rc_update_counters*", 1
    )[0]
    update_body = wifi_fw.rsplit("proc rc_update_counters*", 1)[1].split(
        "proc rc_get_duration*", 1
    )[0]
    stats_body = wifi_fw.rsplit("proc rc_update_stats*", 1)[1].split(
        "proc rc_set_previous_mcs_index*", 1
    )[0]
    highest_rate_body = wifi_fw.rsplit("proc rc_get_initial_rate_config*", 1)[1].split(
        "proc rc_get_lowest_rate_config*", 1
    )[0]
    amsdu_body = wifi_fw.rsplit("proc me_tx_cfm_amsdu*", 1)[1].split(
        "# ME IE building functions", 1
    )[0]
    set_rate_body = wifi_fw.rsplit("proc me_rc_set_rate_req_handler*", 1)[1].split(
        "proc me_traffic_ind_req_handler*", 1
    )[0]
    set_rate_req_layout = wifi_fw.split(
        "MeRcSetRateReqPayload {.packed.} = object", 1
    )[1].split("MeTrafficIndReqPayload {.packed.} = object", 1)[0]
    rc_reset_layout = wifi_fw.split(
        "RcRateResetFieldsView {.packed.} = object", 1
    )[1].split("RcRetrySlotView {.packed.} = object", 1)[0]
    rc_retry_slot_layout = wifi_fw.split(
        "RcRetrySlotView {.packed.} = object", 1
    )[1].split("RcStatsCounterView {.packed.} = object", 1)[0]
    rc_rate_entry_layout = wifi_fw.split(
        "RcRateEntryView {.packed.} = object", 1
    )[1].split("RcRateResetFieldsView {.packed.} = object", 1)[0]
    rc_stats_layout = wifi_fw.split(
        "RcStatsCounterView {.packed.} = object", 1
    )[1].split("TxFrameEnvView {.packed.} = object", 1)[0]
    bw_body = wifi_fw.rsplit("proc rc_update_bw_nss_max*", 1)[1].split(
        "proc rc_update_preamble_type*", 1
    )[0]
    preamble_body = wifi_fw.rsplit("proc rc_update_preamble_type*", 1)[1].split(
        "proc rc_init_bcmc_rate*", 1
    )[0]
    sort_body = wifi_fw.rsplit("proc rc_sort_samples_tp*", 1)[1].split(
        "proc rc_calc_prob_ewma*", 1
    )[0]
    init_body = wifi_fw.rsplit("proc rc_init*", 1)[1].split(
        "proc rc_check*", 1
    )[0]

    for expected in [
        "RcRateEntryView {.packed.} = object",
        "rateEntryBaseToAttemptCountersPadding*: array[4, uint8]",
        "attempts*: uint16",
        "failures*: uint16",
        "probEwma*: uint16",
        "rateConfig*: uint16",
        "RcRateResetFieldsView {.packed.} = object",
        "attempts0*: uint16",
        "successesProbEwmaPadding*: array[3, uint8]",
        "oldProb*: uint8",
        "sampleSkipped*: uint8",
        "initialized*: uint8",
        "RcRetrySlotView {.packed.} = object",
        "rateIdx*: uint16",
        "retrySlotTailPadding*: array[6, uint8]",
        "RcStatsCounterView {.packed.} = object",
        "rateTableToRetrySlotsPadding*: array[128, uint8]",
        "retrySlots*: array[4, RcRetrySlotView]",
        "totalAttempts*: uint16",
        "totalSuccess*: uint16",
        "sampleCandidateToTotalsPadding*: uint16",
        "totalCountersToAvgAmpduPadding*: array[2, uint8]",
        "avgAmpduLen*: uint16",
        "retryLimit*: uint8",
        "updateStage*: uint8",
        "flagsToNssBwPadding*: array[11, uint8]",
        "nssMax*: uint8",
        "bwMax*: uint8",
        "bwToLegacyRateMapPadding*: array[5, uint8]",
        "legacyRateMap*: uint16",
        "legacyRateMapToFixedRatePadding*: array[2, uint8]",
        "fixedRate*: uint16",
        "MeRcSetRateReqPayload {.packed.} = object",
        "staIdxRatePadding*: uint8",
        "doAssert offsetof(MeRcSetRateReqPayload, staIdxRatePadding) == 1",
        "doAssert offsetof(MeRcSetRateReqPayload, fixedRate) == 2",
        "doAssert offsetof(MeRcSetRateReqPayload, mcsRate) == 4",
        "doAssert sizeof(RcRateEntryView) == RC_RATE_ENTRY_SIZE",
        "doAssert offsetof(RcRateEntryView, rateEntryBaseToAttemptCountersPadding) == 0",
        "doAssert offsetof(RcRateResetFieldsView, successesProbEwmaPadding) == 2",
        "doAssert offsetof(RcRateResetFieldsView, oldProb) == 5",
        "doAssert offsetof(RcRateResetFieldsView, sampleSkipped) == 6",
        "doAssert offsetof(RcRateResetFieldsView, initialized) == 7",
        "doAssert offsetof(RcRetrySlotView, retrySlotTailPadding) == 2",
        "doAssert offsetof(RcStatsCounterView, rateTableToRetrySlotsPadding) == 0",
        "doAssert offsetof(RcStatsCounterView, retrySlots) == 128",
        "doAssert offsetof(RcStatsCounterView, sampleCandidateToTotalsPadding) == 162",
        "doAssert offsetof(RcStatsCounterView, totalAttempts) == RCS_TOTAL_ATTEMPTS",
        "doAssert offsetof(RcStatsCounterView, totalCountersToAvgAmpduPadding) == 168",
        "doAssert offsetof(RcStatsCounterView, flagsToNssBwPadding) == 176",
        "doAssert offsetof(RcStatsCounterView, nssMax) == 187",
        "doAssert offsetof(RcStatsCounterView, bwMax) == 188",
        "doAssert offsetof(RcStatsCounterView, bwToLegacyRateMapPadding) == 189",
        "doAssert offsetof(RcStatsCounterView, legacyRateMap) == RCS_RATE_MAP_L",
        "doAssert offsetof(RcStatsCounterView, legacyRateMapToFixedRatePadding) == 196",
        "doAssert offsetof(RcStatsCounterView, fixedRate) == 198",
        "doAssert sizeof(RcStatsCounterView) == RC_STATS_SIZE",
        "template rcRateEntryAt(p: pointer): ptr RcRateEntryView",
        "template rcRateEntry(stats: pointer, rateEntryIndex: uint16): ptr RcRateEntryView",
        "template rcRateResetFields(stats: pointer, rateEntryIndex: uint16): ptr RcRateResetFieldsView",
        "template rcThroughputArray(tpArray: pointer): ptr UncheckedArray[uint32]",
        "template rcStatsCounters(stats: pointer): ptr RcStatsCounterView",
        "proc rcClearRateEntryTransientStats(stats: pointer; rateEntryIndex: uint16) {.inline.}",
        "let resetFields = rcRateResetFields(stats, rateEntryIndex)",
        "resetFields.sampleSkipped = 0",
        "resetFields.initialized = 1",
        "resetFields.attempts0 = 0",
        "resetFields.oldProb = 0",
    ]:
        assert expected in wifi_fw

    assert "reserved*" not in set_rate_req_layout
    assert "reserved00*" not in rc_rate_entry_layout
    assert "reserved02*" not in rc_reset_layout
    assert "reserved02*" not in rc_retry_slot_layout
    for forbidden in [
        "reserved00*",
        "reserved162*",
        "reserved168*",
        "reserved176*",
        "reserved189*",
        "reserved196*",
        "template rcRateEntry(stats: pointer, idx: uint16): ptr RcRateEntryView",
        "template rcRateResetFields(stats: pointer, idx: uint16): ptr RcRateResetFieldsView",
        "proc rcClearRateEntryTransientStats(stats: pointer; idx: uint16)",
        "let resetFields = rcRateResetFields(stats, idx)",
    ]:
        assert forbidden not in wifi_fw
        assert forbidden not in rc_stats_layout

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
        "while retrySlotIndex < counters.retrySlots.len:",
        "let retryRateIndex = counters.retrySlots[retrySlotIndex].rateIdx",
        "let retryRateEntry = rcRateEntry(stats, retryRateIndex)",
        "retryRateEntry.attempts = entryAttempts",
        "retryRateEntry.failures = entryFailures",
        "if retryRateEntry.attempts < retryRateEntry.failures:",
        "let stage = counters.updateStage",
        "let retryLimit = counters.retryLimit",
    ]:
        assert expected in update_body

    for expected in [
        "for rateEntryIndex in 0'u32 ..< nRates.uint32:",
        "let entryPtr = rcRateEntryPtr(stats, rateEntryIndex.int)",
        "for rateEntryIndex in 0'u32 ..< nR.uint32:",
        "let statsResetRateEntry = rcRateEntry(stats, rateEntryIndex.uint16)",
        "statsResetRateEntry.attempts = 0",
        "statsResetRateEntry.failures = 0",
        "var leadingZeroCount: cint",
        "hiMcs = (31 - leadingZeroCount).uint8",
        "for sortedThroughputSlotIndex in 0'u32 ..< 4:",
        "let sortedThroughputByteOffset = sortedThroughputSlotIndex * 8",
        "let storedSortedThroughput = cast[ptr uint16](destBase + sortedThroughputByteOffset + 4)[]",
        "if tpVal != storedSortedThroughput:",
    ]:
        assert expected in highest_rate_body if "leadingZeroCount" in expected else expected in stats_body

    for expected in [
        "for cckRateBitIndex in 0 ..< 4:",
        "rMap and (1'u16 shl cckRateBitIndex)",
        "for ofdmRateBitIndex in 4 ..< 12:",
        "rMap shr ofdmRateBitIndex.uint16",
    ]:
        assert expected in init_body

    assert "let amsduLen = rcStatsCounters(rcStats).legacyRateMap" in amsdu_body
    assert "cast[ptr uint16](cast[uint](rcStats) + RCS_RATE_MAP_L)" not in amsdu_body

    for expected in [
        "let rateControlStats = rcStatsCounters(rcPtr)",
        "rateControlStats.fixedRate = 0xFFFF'u16",
        "var flags = rateControlStats.flags",
        "rateControlStats.flags = flags",
        "let rateControlStaInfoIdx = sta.infoIdx",
        "rc_update_bw_nss_max(\n      rateControlStaInfoIdx, rateControlStats.nssMax, rateControlStats.bwMax)",
        "rateControlStats.fixedRate = fixedRate",
    ]:
        assert expected in set_rate_body

    assert "staField40" not in set_rate_body

    for expected in [
        "var sampleRateEntryIndex: int = 1",
        "while sampleRateEntryIndex < nRates.int - 1:",
        "rcSetRateConfig(rcStats, sampleRateEntryIndex, randomRate)",
        "for rateEntryIndex in 0 ..< nRates.int:",
        "rcClearRateEntryTransientStats(rcStats, rateEntryIndex.uint16)",
    ]:
        assert expected in bw_body

    for forbidden in [
        "rcSetRateConfig(stats, i, 0xFFFF'u16)",
        "rcClearRateEntryTransientStats(rcStats, i.uint16)",
    ]:
        assert forbidden not in wifi_fw

    for expected in [
        "var rateEntryIndex: uint16 = 0",
        "while rateEntryIndex < rcU16(stats, RCS_N_RATES):",
        "let preambleRateEntry = rcRateEntry(stats, rateEntryIndex)",
        "var rateConfig = preambleRateEntry.rateConfig",
        "rcClearRateEntryTransientStats(stats, rateEntryIndex)",
        "preambleRateEntry.rateConfig = rateConfig",
    ]:
        assert expected in preamble_body

    for expected in [
        "let tp = rcThroughputArray(tpArray)",
        "for throughputSortIndex in 1 ..< sortPassLimit:",
        "let currentThroughput = tp[throughputSortIndex]",
        "let previousThroughput = tp[throughputSortIndex - 1]",
        "var swapEntry {.noinit.}: RcRateEntryView",
        "let currentRateEntry = rcRateEntryPtr(stats, throughputSortIndex)",
        "let previousRateEntry = rcRateEntryPtr(stats, throughputSortIndex - 1)",
        "sizeof(RcRateEntryView).csize_t",
        "tp[throughputSortIndex] = previousThroughput",
        "tp[throughputSortIndex - 1] = currentThroughput",
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
        "var idx: int = 1",
        "rcSetRateConfig(rcStats, idx, randomRate)",
        "var idx: uint16 = 0",
        "let entry = rcRateEntry(stats, idx)",
        "let entry = rcRateEntry(stats, rateEntryIndex)",
        "let entry = rcRateEntry(stats, rateEntryIndex.uint16)",
        "let rateIdx = counters.retrySlots[slotIdx].rateIdx",
        "while slotIdx < counters.retrySlots.len:",
        "rcClearRateEntryTransientStats(stats, idx)",
        "for i in 0'u32 ..< nRates.uint32:",
        "let entryPtr = rcRateEntryPtr(stats, i.int)",
        "for i in 0'u32 ..< nR.uint32:",
        "let entry = rcRateEntry(stats, i.uint16)",
        "var c: cint",
        "31 - c",
        "let storedSortedThroughput = cast[ptr uint16](destBase + srcOff + 4)[]",
        "let curVal = cast[ptr uint16](destBase + srcOff + 4)[]",
        "tpVal != curVal",
    ]:
        assert forbidden not in bw_body
        assert forbidden not in preamble_body
        assert forbidden not in highest_rate_body
        assert forbidden not in stats_body

    for forbidden in [
        "for i in 0 ..< 4:",
        "for i in 4 ..< 12:",
    ]:
        assert forbidden not in init_body

    for forbidden in [
        "cast[ptr uint32](cast[uint](tpArray) + (i * 4).uint)",
        "cast[ptr uint32](cast[uint](tpArray) + ((i - 1) * 4).uint)",
        "var tmp {.noinit.}: array[12, uint8]",
        "let tp1 = tp[i]",
        "let tp0 = tp[i - 1]",
        "let e1 = rcRateEntryPtr(stats, i)",
        "let e0 = rcRateEntryPtr(stats, i - 1)",
        "tp[i] = tp0",
        "tp[i - 1] = tp1",
        "12.csize_t",
    ]:
        assert forbidden not in sort_body

def test_wifi_vif_lookup_helper_uses_typed_overlay():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc vif_mgmt_add_key*", 1)[1].split(
        "proc vif_mgmt_del_key*", 1
    )[0]
    del_body = wifi_fw.rsplit("proc vif_mgmt_del_key*", 1)[1].split(
        "proc vif_mgmt_send_postponed_frame*", 1
    )[0]
    add_key_layout = wifi_fw.split(
        "VifMgmtAddKeyParamView {.packed.} = object", 1
    )[1].split("ScanuRawSendCfmPayload {.packed.} = object", 1)[0]
    key_slot_table_layout = wifi_fw.split(
        "VifKeySlotTableOverlay {.packed.} = object", 1
    )[1].split("TxSecurityKeyListView {.packed.} = object", 1)[0]

    for expected in [
        "VifKeySlotTableOverlay {.packed.} = object",
        "vifBaseToKeySlotsPadding*: array[528, uint8]",
        "doAssert offsetof(VifKeySlotTableOverlay, vifBaseToKeySlotsPadding) == 0",
        "doAssert offsetof(VifKeySlotTableOverlay, slots) == 528",
        "template vifKeySlotTable(vif: ptr VifChannelView): ptr VifKeySlotTableOverlay",
        "template vifKeySlot(vif: ptr VifChannelView, slot: uint): ptr VifKeySlotView",
        "template vifKeySlotPtr(vif: ptr VifChannelView, slot: uint): uint32",
        "let req = vifMgmtAddKeyParamView(param)",
        "let vif = vifChannelForIdx(keySlot)",
        "let keyView = vifKeySlot(vif, 0)",
        "let staReplay = vifKeySlot(vif, staIdx.uint)",
        "staReplay.replayCounters[replayCounterIndex].pnLow = pnLo",
        "staReplay.replayCounters[replayCounterIndex].pnHigh = pnHi",
        "let keyPtrs = vifKeyPointers(vif)",
        "keyPtrs.groupKeyPtr = vifKeySlotPtr(vif, 0)",
        "keyPtrs.defaultKeyPtr = vifKeySlotPtr(vif, 0)",
    ]:
        assert expected in wifi_fw if "template " in expected or "Overlay" in expected or "Padding" in expected or "doAssert" in expected else expected in body

    for expected in [
        "keyTypeLenPadding*: array[2, uint8]",
        "keyLenMaterialPadding*: array[3, uint8]",
        "macLenPnPadding*: array[3, uint8]",
        "rxPnTailPadding*: array[4, uint8]",
        "doAssert offsetof(VifMgmtAddKeyParamView, keyTypeLenPadding) == 2",
        "doAssert offsetof(VifMgmtAddKeyParamView, keyLenMaterialPadding) == 5",
        "doAssert offsetof(VifMgmtAddKeyParamView, tkipKeyMaterial) == 24",
        "doAssert offsetof(VifMgmtAddKeyParamView, macLenPnPadding) == 41",
        "doAssert offsetof(VifMgmtAddKeyParamView, pnLowBytes) == 44",
        "doAssert offsetof(VifMgmtAddKeyParamView, pnHighBytes) == 48",
        "doAssert offsetof(VifMgmtAddKeyParamView, cipherType) == 52",
        "doAssert offsetof(VifMgmtAddKeyParamView, keySlot) == 53",
        "doAssert offsetof(VifMgmtAddKeyParamView, spp) == 54",
        "doAssert offsetof(VifMgmtAddKeyParamView, hasRxPn) == 55",
        "doAssert offsetof(VifMgmtAddKeyParamView, rxPnTailPadding) == 56",
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
        "for replacementKeySlotIndex in 0'u .. 3'u:",
        "let slotValid = vifKeySlot(vif, replacementKeySlotIndex).installed",
        "keyPtrs.defaultKeyPtr = vifKeySlotPtr(vif, replacementKeySlotIndex)",
        "let validFlag = vifKeySlot(vif, keySlotU + 4'u).installed",
    ]:
        assert expected in del_body

    for forbidden in [
        "reserved02*",
        "reserved05*",
        "reserved41*",
        "reserved52*",
    ]:
        assert forbidden not in add_key_layout
    assert "reserved00*" not in key_slot_table_layout

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
    wifi_fw = wifi_fw_policy_source()

    init_body = wifi_fw.rsplit("proc vif_mgmt_init*", 1)[1].split(
        "proc vif_mgmt_register*", 1
    )[0]
    register_body = wifi_fw.rsplit("proc vif_mgmt_register*", 1)[1].split(
        "proc vif_mgmt_unregister*", 1
    )[0]
    unregister_body = wifi_fw.rsplit("proc vif_mgmt_unregister*", 1)[1].split(
        "proc vif_mgmt_add_key*", 1
    )[0]
    ap_bcn_int_body = wifi_fw.rsplit("proc vif_mgmt_set_ap_bcn_int*", 1)[1].split(
        "proc vif_mgmt_switch_channel*", 1
    )[0]

    for expected in [
        "vif0View.beaconTimeoutTimer.callback = bcnToEvtAddr",
        "vif0View.beaconTimeoutTimer.env = cast[uint32](vif0)",
        "vif1View.beaconTimeoutTimer.callback = bcnToEvtAddr",
        "vif1View.beaconTimeoutTimer.env = cast[uint32](vif1Entry)",
    ]:
        assert expected in init_body

    for expected in [
        "let freeVifListNode = co_list_pop_front(addr env.freeList)",
        "if freeVifListNode == nil:",
        "let vifEntry = cast[pointer](freeVifListNode)",
        "vif.tbttNode.vifIdx = vifIdx",
        "var vifIdx = 0'u8",
        "while vifIdx < MAX_VIFS.uint8 and vifChannelForIdx(vifIdx) != vif:",
        "vif.tbttTimer.env = pointerAddrU32(vifEntry)",
        "vif.tbttTimer.callback = staTbttCb",
        "vif.keepAliveTimer.callback = bcnTimeoutCb",
        "vif.keepAliveTimer.env = pointerAddrU32(vifEntry)",
        "vif.securityTimer.callback = dataTimeoutCb",
        "vif.securityTimer.env = pointerAddrU32(vifEntry)",
        "vif.rssiStatePadding[0] = 0",
        "vif.rssiStatePadding[1] = 0",
        "doAssert offsetof(VifChannelView, rssiStatePadding) == 192",
    ]:
        assert expected in wifi_fw if expected.startswith("doAssert") else expected in register_body

    for expected in [
        "let otherVif = vifChannelForIdx(otherVifIdx)",
        "otherVif.currentBssid[0].uint32",
        "otherVif.currentBssid[5].uint32 shl 8",
        "vif.beaconTimeoutTimer.callback = cast[pointer](vif_mgmt_bcn_to_evt)",
        "vif.beaconTimeoutTimer.env = pointerAddrU32(vifEntry)",
    ]:
        assert expected in unregister_body

    for expected in [
        "let beaconIntervalRegValue = regRead(MACHW_BCN_INT_REG)",
        "let beaconIntervalRegHighHalf = beaconIntervalRegValue and 0xFFFF0000'u32",
        "regWrite(MACHW_BCN_INT_REG, beaconIntervalRegHighHalf or minInterval.uint32)",
    ]:
        assert expected in ap_bcn_int_body

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
        "let entry = co_list_pop_front(addr env.freeList)",
        "vif.reserved192[0]",
        "vif.reserved192[1]",
    ]:
        assert forbidden not in init_body
        assert forbidden not in register_body
        assert forbidden not in unregister_body

    for forbidden in [
        "let curVal = regRead(MACHW_BCN_INT_REG)",
        "let masked = curVal and 0xFFFF0000'u32",
        "regWrite(MACHW_BCN_INT_REG, masked or minInterval.uint32)",
    ]:
        assert forbidden not in ap_bcn_int_body

    for forbidden in [
        "let vifTabBase = cast[uint](addr vif_info_tab[0])",
        "let rawDiff = vifEntry - vifTabBase",
        "rawDiff div VIF_ENTRY_SIZE.uint",
    ]:
        assert forbidden not in register_body


def test_wifi_vif_overlay_helpers_use_field_anchors():
    wifi_fw = wifi_fw_policy_source()
    ht_caps_layout = wifi_fw.split(
        "VifHtCapabilitiesOverlay {.packed.} = object", 1
    )[1].split("VifHtOperationOverlay {.packed.} = object", 1)[0]
    ht_operation_layout = wifi_fw.split(
        "VifHtOperationOverlay {.packed.} = object", 1
    )[1].split("VifApConfigOverlay {.packed.} = object", 1)[0]
    ap_config_layout = wifi_fw.split(
        "VifApConfigOverlay {.packed.} = object", 1
    )[1].split("KeyReplayCounterView {.packed.} = object", 1)[0]

    for expected in [
        "doAssert offsetof(VifChannelView, apChanSwitchPadding) == 339",
        "doAssert offsetof(VifChannelView, htCapabilitiesStorage) == 344",
        "doAssert offsetof(VifChannelView, edcaParams) == 456",
        "doAssert offsetof(VifSecurityOverlay, connected) == 0",
        "doAssert offsetof(VifHtCapabilitiesOverlay, capInfo) == 0",
        "mcsSetToExtCapPadding*: uint8",
        "extCapToTxBfCapsPadding*: array[2, uint8]",
        "doAssert offsetof(VifHtCapabilitiesOverlay, mcsSetToExtCapPadding) == 19",
        "doAssert offsetof(VifHtCapabilitiesOverlay, extCapToTxBfCapsPadding) == 22",
        "doAssert offsetof(VifHtOperationOverlay, flags) == 0",
        "flagsToSecChanPadding*: uint8",
        "doAssert offsetof(VifHtOperationOverlay, flagsToSecChanPadding) == 2",
        "highestRateToAuthTypePadding*: array[2, uint8]",
        "securityFlagsToBeaconIntervalPadding*: array[26, uint8]",
        "doAssert offsetof(VifApConfigOverlay, highestRateToAuthTypePadding) == 20",
        "doAssert offsetof(VifApConfigOverlay, securityFlagsToBeaconIntervalPadding) == 32",
        "template vifSecurity(vif: ptr VifChannelView): ptr VifSecurityOverlay =\n  cast[ptr VifSecurityOverlay](addr vif.edcaParams[32])",
        "template vifHtCapabilities(vif: ptr VifChannelView): ptr VifHtCapabilitiesOverlay =\n  cast[ptr VifHtCapabilitiesOverlay](addr vif.htCapabilitiesStorage[4])",
        "template vifHtOperation(vif: ptr VifChannelView): ptr VifHtOperationOverlay =\n  cast[ptr VifHtOperationOverlay](addr vif.edcaParams[20])",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "reserved339*: uint8",
        "doAssert offsetof(VifChannelView, reserved344) == 344",
        "addr vif.reserved344[4]",
        "cast[ptr VifSecurityOverlay](cast[uint](vif) + 488)",
        "cast[ptr VifHtCapabilitiesOverlay](cast[uint](vif) + 348)",
        "cast[ptr VifHtOperationOverlay](cast[uint](vif) + 476)",
    ]:
        assert forbidden not in wifi_fw

    for forbidden in [
        "reserved19*",
        "reserved22*",
    ]:
        assert forbidden not in ht_caps_layout
    assert "reserved478*" not in ht_operation_layout
    for forbidden in [
        "reserved20*",
        "reserved32*",
    ]:
        assert forbidden not in ap_config_layout


def test_wifi_sta_bandwidth_overlay_uses_field_anchor():
    wifi_fw = wifi_fw_policy_source()

    for expected in [
        "doAssert offsetof(StaInfoView, bandwidthCheckPrefix) == 74",
        "doAssert sizeof(StaBandwidthOverlay) == 56",
        "doAssert offsetof(StaBandwidthOverlay, rateInfoPtr) == 0",
        "doAssert offsetof(StaBandwidthOverlay, bandwidthCheckPadding) == 8",
        "bandwidthCheckPadding*: array[46, uint8]",
        "template staBandwidthOverlay(sta: ptr StaInfoView): ptr StaBandwidthOverlay =\n  cast[ptr StaBandwidthOverlay](addr sta.bandwidthCheckPrefix[2])",
    ]:
        assert expected in wifi_fw

    assert "cast[ptr StaBandwidthOverlay](cast[uint](sta) + 76'u)" not in wifi_fw
    assert "reserved84*: array[46, uint8]" not in wifi_fw
    assert "addr sta.reserved74[2]" not in wifi_fw


def test_wifi_vif_channel_view_padding_is_semantic():
    wifi_fw = wifi_fw_policy_source()
    vif_layout = wifi_fw.split("VifChannelView {.packed.} = object", 1)[1].split(
        "VifKeySlotView {.packed.} = object", 1
    )[0]
    security_layout = wifi_fw.split(
        "VifSecurityOverlay {.packed.} = object", 1
    )[1].split("VifMachwKeyIndexOverlay {.packed.} = object", 1)[0]

    for expected in [
        "bssidToChanCtxtPadding*: array[2, uint8]",
        "staIdxToPsLastTimePadding*: array[3, uint8]",
        "uapsdBitmapToBeaconTimeoutPadding*: array[3, uint8]",
        "probeCountToTbttCountPadding*: array[3, uint8]",
        "keepAliveToSecurityTimerPadding*: array[16, uint8]",
        "keyPsStateToBeaconTxDescPadding*: array[8, uint8]",
        "beaconTxDescToCallbackPadding*: array[92, uint8]",
        "beaconCallbackToLengthsPadding*: array[4, uint8]",
        "timFlagsToPsBaCounterPadding*: array[3, uint8]",
        "psBaCounterToApStartIntervalPadding*: uint8",
        "scanBandToOperChanPadding*: array[2, uint8]",
        "basicRatesToWmmQosPadding*: array[3, uint8]",
        "wmmFlagsToEdcaParamsPadding*: array[2, uint8]",
        "connectedToRsnIePadding*: array[3, uint8]",
        "keyMgmtMaskToKeyMgmtPadding*: array[3, uint8]",
        "doAssert offsetof(VifChannelView, bssidToChanCtxtPadding) == 62",
        "doAssert offsetof(VifChannelView, staIdxToPsLastTimePadding) == 97",
        "doAssert offsetof(VifChannelView, uapsdBitmapToBeaconTimeoutPadding) == 105",
        "doAssert offsetof(VifChannelView, probeCountToTbttCountPadding) == 117",
        "doAssert offsetof(VifChannelView, keepAliveToSecurityTimerPadding) == 156",
        "doAssert offsetof(VifChannelView, keyPsStateToBeaconTxDescPadding) == 200",
        "doAssert offsetof(VifChannelView, beaconTxDescToCallbackPadding) == 212",
        "doAssert offsetof(VifChannelView, beaconCallbackToLengthsPadding) == 312",
        "doAssert offsetof(VifChannelView, timFlagsToPsBaCounterPadding) == 331",
        "doAssert offsetof(VifChannelView, psBaCounterToApStartIntervalPadding) == 335",
        "doAssert offsetof(VifChannelView, scanBandToOperChanPadding) == 422",
        "doAssert offsetof(VifChannelView, basicRatesToWmmQosPadding) == 449",
        "doAssert offsetof(VifChannelView, wmmFlagsToEdcaParamsPadding) == 454",
        "doAssert offsetof(VifSecurityOverlay, connectedToRsnIePadding) == 1",
        "doAssert offsetof(VifSecurityOverlay, keyMgmtMaskToKeyMgmtPadding) == 13",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "reserved62*",
        "reserved97*",
        "reserved105*",
        "reserved117*",
        "reserved156*",
        "reserved200*",
        "reserved212*",
        "reserved312*",
        "reserved331*",
        "reserved335*",
        "reserved422*",
        "reserved449*",
        "reserved454*",
    ]:
        assert forbidden not in vif_layout

    for forbidden in [
        "reserved489*",
        "reserved501*",
    ]:
        assert forbidden not in security_layout


def test_wifi_sta_info_padding_uses_contextual_names():
    wifi_fw = wifi_fw_policy_source()

    for expected in [
        "macAddrToAssocInfoPadding*: array[2, uint8]",
        "paramFlagPadding*: array[3, uint8]",
        "beaconTimePadding*: array[14, uint8]",
        "keyFlagsPadding*: array[3, uint8]",
        "supportedRatesPadding*: array[3, uint8]",
        "vhtCapsPadding*: array[12, uint8]",
        "htVhtConfigPadding*: array[3, uint8]",
        "controlPortState*: uint8",
        "doAssert offsetof(StaInfoView, macAddrToAssocInfoPadding) == 10",
        "doAssert offsetof(StaInfoView, controlPortState) == 72",
        "doAssert offsetof(StaInfoView, paramFlagPadding) == 45",
        "doAssert offsetof(StaInfoView, beaconTimePadding) == 56",
        "doAssert offsetof(StaInfoView, keyFlagsPadding) == 237",
        "doAssert offsetof(StaInfoView, supportedRatesPadding) == 261",
        "doAssert offsetof(StaInfoView, vhtCapsPadding) == 296",
        "doAssert offsetof(StaInfoView, htVhtConfigPadding) == 317",
        "selfStaStatusPrefixPadding*: array[4, uint8]",
        "statusInfoIdxPadding*: array[34, uint8]",
        "infoIdxValidPadding*: uint8",
        "validVifTypePadding*: array[29, uint8]",
        "vifTypeRateSeedPadding*: array[175, uint8]",
        "rateSeedTxPolicyPadding*: array[73, uint8]",
        "doAssert offsetof(ApSelfStaStartOverlay, selfStaStatusPrefixPadding) == 0",
        "doAssert offsetof(ApSelfStaStartOverlay, statusInfoIdxPadding) == 6",
        "doAssert offsetof(ApSelfStaStartOverlay, infoIdxValidPadding) == 41",
        "doAssert offsetof(ApSelfStaStartOverlay, validVifTypePadding) == 43",
        "doAssert offsetof(ApSelfStaStartOverlay, vifTypeRateSeedPadding) == 73",
        "doAssert offsetof(ApSelfStaStartOverlay, rateSeedTxPolicyPadding) == 261",
    ]:
        assert expected in wifi_fw

    sta_info_block = wifi_fw.split("StaInfoView {.packed.} = object", 1)[1].split(
        "StaBandwidthOverlay {.packed.} = object", 1
    )[0]
    ap_self_sta_start_block = wifi_fw.split(
        "ApSelfStaStartOverlay {.packed.} = object", 1
    )[1].split("StaMgmtRegisterParamView {.packed.} = object", 1)[0]
    for forbidden in [
        "reserved45*: array[3, uint8]",
        "reserved56*: array[14, uint8]",
        "reserved237*: array[3, uint8]",
        "reserved261*: array[3, uint8]",
        "reserved296*: array[12, uint8]",
        "reserved317*: array[3, uint8]",
        "reserved10*: array[2, uint8]",
        "rxNss*: uint8",
        "doAssert offsetof(StaInfoView, rxNss) == 72",
    ]:
        assert forbidden not in sta_info_block
    for forbidden in [
        "reserved00*: array[4, uint8]",
        "reserved06*: array[34, uint8]",
        "reserved41*: uint8",
        "reserved43*: array[29, uint8]",
        "reserved73*: array[175, uint8]",
        "reserved261*: array[73, uint8]",
    ]:
        assert forbidden not in ap_self_sta_start_block


def test_wifi_sta_control_port_state_uses_semantic_field_name():
    wifi_fw = wifi_fw_policy_source()

    supp_body = wifi_fw.split("proc sm_handle_supplicant_result*", 1)[1].split(
        "proc sm_send_sa_query*", 1
    )[0]
    sa_query_body = wifi_fw.split("proc sm_sa_query_handler*", 1)[1].split(
        "proc sm_issue_sa_query_request*", 1
    )[0]
    tx_push_body = wifi_fw.split("proc txu_cntrl_push*", 1)[1].split(
        "proc txu_cntrl_reset*", 1
    )[0]
    vif_state_body = wifi_fw.split("proc mm_set_vif_state_cfm_handler*", 1)[1].split(
        "proc sm_auth_send*", 1
    )[0]
    sta_add_body = wifi_fw.split("proc me_sta_add_req_handler*", 1)[1].split(
        "proc me_sta_del_req_handler*", 1
    )[0]

    for expected in [
        "let supplicantControlPortState = sta.controlPortState",
        "if supplicantControlPortState == 2:",
        "sta.controlPortState = 2",
    ]:
        assert expected in supp_body

    for expected in [
        "let stationControlPortState = staInfoForIdx(staIdx).controlPortState",
        "if stationControlPortState != 2:",
    ]:
        assert expected in sa_query_body

    for expected in [
        "let stationControlPortState = sta.controlPortState",
        "if stationControlPortState == 2:",
        "elif stationControlPortState == 1:",
    ]:
        assert expected in tx_push_body

    for expected in [
        "let controlPortState = 2'u8 - (keyPointerFlags and 1).uint8",
        "sta.controlPortState = controlPortState",
    ]:
        assert expected in vif_state_body

    for expected in [
        "let keyFlagByte = (vifKeyPointers(vif).flags and 0xFF).uint8",
        "let controlPortState = 2'u8 - (keyFlagByte and 1)",
        "sta.controlPortState = controlPortState",
    ]:
        assert expected in sta_add_body

    for forbidden in [
        "rxNss",
        "curStatus",
        "let staType = sta.controlPortState",
        "let rxNss",
        "let nssFlag",
    ]:
        assert forbidden not in supp_body
        assert forbidden not in sa_query_body
        assert forbidden not in tx_push_body
        assert forbidden not in vif_state_body
        assert forbidden not in sta_add_body


def test_wifi_mm_sta_delete_uses_vif_overlay_pointer():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    assert "var timIeAddrOut {.noinit.}: ptr uint32" in beacon_body
    assert "timIeAddrOut[] = 0  # no TIM IE found yet" in beacon_body
    assert "var currentIeAddr = cast[uint](ieBody)" in beacon_body
    assert "let ie = macIeAt(currentIeAddr)" in beacon_body
    assert "timIeAddrOut[] = cast[uint32](currentIeAddr)" in beacon_body
    assert "cast[pointer](currentIeAddr)" in beacon_body
    assert "currentIeAddr += totalLen" in beacon_body
    assert "let vifU = cast[uint](vif)" not in beacon_body
    assert "cast[uint32](vifU)" not in beacon_body
    assert "let csaCtxU = cast[uint](csaCtxPtr)" not in beacon_body
    assert "cast[ptr uint16](csaCtxU + 6)" not in beacon_body
    assert "cast[ptr uint8](csaCtxU + 4)" not in beacon_body
    assert "var resultPtr" not in beacon_body
    assert "resultPtr[]" not in beacon_body
    assert "var iePos" not in beacon_body
    assert "macIeAt(iePos)" not in beacon_body

    assert "pointerAddrU32(vifNode)" in ps_body
    assert "let vifU = cast[uint](vif)" not in ps_body
    assert "cast[uint32](vifU)" not in ps_body


def test_wifi_ps_set_mode_uses_typed_vif_confirmation_overlays():
    wifi_fw = wifi_fw_policy_source()

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


def test_wifi_power_save_null_confirm_count_uses_semantic_names():
    wifi_fw = wifi_fw_policy_source()

    disable_body = wifi_fw.split(
        "proc ps_disable_cfm*(vifEntry: pointer, statusFlags: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc ps_traffic_status_update*", 1
    )[0]
    timer_body = wifi_fw.split(
        "proc ps_tx_null_timer_handle*() {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc mm_check_beacon*", 1
    )[0]
    enable_body = wifi_fw.split(
        "proc ps_enable_cfm*(vifEntry: pointer, status: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc ps_enable_cfm_handle*", 1
    )[0]
    dpsm_body = wifi_fw.split(
        "proc ps_dpsm_update*(enable: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc mm_ap_traffic_probe_cfm*", 1
    )[0]

    for body in [disable_body, timer_body, enable_body]:
        assert "let pendingNullConfirmCount = ps.pendingCount" in body
        assert "if pendingNullConfirmCount == 0:" in body
        assert "let cnt = ps.pendingCount" not in body

    for body in [disable_body, timer_body]:
        assert "let remainingNullConfirmCount = pendingNullConfirmCount - 1" in body
        assert "ps.pendingCount = remainingNullConfirmCount" in body
        assert "if remainingNullConfirmCount != 0:" in body

    assert "ps.pendingCount = pendingNullConfirmCount - 1" in enable_body

    for expected in [
        "let pendingNullConfirmSnapshot = ps.pendingCount",
        "ps.pendingCount = pendingNullConfirmSnapshot + 1",
        "if ps.pendingCount == pendingNullConfirmSnapshot + 1:",
    ]:
        assert expected in dpsm_body

    for forbidden in [
        "let c = ps.pendingCount",
        "ps.pendingCount = c + 1",
        "if ps.pendingCount == c + 1:",
    ]:
        assert forbidden not in dpsm_body


def test_wifi_ap_traffic_probe_uses_semantic_keepalive_budget_name():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split(
        "proc mm_ap_traffic_probe_cfm*(vifEntry: pointer, status: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc td_timer_end*", 1
    )[0]

    for expected in [
        "let keepAliveMissBudget = mm.keepAliveLimit",
        "if keepAliveMissBudget == 0:",
        "mm.keepAliveLimit = keepAliveMissBudget - 1",
        "mm_send_connection_loss_ind(vifIdx, 22)",
    ]:
        assert expected in body

    for forbidden in [
        "let cnt = mm.keepAliveLimit",
        "if cnt == 0:",
        "mm.keepAliveLimit = cnt - 1",
    ]:
        assert forbidden not in body


def test_wifi_null_frame_and_postponed_service_use_typed_overlays():
    wifi_fw = wifi_fw_policy_source()
    qos_header_layout = wifi_fw.split(
        "MacQosDataFrameHeaderView {.packed.} = object", 1
    )[1].split("TxFrameDescView {.packed.} = object", 1)[0]

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
    selfcts_body = wifi_fw.split(
        "proc txl_frame_send_selfcts_frame*(vifInfo: pointer, duration: uint16, rateConfig: uint32, navValue: uint32) {.exportc, cdecl.} =",
        1,
    )[1].split(
        "const WifiTxFrameSuccessfulBit", 1
    )[0]
    service_body = wifi_fw.split(
        "proc wifi_nimfw_service_sta_postponed*(limit: uint32): uint32 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc rfc_channel_ops*", 1
    )[0]
    keepalive_body = wifi_fw.split(
        "proc wifi_nimfw_send_sta_null_frame*(): uint8 {.exportc, cdecl.} =",
        1,
    )[1].split(
        "proc wifi_nimfw_null_frame_ack_ok_count*", 1
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
        "header*: MacDataFrameHeaderView",
        "doAssert offsetof(MacQosDataFrameHeaderView, header) == 0",
        "doAssert offsetof(MacQos4AddrFrameHeaderView, header) == 0",
        "hdr.header.frameControl",
        "hdr.header.seqCtrl",
        "hdr.header.addr1",
        "pushedHdr.header.frameControl",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "data*: MacDataFrameHeaderView",
        "hdr.data.",
        "pushedHdr.data.",
    ]:
        assert forbidden not in qos_header_layout
        assert forbidden not in qosnull_body

    for expected in [
        "let aux = hostTxAuxWords(desc)",
        "aux.rateConfig = rateConfig",
        "aux.navValue = navValue",
    ]:
        assert expected in selfcts_body

    for expected in [
        "for staPostponedVifIndex in 0'u8 ..< MAX_VIFS.uint8:",
        "let vif = vifChannelForIdx(staPostponedVifIndex)",
        "let vifEntry = cast[pointer](vif)",
        "let staEntry = cast[pointer](staInfoForIdx(vif.staIdx))",
        "if txl_cntrl_tx_check(vifEntry):",
        "let postponedFramesSent =",
        "sta_mgmt_send_postponed_frame(vifEntry, staEntry, remaining)",
    ]:
        assert expected in service_body

    assert "for postponedCountStaIndex in 0'u8 ..< STA_INFO_TAB_ENTRIES.uint8:" in count_body
    assert "let sta = staInfoForIdx(postponedCountStaIndex)" in count_body
    assert "total += co_list_cnt(addr sta.postponedList)" in count_body
    assert "for i in 0'u8 ..< STA_INFO_TAB_ENTRIES.uint8:" not in count_body
    assert "let sta = staInfoForIdx(i)" not in count_body
    assert "for i in 0'u8 ..< MAX_VIFS.uint8:" not in service_body
    assert "let vif = vifChannelForIdx(i)" not in service_body
    assert "for keepaliveStaVifIndex in 0'u8 ..< MAX_VIFS.uint8:" in keepalive_body
    assert "let vif = vifChannelForIdx(keepaliveStaVifIndex)" in keepalive_body
    assert "for i in 0'u8 ..< MAX_VIFS.uint8:" not in keepalive_body
    assert "let vif = vifChannelForIdx(i)" not in keepalive_body

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.split("proc txl_frame_desc_active", 1)[1].split(
        "proc txl_frame_rebuild_free_list", 1
    )[0]

    assert "for postponedStaIndex in 0 ..< STA_INFO_TAB_ENTRIES:" in body
    assert "let sta = staInfoForIdx(postponedStaIndex.uint8)" in body
    assert "txl_frame_list_contains(addr sta.postponedList, frameDescPointer)" in body
    for forbidden in [
        "txl_frame_list_contains(addr sta.postponedList, p)",
        "for i in 0 ..< STA_INFO_TAB_ENTRIES:",
        "let sta = staInfoForIdx(i.uint8)",
        "let staBase = cast[uint](addr sta_info_tab[0])",
        "staInfoAt(staBase + i.uint * STA_ENTRY_SIZE.uint)",
        "cast[uint](addr sta_info_tab[0]) +",
    ]:
        assert forbidden not in body


def test_wifi_tpc_update_vif_tx_power_uses_typed_sta_list_overlay():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc tpc_update_vif_tx_power*", 1)[1].split(
        "proc tpc_get_vif_tx_power_vs_rate*", 1
    )[0]

    assert "var staNode = vif.postponedStaHead" in body
    assert "let sta = staInfoAt(staNode)" in body
    assert "sta.txPolicyUpdateFlags[0] = sta.txPolicyUpdateFlags[0] or StaTxPolicyUpdateTxPower" in body
    assert "staNode = cast[pointer](sta.link.next)" in body
    assert "let vifU = cast[uint](vifEntry)" not in body
    assert "cast[ptr pointer](vifU + 340)" not in body
    assert "cast[ptr uint8](staNodeU + 334)" not in body


def test_wifi_ap_start_uses_vif_overlay_for_channel_and_security():
    wifi_fw = wifi_fw_policy_source()

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
    assoc_body = wifi_fw.rsplit("proc apm_assoc_req_handler*", 1)[1].split(
        "proc apm_auth_handler*", 1
    )[0]
    sta_add_body = wifi_fw.rsplit("proc apm_sta_add*", 1)[1].split(
        "proc apm_sta_remove*", 1
    )[0]
    sta_delete_body = wifi_fw.rsplit("proc apm_sta_delete*", 1)[1].split(
        "proc apm_sta_fw_delete*", 1
    )[0]
    aid_list_delete_body = wifi_fw.rsplit("proc aidListDelete", 1)[1].split(
        "proc apm_tx_cfm_handler*", 1
    )[0]
    sta_del_cfm_layout = wifi_fw.split(
        "ApmStaDelCfmPayload {.packed.} = object", 1
    )[1].split("ApmStaAddCfmParamView {.packed.} = object", 1)[0]
    sta_del_ind_layout = wifi_fw.split(
        "ApmStaDelIndPayload {.packed.} = object", 1
    )[1].split("ApmStaAddIndPayload {.packed.} = object", 1)[0]
    sta_add_ind_layout = wifi_fw.split(
        "ApmStaAddIndPayload {.packed.} = object", 1
    )[1].split("ApmConfMaxStaReqPayload {.packed.} = object", 1)[0]
    apm_start_info_layout = wifi_fw.split(
        "ApmStartInfoView {.packed.} = object", 1
    )[1].split("ApmStartChannelView {.packed.} = object", 1)[0]
    apm_start_channel_layout = wifi_fw.split(
        "ApmStartChannelView {.packed.} = object", 1
    )[1].split("ApmStartReqView {.packed.} = object", 1)[0]
    apm_start_req_layout = wifi_fw.split(
        "ApmStartReqView {.packed.} = object", 1
    )[1].split("MmBcnChangeReqPayload {.packed.} = object", 1)[0]
    scan_channel_layout = wifi_fw.split(
        "ScanChannelEntry {.packed.} = object", 1
    )[1].split("ScanStartReqPayload {.packed.} = object", 1)[0]

    assert "template vifChannelTypeByte(vif: ptr VifChannelView): ptr uint8 =\n  cast[ptr uint8](addr vif.flags)" in wifi_fw
    assert "vifChannelTypeByte(vif)[] = req.channel.chanType" in body
    assert "let embedded = apm_embedded_enabled(cast[pointer](vif))" in body
    assert "let apConfig = vifApConfig(vif)" in body
    assert "let securityState = vifSecurity(vif)" in body
    assert "let txPowerChannel = vif.operChan" in body
    assert "let channel = cast[ptr ScanChannelEntry](txPowerChannel)" in body
    assert "txPowerByte = cast[ptr uint8](addr channel.txPower)[]" in body
    assert "tpc_update_vif_tx_power(\n     cast[pointer](vif)," in body
    assert "let vifBase = cast[uint](vif)" not in body
    assert "cast[ptr uint8](vifBase + 4)" not in body
    assert "cast[ptr uint8](cast[uint](txPowerChannel) + 4)" not in body
    assert "vifSecurityAt(vifBase)" not in body
    assert "cast[pointer](vifBase)" not in body
    assert "txPowerTailPadding*: uint8" in scan_channel_layout
    assert "doAssert offsetof(ScanChannelEntry, txPowerTailPadding) == 5" in wifi_fw
    assert "reserved*: uint8" not in scan_channel_layout

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

    assert "for duplicateStaSlotIndex in 0'u ..< 5'u:" in assoc_body
    assert "let duplicateStaSlot = apmStaSlot(duplicateStaSlotIndex)" in assoc_body
    assert "for i in 0'u ..< 5'u:" not in assoc_body
    assert "let slot = apmStaSlot(i)" not in assoc_body

    for expected in [
        "ApmStartInfoView {.packed.} = object",
        "staRateSeedToBeaconTemplatePadding*: array[19, uint8]",
        "beaconIntervalToRateInfoPadding*: array[2, uint8]",
        "vifIdxToBasicRatesPadding*: array[196, uint8]",
        "doAssert offsetof(ApmStartInfoView, staRateSeedToBeaconTemplatePadding) == 13",
        "doAssert offsetof(ApmStartInfoView, beaconIntervalToRateInfoPadding) == 42",
        "doAssert offsetof(ApmStartInfoView, vifIdxToBasicRatesPadding) == 52",
        "ApmStartChannelView {.packed.} = object",
        "bandToChanTypePadding*: uint8",
        "chanTypeToPrimaryFreqPadding*: uint8",
        "primaryToCenterFreqPadding*: array[2, uint8]",
        "centerFreqToAuthTypePadding*: array[2, uint8]",
        "doAssert offsetof(ApmStartChannelView, bandToChanTypePadding) == 3",
        "doAssert offsetof(ApmStartChannelView, chanTypeToPrimaryFreqPadding) == 5",
        "doAssert offsetof(ApmStartChannelView, primaryToCenterFreqPadding) == 8",
        "doAssert offsetof(ApmStartChannelView, centerFreqToAuthTypePadding) == 12",
        "ApmStartReqView {.packed.} = object",
        "staRateSeedToChannelPadding*: uint8",
        "flagsToBeaconLengthsPadding*: array[6, uint8]",
        "beaconIntervalToBeaconFlagsPadding*: array[8, uint8]",
        "dtimPeriodToSupportedRatesPadding*: uint8",
        "doAssert offsetof(ApmStartReqView, staRateSeedToChannelPadding) == 13",
        "doAssert offsetof(ApmStartReqView, flagsToBeaconLengthsPadding) == 30",
        "doAssert offsetof(ApmStartReqView, beaconIntervalToBeaconFlagsPadding) == 42",
        "doAssert offsetof(ApmStartReqView, dtimPeriodToSupportedRatesPadding) == 67",
        "ApmStaDelCfmPayload {.packed.} = object",
        "statusTailPadding*: array[3, uint8]",
        "doAssert offsetof(ApmStaDelCfmPayload, status) == 0",
        "doAssert offsetof(ApmStaDelCfmPayload, statusTailPadding) == 1",
        "ApmStaDelIndPayload {.packed.} = object",
        "staIdxTailPadding*: uint8",
        "doAssert offsetof(ApmStaDelIndPayload, reason) == 0",
        "doAssert offsetof(ApmStaDelIndPayload, extra) == 2",
        "doAssert offsetof(ApmStaDelIndPayload, staIdx) == 4",
        "doAssert offsetof(ApmStaDelIndPayload, staIdxTailPadding) == 5",
        "ApmStaAddIndPayload {.packed.} = object",
        "capabilityAssocInfoPadding*: array[3, uint8]",
        "flagsTailPadding*: array[3, uint8]",
        "doAssert offsetof(ApmStaAddIndPayload, capabilityAssocInfoPadding) == 13",
        "doAssert offsetof(ApmStaAddIndPayload, assoc0) == 16",
        "doAssert offsetof(ApmStaAddIndPayload, flagsTailPadding) == 25",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "reserved13*",
        "reserved42*",
        "reserved52*",
    ]:
        assert forbidden not in apm_start_info_layout

    for forbidden in [
        "reserved03*",
        "reserved05*",
        "reserved08*",
        "reserved12*",
    ]:
        assert forbidden not in apm_start_channel_layout

    for forbidden in [
        "reserved13*",
        "reserved1e*",
        "reserved42*",
        "reserved43*",
    ]:
        assert forbidden not in apm_start_req_layout

    for expected in [
        "msg.rateConfig = sta.capabilityFlags",
        "msg.infoIdx = sta.infoIdx",
        "msg.vifInst = sta.instNbr",
        "msg.capability = sta.extFlag",
        "msg.assoc0 = sta.assocInfoWord0",
        "msg.assoc1 = sta.assocInfoWord1",
        "msg.flags = sta.paramFlag",
    ]:
        assert expected in sta_add_body

    for expected in [
        "let msg2 = cast[ptr ApmStaDelIndPayload](",
        "msg2.reason = reasonCode",
        "msg2.extra = extra",
        "msg2.staIdx = staIdx",
    ]:
        assert expected in sta_delete_body
    assert "for apmStaSlotIndex in 0'u32 ..< 5'u32:" in aid_list_delete_body
    assert "let aidListStaSlot = apmStaSlot(apmStaSlotIndex.uint)" in aid_list_delete_body
    assert "cast[PlatformLogFunc](logFn)(2, 0, nil, 487, apmStaSlotIndex.uint32)" in aid_list_delete_body
    assert "for i in 0'u32 ..< 5'u32:" not in aid_list_delete_body
    assert "let slot = apmStaSlot(i.uint)" not in aid_list_delete_body
    assert "let slot = apmStaSlot(apmStaSlotIndex.uint)" not in aid_list_delete_body
    assert "487, i.uint32" not in aid_list_delete_body

    assert "reserved*" not in sta_del_cfm_layout
    assert "reserved*" not in sta_del_ind_layout

    for forbidden in [
        "reserved0*",
        "reserved1*",
    ]:
        assert forbidden not in sta_add_ind_layout
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


def test_wifi_ap_management_prefix_padding_is_semantic():
    wifi_fw = wifi_fw_policy_source()

    beacon_change_body = wifi_fw.rsplit(
        "proc mm_bcn_change_req_handler*", 1
    )[1].split("proc chan_bcn_detect_start*", 1)[0]
    beacon_change_layout = wifi_fw.split(
        "MmBcnChangeReqPayload {.packed.} = object",
        1,
    )[1].split("ApmRxMgmtPrefixView {.packed.} = object", 1)[0]
    apm_rx_prefix_layout = wifi_fw.split(
        "ApmRxMgmtPrefixView {.packed.} = object",
        1,
    )[1].split("ApmAssocStaAddIndPayload {.packed.} = object", 1)[0]

    for expected in [
        "let beaconChangeReq = beaconChangeReqAt(templatePtr)",
        "let entryFrameLen = beaconChangeReq.frameLen",
        "let entryFlagByte = beaconChangeReq.flagByte",
        "let entryHdrLen = beaconChangeReq.headerLen",
        "csaOffsetsToBeaconDataPadding*: array[2, uint8]",
        "doAssert offsetof(MmBcnChangeReqPayload, csaOffsetsToBeaconDataPadding) == 10",
        "rxuHeaderToStaIdxPadding*: array[7, uint8]",
        "vifIdxToAssocFieldsPadding*: array[7, uint8]",
        "assocByte24ToAssocByte28Padding*: array[3, uint8]",
        "assocFieldsToStaMacPadding*: array[13, uint8]",
        "staMacToReasonPadding*: array[8, uint8]",
        "doAssert offsetof(ApmRxMgmtPrefixView, rxuHeaderToStaIdxPadding) == 0",
        "doAssert offsetof(ApmRxMgmtPrefixView, vifIdxToAssocFieldsPadding) == 9",
        "doAssert offsetof(ApmRxMgmtPrefixView, assocByte24ToAssocByte28Padding) == 25",
        "doAssert offsetof(ApmRxMgmtPrefixView, assocFieldsToStaMacPadding) == 29",
        "doAssert offsetof(ApmRxMgmtPrefixView, staMacToReasonPadding) == 48",
    ]:
        assert expected in wifi_fw

    assert "let entry = beaconChangeReqAt(templatePtr)" not in beacon_change_body
    assert "reserved10*" not in beacon_change_layout
    for forbidden in [
        "reserved00*",
        "reserved09*",
        "reserved25*",
        "reserved29*",
        "reserved48*",
    ]:
        assert forbidden not in apm_rx_prefix_layout


def test_wifi_ap_remove_all_sta_uses_semantic_store_index():
    ap_management = (
        ROOT / "src/bl808/wifi/main/host_ops_parts/ap_management.nim"
    ).read_text()

    body = ap_management.split("proc bl_main_apm_remove_all_sta*", 1)[1].split(
        "proc bl_main_conf_max_sta*",
        1,
    )[0]

    for expected in [
        "for remoteStaStoreIndex in 0'u ..< NxRemoteStaStoreMax:",
        "staAt(remoteStaStoreIndex)",
        "bl_main_apm_sta_delete(remoteStaStoreIndex.uint8)",
    ]:
        assert expected in body

    for forbidden in [
        "for i in 0'u ..< NxRemoteStaStoreMax:",
        "staAt(i)",
        "bl_main_apm_sta_delete(i.uint8)",
    ]:
        assert forbidden not in body


def test_wifi_ap_assoc_ind_payload_padding_is_semantic():
    wifi_fw = wifi_fw_policy_source()

    assoc_ind_layout = wifi_fw.split(
        "ApmAssocStaAddIndPayload {.packed.} = object",
        1,
    )[1].split("ApmAssocStaAddIndHtOverlay {.packed.} = object", 1)[0]

    for expected in [
        "aidToStatusPadding*: array[2, uint8]",
        "vifIdxToAssocFieldsPadding*: array[2, uint8]",
        "assocFieldsTailPadding*: array[2, uint8]",
        "doAssert offsetof(ApmAssocStaAddIndPayload, aidToStatusPadding) == 70",
        "doAssert offsetof(ApmAssocStaAddIndPayload, vifIdxToAssocFieldsPadding) == 74",
        "doAssert offsetof(ApmAssocStaAddIndPayload, assocFieldsTailPadding) == 86",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "reserved70*",
        "reserved74*",
        "reserved86*",
    ]:
        assert forbidden not in assoc_ind_layout


def test_wifi_ap_assoc_ht_overlay_padding_is_semantic():
    wifi_fw = wifi_fw_policy_source()

    ht_layout = wifi_fw.split(
        "ApmAssocStaAddIndHtOverlay {.packed.} = object",
        1,
    )[1].split("MmTimerView {.packed.} = object", 1)[0]

    for expected in [
        "assocIndBaseToHtCapPadding*: array[20, uint8]",
        "capInfoToExtendedCapPadding*: array[18, uint8]",
        "extendedCapToTxBfPadding*: array[2, uint8]",
        "doAssert offsetof(ApmAssocStaAddIndHtOverlay, assocIndBaseToHtCapPadding) == 0",
        "doAssert offsetof(ApmAssocStaAddIndHtOverlay, capInfoToExtendedCapPadding) == 22",
        "doAssert offsetof(ApmAssocStaAddIndHtOverlay, extendedCapToTxBfPadding) == 42",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "reserved00*",
        "reserved22*",
        "reserved42*",
    ]:
        assert forbidden not in ht_layout


def test_wifi_mm_state_handlers_use_vif_overlays():
    wifi_fw = wifi_fw_policy_source()

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
        "let securityState = vifSecurity(vif)",
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


def test_wifi_mm_payload_padding_fields_are_semantic():
    wifi_fw = wifi_fw_policy_source()

    def layout_between(start, end):
        return wifi_fw.split(start, 1)[1].split(end, 1)[0]

    ps_options_layout = layout_between(
        "MmSetPsOptionsReqPayload {.packed.} = object",
        "MmSetIdleReqPayload",
    )
    connection_loss_layout = layout_between(
        "MmConnectionLossIndPayload {.packed.} = object",
        "MmPsChangeIndPayload",
    )
    beacon_int_layout = layout_between(
        "MmSetBeaconIntReqPayload {.packed.} = object",
        "MmSetBasicRatesReqPayload",
    )
    basic_rates_layout = layout_between(
        "MmSetBasicRatesReqPayload {.packed.} = object",
        "MmSetEdcaReqPayload",
    )
    edca_layout = layout_between(
        "MmSetEdcaReqPayload {.packed.} = object",
        "MmSetVifStateReqPayload",
    )
    channel_cfm_layout = layout_between(
        "MmSetChannelCfmPayload {.packed.} = object",
        "MeAddBaReqParamView",
    )
    sta_add_layout = layout_between(
        "MmStaAddReqPayload {.packed.} = object",
        "MmStaDelReqPayload",
    )
    tbtt_layout = layout_between(
        "MmPrimaryTbttIndPayload {.packed.} = object",
        "MmRemainOnChannelCfmPayload",
    )
    chan_update_layout = layout_between(
        "MmChanCtxtUpdatePayload {.packed.} = object",
        "ChanConnLessDelayReqPayload",
    )
    conn_less_layout = layout_between(
        "ChanConnLessDelayReqPayload {.packed.} = object",
        "MeSetPsDisableReqPayload",
    )

    for expected in [
        "vifIdxListenIntervalPadding*: uint8",
        "optionsTailPadding*: uint8",
        "doAssert offsetof(MmConnectionLossIndPayload, vifIdxTailPadding) == 3",
        "doAssert offsetof(MmSetBeaconIntReqPayload, vifIdxTailPadding) == 3",
        "bandTailPadding*: array[2, uint8]",
        "doAssert offsetof(MmSetBasicRatesReqPayload, bandTailPadding) == 6",
        "doAssert offsetof(MmSetEdcaReqPayload, vifIdxTailPadding) == 7",
        "doAssert offsetof(MmSetChannelCfmPayload, statusTailPadding) == 1",
        "doAssert offsetof(MmSetPsOptionsReqPayload, vifIdxListenIntervalPadding) == 1",
        "doAssert offsetof(MmSetPsOptionsReqPayload, optionsTailPadding) == 5",
        "vifQuickConnPadding*: array[11, uint8]",
        "quickConnTailPadding*: uint16",
        "doAssert offsetof(MmStaAddReqPayload, vifQuickConnPadding) == 14",
        "doAssert offsetof(MmStaAddReqPayload, quickConnTailPadding) == 26",
        "staIdxTbttPadding0*: uint8",
        "staIdxTbttPadding1*: uint8",
        "doAssert offsetof(MmPrimaryTbttIndPayload, staIdxTbttPadding0) == 1",
        "doAssert offsetof(MmPrimaryTbttIndPayload, staIdxTbttPadding1) == 2",
        "ctxtIdxBandPadding*: uint8",
        "txPowerTailPadding*: uint8",
        "doAssert offsetof(MmChanCtxtUpdatePayload, ctxtIdxBandPadding) == 1",
        "doAssert offsetof(MmChanCtxtUpdatePayload, txPowerTailPadding) == 11",
        "bandDurationPadding*: uint16",
        "chanDefTailPadding*: uint16",
        "doAssert offsetof(ChanConnLessDelayReqPayload, bandDurationPadding) == 2",
        "doAssert offsetof(ChanConnLessDelayReqPayload, chanDefTailPadding) == 18",
    ]:
        assert expected in wifi_fw

    for forbidden in ["reserved0*: uint8", "reserved1*: uint8"]:
        assert forbidden not in ps_options_layout
        assert forbidden not in tbtt_layout
        assert forbidden not in chan_update_layout
    assert "reserved*: uint8" not in connection_loss_layout
    assert "reserved*: uint8" not in beacon_int_layout
    assert "reserved*: array[2, uint8]" not in basic_rates_layout
    assert "reserved*: uint8" not in edca_layout
    assert "reserved*: uint8" not in channel_cfm_layout
    assert "reserved1*: array[11, uint8]" not in sta_add_layout
    assert "reserved2*: uint16" not in sta_add_layout
    assert "reserved0*: uint16" not in conn_less_layout
    assert "reserved1*: uint16" not in conn_less_layout


def test_wifi_tim_update_uses_vif_overlay_fields():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc mm_tim_update_proceed*", 1)[1].split(
        "proc mm_connection_loss_ind_handler*", 1
    )[0]

    for expected in [
        "let vif = vifChannelForIdx(vifIdx)",
        "let timBitmapByteOffset = (aid shr 3).uint",
        "let bitmapByte = cast[ptr uint8](bitmapBase + timBitmapByteOffset)",
        "vif.timFlags = 1",
        "vif.timCount = timCount + 1",
        "vif.timMin = alignedByte",
        "vif.timMax = timBitmapByteOffset.uint8",
        "timDesc.bitmapEnd = cast[pointer](bitmapBase + timBitmapByteOffset)",
        "vif.timLength = timLen",
    ]:
        assert expected in body

    for forbidden in [
        "let byteIdx =",
        "byteIdx.uint8",
        "bitmapBase + byteIdx",
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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    txl_buffer_env_layout = wifi_fw.split(
        "TxlBufferEnvView {.packed.} = object", 1
    )[1].split("MacDataFrameHeaderView {.packed.} = object", 1)[0]
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
        "bufferEnvBaseToBackupQueuesPadding*: array[180, uint8]",
        "backupQueues*: array[5, TxlBackupQueueView]",
        "doAssert sizeof(TxlBackupQueueView) == 8",
        "doAssert offsetof(TxlBackupQueueView, first) == 0",
        "doAssert offsetof(TxlBackupQueueView, last) == 4",
        "doAssert offsetof(TxlBufferEnvView, bufferEnvBaseToBackupQueuesPadding) == 0",
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
    assert "reserved00*" not in txl_buffer_env_layout


def test_wifi_txl_payload_backup_uses_typed_link_rate_fields():
    wifi_fw = wifi_fw_policy_source()

    host_tx_link_layout = wifi_fw.split(
        "HostTxLinkDescView {.packed.} = object", 1
    )[1].split("HostTxInternalLinkNodeView {.packed.} = object", 1)[0]
    host_tx_internal_link_layout = wifi_fw.split(
        "HostTxInternalLinkNodeView {.packed.} = object", 1
    )[1].split("HostTxBufferedLinkView {.packed.} = object", 1)[0]
    host_tx_buffered_link_layout = wifi_fw.split(
        "HostTxBufferedLinkView {.packed.} = object", 1
    )[1].split("HostTxAuxWordsView {.packed.} = object", 1)[0]
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
        "ackPolicyControl*: uint32",
        "retryLimitControl*: uint32",
        "secondaryTxHwDescPtr*: uint32",
        "frameLenToRetryLimitPadding*: uint32",
        "chainedThdToAckPolicyPadding0*: uint32",
        "chainedThdToAckPolicyPadding1*: uint32",
        "chainedThdToAckPolicyPadding2*: uint32",
        "doAssert offsetof(HostTxHwDescView, secondaryTxHwDescPtr) == 8",
        "doAssert offsetof(HostTxHwDescView, secondaryDescToStatusPadding) == 12",
        "doAssert offsetof(HostTxHwDescView, frameLenToRetryLimitPadding) == 32",
        "doAssert offsetof(HostTxHwDescView, retryLimitControl) == 36",
        "doAssert offsetof(HostTxHwDescView, chainedThdToAckPolicyPadding0) == 44",
        "doAssert offsetof(HostTxHwDescView, chainedThdToAckPolicyPadding1) == 48",
        "doAssert offsetof(HostTxHwDescView, chainedThdToAckPolicyPadding2) == 52",
        "doAssert offsetof(HostTxHwDescView, ackPolicyControl) == 56",
        "doAssert offsetof(TxBufferControlView, ackPolicyControl) == 52",
        "doAssert offsetof(TxBufferControlView, retryLimitControl) == 56",
        "doAssert offsetof(HostTxLinkDescView, ackPolicyControl) == 308",
        "doAssert offsetof(HostTxLinkDescView, retryLimitControl) == 312",
        "doAssert offsetof(HostTxInternalLinkNodeView, ackPolicyControl) == 308",
        "doAssert offsetof(HostTxInternalLinkNodeView, retryLimitControl) == 312",
        "doAssert offsetof(HostTxBufferedLinkView, ackPolicyControl) == 308",
        "doAssert offsetof(HostTxBufferedLinkView, retryLimitControl) == 312",
        "linkDescBaseToHeaderLenPadding*: uint32",
        "headerLenToHeaderThdPadding*: array[64, uint8]",
        "payloadThdToRateTemplatePadding*: array[84, uint8]",
        "internalLinkBaseToHeaderLenPadding*: uint32",
        "headerLenToQueueLinksPadding*: array[8, uint8]",
        "txDescToHeaderThdPadding*: array[48, uint8]",
        "bufferedLinkBaseToHeaderLenPadding*: uint32",
        "padLenToQueueLinksPadding*: uint32",
        "payloadThdToUserIdxPadding*: array[80, uint8]",
        "userIdxToRateTemplatePadding*: array[3, uint8]",
        "doAssert offsetof(HostTxLinkDescView, linkDescBaseToHeaderLenPadding) == 0",
        "doAssert offsetof(HostTxLinkDescView, headerLenToHeaderThdPadding) == 8",
        "doAssert offsetof(HostTxLinkDescView, payloadThdToRateTemplatePadding) == 172",
        "doAssert offsetof(HostTxInternalLinkNodeView, internalLinkBaseToHeaderLenPadding) == 0",
        "doAssert offsetof(HostTxInternalLinkNodeView, headerLenToQueueLinksPadding) == 8",
        "doAssert offsetof(HostTxInternalLinkNodeView, txDescToHeaderThdPadding) == 24",
        "doAssert offsetof(HostTxInternalLinkNodeView, payloadThdToRateTemplatePadding) == 172",
        "doAssert offsetof(HostTxBufferedLinkView, bufferedLinkBaseToHeaderLenPadding) == 0",
        "doAssert offsetof(HostTxBufferedLinkView, padLenToQueueLinksPadding) == 12",
        "doAssert offsetof(HostTxBufferedLinkView, txDescToHeaderThdPadding) == 24",
        "doAssert offsetof(HostTxBufferedLinkView, payloadThdToUserIdxPadding) == 172",
        "doAssert offsetof(HostTxBufferedLinkView, userIdxToRateTemplatePadding) == 253",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let forceRate = hostTxRateTemplate(forceLink)",
        "forceRate.txPower = NimFwForcedMgmtTxPower.int32",
        "forceRate.retryTxPowerControl0 = NimFwForcedMgmtTxPower",
        "forceRate.retryTxPowerControl1 = NimFwForcedMgmtTxPower",
        "forceRate.retryTxPowerControl2 = NimFwForcedMgmtTxPower",
        "let vif = vifChannelForIdx(actual.vifIdx)",
        "let protFlags = vif.timFlags",
        "vif.timFlags = protFlags or 2",
        "vif.timFlags = protFlags and not 2'u8",
        "thd.ackPolicyControl = linkDesc.ackPolicyControl",
        "thd.retryLimitControl = linkDesc.retryLimitControl",
        "nimFwDbgProbePayLinkHeaderLen = probeLink.headerLen",
        "nimFwDbgProbePayLinkTxControlXor =\n            probeLink.ackPolicyControl xor probeLink.retryLimitControl",
        "nimFwDbgProbePayHwConfirmDescPtr = probeHw.txConfirmDescPtr",
        "nimFwDbgProbePayHwMagic = probeHw.magic",
        "nimFwDbgProbePayHwSecondaryDescPtr = probeHw.secondaryTxHwDescPtr",
        "nimFwDbgProbePayHwSecondaryStatusPadding =\n            probeHw.secondaryDescToStatusPadding",
        "let macFrameControlDurationWord =",
        "macHdrTrace.frameControl.uint32 or (macHdrTrace.duration.uint32 shl 16)",
        "template hostTxThdAt(p: pointer): ptr HostTxThdEntryView",
        "hostTxThdAt(listFirst).next = thdLink",
        "nimFwTrace2U32(\"[WIFI-NIMFW] pay_rate \",\n                         linkDesc.ackPolicyControl,\n                         linkDesc.retryLimitControl)",
    ]:
        assert expected in wifi_fw if expected.startswith("template ") else expected in body

    assert "let secondaryTxHwDesc = cast[pointer](hwDesc.secondaryTxHwDescPtr.uint)" in tx_trigger_body
    assert "let secStatus = cast[int32](hostTxHwDescAt(secondaryTxHwDesc).controlFlags)" in tx_trigger_body

    for forbidden in [
        "template hostTxLinkWord(",
        "template hostTxLinkWordAt(",
        "hostTxLinkWord(",
        "hostTxLinkWordAt(",
        "thdWord36Patch",
        "thdWord56Patch",
        "word36Patch",
        "word56Patch",
        "secondaryThdPtr",
        "txHwReserved12",
        "txHwReserved32",
        "txHwReserved44",
        "txHwReserved48",
        "txHwReserved52",
        "cast[ptr uint32](cast[uint](link) + byteOff)",
        "hostTxLinkWordAt(forceLink, 292'u)",
        "hostTxLinkWordAt(forceLink, 296'u)",
        "hostTxLinkWordAt(forceLink, 300'u)",
        "hostTxLinkWordAt(forceLink, 304'u)",
        "cast[ptr pointer](cast[uint](listFirst) + 4)",
        "linkDesc.word308",
        "linkDesc.word312",
        "bufLink.word308",
        "bufLink.word312",
        "forceRate.word40",
        "forceRate.word44",
        "forceRate.word48",
        "nimFwDbgProbePayHw0",
        "nimFwDbgProbePayHw1",
        "nimFwDbgProbePayHw2",
        "nimFwDbgProbePayHw3",
        "nimFwDbgProbePayLink0",
        "nimFwDbgProbePayLink1",
        "macHdrWord0",
    ]:
        assert forbidden not in wifi_fw

    assert re.search(r"\b[a-zA-Z_]\w*Word\d+Patch\*\s*:", wifi_fw) is None

    assert "cast[ptr int32](cast[uint](secondaryTxHwDesc) + 60)" not in tx_trigger_body

    for forbidden in [
        "reserved0*",
        "reserved8*",
        "reserved172*",
    ]:
        assert forbidden not in host_tx_link_layout
    for forbidden in [
        "reserved0*",
        "reserved8*",
        "reserved24*",
        "reserved172*",
    ]:
        assert forbidden not in host_tx_internal_link_layout
    for forbidden in [
        "reserved0*",
        "reserved12*",
        "reserved24*",
        "reserved172*",
        "reserved253*",
    ]:
        assert forbidden not in host_tx_buffered_link_layout

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifEntry = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifEntry)",
    ]:
        assert forbidden not in body


def test_wifi_txl_env_dump_uses_typed_descriptor_overlays():
    wifi_fw = wifi_fw_policy_source()

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
        "descriptorStatus*: uint32",
        "doAssert offsetof(HostTxDescView, link) == 0",
        "doAssert offsetof(HostTxDescView, descriptorStatus) == 4",
        "TxDumpRateDescView {.packed.} = object",
        "rateDumpHeader0*: uint32",
        "rateDumpHeader1*: uint32",
        "rateDumpHeader2*: uint32",
        "rateDumpHeader3*: uint32",
        "primaryPolicyWords*: array[4, uint32]",
        "secondaryPolicyWords*: array[4, uint32]",
        "TxDumpBufferDescView {.packed.} = object",
        "bufferDumpHeader*: uint32",
        "bufferDumpTail*: uint32",
        "template txDumpRateDescAt(p: pointer): ptr TxDumpRateDescView",
        "template txDumpBufferDescAt(p: pointer): ptr TxDumpBufferDescView",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let curTrace = chanCtxtAt(curCtxtTrace)",
        "currentContextStatusTrace = curTrace.status",
        "currentContextIndexTrace = curTrace.contextIndexOrMarker",
        "currentContextAltIndexTrace = curTrace.altIdx",
    ]:
        assert expected in push_int_body

    for expected in [
        "let desc = hostTxDescAt(curDesc)",
        "let thd = desc.hwDesc",
        "let hw = hostTxHwDescAt(thd)",
        "let thdStatus = hw.confirmStatus",
        "curDesc = desc.link.next",
        "let descriptorStatus = desc.descriptorStatus",
        "let thdDataLen = hw.frameLen",
        "let ackPolicyControl = hw.ackPolicyControl",
        "let thdControlFlags = hw.controlFlags",
        "let rateThdPtr = hw.chainedThd",
        "let rateDumpDesc = txDumpRateDescAt(rateThdPtr)",
        "rateDumpDesc.rateDumpHeader0",
        "rateDumpDesc.rateDumpHeader1",
        "rateDumpDesc.rateDumpHeader2",
        "rateDumpDesc.rateDumpHeader3",
        "for primaryPolicyWord in rateDumpDesc.primaryPolicyWords:",
        "for secondaryPolicyWord in rateDumpDesc.secondaryPolicyWords:",
        "nextRateThd = txDumpRateDescAt(nextRateThd).next",
        "let bufferDumpDesc = txDumpBufferDescAt(bufferDumpDescPtr)",
        "bufferDumpDesc.bufferDumpHeader",
        "bufferDumpDescPtr = bufferDumpDesc.next",
    ]:
        assert expected in dump_body

    for forbidden in [
        "let curUTrace = cast[uint](curCtxtTrace)",
        "cur22Trace",
        "cur23Trace",
        "cur25Trace",
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
        "rateWord0",
        "rateWord4",
        "rateWord8",
        "rateWord12",
        "policy0",
        "policy1",
        "bufferWord0",
        "bufferWord8",
    ]:
        assert forbidden not in dump_body


def test_wifi_disconnect_deauth_uses_typed_frame_overlays():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc sm_disconnect*(param: pointer)", 1)[1].split(
        "proc sm_delete_resources*", 1
    )[0]

    for expected in [
        "let connectInfo = connectInfoView(connectInfoPtr)",
        "let txDesc = hostTxDescAt(txFrame)",
        "let deauthHeader = hostTxDataHeader(txDesc)",
        "let frameBodyPtr = cast[pointer](deauthHeader)",
        "deauthHeader.seqCtrl = seqCtrl",
        "c_memcpy(addr deauthHeader.addr1[0], addr connectInfo.bssid[0], 6.csize_t)",
        "c_memcpy(addr deauthHeader.addr2[0],",
        "c_memcpy(addr deauthHeader.addr3[0], addr connectInfo.bssid[0], 6.csize_t)",
        "txDesc.vifIdx = staIdx",
        "txDesc.staInfoIdx = vif.staIdx",
        "txDesc.callback = cast[pointer](sm_disconnect_deauth_cfm)",
        "let deauthFrameControl = deauthHeader.frameControl.uint32",
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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc sm_delete_resources*", 1)[1].split(
        "proc sm_auth_assoc_send_according_chan*", 1
    )[0]
    disconnect_body = wifi_fw.rsplit("proc sm_disconnect_process*", 1)[1].split(
        "proc sm_disconnect_deauth_cfm*", 1
    )[0]
    disconnect_ind_layout = wifi_fw.split(
        "SmDisconnectIndPayload {.packed.} = object", 1
    )[1].split("SmDisconnectProcessIndPayload {.packed.} = object", 1)[0]
    disconnect_process_layout = wifi_fw.split(
        "SmDisconnectProcessIndPayload {.packed.} = object", 1
    )[1].split("SmDisconnectReasonPayload {.packed.} = object", 1)[0]

    for expected in [
        "SmDisconnectIndPayload {.packed.} = object",
        "status*: uint16",
        "reason*: uint16",
        "ftOverDsDiagnosePadding*: array[2, uint8]",
        "diagnoseFirst*: pointer",
        "doAssert SmDisconnectIndPayloadSize == 12'u32",
        "doAssert offsetof(SmDisconnectIndPayload, ftOverDsDiagnosePadding) == 6",
        "doAssert offsetof(SmDisconnectIndPayload, diagnoseFirst) == 8",
        "SmDisconnectProcessIndPayload {.packed.} = object",
        "vifIdxTailPadding*: array[11, uint8]",
        "doAssert SmDisconnectProcessIndPayloadSize == 16'u32",
        "doAssert offsetof(SmDisconnectProcessIndPayload, vifIdxTailPadding) == 5",
        "Host indications are sent by sm_connect_ind or",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let msg = cast[ptr SmDisconnectProcessIndPayload](",
        "msg.status = statusCode",
        "msg.reason = reasonCode",
        "msg.vifIdx = vifChannelAt(param).vifIdx",
    ]:
        assert expected in disconnect_body

    assert "reserved*" not in disconnect_ind_layout
    assert "reserved*" not in disconnect_process_layout

    for forbidden in [
        "ke_msg_alloc(SM_DISCONNECT_IND",
        "ke_msg_alloc(SM_CONNECT_IND_MSG",
        "ke_msg_send(discInd)",
        "ke_msg_send(connInd)",
    ]:
        assert forbidden not in body


def test_wifi_sm_deauth_send_uses_typed_frame_overlays():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
        "let authAlgoSeqTraceWord =",
        "let authStatusChallengeTraceWord =",
        "authTrace.fixed.authAlgo.uint32 or (authTrace.fixed.authSeq.uint32 shl 16)",
        "authTrace.fixed.statusCode.uint32 or",
        "(authTrace.challengeTag.uint32 shl 16) or",
        "(authTrace.challengeLen.uint32 shl 24)",
    ]:
        assert expected in auth_body

    for expected in [
        "let assocFixed = cast[ptr AssocReqFixedBodyView](assocBodyPtr)",
        "let assocCapabilityListenTraceWord =",
        "assocFixed.capabilityInfo.uint32 or (assocFixed.listenInterval.uint32 shl 16)",
        "let assocReassocBssidPrefixWord =",
        "cast[ptr uint32](addr assocFixed.reassocBssid[0])[]",
        "for vifMacByteIndex in 0 ..< 6:",
        "nimFwDbgVifMac[vifMacByteIndex] = vif.macAddr[vifMacByteIndex]",
    ]:
        assert expected in assoc_body

    for forbidden in [
        "authTraceWord0",
        "authTraceWord1",
        "assocTraceWord0",
        "assocTraceWord1",
        "ssid0",
        "bssid0",
    ]:
        assert forbidden not in wifi_fw

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
            "nimFwDbgVifMac[i] = vif.macAddr[i]",
        ]:
            assert forbidden not in body


def test_wifi_connect_ind_uses_typed_payload_overlay():
    wifi_fw = wifi_fw_policy_source()

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
    connect_ind_layout = wifi_fw.split(
        "SmConnectIndPayload {.packed.} = object", 1
    )[1].split("SmVifIdxReqPayload {.packed.} = object", 1)[0]

    for expected in [
        "SmConnectIndPayload {.packed.} = object",
        "statusCode*: uint16",
        "reasonCode*: uint16",
        "bssid*: array[6, uint8]",
        "assocIeBuffer*: array[800, uint8]",
        "assocIeChannelPadding*: array[2, uint8]",
        "chanBand*: uint8",
        "chanBandPrimFreqPadding*: uint8",
        "chanPrimFreq*: uint16",
        "chanType*: uint8",
        "chanTypeCenterFreqPadding*: uint8",
        "chanCenterFreq1*: uint32",
        "chanCenterFreq2*: uint32",
        "doAssert offsetof(SmConnectIndPayload, assocIeBuffer) == 20",
        "doAssert offsetof(SmConnectIndPayload, assocIeChannelPadding) == 820",
        "doAssert offsetof(SmConnectIndPayload, chanBand) == 822",
        "doAssert offsetof(SmConnectIndPayload, chanBandPrimFreqPadding) == 823",
        "doAssert offsetof(SmConnectIndPayload, chanTypeCenterFreqPadding) == 827",
        "template smConnectIndPayloadAt(param: pointer): ptr SmConnectIndPayload",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "reserved820*",
        "reserved823*",
        "reserved827*",
    ]:
        assert forbidden not in connect_ind_layout

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc sm_deauth_handler*", 1)[1].split(
        "proc sm_get_set_machwkey_index*", 1
    )[0]
    deauth_layout = wifi_fw.split(
        "SmDeauthFrameView {.packed.} = object", 1
    )[1].split("MfpMgmtFramePolicyView {.packed.} = object", 1)[0]

    assert "doAssert offsetof(VifChannelView, bssid) == 380" in wifi_fw
    for expected in [
        "rxuHeaderSaQueryVifPadding*: array[7, uint8]",
        "vifIdxFrameFlagsPadding*: array[18, uint8]",
        "frameFlagsSaPadding*: array[8, uint8]",
        "saBssidPadding*: array[6, uint8]",
        "bssidReasonPadding*: array[2, uint8]",
        "doAssert offsetof(SmDeauthFrameView, rxuHeaderSaQueryVifPadding) == 0",
        "doAssert offsetof(SmDeauthFrameView, vifIdxFrameFlagsPadding) == 9",
        "doAssert offsetof(SmDeauthFrameView, frameFlagsSaPadding) == 28",
        "doAssert offsetof(SmDeauthFrameView, saBssidPadding) == 42",
        "doAssert offsetof(SmDeauthFrameView, bssidReasonPadding) == 54",
    ]:
        assert expected in wifi_fw

    assert "let vif = vifChannelForIdx(vifIdx)" in body
    assert "for bssidByteIndex in 0 ..< 6:" in body
    assert "if deauth.bssid[bssidByteIndex] != vif.bssid[bssidByteIndex]:" in body
    assert "for sourceAddrByteIndex in 0 ..< 6:" in body
    assert "if deauth.sa[sourceAddrByteIndex] != vif.macAddr[sourceAddrByteIndex]:" in body
    assert "sm_disconnect_process(cast[pointer](vif), 7, reason)" in body

    for forbidden in [
        "if deauth.bssid[i] != vif.bssid[i]:",
        "if deauth.sa[i] != vif.macAddr[i]:",
    ]:
        assert forbidden not in body

    for forbidden in [
        "reserved00*",
        "reserved09*",
        "reserved28*",
        "reserved42*",
        "reserved54*",
    ]:
        assert forbidden not in deauth_layout

    for forbidden in [
        "let vifBase = cast[uint](addr vif_info_tab[0])",
        "let vifE = vifBase + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "let vif = vifChannelAt(vifE)",
        "cast[ptr uint8](vifE + 380 + i.uint)",
        "cast[ptr uint8](vifE + 380)",
        "sm_disconnect_process(cast[pointer](vifE), 7, reason)",
    ]:
        assert forbidden not in body


def test_wifi_sa_query_handler_uses_semantic_frame_overlay():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc sm_sa_query_handler*", 1)[1].split(
        "proc sm_issue_sa_query_request*", 1
    )[0]
    sa_query_layout = wifi_fw.split(
        "SmSaQueryFrameView {.packed.} = object", 1
    )[1].split("MmStaAddCfmPayload {.packed.} = object", 1)[0]

    for expected in [
        "SmSaQueryFrameView {.packed.} = object",
        "rxuHeaderStaIdxPadding*: array[7, uint8]",
        "vifIdxSaQueryActionPadding*: array[24, uint8]",
        "doAssert offsetof(SmSaQueryFrameView, rxuHeaderStaIdxPadding) == 0",
        "doAssert offsetof(SmSaQueryFrameView, vifIdxSaQueryActionPadding) == 9",
        "doAssert offsetof(SmSaQueryFrameView, action) == 33",
        "let frame = smSaQueryFrameView(param)",
        "let vifIdx = frame.vifIdx",
        "let staIdx = frame.staIdx",
        "let action = frame.action",
        "let transId = frame.transId",
    ]:
        assert expected in wifi_fw if "proc " not in expected else expected in body

    for forbidden in [
        "reserved00*",
        "reserved09*",
    ]:
        assert forbidden not in sa_query_layout


def test_wifi_machw_key_index_uses_typed_vif_overlay():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc sm_get_set_machwkey_index*", 1)[1].split(
        "proc sm_handle_eapol_input*", 1
    )[0]
    key_index_layout = wifi_fw.split(
        "VifMachwKeyIndexOverlay {.packed.} = object", 1
    )[1].split("VifHtCapabilitiesOverlay {.packed.} = object", 1)[0]

    for expected in [
        "VifMachwKeyIndexOverlay {.packed.} = object",
        "vifBaseToMachwKeyIndexesPadding*: array[172, uint8]",
        "primaryPairwise*: uint8",
        "secondaryPairwise*: uint8",
        "group*: uint8",
        "doAssert offsetof(VifMachwKeyIndexOverlay, vifBaseToMachwKeyIndexesPadding) == 0",
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

    assert "reserved00*" not in key_index_layout

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc rxuProtectedKey", 1)[1].split(
        "proc rxu_cntrl_protected_handle*", 1
    )[0]

    for expected in [
        "VifRxProtectedKeyTableOverlay {.packed.} = object",
        "slots*: UncheckedArray[VifKeySlotView]",
        "doAssert offsetof(VifRxProtectedKeyTableOverlay, slots) == 528",
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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc sta_mgmt_init*", 1)[1].split(
        "proc sta_mgmt_register*", 1
    )[0]

    for expected in [
        "var freeStaIndex = 0'u8",
        "while freeStaIndex < STA_MGMT_FREE_STAS.uint8:",
        "let sta = staInfoForIdx(freeStaIndex)",
        "sta_mgmt_entry_init(cast[pointer](sta))",
        "co_list_push_back(addr sta_info_env, cast[ptr CoListHdr](sta))",
        "let bcStaVif0 = staInfoForIdx(STA_MGMT_FREE_STAS.uint8)",
        "bcStaVif0.instNbr = 0",
        "bcStaVif0.controlPortState = 0",
        "bcStaVif0.txPolicy = cast[pointer](txBufferControlBcmcDescAt(0))",
        "bcStaVif0.keyMat = cast[pointer](vifKeyPointers(vifChannelForIdx(0)))",
        "let bcStaVif1 = staInfoForIdx(STA_MGMT_FREE_STAS.uint8 + 1'u8)",
        "bcStaVif1.instNbr = 1",
        "bcStaVif1.controlPortState = 0",
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
        "var idx = 0'u8",
        "let sta = staInfoForIdx(idx)",
    ]:
        assert forbidden not in body


def test_wifi_list_node_paths_use_semantic_entry_names():
    wifi_fw = wifi_fw_policy_source()

    first_ap_body = wifi_fw.rsplit("proc vif_mgmt_get_first_ap_inf*", 1)[1].split(
        "proc vif_mgmt_statistic_dump*", 1
    )[0]
    sta_register_body = wifi_fw.rsplit("proc sta_mgmt_register*", 1)[1].split(
        "proc sta_mgmt_unregister*", 1
    )[0]

    for expected in [
        "var activeVifListNode = cast[pointer](env.activeList.first)",
        "while activeVifListNode != nil:",
        "let vif = vifChannelAt(activeVifListNode)",
        "return activeVifListNode",
        "activeVifListNode = vif.next",
    ]:
        assert expected in first_ap_body

    for expected in [
        "let freeStaInfoListNode = co_list_pop_front(addr sta_info_env)",
        "if freeStaInfoListNode == nil:",
        "let staEntry = cast[uint](freeStaInfoListNode)",
    ]:
        assert expected in sta_register_body

    for forbidden in [
        "var entry = cast[pointer](env.activeList.first)",
        "while entry != nil:",
        "return entry",
        "let entry = co_list_pop_front(addr sta_info_env)",
        "let staEntry = cast[uint](entry)",
    ]:
        assert forbidden not in first_ap_body
        assert forbidden not in sta_register_body


def test_wifi_assoc_bssid_accessor_uses_vif_bssid_overlay():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc scanu_start_cfm_handler*", 1)[1].split(
        "proc scanu_join_req_handler*", 1
    )[0]

    assert "doAssert offsetof(VifChannelView, macAddr) == 80" in wifi_fw
    assert "let vif = vifChannelAt(vifEntry)" in body
    assert "var selectedBssResult: pointer = nil" in body
    assert "var selectedBssChannel: pointer = nil" in body
    assert "discard sm_get_bss_params(addr selectedBssResult, addr selectedBssChannel)" in body
    assert "let vifMacAddr = cast[pointer](addr vif.macAddr[0])" in body
    assert "sm_join_bss(vifMacAddr, selectedBssResult, selectedBssChannel, 0)" in body

    for forbidden in [
        "let vifMac = cast[pointer](cast[uint](vifEntry) + 80)",
        "cast[pointer](cast[uint](vifEntry) + 80)",
        "sm_join_bss(vifMac,",
        "resultPtr",
        "chanPtr",
    ]:
        assert forbidden not in body


def test_wifi_scan_join_uses_vif_ht_key_overlays():
    wifi_fw = wifi_fw_policy_source()

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
        "let apConfig = vifApConfig(vif)",
        "let htCap = vifHtCapabilities(vif).ampduParams",
        "vifKeyPointers(vif).flags = connectFlags",
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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc me_sta_add_req_handler*", 1)[1].split(
        "proc me_sta_del_req_handler*", 1
    )[0]
    sta_add_req_layout = wifi_fw.split(
        "MeStaAddReqPayload {.packed.} = object", 1
    )[1].split("MeRcSetRateReqPayload {.packed.} = object", 1)[0]
    sta_add_cfm_layout = wifi_fw.split(
        "MeStaAddCfmPayload {.packed.} = object", 1
    )[1].split("MeConfigReqPayload {.packed.} = object", 1)[0]

    for expected in [
        "MeStaAddCfmPayload {.packed.} = object",
        "statusTailPadding*: array[6, uint8]",
        "doAssert offsetof(MeStaAddCfmPayload, staIdx) == 0",
        "doAssert offsetof(MeStaAddCfmPayload, status) == 1",
        "doAssert offsetof(MeStaAddCfmPayload, statusTailPadding) == 2",
        "MeStaAddReqPayload {.packed.} = object",
        "supportedRatesCapBlockPadding*: uint8",
        "capBlockFlagsPadding*: array[12, uint8]",
        "capFlagsBeaconIntervalPadding*: array[3, uint8]",
        "uapsdStaIndexPadding*: uint8",
        "doAssert offsetof(MeStaAddReqPayload, supportedRatesCapBlockPadding) == 19",
        "doAssert offsetof(MeStaAddReqPayload, capBlockFlagsPadding) == 52",
        "doAssert offsetof(MeStaAddReqPayload, capFlagsBeaconIntervalPadding) == 65",
        "doAssert offsetof(MeStaAddReqPayload, uapsdStaIndexPadding) == 72",
        "doAssert offsetof(VifHtCapabilitiesOverlay, capInfo) == 0",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let cfm = cast[ptr MeStaAddCfmPayload](",
        "cfm.status = addResult",
        "let assignedStaIdx = cfm.staIdx",
        "let vif = vifChannelForIdx(staIdx)",
        "me_set_sta_ht_vht_param(cast[pointer](sta),\n                            cast[pointer](vifHtCapabilities(vif)))",
        "let keyFlagByte = (vifKeyPointers(vif).flags and 0xFF).uint8",
        "let controlPortState = 2'u8 - (keyFlagByte and 1)",
        "sta.controlPortState = controlPortState",
        "sta.rateWord = vif.apStartBeaconInterval",
    ]:
        assert expected in body

    for forbidden in [
        "reserved19*",
        "reserved52*",
        "reserved65*",
        "reserved72*",
    ]:
        assert forbidden not in sta_add_req_layout

    assert "reserved*" not in sta_add_cfm_layout

    for forbidden in [
        "let vifEntryBase = cast[uint](addr vif_info_tab[0]) + staIdx.uint * 1512'u",
        "let vif = vifChannelAt(vifEntryBase)",
        "cast[pointer](vifEntryBase + 348)",
        "cast[ptr uint8](vifEntryBase + 0x5D8)",
        "cast[ptr uint16](vifEntryBase + 0x150)",
    ]:
        assert forbidden not in body


def test_wifi_me_config_request_uses_semantic_layout_padding():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc me_config_req_handler*", 1)[1].split(
        "proc me_sta_add_req_handler*", 1
    )[0]
    me_config_layout = wifi_fw.split(
        "MeConfigReqPayload {.packed.} = object", 1
    )[1].split("MeStaAddReqPayload {.packed.} = object", 1)[0]
    status4_layout = wifi_fw.split(
        "Status4CfmPayload {.packed.} = object", 1
    )[1].split("SmDisconnectIndPayload {.packed.} = object", 1)[0]

    for expected in [
        "Status4CfmPayload {.packed.} = object",
        "statusTailPadding*: array[3, uint8]",
        "doAssert offsetof(Status4CfmPayload, status) == 0",
        "doAssert offsetof(Status4CfmPayload, statusTailPadding) == 1",
        "MeConfigReqPayload {.packed.} = object",
        "htCapsDefKeyPadding*: array[12, uint8]",
        "htSuppPsOnPadding*: uint8",
        "doAssert offsetof(MeConfigReqPayload, htCapsDefKeyPadding) == 32",
        "doAssert offsetof(MeConfigReqPayload, defKey) == 44",
        "doAssert offsetof(MeConfigReqPayload, htSuppPsOnPadding) == 47",
        "doAssert offsetof(MeConfigReqPayload, psOn) == 48",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let req = meConfigReqView(param)",
        "let htSupp = req.htSupp",
        "discard c_memcpy(addr me.htCaps[0], addr req.htCaps[0], 32.csize_t)",
        "me.defKey = req.defKey",
        "let psOn = req.psOn",
        "me.psOn = psOn",
    ]:
        assert expected in body

    for forbidden in [
        "reserved32*",
        "reserved47*",
    ]:
        assert forbidden not in me_config_layout

    assert "reserved*" not in status4_layout


def test_wifi_rxu_pn_check_uses_typed_replay_counters():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc rxu_cntrl_check_pn*", 1)[1].split(
        "proc rxu_cntrl_desc_prepare*", 1
    )[0]
    key_slot_layout = wifi_fw.split(
        "VifKeySlotView {.packed.} = object", 1
    )[1].split("TkipMicKeyAreaView {.packed.} = object", 1)[0]
    key_replay_layout = wifi_fw.split(
        "KeyReplayCounterView {.packed.} = object", 1
    )[1].split("ReplayCounterWindowSlot {.packed.} = object", 1)[0]
    replay_window_slot_layout = wifi_fw.split(
        "ReplayCounterWindowSlot {.packed.} = object", 1
    )[1].split("ReplayCounterStateView {.packed.} = object", 1)[0]
    rx_protected_key_table_layout = wifi_fw.split(
        "VifRxProtectedKeyTableOverlay {.packed.} = object", 1
    )[1].split("VifKeySlotTableOverlay {.packed.} = object", 1)[0]

    for expected in [
        "KeyReplayCounterView {.packed.} = object",
        "replayWindowSlotBytes*: array[8, uint8]",
        "ReplayCounterWindowSlot {.packed.} = object",
        "pnSnapshot*: array[8, uint8]",
        "VifKeySlotView {.packed.} = object",
        "replayCounters*: array[8, KeyReplayCounterView]",
        "cipherType*: uint8",
        "hasRxPn*: uint8",
        "hasRxPnTailPadding*: array[3, uint8]",
        "vifBaseToProtectedKeySlotsPadding*: array[528, uint8]",
        "doAssert offsetof(KeyReplayCounterView, replayWindowSlotBytes) == 8",
        "doAssert offsetof(ReplayCounterWindowSlot, pnSnapshot) == 0",
        "doAssert offsetof(ReplayCounterWindowSlot, valid) == 8",
        "doAssert offsetof(VifRxProtectedKeyTableOverlay, vifBaseToProtectedKeySlotsPadding) == 0",
        "doAssert offsetof(VifKeySlotView, replayCounters) == 0",
        "doAssert offsetof(VifKeySlotView, cipherType) == 152",
        "doAssert offsetof(VifKeySlotView, hasRxPn) == 156",
        "doAssert offsetof(VifKeySlotView, hasRxPnTailPadding) == 157",
        "doAssert sizeof(KeyReplayCounterView) == 16",
    ]:
        assert expected in wifi_fw

    for expected in [
        "let key = cast[ptr VifKeySlotView](secKeyPtr)",
        "let hasRxPn = key.hasRxPn",
        "if hasRxPn == 0:",
        "let replayCounter = addr key.replayCounters[tid.int]",
        "let storedHi = replayCounter.pnHigh",
        "let storedLo = replayCounter.pnLow",
        "replayCounter.pnLow = nextLo",
        "replayCounter.pnHigh = nextHi",
        "let replayCounterEntry = addr key.replayCounters[adjTid.int]",
        "let replayCounterEntryAddr = cast[uint](replayCounterEntry)",
        "nimFwDbgRxuPnStoredLo = replayCounterEntry.pnLow",
        "nimFwDbgRxuPnStoredHi = replayCounterEntry.pnHigh",
    ]:
        assert expected in body

    for forbidden in [
        "let keyAddr = cast[uint](secKeyPtr)",
        "cast[ptr uint8](keyAddr + 156)[]",
        "let tidOffset = tid.uint * 16",
        "let entryAddr = keyAddr + tidOffset",
        "let entryAddr = keyAddr + adjTid.uint * 16",
        "let entry = addr key.replayCounters[tid.int]",
        "let entry = addr key.replayCounters[adjTid.int]",
        "entry.pnLow = nextLo",
        "entry.pnHigh = nextHi",
        "let keyType = key.cipherType",
        "if keyType == 0:",
        "cast[ptr uint32](entryAddr)[]",
        "cast[ptr uint32](entryAddr + 4)[]",
        "nimFwDbgRxuPnStoredLo = cast[ptr uint32](entryAddr)[]",
        "nimFwDbgRxuPnStoredHi = cast[ptr uint32](entryAddr + 4)[]",
    ]:
        assert forbidden not in body

    assert "reserved157*" not in key_slot_layout
    assert "reserved8*" not in key_replay_layout
    assert "reserved00*" not in replay_window_slot_layout
    assert "reserved00*" not in rx_protected_key_table_layout


def test_wifi_rx_michael_mic_read_uses_typed_word_overlay():
    wifi_fw = wifi_fw_policy_source()

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
        "var micPayloadBuffer = rxFrameBufferChainAt(swdesc.bufferChain)",
        "while dataLen > 0 and micPayloadBuffer != nil:",
        "let micPayloadBase = cast[uint](micPayloadBuffer.frameData)",
        "var micSegmentStart = micPayloadBase + skipBytes.uint",
        "var micSegmentLen = dataLen + skipBytes",
        "micPayloadBuffer = rxFrameBufferChainAt(micPayloadBuffer.next)",
        "let micWords = rxMicWordsAt(micPtr)",
        "rxMic[0] = micWords.lo",
        "rxMic[1] = micWords.hi",
    ]:
        assert expected in body

    for forbidden in [
        "curBuf",
        "bufPayload",
        "segStart",
        "segLen",
    ]:
        assert forbidden not in body

    for forbidden in [
        "cast[ptr uint32](micPtr)[]",
        "cast[ptr uint32](micPtr + 4)[]",
    ]:
        assert forbidden not in body


def test_wifi_tx_sequence_assignment_uses_typed_sta_overlay():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc txu_cntrl_push*", 1)[1].split(
        "proc txu_cntrl_tkip_mic_append*", 1
    )[0]

    for expected in [
        "StaTxSequenceOverlay {.packed.} = object",
        "staBaseToSeqCounterPadding*: array[28, uint8]",
        "seqCounter*: uint16",
        "doAssert offsetof(StaTxSequenceOverlay, staBaseToSeqCounterPadding) == 0",
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

    seq_layout = wifi_fw.split(
        "StaTxSequenceOverlay {.packed.} = object", 1
    )[1].split("RxuQosSeqCacheEntryView {.packed.} = object", 1)[0]
    assert "reserved00*" not in seq_layout


def test_wifi_tx_trigger_dma_status_write_uses_typed_thd_overlay():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc txl_cntrl_tx_check*", 1)[1].split(
        "proc txl_reset*", 1
    )[0]

    for expected in [
        "HostTxHwDescView {.packed.} = object",
        "status*: uint32",
        "secondaryTxHwDescPtr*: uint32",
        "doAssert offsetof(HostTxHwDescView, status) == 16",
        "template hostTxHwDescAt(p: pointer): ptr HostTxHwDescView",
    ]:
        assert expected in wifi_fw

    assert "let dmaHead = hwDesc.txConfirmDescPtr.uint" in body
    assert "hostTxHwDescAt(cast[pointer](dmaHead)).status = thdStatus.uint32" in body
    assert "cast[ptr uint32](dmaHead + 16)[]" not in body


def test_wifi_rxu_mgt_ie_start_uses_typed_tail_overlay():
    wifi_fw = wifi_fw_policy_source()

    helper_body = wifi_fw.rsplit("proc rxuMgtIndIeStart", 1)[1].split(
        "proc rxuMgtIndSsidLogPtr", 1
    )[0]

    for expected in [
        "ieData*: UncheckedArray[uint8]",
        "frameLenChannelPadding*: uint16",
        "channelSignalMetadataPadding*: array[17, uint8]",
        "signalBssidMetadataPadding*: array[21, uint8]",
        "bssidPnPadding*: array[2, uint8]",
        "hwRxhdrTailPadding*: uint32",
        "vifTimestampPadding*: array[7, uint8]",
        "phyVectorBodyPadding*: array[3, uint8]",
        "bufferAddrLengthPadding*: array[16, uint8]",
        "rxDescBaseToPayloadDescPadding*: array[8, uint8]",
        "payloadDescToFrameLenPadding*: array[16, uint8]",
        "frameLenRssiPadding*: array[21, uint8]",
        "payloadDescBaseToFrameDataPadding*: array[8, uint8]",
        "doAssert offsetof(RxMicFailureIndView, bssidPnPadding) == 6",
        "doAssert offsetof(RxMicFailureIndView, hwRxhdrTailPadding) == 20",
        "doAssert offsetof(RxuMgtIndMsgView, vifTimestampPadding) == 9",
        "doAssert offsetof(RxuMgtIndMsgView, phyVectorBodyPadding) == 29",
        "doAssert offsetof(RxUploadDmaArrayView, bufferAddrLengthPadding) == 16",
        "doAssert offsetof(BeaconRxDescView, rxDescBaseToPayloadDescPadding) == 0",
        "doAssert offsetof(BeaconRxDescView, payloadDescToFrameLenPadding) == 12",
        "doAssert offsetof(BeaconRxDescView, frameLenRssiPadding) == 30",
        "doAssert offsetof(BeaconPayloadDescView, payloadDescBaseToFrameDataPadding) == 0",
        "doAssert offsetof(RxuMgtIndView, frameLenChannelPadding) == 2",
        "doAssert offsetof(RxuMgtIndView, channelSignalMetadataPadding) == 7",
        "doAssert offsetof(RxuMgtIndView, rssi) == 24",
        "doAssert offsetof(RxuMgtIndView, signalBssidMetadataPadding) == 27",
        "doAssert offsetof(RxuMgtIndView, bssid) == 48",
        "doAssert offsetof(RxuMgtIndView, ieData) == 68",
    ]:
        assert expected in wifi_fw

    assert "addr rxuMgtIndAt(p).ieData[0]" in helper_body

    rxu_layout = wifi_fw.split("RxuMgtIndView {.packed.} = object", 1)[1].split(
        "PhyRxVectorView", 1
    )[0]
    phy_rx_vector_layout = wifi_fw.split(
        "PhyRxVectorView {.packed.} = object", 1
    )[1].split("MacAddrView", 1)[0]
    for forbidden in [
        "reserved0*: uint16",
        "reserved1*: array[17, uint8]",
        "reserved2*: array[21, uint8]",
    ]:
        assert forbidden not in rxu_layout
    for overlay_name, next_overlay, forbidden_fields in [
        (
            "RxMicFailureIndView {.packed.} = object",
            "RxEthernetRewriteHeaderView {.packed.} = object",
            [
                "reserved06*: array[2, uint8]",
                "reserved20*: uint32",
            ],
        ),
        (
            "RxuMgtIndMsgView {.packed.} = object",
            "RxUploadDmaArrayView {.packed.} = object",
            [
                "reserved09*: array[7, uint8]",
                "reserved29*: array[3, uint8]",
            ],
        ),
        (
            "RxUploadDmaArrayView {.packed.} = object",
            "RxuUploadEnvView {.packed.} = object",
            ["reserved16*: array[16, uint8]"],
        ),
        (
            "BeaconRxDescView {.packed.} = object",
            "BeaconPayloadDescView {.packed.} = object",
            [
                "reserved00*: array[8, uint8]",
                "reserved12*: array[16, uint8]",
                "reserved30*: array[21, uint8]",
            ],
        ),
        (
            "BeaconPayloadDescView {.packed.} = object",
            "BeaconFrameFixedView {.packed.} = object",
            ["reserved00*: array[8, uint8]"],
        ),
    ]:
        overlay_block = wifi_fw.split(overlay_name, 1)[1].split(next_overlay, 1)[0]
        for forbidden in forbidden_fields:
            assert forbidden not in overlay_block

    for expected in [
        "formatBitsToRssiPadding*: array[11, uint8]",
        "rssiToDurationFormatPadding*: array[19, uint8]",
        "durationFormatToLengthPadding*: array[3, uint8]",
        "doAssert offsetof(PhyRxVectorView, formatBitsToRssiPadding) == 8",
        "doAssert offsetof(PhyRxVectorView, rssiToDurationFormatPadding) == 21",
        "doAssert offsetof(PhyRxVectorView, durationFormatToLengthPadding) == 41",
    ]:
        assert expected in wifi_fw
    for forbidden in [
        "reserved8*",
        "reserved21*",
        "reserved41*",
    ]:
        assert forbidden not in phy_rx_vector_layout

    for forbidden in [
        "cast[pointer](cast[uint](p) + sizeof(RxuMgtIndView).uint)",
    ]:
        assert forbidden not in helper_body


def test_wifi_beacon_ie_body_uses_typed_tail_overlay():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc scanu_frame_handler*", 1)[1].split(
        "proc bl_hw_rxhdr_get_status*", 1
    )[0]

    for expected in [
        "doAssert offsetof(VifHtCapabilitiesOverlay, capInfo) == 0",
        "let htCaps = vifHtCapabilities(vifView)",
        "let htCapabilityOut = cast[pointer](htCaps)",
        "me_bw_check(htCapabilityOut)",
        "me_extract_power_constraint(ieStart, ieLen, htCapabilityOut)",
        "me_extract_country_reg(ieStart, ieLen, htCapabilityOut)",
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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc sm_sa_query_timeout_ind_handler*", 1)[1].split(
        "proc sm_disconnect*", 1
    )[0]
    sm_env_layout = wifi_fw.split(
        "SmEnvView {.packed.} = object", 1
    )[1].split("ApmEnvView {.packed.} = object", 1)[0]

    for expected in [
        "saQueryVifIdxTransIdPadding*: uint8",
        "doAssert offsetof(SmEnvView, saQueryVifIdxTransIdPadding) == 39",
        "let sta = staInfoForIdx(staIdx)",
        "let vif = vifChannelForIdx(vifIdx.uint8)",
        "let saQueryVifIdxTransIdPadding = sm.saQueryVifIdxTransIdPadding",
        "cast[pointer](sta), vifIdx)",
        "sm_disconnect_process(cast[pointer](vif), 20, 0xFFFF'u16)",
    ]:
        assert expected in wifi_fw if expected.startswith(("saQuery", "doAssert")) else expected in body

    assert "saQueryField39*" not in sm_env_layout

    for forbidden in [
        "let saField =",
        "sm.saQueryField39",
        "let staBase = cast[uint](addr sta_info_tab[0])",
        "let staEntry = staBase + staIdx.uint * STA_ENTRY_SIZE.uint",
        "let vifBase = cast[uint](addr vif_info_tab[0]) + vifIdx.uint * VIF_ENTRY_SIZE.uint",
        "cast[pointer](staEntry)",
        "sm_disconnect_process(cast[pointer](vifBase), 20, 0xFFFF'u16)",
    ]:
        assert forbidden not in body


def test_wifi_ap_sta_fw_delete_uses_sta_mac_overlay():
    wifi_fw = wifi_fw_policy_source()

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


def test_wifi_ap_timeout_and_mgmt_vif_resolution_use_semantic_indexes():
    wifi_fw = wifi_fw_policy_source()

    timeout_body = wifi_fw.rsplit("proc apm_sta_connect_timeout_ind_handler*", 1)[1].split(
        "proc apm_conf_max_sta_req_handler*", 1
    )[0]
    mgt_body = wifi_fw.rsplit("proc rxu_mgt_frame_check*", 1)[1].split(
        "proc rxu_cntrl_evt*", 1
    )[0]

    for expected in [
        "for apStaSlotIndex in 0'u8 ..< maxStaCount:",
        "let sta = staInfoForIdx(apStaSlotIndex)",
        "logFn(1, 0, nil, 530, apStaSlotIndex.uint32, elapsed)",
        "apm_sta_fw_delete(apStaSlotIndex, vifIdx, WLAN_FW_APM_DELETECONNECTION_TIMEOUT.uint16)",
    ]:
        assert expected in timeout_body

    for forbidden in [
        "for i in 0'u8 ..< maxStaCount:",
        "let sta = staInfoForIdx(i)",
        "logFn(1, 0, nil, 530, i.uint32, elapsed)",
        "apm_sta_fw_delete(i, vifIdx, WLAN_FW_APM_DELETECONNECTION_TIMEOUT.uint16)",
    ]:
        assert forbidden not in timeout_body

    for expected in [
        "for authBssidByteIndex in 0'u ..< 6:",
        "if frame.addr1[authBssidByteIndex] != frame.addr3[authBssidByteIndex]:",
        "for vifMacByteIndex in 0'u ..< 6:",
        "if vif.macAddr[vifMacByteIndex] != frame.addr1[vifMacByteIndex]:",
    ]:
        assert expected in mgt_body

    for forbidden in [
        "for j in 0'u ..< 6:",
        "if frame.addr1[j] != frame.addr3[j]:",
        "if vif.macAddr[j] != frame.addr1[j]:",
    ]:
        assert forbidden not in mgt_body


def test_wifi_auth_assoc_scheduler_uses_vif_overlay_pointer():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc chan_tbtt_switch_update*", 1)[1].split(
        "proc chan_update_tx_power*", 1
    )[0]

    assert "var tbttLeadTimeUs: uint32" in body
    assert "tbttLeadTimeUs = 9000'u32" in body
    assert "tbttLeadTimeUs = 3000'u32" in body
    assert "let tbttTarget = tbttTime - tbttLeadTimeUs" in body
    assert "co_list_extract(chanTbttPrimaryList(), chanTbttHdr(tbttNode))" in body
    assert "co_list_extract(addr chanEnvView().freeList, chanTbttHdr(tbttNode))" not in body
    assert "var offset: uint32" not in body
    assert "let tbttTarget = tbttTime - offset" not in body


def test_wifi_mac_vsie_find_uses_semantic_oui_byte_names():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit(
        "proc mac_vsie_find*(buf: pointer, bufLen: uint32, oui: pointer, ouiLen: uint8): pointer",
        1,
    )[1].split("proc mac_irq*", 1)[0]

    for expected in [
        "let targetOuiBytes = cast[ptr UncheckedArray[uint8]](oui)",
        "let vendorIePayload = ie.macIePayload",
        "for ouiByteIndex in 0'u8 ..< ouiLen:",
        "if vendorIePayload[ouiByteIndex] != targetOuiBytes[ouiByteIndex]:",
    ]:
        assert expected in body

    for forbidden in [
        "let ouiArr =",
        "let ieData =",
        "for i in 0'u8 ..< ouiLen:",
        "ieData[i]",
        "ouiArr[i]",
    ]:
        assert forbidden not in body


def test_wifi_paid_gid_helpers_name_bssid_fields_by_role():
    wifi_fw = wifi_fw_policy_source()

    sta_body = wifi_fw.split(
        "proc mac_paid_gid_sta_compute*(bssid: pointer): uint32",
        1,
    )[1].split("proc mac_paid_gid_ap_compute*", 1)[0]
    ap_body = wifi_fw.split(
        "proc mac_paid_gid_ap_compute*(bssid: pointer, aid: uint16): uint32",
        1,
    )[1].split(
        "# ###########################################################################\n#                  EDCA / Configuration",
        1,
    )[0]

    for expected in [
        "let bssidBytes = cast[ptr UncheckedArray[uint8]](bssid)",
        "let bssidOctet4Msb = bssidBytes[4].uint32 and 0x80'u32",
        "let bssidOctet5ForPartialAid = bssidBytes[5].uint32",
        "result = ((bssidOctet5ForPartialAid shl 1) or bssidOctet4Msb) shl 22",
    ]:
        assert expected in sta_body

    for expected in [
        "let bssidBytes = cast[ptr UncheckedArray[uint8]](bssid)",
        "let bssidOctet5ForPartialAid = bssidBytes[5].uint32",
        "let bssidOctet5UpperNibble = bssidOctet5ForPartialAid shr 4",
        "var bssidMixedAidBits =",
        "(bssidOctet5UpperNibble xor bssidOctet5ForPartialAid) shl 5",
        "bssidMixedAidBits = bssidMixedAidBits and 0x1E0'u32",
        "let combined = bssidMixedAidBits + partialAid",
    ]:
        assert expected in ap_body

    for forbidden in [
        "let b =",
        "let byte4",
        "let byte5",
        "let upperNibble",
        "var mixed",
    ]:
        assert forbidden not in sta_body
        assert forbidden not in ap_body


def test_wifi_phy_freq_to_channel_uses_semantic_band_distance_names():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc phy_freq_to_channel*", 1)[1].split(
        "proc find_wpa_rsn_ie*", 1
    )[0]

    assert "let freqOffsetFromChannelOneMhz = freq.int - 2412" in body
    assert (
        "if freqOffsetFromChannelOneMhz < 0 or "
        "freqOffsetFromChannelOneMhz > 72: return 0"
    ) in body
    assert "let freqOffsetFromFiveGhzBaseMhz = freq.int - 5000" in body
    assert (
        "if freqOffsetFromFiveGhzBaseMhz < 0 or "
        "freqOffsetFromFiveGhzBaseMhz > 820: return 0"
    ) in body
    assert "let offset = freq.int - 2412" not in body
    assert "let offset = freq.int - 5000" not in body


def test_wifi_chan_ctxt_unlink_removes_tbtt_without_reinserting_vif_node():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc chan_ctxt_unlink*", 1)[1].split(
        "proc chan_ctxt_update*", 1
    )[0]

    assert "co_list_extract(chanTbttPrimaryList(), tbttNode)" in body
    assert "chan_tbtt_schedule(nil)" in body
    assert "co_list_extract(addr env.freeList, tbttNode)" not in body
    assert "chan_tbtt_schedule(cast[pointer](addr vif.tbttNode))" not in body


def test_wifi_apm_send_mlme_uses_typed_frame_overlays():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

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
        "let matchedRateCount = msg.rateCount",
        "msg.rateBytes[matchedRateCount] = vifRate",
        "msg.rateCount = matchedRateCount + 1",
        "for existingStaSlotIndex in 0 ..< 5:",
        "let existingStaSlot = apmStaSlot(existingStaSlotIndex.uint)",
        'logFn204(2, 0, cast[pointer](cstring"apm.c"), 536, existingStaSlotIndex.uint32)',
        "aidIdx = existingStaSlotIndex",
        "for freeStaSlotIndex in 0 ..< 5:",
        "let freeStaSlot = apmStaSlot(freeStaSlotIndex.uint)",
        'logFn204(2, 0, cast[pointer](cstring"apm.c"), 560, freeStaSlotIndex.uint32)',
        "aidIdx = freeStaSlotIndex",
    ]:
        assert expected in body

    assert "apConfig.aidBitmapFeatureLow = 0" in start_body
    assert "apConfig.maxAssocRate = 0xFFFF'u16" in start_body

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
        "let cnt = msg.rateCount",
        "msg.rateBytes[cnt]",
        "for i in 0 ..< 5:",
        "let slot = apmStaSlot(i.uint)",
        "let slot = apmStaSlot(existingStaSlotIndex.uint)",
        "let slot = apmStaSlot(freeStaSlotIndex.uint)",
        "aidIdx = i",
        "536, i.uint32",
        "560, i.uint32",
    ]:
        assert forbidden not in body
        assert forbidden not in start_body


def test_wifi_ap_probe_req_handler_uses_typed_ie_and_channel_overlays():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc apm_probe_req_handler*", 1)[1].split(
        "proc apm_auth_handler*", 1
    )[0]
    probe_req_layout = wifi_fw.split(
        "ApmProbeReqView {.packed.} = object", 1
    )[1].split("StaKeyReqPayload {.packed.} = object", 1)[0]
    probe_ssid_layout = wifi_fw.split(
        "VifApProbeSsidOverlay {.packed.} = object", 1
    )[1].split("HostapdOpsView {.packed.} = object", 1)[0]

    for expected in [
        "VifApProbeSsidOverlay {.packed.} = object",
        "hiddenSsidMode*: uint8",
        "ssidLen*: uint8",
        "ssidData*: UncheckedArray[uint8]",
        "vifBaseToProbeSsidPadding*: array[385, uint8]",
        "doAssert offsetof(VifApProbeSsidOverlay, vifBaseToProbeSsidPadding) == 0",
        "doAssert offsetof(VifApProbeSsidOverlay, hiddenSsidMode) == 385",
        "doAssert offsetof(VifApProbeSsidOverlay, ssidLen) == 386",
        "doAssert offsetof(VifApProbeSsidOverlay, ssidData) == 387",
        "template vifApProbeSsid(vif: ptr VifChannelView): ptr VifApProbeSsidOverlay",
        "ApmProbeReqView {.packed.} = object",
        "bodyLenVifPadding*: array[6, uint8]",
        "vifIdxStaMacPadding*: array[33, uint8]",
        "doAssert offsetof(ApmProbeReqView, bodyLenVifPadding) == 2",
        "doAssert offsetof(ApmProbeReqView, vifIdxStaMacPadding) == 9",
    ]:
        assert expected in wifi_fw

    for forbidden in [
        "reserved02*",
        "reserved09*",
    ]:
        assert forbidden not in probe_req_layout
    assert "reserved00*" not in probe_ssid_layout

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
    wifi_fw = wifi_fw_policy_source()
    hostapd_ops_env_layout = wifi_fw.split(
        "VifMgmtHostapdOpsEnvView {.packed.} = object", 1
    )[1].split("VifHostapdPrivView {.packed.} = object", 1)[0]
    hostapd_priv_layout = wifi_fw.split(
        "VifHostapdPrivView {.packed.} = object", 1
    )[1].split("VifApProbeSsidOverlay {.packed.} = object", 1)[0]
    hostapd_ops_layout = wifi_fw.split(
        "HostapdOpsView {.packed.} = object", 1
    )[1].split("PsEnvView {.packed.} = object", 1)[0]

    body = wifi_fw.rsplit("proc apm_handle_eapol_input*", 1)[1].split(
        "proc apm_handle_auth_done*", 1
    )[0]

    for expected in [
        "VifMgmtHostapdOpsEnvView {.packed.} = object",
        "vifMgmtBaseToHostapdOpsPadding*: array[12, uint8]",
        "hostapdOps*: pointer",
        "VifHostapdPrivView {.packed.} = object",
        "vifBaseToHostapdPrivPadding*: array[364, uint8]",
        "hostapdPriv*: pointer",
        "HostapdOpsView {.packed.} = object",
        "opsBaseToEapolRxPadding*: array[44, uint8]",
        "eapolRx*: pointer",
        "doAssert offsetof(VifMgmtHostapdOpsEnvView, vifMgmtBaseToHostapdOpsPadding) == 0",
        "doAssert offsetof(VifMgmtHostapdOpsEnvView, hostapdOps) == 12",
        "doAssert offsetof(VifHostapdPrivView, vifBaseToHostapdPrivPadding) == 0",
        "doAssert offsetof(VifHostapdPrivView, hostapdPriv) == 364",
        "doAssert offsetof(HostapdOpsView, opsBaseToEapolRxPadding) == 0",
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

    assert "reserved00*" not in hostapd_ops_env_layout
    assert "reserved00*" not in hostapd_priv_layout
    assert "reserved00*" not in hostapd_ops_layout


def test_wifi_bam_air_action_uses_typed_frame_overlays():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    add_ba_param_layout = wifi_fw.split(
        "MeAddBaReqParamView {.packed.} = object", 1
    )[1].split("AddBaReqActionBodyView {.packed.} = object", 1)[0]
    del_ba_info_layout = wifi_fw.split(
        "DelBaInfoView {.packed.} = object", 1
    )[1].split("SmAuthFrameView {.packed.} = object", 1)[0]
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
        "MeAddBaReqParamView {.packed.} = object",
        "addBaReqBaseToSsnPadding*: array[8, uint8]",
        "timeoutToAmsduPadding*: array[2, uint8]",
        "AddBaReqActionBodyView {.packed.} = object",
        "AddBaRspActionBodyView {.packed.} = object",
        "DelBaActionBodyView {.packed.} = object",
        "DelBaInfoView {.packed.} = object",
        "delBaInfoBaseToInitiatorPadding*: array[13, uint8]",
        "initiatorToTidPadding*: array[2, uint8]",
        "template addBaReqActionBodyAt(param: pointer): ptr AddBaReqActionBodyView",
        "template addBaRspActionBodyAt(param: pointer): ptr AddBaRspActionBodyView",
        "template delBaActionBodyAt(param: pointer): ptr DelBaActionBodyView",
        "template delBaInfoView(param: pointer): ptr DelBaInfoView",
        "doAssert offsetof(MeAddBaReqParamView, addBaReqBaseToSsnPadding) == 0",
        "doAssert offsetof(MeAddBaReqParamView, timeoutToAmsduPadding) == 12",
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
        "doAssert offsetof(DelBaInfoView, delBaInfoBaseToInitiatorPadding) == 0",
        "doAssert offsetof(DelBaInfoView, initiator) == 13",
        "doAssert offsetof(DelBaInfoView, initiatorToTidPadding) == 14",
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
    assert "reserved00*" not in add_ba_param_layout
    assert "reserved12*" not in add_ba_param_layout
    assert "reserved00*" not in del_ba_info_layout
    assert "reserved14*" not in del_ba_info_layout


def test_wifi_ipc_host_tx_queue_uses_typed_overlays():
    wifi_fw = wifi_fw_policy_source()
    ipc_host_irq = (ROOT / "src/bl808/wifi/ipc_host/irq.nim").read_text()
    ipc_host_init = (ROOT / "src/bl808/wifi/ipc_host/init.nim").read_text()
    ipc_host_tx_shared = (
        ROOT / "src/bl808/wifi/ipc_host/tx_shared.nim"
    ).read_text()
    shared_msg_layout = wifi_fw.split(
        "IpcSharedMsgView {.packed.} = object", 1
    )[1].split("IpcPayloadWordStreamView {.packed.} = object", 1)[0]
    shared_env_layout = wifi_fw.split(
        "IpcSharedEnvView {.packed.} = object", 1
    )[1].split("IpcEmbEnvView {.packed.} = object", 1)[0]
    emb_env_layout = wifi_fw.split(
        "IpcEmbEnvView {.packed.} = object", 1
    )[1].split("IpcHostTxWrapperView {.packed.} = object", 1)[0]
    wrapper_layout = wifi_fw.split(
        "IpcHostTxWrapperView {.packed.} = object", 1
    )[1].split("IpcTxAcDescView {.packed.} = object", 1)[0]

    for expected in [
        "sharedMsgBaseToHeaderPadding*: array[4, uint8]",
        "sharedEnvBaseToHeaderPadding*: array[4, uint8]",
        "counterToHostListPadding*: array[11, uint8]",
        "linkToActivePadding*: uint32",
        "hostTxList*: ptr CoList",
        "hostTxCfmList*: ptr CoList",
        "doAssert offsetof(IpcSharedMsgView, sharedMsgBaseToHeaderPadding) == 0",
        "doAssert offsetof(IpcSharedEnvView, sharedEnvBaseToHeaderPadding) == 0",
        "doAssert offsetof(IpcEmbEnvView, counterToHostListPadding) == 1",
        "doAssert offsetof(IpcHostTxWrapperView, linkToActivePadding) == 4",
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
    dbg_body = ipc_host_irq.rsplit("proc ipcHostDbgHandler", 1)[1].split(
        "proc ipc_host_irq*", 1
    )[0]
    host_irq_body = ipc_host_irq.rsplit("proc ipc_host_irq*", 1)[1].split(
        "proc ipc_host_enable_irq*", 1
    )[0]
    host_init_body = ipc_host_init.split("proc ipc_host_init*", 1)[1]
    host_txbuf_body = ipc_host_tx_shared.split("proc ipc_host_txbuf_get*", 1)[1].split(
        "proc ipc_host_txbuf_free*", 1
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

    for expected in [
        "let debugHostSlotIndex = loadU8(env, EnvDbgIdxOff).uint",
        "let hostId = loadPtr(env, EnvDbgArrayOff + debugHostSlotIndex * 8'u)",
    ]:
        assert expected in dbg_body

    for expected, body in [
        ("for txBufferSlotIndex in 0'u ..< NxTxDescCnt.uint:", host_txbuf_body),
        ("ptrAt(txbuf, txBufferSlotIndex * SharedTxbufSize)", host_txbuf_body),
        ("for sharedTxDescIndex in 0'u ..< NxTxDescCnt.uint:", host_init_body),
        (
            "SharedTxdesc0Off + sharedTxDescIndex * SharedTxdescHostSize",
            host_init_body,
        ),
        ("for txCfmQueueIndex in 0 ..< IpcTxQueueCnt:", host_irq_body),
        (
            "1'u32 shl (txCfmQueueIndex + IpcIrqE2aTxCfmPos)",
            host_irq_body,
        ),
    ]:
        assert expected in body

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

    for forbidden in [
        "let idx = loadU8(env, EnvDbgIdxOff).uint",
        "EnvDbgArrayOff + idx * 8'u",
    ]:
        assert forbidden not in dbg_body

    for forbidden, body in [
        ("for i in 0'u ..< NxTxDescCnt.uint:", host_txbuf_body),
        ("ptrAt(txbuf, i * SharedTxbufSize)", host_txbuf_body),
        ("for i in 0'u ..< NxTxDescCnt.uint:", host_init_body),
        ("SharedTxdesc0Off + i * SharedTxdescHostSize", host_init_body),
        ("for i in 0 ..< IpcTxQueueCnt:", host_irq_body),
        ("1'u32 shl (i + IpcIrqE2aTxCfmPos)", host_irq_body),
    ]:
        assert forbidden not in body

    assert "reserved0*" not in shared_msg_layout
    assert "reserved0*" not in shared_env_layout
    assert "reserved1*" not in emb_env_layout
    assert "reserved4*" not in wrapper_layout


def test_wifi_ipc_tx_ac_reset_uses_typed_overlay():
    wifi_fw = wifi_fw_policy_source()
    ipc_tx_ac_layout = wifi_fw.split(
        "IpcTxAcDescView {.packed.} = object", 1
    )[1].split("IpcTxHwDescWordTableView {.packed.} = object", 1)[0]

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
        "descPtrToSequencePadding*: array[4, uint8]",
        "sequence*: uint16",
        "busy*: uint8",
        "busyTailPadding*: uint8",
        "doAssert sizeof(IpcTxAcDescView) == 16",
        "doAssert IPC_TX_AC_DESC_STRIDE == sizeof(IpcTxAcDescView).uint32",
        "doAssert offsetof(IpcTxAcDescView, descPtr) == 4",
        "doAssert offsetof(IpcTxAcDescView, descPtrToSequencePadding) == 8",
        "doAssert offsetof(IpcTxAcDescView, sequence) == 12",
        "doAssert offsetof(IpcTxAcDescView, busy) == 14",
        "doAssert offsetof(IpcTxAcDescView, busyTailPadding) == 15",
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

    assert "reserved8*" not in ipc_tx_ac_layout
    assert "reserved15*" not in ipc_tx_ac_layout


def test_wifi_scan_cancel_confirmation_payload_is_semantic():
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc scan_send_cancel_cfm*", 1)[1].split(
        "proc scan_get_chan*", 1
    )[0]

    for expected in [
        "let cancelCfmPayload = cast[ptr StatusCfmPayload](",
        "cancelCfmPayload.status = status",
        "ke_msg_send(cancelCfmPayload)",
    ]:
        assert expected in body

    for forbidden in [
        "let param = cast[ptr StatusCfmPayload]",
        "param.status = status",
        "ke_msg_send(param)",
    ]:
        assert forbidden not in body


def test_wifi_fixed_channel_validator_uses_semantic_channel_index_name():
    fixed_channels = (
        ROOT / "src/bl808/wifi/msg_tx/channel_plan_parts/fixed_channels.nim"
    ).read_text()

    body = fixed_channels.split("proc bl_get_fixed_channels_is_valid*", 1)[1]

    for expected in [
        "for fixedChannelIndex in 0 ..< channelNum.int:",
        "cast[ptr UncheckedArray[uint16]](channels)[fixedChannelIndex]",
        "if channel == 0'u16 or channel > channelNumDefault.uint16:",
    ]:
        assert expected in body

    for forbidden in [
        "for i in 0 ..< channelNum.int:",
        "cast[ptr UncheckedArray[uint16]](channels)[i]",
    ]:
        assert forbidden not in body


def test_wifi_scan_request_uses_semantic_channel_slot_names():
    scan_request = (
        ROOT / "src/bl808/wifi/msg_tx/scan_parts/scan_request.nim"
    ).read_text()

    body = scan_request.split("proc bl_send_scanu_req*", 1)[1]

    for expected in [
        "let channels = loadPtr(scanParams, ScanParaChannelsOff)",
        "for scanChannelSlot in 0 ..< scanChannelCount.int:",
        "let channelIndex =",
        "if fixedChannelCount == 0'u16:",
        "scanChannelSlot",
        "cast[ptr UncheckedArray[uint16]](channels)[scanChannelSlot].int - 1",
        "ScanuChanOff + scanChannelSlot.uint * ScanChanSize",
        "channelIndex, scanChannelFlags, 0",
    ]:
        assert expected in body

    for forbidden in [
        "for i in 0 ..< chanCnt.int:",
        "for scanChannelSlot in 0 ..< chanCnt.int:",
        "let index =",
        "if fixedCount == 0'u16:",
        "let channels = loadPtr(sp, ScanParaChannelsOff)",
        "cast[ptr UncheckedArray[uint16]](channels)[i].int - 1",
        "ScanuChanOff + i.uint * ScanChanSize",
        "fillScanChan(req, ScanuChanOff + i.uint * ScanChanSize, index",
    ]:
        assert forbidden not in body


def test_wifi_channel_config_request_uses_semantic_channel_slot_names():
    channel_config = (
        ROOT / "src/bl808/wifi/msg_tx/scan_parts/channel_config.nim"
    ).read_text()

    body = channel_config.split("proc bl_send_me_chan_config_req*", 1)[1]

    for expected in [
        "var configuredChannelCount = channelNumDefault",
        "if configuredChannelCount > SCAN_CHANNEL_2G4:",
        "configuredChannelCount = SCAN_CHANNEL_2G4",
        "for scanChannelSlot in 0 ..< configuredChannelCount:",
        "MeChanChan2G4Off + scanChannelSlot.uint * ScanChanSize",
        "scanChannelSlot, 0, 20",
        "storeU8(channelConfigRequest, MeChanCountOff, (scanChannelSlot + 1).uint8)",
    ]:
        assert expected in body

    for forbidden in [
        "var count = channelNumDefault",
        "if count > SCAN_CHANNEL_2G4:",
        "for i in 0 ..< count:",
        "MeChanChan2G4Off + i.uint * ScanChanSize",
        "storeU8(req, MeChanCountOff, (i + 1).uint8)",
        "storeU8(req, MeChanCountOff, (scanChannelSlot + 1).uint8)",
    ]:
        assert forbidden not in body


def test_wifi_scan_cipher_flags_use_semantic_parsed_ie_names():
    cipher_flags = (
        ROOT / "src/bl808/wifi/rx/scan_events_parts/cipher_flags.nim"
    ).read_text()

    body = cipher_flags.split("proc setCipherFlags", 1)[1]

    for expected in [
        "for parsedIeIndex in 0 ..< parsedIeCount:",
        "let parsedIe = ptrAt(cast[pointer](parsedWpaIes), uint(parsedIeIndex) * sizeof(WifiWpaIe).uint)",
        "let proto = cast[ptr cint](ptrAt(parsedIe, 0))[]",
        "let pairwise = cast[ptr cint](ptrAt(parsedIe, 4))[]",
        "let group = cast[ptr cint](ptrAt(parsedIe, 8))[]",
        "let keyMgmt = cast[ptr cint](ptrAt(parsedIe, 12))[]",
    ]:
        assert expected in body

    for forbidden in [
        "for i in 0 ..< parsedLen:",
        "for parsedIeIndex in 0 ..< parsedLen:",
        "uint(i) * sizeof(WifiWpaIe).uint",
        "cast[pointer](parsed), uint(parsedIeIndex)",
        "let ie = ptrAt(",
        "ptrAt(ie, 0)",
        "ptrAt(ie, 4)",
        "ptrAt(ie, 8)",
        "ptrAt(ie, 12)",
    ]:
        assert forbidden not in body


def test_wifi_tx_flow_control_uses_semantic_vif_role_index_name():
    flow_control = (
        ROOT / "src/bl808/wifi/tx/queue_parts/flow_control.nim"
    ).read_text()

    body = flow_control.split("proc txCntrlUpdateFc", 1)[1]

    for expected in [
        "proc bitVif(vifRoleIndex: int): uint8 {.inline.} =",
        "1'u8 shl vifRoleIndex",
        "for vifRoleIndex in 0 ..< 2:",
        "if (fc.vifBits and bitVif(vifRoleIndex)) != 0'u8:",
        "if vifRoleIndex == BlVifSta:",
    ]:
        assert expected in flow_control

    for forbidden in [
        "proc bitVif(idx: int):",
        "1'u8 shl idx",
        "for i in 0 ..< 2:",
        "bitVif(i)",
        "if i == BlVifSta:",
    ]:
        assert forbidden not in body


def test_wifi_scan_ssid_selection_has_typed_cache_fallback():
    wifi_fw = wifi_fw_policy_source()

    helper_body = wifi_fw.split("proc scanuCachedSsidFor", 1)[1].split(
        '{.emit: "__attribute__((optimize(\\"crossjumping\\"))) void scanu_frame_handler',
        1,
    )[0]
    probe_body = wifi_fw.split("proc scan_probe_req_tx*", 1)[1].split(
        "# ###########################################################################\n#                      SCANU (Upper MAC Scan)",
        1,
    )[0]
    frame_body = wifi_fw.split("proc scanu_frame_handler*", 1)[1].split(
        "proc scanu_search_by_bssid*", 1
    )[0]
    scan_done_body = wifi_fw.split("proc scan_done_ind_handler*", 1)[1].split(
        "proc scan_cancel_req_handler*", 1
    )[0]
    bss_body = wifi_fw.rsplit("proc sm_get_bss_params*", 1)[1].split(
        "proc sm_scan_bss*", 1
    )[0]
    search_body = wifi_fw.split("proc scanu_search_by_ssid*", 1)[1].split(
        "proc scanu_rm_exist_ssid*", 1
    )[0]
    clear_body = wifi_fw.split("proc scanu_cached_scanresult_clear*", 1)[1].split(
        "proc scanu_prune_scanresult_raw_frames", 1
    )[0]
    prune_body = wifi_fw.split("proc wifi_nimfw_prune_scan_raw_cache_for_ssid*", 1)[1].split(
        "proc scanu_dump_scanresult*", 1
    )[0]
    scanu_layout_block = wifi_fw.split("ScanuResultEntry* = object", 1)[1].split(
        "ScanuChannelConfigOverlay", 1
    )[0]

    for expected in [
        "ScanuCachedSsid* = object",
        "valid*: uint8",
        "length*: uint8",
        "ssidBytes*: array[32, uint8]",
        "scanuCachedSsids: array[SCANU_MAX_RESULT_ENTRIES, ScanuCachedSsid]",
        "pendingJoinRxuMgtInd*: pointer",
        "doAssert offsetof(ScanuEnvObj, pendingJoinRxuMgtInd) == 172",
        "securityAuthPointerPadding*: uint8",
        "requesterResultCountPadding*: uint8",
        "filterSsidStatePadding*: uint8",
        "resultStatePointerPadding*: uint8",
        "directedJoinPointerPadding*: uint16",
        "extraIeLenTailPadding*: uint16",
        "doAssert offsetof(ScanuResultEntry, securityAuthPointerPadding) == 23",
        "doAssert offsetof(ScanuEnvObj, requesterResultCountPadding) == 177",
        "doAssert offsetof(ScanuEnvObj, filterSsidStatePadding) == 221",
        "doAssert offsetof(ScanuEnvObj, resultStatePointerPadding) == 223",
        "doAssert offsetof(ScanuEnvObj, directedJoinPointerPadding) == 230",
        "doAssert offsetof(ScanuEnvObj, extraIeLenTailPadding) == 238",
    ]:
        assert expected in wifi_fw

    for expected in [
        "for ssidCacheSlotIndex in 0 ..< SCANU_MAX_RESULT_ENTRIES:",
        "if (addr scanu_env.entries[ssidCacheSlotIndex]) == scanResultEntry:",
        "return addr scanuCachedSsids[ssidCacheSlotIndex]",
        "for ssidByteIndex in 0 ..< cached.length.int:",
        "cached.ssidBytes[ssidByteIndex] = ssid.ssidBytes[ssidByteIndex]",
        "proc scanuCacheSsid(scanResultEntry: ptr ScanuResultEntry;",
        "proc scanuCachedSsidMatches(scanResultEntry: ptr ScanuResultEntry;",
        "proc scanuCachedSsidMeta(scanResultEntry: ptr ScanuResultEntry)",
        "c_memcmp(searchData, addr cached.ssidBytes[0], searchLen.csize_t) == 0",
    ]:
        assert expected in helper_body

    assert "let scanResultEntry = scanuResultAt(result)" in frame_body
    assert "scanuCacheSsid(scanResultEntry, addr ssidScratch)" in frame_body
    assert "for scanResultPointerIndex in 0 ..< MAX_SCAN_RESULTS:" in wifi_fw
    assert "scanuResults[scanResultPointerIndex] = nil" in wifi_fw
    assert "for i in 0 ..< MAX_SCAN_RESULTS:" not in wifi_fw
    assert "scanuResults[i] = nil" not in wifi_fw
    assert "for ssidScratchByteIndex in 0 ..< ssidScratch.length.int:" in frame_body
    assert "ssidScratch.ssidBytes[ssidScratchByteIndex] = ssid.ssidBytes[ssidScratchByteIndex]" in frame_body
    assert "for i in 0 ..< ssidScratch.length.int:" not in frame_body
    assert "ssidScratch.ssidBytes[i] = ssid.ssidBytes[i]" not in frame_body
    assert "for ssidProbeSlotIndex in 0 ..< numSsids.int:" in probe_body
    assert "let ssidSlot = scanSsidSlot(scanReq, ssidProbeSlotIndex)" in probe_body
    assert "for i in 0 ..< numSsids.int:" not in probe_body
    assert "let ssidSlot = scanSsidSlot(scanReq, i)" not in probe_body
    assert "for probeIeRawByteIndex in 0 ..< nimFwDbgProbeIeRaw.len:" in probe_body
    assert "nimFwDbgProbeIeRaw[probeIeRawByteIndex] = 0" in probe_body
    assert "for k in 0 ..< nimFwDbgProbeIeRaw.len:" not in probe_body
    assert "nimFwDbgProbeIeRaw[k] = 0" not in probe_body
    assert "proc scan_get_chan*(channelIndex: uint32): pointer" in wifi_fw
    assert "scanReq.channelList[channelIndex.int]" in wifi_fw
    assert "proc scan_get_chan*(idx: uint32): pointer" not in wifi_fw
    assert "scanReq.channelList[idx.int]" not in wifi_fw
    assert "for filterBssidByteIndex in 0 ..< 6:" in frame_body
    assert (
        "if rx.bssid[filterBssidByteIndex] != scanu_env.filterBssid[filterBssidByteIndex]:"
        in frame_body
    )
    assert "var ssidFilterIndex = 0" in frame_body
    assert "while ssidFilterIndex < numSsids.int:" in frame_body
    assert "let filterSlot = scanSsidSlot(scanReq, ssidFilterIndex)" in frame_body
    assert "let cachedRxuMgtIndLen = totalLen.uint32 + 32" in frame_body
    assert "scanu_env.pendingJoinRxuMgtInd = msg" in frame_body
    assert "let cachedRxuMgtIndView = rxuMgtIndAt(cachedRxuMgtInd)" in search_body
    assert "for bssidPairLogIndex in 0'u32 ..< 3'u32:" in bss_body
    assert "let bssidPairFirstByte = ci.bssid[bssidPairLogIndex.uint * 2]" in bss_body
    assert "for i in 0'u32 ..< 3'u32:" not in bss_body
    assert "let bssidByte = ci.bssid[i.uint * 2]" not in bss_body
    assert "var bssidAllZero = true" in bss_body
    assert "for bssidByteIndex in 0 ..< 6:" in bss_body
    assert "if ci.bssid[bssidByteIndex] != 0:" in bss_body
    assert "bssidAllZero = false" in bss_body
    assert "if bssidAllZero:" in bss_body
    assert "let pendingJoinRxuMgtInd = scanu_env.pendingJoinRxuMgtInd" in scan_done_body
    assert "scanu_env.pendingJoinRxuMgtInd = nil" in scan_done_body
    assert (
        "if not scanuCachedSsidMatches(ssidSearchResultEntry,\n"
        "                                      searchData, searchLen):"
        in search_body
    )
    assert "for ssidSearchResultSlotIndex in 0'u8 ..< SCANU_MAX_RESULT_ENTRIES.uint8:" in search_body
    assert "let ssidSearchResultEntry =" in search_body
    assert "addr scanu_env.entries[ssidSearchResultSlotIndex]" in search_body
    assert "var bestScanResultEntry: ptr ScanuResultEntry = nil" in search_body
    assert "bestScanResultEntry = ssidSearchResultEntry" in search_body
    assert "return bestScanResultEntry" in search_body
    assert "cast[ptr uint32](entryIndexOut)[] = ssidSearchResultSlotIndex.uint32" in search_body
    assert "for i in 0'u8 ..< SCANU_MAX_RESULT_ENTRIES.uint8:" not in search_body
    assert "let entry = addr scanu_env.entries[i]" not in search_body
    assert "let entry = addr scanu_env.entries[ssidSearchResultSlotIndex]" not in search_body
    assert "var bestEntry: ptr ScanuResultEntry = nil" not in search_body
    assert "cast[ptr uint32](entryIndexOut)[] = i.uint32" not in search_body
    assert "let ssidResultEntryIndex = cast[int8](ssidLen)" in wifi_fw
    assert "let ssidIndexResultEntry = addr scanu_env.entries[ssidResultEntryIndex.int]" in wifi_fw
    assert "for scanResultSlotIndex in 0 ..< SCANU_MAX_RESULT_ENTRIES:" in clear_body
    assert (
        "let scanResultEntry = addr scanu_env.entries[scanResultSlotIndex]"
        in clear_body
    )
    assert "scanuClearCachedSsid(scanResultEntry)" in clear_body
    assert "scanResultEntry.valid = 0" in clear_body
    assert "scanResultEntry.rssi = -128'i8" in clear_body
    assert "scanuClearCachedSsid(e)" not in clear_body
    assert "let e = addr scanu_env.entries[i]" not in clear_body
    assert "for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:" not in clear_body
    assert "var bestScanResultEntry: ptr ScanuResultEntry = nil" in prune_body
    assert "bestScanResultEntry = scanResultEntry" in prune_body
    assert "scanResultEntry != bestScanResultEntry" in prune_body
    assert "var bestEntry: ptr ScanuResultEntry = nil" not in prune_body

    for forbidden in [
        "pendingRawMsg",
        "let rawLen",
        "let rawRx",
        "let rawResult",
        "let filterSlot = scanSsidSlot(scanReq, idx)",
        "var idx = 0",
        "if rx.bssid[i] != scanu_env.filterBssid[i]:",
        "var allZero = true",
        "if ci.bssid[i] != 0:",
        "if allZero:",
        "if (addr scanu_env.entries[i]) == entry:",
        "return addr scanuCachedSsids[i]",
        "for i in 0 ..< cached.length.int:",
        "cached.ssidBytes[i] = ssid.ssidBytes[i]",
    ]:
        assert forbidden not in frame_body
        assert forbidden not in bss_body
        assert forbidden not in search_body
        assert forbidden not in scan_done_body
        assert forbidden not in helper_body

    for forbidden in [
        "pad23*: uint8",
        "reserved0*: uint8",
        "reserved1*: uint8",
        "reserved2*: uint8",
        "reserved3*: uint16",
        "reserved4*: uint16",
    ]:
        assert forbidden not in scanu_layout_block


def test_wifi_transition_mode_prefers_psk_over_sae():
    wifi_fw = wifi_fw_policy_source()
    frame_body = wifi_fw.split("proc scanu_frame_handler*", 1)[1].split(
        "proc scanu_search_by_bssid*", 1
    )[0]

    assert "if (keyMgmtMask and 2) != 0: selectedAuth = 2" in frame_body
    assert "elif (keyMgmtMask and 0x400) != 0: selectedAuth = 1024" in frame_body
    assert (
        "if (keyMgmtMask and 0x400) != 0: selectedAuth = 1024\n"
        "          elif (keyMgmtMask and 0x100) != 0"
    ) not in frame_body


def test_wifi_scan_start_payload_alignment_fields_are_semantic():
    wifi_fw = wifi_fw_policy_source()

    scan_start_layout = wifi_fw.split(
        "ScanStartReqPayload {.packed.} = object", 1
    )[1].split("ScanuStartReqPayload {.packed.} = object", 1)[0]
    scanu_start_layout = wifi_fw.split(
        "ScanuStartReqPayload {.packed.} = object", 1
    )[1].split("const KeMsgHdrSize", 1)[0]

    for expected in [
        "localMacResultPointerPadding*: uint16",
        "sendProbeAddIeLenPadding*: uint8",
        "doAssert offsetof(ScanStartReqPayload, localMacResultPointerPadding) == 298",
        "doAssert offsetof(ScanStartReqPayload, scanResult) == 300",
        "doAssert offsetof(ScanStartReqPayload, sendProbeAddIeLenPadding) == 311",
        "doAssert offsetof(ScanStartReqPayload, addIeLen) == 312",
        "localMacProbeIePadding*: uint16",
        "passiveFlagsPadding*: uint16",
        "doAssert offsetof(ScanuStartReqPayload, localMacProbeIePadding) == 298",
        "doAssert offsetof(ScanuStartReqPayload, probeReqIe) == 300",
        "doAssert offsetof(ScanuStartReqPayload, passiveFlagsPadding) == 310",
        "doAssert offsetof(ScanuStartReqPayload, flags) == 312",
    ]:
        assert expected in wifi_fw

    assert "reserved0*: uint16" not in scan_start_layout
    assert "reserved1*: uint8" not in scan_start_layout
    assert "reserved0*: uint16" not in scanu_start_layout
    assert "reserved1*: uint16" not in scanu_start_layout


def test_wifi_tx_control_init_uses_ipc_descriptor_word_overlay():
    wifi_fw = wifi_fw_policy_source()

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
    assert "for accessCategoryIndex in 0 ..< NUM_TX_QUEUES:" in init_body
    assert "txlAcPending[accessCategoryIndex] = 0" in init_body
    assert "txlAcBusy[accessCategoryIndex] = false" in init_body

    for forbidden in [
        "let hwDescAddr = (0x24A00080'u32 + ac * 4).uint16",
        "acCtrl.packetCount = hwDescAddr",
        "0x24A00080'u32 + ac * 4",
        "for i in 0 ..< NUM_TX_QUEUES:",
        "txlAcPending[i] = 0",
        "txlAcBusy[i] = false",
    ]:
        assert forbidden not in init_body


def test_wifi_sta_key_and_raw_tx_hw_descriptor_padding_is_semantic():
    wifi_fw = wifi_fw_policy_source()

    sta_key_layout = wifi_fw.split(
        "StaKeyReqPayload {.packed.} = object", 1
    )[1].split("MachwKeyWriteParamView {.packed.} = object", 1)[0]
    tx_hw_desc_layout = wifi_fw.split(
        "TxHwDesc* = object", 1
    )[1].split("TxBufferDesc* = object", 1)[0]

    for expected in [
        "cipherSuiteToKeyDataPadding*: array[23, uint8]",
        "doAssert offsetof(StaKeyReqPayload, cipherSuiteToKeyDataPadding) == 1",
        "bufMaskToControlPadding*: uint32",
        "controlToRngPadding0*: uint32",
        "controlToRngPadding1*: uint32",
        "controlToRngPadding2*: uint32",
        "controlToRngPadding3*: uint32",
        "doAssert offsetof(TxHwDesc, bufMaskToControlPadding) == 12",
        "doAssert offsetof(TxHwDesc, controlToRngPadding0) == 20",
        "doAssert offsetof(TxHwDesc, controlToRngPadding3) == 32",
        "doAssert offsetof(TxHwDesc, rngVal0) == 36",
    ]:
        assert expected in wifi_fw

    assert "reserved01*" not in sta_key_layout
    for forbidden in [
        "reserved0*",
        "reserved1*",
        "reserved2*",
        "reserved3*",
        "reserved4*",
    ]:
        assert forbidden not in tx_hw_desc_layout


def test_wifi_pspoll_tx_uses_typed_frame_overlays():
    wifi_fw = wifi_fw_policy_source()

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
    wifi_fw = wifi_fw_policy_source()

    for expected in [
        "WpsCallbacksView {.packed.} = object",
        "resultPadding*: array[2, uint8]",
        "ssidLenPadding*: array[3, uint8]",
        "callbackScratchTail*: array[112, uint8]",
        "doAssert offsetof(WpsScanCallbackBuffer, callbackScratchTail) == 28",
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
        "keyWriteCallbackPadding*: pointer",
        "apStoppedCallbackPadding*: pointer",
        "disconnectCallbackPadding*: pointer",
        "parseSecurityCallbackPadding*: pointer",
        "saeFrameCallbackPadding*: pointer",
        "staAdd*: pointer",
        "authTimeout*: pointer",
        "doAssert offsetof(WpaCallbacksView, deinit) == 4",
        "doAssert offsetof(WpaCallbacksView, keyWriteCallbackPadding) == 16",
        "doAssert offsetof(WpaCallbacksView, eapolHandler) == 20",
        "doAssert offsetof(WpaCallbacksView, beaconRegister) == 24",
        "doAssert offsetof(WpaCallbacksView, apStopped) == 28",
        "doAssert offsetof(WpaCallbacksView, apStoppedCallbackPadding) == 32",
        "doAssert offsetof(WpaCallbacksView, staAdd) == 36",
        "doAssert offsetof(WpaCallbacksView, disconnectCallbackPadding) == 44",
        "doAssert offsetof(WpaCallbacksView, parseSecurityCallbackPadding) == 52",
        "doAssert offsetof(WpaCallbacksView, saeFrameCallbackPadding) == 60",
        "doAssert offsetof(WpaCallbacksView, authTimeout) == 64",
        "parserHeaderPadding*: array[4, uint8]",
        "groupCipherPadding*: array[3, uint8]",
        "pairwiseCipherPadding*: array[3, uint8]",
        "keyMgmtMaskPadding*: array[2, uint8]",
        "capsTailPadding*: array[11, uint8]",
        "scanNotifyVendorByte*: uint8",
        "scanNotifyVendorBytePadding*: array[3, uint8]",
        "parserScratchTail*: array[96, uint8]",
        "doAssert offsetof(WpaParsedInfoView, scanNotifyVendorByte) == 28",
        "WpaScanSecurityNotifyView {.packed.} = object",
        "vifIdxPadding*: uint8",
        "bssidTailPadding*: array[38, uint8]",
        "cipherPadding*: uint8",
        "cipherPairTailPadding*: array[66, uint8]",
        "doAssert offsetof(WpaScanSecurityNotifyView, bssidTailPadding) == 14",
        "doAssert offsetof(WpaScanSecurityNotifyView, cipherPadding) == 53",
        "doAssert offsetof(WpaScanSecurityNotifyView, cipherPairTailPadding) == 58",
        "doAssert offsetof(WpaScanSecurityNotifyView, scanNotifyVendorByte) == 124",
        "doAssert offsetof(WpaScanSecurityNotifyView, scanNotifyVendorBytePadding) == 125",
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
        "notify.scanNotifyVendorByte = parsedSecurity.scanNotifyVendorByte",
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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc apm_start_req_handler*", 1)[1].split(
        "proc apm_stop_req_handler*", 1
    )[0]

    for expected in [
        "WpaBeaconRegisterParamView {.packed.} = object",
        "vifIdx*: uint8",
        "bssid*: array[6, uint8]",
        "bssidTailPadding*: array[33, uint8]",
        "rateCount*: uint32",
        "rates*: array[32, uint8]",
        "marker*: uint16",
        "ssid*: array[64, uint8]",
        "terminator*: uint8",
        "terminatorPadding*: uint8",
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
        "let beaconRegister = cast[ptr WpaBeaconRegisterParamView](addr beaconRegisterBuffer[0])",
        "beaconRegister.vifIdx = req.vifIdx",
        "beaconRegister.bssid = vif.bssid",
        "beaconRegister.rateCount = rateCount.uint32",
        "c_memcpy(addr beaconRegister.rates[0], addr vif.supportedRatesLong[1],",
        "beaconRegister.marker = 0x0403'u16",
        "c_memcpy(addr beaconRegister.ssid[0], ssidPtr, ssidLen)",
        "beaconRegister.terminator = 0",
        "let beaconRegisterCallback = wpaCallbacks().beaconRegister",
        "cast[proc(buf: pointer) {.cdecl.}](beaconRegisterCallback)(",
        "addr beaconRegisterBuffer[0]",
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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc mm_sta_add*", 1)[1].split(
        "proc mm_sta_del*", 1
    )[0]

    for expected in [
        "WpaKeyWriteParamView {.packed.} = object",
        "vifIdx*: uint8",
        "staIdx*: uint8",
        "stationIndexPadding*: array[14, uint8]",
        "keyDataLen*: uint32",
        "keyMaterial*: array[38, uint8]",
        "ssid*: array[64, uint8]",
        "ssidTailPadding*: array[3, uint8]",
        "quickConn*: uint8",
        "quickConnPadding*: array[2, uint8]",
        "doAssert sizeof(WpaKeyWriteParamView) == 128",
        "doAssert offsetof(WpaKeyWriteParamView, staIdx) == 1",
        "doAssert offsetof(WpaKeyWriteParamView, stationIndexPadding) == 2",
        "doAssert offsetof(WpaKeyWriteParamView, keyDataLen) == 16",
        "doAssert offsetof(WpaKeyWriteParamView, keyMaterial) == 20",
        "doAssert offsetof(WpaKeyWriteParamView, ssid) == 58",
        "doAssert offsetof(WpaKeyWriteParamView, ssidTailPadding) == 122",
        "doAssert offsetof(WpaKeyWriteParamView, quickConn) == 125",
        "doAssert offsetof(WpaKeyWriteParamView, quickConnPadding) == 126",
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
    wifi_fw = wifi_fw_policy_source()

    body = wifi_fw.rsplit("proc mm_sta_add*", 1)[1].split(
        "proc mm_sta_del*", 1
    )[0]

    for expected in [
        "WepKeyWriteParamView {.packed.} = object",
        "selector*: uint16",
        "selectorPadding*: array[2, uint8]",
        "keyLen*: uint8",
        "keyLenPadding*: array[3, uint8]",
        "keyData*: array[44, uint8]",
        "cipherMode*: uint8",
        "instNbr*: uint8",
        "instNbrPadding*: array[2, uint8]",
        "doAssert sizeof(WepKeyWriteParamView) == 56",
        "doAssert offsetof(WepKeyWriteParamView, selectorPadding) == 2",
        "doAssert offsetof(WepKeyWriteParamView, keyLen) == 4",
        "doAssert offsetof(WepKeyWriteParamView, keyLenPadding) == 5",
        "doAssert offsetof(WepKeyWriteParamView, keyData) == 8",
        "doAssert offsetof(WepKeyWriteParamView, cipherMode) == 52",
        "doAssert offsetof(WepKeyWriteParamView, instNbr) == 53",
        "doAssert offsetof(WepKeyWriteParamView, instNbrPadding) == 54",
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
        "let hi = ascii_to_hex(hexChars[hexIndex])",
        "let lo = ascii_to_hex(hexChars[hexIndex + 1])",
        "wepReq.keyData[hexIndex div 2] = (hi shl 4) or lo",
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
    for source in [
        *blecontroller_policy_paths(),
        *wifi_fw_policy_paths(),
    ]:
        relative = source.relative_to(ROOT)
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
    for source in [
        *blecontroller_policy_paths(),
        *wifi_fw_policy_paths(),
        ROOT / "examples/m0_ble_wifi_hal_test.nim",
    ]:
        text = source.read_text()
        assert "when defined(bl808WifiNimFw)" not in text
        assert "when not defined(bl808WifiNimFw)" not in text


def test_wifi_firmware_task_state_transitions_use_named_constants():
    wifi_fw = wifi_fw_policy_source()
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
    wifi_fw = wifi_fw_policy_source()

    michael_layout = wifi_fw.split(
        "MichaelMicContextView {.packed.} = object", 1
    )[1].split("StaInfoView {.packed.} = object", 1)[0]
    cmac_shift_body = wifi_fw.split("proc aes_cmac_shift_sub_key*", 1)[1].split(
        "proc mfp_is_robust_frame*", 1
    )[0]
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
    aes_encrypt_body = wifi_fw.split("proc aes_encrypt_block*", 1)[1].split(
        "# ###########################################################################\n#                  HSU: Hardware Security Unit",
        1,
    )[0]
    cmac_body = wifi_fw.split("proc hsu_aes_cmac*", 1)[1].split(
        "proc hsu_michael_init*", 1
    )[0]

    assert "MichaelMicContextView {.packed.} = object" in wifi_fw
    assert "left*: uint32" in wifi_fw
    assert "right*: uint32" in wifi_fw
    assert "pending*: uint32" in wifi_fw
    assert "nBytes*: uint8" in wifi_fw
    assert "nBytesTailPadding*: array[3, uint8]" in wifi_fw
    assert "doAssert sizeof(MichaelMicContextView) == 16" in wifi_fw
    assert "doAssert offsetof(MichaelMicContextView, pending) == 8" in wifi_fw
    assert "doAssert offsetof(MichaelMicContextView, nBytes) == 12" in wifi_fw
    assert "doAssert offsetof(MichaelMicContextView, nBytesTailPadding) == 13" in wifi_fw
    assert "template michaelMicContextAt(p: pointer): ptr MichaelMicContextView" in wifi_fw
    assert "reserved13*" not in michael_layout
    assert "proc michael_block*(ctx: pointer, messageWord: uint32)" in wifi_fw
    assert "let mic = michaelMicContextAt(ctx)" in block_body
    assert "var L = mic.left" in block_body
    assert "var R = mic.right" in block_body
    assert "L = L xor messageWord" in block_body
    assert "mic.left = R" in block_body
    assert "mic.right = L" in block_body
    assert "let michaelMicContextPtr = micCtx" in mic_init_body
    assert "let mic = michaelMicContextAt(michaelMicContextPtr)" in mic_init_body
    assert "mic.left = cast[ptr uint32](key)[]" in mic_init_body
    assert "mic.right = cast[ptr UncheckedArray[uint32]](key)[1]" in mic_init_body
    assert "mic.pending = 0" in mic_init_body
    assert "mic.nBytes = 0" in mic_init_body
    assert "var nBytes = mic.nBytes" in mic_calc_body
    assert "var pending = mic.pending" in mic_calc_body
    assert "var micInputByteOffset: uint32 = 0" in mic_calc_body
    assert "for pendingWordFillByteIndex in 0'u32 ..< toProcess:" in mic_calc_body
    assert "for tailMicByteIndex in 0'u32 ..< remaining:" in mic_calc_body
    assert "micInputBytes[micInputByteOffset]" in mic_calc_body
    assert "micInputByteOffset += 4" in mic_calc_body
    assert "micInputByteOffset += 1" in mic_calc_body
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
        "let ctx = micCtx",
        "var offset: uint32 = 0",
        "micInputBytes[offset]",
        "for i in 0'u32 ..< toProcess:",
        "for i in 0'u32 ..< remaining:",
        "proc michael_block*(ctx: pointer, val: uint32)",
        "L = L xor val",
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
    assert "for roundKeyWordIndex in 4'u32 ..< 44:" in cmac_body
    assert "let previousWordByteOffset = (roundKeyWordIndex - 1) * 4" in cmac_body
    assert "roundKeys[previousWordByteOffset.int + wordByteIndex]" in cmac_body
    assert "let roundKeyWordByteOffset = roundKeyWordIndex * 4" in cmac_body
    assert "let previousRoundKeyWordByteOffset = (roundKeyWordIndex - 4) * 4" in cmac_body
    assert "roundKeys[roundKeyWordByteOffset.int + wordByteIndex] =" in cmac_body
    assert "for cmacBlockByteIndex in 0 ..< 16:" in cmac_body
    assert "for lastBlockByteIndex in 0 ..< 16:" in cmac_body
    assert "for finalCmacByteIndex in 0 ..< 16:" in cmac_body
    assert "let stateBytes = cast[ptr array[16, uint8]](state)" in aes_encrypt_body
    assert "substituted[substitutionByteIndex] = AES_SBOX[stateBytes[substitutionByteIndex].int]" in aes_encrypt_body
    assert "for finalStateByteIndex in 0 ..< 16:" in aes_encrypt_body
    assert "let columnByteOffset = col * 4" in aes_encrypt_body
    assert "let col0 = shifted[columnByteOffset]" in aes_encrypt_body
    assert "stateBytes[columnByteOffset + 3] =" in aes_encrypt_body
    assert "let off = i * 4" not in cmac_body
    assert "let prevOff = (i - 1) * 4" not in cmac_body
    assert "let prevWordOff = (i - 4) * 4" not in cmac_body
    assert "roundKeys[previousWordByteOffset.int + j]" not in cmac_body
    assert "roundKeys[roundKeyWordByteOffset.int + j]" not in cmac_body
    assert "substituted[i] = AES_SBOX[stateBytes[i].int]" not in aes_encrypt_body
    assert "let s = cast[ptr array[16, uint8]](state)" not in aes_encrypt_body
    assert "let b = col * 4" not in aes_encrypt_body
    for expected in [
        "let subkeyWord0 = subkeyWords[0]",
        "let subkeyWord1 = subkeyWords[1]",
        "let subkeyWord2 = subkeyWords[2]",
        "let subkeyWord3 = subkeyWords[3]",
        "let msb = (subkeyWord0 and 0x80'u32) != 0",
        "((subkeyWord1 shl 17) and interMask)",
        "((subkeyWord3 shr 15) and carryMask)",
    ]:
        assert expected in cmac_shift_body
    for forbidden in [
        "let w0 = subkeyWords[0]",
        "let w1 = subkeyWords[1]",
        "let w2 = subkeyWords[2]",
        "let w3 = subkeyWords[3]",
    ]:
        assert forbidden not in cmac_shift_body


def test_wifi_tkip_group_mic_path_is_explicit_reference_return():
    wifi_fw = wifi_fw_policy_source()
    mic_area_layout = wifi_fw.split(
        "TkipMicKeyAreaView {.packed.} = object", 1
    )[1].split("RxMicWordsView {.packed.} = object", 1)[0]
    mic_scratch_layout = wifi_fw.split(
        "HostTxMicScratchView {.packed.} = object", 1
    )[1].split("CfgApiElementEntryView {.packed.} = object", 1)[0]
    body = wifi_fw.rsplit("proc txu_cntrl_tkip_mic_append*", 1)[1].split(
        "proc txu_cntrl_protect_mgmt_frame*", 1
    )[0]

    for expected in [
        "TkipMicKeyAreaView {.packed.} = object",
        "micAreaBaseToScratchPadding*: uint32",
        "scratch*: pointer",
        "scratchToKeyMaterialPadding*: array[16, uint8]",
        "keyMaterial*: array[8, uint8]",
        "doAssert sizeof(TkipMicKeyAreaView) == 32",
        "doAssert offsetof(TkipMicKeyAreaView, micAreaBaseToScratchPadding) == 0",
        "doAssert offsetof(TkipMicKeyAreaView, scratch) == 4",
        "doAssert offsetof(TkipMicKeyAreaView, scratchToKeyMaterialPadding) == 8",
        "doAssert offsetof(TkipMicKeyAreaView, keyMaterial) == 24",
        "template tkipMicKeyArea(key: ptr VifKeySlotView;",
        "HostTxMicScratchView {.packed.} = object",
        "initialLeftWord*: uint32",
        "micInputCursor*: pointer",
        "micInputEnd*: pointer",
        "pendingWord*: uint32",
        "micInputScratch*: array[12, uint8]",
        "doAssert offsetof(HostTxMicScratchView, initialLeftWord) == 4",
        "doAssert offsetof(HostTxMicScratchView, micInputCursor) == 8",
        "doAssert offsetof(HostTxMicScratchView, micInputEnd) == 12",
        "doAssert offsetof(HostTxMicScratchView, pendingWord) == 16",
        "doAssert offsetof(HostTxMicScratchView, micInputScratch) == 20",
    ]:
        assert expected in wifi_fw

    assert "Group-key/other TKIP modes follow the reference path" in body
    assert "no immediate software MIC is appended" in body
    assert "let micArea = tkipMicKeyArea(key, micKeyOff)" in body
    assert "if micArea.scratch != nil:" in body
    assert "micArea.scratch = cast[pointer](scratch)" in body
    assert "scratch.micInputCursor = cast[pointer](addr scratch.micInputScratch[0])" in body
    assert "scratch.micInputEnd = cast[pointer](addr scratch.micInputScratch[3])" in body
    assert "scratch.micInputEnd = cast[pointer](addr scratch.micInputScratch[11])" in body
    assert "scratch.pendingWord = 0" in body
    assert "scratch.initialLeftWord = 0" in body
    assert "let keyMaterial = cast[pointer](addr micArea.keyMaterial[0])" in body
    assert "let bodyStart = hostTxLinkMacHdrPtr(link, 26'u)" in body
    assert "me_mic_calc(micCtxPtr, bodyStart, bodyLen.uint32)" in body
    assert "for micByteIndex in 0 ..< 8:" in body
    assert "micDst[micByteIndex] = micResult[micByteIndex]" in body
    assert "# Group key MIC: similar but with different addresses" not in body
    assert "let bodyStart = linkAddr + 348 + 26" not in body
    assert "let frameHdr = cast[uint](payloadPtr) + 348" not in body
    assert "let txPayloadEnd = desc.bufDesc" not in body
    assert "let endOff = cast[ptr uint32](linkAddr + 76)[]" not in body
    assert "let keyAddr = cast[uint](keySlot)" not in body
    assert "let micAreaBase = keyAddr + micKeyOff - 24" not in body
    assert "reserved0*" not in mic_area_layout
    assert "reserved8*" not in mic_area_layout
    for forbidden in [
        "micLInit*",
        "dataPtr*",
        "endPtr*",
        "pending*: uint32",
        "data*: array[12, uint8]",
    ]:
        assert forbidden not in mic_scratch_layout
    assert "cast[ptr pointer](micAreaBase + 4)[]" not in body
    assert "cast[ptr pointer](micAreaBase + 4)[] = cast[pointer](scratch)" not in body
    assert "let keyMaterial = cast[pointer](keyAddr + micKeyOff)" not in body
    assert "scratch.dataPtr" not in body
    assert "scratch.endPtr" not in body
    assert "scratch.pending = 0" not in body
    assert "scratch.micLInit = 0" not in body
    assert "for i in 0 ..< 8:" not in body
    assert "micDst[i] = micResult[i]" not in body
    assert "\n    discard\n" not in body


def test_wifi_mgmt_protection_uses_typed_frame_control_overlay():
    wifi_fw = wifi_fw_policy_source()
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
    wifi_fw = wifi_fw_policy_source()
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


def test_wifi_rxu_management_dispatch_overlay_has_semantic_padding():
    wifi_fw = wifi_fw_policy_source()

    sm_body = wifi_fw.rsplit("proc rxu_mgt_ind_handler_sm", 1)[1].split(
        "proc rxu_mgt_ind_handler_apm", 1
    )[0]
    bam_body = wifi_fw.rsplit("proc rxu_mgt_ind_handler_bam*", 1)[1].split(
        "# ###########################################################################\n#                  MFP",
        1,
    )[0]
    dispatch_layout = wifi_fw.split(
        "RxuMgtDispatchView {.packed.} = object", 1
    )[1].split("SmSaQueryFrameView {.packed.} = object", 1)[0]

    for expected in [
        "RxuMgtDispatchView {.packed.} = object",
        "rxuHeaderFrameCtrlPadding*: array[2, uint8]",
        "frameCtrlStaIdxPadding*: array[3, uint8]",
        "vifIdxActionBodyPadding*: array[23, uint8]",
        "doAssert offsetof(RxuMgtDispatchView, rxuHeaderFrameCtrlPadding) == 0",
        "doAssert offsetof(RxuMgtDispatchView, frameCtrlStaIdxPadding) == 4",
        "doAssert offsetof(RxuMgtDispatchView, vifIdxActionBodyPadding) == 9",
        "let msg = rxuMgtDispatchView(param)",
        "let frameType = msg.frameCtrl and 0xFC'u16",
        "if msg.category == 8'u8:",
        "if msg.actionCode != 0'u8:",
        "let baParam = msg.baParam",
        "let dialogToken = msg.dialogToken",
        "let staIdx = msg.staIdx",
    ]:
        assert expected in wifi_fw

    assert "let frameType = msg.frameCtrl and 0xFC'u16" in sm_body
    assert "if msg.category == 8'u8:" in sm_body
    assert "if msg.actionCode != 0'u8:" in bam_body

    for forbidden in [
        "reserved00*",
        "reserved04*",
        "reserved09*",
    ]:
        assert forbidden not in dispatch_layout


def test_wifi_mm_rx_upload_flags_are_named_by_effect():
    wifi_fw = wifi_fw_policy_source()
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
    mm_env_layout = wifi_fw.split(
        "MmEnvView {.packed.} = object", 1
    )[1].split("MmWmmParameterSourceView {.packed.} = object", 1)[0]
    mm_bcn_layout = wifi_fw.split(
        "MmBcnEnvView {.packed.} = object", 1
    )[1].split("BeaconChangeReqView {.packed.} = object", 1)[0]
    beacon_change_layout = wifi_fw.split(
        "BeaconChangeReqView {.packed.} = object", 1
    )[1].split("BeaconEndDescView {.packed.} = object", 1)[0]

    for expected in [
        "hardwareModeToListenWindowPadding*: array[4, uint8]",
        "maxAmpduDurationTailPadding*: array[12, uint8]",
        "doAssert offsetof(MmEnvView, hardwareModeToListenWindowPadding) == 20",
        "rxPromiscUploadFlag*: uint32",
        "apPromiscUploadFlag*: uint32",
        "doAssert offsetof(MmEnvView, rxPromiscUploadFlag) == 44",
        "doAssert offsetof(MmEnvView, apPromiscUploadFlag) == 48",
        "doAssert offsetof(MmEnvView, maxAmpduDurationTailPadding) == 56",
        "deferredChangeQueuePadding*: uint8",
        "doAssert offsetof(MmBcnEnvView, deferredChangeQueuePadding) == 11",
        "beaconChangeBaseToLengthsPadding*: array[4, uint8]",
        "doAssert offsetof(BeaconChangeReqView, beaconChangeBaseToLengthsPadding) == 0",
        "vifIdxFrameDataPadding*: array[2, uint8]",
        "doAssert offsetof(BeaconChangeReqView, vifIdxFrameDataPadding) == 10",
        "if mm.rxPromiscUploadFlag != 0:",
        "if mm.apPromiscUploadFlag != 0:",
    ]:
        assert expected in wifi_fw
    for forbidden in [
        "reserved20*",
        "reserved56*",
    ]:
        assert forbidden not in mm_env_layout
    assert "reserved11*" not in mm_bcn_layout
    assert "reserved00*" not in beacon_change_layout
    assert "reserved10*" not in beacon_change_layout

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


def test_wifi_intc_handler_init_uses_semantic_irq_slot_names():
    wifi_fw = wifi_fw_policy_source()
    body = wifi_fw.rsplit("proc intc_handlers_init()", 1)[1].split(
        "proc intc_init*", 1
    )[0]

    for expected in [
        "for irqHandlerSlotIndex in 0 ..< intc_handler_tab.len:",
        "intc_handler_tab[irqHandlerSlotIndex] = nil",
        "for spuriousIrqSlotIndex in 24 .. 39:",
        "intc_handler_tab[spuriousIrqSlotIndex] = cast[pointer](intc_spurious)",
    ]:
        assert expected in body

    for forbidden in [
        "for i in 0 ..< intc_handler_tab.len:",
        "intc_handler_tab[i] = nil",
        "for i in 24 .. 39:",
        "intc_handler_tab[i] = cast[pointer](intc_spurious)",
    ]:
        assert forbidden not in body


def test_wifi_set_active_confirm_handlers_use_state_predicates():
    wifi_fw = wifi_fw_policy_source()

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
