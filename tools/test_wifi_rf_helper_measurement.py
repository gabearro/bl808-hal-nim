"""Exercise the RF archive's measurement and signal-generator contracts."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_power_replay import RF


def source() -> str:
    rf = RF.read_text()
    code = r'''
type RfRegs = object
  measureCtrl618, measureMode61c, measureI620, measureQ624: uint32
  calSingenCtrl20c, calSingenPrep210, calSingenMeasurePrep21c: uint32
  calSingenAmpLo214, calSingenAmpHi218: uint32
  rbbRccalCtrl80, rxMode220, channelTuneGate228: uint32
  bandwidthCtrl94, scanSynthControl608, txcalDfe88, roscalCtrl7c: uint32
  channelTuneCtrl26c, baseCtrl1, rxModeDumpReadback224: uint32
const
  RfMeasureReadyMask = 0x10000000'u32
  RfRccalWaitLimit = 10000
var
  bank: RfRegs
  writes: seq[tuple[reg: pointer, clearMask, setMask: uint32]]
  readyAfter, polls: int
  nim_wifi_rf_measure_wait_timeout_count: uint32
  bandwidthCalls: seq[uint32]
  waitCalls: seq[tuple[us: uint32, afterWrites: int]]
  dumpReadAfterWrites: seq[int]
proc rfRegs(): ptr RfRegs = addr bank
proc waitRfUs(us: uint32) = waitCalls.add((us, writes.len))
proc rf_pri_set_bandwidth(bandwidth: uint32) =
  doAssert writes.len == 7, "RF bandwidth callback ran before the final register write"
  bandwidthCalls.add(bandwidth)
proc updateReg32(reg: ptr uint32; clearMask, setMask: uint32) =
  writes.add((cast[pointer](reg), clearMask, setMask))
  reg[] = (reg[] and clearMask) or setMask
proc volatileLoad(reg: ptr uint32): uint32 =
  if reg == addr bank.rxModeDumpReadback224:
    dumpReadAfterWrites.add(writes.len)
  if reg == addr bank.measureCtrl618:
    inc polls
    if polls >= readyAfter:
      bank.measureCtrl618 = bank.measureCtrl618 or RfMeasureReadyMask
  reg[]
'''
    for name in (
        "signedRfAverageMeasurement",
        "rfcPowerMeasureClockHz",
        "rfcPowerMeasureFrequencyWord",
        "rfc_power_meas",
        "rfc_sg_start",
        "rfc_sg_stop",
        "rfc_rf_fsm_force",
        "waitRfRfcUs", "rfc_rc_fsm_force",
        "rfc_wlan_mode_force",
        "rfc_dump",
        "rfc_config_bandwidth",
    ):
        code += rf_procedure(rf, name)
    return code


def mode_source() -> str:
    return r'''
type
  RadioPhyMode = enum wifiOnly = 1, bleOnly = 2, wifiBleCoex = 3
  RfRegs = object
    baseCtrl1, synthCtrl2c, priModeCtrl30: uint32
var
  bank: RfRegs
  bl808RfMode: RadioPhyMode
  writes: seq[tuple[reg: pointer, keep, value: uint32]]
proc rfRegs(): ptr RfRegs = addr bank
proc radioPhyModeFromApi(mode: uint8): RadioPhyMode =
  case mode
  of 2: bleOnly
  of 3: wifiBleCoex
  else: wifiOnly
proc volatileStore(reg: ptr uint32; value: uint32) =
  writes.add((cast[pointer](reg), 0'u32, value))
  reg[] = value
proc updateReg32(reg: ptr uint32; keep, value: uint32) =
  writes.add((cast[pointer](reg), keep, value))
  reg[] = (reg[] and keep) or value
''' + "".join(rf_procedure(RF.read_text(), name) for name in (
        "programRfPriModeRegisters", "rf_pri_config_mode",
    ))


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_rf_noop_entry_points(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = r'''
var bl808RfChannelMhz, bl808RfBandwidthMhz: uint32
'''
    code += rf_procedure(rf, "rf_pri_update_param")
    code += rf_procedure(rf, "rf_pri_set_bandwidth")
    run_program(tmp_path, mode, code + r'''
for input in [0'u32, 20'u32, 2412'u32, high(uint32)]:
  bl808RfChannelMhz = 0x12345678'u32
  bl808RfBandwidthMhz = 0x87654321'u32
  rf_pri_update_param(input)
  rf_pri_set_bandwidth(input)
  doAssert bl808RfChannelMhz == 0x12345678'u32
  doAssert bl808RfBandwidthMhz == 0x87654321'u32
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rf_mode_control_register_sequence(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, mode_source() + r'''
for requested in [0'u32, 1, 2, 3, 4, 5, 6, 7, 8, 9, 255, high(uint32)]:
  for seed in [0'u32, 0xA5A5_5A5A'u32, high(uint32)]:
    bank = RfRegs(baseCtrl1: seed, synthCtrl2c: seed, priModeCtrl30: seed)
    writes.setLen(0)
    rf_pri_config_mode(requested)
    let (keep, value) =
      case requested
      of 3'u32: (0x21F0_FEFF'u32, 0x21F0_6E00'u32)
      of 4'u32: (0x2DF8_F8FF'u32, 0x2DF8_7800'u32)
      of 5'u32: (0xCEFF_F8FF'u32, 0xCEFF_7800'u32)
      of 6'u32: (0x8FFF_FEFF'u32, 0x8FFF_7E00'u32)
      else: ((0xCF09'u32 shl 12) + 0xFF, 0xCF00'u32 shl 12)
    doAssert writes == @[
      (cast[pointer](addr bank.baseCtrl1), 0xFFFF_FFFD'u32, 0'u32),
      (cast[pointer](addr bank.synthCtrl2c), 0'u32, 0'u32),
      (cast[pointer](addr bank.priModeCtrl30), high(uint32), 0x2'u32),
      (cast[pointer](addr bank.priModeCtrl30), keep, value)]
    doAssert bank.baseCtrl1 == (seed and 0xFFFF_FFFD'u32)
    doAssert bank.synthCtrl2c == 0
    doAssert bank.priModeCtrl30 == (((seed or 2'u32) and keep) or value)
    doAssert bl808RfMode ==
      (if requested == 2: bleOnly elif requested == 3: wifiBleCoex else: wifiOnly)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rf_measurement_and_signal_generator(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
doAssert rfcPowerMeasureFrequencyWord(0, 0) == 0x0008_0000'u32
doAssert rfcPowerMeasureFrequencyWord(0, 160_000_000) == 0x0010_0000'u32
doAssert rfcPowerMeasureFrequencyWord(0, -160_000_000) == 0'u32
doAssert rfcPowerMeasureFrequencyWord(1, 10_000_000) == 0x000A_0000'u32
doAssert rfcPowerMeasureFrequencyWord(2, -8_000_000) == 0x0004_0000'u32

bank.measureI620 = 0x0100_0001'u32
bank.measureQ624 = 0x00FF_FFFE'u32
readyAfter = RfRccalWaitLimit + 5
var iSample, qSample: int32
let measuredPower = rfc_power_meas(0, 160_000_000, 7, 9,
  addr iSample, addr qSample)
doAssert polls == readyAfter and nim_wifi_rf_measure_wait_timeout_count == 1
doAssert iSample == -16_777_215 and qSample == 16_777_214
doAssert measuredPower == 0xFA00_0005'u32
doAssert writes.len == 11
doAssert writes[3] == (cast[pointer](addr bank.measureMode61c),
  0x0000_FFFF'u32, 0x0007_0000'u32)
doAssert writes[4] == (cast[pointer](addr bank.measureMode61c),
  0xFFEF_FFFF'u32, 0x0010_0000'u32)
doAssert bank.measureMode61c == 0x0017_0400'u32
doAssert writes[6] == (cast[pointer](addr bank.measureCtrl618),
  0xFFF0_0000'u32, 0'u32)
doAssert writes[8] == (cast[pointer](addr bank.measureCtrl618),
  0xDFFF_FFFF'u32, 0x2000_0000'u32)

bank = default(RfRegs)
writes.setLen(0)
polls = 0
readyAfter = 1
doAssert rfc_power_meas(0, -160_000_000, 0, 0, nil, nil) == 0'u32
doAssert writes[4].setMask == 0'u32
doAssert writes[6].setMask == 0'u32

bank = RfRegs(measureMode61c: 0xABCD_FFFF'u32)
writes.setLen(0)
polls = 0
readyAfter = 1
doAssert rfc_power_meas(2, 0, 0xFFFF_1234'u32, 0, nil, nil) == 0'u32
doAssert writes[3] == (cast[pointer](addr bank.measureMode61c),
  0x0000_FFFF'u32, 0x1234_0000'u32)
doAssert writes[4].setMask == 0x0010_0000'u32
doAssert writes[6].setMask == 0x0008_0000'u32
doAssert bank.measureMode61c == 0x1234_0400'u32

for sample in [(34_374_999'i32, 440'u32, 1'u32, 0xC000_0000'u32),
               (86_562_500'i32, 83'u32, 0x8000_0001'u32, 0xC000_0000'u32),
               (-34_374_999'i32, 440'u32, 1'u32, 0x4000_0000'u32),
               (low(int32), 161'u32, 0x8000_0000'u32, 0x4000_0000'u32),
               (-34_374_999'i32, 440'u32, 0'u32, 0'u32)]:
  bank = RfRegs(calSingenPrep210: high(uint32),
    calSingenMeasurePrep21c: 0xA5A5_5A5A'u32)
  writes.setLen(0)
  rfc_sg_start(sample[0], 1200, sample[2])
  doAssert writes.len == 10
  doAssert writes[3] == (cast[pointer](addr bank.calSingenPrep210),
    0x0FFF_FFFF'u32, 0'u32)
  doAssert writes[4] == (cast[pointer](addr bank.calSingenPrep210),
    0xFFFF_0FFF'u32, 0'u32)
  doAssert bank.calSingenPrep210 == 0x0FFF_0FFF'u32
  doAssert bank.calSingenMeasurePrep21c == 0xA5A5_5A5A'u32
  doAssert (bank.calSingenCtrl20c shr 16 and 0x3FF'u32) == sample[1]
  doAssert (bank.calSingenCtrl20c and 0x8000_0000'u32) != 0
  doAssert (bank.calSingenAmpLo214 and 0x7FF'u32) == 1023
  doAssert (bank.calSingenAmpHi218 and 0xC000_0000'u32) == sample[3]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rf_bandwidth_register_sequence(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for bandwidth in [0'u32, 1, 2, high(uint32)]:
  bank = RfRegs(rbbRccalCtrl80: 0xA5A5_5A5A'u32,
    rxMode220: high(uint32), channelTuneGate228: high(uint32),
    bandwidthCtrl94: high(uint32), scanSynthControl608: high(uint32),
    txcalDfe88: high(uint32), roscalCtrl7c: high(uint32))
  writes.setLen(0)
  bandwidthCalls.setLen(0)
  rfc_config_bandwidth(bandwidth)
  let isWide = bandwidth == 1'u32
  doAssert writes.len == 7 and bandwidthCalls == @[if isWide: 20'u32 else: 10'u32]
  doAssert writes[0] == (cast[pointer](addr bank.rxMode220),
    0xFEFF_FFFF'u32, if bandwidth == 0: 0'u32 else: 0x0100_0000'u32)
  doAssert writes[1] == (cast[pointer](addr bank.bandwidthCtrl94),
    0xEFFF_FFFF'u32, 0x1000_0000'u32)
  doAssert writes[2] == (cast[pointer](addr bank.bandwidthCtrl94),
    0xDFFF_FFFF'u32, if isWide: 0x2000_0000'u32 else: 0'u32)
  doAssert writes[3] == (cast[pointer](addr bank.scanSynthControl608),
    0xDFFF_FFFF'u32, if isWide: 0'u32 else: 0x2000_0000'u32)
  doAssert writes[4] == (cast[pointer](addr bank.channelTuneGate228),
    0xFFFF_FFFB'u32, 0'u32)
  doAssert writes[5] == (cast[pointer](addr bank.txcalDfe88),
    0xFCFF_FFFF'u32, if isWide: 0x0300_0000'u32 else: 0x0200_0000'u32)
  doAssert writes[6] == (cast[pointer](addr bank.roscalCtrl7c),
    0xFFFF_FEFF'u32, 0'u32)
  doAssert bank.rbbRccalCtrl80 == 0xA5A5_5A5A'u32
  doAssert bank.rxMode220 == (if bandwidth == 0: 0xFEFF_FFFF'u32 else: high(uint32))
  doAssert bank.channelTuneGate228 == 0xFFFF_FFFB'u32
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rf_fsm_mode_and_dump_controls(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for requested in [0'u32, 1, 4, 7, 8, 15, 255]:
  bank = RfRegs(channelTuneCtrl26c: 0xA5A5_5A5A'u32,
    baseCtrl1: 0xCAFE_BABE'u32)
  writes.setLen(0)
  waitCalls.setLen(0)
  rfc_rf_fsm_force(requested)
  if requested == 15:
    doAssert writes == @[(cast[pointer](addr bank.channelTuneCtrl26c),
      0xFFFF_FFF7'u32, 0'u32)]
    doAssert waitCalls.len == 0
  else:
    doAssert writes == @[
      (cast[pointer](addr bank.channelTuneCtrl26c), 0xFFFF_FFF8'u32,
       requested and 7'u32),
      (cast[pointer](addr bank.channelTuneCtrl26c), 0xFFFF_FFFF'u32, 8'u32)]
    doAssert waitCalls == @[(20'u32, 1)]
  doAssert bank.channelTuneCtrl26c ==
    (if requested == 15: 0xA5A5_5A52'u32
     else: (0xA5A5_5A5A'u32 and 0xFFFF_FFF8'u32) or
       (requested and 7'u32) or 8'u32)

  bank.baseCtrl1 = 0xCAFE_BABE'u32
  writes.setLen(0)
  waitCalls.setLen(0)
  rfc_rc_fsm_force(requested)
  doAssert writes == @[
    (cast[pointer](addr bank.baseCtrl1), 0xFFFF_F8FF'u32,
     if requested == 15: 0'u32 else: (requested shl 8) and 0x700'u32),
    (cast[pointer](addr bank.baseCtrl1), 0xFFFF_F7FF'u32,
     if requested == 15: 0'u32 else: 0x800'u32)]
  doAssert waitCalls == @[(20'u32, 1)]
  doAssert bank.baseCtrl1 ==
    ((0xCAFE_BABE'u32 and 0xFFFF_F0FF'u32) or
      (if requested == 15: 0'u32
       else: ((requested shl 8) and 0x700'u32) or 0x800'u32))

for requested in [0'u32, 1, 2, 3, 4, 5, 15, high(uint32)]:
  bank = RfRegs(channelTuneGate228: high(uint32), rxMode220: high(uint32))
  writes.setLen(0)
  rfc_wlan_mode_force(requested)
  let accepted = requested <= 4'u32
  doAssert writes == @[
    (cast[pointer](addr bank.channelTuneGate228), 0xFFFF_800F'u32,
     if accepted: (requested shl 4) and 0x7FF0'u32 else: 0'u32),
    (cast[pointer](addr bank.rxMode220), 0xFDFF_FFFF'u32,
     if accepted: 0x0200_0000'u32 else: 0'u32)]

bank = RfRegs(calSingenCtrl20c: high(uint32),
  rxMode220: high(uint32), rxModeDumpReadback224: 0xA5A5_5A5A'u32)
writes.setLen(0)
rfc_sg_stop()
doAssert writes == @[(cast[pointer](addr bank.calSingenCtrl20c),
  0x7FFF_FFFF'u32, 0'u32)]
doAssert bank.calSingenCtrl20c == 0x7FFF_FFFF'u32

writes.setLen(0)
dumpReadAfterWrites.setLen(0)
rfc_dump()
doAssert writes == @[
  (cast[pointer](addr bank.rxMode220), 0x0FFF_FFFF'u32, 0x1000_0000'u32),
  (cast[pointer](addr bank.rxMode220), 0x0FFF_FFFF'u32, 0x2000_0000'u32)]
doAssert dumpReadAfterWrites == @[1, 2]
doAssert bank.rxMode220 == 0x2FFF_FFFF'u32
''')
