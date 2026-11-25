"""Drive the station teardown through every way into and out of state 10.

The harness is test_wifi_sm_cleanup's: the real station_cleanup.nim over the
real ME/MM handlers and kernel queues, plus the real station_sm.nim
(smGo, smDeauthWait, the deauthentication guard, smTeardown) and the real
ends of an attempt or link: sm_connect_ind, smConnectEnd,
sm_connect_abort_process, sm_disconnect_process and the three deauthentication
confirmations. A deauthentication frame is modelled by its confirmation
argument, the stamp smDeauthWait hands out, which is all its owner sees.

Each row starts SM in one state with what that state holds (an attempt in
states 1..9, a connected link in state 0), applies one teardown and one fate
for its frame, and runs the firmware to quiescence. At every step:

  - state 10 and the teardown phase agree, and each phase has its carrier:
    the deauthentication wait has its guard armed, the cleanup is claimed;
  - an attempt or link is reported at most once.

At quiescence SM is idle with nothing allocated, exactly one report was sent,
and every stamp handed out is stale: delivering it again changes nothing.

The static part is generated from dispatch_tables.nim: no SM handler writes
TASK_SM's state itself, and smGo is the only ke_state_set(TASK_SM, ...).

A second table (test_request_answer_table, below) drives the scan, join
and registration states 1 to 3 through each fate of their one request. A
third (test_series_table) drives the BSS parameter batch (state 4) and the
activation (state 9) through each fate of each of their requests; further
tables drive the cleanup (state 10) and the deferred request (states 5 and
7). Every table has a fate in which the STA VIF is removed
(vif_mgmt_unregister's smStaVifRetired), and test_vif_removal_table removes
it from each state itself. test_saved_host_request_table drives the host's
SM_CONNECT_ABORT_REQ and SM_DISCONNECT_REQ in every state.
"""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure, station_sm_source
from test_wifi_message_allocation import run_program
from test_wifi_sm_cleanup import CASES as CLEANUP_CASES, program as cleanup_program

WIFI = FW.parent  # src/bl808/wifi

TABLE = r'''
var
  reports: int
  pending: seq[pointer]   # Confirmation arguments of frames still queued.
  stamps: seq[pointer]    # Every stamp handed out, for the stale sweep.

proc report(): int =
  ## Ends reported to the host: SM_DISCONNECT_IND or a failed SM_CONNECT_IND.
  result = notifications.len
  for reply in controlReplies:
    if reply.id == SM_CONNECT_IND_MSG: inc result

proc check(where: string) =
  doAssert (smState == SmDisconnectingState) == (smOwn.teardown != tdNone),
    where & ": state " & $smState & " with teardown " & $smOwn.teardown
  if smOwn.teardown == tdDeauthWait:
    doAssert smGuardArmed, where & ": deauthentication wait without its guard"
  if smOwn.teardown == tdCleanup:
    # The cleanup waits for its request's answer or for its retry timer.
    doAssert (smOwn.answer != nil) != smGuardArmed,
      where & ": state 10 cleanup with nothing, or two things, to move it"
  doAssert report() <= 1, where & ": ended twice"

proc frame(callback: pointer) =
  ## sm_handle_connection / sm_handle_supplicant_result: build the frame,
  ## enter the wait, push the frame carrying the wait's stamp.
  let stamp = opStampEnv(smDeauthWait(0, callback))
  pending.add(stamp)
  stamps.add(stamp)

proc confirm(callback: pointer; status: uint32) =
  ## The queued frame completes once, with any status (txl_frame_evt, the
  ## reset flush, aging or a retire drain).
  let stamp = pending.pop()
  cast[proc(p: pointer; status: uint32) {.cdecl.}](callback)(stamp, status)

proc guardExpires() =
  cast[proc(env: pointer) {.cdecl.}](smOwn.guard.callback)(
    cast[pointer](smOwn.guard.env.uint))

proc quiesce() =
  var steps = 0
  while wifiMainHasPendingWork():
    inc steps
    doAssert steps <= 40, "teardown stopped making progress"
    discard wifiDrainScheduledWork()
    check("drain")

proc start(state: uint16; attempt: bool) =
  smState = state
  smOwn = default(typeof(smOwn))
  if attempt:
    sm.connectIndMsg = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
  else:
    ke_msg_free(keMsgHdrFromPayload(sm.connectInfo))
    sm.connectInfo = nil
  check("start")
'''


def callbacks() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    return (station_sm_source("smDeauthGuardExpired", "smDeauthWait", record=False)
            + "".join(procedure(scan, name) for name in
                      ("sm_connect_abort_process", "sm_disconnect_deauth_cfm",
                       "sm_connect_abort_deauth_cfm"))
            + SUPPLICANT_LOG
            + procedure(tasks, "sm_supplicant_deauth_cfm").replace("getLogFunc(204)", "noTxLog()"))


SUPPLICANT_LOG = r'''
type TxLog = proc(level: uint32; tag, file: cstring; line: cint; message: cstring) {.cdecl, varargs.}
proc noTxLog(): TxLog = nil
'''


def source() -> str:
    code = cleanup_program("disconnect").removesuffix(CLEANUP_CASES["disconnect"])
    return code + callbacks() + TABLE


# (teardown, start states). The deauthenticating ones are what
# sm_connect_abort_req_handler (states 6, 8, 9), sm_handle_supplicant_result
# (an attempt in state 9) and sm_disconnect_req_handler (a link in state 0) do.
TEARDOWNS = {
    "fail": range(1, 10),
    "abort": (6, 8, 9),
    "supplicant": (9,),
    "disconnect": (0,),
    "loss": (0,),
}
# What becomes of the deauthentication frame.
FATES = ("ack", "noack", "flushed", "aged", "refused", "guard", "late")

STEPS = {
    "fail": "sm_connect_ind(8, 15)",
    "loss": "sm_disconnect_process(addr vifs[0], 16, 0xFFFF)",
}
DEAUTH = {
    "abort": ("sm_connect_abort_deauth_cfm", "sm_connect_abort_process(addr vifs[0], 22, 3)"),
    "supplicant": ("sm_supplicant_deauth_cfm", "smConnectEnd(9, 15)"),
    "disconnect": ("sm_disconnect_deauth_cfm", "sm_disconnect_process(addr vifs[0], 19, 3)"),
}
STATUS = {"ack": "0x80800000'u32", "noack": "0x80000000'u32",
          "flushed": "0x40000000'u32", "aged": "0x40000000'u32", "late": "0x80800000'u32"}


