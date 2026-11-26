"""Audit the PS/DPSM, keepalive and connection-loss machines across overlap,
cancellation and reset.

The PS fixtures run the real ps_machine.nim and power_save.nim transition
procedures with the real mm_set_ps_mode_req_handler, mm_force_idle_req and
chanForceIdle (the harness of test_wifi_ps_table.py). Only the platform edges
are modelled: the TX layer (a null frame is refused, or confirmed exactly
once by a delivery, an AC3 flush or a TX reset's drain), the MM timers, the
kernel's saved queue and the MAC PM register.

The audit findings below were reproduced and are now fixed; their tests
check the fix:

PSK-1  A dynamic-PS sleep transition in flight when a channel switch
       (chanForceIdle -> mm_force_idle_req -> txl_reset) or a MAC recovery
       advanced txResetEpoch was never finished: the flushed confirmation was
       suppressed by the reset epoch. A flushed confirmation now counts for
       its transition (ps_machine.nim).
PSK-2  A connection-loss indication published before a channel-switch reset was
       dropped, although the VIF and station were current: its disconnect
       handoff carried the publication's TX reset epoch, and the handler had
       already set state 10, so SM stayed there. The teardown (station_sm.nim)
       no longer carries an epoch and publishes state 10 only after its claim.
PS-N1  ps_tx_null_timer_handle flushed AC3 before ending the sleep; a
       channel-protection completion in that flush ran a TX reset and the
       handler then abandoned the sleep (pendingCount 0, bits 2|3 set, no
       owner). It now ends the sleep first and then flushes, as ps.o does.
PS-N2  ps_dpsm_update returned at a re-check after a nested TX reset inside a
       null frame's allocation, before arming its timer, leaving the
       transition without an owner; td_timer_end then skipped its re-arm. The
       timer is armed before the first frame, the walk has no early return
       and traffic detection ignores TX resets.
PS-N3  A DPSM decision taken during a scan or ROC dwell wrote the PM bit in
       the middle of the dwell, and the dwell's end restored the value saved
       at its start, contradicting PS. A dwell now holds the bit; PS records
       its choice and the dwell's end applies it. Explicit requests are no
       longer saved during a dwell. A transition sends no null frame during
       a dwell: the scanning STA's VIF is on channel, and the MAC would mark
       the frame with the held PM=0 (on the AP's channel, a sleep that tells
       the AP the station is awake). The transition ends at once; the
       departure's PM=1 null and the way home tell the AP.
PS-N4  A request saved behind the held one waited for an unrelated MM state
       change when the held one was cancelled. Every end of a transition,
       cancel included, releases MM's saved requests.
"""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_handler_contracts import owned_disconnect_source
from test_wifi_message_allocation import run_program
from test_wifi_ps_table import ps_source


MODES = ["checked", "release", "asan"]

PS_HELPERS = r'''
proc beginSleep() =
  ## Dynamic PS, awake; a traffic sample reports idle: DPSM starts a sleep.
  enter(2)
  discard ps_traffic_status_update(0, 4)
  doAssert (ps.flags and 0x0F) == 9 and psOwn.kind == psIdle
  frames.setLen(0)
  discard ps_traffic_status_update(0, 0)
  doAssert psOwn.kind == psSleep and ps.flags == 0x0D and ps.pendingCount == 1
  doAssert nullTimerArmed and (pmRegister and 4) != 0 and frames.len == 1
  doAssert frames[0].callback == cast[pointer](ps_enable_cfm) and not frames[0].done
'''


# --- Overlap ----------------------------------------------------------------

