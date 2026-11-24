"""Bind queued TBTT delivery to the VIF/channel identity present at arm time."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_mm_timer_lifetime import source as mm_source


DECLARATIONS = r'''
proc chanTimerInvalidate(timer: pointer = nil)
proc chanTimerArming(timer: pointer)
proc chanTimerPublished(timer: pointer)
proc chanTimerCapture(timer: pointer): uint32
proc chanTimerDispatch(timer, callback, argument: pointer; serial: uint32): bool
var onUnlock: proc()
'''

DOMAIN = r'''
const MAX_VIFS = 2
type
  Node = object
    targetTime: uint32
    vifIdx, state: uint8
  Context = object
    channel: ChanCtxtDefView
    contextIndexOrMarker, status: uint8
    schedSlot, opSlot: uint16
  Vif = object
    chanCtxt: pointer
var
  nodes: array[2, Node]
  contexts: array[5, Context]
  vifs: array[2, Vif]
  rxVifEpochs, chanCtxtLinkEpochs: array[2, uint32]
  chanCtxtEpochs: array[5, uint32]
  txResetEpoch, chanStatusGeneration, chanConnlessGeneration: uint32
  deferred: pointer
  deliveredTbtt: seq[uint]
  onWork: proc()
  operationDelivery: seq[tuple[index: uint8, status: uint8]]
  onOperation, onIdleReset: proc()
  failIdle: bool
  env: tuple[currentCtxt, scheduledCtxt: pointer, ctxtCount, flags: uint8, lastMacTime: uint32]
proc chanTbttTimer(): pointer = addr timers[0]
proc chanCtxtOpTimer(): pointer = addr timers[2]
proc chanConnLessDelayTimer(): pointer = addr timers[3]
proc chanTbttDeferredSlot(): ptr pointer = addr deferred
proc chanTbttNodeAt(p: pointer): ptr Node =
  doAssert cast[uint](p) in 1'u .. 2'u
  addr nodes[cast[uint](p).int - 1]
proc chanCtxtForIdx(index: uint8): ptr Context = addr contexts[index]
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc chanEnvView(): ptr typeof(env) = addr env
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc smScanPreserveAcrossChannelReset(previous: uint32) = discard
proc smRegistrationPreserveAcrossChannelReset(previous: uint32) = discard
proc mm_force_idle_req(): bool =
  doAssert not enabled
  inc txResetEpoch
  invoke(onIdleReset)
  not failIdle
proc chanTbttSwitchEvent(p: pointer; callbackIrq: uint32) =
  doAssert not enabled
  irqRestore(callbackIrq)
  try:
    deliveredTbtt.add(cast[uint](p))
    invoke(onWork)
  finally: discard irqSave()
proc chan_tbtt_switch_evt(p: pointer) {.cdecl.} =
  let saved = irqSave()
  defer: irqRestore(saved)
  chanTbttSwitchEvent(p, saved)
proc chanCtxtOpEvent(p: pointer; callbackIrq: uint32) =
  doAssert not enabled
  irqRestore(callbackIrq)
  try:
    for index in 0'u8 .. 4:
      if p == cast[pointer](addr contexts[index]):
        operationDelivery.add((index, contexts[index].status))
        invoke(onOperation)
        return
    doAssert false
  finally: discard irqSave()
proc chan_ctxt_op_evt(p: pointer) {.cdecl.} =
  let saved = irqSave()
  defer: irqRestore(saved)
  chanCtxtOpEvent(p, saved)
proc chanConnlessDelayEvent() = discard
proc chan_conn_less_delay_evt() {.cdecl.} =
  let saved = irqSave()
  defer: irqRestore(saved)
  chanConnlessDelayEvent()
proc setupTbtt() =
  onUnlock = nil
  onWork = nil
  onOperation = nil
  onIdleReset = nil
  failIdle = false
  setup()
  deliveredTbtt.setLen(0)
  operationDelivery.setLen(0)
  nodes = default(typeof(nodes))
  vifs = default(typeof(vifs))
  contexts = default(typeof(contexts))
  rxVifEpochs = default(typeof(rxVifEpochs))
  chanCtxtLinkEpochs = default(typeof(chanCtxtLinkEpochs))
  chanCtxtEpochs = default(typeof(chanCtxtEpochs))
  txResetEpoch = 0
  chanConnlessGeneration = 0
  for index in 0 ..< contexts.len:
    contexts[index].contextIndexOrMarker = index.uint8
    contexts[index].status = 1
    contexts[index].schedSlot = 50
    contexts[index].opSlot = 30
    contexts[index].channel.primFreq = 2412
  vifs[0].chanCtxt = addr contexts[0]
  vifs[1].chanCtxt = addr contexts[1]
  nodes[1].vifIdx = 1
  timers[0].callback = cast[pointer](chan_tbtt_switch_evt)
  timers[2].callback = cast[pointer](chan_ctxt_op_evt)
  timers[3].callback = cast[pointer](chan_conn_less_delay_evt)
  env = default(typeof(env))
  env.ctxtCount = 2
proc arm(id = 1'u; target = 100'u32) =
  let node = chanTbttNodeAt(cast[pointer](id))
  node.state = 1
  node.targetTime = target
  deferred = cast[pointer](id)
  # Small IDs keep the TBTT-node mapping explicit in the native fixture.
  timers[0].env = id.uint32
  mm_timer_set(addr timers[0], target)
'''


def source() -> str:
    code = mm_source()
    # Operation contexts need native-width pointers in this host-only fixture.
    code = code.replace("env, expiry: uint32", "env: uint\n    expiry: uint32")
    for name in ("chanTimerInvalidate", "chanTimerArming", "chanTimerPublished",
                 "chanTimerCapture", "chanTimerDispatch"):
        if f"proc {name}(" in code:
            code = code.replace(procedure(code, name), "")
    code = code.replace(procedure(code, "irqRestore"), r'''
proc irqRestore(saved: uint32) =
  enabled = (saved and 8) != 0
  if enabled and onUnlock != nil: onUnlock()
''')
    update = procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_upd_ctxt_status")
    update = update.replace("cast[uint32](cast[uint](chanCtxtPtr))", "cast[uint](chanCtxtPtr)")
    operation = r'''
proc armOperation(index = 0'u8; phase = 4'u8) =
  if phase == 4:
    env.currentCtxt = addr contexts[index]
    env.scheduledCtxt = nil
  else:
    env.currentCtxt = addr contexts[(index.int + 1) mod contexts.len]
    env.scheduledCtxt = addr contexts[index]
  chan_upd_ctxt_status(addr contexts[index], phase)
'''
    return (DECLARATIONS + code + layouts("ChanCtxtDefView") + DOMAIN
            + (FW / "channel_timer.nim").read_text() + update + operation + "\nsetupTbtt()\n")


CASES = {
    "normal": r'''
for irq in [false, true]:
  setupTbtt()
  enabled = irq
  onWork = proc() = doAssert enabled == irq
  arm()
  now = 151
  mm_timer_schedule()
  doAssert deliveredTbtt == @[1'u] and enabled == irq
''',
    "switch_owned_idle": r'''
for outcome in 0 .. 3:
  setupTbtt()
  arm()
  failIdle = outcome == 1
  if outcome == 2: inc txResetEpoch
  doAssert chanForceIdle() == (not failIdle)
  if outcome == 3: inc chanCtxtLinkEpochs[0]
  now = 151
  mm_timer_schedule()
  # Only a changed channel binding retires the deadline; TX resets do not.
  doAssert deliveredTbtt == (if outcome != 3: @[1'u] else: @[])
''',
    "retired_vif": r'''
arm()
inc rxVifEpochs[0]
nodes[0].state = 0
now = 151
mm_timer_schedule()
doAssert deliveredTbtt.len == 0 and nodes[0].state == 0
''',
    "changed_identity": r'''
for change in [0, 1, 3, 4, 5]:
  setupTbtt()
  arm()
  case change
  of 0: inc chanCtxtLinkEpochs[0]
  of 1: inc chanCtxtEpochs[0]
  of 3: vifs[0].chanCtxt = addr contexts[1]
  of 4: contexts[0].channel.primFreq = 2462
  else: nodes[0].targetTime = 200
  now = 151
  mm_timer_schedule()
  doAssert deliveredTbtt.len == 0 and enabled
''',
    "rearm_after_pop": r'''
arm()
onUnlock = proc() =
  if mmTimerScheduling and mm_timer_list.first == nil:
    onUnlock = nil
    inc rxVifEpochs[0]
    arm(target = 500)
now = 151
mm_timer_schedule()
doAssert deliveredTbtt.len == 0 and timers[0].expiry == 500
now = 551
mm_timer_schedule()
doAssert deliveredTbtt == @[1'u] and enabled
''',
    "clear_after_pop": r'''
arm()
onUnlock = proc() =
  if mmTimerScheduling and mm_timer_list.first == nil:
    onUnlock = nil
    mm_timer_clear(addr timers[0])
now = 151
mm_timer_schedule()
doAssert deliveredTbtt.len == 0 and enabled
''',
    "reset_after_pop": r'''
arm()
onUnlock = proc() =
  if mmTimerScheduling and mm_timer_list.first == nil:
    onUnlock = nil
    mm_timer_init()
now = 151
mm_timer_schedule()
doAssert deliveredTbtt.len == 0 and enabled
''',
    "serial_wrap": r'''
chanTbttTimerOwner.serial = high(uint32)
arm()
doAssert chanTimerCapture(addr timers[0]) == 0
now = 151
mm_timer_schedule()
doAssert deliveredTbtt == @[1'u]
''',
    "other_timer": r'''
arm()
mm_timer_set(addr timers[1], 25)
now = 30
mm_timer_schedule()
doAssert delivered == @[2'u] and deliveredTbtt.len == 0
mm_timer_clear(addr timers[1])
now = 151
mm_timer_schedule()
doAssert deliveredTbtt == @[1'u]
''',
    "unrelated_vif": r'''
arm()
inc rxVifEpochs[1]
inc chanCtxtLinkEpochs[1]
inc chanCtxtEpochs[1]
now = 151
mm_timer_schedule()
doAssert deliveredTbtt == @[1'u]
''',
    "power_change": r'''
arm()
contexts[0].channel.txPower = 17
now = 151
mm_timer_schedule()
doAssert deliveredTbtt == @[1'u]
''',
    "failed_rearm": r'''
arm()
nodes[0].targetTime = 500
onTrace = proc(tag: string) =
  raise newException(ValueError, "timer programming")
var raised = false
try: mm_timer_set(addr timers[0], 500)
except ValueError: raised = true
doAssert raised and enabled
onTrace = nil
now = 151
mm_timer_schedule()
doAssert deliveredTbtt.len == 0
arm(target = 500)
now = 551
mm_timer_schedule()
doAssert deliveredTbtt == @[1'u]
''',
    "single_use": r'''
arm()
let serial = chanTimerCapture(addr timers[0])
now = 151
mm_timer_schedule()
doAssert chanTimerDispatch(addr timers[0], timers[0].callback, deferred, serial)
doAssert deliveredTbtt == @[1'u]
''',
    "exceptions": r'''
arm()
onWork = proc() = raise newException(ValueError, "TBTT delivery")
now = 151
var raised = false
try: mm_timer_schedule()
except ValueError: raised = true
doAssert raised and enabled and not mmTimerScheduling
let serial = chanTimerCapture(addr timers[0])
doAssert chanTimerDispatch(addr timers[0], timers[0].callback, deferred, serial)
doAssert deliveredTbtt.len == 1
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_tbtt_timer_dispatch(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
