"""Compare RF power-table state and replay with the vendor's field operations."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


RF = FW / "global_state/rf_bl808_core.nim"
BZ_ROWS = (
    (0, 1, 7, 27, 0, 5, 0, -2, 230),
    (0, 1, 7, 15, 0, 5, 0, 2, 200),
    (0, 1, 7, 9, 0, 5, 0, -2, 150),
    (0, 1, 5, 7, 0, 5, 0, -4, 100),
    (0, 1, 2, 6, 0, 5, 0, 4, 50),
    (0, 1, 7, 16, 0, 5, 1, 2, 90),
    (0, 1, 7, 10, 0, 5, 1, 0, 50),
    (0, 1, 6, 7, 0, 5, 1, 0, 10),
    (0, 1, 3, 8, 0, 5, 1, 0, -30),
)


def array_constant(code: str, name: str) -> str:
    return "const\n  " + name + code.split("  " + name, 1)[1].split("\n  ]", 1)[0] + "\n  ]\n"


def object_type(code: str, name: str) -> str:
    start = code.index("  " + name + " {.packed.} = object\n")
    lines = code[start:].splitlines(keepends=True)
    body = [lines[0]]
    for line in lines[1:]:
        if line.strip() and not line.startswith("    "):
            break
        body.append(line)
    return "type\n" + "".join(body)


def source(*, real_io: bool = False) -> str:
    rf = RF.read_text()
    code = """type
  RfPriTxPowerTableRow = array[9, int16]
  RfPriPowerTableScope = enum rfPowerAll, rfPowerWlan, rfPowerBz
  RfPriPowerTablePhase = enum rfPowerFields, rfPowerCalibration
