"""Audit MM idle/active and channel-context switching for overlap, cancellation and reset.

The fixture extends the channel-protection harness, which compiles the real
channel_switch.nim and channel_protection.nim together with the production
chan_ctxt_add/del/link/unlink, chanStartSwitch, chan_goto_idle_cb,
mm_force_idle_req_handler, chan_sta_tx_cfm and MM idle tracking. The patches
below only make the stubs model MM task-state side effects faithfully:

* mm_force_idle_req (behind chanForceIdle) publishes HW_ACTIVE after its
  TX/RX reset has flushed old confirmations;
* mm_active cancels idle tracking and publishes MM_ACTIVE_STATE;
* chan_pre_switch_channel ends in mm_active, as the vendor routine does.

The production mm_set_idle_req_handler is added to observe whether the host
can still drive MM idle after each sequence.

Tests marked xfail(strict=True) reproduce defects found by the audit and
flip to XPASS once they are fixed. MMCHAN-1 and MMCHAN-2 use production
event orders (an AP or STA unlink while a switch is in flight). MMCHAN-3 is a
hardening contract only: it injects chan_ctxt_del from inside ke_state_set or
chanForceIdle. Review found no production path that retires a context
synchronously there. ke_state_set only requeues saved messages, and
smCleanupService defers while txlResetting().
"""

from pathlib import Path
from textwrap import indent

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_channel_protection import source as protection_source
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def _replace(code: str, old: str, new: str) -> str:
    assert old in code, old
    return code.replace(old, new, 1)


def source() -> str:
    code = protection_source()
    # mm_force_idle_req runs txl_reset (which flushes TX confirmations) and then
    # publishes HW_ACTIVE; hal_machw_reset inside it cancels MM idle tracking.
    code = _replace(code, "proc chanForceIdle(): bool =\n  inc forced\n  inc txResetEpoch\n"
                    "  invoke(onIdle)\n  not forceFailed\n",
                    "proc mmConfigCancelIdle()\n"
                    "proc chanForceIdle(): bool =\n  inc forced\n  mmConfigCancelIdle()\n"
                    "  inc txResetEpoch\n  invoke(onIdle)\n"
                    "  if not forceFailed: mmState = HW_ACTIVE\n  not forceFailed\n")
    # mm_active: mmConfigCancelIdle(); STATE_CNTRL = ACTIVE; ke_state_set(TASK_MM, ACTIVE).
    code = _replace(code, "proc protectionActiveHook() = invoke(onActive)\n",
                    "proc protectionActiveHook() =\n  mmConfigCancelIdle()\n"
                    "  mmState = MM_ACTIVE_STATE\n  invoke(onActive)\n")
    # Every successful vendor chan_pre_switch_channel ends in mm_active().
    code = _replace(code, "  channelEnv.currentCtxt = channelEnv.scheduledCtxt\n"
                    "  channelEnv.scheduledCtxt = nil\n"
                    "proc chan_sta_tx_cfm",
                    "  channelEnv.currentCtxt = channelEnv.scheduledCtxt\n"
                    "  channelEnv.scheduledCtxt = nil\n  mm_active()\n"
                    "proc chan_sta_tx_cfm")
    code = _replace(code, "  mm: tuple[hardwareMode, previousState: uint8]\n",
                    "  mm: tuple[hardwareMode, previousState, idleFlag: uint8]\n")
    code += layouts("MmSetIdleReqPayload") + r'''
const
  TaskGoingIdleState = 2'u16
  MM_SET_IDLE_REQ = 0x1A'u16
  MM_SET_IDLE_CFM = 0x1B'u16
  MmSetIdleReqPayloadSize = sizeof(MmSetIdleReqPayload).uint32
type IdleRequest = object
  header: Header
  payload: MmSetIdleReqPayload
var idleReplies: seq[uint16]
proc smBssAdmitRequest(p: pointer): bool = true
proc smCleanupAdmitRequest(p: pointer): bool = true
proc mmSetIdleReqView(p: pointer): ptr MmSetIdleReqPayload = cast[ptr MmSetIdleReqPayload](p)
proc ke_msg_send_basic_reply(p: pointer; id: uint16) = idleReplies.add(id)
'''
    code += procedure((FW / "task_handlers.nim").read_text(), "mm_set_idle_req_handler")
    return code + r'''
proc settleIdle() =
  ## Deliver the MAC idle interrupt for an outstanding idle request.
  if mmState == MM_GOING_TO_IDLE: mm_hw_idle_evt()

proc deliverPending() =
  ## Run queued/saved force-idle requests and protection confirmations the
  ## way the kernel would, until nothing is left in flight.
  for round in 0..3:
    settleIdle()
    while queued.len != 0:
      let request = take()
      var status = mm_force_idle_req_handler(request)
      if status == KeMsgSaved:
        settleIdle()
        status = mm_force_idle_req_handler(request)
      doAssert status == KeMsgConsumed
      release(request)
    for index in 0..<protectionFrames.len: completeFrame(index)
    settleIdle()

proc hostIdle(): bool =
  ## Host MM_SET_IDLE_REQ(1); allow one MAC idle transition to complete it.
  var request = IdleRequest(header: Header(id: MM_SET_IDLE_REQ, destId: 0, srcId: 3,
    paramLen: MmSetIdleReqPayloadSize), payload: MmSetIdleReqPayload(idle: 1))
  idleReplies.setLen(0)
  if mm_set_idle_req_handler(addr request.payload) == KeMsgSaved:
    settleIdle()
    if mm_set_idle_req_handler(addr request.payload) == KeMsgSaved: return false
  idleReplies == @[MM_SET_IDLE_CFM] and mmState == MM_IDLE

proc twoChannels(scanDestination = false): tuple[home, away: pointer] =
  ## STA (VIF 0) operates on `home`; `away` is a second AP channel (VIF 1)
  ## or the scan context. MM is active on `home`.
  resetProtectionTest()
  result.home = newTarget(2412)
  linkHome(result.home, VIF_TYPE_STA, 0)
  vifs[0].staIdx = 0
  mgmt.activeList.first = cast[ptr CoListHdr](addr vifs[0])
  if scanDestination:
    result.away = cast[pointer](chanCtxtForIdx(3))
    chanCtxtAt(result.away).contextIndexOrMarker = 3
    chanCtxtAt(result.away).status = 1
    channelEnv.flags = channelEnv.flags or 0x08
  else:
    result.away = newTarget(2437)
    linkHome(result.away, VIF_TYPE_AP, 1)
    vifs[0].next = addr vifs[1]
  channelEnv.currentCtxt = result.home
  chanCtxtAt(result.home).status = 5
  mmState = MM_ACTIVE_STATE
  stateRegister = 0x33

proc stageSwitch(target: pointer; phase: int): pointer =
  ## phase 0: request queued for MM; 1: saved behind MM GOING_TO_IDLE;
  ## 2: claimed, PM null frame on the departing channel still unconfirmed.
  result = beginSwitch(target)
  case phase
  of 0: queued.add(result)
  of 1:
    doAssert mm_force_idle_req_handler(result) == KeMsgSaved
    doAssert mmState == MM_GOING_TO_IDLE
    queued.add(result)
  else:
    mmState = MM_IDLE
    stateRegister = 0
    doAssert mm_force_idle_req_handler(result) == KeMsgConsumed
    release(result)
    result = nil
    doAssert protectionFrames.len == 1 and chanProtectionActive()
    doAssert channelEnv.scheduledCtxt == target and mmState == MM_ACTIVE_STATE
'''


