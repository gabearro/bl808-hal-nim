"""Exercise supplicant result, deauth queue failure and the exported bridge."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, PLATFORM, ROOT, procedure, station_sm_source


SUPPLICANT_PLATFORM = PLATFORM.replace(
    "instNbr, controlPortState: uint8", "instNbr, controlPortState, valid: uint8"
).replace(
    "proc ke_state_set(task: uint8; state: uint16) =",
    "var currentSmState: uint16\nproc ke_state_set(task: uint8; state: uint16) =",
).replace(
    '  events.add(("state", nil, state, 0\'u16))',
    '  events.add(("state", nil, state, 0\'u16))\n  currentSmState = state',
)
assert SUPPLICANT_PLATFORM.count("currentSmState") == 2

EXTENSION = r"""
const
  VIF_TYPE_STA = 0'u8
  WLAN_FW_4WAY_HANDSHAKE_ERROR_PSK_TIMEOUT_FAILURE = 8
proc smActivationConsumeSuccess(station: uint8): bool = false
proc mmResetBeaconProbeCount(vif: ptr Vif) = vif.probeCount = 0
type MacDataFrameHeaderView = Header
type TestLogProc = proc(level: uint32; tag, file: cstring;
                        line: cint; message: cstring) {.cdecl, varargs, raises: [Exception].}
var
  txResetEpoch, nimFwDbgDisconnectProcess: uint32
  isResetting: bool
  nimFwWpaPendingMask: uint32
  logEnabled: bool
  bridgeLogMode: bool
  logCalls, printfCalls: int
  printfReason: uint32
  bridgeReason: uint32

proc ke_state_get(task: uint8): uint16 = currentSmState
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc txlResetting(): bool = isResetting
proc testLog(level: uint32; tag, file: cstring;
              line: cint; message: cstring) {.cdecl, varargs.} =
  doAssert level == 3 and tag == nil and $file == "sm.c"
  doAssert line == 1717 and $message == "sm deauth frame transmit failure\r\n"
  inc logCalls
{.emit: "#include <stdarg.h>".}
proc testBridgeLog(level: uint32; tag, file: cstring; line: cint;
                   fmt: cstring) {.cdecl, varargs.} =
  doAssert level == 1 and tag == nil and line == 29
  doAssert $file == "supplicant_api.c"
  doAssert $fmt == "bl_wifi_auth_done_internal: sta_idx %u, reason_code %u\r\n"
  var sta, reason: cuint
  {.emit: ["va_list args; va_start(args, ", fmt, "); ",
           sta, " = va_arg(args, unsigned int); ",
           reason, " = va_arg(args, unsigned int); va_end(args);"].}
  doAssert sta == 4
  bridgeReason = reason
  inc logCalls
proc getLogFunc(offset: int): TestLogProc =
  doAssert offset == 204, "callback used printf slot instead of logger"
  if not logEnabled: nil
  elif bridgeLogMode: cast[TestLogProc](testBridgeLog)
  else: testLog
proc testPrintf(fmt: cstring) {.cdecl, varargs.} =
  doAssert "reason code" in $fmt
  var reason: cuint
  {.emit: ["va_list args; va_start(args, ", fmt, "); ",
           reason, " = va_arg(args, unsigned int); va_end(args);"].}
  inc printfCalls
  printfReason = reason
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 4
  if logEnabled: cast[pointer](testPrintf) else: nil
proc resetSupp(vif, station: uint8) =
  reset(vif, station)
  stations[station].instNbr = vif
  stations[station].valid = 1
  currentSmState = 9
  smOwn = default(typeof(smOwn))
  txResetEpoch = 0
  isResetting = false
  logEnabled = false
  bridgeLogMode = false
  logCalls = 0
  printfCalls = 0
  printfReason = 0
  bridgeReason = 0
  nimFwWpaPendingMask = 3
