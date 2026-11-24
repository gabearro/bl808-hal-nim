"""Distinguish raw discovery results from the bounded join rate set."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_scan_result_updates import source as result_source
from test_wifi_scan_rx_admission import PLATFORM


def source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    mac = (FW / "mac_config_debug.nim").read_text()
    code = layouts("MacIeView", "RxuMgtIndView", "RxuMgtIndMsgView", "RateSetView") + PLATFORM
    code += r'''
var
  errors: int
  extractedRates: array[13, uint8]
proc rateSetAt(p: pointer): ptr RateSetView = cast[ptr RateSetView](p)
proc assert_err(a, b: cstring; line: cint) =
  doAssert line == 897
  inc errors
'''
    code += procedure(mac, "mac_ie_find")
    for name in ["readLegacyRateIe", "scanuRxFrameValid", "scanuFrameMatchesBssid", "scanuRequestCurrent",
                 "me_extract_rate_set"]:
        code += procedure(scan, name)
    code += procedure(scan, "scanu_frame_handler").split("  # Security info\n", 1)[0]
    code += r'''
  if bfOn != 0:
    me_extract_rate_set(ieStart, ieLen, addr extractedRates[0])
  ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
'''
    code += procedure(tasks, "rxu_mgt_ind_handler_scanu")
    return code + r'''
proc rateIe(id: uint8; count: int): seq[uint8] =
  if count < 0: return
  result = @[id, count.uint8]
  for i in 0 ..< count: result.add((0x80 + i mod 64).uint8)
proc prepare(ies: openArray[uint8]; join = true) =
  putIes(ies)
  scanu_env.bssidFilterEnabled = join.uint8
  request.flags = 0x100
  errors = 0
  extractedRates = default(typeof(extractedRates))
proc finish() =
  dealloc(allocation)
  allocation = nil
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_discovery_forwards_rates_unchanged(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
let base = @[0'u8, 2, 65, 80, 1, 8, 0x82, 0x84, 0x8b, 0x96, 12, 18, 24, 36,
             3, 1, 9]
for fc in [0x50'u16, 0x80'u16]:
  for extra in [@[50'u8, 4, 48, 72, 96, 108],
                @[50'u8, 5, 48, 72, 96, 108, 0xff],
                @[50'u8, 5, 48, 72, 96, 108, 2]]:
    let ies = base & extra
    prepare(ies, join = false)
    request.scanType = 0
    rxuMgtIndAt(allocation).freq = 2452
    rxuMgtIndMsgAt(allocation).frameCtrl = fc
    doAssert rxu_mgt_ind_handler_scanu(allocation) == KeMsgNoFree
    doAssert lookups == 1 and forwards == 1 and errors == 0
    doAssert equalMem(rxuMgtIndIeStart(allocation), unsafeAddr ies[0], ies.len)
    finish()
  prepare(base & @[50'u8, 5, 48, 72, 96, 108], join = false)
  rxuMgtIndMsgAt(allocation).frameCtrl = fc
  doAssert rxu_mgt_ind_handler_scanu(allocation) == KeMsgConsumed
  doAssert lookups == 0 and forwards == 0
  finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_discovery_publishes_channel_nine_result(tmp_path: Path, mode: str) -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = result_source()
    code = code.replace(procedure(code, "scanuRxFrameValid"), "")
    prefix, entry, body = code.partition("proc scanu_frame_handler*")
    assert entry
    validator = layouts("RxuMgtIndMsgView") + r'''
const IE_ID_HT_CAP = 45'u8
const IE_ID_RSN = 48'u8
const WPA_OUI = [0'u8, 0x50, 0xF2, 1]
'''
    for name in ["macIePayload", "rxuMgtIndMsgAt"]:
        validator += procedure(PLATFORM, name)
    for name in ["readLegacyRateIe", "scanuRxFrameValid"]:
        validator += procedure(scan, name)
    run_program(tmp_path, mode, prefix + validator + entry + body + r'''
for fc in [0x50'u8, 0x80'u8]:
  for ssids in [0'u8, 1'u8]:
    prepareUpdate(true, -20)
    original.scanType = ssids
    entry.valid = 0
    entry.cachedRxuMgtInd = nil
    scanu_env.resultCount = 0
    let rx = rxuMgtIndAt(addr frame[0])
    rx.freq = 2452
    frame[73] = 9 # DS channel
    frame[2] = fc
    frame[32] = fc
    let rates = [1'u8, 8, 0x82, 0x84, 0x8b, 0x96, 12, 18, 24, 36,
                 50, 5, 48, 72, 96, 108, 0xff]
    for i, value in rates: frame[74 + i] = value
    rx.frameLen += rates.len.uint16
    let originalFrame = frame
    scanu_frame_handler(addr frame[0], rx.frameLen.uint32 + 32)
    doAssert reachedCommit and forwards == 1 and scanu_env.resultCount == 1
    doAssert channel.prim20Freq == 2452 and frame == originalFrame
    doAssert allocations == ssids.int
    if ssids != 0:
      doAssert entry.valid == 1 and entry.cachedRxuMgtInd == (addr copiedFrame[0])
      doAssert equalMem(addr copiedFrame[0], addr frame[0], rx.frameLen.int + 32)
    finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_join_omits_membership_selectors_from_legacy_rates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
let expected = [12'u8, 0x82, 0x84, 0x8b, 0x96, 12, 18, 24, 36, 48, 72, 96, 108]
for selector in 0xf8'u8 .. 0xff'u8:
  let supported = @[1'u8, 8, 0x82, 0x84, 0x8b, 0x96, selector, 12, 18, 24]
  let extended = @[50'u8, 6, 36, 48, selector, 72, 96, 108]
  for ies in [supported & extended, extended & supported]:
    prepare(ies)
    doAssert rxu_mgt_ind_handler_scanu(allocation) == KeMsgNoFree
    doAssert forwards == 1 and errors == 0 and extractedRates == expected
    finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rate_overflow_is_dropped_before_diagnostics(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for reverse in [false, true]:
  let supported = rateIe(1, 8)
  let extended = rateIe(50, 5)
  prepare(if reverse: extended & supported else: supported & extended)
  doAssert rxu_mgt_ind_handler_scanu(allocation) == KeMsgConsumed
  doAssert errors == 0 and parses == 0 and lookups == 0
  doAssert notifications == 0 and forwards == 0
  finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rate_capacity_matches_extractor(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for supportedCount in [-1, 0, 8, 12, 13]:
  for extendedCount in [-1, 0, 4, 12, 13, 255]:
    for reverse in [false, true]:
      let supported = rateIe(1, supportedCount)
      let extended = rateIe(50, extendedCount)
      prepare(if reverse: extended & supported else: supported & extended)
      let total = max(supportedCount, 0) + max(extendedCount, 0)
      let accepted = supportedCount < 0 or total <= 12
      let status = rxu_mgt_ind_handler_scanu(allocation)
      doAssert status == (if accepted: KeMsgNoFree else: KeMsgConsumed)
      doAssert errors == 0
      doAssert parses == accepted.int and lookups == accepted.int
      doAssert notifications == accepted.int and forwards == accepted.int
      if accepted:
        doAssert extractedRates[0].int == (if supportedCount < 0: 0 else: total)
      finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_first_rate_elements_match_lookup_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
let supported = rateIe(1, 8)
let extended = rateIe(50, 4)
let extraSupported = rateIe(1, 255)
let extraExtended = rateIe(50, 255)
for ies in [supported & extraSupported & extended & extraExtended,
            extended & extraExtended & supported & extraSupported]:
  prepare(ies)
  doAssert rxu_mgt_ind_handler_scanu(allocation) == KeMsgNoFree
  doAssert errors == 0 and extractedRates[0] == 12
  finish()
for ies in [extraSupported & supported & extended,
            supported & extraExtended & extended]:
  prepare(ies)
  doAssert rxu_mgt_ind_handler_scanu(allocation) == KeMsgConsumed
  doAssert errors == 0 and parses == 0 and lookups == 0
  finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_direct_scan_handler_also_rejects_rate_overflow(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
prepare(rateIe(1, 8) & rateIe(50, 5))
scanu_frame_handler(allocation, allocated)
doAssert errors == 0 and parses == 0 and lookups == 0
doAssert notifications == 0 and forwards == 0
finish()
''')
