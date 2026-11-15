"""Exercise postponed-frame retirement with reusable private pool slots."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_frame_allocation import PLATFORM as ALLOCATION_PLATFORM
from test_wifi_frame_ownership import STA_QUEUE_STUBS

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = ALLOCATION_PLATFORM.replace(STA_QUEUE_STUBS, "") + r"""
proc sta_mgmt_aging_postponed_desc(sta: pointer; maxCount: uint32): uint32 = 0
"""

CHECKS = r"""
var
  originals: array[4, ptr HostTxDescView]
  seen: array[4, int]
  fresh: seq[ptr HostTxDescView]
  callbackCount, mode: int
  firstCallback, incomingIrq: bool

proc addFresh() =
  let d = hostTxDescAt(txl_frame_get(24))
  doAssert d != nil
  d.vifIdx = stas[0].instNbr
  d.staInfoIdx = 0
  d.postponeFlag = 1
  d.pendingMacTime = macTime
  co_list_push_back(addr stas[0].postponedList, addr d.link)
  inc frameEnv.postponedCount
  fresh.add(d)

proc onRelease(argument: pointer; status: uint32) {.cdecl.} =
  doAssert status == 0 and interruptsEnabled == incomingIrq
  var index = -1
  for i in 0 .. 2:
    if argument == cast[pointer](originals[i]): index = i
  doAssert index >= 0
  inc seen[index]
  inc callbackCount
  doAssert seen[index] == 1, "original lease released twice"
  doAssert frameEnv.postponedCount == (3 - callbackCount + fresh.len).uint32,
    "callback saw stale postponed accounting"
  doAssert txActiveFlush != nil and txActiveFlush.previous != nil
  if not firstCallback: return
  firstCallback = false
  # No original frame remains on the public queue across a callback.
  doAssert stas[0].postponedList.first == nil
  case mode
  of 0: addFresh()
  of 1:
    addFresh()
    doAssert sta_mgmt_postponed_desc_release(addr stas[0], 0) == 0,
      "nested aging consumed fresh or outer-owned work"
  of 2:
    inc stationEpochs[0]
    var batch = txActiveFlush
    while batch != nil:
      if txlQueueReferencesStation(addr batch.postponed, 0):
        txlDrainRetiredPostponed(addr batch.postponed)
      batch = batch.previous
    doAssert callbackCount == 3 and frameEnv.postponedCount == 0
    # Reuse every released physical slot for the replacement station.
    for i in 0 .. 2: addFresh()
  of 3:
    inc rxVifEpochs[0]
    addFresh()
  of 5:
    stas[0].instNbr = 1
    addFresh()
  of 6:
    inc stationEpochs[0]
    addFresh()
  of 7:
    addFresh()
    let node = co_list_pop_front(addr stas[0].postponedList)
    # The vendor pop API leaves last stale when first becomes nil.
    stas[0].postponedList.last = node
    dec frameEnv.postponedCount
    fresh.setLen(0)
    txl_frame_release(node, false)
  else:
    macTime += 30

