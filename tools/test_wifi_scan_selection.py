"""Verify retained-SSID selection returns a matching result pointer and index."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program

PLATFORM = r'''
const SCANU_MAX_RESULT_ENTRIES = 6
const IE_ID_SSID = 0'u8
type
  Env = object
    entries: array[SCANU_MAX_RESULT_ENTRIES, ScanuResultEntry]
  RawFrame = object
    frameLen: uint16
  MacIe = object
    id, len: uint8
  SsidIe = object
    ie: MacIe
    ssidBytes: array[32, uint8]
  Log = proc(a, b: uint32; data: pointer; line: uint32) {.cdecl, varargs.}
var
  scanu_env: Env
  scanuCachedSsids: array[SCANU_MAX_RESULT_ENTRIES, ScanuCachedSsid]
  scanuRequestEpoch: uint32
  nimFwDbgSsidSearch, nimFwDbgSsidEntries, nimFwDbgSsidHits: uint32
  interruptsEnabled = true
proc irqSave(): uint32 =
  result = interruptsEnabled.uint32 * 8
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
proc c_memcmp(a, b: pointer; size: csize_t): cint {.importc: "memcmp", header: "<string.h>".}
proc lengthPrefixedSsidView(p: pointer): ptr ScanSsidSlotView = cast[ptr ScanSsidSlotView](p)
proc nimFwTrace2U32(tag: string; a, b: uint32) = discard
proc nimFwConnectTrace2U32(tag: string; a, b: uint32) = discard
proc getLogFunc(offset: int): Log = nil
proc rxuMgtIndAt(p: pointer): ptr RawFrame = cast[ptr RawFrame](p)
proc rxuMgtIndIeStart(p: pointer): pointer =
  doAssert false, "this fixture exercises retained SSIDs only"
proc mac_ie_find(p: pointer; length: uint32; kind: uint8): pointer =
  doAssert false
proc ssidIeAt(p: pointer): ptr SsidIe = cast[ptr SsidIe](p)
'''


def snapshot_source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    body = scan.split("type ScanuResultSnapshot = object", 1)[1].split("\n{.emit:", 1)[0]
    return "type ScanuResultSnapshot = object" + body + "\n"


def source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = layouts("ScanSsidSlotView", "ScanuCachedSsid", "ScanuResultEntry", "ScanChannelEntry") + PLATFORM
    for name in ["scanuCachedSsidFor", "scanuCachedSsidMatches", "scanuCachedSsidMeta"]:
        code += procedure(scan, name)
    code += snapshot_source() + procedure(scan, "scanu_search_by_ssid")
    return code + r'''
var query = ScanSsidSlotView(length: 4)
query.ssidBytes[0 .. 3] = [109'u8, 101, 115, 104]
proc setup() =
  scanu_env = default(Env)
  for slot in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    scanu_env.entries[slot] = ScanuResultEntry(valid: 1, rssi: -60)
    scanuCachedSsids[slot] = ScanuCachedSsid(valid: 1, length: query.length)
    for i in 0 ..< query.length.int:
      scanuCachedSsids[slot].ssidBytes[i] = query.ssidBytes[i]
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_selected_index_matches_entry(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for strongest in 0 ..< SCANU_MAX_RESULT_ENTRIES:
  setup()
  scanu_env.entries[strongest].rssi = -10
  var selected = 0xFFFFFFFF'u32
  let entry = scanu_search_by_ssid(addr query, addr selected)
  doAssert entry == addr scanu_env.entries[strongest]
  doAssert selected == strongest.uint32, "selected index does not identify returned entry"
setup()
var selected = 0xFFFFFFFF'u32
doAssert scanu_search_by_ssid(addr query, addr selected) == addr scanu_env.entries[0]
doAssert selected == 0, "equal RSSI must retain the first entry and its index"
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_no_selection_preserves_index(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for absent in 0 .. 2:
  setup()
  for slot in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    case absent
    of 0: scanu_env.entries[slot].valid = 0
    of 1: scanuCachedSsids[slot].ssidBytes[0] = 120
    else: scanu_env.entries[slot].rssi = -128
  var selected = 0x12345678'u32
  doAssert scanu_search_by_ssid(addr query, addr selected) == nil
  doAssert selected == 0x12345678'u32
setup()
doAssert scanu_search_by_ssid(addr query, nil) == addr scanu_env.entries[0]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_transition_key_management_selection(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, f'import "{FW / "rsn_parse"}"\n' + r'''
for bits in 0 .. 7:
  let mask = (if (bits and 1) != 0: WifiAuthMaskPsk else: 0'u32) or
    (if (bits and 2) != 0: WifiAuthMaskPskSha256 else: 0'u32) or
    (if (bits and 4) != 0: WifiAuthMaskSae else: 0'u32)
  let expected = if (bits and 1) != 0: WifiKeyMgmtPsk
                 elif (bits and 2) != 0: WifiKeyMgmtPskSha256
                 elif (bits and 4) != 0: WifiKeyMgmtSae
                 else: WifiKeyMgmtNone
  for pmf in [false, true]:
    for extra in [0'u32, 0x80000000'u32]:
      let selected = wifiPreferredKeyMgmtFromMask(mask or extra, pmf)
      doAssert selected == expected
      doAssert wifiDot11AuthTypeFromKeyMgmt(selected) ==
        (if expected == WifiKeyMgmtSae: 3'u8 else: 0'u8)
''')
