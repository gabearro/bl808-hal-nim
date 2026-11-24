"""Exercise upper scan completion and cache retirement across reentrant hooks."""

from pathlib import Path
import re
import shutil
import subprocess
import textwrap

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  TASK_SCANU = 2'u8
  TASK_API = 9'u8
  SCANU_JOIN_CFM = 0x803'u16
  SCANU_JOIN_REQ = 0x802'u16
  SCANU_START_CFM = 0x801'u16
  SCAN_DONE_IND = 0x402'u16
  StatusCfmPayloadSize = 1'u32
  ScanuIdleState = 0'u8
  ScanuScanningState = 1'u8
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint
  SCANU_MAX_RESULT_ENTRIES = 6
type
  Header = object
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Request = object
    flags: uint32
  StatusCfmPayload = object
    status: uint8
  CacheEntry = object
    cachedRxuMgtInd: pointer
    valid: uint8
    rssi: int8
    ssid, channel: uint32
  CacheSidecar = object
    generation: uint32
  Env = object
    paramPtr, pendingJoinRxuMgtInd: pointer
    bssidFilterEnabled, requester, scanBand: uint8
    entries: array[SCANU_MAX_RESULT_ENTRIES, CacheEntry]
  Response = object
    payload: StatusCfmPayload
    id: uint16
    dest: uint8
    owned: bool
var
  scanu_env, replacementEnv: Env
  request, replacementRequest: Request
  requestHeader: Header
  replayToken: Header
  responses: array[8, Response]
  oldFrames, newFrames: array[SCANU_MAX_RESULT_ENTRIES, uint32]
  freedFrames: array[SCANU_MAX_RESULT_ENTRIES, int]
  sent: seq[tuple[id: uint16, dest, status: uint8]]
  state: uint8
  interruptsEnabled = true
  incoming: bool
  requestFrees, requestTransfers, allocations, sends, advances, replaySends, replayFrees: int
  failMask: int
  hook: proc(point: string)
  isCachedJoin: bool
  cachedEntry: CacheEntry
  cachedSidecar: CacheSidecar
  scanuRequestEpoch: uint32

proc smScanAdmitRequest(p: pointer): bool = true
proc smScanOwnsRequest(p: pointer): bool = false
proc scanuCachedSsidFor(entry: ptr CacheEntry): ptr CacheSidecar =
  doAssert entry == addr cachedEntry
  addr cachedSidecar
proc fire(point: string) =
  if hook != nil: hook(point)
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) =
  interruptsEnabled = (saved and 8) != 0
  if interruptsEnabled: fire("restore")
proc ke_state_set(task, value: uint8) =
  doAssert task == TASK_SCANU
  if not isCachedJoin: doAssert not interruptsEnabled
  state = value
proc statusCfmView(p: pointer): ptr StatusCfmPayload = cast[ptr StatusCfmPayload](p)
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  if p == addr request: addr requestHeader else: cast[ptr Header](p)
proc ke_msg_try_alloc(id: uint16; dest, src: uint8; length: uint32): pointer =
  doAssert interruptsEnabled == incoming
  doAssert src == TASK_SCANU
  inc allocations
  let index = allocations - 1
  doAssert index < responses.len
  if (failMask and (1 shl index)) == 0:
    if id == SCAN_DONE_IND:
      doAssert isCachedJoin and dest == TASK_SCANU and length == 0
      result = addr replayToken
    else:
      doAssert length == 1
      responses[index] = Response(id: id, dest: dest, owned: true)
      result = addr responses[index].payload
  fire("alloc" & $allocations)
proc ke_msg_free(p: pointer) =
  doAssert interruptsEnabled == incoming
  doAssert p == addr requestHeader
  inc requestFrees
  doAssert requestFrees == 1, "old request released twice"
  request.flags = 0xDDDDDDDD'u32
  fire("request_free")
proc smScanCompletionAlloc(request: pointer; id: uint16; destination: uint8): pointer =
  ke_msg_try_alloc(id, destination, TASK_SCANU, StatusCfmPayloadSize)
proc ke_msg_free_payload(p: pointer) =
  if p == nil: return
  doAssert interruptsEnabled == incoming
  if p == addr replayToken:
    inc replayFrees
    doAssert replayFrees == 1 and replaySends == 0
    return
  var found = false
  for i in 0 ..< oldFrames.len:
    if p == addr oldFrames[i]:
      inc freedFrames[i]
      doAssert freedFrames[i] == 1, "old cached frame released twice"
      found = true
      fire("cache" & $i)
      break
  doAssert found, "fresh cache entry was released by the old completion"
