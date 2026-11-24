"""Check MM configuration deferral against the vendor state gate."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_channel_request_lifetime import source as lifetime_source
from test_wifi_message_allocation import run_program


def source() -> str:
    code = lifetime_source()
    body = procedure((FW / "task_handlers.nim").read_text(), "mm_hw_config_handler")
    restore = "\n  # Restore local MM state"
    default_start = body.rfind("\n  else:\n    assert_err(\"0\"", 0, body.index(restore))
    assert default_start >= 0
    default_branch = body[default_start:body.index(restore)]
    code = code.replace("\n  else: doAssert false" + restore,
                        default_branch + restore, 1)
    assert default_branch + restore in code
    code = code.replace("proc assert_err(a, b: cstring; line: int) = doAssert false",
                        "proc assert_err(a, b: cstring; line: int) =\n"
                        "  inc assertions\n"
                        "  assertionDetails.add(($a, $b, line))", 1)
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
  assertions: int
  assertionDetails: seq[tuple[condition, file: string, line: int]]
  registerReads: int
  registerWrites: seq[uint32]
  stateWrites: seq[uint16]
  hardwareMode: uint32
''' + code + r'''
proc setup(irq: bool) =
  prepare(irq)
  keTaskDescs[0].stateCount = 4
  registerReads = 0
  assertions = 0
  assertionDetails.setLen(0)
  registerWrites.setLen(0)
  stateWrites.setLen(0)
  hardwareMode = 3
  rxl.processingFlag = 0
'''


CASES = {
    "assertions_stop_hardware_restore": r'''
for irq in [false, true]:
  setup(irq)
  hardwareMode = 0
  mmState = TaskIdleState
  let unknown = ke_msg_alloc(99, TASK_MM, 9, 16)
  doAssert mm_hw_config_handler(unknown) == KeMsgConsumed
  doAssert assertions == 1 and registerWrites.len == 0 and stateWrites.len == 0
  doAssert assertionDetails[0] == ("0", "module", 1563)
  ke_msg_free(keMsgHdrFromPayload(unknown))
  finish()

  setup(irq)
  hardwareMode = 0
  mmState = TaskIdleState
  mm.hardwareMode = 16
  let known = issue()
  ke_msg_send(known)
  doAssert dispatchOne() == KeMsgConsumed
  doAssert assertions == 1, "invalid saved mode was not asserted"
  doAssert assertionDetails[0] ==
    ("(((uint32_t)nextstate << 4) & ~((uint32_t)0x000000F0)) == 0",
     "module", 1465)
  doAssert registerWrites.len == 0, "invalid saved mode wrote MAC state"
  doAssert stateWrites.len == 0, "invalid saved mode restored MM state"
  finish()
''',
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
  doAssert stateWrites == @[2'u16, 0, 1, 2, 0, 1]
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
  doAssert stateWrites == @[0'u16, 1]
  finish()
''',
    "abandoned_idle_owner": r'''
for irq in [false, true]:
  for retireBeforeIdle in [false, true]:
    setup(irq)
    hardwareMode = 0x33
    mmState = 1
    let p = issue()
    let header = keMsgHdrFromPayload(p)
    ke_msg_send(p)
    doAssert dispatchOne() == KeMsgSaved
    doAssert mmState == 2 and mmConfigIdle.owner == header
    let original = contexts
    if retireBeforeIdle:
      doAssert co_list_pop_front(addr keMsgQueueSaved) == header
      ke_msg_free(header)
      doAssert registerWrites.len == 0 and mmState == 2
    else:
      inc chanCtxtEpochs[1]
    hardwareMode = 0
    resumeSaved()
    if not retireBeforeIdle:
      doAssert dispatchOne() == KeMsgConsumed
    doAssert registerWrites == @[0x30'u32] and stateWrites == @[2'u16, 0, 1]
    doAssert mmConfigIdle.phase == mmConfigNoIdle and mmConfigIdle.owner == nil
    doAssert contexts == original and replies == 0 and live.len == 0
    ke_task_schedule()
    doAssert registerWrites.len == 1 and mmState == 1
    finish()
''',
    "unrelated_request_does_not_steal_abandoned_restore": r'''
for irq in [false, true]:
  for followerValid in [false, true]:
    setup(irq)
    let owner = issue(1)
    mmState = 1
    ke_msg_send(owner)
    doAssert dispatchOne() == KeMsgSaved
    let follower = issue(2)
    ke_msg_send(follower)
    if followerValid: inc chanCtxtEpochs[1]
    else: inc chanCtxtEpochs[2]
    hardwareMode = 0
    resumeSaved()
    doAssert dispatchOne() == KeMsgConsumed
    if followerValid:
      doAssert registerWrites == @[0x30'u32] and mmState == 1 and replies == 1
      doAssert mmConfigIdle.phase == mmConfigNoIdle
    else:
      doAssert registerWrites.len == 0 and mmState == 0 and replies == 0
      doAssert mmConfigIdle.owner == keMsgHdrFromPayload(owner)
    doAssert dispatchOne() == KeMsgConsumed
    doAssert registerWrites == @[0x30'u32] and mmState == 1 and replies == 1
    doAssert mmConfigIdle.phase == mmConfigNoIdle
    finish()
''',
    "reset_cancels_stale_idle_restore": r'''
for irq in [false, true]:
  for idleBeforeReset in [false, true]:
    setup(irq)
    let p = issue()
    mmState = 1
    ke_msg_send(p)
    doAssert dispatchOne() == KeMsgSaved
    inc chanCtxtEpochs[1]
    hardwareMode = 0
    if idleBeforeReset: resumeSaved()
    mmConfigCancelIdle()
    if not idleBeforeReset: resumeSaved()
    doAssert dispatchOne() == KeMsgConsumed
    doAssert registerWrites.len == 0 and mmState == 0 and replies == 0
    finish()
''',
    "old_idle_event_cannot_override_active_bypass_or_recovery": r'''
for irq in [false, true]:
  setup(irq)
  for state in [1'u16, 3]:
    mmState = state
    mm_hw_idle_evt()
    doAssert mmState == state and stateWrites.len == 0
  let p = issue()
  mmState = 1
  ke_msg_send(p)
  doAssert dispatchOne() == KeMsgSaved
  hardwareMode = 0
  mmConfigTestEvents = 0x80000000'u32
  mm_hw_idle_evt()
  doAssert mmState == 2 and mmConfigIdle.phase == mmConfigAwaitIdle
  doAssert registerWrites.len == 0 and stateWrites == @[2'u16]
  mmConfigCancelIdle()
  finish()
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_mm_configuration_state(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
