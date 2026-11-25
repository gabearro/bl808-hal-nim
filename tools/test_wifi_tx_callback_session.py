"""Run protocol callbacks inside real TX completion/release session scopes."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_tx_session import PLATFORM as SESSION_PLATFORM

ROOT = Path(__file__).resolve().parents[1]

CALLBACKS = {
    "sm_disconnect_deauth_cfm": "scan_station_ap_me.nim",
    "sm_connect_abort_deauth_cfm": "scan_station_ap_me.nim",
    "sm_supplicant_deauth_cfm": "task_handlers.nim",
    "ps_disable_cfm": "power_save.nim",
    "ps_enable_cfm": "power_save.nim",
    "mm_ap_traffic_probe_cfm": "power_save.nim",
    "mm_ap_probe_cfm": "kernel_mac_channel.nim",
}

PLATFORM = SESSION_PLATFORM + r"""
proc smTxCallbackCurrent(): bool = true
proc smClaimFlushedDisconnect(p: pointer): bool = false
proc smClaimFlushedSupplicantDeauth(p: pointer): bool = false
type
  Vif = object
    beaconTimeoutBase: uint32
    probeCount, vifIdx: uint8
  LogProc = proc(level: uint32; tag, file: cstring; line: cint;
                 message: cstring) {.cdecl, varargs, raises: [Exception].}
var
  effects, cleanups, nested: int
  vif: Vif
  channel: tuple[connlessDelayCount, scanDelayCount: uint8]
  ps: tuple[flags: uint8, pendingCount: uint32]
  mm: tuple[keepAliveLimit: uint32]
  mmTrafficProbeEpochs: array[MAX_VIFS, uint32]
  onPoll, onIdle, onLog, onClear: proc()
proc sm_disconnect_process(p: pointer; status, reason: uint16) = inc effects
proc sm_connect_ind(status, reason: uint16) = inc effects
proc logHook(level: uint32; tag, file: cstring; line: cint;
             message: cstring) {.cdecl, varargs.} =
  if onLog != nil: onLog()
proc getLogFunc(index: int): LogProc =
  if onLog != nil: logHook else: nil
proc chanEnvView(): ptr typeof(channel) = addr channel
proc chanForceIdle(): bool =
  inc effects
  inc txResetEpoch
  if onIdle != nil: onIdle()
  true
proc chan_pre_switch_channel() = inc effects
proc psEnvView(): ptr typeof(ps) = addr ps
proc mmEnvView(): ptr typeof(mm) = addr mm
proc psTxNullTimer(): pointer = nil
proc mm_timer_clear(p: pointer) =
  inc effects
  if onClear != nil: onClear()
proc ps_check_tx_status_part0_nim(p, callback: pointer): uint32 =
  inc effects
  if onPoll != nil: onPoll()
  1
proc ps_disable_cfm_handle(p: pointer): uint32 =
  inc effects
  0
proc ps_enable_cfm_handle(p: pointer) = inc effects
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc mmResetBeaconProbeCount(vif: ptr Vif) = vif.probeCount = 0
proc macTimeNow(): uint32 = 123
proc mm_send_connection_loss_ind(p: pointer; reason: uint16) = inc effects
proc mmPublishConnectionLoss(p: pointer; reason: uint16; epoch: ptr uint32) =
  mm_send_connection_loss_ind(p, reason)
proc protocolState(): auto =
  (effects, channel, ps, mm, vif)
proc resetProtocol() =
  setup()
  effects = 0
  cleanups = 0
  nested = 0
  channel = (1'u8, 1'u8)
  ps = (0'u8, 1'u32)
  psModeBuildSerial = 0
  mm.keepAliveLimit = 0
  vif = Vif(probeCount: 17)
  onPoll = nil
  onIdle = nil
  onLog = nil
  onClear = nil
"""

CHECKS = r"""
let protocolCallbacks = [
  cast[pointer](sm_disconnect_deauth_cfm), cast[pointer](sm_connect_abort_deauth_cfm),
  cast[pointer](sm_supplicant_deauth_cfm), cast[pointer](ps_disable_cfm),
  cast[pointer](ps_enable_cfm), cast[pointer](mm_ap_traffic_probe_cfm),
  cast[pointer](mm_ap_probe_cfm)]
