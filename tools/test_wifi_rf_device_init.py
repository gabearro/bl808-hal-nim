"""RF configuration, chip identity and efuse state from named vendor anchors."""

from pathlib import Path
import re

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_power_replay import RF, object_type, source


def efuse_source(*, real_temperature: bool = False) -> str:
    rf = RF.read_text()
    code = source() + object_type(rf, "WlRfConfig") + object_type(rf, "RfDfeInitBlock")
    constants = re.findall(r"^  WlRfCfg\w+ = .+$", rf, re.M)
    code += "const\n" + "\n".join(constants) + "\n"
    code += "  Bl808WifiRfDeviceInfo = 1\n  Bl808RfDeviceInfoWb03 = 1'u32\n"
    code += rf_procedure(rf, "rfSignedByte")
    code += r'''
type RadioPhyMode = enum wifiOnly = 1, bleOnly = 2, wifiBleCoex = 3
proc apiFromRadioPhyMode(mode: RadioPhyMode): uint8 = mode.uint8
var
  cfgStorage, nextConfig: WlRfConfig
  wlCfgGlobal: pointer
  dfe: RfDfeInitBlock
  bl808RfTxGainComp, bl808RfTempPowerComp: int16
  bl808RfEfuseCapComp, bl808RfEfusePowerComp: int16
  bl808RfBzTxCorrOffset, bl808RfBtTxCorrOffset: int16
  bl808RfChipVersion: uint8
  bl808RfBzTemperatureMeasurementPass: uint8
  bl808RfTempRoomOffset: int16
  bl808RfTempCalEnabled: uint8
  bl808RfTempInterpolationMode = 1'u8
  bl808RfTempChannelCount = 5'u32
  bl808RfTempChannels: array[5, uint16]
  bl808RfTempHighOffsets, bl808RfTempLowOffsets: array[5, int16]
  bl808RfBzTempPowerComp, bl808RfBzAppliedTempComp: array[5, int16]
  bl808RfBzTempCorrAvg: int16
  calls: seq[tuple[kind, value: int, measurement: uint8, writes: int]]
  rebindAfter: int
  invalidate: bool
proc rfDfeInitRegs(): ptr RfDfeInitBlock = addr dfe
proc recordCall(kind, value: int) =
  calls.add((kind, value, bl808RfBzTemperatureMeasurementPass, mmioWrites.len))
  if calls.len == rebindAfter:
    wlCfgGlobal = if invalidate: nil else: addr nextConfig
proc rf_pri_input_bz_target_power(value: int32) = recordCall(1, value.int)
'''
    if real_temperature:
        for name in (
            "rfPriSignedDiv32", "rfPriSensorTemperatureTenths",
            "wlCfgTempHalf", "wlCfgTempByte", "rfPriRefreshTempCompParamFromWlCfg",
            "rfPriTempChannelTableIndex", "rfPriInterpolatedTempOffset",
            "rfPriComputeTemperaturePowerCompForMhz", "rfPriPackFive6BitFields",
            "rfPriWriteBzTemperatureCompDeltas", "rfPriUpdateBzTempCorrAverage",
            "rf_pri_set_bz_temp_comp",
        ):
            if re.search(rf"^proc {name}\*?\(", rf, re.M):
                code += rf_procedure(rf, name)
    else:
        code += "proc rf_pri_set_bz_temp_comp(value: int32) = recordCall(2, value.int)\n"
    for name in (
        "wlCfgSetU32", "wlCfgSetBytes", "seedWlCfgTxPowerDefaults",
        "rf_pri_cfg_init", "wl_rf_cfg_init", "configureWlRfConfig",
        "rf_pri_input_chip_ver", "rfPriEfuseXtalCapPairValid",
        "rfPriApplyEfuseXtalCapTrim", "rf_pri_set_rcal_code",
        "rfPriApplyEfuseTxGainTrim", "rfPriApplyEfuseChipVersion",
        "rfPriApplyEfuseDfeTrim", "rf_pri_get_bz_temp_mp_comp", "rfPriEfuseInit",
    ):
        if re.search(rf"^proc {name}\*?\(", rf, re.M):
            code += rf_procedure(rf, name)
    return code + r'''
template cfgBytes: untyped = cast[ptr UncheckedArray[uint8]](addr cfgStorage)
template nextBytes: untyped = cast[ptr UncheckedArray[uint8]](addr nextConfig)
proc efuseSetup() =
  setup()
  recordWrites = true
  wlCfgGlobal = addr cfgStorage
  for i in 0 ..< sizeof(WlRfConfig):
    cfgBytes[i] = randomWord().uint8
    nextBytes[i] = randomWord().uint8
  for word in registerStorage.mitems: word = randomWord()
  let words = cast[ptr UncheckedArray[uint32]](addr dfe)
  for i in 0 ..< sizeof(dfe) div 4: words[i] = randomWord()
  calls.setLen(0)
  rebindAfter = 0
  invalidate = false
  bl808RfTxGainComp = 123
  bl808RfTempPowerComp = -77
  bl808RfBzTxCorrOffset = 65
  bl808RfBtTxCorrOffset = 66
  bl808RfChipVersion = 99
  bl808RfBzTemperatureMeasurementPass = 0
  mmioWrites.setLen(0)
  mmioReads.setLen(0)
proc configImage(cfg: var WlRfConfig): seq[uint8] =
  let p = cast[ptr UncheckedArray[uint8]](addr cfg)
  for i in 0 ..< sizeof(cfg): result.add(p[i])
proc put32(bytes: var seq[uint8]; offset: int; value: uint32) =
  for i in 0 ..< 4: bytes[offset + i] = (value shr (i * 8)).uint8
proc vendorConfig(before: seq[uint8]): seq[uint8] =
  result = before
  put32(result, 0xC0, 0x02000000)
  put32(result, 0xC4, 0x80808001'u32)
  for i in 0xA1 .. 0xBC: result[i] = 0
  for i in 0xBE .. 0xBF: result[i] = 0
  put32(result, 0x10, 0x096C0100)
  put32(result, 0x14, 0x098A097B)
  put32(result, 0x18, 0x09A80999)
  result[0xBD] = 35
  for i in 0x1C .. 0x31: result[i] = 0
  result[0x9C] = 20
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rf_configuration_wrapper_preserves_caller_owned_bytes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, efuse_source() + r'''
for vector in 0 ..< 500:
  efuseSetup()
  let wanted = vendorConfig(configImage(cfgStorage))
  wl_rf_cfg_init()
  doAssert configImage(cfgStorage) == wanted,
    "RF configuration changed rates or inserted fixed values into compensation bytes"
  doAssert mmioReads.len == 0 and mmioWrites.len == 0
