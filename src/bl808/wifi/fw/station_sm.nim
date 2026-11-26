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
#                 postponed on a channel that never comes back: after 3 s,
#                 or while the VIF is still away from its channel after 9 s.
#   tdCleanup     station_cleanup.nim releases the link through ME and MM, one
#                 request at a time like the series of states 4 and 9 below,
#                 and ends with smGo(SmIdleState). The guard timer then
#                 retries a step whose messages could not be allocated.
#
# Otherwise only sm_init and the removal of the VIF (smAbandon) leave state
# 10: connect and disconnect requests, connection losses and AP
# deauthentications are saved until SM is idle again.
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
# States 4 and 9 send a series of requests to MM and ME, one at a time
# (station_bss.nim, station_activation.nim). Their repliers answer with an
# empty confirmation, allocated by ke_msg_alloc_reply: smSendReserved
# allocates that reply before it sends the request and ke_msg_alloc_reply
# hands it out (smTakeReply), so again the answer needs no allocation at the
# replier and always comes. ME's forward of a request to MM carries the same
# reply: ME takes it when it accepts the request, MM's confirmation to ME
# and ME's to SM are that message relabelled. From the hand-out SM waits for
# the reply, which stays allocated until SM handles it; the replier frees
# the request. Every smGo frees a reply not handed out yet. A replier drops
# a request of SM's that SM no longer waits on (smStaleRequest).
#
# States 5 and 7 wait for the attempt's channel (deferred_auth.nim). The
# auth or assoc request is parked in chan_env (smPark); the channel
# scheduler sends it to TASK_SM when the VIF's context becomes active, and SM
# takes it as the answer. Every smGo frees a request still parked.
#
# States 6 and 8 wait for the AP's auth or assoc response. The request's
# sender arms SM_RSP_TIMEOUT_IND with the stamp of the operation it started
# (smArmResponse), and the expected auth response carries the same stamp
# (station_tx_build.nim). Leaving the state starts a new operation, so a
# deadline or response from an earlier one is stale; nothing else (a TX
# reset, a channel switch) invalidates them.
#
# A STA VIF is removed only by vif_mgmt_unregister, which then calls
# smStaVifRetired. An attempt on that VIF, or the teardown of a link on it,
# ends there at once and unreported (smAbandon). So while SM waits on
# anything, the VIF it waits for is the one it started with, and no replier
# or handler needs to check that the VIF is still there.

type
  SmTeardown = enum
    tdNone, tdDeauthWait, tdCleanup

  SmOwner = object
    op: Op
    teardown: SmTeardown
    request: pointer  ## the request the live operation waits on, or nil
    reply: pointer    ## the reply SM reserved for it, until a replier takes it
    answer: pointer   ## what ends the wait: the request itself or its reply
    vif: uint8        ## state 10: the VIF whose link the teardown ends
    deauthCallback: pointer  ## the waited frame's callback, run by the guard
    deauthSince: uint32      ## MAC time the deauthentication wait started
    guard: MmTimerView  ## state 10's timer: the deauth guard, the cleanup's retry

const
  SmDeauthGuardUs = 3_000_000'u32
    ## Longer than a usual off-channel period (a full passive scan is about
    ## 1.5 s), shorter than the host's 10 s disconnect wait.
  SmDeauthGuardLimitUs = 9_000_000'u32
    ## The longest wait while the VIF is away from its channel, where its
    ## frame is postponed and goes out when the channel comes back.

var smOwn {.wifiCtrl.}: SmOwner

proc smGo(state: uint16; teardown = tdNone): uint32 {.discardable.} =
  ## The only ke_state_set for TASK_SM. Returns the new operation's stamp.
  if smOwn.teardown != tdNone: mm_timer_clear(addr smOwn.guard)
  let reserved = smOwn.reply
  smOwn.teardown = teardown
  smOwn.request = nil
  smOwn.reply = nil
  smOwn.answer = nil
  result = opGo(smOwn.op)
  ke_state_set(TASK_SM, state)
  if reserved != nil: ke_msg_free(keMsgHdrFromPayload(reserved))
  smDeferredCancel()

proc smSend(request: pointer) =
  ## Send the live operation's request; its answer, in place, ends the wait.
  smOwn.request = request
  smOwn.answer = request
  ke_msg_send(request)

proc smPark(request: pointer) =
  ## Park the live operation's deferred auth/assoc request in chan_env. The
  ## channel scheduler sends it back to TASK_SM, which ends the wait.
  smOwn.request = request
  smOwn.answer = request
  chan_ctxt_set_auth_assoc_req(request)

proc smSendReserved(request: pointer): bool =
  ## Send the live operation's request with the reply its replier answers
  ## with (smTakeReply). Without memory for the reply the request is freed
  ## unsent: false.
  let header = keMsgHdrFromPayload(request)
  let reply = ke_msg_try_alloc(header.id + 1, TASK_SM, header.destId, 0)
  if reply == nil:
    ke_msg_free(header)
    return false
  smOwn.request = request
  smOwn.reply = reply
  smOwn.answer = reply
  ke_msg_send(request)
  true

