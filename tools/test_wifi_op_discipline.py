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

And for power save (ps_machine.nim): psStart is the only opGo of PS's
operation and psFinish and psCancel its only ends; psOwn, the transition
count and ps.flags bits 1 and 2 are written only there; every null frame a
transition counts carries its stamp, as does the TX-null timer, and the
confirmations and the timer take a delivery only through that stamp; the
transition procs know nothing of the TX reset epoch; the MAC's PM bit is
written by PS, a dwell's hold and the channel's departure and return only;
no transition sends a null frame while a dwell holds the bit, and the
departure protects every STA whatever PS's state; MM saves a request only
while a transition is live; resets drop ME's exchange before PS's
transition; and the serial, owner, reset-replay and traffic-epoch machinery
they replaced must not come back.
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


# --------------------------------------------------------------------------
# Power save
# --------------------------------------------------------------------------

PS_MACHINE = FW / "ps_machine.nim"
POWER = FW / "power_save.nim"
PS_TRANSITION_PROCS = ["ps_set_mode", "ps_dpsm_update", "ps_enable_cfm", "ps_disable_cfm",
                       "ps_tx_null_timer_handle", "ps_enable_cfm_handle",
                       "ps_disable_cfm_handle", "ps_check_tx_status_part0_nim",
                       "ps_traffic_status_update", "td_timer_end"]


def ps_machine_procs() -> list[str]:
    return re.findall(r"^proc (\w+)", PS_MACHINE.read_text(), re.M)


def test_ps_operation_advances_only_in_start_and_ends() -> None:
    """psOwn (its Op included) is written only in ps_machine.nim; opGo only in
    psStart, opFinish only in psFinish and psCancel."""
    writers = [(path.name, line.strip()) for path in all_firmware()
               for line in code(path.read_text()).splitlines()
               if re.search(r"\bop(Go|Finish)\(psOwn\b|\bpsOwn(\.\w+)*\s*=[^=]", line)]
    assert {name for name, _ in writers} == {"ps_machine.nim"}, writers
    machine = PS_MACHINE.read_text()
    assert "opGo(psOwn.op)" in procedure(machine, "psStart")
    ends = [name for name in ps_machine_procs()
            if "opFinish(psOwn.op)" in code(procedure(machine, name))]
    assert ends == ["psFinish", "psCancel"], ends


def test_ps_count_and_transition_bits_belong_to_the_machine() -> None:
    """ps.pendingCount is written only by the machine; ps.flags bits 1 and 2
    (a wake or a sleep is live) are set by psStart and cleared by psFinish and
    psCancel, and the other writers of ps.flags leave them alone."""
    for path in all_firmware():
        for line in code(path.read_text()).splitlines():
            if re.search(r"\b(ps|psEnvView\(\))\.pendingCount\s*=[^=]|"
                         r"\b(inc|dec) (ps|psEnvView\(\))\.pendingCount", line):
                assert path.name == "ps_machine.nim", (path.name, line)
    flag_writes = [(name, line.strip()) for name in PS_TRANSITION_PROCS + ["ps_init"]
                   for line in code(procedure(POWER.read_text(), name)).splitlines()
                   if re.search(r"\bps\.flags\s*=[^=]", line)]
    assert sorted(flag_writes) == sorted([
        ("ps_set_mode", "ps.flags = (ps.flags and 0x06'u8) or uint8(mode == 2)"),
        ("ps_disable_cfm_handle", "ps.flags = ps.flags or 8'u8"),
        ("ps_enable_cfm_handle", "ps.flags = ps.flags and not 0x08'u8"),
    ]), flag_writes
    machine = PS_MACHINE.read_text()
    assert "ps.flags = ps.flags or 0x02'u8" in procedure(machine, "psStart")
    assert "ps.flags = ps.flags or 0x04'u8" in procedure(machine, "psStart")
    for name in ["psFinish", "psCancel"]:
        assert "ps.flags = ps.flags and not 0x06'u8" in procedure(machine, name), name
    # Elsewhere, no proc that binds PS's environment writes its flags.
    others = []
    for path in all_firmware():
        if path.name in ("ps_machine.nim", "power_save.nim"):
            continue
        text = code(path.read_text())
        assert not re.search(r"\bpsEnvView\(\)\.flags\s*=[^=]", text), path.name
        for body in re.split(r"(?m)^(?=proc )", text):
            if "= psEnvView()" in body and re.search(r"\bps\.flags\s*=[^=]", body):
                others.append((path.name, body.split("(", 1)[0]))
    assert others == [], others


