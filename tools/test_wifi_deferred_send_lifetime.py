"""Exercise deferred TX selection and handoff with real reusable frame leases."""

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

PLATFORM = ALLOCATION_PLATFORM.replace(STA_QUEUE_STUBS, "").replace(
    "    vifIdx, staInfoIdx: uint8",
    "    vifIdx, staInfoIdx, staIdx, accessCategory: uint8\n"
    "    pbufAddr: uint32\n    etherType, postponeFlags: uint16\n    linkDesc: pointer",
).replace(
    "    valid, instNbr: uint8",
    "    valid, instNbr, psMode, psState, trafficFlags: uint8\n"
    "    aid: uint16\n    psStatus: uint32",
)
PLATFORM += r"""
import bl808/wifi/fw_messages
type
  Vif = object
    vifType, psFlags: uint8
  MmTimUpdatePayload = object
    aid: uint16
    setFlag, vifIdx: uint8
const
  VIF_TYPE_STA = 0'u8
  VIF_TYPE_AP = 2'u8
  MmTimUpdatePayloadSize = 4
var
  vifs: array[2, Vif]
  psEnv: tuple[flags, apPending, otherPending: uint8]
  allocated: MmTimUpdatePayload
  messages: seq[MmTimUpdatePayload]
  sent: seq[pointer]
  readinessChecks, psChecks, allocations, frees, warnings: int
  txAllowed: bool
  currentSending: pointer
  events: uint32
proc inject(point: string)
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc apmTxDescPsAt(p: pointer): ptr HostTxDescView = hostTxDescAt(p)
proc keEnvPsFlags(): ptr typeof(psEnv) = addr psEnv
proc co_list_push_front(queue: ptr CoList; node: ptr CoListHdr) =
  node.next = queue.first
  if queue.first == nil: queue.last = node
  queue.first = node
proc ke_evt_set(bits: uint32) =
  events = events or bits
  inject("event")
proc txl_cntrl_tx_check(vif: pointer): bool =
  inc readinessChecks
  result = txAllowed
  inject("ready")
proc apm_tx_int_ps_check(p: pointer): bool =
  inc psChecks
  inject("ps")
  true
proc txl_cntrl_push_int(p: pointer; ac: uint8): uint8 =
  doAssert not interruptsEnabled
  doAssert hostTxDescAt(p).postponeFlag == 0
  doAssert frameEnv.postponedCount == co_list_cnt(addr stas[0].postponedList),
    "TX handoff observed a stale postponed count"
  doAssert hostTxDescAt(p).accessCategory == ac
  sent.add(p)
  currentSending = p
  inject("push")
  1
proc ke_msg_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  doAssert not interruptsEnabled
  doAssert id == 47 and dest == 0 and src == 3 and size == 4
  inc allocations
  inject("allocate")
  allocated = default(MmTimUpdatePayload)
  addr allocated
proc ke_msg_send(p: pointer) =
  doAssert not interruptsEnabled
  messages.add(cast[ptr MmTimUpdatePayload](p)[])
  inject("send")
proc ke_msg_free_payload(p: pointer) =
  doAssert p == addr allocated
  inc frees
proc assert_warn(cond, file: cstring; line: int) =
  doAssert line == 377
  inc warnings
proc sta_mgmt_aging_postponed_desc(sta: pointer; maxCount: uint32): uint32 = 0
"""

