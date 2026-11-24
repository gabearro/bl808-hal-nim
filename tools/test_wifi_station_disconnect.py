"""Check public disconnect completion and reentrant future ownership."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT, procedure

FACADE = ROOT / "src/bl808/wifi/facade_parts"
PLATFORM = r"""
type
  WifiError = enum wifiOk, wifiFail
  Future = ref object
    finished: bool
    value: WifiError
const
  SmIdleState = 0'u16
  SmDisconnectingState = 10'u16
  wifiScanConfirmed = 1'u32
var
  connected = true
  sm_state: uint16
  issueResult: cint
  disconnectDone: bool
  disconnectCalls, abortCalls, polls, timerCalls: int
  automatic = true
  onIssue, onComplete: proc()
  wifiScanFuture, wifiConnectFuture, wifiStaIdleFuture, wifiDisconnectFuture: Future
  wifiDisconnectIssuePending: bool
  wifiDisconnectIssueTimeoutMs: uint32
  wifiDisconnectTimer: uint32
proc wifiBackendConnected(): bool = connected
proc wifiBackendDisconnectDone(): bool = disconnectDone
proc wifiBackendScanDone(): bool = false
proc wifiBackendScanCount(): uint32 = 0
proc bl808_wifi_backend_scan_confirmation(): uint32 = 0
proc noteWifiScan(stage, detail: uint32) = discard
proc wifiBackendConnectDone(): bool = false
proc wifiBackendStaDisconnect(): cint =
  inc disconnectCalls
  if onIssue != nil: onIssue()
  issueResult
proc wifiBackendStaConnectAbort(): cint =
  inc abortCalls
  if onIssue != nil: onIssue()
  issueResult
proc wifiBackendPoll(count: uint32) =
  inc polls
  if automatic and polls >= 3:
    connected = false
    sm_state = 0
proc wifiDisconnectTrace(message: cstring) = discard
proc wifiDisconnectTraceRc(message: cstring; value: cint) = discard
proc wifiNimFirmwareForceStaIdle() =
  doAssert false, "disconnect bypassed firmware completion"
proc completeWifiScan(value: uint32) = discard
proc completeWifiConnect(value: WifiError) = discard
proc completeWifiStaIdle(value: WifiError) = discard
proc completeWifiDisconnect(value: WifiError) =
  let current = wifiDisconnectFuture
  wifiDisconnectFuture = nil
  wifiDisconnectIssuePending = false
  wifiDisconnectIssueTimeoutMs = 0
  wifiDisconnectTimer = 0
  if current != nil:
    current.finished = true
    current.value = value
  if onComplete != nil: onComplete()
proc addTimerMs(delay: uint64; callback: proc()): uint32 =
  inc timerCalls
  timerCalls.uint32
"""

CASES = {
    "sync_connected": """
doAssert wifiDisconnect() == wifiOk
doAssert disconnectCalls == 1 and polls >= 3 and not connected
""",
    "sync_abort": """
connected = false
sm_state = 6
doAssert wifiDisconnect() == wifiOk
doAssert abortCalls == 1 and polls >= 3 and sm_state == 0
""",
    "sync_peer_cleanup": """
connected = false
sm_state = SmDisconnectingState
issueResult = -5
doAssert wifiDisconnect() == wifiOk
doAssert abortCalls == 0 and disconnectCalls == 0
doAssert polls == 3 and sm_state == SmIdleState
""",
    "sync_failure": """
issueResult = -110
automatic = false
doAssert wifiDisconnect() == wifiFail
doAssert polls == 1 and connected
""",
    "sync_abort_failure": """
issueResult = -5
automatic = false
connected = false
sm_state = 6
doAssert wifiDisconnect() == wifiFail
doAssert sm_state == 6 and polls == 1
""",
    "sync_timeout": """
automatic = false
connected = false
sm_state = 6
doAssert wifiDisconnect() == wifiFail
doAssert sm_state == 6 and polls == 5
""",
    "async_wait": """
let original = Future()
wifiDisconnectFuture = original
wifiDisconnectIssuePending = true
wifiDisconnectIssueTimeoutMs = 100
wifiCompletePendingEvents()
doAssert not original.finished and timerCalls == 1
connected = false
wifiCompletePendingEvents()
doAssert original.finished and original.value == wifiOk
""",
    "async_peer_cleanup": """
issueResult = -5
for hostStillConnected in [false, true]:
  let original = Future()
  wifiDisconnectFuture = original
  wifiDisconnectIssuePending = true
  wifiDisconnectIssueTimeoutMs = 100
  connected = hostStillConnected
  sm_state = SmDisconnectingState
  let previousTimers = timerCalls
  wifiCompletePendingEvents()
  doAssert not original.finished and timerCalls == previousTimers + 1
  doAssert abortCalls == 0 and disconnectCalls == 0
  connected = false
  wifiCompletePendingEvents()
  doAssert not original.finished, "host notification is not cleanup completion"
  sm_state = SmIdleState
  wifiCompletePendingEvents()
  doAssert original.finished and original.value == wifiOk