def test_ps_deliveries_carry_the_transition_stamp() -> None:
    machine = PS_MACHINE.read_text()
    power = POWER.read_text()
    assert "txl_frame_send_null_frame(vifChannelAt(vifEntry).staIdx, callback, stamp)" in \
        procedure(machine, "psSend")
    assert "txl_frame_send_null_frame(vif.staIdx, completionFn, psOwn.op.serial)" in \
        procedure(power, "ps_check_tx_status_part0_nim")
    assert "if not opCurrent(psOwn.op, opEnvStamp(env)): return" in procedure(machine, "psConfirm")
    timer = code(procedure(power, "ps_tx_null_timer_handle"))
    statements = [line.strip() for line in timer.splitlines() if line.strip()]
    assert statements[1] == "if not opCurrent(psOwn.op, opEnvStamp(env)): return"
    assert timer.index("psFinish(") < timer.index("txl_cntrl_clear_ac(3)")
    dpsm = code(procedure(power, "ps_dpsm_update"))
    assert "ps.txNullTimerEnv = opStampEnv(stamp)" in dpsm
    assert dpsm.index("mm_timer_set(psTxNullTimer()") < dpsm.index("psSend(")
    for name in ["ps_enable_cfm", "ps_disable_cfm"]:
        assert code(procedure(power, name)).strip().splitlines()[-1].strip().startswith(
            "psConfirm(env, "), name
    # The senders hold the count for the walk and release it last.
    for name in ["ps_set_mode", "ps_dpsm_update"]:
        body = code(procedure(power, name))
        assert body.strip().splitlines()[-1].strip() == "psCount(lastSta)", name
        assert "return" not in body.split("psStart(", 1)[1], f"{name} returns before psCount"


def test_ps_transitions_ignore_the_tx_reset_epoch() -> None:
    assert "txResetEpoch" not in code(PS_MACHINE.read_text())
    for name in PS_TRANSITION_PROCS + ["ps_check_beacon", "ps_check_tbtt", "ps_check_frame",
                                       "ps_check_tx_frame", "ps_uapsd_timer_handle"]:
        body = code(procedure(POWER.read_text(), name))
        for removed in ["txResetEpoch", "txlFrameCallbackCurrent", "psModeBuildSerial",
                        "mmPsModeRequest"]:
            assert removed not in body, (name, removed)
    detector = code((FW / "traffic_detection.nim").read_text())
    assert "txResetEpoch" not in detector and "rxVifEpochs" not in detector


def test_pm_bit_writers() -> None:
    """PS writes the PM bit (psApplyPm) and a dwell holds it (psDwellBegin,
    psDwellEnd); outside ps_machine.nim only the channel scheduler's departure
    sets it for its protection frames and its return and abandonment clear it
    while PS is awake."""
    calls = [(path.name, line.strip()) for path in all_firmware()
             for line in code(path.read_text()).splitlines()
             if "blmac_pwr_mgt_setf(" in line and "proc blmac_pwr_mgt_setf" not in line]
    outside = sorted(call for call in calls if call[0] != "ps_machine.nim")
    assert outside == sorted([
        ("task_handlers.nim", "blmac_pwr_mgt_setf(1)"),
        ("kernel_mac_channel.nim", "blmac_pwr_mgt_setf(0)"),
        ("channel_switch.nim", "blmac_pwr_mgt_setf(0)"),
    ]), outside
    assert "if psAwake():" in code(procedure((FW / "kernel_mac_channel.nim").read_text(),
                                             "chan_pre_switch_channel"))
    assert "psAwake()" in code(procedure((FW / "channel_switch.nim").read_text(), "chanSwitchFinish"))
    assert "0x24B0004C" not in code(POWER.read_text())
    for path in all_firmware():
        assert "surveySnapshot" not in code(path.read_text()) or path.name == "layout_types.nim", path


