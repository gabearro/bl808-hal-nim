"""Revalidate captured RX frames after key checks at copy/publication boundaries."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
import test_wifi_rx_continuation as continuation


MODES = continuation.MODES


def source(connect_trace: bool) -> str:
    code = continuation.source(connect_trace)
    code = code.replace(procedure(code, "allocateEapol"), r'''
proc allocateEapol(length: uint32): pointer {.cdecl.} =
  inc allocations
  if not allocationFails: result = alloc(length.int)
  if onEapolAllocation != nil: onEapolAllocation()
''', 1)
    copy = procedure(code, "rxuCopyFrameBytes")
    code = code.replace(copy, copy.replace("proc rxuCopyFrameBytes(", "proc copyFrameBytesImpl(", 1) + r'''
proc rxuCopyFrameBytes(swdesc: ptr RxSwDescView; offset, length: uint32;
                       destination: pointer): bool =
  inc copyCalls
  copyFrameBytesImpl(swdesc, offset, length, destination)
''', 1)
    code = code.replace(procedure(code, "ke_msg_alloc"), r'''
proc ke_msg_alloc(id: uint16; dst, src, length: int): pointer =
  doAssert id == 0xC04 and dst == 9 and src == 3 and length == 24
  inc notificationAllocations
  result = addr notificationWords[2]
  if onNotificationAllocation != nil: onNotificationAllocation()
''', 1)
    code = code.replace(procedure(code, "ke_msg_free_payload"), r'''
proc ke_msg_free_payload(p: pointer) =
  doAssert p == addr notificationWords[2]
  inc notificationFrees
''', 1)
    code = code.replace(procedure(code, "ke_msg_send"), r'''
proc ke_msg_send(p: pointer) =
  doAssert p == addr notificationWords[2]
  inc notificationSends
''', 1)
    return r'''
const NotificationCanary = 0xA5A5A5A5'u32
var
  onEapolAllocation, onNotificationAllocation: proc()
  copyCalls, notificationAllocations, notificationFrees, notificationSends: int
  notificationWords: array[10, uint32]
''' + code + r'''
var tailChain: Chain

proc prepareDelivery(fc: uint16; cipher, length: int; ap, enabled: bool;
                     protocol = 0x888E'u16) =
  onEapolAllocation = nil
  onNotificationAllocation = nil
  copyCalls = 0
  notificationAllocations = 0
  notificationFrees = 0
  notificationSends = 0
  for value in notificationWords.mitems: value = NotificationCanary
  prepareFrame(fc, cipher, protocol, ap, enabled)
  let headerLength = rxu_cntrl_machdr_len_get(fc).int + (if cipher == 0: 0 else: 8)
  sw.mpduLengthBytes = (headerLength + 8 + length).uint16
  snapAt(headerLength, protocol)
  if cipher == 1:
    for i in 0 ..< 8: bytes[sw.mpduLengthBytes.int + i] = (i + 1).uint8
    sw.mpduLengthBytes += 8
  tailChain = Chain(frameData: addr bytes[1736])
  if sw.mpduLengthBytes > 1736: chain.next = addr tailChain

proc dataOffset(fc: uint16; cipher: int): int =
  rxu_cntrl_machdr_len_get(fc).int + (if cipher == 0: 0 else: 8) + 8

proc checkPrivateNotification() =
  doAssert notificationWords[0] == NotificationCanary and notificationWords[1] == NotificationCanary
  doAssert notificationWords[8] == NotificationCanary and notificationWords[9] == NotificationCanary
'''


@pytest.mark.parametrize("mode", MODES)
@pytest.mark.parametrize("connect_trace", [True, False], ids=["trace", "untraced"])
def test_eapol_final_key_check_rejects_replaced_frame(tmp_path: Path, mode: str,
                                                    connect_trace: bool) -> None:
    run_program(tmp_path, mode, source(connect_trace) + r'''
for ap in [false, true]:
  for baseFc in [0x0008'u16, 0x0088, 0x0388, 0x8388]:
    let fc = baseFc or (if ap: 0x0100'u16 else: 0x0200'u16)
    let contiguous = 1736 - dataOffset(fc, 2)
    for length in [4, 32, contiguous, contiguous + 1, 1800]:
      for kind in 0 .. 3:
        prepareDelivery(fc, 2, length, ap, true)
        # Eligible IRQ entries: protected-header check, commit, optional copy
        # key check, then the final key check immediately before delivery.
        pendingIrqs = if length > contiguous: 4 else: 3
        onRxIrq = proc() = replaceFrame(kind)
        doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
        checkReplacement()
        doAssert eapolCalls == 0, "EAPOL delivered after key validation replaced its frame"
        doAssert frees == allocations and allocations == (length > contiguous).int
        doAssert notificationAllocations == 0 and pendingIrqs == 0 and interrupts
''')


@pytest.mark.parametrize("mode", MODES)
@pytest.mark.parametrize("connect_trace", [True, False], ids=["trace", "untraced"])
def test_scatter_copy_key_check_rejects_replaced_frame(tmp_path: Path, mode: str,
                                                     connect_trace: bool) -> None:
    run_program(tmp_path, mode, source(connect_trace) + r'''
for ap in [false, true]:
  for baseFc in [0x0008'u16, 0x0088, 0x0388, 0x8388]:
    let fc = baseFc or (if ap: 0x0100'u16 else: 0x0200'u16)
    for length in [1737 - dataOffset(fc, 2), 1800]:
      for kind in 0 .. 3:
        prepareDelivery(fc, 2, length, ap, true)
        onEapolAllocation = proc() =
          pendingIrqs = 1
          onRxIrq = proc() = replaceFrame(kind)
        doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
        checkReplacement()
        doAssert copyCalls == 0, "scatter copy borrowed bytes from a replaced RX frame"
        doAssert allocations == 1 and frees == 1 and eapolCalls == 0
        doAssert notificationAllocations == 0 and pendingIrqs == 0 and interrupts
''')


@pytest.mark.parametrize("mode", MODES)
@pytest.mark.parametrize("connect_trace", [True, False], ids=["trace", "untraced"])
def test_mic_notification_key_check_rejects_replaced_frame(tmp_path: Path, mode: str,
                                                         connect_trace: bool) -> None:
    run_program(tmp_path, mode, source(connect_trace) + r'''
for ap in [false, true]:
  for baseFc in [0x0008'u16, 0x0088, 0x0388, 0x8388]:
    let fc = baseFc or (if ap: 0x0100'u16 else: 0x0200'u16)
    for kind in 0 .. 3:
      prepareDelivery(fc, 1, 32, ap, true, 0x0800)
      badMic = true
      onNotificationAllocation = proc() =
        pendingIrqs = 1
        onRxIrq = proc() = replaceFrame(kind)
      doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
      checkReplacement()
      doAssert notificationAllocations == 1 and notificationSends == 0,
        "MIC notification published after key validation replaced its frame"
      doAssert notificationFrees == 1 and copyCalls == 0 and allocations == 0
      for word in notificationWords: doAssert word == NotificationCanary
      doAssert pendingIrqs == 0 and interrupts
''')


@pytest.mark.parametrize("mode", MODES)
@pytest.mark.parametrize("connect_trace", [True, False], ids=["trace", "untraced"])
def test_current_handoffs_and_allocation_failures(tmp_path: Path, mode: str,
                                                connect_trace: bool) -> None:
    run_program(tmp_path, mode, source(connect_trace) + r'''
for enabled in [false, true]:
  for ap in [false, true]:
    for baseFc in [0x0008'u16, 0x0088, 0x0388, 0x8388]:
      let fc = baseFc or (if ap: 0x0100'u16 else: 0x0200'u16)
      for cipher in [0, 2]:
        let offset = dataOffset(fc, cipher)
        let contiguous = 1736 - offset
        for length in [4, 32, contiguous, contiguous + 1, 1800]:
          prepareDelivery(fc, cipher, length, ap, enabled)
          onEapolAllocation = proc() =
            inc stationEpochs[1]
            inc rxVifEpochs[1]
          doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
          doAssert eapolCalls == 1 and eapolLength == length.uint32
          for i in 0 ..< length: doAssert eapolBytes[i] == bytes[offset + i]
          doAssert allocations == (length > contiguous).int and frees == allocations
          doAssert copyCalls == allocations and notificationAllocations == 0
          doAssert interrupts == enabled and not replacementSeen
          if length > contiguous:
            prepareDelivery(fc, cipher, length, ap, enabled)
            allocationFails = true
            doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
            doAssert allocations == 1 and frees == 0 and eapolCalls == 0 and copyCalls == 0
            doAssert interrupts == enabled
      prepareDelivery(fc, 1, 32, ap, enabled, 0x0800)
      badMic = true
      doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
      doAssert notificationAllocations == 1 and notificationSends == 1 and notificationFrees == 0
      doAssert eapolCalls == 0 and copyCalls == 0 and transferred == 0 and replayCalls == 0
      let msg = rxMicFailureIndAt(addr notificationWords[2])
      doAssert msg.bssid == stations[0].macAddr and msg.vifIdx == 0
      checkPrivateNotification()
      doAssert interrupts == enabled
''')