def row(teardown: str, state: int, fate: str) -> str:
    attempt = teardown in ("fail", "abort", "supplicant")
    body = f"start({state}'u16, {str(attempt).lower()})\n"
    if teardown in STEPS:
        body += f"{STEPS[teardown]}\ncheck(\"teardown\")\n"
    else:
        callback, refusal = DEAUTH[teardown]
        cb = f"cast[pointer]({callback})"
        body += f"frame({cb})\ncheck(\"wait\")\n"
        body += "doAssert smState == SmDisconnectingState and smOwn.teardown == tdDeauthWait\n"
        # An attempt is no longer live once its teardown started.
        body += "sm_connect_ind(5, 1)\ncheck(\"second end\")\n"
        body += "doAssert smOwn.teardown == tdDeauthWait and report() == 0\n"
        if fate == "refused":
            body += f"discard pending.pop()\n{refusal}\n"
        elif fate == "guard":
            body += "guardExpires()\n"
        elif fate == "aged":
            # Postponed while off channel, kept across a TX reset, aged out later.
            body += "inc txResetEpoch\n"
            body += f"confirm({cb}, {STATUS[fate]})\n"
        elif fate == "late":
            # The guard ended the wait first; the frame's confirmation is stale.
            body += "guardExpires()\n"
            body += "check(\"guard\")\n"
            body += f"confirm({cb}, {STATUS[fate]})\n"
        else:
            body += f"confirm({cb}, {STATUS[fate]})\n"
        body += "check(\"confirmed\")\n"
        # A frame the guard gave up on may still complete later; the stale
        # sweep below delivers it.
        body += f"doAssert pending.len == {int(fate == 'guard')}\n"
    body += "quiesce()\n"
    body += r'''
doAssert smState == SmIdleState and smOwn.teardown == tdNone
doAssert report() == 1, "teardown ended unreported or twice: " & $report()
doAssert sm.connectInfo == nil and sm.connectIndMsg == nil
doAssert allocated.len == 0 and smOwn.answer == nil
doAssert not smGuardArmed
# Every stamp handed out is stale now.
let quiet = (smState, notifications.len, controlReplies.len, smOwn.teardown)
for stamp in stamps:
  for callback in [cast[pointer](sm_disconnect_deauth_cfm),
                   cast[pointer](sm_connect_abort_deauth_cfm),
                   cast[pointer](sm_supplicant_deauth_cfm)]:
    cast[proc(p: pointer; status: uint32) {.cdecl.}](callback)(stamp, 0x40000000'u32)
  smDeauthGuardExpired(stamp)
doAssert (smState, notifications.len, controlReplies.len, smOwn.teardown) == quiet
sm_connect_ind(8, 15)
doAssert report() == 1 and smState == SmIdleState
'''
    return body


ROWS = [(teardown, state, fate)
        for teardown, states in TEARDOWNS.items()
        for state in states
        for fate in (FATES if teardown in DEAUTH else ("none",))]


@pytest.mark.parametrize("teardown,state,fate", ROWS,
                         ids=[f"{t}-{s}-{f}" for t, s, f in ROWS])
def test_teardown_table(tmp_path: Path, teardown: str, state: int, fate: str) -> None:
    run_program(tmp_path, "checked", source() + row(teardown, state, fate))


@pytest.mark.parametrize("fate", ("flushed", "guard", "refused"))
def test_teardown_table_asan(tmp_path: Path, fate: str) -> None:
    run_program(tmp_path, "asan", source() + row("abort", 9, fate))


def _code(path: Path) -> str:
    """The Nim source without comments or doc comments."""
    lines = []
    for line in path.read_text().splitlines():
        stripped = line.split("#", 1)[0]
        lines.append(stripped)
    return "\n".join(lines)


def _wifi_sources() -> list[Path]:
    return sorted(WIFI.rglob("*.nim"))


def test_one_writer_of_sm_state() -> None:
    """Ratchet: smGo is the only ke_state_set(TASK_SM, ...)."""
    writers = [(path.relative_to(WIFI), n) for path in _wifi_sources()
               for n, line in enumerate(_code(path).splitlines(), 1)
               if "ke_state_set(TASK_SM" in line]
    assert [path for path, _ in writers] == [Path("fw/station_sm.nim")], writers
    assert "ke_state_set(TASK_SM, state)" in procedure((FW / "station_sm.nim").read_text(), "smGo")


def test_state_10_is_entered_only_by_the_teardown() -> None:
    entries = sorted({path.name for path in _wifi_sources()
                      if "smGo(SmDisconnectingState" in _code(path)})
    assert entries == ["station_cleanup.nim", "station_sm.nim"], entries
    assert "smGo(SmDisconnectingState, tdCleanup)" in procedure(
        (FW / "station_cleanup.nim").read_text(), "smCleanupBegin")
    assert "smGo(SmDisconnectingState, tdDeauthWait)" in procedure(
        (FW / "station_sm.nim").read_text(), "smDeauthWait")
    teardown = (FW / "station_sm.nim").read_text()
    assert "txResetEpoch" not in _code(FW / "station_sm.nim"), "the teardown is not a TX frame"
    assert "SmDisconnectHandoff" not in "".join(_code(p) for p in _wifi_sources())
    assert teardown.count("proc smTeardown(") == 1


def sm_handlers() -> list[str]:
    tables = (FW / "dispatch_tables.nim").read_text()
    block = tables.split("var sm_default_state*", 1)[1].split("\n]\n", 1)[0]
    return re.findall(r"keMsgHandlerAddress\((\w+)\)", block)


@pytest.mark.parametrize("handler", sorted(set(sm_handlers())))
def test_sm_handler_writes_state_only_through_smgo(handler: str) -> None:
    """Every sm_default_state handler exists and leaves TASK_SM's state to
    smGo: none of them writes it, names state 10 as a target, or keeps the
    former disconnect handoff."""
    bodies = [procedure(path.read_text(), handler) for path in sorted(FW.glob("*.nim"))
              if re.search(rf"^proc {handler}\*?\(", path.read_text(), re.M)]
    assert len(bodies) == 1, handler
    body = bodies[0]
    assert "ke_state_set(TASK_SM" not in body
    assert "smGo(SmDisconnectingState" not in body
    assert "SmDisconnectHandoff" not in body


