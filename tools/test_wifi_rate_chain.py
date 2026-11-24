"""Exercise production sorting/retry code against the BL808 rc.o control flow."""

from pathlib import Path
import random
import shutil
import struct
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  RC_MAX_RATE_ENTRIES = 10
  STA_INFO_TAB_ENTRIES = 7
  RC_RATE_ENTRY_SIZE = 12
  RCS_N_RATES = 192
  RCS_FLAGS = 175
  RCS_SAMPLE_IDX = 198
  RCS_NO_SS = 187
  RCS_GROUP_CNT = 188
  RCS_BW_MAX = 190
  StaTxPolicyUpdateRateControl = 1'u8
proc rcU8(p: pointer; offset: int): var uint8 =
  cast[ptr uint8](cast[uint](p) + offset.uint)[]
proc rcU16(p: pointer; offset: int): var uint16 =
  cast[ptr uint16](cast[uint](p) + offset.uint)[]
proc rcU32(p: pointer; offset: int): var uint32 =
  cast[ptr uint32](cast[uint](p) + offset.uint)[]
"""

VECTORS = r"""
let vectors = readFile(vectorPath)
doAssert vectors.len mod 480 == 0
var data: array[200, uint8]
var tp: array[10, uint32]
let stats = addr data[0]
for offset in countup(0, vectors.len - 480, 480):
  copyMem(stats, unsafeAddr vectors[offset], 200)
  copyMem(addr tp[0], unsafeAddr vectors[offset + 200], 40)
  testedProc(stats, addr tp[0])
  doAssert equalMem(stats, unsafeAddr vectors[offset + 240], 200),
    "rate state mismatch at vector " & $(offset div 480)
  doAssert equalMem(addr tp[0], unsafeAddr vectors[offset + 440], 40),
    "throughput mismatch at vector " & $(offset div 480)
testedProc(nil, addr tp[0])
let before = data
testedProc(stats, nil)
doAssert before == data
"""

RESET = r"""
var data: array[200, uint8]
for i in 0 ..< data.len: data[i] = (i xor 0xBA).uint8
let stats = addr data[0]
for index in 0 ..< 10:
  let before = data
  rcClearRateEntryTransientStats(stats, index.uint16)
  for offset in 0 ..< data.len:
    let local = offset - (4 + index * 12)
    let expected = if local in [4, 5, 9, 10]: 0'u8
      elif local == 11: 1'u8
      else: before[offset]
    doAssert data[offset] == expected, "reset corrupts counters or adjacent records"
"""

CALLER_STUBS = r"""
type Sta = object
  rcStats: pointer
  txPolicyUpdateFlags: array[1, uint8]
var sta: Sta
var sortedTp: pointer
var sortCalls, chainCalls, duplicateCalls, randomCalls: int
var exhaustedRates: bool
proc staInfoForIdx(index: uint8): ptr Sta =
  doAssert index == 2
  addr sta
proc assert_err(a, b: cstring; line: cint) = discard
proc rc_get_lowest_rate_config(stats: pointer): uint16 = 0x400
proc rc_get_initial_rate_config(stats: pointer): uint16 = 0x1007
proc rc_check_rate_duplicated(stats: pointer; config: uint16): uint8 =
  inc duplicateCalls
  for i in 0 ..< rcU16(stats, RCS_N_RATES).int:
    if rcRateStats(stats, i).rateConfig == config: return 1
  0
proc rc_pick_non_duplicate_rate(stats: pointer): uint16 =
  inc randomCalls
  if exhaustedRates: return 0xFFFF
  0x1800'u16 + randomCalls.uint16
proc rcSetRateConfig(stats: pointer; index: int; config: uint16) =
  rcRateStats(stats, index).rateConfig = config
proc rc_sort_samples_tp(stats, tp: pointer) =
  inc sortCalls
  sortedTp = tp
  doAssert stats == sta.rcStats
  for i in 0 ..< RC_MAX_RATE_ENTRIES:
    doAssert rcThroughputArray(tp)[i] == 0, "caller passed uninitialized/undersized array"
proc rc_update_retry_chain(stats, tp: pointer) =
  inc chainCalls
  doAssert sortedTp == tp, "retry chain received a different scratch buffer"
"""

CALLERS = r"""
var data: array[200, uint8]
let stats = addr data[0]
proc setup(count: int; fixed: uint16) =
  for i in 0 ..< data.len: data[i] = 0xBA
  sta = Sta(rcStats: stats)
  sortedTp = nil
  sortCalls = 0
  chainCalls = 0
  duplicateCalls = 0
  randomCalls = 0
  exhaustedRates = false
  rcU16(stats, RCS_N_RATES) = count.uint16
  rcU16(stats, RCS_SAMPLE_IDX) = fixed
  rcU8(stats, RCS_BW_MAX) = 0
  for i in 0 ..< min(count, 10):
    rcRateStats(stats, i).rateConfig = if i < 2: i.uint16 else: 0x1000'u16 + i.uint16
