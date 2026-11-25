"""Exercise the channel switch machine against the real Nim code.

The harness compiles channel_switch.nim and channel_protection.nim with the
production chan_switch_start, mm_force_idle_req_handler, chan_goto_idle_cb,
chan_sta_tx_cfm/chan_ap_tx_cfm, chan_pre_switch_channel, mm_back_to_host_idle,
chan_ctxt_add/del/link/unlink and the kernel list helpers. The kernel's sent
and saved queues are the real CoLists; `dispatch` plays ke_task_schedule for
TASK_MM and `idleInterrupt` the MAC idle event. `chanForceIdle` stands for
mm_force_idle_req: its TX reset runs `onDrain` with txResetActive set.
"""

from pathlib import Path
from textwrap import indent

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


HARNESS = r'''
{.pragma: wifiCtrl.}
const
  MAX_VIFS = 2
  MAX_CHAN_CTXT = 3
  STA_INFO_TAB_ENTRIES = 7
  TASK_MM = 0'u8
  TASK_NONE = 255'u8
  MM_IDLE = 0'u8
  MM_ACTIVE_STATE = 1'u8
  MM_GOING_TO_IDLE = 2'u8
  HW_ACTIVE = 3'u8
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint
  MM_FORCE_IDLE_REQ_MSG = 74'u16
  MM_SCAN_CHANNEL_START_IND = 75'u16
  MACHW_BASE = 0x24B00000'u
  MACHW_STATE_CNTRL_REG = 0x24B00038'u
  MACHW_TIMLO_REG = 0x24B00120'u
  VIF_TYPE_STA = 0'u8
  VIF_TYPE_AP = 2'u8
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  KeMsgHdr = object
    next: ptr KeMsgHdr
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  ChanCtxtDefView = object
    band, chanType: uint8
    primFreq, centerFreq1, centerFreq2: uint16
    txPower, phyEnvFlags: uint8
  ChanCtxtView = object
    link: CoListHdr
    channel: ChanCtxtDefView
    invalidMarker: uint8
    schedSlot, opSlot, tbttSlot: uint16
    status, contextIndexOrMarker, linkCount: uint8
  ChanEnvView = object
    freeList, activeList, tbttList: CoList
    currentCtxt, scheduledCtxt, dominantCtxt: pointer
    slotPeriod, cdeStarted, lastMacTime: uint32
    flags, scanDelayCount, connlessDelayCount, switchPending: uint8
    ctxtCount, schedState, surveySnapshot: uint8
  TbttNode = object
    hdr: CoListHdr
    state: uint8
  Vif = object
    next: pointer
    chanCtxt, postponedStaHead: pointer
    tbttNode: TbttNode
    vifIdx, vifType, state, staIdx: uint8
  TdEntryView = object
    endActive: uint8
  Frame = tuple[callback: pointer; token: uint32; ap: bool; index: uint8; duration: uint16;
                sourceStatus: uint8]
var
  keMsgQueueSent, keMsgQueueSaved: CoList
  channelEnv: ChanEnvView
  chan_ctxt_pool: array[5, ChanCtxtView]
  chanCtxtEpochs: array[5, uint32]
  chanCtxtLinkEpochs: array[MAX_VIFS, uint32]
  vifs: array[MAX_VIFS, Vif]
  mgmt: tuple[activeList: CoList]
  ps: tuple[enabled: uint8, statusFlags: uint32]
  mm: tuple[idleFlag, hardwareMode, previousState: uint8]
  td_env: array[16, uint32]
  sm_reconn_dominant_flag: uint32
  txResetEpoch: uint32
  txResetActive: bool
  mmState: uint16
  macState, pmRegister, clock: uint32
  frames: seq[Frame]
  tuned: seq[pointer]
  notices, wakes: seq[uint16]
  nullResult, ctsResult: uint8
  synchronous, forceFailed: bool
  gates, forced, asserts, idleRequests, heapFrees, opClears: int
  onIdle, onDrain, onMmState, onSend, onFrame, onStatus, onRx, onActive: proc()
  nimFwDbgChanPreChanMeta, nimFwDbgChanPreChanFreq: uint32
proc invoke(hook: proc()) =
  if hook != nil: hook()
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc assert_err(cond, file: cstring; line: cint) = inc asserts
proc c_memset(p: pointer; value: cint; size: csize_t): pointer {.discardable.} =
  zeroMem(p, size.int)
  p
proc c_memcmp(a, b: pointer; size: csize_t): cint =
  if equalMem(a, b, size.int): 0 else: 1
template keMsgPayload(header: ptr KeMsgHdr): pointer =
  cast[pointer](cast[uint](header) + sizeof(KeMsgHdr).uint)
template keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc chanEnvView(): ptr ChanEnvView = addr channelEnv
proc chanCtxtAt(p: pointer): ptr ChanCtxtView = cast[ptr ChanCtxtView](p)
proc chanCtxtAt(p: uint): ptr ChanCtxtView = cast[ptr ChanCtxtView](p)
proc chanCtxtForIdx(index: uint8): ptr ChanCtxtView = addr chan_ctxt_pool[index]
template chanCtxtHdr(ctxt: ptr ChanCtxtView): ptr CoListHdr = cast[ptr CoListHdr](ctxt)
proc markInvalid(ctxt: ptr ChanCtxtView) =
  ctxt.invalidMarker = 0xFF
  ctxt.contextIndexOrMarker = 0xFF
proc chanTbttHdr(node: ptr TbttNode): ptr CoListHdr = addr node.hdr
proc chanTbttPrimaryList(): ptr CoList = addr channelEnv.tbttList
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifMgmtEnvView(): ptr typeof(mgmt) = addr mgmt
proc psEnvView(): ptr typeof(ps) = addr ps
proc mmEnvView(): ptr typeof(mm) = addr mm
proc tdEntryAt(p: pointer): ptr TdEntryView = cast[ptr TdEntryView](p)
proc chanCtxtOpTimer(): pointer = cast[pointer](0x4C)
proc mm_timer_clear(timer: pointer) = inc opClears
proc chan_ctxt_trigger(ctxt: pointer) = discard
proc chan_update_tx_power(ctxt: pointer) = discard
proc chan_tbtt_schedule(entry: pointer) = discard
proc smDeferredChannelUnlinked(vif: uint8) = discard
proc chan_cde_evt(param: pointer) = discard
proc chan_ctxt_op_evt(ctxt: pointer) = channelEnv.currentCtxt = nil
proc mmConfigCancelIdle() = discard
proc hal_machw_idle_req() = inc idleRequests
proc regRead(address: uint): uint32 =
  if address == MACHW_STATE_CNTRL_REG: macState
  elif address == MACHW_TIMLO_REG: clock
  else:
    doAssert address == MACHW_BASE + 0x4C
    pmRegister
proc regWrite(address: uint; value: uint32) =
  if address == MACHW_STATE_CNTRL_REG: macState = value
  elif address == MACHW_BASE + 0x4C: pmRegister = value
proc blmac_pwr_mgt_setf(value: uint32) =
  pmRegister = (pmRegister and not 4'u32) or (value shl 2)
proc packChannelMeta(channel: ptr ChanCtxtDefView): uint32 = 0
proc packChannelFreq(channel: ptr ChanCtxtDefView): uint32 = 0
proc rxl_timer_int_handler() = invoke(onRx)
proc rxl_cntrl_evt() = discard
proc phySetChannel(channel: ptr ChanCtxtDefView) =
  tuned.add(cast[pointer](cast[uint](channel) - offsetof(ChanCtxtView, channel).uint))
proc tpc_update_tx_power(power: uint8) = discard
proc rfPhyTraceCheckpoint(value: uint32) = discard
proc waitRfUs(value: uint32) = discard
proc mmReplayEdca() = discard
proc smDeferredPublish(vif: pointer) = discard
proc vif_mgmt_send_postponed_frame(vif: pointer) = discard
proc scanDwellPublish(id: uint16; slot: uint32) = notices.add(id)
proc chanHomeWakeRequest(vif: pointer; home: uint8) = wakes.add(home.uint16)
proc chan_conn_less_delay_prog() =
  if (channelEnv.flags and 0x10) != 0: return
  channelEnv.flags = channelEnv.flags or 0x10
  inc gates
proc chan_upd_ctxt_status(p: pointer; status: uint8) =
  chanCtxtAt(p).status = status
  invoke(onStatus)
proc mm_active() =
  macState = 0x33
  mmState = MM_ACTIVE_STATE
  rescheduleMm()
  invoke(onActive)
'''

