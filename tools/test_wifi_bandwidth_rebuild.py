"""Exercise bandwidth updates with the production rate-table builder."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_preamble_updates import source as rate_update_source


def source() -> str:
    rate = (FW / "rate_control.nim").read_text()
    code = rate_update_source()
    for name in ["rc_get_initial_rate_config", "rc_get_lowest_rate_config",
                 "rc_seed_rate_table", "rc_update_bw_nss_max"]:
        code += procedure(rate, name)
    return code + r'''
proc setupHt() =
  setup([0x1000'u16, 0x1007])
  let caps = rcRateCapabilities(stats)
  caps.formatMod = 2
  caps.mcsBitmaps[0] = 0xFF
  caps.maxMcs = 7
  caps.lowestLegacyRate = 4
  caps.highestLegacyRate = 11
  rcPrngState = 0x12345678
proc checkRetryIndexes() =
  for step in 0 ..< 4:
    doAssert rcRetryStep(stats, step).rateIdx < rcRateCapabilities(stats).sampleCount
  checkEdges()
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_failed_seed_preserves_limits_and_table(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for requestedNss in [1'u8, 4'u8, 7'u8]:
  setupHt()
  let before = storage
  let beforeStations = stations
  let beforeRandom = rcPrngState
  rc_update_bw_nss_max(2, 1, requestedNss)
  doAssert storage == before, "failed rebuild changed active limits or samples"
  doAssert stations == beforeStations and rcPrngState == beforeRandom
  doAssert errors == 0
  checkEdges()
for invalidCount in [0'u16, 11'u16, 65535'u16]:
  setupHt()
  rcRateCapabilities(stats).sampleCount = invalidCount
  let before = storage
  rc_update_bw_nss_max(2, 1, 0)
  doAssert storage == before
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_retry_after_missing_capability_rebuilds(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setupHt()
rc_update_bw_nss_max(2, 1, 1)
let caps = rcRateCapabilities(stats)
caps.mcsBitmaps[1] = 0x0F
rc_update_bw_nss_max(2, 1, 1)
doAssert caps.maxBandwidth == 1 and caps.maxNss == 1
doAssert caps.sampleCount == 2
doAssert rcRateStats(stats, 0).rateConfig == 0x1000
doAssert rcRateStats(stats, 1).rateConfig == 0x108B,
  "same request after a failed seed skipped the required rebuild"
doAssert stations[2].txPolicyUpdateFlags[0] == 0x81
checkRetryIndexes()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reduced_rate_space_commits_compact_table(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup([0x1000'u16, 0x1080, 0x1280, 0x1100, 0x1300])
let caps = rcRateCapabilities(stats)
caps.formatMod = 2
caps.mcsBitmaps[0] = 1
caps.maxMcs = 0
caps.maxBandwidth = 2
caps.shortGi = 1
caps.lowestLegacyRate = 4
caps.highestLegacyRate = 11
rc_update_bw_nss_max(2, 0, 0)
doAssert caps.maxBandwidth == 0 and caps.maxNss == 0
doAssert caps.sampleCount == 2
doAssert rcRateStats(stats, 0).rateConfig == 0x1000
doAssert rcRateStats(stats, 1).rateConfig == 0x1200
for unused in 2 ..< 5: doAssert rcRateStats(stats, unused).rateConfig == 0xFFFF
doAssert stations[2].txPolicyUpdateFlags[0] == 0x81
checkRetryIndexes()
''')