proc verifyReset(count: int; before: array[200, uint8]; resetAll: bool) =
  doAssert sortCalls == 1 and chainCalls == 1
  doAssert sta.txPolicyUpdateFlags[0] == StaTxPolicyUpdateRateControl
  doAssert rcU32(stats, 0) == 0xBABABABA'u32
  for i in 0 ..< count:
    let rate = rcRateStats(stats, i)
    if resetAll or i < 2:
      doAssert rate.probability == 0 and rate.oldProbAvailable == 0
      doAssert rate.retryCount == 0 and rate.rateAllowed == 1
    else:
      doAssert rate.probability == 0xBABA and rate.oldProbAvailable == 0xBA
      doAssert rate.retryCount == 0xBA and rate.rateAllowed == 0xBA
    doAssert rate.attempts == 0xBABA and rate.successes == 0xBABA
    doAssert rate.sampleSkipped == 0xBA
  for i in 4 + count * 12 ..< 124: doAssert data[i] == before[i]
for count in 1 .. 10:
  setup(count, 0xFFFF)
  let before = data
  rc_update_bw_nss_max(2, 1, 2)
  verifyReset(count, before, true)
  doAssert rcRateStats(stats, count - 1).rateConfig == 0x1007
  setup(count, 0xFFFF)
  let beforePreamble = data
  rc_update_preamble_type(2, 1)
  verifyReset(count, beforePreamble, false)
  for i in 0 ..< min(count, 2): doAssert rcRateStats(stats, i).rateConfig == (0x400 or i).uint16
  for i in 2 ..< count: doAssert rcRateStats(stats, i).rateConfig == 0x1000'u16 + i.uint16
  doAssert duplicateCalls == 0 and randomCalls == 0
  rc_update_preamble_type(2, 1)
  doAssert sortCalls == 1
  rc_update_preamble_type(2, 0)
  doAssert sortCalls == 1
