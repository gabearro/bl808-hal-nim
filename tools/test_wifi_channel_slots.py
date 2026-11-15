"""Exercise production channel airtime allocation with distinct VIF/context lists."""

from pathlib import Path

from test_wifi_deferred_auth import run_nim
from test_wifi_disconnect_tx import FW, procedure


PLATFORM = r"""
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_STA = 0'u8
  VIF_TYPE_AP = 2'u8
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  ChanCtxtView = object
    next: pointer
    contextIndexOrMarker, status: uint8
    schedSlot, opSlot, tbttSlot: uint16
  Vif = object
    next: pointer
    chanCtxt: pointer
    state, vifIdx, vifType, staIdx, apChanSwitchPending: uint8
    listenInterval, apBeaconInterval: uint16
  ChanEnvView = object
    freeList, activeList, tbttSwitchList: CoList
    flags, schedState, ctxtCount: uint8
    slotPeriod: uint32
    dominantCtxt: pointer
    currentCtxt, scheduledCtxt: pointer
    nextChanTimestamp, cdeStarted, lastMacTime: uint32
  VifMgmtEnv = object
    activeList: CoList
  TdEntryView = object
    prefix: array[41, uint8]
    prevFlags, active, endActive: uint8
  Sta = object
    psMode: uint8
    initialRateConfig: uint32
var
  env: ChanEnvView
  vifMgmt: VifMgmtEnv
  contexts: array[3, ChanCtxtView]
  vifs: array[2, Vif]
  decoy: Vif
  decoyContext: ChanCtxtView
  td_env: array[2, TdEntryView]
  stations: array[7, Sta]
  sm_reconn_dominant_flag: uint32
  chanSlotConfigCycles: uint8
  warnings, dominantReads: int
proc chanEnvView(): ptr ChanEnvView = addr env
proc vifMgmtEnvView(): ptr VifMgmtEnv = addr vifMgmt
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc chanCtxtAt(p: pointer): ptr ChanCtxtView = cast[ptr ChanCtxtView](p)
proc staInfoForIdx(i: uint8): ptr Sta = addr stations[i]
proc tdEntryAt(p: pointer): ptr TdEntryView = cast[ptr TdEntryView](p)
proc chan_get_dominant_chan(): pointer =
  inc dominantReads
  if sm_reconn_dominant_flag != 0: env.dominantCtxt else: nil
proc assert_warn(a, b: cstring; line: int) = inc warnings
proc reset(count = 2) =
  env = default(ChanEnvView)
  vifMgmt = default(VifMgmtEnv)
  vifs = default(typeof(vifs))
  contexts = default(typeof(contexts))
  td_env = default(typeof(td_env))
  stations = default(typeof(stations))
  chanSlotConfigCycles = 0
  sm_reconn_dominant_flag = 0
  warnings = 0
  dominantReads = 0
  env.ctxtCount = count.uint8
  env.slotPeriod = count.uint32 * 51200
  for i in 0 ..< contexts.len:
    contexts[i].contextIndexOrMarker = i.uint8
    contexts[i].status = 1
    contexts[i].schedSlot = 1234
    contexts[i].opSlot = 2345
    contexts[i].tbttSlot = 3456
  for i in 0 ..< vifs.len:
    vifs[i].vifIdx = i.uint8
    vifs[i].staIdx = (6 - i).uint8
    vifs[i].state = 1
    vifs[i].listenInterval = 1
    vifs[i].chanCtxt = addr contexts[i]
    stations[vifs[i].staIdx].initialRateConfig = 102400
    if i + 1 < count: vifs[i].next = addr vifs[i + 1]
  vifMgmt.activeList.first = cast[ptr CoListHdr](addr vifs[0])
  decoyContext = ChanCtxtView(contextIndexOrMarker: 2, schedSlot: 60000,
                             opSlot: 60001, tbttSlot: 60002)
  decoy = Vif(chanCtxt: addr decoyContext, state: 0, vifType: 1)
  env.activeList.first = cast[ptr CoListHdr](addr decoy)
proc slots(index: int; scheduled, tbtt: uint16) =
  doAssert contexts[index].schedSlot == scheduled
  doAssert contexts[index].opSlot == scheduled
  doAssert contexts[index].tbttSlot == tbtt
"""

BASELINE = r"""
reset(1)
chan_distribute_slots()
slots(0, 50, 20)
doAssert decoyContext.schedSlot == 60000 and decoyContext.opSlot == 60001,
  "airtime allocation must walk VIFs, not channel-list entries"
"""