@pytest.mark.parametrize("mode", MODES)
def test_explicit_request_waits_behind_dpsm_sleep_and_runs_once(
        tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + PS_HELPERS + r'''
beginSleep()
# ME disables PS (for example on disconnect) while the sleep null frame is out.
let req = request(0)
let reply = meReservedReply
doAssert dispatch(req) == KeMsgSaved and savedRequests == @[req]
doAssert psOwn.request == nil and ps.flags == 0x0D and frames.len == 1
# The DPSM confirmation ends the sleep and releases MM's saved requests.
let before = reschedules
deliver(0, TxAck)
doAssert psOwn.kind == psIdle and ps.flags == 1 and not nullTimerArmed
doAssert reschedules == before + 1 and answers.len == 0
releaseSaved()
doAssert psOwn.request == req and frames.len == 2
doAssert frames[1].callback == cast[pointer](ps_disable_cfm) and not frames[1].pm
deliver(1, TxAck)
doAssert answers.len == 1 and answers[0].message == reply and answers[0].dest == TASK_ME
doAssert psOwn.kind == psIdle and ps.enabled == 0 and ps.pendingCount == 0
freeAnswers()
doAssert liveMessages == 0 and interrupts
# Later traffic samples cannot restart DPSM once PS is disabled.
doAssert ps_traffic_status_update(0, 4) == 0 and frames.len == 2
''')


@pytest.mark.parametrize("mode", MODES)
def test_dpsm_batch_retries_and_traffic_overlap_finish_once(
        tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + PS_HELPERS + r'''
enter(2, 2)
discard ps_traffic_status_update(0, 4)
frames.setLen(0)
discard ps_traffic_status_update(0, 0)
doAssert ps.flags == 0x0D and ps.pendingCount == 2 and frames.len == 2
deliver(0, TxAck)
doAssert ps.pendingCount == 1 and ps.flags == 0x0D and nullTimerArmed
# Traffic on the other station cannot start an overlapping wake batch.
let serial = psOwn.op.serial
doAssert ps_traffic_status_update(1, 4) == 0 and ps_dpsm_update(1) == 0
doAssert frames.len == 2 and (pmRegister and 4) != 0 and psOwn.op.serial == serial
# The second station's frame was not acknowledged: retry within the batch.
deliver(1, TxNoAck)
doAssert frames.len == 3 and frames[2].sta == 3 and vifs[1].psNullRetry == 1
doAssert frames[2].callback == cast[pointer](ps_enable_cfm) and ps.pendingCount == 1
doAssert frames[2].arg == serial
deliver(2, TxAck)
doAssert ps.pendingCount == 0 and ps.flags == 1 and not nullTimerArmed
doAssert vifs[1].keyPsState == 1 and losses.len == 0
# Exactly one end: the next traffic sample performs a full wake.
doAssert ps_traffic_status_update(0, 4) == 1
doAssert ps.flags == 9 and (pmRegister and 4) == 0 and ps.pendingCount == 0
doAssert frames.len == 5 and frames[3].callback == nil and frames[4].callback == nil
doAssert interrupts
''')


# --- Cancellation -------------------------------------------------------------

@pytest.mark.parametrize("mode", MODES)
def test_cancelled_explicit_transition_ignores_late_confirmation(
        tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + PS_HELPERS + r'''
# meControlReset runs only from MM_RESET_REQ (me_init) and ke_flush, never
# inside a null frame's submission, so only a cancel after it is driven.
enter(1)
let req = request(0)
let reply = meReservedReply
doAssert dispatch(req) == KeMsgNoFree
doAssert psOwn.request == req and ps.pendingCount == 1
# meControlReset: ME forgets its exchange and its reply, then cancels.
meControlCommand = nil
ke_msg_free(keMsgHdrFromPayload(reply))
meReservedReply = nil
psCancel()
doAssert psOwn.kind == psIdle and psOwn.request == nil and liveMessages == 0
doAssert ps.pendingCount == 0 and frames.len == 1 and reschedules == 1
# The AP acknowledges the cancelled transition's frame afterwards.
deliver(0, TxAck)
doAssert answers.len == 0 and ps.pendingCount == 0 and ps.enabled == 1
# The machine is reusable: a fresh request completes exactly once.
let again = request(0)
let againReply = meReservedReply
doAssert dispatch(again) == KeMsgNoFree
doAssert frames.len == 2
deliver(1, TxAck)
doAssert answers.len == 1 and answers[0].message == againReply
doAssert ps.enabled == 0 and ps.flags == 0 and psOwn.request == nil
freeAnswers()
doAssert liveMessages == 0 and interrupts
''')


