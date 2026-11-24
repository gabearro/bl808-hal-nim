"""Run WiFi future completion and reentrant waits with the real ARC runtime."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT, procedure

FACADE = ROOT / "src/bl808/wifi/facade_parts"
RX = ROOT / "src/bl808/wifi/rx"
PLATFORM = r'''
type
  WifiError = enum wifiOk, wifiFail
  TimerId = uint32
  Timer = object
    callback: proc()
    cancelled: bool
  ScanConfirmation = object
    length: uint32
    status: uint8
const IpcMsgParamLenOff = 0'u
var
  timers: seq[Timer]
  wifiScanFuture: CpsFuture[uint32]
  wifiConnectFuture, wifiStaIdleFuture, wifiDisconnectFuture: CpsFuture[WifiError]
  wifiScanTimer, wifiConnectTimer, wifiStaIdleTimer, wifiDisconnectTimer: TimerId
  wifiDisconnectIssuePending: bool
  wifiDisconnectIssueTimeoutMs: uint32
  scanDone, connectDone, connected, idle, disconnected: bool
  eventFutures = true
  scanCount = 7'u32
  scanConfirmationStatus: uint32
  staIface: pointer
  scanSubmitStatus: cint
  issueStatus: cint
  issued: int
proc addTimerMs(ms: uint64; callback: proc()): TimerId =
  doAssert ms > 0
  timers.add(Timer(callback: callback))
  timers.len.uint32
proc cancelTimer(id: TimerId) =
  doAssert id > 0 and id.int <= timers.len
  timers[id.int - 1].cancelled = true
proc fire(id: TimerId) =
  if not timers[id.int - 1].cancelled:
    timers[id.int - 1].callback()
proc wifiBackendUsesEventFutures(): bool = eventFutures
proc wifiBackendScanDone(): bool = scanDone
proc bl808_wifi_backend_scan_count(): uint32 = scanCount
proc bl808_wifi_backend_scan_confirmation(): uint32 = scanConfirmationStatus
proc bl808_wifi_backend_record_scan_confirmation(status: uint32) =
  scanConfirmationStatus = status
proc loadU32(p: pointer; offset: uint): uint32 =
  doAssert p != nil and offset == IpcMsgParamLenOff
  cast[ptr ScanConfirmation](p).length
proc msgParam(p: pointer): pointer =
  doAssert cast[ptr ScanConfirmation](p).length == 1
  addr cast[ptr ScanConfirmation](p).status
proc loadU8(p: pointer; offset: uint): uint8 =
  doAssert offset == 0
  cast[ptr uint8](p)[]
proc wifi_mgmr_scan(data: pointer; callback: pointer): cint =
  doAssert data == (addr staIface) and callback == nil
  scanDone = false
  scanConfirmationStatus = 0
  scanSubmitStatus
proc wifiBackendConnectDone(): bool = connectDone
proc wifiBackendConnected(): bool = connected
proc wifiNimFirmwareStaIdle(): bool = idle
proc wifiNimFirmwareStaDisconnected(): bool = disconnected
proc wifiNimFirmwareIssueDisconnect(): cint =
  inc issued
  issueStatus
proc wifiCompletePendingEvents()
proc notifyEventScanDone(joinScan: bool) =
  if not joinScan:
    scanDone = true
    wifiCompletePendingEvents()
'''


def source() -> str:
    code = f'import "{ROOT / "src/bl808/kernel/runtime"}"\n' + PLATFORM
    state = (FACADE / "runtime_wrappers_parts/state.nim").read_text()
    code += "when defined(bl808WifiDiagLinkDrop):\n" + state.split(
        "when defined(bl808WifiDiagLinkDrop):\n", 1
    )[1]
    code += procedure((FACADE / "runtime_wrappers_parts/backend_status.nim").read_text(),
                      "wifiBackendScanCount")
    code += procedure((RX / "control_events.nim").read_text(), "blRxScanuStartCfm")
    code += (FACADE / "service_futures_parts/completions.nim").read_text()
    code += (FACADE / "service_futures_parts/waits.nim").read_text()
    disconnect = (FACADE / "station_api_parts/disconnect.nim").read_text()
    for name in ["wifiWaitStaIdleAsync", "wifiIssueDisconnectAsync"]:
        code += procedure(disconnect, name)
    code += (FACADE / "service_futures_parts/pending_events.nim").read_text()
    code += (FACADE / "station_api_parts/scan.nim").read_text()
    return code + r'''
proc setup() =
  wifiScanFuture = nil
  wifiConnectFuture = nil
  wifiStaIdleFuture = nil
  wifiDisconnectFuture = nil
  wifiScanTimer = 0
  wifiConnectTimer = 0
  wifiStaIdleTimer = 0
  wifiDisconnectTimer = 0
  wifiDisconnectIssuePending = false
  wifiDisconnectIssueTimeoutMs = 0
  timers.setLen(0)
  scanDone = false
  scanCount = 7
  scanSubmitStatus = 0
  scanConfirmationStatus = 0
  staIface = cast[pointer](1)
  connectDone = false
  connected = false
  idle = false
  disconnected = false
  eventFutures = true
  issueStatus = 0
  issued = 0
'''


CASES = {
    "scan_rejected_before_wait": r'''
for failure in [-12.cint, -16.cint, -22.cint, -110.cint]:
  setup()
  scanSubmitStatus = failure
  let scan = wifiScanAsync(30_000)
  doAssert scan.finished and scan.read() == 0
  doAssert timers.len == 0 and wifiScanFuture == nil
''',
    "scan_confirmation_owns_count": r'''
for scenario in 0..4:
  setup()
  # A canceled or rejected scan can have posted partial results already.
  var reply = ScanConfirmation(length: 1, status: 0)
  if scenario == 1: scanCount = 0
  if scenario == 2: reply.status = 8
  if scenario == 3: reply.length = 0
  let scan = wifiScanAsync(30_000)
  doAssert not scan.finished
  let timer = wifiScanTimer
  discard blRxScanuStartCfm(nil, nil, if scenario == 4: nil else: addr reply)
  doAssert scan.finished and scan.read() == (if scenario == 0: 7'u32 else: 0'u32)
  doAssert timers[timer.int - 1].cancelled and wifiScanFuture == nil
''',
    "scan_observation": r'''
setup()
staIface = nil
doAssert wifiScanAsync(100).read() == 0
doAssert wifiLastScanObservation() == (wifiScanUnavailable, 0'u32)
setup()
scanSubmitStatus = -16
doAssert wifiScanAsync(100).read() == 0
doAssert wifiLastScanObservation() == (wifiScanSubmitRejected, cast[uint32](-16'i32))
setup()
for phase in 0..3:
  var replacement: CpsFuture[uint32]
  var reply = ScanConfirmation(length: 1, status: 0)
  scanCount = 0
  if phase == 1: reply.status = 8
  if phase == 2: reply.length = 0
  let expected = if phase == 3: (wifiScanTimedOut, 0'u32)
                 else: (wifiScanConfirmed, if phase == 2: high(uint32) else: reply.status.uint32)
  let scan = wifiScanAsync(100)
  let timer = wifiScanTimer
  doAssert wifiLastScanObservation() == (wifiScanPending, 0'u32)
  scan.addCallback(proc() =
    doAssert wifiLastScanObservation() == expected
    replacement = wifiScanAsync(100))
  if phase == 3: fire(timer)
  else: discard blRxScanuStartCfm(nil, nil, addr reply)
  doAssert scan.finished and scan.read() == 0
  doAssert replacement != nil and not replacement.finished
  doAssert wifiLastScanObservation() == (wifiScanPending, 0'u32)
  fire(timer)
  doAssert not replacement.finished
  setup()
''',
    "immediate_completion": r'''
for timeout in [0'u32, 100]:
  setup()
  scanDone = true
  let scanned = wifiBeginScanWait(timeout)
  doAssert scanned != nil and scanned.finished and scanned.read() == 7
  doAssert wifiScanFuture == nil and wifiScanTimer == 0
  for timer in timers: doAssert timer.cancelled
  for success in [false, true]:
    setup()
    connectDone = true
    connected = success
    let joined = wifiBeginConnectWait(timeout)
    doAssert joined != nil and joined.finished
    doAssert joined.read() == (if success: wifiOk else: wifiFail)
    doAssert wifiConnectFuture == nil and wifiConnectTimer == 0
    for timer in timers: doAssert timer.cancelled
  setup()
  idle = true
  let stopped = wifiWaitStaIdleAsync(timeout)
  doAssert stopped != nil and stopped.finished and stopped.read() == wifiOk
  setup()
  disconnected = true
  let left = wifiIssueDisconnectAsync(timeout)
  doAssert not left.finished
  wifiCompletePendingEvents()
  doAssert issued == 1 and left.finished and left.read() == wifiOk
  doAssert wifiDisconnectFuture == nil and wifiDisconnectTimer == 0
  doAssert not wifiDisconnectIssuePending
  for timer in timers: doAssert timer.cancelled
''',
    "timeouts_and_fallback": r'''
setup()
let scanned = wifiBeginScanWait(100)
let scanTimer = wifiScanTimer
doAssert not scanned.finished
fire(scanTimer)
doAssert scanned.finished and scanned.read() == 0
doAssert wifiScanFuture == nil and wifiScanTimer == 0
setup()
let joined = wifiBeginConnectWait(100)
fire(wifiConnectTimer)
doAssert joined.finished and joined.read() == wifiFail
setup()
let stopped = wifiWaitStaIdleAsync(100)
fire(wifiStaIdleTimer)
doAssert stopped.finished and stopped.read() == wifiFail
setup()
let left = wifiIssueDisconnectAsync(100)
wifiCompletePendingEvents()
doAssert issued == 1 and not left.finished
fire(wifiDisconnectTimer)
doAssert left.finished and left.read() == wifiFail
doAssert wifiDisconnectFuture == nil and not wifiDisconnectIssuePending
setup()
eventFutures = false
doAssert wifiBeginScanWait(100).read() == 0
doAssert wifiBeginConnectWait(100).read() == wifiFail
connected = true
doAssert wifiBeginConnectWait(100).read() == wifiOk
doAssert wifiIssueDisconnectAsync(100).read() == wifiOk
issueStatus = -1
doAssert wifiIssueDisconnectAsync(100).read() == wifiFail
doAssert timers.len == 0
''',
    "reentrant_completion": r'''
for route in 0 .. 3:
  setup()
  for iteration in 0 ..< 100:
    var replacementScan: CpsFuture[uint32]
    var replacement: CpsFuture[WifiError]
    var oldTimer: TimerId
    var callbacks = 0
    if route == 0:
      let original = wifiBeginScanWait(100)
      oldTimer = wifiScanTimer
      original.addCallback(proc() =
        inc callbacks
        doAssert wifiScanFuture == nil and wifiScanTimer == 0
        doAssert timers[oldTimer.int - 1].cancelled
        replacementScan = wifiBeginScanWait(100))
      completeWifiScan(9)
      doAssert original.finished and original.read() == 9
      doAssert wifiScanFuture == replacementScan and not replacementScan.finished
    else:
      let original = case route
        of 1: wifiBeginConnectWait(100)
        of 2: wifiWaitStaIdleAsync(100)
        else: wifiIssueDisconnectAsync(100)
      wifiCompletePendingEvents()
      oldTimer = case route
        of 1: wifiConnectTimer
        of 2: wifiStaIdleTimer
        else: wifiDisconnectTimer
      original.addCallback(proc() =
        inc callbacks
        doAssert timers[oldTimer.int - 1].cancelled
        case route
        of 1:
          doAssert wifiConnectFuture == nil and wifiConnectTimer == 0
          replacement = wifiBeginConnectWait(100)
        of 2:
          doAssert wifiStaIdleFuture == nil and wifiStaIdleTimer == 0
          replacement = wifiWaitStaIdleAsync(100)
        else:
          doAssert wifiDisconnectFuture == nil and wifiDisconnectTimer == 0
          doAssert not wifiDisconnectIssuePending and wifiDisconnectIssueTimeoutMs == 0
          replacement = wifiIssueDisconnectAsync(100))
      case route
      of 1: completeWifiConnect(wifiOk)
      of 2: completeWifiStaIdle(wifiOk)
      else: completeWifiDisconnect(wifiOk)
      doAssert original.finished and original.read() == wifiOk
      doAssert replacement != nil and not replacement.finished
    doAssert callbacks == 1
    fire(oldTimer)
    if route == 0: doAssert not replacementScan.finished
    else: doAssert not replacement.finished
    setup()
''',
    "cancelled_wait_restart": r'''
for route in 0 .. 3:
  setup()
  if route == 0:
    let original = wifiBeginScanWait(100)
    let oldTimer = wifiScanTimer
    original.cancel()
    let replacement = wifiBeginScanWait(200)
    let newTimer = wifiScanTimer
    doAssert oldTimer != newTimer and original.isCancelled
    fire(oldTimer)
    doAssert not replacement.finished, "retired timeout completed a replacement scan"
    doAssert wifiScanFuture == replacement and wifiScanTimer == newTimer
    fire(newTimer)
    doAssert replacement.finished and replacement.read() == 0
  else:
    let original = case route
      of 1: wifiBeginConnectWait(100)
      of 2: wifiWaitStaIdleAsync(100)
      else: wifiIssueDisconnectAsync(100)
    wifiCompletePendingEvents()
    let oldTimer = case route
      of 1: wifiConnectTimer
      of 2: wifiStaIdleTimer
      else: wifiDisconnectTimer
    original.cancel()
    let replacement = case route
      of 1: wifiBeginConnectWait(200)
      of 2: wifiWaitStaIdleAsync(200)
      else: wifiIssueDisconnectAsync(200)
    wifiCompletePendingEvents()
    let newTimer = case route
      of 1: wifiConnectTimer
      of 2: wifiStaIdleTimer
      else: wifiDisconnectTimer
    doAssert oldTimer != newTimer and original.isCancelled
    fire(oldTimer)
    doAssert not replacement.finished, "retired timeout completed a replacement wait"
    case route
    of 1: doAssert wifiConnectFuture == replacement and wifiConnectTimer == newTimer
    of 2: doAssert wifiStaIdleFuture == replacement and wifiStaIdleTimer == newTimer
    else: doAssert wifiDisconnectFuture == replacement and wifiDisconnectTimer == newTimer
    fire(newTimer)
    doAssert replacement.finished and replacement.read() == wifiFail
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_event_futures(tmp_path: Path, mode: str, case: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "event_futures.nim"
    path.write_text(source() + CASES[case])
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run(
        [nim, "c", "-r", "--mm:arc", "--skipParentCfg:on", "--skipProjCfg:on",
         "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}",
         f"-o:{tmp_path / 'test'}", *flags[mode],
         *(["-d:bl808WifiDiagLinkDrop"] if case == "scan_observation" else []), str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout
