"""Validate bandwidth/NSS updates before touching rate-control state."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  STA_INFO_TAB_ENTRIES = 7
  RC_MAX_RATE_ENTRIES = 10
  RCS_NO_SS = 187
  RCS_GROUP_CNT = 188
  RCS_N_RATES = 192
  RCS_SAMPLE_IDX = 198
  StaTxPolicyUpdateRateControl = 1'u8
type Station = object
  rcStats: pointer
  txPolicyUpdateFlags: array[1, uint8]
var
  stations: array[7, Station]
  data, replacement: array[200, uint8]
  lookups, seeds, sorts, chains, resets: int
  lines: seq[cint]
  hook: proc()
proc rcU8(p: pointer; offset: int): var uint8 =
  cast[ptr UncheckedArray[uint8]](p)[offset]
proc rcU16(p: pointer; offset: int): var uint16 =
  cast[ptr uint16](cast[uint](p) + offset.uint)[]
proc staInfoForIdx(index: uint8): ptr Station =
  inc lookups
  doAssert index < stations.len.uint8
  addr stations[index]
proc assert_err(a, b: cstring; line: cint) =
  lines.add(line)
  if hook != nil: hook()
proc rc_seed_rate_table(stats: pointer): bool =
  doAssert stats == addr data[0]
  inc seeds
  true
proc rcClearRateEntryTransientStats(stats: pointer; index: uint16) =
  doAssert stats == (addr data[0]) and index.int == resets
  inc resets
proc rc_sort_samples_tp(stats, tp: pointer) =
  doAssert stats == addr data[0]
  for i in 0 ..< 10: doAssert cast[ptr UncheckedArray[uint32]](tp)[i] == 0
  inc sorts
proc rc_update_retry_chain(stats, tp: pointer) =
  doAssert stats == (addr data[0]) and sorts == 1
  inc chains
proc setup(fixed = 0'u16) =
  stations = default(typeof(stations))
  data = default(typeof(data))
  replacement = default(typeof(replacement))
  stations[2].rcStats = addr data[0]
  stations[2].txPolicyUpdateFlags[0] = 0x80
  rcU16(addr data[0], RCS_N_RATES) = 3
  rcU16(addr data[0], RCS_SAMPLE_IDX) = fixed
  lookups = 0
  seeds = 0
  sorts = 0
  chains = 0
  resets = 0
  lines.setLen(0)
  hook = nil
'''


def source() -> str:
    return PLATFORM + procedure((FW / "rate_control.nim").read_text(), "rc_update_bw_nss_max")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_limits_preserve_existing_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for pair in [(4'u8, 0'u8), (255'u8, 7'u8), (3'u8, 8'u8), (0'u8, 255'u8)]:
  for fixed in [0'u16, 0xFFFF'u16]:
    setup(fixed)
    let expectedData = data
    let expectedStations = stations
    rc_update_bw_nss_max(2, pair[0], pair[1])
    doAssert data == expectedData and stations == expectedStations
    doAssert lines == @[(if pair[0] > 3: 0x963.cint else: 0x965.cint)]
    doAssert seeds == 0 and resets == 0 and sorts == 0 and chains == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_station_and_missing_stats(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for index in [7'u8, 255'u8]:
  setup()
  let expected = (data, stations)
  rc_update_bw_nss_max(index, 1, 1)
  doAssert (data, stations) == expected and lookups == 0
setup()
stations[2].rcStats = nil
let expected = stations
rc_update_bw_nss_max(2, 1, 1)
doAssert stations == expected and lines == @[0x95D.cint]
doAssert seeds == 0 and sorts == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_limit_callback_cannot_publish_replacement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for pair in [(4'u8, 0'u8), (0'u8, 8'u8)]:
  setup(0xFFFF)
  var expectedData: array[200, uint8]
  var expectedStations: array[7, Station]
  hook = proc() =
    for value in data.mitems: value = 0xC7
    stations[2].rcStats = addr replacement[0]
    stations[2].txPolicyUpdateFlags[0] = 0xA0
    expectedData = data
    expectedStations = stations
  rc_update_bw_nss_max(2, pair[0], pair[1])
  doAssert data == expectedData and stations == expectedStations
  doAssert seeds == 0 and resets == 0 and sorts == 0 and chains == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_valid_manual_and_automatic_updates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for bandwidth in 0'u8 .. 3'u8:
  for nss in [0'u8, 1'u8, 7'u8]:
    for fixed in [0'u16, 0xFFFF'u16]:
      setup(fixed)
      rcU8(addr data[0], RCS_NO_SS) = (bandwidth + 1) mod 4
      let before = data
      rc_update_bw_nss_max(2, bandwidth, nss)
      doAssert rcU8(addr data[0], RCS_NO_SS) == bandwidth
      doAssert rcU8(addr data[0], RCS_GROUP_CNT) == nss
      for i in 0 ..< data.len:
        if i notin [RCS_NO_SS, RCS_GROUP_CNT]: doAssert data[i] == before[i]
      doAssert lines.len == 0 and lookups == 1
      let automatic = fixed == 0xFFFF
      doAssert seeds == automatic.int and sorts == automatic.int and chains == automatic.int
      doAssert resets == (if automatic: 3 else: 0)
      doAssert stations[2].txPolicyUpdateFlags[0] == (if automatic: 0x81'u8 else: 0x80'u8)
      rc_update_bw_nss_max(2, bandwidth, nss)
      doAssert seeds == automatic.int and sorts == automatic.int
''')
