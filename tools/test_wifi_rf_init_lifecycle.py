"""RF initialization and saved-register restore against rf_pri.c.o."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, object_type, source


def core_procedure(code: str, name: str) -> str:
    body = procedure(code[code.rindex("\nproc " + name + "(") + 1:], name)
    return re.split(r"^(?:type|var|const|let)\b", body, maxsplit=1, flags=re.M)[0] + "\n"


def restore_source() -> str:
    rf = RF.read_text()
    code = source(real_io=True).replace(
        "proc rfPriRf70ReplayWindow0Nibble(): uint32 = 9",
        "proc rfPriRf70ReplayWindow0Nibble(): uint32 = "
        "(cast[ptr UncheckedArray[uint32]](rfCalibDataGlobal)[3] shr 24) and 15",
    )
    code += "const RfCalibRccalReplayWordIndex = 2\nconst RfPriTxcalSearchRecords = 18\n"
    code += "proc rfPriSnapshotStage(tag: uint32) = discard\n"
    for name in ("rfCalibHasRestoreData", "rfPriReplayRxcalRegs", "replayRfPriCalRegisters",
                 "rf_pri_restore_cal_reg"):
        if f"proc {name}(" in rf:
            code += core_procedure(rf, name)
    return code + r'''
type RegisterImage = typeof(registerStorage)
proc expectedRestore(initial: RegisterImage): RegisterImage =
  result = initial
  for group in 0 ..< 2:
    for lane in 0 ..< 4:
      let saved = calibration[18 + group * 4 + (lane div 2) * 2]
      field(result[(0x168 + group * 4) div 4], lane * 8, 6,
            cast[int32](saved shr ((lane mod 2) * 8)))
  for lane in 0 ..< 4:
    field(result[0x84 div 4], lane * 8, 6, cast[int32](calibration[2] shr ((3 - lane) * 6)))
  field(result[0x70 div 4], 0, 4, cast[int32](calibration[3] shr 24))
  var table: array[43, uint32]
  for i in 0 ..< table.len: table[i] = initial[0x700 div 4 + i]
  for slot, index in bl808RfTxPowerTableIndex:
    applyExpectedCal(table, 3 + slot * 2, 0x68 + index.int * 8)
  for slot, index in bl808RfBzTargetPowerRecords:
    applyExpectedCal(table, 35 + slot * 2, 0xF8 + index * 8)
  for i, value in table: result[0x700 div 4 + i] = value
  for record in 0 ..< 4:
    field(result[0x170 div 4 + record], 16, 11, cast[int32](calibration[18 + record * 2] shr 16))
    field(result[0x170 div 4 + record], 0, 10, cast[int32](calibration[19 + record * 2]))
proc restoreTrace(expected: RegisterImage): seq[tuple[address: uint, value: uint32]] =
  template put(offset: int) =
    result.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
  for offset in [0x168, 0x16C, 0x84, 0x70]: put(offset)
  for slot in 0 ..< 13:
    put(0x70C + slot * 8)
    put(0x710 + slot * 8)
  for slot in 0 ..< 4:
    put(0x78C + slot * 8)
    put(0x790 + slot * 8)
  for offset in [0x170, 0x174, 0x178, 0x17C]: put(offset)
proc seedSaved(pattern: int) =
  for word in calibration.mitems:
    word = case pattern
      of 0: 0'u32
      of 1: randomWord()
      else: 0'u32
  if pattern == 2:
    calibration[26] = 0x03FF2010
    calibration[27] = 0x000003FF
  rfCalibDataGlobal = addr calibration[0]
proc seedImage() =
  setup()
  for word in registerStorage.mitems: word = randomWord()
'''


def init_source(*, real_restore: bool = False) -> str:
    rf = RF.read_text()
    code = restore_source().replace("rfPriWriteTxPowerTable", "rawRfPriWriteTxPowerTable")
    code = code.replace("replayRfPriCalRegisters", "rawReplayRfPriCalRegisters")
    code += object_type(rf, "RfDfeInitBlock")
    for name in (
        "RfTxcalParam2Mask", "RfTxcalParam2EnableBit", "RfTxcalParam3Mask", "RfTxcalParam3SignBit",
        "RfPriWb03RxcalTosdacReplayMask", "RfPriWb03RxcalTosdacSeed",
        "RfPriWb03RfcEntryRf1600Seed", "RfPriWb03ScanRf80ListenSeed", "RfPriWb03ScanRfbcSeed",
        "RfPriWb03ScanRf1608Seed", "RfPriWb03ScanRf1618Seed", "RfPriWb03ScanRf8cSeed",
    ):
        lines = rf.splitlines()
        for i, line in enumerate(lines):
            if line.startswith("  " + name + " ="):
                block = [line]
                for continuation in lines[i + 1:]:
                    if not continuation.startswith("    "):
                        break
                    block.append(continuation)
                code += "const\n" + "\n".join(block) + "\n"
                break
    code += r'''
const wifiOnly = 1'u32
var
  dfe: RfDfeInitBlock
  bl808RfColdInit, bl808RfMode: uint32
  bl808RfPriXtal40mFlag: uint8
  wlCalGlobal: pointer
  stages: seq[int]
  fullCalls, restoreCalls: int
  published74, published600: uint32
proc rfDfeInitRegs(): ptr RfDfeInitBlock = addr dfe
proc radioPhyModeFromApi(value: uint8): uint32 = value.uint32
proc nim_wifi_rf_pri_init_entry_breakpoint() = discard
proc rfPriEnsureDeviceInfo() = discard
proc rfPhyTraceCheckpoint(tag: uint32) = discard
proc rfPriEfuseInit() =
  doAssert rfCalibDataGlobal == wlCalGlobal
  stages.add(2)
proc rf_pri_xtalfreq() = stages.add(3)
proc writeRfPriFixedValueRegs() = stages.add(4)
proc rfPriWifiPllConfig() = stages.add(5)
proc prepareBl808RfColdRegisters() = stages.add(9)
proc runRfPriFullCalRestoreBaseline() =
  stages.add(6)
  inc fullCalls
  volatileStore(addr rf70.txcalParam74, published74)
  volatileStore(addr rf70.txcalTosdac600, published600)
proc rfPriWaitConfigIdleForWb03RfcEntry() = discard
proc rfPriWriteTxPowerTable(scope: RfPriPowerTableScope = rfPowerAll;
    phases: set[RfPriPowerTablePhase] = {rfPowerFields, rfPowerCalibration}) =
  doAssert phases == {rfPowerFields}
  stages.add(8)
  rawRfPriWriteTxPowerTable(scope, phases)
'''
    code += "proc replayRfPriCalRegisters() =\n  stages.add(7)\n  inc restoreCalls\n"
    code += "  rawReplayRfPriCalRegisters()\n" if real_restore else "  discard\n"
    for name in ("rf_pri_init_calib_mem", "rfCalibHasTxcalData", "rfPriApplyWb03RuntimeLatches",
                 "rfPriApplyWb03RxcalTosdacLatch", "rfPriApplyWb03RfcEntryBaseline", "rf_pri_init"):
        if f"proc {name}(" in rf:
            code += core_procedure(rf, name)
    return code + r'''
proc initSetup(pattern: int) =
  seedImage()
  seedSaved(pattern)
  wlCalGlobal = rfCalibDataGlobal
  rfCalibDataGlobal = nil
  let words = cast[ptr UncheckedArray[uint32]](addr dfe)
  for i in 0 ..< sizeof(dfe) div 4: words[i] = randomWord()
  stages.setLen(0)
  bl808RfPriXtal40mFlag = 0
  fullCalls = 0
  restoreCalls = 0
  published74 = randomWord()
  published600 = randomWord()
proc appendPowerTrace(expected: RegisterImage;
    trace: var seq[tuple[address: uint, value: uint32]]) =
  template put(offset: int) =
    trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
  for i in countdown(2, 0): put(0x700 + i * 4)
  for slot in countdown(12, 0):
    put(0x710 + slot * 8)
    put(0x70C + slot * 8)
  put(0x788)
  for slot in 0 ..< 4:
    put(0x78C + slot * 8)
    put(0x790 + slot * 8)
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_cold_argument_alone_selects_calibration_or_restore(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, init_source() + r'''
for cold in [0'u32, 1, 2, 0x80000000'u32, high(uint32)]:
  for pattern in 0 ..< 3:
    for board in [false, true]:
      initSetup(pattern)
      wb03 = board
      let saved = calibration
      rf_pri_init(cold, 0x1234)
      doAssert fullCalls == (cold != 0).int and restoreCalls == (cold == 0).int,
        "saved values changed the explicit cold/warm branch"
      doAssert stages == @[2, 3, 4, 5, (if cold != 0: 6 else: 7), 8]
      doAssert calibration == saved and rfCalibDataGlobal == wlCalGlobal
      doAssert bl808RfColdInit == cold and bl808RfMode == 0x34
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_40mhz_wlan_cold_init_uses_bl808_precalibration_profile(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, init_source() + r'''
for cold in [0'u32, 1]:
  for api in [wifiOnly, 2'u32, 3]:
    for xtal40 in [0'u8, 1]:
      initSetup(1)
      bl808RfPriXtal40mFlag = xtal40
      rf_pri_init(cold, api)
      let native = cold != 0 and api == wifiOnly and xtal40 != 0
      if native:
        doAssert stages == @[3, 9, 6, 8], "40 MHz WLAN boot used the inherited RF profile"
      else:
        doAssert stages == @[2, 3, 4, 5, (if cold != 0: 6 else: 7), 8]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("cold", [False, True])
def test_initializer_preserves_vendor_mmio_order_without_late_patches(tmp_path: Path, mode: str, cold: bool) -> None:
    code = init_source() + f"const Cold = {str(cold).lower()}\n"
    run_program(tmp_path, mode, code + r'''
for board in [false, true]:
  for crystal in 0'u32 ..< 6:
    for vector in 0 ..< 100:
      initSetup(1)
      wb03 = board
      bl808RfXtalIndex = crystal
      var expected = registerStorage
      var expectedDfe = dfe
      expectedDfe.dfeTrim824 = (expectedDfe.dfeTrim824 and 0x9FFFFFFF'u32) or 0x40000000'u32
      var trace = @[(cast[uint](addr dfe.dfeTrim824), expectedDfe.dfeTrim824)]
      template put(offset: int; keep, value: uint32) =
        expected[offset div 4] = (expected[offset div 4] and keep) or value
        trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
      put(0x220, 0xFFFFE67D'u32, 0)
      put(0x220, 0xFFFFFF9E'u32, 0)
      when Cold:
        put(0x74, 0, published74)
        put(0x600, 0, published600)
      var beforePower: array[43, uint32]
      for i in 0 ..< beforePower.len: beforePower[i] = expected[0x700 div 4 + i]
      let power = expectedPower(beforePower)
      for i, value in power: expected[0x700 div 4 + i] = value
      appendPowerTrace(expected, trace)
      put(0x2C, 0xFFFFFFFF'u32, 6)
      put(0x2C, 0xFFFFFFFF'u32, 0x4021)
      put(0x63C, 0xFFFFFFFF'u32, 0x8080)
      put(0x220, 0xFFFFF9FF'u32, 0)
      rf_pri_init(Cold.uint32, 0)
      doAssert registerStorage == expected and dfe == expectedDfe,
        "initializer overwrote calibrated state or unowned register bits"
      doAssert mmioWrites == trace, "initializer added or reordered physical stores"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_restore_publishes_zero_and_sparse_saved_fields(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, restore_source() + r'''
for pattern in 0 ..< 3:
  for vector in 0 ..< 1000:
    seedImage()
    seedSaved(pattern)
    let saved = calibration
    let expected = expectedRestore(registerStorage)
    rf_pri_restore_cal_reg()
    doAssert registerStorage == expected and calibration == saved,
      "saved zero fields did not replace their owned restore fields"
    doAssert mmioWrites == restoreTrace(expected), "restore omitted or reordered a store"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_nil_restore_remains_noop(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, restore_source() + r'''
seedImage()
let before = registerStorage
rfCalibDataGlobal = nil
rf_pri_restore_cal_reg()
doAssert registerStorage == before and mmioReads.len == 0 and mmioWrites.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_warm_init_with_real_restore_keeps_saved_registers(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, init_source(real_restore=True) + r'''
for pattern in 0 ..< 3:
  for board in [false, true]:
    for vector in 0 ..< 100:
      initSetup(pattern)
      wb03 = board
      let saved = calibration
      let expected = expectedRestore(registerStorage)
      rf_pri_init(0, 0)
      doAssert fullCalls == 0 and restoreCalls == 1 and calibration == saved
      for offset in [0x168, 0x16C, 0x84, 0x70, 0x170, 0x174, 0x178, 0x17C, 0x600, 0x80, 0x90, 0x88, 0xA4, 0xBC, 0x608, 0x618, 0x8C]:
        doAssert registerStorage[offset div 4] == expected[offset div 4],
          "warm initializer replaced restored or unowned register fields"
''')
