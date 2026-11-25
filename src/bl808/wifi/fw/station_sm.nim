# TASK_SM's state and the teardown that is state 10.
#
# smGo is the only writer of TASK_SM's state. Each state it writes starts a
# new SM operation (op.nim), so a stamp handed out before it is stale.
#
# A connection attempt lives from its admission (sm.connectInfo set) until
# sm_connect_ind; a connected link lives until sm_disconnect_process. Every
# end of either goes through smTeardown, after smDeauthWait when a
# deauthentication is sent first. They are the only ways into state 10, which
# has two phases:
#
#   tdDeauthWait  sm_handle_connection or sm_handle_supplicant_result queued a
#                 deauthentication frame that carries the current stamp as its
#                 confirmation argument. The frame's callback, with any status
#                 (sent, not acknowledged, flushed by a TX reset or aged out),
#                 ends the wait. So does a guard timer, in case the frame is
#                 postponed on a channel that never comes back.
#   tdCleanup     station_cleanup.nim releases the link through ME and MM and
#                 ends with smGo(SmIdleState).
#
# Nothing else leaves state 10: connect and disconnect requests, connection
# losses and AP deauthentications are saved until SM is idle again.
#
# States 1, 2 and 3 wait for the answer to one request: SCANU_START_REQ or
# SCANU_JOIN_REQ to SCANU, MM_STA_ADD_REQ to MM. smSend sends it after smGo
# and keeps its pointer. The replier answers it in place, turning the
# request into its own confirmation, so the answer needs no allocation and
# always comes; it is the message SM holds (smTakeAnswer). A replier drops a
# request SM no longer holds, or answers it with a failure; SM ignores an
# answer it does not hold, except that a station such an answer registered
# is deleted. SM's senders allocate the full payload, which the repliers'
# length checks rely on. The message stays allocated from smSend until its
# answer is handled, so the pointer cannot name another message meanwhile.
#
# States 6 and 8 wait for the AP's auth or assoc response. The request's
# sender arms SM_RSP_TIMEOUT_IND with the stamp of the operation it started
# (smArmResponse), and the expected auth response carries the same stamp
# (station_tx_build.nim). Leaving the state starts a new operation, so a
# deadline or response from an earlier one is stale; nothing else (a TX
# reset, a channel switch) invalidates them.

type
  SmTeardown = enum
    tdNone, tdDeauthWait, tdCleanup

  SmOwner = object
    op: Op
    teardown: SmTeardown
    request: pointer  ## the request the live operation waits on, or nil
    deauthVif: uint8
    deauthCallback: pointer  ## the waited frame's callback, run by the guard
    guard: MmTimerView

const SmDeauthGuardUs = 3_000_000'u32
  ## Longer than any off-channel period (a full passive scan is about 1.5 s),
  ## shorter than the host's 10 s disconnect wait.

var smOwn {.wifiCtrl.}: SmOwner

proc smGo(state: uint16; teardown = tdNone): uint32 {.discardable.} =
  ## The only ke_state_set for TASK_SM. Returns the new operation's stamp.
  if smOwn.teardown == tdDeauthWait: mm_timer_clear(addr smOwn.guard)
  smOwn.teardown = teardown
  smOwn.request = nil
  result = opGo(smOwn.op)
  ke_state_set(TASK_SM, state)

proc smSend(request: pointer) =
  ## Send the live operation's request; its answer ends the wait.
  smOwn.request = request
  ke_msg_send(request)

proc smAwaits(request: pointer): bool =
  ## `request` is the one the live operation waits on (a replier's check).
  request != nil and request == smOwn.request

proc smTakeAnswer(answer: pointer): bool =
  ## `answer` answers the live operation's request: the wait ends here, and
  ## the caller takes the next transition. The state is still the one the
  ## request was sent in, since every smGo forgets the request.
  if not smAwaits(answer): return false
  smOwn.request = nil
  true

