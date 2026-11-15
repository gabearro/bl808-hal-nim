"""Keep channel distribution attached to the scheduling state it observed."""

from pathlib import Path

import pytest

from test_wifi_channel_control import PLATFORM
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_mm_timer_lifetime import source as timer_source


HOOKS = r'''
var
  chanCdeGeneration: uint32
  enabled, incomingIrq: bool
  calls: seq[string]
  deadlines: seq[uint32]
  onClock, onTimer, onDistribute, onNext, onSwitch: proc()
proc invoke(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
proc irqSave(): uint32 =
  result = enabled.uint32 * 8
  enabled = false
proc irqRestore(saved: uint32) = enabled = (saved and 8) != 0
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  invoke(onClock)
  clockValue
proc mm_timer_set(timer: pointer; expiry: uint32) =
  doAssert enabled == incomingIrq
  doAssert timer == chanCdeTimer()
  calls.add("timer")
  deadlines.add(expiry)
  invoke(onTimer)
proc chan_distribute_slots() =
  doAssert enabled == incomingIrq
  calls.add("distribute")
  invoke(onDistribute)
proc chan_get_next_chan(): pointer =
  doAssert enabled == incomingIrq
  calls.add("next")
  invoke(onNext)
  nextChannel
proc chan_switch_start(p: pointer) =
  doAssert enabled == incomingIrq
  doAssert p == nextChannel and p != nil
  calls.add("switch")
  invoke(onSwitch)
proc setup(irq = true) =
  reset()
  enabled = irq
  incomingIrq = irq
  chanCdeGeneration = 0
  txResetEpoch = 0
  chanCtxtEpochs = default(typeof(chanCtxtEpochs))
  chanCtxtLinkEpochs = default(typeof(chanCtxtLinkEpochs))
  calls.setLen(0)
  deadlines.setLen(0)
  onClock = nil
  onTimer = nil
  onDistribute = nil
  onNext = nil
  onSwitch = nil
  env.ctxtCount = 2
  env.slotPeriod = 51200
  env.lastMacTime = 777
  env.currentCtxt = addr contexts[0]
  contexts[0].status = 4
  contexts[1].status = 1
  nextChannel = addr contexts[1]
'''


def source() -> str:
    code = PLATFORM
    for name in ("regRead", "mm_timer_set", "chan_distribute_slots",
                 "chan_get_next_chan", "chan_switch_start"):
        code = code.replace(procedure(code, name), "")
    return "var nextChannel: pointer\n" + code + HOOKS + procedure(
        (FW / "kernel_mac_channel.nim").read_text(), "chan_cde_evt")


