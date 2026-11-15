"""Check antenna selection and byte-aligned PHY group programming."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_sta_tx_channel import object_type


def source() -> str:
    rf = (FW / "global_state/rf_bl808_core.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    code = object_type(rf, "WifiModemBlock")
    code += r'''
var
  modem: WifiModemBlock
  version: uint32
  reads: int
  writes: seq[int]
proc modemVersionReg(): uint32 =
  inc reads
  version
proc wifiModemRegs(): ptr WifiModemBlock = addr modem
proc volatileStore(p: ptr uint32; value: uint32) =
  writes.add(cast[int](p) - cast[int](addr modem))
  p[] = value
'''
    for text, name in [(layout, "le32"), (rf, "phy_get_antenna_set"),
                       (rf, "phy_set_group_id_info")]:
        code += procedure(text, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_phy_antenna_mask(tmp_path: Path, mode: str) -> None:
    code = source() + r'''
for txCount in 0'u32..15:
  for rxCount in 0'u32..15:
    for unrelated in [0'u32, 0xFFFFFF00'u32, 0xA5A55A00'u32]:
      version = unrelated or (txCount shl 4) or rxCount
      reads = 0
      let expected = ((1'u32 shl txCount) - 1'u32) and 255'u32
      doAssert phy_get_antenna_set() == expected.uint8,
        "antenna mask must use the TX-chain count"
      doAssert reads == 1
'''
    run_program(tmp_path, mode, code)


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "alignment"])
def test_phy_group_info(tmp_path: Path, mode: str) -> None:
    code = source() + r'''
proc fillModem() =
  let bytes = cast[ptr UncheckedArray[uint8]](addr modem)
  for i in 0..<sizeof(modem): bytes[i] = ((i * 13 + 7) and 255).uint8
  writes.setLen(0)
proc expectedWord(bytes: openArray[uint8]; offset: int): uint32 =
  for i in 0..<4: result = result or (bytes[offset + i].uint32 shl (i * 8))
var
  membership {.align: 4.}: array[12, uint8]
  positions {.align: 4.}: array[20, uint8]
for seed in [0, 1, 127, 255]:
  for i in 0..<membership.len: membership[i] = ((seed + i * 31) and 255).uint8
  for i in 0..<positions.len: positions[i] = ((seed + i * 43) and 255).uint8
  for memberOffset in 0..3:
    for positionOffset in 0..3:
      for memberPresent in [false, true]:
        for positionsPresent in [false, true]:
          fillModem()
          var expected = modem
          var expectedWrites: seq[int]
          if memberPresent:
            expected.groupMembership0 = expectedWord(membership, memberOffset)
            expected.groupMembership1 = expectedWord(membership, memberOffset + 4)
            expectedWrites.add(0x8A8)
            expectedWrites.add(0x8AC)
          if positionsPresent:
            for i in 0..<4:
              expected.userPosition[i] = expectedWord(positions, positionOffset + i * 4)
              expectedWrites.add(0x8B0 + i * 4)
          let originalMembers = membership
          let originalPositions = positions
          phy_set_group_id_info(
            (if memberPresent: addr membership[memberOffset] else: nil),
            (if positionsPresent: addr positions[positionOffset] else: nil))
          doAssert modem == expected
          doAssert writes == expectedWrites
          doAssert membership == originalMembers and positions == originalPositions
'''
    if mode == "alignment":
        code = ('{.passC: "-fsanitize=alignment -fno-sanitize-recover=alignment".}\n'
                '{.passL: "-fsanitize=alignment".}\n' + code)
        mode = "checked"
    run_program(tmp_path, mode, code)
