"""Keep RX timer draining and publication tied to the current descriptor generation."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_channel_capture import source as channel_source


SUPPORT = r'''
proc setupTimer() =
  setup()
  events = 0
  assertions.setLen(0)
  onAssert = nil
  timerWrites.setLen(0)
proc prepareReady(index: int; length = 24'u16; payload = true) =
  let header = rxHeaderHwDescAt(index)
  header[] = rxHeaderHwDescAt(0)[]
  header.next = nil
  header.swDesc = pointerAddrU32(rxSwTableDescAt(index))
  header.mpduLengthBytes = length
  header.frameLen = length
  header.flags = header.flags or 0x4000'u32
  if payload:
    rxPayloadHwDescAt(index)[] = rxPayloadHwDescAt(0)[]
    rxPayloadHwDescAt(index).bufferAddr = pointerAddrU32(addr buffers[index].payloadBytes[0])
    rxPayloadHwDescAt(index).bufferStart = rxPayloadHwDescAt(index).bufferAddr
    rxPayloadHwDescAt(index).frameData = addr buffers[index].payloadBytes[0]
    header.bufferChain = rxPayloadHwDescAt(index)
    header.bufferAddr = pointerAddrU32(header.bufferChain)
  else:
    header.bufferChain = nil
    header.bufferAddr = 0
proc queued(): seq[pointer] =
  var node = env.queue.first
  while node != nil:
    doAssert result.len < 41, "RX timer introduced a ready-list cycle"
    result.add(cast[pointer](node))
    node = node.next
proc markQueued(index: int) =
  let node = addr rxSwTableDescAt(index).link
  node.next = nil
  env.queue = CoList(first: node, last: node)
'''


def source() -> str:
    code = (
        "var onAssert: proc()\nvar assertions: seq[int]\n"
        "var timerWrites: seq[tuple[address: uint, value: uint32]]\n"
        + channel_source()
    )
    code = code.replace(procedure(code, "assert_rec"), r'''
proc assert_rec(condition, file: cstring; line: int) =
  inc recovered
  assertIrqs.add(interrupts)
  assertions.add(line)
  if onAssert != nil:
    let callback = onAssert
    onAssert = nil
    callback()
''', 1)
    code = code.replace(procedure(code, "regWrite"), r'''
proc regWrite(address: uint; value: uint32) =
  doAssert not interrupts
  doAssert address == 0x24B0807C'u and value == 0x000A0000'u32
  timerWrites.add((address, value))
''', 1)
    code = code.replace(procedure(code, "co_list_push_back"), r'''
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  doAssert not interrupts
  node.next = nil
  if list.last == nil: list.first = node
  else: list.last.next = node
  list.last = node
''', 1)
    return code + SUPPORT


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_recoverable_assertions_preserve_drain_progress(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for nonzeroLength in [false, true]:
  for incoming in [false, true]:
    setupTimer()
    interrupts = incoming
    prepareReady(1, if nonzeroLength: 24'u16 else: 0'u16, not nonzeroLength)
    prepareReady(2)
    rxHeaderHwDescAt(0).next = rxHeaderHwDescAt(1)
    rxHeaderHwDescAt(1).next = rxHeaderHwDescAt(2)
    env.submittedHead = rxHeaderHwDescAt(0)
    rxl_timer_int_handler()
    doAssert assertions == @[if nonzeroLength: 193 else: 227]
    doAssert assertIrqs == @[false]
    doAssert queued() == @[cast[pointer](addr rxSwTableDescAt(0).link),
                           cast[pointer](addr rxSwTableDescAt(2).link)],
      "recoverable descriptor error stopped the ready drain"
    doAssert env.submittedHead == nil and events == 0x00100000'u32
    doAssert interrupts == incoming and channelReads == 2
    doAssert timerWrites == @[(0x24B0807C'u, 0x000A0000'u32)]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_structural_abort_still_schedules_earlier_ready_frames(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for cycle in [false, true]:
  setupTimer()
  prepareReady(1)
  rxHeaderHwDescAt(0).next = rxHeaderHwDescAt(1)
  rxHeaderHwDescAt(1).next = if cycle: cast[pointer](rxHeaderHwDescAt(1)) else: cast[pointer](1)
  env.submittedHead = rxHeaderHwDescAt(0)
  rxl_timer_int_handler()
  doAssert assertions == @[193]
  doAssert assertIrqs == @[false]
  doAssert queued() == @[cast[pointer](addr rxSwTableDescAt(0).link)]
  doAssert env.submittedHead == rxHeaderHwDescAt(1)
  doAssert events == 0x00100000'u32, "earlier ready frames were left unscheduled"
  doAssert channelReads == 1 and interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_channel_callback_reset_preserves_replacement_queue(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  setupTimer()
  interrupts = incoming
  prepareReady(3)
  let descriptor = rxSwTableDescAt(0)
  onChannel = proc() =
    rx_swdesc_init()
    markQueued(0)
    env.submittedHead = rxHeaderHwDescAt(3)
    descriptor.descCount = 77
    descriptor.bufferChain = 0xC0FFEE
    events = 0
  harvest()
  doAssert descriptor.link.next == nil, "old timer appended the replacement slot twice"
  doAssert queued() == @[cast[pointer](addr descriptor.link)]
  doAssert env.submittedHead == rxHeaderHwDescAt(3)
  doAssert descriptor.descCount == 77 and descriptor.bufferChain == 0xC0FFEE
  doAssert events == 0 and channelReads == 1 and interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_cancelled_or_changed_capture_is_not_appended(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for variant in 0 .. 3:
  for incoming in [false, true]:
    setupTimer()
    interrupts = incoming
    let descriptor = rxSwTableDescAt(0)
    let header = rxHeaderHwDescAt(0)
    markQueued(2)
    onChannel = proc() =
      case variant
      of 0: rxInvalidateUpload(descriptor)
      of 1: descriptor.swDesc = rxHeaderHwDescAt(1)
      of 2: header.bufferChain = rxPayloadHwDescAt(1)
      else: header.mpduLengthBytes = 25
      descriptor.descCount = 99
    harvest()
    doAssert queued() == @[cast[pointer](addr rxSwTableDescAt(2).link)]
    doAssert descriptor.descCount == 99
    doAssert env.submittedHead == nil and channelReads == 1
    doAssert events == 0x00100000'u32 and interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_assert_callback_reset_does_not_drain_new_generation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  setupTimer()
  interrupts = incoming
  prepareReady(1, 24, false)
  prepareReady(3)
  rxHeaderHwDescAt(0).next = rxHeaderHwDescAt(1)
  env.submittedHead = rxHeaderHwDescAt(0)
  onAssert = proc() =
    rx_swdesc_init()
    markQueued(2)
    env.submittedHead = rxHeaderHwDescAt(3)
    events = 0
  rxl_timer_int_handler()
  doAssert assertions == @[193]
  doAssert assertIrqs == @[false]
  doAssert queued() == @[cast[pointer](addr rxSwTableDescAt(2).link)]
  doAssert env.submittedHead == rxHeaderHwDescAt(3)
  doAssert events == 0 and channelReads == 1 and interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_channel_exception_restores_irqs_and_schedules_prior_work(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  setupTimer()
  interrupts = incoming
  prepareReady(1)
  rxHeaderHwDescAt(0).next = rxHeaderHwDescAt(1)
  env.submittedHead = rxHeaderHwDescAt(0)
  onChannel = proc() =
    onChannel = proc() = raise newException(ValueError, "channel query stopped")
  var raised = false
  try: rxl_timer_int_handler()
  except ValueError: raised = true
  doAssert raised and interrupts == incoming and channelReads == 2
  doAssert queued() == @[cast[pointer](addr rxSwTableDescAt(0).link)]
  doAssert events == 0x00100000'u32
''')
