"""RCCAL field ownership, measurement/search traces, and result publication."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, object_type
from test_wifi_rf_rxcal import rxcal_source


def rccal_source(names: tuple[str, ...]) -> str:
    rf = RF.read_text()
    code = rxcal_source(())
    constants = (
        "RfRccalCapabilityMask", "RfRccalModeMask", "RfRccalStartMode",
        "RfRccalDoneMode", "RfRccalFailMode", "RfRccalCodeMask",
        "RfRccalRegisterKeepMask", "RfRccalBaselineCode", "RfRccalInitialStep", "RfRccalTargetNumerator",
        "RfRccalTargetDenominator", "RfRccalFallbackTargetNumerator",
        "RfRccalFallbackTargetDenominator", "RfRccalMinReferencePower",
        "RfRccalReferenceMeasureCtrl", "RfRccalToneMeasureCtrl", "RfRccalWaitLimit",
        "RfMeasureRccalTriggerMask", "RfMeasureStartMask", "RfMeasureModeKeepMask",
        "RfMeasureRoscalMode", "RfCalibRccalReplayWordIndex",
        "RfPriWb03RccalRf80Seed", "RfPriWb03RccalRf84Seed",
    )
    for name in constants:
        lines = [line for line in rf.splitlines() if line.startswith("  " + name + " = ")]
        if lines:
            code += "const\n" + lines[0] + "\n"
    code = code.replace(
        "adcValues[adcIndex]", "adcValues[adcIndex - 1]"
    ).replace(
        "doAssert adcIndex < adcValues.len", "doAssert adcIndex > 0 and adcIndex <= adcValues.len"
    ).replace(
        "    inc adcIndex\n    return", "    return"
    ).replace(
        "      pending = true\n      polls = 0",
        "      pending = true\n      polls = 0\n"
        "      if adcValues.len != 0:\n"
        "        inc adcIndex\n"
        "        doAssert adcIndex <= adcValues.len, \"RCCAL made an extra measurement\"",
    )
    code += r'''
var
  nim_wifi_rf_pri_rccal_count, nim_wifi_rf_rccal_wait_timeout_count: uint32
  nim_wifi_rf_last_rccal_code, nim_wifi_rf_last_rccal_baseline: uint32
  nim_wifi_rf_last_rccal_target, nim_wifi_rf_last_rccal_power: uint32
  nim_wifi_rf_rccal_search_log, nim_wifi_rf_rccal_power_log: array[32, uint32]
proc rfPriApplyWb03RccalSeed() = inc workarounds
'''
    for name in ("startRfPriTxDfeForCal", "startRfPriRxDfeForCal", *names):
        if f"proc {name}(" in rf:
            code += procedure(rf, name)
    return code + r'''
proc rccalSetup() =
  rxcalSetup()
  nim_wifi_rf_rccal_search_log = default(typeof(nim_wifi_rf_rccal_search_log))
  nim_wifi_rf_rccal_power_log = default(typeof(nim_wifi_rf_rccal_power_log))
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_reference_and_tone_setup_match_vendor_mmio(tmp_path: Path, mode: str) -> None:
    code = rccal_source(("prepareRfPriRccal", "prepareRfPriRccalTone"))
    run_program(tmp_path, mode, code + r'''
for tone in [false, true]:
  for vector in 0 ..< 1000:
    rccalSetup()
    let before = calibration
    var expected = registerStorage
    var trace: seq[tuple[address: uint, value: uint32]]
    template put(offset: int; keep, value: uint32) =
      expected[offset div 4] = (expected[offset div 4] and keep) or value
      trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
    template txDfe() =
      put(0x23C, 0xFFFFFFFF'u32, 0x40000)
      put(0x220, 0xFFFFFE7F'u32, 0)
      put(0x220, 0xFFFFE7FF'u32, 0x1082)
      put(0x220, 0xFFFFFFEF'u32, 0x100)
    if tone:
      put(0x48, 0xFFFF8CFF'u32, 0x6200)
      put(0x20C, 0xFC00FFFF'u32, 0xB50000)
      put(0x214, 0x3FFFFF'u32, 0)
      put(0x218, 0x3FFFFF'u32, 0xC0000000'u32)
      txDfe()
      put(0x20C, 0x7FFFFFFF'u32, 0)
      put(0x20C, 0xFFFFFFFF'u32, 0x80000000'u32)
      put(0x618, 0xFFF00000'u32, 0x16A00)
      prepareRfPriRccalTone()
    else:
      put(0x04, 0xFFFFFFFD'u32, 0)
      put(0x2C, 0, 0)
      put(0x30, 0xFFFFFFFF'u32, 2)
      put(0x30, 0x2DF8F8FF'u32, 0x2DF87800)
      trace.add((0'u, 1'u32))
      txDfe()
      put(0x23C, 0xFFFFFFFF'u32, 0x40000)
      put(0x220, 0xFFFFFF9F'u32, 0)
      put(0x220, 0xFFFFFFFF'u32, 0x21)
      put(0x220, 0xFFFFFFFF'u32, 0x40)
      put(0x80, 0xFFFFFFFF'u32, 0x40000000)
      put(0x88, 0xFFFCFFFF'u32, 0)
      put(0x88, 0xFCFFFFFF'u32, 0x2000000)
      put(0x90, 0xFFFFFFFF'u32, 0x1000)
      put(0x1C, 0xFFFFFFFF'u32, 0x800)
      put(0x60C, 0xFFFFF7FF'u32, 0)
      put(0x60C, 0xFFFFFFFF'u32, 0x8000000)
      put(0x48, 0xFFFF8CFF'u32, 0x3100)
      put(0x20C, 0xFC00FFFF'u32, 0x30000)
      put(0x214, 0x3FFFFF'u32, 0)
      put(0x218, 0x3FFFFF'u32, 0xC0000000'u32)
      put(0x21C, 0xEFFFEFFF'u32, 0)
      put(0x214, 0xFFFFF800'u32, 0xFF)
      put(0x218, 0xFFFFF800'u32, 0xFF)
      txDfe()
      put(0x20C, 0x7FFFFFFF'u32, 0)
      put(0x20C, 0xFFFFFFFF'u32, 0x80000000'u32)
      prepareRfPriRccal()
    doAssert registerStorage == expected and events == trace,
      "RCCAL setup fields, enables, or write/delay order differ from vendor"
    doAssert calibration == before and workarounds == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_ready_wait_never_returns_unfinished_samples(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, rccal_source(("waitRfRccalMeasurementReady",)) + r'''
for delay in [10001, 0, 1, 20017]:
  rccalSetup()
  pending = true
  readyAfter = delay
  let previous = nim_wifi_rf_rccal_wait_timeout_count
  doAssert waitRfRccalMeasurementReady(), "RCCAL wait returned before READY"
  doAssert polls == delay + 1 and events.len == 0
  doAssert nim_wifi_rf_rccal_wait_timeout_count == previous + (delay div RfRccalWaitLimit).uint32
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_prime_and_power_measurement_have_exact_triggers_without_delays(tmp_path: Path, mode: str) -> None:
    code = rccal_source((
        "signedRfPowerMeasurement", "squareRfSample", "saturatingRfUint32",
        "waitRfRccalMeasurementReady", "sampleRfRccalPower", "primeRfRccalPowerMeasurement",
    ))
    run_program(tmp_path, mode, code + r'''
for prime in [true, false]:
  for delay in [0, 1, 10001, 20017]:
    for pair in [(-32768'i32, -32768'i32), (-1'i32, 0'i32), (0'i32, 1'i32), (32767'i32, -12345'i32)]:
      rccalSetup()
      let (i, q) = pair
      adcValues = @[((cast[uint32](i) shl 9) or 0xAA000155'u32,
                     (cast[uint32](q) shl 9) or 0x540000AA'u32)]
      readyAfter = delay
      var expected = registerStorage
      var trace: seq[tuple[address: uint, value: uint32]]
      template put(offset: int; keep, value: uint32) =
        expected[offset div 4] = (expected[offset div 4] and keep) or value
        trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
      if prime:
        put(0x618, 0xFFF00000'u32, 0x600)
        put(0x618, 0xDFEFFFFF'u32, 0)
        put(0x61C, 0xFFFF'u32, 0x4000000)
        put(0x618, 0xFFFFFFFF'u32, 0x20000000)
      else:
        put(0x618, 0xDFEFFFFF'u32, 0)
        put(0x618, 0xFFFFFFFF'u32, 0x20100000)
      expected[0x618 div 4] = expected[0x618 div 4] or 0x10000000'u32
      put(0x618, 0xDFEFFFFF'u32, 0)
      if prime: primeRfRccalPowerMeasurement()
      else:
        doAssert sampleRfRccalPower() == (i.int64 * i.int64 + q.int64 * q.int64).uint32
      doAssert adcIndex == 1 and not pending
      var iReads, qReads: int
      for address in mmioReads:
        if address == cast[uint](addr rf70.measureI620): inc iReads
        if address == cast[uint](addr rf70.measureQ624): inc qReads
      doAssert iReads == 1 and qReads == (if prime: 0 else: 1)
      doAssert registerStorage == expected and events == trace,
        "RCCAL priming/sample control or delay sequence differs from vendor"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_search_fields_and_publication_own_rf84_and_calibration_word2(tmp_path: Path, mode: str) -> None:
    code = rccal_source(("writeRfRccalCode", "publishRfRccalResults", "writeRfRccalSearchCode"))
    run_program(tmp_path, mode, code + r'''
for code in 0'u32 .. 255'u32:
  rccalSetup()
  let before = calibration
  var expected = registerStorage
  expected[0x84 div 4] = (expected[0x84 div 4] and 0xC0FFC0FF'u32) or
    ((code and 63) shl 24) or ((code and 63) shl 8)
  writeRfRccalSearchCode(code)
  doAssert calibration == before and registerStorage == expected,
    "RCCAL search must own only RF84's two search lanes"
  doAssert events == @[(cast[uint](addr rf70.rccalReplay84), expected[0x84 div 4])]
for upper in 0'u32 .. 63'u32:
  for lower in 0'u32 .. 63'u32:
    rccalSetup()
    rf70.rccalReplay84 = (rf70.rccalReplay84 and 0xC0FFC0FF'u32) or (upper shl 24) or (lower shl 8)
    var expected = calibration
    var rfExpected = registerStorage
    var trace: seq[tuple[address: uint, value: uint32]]
    template save(keep, value: uint32) =
      expected[2] = (expected[2] and keep) or value
      trace.add((cast[uint](addr calibration[2]), expected[2]))
    save(0xFFFFFFC0'u32, upper)
    save(0xFFFC0FFF'u32, lower shl 12)
    save(0xFFFFF03F'u32, upper shl 6)
    save(0xFF03FFFF'u32, lower shl 18)
    rfExpected[0x84 div 4] = (rfExpected[0x84 div 4] and 0xC0FFC0FF'u32) or (upper shl 24) or (upper shl 8)
    trace.add((cast[uint](addr rf70.rccalReplay84), rfExpected[0x84 div 4]))
    rfExpected[0x84 div 4] = (rfExpected[0x84 div 4] and 0xFFC0FFC0'u32) or (upper shl 16) or upper
    trace.add((cast[uint](addr rf70.rccalReplay84), rfExpected[0x84 div 4]))
    when declared(publishRfRccalResults): publishRfRccalResults()
    else: writeRfRccalCode(upper)
    doAssert calibration == expected and registerStorage == rfExpected,
      "RCCAL saved result packing or physical field ownership differs"
    doAssert events == trace, "RCCAL publication order differs from vendor"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_search_wrapping_target_sign_history_and_last_programmed_code(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = rccal_source(("saturatingRfUint32", "logRfRccalSearch")) + r'''
var
  scriptedPower: seq[uint32]
  codes: seq[uint32]
  powerIndex, primes, tones, publications: int
proc primeRfRccalPowerMeasurement() = inc primes
proc prepareRfPriRccalTone() = inc tones
proc sampleRfRccalPower(): uint32 =
  doAssert powerIndex < scriptedPower.len, "RCCAL made an extra sample"
  result = scriptedPower[powerIndex]
  inc powerIndex
proc writeRfRccalSearchCode(code: uint32) = codes.add(code and 63)
proc writeRfRccalCode(code: uint32) = inc publications
'''
    code += procedure(rf, "chooseRfRccalCode")
    run_program(tmp_path, mode, code + r'''
for baseline in [0'u32, 1, 63, 64, 53024287, 53024288, 0x12345678'u32, 0x7FFFFFFF'u32, 0x80000000'u32]:
  for pattern in 0 ..< 64:
    for fine in 0 ..< 4:
      rccalSetup()
      let target = ((baseline.uint64 * 81) and 0xFFFFFFFF'u64).uint32 div 100
      let abovePower = max(target + 1, 65'u32)
      scriptedPower = @[baseline]
      var wantedCodes: seq[uint32]
      var wantedPowers: seq[uint32]
      var code = 0'i32
      for bit in countdown(5, 0):
        let candidate = code + (1'i32 shl bit)
        let above = (pattern and (1 shl bit)) != 0
        let power = if above: abovePower else: target
        wantedCodes.add(candidate.uint32 and 63)
        wantedPowers.add(power)
        scriptedPower.add(power)
        if above: code = candidate
      var history = 0
      var ok = false
      for attempt in 0 ..< 63:
        let above = case fine
          of 0: true
          of 1: false
          of 2: attempt mod 3 in [0, 2]
          else: attempt mod 5 in [0, 1, 3]
        let power = if above: abovePower else: target
        wantedCodes.add(cast[uint32](code) and 63)
        wantedPowers.add(power)
        scriptedPower.add(power)
        history = ((history shl 1) or (if above: 1 else: 0)) and 15
        code += (if above: 1 else: -1)
        if (above and history == 5) or (not above and history == 10):
          ok = true
          break
      powerIndex = 0
      primes = 0
      tones = 0
      publications = 0
      codes.setLen(0)
      for index in 0 ..< 32:
        nim_wifi_rf_rccal_search_log[index] = high(uint32)
        nim_wifi_rf_rccal_power_log[index] = high(uint32)
      let result = chooseRfRccalCode()
      doAssert result.ok == ok and result.code == wantedCodes[^1]
      doAssert codes == wantedCodes and powerIndex == scriptedPower.len,
        "RCCAL candidate/history sequence or byte wrapping differs"
      doAssert primes == 1 and tones == 1 and publications == 0
      doAssert nim_wifi_rf_last_rccal_baseline == baseline and nim_wifi_rf_last_rccal_target == target
      doAssert nim_wifi_rf_last_rccal_code == wantedCodes[^1]
      doAssert nim_wifi_rf_last_rccal_power == wantedPowers[^1]
      for index in 0 ..< min(wantedCodes.len, 32):
        doAssert nim_wifi_rf_rccal_power_log[index] == wantedPowers[index]
        doAssert nim_wifi_rf_rccal_search_log[index] ==
          ((wantedCodes[index] shl 24) or (wantedPowers[index] and 0xFFFFFF))
      for index in min(wantedCodes.len, 32) ..< 32:
        doAssert nim_wifi_rf_rccal_power_log[index] == 0 and nim_wifi_rf_rccal_search_log[index] == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_search_and_sampling_integrate_without_record_side_effects(tmp_path: Path, mode: str) -> None:
    code = rccal_source((
        "signedRfPowerMeasurement", "squareRfSample", "saturatingRfUint32",
        "waitRfRccalMeasurementReady", "sampleRfRccalPower", "primeRfRccalPowerMeasurement",
        "writeRfRccalCode", "publishRfRccalResults", "writeRfRccalSearchCode",
        "prepareRfPriRccalTone", "logRfRccalSearch", "chooseRfRccalCode",
    ))
    run_program(tmp_path, mode, code + r'''
for baselineI in [0'i32, 1, 64, 32767, -32768]:
  for pattern in [0, 21, 42, 63]:
    rccalSetup()
    readyAfter = 1
    let before = calibration
    let before80 = rf70.rbbRccalCtrl80
    let baselinePower = (baselineI.int64 * baselineI.int64).uint32
    let target = ((baselinePower.uint64 * 81) and 0xFFFFFFFF'u64).uint32 div 100
    adcValues = @[(1234'u32, 0'u32), (cast[uint32](baselineI) shl 9, 0'u32)]
    var wanted: seq[uint32]
    var code = 0'i32
    for bit in countdown(5, 0):
      let candidate = code + (1'i32 shl bit)
      let above = (pattern and (1 shl bit)) != 0
      adcValues.add(if above: (0x01000000'u32, 0x01000000'u32) else: (0'u32, 0'u32))
      wanted.add(candidate.uint32 and 63)
      if above: code = candidate
    var history = 0
    var ok = false
    for attempt in 0 ..< 63:
      let above = attempt mod 3 in [0, 2]
      adcValues.add(if above: (0x01000000'u32, 0x01000000'u32) else: (0'u32, 0'u32))
      wanted.add(cast[uint32](code) and 63)
      history = ((history shl 1) or (if above: 1 else: 0)) and 15
      code += (if above: 1 else: -1)
      if (above and history == 5) or (not above and history == 10):
        ok = true
        break
    let result = chooseRfRccalCode()
    doAssert result.ok == ok and result.code == wanted[^1]
    doAssert adcIndex == adcValues.len and calibration == before
    doAssert nim_wifi_rf_last_rccal_target == target
    doAssert rf70.rbbRccalCtrl80 == before80
    var actual: seq[uint32]
    for event in events:
      doAssert event.address != 0, "RCCAL search inserts a settling delay absent from vendor"
      if event.address == cast[uint](addr rf70.rccalReplay84): actual.add((event.value shr 24) and 63)
    doAssert actual == wanted
    var iReads, qReads: int
    for address in mmioReads:
      if address == cast[uint](addr rf70.measureI620): inc iReads
      if address == cast[uint](addr rf70.measureQ624): inc qReads
    doAssert iReads == adcValues.len and qReads == adcValues.len - 1
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_coordinator_publishes_before_restore_and_preserves_completion_modes(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = rccal_source(("writeRfRccalCode", "publishRfRccalResults")) + r'''
var
  success: bool
  expectedCalibration: array[96, uint32]
  restored90, search84: uint32
  restores: int
proc saveRfPriCalState(): uint32 = 0
proc prepareRfPriRccal() = discard
proc chooseRfRccalCode(): tuple[ok: bool, code: uint32] =
  volatileStore(addr rf70.rccalReplay84, search84)
  (success, 7'u32) # Publication must read hardware, not this diagnostic value.
proc restoreRfPriCalState(saved: uint32) =
  doAssert calibration == expectedCalibration, "RCCAL restored state before publishing its saved result"
  inc restores
  volatileStore(addr rf70.calPathCtrl90, restored90)
'''
    code += procedure(rf, "runRfPriRccal")
    run_program(tmp_path, mode, code + r'''
for supported in [false, true]:
  for ok in [false, true]:
    for vector in 0 ..< 1000:
      rccalSetup()
      success = ok
      restores = 0
      rf70.capability20 = if supported: 0x400'u32 else: 0'u32
      let initialMode = rf70.calMode14
      restored90 = randomWord()
      search84 = randomWord()
      let upper = (search84 shr 24) and 63
      let lower = (search84 shr 8) and 63
      expectedCalibration = calibration
      if supported:
        expectedCalibration[2] = (expectedCalibration[2] and 0xFF000000'u32) or
          upper or (upper shl 6) or (lower shl 12) or (lower shl 18)
      runRfPriRccal()
      doAssert calibration == expectedCalibration
      doAssert restores == supported.int and workarounds == 0
      let wantedMode = if not supported: initialMode and 0xFFF3FFFF'u32
        elif ok: initialMode or 0xC0000'u32
        else: (initialMode and 0xFFF3FFFF'u32) or 0x80000
      doAssert rf70.calMode14 == wantedMode
      if supported:
        doAssert rf70.calPathCtrl90 == (restored90 and 0xFFFFEFFF'u32)
        doAssert (rf70.rccalReplay84 and 0x3F3F3F3F'u32) ==
          (upper or (upper shl 8) or (upper shl 16) or (upper shl 24))
      else:
        doAssert events == @[(cast[uint](addr rf70.calMode14), wantedMode)]
''')


def calibration_lifecycle_source() -> str:
    rf = RF.read_text()
    code = rccal_source(()).replace("proc rfPriApplyWb03RccalSeed() = inc workarounds\n", "")
    code += object_type(rf, "RfDfeInitBlock")
    code += r'''
var
  dfe: RfDfeInitBlock
  measuredWord, bl808RfColdInit, bl808RfMode: uint32
  calibrationReplays: int
  wlCalGlobal: pointer
proc rfDfeInitRegs(): ptr RfDfeInitBlock = addr dfe
proc radioPhyModeFromApi(mode: uint8): uint32 = mode.uint32
proc nim_wifi_rf_pri_init_entry_breakpoint() = discard
proc rfPriEnsureDeviceInfo() = discard
proc rf_pri_init_calib_mem() = rfCalibDataGlobal = wlCalGlobal
proc rfPriEfuseInit() = discard
proc rf_pri_xtalfreq() = discard
proc writeRfPriFixedValueRegs() = discard
proc rfPriWifiPllConfig() = discard
proc rfPriApplyWb03RfcEntryBaseline() = discard
proc runRfPriLoFcal() = discard
proc runRfPriLoAcal() = discard
proc runRfPriRoscal() = discard
proc runRfPriRccal() =
  rfCalibSetWord(2, measuredWord)
  let upper = measuredWord and 63
  updateReg32(addr rf70.rccalReplay84, 0xC0C0C0C0'u32,
    upper or (upper shl 8) or (upper shl 16) or (upper shl 24))
proc runRfPriTxcal() = discard
proc runRfPriBzTxcal() = discard
proc rfPriSeedBzTxcalFallbackRecords() = discard
proc runRfPriRxcal() = discard
proc rfPriSnapshotStage(tag: uint32) = discard
proc rfPriReplayWb03Rf70FromTxcalCalWords() = discard
proc replayRfPriCalRegisters() =
  inc calibrationReplays
  let word = rfCalibWord(2)
  updateReg32(addr rf70.rccalReplay84, 0xC0C0C0C0'u32,
    ((word and 63) shl 24) or (((word shr 6) and 63) shl 16) or
    (((word shr 12) and 63) shl 8) or ((word shr 18) and 63))
'''
    if "proc rfPriApplyWb03RccalSeed(" in rf:
        code += procedure(rf, "rfPriApplyWb03RccalSeed")
    code += procedure(rf, "runRfPriFullCalRestoreBaseline")
    code += procedure(rf, "rf_pri_init")
    return code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_full_calibration_and_cold_warm_init_keep_measured_rccal_records(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, calibration_lifecycle_source() + r'''
for board in [false, true]:
  for path in 0 ..< 3:
    for vector in 0 ..< 1000:
      rccalSetup()
      calibrationReplays = 0
      wb03 = board
      wlCalGlobal = addr calibration[0]
      let upper = randomWord() and 63
      let lower = randomWord() and 63
      measuredWord = (calibration[2] and 0xFF000000'u32) or upper or (upper shl 6) or
        (lower shl 12) or (lower shl 18)
      if path == 2: calibration[2] = measuredWord
      var expected = calibration
      expected[2] = measuredWord
      case path
      of 0: runRfPriFullCalRestoreBaseline()
      of 1: rf_pri_init(1, 0)
      else: rf_pri_init(0, 0)
      doAssert calibration == expected, "calibration follow-up replaced measured RCCAL records"
      doAssert calibrationReplays == (if path == 2: 1 else: 0),
        "only warm initialization replays saved calibration registers"
      let physicalLower = if path == 2: lower else: upper
      doAssert (rf70.rccalReplay84 and 0x3F3F3F3F'u32) ==
        ((upper shl 24) or (upper shl 16) or (physicalLower shl 8) or physicalLower)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_initializer_final_synthesizer_enable_preserves_bit5(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, calibration_lifecycle_source() + r'''
for cold in [0'u32, 1]:
  for vector in 0 ..< 1000:
    rccalSetup()
    wlCalGlobal = addr calibration[0]
    measuredWord = calibration[2]
    let initial = randomWord() and 0xFFFFFFDF'u32
    rf70.synthCtrl2c = initial
    rf_pri_init(cold, 0)
    doAssert rf70.synthCtrl2c == (initial or 0x4027'u32),
      "RF initialization omitted the vendor synthesizer bit-5 enable"
''')
