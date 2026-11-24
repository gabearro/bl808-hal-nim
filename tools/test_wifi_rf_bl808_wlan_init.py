"""BL808-native WLAN calibration ownership and RF init/retune dispatch."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_bz_comp import compensation_source
from test_wifi_rf_channel_entry import rf_procedure, rfc_source
from test_wifi_rf_init_lifecycle import core_procedure, init_source
from test_wifi_rf_power_replay import RF


def native_init_source() -> str:
    code = init_source().replace(
        "proc rfPriEfuseInit() =\n",
        "var expectScrubbedLegacy: bool\n"
        "proc rfPriEfuseInit() =\n"
        "  if expectScrubbedLegacy:\n"
        "    for b in wifiBl808WlRmem.calib: doAssert b == 0\n"
        "    expectScrubbedLegacy = false\n",
    ).replace(
        "  doAssert rfCalibDataGlobal == wlCalGlobal\n", "",
    )
    start = code.index("proc rfPriEfuseInit()")
    code = code[:start] + r'''
type
  RadioPhyMode = uint32
  FixtureWlMemory = object
    calib: array[320, uint8]
  WlRfConfig = object
    xtalfreqHz: uint32
var wifiBl808WlRmem: FixtureWlMemory
var fixtureRfConfig = WlRfConfig(xtalfreqHz: WlXtal40M)
var wlCfgGlobal: pointer = addr fixtureRfConfig
''' + RF.with_name("rf_bl808_calibration_owner.nim").read_text() + code[start:]
    start = code.index("proc rf_pri_init(coldInit, mode: uint32)")
    code = code[:start] + r'''
proc runRfPriLoFcal() = stages.add(10)
proc runRfPriLoAcal() = stages.add(11)
proc runBl808Roscal() = stages.add(12)
proc runBl808Rccal() = stages.add(13)
proc runBl808Txcal() =
  stages.add(14)
  wifiBl808WlRmem.calib[0x68] = 0xBD
proc programBl808TxGainTable() = stages.add(15)
''' + RF.with_name("rf_bl808_wlan_init.nim").read_text() + code[start:]
    for name in ("lp_rf_pri_init", "rf_pri_full_cal"):
        code += core_procedure(RF.read_text(), name)
    start = code.index("proc rf_pri_init(coldInit, mode: uint32)")
    return code[:start] + code[start:].replace("defined(bl808WifiNativeWlanCalibration)", "true")


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_native_warm_remeasures_and_first_coex_restore_calibrates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, native_init_source() + r'''
initSetup(1)
let foreign = addr calibration[0]
let internal = cast[pointer](addr wifiBl808WlRmem.calib[0])
let nativeStages = @[3, 9, 10, 11, 12, 13, 14, 15]
wlCalGlobal = internal
bl808RfPriXtal40mFlag = 1
rf_pri_init(1, wifiOnly)
doAssert rfBankHasBl808WlanCal() and stages == nativeStages
stages.setLen(0)
rf_pri_full_cal()
doAssert rfBankHasBl808WlanCal() and stages == @[10, 11, 12, 13, 14]

stages.setLen(0)
wlCalGlobal = foreign
rf_pri_init(0, wifiOnly)
doAssert not rfBankHasBl808WlanCal() and stages == @[2, 3, 4, 5, 7, 8]
doAssert managedRfCalibration == rfCalBl808Wlan
doAssert wifiBl808WlRmem.calib[0x68] == 0xBD

stages.setLen(0)
wlCalGlobal = internal
rf_pri_init(0, wifiOnly)
doAssert rfBankHasBl808WlanCal() and stages == nativeStages
expectScrubbedLegacy = true
stages.setLen(0)
rf_pri_init(0, 3)
doAssert not expectScrubbedLegacy and managedRfCalibration == rfCalLegacyFull
doAssert stages == @[2, 3, 4, 5, 6, 8]
for api in [3'u32, wifiOnly]:
  stages.setLen(0)
  rf_pri_init(0, api)
  doAssert managedRfCalibration == rfCalLegacyFull
  doAssert stages == @[2, 3, 4, 5, 7, 8]

stages.setLen(0)
rf_pri_init(1, wifiOnly)
doAssert rfBankHasBl808WlanCal() and stages == nativeStages
wlCalGlobal = foreign
expectScrubbedLegacy = true
stages.setLen(0)
lp_rf_pri_init(0, 0)
doAssert rfCalibDataGlobal == internal and wlCalGlobal == foreign
doAssert not expectScrubbedLegacy and managedRfCalibration == rfCalLegacyFull
doAssert stages == @[2, 3, 4, 5, 6, 8]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_native_init_leaves_later_synth_pulse_bit_unchanged(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, native_init_source() + r'''
for seed in [0'u32, 0x20'u32, 0xA5CCB208'u32]:
  initSetup(1)
  registerStorage[0x2C div 4] = seed
  mmioWrites.setLen(0)
  finishBl808WlanRfInit()
  let synth = cast[uint](addr registerStorage[0x2C div 4])
  var written: seq[uint32]
  for (address, value) in mmioWrites:
    if address == synth: written.add(value)
  doAssert written == @[seed or 0x6'u32, seed or 0x4007'u32]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_fallback_xtal_flag_cannot_select_native_wlan(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, native_init_source() + r'''
initSetup(1)
wlCalGlobal = addr wifiBl808WlRmem.calib[0]
bl808RfPriXtal40mFlag = 1  # the modem uses this selector for unknown rates
fixtureRfConfig.xtalfreqHz = 39_000_000
rf_pri_init(1, wifiOnly)
doAssert not rfBankHasBl808WlanCal() and managedRfCalibration == rfCalLegacyFull
doAssert stages == @[3, 9, 6, 8]

fixtureRfConfig.xtalfreqHz = WlXtal40M
stages.setLen(0)
rf_pri_init(1, wifiOnly)
doAssert rfBankHasBl808WlanCal() and stages == @[3, 9, 10, 11, 12, 13, 14, 15]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_native_retune_uses_notch_tail_without_legacy_replay(tmp_path: Path, mode: str) -> None:
    code = rfc_source()
    start = code.index("proc waitRfRfcUs")
    code = (
        code[:start]
        + "proc rfBankHasBl808WlanCal(): bool = true\n"
        + procedure(RF.with_name("rf_bl808_wlan_init.nim").read_text(), "programBl808ChannelNotch")
        + code[start:].replace("defined(bl808WifiNativeWlanCalibration)", "true")
    )
    run_program(tmp_path, mode, code + r'''
for frequency in [2412'u32, 2417, 2422, 2427, 2432, 2437, 2442,
                  2447, 2452, 2457, 2462, 2467, 2472, 2484]:
  for seed in [0'u32, high(uint32), 0x5A5AA5A5'u32]:
    setup()
    events.setLen(0)
    rfRegs().notchCtrl680 = seed
    rfRegs().channelFreqMhz264 = seed
    rfRegs().channelTuneStrobe268 = seed
    let tune = cast[uint](addr rfRegs().channelFreqMhz264)
    let strobe = cast[uint](addr rfRegs().channelTuneStrobe268)
    let p = cast[uint](addr rfRegs().notchCtrl680)
    let first = (seed and 0x87FFFFFF'u32) or 0x08000000
    let second = first and 0xF800FFFF'u32
    let third = second and 0x7FFFFFFF'u32
    rfc_config_channel(frequency)
    doAssert events[^4 .. ^1] == @[(1'u, frequency), (p, first), (p, second), (p, third)]
    doAssert rfRegs().channelFreqMhz264 == ((seed and 0xFFFFF000'u32) or frequency)
    var delays: seq[uint32]
    var tuneWrites: seq[uint32]
    var strobeWrites: seq[uint32]
    for event in events:
      doAssert event.address notin [0'u, 3'u, 4'u]
      if event.address == 5'u: delays.add(event.value)
      if event.address == tune: tuneWrites.add(event.value)
      if event.address == strobe: strobeWrites.add(event.value)
    doAssert tuneWrites == @[rfRegs().channelFreqMhz264]
    doAssert strobeWrites == @[seed or 0x20000'u32, seed and not 0x20000'u32]
    doAssert delays == @[1'u32, 1, 1, 1, 1, 100, 1]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_native_power_keeps_legacy_compensation_off_shared_registers(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = r'''
var nativeBank: bool
proc rfBankHasBl808WlanCal(): bool = nativeBank
''' + compensation_source()
    code += RF.with_name("rf_bl808_tx_gain.nim").read_text()
    code += r'''
var
  bl808RfAppliedPowerComp: int16
  bl808RfChannelPowerComp, bl808RfChannelLpPowerComp: array[14, int16]
'''
    for name in ("rfPriApplyTotalPowerRuntimeDelta", "rfPriWriteTotalPowerComp",
                 "rf_pri_set_channel_lp_pwr_comp", "rf_pri_set_channel_pwr_comp",
                 "rfPriTxGainDbForTableIndex",
                 "rfPriGetTxGainIndex", "rf_pri_get_txgain_max", "rf_pri_get_txgain_min",
                 "rfc_get_power_level"):
        code += rf_procedure(rf, name)
    for name in ("rf_pri_set_bz_temp_comp", "rfPriBzChannelTestBody", "rfPriWriteTotalPowerComp",
                 "rf_pri_set_channel_lp_pwr_comp", "rf_pri_set_channel_pwr_comp",
                 "rf_pri_get_txgain_max", "rf_pri_get_txgain_min", "rfc_get_power_level"):
        body = rf_procedure(code, name)
        code = code.replace(body.rstrip(), body.replace("defined(bl808WifiNativeWlanCalibration)", "true").rstrip())
    run_program(tmp_path, mode, code + r'''
compSetup(0)
let registers = registerStorage
let channels = bl808RfBzChannelPowerComp
let temperatures = bl808RfBzTempPowerComp
let index = bl808RfChannelPowerIndex
let legacyRows = bl808RfTxPowerTable
nativeBank = true
rfPriWriteTotalPowerComp(1)
rf_pri_set_channel_lp_pwr_comp(1)
rf_pri_set_channel_pwr_comp(2)
rf_pri_set_bz_channel_pwr_comp()
rf_pri_set_bz_temp_comp(60)
doAssert mmioWrites.len == 0 and registerStorage == registers
doAssert channels == bl808RfBzChannelPowerComp and temperatures == bl808RfBzTempPowerComp
doAssert index == bl808RfChannelPowerIndex and legacyRows == bl808RfTxPowerTable
doAssert rf_pri_get_txgain_max() == 20 and rf_pri_get_txgain_min() == 10
doAssert rfc_get_power_level(0, low(int32)) == 0

nativeBank = false
rf_pri_set_bz_channel_pwr_comp()
rf_pri_set_bz_temp_comp(60)
doAssert mmioWrites.len == 4 and registerStorage != registers
doAssert rfc_get_power_level(0, low(int32)) == 60
''')