def run_slots(tmp_path: Path, checks: str) -> None:
    run_nim(tmp_path, PLATFORM
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_distribute_slots")
            + checks)


def test_slot_distribution_uses_active_vifs(tmp_path: Path) -> None:
    run_slots(tmp_path, BASELINE)


CREDIT_CHECKS = r"""
for firstIndex in 0 .. 2:
  for secondIndex in 0 .. 2:
    if firstIndex == secondIndex: continue
    for firstTraffic in 0'u8 .. 3:
      for secondTraffic in 0'u8 .. 3:
        for collision in [false, true]:
          reset()
          vifs[0].chanCtxt = addr contexts[firstIndex]
          vifs[1].chanCtxt = addr contexts[secondIndex]
          td_env[0].prevFlags = firstTraffic
          td_env[1].prevFlags = secondTraffic
          # These station bytes are deliberately opposite: not traffic input.
          stations[0].psMode = (not firstTraffic) and 3
          stations[1].psMode = (not secondTraffic) and 3
          env.flags = if collision: 0xA0 else: 0x20
          let beforeFlags = env.flags
          chan_distribute_slots()
          let factor = if collision: 2'u16 else: 1'u16
          let firstShare = if firstTraffic != 0 and secondTraffic == 0: 60'u16
            elif firstTraffic == 0 and secondTraffic != 0: 40'u16
            else: 50'u16
          slots(firstIndex, firstShare * factor, 20)
          slots(secondIndex, (100 - firstShare) * factor, 20)
          doAssert env.flags == beforeFlags and warnings == 0
          doAssert dominantReads == 1

reset()
vifs[0].state = 0
env.schedState = 1
chan_distribute_slots()
slots(0, 83, 20)
slots(1, 17, 20)
doAssert chanSlotConfigCycles == 50 and env.schedState == 2

reset()
env.flags = 0x80
env.schedState = 1
chan_distribute_slots()
slots(0, 167, 20)
slots(1, 33, 20)
doAssert env.schedState == 2 and chanSlotConfigCycles == 0

reset()
vifs[0].vifType = 2
vifs[0].apChanSwitchPending = 1
vifs[0].apBeaconInterval = 100
chan_distribute_slots()
slots(0, 80, 20)
slots(1, 20, 20)
doAssert vifs[0].apChanSwitchPending == 0 and chanSlotConfigCycles == 50

# Exact halves round down: 450/12 = 37.5, 1350/12 = 112.5.
reset()
env.ctxtCount = 3
td_env[0].prevFlags = 1
td_env[1].prevFlags = 1
vifs[1].vifType = 2
vifs[1].apChanSwitchPending = 1
vifs[1].apBeaconInterval = 100
chan_distribute_slots()
slots(0, 37, 20)
slots(1, 112, 20)
"""


def test_slot_credits_and_rounding(tmp_path: Path) -> None:
    run_slots(tmp_path, CREDIT_CHECKS)


HOLD_CHECKS = r"""
reset()
chan_distribute_slots()
chanSlotConfigCycles = 2
td_env[0].prevFlags = 1
for left in countdown(1, 0):
  chan_distribute_slots()
  slots(0, 50, 20)
  slots(1, 50, 20)
  doAssert chanSlotConfigCycles == left.uint8 and dominantReads == 1
chan_distribute_slots()
slots(0, 60, 20)
slots(1, 40, 20)
doAssert dominantReads == 2

reset()
sm_reconn_dominant_flag = 1
vifs[0].state = 0
env.flags = 0x90
chan_distribute_slots()
slots(0, 167, 20)
slots(1, 33, 20)
doAssert chanSlotConfigCycles == 50 and env.dominantCtxt == addr contexts[0]
vifs[0].state = 1
for left in countdown(49, 0):
  chan_distribute_slots()
  doAssert chanSlotConfigCycles == left.uint8
  slots(0, 167, 20)
  slots(1, 33, 20)
  doAssert env.dominantCtxt == addr contexts[0]
  doAssert env.flags == 0x90 and dominantReads == 1
chan_distribute_slots()
slots(0, 100, 20)
slots(1, 100, 20)
doAssert env.dominantCtxt == nil and dominantReads == 2 and env.flags == 0x90

# A collision requests recomputation even while the hold counter is active.
reset()
chanSlotConfigCycles = 7
env.schedState = 1
chan_distribute_slots()
slots(0, 83, 20)
slots(1, 17, 20)
doAssert chanSlotConfigCycles == 7 and env.schedState == 2
"""


