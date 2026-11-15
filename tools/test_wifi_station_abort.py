"""Run station aborts against owned deferred commands and message lifetimes."""

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
  KeMsgSaved = 2.cint
  SM_CONNECT_ABORT_REQ = 0x1007'u16
  SM_CONNECT_ABORT_CFM = 0x1008'u16
  SCAN_ABORT_REQ = 0x405'u16
  StatusCfmPayloadSize = 1'u32
  WLAN_FW_CONNECT_ABORT_BY_USER_NO_DEAUTH = 24'u16
type StatusCfmPayload = object
  status: uint8
proc chanSwitchCallbackCurrent(): bool = true
var
  replies: seq[uint8]
  outcomes: seq[tuple[status, reason: uint16]]
  deauths, scanAborts, cacheClears: int
  scanHook: proc()
'''

ADAPTERS = r'''
proc ke_msg_alloc(id: uint16; dst, src: uint8; size: uint32): pointer =
  ke_msg_try_alloc(id, dst, src, size)
proc smReqVifIdxOrZero(p: pointer): uint8 =
  if p == nil: 0'u8 else: cast[ptr uint8](p)[]
proc ke_msg_send_basic(id: uint16; dst, src: uint8) =
  doAssert id == SCAN_ABORT_REQ
  inc scanAborts
  invoke(scanHook)
proc scanu_cached_scanresult_clear() = inc cacheClears
proc sm_connect_abort_deauth_cfm() = discard
proc sm_connect_abort_process() = discard
proc sm_handle_connection(vif: uint8; status: uint16; callback, failure: pointer) =
  doAssert vif == 1 and status == 24
  inc deauths
  currentState = 10
  env.connectInfo = nil
  smDeferredCancel()
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
  doAssert offset == 0xB8
  cast[pointer](heapAlloc)
proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, size.int)
  p
