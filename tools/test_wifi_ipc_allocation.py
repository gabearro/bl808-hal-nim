"""Exercise inbound IPC allocation and shared-memory bounds without hardware."""

from pathlib import Path
import re

import pytest

from test_wifi_message_allocation import FW, PLATFORM, run_program
from test_wifi_ap_teardown import procedure


IPC_PLATFORM = r'''
const
  TASK_API = 9'u8
  WifiIpcMsgDrainLimit = 8'u32
  IPC_EMB_UNMASK_SET = 0x2480010C'u
type
  CoList = object
    first, last: pointer
'''

IPC_HELPERS = r'''
var
  ipcSharedEnv: array[2359, uint32]
  env: IpcEmbEnvView
  status: uint32
  writes: seq[tuple[address: uint, value: uint32]]
  sent: pointer
  clears, copies, sendCount, messagesWanted: int
  nimFwDbgIpcMsgYield, nimFwDbgIpcMsgYieldStatus: uint32
proc ipcEmbEnvView(): ptr IpcEmbEnvView = addr env
proc ipcSharedEnvView(): ptr IpcSharedEnvView = cast[ptr IpcSharedEnvView](addr ipcSharedEnv[0])
template ipcPayloadWordStreamAt(p: pointer): ptr IpcPayloadWordStreamView =
  cast[ptr IpcPayloadWordStreamView](p)
proc nimFwTrace(message: cstring) = discard
proc regRead(address: uint): uint32 =
  doAssert address == 0x24800104'u
  status
proc regWrite(address: uint; value: uint32) =
  writes.add((address, value))
  if address == 0x24800108'u: status = status and not value
proc ke_evt_clear(event: uint32) =
  doAssert event == 0x10000000
  inc clears
proc ke_msg_send(p: pointer) =
  if sent == nil: sent = p
  inc sendCount
  doAssert sendCount <= messagesWanted
  if sendCount < messagesWanted: status = 2
proc setup(length: uint32; destination = 2'u8) =
  reset()
  ipcSharedEnv = default(typeof(ipcSharedEnv))
  let shared = ipcSharedEnvView()
  shared.id = 0x1234
  shared.dstId = destination
  shared.paramLen = length
  for i in 0 ..< shared.payloadArea.len: shared.payloadArea[i] = (i mod 251).uint8
  env = IpcEmbEnvView(counter: 7)
  status = 2
  writes.setLen(0)
  sent = nil
  clears = 0
  copies = 0
  sendCount = 0
  messagesWanted = 1
'''

