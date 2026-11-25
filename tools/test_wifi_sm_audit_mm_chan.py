"""Audit MM idle/active and channel-context switching for overlap, cancellation and reset.

The fixture is the channel switch harness of test_wifi_switch_request, which
compiles the real channel_switch.nim and channel_protection.nim with the
production chan_switch_start, mm_force_idle_req_handler, chan_goto_idle_cb,
chan_sta_tx_cfm, chan_pre_switch_channel, mm_back_to_host_idle and
chan_ctxt_add/del/link/unlink, over the real kernel queues. This file adds
the production mm_set_idle_req_handler, to observe whether the host can still
drive MM idle after each sequence, and chanCtxtOpEvent.

The audit's defects are now fixed and the tests pass:

MMCHAN-1  Retiring the switch destination redirects the in-flight switch to
          the remaining context (vendor chan_ctxt_unlink) instead of
          orphaning scheduledCtxt; chan_ctxt_del of a destination does the
          same.
MMCHAN-2  Unlinking the departing (source) context while its PM null is
          pending no longer cancels the switch; the destination is entered.
MMCHAN-3  Every end of a switch leaves MM out of HW_ACTIVE (hardening: the
          staleness is injected through fixture hooks).
MMCHAN-4  The return-home switch after the last scan dwell cannot be lost:
          the switch's MM_FORCE_IDLE_REQ is a static message.
MMCH-S1   A full MAC recovery during the protection wait completes the
          departure after the reset instead of cancelling it.
MMCH-S2   In-place TPC/bandwidth edits of the source or destination do not
          cancel a committed departure: a context is its slot and epoch.
MMCH-S6   The only operating context keeps the EDCA bank after its operation
          timer leaves it at status 1.
"""

from pathlib import Path
from textwrap import indent

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_switch_request import source as switch_source


KERNEL = (FW / "kernel_mac_channel.nim").read_text()
TASKS = (FW / "task_handlers.nim").read_text()


def source() -> str:
    code = switch_source() + r'''
const
  TaskGoingIdleState = 2'u16
  MM_SET_IDLE_REQ = 0x1A'u16
  MM_SET_IDLE_CFM = 0x1B'u16
  MM_SCAN_CHANNEL_END_IND = 76'u16
type MmSetIdleReqPayload = object
  idle: uint8
const MmSetIdleReqPayloadSize = sizeof(MmSetIdleReqPayload).uint32
var
  idleReplies: seq[uint16]
  delivered: int
proc smStaleRequest(p: pointer): bool = false
proc smCleanupAdmitRequest(p: pointer): bool = true
proc mmSetIdleReqView(p: pointer): ptr MmSetIdleReqPayload = cast[ptr MmSetIdleReqPayload](p)
proc ke_msg_send_basic_reply(p: pointer; id: uint16) = idleReplies.add(id)
proc chan_get_dominant_chan(): pointer = nil
proc chan_get_next_chan(): pointer = nil
'''
    code += procedure(TASKS, "mm_set_idle_req_handler")
    code += procedure(KERNEL, "chanCtxtOpEvent")
    return code + r'''
proc deliverPending() =
  ## Run MM and confirm every protection frame, until nothing is in flight.
  for round in 0 .. 3:
    settle()
    while delivered < frames.len:
      inc delivered
      completeFrame(delivered - 1)
    settle()

proc hostIdle(): bool =
  ## Host MM_SET_IDLE_REQ(1); one MAC idle transition may complete it.
  var request: tuple[header: KeMsgHdr; payload: MmSetIdleReqPayload]
  request.header = KeMsgHdr(id: MM_SET_IDLE_REQ, destId: TASK_MM, srcId: 3,
    paramLen: MmSetIdleReqPayloadSize)
  request.payload.idle = 1
  idleReplies.setLen(0)
  if mm_set_idle_req_handler(addr request.payload) == KeMsgSaved:
    idleInterrupt()
    if mm_set_idle_req_handler(addr request.payload) == KeMsgSaved: return false
  idleReplies == @[MM_SET_IDLE_CFM] and mmState == MM_IDLE

proc scanSlot(): pointer =
  ## Slot 3 admitted by chan_scan_req and promoted by the connectionless gate.
  let scan = chanCtxtForIdx(3)
  scan.contextIndexOrMarker = 3
  scan.status = 1
  channelEnv.flags = channelEnv.flags or 0x18
  cast[pointer](scan)

proc twoChannels(scanDestination = false): tuple[home, away: pointer] =
  ## A STA (VIF 0) operates on `home`; `away` is a second AP channel (VIF 1)
  ## or the scan slot. MM is active on `home`.
  resetSwitch()
  delivered = 0
  result.home = newTarget(2412)
  linkHome(result.home, VIF_TYPE_STA, 0)
  if scanDestination:
    result.away = scanSlot()
    activateVifs(1)
  else:
    result.away = newTarget(2437)
    linkHome(result.away, VIF_TYPE_AP, 1)
    activateVifs(2)
  operate(result.home)

proc stageSwitch(target: pointer; phase: int) =
  ## phase 0: request queued for MM; 1: saved behind MM GOING_TO_IDLE;
  ## 2: departure waiting for the PM null frame on the source channel.
  chan_switch_start(target)
  doAssert channelEnv.scheduledCtxt == target and requestLinked()
  case phase
  of 0: discard
  of 1:
    doAssert dispatch() and mmState == MM_GOING_TO_IDLE
  else:
    settle()
    doAssert frames.len >= 1 and chanSw.phase == swProtecting
    doAssert mmState == MM_ACTIVE_STATE

proc recoverMac() =
  ## bl_reset_evt: hal_machw_reset leaves the MAC idle, txl_reset's drain
  ## retires every frame with 0x40000000, then mm_reset reactivates an active
  ## MM and reschedules its saved work.
  macState = 0
  inc txResetEpoch
  txResetActive = true
  while delivered < frames.len:
    inc delivered
    completeFrame(delivered - 1, 0x40000000'u32)
  txResetActive = false
  if mmState == MM_ACTIVE_STATE: mm_active()
  else: ke_state_set(TASK_MM, MM_IDLE)
  rescheduleMm()
'''


