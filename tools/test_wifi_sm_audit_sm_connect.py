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
    re-queued on the same entry 1 ms later with its stamp, and delivered."""
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


def test_build_overtaken_by_tx_reset_keeps_its_deadline(tmp_path: Path) -> None:
    """The re-check idiom of the SM structure audit: sm_auth_send and
    sm_assoc_req_send re-checked their frame and the attempt (with the TX
    reset epoch) after every call and returned silently before entering
    state 6 or 8, so a TX reset or a deleted station inside the build (from
    txl_frame_get's pool recovery) left SM in state 5 or 7 with no deadline
    (the former station_replacement case asserted exactly that: no push, no
    failure). A build now commits, the TX layer refuses the overtaken frame,
    and the response deadline retries."""
    run_nim(tmp_path, response_source() + r'''
for kind in 0..1:
  for change in [9, 3]:        # inc txResetEpoch; delete the AP station
    for stage in 1..5:         # txl_frame_get .. the last pre-push call
      setup(kind)
      hook = stage
      action = change
      perform(kind)
      let waiting = if kind == 0: SmAuthenticatingState else: SmAssocRspState
      doAssert pushes == 1 and releases == 1 and failures == 0
      doAssert currentState == waiting and timerDelay != 0,
        "[SMSTRUCT-RECHECK] the build stopped with SM in state " & $currentState &
        " and nothing armed"
      deliverTimeout(fireDeadline())
      doAssert pushes == 2 and conn.retry == 1 and failures == 0
''', finding="SMSTRUCT-RECHECK")


# --- BSS parameter batch (state 4) -------------------------------------------

def bss_source() -> str:
    from test_wifi_sm_bss_allocation import LIFETIME, source, types
    return (source(types(), (FW / "scan_station_ap_me.nim").read_text()) + LIFETIME
            + "var txResetEpoch: uint32\n")


def test_bss_answer_after_the_attempt_ended(tmp_path: Path) -> None:
    """The attempt ends after the replier answered but before SM took the
    answer: the answer is stale and the next attempt is not advanced."""
    run_nim(tmp_path, bss_source() + r'''
setup()
sm_set_bss_param()
acknowledgeBss()
sm_send_next_bss_param()
doAssert state == SmSettingBssState and sent.len == 2
let reply = smTakeReply(smOwn.request, MM_SET_BSSID_REQ + 1)
doAssert reply != nil
# A newer SM operation owns SM before the queued confirmation is dispatched.
discard smGo(SmAuthenticatingState)
doAssert not smTakeAnswer(reply), "stale BSS reply advanced a retired batch"
ke_msg_free(keMsgHdrFromPayload(reply))
doAssert failures.len == 0 and state == SmAuthenticatingState and sent.len == 2,
  "retired BSS batch reported to or advanced the replacement attempt"
finish()
''')


def test_bss_batch_survives_tx_reset(tmp_path: Path) -> None:
    """SMCONN-F5 by construction: the batch is SM's live request and its
    reserved reply; nothing in it reads the TX reset epoch."""
    bss = (FW / "station_bss.nim").read_text()
    assert "txResetEpoch" not in bss and "smTx" not in bss
    run_nim(tmp_path, bss_source() + r'''
setup()
sm_set_bss_param()
acknowledgeBss()
sm_send_next_bss_param()
doAssert state == SmSettingBssState and sent.len == 2
inc txResetEpoch # Same connection, VIF and station; only TX was drained.
acknowledgeBss()
sm_send_next_bss_param()
doAssert sent.len == 3 and state == SmSettingBssState and failures.len == 0,
  "[SMCONN-F5] BSS batch stopped after TX reset; SM left in state " & $state
finish()
''', finding="SMCONN-F5")


def test_sta_vif_removed_during_the_bss_batch_ends_the_attempt(tmp_path: Path) -> None:
    """SCAN-N3 in state 4 (stage 9g). sm_set_bss_param returned silently when
    the STA VIF was gone, and later each answer re-checked the VIF. Now
    vif_mgmt_unregister tells SM (smStaVifRetired): the attempt ends at the
    removal, wherever the batch is, its unsent requests and the messages SM
    parked are freed, and the request in flight is no longer awaited, so its
    replier drops it. The real station_bss.nim and station_sm.nim run here."""
    run_nim(tmp_path, bss_source() + "const SmIdleState = 0'u16\n"
            + station_sm_source("smAbandon", "smStaVifRetired", record=False) + r'''
for step in 0..8:
  setup()
  sm_set_bss_param()
  for done in 0 ..< step:
    acknowledgeBss()
    sm_send_next_bss_param()
  doAssert state == SmSettingBssState and sent.len == step + 1
  # The attempt's parked messages, allocated so that their release shows.
  let info = ke_msg_alloc(0x1000'u16, TASK_SM, 9, sizeof(Connection).uint32)
  cast[ptr Connection](info)[] = connection
  sm.connectInfo = info
  sm.connectIndMsg = ke_msg_alloc(0x1002'u16, 9, TASK_SM, 4)
  vif.vifType = 4       # vif_mgmt_unregister frees the slot,
  smStaVifRetired(1)    # then tells SM.
  doAssert state == SmIdleState,
    "[SCAN-N3] SM stayed in state " & $state & " with its STA VIF removed"
  doAssert sm.connectInfo == nil and sm.connectIndMsg == nil and sm.pendingBssParams.first == nil
  doAssert smOwn.request == nil and smOwn.reply == nil and not smAwaits(sent[^1])
  doAssert failures.len == 0 and sent.len == step + 1
  finish()
''')


def test_abort_in_states_3_and_4_ends_the_attempt(tmp_path: Path) -> None:
    """The plan's SMCONN-F5/F6 item: abort is no longer saved in states 3/4.
    The real sm_connect_abort_req_handler ends the attempt there with
    WLAN_FW_CONNECT_ABORT_BY_USER_NO_DEAUTH, as in states 5/7, and confirms."""
    from test_wifi_station_abort import program_source as abort_source
    run_nim(tmp_path, abort_source() + r'''
for state in [3'u16, 4]:
  reset()
  outcomes.setLen(0)
  replies.setLen(0)
  currentState = state
  let request = makeAbort()
  doAssert deliverAbort(request) == KeMsgNoFree,
    "abort saved in state " & $state & "; the attempt keeps running"
  doAssert outcomes == @[(24'u16, 3'u16)] and replies == @[0'u8]
  finish()
''')


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
    """SMCONN-F7: MM_RESET_REQ -> me_init -> sm_init with an attempt parked.
    sm_init kept connectIndMsg (every later connect answered busy) and then
    cleared both pointers without freeing the SM_CONNECT_REQ and the 860-byte
    SM_CONNECT_IND (a leak). It now drops the attempt through smAbandon, which
    frees both, and the next connect is admitted."""
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
''' + station_sm_source("smGo", "smAbandon") + procedure((FW / "scan_station_ap_me.nim").read_text(), "sm_init") + r'''
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
  doAssert released == @[cast[pointer](addr previous), cast[pointer](addr parked[0])],
    "[SMCONN-F7] sm_init from state " & $waiting & " leaked the parked SM_CONNECT_REQ " &
    "or SM_CONNECT_IND"
  released.setLen(0)
  cancellations = 0
  let status = sm_connect_req_handler(addr request)
  doAssert status == KeMsgNoFree and confirmationStatus == 0, "[SMCONN-F7] after " &
    "sm_init from state " & $waiting & " SM_CONNECT_REQ answered status " &
    $confirmationStatus & "; stale connectIndMsg=" & $(sm.connectIndMsg == addr parked[0])
''', finding="SMCONN-F7")


# --- Activation exchange (state 9) --------------------------------------------

def test_activation_survives_tx_reset(tmp_path: Path) -> None:
    """SMCONN-F6 by construction: the activation belongs to SM's state-9
    operation; a TX reset does not end it."""
    activation = (FW / "station_activation.nim").read_text()
    assert "txResetEpoch" not in activation and "smTx" not in activation
    from test_wifi_activation_exchange import source
    run_nim(tmp_path, source() + r'''
begin()
inc txResetEpoch # Same connection, VIF and station; only TX was drained.
drain()
doAssert connected == 1 and failures.len == 0, "[SMCONN-F6] activation stopped " &
  "after TX reset with no connect indication; SM left in state " & $state &
  " (applied=" & $applied.len & ")"
finish()
''', finding="SMCONN-F6")


def test_activation_request_answered_through_the_me_forward(tmp_path: Path) -> None:
    """SMSTRUCT-N1 (activation, BSS batch): ME forwards SM's request to MM
    and MM's answer reaches SM in the reply SM reserved before sending, so
    the forward allocates nothing and cannot drop the answer. A request SM
    no longer waits on is dropped by its replier, and the forward ME already
    started completes and leaves ME idle."""
    from test_wifi_activation_exchange import source
    run_nim(tmp_path, source() + r'''
begin()
let options = takeReply(1)
consumeReply(options)
ke_msg_free(keMsgHdrFromPayload(options))
doAssert smActivation.step == 2 and smOwn.reply != nil
let reserved = smOwn.reply
let before = calls
holdMMMode = true
drain()
doAssert meControlReply == reserved and psHeldRequest != nil and calls == before
releaseMM()
let answer = takeReply(2)
doAssert answer == reserved, "[SMSTRUCT-N1] the forwarded answer is not SM's reserved reply"
consumeReply(answer)
ke_msg_free(keMsgHdrFromPayload(answer))
doAssert connected == 1 and meState == MeIdleState
finish()
''')


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


def test_registration_request_is_always_answered(tmp_path: Path) -> None:
    """SMSTRUCT-N1 (registration): MM consumed SM's MM_STA_ADD_REQ without a
    reply when its admission failed, and only a forget hook and a polled
    service turned that into sm_connect_ind(15). MM now answers SM's live
    request in place whatever mm_sta_add returns, and needs no memory to do
    so, so state 3 always ends: with the BSS batch or with
    sm_connect_ind(15). A station registered for an attempt that SM has
    left since (sm_init on MM_RESET_REQ) is deleted, not leaked."""
    from test_wifi_message_allocation import run_program
    from test_wifi_registration_exchange import source
    run_program(tmp_path, "checked", source() + r'''
for status in [0'u8, 1'u8, 7'u8]:
  resetExchange()
  registerStatus = status
  let request = issue()
  failAlloc = true
  let reply = completeRegistration(request)
  failAlloc = false
  doAssert reply == request, "[SMSTRUCT-N1] MM consumed SM's registration without an answer"
  doAssert mm_sta_add_cfm_handler(reply) == 0
  release(reply)
  if status == 0: doAssert bssCalls == 1 and state == 4 and failures.len == 0
  else: doAssert failures == @[(15'u16, 0xFFFF'u16)] and bssCalls == 0
  finishExchange()
resetExchange()
let reply = completeRegistration(issue())
discard smGo(SmIdleState)
doAssert mm_sta_add_cfm_handler(reply) == 0
release(reply)
doAssert deletions == 1 and stations[0].valid == 0,
  "a station registered for an attempt SM has left was leaked"
finishExchange()
''')


def test_sta_vif_removed_during_registration_ends_the_attempt(tmp_path: Path) -> None:
    """SCAN-N3 in state 3 (stage 9g). A registration whose STA VIF was
    removed after the join used to reach MM, which applied it to the freed
    slot (later: answered it with status 1). Now the removal ends the attempt
    at once (smStaVifRetired) and MM drops the request SM no longer waits on:
    nothing is registered for the removed VIF, even when its slot is
    registered again at the same index before MM runs.

    When MM registered the station before the removal, its answer comes to
    an idle SM, and smStaAddRetire asks MM to delete a station that the
    removal left on no VIF's list. MM's delete is then done and leaves the
    station valid (test_wifi_station_lifetime runs the real mmStaDelTry);
    it had been retried every 100 ms until MM_RESET."""
    from test_wifi_message_allocation import run_program
    from test_wifi_registration_exchange import source
    run_program(tmp_path, "checked", source() + r'''
for readded in [false, true]:
  resetExchange()
  let request = issue()
  allocateAttempt()
  removeVif(readded)
  doAssert state == SmIdleState and smOwn.request == nil,
    "[SCAN-N3] SM stayed in state " & $state & " with its STA VIF removed"
  doAssert completeRegistration(request) == nil and registrations == 0,
    "a registration was applied to a removed or re-added VIF"
  doAssert failures.len == 0 and bssCalls == 0 and deletions == 0
  finishExchange()

for readded in [false, true]:
  resetExchange()
  let reply = completeRegistration(issue())
  doAssert registrations == 1 and stations[0].valid == 1 and stations[0].listed
  allocateAttempt()
  removeVif(readded)
  doAssert state == SmIdleState and smOwn.request == nil and smOwn.answer == nil
  let sentBefore = sent.len
  doAssert mm_sta_add_cfm_handler(reply) == 0
  release(reply)
  doAssert unlistedDeletes == 1 and deletions == 0 and stations[0].valid == 1,
    "the stale answer's station was not left to MM as a removed VIF's station"
  doAssert failures.len == 0 and bssCalls == 0 and state == SmIdleState
  doAssert sent.len == sentBefore
  finishExchange()
''')


# --- Cleanup (state 10) and the deferred auth/assoc request (states 5/7) ----

@pytest.mark.parametrize("step", range(4))
@pytest.mark.parametrize("fate", ["vif_retired", "no_memory", "sm_init"])
def test_cleanup_request_is_always_answered(tmp_path: Path, step: int, fate: str) -> None:
    """SMSTRUCT-N1 (cleanup): the cleanup had no loss path. A request of its
    that MM or ME consumed without the reply (an admission refused once the
    VIF was retired, or after the cleanup was replaced) left it waiting in
    state 10, or a polled service cancelled it unreported. The cleanup now
    sends with SM's reserved reply (smSendReserved; the station delete is
    answered in place), so every request it waits on is answered. The
    removal of the VIF ends the cleanup at once (smStaVifRetired), and the
    repliers drop its requests unapplied (smStaleRequest; the entry check of
    mm_sta_del_req_handler). A step whose messages cannot be
    allocated is retried from SM's timer, never skipped. The real cleanup,
    station_sm.nim, ME's control exchange and the ME/MM repliers run here."""
    from test_wifi_sm_cleanup import CASES, program
    code = program("disconnect").removesuffix(CASES["disconnect"])
    run_nim(tmp_path, code + f"const step = {step}\nconst fate = \"{fate}\"\n" + r'''
proc untilReplier(target: int) =
  while smCleanup.step < target: driveOne()
proc untilAnswer(target: int) =
  untilReplier(target)
  while keMsgQueueSent.first == nil or keMsgQueueSent.first.destId != TASK_SM: driveOne()
case fate
of "vif_retired":
  sm_disconnect_process(addr vifs[0], 19, 3)
  untilReplier(step)
  retireVif(0)
of "no_memory":
  if step == 0: failEveryAllocation = true
  sm_disconnect_process(addr vifs[0], 19, 3)
  if step > 0:
    untilAnswer(step - 1)
    failEveryAllocation = true
    driveOne()
  for _ in 0 ..< 3: discard wifiDrainScheduledWork()
  doAssert smCleanup.step == step and commands.len == step,
    "[SMSTRUCT-N1] a cleanup step was skipped without memory"
  failEveryAllocation = false
else:
  sm_disconnect_process(addr vifs[0], 19, 3)
  untilReplier(step)
  smCleanupCancel()
  smGo(SmIdleState)
var dispatched = 0
while wifiMainHasPendingWork() and dispatched < 64:
  discard wifiDrainScheduledWork()
  inc dispatched
doAssert smState == SmIdleState and smOwn.teardown == tdNone and not smGuardArmed,
  "[SMSTRUCT-N1] cleanup left in state 10 after request " & $step & " (" & fate & ")"
doAssert notifications.len == 1 and allocated.len == 0 and meState == MeIdleState
if fate == "no_memory": completed()
''', finding="SMSTRUCT-N1")