def test_table_covers_the_sm_dispatch_table() -> None:
    assert len(sm_handlers()) == 20


@pytest.mark.parametrize("waiting", [False, True], ids=["attempt", "deauth-wait"])
def test_teardown_without_a_sta_vif_still_leaves_state_10(tmp_path: Path, waiting: bool) -> None:
    """The cleanup claims a STA VIF. If the slot now holds another interface
    type, the attempt ends unreported and SM goes idle instead of keeping
    state 10 (or the attempt) without an owner."""
    run_program(tmp_path, "checked", source() + f"""
start(8'u16, true)
let waiting = {str(waiting).lower()}
if waiting:
  frame(cast[pointer](sm_connect_abort_deauth_cfm))
vifs[0].vifType = 1
if waiting: confirm(cast[pointer](sm_connect_abort_deauth_cfm), 0x80800000'u32)
else: sm_connect_ind(8, 15)
check("unclaimed")
doAssert smState == SmIdleState and smOwn.teardown == tdNone
doAssert sm.connectInfo == nil and sm.connectIndMsg == nil and allocated.len == 0
doAssert report() == 0 and not smGuardArmed
""")


# --------------------------------------------------------------------------
# The request/answer states: scan (1), join (2) and registration (3)
# --------------------------------------------------------------------------
#
# The harness is test_wifi_registration_exchange's: the real sm_scan_bss /
# sm_join_bss sender, SCANU's scanu_confirm and entry check (smScanRefused),
# MM's mm_sta_add_req_handler, the SM handlers scanu_start_cfm_handler,
# scanu_join_cfm_handler and mm_sta_add_cfm_handler, and station_sm.nim's
# smGo/smSend/smTakeAnswer. sm_connect_ind is modelled as the end of the
# attempt (state 0); test_teardown_table covers what it really runs.
#
# Each row puts SM in one state with its request outstanding, applies one
# fate and runs to quiescence. At every step a state in 1..3 holds its
# request and no other state does, and an attempt ends at most once.

FAMILY = r'''
proc held(): bool = smOwn.request != nil
proc checkFamily(where: string) =
  doAssert (state in [SmScanningState, SmWaitingState, SmAddingChanState]) == held(),
    where & ": state " & $state & " with request held " & $held()
  doAssert failures.len <= 1, where & ": the attempt ended twice"
proc startFamily(family: uint16): pointer =
  ## SM in `family` with its request sent; returns the request.
  resetExchange()
  attemptEnds = proc() = discard smGo(SmIdleState)
  case family
  of SmScanningState:
    begin(false)
    result = take()
  of SmWaitingState:
    begin(true)
    result = take()
    let vif = addr vifs[conn.vifIdx]
    vif.ap.securityFlags = 0x80000002'u32
    vif.bssid = target
    vif.operChan = addr channel
    contextIndex = 1
  else:
    result = issue()
  doAssert state == family
  checkFamily("start")
proc answer(family: uint16; request: pointer; failed: bool): pointer =
  ## The replier's answer, in place.
  if family == SmAddingChanState:
    if failed: registerStatus = 7
    result = completeRegistration(request)
  else:
    result = complete(request, (if failed: 4'u8 else: 0'u8))
  checkFamily("answered")
proc take(family: uint16; reply: pointer) =
  ## SM's handler for the answer, as the kernel dispatches it.
  case family
  of SmScanningState: discard scanu_start_cfm_handler(reply)
  of SmWaitingState: discard scanu_join_cfm_handler(reply)
  else: discard mm_sta_add_cfm_handler(reply)
  release(reply)
  checkFamily("taken")
'''

FAMILY_FATES = {
    # The answer reports success: SM sends the next state's request.
    "success": r'''
found = true
take(family, answer(family, request, false))
doAssert failures.len == 0
doAssert state == (if family == SmAddingChanState: 4'u16 else: family + 1)
''',
    "failure": r'''
take(family, answer(family, request, true))
doAssert failures.len == 1 and state == SmIdleState
''',
    # The user's abort while the request is out (states 1 and 2 save none).
    "abort": r'''
let reply = answer(family, request, false)
sm.cancelRequested = 1
take(family, reply)
doAssert failures == @[((if family == SmScanningState: 26'u16 else: 25'u16), 0xFFFF'u16)]
doAssert state == SmIdleState
''',
    # SM moved on (sm_init) before the replier ran: nothing is applied.
    "refused": r'''
discard smGo(SmIdleState)
checkFamily("reset")
if family == SmAddingChanState:
  doAssert completeRegistration(request) == nil and registrations == 0
else:
  doAssert smScanRefused(request)
  take(family, take())
doAssert failures.len == 0 and state == SmIdleState
''',
    # SM moved on after the replier answered: the answer changes nothing,
    # and a station registered for it is deleted.
    "stale": r'''
let reply = answer(family, request, false)
discard smGo(SmIdleState)
checkFamily("reset")
take(family, reply)
doAssert failures.len == 0 and state == SmIdleState
if family == SmAddingChanState: doAssert deletions == 1 and stations[0].valid == 0
''',
    # SCAN-N3: the STA VIF is removed (vif_mgmt_unregister) while the
    # replier works on the request: the attempt ends at the removal,
    # unreported, and the answer changes nothing. "vif_readded": a STA VIF
    # is registered again at the same index before the replier runs;
    # nothing is applied to it.
    "vif_gone": r'''
allocateAttempt()
removeVif()
checkFamily("removed")
doAssert failures.len == 0 and state == SmIdleState
found = true
if family == SmAddingChanState:
  doAssert completeRegistration(request) == nil and registrations == 0
else:
  take(family, answer(family, request, false))
doAssert failures.len == 0 and state == SmIdleState
''',
    "vif_readded": r'''
allocateAttempt()
removeVif(readded = true)
checkFamily("re-added")
let sentBefore = sent.len
found = true
if family == SmAddingChanState:
  doAssert completeRegistration(request) == nil and registrations == 0
else:
  take(family, answer(family, request, false))
doAssert failures.len == 0 and state == SmIdleState
doAssert sent.len == sentBefore, "a request went out for the re-added VIF"
''',
}

