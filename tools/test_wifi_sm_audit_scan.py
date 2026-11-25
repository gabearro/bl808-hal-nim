"""Audit the SCAN/SCANU state machines for overlap, cancellation and reset.

Each test drives the real Nim handlers through the fixtures used by the
neighbouring scan tests. Tests marked xfail(strict=True) demonstrate defects
found by the audit and flip to XPASS (a failure) once the defect is fixed:

SCAN-F1  A full MAC recovery (bl_reset_evt -> txl_reset bumps txResetEpoch
         outside chanForceIdle) makes every SM-owned scan exchange stale. The
         SCANU_START_CFM/SCANU_JOIN_CFM reply is freed unclaimed, and the
         loss is not recorded because the owner is no longer current. SM
         stays in SmScanningState/SmWaitingState; later connects return busy
         and disconnects remain saved.
SCAN-F2  The same recovery invalidates the channel timers that carry the
         scan slot (context 3). The connectionless gate and the dwell-end
         operation timer are dropped on dispatch. No START/END notice is ever
         published, so TASK_SCAN, SCANU and slot 3 stay busy for good.
SCAN-F3  MM_SCAN_CHANNEL_END_EARLY (quick-connect, flags bit 8) carries no
         owner. When it reaches an idle TASK_SCAN, it hits assert_err(186),
         which raises KE_EVT_RESET (a full MAC recovery, see F1/F2). It now
         carries the stamp of the dwell that was on its channel when SCANU
         asked, and only that dwell is ended.
SCAN-N1  A dwell switch the channel layer drops left TASK_SCAN waiting in
         state 2 for good. Stage 4 returns such a dwell to the
         connectionless gate (test_dropped_dwell_switch_still_starts_the_dwell).
         Structurally: each dwell holds its START and END from the moment it
         is asked for, the channel layer posts END wherever it retires slot
         3, and SCAN_ABORT_REQ in state 2 ends the dwell as soon as it starts.
SCAN-N3  The SM scan/join exchange was judged by an identity that included
         the STA VIF's epoch and type. Removing the STA VIF in state 1 or 2
         made SCANU's completion free SM's reply unrecorded, so SM stayed in
         state 1 or 2 for good. vif_mgmt_unregister now tells SM
         (smStaVifRetired): the attempt on the removed VIF ends there, in
         every state (tools/test_wifi_sm_table.py), and an answer to a request
         SM no longer waits on changes nothing.
"""

import re
from pathlib import Path

import pytest

from test_wifi_connless_timer_dispatch import source as connless_source
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_scan_table import harness as scan_harness
from test_wifi_sm_scan_completion import source as completion_source
from test_wifi_tbtt_timer_dispatch import source as timer_source


MODES = ["checked", "asan"]

TASKS = (FW / "task_handlers.nim").read_text()

# The TX drain of a channel switch (chanForceIdle). SM's scan exchange is
# not a frame, so it carries no TX reset epoch.
CHANNEL_DRAIN = r'''
var txResetEpoch: uint32
var failIdle: bool
proc mm_force_idle_req(): bool =
  doAssert not enabled
  inc txResetEpoch
  not failIdle
'''

DELIVERY = r'''
proc deliver(reply: pointer; id = SCANU_START_CFM) =
  ## Dispatch a queued SCANU confirmation to SM as the kernel would.
  if reply == nil: return
  if id == SCANU_START_CFM:
    doAssert scanu_start_cfm_handler(reply) == KeMsgConsumed
  elif smScanAccept(reply, id):
    failures.add((0'u16, 0'u16)) # join accepted: SM proceeds to registration
  release(reply)
'''


def scan_exchange() -> str:
    return completion_source() + CHANNEL_DRAIN + procedure(
        (FW / "channel_timer.nim").read_text(), "chanForceIdle") + DELIVERY


# --------------------------------------------------------------------------
# Cancellation
# --------------------------------------------------------------------------