@pytest.mark.parametrize("state", [4, 5, 6, 7, 8])
def test_sta_vif_removed_around_auth_ends_the_attempt(tmp_path: Path, state: int) -> None:
    """SCAN-N3 in states 4 to 8 (stage 9g). With the attempt's STA VIF
    removed, sm_auth_assoc_send_according_chan returned without sending and
    left SM waiting (later: ended the attempt there), and a request parked in
    state 5 or 7 waited for a context that never came back. The removal now
    ends the attempt at once (smStaVifRetired): a parked request is freed,
    one already queued is ignored, and nothing is sent afterwards. The real
    sm_auth_assoc_send_according_chan, deferred_auth.nim and station_sm.nim
    run here."""
    from test_wifi_deferred_auth import run_nim as run_deferred
    from test_wifi_deferred_auth_lifetime import program_source
    run_deferred(tmp_path, program_source() + f"const state = {state}'u16\n" + r'''
for kind in [5'u16, 7]:
  for queued in [false, true]:
    reset()
    if state in [5'u16, 7]:
      schedule(state)
      if queued: publish()
    else: discard smGo(state)
    removeVif()
    doAssert currentState == 0,
      "[SCAN-N3] attempt left in state " & $currentState & " with its STA VIF removed"
    doAssert chan.deferredMsg == nil and live.len == int(queued and state in [5'u16, 7])
    schedule(kind)
    publish()
    drain()
    doAssert sent.len == 0 and endings.len == 0 and live.len == 0
finish()
''')