# The replier answered before the STA VIF was removed (and, "readded", a STA
# VIF registered again at the index): the answer comes to an idle SM and
# changes nothing. The station MM registered for it is on no VIF's list
# after the removal, so MM's delete (smStaAddRetire) is done and leaves it
# valid instead of being retried for ever (test_wifi_station_lifetime runs
# the real mmStaDelTry).
ANSWERED_THEN_REMOVED = r'''
found = true
let reply = answer(family, request, false)
allocateAttempt()
removeVif(readded = READDED)
checkFamily("removed")
doAssert failures.len == 0 and state == SmIdleState
let sentBefore = sent.len
take(family, reply)
doAssert failures.len == 0 and state == SmIdleState
doAssert sent.len == sentBefore, "a stale answer sent a request"
if family == SmAddingChanState:
  doAssert unlistedDeletes == 1 and deletions == 0 and stations[0].valid == 1
'''
FAMILY_FATES["answered_vif_gone"] = ANSWERED_THEN_REMOVED.replace("READDED", "false")
FAMILY_FATES["answered_vif_readded"] = ANSWERED_THEN_REMOVED.replace("READDED", "true")

FAMILY_ROWS = [(family, fate) for family in (1, 2, 3) for fate in FAMILY_FATES
               if not (family == 3 and fate == "abort")]


def family_source() -> str:
    from test_wifi_registration_exchange import source as registration_source
    code = registration_source()
    stub = "  failures.add((status, reason))\n  invoke(onFailure)\n"
    assert stub in code
    code = "var attemptEnds: proc()\n" + code.replace(
        stub, stub + "  if attemptEnds != nil: attemptEnds()\n", 1)
    return code + FAMILY


@pytest.mark.parametrize("family,fate", FAMILY_ROWS, ids=[f"{s}-{f}" for s, f in FAMILY_ROWS])
def test_request_answer_table(tmp_path: Path, family: int, fate: str) -> None:
    run_program(tmp_path, "checked", family_source() + f"""
let family = {family}'u16
let request = startFamily(family)
""" + FAMILY_FATES[fate] + r'''
# Quiescence: what is left is the next state's own request.
while queued.len != 0: release(take())
discard smGo(SmIdleState)
checkFamily("end")
finishExchange()
''')


def test_request_answer_states_have_one_exit() -> None:
    """Each SM answer handler takes the answer with smTakeAnswer (directly
    or through smScanAccept) and nothing else in the firmware tracks,
    forgets or services the scan, join or registration exchange."""
    tasks = (FW / "task_handlers.nim").read_text()
    for handler, take in [("scanu_start_cfm_handler", "smScanAccept(param, SCANU_START_CFM)"),
                          ("scanu_join_cfm_handler", "smScanAccept(param, SCANU_JOIN_CFM)"),
                          ("mm_sta_add_cfm_handler", "smTakeAnswer(param)")]:
        assert take in procedure(tasks, handler), handler
    assert "smTakeAnswer(reply)" in procedure((FW / "station_scan.nim").read_text(), "smScanAccept")
    senders = [path.name for path in _wifi_sources() if "smSend(" in _code(path)]
    assert sorted(senders) == ["scan_station_ap_me.nim", "station_cleanup.nim",
                               "station_sm.nim", "task_handlers.nim"], senders
    main = _code(FW / "task_init_main.nim")
    assert "smScanNeedsService" not in main and "smRegistrationNeedsService" not in main


# --------------------------------------------------------------------------
# The request series: BSS parameter batch (4) and activation (9)
# --------------------------------------------------------------------------
#
# The harnesses are test_wifi_bss_confirmations' (state 4: the real
# station_bss.nim, ME's control exchange and SM's handlers over a model MM)
# and test_wifi_activation_exchange's (state 9: the real
# station_activation.nim, ME's exchange, mm_set_ps_options_req_handler and
# SM's handlers). Each row stops the series at one request and applies one
# fate. After every dispatch: SM holds an answer to wait for exactly while
# the series is live, a reserved reply only together with its request, and
# the attempt is reported at most once. At quiescence nothing is allocated
# and ME is idle.

SERIES_FATES = {
    # The series runs to its end.
    "answered": "advanceTo(step)\nrun(\"answered\")\n",
    # A TX reset (channel switch, MAC recovery) changes nothing.
    "tx_reset": "advanceTo(step)\ninc txResetEpoch\nrun(\"reset\")\n",
    # The attempt ends before the replier ran: the request is dropped, or
    # ME finishes a forward it started.
    "ended_before_reply": "advanceTo(step)\nendAttempt()\ncheck(\"ended\")\nrun(\"ended\")\n",
    # The attempt ends with the answer queued: SM ignores it.
    "ended_after_reply": "let answer = answerAt(step)\nendAttempt()\nconsumeReply(answer)\n"
                         "ke_msg_free(keMsgHdrFromPayload(answer))\ncheck(\"stale\")\nrun(\"stale\")\n",
    # An answer delivered twice counts once.
    "duplicate": "let answer = answerAt(step)\nconsumeReply(answer)\nconsumeReply(answer)\n"
                 "ke_msg_free(keMsgHdrFromPayload(answer))\ncheck(\"duplicate\")\nrun(\"duplicate\")\n",
}

BSS_SERIES = r'''
var txResetEpoch: uint32
proc check(where: string) =
  doAssert (state == SmSettingBssState) == (smOwn.answer != nil),
    where & ": state " & $state & " with an answer held " & $(smOwn.answer != nil)
  doAssert smOwn.reply == nil or smOwn.request != nil, where & ": a reply reserved for nothing"
  doAssert authStarts + int(state == SmDisconnectingState) <= 1, where & ": ended twice"
proc run(where: string) =
  var count = 0
  while dispatchOne():
    check(where)
    inc count
    doAssert count < 64
proc advanceTo(step: int) =
  ## Until SM has sent request `step`; its replier has not run.
  while smRequests.len < step + 1:
    doAssert dispatchOne()
    check("advance")
proc answerAt(step: int): pointer = answerFor(step)
'''

