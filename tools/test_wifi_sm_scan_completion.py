"""Check correlation of station scan confirmations with their originating request."""

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
                        "doAssert dst in [TASK_SM, 9'u8] and src == TASK_SCANU and size >= 1", 1)
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
    code += procedure(scan, "scanuReleaseCompletedOwner")
    code += procedure(scan, "scanuPublishCompletion")
    code += procedure(scan, "scanu_confirm").split("\ntype ProbeIeWriter", 1)[0]
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
proc release(p: pointer) =
  if p != nil: ke_msg_free(keMsgHdrFromPayload(p))
proc finish() =
  doAssert queued.len == 0 and live.len == 0 and smScanTags == nil
'''
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_unrelated_scan_confirmation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
state = SmScanningState
var unrelated: uint8
doAssert scanu_start_cfm_handler(addr unrelated) == 0
doAssert lookups == 0 and failures.len == 0 and state == SmScanningState
''')


CASES = {
    "reserved_primary_reply": r'''
begin()
let request = take()
let before = allocations
failAlloc = true
let reply = complete(request)
doAssert reply != nil and allocations == before and frees == 1
doAssert scanu_start_cfm_handler(reply) == 0
doAssert lookups == 1 and failures == @[(12'u16, 0xFFFF'u16)]
release(reply)
doAssert not smScanNeedsService()
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
doAssert smScanAcceptReply(joinReply, SCANU_JOIN_CFM)
release(joinReply)
finish()
''',
    "join_type_survives_scan_retry_phase": r'''
begin(true)
let reply = complete(take(), 0, 0)
doAssert reply != nil and keMsgHdrFromPayload(reply).id == SCANU_JOIN_CFM
doAssert smScanAcceptReply(reply, SCANU_JOIN_CFM)
release(reply)
finish()
''',
    "stale_before_completion": r'''
begin()
let request = take()
replaceOwner()
doAssert complete(request) == nil
doAssert failures.len == 0 and lookups == 0 and not smScanNeedsService()
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
doAssert not smScanNeedsService()
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
    "reply_header_validation": r'''
for mutation in 0 .. 3:
  begin()
  let reply = complete(take())
  let header = keMsgHdrFromPayload(reply)
  case mutation
  of 0: inc header.id
  of 1: header.srcId = 0
  of 2: header.destId = 9
  else: header.paramLen = 0
  doAssert scanu_start_cfm_handler(reply) == 0
  doAssert lookups == 0 and failures.len == 0
  release(reply)
  doAssert smScanNeedsService()
  smScanService()
  doAssert failures == @[(12'u16, 0xFFFF'u16)]
  finish()
''',
    "failed_completion": r'''
for joining in [false, true]:
  begin(joining)
  let reply = complete(take(), 4)
  doAssert not smScanAcceptReply(reply, if joining: SCANU_JOIN_CFM else: SCANU_START_CFM)
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
  doAssert not smScanAcceptReply(reply, id)
  doAssert sm.cancelRequested == 0 and lookups == 0
  doAssert failures == @[((if joining: 25'u16 else: 26'u16), 0xFFFF'u16)]
  doAssert not smScanAcceptReply(reply, id) and failures.len == 1
  release(reply)
  finish()
''',
    "lost_request_and_reply": r'''
for loseReply in [false, true]:
  begin()
  let request = take()
  if loseReply: release(complete(request))
  else: release(request)
  doAssert smScanNeedsService() and live.len == 0
  smScanService()
  smScanService()
  doAssert failures == @[(12'u16, 0xFFFF'u16)]
  finish()
''',
    "lost_old_owner": r'''
begin()
release(take())
replaceOwner()
smScanService()
doAssert failures.len == 0 and not smScanNeedsService()
finish()
''',
    "reservation_allocation_failure": r'''
setup()
onAlloc = proc() = failAlloc = true
submit(false)
doAssert queued.len == 0 and allocations == 2 and live.len == 0
doAssert failures == @[(14'u16, 0xFFFF'u16)] and not smScanNeedsService()
finish()
''',
    "reservation_reentry": r'''
setup()
onAlloc = proc() = onAlloc = replaceOwner
submit(false)
doAssert queued.len == 0 and allocations == 2 and live.len == 0
doAssert failures.len == 0 and not smScanNeedsService()
finish()
''',
    "completion_state_reentry": r'''
begin()
let request = take()
onScanState = replaceOwner
let reply = complete(request)
doAssert reply != nil and scanu_start_cfm_handler(reply) == KeMsgConsumed
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
doAssert smScanAcceptReply(joinReply, SCANU_JOIN_CFM)
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
doAssert smScanAcceptReply(reply, SCANU_JOIN_CFM)
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
def test_owned_request_waits_for_idle(tmp_path: Path, handler: str, mode: str) -> None:
    body = procedure((FW / "task_handlers.nim").read_text(), handler)
    admission = body.split("  let req = scanuStartReqView(param)", 1)[0] + "  return KeMsgConsumed\n"
    checks = f'''
begin({str(handler == "scanu_join_req_handler").lower()})
let request = take()
doAssert {handler}(request) == KeMsgSaved
doAssert live.len == 2
replaceOwner()
doAssert {handler}(request) == KeMsgConsumed
release(request)
finish()
'''
    run_program(tmp_path, mode, source() + admission + checks)


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
def test_main_loop_services_lost_scan(tmp_path: Path, mode: str) -> None:
    code = source() + r'''
proc wifiEventPendingWork(): bool = false
proc wifiKernelTimerPendingWork(): bool = false
proc wifiMmTimerPendingWork(): bool = false
proc wifiMessagePendingWork(): bool = false
proc wifiResetEventPending(): bool = false
proc smBssNeedsService(): bool = false
proc smCleanupNeedsService(): bool = false
proc smActivationNeedsService(): bool = false
proc smRegistrationNeedsService(): bool = false
proc smRegistrationService() = discard
proc smBssService() = discard
proc smCleanupService() = discard
proc smActivationService() = discard
proc wifiDispatchScheduledEvent(): bool = false
'''
    runtime = (FW / "task_init_main.nim").read_text()
    code += procedure(runtime, "wifiMainHasPendingWork") + procedure(runtime, "wifiDrainScheduledWork")
    code += r'''
begin()
release(take())
doAssert wifiMainHasPendingWork()
doAssert wifiDrainScheduledWork()
doAssert not wifiMainHasPendingWork()
doAssert failures == @[(12'u16, 0xFFFF'u16)]
finish()
'''
    run_program(tmp_path, mode, code)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_join_primary_survives_api_allocation_failure(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
begin(true)
failAlloc = true
let reply = complete(take())
doAssert reply != nil and allocations == 3
doAssert smScanAcceptReply(reply, SCANU_JOIN_CFM)
release(reply)
doAssert failures.len == 0 and not smScanNeedsService()
finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_channel_drain_preserves_current_scan_only(tmp_path: Path, mode: str) -> None:
    code = source() + r'''
var chanTbttTimerOwner, chanConnlessTimerOwner: tuple[valid: bool, resetEpoch: uint32]
var failIdle: bool
proc mm_force_idle_req(): bool =
  doAssert not enabled
  inc txResetEpoch
  not failIdle
proc smRegistrationPreserveAcrossChannelReset(previous: uint32) = discard
'''
    code += procedure((FW / "channel_timer.nim").read_text(), "chanForceIdle")
    run_program(tmp_path, mode, code + r'''
for joining in [false, true]:
  for replyQueued in [false, true]:
    begin(joining)
    let request = take()
    var reply: pointer
    if replyQueued: reply = complete(request)
    for channel in 0 ..< 3:
      chanConnlessTimerOwner = (true, txResetEpoch)
      doAssert chanForceIdle()
      doAssert enabled and chanConnlessTimerOwner.resetEpoch == txResetEpoch
    if not replyQueued: reply = complete(request)
    let id = if joining: SCANU_JOIN_CFM else: SCANU_START_CFM
    doAssert smScanAcceptReply(reply, id)
    release(reply)
    finish()

for change in 0 ..< 4:
  begin()
  let request = take()
  case change
  of 0: inc txResetEpoch # Full recovery does not use chanForceIdle.
  of 1:
    replaceOwner()
    doAssert chanForceIdle()
  of 2:
    failIdle = true
    doAssert not chanForceIdle()
    failIdle = false
  else:
    inc rxVifEpochs[conn.vifIdx]
    doAssert chanForceIdle()
  doAssert complete(request) == nil
  finish()

begin()
release(take())
doAssert smScanNeedsService()
doAssert chanForceIdle()
smScanService()
doAssert failures == @[(12'u16, 0xFFFF'u16)]
finish()
''')
