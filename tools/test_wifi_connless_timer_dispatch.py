"""Exercise the shared scan/ROC gate with the real MM timer dispatcher."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_tbtt_timer_dispatch import source as timer_source


DOMAIN = r'''
var
  scan_env: tuple[channelIndex: uint8]
  switched: seq[uint8]
  onSwitch: proc()
proc vif_mgmt_get_first_ap_inf(): pointer = nil
proc chan_switch_start(p: pointer) =
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
