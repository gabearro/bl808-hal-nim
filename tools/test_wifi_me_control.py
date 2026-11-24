"""Exercise real ME/MM active and power-save transactions without a radio."""

from pathlib import Path

import pytest

from test_wifi_ap_start import program_source, run_program
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program as run_native


DRIVER = r"""
proc resetControl() =
  reset(0, false)
  ke_msg_free(keMsgHdrFromPayload(request))
  request = nil

proc stepControl(): cint =
  let h = co_list_pop_front(addr keMsgQueueSent)
  doAssert h != nil
  let p = keMsgPayload(h)
  case h.id
  of ME_SET_ACTIVE_REQ: result = me_set_active_req_handler(p)
  of ME_SET_PS_DISABLE_REQ: result = me_set_ps_disable_req_handler(p)
  of MM_SET_IDLE_REQ: result = mm_set_idle_req_handler(p)
  of MM_SET_PS_MODE_REQ: result = mm_set_ps_mode_req_handler(p)
  of MM_SET_IDLE_CFM: result = mm_set_idle_cfm_handler(p)
  of MM_SET_PS_MODE_CFM: result = mm_set_ps_mode_cfm_handler(p)
  of 0xC00: result = me_config_req_handler(p)
  else: doAssert false, "unexpected control message " & $h.id
  if result == KeMsgConsumed: ke_msg_free(h)
  elif result == KeMsgSaved: co_list_push_back(addr keMsgQueueSaved, h)
  else: doAssert result == KeMsgNoFree

proc requestControl(psChange: bool; value, vif: uint8): pointer =
  result = newMessage(if psChange: ME_SET_PS_DISABLE_REQ else: ME_SET_ACTIVE_REQ,
                      TASK_ME, TASK_API, 2)
  let bytes = cast[ptr array[2, uint8]](result)
  bytes[] = [value, vif]
  ke_msg_send(result)

proc drainControl() =
  var steps = 0
  while keMsgQueueSent.first != nil:
    inc steps
    doAssert steps < 16
    if stepControl() == KeMsgSaved:
      doAssert mmState in [TaskGoingIdleState, HW_ACTIVE]
      # Simulate the MAC idle event, not a manual ME-state reset.
      ke_state_set(TASK_MM, MM_IDLE)
  doAssert keMsgQueueSaved.first == nil
"""


