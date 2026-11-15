"""ROSCAL register traces, search decisions, and per-branch publication."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_lo_search import lo_source
from test_wifi_rf_power_replay import RF, source


def roscal_source() -> str:
    rf = RF.read_text()
    code = lo_source()
    constants = (
        "RfMeasureTriggerClearMask", "RfMeasureModeKeepMask", "RfMeasureRoscalMode",
        "RfMeasureStartMask", "RfMeasureReadyMask", "RfRoscalCapabilityMask",
        "RfRoscalModeMask", "RfRoscalStartMode", "RfRoscalDoneMode",
        "RfRoscalCodeMask", "RfRoscalIRegMask", "RfRoscalQRegMask",
        "RfRoscalRegisterKeepMask", "RfRoscalWaitLimit", "RfCalibRccalReplayWordIndex",
    )
    code += "const\n" + "".join(
        next(line for line in rf.splitlines() if line.startswith("  " + name + " = ")) + "\n"
        for name in constants
    )
    code += r'''
type RfRoscalSample = object
  measurementWord: uint32
  signed: int32
var
  nim_wifi_rf_roscal_wait_timeout_count, nim_wifi_rf_pri_roscal_count: uint32
  nim_wifi_rf_last_roscal_i, nim_wifi_rf_last_roscal_q: uint32
  nim_wifi_rf_roscal_search_log: array[16, uint32]
'''
    code = code.replace(
        "var comparatorBits:",
        "var adcValues: seq[int32]\nvar adcIndex, measureReads, readyAfter: int\n"
        "var checkIAtQ: bool\nvar expectedI: uint32\nvar comparatorBits:",
        1,
    ).replace(
        "  if p == (addr rf70.acalCtrlA4)",
        "  if p == (addr rf70.measureCtrl618):\n"
        "    inc measureReads\n"
        "    return (p[] and not 0x10000000'u32) or\n"
        "      (if measureReads > readyAfter: 0x10000000'u32 else: 0'u32)\n"
        "  if p == (addr rf70.measureI620) or p == (addr rf70.measureQ624):\n"
        "    doAssert measureReads > readyAfter, \"ROSCAL consumed a sample before READY\"\n"
        "    if checkIAtQ and p == (addr rf70.measureQ624):\n"
        "      for word in [24, 22, 20, 18]:\n"
        "        doAssert (calibration[word] and 255) == expectedI, \"I result was not published before Q search\"\n"
        "    doAssert adcIndex < adcValues.len\n"
        "    result = cast[uint32](adcValues[adcIndex]) and 0x01FFFFFF'u32\n"
        "    inc adcIndex\n    return\n"
        "  if p == (addr rf70.acalCtrlA4)",
        1,
    )
    for name in (
        "rfCalibSetWord", "signedRfAverageMeasurement", "waitRfRoscalMeasurementReady",
        "writeRfRoscalCandidate", "sampleRfRoscalMeasurement", "logRfRoscalSearch",
        "chooseRfRoscalCode", "applyRfRoscalCodes", "applyRfRoscalCode",
        "prepareRfPriRoscal", "runRfPriRoscal",
    ):
        if f"proc {name}(" in rf:
            body = procedure(rf[rf.rindex("\nproc " + name + "(") + 1:], name)
            body = body.split("\ntype\n", 1)[0]
            code += body + "\n"
    return code + r'''
proc roscalSetup() =
  loSetup(4)
  for word in calibration.mitems: word = randomWord()
  rf70.measureCtrl618 = rf70.measureCtrl618 or 0x10000000'u32
  adcValues.setLen(0)
  adcIndex = 0
  measureReads = 0
  readyAfter = 0
  checkIAtQ = false
  nim_wifi_rf_roscal_search_log = default(typeof(nim_wifi_rf_roscal_search_log))
proc publishBoth(i, q: uint32) =
  when declared(applyRfRoscalCode):
    applyRfRoscalCode(true, i)
    applyRfRoscalCode(false, q)
  else: applyRfRoscalCodes(i, q)
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_setup_mmio_and_delay_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, roscal_source() + r'''
for vector in 0 ..< 1000:
  roscalSetup()
  var expected = registerStorage
  var trace: seq[tuple[address: uint, value: uint32]]
  template put(offset: int; keep, value: uint32) =
    expected[offset div 4] = (expected[offset div 4] and keep) or value
    trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
  put(0x04, 0xFFFFFFFD'u32, 0)
  put(0x2C, 0, 0)
  put(0x30, 0xFFFFFFFF'u32, 2)
  put(0x30, 0x21F0FEFF'u32, 0x21F06E00)
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
  put(0x1C, 0xFFFFFFFF'u32, 0x200)
  put(0x48, 0xFFFF8CFF'u32, 0x311F)
  put(0x80, 0x7FFFFFFF'u32, 0)
  prepareRfPriRoscal()
  doAssert registerStorage == expected, "ROSCAL setup differs from vendor register fields"
  doAssert events == trace, "ROSCAL setup write/delay ordering differs from vendor"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_sampler_polls_ready_and_decodes_signed_25_bits(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, roscal_source() + r'''
for delay in [5001, 0, 1, 10010, 20017]:
  for branch in [false, true]:
    for value in [-16777216'i32, -1, 0, 1, 16777215]:
      roscalSetup()
      readyAfter = delay + 2 # Two control RMW reads precede READY polling.
      adcValues = @[value]
      let previousStalls = nim_wifi_rf_roscal_wait_timeout_count
      let sample = sampleRfRoscalMeasurement(branch)
      doAssert sample.signed == value
      doAssert sample.measurementWord == (cast[uint32](value) and 0x1FFFFFF)
      doAssert adcIndex == 1 and delays.len == 0
      doAssert nim_wifi_rf_roscal_wait_timeout_count ==
        previousStalls + (delay div RfRoscalWaitLimit).uint32
      doAssert (rf70.measureCtrl618 and 0x20100000'u32) == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_negative_sample_logging_is_bit_preserving_and_bounded(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, roscal_source() + r'''
for branch in [false, true]:
  for value in [-16777216'i32, -32769, -32768, -1, 0, 32767, 32768, 16777215]:
    roscalSetup()
    var index = if branch: 0 else: 8
    let start = index
    let sample = RfRoscalSample(measurementWord: 0, signed: value)
    logRfRoscalSearch(index, branch, 0xFFFFFFFF'u32, sample)
    doAssert index == start + 1
    doAssert nim_wifi_rf_roscal_search_log[start] ==
      ((if branch: 0x80000000'u32 else: 0'u32) or 0x3F0000'u32 or
        (cast[uint32](value) and 0xFFFF'u32))
    let before = nim_wifi_rf_roscal_search_log
    for full in [16, 17, 128]:
      index = full
      logRfRoscalSearch(index, branch, 0, sample)
      doAssert index == full and nim_wifi_rf_roscal_search_log == before
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_search_sign_zero_history_and_wrapping(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, roscal_source() + r'''
for branch in [false, true]:
  for pattern in 0 ..< 64:
    for fine in 0 ..< 4:
      roscalSetup()
      let initial = rf70.rbbRccalCtrl80
      var wantedCodes: seq[uint32]
      var code = 0
      for bit in countdown(5, 0):
        let candidate = code + (1 shl bit)
        let value = if (pattern and (1 shl bit)) != 0: 1'i32 else: 0'i32
        wantedCodes.add((candidate and 63).uint32)
        adcValues.add(value)
        if value <= 0: code = candidate
      var history = 0
      for attempt in 0 ..< 63:
        let value = case fine
          of 0: 1'i32
          of 1: -1'i32
          of 2: (if attempt mod 3 in [0, 2]: 1'i32 else: 0'i32)
          else: (if attempt mod 5 in [0, 1, 3]: 1'i32 else: -1'i32)
        wantedCodes.add((code and 63).uint32)
        adcValues.add(value)
        history = ((history shl 1) or (if value > 0: 1 else: 0)) and 15
        code += (if value > 0: -1 else: 1)
        if (value > 0 and history == 5) or (value <= 0 and history == 10): break
      let actual = chooseRfRoscalCode(branch)
      doAssert actual == ((code + 256) and 255).uint8,
        "ROSCAL coarse sign decision or fine result wrapping differs"
      doAssert adcIndex == adcValues.len
      var candidateWrites: seq[uint32]
      for event in mmioWrites:
        if event.address == cast[uint](addr rf70.rbbRccalCtrl80):
          candidateWrites.add(if branch: (event.value shr 8) and 63 else: event.value and 63)
      doAssert candidateWrites == wantedCodes, "ROSCAL must program RF80 candidates in vendor order"
      let mask = if branch: 0x3F00'u32 else: 0x3F'u32
      doAssert (rf70.rbbRccalCtrl80 and not mask) == (initial and not mask)
      for event in mmioWrites:
        doAssert event.address != cast[uint](addr rf70.roscalCtrl7c)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_publication_owns_four_record_bytes_and_eight_register_fields(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, roscal_source() + r'''
for i in 0 ..< 256:
  for q in [0, 1, 31, 63, 64, 127, 255]:
    roscalSetup()
    var expected = calibration
    var rfExpected = registerStorage
    var trace: seq[tuple[address: uint, value: uint32]]
    for branch in [true, false]:
      let code = if branch: i.uint32 else: q.uint32
      let byteShift = if branch: 0 else: 8
      for slot, word in [24, 22, 20, 18]:
        expected[word] = (expected[word] and not (255'u32 shl byteShift)) or (code shl byteShift)
        let offset = if slot < 2: 0x16C else: 0x168
        let shift = (if slot mod 2 == 0: 16 else: 0) + byteShift
        rfExpected[offset div 4] = (rfExpected[offset div 4] and not (63'u32 shl shift)) or
                                  ((code and 63) shl shift)
        trace.add((cast[uint](addr registerStorage[offset div 4]), rfExpected[offset div 4]))
    publishBoth(i.uint32, q.uint32)
    doAssert calibration == expected, "ROSCAL overwrote RCCAL or missed its four packed records"
    doAssert registerStorage == rfExpected
    doAssert mmioWrites == trace, "ROSCAL lane writes differ in order or ownership"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_coordinator_publishes_i_before_q_and_preserves_capability_gate(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, roscal_source() + r'''
for supported in [false, true]:
  roscalSetup()
  rf70.capability20 = if supported: 0x100'u32 else: 0'u32
  let before = calibration
  if supported:
    # I: coarse 0, refine -1 -> low byte 255. Q: coarse 63, refine 63.
    adcValues = @[1'i32, 1, 1, 1, 1, 1, 1, 0, 1,
                  0, 0, 0, 0, 0, 0, -1, 1, -1, 1]
    expectedI = 255
    checkIAtQ = true
  runRfPriRoscal()
  if supported:
    doAssert adcIndex == adcValues.len
    for word in [24, 22, 20, 18]:
      doAssert calibration[word] == ((before[word] and 0xFFFF0000'u32) or 0x3FFF)
    doAssert (rf70.calMode14 and 0xC000) == 0xC000
  else:
    doAssert adcIndex == 0 and calibration == before
    doAssert (rf70.calMode14 and 0xC000) == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rxcal_preserves_measured_roscal_bytes(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = source(real_io=True) + procedure(rf, "rfCalibSetWord")
    code += r'''
const
  RfRxcalModeMask = 0x03000000'u32
  RfRxcalStartMode = 0x01000000'u32
  RfRxcalDoneMode = 0x03000000'u32
var
  rxCode: int32
  nim_wifi_rf_pri_rxcal_count, nim_wifi_rf_last_rxcal_power: uint32
  lastWifiRfRxcalRecordWord0, lastWifiRfRxcalRecordWord1: uint32
  wifiRfRxcalRecordWord0Log, wifiRfRxcalRecordWord1Log: array[4, uint32]
  nim_wifi_rf_rxcal_power_log: array[4, uint32]
proc rfPhyTraceCheckpoint(tag: uint32) = discard
proc saveRfPriCalState(): uint32 = 0
proc restoreRfPriCalState(saved: uint32) = discard
proc prepareRfPriRxcal() = discard
proc searchRfRxcalParam(param: uint32; initial, delta: int32):
    tuple[ok: bool, value: int32, power: uint32] =
  (true, (if param == 2: rxCode else: 0'i32), 1'u32)
proc writeRfRxcalParam(param: uint32; value: int32) = discard
proc rfPriApplyWb03RxcalTosdacLatch() = discard
proc rfPriApplyWb03RuntimeLatches() = discard
'''
    for name in (
        "clampRfRxcalParam", "packRfRxcalWord0", "packRfRxcalWord1",
        "storeRfRxcalRecord", "rfPriReplayRxcalRegs",
        "rfPriSeedRxcalRestoreLowHalves", "runRfPriRxcal",
    ):
        if f"proc {name}(" in rf:
            code += procedure(rf, name)
    run_program(tmp_path, mode, code + r'''
for roscal in [0'u32, 0x2023, 0x2123, 0x3F3F, 0xFFFF]:
  for rxcal in [0'i32, 0x155, 0x400, 0x7FF]:
    setup()
    rfCalibDataGlobal = addr calibration[0]
    for word in calibration.mitems: word = randomWord()
    for word in [24, 22, 20, 18]: calibration[word] = roscal
    var expected = calibration
    for word in [24, 22, 20, 18]:
      expected[word] = roscal or (rxcal.uint32 shl 16)
      expected[word + 1] = expected[word + 1] and 0xFFFF0000'u32
    rxCode = rxcal
    runRfPriRxcal()
    doAssert calibration == expected, "RXCAL replaced measured ROSCAL bytes"
''')


def full_calibration_source() -> str:
    rf = RF.read_text()
    code = source(real_io=True) + procedure(rf, "rfCalibSetWord")
    code += r'''
var rosBytes, rxCode: uint32
proc runRfPriLoFcal() = discard
proc runRfPriLoAcal() = discard
proc runRfPriRoscal() =
  for word in [24, 22, 20, 18]:
    rfCalibSetWord(word, (rfCalibWord(word) and 0xFFFF0000'u32) or rosBytes)
proc runRfPriRccal() = discard
proc runRfPriTxcal() = discard
proc runRfPriBzTxcal() = discard
proc rfPriSeedBzTxcalFallbackRecords() = discard
proc runRfPriRxcal() =
  for word in [24, 22, 20, 18]:
    rfCalibSetWord(word, (rfCalibWord(word) and 0xFFFF'u32) or (rxCode shl 16))
proc rfPriSnapshotStage(tag: uint32) = discard
proc replayRfPriCalRegisters() = discard
proc rfPriReplayWb03Rf70FromTxcalCalWords() = discard
proc rfPriApplyWb03RxcalTosdacLatch() = discard
'''
    if "proc rfPriSeedRxcalRestoreLowHalves(" in rf:
        code += procedure(rf, "rfPriSeedRxcalRestoreLowHalves")
    code += procedure(rf, "runRfPriFullCalRestoreBaseline")
    return code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_full_calibration_preserves_measured_roscal_and_rxcal_fields(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, full_calibration_source() + r'''
for roscal in [0'u32, 0x2023, 0x2123, 0x3F3F, 0xFFFF]:
  for rxcal in [0'u32, 0x155, 0x400, 0x7FF]:
    setup()
    rfCalibDataGlobal = addr calibration[0]
    for word in calibration.mitems: word = randomWord()
    var expected = calibration
    for word in [24, 22, 20, 18]: expected[word] = roscal or (rxcal shl 16)
    rosBytes = roscal
    rxCode = rxcal
    runRfPriFullCalRestoreBaseline()
    doAssert calibration == expected, "full-cal follow-up replaced measured ROSCAL/RXCAL fields"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_full_calibration_stops_rx_dfe_at_entry_and_exit(tmp_path: Path, mode: str) -> None:
    code = full_calibration_source().replace(
        "proc runRfPriLoFcal() = discard",
        "var exitMode: uint32\n"
        "proc runRfPriLoFcal() =\n"
        "  doAssert mmioWrites.len == 2, \"RX DFE was not stopped before LO calibration\"\n"
        "  doAssert (rf70.rxMode220 and 0x19E3'u32) == 0",
    ).replace(
        "proc runRfPriRxcal() =\n",
        "proc runRfPriRxcal() =\n"
        "  volatileStore(addr rf70.rxMode220, exitMode)\n",
        1,
    )
    run_program(tmp_path, mode, code + r'''
for vector in 0 ..< 1000:
  setup()
  rfCalibDataGlobal = addr calibration[0]
  let initial = randomWord()
  rf70.rxMode220 = initial
  exitMode = randomWord()
  let address = cast[uint](addr rf70.rxMode220)
  let trace = @[(address, initial and 0xFFFFE67D'u32),
                (address, initial and 0xFFFFE61C'u32),
                (address, exitMode),
                (address, exitMode and 0xFFFFE67D'u32),
                (address, exitMode and 0xFFFFE61C'u32)]
  runRfPriFullCalRestoreBaseline()
  doAssert mmioWrites == trace, "full calibration RX DFE stop ordering differs from vendor"
  doAssert rf70.rxMode220 == (exitMode and 0xFFFFE61C'u32)
''')