for callback in protocolCallbacks:
  let probe = callback in [cast[pointer](mm_ap_probe_cfm), cast[pointer](mm_ap_traffic_probe_cfm)]
  for path in 0 .. 1: # queued completion, explicit failed release
    for status in [0'u32, 0x80010700'u32, 0x80800000'u32]:
      for retirement in 0 .. 3:
        resetProtocol()
        let frame = hostTxDescAt(txl_frame_get(24))
        frame.vifIdx = 0
        frame.staInfoIdx = 0
        frame.callback = callback
        frame.callbackArg = addr vif
        hostTxHwDescAt(frame.hwDesc).confirmStatus = status
        case retirement
        of 1: discard rxInvalidateVif(0)
        of 2: inc stationEpochs[0]
        of 3: discard rxInvalidateVif(1)
        else: discard
        let before = protocolState()
        if path == 0:
          txEnv.packetCounter = 1
          co_list_push_back(addr frameEnv.usedList, addr frame.link)
          txl_frame_evt()
        else:
          txl_frame_release(frame, true)
        let reported = not probe or (path == 0 and (status and 0x80000000'u32) != 0)
        let current = retirement in [0, 3]
        let superseded = callback == cast[pointer](mm_ap_probe_cfm) and status == 0x80010700'u32
        doAssert (protocolState() != before) == (current and reported and not superseded),
          "protocol callback crossed a retired VIF/station session"
        doAssert txActiveFrameCallback == nil
        doAssert co_list_cnt(addr frameEnv.freeList) == 4
        doAssert txEnv.packetCounter == 0

# Direct calls outside a frame callback retain their existing meaning.
for callback in protocolCallbacks:
  resetProtocol()
  let before = protocolState()
  let probe = callback in [cast[pointer](mm_ap_probe_cfm), cast[pointer](mm_ap_traffic_probe_cfm)]
  cast[proc(p: pointer; status: uint32) {.cdecl.}](callback)(addr vif,
    (if probe: 0x80800000'u32 else: 0'u32))
  doAssert protocolState() != before

  if probe:
    # Delivery can yield after taking the hardware status and before invoking
    # the callback. The original session must still veto a real ACK.
    resetProtocol()
    let frame = hostTxDescAt(txl_frame_get(24))
    frame.vifIdx = 0
    frame.staInfoIdx = 0
    let context = txlCaptureFrameCallback(frame)
    discard rxInvalidateVif(0)
    let retired = protocolState()
    txlInvokeFrameCallback(callback, addr vif, 0x80800000'u32, context)
    doAssert protocolState() == retired
    txl_frame_release(frame, false)

proc queueCallback(callback: pointer; status = 0'u32;
                   tagged = false; retire = false; flush = false) =
  let frame = hostTxDescAt(txl_frame_get(24))
  frame.vifIdx = 0
  frame.staInfoIdx = 0
  frame.callback = callback
  frame.callbackArg = addr vif
  if tagged:
    let slot = txl_frame_desc_index(frame)
    txFrameIdentities[slot].psTracked = true
    txFrameIdentities[slot].psSerial = psModeBuildSerial
  if retire: inc psModeBuildSerial
  hostTxHwDescAt(frame.hwDesc).confirmStatus = status
  if flush: txl_frame_release(frame, true)
  else:
    txEnv.packetCounter = 1
    co_list_push_back(addr frameEnv.usedList, addr frame.link)
    txl_frame_evt()

for callback in [cast[pointer](ps_enable_cfm), cast[pointer](ps_disable_cfm)]:
  for flush in [false, true]:
    resetProtocol()
    ps.pendingCount = 7
    queueCallback(callback, 0x80800000'u32, tagged = true, retire = true, flush = flush)
    doAssert ps.pendingCount == 7 and effects == 0,
      "a delayed PS frame borrowed the replacement batch's generation"
    doAssert co_list_cnt(addr frameEnv.freeList) == 4
  resetProtocol()
  queueCallback(callback, 0x80800000'u32, tagged = true)
  doAssert ps.pendingCount == 0 and effects == 2

  resetProtocol()
  onPoll = proc() =
    discard rxInvalidateVif(0)
    ps.pendingCount = 7
    effects = 0
  queueCallback(callback)
  doAssert ps.pendingCount == 7 and effects == 0,
    "retry polling changed the VIF but callback still finalized PS"
  for change in 0 .. 3:
    resetProtocol()
    onClear = proc() =
      doAssert ps.pendingCount == 0
      case change
      of 1: ps.pendingCount = 1
      of 2: discard rxInvalidateVif(0)
      of 3: discard rxInvalidateVif(1)
      else: discard
    queueCallback(callback, 0x80800000'u32)
    doAssert ps.pendingCount == (change == 1).uint32
    doAssert effects == (if change in [1, 2]: 1 else: 2),
      "PS finalized after timer clear changed its pending count or owner"
  resetProtocol()
  onPoll = proc() =
    doAssert txlFrameCallbackCurrent()
    inc psModeBuildSerial
    ps.pendingCount = 7
  queueCallback(callback)
  doAssert ps.pendingCount == 7 and effects == 1,
    "retired retry consumed the replacement mode's count"
  resetProtocol()
  onClear = proc() =
    doAssert txlFrameCallbackCurrent() and ps.pendingCount == 0
    inc psModeBuildSerial
  queueCallback(callback, 0x80800000'u32)
  doAssert ps.pendingCount == 0 and effects == 1,
    "retired confirmation finalized the replacement mode after timer clear"
resetProtocol()
onLog = proc() = discard rxInvalidateVif(0)
queueCallback(cast[pointer](sm_supplicant_deauth_cfm))
doAssert effects == 0, "logging hook restarted the VIF before the connect indication"

proc cleanup(p: pointer; status: uint32) {.cdecl.} =
  inc cleanups
  doAssert not txlFrameCallbackCurrent()
  doAssert status == 0 or status == 0x40000000'u32
for path in 0 .. 1:
  resetProtocol()
  let frame = hostTxDescAt(txl_frame_get(24))
  frame.vifIdx = 0
  frame.staInfoIdx = 0
  frame.callback = cast[pointer](cleanup)
  discard rxInvalidateVif(0)
  if path == 0:
    txEnv.packetCounter = 1
    co_list_push_back(addr frameEnv.usedList, addr frame.link)
    txl_frame_evt()
  else:
    txl_frame_release(frame, true)
  doAssert cleanups == 1, "retired ownership cleanup was suppressed"

proc inner(p: pointer; status: uint32) {.cdecl.} =
  doAssert txlFrameCallbackCurrent()
  inc nested
  sm_connect_abort_deauth_cfm(addr vif, status)
proc outer(p: pointer; status: uint32) {.cdecl.} =
  doAssert txlFrameCallbackCurrent()
  discard rxInvalidateVif(0)
  doAssert not txlFrameCallbackCurrent(), "callback cached currentness across restart"
  let frame = hostTxDescAt(txl_frame_get(24))
  frame.vifIdx = 0
  frame.staInfoIdx = 0
  frame.callback = cast[pointer](inner)
  frame.callbackArg = addr vif
  inc txEnv.packetCounter
  co_list_push_back(addr frameEnv.usedList, addr frame.link)
  txl_frame_evt()
  doAssert not txlFrameCallbackCurrent(), "nested callback lost its parent's identity"
  let before = protocolState()
  sm_connect_abort_deauth_cfm(addr vif, status)
  doAssert protocolState() == before
resetProtocol()
let frame = hostTxDescAt(txl_frame_get(24))
frame.vifIdx = 0
frame.staInfoIdx = 0
frame.callback = cast[pointer](outer)
txEnv.packetCounter = 1
co_list_push_back(addr frameEnv.usedList, addr frame.link)
txl_frame_evt()
doAssert nested == 1 and effects == 1 and txActiveFrameCallback == nil
doAssert co_list_cnt(addr frameEnv.freeList) == 4

proc throwing(p: pointer; status: uint32) {.cdecl.} =
  doAssert txlFrameCallbackCurrent()
  raise newException(ValueError, "callback failure")
resetProtocol()
let exceptionFrame = hostTxDescAt(txl_frame_get(24))
exceptionFrame.vifIdx = 0
exceptionFrame.staInfoIdx = 0
try:
  txlInvokeFrameCallback(cast[pointer](throwing), nil, 0,
                         txlCaptureFrameCallback(exceptionFrame))
  doAssert false
except ValueError: discard
doAssert txActiveFrameCallback == nil and txlFrameCallbackCurrent()
"""


@pytest.mark.parametrize("release", [False, True])
@pytest.mark.parametrize("mutation", [None, "context", *CALLBACKS])
def test_callback_session_scope(tmp_path: Path, release: bool, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    functions = "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent",
        "txlCaptureFrameCallback", "txlFrameCallbackCurrent", "txlInvokeFrameCallback",
        "txl_frame_free_list_pop", "txl_frame_get", "txl_frame_release",
        "txlFrameConfirmPending", "txl_frame_evt",
    ])
    functions += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateQuiescentVif")
    functions += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateVif")
    for name, filename in CALLBACKS.items():
        body = procedure((FW / filename).read_text(), name)
        if mutation == name:
            guard = "  if not txlFrameCallbackCurrent(): return\n"
            if name in ["sm_disconnect_deauth_cfm", "sm_connect_abort_deauth_cfm"]:
                guard = "  if not txlFrameCallbackCurrent() and not smClaimFlushedDisconnect(param): return\n"
            if name == "sm_supplicant_deauth_cfm":
                guard = "  if not txlFrameCallbackCurrent() and not smClaimFlushedSupplicantDeauth(param): return\n"
            assert body.count(guard) >= 1
            body = re.sub(r"(?m)^[ \t]+if not txlFrameCallbackCurrent\((?:frameEpoch)?\)"
                          r"(?: and not smClaimFlushed(?:Disconnect|SupplicantDeauth)\(param\))?: return\n", "", body)
        functions += body
    if mutation == "context":
        assignment = "  txActiveFrameCallback = addr scope\n"
        assert functions.count(assignment) == 1
        functions = functions.replace(assignment, "")
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n"
        for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
    )
    source = tmp_path / "callback_session.nim"
    source.write_text(PLATFORM + debug + functions + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on"]
    if release:
        command += ["-d:release"]
    command += ["--checks:on", f"--nimcache:{tmp_path / 'nimcache'}",
                f"-o:{tmp_path / 'test'}", str(source)]
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout


def test_protection_callbacks_are_owned_by_their_switch_generation() -> None:
    """Channel protection frames finish with any status, a flush or a retired
    VIF session included (chan.o). They are owned by the departure attempt
    whose token they carry, not by the TX session, so the session veto that
    guards the other protocol callbacks does not apply to them."""
    tasks = (FW / "task_handlers.nim").read_text()
    for name in ["chan_ap_tx_cfm", "chan_sta_tx_cfm"]:
        body = procedure(tasks, name)
        assert "txlFrameCallbackCurrent" not in body
        assert "chanProtectionDone(param, " in body
