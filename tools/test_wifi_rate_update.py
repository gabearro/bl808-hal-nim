"""Check rc_update_stats state transitions against the BL808 rc.o basic blocks."""

from pathlib import Path
import os
import random
import shutil
import struct
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_rate_chain import retry_oracle, sort_oracle

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  RC_MAX_RATE_ENTRIES = 10
  RC_RATE_ENTRY_SIZE = 12
  RCS_N_RATES = 192
  RCS_FLAGS = 175
  RCS_SAMPLE_IDX = 198
  RCS_SLOW_RATE_CNT = 173
  RCS_SHORT_GI = 189
  RCS_LOWEST_IDX = 185
  RCS_HIGHEST_IDX = 186
  RCS_MAX_NSS_MCS = 184
  RCS_RATE_MAP = 182
  RCS_RATE_BITMAP = 178
proc rcU8(p: pointer; offset: int): var uint8 =
  cast[ptr uint8](cast[uint](p) + offset.uint)[]
proc rcU16(p: pointer; offset: int): var uint16 =
  cast[ptr uint16](cast[uint](p) + offset.uint)[]
proc rcU32(p: pointer; offset: int): var uint32 =
  cast[ptr uint32](cast[uint](p) + offset.uint)[]
proc rcRateEntryPtr(p: pointer; index: int): pointer =
  cast[pointer](cast[uint](p) + index.uint * 12)
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
proc c_memset(dst: pointer; value: cint; size: csize_t): pointer =
  for i in 0 ..< size.int: rcU8(dst, i) = value.uint8
  dst
