"""Keep each uploaded RX destination independent of the preceding frame."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
import test_wifi_rx_decapsulation as rx


def source() -> str:
    code = rx.dispatch_source()
    old = rx.procedure(code, "hal_machw_search_addr")
    code = code.replace(old, r'''
proc hal_machw_search_addr(p: pointer; unused: uint32): uint32 =
  doAssert unused == 0
  doAssert equalMem(p, addr envState.da[0], 6)
  inc searches
  searchResult
''', 1)
    code = code.replace("proc rxuCntrlEnvView()", "var\n  searches: int\n  searchResult: uint32\n\nproc rxuCntrlEnvView()", 1)
    code += rx.CHECKS.split("proc checkFrame(", 1)[0]
    return code + r'''
proc nextFrame(fc: uint16; vifType: uint8; multicast: bool) =
  let previous = envState
  let headerLength = rxu_cntrl_machdr_len_get(fc)
  setup(fc, headerLength.int, 40)
  envState = previous
  vifs[0].vifType = vifType
  let frame = macDataFrameAt(addr bytes[0])
  if multicast:
    if (fc and 0x100) != 0: frame.addr3[0] = frame.addr3[0] or 1
    else: frame.addr1[0] = frame.addr1[0] or 1
  snapAt(headerLength.int, 0x0800)
  searches = 0
proc checkUpload(destination: uint8; lookupCount: int) =
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
  doAssert prepared == 1 and transferred == 1 and searches == lookupCount
  doAssert envState.dstIdx == destination
  doAssert (sw.frameControlFlags shr 24).uint8 == destination,
    "uploaded destination came from a preceding frame"
  doAssert (sw.frameControlFlags and 0x00FFFF00'u32) == 0
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_unknown_destination_is_initialized(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for stale in [0'u8, 1, 3, 6, 255]:
  for fc in [0x0008'u16, 0x0108, 0x0208, 0x0308, 0x0088, 0x0388]:
    for vifType in [0'u8, 2]:
      for multicast in [false, true]:
        if vifType == 2 and not multicast: continue
        envState.dstIdx = stale
        nextFrame(fc, vifType, multicast)
        searchResult = 4
        checkUpload(255, 0)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ap_unicast_uses_lookup_result(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for destination in [0'u32, 1, 3, 6, 255]:
  for fc in [0x0008'u16, 0x0108, 0x0208, 0x0308, 0x0088, 0x0388]:
    envState.dstIdx = 5
    nextFrame(fc, 2, false)
    searchResult = destination
    checkUpload(destination.uint8, 1)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_destination_does_not_carry_between_frames(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for _ in 0..2:
  nextFrame(0x0108, 2, false)
  searchResult = 4
  checkUpload(4, 1)
  nextFrame(0x0208, 0, false)
  checkUpload(255, 0)
  nextFrame(0x0108, 2, true)
  checkUpload(255, 0)
  nextFrame(0x0108, 2, false)
  searchResult = 255
  checkUpload(255, 1)
  nextFrame(0x0388, 2, false)
  searchResult = 1
  checkUpload(1, 1)
''')
