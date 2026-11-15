"""Check scan-cache publication identity, including deterministic address reuse."""

from pathlib import Path

import pytest

from test_wifi_bss_selection import selection_source
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_scan_selection_owner import source as owner_source


def cache_helpers() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = ""
    if "proc scanuResetCachedSsid(" in scan:
        code += procedure(scan, "scanuResetCachedSsid")
    for name in ["scanuClearCachedSsid", "scanuCacheSsid"]:
        code += procedure(scan, name)
    return code


def source() -> str:
    code = owner_source()
    code = code.replace(
        'proc malloc(size: csize_t): pointer {.importc, header: "<stdlib.h>".}\n'
        'proc free(p: pointer) {.importc, header: "<stdlib.h>".}\n',
        r'''
var reusedBlock: array[512, uint8]
var blockInUse = false
proc malloc(size: csize_t): pointer =
  doAssert not blockInUse and size <= reusedBlock.len.csize_t
  blockInUse = true
  addr reusedBlock[0]
proc free(p: pointer) =
  doAssert blockInUse and p == addr reusedBlock[0]
  blockInUse = false
''', 1)
    code += r'''
proc c_memset(p: pointer; value: cint; size: csize_t): pointer {.importc: "memset", header: "<string.h>".}
type MacAddress = object
  bytes: array[6, uint8]
proc macAddrAt(p: pointer): ptr MacAddress = cast[ptr MacAddress](p)
var scanuCachedChannels: array[SCANU_MAX_RESULT_ENTRIES, ScanChannelEntry]
'''
    code += cache_helpers()
    code += procedure((FW / "scan_station_ap_me.nim").read_text(), "scanu_find_result")
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_identical_republication_invalidates_snapshot(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for clearFirst in [false, true]:
  setup()
  let entry = addr scanu_env.entries[0]
  let snapshot = scanuCaptureResult(entry)
  if clearFirst: scanuClearCachedSsid(entry)
  scanuCacheSsid(entry, addr query)
  doAssert not scanuResultCurrent(snapshot), "same-valued republication reused identity"
  doAssert scanuResultCurrent(scanuCaptureResult(entry))
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_raw_storage_reuse_rejects_old_selection(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
let raw = prepareRaw([109'u8, 101, 115, 104], 4)
var replaced = false
traceHook = proc(tag: string) =
  if tag != "vendor_match" or replaced: return
  replaced = true
  free(raw)
  let replacement = frame([109'u8, 101, 115, 104], 4)
  doAssert replacement == raw
  let view = rxuMgtIndAt(replacement)
  view.frameLen += 4
  view.ieData[6] = 222
  view.ieData[7] = 2
  view.ieData[8] = 1
  view.ieData[9] = 2
  scanuCacheSsid(addr scanu_env.entries[0], addr query)
  scanu_env.entries[0].cachedRxuMgtInd = replacement
var selected = 0x12345678'u32
doAssert scanu_search_by_ssid(addr query, addr selected) == nil,
  "old lookup selected a new frame at the same address"
doAssert replaced and selected == 0x12345678'u32
traceHook = nil
doAssert scanu_search_by_ssid(addr query, addr selected) == addr scanu_env.entries[0]
doAssert selected == 0
free(raw)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reacquired_slot_does_not_restore_old_identity(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
let entry = addr scanu_env.entries[0]
let before = entry[]
let snapshot = scanuCaptureResult(entry)
entry.valid = 0
doAssert scanu_find_result(addr before.bssid[0], 1) == entry
entry[] = before
scanuCacheSsid(entry, addr query)
doAssert not scanuResultCurrent(snapshot)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bss_republication_during_final_log(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, selection_source() + cache_helpers() + r'''
prepare(2)
var bss, chan: pointer
discard selectBss(addr bss, addr chan)
let finalCall = boundaryCalls.len
prepare(2)
var slot = ScanSsidSlotView(length: 4)
slot.ssidBytes[0..3] = conn.ssid[0..3]
var replaced = false
boundaryHook = proc(point: string) =
  if boundaryCalls.len == finalCall:
    replaced = true
    scanuCacheSsid(addr scanu_env.entries[0], addr slot)
doAssert not selectBss(addr bss, addr chan)
doAssert replaced and bss == nil and chan == nil and configured == 0
doAssert conn.authType == 7 and sm.scanResultIndex == 0xFFFFFFFF'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_generation_is_per_slot_and_wraps(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  setup()
  interruptsEnabled = incoming
  let entry = addr scanu_env.entries[0]
  scanuCachedSsids[0].generation = high(uint32)
  let old = scanuCaptureResult(entry)
  let other = scanuCaptureResult(addr scanu_env.entries[1])
  scanuClearCachedSsid(entry)
  doAssert scanuCachedSsids[0].generation == 0
  doAssert scanuCachedSsids[0].valid == 0 and scanuCachedSsids[0].length == 0
  for value in scanuCachedSsids[0].ssidBytes: doAssert value == 0
  scanuCacheSsid(entry, addr query)
  doAssert scanuCachedSsids[0].generation == 1
  doAssert not scanuResultCurrent(old)
  doAssert scanuResultCurrent(scanuCaptureResult(entry))
  doAssert scanuResultCurrent(other)
  doAssert interruptsEnabled == incoming
  scanuClearCachedSsid(nil)
  var external = ScanuResultEntry(valid: 1)
  scanuCacheSsid(addr external, addr query)
  doAssert scanuCachedSsids[0].generation == 1
  doAssert interruptsEnabled == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reservation_retains_vendor_search_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  setup()
  interruptsEnabled = incoming
  for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    scanu_env.entries[i].bssid = [2'u8, 0, 0, 0, 0, (i + 1).uint8]
    scanuCachedSsids[i].generation = 10
  var wanted = scanu_env.entries[4].bssid
  let existing = scanuCaptureResult(addr scanu_env.entries[4])
  doAssert scanu_find_result(addr wanted[0], 1) == addr scanu_env.entries[4]
  doAssert scanuResultCurrent(existing)
  scanu_env.entries[0].valid = 0
  doAssert scanu_find_result(addr wanted[0], 0) == addr scanu_env.entries[4]
  doAssert scanu_find_result(addr wanted[0], 1) == addr scanu_env.entries[0]
  doAssert scanuCachedSsids[0].generation == 11 and scanuCachedSsids[0].valid == 0
  doAssert scanu_env.entries[0].rssi == -128 and scanu_env.entries[0].valid == 0
  doAssert scanuResultCurrent(existing)
  doAssert interruptsEnabled == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_raw_pruning_preserves_result_generation(tmp_path: Path, mode: str) -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = source() + procedure(scan, "scanuDetachRawScanFrames")
    run_program(tmp_path, mode, code + r'''
let raw = prepareRaw([109'u8, 101, 115, 104])
let entry = addr scanu_env.entries[0]
let snapshot = scanuCaptureResult(entry)
let retired = scanuDetachRawScanFrames()
doAssert retired[0] == raw and entry.cachedRxuMgtInd == nil
doAssert scanuCachedSsids[0].generation == snapshot.ssid.generation
doAssert scanuResultCurrent(snapshot, true)
doAssert not scanuResultCurrent(snapshot)
free(retired[0])
''')


def test_generation_stays_outside_vendor_entry_layout() -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    vendor_entry = layout.split("ScanuResultEntry* = object", 1)[1].split("ScanuCachedSsid*", 1)[0]
    assert "generation" not in vendor_entry
    assert "generation: uint32" in layout.split("ScanuCachedSsid* = object", 1)[1].split("ScanuEnvObj*", 1)[0]
    assert "scanuResetCachedSsid" in procedure(scan, "scanu_find_result")
    assert "scanuResetCachedSsid" in procedure(scan, "scanuClearCachedSsid")
    assert "scanuResetCachedSsid" in procedure(scan, "scanuCacheSsid")
    assert "scanuResetCachedSsid" not in procedure(scan, "scanuDetachRawScanFrames")
