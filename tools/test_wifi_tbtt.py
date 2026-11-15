"""Run TBTT scheduling with production intrusive-list operations."""

from pathlib import Path
import re

from test_wifi_deferred_auth import run_nim
from test_wifi_disconnect_tx import FW, procedure


PLATFORM = r"""
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  MACHW_TIMLO_REG = 0x24B00120'u
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  ChanTbttNodeView = object
    link: CoListHdr
    targetTime: uint32
    vifIdx, priority, state: uint8
  ChanCtxtView = object
    status: uint8
    opSlot, tbttSlot: uint16
  Vif = object
    chanCtxt: pointer
    tbttNode: ChanTbttNodeView
    vifType, staIdx: uint8
    apBeaconInterval: uint16
  Sta = object
    initialRateConfig: uint32
  Env = object
    primary, delayed: CoList
    currentCtxt, scheduledCtxt, dominantCtxt, tbttDeferredSlot: pointer
    flags, schedState, ctxtCount: uint8
    lastMacTime: uint32
  Event = tuple[kind: string, param: pointer, value: uint32]
var
  env: Env
  nodes: array[4, ChanTbttNodeView]
  vifs: array[2, Vif]
  contexts: array[3, ChanCtxtView]
  stations: array[7, Sta]
  clockValue, chanConflictCount: uint32
  warnings: int
  events: seq[Event]
  timerActive: bool
  enabled: bool
  chanTbttGeneration, txResetEpoch: uint32
  rxVifEpochs, chanCtxtLinkEpochs: array[MAX_VIFS, uint32]
  chanCtxtEpochs: array[5, uint32]
proc irqSave(): uint32 =
  result = enabled.uint32 * 8
  enabled = false
proc irqRestore(saved: uint32) = enabled = (saved and 8) != 0
proc chanEnvView(): ptr Env = addr env
proc chanCtxtAt(p: pointer): ptr ChanCtxtView = cast[ptr ChanCtxtView](p)
proc chanTbttNodeAt(p: pointer): ptr ChanTbttNodeView = cast[ptr ChanTbttNodeView](p)
proc chanTbttHdr(p: ptr ChanTbttNodeView): ptr CoListHdr = addr p.link
proc chanTbttPrimaryList(): ptr CoList = addr env.primary
proc chanTbttReschedList(): ptr CoList = addr env.delayed
proc chanTbttDeferredSlot(): ptr pointer = addr env.tbttDeferredSlot
proc chanTbttTimer(): pointer = cast[pointer](44)
proc chanTbttConflictCounter(): ptr uint32 = addr chanConflictCount
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc staInfoForIdx(i: uint8): ptr Sta = addr stations[i]
proc regRead(p: uint): uint32 = clockValue
proc macTimeNow(): uint32 = clockValue
proc chan_get_dominant_chan(): pointer = env.dominantCtxt
proc chan_switch_start(p: pointer) = events.add(("switch", p, 0'u32))
proc mm_timer_set(p: pointer; time: uint32) =
  timerActive = true
  events.add(("timer", p, time))
proc mm_timer_clear(p: pointer) =
  timerActive = false
  events.add(("clear", p, 0'u32))
proc assert_err(a, b: cstring; line: cint) = doAssert false, "unexpected intrusive-list invariant"
proc assert_warn(a, b: cstring; line: cint) = inc warnings
proc reset() =
  env = default(Env)
  nodes = default(typeof(nodes))
  vifs = default(typeof(vifs))
  stations = default(typeof(stations))
  contexts = default(typeof(contexts))
  chanConflictCount = 0
  events.setLen(0)
  warnings = 0
  timerActive = false
  enabled = true
  chanTbttGeneration = 0
  txResetEpoch = 0
  rxVifEpochs = default(typeof(rxVifEpochs))
  chanCtxtEpochs = default(typeof(chanCtxtEpochs))
  chanCtxtLinkEpochs = default(typeof(chanCtxtLinkEpochs))
  clockValue = 1000
  env.ctxtCount = 2
  env.currentCtxt = addr contexts[0]
  contexts[0] = ChanCtxtView(status: 4, opSlot: 100, tbttSlot: 40)
  contexts[1] = ChanCtxtView(status: 4, opSlot: 100, tbttSlot: 40)
  for i in 0 ..< vifs.len:
    vifs[i].staIdx = i.uint8
    vifs[i].chanCtxt = addr contexts[i]
    vifs[i].tbttNode.vifIdx = i.uint8
    stations[i].initialRateConfig = 102400
  for i in 0 ..< nodes.len: nodes[i].vifIdx = (i mod 2).uint8
proc listNodes(list: ptr CoList): seq[pointer] =
  var item = list.first
  while item != nil:
    doAssert result.len < 10, "list cycle"
    result.add(cast[pointer](item))
    item = item.next
"""


