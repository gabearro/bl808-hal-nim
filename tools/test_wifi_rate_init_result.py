"""Do not publish station success when rate initialization fails."""

from pathlib import Path

import pytest

from test_wifi_assoc_response import source as assoc_source
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rate_init import CASES as INIT_CASES, source as initializer_source
from test_wifi_station_capabilities import ap_source


def wrapper_source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = r'''
var succeeds: bool
var initialized, refreshed: int
let station = cast[pointer](0x1234)
proc rcTryInitStation(p: pointer): bool =
  doAssert p == station
  inc initialized
  succeeds
proc rc_init(p: pointer) = discard rcTryInitStation(p)
proc me_update_buffer_control(p: pointer): pointer =
  doAssert p == station
  inc refreshed
  p
'''
    if "proc meTryInitRate(" in scan:
        code += procedure(scan, "meTryInitRate")
    return code + procedure(scan, "me_init_rate")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_failed_init_does_not_refresh_policy(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, wrapper_source() + r'''
{.emit: """
_Static_assert(__builtin_types_compatible_p(__typeof__(&me_init_rate),
    void (*)(void *)), "ME initialization keeps its void C ABI");
""".}
succeeds = false
me_init_rate(station)
doAssert initialized == 1 and refreshed == 0
succeeds = true
me_init_rate(station)
doAssert initialized == 2 and refreshed == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_initializer_reports_result(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, initializer_source() + INIT_CASES.split("var countState:", 1)[0] + r'''
{.emit: """
_Static_assert(__builtin_types_compatible_p(__typeof__(&rc_init),
    void (*)(void *)), "RC initialization keeps its void C ABI");
""".}
for ht in [false, true]:
  setup(ht, 0xFFF, 0, 0, 0x21)
  doAssert rcTryInitStation(addr sta)
  doAssert policy.status == 0xBADCAB1E'u32 and errors == 0
for invalidCase in 0 ..< 6:
  setup(false, 0xFFF, 0, 0, 0)
  case invalidCase
  of 0: legacyMap = 0
  of 1: sta.infoIdx = 5
  of 2: sta.txPolicy = nil
  of 3:
    setup(true, 0xFFF, 0, 0, 0, 4, 4)
  of 4: sta.nssBwMax = 1
  else:
    setup(true, 0xFFF, 0, 0, 0, 1, 1)
    sta.vhtCaps[4] = 0
  doAssert not rcTryInitStation(addr sta)
  doAssert policy.status == 0xA5A5A5A5'u32 and errors == 1
doAssert not rcTryInitStation(nil)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_assoc_rejects_failed_rate_init(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, assoc_source() + r'''
let p = response([])
failRateInit = true
sm_assoc_rsp_handler(p)
doAssert rates == 1 and failures == @[(5'u16, 0xFFFF'u16)]
doAssert powers.len == 0 and sent.len == 0 and state == 8
finish(p)
let replacementFrame = response([])
failRateInit = true
onRate = replaceOwner
sm_assoc_rsp_handler(replacementFrame)
doAssert failures.len == 0 and sent.len == 0 and state == 6
finish(replacementFrame)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ap_rejects_failed_rate_init(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ap_source() + r'''
reset(1, 2, 0, 0, false)
expectedAtInit = (0'u8, 0'u8, 0'u8)
rateInitFails = true
doAssert me_sta_add_req_handler(addr requestBytes[0]) == 0
doAssert initialized == 1 and sent == 1 and deleted == @[2'u8]
doAssert response[0] == 0xFF and response[1] != 0
doAssert stations[2].controlPortState == 0 and stations[2].rateWord == 0
doAssert stations[2].txPolicyUpdateFlags == [0'u8, 0'u8]
reset(1, 2, 0, 0, false)
rateInitFails = true
onRateInit = proc() =
  inc stationEpochs[2]
  stations[2].aid = 99
doAssert me_sta_add_req_handler(addr requestBytes[0]) == 0
doAssert response[1] != 0 and deleted.len == 0
doAssert stations[2].aid == 99 and stations[2].txPolicyUpdateFlags == [0'u8, 0'u8]
''')
