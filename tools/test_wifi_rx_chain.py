"""Run the production RX chain walkers and uploader with a bounded DMA pool."""

from pathlib import Path
import os
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import RX_RING_CONFIG_IMPORT
from test_wifi_rx_upload import RX_FORWARD_SHIM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
proc rxStationCurrent(p: pointer): bool = true
proc rxCapturedChannelCurrent(p: pointer): bool = false
proc rxUploadGeneration(p: pointer): uint32 = 0
proc rxUploadCurrent(p: pointer; generation: uint32): bool = true
proc rxInvalidateUpload(p: pointer) = discard
proc rxl_mpdu_free*(desc: pointer) {.exportc, cdecl.}
proc rxReleaseUpload(p: pointer; generation: uint32) = rxl_mpdu_free(p)
type
  RxPayloadHwDescView = object
    magic: uint32
    next: pointer
    bufferAddr, bufferEnd: uint32
    status, usedFlag: uint32
    bufferStart: uint32
    frameLen: uint16
  RxDmaProgressDescView = RxPayloadHwDescView
  RxPayloadBufferView = object
    payloadBytes: array[1736, uint8]
  RxSwDescView = object
    bufferChain: pointer
    mpduLengthBytes: uint16
    bufferOffset, frameControlFlags, uploadDone: uint32
    channelInfo: array[8, uint8]
  RxMpduDescView = object
    swDesc, prevDesc, curDesc: pointer
    descFlag, descCount: uint8
  RxUploadDmaArrayView = object
    bufferAddrs, frameLenFieldAddrs: array[4, uint32]
    lengths: array[4, uint16]
  CoListHdr = object
  CoList = object
    nodes: seq[pointer]
  RxuEnv = object
    uploadList: CoList
  RxlEnv = object
    uploadCount: uint32
var
  rx_payload_desc: array[41 * sizeof(RxPayloadHwDescView), uint8]
  payloadBytes: array[41, RxPayloadBufferView]
  sw: RxSwDescView
  desc: RxMpduDescView
  upper: RxuEnv
  lower: RxlEnv
  level: uint32
  expectedLevel: uint32
  assertions, released, entered, exited, channelCalls, inputCalls: int
  inputResult: cint
  releaseThrows: bool
  dma: RxUploadDmaArrayView
  nimFwDbgRxuUploadEvt, nimFwDbgRxuUploadEntry: uint32
  nimFwDbgRxuUploadTcpipFail, nimFwDbgRxuUploadTcpipOk, nimFwDbgRxuDescPrepare: uint32
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc rxPayloadHwDescAt(index: int): ptr RxPayloadHwDescView =
  cast[ptr RxPayloadHwDescView](addr rx_payload_desc[index * sizeof(RxPayloadHwDescView)])
proc rxPayloadBufferAt(index: int): ptr RxPayloadBufferView = addr payloadBytes[index]
proc rxDmaProgressDescAt(p: pointer): ptr RxDmaProgressDescView = cast[ptr RxDmaProgressDescView](p)
proc rxMpduDescView(p: pointer): ptr RxMpduDescView = cast[ptr RxMpduDescView](p)
proc rxSwDescView(p: pointer): ptr RxSwDescView = cast[ptr RxSwDescView](p)
proc rxMpduHeader(p: pointer): ptr RxSwDescView =
  if p == (addr desc) and desc.swDesc == (addr sw): addr sw else: nil
proc rxCaptureFrame(p: pointer): uint8 = 0
proc rxFrameCurrent(identity: uint8): bool = true
proc first(list: CoList): pointer =
  if list.nodes.len == 0: nil else: list.nodes[0]
proc rxuCntrlEnvView(): ptr RxuEnv = addr upper
proc rxlCntrlEnvView(): ptr RxlEnv = addr lower
proc co_list_pop_front(list: ptr CoList): pointer =
  if list.nodes.len == 0: return nil
  result = list.nodes[0]
  list.nodes.delete(0)
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) = list.nodes.add(node)
proc ke_evt_clear(mask: uint32) = doAssert mask == 0x800000
proc ke_evt_set(mask: uint32) = doAssert mask == 0x800000
proc getLogFunc(offset: int): pointer = nil
proc c_memset(p: pointer; value: cint; length: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, length.int)
  p
