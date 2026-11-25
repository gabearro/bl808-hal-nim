"""Audit the PS/DPSM, keepalive and connection-loss machines across overlap,
cancellation and reset.

The fixtures compile the real power_save.nim, task_handlers.nim,
kernel_mac_channel.nim and channel_timer.nim procedures. Only the platform
edges are modelled: the TX frame pool (with the same reset-epoch, station-epoch
and PS-serial freshness rules as txlFrameIdentityCurrent), the MM timer list,
the kernel message queue and the MAC PM register.

The audit findings below were reproduced here and are now fixed; their tests
check the fix:

PSK-1  A dynamic-PS sleep transition that is in flight when a channel switch
       (chanForceIdle -> mm_force_idle_req -> txl_reset) or MAC recovery
       advances txResetEpoch is never finished. Its null-frame confirmation is
       suppressed by the reset epoch, ps_tx_null_timer_handle refuses the
       timeout because psTxNullOwner.resetEpoch was captured at arm time, and
       mmPsModeRetryAfterReset only rescues explicit MM requests.
PSK-2  A connection-loss indication published before a channel-switch reset was
       dropped, although the VIF and station were current: its disconnect
       handoff carried the publication's TX reset epoch, and the handler had
       already set state 10, so SM stayed there. The teardown (station_sm.nim)
       no longer carries an epoch and publishes state 10 only after its claim.
"""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_handler_contracts import owned_disconnect_source
from test_wifi_message_allocation import run_program


MODES = ["checked", "release", "asan"]

