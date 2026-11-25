"""Run station aborts and disconnects against owned deferred commands and message lifetimes.

SM_CONNECT_ABORT_REQ is answered in place (it becomes SM_CONNECT_ABORT_CFM)
and is never saved: it acts on the attempt that is live when it is
dispatched. SM_DISCONNECT_REQ is saved while SM is busy and acts only on the
STA VIF generation ke_msg_send stamped it with (station_abort.nim)."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_deferred_auth_lifetime import program_source as deferred_source
from test_wifi_disconnect_tx import FW, ROOT, procedure

SUPPORT = r'''
const
  TASK_API = 9'u8
  TASK_SCAN = 1'u8
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint
  SmIdleState = 0'u16
  SM_DISCONNECT_REQ = 0x1003'u16
  SM_DISCONNECT_CFM = 0x1004'u16
  SM_CONNECT_ABORT_REQ = 0x1007'u16
  SM_CONNECT_ABORT_CFM = 0x1008'u16
  SCAN_ABORT_REQ = 0x405'u16
  ScanChannelRunningState = 3'u16
  StatusCfmPayloadSize = 1'u32
  WLAN_FW_CONNECT_ABORT_BY_USER_NO_DEAUTH = 24'u16
type StatusCfmPayload = object
  status: uint8
var
  replies: seq[uint8]
  outcomes: seq[tuple[status, reason: uint16]]
  deauths, scanAborts, cacheClears: int
  scanTerminations: int
  scanState: uint16
  scan_env: tuple[paramPtr: pointer, abortFlag: uint8]
  scanu_env: tuple[paramPtr: pointer]
  upperScan, lowerScan: uint32
  lowerExchange: pointer
  smOwnsUpper: bool
  pendingScanAborts: seq[pointer]
  scanHook: proc()
  tlvHook: proc()
  disconnects, disconnectReplies: int
  disconnectRequest: pointer
  nimFwDbgDisconnectReq, nimFwDbgDisconnectReqState: uint32
'''

ADAPTERS = r'''
proc ke_msg_alloc(id: uint16; dst, src: uint8; size: uint32): pointer =
  ke_msg_try_alloc(id, dst, src, size)
proc smReqVifIdxOrZero(p: pointer): uint8 =
  if p == nil: 0'u8 else: cast[ptr uint8](p)[]
proc scanuAwaits(lower: pointer): bool = lower != nil and lower == lowerExchange
proc smAwaits(request: pointer): bool = smOwnsUpper and request == addr upperScan
proc scan_terminate_channel_request() = inc scanTerminations
proc scanOnChannel(): bool = true  # the dwell has not left its channel
proc scanu_cached_scanresult_clear() = inc cacheClears
proc sm_connect_abort_deauth_cfm() = discard
proc sm_connect_abort_process() = discard
proc sm_disconnect_deauth_cfm() = discard
proc sm_disconnect_process() = discard
proc sm_connection_tlv_set() = invoke(tlvHook)
proc sm_handle_connection(vif: uint8; status: uint16; callback, failure: pointer) =
  doAssert vif == 1
  if status == 19:
    inc disconnects
    doAssert callback == cast[pointer](sm_disconnect_deauth_cfm)
    doAssert failure == cast[pointer](sm_disconnect_process)
  else:
    doAssert status == 24
    inc deauths
  env.connectInfo = nil
  discard smGo(10)
'''

ALLOCATOR = r'''
const KeMsgHdrSize = sizeof(KeMsgHdr)
proc mmTimAllocationSize(id: uint16; destination: uint8; length: uint32): uint32 = length
proc mmTimRegisterAllocation(header: ptr KeMsgHdr) = discard
proc chanUpdateStorageLength(id: uint16; destination: uint8; length: uint32): uint32 = length
proc chanUpdateRegister(header: ptr KeMsgHdr) = discard
proc heapAlloc(size: uint32): pointer {.cdecl.} =
  inc allocations
  if not allocFail:
    result = alloc0(size.int)
    live.add(cast[ptr KeMsgHdr](result))
  invoke(allocationHook)
proc blOpsFunc(offset: int): pointer =
  if offset == 4: return nil
  doAssert offset == 0xB8
  cast[pointer](heapAlloc)
proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, size.int)
  p
'''

HELPERS = r'''
proc beginScan(owned: bool) =
  scanu_env.paramPtr = addr upperScan
  scan_env = (cast[pointer](addr lowerScan), 0'u8)
  lowerExchange = scan_env.paramPtr
  smOwnsUpper = owned
  scanState = ScanChannelRunningState
proc deliverScanAbort() =
  doAssert pendingScanAborts.len == 1
  let payload = pendingScanAborts.pop()
  doAssert scan_abort_req_handler(payload) == KeMsgConsumed
  ke_msg_free(keMsgHdrFromPayload(payload))
proc makeAbort(vif = 1'u8): pointer =
  let fail = allocFail
  allocFail = false
  result = ke_msg_try_alloc(SM_CONNECT_ABORT_REQ, TASK_SM, TASK_API, 1)
  allocFail = fail
  doAssert result != nil
  cast[ptr uint8](result)[] = vif
proc deliverAbort(request: pointer): cint =
  result = sm_connect_abort_req_handler(request)
  if result == KeMsgConsumed: ke_msg_free(keMsgHdrFromPayload(request))
proc makeDisconnect(vif = 1'u8; length = 1'u32): pointer =
  result = ke_msg_try_alloc(SM_DISCONNECT_REQ, TASK_SM, TASK_API, length)
  doAssert result != nil
  if length != 0: cast[ptr uint8](result)[] = vif
  # ke_msg_send stamps it as it queues it.
  smDisconnectStamp(keMsgHdrFromPayload(result))
  disconnectRequest = result
proc deliverDisconnect(request: pointer): cint =
  result = sm_disconnect_req_handler(request)
  if result == KeMsgConsumed: ke_msg_free(keMsgHdrFromPayload(request))
'''


def program_source() -> str:
    code = SUPPORT + deferred_source()
    fields = "    connectInfo, connectIndMsg: pointer\n"
    assert code.count(fields) == 1
    code = code.replace(fields, fields + "    cancelRequested: uint8\n", 1)
    code = code.replace("proc smDeferredCancel()\n", """proc smDisconnectStorageLength(id: uint16; destination: uint8; length: uint32): uint32
