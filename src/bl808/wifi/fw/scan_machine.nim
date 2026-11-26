# TASK_SCAN, the lower scan, and TASK_SCANU, the upper scan and join.
#
# TASK_SCAN runs one SCAN_START_REQ at a time, one channel (a dwell) after
# another:
#
#   0  idle     scan_env.paramPtr is nil.
#   2  pending  the dwell on scan_env.channelIndex is asked of the channel
#               scheduler (slot 3) and waits for MM_SCAN_CHANNEL_START_IND.
#   3  running  the radio is on the dwell's channel; it waits for
#               MM_SCAN_CHANNEL_END_IND.
#
# scanGo is the only ke_state_set(TASK_SCAN). Entering state 2 starts a new
# operation (op.nim); state 3 is the same dwell on its channel. The dwell's
# START and END notices, its probe repeat timer and an END_EARLY request
# carry its stamp, and a handler takes one only while that dwell is live and
# in the state it expects (scanCurrent). Anything older is dropped.
#
# A request is admitted in scan_start_req_handler and scanRelease is its only
# end: it answers the request in place, once, and goes idle. So the state is
# not 0 exactly while paramPtr is set, and a request is answered exactly once:
# with SCAN_DONE_IND when its scan ran, with a failing SCAN_START_CFM when it
# was refused or could not start a dwell. The answer is the request itself,
# so it needs no allocation and cannot be lost.
#
# Each dwell holds its two notices from the moment it is asked for
# (scanDwellBegin): the channel scheduler posts START when slot 3 becomes
# current (chan_pre_switch_channel) and END when it retires the slot
# (chanCtxtOpEvent), START first if it is still held (scanDwellPost). It
# needs no allocation for them, and each is posted at most once. The
# scheduler never abandons the slot: a switch to it that is abandoned puts
# the dwell back to the connectionless gate (chanConnlessRequeue), and the
# slot leaves the pool only through chanCtxtOpEvent, which posts END, or
# chan_init. So a dwell in state 2 always gets START, and one in state 3 END.
# SCAN_ABORT_REQ and SCAN_CANCEL_REQ set the stop flag (abortFlag); an abort
# in state 3 leaves the channel at once (scan_terminate_channel_request), and
# a dwell that starts with the flag set leaves it at once too. A dwell is
# asked to leave only while it still holds its END (scanOnChannel), so at
# most once.
#
# TASK_SCANU runs one SCANU_START_REQ or SCANU_JOIN_REQ at a time. Its state
# tables save new requests while it is busy, so a request is admitted only in
# state 0. scanuGo is the only ke_state_set(TASK_SCANU), once per request: 1
# (scanning) or 2 (joining) at admission, 0 at the end; each starts a new
# operation, whose stamp the frame handler and the result snapshots compare.
# scanuComplete is the only end of a request (scanu_confirm and the cached
# join replay): it answers the requester once and goes idle.
#
# SCANU has at most one SCAN_START_REQ outstanding (scanuOwn.lower). TASK_SCAN
# answers it in place, as SCAN_DONE_IND or as a failing SCAN_START_CFM, so
# SCANU takes exactly the message it holds (scanuTakeLower); the message stays
# allocated until SCANU handles it, so the pointer cannot name another one
# meanwhile. TASK_SCAN drops a request SCANU no longer holds (after a reset).

type
  ScanOwner = object
    op: Op
    start, finish: pointer  ## the live dwell's notices the scheduler has not posted

  ScanuOwner = object
    op: Op
    lower: pointer  ## the SCAN_START_REQ SCANU waits on, until it is answered

var
  scanOwn {.wifiCtrl.}: ScanOwner
  scanuOwn {.wifiCtrl.}: ScanuOwner

const ScanStampSize = sizeof(uint32).uint32

template stampOf(message: pointer): var uint32 = cast[ptr uint32](message)[]

# --------------------------------------------------------------------------
# TASK_SCAN
# --------------------------------------------------------------------------

proc scanDropNotices() =
  for notice in [scanOwn.start, scanOwn.finish]:
    if notice != nil: ke_msg_free(keMsgHdrFromPayload(notice))
  scanOwn.start = nil
  scanOwn.finish = nil

proc scanGo(state: uint16): uint32 {.discardable.} =
  ## The only ke_state_set for TASK_SCAN. State 2 starts a new dwell, 3 is
  ## that dwell on its channel, 0 ends it. Leaving a dwell frees the notices
  ## it still holds. Returns the live stamp.
  if state != ScanChannelRunningState:
    scanDropNotices()
    if state == ScanIdleState: opFinish(scanOwn.op)
    else: discard opGo(scanOwn.op)
  ke_state_set(TASK_SCAN, state)
  scanOwn.op.serial

proc scanCurrent(message: pointer; state: uint16): bool =
  ## `message` (a notice, the probe repeat expiry or END_EARLY) carries the
  ## stamp of the live dwell, which is in `state`.
  message != nil and keMsgHdrFromPayload(message).paramLen == ScanStampSize and
    opCurrent(scanOwn.op, stampOf(message)) and ke_state_get(TASK_SCAN) == state

