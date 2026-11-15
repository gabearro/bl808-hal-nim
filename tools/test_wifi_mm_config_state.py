"""Check MM configuration deferral against the vendor state gate."""

from pathlib import Path

import pytest

from test_wifi_channel_request_lifetime import source as lifetime_source
from test_wifi_message_allocation import run_program


def source() -> str:
    code = lifetime_source()
    code = code.replace(
        "proc ke_state_set(task: uint8; state: uint16) = mmState = state",
        """proc ke_state_set(task: uint8; state: uint16) =
  stateWrites.add(state)
  mmState = state""",
    )
    code = code.replace(
        "  if onRead != nil: onRead()\n  0\n",
        "  inc registerReads\n  if onRead != nil: onRead()\n  hardwareMode\n",
    )
    code = code.replace(
        "  doAssert address == MACHW_STATE_CNTRL_REG and value == 0\n",
        "  doAssert address == MACHW_STATE_CNTRL_REG\n  registerWrites.add(value)\n",
    )
    return r'''
var
  registerReads: int
  registerWrites: seq[uint32]
  stateWrites: seq[uint16]
  hardwareMode: uint32
''' + code + r'''
proc setup(irq: bool) =
  prepare(irq)
  keTaskDescs[0].stateCount = 4
  registerReads = 0
  registerWrites.setLen(0)
  stateWrites.setLen(0)
  hardwareMode = 3
  rxl.processingFlag = 0
'''


CASES = {
    "defer_without_side_effects": r'''
for irq in [false, true]:
  for state in [2'u16, 3]:
    for messageId in [6'u16, 8, 14, 16, 18, 20, 22, 24, 41]:
      for rxFlag in [0'u8, 1]:
        setup(irq)
        let p = if messageId == 41: issue()
                else: ke_msg_alloc(messageId, TASK_MM, 9, 16)
        let header = keMsgHdrFromPayload(p)
        let payload = cast[ptr UncheckedArray[uint8]](p)
        var beforePayload = newSeq[uint8](header.paramLen.int)
        copyMem(addr beforePayload[0], p, beforePayload.len)
        ke_msg_send(p)
        mmState = state
        mm = (hardwareMode: 3'u8, previousState: 1'u8)
        rxl.processingFlag = rxFlag
        let before = contexts
        doAssert dispatchOne() == KeMsgSaved
        doAssert mmState == state, "changed an already deferred MM state"
        doAssert mm == (hardwareMode: 3'u8, previousState: 1'u8),
          "overwrote the original resume state"
        doAssert registerReads == 0 and registerWrites.len == 0
        doAssert stateWrites.len == 0 and idleRequests == 0
        doAssert rxl.processingFlag == rxFlag
        doAssert contexts == before and events.len == 0 and replies == 0
        doAssert live.len == 1 and keMsgQueueSent.first == nil
        doAssert keMsgQueueSaved.first == header and keMsgQueueSaved.last == header
        for i, value in beforePayload: doAssert payload[i] == value
        if messageId == 41: doAssert chanUpdateAdmit(p)
        finish()
''',
    "consecutive_requests": r'''
for irq in [false, true]:
  setup(irq)
  let first = issue(1)
  let second = issue(2)
  ke_msg_send(first)
  ke_msg_send(second)
  mmState = 1
  doAssert dispatchOne() == KeMsgSaved
  doAssert mmState == 2 and idleRequests == 1 and registerReads == 1
  doAssert mm == (hardwareMode: 3'u8, previousState: 1'u8)
  doAssert stateWrites == @[2'u16] and registerWrites.len == 0
  doAssert dispatchOne() == KeMsgSaved
  doAssert mmState == 2 and idleRequests == 1 and registerReads == 1
  doAssert mm == (hardwareMode: 3'u8, previousState: 1'u8)
  doAssert stateWrites == @[2'u16] and registerWrites.len == 0
  doAssert live.len == 2 and replies == 0 and events.len == 0
  doAssert keMsgQueueSaved.first == keMsgHdrFromPayload(first)
  doAssert keMsgQueueSaved.last == keMsgHdrFromPayload(second)
  doAssert chanUpdateAdmit(first) and chanUpdateAdmit(second)

  hardwareMode = 0
  resumeSaved()
  doAssert dispatchOne() == KeMsgConsumed
  doAssert contexts[1].channel == definition(request(1))
  doAssert contexts[2].channel != definition(request(2))
  doAssert replies == 1 and live.len == 1 and mmState == 1
  doAssert registerWrites == @[0x30'u32]

  hardwareMode = 3
  doAssert dispatchOne() == KeMsgSaved
  doAssert replies == 1 and idleRequests == 2 and registerReads == 3
  doAssert mm == (hardwareMode: 3'u8, previousState: 1'u8)
  hardwareMode = 0
  resumeSaved()
  doAssert dispatchOne() == KeMsgConsumed
  doAssert contexts[2].channel == definition(request(2))
  doAssert replies == 2 and live.len == 0 and mmState == 1
  doAssert registerReads == 4 and registerWrites == @[0x30'u32, 0x30]
  doAssert stateWrites == @[2'u16, 1, 2, 1]
  doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
  finish()
''',
    "host_bypass_resume": r'''
for irq in [false, true]:
  setup(irq)
  let p = issue()
  ke_msg_send(p)
  mmState = 3
  mm = (hardwareMode: 3'u8, previousState: 1'u8)
  doAssert dispatchOne() == KeMsgSaved
  doAssert mmState == 3 and registerReads == 0 and idleRequests == 0
  hardwareMode = 0
  resumeSaved()
  doAssert dispatchOne() == KeMsgConsumed
  doAssert contexts[1].channel == definition(request(1))
  doAssert replies == 1 and live.len == 0 and mmState == 1
  doAssert registerReads == 1 and registerWrites == @[0x30'u32]
  doAssert stateWrites == @[1'u16]
  finish()
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_mm_configuration_state(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
