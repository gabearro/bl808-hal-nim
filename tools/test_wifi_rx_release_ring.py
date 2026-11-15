"""Return complete RX frames through the real release and DMA append routines."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_dma_ring import source as ring_source


def source() -> str:
    code = "var rxUploadEpochs: array[41, uint32]\n" + ring_source()
    code = code.replace(
        layouts("RxSwTableDescView").removeprefix("type\n"),
        layouts("RxMpduDescView").removeprefix("type\n")
        + "  RxSwTableDescView = RxMpduDescView\n",
        1,
    )
    code = code.replace("      forgotten.add(i)\n",
                        "      forgotten.add(i)\n      inc rxUploadEpochs[i]\n", 1)
    # Host pointers are wider than the target's address fields. Resolve the
    # header's 32-bit payload address through the bounded native fixture pool.
    code += r'''
type RxSwDescView = RxHeaderHwDescView
template rx_payload_desc: untyped =
  cast[ptr array[sizeof(payloads), uint8]](addr payloads[0])[]
template uploadDone(header: ptr RxSwDescView): untyped = header.usedFlag
template `uploadDone=`(header: ptr RxSwDescView; value: uint32) =
  header.usedFlag = value
proc bufferChain(header: ptr RxSwDescView): pointer =
  if header.bufferAddr == 0: return nil
  for i in 0 ..< payloads.len:
    if header.bufferAddr == pointerAddrU32(addr payloads[i]):
      return addr payloads[i]
proc rxSwDescView(p: pointer): ptr RxSwDescView = cast[ptr RxSwDescView](p)
proc rxMpduDescView(p: pointer): ptr RxMpduDescView = cast[ptr RxMpduDescView](p)
proc rxMpduDescIndex(p: pointer): int =
  for i in 0 ..< software.len:
    if p == (addr software[i]): return i
  -1
proc rxMpduHeader(p: pointer): ptr RxSwDescView =
  let i = rxMpduDescIndex(p)
  if i >= 0 and software[i].swDesc == (addr headers[i]) and
      headers[i].swDesc == pointerAddrU32(p):
    return addr headers[i]
'''
    lower = (FW / "rx_layer.nim").read_text()
    for name in (
        "rxUploadGeneration", "rxUploadCurrent", "rxInvalidateUpload",
        "rxPayloadDescIndex", "rxPayloadChainBounds", "rxl_frame_release",
        "rxl_mpdu_free", "rxReleaseUpload", "rxl_current_desc_get",
    ):
        code += procedure(lower, name)
    code += procedure((FW / "mac_config_debug.nim").read_text(),
                      "bl60x_firmwre_mpdu_free")
    return code + r'''
var nextPayload: pointer
proc setup(incoming: uint32) =
  reset()
  software = default(typeof(software))
  rxUploadEpochs = default(typeof(rxUploadEpochs))
  for i in 0 ..< software.len:
    software[i].swDesc = addr headers[i]
    headers[i].usedFlag = 0
    payloads[i].usedFlag = 0
  irqLevel = incoming
  doAssert rxl_hwdesc_init(1)
  nextPayload = addr payloads[1]
  triggers.setLen(0)
  forgotten.setLen(0)
  enters = 0
  exits = 0

proc takeFrame(count: int): ptr RxMpduDescView =
  let header = rxHeaderHwDescView(lower.submittedHead)
  lower.submittedHead = header.next
  header.next = nil
  header.bufferAddr = pointerAddrU32(nextPayload)
  header.usedFlag = 1
  var last, previous: pointer
  for i in 0 ..< count:
    doAssert nextPayload != nil and nextPayload != hardware.pdCurrent
    previous = last
    last = nextPayload
    let payload = rxDmaProgressDescAt(nextPayload)
    nextPayload = payload.next
    payload.status = (i + 1 == count).uint16
    payload.usedFlag = 1
  for i in 0 ..< headers.len:
    if header == (addr headers[i]): result = addr software[i]
  doAssert result != nil
  result.prevDesc = previous
  result.curDesc = last
  result.descCount = (2 * count - 1).uint8
  lower.uploadCount += result.descCount.uint32

proc verifyRings(held: openArray[ptr RxMpduDescView] = []) =
  var currentHeader, currentPayload: pointer
  rxl_current_desc_get(addr currentHeader, addr currentPayload)
  doAssert currentHeader == lower.currentHd
  doAssert currentPayload == hardware.pdCurrent
  var seenHeaders, seenPayloads: array[41, bool]
  var ownedHeaders, ownedPayloads: int
  for frame in held:
    let header = rxMpduHeader(frame)
    doAssert header != nil and header.usedFlag == 1
    inc ownedHeaders
    var payload = bufferChain(header)
    while true:
      doAssert payload != nil
      let pd = rxDmaProgressDescAt(payload)
      doAssert pd.usedFlag == 1
      inc ownedPayloads
      if (pd.status and 1) != 0: break
      payload = pd.next
  var header = lower.submittedHead
  for position in 0 ..< 40 - ownedHeaders:
    doAssert header != nil and header != lower.currentHd
    var index = -1
    for i in 0 ..< headers.len:
      if header == (addr headers[i]): index = i
    doAssert index >= 0 and not seenHeaders[index]
    seenHeaders[index] = true
    doAssert headers[index].usedFlag == 0
    if position == 39 - ownedHeaders:
      doAssert header == lower.submittedTail
    header = rxHeaderHwDescView(header).next
  doAssert header == nil
  var payload = nextPayload
  for position in 0 ..< 40 - ownedPayloads:
    doAssert payload != nil and payload != hardware.pdCurrent
    let index = rxPayloadDescIndex(payload)
    doAssert index >= 0 and not seenPayloads[index]
    seenPayloads[index] = true
    doAssert payloads[index].usedFlag == 0
    if position == 39 - ownedPayloads:
      doAssert payload == hardware.pdTail
    payload = rxDmaProgressDescAt(payload).next
  doAssert payload == nil
  doAssert rxHeaderHwDescView(lower.currentHd).usedFlag == 0
  doAssert rxDmaProgressDescAt(hardware.pdCurrent).usedFlag == 0

proc releaseFrame(frame: ptr RxMpduDescView; headerMatches, payloadMatches: bool) =
  hdHead = if headerMatches: pointerAddrU32(lower.currentHd) else: 0
  pdHead = if payloadMatches: pointerAddrU32(hardware.pdCurrent) else: 0
  let oldTriggers = triggers.len
  let oldCount = lower.uploadCount
  let charged = frame.descCount.uint32
  let oldGeneration = rxUploadGeneration(frame)
  bl60x_firmwre_mpdu_free(frame)
  doAssert lower.uploadCount == oldCount - charged
  doAssert rxUploadGeneration(frame) != oldGeneration
  doAssert rxMpduHeader(frame).usedFlag == 0
  doAssert triggers.len == oldTriggers + 2
  doAssert triggers[^2 .. ^1] == @[0x02000000'u32, 0x01000000'u32]
  let calls = enters
  let releasedGeneration = rxUploadGeneration(frame)
  bl60x_firmwre_mpdu_free(frame)
  doAssert enters == calls and triggers.len == oldTriggers + 2
  doAssert rxUploadGeneration(frame) == releasedGeneration
  doAssert lower.uploadCount == oldCount - charged
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_complete_frame_return_preserves_dma_rings(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [0'u32, 8]:
  setup(incoming)
  for cycle in 0 ..< 164:
    let frame = takeFrame(cycle mod 4 + 1)
    verifyRings([frame])
    let pattern = (cycle div 4) mod 4
    releaseFrame(frame, (pattern and 1) != 0, (pattern and 2) != 0)
    verifyRings()
    doAssert lower.uploadCount == 0 and errors == 0 and irqLevel == incoming
    doAssert enters == exits
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_out_of_order_host_returns_preserve_other_frames(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [0'u32, 8]:
  for pattern in 0 ..< 4:
    for reinitialize in [false, true]:
      setup(incoming)
      let first = takeFrame(1)
      let second = takeFrame(4)
      let third = takeFrame(2)
      verifyRings([first, second, third])
      if reinitialize:
        doAssert rxl_hwdesc_init(0)
        for i in 0 ..< payloads.len:
          if pdSubmitted == pointerAddrU32(addr payloads[i]):
            nextPayload = addr payloads[i]
        verifyRings([first, second, third])
      releaseFrame(second, (pattern and 1) != 0, (pattern and 2) != 0)
      verifyRings([first, third])
      releaseFrame(first, (pattern and 2) != 0, (pattern and 1) != 0)
      verifyRings([third])
      releaseFrame(third, (pattern and 1) == 0, (pattern and 2) == 0)
      verifyRings()
      doAssert lower.uploadCount == 0 and errors == 0 and irqLevel == incoming
      doAssert enters == 6 + reinitialize.int and exits == enters
''')