CASES = {
    "timer_reset": r'''
for irq in [false, true]:
  for state in 0'u8 .. 2:
    setup(irq)
    var snapshot: typeof(env)
    onTimer = proc() =
      inc txResetEpoch
      env.lastMacTime = 99
      env.cdeStarted = 7
      snapshot = env
    var event = state
    chan_cde_evt(addr event)
    doAssert env == snapshot and calls == @["timer"] and enabled == irq
''',
    "timer_topology": r'''
for change in 0 .. 8:
  setup()
  var snapshot: typeof(env)
  onTimer = proc() =
    case change
    of 0: inc chanCtxtEpochs[0]
    of 1: inc chanCtxtLinkEpochs[0]
    of 2: env.currentCtxt = addr contexts[1]
    of 3: env.scheduledCtxt = addr contexts[2]
    of 4: env.ctxtCount = 3
    of 5: env.slotPeriod = 500
    of 6: env.flags = 4
    of 7: env.cdeStarted = 8
    else: env.lastMacTime = 123
    snapshot = env
  var event = 1'u8
  chan_cde_evt(addr event)
  doAssert env == snapshot and calls == @["timer"] and enabled
''',
    "nested_timer_event": r'''
for irq in [false, true]:
  for outerState in 0'u8 .. 2:
    for innerState in 0'u8 .. 1:
      setup(irq)
      var snapshot: typeof(env)
      var callCount: int
      onTimer = proc() =
        var nestedState = innerState
        chan_cde_evt(addr nestedState)
        snapshot = env
        callCount = calls.len
      var event = outerState
      chan_cde_evt(addr event)
      doAssert env == snapshot and calls.len == callCount and enabled == irq
''',
    "operation_state_change": r'''
for boundary in 0 .. 1:
  for index in 0 .. 1:
    for status in [2'u8, 3, 5]:
      setup()
      env.scheduledCtxt = addr contexts[1]
      nextChannel = addr contexts[2]
      contexts[2].status = 1
      var snapshot: tuple[environment: typeof(env), values: typeof(contexts)]
      var callCount: int
      let replace = proc() =
        contexts[index].status = status
        snapshot = (env, contexts)
        callCount = calls.len
      if boundary == 0: onTimer = replace
      else: onNext = replace
      var event = 2'u8
      chan_cde_evt(addr event)
      doAssert (env, contexts) == snapshot and calls.len == callCount and enabled
''',
    "distribute_replacement": r'''
for state in 1'u8 .. 2:
  setup()
  var snapshot: typeof(env)
  onDistribute = proc() =
    inc chanCtxtEpochs[0]
    env.scheduledCtxt = addr contexts[2]
    snapshot = env
  var event = state
  chan_cde_evt(addr event)
  doAssert env == snapshot and calls == @["timer", "distribute"] and enabled
''',
    "next_replacement": r'''
for state in 1'u8 .. 2:
  setup()
  var snapshot: typeof(env)
  onNext = proc() =
    inc chanCtxtEpochs[1]
    env.scheduledCtxt = addr contexts[2]
    snapshot = env
  var event = state
  chan_cde_evt(addr event)
  doAssert env == snapshot and calls == @["timer", "distribute", "next"] and enabled
''',
    "nil_selection": r'''
for state in 1'u8 .. 2:
  for scheduled in [false, true]:
    setup()
    env.scheduledCtxt = if scheduled: cast[pointer](addr contexts[0]) else: nil
    let previous = env.scheduledCtxt
    let oldContexts = contexts
    nextChannel = nil
    var event = state
    chan_cde_evt(addr event)
    doAssert env.scheduledCtxt == previous and contexts == oldContexts
    doAssert calls == @["timer", "distribute", "next"] and enabled
''',
    "invalid_selection": r'''
for state in 1'u8 .. 2:
  for invalid in 0 .. 2:
    setup()
    env.scheduledCtxt = addr contexts[0]
    if invalid == 0: nextChannel = cast[pointer](1)
    elif invalid == 1: contexts[1].contextIndexOrMarker = 255
    else: contexts[1].status = 0
    let previous = contexts
    var event = state
    chan_cde_evt(addr event)
    doAssert env.scheduledCtxt == (addr contexts[0]) and contexts == previous
    doAssert calls == @["timer", "distribute", "next"] and enabled
''',
    "invalid_pending": r'''
for invalid in 0 .. 2:
  setup()
  env.scheduledCtxt = addr contexts[0]
  if invalid == 0: env.scheduledCtxt = cast[pointer](1)
  elif invalid == 1: contexts[0].contextIndexOrMarker = 255
  else: contexts[0].status = 0
  let previous = contexts
  let scheduled = env.scheduledCtxt
  var event = 2'u8
  chan_cde_evt(addr event)
  doAssert env.scheduledCtxt == scheduled and contexts == previous
  doAssert calls == @["timer", "distribute", "next"] and enabled
''',
    "clock_reset": r'''
setup()
var snapshot: typeof(env)
onClock = proc() =
  inc txResetEpoch
  env.lastMacTime = 123
  snapshot = env
var event = 1'u8
chan_cde_evt(addr event)
doAssert env == snapshot and calls.len == 0 and enabled
''',
    "event_snapshot": r'''
setup()
var event = 1'u8
onClock = proc() = event = 2
chan_cde_evt(addr event)
doAssert env.scheduledCtxt == nextChannel
doAssert calls == @["timer", "distribute", "next"] and enabled
''',
    "callback_exceptions": r'''
for irq in [false, true]:
  for boundary in 0 .. 4:
    setup(irq)
    let fail = proc() = raise newException(ValueError, "distribution callback")
    case boundary
    of 0: onClock = fail
    of 1: onTimer = fail
    of 2: onDistribute = fail
    of 3: onNext = fail
    else: onSwitch = fail
    var raised = false
    var event = 2'u8
    try: chan_cde_evt(addr event)
    except ValueError: raised = true
    doAssert raised and enabled == irq
''',
    "wrap_and_repeat": r'''
for state in 0'u8 .. 2:
  setup()
  chanCdeGeneration = high(uint32)
  clockValue = 0xFFFFFFF0'u32
  var event = state
  chan_cde_evt(addr event)
  doAssert chanCdeGeneration == 0
  doAssert deadlines == @[clockValue + env.slotPeriod]
  clockValue += 1
  chan_cde_evt(addr event)
  doAssert deadlines.len == (if state == 0: 2 else: 1)
  doAssert chanCdeGeneration == 1 and enabled
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_distribution_owner(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


TIMER_DOMAIN = r'''
type DistributionContext = object
  contextIndexOrMarker, status: uint8
var
  chanCdeGeneration, txResetEpoch: uint32
  chanCtxtEpochs: array[5, uint32]
  chanCtxtLinkEpochs: array[2, uint32]
  contexts: array[5, DistributionContext]
  env: tuple[ctxtCount, flags: uint8, slotPeriod, cdeStarted, lastMacTime: uint32,
             currentCtxt, scheduledCtxt: pointer]
  distributions, selections, switches: int
proc chanEnvView(): ptr typeof(env) = addr env
proc chanCtxtForIdx(index: uint8): ptr DistributionContext = addr contexts[index]
proc chanCtxtAt(p: pointer): ptr DistributionContext = cast[ptr DistributionContext](p)
proc chanCdeTimer(): pointer = addr timers[0]
proc chan_distribute_slots() = inc distributions
proc chan_get_next_chan(): pointer =
  inc selections
  addr contexts[1]
proc chan_switch_start(p: pointer) = inc switches
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("boundary", ["input_trace", "timer_trace", "hardware"])
def test_distribution_with_mm_timer(tmp_path: Path, mode: str, boundary: str) -> None:
    checks = r'''
env.ctxtCount = 2
env.slotPeriod = 51200
env.lastMacTime = 777
env.currentCtxt = addr contexts[0]
for index in 0 ..< contexts.len:
  contexts[index].contextIndexOrMarker = index.uint8
  contexts[index].status = 1
var snapshot: typeof(env)
proc replace() =
  inc txResetEpoch
  mm_timer_init()
  env.lastMacTime = 91
  env.cdeStarted = 0
  env.scheduledCtxt = addr contexts[2]
  snapshot = env
'''
    if boundary == "hardware":
        checks += "onHardware = replace\n"
    else:
        tag = "in" if boundary == "input_trace" else "timer"
        checks += f'''
onTrace = proc(tag: string) =
  if tag == "[WIFI-NIMFW] mm_timer_set {tag} ":
    onTrace = nil
    replace()
'''
    checks += r'''
var event = 1'u8
chan_cde_evt(addr event)
doAssert env == snapshot and distributions == 0 and selections == 0 and switches == 0
doAssert queueIds().len == 0 and enabled
finish()
'''
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    run_program(tmp_path, mode, timer_source() + TIMER_DOMAIN
                + procedure(kernel, "chan_cde_evt") + checks)