PHASES = ["queued", "saved", "protection_wait"]


def run_case(tmp_path: Path, body: str, mode: str = "checked") -> None:
    run_program(tmp_path, mode, source() + "\nblock:\n" + indent(body, "  "))


# --------------------------------------------------------------------------
# Audit defects, now fixed
# --------------------------------------------------------------------------


@pytest.mark.parametrize("phase", range(3), ids=PHASES)
def test_unlink_switch_destination_keeps_scheduler_live(tmp_path: Path, phase: int) -> None:
    """MMCHAN-1: the AP stops while the switch to its channel is in flight."""
    run_case(tmp_path, f"let phase = {phase}\n" + r'''
let (home, away) = twoChannels()
stageSwitch(away, phase)
chan_ctxt_unlink(1)
doAssert channelEnv.ctxtCount == 1
deliverPending()
# Vendor: the switch continues to the remaining context.
doAssert channelEnv.scheduledCtxt == nil, "scheduledCtxt left without an owning request"
doAssert channelEnv.switchPending == 0
doAssert channelEnv.currentCtxt == home and mmState == MM_ACTIVE_STATE
# A later interface on another channel must still be schedulable.
let replacement = newTarget(2462)
linkHome(replacement, VIF_TYPE_AP, 1)
chan_switch_start(replacement)
doAssert requestLinked(), "chan_switch_start ignored: scheduledCtxt still set"
deliverPending()
doAssert channelEnv.currentCtxt == replacement and idleSwitch()
finishSwitch()
''')


@pytest.mark.parametrize("scan", [False, True], ids=["ap_destination", "scan_destination"])
def test_unlink_switch_source_during_protection_wait(tmp_path: Path, scan: bool) -> None:
    """MMCHAN-2: the STA disconnects before its PM null frame is confirmed."""
    run_case(tmp_path, f"let scan = {str(scan).lower()}\n" + r'''
let (home, away) = twoChannels(scan)
stageSwitch(away, 2)
chan_ctxt_unlink(0)
doAssert channelEnv.currentCtxt == nil
deliverPending()                     # the late null-frame confirmation arrives
# Vendor chan_sta_tx_cfm: last confirmation -> mm_force_idle_req + chan_pre_switch_channel.
doAssert channelEnv.currentCtxt == away, "destination abandoned with no current context"
doAssert channelEnv.scheduledCtxt == nil and mmState == MM_ACTIVE_STATE
if scan: doAssert notices == @[MM_SCAN_CHANNEL_START_IND]
finishSwitch()
''')


@pytest.mark.parametrize("cause", range(4), ids=[
    "retired_at_hw_active_publication", "destination_retired_in_force_idle",
    "source_retired_in_force_idle", "destination_retired_in_protection_completion"])
