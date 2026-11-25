"""Audit the station connect SM for overlap, cancellation and reset gaps.

Each test drives the real Nim handlers through an existing host fixture. A
TX reset here means ``txl_reset`` advancing ``txResetEpoch``: a channel-context
departure or connection-less (scan/ROC) switch via ``chan_goto_idle_cb`` ->
``mm_force_idle_req``, or ``bl_reset_evt`` MAC recovery. None of these ends the
station connection in the vendor firmware; its SM timers, kernel messages and
frame callbacks all survive them. Tests marked ``xfail`` reproduce a finding
and must fail with that finding's tag; any other failure is reported as an error.
"""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure, station_sm_source


class FindingReproduced(AssertionError):
    """The program stopped at the assertion tagged with the expected finding."""


def run_nim(tmp_path: Path, code: str, finding: str = "") -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "sm_connect_audit.nim"
    path.write_text(code)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", "--assertions:on", f"--path:{ROOT / 'src'}",
         f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'check'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180,
    )
    reproduced = any(f"[{finding}]" in line and "[AssertionDefect]" in line
                     for line in result.stdout.splitlines())
    if result.returncode != 0 and finding and reproduced:
        raise FindingReproduced(result.stdout[-1500:])
    assert result.returncode == 0, result.stdout


def finding(tag: str, summary: str):
    return pytest.mark.xfail(strict=True, raises=FindingReproduced, reason=f"{tag}: {summary}")


# --- Auth/assoc response deadline (states 5..8) -------------------------------

def response_source() -> str:
    from test_wifi_station_tx_build import program_source
    scan = (FW / "scan_station_ap_me.nim").read_text()
    return program_source() + procedure(scan, "sm_auth_start") + r'''
proc fireDeadline(): pointer =
  # Expire the one armed SM_RSP_TIMEOUT_IND entry and return the message
  # ke_timer_schedule posts for it: its payload is the entry's stamp.
  doAssert timerDelay != 0
  now = timerEntry.time
  timerDelay = 0
  result = ke_msg_try_alloc(SM_RSP_TIMEOUT_IND, TASK_SM, 0xFF, 4)
  cast[ptr uint32](result)[] = timerEntry.stamp
proc deliverTimeout(message: pointer) =
  doAssert sm_rsp_timeout_ind_handler(message) == KeMsgConsumed
  ke_msg_free(keMsgHdrFromPayload(message))
'''


def test_auth_restart_retires_queued_deadline(tmp_path: Path) -> None:
    """State 6 deauth restarts auth after the old deadline is already queued."""
    run_nim(tmp_path, response_source() + r'''
setup(0)
perform(0)
doAssert currentState == SmAuthenticatingState and pushes == 1
txl_frame_release(activeFrame, false)
let stale = fireDeadline()
doAssert stale != nil
# rxu_mgt_ind_handler_sm restarts authentication on deauth/disassoc in state 6.
conn.retry = 2
sm_auth_start()
doAssert pushes == 2 and conn.retry == 0 and currentState == SmAuthenticatingState
txl_frame_release(activeFrame, false)
deliverTimeout(stale)
doAssert pushes == 2 and conn.retry == 0 and failures == 0,
  "the replaced attempt's queued deadline retried the restarted attempt"
# Exactly one deadline remains, and it belongs to the restarted attempt.
let current = fireDeadline()
doAssert current != nil
deliverTimeout(current)
doAssert pushes == 3 and conn.retry == 1 and failures == 0
''')


def test_response_deadline_survives_tx_reset(tmp_path: Path) -> None:
    """SMCONN-F1 by construction: the deadline carries the SM operation's
    stamp, which only a state change advances, so a TX reset cannot retire it."""
    run_nim(tmp_path, response_source() + r'''
for kind in 0..1:
  setup(kind)
  perform(kind)
  let waiting = if kind == 0: SmAuthenticatingState else: SmAssocRspState
  doAssert pushes == 1 and failures == 0 and currentState == waiting
  doAssert timerEntry.stamp == smOwn.op.serial
  txl_frame_release(activeFrame, false) # Sent, but the AP response is lost.
  inc txResetEpoch                      # Channel departure or MAC recovery.
  deliverTimeout(fireDeadline())
  doAssert pushes == 2 and failures == 0 and conn.retry == 1 and currentState == waiting,
    "[SMCONN-F1] response deadline dropped after TX reset; SM stays in state " &
    $currentState & " with no retry, failure or timer"
''')


def test_response_expiry_that_cannot_be_posted_is_delivered_later(tmp_path: Path) -> None:
    """SMSTRUCT-N2: the real ke_timer_schedule could not allocate the
    SM_RSP_TIMEOUT_IND, so the dispatch had claimed the expiry, asserted and
    dropped it, leaving SM in state 6 or 8 with no deadline. The expiry is now
    re-queued on the same entry 1 ms later with its stamp, and delivered. An
    association comeback chunk whose re-arm cannot be allocated ends the wait
    (and the retry policy runs) instead of losing it."""
    from test_wifi_message_allocation import run_program
    from test_wifi_response_timeout import source
    run_program(tmp_path, "checked", source() + r'''
for waiting in [SmAuthenticatingState, SmAssocRspState]:
  setup(waiting)
  let stamp = arm(0x7D000)
  failAlloc = true
  now = cast[ptr KeTimerEntry](keTimerQueue.first).time
  ke_timer_schedule()
  let entry = cast[ptr KeTimerEntry](keTimerQueue.first)
  doAssert messages.first == nil and allocationFailures == 0
  doAssert entry != nil and entry.stamp == stamp and entry.time == now + 1000,
    "[SMSTRUCT-N2] an expiry that could not be posted was dropped"
  failAlloc = false
  now = entry.time
  ke_timer_schedule()
  deliver(takeMessage())
  doAssert connection.retry == 1 and authRetries + assocRetries == 1 and failures == 0
  doAssert state == waiting and ke_timer_active(SM_RSP_TIMEOUT_IND, TASK_SM)
  finish()
setup(SmAssocRspState)
doAssert smArmResponse(smGo(SmAssocRspState), 1_000_000'u64 * 1024)
let chunk = expire()
failAlloc = true
onAlloc = proc() = failAlloc = false
deliver(chunk)
doAssert assocRetries == 1 and connection.retry == 1 and allocationFailures == 0,
  "[SMSTRUCT-N2] a comeback chunk that could not be re-armed was lost"
doAssert ke_timer_active(SM_RSP_TIMEOUT_IND, TASK_SM)
finish()
''')


def test_auth_response_after_tx_reset_completes_attempt(tmp_path: Path) -> None:
    from test_wifi_auth_response import source as auth_source
    run_nim(tmp_path, auth_source() + r'''
let p = authResponse(0, 2)
doAssert state == SmAuthenticatingState
inc txResetEpoch # The channel scheduler departed and returned while waiting.
sm_auth_handler(p)
doAssert associations == 1 and failures.len == 0, "[SMCONN-F2] open-system auth " &
  "response for the live attempt was ignored after TX reset (associations=" &
  $associations & ", txSequence=" & $smAuthExpected.txSequence & ")"
finish(p)
''', finding="SMCONN-F2")


# --- BSS parameter batch (state 4) -------------------------------------------

def bss_source() -> str:
    from test_wifi_auth_frames import layouts
    from test_wifi_sm_bss_allocation import LIFETIME, source
    names = ["MeSetPsDisableReqPayload", "MmSetBssidReqPayload", "MmSetBasicRatesReqPayload",
             "MmSetBeaconIntReqPayload", "MeSetActiveReqPayload", "MmSetEdcaReqPayload"]
    types = layouts(*names)
    types += "const\n" + "".join(f"  {name}Size = sizeof({name}).uint32\n" for name in names)
    return source(types, (FW / "scan_station_ap_me.nim").read_text()) + LIFETIME


def test_bss_reply_queued_before_cancellation(tmp_path: Path) -> None:
    """The attempt is retired after MM produced a reply but before SM consumed it."""
    run_nim(tmp_path, bss_source() + r'''
setup()
sm_set_bss_param()
acknowledgeBss()
sm_send_next_bss_param()
doAssert state == SmSettingBssState and sent.len == 2
let reply = smBssTakeReply(smBss.request, SmBssRequests[smBss.step] + 1, 0)
doAssert reply != nil
# A newer attempt owns SM before the queued confirmation is dispatched.
sm.connectInfo = addr replacement
state = SmAuthenticatingState
doAssert smBssNeedsService()
smBssService()
doAssert not smBss.active and sm.pendingBssParams.first == nil
doAssert not smBssConsumeReply(reply), "stale BSS reply advanced a retired batch"
ke_msg_free(keMsgHdrFromPayload(reply))
doAssert failures.len == 0 and state == SmAuthenticatingState and sent.len == 2,
  "retired BSS batch reported to or advanced the replacement attempt"
finish()
''')


