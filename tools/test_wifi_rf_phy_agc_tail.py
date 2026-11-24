"""Normal PHY post-AGC register tail from the pinned phy.c.o object."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_low_power import phy_source


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_normal_phy_agc_event_fields_match_object(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, phy_source() + r'''
const eventWrites = [
  (0xB384, 0x03FFFFFF'u32, 0xE4000000'u32),
  (0xB384, 0xFC0FFFFF'u32, 0x03700000'u32),
  (0xB384, 0xFFF03FFF'u32, 0x00050000'u32),
  (0xB384, 0xFFFFDFFF'u32, 0'u32),
  (0xB384, 0xFFFFE3FF'u32, 0x00000800'u32),
  (0xB388, 0x03FFFFFF'u32, 0x3C000000'u32),
  (0xB388, 0xFC0FFFFF'u32, 0x01700000'u32),
  (0xB388, 0xFFF03FFF'u32, 0x000A8000'u32),
  (0xB388, 0xFFFFDFFF'u32, 0'u32),
  (0xB388, 0xFFFFE3FF'u32, 0x00001400'u32),
]
for vector in 0 ..< 200:
  setup()
  var expected = modemBank
  var trace: seq[tuple[address, value: uint32]]
  for row in eventWrites:
    expected[row[0] div 4] = (expected[row[0] div 4] and row[1]) or row[2]
    trace.add((0x24C00000'u32 + row[0].uint32, expected[row[0] div 4]))
  bl808PhyProgramAgcCoreRegs()
  var first = -1
  for i, row in writes:
    if row.address == 0x24C0B384'u32:
      first = i
      break
  doAssert first >= 0
  doAssert writes[first ..< first + trace.len] == trace,
    "normal PHY AGC event stores differ from phy_init+0x6ce..0x776"
  doAssert modemBank[0xB384 div 4] == expected[0xB384 div 4]
  doAssert modemBank[0xB388 div 4] == expected[0xB388 div 4]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_normal_phy_agc_tail_store_order_and_masks(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, phy_source() + r'''
const tail = [
  (0xC864, 0'u32, 0x0000C078'u32),
  (0xB390, 0xFFFFFF0F'u32, 0x00000010'u32),
  (0xC834, 0xFFFFFFFC'u32, 0x00000001'u32),
  (0xB304, 0xFFFF80FF'u32, 0x00004B00'u32),
  (0xC814, 0xFFFFFFFC'u32, 0x00000002'u32),
  (0xC814, 0xFFFFFFC3'u32, 0x00000008'u32),
  (0xC814, 0xFFFFFC3F'u32, 0x00000080'u32),
  (0xC040, 0xFE0FFFFF'u32, 0x00E00000'u32),
  (0xC040, 0xFFF07FFF'u32, 0'u32),
  (0xC044, 0xFFFF00FF'u32, 0x00000800'u32),
  (0xC044, 0xFFFFFF00'u32, 0'u32),
]
for vector in 0 ..< 200:
  setup()
  var expected = modemBank
  expected[0xB390 div 4] =
    (expected[0xB390 div 4] and 0xFFFFFFFC'u32) or 1'u32
  var trace: seq[tuple[address, value: uint32]]
  for row in tail:
    expected[row[0] div 4] = (expected[row[0] div 4] and row[1]) or row[2]
    trace.add((0x24C00000'u32 + row[0].uint32, expected[row[0] div 4]))
  bl808PhyProgramAgcCoreRegs()
  doAssert writes.len >= tail.len + 1
  doAssert writes[^(tail.len + 1)].address == 0x24C0B414'u32
  doAssert writes[^tail.len .. ^1] == trace,
    "normal PHY post-AGC stores differ from phy_init+0x8a4..0x938"
  for row in tail:
    doAssert modemBank[row[0] div 4] == expected[row[0] div 4]
''')
