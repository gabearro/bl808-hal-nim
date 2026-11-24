"""Run channel protection-frame handoff and completion barriers on the host."""

from pathlib import Path

import pytest

from test_wifi_deferred_auth import run_nim
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_mm_timer_lifetime import source as mm_timer_source


PLATFORM = r"""
proc smDeferredPublish(vifEntry: pointer) = discard
var txResetEpoch: uint32
proc txlFrameCallbackCurrent(resetEpoch = txResetEpoch): bool = true
proc chanSwitchCallbackCurrent(): bool = true
proc chanSwitchSelectTarget(target: pointer): bool = true
const
  MAX_VIFS = 2
  TASK_MM = 0'u8
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_STA = 0'u8
  VIF_TYPE_AP = 2'u8
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  Channel = object
    txPower: uint8
  ChanCtxtView = object
    channel: Channel
    status, contextIndexOrMarker, altIdx, invalidMarker: uint8
    schedSlot, opSlot: uint16
  Vif = object
    next: pointer
    chanCtxt, postponedStaHead: pointer
    state, vifType, vifIdx, staIdx: uint8
  Env = object
    currentCtxt, scheduledCtxt, deferredMsg: pointer
    activeList: CoList
    flags, ctxtCount, switchPending, scanDelayCount, connlessDelayCount: uint8
    surveySnapshot: uint8
    lastMacTime: uint32
  PsEnv = object
    enabled: uint8
    statusFlags: uint32
  VifMgmt = object
    activeList: CoList
  TdEntryView = object
    endActive: uint8
  TxEnv = object
    freeList: CoList
  Send = tuple[kind: string, index: uint8, duration: uint16, state: uint8, callback: pointer, token: uint32]
  Event = tuple[kind: string, value: uint]
var
  env: Env
  ps: PsEnv
  mgmt: VifMgmt
  tx: TxEnv
  vifs: array[2, Vif]
  contexts: array[5, ChanCtxtView]
  td_env: array[64, uint32]
  sends: seq[Send]
  events: seq[Event]
  nullResult: array[7, uint8]
  ctsResult: array[2, uint8]
  allocFail: bool
  callbackStorage: pointer
  nimFwDbgChanPreChanMeta, nimFwDbgChanPreChanFreq, nimFwDbgAutoNullSkipped: uint32
  allocations: int
  cdeTarget: pointer
  checkAdmission: proc(p: pointer): bool
const MACHW_BASE = 0x24B00000'u
proc chanEnvView(): ptr Env = addr env
proc psEnvView(): ptr PsEnv = addr ps
proc vifMgmtEnvView(): ptr VifMgmt = addr mgmt
proc txFrameEnv(): ptr TxEnv = addr tx
proc irqSave(): uint32 = 0
proc irqRestore(value: uint32) = discard
proc resetProtection() = discard
proc chanCtxtAt(p: pointer): ptr ChanCtxtView = cast[ptr ChanCtxtView](p)
proc chanCtxtForIdx(i: uint8): ptr ChanCtxtView = addr contexts[i]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc tdEntryAt(p: pointer): ptr TdEntryView = cast[ptr TdEntryView](p)
proc chanForceIdle(): bool =
  events.add(("idle", 0'u))
  inc txResetEpoch
  true
proc chanForceIdleForDeparture(target: pointer): bool =
  doAssert target == env.scheduledCtxt
  chanForceIdle()
proc mm_active() = events.add(("active", 0'u))
proc mmReplayEdca() = discard
proc blmac_pwr_mgt_setf(value: uint32) = events.add(("pm", value.uint))
proc chan_upd_ctxt_status(p: pointer; status: uint8) =
  chanCtxtAt(p).status = status
  events.add(("status", status.uint))
proc txl_frame_send_null_frame(sta: uint8; cb: pointer; arg: uint32): uint8 {.cdecl.} =
  if checkAdmission != nil: doAssert checkAdmission(addr vifs[sta])
  sends.add(("null", sta, 0'u16, chanCtxtAt(env.currentCtxt).status, cb, arg))
  nullResult[sta]
proc txl_frame_send_selfcts_frame(p: pointer; duration: uint16; cb: pointer; arg: uint32): uint8 {.cdecl.} =
  let v = vifChannelAt(p)
  if checkAdmission != nil: doAssert checkAdmission(p)
  sends.add(("cts", v.vifIdx, duration, chanCtxtAt(env.currentCtxt).status, cb, arg))
  ctsResult[v.vifIdx]
proc ke_msg_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  doAssert id == 74 and dest == TASK_MM and src == 255 and size == 4
  inc allocations
  if allocFail: nil else: addr callbackStorage
proc ke_msg_send(p: pointer) =
  doAssert p == addr callbackStorage
  events.add(("message", 74'u))
proc reset() =
  env = default(Env)
  resetProtection()
  ps = default(PsEnv)
  vifs = default(typeof(vifs))
  contexts = default(typeof(contexts))
  sends.setLen(0)
  events.setLen(0)
  nullResult = default(typeof(nullResult))
  ctsResult = default(typeof(ctsResult))
  allocFail = false
  allocations = 0
  callbackStorage = nil
  checkAdmission = nil
  tx.freeList.first = cast[ptr CoListHdr](1)
  env.currentCtxt = addr contexts[0]
  env.scheduledCtxt = addr contexts[1]
  env.ctxtCount = 2
  env.switchPending = 1
  contexts[0].status = 4
  contexts[0].schedSlot = 50
  for i in 0 ..< contexts.len: contexts[i].contextIndexOrMarker = i.uint8
  for i in 0 ..< vifs.len:
    vifs[i].vifIdx = i.uint8
    vifs[i].staIdx = i.uint8
    vifs[i].state = 1
    vifs[i].chanCtxt = addr contexts[0]
    vifs[i].postponedStaHead = cast[pointer](1)
  vifs[0].next = addr vifs[1]
  mgmt.activeList.first = cast[ptr CoListHdr](addr vifs[0])
  cdeTarget = addr contexts[2]
"""