def test_bss_batch_survives_tx_reset(tmp_path: Path) -> None:
    run_nim(tmp_path, bss_source() + r'''
setup()
sm_set_bss_param()
acknowledgeBss()
sm_send_next_bss_param()
doAssert state == SmSettingBssState and sent.len == 2 and smBss.active
inc txResetEpoch # Same connection, VIF and station; only TX was drained.
if smBssNeedsService(): smBssService()
doAssert smBss.active or failures.len == 1, "[SMCONN-F5] BSS batch cancelled after " &
  "TX reset without sm_connect_ind; SM left in state " & $state &
  " where abort and disconnect are saved"
if smBss.active:
  acknowledgeBss()
  sm_send_next_bss_param()
  doAssert sent.len == 3
finish()
''', finding="SMCONN-F5")


# --- Deauthentication completions that leave state 10 -------------------------

SUPPLICANT_SUPPORT = r'''
type PlatformLogFunc = proc(level: uint32; tag, file: cstring; line: cint;
                            format: cstring) {.cdecl, varargs.}
proc getLogFunc(index: static[int]): PlatformLogFunc = nil
proc blOpsFunc(index: int): pointer = nil
proc smActivationConsumeSuccess(station: uint8): bool = false
proc smRetireEstablishedSupplicantLink(station: uint8; reason: uint16) = doAssert false
'''

DEAUTH_HELPERS = r'''
proc retireByReset() =
  # txl_reset advances the epoch, then txl_cfm_flush -> txl_frame_evt runs the
  # callback with the flush status while the reset is still active.
  let frame = activeFrame
  let context = txlCaptureFrameCallback(frame)
  let callback = frame.callback
  let argument = frame.callbackArg
  inc txResetEpoch
  txResetActive = true
  txlInvokeFrameCallback(callback, argument, 0x40000000'u32, context)
  txResetActive = false
proc startSupplicantFailure() =
  prepare(0)
  currentState = SM_ACTIVATING_STATE
  sm_handle_supplicant_result(2, 15) # 4-way handshake timeout on the AP station.
  doAssert currentState == SmDisconnectingState and pushes == 1 and failures == 0
  doAssert activeFrame.callback == cast[pointer](sm_supplicant_deauth_cfm)
'''


def deauth_source() -> str:
    from test_wifi_deauth_lifetime import source
    code = source()
    station = "    valid, instNbr: uint8\n"
    assert code.count(station) == 1
    code = code.replace(station, "    valid, instNbr, controlPortState: uint8\n", 1)
    tasks = (FW / "task_handlers.nim").read_text()
    scan = (FW / "scan_station_ap_me.nim").read_text()
    return (code + SUPPLICANT_SUPPORT
            + procedure(tasks, "sm_supplicant_deauth_cfm")
            + procedure(scan, "sm_handle_supplicant_result") + DEAUTH_HELPERS)


def test_abort_deauth_flushed_by_reset_completes_abort(tmp_path: Path) -> None:
    run_nim(tmp_path, deauth_source() + r'''
for waiting in [SmAuthenticatingState, SmAssocRspState, SM_ACTIVATING_STATE]:
  prepare(0)
  currentState = waiting
  sm_handle_connection(1, 24, cast[pointer](sm_connect_abort_deauth_cfm), cast[pointer](failed))
  doAssert currentState == SmDisconnectingState and pushes == 1 and failures == 0
  retireByReset()
  doAssert failures == 1 and failureStatus == 23, "[SMCONN-F3] abort from state " &
    $waiting & ": flushed deauth callback returned early; SM stays in state " &
    $currentState & " owning connection " & $(sm.connectInfo != nil)
''', finding="SMCONN-F3")


def test_supplicant_deauth_completion_reports_failure(tmp_path: Path) -> None:
    """Control for F4: without a reset the 4-way failure leaves state 10 once."""
    run_nim(tmp_path, deauth_source() + r'''
startSupplicantFailure()
let frame = activeFrame
let context = txlCaptureFrameCallback(frame)
let callback = frame.callback
let argument = frame.callbackArg
txlInvokeFrameCallback(callback, argument, 0x00800000'u32, context)
doAssert failures == 1 and failureStatus == 8 and failureReason == 15
# A replacement attempt must not receive the old frame's completion.
sm.connectInfo = addr replacementConn
currentState = SmAuthenticatingState
inc rxVifEpochs[1]
txlInvokeFrameCallback(callback, argument, 0x00800000'u32, context)
doAssert failures == 1 and currentState == SmAuthenticatingState
''')


def test_supplicant_deauth_flushed_by_reset_completes_failure(tmp_path: Path) -> None:
    run_nim(tmp_path, deauth_source() + r'''
startSupplicantFailure()
retireByReset()
doAssert failures == 1 and failureStatus == 8, "[SMCONN-F4] flushed supplicant " &
  "deauth callback returned early; SM stays in state " & $currentState &
  " owning connection " & $(sm.connectInfo != nil)
''', finding="SMCONN-F4")