def test_abandoned_switch_leaves_host_bypass(tmp_path: Path, cause: int) -> None:
    """MMCHAN-3 (hardening): the staleness is injected through fixture hooks."""
    run_case(tmp_path, f"let cause = {cause}\n" + r'''
resetSwitch()
let source = newTarget(2412)
let target = newTarget(2437)
if cause == 3:                       # STA on the departing channel -> PM null frame
  linkHome(source, VIF_TYPE_STA, 0)
  activateVifs(1)
channelEnv.currentCtxt = source
chanCtxtAt(source).status = 5
let retireTarget = proc() = chan_ctxt_del(slot(target))
let retireSource = proc() = chan_ctxt_del(slot(source))
chan_switch_start(target)
case cause
of 0:
  onMmState = proc() =
    if mmState == HW_ACTIVE:
      onMmState = nil
      retireTarget()
of 1: onIdle = retireTarget
of 2: onIdle = retireSource
else: discard
doAssert mmState == MM_IDLE
settle()
if cause == 3:
  doAssert frames.len == 1 and mmState == MM_ACTIVE_STATE
  onIdle = retireTarget              # injected into the final confirmation's forced idle
  completeFrame(0)
doAssert channelEnv.scheduledCtxt == nil and chanSw.phase == swNone
# A retired source does not stop the switch (vendor). A retired target
# redirects it to the remaining context (cause 3: the source) or, with none
# left, ends it.
doAssert tuned == (if cause == 2: @[target] elif cause == 3: @[source] else: @[])
doAssert mmState != HW_ACTIVE, "switch ended while MM is host-bypassed"
doAssert hostIdle(), "MM_SET_IDLE_REQ can no longer complete"
finishSwitch()
''')


def test_return_home_after_last_scan_dwell_is_never_lost(tmp_path: Path) -> None:
    """MMCHAN-4: the dwell end's chan_switch_start(home) cannot fail.

    The switch's MM_FORCE_IDLE_REQ is static, so an exhausted message heap
    (the audit's trigger) is not involved at all; the harness has no
    allocator for it to call.
    """
    run_case(tmp_path, r'''
resetSwitch()
let home = newTarget(2412)
linkHome(home, VIF_TYPE_STA, 0)
let scan = scanSlot()
channelEnv.currentCtxt = scan
chanCtxtAt(scan).status = 4
mmState = MM_ACTIVE_STATE
chanCtxtOpEvent(scan, 0)             # the last dwell's operation timer
doAssert (channelEnv.flags and 0x18) == 0 and chanCtxtAt(scan).contextIndexOrMarker == 255
doAssert channelEnv.scheduledCtxt == home and requestLinked()
settle()
doAssert channelEnv.currentCtxt == home and tuned == @[home] and idleSwitch()
doAssert mmState == MM_ACTIVE_STATE
finishSwitch()
''')


@pytest.mark.parametrize("scan", [False, True], ids=["ap_destination", "scan_destination"])
def test_recovery_during_protection_wait_completes_departure(tmp_path: Path, scan: bool) -> None:
    """MMCH-S1: an assert raises KE_EVT_RESET inside the protection wait.

    txl_reset's drain retires the PM null; the departure must run after the
    reset (never inside its window) and enter the destination.
    """
    run_case(tmp_path, f"let scan = {str(scan).lower()}\n" + r'''
let (home, away) = twoChannels(scan)
stageSwitch(away, 2)
doAssert (pmRegister and 4) != 0 and chanCtxtAt(away).status == 3
let forcedBefore = forced
recoverMac()
doAssert tuned.len == 0 and forced == forcedBefore, "departed inside the reset window"
doAssert chanSw.phase == swDeparting and requestLinked()
settle()
doAssert channelEnv.currentCtxt == away and channelEnv.scheduledCtxt == nil
doAssert tuned == @[away] and mmState == MM_ACTIVE_STATE and idleSwitch()
if scan:
  doAssert notices == @[MM_SCAN_CHANNEL_START_IND] and (channelEnv.flags and 0x08) != 0
  doAssert (pmRegister and 4) == 0
finishSwitch()
''')


@pytest.mark.parametrize("edit", ["source_tx_power", "destination_tx_power",
                                  "source_phy_flags", "destination_bandwidth"])
