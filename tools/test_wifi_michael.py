"""Known-answer and streaming checks for the actual Nim TKIP MIC routines.

The six published vectors are the IEEE 802.11i vectors carried by Linux v6.12:
https://github.com/torvalds/linux/blob/v6.12/crypto/testmgr.h#L34857-L34905
The independent byte-oriented oracle below is checked against those answers
before it supplies frame and streaming cases. No network is needed by tests.
"""

from pathlib import Path
import random
import re
import shutil
import subprocess
import textwrap

import pytest


ROOT = Path(__file__).resolve().parents[1]
VECTORS = [
    ("0000000000000000", b"", "82925c1ca1d130b8"),
    ("82925c1ca1d130b8", b"M", "434721ca40639b3f"),
    ("434721ca40639b3f", b"Mi", "e8f9becae97e5d29"),
    ("e8f9becae97e5d29", b"Mic", "90038fc6cf13c1db"),
    ("90038fc6cf13c1db", b"Mich", "d55e100510128986"),
    ("d55e100510128986", b"Michael", "0a942b124ecaa546"),
]


def michael(key: bytes, message: bytes) -> bytes:
    mask = 0xFFFFFFFF
    left = int.from_bytes(key[:4], "little")
    right = int.from_bytes(key[4:], "little")
    padded = message + b"\x5a"
    padded += bytes((-len(padded)) % 4 + 4)
    for offset in range(0, len(padded), 4):
        left ^= int.from_bytes(padded[offset:offset + 4], "little")
        for mix in (
            lambda x: ((x << 17) | (x >> 15)) & mask,
            lambda x: ((x & 0xFF00FF) << 8) | ((x >> 8) & 0xFF00FF),
            lambda x: ((x << 3) | (x >> 29)) & mask,
            lambda x: ((x >> 2) | (x << 30)) & mask,
        ):
            right ^= mix(left)
            left = (left + right) & mask
    return left.to_bytes(4, "little") + right.to_bytes(4, "little")


def nim_bytes(data: bytes) -> str:
    return "[" + ", ".join(f"{value}'u8" for value in data) + "]"


def nim_string(data: bytes) -> str:
    return '"' + "".join(f"\\x{value:02x}" for value in data) + '"'


PRELUDE = r"""
template michaelMicContextAt(p: pointer): ptr MichaelMicContextView =
  cast[ptr MichaelMicContextView](p)
proc assert_err(file, message: cstring; line: cint) =
  raise newException(AssertionDefect, $file & ":" & $line)
proc c_memset(dst: pointer; value: cint; size: csize_t): pointer =
  doAssert value == 0
  zeroMem(dst, size.int)
  dst
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
var hsuMichaelCtx: array[16, uint8]
"""

CHECKS = r"""
proc resultBytes(ctx: var MichaelMicContextView): array[8, uint8] =
  copyMem(addr result[0], addr ctx, 8)

proc checkRaw(key: array[8, uint8]; message: string; expected: array[8, uint8]) =
  # Vary physical alignment independently of the number of pending MIC bytes.
  for alignment in 0 .. 3:
    var data = newSeq[uint8](message.len + 4)
    for i in 0 ..< message.len:
      data[i + alignment] = message[i].uint8
    let start = cast[uint](addr data[alignment])
    for split in 0 .. message.len:
      hsu_michael_init(unsafeAddr key[0])
      hsu_michael_calc(cast[pointer](start), split.uint32)
      hsu_michael_calc(cast[pointer](start + split.uint),
                       (message.len - split).uint32)
      var actual: array[8, uint8]
      hsu_michael_end(addr actual[0])
      doAssert actual == expected, "MIC split=" & $split & " alignment=" & $alignment
    # Repeated short segments exercise all pending-word fill paths.
    for chunkSize in [1, 2, 3, 4, 7, 16, 1736]:
      hsu_michael_init(unsafeAddr key[0])
      var pos = 0
      while pos < message.len:
        let count = min(chunkSize, message.len - pos)
        hsu_michael_calc(cast[pointer](start + pos.uint), count.uint32)
        pos += count
      var actual: array[8, uint8]
      hsu_michael_end(addr actual[0])
      doAssert actual == expected, "MIC chunk=" & $chunkSize

proc checkFrame(key: array[8, uint8]; da, sa: array[6, uint8]; priority: uint8;
                message: string; expected: array[8, uint8]) =
  var ctx: MichaelMicContextView
  me_mic_init(addr ctx, unsafeAddr key[0], unsafeAddr da[0], unsafeAddr sa[0], priority)
  if message.len != 0:
    me_mic_calc(addr ctx, unsafeAddr message[0], message.len.uint32)
  me_mic_end(addr ctx)
  doAssert resultBytes(ctx) == expected, "MIC pseudo-header order"
  doAssert rxFrameMic(key, da, sa, priority, message) == expected,
    "RX MIC pseudo-header order"
"""