"""

FAILURE_CHECK = r"""
resetSupp(1, 4)
pushFail = true
sm_handle_supplicant_result(4, 17'u8)
doAssert pushCalls == 1 and releases == 1
doAssert events[^1] == ("abort", nil, 9'u16, 17'u16),
  "queue failure must report status 9 exactly once"
"""

CHECKS = r"""
for vif in 0'u8 .. 1'u8:
  for station in 0'u8 .. 6'u8:
    for reason in [1'u16, 15, 17, 255, 256, 0xBEEF, 0xFFFF]:
      resetSupp(vif, station)
      logEnabled = true
      sm_handle_supplicant_result(station, reason)
      doAssert pushCalls == 1 and releases == 0
      doAssert desc.vifIdx == vif and desc.staInfoIdx == station
      # The frame carries the deauthentication wait's stamp, not the VIF.
      doAssert smDeauthConfirmed(desc.callbackArg) and currentSmState == SmDisconnectingState
      doAssert desc.hdrLen == 0 and desc.secTailLen == 0
      let hdr = hostTxDataHeader(addr desc)
      doAssert hdr.frameControl == 0xC0 and hdr.seqCtrl == 0x4560 and hdr.duration == 0
      doAssert hdr.addr1 == stations[station].macAddr
      doAssert hdr.addr2 == vifs[vif].macAddr and hdr.addr3 == hdr.addr1
      doAssert link.macHeader[24] == (reason and 255).uint8
      doAssert link.macHeader[25] == (reason shr 8).uint8
      doAssert hw.payloadEnd == hw.payloadStart + 25 and hw.frameLen == 30
      # State 10 is entered once the frame is built, just before the push.
      doAssert events.len == 2 and events[0].kind == "power" and events[1].kind == "state"
      doAssert printfCalls == (if reason == 15: 1 else: 0)
      if printfCalls != 0: doAssert printfReason == 15
      let cb = cast[proc(p: pointer; status: uint32) {.cdecl.}](desc.callback)
      cb(desc.callbackArg, 0x00800000)
      doAssert logCalls == 0
      doAssert events[^1] == ("abort", nil, 8'u16, 15'u16)

# Any status ends the wait once; only the wait's own stamp is accepted.
for status in [0'u32, 0x800, 0x007FFFFF, 0x00800000, 0x40000000, 0xFFFFFFFF'u32]:
  resetSupp(0, 0)
  logEnabled = true
  let stamp = opStampEnv(smDeauthWait(0, cast[pointer](sm_supplicant_deauth_cfm)))
  events.setLen(0)
  sm_supplicant_deauth_cfm(addr vifs[0], status)
  doAssert logCalls == 0 and events.len == 0
  sm_supplicant_deauth_cfm(stamp, status)
  doAssert logCalls == (if (status and 0x00800000) == 0: 1 else: 0)
  doAssert events == @[("abort", cast[pointer](nil), 8'u16, 15'u16)]
  smGo(SmIdleState)
  sm_supplicant_deauth_cfm(stamp, status)
  doAssert events.len == 2 and events[1].kind == "state"

for failure in 0 .. 3:
  resetSupp(1, 4)
  case failure
  of 0: allocFail = true
  of 1: pushFail = true
  of 2: noLink = true
  else: noHw = true
  sm_handle_supplicant_result(4, 0xBEEF)
  doAssert events[^1] == ("abort", nil, (if failure == 1: 9'u16 else: 10'u16), 0xBEEF'u16)
  doAssert releases == (if failure == 0: 0 else: 1)
  doAssert pushCalls == (if failure == 1: 1 else: 0)
  var notifications = 0
  for event in events:
    if event.kind == "abort": inc notifications
  doAssert notifications == 1

for priorState in [0'u8, 1, 2]:
  resetSupp(0, 0)
  stations[0].controlPortState = priorState
  sm_handle_supplicant_result(0, 0)
  doAssert getCalls == 0 and stations[0].controlPortState == 2
  doAssert events.len == (if priorState == 2: 0 else: 1)
resetSupp(0, 0)
currentSmState = 10
sm_handle_supplicant_result(0, 17)
doAssert getCalls == 0 and events.len == 0
for invalid in [7'u8, 255]:
  resetSupp(0, 0)
  sm_handle_supplicant_result(invalid, 17)
  doAssert getCalls == 0 and events.len == 0

# The public bridge must preserve all 16 reason bits and only clear pending
# WPA state on actual success, including reasons whose low byte is zero.
for reason in [0'u16, 1, 256, 0xBEEF]:
  resetSupp(1, 4)
  logEnabled = true
  bridgeLogMode = true
  doAssert bl_wifi_auth_done_internal(4, reason)
  doAssert logCalls == 1 and bridgeReason == reason.uint32
  if reason == 0:
    doAssert nimFwWpaPendingMask == 1 and stations[4].controlPortState == 2
  else:
    doAssert nimFwWpaPendingMask == 3
    doAssert link.macHeader[24] == (reason and 255).uint8
    doAssert link.macHeader[25] == (reason shr 8).uint8
resetSupp(0, 0)
doAssert not bl_wifi_auth_done_internal(255, 0)
doAssert logCalls == 0 and events.len == 0
resetSupp(0, 0)
stations[0].instNbr = 2
sm_handle_supplicant_result(0, 17)
doAssert getCalls == 0 and events.len == 0
resetSupp(0, 0)
let flushed = opStampEnv(smDeauthWait(0, cast[pointer](sm_supplicant_deauth_cfm)))
sm_supplicant_deauth_cfm(flushed, 0)
doAssert logCalls == 0 and events[^1] == ("abort", nil, 8'u16, 15'u16)

# Once join succeeds, a failure is a station disconnect, not a join result.
# State 10 is entered by the disconnect's cleanup, not before it.
for disruption in 0 .. 5:
  resetSupp(1, 4)
  env.connectInfo = nil
  currentSmState = SmIdleState
  stations[4].controlPortState = 2
  case disruption
  of 1: stations[4].valid = 0
  of 2: vifs[1].staIdx = 5
  of 3: vifs[1].state = 0
  of 4: currentSmState = SmDisconnectingState
  of 5: isResetting = true
  else: discard
  sm_handle_supplicant_result(4, 0x0123)
  doAssert getCalls == 0 and pushCalls == 0
  if disruption == 0:
    doAssert events == @[("disconnect", cast[pointer](addr vifs[1]), 8'u16, 0x0123'u16)]
  else:
    doAssert events.len == 0

resetSupp(1, 4)
env.connectInfo = nil
currentSmState = SmIdleState
stations[4].controlPortState = 2
sm_handle_supplicant_result(4, 0)
doAssert stations[4].controlPortState == 2 and events.len == 0

# Pre-association deauth is deliberately unprotected and always reason 3.
for vif in 0'u8 .. 1'u8:
  resetSupp(vif, 4)
  connectInfo.vifIdx = vif
  sm_deauth_send()
  doAssert pushCalls == 1 and releases == 0
  doAssert desc.callback == nil and desc.callbackArg == addr vifs[vif]
  doAssert desc.vifIdx == vif and desc.staInfoIdx == 4
  doAssert desc.hdrLen == 0 and desc.secTailLen == 0
  doAssert link.macHeader[24] == 3 and link.macHeader[25] == 0
  doAssert hw.payloadEnd == hw.payloadStart + 25 and hw.frameLen == 30
  doAssert protectCalls == 0 and micCalls == 0
  let hdr = hostTxDataHeader(addr desc)
  doAssert hdr.frameControl == 0xC0 and hdr.duration == 0 and hdr.seqCtrl == 0x4560
  doAssert hdr.addr1 == stations[4].macAddr and hdr.addr3 == hdr.addr1
  doAssert hdr.addr2 == vifs[vif].macAddr
for failure in 0 .. 3:
  resetSupp(0, 4)
  connectInfo.vifIdx = 0
  case failure
  of 0: allocFail = true
  of 1: pushFail = true
  of 2: noLink = true
  else: noHw = true
  sm_deauth_send()
  doAssert releases == (if failure == 0: 0 else: 1)
  doAssert pushCalls == (if failure == 1: 1 else: 0)
  for event in events: doAssert event.kind notin ["abort", "disconnect"]
resetSupp(0, 4)
env.connectInfo = nil
sm_deauth_send()
doAssert getCalls == 0
resetSupp(0, 4)
connectInfo.vifIdx = 2
sm_deauth_send()
doAssert getCalls == 0
resetSupp(0, 4)
connectInfo.vifIdx = 0
vifs[0].staIdx = 255
sm_deauth_send()
doAssert getCalls == 0
"""


def run_nim(tmp_path: Path, source: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "supplicant.nim"
    path.write_text("import strutils\n" + source)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'check'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout


def test_supplicant_queue_failure(tmp_path: Path) -> None:
    source = (FW / "scan_station_ap_me.nim").read_text()
    callback = "\nproc sm_supplicant_deauth_cfm(p: pointer; status: uint32) {.cdecl.} = discard\n"
    run_nim(tmp_path, SUPPLICANT_PLATFORM + DEAUTH_WAIT + EXTENSION + callback
            + procedure(source, "me_build_deauthenticate")
            + established_path(source)
            + procedure(source, "sm_handle_supplicant_result") + FAILURE_CHECK)


DEAUTH_WAIT = station_sm_source("smGo", "smDeauthConfirmed", "smDeauthVif",
                                "smDeauthGuardExpired", "smDeauthWait")


def established_path(source: str) -> str:
    return "".join(procedure(source, name) for name in (
        "sm_connect_ind", "smRetireEstablishedSupplicantLink",
    ))


def test_supplicant_reason_and_completion(tmp_path: Path) -> None:
    source = (FW / "scan_station_ap_me.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    platform = (FW / "platform_bl.nim").read_text()
    run_nim(tmp_path, SUPPLICANT_PLATFORM + DEAUTH_WAIT + EXTENSION
            + procedure(tasks, "sm_supplicant_deauth_cfm")
            + procedure(source, "me_build_deauthenticate")
            + established_path(source)
            + procedure(source, "sm_handle_supplicant_result")
            + procedure(source, "smDeauthSend")
            + procedure(source, "sm_deauth_send")
            + procedure(platform, "bl_wifi_auth_done_internal") + CHECKS)
