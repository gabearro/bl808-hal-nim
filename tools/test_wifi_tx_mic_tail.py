"""Match security-tail construction to the real length allocator's decision."""

from pathlib import Path
import re

import pytest

from test_wifi_aes_cmac import procedure
from test_wifi_disconnect_tx import FW
from test_wifi_message_allocation import run_program
from test_wifi_tx_counter_limit import SETUP
from test_wifi_tx_security import program_source


def source() -> str:
    code = r'''
type
  HostTxThdEntryView = object
    magic: uint32
    next: pointer
    payloadStart, payloadEnd: uint
    flags: uint32
  HostTxMicScratchView = object
    magic, initialLeftWord: uint32
    micInputCursor, micInputEnd: pointer
    pendingWord: uint32
    micInputScratch: array[12, uint8]
'''
    platform = program_source()
    platform = platform.replace(
        "  HostTxLinkDescView = object\n",
        "  HostTxLinkDescView = object\n"
        "    headerThd: HostTxThdEntryView\n"
        "    payloadThd: array[4, HostTxThdEntryView]\n"
        "    micScratch: HostTxMicScratchView\n"
        "    macHeader: array[128, uint8]\n",
    ).replace(
        "  HostTxDescView = object\n",
        "  HostTxDescView = object\n"
        "    da, sa: array[6, uint8]\n"
        "    qosExtLen: uint8\n",
    )
    code += platform + SETUP + r'''
var
  scratchProxy: HostTxThdEntryView
  payloads: array[4, array[16, uint8]]
  micCalls: seq[tuple[start: pointer, count: uint32]]
  initialized, finalized: int
proc hostTxLinkMacHdrAddr(p: ptr HostTxLinkDescView): uint =
  cast[uint](addr p.macHeader[0])
proc hostTxThdAt(p: pointer): ptr HostTxThdEntryView =
  # The target overlays 32-bit pointer words in the scratch header. Model that
  # one pointer conversion separately on the 64-bit native test host.
  if p == cast[pointer](addr link.micScratch):
    scratchProxy.next = cast[pointer](link.micScratch.initialLeftWord.uint)
    scratchProxy.payloadStart = cast[uint](link.micScratch.micInputCursor)
    scratchProxy.payloadEnd = cast[uint](link.micScratch.micInputEnd)
    addr scratchProxy
  else:
    cast[ptr HostTxThdEntryView](p)
proc me_mic_init(ctx, material, da, sa: pointer; priority: uint8) =
  inc initialized
  doAssert material == cast[pointer](addr key.keyMaterial[0])
  doAssert da == cast[pointer](addr desc.da[0]) and sa == cast[pointer](addr desc.sa[0])
  doAssert priority == desc.staIdx
  let bytes = cast[ptr UncheckedArray[uint8]](ctx)
  for i in 0..<8: bytes[i] = (0x70 + i).uint8
proc me_mic_calc(ctx, data: pointer; length: uint32) =
  micCalls.add((data, length))
proc me_mic_calc(ctx, data: pointer; length: uint) =
  doAssert length <= high(uint32).uint
  micCalls.add((data, length.uint32))
proc me_mic_end(ctx: pointer) = inc finalized
proc prepare(cipher: uint8; bypass: bool; segments = 2; extension = 8'u8) =
  setup(cipher, 41, true)
  desc.frameLen = 0x8E88
  desc.staIdx = 3
  desc.qosExtLen = extension
  if bypass:
    vifs[1].flags = 2
    stations[3].rateWord = 0x888E
  let reserved = txu_cntrl_sechdr_len_compute(addr desc, addr tail)
  doAssert reserved != high(uint32)
  desc.secTailLen = tail.uint8
  desc.hdrLen = 26 + reserved.uint8 + extension
  initialized = 0
  finalized = 0
  micCalls.setLen(0)
  for value in link.micScratch.micInputScratch.mitems: value = 0xA5
  scratchProxy = HostTxThdEntryView(payloadStart: cast[uint](addr link.micScratch.micInputScratch[0]))
  for i in 0..<segments:
    link.payloadThd[i] = HostTxThdEntryView(payloadStart: cast[uint](addr payloads[i][0]),
      payloadEnd: cast[uint](addr payloads[i][0]) + (3 + i).uint)
    if i + 1 < segments: link.payloadThd[i].next = addr link.payloadThd[i + 1]
  if segments != 0: link.headerThd.next = addr link.payloadThd[0]
'''
    routine = procedure((FW / "tx_upper.nim").read_text(), "txu_cntrl_tkip_mic_append")
    routine = "\n".join(
        '    doAssert false, "MIC chain did not reach its tail"'
        if "lw a5, 8(zero)" in line else line for line in routine.splitlines()
    ) + "\n"
    return code + routine