RETIREMENTS = r'''
proc retire(kind: int) =
  ## The frame ends once, whatever retired it: sent (ACK / no ACK), flushed
  ## inside a TX reset, aged out of its station queue after one (KNOWN-TXRX-
  ## F1-SM: no reset is active then), or released after its VIF session moved on.
  let frame = activeFrame
  let context = txlCaptureFrameCallback(frame)
  let callback = frame.callback
  let argument = frame.callbackArg
  case kind
  of 0: txlInvokeFrameCallback(callback, argument, 0x80800000'u32, context)
  of 1: txlInvokeFrameCallback(callback, argument, 0x80000000'u32, context)
  of 2:
    inc txResetEpoch
    txResetActive = true
    txlInvokeFrameCallback(callback, argument, 0x40000000'u32, context)
    txResetActive = false
  of 3:
    inc txResetEpoch
    txlInvokeFrameCallback(callback, argument, 0x40000000'u32, context)
  else:
    inc rxVifEpochs[frame.vifIdx]
    txlInvokeFrameCallback(callback, argument, 0x40000000'u32, context)
  # A second completion of the same frame (or of an older one) is stale.
  txlInvokeFrameCallback(callback, argument, 0x40000000'u32, context)
'''


def test_teardown_deauth_ends_its_wait_on_any_retirement(tmp_path: Path) -> None:
    """SMCONN-F3/F4 by construction: the deauthentication frame carries the
    teardown's stamp, so no TX reset or session check can strand state 10."""
    run_nim(tmp_path, deauth_source() + RETIREMENTS + r'''
for kind in 0 .. 4:
  for waiting in [SmAuthenticatingState, SmAssocRspState, SM_ACTIVATING_STATE]:
    prepare(0)
    currentState = waiting
    sm_handle_connection(1, 24, cast[pointer](sm_connect_abort_deauth_cfm), cast[pointer](failed))
    doAssert currentState == SmDisconnectingState and smOwn.teardown == tdDeauthWait
    retire(kind)
    doAssert failures == 1 and failureStatus == 23 and failureReason == 3,
      "abort from state " & $waiting & " not completed by retirement " & $kind
    doAssert smOwn.teardown == tdCleanup and not smGuardArmed
  startSupplicantFailure()
  retire(kind)
  doAssert failures == 1 and failureStatus == 8 and failureReason == 15,
    "supplicant failure not completed by retirement " & $kind
''')


def test_unconfirmed_deauth_is_ended_by_its_guard(tmp_path: Path) -> None:
    """Critique backstop for tdDeauthWait: a deauthentication frame postponed
    on a context that never returns is not aged on a STA-only device. Its
    guard timer ends the wait as a flush would; the frame's late confirmation
    is then stale."""
    run_nim(tmp_path, deauth_source() + RETIREMENTS + r'''
proc expireGuard() =
  doAssert smGuardArmed and smOwn.guard.callback == cast[pointer](smDeauthGuardExpired)
  cast[proc(env: pointer) {.cdecl.}](smOwn.guard.callback)(cast[pointer](smOwn.guard.env.uint))
for waiting in [SmAuthenticatingState, SmAssocRspState, SM_ACTIVATING_STATE]:
  prepare(0)
  currentState = waiting
  sm_handle_connection(1, 24, cast[pointer](sm_connect_abort_deauth_cfm), cast[pointer](failed))
  let late = activeFrame
  let lateCallback = late.callback
  let lateArgument = late.callbackArg
  let context = txlCaptureFrameCallback(late)
  expireGuard()
  doAssert failures == 1 and failureStatus == 23 and not smGuardArmed
  txlInvokeFrameCallback(lateCallback, lateArgument, 0x80800000'u32, context)
  doAssert failures == 1
  # The next attempt's abort waits for its own frame: the late confirmation
  # of the earlier one is stale, even while the same kind of wait is live.
  smGo(SmIdleState)
  sm.connectInfo = addr conn
  smGo(waiting)
  sm_handle_connection(1, 24, cast[pointer](sm_connect_abort_deauth_cfm), cast[pointer](failed))
  doAssert smOwn.teardown == tdDeauthWait
  txlInvokeFrameCallback(lateCallback, lateArgument, 0x80800000'u32, context)
  doAssert failures == 1 and smOwn.teardown == tdDeauthWait,
    "an earlier wait's frame ended a later teardown"
  retire(0)
  doAssert failures == 2
startSupplicantFailure()
expireGuard()
doAssert failures == 1 and failureStatus == 8 and failureReason == 15
# Clearing the wait disarms the guard: the user disconnect path.
prepare(0)
sm.connectInfo = nil
currentState = SmIdleState
sm_handle_connection(1, 19, cast[pointer](sm_disconnect_deauth_cfm), cast[pointer](failed))
doAssert smGuardArmed and smOwn.teardown == tdDeauthWait
expireGuard()
doAssert disconnects == 1 and not smGuardArmed and failures == 0
''')