def list_source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    snapshot = re.search(r"(?ms)^type\n  ChanTbttSnapshot = object.*?(?=^var\n)", kernel).group()
    return snapshot + "".join(procedure(kernel, name) for name in [
        "chanTbttBegin", "chanTbttCurrent",
        "co_list_push_back", "co_list_push_front", "co_list_pop_front",
        "co_list_extract", "co_list_insert_after", "chan_tbtt_detect_conflict",
        "chanTbttInsert", "chan_tbtt_insert",
    ])


def test_new_tbtt_is_armed_after_insertion(tmp_path: Path) -> None:
    checks = r"""
reset()
nodes[0].targetTime = 50000
chan_tbtt_schedule(addr nodes[0])
doAssert env.primary.first == addr nodes[0].link
doAssert nodes[0].state == 1 and env.tbttDeferredSlot == addr nodes[0]
doAssert events == @[("timer", cast[pointer](44), 50000'u32)],
  "inserting the first TBTT must arm its timer"
"""
    callback = "proc chan_tbtt_switch_evt(p: pointer = nil) = events.add((\"switch\", p, 0'u32))\n"
    run_nim(tmp_path, PLATFORM + list_source() + callback
            + procedure((FW / "task_handlers.nim").read_text(), "chan_tbtt_schedule") + checks)


def test_missed_beacon_priority_wins_collision(tmp_path: Path) -> None:
    checks = r"""
reset()
nodes[0].targetTime = 10000
nodes[1].targetTime = 12000
nodes[0].priority = 0
nodes[1].priority = 1
co_list_push_back(addr env.primary, addr nodes[0].link)
chan_tbtt_insert(addr nodes[1])
doAssert listNodes(addr env.primary) == @[cast[pointer](addr nodes[1])],
  "higher missed-beacon priority must win a collision"
doAssert listNodes(addr env.delayed) == @[cast[pointer](addr nodes[0])]
"""
    run_nim(tmp_path, PLATFORM + list_source() + checks)


def test_tbtt_priority_matrix_and_wrap_order(tmp_path: Path) -> None:
    checks = r"""
for state in 0'u8 .. 2:
  for oldPriority in 0'u8 .. 5:
    for newPriority in 0'u8 .. 5:
      for offset in [-50000, -20480, -1, 0, 1, 20480, 50000]:
        reset()
        nodes[0].targetTime = 100000
        nodes[1].targetTime = (100000 + offset).uint32
        nodes[0].state = state
        nodes[0].priority = oldPriority
        nodes[1].priority = newPriority
        if state == 1: env.tbttDeferredSlot = addr nodes[0]
        co_list_push_back(addr env.primary, addr nodes[0].link)
        chan_tbtt_insert(addr nodes[1])
        let conflict = abs(offset) <= 20480
        let oldWins = if state == 2: offset < 0 or conflict
          else: conflict and oldPriority >= newPriority
        if oldWins:
          doAssert listNodes(addr env.primary) == @[cast[pointer](addr nodes[0])]
          doAssert listNodes(addr env.delayed) == @[cast[pointer](addr nodes[1])]
        elif conflict:
          doAssert listNodes(addr env.primary) == @[cast[pointer](addr nodes[1])]
          doAssert listNodes(addr env.delayed) == @[cast[pointer](addr nodes[0])]
          if state == 1: doAssert nodes[0].state == 0
        else:
          let order = if offset < 0:
            @[cast[pointer](addr nodes[1]), cast[pointer](addr nodes[0])]
          else:
            @[cast[pointer](addr nodes[0]), cast[pointer](addr nodes[1])]
          doAssert listNodes(addr env.primary) == order
          doAssert env.delayed.first == nil

reset()
nodes[0].targetTime = 0xFFFF0000'u32
nodes[1].targetTime = 1000
co_list_push_back(addr env.primary, addr nodes[0].link)
chan_tbtt_insert(addr nodes[1])
doAssert listNodes(addr env.primary) ==
  @[cast[pointer](addr nodes[0]), cast[pointer](addr nodes[1])]
"""
    run_nim(tmp_path, PLATFORM + list_source() + checks)