"""
    code += object_type(rf, "RfRegBlock")
    code += object_type(rf, "RfTxPowerCompTableBlock")
    for name in (
        "RfPriTxPowerTableDefault", "RfPriTxPowerTableIndexDefault",
        "RfPriWb03TxPowerRegisterBaseline",
        "RfPriTxcalReplayRecordIds", "RfPriBzTxcalTableStarts",
    ):
        code += array_constant(rf, name)
    if "  RfPriTxPowerRegisterBase:" in rf:
        code += array_constant(rf, "RfPriTxPowerRegisterBase")
    if "  RfPriBzTxPowerTableDefault:" in rf:
        code += array_constant(rf, "RfPriBzTxPowerTableDefault")
    for name in (
        "RfPriBzTargetPowerDefaultRecords", "RfPriBzTargetPowerLowRecords",
        "RfPriBzTargetPowerMidRecords", "RfPriBzTargetPowerHighRecords",
    ):
        code += "const " + name + rf.split("  " + name, 1)[1].split("\n", 1)[0] + "\n"
    rows = ",\n".join("  [" + ", ".join(f"{v}'i16" for v in row) + "]" for row in BZ_ROWS)
    code += "const VendorBzRows: array[9, RfPriTxPowerTableRow] = [\n" + rows + "\n]\n"
    code += r'''
const
  RfCalibTxcalRecordBaseWord = 26
  RfCalibBzTxcalRecordBaseByte = 0xF8
  RfCalibBzTxcalRecordStrideBytes = 8
  RfPriTxPowerRowTxGainTenthsIndex = 6
  RfPriTxPowerRowPowerThresholdTenthsIndex = 8
  WlXtal40M = 40000000'u32
  RfPriTxPowerSkipNone = 0'u32
  RfPriTxPowerSkipNoCalData = 1'u32
  RfPriTxPowerSkipWb03TxcalIncomplete = 2'u32
  RfPriTxPowerSkipWb03BzTxcalIncomplete = 3'u32
  RfPriTxPowerSkipWb03OptInDisabled = 4'u32
  RfPriTxPowerReplayBaseOnly = 0'u32
  RfPriTxPowerReplayCalRecords = 1'u32
  RfPriTxPowerReplayWb03RestoreBaseline = 2'u32
  RfPriTxPowerReplayWb03CompleteRecords = 3'u32
var
  bl808RfTxPowerTable = RfPriTxPowerTableDefault
  bl808RfTxPowerTableIndex = RfPriTxPowerTableIndexDefault
  bl808RfBzTargetPowerRecords = [1, 2, 3, 6]
  bl808RfLowPowerTableDelta: int16
  calibration: array[96, uint32]
  rfCalibDataGlobal: pointer
  bl808RfXtalIndex = 4'u32
  bl808WifiRfWb03ReplayCompleteTxPowerCal, wb03: bool
  nim_wifi_rf_tx_power_txcal_complete, nim_wifi_rf_tx_power_bz_txcal_complete: uint32
  nim_wifi_rf_tx_power_replay_mode, nim_wifi_rf_tx_power_replay_skip_reason: uint32
  writes, snapshots: int
proc rfPriIsWb03(): bool = wb03
proc xtalIndex(hz: uint32): uint32 = 4
proc rfPriSnapshotBzTxcalState(tag: uint32) =
  doAssert tag in [0xB1'u32, 0xB2, 0xB5]
  inc snapshots
var
  registerStorage: array[(sizeof(RfRegBlock) + 3) div 4, uint32]
  registerWrites: seq[tuple[index: int, value: uint32]]
  mmioWrites: seq[tuple[address: uint, value: uint32]]
  mmioReads: seq[uint]
  channelCompCalls: int
  recordWrites: bool
template hardware: untyped = cast[ptr RfTxPowerCompTableBlock](addr registerStorage[0])[]
template rf70: untyped = cast[ptr RfRegBlock](addr registerStorage[0])[]
template written: untyped = hardware.txPowerCompWords700
proc rfTxPowerCompTableRegs(): ptr RfTxPowerCompTableBlock = addr hardware
proc rfRegs(): ptr RfRegBlock = addr rf70
proc volatileLoad(p: ptr uint32): uint32 =
  if recordWrites: mmioReads.add(cast[uint](p))
  p[]
proc volatileStore(p: ptr uint32; value: uint32) =
  let base = cast[uint](addr hardware.txPowerCompWords700[0])
  let address = cast[uint](p)
  if recordWrites: mmioWrites.add((address, value))
  if address >= base and address < base + sizeof(written).uint:
    inc writes
    if recordWrites: registerWrites.add(((address - base).int div 4, value))
  p[] = value
proc updateReg32(p: ptr uint32; keep, value: uint32) =
  volatileStore(p, (volatileLoad(p) and keep) or value)
proc rf_pri_set_bz_channel_pwr_comp() = inc channelCompCalls
proc rfPriRf70ReplayWindow0Nibble(): uint32 = 9
'''
    for name in (
        "writeRfTxPowerCompTable", "rfPriReadTxPowerTable",
        "rfPriPublishTxPowerTable",
    ):
        if f"proc {name}(" in rf:
            code += procedure(rf, name)
    for name in (
        "rfSignExtend16", "rfCalibWord", "rfCalibHalf", "rfCalibByte",
        "rfCalibBzTxcalRecordByteOffset", "rfCalibBzTxcalRecordWord0",
        "rfCalibBzTxcalRecordWord1", "rfPriDivTowardZeroBy10",
        "rfPriApplyPowerRowToTable", "rfPriPowerTableIndicesValid",
        "rfPriApplyRuntimePowerTables",
        "rfPriApplyTxcalRecordToTable", "rfPriApplyBzTxcalRecordToTable",
        "rfPriTxcalReplayRecordsComplete", "rfPriBzTxcalReplayRecordsComplete",
        "rfPriWriteTxPowerTable", "rfPriResetTxPowerRuntimeTables",
        "rfPriApplyLowPowerRuntimeDelta",
    ):
        if f"proc {name}(" in rf:
            if name == "rfPriWriteTxPowerTable":
                if rf.count("\nproc rfPriWriteTxPowerTable(") > 1:
                    code += procedure(rf, name)
                code += rf[rf.rindex("\nproc rfPriWriteTxPowerTable(") + 1:].split("\nproc ", 1)[0] + "\n"
            else:
                code += procedure(rf, name)
    if real_io:
        code += procedure(rf, "rfPriSelectBzTargetPowerRecords")
        code += procedure(rf, "rf_pri_input_bz_target_power")
    code += "const RecordWriteTrace = " + ("true" if real_io else "false") + "\n"
    return code + r'''
proc setup() =
  rfPriResetTxPowerRuntimeTables()
  bl808RfBzTargetPowerRecords = [1, 2, 3, 6]
  calibration = default(typeof(calibration))
  rfCalibDataGlobal = nil
  wb03 = false
  bl808RfXtalIndex = 4
  bl808WifiRfWb03ReplayCompleteTxPowerCal = false
  registerStorage = default(typeof(registerStorage))
  registerWrites.setLen(0)
  mmioWrites.setLen(0)
  mmioReads.setLen(0)
  recordWrites = RecordWriteTrace
  writes = 0
  snapshots = 0
proc field(word: var uint32; start, width: int; value: int32) =
  for bit in 0 ..< width:
    let mask = 1'u32 shl (start + bit)
    if ((cast[uint32](value) shr bit) and 1) != 0:
      word = word or mask
    else:
      word = word and not mask
proc expectedPower(initial = default(array[43, uint32]);
    wlan = true; bz = true): array[43, uint32] =
  result = initial
  for slot in 0 ..< (if wlan: 13 else: 0):
    let index = bl808RfTxPowerTableIndex[slot]
    let row = bl808RfTxPowerTable[index.int]
    let gainWord = if slot < 8: slot div 4 else: 2
    let gainBit = if slot < 8: (slot mod 4) * 6 else: (slot - 8) * 6
    field(result[gainWord], gainBit, 6, row[8].int32 div 10)
    let start = 3 + slot * 2
    for spec in [(0, 26, 2), (1, 28, 2), (2, 18, 3),
                 (3, 21, 5), (4, 30, 2), (7, 11, 7)]:
      let (parameter, position, width) = spec
      field(result[start], position, width, row[parameter].int32)
    field(result[start + 1], 24, 3, row[5].int32)
    field(result[start + 1], 27, 1, row[6].int32)
  for slot in 0 ..< (if bz: 4 else: 0):
    let index = bl808RfBzTargetPowerRecords[slot]
    let row = VendorBzRows[index]
    field(result[34], slot * 6, 6, row[8].int32 div 10)
    let start = 35 + slot * 2
    for spec in [(0, 26, 2), (1, 28, 2), (2, 18, 3), (3, 21, 5), (7, 11, 7)]:
      let (parameter, position, width) = spec
      field(result[start], position, width, row[parameter].int32)
    field(result[start + 1], 24, 3, row[5].int32)
    field(result[start + 1], 27, 1, row[6].int32)
proc applyExpectedCal(words: var array[43, uint32]; start, offset: int) =
  let bytes = cast[ptr UncheckedArray[uint8]](addr calibration[0])
  let p0 = bytes[offset].int32
  let p1 = bytes[offset + 1].int32
  let p2 = bytes[offset + 2].int32 or (bytes[offset + 3].int32 shl 8)
  let p3 = bytes[offset + 4].int32 or (bytes[offset + 5].int32 shl 8)
  field(words[start], 0, 11, p2)
  field(words[start + 1], 2, 6, p1)
  field(words[start + 1], 8, 6, p0)
  field(words[start + 1], 14, 10, p3)
proc expectedReplay(initial = default(array[43, uint32]);
    wlan = true; bz = true): array[43, uint32] =
  result = expectedPower(initial, wlan, bz)
  if rfCalibDataGlobal != nil:
    for slot in 0 ..< (if wlan: 13 else: 0):
      let index = bl808RfTxPowerTableIndex[slot]
      applyExpectedCal(result, 3 + slot * 2, 0x68 + index.int * 8)
    for slot in 0 ..< (if bz: 4 else: 0):
      let index = bl808RfBzTargetPowerRecords[slot]
      applyExpectedCal(result, 35 + slot * 2, 0xF8 + index * 8)
proc expectedCalBaseline(initial: array[43, uint32];
    wlan = true; bz = true): array[43, uint32] =
  result = initial
  for domain in 0 ..< 2:
    if (domain == 0 and not wlan) or (domain == 1 and not bz): continue
    for slot in 0 ..< (if domain == 0: 13 else: 4):
      let a = (if domain == 0: 3 else: 35) + slot * 2
      field(result[a], 0, 11, cast[int32](RfPriWb03TxPowerRegisterBaseline[a]))
      field(result[a + 1], 2, 22,
            cast[int32](RfPriWb03TxPowerRegisterBaseline[a + 1] shr 2))
proc expectedDelta(delta: int16;
    rows: var array[18, RfPriTxPowerTableRow]; indices: var array[13, int16]) =
  rows = RfPriTxPowerTableDefault
  indices = RfPriTxPowerTableIndexDefault
  var quotient, remainder: int32
  if delta > 24:
    quotient = 2
  else:
    let bounded = max(delta.int32, -36)
    quotient = bounded div 12
    remainder = bounded mod 12
    if remainder > 8:
      inc quotient
      remainder -= 12
    elif remainder < -6:
      dec quotient
      remainder += 12
  for i in 7 ..< rows.len:
    rows[i][7] = cast[int16](((rows[i][7].int32 + remainder) and 0xFFFF).uint16)
    rows[i][8] = cast[int16](((rows[i][8].int32 - quotient * 30) and 0xFFFF).uint16)
  for i in 7 ..< indices.len: indices[i] -= quotient.int16
var randomState = 0x10325476'u32
proc randomWord(): uint32 =
  randomState = randomState xor (randomState shl 13)
  randomState = randomState xor (randomState shr 17)
  randomState = randomState xor (randomState shl 5)
  randomState
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_low_power_delta_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
for value in low(int16).int .. high(int16).int:
  var rows: array[18, RfPriTxPowerTableRow]
  var indices: array[13, int16]
  expectedDelta(value.int16, rows, indices)
  rfPriApplyLowPowerRuntimeDelta(value.int16)
  doAssert bl808RfTxPowerTable == rows, "wrong LP row update for " & $value
  doAssert bl808RfTxPowerTableIndex == indices, "wrong LP selection for " & $value
  doAssert bl808RfLowPowerTableDelta == value.int16
doAssert writes == 65536 * 29 and snapshots == 65536
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_runtime_power_and_calibration_registers(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for vector in 0 ..< 2000:
  setup()
  if vector != 0:
    for row in bl808RfTxPowerTable.mitems:
      for value in row.mitems: value = cast[int16]((randomWord() and 0xFFFF).uint16)
    for index in bl808RfTxPowerTableIndex.mitems: index = (randomWord() mod 18).int16
    for index in bl808RfBzTargetPowerRecords.mitems: index = (randomWord() mod 9).int
  if vector mod 2 != 0:
    for word in calibration.mitems: word = randomWord()
    rfCalibDataGlobal = addr calibration[0]
  let expected = expectedReplay()
  rfPriWriteTxPowerTable()
  doAssert written == expected, "incorrect RF register fields at vector " & $vector
  doAssert writes == (if rfCalibDataGlobal == nil: 38 else: 72) and snapshots == 1
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_wb03_replays_selected_calibration_records_including_zero(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for variant in 0 ..< 5:
  setup()
  wb03 = true
  bl808WifiRfWb03ReplayCompleteTxPowerCal = variant >= 2
  for word in calibration.mitems: word = 0x03212010
  if variant != 0: rfCalibDataGlobal = addr calibration[0]
  for slot in 7 ..< 13: bl808RfTxPowerTableIndex[slot] = (slot + 5).int16
  if variant == 3: calibration[26 + 17 * 2] = 0; calibration[27 + 17 * 2] = 0
  if variant == 4: calibration[(0xF8 + 6 * 8) div 4] = 0; calibration[(0xFC + 6 * 8) div 4] = 0
  let expected = expectedReplay()
  rfPriWriteTxPowerTable()
  doAssert written == expected and writes == (if variant == 0: 38 else: 72)
  doAssert nim_wifi_rf_tx_power_replay_mode == (if variant == 0: 0'u32 else: 1'u32)
  let reason = if variant == 0: 1'u32 else: 0'u32
  doAssert nim_wifi_rf_tx_power_replay_skip_reason == reason
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_row_field_preservation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for wlan in [false, true]:
  for vector in 0 ..< 1000:
    var row: RfPriTxPowerTableRow
    for value in row.mitems: value = cast[int16]((randomWord() and 0xFFFF).uint16)
    var words: array[43, uint32]
    for word in words.mitems: word = randomWord()
    var expected = words
    let start = vector mod 42
    for spec in [(0, 26, 2), (1, 28, 2), (2, 18, 3), (3, 21, 5), (7, 11, 7)]:
      let (parameter, position, width) = spec
      field(expected[start], position, width, row[parameter].int32)
    if wlan: field(expected[start], 30, 2, row[4].int32)
    field(expected[start + 1], 24, 3, row[5].int32)
    field(expected[start + 1], 27, 1, row[6].int32)
    rfPriApplyPowerRowToTable(words, start, row, wlan)
    doAssert words == expected, "power-row update changed unrelated register bits"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_invalid_indices_do_not_publish(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for variant in 0 ..< 4:
  setup()
  case variant
  of 0: bl808RfTxPowerTableIndex[0] = -1
  of 1: bl808RfTxPowerTableIndex[12] = 18
  of 2: bl808RfBzTargetPowerRecords[0] = -1
  else: bl808RfBzTargetPowerRecords[3] = 9
  var words: array[43, uint32]
  doAssert not rfPriApplyRuntimePowerTables(words)
  doAssert words == default(typeof(words))
  rfCalibDataGlobal = addr calibration[0]
  for word in calibration.mitems: word = 0x03212010
  rfPriWriteTxPowerTable()
  doAssert writes == 0 and snapshots == 0
''')
