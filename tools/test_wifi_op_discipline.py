"""Static discipline of the Wi-Fi station state machine (SM).

These are the rules a reader relies on to convince themselves that SM is
correct without reading every callee:

  - smGo is the only ke_state_set(TASK_SM, ...) and the only opGo of SM's
    operation, so a stamp goes stale exactly when SM moves on;
  - SM's own files take no IRQ lock and know nothing of the TX reset epoch:
    no interrupt handler touches SM, and a TX reset ends frames, not SM's
    waits;
  - every SM handler that takes an answer takes it through smTakeAnswer, or
    through the stamp of the operation that is waiting (the response
    deadline, SA Query's own serial); the others are on a short list of
    inputs that are not answers;
  - the frame builders take the operation's stamp at entry and commit (or
    report a failure) only while that operation is live, with no other
    re-check, and every frame SM pushes with a callback carries the stamp
    of the wait it ends.

The session/owner machinery that these rules replaced (smTx*, the per-VIF
TX serials, SmTxBuildContext) must not come back.

The same rules hold for TASK_SCAN and TASK_SCANU (scan_machine.nim): scanGo
and scanuGo are their only state writers and the only writers of their
operations; the dwell's notices, its probe repeat timer and END_EARLY carry
its stamp and every handler that takes one checks it (scanCurrent); SCANU
takes TASK_SCAN's answer only as the request it holds (scanuTakeLower); each
machine ends a request in one place (scanRelease, scanuComplete); and the
dwell, lower-exchange and producer machinery they replaced must not come back.
"""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure

WIFI = FW.parent

# Files that hold only SM: station_*.nim, the deferred auth/assoc request and
# the operation record.
SM_FILES = sorted(FW.glob("station_*.nim")) + [FW / "deferred_auth.nim", FW / "op.nim"]

# SM's frame builders and response handlers, which live among SCANU, APM and
# ME code in scan_station_ap_me.nim.
BUILDERS = ["sm_auth_send", "sm_assoc_req_send", "sm_handle_connection",
            "sm_deauth_send", "sm_handle_supplicant_result"]
SM_PROCS = BUILDERS + ["sm_auth_handler", "sm_assoc_rsp_handler", "sm_assoc_done",
                       "smAssocDone", "sm_get_bss_params", "smConnectEnd"]

# sm_default_state inputs that are not the answer to a request SM sent.
NOT_ANSWERS = {
    "sm_connect_req_handler": "host request (admission)",
    "sm_disconnect_req_handler": "host request, stamped with its VIF's generation",
    "sm_connect_abort_req_handler": "host request, answered in place",
    "mm_connection_loss_ind_handler": "MM indication, checked against its tag",
    "rxu_mgt_ind_handler_sm": "frame from the air; the auth response is matched "
                              "to the operation's stamp (smAuthResponseMatches)",
}
# How the other handlers take their answer.
ANSWER_GATES = ("smTakeAnswer", "smResponseExpiry", "smSaQueryClaimTimeout")


def code(text: str) -> str:
    """Nim source without comments and doc comments."""
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def without_diagnostics(text: str) -> str:
    """Drop `when defined(bl808WifiDiag...)` blocks (diagnostic-only records)."""
    lines = text.splitlines()
    kept = []
    skip_indent = None
    for line in lines:
        indent = len(line) - len(line.lstrip())
        if skip_indent is not None:
            if line.strip() == "" or indent > skip_indent:
                continue
            skip_indent = None
        if re.match(r"\s*when defined\(bl808WifiDiag\w*\):", line):
            skip_indent = indent
            continue
        kept.append(line)
    return "\n".join(kept)


def all_firmware() -> list[Path]:
    return sorted(WIFI.rglob("*.nim"))


def find_procedure(name: str) -> str:
    bodies = [procedure(path.read_text(), name) for path in sorted(FW.glob("*.nim"))
              if re.search(rf"^proc {name}\*?\(", path.read_text(), re.M)]
    assert len(bodies) == 1, name
    return bodies[0]


