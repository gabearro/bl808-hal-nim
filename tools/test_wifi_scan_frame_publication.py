"""Exercise cached scan-frame ownership across free/allocation callbacks."""

from pathlib import Path
import textwrap

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const SCANU_MAX_RESULT_ENTRIES = 6
type Env = object
  entries: array[SCANU_MAX_RESULT_ENTRIES, ScanuResultEntry]
  paramPtr, pendingJoinRxuMgtInd: pointer
  resultCount: uint16
var
  scanu_env: Env
  scanuCachedSsids: array[SCANU_MAX_RESULT_ENTRIES, ScanuCachedSsid]
  scanuRequestEpoch: uint32
  scan_env: tuple[abortFlag: uint8]
  nimFwDbgScanFrameAccepted, nimFwDbgScanFrameLast: uint32
  incoming, oldFrame, copyFrame, replacementFrame: array[192, uint8]
  request, replacementRequest: uint32
  oldLive, copyLive, replacementLive, allocationFails, enabled: bool
  allocations, oldFrees, copyFrees, forwarded: int
  hook: proc(point: string)
  smOwn: tuple[op: Op]
proc fire(point: string) =
  if hook != nil: hook(point)
proc irqSave(): uint32 =
  result = enabled.uint32 * 8
  enabled = false
proc irqRestore(saved: uint32) = enabled = (saved and 8) != 0
proc rxuMgtIndAt(p: pointer): ptr RxuMgtIndView = cast[ptr RxuMgtIndView](p)
proc scanuCachedSsidFor(entry: ptr ScanuResultEntry): ptr ScanuCachedSsid =
  for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    if entry == addr scanu_env.entries[i]: return addr scanuCachedSsids[i]
proc c_memcpy(dest, source: pointer; size: csize_t): pointer =
  doAssert dest == (addr copyFrame[0]) and source == (addr incoming[0])
  doAssert copyLive and size == 92
  doAssert scanu_env.entries[0].cachedRxuMgtInd != dest
  doAssert scanu_env.pendingJoinRxuMgtInd != dest
  copyMem(dest, source, size.int)
  dest
proc ke_msg_free_payload(p: pointer) =
  if p == nil: return
  if p == addr oldFrame[0]:
    doAssert oldLive
    oldLive = false
    inc oldFrees
    fire("free")
  elif p == addr copyFrame[0]:
    doAssert copyLive
    copyLive = false
    inc copyFrees
  else:
    doAssert false, "released a replacement owned by another publication"
proc ke_msg_try_alloc(id: uint16; dst, src: uint8; size: uint32): pointer =
  doAssert id == 0x1C00 and dst == 2 and src == 2 and size == 92
  inc allocations
  if not allocationFails:
    doAssert not copyLive
    copyLive = true
    result = addr copyFrame[0]
  fire("alloc")
proc ke_msg_forward_and_change_id(p: pointer; id: uint16; dst, src: uint8) =
  doAssert p == (addr incoming[0]) and id == 0x804 and dst == 9 and src == 2
  inc forwarded
  doAssert forwarded == 1
  fire("forward")
proc setup(hasOld = true) =
  hook = nil
  discard opGo(smOwn.op)
  enabled = true
  scanu_env = default(Env)
  scanuCachedSsids = default(typeof(scanuCachedSsids))
  scanuRequestEpoch = 7
  scanu_env.paramPtr = addr request
  scanu_env.entries[0] = ScanuResultEntry(valid: 1, rssi: -30)
  scanuCachedSsids[0].generation = 9
  oldLive = hasOld
  copyLive = false
  replacementLive = false
  allocationFails = false
  allocations = 0
  oldFrees = 0
  copyFrees = 0
  forwarded = 0
  nimFwDbgScanFrameAccepted = 0
  nimFwDbgScanFrameLast = 0
  scan_env.abortFlag = 0
  for i in 0 ..< 92: incoming[i] = (i mod 251).uint8
  rxuMgtIndAt(addr incoming[0]).frameLen = 60
  if hasOld:
    scanu_env.entries[0].cachedRxuMgtInd = addr oldFrame[0]
proc replacePublication(action: int) =
  if action == 0: scanu_env.paramPtr = addr replacementRequest
  elif action == 1: inc scanuRequestEpoch
  elif action == 2: inc scanuCachedSsids[0].generation
  scanu_env.entries[0] = ScanuResultEntry(valid: 1, rssi: -11,
    cachedRxuMgtInd: addr replacementFrame[0])
  scanu_env.entries[0].bssid[0] = 8
  scanu_env.pendingJoinRxuMgtInd = addr replacementFrame[0]
  scanu_env.resultCount = 73
  replacementLive = true
'''


def source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = layouts("ScanuResultEntry", "ScanuCachedSsid", "RxuMgtIndView")
    code += (FW / "op.nim").read_text() + PLATFORM
    code += procedure(scan, "scanuRequestCurrent")
    if "proc scanuPublishFrameResult(" in scan:
        code += procedure(scan, "scanuPublishFrameResult").split("\n{.emit:", 1)[0]
    else:
        tail = procedure(scan, "scanu_frame_handler").split("  # Update result count and mark valid\n", 1)[1]
        code += r'''
