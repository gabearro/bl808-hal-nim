"""Check the separate calibration-restore and initialization power phases."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, source
from test_wifi_rf_power_scope import CHECKS


def lifecycle_source() -> str:
    rf = RF.read_text()
    code = source(real_io=True) + CHECKS + r'''
var rxcalReplays: int
const RfCalibRccalReplayWordIndex = 2
proc rfPriSnapshotStage(tag: uint32) = discard
proc rfPriReplayRxcalRegs() = inc rxcalReplays
'''
    if "proc writeRfPriGainInit(" in rf:
        code += procedure(rf, "writeRfPriGainInit")
    if "proc rfCalibHasRestoreData(" in rf:
        code += procedure(rf, "rfCalibHasRestoreData")
    code += procedure(rf, "replayRfPriCalRegisters")
    code += procedure(rf, "rf_pri_restore_cal_reg")
    init = procedure(rf, "rf_pri_init")
    start = "  writeRfPriGainInit()" if "  writeRfPriGainInit()" in init else (
        "  rfPriSnapshotStage(0xF407'u32)"
    )
    followup = init[init.index(start):].split("  rfPriSnapshotStage(0xF408'u32)", 1)[0]
    code += "proc initializationPowerFollowup() =\n" + followup
    return code + r'''
proc expectedCalibration(initial: array[43, uint32]): array[43, uint32] =
  result = initial
  for slot, index in bl808RfTxPowerTableIndex:
    applyExpectedCal(result, 3 + slot * 2, 0x68 + index.int * 8)
  for slot, index in bl808RfBzTargetPowerRecords:
    applyExpectedCal(result, 35 + slot * 2, 0xF8 + index * 8)
proc expectedPhaseTrace(words: array[43, uint32]; calibrationPhase: bool):
    seq[tuple[index: int, value: uint32]] =
  if calibrationPhase:
    for slot in 0 ..< 13:
      let a = 3 + slot * 2
      result.add((a, words[a])); result.add((a + 1, words[a + 1]))
    for slot in 0 ..< 4:
      let a = 35 + slot * 2
      result.add((a, words[a])); result.add((a + 1, words[a + 1]))
  else:
    for i in countdown(2, 0): result.add((i, words[i]))
    for slot in countdown(12, 0):
      let a = 3 + slot * 2
      result.add((a + 1, words[a + 1])); result.add((a, words[a]))
    result.add((34, words[34]))
    for slot in 0 ..< 4:
      let a = 35 + slot * 2
      result.add((a, words[a])); result.add((a + 1, words[a + 1]))
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_calibration_restore_does_not_reprogram_power_fields(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, lifecycle_source() + r'''
for vector in 0 ..< 200:
  setup()
  seedHardware()
  fillCalibration()
  if vector mod 2 != 0:
    calibration[26] = 0; calibration[27] = 0
  let initial = hardware.txPowerCompWords700
  let expected = expectedCalibration(initial)
  rf_pri_restore_cal_reg()
  doAssert hardware.txPowerCompWords700 == expected,
    "calibration restore replaced live power or unowned fields"
  doAssert registerWrites == expectedPhaseTrace(expected, true),
    "calibration restore issued power stores or reordered the domains"
  doAssert rxcalReplays == vector + 1
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_initialization_followup_does_not_replay_calibration(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, lifecycle_source() + r'''
for vector in 0 ..< 200:
  setup()
  seedHardware()
  if vector mod 2 != 0: fillCalibration()
  wb03 = vector mod 4 >= 2
  bl808WifiRfWb03ReplayCompleteTxPowerCal = vector mod 8 >= 4
  let initial = hardware.txPowerCompWords700
  let expected = expectedPower(initial)
  initializationPowerFollowup()
  doAssert hardware.txPowerCompWords700 == expected,
    "initialization power follow-up replaced restored calibration or unowned fields"
  doAssert registerWrites == expectedPhaseTrace(expected, false),
    "initialization follow-up issued calibration stores or reordered the domains"
  doAssert nim_wifi_rf_tx_power_replay_mode == RfPriTxPowerReplayBaseOnly
  doAssert nim_wifi_rf_tx_power_replay_skip_reason == RfPriTxPowerSkipNone
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_restore_without_storage_is_noop(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, lifecycle_source() + r'''
for vector in 0 ..< 100:
  setup()
  seedHardware()
  let before = hardware.txPowerCompWords700
  let beforeRf70 = rf70.txcalParam70
  rf_pri_restore_cal_reg()
  doAssert hardware.txPowerCompWords700 == before
  doAssert rf70.txcalParam70 == beforeRf70
  doAssert registerWrites.len == 0 and rxcalReplays == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_wb03_replay_is_calibration_only_and_power_stays_live(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, lifecycle_source() + r'''
for variant in 0 ..< 4:
  setup()
  seedHardware()
  fillCalibration()
  wb03 = true
  bl808WifiRfWb03ReplayCompleteTxPowerCal = variant != 0
  if variant == 2: calibration[26] = 0; calibration[27] = 0
  if variant == 3:
    calibration[(0xF8 + 6 * 8) div 4] = 0
    calibration[(0xFC + 6 * 8) div 4] = 0
  let before = hardware.txPowerCompWords700
  let cal = expectedCalibration(before)
  rf_pri_restore_cal_reg()
  doAssert hardware.txPowerCompWords700 == cal
  doAssert registerWrites == expectedPhaseTrace(cal, true)
  for delta in [-36'i16, -7, 0, 9, 24, 32767]:
    let prior = hardware.txPowerCompWords700
    registerWrites.setLen(0)
    rfPriApplyLowPowerRuntimeDelta(delta)
    let power = expectedPower(prior, bz = false)
    let final = expectedReplay(prior, bz = false)
    doAssert hardware.txPowerCompWords700 == final,
      "WB03 calibration replay replaced live compensated power rows"
    checkTrace(power, final, true, true)
    # Changed or absent calibration data cannot affect init's power phase.
    let live = hardware.txPowerCompWords700
    registerWrites.setLen(0)
    rfCalibDataGlobal = nil
    initializationPowerFollowup()
    let expected = expectedPower(live)
    doAssert hardware.txPowerCompWords700 == expected
    doAssert registerWrites == expectedPhaseTrace(expected, false)
    rfCalibDataGlobal = addr calibration[0]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_empty_or_invalid_replay_does_not_publish(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, lifecycle_source() + r'''
for board in [true, false]:
  for scope in [rfPowerAll, rfPowerWlan, rfPowerBz]:
    for phases in [{rfPowerFields}, {rfPowerCalibration},
                   {rfPowerFields, rfPowerCalibration}]:
      setup()
      seedHardware()
      fillCalibration()
      wb03 = board
      let before = hardware.txPowerCompWords700
      rfPriWriteTxPowerTable(scope, {})
      doAssert registerWrites.len == 0 and snapshots == 0
      if scope == rfPowerBz: bl808RfBzTargetPowerRecords[3] = -1
      else: bl808RfTxPowerTableIndex[12] = -1
      rfPriWriteTxPowerTable(scope, phases)
      doAssert hardware.txPowerCompWords700 == before
      doAssert registerWrites.len == 0 and snapshots == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_both_domain_replay_keeps_each_power_calibration_pair_ordered(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, lifecycle_source() + r'''
setup()
seedHardware()
fillCalibration()
let before = hardware.txPowerCompWords700
let wlanPower = expectedPower(before, bz = false)
let wlanCal = expectedReplay(before, bz = false)
let bzPower = expectedPower(wlanCal, wlan = false)
let final = expectedReplay(wlanCal, wlan = false)
var trace: seq[tuple[index: int, value: uint32]]
for event in expectedPhaseTrace(wlanPower, false):
  if event.index < 29: trace.add(event)
for event in expectedPhaseTrace(wlanCal, true):
  if event.index < 29: trace.add(event)
for event in expectedPhaseTrace(bzPower, false):
  if event.index >= 34: trace.add(event)
for event in expectedPhaseTrace(final, true):
  if event.index >= 34: trace.add(event)
rfPriWriteTxPowerTable()
doAssert hardware.txPowerCompWords700 == final
doAssert registerWrites == trace
''')