def sm_handlers() -> list[str]:
    tables = (FW / "dispatch_tables.nim").read_text()
    block = tables.split("var sm_default_state*", 1)[1].split("\n]\n", 1)[0]
    return sorted(set(re.findall(r"keMsgHandlerAddress\((\w+)\)", block)))


def test_one_state_writer_and_one_serial_writer() -> None:
    writers = [path.relative_to(WIFI) for path in all_firmware()
               for line in code(path.read_text()).splitlines()
               if "ke_state_set(TASK_SM" in line]
    assert writers == [Path("fw/station_sm.nim")], writers
    go = procedure((FW / "station_sm.nim").read_text(), "smGo")
    assert "ke_state_set(TASK_SM, state)" in go and "opGo(smOwn.op)" in go
    advancers = [path.relative_to(WIFI) for path in all_firmware()
                 for line in code(path.read_text()).splitlines()
                 if re.search(r"\bop(Go|Finish)\(smOwn\b|\bsmOwn(\.op(\.\w+)?)?\s*=[^=]", line)
                 and path.name != "op.nim"]
    assert advancers == [Path("fw/station_sm.nim")], advancers


@pytest.mark.parametrize("path", SM_FILES, ids=lambda p: p.name)
def test_sm_files_take_no_irq_lock(path: Path) -> None:
    """No interrupt handler touches SM (they post events, move TX/RX
    descriptors and raise recovery), so SM's files need no mask."""
    text = code(without_diagnostics(path.read_text()))
    assert "irqSave" not in text and "irqRestore" not in text
    assert not re.search(r"\w+Locked\(", text)
    assert "outside:" not in text


@pytest.mark.parametrize("path", SM_FILES, ids=lambda p: p.name)
def test_sm_files_ignore_the_tx_reset_epoch(path: Path) -> None:
    # station_cleanup.nim still asks txlResetting(): a cleanup step that comes
    # inside a TX reset's drain (from a flushed deauthentication's
    # confirmation) is run again from SM's timer, not inside the reset.
    assert "txResetEpoch" not in code(path.read_text())


@pytest.mark.parametrize("name", SM_PROCS)
def test_sm_procs_ignore_the_tx_reset_epoch(name: str) -> None:
    body = code(find_procedure(name))
    assert "txResetEpoch" not in body and "irqSave" not in body


@pytest.mark.parametrize("name", sm_handlers() + [
    "sm_deauth_handler", "sm_sa_query_handler", "sm_issue_sa_query_request",
    "smTrySubmitSaQuery", "sm_get_bss_params", "sm_handle_supplicant_result"])
def test_sm_handlers_take_no_irq_lock(name: str) -> None:
    body = code(without_diagnostics(find_procedure(name)))
    assert "irqSave" not in body and "irqRestore" not in body, name
    assert not re.search(r"\w+Locked\(", body), name


@pytest.mark.parametrize("handler", sm_handlers())
def test_answers_are_taken_through_the_operation(handler: str) -> None:
    body = code(find_procedure(handler))
    if handler in NOT_ANSWERS:
        assert not any(gate in body for gate in ANSWER_GATES[:1]), handler
        return
    # The handler or the SM helper it hands the message to.
    helpers = re.findall(r"\b(sm[A-Z]\w*)\(", body)
    reached = body + "".join(code(find_procedure(name)) for name in helpers
                             if any(re.search(rf"^proc {name}\*?\(", p.read_text(), re.M)
                                    for p in SM_FILES))
    assert any(gate in reached for gate in ANSWER_GATES), handler


def test_not_answer_list_is_short_and_current() -> None:
    assert set(NOT_ANSWERS) <= set(sm_handlers())
    assert len(NOT_ANSWERS) <= 5