ACTIVATION_SERIES = r'''
proc check(where: string) =
  let live = state == SM_ACTIVATING_STATE and smActivationLive()
  doAssert live == (smOwn.answer != nil),
    where & ": state " & $state & " with an answer held " & $(smOwn.answer != nil)
  doAssert smOwn.reply == nil or smOwn.request != nil, where & ": a reply reserved for nothing"
  doAssert connected + failures.len <= 1, where & ": ended twice"
proc run(where: string) =
  var count = 0
  while dispatchOne():
    check(where)
    inc count
    doAssert count < 64
proc advanceTo(step: int) =
  ## Until SM has sent request `step`; its replier has not run.
  while smActivation.step < step:
    doAssert dispatchOne()
    check("advance")
proc answerAt(step: int): pointer = takeReply(step)
'''

SERIES_ROWS = ([("bss", step, fate) for step in range(9) for fate in SERIES_FATES]
               + [("bss", step, fate) for step in range(9) for fate in ("vif_retired", "vif_readded")]
               + [("activation", step, fate) for step in range(3) for fate in SERIES_FATES]
               + [("activation", step, "station_deleted") for step in range(3)]
               + [("activation", step, fate) for step in range(3)
                  for fate in ("vif_retired", "vif_readded")])

# The STA VIF is removed (vif_mgmt_unregister) with request `step` queued
# for its replier. The removal ends the attempt at once, unreported, and
# clears the VIF's ME mask bits; the replier drops the request SM no longer
# waits on, also when a STA VIF was registered again at the same index.
RETIRED = r'''
advanceTo(step)
let unapplied = applied.len
allocateAttempt()
{retire}
check("removed")
doAssert state == SmIdleState and smOwn.answer == nil and smOwn.request == nil
{readd}
run("retired")
doAssert applied.len == unapplied, "a request was applied to the removed VIF"
doAssert me.psDisableMask == 0 and me.activeMask == 0, "the removed VIF kept an ME mask bit"
doAssert failures.len == 0 and state == SmIdleState
'''


def series_program(family: str, step: int, fate: str) -> str:
    if family == "bss":
        from test_wifi_bss_confirmations import source as bss_source
        code = bss_source() + BSS_SERIES + f"const fate = \"{fate}\"\nlet step = {step}\n"
        code += "begin()\ncheck(\"start\")\n"
        if fate in ["vif_retired", "vif_readded"]:
            code += RETIRED.replace("{retire}", "retireVif()").replace(
                "{readd}", "vif.vifType = 0" if fate == "vif_readded" else "")
        else:
            code += SERIES_FATES[fate]
        code += r'''
if fate in ["answered", "tx_reset", "duplicate"]:
  doAssert authStarts == 1 and state == 6 and smRequests.len == 9
elif fate in ["vif_retired", "vif_readded"]:
  doAssert authStarts == 0 and smRequests.len == step + 1
else:
  doAssert authStarts == 0 and state == SmDisconnectingState
  doAssert smRequests.len == step + 1, "a request was sent after the attempt ended"
  endAttempt()
assertQuiet()
'''
    else:
        from test_wifi_activation_exchange import source as activation_source
        code = activation_source() + ACTIVATION_SERIES
        code += f"const fate = \"{fate}\"\nlet step = {step}\nbegin()\ncheck(\"start\")\n"
        if fate == "station_deleted":
            # The AP station is deleted under the activation: reported once.
            code += "advanceTo(step)\ninc stationEpochs[2]\nrun(\"deleted\")\n"
        elif fate in ["vif_retired", "vif_readded"]:
            code += RETIRED.replace("{retire}", "retireVif(1)").replace(
                "{readd}", "vifs[1] = Vif(vifIdx: 1, staIdx: 2)" if fate == "vif_readded" else "")
        else:
            code += SERIES_FATES[fate]
        code += r'''
if fate in ["answered", "tx_reset", "duplicate"]:
  doAssert connected == 1 and failures.len == 0 and stationReady == 1
elif fate == "station_deleted":
  doAssert connected == 0 and failures == @[(5'u16, 0xFFFF'u16)]
elif fate in ["vif_retired", "vif_readded"]:
  doAssert connected == 0 and failures.len == 0 and state == SmIdleState
else:
  doAssert connected == 0 and failures.len == 1 and state == SmDisconnectingState
doAssert not smActivationLive() and smOwn.answer == nil and meState == MeIdleState
finish()
'''
    return code


@pytest.mark.parametrize("family,step,fate", SERIES_ROWS,
                         ids=[f"{f}-{s}-{t}" for f, s, t in SERIES_ROWS])
def test_series_table(tmp_path: Path, family: str, step: int, fate: str) -> None:
    run_program(tmp_path, "checked", series_program(family, step, fate))


def test_series_states_have_one_exit() -> None:
    """The batch and the activation send with smSendReserved and take their
    answers with smTakeAnswer; nothing forgets, cancels or services them."""
    tasks = (FW / "task_handlers.nim").read_text()
    for handler in ["mm_bss_param_setting_handler", "me_set_ps_disable_cfm_handler_sm",
                    "me_set_active_cfm_handler_sm", "mm_set_vif_state_cfm_handler",
                    "smActivationOptionsCfmHandler"]:
        assert "smTakeAnswer(param)" in procedure(tasks, handler), handler
    for path in ["station_bss.nim", "station_activation.nim"]:
        code = _code(FW / path)
        assert "smSendReserved(" in code and "ke_msg_send(" not in code.replace(
            "ke_msg_send(message)", ""), path
    main = _code(FW / "task_init_main.nim")
    assert "smBss" not in main and "smActivation" not in main
    assert "meControlReset" not in _code(FW / "station_bss.nim") + _code(FW / "station_activation.nim")


# --------------------------------------------------------------------------
# The cleanup (state 10, phase tdCleanup)
# --------------------------------------------------------------------------
#
# The harness is test_wifi_sm_cleanup's. A disconnect's cleanup is stopped at
# one of its four requests and one fate is applied. After every dispatch SM
# in the cleanup has exactly one thing to move it: the answer it waits for,
# or its retry timer; a reserved reply exists only with its request; the
# disconnect is reported at most once. At quiescence SM is idle, nothing is
# allocated, ME is idle and the disconnect was reported once.

