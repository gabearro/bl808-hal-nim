"""Run complete deauthentication builders and delayed completion ownership."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, ROOT, procedure, station_sm_source
from test_wifi_station_tx_build import program_source as station_source

SUPPORT = r'''
const InvalidFrameDescIndex = high(uint32)
type ManagementReasonBodyView {.packed.} = object
  reason: uint16
var
  txFrameIdentities: array[2, TxFrameIdentity]
  mmBcnGeneration: uint32
  mfpMode: uint32
  badMic: bool
  disconnects: int
  txResetActive: bool
  authStarts: int
  nimFwDbgActiveCfmBadState, nimFwDbgActiveCfmLastState: uint32
proc mm_bcn_transmitted() = discard
proc managementReasonBodyAt(p: pointer): ptr ManagementReasonBodyView =
  cast[ptr ManagementReasonBodyView](p)
proc txl_frame_desc_index(p: pointer): uint32 =
  if p == nil: InvalidFrameDescIndex else: frameIndex(p).uint32
proc mfp_protect_mgmt_frame(p: pointer; fc: uint32): uint32 =
  doAssert fc == 0xC0
  observe(3)
  mfpMode
proc mfp_add_mgmt_mic(p, bytes: pointer; length: uint32): uint32 =
  observe(10)
  if badMic: 0'u32 else: 18'u32
proc failed(p: pointer; status, reason: uint16) {.cdecl.} =
  inc failures
  failureStatus = status
proc smCleanupConfirmed() = doAssert false, "no cleanup runs here"
proc sm_auth_start() = inc authStarts
var batchDone = true
proc smBssNext(): bool = batchDone  # station_bss.nim: the STA VIF is still there
'''

TEARDOWN = r'''
proc sm_disconnect_process(p: pointer; status, reason: uint16) {.cdecl.} =
  # The real one enters the cleanup, a new SM state.
  inc disconnects
  sm.connectInfo = nil
  smGo(0)
proc smConnectEnd(status, reason: uint16) =
  # The real one tears the attempt down: a new SM state.
  sm_connect_ind(status, reason)
  smGo(SmDisconnectingState, tdCleanup)
proc smTeardown(vif: pointer; indication: pointer = nil; disconnected = false;
                status = 0'u16; reason = 0'u16): bool {.discardable.} = doAssert false
'''

CHECKS = r'''
proc prepare(kind: int) =
  setup(1)
  currentState = if kind == 0: 6 else: 4
  disconnects = 0
  authStarts = 0
  mfpMode = 0
  badMic = false
proc sendDeauth(kind: int) =
  if kind == 0:
    sm_handle_connection(1, 24, cast[pointer](sm_disconnect_deauth_cfm), cast[pointer](failed))
  else: sm_deauth_send()
proc complete() =
  let captured = txlCaptureFrameCallback(activeFrame)
  let callback = activeFrame.callback
  let argument = activeFrame.callbackArg
  txlInvokeFrameCallback(callback, argument, 0, captured)
'''

CASES = {
    "preparation_replacement": r'''
for kind in 0..1:
  for point in [1, 2]:
    prepare(kind)
    hook = point
    action = 1
    sendDeauth(kind)
    doAssert hookFired and pushes == 0 and failures == 0
    doAssert currentState == 9 and sm.connectInfo == addr replacementConn
''',
    "lease_reuse": r'''
for kind in 0..1:
  prepare(kind)
  hook = 2
  action = 2
  sendDeauth(kind)
  let i = frameIndex(activeFrame)
  doAssert descriptors[i] == replacementDesc and hardware[i] == replacementHw and links[i] == replacementLink,
    "older deauthentication builder modified a replacement frame"
  doAssert pushes == 0 and leased[i]
''',
    "protection_lease_reuse": r'''
for point in [3, 10, 11]:
  prepare(0)
  mfpMode = if point == 11: 1 else: 2
  hook = point
  action = 2
  sendDeauth(0)
  let i = frameIndex(activeFrame)
  doAssert hookFired and descriptors[i] == replacementDesc
  doAssert hardware[i] == replacementHw and links[i] == replacementLink
  doAssert pushes == 0 and leased[i]
''',
    "trace_lease_reuse": r'''
prepare(1)
hook = 4
action = 2
sendDeauth(1)
let i = frameIndex(activeFrame)
doAssert hookFired and descriptors[i] == replacementDesc
doAssert hardware[i] == replacementHw and links[i] == replacementLink
doAssert pushes == 0 and leased[i]
''',
    "failed_handoff_replacement": r'''
prepare(0)
hook = 6
action = 1
pushFailure = true
sendDeauth(0)
doAssert pushes == 1 and failures == 0 and currentState == 9,
  "older failed handoff notified the replacement connection"
''',
    "station_reassigned": r'''
for kind in 0..1:
  prepare(kind)
  hook = 2
  action = 6
  sendDeauth(kind)
  doAssert hookFired and pushes == 0 and failures == 0 and vifs[1].staIdx == 3
# Once queued, the frame's confirmation ends the wait whatever the VIF now
# holds; the cleanup decides what is left to release.
prepare(0)
sendDeauth(0)
vifs[1].staIdx = 3
complete()
doAssert disconnects == 1
''',
    "completion_replacement": r'''
prepare(0)
sendDeauth(0)
doAssert pushes == 1
sm.connectInfo = addr replacementConn
smGo(6)
complete()
doAssert disconnects == 0 and sm.connectInfo == addr replacementConn,
  "older completion disconnected a replacement attempt"
''',
    "state_replacement": r'''
prepare(0)
hook = 7
action = 1
sendDeauth(0)
doAssert pushes == 0 and failures == 0 and currentState == 9
''',
    "protection_replacement": r'''
for point in [3, 10]:
  prepare(0)
  mfpMode = 2
  hook = point
  action = 1
  sendDeauth(0)
  doAssert hookFired and pushes == 0 and failures == 0 and currentState == 9
''',
    "retirement_replacement": r'''
prepare(0)
hook = 9
action = 1
mfpMode = 2
badMic = true
sendDeauth(0)
doAssert hookFired and releases == 1 and failures == 0 and currentState == 9
''',
    "bip_append_failure": r'''
for enabled in [false, true]:
  prepare(0)
  interruptsEnabled = enabled
  mfpMode = 2
  badMic = true
  sendDeauth(0)
  doAssert pushes == 0 and releases == 1 and failures == 1
  doAssert failureStatus == 24 and disconnects == 0
  doAssert interruptsEnabled == enabled
''',
    "completion_newer_build": r'''
# A second deauthentication is not sent while the first one's wait is live.
prepare(0)
sendDeauth(0)
let oldFrame = activeFrame
let oldScope = txlCaptureFrameCallback(oldFrame)
let callback = oldFrame.callback
let argument = oldFrame.callbackArg
sendDeauth(0)
doAssert pushes == 1 and activeFrame == oldFrame
txlInvokeFrameCallback(callback, argument, 0, oldScope)
doAssert disconnects == 1
txlInvokeFrameCallback(callback, argument, 0, oldScope)
doAssert disconnects == 1
''',
    "completion_state_change": r'''
prepare(0)
sendDeauth(0)
smGo(9)
complete()
doAssert disconnects == 0 and currentState == 9
''',
    "completion_reset_retirement": r'''
# A frame retired by a TX reset (or aged out after one: disruption 1) still
# ends the wait it carries; only an argument that is not the wait's stamp
# (disruption 6, the vendor's VIF pointer) is ignored. Exactly once.
for disruption in 0 .. 6:
  prepare(0)
  sendDeauth(0)
  let frame = activeFrame
  let context = txlCaptureFrameCallback(frame)
  let callback = frame.callback
  let argument = if disruption == 6: cast[pointer](addr vifs[0]) else: frame.callbackArg
  inc txResetEpoch
  txResetActive = disruption != 1
  case disruption
  of 2: inc rxVifEpochs[1]
  of 3: inc stationEpochs[frame.staInfoIdx]
  of 4: inc smTxSerials[1]
  of 5: sm.connectInfo = addr replacementConn
  else: discard
  txlInvokeFrameCallback(callback, argument, 0x40000000'u32, context)
  doAssert disconnects == (if disruption == 6: 0 else: 1)
  txlInvokeFrameCallback(callback, argument, 0x40000000'u32, context)
  doAssert disconnects == (if disruption == 6: 0 else: 1)
  txResetActive = false
''',
    "connected_without_attempt": r'''
prepare(0)
sm.connectInfo = nil
sendDeauth(0)
doAssert pushes == 1 and failures == 0
complete()
doAssert disconnects == 1
''',
    "abort_completion": r'''
for replace in [false, true]:
  prepare(0)
  sm_handle_connection(1, 24, cast[pointer](sm_connect_abort_deauth_cfm), cast[pointer](failed))
  if replace:
    sm.connectInfo = addr replacementConn
    smGo(6)
  complete()
  doAssert failures == (if replace: 0 else: 1)
  if not replace: doAssert failureStatus == 23
''',
    "interrupt_state": r'''
for enabled in [false, true]:
  for failure in [false, true]:
    prepare(0)
    interruptsEnabled = enabled
    pushFailure = failure
    sendDeauth(0)
    doAssert interruptsEnabled == enabled
''',
    "normal_completion": r'''
for mode in 0'u32..2:
  prepare(0)
  mfpMode = mode
  sendDeauth(0)
  doAssert pushes == 1 and failures == 0 and disconnects == 0
  doAssert currentState == 10 and smOwn.teardown == tdDeauthWait
  doAssert smDeauthConfirmed(activeFrame.callbackArg)
  let expected = if mode == 1: 42'u16 elif mode == 2: 44'u16 else: 26'u16
  doAssert activeFrame.frameLen == expected and activeFrame.seqPassthrough == expected
  complete()
  doAssert disconnects == 1
prepare(1)
sendDeauth(1)
doAssert pushes == 1 and failures == 0 and currentState == 4
doAssert activeFrame.frameLen == 26 and activeFrame.callback == nil
''',
    # The answer to the BSS batch's last request sends the deauthentication
    # sm_init asked for, then starts authentication.
    "active_normal": r'''
for pending in 0'u8..1:
  prepare(1)
  sm.deauthPending = pending
  var answer: uint8
  smOwn.answer = addr answer
  doAssert me_set_active_cfm_handler_sm(addr answer) == 0
  doAssert pushes == pending.int and authStarts == 1 and sm.deauthPending == 0
  doAssert smOwn.answer == nil
# The batch ended the attempt instead (its STA VIF is gone): no deauthentication
# and no authentication.
prepare(1)
sm.deauthPending = 1
batchDone = false
var answer: uint8
smOwn.answer = addr answer
doAssert me_set_active_cfm_handler_sm(addr answer) == 0
doAssert pushes == 0 and authStarts == 0 and sm.deauthPending == 1
batchDone = true
''',
    # Any other ME_SET_ACTIVE_CFM (stale, or none) changes nothing.
    "active_not_the_answer": r'''
prepare(1)
sm.deauthPending = 1
var answer, other: uint8
smOwn.answer = addr answer
doAssert me_set_active_cfm_handler_sm(addr other) == 0
doAssert me_set_active_cfm_handler_sm(nil) == 0
doAssert pushes == 0 and authStarts == 0 and sm.deauthPending == 1
doAssert smOwn.answer == addr answer
''',
}


def source() -> str:
    tx = (FW / "tx_layer.nim").read_text()
    sm = (FW / "scan_station_ap_me.nim").read_text()
    code = station_source()
    code = code.replace("    connectFlags: uint8", "    connectFlags, deauthPending: uint8", 1)
    code = code.replace("    smConnecting = false\n  of 2:",
                        "    smConnecting = false\n    sm.deauthPending = 9\n  of 2:", 1)
    code = re.sub(r"  TxFrameIdentity = object\n.*?\nvar\n",
                  layouts("TxFrameIdentity", "TxFrameCallbackScope").removeprefix("type\n") + "\nvar\n",
                  code, count=1, flags=re.S)
    if "proc txlFrameBindSmOwner" in code:
        code = code.replace(procedure(code, "txlFrameBindSmOwner"), "", 1)
    code = code.replace("  inc releases\n", "  inc releases\n  observe(9)\n", 1)
    code = code.replace("  hostTxDescAt(p).hdrLen = 4", "  hostTxDescAt(p).hdrLen = 8")
    code = code.replace("  hostTxDescAt(p).secTailLen = 4", "  hostTxDescAt(p).secTailLen = 8")
    code = code.replace("hostTxDataHeader(hostTxDescAt(p)).frameControl = 0x40B0",
                        "hostTxDataHeader(hostTxDescAt(p)).frameControl = 0x40C0")
    protect = procedure(code, "txu_cntrl_protect_mgmt_frame")
    code = code.replace(protect, protect.replace("observe(3)", "observe(11)"), 1)
    extra = SUPPORT
    for name in ["txlCaptureFrameIdentity", "txlFrameIdentityCurrent", "txlCaptureFrameCallback",
                 "txlFrameCallbackCurrent", "txlInvokeFrameCallback", "txlFrameBindSmOwner"]:
        if re.search(rf"^proc {name}\(", tx, re.M):
            extra += procedure(tx, name)
    code = code.replace("var smTxSerials", extra + "\nvar smTxSerials", 1)
    code = code.replace("      inc generations[i]\n", """      inc generations[i]
      txFrameIdentities[i] = txlCaptureFrameIdentity()
      txFrameIdentities[i].generation = generations[i]
      txFrameIdentities[i].leased = true