proc smArmResponse(stamp: uint32; delayUs: uint64): bool =
  ## Arm the auth/assoc response deadline of operation `stamp`, which must be
  ## the live one. A longer wait (an association comeback) is cut to the
  ## longest kernel timer, about 300 s.
  if not opCurrent(smOwn.op, stamp): return false
  ke_timer_try_set(SM_RSP_TIMEOUT_IND, TASK_SM,
                   min(delayUs, KE_TIMER_MAX_DELAY.uint64).uint32, stamp = stamp)

proc smResponseExpiry(param: pointer): uint32 =
  ## The stamp of SM_RSP_TIMEOUT_IND `param` if it ends the live operation's
  ## response wait, else 0.
  if param == nil or keMsgHdrFromPayload(param).paramLen != 4: return 0
  let stamp = cast[ptr uint32](param)[]
  if opCurrent(smOwn.op, stamp): stamp else: 0

proc smDeauthConfirmed(env: pointer): bool =
  ## `env`, a frame's confirmation argument, belongs to the live deauth wait.
  smOwn.teardown == tdDeauthWait and opCurrent(smOwn.op, opEnvStamp(env))

proc smDeauthVif(): pointer =
  cast[pointer](vifChannelForIdx(smOwn.deauthVif))

proc smTeardownUnclaimed() =
  ## No STA VIF was left to clean up (its slot now holds another interface
  ## type). End the attempt here, unreported, rather than stay in state 10.
  let sm = smEnvView()
  let connection = sm.connectInfo
  let indication = sm.connectIndMsg
  sm.connectInfo = nil
  sm.connectIndMsg = nil
  smActivationCancelConnection(connection)
  smBssCancel()
  smDeferredCancel()
  smGo(SmIdleState)
  if connection != nil: ke_msg_free(keMsgHdrFromPayload(connection))
  if indication != nil: ke_msg_free(keMsgHdrFromPayload(indication))

proc smTeardown(vif: pointer; indication: pointer = nil; disconnected = false;
                status = 0'u16; reason = 0'u16): bool {.discardable.} =
  ## End the attempt or link on `vif`, after its deauthentication wait if it
  ## had one. The cleanup claims the link and SM's messages before it publishes
  ## state 10. `indication` is the attempt's SM_CONNECT_IND, sent when the
  ## cleanup completes; `disconnected` asks for SM_DISCONNECT_IND instead.
  if smOwn.teardown == tdCleanup: return false
  smSaQueryEnd()
  if smCleanupBegin(vif, indication, disconnected, status, reason): return true
  # State 10 must not stay without an owner, nor may an attempt that is
  # ending on its own VIF (`indication` is its SM_CONNECT_IND) stay live.
  if smOwn.teardown == tdDeauthWait or indication != nil:
    smTeardownUnclaimed()
  false

proc smDeauthGuardExpired(env: pointer) {.cdecl.} =
  ## No confirmation came: complete the wait as a flushed frame would.
  if not smDeauthConfirmed(env): return
  cast[proc(env: pointer; status: uint32) {.cdecl.}](smOwn.deauthCallback)(
    env, 0x40000000'u32)

proc smDeauthWait(vifIdx: uint8; callback: pointer): uint32 =
  ## Enter state 10 to wait for the deauthentication frame the caller pushes
  ## next, with `callback` and the returned stamp as its confirmation argument.
  ## Refused (0) while a teardown is running: the caller drops its frame.
  if smOwn.teardown != tdNone: return 0
  smSaQueryEnd()
  smOwn.deauthVif = vifIdx
  smOwn.deauthCallback = callback
  result = smGo(SmDisconnectingState, tdDeauthWait)
  smOwn.guard.callback = cast[pointer](smDeauthGuardExpired)
  smOwn.guard.env = result
  mm_timer_set(addr smOwn.guard, macTimeNow() + SmDeauthGuardUs)