""",
    "async_cleanup_completed_before_issue": """
let original = Future()
wifiDisconnectFuture = original
wifiDisconnectIssuePending = true
wifiDisconnectIssueTimeoutMs = 100
issueResult = -5
connected = false
sm_state = SmIdleState
wifiCompletePendingEvents()
doAssert original.finished and original.value == wifiOk
doAssert abortCalls == 0 and disconnectCalls == 0
""",
    "async_stale_flag": """
let original = Future()
wifiDisconnectFuture = original
disconnectDone = true
wifiCompletePendingEvents()
doAssert not original.finished, "stale completion flag finished a live link"
""",
    "async_issue_error": """
let original = Future()
wifiDisconnectFuture = original
wifiDisconnectIssuePending = true
issueResult = -5
wifiCompletePendingEvents()
doAssert original.finished and original.value == wifiFail and timerCalls == 0
""",
    "async_replace_during_issue": """
let original = Future()
let replacement = Future()
wifiDisconnectFuture = original
wifiDisconnectIssuePending = true
wifiDisconnectIssueTimeoutMs = 100
onIssue = proc() =
  original.finished = true
  wifiDisconnectFuture = replacement
  wifiDisconnectIssuePending = true
wifiCompletePendingEvents()
doAssert wifiDisconnectFuture == replacement and not replacement.finished
doAssert timerCalls == 0 and wifiDisconnectIssuePending
""",
    "async_replace_after_failure": """
let original = Future()
let replacement = Future()
wifiDisconnectFuture = original
wifiDisconnectIssuePending = true
issueResult = -5
onComplete = proc() =
  connected = false
  wifiDisconnectFuture = replacement
  wifiDisconnectIssuePending = true
wifiCompletePendingEvents()
doAssert original.finished and original.value == wifiFail
doAssert wifiDisconnectFuture == replacement and not replacement.finished
""",
}


def program(case: str, mutation: str | None = None) -> str:
    runtime = (FACADE / "runtime_wrappers_parts/firmware_station.nim").read_text()
    source = PLATFORM
    for name in ["wifiNimFirmwareStaIdle", "wifiNimFirmwareIssueDisconnect", "wifiNimFirmwareDisconnectNeedsDrain"]:
        source += procedure(runtime, name)
    if "proc wifiNimFirmwareStaDisconnected" in runtime:
        source += procedure(runtime, "wifiNimFirmwareStaDisconnected")
    else:
        source += "\nproc wifiNimFirmwareStaDisconnected(): bool = not connected and sm_state == 0\n"
    source += "\nconst WifiDisconnectPollLimit = 4\n"
    source += procedure((FACADE / "station_api_parts/disconnect.nim").read_text(), "wifiDisconnect")
    events = procedure((FACADE / "service_futures_parts/pending_events.nim").read_text(), "wifiCompletePendingEvents")
    if mutation:
        before, after = {
            "identity": ("    if wifiDisconnectFuture != pending or pending.finished: return\n", ""),
            "terminal": ("    if wifiNimFirmwareStaDisconnected():\n", "    if wifiNimFirmwareStaIdle():\n"),
            "continuation": ("      completeWifiDisconnect(wifiFail)\n      return\n", "      completeWifiDisconnect(wifiFail)\n"),
        }[mutation]
        assert before in events
        events = events.replace(before, after)
    source += events
    return source + "\n" + CASES[case]


def run(tmp_path: Path, case: str, mode: str, mutation: str | None = None) -> None:
    nim = shutil.which("nim")
    if nim is None: pytest.skip("Nim is required")
    source = tmp_path / "station_disconnect.nim"
    source.write_text(program(case, mutation))
    flags = {"checked": [], "release": ["-d:release"],
             "asan": ["--passC:-fsanitize=address", "--passL:-fsanitize=address"],
             "arc": ["--mm:arc"]}[mode]
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
                             *flags, "--checks:on", f"--nimcache:{tmp_path / 'cache'}",
                             f"-o:{tmp_path / 'test'}", str(source)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if mutation: assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
    else: assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan", "arc"])
def test_station_disconnect(tmp_path: Path, case: str, mode: str) -> None:
    run(tmp_path, case, mode)


@pytest.mark.parametrize("mutation,case", [("identity", "async_replace_during_issue"),
                                         ("terminal", "async_wait"),
                                         ("continuation", "async_replace_after_failure")])
def test_station_disconnect_guards(tmp_path: Path, mutation: str, case: str) -> None:
    run(tmp_path, case, "checked", mutation)
