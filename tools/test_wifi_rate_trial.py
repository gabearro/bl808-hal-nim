"""Compare production rc_check with the BL808 trial-state basic blocks."""

from pathlib import Path
import os
import random
import shutil
import struct
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"
MASK = 0xFFFFFFFF

PLATFORM = r"""
const
  RC_MAX_RATE_ENTRIES = 10
  RC_RATE_ENTRY_SIZE = 12
  RC_UPDATE_INTERVAL = 100000'u32
  MACHW_TIMLO_REG = 0x24B00120'u
proc rcU8(p: pointer; offset: int): var uint8 = cast[ptr uint8](cast[uint](p) + offset.uint)[]
proc rcU16(p: pointer; offset: int): var uint16 = cast[ptr uint16](cast[uint](p) + offset.uint)[]
proc rcU32(p: pointer; offset: int): var uint32 = cast[ptr uint32](cast[uint](p) + offset.uint)[]
var rcPrngState: uint32
var interruptsEnabled = true
proc irqSave(): uint32 =
  result = interruptsEnabled.uint32 * 8
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
template rcPrngNext(): uint32 =
  rcPrngState = rcPrngState * 0x41C64E6D'u32 + 0x3039'u32
  rcPrngState
proc rcRateEntryPtr(p: pointer; index: int): pointer = cast[pointer](cast[uint](p) + index.uint * 12)
proc rcRateConfig(p: pointer; index: int): uint16 = rcU16(p, 10 + index * 12)
type Sta = object
  rcStats: pointer
  txPolicyUpdateFlags: array[1, uint8]
  instNbr: uint8
var
  sta: Sta
  firstTime, secondTime, traceHash: uint32
  timeReads, errors: int
  updateResult: uint8
  durations, throughputs: array[10, uint32]
  nssValues: array[10, uint8]
  nimFwDbgRcUpdateCalls, nimFwDbgRcUpdateMeta, nimFwDbgRcUpdateArgs: uint32
  nimFwDbgRcUpdateSlot, nimFwDbgRcUpdateEntry, nimFwDbgRcUpdateCounts, nimFwDbgRcUpdateFail: uint32
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc trace(kind, value: uint32) =
  traceHash = (traceHash * 16777619'u32) xor ((kind shl 16) or value)
proc staInfoForIdx(index: uint8): ptr Sta =
  doAssert index <= 4
  trace(1, index.uint32)
  addr sta
proc assert_err(file, expr: cstring; line: int) = inc errors
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG and timeReads < 2
  trace(3, timeReads.uint32)
  inc timeReads
  if timeReads == 1: firstTime else: secondTime
proc rc_update_stats(stats: pointer; init: uint8): uint8 =
  doAssert stats == sta.rcStats and init == 0
  trace(4, init.uint32)
  rcU8(stats, 175) = rcU8(stats, 175) xor 0xD3
  rcU8(stats, 174) = 3
  rcU8(stats, 176) = 0xA5
  updateResult
proc rateIndex(rate: uint16): int =
  for i in 0 ..< rcU16(sta.rcStats, 192).int:
    if rcU16(sta.rcStats, 10 + i * 12) == rate: return i
  doAssert false, "callee received a rate outside the table"
proc rc_get_duration(rate: uint16): uint32 =
  trace(5, rate.uint32)
  durations[rateIndex(rate)]
proc rc_get_nss(rate: uint16): uint8 =
  trace(6, rate.uint32)
  nssValues[rateIndex(rate)]
proc rc_calc_tp(stats: pointer; index: uint8): uint32 =
  doAssert stats == sta.rcStats and index < rcU16(stats, 192)
  trace(7, index.uint32)
  throughputs[index.int]
"""