PHASES = ["queued", "saved", "protection_wait"]


def run_case(tmp_path: Path, body: str, mode: str = "checked") -> None:
    run_program(tmp_path, mode, source() + "\nblock:\n" + indent(body, "  "))


# --------------------------------------------------------------------------
# Defects (strict xfail)
# --------------------------------------------------------------------------


@pytest.mark.xfail(strict=True, reason=(
    "MMCHAN-1: chan_ctxt_unlink re-points scheduledCtxt at the remaining context, then "
    "chan_ctxt_del->chanSwitchRetire cancels the only force-idle request; the orphaned "
    "scheduledCtxt/switchPending blocks TX and every later chan_switch_start"))
@pytest.mark.parametrize("phase", range(3), ids=PHASES)
def test_unlink_switch_destination_keeps_scheduler_live(tmp_path: Path, phase: int) -> None:
    run_case(tmp_path, f"let phase = {phase}\n" + r'''
let (home, away) = twoChannels()
discard stageSwitch(away, phase)
chan_ctxt_unlink(1)                  # AP stops while the switch to its channel is in flight
doAssert channelEnv.ctxtCount == 1
deliverPending()
# Vendor: the still-queued MM_FORCE_IDLE_REQ switches to the remaining context.
doAssert channelEnv.scheduledCtxt == nil, "scheduledCtxt left without an owning request"
doAssert channelEnv.switchPending == 0
doAssert channelEnv.currentCtxt == home
# A later interface on another channel must still be schedulable.
let replacement = newTarget(2462)
linkHome(replacement, VIF_TYPE_AP, 1)
chan_switch_start(replacement)
doAssert queued.len == 1, "chan_switch_start ignored: scheduledCtxt still set"
deliverPending()
doAssert channelEnv.currentCtxt == replacement
finishProtectionTest()
''')


