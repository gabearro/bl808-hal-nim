"""Execute the RX upload handler with host-side platform/descriptor doubles.

The production Nim body is compiled unchanged, rather than reproducing its
queue/admission algorithm in Python. MMIO and physical layout are deliberately
outside this test; target builds still validate the real descriptor overlays.
"""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_message_allocation import RX_RING_CONFIG_IMPORT

ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
type
  CoList = object
    nodes: seq[pointer]
  RxMpduDescView = object
    swDesc: pointer
    descFlag, descCount: uint8
  RxSwDescView = object
    mpduLengthBytes: uint16
    bufferOffset, frameControlFlags, uploadDone: uint32
    bufferChain: pointer
  RxPayloadHwDescView = object
    bufferAddr: uint32
    bufferStart: uint
    frameLen: uint16
    usedFlag: uint32
    next: pointer
  RxUploadDmaArrayView = object
    bufferAddrs, frameLenFieldAddrs: array[4, uint32]
    lengths: array[4, uint16]
  RxuEnv = object
    uploadList: CoList
  RxlEnv = object
    uploadCount: uint32

var
  upper: RxuEnv
  lower: RxlEnv
  nimFwDbgRxuUploadEvt, nimFwDbgRxuUploadEntry: uint32
  nimFwDbgRxuUploadTcpipFail, nimFwDbgRxuUploadTcpipOk: uint32
  freed: seq[pointer]
  calls: seq[string]
  inputResult: cint
  capturedDma: RxUploadDmaArrayView
  capturedNode, capturedHeader: pointer
  capturedFlag, capturedOffset, capturedFc: uint32
  countOnRestore: uint32

proc first(list: CoList): pointer =
  if list.nodes.len == 0: nil else: list.nodes[0]
proc rxuCntrlEnvView(): ptr RxuEnv = addr upper
proc rxlCntrlEnvView(): ptr RxlEnv = addr lower
proc rxSwDescView(p: pointer): ptr RxSwDescView = cast[ptr RxSwDescView](p)
proc rxMpduHeader(p: pointer): ptr RxSwDescView =
  if p == nil: nil else: rxSwDescView(cast[ptr RxMpduDescView](p).swDesc)
proc rxStationCurrent(p: pointer): bool = true
proc rxUploadGeneration(p: pointer): uint32 = 0
proc rxUploadCurrent(p: pointer; generation: uint32): bool = true
proc co_list_pop_front(list: ptr CoList): pointer =
  if list.nodes.len == 0: return nil
  result = list.nodes[0]
  list.nodes.delete(0)
proc ke_evt_clear(mask: uint32) =
  doAssert mask == 0x00800000'u32
  calls.add("clear")
proc ke_evt_set(mask: uint32) = discard
proc getLogFunc(offset: int): pointer = nil
proc c_memset(dst: pointer; value: cint; size: csize_t): pointer =
  doAssert value == 0
  zeroMem(dst, size.int)
  dst
proc c_memmove(dst, src: pointer; size: csize_t): pointer
  {.importc: "memmove", header: "<string.h>".}
proc rxl_mpdu_free(node: pointer) =
  calls.add("free")
  freed.add(node)
proc rxReleaseUpload(node: pointer; generation: uint32) = rxl_mpdu_free(node)
proc assert_rec(condition, file: cstring; line: int) =
  doAssert false, "unexpected malformed chain in upload fixture"
# These upload doubles use finite nil-terminated chains. Physical-pool and
# end-marker validation is exercised by test_wifi_rx_chain.py.
proc rxPayloadChainBounds(head: pointer; previous, last: var pointer): uint8 =
  previous = nil
  last = head
  while last != nil:
    inc result
    doAssert result <= 41
    let next = cast[ptr RxPayloadHwDescView](last).next
    if next == nil: return
    previous = last
    last = next
proc rxPayloadBufferValid(p: pointer): bool =
  cast[ptr RxPayloadHwDescView](p).bufferAddr != 0
proc enter(): uint32 {.cdecl.} =
  calls.add("enter")
  8
proc leave(saved: uint32) {.cdecl.} =
  doAssert saved == 8
  calls.add("leave")
  countOnRestore = lower.uploadCount
proc blOpsFunc(offset: int): pointer =
  case offset
  of 20: cast[pointer](enter)
  of 24: cast[pointer](leave)
  else: nil