HARNESS = r"""
let vectors = readFile(vectorPath)
const stride = 516
doAssert vectors.len mod stride == 0
var storage: array[216, uint8]
let stats = addr storage[8]
sta.rcStats = stats
for offset in countup(0, vectors.len - stride, stride):
  for value in storage.mitems: value = 0xA5
  copyMem(stats, unsafeAddr vectors[offset], 200)
  copyMem(addr durations[0], unsafeAddr vectors[offset + 200], 40)
  copyMem(addr throughputs[0], unsafeAddr vectors[offset + 240], 40)
  copyMem(addr nssValues[0], unsafeAddr vectors[offset + 280], 10)
  copyMem(addr firstTime, unsafeAddr vectors[offset + 290], 4)
  copyMem(addr secondTime, unsafeAddr vectors[offset + 294], 4)
  copyMem(addr rcPrngState, unsafeAddr vectors[offset + 298], 4)
  updateResult = vectors[offset + 302].uint8
  sta.txPolicyUpdateFlags[0] = vectors[offset + 303].uint8
  traceHash = 0
  timeReads = 0
  errors = 0
  rc_check(vectors[offset + 304].uint8)
  doAssert equalMem(stats, unsafeAddr vectors[offset + 306], 200),
    "state differs at trial vector " & $(offset div stride)
  var expectedPrng, expectedTrace: uint32
  copyMem(addr expectedPrng, unsafeAddr vectors[offset + 506], 4)
  copyMem(addr expectedTrace, unsafeAddr vectors[offset + 512], 4)
  doAssert rcPrngState == expectedPrng, "incorrect PRNG draw count"
  doAssert sta.txPolicyUpdateFlags[0] == vectors[offset + 510].uint8, "lost TX policy refresh"
  doAssert timeReads == vectors[offset + 511].int and traceHash == expectedTrace,
    "callee order or arguments differ at trial vector " & $(offset div stride)
  doAssert errors == 0
  for i in 0 ..< 8: doAssert storage[i] == 0xA5 and storage[208 + i] == 0xA5

for invalid in [5'u8, 255]:
  traceHash = 0
  timeReads = 0
  rc_check(invalid)
  doAssert traceHash == 0 and timeReads == 0
sta.rcStats = nil
errors = 0
timeReads = 0
rc_check(0)
doAssert errors == 1 and timeReads == 0
sta.rcStats = stats
for count in [0'u16, 11, 65535]:
  rcU16(stats, 192) = count
  timeReads = 0
  rc_check(0)
  doAssert timeReads == 0
zeroMem(stats, 200)
rcU16(stats, 192) = 4
rcU8(stats, 174) = 1
rcU16(stats, 128) = 99
timeReads = 0
firstTime = 0
sta.txPolicyUpdateFlags[0] = 0
let savedPrng = rcPrngState
rc_check(0)
doAssert rcU8(stats, 174) == 0 and rcPrngState == savedPrng
doAssert sta.txPolicyUpdateFlags[0] == 0
rcU16(stats, 128) = 0
rcU16(stats, 160) = 0xFFFF
rcU8(stats, 174) = 3
timeReads = 0
rc_check(0)
doAssert rcU8(stats, 174) == 0 and sta.txPolicyUpdateFlags[0] == 0
"""

SEQUENCE = r"""
var state: array[200, uint8]
let stats = addr state[0]
sta.rcStats = stats
for first in [false, true]:
  state = default(typeof(state))
  sta.txPolicyUpdateFlags[0] = 0
  errors = 0
  timeReads = 0
  firstTime = 0
  rcU16(stats, 192) = 4
  rcU16(stats, 170) = 4
  rcU8(stats, 177) = 2
  for i in 0 ..< 4:
    rcRateStats(stats, i).rateConfig = (0x1000 + i).uint16
  rcRetryStep(stats, 0).rateIdx = 0
  rcRetryStep(stats, 0).throughput = 100
  rcRetryStep(stats, 1).rateIdx = 1
  rcRetryStep(stats, 1).throughput = 80
  rcRetryStep(stats, 2).rateIdx = 2
  rcRateStats(stats, 3).retryCount = if first: 10 else: 0
  durations = [300'u32, 200, 400, 100, 1, 1, 1, 1, 1, 1]
  throughputs[3] = 0x12345678
  rcU8(stats, 174) = 1
  rcPrngState = (3'u32 shl 16) - 0x3039'u32
  rcPrngState *= prngInverse
  rc_check(0)
  doAssert rcTrialControl(stats).status == 2 and rcTrialControl(stats).sampleWait == 24
  doAssert sta.txPolicyUpdateFlags[0] == 1
  doAssert rcTrialBackup(stats).rateIdx == 1 and rcTrialBackup(stats).throughput == 80
  let target = if first: 0 else: 1
  doAssert rcRetryStep(stats, target).rateIdx == 3
  doAssert rcRetryStep(stats, target).throughput == 0x12345678
  rc_update_counters(0, 1, 0, false, false)
  doAssert interruptsEnabled
  doAssert rcTrialControl(stats).status == 2, "confirmation preceded policy consumption"
  sta.txPolicyUpdateFlags[0] = 0
  rc_update_counters(0, 1, 0, false, false)
  doAssert interruptsEnabled
  doAssert rcTrialControl(stats).status == 3
  timeReads = 0
  let beforeRestorePrng = rcPrngState
  rc_check(0)
  doAssert rcPrngState == beforeRestorePrng
  doAssert rcTrialControl(stats).status == 0
  doAssert rcRetryStep(stats, 0).rateIdx == 0 and rcRetryStep(stats, 0).throughput == 100
  doAssert rcRetryStep(stats, 1).rateIdx == 1 and rcRetryStep(stats, 1).throughput == 80
  doAssert rcTrialBackup(stats).rateIdx == 255 and rcTrialBackup(stats).throughput == 0
  doAssert sta.txPolicyUpdateFlags[0] == 1 and errors == 0
"""


