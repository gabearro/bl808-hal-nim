"""Keep upper scan producers bound to the request that entered each call."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_scan_ie_builder import PLATFORM as BUILDER_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"


def platform_source() -> str:
    source = BUILDER_PLATFORM.replace("type\n", """type
  Header = object
    id: uint16
    srcId: uint8
    paramLen: uint32
  CachedEntry = object
    cachedRxuMgtInd: pointer
  CachedSsid = object
    generation: uint32
  Vif = object
    securityFlags: uint32
""", 1).replace("    scanBand, bssidFilterEnabled: uint8", """
    scanBand, bssidFilterEnabled, resultState, directedFound, requester, joinRetryCount: uint8
    resultCount: uint32
    filterBssid: array[6, uint8]
    probeIeCopyDst, pendingJoinRxuMgtInd: pointer""")
    source = source.replace("proc scanProbeReqIeDataPtr", """
const
  ScanuStartReqPayloadSize = sizeof(ScanuStartReqPayload).uint32
  ScanuIdleState = 0'u8
  ScanuScanningState = 1'u8
  ScanuJoiningState = 2'u8
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  SCAN_STATUS_BUSY = 8'u8
  TASK_SM = 4'u8
  SCANU_START_CFM = 0x801'u16
  StatusCfmPayloadSize = 1'u32
  SCAN_DONE_IND = 0x402'u16
var
  replacementRequest, abandonedRequest: ScanuStartReqPayload
  requestHeader, abandonedHeader: Header
  vifs: array[2, Vif]
  state: uint8
  clears, filterCopies, parentFrees, replaySends, cachedSends: int
  childOwned, cachedAvailable, replayOwned: bool
  cachedEntry: CachedEntry
  cachedSsid: CachedSsid
  cachedPayload: uint32
  replayToken: uint32
  rawProbe: array[4, uint8]
  stage: string
  action: int
  fired: bool
  replacementEnv: ScanEnv
  requestSnapshot: ScanuStartReqPayload
  childSnapshot: ScanStartReqPayload
  ieSnapshot: array[200, uint8]
proc observe(point: string)
proc statusCfmView(p: pointer): ptr tuple[status: uint8] =
  cast[ptr tuple[status: uint8]](p)
proc scanuAnswer(p: pointer; id: uint16; dest, status: uint8) =
  doAssert false, "producer test unexpectedly rejected its scan as busy"
proc scanProbeReqIeDataPtr""", 1)
    replacements = {
        "keMsgHdrFromPayload": r"""
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  if p == addr request: addr requestHeader
  elif p == addr abandonedRequest: addr abandonedHeader
  else: cast[ptr Header](p)
""",
        "ke_msg_try_alloc": r"""
proc ke_msg_try_alloc(id: uint16; dest, source: uint8; length: uint32): pointer =
  doAssert not interruptsEnabled
  if id == SCAN_DONE_IND:
    doAssert dest == TASK_SCANU and source == TASK_SCANU and length == 0
    doAssert not replayOwned
    replayOwned = true
    return addr replayToken
  doAssert id == SCAN_START_REQ and dest == TASK_SCAN and source == TASK_SCANU
  doAssert length == ScanStartReqPayloadSize
  inc allocations
  if not allocatorFails:
    child = default(ScanStartReqPayload)
    childOwned = true
    result = addr child
  observe("alloc")
""",
        "ke_msg_free": r"""
proc ke_msg_free(p: pointer) =
  doAssert not interruptsEnabled
  if p == (addr child):
    doAssert childOwned
    childOwned = false
    inc frees
    child.vifIdx = 0xE7
    childSnapshot = child
    observe("free_child")
  elif p == (addr abandonedHeader) or p == (addr requestHeader):
    inc parentFrees
    observe("free_abandoned")
  else: doAssert false
""",
        "ke_msg_send": r"""
proc ke_msg_send(p: pointer) =
  doAssert not interruptsEnabled
  if p == addr replayToken:
    doAssert replayOwned and scanu_env.pendingJoinRxuMgtInd == p
    replayOwned = false
    inc replaySends
    return
  if p == (addr cachedPayload):
    doAssert cachedEntry.cachedRxuMgtInd == nil and request.flags == 0
    inc cachedSends
    observe("cached_send")
    return
  doAssert p == (addr child) and childOwned
  childOwned = false
  inc sends
  sentBytes = @[]
  for i in 0 ..< child.ieBodyLen.int: sentBytes.add(scan_probe_req_ie.ieData[i])
  child.vifIdx = 0xD3
  childSnapshot = child
  observe("send")
