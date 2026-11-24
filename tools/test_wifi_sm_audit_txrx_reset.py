"""Audit TX/RX lifecycle, kernel timers, and reset for overlap and cancellation.

Each program drives the production Nim handlers through the fixtures already
used by the TX and response-timer suites. Tests marked xfail(strict=True)
reproduce a defect found by the state-machine audit; they flip when fixed.

F1: frames postponed on a station queue are leased in one TX reset epoch and
    released in a later one. Every channel switch runs chanForceIdle ->
    mm_force_idle_req -> txl_reset, so a frame postponed while its VIF was off
    channel is dropped on return (no TX, no callback) or aged out with a stale
    callback scope outside the reset window.
F2: the SM response deadline is bound to txResetEpoch and is discarded by
    ke_timer_schedule after any txl_reset, including a channel switch, so SM
    can wait for an auth/assoc response with no deadline.
"""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_frame_ownership import STA_QUEUE_STUBS
from test_wifi_internal_preparation import platform_source
from test_wifi_message_allocation import run_program
from test_wifi_response_timeout import source as response_source


MODES = ["checked", "release"]


class FindingReproduced(AssertionError):
    """The program stopped at the assertion carrying the expected finding text."""


def finding(tag: str, summary: str):
    # Only the tagged assertion counts as the expected failure; a compile or
    # fixture error, or any other assertion, still fails the test.
    return pytest.mark.xfail(strict=True, raises=FindingReproduced, reason=f"{tag}: {summary}")


def run_finding(tmp_path: Path, mode: str, code: str, marker: str) -> None:
    try:
        run_program(tmp_path, mode, code)
    except AssertionError as error:
        if marker in str(error):
            raise FindingReproduced(marker) from error
        raise

# chanForceIdle is the channel-switch entry into mm_force_idle_req/txl_reset.
CHANNEL_RESET_STUBS = r'''
var chanTbttTimerOwner, chanConnlessTimerOwner: tuple[valid: bool, resetEpoch: uint32]
proc smScanPreserveAcrossChannelReset(previous: uint32) = discard
proc smRegistrationPreserveAcrossChannelReset(previous: uint32) = discard
'''


def channel_reset(force_idle_body: str) -> str:
    return (CHANNEL_RESET_STUBS + "proc mm_force_idle_req(): bool =\n" + force_idle_body +
            procedure((FW / "channel_timer.nim").read_text(), "chanForceIdle"))


def _replace_once(code: str, old: str, new: str) -> str:
    assert code.count(old) >= 1, old
    return code.replace(old, new)


