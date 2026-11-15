"""Exercise raw SSID selection with exact-sized frame and query allocations."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_scan_selection import source as retained_source


def source() -> str:
    code = layouts("RxuMgtIndView", "MacIeView", "SsidIeView") + retained_source()
    for name, replacement in {
        "rxuMgtIndAt": "proc rxuMgtIndAt(p: pointer): ptr RxuMgtIndView = cast[ptr RxuMgtIndView](p)\n",
        "rxuMgtIndIeStart": procedure((FW / "layout_types.nim").read_text(), "rxuMgtIndIeStart"),
        "mac_ie_find": procedure((FW / "mac_config_debug.nim").read_text(), "mac_ie_find"),
        "ssidIeAt": "proc ssidIeAt(p: pointer): ptr SsidIeView = cast[ptr SsidIeView](p)\n",
    }.items():
        code = code.replace(procedure(code, name), replacement, 1)
    code = code.replace("proc mac_ie_find", """proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
proc totalLen(ie: ptr MacIeView): uint = ie.len.uint + 2
proc mac_ie_find""", 1)
    return code + r'''
proc malloc(size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc frame(ssid: openArray[uint8]; padding = 0): pointer =
  let size = sizeof(RxuMgtIndView) + 2 + ssid.len + padding
  result = malloc(size.csize_t)
  doAssert result != nil
  zeroMem(result, size)
  let raw = rxuMgtIndAt(result)
  raw.frameLen = (36 + 2 + ssid.len).uint16
  raw.ieData[0] = 0
  raw.ieData[1] = ssid.len.uint8
  for i, value in ssid: raw.ieData[2 + i] = value
proc prepareRaw(ssid: openArray[uint8]; padding = 0): pointer =
  setup()
  for slot in 1 ..< SCANU_MAX_RESULT_ENTRIES: scanu_env.entries[slot].valid = 0
  result = frame(ssid, padding)
  scanu_env.entries[0].cachedRxuMgtInd = result
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_short_raw_element(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for length in 0 .. 3:
  var rawSsid = newSeq[uint8](length)
  for value in rawSsid.mitems: value = 120
  let raw = prepareRaw(rawSsid)
  var selected = 0xFFFFFFFF'u32
  doAssert scanu_search_by_ssid(addr query, addr selected) == addr scanu_env.entries[0]
  doAssert selected == 0
  free(raw)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_short_raw_element_with_long_cached_match(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
query.length = 32
for value in query.ssidBytes.mitems: value = 81
for length in 0 .. 3:
  var rawSsid = newSeq[uint8](length)
  for value in rawSsid.mitems: value = 120
  let raw = prepareRaw(rawSsid, 4)
  var selected = 0xFFFFFFFF'u32
  doAssert scanu_search_by_ssid(addr query, addr selected) == addr scanu_env.entries[0]
  doAssert selected == 0
  free(raw)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_compact_query(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for length in 1 .. 3:
  let compact = cast[ptr UncheckedArray[uint8]](malloc((length + 1).csize_t))
  compact[0] = length.uint8
  for i in 0 ..< length: compact[i + 1] = (65 + i).uint8
  query.length = length.uint8
  for i in 0 ..< length: query.ssidBytes[i] = compact[i + 1]
  setup()
  for slot in 1 ..< SCANU_MAX_RESULT_ENTRIES: scanu_env.entries[slot].valid = 0
  var selected = 0xFFFFFFFF'u32
  doAssert scanu_search_by_ssid(compact, addr selected) == addr scanu_env.entries[0]
  doAssert selected == 0
  free(compact)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_query(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
var selected = 0x12345678'u32
doAssert scanu_search_by_ssid(nil, addr selected) == nil
doAssert selected == 0x12345678'u32
let empty = cast[ptr uint8](malloc(1))
empty[] = 0
doAssert scanu_search_by_ssid(empty, addr selected) == nil
doAssert selected == 0x12345678'u32
free(empty)
query.length = 33
scanuCachedSsids[0].length = 33
for slot in 1 ..< SCANU_MAX_RESULT_ENTRIES: scanu_env.entries[slot].valid = 0
doAssert scanu_search_by_ssid(addr query, addr selected) == nil
doAssert selected == 0x12345678'u32
let oversized = cast[ptr uint8](malloc(1))
for length in [33'u8, 255'u8]:
  oversized[] = length
  doAssert scanu_search_by_ssid(oversized, addr selected) == nil
  doAssert selected == 0x12345678'u32
free(oversized)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_raw_and_retained_matches(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for length in 1 .. 32:
  query.length = length.uint8
  for value in query.ssidBytes.mitems: value = 81
  var rawSsid = newSeq[uint8](length)
  for value in rawSsid.mitems: value = 81
  let raw = prepareRaw(rawSsid)
  scanuCachedSsids[0].valid = 0
  var selected = 0xFFFFFFFF'u32
  doAssert scanu_search_by_ssid(addr query, addr selected) == addr scanu_env.entries[0]
  free(raw)
let raw = prepareRaw([120'u8, 120, 120, 120])
query.length = 4
for value in query.ssidBytes.mitems: value = 109
scanuCachedSsids[0].valid = 0
var selected = 0xFFFFFFFF'u32
doAssert scanu_search_by_ssid(addr query, addr selected) == nil
doAssert selected == 0xFFFFFFFF'u32
free(raw)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_raw_length_mismatch_without_cached_match(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for length in [0, 1, 3, 5, 33, 255]:
  var rawSsid = newSeq[uint8](length)
  for value in rawSsid.mitems: value = 109
  let raw = prepareRaw(rawSsid)
  scanuCachedSsids[0].valid = 0
  var selected = 0x12345678'u32
  doAssert scanu_search_by_ssid(addr query, addr selected) == nil
  doAssert selected == 0x12345678'u32
  free(raw)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_missing_or_incomplete_raw_element(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for frameLen in [0'u16, 35'u16, 36'u16, 37'u16, 38'u16]:
  let raw = prepareRaw([])
  rxuMgtIndAt(raw).frameLen = frameLen
  rxuMgtIndAt(raw).ieData[1] = 32
  var selected = 0xFFFFFFFF'u32
  doAssert scanu_search_by_ssid(addr query, addr selected) == addr scanu_env.entries[0]
  doAssert selected == 0
  scanuCachedSsids[0].valid = 0
  selected = 0x12345678'u32
  doAssert scanu_search_by_ssid(addr query, addr selected) == nil
  doAssert selected == 0x12345678'u32
  free(raw)
''')


def traced_source() -> str:
    code = source()
    return code.replace(procedure(code, "nimFwTrace2U32"), r'''
var traceHook: proc(tag: string)
proc nimFwTrace2U32(tag: string; a, b: uint32) =
  if traceHook != nil: traceHook(tag)
''', 1)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_query_snapshot_before_trace(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, traced_source() + r'''
let compact = cast[ptr UncheckedArray[uint8]](malloc(5))
compact[0] = 4
for i in 0 ..< 4: compact[i + 1] = query.ssidBytes[i]
setup()
for slot in 1 ..< SCANU_MAX_RESULT_ENTRIES: scanu_env.entries[slot].valid = 0
traceHook = proc(tag: string) =
  if tag == "[WIFI-NIMFW] ssid_s ":
    free(compact)
var selected = 0xFFFFFFFF'u32
doAssert scanu_search_by_ssid(compact, addr selected) == addr scanu_env.entries[0]
doAssert selected == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_raw_frame_released_by_trace(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, traced_source() + r'''
discard prepareRaw([109'u8, 101, 115, 104])
traceHook = proc(tag: string) =
  if tag == "[WIFI-NIMFW] ssid_e ":
    let raw = scanu_env.entries[0].cachedRxuMgtInd
    scanu_env.entries[0].cachedRxuMgtInd = nil
    free(raw)
var selected = 0xFFFFFFFF'u32
doAssert scanu_search_by_ssid(addr query, addr selected) == addr scanu_env.entries[0]
doAssert selected == 0
''')
