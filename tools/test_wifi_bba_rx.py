"""Compare BBA RX-vector math and detector transitions with the RF object."""

from pathlib import Path
import shutil
import subprocess
import re

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure
from test_wifi_sta_tx_channel import object_type


def implementation(source: str, name: str) -> str:
    return procedure(source[source.rindex(f"proc {name}"):], name)


PLATFORM = r'''
type
  Rf = object
    pdCompLatchCtrl50c: uint32
  Bba = object
    pdGain390, pdCompC830: uint32
var
  state: BbaRuntimeState
  rf: Rf
  bba: Bba
  interruptsEnabled = true
  strictIrq: bool
  irqEntries: int
  gains: seq[uint32]
  events: seq[string]
  carrierSamples: seq[tuple[rssi, ppm: int32]]
  detectorSamples: seq[int32]
  mutateVector: ptr BbaRxVectorView
  nextRssi: uint8
proc stateWrite(p: pointer) =
  var name = ""
  if p == (addr state.pdRssiState): name = "state"
  elif p == (addr state.pdCompLatch): name = "latch"
  elif p == (addr state.pdCompCurrent): name = "comp"
  if name.len != 0:
    if strictIrq: doAssert not interruptsEnabled, "unmasked detector state write"
    events.add(name)
template volatileLoad(p: untyped): untyped = p[]
template volatileStore(p, v: untyped) =
  let destination = p
  stateWrite(cast[pointer](destination))
  destination[] = v
proc bbaState(): ptr BbaRuntimeState = addr state
proc bbaRxVecPtr(p: pointer): ptr BbaRxVectorView = cast[ptr BbaRxVectorView](p)
proc rfRegs(): ptr Rf = addr rf
proc bbaAgcRegs(): ptr Bba = addr bba
proc bbaIrqSave(): uint32 =
  inc irqEntries
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc bbaIrqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
proc updateReg32(p: ptr uint32; mask, value: uint32) =
  if strictIrq: doAssert not interruptsEnabled, "unmasked detector register write"
  events.add(if p == (addr rf.pdCompLatchCtrl50c): "latch-reg" else: "comp-reg")
  p[] = (p[] and mask) or value
proc bbaProgramPdGain(gain: uint32) =
  if strictIrq: doAssert not interruptsEnabled, "unmasked detector gain update"
  gains.add(gain)
  events.add("gain")
  state.pdGainCode = gain.uint8
proc bbaRunCarrierErrorLoop(rssi, ppm: int32) =
  carrierSamples.add((rssi, ppm))
  if mutateVector != nil: mutateVector.rssiDbm = nextRssi
proc floorDivide(value, divisor: int): int =
  if value < 0: -((-value + divisor - 1) div divisor) else: value div divisor
proc signedByte(value: int): int = ((value + 128) mod 256 + 256) mod 256 - 128
proc dsssExpected(raw: int): int = floorDivide(signedByte(raw) * 45, 64)
proc ofdmExpected(raw: int): int =
  let signed = if raw >= 32768: raw - 65536 else: raw
  signedByte(floorDivide(-17 * floorDivide(signed, 16), 128))
proc reset() =
  state = BbaRuntimeState(pdGainCode: 3, cePpmAccumulator: 0x4567,
    ceUpdateInterval: 10, ceUpdateCount: 3, ceCapcodeHoldoff: 1)
  rf.pdCompLatchCtrl50c = 0xDAABCDEF'u32
  bba.pdGain390 = 0x89ABCDEF'u32
  bba.pdCompC830 = 0x76543210'u32
  strictIrq = false
  irqEntries = 0
  gains.setLen(0)
  events.setLen(0)
  carrierSamples.setLen(0)
  detectorSamples.setLen(0)
  mutateVector = nil
'''