""",
        "scanu_confirm": r"""
proc scanu_confirm(status: uint8) =
  inc confirmations
  lastStatus = status
  inc scanuRequestEpoch
  scanu_env.paramPtr = nil
  state = ScanuIdleState
""",
        "finishAdvancedScanuScanBand": "",
    }
    for name, body in replacements.items():
        source = source.replace(procedure(source, name), body)
    source += r"""
proc scanuStartReqView(p: pointer): ptr ScanuStartReqPayload = cast[ptr ScanuStartReqPayload](p)
proc ke_state_set(task: uint8; value: uint16) =
  doAssert task == TASK_SCANU and not interruptsEnabled
  state = value.uint8
  observe("state")
proc ke_state_get(task: uint8): uint16 =
  doAssert task == TASK_SCANU
  state.uint16
proc cacheScanuFilterSsid(req: ptr ScanuStartReqPayload) = inc filterCopies
proc scanu_cached_scanresult_clear() =
  inc clears
  observe("clear")
{.emit: "#include <stdarg.h>".}
proc retryLog(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil and $file == "scanu.c" and line == 1163
  doAssert $format == "rescan:%s %d \r\n"
  var name: cstring
  var count: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ",
           name, " = va_arg(args, const char*); ",
           count, " = va_arg(args, int); va_end(args);"].}
  doAssert $name == "scanu_scan_next" and count == 1163
  observe("log")
proc getLogFunc(offset: int): pointer =
  doAssert offset == 204
  cast[pointer](retryLog)
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index < 2
  addr vifs[index]
proc vifApConfig(vif: ptr Vif): ptr Vif = vif
proc assert_err(a, b: cstring; line: int) = observe("assert")
proc scanu_search_by_bssid(p: pointer): pointer =
  observe("lookup")
  if cachedAvailable: addr cachedEntry else: nil
proc scanuResultAt(p: pointer): ptr CachedEntry = cast[ptr CachedEntry](p)
proc scanuCachedSsidFor(entry: ptr CachedEntry): ptr CachedSsid =
  doAssert entry == addr cachedEntry
  addr cachedSsid
proc ke_msg_free_payload(p: pointer) =
  doAssert not interruptsEnabled and p == (addr replayToken) and replayOwned
  replayOwned = false