@pytest.mark.parametrize("mode", MODES)
def test_cancel_wins_over_found_bss_when_completion_already_queued(tmp_path: Path, mode: str) -> None:
    """SM_CONNECT_ABORT_REQ is handled after SCANU queued a successful CFM.

    The abort cannot reach the lower scan, so only cancelRequested carries it.
    The queued CFM must report ABORT_WHEN_SCANNING once and must not start a
    join, even though the cache now holds a matching BSS.
    """
    run_program(tmp_path, mode, scan_exchange() + r'''
begin()
let reply = complete(take())
doAssert reply != nil and keMsgHdrFromPayload(reply).id == SCANU_START_CFM
found = true
sm.cancelRequested = 1
deliver(reply)
doAssert sm.cancelRequested == 0 and failures == @[(26'u16, 0xFFFF'u16)]
doAssert queued.len == 0 and state == SmScanningState, "cancelled connection submitted a join"
finish()
''')


# --------------------------------------------------------------------------
# Overlap
# --------------------------------------------------------------------------

@pytest.mark.parametrize("mode", MODES)
def test_previous_session_completion_overlaps_new_scan(tmp_path: Path, mode: str) -> None:
    """Session A's queued CFM is dispatched while session B's scan is in flight.

    A's reply must not drive B, and its release must not register a lost
    exchange for B. B's own reply must still be accepted exactly once.
    """
    run_program(tmp_path, mode, scan_exchange() + r'''
for joining in [false, true]:
  let id = if joining: SCANU_JOIN_CFM else: SCANU_START_CFM
  begin(joining)
  let oldReply = complete(take())
  doAssert oldReply != nil
  # A finishes; B publishes its own request before A's CFM is dispatched.
  sm.connectInfo = addr replacement
  sm.connectIndMsg = addr otherIndication
  state = SmIdleState
  submit(joining)
  doAssert queued.len == 1 and state == (if joining: SmWaitingState else: SmScanningState)
  let newRequest = take()
  found = true
  if joining: doAssert not smScanAccept(oldReply, id)
  else: doAssert scanu_start_cfm_handler(oldReply) == KeMsgConsumed
  doAssert lookups == 0 and failures.len == 0 and queued.len == 0, "old CFM acted on session B"
  release(oldReply)
  found = false
  deliver(complete(newRequest), id)
  doAssert failures.len == 1
  if not joining: doAssert lookups == 1 and failures == @[(12'u16, 0xFFFF'u16)]
  finish()
''')


# --------------------------------------------------------------------------
# Reset
# --------------------------------------------------------------------------

@pytest.mark.parametrize("mode", MODES)
def test_channel_drain_keeps_owned_scan_cancellable(tmp_path: Path, mode: str) -> None:
    """A channel-switch TX drain (chanForceIdle) during an SM scan.

    The exchange survives the drain whether the CFM is already queued or not,
    and a cancellation recorded after the drain is still reported.
    """
    run_program(tmp_path, mode, scan_exchange() + r'''
for replyQueued in [false, true]:
  begin()
  let request = take()
  var reply: pointer
  if replyQueued: reply = complete(request)
  let before = txResetEpoch
  doAssert chanForceIdle() and txResetEpoch == before + 1
  sm.cancelRequested = 1
  if not replyQueued: reply = complete(request)
  doAssert reply != nil
  deliver(reply)
  doAssert failures == @[(26'u16, 0xFFFF'u16)] and sm.cancelRequested == 0
  finish()
''')


FULL_RECOVERY = {
    # SCANU finishes the scan after the recovery and queues its CFM.
    "completion_after_recovery": r'''
begin()
let request = take()
inc txResetEpoch # bl_reset_evt -> txl_reset, not the chanForceIdle drain
deliver(complete(request))
''',
    # The SCANU_START_REQ is still queued; SCANU's entry check
    # (smScanRefused) lets SM's live request through.
    "queued_request_after_recovery": r'''
begin()
let request = take()
inc txResetEpoch
doAssert not smScanRefused(request)
deliver(complete(request))
''',
    "join_completion_after_recovery": r'''
begin(true)
let request = take()
inc txResetEpoch
deliver(complete(request), SCANU_JOIN_CFM)
''',
    # The host times out and aborts; SmScanningState only records the flag.
    "abort_after_recovery": r'''
begin()
let request = take()
inc txResetEpoch
sm.cancelRequested = 1
deliver(complete(request))
''',
}


