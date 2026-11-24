"""BL808-demo TXCAL transaction through the RF6C mixer sweep."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, object_type
from test_wifi_rf_txcal import SAMPLER, txcal_source


def bl808_txcal_source() -> str:
    rf = RF.read_text()
    code = txcal_source((
        "signedRfAverageMeasurement", "signedRfAverageAdcMean",
        *SAMPLER, "sampleRfTxcalAdcMean",
        "programRfPriModeRegisters", "startRfPriTxDfeForCal",
    ))
    start = rf.rindex("\nproc sampleRfTxcalAverage(")
    code += procedure(rf[start + 1:], "sampleRfTxcalAverage")
    code += object_type(rf, "RfDfeInitBlock")
    code += """
var fixtureDfe: RfDfeInitBlock
proc rfDfeInitRegs(): ptr RfDfeInitBlock = addr fixtureDfe
proc waitBl808RfCalUs(us: uint32) = events.add((0'u, us))
"""
    return code + "".join(RF.with_name(name).read_text() for name in (
        "rf_bl808_calibration_snapshot.nim", "rf_bl808_tx_gain.nim", "rf_bl808_txcal.nim"))


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bl808_txcal_mixer_prefix_and_restore_match_demo(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, bl808_txcal_source() + r'''
const
  RfSnapshotOffsets = [0x04, 0x2C, 0x1C, 0x30, 0xB8, 0xC0, 0xC4,
    0x84, 0x8C, 0x600, 0x60C, 0x618, 0x61C, 0x48, 0x20C, 0x214, 0x218,
    0x23C, 0x240, 0x244, 0xF0, 0x64, 0x58, 0x220, 0x70, 0xA4]
type Trace = seq[tuple[address: uint, value: uint32]]
proc rfAddress(offset: int): uint = cast[uint](addr registerStorage[offset div 4])
proc appendRawAdc(value: int32) =
  adcValues.add(((cast[uint32](value) and 0x01FFFFFF'u32) or 0xAA000000'u32, 0'u32))

for trial in 0 ..< 5:
  let meanPath = case trial
    of 0: @[64'i32]
    of 1: @[128'i32]
    of 2: @[129'i32, 63, 96]
    of 3: @[-1'i32, -1, -1, -1, -1, -1, -1, -1]
    else: @[129'i32, 129, 129, 129, 129, 129, 129, 129]
  let ampPath = case trial
    of 0, 1: @[128'u32]
    of 2: @[128'u32, 64, 96]
    of 3: @[128'u32, 192, 224, 240, 248, 252, 254, 255]
    else: @[128'u32, 64, 32, 16, 8, 4, 2, 1]
  for mixerCase in 0 ..< 10:
    for readyDelay in [0, 2]:
      rxcalSetup()
      readyAfter = readyDelay
      fixtureDfe.hbnCtrl30 = randomWord()
      let originalRf = registerStorage
      let originalHbn = fixtureDfe.hbnCtrl30
      let originalRecords = calibration
      for mean in meanPath: appendRawAdc(mean * 1024)
      for candidate in 0 ..< 8:
        appendRawAdc(
          if mixerCase == 0: -2048'i32
          elif mixerCase == 9 and candidate in [2, 6]: 0x00FFFFFF'i32
          elif mixerCase == candidate + 1: -1'i32
          else: -4000'i32)
      let winner = case mixerCase
        of 0: 5'u32
        of 9: 2'u32
        else: (mixerCase - 1).uint32

      var expected = originalRf
      var eventsExpected: Trace
      template put(offset: int; keep, bits: uint32) =
        expected[offset div 4] = (expected[offset div 4] and keep) or bits
        eventsExpected.add((rfAddress(offset), expected[offset div 4]))
      template startDfe() =
        put(0x220, 0xFFFFFE7F'u32, 0)
        put(0x220, 0xFFFFE7FF'u32, 0x1082)
        put(0x220, 0xFFFFFFEF'u32, 0x100)
      template average() =
        put(0x618, 0xDFEFFFFF'u32, 0)
        put(0x61C, 0xFFFF'u32, 0x04000000)
        put(0x618, 0xFFFFFFFF'u32, 0x20000000)
        expected[0x618 div 4] = expected[0x618 div 4] or 0x10000000
        put(0x618, 0xDFEFFFFF'u32, 0)

      # Demo rf_pri_txcal+0x20..0x2c6. Channel tuning is tested separately.
      put(0x14, 0xFF0FFFFF'u32, 0x500000)
      put(0x04, 0xFFFFFFFD'u32, 0)
      put(0x2C, 0, 0)
      put(0x30, 0xFFFFFFFF'u32, 2)
      put(0x30, 0xCEFFF8FF'u32, 0xCEFF7800'u32)
      eventsExpected.add((0'u, 0'u32))
      startDfe()
      put(0x220, 0xFFFFFF9F'u32, 0)
      put(0x220, 0xFFFFFFFF'u32, 0x21)
      put(0x220, 0xFFFFFFFF'u32, 0x40)
      eventsExpected.add((1'u, 9'u32))
      put(0x1C, 0xFFFFFFFF'u32, 0x3000)
      put(0x84, 0xFFFFFFFF'u32, 0x80000000'u32)
      put(0x64, 0xFFFFFFFF'u32, 0x400000)
      put(0x6C, 0xFFFFFFF8'u32, 4)
      put(0x20C, 0xFC00FFFF'u32, 0xB0000)
      put(0x214, 0x003FFFFF'u32, 0)
      put(0x218, 0x003FFFFF'u32, 0xC0000000'u32)
      put(0x64, 0x0FC3FFFF'u32, 0x50000000)
      put(0x58, 0xFFF8FFFF'u32, 0x40000)
      put(0x48, 0xCE08FFFF'u32, 0x870000)
      for amplitude in ampPath:
        put(0x214, 0xFFFFF800'u32, amplitude)
        put(0x218, 0xFFFFF800'u32, amplitude)
        put(0x20C, 0x7FFFFFFF'u32, 0)
        put(0x20C, 0xFFFFFFFF'u32, 0x80000000'u32)
        startDfe()
        eventsExpected.add((0'u, 10'u32))
        average()
      for candidate in 0'u32 ..< 8:
        put(0x6C, 0xFFFFFFF8'u32, candidate)
        average()
      var expectedRecords = originalRecords
      expectedRecords[3] = (expectedRecords[3] and 0xF8FFFFFF'u32) or (winner shl 24)
      eventsExpected.add((cast[uint](addr calibration[3]), expectedRecords[3]))
      put(0x6C, 0xFFFFFFF8'u32, winner)
      let saved = beginBl808Txcal()
      doAssert events == eventsExpected, "native mixer setup, wait, sampling or publication differs"
      doAssert registerStorage == expected and calibration == expectedRecords
      doAssert adcIndex == ampPath.len + 8 and not pending
      let hbnAddress = cast[uint](addr fixtureDfe.hbnCtrl30)
      var snapshotReads: seq[uint]
      for i, offset in RfSnapshotOffsets:
        if i == 7: snapshotReads.add(hbnAddress)
        snapshotReads.add(rfAddress(offset))
      doAssert mmioReads[0] == rfAddress(0x14)
      doAssert mmioReads[1 .. 27] == snapshotReads

      # Restore must restore RCCAL's scratch bit but keep the measured RF6C code.
      for offset in [0x88, 0x90, 0x74]: registerStorage[offset div 4] = randomWord()
      fixtureDfe.hbnCtrl30 = randomWord()
      expected = registerStorage
      var restoreTrace: Trace
      for i, offset in RfSnapshotOffsets:
        if i == 7: restoreTrace.add((hbnAddress, originalHbn))
        expected[offset div 4] = originalRf[offset div 4]
        restoreTrace.add((rfAddress(offset), originalRf[offset div 4]))
      adcValues.setLen(0)
      events.setLen(0)
      mmioReads.setLen(0)
      restoreBl808CalibrationState(saved)
      doAssert events == restoreTrace and mmioReads.len == 0
      doAssert registerStorage == expected and fixtureDfe.hbnCtrl30 == originalHbn
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bl808_txcal_search_targets_rf70_and_new_frequency_words(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, bl808_txcal_source() + r'''
for param in Bl808TxcalParam:
  let (lo, hi, freqBits) = case param
    of bl808TxcalIqI, bl808TxcalIqQ: (0'i32, 63'i32, 0x0000F400'u32)
    of bl808TxcalOffsetI: (0'i32, 2047'i32, 0x0001E800'u32)
    of bl808TxcalOffsetQ: (-512'i32, 511'i32, 0x0001E800'u32)
  for center in [lo, (lo + hi + 1) div 2, hi]:
    for delta in [0'i32, 1, 8, 16, 32]:
      for decisionPattern in 0 ..< 27:
        rxcalSetup()
        var expected = registerStorage
        var trace: seq[tuple[address: uint, value: uint32]]
        template put(offset: int; keep, bits: uint32) =
          expected[offset div 4] = (expected[offset div 4] and keep) or bits
          trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
        proc addAdc(magnitude: int32) =
          adcValues.add((cast[uint32]((-magnitude) shl 9), 17'u32 shl 9))
        template measure(candidate, magnitude: int32; first = false) =
          let bits = cast[uint32](candidate)
          case param
          of bl808TxcalIqI:
            put(0x70, 0xC0FFFFFF'u32, (bits and 63) shl 24)
          of bl808TxcalIqQ:
            put(0x70, 0xFFC0FFFF'u32, (bits and 63) shl 16)
          of bl808TxcalOffsetI:
            put(0x600, 0xFF800FFF'u32, ((bits and 2047) shl 12) or 0x800000)
          of bl808TxcalOffsetQ:
            put(0x600, 0xFFFFFC00'u32, (bits and 1023) or 0x400)
          trace.add((0'u, 10'u32))
          if first: put(0x618, 0xFFF00000'u32, freqBits)
          put(0x618, 0xDFEFFFFF'u32, 0)
          put(0x618, 0xFFFFFFFF'u32, 0x20100000)
          expected[0x618 div 4] = expected[0x618 div 4] or 0x10000000
          put(0x618, 0xDFEFFFFF'u32, 0)
          addAdc(magnitude)
        var wanted = center
        var magnitude = 100'i32
        measure(center, magnitude, true)
        var step = delta
        var choices = decisionPattern
        while true:
          let left = max(lo, wanted - step)
          let right = min(hi, wanted + step)
          case choices mod 3
          of 0:
            dec magnitude
            measure(left, magnitude)
            wanted = left
          of 1:
            measure(left, magnitude)
            dec magnitude
            measure(right, magnitude)
            wanted = right
          else:
            measure(left, magnitude)
            measure(right, magnitude)
          choices = choices div 3
          step = step div 2
          if step == 0: break
        doAssert searchBl808TxcalParam(param, center, delta) == wanted
        doAssert adcIndex == adcValues.len and not pending
        doAssert events == trace and registerStorage == expected,
          "native TXCAL resampled right, reinitialized frequency, or used legacy RF74"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bl808_txcal_records_own_both_banks_and_fixed_active_slot(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, bl808_txcal_source() + r'''
type Trace = seq[tuple[address: uint, value: uint32]]
for vector in 0 ..< 128:
  rxcalSetup()
  fixtureDfe.hbnCtrl30 = randomWord()
  var savedRegisters = registerStorage
  let saved = saveBl808CalibrationState()
  let savedHbn = fixtureDfe.hbnCtrl30
  var wantedRecords = calibration
  var recordTrace: Trace
  var expectedA, expectedB: array[8, uint32]
  for slot in 0 ..< 8:
    let i = 26 + slot * 2
    let iqI = if vector == 0: 0'u32 else: randomWord() and 63
    let iqQ = if vector == 0: 0'u32 else: randomWord() and 63
    let gain = if vector == 0: 0'u32 else: randomWord() and 2047
    let rawPhase = if vector == 0: 0'u32 else: randomWord() and 1023
    let phase = if rawPhase >= 512: rawPhase.int32 - 1024 else: rawPhase.int32
    let values: Bl808TxcalResult = [iqI.int32, iqQ.int32, gain.int32, phase]
    let addr0 = cast[uint](addr calibration[i])
    let addr1 = cast[uint](addr calibration[i + 1])
    let first = (calibration[i] and 0xFFFFFFC0'u32) or iqI
    let second = (first and 0xFFFFF03F'u32) or (iqQ shl 6)
    wantedRecords[i] = (second and 0xFF800FFF'u32) or (gain shl 12)
    wantedRecords[i + 1] = (calibration[i + 1] and 0xFFFFFC00'u32) or rawPhase
    recordTrace.add(@[(addr0, first), (addr0, second), (addr0, wantedRecords[i]),
                      (addr1, wantedRecords[i + 1])])
    storeBl808TxcalRecord(slot.Bl808TxcalSlot, values)
    expectedA[slot] = gain
    expectedB[slot] = (rawPhase shl 14) or (iqI shl 8) or (iqQ shl 2)
  doAssert events == recordTrace and calibration == wantedRecords
  # Mutate scratch registers before the finish path restores them.
  for word in registerStorage.mitems: word = randomWord()
  fixtureDfe.hbnCtrl30 = randomWord()
  var expected = registerStorage
  var trace: Trace
  template put(offset: int; keep, bits: uint32) =
    expected[offset div 4] = (expected[offset div 4] and keep) or bits
    trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
  for bank in [0x708, 0x764]:
    for slot in 0 ..< 8:
      put(bank + 8 * slot, 0xFFFFF800'u32, expectedA[slot])
      put(bank + 8 * slot + 4, 0xFF000003'u32, expectedB[slot])
  put(0x1C, 0xFFFFCFFF'u32, 0)
  for offset in [0x04, 0x2C, 0x1C, 0x30, 0xB8, 0xC0, 0xC4]:
    put(offset, 0, savedRegisters[offset div 4])
  trace.add((cast[uint](addr fixtureDfe.hbnCtrl30), savedHbn))
  for offset in [0x84, 0x8C, 0x600, 0x60C, 0x618, 0x61C, 0x48, 0x20C,
      0x214, 0x218, 0x23C, 0x240, 0x244, 0xF0, 0x64, 0x58, 0x220, 0x70, 0xA4]:
    put(offset, 0, savedRegisters[offset div 4])
  put(0x14, 0xFFFFFFFF'u32, 0xF00000)
  let record = expectedB[3]
  let iq = (((record shr 8) and 63) shl 24) or (((record shr 2) and 63) shl 16)
  put(0x70, 0xC0C0FFFF'u32, iq)
  put(0x600, 0xFF800C00'u32, ((record shr 14) and 1023) or (expectedA[3] shl 12))
  events.setLen(0)
  finishBl808Txcal(saved)
  doAssert events == trace and registerStorage == expected
  doAssert fixtureDfe.hbnCtrl30 == savedHbn and calibration == wantedRecords

rfCalibDataGlobal = nil
events.setLen(0)
storeBl808TxcalRecord(0, default(Bl808TxcalResult))
replayBl808TxcalCorrections()
publishBl808TxcalActiveRecord()
doAssert events.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bl808_txcal_row_refines_each_coarse_winner(tmp_path: Path, mode: str) -> None:
    code = bl808_txcal_source()
    start = code.index("proc searchBl808TxcalParam(")
    end = code.index("const Bl808TxcalRecordCount", start)
    code = code[:start] + r'''
type Call = tuple[param: Bl808TxcalParam, center, delta: int32]
const Steps: array[8, Call] = [
  (bl808TxcalIqI, 0x20'i32, 0x10'i32), (bl808TxcalIqQ, 0x20'i32, 0x10'i32),
  (bl808TxcalIqI, 37'i32, 0x08'i32), (bl808TxcalIqQ, 12'i32, 0x08'i32),
  (bl808TxcalOffsetI, 0x400'i32, 0x80'i32), (bl808TxcalOffsetQ, 0'i32, 0x40'i32),
  (bl808TxcalOffsetI, 973'i32, 0x40'i32), (bl808TxcalOffsetQ, -39'i32, 0x20'i32),
]
const Codes = [37'i32, 12, 31, 8, 973, -39, 998, -47]
var call = 0
proc searchBl808TxcalParam(param: Bl808TxcalParam; center, delta: int32): int32 =
  doAssert adcIndex == 1 and not pending, "row search must prime the ADC first"
  doAssert call < Steps.len and (param, center, delta) == Steps[call]
  doAssert events.len == 4 + call, "row did not program the last winner before continuing"
  result = Codes[call]
  inc call

''' + code[end:]
    run_program(tmp_path, mode, code + r'''
rxcalSetup()
let initialIq = rf70.txcalParam70
let initialOffsets = rf70.txcalTosdac600
adcValues = @[(123'u32, 0'u32)]
let measured = searchBl808TxcalRow()
doAssert call == 8 and events.len == 12
doAssert measured == [31'i32, 8, 998, -47]
doAssert rf70.txcalParam70 == ((initialIq and 0xC0C0FFFF'u32) or (31'u32 shl 24) or (8'u32 shl 16))
doAssert rf70.txcalTosdac600 == ((initialOffsets and 0xFF800C00'u32) or
  (998'u32 shl 12) or 0x800000'u32 or 0x400'u32 or 977'u32)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bl808_txcal_row_uses_selected_drive_and_tone_route(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, bl808_txcal_source() + r'''
for slot in 0 ..< 8:
  for gain in [(0'i16, 0'i16), (1'i16, 9'i16), (3'i16, 26'i16)]:
    rxcalSetup()
    adcValues = @[(128'u32 shl 10, 0'u32)]
    var expected = registerStorage
    var trace: seq[tuple[address: uint, value: uint32]]
    template put(offset: int; keep, bits: uint32) =
      expected[offset div 4] = (expected[offset div 4] and keep) or bits
      trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
    put(0x20C, 0xFC00FFFF'u32, 0x3D0000)
    put(0x214, 0x003FFFFF'u32, 0)
    put(0x218, 0x003FFFFF'u32, 0xC0000000'u32)
    put(0x64, 0x0FC3FFFF'u32, 0x90300000'u32)
    put(0x58, 0xFFF8FFFF'u32, 0x40000)
    put(0x48, 0xCE0FFFFF'u32, 0x770000)
    put(0x8C, 0xFFFFFFCF'u32, 0x10)
    put(0x64, 0x0FC3FFFF'u32, 0x60100000)
    put(0x58, 0xFFF8FFFF'u32, 0x40000)
    let tone = (if slot < 2: 3'u32 else: 7'u32) shl 16
    put(0x48, 0xCE08FFFF'u32, tone or (gain[0].uint32 shl 28) or (gain[1].uint32 shl 20))
    trace.add((0'u, 10'u32))
    put(0x214, 0xFFFFF800'u32, 192)
    put(0x218, 0xFFFFF800'u32, 192)
    put(0x20C, 0x7FFFFFFF'u32, 0)
    put(0x20C, 0xFFFFFFFF'u32, 0x80000000'u32)
    put(0x220, 0xFFFFFE7F'u32, 0)
    put(0x220, 0xFFFFE7FF'u32, 0x1082)
    put(0x220, 0xFFFFFFEF'u32, 0x100)
    trace.add((0'u, 10'u32))
    put(0x618, 0xDFEFFFFF'u32, 0)
    put(0x61C, 0xFFFF'u32, 0x04000000)
    put(0x618, 0xFFFFFFFF'u32, 0x20000000)
    expected[0x618 div 4] = expected[0x618 div 4] or 0x10000000
    put(0x618, 0xDFEFFFFF'u32, 0)
    prepareBl808TxcalRows()
    prepareBl808TxcalRow(slot.Bl808TxcalSlot, gain[0], gain[1])
    doAssert events == trace and registerStorage == expected and adcIndex == 1
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bl808_txcal_runs_eight_rows_with_native_gain_indices(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, bl808_txcal_source() + r'''
rxcalSetup()
let savedRf = registerStorage
let savedWords = calibration
for sample in 0 ..< 9:
  adcValues.add(((if sample == 0: 64'u32 shl 10 else: 0'u32), 0'u32))
for slot in 0 ..< 8:
  adcValues.add((128'u32 shl 10, 0'u32))
  # Prime plus eight searches: with tied power, every level checks both sides.
  for sample in 0 ..< 101: adcValues.add((0'u32, 0'u32))
runBl808Txcal()
doAssert adcIndex == 825 and not pending and nim_wifi_rf_pri_txcal_count == 1
doAssert calibration[3] == (savedWords[3] and 0xF8FFFFFF'u32)
doAssert (rf70.txcalDc6c and 7) == 0
const tones = [0x01A30000'u32, 0x01630000, 0x01170000, 0x01170000,
               0x00C70000, 0x00C70000, 0x00970000, 0x00770000]
var toneWrites: seq[uint32]
for access in events:
  if access.address == cast[uint](addr rf70.rccalTone48):
    toneWrites.add(access.value)
doAssert toneWrites.len == 11, "one mixer tone, one I/Q setup, eight rows, one restore"
for slot in 0 ..< 8:
  doAssert (toneWrites[slot + 2] and 0x31F70000'u32) == tones[slot]
  let row = 26 + slot * 2
  doAssert calibration[row] == ((savedWords[row] and 0xFF800000'u32) or 0x00400820'u32)
  doAssert calibration[row + 1] == (savedWords[row + 1] and 0xFFFFFC00'u32)
  for bank in [0x708, 0x764]:
    let a = (bank + slot * 8) div 4
    doAssert registerStorage[a] == ((savedRf[a] and 0xFFFFF800'u32) or 0x400'u32)
    doAssert registerStorage[a + 1] == ((savedRf[a + 1] and 0xFF000003'u32) or 0x2080'u32)
doAssert rf70.txcalParam70 == ((savedRf[0x70 div 4] and 0xC0C0FFFF'u32) or 0x20200000'u32)
doAssert rf70.txcalTosdac600 == ((savedRf[0x600 div 4] and 0xFF800C00'u32) or 0x00400000'u32)
''')