def test_wifi_michael_vectors_and_streaming(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")

    cases = []
    for key_hex, message, answer_hex in VECTORS:
        key, answer = bytes.fromhex(key_hex), bytes.fromhex(answer_hex)
        assert michael(key, message) == answer
        cases.append(f"checkRaw({nim_bytes(key)}, {nim_string(message)}, {nim_bytes(answer)})")

    rng = random.Random(0x808)
    for length in [0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 31, 32, 63, 255, 1735, 1736, 1737]:
        key = rng.randbytes(8)
        message = rng.randbytes(length)
        answer = michael(key, message)
        cases.append(f"checkRaw({nim_bytes(key)}, {nim_string(message)}, {nim_bytes(answer)})")

    for priority in [0, 1, 3, 7, 255]:
        key = rng.randbytes(8)
        da, sa = rng.randbytes(6), rng.randbytes(6)
        message = rng.randbytes(37)
        tid = 0 if priority == 255 else priority & 7
        answer = michael(key, da + sa + bytes([tid, 0, 0, 0]) + message)
        cases.append(
            f"checkFrame({nim_bytes(key)}, {nim_bytes(da)}, {nim_bytes(sa)}, "
            f"{priority}'u8, {nim_string(message)}, {nim_bytes(answer)})"
        )

    firmware = (ROOT / "src/bl808/wifi/fw/scan_station_ap_me.nim").read_text()
    layouts = (ROOT / "src/bl808/wifi/fw/layout_types.nim").read_text()
    context = "  MichaelMicContextView" + layouts.split("  MichaelMicContextView", 1)[1].split(
        "  StaInfoView", 1
    )[0]
    mic_functions = "proc michael_block*" + firmware.split("proc michael_block*", 1)[1]
    # Only the target-specific C declaration is omitted; Nim bodies are unchanged.
    mic_functions = re.sub(r"(?m)^\{\.emit:.*\n", "", mic_functions)
    hsu = (ROOT / "src/bl808/wifi/fw/crypto_mfp_hsu.nim").read_text()
    hsu_functions = "proc hsu_michael_init*" + hsu.split("proc hsu_michael_init*", 1)[1]
    rx = (ROOT / "src/bl808/wifi/fw/rx_upper.nim").read_text()
    rx_init = re.search(r"(?m)^[ \t]+me_mic_init\(addr micCtx\[0\],.*?tidVal\)", rx, re.S)
    assert rx_init is not None
    rx_adapter = r"""
proc rxFrameMic(key: array[8, uint8]; da, sa: array[6, uint8]; priority: uint8;
                message: string): array[8, uint8] =
  var keyStorage: array[152, uint8]
  copyMem(addr keyStorage[144], unsafeAddr key[0], 8)
  let secKeyBase = cast[uint](addr keyStorage[0])
  var env = (da: da, sa: sa)
  let tidVal = priority
  var micCtx: array[4, uint32]
""" + textwrap.indent(textwrap.dedent(rx_init[0]), "  ") + r"""
  if message.len != 0:
    me_mic_calc(addr micCtx[0], unsafeAddr message[0], message.len.uint32)
  me_mic_end(addr micCtx[0])
  copyMem(addr result[0], addr micCtx[0], 8)
"""
    source = tmp_path / "wifi_michael_vectors.nim"
    source.write_text(
        "type\n" + context + PRELUDE + mic_functions + hsu_functions
        + rx_adapter + CHECKS + "\n" + "\n".join(cases)
    )
    run = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}",
         f"-o:{tmp_path / 'wifi_michael_vectors'}", str(source)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        timeout=90,
    )
    assert run.returncode == 0, run.stdout