def source(*, sample_loop: bool = False) -> str:
    rf = (FW / "global_state/rf_bl808_core.nim").read_text()
    code = object_type(rf, "BbaRuntimeState") + object_type(rf, "BbaRxVectorView")
    for name in ("BbaPdThresholdAttack", "BbaPdThresholdRelease"):
        match = re.search(rf"^  {name}.*?\[[^\n]*?\]\s*$", rf, re.M | re.S)
        assert match
        code += ("var\n" if 'exportc: "pd_th_att"' in rf else "const\n") + match[0] + "\n"
    code += PLATFORM
    for name in ["signExtend", "bbaExtractBits", "bbaProgramPdLatchRegs", "bbaSetPdLatch", "bbaUpdatePdComp",
                 "bbaRxFormatWord1", "calc_ppm", "bba_rssi_correction"]:
        if name == "bbaProgramPdLatchRegs" and f"proc {name}(" not in rf:
            continue
        code += implementation(rf, name)
    if sample_loop:
        code += "proc bbaRunPowerDetectLoop(rssi: int32) = detectorSamples.add(rssi)\n"
    else:
        code += implementation(rf, "bbaRunPowerDetectLoop")
    code += implementation(rf, "bba_pd_loop")
    code += implementation(rf, "bba_loop")
    for name in ["wl_wlan_bb_pre_proc", "wl_wlan_bb_post_proc", "wl_wlan_rssi_get", "wl_wlan_ppm_get"]:
        code += implementation(rf, name)
    return code