proc enter(): uint32 {.cdecl.} =
  result = level
  level = 0
  inc entered
proc leave(saved: uint32) {.cdecl.} =
  doAssert level == 0
  level = saved
  inc exited
proc irqSave(): uint32 =
  result = level
  level = 0
proc irqRestore(saved: uint32) = level = saved
proc blOpsFunc(offset: int): pointer =
  case offset
  of 20: cast[pointer](enter)
  of 24: cast[pointer](leave)
  else: nil
proc assert_rec(condition, file: cstring; line: int) =
  doAssert level == expectedLevel, "RX error returned with interrupts disabled"
  inc assertions
proc rxl_frame_release(p: pointer) =
  doAssert level == 0 and p == addr desc
  inc released
  if releaseThrows: raise newException(ValueError, "injected release failure")
proc phy_get_channel_raw(p: pointer; band: uint8) =
  doAssert p != nil and band == 0
  inc channelCalls
  zeroMem(p, 8)
proc tcpip_stack_input(p: pointer; flag: uint32; header: pointer; offset: uint32;
                       packet: pointer; fc: uint32): cint =
  doAssert p == cast[pointer](addr desc) and header == cast[pointer](addr sw.mpduLengthBytes)
  doAssert level == 8
  inc inputCalls
  dma = cast[ptr RxUploadDmaArrayView](packet)[]
  inputResult
"""

CHECKS = r"""
proc reset(count: int; terminal = true) =
  zeroMem(addr rx_payload_desc[0], sizeof(rx_payload_desc))
  upper.uploadList.nodes.setLen(0)
  lower.uploadCount = 0
  sw = default(RxSwDescView)
  desc = RxMpduDescView(swDesc: addr sw, descFlag: 3)
  level = 8
  expectedLevel = 8
  assertions = 0
  entered = 0
  exited = 0
  released = 0
  channelCalls = 0
  inputCalls = 0
  inputResult = 0
  releaseThrows = false
  dma = default(RxUploadDmaArrayView)
  for i in 0 ..< count:
    let pd = rxPayloadHwDescAt(i)
    pd.bufferAddr = pointerAddrU32(addr rxPayloadBufferAt(i).payloadBytes[0])
    pd.usedFlag = 0x1234
    if i + 1 < count: pd.next = rxPayloadHwDescAt(i + 1)
    elif terminal: pd.status = 1
  if count > 0: sw.bufferChain = rxPayloadHwDescAt(0)

for count in 1 .. 41:
  reset(count)
  # End-of-frame status terminates the packet even when the DMA ring continues.
  rxPayloadHwDescAt(count - 1).next = rxPayloadHwDescAt(0)
  rxl_mpdu_transfer(addr desc)
  doAssert channelCalls == 1 and desc.descCount == (count - 1).uint8
  doAssert desc.curDesc == rxPayloadHwDescAt(count - 1)
  doAssert desc.prevDesc == (if count == 1: nil else: cast[pointer](rxPayloadHwDescAt(count - 2)))
  sw.uploadDone = 1
  rxl_mpdu_free(addr desc)
  doAssert released == 1 and assertions == 0 and entered == 1 and exited == 1
  doAssert level == 8 and sw.uploadDone == 0
  for i in 0 ..< count: doAssert rxPayloadHwDescAt(i).usedFlag == 0

# Exercise every start/stride permutation across the physical pool.
for start in 0 ..< 41:
  for step in 1 ..< 41:
    let count = (start + step) mod 41 + 1
    reset(0)
    for i in 0 ..< count:
      let index = (start + i * step) mod 41
      let pd = rxPayloadHwDescAt(index)
      pd.usedFlag = 1
      if i + 1 == count: pd.status = 1
      else: pd.next = rxPayloadHwDescAt((start + (i + 1) * step) mod 41)
    sw.bufferChain = rxPayloadHwDescAt(start)
    rxl_mpdu_transfer(addr desc)
    doAssert desc.descCount == (count - 1).uint8
    doAssert desc.curDesc == rxPayloadHwDescAt((start + (count - 1) * step) mod 41)
    rxl_mpdu_free(addr desc)
    doAssert released == 1 and assertions == 0 and entered == exited