PS_PLATFORM = r'''
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_STA = 0'u8
  TASK_MM = 0'u8
  TASK_ME = 3'u8
  TASK_API = 11'u8
  MM_SET_PS_MODE_REQ = 0x1F'u16
  MM_SET_PS_MODE_CFM = 0x20'u16
  KE_EVT_KE_MESSAGE = 0x01000000'u32
  HW_ACTIVE = 3
  MM_ACTIVE_STATE = 1'u16
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint
  PmRegister = 0x24B0004C'u
  TxAck = 0x80800000'u32      # Done and acknowledged.
  TxNoAck = 0x80000000'u32    # Done, retry limit reached without an ACK.
  TxFlushed = 0x40000000'u32  # txl_cfm_flush: never completed on air.
const MmSetPsModeReqPayloadSize = sizeof(MmSetPsModeReqPayload).uint32
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  Vif = object
    next: pointer
    flags, keyPsState, psLastTime: uint32
    vifIdx, vifType, state, staIdx, psNullRetry, uapsdBitmap, psFlags: uint8
  KePs = object
    flags, staPending: uint8
  MmEnv = object
    previousState: uint16
    hardwareMode: uint8
  VifEnv = object
    activeList: tuple[first: pointer]
  Frame = object
    sta: uint8
    callback: pointer
    argWord, resetEpoch, psSerial, stationEpoch: uint32
    psTracked, done: bool
  Cfm = tuple[id: uint16, dest: uint8]
var
  ps: PsEnvView
  params: BlPsParamsView
  vifs: array[MAX_VIFS, Vif]
  vifEnv: VifEnv
  tdEntries: array[MAX_VIFS, TdEntryView]
  ke: KePs
  mm: MmEnv
  rxVifEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[STA_INFO_TAB_ENTRIES, uint32]
  txResetEpoch, psModeBuildSerial, mmPsModeTxResetEpoch: uint32
  psTxNullOwner: PsTxNullOwner
  mmPsModeRequest, meControlCommand: pointer
  keMsgQueueSent: CoList
  chanTbttTimerOwner, chanConnlessTimerOwner: tuple[valid: bool, resetEpoch: uint32]
  mmState: uint16
  pmRegister, macNow: uint32
  frames: seq[Frame]
  activeFrame = -1
  nullSendStatus: uint8
  onSend: proc()
  nullTimerArmed, uapsdTimerArmed: bool
  cfms: seq[Cfm]
  requeued: seq[pointer]
  liveRequests: int
  losses: seq[uint16]
  interrupts = true

proc irqSave(): uint32 =
  result = interrupts.uint32
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = saved != 0
proc psEnvView(): ptr PsEnvView = addr ps
proc blPsParamsView(): ptr BlPsParamsView = addr params
proc vifMgmtEnvView(): ptr VifEnv = addr vifEnv
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(index: uint8): ptr Vif =
  if index < MAX_VIFS.uint8: addr vifs[index] else: nil
proc staDeleteEpoch(index: uint8): uint32 =
  if index < STA_INFO_TAB_ENTRIES.uint8: stationEpochs[index] else: 0'u32
proc keEnvPsFlags(): ptr KePs = addr ke
proc mmEnvView(): ptr MmEnv = addr mm
proc tdEntryForVif(index: uint8): ptr TdEntryView = addr tdEntries[index]
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc macTimeNow(): uint32 = macNow
proc getLogFunc(slot: int): pointer = nil
proc blOpsFunc(slot: int): pointer = nil
proc volatileLoad(p: ptr uint32): uint32 =
  doAssert cast[uint](p) == PmRegister
  pmRegister
proc volatileStore(p: ptr uint32; value: uint32) =
  doAssert cast[uint](p) == PmRegister
  pmRegister = value
proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, size.int)
  p
proc chan_is_on_channel(p: pointer): bool {.cdecl.} = true
template psUapsdTimer(): pointer = cast[pointer](addr psEnvView().nullRetryLimit)
template psTxNullTimer(): pointer = cast[pointer](addr psEnvView().txNullTimerWord)
proc mm_timer_set(timer: pointer; expiry: uint32) =
  if timer == psTxNullTimer(): nullTimerArmed = true
  else:
    doAssert timer == psUapsdTimer()
    uapsdTimerArmed = true
proc mm_timer_clear(timer: pointer) =
  if timer == psTxNullTimer(): nullTimerArmed = false
  else:
    doAssert timer == psUapsdTimer()
    uapsdTimerArmed = false
proc mmTimerActiveDelivery(timer: pointer): ptr MmTimerMutation = nil
proc wifi_hosal_pm_post_event(event, code: uint32; p: pointer) =
  if p != nil: cast[ptr uint32](p)[] = 0
proc td_cfm_set_timer(index: uint8; value: uint32) = discard
proc ke_evt_set(bits: uint32) = discard
proc mm_send_connection_loss_ind(vif: pointer; reason: uint16) = losses.add(reason)
proc keMsgPayload(header: ptr KeMsgHdr): pointer =
  cast[pointer](cast[uint](header) + sizeof(KeMsgHdr).uint)
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc ke_msg_free(header: ptr KeMsgHdr) =
  dec liveRequests
  dealloc(header)
proc ke_msg_send_basic(id: uint16; dest, src: uint8) = cfms.add((id, dest))
proc ke_msg_send_basic_reply(request: pointer; id: uint16) =
  cfms.add((id, keMsgHdrFromPayload(request).srcId))
proc ke_reschedule_saved_messages(task: uint8): bool = false
proc co_list_push_front(list: ptr CoList; node: ptr CoListHdr) =
  doAssert list == addr keMsgQueueSent
  requeued.add(keMsgPayload(cast[ptr KeMsgHdr](node)))
proc ke_state_get(task: uint8): uint16 =
  doAssert task == TASK_MM
  mmState
proc ke_state_set(task: uint8; state: uint16) =
  doAssert task == TASK_MM
  mmState = state
proc smStaleRequest(p: pointer): bool = false
proc smCleanupAdmitRequest(p: pointer): bool = true
proc txlResetting(): bool = false
proc ps_polling_frame(p: pointer): uint8 {.discardable.} = 0
proc mmSetPsModeReqView(p: pointer): ptr MmSetPsModeReqPayload =
  cast[ptr MmSetPsModeReqPayload](p)
proc hal_machw_reset(): bool = true
proc rxl_reset(): bool = true
proc smScanPreserveAcrossChannelReset(previous: uint32) = discard
proc smRegistrationPreserveAcrossChannelReset(previous: uint32) = discard
proc ps_uapsd_timer_handle() {.cdecl.} = discard

proc ps_disable_cfm*(vifEntry: pointer, statusFlags: uint32) {.exportc, cdecl.}
proc ps_enable_cfm*(vifEntry: pointer, status: uint32) {.exportc, cdecl.}
proc ps_enable_cfm_handle*(vifEntry: pointer) {.exportc, cdecl, noinline.}
proc ps_disable_cfm_handle*(vifEntry: pointer): uint32 {.exportc, cdecl.}
proc ps_dpsm_update*(enable: uint32): uint32 {.exportc, cdecl, discardable.}
proc ps_tx_null_timer_handle*() {.exportc, cdecl.}
proc mmPsModeCancel()
proc mmPsModeComplete()
proc mmPsModeRetryAfterReset()

# TX frame pool. Freshness follows txlFrameIdentityCurrent: the reset epoch and
# station epoch at lease, plus the PS serial stamped on entry for PS callbacks.
proc frameCurrent(f: Frame): bool =
  f.resetEpoch == txResetEpoch and stationEpochs[f.sta] == f.stationEpoch and
    (not f.psTracked or f.psSerial == psModeBuildSerial)
proc txlFrameCallbackCurrent(): bool =
  activeFrame < 0 or frameCurrent(frames[activeFrame])
proc txl_frame_send_null_frame(staIdx: uint8; cfmCallback: pointer;
                               cfmArg: uint32): uint8 {.discardable.} =
  let tracked = cfmCallback == cast[pointer](ps_enable_cfm) or
    cfmCallback == cast[pointer](ps_disable_cfm)
  frames.add(Frame(sta: staIdx, callback: cfmCallback, argWord: cfmArg,
    resetEpoch: txResetEpoch, psSerial: psModeBuildSerial,
    stationEpoch: stationEpochs[staIdx], psTracked: tracked,
    done: nullSendStatus != 0))
  if onSend != nil: onSend()
  nullSendStatus
proc argPointer(word: uint32): pointer =
  for index in 0 ..< MAX_VIFS:
    if pointerAddrU32(addr vifs[index]) == word: return addr vifs[index]
  doAssert false, "callback argument is not a VIF"
proc deliver(index: int; status: uint32) =
  ## txl_frame_cfm: always calls the callback; the callback checks freshness.
  doAssert not frames[index].done
  frames[index].done = true
  let callback = frames[index].callback
  if callback == nil: return
  let arg = argPointer(frames[index].argWord)
  let previous = activeFrame
  activeFrame = index
  cast[proc(p: pointer; status: uint32) {.cdecl.}](callback)(arg, status)
  activeFrame = previous
proc flushPending() =
  let count = frames.len
  for index in 0 ..< count:
    if not frames[index].done: deliver(index, TxFlushed)
proc txl_cntrl_clear_ac(ac: uint8): bool =
  doAssert ac == 3
  flushPending()
  true
proc txl_reset(): bool =
  # tx_layer.nim advances the epoch before flushing the queued confirmations.
  inc txResetEpoch
  flushPending()
  true
proc fireNullTimer(): bool =
  if not nullTimerArmed: return false
  nullTimerArmed = false
  ps_tx_null_timer_handle()
  true
proc ackEverything() =
  for _ in 0 .. 3:
    for index in 0 ..< frames.len:
      if not frames[index].done: deliver(index, TxAck)
    discard fireNullTimer()
proc request(mode: uint8): pointer =
  let header = cast[ptr KeMsgHdr](alloc0(sizeof(KeMsgHdr) + 4))
  header.id = MM_SET_PS_MODE_REQ
  header.destId = TASK_MM
  header.srcId = TASK_ME
  header.paramLen = MmSetPsModeReqPayloadSize
  inc liveRequests
  result = keMsgPayload(header)
  mmSetPsModeReqView(result).mode = mode
proc setup(stations = 1) =
  ## Associated STA with dynamic PS enabled and currently awake.
  ps = PsEnvView(enabled: 1, mode: TASK_ME, flags: 0x09, statusFlags: 0x08,
                 uapsdPeriod: 100)
  params = BlPsParamsView(trafficPeriod: 100, timPeriod: 100, trafficThreshold: 1,
                          nullRetryLimit: 8, txNullTimeout: 50)
  vifs[0] = Vif(vifIdx: 0, vifType: VIF_TYPE_STA, state: 1, staIdx: 2)
  vifs[1] = Vif(vifIdx: 1, vifType: 4, staIdx: 0xFF)
  if stations == 2:
    vifs[1] = Vif(vifIdx: 1, vifType: VIF_TYPE_STA, state: 1, staIdx: 3)
    vifs[0].next = addr vifs[1]
  vifEnv.activeList.first = addr vifs[0]
  for index in 0 ..< MAX_VIFS:
    tdEntries[index] = TdEntryView(vifIdx: index.uint8, active: 1)
  ke = default(KePs)
  mm = default(MmEnv)
  rxVifEpochs = default(typeof(rxVifEpochs))
  stationEpochs = default(typeof(stationEpochs))
  txResetEpoch = 0
  psModeBuildSerial = 0
  mmPsModeTxResetEpoch = 0
  psTxNullOwner = default(PsTxNullOwner)
  mmPsModeRequest = nil
  meControlCommand = nil
  keMsgQueueSent = default(CoList)
  chanTbttTimerOwner = (false, 0'u32)
  chanConnlessTimerOwner = (false, 0'u32)
  mmState = MM_ACTIVE_STATE
  pmRegister = 0
  macNow = 1000
  frames.setLen(0)
  activeFrame = -1
  nullSendStatus = 0
  onSend = nil
  nullTimerArmed = false
  uapsdTimerArmed = false
  cfms.setLen(0)
  requeued.setLen(0)
  liveRequests = 0
  losses.setLen(0)
  interrupts = true
'''

