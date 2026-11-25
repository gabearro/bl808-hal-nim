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
and registration states 1 to 3 through each fate of their one request.
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
    doAssert smCleanup.active, where & ": state 10 without its cleanup"
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
doAssert smState == SmIdleState and smOwn.teardown == tdNone and not smCleanup.active
doAssert report() == 1, "teardown ended unreported or twice: " & $report()
doAssert sm.connectInfo == nil and sm.connectIndMsg == nil
doAssert allocated.len == 0 and smCleanupTags == nil
doAssert not smGuardArmed
# Every stamp handed out is stale now.
let quiet = (smState, notifications.len, controlReplies.len, smCleanup.active)
for stamp in stamps:
  for callback in [cast[pointer](sm_disconnect_deauth_cfm),
                   cast[pointer](sm_connect_abort_deauth_cfm),
                   cast[pointer](sm_supplicant_deauth_cfm)]:
    cast[proc(p: pointer; status: uint32) {.cdecl.}](callback)(stamp, 0x40000000'u32)
  smDeauthGuardExpired(stamp)
doAssert (smState, notifications.len, controlReplies.len, smCleanup.active) == quiet
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
doAssert smState == SmIdleState and smOwn.teardown == tdNone and not smCleanup.active
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
    # SCAN-N3: the STA VIF is removed while SCANU works on the request.
    "vif_gone": r'''
vifs[conn.vifIdx] = Vif(vifIdx: 127, vifType: 4, staIdx: 0xFF)
found = true
take(family, answer(family, request, false))
doAssert failures.len == 1 and state == SmIdleState
''',
}

FAMILY_ROWS = [(family, fate) for family in (1, 2, 3) for fate in FAMILY_FATES
               if not (family == 3 and fate in ("abort", "vif_gone"))]


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
    assert sorted(senders) == ["scan_station_ap_me.nim", "station_sm.nim", "task_handlers.nim"], senders
    main = _code(FW / "task_init_main.nim")
    assert "smScanNeedsService" not in main and "smRegistrationNeedsService" not in main