@pytest.mark.xfail(strict=True, reason=(
    "MMCHAN-2: unlinking the departing (source) context while its PM null frame is "
    "pending cancels the whole switch via chanSwitchRetire; the still-valid destination "
    "(AP channel or scan context) is never entered and nothing re-drives it"))
@pytest.mark.parametrize("scan", [False, True], ids=["ap_destination", "scan_destination"])
def test_unlink_switch_source_during_protection_wait(tmp_path: Path, scan: bool) -> None:
    run_case(tmp_path, f"let scan = {str(scan).lower()}\n" + r'''
let (home, away) = twoChannels(scan)
discard stageSwitch(away, 2)
chan_ctxt_unlink(0)                  # STA disconnects before its PM null frame confirms
deliverPending()                     # late null-frame confirmation arrives
# Vendor chan_sta_tx_cfm: last confirmation -> mm_force_idle_req + chan_pre_switch_channel.
doAssert channelEnv.currentCtxt == away, "destination abandoned with no current context"
doAssert channelEnv.scheduledCtxt == nil and mmState == MM_ACTIVE_STATE
finishProtectionTest()
''')


@pytest.mark.xfail(strict=True, reason=(
    "MMCHAN-3 (hardening, trigger unproven): if a claimed switch goes stale after MM "
    "entered HW_ACTIVE, the early returns never call mm_active/mm_back_to_host_idle. "
    "MM then saves MM_SET_IDLE_REQ forever. The staleness is injected by fixture hooks; "
    "no production path was found that does it"))
@pytest.mark.parametrize("cause", range(4), ids=[
    "retired_at_hw_active_publication", "destination_retired_in_force_idle",
    "source_retired_in_force_idle", "destination_retired_in_protection_completion"])
def test_abandoned_switch_leaves_host_bypass(tmp_path: Path, cause: int) -> None:
    run_case(tmp_path, f"let cause = {cause}\n" + r'''
resetProtectionTest()
let source = newTarget(2412)
let target = newTarget(2437)
if cause == 3:                       # STA on the departing channel -> PM null frame
  linkHome(source, VIF_TYPE_STA, 0)
  vifs[0].staIdx = 0
  mgmt.activeList.first = cast[ptr CoListHdr](addr vifs[0])
channelEnv.currentCtxt = source
chanCtxtAt(source).status = 5
let retireTarget = proc() = chan_ctxt_del(chanCtxtAt(target).contextIndexOrMarker)
let retireSource = proc() = chan_ctxt_del(chanCtxtAt(source).contextIndexOrMarker)
let request = beginSwitch(target)
case cause
of 0: onMmState = retireTarget       # injected: retired while MM publishes HW_ACTIVE
of 1: onIdle = retireTarget          # injected: retired inside the force-idle TX/RX reset
of 2: onIdle = retireSource          # injected
else: discard
doAssert mmState == MM_IDLE
doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
release(request)
if cause == 3:
  doAssert protectionFrames.len == 1 and mmState == MM_ACTIVE_STATE
  onIdle = retireTarget              # injected into the final cfm's force idle
  completeFrame(0)
doAssert callbacks == 0 and channelEnv.scheduledCtxt == nil and not chanProtectionActive()
doAssert mmState != HW_ACTIVE, "switch abandoned while MM is host-bypassed"
doAssert hostIdle(), "MM_SET_IDLE_REQ can no longer complete"
finishProtectionTest()
''')


# --------------------------------------------------------------------------
# Behaviour that is currently correct
# --------------------------------------------------------------------------


@pytest.mark.parametrize("mode", ["checked", "asan"])
@pytest.mark.parametrize("phase", range(2), ids=PHASES[:2])
def test_unlink_switch_source_before_claim_keeps_switch(tmp_path: Path, phase: int,
                                                        mode: str) -> None:
    """Cancellation of the departing side before MM claims the request."""
    run_case(tmp_path, f"let phase = {phase}\n" + r'''
let (home, away) = twoChannels()
let request = stageSwitch(away, phase)
chan_ctxt_unlink(0)                  # STA leaves the departing channel first
doAssert queued == @[request] and channelEnv.scheduledCtxt == away
doAssert channelEnv.currentCtxt == nil and channelEnv.ctxtCount == 1
deliverPending()
doAssert callbacks == 1 and channelEnv.currentCtxt == away
doAssert channelEnv.scheduledCtxt == nil and channelEnv.switchPending == 0
doAssert protectionFrames.len == 0 and mmState == MM_ACTIVE_STATE
doAssert hostIdle()
finishProtectionTest()
''', mode)


