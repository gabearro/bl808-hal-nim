"""Exercise vendor connectionless-delay decisions and preparation ownership."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_auth_frames import layouts
from test_wifi_mm_timer_lifetime import source as timer_source


PLATFORM = r'''
const MACHW_BASE = 0x24B00000'u
const MACHW_TIMLO_REG = MACHW_BASE + 0x120
type Env = object
  flags, ctxtCount: uint8
  scheduledCtxt: pointer
var
  env: Env
  scan_env: tuple[channelIndex: uint8]
  chanConnlessGeneration, txResetEpoch: uint32
  chanCtxtEpochs: array[5, uint32]
  rxVifEpochs: array[2, uint32]
  enabled, incomingIrq, hasAp, checkSwitchIrq, timerPending: bool
  events: seq[string]
  expiry: uint32
  now = 1000'u32
  apCalls, timerCalls, traceCalls, switches: int
  onTrace, onAp, onTimer, onRead: proc()
  mmTimerRevision: uint32
  mmTimerMutationTop: ptr MmTimerMutation
proc invoke(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
proc irqSave(): uint32 =
  result = enabled.uint32 * 8
  enabled = false
proc irqRestore(saved: uint32) = enabled = (saved and 8) != 0
proc chanEnvView(): ptr Env = addr env
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  events.add("clock")
  invoke(onRead)
  now
proc nimFwTrace2U32(tag: cstring; a, b: uint32) =
  doAssert enabled == incomingIrq
  inc traceCalls
  events.add("trace")
  invoke(onTrace)
proc vif_mgmt_get_first_ap_inf(): pointer =
  doAssert enabled == incomingIrq
  inc apCalls
  events.add("ap")
  invoke(onAp)
  if hasAp: cast[pointer](1) else: nil
proc chanConnLessDelayTimer(): pointer = cast[pointer](92)
proc chanConnlessTimerPending(generation: uint32): bool = timerPending
proc mm_timer_set(p: pointer; target: uint32) =
  doAssert enabled == incomingIrq and p == chanConnLessDelayTimer()
  inc timerCalls
  expiry = target
  timerPending = true
  events.add("timer")
  invoke(onTimer)
proc mmTimerSetLocked(p: pointer; target, saved: uint32) =
  doAssert not enabled
  irqRestore(saved)
  try: mm_timer_set(p, target)
  finally: discard irqSave()
proc chanCtxtForIdx(index: uint8): pointer = cast[pointer](index.uint + 1)
proc chan_switch_start(p: pointer) =
  if checkSwitchIrq: doAssert not enabled
  inc switches
proc assert_err(a, b: cstring; line: cint) = doAssert false
proc setup(flags = 2'u8; count = 2'u8; cursor = 3'u8; ap = false; irq = true) =
  env = Env(flags: flags, ctxtCount: count)
  scan_env.channelIndex = cursor
  hasAp = ap
  enabled = irq
  incomingIrq = irq
  checkSwitchIrq = false
  timerPending = false
  chanConnlessGeneration = 0
  txResetEpoch = 0
  chanCtxtEpochs = default(typeof(chanCtxtEpochs))
  rxVifEpochs = default(typeof(rxVifEpochs))
  events.setLen(0)
  apCalls = 0
  timerCalls = 0
  traceCalls = 0
  switches = 0
  expiry = 0
  now = 1000
  onTrace = nil
  onAp = nil
  onTimer = nil
  onRead = nil
'''


def source() -> str:
    tasks = (FW / "task_handlers.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    mutations = "".join(procedure(kernel, name) for name in (
        "mmTimerCancelMutations", "mmTimerBeginMutation", "mmTimerEndMutation"))
    return (layouts("MmTimerMutation") + PLATFORM + mutations + procedure(tasks, "chanConnLessDelay")
            + procedure(tasks, "chan_conn_less_delay_prog")
            + procedure(kernel, "chanConnlessDelayEvent")
            + procedure(kernel, "chan_conn_less_delay_evt"))


CASES = {
    "scan_factors": r'''
for collision in [false, true]:
  setup(flags = if collision: 0x82'u8 else: 2'u8)
  chan_conn_less_delay_prog()
  doAssert expiry == now + (if collision: 480000'u32 else: 240000'u32)
''',
    "ap_window": r'''
setup(count = 1, cursor = 1, ap = true)
chan_conn_less_delay_prog()
doAssert expiry == now + 240000
''',
    "lookup_order": r'''
setup(ap = true)
chan_conn_less_delay_prog()
doAssert events.find("ap") < events.find("timer")
''',
    "lookup_gates": r'''
for flags in [0'u8, 1, 3]:
  setup(flags = flags)
  chan_conn_less_delay_prog()
  doAssert apCalls == 0 and expiry == now + 30000
setup(count = 0)
chan_conn_less_delay_prog()
doAssert apCalls == 0 and expiry == now
setup(cursor = 0)
chan_conn_less_delay_prog()
doAssert apCalls == 0 and expiry == now + 30000
''',
    "vendor_matrix": r'''
for count in 0'u8 .. 3:
  for cursor in [0'u8, 1, 2, 3, 4, 7, 255]:
    for flags in [0'u8, 1, 2, 3, 0x82]:
      for ap in [false, true]:
        for irq in [false, true]:
          setup(flags, count, cursor, ap, irq)
          now = 0xFFFFFF00'u32
          chan_conn_less_delay_prog()
          let asksAp = count > 0 and (flags and 1) == 0 and
            (flags and 2) != 0 and cursor != 0
          var factor = 1'u32
          if count == 0: factor = 0
          elif asksAp and (ap or (cursor.uint32 + 1) mod 4 == 0):
            if count <= 1: factor = if ap: 8'u32 else: 4'u32
            else: factor = if (flags and 0x80) != 0: 16'u32 else: 8'u32
          doAssert expiry == now + factor * 30000
          doAssert timerCalls == 1 and apCalls == asksAp.int and enabled == irq
''',
    "trace_replacement": r'''
for boundary in 1 .. 2:
  setup()
  var expected: typeof(env)
  onTrace = proc() =
    if traceCalls < boundary:
      onTrace = proc() =
        inc chanConnlessGeneration
        env.flags = 0x94
        expected = env
    else:
      inc chanConnlessGeneration
      env.flags = 0x94
      expected = env
  chan_conn_less_delay_prog()
  doAssert env == expected and timerCalls == 0 and enabled
''',
    "ap_replacement": r'''
setup()
var expected: typeof(env)
onAp = proc() =
  inc chanConnlessGeneration
  env.flags = 0x94
  expected = env
chan_conn_less_delay_prog()
doAssert env == expected and timerCalls == 0 and enabled
''',
    "epoch_change": r'''
for change in 0 .. 3:
  setup()
  onAp = proc() =
    case change
    of 0: inc txResetEpoch
    of 1: inc chanCtxtEpochs[3]
    of 2: inc chanCtxtEpochs[4]
    else: inc rxVifEpochs[0]
  chan_conn_less_delay_prog()
  doAssert timerCalls == 0 and enabled
''',
    "reservation_cleanup": r'''
setup()
onAp = proc() = scan_env.channelIndex = 1
chan_conn_less_delay_prog()
doAssert timerCalls == 0 and (env.flags and 16) == 0 and enabled
''',
    "busy_and_nested": r'''
setup(flags = 0x12)
chan_conn_less_delay_prog()
doAssert timerCalls == 0 and apCalls == 0
setup()
onTrace = proc() = chan_conn_less_delay_prog()
chan_conn_less_delay_prog()
doAssert timerCalls == 1 and enabled
''',
    "additional_waiter_keeps_gate": r'''
for first in [1'u8, 2]:
  for boundary in ["entry", "clock", "ap", "delay"]:
    if first == 1 and boundary == "ap": continue
    for replaceOriginal in [false, true]:
      setup(first)
      let join = proc() =
        let originalSlot = if first == 1: 4 else: 3
        let nextSlot = if first == 1: 3 else: 4
        inc chanCtxtEpochs[nextSlot]
        if replaceOriginal: inc chanCtxtEpochs[originalSlot]
        env.flags = env.flags or (first xor 3)
        chan_conn_less_delay_prog()
      case boundary
      of "entry": onTrace = join
      of "clock": onRead = join
      of "ap": onAp = join
      else: onTrace = proc() = onTrace = join
      chan_conn_less_delay_prog()
      if replaceOriginal:
        doAssert env.flags == 3 and timerCalls == 0
      else:
        doAssert env.flags == 0x13 and timerCalls == 1 and expiry == now + 30000
      doAssert enabled and mmTimerMutationTop == nil
''',
    "event_irq": r'''
for irq in [false, true]:
  for flags in [1'u8, 2]:
    setup(flags = flags, irq = irq)
    checkSwitchIrq = true
    chan_conn_less_delay_evt()
    doAssert switches == 1 and enabled == irq
    doAssert env.flags == (if flags == 1: 4'u8 else: 8'u8)
''',
    "event_takes_over": r'''
setup()
onTrace = proc() = chan_conn_less_delay_evt()
chan_conn_less_delay_prog()
doAssert timerCalls == 0 and switches == 1 and env.flags == 0x18 and enabled
''',
    "preparation_exception": r'''
for irq in [false, true]:
  for boundary in 0 .. 3:
    setup(irq = irq)
    let fail = proc() = raise newException(ValueError, "connectionless preparation")
    case boundary
    of 0: onTrace = fail
    of 1: onRead = fail
    of 2: onAp = fail
    else: onTrace = proc() = onTrace = fail
    var raised = false
    try: chan_conn_less_delay_prog()
    except ValueError: raised = true
    doAssert raised and enabled == irq and env.flags == 2 and timerCalls == 0
    doAssert mmTimerMutationTop == nil
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_connless_delay(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


TIMER_DOMAIN = r'''
var
  env: tuple[flags, ctxtCount: uint8]
  scan_env: tuple[channelIndex: uint8]
  chanConnlessGeneration, txResetEpoch: uint32
  chanCtxtEpochs: array[5, uint32]
  rxVifEpochs: array[2, uint32]
  apCalls: int
proc chanEnvView(): ptr typeof(env) = addr env
proc chanConnLessDelayTimer(): pointer = addr timers[3]
proc chanConnlessTimerPending(generation: uint32): bool =
  var node = mm_timer_list.first
  while node != nil:
    if cast[pointer](node) == chanConnLessDelayTimer(): return true
    node = node.next
proc vif_mgmt_get_first_ap_inf(): pointer =
  inc apCalls
  nil
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("boundary", ["normal", "entry_trace", "delay_trace", "joined"])
def test_connless_with_mm_timer(tmp_path: Path, mode: str, boundary: str) -> None:
    tasks = (FW / "task_handlers.nim").read_text()
    checks = r'''
now = 1000
env.flags = 2
env.ctxtCount = 2
scan_env.channelIndex = 3
'''
    if boundary == "joined":
        checks += r'''
onTrace = proc(tag: string) =
  if tag == "[WIFI-NIMFW] cld_prog delay ":
    onTrace = nil
    env.flags = env.flags or 1
    inc chanCtxtEpochs[4]
    chan_conn_less_delay_prog()
'''
    elif boundary != "normal":
        suffix = "flags" if boundary == "entry_trace" else "delay"
        checks += f'''
onTrace = proc(tag: string) =
  if tag == "[WIFI-NIMFW] cld_prog {suffix} ":
    onTrace = nil
    mm_timer_clear(chanConnLessDelayTimer())
'''
    checks += "chan_conn_less_delay_prog()\n"
    if boundary == "normal":
        checks += r'''
doAssert queueIds() == @[4'u] and timers[3].expiry == 241000
doAssert env.flags == 0x12 and apCalls == 1
'''
    elif boundary == "joined":
        checks += r'''
doAssert queueIds() == @[4'u] and timers[3].expiry == 31000
doAssert env.flags == 0x13 and apCalls == 1
'''
    else:
        checks += "doAssert queueIds().len == 0 and env.flags == 2\n"
    checks += "doAssert enabled and mmTimerMutationTop == nil\nfinish()\n"
    run_program(tmp_path, mode, timer_source() + TIMER_DOMAIN
                + procedure(tasks, "chanConnLessDelay")
                + procedure(tasks, "chan_conn_less_delay_prog") + checks)