wlCfgGlobal = nil
wl_rf_cfg_init()
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_platform_profile_seeds_the_requested_configuration_only(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, efuse_source() + r'''
efuseSetup()
let otherBefore = configImage(cfgStorage)
var wanted = configImage(nextConfig)
for span in [(0x32, 4), (0x36, 8), (0x3E, 8), (0x46, 8), (0x6C, 10), (0x78, 10)]:
  for i in 0 ..< span[1]: wanted[span[0] + i] = 28
configureWlRfConfig(addr nextConfig, 26000000, wifiBleCoex, 1)
let actual = configImage(nextConfig)
for i in 0x10 ..< 0xC8:
  doAssert actual[i] == wanted[i], "platform defaults wrote through the global config pointer"
doAssert configImage(cfgStorage) == otherBefore
doAssert nextConfig.xtalfreqHz == 26000000 and nextConfig.apiMode == 3
doAssert nextConfig.requestFullCalibration == 1 and nextConfig.status == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rcal_updates_all_three_named_compensation_states(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, efuse_source() + r'''
efuseSetup()
var codes: seq[uint32]
for value in 0'u32 .. 255: codes.add(value)
codes.add([256'u32, 384, 65535, 0x80000080'u32, 0xFFFFFF80'u32, high(uint32)])
for first in codes:
  for second in codes:
    mmioWrites.setLen(0)
    let before = rf70.xtalCapTrim5c
    let valid = first != 128 and second != 128
    let wanted = (before and 0xFFE0FC0F'u32) or
      (if valid: ((first and 31) shl 16) or ((second and 63) shl 4) else: 0x100200'u32)
    bl808RfTxGainComp = 123
    bl808RfBzTxCorrOffset = 65
    bl808RfBtTxCorrOffset = 66
    rf_pri_set_rcal_code(first, second)
    doAssert rf70.xtalCapTrim5c == wanted
    doAssert bl808RfTxGainComp == (if valid: -4 else: 0)
    doAssert bl808RfBzTxCorrOffset == (if valid: -7 else: -3)
    doAssert bl808RfBtTxCorrOffset == bl808RfBzTxCorrOffset
    doAssert mmioWrites == @[(cast[uint](addr rf70.xtalCapTrim5c), wanted)]
    doAssert bl808RfTempPowerComp == -77
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_chip_version_zero_selects_one_instead_of_preserving_previous(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, efuse_source() + r'''
efuseSetup()
for highWord in [0'u32, 0x10000, 0x80000000'u32, 0xFFFF0000'u32]:
  for lowWord in 0 ..< 65536:
    let value = highWord or lowWord.uint32
    bl808RfChipVersion = 99
    rf_pri_input_chip_ver(value)
    doAssert bl808RfChipVersion == (if value == 0: 1'u8 else: value.uint8)
doAssert mmioWrites.len == 0 and mmioReads.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_efuse_chip_identity_and_exact_initialization_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, efuse_source() + r'''
for pair in [(0, 0), (31, 63), (255, 255), (128, 0), (0, 128), (128, 128), (200, 100)]:
  for chip in [0, 1, 99, 127, 128, 255]:
    for trim in 0 .. 255:
      efuseSetup()
      cfgBytes[0xC4] = chip.uint8
      cfgBytes[0xC5] = pair[0].uint8
      cfgBytes[0xC6] = pair[1].uint8
      cfgBytes[0xC7] = trim.uint8
      cfgBytes[0x9C] = 0xF4
      cfgBytes[0xBD] = 0xEE
      let valid = pair[0] != 128 and pair[1] != 128
      var wanted = registerStorage
      wanted[0x5C div 4] = (wanted[0x5C div 4] and 0xFFE0FC0F'u32) or
        (if valid: ((pair[0].uint32 and 31) shl 16) or ((pair[1].uint32 and 63) shl 4)
         else: 0x100200'u32)
      wanted[0x704 div 4] = (wanted[0x704 div 4] and 0x00FFFFFF'u32) or
        (if valid: 0xFC000000'u32 else: 0'u32)
      wanted[0x7AC div 4] = (wanted[0x7AC div 4] and 0xFFFFFF00'u32) or
        (if valid: 248'u32 else: 252'u32)
      let wantedDfe = (dfe.dfeTrim824 and 0xFFFFFFF0'u32) or
        (if trim == 128: 4'u32 else: (trim and 15).uint32)
      rfPriEfuseInit()
      doAssert bl808RfChipVersion == (if chip == 0: 1 else: chip).uint8
      doAssert bl808RfTxGainComp == (if valid: -4 else: 0)
      doAssert bl808RfBzTxCorrOffset == (if valid: -7 else: -3)
      doAssert bl808RfBtTxCorrOffset == bl808RfBzTxCorrOffset
      doAssert bl808RfTempPowerComp == -77, "efuse wrote WLAN temperature compensation"
      doAssert registerStorage == wanted and dfe.dfeTrim824 == wantedDfe
      doAssert mmioWrites == @[(cast[uint](addr rf70.xtalCapTrim5c), wanted[0x5C div 4]),
        (cast[uint](addr dfe.dfeTrim824), wantedDfe),
        (cast[uint](addr rf70.txPowerComp704), wanted[0x704 div 4]),
        (cast[uint](addr rf70.txPowerComp7ac), wanted[0x7AC div 4])]
      doAssert calls == @[(1, -12, 0'u8, 1), (2, -18, 1'u8, 1), (2, 35, 0'u8, 1)]
      doAssert bl808RfBzTemperatureMeasurementPass == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_efuse_reloads_configuration_after_power_and_temperature_calls(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, efuse_source() + r'''
for stage in 1 .. 3:
  for missing in [false, true]:
    efuseSetup()
    cfgBytes[0xC4] = 99
    cfgBytes[0xC5] = 128
    cfgBytes[0xC6] = 128
    cfgBytes[0x9C] = 20
    cfgBytes[0xBD] = 10
    cfgBytes[0xC7] = 1
    nextBytes[0xBD] = 0xF3
    nextBytes[0xC7] = 7
    rebindAfter = stage
    invalidate = missing
    let before = dfe.dfeTrim824
    rfPriEfuseInit()
    doAssert calls.len == (if missing and stage == 1: 1 else: 3)
    if calls.len > 1:
      doAssert calls[1].value == (if stage == 1: -13 else: 10)
    if missing:
      doAssert mmioWrites.len == 1 and dfe.dfeTrim824 == before
    else:
      doAssert dfe.dfeTrim824 == ((before and 0xFFFFFFF0'u32) or 7)
      doAssert mmioWrites.len == 4
    doAssert bl808RfChipVersion == 99 and bl808RfTxGainComp == 0
efuseSetup()
wlCfgGlobal = nil
rfPriEfuseInit()
doAssert calls.len == 0 and mmioReads.len == 0 and mmioWrites.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_efuse_captures_real_bz_temperature_baseline(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, efuse_source(real_temperature=True) + r'''
efuseSetup()
cfgBytes[0xC4] = 99
cfgBytes[0xC5] = 128
cfgBytes[0xC6] = 128
cfgBytes[0xBD] = 55
cfgBytes[0x10] = 1
let halves = cast[ptr UncheckedArray[uint16]](addr cfgStorage)
for i, channel in [2412, 2427, 2442, 2457, 2472]:
  halves[0x12 div 2 + i] = channel.uint16
  halves[0x1C div 2 + i] = 100
  halves[0x26 div 2 + i] = 100
halves[0x30 div 2] = 0
let old784 = rf70.rfGainOrBzTempComp784
let old7b8 = rf70.bzTemperatureComp7b8
rfPriEfuseInit()
doAssert bl808RfBzAppliedTempComp == [4'i16, 4, 4, 4, 4]
doAssert bl808RfBzTempPowerComp == [0'i16, 0, 0, 0, 0]
doAssert bl808RfBzTemperatureMeasurementPass == 0 and bl808RfBzTempCorrAvg == 0
var packed: uint32
for i in 0 ..< 5: packed = packed or (60'u32 shl (i * 6))
doAssert rf70.rfGainOrBzTempComp784 == ((old784 and 0xC0000000'u32) or packed)
doAssert rf70.bzTemperatureComp7b8 == ((old7b8 and 0xC0000000'u32) or packed)
''')


def device_source() -> str:
    rf = RF.read_text()
    code = "const\n  Bl808RfDeviceInfoBl616 = 0'u32\n  Bl808RfDeviceInfoWb03 = 1'u32\n"
    code += "  Bl808RfDeviceInfoBl618m = 2'u32\n  Bl808WifiRfDeviceInfo = 1\n"
    for name in ("bl808RfDeviceBl616", "bl808RfDeviceWb03", "bl808RfDeviceBl618m", "bl808RfDeviceInfoSet"):
        declaration = re.search(rf"^  {name}: uint8.*$", rf, re.M)
        if declaration:
            code += "var\n" + declaration[0] + "\n"
    for name in ("rf_pri_input_device_info", "rfPriDeviceInfoValid", "rfPriEnsureDeviceInfo",
                 "rfPriIsWb03", "rfPriAnyKnownDeviceFlag"):
        if re.search(rf"^proc {name}\*?\(", rf, re.M):
            code += rf_procedure(rf, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_device_flags_preserve_vendor_default_and_explicit_unknown(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, device_source() + r'''
doAssert bl808RfDeviceBl616 == 1 and bl808RfDeviceWb03 == 0 and bl808RfDeviceBl618m == 0
doAssert not rfPriIsWb03() and rfPriAnyKnownDeviceFlag()
for device in [0'u32, 1, 2, 3, 255, 256, 0x10001, high(uint32)]:
  rf_pri_input_device_info(device)
  when declared(rfPriEnsureDeviceInfo): rfPriEnsureDeviceInfo()
  doAssert bl808RfDeviceBl616 == (device == 0).uint8
  doAssert bl808RfDeviceWb03 == (device == 1).uint8
  doAssert bl808RfDeviceBl618m == (device == 2).uint8
  doAssert rfPriIsWb03() == (device == 1)
  doAssert rfPriAnyKnownDeviceFlag() == (device < 3)
''')