def test_multiple_displacements_preserve_intrusive_links(tmp_path: Path) -> None:
    checks = r"""
reset()
nodes[0].targetTime = 100000
nodes[1].targetTime = 130000
nodes[2].targetTime = 115000
nodes[0].state = 1
nodes[2].priority = 5
env.tbttDeferredSlot = addr nodes[0]
co_list_push_back(addr env.primary, addr nodes[0].link)
co_list_push_back(addr env.primary, addr nodes[1].link)
chan_tbtt_insert(addr nodes[2])
doAssert listNodes(addr env.primary) == @[cast[pointer](addr nodes[2])]
doAssert listNodes(addr env.delayed) ==
  @[cast[pointer](addr nodes[0]), cast[pointer](addr nodes[1])]
doAssert nodes[0].state == 0
doAssert events == @[("clear", cast[pointer](44), 0'u32)]
"""
    run_nim(tmp_path, PLATFORM + list_source() + checks)


def scheduler_source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    return (list_source() + procedure(kernel, "chanTbttSwitchEvent")
            + procedure(kernel, "chan_tbtt_switch_evt")
            + procedure(tasks, "chan_tbtt_schedule"))


def test_tbtt_callback_units_and_gates(tmp_path: Path) -> None:
    checks = r"""
for count in 0'u8 .. 3:
  for flags in [0'u8, 4, 8, 12]:
    for dominance in 0 .. 2:
      for pending in 0 .. 2:
        for elapsed in [0'u32, 1023, 1024, 2048, 204800, 0xFFFFFFFF'u32]:
          reset()
          env.ctxtCount = count
          env.flags = flags
          env.lastMacTime = 0xFFFFFF00'u32
          clockValue = env.lastMacTime + elapsed
          env.dominantCtxt = case dominance
            of 0: nil
            of 1: cast[pointer](addr contexts[1])
            else: cast[pointer](addr contexts[2])
          env.scheduledCtxt = case pending
            of 0: nil
            of 1: cast[pointer](addr contexts[1])
            else: cast[pointer](addr contexts[2])
          nodes[1].vifIdx = 1
          nodes[1].priority = 5
          chan_tbtt_switch_evt(addr nodes[1])
          let allowed = count > 1 and flags == 0 and dominance != 2 and pending != 2
          if allowed:
            let slots = (elapsed shr 10) and 0xFFFF'u32
            doAssert contexts[0].opSlot == (if slots < 100: 100'u16 - slots.uint16 else: 0'u16)
            doAssert contexts[1].tbttSlot == 20
            doAssert nodes[1].priority == 0 and nodes[1].state == 2
            doAssert env.lastMacTime == clockValue
            doAssert events.len == (pending == 0).int
            if pending == 0: doAssert events[0].param == addr contexts[1]
          else:
            doAssert contexts[0].opSlot == 100 and contexts[1].tbttSlot == 40
            doAssert nodes[1].priority == 5 and nodes[1].state == 0 and events.len == 0
reset()
chan_tbtt_switch_evt(nil)
nodes[0].vifIdx = 2
chan_tbtt_switch_evt(addr nodes[0])
nodes[0].vifIdx = 0
vifs[0].chanCtxt = nil
chan_tbtt_switch_evt(addr nodes[0])
doAssert events.len == 0
"""
    run_nim(tmp_path, PLATFORM + scheduler_source() + checks)


def test_rescheduled_tbtt_is_armed_and_invalid_periods_terminate(tmp_path: Path) -> None:
    checks = r"""
reset()
nodes[0].targetTime = 50000
nodes[0].priority = 5
nodes[1].targetTime = 51000
nodes[1].vifIdx = 1
co_list_push_back(addr env.primary, addr nodes[0].link)
chan_tbtt_schedule(addr nodes[1])
doAssert listNodes(addr env.primary) ==
  @[cast[pointer](addr nodes[0]), cast[pointer](addr nodes[1])]
doAssert nodes[1].targetTime == 153400 and nodes[1].priority == 1
doAssert env.delayed.first == nil and timerActive

for priority in [0'u8, 4, 5]:
  reset()
  nodes[0].targetTime = 50000
  nodes[0].priority = 5
  nodes[1].targetTime = 51000
  nodes[1].priority = priority
  nodes[1].vifIdx = 1
  vifs[1].vifType = 2
  vifs[1].apBeaconInterval = 25
  co_list_push_back(addr env.primary, addr nodes[0].link)
  chan_tbtt_schedule(addr nodes[1])
  doAssert nodes[1].targetTime == 76600
  doAssert nodes[1].priority == (if priority < 5: priority + 1 else: 5'u8)

for bad in 0 .. 3:
  reset()
  nodes[0].targetTime = 50000
  nodes[0].priority = 5
  nodes[1].targetTime = 51000
  nodes[1].vifIdx = 1
  if bad == 0: nodes[1].vifIdx = 2
  if bad == 1: stations[1].initialRateConfig = 0
  if bad == 2: vifs[1].staIdx = 255
  if bad == 3: vifs[1].vifType = 2
  co_list_push_back(addr env.primary, addr nodes[0].link)
  chan_tbtt_schedule(addr nodes[1])
  doAssert env.delayed.first == nil and warnings == 1
  doAssert listNodes(addr env.primary) == @[cast[pointer](addr nodes[0])]
"""
    run_nim(tmp_path, PLATFORM + scheduler_source() + checks)