proc ke_msg_send(p: pointer) =
  doAssert interruptsEnabled == incoming
  if isCachedJoin:
    if p == addr replayToken:
      doAssert scanu_env.pendingJoinRxuMgtInd == p and replayFrees == 0
      inc replaySends
      return
    doAssert p == addr oldFrames[0]
    doAssert cachedEntry.cachedRxuMgtInd == nil and request.flags == 0,
      "cached-frame handoff preceded owner detachment"
    fire("cached_send")
    return
  if p == addr request:
    doAssert requestFrees == 0 and requestTransfers == 0
    doAssert requestHeader.paramLen == StatusCfmPayloadSize and requestHeader.srcId == TASK_SCANU
    inc requestTransfers
    sent.add((requestHeader.id, requestHeader.destId, statusCfmView(p).status))
    inc sends
    fire("send" & $sends)
    return
  for response in responses.mitems:
    if p == addr response.payload:
      doAssert response.owned
      sent.add((response.id, response.dest, response.payload.status))
      response.owned = false
      inc sends
      fire("send" & $sends)
      # A synchronous consumer may recycle the response immediately.
      response.payload.status = 0xE7
      return
  doAssert false
proc scanuClearCachedSsid(entry: ptr CacheEntry) =
  doAssert not interruptsEnabled
  entry.ssid = 0
proc scanuClearCachedChannel(entry: ptr CacheEntry) =
  doAssert not interruptsEnabled
  entry.channel = 0