def test_definition_edit_keeps_committed_departure(tmp_path: Path, edit: str) -> None:
    """MMCH-S2: TPC (APM start, beacon Power Constraint) or MM_CHAN_CTXT_UPDATE
    edits a context in place while its departure waits for protection."""
    run_case(tmp_path, f'let edit = "{edit}"\n' + r'''
let (home, away) = twoChannels()
stageSwitch(away, 2)
let epochs = chanCtxtEpochs
case edit
of "source_tx_power": chanCtxtAt(home).channel.txPower = 15
of "destination_tx_power": chanCtxtAt(away).channel.txPower = 15
of "source_phy_flags": inc chanCtxtAt(home).channel.phyEnvFlags
else: chanCtxtAt(away).channel.centerFreq1 = 2447
doAssert chanCtxtEpochs == epochs
deliverPending()
doAssert channelEnv.currentCtxt == away and tuned == @[away] and idleSwitch()
doAssert mmState == MM_ACTIVE_STATE
finishSwitch()
''')


def test_surviving_context_keeps_edca_after_its_operation_timer(tmp_path: Path) -> None:
    """MMCH-S6: the AP stops, then the STA context's operation timer fires.

    With one context left chanCtxtOpEvent sets the current context to status 1
    and chan_switch_start(itself) does nothing (vendor). The STA still owns
    the EDCA bank: MM_SET_EDCA_REQ and WMM refreshes must reach the hardware.
    """
    owner = "type VifChannelView = Vif\n" + procedure(KERNEL, "mmEdcaOwner")
    run_program(tmp_path, "checked", source() + owner + "\nblock:\n" + indent(r'''
let (home, away) = twoChannels()
doAssert mmEdcaOwner() == addr vifs[0]
chanCtxtAt(home).status = 4          # its operation timer runs while two contexts operate
chan_ctxt_unlink(1)                  # the AP stops: neither current nor scheduled
doAssert channelEnv.ctxtCount == 1 and channelEnv.scheduledCtxt == nil
chanCtxtOpEvent(home, 0)             # the operation timer fires
doAssert chanCtxtAt(home).status == 1 and channelEnv.currentCtxt == home
doAssert channelEnv.scheduledCtxt == nil and not requestLinked()
doAssert mmEdcaOwner() == addr vifs[0], "EDCA updates suppressed on the only operating context"
finishSwitch()
''', "  "))


def test_definition_edit_then_abandoned_idle_wait_restores_mm(tmp_path: Path) -> None:
    """MMCH-S2, second effect: a switch-owned idle wait abandoned after an edit."""
    run_case(tmp_path, r'''
let (home, away) = twoChannels()
stageSwitch(away, 1)
chanCtxtAt(home).channel.txPower = 15
chan_ctxt_unlink(1)                  # the AP stops; MM is going idle for the switch
chan_ctxt_unlink(0)                  # and the STA leaves too: no context remains
doAssert channelEnv.ctxtCount == 0 and channelEnv.scheduledCtxt == nil
settle()
doAssert mmState == MM_ACTIVE_STATE and tuned.len == 0, "MM left idle with the MAC idle"
doAssert hostIdle()
finishSwitch()
''')


# --------------------------------------------------------------------------
# Behaviour that was already correct
# --------------------------------------------------------------------------


@pytest.mark.parametrize("mode", ["checked", "asan"])
@pytest.mark.parametrize("phase", range(2), ids=PHASES[:2])
def test_unlink_switch_source_before_claim_keeps_switch(tmp_path: Path, phase: int,
                                                        mode: str) -> None:
    """Cancellation of the departing side before MM runs the request."""
    run_case(tmp_path, f"let phase = {phase}\n" + r'''
let (home, away) = twoChannels()
stageSwitch(away, phase)
chan_ctxt_unlink(0)                  # STA leaves the departing channel first
doAssert requestLinked() and channelEnv.scheduledCtxt == away
doAssert channelEnv.currentCtxt == nil and channelEnv.ctxtCount == 1
deliverPending()
doAssert tuned == @[away] and channelEnv.currentCtxt == away and idleSwitch()
doAssert frames.len == 0 and mmState == MM_ACTIVE_STATE
doAssert hostIdle()
finishSwitch()
''', mode)


@pytest.mark.parametrize("mode", ["checked", "asan"])
@pytest.mark.parametrize("phase", range(2), ids=PHASES[:2])
def test_unlink_only_switch_destination_releases_scheduler(tmp_path: Path, phase: int,
                                                           mode: str) -> None:
    """Boundary of MMCHAN-1: with no context left the switch is abandoned."""
    run_case(tmp_path, f"let phase = {phase}\n" + r'''
resetSwitch()
let target = newTarget(2437)
linkHome(target, VIF_TYPE_STA, 0)
if phase == 1: mmState = MM_ACTIVE_STATE
stageSwitch(target, phase)
chan_ctxt_unlink(0)                  # join aborted before its channel was entered
doAssert channelEnv.ctxtCount == 0 and idleSwitch()
settle()                             # the request hands MM back when it runs
doAssert tuned.len == 0 and not requestLinked()
doAssert mmState == MM_ACTIVE_STATE
let next = newTarget(2462)
linkHome(next, VIF_TYPE_STA, 0)
chan_switch_start(next)
doAssert requestLinked()
deliverPending()
doAssert channelEnv.currentCtxt == next and mmState == MM_ACTIVE_STATE
finishSwitch()
''', mode)