def test_wifi_rx_mic_crosses_payload_boundaries(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    rx = (ROOT / "src/bl808/wifi/fw/rx_upper.nim").read_text()
    read_mic = rx.split("# 3. Read received MIC", 1)[1].split(
        "# 4. Compare computed MIC", 1
    )[0]
    # Restore the comment prefix removed by the split, then dedent the real body.
    read_mic = textwrap.dedent("          # 3. Read received MIC" + read_mic)
    layouts = (ROOT / "src/bl808/wifi/fw/layout_types.nim").read_text()
    chain = "  RxFrameBufferChainView" + layouts.split("  RxFrameBufferChainView", 1)[1].split(
        "  RxDmaProgressDescView", 1
    )[0]
    words = "  RxMicWordsView" + layouts.split("  RxMicWordsView", 1)[1].split(
        "  VifKeyPointersView", 1
    )[0]
    prelude = r"""
const MAX_DMA_SEG = 1736
var missingChainErrors = 0
template rxFrameBufferChainAt(p: pointer): ptr RxFrameBufferChainView =
  cast[ptr RxFrameBufferChainView](p)
template rxMicWordsAt(p: uint): ptr RxMicWordsView = cast[ptr RxMicWordsView](p)
proc assert_rec(file, message: cstring; line: cint) =
  doAssert line == 852
  inc missingChainErrors
proc readMic(chain: pointer; frameSize: uint16; received: var array[2, uint32]): bool =
  let swdesc = (bufferChain: chain)
  template doReturn() = return false
"""
    checks = r"""
  received = rxMic
  true

let expected: array[8, uint8] = [0x42'u8, 0x31, 0x27, 0x59, 0x8A, 0x63, 0x77, 0xB2]
for micStart in [24, 1728, 1729, 1730, 1731, 1732, 1733, 1734, 1735,
                 1736, 1737, 3464, 3465, 3466, 3467, 3468, 3469, 3470,
                 3471, 3472, 3473, 5207, 5208]:
  # Poison guard bytes make an accidental cross-buffer word read deterministic.
  var payloads: array[4, array[MAX_DMA_SEG + 8, uint8]]
  var nodes: array[4, RxFrameBufferChainView]
  for i in 0 ..< nodes.len:
    for j in 0 ..< payloads[i].len: payloads[i][j] = 0xDD
    nodes[i].frameData = addr payloads[i][0]
    if i + 1 < nodes.len: nodes[i].next = addr nodes[i + 1]
  for i in 0 ..< expected.len:
    let position = micStart + i
    payloads[position div MAX_DMA_SEG][position mod MAX_DMA_SEG] = expected[i]
  let before = payloads
  var received: array[2, uint32]
  doAssert readMic(addr nodes[0], (micStart + 8).uint16, received)
  var bytes: array[8, uint8]
  copyMem(addr bytes[0], addr received[0], 8)
  doAssert bytes == expected, "MIC at " & $micStart & " crosses descriptor boundary"
  doAssert payloads == before, "MIC read modified packet bytes"

# Incomplete MICs must not read past the last descriptor or reach comparison.
for micStart in [1729, 1730, 1731, 1732, 1733, 1734, 1735, 1736]:
  var payload: array[MAX_DMA_SEG + 8, uint8]
  var node = RxFrameBufferChainView(frameData: addr payload[0])
  var received: array[2, uint32]
  let errorsBefore = missingChainErrors
  doAssert not readMic(addr node, (micStart + 8).uint16, received)
  doAssert missingChainErrors == errorsBefore + 1

var received: array[2, uint32]
let errorsBeforeShortFrame = missingChainErrors
for length in 0'u16 .. 7'u16:
  doAssert not readMic(nil, length, received)
doAssert missingChainErrors == errorsBeforeShortFrame
doAssert not readMic(nil, 32, received)
doAssert missingChainErrors == errorsBeforeShortFrame + 1
"""
    source = tmp_path / "wifi_rx_mic_segments.nim"
    source.write_text("type\n" + chain + words + prelude + textwrap.indent(read_mic, "  ") + checks)
    run = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}",
         f"-o:{tmp_path / 'wifi_rx_mic_segments'}", str(source)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        timeout=90,
    )
    assert run.returncode == 0, run.stdout


