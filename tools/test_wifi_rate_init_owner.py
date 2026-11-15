"""Retain station ownership across rate-parser warning callbacks."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rate_init import CASES, source as initializer_source
from test_wifi_rate_masks import helpers as rate_parser_helpers


def source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = initializer_source()
    code = code.replace(procedure(code, "me_legacy_rate_bitfield_build"),
        rate_parser_helpers() + procedure(scan, "me_legacy_rate_bitfield_build"), 1)
    code += CASES.split("var countState:", 1)[0]
    return code + r'''
var replacementStats: array[200, uint8]
var replacementPolicy: TxPolicyView
proc warningSetup() =
  setup(false, 0, 0, 0, 0)
  sta.supportedRates = [3'u8, 0x7F, 0x82, 0x8C, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  replacementStats = default(typeof(replacementStats))
  replacementPolicy = default(TxPolicyView)
  warnings = 0
  warningHook = nil
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_warning_cannot_finish_replaced_station(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for replacementKind in 0 ..< 8:
  warningSetup()
  var expectedStation: MockSta
  var expectedPool: typeof(rcStaStatsPool)
  var expectedPolicy: TxPolicyView
  warningHook = proc() =
    case replacementKind
    of 0: inc stationEpochs[2]
    of 1: sta.valid = 0
    of 2: sta.txPolicy = addr replacementPolicy
    of 3: sta.rcStats = addr replacementStats[0]
    of 4: sta.infoIdx = 3
    of 5: sta.vif = cast[pointer](0x87654321'u)
    of 6: sta.instNbr = 0
    else: inc rxVifEpochs[1]
    rcStaStatsPool[2 * RC_STATS_SIZE] = 0xC7
    expectedStation = sta
    expectedPool = rcStaStatsPool
    expectedPolicy = policy
  doAssert not rcTryInitStation(addr sta), "replaced station completed rate initialization"
  doAssert sta == expectedStation and rcStaStatsPool == expectedPool and policy == expectedPolicy
  doAssert replacementStats == default(typeof(replacementStats))
  doAssert replacementPolicy == default(TxPolicyView)
  doAssert warnings == 1 and errors == 0 and phyCalls == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_warning_without_replacement_keeps_valid_rates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
warningSetup()
doAssert rcTryInitStation(addr sta)
doAssert warnings == 1 and errors == 0 and phyCalls == 2
let caps = rcRateCapabilities(sta.rcStats)
doAssert caps.legacyRateMap == 0x11 and caps.sampleCount == 2
doAssert policy.status == 0xBADCAB1E'u32
doAssert rcRateStats(sta.rcStats, 0).rateConfig == 0x400
doAssert rcRateStats(sta.rcStats, 1).rateConfig == 4
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_inactive_station_does_not_start_initialization(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for invalidVif in [1'u8, 2'u8, 255'u8]:
  warningSetup()
  if invalidVif == 1: sta.valid = 0
  else: sta.instNbr = invalidVif
  let expectedStation = sta
  let expectedPool = rcStaStatsPool
  let expectedPolicy = policy
  doAssert not rcTryInitStation(addr sta)
  doAssert sta == expectedStation and rcStaStatsPool == expectedPool and policy == expectedPolicy
  doAssert phyCalls == 0 and warnings == 0 and errors == 0
''')
