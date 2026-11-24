"""Check the supplicant completion callbacks against their vendor C ABI."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  STA_INFO_TAB_ENTRIES = 7
  MAX_VIFS = 2
  WLAN_FW_APM_DEAUTH_BY_AUTHENTICATOR = 6'u16
type
  Sta = object
    instNbr, controlPortState: uint8
  Vif = object
    probeCount: uint32
  PlatformLogFunc = proc(level, severity: uint32; file: pointer;
                         line: uint32) {.cdecl, varargs.}
var
  stations: array[7, Sta]
  vifs: array[2, Vif]
  nimFwWpaPendingMask, nimFwDbgPtkInitDone: uint32
  logging, removeResult: bool
  slots: seq[int]
  lines: seq[cint]
  messages: seq[string]
  removals: seq[tuple[vif, sta: uint8, kind, reason: uint16]]
  results: seq[tuple[sta: uint8, reason: uint16]]
proc staInfoForIdx(index: uint8): ptr Sta =
  doAssert index < 7
  addr stations[index]
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc mmResetBeaconProbeCount(vif: ptr Vif) = vif.probeCount = 0
proc encodedArgU8(p: pointer): uint8 = cast[uint](p).uint8
proc apm_sta_remove(vif, sta: uint8; kind, reason: uint16): bool =
  removals.add((vif, sta, kind, reason))
  removeResult
proc sm_handle_supplicant_result(sta: uint8; reason: uint16) =
  results.add((sta, reason))
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc recordLog(level: uint32; tag, file: cstring; line: cint;
               format: cstring) {.cdecl, varargs.} =
  doAssert level == 1 and tag == nil
  doAssert file == cstring("supplicant_api.c")
  doAssert cast[uint](format) > 4096
  var output: array[256, char]
  var written: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ",
           written, " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
           format, ", args); va_end(args);"].}
  doAssert written >= 0 and written < output.len.cint
  messages.add($cast[cstring](addr output[0]))
  lines.add(line)
proc getLogFunc(offset: int): PlatformLogFunc =
  slots.add(offset)
  doAssert offset == 204, "completion used a non-logger operation slot"
  if logging: cast[PlatformLogFunc](recordLog) else: nil
proc setup(enabled: bool) =
  logging = enabled
  removeResult = true
  stations = default(typeof(stations))
  stations[4].instNbr = 1
  vifs = default(typeof(vifs))
  vifs[1].probeCount = 9
  nimFwWpaPendingMask = 3
  nimFwDbgPtkInitDone = 0
  slots.setLen(0)
  lines.setLen(0)
  messages.setLen(0)
  removals.setLen(0)
  results.setLen(0)
'''


def source(ptk: bool = False) -> str:
    platform = (FW / "platform_bl.nim").read_text()
    code = PLATFORM
    if ptk:
        code += procedure((FW / "scan_station_ap_me.nim").read_text(), "apm_handle_auth_done")
        code += procedure(platform, "bl_wifi_wpa_ptk_init_done_internal")
        code += r'''
{.emit: """
extern NIM_BOOL bl_wifi_wpa_ptk_init_done_internal(unsigned char);
static NIM_BOOL call_ptk_completion(unsigned char station) {
  return bl_wifi_wpa_ptk_init_done_internal(station);
}
""".}
proc callPtk(station: uint8): bool {.importc: "call_ptk_completion", cdecl, nodecl.}
'''
    else:
        code += procedure(platform, "bl_wifi_ap_deauth_internal")
        code += procedure(platform, "bl_wifi_auth_done_internal")
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_auth_and_deauth_log_arguments(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  setup(enabled)
  doAssert bl_wifi_ap_deauth_internal(1, 4, 0x1234BEEF'u32) == 0
  doAssert removals == @[(1'u8, 4'u8, 6'u16, 0xBEEF'u16)]
  doAssert messages == (if enabled:
    @["bl_wifi_ap_deauth_internal: vif_idx 1, sta_idx 4, reason 305446639\r\n"]
    else: newSeq[string]())
  doAssert lines == (if enabled: @[22.cint] else: newSeq[cint]())
  removeResult = false
  doAssert bl_wifi_ap_deauth_internal(1, 4, 1) == -1
  for reason in [0'u16, 256, 0xBEEF]:
    setup(enabled)
    doAssert bl_wifi_auth_done_internal(4, reason)
    doAssert results == @[(4'u8, reason)]
    doAssert messages == (if enabled:
      @["bl_wifi_auth_done_internal: sta_idx 4, reason_code " & $reason & "\r\n"]
      else: newSeq[string]())
    doAssert lines == (if enabled: @[29.cint] else: newSeq[cint]())
    doAssert nimFwWpaPendingMask == (if reason == 0: 1'u32 else: 3'u32)
    doAssert vifs[1].probeCount == (if reason == 0: 0'u32 else: 9'u32)
  setup(enabled)
  doAssert not bl_wifi_auth_done_internal(255, 0)
  doAssert slots.len == 0 and results.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ptk_completion_uses_station_and_returns_boolean(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(True) + r'''
let typed: proc(station: uint8): bool {.cdecl.} = bl_wifi_wpa_ptk_init_done_internal
for enabled in [false, true]:
  for station in [0'u8, 1, 4, 6]:
    setup(enabled)
    doAssert callPtk(station)
    for other in 0 .. 6:
      doAssert stations[other].controlPortState == (if other == station.int: 2'u8 else: 0'u8)
    doAssert nimFwWpaPendingMask == 3 and nimFwDbgPtkInitDone == 1
    doAssert slots == @[204]
    doAssert messages == (if enabled:
      @["bl_wifi_wpa_ptk_init_done_internal: sta_idx " & $station & "\r\n"]
      else: newSeq[string]())
    doAssert lines == (if enabled: @[99.cint] else: newSeq[cint]())
  for invalid in [7'u8, 255]:
    setup(enabled)
    let before = stations
    doAssert not typed(invalid)
    doAssert stations == before
    doAssert nimFwWpaPendingMask == 3 and slots.len == 0
''')