CHECKS = r'''
for length in [0'u32, 1, 2, 3, 4, 5, 64, 499, 500]:
  for destination in 0'u8 .. 8:
    setup(length, destination)
    ipc_emb_msg_evt()
    doAssert sent != nil and allocationCalls == 1 and assertions == 0
    let header = keMsgHdrFromPayload(sent)
    doAssert header.id == 0x1234 and header.destId == destination
    doAssert header.srcId == TASK_API and header.paramLen == length
    let bytes = cast[ptr UncheckedArray[uint8]](sent)
    for i in 0 ..< length.int: doAssert bytes[i] == (i mod 251).uint8
    for i in length.int ..< length.int + 4:
      doAssert bytes[i] == 0xA5, $length & ":" & $i & ":" & $bytes[i]
    doAssert env.counter == 8 and ipcSharedEnvView().srcId == 7
    doAssert clears == 1 and writes == @[(0x24800108'u, 2'u32),
      (0x24800100'u, 4'u32), (IPC_EMB_UNMASK_SET, 2'u32)]

for length in [501'u32, 860, 0x24C0, 0x24C1, 0xFFFFFFF0'u32, 0xFFFFFFFF'u32]:
  setup(length)
  ipc_emb_msg_evt()
  doAssert sent == nil and allocationCalls == 0 and assertions == 1
  doAssert env.counter == 7 and clears == 0
  doAssert writes == @[(0x24800108'u, 2'u32)]
for destination in [9'u8, 10, 11, 255]:
  setup(4, destination)
  ipc_emb_msg_evt()
  doAssert sent == nil and allocationCalls == 0 and assertions == 1
  doAssert env.counter == 7 and clears == 0

setup(4, 8)
env.counter = 255
ipc_emb_msg_evt()
doAssert sent != nil and allocationCalls == 1 and assertions == 0
doAssert keMsgHdrFromPayload(sent).destId == 8
doAssert ipcSharedEnvView().srcId == 255 and env.counter == 0
for missing in [false, true]:
  setup(4)
  failAllocation = true
  missingAllocator = missing
  ipc_emb_msg_evt()
  doAssert sent == nil and assertions == 1 and env.counter == 7
  doAssert allocationCalls == (not missing).int and clears == 0
  doAssert writes == @[(0x24800108'u, 2'u32)]

setup(4)
messagesWanted = WifiIpcMsgDrainLimit.int + 2
ipc_emb_msg_evt()
doAssert sendCount == WifiIpcMsgDrainLimit.int
doAssert allocationCalls == sendCount and assertions == 0
doAssert status == 2 and clears == 0
doAssert nimFwDbgIpcMsgYield == 1 and nimFwDbgIpcMsgYieldStatus == 2
doAssert env.counter == 7'u8 + WifiIpcMsgDrainLimit.uint8
doAssert writes.len == sendCount * 2
ipc_emb_msg_evt()
doAssert sendCount == messagesWanted and allocationCalls == messagesWanted
doAssert status == 0 and clears == 1 and assertions == 0
doAssert env.counter == 7'u8 + messagesWanted.uint8
doAssert ipcSharedEnvView().srcId == env.counter - 1
doAssert writes[^1] == (IPC_EMB_UNMASK_SET, 2'u32)

for length in [0'u32, 1, 2, 3, 4, 5, 64, 499, 500]:
  setup(0)
  var message: array[0x24C0 + 8, uint8]
  let envelope = cast[ptr IpcEmbMsgEnvelopeView](addr message[0])
  envelope.desc.id = 0x5678
  envelope.desc.dstId = 3
  envelope.desc.srcId = 9
  envelope.desc.paramLen = length
  for i in 0 ..< length.int: message[i + 8] = (250 - (i mod 251)).uint8
  let shared = ipcSharedEnvView()
  for value in shared.payloadArea.mitems: value = 0xA5
  ipc_emb_msg_push(envelope)
  doAssert shared.id == 0x5678 and shared.dstId == 3 and shared.srcId == 9
  doAssert shared.paramLen == length and assertions == 0
  for i in 0 ..< length.int: doAssert shared.payloadArea[i] == message[i + 8]
  for i in length.int ..< shared.payloadArea.len: doAssert shared.payloadArea[i] == 0xA5
  doAssert writes == @[(0x24800100'u, 4'u32)]
setup(0)
var invalid: IpcEmbMsgDescView
invalid.paramLen = 0x24C1
ipc_emb_msg_push(addr invalid)
doAssert assertions == 1 and writes.len == 0 and ipcSharedEnvView().id == 0x1234
for length in [501'u32, 860, 0x24C0]:
  invalid.paramLen = length
  ipc_emb_msg_push(addr invalid)
  doAssert writes.len == 0 and ipcSharedEnvView().id == 0x1234
doAssert assertions == 4
ipc_emb_msg_push(nil)
doAssert assertions == 4
reset()
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ipc_allocation_and_bounds(tmp_path: Path, mode: str) -> None:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["IpcSharedMsgView", "IpcSharedEnvView", "IpcEmbEnvView", "IpcPayloadWordStreamView",
                 "IpcEmbMsgDescView", "IpcEmbMsgEnvelopeView"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    ipc = (FW / "ipc_embedded.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = PLATFORM + IPC_PLATFORM + types + IPC_HELPERS
    code += procedure(kernel, "ke_msg_try_alloc")
    copy_words = re.search(r"(?ms)^proc copyIpcPayloadWords\b.*?(?=^template |^proc |\Z)", layout)
    assert copy_words is not None
    code += copy_words.group(0)
    code += procedure(ipc, "ipcMessagePayloadFits")
    code += procedure(ipc, "ipcMessagePending")
    code += procedure(ipc, "ipc_emb_msg_push")
    code += procedure(ipc, "ipc_emb_msg_evt")
    run_program(tmp_path, mode, code + CHECKS)