@pytest.mark.parametrize("case", FULL_RECOVERY)
def test_full_recovery_during_owned_scan_reaches_sm(tmp_path: Path, case: str) -> None:
    run_program(tmp_path, "checked", scan_exchange() + FULL_RECOVERY[case] + r'''
doAssert failures.len == 1, "SM never received a terminal scan result after MAC recovery"
finish()
''')


RADIO_DEADLINES = {
    # Slot 3 is on channel; only its operation timer can publish the END.
    "dwell_end": (timer_source, r'''
for irq in [false, true]:
  setupTbtt()
  enabled = irq
  armOperation(3, 4)
  recoverMac()
  now = timers[2].expiry + 51
  mm_timer_schedule()
  doAssert operationDelivery == @[(3'u8, 4'u8)], "scan dwell end was dropped"
'''),
    # Slot 3 is requested and waits for the connectionless gate.
    "dwell_gate": (connless_source, r'''
for irq in [false, true]:
  setupConnless(2, irq)
  chan_conn_less_delay_prog()
  recoverMac()
  expireConnless()
  doAssert switched == @[3'u8], "scan dwell never started"
'''),
}


# Both timer fixtures include the real channel_timer.nim.
RECOVERY = r'''
proc recoverMac() =
  # bl_reset_evt: txl_reset drains TX, then the recovery carries what is owed.
  inc txResetEpoch
'''


@pytest.mark.parametrize("case", RADIO_DEADLINES)
def test_scan_radio_deadlines_survive_full_recovery(tmp_path: Path, case: str) -> None:
    fixture, body = RADIO_DEADLINES[case]
    run_program(tmp_path, "checked", fixture() + RECOVERY + body)


@pytest.mark.parametrize("case", RADIO_DEADLINES)
def test_scan_radio_deadlines_survive_retried_recovery(tmp_path: Path, case: str) -> None:
    """txl_reset advances the epoch, times out, and the recovery is retried."""
    fixture, body = RADIO_DEADLINES[case]
    retried = RECOVERY.replace(
        "  inc txResetEpoch\n", "  inc txResetEpoch # first attempt timed out\n  inc txResetEpoch\n")
    assert retried != RECOVERY
    run_program(tmp_path, "checked", fixture() + retried + body)


@pytest.mark.parametrize("mode", MODES)
def test_probe_expiry_behind_dwell_end_is_inert(tmp_path: Path, mode: str) -> None:
    """A SCAN_PROBE_TIMER expiry posted before END(n) cleared the timer.

    The expiry carries dwell n's stamp: it must not transmit on channel n+1
    while that dwell is pending or running, nor after the request completes.
    A live dwell still sends its repeat probe."""
    run_program(tmp_path, mode, scan_harness() + r'''
scan_init()
scanu_init()
discard newUpper(SCANU_START_REQ, HostTask, 2)
while queue.len > 0 or states[TASK_SCAN] != ScanChannelPendingState: doAssert step()
arrive()
doAssert step() and states[TASK_SCAN] == ScanChannelRunningState and probes == 1
let first = timer.stamp
discard stale(SCAN_PROBE_TIMER, first)
doAssert step() and probes == 2, "a live dwell's repeat probe was dropped"
let expiry = stale(SCAN_PROBE_TIMER, first)   # posted before END(0) cleared the timer
queue.delete(queue.find(expiry))
retire()
doAssert step()                               # END(0): channel 1 pending
doAssert states[TASK_SCAN] == ScanChannelPendingState and scan_env.channelIndex == 1
queue.insert(expiry, 0)
doAssert step() and probes == 2, "channel 0 probe expiry transmitted during channel 1 setup"
discard stale(SCAN_PROBE_TIMER, first)
arrive()
doAssert step() and probes == 2             # the old expiry, ahead of START(1)
doAssert step() and probes == 3             # START(1) probes once
discard stale(SCAN_PROBE_TIMER, first)
doAssert step() and probes == 3, "channel 0 probe expiry transmitted on channel 1"
discard stale(SCAN_PROBE_TIMER, timer.stamp)
doAssert step() and probes == 4
finish("probe")
discard stale(SCAN_PROBE_TIMER, first)
doAssert step() and probes == 4
doAssert heap.len == 0 and queue.len == 0
''')