def test_ps_sends_no_null_frame_during_a_dwell() -> None:
    """The MAC marks a null frame with the register's PM bit, which a dwell
    holds at 0, and the scanning STA's VIF is on channel during its dwell. So
    both transition walks skip their frames while a dwell holds the bit
    (psDwell), and psApplyPm only records PS's choice then. Behaviour:
    test_wifi_ps_table.py (dwell_request, dwell_traffic and the
    dwell_sends_* mutations)."""
    machine = PS_MACHINE.read_text()
    assert "(psEnvView().statusFlags and 2'u32) != 0" in code(procedure(machine, "psDwell"))
    assert "if not psDwell(): blmac_pwr_mgt_setf(pm.uint32)" in code(procedure(machine, "psApplyPm"))
    power = POWER.read_text()
    explicit = code(procedure(power, "ps_set_mode"))
    assert explicit.count("psSend(") == 1
    assert "if not psDwell(): psSend(node, callback, stamp)" in explicit
    dpsm = code(procedure(power, "ps_dpsm_update"))
    assert "if vif.state != 0 and chan_is_on_channel(node) and not psDwell():" in dpsm
    walk = dpsm.split("and not psDwell():", 1)[1]
    assert walk.count("txl_frame_send_null_frame(") == 1 and walk.count("psSend(") == 1


def test_departure_protects_whatever_ps_state() -> None:
    """chan_goto_idle_cb sends its PM=1 null to every active STA VIF on the
    channel it leaves, and its self-CTS to the AP VIFs, without asking PS:
    its forced idle may just have flushed (and so ended) a power-save
    transition the AP never heard."""
    body = code(procedure((FW / "task_handlers.nim").read_text(), "chan_goto_idle_cb"))
    for name in ["psAwake", "psOwn", "psEnvView", "break build"]:
        assert name not in body, name


def test_resets_drop_me_before_ps() -> None:
    """ke_flush, like me_init then mm_init, resets ME's exchange before it
    cancels PS's transition, so ME never keeps the request psCancel frees."""
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    flush = code(procedure(kernel, "ke_flush"))
    assert flush.count("meControlReset()") == 1 and flush.count("psCancel()") == 1
    assert flush.index("meControlReset()") < flush.index("psCancel()")
    reset = code(procedure((FW / "task_handlers.nim").read_text(), "mm_reset_req_handler"))
    assert reset.index("me_init()") < reset.index("mm_init()")


def test_mm_saves_a_ps_request_only_while_a_transition_is_live() -> None:
    body = code(find_procedure("mm_set_ps_mode_req_handler"))
    assert body.count("KeMsgSaved") == 1
    assert "if psOwn.kind != psIdle:\n    return KeMsgSaved" in body
    assert "psHold(param)" in body and "psAnswer(param)" in body


def test_ps_machinery_is_gone() -> None:
    text = "".join(code(path.read_text()) for path in all_firmware())
    for name in ["psModeBuildSerial", "psTxNullOwner", "PsTxNullOwner", "mmPsModeRequest",
                 "mmPsModeTxResetEpoch", "mmPsModeRetryAfterReset", "mmPsModeCancel",
                 "mmPsModeComplete", "psTracked", "psSerial", "tdEpochs",
                 "tdCfmCommittedEpochs", "tdCfmScheduled", "tdTimerActive",
                 "tdRecoveryTimerActive", "tdOperationCurrent", "deferredMode"]:
        hits = [path.name for path in all_firmware()
                if re.search(rf"\b{name}\b", code(path.read_text()))]
        assert hits in ([], ["layout_types.nim"]), (name, hits)
