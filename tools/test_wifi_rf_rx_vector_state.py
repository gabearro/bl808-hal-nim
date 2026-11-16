"""Carrier-error callback state and RX gain data/updates from the RF archive."""

from pathlib import Path
import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_core_entry import wl_types
from test_wifi_rf_power_replay import RF, array_constant, object_type


def carrier_source(*, real_update: bool = True) -> str:
    rf = RF.read_text()
    code = wl_types() + object_type(rf, "BbaRuntimeState") + r'''
var
  state: BbaRuntimeState
  configs: array[2, WlRfConfig]
  wlCfgGlobal: pointer
  interruptsEnabled: bool
  savedIrq, restoredIrq: int
  callLog: seq[tuple[name: string, irq: bool, first, second: int]]
  writes: seq[tuple[offset: int, irq: bool]]
  capcode, auxiliary: uint8
  changeAccumulator: bool
  nextAccumulator: uint16
  rebindConfig, removeConfig, removeSetter: bool
  applyCalls: int
  trackWrites = true
proc bbaState(): ptr BbaRuntimeState = addr state
proc volatileLoad[T](p: ptr T): T = p[]
proc volatileStore[T](p: ptr T; value: T) =
  if trackWrites: writes.add(((cast[uint](p) - cast[uint](addr state)).int, interruptsEnabled))
  p[] = value
proc bbaIrqSave(): uint32 =
  inc savedIrq
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc bbaIrqRestore(previous: uint32) =
  inc restoredIrq
  interruptsEnabled = (previous and 8) != 0
proc getCapcode(a, b: ptr uint8) {.cdecl.} =
  doAssert a != b, "carrier-error getter requires two distinct output bytes"
  a[] = capcode
  b[] = auxiliary
  callLog.add(("get", interruptsEnabled, capcode.int, auxiliary.int))
  if changeAccumulator: state.cePpmAccumulator = nextAccumulator
  if rebindConfig: wlCfgGlobal = addr configs[1]
  if removeConfig: wlCfgGlobal = nil
  if removeSetter:
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg != nil: cfg.capcodeSetCallback = nil
proc setCapcode(a, b: uint8) {.cdecl.} =
  callLog.add(("set0", interruptsEnabled, a.int, b.int))
  state.cePpmAccumulator = 12345
proc setOther(a, b: uint8) {.cdecl.} =
  callLog.add(("set1", interruptsEnabled, a.int, b.int))
  state.cePpmAccumulator = 12345
proc legacySet(a: uint8) {.cdecl.} =
  callLog.add(("set0", interruptsEnabled, a.int, -1))
proc legacyOther(a: uint8) {.cdecl.} =
  callLog.add(("set1", interruptsEnabled, a.int, -1))
proc setup() =
  state = BbaRuntimeState(ceLoopScratch0: 0x12345678, ceLoopScratch4: 0x87654321'u32,
    pdRssiState: 3, pdGainCode: 2, pdCompCurrent: 1, pdCompLatch: 1,
    pdLoopToCeAccumulatorPadding0: 77, pdLoopToCeAccumulatorPadding1: 88,
    cePpmAccumulator: 500, ceUpdateInterval: 10, ceUpdateCount: 7,
    ceCapcodeHoldoff: 0, ceLoopTailPadding: 99)
  configs = default(typeof(configs))
  wlCfgGlobal = addr configs[0]
  configs[0].capcodeGetCallback = cast[pointer](getCapcode)
  configs[1].capcodeGetCallback = cast[pointer](getCapcode)
  interruptsEnabled = true
  savedIrq = 0
  restoredIrq = 0
  callLog.setLen(0)
  writes.setLen(0)
  capcode = 31
  auxiliary = 42
  changeAccumulator = false
  rebindConfig = false
  removeConfig = false
  removeSetter = false
  applyCalls = 0
  trackWrites = true
'''
    update = rf_procedure(rf, "bbaApplyCarrierErrorCapcode")
    # Match the pre-fix function-pointer prototype without making a mismatched C call.
    legacy = "proc(a: uint8)" in update
    code += "const LegacySetterAbi = " + str(legacy).lower() + "\n"
    code += r'''
proc installSetters() =
  when LegacySetterAbi:
    configs[0].capcodeSetCallback = cast[pointer](legacySet)
    configs[1].capcodeSetCallback = cast[pointer](legacyOther)
  else:
    configs[0].capcodeSetCallback = cast[pointer](setCapcode)
    configs[1].capcodeSetCallback = cast[pointer](setOther)
'''
    code += rf_procedure(rf, "signExtend")
    if real_update:
        code += update
    else:
        code += "proc bbaApplyCarrierErrorCapcode() = inc applyCalls\n"
    return code + rf_procedure(rf, "bbaRunCarrierErrorLoop")


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_carrier_getter_precedes_live_accumulator_sampling(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, carrier_source() + r'''
for initial in [0'u16, 1, 0x7FFF, 0x8000, 0xFFFF]:
  for next in [0'u16, 1, 0x7FFF, 0x8000, 0xFFFF]:
    setup()
    installSetters()
    state.cePpmAccumulator = initial
    changeAccumulator = true
    nextAccumulator = next
    bbaApplyCarrierErrorCapcode()
    doAssert callLog.len >= 1 and callLog[0].name == "get",
      "carrier-error update skipped the getter on the old accumulator value"
    if next == 0:
      doAssert callLog.len == 1 and savedIrq == 0
      doAssert state.cePpmAccumulator == 0 and state.ceCapcodeHoldoff == 0
    else:
      let expected = if next < 0x8000: 30 else: 32
      doAssert callLog.len == 2 and callLog[1].first == expected,
        "carrier-error direction was sampled before the getter call"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_carrier_setter_receives_two_equal_capcodes_under_irq_mask(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, carrier_source() + r'''
for initialIrq in [false, true]:
  for accumulator in [0'u16, 1, 384, 500, 0x7FFF, 0x8000, 0xFFFF]:
    for cap in 0 .. 255:
      setup()
      installSetters()
      interruptsEnabled = initialIrq
      state.cePpmAccumulator = accumulator
      capcode = cap.uint8
      let before = state
      bbaApplyCarrierErrorCapcode()
      doAssert callLog.len >= 1 and callLog[0] == ("get", initialIrq, cap, 42)
      let changes = accumulator != 0 and
        (if accumulator < 0x8000: cap != 0 else: cap <= 62)
      var expected = before
      if changes:
        let value = if accumulator < 0x8000: cap - 1 else: cap + 1
        doAssert callLog == @[("get", initialIrq, cap, 42), ("set0", false, value, value)],
          "setter ABI or interrupt-mask state differs from the RF object"
        expected.cePpmAccumulator = 0
        expected.ceCapcodeHoldoff = 1
        doAssert writes == @[(14, false), (18, false)]
        doAssert savedIrq == 1 and restoredIrq == 1
      else:
        doAssert callLog.len == 1 and writes.len == 0 and savedIrq == 0
      doAssert state == expected and interruptsEnabled == initialIrq
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_carrier_reloads_setter_config_and_restores_irq_on_local_guards(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, carrier_source() + r'''
for initialIrq in [false, true]:
  for missingBefore in [false, true]:
    for guard in 0 .. 2:
      setup()
      installSetters()
      interruptsEnabled = initialIrq
      if missingBefore: configs[0].capcodeSetCallback = nil
      rebindConfig = true
      removeConfig = guard == 1
      removeSetter = guard == 2
      let before = state
      bbaApplyCarrierErrorCapcode()
      if guard == 0:
        doAssert callLog == @[("get", initialIrq, 31, 42), ("set1", false, 30, 30)],
          "setter did not use the configuration reloaded after the getter"
        doAssert state.cePpmAccumulator == 0 and state.ceCapcodeHoldoff == 1
      else:
        doAssert callLog == @[("get", initialIrq, 31, 42)]
        doAssert state == before and writes.len == 0
      doAssert interruptsEnabled == initialIrq
setup()
wlCfgGlobal = nil
bbaApplyCarrierErrorCapcode()
doAssert callLog.len == 0 and savedIrq == 0
setup()
configs[0].capcodeGetCallback = nil
bbaApplyCarrierErrorCapcode()
doAssert callLog.len == 0 and savedIrq == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_carrier_loop_uses_low_halfword_without_checked_overflow(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, carrier_source(real_update=False) + r'''
proc signedHalf(word: uint32): int32 =
  if word < 32768: word.int32 else: word.int32 - 65536
trackWrites = false
for highWord in [0'u32, 0x12340000, 0x007F0000, 0xFFFF0000'u32]:
  for lowWord in 0'u32 .. 65535:
    for rssi in [-86'i32, -85, -65]:
      for old in [0'u16, 32767, 32768]:
        state = default(BbaRuntimeState)
        state.cePpmAccumulator = old
        applyCalls = 0
        let ppm = highWord or lowWord
        let scaled = signedHalf((lowWord * 64) mod 65536)
        var expected = old.uint32
        if abs(scaled) > 192:
          let weight = if rssi < -85: 64'u32 elif rssi < -65: 128'u32 else: 256'u32
          expected = (expected + lowWord * weight) mod 65536
        bbaRunCarrierErrorLoop(rssi, cast[int32](ppm))
        doAssert state.cePpmAccumulator == expected.uint16
        doAssert applyCalls == (abs(signedHalf(expected)) > 384).int
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_carrier_holdoff_count_uses_exact_byte_gate(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, carrier_source(real_update=False) + r'''
trackWrites = false
for flag in [0'u8, 1, 2, 255]:
  for interval in 0 .. 255:
    for count in 0 .. 255:
      state = BbaRuntimeState(ceUpdateInterval: interval.uint8,
        ceUpdateCount: count.uint8, ceCapcodeHoldoff: flag)
      var expected = state
      if flag == 1:
        if count < interval: expected.ceUpdateCount = (count + 1).uint8
        else:
          expected.ceUpdateCount = 0
          expected.ceCapcodeHoldoff = 0
      bbaRunCarrierErrorLoop(-65, 0)
      doAssert state == expected
''')


def gain_source() -> str:
    rf = RF.read_text()
    code = object_type(rf, "WifiModemBlock") + object_type(rf, "BbaAgcBlock")
    if "var phyRxGainTable*" in rf:
        code += rf[rf.index("var phyRxGainTable*"):].split("\nvar phyRxGainOffsetVsTemperature", 1)[0] + "\n"
    else:
        code += array_constant(rf, "PhyRxGainTable")
    code += r'''
var
  registers: array[0xD000 div 4, uint32]
  phyRxGainOffsetVsTemperature = -128'i8
  writes: seq[tuple[offset: int, value: uint32]]
proc wifiModemRegs(): ptr WifiModemBlock = cast[ptr WifiModemBlock](addr registers[0])
proc bbaAgcRegs(): ptr BbaAgcBlock = cast[ptr BbaAgcBlock](addr registers[0xB000 div 4])
proc volatileLoad[T](p: ptr T): T = p[]
proc volatileStore(p: ptr uint32; value: uint32) =
  writes.add(((cast[uint](p) - cast[uint](addr registers[0])).int, value))
  p[] = value
proc volatileStore(p: ptr int8; value: int8) = p[] = value
proc updateReg32(p: ptr uint32; keep, value: uint32) =
  volatileStore(p, (p[] and keep) or value)
const VendorGains = [14'i8, 19, 26, 32, 38, 45, 50, 57, 63]
'''
    for name in ("phyRxGainByte", "rc2_config_rxgain", "bba_get_pd_cfg"):
        code += rf_procedure(rf, name)
    return code + r'''
proc program(offset: int32) =
  when compiles(rc2_config_rxgain(offset)):
    rc2_config_rxgain(offset)
  else:
    rc2_config_rxgain(cast[int8](offset.uint8))
proc setup() =
  for i in 0 ..< registers.len: registers[i] = 0xA5A55A5A'u32 xor i.uint32
  phyRxGainOffsetVsTemperature = -128
  writes.setLen(0)
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rx_gain_defaults_and_nine_ordered_byte_updates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, gain_source() + r'''
when declared(phyRxGainTable):
  doAssert phyRxGainTable == VendorGains, "RX gain defaults differ from .data.rxgain"
else:
  doAssert PhyRxGainTable == VendorGains, "RX gain defaults differ from .data.rxgain"
for offset in -128 .. 127:
  setup()
  phyRxGainOffsetVsTemperature = (if offset == -128: 0 else: -128).int8
  var expected = registers
  var trace: seq[tuple[offset: int, value: uint32]]
  for i in 0 ..< 9:
    let reg = 0xC080 + (i div 4) * 4
    let shift = (i mod 4) * 8
    let value = ((VendorGains[i].int + offset + 256) mod 256).uint32
    expected[reg div 4] = (expected[reg div 4] and not (255'u32 shl shift)) or (value shl shift)
    trace.add((reg, expected[reg div 4]))
  program(offset.int32)
  doAssert registers == expected and writes == trace,
    "RX gain programming did not preserve the nine byte-field writes"
  writes.setLen(0)
  program(offset.int32)
  doAssert writes.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rx_gain_mutable_table_and_full_word_cache_comparison(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, gain_source() + r'''
when declared(phyRxGainTable):
  for variant in 0 ..< 256:
    for i in 0 ..< 9: phyRxGainTable[i] = cast[int8](((variant + i * 17) mod 256).uint8)
    for offset in [-2147483648'i32, -128, -5, 0, 127, 128, 255, 256, 511, 0x7FFFFFFF]:
      setup()
      let narrowed = cast[int8](offset.uint8)
      phyRxGainOffsetVsTemperature = narrowed
      program(offset)
      if offset == narrowed.int32:
        doAssert writes.len == 0
      else:
        doAssert writes.len == 9 and phyRxGainOffsetVsTemperature == narrowed
        for i in 0 ..< 9:
          let word = registers[(0xC080 + (i div 4) * 4) div 4]
          let wanted = ((phyRxGainTable[i].int + narrowed.int + 512) mod 256).uint32
          doAssert ((word shr ((i mod 4) * 8)) and 255) == wanted
else:
  doAssert false, "RX gain asset is not mutable/exported"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_detector_config_reports_full_six_bit_dsss_field(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, gain_source() + r'''
for ofdm in 0'u32 .. 15:
  for dsss in 0'u32 .. 63:
    for threshold in 0'u32 .. 255:
      registers[0xB390 div 4] = (0xA5A55A5A'u32 and 0xFFFFFF0F'u32) or (ofdm shl 4)
      registers[0xC830 div 4] = (0x5A5AA5A5'u32 and 0xFC0FFFFF'u32) or (dsss shl 20)
      registers[0xB3C0 div 4] = (0x87654321'u32 and 0xFFFF00FF'u32) or (threshold shl 8)
      var a, b, c: uint8
      bba_get_pd_cfg(addr a, addr b, addr c)
      doAssert a == ofdm.uint8 and b == dsss.uint8 and c == threshold.uint8,
        "detector getter truncated bits 25:24"
var alias: uint8
bba_get_pd_cfg(addr alias, addr alias, addr alias)
doAssert alias == 255
bba_get_pd_cfg(nil, nil, nil)
doAssert writes.len == 0
''')