CASES = {
    "dsss": r'''
var vector: BbaRxVectorView
for rate in 0..3:
  vector.rxFormatWord1Rate = (rate * 16 + 7).uint8
  for upper in [0, 85, 255]:
    for raw in 0..255:
      vector.carrierFreqOffset = (upper * 256 + raw).uint16
      let before = vector
      doAssert calc_ppm(addr vector).int == dsssExpected(raw), "DSSS scale differs from RF object"
      doAssert wl_wlan_ppm_get(addr vector).int == dsssExpected(raw)
      doAssert vector == before
''',
    "ofdm": r'''
var vector = BbaRxVectorView(rxFormatModeWord0: 1)
for raw in 0..65535:
  vector.carrierFreqOffset = raw.uint16
  doAssert calc_ppm(addr vector).int == ofdmExpected(raw), "OFDM rounding differs from RF object"
''',
    "format_selection": r'''
var vector: BbaRxVectorView
for mode in 0..15:
  for rate in 0..15:
    vector.rxFormatModeWord0 = 0xABCD1200'u32 or mode.uint32
    vector.rxFormatWord1Rate = (rate * 16 + 15).uint8
    vector.rssiDbm = 0xA5
    vector.rxFormatWord1Mcs = 0x5A
    vector.rxFormatWord1Flags = 0xCF
    for raw in [0, 1, 15, 16, 63, 127, 128, 255, 256, 32767, 32768, 65535]:
      vector.carrierFreqOffset = raw.uint16
      let expected = if mode == 0 and rate <= 3: dsssExpected(raw and 255) else: ofdmExpected(raw)
      doAssert calc_ppm(addr vector).int == expected
''',
    "rssi": r'''
var vector: BbaRxVectorView
for latch in [0'u8, 1, 2, 255]:
  for raw in 0..255:
    reset()
    state.pdCompLatch = latch
    vector = BbaRxVectorView(rxFormatModeWord0: 0x12345678'u32, rssiDbm: raw.uint8,
      rxFormatWord1Mcs: 0xA5, rxFormatWord1Flags: 0x5A, carrierFreqOffset: 0x7788)
    var expected = vector
    if latch != 0: expected.rssiDbm = ((raw + 20) mod 256).uint8
    wl_wlan_bb_pre_proc(addr vector)
    doAssert vector == expected
    doAssert wl_wlan_rssi_get(addr vector).int == signedByte(expected.rssiDbm.int)
doAssert calc_ppm(nil) == 0 and wl_wlan_ppm_get(nil) == 0 and wl_wlan_rssi_get(nil) == 0
wl_wlan_bb_pre_proc(nil)
''',
    "loop_sampling": r'''
var vector: BbaRxVectorView
for frameType in [0'u32, 0x40, 0x80, 0x100, 0x180]:
  for change in [false, true]:
    reset()
    vector = BbaRxVectorView(rssiDbm: 0xA0, carrierFreqOffset: 0)
    if change:
      mutateVector = addr vector
      nextRssi = 0x81
    wl_wlan_bb_post_proc(addr vector, frameType)
    if frameType == 0x80:
      doAssert carrierSamples == @[(rssi: -96'i32, ppm: 0'i32)]
      doAssert detectorSamples == @[(if change: -127'i32 else: -96'i32)],
        "detector did not reload RSSI after carrier-error processing"
    else:
      doAssert carrierSamples.len == 0 and detectorSamples.len == 0
reset()
wl_wlan_bb_post_proc(nil, 0x80)
doAssert carrierSamples.len == 0 and detectorSamples.len == 0
''',
    "detector_transitions": r'''
for initial in [0'u8, 1, 2, 3, 4, 255]:
  for rssi in -128..127:
    for latch in [0'u8, 1, 2]:
      for comp in [0'u8, 1]:
        for enabled in [false, true]:
          reset()
          state.pdRssiState = initial
          state.pdCompLatch = latch
          state.pdCompCurrent = comp
          interruptsEnabled = enabled
          var expected = state
          var selected = initial
          case initial
          of 0:
            if rssi > -70: selected = 1
          of 1:
            if rssi > -48: selected = 2
            elif rssi < -75: selected = 0
          of 2:
            if rssi < -75: selected = 0
            elif rssi < -53: selected = 1
          of 3:
            if rssi < -75: selected = 0
            elif rssi < -53: selected = 1
            elif rssi < -41: selected = 2
          else:
            if rssi > -70: selected = 1
          let expectedLatch = if initial in [2'u8, 3] and rssi >= -14: 1'u8 else: 0'u8
          let expectedComp = if (initial == 0 or (initial in [1'u8, 2, 3] and selected == 0)) and rssi < -90: 1'u8 else: 0'u8
          expected.pdRssiState = selected
          expected.pdCompLatch = expectedLatch
          expected.pdCompCurrent = expectedComp
          if selected != initial: expected.pdGainCode = selected
          bba_pd_loop(rssi.int32)
          doAssert state == expected, "detector state differs from RF object"
          doAssert interruptsEnabled == enabled
          doAssert gains == (if selected == initial: @[] else: @[selected.uint32])
          let expectedRf = if latch == expectedLatch: 0xDAABCDEF'u32 else:
            (0xDAABCDEF'u32 and not 0x300'u32) or (expectedLatch.uint32 shl 8)
          doAssert rf.pdCompLatchCtrl50c == expectedRf
          doAssert bba.pdGain390 == (if comp == expectedComp: 0x89ABCDEF'u32 else: 0x89ABCD0F'u32)
          doAssert bba.pdCompC830 == (if comp == expectedComp: 0x76543210'u32 else:
            (0x76543210'u32 and 0xFC0FFFFF'u32) or (expectedComp.uint32 shl 20))
''',
    "detector_atomicity": r'''
for enabled in [false, true]:
  for scenario in 0..3:
    reset()
    interruptsEnabled = enabled
    strictIrq = true
    state.pdCompCurrent = 1
    state.pdCompLatch = 1
    let rssi = case scenario
      of 0:
        state.pdRssiState = 0
        -50'i32
      of 1:
        state.pdRssiState = 1
        -100'i32
      of 2:
        state.pdRssiState = 2
        state.pdCompLatch = 0
        -10'i32
      else:
        state.pdRssiState = 3
        -45'i32
    bba_pd_loop(rssi)
    doAssert interruptsEnabled == enabled
    let groups = (if gains.len != 0: 1 else: 0) +
      (if "latch" in events: 1 else: 0) + (if "comp" in events: 1 else: 0)
    doAssert irqEntries == groups
''',
}


def test_bba_critical_sections_have_compiler_barriers() -> None:
    rf = (FW / "global_state/rf_bl808_core.nim").read_text()
    save = rf.split("template bbaIrqSave()", 1)[1].split("template bbaIrqRestore", 1)[0]
    restore = rf.split("template bbaIrqRestore", 1)[1].split("\nproc ", 1)[0]
    assert r':: \"memory\"' in save
    assert r'::: \"memory\"' in restore


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_bba_rx(tmp_path: Path, case: str, mode: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "bba_rx.nim"
    path.write_text(source(sample_loop=case == "loop_sampling") + CASES[case])
    flags = {
        "checked": [],
        "release": ["-d:release", "--assertions:on"],
        "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"],
    }[mode]
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--checks:on", *flags, f"--nimcache:{tmp_path / 'cache'}",
        f"-o:{tmp_path / 'check'}", str(path)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout
