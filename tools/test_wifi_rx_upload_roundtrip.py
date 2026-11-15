"""Exercise real RX transfer, upload, and host release as one pipeline."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_chain import CHECKS, PLATFORM
from test_wifi_rx_upload import RX_FORWARD_SHIM


def source() -> str:
    code = PLATFORM.replace(
        "  doAssert level == 8\n  inc inputCalls",
        "  doAssert level == expectedLevel\n  inc inputCalls",
    ) + RX_FORWARD_SHIM
    lower = (FW / "rx_layer.nim").read_text()
    for name in (
        "rxPayloadDescIndex",
        "rxPayloadBufferValid",
        "rxPayloadChainBounds",
        "rxl_mpdu_free",
        "rxTransferFrame",
        "rxl_mpdu_transfer",
    ):
        code += procedure(lower, name)
    code += procedure((FW / "rx_upper.nim").read_text(), "rxu_swdesc_upload_evt")
    code += procedure(
        (FW / "mac_config_debug.nim").read_text(), "bl60x_firmwre_mpdu_free"
    )
    code += CHECKS.split("\nfor count in 1 .. 41:", 1)[0]
    return code + r'''
proc prepare(segments: int; offset, retained, incoming: uint32) =
  reset(segments)
  level = incoming
  expectedLevel = incoming
  lower.uploadCount = retained
  for index in 0 ..< segments:
    rxPayloadHwDescAt(index).usedFlag = 0
  sw.bufferOffset = offset
  sw.mpduLengthBytes = ((segments - 1) * 1736 + 37 - offset.int).uint16
  # The terminal marker, not nil, bounds a packet within the hardware ring.
  rxPayloadHwDescAt(segments - 1).next = rxPayloadHwDescAt(0)
  rxl_mpdu_transfer(addr desc)
  doAssert desc.descCount == (segments - 1).uint8
  doAssert desc.curDesc == rxPayloadHwDescAt(segments - 1)
  doAssert desc.prevDesc ==
    (if segments == 1: nil else: cast[pointer](rxPayloadHwDescAt(segments - 2)))
  doAssert level == incoming and lower.uploadCount == retained
  upper.uploadList.nodes.add(addr desc)
proc checkRecycled(segments: int; retained, incoming: uint32) =
  doAssert lower.uploadCount == retained and sw.uploadDone == 0
  doAssert released == 1 and assertions == 0 and level == incoming
  doAssert entered == exited and upper.uploadList.nodes.len == 0
  for index in 0 ..< segments:
    doAssert rxPayloadHwDescAt(index).usedFlag == 0
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_retained_upload_roundtrip(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for segments in 1 .. 4:
  for offset in [0'u32, 4, 20]:
    for retained in [0'u32, 7]:
      for incoming in [0'u32, 8]:
        prepare(segments, offset, retained, incoming)
        rxu_swdesc_upload_evt()
        # Vendor counts nonterminal links at transfer, then each upload entry.
        let charged = (2 * segments - 1).uint32
        doAssert desc.descCount.uint32 == charged
        doAssert lower.uploadCount == retained + charged
        doAssert sw.uploadDone == 1 and inputCalls == 1 and released == 0
        doAssert level == incoming and entered == 1 and exited == 1
        for index in 0 ..< 4:
          let expected = if index + 1 < segments: 1736'u16
                         elif index < segments: 37'u16
                         else: 0'u16
          doAssert dma.lengths[index] == expected
          if index < segments:
            doAssert dma.bufferAddrs[index] == rxPayloadHwDescAt(index).bufferAddr
            doAssert rxPayloadHwDescAt(index).usedFlag == 1
        bl60x_firmwre_mpdu_free(addr desc)
        checkRecycled(segments, retained, incoming)
        let entryCount = entered
        bl60x_firmwre_mpdu_free(addr desc)
        checkRecycled(segments, retained, incoming)
        doAssert entered == entryCount, "duplicate host release reentered the adapter"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rejected_host_delivery_does_not_charge_buffers(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for segments in 1 .. 4:
  for retained in [0'u32, 7]:
    for incoming in [0'u32, 8]:
      prepare(segments, 4, retained, incoming)
      inputResult = -1
      rxu_swdesc_upload_evt()
      doAssert inputCalls == 1
      doAssert desc.descCount == (2 * segments - 1).uint8
      checkRecycled(segments, retained, incoming)
      let entryCount = entered
      bl60x_firmwre_mpdu_free(addr desc)
      checkRecycled(segments, retained, incoming)
      doAssert entered == entryCount
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_headroom_rejection_recycles_transferred_chain(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for segments in 1 .. 4:
  for retained in [39'u32, 40, 41]:
    for incoming in [0'u32, 8]:
      prepare(segments, 20, retained, incoming)
      rxu_swdesc_upload_evt()
      doAssert inputCalls == 0 and desc.descCount == (segments - 1).uint8
      checkRecycled(segments, retained, incoming)
''')
