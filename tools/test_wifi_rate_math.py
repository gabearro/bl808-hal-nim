"""Compare production rate-control math with decoded BL808 calculations."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const RC_MAX_RATE_ENTRIES = 10
const
  RCS_N_RATES = 192
  RCS_SAMPLE_IDX = 198
  RCS_SLOW_RATE_CNT = 173
  RCS_SHORT_GI = 189
type
  RateEntry {.packed.} = object
    padding: array[4, uint8]
    attempts, successes, probEwma, rateConfig: uint16
  StatsMean {.packed.} = object
    padding: array[170, uint8]
    avgAmpduLen: uint16
    sampleWait, slowRateCount, updateStage, flags: uint8
    tailPadding: array[22, uint8]
    fixedRate: uint16
  RcRateStatsView {.packed.} = object
    attempts, successes, probability, rateConfig: uint16
    sampleSkipped, oldProbAvailable, retryCount, rateAllowed: uint8
  RcRetryStepView {.packed.} = object
    throughput: uint32
    rateIdx: uint16
    padding: array[2, uint8]
  RcAmpduStatsView {.packed.} = object
    ampduLength, ampduPackets: uint16
    averageLengthQ16: uint32
proc rcU16(p: pointer; offset: int): var uint16 =
  cast[ptr uint16](cast[uint](p) + offset.uint)[]
proc rcU8(p: pointer; offset: int): var uint8 =
  cast[ptr uint8](cast[uint](p) + offset.uint)[]
proc rcU32(p: pointer; offset: int): var uint32 =
  cast[ptr uint32](cast[uint](p) + offset.uint)[]
proc rcRateEntryPtr(p: pointer; index: int): pointer =
  cast[pointer](cast[uint](p) + index.uint * 12)
proc rcRateEntryAt(p: pointer): ptr RateEntry = cast[ptr RateEntry](p)
proc rcRateEntry(p: pointer; index: uint16): ptr RateEntry =
  cast[ptr RateEntry](cast[uint](p) + index.uint * 12)
proc rcStatsCounters(p: pointer): ptr StatsMean = cast[ptr StatsMean](p)
proc rcRateStats(p: pointer; index: int): ptr RcRateStatsView =
  cast[ptr RcRateStatsView](cast[uint](p) + 4 + index.uint * 12)
proc rcRetryStep(p: pointer; index: int): ptr RcRetryStepView =
  cast[ptr RcRetryStepView](cast[uint](p) + 124 + index.uint * 8)
proc rcAmpduStats(p: pointer): ptr RcAmpduStatsView =
  cast[ptr RcAmpduStatsView](cast[uint](p) + 164)
"""

TABLES = r"""
const expectedCck = [10452000'u32, 10548000, 5380000, 5476000,
  2315000, 2411000, 1439000, 1535000]
const expectedOfdm = [1600000'u32, 1068000, 800000, 536000,
  400000, 268000, 200000, 180000]
const expectedHt = [1477000'u32, 1329350, 711250, 640175, 328250, 295475, 164250, 147875,
  738500, 664700, 355750, 320225, 164250, 147875, 82250, 74075,
  492500, 443300, 237250, 213575, 109500, 98600, 54750, 49325,
  369250, 332375, 178000, 160250, 82250, 74075, 40000, 36050,
  246250, 221675, 118750, 106925, 54750, 49325, 27500, 24800,
  184750, 166325, 89000, 80150, 41250, 37175, 20750, 18725,
  164250, 147875, 79250, 71375, 36500, 32900, 18250, 16475,
  147750, 133025, 71250, 64175, 33000, 29750, 16500, 14900,
  123250, 110975, 59500, 53600, 27500, 24800, 13750, 12425,
  111000, 99950, 53500, 48200, 24750, 22325, 12500, 11300]
proc expectedDuration(rate: uint16): uint32 =
  let format = (rate shr 11) and 7
  if (format and 6) == 0:
    let mcs = (rate and 127).int
    if mcs < 4: return expectedCck[mcs * 2 + ((rate shr 10) and 1).int]
    if mcs < 12: return expectedOfdm[mcs - 4]
    return 0
  if format notin [2'u16, 3'u16]: return 0
  let mcs = (rate and 7).int
  let streams = ((rate shr 3) and 3).uint32 + 1
  let bandwidth = ((rate shr 7) and 3).int
  let gi = ((rate shr 9) and 1).int
  expectedHt[mcs * 8 + bandwidth * 2 + gi] div streams
"""

