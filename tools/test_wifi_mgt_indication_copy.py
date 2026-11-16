"""Copy management indications from DMA chains without their security headers."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_mgt_receive import management_source


MODES = ["checked", "release", "asan", "firmware"]


def source(scattered: bool = False) -> str:
    code = management_source()
    code = code.replace(procedure(code, "ke_msg_free_payload"), r'''
proc ke_msg_free_payload(p: pointer) =
  doAssert p == addr message[0]
  inc copyFrees
''', 1)
    if scattered:
        code = code.replace("message: array[256, uint8]", "message: array[4096, uint8]", 1)
        code = code.replace(procedure(code, "rxFrameBufferChainAt"), r'''
proc rxFrameBufferChainAt(p: pointer): ptr MgtFixtureBuffer = cast[ptr MgtFixtureBuffer](p)
''', 1)
        code = code.replace(procedure(code, "rxFrameAtRef"), r'''
proc rxFrameAtRef(p: pointer): ptr Frame =
  let chain = rxFrameBufferChainAt(p)
  if chain == nil: nil else: cast[ptr Frame](chain.frameData)
''', 1)
        # The chain type and accessor must precede the frame accessor above.
        declaration = procedure(code, "rxFrameAtRef")
        code = code.replace(declaration, "proc rxFrameAtRef(p: pointer): ptr Frame\n", 1)
        code += declaration
    return "var copyFrees: int\n" + code + r'''
proc prepareCopy(fc: uint16; kind: uint8; security, payload: int) =
  reset(fc, 0, 4, kind)
  copyFrees = 0
  env.machdrLen = (rxMacHeaderLen(fc).int + security).uint8
  rx.mpduLengthBytes = (env.machdrLen.int + payload).uint16
  for i in 0 ..< security: frame.body[i] = (0xD0 + i).uint8
  for i in 0 ..< payload: frame.body[security + i] = ((i * 17 + 3) and 255).uint8
  if (fc and 0x00FC'u16) == 0x00D0: frame.body[security] = 3
  if (fc and 0x00FC'u16) in [0x00A0'u16, 0x00C0]:
    frame.body[security] = 0x34
    frame.body[security + 1] = 0x12
  mm.rxPromiscUploadFlag = 0
  mm.apPromiscUploadFlag = 0
'''


@pytest.mark.parametrize("mode", MODES)
def test_whole_protected_indication_omits_security_header(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for sample in [(0'u8, 0x40A0'u16, 8), (0'u8, 0x40C0'u16, 8),
                 (2'u8, 0x40A0'u16, 8), (2'u8, 0x40C0'u16, 8),
                 (2'u8, 0x40B0'u16, 4)]:
    let (kind, fc, security) = sample
    for length in [2, 6, 12, 31, 64]:
      if fc == 0x40B0'u16 and length < 6: continue
      prepareCopy(fc, kind, security, length)
      interrupts = enabled
      let before = frame
      doAssert rxu_mgt_frame_check(addr desc, 4) == 0
      let ind = rxuMgtIndMsgAt(addr message[0])
      doAssert sent == 1 and copyFrees == 0 and ind.frameLen == (24 + length).uint16,
        "whole management indication still counts its security header"
      doAssert equalMem(addr message[32], addr before, 24)
      doAssert equalMem(addr message[56], unsafeAddr before.body[security], length),
        "management reason/body was replaced by IV bytes"
      doAssert ind.frameCtrl == fc and frame == before and interrupts == enabled
      if (fc and 0xFC'u16) in [0xA0'u16, 0xC0]:
        doAssert cast[ptr uint16](addr message[56])[] == 0x1234
''')


CHAIN_SUPPORT = r'''
var
  buffers: array[3, array[1744, uint8]]
  chains: array[2, MgtFixtureBuffer]
  expected: seq[uint8]
proc wireByte(offset: int): ptr uint8 =
  doAssert offset >= 0 and offset < 3472
  if offset < 1736: addr buffers[0][offset]
  else: addr buffers[2][offset - 1736]
proc loadChain(fc: uint16; kind: uint8; security, total: int) =
  prepareCopy(fc, kind, security, 12)
  for buffer in buffers.mitems:
    for value in buffer.mitems: value = 0xCD
  let prefix = rxMacHeaderLen(fc).int
  for i in 0 ..< prefix: wireByte(i)[] = cast[ptr UncheckedArray[uint8]](addr frame)[i]
  for i in prefix ..< prefix + security: wireByte(i)[] = (0xD0 + i - prefix).uint8
  for i in prefix + security ..< total: wireByte(i)[] = ((i * 31 + 7) and 255).uint8
  if (fc and 0xFC'u16) == 0xD0: wireByte(prefix + security)[] = 3
  chains[1] = MgtFixtureBuffer(frameData: addr buffers[2][0])
  chains[0] = MgtFixtureBuffer(frameData: addr buffers[0][0], next: addr chains[1])
  rx.bufferChain = addr chains[0]
  rx.mpduLengthBytes = total.uint16
  expected.setLen(0)
  let bodyOnly = kind == 0 and (fc and 0xFC'u16) in [0x10'u16, 0x30, 0xB0, 0xD0]
  if not bodyOnly:
    for i in 0 ..< prefix: expected.add(wireByte(i)[])
  for i in prefix + security ..< total: expected.add(wireByte(i)[])
'''


@pytest.mark.parametrize("mode", MODES)
def test_indication_copy_follows_dma_segments(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(True) + CHAIN_SUPPORT + r'''
for enabled in [false, true]:
  for sample in [(0'u8, 0x0050'u16, 0), (0'u8, 0x0080'u16, 0),
                 (0'u8, 0x0010'u16, 0), (0'u8, 0x00B0'u16, 0),
                 (0'u8, 0x40D0'u16, 8), (2'u8, 0x00B0'u16, 0)]:
    let (kind, fc, security) = sample
    for length in [1735, 1736, 1737, 1759, 1760, 2328]:
      loadChain(fc, kind, security, length)
      interrupts = enabled
      let before = buffers
      let beforeChains = chains
      doAssert rxu_mgt_frame_check(addr desc, 4) == 0
      doAssert sent == 1 and copyFrees == 0
      let ind = rxuMgtIndMsgAt(addr message[0])
      doAssert ind.frameLen == expected.len.uint16
      for i, value in expected:
        doAssert message[32 + i] == value, "management copy crossed a DMA segment as flat memory"
      doAssert buffers == before and chains == beforeChains and interrupts == enabled
''')


@pytest.mark.parametrize("mode", MODES)
def test_failed_chain_copy_keeps_indication_private(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(True) + CHAIN_SUPPORT + r'''
for enabled in [false, true]:
  for length in [1737, 1800, 2328]:
    loadChain(0x00D0, 0, 0, length)
    chains[0].next = nil
    interrupts = enabled
    let before = buffers
    doAssert rxu_mgt_frame_check(addr desc, 4) == 0
    doAssert sent == 0 and allocationCalls == 1 and copyFrees == 1,
      "partial management copy was published instead of freed"
    doAssert uploads == 0 and buffers == before and interrupts == enabled
''')


@pytest.mark.parametrize("mode", MODES)
def test_plain_single_buffer_copy_keeps_existing_layout(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for sample in [(0'u8, 0x50'u16), (0'u8, 0x80'u16), (0'u8, 0x10'u16),
                 (0'u8, 0xB0'u16), (0'u8, 0xD0'u16), (2'u8, 0xB0'u16)]:
    let (kind, fc) = sample
    for length in [12, 13, 14, 15, 31, 64, 96]:
      prepareCopy(fc, kind, 0, length)
      interrupts = enabled
      let before = frame
      doAssert rxu_mgt_frame_check(addr desc, 4) == 0
      let bodyOnly = kind == 0 and fc in [0x10'u16, 0xB0, 0xD0]
      let copied = if bodyOnly: length else: length + 24
      let start = if bodyOnly: cast[pointer](unsafeAddr before.body[0]) else: unsafeAddr before
      doAssert sent == 1 and rxuMgtIndMsgAt(addr message[0]).frameLen == copied.uint16
      doAssert equalMem(addr message[32], start, copied) and copyFrees == 0
      doAssert frame == before and interrupts == enabled
''')