@pytest.mark.parametrize("mode", MODES)
def test_cancel_releases_requests_saved_behind_it(tmp_path: Path, mode: str) -> None:
    """PS-N4: a request saved while another transition holds PS runs when
    that transition is cancelled, not at an unrelated MM state change."""
    run_program(tmp_path, mode, ps_source() + PS_HELPERS + r'''
enter(1)
let held = request(0, fromMe = false)
doAssert dispatch(held) == KeMsgNoFree and psOwn.request == held
let waiting = request(2, fromMe = false)
doAssert dispatch(waiting) == KeMsgSaved
let before = reschedules
psCancel()
doAssert reschedules == before + 1 and psOwn.kind == psIdle
releaseSaved()
doAssert psOwn.request == waiting
ackAll()
doAssert answers.len == 1 and answers[0].message == waiting
doAssert ps.enabled == 1 and (ps.flags and 1) == 1
freeAnswers()
doAssert liveMessages == 0
''')


# --- Reset --------------------------------------------------------------------

@pytest.mark.parametrize("mode", MODES)
def test_channel_switch_reset_finishes_dpsm_sleep_transition(
        tmp_path: Path, mode: str) -> None:
    """PSK-1: the sleep's frame flushed by the departure's TX reset counts."""
    run_program(tmp_path, mode, ps_source() + PS_HELPERS + r'''
beginSleep()
# A scan or multi-channel switch leaves the home channel before the ACK.
doAssert chanForceIdle()
doAssert txResetEpoch == 1 and frames[0].done and frames.len == 1
doAssert psOwn.kind == psIdle and ps.pendingCount == 0 and (ps.flags and 6) == 0,
  "DPSM transition stranded: flags=" & $ps.flags & " pending=" & $ps.pendingCount
doAssert ps.flags == 1 and not nullTimerArmed and (pmRegister and 4) != 0
mmState = MM_ACTIVE_STATE
# Traffic must then be able to bring the station out of power save.
discard ps_traffic_status_update(0, 4)
doAssert (ps.flags and 8) != 0 and (pmRegister and 4) == 0
''')


@pytest.mark.parametrize("mode", MODES)
def test_explicit_request_after_channel_switch_is_answered(
        tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + PS_HELPERS + r'''
beginSleep()
doAssert chanForceIdle()
mmState = MM_ACTIVE_STATE
let req = request(0)
let reply = meReservedReply
doAssert dispatch(req) == KeMsgNoFree
ackAll()
doAssert answers.len == 1 and answers[0].message == reply,
  "request parked: flags=" & $ps.flags & " pending=" & $ps.pendingCount
freeAnswers()
doAssert liveMessages == 0
''')


@pytest.mark.parametrize("mode", MODES)
def test_explicit_transition_across_channel_switch_completes(
        tmp_path: Path, mode: str) -> None:
    """A TX reset no longer requeues the held request (the removed
    mmPsModeRetryAfterReset): its flushed frame counts, the transition ends and
    answers it once. MM may be forced idle meanwhile."""
    run_program(tmp_path, mode, ps_source() + PS_HELPERS + r'''
enter(1)
let req = request(0)
let reply = meReservedReply
doAssert dispatch(req) == KeMsgNoFree
doAssert ps.pendingCount == 1 and frames.len == 1 and (pmRegister and 4) == 0
doAssert chanForceIdle() and mmState == HW_ACTIVE.uint16
doAssert psOwn.kind == psIdle and psOwn.request == nil and ps.pendingCount == 0
doAssert answers.len == 1 and answers[0].message == reply and ps.enabled == 0
doAssert frames.len == 1, "a flushed frame was sent again inside the drain"
# A request that arrives while MM is forced idle is not saved for it.
let later = request(2, fromMe = false)
doAssert dispatch(later) == KeMsgNoFree
ackAll()
doAssert answers.len == 2 and answers[1].message == later and ps.enabled == 1
freeAnswers()
doAssert liveMessages == 0 and interrupts
''')


