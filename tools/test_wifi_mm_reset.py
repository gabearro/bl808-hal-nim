"""Exercise reset ordering, interrupt restoration, and requester routing."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  TASK_API = 9'u8
  KeMsgConsumed = 0.cint
  KeMsgSaved = 2.cint
type
  Header = object
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Message = object
    header: Header
    payload: array[1, uint8]
  BlHw = object
var
  message: Message
  hw: BlHw
  interrupts, initialInterrupts: bool
  irqDepth: int
  mutateRouting, failInit, failInitResult: bool
  mmState: uint16
  events: seq[string]
  confirmations: seq[tuple[id: uint16, destination, source: uint8]]
proc nimFwTrace(text: string) = discard
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  doAssert p == addr message.payload[0]
  addr message.header
proc irqSave(): uint32 =
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
  inc irqDepth
  events.add("disable")
proc irqRestore(previous: uint32) =
  doAssert irqDepth == 1
  dec irqDepth
  interrupts = (previous and 8) != 0
  events.add("restore")
proc checkResetContext() =
  doAssert irqDepth == 1 and not interrupts
proc hal_machw_stop(): bool {.exportc, cdecl.} =
  checkResetContext()
  events.add("mac-stop")
  true
proc phy_stop() {.exportc, cdecl.} =
  checkResetContext()
  events.add("phy-stop")
proc me_init() {.exportc, cdecl.} =
  checkResetContext()
  events.add("me-init")
proc mm_init(): bool {.discardable.} =
  checkResetContext()
  doAssert events[^1] == "me-init"
  events.add("mm-init")
  if mutateRouting:
    message.header.srcId = 201
    message.header.destId = 202
  if failInit: raise newException(ValueError, "init stopped")
  if failInitResult: return false
  mmState = 7
  true
proc ke_msg_send_basic(id: uint16; destination, source: uint8) =
  doAssert irqDepth == 0 and interrupts == initialInterrupts
  doAssert mmState == 7
  confirmations.add((id, destination, source))
  events.add("confirm")
proc ke_state_set(task: uint8; state: uint16) =
  doAssert task == TASK_MM and state == MM_IDLE.uint16
  doAssert irqDepth == 0 and interrupts == initialInterrupts
  mmState = state
  events.add("idle-state")
proc sendEmpty(hardware: ptr BlHw; id: uint16; destination: uint8;
               flags: uint32; expected: uint16; cfm: pointer): cint
proc setup(enabled: bool) =
  message = Message(header: Header(id: MM_RESET_REQ, destId: TASK_MM,
                                  srcId: DRV_TASK_ID, paramLen: 0))
  interrupts = enabled
  initialInterrupts = enabled
  irqDepth = 0
  mutateRouting = false
  failInit = false
  failInitResult = false
  mmState = 255
  events.setLen(0)
  confirmations.setLen(0)
'''

SEND = r'''
proc sendEmpty(hardware: ptr BlHw; id: uint16; destination: uint8;
               flags: uint32; expected: uint16; cfm: pointer): cint =
  doAssert hardware == addr hw
  doAssert id == MM_RESET_REQ and destination == TASK_MM
  doAssert flags == 1 and expected == MM_RESET_CFM and cfm == nil
  mm_reset_req_handler(addr message.payload[0])
'''


def source() -> str:
    wifi = FW.parent
    constants = "".join((wifi / path).read_text() for path in [
        "msg_tx/layout/task_ids.nim", "msg_tx/layout/message_ids.nim", "fw_constants/states.nim"
    ])
    handler = procedure((FW / "task_handlers.nim").read_text(), "mm_reset_req_handler")
    producer = procedure((wifi / "msg_tx/mm_control_parts/lifecycle.nim").read_text(), "bl_send_reset")
    return constants + PLATFORM + handler + SEND + producer


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_producer_order_and_interrupt_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [true, false]:
  for mutate in [false, true]:
    setup(enabled)
    mutateRouting = mutate
    doAssert bl_send_reset(addr hw) == KeMsgConsumed
    doAssert events == @["disable", "mac-stop", "phy-stop", "me-init", "mm-init",
                          "restore", "confirm", "idle-state"]
    doAssert confirmations == @[(MM_RESET_CFM, DRV_TASK_ID, TASK_MM)]
    doAssert interrupts == enabled and irqDepth == 0 and mmState == MM_IDLE.uint16
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_uses_saved_requester_metadata(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for requester in [9'u8, 17, 100]:
  for enabled in [false, true]:
    setup(enabled)
    message.header.srcId = requester
    mutateRouting = true
    doAssert mm_reset_req_handler(addr message.payload[0]) == KeMsgConsumed
    doAssert confirmations == @[(MM_RESET_CFM, requester, TASK_MM)]
    doAssert events[^2 .. ^1] == @["confirm", "idle-state"]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_restores_interrupts_when_initialization_stops(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  setup(enabled)
  failInit = true
  var stopped = false
  try:
    discard mm_reset_req_handler(addr message.payload[0])
  except ValueError:
    stopped = true
  doAssert stopped and interrupts == enabled and irqDepth == 0
  doAssert events == @["disable", "mac-stop", "phy-stop", "me-init", "mm-init", "restore"]
  doAssert confirmations.len == 0 and mmState == 255
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_null_reset_has_no_side_effects(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  setup(enabled)
  doAssert mm_reset_req_handler(nil) == KeMsgConsumed
  doAssert interrupts == enabled and irqDepth == 0 and mmState == 255
  doAssert events.len == 0 and confirmations.len == 0
''')
