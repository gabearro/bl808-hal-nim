"""Check SCANU's answers to SM's scan and join requests (states 1 and 2).

SCANU answers SM's request in place, so the answer is the message SM holds;
SM takes it only while the operation that sent it is live."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_sm_scan_submit import source as submission_source


def source() -> str:
    code = "var queued: seq[pointer]\nvar scanState: uint8\nvar onScanState: proc()\n" + submission_source()
    code = code.replace(procedure(code, "ke_msg_send"), """
proc ke_msg_send(p: pointer) =
  queued.add(p)
  invoke(onSend)
""", 1)
    code = code.replace(procedure(code, "ke_state_get"), """
proc ke_state_get(task: uint8): uint16 =
  if task == TASK_SCANU: scanState.uint16 else: state
""", 1)
    code = code.replace(procedure(code, "ke_state_set"), """
proc ke_state_set(task: uint8; value: uint16) =
  if task == TASK_SCANU:
    scanState = value.uint8
    invoke(onScanState)
  else:
    state = value
    invoke(onState)
""", 1)
    code = code.replace("doAssert dst == TASK_SM and src == TASK_SCANU and size >= 1",
                        "doAssert dst == 9'u8 and src == TASK_SCANU and size >= 1", 1)
    code = code.replace("vifIdx, vifType, staIdx: uint8",
                        "vifIdx, vifType, staIdx: uint8\n    macAddr: array[6, uint8]", 1)
    code += r'''
const KeMsgConsumed = 0.cint
const KeMsgNoFree = 1.cint
const KeMsgSaved = 2.cint
const TASK_API = 9'u8
const ScanuIdleState = 0'u8
const SCAN_STATUS_BUSY = 8'u8
type ScanEnvironment = object
  paramPtr, pendingJoinRxuMgtInd: pointer
  bssidFilterEnabled, requester: uint8
var scanu_env: ScanEnvironment
var scanuRequestEpoch: uint32
var lookups: int
var found: bool
proc vif_mgmt_get_vif(index: uint8): pointer = addr vifs[index]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc assert_err(a, b: cstring; line: int) = doAssert false
proc sm_get_bss_params(bss, channel: ptr pointer) =
  inc lookups
  bss[] = if found: addr target[0] else: nil
  channel[] = if found: addr config.entries[0] else: nil
'''
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "ke_msg_forward_and_change_id")
    for name in ["scanuReleaseCompletedOwner", "scanuAnswer", "scanuReply", "scanuPublishCompletion"]:
        code += procedure(scan, name)
    code += procedure(scan, "scanu_confirm").split("\ntype ProbeIeWriter", 1)[0]
    code += (FW / "station_scan.nim").read_text()
    code += procedure((FW / "task_handlers.nim").read_text(), "scanu_start_cfm_handler")
    code += r'''
proc begin(joining = false) =
  doAssert queued.len == 0
  setup()
  lookups = 0
  found = false
  scanState = 1
  onScanState = nil
  submit(joining)
proc take(): pointer =
  doAssert queued.len > 0
  result = queued[0]
  queued.delete(0)
proc complete(request: pointer; status = 0'u8; joinMode = -1): pointer =
  ## SCANU finishes SM's request; returns SM's answer.
  let header = keMsgHdrFromPayload(request)
  scanu_env = ScanEnvironment(paramPtr: request, requester: TASK_SM,
    bssidFilterEnabled: (if joinMode >= 0: joinMode.uint8 else: uint8(header.id == SCANU_JOIN_REQ)))
  scanu_confirm(status)
  for p in queued:
    if keMsgHdrFromPayload(p).destId == TASK_SM:
      doAssert result == nil
      result = p
    else:
      doAssert keMsgHdrFromPayload(p).destId == TASK_API
      ke_msg_free(keMsgHdrFromPayload(p))
  queued.setLen(0)
  doAssert result == request, "SM's request was not answered in place"
proc release(p: pointer) =
  if p != nil: ke_msg_free(keMsgHdrFromPayload(p))
proc finish() =
  doAssert queued.len == 0 and live.len == 0
'''
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_unrelated_scan_confirmation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
state = SmScanningState
let unrelated = ke_msg_alloc(SCANU_START_CFM, 9, TASK_SCANU, StatusCfmPayloadSize)
doAssert scanu_start_cfm_handler(unrelated) == 0
doAssert lookups == 0 and failures.len == 0 and state == SmScanningState
release(unrelated)
''')


CASES = {
    "answer_needs_no_allocation": r'''
begin()
let request = take()
let before = allocations
failAlloc = true
let reply = complete(request)
doAssert allocations == before and frees == 0
doAssert keMsgHdrFromPayload(reply).id == SCANU_START_CFM
doAssert keMsgHdrFromPayload(reply).paramLen == StatusCfmPayloadSize
doAssert scanu_start_cfm_handler(reply) == 0
doAssert lookups == 1 and failures == @[(12'u16, 0xFFFF'u16)]
release(reply)
finish()
''',
    "scan_to_join": r'''
begin()
let reply = complete(take())
found = true
doAssert scanu_start_cfm_handler(reply) == 0
release(reply)
doAssert lookups == 1 and queued.len == 1 and state == SmWaitingState
let joinReply = complete(take())
doAssert smScanAccept(joinReply, SCANU_JOIN_CFM)
release(joinReply)
finish()
''',
    "join_type_survives_scan_retry_phase": r'''
begin(true)
let reply = complete(take(), 0, 0)
doAssert keMsgHdrFromPayload(reply).id == SCANU_JOIN_CFM
doAssert smScanAccept(reply, SCANU_JOIN_CFM)
release(reply)
finish()
''',
    "stale_before_completion": r'''
begin()
let request = take()
replaceOwner()
let reply = complete(request)
doAssert scanu_start_cfm_handler(reply) == 0
doAssert failures.len == 0 and lookups == 0 and state == 6
release(reply)
finish()
''',
    "stale_after_completion": r'''
begin()
let reply = complete(take())
replaceOwner()
state = SmScanningState
doAssert scanu_start_cfm_handler(reply) == 0
doAssert lookups == 0 and failures.len == 0
release(reply)
finish()
''',
    "duplicate_reply": r'''
begin()
let reply = complete(take())
doAssert scanu_start_cfm_handler(reply) == 0
doAssert scanu_start_cfm_handler(reply) == 0
doAssert lookups == 1 and failures.len == 1
release(reply)
finish()
''',
    "failed_completion": r'''
for joining in [false, true]:
  begin(joining)
  let reply = complete(take(), 4)
  doAssert not smScanAccept(reply, if joining: SCANU_JOIN_CFM else: SCANU_START_CFM)
  doAssert lookups == 0 and failures == @[((if joining: 14'u16 else: 12'u16), 0xFFFF'u16)]
  release(reply)
  finish()
''',
    "failed_completion_after_cancel": r'''
for joining in [false, true]:
  begin(joining)
  let reply = complete(take(), 4)
  let id = if joining: SCANU_JOIN_CFM else: SCANU_START_CFM
  sm.cancelRequested = 1
  doAssert not smScanAccept(reply, id)
  doAssert sm.cancelRequested == 0 and lookups == 0
  doAssert failures == @[((if joining: 25'u16 else: 26'u16), 0xFFFF'u16)]
  doAssert not smScanAccept(reply, id) and failures.len == 1
  release(reply)
  finish()
''',
    "completion_state_reentry": r'''
begin()
let request = take()
onScanState = replaceOwner
let reply = complete(request)
doAssert scanu_start_cfm_handler(reply) == KeMsgConsumed
release(reply)
doAssert failures.len == 0 and lookups == 0
finish()
''',
    "confirmation_precedes_saved_scan": r'''
begin()
let request = take()
scanu_env = ScanEnvironment(paramPtr: request, requester: TASK_SM)
var savedScan: uint8
onScanState = proc() =
  if scanState == ScanuIdleState: queued.add(addr savedScan)
scanu_confirm(0)
doAssert queued.len == 2 and queued[1] == addr savedScan
let reply = take()
found = true
doAssert scanu_start_cfm_handler(reply) == KeMsgConsumed
release(reply)
doAssert lookups == 1 and take() == addr savedScan
onScanState = nil
let joinReply = complete(take())
doAssert smScanAccept(joinReply, SCANU_JOIN_CFM)
release(joinReply)
finish()
''',
    "synchronous_completion": r'''
setup()
lookups = 0
found = true
onSend = proc() =
  let reply = complete(take())
  doAssert scanu_start_cfm_handler(reply) == 0
  release(reply)
submit(false)
doAssert state == SmWaitingState and queued.len == 1
let reply = complete(take())
doAssert smScanAccept(reply, SCANU_JOIN_CFM)
release(reply)
finish()
''',
    "only_a_new_operation_ends_the_wait": r'''
# A TX reset, a channel switch or a slot epoch is not SM's operation. Only
# SM changing state makes the answer stale.
for change in 0 .. 2:
  begin()
  let request = take()
  case change
  of 0: discard
  of 1: discard smGo(SmIdleState)          # sm_init
  else: discard smGo(SmScanningState)      # a new scan from the same state
  let reply = complete(request)
  doAssert smScanAccept(reply, SCANU_START_CFM) == (change == 0)
  release(reply)
  finish()
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_scan_completion_ownership(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("handler", ["scanu_start_req_handler", "scanu_join_req_handler"])
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_sm_request_waits_for_idle(tmp_path: Path, handler: str, mode: str) -> None:
    """SCANU saves SM's live request while busy; once SM has moved on, the
    request is answered with a failure at once and SM ignores the answer."""
    body = procedure((FW / "task_handlers.nim").read_text(), handler)
    admission = body.split("  let req = scanuStartReqView(param)", 1)[0] + "  return KeMsgConsumed\n"
    joining = handler == "scanu_join_req_handler"
    checks = f'''
begin({str(joining).lower()})
let request = take()
doAssert {handler}(request) == KeMsgSaved
doAssert live.len == 1
replaceOwner()
doAssert {handler}(request) == KeMsgNoFree
let reply = take()
doAssert reply == request and statusCfmView(reply).status == SCAN_STATUS_FAIL
doAssert keMsgHdrFromPayload(reply).id == {"SCANU_JOIN_CFM" if joining else "SCANU_START_CFM"}
doAssert keMsgHdrFromPayload(reply).destId == TASK_SM
doAssert not smScanAccept(reply, keMsgHdrFromPayload(reply).id) and failures.len == 0
release(reply)
finish()
'''
    run_program(tmp_path, mode, source() + admission + checks)


@pytest.mark.parametrize("handler", ["scanu_start_req_handler", "scanu_join_req_handler"])
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_cancelled_request_retires_without_using_radio(tmp_path: Path, handler: str, mode: str) -> None:
    body = procedure((FW / "task_handlers.nim").read_text(), handler)
    admission = body.split("  let req = scanuStartReqView(param)", 1)[0] + r'''
  doAssert false, "cancelled scan reached radio admission"
  return KeMsgConsumed
'''
    joining = handler == "scanu_join_req_handler"
    run_program(tmp_path, mode, source() + admission + f'''
let joining = {str(joining).lower()}
proc handler(request: pointer): cint = {handler}(request)
''' + r'''
for busy in [true, false]:
  begin(joining)
  let request = take()
  var unrelated: uint32
  if busy:
    scanu_env.paramPtr = addr unrelated
    scanu_env.requester = TASK_API
  else:
    scanu_env = default(ScanEnvironment)
    scanState = ScanuIdleState
  let original = scanu_env
  let epoch = scanuRequestEpoch
  let stateBefore = scanState
  let allocationsBefore = allocations
  sm.cancelRequested = 1
  failAlloc = true
  doAssert handler(request) == KeMsgNoFree
  doAssert queued.len == 1 and allocations == allocationsBefore
  doAssert scanu_env == original and scanuRequestEpoch == epoch and scanState == stateBefore
  let reply = take()
  doAssert reply == request
  let id = keMsgHdrFromPayload(reply).id
  doAssert not smScanAccept(reply, id)
  doAssert sm.cancelRequested == 0 and lookups == 0
  doAssert failures == @[((if joining: 25'u16 else: 26'u16), 0xFFFF'u16)]
  doAssert not smScanAccept(reply, id) and failures.len == 1
  release(reply)
  finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_busy_host_scan_returns_confirmation_without_stealing_owner(tmp_path: Path, mode: str) -> None:
    body = procedure((FW / "task_handlers.nim").read_text(), "scanu_start_req_handler")
    admission = body.split("  let req = scanuStartReqView(param)", 1)[0] + "  return KeMsgConsumed\n"
    run_program(tmp_path, mode, source() + admission + r'''
begin()
let active = take()
scanu_env.paramPtr = active
scanu_env.requester = TASK_SM
let original = scanu_env
let epoch = scanuRequestEpoch
let client = ke_msg_try_alloc(SCANU_START_REQ, TASK_SCANU, TASK_SM, ScanuStartReqPayloadSize)
keMsgHdrFromPayload(client).srcId = TASK_API
let tries = allocations
failAlloc = true
onSend = proc() = doAssert enabled
doAssert scanu_start_req_handler(client) == KeMsgNoFree
doAssert allocations == tries and scanu_env == original and scanuRequestEpoch == epoch
doAssert scanState == 1 and queued == @[client]
let reply = take()
let header = keMsgHdrFromPayload(reply)
doAssert header.id == SCANU_START_CFM and header.srcId == TASK_SCANU and header.destId == TASK_API
doAssert header.paramLen == StatusCfmPayloadSize and statusCfmView(reply).status == SCAN_STATUS_BUSY
release(reply)
release(complete(active))
finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_join_primary_survives_api_allocation_failure(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
begin(true)
failAlloc = true
let reply = complete(take())
doAssert allocations == 2
doAssert smScanAccept(reply, SCANU_JOIN_CFM)
release(reply)
doAssert failures.len == 0
finish()
''')


def test_no_lost_exchange_machinery() -> None:
    """The exchange has no tags, loss records or polled service: SCANU
    always answers in place, so nothing can be lost."""
    sources = "".join(path.read_text() for path in FW.rglob("*.nim"))
    for gone in ["smScanForget", "smScanNeedsService", "smScanService", "smScanTags",
                 "smScanCompletionAlloc", "smScanAdmitRequest", "smScanOwnsRequest"]:
        assert gone not in sources, gone
    confirm = procedure((FW / "scan_station_ap_me.nim").read_text(), "scanu_confirm")
    assert "scanuReply(primaryId, completion.source)" in confirm