@pytest.mark.parametrize("mode", MODES)
def test_mm_reset_retires_pending_ps_work(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + PS_HELPERS + r'''
beginSleep()
let req = request(0)
doAssert dispatch(req) == KeMsgSaved
# MM_RESET_REQ: me_init() resets ME (its reply and the saved request go with
# the kernel's queues), then mm_init() -> ps_init() ends the sleep unanswered.
ke_msg_free(keMsgHdrFromPayload(meReservedReply))
meReservedReply = nil
meControlCommand = nil
ke_msg_free(keMsgHdrFromPayload(req))
savedRequests.setLen(0)
let staleTimer = ps.txNullTimerEnv
ps_init()
doAssert psOwn.kind == psIdle and liveMessages == 0 and answers.len == 0
doAssert ps.enabled == 0 and ps.flags == 0 and ps.pendingCount == 0 and not nullTimerArmed
doAssert ps.txNullTimerCallback == cast[pointer](ps_tx_null_timer_handle)
# ME enables PS again before the pre-reset work has drained.
let again = request(2)
let reply = meReservedReply
doAssert dispatch(again) == KeMsgNoFree
doAssert psOwn.request == again and ps.flags == 1 and ps.pendingCount == 1
doAssert frames.len == 2 and frames[1].callback == cast[pointer](ps_enable_cfm)
# A stale TX-null timeout (the old sleep's stamp) does not end the new one.
ps_tx_null_timer_handle(staleTimer)
doAssert ps.pendingCount == 1 and not frames[1].done and answers.len == 0
# The pre-reset null frame's late ACK does not confirm the new request.
deliver(0, TxAck)
doAssert ps.pendingCount == 1 and answers.len == 0 and psOwn.request == again
deliver(1, TxAck)
doAssert answers.len == 1 and answers[0].message == reply and psOwn.request == nil
doAssert ps.enabled == 1 and ps.flags == 1 and ps.pendingCount == 0
freeAnswers()
doAssert liveMessages == 0 and interrupts
''')


# --- PS-N1, PS-N2, PS-N3 ------------------------------------------------------

@pytest.mark.parametrize("mode", MODES)
def test_tx_null_timeout_ends_the_sleep_before_flushing(tmp_path: Path, mode: str) -> None:
    """PS-N1: a protection frame on AC3 completes inside the timer's flush and
    its departure resets TX; the sleep has already ended, consistently."""
    run_program(tmp_path, mode, ps_source() + PS_HELPERS + r'''
beginSleep()
# The departure's protection frame is ahead of the sleep null on AC3; its
# confirmation runs chanForceIdle (txl_reset) from inside the flush.
var departed = false
proc protectionCfm(p: pointer; status: uint32) {.cdecl.} =
  departed = true
  doAssert psOwn.kind == psIdle, "the sleep was still live inside the flush"
  doAssert chanForceIdle()
frames.insert(Frame(sta: 2, callback: cast[pointer](protectionCfm), arg: 0, pm: true), 0)
doAssert fireNullTimer()
doAssert departed and txResetEpoch == 1
doAssert psOwn.kind == psIdle and ps.pendingCount == 0 and ps.flags == 1
doAssert not nullTimerArmed and (pmRegister and 4) != 0 and vifs[0].keyPsState == 1
mmState = MM_ACTIVE_STATE
# PS is not stranded: an explicit request runs and is answered.
let req = request(0, fromMe = false)
doAssert dispatch(req) == KeMsgNoFree
ackAll()
doAssert answers.len == 1 and answers[0].message == req and ps.enabled == 0
freeAnswers()
# A failed AC3 halt does not keep the sleep live either (ps.o order).
beginSleep()
clearResult = false
doAssert fireNullTimer() and psOwn.kind == psIdle and ps.flags == 1
''')


