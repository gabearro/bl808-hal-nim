"""Exercise the decoded me_utils.o rate and capability helper contracts."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


HELPERS = (
    "me_rate_translate",
    "me_legacy_rate_bitfield_build",
    "me_legacy_ridx_min",
    "me_legacy_ridx_max",
    "me_11n_nss_max",
    "me_11ac_nss_max",
    "me_11ac_mcs_max",
    "me_rate_bitfield_vht_build",
)


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_me_rate_helpers_match_decoded_branches(tmp_path: Path, mode: str) -> None:
    source = (FW / "scan_station_ap_me.nim").read_text()
    code = r'''
type
  RateSetView {.packed.} = object
    count: uint8
    rates: UncheckedArray[uint8]
  HtMcsNssPrefixView {.packed.} = object
    nss0, nss1, nss2, nss3: uint8
template rateSetAt(p: pointer): ptr RateSetView = cast[ptr RateSetView](p)
template htMcsNssPrefixView(p: pointer): ptr HtMcsNssPrefixView =
  cast[ptr HtMcsNssPrefixView](p)
var warnings: int
proc assert_warn(a, b: cstring; line: cint) =
  doAssert line == 411
  inc warnings
'''
    for name in HELPERS:
        code += procedure(source, name)
    run_program(tmp_path, mode, code + r'''
let rates = [2'u8, 4, 11, 22, 12, 18, 24, 36, 48, 72, 96, 108]
for raw in 0'u32 .. 255'u32:
  var expected = 255'u32
  for index, rate in rates:
    if (raw and 0x7F) == rate.uint32:
      expected = index.uint32
  doAssert me_rate_translate(raw) == expected

var rateSet: array[13, uint8]
rateSet[0] = 12
for index, rate in rates: rateSet[index + 1] = rate or 0x80
doAssert me_legacy_rate_bitfield_build(addr rateSet[0], 0) == 0xFFF
doAssert me_legacy_rate_bitfield_build(addr rateSet[0], 1) == 0xFFF
for index in 0 ..< 12:
  if (index and 1) != 0: rateSet[index + 1] = rates[index]
doAssert me_legacy_rate_bitfield_build(addr rateSet[0], 1) == 0x555
rateSet[12] = 0xFF
warnings = 0
doAssert me_legacy_rate_bitfield_build(addr rateSet[0], 0) == 0x7FF
doAssert warnings == 1
warnings = 0
doAssert me_legacy_rate_bitfield_build(addr rateSet[0], 1) == 0x555
doAssert warnings == 1

for raw in 0'u32 .. 65535'u32:
  var expectedMin = 12'u8
  var expectedMax = if raw == 0: 12'u8 else: 255'u8
  for index in 0 .. 11:
    if (raw and (1'u32 shl index)) != 0:
      if expectedMin == 12: expectedMin = index.uint8
      expectedMax = index.uint8
  doAssert me_legacy_ridx_min(raw) == expectedMin
  doAssert me_legacy_ridx_max(raw) == expectedMax

let htCases = [
  [0'u8, 0, 0, 0], [1'u8, 0, 0, 0], [0'u8, 1, 0, 0],
  [0'u8, 0, 1, 0], [0'u8, 0, 0, 1], [1'u8, 1, 1, 1]
]
for mcs in htCases:
  var expected = 0'u8
  for index in 1 .. 3:
    if mcs[index] != 0: expected = index.uint8
  doAssert me_11n_nss_max(unsafeAddr mcs[0]) == expected

for raw in 0'u32 .. 65535'u32:
  var expectedNss = 0'u8
  for index in 1 .. 7:
    if ((raw shr (index * 2)) and 3) != 3:
      expectedNss = index.uint8
  let expectedMcs =
    case raw and 3
    of 1: 8'u8
    of 2: 9'u8
    else: 7'u8
  doAssert me_11ac_nss_max(cast[pointer](raw.uint)) == expectedNss
  doAssert me_11ac_mcs_max(cast[pointer](raw.uint)) == expectedMcs

let maps = [0'u32, 0xFFFF'u32, 0xAAAA'u32, 0x5555'u32, 0xFFFC'u32,
            0xFFF3'u32, 0x0000'u32, 0x00FF'u32, 0xFFFF0000'u32,
            0x1234'u32, 0xFEDC'u32]
for rx in maps:
  for tx in maps:
    var expected = 0xFFFF'u32
    for index in 0 .. 7:
      let shift = index * 2
      let rxField = (rx shr shift) and 3
      let txField = (tx shr shift) and 3
      if rxField == 3 or txField == 3: break
      let chosen = if rxField < txField: rxField else: txField
      expected = (expected and not (3'u32 shl shift)) or (chosen shl shift)
    doAssert me_rate_bitfield_vht_build(rx, tx) == expected
''')
