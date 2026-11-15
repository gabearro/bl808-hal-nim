"""Check operation-timer dispatch across slot reuse and protection TX states."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_tbtt_timer_dispatch import source


CASES = {
    "normal_phases": r'''
for irq in [false, true]:
  for phase in [2'u8, 4]:
    for index in 0'u8 .. 4:
      setupTbtt()
      enabled = irq
      onOperation = proc() = doAssert enabled == irq
      armOperation(index, phase)
      now = timers[2].expiry + 51
      mm_timer_schedule()
      doAssert operationDelivery == @[(index, phase)] and enabled == irq
''',
    "reused_context": r'''
for index in 0'u8 .. 4:
  setupTbtt()
  armOperation(index)
  inc chanCtxtEpochs[index]
  now = timers[2].expiry + 51
  mm_timer_schedule()
  doAssert operationDelivery.len == 0
''',
    "retired_context": r'''
armOperation()
contexts[0].contextIndexOrMarker = 255
now = timers[2].expiry + 51
mm_timer_schedule()
doAssert operationDelivery.len == 0
''',
    "identity_change": r'''
for change in 0 .. 5:
  setupTbtt()
  armOperation()
  case change
  of 0: inc txResetEpoch
  of 1: contexts[0].channel.primFreq = 2462
  of 2: contexts[0].status = 1
  of 3: env.currentCtxt = addr contexts[1]
  of 4: env.scheduledCtxt = addr contexts[1]
  else: contexts[0].contextIndexOrMarker = 255
  now = timers[2].expiry + 51
  mm_timer_schedule()
  doAssert operationDelivery.len == 0
''',
    "protection_state": r'''
for index in 0'u8 .. 4:
  for phase in [2'u8, 4]:
    setupTbtt()
    armOperation(index, phase)
    let deadline = timers[2].expiry
    let serial = chanTimerCapture(addr timers[2])
    chan_upd_ctxt_status(addr contexts[index], 3)
    doAssert timers[2].expiry == deadline and chanTimerCapture(addr timers[2]) == serial
    now = deadline + 51
    mm_timer_schedule()
    doAssert operationDelivery == @[(index, 3'u8)]
''',
    "rearm_after_pop": r'''
armOperation()
onUnlock = proc() =
  if mmTimerScheduling and mm_timer_list.first == nil:
    onUnlock = nil
    inc chanCtxtEpochs[0]
    armOperation(0, 2)
now = timers[2].expiry + 51
mm_timer_schedule()
doAssert operationDelivery.len == 0
now = timers[2].expiry + 51
mm_timer_schedule()
doAssert operationDelivery == @[(0'u8, 2'u8)]
''',
    "cancel_after_pop": r'''
for reset in [false, true]:
  setupTbtt()
  armOperation()
  onUnlock = proc() =
    if mmTimerScheduling and mm_timer_list.first == nil:
      onUnlock = nil
      if reset: mm_timer_init()
      else: mm_timer_clear(addr timers[2])
  now = timers[2].expiry + 51
  mm_timer_schedule()
  doAssert operationDelivery.len == 0
''',
    "other_timer_and_power": r'''
armOperation()
contexts[0].channel.txPower = 17
mm_timer_set(addr timers[1], 100)
now = 151
mm_timer_schedule()
doAssert delivered == @[2'u] and operationDelivery.len == 0
now = timers[2].expiry + 51
mm_timer_schedule()
doAssert operationDelivery == @[(0'u8, 4'u8)]
''',
    "both_channel_timers": r'''
arm()
armOperation()
now = 151
mm_timer_schedule()
doAssert deliveredTbtt == @[1'u] and operationDelivery.len == 0
mm_timer_clear(addr timers[0])
now = timers[2].expiry + 51
mm_timer_schedule()
doAssert operationDelivery == @[(0'u8, 4'u8)]
''',
    "failed_rearm": r'''
armOperation()
onTrace = proc(tag: string) =
  raise newException(ValueError, "operation timer programming")
var raised = false
try: armOperation(0, 2)
except ValueError: raised = true
doAssert raised and enabled
onTrace = nil
now = timers[2].expiry + 51
mm_timer_schedule()
doAssert operationDelivery.len == 0
armOperation(0, 2)
now = timers[2].expiry + 51
mm_timer_schedule()
doAssert operationDelivery == @[(0'u8, 2'u8)]
''',
    "single_use_and_exception": r'''
armOperation()
let serial = chanTimerCapture(addr timers[2])
onOperation = proc() = raise newException(ValueError, "operation callback")
now = timers[2].expiry + 51
var raised = false
try: mm_timer_schedule()
except ValueError: raised = true
doAssert raised and enabled and not mmTimerScheduling
doAssert chanTimerDispatch(addr timers[2], timers[2].callback, addr contexts[0], serial)
doAssert operationDelivery.len == 1
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_operation_timer_dispatch(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
