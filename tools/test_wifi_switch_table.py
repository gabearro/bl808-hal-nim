"""Drive the channel switch through every phase and disturbance.

The harness is the one of test_wifi_sm_audit_mm_chan: the real
channel_switch.nim and channel_protection.nim, chan_switch_start,
mm_force_idle_req_handler, chan_goto_idle_cb, chan_*_tx_cfm,
chan_pre_switch_channel, chan_ctxt_add/del/link/unlink and chanCtxtOpEvent
over the real kernel queues. This file also runs the real
chanConnlessDelayEvent (the connectionless gate) and routes chan_ctxt_op_evt
to the real chanCtxtOpEvent. chan_cde_evt is reduced to "the first operating
context".

A STA (VIF 0) operates on `home`; an AP (VIF 1) is linked to `away`. A switch
to `away`, the scan slot or the ROC slot, or to `away` while the gate claims a
scan dwell (the switch then enters the scan slot), is left in one phase:

  queued      its MM_FORCE_IDLE_REQ is waiting for MM;
  saved       the request is saved behind MM's GOING_TO_IDLE;
  protecting  the PM=1 null on `home` is outstanding;
  departing   that null was retired by a TX reset; the departure waits for MM;
  arrived     the switch is over and the destination is current.

Then one disturbance is applied and everything runs to quiescence: MM and the
TX path run, a dwell waiting at its gate gets the gate, a running dwell gets
its operation timer. After the disturbance and at every drain step:

  - MM is not left HW_ACTIVE;
  - scheduledCtxt is set exactly while a switch is live, and a live switch
    has a way forward (its request is queued, or protection frames are
    outstanding);
  - flag 0x08 (0x04) is set only while the scan (ROC) dwell is pending (a
    live switch will enter it) or running, and a dwell waiting at 0x02
    (0x01) has its gate armed.

At quiescence no switch is live, nothing is queued, MM is active, every scan
or ROC dwell was entered and ended, and whenever an operating context exists
one is current with the PM bit clear.
"""

from pathlib import Path
from textwrap import indent

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_sm_audit_mm_chan import source as audit_source


KERNEL = (FW / "kernel_mac_channel.nim").read_text()
OP_STUB = "proc chan_ctxt_op_evt(ctxt: pointer) = channelEnv.currentCtxt = nil\n"