def tx_source() -> str:
    """Real internal-frame lease, postponement, completion and txl_reset."""
    layout = (FW / "layout_types.nim").read_text()
    identity = re.search(r"(?ms)^  StaQueueIdentity = object\n.*?(?=^  \w|\Z)", layout)
    assert identity
    code = platform_source()
    code = _replace_once(code, STA_QUEUE_STUBS, "\ntype\n" + identity.group(0))
    code = _replace_once(code, "proc txlResetting(): bool = false\n", "proc txlResetting(): bool\n")
    code = _replace_once(code, "  TxVif = object\n    chanCtxt: ptr ChannelContext\n    vifIdx: uint8\n",
                         "  TxVif = object\n    chanCtxt: ptr ChannelContext\n    vifIdx: uint8\n"
                         "    psFlags, vifType: uint8\n")
    code = _replace_once(code, "type StaInfoView = Sta\n",
                         "type StaInfoView = Sta\n"
                         "type TxCtrlEnv = object\n"
                         "  packetCounter: uint32\n"
                         "  seqCounter: uint16\n"
                         "  resetInProgress: uint8\n"
                         "  reserved: array[96, uint8]\n")
    code = _replace_once(code, "  txEnv: tuple[packetCounter: uint32]\n", "  txEnv: TxCtrlEnv\n")
    code = _replace_once(code, "tuple[current: pointer, pending: CoList]",
                         "tuple[current: pointer, pending: CoList, packetCount: uint16, busyFlag: uint8]")
    code += r'''
const
  VIF_TYPE_STA = 0'u8
  VIF_TYPE_AP = 2'u8
  WifiHwPollLimit = 4'u32
type ApmPsDescView = object
  accessCategory: uint8
var
  cfmLists: array[5, CoList]
  txRecoveryPostponed: CoList
  txResetActive: bool
  txlAcPending: array[5, uint32]
  txlAcBusy: array[5, bool]
  psEnvFlags: tuple[flags, apPending, otherPending: uint8]
  haltWrites: seq[uint32]
  flushCalls: int
  cbCalls: int
  cbStatuses: seq[uint32]
  cbCurrent, cbInReset: seq[bool]
proc txlResetting(): bool = txEnv.resetInProgress != 0
proc txCfmList(ac: uint32): ptr CoList = addr cfmLists[ac]
proc keEnvPsFlags(): ptr typeof(psEnvFlags) = addr psEnvFlags
proc apmTxDescPsAt(p: pointer): ApmPsDescView =
  # The vendor PS view's AC byte is HostTxDescView offset 46.
  ApmPsDescView(accessCategory: hostTxDescAt(p).staIdx)
proc apm_tx_int_ps_get_postpone(vif, sta: pointer; flag: ptr uint32): pointer =
  flag[] = 0
  nil
proc noteHwWaitTimeout(reg, mask: uint32) = doAssert false, "fixture IPC TX slots are idle"
proc hal_machw_disable_int() = doAssert false, "fixture reset does not time out"
proc txl_hwdesc_reset() = discard
proc txl_buffer_reinit() = discard
proc txl_cfm_init() = cfmLists = default(typeof(cfmLists))
proc ipcTxHwDescWordHalfword(ac: uint32): uint16 = (0x40'u32 + ac).uint16
proc ipcTxIdleStatus(): uint32 = 0xFFFF'u32
when not declared(co_list_init):
  proc co_list_init(list: ptr CoList) = list[] = default(CoList)
when not declared(c_memset):
  proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
    zeroMem(p, size.int)
    p
'''
    tx = (FW / "tx_layer.nim").read_text()
    sta = (FW / "sta_management.nim").read_text()
    functions = procedure((FW / "task_handlers.nim").read_text(), "txl_int_fake_transfer")
    functions += "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent", "txlCaptureFrameCallback",
        "txlFrameCallbackCurrent", "txlInvokeFrameCallback", "txlStationAdmits",
        "txlCaptureSession", "txlSessionCurrent", "txl_frame_free_list_pop", "txl_frame_get",
        "txl_frame_release", "txlFrameConfirmPending", "txl_frame_evt",
        "txlDrainRetiredPostponed", "txl_cntrl_push_int",
    ])
    functions += "".join(procedure(sta, name) for name in [
        "staPostponedOwner", "staPostponedOwnerCurrent", "staPostponedListValid",
        "staReleasePostponed", "sta_mgmt_postponed_desc_release",
        "sta_mgmt_send_postponed_frame",
    ])
    hooks = r'''
proc observe(label: string) = discard
proc txl_payload_handle_backup(p: pointer) = inc drainCalls
proc apm_tx_int_ps_postpone(p, sta: pointer) = inc postponeCalls
proc txl_cfm_flush(ac: uint8; list: ptr CoList; status: uint32) =
  # The scenarios keep the AC queues empty; the vendor tail drains frame events.
  doAssert list.first == nil, "fixture flush has no queued descriptors"
  inc flushCalls
  txl_frame_evt()
'''
    reset = procedure(tx, "txlRebasePostponedLeases") + procedure(tx, "txl_reset")
    reset = _replace_once(reset, "volatileLoad(cast[ptr uint32](IPC_TX_STATUS_REG))", "ipcTxIdleStatus()")
    reset = _replace_once(reset, "volatileStore(cast[ptr uint32](0x24A00020'u), acBit)",
                          "haltWrites.add(acBit)")
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n"
        for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions + reset)))
    )
    # hal_machw_reset and rxl_reset succeed; the TX layer reset is the real one.
    force_idle = channel_reset("  txl_reset()\n")
    return code + debug + functions + hooks + reset + force_idle + r'''
proc frameDone(arg: pointer; status: uint32) {.cdecl.} =
  # Record what a protocol owner sees: status, its session scope, reset window.
  inc cbCalls
  cbStatuses.add(status)
  cbCurrent.add(txlFrameCallbackCurrent())
  cbInReset.add(txResetActive)

proc prepare(count = 1): array[2, ptr HostTxDescView] =
  interruptsEnabled = true
  setup()
  txEnv = default(TxCtrlEnv)
  cfmLists = default(typeof(cfmLists))
  txRecoveryPostponed = default(CoList)
  txActiveFlush = nil
  txResetActive = false
  haltWrites.setLen(0)
  flushCalls = 0
  vifs[0] = TxVif(vifIdx: 0, chanCtxt: addr context, vifType: VIF_TYPE_STA)
  vifs[1] = TxVif(vifIdx: 1, chanCtxt: addr context, vifType: VIF_TYPE_STA)
  channel = ChannelEnv(currentCtxt: addr context, scheduledCtxt: addr context)
  tails = default(typeof(tails))
  drainCalls = 0
  postponeCalls = 0
  cbCalls = 0
  cbStatuses.setLen(0)
  cbCurrent.setLen(0)
  cbInReset.setLen(0)
  for i in 0 ..< count:
    let frame = hostTxDescAt(txl_frame_get(24))
    doAssert frame != nil
    # A deauthentication on station 1 (VIF 1), the SM disconnect's frame.
    frame.vifIdx = 1
    frame.staInfoIdx = 1
    frame.staIdx = 3
    hostTxLinkDescAt(frame.bufDesc).macHeader[0] = 0xC0
    frame.callback = cast[pointer](frameDone)
    frame.callbackArg = frame
    result[i] = frame

proc postponeOffChannel(frame: ptr HostTxDescView) =
  # VIF 1 is not on the current channel: chan_is_tx_allowed is false.
  profile = 1
  doAssert txl_cntrl_push_int(frame, 3) == 1
  doAssert frame.postponeFlag == 1 and frame.staIdx == 3

proc channelSwitchReset() =
  # chanForceIdle -> mm_force_idle_req -> hal_machw_reset, rxl_reset, txl_reset.
  let before = txResetEpoch
  doAssert chanForceIdle()
  doAssert txResetEpoch == before + 1 and not txlResetting() and not txResetActive
  doAssert haltWrites == @[1'u32, 2, 4, 8, 16] and flushCalls == 10

proc arriveOnChannel(): uint32 =
  # chan_pre_switch_channel arrival -> vif_mgmt_send_postponed_frame(vif 1).
  profile = 0
  sta_mgmt_send_postponed_frame(addr vifs[1], addr stas[1], 0)
'''


