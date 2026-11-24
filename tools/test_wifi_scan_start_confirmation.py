"""Check SCAN replies and their association with the queued SCANU request."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


TASKS = ROOT / "src/bl808/wifi/fw/task_handlers.nim"

def exchange_source() -> str:
    scan = (TASKS.parent / "scan_station_ap_me.nim").read_text()
    exchange = scan.split("type ScanuLowerExchange", 1)[1].split("proc scanuRequestCurrent", 1)[0]
    return "type ScanuLowerExchange" + exchange.replace(" {.wifiCtrl.}", "")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_scan_start_confirmation_length(tmp_path: Path, mode: str) -> None:
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
  message: Message
  lowerRequest, upperRequest, otherReply, terminal: uint8
  scanu_env: tuple[paramPtr: pointer]
  scanuRequestEpoch: uint32
  confirms: seq[uint8]
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  doAssert p == addr message.payload
  addr message.header
proc statusCfmView(p: pointer): ptr Status =
  doAssert p == addr message.payload
  addr message.payload
proc scanu_confirm(status: uint8) = confirms.add(status)
'''
    source += exchange_source() + handler
    source += r'''
doAssert scan_start_cfm_handler(nil) == KeMsgConsumed
doAssert confirms.len == 0
scanu_env.paramPtr = addr upperRequest
scanuLower = ScanuLowerExchange(request: addr lowerRequest, epoch: scanuRequestEpoch)
message.payload.status = 7
message.header.paramLen = 0
scanuTrackLowerReply(addr lowerRequest, addr message.payload, done = false)
doAssert scan_start_cfm_handler(addr message.payload) == KeMsgConsumed
doAssert confirms.len == 0
message.header.paramLen = StatusCfmPayloadSize
message.payload.status = 0
scanuTrackLowerReply(addr lowerRequest, addr message.payload, done = false)
doAssert scan_start_cfm_handler(addr message.payload) == KeMsgConsumed
doAssert confirms.len == 0
message.payload.status = 7
scanuTrackLowerReply(addr lowerRequest, addr message.payload, done = false)
doAssert scan_start_cfm_handler(addr otherReply) == KeMsgConsumed
doAssert confirms.len == 0
doAssert scan_start_cfm_handler(addr message.payload) == KeMsgConsumed
doAssert scan_start_cfm_handler(addr message.payload) == KeMsgConsumed
doAssert confirms == @[7'u8]
scanuTrackLowerReply(addr lowerRequest, addr message.payload, done = false)
scanuTrackLowerReply(addr lowerRequest, addr terminal, done = true)
inc scanuRequestEpoch # same upper request address, different owner
doAssert scan_start_cfm_handler(addr message.payload) == KeMsgConsumed
doAssert not scanuClaimLowerReply(addr terminal, done = true)
doAssert confirms == @[7'u8]

# New phase in the same upper generation must not accept the previous phase.
scanuLower = ScanuLowerExchange(request: addr lowerRequest, epoch: scanuRequestEpoch)
scanuTrackLowerReply(addr lowerRequest, addr terminal, done = true)
doAssert scanuClaimLowerReply(addr terminal, done = true)
doAssert not scanuClaimLowerReply(addr terminal, done = true)
'''
    run_program(tmp_path, mode, source)