proc scanuPublishFrameResult(frame: pointer; scanResultEntry: ptr ScanuResultEntry;
    request: pointer; epoch, generation: uint32; numSsids, bfOn: uint8) =
  let totalLen = rxuMgtIndAt(frame).frameLen
''' + textwrap.indent(textwrap.dedent(tail), "  ")
    return code + r'''
proc publish(bfOn = 0'u8; numSsids = 1'u8) =
  scanuPublishFrameResult(addr incoming[0], 60, 92, addr scanu_env.entries[0],
    addr request, 7, 9, numSsids, bfOn)
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_callbacks_preserve_replacement_publication(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for point in ["free", "alloc"]:
  for action in 0 .. 3:
    for fail in [false, true]:
      setup()
      allocationFails = fail
      var replaced = false
      var expected: Env
      hook = proc(at: string) =
        if at != point or replaced: return
        replaced = true
        replacePublication(action)
        expected = scanu_env
      publish()
      doAssert replaced and scanu_env == expected, "old publisher changed replacement at " & point
      doAssert forwarded == 1 and oldFrees == 1 and replacementLive
      doAssert allocations == (if point == "alloc": 1 else: 0)
      doAssert copyFrees == (if point == "alloc" and not fail: 1 else: 0) and not copyLive
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_retired_context_does_not_publish(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for action in 0 .. 2:
  setup()
  replacePublication(action)
  let expected = scanu_env
  publish()
  doAssert scanu_env == expected
  doAssert allocations == 0 and oldFrees == 0 and copyFrees == 0
  doAssert forwarded == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_success_failure_and_forwarding(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for bfOn in [0'u8, 1'u8]:
  for hasOld in [false, true]:
    for fail in [false, true]:
      for irq in [false, true]:
        setup(hasOld)
        enabled = irq
        allocationFails = fail
        publish(bfOn)
        let keepsOld = bfOn != 0 and hasOld
        doAssert forwarded == 1 and enabled == irq
        doAssert oldFrees == (hasOld and not keepsOld).int
        doAssert allocations == (not keepsOld).int and copyFrees == 0
        if keepsOld:
          doAssert scanu_env.entries[0].cachedRxuMgtInd == addr oldFrame[0]
        elif fail:
          doAssert scanu_env.entries[0].cachedRxuMgtInd == nil and not copyLive
        else:
          doAssert copyLive and scanu_env.entries[0].cachedRxuMgtInd == addr copyFrame[0]
          for i in 0 ..< 92: doAssert copyFrame[i] == incoming[i]
        doAssert scanu_env.pendingJoinRxuMgtInd == nil,
          "a live observation was mistaken for queued replay completion"
setup(false)
scanu_env.entries[0].valid = 0
publish(numSsids = 0)
doAssert scanu_env.entries[0].valid == 0 and scanu_env.resultCount == 1
doAssert allocations == 0 and forwarded == 1
setup(false)
scanu_env.entries[0].valid = 0
scan_env.abortFlag = 1
publish(numSsids = 0)
doAssert scanu_env.entries[0].valid == 0 and scanu_env.resultCount == 1
doAssert allocations == 0 and forwarded == 1
setup()
hook = proc(at: string) =
  if at == "forward": replacePublication(2)
publish()
doAssert scanu_env.entries[0].cachedRxuMgtInd == addr replacementFrame[0]
doAssert scanu_env.resultCount == 73 and replacementLive
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_directed_connection_changes_during_allocation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for point in ["free", "alloc"]:
  setup()
  let stamp = smOwn.op.serial
  var fired = false
  hook = proc(at: string) =
    if at == point and not fired:
      fired = true
      discard opGo(smOwn.op)  # SM moved on
  scanuPublishFrameResult(addr incoming[0], 60, 92, addr scanu_env.entries[0],
    addr request, 7, 9, 1, 0, stamp)
  doAssert fired and not copyLive and forwarded == 1
  doAssert scanu_env.entries[0].cachedRxuMgtInd == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_cached_length_uses_admitted_snapshot(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for point in ["free", "alloc"]:
  setup()
  hook = proc(at: string) =
    if at == point:
      rxuMgtIndAt(addr incoming[0]).frameLen =
        if point == "free": 65535'u16 else: 0'u16
  publish()
  doAssert forwarded == 1 and allocations == 1 and oldFrees == 1
  doAssert scanu_env.entries[0].cachedRxuMgtInd == addr copyFrame[0]
  doAssert rxuMgtIndAt(addr copyFrame[0]).frameLen == 60
  for i in 2 ..< 92: doAssert copyFrame[i] == incoming[i]

for frameLength in [35'u16, 61, 65535]:
  setup()
  scanuPublishFrameResult(addr incoming[0], frameLength, 92,
    addr scanu_env.entries[0], addr request, 7, 9, 1, 0)
  doAssert forwarded == 1 and allocations == 0 and oldFrees == 0
  doAssert scanu_env.entries[0].cachedRxuMgtInd == addr oldFrame[0]
setup()
scanuPublishFrameResult(addr incoming[0], 60, 31,
  addr scanu_env.entries[0], addr request, 7, 9, 1, 0)
doAssert forwarded == 1 and allocations == 0 and oldFrees == 0
setup()
scanuPublishFrameResult(nil, 60, 92,
  addr scanu_env.entries[0], addr request, 7, 9, 1, 0)
doAssert forwarded == 0 and allocations == 0 and oldFrees == 0
''')