@pytest.mark.parametrize("mode", MODES)
def test_nested_reset_inside_dpsm_walk_keeps_its_owner(tmp_path: Path, mode: str) -> None:
    """PS-N2: the pool is empty when the second station's null is allocated;
    its recovery flush completes a protection frame whose departure resets TX,
    and that frame is refused. The sleep still has its timer, the first frame
    counts as flushed, and the walk ends it."""
    run_program(tmp_path, mode, ps_source() + PS_HELPERS + r'''
for sleeping in [true, false]:
  enter(2, 2)
  discard ps_traffic_status_update(0, 4)
  frames.setLen(0)
  if not sleeping:
    discard ps_traffic_status_update(0, 0)
    ackAll()
    frames.setLen(0)
  var sends = 0
  proc recovery() =
    inc sends
    if sends == 2:
      doAssert nullTimerArmed or not sleeping, "no owner while sending"
      doAssert chanForceIdle()
      nullSendStatus = 1
    else: onAlloc = recovery
  onAlloc = recovery
  discard ps_traffic_status_update(0, if sleeping: 0'u32 else: 4'u32)
  nullSendStatus = 0
  onAlloc = nil
  doAssert txResetEpoch == 1 and frames.len == 2
  doAssert psOwn.kind == psIdle and ps.pendingCount == 0 and (ps.flags and 6) == 0
  doAssert not nullTimerArmed
  doAssert ps.flags == (if sleeping: 1'u8 else: 9'u8)
  doAssert ((pmRegister and 4) != 0) == sleeping
  mmState = MM_ACTIVE_STATE
''')


@pytest.mark.parametrize("mode", MODES)
def test_traffic_detection_rearms_after_a_nested_reset(tmp_path: Path, mode: str) -> None:
    """PS-N2, traffic detection: td_timer_end re-arms its own timer after a
    traffic update whose sleep ran into a TX reset, and a wake's confirmation
    timer replaces the re-arm only for the VIF it armed."""
    run_program(tmp_path, mode, ps_source(td = True) + PS_HELPERS + r'''
enter(2)
discard ps_traffic_status_update(0, 4)
frames.setLen(0)
let td = addr tdEntries[0]
td.endActive = 1
td.prevFlags = 0x0C
# The sleep null's allocation recovery resets TX, and the null is refused.
onAlloc = proc() =
  doAssert chanForceIdle()
  nullSendStatus = 1
tdArms.setLen(0)
td_timer_end(td)
nullSendStatus = 0
doAssert txResetEpoch == 1 and psOwn.kind == psIdle and ps.flags == 1
doAssert tdArms == @[(0'u8, macNow + params.trafficPeriod)], $tdArms
# A wake: ps_disable_cfm_handle hands the TIM window to the detector, whose
# confirmation timer replaces the sample's re-arm.
mmState = MM_ACTIVE_STATE
pmResult = 1
td.period = 50
td.prevFlags = 0
tdArms.setLen(0)
td_timer_end(td)
doAssert ps.flags == 9 and tdArms == @[(0'u8, macNow + 50)], $tdArms
doAssert td.period == 0 and tdCfmArmed[0]
''')