PRE_SWITCH_STUB = r"""
proc chan_pre_switch_channel(p: pointer = nil) = events.add(("pre", cast[uint](env.scheduledCtxt)))
"""

CFM_STUBS = r"""
proc chan_sta_tx_cfm(p: pointer; status: uint32 = 0) {.cdecl.} = discard
proc chan_ap_tx_cfm(p: pointer; status: uint32 = 0) {.cdecl.} = discard
"""


def protection_source(platform: str) -> str:
    platform = platform.replace(procedure(platform, "resetProtection"), "proc resetProtection()\n")
    support = r'''
{.pragma: wifiCtrl.}
type ChanSwitchContext = object
  target: pointer
  captured: bool
proc chanSwitchCapture(target: pointer): ChanSwitchContext =
  ChanSwitchContext(target: target, captured: target != nil)
proc chanSwitchContextCurrent(context: ChanSwitchContext; checkDefinition = true): bool =
  context.captured
proc chanSwitchCancel(target: pointer = nil)
'''
    support += (FW / "channel_protection.nim").read_text()
    support += r'''
proc resetProtection() = chanProtectionInvalidate()
proc chanSwitchCancel(target: pointer = nil) =
  let retired = chanProtectionCancel(target)
  if retired != nil and env.scheduledCtxt == retired: env.scheduledCtxt = nil
'''
    return platform + support


def test_failed_protection_frames_do_not_block_switch(tmp_path: Path) -> None:
    checks = r"""
reset()
vifs[1].state = 0
nullResult[0] = 1
chan_goto_idle_cb()
doAssert env.scanDelayCount == 0 and env.connlessDelayCount == 0,
  "failed submission has no future completion to wait for"
doAssert events[^1].kind == "pre"
"""
    run_nim(tmp_path, protection_source(PLATFORM + PRE_SWITCH_STUB + CFM_STUBS)
            + procedure((FW / "task_handlers.nim").read_text(), "chan_goto_idle_cb") + checks)


def callback_bodies() -> str:
    source = (FW / "task_handlers.nim").read_text()
    return procedure(source, "chan_sta_tx_cfm") + procedure(source, "chan_ap_tx_cfm")