def test_early_end_without_a_running_dwell_sends_nothing(tmp_path: Path) -> None:
    """Quick connect matched a frame that SCANU dispatched with no dwell on
    its channel (idle, or between dwells). Nothing is sent, so nothing can
    reach an idle TASK_SCAN and assert."""
    run_program(tmp_path, "checked", scan_harness() + r'''
scan_init()
scanu_init()
scanEarlyEndRequest()
doAssert queue.len == 0, "early end sent with no dwell to end"
discard newUpper(SCANU_START_REQ, HostTask, 2)
while queue.len > 0 or states[TASK_SCAN] != ScanChannelPendingState: doAssert step()
scanEarlyEndRequest()
doAssert queue.len == 0, "early end sent for a dwell not on its channel"
finish("pending")
''')


def test_early_end_only_ends_the_dwell_that_asked(tmp_path: Path) -> None:
    run_program(tmp_path, "checked", scan_harness() + r'''
proc running(channels: int) =
  scan_init()
  scanu_init()
  requests.setLen(0)
  answers.setLen(0)
  arrivals = 0
  terminations = 0
  discard newUpper(SCANU_START_REQ, HostTask, channels)
  while queue.len > 0 or states[TASK_SCAN] != ScanChannelPendingState: doAssert step()
  arrive()
  doAssert step() and states[TASK_SCAN] == ScanChannelRunningState

# The dwell that asked is ended; a duplicate request finds it gone.
running(3)
scanEarlyEndRequest()
scanEarlyEndRequest()
doAssert queue.len == 2
doAssert step() and terminations == 1 and queue.len == 2   # its END is queued
finish("duplicate")
doAssert terminations == 1 and arrivals == 3

# Overlap: the request is dispatched after the scan moved to the next channel.
running(3)
scanEarlyEndRequest()
let early = queue.pop()
retire()
doAssert step() and scan_env.channelIndex == 1
arrive()
doAssert step()
queue.add(early)
doAssert step() and terminations == 0, "early end for channel 0 ended channel 1"
finish("overlap")

# Cancellation and reset: the request is dispatched after TASK_SCAN's request
# ended (abort) or after a reset; it is dropped instead of asserting.
for reset in [false, true]:
  running(2)
  scanEarlyEndRequest()
  let late = queue.pop()
  if reset: mmReset()
  else:
    ke_msg_send(ke_msg_try_alloc(SCAN_ABORT_REQ, TASK_SCAN, HostTask, 0))
    doAssert step() and terminations == 1
  settle("ended")
  queue.add(late)
  doAssert step() and terminations == int(not reset) and states[TASK_SCAN] == ScanIdleState
  finish("ended")
''')


def test_abort_in_state_2_ends_the_dwell_when_it_starts(tmp_path: Path) -> None:
    """SCAN-N1, structural: SM's abort while the dwell waits for slot 3 sets
    the stop flag; the dwell leaves its channel as soon as it starts, END
    follows at once, the request ends after one dwell, and SM's scan gets
    its answer. The pinned handler only sets the flag in state 2, so the
    dwell then ran its full duration, probing."""
    run_program(tmp_path, "checked", scan_harness() + r'''
scan_init()
scanu_init()
let upper = newUpper(SCANU_START_REQ, TASK_SM, 5)
while queue.len > 0 or states[TASK_SCAN] != ScanChannelPendingState: doAssert step()
smQueueOwnedScanAbort()
doAssert step() and scan_env.abortFlag == 1 and states[TASK_SCAN] == ScanChannelPendingState
arrive()
doAssert step() and terminations == 1 and probes == 0
doAssert scanSlot.slot == 0xFF and queue.len == 1 and
  keMsgHdrFromPayload(queue[0]).id == MM_SCAN_CHANNEL_END_IND
finish("abort")
doAssert arrivals == 1 and answers == @[(upper, SCANU_START_CFM)]
''')