PROBABILITY = r"""
var data: array[12, uint8]
let entry = addr data[0]
for attempts in 1'u16 .. 256'u16:
  for successes in 0'u16 .. attempts:
    for oldProb in [0'u16, 1, 32768, 65535]:
      for initialized in [false, true]:
        data = default(typeof(data))
        rcU16(entry, 0) = attempts
        rcU16(entry, 2) = successes
        rcU16(entry, 4) = oldProb
        rcU8(entry, 8) = 17
        rcU8(entry, 9) = initialized.uint8
        let ratio = successes.uint64 * 65536 div attempts.uint64
        let expected = if initialized: (oldProb.uint64 * 3 + ratio) div 4
          elif successes == 0: 0'u64
          else: ratio - 1
        rc_calc_prob_ewma(entry)
        doAssert rcU16(entry, 4) == expected.uint16, "incorrect first sample or EWMA"
        doAssert rcU16(entry, 0) == attempts and rcU16(entry, 2) == successes
        doAssert rcU8(entry, 8) == 0 and rcU8(entry, 9) == 1
for idle in 0'u16 .. 255'u16:
  data = default(typeof(data))
  rcU16(entry, 4) = 32100
  rcU8(entry, 8) = idle.uint8
  rc_calc_prob_ewma(entry)
  doAssert rcU16(entry, 4) == 32100 and rcU8(entry, 9) == 0
  doAssert rcU8(entry, 8) == min(idle + 1, 255'u16).uint8
"""

DURATION = r"""
doAssert RcDurationCck == expectedCck
doAssert RcDurationNonHt == expectedOfdm
doAssert RcDurationHtAmpdu == expectedHt
for raw in 0'u32 .. 65535'u32:
  let rate = raw.uint16
  doAssert rc_get_duration(rate) == expectedDuration(rate), "duration table or index mismatch"
  let format = (rate shr 11) and 7
  let expectedNss = if format in [2'u16, 3'u16]: ((rate shr 3) and 3).uint8 else: 0'u8
  doAssert rc_get_nss(rate) == expectedNss, "NSS decoded from MCS bits"
"""

THROUGHPUT = r"""
var data: array[200, uint8]
let stats = addr data[0]
for sample in 0'u8 .. 9'u8:
  for rate in [0'u16, 1, 3, 4, 11, 0x1000, 0x1207, 0x13FF, 0x2000]:
    for prob in [0'u16, 0x1997, 0x1998, 0x1999, 32768, 65535]:
      for mean in [0'u16, 1, 4, 64, 65535]:
        data = default(typeof(data))
        let entry = rcRateEntry(stats, sample.uint16)
        entry.rateConfig = rate
        entry.probEwma = prob
        rcStatsCounters(stats).avgAmpduLen = mean
        let cck = (((rate shr 11) and 6) == 0) and (rate and 127) < 4
        let duration = expectedDuration(rate)
        var expected = 0'u32
        if prob > 0x1998 and duration > 0 and (cck or mean != 0):
          let overhead = if cck: 0'u64 else: 218000'u64 div mean.uint64
          let step = (prob.uint64 * 1000) div (duration.uint64 + overhead)
          expected = (((step * 1000000) and 0xFFFFFFFF'u64) shr 16).uint32
        doAssert rc_calc_tp(stats, sample) == expected, "throughput Q16 scaling or entry selection mismatch"
doAssert rc_calc_tp(nil, 0) == 0
doAssert rc_calc_tp(stats, 10) == 0
doAssert rc_calc_tp(stats, 255) == 0
"""