CHECKS = r"""
var
  originals: array[4, ptr HostTxDescView]
  fresh: seq[ptr HostTxDescView]
  trigger: string
  action: int
  fired: bool

proc enqueue(d: ptr HostTxDescView) =
  d.vifIdx = 0
  d.staInfoIdx = 0
  d.staIdx = 0
  d.accessCategory = 0
  d.postponeFlag = 1
  d.linkDesc = d.bufDesc
  co_list_push_back(addr stas[0].postponedList, addr d.link)
  inc frameEnv.postponedCount
  stas[0].trafficFlags = stas[0].trafficFlags or 2

proc allocateFresh(count: int) =
  for i in 0 ..< count:
    let d = hostTxDescAt(txl_frame_get(24))
    doAssert d != nil
    enqueue(d)
    fresh.add(d)

proc retireQueues() =
  txlDrainRetiredPostponed(addr stas[0].postponedList)
  var batch = txActiveFlush
  while batch != nil:
    txlDrainRetiredPostponed(addr batch.postponed)
    batch = batch.previous

proc inject(point: string) =
  if fired or point != trigger: return
  fired = true
  doAssert not interruptsEnabled
  case action
  of 0, 1:
    # A retired station or VIF can reuse all of its old physical frame slots.
    let count = frameEnv.postponedCount.int
    if action == 0: inc stationEpochs[0]
    else: inc rxVifEpochs[0]
    retireQueues()
    doAssert frameEnv.postponedCount == 0
    allocateFresh(count)
    macTime = 120001  # Stale final aging would consume replacement work.
  of 2:
    # A nested flush can consume the detached selection without retiring it.
    doAssert txActiveFlush != nil and txActiveFlush.postponed.first != nil
    txlDrainRetiredPostponed(addr txActiveFlush.postponed)
    allocateFresh(1)
  of 3:
    # A direct completion may replace a lease before clearing its batch link.
    doAssert txActiveFlush != nil
    let d = hostTxDescAt(cast[pointer](txActiveFlush.postponed.first))
    d.postponeFlag = 0
    dec frameEnv.postponedCount
    txl_frame_release(d, false)
    allocateFresh(1)
    doAssert fresh[0] == d
  of 4:
    # Epoch invalidation without a nested drain leaves cleanup to the selector.
    inc stationEpochs[0]
  of 5:
    enqueue(originals[1])
  of 6:
    stas[0].psStatus = 2
    stas[0].psState = 4
  of 7:
    stas[0].psState = 4
  of 8:
    # Replace the queue head at the same address without changing the station.
    let count = frameEnv.postponedCount.int
    retireQueues()
    allocateFresh(count)
    txAllowed = false
  of 9:
    # Submission can immediately complete and re-postpone that physical slot.
    let d = hostTxDescAt(currentSending)
    txl_frame_release(d, false)
    allocateFresh(1)
    doAssert fresh[0] == d
    txAllowed = false
  of 10, 11:
    # Submission can retire both the submitted owner and its remaining queue.
    let d = hostTxDescAt(currentSending)
    if action == 10: inc stationEpochs[0]
    else: inc rxVifEpochs[0]
    let count = frameEnv.postponedCount.int + 1
    retireQueues()
    txl_frame_release(d, false)
    allocateFresh(count)
    macTime = 120001
  else: doAssert false

proc setup(count: int; irq: bool) =
  initPool()
  vifs = default(typeof(vifs))
  vifs[0].vifType = VIF_TYPE_AP
  stas[0] = Sta(valid: 1, instNbr: 0, aid: 42, psStatus: 1, trafficFlags: 2)
  psEnv = default(typeof(psEnv))
  events = 0
  messages.setLen(0)
  sent.setLen(0)
  fresh.setLen(0)
  trigger = ""
  fired = false
  readinessChecks = 0
  psChecks = 0
  allocations = 0
  frees = 0
  warnings = 0
  txAllowed = true
  interruptsEnabled = irq
  doAssert txActiveFlush == nil
  for i in 0 .. 3:
    originals[i] = hostTxDescAt(txl_frame_get(24))
    originals[i].linkDesc = originals[i].bufDesc
    originals[i].vifIdx = 0
    originals[i].staInfoIdx = 0
    originals[i].staIdx = 0
    originals[i].accessCategory = 0
    if i < count: enqueue(originals[i])
  doAssert frameEnv.postponedCount == count.uint32

proc checkFresh() =
  var node = stas[0].postponedList.first
  for d in fresh:
    doAssert node == addr d.link
    doAssert d.postponeFlag == 1 and d.accessCategory == 0
    doAssert txlFrameSessionCurrent(d), "replacement lease was invalidated"
    node = node.next
  doAssert node == nil
  doAssert frameEnv.postponedCount == fresh.len.uint32
  doAssert frameEnv.freeList.first == nil, "replacement frame was freed"

for irq in [false, true]:
  for point in ["allocate", "send"]:
    for change in 0 .. 7:
      setup(1, irq)
      trigger = point
      action = change
      var blocked = 0'u32
      let selected = apm_tx_int_ps_get_postpone(addr vifs[0], addr stas[0], addr blocked)
      doAssert fired and interruptsEnabled == irq and txActiveFlush == nil
      if change <= 3:
        doAssert selected == nil and blocked == 1,
          "selector returned a retired, drained, or recycled selection"
        checkFresh()
      elif change == 4:
        doAssert selected == nil and blocked == 1
        doAssert frameEnv.postponedCount == 0
        doAssert co_list_cnt(addr frameEnv.freeList) == 1
      elif change == 5:
        doAssert selected == cast[pointer](originals[0]) and blocked == 0
        doAssert stas[0].postponedList.first == addr originals[1].link
        doAssert frameEnv.postponedCount == 2 and stas[0].trafficFlags == 2
        doAssert (hostTxLinkDescAt(originals[0].bufDesc).macHeader[1] and 0x20) != 0,
          "More Data ignored work queued during TIM notification"
        if point == "allocate": doAssert messages.len == 0 and frees == 1
      else:
        doAssert selected == nil and blocked == 1
        doAssert stas[0].postponedList.first == addr originals[0].link
        doAssert originals[0].accessCategory == 0 and originals[0].postponeFlag == 1
        doAssert frameEnv.postponedCount == 1 and stas[0].trafficFlags == 8
        doAssert events == 256

  # The sender must stop before touching a replacement station or VIF queue.
  for point in ["event", "ready", "ps"]:
    for change in [0, 1]:
      setup(2, irq)
      vifs[0].psFlags = 1
      trigger = point
      action = change
      doAssert sta_mgmt_send_postponed_frame(addr vifs[0], addr stas[0], 0) == 0
      doAssert fired and sent.len == 0 and interruptsEnabled == irq
      checkFresh()

  # Reuse of the exact head pointer must invalidate earlier readiness results.
  for point in ["ready", "ps"]:
    setup(2, irq)
    trigger = point
    action = 8
    doAssert sta_mgmt_send_postponed_frame(addr vifs[0], addr stas[0], 0) == 0
    doAssert fired and sent.len == 0 and readinessChecks == 2
    doAssert interruptsEnabled == irq
    checkFresh()

  for change in [9, 10, 11]:
    setup(2, irq)
    trigger = "push"
    action = change
    doAssert sta_mgmt_send_postponed_frame(addr vifs[0], addr stas[0], 1) == 1
    doAssert fired and sent == @[cast[pointer](originals[0])]
    doAssert interruptsEnabled == irq
    if change == 9:
      doAssert frameEnv.postponedCount == 2
      doAssert stas[0].postponedList.first == addr originals[1].link
      doAssert stas[0].postponedList.last == addr fresh[0].link
      doAssert fresh[0].postponeFlag == 1 and txlFrameSessionCurrent(fresh[0])
    else: checkFresh()

  # Ordinary AP selection still chooses the eligible middle frame.
  setup(3, irq)
  originals[1].accessCategory = 1
  stas[0].psStatus = 2
  stas[0].psState = 8
  stas[0].trafficFlags = 8
  doAssert sta_mgmt_send_postponed_frame(addr vifs[0], addr stas[0], 1) == 1
  doAssert sent == @[cast[pointer](originals[1])]
  doAssert frameEnv.postponedCount == 2 and interruptsEnabled == irq
  doAssert stas[0].postponedList.first == addr originals[0].link
  doAssert stas[0].postponedList.last == addr originals[2].link

  # Validate queue geometry before the sender reads the first descriptor.
  setup(1, irq)
  stas[0].postponedList.first = cast[ptr CoListHdr](1)
  doAssert sta_mgmt_send_postponed_frame(addr vifs[0], addr stas[0], 0) == 0
  doAssert readinessChecks == 0 and sent.len == 0 and frameEnv.postponedCount == 1
  doAssert interruptsEnabled == irq
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "visibility", "lease", "selection_owner", "service", "more_data", "head_lease", "count", "sender_owner", "validation"])
def test_deferred_send_lifetime(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    sta = (FW / "sta_management.nim").read_text()
    apm = (FW / "scan_station_ap_me.nim").read_text()
    functions = "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent", "txlCaptureFrameCallback",
        "txlFrameCallbackCurrent", "txlInvokeFrameCallback", "txl_frame_free_list_pop",
        "txl_frame_get", "txl_frame_release", "txlDrainRetiredPostponed",
    ])
    functions += "".join(procedure(sta, name) for name in [
        "staPostponedOwner", "staPostponedOwnerCurrent", "staPostponedListValid",
        "staReleasePostponed", "sta_mgmt_postponed_desc_release",
    ])
    selector = "".join(procedure(apm, name) for name in [
        "apmPsCapture", "apmPsSessionCurrent", "apmPsTimRequest", "apmPsHasMore",
        "apm_tx_int_ps_get_postpone",
    ])
    sender = procedure(sta, "sta_mgmt_send_postponed_frame")
    if mutation == "visibility":
        selector = selector.replace("      txActiveFlush = addr batch\n", "")
    elif mutation == "lease":
        selector = selector.replace("if not txlFrameLeaseMatches(hostTxDescAt(postponedTxDesc), generation):", "if false:")
    elif mutation == "selection_owner":
        selector = selector.replace("      if not apmPsSessionCurrent(identity):", "      if false:")
    elif mutation == "service":
        selector = selector.replace("if sta.psStatus != psStatus or sta.psState != delivMask:", "if false:")
    elif mutation == "more_data":
        selector = selector.replace("let stillMore = apmPsHasMore(addr sta.postponedList, delivMask, uapsdService)", "let stillMore = hasMoreDeliverablePostponedTx")
    elif mutation == "head_lease":
        sender = sender.replace("not txlFrameLeaseMatches(hostTxDescAt(cast[pointer](head)), generation)", "false")
    elif mutation == "count":
        old = ("    if frameEnv.postponedCount > 0:\n"
               "      frameEnv.postponedCount = frameEnv.postponedCount - 1\n")
        assert old in sender
        sender = sender.replace(old, "").replace("    discard txl_cntrl_push_int(frameDesc, ac)\n",
                                                "    discard txl_cntrl_push_int(frameDesc, ac)\n" + old)
    elif mutation == "sender_owner":
        sender = sender.replace("staPostponedOwnerCurrent(identity)", "true")
    elif mutation == "validation":
        sender = sender.replace("if not staPostponedListValid(addr sta.postponedList):", "if false:")
    functions += selector + sender
    layout = (FW / "layout_types.nim").read_text()
    identity = "type\n  ApmPsSession = object" + layout.split(
        "  ApmPsSession = object", 1)[1].split("\n  TxDmaOwner", 1)[0]
    storage = (FW / "global_state/storage.nim").read_text()
    table = "\nvar mac_ac2uapsd*" + storage.split("var mac_ac2uapsd*", 1)[1].split("\n]", 1)[0] + "\n]\n"
    debug = "\nvar\n" + "".join(f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions))))
    source = tmp_path / "deferred_send.nim"
    source.write_text(PLATFORM + identity + table + debug + functions + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
        "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(source)], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and (
            "AssertionDefect" in result.stdout or "SIGSEGV" in result.stdout or "AddressSanitizer" in result.stdout
        ), result.stdout
