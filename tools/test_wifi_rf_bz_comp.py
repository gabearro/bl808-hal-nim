"""BZ/WLAN compensation arithmetic and ownership from rf_pri.c.o."""

from pathlib import Path
import re

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_device_init import efuse_source
from test_wifi_rf_power_replay import RF


def compensation_source() -> str:
    rf = RF.read_text()
    code = efuse_source(real_temperature=True)
    old = "proc rf_pri_set_bz_channel_pwr_comp() = inc channelCompCalls"
    assert code.count(old) == 1
    code = code.replace(old,
        "proc rfPriBzChannelTestBody() {.exportc, cdecl.}\n"
        "proc rf_pri_set_bz_channel_pwr_comp() = rfPriBzChannelTestBody()")
    old = "proc rf_pri_input_bz_target_power(value: int32) = recordCall(1, value.int)"
    assert code.count(old) == 1
    code = code.replace(old, "proc rf_pri_input_bz_target_power(targetPowerDbm: int32) {.exportc, cdecl.}")
    code += r'''
var
  bl808RfBzChannelPowerComp: array[5, int16]
  bl808RfBzChCorrAvg: int16
  bl808RfChannelPowerIndex = 1'u8
  bl808RfTempMeasurementPass: uint8
  bl808RfCurrentTemperatureC: int16
  totalCalls: seq[uint32]
proc rf_pri_set_channel_total_pwr_comp(value: uint32) = totalCalls.add(value)
'''
    for name in (
        "rfPriRefreshBzChannelPowerComp", "rfPriClampBzChannelComp",
        "rf_pri_set_bz_channel_pwr_comp", "rfPriChannelCenterMhz",
        "rfPriComputeTemperaturePowerComp", "rf_pri_set_temp_comp",
        "rfPriSelectBzTargetPowerRecords", "rfPriBzTargetPowerWindowActive",
        "rf_pri_input_bz_target_power",
    ):
        if re.search(rf"^proc {name}\*?\(", rf, re.M):
            body = rf_procedure(rf, name)
            if name == "rf_pri_set_bz_channel_pwr_comp":
                body = body.replace("proc rf_pri_set_bz_channel_pwr_comp()", "proc rfPriBzChannelTestBody()", 1)
            code += body
    return code + r'''
proc half(value: int64): int16 =
  let bits = value and 65535
  (if bits >= 32768: bits - 65536 else: bits).int16
proc word(value: int64): int32 =
  let bits = value and 0xFFFFFFFF'i64
  (if bits >= 2147483648'i64: bits - 4294967296'i64 else: bits).int32
proc divide(n, d: int64): int64 =
  if d == 0: -1
  elif n == -2147483648'i64 and d == -1: -2147483648'i64
  else: n div d
proc pack(values: array[5, int16]): uint32 =
  for i, value in values:
    result = result or (((value.int64 and 63).uint32) shl (i * 6))
proc aggregate(values: array[5, int16]): int16 =
  var smallest = 0'i16
  var total = 0'i64
  for value in values:
    total += value
    smallest = min(smallest, value)
  if smallest < 0: smallest else: half(total div 5)
proc sample(channel: int; temperature: int32; previous: int16): tuple[value: int16, computed: bool] =
  let sensor = half(temperature.int64 * 10).int64
  let room = half(bl808RfTempRoomOffset.int64 * 10 + 350).int64
  if sensor == room: return (0'i16, true)
  let count = min(bl808RfTempChannelCount.int, 5)
  var slot = 0
  while slot < count and bl808RfTempChannels[slot].int <= channel: inc slot
  let table = if sensor < room: bl808RfTempLowOffsets else: bl808RfTempHighOffsets
  var divisor: int64
  if slot == 0: divisor = table[0]
  elif slot == count: divisor = table[count - 1]
  elif bl808RfTempInterpolationMode > 1: return (previous, false)
  elif bl808RfTempInterpolationMode == 0: divisor = table[slot - 1]
  else:
    let left = bl808RfTempChannels[slot - 1].int64
    let right = bl808RfTempChannels[slot].int64
    let numerator = word((table[slot].int64 - table[slot - 1].int64) * (channel.int64 - left)).int64
    divisor = word(table[slot - 1].int64 + divide(numerator, right - left)).int64
  (half(divide((sensor - room) * 2, divisor)), true)
proc compSetup(profile: int) =
  efuseSetup()
  cfgBytes[0x10] = 1
  let halves = cast[ptr UncheckedArray[uint16]](addr cfgStorage)
  let channels = case profile
    of 0: [2412, 2427, 2442, 2457, 2472]
    of 1: [2400, 2450, 2500, 2550, 2600]
    else: [2420, 2440, 2460, 2480, 2500]
  for i in 0 ..< 5:
    halves[0x12 div 2 + i] = channels[i].uint16
    halves[0x1C div 2 + i] = (50 + i * 30).uint16
    halves[0x26 div 2 + i] = (70 + i * 20).uint16
  halves[0x30 div 2] = 0
  bl808RfTempInterpolationMode = 1
  bl808RfTempChannelCount = 5
  bl808RfBzTempCorrAvg = -17
  bl808RfTempPowerComp = 1234
  bl808RfTempMeasurementPass = 0
  bl808RfCurrentTemperatureC = -99
  totalCalls.setLen(0)
  for i in 0 ..< 5:
    bl808RfBzTempPowerComp[i] = (20 + i).int16
    bl808RfBzAppliedTempComp[i] = (7 + i).int16
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bz_channel_correction_domains_clipping_and_aggregate(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, compensation_source() + r'''
for vector in 0 ..< 5000:
  compSetup(0)
  let oldTemp = bl808RfBzTempCorrAvg
  bl808RfBzTxCorrOffset = half(randomWord().int64)
  bl808RfBtTxCorrOffset = half(randomWord().int64)
  var raw, clipped, bz, bt: array[5, int16]
  for i in 0 ..< 5:
    cfgBytes[0xBE + i] = randomWord().uint8
    let byte = cfgBytes[0xBE + i].int
    raw[i] = (if byte >= 128: byte - 256 else: byte).int16
    clipped[i] = clamp(raw[i], -16'i16, 16'i16)
    bz[i] = half(clipped[i].int64 + bl808RfBzTxCorrOffset.int64)
    bt[i] = half(clipped[i].int64 + bl808RfBtTxCorrOffset.int64)
  var wanted = registerStorage
  wanted[0x780 div 4] = (wanted[0x780 div 4] and 0xC0000000'u32) or pack(bz)
  wanted[0x7B4 div 4] = (wanted[0x7B4 div 4] and 0xC0000000'u32) or pack(bt)
  rf_pri_set_bz_channel_pwr_comp()
  doAssert bl808RfBzChannelPowerComp == raw, "raw config copy must remain unclipped"
  doAssert registerStorage == wanted, "BZ/BT correction domains or physical fields differ"
  doAssert bl808RfBzChCorrAvg == aggregate(clipped)
  doAssert bl808RfBzTempCorrAvg == oldTemp
  doAssert mmioWrites == @[(cast[uint](addr rf70.bzChannelPowerComp780), wanted[0x780 div 4]),
    (cast[uint](addr rf70.bzChannelPowerComp7b4), wanted[0x7B4 div 4])]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bz_disabled_measurement_preserves_baseline_and_shared_scalar(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, compensation_source() + r'''
for measurement in [0'u8, 1, 2, 255]:
  compSetup(0)
  cfgBytes[0x10] = 0
  bl808RfBzTemperatureMeasurementPass = measurement
  let baseline = bl808RfBzAppliedTempComp
  let oldAverage = bl808RfBzTempCorrAvg
  var wanted = registerStorage
  if measurement == 0:
    var deltas: array[5, int16]
    for i in 0 ..< 5: deltas[i] = -baseline[i]
    for offset in [0x784, 0x7B8]:
      wanted[offset div 4] = (wanted[offset div 4] and 0xC0000000'u32) or pack(deltas)
  rf_pri_set_bz_temp_comp(55)
  doAssert bl808RfBzTempPowerComp == default(array[5, int16])
  doAssert bl808RfBzAppliedTempComp == baseline, "disabled MP overwrote the saved baseline"
  doAssert bl808RfTempPowerComp == 1234
  doAssert registerStorage == wanted
  doAssert bl808RfBzTempCorrAvg == (if measurement == 0: 0 else: oldAverage)
  doAssert mmioWrites.len == (if measurement == 0: 2 else: 0)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bz_measurement_storage_shared_accumulator_and_exact_writes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, compensation_source() + r'''
for profile in 0 ..< 3:
  for interpolation in [0'u8, 1, 2, 255]:
    for measurement in [0'u8, 1, 2]:
      for temperature in [-2147483648'i32, -65536, -32769, -3276, -17, 0, 35, 55, 3277, 65535, 2147483647]:
        compSetup(profile)
        bl808RfTempInterpolationMode = interpolation
        bl808RfBzTemperatureMeasurementPass = measurement
        rfPriRefreshTempCompParamFromWlCfg(wlCfgGlobal)
        var current: array[5, int16]
        var baseline = bl808RfBzAppliedTempComp
        var shared = bl808RfTempPowerComp
        let oldAverage = bl808RfBzTempCorrAvg
        var publish = false
        for i, channel in [2412, 2434, 2450, 2466, 2478]:
          let sampled = sample(channel, temperature, shared)
          shared = sampled.value
          publish = publish or sampled.computed
          if measurement != 0: baseline[i] = shared
          else: current[i] = shared
        var wanted = registerStorage
        if measurement == 0:
          var deltas: array[5, int16]
          for i in 0 ..< 5: deltas[i] = half(current[i].int64 - baseline[i].int64)
          for offset in [0x784, 0x7B8]:
            wanted[offset div 4] = (wanted[offset div 4] and 0xC0000000'u32) or pack(deltas)
        rf_pri_set_bz_temp_comp(temperature)
        doAssert bl808RfBzTempPowerComp == current
        doAssert bl808RfBzAppliedTempComp == baseline
        doAssert bl808RfTempPowerComp == (if publish: shared else: 1234'i16)
        doAssert bl808RfBzTempCorrAvg == (if measurement == 0: aggregate(current) else: oldAverage)
        doAssert registerStorage == wanted and mmioWrites.len == (if measurement == 0: 2 else: 0)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bz_zero_and_single_channel_temperature_tables(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, compensation_source() + r'''
for count in [0'u32, 1'u32]:
  for temperature in [-17'i32, 35, 55]:
    for measurement in [0'u8, 1]:
      compSetup(0)
      bl808RfTempChannelCount = count
      bl808RfTempChannels = [2400'u16, 2430, 2460, 2490, 2520]
      bl808RfTempHighOffsets = [80'i16, 81, 82, 83, 84]
      bl808RfTempLowOffsets = [100'i16, 101, 102, 103, 104]
      bl808RfBzTemperatureMeasurementPass = measurement
      let oldChannels = bl808RfTempChannels
      let oldHigh = bl808RfTempHighOffsets
      let oldLow = bl808RfTempLowOffsets
      let oldBaseline = bl808RfBzAppliedTempComp
      let oldRegisters = registerStorage
      let expected =
        if temperature == 35: 0'i16
        elif temperature == 55: (if count == 0: 5'i16 else: 8'i16)
        else: (if count == 0: -10'i16 else: -14'i16)
      rf_pri_set_bz_temp_comp(temperature)
      if count == 0:
        doAssert bl808RfTempChannels == oldChannels
        doAssert bl808RfTempHighOffsets == oldHigh
        doAssert bl808RfTempLowOffsets == oldLow
      else:
        doAssert bl808RfTempChannels[0] == 2412
        doAssert bl808RfTempHighOffsets[0] == 50
        doAssert bl808RfTempLowOffsets[0] == 70
        doAssert bl808RfTempChannels[1 .. 4] == oldChannels[1 .. 4]
        doAssert bl808RfTempHighOffsets[1 .. 4] == oldHigh[1 .. 4]
        doAssert bl808RfTempLowOffsets[1 .. 4] == oldLow[1 .. 4]
      doAssert bl808RfTempPowerComp == expected
      for i in 0 ..< 5:
        doAssert bl808RfBzTempPowerComp[i] ==
          (if measurement == 0: expected else: 0'i16)
        doAssert bl808RfBzAppliedTempComp[i] ==
          (if measurement == 0: oldBaseline[i] else: expected)
      doAssert mmioWrites.len == (if measurement == 0: 2 else: 0)
      if measurement == 0:
        doAssert bl808RfBzTempCorrAvg == expected
        var deltas: array[5, int16]
        for i in 0 ..< 5:
          deltas[i] = expected - oldBaseline[i]
        for offset in [0x784, 0x7B8]:
          doAssert registerStorage[offset div 4] ==
            ((oldRegisters[offset div 4] and 0xC0000000'u32) or pack(deltas))
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_temperature_zero_divisor_has_rv32_div_result(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, compensation_source() + r'''
for measurement in [0'u8, 1]:
  for temperature in [-10'i32, 35, 55]:
    compSetup(0)
    let halves = cast[ptr UncheckedArray[uint16]](addr cfgStorage)
    for i in 0 ..< 5:
      halves[0x1C div 2 + i] = 0
      halves[0x26 div 2 + i] = 0
    bl808RfTempMeasurementPass = measurement
    rf_pri_set_temp_comp(temperature)
    doAssert bl808RfTempPowerComp == (if temperature == 35: 0 else: -1)
    doAssert totalCalls.len == (if measurement == 0: 1 else: 0)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_wlan_temperature_publication_and_interpolation_modes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, compensation_source() + r'''
for enabled in [0'u8, 1, 255]:
  for interpolation in [0'u8, 1, 2, 255]:
    for measurement in [0'u8, 1, 255]:
      for channel in [0'u8, 1, 7, 14, 15, 255]:
        for temperature in [-2147483648'i32, -32769, -3276, -17, 0, 35, 55, 3277, 65535, 2147483647]:
          compSetup(1)
          cfgBytes[0x10] = enabled
          bl808RfTempInterpolationMode = interpolation
          bl808RfTempMeasurementPass = measurement
          bl808RfChannelPowerIndex = channel
          rfPriRefreshTempCompParamFromWlCfg(wlCfgGlobal)
          let valid = channel >= 1 and channel <= 14
          let mhz = if channel == 14: 2484 else: 2412 + (channel.int - 1) * 5
          let want = if not valid: 1234'i16 elif enabled == 0: 0'i16
                     else: sample(mhz, temperature, 0).value
          rf_pri_set_temp_comp(temperature)
          doAssert bl808RfTempPowerComp == want
          doAssert bl808RfCurrentTemperatureC ==
            (if valid and enabled != 0 and measurement == 0:
              (half(temperature.int64 * 10).int div 10).int16 else: -99'i16)
          doAssert totalCalls == (if valid and measurement == 0: @[channel.uint32] else: @[])
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bz_target_skip_uses_vendor_window_key(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, compensation_source() + r'''
for target in [-2147483648'i32, -1, 5, 6, 20, 21, 23, 24, 2147483647]:
  compSetup(0)
  rfCalibDataGlobal = addr calibration[0]
  let window = rfPriSelectBzTargetPowerRecords(target)
  bl808RfBzTargetPowerRecords = [8, 8, 8, 8]
  let key = if target <= 5 or (target > 20 and target <= 23): 0 else: 3
  bl808RfBzTargetPowerRecords[key] = window[key]
  let before = bl808RfBzTargetPowerRecords
  rf_pri_input_bz_target_power(target)
  doAssert bl808RfBzTargetPowerRecords == before, "non-key entries were normalized"
  doAssert mmioWrites.len == 3 and writes == 1 and snapshots == 0,
    "unchanged target window republished calibration or power tables"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_signed_coefficients_room_wrap_and_zero_crossings(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, compensation_source() + r'''
for profile in 0 ..< 3:
  for coefficients in [[-32768, 32767, 0, -1, 1], [0, 0, 0, 0, 0],
                       [5, -9, 13, -17, 21]]:
    for room in [-32768, -3600, -1, 0, 3600, 32767]:
      for interpolation in [0'u8, 1, 2]:
        compSetup(profile)
        bl808RfTempInterpolationMode = interpolation
        let halves = cast[ptr UncheckedArray[uint16]](addr cfgStorage)
        for i in 0 ..< 5:
          halves[0x1C div 2 + i] = cast[uint16](coefficients[i].int16)
          halves[0x26 div 2 + i] = cast[uint16](coefficients[4 - i].int16)
        halves[0x30 div 2] = cast[uint16](room.int16)
        rfPriRefreshTempCompParamFromWlCfg(wlCfgGlobal)
        for temperature in [-2147483648'i32, -32769, -3276, -17, 0, 35, 55, 3277, 65535, 2147483647]:
          for channel in [1'u8, 7, 14]:
            bl808RfChannelPowerIndex = channel
            bl808RfTempPowerComp = 1234
            let mhz = if channel == 14: 2484 else: 2412 + (channel.int - 1) * 5
            let expected = sample(mhz, temperature, 0).value
            rf_pri_set_temp_comp(temperature)
            doAssert bl808RfTempPowerComp == expected
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rv32_arithmetic_primitives_and_full_width_intermediate(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, compensation_source() + r'''
for numerator in [low(int32), -2147483647'i32, -17, -1, 0, 1, 17, high(int32)]:
  for denominator in [low(int32), -65535'i32, -17, -1, 0, 1, 17, 65535, high(int32)]:
    doAssert rfPriSignedDiv32(numerator, denominator) == divide(numerator.int64, denominator.int64).int32
for highWord in [0'u32, 0x10000, 0x80000000'u32, 0xFFFF0000'u32]:
  for lowWord in 0 ..< 65536:
    let temperature = cast[int32](highWord or lowWord.uint32)
    doAssert rfPriSensorTemperatureTenths(temperature) == half(temperature.int64 * 10)
compSetup(0)
bl808RfTempChannels = [0'u16, 65535, 65535, 65535, 65535]
doAssert rfPriInterpolatedTempOffset(65534, [-32768'i16, 32767, 0, 0, 0], 1) == -32771
bl808RfTempChannels = [1'u16, 1, 1, 1, 1]
doAssert rfPriInterpolatedTempOffset(1, [5'i16, 9, 0, 0, 0], 1) == 4
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_temperature_config_pointer_is_stable_during_copy(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = compensation_source()
    half = rf_procedure(rf, "wlCfgTempHalf")
    byte = rf_procedure(rf, "wlCfgTempByte")
    assert code.count(half) == 1 and code.count(byte) == 1
    code = code.replace(half, r'''
var tempCfgReads: seq[pointer]
proc wlCfgTempHalf(cfg: pointer, offset: int): int16 =
  tempCfgReads.add(cfg)
  if tempCfgReads.len == 1:
    wlCfgGlobal = addr nextConfig
  let bytes = cast[ptr UncheckedArray[uint8]](cfg)
  cast[int16](uint16(bytes[offset]) or (uint16(bytes[offset + 1]) shl 8))
''')
    code = code.replace(byte, r'''
proc wlCfgTempByte(cfg: pointer, offset: int): uint8 =
  tempCfgReads.add(cfg)
  cast[ptr UncheckedArray[uint8]](cfg)[offset]
''')
    run_program(tmp_path, mode, code + r'''
for bz in [false, true]:
  compSetup(1)
  nextBytes[0x10] = 0
  tempCfgReads.setLen(0)
  if bz:
    bl808RfBzTemperatureMeasurementPass = 1
    rf_pri_set_bz_temp_comp(55)
  else:
    bl808RfTempMeasurementPass = 1
    rf_pri_set_temp_comp(55)
  doAssert tempCfgReads.len == 17
  for source in tempCfgReads:
    doAssert source == addr cfgStorage, "temperature table mixed two configurations"
  doAssert wlCfgGlobal == addr nextConfig
  doAssert bl808RfTempCalEnabled == 1
''')
