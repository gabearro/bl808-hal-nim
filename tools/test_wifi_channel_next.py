"""Exercise channel selection at TBTT and available-slot boundaries."""

from pathlib import Path

from test_wifi_deferred_auth import run_nim
from test_wifi_disconnect_tx import FW, procedure


PLATFORM = r"""
const
  MAX_VIFS = 2
  MACHW_TIMLO_REG = 0x24B00120'u
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  ChanCtxtView = object
    status: uint8
    opSlot, tbttSlot: uint16
  TbttNode = object
    targetTime: uint32
    vifIdx, state: uint8
  Vif = object
    chanCtxt: pointer
  Env = object
    currentCtxt: pointer
    tbttSwitchList: CoList
    nextChanTimestamp: uint32
var
  env: Env
  contexts: array[3, ChanCtxtView]
  fallback: ChanCtxtView
  vifs: array[2, Vif]
  node: TbttNode
  clockValue: uint32
  assertions: seq[int]
proc chanEnvView(): ptr Env = addr env
proc chanCtxtAt(p: pointer): ptr ChanCtxtView = cast[ptr ChanCtxtView](p)
proc chanCtxtForIdx(i: uint8): ptr ChanCtxtView = addr contexts[i]
proc chanTbttNodeAt(p: pointer): ptr TbttNode = cast[ptr TbttNode](p)
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  clockValue
proc assert_err(a, b: cstring; line: int) = assertions.add(line)
proc reset() =
  env = default(Env)
  contexts = default(typeof(contexts))
  vifs = default(typeof(vifs))
  fallback = default(ChanCtxtView)
  node = default(TbttNode)
  assertions.setLen(0)
  clockValue = 1000
  env.nextChanTimestamp = 20000
  contexts[0] = ChanCtxtView(status: 1, opSlot: 99)
  contexts[1] = ChanCtxtView(status: 1, opSlot: 20, tbttSlot: 5)
  contexts[2] = ChanCtxtView(status: 1, opSlot: 10)
  vifs[1].chanCtxt = addr contexts[1]
  node = TbttNode(vifIdx: 1, targetTime: 10000)
  env.tbttSwitchList.first = cast[ptr CoListHdr](addr node)
"""

BASELINE = r"""
reset()
doAssert chan_get_next_chan() == (addr contexts[1]),
  "TBTT candidate has 15 free slots and needs only 8, not 9000 slots"
"""


def run_next(tmp_path: Path, checks: str) -> None:
    run_nim(tmp_path, PLATFORM
            + procedure((FW / "task_handlers.nim").read_text(), "chan_get_next_chan")
            + checks)


def test_tbtt_selection_uses_slot_units(tmp_path: Path) -> None:
    run_next(tmp_path, BASELINE)


CHECKS = r"""
for now in [0'u32, 1000, 0xFFFFF000'u32]:
  for distance in [5120'u32, 5121, 8191, 8192, 9215, 9216, 10240]:
    for available in [0'u16, 5, 7, 8, 9, 10, 20]:
      reset()
      clockValue = now
      node.targetTime = now + distance
      env.nextChanTimestamp = node.targetTime + 10000
      contexts[1].tbttSlot = 5
      contexts[1].opSlot = available + 5
      let fits = distance <= 5120 or available.uint32 >= (distance shr 10)
      let expected = if fits: addr contexts[1] else: addr contexts[0]
      doAssert chan_get_next_chan() == expected
      doAssert assertions.len == 0

# Reserving more TBTT time than remains saturates usable slots to zero.
reset()
contexts[1].opSlot = 5
contexts[1].tbttSlot = 20
doAssert chan_get_next_chan() == addr contexts[0]

# A TBTT after/equal to the operation deadline does not constrain selection.
for offset in [0'u32, 1, 10000]:
  reset()
  env.nextChanTimestamp = node.targetTime - offset
  doAssert chan_get_next_chan() == addr contexts[0]

# Current-channel preservation gates, including unsigned TSF wrap.
for now in [1000'u32, 0xFFFFF000'u32]:
  for distance in [5119'u32, 5120, 5121]:
    reset()
    clockValue = now
    env.currentCtxt = addr fallback
    env.nextChanTimestamp = now + distance
    node.targetTime = env.nextChanTimestamp + 10000
    let expected = if distance <= 5120: addr fallback else: addr contexts[0]
    doAssert chan_get_next_chan() == expected
reset()
env.currentCtxt = addr fallback
fallback.status = 4
doAssert chan_get_next_chan() == addr fallback
reset()
env.currentCtxt = addr fallback
node.state = 2
doAssert chan_get_next_chan() == addr fallback

# The active pool wins by remaining slots; later indexes win exact ties.
for mask in 1 .. 7:
  for a in [0'u16, 1, 10]:
    for b in [0'u16, 1, 10]:
      for c in [0'u16, 1, 10]:
        reset()
        env.tbttSwitchList.first = nil
        contexts[0].opSlot = a
        contexts[1].opSlot = b
        contexts[2].opSlot = c
        var expectedIndex = -1
        var remaining = -1
        for i in 0 ..< 3:
          contexts[i].status = ((mask shr i) and 1).uint8
          if contexts[i].status != 0 and contexts[i].opSlot.int >= remaining:
            remaining = contexts[i].opSlot.int
            expectedIndex = i
        doAssert chan_get_next_chan() == addr contexts[expectedIndex]
        doAssert assertions.len == 0

# Retain the current candidate if no active pool entry replaces it.
reset()
env.tbttSwitchList.first = nil
env.currentCtxt = addr fallback
contexts = default(typeof(contexts))
doAssert chan_get_next_chan() == addr fallback
doAssert assertions.len == 0
reset()
env.tbttSwitchList.first = nil
contexts = default(typeof(contexts))
doAssert chan_get_next_chan() == nil
doAssert assertions == @[414]

reset()
node.vifIdx = 2
doAssert chan_get_next_chan() == nil
doAssert assertions == @[338]
reset()
vifs[1].chanCtxt = nil
doAssert chan_get_next_chan() == nil
doAssert assertions == @[338]
"""


def test_channel_selection_boundaries_and_fallback(tmp_path: Path) -> None:
    run_next(tmp_path, CHECKS)
