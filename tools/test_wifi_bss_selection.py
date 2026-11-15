"""Execute BSS selection and scan completion across connection replacements."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_auth_frames import layouts
from test_wifi_message_allocation import run_program
from test_wifi_sm_scan_completion import source as completion_source
from test_wifi_scan_selection import snapshot_source


SUPPORT = r'''
var
  boundaryCalls: seq[string]
  boundaryHook: proc(point: string)
  bssidAvailable, ssidAvailable: bool
  selectedIndex: int32
  configured: int
  logLines: seq[string]
  nimFwDbgBssIn, nimFwDbgBssSsidResult, nimFwDbgBssDirected, nimFwDbgBssOut: uint32
  scanuCachedSsids: array[SCANU_MAX_RESULT_ENTRIES, ScanuCachedSsid]
proc boundary(point: string) =
  boundaryCalls.add(point)
  if boundaryHook != nil: boundaryHook(point)
proc receiveBssLog(line: cstring) {.exportc: "test_receive_bss_log", cdecl.} =
  logLines.add($line)
  boundary("log")
{.emit: """
#include <stdarg.h>
#include <stdio.h>
void test_receive_bss_log(char *line);
static void test_format_bss_log(char *fmt, ...) {
  char line[256];
  va_list args;
  if (!fmt) { test_receive_bss_log("<null>"); return; }
  va_start(args, fmt);
  vsnprintf(line, sizeof(line), fmt, args);
  va_end(args);
  test_receive_bss_log(line);
}
""".}
proc logBss(p: cstring) {.importc: "test_format_bss_log", nodecl, cdecl, varargs.}
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 4
  cast[pointer](logBss)
proc nimFwConnectTrace2U32(tag: string; a, b: uint32) = boundary(tag)
proc connectInfoChannelHint(p: pointer): pointer = addr connectInfoView(p).channelHint[0]
proc scanuResultAt(p: pointer): ptr ScanuResultEntry = cast[ptr ScanuResultEntry](p)
proc scanResultChannelPtr(p: ptr ScanuResultEntry): pointer = p.chanPtr
proc scanuCachedSsidFor(p: ptr ScanuResultEntry): ptr ScanuCachedSsid =
  for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    if p == addr scanu_env.entries[i]: return addr scanuCachedSsids[i]
proc scanuCachedSsidMatches(p: ptr ScanuResultEntry; data: pointer; length: uint8): bool =
  if p.ssidLen != length: return false
  let bytes = cast[ptr UncheckedArray[uint8]](data)
  for i in 0 ..< length.int:
    if p.ssid[i] != bytes[i]: return false
  true
proc scanu_search_by_bssid(p: pointer): pointer =
  boundary("bssid")
  if bssidAvailable: addr scanu_env.entries[0] else: nil
proc scanu_search_by_ssid(p, index: pointer): pointer =
  boundary("ssid")
  cast[ptr int32](index)[] = selectedIndex
  if ssidAvailable: addr scanu_env.entries[0] else: nil
proc configureSelectedBssAuth(entry: ptr ScanuResultEntry; ci: ptr ConnectInfoView) =
  inc configured
  ci.authType = 3
'''


def selection_source() -> str:
    code = "{.define: bl808WifiConnectTrace.}\n" + layouts("ScanuCachedSsid") + completion_source()
    code = code.replace("    channelDuration: uint32", """    channelDuration: uint32
    bssid: array[6, uint8]
    channelHint: array[8, uint8]
    authType: uint8""", 1)
    code = code.replace("joinBssFlag, cancelRequested: uint8]",
                        "joinBssFlag, cancelRequested: uint8, scanResultIndex: uint32]", 1)
    code = code.replace("cast[pointer](addr indication), 7'u8, 0'u8)",
                        "cast[pointer](addr indication), 7'u8, 0'u8, 0xFFFFFFFF'u32)", 1)
    code = code.replace("type ScanEnvironment = object", """const SCANU_MAX_RESULT_ENTRIES = 6
type ScanuResultEntry = object
  valid, ssidLen: uint8
  rssi: int8
  ssid: array[32, uint8]
  chanPtr, cachedRxuMgtInd: pointer
