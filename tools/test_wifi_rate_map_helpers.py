"""Exercise actual NSS/MCS decoders and their rate-initialization caller."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rate_init import CASES as RATE_CASES, source as rate_source
from test_wifi_sta_tx_channel import object_type


def ht_source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    scan = (FW / "scan_station_ap_me.nim").read_text()
    return (object_type(layout, "HtMcsNssPrefixView")
            + "template htMcsNssPrefixView(p: pointer): ptr HtMcsNssPrefixView =\n"
              "  cast[ptr HtMcsNssPrefixView](p)\n"
            + procedure(scan, "me_11n_nss_max"))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rate_map_decoders(tmp_path: Path, mode: str) -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = ht_source()
    for name in ["me_11ac_nss_max", "me_11ac_mcs_max"]:
        code += procedure(scan, name)
    code += r'''
var bytes: array[8, uint8]
for offset in 0..3:
  for mask in 0..15:
    for value in [1'u8, 0x80, 0xFF]:
      for i in 0..<4:
        bytes[offset + i] = if (mask and (1 shl i)) != 0: value else: 0
      var expected = 0'u8
      for i in 1..3:
        if (mask and (1 shl i)) != 0: expected = i.uint8
      let before = bytes
      doAssert me_11n_nss_max(addr bytes[offset]) == expected
      doAssert bytes == before
for word in 0'u32..65535:
  var expectedNss = 0'u8
  for i in 1..7:
    if ((word shr (i * 2)) and 3) != 3: expectedNss = i.uint8
  let expectedMcs = case word and 3
                    of 1: 8'u8
                    of 2: 9'u8
                    else: 7'u8
  for upper in [0'u32, 0xFFFF0000'u32, 0xA55A0000'u32]:
    let encodedMap = cast[pointer]((upper or word).uint)
    doAssert me_11ac_nss_max(encodedMap) == expectedNss
    doAssert me_11ac_mcs_max(encodedMap) == expectedMcs
'''
    run_program(tmp_path, mode, code)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rate_init_uses_real_ht_nss(tmp_path: Path, mode: str) -> None:
    code = rate_source()
    stub = procedure(code, "me_11n_nss_max")
    assert code.count(stub) == 1
    code = code.replace(stub, ht_source(), 1)
    code += RATE_CASES.split("proc expectedCount", 1)[0]
    code += r'''
proc checkNss(peerMask, localMask: int; value: uint8) =
  setup(true, 0xFFF, 0, 1, 0x861)
  var peerMax, localMax: uint8
  for i in 0..<4:
    sta.vhtCaps[3 + i] = if (peerMask and (1 shl i)) != 0: value else: 0
    me_env[11 + i] = if (localMask and (1 shl i)) != 0: value else: 0
    if i > 0:
      if sta.vhtCaps[3 + i] != 0: peerMax = i.uint8
      if me_env[11 + i] != 0: localMax = i.uint8
  doAssert rcTryInitStation(addr sta),
    "peer=" & $peerMask & " local=" & $localMask & " value=" & $value &
    " errors=" & $errors
  doAssert errors == 0 and phyCalls == 2
  let caps = rcRateCapabilities(sta.rcStats)
  doAssert caps.maxNss == min(peerMax, localMax)
  doAssert caps.mcsBitmaps[0] == 0xFF
  for i in 1..<4: doAssert caps.mcsBitmaps[i] == sta.vhtCaps[3 + i]
for value in [1'u8, 0x80, 0xFF]:
  for peerStreams in 1..4:
    for localStreams in 1..4:
      checkNss((1 shl peerStreams) - 1, (1 shl localStreams) - 1, value)
  # A one-stream local profile must ignore holes in higher peer NSS groups.
  for peerMask in 0..15: checkNss(peerMask, 1, value)
'''
    run_program(tmp_path, mode, code)