# --- MM_SET_BEACON_INT_REQ for a STA VIF without its AP station ---------------

@pytest.mark.parametrize("mutation", [False, True], ids=["guarded", "unguarded"])
def test_beacon_interval_without_ap_station_writes_nothing(tmp_path: Path, mutation: bool) -> None:
    """Stage 9g item (f). Pinned mm_hw_config_handler writes the STA beacon
    interval to sta_info_tab[vif.staIdx]; for a STA VIF without its AP
    station (0xFF) that is past the table. The port writes nothing then. The
    real MM_SET_BEACON_INT_REQ branch of mm_hw_config_handler runs here."""
    tasks = (FW / "task_handlers.nim").read_text()
    branch = tasks[tasks.index("  of 16:  # MM_SET_BEACON_INT_REQ"):tasks.index("  of 18:  # MM_SET_BASIC_RATES_REQ")]
    lines = branch.splitlines()[1:]
    body = "\n".join(line[2:] for line in lines) + "\n"
    if mutation:
        guard = "if staIdx < STA_INFO_TAB_ENTRIES.uint8:"
        assert body.count(guard) == 1
        body = body.replace(guard, "if true:", 1)
    code = r'''
const
  STA_INFO_TAB_ENTRIES = 7
  MM_SET_BEACON_INT_CFM = 17'u16
type
  MmSetBeaconIntReqPayload = object
    interval: uint16
    vifIdx: uint8
  Vif = object
    vifType, staIdx: uint8
  Station = object
    initialRateConfig: uint32
var
  vifs: array[2, Vif]
  stations: array[STA_INFO_TAB_ENTRIES, Station]
  apIntervals: int
proc vifEntryAddr(index: uint8): uint = cast[uint](addr vifs[index])
proc vifChannelAt(p: uint): ptr Vif = cast[ptr Vif](p)
proc staInfoForIdx(index: uint8): ptr Station =
  doAssert index < STA_INFO_TAB_ENTRIES, "[MM-BCN-INT] sta_info_tab indexed with " & $index
  addr stations[index]
proc vif_mgmt_set_ap_bcn_int(vif: pointer; interval: uint16) = inc apIntervals
proc beaconInterval(msgBody: pointer): uint16 =
  var cfmBasicId: uint16
''' + body + r'''
  cfmBasicId
vifs[1] = Vif(vifType: 0, staIdx: 2)
var request = MmSetBeaconIntReqPayload(interval: 100, vifIdx: 1)
doAssert beaconInterval(addr request) == MM_SET_BEACON_INT_CFM
doAssert stations[2].initialRateConfig == 100'u32 shl 10
vifs[1].staIdx = 0xFF
stations[2].initialRateConfig = 0
doAssert beaconInterval(addr request) == MM_SET_BEACON_INT_CFM
doAssert stations == default(typeof(stations)) and apIntervals == 0
'''
    if mutation:
        with pytest.raises(AssertionError):
            run_nim(tmp_path, code)
    else:
        run_nim(tmp_path, code)