KERNEL_PROCS = ["co_list_push_back", "co_list_pop_front", "co_list_extract", "ke_queue_extract",
                "chan_ctxt_add", "chan_ctxt_del", "chan_ctxt_link", "chan_ctxt_unlink",
                "mm_back_to_host_idle"]
TASK_PROCS = ["chan_switch_start", "mm_force_idle_req_handler", "chan_ap_tx_cfm",
              "chan_sta_tx_cfm", "chan_goto_idle_cb"]


def source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    code = HARNESS.replace("proc mm_active() =", "proc rescheduleMm()\nproc mm_active() =", 1)
    for name in KERNEL_PROCS[:4]:
        code += procedure(kernel, name)
    code += r'''
proc ke_msg_free(header: pointer)
proc mm_back_to_host_idle*() {.exportc, cdecl.}
proc chanSwitchForget(header: pointer): bool
proc chan_pre_switch_channel*() {.exportc, cdecl.}
proc chan_goto_idle_cb*() {.exportc, cdecl.}
proc chan_sta_tx_cfm*(param: pointer, status: uint32) {.exportc, cdecl.}
proc chan_ap_tx_cfm*(param: pointer, status: uint32) {.exportc, cdecl.}
proc chan_switch_start*(chanCtxt: pointer) {.exportc, cdecl.}
proc rescheduleMm() =
  ## ke_state_set: MM's saved messages go back to the sent queue.
  proc toMm(node: ptr CoListHdr; unused: pointer): bool {.cdecl.} =
    cast[ptr KeMsgHdr](node).destId == TASK_MM
  while true:
    let node = ke_queue_extract(addr keMsgQueueSaved, toMm, nil)
    if node == nil: break
    co_list_push_back(addr keMsgQueueSent, node)
proc ke_state_get(task: uint8): uint16 =
  doAssert task == TASK_MM
  mmState
proc ke_state_set(task: uint8; value: uint16) =
  doAssert task == TASK_MM
  let changed = mmState != value
  mmState = value
  invoke(onMmState)
  if changed: rescheduleMm()
proc ke_msg_send(p: pointer) =
  co_list_push_back(addr keMsgQueueSent, cast[ptr CoListHdr](keMsgHdrFromPayload(p)))
  invoke(onSend)
proc ke_msg_free(header: pointer) =
  if chanSwitchForget(header): return
  inc heapFrees
  dealloc(header)
proc chanForceIdle(): bool =
  ## mm_force_idle_req: MAC reset, then txl_reset's drain, then HW_ACTIVE.
  inc forced
  inc txResetEpoch
  txResetActive = true
  invoke(onDrain)
  txResetActive = false
  invoke(onIdle)
  if forceFailed: return false
  macState = 0
  ke_state_set(TASK_MM, HW_ACTIVE)
  true
proc sendFrame(callback: pointer; token: uint32; ap: bool; index: uint8; duration: uint16;
               refused: uint8): uint8 =
  let current = channelEnv.currentCtxt
  frames.add((callback, token, ap, index, duration,
              if current == nil: 0'u8 else: chanCtxtAt(current).status))
  invoke(onFrame)
  if refused == 0 and synchronous:
    cast[proc(p: pointer; status: uint32) {.cdecl.}](callback)(cast[pointer](token.uint), 0)
  refused
proc txl_frame_send_null_frame(index: uint8; callback: pointer; arg: uint32): uint8 =
  sendFrame(callback, arg, false, index, 0, nullResult)
proc txl_frame_send_selfcts_frame(vif: pointer; duration: uint16; callback: pointer;
                                  arg: uint32): uint8 =
  sendFrame(callback, arg, true, vifChannelAt(vif).vifIdx, duration, ctsResult)
'''
    code += (FW / "channel_switch.nim").read_text()
    code += (FW / "channel_protection.nim").read_text()
    for name in KERNEL_PROCS[4:]:
        code += procedure(kernel, name)
    code += procedure(kernel, "chan_pre_switch_channel")
    for name in TASK_PROCS:
        code += procedure(tasks, name)
    return code + r'''
proc queuedRequests(queue: CoList): int =
  var node = queue.first
  while node != nil:
    inc result
    node = node.next
proc dispatch(): bool =
  ## ke_task_schedule for TASK_MM: run one queued message.
  let node = co_list_pop_front(addr keMsgQueueSent)
  if node == nil: return false
  let header = cast[ptr KeMsgHdr](node)
  doAssert header.id == MM_FORCE_IDLE_REQ_MSG and header.destId == TASK_MM
  case mm_force_idle_req_handler(keMsgPayload(header))
  of KeMsgConsumed: ke_msg_free(header)
  of KeMsgSaved: co_list_push_back(addr keMsgQueueSaved, node)
  else: discard
  true
proc idleInterrupt() =
  ## mm_hw_idle_evt: the MAC reached idle.
  if mmState == MM_GOING_TO_IDLE:
    macState = 0
    ke_state_set(TASK_MM, MM_IDLE)
proc settle() =
  ## Run MM until nothing is queued and no idle transition is pending.
  for round in 0 ..< 8:
    while dispatch(): discard
    if mmState != MM_GOING_TO_IDLE: break
    idleInterrupt()
proc completeFrame(index: int; status = 0'u32) =
  let frame = frames[index]
  cast[proc(p: pointer; status: uint32) {.cdecl.}](frame.callback)(
    cast[pointer](frame.token.uint), status)
proc resetChannels() =
  channelEnv = default(ChanEnvView)
  chan_ctxt_pool = default(typeof(chan_ctxt_pool))
  for epoch in chanCtxtEpochs.mitems: inc epoch
  for epoch in chanCtxtLinkEpochs.mitems: inc epoch
  for index in 0 ..< MAX_CHAN_CTXT:
    let context = addr chan_ctxt_pool[index]
    markInvalid(context)
    co_list_push_back(addr channelEnv.freeList, chanCtxtHdr(context))
  for index in 3 ..< 5:
    markInvalid(addr chan_ctxt_pool[index])
proc resetSwitch() =
  chanSwitchReset()
  doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
  resetChannels()
  vifs = default(typeof(vifs))
  for index in 0'u8 ..< MAX_VIFS.uint8: vifs[index].vifIdx = index
  mgmt = default(typeof(mgmt))
  ps = default(typeof(ps))
  mm = default(typeof(mm))
  mmState = MM_IDLE
  macState = 0
  pmRegister = 0
  frames.setLen(0)
  tuned.setLen(0)
  notices.setLen(0)
  wakes.setLen(0)
  nullResult = 0
  ctsResult = 0
  synchronous = false
  forceFailed = false
  txResetActive = false
  gates = 0
  forced = 0
  asserts = 0
  idleRequests = 0
  heapFrees = 0
  opClears = 0
  onIdle = nil
  onDrain = nil
  onMmState = nil
  onSend = nil
  onFrame = nil
  onStatus = nil
  onRx = nil
  onActive = nil
proc newTarget(freq = 2412'u16): pointer =
  var definition = ChanCtxtDefView(primFreq: freq, centerFreq1: freq)
  var index: uint8
  doAssert chan_ctxt_add(addr definition, addr index) == 0
  cast[pointer](chanCtxtForIdx(index))
proc slot(p: pointer): uint8 = chanCtxtAt(p).contextIndexOrMarker
proc linkHome(home: pointer; role: uint8; index = 0'u8) =
  let vif = vifChannelForIdx(index)
  vif.vifType = role
  vif.state = 1
  vif.staIdx = index
  vif.chanCtxt = nil
  chan_ctxt_link(index, slot(home))
  doAssert vif.chanCtxt == home
proc activateVifs(count: int) =
  ## Put the first `count` VIFs on the active list.
  mgmt.activeList.first = if count > 0: cast[ptr CoListHdr](addr vifs[0]) else: nil
  vifs[0].next = if count > 1: addr vifs[1] else: nil
  vifs[1].next = nil
proc operate(home: pointer) =
  ## MM active on `home`.
  channelEnv.currentCtxt = home
  chanCtxtAt(home).status = 5
  mmState = MM_ACTIVE_STATE
  macState = 0x33
proc requestLinked(): bool =
  var node = keMsgQueueSent.first
  while node != nil:
    if node == cast[ptr CoListHdr](addr chanSwitchRequest.header): return true
    node = node.next
  node = keMsgQueueSaved.first
  while node != nil:
    if node == cast[ptr CoListHdr](addr chanSwitchRequest.header): return true
    node = node.next
proc idleSwitch(): bool =
  chanSw.phase == swNone and channelEnv.scheduledCtxt == nil and
    channelEnv.switchPending == 0 and channelEnv.scanDelayCount == 0 and
    channelEnv.connlessDelayCount == 0
proc finishSwitch() =
  settle()
  doAssert mmState != HW_ACTIVE
  chanSwitchReset()
  doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
'''