CASES = {
    "control_port": r'''
for cipher in [0'u8, 1, 3]:
  prepare(cipher, true)
  doAssert desc.secTailLen == 0 and counter() == 41
  let before = link
  let chain = link.payloadThd
  let beforeDesc = desc
  txu_cntrl_tkip_mic_append(addr desc)
  doAssert link == before and link.payloadThd == chain,
    "control-port bypass gained a security trailer"
  doAssert desc == beforeDesc and counter() == 41
  doAssert initialized == 0 and finalized == 0 and micCalls.len == 0
''',
    "protected_tkip": r'''
for segments in 0..4:
  for extension in [0'u8, 8]:
    prepare(1, false, segments, extension)
    doAssert desc.secTailLen == 12
    txu_cntrl_tkip_mic_append(addr desc)
    doAssert initialized == 1 and finalized == 1
    doAssert micCalls.len == segments + 1
    doAssert micCalls[0] == (cast[pointer](addr link.macHeader[desc.hdrLen - extension]), extension.uint32)
    for i in 0..<segments:
      doAssert micCalls[i + 1] == (cast[pointer](addr payloads[i][0]), (4 + i).uint32)
    let last = if segments == 0: addr link.headerThd else: addr link.payloadThd[segments - 1]
    doAssert last.next == cast[pointer](addr link.micScratch)
    doAssert link.micScratch.magic == 0xCAFEFADE'u32
    doAssert link.micScratch.initialLeftWord == 0 and link.micScratch.pendingWord == 0
    doAssert link.micScratch.micInputCursor == cast[pointer](addr link.micScratch.micInputScratch[0])
    doAssert link.micScratch.micInputEnd == cast[pointer](addr link.micScratch.micInputScratch[11])
    for i in 0..<12:
      doAssert link.micScratch.micInputScratch[i] == (if i < 8: (0x70 + i).uint8 else: 0xA5'u8)
''',
    "protected_wep": r'''
for cipher in [0'u8, 3]:
  prepare(cipher, false)
  doAssert desc.secTailLen == 4
  txu_cntrl_tkip_mic_append(addr desc)
  doAssert link.payloadThd[1].next == cast[pointer](addr link.micScratch)
  doAssert link.micScratch.micInputEnd == cast[pointer](addr link.micScratch.micInputScratch[3])
  doAssert initialized == 0 and finalized == 0 and micCalls.len == 0
''',
    "ccmp": r'''
prepare(2, false)
doAssert desc.secTailLen == 8
let before = link
txu_cntrl_tkip_mic_append(addr desc)
doAssert link == before and initialized == 0 and finalized == 0
''',
    "repeated_tail": r'''
for cipher in [0'u8, 1, 3]:
  for segments in 0..4:
    prepare(cipher, false, segments)
    txu_cntrl_tkip_mic_append(addr desc)
    let prepared = link
    let beforeCounter = counter()
    for repeat in 1..3:
      txu_cntrl_tkip_mic_append(addr desc)
      doAssert link == prepared and counter() == beforeCounter
      var current = addr link.headerThd
      var count = 0
      while current != nil:
        inc count
        doAssert count <= segments + 2, "repeated trailer construction formed a cycle"
        current = hostTxThdAt(current.next)
      doAssert count == segments + 2
      doAssert link.micScratch.initialLeftWord == 0
    if cipher == 1:
      doAssert initialized == 4 and finalized == 4
      doAssert micCalls.len == 4 * (segments + 1)
    else:
      doAssert initialized == 0 and finalized == 0 and micCalls.len == 0
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_security_tail(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rebuilt_payload_chain_replaces_old_tail(tmp_path: Path, mode: str) -> None:
    code = source().replace(
        "  HostTxDescView = object\n",
        "  HostTxDescView = object\n"
        "    bufferPtrs, bufferLens: array[4, uint32]\n"
        "    seqPassthrough: uint16\n"
        "    hwDesc: pointer\n",
    ).replace(
        "    headerThd: HostTxThdEntryView\n",
        "    headerLen: uint32\n"
        "    headerThd: HostTxThdEntryView\n",
    )
    code += r'''
type Hardware = object
  frameLen, status, controlFlags, retryLimitControl, ackPolicyControl: uint32
  chainedThd: pointer
var hardware: Hardware
proc hostTxHwDescAt(p: pointer): ptr Hardware = cast[ptr Hardware](p)
'''
    builder = procedure((FW / "tx_layer.nim").read_text(), "txlBuildBufferThd")
    names = sorted(set(re.findall(r"\bnimFwDbg\w+", builder)))
    code += "\nvar\n" + "".join(f"  {name}: uint32\n" for name in names)
    code += procedure((FW / "layout_types.nim").read_text(), "txPayloadChainLength")
    code += builder + r'''
for cipher in [0'u8, 1, 3]:
  prepare(cipher, false, 0)
  desc.hwDesc = addr hardware
  link.headerLen = desc.hdrLen.uint32
  for segments in 1..4:
    desc.bufferPtrs = default(typeof(desc.bufferPtrs))
    desc.bufferLens = default(typeof(desc.bufferLens))
    var total = 0'u32
    for i in 0..<segments:
      desc.bufferPtrs[i] = 0x20000000'u32 + i.uint32 * 0x100
      desc.bufferLens[i] = (i + 4).uint32
      total += desc.bufferLens[i]
    desc.seqPassthrough = total.uint16
    doAssert txlBuildBufferThd(addr desc)
    doAssert link.payloadThd[segments - 1].next == nil
    initialized = 0
    finalized = 0
    micCalls.setLen(0)
    txu_cntrl_tkip_mic_append(addr desc)
    doAssert link.payloadThd[segments - 1].next == cast[pointer](addr link.micScratch)
    var current = addr link.headerThd
    var count = 0
    while current != nil:
      inc count
      doAssert count <= segments + 2, "rebuilt trailer chain contains a cycle"
      current = hostTxThdAt(current.next)
    doAssert count == segments + 2
    if cipher == 1:
      doAssert initialized == 1 and finalized == 1 and micCalls.len == segments + 1
      for i in 0..<segments:
        doAssert micCalls[i + 1] == (cast[pointer](desc.bufferPtrs[i].uint), desc.bufferLens[i])
    else:
      doAssert initialized == 0 and finalized == 0 and micCalls.len == 0
'''
    run_program(tmp_path, mode, code)