proc tcpip_stack_input(node: pointer; flag: uint32; header: pointer;
                       offset: uint32; dma: pointer; fc: uint32): cint =
  calls.add("input")
  capturedNode = node
  capturedHeader = header
  capturedFlag = flag
  capturedOffset = offset
  capturedFc = fc
  capturedDma = cast[ptr RxUploadDmaArrayView](dma)[]
  inputResult
"""

RX_FORWARD_SHIM = r"""
# This fixture tests the uploader; bridge lifetime is exercised separately.
proc rxHostForward(desc: pointer; generation, status: uint32; header: pointer;
                   offset: uint32; data: pointer; extra: uint32): cint =
  tcpip_stack_input(desc, status, header, offset, data, extra)
"""
PLATFORM += RX_FORWARD_SHIM

CHECKS = r"""
proc checkHeaderMove(headerLen: uint8; stripLen: uint32) =
  var bytes: array[64, uint8]
  for i in 0 ..< bytes.len:
    bytes[i] = i.uint8
  let before = bytes
  var expected = bytes
  var payload = RxPayloadHwDescView(bufferAddr: 0x20000000,
                                    bufferStart: cast[uint](addr bytes[0]))
  var sw = RxSwDescView(bufferChain: addr payload)
  for i in 0 ..< headerLen.int:
    expected[stripLen.int + i] = before[i]
  rxuStripPayloadPrefix(addr sw, stripLen, headerLen)
  doAssert bytes == expected, "overlapping MAC header move"
  # Blob writes packet bytes, not the payload descriptor at +8 or +24.
  doAssert payload.bufferAddr == 0x20000000, "changed DMA buffer address"
  doAssert payload.bufferStart == cast[uint](addr bytes[0])