proc smDisconnectRegister(header: ptr KeMsgHdr)
proc smDisconnectForget(header: pointer)
proc smDisconnectStamp(header: ptr KeMsgHdr)
proc smDeferredCancel()
""", 1)
    code = code.replace("  live.delete(index)\n", "  smDisconnectForget(header)\n  live.delete(index)\n", 1)
    original_allocator = procedure(code, "ke_msg_try_alloc")
    allocator = procedure((FW / "kernel_mac_channel.nim").read_text(), "ke_msg_try_alloc")
    code = code.replace(original_allocator, ALLOCATOR + allocator, 1)
    code = code.replace("proc ke_state_get(task: uint8): uint16 = currentState",
                        "proc ke_state_get(task: uint8): uint16 =\n"
                        "  if task == TASK_SCAN: scanState else: currentState", 1)
    code = code.replace("  inc publications\n  queue.add(payload)", """  if keMsgHdrFromPayload(payload).id == SM_DISCONNECT_CFM:
    let hdr = keMsgHdrFromPayload(payload)
    doAssert payload == disconnectRequest and hdr.paramLen == 0
    doAssert hdr.destId == TASK_API and hdr.srcId == TASK_SM
    inc disconnectReplies
    ke_msg_free(hdr)
    return
  if keMsgHdrFromPayload(payload).id == SM_CONNECT_ABORT_CFM:
    replies.add(cast[ptr StatusCfmPayload](payload).status)
    ke_msg_free(keMsgHdrFromPayload(payload))
    invoke(publicationHook)
    return
  if keMsgHdrFromPayload(payload).id == SCAN_ABORT_REQ:
    inc scanAborts
    pendingScanAborts.add(payload)
    invoke(scanHook)
    return
  inc publications
  queue.add(payload)""", 1)
    ending = "  endings.add((status, reason))\n"
    assert code.count(ending) == 1
    code = code.replace(ending, ending + "  if status == 24: outcomes.add((status, reason))\n", 1)
    code += (FW / "station_abort.nim").read_text()
    handlers = (FW / "task_handlers.nim").read_text()
    abort_handlers = ["smAbortOwnsLowerScan", "scan_abort_req_handler", "smQueueOwnedScanAbort",
                      "sm_disconnect_req_handler", "sm_connect_abort_req_handler"]
    return (code + ADAPTERS + procedure((FW / "kernel_mac_channel.nim").read_text(),
            "ke_msg_forward_and_change_id") + "".join(procedure(handlers, name)
            for name in abort_handlers) + HELPERS)


CASES = {
    "disconnect_lifetime": r'''
# A saved disconnect cannot act on a replacement VIF, even while SM is busy.
let saved = makeDisconnect()
doAssert deliverDisconnect(saved) == KeMsgSaved and disconnectReplies == 0
inc rxVifEpochs[1]
doAssert deliverDisconnect(saved) == KeMsgNoFree
doAssert disconnects == 0 and disconnectReplies == 1

# Publication, not first dispatch, determines the original target.
let queued = makeDisconnect()
inc rxVifEpochs[1]
currentState = SmIdleState
doAssert deliverDisconnect(queued) == KeMsgNoFree
doAssert disconnects == 0 and disconnectReplies == 2

# A join may retire its connection buffer without retiring the VIF session.
let current = makeDisconnect()
currentState = 6
doAssert deliverDisconnect(current) == KeMsgSaved
currentState = SmIdleState
env.connectInfo = nil
let allocated = allocations
allocFail = true
doAssert deliverDisconnect(current) == KeMsgNoFree
doAssert disconnects == 1 and disconnectReplies == 3 and allocations == allocated
allocFail = false

# A VIF removed and added again at the same index is another generation.
currentState = 6
let removed = makeDisconnect()
doAssert deliverDisconnect(removed) == KeMsgSaved
inc rxVifEpochs[1]  # vif_mgmt_unregister
currentState = SmIdleState
doAssert deliverDisconnect(removed) == KeMsgNoFree
doAssert disconnects == 1 and disconnectReplies == 4

# Malformed or unbound requests still release the command, but do no work.
for length in [0'u32, 1, 2]:
  let bad = makeDisconnect(255, length)
  doAssert deliverDisconnect(bad) == KeMsgNoFree
doAssert disconnects == 1 and disconnectReplies == 7
''',
    "parked_auth": """