proc scanDwellBegin(): bool =
  ## Start the dwell on scan_env.channelIndex: enter state 2 holding its two
  ## notices. The caller then asks the channel scheduler for slot 3
  ## (scan_set_channel_request). False, with nothing changed, when slot 3 is
  ## taken, the channel is out of range or the notices cannot be allocated.
  let request = scan_env.paramPtr
  if request == nil or chanScanPoolOverlay().slot != 0xFF or
      scan_env.channelIndex >= scanStartReqView(request).channelCount:
    return false
  let start = ke_msg_try_alloc(MM_SCAN_CHANNEL_START_IND, TASK_SCAN, TASK_NONE, ScanStampSize)
  let finish = ke_msg_try_alloc(MM_SCAN_CHANNEL_END_IND, TASK_SCAN, TASK_NONE, ScanStampSize)
  if start == nil or finish == nil:
    for notice in [start, finish]:
      if notice != nil: ke_msg_free(keMsgHdrFromPayload(notice))
    return false
  let stamp = scanGo(ScanChannelPendingState)
  stampOf(start) = stamp
  stampOf(finish) = stamp
  scanOwn.start = start
  scanOwn.finish = finish
  true

proc scanDwellPost(id: uint16) =
  ## The channel scheduler reached slot 3 (MM_SCAN_CHANNEL_START_IND) or
  ## retired it (MM_SCAN_CHANNEL_END_IND): post the dwell's notice, START
  ## first if END comes before it was posted.
  if id == MM_SCAN_CHANNEL_END_IND and scanOwn.start != nil:
    scanDwellPost(MM_SCAN_CHANNEL_START_IND)
  let notice =
    if id == MM_SCAN_CHANNEL_START_IND: scanOwn.start else: scanOwn.finish
  if notice == nil: return
  if id == MM_SCAN_CHANNEL_START_IND: scanOwn.start = nil
  else: scanOwn.finish = nil
  when defined(bl808WifiDiagWarmScan):
    if id == MM_SCAN_CHANNEL_START_IND: inc nimFwDbgWarmScan.start_posted
    else: inc nimFwDbgWarmScan.end_posted
  ke_msg_send(notice)

proc scanAnswer(request: pointer; id: uint16; destination, status: uint8) =
  ## Answer `request` in place: it becomes SCAN_START_CFM (with `status`) or
  ## SCAN_DONE_IND to `destination`.
  let header = keMsgHdrFromPayload(request)
  if id == SCAN_START_CFM:
    statusCfmView(request).status = status
    header.paramLen = StatusCfmPayloadSize
  else:
    header.paramLen = 0
  when defined(bl808WifiDiagWarmScan):
    if id == SCAN_START_CFM:
      inc nimFwDbgWarmScan.lower_replies
      nimFwDbgWarmScanLowerStatus = status.uint32
  ke_msg_forward_and_change_id(request, id, destination, TASK_SCAN)

proc scanRelease(failed = false) =
  ## The only end of an admitted request: answer it in place and go idle.
  ## A request that could not start its next dwell (`failed`) is answered
  ## with SCAN_START_CFM(FAIL), which ends SCANU's request with an error
  ## rather than as a fully scanned band.
  let request = scan_env.paramPtr
  if request == nil: return
  scan_env.paramPtr = nil
  scan_env.abortFlag = 0
  if failed: scanAnswer(request, SCAN_START_CFM, scan_env.requester, SCAN_STATUS_FAIL)
  else: scanAnswer(request, SCAN_DONE_IND, scan_env.requester, 0)
  scanGo(ScanIdleState)

proc scanOnChannel(): bool =
  ## The live dwell is still on its channel: the scheduler has not retired
  ## slot 3 (it posts END when it does). Only then may the dwell be asked to
  ## leave; afterwards the scheduler's timer belongs to another context.
  scanOwn.finish != nil

proc scanStopAfterDwell() =
  ## SCANU found what it scans for (flag 0x40): the lower scan of its own
  ## request stops after the dwell on its channel; a dwell still waiting for
  ## slot 3 leaves the channel as soon as it reaches it.
  if scan_env.paramPtr != nil and scan_env.paramPtr == scanuOwn.lower:
    scan_env.abortFlag = 1

proc scanEarlyEndRequest() =
  ## Quick connect (flag 0x100): ask TASK_SCAN to leave the channel of the
  ## dwell running now. Nothing is sent while no dwell is on its channel.
  if ke_state_get(TASK_SCAN) != ScanChannelRunningState or
      scan_env.paramPtr != scanuOwn.lower:
    return
  let message = ke_msg_try_alloc(MM_SCAN_CHANNEL_END_EARLY, TASK_SCAN, TASK_SCANU,
                                 ScanStampSize)
  if message == nil: return
  stampOf(message) = scanOwn.op.serial
  ke_msg_send(message)