@pytest.mark.parametrize("mode", ["checked", "asan"])
@pytest.mark.parametrize("phase", range(2), ids=PHASES[:2])
def test_unlink_only_switch_destination_releases_scheduler(tmp_path: Path, phase: int,
                                                           mode: str) -> None:
    """Boundary of MMCHAN-1: with no context left the switch is fully retired."""
    run_case(tmp_path, f"let phase = {phase}\n" + r'''
resetProtectionTest()
let target = newTarget(2437)
linkHome(target, VIF_TYPE_STA, 0)
if phase == 1:
  mmState = MM_ACTIVE_STATE
  stateRegister = 0x33
discard stageSwitch(target, phase)
chan_ctxt_unlink(0)                  # join aborted before its channel was entered
doAssert channelEnv.ctxtCount == 0 and queued.len == 0 and live.len == 0
doAssert channelEnv.scheduledCtxt == nil and channelEnv.switchPending == 0
doAssert chanSwitchActive == nil and chanSwitchTags == nil
settleIdle()
doAssert callbacks == 0 and mmState == MM_IDLE
let next = newTarget(2462)
linkHome(next, VIF_TYPE_STA, 0)
chan_switch_start(next)
doAssert queued.len == 1
deliverPending()
doAssert channelEnv.currentCtxt == next and mmState == MM_ACTIVE_STATE
finishProtectionTest()
''', mode)


@pytest.mark.parametrize("mode", ["checked", "asan"])
def test_conflicting_switch_requests_are_single_flight(tmp_path: Path, mode: str) -> None:
    """Overlap: other starts while one switch is in flight neither queue nor retarget."""
    run_case(tmp_path, r'''
resetProtectionTest()
let a = newTarget(2412)
let b = newTarget(2437)
let c = newTarget(2462)
channelEnv.currentCtxt = a
chanCtxtAt(a).status = 5
let first = stageSwitch(b, 0)
let statusC = chanCtxtAt(c).status
for other in [c, b, a]:              # conflicting, duplicate, current
  chan_switch_start(other)
  doAssert queued == @[first] and live.len == 1
  doAssert channelEnv.scheduledCtxt == b and channelEnv.switchPending == 1
  doAssert chanSwitchActive != nil and chanSwitchActive.destination.target == b
doAssert chanCtxtAt(c).status == statusC
deliverPending()
doAssert callbacks == 1 and channelEnv.currentCtxt == b and channelEnv.scheduledCtxt == nil
chan_switch_start(c)                 # the single-flight slot was released
doAssert queued.len == 1
deliverPending()
doAssert callbacks == 2 and channelEnv.currentCtxt == c
finishProtectionTest()
''', mode)


@pytest.mark.parametrize("mode", ["checked", "asan"])
@pytest.mark.parametrize("phase", range(3), ids=PHASES)
def test_reset_retires_pending_switch_and_late_completions(tmp_path: Path, phase: int,
                                                           mode: str) -> None:
    """Reset with work pending, modeled by the ke_flush/ke_init cancel calls in order.

    The reset entry points themselves are not compiled here, only
    mmConfigCancelIdle() followed by chanSwitchCancel().
    """
    run_case(tmp_path, f"let phase = {phase}\n" + r'''
let (home, away) = twoChannels()
discard stageSwitch(away, phase)
mmConfigCancelIdle()
chanSwitchCancel()
doAssert queued.len == 0 and live.len == 0 and chanSwitchTags == nil
doAssert chanSwitchActive == nil and not chanProtectionActive()
doAssert channelEnv.scheduledCtxt == nil and channelEnv.switchPending == 0
doAssert channelEnv.scanDelayCount == 0 and channelEnv.connlessDelayCount == 0
let modes = modeRequests
settleIdle()                         # idle interrupt of the abandoned request
for index in 0..<protectionFrames.len: completeFrame(index)   # late confirmations
doAssert callbacks == 0 and forced == (phase == 2).int
doAssert channelEnv.currentCtxt == home and channelEnv.scheduledCtxt == nil
doAssert modeRequests == modes, "reset must not restore the abandoned home mode"
doAssert mmState in [MM_IDLE, MM_ACTIVE_STATE]
chan_switch_start(away)              # fresh work after the reset
doAssert queued.len == 1
deliverPending()
doAssert channelEnv.currentCtxt == away and channelEnv.scheduledCtxt == nil
doAssert mmState == MM_ACTIVE_STATE and hostIdle()
finishProtectionTest()
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