def test_wifi_rx_mic_failure_indication_wire_fields(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    rx = (ROOT / "src/bl808/wifi/fw/rx_upper.nim").read_text()
    body = re.search(r"(?m)^[ \t]+let failMsg = ke_msg_alloc\(0xC04'u16,.*?ke_msg_send\(failMsg\)", rx, re.S)
    assert body is not None
    layouts = (ROOT / "src/bl808/wifi/fw/layout_types.nim").read_text()
    indication = "  RxMicFailureIndView" + layouts.split("  RxMicFailureIndView", 1)[1].split(
        "  RxEthernetRewriteHeaderView", 1
    )[0]
    prelude = r"""
type TestSta = object
  macAddr: array[6, uint8]
var sta = TestSta(macAddr: [2'u8, 3, 4, 5, 6, 7])
var sent = 0
var allocationBuffer: pointer
var allocationDest: uint8
proc ke_msg_alloc(id: uint16; destId, srcId: uint8; paramLen: uint32): pointer =
  doAssert id == 0xC04 and srcId == TASK_ME and paramLen == 24
  allocationDest = destId
  allocationBuffer
proc staInfoForIdx(idx: uint8): ptr TestSta =
  doAssert idx == 3
  addr sta
proc rxCopyAddr(dst, src: ptr array[6, uint8]) = dst[] = src[]
proc rxMicFailureIndAt(p: pointer): ptr RxMicFailureIndView =
  cast[ptr RxMicFailureIndView](p)
proc ke_msg_send(p: pointer) = inc sent
proc makeIndication(flags: uint32; tid: uint8): array[24, uint8] =
  for i in 0 ..< result.len: result[i] = 0xA5
  allocationBuffer = addr result[0]
  let env = (staIdx: 3'u8, vifIdx: 1'u8, secInfo0: 0x44332211'u32,
             secInfo1: 0x00006655'u32, hwRxhdr: flags)
  let secKey = (staIdx: 2'u8,)
  let tidVal = tid
"""
    checks = r"""
static: doAssert sizeof(RxMicFailureIndView) == 24
for flags in [0'u32, 0x400'u32, 0xFF000000'u32, 0xFF000400'u32]:
  for tid in [0'u8, 1, 3, 7, 8, 255]:
    let before = sent
    let wire = makeIndication(flags, tid)
    doAssert allocationDest == 9, "MIC failure indication must reach host API task"
    doAssert sent == before + 1
    for i in 0 ..< 6: doAssert wire[i] == sta.macAddr[i]
    doAssert wire[6] == 0xA5 and wire[7] == 0xA5
    doAssert wire[8 .. 15] == @[0x11'u8, 0x22, 0x33, 0x44, 0x55, 0x66, 0, 0]
    doAssert wire[16] == ((flags shr 10) and 1).uint8,
      "group flag must come from hardware bit 10, not TID"
    doAssert wire[17] == 2 and wire[18] == 1
    for i in 19 ..< 24:
      doAssert wire[i] == 0xA5, "failure indication padding was written"
"""
    source = tmp_path / "wifi_rx_mic_indication.nim"
    source.write_text("import bl808/wifi/fw_messages/tasks\ntype\n" + indication + prelude + textwrap.indent(
        textwrap.dedent(body[0]), "  "
    ) + "\n" + checks)
    run = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'nimcache'}",
         f"-o:{tmp_path / 'wifi_rx_mic_indication'}", str(source)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        timeout=90,
    )
    assert run.returncode == 0, run.stdout