def test_timer_boundaries_and_beacon_updates(tmp_path: Path) -> None:
    checks = r"""
for now in [0'u32, 1000, 0xFFFFFF00'u32]:
  for wait in [0'u32, 1999, 2000, 2001, 50000]:
    reset()
    clockValue = now
    nodes[0].targetTime = now + wait
    chan_tbtt_schedule(addr nodes[0])
    doAssert events.len == 1
    if wait < 2000:
      doAssert not timerActive and nodes[0].state == 2
      doAssert events[0].kind == "switch" and events[0].param == addr contexts[0]
    else:
      doAssert timerActive and nodes[0].state == 1
      doAssert events[0] == ("timer", cast[pointer](44), nodes[0].targetTime)

reset()
chan_tbtt_switch_update(addr vifs[0], 100000)
let node = addr vifs[0].tbttNode
doAssert node.targetTime == 91000 and node.state == 1
doAssert env.tbttDeferredSlot == node and timerActive
let previousEvents = events.len
chan_tbtt_switch_update(addr vifs[0], 100000)
doAssert events.len == previousEvents
chan_tbtt_switch_update(addr vifs[0], 105000)
doAssert node.targetTime == 96000 and node.state == 1
doAssert listNodes(addr env.primary) == @[cast[pointer](node)]
clockValue = 95500
chan_tbtt_switch_update(addr vifs[0], 105001)
doAssert node.targetTime == 96001 and node.state == 2 and not timerActive
doAssert env.tbttDeferredSlot == nil

reset()
env.ctxtCount = 1
chan_tbtt_switch_update(addr vifs[0], 100000)
doAssert vifs[0].tbttNode.targetTime == 97000
doAssert env.primary.first == nil and events.len == 0
chan_tbtt_switch_update(nil, 100000)
"""
    run_nim(tmp_path, PLATFORM + scheduler_source()
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_tbtt_switch_update")
            + checks)


def test_single_tbtt_timer_ownership(tmp_path: Path) -> None:
    checks = r"""
proc fireTimer() =
  doAssert timerActive
  timerActive = false
  let owner = env.tbttDeferredSlot
  chan_tbtt_switch_evt(owner)

reset()
nodes[0].targetTime = 100000
nodes[1].targetTime = 50000
chan_tbtt_schedule(addr nodes[0])
chan_tbtt_schedule(addr nodes[1])
doAssert nodes[0].state == 0 and nodes[1].state == 1,
  "only the node that owns the timer may remain armed"
clockValue = 50000
fireTimer()
co_list_extract(addr env.primary, addr nodes[1].link)
chan_tbtt_schedule(nil)
doAssert timerActive and env.tbttDeferredSlot == addr nodes[0]

reset()
nodes[0].targetTime = 100000
chan_tbtt_schedule(addr nodes[0])
co_list_extract(addr env.primary, addr nodes[0].link)
chan_tbtt_schedule(nil)
doAssert not timerActive and env.tbttDeferredSlot == nil and nodes[0].state == 0

reset()
nodes[0].targetTime = 100000
nodes[1].targetTime = clockValue + 1000
chan_tbtt_schedule(addr nodes[0])
chan_tbtt_schedule(addr nodes[1])
doAssert not timerActive and nodes[0].state == 0 and nodes[1].state == 2
doAssert env.tbttDeferredSlot == nil

reset()
nodes[0].targetTime = 100000
chan_tbtt_schedule(addr nodes[0])
clockValue = 100000
env.flags = 8
fireTimer()
doAssert nodes[0].state == 0 and env.tbttDeferredSlot == nil
env.flags = 0
chan_tbtt_schedule(nil)
doAssert nodes[0].state == 2
"""
    run_nim(tmp_path, PLATFORM + scheduler_source() + checks)
