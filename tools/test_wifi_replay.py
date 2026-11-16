"""Legacy-vendor boundary vectors for RX replay; wide jumps have separate tests."""

from pathlib import Path
import random
import re
import shutil
import struct
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
MASK32 = (1 << 32) - 1
MASK64 = (1 << 64) - 1
RECORD = struct.Struct("<4IQI4I")


def vendor_window(state: tuple[int, int, int, int], received: int):
    """Reference translation of replay_counter.o, offsets 0x00 through 0x84.

    ADD64 wraps at 64 bits. WEXTI(..., 5) extracts bits 36..5;
    the final SLL uses the low five bits of the incremented packet number.
    """
    low, high, bitmap0, bitmap1 = state
    last = low | (high << 32)
    if ((received + 33) & MASK64) < last:
        return False, state
    next_pn = (received + 1) & MASK64
    index = (next_pn >> 5) & MASK32
    bits = [bitmap0, bitmap1]
    if next_pn > last:
        old_index = (last >> 5) & MASK32
        # The disassembly clears at most two banks when advancing blocks.
        count = min(2, (index - old_index) & MASK32)
        for step in range(1, count + 1):
            bits[(old_index + step) & 1] = 0
        low, high = next_pn & MASK32, next_pn >> 32
    bank = index & 1
    bit = 1 << (next_pn & 31)
    if bits[bank] & bit:
        return False, (low, high, *bits)
    bits[bank] |= bit
    return True, (low, high, *bits)


def replay_vectors() -> bytes:
    rng = random.Random(0x8083216)
    records = bytearray()

    def add(state, received):
        accepted, result = vendor_window(state, received)
        records.extend(RECORD.pack(*state, received, accepted, *result))
        return accepted, result

    # Explicit block, comparison, carry, and 32-bit block-index wrap edges.
    for last in [0, 1, 30, 31, 32, 33, 63, 64, 65, (1 << 32) - 1,
                 1 << 32, (1 << 37) - 1, 1 << 37, (1 << 48) - 1, MASK64]:
        for delta in [-80, -64, -34, -33, -32, -31, -1, 0, 1, 2, 31, 32, 33, 64]:
            received = (last + delta) & MASK64
            for bits in [(0, 0), (MASK32, MASK32), (0xAAAAAAAA, 0x55555555),
                         (rng.getrandbits(32), rng.getrandbits(32))]:
                add((last & MASK32, last >> 32, *bits), received)

    for _ in range(6000):
        last = rng.getrandbits(64)
        received = (last + rng.randint(-200, 200)) & MASK64
        add((last & MASK32, last >> 32, rng.getrandbits(32), rng.getrandbits(32)),
            received)

    # A set-based oracle independently checks acceptance on valid streams.
    # It knows nothing about the two bitmap banks or their storage layout.
    for start in [0, (1 << 32) - 64, (1 << 37) - 64, (1 << 48) - 100000]:
        state = (start & MASK32, start >> 32, 0, 0)
        highest = start - 1
        seen = set()
        for _ in range(10000):
            if seen and rng.randrange(5) == 0:
                received = rng.choice(tuple(seen))
            else:
                received = max(0, highest + rng.randint(-80, 100))
            expected = received >= highest - 32 and received not in seen
            accepted, state = add(state, received)
            assert accepted == expected
            if accepted:
                highest = max(highest, received)
                seen.add(received)
    return bytes(records)


