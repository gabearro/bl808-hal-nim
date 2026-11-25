"""Check MM PS-option assertion provenance: a rejected request changes
nothing but is still answered, so its requester is not left waiting."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    handler = procedure((FW / "task_handlers.nim").read_text(),
                        "mm_set_ps_options_req_handler")
    return layouts("MmSetPsOptionsReqPayload") + r'''
const
  MAX_VIFS = 2
  MM_SET_PS_OPTIONS_CFM = 58'u16
  MmSetPsOptionsReqPayloadSize = sizeof(MmSetPsOptionsReqPayload).uint32
  KeMsgConsumed = 0.cint
type
  Header = object
    paramLen: uint32
  Request = object
    header: Header
    payload: MmSetPsOptionsReqPayload
  Vif = object
    vifType: uint8
    listenInterval: uint16
    psOptions: uint8
var
  request: Request
  vifs: array[MAX_VIFS, Vif]
  assertions: seq[tuple[condition, file: string, line: cint]]
  replies: int
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  doAssert p == addr request.payload
  addr request.header
proc mmSetPsOptionsReqView(p: pointer): ptr MmSetPsOptionsReqPayload =
  cast[ptr MmSetPsOptionsReqPayload](p)
proc smStaleRequest(p: pointer): bool = false
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc assert_err(condition, file: cstring; line: cint) =
  assertions.add(($condition, $file, line))
proc ke_msg_send_basic_reply(p: pointer; id: uint16) =
  doAssert p == cast[pointer](addr request.payload)
  doAssert id == MM_SET_PS_OPTIONS_CFM
  inc replies
''' + handler


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ps_options_assertion(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for vifType in [0'u8, 1, 2]:
  request = Request(header: Header(paramLen: MmSetPsOptionsReqPayloadSize),
                    payload: MmSetPsOptionsReqPayload(vifIdx: 0,
                      listenInterval: 42, options: 5))
  vifs[0] = Vif(vifType: vifType, listenInterval: 77, psOptions: 88)
  assertions.setLen(0)
  replies = 0
  doAssert mm_set_ps_options_req_handler(addr request.payload) == KeMsgConsumed
  if vifType == 0:
    doAssert assertions.len == 0 and replies == 1
    doAssert vifs[0].listenInterval == 42 and vifs[0].psOptions == 5
  else:
    doAssert assertions == @[("vif_entry->type == VIF_STA", "module", 1680.cint)]
    doAssert replies == 1
    doAssert vifs[0].listenInterval == 77 and vifs[0].psOptions == 88
# An out-of-range VIF index is answered without touching any VIF.
request.payload.vifIdx = MAX_VIFS
assertions.setLen(0)
replies = 0
doAssert mm_set_ps_options_req_handler(addr request.payload) == KeMsgConsumed
doAssert assertions.len == 0 and replies == 1
''')
