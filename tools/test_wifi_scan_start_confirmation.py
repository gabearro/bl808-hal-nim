"""Check SCAN_START_CFM against the lower request SCANU waits on."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure, scan_machine_source
from test_wifi_message_allocation import run_program


TASKS = ROOT / "src/bl808/wifi/fw/task_handlers.nim"


def exchange_source() -> str:
    """SCANU's one outstanding SCAN_START_REQ (scan_machine.nim): op.nim, the
    owner records and the procs that hold, send and take it. The fixture
    supplies ke_msg_send and scanu_env."""
    return (FW / "op.nim").read_text() + scan_machine_source(
        "scanuRequestCurrent", "scanuAwaits", "scanuSendLower", "scanuTakeLower")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_scan_start_confirmation_length(tmp_path: Path, mode: str) -> None:
    """TASK_SCAN refuses SCANU's lower request by answering it in place, so
    only that message ends SCANU's request; its separate success
    confirmation, another reply, a duplicate or a reply after SCANU moved on
    changes nothing."""
    handler = procedure(TASKS.read_text(), "scan_start_cfm_handler")
    source = r'''
const
  KeMsgConsumed = 0.cint
  StatusCfmPayloadSize = 1'u32
type
  Header = object
    paramLen: uint32
  Status = object
    status: uint8
  Message = object
    header: Header
    payload: Status
var
  lower, success, other: Message
  scanu_env: tuple[paramPtr: pointer]
  upperRequest: uint8
  sent: seq[pointer]
  confirms: seq[uint8]
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  addr cast[ptr Message](cast[uint](p) - sizeof(Header).uint).header
proc statusCfmView(p: pointer): ptr Status = cast[ptr Status](p)
proc ke_msg_send(p: pointer) = sent.add(p)
proc scanu_confirm(status: uint8) = confirms.add(status)
'''
    source += exchange_source() + handler
    source += r'''
doAssert scan_start_cfm_handler(nil) == KeMsgConsumed
scanu_env.paramPtr = addr upperRequest
scanuSendLower(addr lower.payload)
doAssert sent == @[pointer(addr lower.payload)] and scanuAwaits(addr lower.payload)
success.payload.status = 0
success.header.paramLen = StatusCfmPayloadSize
doAssert scan_start_cfm_handler(addr success.payload) == KeMsgConsumed
other.payload.status = 7
doAssert scan_start_cfm_handler(addr other.payload) == KeMsgConsumed
doAssert confirms.len == 0 and scanuAwaits(addr lower.payload)
# The lower request answered in place with a failure ends the request once.
lower.payload.status = 8
lower.header.paramLen = StatusCfmPayloadSize
doAssert scan_start_cfm_handler(addr lower.payload) == KeMsgConsumed
doAssert scan_start_cfm_handler(addr lower.payload) == KeMsgConsumed
doAssert confirms == @[8'u8] and scanuOwn.lower == nil
# SCANU moved on (scanuGo forgets the lower request): a late answer is inert.
scanuSendLower(addr lower.payload)
scanuOwn.lower = nil
doAssert scan_start_cfm_handler(addr lower.payload) == KeMsgConsumed
doAssert confirms == @[8'u8]
'''
    run_program(tmp_path, mode, source)
