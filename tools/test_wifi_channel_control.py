"""Run production channel-control paths against explicit vendor invariants."""

from pathlib import Path

from test_wifi_deferred_auth import run_nim
from test_wifi_disconnect_tx import FW, procedure


PLATFORM = r"""
const MAX_CHAN_CTXT = 3
const MAX_VIFS = 2
var chanCtxtEpochs: array[5, uint32]
var txResetEpoch: uint32
var chanCtxtLinkEpochs: array[MAX_VIFS, uint32]
proc smDeferredCancel() = discard
proc smDeferredChannelUnlinked(vifIndex: uint8) = discard
proc chanSwitchCancel(target: pointer = nil) = discard
proc chanSwitchRetire(target: pointer) = discard
proc chanBcnRequestReset() = discard
proc scanDwellReset() = discard
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  ChanCtxtView = object
    hdr: CoListHdr
    channel: array[10, uint8]
    status, contextIndexOrMarker, linkCount, invalidMarker: uint8
    opSlot: uint16
  TbttNode = object
    hdr: CoListHdr
    state: uint8
  Vif = object
    chanCtxt: pointer
    tbttNode: TbttNode
  ChanEnvView = object
    freeList, activeList, tbttList: CoList
    currentCtxt, scheduledCtxt, dominantCtxt, scanCtxt: pointer
    flags, ctxtCount, schedState, timerState: uint8
    switchPending, scanDelayCount, connlessDelayCount, surveySnapshot: uint8
    slotPeriod, lastMacTime, cdeStarted: uint32
    deferredMsg: pointer
    tbttSwitchCallback, cdeCallback, cdeArg, ctxtOpCallback, connLessDelayCallback: pointer
  Event = tuple[kind: string, value: uint]
var
  env: ChanEnvView
  contexts: array[5, ChanCtxtView]
  vif: Vif
  events: seq[Event]
  deleted: array[5, bool]
  chan_env: array[256, uint8]
  chan_ctxt_pool: array[5, ChanCtxtView]
  chanCtxtCount, chanCtxtFlags: uint8
  chanCurrentCtxt, chanPendingCtxt: pointer
  chanConflictCount, chanEnvTimerTarget: uint32
  chanSlotConfigCycles: uint8
  chanConflictDetected, chanScanPending: bool
  cde_evt_tmr_msg: uint8
  sm_reconn_dominant_flag: uint32
const
  MACHW_BASE = 0x24B00000'u
  MACHW_TIMLO_REG = MACHW_BASE + 0x120
var clockValue = 1000'u32
proc chanEnvView(): ptr ChanEnvView = addr env
proc chanCtxtForIdx(i: uint8): ptr ChanCtxtView = addr contexts[i]
proc chanCtxtAt(p: pointer): ptr ChanCtxtView = cast[ptr ChanCtxtView](p)
proc chanCtxtAt(p: uint): ptr ChanCtxtView = cast[ptr ChanCtxtView](p)
proc chanCtxtHdr(p: ptr ChanCtxtView): ptr CoListHdr = addr p.hdr
proc chanTbttHdr(p: ptr TbttNode): ptr CoListHdr = addr p.hdr
proc chanTbttPrimaryList(): ptr CoList = addr env.tbttList
proc vifChannelForIdx(i: uint8): ptr Vif = addr vif
proc chanTbttSwitchTimer(): pointer = cast[pointer](48)
proc chanCdeTimer(): pointer = cast[pointer](60)
proc chanCtxtOpTimer(): pointer = cast[pointer](76)
proc c_memset(dst: pointer; byte: cint; size: csize_t): pointer =
  zeroMem(dst, size.int)
  dst
proc markInvalid(p: ptr ChanCtxtView) =
  p.invalidMarker = 0xFF
  p.contextIndexOrMarker = 0xFF
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  node.next = nil
  if list.last == nil: list.first = node
  else: list.last.next = node
  list.last = node
proc co_list_extract(list: ptr CoList; node: ptr CoListHdr) =
  var previous: ptr CoListHdr
  var current = list.first
  while current != nil:
    if current == node:
      if previous == nil: list.first = current.next
      else: previous.next = current.next
      if list.last == current: list.last = previous
      return
    previous = current
    current = current.next
proc assert_err(a, b: cstring; line: int) = doAssert false, "unexpected channel invariant failure"
proc mm_timer_clear(timer: pointer) = events.add(("clear", cast[uint](timer)))
proc mm_timer_set(timer: pointer; expiry: uint32) =
  events.add(("timer", cast[uint](timer)))
  events.add(("expiry", expiry.uint))
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  clockValue
proc chan_tbtt_schedule(p: pointer) =
  doAssert p == nil
  events.add(("tbtt", 0'u))
proc chan_update_tx_power(p: pointer) = events.add(("power", cast[uint](p)))
proc chan_ctxt_del(index: uint8) =
  doAssert contexts[index].linkCount == 0
  doAssert not deleted[index]
  deleted[index] = true
  events.add(("delete", index.uint))
  contexts[index].status = 0
  contexts[index].contextIndexOrMarker = 0xFF
proc chan_distribute_slots() = events.add(("distribute", 0'u))
var nextChannel: pointer
proc chan_get_next_chan(): pointer =
  events.add(("next", 0'u))
  nextChannel
proc chan_switch_start(p: pointer) = events.add(("switch", cast[uint](p)))
proc reset() =
  env = default(ChanEnvView)
  contexts = default(typeof(contexts))
  for i in 0 ..< contexts.len:
    contexts[i].contextIndexOrMarker = i.uint8
  vif = default(Vif)
  events.setLen(0)
  deleted = default(typeof(deleted))
  chanConflictCount = 0
  chanEnvTimerTarget = 0x1234
  sm_reconn_dominant_flag = 0
  nextChannel = addr contexts[1]
  clockValue = 1000
"""