MATRIX = r"""
for psChange in [false, true]:
  for oldMask in 0'u32 .. 3:
    for value in 0'u8 .. 1:
      for vif in 0'u8 .. 1:
        for psOn in 0'u8 .. 1:
          for hardwareState in [0'u16, 1, 2, 3]:
            resetControl()
            mmState = hardwareState
            me.psOn = psOn
            me.activeMask = oldMask
            me.psDisableMask = oldMask
            let request = requestControl(psChange, value, vif)
            let first = stepControl()
            let fast = (psChange and psOn == 0) or
              (oldMask == 0 and value == 0) or (oldMask != 0 and value != 0)
            let target = if psChange and psOn == 0: oldMask
              elif value == 0: oldMask and not (1'u32 shl vif)
              else: oldMask or (1'u32 shl vif)
            if fast:
              doAssert first == KeMsgConsumed and meState == MeIdleState
              doAssert controlReplies.len == 1 and keMsgQueueSent.first == nil
            else:
              doAssert first == KeMsgNoFree and meState == MeBusyState
              doAssert me.requesterId == TASK_API and controlReplies.len == 0
              doAssert meControlCommand == request and not meControlReplyReady
              let command = keMsgQueueSent.first
              doAssert keMsgPayload(command) == request
              doAssert command.srcId == TASK_ME and command.destId == TASK_MM
              doAssert command.paramLen == 1
              doAssert command.id == (if psChange: MM_SET_PS_MODE_REQ else: MM_SET_IDLE_REQ)
              doAssert cast[ptr uint8](request)[] ==
                (if psChange: (if target == 0: 2'u8 else: 0'u8) else: uint8(target == 0))
              let unrelated = newMessage(if psChange: MM_SET_PS_MODE_CFM else: MM_SET_IDLE_CFM,
                                         TASK_ME, TASK_MM, 0)
              let before = meControlReply
              let stale = if psChange: mm_set_ps_mode_cfm_handler(unrelated)
                          else: mm_set_idle_cfm_handler(unrelated)
              doAssert stale == KeMsgConsumed and meControlReply == before
              doAssert meState == MeBusyState and controlReplies.len == 0
              ke_msg_free(keMsgHdrFromPayload(unrelated))
              drainControl()
              doAssert meState == MeIdleState and me.requesterId == TASK_NONE
              doAssert meControlCommand == nil and meControlReply == nil
              doAssert controlReplies.len == 1
            doAssert (if psChange: me.psDisableMask else: me.activeMask) == target
            let cfm = controlReplies[0]
            doAssert cfm.id == (if psChange: ME_SET_PS_DISABLE_CFM else: ME_SET_ACTIVE_CFM)
            doAssert cfm.src == TASK_ME and cfm.dst == TASK_API and cfm.length == 0
            doAssert allocated.len == 0

# An in-flight PS exchange retains the MM command through a deferred callback.
resetControl()
psDeferred = true
let pending = requestControl(true, 1, 1)
doAssert stepControl() == KeMsgNoFree
doAssert stepControl() == KeMsgNoFree
doAssert meState == MeBusyState and mmPsModeRequest == pending
doAssert controlReplies.len == 0 and allocated.len == 2
let concurrent = newMessage(ME_SET_ACTIVE_REQ, TASK_ME, TASK_API, 2)
cast[ptr array[2, uint8]](concurrent)[] = [1'u8, 0]
doAssert me_set_active_req_handler(concurrent) == KeMsgSaved
doAssert me.activeMask == 0 and controlReplies.len == 0
ke_msg_free(keMsgHdrFromPayload(concurrent))
mmPsModeComplete()
doAssert mmPsModeRequest == nil and controlReplies.len == 0
let replyHeader = keMsgQueueSent.first
replyHeader.srcId = TASK_API
doAssert mm_set_ps_mode_cfm_handler(keMsgPayload(replyHeader)) == KeMsgConsumed
doAssert meState == MeBusyState and meControlReply != nil
replyHeader.srcId = TASK_MM
drainControl()
doAssert meState == MeIdleState and controlReplies.len == 1 and allocated.len == 0

# Allocation failure does not commit the mask or take the caller's message.
resetControl()
let retry = requestControl(false, 1, 0)
failAt = kernelAllocations + 1
doAssert stepControl() == KeMsgSaved
doAssert meState == MeIdleState and me.activeMask == 0
doAssert meControlCommand == nil and meControlReply == nil and allocated.len == 1
failAt = 0
discard ke_reschedule_saved_messages(TASK_ME)
drainControl()
doAssert me.activeMask == 1 and controlReplies.len == 1 and allocated.len == 0

for psChange in [false, true]:
  for malformed in 0 .. 2:
    resetControl()
    let p = requestControl(psChange, 1, 0)
    discard co_list_pop_front(addr keMsgQueueSent)
    if malformed == 0: keMsgHdrFromPayload(p).paramLen = 0
    elif malformed == 1: cast[ptr array[2, uint8]](p)[1] = 255
    let result = if psChange: me_set_ps_disable_req_handler(if malformed == 2: nil else: p)
                 else: me_set_active_req_handler(if malformed == 2: nil else: p)
    doAssert result == KeMsgConsumed and meState == MeIdleState
    doAssert me.activeMask == 0 and me.psDisableMask == 0
    doAssert controlReplies.len == 0
    ke_msg_free(keMsgHdrFromPayload(p))
"""


RESET = r"""
for phase in 0 .. 2:
  for saved in [false, true]:
    resetControl()
    psDeferred = phase == 1
    discard requestControl(true, 1, 0)
    doAssert stepControl() == KeMsgNoFree
    if phase != 0: doAssert stepControl() == KeMsgNoFree
    if saved and keMsgQueueSent.first != nil:
      co_list_push_back(addr keMsgQueueSaved, co_list_pop_front(addr keMsgQueueSent))
    let unrelated = newMessage(0x777, TASK_MM, TASK_API, 0)
    ke_msg_send(unrelated)
    meControlReset()
    doAssert meControlCommand == nil and meControlReply == nil
    doAssert mmPsModeRequest == nil and me.requesterId == TASK_NONE
    doAssert keMsgQueueSaved.first == nil and allocated.len == 1
    doAssert keMsgPayload(co_list_pop_front(addr keMsgQueueSent)) == unrelated
    doAssert keMsgQueueSent.first == nil
    ke_msg_free(keMsgHdrFromPayload(unrelated))
    meControlReset()
    doAssert allocated.len == 0
"""