TABLE = r'''
proc chan_ctxt_op_evt(ctxt: pointer) = chanCtxtOpEvent(ctxt, 0)

const
  Kinds = ["away", "scan", "roc", "away+scan"]
  Phases = ["queued", "saved", "protecting", "departing", "arrived"]

proc rocSlot(): pointer =
  ## Slot 4 admitted by chan_roc_req and promoted by the connectionless gate.
  let roc = chanCtxtForIdx(4)
  roc.contextIndexOrMarker = 4
  roc.invalidMarker = 0
  roc.status = 1
  channelEnv.flags = channelEnv.flags or 0x14
  cast[pointer](roc)

proc cdeModel() =
  ## chan_cde_evt reduced: event 1 re-points the switch, event 2 starts one,
  ## each at the first operating context; nothing while a dwell is claimed.
  if channelEnv.ctxtCount <= 1 or (channelEnv.flags and 0x0C) != 0: return
  let next = cast[pointer](channelEnv.activeList.first)
  if cdeEvents[^1] == 1: channelEnv.scheduledCtxt = next
  elif cdeEvents[^1] == 2 and channelEnv.scheduledCtxt == nil: chan_switch_start(next)

proc completeOutstanding(status: uint32) =
  while delivered < frames.len:
    inc delivered
    completeFrame(delivered - 1, status)

proc stage(kind, phase: int): pointer =
  ## Leave a switch to the destination of `kind` in `phase`; return it.
  let away = twoChannels().away
  onCde = cdeModel
  result = case kind
    of 1: scanSlot()
    of 2: rocSlot()
    else: away
  chan_switch_start(result)
  doAssert channelEnv.scheduledCtxt == result and requestLinked()
  # The gate claims a scan dwell while the switch is in flight; the switch
  # then goes to the scan slot instead (chan_pre_switch_channel).
  let arrival = if kind == 3: scanSlot() else: result
  case phase
  of 0: discard
  of 1: doAssert dispatch() and mmState == MM_GOING_TO_IDLE
  of 2, 3:
    settle()
    doAssert frames.len == 1 and chanSw.phase == swProtecting and mmState == MM_ACTIVE_STATE
    if phase == 3:
      # bl_reset_evt's txl_reset drains the null: the departure goes to MM.
      inc txResetEpoch
      txResetActive = true
      completeOutstanding(0x40000000'u32)
      txResetActive = false
      doAssert chanSw.phase == swDeparting and requestLinked()
  else:
    deliverPending()
    doAssert channelEnv.currentCtxt == arrival and chanSw.phase == swNone

proc check(label: string; quiet = false) =
  let env = addr channelEnv
  let live = chanSw.phase != swNone
  doAssert mmState != HW_ACTIVE, label & ": MM left HW_ACTIVE"
  doAssert (env.scheduledCtxt != nil) == live, label & ": scheduledCtxt and the switch disagree"
  if chanSw.phase in {swQueued, swDeparting}:
    doAssert requestLinked(), label & ": the switch waits for a request MM will never run"
  if chanSw.phase == swProtecting:
    doAssert env.scanDelayCount.int + env.connlessDelayCount.int > 0,
      label & ": protection wait with nothing outstanding"
  for (flag, index) in [(0x08'u8, 3'u8), (0x04'u8, 4'u8)]:
    if (env.flags and flag) != 0:
      doAssert live or env.currentCtxt == cast[pointer](chanCtxtForIdx(index)),
        label & ": a dwell is claimed but neither pending nor running"
  if (env.flags and 0x03) != 0:
    doAssert (env.flags and 0x10) != 0, label & ": a waiting dwell has no gate"
  if quiet:
    doAssert not live and env.switchPending == 0 and not requestLinked() and
      keMsgQueueSaved.first == nil, label & ": not quiescent"
    doAssert mmState == MM_ACTIVE_STATE, label & ": MM not active"
    doAssert (env.flags and 0x0F) == 0, label & ": a scan or ROC dwell was never served"
    if env.ctxtCount > 0:
      # With no context left the bit is cleared by the next arrival.
      doAssert env.currentCtxt != nil and slot(env.currentCtxt) <= 2,
        label & ": no operating channel is current"
      doAssert (pmRegister and 4) == 0, label & ": PM bit left set"

proc drain(label: string) =
  for round in 0 .. 5:
    deliverPending()
    check(label & " (drain " & $round & ")")
    let current = channelEnv.currentCtxt
    if current != nil and slot(current) in [3'u8, 4]:
      chanCtxtOpEvent(current, 0)        # the dwell's operation timer
    elif (channelEnv.flags and 0x03) != 0 and chanSw.phase == swNone:
      chanConnlessDelayEvent()           # the connectionless gate
    else:
      check(label & " (quiescent)", quiet = true)
      return
  doAssert false, label & ": no quiescence"

proc disturb(event: string; destination: pointer) =
  case event
  of "cfm_acked": completeOutstanding(0)
  of "cfm_failed": completeOutstanding(0x00800000'u32)
  of "cfm_flushed": completeOutstanding(0x40000000'u32)
  of "cfm_unrelated":
    chan_sta_tx_cfm(nil, 0)
    chan_ap_tx_cfm(nil, 0)
  of "unlink_destination", "unlink_other": chan_ctxt_unlink(1)
  of "unlink_source": chan_ctxt_unlink(0)
  of "unlink_all":
    chan_ctxt_unlink(1)
    chan_ctxt_unlink(0)
  of "op_deadline": chanCtxtOpEvent(destination, 0)
  of "reset": recoverMac()
  else: doAssert false, event

proc run(event: string) =
  for kind in 0 .. 3:
    if event == "unlink_destination" and kind notin [0, 3]: continue
    if event == "unlink_other" and kind notin [1, 2]: continue
    for phase in 0 .. 4:
      let label = event & " in " & Kinds[kind] & "/" & Phases[phase]
      let destination = stage(kind, phase)
      disturb(event, destination)
      check(label)
      drain(label)
      if kind in [1, 3]:
        doAssert notices == @[MM_SCAN_CHANNEL_START_IND, MM_SCAN_CHANNEL_END_IND],
          label & ": the scan dwell was not entered and ended once"
      elif kind == 2:
        doAssert cast[pointer](chanCtxtForIdx(4)) in tuned, label & ": ROC dwell never entered"
      finishSwitch()
'''


def source() -> str:
    code = audit_source()
    assert OP_STUB in code
    code = code.replace(OP_STUB, "proc chan_ctxt_op_evt(ctxt: pointer)\n", 1)
    code += "var chanConnlessGeneration: uint32\n" + procedure(KERNEL, "chanConnlessDelayEvent")
    return code + TABLE


EVENTS = ["cfm_acked", "cfm_failed", "cfm_flushed", "cfm_unrelated", "unlink_destination",
          "unlink_source", "unlink_other", "unlink_all", "op_deadline", "reset"]


@pytest.mark.parametrize("mode", ["checked", "release"])
@pytest.mark.parametrize("event", EVENTS)
def test_switch_table(tmp_path: Path, event: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + "\nblock:\n" + indent(f'run("{event}")\n', "  "))
