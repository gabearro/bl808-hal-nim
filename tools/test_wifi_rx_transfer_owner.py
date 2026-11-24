"""Keep channel queries and upload preparation bound to the original RX frame."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_channel_capture import source as channel_source
from test_wifi_rx_chain import PLATFORM as CHAIN_PLATFORM, CHECKS as CHAIN_CHECKS
from test_wifi_rx_decapsulation import CHECKS, FW
from test_wifi_rx_raw import source as raw_source


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_channel_query_cannot_write_replacement_metadata(tmp_path: Path, mode: str) -> None:
    code = channel_source()
    code = code.replace(procedure(code, "phy_get_channel_raw"), r'''
proc phy_get_channel_raw(info: pointer; index: uint8) =
  inc channelReads
  if onChannel != nil:
    let action = onChannel
    onChannel = nil
    action()
  copyMem(info, addr radio[0], 8)
''', 1)
    run_program(tmp_path, mode, code + r'''
for variant in 0 .. 4:
  for incoming in [false, true]:
    setup()
    interrupts = incoming
    let descriptor = rxSwTableDescAt(0)
    let header = rxHeaderHwDescAt(0)
    onChannel = proc() =
      case variant
      of 0: rxInvalidateUpload(descriptor)
      of 1: inc stationEpochs[4]
      of 2: inc rxVifEpochs[0]
      of 3: descriptor.swDesc = rxHeaderHwDescAt(1)
      else: header.bufferChain = rxPayloadHwDescAt(1)
      descriptor.descCount = 77
      descriptor.prevDesc = cast[pointer](11)
      descriptor.curDesc = cast[pointer](12)
      header.channelInfo = [9'u8, 8, 7, 6, 5, 4, 3, 2]
    rxl_mpdu_transfer(descriptor)
    doAssert descriptor.descCount == 77
    doAssert descriptor.prevDesc == cast[pointer](11) and descriptor.curDesc == cast[pointer](12)
    doAssert header.channelInfo == [9'u8, 8, 7, 6, 5, 4, 3, 2]
    doAssert channelReads == 1 and interrupts == incoming
''')


def cancellation_source(succeeds: bool = False) -> str:
    code = raw_source(real_upload=True)
    code = code.replace("var rxGeneration: uint32\n", "")
    for name in ("rxUploadGeneration", "rxUploadCurrent"):
        if f"proc {name}(" in code:
            code = code.replace(procedure(code, name), "", 1)
    helpers = r'''
proc rxUploadGeneration(p: pointer): uint32 = rxGeneration
proc rxUploadCurrent(p: pointer; generation: uint32): bool = generation == rxGeneration
'''
    code = "var rxGeneration: uint32\n" + helpers + code
    code = code.replace(procedure(code, "rxl_mpdu_transfer"), r'''
proc rxl_mpdu_transfer(p: pointer) =
  inc transferred
  inc rxGeneration
  sw.bufferOffset = 777
''', 1)
    if "proc rxTransferFrame(" in code:
        code = code.replace(procedure(code, "rxTransferFrame"), f'''
proc rxTransferFrame(p: pointer): bool =
  inc transferred
  inc rxGeneration
  sw.bufferOffset = 777
  {str(succeeds).lower()}
''', 1)
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_cancelled_transfer_is_not_prepared_or_reported_uploaded(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, cancellation_source() + r'''
for direct in [false, true]:
  reset(0x0008, 40)
  if direct:
    envState.machdrLen = rxu_cntrl_machdr_len_get(0x0008'u16)
    rxu_mpdu_upload_and_indicate(addr mpdu)
  else:
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
  doAssert transferred == 1 and prepared == 0
  doAssert envState.uploadList.first == nil and sw.bufferOffset == 777
  doAssert interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_associated_transfer_cancellation(tmp_path: Path, mode: str) -> None:
    code = cancellation_source() + procedure(CHECKS, "snapAt")
    run_program(tmp_path, mode, code + r'''
for incoming in [false, true]:
  setup(0x0208, 24, 40)
  snapAt(24, 0x0800)
  interrupts = incoming
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
  doAssert transferred == 1 and prepared == 0
  doAssert envState.uploadList.first == nil and sw.bufferOffset == 777
  doAssert interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_recycled_transfer_success_is_not_queued(tmp_path: Path, mode: str) -> None:
    code = cancellation_source(succeeds=True) + procedure(CHECKS, "snapAt")
    run_program(tmp_path, mode, code + r'''
for route in 0 .. 2:
  for incoming in [false, true]:
    if route == 2:
      setup(0x0208, 24, 40)
      snapAt(24, 0x0800)
    else:
      reset(0x0008, 40)
    interrupts = incoming
    if route == 0:
      envState.machdrLen = rxu_cntrl_machdr_len_get(0x0008'u16)
      rxu_mpdu_upload_and_indicate(addr mpdu)
    else:
      doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
    doAssert transferred == 1 and prepared == 0
    doAssert envState.uploadList.first == nil and sw.bufferOffset == 777
    doAssert interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_channel_query_revalidates_payload_chain(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, channel_source() + r'''
for variant in 0 .. 2:
  setup()
  let descriptor = rxSwTableDescAt(0)
  let head = rxPayloadHwDescAt(0)
  let tail = rxPayloadHwDescAt(1)
  head.status = 0
  head.next = tail
  tail.status = 1
  onChannel = proc() =
    case variant
    of 0:
      tail.status = 0
      tail.next = tail
    of 1:
      tail.status = 0
      tail.next = rxPayloadHwDescAt(2)
      rxPayloadHwDescAt(2).status = 1
    else:
      head.status = 1
  rxl_mpdu_transfer(descriptor)
  doAssert interrupts and channelReads == 1
  case variant
  of 0:
    doAssert recovered == 1
    doAssert descriptor.descCount == 0 and descriptor.curDesc == nil
    doAssert descriptor.prevDesc == nil
  of 1:
    doAssert recovered == 0 and descriptor.descCount == 2
    doAssert descriptor.prevDesc == tail and descriptor.curDesc == rxPayloadHwDescAt(2)
  else:
    doAssert recovered == 0 and descriptor.descCount == 0
    doAssert descriptor.prevDesc == nil and descriptor.curDesc == head
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_prepare_requires_current_completed_transfer(tmp_path: Path, mode: str) -> None:
    code = channel_source()
    code = code.replace(procedure(code, "co_list_push_back"), r'''
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  doAssert not interrupts
  node.next = nil
  if list.last == nil: list.first = node
  else: list.last.next = node
  list.last = node
''', 1)
    code += "\nvar nimFwDbgRxuDescPrepare: uint32\n"
    code += procedure(FW.read_text(), "rxu_cntrl_desc_prepare")
    run_program(tmp_path, mode, code + r'''
for variant in 0 .. 4:
  for incoming in [false, true]:
    setup()
    upperEnv = default(RxuEnv)
    nimFwDbgRxuDescPrepare = 0
    let descriptor = rxSwTableDescAt(0)
    rxl_mpdu_transfer(descriptor)
    case variant
    of 0: discard
    of 1: descriptor.curDesc = nil
    of 2: inc stationEpochs[4]
    of 3: descriptor.swDesc = rxHeaderHwDescAt(1)
    else: inc rxVifEpochs[0]
    descriptor.descFlag = 77
    interrupts = incoming
    rxu_cntrl_desc_prepare(descriptor)
    doAssert interrupts == incoming
    if variant == 0:
      doAssert upperEnv.uploadList.first == addr descriptor.link
      doAssert upperEnv.uploadList.last == addr descriptor.link
      doAssert descriptor.descFlag == 3 and nimFwDbgRxuDescPrepare == 1
    else:
      doAssert upperEnv.uploadList.first == nil and upperEnv.uploadList.last == nil
      doAssert descriptor.descFlag == 77 and nimFwDbgRxuDescPrepare == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bounded_transfer_chain_bookkeeping(tmp_path: Path, mode: str) -> None:
    code = CHAIN_PLATFORM
    lower = (FW.parent / "rx_layer.nim").read_text()
    for name in ("rxPayloadDescIndex", "rxPayloadChainBounds", "rxl_mpdu_free",
                 "rxTransferFrame", "rxl_mpdu_transfer"):
        code += procedure(lower, name)
    code += CHAIN_CHECKS.split("\nfor count in 1 .. 41:", 1)[0]
    run_program(tmp_path, mode, code + r'''
for count in [1, 2, 4, 41]:
  for incoming in [0'u32, 8'u32]:
    reset(count)
    level = incoming
    expectedLevel = incoming
    rxPayloadHwDescAt(count - 1).next = rxPayloadHwDescAt(0)
    rxl_mpdu_transfer(addr desc)
    doAssert channelCalls == 1 and desc.descCount == (count - 1).uint8
    doAssert desc.curDesc == rxPayloadHwDescAt(count - 1)
    doAssert desc.prevDesc == (if count == 1: nil else: cast[pointer](rxPayloadHwDescAt(count - 2)))
    doAssert level == incoming and entered == 0 and exited == 0
    rxl_mpdu_free(addr desc)
    doAssert released == 1 and assertions == 0 and entered == 1 and exited == 1
    doAssert level == incoming
''')