@pytest.mark.parametrize("name", BUILDERS)
def test_builders_commit_once_on_their_stamp(name: str) -> None:
    """One stamp taken at entry, checked before the commit (and by the failure
    exits); no other re-check of the frame or the attempt."""
    body = code(find_procedure(name))
    assert body.count("smOwn.op.serial") == 1, name
    assert "opCurrent(smOwn.op, stamp)" in body, name
    entry = body.index("smOwn.op.serial")
    frame_get = body.index("txl_frame_get(")
    assert entry < frame_get, f"{name} takes its stamp after txl_frame_get"
    commit = body.index("opCurrent(smOwn.op, stamp)", frame_get)
    for transition in ["smGo(", "smDeauthWait(", "txl_frame_push(", "txl_frame_try_push_force("]:
        if transition in body:
            assert body.index(transition) > commit, f"{name}: {transition} before the commit check"
    for removed in [r"\bsmTx(?!Fits)\w*", r"\birqSave\b", r"\btxResetEpoch\b",
                    r"\btxlFrameLeaseMatches\b", r"\btxlFramePreparationCurrent\b",
                    r"\bcurrent\(\)"]:
        assert not re.search(removed, body), f"{name} still re-checks with {removed}"


@pytest.mark.parametrize("name", BUILDERS)
def test_pushed_callbacks_carry_the_wait_stamp(name: str) -> None:
    body = code(find_procedure(name))
    callbacks = re.findall(r"desc\.callback = (\w+)", body)
    for value in callbacks:
        if value == "nil":
            continue
        assert "desc.callbackArg = opStampEnv(wait)" in body, name
        assert "smDeauthWait(" in body, name


@pytest.mark.parametrize("name", ["sm_connect_abort_deauth_cfm", "sm_supplicant_deauth_cfm",
                                  "sm_disconnect_deauth_cfm"])
def test_deauth_confirmations_check_the_stamp(name: str) -> None:
    assert "smDeauthConfirmed(param)" in code(find_procedure(name))


def test_auth_and_assoc_frames_have_no_confirmation() -> None:
    """Their response, not their confirmation, ends the wait (sm.o)."""
    for name in ["sm_auth_send", "sm_assoc_req_send"]:
        body = code(find_procedure(name))
        assert "desc.callback = nil" in body and "desc.callback = " not in body.replace(
            "desc.callback = nil", ""), name


def test_session_machinery_is_gone() -> None:
    text = "".join(code(path.read_text()) for path in all_firmware())
    for name in ["smTxSerials", "SmTxBuildContext", "smTxCapture", "smTxBegin",
                 "smTxSessionCurrent", "smTxOwnerCurrent", "smTxBindStation",
                 "smTxFrameCurrent", "smTxAdopt", "smTxSetOwnerState", "smTxSetState",
                 "smTxSubmit", "smTxFail", "smTxEnd", "smTxRelease", "smDeauthSend",
                 "smAssocOwnerCurrent", "txlFrameBindSmOwner", "smTxSnapshotJoinPeer"]:
        assert not re.search(rf"\b{name}\b", text), name
    identity = (FW / "layout_types.nim").read_text().split("  TxFrameIdentity = object", 1)[1]
    identity = identity.split("\n\n", 1)[0]
    assert not re.search(r"\bsm[A-Z]\w*", identity), identity


# --------------------------------------------------------------------------
# TASK_SCAN and TASK_SCANU
# --------------------------------------------------------------------------

SCAN_MACHINE = FW / "scan_machine.nim"


def scan_handlers(*tables: str) -> list[str]:
    source = (FW / "dispatch_tables.nim").read_text()
    names = set()
    for table in tables:
        block = source.split(f"var {table}*", 1)[1].split("\n]\n", 1)[0]
        names.update(re.findall(r"keMsgHandlerAddress\((\w+)\)", block))
    return sorted(names - {"ke_msg_save", "ke_msg_discard"})


SCAN_HANDLERS = scan_handlers("scan_default_state")
SCANU_HANDLERS = scan_handlers("scanu_idle", "scanu_scanning", "scanu_joining", "scanu_default_state")


