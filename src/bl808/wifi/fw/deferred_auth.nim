# SM's deferred authentication or association request (states 5 and 7).
#
# sm_auth_assoc_send_according_chan sends the auth or assoc frame at once
# when the attempt's channel is the only one or the dominant one, or has 0
# or 41..199 ms left. Otherwise smDeferredPark enters state 5 or 7 and parks
# SM_CONNECT_AUTH_ASSOC_REQ, with the frame's parameters, in chan_env as the
# operation's request (smPark). When the VIF's channel context becomes active
# the channel scheduler sends it to TASK_SM (smDeferredPublish), and SM takes
# it like an answer and sends the frame (smDeferredDispatch). Every smGo frees
# a request still parked (smDeferredCancel); one already sent is ignored when
# it arrives. An abort in state 5 or 7 ends the attempt.

proc smDeferredCancel() =
  ## Free the parked request, if any (every smGo).
  let env = chanEnvView()
  let parked = env.deferredMsg
  if parked == nil: return
  env.deferredMsg = nil
  ke_msg_free(keMsgHdrFromPayload(parked))

proc smDeferredPark(state, sequence: uint16; challenge: pointer) =
  ## Enter `state` (5 or 7) until the attempt's channel is active, with the
  ## frame's parameters parked; or end the attempt without memory for them.
  ## The message carries its own copy of a shared-key challenge.
  let length = if challenge == nil: SmConnectAuthAssocReqPayloadSize
               else: SmConnectAuthAssocChallengePayloadSize
  let request = ke_msg_try_alloc(SM_CONNECT_AUTH_ASSOC_REQ_MSG, TASK_SM, 0xFF, length)
  if request == nil:
    sm_connect_ind(WLAN_FW_AUTH_OR_ASSOC_RESPONSE_TIMEOUT_FAILURE, 0xFFFF)
    return
  let payload = cast[ptr SmConnectAuthAssocReqPayload](request)
  payload[] = SmConnectAuthAssocReqPayload(nextState: state, authSequence: sequence)
  if challenge != nil:
    let extended = cast[ptr SmConnectAuthAssocChallengePayload](request)
    copyMem(addr extended.challenge[0], challenge, extended.challenge.len)
    payload.challengeAddress = pointerAddrU32(addr extended.challenge[0])
  smGo(state)
  smPark(request)

proc smDeferredPublish(vifEntry: pointer) =
  ## The context of STA VIF `vifEntry` is active (chan_pre_switch_channel):
  ## send SM the request parked for it, as pinned chan.o does at +0x1de.
  let env = chanEnvView()
  let request = env.deferredMsg
  let connection = smEnvView().connectInfo
  if request == nil or connection == nil or
      cast[pointer](vifChannelForIdx(connectInfoView(connection).vifIdx)) != vifEntry:
    return
  env.deferredMsg = nil
  ke_msg_send(request)

proc smDeferredDispatch(payload: pointer): cint =
  ## The parked request is back: send its frame. One SM no longer waits on
  ## changes nothing. The attempt ends if its STA VIF has gone meanwhile:
  ## the frame builders would return without sending.
  if not smTakeAnswer(payload): return KeMsgConsumed
  let request = cast[ptr SmConnectAuthAssocReqPayload](payload)
  let connection = smEnvView().connectInfo
  if connection == nil or not smAttemptStaVif(connectInfoView(connection).vifIdx):
    sm_connect_ind(WLAN_FW_AUTH_OR_ASSOC_RESPONSE_TIMEOUT_FAILURE, 0xFFFF)
  elif request.nextState == SmAuthStartingState:
    let challenge =
      if keMsgHdrFromPayload(payload).paramLen == SmConnectAuthAssocChallengePayloadSize:
        cast[pointer](addr cast[ptr SmConnectAuthAssocChallengePayload](payload).challenge[0])
      else: nil
    sm_auth_send(request.authSequence, challenge)
  else:
    sm_assoc_req_send()
  KeMsgConsumed
