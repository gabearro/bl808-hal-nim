"""Check the candidate slot priority used by the vendor rc_update_stats loop."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_rate_update import PLATFORM, compile_and_run, firmware_prelude


HARNESS = r"""
var storage: array[200, uint8]
let stats = addr storage[0]
activeStats = stats
rcU16(stats, RCS_N_RATES) = 10
for index in 0 ..< 10:
  rcRateStats(stats, index).rateConfig = (0x2000 + index).uint16
rcRetryStep(stats, 0).rateIdx = 8
rcRetryStep(stats, 1).rateIdx = 9
rcRetryStep(stats, 2).rateIdx = 7
rcRateStats(stats, 8).rateConfig = 0x1000
rcRateStats(stats, 9).rateConfig = 0x1010
randomConfig = 0x1100

doAssert rc_get_new_sample_rates(stats) ==
  [0x1100'u16, 0xFFFF, 0x1001, 0x1002, 0x1011, 0x1012]
rc_get_new_samples(stats)
for index, expected in [0x1100'u16, 0x1001, 0x1002, 0x1011, 0x1012]:
  doAssert rcRateStats(stats, index + 1).rateConfig == expected
"""

BOUNDARY_HARNESS = r"""
var storage: array[200, uint8]
let stats = addr storage[0]
activeStats = stats
rcU16(stats, RCS_N_RATES) = 10
for index in 0 ..< 10:
  let rate = rcRateStats(stats, index)
  rate.rateConfig = (0x2000 + index).uint16
  rate.attempts = 3
  rate.successes = 2
rcRetryStep(stats, 0).rateIdx = 7
rcRetryStep(stats, 1).rateIdx = 8
rcRetryStep(stats, 2).rateIdx = 9
rcRateStats(stats, 7).rateConfig = 0x1040
rcRateStats(stats, 8).rateConfig = 0x10C0
rcRateStats(stats, 1).probability = 0x8000
rcRateStats(stats, 1).sampleSkipped = 10
rcRateStats(stats, 2).probability = 0x8000
rcRateStats(stats, 2).sampleSkipped = 11
randomConfig = 0x1100

doAssert rc_get_new_sample_rates(stats) ==
  [0x1100'u16, 0xFFFF, 0xFFFF, 0x1042, 0xFFFF, 0xFFFF]
rc_get_new_samples(stats)
doAssert rcRateStats(stats, 1).rateConfig == 0x2001
doAssert rcRateStats(stats, 2).rateConfig == 0x1100
doAssert rcRateStats(stats, 3).rateConfig == 0x1042
for index in 0 ..< 10:
  doAssert rcRateStats(stats, index).attempts == 0
  doAssert rcRateStats(stats, index).successes == 0
"""


@pytest.mark.parametrize("build_mode", ["checked", "release"])
def test_vendor_candidate_priority(build_mode: str, tmp_path: Path) -> None:
    code, source = firmware_prelude(PLATFORM)
    code += procedure(source, "rc_get_new_sample_rates")
    code += procedure(source, "rc_get_new_samples")
    compile_and_run(code + HARNESS, tmp_path, build_mode)


@pytest.mark.parametrize("build_mode", ["checked", "release"])
def test_vendor_candidate_preservation_boundary(build_mode: str, tmp_path: Path) -> None:
    code, source = firmware_prelude(PLATFORM)
    code += procedure(source, "rc_get_new_sample_rates")
    code += procedure(source, "rc_get_new_samples")
    compile_and_run(code + BOUNDARY_HARNESS, tmp_path, build_mode)