def model(state: bytearray, durations: list[int], throughputs: list[int], nss: list[int],
          times: tuple[int, int], seed: int, update: int, policy: int, sta: int) -> tuple[int, int, int, int]:
    u16 = lambda at: struct.unpack_from("<H", state, at)[0]
    u32 = lambda at: struct.unpack_from("<I", state, at)[0]
    put16 = lambda at, value: struct.pack_into("<H", state, at, value)
    put32 = lambda at, value: struct.pack_into("<I", state, at, value)
    calls, reads = 0, 0

    def trace(kind: int, value: int) -> None:
        nonlocal calls
        calls = ((calls * 16777619) & MASK) ^ ((kind << 16) | value)

    def duration(index: int) -> int:
        trace(5, u16(10 + index * 12))
        return durations[index]

    def streams(index: int) -> int:
        trace(6, u16(10 + index * 12))
        return nss[index]

    def step_copy(dst: int, src: int) -> None:
        put32(dst, u32(src))
        put16(dst + 4, u16(src + 4))

    trace(1, sta)
    trace(3, 0)
    reads = 1
    changed = False
    if (100000 - times[0] + u32(0)) & 0x80000000:
        trace(4, 0)
        state[175] ^= 0xD3
        state[174] = 0
        state[176] = 0
        state[175] &= ~0x10
        trace(3, 1)
        reads = 2
        put32(0, times[1])
        changed = bool(update)
    stage = state[174]
    if stage == 3:
        if not state[175] & 2:
            step_copy(124, 132)
        step_copy(132, 156)
        state[174] = 0
        put32(156, 0)
        put16(160, 255)
        changed = True
    elif stage == 1:
        if state[175] & 0x40:
            state[174] = 0
        else:
            fmt = state[177]
            best, second, third = (u16(offset) for offset in (128, 136, 144))
            if fmt <= 1:
                adjusted = (u16(8 + best * 12) - 0x1999) & 65535
                state[172] = 10 if adjusted <= 0xD99A else 5
            else:
                state[172] = ((u16(170) + 8) * 2) & 255
            seed = (seed * 0x41C64E6D + 0x3039) & MASK
            sample = (seed >> 16) % u16(192)
            if sample in (best, second, third) or u16(8 + sample * 12) > 0xF333:
                state[174] = 0
            else:
                sample_duration = duration(sample)
                skipped = state[12 + sample * 12]
                score, front, accepted = 0, False, True
                if fmt <= 1:
                    best_duration = duration(best)
                    front = sample_duration > best_duration and skipped >= 20
                else:
                    second_duration = duration(second)
                    minimum_skips = 32 if state[13 + sample * 12] else u16(170)
                    fast = sample_duration < second_duration
                    if not fast:
                        best_nss, sample_nss = streams(best), streams(sample)
                        if ((best_nss - 1) & MASK) >= sample_nss:
                            fast = sample_duration < duration(third)
                    if not fast:
                        if skipped < minimum_skips:
                            accepted = False
                        else:
                            state[173] = (state[173] + 1) & 255
                            accepted = state[173] <= 2
                            if state[173] > 15:
                                state[173] = 15
                    if accepted:
                        trace(7, sample)
                        score = throughputs[sample]
                        front = (state[14 + sample * 12] & 15) > 9 or skipped >= minimum_skips
                if accepted:
                    step_copy(156, 132)
                    if front:
                        state[175] &= ~2
                        step_copy(132, 124)
                        put16(128, sample)
                        put32(124, score)
                    else:
                        state[175] |= 2
                        put16(136, sample)
                        put32(132, score)
                    state[174] = 2
                    changed = True
                else:
                    state[174] = 0
    return seed, policy | int(changed), reads, calls