schedule(5)
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgNoFree
publish()
drain()
doAssert sent.len == 0, "cancelled deferred authentication was transmitted"
doAssert outcomes == @[(24'u16, 3'u16)] and replies == @[0'u8]
""",
    "parked_assoc": """
schedule(7)
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgNoFree
publish()
drain()
doAssert sent.len == 0, "cancelled deferred association was transmitted"
doAssert outcomes == @[(24'u16, 3'u16)] and replies == @[0'u8]
""",
    "queued": """
schedule()
publish()
let pending = queue[0]
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgNoFree
doAssert live.find(keMsgHdrFromPayload(pending)) >= 0
drain()
doAssert sent.len == 0 and outcomes.len == 1
""",
    # The pinned handler saves the abort in states 3 and 4; here it ends the
    # attempt at once, as in states 5 and 7 (no frame went to the AP yet).
    "join_acts": """
for state in [3'u16, 4]:
  reset()
  outcomes.setLen(0)
  replies.setLen(0)
  currentState = state
  let request = makeAbort()
  doAssert deliverAbort(request) == KeMsgNoFree
  doAssert outcomes == @[(24'u16, 3'u16)] and replies == @[0'u8]
  doAssert currentState == 10 and deauths == 0
""",
    # The abort is answered in place: without memory it still acts and is
    # confirmed, and it is never saved for a later attempt. The pinned
    # handler allocates its confirmation with ke_msg_alloc.
    "never_saved": """
for state in [3'u16, 5]:
  reset()
  outcomes.setLen(0)
  replies.setLen(0)
  if state == 5: schedule(5)
  else: currentState = state
  let request = makeAbort()
  let before = allocations
  allocFail = true
  doAssert deliverAbort(request) == KeMsgNoFree
  allocFail = false
  doAssert allocations == before, "the abort allocated its confirmation"
  doAssert outcomes == @[(24'u16, 3'u16)] and replies == @[0'u8]
  doAssert live.find(keMsgHdrFromPayload(request)) < 0
""",
    # It acts on the attempt live when it is dispatched, if that attempt is
    # on the VIF it names.
    "acts_on_the_live_attempt": """
let request = makeAbort()
env.connectInfo = addr replacement
schedule()
doAssert deliverAbort(request) == KeMsgNoFree
doAssert outcomes.len == 1 and replies == @[0'u8]
publish()
drain()
doAssert sent.len == 0
""",
    # The host starts another attempt while it handles the confirmation,
    # which is sent last: that attempt is not aborted.
    "reply_replacement": """
schedule()
let request = makeAbort()
publicationHook = proc() =
  env.connectInfo = addr replacement
  schedule(7)
doAssert deliverAbort(request) == KeMsgNoFree
doAssert currentState == 7 and chan.deferredMsg != nil
publish()
drain()
doAssert sent.len == 1 and sent[0].kind == 7 and outcomes.len == 1
""",
    "invalid_length": """
schedule()
let request = ke_msg_try_alloc(SM_CONNECT_ABORT_REQ, TASK_SM, TASK_API, 2)
cast[ptr uint8](request)[] = 1
doAssert deliverAbort(request) == KeMsgNoFree
doAssert outcomes.len == 0 and replies == @[1'u8]
publish()
drain()
doAssert sent.len == 1
""",
    "wrong_vif": """
schedule()
let request = makeAbort(0)
doAssert deliverAbort(request) == KeMsgNoFree
doAssert outcomes.len == 0 and replies == @[1'u8]
publish()
drain()
doAssert sent.len == 1
""",
    "invalid_vif": """
schedule()
let request = makeAbort(2)
doAssert deliverAbort(request) == KeMsgNoFree
doAssert outcomes.len == 0 and replies == @[1'u8]
""",
    "response_window": """
for state in [6'u16, 8, 9]:
  reset()
  currentState = state
  let request = makeAbort()
  doAssert deliverAbort(request) == KeMsgNoFree
doAssert deauths == 3 and outcomes.len == 0 and replies == @[0'u8, 0, 0]
""",
    "idle": """
env.connectInfo = nil
currentState = 0
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgNoFree
doAssert outcomes.len == 0 and deauths == 0 and replies == @[0'u8]
""",
    "disconnecting": """
currentState = 10
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgNoFree
doAssert outcomes.len == 0 and deauths == 0 and replies == @[0'u8]
""",
    "scanning": """
currentState = 1
beginScan(owned = true)
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgNoFree
doAssert env.cancelRequested == 1 and scanAborts == 1 and cacheClears == 1
doAssert replies == @[1'u8]
deliverScanAbort()
doAssert scan_env.abortFlag == 1 and scanTerminations == 1
""",
    "scanning_behind_public_scan": """
currentState = 1
# SCANU holds a public scan; this station connection's scan is still saved.
beginScan(owned = false)
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgNoFree
doAssert env.cancelRequested == 1 and replies == @[1'u8]
doAssert scanAborts == 0, "station cancellation interrupted the public scan"
doAssert cacheClears == 0, "station cancellation erased public scan results"
""",
    # The abort carries no payload: it acts on the lower scan running when it
    # is dispatched, if that is still the one of SM's live scan request.
    "scan_abort_at_dispatch": """
currentState = 1
beginScan(owned = true)
doAssert deliverAbort(makeAbort()) == KeMsgNoFree
doAssert pendingScanAborts.len == 1
# SCANU went on to the request's next band: the abort stops that one.
var nextLower: uint32
scan_env.paramPtr = addr nextLower
lowerExchange = addr nextLower
deliverScanAbort()
doAssert scan_env.abortFlag == 1 and scanTerminations == 1
# SM moved on before its abort ran: the scan is left alone.
scan_env.abortFlag = 0
doAssert deliverAbort(makeAbort()) == KeMsgNoFree
smOwnsUpper = false
deliverScanAbort()
doAssert scan_env.abortFlag == 0 and scanTerminations == 1
""",
    # Without memory for SCAN_ABORT_REQ the lower scan runs to its end; the
    # station's scan still completes as cancelled (cancelRequested).
    "scan_abort_optional_allocation": """
currentState = 1
beginScan(owned = true)
let request = makeAbort()
allocFail = true
doAssert deliverAbort(request) == KeMsgNoFree
allocFail = false
doAssert env.cancelRequested == 1 and replies == @[1'u8]
doAssert scanAborts == 0 and cacheClears == 0 and live.len == 0
""",
    "waiting": """
currentState = 2
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgNoFree
doAssert env.cancelRequested == 1 and scanAborts == 0 and replies == @[0'u8]
""",
    # Pinned sm_connect_abort_req_handler only confirms an abort in states 5
    # and 7. Here it always ends the attempt there, parked request or not.
    "parked_state_always_acts": """
for state in [5'u16, 7]:
  reset()
  outcomes.setLen(0)
  replies.setLen(0)
  discard smGo(state)
  let request = makeAbort()
  doAssert deliverAbort(request) == KeMsgNoFree
  doAssert outcomes == @[(24'u16, 3'u16)] and replies == @[0'u8]
  doAssert currentState == 10 and deauths == 0
""",
    "disabled_irqs": """
schedule()
let request = makeAbort()
interruptsEnabled = false
doAssert deliverAbort(request) == KeMsgNoFree
doAssert not interruptsEnabled and outcomes.len == 1
interruptsEnabled = true
""",
    "storage_limits": """
doAssert smDisconnectStorageLength(0x777, TASK_SM, 17) == 17
doAssert smDisconnectStorageLength(SM_CONNECT_ABORT_REQ, TASK_SM, 1) == 1
doAssert smDisconnectStorageLength(SM_DISCONNECT_REQ, TASK_SM, 0) == 0
doAssert smDisconnectStorageLength(SM_DISCONNECT_REQ, TASK_SM, 1) > 1
for delta in 0'u32 .. 15:
  let before = allocations
  doAssert ke_msg_try_alloc(SM_DISCONNECT_REQ, TASK_SM, TASK_API, high(uint32) - delta) == nil
  doAssert allocations == before
let request = makeDisconnect()
doAssert keMsgHdrFromPayload(request).paramLen == 1
currentState = 0
doAssert deliverDisconnect(request) == KeMsgNoFree
""",
    "recycled_request": """
env.connectInfo = nil
currentState = 6
for index in 0..<100:
  let request = makeDisconnect()
  inc rxVifEpochs[1]
  doAssert deliverDisconnect(request) == KeMsgNoFree
  doAssert smDisconnectStamps == nil
doAssert disconnectReplies == 100 and live.len == 0
""",
}


MUTATIONS = {
    "disconnect_epoch": ("rxVifEpochs[stamp.vif] == stamp.vifEpoch and", "true and",
                         "disconnect_lifetime"),
    "capture": ("  smDisconnectStamp(keMsgHdrFromPayload(result))\n  disconnectRequest",
                "  disconnectRequest", "disconnect_lifetime"),
    "release": ("  smDisconnectForget(header)", "  discard", "recycled_request"),
    "scan_abort_owner": ("  if param != nil and keMsgHdrFromPayload(param).srcId == TASK_SM and\n      not smAbortOwnsLowerScan():",
                         "  if false:", "scan_abort_at_dispatch"),
}


def run_case(tmp_path: Path, case: str, mode: str = "checked", mutation: str = "") -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "abort.nim"
    code = program_source()
    if mutation:
        old, new, _ = MUTATIONS[mutation]
        assert code.count(old) == 1
        code = code.replace(old, new, 1)
    path.write_text(code + "\nreset()\n" + CASES[case] + "\nfinish()\ndoAssert smDisconnectStamps == nil\n")
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}[mode]
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--checks:on", *flags, f"--path:{ROOT / 'src'}",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'check'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if mutation:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
    else:
        assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_station_abort(tmp_path: Path, case: str, mode: str) -> None:
    run_case(tmp_path, case, mode)


@pytest.mark.parametrize("mutation", MUTATIONS)
def test_station_abort_guards(tmp_path: Path, mutation: str) -> None:
    run_case(tmp_path, MUTATIONS[mutation][2], mutation=mutation)


def test_abort_message_hooks() -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    sender = procedure(kernel, "ke_msg_send")
    assert sender.index("smDisconnectStamp(hdr)") < sender.index("co_list_push_back")
    assert "smDisconnectRegister(hdr)" in procedure(kernel, "ke_msg_try_alloc")
    assert "smDisconnectForget(param)" in procedure(kernel, "ke_msg_free")
    # The abort is answered in place and never saved: it needs no stamp.
    tasks = (FW / "task_handlers.nim").read_text()
    abort = procedure(tasks, "sm_connect_abort_req_handler")
    assert "KeMsgSaved" not in abort and "ke_msg_try_alloc" not in abort
    assert "SM_CONNECT_ABORT_REQ" not in (FW / "station_abort.nim").read_text().split("type", 1)[1]
    # A message delivered to the host is retired by ke_msg_free, which forgets it.
    assert "ke_msg_free(hdr)" in sender.split("bl_rx_e2a_handler(", 1)[1]
