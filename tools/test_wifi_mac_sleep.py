"""Check MAC sleep timer eligibility against the vendor branch/read sequence."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type
  Read = tuple[address: uint, value: uint32]
  Assertion = tuple[condition, file: string, line: cint]
var
  active: uint32
  timers: array[10, seq[uint32]]
  timerReads: array[10, int]
  times: seq[uint32]
  timeReads: int
  reads: seq[Read]
  assertions: seq[Assertion]
proc regRead(address: uint): uint32 =
  if address == MACHW_INTC_BASE + 0x8C:
    result = active
  elif address == MACHW_TIMLO_REG:
    doAssert times.len != 0
    result = times[min(timeReads, times.high)]
    inc timeReads
  else:
    doAssert address >= MACHW_BASE + 0x128 and address < MACHW_BASE + 0x150
    doAssert (address and 3) == 0
    let index = ((address - MACHW_BASE - 0x128) div 4).int
    doAssert timers[index].len != 0
    result = timers[index][min(timerReads[index], timers[index].high)]
    inc timerReads[index]
  reads.add((address, result))
proc assert_err(condition, file: cstring; line: cint) =
  assertions.add(($condition, $file, line))
proc setup(mask: uint32) =
  active = mask
  timers = default(typeof(timers))
  for index in 0 ..< timers.len: timers[index] = @[2000'u32]
  timerReads = default(typeof(timerReads))
  times = @[0'u32]
  timeReads = 0
  reads.setLen(0)
  assertions.setLen(0)
proc timerAddress(index: int): uint = MACHW_BASE + 0x128 + index.uint * 4
proc timestamp(base: uint32; delta: int64): uint32 =
  ((base.int64 + delta) and 0xFFFFFFFF'i64).uint32
proc negativeDifference(deadline, now: uint32; offset: int64): bool =
  ((deadline.int64 - now.int64 + offset) and 0x80000000'i64) != 0
proc checkAssertion(expected: bool) =
  if expected:
    doAssert assertions == @[(
      "!hal_machw_time_past(blmac_abs_timer_get(i) + 5000)",
      "hal_machw.c", 595.cint)]
  else:
    doAssert assertions.len == 0
'''


def source() -> str:
    registers = (FW / "register_constants.nim").read_text().split("  # MAC platform registers", 1)[0]
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    return registers + PLATFORM + procedure(kernel, "hal_machw_sleep_check")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_near_deadline_vetoes_sleep(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for index in 0 .. 8:
  for ahead in [0'i64, 1, 1999]:
    setup(1'u32 shl index)
    times = @[1000'u32, 1000'u32]
    timers[index] = @[timestamp(1000, ahead), timestamp(1000, ahead)]
    doAssert not hal_machw_sleep_check()
    checkAssertion(false)
    doAssert timerReads[index] == 2 and timeReads == 2
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_only_nine_timer_bits_are_considered(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for mask in [0'u32, 0x200'u32, 0xFFFFFE00'u32]:
  setup(mask)
  timers[9] = @[0'u32]
  doAssert hal_machw_sleep_check()
  doAssert reads == @[(MACHW_INTC_BASE + 0x8C, mask)]
  doAssert timeReads == 0
  for count in timerReads: doAssert count == 0
  checkAssertion(false)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_deadline_boundaries_and_timestamp_wrap(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for now in [0'u32, 1, 0x7FFFFFFF'u32, 0x80000000'u32, 0xFFFFFFFE'u32, 0xFFFFFFFF'u32]:
  for delta in [-2147483648'i64, -2147481649'i64, -5001'i64, -5000'i64,
                -4999'i64, -1'i64, 0'i64, 1999'i64, 2000'i64, 2001'i64,
                2147483647'i64, 2147485648'i64]:
    for index in 0 .. 8:
      setup(1'u32 shl index)
      let deadline = timestamp(now, delta)
      timers[index] = @[deadline, deadline]
      times = @[now, now]
      let veto = negativeDifference(deadline, now, -2000)
      doAssert hal_machw_sleep_check() == not veto
      checkAssertion(veto and negativeDifference(deadline, now, 5000))
      let count = if veto: 2 else: 1
      doAssert timerReads[index] == count and timeReads == count
      var expected: seq[Read] = @[(MACHW_INTC_BASE + 0x8C, active)]
      for read in 0 ..< count:
        expected.add((timerAddress(index), deadline))
        expected.add((MACHW_TIMLO_REG, now))
      doAssert reads == expected
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_each_timer_uses_a_fresh_mac_time(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(0x1FF)
times.setLen(0)
var expected: seq[Read] = @[(MACHW_INTC_BASE + 0x8C, active)]
for index in 0 .. 8:
  let now = timestamp(0xFFFFF000'u32, index.int64 * 1000)
  let deadline = timestamp(now, 2000)
  times.add(now)
  timers[index] = @[deadline]
  expected.add((timerAddress(index), deadline))
  expected.add((MACHW_TIMLO_REG, now))
doAssert hal_machw_sleep_check()
doAssert reads == expected and timeReads == 9
for index in 0 .. 8: doAssert timerReads[index] == 1
checkAssertion(false)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_secondary_check_rereads_and_stops_scanning(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for index in 0 .. 8:
  for late in [false, true]:
    setup(0x1FF)
    times.setLen(0)
    var expected: seq[Read] = @[(MACHW_INTC_BASE + 0x8C, active)]
    for earlier in 0 ..< index:
      timers[earlier] = @[12000'u32]
      times.add(10000)
      expected.add((timerAddress(earlier), 12000'u32))
      expected.add((MACHW_TIMLO_REG, 10000'u32))
    timers[index] = @[10001'u32, if late: 100'u32 else: 100000'u32]
    times.add(10000)
    times.add(20000)
    expected.add((timerAddress(index), 10001'u32))
    expected.add((MACHW_TIMLO_REG, 10000'u32))
    expected.add((timerAddress(index), timers[index][1]))
    expected.add((MACHW_TIMLO_REG, 20000'u32))
    doAssert not hal_machw_sleep_check()
    doAssert reads == expected
    checkAssertion(late)
    for later in index + 1 .. 9: doAssert timerReads[later] == 0
''')