""", 1)
    # Definitions used by the allocator must precede that procedure.
    marker = "proc txl_frame_get(size: uint32): pointer ="
    first, rest = code.split(marker, 1)
    extra_start = rest.index("const InvalidFrameDescIndex")
    extra_end = rest.index("\nvar smTxSerials", extra_start)
    extras = rest[extra_start:extra_end]
    rest = rest[:extra_start] + rest[extra_end:]
    code = first + extras + "\n" + marker + rest
    code += TEARDOWN
    code += station_sm_source("smTakeAnswer", "smDeauthConfirmed", "smDeauthVif",
                              "smDeauthGuardExpired", "smDeauthWait", record=False)
    for name in ["me_build_deauthenticate", "sm_disconnect_deauth_cfm",
                 "sm_connect_abort_deauth_cfm", "sm_handle_connection", "smDeauthSend", "sm_deauth_send"]:
        if not re.search(rf"^proc {name}\*?\(", sm, re.M):
            continue
        code += procedure(sm, name)
    tasks = (FW / "task_handlers.nim").read_text()
    code += procedure(tasks, "me_set_active_cfm_handler_sm")
    return code + CHECKS


def run_case(tmp_path: Path, case: str, mode: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "deauth.nim"
    path.write_text(source() + "\n" + CASES[case])
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}[mode]
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--checks:on", "-d:bl808WifiConnectTrace",
        f"--path:{ROOT / 'src'}", *flags, f"--nimcache:{tmp_path / 'cache'}",
        f"-o:{tmp_path / 'check'}", str(path)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_deauth_lifetime(tmp_path: Path, case: str, mode: str) -> None:
    run_case(tmp_path, case, mode)
