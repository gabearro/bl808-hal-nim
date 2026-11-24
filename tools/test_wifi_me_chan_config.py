"""Check ME channel-config copy bounds and confirmation routing."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_me_chan_config(tmp_path: Path, mode: str) -> None:
    handler = procedure((FW / "task_handlers.nim").read_text(),
                        "me_chan_config_req_handler")
    run_program(tmp_path, mode, r'''
type
  MsgHdr = object
    paramLen: uint32
    destId, srcId: uint8
  Request = object
    header: MsgHdr
    data: array[86, uint8]
  MeEnv = object
    chanConfig: array[86, uint8]
    sentinel: uint32
const
  ME_CHAN_CONFIG_CFM = 0xC03'u16
  KeMsgConsumed = 0.cint
var
  request: Request
  me: MeEnv
  replies: seq[tuple[id: uint16, dest, src: uint8]]
proc keMsgHdrFromPayload(p: pointer): ptr MsgHdr =
  doAssert p == addr request.data[0]
  addr request.header
proc meEnvView(): ptr MeEnv = addr me
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
proc ke_msg_send_basic(id: uint16; dest, src: uint8) =
  replies.add((id, dest, src))
''' + handler + r'''
for i in 0 ..< request.data.len:
  request.data[i] = (i xor 0xA5).uint8
request.header.destId = 3
request.header.srcId = 9
for size in 0'u32 .. 85'u32:
  request.header.paramLen = size
  me = MeEnv(sentinel: 0x12345678'u32)
  replies.setLen(0)
  doAssert me_chan_config_req_handler(addr request.data[0]) == KeMsgConsumed
  doAssert me.chanConfig == default(array[86, uint8])
  doAssert me.sentinel == 0x12345678'u32 and replies.len == 0
doAssert me_chan_config_req_handler(nil) == KeMsgConsumed
doAssert replies.len == 0
request.header.paramLen = 86
doAssert me_chan_config_req_handler(addr request.data[0]) == KeMsgConsumed
doAssert me.chanConfig == request.data
doAssert me.sentinel == 0x12345678'u32
doAssert replies == @[(ME_CHAN_CONFIG_CFM, 9'u8, 3'u8)]
''')
