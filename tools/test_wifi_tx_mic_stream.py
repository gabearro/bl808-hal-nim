"""Run the actual TX tail and Michael routines across fragmented payloads."""

from pathlib import Path
import random
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_michael import VECTORS, michael, nim_bytes, nim_string
from test_wifi_tx_mic_tail import source as tail_source


def source() -> str:
    code = tail_source().replace("payloads: array[4, array[16, uint8]]",
                                 "payloads: array[4, array[2360, uint8]]")
    assert "payloads: array[4, array[2360, uint8]]" in code
    start = code.index("proc me_mic_init(")
    end = code.index("proc prepare(", start)
    core = (FW / "scan_station_ap_me.nim").read_text()
    real = "".join(procedure(core, name) for name in [
        "michael_block", "me_mic_init", "me_mic_calc", "me_mic_end"])
    real = re.sub(r"(?m)^\{\.emit:.*\n", "", real)
    prelude = layouts("MichaelMicContextView") + r'''
template michaelMicContextAt(p: pointer): ptr MichaelMicContextView =
  cast[ptr MichaelMicContextView](p)
proc assert_err(cond, file: cstring; line: cint) =
  raise newException(AssertionDefect, $file & ":" & $line)
'''
    # The native fixture uses pointer-sized THD ranges; target ranges are u32.
    real += r'''
proc me_mic_calc(ctx, data: pointer; length: uint) =
  doAssert length <= high(uint32).uint
  me_mic_calc(ctx, data, length.uint32)
'''
    code = code[:start] + prelude + real + code[end:]
    layout = (FW / "layout_types.nim").read_text()
    code += layouts("LlcSnapHeaderView") + r'''
type TxFrameBuildLayout = object
  snap: ptr LlcSnapHeaderView
'''
    return code + procedure(layout, "txFrameWriteSnap")


CHECKS = r'''
proc checkStream(material: array[8, uint8]; da, sa: array[6, uint8];
                 priority: uint8; protocol: uint16; message: string;
                 answer: array[8, uint8]) =
  let extension = if protocol >= 1536: 8'u8 else: 0'u8
  for alignment in 0 .. 3:
    for split in 0 .. message.len:
      prepare(1, false, 0, extension)
      for value in link.macHeader.mitems: value = 0xA7
      desc.da = da
      desc.sa = sa
      desc.staIdx = priority
      copyMem(addr key.keyMaterial[0], unsafeAddr material[0], 8)
      for bytes in payloads.mitems:
        for value in bytes.mitems: value = 0xCD
      var segments = 0
      for part in 0 .. 1:
        let start = if part == 0: 0 else: split
        let length = if part == 0: split else: message.len - split
        if length == 0: continue
        let begin = cast[uint](addr payloads[segments][alignment])
        for i in 0 ..< length: payloads[segments][alignment + i] = message[start + i].uint8
        link.payloadThd[segments] = HostTxThdEntryView(payloadStart: begin,
          payloadEnd: begin + length.uint - 1)
        if segments != 0: link.payloadThd[segments - 1].next = addr link.payloadThd[segments]
        inc segments
      if segments != 0: link.headerThd.next = addr link.payloadThd[0]
      if extension != 0:
        let snap = cast[ptr LlcSnapHeaderView](addr link.macHeader[desc.hdrLen - extension])
        txFrameWriteSnap(TxFrameBuildLayout(snap: snap), lmacGateHalfword(protocol))
      let beforePayloads = payloads
      let beforeDesc = desc
      let beforeKey = key
      var expected = link
      let scratch = addr link.micScratch
      expected.micScratch.magic = 0xCAFEFADE'u32
      expected.micScratch.initialLeftWord = 0
      expected.micScratch.micInputCursor = addr scratch.micInputScratch[0]
      expected.micScratch.micInputEnd = addr scratch.micInputScratch[11]
      expected.micScratch.pendingWord = 0
      for i in 0 ..< 8: expected.micScratch.micInputScratch[i] = answer[i]
      if segments == 0: expected.headerThd.next = scratch
      else: expected.payloadThd[segments - 1].next = scratch
      for repeat in 0 .. 2:
        txu_cntrl_tkip_mic_append(addr desc)
        doAssert link == expected, "TX Michael bytes or trailer layout differ from the reference"
        doAssert payloads == beforePayloads, "MIC construction changed payload or guards"
        doAssert desc == beforeDesc and key == beforeKey, "MIC construction changed key/descriptor"
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_tx_tail_real_michael_stream(tmp_path: Path, mode: str) -> None:
    for key, message, answer in VECTORS:
        assert michael(bytes.fromhex(key), message) == bytes.fromhex(answer)
    rng = random.Random(0x8084D4943)
    checks = []
    lengths = [0, 1, 2, 3, 4, 7, 8, 31, 63, 1735, 1736, 1737, 2352]
    for index, length in enumerate(lengths):
        material, da, sa = rng.randbytes(8), rng.randbytes(6), rng.randbytes(6)
        message = rng.randbytes(length)
        priority = [0, 3, 7, 255][index % 4]
        protocol = [1500, 0x0800, 0x80F3, 0x8137][index % 4]
        snap = b""
        if protocol >= 1536:
            snap = bytes([0xAA, 0xAA, 3, 0, 0, 0xF8 if protocol in [0x80F3, 0x8137] else 0])
            snap += protocol.to_bytes(2, "big")
        tid = 0 if priority == 255 else priority & 7
        answer = michael(material, da + sa + bytes([tid, 0, 0, 0]) + snap + message)
        checks.append(f"checkStream({nim_bytes(material)}, {nim_bytes(da)}, {nim_bytes(sa)}, "
                      f"{priority}'u8, {protocol}'u16, {nim_string(message)}, {nim_bytes(answer)})")
    run_program(tmp_path, mode, source() + CHECKS + "\n" + "\n".join(checks))


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_michael_zero_length_update(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var material = [1'u8, 2, 3, 4, 5, 6, 7, 8]
var da = [2'u8, 3, 4, 5, 6, 7]
var sa = [4'u8, 5, 6, 7, 8, 9]
var poison: array[16, uint8]
for value in poison.mitems: value = 0xA5
for pending in 0'u32 .. 3'u32:
  for alignment in 0 .. 3:
    for absent in [false, true]:
      var ctx: MichaelMicContextView
      me_mic_init(addr ctx, addr material[0], addr da[0], addr sa[0], 7)
      me_mic_calc(addr ctx, addr poison[0], pending)
      let before = ctx
      let input = if absent: nil else: cast[pointer](addr poison[alignment])
      for repeat in 0 .. 2:
        me_mic_calc(addr ctx, input, 0'u32)
        doAssert ctx == before, "zero-length MIC update changed streaming state"
''')