UNLINK_STUBS = r"""
proc chan_cde_evt(p: pointer = nil) =
  events.add(("cde", if p == nil: 255'u else: cast[ptr uint8](p)[].uint))
proc chan_ctxt_op_evt(p: pointer = nil) =
  doAssert p == (addr contexts[0]), "unlink must pass the retiring context"
  doAssert not deleted[0] and contexts[0].status == 4,
    "operation callback must run while the context is still live"
  events.add(("op", cast[uint](p)))
"""

UNLINK_CHECKS = r"""
for count in 1'u8 .. 3:
  for links in 1'u8 .. 2:
    for schedule in 0 .. 2:
      for current in 0 .. 2:
        for dominant in [false, true]:
          reset()
          let retiring = addr contexts[0]
          retiring.linkCount = links
          retiring.status = 1
          env.ctxtCount = count
          env.slotPeriod = 0xC800'u32 * count.uint32
          env.flags = 0xFF
          env.cdeStarted = 1
          env.schedState = 1
          env.dominantCtxt = addr contexts[2]
          env.scanCtxt = env.dominantCtxt
          env.deferredMsg = cast[pointer](0x12345678)
          sm_reconn_dominant_flag = dominant.uint32
          for i in 0 ..< count.int:
            co_list_push_back(addr env.activeList, addr contexts[i].hdr)
          co_list_push_back(addr env.tbttList, addr vif.tbttNode.hdr)
          vif.chanCtxt = retiring
          vif.tbttNode.state = 1
          env.scheduledCtxt = case schedule
            of 0: nil
            of 1: cast[pointer](retiring)
            else: cast[pointer](addr contexts[4])
          env.currentCtxt = case current
            of 0: nil
            of 1: cast[pointer](retiring)
            else: cast[pointer](addr contexts[4])
          chan_ctxt_unlink(0)
          let last = links == 1
          let remaining = count - last.uint8
          doAssert env.ctxtCount == remaining
          doAssert env.slotPeriod == 0xC800'u32 * (count.uint32 - 1)
          doAssert vif.chanCtxt == nil and vif.tbttNode.state == 0
          doAssert env.tbttList.first == nil
          doAssert env.deferredMsg == cast[pointer](0x12345678)
          var expected: seq[Event]
          if last:
            if schedule == 0 and current == 1:
              expected.add(("clear", 76'u))
              expected.add(("op", cast[uint](retiring)))
            elif schedule == 1 and remaining > 1:
              expected.add(("cde", 1'u))
            expected.add(("delete", 0'u))
          expected.add(("tbtt", 0'u))
          expected.add(("power", cast[uint](retiring)))
          doAssert events == expected, "unlink callback order/conditions"
          doAssert deleted[0] == last
          doAssert env.flags == 0x7F
          if remaining == 1:
            doAssert env.cdeStarted == 0 and env.schedState == 0
            doAssert env.dominantCtxt == (if dominant: nil else: addr contexts[2])
          else:
            doAssert env.cdeStarted == 1 and env.schedState == 1
          if last and schedule == 1 and remaining == 1:
            doAssert env.scheduledCtxt == addr contexts[1]

for links in 1'u8 .. 2:
  reset()
  contexts[0].linkCount = links
  contexts[0].status = 0
  vif.chanCtxt = addr contexts[0]
  env.ctxtCount = 2
  env.slotPeriod = 0x123400
  chan_ctxt_unlink(0)
  doAssert env.ctxtCount == 2 and env.slotPeriod == 0x123400
  doAssert deleted[0] == (links == 1)
  doAssert events[^2..^1] == @[("tbtt", 0'u), ("power", cast[uint](addr contexts[0]))]

for invalid in [MAX_VIFS.uint8, 255'u8]:
  reset()
  vif.chanCtxt = addr contexts[0]
  contexts[0].linkCount = 1
  chan_ctxt_unlink(invalid)
  doAssert vif.chanCtxt == (addr contexts[0]) and contexts[0].linkCount == 1
  doAssert events.len == 0 and env.ctxtCount == 0
"""


