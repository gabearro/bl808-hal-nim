"""Native post-VCO bus trace, from Git blob a9935b475d2198000ae7b67d141f00767176a81a."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, object_type


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_native_rfc_completion_bus_trace(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = object_type(rf, "RfRegBlock") + object_type(rf, "PhyAgcBlock")
    code += r'''
template rfRegs(): ptr RfRegBlock = cast[ptr RfRegBlock](0x20001000'u)
template phyRegs(): ptr PhyAgcBlock = cast[ptr PhyAgcBlock](0x20002800'u)

type Event = tuple[kind: char; address, value: uint32]
var
  expected: seq[Event]
  cursor: int

proc consume(kind: char; address: uint): uint32 =
  doAssert cursor < expected.len, "extra bus access: " & $cursor
  let e = expected[cursor]
  doAssert e.kind == kind and e.address.uint == address, "wrong bus access: " & $cursor
  inc cursor
  e.value
proc volatileLoad(p: ptr uint32): uint32 = consume('r', cast[uint](p))
proc volatileStore(p: ptr uint32; v: uint32) =
  doAssert consume('w', cast[uint](p)) == v, "wrong store: " & $cursor
proc waitRfUs(us: uint32) =
  doAssert false, "native RFC called the platform timer"
proc waitBl808RfcUs(us: uint32) =
  doAssert consume('d', 0) == us * 16, "wrong delay count: " & $cursor
proc rfBankHasBl808WlanCal(): bool = true
'''
    code += procedure((RF.parents[3] / "radio_phy.nim").read_text(), "updateReg32")
    code += procedure(rf, "waitRfRfcUs")
    code += procedure(rf, "rfc_rc_fsm_force")
    code += f'include "{RF.with_name("rf_bl808_rfc_tail.nim")}"\n'
    run_program(tmp_path, mode, code + r'''
const
  ctrl = 0x20001004'u32
  synth = 0x2000102C'u32
  rx = 0x20001220'u32
  dfe = 0x2000163C'u32
  gate = 0x4000E41C'u32

for seed in [0'u32, high(uint32), 0xA5A55A5A'u32]:
  expected.setLen(0)
  cursor = 0
  proc readWord(address: uint32): uint32 =
    # Also supply fresh unrelated bits on every read (including gate release).
    result = if seed == 0xA5A55A5A'u32: seed xor (expected.len.uint32 * 0x9E3779B9'u32)
             else: seed
    expected.add(('r', address, result))
  proc rmw(address, clear, bits: uint32) =
    let old = readWord(address)
    expected.add(('w', address, (old and not clear) or bits))
  proc delay(count: uint32) = expected.add(('d', 0'u32, count))

  # rfc.o:.text.rfc_init+0x74e..+0x7f4.
  rmw(ctrl, 1 shl 11, 0)
  rmw(0x2000126C, 1 shl 3, 0)
  rmw(0x20001268, 0xFFFF, 0x1040)
  rmw(ctrl, 0, 2)
  rmw(synth, 0, 4)
  rmw(dfe, 0, 1 shl 7)
  rmw(dfe, 0, 1 shl 15)
  rmw(dfe, 0x7F, 0)
  rmw(dfe, 0x7F shl 8, 0)
  rmw(synth, 0, 2)
  rmw(synth, 0, 1 shl 14)
  rmw(synth, 0, 1 shl 5)

  # +0x7f6..+0x884; waits relocated at +0x812 and +0x826.
  rmw(rx, 1 shl 27, 0)
  rmw(ctrl, 0xC, 0)
  rmw(gate, 1 shl 6, 0)
  delay(16)
  rmw(ctrl, 0xC, 4)
  delay(16)
  rmw(gate, 0, 1 shl 6)
  rmw(rx, 1 shl 4, 0)
  rmw(synth, 0, 4)
  rmw(dfe, 0, 1 shl 7)
  rmw(dfe, 0, 1 shl 15)
  rmw(synth, 0, 1 shl 14)
  rmw(synth, 1 shl 5, 0)
  for i in 0..<3: discard readWord(synth) # +0x886/+0x894/+0x8aa

  rmw(0x20001618, 3'u32 shl 30, 2'u32 shl 30)
  # +0x8d8 -> rfc_helper.o:.text.rfc_rc_fsm_force+0x0c..+0x44.
  rmw(ctrl, 7 shl 8, 7 shl 8)
  delay(320)
  rmw(ctrl, 0, 1 shl 11)
  rmw(rx, 0, 2)
  rmw(rx, 0, 1)
  delay(16)
  # +0x904 -> same helper, release branch +0x4a..+0x72.
  rmw(ctrl, 7 shl 8, 0)
  delay(320)
  rmw(ctrl, 1 shl 11, 0)
  rmw(rx, 2, 0)
  rmw(rx, 1, 0)
  expected.add(('w', 0x200028A8'u32, 200'u32)) # +0x928: no preceding read

  programBl808RfcModemLateInit()
  doAssert cursor == expected.len, "incomplete native RFC tail"
''', defines=("bl808WifiNativeWlanCalibration",))
