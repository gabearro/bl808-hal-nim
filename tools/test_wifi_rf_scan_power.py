"""Check RF state ownership at scan/TX boundaries and total-power publication."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_power_replay import RF, source
import test_wifi_channel_handoff as handoff
import test_wifi_dma_lifetime as dma
import test_wifi_station_rx_filter as rx_filter
import test_wifi_station_tx_build as station


def constant_imports(code: str) -> str:
    for name in ("states", "status_codes"):
        code = code.replace(f"import bl808/wifi/fw_constants/{name}",
                            f'import "{ROOT / "src/bl808/wifi/fw_constants" / name}"')
    return code


def total_source() -> str:
    rf = RF.read_text()
    code = source(real_io=True) + r'''
var
  bl808RfTempPowerComp, bl808RfAppliedPowerComp, bl808RfTxGainComp: int16
  bl808RfChannelPowerComp: array[14, int16]
  bl808RfChipVersion = 1'u8
'''
    for name in ("rfPriApplyTotalPowerRuntimeDelta", "rfPriWriteTotalPowerComp",
                 "rf_pri_set_channel_total_pwr_comp", "rf_pri_input_chip_ver"):
        if f"proc {name}" in rf:
            code += rf_procedure(rf, name)
    return code + r'''
proc signedHalf(value: int64): int16 =
  let bits = value and 65535
  (if bits >= 32768: bits - 65536 else: bits).int16
proc randomizeHardware() =
  for word in registerStorage.mitems: word = randomWord()
  for word in calibration.mitems: word = randomWord()
  rfCalibDataGlobal = addr calibration[0]
  mmioWrites.setLen(0)
  registerWrites.setLen(0)
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_total_power_direct_path_has_no_board_or_crystal_bypass(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, total_source() + r'''
for board in [false, true]:
  for crystal in 0'u32 .. 5:
    for version in [0'u32, 1, 2, 98, 100, 255]:
      for vector in 0 ..< 120:
        setup()
        randomizeHardware()
        wb03 = board
        bl808RfXtalIndex = crystal
        bl808RfChipVersion = version.uint8
        let channel = 1 + (vector mod 14)
        bl808RfTempPowerComp = signedHalf(randomWord().int64)
        bl808RfAppliedPowerComp = signedHalf(randomWord().int64)
        bl808RfChannelPowerComp[channel - 1] = signedHalf(randomWord().int64)
        bl808RfTxGainComp = signedHalf(randomWord().int64)
        let total = signedHalf(bl808RfTempPowerComp.int64 - bl808RfAppliedPowerComp.int64 +
          bl808RfChannelPowerComp[channel - 1].int64)
        let value = bl808RfTxGainComp.int64 + clamp(total.int64, -16'i64, 16'i64)
        let beforeCal = calibration
        let beforeTable = bl808RfTxPowerTable
        let beforeIndex = bl808RfTxPowerTableIndex
        var wanted = registerStorage
        wanted[0x704 div 4] = (wanted[0x704 div 4] and 0x00FFFFFF'u32) or
          (((value and 255).uint32) shl 24)
        wanted[0x7AC div 4] = (wanted[0x7AC div 4] and 0xFFFFFF00'u32) or
          ((value - 4) and 255).uint32
        rf_pri_set_channel_total_pwr_comp(channel.uint32)
        doAssert registerStorage == wanted, "total power compensation changed the wrong RF fields or was skipped"
        doAssert mmioWrites == @[(cast[uint](addr rf70.txPowerComp704), wanted[0x704 div 4]),
          (cast[uint](addr rf70.txPowerComp7ac), wanted[0x7AC div 4])]
        doAssert calibration == beforeCal and bl808RfTxPowerTable == beforeTable
        doAssert bl808RfTxPowerTableIndex == beforeIndex
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_chip99_total_power_resets_tables_without_replaying_calibration(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, total_source() + r'''
for delta in -40 .. 40:
  for vector in 0 ..< 10:
    setup()
    randomizeHardware()
    wb03 = true
    for row in bl808RfTxPowerTable.mitems:
      for value in row.mitems: value = signedHalf(randomWord().int64)
    for index in bl808RfTxPowerTableIndex.mitems: index = -123
    bl808RfChipVersion = 1
    rf_pri_input_chip_ver(0)
    doAssert bl808RfChipVersion == 1
    rf_pri_input_chip_ver(99)
    bl808RfTempPowerComp = delta.int16
    bl808RfAppliedPowerComp = 0
    bl808RfChannelPowerComp[5] = 0
    bl808RfTxGainComp = 123
    let beforeCal = calibration
    let before = registerStorage
    let beforePower = hardware.txPowerCompWords700
    let beforeDelta = bl808RfLowPowerTableDelta
    let bounded = clamp(delta, -16, 16)
    var quotient = bounded div 4
    var remainder = bounded mod 4
    if remainder >= 2:
      inc quotient
      remainder -= 4
    elif remainder <= -3:
      dec quotient
      remainder += 4
    var rows = RfPriTxPowerTableDefault
    var indices = RfPriTxPowerTableIndexDefault
    for row in rows.mitems:
      row[7] = signedHalf(row[7].int64 + remainder)
      row[8] = signedHalf(row[8].int64 - quotient * 10)
    var valid = true
    for index in indices.mitems:
      index = signedHalf(index.int64 - quotient)
      valid = valid and index >= 0 and index < rows.len.int16
    rf_pri_set_channel_total_pwr_comp(6)
    doAssert bl808RfTxPowerTable == rows and bl808RfTxPowerTableIndex == indices,
      "chip-99 total compensation did not reset and adjust all rows and indices"
    doAssert calibration == beforeCal and bl808RfLowPowerTableDelta == beforeDelta
    var wanted = before
    var trace: seq[tuple[index: int, value: uint32]]
    if valid:
      let power = expectedPower(beforePower, bz = false)
      for i in 0 ..< power.len: wanted[0x700 div 4 + i] = power[i]
      for i in countdown(2, 0): trace.add((i, power[i]))
      for slot in countdown(12, 0):
        let i = 3 + slot * 2
        trace.add((i + 1, power[i + 1]))
        trace.add((i, power[i]))
    doAssert registerStorage == wanted and registerWrites == trace and mmioWrites.len == trace.len,
      "chip-99 path must publish only WLAN power fields, not calibration or direct compensation"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scan_filter_does_not_replay_rf_latches(tmp_path: Path, mode: str) -> None:
    code = rx_filter.source().replace("proc rfPriApplyWb03ScanRxLatches() = discard",
        "var rfReplays: int\nproc rfPriApplyWb03ScanRxLatches() = inc rfReplays")
    run_program(tmp_path, mode, constant_imports(code) + r'''
for passive in 0'u8 .. 255:
  setup(0)
  setupRadio(0x3503858C, 0x40000001, 0)
  rfReplays = 0
  applyScanChannelRxFilter(passive)
  let bits = if (passive and 1) == 0: 0x2200'u32 else: 0x2000'u32
  doAssert mm.rxFilterExtra == (0x40000001'u32 or bits)
  doAssert writes == @[(MACHW_RX_CNTRL_REG, mm.rxFilterBase or mm.rxFilterExtra)]
  doAssert rfReplays == 0, "scan RX filter programming invoked an unmatched RF replay"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scan_mac_activation_does_not_replace_rf_state(tmp_path: Path, mode: str) -> None:
    platform = handoff.PRE_SWITCH_PLATFORM.replace(
        "proc rfPriPrepareWb03MacActiveScanState() = discard",
        'proc rfPriPrepareWb03MacActiveScanState() = events.add(("rf-replay", 0\'u))',
    )
    code = handoff.PLATFORM + platform + handoff.CFM_STUBS
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_pre_switch_channel")
    run_program(tmp_path, mode, code + r'''
for flags in [8'u8, 12, 0x28, 0x2C]:
  reset()
  mgmt.activeList.first = nil
  env.flags = flags
  chan_pre_switch_channel()
  doAssert env.currentCtxt == (addr contexts[3]) and env.scheduledCtxt == nil
  doAssert events == @[("timer-clear", 76'u), ("phy", 3'u), ("status", 4'u),
    ("basic", 75'u), ("pm", 0'u), ("active", 0'u)],
    "scan MAC activation inserted an RF replay or changed the channel handoff order"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_station_builders_do_not_replace_rf_state(tmp_path: Path, mode: str) -> None:
    code = station.program_source().replace("proc rfPriApplyWb03AuthTxLatches() = observe(5)",
        "var rfReplays: int\nproc rfPriApplyWb03AuthTxLatches() = inc rfReplays")
    run_program(tmp_path, mode, constant_imports(code) + r'''
for kind in 0 .. 1:
  setup(kind)
  rfReplays = 0
  perform(kind)
  doAssert pushes == 1 and failures == 0
  doAssert rfReplays == 0, "station TX builder invoked an unmatched RF replay"
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_dma_does_not_replay_rf_latches(tmp_path: Path, mode: str, monkeypatch) -> None:
    original = dma.instrument_platform
    monkeypatch.setattr(dma, "instrument_platform", lambda: original().replace(
        'proc rfPriApplyWb03AuthTxLatches() = observe("rf")',
        'proc rfPriApplyWb03AuthTxLatches() = doAssert false, "TX DMA invoked an unmatched RF replay"',
    ))
    dma.test_dma_lifetime(tmp_path, mode, None)