@pytest.mark.parametrize("mode", ["checked", "asan"])
@pytest.mark.parametrize("phase", range(3), ids=PHASES)
def test_reset_retires_pending_switch_and_late_completions(tmp_path: Path, phase: int,
                                                           mode: str) -> None:
    """Kernel re-initialisation (ke_flush/ke_init/chan_init) with a switch pending."""
    run_case(tmp_path, f"let phase = {phase}\n" + r'''
let (home, away) = twoChannels()
stageSwitch(away, phase)
chanSwitchReset()
doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
doAssert idleSwitch() and not chanSwitchRequestQueued
idleInterrupt()                      # idle interrupt of the dropped request
for index in 0 ..< frames.len: completeFrame(index)   # late confirmations
doAssert tuned.len == 0 and forced == (phase == 2).int
doAssert channelEnv.currentCtxt == home and channelEnv.scheduledCtxt == nil
doAssert mmState in [MM_IDLE.uint16, MM_ACTIVE_STATE.uint16]
delivered = frames.len
chan_switch_start(away)              # fresh work after the reset
doAssert requestLinked()
deliverPending()
doAssert channelEnv.currentCtxt == away and channelEnv.scheduledCtxt == nil
doAssert mmState == MM_ACTIVE_STATE and hostIdle()
finishSwitch()
''', mode)


def test_recovery_during_config_idle_wait_restores_mm_state(tmp_path: Path) -> None:
    """KTX-1: a MAC recovery while a config request waits for idle.

    hal_machw_reset no longer discards the saved mode and state, and mm_reset
    marks the wait ready, so the replayed request restores ACTIVE and mode 3.
    """
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    idle = kernel.split("type MmConfigIdlePhase = enum", 1)[1].split("proc mmConfigTrackIdle", 1)[0]
    reset = procedure(kernel, "hal_machw_reset")
    assert "mmConfigCancelIdle" not in reset
    run_program(tmp_path, "checked", r'''
const
  TASK_MM = 0'u8
  MM_IDLE = 0
  MM_ACTIVE_STATE = 1
  MM_GOING_TO_IDLE = 2
  MACHW_STATE_CNTRL_REG = 0x38'u
type MmEnv = object
  hardwareMode, previousState: uint8
var
  mm: MmEnv
  state: uint16
  stateReg, events: uint32
  asserts: int
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc mmEnvView(): ptr MmEnv = addr mm
proc ke_state_get(task: uint8): uint16 = state
proc ke_state_set(task: uint8; value: uint16) = state = value
proc ke_evt_field_get(): uint32 = events
proc regRead(address: uint): uint32 = stateReg
proc regWrite(address: uint; value: uint32) = stateReg = value
proc assert_err(condition, module: cstring; line: cint) = inc asserts
type MmConfigIdlePhase = enum''' + idle
        + procedure(kernel, "mmConfigTrackIdle") + procedure(kernel, "mmConfigCancelIdle")
        + procedure(kernel, "mmConfigResumeIdle") + r'''
proc mm_active() =
  mmConfigCancelIdle()
  stateReg = 0x30
  state = MM_ACTIVE_STATE
''' + procedure(kernel, "mm_reset") + r'''
var request: int
# A connected STA: MM active, MAC mode 3. A config request starts the idle wait.
state = MM_ACTIVE_STATE
stateReg = 0x30
let epoch = mmConfigTrackIdle(addr request, 3, MM_ACTIVE_STATE.uint8)
state = MM_GOING_TO_IDLE
# The idle interrupt never arrives; recovery resets the MAC (now idle) and MM.
stateReg = 0
mm_reset()
doAssert state == MM_IDLE and mmConfigIdle.phase == mmConfigIdleReady
doAssert mm.hardwareMode == 3 and mm.previousState == MM_ACTIVE_STATE.uint8
# The saved request replays, applies its change and resumes.
doAssert mmConfigIdle.epoch == epoch and mmConfigResumeIdle(epoch, TASK_MM)
doAssert state == MM_ACTIVE_STATE and stateReg == 0x30 and asserts == 0
doAssert mmConfigIdle.phase == mmConfigNoIdle
''')