PS_HELPERS = r'''
proc beginSleep() =
  ## A traffic-detection sample reports idle: DPSM starts a sleep transition.
  discard ps_traffic_status_update(0, 0)
  doAssert ps.flags == 0x0D and ps.pendingCount == 1 and nullTimerArmed
  doAssert (pmRegister and 4) != 0 and frames.len == 1
  doAssert frames[0].callback == cast[pointer](ps_enable_cfm) and not frames[0].done
'''


def ps_source() -> str:
    power = (FW / "power_save.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    channel = (FW / "channel_timer.nim").read_text()
    code = layouts("PsEnvView", "BlPsParamsView", "TdEntryView", "MmVifIdentity",
                   "PsTxNullOwner", "MmTimerMutation", "KeMsgHdr",
                   "MmSetPsModeReqPayload")
    code += PS_PLATFORM
    code += procedure(kernel, "mmCaptureVif") + procedure(kernel, "mmVifCurrent")
    for name in ["ps_init", "ps_set_mode", "ps_check_tx_status_part0_nim",
                 "ps_disable_cfm", "ps_traffic_status_update", "ps_tx_null_timer_handle",
                 "ps_disable_cfm_handle", "ps_enable_cfm", "ps_enable_cfm_handle",
                 "ps_dpsm_update"]:
        code += procedure(power, name)
    for name in ["mmPsModeCancel", "mmPsModeComplete", "mmPsModeRetryAfterReset",
                 "mm_set_ps_mode_req_handler"]:
        code += procedure(tasks, name)
    code += ("\nwhen not declared(mmConfigCancelIdle):\n  proc mmConfigCancelIdle() = discard\n" + procedure(kernel, "mm_force_idle_req"))
    code += procedure(channel, "chanForceIdle")
    return code + PS_HELPERS


# --- Overlap ----------------------------------------------------------------

@pytest.mark.parametrize("mode", MODES)
def test_explicit_request_parks_behind_dpsm_sleep_and_replays_once(
        tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + r'''
setup()
beginSleep()
# ME disables PS (for example on disconnect) while the sleep null frame is out.
let req = request(0)
doAssert mm_set_ps_mode_req_handler(req) == KeMsgNoFree
doAssert mmPsModeRequest == req and ps.flags == 0x1D and ps.deferredMode == 0
doAssert frames.len == 1 and cfms.len == 0
# The DPSM confirmation finishes the sleep and replays the parked request.
deliver(0, TxAck)
doAssert ps.flags == 0 and (pmRegister and 4) == 0 and not nullTimerArmed
doAssert frames.len == 2 and frames[1].callback == cast[pointer](ps_disable_cfm)
doAssert cfms.len == 0 and mmPsModeRequest == req
deliver(1, TxAck)
doAssert cfms == @[(MM_SET_PS_MODE_CFM, TASK_ME)]
doAssert mmPsModeRequest == nil and ps.enabled == 0 and ps.pendingCount == 0
doAssert liveRequests == 0 and interrupts
# Later traffic samples cannot restart DPSM once PS is disabled.
doAssert ps_traffic_status_update(0, 4) == 0 and frames.len == 2
''')


@pytest.mark.parametrize("mode", MODES)
def test_dpsm_batch_retries_and_traffic_overlap_finish_once(
        tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + r'''
setup(stations = 2)
discard ps_traffic_status_update(0, 0)
doAssert ps.flags == 0x0D and ps.pendingCount == 2 and frames.len == 2
deliver(0, TxAck)
doAssert ps.pendingCount == 1 and ps.flags == 0x0D and nullTimerArmed
# Traffic on the other station cannot start an overlapping wake batch.
doAssert ps_traffic_status_update(1, 4) == 0
doAssert frames.len == 2 and (pmRegister and 4) != 0
# The second station's frame was not acknowledged: retry within the batch.
deliver(1, TxNoAck)
doAssert frames.len == 3 and frames[2].sta == 3 and vifs[1].psNullRetry == 1
doAssert frames[2].callback == cast[pointer](ps_enable_cfm) and ps.pendingCount == 1
deliver(2, TxAck)
doAssert ps.pendingCount == 0 and ps.flags == 1 and not nullTimerArmed
doAssert vifs[1].keyPsState == 1 and losses.len == 0
# Exactly one completion: the next traffic sample performs a full wake.
doAssert ps_traffic_status_update(0, 4) == 1
doAssert ps.flags == 9 and (pmRegister and 4) == 0 and ps.pendingCount == 0
doAssert frames.len == 5 and frames[3].callback == nil and frames[4].callback == nil
doAssert interrupts
''')


# --- Cancellation -------------------------------------------------------------

@pytest.mark.parametrize("mode", MODES)
def test_cancelled_explicit_transition_ignores_late_confirmation(
        tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + r'''
for phase in ["during", "after"]:
  setup()
  ps.flags = 1        # DPSM asleep, no transition in flight.
  pmRegister = 4
  let req = request(0)
  meControlCommand = req
  if phase == "during":
    # The ME owner is reset while the null frame is being submitted.
    onSend = proc() =
      onSend = nil
      mmPsModeCancel()
  doAssert mm_set_ps_mode_req_handler(req) == KeMsgNoFree
  if phase == "after":
    doAssert mmPsModeRequest == req and ps.pendingCount == 1
    mmPsModeCancel()
  doAssert mmPsModeRequest == nil and meControlCommand == nil and liveRequests == 0
  doAssert ps.pendingCount == 0 and frames.len == 1
  # The AP acknowledges the cancelled transition's frame afterwards.
  deliver(0, TxAck)
  doAssert cfms.len == 0 and ps.pendingCount == 0 and ps.enabled == 1
  # The machine is reusable: a fresh request completes exactly once.
  let again = request(0)
  doAssert mm_set_ps_mode_req_handler(again) == KeMsgNoFree
  doAssert frames.len == 2
  deliver(1, TxAck)
  doAssert cfms == @[(MM_SET_PS_MODE_CFM, TASK_ME)] and mmPsModeRequest == nil
  doAssert ps.enabled == 0 and ps.flags == 0 and liveRequests == 0 and interrupts
''')


@pytest.mark.parametrize("mode", MODES)
def test_cancelled_parked_request_is_not_replayed(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + r'''
setup()
beginSleep()
let req = request(0)
doAssert mm_set_ps_mode_req_handler(req) == KeMsgNoFree and ps.flags == 0x1D
meControlCommand = req
mmPsModeCancel()
doAssert mmPsModeRequest == nil and meControlCommand == nil and liveRequests == 0
# Only the parked command is cancelled; DPSM still owns its transition.
doAssert ps.flags == 0x0D and ps.pendingCount == 1 and nullTimerArmed
deliver(0, TxAck)
doAssert ps.flags == 1 and (pmRegister and 4) != 0 and not nullTimerArmed
doAssert frames.len == 1 and cfms.len == 0 and interrupts
''')


# --- Reset --------------------------------------------------------------------

@pytest.mark.parametrize("mode", MODES)
def test_channel_switch_reset_strands_dpsm_sleep_transition(
        tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + r'''
setup()
beginSleep()
# A scan or multi-channel switch leaves the home channel before the ACK.
doAssert chanForceIdle()
doAssert txResetEpoch == 1 and frames[0].done and requeued.len == 0
mmState = MM_ACTIVE_STATE   # The switch finishes and MM is active again.
doAssert fireNullTimer()
doAssert ps.pendingCount == 0 and (ps.flags and 6) == 0,
  "DPSM transition stranded: flags=" & $ps.flags & " pending=" & $ps.pendingCount
# Traffic must then be able to bring the station out of power save.
discard ps_traffic_status_update(0, 4)
doAssert (ps.flags and 8) != 0 and (pmRegister and 4) == 0
''')


@pytest.mark.parametrize("mode", MODES)
def test_explicit_request_after_stranded_dpsm_never_confirms(
        tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + r'''
setup()
beginSleep()
doAssert chanForceIdle()
mmState = MM_ACTIVE_STATE
discard fireNullTimer()
let req = request(0)
doAssert mm_set_ps_mode_req_handler(req) == KeMsgNoFree
ackEverything()
doAssert cfms == @[(MM_SET_PS_MODE_CFM, TASK_ME)],
  "request parked: flags=" & $ps.flags & " pending=" & $ps.pendingCount
''')


@pytest.mark.parametrize("mode", MODES)
def test_explicit_transition_across_channel_switch_is_requeued(
        tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + r'''
setup()
ps.flags = 1      # DPSM asleep; ME requests PS off.
pmRegister = 4
let req = request(0)
doAssert mm_set_ps_mode_req_handler(req) == KeMsgNoFree
doAssert ps.pendingCount == 1 and frames.len == 1
doAssert chanForceIdle()
# The flushed confirmation was stale; the request is retained and requeued.
doAssert requeued == @[req] and mmPsModeRequest == nil and liveRequests == 1
doAssert ps.pendingCount == 0 and (ps.flags and 0x16) == 0 and cfms.len == 0
# While MM is still forced idle, the replay waits.
doAssert mm_set_ps_mode_req_handler(req) == KeMsgSaved
mmState = MM_ACTIVE_STATE
doAssert mm_set_ps_mode_req_handler(req) == KeMsgNoFree
doAssert frames.len == 2 and frames[1].resetEpoch == 1
deliver(1, TxAck)
doAssert cfms == @[(MM_SET_PS_MODE_CFM, TASK_ME)] and mmPsModeRequest == nil
doAssert ps.enabled == 0 and liveRequests == 0 and interrupts
''')


@pytest.mark.parametrize("mode", MODES)
def test_mm_reset_retires_pending_ps_work(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + r'''
setup()
beginSleep()
let req = request(0)
doAssert mm_set_ps_mode_req_handler(req) == KeMsgNoFree and ps.flags == 0x1D
meControlCommand = req
# MM_RESET_REQ: me_init() -> meControlReset() -> mmPsModeCancel(); mm_init() -> ps_init().
mmPsModeCancel()
ps_init()
doAssert mmPsModeRequest == nil and liveRequests == 0 and cfms.len == 0
doAssert ps.enabled == 0 and ps.flags == 0 and ps.pendingCount == 0
doAssert ps.txNullTimerCallback == cast[pointer](ps_tx_null_timer_handle)
# ME enables PS again before the pre-reset work has drained. ps_init zeroed
# pendingCount, so only a live transition shows whether stale work is ignored.
let again = request(2)
doAssert mm_set_ps_mode_req_handler(again) == KeMsgNoFree
doAssert mmPsModeRequest == again and ps.flags == 1 and ps.pendingCount == 1
doAssert frames.len == 2 and frames[1].callback == cast[pointer](ps_enable_cfm)
# A stale TX-null timeout (old arm serial) must not abort the new transition.
doAssert fireNullTimer()
doAssert ps.pendingCount == 1 and not frames[1].done and cfms.len == 0
# The pre-reset null frame's late ACK must not confirm the new request.
deliver(0, TxAck)
doAssert ps.pendingCount == 1 and cfms.len == 0 and mmPsModeRequest == again
deliver(1, TxAck)
doAssert cfms == @[(MM_SET_PS_MODE_CFM, TASK_ME)] and mmPsModeRequest == nil
doAssert ps.enabled == 1 and ps.flags == 1 and ps.pendingCount == 0
doAssert liveRequests == 0 and interrupts
''')


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
proc mmPsModeRetryAfterReset() = discard
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
