"""Check channel-switch parser fields and return ABI against the vendor flow."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
var calls: seq[tuple[band, channel: uint8]]
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
proc totalLen(ie: ptr MacIeView): uint = ie.len.uint + 2
template macIePayload(ie: ptr MacIeView): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](ie) + 2)
proc phy_channel_to_freq(band, channel: uint8): uint16 =
  calls.add((band, channel))
  if band == 0 and channel in 1'u8 .. 14'u8:
    if channel == 14: 2484'u16 else: 2407'u16 + channel.uint16 * 5
  elif band == 1 and channel in 1'u8 .. 165'u8:
    5000'u16 + channel.uint16 * 5
  else: 0xFFFF'u16
proc malloc(n: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc packed(band, width: uint8; primary, center1, center2: uint16): array[8, uint8] =
  [band, width, (primary and 255).uint8, (primary shr 8).uint8,
   (center1 and 255).uint8, (center1 shr 8).uint8,
   (center2 and 255).uint8, (center2 shr 8).uint8]
"""

FIELDS = r"""
proc check(ies: openArray[uint8]; expectedMode: uint8;
           expected: array[8, uint8]; expectedCalls: openArray[tuple[band, channel: uint8]]) =
  let input = malloc(max(1, ies.len).csize_t)
  doAssert input != nil
  defer: free(input)
  if ies.len != 0: copyMem(input, unsafeAddr ies[0], ies.len)
  var output: array[24, uint8]
  for value in output.mitems: value = 0xA5
  var mode = 0xCC'u8
  calls.setLen(0)
  me_extract_csa(input, ies.len.uint32, addr mode, addr output[8])
  doAssert mode == expectedMode, "third argument must receive the switch mode"
  doAssert output[8..15] == expected, "incorrect channel-switch output fields"
  doAssert calls == @expectedCalls
  for i in 0 ..< 8: doAssert output[i] == 0xA5
  for i in 16 ..< 24: doAssert output[i] == 0xA5

check([37'u8, 3, 1, 6, 4], 1, packed(0, 0, 2437, 2437, 0), [(0'u8, 6'u8)])
check([37'u8, 3, 255, 6, 4], 255, packed(0, 0, 2437, 2437, 0), [(0'u8, 6'u8)])
check([60'u8, 4, 3, 128, 6, 1], 3, packed(0, 0, 2437, 2437, 0), [(0'u8, 6'u8)])
check([60'u8, 4, 0, 81, 36, 0], 0, packed(1, 0, 5180, 5180, 0), [(1'u8, 36'u8)])
check([37'u8, 3, 1, 14, 1, 60, 4, 0, 115, 36, 8], 1,
      packed(0, 0, 2484, 2484, 0), [(0'u8, 14'u8)])
check([37'u8, 3, 0, 36, 4, 62, 1, 1], 0,
      packed(1, 1, 5180, 5190, 0), [(1'u8, 36'u8)])
check([37'u8, 3, 0, 36, 4, 62, 1, 3], 0,
      packed(1, 1, 5180, 5170, 0), [(1'u8, 36'u8)])
for offset in [0'u8, 2, 255]:
  check([37'u8, 3, 0, 6, 4, 62, 1, offset], 0,
        packed(0, 0, 2437, 2437, 0), [(0'u8, 6'u8)])
for width in 0'u8 .. 4'u8:
  let encodedWidth = if width in 1'u8 .. 3'u8: width + 1 else: 1'u8
  check([37'u8, 3, 1, 36, 4, 196, 5, 194, 3, width, 42, 58], 1,
        packed(1, encodedWidth, 5180, 5210, 5290),
        [(1'u8, 36'u8), (1'u8, 42'u8), (1'u8, 58'u8)])
# Wide bandwidth takes precedence over the separate secondary-offset IE.
check([37'u8, 3, 1, 36, 4, 62, 1, 3, 196, 5, 194, 3, 1, 42, 0], 1,
      packed(1, 2, 5180, 5210, 0), [(1'u8, 36'u8), (1'u8, 42'u8)])
"""

CONTRACT = r"""
let parse: proc(data: pointer; length: uint32; mode, output: pointer): uint8 {.cdecl.} = me_extract_csa
var input = [37'u8, 3, 1, 6, 0]
var mode = 0xCC'u8
var output: array[8, uint8]
for count in [0'u8, 1, 4, 255]:
  input[4] = count
  doAssert parse(addr input[0], input.len.uint32, addr mode, addr output[0]) ==
    (if count == 0: 2'u8 else: count)
  doAssert mode == 1
for bytes in [newSeq[uint8](), @[1'u8, 1, 2], @[37'u8, 2, 1, 6],
              @[60'u8, 3, 0, 81, 36], @[37'u8, 3, 1, 6],
              @[37'u8, 3, 1, 6, 4, 62, 0],
              @[37'u8, 3, 1, 36, 4, 196, 4, 194, 2, 1, 42]]:
  let data = malloc(max(1, bytes.len).csize_t)
  doAssert data != nil
  if bytes.len != 0: copyMem(data, unsafeAddr bytes[0], bytes.len)
  for value in output.mitems: value = 0xA5
  mode = 0xCC
  calls.setLen(0)
  doAssert parse(data, bytes.len.uint32, addr mode, addr output[0]) == 0
  doAssert mode == 0xCC and calls.len == 0
  for value in output: doAssert value == 0xA5
  free(data)
calls.setLen(0)
doAssert parse(nil, 5, addr mode, addr output[0]) == 0
doAssert parse(addr input[0], 5, nil, addr output[0]) == 0
doAssert parse(addr input[0], 5, addr mode, nil) == 0
doAssert calls.len == 0
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", ["fields", "contract"])
def test_csa_extraction(tmp_path: Path, mode: str, case: str) -> None:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["MacIeView", "CsaIeView", "ExtendedCsaIeView", "SecondaryChannelOffsetIeView",
                 "WideBandwidthChannelSwitchIeView", "CsaOutputView"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    functions = procedure((FW / "mac_config_debug.nim").read_text(), "mac_ie_find")
    functions += procedure((FW / "scan_station_ap_me.nim").read_text(), "me_extract_csa")
    run_program(tmp_path, mode, types + PLATFORM + functions + (FIELDS if case == "fields" else CONTRACT))
