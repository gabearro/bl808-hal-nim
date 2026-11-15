"""RF70 window publication and TXCAL completion against rf_pri.c.o."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, array_constant, source
from test_wifi_rf_txcal_setup import setup_source


def rf70_source(names: tuple[str, ...]) -> str:
    rf = RF.read_text()
    code = setup_source(())
    for name in (
        "RfCalibRf70ReplayHighBandWordIndex", "RfPriWb03Rf70ColdSeed",
        "RfPriRf70ReplayFieldsMeasuredByTxcal", "RfPriRf70ReplayFieldsMeasuredFallback",
    ):
        lines = [line for line in rf.splitlines() if line.startswith("  " + name + " = ")]
        if lines:
            code += "const\n" + lines[0] + "\n"
    code += r'''
var
  bl808WifiRfWb03ApplyMeasuredRf70Replay: bool
  rf70ReplayWindowValidMask, rf70ReplayWindow0SourceNibble: uint32
  rf70ReplayWindow1SourceNibble, rf70ReplayWindow2SourceNibble: uint32
  nim_wifi_rf_rf70_txcal_search_count, nim_wifi_rf_rf70_txcal_search_ok_mask: uint32
  nim_wifi_rf_rf70_replay_reason: uint32
  rf70ReplaySearchBestNibble, rf70ReplaySearchRunnerUpNibble: array[3, uint32]
  rf70ReplaySearchBestSample, rf70ReplaySearchRunnerUpSample: array[3, uint32]
  rf70ReplaySearchMeasureCtrl, rf70ReplaySearchMeasureMode: array[3, uint32]
  rf70ReplaySearchMeasureIRaw, rf70ReplayCandidateValidMask: array[3, uint32]
  rf70ReplayCandidateAverageSample: array[48, uint32]
'''
    for name in (
        "rfCalibRf70ReplayHighBandWord", "rfCalibSetRf70ReplayLowBandWord",
        "rfCalibSetRf70ReplayHighBandWord", "rfPriRf70ReplayWindow1Nibble",
        "rfPriRf70ReplayWindow2Nibble", *names,
    ):
        if f"proc {name}(" in rf:
            if name == "sampleRfTxcalAverage":
                code += rf[rf.rindex("\nproc sampleRfTxcalAverage(") + 1:].split("\nproc ", 1)[0] + "\n"
            else:
                code += procedure(rf, name)
    return code


PUBLICATION = (
    "rfPriRefreshRf70ReplayWindowDiagnostics", "rfPriStoreRf70ReplayWindowNibbles",
    "rfPriStoreRf70ReplayWindowNibble",
)


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_windows_keep_vendor_floor_ties_adjacency_and_last_candidate(tmp_path: Path, mode: str) -> None:
    code = rf70_source(("rfPriRecordRf70SearchWindow",)) + r'''
var values: array[16, int32]
var index: int
proc sampleRfTxcalAverage(): tuple[ok: bool, value: int32, ctrl, mode, iRaw: uint32] =
  doAssert index < 16
  result = (true, values[index], 0x12345678'u32, 0x400AA55'u32,
            (cast[uint32](values[index]) and 0x1FFFFFF) or 0xAA000000'u32)
  inc index
'''
    code += procedure(RF.read_text(), "rfPriSearchRf70ReplayWindow")
    run_program(tmp_path, mode, code + r'''
for window in 0 ..< 3:
  for peak in 0 ..< 16:
    for runner in 0 ..< 16:
      for floor in [-16777216'i32, -2049, -2048, -2047]:
        rxcalSetup()
        for value in values.mitems: value = floor
        values[peak] = if peak == runner: -2047 else: 1234
        if peak != runner: values[runner] = 1233
        index = 0
        let before = rf70.txcalParam70
        var best = 5'u32
        var second = 5'u32
        var bestValue = -2048'i32
        var secondValue = -2048'i32
        for candidate, value in values:
          if value > bestValue:
            secondValue = bestValue
            second = best
            bestValue = value
            best = candidate.uint32
          elif value > secondValue:
            secondValue = value
            second = candidate.uint32
        let wanted = if abs(best.int32 - second.int32) == 1: min(best, second) else: best
        let actual = rfPriSearchRf70ReplayWindow(window)
        doAssert actual.ok and actual.nibble == wanted and index == 16
        doAssert events.len == 16, "RF70 window must not restore the input register"
        for candidate, event in events:
          doAssert event == (cast[uint](addr rf70.txcalParam70), (before and 0xFFFFFFF0'u32) or candidate.uint32)
        doAssert rf70.txcalParam70 == ((before and 0xFFFFFFF0'u32) or 15)
        doAssert rf70ReplaySearchBestNibble[window] == best
        doAssert rf70ReplaySearchRunnerUpNibble[window] == second
        doAssert rf70ReplaySearchBestSample[window] == cast[uint32](bestValue)
        doAssert rf70ReplaySearchRunnerUpSample[window] == cast[uint32](secondValue)
        doAssert rf70ReplaySearchMeasureCtrl[window] == 0x12345678
        doAssert rf70ReplaySearchMeasureMode[window] == 0x400AA55
        doAssert rf70ReplaySearchMeasureIRaw[window] == ((cast[uint32](values[15]) and 0x1FFFFFF) or 0xAA000000'u32)
        for candidate, value in values:
          doAssert rf70ReplayCandidateAverageSample[window * 16 + candidate] == cast[uint32](value)
        doAssert rf70ReplayCandidateValidMask[window] == 0xFFFF
        for address in mmioReads:
          doAssert address notin [cast[uint](addr rf70.measureI620), cast[uint](addr rf70.measureCtrl618),
                                 cast[uint](addr rf70.measureMode61c)], "RF70 diagnostics reread the measurement"
for window in 0 ..< 3:
  for uniform in [-16777216'i32, -2049, -2048, -2047, 0, 16777215]:
    rxcalSetup()
    for value in values.mitems: value = uniform
    index = 0
    let aboveFloor = uniform > -2048
    let best = if aboveFloor: 0'u32 else: 5'u32
    let runner = if aboveFloor: 1'u32 else: 5'u32
    let actual = rfPriSearchRf70ReplayWindow(window)
    doAssert actual.ok and actual.nibble == best and index == 16 and events.len == 16
    doAssert rf70ReplaySearchBestNibble[window] == best
    doAssert rf70ReplaySearchRunnerUpNibble[window] == runner
    doAssert rf70ReplaySearchBestSample[window] == cast[uint32](max(uniform, -2048'i32))
    doAssert rf70ReplaySearchRunnerUpSample[window] == cast[uint32](max(uniform, -2048'i32))
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_invalid_window_has_no_effect(tmp_path: Path, mode: str) -> None:
    code = rf70_source(("rfPriRecordRf70SearchWindow",)) + r'''
proc sampleRfTxcalAverage(): tuple[ok: bool, value: int32, ctrl, mode, iRaw: uint32] =
  doAssert false, "invalid RF70 window performed a measurement"
'''
    code += procedure(RF.read_text(), "rfPriSearchRf70ReplayWindow")
    run_program(tmp_path, mode, code + r'''
rxcalSetup()
let before = registerStorage
let count = nim_wifi_rf_rf70_txcal_search_count
for window in [-1, 3, high(int)]:
  let actual = rfPriSearchRf70ReplayWindow(window)
  doAssert not actual.ok and actual.nibble == 0
doAssert registerStorage == before and events.len == 0 and mmioReads.len == 0
doAssert nim_wifi_rf_rf70_txcal_search_count == count
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_each_publication_preserves_unowned_bits_and_accepts_zero(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, rf70_source(PUBLICATION) + r'''
proc store(window: int; value: uint32) =
  when declared(rfPriStoreRf70ReplayWindowNibble):
    rfPriStoreRf70ReplayWindowNibble(window, value)
  else:
    var fields = [rfPriRf70ReplayWindow0Nibble(), rfPriRf70ReplayWindow1Nibble(), rfPriRf70ReplayWindow2Nibble()]
    if window >= 0 and window < 3: fields[window] = value
    rfPriStoreRf70ReplayWindowNibbles(fields[0], fields[1], fields[2])
for window in 0 ..< 3:
  for value in [0'u32, 1, 15, 16, high(uint32)]:
    for vector in 0 ..< 1000:
      rxcalSetup()
      var expected = calibration
      let word = if window == 0: 3 else: 4
      let shift = if window == 0: 24 elif window == 1: 8 else: 4
      expected[word] = (expected[word] and not (15'u32 shl shift)) or ((value and 15) shl shift)
      store(window, value)
      doAssert calibration == expected, "RF70 publication changed unowned saved bits"
      doAssert events == @[(cast[uint](addr calibration[word]), expected[word])]
      doAssert rf70ReplayWindowValidMask == 7, "zero is a valid RF70 saved code"
rxcalSetup()
let before = calibration
for window in [-1, 3, high(int)]: store(window, 0)
rfCalibDataGlobal = nil
store(0, 0)
doAssert calibration == before and events.len == 0
rfPriRefreshRf70ReplayWindowDiagnostics()
doAssert rf70ReplayWindowValidMask == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_three_windows_publish_before_channel_changes_on_every_board(tmp_path: Path, mode: str) -> None:
    code = rf70_source(PUBLICATION) + r'''
var windows: seq[int]
var selected: array[3, uint32]
proc rfPriSearchRf70ReplayWindow(window: int): tuple[ok: bool, nibble: uint32] =
  windows.add(window)
  nim_wifi_rf_rf70_txcal_search_ok_mask = nim_wifi_rf_rf70_txcal_search_ok_mask or (1'u32 shl window)
  (true, selected[window])
'''
    # Replace the shared fixture's channel stub with one that checks publication timing.
    code = code.replace(
        "proc rfPriConfigChannelForCal(channel: int) = events.add((1'u, channel.uint32))",
        "proc rfPriConfigChannelForCal(channel: int) =\n"
        "  events.add((1'u, channel.uint32))\n"
        "  case channel\n"
        "  of 2: doAssert ((rfCalibWord(3) shr 24) and 15) == selected[0]\n"
        "  of 17: doAssert ((rfCalibWord(4) shr 8) and 15) == selected[1]\n"
        "  of 9: doAssert ((rfCalibWord(4) shr 4) and 15) == selected[2]\n"
        "  else: doAssert false",
    )
    code = code.replace("var windows: seq[int]\nvar selected: array[3, uint32]\n", "")
    marker = "proc rfPriConfigChannelForCal(channel: int) ="
    code = code.replace(marker, "var windows: seq[int]\nvar selected: array[3, uint32]\n" + marker, 1)
    for name in ("rfPriPopulateWb03TxcalRf70ReplayFieldsFromSearch", "rfPriPopulateWb03TxcalRf70ReplayFields",
                 "rfPriPopulateTxcalRf70ReplayFields"):
        if f"proc {name}(" in RF.read_text(): code += procedure(RF.read_text(), name)
    run_program(tmp_path, mode, code + r'''
for board in [false, true]:
  for crystal in 0'u32 ..< 6:
    for optIn in [false, true]:
      for vector in 0 ..< 100:
        rxcalSetup()
        wb03 = board
        bl808RfXtalIndex = crystal
        bl808WifiRfWb03ApplyMeasuredRf70Replay = optIn
        selected = [0'u32, 7, 0]
        windows.setLen(0)
        var expected = calibration
        expected[3] = expected[3] and 0xF0FFFFFF'u32
        expected[4] = (expected[4] and 0xFFFFF00F'u32) or 0x700
        let trace = @[(cast[uint](addr calibration[3]), expected[3]), (1'u, 2'u32),
                      (cast[uint](addr calibration[4]), (calibration[4] and 0xFFFFF0FF'u32) or 0x700), (1'u, 17'u32),
                      (cast[uint](addr calibration[4]), expected[4]), (1'u, 9'u32)]
        when declared(rfPriPopulateTxcalRf70ReplayFields): rfPriPopulateTxcalRf70ReplayFields()
        else: rfPriPopulateWb03TxcalRf70ReplayFields()
        doAssert windows == @[0, 1, 2] and events == trace and calibration == expected
        doAssert rf70ReplayWindowValidMask == 7 and nim_wifi_rf_rf70_txcal_search_ok_mask == 7
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_real_sampling_has_one_i_read_per_candidate_and_no_rf70_restore(tmp_path: Path, mode: str) -> None:
    code = rf70_source((
        *PUBLICATION, "signedRfAverageMeasurement", "waitRfTxcalMeasurementReady",
        "sampleRfTxcalAverage", "rfPriRecordRf70SearchWindow", "rfPriSearchRf70ReplayWindow",
    ))
    for name in ("rfPriPopulateWb03TxcalRf70ReplayFieldsFromSearch", "rfPriPopulateWb03TxcalRf70ReplayFields",
                 "rfPriPopulateTxcalRf70ReplayFields"):
        if f"proc {name}(" in RF.read_text(): code += procedure(RF.read_text(), name)
    run_program(tmp_path, mode, code + r'''
for delay in [0, 1, 10001]:
  rxcalSetup()
  wb03 = true
  bl808RfXtalIndex = 4
  bl808WifiRfWb03ApplyMeasuredRf70Replay = true
  calibration[3] = 0
  calibration[4] = 0
  readyAfter = delay
  let before = rf70.txcalParam70
  adcValues.setLen(0)
  for window in 0 ..< 3:
    for candidate in 0 ..< 16:
      let value = if candidate == 6: -2047'i32 else: -2048'i32
      adcValues.add(((cast[uint32](value) and 0x1FFFFFF) or 0xAA000000'u32, 0'u32))
  when declared(rfPriPopulateTxcalRf70ReplayFields): rfPriPopulateTxcalRf70ReplayFields()
  else: rfPriPopulateWb03TxcalRf70ReplayFields()
  doAssert adcIndex == 48 and not pending
  doAssert rfPriRf70ReplayWindow0Nibble() == 5 and rfPriRf70ReplayWindow1Nibble() == 5 and rfPriRf70ReplayWindow2Nibble() == 5
  doAssert rf70.txcalParam70 == ((before and 0xFFFFFFF0'u32) or 15)
  var iReads, qReads, candidates, controls, modes: int
  for address in mmioReads:
    if address == cast[uint](addr rf70.measureI620): inc iReads
    if address == cast[uint](addr rf70.measureQ624): inc qReads
  for event in events:
    if event.address == cast[uint](addr rf70.txcalParam70): inc candidates
    if event.address == cast[uint](addr rf70.measureCtrl618): inc controls
    if event.address == cast[uint](addr rf70.measureMode61c): inc modes
    doAssert event.address != 0, "RF70 scans insert no delay"
  doAssert iReads == 48 and qReads == 0 and candidates == 48 and controls == 144 and modes == 48
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("bz", [False, True])
def test_completion_replays_before_restore_and_wlan_uses_record_three(tmp_path: Path, mode: str, bz: bool) -> None:
    rf = RF.read_text()
    code = setup_source(()).replace("doAssert tag in [0xB1'u32, 0xB2, 0xB5]", "discard tag")
    code = code.replace("rfPriWriteTxPowerTable", "unusedRfPriWriteTxPowerTable")
    for name in ("RfPriTxcalParams", "RfPriBzTxcalParams"):
        code += array_constant(rf, name)
    code += r'''
var replayCount, restoreCount, rows: int
var expectedScope: RfPriPowerTableScope
var saved74, saved600, savedMode: uint32
proc saveRfPriCalState(): uint32 = 0
proc prepareRfPriTxcal() =
  rf70.calCtrl1c = rf70.calCtrl1c or 0x3000
proc prepareRfPriBzTxcal() = prepareRfPriTxcal()
proc rfPriPopulateTxcalRf70ReplayFields() = discard
proc rfPriPopulateWb03TxcalRf70ReplayFields() = discard
proc rfPriApplyTxcalLowBandRf70ReplayNibble() = discard
proc prepareRfTxcalSearchStage() = discard
proc chooseRfTxcalOsdacCode(): uint32 = 10
proc configureRfPriTxcalGain(index: int; params: array[7, uint32]) = discard
proc configureRfPriTxcalGain(power: RfPriTxPowerTableRow; params: array[7, uint32]) = discard
proc tuneRfTxcalRowPower(target, code: uint32): uint32 = 0
proc primeRfTxcalSearch() = doAssert false
proc writeRfTxcalParam(parameter: uint32; value: int32) = doAssert false
proc searchRfTxcalParam(parameter: uint32; center, delta: int32; freq: uint32):
    tuple[ok: bool, value: int32, power: uint32] = doAssert false
proc storeRfTxcalRecord(index: int; p0, p1, p2, p3: int32; power: uint32) = inc rows
proc storeRfPriBzTxcalRecord(index: int; p0, p1, p2, p3: int32) = inc rows
proc rfPriWriteTxPowerTable(scope: RfPriPowerTableScope; phases: set[RfPriPowerTablePhase]) =
  doAssert scope == expectedScope and phases == {rfPowerCalibration} and (rf70.calCtrl1c and 0x3000) == 0x3000
  inc replayCount
  events.add((6'u, scope.ord.uint32))
proc restoreRfPriCalState(saved: uint32) =
  doAssert replayCount == 1, "TXCAL restored state before replaying its table"
  doAssert (rf70.calCtrl1c and 0x3000) == 0 and (rf70.txcalGain64 and 0x7000000) == 0x3000000
  inc restoreCount
  events.add((7'u, 0'u32))
  rf70.txcalParam74 = saved74
  rf70.txcalTosdac600 = saved600
  rf70.calMode14 = savedMode
'''
    for name in ("publishRfTxcalActiveRecord", "runRfPriBzTxcal" if bz else "runRfPriTxcal"):
        if f"proc {name}(" in rf: code += procedure(rf, name)
    code += f"\nconst Bz = {'true' if bz else 'false'}\n"
    run_program(tmp_path, mode, code + r'''
for vector in 0 ..< 1000:
  rxcalSetup()
  saved74 = randomWord()
  saved600 = randomWord()
  savedMode = randomWord()
  replayCount = 0
  restoreCount = 0
  rows = 0
  expectedScope = if Bz: rfPowerBz else: rfPowerWlan
  let savedRecords = calibration
  let expected74 = (saved74 and 0xC0C0FFFF'u32) or ((calibration[32] shl 24) and 0x3F000000'u32) or ((calibration[32] shl 8) and 0x3F0000)
  let expected600 = (saved600 and 0xFF800C00'u32) or ((calibration[32] shr 4) and 0x7FF000) or (calibration[33] and 0x3FF)
  when Bz: runRfPriBzTxcal()
  else: runRfPriTxcal()
  doAssert replayCount == 1 and restoreCount == 1 and calibration == savedRecords
  doAssert rf70.calMode14 == (savedMode or 0xF00000)
  when Bz:
    doAssert rows == 9 and rf70.txcalParam74 == saved74 and rf70.txcalTosdac600 == saved600
    doAssert events[^1] == (cast[uint](addr rf70.calMode14), savedMode or 0xF00000)
  else:
    doAssert rows == 18 and rf70.txcalParam74 == expected74 and rf70.txcalTosdac600 == expected600
    doAssert events[^3 .. ^1] == @[(cast[uint](addr rf70.calMode14), savedMode or 0xF00000),
      (cast[uint](addr rf70.txcalParam74), expected74), (cast[uint](addr rf70.txcalTosdac600), expected600)]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_replay_uses_records_including_zero_without_board_substitution(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_io=True) + r'''
proc expectedRecords(words: var array[43, uint32]; wlan, bz: bool) =
  let bytes = cast[ptr UncheckedArray[uint8]](addr calibration[0])
  for domain in 0 ..< 2:
    if (domain == 0 and not wlan) or (domain == 1 and not bz): continue
    for slot in 0 ..< (if domain == 0: 13 else: 4):
      let record = if domain == 0: bl808RfTxPowerTableIndex[slot].int else: bl808RfBzTargetPowerRecords[slot]
      let offset = (if domain == 0: 0x68 else: 0xF8) + record * 8
      let word = (if domain == 0: 3 else: 35) + slot * 2
      field(words[word], 0, 11, bytes[offset + 2].int32 or (bytes[offset + 3].int32 shl 8))
      field(words[word + 1], 2, 6, bytes[offset + 1].int32)
      field(words[word + 1], 8, 6, bytes[offset].int32)
      field(words[word + 1], 14, 10, bytes[offset + 4].int32 or (bytes[offset + 5].int32 shl 8))
for board in [false, true]:
  for crystal in 0'u32 ..< 6:
    for optIn in [false, true]:
      for storage in 0 ..< 3:
        for scope in [rfPowerAll, rfPowerWlan, rfPowerBz]:
          for phases in [{rfPowerFields}, {rfPowerCalibration}, {rfPowerFields, rfPowerCalibration}]:
            setup()
            for word in written.mitems: word = randomWord()
            wb03 = board
            bl808RfXtalIndex = crystal
            bl808WifiRfWb03ReplayCompleteTxPowerCal = optIn
            if storage != 0: rfCalibDataGlobal = addr calibration[0]
            if storage == 2:
              for word in calibration.mitems: word = randomWord()
              calibration[26] = 0
              calibration[27] = 0
            var expected = written
            if rfPowerFields in phases:
              expected = expectedPower(expected, scope != rfPowerBz, scope != rfPowerWlan)
            if rfPowerCalibration in phases and storage != 0:
              expectedRecords(expected, scope != rfPowerBz, scope != rfPowerWlan)
            rfPriWriteTxPowerTable(scope, phases)
            doAssert written == expected, "TXCAL replay skipped zero fields or substituted board constants"
            doAssert nim_wifi_rf_tx_power_replay_mode == (if rfPowerCalibration in phases and storage != 0: 1'u32 else: 0'u32)
            doAssert nim_wifi_rf_tx_power_replay_skip_reason == (if rfPowerCalibration in phases and storage == 0: 1'u32 else: 0'u32)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_full_calibration_runs_bz_everywhere_without_extra_replay(tmp_path: Path, mode: str) -> None:
    code = setup_source(()) + r'''
var stages: seq[int]
var unexpected: int
proc runRfPriLoFcal() = stages.add(1)
proc runRfPriLoAcal() = stages.add(2)
proc runRfPriRoscal() = stages.add(3)
proc runRfPriRccal() = stages.add(4)
proc runRfPriTxcal() = stages.add(5)
proc runRfPriBzTxcal() = stages.add(6)
proc runRfPriRxcal() = stages.add(7)
proc rfPriSeedBzTxcalFallbackRecords() = inc unexpected
proc replayRfPriCalRegisters() = inc unexpected
proc rfPriReplayWb03Rf70FromTxcalCalWords() = inc unexpected
proc rfPriSnapshotStage(tag: uint32) = discard
'''
    code += procedure(RF.read_text(), "runRfPriFullCalRestoreBaseline")
    run_program(tmp_path, mode, code + r'''
for board in [false, true]:
  for crystal in 0'u32 ..< 6:
    rxcalSetup()
    stages.setLen(0)
    unexpected = 0
    wb03 = board
    bl808RfXtalIndex = crystal
    let before = rf70.rxMode220
    let first = before and 0xFFFFE67D'u32
    let last = first and 0xFFFFFF9E'u32
    runRfPriFullCalRestoreBaseline()
    doAssert stages == @[1, 2, 3, 4, 5, 6, 7] and unexpected == 0
    doAssert events == @[(cast[uint](addr rf70.rxMode220), first), (cast[uint](addr rf70.rxMode220), last),
                        (cast[uint](addr rf70.rxMode220), last), (cast[uint](addr rf70.rxMode220), last)]
''')
