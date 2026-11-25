"""Exercise SCANU's completion (scanuComplete) and cache retirement.

The completion detaches the request before its callouts and ends in
scanuGo(0). The hooks that installed a replacement request from inside an
allocation, a send or a free are gone with the guard they exercised: none of
those calls runs SCANU code (the firmware step is not reentered)."""

from pathlib import Path
import re
import shutil
import subprocess
import textwrap

import pytest

from test_wifi_disconnect_tx import procedure, scan_machine_source

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  TASK_SCANU = 2'u8
  TASK_SM = 4'u8
  TASK_API = 9'u8
  SCANU_JOIN_CFM = 0x803'u16
  SCANU_JOIN_REQ = 0x802'u16
  SCANU_START_CFM = 0x801'u16
  SCAN_DONE_IND = 0x402'u16
  StatusCfmPayloadSize = 1'u32
  ScanuIdleState = 0'u16
  ScanuScanningState = 1'u16
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
proc ke_state_set(task: uint8; value: uint16) =
  doAssert task == TASK_SCANU
  state = value.uint8
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
proc scanu_scan_next() = inc advances
"""

CHECKS = r"""
proc setup(irq: bool; route: string) =
  hook = nil
  incoming = irq
  interruptsEnabled = irq
  scanu_env = default(Env)
  discard scanuGo(ScanuScanningState)
  request = Request(flags: 0x12345678)
  requestHeader = Header(paramLen: 324)
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
    for i in 0 ..< scanu_env.entries.len:
      scanu_env.entries[i] = CacheEntry(cachedRxuMgtInd: addr oldFrames[i],
        valid: 1, rssi: -33, ssid: i.uint32 + 1, channel: 2412)

# Each cached frame is freed once, after every entry was detached; the
# replay's notice is not the cache's to release.
for irq in [false, true]:
  for index in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    setup(irq, "clear")
    var fired = false
    hook = proc(point: string) =
      if fired or point != "cache" & $index: return
      fired = true
      doAssert scanu_env.pendingJoinRxuMgtInd == addr replayToken,
        "cache clearing changed independent replay ownership"
      for entry in scanu_env.entries:
        doAssert entry.cachedRxuMgtInd == nil and entry.valid == 0
        doAssert entry.rssi == -128 and entry.ssid == 0 and entry.channel == 0
    scanu_cached_scanresult_clear()
    doAssert fired and interruptsEnabled == irq
    for count in freedFrames: doAssert count == 1
    doAssert sent.len == 0 and requestFrees == 0

# Allocation failures still release or transfer the old request exactly once.
for route in ["plain", "join", "done"]:
  for mask in 0 .. 3:
    for irq in [false, true]:
      setup(irq, route)
      failMask = mask
      let stamp = scanuOwn.op.serial
      if route == "done": discard scan_done_ind_handler(addr replayToken)
      else: scanu_confirm(31)
      let transferred = ((mask and 1) != 0).int
      doAssert requestTransfers == transferred and requestFrees + transferred == 1
      doAssert scanu_env.paramPtr == nil and scanu_env.pendingJoinRxuMgtInd == nil
      doAssert state == ScanuIdleState and interruptsEnabled == irq
      doAssert not opCurrent(scanuOwn.op, stamp), "the completed request's stamp is still live"
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
      # Nothing is left to complete.
      scanu_confirm(9)
      doAssert sent.len <= 2 and requestFrees + requestTransfers == 1

setup(true, "plain")
scanu_env.paramPtr = nil
scanu_confirm(0)
doAssert allocations == 0 and requestFrees == 0 and sent.len == 0
doAssert state == 7

# SCAN_DONE_IND: only the replay's own notice ends a join; only the lower
# request SCANU waits on, answered in place, ends a band.
setup(true, "plain")
discard scan_done_ind_handler(nil)
discard scan_done_ind_handler(addr replayToken)
doAssert advances == 0 and allocations == 0 and requestFrees == 0
var lowerDone: uint8
scanuOwn.lower = addr lowerDone     # scanuSendLower's record of the sent request
discard scan_done_ind_handler(addr lowerDone)
discard scan_done_ind_handler(addr lowerDone)
doAssert advances == 1 and scanu_env.paramPtr == (addr request) and scanuOwn.lower == nil
doAssert scanu_env.scanBand == 1

