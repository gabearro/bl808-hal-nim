"""Exercise fixed management fields before RX sequence/replay publication."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_mgt_receive import management_source
from test_wifi_rx_mgmt_cipher import source as dispatch_source


PRODUCER_CASES = {
    "short-fixed-fields": r'''
for sample in [(2'u8, 0x0000'u16, 4), (0'u8, 0x0010'u16, 6),
               (2'u8, 0x0020'u16, 10), (0'u8, 0x0030'u16, 6),
               (0'u8, 0x0050'u16, 12), (0'u8, 0x0080'u16, 12),
               (0'u8, 0x00A0'u16, 2), (0'u8, 0x00B0'u16, 6),
               (0'u8, 0x00C0'u16, 2)]:
  let (kind, fc, minimum) = sample
  for length in 1..<minimum:
    reset(fc, 0, 4, kind)
    rx.mpduLengthBytes = (24 + length).uint16
    env.seqCtrl = 0x1230
    stations[4].nonQosSeqCtrl = 0x7770
    discard rxu_mgt_frame_check(addr desc, 4)
    doAssert sent == 0 and allocationCalls == 0 and decodes == 0 and
      policyCalls == 0 and stations[4].nonQosSeqCtrl == 0x7770,
      "short fixed fields advanced management RX state"
''',
    "short-action-fields": r'''
for sample in [(3'u8, 0'u8, 9), (3'u8, 1'u8, 9),
               (3'u8, 2'u8, 6), (8'u8, 0'u8, 4), (8'u8, 1'u8, 4)]:
  let (category, action, minimum) = sample
  for length in 1..<minimum:
    reset(0x00D0, 0, 4)
    frame.body[0] = category
    frame.body[1] = action
    rx.mpduLengthBytes = (24 + length).uint16
    env.seqCtrl = 0x1230
    stations[4].nonQosSeqCtrl = 0x7770
    discard rxu_mgt_frame_check(addr desc, 4)
    doAssert sent == 0 and allocationCalls == 0 and decodes == 0 and
      policyCalls == 0 and stations[4].nonQosSeqCtrl == 0x7770,
      "short Action body advanced management RX state"
''',
    "valid-boundaries": r'''
for sample in [(2'u8, 0x0000'u16, 4, 0'u8, 0'u8),
               (0'u8, 0x0010'u16, 6, 0'u8, 0'u8),
               (2'u8, 0x0020'u16, 10, 0'u8, 0'u8),
               (0'u8, 0x0030'u16, 6, 0'u8, 0'u8),
               (0'u8, 0x0050'u16, 12, 0'u8, 0'u8),
               (0'u8, 0x0080'u16, 12, 0'u8, 0'u8),
               (0'u8, 0x00A0'u16, 2, 0'u8, 0'u8),
               (0'u8, 0x00B0'u16, 6, 0'u8, 0'u8),
               (0'u8, 0x00C0'u16, 2, 0'u8, 0'u8),
               (0'u8, 0x00D0'u16, 9, 3'u8, 0'u8),
               (0'u8, 0x00D0'u16, 4, 8'u8, 0'u8)]:
  let (kind, fc, minimum, category, action) = sample
  reset(fc, 0, 4, kind)
  frame.body[0] = category
  frame.body[1] = action
  rx.mpduLengthBytes = (24 + minimum).uint16
  discard rxu_mgt_frame_check(addr desc, 4)
  doAssert sent == 1 and allocationCalls == 1 and policyCalls == 1,
    "minimal fixed fields did not reach the existing subtype route"
''',
}


def traced_source() -> str:
    code = management_source()
    stub = "template nimFwTrace2U32(args: varargs[untyped]) = discard\n"
    assert code.count(stub) == 1
    return code.replace(stub, r'''
proc nimFwTrace2U32(label: cstring; a, b: uint32) = discard
''', 1) + r'''
proc packetMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc packetFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}
'''


TRACE_CASE = r'''
for fc in [0x0010'u16, 0x0030'u16]:
  for length in [6, 7, 11, 12]:
    reset(fc, 0, 4)
    rx.mpduLengthBytes = (24 + length).uint16
    let packet = packetMalloc(rx.mpduLengthBytes.csize_t)
    doAssert packet != nil
    copyMem(packet, addr frame, rx.mpduLengthBytes.int)
    rx.bufferChain = packet
    try:
      discard rxu_mgt_frame_check(addr desc, 4)
      doAssert sent == 1 and allocationCalls == 1
    finally:
      packetFree(packet)
'''


DISPATCH_CASE = r'''
for associated in [false, true]:
  for enabled in [false, true]:
    for length in 1..5:
      prepare(0x40B0'u16, 20, associated, false, false, false, enabled,
              bodyLength = length)
      checkRejected(enabled)
for enabled in [false, true]:
  for length in 1..8:
    prepare(0x40D0'u16, 28, true, true, false, false, enabled,
            category = 3, bodyLength = length)
    bytes[33] = 0
    checkRejected(enabled)
  for length in 1..3:
    prepare(0x40D0'u16, 28, true, true, false, false, enabled,
            category = 8, bodyLength = length)
    checkRejected(enabled)
  for sample in [(0x40B0'u16, 20'u32, 6), (0x40D0'u16, 28'u32, 9)]:
    let (fc, cipher, length) = sample
    prepare(fc, cipher, true, cipher == 28, false, false, enabled,
            category = 3, bodyLength = length)
    if cipher == 28: bytes[33] = 0
    discard rxu_cntrl_frame_handle(addr mpdu)
    doAssert managementCalls == 1
    doAssert keySelections == (if cipher == 28: 1 else: 0)
    doAssert interrupts == enabled
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
@pytest.mark.parametrize("case", PRODUCER_CASES)
def test_producer_fixed_fields(case: str, mode: str, tmp_path: Path) -> None:
    run_program(tmp_path, mode, management_source() + PRODUCER_CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_assoc_trace_bounds(mode: str, tmp_path: Path) -> None:
    run_program(tmp_path, mode, traced_source() + TRACE_CASE)


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_dispatch_fixed_fields(mode: str, tmp_path: Path) -> None:
    run_program(tmp_path, mode, dispatch_source() + DISPATCH_CASE)