proc setup(pattern: int; irq: bool) =
  initPool()
  incomingIrq = irq
  interruptsEnabled = irq
  callbackCount = 0
  firstCallback = true
  seen = default(typeof(seen))
  fresh.setLen(0)
  doAssert txActiveFlush == nil
  stas[0].instNbr = 0
  stas[0].valid = 1
  macTime = 120001
  for i in 0 .. 3:
    originals[i] = hostTxDescAt(txl_frame_get(24))
    doAssert originals[i] != nil
    originals[i].vifIdx = 0
    originals[i].staInfoIdx = 0
  for i in 0 .. 2:
    let d = originals[i]
    d.callback = cast[pointer](onRelease)
    d.callbackArg = d
    d.postponeFlag = 1
    d.pendingMacTime = case pattern
      of 0: 0'u32
      of 1: (if i == 1: 0'u32 else: macTime)
      else: (i * 10).uint32
    co_list_push_back(addr stas[0].postponedList, addr d.link)
  frameEnv.postponedCount = 3

for irq in [false, true]:
  for forced in [false, true]:
    for pattern in 0 .. 2:
      for action in 0 .. 7:
        setup(pattern, irq)
        mode = action
        let released = sta_mgmt_postponed_desc_release(addr stas[0], forced.uint32)
        doAssert interruptsEnabled == irq and txActiveFlush == nil
        if action == 2:
          doAssert released == 1 and callbackCount == 3
        elif action in [3, 5, 6] or forced or pattern == 0 or (action == 4 and pattern == 2):
          doAssert released == 3 and callbackCount == 3
        else:
          doAssert released == 1 and callbackCount == 1
        var expected: seq[pointer]
        for i in 0 .. 2:
          if seen[i] == 0: expected.add(originals[i])
        for d in fresh: expected.add(d)
        var node = stas[0].postponedList.first
        var last: ptr CoListHdr
        for p in expected:
          doAssert cast[pointer](node) == p, "survivors or fresh work reordered/lost"
          doAssert txlFrameSessionCurrent(hostTxDescAt(p))
          last = node
          node = node.next
        doAssert node == nil
        if expected.len != 0:
          doAssert stas[0].postponedList.last == last
        doAssert frameEnv.postponedCount == expected.len.uint32
        doAssert co_list_cnt(addr frameEnv.freeList) == (callbackCount - fresh.len).uint32

# Preserve corrupt lists and unrelated counts without following bad pointers.
for corruption in 0 .. 4:
  setup(0, true)
  mode = 4
  case corruption
  of 0: stas[0].postponedList.last = addr originals[0].link
  of 1: stas[0].postponedList.first = cast[ptr CoListHdr](1)
  of 2: originals[1].link.next = cast[ptr CoListHdr](1)
  of 3: originals[2].link.next = addr originals[0].link
  else: stas[0].postponedList.first = nil
  let first = stas[0].postponedList.first
  let last = stas[0].postponedList.last
  doAssert sta_mgmt_postponed_desc_release(addr stas[0], 1) == 0
  doAssert stas[0].postponedList.first == first and stas[0].postponedList.last == last
  doAssert frameEnv.postponedCount == 3 and callbackCount == 0 and txActiveFlush == nil
doAssert sta_mgmt_postponed_desc_release(nil, 1) == 0
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "count", "visibility", "owner", "detach", "restore", "empty_tail", "validation", "callback_irq", "snapshot_age"])
def test_postponed_batch(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    sta = (FW / "sta_management.nim").read_text()
    functions = "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent", "txlCaptureFrameCallback",
        "txlFrameCallbackCurrent", "txlInvokeFrameCallback", "txl_frame_free_list_pop",
        "txl_frame_get", "txl_frame_release", "txlQueueReferencesStation", "txlDrainRetiredPostponed",
    ])
    functions += "".join(procedure(sta, name) for name in [
        "staPostponedOwner", "staPostponedOwnerCurrent", "staPostponedListValid",
    ])
    body = procedure(sta, "staReleasePostponed") + procedure(sta, "sta_mgmt_postponed_desc_release")
    if mutation == "count":
        old = "    if frameEnv.postponedCount > 0:\n      dec frameEnv.postponedCount\n"
        assert old in body
        body = body.replace(old, "").replace(
            "      txl_frame_release(postponedTxDesc, true)\n",
            "      txl_frame_release(postponedTxDesc, true)\n      if frameEnv.postponedCount > 0:\n        dec frameEnv.postponedCount\n")
    elif mutation == "visibility":
        body = body.replace("  txActiveFlush = addr retained\n", "")
    elif mutation == "owner":
        old = procedure(functions, "staPostponedOwnerCurrent")
        functions = functions.replace(old, "proc staPostponedOwnerCurrent(identity: StaQueueIdentity): bool = true\n")
    elif mutation == "detach":
        body = body.replace("  sta.postponedList = default(CoList)\n", "")
    elif mutation == "restore":
        body = body.replace("    retained.postponed.last.next = sta.postponedList.first\n",
                            "    retained.postponed.last.next = nil\n")
    elif mutation == "empty_tail":
        body = body.replace("    if sta.postponedList.first == nil:", "    if sta.postponedList.last == nil:")
    elif mutation == "validation":
        body = body.replace("  if not staPostponedListValid(addr sta.postponedList):", "  if false:")
    elif mutation == "callback_irq":
        body = body.replace("    irqRestore(callbackIrqState)\n", "")
    elif mutation == "snapshot_age":
        body = body.replace("regRead(MACHW_TIMLO_REG)", "capturedMacTime")
        body = body.replace("  let frameEnv = txFrameEnv()\n", "  let frameEnv = txFrameEnv()\n  let capturedMacTime = regRead(MACHW_TIMLO_REG)\n")
    functions += body
    layout = (FW / "layout_types.nim").read_text()
    identity = "type\n  StaQueueIdentity = object" + layout.split(
        "  StaQueueIdentity = object", 1
    )[1].split("\n  TxDmaOwner", 1)[0]
    debug = "\nvar\n" + "".join(f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions))))
    source = tmp_path / "postponed.nim"
    source.write_text(PLATFORM + identity + debug + functions + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
        "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *options[mode], str(source)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