CANCEL_PS = r"""
for parked in [false, true]:
  resetControl()
  psDeferred = true
  discard requestControl(true, 1, 0)
  doAssert stepControl() == KeMsgNoFree and stepControl() == KeMsgNoFree
  doAssert mmPsModeRequest != nil and allocated.len == 2
  ps.flags = (if parked: 0x15'u8 else: 1'u8)
  ps.pendingCount = 2
  ps.currentVif = addr vifs[0]
  let serial = psModeBuildSerial
  meControlReset()
  doAssert mmPsModeRequest == nil and meControlReply == nil and allocated.len == 0
  doAssert controlReplies.len == 0 and keMsgQueueSent.first == nil
  if parked:
    doAssert ps.flags == 5 and ps.pendingCount == 2 and ps.currentVif == addr vifs[0]
    doAssert psModeBuildSerial == serial
  else:
    doAssert ps.flags == 1 and ps.pendingCount == 0 and ps.currentVif == nil
    doAssert psModeBuildSerial == serial + 1
  let after = (ps, psModeBuildSerial)
  meControlReset()
  doAssert (ps, psModeBuildSerial) == after
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_cancel_ps_owner_and_parked_request_separately(tmp_path: Path, mode: str) -> None:
    run_native(tmp_path, mode, program_source() + DRIVER + CANCEL_PS)


PS_RESET = r"""
const KE_EVT_KE_MESSAGE = 0x08000000'u32
var txResetAllowed: bool
var nullTimerClears: int
proc psTxNullTimer(): pointer = addr nullTimerClears
proc mm_timer_clear(timer: pointer) =
  doAssert timer == psTxNullTimer()
  inc nullTimerClears
proc ke_evt_set(bits: uint32) = doAssert bits == KE_EVT_KE_MESSAGE
proc ke_evt_clear(bits: uint32) = discard
proc waitMacSoftResetClear(): bool = true
template smSaQueryResetScope() = discard
proc smSaQueryClearResetTimer() = discard
proc hal_machw_reset(): bool = true
proc rxl_reset(): bool = true
proc txl_reset(): bool =
  inc txResetEpoch
  txResetAllowed
proc mm_reset() = ke_state_set(TASK_MM, MM_IDLE)
proc vif_mgmt_reset() = discard
"""

PS_RESET_CHECKS = r"""
proc startDeferredPs(): pointer =
  resetControl()
  psDeferred = true
  nullTimerClears = 0
  result = requestControl(true, 1, 1)
  doAssert stepControl() == KeMsgNoFree
  doAssert stepControl() == KeMsgNoFree
  doAssert mmPsModeRequest == result and mmPsModeTxResetEpoch == txResetEpoch
  doAssert controlReplies.len == 0 and meState == MeBusyState
  ps.pendingCount = 1
  ps.flags = 0x9F
  ps.currentVif = addr vifs[0]