def test_slot_3_retires_only_with_its_end() -> None:
    """SCAN-N1, structural: slot 3 leaves the pool only in chanCtxtOpEvent,
    which posts the dwell's END, and in chan_init (after scan_init answered
    TASK_SCAN's request). An abandoned switch to the slot returns the dwell to
    the connectionless gate instead (chanConnlessRequeue)."""
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    op = procedure(kernel, "chanCtxtOpEvent")
    retire = op.index("elif contextIndexOrMarker == 3:")
    assert "scanDwellPost(MM_SCAN_CHANNEL_END_IND)" in op[retire:op.index("ctxt.contextIndexOrMarker = 0xFF")]
    assert "scanDwellPost(MM_SCAN_CHANNEL_START_IND)" in procedure(kernel, "chan_pre_switch_channel")
    writers = sorted((path.name, line.strip()) for path in FW.glob("*.nim")
                     for line in path.read_text().splitlines()
                     if re.search(r"inc chanCtxtEpochs\[(3|index)\]", line))
    assert writers == [("kernel_mac_channel.nim", "inc chanCtxtEpochs[3]"),
                       ("kernel_mac_channel.nim", "inc chanCtxtEpochs[index]")], writers
    assert "inc chanCtxtEpochs[3]" in procedure(kernel, "chan_scan_req")
    mm = procedure(kernel, "mm_init")
    assert mm.index("scan_init()") < mm.index("chan_init()")
    switch = (FW / "channel_switch.nim").read_text()
    assert "chanConnlessRequeue()" in procedure(switch, "chanSwitchFinish")


def test_raw_send_during_scan_is_refused_with_confirmation(tmp_path: Path) -> None:
    """SCANU_RAW_SEND_REQ outside idle gets a nonzero CFM instead of silence."""
    run_program(tmp_path, "checked", r'''
type Header = object
  next: pointer
  id: uint16
  destId, srcId: uint8
  paramLen: uint32
const KeMsgConsumed = 0.cint
var confirmations: seq[(uint, uint8)]
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  cast[ptr Header](cast[uint](p) - sizeof(Header).uint)
proc scanu_raw_send_cfm(result: pointer; destId: uint8) =
  confirmations.add((cast[uint](result), destId))
''' + procedure(TASKS, "scanu_raw_send_busy_handler") + r'''
var message: tuple[header: Header, payload: array[8, uint8]]
message.header.srcId = 13
doAssert scanu_raw_send_busy_handler(addr message.payload) == KeMsgConsumed
doAssert confirmations == @[(1'u, 13'u8)]
doAssert scanu_raw_send_busy_handler(nil) == KeMsgConsumed and confirmations.len == 1
''')
    tables = (FW / "dispatch_tables.nim").read_text()
    default = tables.split("var scanu_default_state*", 1)[1].split("\n]", 1)[0]
    assert "SCANU_RAW_SEND_REQ, handler: keMsgHandlerAddress(scanu_raw_send_busy_handler)" in default


# --------------------------------------------------------------------------
# The slot-3 dwell switch (SCAN-N1)
# --------------------------------------------------------------------------

def dwell_switch_source() -> str:
    from test_wifi_switch_request import source as switch_source
    return switch_source() + r'''
const MM_SCAN_CHANNEL_END_IND = 76'u16
var chanConnlessGeneration: uint32
''' + procedure((FW / "kernel_mac_channel.nim").read_text(), "chanConnlessDelayEvent") + r'''
proc admitScan(home: bool) =
  ## chan_scan_req admitted slot 3 (flags 0x02) and armed the gate (0x10).
  resetSwitch()
  if home:
    let context = newTarget(2412)
    linkHome(context, VIF_TYPE_STA, 0)
    operate(context)
  let scan = chanCtxtForIdx(3)
  scan.contextIndexOrMarker = 3
  scan.status = 1
  channelEnv.flags = 0x12
proc dwellStarted(): bool =
  channelEnv.currentCtxt == cast[pointer](chanCtxtForIdx(3)) and
    notices == @[MM_SCAN_CHANNEL_START_IND] and (channelEnv.flags and 0x08) != 0
'''