CLEANUP_SERIES = r'''
proc checkCleanup(where: string) =
  if smOwn.teardown == tdCleanup:
    doAssert (smOwn.answer != nil) != smGuardArmed,
      where & ": the cleanup has nothing, or two things, to move it"
    doAssert smOwn.reply == nil or smOwn.request != nil, where & ": a reply reserved for nothing"
  else:
    doAssert smOwn.answer == nil and not smGuardArmed, where & ": the cleanup outlived state 10"
  doAssert notifications.len <= 1, where & ": the disconnect was reported twice"
proc runCleanup(where: string) =
  var count = 0
  while wifiMainHasPendingWork():
    discard wifiDrainScheduledWork()
    checkCleanup(where)
    inc count
    doAssert count < 64, where & ": the cleanup stopped making progress"
proc untilReplier(step: int) =
  ## Until request `step` is sent; its replier has not run.
  while smCleanup.step < step:
    driveOne()
    checkCleanup("advance")
proc untilAnswer(step: int) =
  ## Until the answer to request `step` is queued for SM.
  untilReplier(step)
  while keMsgQueueSent.first == nil or keMsgQueueSent.first.destId != TASK_SM:
    driveOne()
    checkCleanup("answer")
proc deliver(h: ptr Header) =
  ## SM's handler for an answer, as the kernel dispatches it.
  let p = keMsgPayload(h)
  case h.id
  of ME_SET_PS_DISABLE_CFM: me_set_ps_disable_cfm_handler_sm(p)
  of ME_SET_ACTIVE_CFM: me_set_active_cfm_handler_sm(p)
  of MM_STA_DEL_CFM: discard smCleanupCfmHandler(p)
  else: discard mm_set_vif_state_cfm_handler(p)
  checkCleanup("delivered")
proc smInit() =
  smCleanupCancel()
  smGo(SmIdleState)
  checkCleanup("sm_init")
proc quiet() =
  doAssert smState == SmIdleState and smOwn.teardown == tdNone
  doAssert allocated.len == 0 and meState == MeIdleState and notifications.len == 1
  doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
'''

# Effects of the four requests on the model: (ME PS-disable bit, VIF state,
# station deleted, ME active bit), as each would leave them once applied.
CLEANUP_FATES = {
    "answered": "start()\nrunCleanup(\"answered\")\ncompleted()\n",
    # An answer delivered twice moves the cleanup once.
    "duplicate": "start()\nuntilAnswer(step)\nlet h = co_list_pop_front(addr keMsgQueueSent)\n"
                 "deliver(h)\ndeliver(h)\nke_msg_free(h)\nrunCleanup(\"duplicate\")\ncompleted()\n",
    # sm_init after the replier answered: SM ignores the answer, sends nothing more.
    "stale": "start()\nuntilAnswer(step)\nlet h = co_list_pop_front(addr keMsgQueueSent)\nsmInit()\n"
             "deliver(h)\nke_msg_free(h)\nrunCleanup(\"stale\")\nquiet()\n"
             "doAssert commands.len == step + 1, \"a request was sent after sm_init\"\n",
    # sm_init before the replier ran: it drops the request, unapplied.
    "dropped": "start()\nuntilReplier(step)\nlet before = effects()\nsmInit()\nrunCleanup(\"dropped\")\nquiet()\n"
               "doAssert effects() == before, \"a request SM no longer waits on was applied\"\n"
               "doAssert commands.len == step + 1\n",
    # The VIF is removed (vif_mgmt_unregister) before the replier ran: the
    # removal ends the cleanup at once and clears the VIF's ME mask bits;
    # the request in flight is dropped and nothing more is sent. Its station
    # is left valid, as the removal leaves it.
    "vif_retired": "start()\nuntilReplier(step)\nlet before = (vifs[0].state, removed.len)\n"
                   "retireVif(0)\ncheckCleanup(\"removed\")\n"
                   "doAssert smState == SmIdleState and smOwn.teardown == tdNone\n"
                   "runCleanup(\"retired\")\nquiet()\n"
                   "doAssert (vifs[0].state, removed.len) == before, \"a request was applied to the removed VIF\"\n"
                   "doAssert (me.psDisableMask and 1) == 0 and (me.activeMask and 1) == 0\n"
                   "doAssert commands.len == step + 1, \"a request was sent after the removal\"\n",
    # The step's messages cannot be allocated: the retry timer runs it again
    # until memory returns; no step is skipped.
    "no_memory": "stall(proc(on: bool) = failEveryAllocation = on)\ncompleted()\n",
    # The step comes during a TX reset: it waits for the retry timer.
    "tx_reset": "stall(proc(on: bool) = txResetInProgress = on)\ncompleted()\n",
}

CLEANUP_ROW = r'''
proc effects(): tuple[psDisable, vifState: uint8, removed: int, active: uint32] =
  ((me.psDisableMask and 1).uint8, vifs[0].state, removed.len, me.activeMask and 1)
proc start() =
  sm_disconnect_process(addr vifs[0], 19, 3)
  checkCleanup("start")
proc stall(condition: proc(on: bool)) =
  if step == 0: condition(true)
  start()
  if step > 0:
    untilAnswer(step - 1)
    condition(true)
    driveOne()
  doAssert smCleanup.step == step and smOwn.answer == nil and smGuardArmed
  for _ in 0 ..< 3:
    discard wifiDrainScheduledWork()
    checkCleanup("stalled")
  doAssert smCleanup.step == step and commands.len == step, "a step was skipped"
  condition(false)
  runCleanup("resumed")
'''

CLEANUP_ROWS = [(step, fate) for step in range(4) for fate in CLEANUP_FATES]


@pytest.mark.parametrize("step,fate", CLEANUP_ROWS, ids=[f"{s}-{f}" for s, f in CLEANUP_ROWS])
def test_cleanup_table(tmp_path: Path, step: int, fate: str) -> None:
    code = cleanup_program("disconnect").removesuffix(CLEANUP_CASES["disconnect"])
    run_program(tmp_path, "checked", code + CLEANUP_SERIES + f"let step = {step}\n"
                + CLEANUP_ROW + CLEANUP_FATES[fate])


