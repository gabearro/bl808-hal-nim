"""Focused rc.o parity check for the fixed-rate stats refresh path."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_rate_update import PLATFORM, compile_and_run, firmware_prelude


HARNESS = r"""
var storage: array[200, uint8]
let stats = addr storage[0]
activeStats = stats
# The archive loads a byte at stats+128 in the fixed-rate steady path.
# The high byte is deliberately nonzero to distinguish it from a u16 read.
rcU16(stats, RCS_N_RATES) = 3
rcRetryStep(stats, 0).rateIdx = 0x0101
rcStatsCounters(stats).fixedRate = 7
rcStatsCounters(stats).flags = 0
rcRateStats(stats, 0).attempts = 3
rcRateStats(stats, 1).attempts = 4
rcRateStats(stats, 2).attempts = 5
callTrace = 0
doAssert rc_update_stats(stats, 0) == 0
doAssert callTrace == ((1'u32 shl 16) or 1'u32)
doAssert rcRateStats(stats, 0).attempts == 0
doAssert rcRateStats(stats, 1).attempts == 0
doAssert rcRateStats(stats, 2).attempts == 5
doAssert rcRetryStep(stats, 0).rateIdx == 0x0101
"""


@pytest.mark.parametrize("build_mode", ["checked", "release"])
def test_vendor_stats_refresh_details(build_mode: str, tmp_path: Path) -> None:
    code, source = firmware_prelude(PLATFORM)
    code += """
proc rc_sort_samples_tp(stats, tp: pointer) = discard
proc rc_update_retry_chain(stats, tp: pointer) = discard
proc rc_get_new_samples(stats: pointer) = discard
"""
    code += procedure(source, "rc_update_stats")
    compile_and_run(code + HARNESS, tmp_path, build_mode)
