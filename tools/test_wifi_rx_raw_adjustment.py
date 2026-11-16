"""Check nonzero header relocation through the real raw-upload helper."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rx_raw import source


CHECKS = r'''
for fc in [0x0080'u16, 0x80B0, 0x0008, 0x0088, 0x0388, 0x8388]:
  let headerLength = rxu_cntrl_machdr_len_get(fc).int
  for prefix in [0, 4, 8, 12]:
    for enabled in [false, true]:
      for station in [0'u8, 4, 255]:
        reset(fc, headerLength + prefix + 16)
        for index in 2..<bytes.len: bytes[index] = (index * 37 and 255).uint8
        let original = bytes
        var expected = bytes
        for index in 0..<headerLength: expected[prefix + index] = original[index]
        let buffer = alloc(bytes.len)
        defer: dealloc(buffer)
        copyMem(buffer, addr bytes[0], bytes.len)
        chain.frameData = buffer
        let previousChain = chain
        envState.machdrLen = (headerLength + prefix).uint8
        envState.stripLen = 199
        envState.staIdx = station
        envState.vifIdx = 1
        sw.frameControlFlags = 0x12000004'u32
        sw.bufferOffset = 71
        interrupts = enabled
        rxu_mpdu_upload_and_indicate(addr mpdu)
        doAssert cmpMem(buffer, addr expected[0], expected.len) == 0
        doAssert chain == previousChain, "header movement must not rebase the DMA descriptor"
        doAssert sw.mpduLengthBytes == (headerLength + 16).uint16
        doAssert sw.bufferOffset == 0
        doAssert envState.machdrLen == headerLength.uint8
        doAssert envState.stripLen == prefix.uint8
        doAssert sw.frameControlFlags == (0x12000106'u32 or (station.uint32 shl 16))
        doAssert transferred == 1 and prepared == 1
        doAssert envState.uploadList.first == cast[pointer](addr mpdu)
        doAssert interrupts == enabled
for fc in [0x0008'u16, 0x0088, 0x0388]:
  let headerLength = rxu_cntrl_machdr_len_get(fc).int
  for envLength in [headerLength - 2, headerLength + 8]:
    reset(fc, headerLength + 4)
    let before = bytes
    let flags = 0x12000004'u32
    envState.machdrLen = envLength.uint8
    envState.stripLen = 199
    sw.frameControlFlags = flags
    sw.bufferOffset = 71
    rxu_mpdu_upload_and_indicate(addr mpdu)
    doAssert bytes == before and sw.mpduLengthBytes == (headerLength + 4).uint16
    doAssert sw.frameControlFlags == flags and sw.bufferOffset == 71
    doAssert envState.machdrLen == envLength.uint8 and envState.stripLen == 199
    doAssert transferred == 0 and prepared == 0 and envState.uploadList.first == nil
  reset(fc, headerLength + 4)
  envState.machdrLen = headerLength.uint8
  chain.frameData = nil
  rxu_mpdu_upload_and_indicate(addr mpdu)
  doAssert transferred == 0 and prepared == 0 and sw.frameControlFlags == 0
  reset(fc, headerLength + 4)
  envState.machdrLen = (headerLength + 1).uint8
  envState.stripLen = 199
  let before = bytes
  var warned = false
  try:
    rxu_mpdu_upload_and_indicate(addr mpdu)
  except AssertionDefect:
    warned = true
  doAssert warned and bytes == before
  doAssert sw.frameControlFlags == 0 and sw.mpduLengthBytes == (headerLength + 4).uint16
  doAssert envState.stripLen == 199 and transferred == 0 and prepared == 0
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_raw_upload_header_adjustment(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_upload=True) + CHECKS)