def vectors() -> bytes:
    rng = random.Random(0x808771A1)
    output = bytearray()

    def append_case(state: bytearray, duration_values: list[int], tp_values: list[int], streams: list[int],
                    times: tuple[int, int], seed: int, update: int, policy: int, sta: int) -> None:
        output.extend(state + struct.pack("<10I10I10B3I4B", *duration_values, *tp_values, *streams,
                                          *times, seed, update, policy, sta, 0))
        seed, policy, reads, calls = model(state, duration_values, tp_values, streams, times, seed, update, policy, sta)
        output.extend(state + struct.pack("<IBBI", seed, policy, reads, calls))

    for count in range(1, 11):
        for iteration in range(800):
            state = bytearray(rng.randbytes(200))
            struct.pack_into("<H", state, 192, count)
            for i in range(10):
                struct.pack_into("<H", state, 10 + i * 12, 0x1000 + i)
                struct.pack_into("<H", state, 8 + i * 12, rng.choice([0, 0x1998, 0x1999, 0xF332, 0xF333, 0xF334, 65535]))
                state[12 + i * 12] = rng.choice([0, 1, 19, 20, 31, 32, 33, 255])
                state[13 + i * 12] = rng.randrange(2)
                state[14 + i * 12] = rng.choice([0, 9, 10, 15, 0xA1])
            for at in (128, 136, 144, 152, 160):
                struct.pack_into("<H", state, at, rng.randrange(count))
            state[174] = rng.choice([0, 1, 1, 1, 2, 3, 255])
            state[175] = rng.randrange(256)
            state[177] = rng.choice([0, 1, 2, 3])
            state[173] = rng.choice([0, 1, 2, 14, 15, 16, 254, 255])
            struct.pack_into("<H", state, 170, rng.choice([0, 1, 4, 31, 120, 255, 65535]))
            now = rng.getrandbits(32)
            elapsed = rng.choice([0, 0, 0, 99999, 100000, 100001, 0x7FFFFFFF, MASK])
            struct.pack_into("<I", state, 0, (now - elapsed) & MASK)
            times = (now, (now + rng.randrange(1000)) & MASK)
            duration_values = [rng.choice([1, 10, 100, 200, 100000]) for _ in range(10)]
            tp_values = [rng.getrandbits(32) for _ in range(10)]
            streams = [rng.randrange(4) for _ in range(10)]
            seed, update, policy, sta = rng.getrandbits(32), rng.randrange(2), rng.randrange(256), rng.randrange(5)
            append_case(state, duration_values, tp_values, streams, times, seed, update, policy, sta)
    seed = ((3 << 16) - 0x3039) * pow(0x41C64E6D, -1, 1 << 32) & MASK
    for fmt in (0, 1, 2, 3):
        for skipped in (0, 19, 20, 31, 32, 255):
            for retry in (9, 10):
                for best_nss in range(4):
                    for sample_nss in range(4):
                        for first, second, third in ((50, 200, 200), (100, 100, 200), (200, 50, 50)):
                            for old in (0, 1):
                                for slow in (1, 2, 15, 255):
                                    state = bytearray(200)
                                    struct.pack_into("<H", state, 192, 4)
                                    struct.pack_into("<H", state, 170, 4)
                                    state[173:178] = bytes([slow, 1, 0, 0, fmt])
                                    for i in range(4):
                                        struct.pack_into("<H", state, 10 + i * 12, 0x1000 + i)
                                    for offset, index in ((128, 0), (136, 1), (144, 2), (152, 0), (160, 1)):
                                        struct.pack_into("<H", state, offset, index)
                                    state[48:51] = bytes([skipped, old, retry])
                                    append_case(state, [first, second, third, 100] + [1] * 6,
                                                [0, 0, 0, 0xFEDCBA98] + [0] * 6,
                                                [best_nss, 0, 0, sample_nss] + [0] * 6,
                                                (0, 0), seed, 0, 0, 0)
    return bytes(output)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("scenario", ["vectors", "sequence"])
def test_rate_trial(mode: str, scenario: str, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    layout = (FW / "layout_types.nim").read_text()
    helpers = (FW / "runtime_helpers.nim").read_text()
    source = (FW / "rate_control.nim").read_text()
    code = layout.split("# Linked list node", 1)[0] + PLATFORM
    code += "\ntype\n  RcRateEntryView" + layout.split("  RcRateEntryView", 1)[1].split("  TxFrameEnvView", 1)[0]
    code += "\ntemplate rcRateEntryAt" + helpers.split("template rcRateEntryAt", 1)[1].split("proc rcClearRateEntryTransientStats", 1)[0]
    if "proc rc_install_trial(" in source:
        code += procedure(source, "rc_install_trial")
    code += procedure(source, "rc_check")
    if scenario == "vectors":
        vector_path = tmp_path / "vectors.bin"
        vector_path.write_bytes(vectors())
        code += f'\nconst vectorPath = "{vector_path}"\n' + HARNESS
    else:
        code += procedure(source, "rc_update_counters")
        code += f"\nconst prngInverse = {pow(0x41C64E6D, -1, 1 << 32)}'u32\n" + SEQUENCE
    path = tmp_path / "rate_trial.nim"
    path.write_text(code)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    command += ["--checks:on"] if mode == "checked" else ["-d:release", "--checks:off"]
    if mode == "asan":
        command += ["--passC:-fsanitize=address", "--passC:-fno-omit-frame-pointer", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(path)], cwd=ROOT, text=True,
                            env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0"},
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