@pytest.mark.parametrize("mode", MODES)
def test_dpsm_during_a_dwell_leaves_the_pm_bit_to_the_dwell(tmp_path: Path, mode: str) -> None:
    """PS-N3: a DPSM sleep decided during a scan dwell on the AP's channel
    (the scanning STA's VIF is on channel) records PM=1 without writing it
    and sends no null frame, which the MAC would mark PM=0: it ends at once.
    The dwell's end applies PM=1, so PS, the MAC and the departure's PM=1
    null agree, and the way home sends no wake. An explicit request during a
    dwell runs at once the same way; PS off then gets the wake on the way
    home."""
    run_program(tmp_path, mode, ps_source() + PS_HELPERS + r'''
enter(2)
discard ps_traffic_status_update(0, 4)
frames.setLen(0)
doAssert (pmRegister and 4) == 0 and not psOwn.pm
psDwellBegin()
doAssert (ps.statusFlags and 2) != 0 and (pmRegister and 4) == 0
doAssert chan_is_on_channel(addr vifs[0])
discard ps_traffic_status_update(0, 0)
doAssert frames.len == 0, "a sleep null went out during the dwell (it would say PM=0)"
doAssert psOwn.kind == psIdle and psOwn.pm and (pmRegister and 4) == 0
doAssert ps.flags == 1 and not nullTimerArmed and vifs[0].keyPsState == 1
doAssert (ps.statusFlags and 8) == 0 and losses.len == 0
psDwellEnd()
doAssert (ps.statusFlags and 2) == 0 and (pmRegister and 4) != 0
# The way home: PS asleep, so no wake null is due.
doAssert not psAwake()
# Traffic during a dwell wakes PS the same way, without a frame.
psDwellBegin()
discard ps_traffic_status_update(0, 4)
doAssert frames.len == 0
doAssert psOwn.kind == psIdle and not psOwn.pm and (ps.flags and 8) != 0
psDwellEnd()
doAssert (pmRegister and 4) == 0 and psAwake()
# An explicit request during a dwell is not saved, sends nothing and is
# answered at once; its PM choice waits for the dwell's end.
for requested in [1'u8, 0]:
  psDwellBegin()
  let req = request(requested, fromMe = false)
  doAssert dispatch(req) == KeMsgNoFree and savedRequests.len == 0
  doAssert frames.len == 0 and psOwn.kind == psIdle
  doAssert answers.len == 1 and answers[0].message == req
  doAssert psOwn.pm == (requested != 0) and (pmRegister and 4) == 0
  doAssert ps.enabled == uint8(requested != 0)
  doAssert ((ps.statusFlags and 8) != 0) == (requested == 0)
  psDwellEnd()
  doAssert ((pmRegister and 4) != 0) == (requested != 0) and psAwake() == (requested == 0)
  freeAnswers()
doAssert liveMessages == 0
''')


# Each fix above, reverted in the real source: its audit test fails again.
REVERTS = {
    "PS-N1": ("POWER", "  psFinish(if mmVifCurrent(psOwn.vif): psOwn.vif.vif else: nil)\n"
              "  discard txl_cntrl_clear_ac(3)",
              "  discard txl_cntrl_clear_ac(3)\n"
              "  if psOwn.op.live: psFinish(if mmVifCurrent(psOwn.vif): psOwn.vif.vif else: nil)",
              test_tx_null_timeout_ends_the_sleep_before_flushing),
    "PS-N2": ("POWER", "    ps.txNullTimerEnv = opStampEnv(stamp)\n"
              "    mm_timer_set(psTxNullTimer(), macTimeNow() + blPsParamsView().txNullTimeout)\n", "",
              test_nested_reset_inside_dpsm_walk_keeps_its_owner),
    "PS-N3": ("MACHINE", "  if not psDwell(): blmac_pwr_mgt_setf(pm.uint32)", "  blmac_pwr_mgt_setf(pm.uint32)",
              test_dpsm_during_a_dwell_leaves_the_pm_bit_to_the_dwell),
    "PS-N3-null": ("POWER", "      if vif.state != 0 and chan_is_on_channel(node) and not psDwell():",
                   "      if vif.state != 0 and chan_is_on_channel(node):",
                   test_dpsm_during_a_dwell_leaves_the_pm_bit_to_the_dwell),
    "PS-N4": ("MACHINE", "  if request != nil: ke_msg_free(keMsgHdrFromPayload(request))\n"
              "  discard ke_reschedule_saved_messages(TASK_MM)",
              "  if request != nil: ke_msg_free(keMsgHdrFromPayload(request))",
              test_cancel_releases_requests_saved_behind_it),
    "PSK-1": ("MACHINE", "  if not opCurrent(psOwn.op, opEnvStamp(env)): return\n",
              "  if not opCurrent(psOwn.op, opEnvStamp(env)) or (status and 0x80000000'u32) == 0: return\n",
              test_channel_switch_reset_finishes_dpsm_sleep_transition),
}


