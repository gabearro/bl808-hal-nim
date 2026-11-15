"""TXCAL setup, OSDAC selection, and row-power flow from RF vendor disassembly."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, array_constant
from test_wifi_rf_txcal import txcal_source


def setup_source(names: tuple[str, ...]) -> str:
    rf = RF.read_text()
    code = txcal_source(())
    for name in (
        "RfTxcalSingenAmplitudeMask", "RfTxcalInitialAmp", "RfTxcalInitialAdcMax",
        "RfTxcalInitialAdcMin", "RfMeasureRoscalMode", "RfTxcalMixerCsMask",
        "RfTxcalMixerCsCount", "RfTxcalOsdacTraceEntries", "RfCalibRccalReplayWordIndex",
        "RfPriTxcalRf70InitialSearchSeedNibble",
    ):
        lines = [line for line in rf.splitlines() if line.startswith("  " + name + " = ")]
        if lines:
            code += "const\n" + lines[0] + "\n"
    code += r'''
var
  rfTxcalOsdacCode: uint32
  nim_wifi_rf_txcal_amp_search_count, nim_wifi_rf_last_txcal_amp: uint32
  nim_wifi_rf_last_txcal_amp_mean: uint32
  nim_wifi_rf_last_txcal_tmxcs, nim_wifi_rf_last_txcal_tmxcs_power: uint32
  nim_wifi_rf_txcal_tmxcs_power_log: array[8, uint32]
  preRf70TxcalSingenAmplitude, preRf70TxcalAdcMean, preRf70TxcalParamReg: uint32
  preRf70TxcalMixerDcReg, preRf70SingenControlReg: uint32
  preRf70SingenAmplitudeLoReg, preRf70SingenAmplitudeHiReg: uint32
  preRf70AverageMeasureCtrlReg, preRf70AverageMeasureModeReg: uint32
'''
    for name in names:
        if f"proc {name}(" in rf:
            if name == "sampleRfTxcalAverage":
                code += rf[rf.rindex("\nproc sampleRfTxcalAverage(") + 1:].split("\nproc ", 1)[0] + "\n"
            elif name == "configureRfPriTxcalGain":
                code += rf[rf.index("\nproc configureRfPriTxcalGain(") + 1:].split("\nproc ", 1)[0] + "\n"
            else:
                code += procedure(rf, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_table_amplitudes_decode_vendor_little_endian_words(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = setup_source(())
    code += array_constant(rf, "RfPriTxcalParams") + array_constant(rf, "RfPriBzTxcalParams")
    run_program(tmp_path, mode, code + r'''
let wlan = [0x100'u32, 0x100, 0x110, 0x170, 0x1B0, 0x190, 0x200, 0x100, 0x110,
            0x170, 0x180, 0x160, 0x1C0, 0x1D0, 0x1D0, 0x1D0, 0x1D0, 0x1D0]
let bz = [0x100'u32, 0x150, 0x190, 0x1A0, 0x200, 0x150, 0x180, 0x1A0, 0x1B0]
for row in 0 ..< wlan.len: doAssert RfPriTxcalParams[row][4] == wlan[row]
for row in 0 ..< bz.len: doAssert RfPriBzTxcalParams[row][4] == bz[row]
doAssert RfTxcalInitialAmp == 256
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_amplitude_write_owns_prep_gate_dfe_and_toggle_order(tmp_path: Path, mode: str) -> None:
    code = setup_source(("startRfPriTxDfeForCal", "writeRfTxcalSingenAmplitude"))
    run_program(tmp_path, mode, code + r'''
for amp in [0'u32, 1, 16, 256, 1023, 2047, 2048, high(uint32)]:
  for vector in 0 ..< 100:
    rxcalSetup()
    var expected = registerStorage
    var trace: seq[tuple[address: uint, value: uint32]]
    template put(offset: int; keep, value: uint32) =
      expected[offset div 4] = (expected[offset div 4] and keep) or value
      trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
    put(0x21C, 0xEFFFEFFF'u32, 0)
    put(0x214, 0xFFFFF800'u32, amp and 0x7FF)
    put(0x218, 0xFFFFF800'u32, amp and 0x7FF)
    put(0x23C, 0xFFFFFFFF'u32, 0x40000)
    put(0x220, 0xFFFFFE7F'u32, 0)
    put(0x220, 0xFFFFE7FF'u32, 0x1082)
    put(0x220, 0xFFFFFFEF'u32, 0x100)
    put(0x20C, 0x7FFFFFFF'u32, 0)
    put(0x20C, 0xFFFFFFFF'u32, 0x80000000'u32)
    writeRfTxcalSingenAmplitude(amp)
    doAssert registerStorage == expected and events == trace, "TXCAL amplitude staging differs"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("bz", [False, True])
def test_initial_setup_preserves_vendor_fields_and_write_order(tmp_path: Path, mode: str, bz: bool) -> None:
    code = setup_source(("startRfPriTxDfeForCal", "startRfPriRxDfeForCal")) + r'''
var initialArgs: seq[tuple[amp: uint32, hi, lo: int32]]
proc tuneRfTxcalSingenPower(amp: uint32; hi, lo: int32): uint32 =
  initialArgs.add((amp, hi, lo))
  nim_wifi_rf_last_txcal_amp_mean = 0x55
  0x155
'''
    name = "prepareRfPriBzTxcal" if bz else "prepareRfPriTxcal"
    code += procedure(RF.read_text(), name)
    code += f"\nconst Bz = {'true' if bz else 'false'}\n"
    run_program(tmp_path, mode, code + r'''
for vector in 0 ..< 1000:
  rxcalSetup()
  initialArgs.setLen(0)
  let saved = calibration
  var expected = registerStorage
  var trace: seq[tuple[address: uint, value: uint32]]
  template put(offset: int; keep, value: uint32) =
    expected[offset div 4] = (expected[offset div 4] and keep) or value
    trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
  put(0x04, 0xFFFFFFFD'u32, 0)
  put(0x2C, 0, 0)
  put(0x30, 0xFFFFFFFF'u32, 2)
  put(0x30, 0xCEFFF8FF'u32, 0xCEFF7800'u32)
  trace.add((0'u, 1'u32))
  put(0x23C, 0xFFFFFFFF'u32, 0x40000)
  put(0x220, 0xFFFFFE7F'u32, 0)
  put(0x220, 0xFFFFE7FF'u32, 0x1082)
  put(0x220, 0xFFFFFFEF'u32, 0x100)
  put(0x23C, 0xFFFFFFFF'u32, 0x40000)
  put(0x220, 0xFFFFFF9F'u32, 0)
  put(0x220, 0xFFFFFFFF'u32, 0x21)
  put(0x220, 0xFFFFFFFF'u32, 0x40)
  trace.add((1'u, 9'u32))
  put(0x1C, 0xFFFFFFFF'u32, 0x3000)
  put(0x88, 0xFFFFFFFF'u32, 0x80000000'u32)
  put(0x64, 0xFFFFFFFF'u32, 0x800000)
  if not Bz: put(0x70, 0xFFFFFFF0'u32, 0xB)
  put(0x20C, 0xFC00FFFF'u32, if Bz: 0x490000'u32 else: 0xB0000'u32)
  put(0x214, 0x3FFFFF'u32, 0)
  put(0x218, 0x3FFFFF'u32, 0xC0000000'u32)
  put(0x60, 0xFFFFFFFF'u32, 3)
  put(0x64, 0x0F83FFFF'u32, if Bz: 0x90300000'u32 else: 0x50000000'u32)
  put(0x58, 0xFFF8FFFF'u32, 0x40000)
  put(0x48, if Bz: 0xCE0FFFFF'u32 else: 0xCE08FFFF'u32, if Bz: 0x770000'u32 else: 0x870000'u32)
  if Bz:
    put(0x90, 0xFFFFFFCF'u32, 0x10)
    put(0x64, 0xF8FFFFFF'u32, 0x4000000)
  else:
    put(0x68, 0x1DFFFFFF'u32, 0xE0000000'u32)
  when Bz: prepareRfPriBzTxcal()
  else: prepareRfPriTxcal()
  doAssert registerStorage == expected and events == trace, "TXCAL initial setup differs from vendor"
  doAssert calibration == saved
  when Bz: doAssert initialArgs.len == 0
  else:
    doAssert initialArgs == @[(256'u32, 128'i32, 96'i32)]
    doAssert preRf70TxcalSingenAmplitude == 0x155 and preRf70TxcalAdcMean == 0x55
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_search_stage_uses_rf90_and_exact_gain_masks(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, setup_source(("prepareRfTxcalSearchStage",)) + r'''
for vector in 0 ..< 1000:
  rxcalSetup()
  var expected = registerStorage
  var trace: seq[tuple[address: uint, value: uint32]]
  template put(offset: int; keep, value: uint32) =
    expected[offset div 4] = (expected[offset div 4] and keep) or value
    trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
  put(0x20C, 0xFC00FFFF'u32, 0x490000)
  put(0x214, 0x3FFFFF'u32, 0)
  put(0x218, 0x3FFFFF'u32, 0xC0000000'u32)
  put(0x60, 0xFFFFFFFF'u32, 3)
  put(0x64, 0x0F83FFFF'u32, 0x90300000'u32)
  put(0x58, 0xFFF8FFFF'u32, 0x40000)
  put(0x48, 0xCE0FFFFF'u32, 0x770000)
  put(0x90, 0xFFFFFFCF'u32, 0x10)
  put(0x64, 0xF8FFFFFF'u32, 0x4000000)
  put(0x64, 0xFF83FFFF'u32, 0xF0400000'u32)
  put(0x60, 0xFFFFFFFF'u32, 3)
  put(0x30, 0xFFFEFFFF'u32, 0)
  put(0x58, 0xFFF8FFFF'u32, 0x10000)
  put(0x21C, 0xEFFFEFFF'u32, 0)
  put(0x214, 0xFFFFF800'u32, 0x10)
  put(0x218, 0xFFFFF800'u32, 0x10)
  put(0x23C, 0xFFFFFFFF'u32, 0x40000)
  put(0x220, 0xFFFFFE7F'u32, 0)
  put(0x220, 0xFFFFE7FF'u32, 0x1082)
  put(0x220, 0xFFFFFFEF'u32, 0x100)
  put(0x20C, 0x7FFFFFFF'u32, 0)
  put(0x20C, 0xFFFFFFFF'u32, 0x80000000'u32)
  trace.add((0'u, 10'u32))
  prepareRfTxcalSearchStage()
  doAssert registerStorage == expected and events == trace
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_row_gain_fields_use_saved_osdac_code_not_table_placeholder(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, setup_source(("configureRfPriTxcalGain",)) + r'''
for vector in 0 ..< 2000:
  rxcalSetup()
  var params: array[7, uint32]
  var power: array[9, uint16]
  for value in params.mitems: value = randomWord()
  for value in power.mitems: value = (randomWord() and 65535).uint16
  rfTxcalOsdacCode = randomWord()
  var expected = registerStorage
  var trace: seq[tuple[address: uint, value: uint32]]
  template put(offset: int; keep, value: uint32) =
    expected[offset div 4] = (expected[offset div 4] and keep) or value
    trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
  put(0x60, 0xFFFFFFFC'u32, params[3] and 3)
  put(0x64, 0x0F83FFFF'u32, (params[0] shl 28) or ((rfTxcalOsdacCode shl 18) and 0x7C0000))
  put(0x58, 0xFFF8FFFF'u32, (params[1] shl 16) and 0x70000)
  put(0x48, 0xCE08FFFF'u32, ((power[0].uint32 shl 28) and 0x30000000'u32) or
      ((power[3].uint32 shl 20) and 0x1F00000) or ((params[5] shl 16) and 0x70000))
  put(0x68, 0x1DFFFFFF'u32, params[6] shl 29)
  when compiles(configureRfPriTxcalGain(power, params)):
    configureRfPriTxcalGain(power, params)
  else: configureRfPriTxcalGain(cast[RfPriTxPowerTableRow](power), params)
  doAssert registerStorage == expected and events == trace, "TXCAL row gain field ownership differs"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_wlan_gain_wrapper_uses_live_power_rows(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = setup_source(())
    if "  RfPriTxcalPowerSetup:" in rf:
        code += array_constant(rf, "RfPriTxcalPowerSetup")
    code += r'''
var observed: tuple[a, b: uint16]
proc configureRfPriTxcalGain(power: array[9, uint16]; params: array[7, uint32]) =
  observed = (power[0], power[3])
proc configureRfPriTxcalGain(power: RfPriTxPowerTableRow; params: array[7, uint32]) =
  observed = (cast[uint16](power[0]), cast[uint16](power[3]))
'''
    code += rf[rf.index("\nproc configureRfPriTxcalGain(txcalPowerSetupIndex:") + 1:].split("\nproc ", 1)[0] + "\n"
    run_program(tmp_path, mode, code + r'''
for row in 0 ..< 18:
  for vector in 0 ..< 100:
    rxcalSetup()
    for value in bl808RfTxPowerTable[row].mitems: value = cast[int16]((randomWord() and 65535).uint16)
    configureRfPriTxcalGain(row, default(array[7, uint32]))
    doAssert observed == (cast[uint16](bl808RfTxPowerTable[row][0]), cast[uint16](bl808RfTxPowerTable[row][3])),
      "TXCAL gain setup must use the live WLAN power table"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_row_power_search_bounds_retry_zero_return_and_last_programmed_state(tmp_path: Path, mode: str) -> None:
    code = setup_source(("clampRfTxcalAmp", "writeRfTxcalOsdacCode")) + r'''
var means: seq[int32]
var meanIndex: int
proc writeRfTxcalSingenAmplitude(amp: uint32) = events.add((3'u, amp))
proc sampleRfTxcalAdcMean(): tuple[ok: bool, value: int32] =
  doAssert meanIndex < means.len
  result = (true, means[meanIndex])
  events.add((2'u, cast[uint32](result.value)))
  inc meanIndex
'''
    for name in ("tuneRfTxcalSingenPower", "tuneRfTxcalRowPower"):
        if f"proc {name}(" in RF.read_text():
            code += procedure(RF.read_text(), name)
    run_program(tmp_path, mode, code + r'''
for target in [256'u32, 272, 336, 368, 400, 432, 448, 464, 512]:
  for code in [0'u32, 1, 3, 10, 20, 31]:
    for scenario in 0 ..< 8:
      rxcalSetup()
      var expected = registerStorage
      var trace: seq[tuple[address: uint, value: uint32]]
      template put(offset: int; keep, value: uint32) =
        expected[offset div 4] = (expected[offset div 4] and keep) or value
        trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
      means.setLen(0)
      meanIndex = 0
      let lo = target shr 2
      let hi = min(target shl 1, 1023'u32)
      let span = hi - lo
      var wanted = 0'u32
      block oracle:
        for attempt in 0 ..< 2:
          put(0x64, 0xFF83FFFF'u32, (((code shr attempt) shl 18) and 0x7C0000))
          var amp = lo + (span shr 1)
          var step = span shr 2
          var level = 0
          while true:
            trace.add((3'u, amp))
            trace.add((0'u, 10'u32))
            let value = case scenario
              of 0: 0'i32
              of 1: 128'i32
              of 2: 129'i32
              of 3: -1'i32
              of 4: (if attempt == 0: -1'i32 else: 64'i32)
              of 5: (if attempt == 1 and step == 0: 64'i32 else: -1'i32)
              of 6: (if step == 0: 64'i32 else: -1'i32)
              else: (if level mod 2 == 0: 129'i32 else: -1'i32)
            means.add(value)
            trace.add((2'u, cast[uint32](value)))
            if value >= 0 and value <= 128:
              wanted = if step == 0: 0'u32 else: amp
              break oracle
            if value > 128: amp -= step
            else: amp += step
            if step == 0:
              if value >= 0: break oracle
              break
            step = step shr 1
            inc level
      let actual = when declared(tuneRfTxcalRowPower): tuneRfTxcalRowPower(target, code)
                   else: tuneRfTxcalSingenPower(target, 128, 0)
      doAssert actual == wanted and meanIndex == means.len, "TXCAL row amplitude decisions or retry differ"
      doAssert events == trace and registerStorage == expected, "TXCAL row power write order differs"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_row_search_priming_uses_its_own_mode_and_one_finished_i_sample(tmp_path: Path, mode: str) -> None:
    code = setup_source((
        "signedRfAverageMeasurement", "waitRfTxcalMeasurementReady",
        "sampleRfTxcalAverage", "primeRfTxcalSearch",
    ))
    run_program(tmp_path, mode, code + r'''
for delay in [0, 1, 10001, 20017]:
  rxcalSetup()
  readyAfter = delay
  adcValues = @[(0xAABBCCDD'u32, 0xFFFF'u32)]
  var expected = registerStorage
  var trace: seq[tuple[address: uint, value: uint32]]
  template put(offset: int; keep, value: uint32) =
    expected[offset div 4] = (expected[offset div 4] and keep) or value
    trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
  put(0x618, 0xDFEFFFFF'u32, 0)
  put(0x61C, 0xFFFF'u32, 0x10000000)
  put(0x618, 0xFFFFFFFF'u32, 0x20000000)
  expected[0x618 div 4] = expected[0x618 div 4] or 0x10000000'u32
  put(0x618, 0xDFEFFFFF'u32, 0)
  when declared(primeRfTxcalSearch): primeRfTxcalSearch()
  else: discard sampleRfTxcalAverage()
  doAssert adcIndex == 1 and not pending and events == trace and registerStorage == expected
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("bz", [False, True])
def test_coordinators_use_row_targets_skip_failed_rows_and_prime_successes(tmp_path: Path, mode: str, bz: bool) -> None:
    rf = RF.read_text()
    code = setup_source(()).replace("doAssert tag in [0xB1'u32, 0xB2, 0xB5]", "discard tag")
    for name in ("RfPriTxcalParams", "RfPriBzTxcalParams", "RfPriBzTxcalPowerSetup"):
        if "  " + name + ":" in rf:
            code += array_constant(rf, name)
    code += r'''
var
  expectedTargets: seq[uint32]
  failed: array[18, bool]
  row, searches, programs, primers, stored, rowTunes, legacyTunes: int
  phases: seq[int]
const Results = [20'i32, 21, 22, 23, 1000, -32, 1100, -25]
proc saveRfPriCalState(): uint32 = 0
proc restoreRfPriCalState(saved: uint32) = discard
proc prepareRfPriTxcal() = phases.add(1)
proc prepareRfPriBzTxcal() = phases.add(6)
proc rfPriPopulateWb03TxcalRf70ReplayFields() = phases.add(2)
proc rfPriPopulateTxcalRf70ReplayFields() = phases.add(2)
proc publishRfTxcalActiveRecord() = discard
proc rfPriApplyTxcalLowBandRf70ReplayNibble() = phases.add(3)
proc prepareRfTxcalSearchStage() = phases.add(4)
proc chooseRfTxcalMixerCs(): uint32 =
  phases.add(5)
  10
proc chooseRfTxcalOsdacCode(): uint32 =
  phases.add(5)
  10
proc configureRfPriTxcalGain(index: int; params: array[7, uint32]) =
  doAssert index == row
proc configureRfPriTxcalGain(power: array[9, uint16]; params: array[7, uint32]) = discard
proc configureRfPriTxcalGain(power: RfPriTxPowerTableRow; params: array[7, uint32]) = discard
proc tuneRfTxcalSingenPower(amp: uint32; hi, lo: int32): uint32 =
  inc legacyTunes
  amp
proc tuneRfTxcalRowPower(target, code: uint32): uint32 =
  inc rowTunes
  doAssert code == rfTxcalOsdacCode and target == expectedTargets[row]
  result = if failed[row]: 0'u32 else: target
proc primeRfTxcalSearch() =
  doAssert not failed[row] and stored == row
  inc primers
proc writeRfTxcalParam(parameter: uint32; value: int32) = inc programs
proc searchRfTxcalParam(parameter: uint32; center, delta: int32; freq: uint32):
    tuple[ok: bool, value: int32, power: uint32] =
  doAssert not failed[row] and primers > searches div 8
  doAssert programs == searches
  result = (true, Results[searches mod 8], (searches mod 8 + 1).uint32)
  inc searches
proc record(p0, p1, p2, p3: int32) =
  if failed[row]: doAssert [p0, p1, p2, p3] == [32'i32, 32, 1024, 0]
  else: doAssert [p0, p1, p2, p3] == [22'i32, 23, 1100, -25]
  inc row
  inc stored
proc storeRfTxcalRecord(index: int; p0, p1, p2, p3: int32; power: uint32) =
  doAssert index == row
  if failed[row]: doAssert power == 0
  record(p0, p1, p2, p3)
proc storeRfPriBzTxcalRecord(index: int; p0, p1, p2, p3: int32) =
  doAssert index == row
  record(p0, p1, p2, p3)
'''
    name = "runRfPriBzTxcal" if bz else "runRfPriTxcal"
    code += procedure(rf, name)
    code += f"\nconst Bz = {'true' if bz else 'false'}\nconst Rows = {9 if bz else 18}\n"
    targets = ([256, 336, 400, 416, 512, 336, 384, 416, 432] if bz else
               [256, 256, 272, 368, 432, 400, 512, 256, 272, 368, 384, 352, 448, 464, 464, 464, 464, 464])
    code += "expectedTargets = @[" + ", ".join(f"{v}'u32" for v in targets) + "]\n"
    run_program(tmp_path, mode, code + r'''
for pattern in 0'u32 ..< 128:
  rxcalSetup()
  row = 0
  stored = 0
  searches = 0
  programs = 0
  primers = 0
  rowTunes = 0
  legacyTunes = 0
  phases.setLen(0)
  rfTxcalOsdacCode = 17
  var successes = 0
  for index in 0 ..< Rows:
    failed[index] = ((pattern shr (index mod 7)) and 1) != 0
    if not failed[index]: inc successes
  when Bz: runRfPriBzTxcal()
  else: runRfPriTxcal()
  doAssert rowTunes == Rows and legacyTunes == 0 and stored == Rows
  doAssert searches == 8 * successes and programs == searches and primers == successes
  when Bz:
    doAssert phases == @[6] and rfTxcalOsdacCode == 17
    for index in 0 ..< Rows:
      if failed[index]:
        doAssert nim_wifi_rf_bz_txcal_ok_mask_log[index] == 0
        doAssert nim_wifi_rf_bz_txcal_power_log[index] == 0
  else:
    doAssert phases == @[1, 2, 3, 4, 5] and rfTxcalOsdacCode == 10
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_initial_amplitude_search_visits_nine_levels_and_keeps_thresholds(tmp_path: Path, mode: str) -> None:
    code = setup_source(("clampRfTxcalAmp",)) + r'''
var means: seq[int32]
var measuredAmps: seq[uint32]
var meanIndex: int
proc writeRfTxcalSingenAmplitude(amp: uint32) = measuredAmps.add(amp)
proc sampleRfTxcalAdcMean(): tuple[ok: bool, value: int32] =
  doAssert meanIndex < means.len
  result = (true, means[meanIndex])
  inc meanIndex
'''
    code += procedure(RF.read_text(), "tuneRfTxcalSingenPower")
    run_program(tmp_path, mode, code + r'''
for pattern in 0 ..< 19683:
  rxcalSetup()
  means.setLen(0)
  measuredAmps.setLen(0)
  meanIndex = 0
  var expected: seq[uint32]
  var amp = 256'u32
  var step = 128'u32
  var choices = pattern
  while true:
    expected.add(amp)
    let choice = choices mod 3
    choices = choices div 3
    let value = if choice == 0: 95'i32 elif choice == 1: 129'i32 else: 96'i32
    means.add(value)
    if value in 96'i32 .. 128'i32 or step == 0: break
    if value < 96: amp += step
    else: amp -= step
    step = step shr 1
  let actual = tuneRfTxcalSingenPower(RfTxcalInitialAmp, 128, 96)
  doAssert actual == amp and measuredAmps == expected and meanIndex == means.len
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_osdac_search_targets_signed_mean_and_preserves_calibration(tmp_path: Path, mode: str) -> None:
    code = setup_source(("writeRfTxcalMixerCs", "writeRfTxcalOsdacCode")) + r'''
var means: seq[int32]
var meanIndex: int
proc nextMean(): int32 =
  doAssert meanIndex < means.len
  result = means[meanIndex]
  events.add((2'u, cast[uint32](result)))
  inc meanIndex
proc sampleRfTxcalAdcMean(): tuple[ok: bool, value: int32] = (true, nextMean())
proc sampleRfTxcalAverage(): tuple[ok: bool, value: int32] = (true, nextMean() * 1024)
'''
    for name in ("chooseRfTxcalMixerCs", "chooseRfTxcalOsdacCode"):
        if f"proc {name}(" in RF.read_text():
            code += procedure(RF.read_text(), name)
    run_program(tmp_path, mode, code + r'''
for vector in 0 ..< 3000:
  rxcalSetup()
  rf70.txcalGain64 = (rf70.txcalGain64 and 0xFF83FFFF'u32) or 0x400000
  let saved = calibration
  means.setLen(0)
  meanIndex = 0
  for _ in 0 ..< 9:
    let values = [-400'i32, -301, -300, -299, -251, -250, -249, -200, -199, -198, 0, 100]
    means.add(values[int(randomWord() mod values.len.uint32)])
  var expected = registerStorage
  var trace: seq[tuple[address: uint, value: uint32]]
  template put(offset: int; keep, value: uint32) =
    expected[offset div 4] = (expected[offset div 4] and keep) or value
    trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
  var best = 16'u32
  var bestMean = means[0]
  var index = 1
  trace.add((0'u, 10'u32))
  trace.add((2'u, cast[uint32](bestMean)))
  for step in [8'u32, 4, 2, 1]:
    var candidate = best - step
    if candidate == 0: candidate = 1
    put(0x64, 0xFF83FFFF'u32, (candidate shl 18) and 0x7C0000)
    trace.add((0'u, 10'u32))
    var value = means[index]
    inc index
    trace.add((2'u, cast[uint32](value)))
    if abs(value + 250) < abs(bestMean + 250) or value < -300:
      best = candidate
      bestMean = value
    else:
      candidate = min(best + step, 31'u32)
      put(0x64, 0xFF83FFFF'u32, candidate shl 18)
      trace.add((0'u, 10'u32))
      value = means[index]
      inc index
      trace.add((2'u, cast[uint32](value)))
      if abs(value + 250) < abs(bestMean + 250) or value >= -199:
        best = candidate
        bestMean = value
  put(0x30, 0xFFFFFFFF'u32, 0x10000)
  put(0x58, 0xFFF8FFFF'u32, 0x40000)
  let wanted = if best < 3 or best > 20 or bestMean < -300 or bestMean > -200: 10'u32 else: best
  let actual = when declared(chooseRfTxcalOsdacCode): chooseRfTxcalOsdacCode()
               else: chooseRfTxcalMixerCs()
  doAssert actual == wanted and meanIndex == index, "TXCAL OSDAC search decisions differ"
  doAssert registerStorage == expected and events == trace, "TXCAL OSDAC writes or timing differ"
  doAssert calibration == saved, "TXCAL OSDAC selection must not rewrite RCCAL's saved word"
''')
