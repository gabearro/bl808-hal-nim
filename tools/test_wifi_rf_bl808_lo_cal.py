"""Check BL808 LO calibration from measurement through channel-9 setup."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_lo_search import packed_lo_source
from test_wifi_rf_power_replay import RF, object_type


def native_lo_source() -> str:
    rf = RF.read_text()
    code = "var nativeDelayCalls: seq[uint32]\nproc rfBankUsesBl808LoCal(): bool = true\n" + packed_lo_source()
    delay_stub = """proc waitBl808RfCalUs(us: uint32) =
  nativeDelayCalls.add(us)
  waitRfUs(us)
"""
    code = code.replace("proc waitRfCalibrationUs", delay_stub + "proc waitRfCalibrationUs", 1)
    snapshot = object_type(rf, "RfDfeInitBlock") + (
        "var fixtureDfe: RfDfeInitBlock\n"
        "proc rfDfeInitRegs(): ptr RfDfeInitBlock = addr fixtureDfe\n"
    ) + RF.with_name("rf_bl808_calibration_snapshot.nim").read_text()
    start = rf.index("  type RfLoCalState = object")
    end = rf.index("proc waitRfFcalReady", start)
    snapshot += "\n".join(line[2:] for line in rf[start:end].splitlines()) + "\n"
    code = code.replace("proc runRfPriLoFcal()", snapshot + "proc runRfPriLoFcal()", 1)
    for name in ("rfPriVcoCalWord", "rf_pri_get_vco_freq_cw", "rf_pri_get_vco_idac_cw"):
        code += rf_procedure(rf, name)
    # The shared power-table fixture is only here for the RF register mock.
    code = code.replace("  when defined(bl808WifiNativeWlanCalibration):\n    if rfBankHasBl808WlanCal()",
                        "  when false:\n    if rfBankHasBl808WlanCal()")
    return code.replace("defined(bl808WifiNativeWlanCalibration)", "true")


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_native_fcal_first_crossing_flows_to_channel_nine(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, native_lo_source() + r'''
proc checkNativeRestore(before: typeof(registerStorage)) =
  let restored = mmioWrites[^28 .. ^2]
  for (i, offset) in [(8, 0x84), (9, 0x8C), (25, 0x70)]:
    let p = addr registerStorage[offset div 4]
    doAssert restored[i] == (cast[uint](p), before[offset div 4])
  for event in restored:
    doAssert event.address notin [cast[uint](addr rf70.txcalDfe88),
      cast[uint](addr rf70.calPathCtrl90), cast[uint](addr rf70.txcalParam74)]

loSetup(4)
let halves = cast[ptr UncheckedArray[uint16]](addr calibration[0])
for slot in 0 ..< 21: halves[14 + slot] = 0xADAA
let target = VendorCnt[4][9]
sampleValues = @[VendorRange[4][0] + 1, target - 100, target - 5,
                 target - 1, target + 10, VendorRange[4][2] + 1]
let beforeFcal = registerStorage
runRfPriLoFcal()
doAssert nativeDelayCalls == @[10'u32, 50, 50, 100, 100, 100, 100, 100, 100]
doAssert sampleIndex == 6 and halves[23] == 0xAD7F and channelFcalTable[9] == 0x7F
doAssert rfLoFcal(9) == 0x7F and rfLoAcal(9) == 13
checkNativeRestore(beforeFcal)

let beforeAcal = registerStorage
for i in 0 ..< 21 * 5: comparatorBits.add(0)
nativeDelayCalls.setLen(0)
runRfPriLoAcal()
doAssert nativeDelayCalls.len == 21 * 6
for delay in nativeDelayCalls: doAssert delay == 1
doAssert comparatorIndex == 105 and halves[23] == 0xBF7F
doAssert channelAcalTable[9] == 31
checkNativeRestore(beforeAcal)
doAssert rf_pri_get_vco_freq_cw(2440) == 0x7F and rf_pri_get_vco_idac_cw(2440) == 31

# Pinned demo rf_pri_txcal+0xfc..+0x1dc: distinct keep masks for
# the synthesizer coarse code, sigma-delta divider, and strobe.
rf70.priModeCtrl30 = 0x12345678'u32
rf70.fcalCtrlA0 = 0xABCDEF12'u32
rf70.channelFcalConfigBc = 0xFEDCBA98'u32
rf70.sdmDivC4 = 0xF1234567'u32
rf70.sdmCtrlC0 = 0xAAFFF005'u32
rf70.txcalCtrlB8 = 0x32100012'u32
rf70.channelCalStrobeB0 = 0xC0010000'u32
rf70.channelCalStatusB4 = 0
nativeDelayCalls.setLen(0)
mmioWrites.setLen(0)
rfPriConfigChannelForCal(9)
doAssert nativeDelayCalls == @[10'u32, 50, 10, 50]
doAssert mmioWrites == @[
  (cast[uint](addr rf70.priModeCtrl30), 0x12F45678'u32),
  (cast[uint](addr rf70.fcalCtrlA0), 0xABDFEF7F'u32),
  (cast[uint](addr rf70.channelFcalConfigBc), 0xFE7CBA98'u32),
  (cast[uint](addr rf70.sdmDivC4), 0xD4555555'u32),
  (cast[uint](addr rf70.sdmCtrlC0), 0xAAFFE005'u32),
  (cast[uint](addr rf70.txcalCtrlB8), 0x32110012'u32),
  (cast[uint](addr rf70.txcalCtrlB8), 0x32100012'u32),
  (cast[uint](addr rf70.channelCalStrobeB0), 0xD0010000'u32),
  (cast[uint](addr rf70.channelCalStrobeB0), 0xC0010000'u32)
]
''')


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_native_fcal_sweep_steps_as_a_halfword(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, native_lo_source() + r'''
loSetup(4)
let limits = VendorRange[4]
sampleValues = @[limits[0] - 1, limits[0] - 1, limits[0] - 1, limits[0] - 1,
                 limits[1] + 1, limits[1] + 1, limits[1] + 1]
for i in 0 ..< 40: sampleValues.add(limits[0])
rf70.fcalCtrlA0 = 0xABCD1200'u32
runRfPriLoFcal()
doAssert sampleIndex == 47
var a0: seq[uint32]
for event in mmioWrites:
  if event.address == cast[uint](addr rf70.fcalCtrlA0): a0.add(event.value)
doAssert a0[8 + 16] == 0xABCD1200'u32
doAssert a0[8 + 17] == 0xABCDFFFF'u32
''')