var activeStats: pointer
var inputTp: array[10, uint32]
var randomConfig: uint16
var callTrace: uint32
proc trace(kind, arg: uint32) =
  callTrace = (callTrace * 16777619'u32) xor ((kind shl 16) or arg)
proc rc_calc_prob_ewma(entry: pointer) =
  let offset = cast[uint](entry) - cast[uint](activeStats)
  doAssert offset >= 4 and (offset - 4) mod 12 == 0
  let index = (offset - 4) div 12
  doAssert index < rcU16(activeStats, RCS_N_RATES).uint
  trace(1, index.uint32)
proc rc_calc_tp(stats: pointer; index: uint8): uint32 =
  doAssert stats == activeStats
  trace(2, index.uint32)
  inputTp[index.int]
proc rc_new_random_rate(stats: pointer): uint16 =
  trace(3, 0)
  randomConfig
proc rc_set_next_mcs_index(stats: pointer; rate: uint16): uint16 =
  trace(4, rate.uint32)
  if (rate and 0x40) != 0: rate else: rate xor 1
proc rc_set_previous_mcs_index(stats: pointer; rate: uint16): uint16 =
  trace(5, rate.uint32)
  if (rate and 0x80) != 0: rate else: rate xor 2
proc rc_check_valid_rate(stats: pointer; rate: uint16): uint8 =
  trace(6, rate.uint32)
  ((rate and 4) == 0).uint8
proc rc_check_rate_duplicated(stats: pointer; rate: uint16): uint8 =
  trace(7, rate.uint32)
  for i in 0 ..< rcU16(stats, RCS_N_RATES).int:
    if rcU16(stats, 10 + i * 12) == rate: return 1
  0
"""

HARNESS = r"""
let vectors = readFile(vectorPath)
const stride = 449
doAssert vectors.len mod stride == 0
var storage: array[216, uint8]
let stats = addr storage[8]
activeStats = stats
for offset in countup(0, vectors.len - stride, stride):
  for i in 0 ..< storage.len: storage[i] = 0xA5
  copyMem(stats, unsafeAddr vectors[offset], 200)
  copyMem(addr inputTp[0], unsafeAddr vectors[offset + 200], 40)
  copyMem(addr randomConfig, unsafeAddr vectors[offset + 240], 2)
  callTrace = 0
  let result = rc_update_stats(stats, vectors[offset + 242].uint8)
  doAssert result == vectors[offset + 448].uint8,
    "result differs at vector " & $(offset div stride)
  doAssert equalMem(stats, unsafeAddr vectors[offset + 244], 200),
    "state differs at vector " & $(offset div stride)
  var expectedTrace: uint32
  copyMem(addr expectedTrace, unsafeAddr vectors[offset + 444], 4)
  doAssert callTrace == expectedTrace,
    "callee order/arguments differ at vector " & $(offset div stride)
  for i in 0 ..< 8:
    doAssert storage[i] == 0xA5 and storage[208 + i] == 0xA5
doAssert rc_update_stats(nil, 0) == 0
"""

REAL_MATH = r"""
var data: array[200, uint8]
let stats = addr data[0]
activeStats = stats
for count in 1 .. 10:
  data = default(typeof(data))
  rcU32(stats, 0) = 0xC0DEC0DE'u32
  rcU16(stats, RCS_N_RATES) = count.uint16
  rcStatsCounters(stats).fixedRate = 0xFFFF
  rcAmpduStats(stats).ampduLength = 8
  rcAmpduStats(stats).ampduPackets = 2
  rcAmpduStats(stats).averageLengthQ16 = 4'u32 shl 16
  for i in 0 ..< count:
    let rate = rcRateStats(stats, i)
    rate.rateConfig = 4
    rate.attempts = 2
    rate.successes = 1
  doAssert rc_update_stats(stats, 1) == (count > 1).uint8
  doAssert rcU32(stats, 0) == 0xC0DEC0DE'u32
  doAssert rcAmpduStats(stats).ampduLength == 0 and rcAmpduStats(stats).ampduPackets == 0
  doAssert rcAmpduStats(stats).averageLengthQ16 == 4'u32 shl 16
  let expected = [count - 1, (if count > 2: count - 2 else: count - 1), max(count - 3, 0), 0]
  for step in 0 ..< 4:
    doAssert rcRetryStep(stats, step).rateIdx == expected[step].uint16
    doAssert rcRetryStep(stats, step).throughput == 289
  for i in 0 ..< count:
    let rate = rcRateStats(stats, i)
    doAssert rate.probability == 32767 and rate.oldProbAvailable == 1
    doAssert rate.attempts == 2 and rate.successes == 1
    doAssert rate.retryCount == 0 and rate.rateAllowed == 1

  if count == 10:
    rcU16(stats, RCS_RATE_MAP) = 0x0FFF
    rcU8(stats, RCS_HIGHEST_IDX) = 11
    randomConfig = 5
    doAssert rc_update_stats(stats, 0) == 0
    doAssert rcRateStats(stats, 1).rateConfig == 5
    doAssert rcRateStats(stats, 2).rateConfig == 3
    for i in 0 ..< count:
      doAssert rcRateStats(stats, i).attempts == 0
      doAssert rcRateStats(stats, i).successes == 0

  rcStatsCounters(stats).fixedRate = 8
  rcStatsCounters(stats).flags = 0x20
  doAssert rc_update_stats(stats, 0) == 1
  doAssert rcStatsCounters(stats).flags == 0x40
  for step in 0 ..< 3:
    doAssert rcRetryStep(stats, step).rateIdx == (count - 1).uint16
    doAssert rcRetryStep(stats, step).throughput == 0
  doAssert rcRetryStep(stats, 3).throughput == 289
  for i in 0 ..< count:
    let rate = rcRateStats(stats, i)
    doAssert rate.attempts == 0 and rate.successes == 0
    rate.attempts = 3
    rate.successes = 1
  let current = rcRateStats(stats, count - 1)
  doAssert current.rateConfig == 8 and current.probability == 0
  current.oldProbAvailable = 0
  current.attempts = 4
  current.successes = 4
  doAssert rc_update_stats(stats, 0) == 0
  doAssert current.probability == 65535
  for i in 0 ..< count:
    let rate = rcRateStats(stats, i)
    if i == 0 or i == count - 1:
      doAssert rate.attempts == 0 and rate.successes == 0
    else:
      doAssert rate.attempts == 3 and rate.successes == 1

data = default(typeof(data))
rcU16(stats, RCS_N_RATES) = 10
rcU8(stats, RCS_MAX_NSS_MCS) = 7
rcU8(stats, RCS_SHORT_GI) = 1
rcU8(stats, RCS_RATE_BITMAP) = 0xFF
rcU8(stats, RCS_RATE_BITMAP + 1) = 0xF0
rcRateStats(stats, 0).rateConfig = 0x100C
rcRateStats(stats, 1).rateConfig = 0x1006
rcRetryStep(stats, 0).rateIdx = 0
rcRetryStep(stats, 1).rateIdx = 1
randomConfig = 0x1000
doAssert rc_get_new_sample_rates(stats) ==
  [0x1000'u16, 0x120C, 0x120D, 0xFFFF, 0x1207, 0x1205]
"""


def update_oracle(state: bytearray, tp: list[int], random_rate: int, init: int) -> tuple[int, int]:
    read16 = lambda at: struct.unpack_from("<H", state, at)[0]
    read32 = lambda at: struct.unpack_from("<I", state, at)[0]

    def put16(at: int, value: int) -> None:
        struct.pack_into("<H", state, at, value)

    def put32(at: int, value: int) -> None:
        struct.pack_into("<I", state, at, value)

    calls = 0

    def trace(kind: int, arg: int) -> None:
        nonlocal calls
        calls = ((calls * 16777619) & 0xFFFFFFFF) ^ ((kind << 16) | arg)

    def clear_counts(index: int) -> None:
        put32(4 + index * 12, 0)

    count = read16(192)
    if not 0 < count <= 10:
        return 0, 0
    before = [read16(128 + step * 8) for step in range(4)]
    packets = read16(166)
    if packets:
        # rc.o uses RV32 DIV (signed), then wrapping arithmetic and logical SRL.
        numerator = read16(164) << 16
        if numerator & 0x80000000:
            numerator -= 1 << 32
        quotient = abs(numerator) // packets
        if numerator < 0:
            quotient = -quotient
        average = ((read32(168) * 96 + quotient * 32) & 0xFFFFFFFF) >> 7
        put32(164, 0)
        put32(168, average)
    state[173] = 0
    for index in range(count):
        state[14 + index * 12] = 0
        state[15 + index * 12] = 1
    fixed = read16(198)
    changed = 0
    if fixed != 0xFFFF:
        if state[175] & 0x20:
            index = next((i for i in range(count) if read16(10 + i * 12) == fixed), count - 1)
            if read16(10 + index * 12) != fixed:
                put16(10 + index * 12, fixed)
                put16(8 + index * 12, 0)
            for step in range(3):
                put32(124 + step * 8, 0)
                put16(128 + step * 8, index)
            for index in range(count):
                clear_counts(index)
            state[175] = (state[175] & 0x9F) | 0x40
            changed = 1
        else:
            index = state[128]
            if index >= count:
                return 0, calls
            trace(1, index)
            clear_counts(index)
            clear_counts(0)
    else:
        for index in range(count):
            trace(1, index)
            trace(2, index)
        sort_oracle(state, tp, count)
        retry_oracle(state, tp, count)
        if init == 0:
            if count < 10:
                for index in range(count):
                    clear_counts(index)
            else:
                first = read16(10 + read16(128) * 12)
                second = read16(10 + read16(136) * 12)
                trace(3, 0)
                candidates = [random_rate, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF]
                if ((first >> 11) & 6) and state[189] == 1:
                    candidates[1] = first ^ 0x200
                for slot, rate, kind, mask, bit in [(2, first, 4, 0x40, 1), (3, first, 5, 0x80, 2),
                                                   (4, second, 4, 0x40, 1), (5, second, 5, 0x80, 2)]:
                    trace(kind, rate)
                    alternate = rate if rate & mask else rate ^ bit
                    if alternate != rate:
                        trace(6, alternate)
                        if not alternate & 4:
                            candidates[slot] = alternate
                index, candidate = 1, 0
                while index < count:
                    current = index
                    protected = [read16(128 + i * 8) for i in range(3)]
                    preserve = read16(8 + index * 12) >= 0x8000 and state[12 + index * 12] <= 10
                    if preserve or index in protected or candidate >= 6:
                        index += 1
                    else:
                        replacement = candidates[candidate]
                        candidate += 1
                        if replacement != 0xFFFF:
                            trace(7, replacement)
                            duplicated = any(read16(10 + i * 12) == replacement for i in range(count))
                            if not duplicated:
                                put16(10 + current * 12, replacement)
                                put16(8 + current * 12, 0)
                                state[13 + current * 12] = 0
                                index += 1
                    clear_counts(current)
                clear_counts(0)
    changed |= before != [read16(128 + step * 8) for step in range(4)]
    return int(changed), calls


def make_vectors() -> bytes:
    rng = random.Random(0x808C0)
    data = bytearray()
    for count in [0, *range(1, 11), 11, 65535]:
        for case in range(300):
            state = bytearray(rng.randbytes(200))
            struct.pack_into("<H", state, 192, count)
            for index in range(10):
                struct.pack_into("<H", state, 10 + index * 12,
                                 rng.choice([0, 1, 2, 3, 4, 0x1000, 0x1001, 0x1040, 0x1080, 0x1200, 0xFFFF]))
                struct.pack_into("<H", state, 8 + index * 12, rng.choice([0, 0x7FFF, 0x8000, 0xFFFF]))
                state[12 + index * 12] = rng.choice([0, 10, 11, 255])
            for step in range(4):
                struct.pack_into("<H", state, 128 + step * 8, rng.randrange(max(1, min(count, 10))))
            fixed = 0xFFFF if case % 4 < 2 else (
                struct.unpack_from("<H", state, 10 + rng.randrange(10) * 12)[0] if case % 4 == 2 else 0x1234)
            struct.pack_into("<H", state, 198, fixed)
            if case % 8 < 4:
                state[175] &= ~0x20
            else:
                state[175] |= 0x20
            if case % 17 == 0:
                state[128] = 255  # Invalid current index in fixed/no-change mode.
            state[189] = rng.choice([0, 1, 2])
            struct.pack_into("<HH", state, 164, rng.choice([0, 1, 32767, 32768, 65535]),
                             rng.choice([0, 1, 3, 65535]))
            tp = [rng.choice([0, 1, 5, 0xFFFFFFFF, rng.getrandbits(32)]) for _ in range(10)]
            init = rng.choice([0, 0, 1, 255])
            random_rate = rng.choice([0, 1, 0x1001, 0x1234, 0xFFFF])
            data += state + struct.pack("<10IHBB", *tp, random_rate, init, 0)
            result, calls = update_oracle(state, tp.copy(), random_rate, init)
            data += state + struct.pack("<IB", calls, result)
    return bytes(data)


def firmware_prelude(platform: str) -> tuple[str, str]:
    layout = (FW / "layout_types.nim").read_text()
    helpers = (FW / "runtime_helpers.nim").read_text()
    source = (FW / "rate_control.nim").read_text()
    types = "  RcRateEntryView" + layout.split("  RcRateEntryView", 1)[1].split("  TxFrameEnvView", 1)[0]
    code = platform + "\ntype\n" + types
    code += "\ntemplate rcRateEntryAt" + helpers.split("template rcRateEntryAt", 1)[1].split(
        "proc rcClearRateEntryTransientStats", 1)[0]
    return code, source


def compile_and_run(code: str, tmp_path: Path, build_mode: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "rate_update.nim"
    path.write_text(code)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    command += ["--checks:on"] if build_mode == "checked" else ["-d:release", "--checks:off"]
    if build_mode == "asan":
        command += ["--passC:-fsanitize=address", "--passC:-fno-omit-frame-pointer", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(path)], cwd=ROOT, text=True,
                            env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0"},
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("build_mode", ["checked", "release", "asan"])
def test_rate_update(build_mode: str, tmp_path: Path) -> None:
    code, source = firmware_prelude(PLATFORM)
    for name in ["rc_get_mcs_index", "rc_sort_samples_tp", "rc_update_retry_chain"]:
        if name == "rc_update_retry_chain":
            code += procedure((FW / "kernel_mac_channel.nim").read_text(), "is_cck_group")
        code += procedure(source, name)
    for name in ["rc_get_new_sample_rates", "rc_get_new_samples"]:
        if f"proc {name}(" in source:
            code += procedure(source, name)
    code += procedure(source, "rc_update_stats")
    vector_path = tmp_path / "vectors.bin"
    vector_path.write_bytes(make_vectors())
    code += f'\nconst vectorPath = "{vector_path}"\n' + HARNESS
    compile_and_run(code, tmp_path, build_mode)


@pytest.mark.parametrize("build_mode", ["checked", "release", "asan"])
def test_rate_update_real_math(build_mode: str, tmp_path: Path) -> None:
    platform = PLATFORM.split("proc rc_calc_prob_ewma", 1)[0]
    platform += procedure(PLATFORM, "rc_new_random_rate")
    code, source = firmware_prelude(platform)
    code += procedure((FW / "runtime_helpers.nim").read_text(), "rcRateConfig")
    code += (FW / "rate_duration_tables.nim").read_text()
    for name in ["rc_get_mcs_index", "rc_get_nss", "rc_get_duration", "rc_calc_prob_ewma"]:
        code += procedure(source, name)
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "is_cck_group")
    for name in ["rc_calc_tp", "rc_check_valid_rate", "rc_check_rate_duplicated",
                 "rc_set_next_mcs_index", "rc_set_previous_mcs_index",
                 "rc_sort_samples_tp", "rc_update_retry_chain",
                 "rc_get_new_sample_rates", "rc_get_new_samples", "rc_update_stats"]:
        code += procedure(source, name)
    compile_and_run(code + REAL_MATH, tmp_path, build_mode)