def test_collision_counter_preserves_deferred_tx(tmp_path: Path) -> None:
    layout = (FW / "layout_types.nim").read_text()
    helper = layout.split("template chanTbttConflictCounter", 1)[1].split("\ntemplate ", 1)[0]
    checks = r"""
reset()
env.deferredMsg = cast[pointer](0x12345678)
doAssert chan_tbtt_detect_conflict(1000, 1000)
doAssert env.deferredMsg == cast[pointer](0x12345678),
  "TBTT collision counter must not overwrite a queued auth/assoc pointer"
doAssert chanConflictCount == 3 and env.schedState == 1 and env.flags == 0x80
for left in countdown(2, 0):
  doAssert not chan_tbtt_detect_conflict(50000, 0)
  doAssert chanConflictCount == left.uint32
  doAssert env.deferredMsg == cast[pointer](0x12345678)
doAssert env.flags == 0
"""
    run_nim(tmp_path, PLATFORM + "template chanTbttConflictCounter" + helper
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_tbtt_detect_conflict") + checks)


def test_channel_unlink_callback_order(tmp_path: Path) -> None:
    run_nim(tmp_path, PLATFORM + UNLINK_STUBS
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_ctxt_unlink")
            + UNLINK_CHECKS)


def test_cde_timer_and_first_activation(tmp_path: Path) -> None:
    support = """
var chanCdeGeneration: uint32
proc irqSave(): uint32 = 0
proc irqRestore(value: uint32) = discard
"""
    checks = r"""
for count in 0'u8 .. 3:
  for state in [0'u8, 1, 2, 3, 255]:
    for flags in [0'u8, 4, 8, 12, 0x80]:
      for started in [0'u32, 1, 0x1234]:
        for scheduled in 0 .. 2:
          reset()
          env.ctxtCount = count
          env.flags = flags
          env.cdeStarted = started
          env.lastMacTime = 777
          env.slotPeriod = 250
          contexts[0].status = 3
          contexts[1].status = 1
          env.scheduledCtxt = case scheduled
            of 0: nil
            of 1: cast[pointer](addr contexts[0])
            else: cast[pointer](addr contexts[1])
          let before = env
          var event = state
          chan_cde_evt(addr event)
          let active = count > 1 and (state == 0 or
            (state in [1'u8, 2] and (flags and 12) == 0))
          var expected: seq[Event]
          if active:
            if state == 0 or started == 0:
              expected.add(("timer", 60'u))
              expected.add(("expiry", 1250'u))
            expected.add(("distribute", 0'u))
            if state != 0:
              expected.add(("next", 0'u))
              if state == 2 and scheduled == 0:
                expected.add(("switch", cast[uint](addr contexts[1])))
              doAssert env.cdeStarted == (if started == 0: 1'u32 else: started)
              doAssert env.lastMacTime == clockValue
              if state == 1 or (state == 2 and scheduled != 0):
                doAssert env.scheduledCtxt == addr contexts[1]
              else:
                doAssert env.scheduledCtxt == nil
              if state == 2 and scheduled == 1:
                doAssert contexts[0].status == 1 and contexts[1].status == 3
          else:
            doAssert env == before
          doAssert events == expected, "CDE timer or first-event fallthrough"
reset()
chan_cde_evt(nil)
doAssert events.len == 0
"""
    run_nim(tmp_path, PLATFORM + support
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_cde_evt") + checks)


def test_channel_init_owns_timer_event_byte(tmp_path: Path) -> None:
    stubs = r"""
proc chan_tbtt_switch_evt(p: pointer) = discard
proc chan_conn_less_delay_evt() = discard
"""
    checks = r"""
reset()
let previousAllocations = chanCtxtEpochs
let previousBindings = chanCtxtLinkEpochs
chan_init()
for index in 0..<MAX_CHAN_CTXT:
  doAssert chanCtxtEpochs[index] == previousAllocations[index] + 1
for index in 0..<MAX_VIFS:
  doAssert chanCtxtLinkEpochs[index] == previousBindings[index] + 1
doAssert env.cdeArg == (addr cde_evt_tmr_msg)
doAssert env.cdeArg != (addr env.deferredMsg)
doAssert env.cdeCallback == cast[pointer](chan_cde_evt)
doAssert env.ctxtOpCallback == cast[pointer](chan_ctxt_op_evt)
doAssert env.deferredMsg == nil
var node = env.freeList.first
var count = 0
while node != nil:
  doAssert node == addr chan_ctxt_pool[count].hdr
  inc count
  node = node.next
doAssert count == 3
for ctxt in chan_ctxt_pool:
  doAssert ctxt.invalidMarker == 0xFF and ctxt.contextIndexOrMarker == 0xFF
"""
    run_nim(tmp_path, PLATFORM + UNLINK_STUBS + stubs
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_init") + checks)


def test_channel_timer_addresses(tmp_path: Path) -> None:
    layout = (FW / "layout_types.nim").read_text()
    code = "var chan_env: array[256, uint8]\n"
    for name in ["chanTimerAt", "chanTbttTimer", "chanTbttSwitchTimer", "chanCdeTimer",
                 "chanCtxtOpTimer", "chanConnLessDelayTimer"]:
        code += "template " + name + layout.split("template " + name, 1)[1].split("\n\n", 1)[0] + "\n"
    code += r"""
let base = cast[uint](addr chan_env[0])
doAssert cast[uint](chanTbttTimer()) - base == 0x2C
doAssert cast[uint](chanTbttSwitchTimer()) - base == 0x2C
doAssert cast[uint](chanCdeTimer()) - base == 0x3C
doAssert cast[uint](chanCtxtOpTimer()) - base == 0x4C
doAssert cast[uint](chanConnLessDelayTimer()) - base == 0x5C
"""
    run_nim(tmp_path, code)


def test_dominant_channel_uses_shared_environment(tmp_path: Path) -> None:
    checks = r"""
for flag in [0'u32, 1, 0xFFFFFFFF'u32]:
  for dominant in [nil, cast[pointer](addr contexts[1])]:
    reset()
    sm_reconn_dominant_flag = flag
    env.dominantCtxt = dominant
    chanCurrentCtxt = cast[pointer](addr contexts[4])
    doAssert chan_get_dominant_chan() == (if flag == 0: nil else: dominant)
"""
    run_nim(tmp_path, PLATFORM
            + procedure((FW / "task_handlers.nim").read_text(), "chan_get_dominant_chan") + checks)


OP_STUBS = r"""
type PsEnv = object
  statusFlags: uint32
var ps: PsEnv
proc psEnvView(): ptr PsEnv = addr ps
proc irqSave(): uint32 =
  events.add(("lock", 0'u))
  8
proc irqRestore(mask: uint32) =
  doAssert mask == 8
  events.add(("unlock", 0'u))
proc blmac_pwr_mgt_setf(value: uint32) = events.add(("pm", value.uint))
proc chan_goto_idle_cb() = events.add(("goto-idle", 0'u))
proc chanProtectionCancel(p: pointer): pointer = nil
proc chan_conn_less_delay_prog() = events.add(("delay", 0'u))
const MM_SCAN_CHANNEL_END_IND = 77'u16
proc scanDwellPublish(id: uint16; slot: uint32) =
  doAssert id == MM_SCAN_CHANNEL_END_IND and slot == chanCtxtEpochs[3]
  events.add(("message", id.uint))
proc mm_force_idle_req(): bool =
  events.add(("force-idle", 0'u))
  inc txResetEpoch
  true
proc chanForceIdle(): bool = mm_force_idle_req()
proc mm_back_to_host_idle() = events.add(("host-idle", 0'u))
proc chan_cde_evt(p: pointer) = events.add(("cde", cast[ptr uint8](p)[].uint))
proc filterIrqEvents() =
  var observed: seq[Event]
  for event in events:
    if event.kind notin ["lock", "unlock"]: observed.add(event)
  events = observed
"""

OP_CHECKS = r"""
for count in [2'u8, 3]:
  for first in [false, true]:
    for delta in [0'u32, 1, 1023, 1024, 2048, 10240, 0xFFFFFFFF'u32]:
      for dominant in [false, true]:
        reset()
        env.ctxtCount = count
        env.lastMacTime = 0xFFFFFF00'u32
        clockValue = env.lastMacTime + delta
        env.dominantCtxt = if dominant: addr contexts[3] else: nil
        sm_reconn_dominant_flag = 1
        contexts[0].status = 4
        contexts[0].opSlot = 10
        contexts[0].hdr.next = addr contexts[1].hdr
        env.activeList.first = if first: addr contexts[0].hdr else: addr contexts[2].hdr
        chan_ctxt_op_evt(addr contexts[0])
        filterIrqEvents()
        let elapsedSlots = (delta shr 10) and 0xFFFF'u32
        let expectedSlots = if elapsedSlots < 10: 10'u16 - elapsedSlots.uint16 else: 0'u16
        doAssert contexts[0].opSlot == expectedSlots, "slot accounting uses 1024-us units"
        doAssert env.lastMacTime == clockValue
        doAssert contexts[0].status == 1
        let target = if count == 3: addr contexts[1]
          elif dominant: addr contexts[3]
          elif first: addr contexts[1]
          else: addr contexts[2]
        doAssert events[^1] == ("switch", cast[uint](target)), "dominant context overrides rotation"

for count in 0'u8 .. 1:
  reset()
  env.ctxtCount = count
  env.activeList.first = addr contexts[1].hdr
  contexts[0].status = 4
  chan_ctxt_op_evt(addr contexts[0])
  filterIrqEvents()
  doAssert contexts[0].status == 1
  doAssert events == @[("switch", cast[uint](addr contexts[1]))]

reset()
env.ctxtCount = 0
contexts[0].status = 4
chan_ctxt_op_evt(addr contexts[0])
filterIrqEvents()
doAssert contexts[0].status == 1
doAssert events == @[("switch", 0'u)]

for marker in [3'u8, 4, 5, 255]:
  for count in 0'u8 .. 3:
    for flags in [0'u8, 0xFF]:
      for pm in [0'u8, 1]:
        for invalid in [0'u8, 255]:
          reset()
          env.ctxtCount = count
          env.flags = flags
          env.surveySnapshot = pm
          let selected = if marker < 5: marker.int else: 0
          env.currentCtxt = addr contexts[selected]
          env.activeList.first = addr contexts[1].hdr
          ps.statusFlags = 0xA5A5FFFF'u32
          contexts[selected].status = 4
          contexts[selected].contextIndexOrMarker = marker
          contexts[selected].invalidMarker = invalid
          chan_ctxt_op_evt(addr contexts[selected])
          filterIrqEvents()
          if marker >= 5:
            doAssert events.len == 0 and env.currentCtxt == (addr contexts[selected])
            continue
          doAssert ps.statusFlags == 0xA5A5FFFD'u32, "release off-channel power-save prevention"
          doAssert env.currentCtxt == nil and contexts[selected].contextIndexOrMarker == 255
          var expectedFlags = flags and not 0x10'u8
          if marker == 3: expectedFlags = expectedFlags and not 0x08'u8
          if marker == 4:
            expectedFlags = expectedFlags and not 0x04'u8
            if invalid == 0: expectedFlags = expectedFlags and not 0x40'u8
          doAssert env.flags == expectedFlags
          var expected: seq[Event] = @[("pm", pm.uint)]
          if marker == 3: expected.add(("message", 77'u))
          if (flags and 3) != 0: expected.add(("delay", 0'u))
          case count
          of 1: expected.add(("switch", cast[uint](addr contexts[1])))
          of 2, 3: expected.add(("cde", 2'u))
          else:
            expected.add(("force-idle", 0'u))
            expected.add(("host-idle", 0'u))
          doAssert events == expected, "scan/ROC must resume CDE or idle after retiring"

for status in 0'u8 .. 6:
  for count in 0'u8 .. 3:
    for pending in [0'u8, 1]:
      if status == 4: continue
      reset()
      env.ctxtCount = count
      env.switchPending = pending
      env.scanDelayCount = 7
      env.connlessDelayCount = 8
      contexts[0].status = status
      chan_ctxt_op_evt(addr contexts[0])
      filterIrqEvents()
      let shouldIdle = status in [2'u8, 3] and count > 1 and pending == 0
      doAssert events.len == shouldIdle.int
      doAssert env.flags == (if status in [2'u8, 3]: 0x20'u8 else: 0'u8)
      if shouldIdle:
        doAssert contexts[0].status == 2
        doAssert env.scanDelayCount == 0 and env.connlessDelayCount == 0
        doAssert events[0].kind == "goto-idle"
reset()
chan_ctxt_op_evt(nil)
doAssert events.len == 0
"""


def test_context_operation_releases_channel_and_accounts_slots(tmp_path: Path) -> None:
    run_nim(tmp_path, PLATFORM + OP_STUBS
            + procedure((FW / "task_handlers.nim").read_text(), "chan_get_dominant_chan")
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "chanCtxtOpEvent")
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_ctxt_op_evt")
            + OP_CHECKS)
