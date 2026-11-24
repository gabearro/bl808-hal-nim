"""Exercise the BL808 MAC-timer delay with scripted register reads."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_bl808_calibration_wait(tmp_path: Path, mode: str) -> None:
    body = RF.with_name("rf_bl808_calibration_delay.nim").read_text()
    run_program(tmp_path, mode, r'''
const MACHW_TIMLO_REG = 0x24B00120'u
var
  clockValues: seq[uint32]
  timerReads, spins, decrements: int
  spinSeed: uint32 = 32
  expectSeed = true
  fallback: seq[uint32]

proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  doAssert expectSeed and spins == timerReads and decrements == (spinSeed.int + 1) * spins
  result = clockValues[min(timerReads, clockValues.high)]
  inc timerReads

proc volatileLoad(p: ptr uint32): uint32 =
  doAssert not expectSeed
  doAssert p[] == spinSeed - (decrements mod (spinSeed.int + 1)).uint32
  inc decrements
  p[]

proc volatileStore(p: ptr uint32; value: uint32) =
  if expectSeed:
    doAssert value == spinSeed and decrements == spins * (spinSeed.int + 1)
    inc spins
    expectSeed = false
  else:
    doAssert value == p[] - 1'u32
    expectSeed = p[] == 0'u32
  p[] = value

proc waitRfUs(us: uint32) = fallback.add(us)
''' + body + r'''
proc check(us: uint32; values: seq[uint32]; polls: int; stuck = false) =
  clockValues = values
  timerReads = 0
  spins = 0
  decrements = 0
  fallback.setLen(0)
  let prior = nimFwDbgRfCalDelayFallbacks
  waitBl808RfCalUs(us)
  doAssert timerReads == polls + 1 and spins == polls and decrements == 33 * polls
  doAssert fallback == (if stuck: @[us] else: @[])
  doAssert nimFwDbgRfCalDelayFallbacks == prior + stuck.uint32

check(0, @[100'u32, 100], 1)
check(1, @[100'u32, 102], 1)
check(10, @[100'u32, 103, 109, 110], 3)
check(10, @[0xFFFFFFFC'u32, 0xFFFFFFFF'u32, 0, 5, 6], 4)
check(50, @[100'u32, 99, 105, 110], Bl808RfCalDelayPollLimit, true)
check(100, @[100'u32], Bl808RfCalDelayPollLimit, true)

# The RFC countdown never reads the MAC timer. Seed zero still decrements once.
for (us, seed) in [(0'u32, 0'u32), (1'u32, 16'u32), (20'u32, 320'u32), (100'u32, 1600'u32)]:
  spinSeed = seed
  timerReads = 0
  spins = 0
  decrements = 0
  fallback.setLen(0)
  waitBl808RfcUs(us)
  doAssert expectSeed and timerReads == 0 and spins == 1
  doAssert decrements == seed.int + 1 and fallback.len == 0
''')