for headerLen in [24'u8, 26, 30, 32, 36]:
  for stripLen in [0'u32, 4, 8, 12]:
    checkHeaderMove(headerLen, stripLen)

proc reset(count: uint32) =
  upper = default(RxuEnv)
  lower.uploadCount = count
  calls.setLen(0)
  freed.setLen(0)
  inputResult = 0
  capturedNode = nil
  capturedDma = default(RxUploadDmaArrayView)
  countOnRestore = 0

proc checkUpload(count: uint32; length: uint16; offset: uint32 = 0;
                 fail = false; initialSegments: uint8 = 0) =
  reset(count)
  var payloads: array[4, RxPayloadHwDescView]
  for i in 0 ..< payloads.len:
    payloads[i].bufferAddr = 0x20000000'u32 + i.uint32 * 0x800'u32
    if i + 1 < payloads.len: payloads[i].next = addr payloads[i + 1]
  var sw = RxSwDescView(mpduLengthBytes: length, bufferOffset: offset,
    frameControlFlags: 0x1235, bufferChain: addr payloads[0])
  var desc = RxMpduDescView(swDesc: addr sw, descFlag: 3,
                           descCount: initialSegments)
  upper.uploadList.nodes.add(addr desc)
  inputResult = if fail: -1 else: 0
  rxu_swdesc_upload_evt()
  doAssert upper.uploadList.nodes.len == 0
  # Vendor: signed BLT 2, (41 - count), admits only when headroom > 2.
  if count >= 39:
    doAssert calls == @["clear", "free"], "admitted exhausted count " & $count
    doAssert freed == @[cast[pointer](addr desc)]
    doAssert desc.descCount == initialSegments
    doAssert sw.uploadDone == 0
    doAssert lower.uploadCount == count
    return
  if length == 0 or offset >= 1736 or length.uint32 + offset > 6944:
    doAssert calls == @["clear", "free"]
    doAssert freed == @[cast[pointer](addr desc)]
    doAssert desc.descCount == initialSegments and sw.uploadDone == 0
    doAssert lower.uploadCount == count
    return
  doAssert capturedNode == cast[pointer](addr desc)
  doAssert capturedHeader == cast[pointer](addr sw.mpduLengthBytes)
  doAssert capturedFlag == 3 and capturedOffset == offset and capturedFc == 1
  doAssert sw.uploadDone == 1
  var remaining = length.uint32 + offset
  var segments = 0'u8
  for i in 0 ..< payloads.len:
    let size = min(remaining, 1736'u32).uint16
    doAssert capturedDma.lengths[i] == size
    if size != 0:
      inc segments
      doAssert capturedDma.bufferAddrs[i] == payloads[i].bufferAddr
      doAssert capturedDma.frameLenFieldAddrs[i] ==
        cast[uint32](cast[uint](addr payloads[i].frameLen))
      doAssert payloads[i].usedFlag == 1
      remaining -= size.uint32
    else:
      doAssert capturedDma.bufferAddrs[i] == 0
      doAssert capturedDma.frameLenFieldAddrs[i] == 0
      doAssert payloads[i].usedFlag == 0
  doAssert desc.descCount == initialSegments + segments
  if fail:
    doAssert calls == @["clear", "input", "free"]
    doAssert freed == @[cast[pointer](addr desc)]
    doAssert lower.uploadCount == count
  else:
    when defined(bl808WifiRxPbufInput):
      doAssert calls == @["clear", "input", "free"]
      doAssert freed == @[cast[pointer](addr desc)]
      doAssert lower.uploadCount == count
    else:
      doAssert calls == @["clear", "input", "enter", "leave"]
      doAssert freed.len == 0
      doAssert lower.uploadCount == count + initialSegments + segments
      doAssert countOnRestore == lower.uploadCount

reset(0)
rxu_swdesc_upload_evt()
doAssert calls == @["clear"]
for count in 0'u32 .. 128'u32:
  checkUpload(count, 100)
for count in [0x7FFFFFFF'u32, 0x80000000'u32, 0xFFFFFFFE'u32, 0xFFFFFFFF'u32]:
  checkUpload(count, 100)
for size in [0'u16, 1, 1735, 1736, 1737, 3472, 5209, 6944, 6945]:
  checkUpload(0, size)
checkUpload(38, 1734, offset = 4)
checkUpload(0, 1737, initialSegments = 2)
checkUpload(0, 1737, fail = true)

# Admission must be rechecked after each dequeued frame changes uploadCount.
for firstLength in [10'u16, 6944'u16]:
  reset(38)
  var queuePayloads: array[3, array[4, RxPayloadHwDescView]]
  var queueSw: array[3, RxSwDescView]
  var queueDescs: array[3, RxMpduDescView]
  for i in 0 ..< 3:
    for j in 0 ..< 4:
      queuePayloads[i][j].bufferAddr = 0x20000000'u32 + (i * 4 + j).uint32 * 0x800
    for j in 0 ..< 3:
      queuePayloads[i][j].next = addr queuePayloads[i][j + 1]
    queueSw[i] = RxSwDescView(mpduLengthBytes: firstLength,
                             bufferChain: addr queuePayloads[i][0])
    queueDescs[i] = RxMpduDescView(swDesc: addr queueSw[i], descFlag: 3)
    upper.uploadList.nodes.add(addr queueDescs[i])
  rxu_swdesc_upload_evt()
  doAssert upper.uploadList.nodes.len == 0
  when defined(bl808WifiRxPbufInput):
    doAssert calls == @["clear", "input", "free", "input", "free", "input", "free"]
    doAssert lower.uploadCount == 38
  else:
    doAssert calls == @["clear", "input", "enter", "leave", "free", "free"]
    doAssert lower.uploadCount == (if firstLength == 10: 39'u32 else: 42'u32)
    doAssert freed == @[cast[pointer](addr queueDescs[1]),
                       cast[pointer](addr queueDescs[2])]
"""


@pytest.mark.parametrize("pbuf_input", [False, True])
def test_rx_upload_handler(pbuf_input: bool, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    firmware = (ROOT / "src/bl808/wifi/fw/rx_upper.nim").read_text()
    strip_helper = "proc rxuStripPayloadPrefix" + firmware.split(
        "proc rxuStripPayloadPrefix", 1
    )[1].split("\nproc rxu_cntrl_desc_prepare", 1)[0]
    signature = "proc rxu_swdesc_upload_evt*() {.exportc, cdecl.} ="
    handler = signature + firmware.split(signature, 1)[1].split("\nproc ", 1)[0]
    source = tmp_path / "rx_upload_test.nim"
    source.write_text(RX_RING_CONFIG_IMPORT + "proc irqSave(): uint32 = 8\n"
                     "proc irqRestore(saved: uint32) = discard\n"
                     + PLATFORM + "\n" + strip_helper + "\n" + handler + "\n" + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
               "--skipUserCfg:on", "--checks:on",
               f"--nimcache:{tmp_path / 'nimcache'}",
               f"-o:{tmp_path / 'rx_upload_test'}"]
    if pbuf_input:
        command.append("-d:bl808WifiRxPbufInput")
    result = subprocess.run(command + [str(source)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
