"""Exercise the shared scan/ROC gate with the real MM timer dispatcher."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_tbtt_timer_dispatch import source as timer_source


DOMAIN = r'''
var
  scan_env: tuple[channelIndex: uint8]
  switched: seq[uint8]
  onSwitch: proc()
proc vif_mgmt_get_first_ap_inf(): pointer = nil
proc chanStartConnlessSwitch(p: pointer) =
  doAssert not enabled
  for index in 0'u8 .. 4:
    if p == cast[pointer](addr contexts[index]):
      switched.add(index)
      invoke(onSwitch)
      return
  doAssert false
'''


def source() -> str:
    code = timer_source()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    worker = procedure(kernel, "chanConnlessDelayEvent")
    code = code.replace(procedure(code, "chanConnlessDelayEvent"), DOMAIN + worker)
    return code + procedure(tasks, "chanConnLessDelay") + procedure(
        tasks, "chan_conn_less_delay_prog") + r'''
proc setupConnless(flags = 2'u8; irq = true) =
  onSwitch = nil
  switched.setLen(0)
  setupTbtt()
  enabled = irq
  env.flags = flags
  scan_env.channelIndex = 3
  now = 1000
proc expireConnless() =
  now = timers[3].expiry + 51
  mm_timer_schedule()
setupConnless()
'''


CASES = {
    "normal": r'''
for irq in [false, true]:
  for flags in [1'u8, 2, 3]:
    setupConnless(flags, irq)
    chan_conn_less_delay_prog()
    doAssert env.flags == (flags or 16) and queueIds() == @[4'u]
    expireConnless()
    doAssert switched == @[if flags == 2: 3'u8 else: 4'u8]
    doAssert env.flags == (if flags == 1: 20'u8 elif flags == 2: 24'u8 else: 22'u8)
    doAssert enabled == irq and mmTimerMutationTop == nil and not mmTimerScheduling
''',
    "late_roc": r'''
chan_conn_less_delay_prog()
let deadline = timers[3].expiry
let serial = chanTimerCapture(addr timers[3])
env.flags = env.flags or 1
inc chanCtxtEpochs[4]
chan_conn_less_delay_prog()
doAssert timers[3].expiry == deadline and chanTimerCapture(addr timers[3]) == serial
expireConnless()
doAssert switched == @[4'u8] and env.flags == 22
''',
    "rearm_after_pop": r'''
chan_conn_less_delay_prog()
onUnlock = proc() =
  if mmTimerScheduling and mm_timer_list.first == nil:
    onUnlock = nil
    env.flags = 1
    chan_conn_less_delay_prog()
expireConnless()
doAssert switched.len == 0 and queueIds() == @[4'u] and env.flags == 17
expireConnless()
doAssert switched == @[4'u8] and env.flags == 20
''',
    "cancel_after_pop": r'''
for reset in [false, true]:
  setupConnless()
  chan_conn_less_delay_prog()
  onUnlock = proc() =
    if mmTimerScheduling and mm_timer_list.first == nil:
      onUnlock = nil
      if reset: mm_timer_init()
      else: mm_timer_clear(addr timers[3])
      env.flags = 1
  expireConnless()
  doAssert switched.len == 0 and env.flags == 1 and queueIds().len == 0
''',
    "changed_gate": r'''
for change in 0 .. 2:
  setupConnless()
  chan_conn_less_delay_prog()
  case change
  of 0: inc txResetEpoch
  of 1: inc chanConnlessGeneration
  else: env.flags = env.flags and not 16'u8
  let flags = env.flags
  expireConnless()
  doAssert switched.len == 0 and env.flags == flags
''',
    "return_home_after_next_dwell_is_armed": r'''
for outcome in 0 .. 3:
  setupConnless()
  env.ctxtCount = 1
  chan_conn_less_delay_prog()
  failIdle = outcome == 1
  if outcome == 2: inc txResetEpoch
  doAssert chanForceIdle() == (not failIdle)
  if outcome == 3:
    mm_timer_clear(chanConnLessDelayTimer())
    env.flags = 2
  expireConnless()
  doAssert switched == (if outcome == 0: @[3'u8] else: @[])
  doAssert env.flags == [24'u8, 18, 18, 2][outcome]
''',
    "clear_during_programming": r'''
for irq in [false, true]:
  for reset in [false, true]:
    setupConnless(irq = irq)
    onHardware = proc() =
      if reset: mm_timer_init()
      else: mm_timer_clear(addr timers[3])
    chan_conn_less_delay_prog()
    doAssert queueIds().len == 0 and env.flags == 2 and enabled == irq
    doAssert mmTimerMutationTop == nil
    chan_conn_less_delay_prog()
    expireConnless()
    doAssert switched == @[3'u8]
''',
    "prepare_exception": r'''
for irq in [false, true]:
  for boundary in ["in", "timer"]:
    setupConnless(irq = irq)
    onTrace = proc(tag: string) =
      if tag == "[WIFI-NIMFW] mm_timer_set " & boundary & " ":
        raise newException(ValueError, "MM preparation")
    var raised = false
    try: chan_conn_less_delay_prog()
    except ValueError: raised = true
    doAssert raised and enabled == irq and mmTimerMutationTop == nil
    doAssert env.flags == 2 and queueIds().len == 0
    onTrace = nil
    chan_conn_less_delay_prog()
    expireConnless()
    doAssert switched == @[3'u8]
''',
    "published_exception": r'''
for irq in [false, true]:
  setupConnless(irq = irq)
  onHardware = proc() = raise newException(ValueError, "MM hardware")
  var raised = false
  try: chan_conn_less_delay_prog()
  except ValueError: raised = true
  doAssert raised and enabled == irq and mmTimerMutationTop == nil
  doAssert env.flags == 18 and queueIds() == @[4'u]
  expireConnless()
  doAssert switched == @[3'u8] and env.flags == 24
''',
    "failed_rearm": r'''
chan_conn_less_delay_prog()
env.flags = 1
onTrace = proc(tag: string) =
  if tag == "[WIFI-NIMFW] mm_timer_set in ":
    raise newException(ValueError, "replacement preparation")
var raised = false
try: chan_conn_less_delay_prog()
except ValueError: raised = true
doAssert raised and env.flags == 1 and queueIds() == @[4'u]
onTrace = nil
expireConnless()
doAssert switched.len == 0 and env.flags == 1
chan_conn_less_delay_prog()
expireConnless()
doAssert switched == @[4'u8] and env.flags == 20
''',
    "other_callback": r'''
timers[3].callback = cast[pointer](expired)
mm_timer_set(addr timers[3], now + 100)
expireConnless()
doAssert delivered == @[4'u] and switched.len == 0 and env.flags == 2
''',
    "replacement_during_programming": r'''
for irq in [false, true]:
  setupConnless(irq = irq)
  onHardware = proc() =
    env.flags = 1
    chan_conn_less_delay_prog()
  chan_conn_less_delay_prog()
  doAssert env.flags == 17 and queueIds() == @[4'u] and enabled == irq
  expireConnless()
  doAssert switched == @[4'u8] and env.flags == 20
''',
    "inline_expiry": r'''
for irq in [false, true]:
  setupConnless(irq = irq)
  onHardware = proc() = expireConnless()
  chan_conn_less_delay_prog()
  doAssert switched == @[3'u8] and env.flags == 24 and queueIds().len == 0
  doAssert enabled == irq and mmTimerMutationTop == nil and not mmTimerScheduling
''',
    "single_use": r'''
chan_conn_less_delay_prog()
let serial = chanTimerCapture(addr timers[3])
expireConnless()
env.flags = 17
doAssert chanTimerDispatch(addr timers[3], timers[3].callback, nil, serial)
doAssert switched == @[3'u8] and env.flags == 17
''',
    "callback_rearm": r'''
chan_conn_less_delay_prog()
onSwitch = proc() =
  env.flags = 1
  chan_conn_less_delay_prog()
expireConnless()
doAssert switched == @[3'u8] and env.flags == 17 and queueIds() == @[4'u]
expireConnless()
doAssert switched == @[3'u8, 4'u8] and env.flags == 20
''',
    "scheduled_context": r'''
chan_conn_less_delay_prog()
env.scheduledCtxt = addr contexts[0]
expireConnless()
doAssert switched.len == 0 and env.flags == 24
''',
    "operating_scan_with_scheduled_context": r'''
for change in 0 .. 4:
  setupTbtt()
  armOperation(3, 4)
  env.scheduledCtxt = addr contexts[0]
  case change
  of 1: contexts[3].contextIndexOrMarker = 0xFF
  of 2: inc chanCtxtEpochs[3]
  of 3: env.currentCtxt = addr contexts[1]
  of 4: contexts[3].channel.primFreq = 2462
  else: discard
  now = timers[2].expiry + 51
  mm_timer_schedule()
  doAssert queueIds().len == 0
  doAssert operationDelivery == (if change == 0: @[(3'u8, 4'u8)] else: @[])

# Neither a scan switch nor an operating ROC ignores the scheduled context.
for (index, phase) in [(3'u8, 2'u8), (4'u8, 4'u8)]:
  setupTbtt()
  armOperation(index, phase)
  env.scheduledCtxt = addr contexts[0]
  now = timers[2].expiry + 51
  mm_timer_schedule()
  doAssert operationDelivery.len == 0

# A newer arm of the same slot must still suppress the popped deadline.
setupTbtt()
armOperation(3, 4)
onUnlock = proc() =
  if mmTimerScheduling and mm_timer_list.first == nil:
    onUnlock = nil
    armOperation(3, 4)
    env.scheduledCtxt = addr contexts[0]
now = timers[2].expiry + 51
mm_timer_schedule()
doAssert operationDelivery.len == 0 and queueIds().len == 1
now = timers[2].expiry + 51
mm_timer_schedule()
doAssert operationDelivery == @[(3'u8, 4'u8)] and queueIds().len == 0
''',
    "serial_wrap": r'''
chanConnlessTimerOwner.serial = high(uint32)
chan_conn_less_delay_prog()
doAssert chanTimerCapture(addr timers[3]) == 0
expireConnless()
doAssert switched == @[3'u8]
''',
    "callback_exception": r'''
chan_conn_less_delay_prog()
onSwitch = proc() = raise newException(ValueError, "channel switch")
var raised = false
try: expireConnless()
except ValueError: raised = true
doAssert raised and enabled and not mmTimerScheduling and mmTimerMutationTop == nil
doAssert switched == @[3'u8] and env.flags == 24 and queueIds().len == 0
''',
    "all_channel_timers": r'''
now = 0
arm()
armOperation()
chan_conn_less_delay_prog()
now = 151
mm_timer_schedule()
doAssert deliveredTbtt == @[1'u] and operationDelivery.len == 0 and switched.len == 0
now = timers[2].expiry + 51
mm_timer_schedule()
doAssert operationDelivery == @[(0'u8, 4'u8)] and switched.len == 0
expireConnless()
doAssert switched == @[3'u8]
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_connless_timer_dispatch(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


def switch_source() -> str:
    code = source()
    code = code.replace(procedure(code, "chanStartConnlessSwitch"),
                        "proc chanStartConnlessSwitch(target: pointer)\n", 1)
    code = code.replace("ctxtCount, flags: uint8,", "ctxtCount, flags, switchPending: uint8,", 1)
    # The pool link is a 32-bit field on RV32; it is not dereferenced here.
    pool = layouts("ChanCtxtView", "ChanScanPoolOverlay", "ChanRocOverlay")
    start, end = code.index("  Context = object"), code.index("  Vif = object")
    code = (code[:start] + pool.replace("link*: CoListHdr", "link*: uint32")
            + "  Context = ChanCtxtView\n" + code[end:])
    switch = (FW / "channel_switch.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    code += layouts("KeMsgHdr") + switch[:switch.index("proc chanSwitchCapture")] + r'''
const
  MM_FORCE_IDLE_REQ_MSG = 74'u16
  TASK_MM = 0'u8
  TASK_NONE = 255'u8
  KeMsgTailSlack = 4'u32
var
  message: tuple[header: KeMsgHdr, payload: array[32, uint64]]
  attempts, failures, sent: int
  onAlloc: proc()
proc chanProtectionInvalidate() = discard
proc chan_goto_idle_cb() {.cdecl.} = discard
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  doAssert p == addr message.payload
  addr message.header
proc ke_msg_try_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  doAssert not enabled and (id, dest, src) == (74'u16, 0'u8, 255'u8)
  inc attempts
  invoke(onAlloc)
  if failures > 0:
    dec failures
    return nil
  doAssert size <= sizeof(message.payload).uint32 and chanSwitchTags == nil
  message.header = KeMsgHdr(id: id, destId: dest, srcId: src, paramLen: size)
  addr message.payload
proc ke_msg_free(h: ptr KeMsgHdr) = doAssert false, "unexpected message drop"
'''
    for name in ("chanSwitchCapture", "chanSwitchContextCurrent", "chanSwitchTagFor",
                 "chanSwitchAllocate", "chanSwitchPublish", "chanSwitchAdmit"):
        code += procedure(switch, name)
    code += r'''
proc ke_msg_send(p: pointer) =
  doAssert chanSwitchAdmit(p) and env.switchPending == 1
  doAssert chanCtxtAt(env.scheduledCtxt).status == 2
  inc sent
'''
    for name in ("chanStartSwitch", "chan_switch_start", "chanStartConnlessSwitch"):
        code += procedure(tasks, name)
    return code + r'''
template scan: untyped = cast[ptr ChanScanPoolOverlay](addr contexts[3].channel)
template roc: untyped = cast[ptr ChanRocOverlay](addr contexts[4].channel)
proc setupScan(oom: int) =
  setupConnless()
  env.ctxtCount = 0
  attempts = 0
  sent = 0
  failures = oom
  onAlloc = nil
  chanSwitchTags = nil
  chanSwitchActive = nil
  scan.slot = 3
  scan.active = 1
  scan.durationTicks = 37
  scan.channel.primFreq = 2462
  roc.slot = 0xFF
  roc.stateLo = 0
proc checkRetry(flags: uint8) =
  doAssert env.flags == flags and env.scheduledCtxt == nil and env.switchPending == 0
  doAssert sent == 0 and chanSwitchTags == nil and queueIds() == @[4'u]
  doAssert chanConnlessTimerPending(chanConnlessGeneration)
  doAssert timers[3].expiry == now + 30_000 and hardware[^1] == (3, timers[3].expiry)
  doAssert scan.slot == 3 and scan.active == 1 and scan.durationTicks == 37
  doAssert scan.channel.primFreq == 2462
proc checkSent(index, flags: uint8; extra: uint32 = 0) =
  let target = addr contexts[index]
  doAssert sent == 1 and env.flags == flags and env.scheduledCtxt == target
  doAssert env.switchPending == 1 and target.status == 2
  doAssert not chanConnlessTimerPending(chanConnlessGeneration)
  doAssert queueIds() == @[cast[uint](target)] and timers[2].expiry == now + 4000 + extra
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_switch_allocation_handoff(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, switch_source() + r'''
for oom in [0, 2]:
  setupScan(oom)
  now = high(uint32) - 1000
  chan_conn_less_delay_prog()
  doAssert timers[3].expiry == now
  for failed in 1 .. oom:
    let oldSerial = chanTimerCapture(addr timers[3])
    expireConnless()
    checkRetry(0x12)
    doAssert attempts == failed and chanCtxtEpochs[3] == 0
    doAssert chanTimerDispatch(addr timers[3], timers[3].callback, nil, oldSerial)
    now += 2000
    mm_timer_schedule()
    doAssert attempts == failed and queueIds() == @[4'u]
  expireConnless()
  doAssert attempts == oom + 1
  checkSent(3, 0x18)

# Delayed ROC joins the gate while scan allocation is failing. Its own OOM
# preserves both singletons; it wins the next arbitration without losing scan.
setupScan(2)
env.ctxtCount = 2
env.currentCtxt = addr contexts[0]
chan_conn_less_delay_prog()
onAlloc = proc() =
  inc chanCtxtEpochs[4]
  roc.slot = 4
  roc.stateLo = 1
  roc.channel.primFreq = 2437
  env.flags = env.flags or 1
  chan_conn_less_delay_prog()
expireConnless()
checkRetry(0x13)
expireConnless()
checkRetry(0x13)
expireConnless()
checkSent(4, 0x16, 3000)
doAssert attempts == 3 and scan.active == 1 and roc.channel.primFreq == 2437

for change in 0 .. 6:
  setupScan(1)
  chan_conn_less_delay_prog()
  onAlloc = proc() =
    case change
    of 0: inc txResetEpoch
    of 1: inc chanCtxtEpochs[3]
    of 2: scan.channel.primFreq = 2417
    of 3: env.scheduledCtxt = addr contexts[1]
    of 4: mm_timer_clear(addr timers[3])
    of 5: onRead = proc() = inc chanCtxtEpochs[3]
    else:
      env.flags = 1
      roc.slot = 4
      roc.stateLo = 1
      chan_conn_less_delay_prog()
  expireConnless()
  doAssert scan.active == 1
  if change == 6:
    # No home: the replacement's zero-delay timer is due in this dispatch.
    doAssert attempts == 2
    checkSent(4, 0x14)
  else:
    doAssert attempts == 1 and sent == 0
    doAssert queueIds().len == 0 and env.flags == 0x18
    if change == 3: doAssert env.scheduledCtxt == addr contexts[1]

# A clear or same-address replacement from within retry programming owns
# the timer. The stale attempt must not retain or release its reservation.
for replace in [false, true]:
  setupScan(1)
  chan_conn_less_delay_prog()
  onAlloc = proc() =
    onTrace = proc(tag: string) =
      if tag != "[WIFI-NIMFW] mm_timer_set in ": return
      onTrace = nil
      if replace:
        inc chanCtxtEpochs[3]
        scan.channel.primFreq = 2437
        env.ctxtCount = 1
        env.flags = 2
        chan_conn_less_delay_prog()
      else:
        mm_timer_clear(addr timers[3])
  expireConnless()
  doAssert attempts == 1 and sent == 0
  if replace:
    doAssert queueIds() == @[4'u] and env.flags == 0x12
    doAssert timers[3].expiry == now + 120_000 and scan.channel.primFreq == 2437
  else:
    doAssert queueIds().len == 0 and env.flags == 2
    chan_conn_less_delay_prog()
  expireConnless()
  checkSent(3, 0x18)
''')
