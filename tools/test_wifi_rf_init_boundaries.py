"""Compare the initializer's MMIO boundaries with the selected RF object."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, object_type, source


def boundary_source() -> str:
    rf = RF.read_text()
    code = source(real_io=True)
    code += object_type(rf, "RfPllBlock") + object_type(rf, "RfDfeInitBlock")
    code += r'''
var pll: RfPllBlock
var dfe: RfDfeInitBlock
proc rfPllRegs(): ptr RfPllBlock = addr pll
proc rfDfeInitRegs(): ptr RfDfeInitBlock = addr dfe
proc rfPriEfuseInit() = discard
proc rf_pri_xtalfreq() = discard
proc writeRfPriFixedValueRegs() = discard
proc rfPriSnapshotStage(tag: uint32) = discard
'''
    if "proc writeRfPriStaticInit(" in rf:
        code += procedure(rf, "writeRfPriStaticInit")
    init = procedure(rf, "rf_pri_init")
    prefix = init[init.index("  rfPriEfuseInit()"):].split(
        "  rfPriWifiPllConfig()", 1
    )[0]
    code += "proc initializePrePll() =\n" + prefix
    rx = init.split("  let rf = rfRegs()", 1)[1].split("  if needsFullCal:", 1)[0]
    code += "proc initializeRxMode() =\n  let rf = rfRegs()" + rx
    return code + r'''
static:
  doAssert offsetof(RfRegBlock, rxMode220) == 0x220
  doAssert offsetof(RfRegBlock, calPathCtrl90) == 0x90
  doAssert offsetof(RfRegBlock, rfGainTable75c) == 0x75C
  doAssert offsetof(RfRegBlock, rfGainTable760) == 0x760
  doAssert offsetof(RfTxPowerCompTableBlock, txPowerCompWords700) == 0x700
  doAssert sizeof(RfTxPowerCompTableBlock) <= sizeof(RfRegBlock)
proc seedRegisters() =
  for word in registerStorage.mitems: word = randomWord()
  let pllWords = cast[ptr UncheckedArray[uint32]](addr pll)
  for i in 0 ..< sizeof(pll) div 4: pllWords[i] = randomWord()
  let dfeWords = cast[ptr UncheckedArray[uint32]](addr dfe)
  for i in 0 ..< sizeof(dfe) div 4: dfeWords[i] = randomWord()
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_no_additional_static_writes_between_fixed_defaults_and_pll(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, boundary_source() + r'''
for vector in 0 ..< 1000:
  setup()
  seedRegisters()
  let rfBefore = registerStorage
  let pllBefore = pll
  let dfeBefore = dfe
  initializePrePll()
  doAssert registerStorage == rfBefore and pll == pllBefore and dfe == dfeBefore,
    "unlisted static init rewrote fixed defaults or enabled the PLL early"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rx_preparation_preserves_calibration_path_control(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, boundary_source() + r'''
for vector in 0 ..< 1000:
  setup()
  seedRegisters()
  var expected = registerStorage
  expected[0x220 div 4] = expected[0x220 div 4] and 0xFFFFE67D'u32 and 0xFFFFFF9E'u32
  initializeRxMode()
  doAssert registerStorage == expected,
    "RX preparation changed calibration-path control or unrelated RF fields"
''')
