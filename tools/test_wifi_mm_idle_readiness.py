"""Reject MM idle/configuration completion when hardware is still active."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_mm_config_state import source as config_source


def source() -> str:
    code = config_source().replace(
        "mm: tuple[hardwareMode, previousState: uint8]",
        "mm: tuple[hardwareMode, previousState, idleFlag: uint8]",
    )
    code = code.replace(procedure(code, "assert_err"), r'''
proc assert_err(a, b: cstring; line: int) =
  inc assertions
  assertionDetails.add(($a, $b, line))
  if onAssert != nil: onAssert()
''')
    reply_stub = """proc ke_msg_send_basic_reply(p: pointer; id: uint16) =
  doAssert id == MM_CHAN_CTXT_UPDATE_CFM
  inc replies
"""
    assert reply_stub in code
    code = code.replace(reply_stub, r'''
proc ke_msg_send_basic_reply(p: pointer; id: uint16) =
  doAssert id in [MM_CHAN_CTXT_UPDATE_CFM, MM_SET_IDLE_CFM]
  inc replies
''')
    code = code.replace("  result = mm_hw_config_handler(param)",
                        "  result = if keMsgHdrFromPayload(param).id == 26:\n"
                        "      mm_set_idle_req_handler(param)\n"
                        "    else: mm_hw_config_handler(param)")
    prefix = r'''
const
  MM_ACTIVE_STATE = 1'u8
  HW_ACTIVE = 3'u8
  MM_SET_IDLE_CFM = 27'u16
  MmSetIdleReqPayloadSize = 1'u32
var onAssert: proc()
proc mm_set_idle_req_handler*(param: pointer): cint {.exportc, cdecl.}
'''
    helpers = r'''
template mmSetIdleReqView(p: pointer): ptr MmSetIdleReqPayload =
  cast[ptr MmSetIdleReqPayload](p)
proc prepareReadiness(irq: bool) =
  setup(irq)
  onAssert = nil
  mm = (hardwareMode: 3'u8, previousState: 1'u8, idleFlag: 9'u8)
proc idleRequest(idle: uint8): pointer =
  result = ke_msg_alloc(26, TASK_MM, 9, MmSetIdleReqPayloadSize)
  mmSetIdleReqView(result).idle = idle
'''
    return (prefix + layouts("MmSetIdleReqPayload") + code + helpers
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "mm_active")
            + procedure((FW / "task_handlers.nim").read_text(), "mm_set_idle_req_handler"))


REJECT_NONIDLE = r'''
const idle = IDLE_REQUEST
for irq in [false, true]:
  for reenter in [false, true]:
    for upper in [0'u32, 0xABCDEFF0'u32]:
      for low in 1'u32 .. 15:
        prepareReadiness(irq)
        hardwareMode = upper or low
        let p = if idle: idleRequest(1) else: issue()
        var expectedMm = mm
        if idle: expectedMm.idleFlag = 1
        var expectedContexts = contexts
        if reenter:
          expectedMm = (hardwareMode: 5'u8, previousState: 3'u8, idleFlag: 7'u8)
          expectedContexts[1].channel.primFreq = 2462
          onAssert = proc() =
            mm = expectedMm
            contexts = expectedContexts
            mmState = 3
        ke_msg_send(p)
        doAssert dispatchOne() == KeMsgConsumed
        doAssert assertions == 1
        doAssert assertionDetails.len == 1
        doAssert assertionDetails[0] ==
          ("blmac_current_state_getf() == HW_IDLE", "module",
           if idle: 946 else: 1527)
        doAssert mm == expectedMm, "continued updating MM after idle failure"
        doAssert mmState == (if reenter: 3'u16 else: 0'u16)
        doAssert contexts == expectedContexts and events.len == 0
        doAssert registerReads == 1 and registerWrites.len == 0
        doAssert stateWrites.len == 0 and idleRequests == 0 and replies == 0,
          "reported successful configuration after idle failure"
        doAssert live.len == 0 and keMsgQueueSent.first == nil
        doAssert keMsgQueueSaved.first == nil
        finish()
'''


CASES = {
    "explicit_idle_supersedes_pending_restore": r'''
for irq in [false, true]:
  prepareReadiness(irq)
  mmState = MM_ACTIVE_STATE
  let update = issue()
  ke_msg_send(update)
  doAssert dispatchOne() == KeMsgSaved
  doAssert mmConfigIdle.owner == keMsgHdrFromPayload(update)
  inc chanCtxtEpochs[1]
  ke_msg_send(idleRequest(1))
  hardwareMode = 0
  resumeSaved()
  doAssert dispatchOne() == KeMsgConsumed
  doAssert mm.idleFlag == 1 and mmConfigIdle.phase == mmConfigNoIdle
  doAssert dispatchOne() == KeMsgConsumed
  doAssert replies == 1 and registerWrites.len == 0 and mmState == MM_IDLE
  doAssert stateWrites == @[TaskGoingIdleState, MM_IDLE]
  finish()
''',
    "accept_idle_hardware": r'''
for irq in [false, true]:
  for idle in [false, true]:
    for hardware in [0'u32, 0xABCDEFF0'u32]:
      prepareReadiness(irq)
      hardwareMode = hardware
      let before = contexts
      let p = if idle: idleRequest(1) else: issue()
      ke_msg_send(p)
      doAssert dispatchOne() == KeMsgConsumed
      doAssert assertions == 0 and replies == 1 and registerReads == 1
      doAssert idleRequests == 0 and live.len == 0
      if idle:
        doAssert contexts == before and registerWrites.len == 0
        doAssert stateWrites.len == 0 and mmState == 0
        doAssert mm == (hardwareMode: 0'u8, previousState: 0'u8, idleFlag: 1'u8)
      else:
        doAssert contexts[1].channel == definition(request(1))
        doAssert registerWrites == @[0x30'u32] and stateWrites == @[1'u16]
        doAssert mmState == 1
        doAssert mm == (hardwareMode: 3'u8, previousState: 1'u8, idleFlag: 9'u8)
      finish()
''',
    "idle_transition_matrix": r'''
for irq in [false, true]:
  for state in 0'u16 .. 3:
    for idle in 0'u8 .. 1:
      prepareReadiness(irq)
      hardwareMode = 0
      mmState = state
      ke_msg_send(idleRequest(idle))
      let deferred = state == 3 or state == 2 or (state == 1 and idle != 0)
      doAssert dispatchOne() == (if deferred: KeMsgSaved else: KeMsgConsumed)
      doAssert assertions == 0
      doAssert mm.idleFlag == (if state == 3: 9'u8 else: idle)
      doAssert replies == (not deferred).int
      if state == 3 or state == 2:
        doAssert mmState == state and idleRequests == 0 and registerReads == 0
        doAssert stateWrites.len == 0 and registerWrites.len == 0
      elif idle == 0:
        doAssert mmState == 1 and idleRequests == 0 and registerReads == 0
        doAssert stateWrites == @[1'u16] and registerWrites == @[0x30'u32]
      elif state == 1:
        doAssert mmState == 2 and idleRequests == 1 and registerReads == 0
        doAssert stateWrites == @[2'u16] and registerWrites.len == 0
      else:
        doAssert mmState == 0 and idleRequests == 0 and registerReads == 1
        doAssert stateWrites.len == 0 and registerWrites.len == 0
      finish()
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_mm_idle_readiness(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("idle", [False, True], ids=["configuration", "idle-request"])
def test_nonidle_hardware(tmp_path: Path, mode: str, idle: bool) -> None:
    checks = REJECT_NONIDLE.replace("IDLE_REQUEST", str(idle).lower())
    run_program(tmp_path, mode, source() + checks)
