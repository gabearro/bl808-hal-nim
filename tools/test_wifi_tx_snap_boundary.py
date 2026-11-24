"""Keep TX header reservation consistent with its SNAP encoding boundary."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_tx_sequence import CHECKS, program_source


def source(unchecked: bool) -> str:
    code = program_source()
    if unchecked:
        for name in ["txu_cntrl_push", "txuBuildFrame", "txu_cntrl_frame_build"]:
            body = procedure(code, name)
            code = code.replace(body, "{.push checks:off.}\n" + body + "\n{.pop.}\n", 1)
    checks = CHECKS.split("\nreset()\n", 1)[0]
    assert "let snapLength = if etherType >= 1536: 8 else: 0" in checks
    return code + checks


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("unchecked", [False, True], ids=["bounds", "unchecked"])
def test_tx_snap_boundary(tmp_path: Path, mode: str, unchecked: bool) -> None:
    checks = r'''
for etherType in [0'u16, 1500, 1535, 1536, 1537, 0x0800, 0xFFFF]:
  for tid in [0'u8, 7, 0xFF]:
    for vifIndex in [0'u8, 1]:
      for securityLength in [0'u32, 4, 8]:
        for enabled in [false, true]:
          reset()
          interrupts = enabled
          securityHeaderLen = securityLength
          securityTailLen = securityLength
          pushResult = 1
          checkTx(0, tid, vifIndex, etherType)
          doAssert interrupts == enabled
'''
    run_program(tmp_path, mode, source(unchecked) + checks)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_frame_build_rejects_invalid_header_reservation(tmp_path: Path, mode: str) -> None:
    checks = r'''
reset()
var buffer: array[192, uint8]
for tid in [0'u8, 0xFF'u8]:
  for etherType in [1500'u16, 1536'u16, 0x0800'u16]:
    let macLen = if tid == 0xFF: 24 else: 26
    let snapLen = if etherType >= 1536: 8 else: 0
    let required = macLen + snapLen
    var desc = HostTxDescView(staInfoIdx: 0, staIdx: tid, vifIdx: 0,
      frameLen: lmacGateHalfword(etherType), hdrLen: required.uint8,
      qosExtLen: snapLen.uint8)
    for reserved in [0, required - 1, required + 1, required + 3,
                     required + 5, required + 9, 255]:
      desc.hdrLen = reserved.uint8
      for value in buffer.mitems: value = 0xC7
      let before = buffer
      doAssert not txuBuildFrame(addr desc, addr buffer[128])
      doAssert buffer == before, "invalid reservation wrote outside header"
    for security in [0, 4, 8]:
      securityHeaderLen = security.uint32
      securityTailLen = security.uint32
      desc.hdrLen = (required + security).uint8
      desc.secTailLen = security.uint8
      desc.qosExtLen = snapLen.uint8
      for value in buffer.mitems: value = 0xC7
      doAssert txuBuildFrame(addr desc, addr buffer[128])
      for i in 0 ..< 128 - desc.hdrLen.int:
        doAssert buffer[i] == 0xC7
      for i in 128 ..< buffer.len:
        doAssert buffer[i] == 0xC7
      for wrongSecurity in [0, 4, 8]:
        if wrongSecurity == security: continue
        desc.hdrLen = (required + wrongSecurity).uint8
        for value in buffer.mitems: value = 0xC7
        let before = buffer
        doAssert not txuBuildFrame(addr desc, addr buffer[128])
        doAssert buffer == before, "mismatched security reservation wrote a partial header"
      desc.hdrLen = (required + security).uint8
      for wrongTail in [0, 4, 8, 12, 255]:
        if wrongTail == security: continue
        desc.secTailLen = wrongTail.uint8
        for value in buffer.mitems: value = 0xC7
        let before = buffer
        doAssert not txuBuildFrame(addr desc, addr buffer[128])
        doAssert buffer == before, "mismatched security tail wrote a partial header"
      desc.secTailLen = security.uint8
      for wrongSnap in [0, 8, 16, 255]:
        if wrongSnap == snapLen: continue
        desc.qosExtLen = wrongSnap.uint8
        for value in buffer.mitems: value = 0xC7
        let before = buffer
        doAssert not txuBuildFrame(addr desc, addr buffer[128])
        doAssert buffer == before, "mismatched SNAP extension wrote a partial header"
      desc.qosExtLen = snapLen.uint8
      if security == 8:
        securityTailLen = 12
        desc.secTailLen = 12
        doAssert txuBuildFrame(addr desc, addr buffer[128]), "TKIP tail was rejected"
securityHeaderLen = 0
doAssert not txuBuildFrame(nil, addr buffer[128])
var nullBufferDesc = HostTxDescView(staInfoIdx: 0, staIdx: 0xFF, vifIdx: 0,
  frameLen: lmacGateHalfword(1536'u16), hdrLen: 32)
doAssert not txuBuildFrame(addr nullBufferDesc, nil)
for invalidVif in [MAX_VIFS.uint8, 0xFF'u8]:
  nullBufferDesc.vifIdx = invalidVif
  for value in buffer.mitems: value = 0xC7
  let before = buffer
  doAssert not txuBuildFrame(addr nullBufferDesc, addr buffer[128])
  doAssert buffer == before, "invalid VIF wrote a partial header"
'''
    run_program(tmp_path, mode, source(mode == "release") + checks)