@pytest.mark.parametrize("mode", MODES)
def test_postponed_frames_resume_in_order_without_reset(tmp_path: Path, mode: str) -> None:
    """Overlap: two frames queued off channel are sent once, in order, on return."""
    run_program(tmp_path, mode, tx_source() + r'''
for count in 1 .. 2:
  let frames = prepare(count)
  for i in 0 ..< count: postponeOffChannel(frames[i])
  doAssert postponeCalls == count and frameEnv.postponedCount == count.uint32
  doAssert arriveOnChannel() == count.uint32
  doAssert drainCalls == count and cbCalls == 0
  doAssert frameEnv.postponedCount == 0 and stas[1].postponedList.first == nil
  doAssert txEnv.packetCounter == count.uint32
  var node = acs[3].pending.first
  for i in 0 ..< count:
    doAssert node == addr frames[i].link, "postponed order not preserved"
    doAssert frames[i].postponeFlag == 0
    node = node.next
  doAssert node == nil
''')


@pytest.mark.parametrize("mode", MODES)
def test_reset_retires_queued_completion_once_inside_reset_window(tmp_path: Path, mode: str) -> None:
    """Cancellation after the completion is queued: reset reports it exactly once."""
    run_program(tmp_path, mode, tx_source() + r'''
let frame = prepare()[0]
profile = 0
doAssert txl_cntrl_push_int(frame, 3) == 1
doAssert drainCalls == 1 and txEnv.packetCounter == 1
# The MAC acknowledged it and txl_frame_cfm queued the completion event...
discard co_list_pop_front(addr acs[3].pending)
hostTxHwDescAt(frame.hwDesc).confirmStatus = 0x80800000'u32
co_list_push_back(addr frameEnv.usedList, addr frame.link)
# ...but a channel-switch reset runs before txl_frame_evt is dispatched.
channelSwitchReset()
doAssert cbCalls == 1, "queued completion lost or repeated across 10 reset flushes"
doAssert cbStatuses == @[0x40000000'u32]
doAssert cbInReset == @[true] and cbCurrent == @[false]
doAssert frameEnv.usedList.first == nil and co_list_cnt(addr frameEnv.freeList) == 4
txl_frame_evt()
doAssert cbCalls == 1
''')


@pytest.mark.parametrize("mode", MODES)
def test_station_delete_retires_postponed_frame_with_stale_scope(tmp_path: Path, mode: str) -> None:
    """Cancellation before TX: a deleted peer's postponed frame completes once, stale."""
    run_program(tmp_path, mode, tx_source() + r'''
let frames = prepare(2)
for frame in frames: postponeOffChannel(frame)
# mm_sta_del advances the station epoch, then sta_mgmt_entry_init releases
# every postponed descriptor with its callback before the slot can be reused.
inc stationEpochs[1]
doAssert sta_mgmt_postponed_desc_release(addr stas[1], 1) == 2
doAssert cbCalls == 2 and cbStatuses == @[0'u32, 0]
doAssert cbCurrent == @[false, false], "deleted peer's completion looks current"
doAssert cbInReset == @[false, false]
doAssert frameEnv.postponedCount == 0 and co_list_cnt(addr frameEnv.freeList) == 4
# Returning to the channel must not resurrect or double-complete them.
doAssert arriveOnChannel() == 0
doAssert drainCalls == 0 and cbCalls == 2 and acs[3].pending.first == nil
''')