def run_case(tmp_path: Path, body: str, mode: str = "checked", code: str = "") -> None:
    run_program(tmp_path, mode, source() + code + "\nblock:\n" + indent(body, "  "))


CASES = {
    "start_and_arrive": r'''
for saved in [false, true]:
  resetSwitch()
  let home = newTarget(2412)
  let away = newTarget(2437)
  if saved: operate(home)
  chan_switch_start(away)
  doAssert channelEnv.scheduledCtxt == away and chanCtxtAt(away).status == 2
  doAssert channelEnv.switchPending == 1 and chanSw.phase == swQueued
  doAssert queuedRequests(keMsgQueueSent) == 1 and requestLinked()
  doAssert dispatch()
  if saved:
    # MM was active: the request waits for the MAC to go idle.
    doAssert mmState == MM_GOING_TO_IDLE and idleRequests == 1
    doAssert queuedRequests(keMsgQueueSaved) == 1
    idleInterrupt()
    doAssert dispatch()
  doAssert tuned == @[away] and channelEnv.currentCtxt == away
  doAssert idleSwitch() and mmState == MM_ACTIVE_STATE and forced == 1
  doAssert not requestLinked() and not chanSwitchRequestQueued and heapFrees == 0
  finishSwitch()
''',
    "single_flight": r'''
resetSwitch()
let a = newTarget(2412)
let b = newTarget(2437)
let c = newTarget(2462)
operate(a)
channelEnv.ctxtCount = 2
chan_switch_start(b)
let statusC = chanCtxtAt(c).status
for other in [c, b]:
  chan_switch_start(other)
  doAssert channelEnv.scheduledCtxt == b and queuedRequests(keMsgQueueSent) == 1
doAssert chanCtxtAt(c).status == statusC
chan_switch_start(a)                 # the current context only restarts its dwell
doAssert chanCtxtAt(a).status == 4 and channelEnv.scheduledCtxt == b
settle()
doAssert channelEnv.currentCtxt == b and idleSwitch()
chan_switch_start(c)
settle()
doAssert channelEnv.currentCtxt == c and tuned == @[b, c]
finishSwitch()
''',
    "invalid_target": r'''
resetSwitch()
chan_switch_start(nil)
chan_switch_start(cast[pointer](chanCtxtForIdx(1)))   # never allocated
chan_switch_start(cast[pointer](chanCtxtForIdx(3)))   # scan slot not in use
doAssert idleSwitch() and keMsgQueueSent.first == nil
finishSwitch()
''',
    "abandoned_queued_switch_gives_mm_back": r'''
for hostIdle in [false, true]:
  for retireWhileSaved in [false, true]:
    resetSwitch()
    let home = newTarget(2412)
    linkHome(home, VIF_TYPE_STA)
    let away = newTarget(2437)
    operate(home)
    mm.idleFlag = hostIdle.uint8
    chan_switch_start(away)
    if retireWhileSaved:
      doAssert dispatch() and mmState == MM_GOING_TO_IDLE
    chan_ctxt_del(slot(away))
    doAssert idleSwitch() and channelEnv.currentCtxt == home
    # The request stays queued; MM hands itself back when it runs.
    doAssert requestLinked()
    settle()
    doAssert tuned.len == 0 and forced == 0 and not requestLinked()
    doAssert mmState == (if hostIdle: MM_IDLE.uint16 else: MM_ACTIVE_STATE.uint16)
    finishSwitch()
''',
    "new_switch_reuses_queued_request": r'''
resetSwitch()
let home = newTarget(2412)
linkHome(home, VIF_TYPE_STA)
let away = newTarget(2437)
let other = newTarget(2462)
operate(home)
chan_switch_start(away)
doAssert dispatch() and queuedRequests(keMsgQueueSaved) == 1
chan_ctxt_del(slot(away))
chan_switch_start(other)
# Still one request, saved behind the pending idle transition.
doAssert queuedRequests(keMsgQueueSaved) == 1 and queuedRequests(keMsgQueueSent) == 0
settle()
doAssert tuned == @[other] and channelEnv.currentCtxt == other and idleSwitch()
finishSwitch()
''',
    "mac_busy_in_idle_keeps_request": r'''
resetSwitch()
let away = newTarget(2437)
chan_switch_start(away)
macState = 0x33                      # MM idle but the MAC is not
doAssert dispatch()
doAssert asserts == 1 and queuedRequests(keMsgQueueSaved) == 1 and mmState == MM_IDLE
doAssert chanSw.phase == swQueued and channelEnv.scheduledCtxt == away
# Recovery: the MAC is reset and MM's saved messages are rescheduled.
macState = 0
rescheduleMm()
settle()
doAssert tuned == @[away] and idleSwitch() and mmState == MM_ACTIVE_STATE
finishSwitch()
''',
    "failed_forced_idle_retries": r'''
for viaDeparture in [false, true]:
  resetSwitch()
  let home = newTarget(2412)
  linkHome(home, VIF_TYPE_STA)
  if viaDeparture: activateVifs(1)   # a PM null frame protects the departure
  let away = newTarget(2437)
  operate(home)
  chan_switch_start(away)
  if viaDeparture:
    settle()
    doAssert frames.len == 1 and chanSw.phase == swProtecting
  forceFailed = true
  if viaDeparture: completeFrame(0)
  else: settle()
  # The departure waits for MM again; MM is not left host-bypassed.
  doAssert chanSw.phase == (if viaDeparture: swDeparting else: swQueued)
  doAssert requestLinked() and mmState != HW_ACTIVE and tuned.len == 0
  forceFailed = false
  settle()
  doAssert tuned == @[away] and idleSwitch() and mmState == MM_ACTIVE_STATE
  finishSwitch()
''',
    "reset_drops_queued_and_saved_request": r'''
for saved in [false, true]:
  resetSwitch()
  let away = newTarget(2437)
  if saved: mmState = MM_ACTIVE_STATE
  chan_switch_start(away)
  if saved: doAssert dispatch() and queuedRequests(keMsgQueueSaved) == 1
  chanSwitchReset()
  doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
  doAssert idleSwitch() and not chanSwitchRequestQueued
  idleInterrupt()
  chan_switch_start(away)            # the request is sent again, once
  doAssert queuedRequests(keMsgQueueSent) == 1
  settle()
  doAssert channelEnv.currentCtxt == away and heapFrees == 0
  finishSwitch()
''',
    "dropped_request_abandons_switch": r'''
resetSwitch()
let away = newTarget(2437)
chan_switch_start(away)
let header = co_list_pop_front(addr keMsgQueueSent)
ke_msg_free(header)                  # never freed; its switch cannot proceed
doAssert heapFrees == 0 and idleSwitch() and not chanSwitchRequestQueued
doAssert chanCtxtAt(away).status == 1
chan_switch_start(away)
settle()
doAssert channelEnv.currentCtxt == away
finishSwitch()
''',
    "other_force_idle_requests": r'''
resetSwitch()
var calls = 0
proc legacy() {.cdecl.} = inc calls
let request = cast[ptr KeMsgHdr](alloc0(sizeof(KeMsgHdr) + 8))
request[] = KeMsgHdr(id: MM_FORCE_IDLE_REQ_MSG, destId: TASK_MM, srcId: TASK_NONE, paramLen: 4)
cast[ptr pointer](keMsgPayload(request))[] = cast[pointer](legacy)
ke_msg_send(keMsgPayload(request))
settle()
doAssert calls == 1 and heapFrees == 1 and mmState == HW_ACTIVE
doAssert mm_force_idle_req_handler(nil) == KeMsgConsumed
mmState = MM_IDLE
finishSwitch()
''',
    "retired_source_keeps_switch": r'''
resetSwitch()
let home = newTarget(2412)
let away = newTarget(2437)
operate(home)
chan_switch_start(away)
chan_ctxt_del(slot(home))
doAssert channelEnv.currentCtxt == nil and channelEnv.scheduledCtxt == away
settle()
doAssert tuned == @[away] and channelEnv.currentCtxt == away and idleSwitch()
finishSwitch()
''',
    "unlinked_destination_redirects_to_remaining": r'''
resetSwitch()
let home = newTarget(2412)
let away = newTarget(2437)
linkHome(home, VIF_TYPE_STA, 0)
linkHome(away, VIF_TYPE_AP, 1)
operate(home)
chan_switch_start(away)
chan_ctxt_unlink(1)                  # vendor: scheduledCtxt := the remaining context
doAssert channelEnv.scheduledCtxt == home and chanSw.phase == swQueued
settle()
doAssert channelEnv.currentCtxt == home and idleSwitch() and mmState == MM_ACTIVE_STATE
finishSwitch()
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "asan"])
def test_switch_request_lifetime(tmp_path: Path, case: str, mode: str) -> None:
    run_case(tmp_path, CASES[case], mode)


def test_switch_release_and_reset_hooks() -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    assert "if chanSwitchForget(param): return" in procedure(kernel, "ke_msg_free")
    assert "chanSwitchForget" not in procedure(kernel, "ke_msg_send")
    for name in ["ke_init", "ke_flush", "chan_init"]:
        assert "chanSwitchReset()" in procedure(kernel, name)
    assert "chanSwitchRetire(cast[pointer](ctxt))" in procedure(kernel, "chan_ctxt_del")