@pytest.mark.parametrize("finding", sorted(REVERTS))
def test_reverted_fix_reproduces_the_finding(tmp_path: Path, finding: str, monkeypatch) -> None:
    import test_wifi_ps_table as harness
    name, old, new, test = REVERTS[finding]
    source = getattr(harness, name)
    assert source.count(old) == 1, finding
    monkeypatch.setattr(harness, name, source.replace(old, new))
    with pytest.raises(AssertionError):
        test(tmp_path, "checked")


# --- Keepalive / connection loss ---------------------------------------------

LOSS_PLATFORM = r'''
const
  TASK_SM = 4'u8
  TASK_MM = 0'u8
  MAX_VIFS = 2
  MM_CONNECTION_LOSS_IND = 0x31'u16
  SM_SA_QUERY_TIMEOUT_IND_MSG = 0x1009'u16
  KeMsgTailSlack = 4'u32
  SmIdleState = 0'u16
  SmDisconnectingState = 10'u16
  KeMsgConsumed = 0.cint
  KeMsgSaved = 2.cint
  VIF_TYPE_STA = 0'u8
  HW_ACTIVE = 3
const MmConnectionLossIndPayloadSize = sizeof(MmConnectionLossIndPayload).uint32
type
  Vif = object
    vifIdx, staIdx, vifType, state: uint8
    beaconTimeoutBase: uint32
  MmEnv = object
    keepAliveLimit: uint32
    previousState: uint16
    hardwareMode: uint8
var
  vifs: array[2, Vif]
  mm: MmEnv
  rxVifEpochs: array[2, uint32]
  stationEpochs: array[16, uint32]
  mmBeaconProbeEpochs, mmTrafficProbeEpochs: array[MAX_VIFS, uint32]
  txResetEpoch: uint32
  mmConnLossTags: ptr MmConnLossTag
  chanTbttTimerOwner, chanConnlessTimerOwner: tuple[valid: bool, resetEpoch: uint32]
  sent: seq[pointer]
  interruptsEnabled = true
  nimFwDbgConnLossInd, nimFwDbgDisconnectProcess: uint32
  sm: tuple[connectInfo, connectIndMsg: pointer, saQueryActive: uint8]
  smState, mmState: uint16
  disconnects, tlvCalls: int
  lastReason: uint16
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc mmConnectionLossIndView(p: pointer): ptr MmConnectionLossIndPayload =
  cast[ptr MmConnectionLossIndPayload](p)
proc mmConnLossForget(header: pointer)
proc ke_msg_alloc(id: uint16; destination, source: uint8; length: uint32): pointer =
  let header = cast[ptr KeMsgHdr](alloc0(sizeof(KeMsgHdr) + length.int + KeMsgTailSlack.int))
  header.id = id
  header.destId = destination
  header.srcId = source
  header.paramLen = length
  cast[pointer](cast[uint](header) + sizeof(KeMsgHdr).uint)
proc ke_msg_free_payload(p: pointer) =
  let header = keMsgHdrFromPayload(p)
  mmConnLossForget(cast[pointer](header))
  dealloc(header)
proc ke_msg_send(p: pointer) = sent.add(p)
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc staDeleteEpoch(index: uint8): uint32 =
  if index < stationEpochs.len.uint8: stationEpochs[index] else: 0'u32
proc ke_state_get(task: uint8): uint16 =
  if task == TASK_SM: smState else: mmState
proc ke_state_set(task: uint8; value: uint16) =
  if task == TASK_SM: smState = value else: mmState = value
proc sm_connection_tlv_set() = inc tlvCalls
proc smEnvView(): ptr typeof(sm) = addr sm
proc mmEnvView(): ptr MmEnv = addr mm
proc macTimeNow(): uint32 = 0x1234
proc txlFrameCallbackCurrent(): bool = true
proc keTimerClearLocked(id: uint16; task: uint8; saved: uint32) = irqRestore(saved)
proc smCleanupBegin(vif: pointer; indication: pointer = nil; disconnected = false;
                    status = 0'u16; reason = 0'u16): bool =
  doAssert disconnected and indication == nil
  lastReason = status
  inc disconnects
  ke_state_set(TASK_SM, SmDisconnectingState)
  true
proc hal_machw_reset(): bool = true
proc rxl_reset(): bool = true
proc txl_reset(): bool =
  inc txResetEpoch
  true
proc smScanPreserveAcrossChannelReset(previous: uint32) = discard
proc smRegistrationPreserveAcrossChannelReset(previous: uint32) = discard
'''


