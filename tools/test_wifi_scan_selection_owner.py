"""Check selector publication when callbacks replace the selected scan state."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_scan_raw_ssid import traced_source


def source() -> str:
    code = traced_source()
    return code.replace(procedure(code, "getLogFunc"), r'''
proc matchLog(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil and file == cstring("scanu.c")
  doAssert line == 1010 and format != nil
  if traceHook != nil: traceHook("vendor_match")
proc getLogFunc(offset: int): Log = cast[Log](matchLog)
''', 1)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_selected_entry_changes_before_publication(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for point in ["[WIFI-NIMFW] ssid_e ", "[WIFI-NIMFW] ssid_hit ", "vendor_match"]:
  for mutation in 0 .. 5:
    traceHook = nil
    let raw = prepareRaw([109'u8, 101, 115, 104])
    var fired = false
    traceHook = proc(tag: string) =
      if fired or tag != point: return
      fired = true
      case mutation
      of 0: scanu_env.entries[0].valid = 0
      of 1: scanu_env.entries[0].bssid[0] = 2
      of 2: scanu_env.entries[0].rssi = -127
      of 3: scanu_env.entries[0].securityType = 0x0101
      of 4: scanuCachedSsids[0].ssidBytes[0] = 120
      else: scanu_env.entries[0].chanPtr = cast[pointer](1)
    var selected = 0x12345678'u32
    doAssert scanu_search_by_ssid(addr query, addr selected) == nil,
      "selector published a changed entry at " & point
    doAssert fired and selected == 0x12345678'u32
    free(raw)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_winner_changes_during_later_entry(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
scanu_env.entries[0].rssi = -10
var matches = 0
traceHook = proc(tag: string) =
  if tag == "vendor_match":
    inc matches
    if matches == 2: scanu_env.entries[0].valid = 0
var selected = 0x12345678'u32
doAssert scanu_search_by_ssid(addr query, addr selected) == nil
doAssert matches >= 2 and selected == 0x12345678'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_channel_and_request_changes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var channel = ScanChannelEntry(prim20Freq: 2412, txPower: 20)
for incoming in [false, true]:
  for mutation in 0 .. 4:
    traceHook = nil
    setup()
    for slot in 1 ..< SCANU_MAX_RESULT_ENTRIES: scanu_env.entries[slot].valid = 0
    scanu_env.entries[0].chanPtr = addr channel
    interruptsEnabled = incoming
    var fired = false
    traceHook = proc(tag: string) =
      doAssert not interruptsEnabled
      if fired or tag != "vendor_match": return
      fired = true
      case mutation
      of 0: inc channel.prim20Freq
      of 1: inc channel.txPower
      of 2: inc scanuRequestEpoch
      of 3: scanuCachedSsids[0].valid = 0
      else: scanuCachedSsids[0].length = 1
    var selected = 0x12345678'u32
    doAssert scanu_search_by_ssid(addr query, addr selected) == nil
    doAssert fired and selected == 0x12345678'u32
    doAssert interruptsEnabled == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_raw_replacement_is_not_raw_pruning(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for retained in [false, true]:
  traceHook = nil
  let raw = prepareRaw([109'u8, 101, 115, 104])
  let replacement = frame([120'u8, 120, 120, 120])
  scanuCachedSsids[0].valid = retained.uint8
  traceHook = proc(tag: string) =
    if tag == "vendor_match": scanu_env.entries[0].cachedRxuMgtInd = replacement
  var selected = 0x12345678'u32
  doAssert scanu_search_by_ssid(addr query, addr selected) == nil
  doAssert selected == 0x12345678'u32
  free(raw)
  free(replacement)
traceHook = nil
discard prepareRaw([109'u8, 101, 115, 104])
scanuCachedSsids[0].valid = 0
traceHook = proc(tag: string) =
  if tag == "vendor_match":
    free(scanu_env.entries[0].cachedRxuMgtInd)
    scanu_env.entries[0].cachedRxuMgtInd = nil
var selected = 0x12345678'u32
doAssert scanu_search_by_ssid(addr query, addr selected) == nil
doAssert selected == 0x12345678'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_snapshot_requires_owned_valid_entry(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
doAssert scanuCaptureResult(nil).entry == nil
var external = ScanuResultEntry(valid: 1)
doAssert scanuCaptureResult(addr external).entry == nil
let entry = addr scanu_env.entries[0]
doAssert scanuResultCurrent(scanuCaptureResult(entry))
entry.valid = 0
doAssert scanuCaptureResult(entry).entry == nil
doAssert not scanuResultCurrent(scanuCaptureResult(entry))
''')
