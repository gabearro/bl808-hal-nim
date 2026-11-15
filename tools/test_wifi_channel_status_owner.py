"""Keep channel status changes and timer publication in one owned operation."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_tbtt_timer_dispatch import source


CASES = {
    "clock_reuse": r'''
for index in 0 .. 4:
  setupTbtt()
  var expected: typeof(contexts)
  onRead = proc() =
    inc chanCtxtEpochs[index]
    contexts[index].status = 1
    contexts[index].opSlot = 71
    expected = contexts
  chan_upd_ctxt_status(addr contexts[index], 4)
  doAssert contexts == expected and queueIds().len == 0 and enabled
''',
    "newer_request": r'''
onRead = proc() = chan_upd_ctxt_status(addr contexts[0], 3)
chan_upd_ctxt_status(addr contexts[0], 4)
doAssert contexts[0].status == 3 and queueIds().len == 0 and enabled
''',
    "role_change": r'''
for change in 0 .. 4:
  setupTbtt()
  var expected: tuple[environment: typeof(env), values: typeof(contexts)]
  onRead = proc() =
    case change
    of 0: env.scheduledCtxt = addr contexts[1]
    of 1: env.currentCtxt = addr contexts[1]
    of 2: env.ctxtCount = 1
    of 3: env.lastMacTime = 17
    else: contexts[0].status = 3
    expected = (env, contexts)
  chan_upd_ctxt_status(addr contexts[0], 4)
  doAssert (env, contexts) == expected and queueIds().len == 0 and enabled
''',
    "clock_reset": r'''
onRead = proc() = inc txResetEpoch
chan_upd_ctxt_status(addr contexts[0], 4)
doAssert contexts[0].status == 1 and queueIds().len == 0 and enabled
''',
    "invalid_context": r'''
for invalid in 0 .. 3:
  setupTbtt()
  var target = cast[pointer](addr contexts[0])
  if invalid == 0: target = nil
  elif invalid == 1: target = cast[pointer](1)
  elif invalid == 2: contexts[0].contextIndexOrMarker = 255
  else: contexts[0].status = 0
  let before = contexts
  chan_upd_ctxt_status(target, 4)
  doAssert contexts == before and queueIds().len == 0 and enabled
''',
    "irq_contract": r'''
for irq in [false, true]:
  for phase in [2'u8, 4]:
    setupTbtt()
    enabled = irq
    onRead = proc() = doAssert not enabled
    onTrace = proc(tag: string) = doAssert enabled == irq
    onHardware = proc() = doAssert enabled == irq
    armOperation(0, phase)
    doAssert enabled == irq and queueIds().len == 1
''',
    "publication_before_unmask": r'''
for phase in [2'u8, 4]:
  setupTbtt()
  var observed = false
  onUnlock = proc() =
    onUnlock = nil
    observed = true
    doAssert chanCtxtTimerOwner.prepared or chanCtxtTimerOwner.valid
    doAssert chanCtxtTimerOwner.phase == phase
  armOperation(0, phase)
  doAssert observed and enabled
''',
    "trace_continuation": r'''
for phase in [3'u8, 4]:
  setupTbtt()
  onTrace = proc(tag: string) =
    onTrace = nil
    chan_upd_ctxt_status(addr contexts[0], phase)
  armOperation(0, 2)
  doAssert contexts[0].status == phase and queueIds().len == 1
  doAssert timers[2].expiry == (if phase == 3: 7000'u32 else: 51200'u32)
  now = timers[2].expiry + 51
  mm_timer_schedule()
  doAssert operationDelivery == @[(0'u8, phase)]
''',
    "clear_irq_contract": r'''
for irq in [false, true]:
  setupTbtt()
  enabled = irq
  armOperation(0, 2)
  env.ctxtCount = 1
  onHardware = proc() = doAssert enabled == irq
  chan_upd_ctxt_status(addr contexts[0], 4)
  doAssert contexts[0].status == 5 and queueIds().len == 0 and enabled == irq
  doAssert not chanCtxtTimerOwner.valid
''',
    "clear_rearms": r'''
for irq in [false, true]:
  setupTbtt()
  enabled = irq
  armOperation(0, 2)
  env.ctxtCount = 1
  onHardware = proc() = chan_upd_ctxt_status(addr contexts[0], 2)
  chan_upd_ctxt_status(addr contexts[0], 4)
  doAssert contexts[0].status == 2 and timers[2].expiry == 4000
  doAssert queueIds().len == 1 and chanCtxtTimerOwner.valid and enabled == irq
''',
    "exceptions": r'''
for irq in [false, true]:
  for boundary in 0 .. 2:
    setupTbtt()
    enabled = irq
    let fail = proc() = raise newException(ValueError, "status callback")
    if boundary == 0: onRead = fail
    elif boundary == 1:
      onTrace = proc(tag: string) = fail()
    else: onHardware = fail
    var raised = false
    try: armOperation(0, 4)
    except ValueError: raised = true
    doAssert raised and enabled == irq and mmTimerMutationTop == nil
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_channel_status_owner(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