DWELL_DROPS = {
    # MM is idle but the MAC is not: the blob's assert, a full recovery here.
    "mac_busy_in_idle": r'''
if mmState == MM_ACTIVE_STATE:
  doAssert dispatch()                # MM idles for the switch first
  idleInterrupt()
macState = 0x33
settle()
doAssert asserts == 1 and chanSw.phase == swQueued and requestLinked()
macState = 0                         # bl_reset_evt: MAC reset, MM's saved work rescheduled
rescheduleMm()
''',
    # A HW poll timeout inside the forced idle (hal_machw_reset/rxl/txl_reset).
    "forced_idle_timeout": r'''
forceFailed = true
settle()
doAssert chanSw.phase == swQueued and requestLinked() and mmState != HW_ACTIVE
forceFailed = false
''',
    # The kernel drops the request (it is never freed): the switch is
    # abandoned and the dwell goes back to its gate, which fires again.
    "request_dropped": r'''
ke_msg_free(co_list_pop_front(addr keMsgQueueSent))
doAssert chanSw.phase == swNone and channelEnv.scheduledCtxt == nil
doAssert (channelEnv.flags and 0x1E) == 0x12 and gates == 1, "dwell not returned to its gate"
chanConnlessDelayEvent()
''',
}


@pytest.mark.parametrize("home", [False, True], ids=["disconnected", "connected"])
@pytest.mark.parametrize("drop", DWELL_DROPS)
def test_dropped_dwell_switch_still_starts_the_dwell(tmp_path: Path, drop: str, home: bool) -> None:
    """SCAN-N1: TASK_SCAN waits in state 2 for START; only the dwell switch
    can deliver it. A switch that cannot proceed is retried after the MAC
    recovery or returned to the connectionless gate; END is never posted
    for a dwell that was not entered."""
    run_program(tmp_path, "checked", dwell_switch_source() + f"admitScan({str(home).lower()})\n"
                + r'''
chanConnlessDelayEvent()             # the gate fires: 0x02 -> 0x08, switch to slot 3
doAssert (channelEnv.flags and 0x0A) == 0x08 and chanSw.phase == swQueued
''' + DWELL_DROPS[drop] + r'''
settle()
doAssert MM_SCAN_CHANNEL_END_IND notin notices
doAssert dwellStarted(), "the scan dwell never started"
doAssert idleSwitch() and mmState == MM_ACTIVE_STATE
finishSwitch()
''')


# --------------------------------------------------------------------------
# The STA VIF removed during the scan or join (SCAN-N3)
# --------------------------------------------------------------------------

@pytest.mark.parametrize("joining", [False, True], ids=["scanning", "joining"])
@pytest.mark.parametrize("mode", MODES)
def test_sta_vif_removed_while_scanning_ends_attempt(tmp_path: Path, joining: bool, mode: str) -> None:
    """SCAN-N3: MM_REMOVE_IF_REQ for the STA VIF in state 1 or 2 resets its
    slot (vif_mgmt_unregister) while SCANU works on SM's request. The
    removal tells SM, which ends the attempt there; SCANU's later answer is
    for a request SM no longer waits on and changes nothing."""
    from test_wifi_registration_exchange import source
    run_program(tmp_path, mode, source() + f"let joining = {str(joining).lower()}\n" + r'''
begin(joining)
let request = take()
allocateAttempt()
removeVif()
doAssert state == SmIdleState and smOwn.request == nil,
  "[SCAN-N3] SM stayed in state " & $state & " after its STA VIF was removed"
found = true
let reply = complete(request)
if joining: doAssert scanu_join_cfm_handler(reply) == 0
else: doAssert scanu_start_cfm_handler(reply) == 0
release(reply)
doAssert failures.len == 0 and queued.len == 0 and state == SmIdleState
finish()
''')