for irq in [false, true]:
  setup(irq, "join")
  isCachedJoin = true
  cachedEntry.cachedRxuMgtInd = addr oldFrames[0]
  doAssert cachedJoin() == 1
  doAssert cachedEntry.cachedRxuMgtInd == nil and request.flags == 0
  doAssert replaySends == 1 and scanu_env.pendingJoinRxuMgtInd == addr replayToken

setup(true, "join")
isCachedJoin = true
cachedEntry.cachedRxuMgtInd = addr oldFrames[0]
failMask = 1
doAssert cachedJoin() == 0, "a join without its replay notice did not fall back to scanning"
doAssert replaySends == 0 and replayFrees == 0
doAssert cachedEntry.cachedRxuMgtInd == addr oldFrames[0]
doAssert scanu_env.pendingJoinRxuMgtInd == nil and request.flags == 0x12345678'u32
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "request_detach", "complete_state", "cache_detach",
                                      "partial_cache", "nil_completion", "cached_send"])
def test_scanu_completion(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    scan = (FW / "scan_station_ap_me.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    machine = scan_machine_source("scanuGo", "scanuAwaits", "scanuTakeLower",
                                  "scanuAnswer", "scanuReply", "scanuPublishCompletion",
                                  "scanuComplete", "scanu_confirm", record=False)
    detach = procedure(scan, "scanuDetachCachedScanResults")
    clear = procedure(scan, "scanu_cached_scanresult_clear")
    done = procedure(tasks, "scan_done_ind_handler")
    join = procedure(tasks, "scanu_join_req_handler")
    join = join.split("  if existing != nil:\n", 1)[1].split("  # Start scan", 1)[0]
    cached = ("proc cachedJoin(): cint =\n  let existingEntry = addr cachedEntry\n"
              "  let req = addr request\n" + textwrap.indent(textwrap.dedent(
                  join.replace("    let existingEntry = scanuResultAt(existing)\n", "")), "  ")
              + "  return 0\n")
    if mutation == "request_detach":
        assert "  scanu_env.paramPtr = nil\n" in machine
        machine = machine.replace("  scanu_env.paramPtr = nil\n", "", 1)
    elif mutation == "complete_state":
        old = "  scanuGo(ScanuIdleState)\n\nproc scanu_confirm"
        assert old in machine
        machine = machine.replace(old, "\nproc scanu_confirm", 1)
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
    elif mutation == "nil_completion":
        assert "  if request == nil: return\n" in machine
        machine = machine.replace("  if request == nil: return\n", "", 1)
    elif mutation == "cached_send":
        old = "      existingEntry.cachedRxuMgtInd = nil\n      req.flags = 0\n"
        assert old in cached
        cached = cached.replace(old, "")
        cached = cached.replace("      ke_msg_send(cachedRxuMgtInd)\n",
            "      ke_msg_send(cachedRxuMgtInd)\n" + old)
    program = tmp_path / "completion.nim"
    layout = (FW / "layout_types.nim").read_text()
    cache_count = int(re.search(r"(?m)^const SCANU_MAX_RESULT_ENTRIES\* = (\d+)$", layout).group(1))
    platform = PLATFORM.replace("SCANU_MAX_RESULT_ENTRIES = 6", f"SCANU_MAX_RESULT_ENTRIES = {cache_count}")
    forward = procedure((FW / "kernel_mac_channel.nim").read_text(), "ke_msg_forward_and_change_id")
    record = (FW / "op.nim").read_text() + scan_machine_source()
    program.write_text("import std/strutils\n" + platform + record + forward
                       + "proc scanu_cached_scanresult_clear*() {.exportc, cdecl.}\n"
                       + machine + detach + clear + done + cached + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags[mode], str(program)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