for originalLevel in [0'u32, 8'u32]:
  for terminal in [false, true]:
    reset(1, terminal)
    level = originalLevel
    expectedLevel = originalLevel
    rxl_mpdu_free(addr desc)
    doAssert level == originalLevel and entered == 1 and exited == 1
    doAssert assertions == (if terminal: 0 else: 1)

# Old code asserts here without balancing its platform critical section.
reset(2, false)
sw.uploadDone = 1
rxl_mpdu_free(addr desc)
doAssert released == 0 and assertions == 1 and level == 8
doAssert entered == 1 and exited == 1
doAssert sw.uploadDone == 1 and rxPayloadHwDescAt(0).usedFlag == 0x1234

reset(1)
releaseThrows = true
var raised = false
try:
  rxl_mpdu_free(addr desc)
except ValueError:
  raised = true
doAssert raised and level == 8 and entered == 1 and exited == 1

# Reject null, foreign/misaligned pointers, and cycles without dereferencing them.
for variant in 0 .. 7:
  reset(3, false)
  case variant
  of 0: sw.bufferChain = nil
  of 1: sw.bufferChain = cast[pointer](1'u)
  of 2: sw.bufferChain = cast[pointer](cast[uint](sw.bufferChain) + 1)
  of 3: rxPayloadHwDescAt(0).next = cast[pointer](1'u)
  of 4: rxPayloadHwDescAt(0).next = rxPayloadHwDescAt(0)
  of 5: rxPayloadHwDescAt(2).next = rxPayloadHwDescAt(1)
  of 6: sw.bufferChain = cast[pointer](cast[uint](addr rx_payload_desc[0]) + sizeof(rx_payload_desc).uint)
  else: sw.bufferChain = cast[pointer](cast[uint](addr rx_payload_desc[0]) - 1)
  desc.prevDesc = cast[pointer](1'u)
  desc.curDesc = cast[pointer](1'u)
  desc.descCount = 255
  rxl_mpdu_transfer(addr desc)
  doAssert assertions == 1 and channelCalls == 0
  doAssert desc.prevDesc == nil and desc.curDesc == nil and desc.descCount == 0
  rxl_mpdu_free(addr desc)
  doAssert released == 0 and assertions == 2 and level == 8 and entered == exited
  doAssert rxPayloadHwDescAt(0).usedFlag == 0x1234

# Invalid transfers must not be queued by their caller's descriptor-prepare step.
reset(1, false)
rxl_mpdu_transfer(addr desc)
rxu_cntrl_desc_prepare(addr desc)
doAssert upper.uploadList.nodes.len == 0

proc upload(count, length, offset: int; accepted: bool; corruptAddress = false;
            initialCount: uint8 = 0; retained = false) =
  reset(count)
  sw.mpduLengthBytes = length.uint16
  sw.bufferOffset = offset.uint32
  desc.descCount = initialCount
  for i in 0 ..< count: rxPayloadHwDescAt(i).usedFlag = 0
  if corruptAddress: rxPayloadHwDescAt(0).bufferAddr = 0
  if retained: inputResult = 0 else: inputResult = -1
  upper.uploadList.nodes.add(addr desc)
  rxu_swdesc_upload_evt()
  doAssert inputCalls == accepted.int
  doAssert level == 8
  if accepted:
    let segments = (length + offset + 1735) div 1736
    doAssert desc.descCount == initialCount + segments.uint8
    for i in 0 ..< segments:
      doAssert dma.lengths[i] == min(1736, length + offset - i * 1736).uint16
    when defined(bl808WifiRxPbufInput):
      doAssert released == 1 and lower.uploadCount == 0
    else:
      if retained:
        doAssert released == 0 and lower.uploadCount == desc.descCount.uint32
        bl60x_firmwre_mpdu_free(addr desc)
        doAssert released == 1 and lower.uploadCount == 0 and level == 8
      else:
        doAssert released == 1 and lower.uploadCount == 0
  else:
    doAssert desc.descCount == initialCount and inputCalls == 0
    if corruptAddress:
      doAssert released == 0 and assertions == 1 and lower.uploadCount == 0
    else:
      doAssert released == 1 and lower.uploadCount == 0

for count in 1 .. 4:
  for length in [1, 1735, 1736, 1737, 3472, 5208, 6944, 6945]:
    upload(count, length, 0, length <= count * 1736 and length <= 6944)
upload(4, 1736, 2, true, initialCount = 2)
upload(4, 100, 0, true, retained = true)
upload(4, 0, 0, false)
upload(4, 1, 1736, false)
upload(4, 100, 0x7FFFFFFF, false)
upload(4, 100, 0, false, corruptAddress = true)
upload(4, 1737, 0, false, initialCount = 255)

# An invalid ring is recovered, not handed to the normal free walker again.
reset(2, false)
sw.mpduLengthBytes = 100
upper.uploadList.nodes.add(addr desc)
rxu_swdesc_upload_evt()
doAssert inputCalls == 0 and released == 0 and assertions == 1 and level == 8

# An already uploaded buffer must not be reclaimed by a duplicate upload.
for count in [0'u32, 39'u32]:
  reset(2)
  lower.uploadCount = count
  sw.mpduLengthBytes = 100
  upper.uploadList.nodes.add(addr desc)
  rxu_swdesc_upload_evt()
  doAssert inputCalls == 0 and released == 0 and assertions == 1
  doAssert rxPayloadHwDescAt(0).usedFlag == 0x1234
  doAssert lower.uploadCount == count

reset(0)
rxl_mpdu_free(nil)
rxl_mpdu_transfer(nil)
desc.swDesc = nil
rxl_mpdu_free(addr desc)
rxl_mpdu_transfer(addr desc)
doAssert assertions == 4 and entered == 0 and released == 0
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("pbuf_input", [False, True])
def test_rx_chain(mode, pbuf_input, tmp_path):
    nim = shutil.which("nim")
    if not nim:
        pytest.skip("Nim compiler is unavailable")
    lower = (FW / "rx_layer.nim").read_text()
    upper = (FW / "rx_upper.nim").read_text()
    source = PLATFORM + RX_FORWARD_SHIM
    for name in ["rxPayloadDescIndex", "rxPayloadBufferValid", "rxPayloadChainBounds",
                 "rxl_mpdu_free", "rxTransferFrame", "rxl_mpdu_transfer"]:
        if f"proc {name}(" in lower or f"proc {name}*(" in lower:
            source += procedure(lower, name)
    source += procedure(upper, "rxu_cntrl_desc_prepare")
    source += procedure(upper, "rxu_swdesc_upload_evt")
    source += procedure((FW / "mac_config_debug.nim").read_text(), "bl60x_firmwre_mpdu_free")
    path = tmp_path / "rx_chain.nim"
    path.write_text(RX_RING_CONFIG_IMPORT + source + CHECKS)
    binary = tmp_path / "test"
    command = [nim, "c", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{binary}"]
    command += ["--checks:on"] if mode == "checked" else ["-d:release", "--checks:off"]
    if pbuf_input:
        command += ["-d:bl808WifiRxPbufInput"]
    if mode == "asan":
        command += ["--passC:-fsanitize=address", "--passC:-fno-omit-frame-pointer", "--passL:-fsanitize=address"]
    compiled = subprocess.run(command + [str(path)], cwd=ROOT, text=True, timeout=60,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert compiled.returncode == 0, compiled.stdout
    ran = subprocess.run([str(binary)], cwd=ROOT, text=True, timeout=15,
                         env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0"},
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert ran.returncode == 0, ran.stdout
