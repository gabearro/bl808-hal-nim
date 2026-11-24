"""Check FCAL's measured sweep, nearest code, and LO record lifecycle."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_lo_search import lo_source, packed_lo_source
from test_wifi_rf_power_replay import RF, object_type


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_sweep_limits_stop_check_and_byte_wrap(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, lo_source() + r'''
for row in 0 ..< 6:
  for scenario in 0 ..< 3:
    loSetup(row)
    let limits = VendorRange[row]
    let coarse = (limits[0] + 1).uint16
    var base = 128
    var coarseReads = 1
    if scenario == 2:
      # Seven decisions place the coarse code at 15, so the sweep crosses zero.
      sampleValues = @[limits[0] - 1, limits[0] - 1, limits[0] - 1,
                       limits[0] - 1, limits[1] + 1, limits[1] + 1, limits[1] + 1]
      base = 15
      coarseReads = 7
    else: sampleValues = @[coarse]
    for i in 0 ..< 45:
      sampleValues.add(if scenario == 1: limits[2] + 1 else: limits[0])
    runRfPriLoFcal()
    let sweepCount = if scenario == 1: 2 else: 40
    doAssert sampleIndex == coarseReads + sweepCount, "FCAL sweep length differs from vendor"
    var codes: seq[uint32]
    for event in mmioWrites:
      if event.address == cast[uint](addr rf70.fcalCtrlA0): codes.add(event.value and 255)
    doAssert codes.len == 1 + coarseReads + sweepCount
    for i in 0 ..< sweepCount:
      doAssert codes[1 + coarseReads + i] == ((base + 1 - i + 256) and 255).uint32,
        "FCAL sweep stopped at zero or programmed a different code"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("base", [15, 128, 240])
def test_nearest_sample_tie_bias_and_packed_records(tmp_path: Path, mode: str, base: int) -> None:
    run_program(tmp_path, mode, packed_lo_source() + f"const BaseCode = {base}\n" + r'''
for row in 0 ..< 6:
  for step in [50, 64, 80, 100, 127, 150, 200, 400]:
    for shift in 1 ..< step:
      loSetup(row)
      for word in calibration.mitems: word = randomWord()
      let initial = calibration
      var expected = calibration
      let halves = cast[ptr UncheckedArray[uint16]](addr expected[0])
      let limits = VendorRange[row]
      sampleValues.setLen(0)
      var coarseCode = 128
      for bit in countdown(6, 0):
        if coarseCode == BaseCode:
          sampleValues.add(limits[0] + 1)
          break
        if coarseCode > BaseCode:
          sampleValues.add(limits[0] - 1)
          coarseCode -= 1 shl bit
        else:
          sampleValues.add(limits[1] + 1)
          coarseCode += 1 shl bit
      doAssert coarseCode == BaseCode
      let coarseReads = sampleValues.len
      var counts: seq[int]
      for i in 0 ..< 40:
        let count = VendorCnt[row][0].int - shift + step * i
        sampleValues.add(count.uint16)
        counts.add(count)
        if i > 0 and count > limits[2].int: break
      doAssert counts[^1] >= VendorCnt[row][20].int
      for channel in 0 ..< 21:
        var best = 0
        var distance = high(int)
        for i, count in counts:
          let delta = abs(count - VendorCnt[row][channel].int)
          if delta <= distance:
            distance = delta
            best = i
        # Measured code is base+1-i; publication adds one at vendor +0x378.
        let code = ((BaseCode + 2 - best + 256) and 255).uint16
        halves[14 + channel] = (halves[14 + channel] and 255) or (code shl 8)
      runRfPriLoFcal()
      doAssert sampleIndex == counts.len + coarseReads
      doAssert calibration == expected, "FCAL must select nearest count, favor upper-count ties, and store code+1"
      let initialHalves = cast[ptr UncheckedArray[uint16]](unsafeAddr initial[0])
      for channel in 0 ..< 21:
        doAssert (halves[14 + channel] and 255) == (initialHalves[14 + channel] and 255)
      doAssert nim_wifi_rf_last_lo_fcal == (halves[34] shr 8).uint32
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_fcal_publishes_records_after_restoring_state(tmp_path: Path, mode: str) -> None:
    code = packed_lo_source().replace(
        "proc restoreRfPriCalState(state: RfPriCalState) = discard",
        "var restored: bool\nproc restoreRfPriCalState(state: RfPriCalState) = restored = true",
    )
    code = code.replace(
        "proc setRfLoFcal(loChannelIndex: int, fcal: uint16) =",
        "proc setRfLoFcal(loChannelIndex: int, fcal: uint16) =\n"
        "  doAssert restored, \"FCAL records were published before state restoration\"",
    )
    run_program(tmp_path, mode, code + r'''
for row in 0 ..< 6:
  loSetup(row)
  restored = false
  sampleValues = @[(VendorRange[row][0] + 1).uint16,
                   VendorCnt[row][0] - 1, VendorRange[row][2] + 1]
  runRfPriLoFcal()
  doAssert restored
''')


def lifecycle_source() -> str:
    rf = RF.read_text()
    code = packed_lo_source()
    for name, body in (
        ("runRfPriLoFcal", "  for i in 0 ..< 21: setRfLoFcal(i, (0x40 + i).uint16)\n"),
        ("runRfPriLoAcal", "  for i in 0 ..< 21: setRfLoAcal(i, (0x20 + i).uint16)\n"),
    ):
        start = code.index("proc " + name + "(")
        end = code.index("\nproc ", start + 1)
        code = code[:start] + "proc " + name + "() =\n" + body + code[end:]
    code += r'''
var observedLo: array[21, uint16]
var stages: seq[int]
proc checkLo() =
  let halves = cast[ptr UncheckedArray[uint16]](rfCalibDataGlobal)
  for i in 0 ..< 21:
    doAssert halves[14 + i] == observedLo[i], "full calibration replaced measured LO records"
proc runRfPriRoscal() = checkLo(); stages.add(1)
proc runRfPriRccal() = checkLo(); stages.add(2)
proc runRfPriTxcal() = checkLo(); stages.add(3)
proc runRfPriBzTxcal() = checkLo(); stages.add(4)
proc rfPriSeedBzTxcalFallbackRecords() = checkLo(); stages.add(4)
proc runRfPriRxcal() = checkLo(); stages.add(5)
proc rfPriSnapshotStage(tag: uint32) = discard
proc replayRfPriCalRegisters() = checkLo()
proc rfPriReplayWb03Rf70FromTxcalCalWords() = checkLo()
proc rfPriApplyWb03RxcalTosdacLatch() = checkLo()
'''
    return code + procedure(rf, "runRfPriFullCalRestoreBaseline")


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_full_calibration_keeps_measured_lo_for_every_crystal(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, lifecycle_source() + r'''
for row in 0 ..< 6:
  for board in [false, true]:
    loSetup(row)
    wb03 = board
    stages.setLen(0)
    for i in 0 ..< 21:
      observedLo[i] = ((0x40 + i) shl 8 or (0x20 + i)).uint16
    runRfPriFullCalRestoreBaseline()
    checkLo()
    doAssert stages == @[1, 2, 3, 4, 5]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_warm_initialization_does_not_fabricate_lo_records(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = packed_lo_source() + object_type(rf, "RfDfeInitBlock") + r'''
var dfe: RfDfeInitBlock
proc rfDfeInitRegs(): ptr RfDfeInitBlock = addr dfe
proc rfPriEfuseInit() = discard
proc rfPriSnapshotStage(tag: uint32) = discard
proc writeRfPriFixedValueRegs() = discard
proc prepareBl808RfColdRegisters() = discard
'''
    init = procedure(rf, "rf_pri_init")
    start = init.index("\n  if not useBl808ColdDefaults:")
    end = init.index("\n  if not useBl808ColdDefaults:\n    rfPriWifiPllConfig()", start + 1)
    code += "proc initializeBeforePll(useBl808ColdDefaults: bool) =" + init[start:end] + "\n"
    run_program(tmp_path, mode, code + r'''
for row in 0 ..< 6:
  for empty in [false, true]:
    for cold in [false, true]:
      loSetup(row)
      if not empty:
        for word in calibration.mitems: word = randomWord() or 1
      let initial = calibration
      initializeBeforePll(cold)
      doAssert calibration == initial, "initialization seeded fixed LO words instead of retaining caller records"
''')
