"""TXCAL search, measurement, and saved-record contracts from rf_pri.c.o."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, array_constant
from test_wifi_rf_rxcal import rxcal_source


def txcal_source(names: tuple[str, ...]) -> str:
    rf = RF.read_text()
    code = rxcal_source(()).replace(
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
        "        doAssert adcIndex <= adcValues.len, \"TXCAL made an extra measurement\"",
    )
    for name in (
        "RfTxcalModeMask", "RfTxcalStartMode", "RfTxcalDoneMode",
        "RfTxcalParam0Mask", "RfTxcalParam1Mask", "RfTxcalParam2Mask",
        "RfTxcalParam2EnableBit", "RfTxcalParam3Mask", "RfTxcalParam3SignBit",
        "RfTxcalWaitLimit", "RfMeasureRccalTriggerMask", "RfMeasureFrequencyShift",
        "RfMeasureTriggerClearMask", "RfMeasureModeKeepMask", "RfMeasureStartMask",
        "RfTxcalAverageMeasureMode",
        "RfTxcalSampleTraceEntries", "RfPriTxcalSearchRecords", "RfPriBzTxcalSearchRecords",
        "RfTxcalGainAmp", "RfTxcalGainAdcMax", "RfTxcalGainAdcMin",
        "RfTxcalSearchFreqIq", "RfTxcalSearchFreqOsdac",
        "RfBzTxcalSearchFreqIq", "RfBzTxcalSearchFreqOsdac",
    ):
        lines = [line for line in rf.splitlines() if line.startswith("  " + name + " = ")]
        if lines:
            code += "const\n" + lines[0] + "\n"
    code += r'''
var
  nim_wifi_rf_txcal_wait_timeout_count, nim_wifi_rf_txcal_search_count: uint32
  nim_wifi_rf_txcal_sample_count, nim_wifi_rf_pri_txcal_count: uint32
  nim_wifi_rf_txcal_sample_param_log, nim_wifi_rf_txcal_sample_candidate_log: array[48, uint32]
  nim_wifi_rf_txcal_sample_freq_log, nim_wifi_rf_txcal_sample_ctrl_log: array[48, uint32]
  nim_wifi_rf_txcal_sample_i_log, nim_wifi_rf_txcal_sample_q_log: array[48, uint32]
  nim_wifi_rf_txcal_sample_power_log: array[48, uint32]
  lastWifiRfTxcalRecordWord0, lastWifiRfTxcalRecordWord1: uint32
  wifiRfTxcalRecordWord0Log, wifiRfTxcalRecordWord1Log: array[18, uint32]
  nim_wifi_rf_txcal_power_log, nim_wifi_rf_txcal_amp_log: array[18, uint32]
  nim_wifi_rf_bz_txcal_word0_log, nim_wifi_rf_bz_txcal_word1_log: array[9, uint32]
  nim_wifi_rf_bz_txcal_ok_mask_log, nim_wifi_rf_bz_txcal_power_log: array[9, uint32]
'''
    for name in names:
        if f"proc {name}(" in rf:
            code += procedure(rf, name)
    return code


ENCODERS = ("clampRfTxcalParam", "encodeRfTxcalParam3", "writeRfTxcalParam")
SAMPLER = (
    "signedRfPowerMeasurement", "squareRfSample", "saturatingRfUint32",
    "waitRfTxcalMeasurementReady", *ENCODERS,
    "sampleRfTxcalPower", "measureRfTxcalCandidate",
)


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_parameter_encoding_masks_raw_values_without_clamping(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, txcal_source(ENCODERS) + r'''
for parameter in [0'u32, 1, 2, 3, 4, high(uint32)]:
  for value in [low(int32), -65537, -513, -512, -1, 0, 63, 64, 511, 512, 2047, 2048, high(int32)]:
    rxcalSetup()
    var expected = registerStorage
    let raw = cast[uint32](value)
    let offset = if parameter <= 1: 0x74 else: 0x600
    let before = expected[offset div 4]
    case parameter
    of 0: expected[offset div 4] = (before and 0xC0FFFFFF'u32) or ((raw shl 24) and 0x3F000000)
    of 1: expected[offset div 4] = (before and 0xFFC0FFFF'u32) or ((raw shl 16) and 0x3F0000)
    of 2: expected[offset div 4] = (before and 0xFF800FFF'u32) or ((raw shl 12) and 0x7FF000) or 0x800000
    of 3: expected[offset div 4] = (before and 0xFFFFFC00'u32) or (raw and 0x3FF) or 0x400
    else: discard
    writeRfTxcalParam(parameter, value)
    doAssert registerStorage == expected, "TXCAL encoder clamps values or changes unowned bits"
    if parameter <= 3:
      doAssert events == @[(cast[uint](addr registerStorage[offset div 4]), expected[offset div 4])]
    else: doAssert events.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_ready_wait_preserves_busy_polling_and_never_returns_unfinished_data(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, txcal_source(("waitRfTxcalMeasurementReady",)) + r'''
for delay in [10001, 0, 1, 20017]:
  rxcalSetup()
  pending = true
  readyAfter = delay
  let before = registerStorage
  let previous = nim_wifi_rf_txcal_wait_timeout_count
  doAssert waitRfTxcalMeasurementReady(), "TXCAL returned before READY"
  doAssert polls == delay + 1 and events.len == 0 and registerStorage == before
  doAssert nim_wifi_rf_txcal_wait_timeout_count == previous + (delay div RfTxcalWaitLimit).uint32
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_sampler_initializes_once_and_keeps_signed_power_and_bounded_trace(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, txcal_source(SAMPLER) + r'''
proc measure(freq: uint32; initial: bool): tuple[ok: bool, power: uint32] =
  when compiles(measureRfTxcalCandidate(2'u32, 0x345'i32, freq, initial)):
    measureRfTxcalCandidate(2'u32, 0x345'i32, freq, initial)
  else: measureRfTxcalCandidate(2'u32, 0x345'i32, freq)
for freq in [0x49'u32, 0x92, 0x8123, 0x40000000]:
  for initial in [true, false]:
    for pair in [(-32768'i32, -32768'i32), (-1'i32, 0'i32), (0'i32, 1'i32), (32767'i32, -12345'i32)]:
      rxcalSetup()
      let (i, q) = pair
      let rawI = (cast[uint32](i) shl 9) or 0xAA000155'u32
      let rawQ = (cast[uint32](q) shl 9) or 0x540000AA'u32
      adcValues = @[(rawI, rawQ)]
      readyAfter = 10001
      nim_wifi_rf_txcal_sample_count = 2 * 48 + 7
      var expected = registerStorage
      var trace: seq[tuple[address: uint, value: uint32]]
      template put(offset: int; keep, value: uint32) =
        expected[offset div 4] = (expected[offset div 4] and keep) or value
        trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
      put(0x600, 0xFF800FFF'u32, 0xB45000)
      trace.add((0'u, 10'u32))
      if initial: put(0x618, 0xFFF00000'u32, freq shl 9)
      put(0x618, 0xDFEFFFFF'u32, 0)
      put(0x618, 0xFFFFFFFF'u32, 0x20100000)
      expected[0x618 div 4] = expected[0x618 div 4] or 0x10000000'u32
      let captured = expected[0x618 div 4]
      put(0x618, 0xDFEFFFFF'u32, 0)
      let sample = measure(freq, initial)
      let power = (i.int64 * i.int64 + q.int64 * q.int64).uint32
      doAssert sample.ok and sample.power == power and adcIndex == 1 and not pending
      doAssert events == trace, "TXCAL sampling trace differs: " & $freq & " " & $initial & " " & $events & " vs " & $trace
      doAssert registerStorage == expected, "TXCAL sampling register fields differ"
      doAssert nim_wifi_rf_txcal_sample_count == 104
      doAssert nim_wifi_rf_txcal_sample_param_log[7] == 2
      doAssert nim_wifi_rf_txcal_sample_candidate_log[7] == 0x345
      doAssert nim_wifi_rf_txcal_sample_freq_log[7] == freq
      doAssert nim_wifi_rf_txcal_sample_i_log[7] == rawI and nim_wifi_rf_txcal_sample_q_log[7] == rawQ
      doAssert nim_wifi_rf_txcal_sample_power_log[7] == power and nim_wifi_rf_txcal_sample_ctrl_log[7] == captured
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_shared_wait_keeps_average_and_adc_mean_readers_complete(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = txcal_source((
        "signedRfAverageMeasurement", "signedRfAverageAdcMean",
        "waitRfTxcalMeasurementReady", "sampleRfTxcalAdcMean",
    ))
    # The firmware has an earlier forward declaration for the RF70 caller.
    code += rf[rf.rindex("\nproc sampleRfTxcalAverage(") + 1:].split("\nproc ", 1)[0] + "\n"
    run_program(tmp_path, mode, code + r'''
for delay in [0, 1, 10001, 20017]:
  for average in [false, true]:
    for raw in [0'u32, 0xFFFFFFFF'u32, 0x01000000'u32, 0x00FFFFFF'u32, 0xAAABCDEF'u32]:
      rxcalSetup()
      readyAfter = delay
      adcValues = @[(raw, 0'u32)]
      var expected = registerStorage
      var trace: seq[tuple[address: uint, value: uint32]]
      template put(offset: int; keep, value: uint32) =
        expected[offset div 4] = (expected[offset div 4] and keep) or value
        trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
      put(0x618, 0xDFEFFFFF'u32, 0)
      put(0x61C, 0xFFFF'u32, 0x4000000)
      put(0x618, 0xFFFFFFFF'u32, 0x20000000)
      expected[0x618 div 4] = expected[0x618 div 4] or 0x10000000'u32
      put(0x618, 0xDFEFFFFF'u32, 0)
      let sample = if average:
          let captured = sampleRfTxcalAverage()
          (ok: captured.ok, value: captured.value)
        else: sampleRfTxcalAdcMean()
      let bits = if average: 25 else: 15
      let unsigned = (raw shr (if average: 0 else: 10)) and ((1'u32 shl bits) - 1)
      let wanted = unsigned.int32 - (if (unsigned and (1'u32 shl (bits - 1))) != 0: (1'i32 shl bits) else: 0'i32)
      doAssert sample.ok and sample.value == wanted
      doAssert adcIndex == 1 and not pending and events == trace and registerStorage == expected
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_search_decisions_raw_center_zero_delta_and_caller_owned_final_write(tmp_path: Path, mode: str) -> None:
    code = txcal_source(("clampRfTxcalParam",)) + r'''
var
  scriptedPower: seq[uint32]
  measured: seq[tuple[value: int32, initial: bool]]
  measurementIndex, explicitWrites: int
proc writeRfTxcalParam(parameter: uint32; value: int32) = inc explicitWrites
proc measureRfTxcalCandidate(parameter: uint32; value: int32; freq: uint32; initial = false):
    tuple[ok: bool, power: uint32] =
  doAssert freq == 0x92 and measurementIndex < scriptedPower.len
  measured.add((value, initial))
  result = (true, scriptedPower[measurementIndex])
  inc measurementIndex
'''
    code += procedure(RF.read_text(), "searchRfTxcalParam")
    run_program(tmp_path, mode, code + r'''
for parameter in [0'u32, 1, 2, 3]:
  let lo = if parameter == 3: -512'i32 else: 0'i32
  let hi = if parameter <= 1: 63'i32 elif parameter == 2: 2047'i32 else: 511'i32
  for center in [lo - 64, lo, (lo + hi + 1) div 2, hi, hi + 64]:
    for delta in [0'i32, 1, 8, 16, 32, 64, 128]:
      var levels = 1
      var remaining = delta
      while remaining > 1:
        inc levels
        remaining = remaining div 2
      var patterns = 1
      for _ in 0 ..< levels: patterns *= 3
      for pattern in 0 ..< patterns:
        scriptedPower = @[0x80000100'u32]
        var expected = @[(center, true)]
        var best = center
        var power = scriptedPower[0]
        var decision = pattern
        var step = delta
        while true:
          let left = max(lo, best - step)
          let right = min(hi, best + step)
          let choice = decision mod 3
          decision = decision div 3
          expected.add((left, false))
          if choice == 0:
            dec power
            scriptedPower.add(power)
            best = left
          else:
            scriptedPower.add(power)
            expected.add((right, false))
            if choice == 1:
              dec power
              scriptedPower.add(power)
              best = right
            else: scriptedPower.add(power)
          step = step div 2
          if step == 0: break
        measured.setLen(0)
        measurementIndex = 0
        explicitWrites = 0
        let result = searchRfTxcalParam(parameter, center, delta, 0x92)
        doAssert result.ok and result.value == best and result.power == power
        doAssert measured == expected and measurementIndex == scriptedPower.len,
          "TXCAL search decision, endpoint, tie, or sample order differs"
        doAssert explicitWrites == 0, "TXCAL final code programming belongs to the caller"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_search_integrates_without_extra_setup_samples_or_writes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, txcal_source((*SAMPLER, "searchRfTxcalParam")) + r'''
for parameter in [0'u32, 1, 2, 3]:
  let lo = if parameter == 3: -512'i32 else: 0'i32
  let hi = if parameter <= 1: 63'i32 elif parameter == 2: 2047'i32 else: 511'i32
  for center in [lo, (lo + hi + 1) div 2, hi]:
    for delta in [0'i32, 1, 16, 64, 128]:
      for choice in 0 ..< 3:
        rxcalSetup()
        readyAfter = 1
        var codes = @[center]
        var best = center
        var amplitude = 100'i32
        adcValues = @[((amplitude.uint32 shl 9), 0'u32)]
        var step = delta
        while true:
          let left = max(lo, best - step)
          let right = min(hi, best + step)
          codes.add(left)
          if choice == 0:
            dec amplitude
            best = left
            adcValues.add((amplitude.uint32 shl 9, 0'u32))
          else:
            adcValues.add((amplitude.uint32 shl 9, 0'u32))
            codes.add(right)
            if choice == 1:
              dec amplitude
              best = right
            adcValues.add((amplitude.uint32 shl 9, 0'u32))
          step = step div 2
          if step == 0: break
        let offset = if parameter <= 1: 0x74 else: 0x600
        let initialRegister = registerStorage[offset div 4]
        let result = searchRfTxcalParam(parameter, center, delta, 0x49)
        doAssert result.ok and result.value == best and result.power == (amplitude * amplitude).uint32
        doAssert adcIndex == adcValues.len
        var wantedCodes: seq[uint32]
        for code in codes:
          let raw = cast[uint32](code)
          wantedCodes.add(case parameter
            of 0: (initialRegister and 0xC0FFFFFF'u32) or ((raw shl 24) and 0x3F000000)
            of 1: (initialRegister and 0xFFC0FFFF'u32) or ((raw shl 16) and 0x3F0000)
            of 2: (initialRegister and 0xFF800FFF'u32) or ((raw shl 12) and 0x7FF000) or 0x800000
            else: (initialRegister and 0xFFFFFC00'u32) or (raw and 0x3FF) or 0x400)
        var actualCodes: seq[uint32]
        var controlWrites, delays: int
        for event in events:
          if event.address == cast[uint](addr registerStorage[offset div 4]): actualCodes.add(event.value)
          if event.address == cast[uint](addr rf70.measureCtrl618): inc controlWrites
          if event.address == 0:
            doAssert event.value == 10
            inc delays
        doAssert actualCodes == wantedCodes and registerStorage[offset div 4] == wantedCodes[^1]
        doAssert delays == codes.len and controlWrites == 1 + 3 * codes.len
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_saved_records_keep_bytes_signed_halfwords_padding_and_bounds(tmp_path: Path, mode: str) -> None:
    code = txcal_source((
        "clampRfTxcalParam", "encodeRfTxcalParam3", "rfCalibSetByte", "rfCalibSetHalf",
        "rfCalibStoreBzTxcalRecordWords", "packRfTxcalCalWord0", "packRfTxcalCalWord1",
        "storeRfTxcalRecord", "storeRfPriBzTxcalRecord",
    ))
    run_program(tmp_path, mode, code + r'''
for bz in [false, true]:
  let rows = if bz: 9 else: 18
  for row in 0 ..< rows:
    for vector in 0 ..< 1100:
      rxcalSetup()
      let p0 = cast[int32](randomWord())
      let p1 = cast[int32](randomWord())
      let p2 = cast[int32](randomWord())
      let p3 = if vector <= 1023: vector.int32 - 512 else: cast[int32](randomWord())
      let offset = (if bz: 0xF8 else: 0x68) + row * 8
      var expected = calibration
      let bytes = cast[ptr UncheckedArray[uint8]](addr expected[0])
      let halves = cast[ptr UncheckedArray[uint16]](addr expected[0])
      bytes[offset] = (cast[uint32](p0) and 255).uint8
      bytes[offset + 1] = (cast[uint32](p1) and 255).uint8
      halves[(offset + 2) div 2] = (cast[uint32](p2) and 65535).uint16
      halves[(offset + 4) div 2] = (cast[uint32](p3) and 65535).uint16
      if bz:
        storeRfPriBzTxcalRecord(row, p0, p1, p2, p3)
        doAssert nim_wifi_rf_bz_txcal_word0_log[row] == expected[offset div 4]
        doAssert nim_wifi_rf_bz_txcal_word1_log[row] == (cast[uint32](p3) and 65535)
      else:
        storeRfTxcalRecord(row, p0, p1, p2, p3, 0xF00D)
        doAssert wifiRfTxcalRecordWord0Log[row] == expected[offset div 4]
        doAssert wifiRfTxcalRecordWord1Log[row] == (cast[uint32](p3) and 65535)
        doAssert nim_wifi_rf_txcal_power_log[row] == 0xF00D
      doAssert calibration == expected, "TXCAL saved fields or padding differ from vendor"
rxcalSetup()
let before = calibration
for index in [-1, 18, 127]: storeRfTxcalRecord(index, 0, 0, 0, 0, 0)
for index in [-1, 9, 127]: storeRfPriBzTxcalRecord(index, 0, 0, 0, 0)
rfCalibDataGlobal = nil
storeRfTxcalRecord(0, 0, 0, 0, 0, 0)
storeRfPriBzTxcalRecord(0, 0, 0, 0, 0)
doAssert calibration == before and events.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("bz", [False, True])
def test_callers_program_every_result_and_use_vendor_frequencies(tmp_path: Path, mode: str, bz: bool) -> None:
    rf = RF.read_text()
    code = txcal_source(())
    code = code.replace("doAssert tag in [0xB1'u32, 0xB2, 0xB5]", "discard tag")
    for name in ("RfPriTxcalParams", "RfPriBzTxcalParams", "RfPriBzTxcalPowerSetup"):
        if "  " + name + ":" in rf:
            code += array_constant(rf, name)
    code += r'''
var
  rfTxcalOsdacCode: uint32
  inputs: seq[tuple[parameter: uint32, center, delta: int32, freq: uint32]]
  programmed: seq[tuple[parameter: uint32, value: int32]]
const Results = [20'i32, 21, 22, 23, 1000, -32, 1100, -25]
proc saveRfPriCalState(): uint32 = 0
proc restoreRfPriCalState(saved: uint32) = discard
proc prepareRfPriTxcal() = discard
proc prepareRfPriBzTxcal() = discard
proc rfPriPopulateWb03TxcalRf70ReplayFields() = discard
proc rfPriPopulateTxcalRf70ReplayFields() = discard
proc publishRfTxcalActiveRecord() = discard
proc rfPriApplyTxcalLowBandRf70ReplayNibble() = discard
proc chooseRfTxcalMixerCs(): uint32 = 0
proc chooseRfTxcalOsdacCode(): uint32 = 0
proc prepareRfTxcalSearchStage() = discard
proc configureRfPriTxcalGain(index: int; params: array[7, uint32]) = discard
proc configureRfPriTxcalGain(power: array[9, uint16]; params: array[7, uint32]) = discard
proc configureRfPriTxcalGain(power: RfPriTxPowerTableRow; params: array[7, uint32]) = discard
proc tuneRfTxcalSingenPower(amp: uint32; hi, lo: int32): uint32 = amp
proc tuneRfTxcalRowPower(target, code: uint32): uint32 = target
proc primeRfTxcalSearch() = discard
proc writeRfTxcalParam(parameter: uint32; value: int32) = programmed.add((parameter, value))
proc searchRfTxcalParam(parameter: uint32; center, delta: int32; freq: uint32):
    tuple[ok: bool, value: int32, power: uint32] =
  doAssert programmed.len == inputs.len, "TXCAL caller did not program the previous search result"
  let index = inputs.len mod 8
  inputs.add((parameter, center, delta, freq))
  (true, Results[index], (index + 1).uint32)
proc storeRfTxcalRecord(row: int; p0, p1, p2, p3: int32; power: uint32) =
  doAssert [p0, p1, p2, p3] == [22'i32, 23, 1100, -25]
proc storeRfPriBzTxcalRecord(row: int; p0, p1, p2, p3: int32) =
  doAssert [p0, p1, p2, p3] == [22'i32, 23, 1100, -25]
'''
    name = "runRfPriBzTxcal" if bz else "runRfPriTxcal"
    code += procedure(rf, name)
    code += f"\nconst Rows = {9 if bz else 18}\n"
    run_program(tmp_path, mode, code + f"\nrxcalSetup()\n{name}()\n" + r'''
doAssert inputs.len == 8 * Rows and programmed.len == inputs.len
let expected = @[(0'u32, 32'i32, 16'i32, 0x49'u32), (1'u32, 32'i32, 16'i32, 0x49'u32),
                 (0'u32, 20'i32, 8'i32, 0x49'u32), (1'u32, 21'i32, 8'i32, 0x49'u32),
                 (2'u32, 1024'i32, 128'i32, 0x92'u32), (3'u32, 0'i32, 64'i32, 0x92'u32),
                 (2'u32, 1000'i32, 64'i32, 0x92'u32), (3'u32, -32'i32, 32'i32, 0x92'u32)]
for index in 0 ..< inputs.len:
  doAssert inputs[index] == expected[index mod 8], "TXCAL search arguments differ from vendor"
  doAssert programmed[index] == (expected[index mod 8][0], Results[index mod 8])
''')
