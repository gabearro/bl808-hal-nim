"""Check beacon deadlines against the vendor's register-level calculation."""

from pathlib import Path

import pytest

from test_wifi_beacon_probe_policy import source as probe_source
from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program


MASK32 = (1 << 32) - 1
MASK64 = (1 << 64) - 1


def deadline(tsf: int, received: int, interval: int, count: int, drift: int,
             full_duration: int, header_duration: int, clock: int,
             pre_duration: int, access_time: int) -> int:
    ticks = interval << 10
    aligned = (tsf // ticks) * ticks
    anchor = min(aligned, (tsf - header_duration) & MASK64)
    elapsed = (tsf - received + ((full_duration - header_duration) & MASK32)) & MASK64
    next_target = (anchor + ((ticks * count) & MASK32)) & MASK64
    return (clock - 400 - pre_duration - access_time - drift * count
            + next_target - elapsed) & MASK32


def source() -> str:
    code = probe_source()
    code = code.replace("frameStorage: array[36, uint8]", "frameStorage: array[64, uint8]")
    code = code.replace("var\n  mm:", "var\n  descriptorAccess, fullDuration, headerDuration: uint32\n  timerSets: int\n  durationLengths: seq[uint32]\n  mm:")
    code = code.replace(procedure(code, "volatileLoad"), r'''
proc volatileLoad(p: ptr uint32): uint32 =
  if cast[uint](p) == 0x24B080A4'u: descriptorAccess else: clock
''', 1)
    code = code.replace(procedure(code, "hal_machw_rx_duration"), r'''
proc hal_machw_rx_duration(p: pointer; length: uint32): uint32 =
  doAssert p == addr rx
  durationLengths.add(length)
  if length == 24: headerDuration else: fullDuration
''', 1)
    code = code.replace(procedure(code, "mm_timer_set"), r'''
proc mm_timer_set(p: pointer; expiry: uint32) =
  doAssert p == addr vif.tbttTimer
  inc timerSets
  cast[ptr Timer](p).expiry = expiry
''', 1)
    return code + r'''
proc prepare(tsf, received: uint64; interval, listen, drift: uint16;
             full, header, now, pre, access: uint32; count = -1; period = 0) =
  setup()
  frame.tsfLow = tsf.uint32
  frame.tsfHigh = (tsf shr 32).uint32
  frame.beaconInterval = interval
  rx.timestampLow = received.uint32
  rx.timestampHigh = (received shr 32).uint32
  vif.listenInterval = listen
  sta.listenWindowDuration = drift
  sta.beaconTimeOffset = 0x76543210
  mm.tbttPreDuration = pre
  fullDuration = full
  headerDuration = header
  clock = now
  descriptorAccess = access
  timerSets = 0
  durationLengths.setLen(0)
  if count >= 0:
    frameStorage[36] = 5
    frameStorage[37] = 4
    frameStorage[38] = count.uint8
    frameStorage[39] = period.uint8
    frameStorage[40] = 0
    frameStorage[41] = 1
    rx.frameLen = 42
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_countdown_and_drift_sources(tmp_path: Path, mode: str) -> None:
    checks = ""
    for listen, count, period, effective in [(4, 2, 5, 4), (0, 2, 5, 2),
                                             (0, 0, 5, 5), (0, -1, 0, 1),
                                             (0, 0, 0, 0)]:
        expected = deadline(234567, 231000, 100, effective, 9, 320, 48,
                            240000, 4000, 57)
        checks += f'''
prepare(234567, 231000, 100, {listen}, 9, 320, 48, 240000, 4000, 57,
        {count}, {period})
process()
doAssert vif.tbttTimer.expiry == {expected}'u32
doAssert durationLengths == @[rx.frameLen.uint32, 24'u32]
doAssert timerSets == 1
'''
    run_program(tmp_path, mode, source() + checks)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tsf_alignment_receive_timestamps_and_wrap(tmp_path: Path, mode: str) -> None:
    vectors = [
        (204800 + phase, 202100, 100, 3, 7, 340, 48, 250000, 4000, 61)
        for phase in (0, 47, 48, 49, 900)
    ] + [
        ((1 << 40) + 334455, (1 << 40) + 330001, 100, 2, 11,
         400, 64, 0xFFFFF000, 4000, 73),
        (MASK64 - 117, MASK64 - 1517, 65535, 65535, 65535,
         300, 44, 3000, 7000, 79),
        (12, MASK64 - 200, 1, 1, 3, 280, 48, 1000, 17, 1),
        ((1 << 32) + 20, (1 << 32) - 1100, 100, 1, 9,
         256, 40, 0xFFFFFFF0, 4000, 83),
    ]
    checks = ""
    for values in vectors:
        tsf, received, interval, count, drift, full, header, clock, pre, access = values
        expected = deadline(*values)
        checks += f'''
prepare({tsf}'u64, {received}'u64, {interval}, {count}, {drift},
        {full}, {header}, {clock}'u32, {pre}, {access})
process()
doAssert vif.tbttTimer.expiry == {expected}'u32
'''
    run_program(tmp_path, mode, source() + checks)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_unchanged_deadline_does_not_rearm_timer(tmp_path: Path, mode: str) -> None:
    expected = deadline(234567, 231000, 100, 3, 9, 320, 48, 240000, 4000, 57)
    run_program(tmp_path, mode, source() + f'''
prepare(234567, 231000, 100, 3, 9, 320, 48, 240000, 4000, 57)
vif.tbttTimer.expiry = {expected}'u32
process()
doAssert timerSets == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_incomplete_or_zero_interval_beacon_does_not_schedule(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for length in [0'u16, 24, 32, 35, 36]:
  prepare(234567, 231000, 100, 3, 9, 320, 48, 240000, 4000, 57)
  rx.frameLen = length
  if length == 36: frame.beaconInterval = 0
  mm.flagsHigh = 1
  clock = 40_000_000
  let before = vif
  let beforeMm = mm
  process()
  doAssert timerSets == 0 and durationLengths.len == 0
  doAssert sends == 0 and losses == 0
  doAssert vif == before and mm == beforeMm
''')