def loss_source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = layouts("KeMsgHdr", "MmVifIdentity", "MmConnLossTag",
                   "MmConnectionLossIndPayload")
    code += LOSS_PLATFORM
    for name in ["mmCaptureVif", "mmVifCurrent", "mmConnLossTagAt", "mmConnLossProbeEpoch",
                 "mmConnLossTagFor", "mmPublishConnectionLoss", "mm_send_connection_loss_ind"]:
        code += procedure(kernel, name)
    code += procedure(kernel[kernel.index("proc mmConnLossForget(header: pointer) ="):],
                      "mmConnLossForget")
    code += owned_disconnect_source()
    code += procedure((FW / "task_handlers.nim").read_text(), "mm_connection_loss_ind_handler")
    code += procedure((FW / "power_save.nim").read_text(), "mm_ap_traffic_probe_cfm")
    code += ("\nwhen not declared(mmConfigCancelIdle):\n  proc mmConfigCancelIdle() = discard\n" + procedure(kernel, "mm_force_idle_req"))
    code += procedure((FW / "channel_timer.nim").read_text(), "chanForceIdle")
    return code


@pytest.mark.parametrize("mode", MODES)
def test_keepalive_loss_survives_channel_switch_reset(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, loss_source() + r'''
let handler: proc(param: pointer): cint {.cdecl.} = mm_connection_loss_ind_handler
vifs[1] = Vif(vifIdx: 1, staIdx: 2, vifType: VIF_TYPE_STA, state: 1)
proc exhaustKeepalive(): pointer =
  mm.keepAliveLimit = 0
  mm_ap_traffic_probe_cfm(addr vifs[1], 0x80000000'u32)  # Done without an ACK.
  doAssert mm.keepAliveLimit == 10 and sent.len == 1
  sent.pop()

# Control: without a channel switch the exhausted budget disconnects.
smState = SmIdleState
let direct = exhaustKeepalive()
doAssert handler(direct) == KeMsgConsumed and disconnects == 1 and lastReason == 22
ke_msg_free_payload(direct)
doAssert mmConnLossTags == nil

# A scan's channel switch is processed before SM dispatches the indication.
smState = SmIdleState
let pending = exhaustKeepalive()
doAssert chanForceIdle() and mmState == HW_ACTIVE.uint16
doAssert mmVifCurrent(mmCaptureVif(addr vifs[1]))  # Same VIF and station.
doAssert handler(pending) == KeMsgConsumed
doAssert disconnects == 2 and lastReason == 22,
  "keepalive loss silently dropped after channel-switch reset"
doAssert smState == SmDisconnectingState
''')