# --------------------------------------------------------------------------
# TASK_SCANU
# --------------------------------------------------------------------------

proc scanuGo(state: uint16): uint32 {.discardable.} =
  ## The only ke_state_set for TASK_SCANU: 1 or 2 when a request is admitted,
  ## 0 when it ends. Each starts a new operation; returns its stamp.
  scanuOwn.lower = nil
  result = opGo(scanuOwn.op)
  ke_state_set(TASK_SCANU, state)

proc scanuRequestCurrent(request: pointer; stamp: uint32): bool {.inline.} =
  ## `request` is SCANU's live request, admitted under operation `stamp`.
  request != nil and scanu_env.paramPtr == request and opCurrent(scanuOwn.op, stamp)

proc scanuAwaits(lower: pointer): bool =
  ## `lower` is the SCAN_START_REQ SCANU waits on (TASK_SCAN's entry check).
  lower != nil and lower == scanuOwn.lower

proc scanuSendLower(lower: pointer) =
  ## Send the request's next SCAN_START_REQ; TASK_SCAN answers it in place.
  scanuOwn.lower = lower
  ke_msg_send(lower)

proc scanuTakeLower(answer: pointer): bool =
  ## `answer` (SCAN_DONE_IND or a failing SCAN_START_CFM) is TASK_SCAN's
  ## answer to the request SCANU waits on: the wait ends here.
  if not scanuAwaits(answer): return false
  scanuOwn.lower = nil
  true

proc scanuAnswer(request: pointer; id: uint16; destination, status: uint8) =
  ## Answer `request` in place: it becomes its own confirmation. This needs
  ## no allocation, so it cannot fail.
  statusCfmView(request).status = status
  keMsgHdrFromPayload(request).paramLen = StatusCfmPayloadSize
  ke_msg_forward_and_change_id(request, id, destination, TASK_SCANU)

proc scanuReply(id: uint16; destination: uint8): pointer =
  ## A separate confirmation, as the blob allocates one. SM's requests, and
  ## any whose allocation fails, are answered in place instead (nil).
  if destination == TASK_SM: nil
  else: ke_msg_try_alloc(id, destination, TASK_SCANU, StatusCfmPayloadSize)

proc scanuPublishCompletion(request, reply: pointer; id: uint16;
                            destination, status: uint8) =
  if reply == nil:
    scanuAnswer(request, id, destination, status)
  else:
    statusCfmView(reply).status = status
    ke_msg_free(keMsgHdrFromPayload(request))
    ke_msg_send(reply)

proc scanuComplete(status: uint8; replayed = false) =
  ## The only end of a SCANU request: answer the requester once and go idle.
  ## scanu_confirm in join mode also tells TASK_API. The cached join replay
  ## (`replayed`, pinned scan_done_ind_handler) sends only the requester's
  ## SCANU_JOIN_CFM and clears the cached results.
  let request = scanu_env.paramPtr
  if request == nil: return
  let source = scanu_env.requester
  # SM's answer has the type of its request; SM does not read the filter.
  let joining =
    if source == TASK_SM: keMsgHdrFromPayload(request).id == SCANU_JOIN_REQ
    else: scanu_env.bssidFilterEnabled != 0
  scanu_env.paramPtr = nil
  scanu_env.pendingJoinRxuMgtInd = nil
  if replayed: scanu_cached_scanresult_clear()
  let primaryId = if joining: SCANU_JOIN_CFM else: SCANU_START_CFM
  let primary = scanuReply(primaryId, source)
  let api =
    if joining and not replayed:
      ke_msg_try_alloc(SCANU_JOIN_CFM, TASK_API, TASK_SCANU, StatusCfmPayloadSize)
    else: nil
  if api != nil: statusCfmView(api).status = status
  scanuPublishCompletion(request, primary, primaryId, source, status)
  if api != nil: ke_msg_send(api)
  # Idle after the answer is queued, ahead of any saved request it releases.
  scanuGo(ScanuIdleState)

proc scanuAbandon() =
  ## Drop SCANU's request unanswered and go idle: scanu_init, and ke_flush,
  ## which flushes the lower answer SCANU waits on. The requester is reset
  ## with it (SM by sm_init or smAbandon); a host requester is not answered,
  ## as in the blob, which drops the pointer with scanu_init's memset.
  let request = scanu_env.paramPtr
  scanu_env.paramPtr = nil
  scanu_env.pendingJoinRxuMgtInd = nil
  scanuGo(ScanuIdleState)
  if request != nil: ke_msg_free(keMsgHdrFromPayload(request))

proc scanu_confirm*(status: uint8) {.exportc, cdecl.} =
  ## Send the scan or join confirmation and end the request (58 instrs).
  ## Blob: allocates SCANU_JOIN_CFM twice in join mode (to the requester and
  ## TASK_API), or SCANU_START_CFM in scan mode, frees the request and sets
  ## TASK_SCANU idle.
  scanuComplete(status)