@pytest.mark.parametrize("task,go", [("TASK_SCAN", "scanGo"), ("TASK_SCANU", "scanuGo")])
def test_scan_machines_have_one_state_writer(task: str, go: str) -> None:
    writers = [(path.relative_to(WIFI), line.strip()) for path in all_firmware()
               for line in code(path.read_text()).splitlines()
               if re.search(rf"ke_state_set\({task}\b", line)]
    assert writers == [(Path("fw/scan_machine.nim"), f"ke_state_set({task}, state)")], writers
    assert f"ke_state_set({task}, state)" in procedure(SCAN_MACHINE.read_text(), go)


@pytest.mark.parametrize("owner", ["scanOwn", "scanuOwn"])
def test_scan_operations_advance_only_in_their_go(owner: str) -> None:
    """The stamp of a dwell or a SCANU request changes only in scanGo or
    scanuGo; their records are written only in scan_machine.nim."""
    writers = [(path.relative_to(WIFI), line.strip()) for path in all_firmware()
               for line in code(path.read_text()).splitlines()
               if re.search(rf"\bop(Go|Finish)\({owner}\b|\b{owner}(\.\w+)*\s*=[^=]", line)]
    assert {path for path, _ in writers} == {Path("fw/scan_machine.nim")}, writers
    machine = SCAN_MACHINE.read_text()
    go = "scanGo" if owner == "scanOwn" else "scanuGo"
    advancing = [line for _, line in writers if re.search(r"\bop(Go|Finish)\(", line)]
    assert all(line in procedure(machine, go) for line in advancing), advancing


@pytest.mark.parametrize("handler", SCAN_HANDLERS + SCANU_HANDLERS)
def test_scan_handlers_leave_the_state_to_their_go(handler: str) -> None:
    body = code(find_procedure(handler))
    assert "ke_state_set(" not in body, handler
    assert not re.search(r"\bop(Go|Finish)\(", body), handler


def test_scan_deliveries_carry_the_dwell_stamp() -> None:
    """START, END, END_EARLY and the probe repeat expiry are taken only with
    the live dwell's stamp; the timer and END_EARLY are stamped when made."""
    for handler in ["mm_scan_channel_start_ind_handler", "mm_scan_channel_end_ind_handler",
                    "mm_scan_channel_end_early_handler", "scan_probe_req_handler"]:
        assert "scanCurrent(param, " in code(find_procedure(handler)), handler
    arming = [(path.name, line.strip()) for path in all_firmware()
              for line in code(path.read_text()).splitlines()
              if "SCAN_PROBE_TIMER" in line and re.search(r"ke_timer(_try)?_set\(", line)]
    assert len(arming) == 1 and arming[0][0] == "task_handlers.nim", arming
    start = code(find_procedure("mm_scan_channel_start_ind_handler"))
    assert "stamp = scanOwn.op.serial" in start
    machine = SCAN_MACHINE.read_text()
    assert "stampOf(message) = scanOwn.op.serial" in procedure(machine, "scanEarlyEndRequest")
    begin = procedure(machine, "scanDwellBegin")
    assert "stampOf(start) = stamp" in begin and "stampOf(finish) = stamp" in begin
    sent = [(path.name, line.strip()) for path in all_firmware()
            for line in code(path.read_text()).splitlines()
            if re.search(r"MM_SCAN_CHANNEL_(START_IND|END_IND|END_EARLY)\b", line)
            and re.search(r"ke_msg_(send_basic|try_alloc|alloc)\(", line)]
    assert sorted(name for name, _ in sent) == ["scan_machine.nim"] * 3, sent


