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
                 if re.search(r"\bopGo\(|\bopFinish\(|\bsmOwn(\.op(\.\w+)?)?\s*=[^=]", line)
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