proc smAwaits(request: pointer): bool =
  ## `request` is the one the live operation waits on (a replier's check).
  request != nil and request == smOwn.request

proc smStaleRequest(request: pointer): bool =
  ## The entry check of the repliers of states 4, 9 and 10: true when
  ## `request` is one SM sent and no longer waits on. The replier drops it
  ## without applying it.
  keMsgHdrFromPayload(request).srcId == TASK_SM and not smAwaits(request)

proc smTakeReply(request: pointer; id: uint16): pointer =
  ## ke_msg_alloc_reply for the request SM waits on: the reply reserved for
  ## it, as confirmation `id` back to the sender. The request is answered
  ## (its replier frees it); SM now waits for the reply.
  result = smOwn.reply
  if result == nil: return
  smOwn.reply = nil
  smOwn.request = nil
  let header = keMsgHdrFromPayload(result)
  let requestHeader = keMsgHdrFromPayload(request)
  header.id = id
  header.destId = requestHeader.srcId
  header.srcId = requestHeader.destId
  header.paramLen = 0

proc smTakeAnswer(answer: pointer): bool =
  ## `answer` answers the live operation's request: the wait ends here, and
  ## the caller takes the next transition. The state is still the one the
  ## request was sent in, since every smGo forgets the request.
  if answer == nil or answer != smOwn.answer: return false
  smOwn.request = nil
  smOwn.answer = nil
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
  cast[pointer](vifChannelForIdx(smOwn.vif))

proc smAbandon() =
  ## End the attempt, and a teardown in progress, here and unreported: free
  ## the messages SM holds and go idle. For sm_init, for the removal of the
  ## VIF SM works on (smStaVifRetired), and for a teardown that finds no STA
  ## VIF to clean up.
  let sm = smEnvView()
  let connection = sm.connectInfo
  let indication = sm.connectIndMsg
  sm.connectInfo = nil
  sm.connectIndMsg = nil
  smActivationCancel()
  smBssCancel()
  smCleanupCancel()
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
  # No STA VIF to clean up: an FT attempt admitted on another interface
  # type. State 10 must not stay without an owner, nor may an attempt that
  # is ending on its own VIF (`indication` is its SM_CONNECT_IND) stay live.
  if smOwn.teardown == tdDeauthWait or indication != nil:
    smAbandon()
  false

proc smDeauthPostponed(): bool =
  ## The teardown's VIF is away from its channel: its frames are postponed
  ## and go out when the channel comes back (txl_cntrl_tx_check).
  let vif = smDeauthVif()
  vifChannelAt(vif).chanCtxt != nil and not txl_cntrl_tx_check(vif)

proc smDeauthGuardExpired(env: pointer) {.cdecl.} =
  ## No confirmation came: complete the wait as a flushed frame would. While
  ## the frame can still go out when the VIF's channel returns, wait longer,
  ## up to SmDeauthGuardLimitUs; the blob waits without bound.
  if not smDeauthConfirmed(env): return
  let now = macTimeNow()
  let elapsed = now - smOwn.deauthSince
  if smDeauthPostponed() and elapsed < SmDeauthGuardLimitUs:
    # The limit is measured from the start of the wait, so a late expiry
    # cannot shorten it.
    mm_timer_set(addr smOwn.guard,
                 now + min(SmDeauthGuardUs, SmDeauthGuardLimitUs - elapsed))
    return
  cast[proc(env: pointer; status: uint32) {.cdecl.}](smOwn.deauthCallback)(
    env, 0x40000000'u32)

proc smDeauthWait(vifIdx: uint8; callback: pointer): uint32 =
  ## Enter state 10 to wait for the deauthentication frame the caller pushes
  ## next, with `callback` and the returned stamp as its confirmation argument.
  ## Refused (0) while a teardown is running: the caller drops its frame.
  if smOwn.teardown != tdNone: return 0
  smSaQueryEnd()
  smOwn.vif = vifIdx
  smOwn.deauthCallback = callback
  result = smGo(SmDisconnectingState, tdDeauthWait)
  smOwn.guard.callback = cast[pointer](smDeauthGuardExpired)
  smOwn.guard.env = result
  smOwn.deauthSince = macTimeNow()
  mm_timer_set(addr smOwn.guard, smOwn.deauthSince + SmDeauthGuardUs)

proc smStaVifRetired(vifIdx: uint8) =
  ## vif_mgmt_unregister has retired STA VIF `vifIdx`. The attempt on it, or
  ## the teardown of a link on it, ends here, unreported: nothing is left to
  ## release, and the host drops an indication for a removed VIF
  ## (rxHostClaimStationIndication). Pinned sm.o is not told and goes on with
  ## the freed slot.
  let connection = smEnvView().connectInfo
  if (connection != nil and connectInfoView(connection).vifIdx == vifIdx) or
      (smOwn.teardown != tdNone and smOwn.vif == vifIdx):
    smAbandon()