proc advanceScanuScanBand() = inc advances
"""

CHECKS = r"""
proc setup(irq: bool; route: string) =
  hook = nil
  incoming = irq
  interruptsEnabled = irq
  scanu_env = default(Env)
  scanuRequestEpoch = 1
  request = Request(flags: 0x12345678)
  requestHeader = Header(paramLen: 324)
  replacementRequest = Request(flags: 0x87654321'u32)
  responses = default(typeof(responses))
  sent.setLen(0)
  freedFrames = default(typeof(freedFrames))
  requestFrees = 0
  requestTransfers = 0
  allocations = 0
  sends = 0
  advances = 0
  replaySends = 0
  replayFrees = 0
  replayToken = Header(id: SCAN_DONE_IND, srcId: TASK_SCANU)
  failMask = 0
  isCachedJoin = false
  state = 7
  scanu_env.paramPtr = addr request
  scanu_env.requester = 5
  scanu_env.bssidFilterEnabled = (route in ["join", "done"]).uint8
  if route in ["done", "clear"]:
    scanu_env.pendingJoinRxuMgtInd = addr replayToken
  if route in ["done", "clear"]:
    for i in 0 ..< scanu_env.entries.len:
      scanu_env.entries[i] = CacheEntry(cachedRxuMgtInd: addr oldFrames[i],
        valid: 1, rssi: -33, ssid: i.uint32 + 1, channel: 2412)

proc installReplacement(reuse: bool) =
  inc scanuRequestEpoch
  scanu_env = Env(paramPtr: (if reuse: addr request else: addr replacementRequest),
    pendingJoinRxuMgtInd: addr newFrames[0], requester: 8,
    bssidFilterEnabled: 1, scanBand: 2)
  for i in 0 ..< scanu_env.entries.len:
    scanu_env.entries[i] = CacheEntry(cachedRxuMgtInd: addr newFrames[i],
      valid: 1, rssi: -17, ssid: 0xA0'u32 + i.uint32, channel: 2462)
  if reuse: request.flags = 0xBADCAB1E'u32
  state = 9
  replacementEnv = scanu_env

for route in ["plain", "join", "done", "clear"]:
  var points = case route
    of "plain": @["restore", "alloc1", "request_free", "send1"]
    of "join": @["restore", "alloc1", "alloc2", "request_free", "send1", "send2"]
    else: @["restore"]
  if route in ["done", "clear"]:
    for i in 0 ..< SCANU_MAX_RESULT_ENTRIES: points.add("cache" & $i)
    if route == "done": points.add(@["alloc1", "request_free", "send1"])
  for irq in [false, true]:
    for trigger in points:
      if trigger == "restore" and not irq: continue
      for recursive in [false, true]:
        setup(irq, route)
        var fired = false
        hook = proc(point: string) =
          if fired or point != trigger: return
          fired = true
          doAssert interruptsEnabled == incoming
          if route != "clear":
            doAssert scanu_env.paramPtr == nil and scanu_env.pendingJoinRxuMgtInd == nil
            doAssert state == 7
          else:
            doAssert scanu_env.pendingJoinRxuMgtInd == addr replayToken,
              "cache clearing changed independent replay ownership"
          if route in ["done", "clear"]:
            for entry in scanu_env.entries:
              doAssert entry.cachedRxuMgtInd == nil and entry.valid == 0
              doAssert entry.rssi == -128 and entry.ssid == 0 and entry.channel == 0
          if recursive and route != "clear":
            # The detached request cannot be confirmed recursively a second time.
            scanu_confirm(99)
            discard scan_done_ind_handler(nil)
            doAssert state == 7 and advances == 0
          installReplacement(trigger == "request_free")
          if trigger.startsWith("cache"):
            let index = ord(trigger[^1]) - ord('0')
            scanu_env.entries[index].cachedRxuMgtInd = addr oldFrames[index]
            replacementEnv = scanu_env
        if route in ["plain", "join"]: scanu_confirm(27)
        elif route == "done": doAssert scan_done_ind_handler(addr replayToken) == KeMsgConsumed
        else: scanu_cached_scanresult_clear()
        hook = nil
        doAssert fired and interruptsEnabled == irq
        doAssert state == 9 and scanu_env == replacementEnv,
          "old completion changed replacement scan state"
        if trigger == "request_free": doAssert request.flags == 0xBADCAB1E'u32
        doAssert requestFrees == (route != "clear").int
        if route in ["done", "clear"]:
          for count in freedFrames: doAssert count == 1
        if route == "plain":
          doAssert sent == @[(SCANU_START_CFM, 5'u8, 27'u8)]
        elif route == "join":
          doAssert sent == @[(SCANU_JOIN_CFM, 5'u8, 27'u8), (SCANU_JOIN_CFM, TASK_API, 27'u8)]
        elif route == "done":
          doAssert sent == @[(SCANU_JOIN_CFM, 5'u8, 0'u8)]
        else: doAssert sent.len == 0
        for response in responses: doAssert not response.owned

# Allocation failures still release or transfer the old request exactly once.
for route in ["plain", "join", "done"]:
  for mask in 0 .. 3:
    for irq in [false, true]:
      setup(irq, route)
      failMask = mask
      if route == "done": discard scan_done_ind_handler(addr replayToken)
      else: scanu_confirm(31)
      let transferred = ((mask and 1) != 0).int
      doAssert requestTransfers == transferred and requestFrees + transferred == 1
      doAssert scanu_env.paramPtr == nil
      doAssert state == ScanuIdleState and interruptsEnabled == irq
      let wanted = if route == "join": 2 else: 1
      doAssert allocations == wanted
      if route == "done":
        doAssert sent == @[(SCANU_JOIN_CFM, 5'u8, 0'u8)]
        for count in freedFrames: doAssert count == 1
      else:
        let primary = if route == "join": SCANU_JOIN_CFM else: SCANU_START_CFM
        doAssert sent[0] == (primary, 5'u8, 31'u8)
        if route == "join" and (mask and 2) == 0:
          doAssert sent == @[(primary, 5'u8, 31'u8), (SCANU_JOIN_CFM, TASK_API, 31'u8)]
        else:
          doAssert sent.len == 1

setup(true, "plain")
failMask = 1
hook = proc(point: string) =
  if point == "send1": installReplacement(false)
scanu_confirm(31)
doAssert state == 9 and scanu_env == replacementEnv
doAssert requestTransfers == 1 and requestFrees == 0

setup(true, "plain")
scanu_env.paramPtr = nil
scanu_confirm(0)
doAssert allocations == 0 and requestFrees == 0 and sent.len == 0
doAssert state == 7
setup(true, "plain")
scanu_env.pendingJoinRxuMgtInd = nil
discard scan_done_ind_handler(nil)
doAssert advances == 0 and allocations == 0 and requestFrees == 0
var lowerRequest, lowerDone: uint8
scanuLower = ScanuLowerExchange(request: addr lowerRequest, epoch: scanuRequestEpoch)
scanuTrackLowerReply(addr lowerRequest, addr lowerDone, done = true)
discard scan_done_ind_handler(addr replayToken)
doAssert advances == 0
discard scan_done_ind_handler(addr lowerDone)
discard scan_done_ind_handler(addr lowerDone)
doAssert advances == 1 and scanu_env.paramPtr == addr request

setup(true, "done")
discard scan_done_ind_handler(nil)
doAssert advances == 0 and allocations == 0 and scanu_env.paramPtr == addr request

for irq in [false, true]:
  setup(irq, "join")
  isCachedJoin = true
  cachedEntry.cachedRxuMgtInd = addr oldFrames[0]
  hook = proc(point: string) =
    if point == "cached_send":
      cachedEntry.cachedRxuMgtInd = addr newFrames[0]
      request.flags = 0xAABBCCDD'u32
  doAssert cachedJoin() == 1
  doAssert cachedEntry.cachedRxuMgtInd == addr newFrames[0]
  doAssert request.flags == 0xAABBCCDD'u32 and replaySends == 1

for failure in ["alloc", "slot_replaced", "request_replaced"]:
  setup(true, "join")
  isCachedJoin = true
  cachedEntry.cachedRxuMgtInd = addr oldFrames[0]
  cachedSidecar.generation = 1
  failMask = (failure == "alloc").int
  hook = proc(point: string) =
    if point == "alloc1":
      if failure == "slot_replaced": inc cachedSidecar.generation
      elif failure == "request_replaced": installReplacement(true)
  let replaced = failure == "request_replaced"
  doAssert cachedJoin() == replaced.cint
  doAssert replaySends == 0 and replayFrees == (failure != "alloc").int
  doAssert cachedEntry.cachedRxuMgtInd == addr oldFrames[0]
  if replaced:
    doAssert state == 9 and scanu_env == replacementEnv
    doAssert request.flags == 0xBADCAB1E'u32
  else:
    doAssert state == 7 and scanu_env.pendingJoinRxuMgtInd == nil
    doAssert request.flags == 0x12345678'u32
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "request_detach", "late_state", "cache_detach",
                                      "partial_cache", "done_detach", "nil_completion", "cached_send", "unlocked"])
def test_scanu_completion(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    scan = (FW / "scan_station_ap_me.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    confirm = procedure(scan, "scanu_confirm").split("\ntype ProbeIeWriter", 1)[0]
    detach = procedure(scan, "scanuDetachCachedScanResults")
    clear = procedure(scan, "scanu_cached_scanresult_clear")
    done = procedure(tasks, "scan_done_ind_handler")
    join = procedure(tasks, "scanu_join_req_handler")
    join = join.split("  if existing != nil:\n", 1)[1].split("  # Start scan", 1)[0]
    cached = ("proc cachedJoin(): cint =\n  let existingEntry = addr cachedEntry\n"
              "  let param = cast[pointer](addr request)\n  let epoch = scanuRequestEpoch\n"
              "  let req = addr request\n" + textwrap.indent(textwrap.dedent(
                  join.replace("    let existingEntry = scanuResultAt(existing)\n", "")), "  ")
              + "  return 0\n")
    if mutation == "request_detach":
        confirm = confirm.replace("    scanu_env.paramPtr = nil\n", "")
    elif mutation == "late_state":
        confirm += "  ke_state_set(TASK_SCANU, ScanuIdleState)\n"
    elif mutation == "cache_detach":
        detach = detach.replace("    scanResultEntry.cachedRxuMgtInd = nil\n", "")
    elif mutation == "partial_cache":
        clear = r"""
proc scanu_cached_scanresult_clear*() {.exportc, cdecl.} =
  for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    var frame: pointer
    block:
      let saved = irqSave()
      frame = scanu_env.entries[i].cachedRxuMgtInd
      scanu_env.entries[i].cachedRxuMgtInd = nil
      irqRestore(saved)
    ke_msg_free_payload(frame)
"""
    elif mutation == "done_detach":
        done = done.replace("      scanu_env.paramPtr = nil\n", "")
    elif mutation == "nil_completion":
        confirm = confirm.replace("    if oldRequest == nil: return\n", "")
    elif mutation == "unlocked":
        confirm = confirm.replace("    let saved = irqSave()\n    defer: irqRestore(saved)\n", "")
    elif mutation == "cached_send":
        old = "        existingEntry.cachedRxuMgtInd = nil\n        req.flags = 0\n"
        assert old in cached
        cached = cached.replace(old, "")
        cached = cached.replace("        ke_msg_send(cachedRxuMgtInd)\n",
            "        ke_msg_send(cachedRxuMgtInd)\n" + old)
    program = tmp_path / "completion.nim"
    layout = (FW / "layout_types.nim").read_text()
    cache_count = int(re.search(r"(?m)^const SCANU_MAX_RESULT_ENTRIES\* = (\d+)$", layout).group(1))
    platform = PLATFORM.replace("SCANU_MAX_RESULT_ENTRIES = 6", f"SCANU_MAX_RESULT_ENTRIES = {cache_count}")
    current = procedure(scan, "scanuRequestCurrent")
    publication = procedure(scan, "scanuReleaseCompletedOwner") + procedure(scan, "scanuPublishCompletion")
    forward = procedure((FW / "kernel_mac_channel.nim").read_text(), "ke_msg_forward_and_change_id")
    from test_wifi_scan_start_confirmation import exchange_source

    program.write_text("import std/strutils\n" + platform + exchange_source() + forward +
                       current + publication + confirm + detach + clear + done + cached + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags[mode], str(program)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