let original = startDeferredPs()
let reservedReply = meControlReply
let later = newMessage(MM_SET_PS_MODE_REQ, TASK_MM, TASK_API, 1)
cast[ptr uint8](later)[] = 2
ke_msg_send(later)
doAssert stepControl() == KeMsgSaved
txResetAllowed = false
bl_reset_evt()
doAssert mmPsModeRequest == original and nullTimerClears == 0
doAssert keMsgQueueSent.first == nil and controlReplies.len == 0
mmPsModeComplete() # An old completion cannot confirm after its TX epoch retired.
doAssert mmPsModeRequest == original and controlReplies.len == 0
txResetAllowed = true
bl_reset_evt()
doAssert mmPsModeRequest == nil and meControlReply == reservedReply
doAssert nullTimerClears == 1 and ps.pendingCount == 0 and ps.currentVif == nil
doAssert ps.flags == 0x89
doAssert keMsgPayload(keMsgQueueSent.first) == original
doAssert keMsgPayload(keMsgQueueSent.first.next) == later
mmPsModeRetryAfterReset()
doAssert nullTimerClears == 1 and controlReplies.len == 0
psDeferred = false
drainControl()
doAssert psModes == @[0'u8, 0, 2]
doAssert controlReplies.len == 2 and allocated.len == 0
doAssert controlReplies[0].id == MM_SET_PS_MODE_CFM
doAssert controlReplies[1].id == ME_SET_PS_DISABLE_CFM and meState == MeIdleState

let paused = startDeferredPs()
doAssert mm_force_idle_req()
doAssert mmState == HW_ACTIVE and mmPsModeRequest == nil
doAssert keMsgPayload(keMsgQueueSent.first) == paused
doAssert stepControl() == KeMsgSaved and controlReplies.len == 0
doAssert keMsgPayload(keMsgQueueSaved.first) == paused
ke_state_set(TASK_MM, MM_IDLE)
psDeferred = false
drainControl()
doAssert psModes == @[0'u8, 0] and controlReplies.len == 1 and allocated.len == 0
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mac_reset_replays_retained_ps_mode(tmp_path: Path, mode: str) -> None:
    handlers = (FW / "task_handlers.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    platform = (FW / "platform_bl.nim").read_text()
    code = program_source()
    code += DRIVER + PS_RESET
    code += procedure(kernel, "co_list_push_front")
    code += procedure(handlers, "mmPsModeRetryAfterReset")
    code += procedure(platform, "bl_reset_evt") + procedure(kernel, "mm_force_idle_req")
    run_native(tmp_path, mode, code + PS_RESET_CHECKS)


CONFIG = r"""
for enabled in [0'u8, 1]:
  resetControl()
  me.psOn = 5
  let request = newMessage(0xC00, TASK_ME, TASK_API, MeConfigReqPayloadSize)
  let config = meConfigReqView(request)
  config.psOn = enabled
  config.htSupp = 0
  config.defKey = 123
  ke_msg_send(request)
  let result = stepControl()
  doAssert result == (if enabled == 0: KeMsgConsumed else: KeMsgNoFree)
  doAssert controlReplies.len == 1 and controlReplies[0].id == ME_CONFIG_CFM
  doAssert not configCfmSawCommand
  doAssert configCfmSeenFields == (0'u8, 5'u8, 0'u8, 0'u8, 0'u16),
    $configCfmSeenFields
  doAssert configCfmSeenRequester == 0
  if enabled != 0: doAssert configCfmSawOriginalRequest
  doAssert controlReplies[0].length == 0
  doAssert me.defKey == 123 and me.psOn == enabled
  if enabled != 0:
    doAssert meState == MeBusyState and me.requesterId == TASK_NONE
    doAssert keMsgQueueSent.first.id == MM_SET_PS_MODE_REQ
    doAssert cast[ptr uint8](keMsgPayload(keMsgQueueSent.first))[] == 2
    drainControl()
    doAssert psModes == @[2'u8]
  doAssert meState == MeIdleState and controlReplies.len == 1 and allocated.len == 0

# A failed control allocation must not publish a confirmation that a retry
# would duplicate.
resetControl()
me.psOn = 5
me.htSupp = 7
let retryConfig = newMessage(0xC00, TASK_ME, TASK_API, MeConfigReqPayloadSize)
meConfigReqView(retryConfig).psOn = 1
meConfigReqView(retryConfig).defKey = 123
ke_msg_send(retryConfig)
failAt = kernelAllocations + 1
doAssert stepControl() == KeMsgSaved
doAssert controlReplies.len == 0 and meState == MeIdleState
doAssert me.psOn == 5 and me.defKey == 0 and me.htSupp == 7,
  $(me.psOn, me.defKey, me.htSupp)
failAt = 0
discard ke_reschedule_saved_messages(TASK_ME)
drainControl()
doAssert controlReplies.len == 1 and controlReplies[0].id == ME_CONFIG_CFM
doAssert not configCfmSawCommand
doAssert configCfmSawOriginalRequest
doAssert allocated.len == 0

# A synchronous confirmation callback can submit a second request before the
# first request is forwarded or ME state becomes busy.
resetControl()
me.psOn = 5
let firstConfig = newMessage(ME_CONFIG_REQ, TASK_ME, TASK_API, MeConfigReqPayloadSize)
meConfigReqView(firstConfig).psOn = 1
meConfigReqView(firstConfig).defKey = 123
let nestedConfig = newMessage(ME_CONFIG_REQ, TASK_ME, TASK_API, MeConfigReqPayloadSize)
meConfigReqView(nestedConfig).defKey = 999
configCfmHook = proc() =
  doAssert me_config_req_handler(nestedConfig) == KeMsgSaved
  doAssert me.defKey == 0 and me.psOn == 5
ke_msg_send(firstConfig)
doAssert stepControl() == KeMsgNoFree
doAssert configCfmSawOriginalRequest and not configCfmSawCommand
doAssert configCfmSeenFields == (0'u8, 5'u8, 0'u8, 0'u8, 0'u16)
doAssert configCfmSeenRequester == 0
doAssert me.defKey == 123 and me.psOn == 1
configCfmHook = nil
ke_msg_free(keMsgHdrFromPayload(nestedConfig))
drainControl()
doAssert controlReplies.len == 1 and allocated.len == 0

resetControl()
me.psOn = 5
let noPsConfig = newMessage(ME_CONFIG_REQ, TASK_ME, TASK_API, MeConfigReqPayloadSize)
meConfigReqView(noPsConfig).defKey = 77
let nestedNoPs = newMessage(ME_CONFIG_REQ, TASK_ME, TASK_API, MeConfigReqPayloadSize)
meConfigReqView(nestedNoPs).defKey = 88
configCfmHook = proc() =
  doAssert me_config_req_handler(nestedNoPs) == KeMsgSaved
  doAssert me.defKey == 0 and meConfigInProgress
ke_msg_send(noPsConfig)
doAssert stepControl() == KeMsgConsumed
doAssert me.defKey == 77 and not meConfigInProgress
doAssert configCfmSeenFields == (0'u8, 5'u8, 0'u8, 0'u8, 0'u16)
doAssert configCfmSeenRequester == 0
configCfmHook = nil
ke_msg_free(keMsgHdrFromPayload(nestedNoPs))
doAssert controlReplies.len == 1 and allocated.len == 0

for nss in 0'u8 .. 8:
  for capability in [0'u16, 1, 2, 3, 0xFFFF]:
    resetControl()
    phyNss = nss
    let request = newMessage(0xC00, TASK_ME, TASK_API, MeConfigReqPayloadSize)
    let config = meConfigReqView(request)
    config.htSupp = 1
    config.psOn = 0
    config.htCaps[0] = (capability and 255).uint8
    config.htCaps[1] = (capability shr 8).uint8
    ke_msg_send(request)
    doAssert stepControl() == KeMsgConsumed
    doAssert configCfmSeenFields.htSupp == 1
    doAssert configCfmSeenCapInfo == capability
    doAssert configCfmSeenFields.nss == 0 and configCfmSeenFields.htCapByte == 0
    doAssert me.nss == ((nss.uint16 + 1) shr 1).uint8
    doAssert me.htCapByte == ((capability shr 1) and 1).uint8
    doAssert allocated.len == 0

# Dynamic PS completion uses the incoming request's source, not stale ps_env.
resetControl()
ps.mode = TASK_APM
let dynamic = newMessage(MM_SET_PS_MODE_REQ, TASK_MM, TASK_API, 1)
cast[ptr uint8](dynamic)[] = 3
doAssert mm_set_ps_mode_req_handler(dynamic) == KeMsgConsumed
doAssert controlReplies.len == 1 and controlReplies[0].id == MM_SET_PS_MODE_CFM
doAssert controlReplies[0].dst == TASK_API
ke_msg_free(keMsgHdrFromPayload(dynamic))
doAssert allocated.len == 0
"""


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_me_control_transitions(tmp_path: Path, build: str) -> None:
    run_program(tmp_path, build, DRIVER + MATRIX)


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_ps_mode_waits_for_connectionless_pm_restore(tmp_path: Path, build: str) -> None:
    run_program(tmp_path, build, DRIVER + r'''
for mode in 0'u8 .. 3'u8:
  resetControl()
  mmState = 1
  ps.statusFlags = 6 # Active scan/ROC and an unrelated status bit.
  let command = newMessage(MM_SET_PS_MODE_REQ, TASK_MM, TASK_API, 1)
  mmSetPsModeReqView(command).mode = mode
  ke_msg_send(command)
  doAssert stepControl() == KeMsgSaved
  doAssert keMsgQueueSaved.first == keMsgHdrFromPayload(command)
  doAssert mmPsModeRequest == nil and psModes.len == 0 and controlReplies.len == 0

  # Scan/ROC END restores PM; its forced-idle and active/host-idle state
  # transitions requeue work. It still cannot run in the forced-idle state.
  ps.statusFlags = 4
  ke_state_set(TASK_MM, HW_ACTIVE)
  doAssert stepControl() == KeMsgSaved
  ke_state_set(TASK_MM, (if mode == 0: MM_IDLE.uint16 else: 1'u16))
  drainControl()
  doAssert psModes == (if mode == 3: @[] else: @[mode])
  doAssert controlReplies.len == 1 and controlReplies[0].id == MM_SET_PS_MODE_CFM
  doAssert allocated.len == 0 and ps.statusFlags == 4
''')


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_me_control_reset_ownership(tmp_path: Path, build: str) -> None:
    run_program(tmp_path, build, DRIVER + RESET)


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_me_config_ps_handshake(tmp_path: Path, build: str) -> None:
    run_program(tmp_path, build, DRIVER + CONFIG)
