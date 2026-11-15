"""Keep preamble-updated sample tables valid when distinct rates run out."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rate_generation import prelude


PLATFORM = r'''
const
  STA_INFO_TAB_ENTRIES = 7
  RCS_FLAGS = 175
  RCS_SAMPLE_IDX = 198
  StaTxPolicyUpdateRateControl = 1'u8
type Station = object
  rcStats: pointer
  txPolicyUpdateFlags: array[1, uint8]
var
  stations: array[7, Station]
  storage: array[232, uint8]
  lookups, errors: int
let stats = addr storage[16]
proc staInfoForIdx(index: uint8): ptr Station =
  inc lookups
  doAssert index < stations.len.uint8
  addr stations[index]
proc assert_err(a, b: cstring; line: cint) =
  doAssert line == 0x9A2
  inc errors
proc setup(rates: openArray[uint16]; highest = 3'u8) =
  for value in storage.mitems: value = 0xBA
  zeroMem(stats, 200)
  stations = default(typeof(stations))
  stations[2].rcStats = stats
  stations[2].txPolicyUpdateFlags[0] = 0x80
  let caps = rcRateCapabilities(stats)
  caps.legacyRateMap = (1'u16 shl (highest + 1)) - 1
  caps.highestLegacyRate = highest
  caps.sampleCount = rates.len.uint16
  caps.fixedRate = 0xFFFF
  for i, config in rates:
    let entry = rcRateStats(stats, i)
    entry.rateConfig = config
    entry.attempts = (100 + i).uint16
    entry.successes = (50 + i).uint16
    entry.sampleSkipped = (0xA0 + i).uint8
    entry.probability = 0xFFFF
    entry.oldProbAvailable = 1
    entry.retryCount = 8
  lookups = 0
  errors = 0
proc checkEdges() =
  for i in 0 ..< 16:
    doAssert storage[i] == 0xBA and storage[216 + i] == 0xBA
proc checkTable(expected: openArray[uint16]; originalIndexes: openArray[int]) =
  let caps = rcRateCapabilities(stats)
  for i in 0 ..< caps.sampleCount.int:
    let config = rcRateStats(stats, i).rateConfig
    if ((config shr 11) and 6) == 0 and (config and 127) < 4:
      doAssert (config and 0x400) != 0, "CCK sample violates preamble type 1"
  doAssert caps.preambleType == 1 and caps.sampleCount.int == expected.len
  doAssert stations[2].txPolicyUpdateFlags[0] == 0x81
  for i, config in expected:
    let entry = rcRateStats(stats, i)
    doAssert entry.rateConfig == config
    doAssert entry.attempts == (100 + originalIndexes[i]).uint16
    doAssert entry.successes == (50 + originalIndexes[i]).uint16
    doAssert entry.sampleSkipped == (0xA0 + originalIndexes[i]).uint8
    doAssert entry.probability == 0 and entry.oldProbAvailable == 0 and entry.retryCount == 0
    for j in 0 ..< i: doAssert rcRateStats(stats, j).rateConfig != config
  for step in 0 ..< 4: doAssert rcRetryStep(stats, step).rateIdx.int < expected.len
  doAssert errors == 0
  checkEdges()
'''


def source() -> str:
    code, rate, helpers = prelude()
    layout = (FW / "layout_types.nim").read_text()
    code += "\ntype\n  RcRateEntryView" + layout.split("  RcRateEntryView", 1)[1].split(
        "  RcRateCapabilitiesView", 1)[0]
    code += "\ntemplate rcRateEntryAt" + helpers.split("template rcRateEntryAt", 1)[1].split(
        "template rcRateCapabilities", 1)[0]
    code += "\ntemplate rcThroughputArray" + helpers.split("template rcThroughputArray", 1)[1].split(
        "template rcStatsCounters", 1)[0]
    for name in ["rcRateConfig", "rcSetRateConfig", "rcClearRateEntryTransientStats"]:
        code += procedure(helpers, name)
    code += PLATFORM
    code += procedure(rate, "rc_get_mcs_index")
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "is_cck_group")
    for name in ["rc_new_random_rate", "rc_check_rate_duplicated"]:
        code += procedure(rate, name)
    code += procedure(helpers, "rc_pick_non_duplicate_rate")
    for name in ["rc_sort_samples_tp", "rc_update_retry_chain", "rc_update_preamble_type"]:
        code += procedure(rate, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_saturated_cck_table_is_compacted(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup([0x400'u16, 1, 0x401, 2, 0x402, 3, 0x403])
rc_update_preamble_type(2, 1)
checkTable([0x400'u16, 0x401, 0x402, 0x403], [0, 1, 3, 5])
for i in 4 ..< 7: doAssert rcRateStats(stats, i).rateConfig == 0xFFFF
let before = storage
let seed = rcPrngState
rc_update_preamble_type(2, 1)
doAssert storage == before and rcPrngState == seed
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mixed_table_preserves_unaffected_rates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup([0x400'u16, 1, 0x401, 2, 0x402, 3, 0x403, 4, 5, 6], 6)
rc_update_preamble_type(2, 1)
checkTable([0x400'u16, 0x401, 0x402, 0x403, 4, 5, 6], [0, 1, 3, 5, 7, 8, 9])
for i in 7 ..< 10: doAssert rcRateStats(stats, i).rateConfig == 0xFFFF
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_spare_rates_and_fixed_mode(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup([0x400'u16, 1, 0x401])
rc_update_preamble_type(2, 1)
doAssert rcRateCapabilities(stats).sampleCount == 3
for i in 0 ..< 3:
  let config = rcRateStats(stats, i).rateConfig
  doAssert config in [0x400'u16, 0x401, 0x402, 0x403]
  for j in 0 ..< i: doAssert rcRateStats(stats, j).rateConfig != config
checkEdges()
setup([0x400'u16, 1, 0x401])
rcRateCapabilities(stats).fixedRate = 0x400
let beforeFixed = storage
rc_update_preamble_type(2, 1)
for i in 0 ..< storage.len:
  if i != 16 + 190: doAssert storage[i] == beforeFixed[i]
doAssert rcRateCapabilities(stats).preambleType == 1
doAssert stations[2].txPolicyUpdateFlags[0] == 0x80
let beforeModeZero = storage
rc_update_preamble_type(2, 0)
for i in 0 ..< storage.len:
  if i != 16 + 190: doAssert storage[i] == beforeModeZero[i]
doAssert rcRateCapabilities(stats).preambleType == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_updates_leave_state_unchanged(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for index in [7'u8, 255'u8]:
  setup([0x400'u16])
  let before = storage
  rc_update_preamble_type(index, 1)
  doAssert storage == before and lookups == 0
for preamble in [2'u8, 255'u8]:
  setup([0x400'u16])
  let before = storage
  rc_update_preamble_type(2, preamble)
  doAssert storage == before
for count in [0'u16, 11'u16, 65535'u16]:
  setup([0x400'u16])
  rcRateCapabilities(stats).sampleCount = count
  let before = storage
  rc_update_preamble_type(2, 1)
  doAssert storage == before
setup([0x400'u16])
stations[2].rcStats = nil
let before = storage
rc_update_preamble_type(2, 1)
doAssert storage == before and errors == 1
''')