@pytest.mark.parametrize("mode", MODES)
def test_postponed_frame_survives_channel_switch_reset(tmp_path: Path, mode: str) -> None:
    """Reset with work pending: off-channel frame must be sent or completed on return."""
    run_finding(tmp_path, mode, tx_source() + r'''
let frame = prepare()[0]
postponeOffChannel(frame)
channelSwitchReset()
# txl_reset retires AC queues, cfm lists and recovery postponements, but not
# this station queue: the frame is still owned there and its owner still waits.
let retiredByReset = stas[1].postponedList.first == nil
doAssert retiredByReset or stas[1].postponedList.first == addr frame.link
let sent = arriveOnChannel()
doAssert sent == (if retiredByReset: 0'u32 else: 1'u32)
doAssert stas[1].postponedList.first == nil and frameEnv.postponedCount == 0
let transmitted = drainCalls == 1 and acs[3].pending.first == addr frame.link
let notified = cbCalls == 1 and (cbInReset[0] or cbCurrent[0])
doAssert cbCalls <= 1 and not (transmitted and cbCalls != 0)
doAssert transmitted or notified,
  "F1: postponed deauth dropped silently (drain=" & $drainCalls & " callbacks=" & $cbCalls &
  " free=" & $co_list_cnt(addr frameEnv.freeList) & ")"
''', "F1: postponed deauth dropped silently")


@pytest.mark.parametrize("mode", MODES)
def test_postponed_frame_aged_after_reset_reaches_owner(tmp_path: Path, mode: str) -> None:
    """Reset then aging: owners discard stale completions unless inside txl_reset."""
    run_finding(tmp_path, mode, tx_source() + r'''
let frame = prepare()[0]
postponeOffChannel(frame)
let postponedAt = frame.pendingMacTime
channelSwitchReset()
# mm_tbtt_evt -> sta_mgmt_aging_postponed_desc after 120 ms off channel; the
# fixture stubs that loop, so call its per-station step (flag 0) directly.
macTime = postponedAt + 0x1D4C1'u32
discard sta_mgmt_postponed_desc_release(addr stas[1], 0)
doAssert cbCalls == 1 and stas[1].postponedList.first == nil
# sm_disconnect_deauth_cfm accepts only txlFrameCallbackCurrent() or a
# completion delivered while txResetActive (smClaimFlushedDisconnect).
doAssert cbInReset[0] or cbCurrent[0],
  "F1: aged postponed frame completed with stale scope outside reset window"
''', "F1: aged postponed frame completed with stale scope")


def response_program(body: str) -> str:
    # mm_force_idle_req's txl_reset advances the TX epoch exactly once.
    force_idle = channel_reset("  inc txResetEpoch\n  true\n")
    return response_source() + force_idle + body + "\nfinish()\n"


@pytest.mark.parametrize("mode", MODES)
def test_response_deadline_survives_unrelated_retirement(tmp_path: Path, mode: str) -> None:
    """Owner-scoped invalidation: retiring another VIF or peer keeps SM's deadline."""
    run_program(tmp_path, mode, response_program(r'''
setup()
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 50)
inc rxVifEpochs[0]
inc stationEpochs[3]
now = 151
ke_timer_schedule()
deliver(takeMessage())
doAssert authRetries == 1 and connection.retry == 1 and failures == 0
doAssert messages.first == nil and not ke_timer_active(SM_RSP_TIMEOUT_IND, TASK_SM)
'''))


@pytest.mark.parametrize("mode", MODES)
def test_response_deadline_survives_channel_switch_reset(tmp_path: Path, mode: str) -> None:
    """Reset with a timer pending: the auth deadline must still retry or fail."""
    run_finding(tmp_path, mode, response_program(r'''
setup()
ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, 50)
doAssert ke_timer_active(SM_RSP_TIMEOUT_IND, TASK_SM)
# SM is authenticating; an off-channel hop runs chanForceIdle -> txl_reset.
doAssert chanForceIdle()
now = 151
ke_timer_schedule()
while messages.first != nil:
  deliver(takeMessage())
doAssert state == SmAuthenticatingState
doAssert authRetries + failures == 1 or ke_timer_active(SM_RSP_TIMEOUT_IND, TASK_SM),
  "F2: response deadline discarded; SM remains authenticating with no timer"
'''), "F2: response deadline discarded")