type ScanEnvironment = object""", 1)
    code = code.replace("  bssidFilterEnabled, requester: uint8", """  bssidFilterEnabled, requester: uint8
  resultCount: uint32
  directedFound: uint8
  entries: array[SCANU_MAX_RESULT_ENTRIES, ScanuResultEntry]""", 1)
    scan = (FW / "scan_station_ap_me.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    helpers = SUPPORT
    for name in ["connectInfoChannelFrequency", "connectInfoHasChannelHint"]:
        helpers += procedure(layout, name)
    for name in ["bestDirectedScanuResult", "bestScanuResultForSsidAndFreq"]:
        helpers += procedure(scan, name)
    helpers += snapshot_source()
    code = code.replace(procedure(code, "sm_get_bss_params"),
                        helpers + procedure(scan, "sm_get_bss_params"), 1)
    return code + r'''
proc prepare(route: int) =
  setup()
  state = SmScanningState
  boundaryHook = nil
  boundaryCalls.setLen(0)
  configured = 0
  logLines.setLen(0)
  scanu_env = default(ScanEnvironment)
  scanu_env.resultCount = 1
  scanu_env.entries[0] = ScanuResultEntry(valid: 1, ssidLen: 4, rssi: -30,
    chanPtr: addr channel)
  scanu_env.entries[0].ssid[0..3] = conn.ssid[0..3]
  scanuCachedSsids = default(typeof(scanuCachedSsids))
  scanuCachedSsids[0].valid = 1
  scanuCachedSsids[0].length = 4
  scanuCachedSsids[0].ssidBytes[0..3] = conn.ssid[0..3]
  conn.authType = 7
  bssidAvailable = route == 0
  ssidAvailable = route in [2, 3]
  selectedIndex = if route == 3: -1 else: 0
  if route < 2: conn.bssid = [2'u8, 1, 2, 3, 4, 5]
  if route in [1, 4, 5]:
    conn.channelHint[0] = 0x9E
    conn.channelHint[1] = 0x09
  if route == 5: conn.channelHint[0] = 0x6C
  if route == 6: scanu_env.directedFound = 1
proc selectBss(bss, chan: ptr pointer): bool = sm_get_bss_params(bss, chan)
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_selection_callback_replacement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, selection_source() + r'''
for route in 0 .. 7:
  prepare(route)
  var bss, chan: pointer
  discard selectBss(addr bss, addr chan)
  let count = boundaryCalls.len
  doAssert count > 0
  for trigger in 1 .. count:
    for action in 0 .. 5:
      prepare(route)
      var replaced = false
      boundaryHook = proc(point: string) =
        if replaced or boundaryCalls.len != trigger: return
        replaced = true
        case action
        of 0: replaceOwner()
        of 1: inc smTxSerials[conn.vifIdx]
        of 2: inc rxVifEpochs[conn.vifIdx]
        of 3: inc scanuRequestEpoch
        of 4: sm.connectIndMsg = addr otherIndication
        else: state = SmWaitingState
        sm.scanResultIndex = 0xABCDEF01'u32
      bss = addr target
      chan = addr target
      doAssert not selectBss(addr bss, addr chan), "retired selection returned success"
      doAssert replaced and bss == nil and chan == nil
      doAssert configured == 0 and conn.authType == 7
      doAssert sm.scanResultIndex == 0xABCDEF01'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_selection_routes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, selection_source() + r'''
for route in 0 .. 7:
  for incoming in [false, true]:
    prepare(route)
    enabled = incoming
    var bss, chan: pointer
    let found = selectBss(addr bss, addr chan)
    doAssert enabled == incoming
    case route
    of 0:
      doAssert found and bss == (addr conn.bssid[0]) and chan == (addr channel)
    of 1:
      doAssert found and bss == (addr conn.bssid[0]) and chan == (addr conn.channelHint[0])
    of 2, 4, 6:
      doAssert found and bss == (addr scanu_env.entries[0]) and chan == (addr channel)
      doAssert sm.scanResultIndex == (if route in [4, 6]: 0xFFFFFFFF'u32 else: 0'u32)
    of 5:
      doAssert not found and bss == nil and chan == (addr conn.channelHint[0])
    of 3:
      doAssert not found and bss == nil and chan == (addr channel)
    else:
      doAssert not found and bss == nil and chan == nil
    doAssert configured == (if route in [0, 2, 3, 4, 6]: 1 else: 0)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_directed_fallback_preserves_channel_filter(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, selection_source() + r'''
prepare(5)
scanu_env.directedFound = 1
var bss, chan: pointer
doAssert not selectBss(addr bss, addr chan), "directed fallback bypassed requested frequency"
doAssert bss == nil and chan == addr conn.channelHint[0]
doAssert configured == 0 and sm.scanResultIndex == 0xFFFFFFFF'u32
prepare(6)
doAssert selectBss(addr bss, addr chan)
doAssert bss == (addr scanu_env.entries[0]) and chan == (addr channel)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_selection_missing_context(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, selection_source() + r'''
prepare(0)
var bss = cast[pointer](1)
var chan = cast[pointer](1)
sm.connectInfo = nil
doAssert not selectBss(addr bss, addr chan)
doAssert bss == nil and chan == nil and boundaryCalls.len == 0
prepare(0)
doAssert not selectBss(nil, addr chan)
doAssert chan == nil
doAssert not selectBss(addr bss, nil)
doAssert bss == nil and boundaryCalls.len == 0
prepare(0)
sm.connectIndMsg = nil
doAssert selectBss(addr bss, addr chan)
doAssert bss == (addr conn.bssid[0]) and chan == (addr channel)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_scan_handler_rechecks_owner(tmp_path: Path, mode: str) -> None:
    code = "var onLookup, onVif: proc()\n" + completion_source()
    code = code.replace("  inc lookups\n", "  inc lookups\n  invoke(onLookup)\n", 1)
    code = code.replace("proc vif_mgmt_get_vif(index: uint8): pointer = addr vifs[index]",
                        "proc vif_mgmt_get_vif(index: uint8): pointer =\n"
                        "  invoke(onVif)\n  addr vifs[index]", 1)
    run_program(tmp_path, mode, code + r'''
for duringVif in [false, true]:
  for haveBss in [false, true]:
    begin()
    let reply = complete(take())
    found = haveBss
    let replace = proc() =
      replaceOwner()
      state = SmScanningState
    if duringVif: onVif = replace
    else: onLookup = replace
    doAssert scanu_start_cfm_handler(reply) == 0
    doAssert failures.len == 0 and queued.len == 0
    doAssert sm.connectInfo == (addr replacement) and state == SmScanningState
    release(reply)
    finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_selected_entry_changes_during_final_log(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, selection_source() + r'''
for route in [0, 2, 4, 6]:
  prepare(route)
  var bss, chan: pointer
  discard selectBss(addr bss, addr chan)
  let finalCall = boundaryCalls.len
  for mutation in 0 .. 5:
    prepare(route)
    boundaryHook = proc(point: string) =
      if boundaryCalls.len != finalCall: return
      case mutation
      of 0: scanu_env.entries[0].valid = 0
      of 1: scanu_env.entries[0].chanPtr = addr config.entries[0]
      of 2: scanu_env.entries[0].ssid[0] = 0xFF
      of 3: inc channel.prim20Freq
      of 4: scanuCachedSsids[0].ssidBytes[0] = 0xFF
      else: scanuCachedSsids[0].valid = 0
    doAssert not selectBss(addr bss, addr chan)
    doAssert bss == nil and chan == nil and configured == 0
    doAssert conn.authType == 7 and sm.scanResultIndex == 0xFFFFFFFF'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_selected_entry_changes_after_lookup(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, selection_source() + r'''
prepare(2)
var afterLookup = false
var changed = false
boundaryHook = proc(point: string) =
  if point == "ssid":
    afterLookup = true
  elif afterLookup and not changed:
    changed = true
    scanu_env.entries[0].valid = 0
var bss, chan: pointer
doAssert not selectBss(addr bss, addr chan)
doAssert changed and bss == nil and chan == nil and configured == 0
doAssert conn.authType == 7 and sm.scanResultIndex == 0xFFFFFFFF'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_channel_resolution_precedes_snapshot(tmp_path: Path, mode: str) -> None:
    code = selection_source()
    code = code.replace(procedure(code, "scanResultChannelPtr"), r'''
proc scanResultChannelPtr(p: ptr ScanuResultEntry): pointer =
  if p.chanPtr == nil: p.chanPtr = addr channel
  p.chanPtr
''', 1)
    run_program(tmp_path, mode, code + r'''
for route in [0, 2, 6]:
  prepare(route)
  scanu_env.entries[0].chanPtr = nil
  var bss, chan: pointer
  doAssert selectBss(addr bss, addr chan)
  doAssert chan == (addr channel) and configured == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_callback_releases_connection(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, selection_source() + r'''
prepare(0)
let retired = cast[ptr ConnectInfoView](alloc0(sizeof(ConnectInfoView)))
retired[] = conn
sm.connectInfo = retired
var released = false
boundaryHook = proc(point: string) =
  if released: return
  released = true
  replaceOwner()
  dealloc(retired)
var bss, chan: pointer
doAssert not selectBss(addr bss, addr chan)
doAssert released and bss == nil and chan == nil and configured == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_platform_log_arguments(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, selection_source() + r'''
prepare(0)
var bss, chan: pointer
discard selectBss(addr bss, addr chan)
doAssert "<null>" notin logLines
doAssert "bssid[0] = 0x102\r\n" in logLines
doAssert "bssid[1] = 0x302\r\n" in logLines
doAssert "bssid[2] = 0x504\r\n" in logLines
prepare(2)
conn.ssidLen = 32
for byte in conn.ssid.mitems: byte = 81
discard selectBss(addr bss, addr chan)
var expected = "search ssid = "
for i in 0 ..< 32: expected.add('Q')
expected.add("\r\n")
doAssert expected in logLines
doAssert "result ssid index = 0\r\n" in logLines
''')
