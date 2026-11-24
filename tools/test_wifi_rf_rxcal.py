"""RXCAL setup, search sampling, and saved-record ownership from rf_pri.c.o."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, source


def rxcal_source(names: tuple[str, ...]) -> str:
    rf = RF.read_text()
    code = source(real_io=True)
    constants = (
        "RfRxcalModeMask", "RfRxcalStartMode", "RfRxcalDoneMode",
        "RfRxcalSearchLowMask", "RfRxcalSearchHighMask", "RfRxcalSearchHighEnable",
        "RfRxcalMeasureClearMask", "RfRxcalMeasureSetupMask", "RfMeasureReadyMask",
        "RfRxcalWaitLimit", "RfCalibRf70ReplayLowBandWordIndex", "RfCtrlTuneEnableMask",
        "WlRfCfgRxcalA8Offset", "WlRfCfgRxcalAcOffset",
    )
    code += "const\n" + "".join(
        next(line for line in rf.splitlines() if line.startswith("  " + name + " = ")) + "\n"
        for name in constants
    )
    code = code.replace(
        "proc rfPriRf70ReplayWindow0Nibble(): uint32 = 9",
        "proc rfPriRf70ReplayWindow0Nibble(): uint32",
    ).replace(
        "proc volatileLoad(p: ptr uint32): uint32 =",
        "var\n"
        "  events: seq[tuple[address: uint, value: uint32]]\n"
        "  adcValues: seq[tuple[i, q: uint32]]\n"
        "  adcIndex, polls, readyAfter: int\n"
        "  pending: bool\n"
        "proc volatileLoad(p: ptr uint32): uint32 =",
    ).replace(
        "  p[]\nproc volatileStore",
        "  if p == (addr rf70.measureCtrl618) and pending:\n"
        "    inc polls\n"
        "    return (p[] and not 0x10000000'u32) or\n"
        "      (if polls > readyAfter: 0x10000000'u32 else: 0'u32)\n"
        "  if (p == (addr rf70.measureI620) or p == (addr rf70.measureQ624)) and adcValues.len != 0:\n"
        "    doAssert pending and polls > readyAfter, \"RXCAL read an unfinished sample\"\n"
        "    doAssert adcIndex < adcValues.len\n"
        "    if p == (addr rf70.measureI620): return adcValues[adcIndex].i\n"
        "    result = adcValues[adcIndex].q\n"
        "    inc adcIndex\n    return\n"
        "  p[]\nproc volatileStore",
    ).replace(
        "  if recordWrites: mmioWrites.add((address, value))",
        "  if recordWrites:\n"
        "    mmioWrites.add((address, value))\n"
        "    events.add((address, value))\n"
        "  if p == (addr rf70.measureCtrl618):\n"
        "    if (p[] and 0x20000000'u32) == 0 and (value and 0x20000000'u32) != 0:\n"
        "      pending = true\n      polls = 0\n"
        "    elif (value and 0x20000000'u32) == 0: pending = false",
    )
    code += procedure(rf, "rfCalibSetWord").replace(
        "proc rfCalibSetWord(", "proc rawRfCalibSetWord(", 1
    )
    code += r'''
var
  nim_wifi_rf_pri_rxcal_count, nim_wifi_rf_rxcal_search_count: uint32
  nim_wifi_rf_rxcal_wait_timeout_count, nim_wifi_rf_last_rxcal_power: uint32
  lastWifiRfRxcalRecordWord0, lastWifiRfRxcalRecordWord1: uint32
  wifiRfRxcalRecordWord0Log, wifiRfRxcalRecordWord1Log: array[4, uint32]
  nim_wifi_rf_rxcal_power_log: array[4, uint32]
  wlCfgStorage: array[256, uint8]
  wlCfgGlobal: pointer
  checkpoints: seq[uint32]
  workarounds: int
proc rfCalibSetWord(index: int; value: uint32) =
  events.add((cast[uint](rfCalibDataGlobal) + (index * 4).uint, value))
  rawRfCalibSetWord(index, value)
proc waitRfUs(us: uint32) = events.add((0'u, us))
proc rfPhyTraceCheckpoint(tag: uint32) = checkpoints.add(tag)
proc rfPriApplyWb03RuntimeLatches() = inc workarounds
proc rfPriApplyWb03RxcalTosdacLatch() = inc workarounds
proc rfPriConfigChannelForCal(channel: int) = events.add((1'u, channel.uint32))
'''
    for name in (
        "rfCalibRf70ReplayLowBandWord", "rfPriRf70ReplayWindow0Nibble",
        *names,
    ):
        if f"proc {name}(" in rf:
            body = procedure(rf, name)
            if name == "rfPriRf70ReplayWindow0Nibble":
                body = body.replace(" {.inline.}", "")
            code += body
    return code + r'''
proc rxcalSetup() =
  setup()
  rfCalibDataGlobal = addr calibration[0]
  wlCfgGlobal = addr wlCfgStorage[0]
  for word in calibration.mitems: word = randomWord()
  for word in registerStorage.mitems: word = randomWord()
  for value in wlCfgStorage.mitems: value = (randomWord() and 255).uint8
  events.setLen(0)
  adcValues.setLen(0)
  adcIndex = 0
  polls = 0
  readyAfter = 0
  pending = false
  checkpoints.setLen(0)
  workarounds = 0
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_setup_uses_saved_txcal_active_gain_and_exact_mmio(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, rxcal_source(("prepareRfPriRxcal",)) + r'''
for rowIndex in 0 ..< 18:
  for vector in 0 ..< 40:
    rxcalSetup()
    bl808RfTxPowerTableIndex[8] = rowIndex.int16
    bl808RfTxPowerTable[rowIndex][0] = cast[int16]((randomWord() and 65535).uint16)
    bl808RfTxPowerTable[rowIndex][3] = cast[int16]((randomWord() and 65535).uint16)
    let row = bl808RfTxPowerTable[rowIndex]
    let savedCalibration = calibration
    let savedConfig = wlCfgStorage
    var expected = registerStorage
    var trace: seq[tuple[address: uint, value: uint32]]
    var reads: seq[uint]
    template put(offset: int; keep, value: uint32) =
      expected[offset div 4] = (expected[offset div 4] and keep) or value
      trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
      if offset != 0x2C: reads.add(cast[uint](addr registerStorage[offset div 4]))
    put(0x04, 0xFFFFFFFD'u32, 0)
    put(0x2C, 0, 0)
    put(0x30, 0xFFFFFFFF'u32, 2)
    put(0x30, 0x8FFFFEFF'u32, 0x8FFF7E00'u32)
    trace.add((1'u, 9'u32))
    put(0xBC, 0xFFFFFFFF'u32, 0x20000000)
    put(0xB8, 0xFFFFFFFF'u32, 0x01000000)
    trace.add((0'u, 1'u32))
    put(0x23C, 0xFFFFFFFF'u32, 0x40000)
    put(0x220, 0xFFFFFE7F'u32, 0)
    put(0x220, 0xFFFFE7FF'u32, 0x1082)
    put(0x220, 0xFFFFFFEF'u32, 0x100)
    put(0x23C, 0xFFFFFFFF'u32, 0x40000)
    put(0x220, 0xFFFFFF9F'u32, 0)
    put(0x220, 0xFFFFFFFF'u32, 0x21)
    put(0x220, 0xFFFFFFFF'u32, 0x40)
    put(0x88, 0xFFFFFFFF'u32, 0x10000000)
    put(0x64, 0xFFFFFFFF'u32, 0x800000)
    put(0x70, 0xFFFFFFF0'u32, (calibration[3] shr 24) and 15)
    put(0x90, 0xFFFFFFCF'u32, 0x10)
    put(0x88, 0xFCFFFFFF'u32, 0x02000000)
    put(0x60, 0xFFFFFFFF'u32, 3)
    put(0x64, 0x0F83FFFF'u32, 0x201C0000)
    put(0x58, 0xFFF8FFFF'u32, 0x40000)
    # rf_pri_rxcal+0x194..0x1cc: both table fields precede the same store.
    put(0x48, 0xCE08FFFF'u32, ((cast[uint32](row[0].int32) and 3) shl 28) or
      ((cast[uint32](row[3].int32) and 31) shl 20) or 0x70000)
    put(0x68, 0x1DFFFFFF'u32, 0xA0000000'u32)
    put(0x48, 0xFFFF8CE0'u32, 0x311F)
    trace.add((0'u, 10'u32))
    # +0x206, +0x224, +0x244, +0x25c: one calibration load per RMW.
    reads.add(cast[uint](addr calibration[43]))
    put(0x600, 0xFFFFFC00'u32, (calibration[43] and 0x3FF) or 0x400)
    reads.add(cast[uint](addr calibration[42]))
    put(0x600, 0xFF800FFF'u32, ((calibration[42] shr 4) and 0x7FF000) or 0x800000)
    reads.add(cast[uint](addr calibration[42]))
    put(0x74, 0xC0FFFFFF'u32, (calibration[42] shl 24) and 0x3F000000'u32)
    reads.add(cast[uint](addr calibration[42]))
    put(0x74, 0xFFC0FFFF'u32, (calibration[42] shl 8) and 0x3F0000)
    put(0x61C, 0xFFFF'u32, 0x50000000)
    put(0x618, 0x3FFFFFFF'u32, 0x40000000)
    put(0x614, 0xFF800FFF'u32, 0xC00000)
    put(0x614, 0xFFFFFC00'u32, 0x400)
    put(0x20C, 0xFC00FFFF'u32, 0x400000)
    put(0x214, 0x3FFFFF'u32, 0x40000000)
    put(0x218, 0x3FFFFF'u32, 0)
    put(0x21C, 0xEFFFEFFF'u32, 0)
    put(0x214, 0xFFFFF800'u32, 0x110)
    put(0x218, 0xFFFFF800'u32, 0x110)
    put(0x20C, 0x7FFFFFFF'u32, 0)
    put(0x20C, 0xFFFFFFFF'u32, 0x80000000'u32)
    prepareRfPriRxcal()
    doAssert registerStorage == expected, "RXCAL setup fields differ from vendor"
    doAssert events == trace, "RXCAL setup write/delay order differs from vendor"
    doAssert mmioReads == reads, "RXCAL setup register or replay read order differs from vendor"
    doAssert calibration == savedCalibration and wlCfgStorage == savedConfig
    doAssert workarounds == 0 and checkpoints == @[0x30'u32, 0x31]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_candidate_fields_encode_raw_values_without_clamping(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, rxcal_source(("clampRfRxcalParam", "writeRfRxcalParam")) + r'''
for parameter in [2'u32, 3]:
  for value in [low(int32), -65537, -513, -512, -1, 0, 511, 512, 2047, 2048, 65535, high(int32)]:
    rxcalSetup()
    let before = registerStorage
    let initial = rf70.rxcalSearch614
    let wanted = if parameter == 2:
        (initial and 0xFF800FFF'u32) or ((cast[uint32](value) and 0x7FF) shl 12) or 0x800000
      else:
        (initial and 0xFFFFFC00'u32) or (cast[uint32](value) and 0x3FF) or 0x400
    writeRfRxcalParam(parameter, value)
    var expected = before
    expected[0x614 div 4] = wanted
    doAssert registerStorage == expected, "RXCAL candidate encoding clamps or changes unowned fields"
    doAssert events == @[(cast[uint](addr rf70.rxcalSearch614), wanted)]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_wait_does_not_return_before_ready(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, rxcal_source(("waitRfRxcalMeasurementReady",)) + r'''
for delay in [10001, 0, 1, 20017]:
  rxcalSetup()
  pending = true
  readyAfter = delay
  let before = registerStorage
  let previousStalls = nim_wifi_rf_rxcal_wait_timeout_count
  doAssert waitRfRxcalMeasurementReady(), "RXCAL wait returned before READY"
  doAssert polls == delay + 1 and events.len == 0
  doAssert registerStorage == before
  doAssert nim_wifi_rf_rxcal_wait_timeout_count == previousStalls + (delay div RfRxcalWaitLimit).uint32
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_sampler_setup_once_ready_polling_and_signed_power(tmp_path: Path, mode: str) -> None:
    code = rxcal_source((
        "signedRfPowerMeasurement", "squareRfSample", "saturatingRfUint32",
        "waitRfRxcalMeasurementReady", "clampRfRxcalParam", "writeRfRxcalParam",
        "sampleRfRxcalPower", "measureRfRxcalCandidate",
    ))
    run_program(tmp_path, mode, code + r'''
proc measure(initial: bool): tuple[ok: bool, power: uint32] =
  when compiles(measureRfRxcalCandidate(2'u32, 0x345'i32, initial)):
    measureRfRxcalCandidate(2'u32, 0x345'i32, initial)
  else: measureRfRxcalCandidate(2'u32, 0x345'i32)
for delay in [0, 1, 10001, 20017]:
  for initial in [true, false]:
    for pair in [(-32768'i32, -32768'i32), (-1'i32, 0'i32), (0'i32, 1'i32), (32767'i32, -12345'i32)]:
      rxcalSetup()
      let (i, q) = pair
      adcValues = @[((cast[uint32](i) shl 9) or 0xAA000155'u32,
                     (cast[uint32](q) shl 9) or 0x540000AA'u32)]
      readyAfter = delay
      let previousStalls = nim_wifi_rf_rxcal_wait_timeout_count
      var expected = registerStorage
      var trace: seq[tuple[address: uint, value: uint32]]
      template put(offset: int; keep, value: uint32) =
        expected[offset div 4] = (expected[offset div 4] and keep) or value
        trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
      put(0x614, 0xFF800FFF'u32, 0xB45000)
      trace.add((0'u, 10'u32))
      if initial: put(0x618, 0xFFF00000'u32, 0xF0000)
      put(0x618, 0xDFEFFFFF'u32, 0)
      put(0x618, 0xFFFFFFFF'u32, 0x20100000)
      expected[0x618 div 4] = expected[0x618 div 4] or 0x10000000'u32
      put(0x618, 0xDFEFFFFF'u32, 0)
      let sample = measure(initial)
      doAssert sample.ok
      doAssert sample.power == (i.int64 * i.int64 + q.int64 * q.int64).uint32
      doAssert adcIndex == 1 and not pending
      doAssert registerStorage == expected and events == trace,
        "RXCAL sampling setup, trigger, delay, or completion fields differ"
      doAssert nim_wifi_rf_rxcal_wait_timeout_count == previousStalls + (delay div RfRxcalWaitLimit).uint32
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_search_short_circuits_left_improvements_and_leaves_programming_to_caller(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = rxcal_source(("clampRfRxcalParam",)) + r'''
var
  scriptedPower: seq[uint32]
  measured: seq[tuple[value: int32, initial: bool]]
  measurementIndex, explicitWrites: int
proc writeRfRxcalParam(parameter: uint32; value: int32) = inc explicitWrites
proc measureRfRxcalCandidate(parameter: uint32; value: int32; initial = false):
    tuple[ok: bool, power: uint32] =
  doAssert measurementIndex < scriptedPower.len, "RXCAL made an extra measurement"
  measured.add((value, initial))
  result = (true, scriptedPower[measurementIndex])
  inc measurementIndex
'''
    code += procedure(rf, "searchRfRxcalParam")
    run_program(tmp_path, mode, code + r'''
for parameter in [2'u32, 3]:
  let lo = if parameter == 2: 0'i32 else: -512'i32
  let hi = if parameter == 2: 2047'i32 else: 511'i32
  for center in [lo, (lo + hi + 1) div 2, hi]:
    for delta in [0'i32, 1, 16, 32, 64]:
      var levels = 1
      var remaining = delta
      while remaining > 1:
        inc levels
        remaining = remaining div 2
      var patterns = 1
      for _ in 0 ..< levels: patterns *= 3
      for pattern in 0 ..< patterns:
        scriptedPower = @[1000'u32]
        var expected = @[(center, true)]
        var best = center
        var power = 1000'u32
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
            scriptedPower.add(power) # A tie must not select the left point.
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
        let result = searchRfRxcalParam(parameter, center, delta)
        doAssert result.ok and result.value == best and result.power == power
        doAssert measured == expected and measurementIndex == scriptedPower.len,
          "RXCAL search decision, tie, or sample order differs from vendor"
        doAssert explicitWrites == 0, "RXCAL search must leave final code programming to its caller"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_search_and_sampler_integrate_without_extra_samples_or_writes(tmp_path: Path, mode: str) -> None:
    code = rxcal_source((
        "signedRfPowerMeasurement", "squareRfSample", "saturatingRfUint32",
        "waitRfRxcalMeasurementReady", "writeRfRxcalParam",
        "sampleRfRxcalPower", "measureRfRxcalCandidate", "searchRfRxcalParam",
    ))
    run_program(tmp_path, mode, code + r'''
for parameter in [2'u32, 3]:
  let lo = if parameter == 2: 0'i32 else: -512'i32
  let hi = if parameter == 2: 2047'i32 else: 511'i32
  for center in [lo, (lo + hi + 1) div 2, hi]:
    for delta in [1'i32, 16, 64]:
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
        let initialRegister = rf70.rxcalSearch614
        let result = searchRfRxcalParam(parameter, center, delta)
        doAssert result.ok and result.value == best and result.power == (amplitude * amplitude).uint32
        doAssert adcIndex == adcValues.len
        var wantedCodes: seq[uint32]
        for code in codes:
          wantedCodes.add(if parameter == 2:
              (initialRegister and 0xFF800FFF'u32) or ((cast[uint32](code) and 0x7FF) shl 12) or 0x800000
            else: (initialRegister and 0xFFFFFC00'u32) or (cast[uint32](code) and 0x3FF) or 0x400)
        var actualCodes: seq[uint32]
        var controlWrites, delays: int
        for event in events:
          if event.address == cast[uint](addr rf70.rxcalSearch614): actualCodes.add(event.value)
          if event.address == cast[uint](addr rf70.measureCtrl618): inc controlWrites
          if event.address == 0:
            doAssert event.value == 10
            inc delays
        doAssert actualCodes == wantedCodes and rf70.rxcalSearch614 == wantedCodes[^1]
        doAssert delays == codes.len and controlWrites == 1 + 3 * codes.len
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_records_keep_signed_halfwords_and_mask_only_physical_lanes(tmp_path: Path, mode: str) -> None:
    code = rxcal_source((
        "clampRfRxcalParam", "packRfRxcalWord0", "packRfRxcalWord1",
        "storeRfRxcalRecord", "rfPriReplayRxcalRegs",
    ))
    run_program(tmp_path, mode, code + r'''
for record in 0 ..< 4:
  for p2 in [0'i32, 1, 2047, 2048, -1, 65535]:
    for p3 in -512'i32 .. 511'i32:
      rxcalSetup()
      let word = 18 + record * 2
      var expected = calibration
      expected[word] = (expected[word] and 0xFFFF'u32) or (cast[uint32](p2) shl 16)
      expected[word + 1] = (expected[word + 1] and 0xFFFF0000'u32) or (cast[uint32](p3) and 65535)
      let physical = (rf70.rxcalReplay[record] and 0xF800FC00'u32) or
        ((cast[uint32](p2) and 0x7FF) shl 16) or (cast[uint32](p3) and 0x3FF)
      let trace = @[(cast[uint](addr calibration[word]), expected[word]),
                    (cast[uint](addr calibration[word + 1]), expected[word + 1]),
                    (cast[uint](addr rf70.rxcalReplay[record]), physical)]
      storeRfRxcalRecord(record, p2, p3, 0xF00D'u32)
      doAssert calibration == expected, "RXCAL saved records must retain low signed 16-bit results"
      doAssert events == trace, "RXCAL record/register publication order or physical field masks differ"
      doAssert wifiRfRxcalRecordWord0Log[record] == expected[word]
      doAssert wifiRfRxcalRecordWord1Log[record] == expected[word + 1]
      doAssert nim_wifi_rf_rxcal_power_log[record] == 0xF00D
rxcalSetup()
let before = calibration
for index in [-1, 4, 127]: storeRfRxcalRecord(index, 0, 0, 0)
rfCalibDataGlobal = nil
storeRfRxcalRecord(0, 0, 0, 0)
doAssert calibration == before and events.len == 0
for vector in 0 ..< 1000:
  rxcalSetup()
  let before = calibration
  var expected = registerStorage
  var trace: seq[tuple[address: uint, value: uint32]]
  for record in 0 ..< 4:
    let word = 18 + record * 2
    expected[(0x170 div 4) + record] = (expected[(0x170 div 4) + record] and 0xF800FC00'u32) or
      (calibration[word] and 0x7FF0000) or (calibration[word + 1] and 0x3FF)
    trace.add((cast[uint](addr rf70.rxcalReplay[record]), expected[(0x170 div 4) + record]))
  rfPriReplayRxcalRegs()
  doAssert calibration == before and registerStorage == expected and events == trace
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_coordinator_programs_search_results_restores_then_publishes_once(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = rxcal_source((
        "clampRfRxcalParam", "writeRfRxcalParam", "packRfRxcalWord0", "packRfRxcalWord1",
        "storeRfRxcalRecord", "rfPriReplayRxcalRegs",
    )) + r'''
var
  inputCalibration: array[96, uint32]
  inputRegisters: array[3, uint32]
  results: array[4, int32]
  searchInputs: seq[tuple[parameter: uint32, center, delta: int32]]
  restoreCount: int
const saveEvent = (1'u, 0x2c'u32)
const setupEvent = (1'u, 0x34'u32)
const searchSites = [0x33e'u32, 0x36c, 0x3a2, 0x3d4]
proc saveRfPriCalState(): uint32 =
  events.add(saveEvent)
  return 0xCA1'u32
proc prepareRfPriRxcal() = events.add(setupEvent)
proc searchRfRxcalParam(parameter: uint32; center, delta: int32):
    tuple[ok: bool, value: int32, power: uint32] =
  doAssert searchInputs.len < 4
  events.add((1'u, searchSites[searchInputs.len]))
  result = (true, results[searchInputs.len], (searchInputs.len + 1).uint32)
  searchInputs.add((parameter, center, delta))
proc restoreRfPriCalState(saved: uint32) =
  doAssert saved == 0xCA1'u32
  doAssert calibration == inputCalibration, "RXCAL published records before restoring state"
  inc restoreCount
  volatileStore(addr rf70.txcalDfe88, inputRegisters[0])
  volatileStore(addr rf70.rxcalSearch614, inputRegisters[1])
  volatileStore(addr rf70.measureCtrl618, inputRegisters[2])
'''
    code += procedure(rf, "runRfPriRxcal")
    run_program(tmp_path, mode, code + r'''
for vector in 0 ..< 1000:
  rxcalSetup()
  inputCalibration = calibration
  inputRegisters = [randomWord(), randomWord(), randomWord()]
  results = [0x401'i32, -3'i32, (randomWord() and 0x7FF).int32, (randomWord() and 0x3FF).int32 - 512]
  searchInputs.setLen(0)
  restoreCount = 0
  let initialMode = rf70.calMode14
  var expected = calibration
  var trace: seq[tuple[address: uint, value: uint32]]
  trace.add((cast[uint](addr rf70.calMode14), (initialMode and 0xFCFFFFFF'u32) or 0x1000000))
  trace.add(saveEvent)
  trace.add(setupEvent)
  var searchControl = rf70.rxcalSearch614
  for index in 0 ..< 4:
    trace.add((1'u, searchSites[index]))
    let value = cast[uint32](results[index])
    searchControl = if index mod 2 == 0:
        (searchControl and 0xFF800FFF'u32) or ((value and 0x7FF) shl 12) or 0x800000
      else: (searchControl and 0xFFFFFC00'u32) or (value and 0x3FF) or 0x400
    trace.add((cast[uint](addr rf70.rxcalSearch614), searchControl))
  for index, address in [addr rf70.txcalDfe88, addr rf70.rxcalSearch614, addr rf70.measureCtrl618]:
    trace.add((cast[uint](address), inputRegisters[index]))
  trace.add((cast[uint](addr rf70.txcalDfe88), inputRegisters[0] and 0xEFFFFFFF'u32))
  trace.add((cast[uint](addr rf70.calMode14), initialMode or 0x3000000'u32))
  for record in 0 ..< 4:
    let word = 18 + record * 2
    expected[word] = (expected[word] and 65535) or (results[2].uint32 shl 16)
    expected[word + 1] = (expected[word + 1] and 0xFFFF0000'u32) or (cast[uint32](results[3]) and 65535)
    trace.add((cast[uint](addr calibration[word]), expected[word]))
    trace.add((cast[uint](addr calibration[word + 1]), expected[word + 1]))
    trace.add((cast[uint](addr rf70.rxcalReplay[record]),
      (rf70.rxcalReplay[record] and 0xF800FC00'u32) or
      (results[2].uint32 shl 16) or (cast[uint32](results[3]) and 0x3FF)))
  runRfPriRxcal()
  doAssert restoreCount == 1 and workarounds == 0
  doAssert searchInputs == @[(2'u32, 0x400'i32, 0x40'i32), (3'u32, 0'i32, 0x20'i32),
                             (2'u32, results[0], 0x20'i32), (3'u32, results[1], 0x10'i32)]
  doAssert calibration == expected and events == trace,
    "RXCAL caller programming, restore/done order, or single publication differs"
  doAssert rf70.rxcalSearch614 == inputRegisters[1] and rf70.measureCtrl618 == inputRegisters[2]
rxcalSetup()
rfCalibDataGlobal = nil
runRfPriRxcal()
doAssert events.len == 0
''')
