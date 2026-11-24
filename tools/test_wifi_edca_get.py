"""Check EDCA register decode and output-store order against mm_task.o."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    mac = (FW / "mac_config_debug.nim").read_text()
    return r'''
const
  MACHW_EDCA_AC_BK_REG = 0x24B00200'u
  MACHW_EDCA_AC_BE_REG = 0x24B00204'u
  MACHW_EDCA_AC_VI_REG = 0x24B00208'u
  MACHW_EDCA_AC_VO_REG = 0x24B0020C'u
var reads: seq[uint]
proc regRead(address: uint): uint32 =
  reads.add(address)
  case address
  of MACHW_EDCA_AC_BK_REG: 0x12345678'u32
  of MACHW_EDCA_AC_BE_REG: 0x89ABCDEF'u32
  of MACHW_EDCA_AC_VI_REG: 0xDEADBEEF'u32
  of MACHW_EDCA_AC_VO_REG: 0xFEDCBA98'u32
  else: raiseAssert("unexpected EDCA register")
''' + procedure(mac, "bl60x_edca_get")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_edca_get(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
let addresses = [MACHW_EDCA_AC_BK_REG, MACHW_EDCA_AC_BE_REG,
                 MACHW_EDCA_AC_VI_REG, MACHW_EDCA_AC_VO_REG]
let words = [0x12345678'u32, 0x89ABCDEF'u32, 0xDEADBEEF'u32, 0xFEDCBA98'u32]
for ac in 0 .. 3:
  reads.setLen(0)
  var aifs, cwmin, cwmax: uint8 = 0xA5
  var txop: uint16 = 0xA5A5
  doAssert bl60x_edca_get(ac.cint, addr aifs, addr cwmin, addr cwmax,
                           addr txop) == 0
  let word = words[ac]
  doAssert reads == @[addresses[ac]]
  doAssert aifs == (word and 0xF).uint8
  doAssert cwmin == ((word shr 4) and 0xF).uint8
  doAssert cwmax == ((word shr 8) and 0xF).uint8
  doAssert txop == (word shr 12).uint16

for ac in [-1.cint, 4.cint, high(cint)]:
  reads.setLen(0)
  var aifs, cwmin, cwmax: uint8 = 0xA5
  var txop: uint16 = 0xA5A5
  doAssert bl60x_edca_get(ac, addr aifs, addr cwmin, addr cwmax,
                           addr txop) == -1
  doAssert reads.len == 0
  doAssert aifs == 0xA5 and cwmin == 0xA5 and cwmax == 0xA5
  doAssert txop == 0xA5A5

# The vendor writes txop first and aifs last. Alias outputs to expose order.
for ac in 0 .. 3:
  reads.setLen(0)
  var output = 0xA5A5'u16
  let byteOutput = cast[ptr uint8](addr output)
  doAssert bl60x_edca_get(ac.cint, byteOutput, byteOutput, byteOutput,
                           addr output) == 0
  let expected = (((words[ac] shr 20) and 0xFF'u32) shl 8) or
                 (words[ac] and 0xF'u32)
  doAssert output == expected.uint16
  doAssert reads == @[addresses[ac]]
''')
