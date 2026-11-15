"""Exercise TBTT timer ownership across nested scheduling and VIF changes."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_tbtt import PLATFORM, scheduler_source


HOOKS = r'''
var
  incomingIrq: bool
  onClear, onSet, onClock, onDominant, onWarn: proc()
proc invoke(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
proc regRead(p: uint): uint32 =
  invoke(onClock)
  clockValue
proc macTimeNow(): uint32 = regRead(MACHW_TIMLO_REG)
proc chan_get_dominant_chan(): pointer =
  doAssert enabled == incomingIrq
  invoke(onDominant)
  env.dominantCtxt
proc mm_timer_set(p: pointer; time: uint32) =
  doAssert enabled == incomingIrq
  timerActive = true
  events.add(("timer", p, time))
  invoke(onSet)
proc mm_timer_clear(p: pointer) =
  doAssert enabled == incomingIrq
  timerActive = false
  events.add(("clear", p, 0'u32))
  invoke(onClear)
proc assert_warn(a, b: cstring; line: cint) =
  inc warnings
  invoke(onWarn)
proc setup(irq = true) =
  reset()
  enabled = irq
  incomingIrq = irq
  onClear = nil
  onSet = nil
  onClock = nil
  onDominant = nil
  onWarn = nil
  nodes[0].targetTime = 100000
  nodes[1].targetTime = 50000
  nodes[2].targetTime = 25000
proc snapshot(): auto = (env, nodes, vifs, contexts)
'''


def source() -> str:
    code = PLATFORM
    declarations = ""
    for name, declaration in (
        ("regRead", "proc regRead(p: uint): uint32\n"),
        ("macTimeNow", "proc macTimeNow(): uint32\n"),
        ("chan_get_dominant_chan", "proc chan_get_dominant_chan(): pointer\n"),
        ("mm_timer_set", "proc mm_timer_set(p: pointer; time: uint32)\n"),
        ("mm_timer_clear", "proc mm_timer_clear(p: pointer)\n"),
        ("assert_warn", "proc assert_warn(a, b: cstring; line: cint)\n"),
    ):
        code = code.replace(procedure(code, name), "")
        declarations += declaration
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    return declarations + code + HOOKS + scheduler_source() + procedure(
        kernel, "chan_tbtt_switch_update")


CASES = {
    "clear_replacement": r'''
for irq in [false, true]:
  setup(irq)
  chan_tbtt_schedule(addr nodes[0])
  var expected: typeof(snapshot())
  var count: int
  onClear = proc() =
    chan_tbtt_schedule(addr nodes[2])
    expected = snapshot()
    count = events.len
  chan_tbtt_schedule(addr nodes[1])
  doAssert snapshot() == expected and events.len == count and enabled == irq
  doAssert env.tbttDeferredSlot == (addr nodes[2]) and timerActive
''',
    "displaced_replacement": r'''
setup()
nodes[0].targetTime = 50000
nodes[1].targetTime = 51000
nodes[1].priority = 5
nodes[2].targetTime = 10000
chan_tbtt_schedule(addr nodes[0])
var expected: typeof(snapshot())
var count: int
onClear = proc() =
  chan_tbtt_schedule(addr nodes[2])
  expected = snapshot()
  count = events.len
chan_tbtt_schedule(addr nodes[1])
doAssert snapshot() == expected and events.len == count and enabled
''',
    "clock_replacement": r'''
setup()
var expected: typeof(snapshot())
var count: int
onClock = proc() =
  let previousIrq = incomingIrq
  incomingIrq = enabled
  chan_tbtt_schedule(addr nodes[1])
  incomingIrq = previousIrq
  expected = snapshot()
  count = events.len
chan_tbtt_schedule(addr nodes[0])
doAssert snapshot() == expected and events.len == count and enabled
doAssert env.tbttDeferredSlot == (addr nodes[1]) and timerActive
''',
    "callback_vif_reuse": r'''
setup()
chan_tbtt_schedule(addr nodes[0])
var expected: typeof(snapshot())
onClock = proc() =
  inc rxVifEpochs[0]
  vifs[0].chanCtxt = addr contexts[1]
  nodes[0].targetTime = 90000
  nodes[0].priority = 5
  nodes[0].state = 1
  env.tbttDeferredSlot = addr nodes[0]
  expected = snapshot()
chan_tbtt_switch_evt(addr nodes[0])
doAssert snapshot() == expected and enabled
''',
    "callback_replacement": r'''
setup()
chan_tbtt_schedule(addr nodes[0])
var expected: typeof(snapshot())
var count: int
onDominant = proc() =
  chan_tbtt_switch_update(addr vifs[1], 34000)
  expected = snapshot()
  count = events.len
chan_tbtt_switch_evt(addr nodes[0])
doAssert snapshot() == expected and events.len == count and enabled
''',
    "foreign_timer_owner": r'''
setup()
chan_tbtt_schedule(addr nodes[1])
nodes[0].state = 1
let previous = snapshot()
let count = events.len
chan_tbtt_switch_evt(addr nodes[0])
doAssert snapshot() == previous and events.len == count and enabled
''',
    "callback_epoch_change": r'''
for boundary in 0 .. 1:
  for change in 0 .. 2:
    setup()
    chan_tbtt_schedule(addr nodes[0])
    var expected: typeof(snapshot())
    let replace = proc() =
      case change
      of 0: inc rxVifEpochs[0]
      of 1: inc chanCtxtEpochs[0]
      else: inc chanCtxtLinkEpochs[0]
      expected = snapshot()
    if boundary == 0: onClock = replace
    else: onDominant = replace
    chan_tbtt_switch_evt(addr nodes[0])
    doAssert snapshot() == expected and enabled
''',
    "warning_replacement": r'''
setup()
nodes[0].targetTime = 50000
nodes[0].priority = 5
nodes[1].targetTime = 51000
nodes[2].targetTime = 10000
vifs[1].staIdx = 255
chan_tbtt_schedule(addr nodes[0])
var expected: typeof(snapshot())
var count: int
onWarn = proc() =
  chan_tbtt_insert(addr nodes[2])
  expected = snapshot()
  count = events.len
chan_tbtt_schedule(addr nodes[1])
doAssert warnings == 1 and snapshot() == expected and events.len == count and enabled
''',
    "callback_exceptions": r'''
for irq in [false, true]:
  for boundary in 0 .. 3:
    setup(irq)
    let fail = proc() = raise newException(ValueError, "TBTT callback")
    if boundary == 0:
      onClock = fail
    elif boundary == 1:
      onSet = fail
    elif boundary == 2:
      chan_tbtt_schedule(addr nodes[0])
      onClear = fail
    else:
      chan_tbtt_schedule(addr nodes[1])
      onDominant = fail
    var raised = false
    try:
      if boundary == 3: chan_tbtt_switch_evt(addr nodes[1])
      elif boundary == 2: chan_tbtt_schedule(addr nodes[1])
      else: chan_tbtt_schedule(addr nodes[0])
    except ValueError: raised = true
    doAssert raised and enabled == irq
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_tbtt_owner(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
