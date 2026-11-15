"""Check the vendor's separate WLAN/BZ runtime register write boundaries."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import source


CHECKS = r'''
proc seedHardware() =
  for word in hardware.txPowerCompWords700.mitems: word = randomWord()
  rf70.txcalParam70 = randomWord()
  registerWrites.setLen(0)
  channelCompCalls = 0
proc fillCalibration() =
  for word in calibration.mitems: word = randomWord() or 0x01010101
  rfCalibDataGlobal = addr calibration[0]
proc checkTrace(power, final: array[43, uint32]; wlan, cal: bool) =
  var expected: seq[tuple[index: int, value: uint32]]
  if wlan:
    for i in countdown(2, 0): expected.add((i, power[i]))
    for slot in countdown(12, 0):
      let a = 3 + slot * 2
      expected.add((a + 1, power[a + 1]))
      expected.add((a, power[a]))
  else:
    expected.add((34, power[34]))
    for slot in 0 ..< 4:
      let a = 35 + slot * 2
      expected.add((a, power[a]))
      expected.add((a + 1, power[a + 1]))
  if cal:
    for slot in 0 ..< (if wlan: 13 else: 4):
      let a = (if wlan: 3 else: 35) + slot * 2
      expected.add((a, final[a]))
      expected.add((a + 1, final[a + 1]))
  doAssert registerWrites == expected, "wrong register write order or intermediate fields"
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_wlan_runtime_preserves_bz_and_shared_fields(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_io=True) + CHECKS + r'''
for vector in 0 ..< 300:
  setup()
  seedHardware()
  if vector mod 3 != 0: fillCalibration()
  let initial = hardware.txPowerCompWords700
  let delta = [-32768'i16, -36, -31, -19, -7, 0, 8, 9, 20, 21, 24, 32767][vector mod 12]
  rfPriApplyLowPowerRuntimeDelta(delta)
  let power = expectedPower(initial, bz = false)
  let final = expectedReplay(initial, bz = false)
  doAssert hardware.txPowerCompWords700 == final,
    "WLAN runtime replay changed BZ or non-owned fields"
  checkTrace(power, final, true, rfCalibDataGlobal != nil)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bz_runtime_preserves_wlan_and_shared_fields(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_io=True) + CHECKS + r'''
for vector in 0 ..< 300:
  setup()
  seedHardware()
  if vector mod 3 != 0: fillCalibration()
  let initial = hardware.txPowerCompWords700
  let beforeRf70 = rf70.txcalParam70
  let target = [low(int32), 5, 6, 20, 21, 23, 24, high(int32)][vector mod 8]
  let records = if target <= 5: [5, 6, 7, 8]
                elif target <= 20: [1, 2, 3, 4]
                elif target <= 23: [0, 1, 2, 3]
                else: [1, 2, 3, 6]
  rf_pri_input_bz_target_power(target)
  doAssert bl808RfBzTargetPowerRecords == records
  doAssert channelCompCalls == 1
  doAssert rf70.txcalParam70 == (if rfCalibDataGlobal == nil: beforeRf70
                               else: (beforeRf70 and 0xFFFFFFF0'u32) or 9)
  if target > 23:
    doAssert hardware.txPowerCompWords700 == initial and registerWrites.len == 0
  else:
    let power = expectedPower(initial, wlan = false)
    let final = expectedReplay(initial, wlan = false)
    doAssert hardware.txPowerCompWords700 == final,
      "BZ runtime replay changed WLAN or non-owned fields"
    checkTrace(power, final, false, rfCalibDataGlobal != nil)
  registerWrites.setLen(0)
  rf_pri_input_bz_target_power(target)
  doAssert channelCompCalls == 2 and registerWrites.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scoped_wb03_replays_records_without_fixed_fallback(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_io=True) + CHECKS + r'''
for wlan in [true, false]:
  for variant in 0 ..< 5:
    setup()
    seedHardware()
    wb03 = true
    bl808WifiRfWb03ReplayCompleteTxPowerCal = variant != 1
    if variant != 0: fillCalibration()
    # Neither an empty record nor the other domain changes replay ownership.
    if variant == 3:
      let offset = if wlan: 0xF8 + 6 * 8 else: 0x68
      calibration[offset div 4] = 0
      calibration[offset div 4 + 1] = 0
    if variant == 4:
      let offset = if wlan: 0x68 else: 0xF8 + 5 * 8
      calibration[offset div 4] = 0
      calibration[offset div 4 + 1] = 0
    let initial = hardware.txPowerCompWords700
    if wlan: rfPriApplyLowPowerRuntimeDelta(0)
    else: rf_pri_input_bz_target_power(5)
    let useRecords = variant != 0
    let power = expectedPower(initial, wlan, not wlan)
    let final = expectedReplay(initial, wlan, not wlan)
    doAssert hardware.txPowerCompWords700 == final,
      "scoped WB03 record replay changed another domain or unowned fields"
    doAssert nim_wifi_rf_tx_power_replay_mode == (if useRecords: 1'u32 else: 0'u32)
    let reason = if variant == 0: 1'u32 else: 0'u32
    doAssert nim_wifi_rf_tx_power_replay_skip_reason == reason
    checkTrace(power, final, wlan, useRecords)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_other_domain_indices_do_not_block_runtime_update(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_io=True) + CHECKS + r'''
for wlan in [true, false]:
  setup()
  seedHardware()
  fillCalibration()
  let initial = hardware.txPowerCompWords700
  if wlan:
    bl808RfBzTargetPowerRecords[0] = -1
    bl808RfBzTargetPowerRecords[3] = 9
    rfPriApplyLowPowerRuntimeDelta(9)
  else:
    bl808RfTxPowerTableIndex[0] = -1
    bl808RfTxPowerTableIndex[12] = 18
    rf_pri_input_bz_target_power(5)
  let power = expectedPower(initial, wlan, not wlan)
  let final = expectedReplay(initial, wlan, not wlan)
  doAssert hardware.txPowerCompWords700 == final,
    "irrelevant invalid indices prevented a valid runtime update"
  checkTrace(power, final, wlan, true)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_zero_selected_calibration_clears_only_its_owned_fields(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_io=True) + CHECKS + r'''
for wlan in [true, false]:
  setup()
  seedHardware()
  fillCalibration()
  let offset = if wlan: 0x68 else: 0xF8 + 5 * 8
  calibration[offset div 4] = 0
  calibration[offset div 4 + 1] = 0
  let initial = hardware.txPowerCompWords700
  if wlan: rfPriApplyLowPowerRuntimeDelta(0)
  else: rf_pri_input_bz_target_power(5)
  let power = expectedPower(initial, wlan, not wlan)
  let final = expectedReplay(initial, wlan, not wlan)
  doAssert hardware.txPowerCompWords700 == final,
    "zero record changed unowned calibration fields"
  checkTrace(power, final, wlan, true)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_publication_preserves_current_not_snapshotted_unowned_bits(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_io=True) + CHECKS + r'''
for wlan in [true, false]:
  for phase in [rfPowerFields, rfPowerCalibration]:
    for vector in 0 ..< 100:
      seedHardware()
      var packed: array[43, uint32]
      for word in packed.mitems: word = randomWord()
      var expected = hardware.txPowerCompWords700
      if phase == rfPowerFields:
        if wlan:
          for i in 0 ..< 3:
            field(expected[i], 0, if i == 2: 30 else: 24, cast[int32](packed[i]))
        else:
          field(expected[34], 0, 24, cast[int32](packed[34]))
      for slot in 0 ..< (if wlan: 13 else: 4):
        let a = (if wlan: 3 else: 35) + slot * 2
        if phase == rfPowerFields:
          field(expected[a], 11, if wlan: 21 else: 19, cast[int32](packed[a] shr 11))
          field(expected[a + 1], 24, 4, cast[int32](packed[a + 1] shr 24))
        else:
          field(expected[a], 0, 11, cast[int32](packed[a]))
          field(expected[a + 1], 2, 22, cast[int32](packed[a + 1] shr 2))
      rfPriPublishTxPowerTable(packed, if wlan: rfPowerWlan else: rfPowerBz, phase)
      doAssert hardware.txPowerCompWords700 == expected,
        "publisher copied stale unowned bits instead of preserving live bits"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_invalid_selected_indices_do_not_partially_publish(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_io=True) + CHECKS + r'''
for wlan in [true, false]:
  for invalid in [-1, 32767]:
    setup()
    seedHardware()
    fillCalibration()
    let initial = hardware.txPowerCompWords700
    if wlan: bl808RfTxPowerTableIndex[12] = invalid.int16
    else: bl808RfBzTargetPowerRecords[3] = invalid
    rfPriWriteTxPowerTable(if wlan: rfPowerWlan else: rfPowerBz)
    doAssert hardware.txPowerCompWords700 == initial
    doAssert registerWrites.len == 0 and snapshots == 0
''')