def test_slot_configuration_hold_and_dominance(tmp_path: Path) -> None:
    run_slots(tmp_path, HOLD_CHECKS)


LISTEN_CHECKS = r"""
for longVif in 0 .. 1:
  reset()
  env.flags = 0x80
  vifs[longVif].listenInterval = 2
  chan_distribute_slots()
  slots(longVif, 100, 20)
  slots(1 - longVif, 0xFFFF, 20)

reset()
vifs[0].listenInterval = 2
vifs[1].vifType = 2
vifs[1].apBeaconInterval = 25
chan_distribute_slots()
slots(0, 100, 20)
slots(1, 0xFFFF, 80)

# Two VIFs sharing a channel accumulate credit in one context.
reset()
vifs[1].chanCtxt = addr contexts[0]
env.ctxtCount = 1
stations[vifs[1].staIdx].initialRateConfig = 51200
chan_distribute_slots()
slots(0, 50, 40)
doAssert warnings == 0

reset()
vifs[0].chanCtxt = nil
env.slotPeriod = 51200
chan_distribute_slots()
slots(1, 100, 20)
doAssert contexts[0].schedSlot == 1234 and warnings == 0

reset()
vifMgmt.activeList.first = nil
env.slotPeriod = 0
chan_distribute_slots()
doAssert contexts[0].schedSlot == 1234 and warnings == 0

reset(1)
vifs[0].staIdx = 255
chan_distribute_slots()
slots(0, 50, 20)

reset(1)
vifs[0].vifType = 2
vifs[0].apBeaconInterval = 0
chan_distribute_slots()
slots(0, 50, 20)

for badIndex in [3'u8, 255]:
  reset(1)
  contexts[0].contextIndexOrMarker = badIndex
  chan_distribute_slots()
  doAssert warnings == 1 and contexts[0].schedSlot == 1234
reset(1)
vifs[0].vifIdx = 2
chan_distribute_slots()
doAssert warnings == 1 and contexts[0].schedSlot == 1234
"""


def test_long_listen_shared_and_invalid_contexts(tmp_path: Path) -> None:
    run_slots(tmp_path, LISTEN_CHECKS)


def test_cde_allocation_and_selection_integration(tmp_path: Path) -> None:
    platform = r"""
const
  MACHW_BASE = 0x24B00000'u
  MACHW_TIMLO_REG = MACHW_BASE + 0x120
type TbttNode = object
  state, vifIdx: uint8
  targetTime: uint32
var
  clockValue = 1000'u32
  timerWrites: seq[uint32]
  switches: seq[pointer]
proc regRead(address: uint): uint32 = clockValue
proc chanCtxtForIdx(index: uint8): ptr ChanCtxtView = addr contexts[index]
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc chanTbttNodeAt(p: pointer): ptr TbttNode = cast[ptr TbttNode](p)
proc chanCdeTimer(): pointer = cast[pointer](60)
proc mm_timer_set(timer: pointer; expiry: uint32) =
  doAssert timer == cast[pointer](60)
  timerWrites.add(expiry)
proc chan_switch_start(p: pointer) = switches.add(p)
proc assert_err(a, b: cstring; line: int) = doAssert false, "unexpected invariant failure"
"""
    checks = r"""
reset()
contexts[2].status = 0
var event = 1'u8
chan_cde_evt(addr event)
slots(0, 50, 20)
slots(1, 50, 20)
doAssert env.scheduledCtxt == addr contexts[1]
doAssert timerWrites == @[103400'u32]
doAssert env.cdeStarted == 1 and env.lastMacTime == clockValue
doAssert switches.len == 0

# Traffic shifts the next grant while the old grant's operation state transfers.
td_env[0].prevFlags = 1
contexts[1].status = 3
event = 2
chan_cde_evt(addr event)
slots(0, 60, 20)
slots(1, 40, 20)
doAssert env.scheduledCtxt == addr contexts[0]
doAssert contexts[0].status == 3 and contexts[1].status == 1
doAssert timerWrites.len == 1 and switches.len == 0

reset()
contexts[2].status = 0
event = 2
chan_cde_evt(addr event)
doAssert switches == @[cast[pointer](addr contexts[1])]
"""
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    run_nim(tmp_path, PLATFORM + platform
            + procedure(kernel, "chan_distribute_slots")
            + procedure(tasks, "chan_get_next_chan")
            + procedure(kernel, "chan_cde_evt") + checks)
