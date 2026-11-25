type
  SmSaQueryTxResult = enum
    saQueryBuildRejected, saQueryQueueRejected, saQuerySubmitted

  SmPeerDisconnectEvidence = object
    header, radio: uint32
    submitted, rejected: uint8
    when defined(bl808WifiDiagPeerRxAdmission):
      protection: RxMgtProtection

  SmSaQueryLease = object
    peer: MmVifIdentity
    serial, deadline: uint32
    armed: bool
    when defined(bl808WifiDiagLinkDrop):
      evidence: SmPeerDisconnectEvidence

var
  smSaQuery {.wifiCtrl.}: SmSaQueryLease
  smSaQueryResetting {.wifiCtrl.}: bool
  smSaQueryResetEpoch {.wifiCtrl.}: uint32

proc smSaQueryBeginReset(): bool =
  let saved = irqSave()
  result = smSaQueryResetting
  smSaQueryResetting = true
  inc smSaQueryResetEpoch
  inc smSaQuery.serial
  smSaQuery.armed = false
  smEnvView().saQueryActive = 0
  irqRestore(saved)

proc smSaQueryEndReset(previous: bool) =
  let saved = irqSave()
  smSaQueryResetting = previous
  irqRestore(saved)

proc smSaQueryClearResetTimer() =
  ke_timer_clear(SM_SA_QUERY_TIMEOUT_IND_MSG, TASK_SM)

when defined(bl808WifiDiagLinkDrop):
  var nimFwDbgPeerDisconnect {.wifiCtrl, exportc: "nimfw_dbg_peer_disconnect", volatile.}:
    array[6, uint32]

  proc smCapturePeerDisconnect(frame: ptr RxuMgtIndMsgView;
                               viaQuery: bool): SmPeerDisconnectEvidence =
    let seqCtrl = macDataFrameAt(addr frame.body[0]).seqCtrl
    let path = if viaQuery: 2'u32 else: 1'u32
    result.header = frame.frameCtrl.uint32 or (seqCtrl.uint32 shl 16)
    result.radio = frame.freq.uint32 or (cast[uint8](frame.rssi).uint32 shl 16) or
      (path shl 24)

proc smSaQueryCurrent(serial: uint32): bool =
  let sm = smEnvView()
  not smSaQueryResetting and smSaQuery.serial == serial and sm.saQueryActive != 0 and
    sm.saQueryStaIdx == smSaQuery.peer.station and mmVifCurrent(smSaQuery.peer) and
    vifChannelAt(smSaQuery.peer.vif).state != 0

proc smSaQueryArmCurrent(context: pointer): bool =
  smSaQueryCurrent(cast[ptr uint32](context)[])

proc smSaQueryQueueTimeout(serial: uint32) =
  if serial == 0 or not smSaQueryCurrent(serial) or not smSaQuery.armed: return
  let message = ke_msg_try_alloc(SM_SA_QUERY_TIMEOUT_IND_MSG, TASK_SM, 0xFF, 4)
  let saved = irqSave()
  if not smSaQueryCurrent(serial) or not smSaQuery.armed:
    irqRestore(saved)
    if message != nil: ke_msg_free(keMsgHdrFromPayload(message))
    return
  defer: irqRestore(saved)
  if message != nil:
    cast[ptr uint32](message)[] = serial
    ke_msg_send(message)
  else:
    # Local resource exhaustion is not a failed peer response.
    smEnvView().saQueryActive = 0
    smSaQuery.armed = false

proc smSaQueryClaimTimeout(param: pointer): uint32 =
  if param == nil or not smSaQuery.armed: return 0
  let header = keMsgHdrFromPayload(param)
  if header.id != SM_SA_QUERY_TIMEOUT_IND_MSG or header.destId != TASK_SM or
      header.srcId != 0xFF or header.paramLen != 4: return 0
  let serial = cast[ptr uint32](param)[]
  if serial == 0 or serial != smSaQuery.serial: return 0
  let deadline = smSaQuery.deadline
  let now = macTimeNow()
  if cast[int32](now - deadline + 50) < 0 or not smSaQueryCurrent(serial) or
      not smSaQuery.armed:
    return 0
  smSaQuery.armed = false
  serial

proc smSaQueryEnd() =
  ## The link is being torn down: no SA Query outcome can matter any more.
  smEnvView().saQueryActive = 0
  smSaQuery.armed = false
  ke_timer_clear(SM_SA_QUERY_TIMEOUT_IND_MSG, TASK_SM)

proc smReportApDisconnect(peer: MmVifIdentity; reason: uint16;
                          evidence = default(SmPeerDisconnectEvidence)) =
  ## The AP ended the link (deauthentication, disassociation or an SA Query
  ## that went unanswered). Log it as sm.o does, then end the link.
  let logFn = blOpsFunc(4)
  if logFn != nil:
    cast[proc(fmt: cstring) {.cdecl, varargs.}](logFn)(
      "Deauth/Disassociate by AP, Wlan802.11 reason code = %d\r\n", reason.cint)
  when defined(bl808WifiDiagLinkDrop):
    # This marks SM's teardown decision, not host delivery or cleanup completion.
    let record = addr nimFwDbgPeerDisconnect
    if volatileLoad(addr record[0]) == 0 and evidence.radio shr 24 != 0:
      let evidenceIrq = irqSave()
      defer: irqRestore(evidenceIrq)
      if volatileLoad(addr record[0]) == 0:
        volatileStore(addr record[1], macTimeNow())
        volatileStore(addr record[2], reason.uint32 or (peer.index.uint32 shl 16) or
          (peer.station.uint32 shl 24))
        volatileStore(addr record[3], evidence.header)
        volatileStore(addr record[4], evidence.radio)
        var provenance = evidence.submitted.uint32 or (evidence.rejected.uint32 shl 8)
        when defined(bl808WifiDiagPeerRxAdmission):
          provenance = provenance or (evidence.protection.uint32 shl 16)
        volatileStore(addr record[5], provenance)
        # Publish last, under the same IRQ lock as the probe history writer.
        volatileStore(addr record[0], 0x50454552'u32) # PEER
  sm_disconnect_process(peer.vif, 7, reason)