def test_cleanup_has_one_exit() -> None:
    """The cleanup sends with smSendReserved or smSend, and SM's handlers take
    its answers with smTakeAnswer; nothing forgets, polls or cancels it."""
    tasks = (FW / "task_handlers.nim").read_text()
    for handler in ["me_set_ps_disable_cfm_handler_sm", "me_set_active_cfm_handler_sm",
                    "mm_set_vif_state_cfm_handler"]:
        body = procedure(tasks, handler)
        assert "smTakeAnswer(param)" in body and "smCleanupConfirmed()" in body, handler
    cleanup = _code(FW / "station_cleanup.nim")
    assert "smTakeAnswer(reply)" in procedure(cleanup, "smCleanupCfmHandler")
    assert "smCleanupNext()" in procedure(cleanup, "smCleanupConfirmed")
    for gone in ("Forget", "NeedsService", "lost", "awaiting", "meControlReset", "irqSave"):
        assert gone not in cleanup, gone


# --------------------------------------------------------------------------
# The deferred auth/assoc request (states 5 and 7)
# --------------------------------------------------------------------------
#
# The harness is test_wifi_deferred_auth_lifetime's: the real deferred_auth.nim,
# sm_auth_assoc_send_according_chan, chan_ctxt_set_auth_assoc_req, the
# publication branch of chan_pre_switch_channel and station_sm.nim. SM parks
# its request in state 5 or 7 and one fate is applied. At every step states 5
# and 7 hold exactly the parked request and no other state holds one, chan_env
# parks at most SM's request, and the attempt ends or sends at most once. At
# quiescence nothing is allocated.

DEFERRED_SERIES = r'''
proc checkDeferred(where: string) =
  doAssert (currentState in [5'u16, 7]) == held(),
    where & ": state " & $currentState & " with a request held " & $held()
  doAssert chan.deferredMsg == nil or chan.deferredMsg == smOwn.request,
    where & ": chan_env parks a request SM does not hold"
  doAssert sent.len + endings.len <= 1, where & ": the attempt went on twice"
proc dispatch(where: string) =
  while queue.len != 0:
    let payload = queue[0]
    queue.delete(0)
    doAssert sm_connect_auth_assoc_req(payload) == KeMsgConsumed
    checkDeferred(where)
    ke_msg_free(keMsgHdrFromPayload(payload))
'''

DEFERRED_FATES = {
    # The channel comes back: the frame goes out once.
    "published": "publish()\ncheckDeferred(\"published\")\npublish()\ndispatch(\"sent\")\n"
                 "doAssert sent.len == 1 and sent[0].kind == state and currentState == state + 1\n",
    # The user's abort while the request is parked or queued ends the attempt.
    "abort_parked": "sm_connect_ind(24, 3)\ncheckDeferred(\"abort\")\npublish()\ndispatch(\"stale\")\n"
                    "doAssert sent.len == 0 and endings == @[(24'u16, 3'u16)] and live.len == 0\n",
    "abort_queued": "publish()\nsm_connect_ind(24, 3)\ncheckDeferred(\"abort\")\ndispatch(\"stale\")\n"
                    "doAssert sent.len == 0 and endings == @[(24'u16, 3'u16)]\n",
    # sm_init while parked frees the request.
    "sm_init": "discard smGo(0)\ncheckDeferred(\"sm_init\")\n"
               "doAssert live.len == 0 and chan.deferredMsg == nil\npublish()\ndispatch(\"stale\")\n"
               "doAssert sent.len == 0 and endings.len == 0\n",
    # The STA VIF is removed (vif_mgmt_unregister), with the request parked
    # or already sent back: the attempt ends at the removal, unreported, and
    # nothing is sent.
    "vif_retired_parked": "removeVif()\ncheckDeferred(\"removed\")\npublish()\ndispatch(\"retired\")\n"
                          "doAssert sent.len == 0 and endings.len == 0 and currentState == 0\n",
    "vif_retired_queued": "publish()\nremoveVif()\ncheckDeferred(\"removed\")\ndispatch(\"retired\")\n"
                          "doAssert sent.len == 0 and endings.len == 0 and currentState == 0\n",
    # The request delivered twice sends one frame.
    "duplicate": "publish()\nlet payload = queue[0]\nqueue.delete(0)\n"
                 "discard sm_connect_auth_assoc_req(payload)\ncheckDeferred(\"first\")\n"
                 "discard sm_connect_auth_assoc_req(payload)\ncheckDeferred(\"second\")\n"
                 "ke_msg_free(keMsgHdrFromPayload(payload))\ndoAssert sent.len == 1\n",
}

DEFERRED_ROWS = [(state, fate) for state in (5, 7) for fate in DEFERRED_FATES]


@pytest.mark.parametrize("state,fate", DEFERRED_ROWS, ids=[f"{s}-{f}" for s, f in DEFERRED_ROWS])
def test_deferred_table(tmp_path: Path, state: int, fate: str) -> None:
    from test_wifi_deferred_auth import run_nim
    from test_wifi_deferred_auth_lifetime import program_source as deferred_source
    run_nim(tmp_path, deferred_source() + DEFERRED_SERIES + f"""
let state = {state}'u16
reset()
checkDeferred("start")
schedule(state)
doAssert currentState == state and chan.deferredMsg != nil
checkDeferred("parked")
""" + DEFERRED_FATES[fate] + "finish()\ncheckDeferred(\"end\")\ndoAssert live.len == 0\n")


def test_deferred_request_has_one_exit() -> None:
    """States 5 and 7 are entered only by smDeferredPark, and the dispatch
    takes the request with smTakeAnswer."""
    deferred = _code(FW / "deferred_auth.nim")
    assert "smGo(state)" in procedure(deferred, "smDeferredPark")
    assert "smPark(request)" in procedure(deferred, "smDeferredPark")
    assert "smTakeAnswer(payload)" in procedure(deferred, "smDeferredDispatch")
    for path in _wifi_sources():
        code = _code(path)
        assert "smGo(SmAuthStartingState" not in code and "smGo(SmAssociatingState" not in code, path


# --------------------------------------------------------------------------
# The removal of the STA VIF, in every state (stage 9g, SCAN-N3)
# --------------------------------------------------------------------------
#
# vif_mgmt_unregister tells SM when it retires a STA VIF (smStaVifRetired).
# The tables above remove the VIF in states 1 to 9 and 10 (cleanup) with a
# request in flight; the rows below use the teardown harness for the states
# themselves: an attempt in each of states 1 to 9, a link in state 0 and the
# deauthentication wait of state 10. In every one SM ends what it does on the
# VIF at once, unreported (smAbandon), frees what it holds, keeps no timer
# and accepts none of the stamps it handed out.

