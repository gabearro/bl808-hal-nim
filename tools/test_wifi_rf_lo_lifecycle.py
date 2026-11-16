"""LO lookup and CW register contracts recovered from rf_pri.c.o."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_lo_search import packed_lo_source
from test_wifi_rf_power_replay import RF, array_constant
from test_wifi_rf_xtal_pll import xtal_source


def cw_source() -> str:
    rf = RF.read_text()
    code = xtal_source().replace("RfConfigChannelWaitLimit = 2", "RfConfigChannelWaitLimit = 5000")
    code = code.replace(
        "proc volatileLoad(p: ptr uint32): uint32 =",
        "var events: seq[tuple[address: uint, value: uint32]]\n"
        "var busyReads, statusReads: int\nvar busyMask: uint32\n"
        "proc volatileLoad(p: ptr uint32): uint32 =",
    ).replace(
        "  p[]\nproc volatileStore",
        "  if p == addr rf70.channelCalStatusB4:\n"
        "    inc statusReads\n"
        "    return if statusReads <= busyReads: busyMask else: 0'u32\n"
        "  p[]\nproc volatileStore",
    ).replace(
        "  if recordWrites: mmioWrites.add((address, value))",
        "  if recordWrites:\n    mmioWrites.add((address, value))\n"
        "    events.add((address, value))",
    ).replace(
        "proc waitRfUs(us: uint32) = discard",
        "proc waitRfUs(us: uint32) = events.add((0'u, us))",
    )
    code += array_constant(rf, "RfPriCwPowerAmplitudeTable")
    code += r'''
const
  RfTxcalSingenAmplitudeMask = 0x7FF'u32
  VendorAmplitude = [32'u32, 36, 40, 45, 51, 57, 64, 72, 81, 91, 102,
    114, 128, 144, 161, 181, 204, 229, 256, 288, 323, 362, 407, 456,
    512, 575, 645, 724, 812, 911, 1023]
var
  bl808RfChannelPowerComp: array[14, int16]
  bl808RfTempPowerComp, bl808RfTxGainComp: int16
  nim_wifi_rf_cw_start_count, nim_wifi_rf_cw_start_channel: uint32
  nim_wifi_rf_cw_start_channel_index, nim_wifi_rf_cw_start_power_index: uint32
  nim_wifi_rf_cw_start_sdm_div, nim_wifi_rf_cw_start_rf220: uint32
  nim_wifi_rf_cw_start_rf20c, nim_wifi_rf_cw_start_rf214, nim_wifi_rf_cw_start_rf218: uint32
'''
    for name in (
        "startRfPriTxDfeForCal", "rfPriCwChannelIndex", "rfPriCwLoCalIndex",
        "rfPriCwCompensatedTarget", "rfPriCwPowerTableIndex",
        "rfPriCwXtalDivisorTenths", "rfPriCwSdmDivWord",
        "rfPriProgramCwChannel", "rfPriStartCwDfeStrobes", "rf_pri_cw_start",
        "rfPriVcoCalWord", "rf_pri_get_vco_freq_cw", "rf_pri_get_vco_idac_cw",
        "rfcVcoPair", "programRfcVcoTable",
    ):
        code += rf_procedure(rf, name)
    return code + r'''
proc cwSetup() =
  crystalSetup()
  seedPll()
  rfCalibDataGlobal = addr calibration[0]
  events.setLen(0)
  busyReads = 0
  statusReads = 0
  busyMask = 0x01100000
  nim_wifi_rf_cw_start_count = 0
  nim_wifi_rf_config_channel_wait_timeout_count = 0
proc vendorSlot(f: uint32): int =
  if f > 2472: 13
  elif f < 2412: 0
  else: (f.int - 2412) div 5
proc signedHalf(value: int64): int =
  let low = (value and 65535).int
  if low >= 32768: low - 65536 else: low
proc vendorPower(target: int32; slot: int): int =
  let delta = (bl808RfChannelPowerComp[slot].int + bl808RfTempPowerComp.int) div 4
  let clipped = max(signedHalf(target.int64 + delta), 0)
  # The local port deliberately bounds vendor table reads outside 0..30.
  min(max(clipped + bl808RfTxGainComp.int div 4 + 2, 0), 30)
proc vendorDivisor(mask: int): uint32 =
  if (mask and 1) != 0: 720
  elif (mask and 2) != 0: 780
  elif (mask and 4) != 0: 960
  elif (mask and 16) != 0: 1200
  elif (mask and 32) != 0: 1560
  else: 1152
proc vendorSdm(f: uint32; mask: int): uint32 =
  ((f.uint64 * 40 * (1'u64 shl 22)) div vendorDivisor(mask).uint64).uint32
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_vco_getters_use_wrapped_subtraction_and_full_idac_byte(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, cw_source() + r'''
cwSetup()
let halves = cast[ptr UncheckedArray[uint16]](addr calibration[0])
for i in 0 ..< 21: halves[14 + i] = ((17 + i) shl 8 or (0xC0 + i)).uint16
let before = calibration
for highWord in [0'u32, 0x10000, 0x80000000'u32, 0xFFFF0000'u32]:
  for lowWord in 0 ..< 65536:
    let f = highWord or lowWord.uint32
    let wrapped = (f.uint64 + 4294967296'u64 - 2402) and 0xFFFFFFFF'u64
    let index = min((wrapped shr 2).int, 20)
    doAssert rf_pri_get_vco_freq_cw(f) == (17 + index).uint32
    doAssert rf_pri_get_vco_idac_cw(f) == (0xC0 + index).uint32
doAssert calibration == before and events.len == 0
rfCalibDataGlobal = nil
doAssert rf_pri_get_vco_freq_cw(2400) == 0 and rf_pri_get_vco_idac_cw(2484) == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rfc_vco_table_packs_all_records_without_masking_idac(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, cw_source() + r'''
cwSetup()
let halves = cast[ptr UncheckedArray[uint16]](addr calibration[0])
for i in 0 ..< 21: halves[14 + i] = randomWord().uint16
var wanted = registerStorage
var trace: seq[tuple[address: uint, value: uint32]]
for i in 0 ..< 11:
  let value = if i < 10: halves[14 + i * 2].uint32 or (halves[15 + i * 2].uint32 shl 16)
              else: halves[34].uint32
  wanted[0x13C div 4 + i] = value
  trace.add((cast[uint](addr registerStorage[0x13C div 4 + i]), value))
programRfcVcoTable()
doAssert registerStorage == wanted and mmioWrites == trace
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_cw_channel_compensation_slots_cover_low_validation_frequencies(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, cw_source() + r'''
for f in 2402'u32 .. 2484'u32: doAssert rfPriCwChannelIndex(f) == vendorSlot(f)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_cw_power_uses_temperature_signed_halfword_and_separate_gain(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, cw_source() + r'''
cwSetup()
for slot in 0 ..< 14:
  for channel in [-32768, -19, -3, 0, 3, 19, 32767]:
    bl808RfChannelPowerComp[slot] = channel.int16
    for temperature in [-32768, -7, 0, 7, 32767]:
      bl808RfTempPowerComp = temperature.int16
      for gain in [-32768, -11, -3, 0, 3, 11, 32767]:
        bl808RfTxGainComp = gain.int16
        for target in [low(int32), -65536'i32, -32769, -19, -1, 0, 1, 17,
                       30, 32767, 32768, 65536, high(int32)]:
          let compensated = rfPriCwCompensatedTarget(target, slot)
          doAssert rfPriCwPowerTableIndex(compensated) == vendorPower(target, slot).uint32
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_cw_crystal_precedence_and_fixed_point_dividers(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, cw_source() + r'''
cwSetup()
for mask in 1 ..< 64:
  setFlags(mask)
  doAssert rfPriCwXtalDivisorTenths() == vendorDivisor(mask)
  for f in 2402'u32 .. 2484'u32: doAssert rfPriCwSdmDivWord(f) == vendorSdm(f, mask)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_cw_channel_programming_preserves_unowned_rfbc_fields(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, cw_source() + r'''
for row in 0 ..< 6:
  for f in 2402'u32 .. 2484'u32:
    cwSetup()
    setFlags(1 shl row)
    let before = rf70.channelFcalConfigBc
    let index = ((f - 2402) shr 2).int
    let expected = (before and 0xFF0FFFFF'u32) or ((loFcalValues[index].uint32 shr 4) shl 20)
    rfPriProgramCwChannel(f)
    doAssert rf70.channelFcalConfigBc == expected
    doAssert (rf70.sdmDivC4 and 0x3FFFFFFF) == vendorSdm(f, 1 shl row)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_cw_strobes_wait_until_both_status_bits_clear(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, cw_source() + r'''
for mask in [0x00100000'u32, 0x01000000, 0x01100000]:
  for count in [0, 1, 4999, 5000, 10001]:
    cwSetup()
    busyMask = mask
    busyReads = count
    let initialB8 = rf70.txcalCtrlB8
    let initialB0 = rf70.channelCalStrobeB0
    rfPriStartCwDfeStrobes()
    doAssert statusReads == count + 1, "CW returned with calibration still busy"
    doAssert nim_wifi_rf_config_channel_wait_timeout_count == (count div 5000).uint32
    doAssert events.len == (count + 1) * 8
    for i in 0 ..< count + 1:
      let b8 = if i == 0: initialB8 else: initialB8 and 0xFFFEFFFF'u32
      let b0 = if i == 0: initialB0 else: initialB0 and 0xEFFFFFFF'u32
      let expected = @[(cast[uint](addr rf70.txcalCtrlB8), b8 or 0x10000'u32),
        (0'u, 10'u32), (cast[uint](addr rf70.txcalCtrlB8), b8 and 0xFFFEFFFF'u32),
        (0'u, 50'u32), (cast[uint](addr rf70.channelCalStrobeB0), b0 or 0x10000000'u32),
        (0'u, 10'u32), (cast[uint](addr rf70.channelCalStrobeB0), b0 and 0xEFFFFFFF'u32),
        (0'u, 50'u32)]
      doAssert events[i * 8 ..< i * 8 + 8] == expected
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_cw_reads_gain_after_calibration_without_reloading_temperature(tmp_path: Path, mode: str) -> None:
    code = cw_source().replace(
        "proc waitRfUs(us: uint32) = events.add((0'u, us))",
        "proc compensationChange()\n"
        "proc waitRfUs(us: uint32) =\n"
        "  events.add((0'u, us))\n  compensationChange()",
    )
    run_program(tmp_path, mode, code + r'''
proc compensationChange() =
  bl808RfTempPowerComp = 80
  bl808RfTxGainComp = 8
cwSetup()
bl808RfChannelPowerComp[0] = 4
bl808RfTempPowerComp = 0
bl808RfTxGainComp = -4
rf_pri_cw_start(10, 2412)
# Early target is 10 + (4 + 0)/4 = 11; late gain adds 8/4 + 2.
doAssert nim_wifi_rf_cw_start_power_index == 15
doAssert (rf70.calSingenAmpLo214 and 0x7FF) == VendorAmplitude[15]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_cw_full_register_trace_and_invalid_input_noop(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, cw_source() + r'''
for row in 0 ..< 6:
  for f in 2402'u32 .. 2484'u32:
    cwSetup()
    setFlags(1 shl row)
    for i in 0 ..< 14: bl808RfChannelPowerComp[i] = (i - 6).int16
    bl808RfTempPowerComp = 7
    bl808RfTxGainComp = -5
    if (f and 1) == 0:
      loFcalValues = default(typeof(loFcalValues))
      loAcalValues = default(typeof(loAcalValues))
    let power = (f.int mod 20 - 3).int32
    let amplitude = VendorAmplitude[vendorPower(power, vendorSlot(f))]
    var expected = registerStorage
    var trace: seq[tuple[address: uint, value: uint32]]
    template put(offset: int; keep, value: uint32) =
      expected[offset div 4] = (expected[offset div 4] and keep) or value
      trace.add((cast[uint](addr registerStorage[offset div 4]), expected[offset div 4]))
    template delay(us: uint32) = trace.add((0'u, us.uint32))
    put(0x2C, 0xFFFFFFFB'u32, 0)
    put(0x68, 0x0C00C088'u32, 0xE1770244'u32)
    put(0x48, 0xCE08FFFF'u32, 0x10700000)
    put(0x68, 0x1DFFFFFF'u32, 0xE0000000'u32)
    put(0x63C, 0xFF800000'u32, 0)
    put(0x220, 0xFFFFE67D'u32, 0)
    put(4, 0xFFFFFFFD'u32, 0)
    put(0x2C, 0, 0)
    put(0x30, 0xFFFFFFFF'u32, 2)
    put(0x30, 0xCEFFF8FF'u32, 0xCEFF7800'u32)
    put(0x30, 0xFFFFFFFF'u32, 0x0F000000)
    let lo = ((f - 2402) shr 2).int
    put(0xA0, 0xFFC0FF00'u32, loFcalValues[lo].uint32 or ((loAcalValues[lo].uint32 and 63) shl 16))
    put(0xBC, 0xFF0FFFFF'u32, (loFcalValues[lo].uint32 shr 4) shl 20)
    put(0xC4, 0xC0000000'u32, vendorSdm(f, 1 shl row))
    put(0xC0, 0xFFFFEFFF'u32, 0)
    put(0xB8, 0xFFFFFFFF'u32, 0x10000)
    delay(10)
    put(0xB8, 0xFFFEFFFF'u32, 0)
    delay(50)
    put(0xB0, 0xFFFFFFFF'u32, 0x10000000)
    delay(10)
    put(0xB0, 0xEFFFFFFF'u32, 0)
    delay(50)
    put(0x20C, 0xFC00FFFF'u32, 0)
    put(0x214, 0x003FFFFF'u32, 0)
    put(0x218, 0x003FFFFF'u32, 0xC0000000'u32)
    put(0x21C, 0xEFFFEFFF'u32, 0)
    put(0x214, 0xFFFFF800'u32, amplitude)
    put(0x218, 0xFFFFF800'u32, amplitude)
    delay(1)
    put(0x23C, 0xFFFFFFFF'u32, 0x40000)
    put(0x220, 0xFFFFFE7F'u32, 0)
    put(0x220, 0xFFFFE7FF'u32, 0x1082)
    put(0x220, 0xFFFFFFEF'u32, 0x100)
    put(0x20C, 0x7FFFFFFF'u32, 0)
    put(0x20C, 0x7FFFFFFF'u32, 0x80000000'u32)
    rf_pri_cw_start(power, f)
    doAssert registerStorage == expected, "CW register fields differ"
    doAssert events == trace, "CW MMIO/delay order or write count differs"
    doAssert trace.len == 36 and statusReads == 1
    doAssert nim_wifi_rf_cw_start_power_index == vendorPower(power, vendorSlot(f)).uint32

for missingCal in [false, true]:
  for f in [0'u32, 2401, 2402, 2484, 2485, 0x10000962'u32, high(uint32)]:
    if not missingCal and f in [2402'u32, 2484]: continue
    cwSetup()
    if missingCal: rfCalibDataGlobal = nil
    let before = registerStorage
    rf_pri_cw_start(12, f)
    doAssert registerStorage == before and events.len == 0 and mmioReads.len == 0
    doAssert nim_wifi_rf_cw_start_count == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bracketed_nonmonotonic_fcal_selects_first_crossing_pair(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, packed_lo_source() + r'''
for row in 0 ..< 6:
  for shift in [0, 37, 91]:
    loSetup(row)
    for word in calibration.mitems: word = randomWord()
    var expected = calibration
    let halves = cast[ptr UncheckedArray[uint16]](addr expected[0])
    let first = VendorCnt[row][0].int
    let counts = @[first - 100, first + 300 + shift, first + 90,
      first + 800 + shift, first + 40, VendorCnt[row][20].int - 100,
      VendorRange[row][2].int + 1]
    sampleValues = @[((VendorRange[row][0].int + VendorRange[row][1].int) div 2).uint16]
    for count in counts: sampleValues.add(count.uint16)
    for channel in 0 ..< 21:
      let target = VendorCnt[row][channel].int
      var crossing = 1
      while counts[crossing] < target: inc crossing
      var selected = crossing
      if target - counts[crossing - 1] < counts[crossing] - target: dec selected
      let code = ((130 - selected) and 255).uint16
      halves[14 + channel] = (halves[14 + channel] and 255) or (code shl 8)
    runRfPriLoFcal()
    doAssert sampleIndex == counts.len + 1
    doAssert calibration == expected, "FCAL used a global-nearest sample instead of the crossing pair"
''')
