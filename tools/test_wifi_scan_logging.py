"""Check scan diagnostics with bounded SSIDs and actual C variadic arguments."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
import test_wifi_scan_cache_prune as pruning
from test_wifi_scan_raw_ssid import source as raw_source
from test_wifi_scan_selection import source as retained_source


LOGGER = r'''
var
  logsEnabled, expectedIrq: bool
  scanLogs: seq[tuple[line: cint, message: string]]
  logAction: proc(line: cint)
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc scanLogger(level: uint32; tag, file: cstring; line: cint;
                format: cstring) {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil and file == cstring("scanu.c")
  doAssert interruptsEnabled == expectedIrq
  doAssert cast[uint](format) > 4096
  var output: array[160, char]
  var length: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ",
           length, " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
           format, ", args); va_end(args);"].}
  doAssert length >= 0 and length < output.len.cint
  scanLogs.add((line, $cast[cstring](addr output[0])))
  if logAction != nil: logAction(line)
proc getLogFunc(offset: int): Log =
  doAssert offset == 204
  if logsEnabled: cast[Log](scanLogger) else: nil
'''


def with_logger(code: str) -> str:
    return code.replace(procedure(code, "getLogFunc"), LOGGER, 1)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_selected_index_and_signed_rssi_logs(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, with_logger(retained_source()) + r'''
for incoming in [false, true]:
  for enabled in [false, true]:
    setup()
    logsEnabled = enabled
    scanLogs.setLen(0)
    interruptsEnabled = incoming
    expectedIrq = false
    let rssi = [-127'i8, -64, -32, -1, 0, 1]
    for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:
      scanu_env.entries[i].rssi = rssi[i]
    var selected = 99'u32
    doAssert scanu_search_by_ssid(addr query, addr selected) == addr scanu_env.entries[5]
    doAssert selected == 5 and interruptsEnabled == incoming
    doAssert scanLogs.len == (if enabled: 6 else: 0)
    if enabled:
      for i in 0 ..< scanLogs.len:
        doAssert scanLogs[i] == (1010.cint,
          "find existed ssid, idx = " & $i & ", rssi " & $rssi[i] & "\r\n")
''')
    run_program(tmp_path, mode, with_logger(raw_source()) + r'''
logsEnabled = true
expectedIrq = false
let raw = prepareRaw([109'u8, 101, 115, 104])
scanu_env.entries[0].rssi = -42
var selected = 99'u32
doAssert scanu_search_by_ssid(addr query, addr selected) == addr scanu_env.entries[0]
doAssert selected == 0
doAssert scanLogs == @[(1010.cint, "find existed ssid, idx = 0, rssi -42\r\n")]
free(raw)
''')


def removal_source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    setup = pruning.CHECKS.split("\nproc run(", 1)[0]
    return with_logger(pruning.PLATFORM) + procedure(scan, "scanu_rm_exist_ssid") + setup


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_removed_ssid_log_snapshot(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, removal_source() + r'''
for incoming in [false, true]:
  for length in [0, 1, 31, 32]:
    for replaceAtRestore in [false, true]:
      if replaceAtRestore and not incoming: continue
      setup(incoming)
      logsEnabled = true
      expectedIrq = incoming
      scanLogs.setLen(0)
      logAction = nil
      filter.length = length.uint8
      scanu_env.filterSsidLen = length.uint8
      for i in 0 ..< 32:
        filter.ssidBytes[i] = (65 + (i mod 26)).uint8
        scanu_env.filterSsid[i] = filter.ssidBytes[i]
      var expected = ""
      for i in 0 ..< length: expected.add(char(filter.ssidBytes[i]))
      var replaced = false
      proc replaceCache() =
        doAssert not replaced
        replaced = true
        doAssert scanu_env.entries[3] == default(ScanuResultEntry)
        for b in scanu_env.filterSsid.mitems: b = 120
        scanu_env.filterSsidLen = 32
        filter.length = 255
        scanu_env.entries[3] = ScanuResultEntry(valid: 1,
          cachedRxuMgtInd: addr newFrames[3], ssid: 99)
      if replaceAtRestore:
        hook = proc(point: string) =
          if point == "restore" and not replaced: replaceCache()
      else:
        logAction = proc(line: cint) =
          if line == 1032: replaceCache()
      scanu_rm_exist_ssid(addr filter, 3)
      doAssert replaced and freed[3] == 1 and interruptsEnabled == incoming
      doAssert scanu_env.entries[3].ssid == 99
      doAssert scanu_env.entries[3].cachedRxuMgtInd == addr newFrames[3]
      doAssert scanLogs == @[(1032.cint, "start scanu_rm_exist_ssid \r\n"),
        (1043.cint, "delete the existed ssid " & expected & "\r\n"),
        (1046.cint, "over scanu_rm_exist_ssid \r\n")]
      hook = nil
      logAction = nil

for embeddedZero in [false, true]:
  setup(true)
  logsEnabled = true
  expectedIrq = true
  scanLogs.setLen(0)
  filter.length = 32
  scanu_env.filterSsidLen = 32
  for i in 0 ..< 32:
    filter.ssidBytes[i] = 81
    scanu_env.filterSsid[i] = 81
  if embeddedZero:
    filter.ssidBytes[1] = 0
    scanu_env.filterSsid[1] = 0
  scanu_rm_exist_ssid(addr filter, 3)
  let expected = if embeddedZero: "Q" else: "QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
  doAssert scanLogs[1].message == "delete the existed ssid " & expected & "\r\n"
  doAssert freed[3] == 1

for invalid in [false, true]:
  setup(false)
  logsEnabled = true
  expectedIrq = false
  scanLogs.setLen(0)
  filter.ssidBytes[0] = 121
  scanu_rm_exist_ssid(addr filter, if invalid: 255'u8 else: 3'u8)
  doAssert scanLogs == (if invalid:
    @[(1032.cint, "start scanu_rm_exist_ssid \r\n")]
    else: @[(1032.cint, "start scanu_rm_exist_ssid \r\n"),
            (1046.cint, "over scanu_rm_exist_ssid \r\n")])
  doAssert freed[3] == 0
''')
