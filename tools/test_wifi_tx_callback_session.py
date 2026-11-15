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
    "chan_ap_tx_cfm": "task_handlers.nim",
    "chan_sta_tx_cfm": "task_handlers.nim",
    "ps_disable_cfm": "power_save.nim",
    "ps_enable_cfm": "power_save.nim",
    "mm_ap_traffic_probe_cfm": "power_save.nim",
}

PLATFORM = SESSION_PLATFORM + r"""
proc smTxCallbackCurrent(): bool = true
proc chanProtectionTagged(p: pointer): bool = false
proc chanProtectionActive(): bool = false
proc chanProtectionComplete(p: pointer; ap: bool; serial: var uint32): bool = false
proc chanProtectionCurrent(serial: uint32): bool = false
proc chanProtectionResume(serial: uint32) = discard
proc chanProtectionAbandon(p: pointer) = discard
proc chanProtectionCancelSerial(serial: uint32) = discard
type
  Vif = object
    beaconTimeoutBase: uint32
  LogProc = proc(level: uint32; tag, file: cstring; line: cint;
                 message: cstring) {.cdecl, varargs, raises: [Exception].}
var
  effects, cleanups, nested: int
  vif: Vif
  channel: tuple[connlessDelayCount, scanDelayCount: uint8]
  ps: tuple[flags: uint8, pendingCount: uint32]
  mm: tuple[keepAliveLimit: uint32]
  onPoll, onIdle, onLog: proc()
proc sm_disconnect_process(p: pointer; status, reason: uint16) = inc effects
proc sm_connect_ind(status, reason: uint16) = inc effects
proc logHook(level: uint32; tag, file: cstring; line: cint;
             message: cstring) {.cdecl, varargs.} =
  if onLog != nil: onLog()
proc getLogFunc(index: int): LogProc =
  if onLog != nil: logHook else: nil
proc chanEnvView(): ptr typeof(channel) = addr channel
proc mm_force_idle_req(): bool =
  inc effects
  if onIdle != nil: onIdle()
  true
proc chan_pre_switch_channel() = inc effects
proc psEnvView(): ptr typeof(ps) = addr ps
proc mmEnvView(): ptr typeof(mm) = addr mm
proc psTxNullTimer(): pointer = nil
proc mm_timer_clear(p: pointer) = inc effects
proc ps_check_tx_status_part0_nim(p, callback: pointer): uint32 =
  inc effects
  if onPoll != nil: onPoll()
  1
proc ps_disable_cfm_handle(p: pointer): uint32 =
  inc effects
  0
proc ps_enable_cfm_handle(p: pointer) = inc effects
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc macTimeNow(): uint32 = 123
proc mm_send_connection_loss_ind(p: pointer; reason: uint16) = inc effects
proc protocolState(): auto =
  (effects, channel, ps, mm, vif)
proc resetProtocol() =
  setup()
  effects = 0
  cleanups = 0
  nested = 0
  channel = (1'u8, 1'u8)
  ps = (0'u8, 1'u32)
  mm.keepAliveLimit = 0
  vif = default(Vif)
  onPoll = nil
  onIdle = nil
  onLog = nil
"""

CHECKS = r"""
let protocolCallbacks = [
  cast[pointer](sm_disconnect_deauth_cfm), cast[pointer](sm_connect_abort_deauth_cfm),
  cast[pointer](sm_supplicant_deauth_cfm), cast[pointer](chan_ap_tx_cfm),
  cast[pointer](chan_sta_tx_cfm), cast[pointer](ps_disable_cfm),
  cast[pointer](ps_enable_cfm), cast[pointer](mm_ap_traffic_probe_cfm)]
for callback in protocolCallbacks:
  for path in 0 .. 1: # queued completion, explicit failed release
    for status in [0'u32, 0x80800000'u32]:
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
        let current = retirement in [0, 3]
        doAssert (protocolState() != before) == current,
          "protocol callback crossed a retired VIF/station session"
        doAssert txActiveFrameCallback == nil
        doAssert co_list_cnt(addr frameEnv.freeList) == 4
        doAssert txEnv.packetCounter == 0

# Direct calls outside a frame callback retain their existing meaning.
for callback in protocolCallbacks:
  resetProtocol()
  let before = protocolState()
  cast[proc(p: pointer; status: uint32) {.cdecl.}](callback)(addr vif, 0)
  doAssert protocolState() != before

proc queueCallback(callback: pointer) =
  let frame = hostTxDescAt(txl_frame_get(24))
  frame.vifIdx = 0
  frame.staInfoIdx = 0
  frame.callback = callback
  frame.callbackArg = addr vif
  txEnv.packetCounter = 1
  co_list_push_back(addr frameEnv.usedList, addr frame.link)
  txl_frame_evt()

for callback in [cast[pointer](ps_enable_cfm), cast[pointer](ps_disable_cfm)]:
  resetProtocol()
  onPoll = proc() =
    discard rxInvalidateVif(0)
    ps.pendingCount = 7
    effects = 0
  queueCallback(callback)
  doAssert ps.pendingCount == 7 and effects == 0,
    "retry polling changed the VIF but callback still finalized PS"
for callback in [cast[pointer](chan_ap_tx_cfm), cast[pointer](chan_sta_tx_cfm)]:
  resetProtocol()
  if callback == cast[pointer](chan_ap_tx_cfm): channel.scanDelayCount = 0
  else: channel.connlessDelayCount = 0
  onIdle = proc() =
    discard rxInvalidateVif(0)
    channel = (7'u8, 9'u8)
  queueCallback(callback)
  doAssert effects == 1 and channel == (7'u8, 9'u8),
    "idle request restarted the VIF but stale callback continued switching"
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
            if name in ["chan_ap_tx_cfm", "chan_sta_tx_cfm"]:
                entry_guard = ("  if not txlFrameCallbackCurrent():\n"
                               "    chanProtectionAbandon(param)\n    return\n")
                assert entry_guard in body
                body = body.replace(entry_guard, "", 1)
            assert body.count(guard) >= 1
            body = re.sub(r"(?m)^[ \t]+if not txlFrameCallbackCurrent\(\): return\n", "", body)
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