def test_protection_admission_and_counting(tmp_path: Path) -> None:
    checks = r"""
for count in 1'u8 .. 3:
  for failedNull in 0'u8 .. 1:
    for failedCts in 0'u8 .. 1:
      for blockedPs in [false, true]:
        for oldStatus in [1'u8, 3, 4, 5, 6]:
          reset()
          env.ctxtCount = count
          contexts[0].status = oldStatus
          vifs[1].vifType = 2
          nullResult[0] = failedNull
          ctsResult[1] = failedCts
          if blockedPs: ps.enabled = 1
          chan_goto_idle_cb()
          let apSent = count == 2 and not blockedPs
          let nullSent = not blockedPs
          let pendingNull = nullSent and failedNull == 0
          let pendingCts = apSent and failedCts == 0
          doAssert env.scanDelayCount == pendingNull.uint8
          doAssert env.connlessDelayCount == pendingCts.uint8
          doAssert sends.len == nullSent.int + apSent.int
          doAssert contexts[0].status == oldStatus
          doAssert env.switchPending == 0
          for send in sends:
            doAssert send.state == 6, "protection frame must bypass channel pause"
            if send.kind == "null":
              doAssert send.callback == cast[pointer](chan_sta_tx_cfm)
            else:
              doAssert send.callback == cast[pointer](chan_ap_tx_cfm)
              doAssert send.duration == 51
          if pendingNull or pendingCts:
            doAssert events[^1].kind == "active" and contexts[1].status == 3
          else:
            doAssert events[^1].kind == "pre"

reset()
nullResult[0] = 1
chan_goto_idle_cb()
doAssert sends.len == 2 and env.scanDelayCount == 1
chan_sta_tx_cfm(cast[pointer](sends[^1].token.uint), 0)
doAssert env.scanDelayCount == 0 and events[^1].kind == "pre"

for skip in 0 .. 4:
  reset()
  vifs[0].chanCtxt = addr contexts[2]
  contexts[2].schedSlot = 30
  vifs[1].vifType = 2
  if skip == 1: vifs[1].state = 0
  if skip == 2: vifs[1].postponedStaHead = nil
  if skip == 3: vifs[1].chanCtxt = addr contexts[2]
  if skip == 4: contexts[2].schedSlot = 0
  chan_goto_idle_cb()
  doAssert sends.len == (skip == 0).int
  if skip == 0: doAssert sends[0].duration == 30

for badStation in [7'u8, 255]:
  reset()
  vifs[0].staIdx = badStation
  vifs[1].state = 0
  chan_goto_idle_cb()
  doAssert sends.len == 0 and env.scanDelayCount == 0
for slotCount in [0'u16, 1, 50, 65535]:
  reset()
  vifs[0].state = 0
  vifs[1].vifType = 2
  contexts[0].schedSlot = slotCount
  chan_goto_idle_cb()
  let duration = ((slotCount.uint32 shl 10) div 1000) and 0xFFFF'u32
  doAssert sends.len == (duration != 0).int
  if sends.len != 0: doAssert sends[0].duration == duration.uint16
reset()
env.scheduledCtxt = nil
chan_goto_idle_cb()
doAssert sends.len == 0 and events.len == 0 and env.switchPending == 0
"""
    run_nim(tmp_path, protection_source(PLATFORM + PRE_SWITCH_STUB) + callback_bodies()
            + procedure((FW / "task_handlers.nim").read_text(), "chan_goto_idle_cb") + checks)


def test_tx_confirmation_waits_for_all_protection_frames(tmp_path: Path) -> None:
    checks = r"""
for apCount in 0'u8 .. 2:
  for staCount in 0'u8 .. 2:
    for reverse in [false, true]:
      reset()
      env.connlessDelayCount = apCount
      env.scanDelayCount = staCount
      let total = apCount.int + staCount.int
      for i in 0 ..< 2:
        let useAp = (i == 0) == reverse
        let n = if useAp: apCount else: staCount
        for j in 0 ..< n.int:
          if useAp: chan_ap_tx_cfm(nil, 0)
          else: chan_sta_tx_cfm(nil, 0x00800000)
          let remaining = env.connlessDelayCount + env.scanDelayCount
          doAssert events.len == (if remaining == 0: 2 else: 0),
            "MAC must not retune with protection frames still outstanding"
      doAssert env.connlessDelayCount == 0 and env.scanDelayCount == 0
      doAssert events.len == (if total == 0: 0 else: 2)
      chan_ap_tx_cfm(nil, 0)
      chan_sta_tx_cfm(nil, 0)
      doAssert events.len == (if total == 0: 0 else: 2), "duplicate completion"
"""
    run_nim(tmp_path, protection_source(PLATFORM + PRE_SWITCH_STUB) + callback_bodies() + checks)


def test_switch_request_allocation_and_publication(tmp_path: Path) -> None:
    checks = r"""
reset()
env.scheduledCtxt = nil
env.switchPending = 0
allocFail = true
let before = env
chan_switch_start(addr contexts[1])
doAssert env == before and contexts[1].status == 0 and events.len == 0
doAssert allocations == 1
allocFail = false
chan_switch_start(addr contexts[1])
doAssert env.scheduledCtxt == addr contexts[1]
doAssert env.switchPending == 1 and contexts[1].status == 2
doAssert callbackStorage == cast[pointer](chan_goto_idle_cb)
doAssert events == @[("status", 2'u), ("message", 74'u)]
let previous = env
chan_switch_start(addr contexts[2])
doAssert env == previous and allocations == 2
for count in 0'u8 .. 3:
  for marker in 0'u8 .. 4:
    reset()
    env.ctxtCount = count
    contexts[0].contextIndexOrMarker = marker
    chan_switch_start(addr contexts[0])
    doAssert allocations == 0
    doAssert events.len == (count > 1 and marker <= 2).int
reset()
chan_switch_start(nil)
doAssert allocations == 0 and events.len == 0
"""
    stubs = r"""
proc chan_goto_idle_cb() {.cdecl.} = discard
proc keMsgHdrFromPayload(p: pointer): pointer = p
proc ke_msg_free(p: pointer) = discard
proc chanSwitchAllocate(target: pointer): pointer =
  result = ke_msg_alloc(74, TASK_MM, 255, 4)
  if result != nil: cast[ptr pointer](result)[] = cast[pointer](chan_goto_idle_cb)
proc chanSwitchPublish(request: pointer): bool = true
proc chanSwitchAdmit(request: pointer): bool = true
"""
    tasks = (FW / "task_handlers.nim").read_text()
    run_nim(tmp_path, PLATFORM + stubs + procedure(tasks, "chanStartSwitch")
            + procedure(tasks, "chan_switch_start") + checks)


def home_wake_source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n  MmVifIdentity" + layout.split("  MmVifIdentity", 1)[1].split("\n\n", 1)[0] + "\n"
    return types + r"""
type
  MmTimerView = object
    callback: pointer
    env, expiry: uint32
  Delivery = object
    timer: pointer
    cancelled: bool
var
  homeDeadlines: seq[ptr MmTimerView]
  homeDelivery: ptr Delivery
  rxVifEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[STA_INFO_TAB_ENTRIES, uint32]
  clock: uint32
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc staDeleteEpoch(index: uint8): uint32 =
  if index < STA_INFO_TAB_ENTRIES.uint8: stationEpochs[index] else: 0
proc txlResetting(): bool = false
proc txlVifIsRetiring(index: uint8): bool = false
proc macTimeNow(): uint32 = clock
proc mmTimerActiveDelivery(timer: pointer): ptr Delivery =
  if homeDelivery != nil and homeDelivery.timer == timer: homeDelivery else: nil
proc mmTimerSetLocked(timer: pointer; expiry, saved: uint32) =
  let delivery = mmTimerActiveDelivery(timer)
  if delivery != nil: delivery.cancelled = true
  let entry = cast[ptr MmTimerView](timer)
  entry.expiry = expiry
  if entry notin homeDeadlines: homeDeadlines.add(entry)
proc fireNextHomeTimer(beforeDelivery: proc() = nil) =
  doAssert homeDeadlines.len != 0
  let entry = homeDeadlines[0]
  homeDeadlines.delete(0)
  clock = entry.expiry
  var delivery = Delivery(timer: entry)
  homeDelivery = addr delivery
  let callback = entry.callback
  let argument = cast[pointer](entry.env.uint)
  if beforeDelivery != nil: beforeDelivery()
  cast[proc(arg: pointer) {.cdecl.}](callback)(argument)
  homeDelivery = nil
""" + "".join(procedure(kernel, name) for name in (
        "mmCaptureVif", "mmVifCurrent", "mmStaOwnerCurrent", "mmStaTimerCurrent",
    )) + (FW / "channel_home_wake.nim").read_text().replace(" {.wifiCtrl.}", "")


PRE_SWITCH_PLATFORM = r"""
proc chanCtxtOpTimer(): pointer = cast[pointer](76)
proc mm_timer_clear(p: pointer) = events.add(("timer-clear", cast[uint](p)))
proc packChannelMeta(p: ptr Channel): uint32 = 0
proc packChannelFreq(p: ptr Channel): uint32 = 0
proc rxl_timer_int_handler() = events.add(("rx-harvest", 0'u))
proc rxl_cntrl_evt() = events.add(("rx-drain", 0'u))
proc phySetChannel(p: ptr Channel) =
  for i in 0 ..< contexts.len:
    if p == addr contexts[i].channel: events.add(("phy", i.uint))
proc tpc_update_tx_power(value: uint8) = discard
var macControl: uint32
proc regWrite(address: uint; value: uint32) =
  if address == MACHW_BASE + 0x4C: macControl = value
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_BASE + 0x4C
  macControl
proc rfPhyTraceCheckpoint(value: uint32) = discard
proc rfPriPrepareWb03MacActiveScanState() = discard
proc waitRfUs(value: uint32) = discard
proc ke_msg_send_basic(id: uint16; dest, src: uint8) = events.add(("basic", id.uint))
const MM_SCAN_CHANNEL_START_IND = 75'u16
var chanCtxtEpochs: array[5, uint32]
proc scanDwellPublish(id: uint16; slot: uint32) = ke_msg_send_basic(id, 1, 255)
proc vif_mgmt_send_postponed_frame(p: pointer) = discard
proc chan_cde_evt(p: pointer) = env.scheduledCtxt = cdeTarget
proc lastPhy(): int =
  result = -1
  for event in events:
    if event.kind == "phy": result = event.value.int
""" + home_wake_source()


def test_preswitch_honors_scan_and_roc_priority(tmp_path: Path) -> None:
    checks = r"""
for flags in [0'u8, 4, 8, 12, 0x20, 0x24, 0x28, 0x2C]:
  reset()
  mgmt.activeList.first = nil
  env.flags = flags
  chan_pre_switch_channel()
  let expected = if (flags and 8) != 0: 3 elif (flags and 4) != 0: 4 else: 1
  doAssert lastPhy() == expected
  doAssert env.currentCtxt == (addr contexts[expected]) and env.scheduledCtxt == nil
  doAssert env.flags == (flags and not 0x20'u8)
  if expected != 1: doAssert contexts[1].status == 1
for count in 0'u8 .. 3:
  reset()
  mgmt.activeList.first = nil
  env.ctxtCount = count
  env.scheduledCtxt = nil
  env.activeList.first = cast[ptr CoListHdr](addr contexts[1])
  chan_pre_switch_channel()
  let expected = if count == 0: -1 elif count == 1: 1 else: 2
  doAssert lastPhy() == expected
"""
    run_nim(tmp_path, PLATFORM + PRE_SWITCH_PLATFORM + CFM_STUBS
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_pre_switch_channel")
            + checks)


@pytest.mark.parametrize("mode", ["checked", "firmware", "old-drop"])
def test_sta_home_wake_uses_last_free_descriptor_or_retries(tmp_path: Path, mode: str) -> None:
    checks = r"""
for initiallyFree in [false, true]:
  reset()
  homeDeadlines.setLen(0)
  clock = high(uint32) - 1000
  env.currentCtxt = nil
  env.ctxtCount = 1
  env.scheduledCtxt = addr contexts[0]
  vifs[0].next = nil
  if not initiallyFree: tx.freeList.first = nil
  let skipped = nimFwDbgAutoNullSkipped
  chan_pre_switch_channel()
  doAssert lastPhy() == 0 and env.currentCtxt == addr contexts[0]
  doAssert env.scheduledCtxt == nil and events[^1].kind == "active"
  doAssert ("pm", 0'u) in events
  doAssert nimFwDbgAutoNullSkipped == skipped + (not initiallyFree).uint32
  doAssert sends.len == initiallyFree.int
  if not initiallyFree:
    doAssert homeDeadlines.len == 1 and homeDeadlines[0].expiry == 3999
    tx.freeList.first = cast[ptr CoListHdr](1)
    fireNextHomeTimer()
  doAssert homeDeadlines.len == 0 and sends.len == 1
  doAssert sends[0].kind == "null" and sends[0].index == vifs[0].staIdx
  doAssert sends[0].callback == nil and sends[0].token == 0
"""
    pre_switch = procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_pre_switch_channel")
    code = PLATFORM + PRE_SWITCH_PLATFORM + CFM_STUBS
    if mode == "old-drop":
        # The earlier home path skipped an empty pool without preserving work.
        pre_switch = pre_switch.replace("chanHomeWakeRequest(vif2, contextIndexOrMarker)",
            "if txFrameEnv().freeList.first != nil:\n"
            "                discard txl_frame_send_null_frame(vif.staIdx, nil, 0)\n"
            "              else: inc nimFwDbgAutoNullSkipped", 1)
        with pytest.raises(AssertionError, match="homeDeadlines.len == 1"):
            run_program(tmp_path, "firmware", code + pre_switch + checks)
    else:
        run_program(tmp_path, mode, code + pre_switch + checks)


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_home_wake_retry_is_bounded_and_session_owned(tmp_path: Path, mode: str) -> None:
    checks = r"""
proc beginHome() =
  reset()
  homeDeadlines.setLen(0)
  clock = 0
  env.scheduledCtxt = addr contexts[0]
  vifs[0].next = nil

# Rejected submissions retry at bounded intervals, including RC failure with
# a free descriptor. A permanently full pool never invokes the allocator.
for slotFree in [false, true]:
  beginHome()
  if not slotFree: tx.freeList.first = nil
  nullResult[0] = 1
  chan_pre_switch_channel()
  doAssert events[^1].kind == "active"
  for step in 1 .. 4:
    doAssert homeDeadlines.len == 1 and homeDeadlines[0].expiry == (step * 5000).uint32
    fireNextHomeTimer()
  doAssert homeDeadlines.len == 0 and sends.len == (if slotFree: 5 else: 0)

for replace in 0 .. 6:
  beginHome()
  tx.freeList.first = nil
  chan_pre_switch_channel()
  tx.freeList.first = cast[ptr CoListHdr](1)
  case replace
  of 0: inc stationEpochs[0]
  of 1: inc rxVifEpochs[0]
  of 2: inc chanCtxtEpochs[0] # a TX reset alone no longer retires the wake
  of 3: inc chanCtxtEpochs[0]
  of 4: env.currentCtxt = addr contexts[3]
  of 5: env.scheduledCtxt = addr contexts[3]
  else: ps.enabled = 1
  fireNextHomeTimer()
  doAssert sends.len == 0 and homeDeadlines.len == 0

# A new home return can supersede a popped but not-yet-delivered old timer.
beginHome()
tx.freeList.first = nil
chan_pre_switch_channel()
fireNextHomeTimer(proc() =
  chanHomeWakeRequest(addr vifs[0], 0)
  tx.freeList.first = cast[ptr CoListHdr](1))
doAssert sends.len == 0 and homeDeadlines.len == 1 and homeDeadlines[0].expiry == 10000
fireNextHomeTimer()
doAssert sends.len == 1 and homeDeadlines.len == 0

# The second VIF can use its existing descriptor even when the first VIF's
# immediate submission was rejected and needs a retry.
beginHome()
vifs[0].next = addr vifs[1]
nullResult[0] = 1
chan_pre_switch_channel()
doAssert sends.len == 2 and sends[0].index == 0 and sends[1].index == 1
doAssert homeDeadlines.len == 1
nullResult[0] = 0
fireNextHomeTimer()
doAssert sends.len == 3 and sends[^1].index == 0 and homeDeadlines.len == 0
"""
    run_program(tmp_path, mode, PLATFORM + PRE_SWITCH_PLATFORM + CFM_STUBS
                + procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_pre_switch_channel")
                + checks)


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_home_wake_timer_against_real_mm_dispatch(tmp_path: Path, mode: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    identity = "type\n  MmVifIdentity" + layout.split("  MmVifIdentity", 1)[1].split("\n\n", 1)[0] + "\n"
    code = mm_timer_source() + identity + r"""
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_STA = 0'u8
type
  Vif = object
    chanCtxt: pointer
    state, vifType, vifIdx, staIdx: uint8
var
  home: uint32
  vif = Vif(state: 1, chanCtxt: addr home)
  env = (currentCtxt: cast[pointer](addr home), scheduledCtxt: pointer(nil))
  tx: tuple[freeList: CoList]
  ps = (enabled: 0'u8, statusFlags: 0'u32)
  rxVifEpochs: array[MAX_VIFS, uint32]
  chanCtxtEpochs: array[5, uint32]
  txResetEpoch, nimFwDbgAutoNullSkipped: uint32
  submissions: int
proc vifChannelForIdx(index: uint8): ptr Vif =
  if index == 0: addr vif else: nil
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc chanCtxtForIdx(index: uint8): pointer = addr home
proc chanEnvView(): ptr typeof(env) = addr env
proc psEnvView(): ptr typeof(ps) = addr ps
proc txFrameEnv(): ptr typeof(tx) = addr tx
proc staDeleteEpoch(index: uint8): uint32 = 0
proc txlResetting(): bool = false
proc txlVifIsRetiring(index: uint8): bool = false
proc macTimeNow(): uint32 = now
proc txl_frame_send_null_frame(sta: uint8; cb: pointer; argument: uint32): uint8 =
  doAssert not enabled and sta == 0 and tx.freeList.first != nil
  inc submissions
  0
"""
    code += "".join(procedure(kernel, name) for name in (
        "mmCaptureVif", "mmVifCurrent", "mmTimerActiveDelivery", "mmStaOwnerCurrent", "mmStaTimerCurrent",
    ))
    code += (FW / "channel_home_wake.nim").read_text()
    run_program(tmp_path, mode, code + r"""
now = high(uint32) - 1000
chanHomeWakeRequest(addr vif, 0)
doAssert mm_timer_list.first != nil and hardware[^1].expiry == 3999
now = 3999
onClearEvent = proc() =
  onRestore = proc() =
    chanHomeWakeRequest(addr vif, 0)
    tx.freeList.first = cast[ptr CoListHdr](1)
mm_timer_schedule()
doAssert submissions == 0 and mm_timer_list.first != nil and hardware[^1].expiry == 8999
now = 8999
mm_timer_schedule()
doAssert submissions == 1 and nimFwDbgHomeWakeQueued == 1 and mm_timer_list.first == nil
doAssert mmTimerMutationTop == nil and enabled and not mmTimerScheduling
""", defines=("bl808WifiBenchConnectedScan",))


def test_preswitch_only_drains_receive_on_scan_or_roc_handoff(tmp_path: Path) -> None:
    checks = r"""
for prev in [-1, 0, 3, 4]:
  for next in [1, 3, 4]:
    reset()
    mgmt.activeList.first = nil
    env.currentCtxt = if prev < 0: nil else: addr contexts[prev]
    env.scheduledCtxt = addr contexts[next]
    chan_pre_switch_channel()
    var relevant: seq[string]
    for event in events:
      if event.kind in ["rx-harvest", "rx-drain", "phy"]: relevant.add(event.kind)
    let expected = if prev >= 3 or next >= 3: @["rx-harvest", "rx-drain", "phy"] else: @["phy"]
    doAssert relevant == expected and lastPhy() == next
"""
    run_nim(tmp_path, PLATFORM + PRE_SWITCH_PLATFORM + CFM_STUBS
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_pre_switch_channel")
            + checks)


def test_scan_and_roc_restore_only_saved_pm_bit(tmp_path: Path) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    platform = PLATFORM.replace(procedure(PLATFORM, "blmac_pwr_mgt_setf"), "")
    checks = r"""
for flags in [8'u8, 4'u8]:
  for initial in [0'u32, 1, 4, 5, 0xFFFFFFFB'u32, high(uint32)]:
    reset()
    env.flags = flags
    macControl = initial
    chan_pre_switch_channel()
    # chan.o:chan_pre_switch_channel+0x128 extracts bit 2 before clearing it.
    doAssert env.surveySnapshot == ((initial shr 2) and 1).uint8
    doAssert macControl == (initial and not 4'u32)
    # The completion at chan_ctxt_op_evt+0x11e uses the live register.
    macControl = macControl xor 0x80'u32
    blmac_pwr_mgt_setf(env.surveySnapshot.uint32)
    doAssert macControl == (initial xor 0x80'u32)
"""
    run_nim(tmp_path, platform + PRE_SWITCH_PLATFORM + CFM_STUBS
            + "proc assert_err(a, b: cstring; line: cint) = doAssert false\n"
            + procedure(kernel, "blmac_pwr_mgt_setf")
            + procedure(kernel, "chan_pre_switch_channel") + checks)


def test_protection_completion_to_preswitch_integration(tmp_path: Path) -> None:
    source = (FW / "task_handlers.nim").read_text()
    forward = "proc chan_pre_switch_channel*() {.exportc, cdecl.}\n"
    checks = r"""
reset()
vifs[1].vifType = 2
checkAdmission = proc(p: pointer): bool = chan_is_tx_allowed(p)
doAssert not chan_is_tx_allowed(addr vifs[0])
chan_goto_idle_cb()
doAssert env.scanDelayCount == 1 and env.connlessDelayCount == 1
doAssert lastPhy() == -1 and contexts[0].status == 4
chan_sta_tx_cfm(cast[pointer](sends[0].token.uint), 0x00800000)
doAssert lastPhy() == -1
chan_ap_tx_cfm(cast[pointer](sends[1].token.uint), 0)
doAssert lastPhy() == 1 and env.currentCtxt == addr contexts[1]
doAssert env.scheduledCtxt == nil
chan_ap_tx_cfm(nil, 0)
chan_sta_tx_cfm(nil, 0)
var retunes = 0
for event in events:
  if event.kind == "phy": inc retunes
doAssert retunes == 1

reset()
env.flags = 8
vifs[1].state = 0
nullResult[0] = 1
checkAdmission = proc(p: pointer): bool = chan_is_tx_allowed(p)
chan_goto_idle_cb()
doAssert env.scanDelayCount == 0 and lastPhy() == 3
"""
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    run_nim(tmp_path, protection_source(PLATFORM + PRE_SWITCH_PLATFORM + forward)
            + procedure(kernel, "chan_is_on_channel")
            + procedure(kernel, "chan_is_tx_allowed") + callback_bodies()
            + procedure(source, "chan_goto_idle_cb")
            + procedure(kernel, "chan_pre_switch_channel")
            + checks)


def test_protection_timeout_ignores_flushed_and_late_completions(tmp_path: Path) -> None:
    platform = PLATFORM.replace("var txResetEpoch: uint32", r"""
var
  txResetEpoch, frameEpoch: uint32
  trackedFrame: bool
  onResetDrain: proc()
""").replace("proc txlFrameCallbackCurrent(resetEpoch = txResetEpoch): bool = true",
             "proc txlFrameCallbackCurrent(resetEpoch = txResetEpoch): bool =\n"
             "  not trackedFrame or frameEpoch == resetEpoch")
    platform = platform.replace("  inc txResetEpoch\n  true", r"""
  inc txResetEpoch
  if onResetDrain != nil:
    let drain = onResetDrain
    onResetDrain = nil
    drain()
  true""")
    tasks = (FW / "task_handlers.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    support = r"""
const
  MACHW_TIMLO_REG = MACHW_BASE + 0x120
  MM_SCAN_CHANNEL_END_IND = 77'u16
proc chan_get_next_chan(): pointer = nil
proc chan_get_dominant_chan(): pointer = nil
proc chan_switch_start(p: pointer) = doAssert false
proc chanSwitchRetire(p: pointer) = doAssert false
proc chan_conn_less_delay_prog() = doAssert false
proc mm_back_to_host_idle() = doAssert false
proc deliverFrame(index: int; epoch: uint32) =
  let frame = sends[index]
  trackedFrame = true
  frameEpoch = epoch
  defer: trackedFrame = false
  cast[proc(p: pointer; status: uint32) {.cdecl.}](frame.callback)(
    cast[pointer](frame.token.uint), 0x40000000'u32)
"""
    checks = r"""
for flushDuringReset in [false, true]:
  reset()
  vifs[1].vifType = VIF_TYPE_AP
  chan_goto_idle_cb()
  let departed = txResetEpoch
  doAssert lastPhy() == -1 and sends.len == 2
  doAssert chanProtectionActive() and contexts[1].status == 3
  doAssert env.scanDelayCount == 1 and env.connlessDelayCount == 1
  if flushDuringReset:
    onResetDrain = proc() =
      doAssert txResetEpoch != departed
      deliverFrame(0, departed)
      deliverFrame(1, departed)
  chan_ctxt_op_evt(addr contexts[1])
  doAssert sends.len == 2 and not chanProtectionActive()
  doAssert env.currentCtxt == (addr contexts[1]) and env.scheduledCtxt == nil
  doAssert contexts[1].status == 4
  let beforeLate = events.len
  deliverFrame(0, departed)
  deliverFrame(1, departed)
  # Even a token replay without its original TX epoch cannot consume a ticket.
  deliverFrame(0, txResetEpoch)
  deliverFrame(1, txResetEpoch)
  doAssert events.len == beforeLate
  var retunes = 0
  for event in events:
    if event.kind == "phy": inc retunes
  doAssert retunes == 1 and lastPhy() == 1
"""
    forward = "proc chan_pre_switch_channel*() {.exportc, cdecl.}\n"
    code = protection_source(platform + PRE_SWITCH_PLATFORM + forward)
    code += callback_bodies() + procedure(tasks, "chan_goto_idle_cb")
    code += procedure(kernel, "chan_pre_switch_channel") + support
    code += procedure(kernel, "chanCtxtOpEvent") + procedure(kernel, "chan_ctxt_op_evt")
    run_program(tmp_path, "checked", code + checks)


def test_channel_operation_timer_contract(tmp_path: Path) -> None:
    platform = PLATFORM.replace(procedure(PLATFORM, "chan_upd_ctxt_status"), "")
    timer = r"""
const MACHW_TIMLO_REG = MACHW_BASE + 0x120
type Timer = object
  env: uint32
var
  timerStorage: Timer
  timerSets, timerClears: int
  expiry, now: uint32
  chanStatusGeneration: uint32
  chanCtxtEpochs: array[5, uint32]
proc chanCtxtOpTimer(): pointer = addr timerStorage
proc mmTimerAt(p: pointer): ptr Timer = cast[ptr Timer](p)
proc regRead(address: uint): uint32 = now
proc mm_timer_set(p: pointer; target: uint32) =
  doAssert p == addr timerStorage
  inc timerSets
  expiry = target
proc mm_timer_clear(p: pointer) =
  doAssert p == addr timerStorage
  inc timerClears
proc mmTimerSetLocked(p: pointer; target, callbackIrq: uint32) = mm_timer_set(p, target)
proc mmTimerClearLocked(p: pointer; callbackIrq: uint32) = mm_timer_clear(p)
"""
    checks = r"""
for stamp in [0'u32, 1000, 0xFFFFF060'u32, 0xFFFFE4A8'u32, 0xFFFFFFFE'u32]:
  for count in 0'u8 .. 3:
    for marker in 0'u8 .. 4:
      for state in 0'u8 .. 6:
        for slots in [0'u16, 4, 5, 50, 65535]:
          reset()
          now = stamp
          env.ctxtCount = count
          env.lastMacTime = 777
          contexts[marker].status = 1
          contexts[marker].schedSlot = slots
          contexts[marker].opSlot = slots
          timerSets = 0
          timerClears = 0
          timerStorage.env = 123
          chan_upd_ctxt_status(addr contexts[marker], state)
          var expectedStatus: uint8
          var expectedExpiry = 0'u32
          if state == 2:
            expectedStatus = 2
            expectedExpiry = stamp + (if count > 1: 7000'u32 else: 4000'u32)
          elif state == 4:
            if marker > 2 or (count > 1 and slots > 4):
              expectedStatus = 4
              expectedExpiry = stamp + (slots.uint32 shl 10)
            else:
              expectedStatus = 5
          else:
            expectedStatus = 3
          doAssert contexts[marker].status == expectedStatus
          let armed = expectedStatus in {2'u8, 4'u8}
          doAssert timerSets == armed.int
          doAssert timerClears == (not armed and expectedStatus != 3).int
          if timerSets != 0:
            doAssert expiry == expectedExpiry
            doAssert timerStorage.env == cast[uint32](cast[uint](addr contexts[marker]))
          else:
            doAssert timerStorage.env == 123
          let expectedLast = if state == 4 and marker <= 2 and count > 1 and slots > 4:
            stamp else: 777'u32
          doAssert env.lastMacTime == expectedLast
"""
    run_nim(tmp_path, platform + timer
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_upd_ctxt_status") + checks)