"""
    return source


CHECKS = r"""
proc observe(point: string) =
  if fired or point != stage: return
  fired = true
  doAssert not interruptsEnabled
  if action == 0: return
  if action == 4:
    if point in ["clear", "free_abandoned", "lookup", "cached_send"]: scanu_start()
    else: scanu_scan_next()
    return
  if action == 7:
    doAssert scanu_join_req_handler(addr replacementRequest) == KeMsgConsumed
    return
  if action in [5, 6]:
    inc scanuRequestEpoch
    scanu_env.paramPtr = if action == 5: addr replacementRequest else: addr request
    state = ScanuScanningState
    scanu_start()
    return
  inc scanuRequestEpoch
  if action == 3:
    scanu_env.paramPtr = nil
    state = ScanuIdleState
  else:
    if action == 2:
      request.channelCount = 255
      request.vifIdx = 99
      request.flags = 0xDEADBEEF'u32
      request.bssid = [0xEE'u8, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE]
      scanu_env.paramPtr = addr request
    else:
      scanu_env.paramPtr = addr replacementRequest
    scanu_env.requester = 9
    scanu_env.resultState = 77
    scanu_env.directedFound = 1
    scanu_env.scanBand = 3
    scanu_env.joinRetryCount = 29
    state = 9
  for b in scan_probe_req_ie.ieData.mitems: b = 0xA6
  replacementEnv = scanu_env
  requestSnapshot = request
  ieSnapshot = scan_probe_req_ie.ieData

proc setup(irq: bool; route, point: string) =
  interruptsEnabled = irq
  request = default(ScanuStartReqPayload)
  request.vifIdx = 1
  request.channelCount = 1
  request.channelList[0] = ScanChannelEntry(prim20Freq: 2412, band: 0)
  request.scanType = 1
  request.ssidFilter[0] = 1
  request.ssidFilter[1] = 0x42
  request.bssid = [0x10'u8, 2, 3, 4, 5, 6]
  request.flags = 0x12345678
  rawProbe = [221'u8, 2, 1, 2]
  request.probeReqIe = addr rawProbe[0]
  request.probeReqIeLen = 4
  replacementRequest = request
  abandonedRequest = request
  requestHeader.srcId = 5
  requestHeader.paramLen = ScanuStartReqPayloadSize
  abandonedHeader.srcId = 6
  abandonedHeader.paramLen = ScanuStartReqPayloadSize
  scanu_env = ScanEnv(paramPtr: addr request, requester: 5, resultCount: 17,
    probeIeCopyDst: addr hostIes.ieData[0])
  state = ScanuScanningState
  if route == "handler":
    scanu_env.paramPtr = if point == "free_abandoned": addr abandonedRequest else: nil
    state = ScanuIdleState
  if route in ["join", "cached_join"]:
    scanu_env.paramPtr = nil
    state = ScanuIdleState
  if route == "advanced":
    scanu_env.scanBand = 1
    scanu_env.bssidFilterEnabled = 1
    scanu_env.joinRetryCount = 3
  if route == "error": rawProbe[1] = 5
  allocations = 0
  frees = 0
  sends = 0
  confirmations = 0
  parentFrees = 0
  replaySends = 0
  replayOwned = false
  cachedSends = 0
  clears = 0
  filterCopies = 0
  childOwned = false
  cachedAvailable = route == "cached_join"
  cachedEntry.cachedRxuMgtInd = addr cachedPayload
  allocatorFails = route == "oom"
  scanuRequestEpoch = 1
  scanuProducerRequest = nil
  scanuProducerEpoch = 0
  for i in 0 ..< hostIes.ieData.len: hostIes.ieData[i] = 0
  for i in 0 .. 3: hostIes.ieData[i] = rawProbe[i]
  for b in scan_probe_req_ie.ieData.mitems: b = 0xCC
  for i in 0 ..< mac_id2rate.len: mac_id2rate[i] = (0x10 + i).uint8
  me.htSupp = 0
  stage = point
  fired = false

proc run(route: string): cint =
  case route
  of "start": scanu_start()
  of "handler": return scanu_start_req_handler(addr request)
  of "join", "cached_join": return scanu_join_req_handler(addr request)
  else: scanu_scan_next()
  -1

for irq in [false, true]:
  for route in ["next", "start", "handler", "advanced", "error", "oom", "join", "cached_join"]:
    let points = case route
      of "start": @["clear", "state", "alloc", "send"]
      of "handler": @["free_abandoned", "clear", "alloc", "send"]
      of "advanced": @["log"]
      of "error": @["free_child"]
      of "oom": @["alloc"]
      of "join": @["lookup", "alloc", "send"]
      of "cached_join": @["lookup", "cached_send"]
      else: @["alloc", "send"]
    for point in points:
      for change in 0 .. 3:
        setup(irq, route, point)
        action = change
        let rc = run(route)
        doAssert fired and interruptsEnabled == irq
        if route in ["handler", "join", "cached_join"]: doAssert rc == KeMsgNoFree
        if change != 0:
          doAssert scanu_env == replacementEnv and request == requestSnapshot
          doAssert scan_probe_req_ie.ieData == ieSnapshot
          doAssert state == (if change == 3: ScanuIdleState else: 9'u8)
          doAssert confirmations == 0, "stale producer confirmed the replacement"
          if point in ["clear", "state", "lookup", "log", "free_abandoned", "cached_send"]:
            doAssert allocations == 0
          if point == "alloc" and route != "oom": doAssert frees == 1
          if point in ["send", "free_child", "alloc"] and route != "oom":
            doAssert child == childSnapshot, "stale producer modified a consumed child"
          if point == "cached_send": doAssert replaySends == 0 and not replayOwned
        else:
          if route in ["next", "start", "handler", "join"]:
            doAssert sends == 1 and allocations == 1 and confirmations == 0
            doAssert not childOwned
          elif route == "cached_join": doAssert cachedSends == 1 and replaySends == 1 and not replayOwned
          elif route == "advanced":
            doAssert scanu_env.joinRetryCount == 2 and scanu_env.resultState == 1
            doAssert scanu_env.scanBand == 0 and scanu_env.bssidFilterEnabled == 1
            doAssert sends == 1 and allocations == 1 and confirmations == 0
          elif route == "error": doAssert confirmations == 1 and lastStatus == SCAN_STATUS_BAD_PARAM
          elif route == "oom": doAssert confirmations == 1 and lastStatus == SCAN_STATUS_FAIL
        if not childOwned and (sends != 0 or frees != 0): doAssert child == childSnapshot

# Bounds are checked before the first channel-table access or allocation.
for route in ["handler", "join"]:
  for length in [0'u32, ScanuStartReqPayloadSize - 1]:
    setup(true, route, "")
    requestHeader.paramLen = length
    let before = scanu_env
    doAssert run(route) == KeMsgConsumed
    doAssert scanu_env == before and state == ScanuIdleState
    doAssert allocations == 0 and sends == 0 and confirmations == 0
    doAssert interruptsEnabled
for invalid in 1 .. 5:
  setup(true, "next", "")
  case invalid
  of 1: request.channelCount = 43
  of 2: request.channelCount = 255
  of 3: request.scanType = 2
  of 4: request.ssidFilter[0] = 33
  else: request.vifIdx = 2
  scanu_scan_next()
  doAssert allocations == 0 and confirmations == 1 and lastStatus == SCAN_STATUS_BAD_PARAM
  doAssert interruptsEnabled
setup(true, "next", "")
request.channelCount = 0
scanu_scan_next()
doAssert allocations == 0 and sends == 0 and confirmations == 1 and lastStatus == 0
doAssert interruptsEnabled
setup(true, "next", "")
request.scanType = 0
request.ssidFilter[0] = 255 # Unused SSID storage is not validated or transmitted.
scanu_scan_next()
doAssert sends == 1 and confirmations == 0
setup(true, "next", "")
request.channelCount = request.channelList.len.uint8
for channel in request.channelList.mitems: channel = ScanChannelEntry(prim20Freq: 2412, band: 0)
request.ssidFilter[0] = 32
scanu_scan_next()
doAssert sends == 1 and child.channelCount == 42 and confirmations == 0
doAssert child.channelList == request.channelList and child.ssidFilter == request.ssidFilter
for found in [false, true]:
  setup(true, "advanced", "")
  if found: scanu_env.directedFound = 1
  else: scanu_env.joinRetryCount = 0
  scanu_scan_next()
  doAssert allocations == 0 and sends == 0 and confirmations == 1
  doAssert lastStatus == 0 and scanu_env.scanBand == 1
  doAssert interruptsEnabled
setup(true, "next", "")
let firstEpoch = cacheScanuStartRequest(addr request, addr request, 5)
doAssert firstEpoch == 2 and scanuRequestCurrent(addr request, firstEpoch)
let secondEpoch = cacheScanuStartRequest(addr request, addr request, 5)
doAssert secondEpoch == firstEpoch + 1
doAssert not scanuRequestCurrent(addr request, firstEpoch)
setup(true, "join", "")
request.vifIdx = 2
doAssert scanu_join_req_handler(addr request) == KeMsgConsumed
doAssert allocations == 0 and scanu_env.paramPtr == nil and state == ScanuIdleState
setup(true, "join", "")
request.bssid[0] = 1
doAssert scanu_join_req_handler(addr request) == KeMsgNoFree
doAssert allocations == 0 and confirmations == 1 and lastStatus == SCAN_STATUS_BAD_PARAM
for (route, point) in [("start", "clear"), ("start", "state"), ("next", "alloc"), ("advanced", "log"),
                       ("handler", "free_abandoned"), ("join", "lookup"), ("cached_join", "cached_send")]:
  setup(true, route, point)
  action = 4
  discard run(route)
  if route == "advanced": doAssert scanu_env.joinRetryCount == 2
  elif route == "cached_join": doAssert allocations == 0 and cachedSends == 1
  else: doAssert allocations == 1 and sends == 1
for change in [5, 6]:
  setup(true, "start", "clear")
  action = change
  scanu_start()
  doAssert fired and allocations == 1 and sends == 1
  doAssert scanu_env.paramPtr == (if change == 5: addr replacementRequest else: addr request)
  doAssert state == ScanuScanningState and scanuProducerRequest == nil
setup(true, "join", "lookup")
action = 7
doAssert scanu_join_req_handler(addr request) == KeMsgNoFree
doAssert fired and scanu_env.paramPtr == (addr request) and allocations == 1
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "allocation", "next", "reset", "retry", "start",
                                      "state_transition", "failure", "install", "join", "bounds", "reentrant"])
def test_scanu_producer_lifetime(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    scan = (FW / "scan_station_ap_me.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    writer = "type ProbeIeWriter = object" + scan.split("type ProbeIeWriter = object", 1)[1].split("\nproc ", 1)[0] + "\n"
    functions = writer + "".join(procedure(scan, name) for name in [
        "scanuRequestCurrent", "scanChannelValid", "reserveProbeIeBytes", "cursor", "appendByte", "appendIeHeader",
        "skip", "appendDsParamPlaceholder", "appendBytes", "probeIesValid", "appendHtCapabilities",
        "macId2RatePtr", "appendSupportedRates", "finishScanStartReq", "sendScanStartReq",
        "initScanStartReq", "appendScanBandChannel", "copyScanBandChannels", "firstScanBandChannel",
        "clampedProbeReqIeLen", "supportedRateStart", "appendScanSupportedRates", "appendScanHtCapabilities",
        "allocScanStartReq", "allocInitializedScanStartReq", "copyScanSsidFilterIfPresent",
        "resetUndirectedScanuStart", "finishAdvancedScanuScanBand", "scanu_start", "scanu_scan_next",
    ])
    functions = "proc scanu_scan_next*() {.exportc, cdecl.}\n" + functions
    functions += "".join(procedure(tasks, name) for name in [
        "cacheScanuStartRequest", "scanu_start_req_handler", "scanu_join_req_handler",
    ])
    if mutation == "reentrant":
        functions = re.sub(r"  if scanuProducerRequest == scanParam and scanuProducerEpoch == epoch:\n    return\n", "", functions)
    target = {
        "allocation": "allocInitializedScanStartReq", "next": "scanu_scan_next",
        "reset": "resetUndirectedScanuStart", "retry": "finishAdvancedScanuScanBand",
        "start": "scanu_start", "state_transition": "scanu_start",
        "failure": "sendScanStartReq", "install": "cacheScanuStartRequest",
        "join": "scanu_join_req_handler", "bounds": "scanu_scan_next",
    }.get(mutation)
    if target:
        body = procedure(tasks if target in ["cacheScanuStartRequest", "scanu_join_req_handler"] else scan, target)
        changed = body
        if mutation == "allocation":
            changed = re.sub(r"  if not scanuRequestCurrent\(cast\[pointer\]\(req\), epoch\):\n(?:    .*\n)+", "", body)
        elif mutation in ["next", "start", "reset", "retry"]:
            changed = re.sub(r"(?m)^ +if not scanuRequestCurrent\(scanParam, epoch\):\n +return(?: false)?\n", "", body)
        elif mutation == "state_transition":
            changed = body.replace(
                "  ke_state_set(TASK_SCANU, ScanuScanningState)\n"
                "  if not scanuRequestCurrent(scanParam, epoch):\n    return\n",
                "  ke_state_set(TASK_SCANU, ScanuScanningState)\n")
        elif mutation == "failure":
            changed = body.replace("    if scanuRequestCurrent(owner, epoch):\n      scanu_confirm", "    scanu_confirm")
        elif mutation == "install":
            changed = body.replace("    inc scanuRequestEpoch\n", "")
        elif mutation == "join":
            changed = body.replace("  if scanuRequestCurrent(param, epoch):\n    ke_state_set", "  ke_state_set")
        elif mutation == "bounds":
            start = body.index("  if numChannels.int > scanReq.channelList.len")
            end = body.index("  var scanBand", start)
            changed = body[:start] + body[end:]
        assert changed != body, mutation
        functions = functions.replace(body, changed)
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["ScanChannelEntry", "ScanSsidSlotView", "ScanStartReqPayload", "ScanuStartReqPayload", "MacIeView"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n", 1)[0] + "\n"
    debug = "\nvar\n" + "".join(f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions))))
    program = tmp_path / "producer.nim"
    from test_wifi_scan_start_confirmation import exchange_source

    program.write_text(types + platform_source() + exchange_source() + debug + functions + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags[mode], str(program)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(marker in result.stdout for marker in
            ["AssertionDefect", "IndexDefect", "AddressSanitizer"]), result.stdout
