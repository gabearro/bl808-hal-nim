"""Keep scan rate-set overflow out of the parser/diagnostic path."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
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
    for name in ["scanuRxFrameValid", "scanuFrameMatchesBssid", "scanuRequestCurrent",
                 "me_extract_rate_set"]:
        code += procedure(scan, name)
    code += procedure(scan, "scanu_frame_handler").split("  # Security info\n", 1)[0]
    code += r'''
  me_extract_rate_set(ieStart, ieLen, addr extractedRates[0])
  ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
'''
    code += procedure(tasks, "rxu_mgt_ind_handler_scanu")
    return code + r'''
proc rateIe(id: uint8; count: int): seq[uint8] =
  if count < 0: return
  result = @[id, count.uint8]
  for i in 0 ..< count: result.add((0x80 + i mod 64).uint8)
proc prepare(ies: openArray[uint8]) =
  putIes(ies)
  request.flags = 0x100
  errors = 0
  extractedRates = default(typeof(extractedRates))
proc finish() =
  dealloc(allocation)
  allocation = nil
'''


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