REMOVAL = r'''
retireVif(0)        # vif_mgmt_unregister retires VIF 0 and tells SM,
vifs[0].vifType = 4 # its entry freed.
check("removed")
doAssert smState == SmIdleState and smOwn.teardown == tdNone and not smGuardArmed
doAssert sm.connectInfo == nil and sm.connectIndMsg == nil
quiesce()
doAssert report() == 0, "the removal was reported"
doAssert allocated.len == 0 and smOwn.answer == nil
let quiet = (smState, notifications.len, controlReplies.len, smOwn.teardown)
for stamp in stamps & pending:
  for callback in [cast[pointer](sm_disconnect_deauth_cfm),
                   cast[pointer](sm_connect_abort_deauth_cfm),
                   cast[pointer](sm_supplicant_deauth_cfm)]:
    cast[proc(p: pointer; status: uint32) {.cdecl.}](callback)(stamp, 0x40000000'u32)
  smDeauthGuardExpired(stamp)
doAssert (smState, notifications.len, controlReplies.len, smOwn.teardown) == quiet
'''

REMOVAL_ROWS = [(state, "attempt") for state in range(1, 10)] + [(0, "link"), (10, "deauth_wait")]


@pytest.mark.parametrize("state,holding", REMOVAL_ROWS, ids=[f"{s}-{h}" for s, h in REMOVAL_ROWS])
def test_vif_removal_table(tmp_path: Path, state: int, holding: str) -> None:
    body = {"attempt": f"start({state}'u16, true)\n",
            "link": "start(0'u16, false)\n",
            "deauth_wait": "start(9'u16, true)\nframe(cast[pointer](sm_connect_abort_deauth_cfm))\n"
                           "doAssert smOwn.teardown == tdDeauthWait\n"}[holding]
    run_program(tmp_path, "checked", source() + body + REMOVAL)


def test_vif_removal_is_one_signal() -> None:
    """vif_mgmt_unregister is the only caller of smStaVifRetired, from a defer
    placed at the commit of the removal, so every return after it signals.
    The per-request VIF checks it replaces are gone."""
    callers = [path.name for path in _wifi_sources() if "smStaVifRetired(" in _code(path)]
    assert sorted(callers) == ["station_sm.nim", "vif_management.nim"], callers
    unregister = procedure((FW / "vif_management.nim").read_text(), "vif_mgmt_unregister")
    defer = unregister.index("  defer:\n    if vifType == VIF_TYPE_STA:")
    assert defer < unregister.index("smStaVifRetired(vifIdx)") < unregister.index(
        "rxInvalidateQuiescentVif(vifIdx, selected)")
    assert unregister.index("co_list_extract(addr env.activeList") < defer
    code = "".join(_code(path) for path in _wifi_sources())
    for gone in ("smAttemptStaVif", "smRequestVifLive", "smCleanupVifLive", "smTeardownUnclaimed",
                 "SmStaRequestIdentity", "smAbortCurrent"):
        assert gone not in code, gone
    scan = (FW / "scan_station_ap_me.nim").read_text()
    assert "smAbandon()" in procedure(scan, "sm_init")
    assert "smAbandon()" in procedure((FW / "kernel_mac_channel.nim").read_text(), "ke_flush")


# --------------------------------------------------------------------------
# Saved host requests (stage 9h)
# --------------------------------------------------------------------------
#
# The harness is test_wifi_station_abort's: the real sm_connect_abort_req_handler,
# sm_disconnect_req_handler, station_abort.nim and the message allocator over
# the deferred auth/assoc model. In every SM state the abort is answered in
# place, exactly once, and never saved: it acts on the attempt live then. The
# disconnect is saved while SM is busy and acts, once SM is idle, only on the
# STA VIF generation it was sent for: not after the VIF was removed and added
# again, whether that happened before its first dispatch or while it was
# saved.

HOST_REQUESTS = r'''
proc clearRecords() =
  replies.setLen(0)
  outcomes.setLen(0)
  deauths = 0
  disconnects = 0
  disconnectReplies = 0
  env.cancelRequested = 0
clearRecords()
currentState = state
let abort = makeAbort()
doAssert deliverAbort(abort) == KeMsgNoFree and replies.len == 1
doAssert outcomes.len == int(state in [3'u16, 4, 5, 7])
doAssert deauths == int(state in [6'u16, 8, 9])
doAssert replies[0] == (if state == 1: 1'u8 else: 0'u8)
doAssert (env.cancelRequested == 1) == (state in [1'u16, 2])
reset()
clearRecords()
currentState = state
let disconnect = makeDisconnect()
if fate == "replaced_before_dispatch": inc rxVifEpochs[1]
var outcome = deliverDisconnect(disconnect)
doAssert (outcome == KeMsgSaved) == (state != SmIdleState and fate != "replaced_before_dispatch")
if fate == "replaced_while_saved": inc rxVifEpochs[1]
if outcome == KeMsgSaved:
  currentState = SmIdleState
  outcome = deliverDisconnect(disconnect)
doAssert outcome == KeMsgNoFree and disconnectReplies == 1
let acted = fate == "live" or (fate == "replaced_while_saved" and state == SmIdleState)
doAssert disconnects == int(acted), "disconnect acted on another VIF generation"
'''

HOST_FATES = ("live", "replaced_before_dispatch", "replaced_while_saved")
HOST_ROWS = [(state, fate) for state in range(11) for fate in HOST_FATES]


@pytest.mark.parametrize("state,fate", HOST_ROWS, ids=[f"{s}-{f}" for s, f in HOST_ROWS])
def test_saved_host_request_table(tmp_path: Path, state: int, fate: str) -> None:
    from test_wifi_deferred_auth import run_nim
    from test_wifi_station_abort import program_source as abort_source
    run_nim(tmp_path, abort_source() + f"""
let state = {state}'u16
let fate = "{fate}"
reset()
""" + HOST_REQUESTS + "finish()\ndoAssert smDisconnectStamps == nil and live.len == 0\n")
