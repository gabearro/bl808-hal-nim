"""Check delete-request forwarding, reply routing, and allocation ownership."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import TIM_METADATA_STUBS

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r'''
const
  TASK_MM = 0'u8
  TASK_ME = 3'u8
  TASK_API = 9'u8
  TASK_SM = 4'u8
  MAX_VIFS = 2
  STA_MGMT_FREE_STAS = 5
  VIF_TYPE_STA = 0'u8
  SmIdleState = 0'u16
  MM_SET_VIF_STATE_REQ = 24'u16
  MM_STA_DEL_REQ = 12'u16
  MM_STA_DEL_CFM = 13'u16
  ME_STA_DEL_REQ = 0xC07'u16
  ME_STA_DEL_CFM = 0xC08'u16
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint
type
  KeMsgHdr = object
    next: pointer
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  CoListHdr = KeMsgHdr
  MeStaDelReqPayload = object
    staIdx: uint8
  MmStaDelReqPayload = MeStaDelReqPayload
  MmSetVifStateReqPayload = object
    aid: uint16
    state, vifIdx: uint8
  VifChannelView = object
    vifIdx, vifType, staIdx, state: uint8
    chanCtxt: pointer
    config: tuple[securityFlags: uint8]
  Sm = object
    connectInfo, connectIndMsg: pointer
    cancelRequested, joinBssFlag, deauthPending: uint8
    scanResultIndex: uint32
  Sent = object
    p: pointer
    id: uint16
    dest, src: uint8
    length: uint32
const
  MeStaDelReqPayloadSize = 1'u32
  MmStaDelReqPayloadSize = 1'u32
  MmSetVifStateReqPayloadSize = sizeof(MmSetVifStateReqPayload).uint32
  KeMsgHdrSize = sizeof(KeMsgHdr).uint
  KeMsgTailSlack = 4'u32
var
  allocated: seq[pointer]
  sent: seq[Sent]
  deleted: seq[uint8]
  retries: seq[uint8]
  keMsgQueueSaved: seq[pointer]
  failAllocation: bool
  failDelete: bool
  calls: int
  stations: array[5, tuple[valid: uint8]]
  staDeleteEpochs: array[5, uint32]
  vifs: array[2, VifChannelView]
  sm: Sm
  nimFwDbgDisconnectInd, nimFwWpaPendingMask: uint32
  onAllocate: proc()
proc calloc(count, size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc keMsgPayload(h: ptr KeMsgHdr): pointer = cast[pointer](cast[uint](h) + KeMsgHdrSize)
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - KeMsgHdrSize)
proc allocate(size: uint32): pointer {.cdecl.} =
  inc calls
  if failAllocation: return nil
  result = calloc(1, size.csize_t)
  doAssert result != nil
  allocated.add(result)
  if onAllocate != nil:
    let callback = onAllocate
    onAllocate = nil
    callback()
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 0xB8
  cast[pointer](allocate)
proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, size.int)
  p
proc ke_msg_try_alloc(id: uint16; destId, srcId: uint8; paramLen: uint32): pointer
proc ke_msg_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  ke_msg_try_alloc(id, dest, src, size)
proc ke_msg_send(p: pointer) =
  doAssert p != nil
  let h = keMsgHdrFromPayload(p)
  sent.add(Sent(p: p, id: h.id, dest: h.destId, src: h.srcId, length: h.paramLen))
proc ke_msg_send_basic(id: uint16; dest, src: uint8) =
  let p = ke_msg_alloc(id, dest, src, 0)
  if p != nil: ke_msg_send(p)
proc mmStaDelReqView(p: pointer): ptr MmStaDelReqPayload = cast[ptr MmStaDelReqPayload](p)
proc mmStaDelTry(index: uint8; saved: uint32): bool =
  deleted.add(index)
  not failDelete
proc mmStaDelRetryPending(index: uint8): bool = false
proc mmStaDelQueueRetryLocked(index: uint8; saved: uint32) = retries.add(index)
proc co_list_push_back(queue: ptr seq[pointer]; header: ptr CoListHdr) = queue[].add(header)
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc txlResetting(): bool = false
proc staInfoForIdx(index: uint8): ptr tuple[valid: uint8] = addr stations[index]
proc smEnvView(): ptr Sm = addr sm
proc smAwaits(request: pointer): bool = true  # SM waits on its delete
proc smRequestVifLive(): bool = true
proc smStaleRequest(request: pointer): bool = false
proc vifChannelAt(p: pointer): ptr VifChannelView = cast[ptr VifChannelView](p)
proc vifChannelForIdx(index: uint8): ptr VifChannelView = addr vifs[index]
proc vifApConfig(vif: ptr VifChannelView): ptr typeof(vif.config) = addr vif.config
proc connectInfoView(p: pointer): ptr tuple[vifIdx: uint8] = cast[ptr tuple[vifIdx: uint8]](p)
proc chan_ctxt_unlink(index: uint8) = vifs[index].chanCtxt = nil
proc ke_state_set(task: uint8; state: uint16) = doAssert task == TASK_SM and state == SmIdleState
proc ke_msg_free(p: pointer) =
  let index = allocated.find(p)
  doAssert index >= 0
  allocated.delete(index)
  free(p)
proc reset() =
  for p in allocated: free(p)
  allocated.setLen(0)
  sent.setLen(0)
  deleted.setLen(0)
  retries.setLen(0)
  keMsgQueueSaved.setLen(0)
  failAllocation = false
  failDelete = false
  calls = 0
  onAllocate = nil
  for sta in stations.mitems: sta.valid = 1
  sm = default(Sm)
  vifs = default(typeof(vifs))
'''

CHECKS = r'''
# MM must reply to the actual sender, including SM/ME and the second host task.
for source in 0'u8 .. 10:
  for index in [0'u8, 4, 5, 255]:
    reset()
    let p = ke_msg_alloc(MM_STA_DEL_REQ, TASK_MM, source, 1)
    mmStaDelReqView(p).staIdx = index
    mm_sta_del_req_handler(p)
    doAssert sent.len == 1 and deleted == @[index]
    doAssert sent[0].id == MM_STA_DEL_CFM and sent[0].dest == source
    doAssert sent[0].src == TASK_MM and sent[0].length == 0
    doAssert sent[0].p == p, "MM must transfer the request allocation to its reply"
    doAssert calls == 1

# ME acknowledges acceptance separately and sends a new MM delete request.
for source in 0'u8 .. 10:
  reset()
  let p = ke_msg_alloc(ME_STA_DEL_REQ, TASK_ME, source, 1)
  cast[ptr MeStaDelReqPayload](p).staIdx = 4
  doAssert me_sta_del_req_handler(p) == KeMsgConsumed
  doAssert sent.len == 2 and deleted.len == 0
  let mmRequest = sent[0].p
  doAssert mmRequest != p
  doAssert sent[0] == Sent(p: mmRequest, id: MM_STA_DEL_REQ, dest: TASK_MM, src: TASK_ME, length: 1)
  doAssert mmStaDelReqView(mmRequest).staIdx == 4
  doAssert sent[1].id == ME_STA_DEL_CFM and sent[1].dest == source
  doAssert sent[1].src == TASK_ME and sent[1].length == 0
  doAssert calls == 3
  failAllocation = true
  mm_sta_del_req_handler(mmRequest)
  doAssert deleted == @[4'u8]
  doAssert sent[^1] == Sent(p: mmRequest, id: MM_STA_DEL_CFM, dest: TASK_ME, src: TASK_MM, length: 0)
  doAssert calls == 3, "MM completion must not allocate"

let meHandler = cast[proc(p: pointer): cint {.cdecl.}](me_sta_del_req_handler)
let mmHandler = cast[proc(p: pointer): cint {.cdecl.}](mm_sta_del_req_handler)
reset()
let pending = ke_msg_alloc(ME_STA_DEL_REQ, TASK_ME, 10, 1)
cast[ptr MeStaDelReqPayload](pending).staIdx = 2
let original = keMsgHdrFromPayload(pending)[]
failAllocation = true
doAssert meHandler(pending) == KeMsgSaved
doAssert sent.len == 0 and deleted.len == 0 and allocated.len == 1
doAssert keMsgHdrFromPayload(pending)[] == original
failAllocation = false
doAssert meHandler(pending) == KeMsgConsumed
doAssert mmHandler(sent[0].p) == KeMsgNoFree
doAssert allocated.len == 3 and deleted == @[2'u8]

reset()
let failed = ke_msg_alloc(MM_STA_DEL_REQ, TASK_MM, TASK_API, 1)
mmStaDelReqView(failed).staIdx = 2
failDelete = true
doAssert mmHandler(failed) == KeMsgNoFree
doAssert sent.len == 0 and retries == @[2'u8]
doAssert keMsgQueueSaved == @[cast[pointer](keMsgHdrFromPayload(failed))]
doAssert keMsgHdrFromPayload(failed).paramLen == 1
failDelete = false
keMsgQueueSaved.setLen(0)
doAssert mmHandler(failed) == KeMsgNoFree
doAssert sent.len == 1 and sent[0].id == MM_STA_DEL_CFM
doAssert sent[0].p == failed and sent[0].dest == TASK_API

for task in [TASK_MM, TASK_ME]:
  reset()
  let malformed = ke_msg_alloc((if task == TASK_MM: MM_STA_DEL_REQ else: ME_STA_DEL_REQ), task, TASK_API, 0)
  let handler = if task == TASK_MM: mmHandler else: meHandler
  doAssert handler(malformed) == KeMsgConsumed
  doAssert handler(nil) == KeMsgConsumed
  doAssert sent.len == 0 and deleted.len == 0 and allocated.len == 1
reset()

proc replaceStation() = inc staDeleteEpochs[2]
# SM also checks reuse at dispatch; see test_wifi_sm_cleanup.py.
reset()
onAllocate = replaceStation
let reused = ke_msg_alloc(ME_STA_DEL_REQ, TASK_ME, TASK_API, 1)
cast[ptr MeStaDelReqPayload](reused).staIdx = 2
onAllocate = replaceStation
doAssert meHandler(reused) == KeMsgConsumed
doAssert mmStaDelReqView(sent[0].p).staIdx == 255
reset()
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_delete_dispatch(tmp_path: Path, mode: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    handlers = (FW / "task_handlers.nim").read_text()
    bodies = procedure(kernel, "ke_msg_try_alloc")
    bodies += procedure(kernel, "ke_msg_forward_and_change_id")
    sta = (FW / "sta_management.nim").read_text()
    for name in ["staDeleteEpoch", "staDeleteIsCurrent"]:
        bodies += procedure(sta, name)
    for name in ["mm_sta_del_req_handler", "me_sta_del_req_handler"]:
        bodies += procedure(handlers, name)
    path = tmp_path / "dispatch.nim"
    path.write_text(PLATFORM + TIM_METADATA_STUBS + bodies + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
               "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(path)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout
