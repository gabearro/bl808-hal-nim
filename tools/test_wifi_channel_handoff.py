"""Run channel protection-frame handoff and completion barriers on the host."""

from pathlib import Path

from test_wifi_deferred_auth import run_nim
from test_wifi_disconnect_tx import FW, procedure


PLATFORM = r"""
proc smDeferredPublish(vifEntry: pointer) = discard
proc txlFrameCallbackCurrent(): bool = true
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
    status, contextIndexOrMarker, altIdx: uint8
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
proc mm_force_idle_req(): bool =
  events.add(("idle", 0'u))
  true
proc mm_active() = events.add(("active", 0'u))
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
proc chanSwitchContextCurrent(context: ChanSwitchContext): bool = context.captured
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
    run_nim(tmp_path, PLATFORM + stubs
            + procedure((FW / "task_handlers.nim").read_text(), "chan_switch_start") + checks)


PRE_SWITCH_PLATFORM = r"""
proc chanCtxtOpTimer(): pointer = cast[pointer](76)
proc mm_timer_clear(p: pointer) = events.add(("timer-clear", cast[uint](p)))
proc packChannelMeta(p: ptr Channel): uint32 = 0
proc packChannelFreq(p: ptr Channel): uint32 = 0
proc rxl_timer_int_handler() = discard
proc rxl_cntrl_evt() = discard
proc phySetChannel(p: ptr Channel) =
  for i in 0 ..< contexts.len:
    if p == addr contexts[i].channel: events.add(("phy", i.uint))
proc tpc_update_tx_power(value: uint8) = discard
proc regWrite(address: uint; value: uint32) = discard
proc regRead(address: uint): uint32 = 0
proc rfPhyTraceCheckpoint(value: uint32) = discard
proc rfPriPrepareWb03MacActiveScanState() = discard
proc waitRfUs(value: uint32) = discard
proc ke_msg_send_basic(id: uint16; dest, src: uint8) = events.add(("basic", id.uint))
proc co_list_cnt(p: ptr CoList): uint32 = 3
proc vif_mgmt_send_postponed_frame(p: pointer) = discard
proc chan_cde_evt(p: pointer) = env.scheduledCtxt = cdeTarget
proc lastPhy(): int =
  result = -1
  for event in events:
    if event.kind == "phy": result = event.value.int
"""


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
  chanStatusGeneration, txResetEpoch: uint32
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
          doAssert timerSets == (expectedExpiry != 0).int
          doAssert timerClears == (expectedExpiry == 0 and expectedStatus != 3).int
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