HARNESS = r"""
import std/os

const RxuMgmtPnTid = 8'u8
type RxEnv = object
  secInfo0, secInfo1: uint32
  secFlags: uint8
var env: RxEnv
proc rxuCntrlEnvView(): ptr RxEnv = addr env
proc rxMgtReplayCounter(key: pointer): ptr KeyReplayCounterView = nil

proc read32(data: string; at: int): uint32 =
  for i in 0 ..< 4:
    result = result or (data[at + i].uint32 shl (8 * i))

proc readState(data: string; at: int): ReplayCounterStateView =
  result.pnLow = read32(data, at)
  result.pnHigh = read32(data, at + 4)
  result.bitmap[0] = read32(data, at + 8)
  result.bitmap[1] = read32(data, at + 12)

proc runChecks() =
  static:
    doAssert sizeof(ReplayCounterStateView) == 16
    doAssert sizeof(KeyReplayCounterView) == 16
    doAssert offsetof(KeyReplayCounterView, bitmap) == 8
    doAssert sizeof(VifKeySlotView) == 160
  let data = readFile(paramStr(1))
  doAssert data.len mod 44 == 0
  for record in 0 ..< data.len div 44:
    let at = record * 44
    let initial = readState(data, at)
    let received = read32(data, at + 16).uint64 or
      (read32(data, at + 20).uint64 shl 32)
    let expected = readState(data, at + 28)
    let expectedResult = read32(data, at + 24) != 0
    var guarded: array[48, uint8]
    for value in guarded.mitems: value = 0xA5
    let state = cast[ptr ReplayCounterStateView](addr guarded[16])
    state[] = initial
    doAssert replay_counter_validate(state, received) == expectedResult,
      "decision at vector " & $record
    doAssert state[] == expected, "state at vector " & $record
    for i in 0 ..< 16:
      doAssert guarded[i] == 0xA5 and guarded[i + 32] == 0xA5,
        "replay state overrun"

    # Route the same cases through the real RX caller and protect all other
    # per-TID counters, TX PN, and key bytes against accidental writes.
    if record < 2000:
      # Physical-key management counters have a separate lifecycle suite.
      for tid in 0'u8 .. 7'u8:
        let selected = tid.int
        var keyBytes: array[192, uint8]
        for value in keyBytes.mitems: value = 0xA5
        let key = cast[ptr VifKeySlotView](addr keyBytes[16])
        key.hasRxPn = 1
        key.replayCounters[selected] = initial
        var expectedBytes = keyBytes
        cast[ptr VifKeySlotView](addr expectedBytes[16]).replayCounters[selected] = expected
        env.secInfo0 = (received and 0xFFFFFFFF'u64).uint32
        env.secInfo1 = (received shr 32).uint32
        if tid < 8:
          let before = keyBytes
          doAssert rxuPnFresh(key, tid) == expectedResult
          doAssert keyBytes == before, "replay preview mutated key state"
        doAssert (rxu_cntrl_check_pn(key, tid) != 0) == expectedResult
        doAssert keyBytes == expectedBytes, "RX window modified another TID or key"

  # Strict mode has no bitmap updates and no reordering allowance.
  for tid in 0'u8 .. 7'u8:
    for last in [0'u64, 1, 0xFFFFFFFE'u64, 0xFFFFFFFF'u64, 0x100000000'u64, 0xFFFFFFFFFFFF'u64]:
      for received in [0'u64, 1, last, last + 1, 0xFFFFFFFF'u64, 0x100000000'u64]:
        var keyBytes: array[192, uint8]
        for value in keyBytes.mitems: value = 0xA5
        let key = cast[ptr VifKeySlotView](addr keyBytes[16])
        key.hasRxPn = 0
        key.replayCounters[tid].pnLow = (last and 0xFFFFFFFF'u64).uint32
        key.replayCounters[tid].pnHigh = (last shr 32).uint32
        var expectedBytes = keyBytes
        let accepted = received + 1 > last
        if accepted:
          let target = cast[ptr VifKeySlotView](addr expectedBytes[16])
          target.replayCounters[tid].pnLow = ((received + 1) and 0xFFFFFFFF'u64).uint32
          target.replayCounters[tid].pnHigh = ((received + 1) shr 32).uint32
        env.secInfo0 = (received and 0xFFFFFFFF'u64).uint32
        env.secInfo1 = (received shr 32).uint32
        let before = keyBytes
        doAssert rxuPnFresh(key, tid) == accepted
        doAssert keyBytes == before, "strict replay preview mutated key state"
        doAssert (rxu_cntrl_check_pn(key, tid) != 0) == accepted
        doAssert keyBytes == expectedBytes, "strict RX modified bitmap or another key"
"""


def test_rx_replay_window(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    base = ROOT / "src/bl808/wifi/fw"
    layout = (base / "layout_types.nim").read_text()
    rx = (base / "rx_upper.nim").read_text()
    mac = (base / "mac_config_debug.nim").read_text()
    types = "  KeyReplayCounterView" + layout.split(
        "  KeyReplayCounterView", 1
    )[1].split("\n  RxMicWordsView", 1)[0]
    accessor = "template replayCounterStateView" + layout.split(
        "template replayCounterStateView", 1
    )[1].split("\ntemplate ", 1)[0]
    validate = "proc replay_counter_validate*" + mac.split(
        "proc replay_counter_validate*", 1
    )[1].split("\n# ################################################################", 1)[0]
    rx_check = "proc rxu_cntrl_check_pn*" + rx.split(
        "proc rxu_cntrl_check_pn*", 1
    )[1].split("\nproc rxuStripPayloadPrefix", 1)[0]
    debug_vars = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", rx_check)))
    )
    preamble, checks = HARNESS.split("proc runChecks()", 1)
    source = tmp_path / "replay_test.nim"
    source.write_text("type\n" + types + "\n" + preamble + debug_vars + accessor
                      + "\n" + validate + "\n" + rx_check + "\nproc runChecks()"
                      + checks + "\nrunChecks()\n")
    vectors = tmp_path / "vectors.bin"
    vectors.write_bytes(replay_vectors())
    executable = tmp_path / "replay_test"
    result = subprocess.run(
        [nim, "c", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{executable}",
         str(source)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout
    result = subprocess.run([str(executable), str(vectors)], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