'''

HELPERS = r'''
proc makeAbort(vif = 1'u8): pointer =
  result = ke_msg_try_alloc(SM_CONNECT_ABORT_REQ, TASK_SM, TASK_API, 1)
  doAssert result != nil
  cast[ptr uint8](result)[] = vif
  smAbortCaptureMessage(keMsgHdrFromPayload(result))
proc deliverAbort(request: pointer): cint =
  result = sm_connect_abort_req_handler(request)
  if result == KeMsgConsumed: ke_msg_free(keMsgHdrFromPayload(request))
'''


def program_source() -> str:
    code = SUPPORT + deferred_source()
    code = code.replace("    connectInfo: pointer\n", "    connectInfo: pointer\n    cancelRequested: uint8\n", 1)
    code = code.replace("proc smDeferredCancel()\n", """proc smAbortStorageLength(id: uint16; destination: uint8; length: uint32): uint32
proc smAbortRegister(header: ptr KeMsgHdr)
proc smAbortForget(header: pointer)
proc smAbortCaptureMessage(header: ptr KeMsgHdr)
proc smDeferredCancel()
""", 1)
    code = code.replace("  smDeferredForget(header)\n", "  smDeferredForget(header)\n  smAbortForget(header)\n", 1)
    original_allocator = procedure(code, "ke_msg_try_alloc")
    allocator = procedure((FW / "kernel_mac_channel.nim").read_text(), "ke_msg_try_alloc")
    code = code.replace(original_allocator, ALLOCATOR + allocator, 1)
    code = code.replace("  inc publications\n  queue.add(payload)", """  if keMsgHdrFromPayload(payload).id == SM_CONNECT_ABORT_CFM:
    replies.add(cast[ptr StatusCfmPayload](payload).status)
    ke_msg_free(keMsgHdrFromPayload(payload))
    invoke(publicationHook)
    return
  inc publications
  queue.add(payload)""", 1)
    code = code.replace("  doAssert status == 11 and reason == 0xFFFF\n", """  if status == 24:
    outcomes.add((status, reason))
    currentState = 10
    env.connectInfo = nil
    smDeferredCancel()
    return
  doAssert status == 11 and reason == 0xFFFF
""", 1)
    abort_file = FW / "station_abort.nim"
    if abort_file.exists():
        code += abort_file.read_text()
    else:
        code += """
proc smAbortStorageLength(id: uint16; destination: uint8; length: uint32): uint32 = length
proc smAbortRegister(header: ptr KeMsgHdr) = discard
proc smAbortForget(header: pointer) = discard
proc smAbortCaptureMessage(header: ptr KeMsgHdr) = discard
"""
    return code + ADAPTERS + procedure((FW / "task_handlers.nim").read_text(),
                                     "sm_connect_abort_req_handler") + HELPERS


CASES = {
    "parked_auth": """
schedule(5)
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgConsumed
publish()
drain()
doAssert sent.len == 0, "cancelled deferred authentication was transmitted"
doAssert outcomes == @[(24'u16, 3'u16)] and replies == @[0'u8]
""",
    "parked_assoc": """
schedule(7)
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgConsumed
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
doAssert deliverAbort(request) == KeMsgConsumed
doAssert live.find(keMsgHdrFromPayload(pending)) >= 0
drain()
doAssert sent.len == 0 and outcomes.len == 1
""",
    "executing": """
schedule()
let request = makeAbort()
authHook = proc() =
  currentState = 5
  doAssert deliverAbort(request) == KeMsgSaved
  doAssert outcomes.len == 0 and replies.len == 0
  currentState = 6
publish()
drain()
doAssert sent.len == 1
doAssert deliverAbort(request) == KeMsgConsumed
doAssert deauths == 1 and replies == @[0'u8]
""",
    "join_saved": """
let request = makeAbort()
for state in [3'u16, 4]:
  currentState = state
  let before = allocations
  doAssert deliverAbort(request) == KeMsgSaved
  doAssert allocations == before and replies.len == 0
schedule()
doAssert deliverAbort(request) == KeMsgConsumed
doAssert outcomes.len == 1 and sent.len == 0
""",
    "saved_replacement": """
let request = makeAbort()
currentState = 3
doAssert deliverAbort(request) == KeMsgSaved
env.connectInfo = addr replacement
schedule()
doAssert deliverAbort(request) == KeMsgConsumed
doAssert outcomes.len == 0 and replies == @[0'u8]
publish()
drain()
doAssert sent.len == 1
""",
    "queued_replacement_before_dispatch": """
let request = makeAbort()
env.connectInfo = addr replacement
schedule()
doAssert deliverAbort(request) == KeMsgConsumed
doAssert outcomes.len == 0 and replies == @[0'u8]
publish()
drain()
doAssert sent.len == 1
""",
    "saved_epoch": """
let request = makeAbort()
currentState = 4
doAssert deliverAbort(request) == KeMsgSaved
inc rxVifEpochs[1]
schedule()
doAssert deliverAbort(request) == KeMsgConsumed
doAssert outcomes.len == 0
publish()
drain()
doAssert sent.len == 1
""",
    "allocation_replacement": """
schedule()
let request = makeAbort()
allocationHook = proc() =
  env.connectInfo = addr replacement
  schedule(7)
doAssert deliverAbort(request) == KeMsgConsumed
doAssert outcomes.len == 0 and replies == @[0'u8]
publish()
drain()
doAssert sent.len == 1 and sent[0].kind == 7
""",
    "allocation_failure": """
schedule()
let request = makeAbort()
allocFail = true
doAssert deliverAbort(request) == KeMsgSaved
doAssert outcomes.len == 0 and replies.len == 0 and chan.deferredMsg != nil
allocFail = false
doAssert deliverAbort(request) == KeMsgConsumed
doAssert outcomes.len == 1 and replies == @[0'u8]
""",
    "two_inflight": """
let first = makeAbort()
currentState = 3
doAssert deliverAbort(first) == KeMsgSaved
env.connectInfo = addr replacement
schedule(7)
let second = makeAbort()
doAssert deliverAbort(first) == KeMsgConsumed
doAssert outcomes.len == 0 and currentState == 7
doAssert deliverAbort(second) == KeMsgConsumed
doAssert outcomes.len == 1 and replies == @[0'u8, 0]
""",
    "reply_replacement": """
schedule()
let request = makeAbort()
publicationHook = proc() =
  env.connectInfo = addr replacement
  schedule(7)
doAssert deliverAbort(request) == KeMsgConsumed
doAssert currentState == 7 and chan.deferredMsg != nil
publish()
drain()
doAssert sent.len == 1 and sent[0].kind == 7 and outcomes.len == 1
""",
    "invalid_length": """
schedule()
let request = ke_msg_try_alloc(SM_CONNECT_ABORT_REQ, TASK_SM, TASK_API, 2)
cast[ptr uint8](request)[] = 1
smAbortCaptureMessage(keMsgHdrFromPayload(request))
doAssert deliverAbort(request) == KeMsgConsumed
doAssert outcomes.len == 0 and replies == @[1'u8]
publish()
drain()
doAssert sent.len == 1
""",
    "wrong_vif": """
schedule()
let request = makeAbort(0)
doAssert deliverAbort(request) == KeMsgConsumed
doAssert outcomes.len == 0 and replies == @[1'u8]
publish()
drain()
doAssert sent.len == 1
""",
    "invalid_vif": """
schedule()
let request = makeAbort(2)
doAssert deliverAbort(request) == KeMsgConsumed
doAssert outcomes.len == 0 and replies == @[1'u8]
""",
    "payload_changed": """
let request = makeAbort()
currentState = 3
doAssert deliverAbort(request) == KeMsgSaved
cast[ptr uint8](request)[] = 0
schedule()
doAssert deliverAbort(request) == KeMsgConsumed
doAssert outcomes.len == 0 and replies == @[1'u8]
""",
    "response_window": """
for state in [6'u16, 8, 9]:
  reset()
  currentState = state
  let request = makeAbort()
  doAssert deliverAbort(request) == KeMsgConsumed
doAssert deauths == 3 and outcomes.len == 0 and replies == @[0'u8, 0, 0]
""",
    "idle": """
env.connectInfo = nil
currentState = 0
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgConsumed
doAssert outcomes.len == 0 and deauths == 0 and replies == @[0'u8]
""",
    "disconnecting": """
currentState = 10
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgConsumed
doAssert outcomes.len == 0 and deauths == 0 and replies == @[0'u8]
""",
    "scanning": """
currentState = 1
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgConsumed
doAssert env.cancelRequested == 1 and scanAborts == 1 and cacheClears == 1
doAssert replies == @[1'u8]
""",
    "scan_replacement": """
currentState = 1
let request = makeAbort()
scanHook = proc() =
  env.connectInfo = addr replacement
  inc rxVifEpochs[1]
  currentState = 1
doAssert deliverAbort(request) == KeMsgConsumed
doAssert cacheClears == 0 and replies == @[1'u8]
""",
    "waiting": """
currentState = 2
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgConsumed
doAssert env.cancelRequested == 1 and scanAborts == 0 and replies == @[0'u8]
""",
    "missing_pending": """
currentState = 5
let request = makeAbort()
doAssert deliverAbort(request) == KeMsgSaved
doAssert replies.len == 0 and outcomes.len == 0
ke_msg_free(keMsgHdrFromPayload(request))
""",
    "disabled_irqs": """
schedule()
let request = makeAbort()
interruptsEnabled = false
doAssert deliverAbort(request) == KeMsgConsumed
doAssert not interruptsEnabled and outcomes.len == 1
interruptsEnabled = true
""",
    "storage_limits": """
doAssert smAbortStorageLength(0x777, TASK_SM, 17) == 17
doAssert smAbortStorageLength(SM_CONNECT_ABORT_REQ, TASK_SM, 0) == 0
doAssert smAbortStorageLength(SM_CONNECT_ABORT_REQ, TASK_SM, 1) > 1
for delta in 0'u32 .. 15:
  let before = allocations
  doAssert ke_msg_try_alloc(SM_CONNECT_ABORT_REQ, TASK_SM, TASK_API, high(uint32) - delta) == nil
  doAssert allocations == before
let request = makeAbort()
doAssert keMsgHdrFromPayload(request).paramLen == 1
currentState = 0
doAssert deliverAbort(request) == KeMsgConsumed
""",
    "recycled_request": """
env.connectInfo = nil
currentState = 0
for index in 0..<100:
  let request = makeAbort()
  doAssert deliverAbort(request) == KeMsgConsumed
  doAssert smAbortTags == nil
doAssert replies.len == 100 and live.len == 0
""",
}


MUTATIONS = {
    "connection": ("smEnvView().connectInfo == identity.connection and", "true and", "saved_replacement"),
    "epoch": ("rxVifEpochs[identity.vifIndex] == identity.vifEpoch and", "true and", "saved_epoch"),
    "capture": ("  smAbortCaptureMessage(keMsgHdrFromPayload(result))", "  discard", "queued_replacement_before_dispatch"),
    "executing": ("if tag.location == smDeferredExecuting: return false", "if tag.location == smDeferredExecuting: return true", "executing"),
    "release": ("  smAbortForget(header)", "  discard", "recycled_request"),
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
    path.write_text(code + "\nreset()\n" + CASES[case] + "\nfinish()\ndoAssert smAbortTags == nil\n")
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
    assert sender.index("smAbortCaptureMessage(hdr)") < sender.index("co_list_push_back")
    assert "smAbortRegister(hdr)" in procedure(kernel, "ke_msg_try_alloc")
    assert "smAbortForget(param)" in procedure(kernel, "ke_msg_free")
    assert sender.index("smAbortForget(cast[pointer](hdr))") < sender.index("opsFn(cast[pointer](hdr))")