def test_scanu_takes_only_the_answer_it_holds() -> None:
    for handler in ["scan_start_cfm_handler", "scan_done_ind_handler"]:
        assert "scanuTakeLower(param)" in code(find_procedure(handler)), handler
    done = code(find_procedure("scan_done_ind_handler"))
    assert "param == scanu_env.pendingJoinRxuMgtInd" in done
    start = code(find_procedure("scan_start_req_handler"))
    assert "requester == TASK_SCANU and not scanuAwaits(param)" in start


def test_each_scan_machine_ends_a_request_in_one_place() -> None:
    """scanRelease answers TASK_SCAN's request and goes idle; scanuComplete
    answers SCANU's request and goes idle (scanu_confirm and the replay)."""
    machine = SCAN_MACHINE.read_text()
    release = procedure(machine, "scanRelease")
    assert "scan_env.paramPtr = nil" in release and "scanGo(ScanIdleState)" in release
    complete = procedure(machine, "scanuComplete")
    assert "scanu_env.paramPtr = nil" in complete and "scanuGo(ScanuIdleState)" in complete
    assert procedure(machine, "scanu_confirm").strip().endswith("scanuComplete(status)")
    for path in all_firmware():
        for line in code(path.read_text()).splitlines():
            if re.search(r"\bscan_env\.paramPtr\s*=[^=]", line):
                assert path.name in ("scan_machine.nim", "task_handlers.nim"), (path, line)
            if re.search(r"\bscanu_env\.paramPtr\s*=[^=]", line):
                assert path.name in ("scan_machine.nim", "task_handlers.nim"), (path, line)
    tasks = (FW / "task_handlers.nim").read_text()
    # The handlers store a request only on admission.
    assert code(procedure(tasks, "cacheScanStartContext")).count("scan_env.paramPtr = param") == 1
    for handler in ["scanu_start_req_handler", "scanu_join_req_handler"]:
        body = code(procedure(tasks, handler))
        assert body.count("scanu_env.paramPtr = param") == 1, handler
        assert body.index("scanu_env.paramPtr = param") < body.index("scanuGo(")


def test_scan_machine_takes_no_irq_lock_and_ignores_the_tx_reset_epoch() -> None:
    text = code(SCAN_MACHINE.read_text())
    assert "irqSave" not in text and "txResetEpoch" not in text
    for handler in SCAN_HANDLERS + SCANU_HANDLERS:
        body = code(without_diagnostics(find_procedure(handler)))
        assert "txResetEpoch" not in body, handler
        if handler != "rxu_mgt_ind_handler_scanu":
            assert "irqSave" not in body, handler


def test_scan_machinery_is_gone() -> None:
    text = "".join(code(path.read_text()) for path in all_firmware())
    for name in ["ScanDwellPair", "ScanDwellPosted", "ScanDwellRetired", "scanDwellHeld",
                 "scanDwellRequest", "scanDwellOwnsLower", "scanDwellEpoch", "scanDwellSerial",
                 "scanDwellSlot", "scanDwellResetEpoch", "scanDwellChannel", "scanDwellPostedHead",
                 "scanDwellReserve", "scanDwellInstall", "scanDwellCurrent", "scanDwellPublish",
                 "scanDwellClaim", "scanDwellDetach", "scanDwellForget", "scanDwellReset",
                 "scanDwellBeginReset", "scanDwellFinishReset", "scanDwellDispose",
                 "scanEarlyEndClaim", "ScanProbeTimerContext", "scanProbeTimerCurrent",
                 "scheduleActiveScanProbeTimer", "ScanuLowerExchange", "scanuLower",
                 "scanuLowerCurrent", "scanuTrackLowerReply", "scanuClaimLowerReply",
                 "scanuProducerRequest", "scanuProducerEpoch", "scanRequestEpoch",
                 "scanuRequestEpoch", "releaseCompletedScanRequest", "forwardFailedScanDwell",
                 "scanuReleaseCompletedOwner", "cacheScanuStartRequest", "SmScanAbortPayloadSize"]:
        assert not re.search(rf"\b{name}\b", text), name
    assert not re.search(r"\bscanEarlyEnd\b", text)