INTEGRATION_STUBS = r"""
proc c_memcpy(dst, src: pointer; length: csize_t): pointer =
  copyMem(dst, src, length.int)
  dst
proc c_memset(dst: pointer; value: cint; length: csize_t): pointer =
  doAssert value == 0
  zeroMem(dst, length.int)
  dst
var sortedThroughput: pointer
proc rc_sort_samples_tp(stats, tp: pointer) =
  sortedThroughput = tp
  for i in 0 ..< rcU16(stats, RCS_N_RATES).int:
    doAssert cast[ptr UncheckedArray[uint32]](tp)[i] == rc_calc_tp(stats, i.uint8)
proc rc_update_retry_chain(stats, tp: pointer) =
  doAssert tp == sortedThroughput
proc rc_new_random_rate(stats: pointer): uint16 = 0
proc rc_check_rate_duplicated(stats: pointer; rate: uint16): uint8 = 0
proc rc_check_valid_rate(stats: pointer; rate: uint16): uint8 = 0
proc rc_set_next_mcs_index(stats: pointer; rate: uint16): uint16 = rate
proc rc_set_previous_mcs_index(stats: pointer; rate: uint16): uint16 = rate
proc rc_get_new_samples(stats: pointer) = discard
"""

INTEGRATION = r"""
var data: array[200, uint8]
let stats = addr data[0]
for count in 1'u16 .. 10'u16:
  data = default(typeof(data))
  rcU32(stats, 0) = 0xDEADBEEF'u32
  for i in 0'u16 ..< count:
    let entry = rcRateEntry(stats, i)
    entry.attempts = 2
    entry.successes = 1
    entry.rateConfig = 4
  rcU16(stats, RCS_N_RATES) = count
  rcU16(stats, RCS_SAMPLE_IDX) = 0xFFFF
  rcStatsCounters(stats).avgAmpduLen = 4
  doAssert rc_update_stats(stats, 1) == 0
  doAssert rcU32(stats, 0) == 0xDEADBEEF'u32, "probability update modified last_rc_time"
  for i in 0'u16 ..< count:
    doAssert rcRateEntry(stats, i).probEwma == 32767
    doAssert rcRateEntry(stats, i).attempts == 2
    doAssert rcRateEntry(stats, i).successes == 1
"""


@pytest.mark.parametrize("scenario", ["probability", "duration", "throughput", "integration"])
@pytest.mark.parametrize("release_mode", [False, True])
def test_rate_math(scenario: str, release_mode: bool, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    source = (FW / "rate_control.nim").read_text()
    names = ["rc_calc_prob_ewma"] if scenario == "probability" else [
        "rc_get_mcs_index", "rc_get_nss", "rc_get_duration"]
    code = PLATFORM
    table_file = FW / "rate_duration_tables.nim"
    if table_file.exists():
        code += table_file.read_text()
    code += "\n".join(procedure(source, name) for name in names)
    if scenario in ["throughput", "integration"]:
        code += procedure((FW / "kernel_mac_channel.nim").read_text(), "is_cck_group")
        code += procedure(source, "rc_calc_tp")
    if scenario == "integration":
        code += procedure(source, "rc_calc_prob_ewma")
        code += INTEGRATION_STUBS
        code += procedure(source, "rc_update_stats")
    code += TABLES
    code += {"probability": PROBABILITY, "duration": DURATION,
             "throughput": THROUGHPUT, "integration": INTEGRATION}[scenario]
    path = tmp_path / "rate_math.nim"
    path.write_text(code)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
               "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    command += ["-d:release", "--checks:off"] if release_mode else ["--checks:on"]
    result = subprocess.run(command + [str(path)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