# --- Re-initialisation with an attempt parked in SM ---------------------------

def test_connect_admitted_after_sm_init(tmp_path: Path) -> None:
    from test_wifi_connect_admission import admission_source
    code = admission_source()
    fields = "    vendorIeLen: uint16\n"
    assert code.count(fields) == 1
    code = code.replace(fields, fields + "    deauthPending: uint8\n    authRetryLimit: uint32\n", 1)
    run_nim(tmp_path, code + r'''
var smConnecting, smReconnectTrigger: bool
var smAuthRetryLimit: uint8
var cancellations: int
proc smActivationCancel() = inc cancellations
proc smBssCancel() = inc cancellations
proc smCleanupCancel() = inc cancellations
proc smDeferredCancel() = inc cancellations
proc ke_state_set(task: uint8; state: uint16) =
  doAssert task == TASK_SM
  currentState = state
''' + station_sm_source() + procedure((FW / "scan_station_ap_me.nim").read_text(), "sm_init") + r'''
for waiting in 1'u16 .. 10'u16:
  resetAdmission()
  # MM_RESET_REQ -> me_init -> sm_init while an attempt still owns SM.
  var previous = ConnectInfoView(vifIdx: 0)
  var parked: array[860, uint8]
  sm.connectInfo = addr previous
  sm.connectIndMsg = addr parked[0]
  currentState = waiting
  sm_init()
  doAssert currentState == SmIdleState and sm.connectInfo == nil and cancellations == 4
  cancellations = 0
  let status = sm_connect_req_handler(addr request)
  doAssert status == KeMsgNoFree and confirmationStatus == 0, "[SMCONN-F7] after " &
    "sm_init from state " & $waiting & " SM_CONNECT_REQ answered status " &
    $confirmationStatus & "; stale connectIndMsg=" & $(sm.connectIndMsg == addr parked[0])
''', finding="SMCONN-F7")


# --- Activation exchange (state 9) --------------------------------------------

def test_activation_survives_tx_reset(tmp_path: Path) -> None:
    from test_wifi_activation_exchange import source
    run_nim(tmp_path, source() + r'''
begin()
inc txResetEpoch # Same connection, VIF and station; only TX was drained.
drain()
if smActivationNeedsService(): smActivationService()
doAssert connected == 1 or failures.len == 1, "[SMCONN-F6] activation cancelled " &
  "after TX reset with no connect indication; SM left in state " & $state &
  " (applied=" & $applied.len & ")"
finish()
''', finding="SMCONN-F6")


# --- Requests consumed without their reply ----------------------------------

def test_request_on_busy_mac_is_answered_after_recovery(tmp_path: Path) -> None:
    """SMSTRUCT-N1: with TASK_MM idle but the MAC not idle, the real
    mm_hw_config_handler (BSS steps 1-7, cleanup step 1) and
    mm_set_idle_req_handler (the ME_SET_ACTIVE forward of BSS step 8 and
    cleanup step 3) assert. The assert posts a MAC recovery; the request used
    to be consumed without its reply, leaving the BSS batch or the cleanup
    waiting for good. It is now kept and answered once the recovery has
    idled the MAC and rescheduled MM's saved work."""
    from test_wifi_message_allocation import run_program
    from test_wifi_mm_idle_readiness import source as readiness_source
    run_program(tmp_path, "checked", readiness_source() + r'''
for idle in [false, true]:
  prepareReadiness(false)
  doAssert hardwareMode != 0 and mmState == 0     # MM idle, MAC not idle
  let p = if idle: idleRequest(1) else: issue()
  ke_msg_send(p)
  doAssert dispatchOne() == KeMsgSaved and assertions == 1 and replies == 0
  doAssert keMsgQueueSaved.first == keMsgHdrFromPayload(p)
  # bl_reset_evt: hal_machw_reset idles the MAC, then MM's saved work runs.
  hardwareMode = 0
  resumeSaved()
  doAssert dispatchOne() == KeMsgConsumed
  doAssert replies == 1 and assertions == 1,
    "[SMSTRUCT-N1] an owned request was consumed without its reply"
  finish()
''')