for fixed in [0'u16, 0x1007]:
  setup(10, fixed)
  let before = data
  rc_update_preamble_type(2, 1)
  doAssert sortCalls == 0 and chainCalls == 0
  doAssert data[0 ..< 190] == before[0 ..< 190]
  rc_update_bw_nss_max(2, 1, 2)
  doAssert sortCalls == 0
for invalid in [0, 11, 65535]:
  setup(invalid, 0xFFFF)
  rc_update_preamble_type(2, 1)
  rc_update_bw_nss_max(2, 1, 2)
  doAssert sortCalls == 0 and chainCalls == 0
setup(3, 0xFFFF)
rcRateStats(stats, 1).rateConfig = 0x400
rc_update_preamble_type(2, 1)
doAssert randomCalls == 1
doAssert rcRateStats(stats, 0).rateConfig == 0x400
doAssert rcRateStats(stats, 1).rateConfig == 0x1801
setup(3, 0xFFFF)
rcRateStats(stats, 0).rateConfig = 0x400
rc_update_preamble_type(2, 1)
doAssert randomCalls == 0
doAssert rcRateStats(stats, 0).rateConfig == 0x400
setup(3, 0xFFFF)
rcRateStats(stats, 2).rateConfig = 0x401
rc_update_preamble_type(2, 1)
doAssert randomCalls == 1
doAssert rcRateStats(stats, 0).rateConfig == 0x400
doAssert rcRateStats(stats, 1).rateConfig == 0x1801
doAssert rcRateStats(stats, 2).rateConfig == 0x401
setup(3, 0xFFFF)
rcRateStats(stats, 1).rateConfig = 0x400
exhaustedRates = true
rc_update_preamble_type(2, 1)
doAssert rcU16(stats, RCS_N_RATES) == 2
doAssert rcRateStats(stats, 0).rateConfig == 0x400
doAssert rcRateStats(stats, 1).rateConfig == 0x1002
doAssert rcRateStats(stats, 2).rateConfig == 0xFFFF
"""


def sort_oracle(state: bytearray, tp: list[int], count: int) -> None:
    if not 0 < count <= 10:
        return
    # The disassembled sorter compares only indices 1..count-1 and is stable.
    order = [0] + sorted(range(1, count), key=tp.__getitem__)
    records = [state[4 + i * 12:16 + i * 12] for i in order]
    values = [tp[i] for i in order]
    state[4:4 + count * 12] = b"".join(records)
    tp[:count] = values


def retry_oracle(state: bytearray, tp: list[int], count: int) -> None:
    if not 0 < count <= 10:
        return
    u16 = lambda offset: struct.unpack_from("<H", state, offset)[0]
    allowed = lambda index: state[15 + index * 12] != 0
    cck = lambda index: (u16(10 + index * 12) >> 11) & 6 == 0 and u16(10 + index * 12) & 127 < 4
    # Label/offset progression follows rc.o, not the production helper structure.
    if state[175] & 4 or tp[count - 1] >= tp[0]:
        best, score, rank = count - 1, tp[count - 1], 2
    else:
        best, score, rank = 0, 0, 1
    if not cck(best):
        for index in range(count - 1):
            if cck(index):
                state[15 + index * 12] = 0
        state[15 + best * 12] = 1
    second, second_score = best, score
    while True:  # 0x84: rank advances even when the search terminates.
        previous_rank = rank
        rank += 1
        if previous_rank >= count:
            break
        index = count - previous_rank
        if allowed(index):
            second, second_score = index, tp[index]
            break
    index = count - rank  # 0xb4
    while (count - index) & 0xFFFF < count:
        if allowed(index):
            break
        index -= 1
    else:
        index = second
    probability, score = u16(8 + index * 12), tp[index]
    for candidate in range(second):
        if not allowed(candidate) or candidate == best:
            continue
        candidate_probability = u16(8 + candidate * 12)
        if candidate_probability > 0xF332:
            accept = tp[candidate] >= score
        else:
            accept = candidate_probability >= probability
        if accept:
            index, probability, score = candidate, candidate_probability, tp[candidate]
    for slot, (entry, value) in enumerate([(best, tp[best] if best == count - 1 else 0),
                                         (second, second_score), (index, tp[index]), (0, tp[0])]):
        struct.pack_into("<IH", state, 124 + slot * 8, value, entry)


def vectors(scenario: str) -> bytes:
    rng = random.Random(0xB1808)
    output = bytearray()
    for count in [0, *range(1, 11), 11, 65535]:
        for case in range(400):
            state = bytearray(rng.randbytes(200))
            struct.pack_into("<H", state, 192, count)
            tp = [rng.choice([0, 1, 3, 5, 0xFFFFFFFF, rng.getrandbits(32)]) for _ in range(10)]
            for i in range(10):
                struct.pack_into("<H", state, 10 + 12 * i, rng.choice([0, 3, 4, 11, 0x1007, 0xFFFF]))
                struct.pack_into("<H", state, 8 + 12 * i, rng.choice([0, 1, 0xF331, 0xF332, 0xF333, 0xFFFF]))
                state[15 + 12 * i] = rng.choice([0, 1, 2])
            if case % 4 == 0:
                tp = [0] * 10
            output += state + struct.pack("<10I", *tp)
            if scenario in ["sort", "pipeline"]:
                sort_oracle(state, tp, count)
            if scenario in ["retry", "pipeline"]:
                retry_oracle(state, tp, count)
            output += state + struct.pack("<10I", *tp)
    return bytes(output)


@pytest.mark.parametrize("scenario", ["sort", "retry", "pipeline", "reset", "callers"])
@pytest.mark.parametrize("release_mode", [False, True])
def test_rate_chain(scenario: str, release_mode: bool, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    layout = (FW / "layout_types.nim").read_text()
    helpers = (FW / "runtime_helpers.nim").read_text()
    source = (FW / "rate_control.nim").read_text()
    types = layout.split("  RcRateEntryView", 1)[1].split("  RcRetrySlotView", 1)[0]
    code = PLATFORM + "\ntype\n  RcRateEntryView" + types
    code += "\ntemplate rcRateEntryAt" + helpers.split("template rcRateEntryAt", 1)[1].split(
        "template rcStatsCounters", 1)[0]
    code += procedure(source, "rc_get_mcs_index")
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "is_cck_group")
    if scenario in ["reset", "callers"]:
        code += procedure(helpers, "rcClearRateEntryTransientStats")
    if scenario == "callers":
        code += CALLER_STUBS
        code += procedure(source, "rc_seed_rate_table")
        code += procedure(source, "rc_update_bw_nss_max")
        code += procedure(source, "rc_update_preamble_type")
        code += CALLERS
    elif scenario == "reset":
        code += RESET
    else:
        functions = {"sort": ["rc_sort_samples_tp"], "retry": ["rc_update_retry_chain"],
                     "pipeline": ["rc_sort_samples_tp", "rc_update_retry_chain"]}[scenario]
        code += "\n".join(procedure(source, function) for function in functions)
        vector_path = tmp_path / "vectors.bin"
        vector_path.write_bytes(vectors(scenario))
        code += f'\nconst vectorPath = "{vector_path}"\n'
        code += "template testedProc(stats, tp: pointer) =\n"
        code += "".join(f"  {function}(stats, tp)\n" for function in functions) + VECTORS
    path = tmp_path / "rate_chain.nim"
    path.write_text(code)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    command += ["-d:release", "--checks:off"] if release_mode else ["--checks:on"]
    result = subprocess.run(command + [str(path)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
