var meConfigInProgress: bool
var meControlEpoch: uint32

proc meControlMessageMatches(node: ptr CoListHdr, payload: pointer): bool {.cdecl.} =
  keMsgPayload(cast[ptr KeMsgHdr](node)) == payload

proc meCancelQueuedPayload(payload: pointer) =
  if payload == nil:
    return
  for queue in [addr keMsgQueueSent, addr keMsgQueueSaved]:
    let saved = irqSave()
    let node = ke_queue_extract(queue, meControlMessageMatches, payload)
    irqRestore(saved)
    if node != nil:
      ke_msg_free(node)
      # A free callback may reuse this address in the other queue.
      return

proc mmPsModeCancel() =
  let request = block:
    let saved = irqSave()
    defer: irqRestore(saved)
    let held = mmPsModeRequest
    if held == nil: return
    mmPsModeRequest = nil
    if meControlCommand == held:
      meControlCommand = nil
    let ps = psEnvView()
    if (ps.flags and 0x10) != 0:
      # Only the parked command is canceled; DPSM still owns the transition.
      ps.flags = ps.flags and not 0x10'u8
    else:
      inc psModeBuildSerial
      ps.pendingCount = 0
      ps.currentVif = nil
      ps.flags = ps.flags and not 0x06'u8
    held
  ke_msg_free(keMsgHdrFromPayload(request))
  # A second request saved behind the held one must not wait for an
  # unrelated MM state change.
  discard ke_reschedule_saved_messages(TASK_MM)

proc meControlReset() =
  inc meControlEpoch
  meConfigInProgress = false
  let command = meControlCommand
  let reply = meControlReply
  let ready = meControlReplyReady
  meControlCommand = nil
  meControlReply = nil
  meControlReplyReady = false
  if reply != nil and apmStartReply == reply:
    apmStartReply = nil
    apmStartReplyPublished = false
  meEnvView().requesterId = TASK_NONE
  if command == mmPsModeRequest:
    mmPsModeCancel()
  else:
    meCancelQueuedPayload(command)
  if ready:
    meCancelQueuedPayload(reply)
  elif reply != nil:
    ke_msg_free(keMsgHdrFromPayload(reply))

proc meTakeControlReply(request: pointer, id: uint16, length: uint32): pointer =
  if request == nil or request != meControlCommand or
     id != meControlExpectedId or length != 0 or meControlReply == nil:
    return nil
  let header = keMsgHdrFromPayload(meControlReply)
  header.id = id
  header.destId = TASK_ME
  header.srcId = TASK_MM
  header.paramLen = 0
  meControlCommand = nil
  meControlReplyReady = true
  meControlReply

proc meReserveControl(request: pointer, commandId, replyId: uint16,
                      mask: uint32): cint =
  if meConfigInProgress or meControlCommand != nil or meControlReply != nil:
    return KeMsgSaved
  let requestHeader = keMsgHdrFromPayload(request)
  let requester = requestHeader.srcId
  let reply = if replyId == 0:
      ke_msg_alloc(commandId + 1, TASK_ME, TASK_MM, 0)
    else:
      ke_msg_alloc_reply(request, replyId, 0)
  if reply == nil:
    return KeMsgSaved
  inc meControlEpoch
  meControlCommand = request
  meControlReply = reply
  meControlReplyReady = false
  meControlExpectedId = commandId + 1
  meControlFinalId = replyId
  meControlRequester = requester
  let me = meEnvView()
  if replyId != 0:
    me.requesterId = requester
    if commandId == MM_SET_IDLE_REQ: me.activeMask = mask
    else: me.psDisableMask = mask
  KeMsgNoFree

proc meForwardControl(request: pointer, commandId: uint16, value: uint8,
                      reply: pointer): cint =
  if meControlCommand != request or meControlReply != reply:
    return KeMsgConsumed
  if meControlFinalId == 0:
    meEnvView().requesterId = TASK_NONE
  let requestHeader = keMsgHdrFromPayload(request)
  # The two-byte ME request has room for the one-byte MM command. Forward its
  # allocation; the MM worker owns it until the hardware transition completes.
  requestHeader.id = commandId
  requestHeader.destId = TASK_MM
  requestHeader.srcId = TASK_ME
  requestHeader.paramLen = 1
  cast[ptr uint8](request)[] = value
  ke_state_set(TASK_ME, MeBusyState)
  if meControlCommand != request or meControlReply != reply:
    return KeMsgConsumed
  ke_msg_send(request)
  KeMsgNoFree

proc meBeginControl(request: pointer, commandId: uint16, value: uint8,
                    replyId: uint16, mask: uint32): cint =
  result = meReserveControl(request, commandId, replyId, mask)
  if result == KeMsgNoFree:
    result = meForwardControl(request, commandId, value, meControlReply)

proc meCompleteControl(reply: pointer, expectedId: uint16): cint =
  if reply == nil or reply != meControlReply or not meControlReplyReady:
    return KeMsgConsumed
  let header = keMsgHdrFromPayload(reply)
  if header.id != expectedId or expectedId != meControlExpectedId or
     header.srcId != TASK_MM or header.destId != TASK_ME:
    return KeMsgConsumed
  let finalId = meControlFinalId
  let requester = meControlRequester
  let epoch = meControlEpoch
  meControlReply = nil
  meControlReplyReady = false
  meControlCommand = nil
  meEnvView().requesterId = TASK_NONE
  result = KeMsgConsumed
  if finalId != 0:
    header.id = finalId
    header.destId = requester
    header.srcId = TASK_ME
    ke_msg_send(reply)
    result = KeMsgNoFree
  # State publication releases saved work. Queue the confirmation first and
  # do not idle a control exchange installed by a synchronous host callback.
  let saved = irqSave()
  defer: irqRestore(saved)
  if meControlEpoch == epoch and ke_state_get(TASK_ME) == MeBusyState:
    ke_state_set(TASK_ME, MeIdleState)

proc mmPsModeComplete() =
  let request = mmPsModeRequest
  if request == nil:
    ke_msg_send_basic(MM_SET_PS_MODE_CFM, psEnvView().mode, TASK_MM)
    return
  if mmPsModeTxResetEpoch != txResetEpoch: return
  mmPsModeRequest = nil
  ke_msg_send_basic_reply(request, MM_SET_PS_MODE_CFM)
  ke_msg_free(keMsgHdrFromPayload(request))
  discard ke_reschedule_saved_messages(TASK_MM)

proc mmPsModeRetryAfterReset() =
  let saved = irqSave()
  defer: irqRestore(saved)
  let request = mmPsModeRequest
  let previous = mmPsModeTxResetEpoch
  let epoch = txResetEpoch
  if request == nil or previous == epoch: return
  mm_timer_clear(psTxNullTimer())
  if txResetEpoch != epoch or mmPsModeRequest != request or
      mmPsModeTxResetEpoch != previous: return
  let ps = psEnvView()
  ps.pendingCount = 0
  ps.currentVif = nil
  ps.flags = ps.flags and not 0x16'u8 # abandoned transitions and deferred mode
  mmPsModeRequest = nil
  # Keep the original command and reply ownership. Requests saved behind it
  # must not overtake it when MM releases the saved queue during reset.
  co_list_push_front(addr keMsgQueueSent, cast[ptr CoListHdr](keMsgHdrFromPayload(request)))
  ke_evt_set(KE_EVT_KE_MESSAGE)

# --- MM Task Handlers (mm_task.o) ---

proc mm_reset_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle MM_RESET_REQ: reset MAC state (92 bytes in blob).
  ## Stop MAC/PHY and initialize ME/MM with interrupts disabled; restore
  ## the incoming interrupt state before confirming the request.
  if param == nil: return KeMsgConsumed
  let hdr = keMsgHdrFromPayload(param)
  let requesterTask = hdr.srcId
  let destinationTask = hdr.destId
  nimFwTrace("[WIFI-NIMFW] mm_reset_req begin")
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    if not hal_machw_stop(): return KeMsgSaved
    phy_stop()
    me_init()
    if not mm_init(): return KeMsgSaved
  # Send reset confirmation and set state (blob: ke_msg_send_basic + ke_state_set)
  nimFwTrace("[WIFI-NIMFW] mm_reset_req cfm")
  ke_msg_send_basic(MM_RESET_CFM, requesterTask, destinationTask)
  ke_state_set(TASK_MM, MM_IDLE)
  nimFwTrace("[WIFI-NIMFW] mm_reset_req done")
  return KeMsgConsumed

proc mm_start_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Apply the PHY configuration and timing fields from the 72-byte start
  ## request, then activate MM on the vendor's initial 2.4 GHz channel.
  if param == nil: return KeMsgConsumed
  let hdr = keMsgHdrFromPayload(param)
  if hdr.paramLen < MmStartReqPayloadSize: return KeMsgConsumed
  let destinationTask = hdr.destId
  let requesterTask = hdr.srcId
  let state = ke_state_get(destinationTask)
  if state != MM_IDLE.uint16:
    assert_err("ke_state_get(dest_id) == MM_IDLE", "module", 308)
    return KeMsgConsumed
  let req = mmStartReqView(param)
  phy_init(cast[pointer](addr req.phyConfig[0]))
  phySetChannel(0'u8, 0'u8, 2412'u16, 2412'u16, 0'u16, 0'u8)
  tpc_update_tx_power(16'u8)
  psEnvView().uapsdPeriod = req.uapsdTimeoutMs * 1000'u32
  mmEnvView().listenWindow = req.lpClockAccuracy
  ke_msg_send_basic(MM_START_CFM, requesterTask, destinationTask)
  mm_active()
  hal_machw_idle_req()
  ke_state_set(destinationTask, MM_GOING_TO_IDLE.uint16)
  return KeMsgConsumed

proc mm_version_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle MM_VERSION_REQ (84 bytes in blob).
  ## From blob: allocates 24-byte CFM, fills version info from HW regs.
  ## msg[0]=0x05040000 (FW version), msg[4,8]=HW version regs,
  ## msg[12..15]=version string, msg[20]=0x001089DF (feature flags).
  if param == nil: return KeMsgConsumed
  let request = keMsgHdrFromPayload(param)
  let cfm = cast[ptr MmVersionCfmPayload](
    ke_msg_alloc(MM_VERSION_CFM, request.srcId, request.destId,
                 MmVersionCfmPayloadSize))
  if cfm == nil:
    return KeMsgConsumed
  # FW version word
  cfm.fwVersion = 0x05040000'u32
  # HW version registers from MACHW_BASE
  cfm.hwVersion0 = regRead(MACHW_BASE + 4)
  cfm.hwVersion1 = regRead(MACHW_BASE + 8)
  # Version string at offset 12 (blob: phy_get_version(cfm+12, cfm+16))
  phy_get_version(addr cfm.phyVersion0, addr cfm.phyVersion1)
  # Feature flags
  cfm.features = 0x001089DF'u32
  ke_msg_send(cfm)
  return KeMsgConsumed

proc mm_hw_config_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle HW configuration messages (1276 bytes / 399 instrs in blob).
  ## Blob ABI: a0=msgId, a1=msgBody, a2=srcId, a3=destId.
  ## Dispatches on msgId to configure MAC HW for various operations.
  ## Called via ke_task_schedule for msg IDs: 6,8,14,16,18,20,22,24,41.
  if param == nil or smStaleRequest(param) or not chanUpdateAdmit(param):
    return KeMsgConsumed
  let hdr = keMsgHdrFromPayload(param)
  let msgId = hdr.id
  let msgBody = param
  let srcId = hdr.destId
  let destId = hdr.srcId

  let edcaRefresh = msgId == MM_SET_EDCA_REQ and hdr.paramLen == 0 and
    srcId == TASK_MM and destId == TASK_MM and cast[pointer](hdr) == mmEdcaRefresh.message
  if msgId == MM_SET_EDCA_REQ and hdr.paramLen < MmSetEdcaReqPayloadSize and not edcaRefresh:
    return KeMsgConsumed
  if msgId == MM_CHAN_CTXT_UPDATE_REQ and hdr.paramLen < MmChanCtxtUpdatePayloadSize:
    return KeMsgConsumed
  if msgId == MM_REMOVE_IF_REQ:
    if hdr.paramLen < sizeof(MmRemoveIfReqPayload).uint32:
      return KeMsgConsumed
    if not apmPrepareVifRemoval(cast[ptr MmRemoveIfReqPayload](param).vifIdx):
      return KeMsgSaved

  let mm = mmEnvView()

  # Do not replace the saved resume state while a transition is pending.
  let curState = ke_state_get(srcId)
  if curState == TaskGoingIdleState or curState == MM_HOST_BYPASSED.uint16:
    return KeMsgSaved
  if curState != TaskIdleState:
    # Non-idle: save HW mode and task state, force idle
    let saved = irqSave()
    defer: irqRestore(saved)
    let hwMode = regRead(MACHW_STATE_CNTRL_REG) and 0x0F'u32
    discard mmConfigTrackIdle(hdr, hwMode.uint8, curState.uint8)
    hal_machw_idle_req()
    ke_state_set(srcId, TaskGoingIdleState)
    # Fast path: if SET_VIF_STATE with state=0, enable monitor RX
    if msgId == MM_SET_VIF_STATE_REQ and
        cast[ptr MmSetVifStateReqPayload](msgBody).state == 0:
      rxlCntrlEnvView().processingFlag = 1
    return KeMsgSaved

  let idleEpoch = mmConfigIdle.epoch
  # Assert HW is truly idle
  let hwState = regRead(MACHW_STATE_CNTRL_REG) and 0x0F'u32
  if hwState != 0:
    # The blob halts here. The assert posts a MAC recovery, which leaves the
    # MAC idle and reschedules MM's saved messages: the request then runs
    # and is confirmed.
    assert_err("blmac_current_state_getf() == HW_IDLE", "module", 1527)
    return KeMsgSaved

  # Blob tail-merges all ke_msg_send_basic error/ack paths into a
  # single shared call site. Collect the CFM msg ID here; branches
  # that need basic-send set it, then fall through to one tail call.
  var cfmBasicId: uint16 = 0
  # Also share the non-basic ke_msg_send (add-if / set-channel) via
  # a cfmPtr — blob has one ke_msg_send site for these.
  var cfmPtr: pointer = nil
  # Main dispatch on msgId
  case msgId.int
  of 6:  # MM_ADD_IF_REQ -> vif_mgmt_register + send CFM
    let req = cast[ptr MmAddIfReqPayload](msgBody)
    let cfm = cast[ptr MmAddIfCfmPayload](
      ke_msg_alloc(MM_ADD_IF_CFM, destId, srcId, MmAddIfCfmPayloadSize))
    if cfm == nil:
      return KeMsgConsumed
    let p2p = req.p2p != 0
    cfm.status =
      vif_mgmt_register(cast[pointer](addr req.macAddr[0]), req.ifType, p2p,
                        addr cfm.vifIdx)
    cfmPtr = cast[pointer](cfm)

  of 8:  # MM_REMOVE_IF_REQ -> vif_mgmt_unregister + maybe monitor mode
    let req = cast[ptr MmRemoveIfReqPayload](msgBody)
    let vifIdx = req.vifIdx
    if vifIdx <= 1:
      if not vif_mgmt_unregister(vifIdx):
        return KeMsgSaved
    # Check if no VIFs remain
    let vifMgmt = vifMgmtEnvView()
    if vifMgmt.activeList.first == nil:
      hal_machw_monitor_mode(true)
    cfmBasicId = MM_REMOVE_IF_CFM

  of 14:  # MM_SET_CHANNEL_REQ -> phy_set_channel + send CFM
    let req = cast[ptr MmSetChannelReqPayload](msgBody)
    let cfm = cast[ptr MmSetChannelCfmPayload](
      ke_msg_alloc(MM_SET_CHANNEL_CFM, destId, srcId,
                   MmSetChannelCfmPayloadSize))
    if cfm == nil:
      return KeMsgConsumed
    if req.index != 0:
      phySetChannel(req.band, req.chanType, req.prim20Freq,
                    req.center1Freq, req.center2Freq, 0)
    cfmPtr = cast[pointer](cfm)

  of 16:  # MM_SET_BEACON_INT_REQ -> set beacon interval
    let req = cast[ptr MmSetBeaconIntReqPayload](msgBody)
    let vifIdx = req.vifIdx
    let vifU = vifEntryAddr(vifIdx)
    let vif = vifChannelAt(vifU)
    let bcnInt = req.interval
    # Check if AP mode
    let apFlag = vif.vifType
    if apFlag != 0:
      vif_mgmt_set_ap_bcn_int(cast[pointer](vifU), bcnInt)
    else:
      # STA mode: write bcn_int << 10 to sta_entry[24]. Without an AP station
      # (0xFF) the blob writes past sta_info_tab; here nothing is written.
      let staIdx = vif.staIdx
      if staIdx < STA_INFO_TAB_ENTRIES.uint8:
        staInfoForIdx(staIdx).initialRateConfig = bcnInt.uint32 shl 10
    cfmBasicId = MM_SET_BEACON_INT_CFM

  of 18:  # MM_SET_BASIC_RATES_REQ -> write basic rate bitmap to HW
    let req = cast[ptr MmSetBasicRatesReqPayload](msgBody)
    let chanCtxPtr = chanEnvView().currentCtxt
    if chanCtxPtr != nil:
      let chanBand = chanCtxtAt(chanCtxPtr).channel.band
      if chanBand == req.band:
        regWrite(MACHW_BASE + 0x0DC'u, 496'u32)  # basic rate bitmap
    cfmBasicId = MM_SET_BASIC_RATES_CFM

  of 20:  # MM_SET_BSSID_REQ -> copy BSSID to VIF + MAC HW
    let req = cast[ptr MmSetBssidReqPayload](msgBody)
    let vifIdx = req.vifIdx
    let vifU = vifEntryAddr(vifIdx)
    let vif = vifChannelAt(vifU)
    # The SM BSS-parameter path sources this request from VIF+380
    # (vif.bssid in our layout). Keep that canonical field in sync with the
    # MAC HW BSSID and the local currentBssid helper used by reset/switch code.
    vif.bssid = req.bssid
    vif.currentBssid = req.bssid
    let bssidView = macAddrAt(addr req.bssid[0])
    let bssidLo = bssidView.lowLe
    let bssidHi = bssidView.highLe
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] set_bssid ",
                            bssidLo, bssidHi)
    # If exactly 1 VIF active, write BSSID to MAC HW
    let vifMgmt = vifMgmtEnvView()
    if vifMgmt.staCount.int + vifMgmt.apCount.int == 1:
      regWrite(MACHW_BASE + 0x020'u, bssidLo)
      regWrite(MACHW_BASE + 0x024'u, bssidHi)
      when defined(bl808WifiConnectTrace):
        nimFwConnectTrace2U32("[WIFI-CT] set_bssid_hw ", bssidLo, bssidHi)
        nimFwConnectTraceHw("[WIFI-CT] hw_own ")
    cfmBasicId = MM_SET_BSSID_CFM

  of 22:  # MM_SET_EDCA_REQ -> write EDCA params + ps_uapsd_set
    if edcaRefresh:
      let saved = irqSave()
      if mmEdcaRefreshCurrent():
        mmProgramEdca(vifChannelForIdx(mmEdcaRefresh.vif))
      irqRestore(saved)
    else:
      let req = cast[ptr MmSetEdcaReqPayload](msgBody)
      let hwQueue = req.acmFlag
      let vifIdx = req.vifIdx
      if vifIdx < MAX_VIFS.uint8 and hwQueue < 4:
        let edcaParam = req.edcaParam
        let vifU = vifEntryAddr(vifIdx)
        let vif = vifChannelAt(vifU)
        block:
          let saved = irqSave()
          defer: irqRestore(saved)
          vif.edcaRegs[hwQueue] = edcaParam
          if mmEdcaOwner() == vif:
            regWrite(MACHW_BASE + 0x200'u + hwQueue.uint * 4, edcaParam)
            mm_env_max_ampdu_duration_set(0)
        if vif.vifType == VIF_TYPE_STA:
          ps_uapsd_set(cast[pointer](vifU), hwQueue, req.uapsdAc.uint32)
      # An out-of-range queue or VIF changes nothing but is still answered.
      cfmBasicId = MM_SET_EDCA_CFM

  of 24:  # MM_SET_VIF_STATE_REQ -> full VIF state transition
    let req = cast[ptr MmSetVifStateReqPayload](msgBody)
    let vifIdx = req.vifIdx
    let vifU = vifEntryAddr(vifIdx)
    let vif = vifChannelAt(vifU)
    let newState = req.state
    let apFlag = vif.vifType
    var runCommonVifStateUpdate = true
    inc nimFwDbgSetVifState
    nimFwDbgSetVifStateNew = newState.uint32 or (apFlag.uint32 shl 8) or (vifIdx.uint32 shl 16)

    if newState == 0:
      let saved = irqSave()
      defer: irqRestore(saved)
      if vif.vifType == VIF_TYPE_STA:
        if ke_task_sm_activating(): inc nimFwDbgSetVifStateAct
        for timer in [addr vif.tbttTimer, addr vif.keepAliveTimer, addr vif.securityTimer]:
          mmTimerClearLocked(timer, saved)
      vif.state = 0
    elif apFlag == VIF_TYPE_STA:
      let activating = ke_task_sm_activating()
      if activating:
        inc nimFwDbgSetVifStateAct
        # Activating STA: set up TBTT timer, beacon tracking, etc.
        let staIdx = vif.staIdx
        let sta = staInfoForIdx(staIdx)
        let tbttTime = macTimeNow()
        mm_timer_set(addr vif.tbttTimer, tbttTime + sta.initialRateConfig)
        # Store AID and vendor beacon timing helper.
        sta.aid = req.aid
        let listenWindow = mm.listenWindow.uint32 + 20'u32
        sta.listenWindowDuration =
          ((listenWindow * sta.initialRateConfig) div 1_000_000'u32).uint16
        # Clear VIF beacon tracking state
        vif.listenInterval = 0
        vif.psOptions = 0
        let psTime = macTimeNow()
        vif.probeCount = 0
        vif.beaconCrc = 0
        vif.psLastTime = psTime
        vif.flags = vif.flags or 1'u32
        let beaconTime = macTimeNow()
        vif.tbttCount = 0
        vif.beaconLossCount = 0
        vif.beaconTimeoutBase = beaconTime
        mm.keepAliveLimit = 10
        vif.beaconRxCount = 0
        vif.beaconLossWindow = 0
        vif.lastBeaconMacTime = 0
        chan_bcn_detect_start(cast[pointer](vifU))
      else:
        runCommonVifStateUpdate = false

    # Common: update VIF operational state
    if runCommonVifStateUpdate:
      if newState != 0: vif.state = newState
      if newState != 0 and mmEdcaOwner() == vif:
        # Write EDCA params from VIF to MAC HW
        if apFlag in [VIF_TYPE_STA, VIF_TYPE_AP]:
          # STA BSS setup saves the negotiated WMM word for each queue.
          for ac in 0'u ..< 4'u:
            let edcaVal = vif.edcaRegs[ac.int]
            regWrite(MACHW_BASE + 0x200'u + ac * 4, edcaVal)
        else:  # Other interface types retain the SDK's common EDCA word.
          let voEdca = vif.edcaRegs[3]
          for ac in 0'u ..< 4'u:
            regWrite(MACHW_BASE + 0x200'u + ac * 4, voEdca)
        mm_env_max_ampdu_duration_set(0)
      elif newState == 0:
        mmReplayEdca()
      cfmBasicId = MM_SET_VIF_STATE_CFM

  of 41:  # MM_CHAN_CTXT_UPDATE_REQ
    if chanUpdateAdmit(msgBody):
      chan_ctxt_update(msgBody)
      if chanUpdateAdmit(msgBody):
        cfmBasicId = MM_CHAN_CTXT_UPDATE_CFM

  else:
    assert_err("0", "module", 1563)
    return KeMsgConsumed

  # Restore local MM state before a confirmation can synchronously reenter.
  # The request has been applied, so it is confirmed even when a pending reset
  # refuses the resume.
  discard mmConfigResumeIdle(idleEpoch, srcId)
  if cfmBasicId != 0:
    ke_msg_send_basic_reply(param, cfmBasicId)
  if cfmPtr != nil:
    ke_msg_send(cfmPtr)
  return KeMsgConsumed

{.emit: "__attribute__((optimize(\"crossjumping\"))) int mm_set_idle_req_handler(void*);".}
proc mm_set_idle_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## The request belongs to TASK_MM and remains saved until hardware is idle.
  if param == nil or keMsgHdrFromPayload(param).paramLen < MmSetIdleReqPayloadSize:
    return KeMsgConsumed
  let state = ke_state_get(TASK_MM)
  if state == HW_ACTIVE.uint16:
    return KeMsgSaved
  let idle = mmSetIdleReqView(param).idle
  let mm = mmEnvView()
  mm.idleFlag = idle
  if idle != 0:
    # Going idle
    if state == MM_IDLE.uint16:
      # Already idle - verify HW idle, then send cfm
      let hwState = regRead(MACHW_STATE_CNTRL_REG) and 0x0F'u32
      if hwState != 0:
        # As in mm_hw_config_handler: kept until the posted recovery idles
        # the MAC and reschedules it.
        assert_err("blmac_current_state_getf() == HW_IDLE", "module", 946)
        return KeMsgSaved
      mmConfigCancelIdle()
      mm.previousState = 0
      mm.hardwareMode = 0
      ke_msg_send_basic_reply(param, MM_SET_IDLE_CFM)
      return KeMsgConsumed
    if state == TaskGoingIdleState:
      return KeMsgSaved
    hal_machw_idle_req()
    ke_state_set(TASK_MM, TaskGoingIdleState)
    return KeMsgSaved
  else:
    # Going active
    if state == TaskGoingIdleState:
      return KeMsgSaved
    mm_active()
    ke_msg_send_basic_reply(param, MM_SET_IDLE_CFM)
  return KeMsgConsumed

proc mm_set_idle_cfm_handler*(param: pointer): cint {.exportc, cdecl.} =
  meCompleteControl(param, MM_SET_IDLE_CFM)

proc mm_sta_add_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle MM_STA_ADD_REQ (70 bytes in blob, 22 instrs).
  ## From blob: allocates 3-byte CFM message (id=11=MM_STA_ADD_CFM),
  ## calls mm_sta_add(param, &msg[1], &msg[2]), stores status at msg[0],
  ## sends via ke_msg_send, returns 0.
  ## SM's request is answered in place instead (smStaAddAnswer), so its
  ## confirmation cannot be lost; one SM no longer waits on is not applied.
  if param == nil or keMsgHdrFromPayload(param).paramLen < MmStaAddReqPayloadSize:
    return KeMsgConsumed
  let header = keMsgHdrFromPayload(param)
  let requester = header.srcId
  if requester == TASK_SM and not smAwaits(param): return KeMsgConsumed
  var cfm: ptr MmStaAddCfmPayload
  if requester != TASK_SM:
    cfm = cast[ptr MmStaAddCfmPayload](
      ke_msg_alloc(MM_STA_ADD_CFM, requester, header.destId, MmStaAddCfmPayloadSize))
    if cfm == nil: return KeMsgConsumed
  var staIdx = 0xFF'u8
  var hwStaIdx = 0xFF'u8
  let status = mm_sta_add(param, addr staIdx, addr hwStaIdx)
  inc nimFwDbgPreauthStaCfm
  nimFwDbgPreauthStaCfmMeta = status.uint32 or (staIdx.uint32 shl 8) or
    (hwStaIdx.uint32 shl 16) or (requester.uint32 shl 24)
  if cfm == nil:
    smStaAddAnswer(param, status, staIdx, hwStaIdx)
    return KeMsgNoFree
  cfm[] = MmStaAddCfmPayload(status: status, staIdx: staIdx, hwStaIdx: hwStaIdx)
  ke_msg_send(cfm)
  return KeMsgConsumed

proc mm_sta_add_cfm_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle MM_STA_ADD_CFM (288 bytes in blob, 72 instrs).
  ## From blob (me_task.o): asserts state==3 (CONNECTED). If cfm->status!=0:
  ## calls sm_connect_ind(15, 0xFFFF) to signal failure. If status==0:
  ## reads sta_idx from cfm[1], copies 13 bytes from vif.bssid(436) to
  ## sta.mac_addr(248). Sets HT/VHT capa bits in sta.capa_flags(308) based
  ## on vif.flags(484). If VHT: copies 32 bytes of HT cap from vif(348) to
  ## sta(264), calls me_set_sta_ht_vht_param. Invokes WPA callback, then
  ## calls sm_set_bss_param.
  ## Only the answer to SM's live registration is taken, so SM is in state 3
  ## here; a station MM registered for an earlier one is deleted.
  if not smTakeAnswer(param):
    smStaAddRetire(param)
    return KeMsgConsumed
  # A failure, or a station deleted since MM registered it, ends the attempt.
  let staIdx = smStaAddStation(param)
  if staIdx == 0xFF:
    sm_connect_ind(15, 0xFFFF)
    return KeMsgConsumed
  # Success path: set up station entry
  let sta = staInfoForIdx(staIdx)
  let vifIdx = sta.instNbr
  let vif = vifChannelForIdx(vifIdx)
  # Copy 13 bytes from vif.bssid(436) to sta(248)
  discard c_memcpy(cast[pointer](addr sta.supportedRates[0]),
                   addr vif.basicRates[0], 13.csize_t)
  # Set HT/VHT capability flags
  let vifFlags = vifApConfig(vif).securityFlags
  if (vifFlags and 1) != 0:  # HT flag
    sta.capabilityFlags = sta.capabilityFlags or 1
  if (vifFlags and 2) != 0:  # VHT flag
    sta.capabilityFlags = sta.capabilityFlags or 2
    # Copy 32 bytes of HT/VHT caps from vif(348) to sta(264)
    discard c_memcpy(cast[pointer](addr sta.vhtCaps[0]),
                     cast[pointer](vifHtCapabilities(vif)), 32.csize_t)
    me_set_sta_ht_vht_param(cast[pointer](sta), cast[pointer](vifHtCapabilities(vif)))
  sm_set_bss_param()
  return 0

proc mm_sta_del_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## The vendor confirms to the incoming source, not unconditionally to API.
  ## The confirmation is the request itself, so it needs no allocation. A
  ## request of SM's that SM no longer waits on is not applied; a queued one
  ## whose station is deleted meanwhile already names no station
  ## (staDeleteCancelQueued).
  if param == nil or keMsgHdrFromPayload(param).paramLen < MmStaDelReqPayloadSize:
    return KeMsgConsumed
  let header = keMsgHdrFromPayload(param)
  let destination = header.srcId
  let source = header.destId
  if destination == TASK_SM and not smAwaits(param): return KeMsgConsumed
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    if txlResetting(): return KeMsgSaved
    let staIdx = mmStaDelReqView(param).staIdx
    # A task-wide wake may replay this request before the MAC retry is due.
    if mmStaDelRetryPending(staIdx) or not mmStaDelTry(staIdx, saved):
      if txlResetting(): return KeMsgSaved
      # Publish before arming: a synchronous timer callback must see the request.
      if mmStaDelReqView(param).staIdx == staIdx:
        co_list_push_back(addr keMsgQueueSaved, cast[ptr CoListHdr](header))
        mmStaDelQueueRetryLocked(staIdx, saved)
        return KeMsgNoFree
  if txlResetting(): return KeMsgSaved
  # Reuse the consumed request so completion cannot fail to allocate.
  header.paramLen = 0
  ke_msg_forward_and_change_id(param, MM_STA_DEL_CFM, destination, source)
  KeMsgNoFree

proc mm_set_ps_mode_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle MM_SET_PS_MODE_REQ (96 bytes in blob, 30 instrs).
  ## From blob (mm_task.o): reads req[0] = ps_mode. If ps_mode == 3
  ## (PS_MODE_ON_DYN): iterates linked list of VIFs from vif_mgmt_env+8.
  ## For each STA (vif[86]==0) and active (vif[88]!=0) VIF, calls
  ## ps_polling_frame. When the list is exhausted, sends MM_SET_PS_MODE_CFM.
  ## If ps_mode != 3: forwards to ps_set_mode.
  if param == nil or keMsgHdrFromPayload(param).paramLen < MmSetPsModeReqPayloadSize:
    return KeMsgConsumed
  # Scan/ROC owns the PM register until its end restores the saved value.
  # The return-to-channel or host-idle state transition requeues this command.
  if mmPsModeRequest != nil or txlResetting() or ke_state_get(TASK_MM) == HW_ACTIVE.uint16 or
      (psEnvView().statusFlags and 0x02'u32) != 0:
    return KeMsgSaved
  let mode = mmSetPsModeReqView(param).mode
  if mode != 3:
    mmPsModeRequest = param
    mmPsModeTxResetEpoch = txResetEpoch
    ps_set_mode(mode, keMsgHdrFromPayload(param).srcId)
    return KeMsgNoFree
  # PS_MODE_ON_DYN: iterate active VIF linked list from vif_mgmt_env.
  let env = vifMgmtEnvView()
  var vifNode = cast[pointer](env.activeList.first)
  while vifNode != nil:
    let vif = vifChannelAt(vifNode)
    let vifType = vif.vifType
    let psCap = vif.state
    if vifType == 0 and psCap != 0:
      # STA VIF that supports PS - poll for PS frame (blob: ps_polling_frame)
      discard ps_polling_frame(vifNode)
    vifNode = vif.next  # Follow linked list
  # Dynamic PS confirm goes back to the requester stored in ps_env[1].
  ke_msg_send_basic_reply(param, MM_SET_PS_MODE_CFM)
  KeMsgConsumed

proc mm_set_ps_mode_cfm_handler*(param: pointer): cint {.exportc, cdecl.} =
  meCompleteControl(param, MM_SET_PS_MODE_CFM)

proc mm_set_ps_options_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle MM_SET_PS_OPTIONS_REQ (132 bytes in blob, 44 instrs).
  ## From blob: a1=msg body, a2=src_id, a3=dest_id. Reads vif_idx from msg[0],
  ## computes VIF entry, asserts type==0 (STA), stores listen_interval(msg[2])
  ## and ps_options(msg[4]) to VIF, sends CFM with src/dest from original msg.
  if param == nil or keMsgHdrFromPayload(param).paramLen < MmSetPsOptionsReqPayloadSize or
      smStaleRequest(param): return KeMsgConsumed
  let req = cast[ptr MmSetPsOptionsReqPayload](param)
  let vifIdx = req.vifIdx
  # The blob indexes the VIF unchecked and halts on a VIF that is not a
  # station. Here such a request changes nothing but is still answered.
  if vifIdx < MAX_VIFS.uint8:
    let vif = vifChannelForIdx(vifIdx)
    if vif.vifType != 0:
      assert_err("vif_entry->type == VIF_STA", "module", 1680)
    else:
      # Store listen interval and PS options from msg body
      vif.listenInterval = req.listenInterval
      vif.psOptions = req.options
  # Send confirmation with original src/dest routing
  ke_msg_send_basic_reply(param, MM_SET_PS_OPTIONS_CFM)
  KeMsgConsumed

proc mm_set_vif_state_cfm_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## The answer to the activation's first request, or in state 10 the
  ## cleanup's.
  if not smTakeAnswer(param): return KeMsgConsumed
  if ke_state_get(TASK_SM) == SmDisconnectingState: smCleanupConfirmed()
  else: smActivationConfirmed()
  KeMsgConsumed

proc smActivationOptionsCfmHandler(param: pointer): cint {.cdecl.} =
  ## The answer to the activation's second request.
  if smTakeAnswer(param): smActivationConfirmed()
  KeMsgConsumed

proc mm_bcn_change_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle MM_BCN_CHANGE_REQ (22 bytes in blob).
  ## From blob: moves a1 (message body) into a0, calls mm_bcn_change, returns 1.
  let msgBody = param
  mm_bcn_change(msgBody)
  KeMsgNoFree

proc mm_bcn_change_cfm_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle MM_BCN_CHANGE_CFM: beacon change confirmed.
  ## Blob (mm_bcn.o, 66b): assert APM starting, then apm_start_cfm(0).
  let state = ke_state_get(TASK_APM)
  if not apmConsumeStartReply(param):
    return KeMsgConsumed
  if state != ApmStartingState:
    apm_start_cfm(cast[pointer](1'u))
    return KeMsgConsumed
  let failed = param != nil and keMsgHdrFromPayload(param).paramLen >=
    sizeof(MmBcnChangeCfmPayload).uint32 and
    cast[ptr MmBcnChangeCfmPayload](param).status != 0
  apm_start_cfm(if failed: cast[pointer](1'u) else: nil)
  KeMsgConsumed

proc mm_set_vif_state_cfm_handler_apm*(param: pointer): cint {.exportc, cdecl.} =
  if apmConsumeStartReply(param) and apmRollbackActive:
    apmContinueStartRollback()
  KeMsgConsumed

proc mm_tim_update_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## The TIM worker owns the message, whether it applies or queues it.
  mm_tim_update(param)
  KeMsgNoFree

proc mm_tim_update_proceed*(param: pointer) {.exportc, cdecl, noinline.} =
  ## Update the partial virtual bitmap and its two hardware descriptors.
  ## AID 0 controls multicast delivery; AIDs 1..2007 occupy the bitmap.
  if param == nil:
    return
  let saved = irqSave()
  defer: irqRestore(saved)
  let msgHdr = keMsgHdrFromPayload(param)
  let sender = msgHdr.srcId
  defer:
    ke_msg_send_basic(0x30, sender, TASK_MM)
    ke_msg_free(msgHdr)
  if not mmTimMessageCurrent(msgHdr):
    return
  if msgHdr.paramLen < MmTimUpdatePayloadSize:
    return
  let req = cast[ptr MmTimUpdatePayload](param)
  let aid = req.aid
  let setFlag = req.setFlag
  let vifIdx = req.vifIdx
  if vifIdx >= MAX_VIFS.uint8 or aid > MAX_AID.uint16:
    return
  let vif = vifChannelForIdx(vifIdx)
  if vif.vifType != VIF_TYPE_AP or vif.beaconEnabled == 0:
    return
  let bitmapBase = cast[uint](addr txl_tim_bitmap_pool[0])
  let timDesc = timDescView()
  let timIe = timIeAt(addr txl_tim_ie_pool[0])
  if aid == 0:
    # DTIM (multicast) bit at vif+330 (0x14a)
    if setFlag != 0:
      vif.timFlags = 1
    else:
      vif.timFlags = 0
  else:
    # Per-STA TIM bitmap update
    let timBitmapByteOffset = (aid shr 3).uint
    let bitIdx = (aid and 7).uint
    let mask = 1'u8 shl bitIdx
    let bitmapByte = cast[ptr uint8](bitmapBase + timBitmapByteOffset)
    let oldByte = bitmapByte[]
    let wasSet = (oldByte and mask) != 0
    if setFlag != 0:
      # Set bit
      if not wasSet:
        bitmapByte[] = oldByte or mask
        # Increment TIM count
        let timCount = vif.timCount
        vif.timCount = timCount + 1
        # Update min/max
        let curMin = vif.timMin
        let alignedByte = (timBitmapByteOffset and 0xFE'u).uint8
        if timBitmapByteOffset.uint8 < curMin:
          vif.timMin = alignedByte
          timDesc.bitmapStart = cast[pointer](bitmapBase + alignedByte.uint)
        let curMax = vif.timMax
        if timBitmapByteOffset.uint8 > curMax:
          vif.timMax = timBitmapByteOffset.uint8
          timDesc.bitmapEnd = cast[pointer](bitmapBase + timBitmapByteOffset)
        # Recompute TIM IE length
        let newMax = vif.timMax
        let newMin = vif.timMin
        var timLen = newMax.uint16 + 6 - newMin.uint16
        if timLen < 6: timLen = 6
        vif.timLength = timLen
        timIe.ie.len = (timLen - 2).uint8
        timIe.bitmapControl = newMin
        timDesc.payloadEnd = cast[pointer](addr timIe.bitmapControl)
        timDesc.next = cast[pointer](addr timDesc.bitmapMagic)
    else:
      # Clear bit
      if wasSet:
        bitmapByte[] = oldByte and not mask
        let timCount = vif.timCount
        let newCount = if timCount > 0: timCount - 1 else: 0'u16
        vif.timCount = newCount
        if newCount == 0:
          # All clear: reset TIM fields
          vif.timLength = 6  # tim_len = 6
          vif.timMin = 0xFF'u8
          vif.timMax = 0
          timIe.ie.len = 4  # partial bitmap len
          timIe.bitmapControl = 0
          timIe.partialBitmap[0] = 0
          timDesc.payloadEnd = cast[pointer](addr timIe.partialBitmap[0])
          timDesc.next = timDesc.bitmapNext
          timDesc.bitmapStart = cast[pointer](bitmapBase)
          timDesc.bitmapEnd = cast[pointer](bitmapBase)
        else:
          # Adjust min: scan upward for first non-zero byte
          var curMin = vif.timMin
          let alignedByte = (timBitmapByteOffset and 0xFE'u).uint8
          if curMin == alignedByte:
            while curMin < (MAX_AID shr 3).uint8:
              if cast[ptr uint8](bitmapBase + curMin.uint)[] != 0:
                break
              curMin = curMin + 1
            vif.timMin = curMin and 0xFE'u8
            timDesc.bitmapStart = cast[pointer](bitmapBase + (curMin and 0xFE'u8).uint)
          # Adjust max: scan downward for first non-zero byte
          var curMax = vif.timMax
          if curMax == timBitmapByteOffset.uint8:
            while curMax > 0:
              if cast[ptr uint8](bitmapBase + curMax.uint)[] != 0:
                break
              curMax = curMax - 1
            vif.timMax = curMax
            timDesc.bitmapEnd = cast[pointer](bitmapBase + curMax.uint)
          # Recompute TIM IE length
          let finalMax = vif.timMax
          let finalMin = vif.timMin
          var timLen = finalMax.uint16 + 6 - finalMin.uint16
          if timLen < 6: timLen = 6
          vif.timLength = timLen
          timIe.ie.len = (timLen - 2).uint8
          timIe.bitmapControl = finalMin

proc mm_connection_loss_ind_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle connection loss indication (116 bytes in blob, sm_task.o).
  ## Blob: ke_state_get(SM), check VIF type/active, ke_state_set(SM,10),
  ## sm_connection_tlv_set, sm_disconnect_process(vif, reason, 0xFFFF).
  ## Here sm_disconnect_process enters state 10 once its cleanup has claimed
  ## the link.
  if param == nil: return KeMsgConsumed
  let saved = irqSave()
  let tag = mmConnLossTagFor(param)
  if tag == nil:
    irqRestore(saved)
    return KeMsgConsumed
  # The saved-message queue can retry this indication after a new connection
  # starts. Check its producer identity before asking the kernel to save it.
  if ke_state_get(TASK_SM) != SmIdleState:
    irqRestore(saved)
    return KeMsgSaved
  let vif = tag.identity.vif
  let reason = tag.reason
  tag.consumed = true
  irqRestore(saved)
  if vifChannelAt(vif).vifType != VIF_TYPE_STA or vifChannelAt(vif).state == 0:
    return KeMsgConsumed
  sm_connection_tlv_set()
  sm_disconnect_process(vif, reason, 0xFFFF'u16)
  return 0

proc mm_bss_param_setting_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## The answer to one of the BSS batch's MM requests sends the next one.
  ## Only SM's live answer is taken, so SM is in state 4 (pinned: assert
  ## 663).
  if smTakeAnswer(param): sm_send_next_bss_param()
  return 0

proc mm_bss_param_setting_handler_apm*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle AP BSS parameter-setting confirmations.
  if apmConsumeStartReply(param):
    if apmRollbackActive:
      apmContinueStartRollback()
    elif ke_state_get(TASK_APM) == ApmActiveState:
      apm_send_next_bss_param(param)
    else:
      apm_start_cfm(cast[pointer](1'u))
  return KeMsgConsumed

proc mm_force_idle_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle force-idle request — 120 bytes / 30 instrs in blob mm_task.o.
  ##
  ## Blob flow:
  ##   state = ke_state_get(TASK_MM)
  ##   if state == 0  → .L65:
  ##     if (*(u32*)0x24B00038 & 0xF) != 0: assert_err(line 1013)
  ##     ke_state_set(TASK_MM, 3)
  ##     cb = *(void**)param; cb()
  ##     return KE_MSG_CONSUMED
  ##   elif state == 2 → return KE_MSG_SAVED
  ##   else            → hal_machw_idle_req(); ke_state_set(TASK_MM, 2);
  ##                     return KE_MSG_SAVED
  ##
  ## Previous Nim inserted a ke_msg_alloc + ke_msg_send MM_FORCE_IDLE_CFM
  ## at the state==0 path that the blob never issues. The blob's "status"
  ## is returned only via the callback (s0 return value is 0 on success).
  ##
  ## Port: the channel switch's request is static and is never freed
  ## (chanSwitchTake). A MAC that is not idle in MM_IDLE asserts as in the
  ## blob, but the request stays saved instead of being dropped; the posted
  ## recovery reschedules MM's saved messages.
  if param == nil or keMsgHdrFromPayload(param).paramLen < 4: return KeMsgConsumed
  let state = ke_state_get(TASK_MM)
  if state == MM_IDLE.uint16:
    if (regRead(MACHW_STATE_CNTRL_REG) and 0xF'u32) != 0:
      assert_err("blmac_current_state_getf() == HW_IDLE", "module", 1013)
      return KeMsgSaved
    let consumed = chanSwitchTake(param)
    mmConfigCancelIdle()
    ke_state_set(TASK_MM, HW_ACTIVE.uint16)
    let callbackPtr = cast[ptr pointer](param)[]
    if callbackPtr != nil:
      cast[proc() {.cdecl.}](callbackPtr)()
    return consumed
  elif state == MM_GOING_TO_IDLE.uint16:
    return KeMsgSaved
  else:
    let saved = irqSave()
    defer: irqRestore(saved)
    hal_machw_idle_req()
    ke_state_set(TASK_MM, MM_GOING_TO_IDLE)
    return KeMsgSaved

proc mm_remain_on_channel_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Return the ROC status to the original sender with operation and slot ID.
  if param == nil: return KeMsgConsumed
  if not chanBcnRequestAdmit(param): return KeMsgConsumed
  let hdr = keMsgHdrFromPayload(param)
  if hdr.paramLen < MmRemainOnChannelReqPayloadSize: return KeMsgConsumed
  let src = hdr.srcId
  let dest = hdr.destId
  let operation = mmRemainOnChannelReqView(param).opCode
  let status = chan_roc_req(param, src)
  if src == 0:
    return KeMsgConsumed
  let cfm = cast[ptr MmRemainOnChannelCfmPayload](
    ke_msg_alloc(MM_REMAIN_ON_CHANNEL_CFM, src, dest,
                 MmRemainOnChannelCfmPayloadSize))
  if cfm != nil:
    cfm.opCode = operation
    cfm.status = status
    cfm.ctxtIdx = 4
    ke_msg_send(cfm)
  return KeMsgConsumed

proc mm_monitor_enable_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle monitor mode enable request (198 bytes in blob, 48 instrs).
  ## From blob: allocates MM_MONITOR_CFM (id=71, 40 bytes). Fills payload with
  ## debug magic values (0x11111111..0x77777777). Copies channel band from req.
  ## Initializes PHY, sets channel to 2437MHz (channel 6), activates MAC HW,
  ## sets cfm[0]=0 (success), sends cfm.
  if param == nil: return KeMsgConsumed
  let request = keMsgHdrFromPayload(param)
  if request.paramLen < MmMonitorReqPayloadSize: return KeMsgConsumed
  let channel = mmMonitorReqView(param).channel
  let cfm = cast[ptr MmMonitorCfmPayload](
    ke_msg_alloc(MM_MONITOR_CFM, request.srcId, request.destId,
                 MmMonitorCfmPayloadSize))
  if cfm != nil:
    cfm.status = 1'u32
    cfm.debugReserved = 0'u32
    cfm.debug1 = 0x11111111'u32
    cfm.debug2 = 0x22222222'u32
    cfm.debug3 = 0x33333333'u32
    cfm.debug4 = 0x44444444'u32
    cfm.debug5 = 0x55555555'u32
    cfm.debug6 = 0x66666666'u32
    cfm.debug7 = 0x77777777'u32
    # Copy channel band from request
    cfm.channel = channel
    # Initialize PHY with zeroed config buffer, then set channel
    var phyCfg: array[64, uint8]
    discard c_memset(addr phyCfg[0], 0, 64.csize_t)
    phyCfg[0] = 0
    phy_init(addr phyCfg[0])
    phySetChannel(0, 0, 2437, 2437, 0, 0)
    mm_active()
    # Mark success and send
    cfm.status = 0'u32
    ke_msg_send(cfm)
  return 0

proc mm_monitor_channel_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle monitor channel request (162 bytes in blob, ~42 instrs).
  ## From blob (mm_task.o): Nearly identical to mm_monitor_enable_req_handler.
  ## Allocs MM_MONITOR_CHANNEL_CFM (id=73, 40 bytes). Fills payload with
  ## debug magic values (0x11111111..0x77777777). Reads channel freq from
  ## req as a word, stores to cfm[4]. Calls phy_set_channel with the freq.
  ## Sets cfm[0]=0 (success), sends cfm.
  if param == nil: return KeMsgConsumed
  let request = keMsgHdrFromPayload(param)
  if request.paramLen < MmMonitorReqPayloadSize: return KeMsgConsumed
  let channel = mmMonitorReqView(param).channel
  let cfm = cast[ptr MmMonitorCfmPayload](
    ke_msg_alloc(MM_MONITOR_CHANNEL_CFM, request.srcId, request.destId,
                 MmMonitorCfmPayloadSize))
  if cfm != nil:
    cfm.status = 1'u32
    cfm.debugReserved = 0'u32
    cfm.debug1 = 0x11111111'u32
    cfm.debug2 = 0x22222222'u32
    cfm.debug3 = 0x33333333'u32
    cfm.debug4 = 0x44444444'u32
    cfm.debug5 = 0x55555555'u32
    cfm.debug6 = 0x66666666'u32
    cfm.debug7 = 0x77777777'u32
    # Read channel info from request and store
    let chanFreq = uint16(channel and 0xFFFF'u32)
    cfm.channel = channel
    # Set channel
    phySetChannel(0, 0, chanFreq, chanFreq, 0, 0)
    # Mark success and send
    cfm.status = 0'u32
    ke_msg_send(cfm)
  return 0

proc scanChannelRxFilterBits*(passiveFlag: uint8): uint32 {.inline.} =
  if (passiveFlag and 1) == 0:
    SCAN_ACTIVE_RX_FILTER_BITS
  else:
    SCAN_PASSIVE_RX_FILTER_BITS

proc applyScanChannelRxFilter*(passiveFlag: uint8) {.inline.} =
  let mm = mmEnvView()
  let rxFlags = mm.rxFilterExtra or scanChannelRxFilterBits(passiveFlag)
  mm.rxFilterExtra = rxFlags
  regWrite(MACHW_RX_CNTRL_REG, rxFlags or mm.rxFilterBase)
  rfPhyTraceCheckpoint(0x4F'u32)
  nimFwScanRxFilterProbe()

type ScanProbeTimerContext = tuple[param: pointer, epoch: uint32, channel: uint8]

proc scanProbeTimerCurrent(context: pointer): bool {.nimcall.} =
  let owner = cast[ptr ScanProbeTimerContext](context)
  scan_env.paramPtr == owner.param and scanRequestEpoch == owner.epoch and
    scan_env.channelIndex == owner.channel and
    ke_state_get(TASK_SCAN) == ScanChannelPendingState

proc scheduleActiveScanProbeTimer*(scanParam: pointer; requestEpoch: uint32;
                                   channelIndex: uint8): bool {.inline.} =
  var owner: ScanProbeTimerContext = (scanParam, requestEpoch, channelIndex)
  template current(): bool = scanProbeTimerCurrent(addr owner)
  if scan_probe_req_tx() != 0:
    let logFn = cast[proc(format: cstring) {.cdecl, varargs.}](blOpsFunc(4))
    if logFn != nil:
      logFn("scan_probe_req_tx f\r\n")
  if not current(): return false
  let duration = scan_get_scan_duration()
  if not current(): return false
  let delay = duration shr 1
  # The channel timer ends the dwell independently of this optional retry.
  if delay != 0 and delay <= KE_TIMER_MAX_DELAY:
    discard ke_timer_try_set(SCAN_PROBE_TIMER, TASK_SCAN, delay)
  current()

proc scanTaskInChannelRunningState*(): bool {.inline.} =
  ke_state_get(TASK_SCAN) == ScanChannelRunningState

proc enterScanChannelRunningState*() {.inline.} =
  ke_state_set(TASK_SCAN, ScanChannelRunningState)

proc sendPeriodicScanProbeRequest*(): uint8 {.inline.} =
  scan_probe_req_tx()

proc mm_scan_channel_start_ind_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle scan channel start indication (68 instrs in blob).
  ## From blob (scan_task.o): checks ke_state_get(SCAN)==2 (asserts), reads scan
  ## config, sets EDCA params with passive/active flag, writes to MACHW RX filter
  ## register (0x24B00060), optionally sends active-scan probe requests, arms
  ## SCAN_PROBE_TIMER, and sets ke_state(SCAN, 3).
  if not scanDwellClaim(param): return KeMsgConsumed
  let state = ke_state_get(TASK_SCAN)
  if state != ScanChannelPendingState:
    assert_err("scan_task.c", "scan_task.c", 159)
    return KeMsgConsumed
  # Read scan env parameters
  let scanParam = scan_env.paramPtr
  if scanParam == nil: return KeMsgConsumed
  let requestEpoch = scanRequestEpoch
  let currentChannel = scan_env.channelIndex
  template current(): bool =
    scan_env.paramPtr == scanParam and scanRequestEpoch == requestEpoch and
      scan_env.channelIndex == currentChannel and
      ke_state_get(TASK_SCAN) == ScanChannelPendingState
  # Set EDCA params for scan: check passive flag (param byte 3, bit 0)
  let scanReq = scanStartReqView(scanParam)
  if scan_env.channelIndex >= scanReq.channelCount or
      scan_env.channelIndex.int >= scanReq.channelList.len:
    return KeMsgConsumed
  let passiveFlag = scanReq.channelList[scan_env.channelIndex.int].flags
  applyScanChannelRxFilter(passiveFlag)
  if not current(): return KeMsgConsumed
  nimFwDbgScanStartRxCtrl = regRead(MACHW_RX_CNTRL_REG)
  nimFwDbgScanStartIrqRaw = regRead(MACHW_INTC_STATUS_RAW)
  nimFwDbgScanStartGenRaw = regRead(MACHW_INTC_GEN_RAW)
  snapshotPhyChannel(nimFwDbgScanStartPhyRaw)
  rfPhyTraceCheckpoint(0x50'u32)
  if not current(): return KeMsgConsumed
  # Active scan: send probe requests and set scan timer
  if (passiveFlag and 1) == 0:
    if not scheduleActiveScanProbeTimer(scanParam, requestEpoch, currentChannel):
      return KeMsgConsumed
  if not current(): return KeMsgConsumed
  enterScanChannelRunningState()
  when defined(bl808WifiDiagWarmScan): inc nimFwDbgWarmScan.start_handled
  return KeMsgConsumed

proc clearScanEdcaRxFilter*() {.inline.} =
  let mm = mmEnvView()
  let rxFlags = mm.rxFilterExtra and SCAN_EDCA_RX_FILTER_CLEAR_MASK
  mm.rxFilterExtra = rxFlags
  regWrite(MACHW_RX_CNTRL_REG, rxFlags or mm.rxFilterBase)

proc advanceScanChannelIndex*(): uint8 {.inline.} =
  let chanIdx = scan_env.channelIndex + 1
  scan_env.channelIndex = chanIdx
  chanIdx

proc scanChannelSequenceDone*(chanIdx, totalChans, abortFlag: uint8): bool {.inline.} =
  chanIdx >= totalChans or abortFlag != 0

proc forwardFailedScanDwell(scanParam: pointer; requester: uint8) =
  when defined(bl808WifiDiagWarmScan):
    inc nimFwDbgWarmScan.lower_replies
    nimFwDbgWarmScanLowerStatus = SCAN_STATUS_FAIL.uint32
  keMsgHdrFromPayload(scanParam).paramLen = StatusCfmPayloadSize
  statusCfmView(scanParam).status = SCAN_STATUS_FAIL
  scanuTrackLowerReply(scanParam, scanParam, done = false)
  ke_msg_forward_and_change_id(scanParam, SCAN_START_CFM, requester, TASK_SCAN)

proc releaseCompletedScanRequest*(scanParam: pointer;
                                  expectedEpoch = scanRequestEpoch;
                                  endInd: pointer = nil; failed = false): bool
    {.inline, discardable.} =
  let saved = irqSave()
  if scanParam == nil or scan_env.paramPtr != scanParam or
      scanRequestEpoch != expectedEpoch:
    irqRestore(saved)
    return false
  let requester = scan_env.requester
  var unused: ScanDwellPair
  if scanDwellRequest == scanParam and scanDwellEpoch == expectedEpoch:
    unused = scanDwellDetach()
  inc scanRequestEpoch
  let detachedEpoch = scanRequestEpoch
  scan_env.paramPtr = nil
  scan_env.abortFlag = 0
  # Queue the old completion while this task is still running. A replacement
  # request may start when the old message is freed below.
  if failed:
    # The next dwell could not be reserved. Do not report the band as fully
    # scanned: SCANU's normal nonzero START_CFM path completes it with error.
    forwardFailedScanDwell(scanParam, requester)
  elif endInd != nil:
    scanuTrackLowerReply(scanParam, endInd, done = true)
    ke_msg_forward_and_change_id(endInd, SCAN_DONE_IND, requester, TASK_SCAN)
  else:
    # No usable end envelope. Reuse the retained lower request; terminal
    # publication must not silently depend on another allocation.
    keMsgHdrFromPayload(scanParam).paramLen = 0
    scanuTrackLowerReply(scanParam, scanParam, done = true)
    ke_msg_forward_and_change_id(scanParam, SCAN_DONE_IND, requester, TASK_SCAN)
  if scan_env.paramPtr == nil and scanRequestEpoch == detachedEpoch and
      ke_state_get(TASK_SCAN) == ScanChannelRunningState:
    ke_state_set(TASK_SCAN, ScanIdleState)
  irqRestore(saved)
  if not failed and endInd != nil: ke_msg_free(keMsgHdrFromPayload(scanParam))
  scanDwellDispose(unused)
  true

proc mm_scan_channel_end_ind_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle scan channel end indication (68 instrs in blob).
  ## From blob (scan_task.o): checks ke_state_get(SCAN)==3 (asserts). Clears EDCA
  ## scan flags in chan config. Writes cleared value to MACHW register (0x24B00060).
  ## Increments scan channel index (scan_env[9]). If index >= total channels
  ## OR abort flag set, sends scan done msg and resets. Otherwise calls
  ## scan_set_channel_request for next channel.
  if not scanDwellClaim(param): return KeMsgConsumed
  let state = ke_state_get(TASK_SCAN)
  if state != ScanChannelRunningState:
    assert_err("scan_task.c", "scan_task.c", 234)
    return KeMsgConsumed
  let scanParam = scan_env.paramPtr
  if scanParam == nil:
    return KeMsgConsumed
  let requestEpoch = scanRequestEpoch
  let currentChannel = scan_env.channelIndex
  let scanReq = scanStartReqView(scanParam)
  if scan_env.channelIndex >= scanReq.channelCount or
      scan_env.channelIndex.int >= scanReq.channelList.len:
    return KeMsgConsumed
  # The vendor clears the probe timer before advancing the channel.
  ke_timer_clear(SCAN_PROBE_TIMER, TASK_SCAN)
  if scan_env.paramPtr != scanParam or scanRequestEpoch != requestEpoch or
      scan_env.channelIndex != currentChannel or
      ke_state_get(TASK_SCAN) != ScanChannelRunningState:
    return KeMsgConsumed
  clearScanEdcaRxFilter()
  nimFwDbgScanEndRxCtrl = regRead(MACHW_RX_CNTRL_REG)
  nimFwDbgScanEndIrqRaw = regRead(MACHW_INTC_STATUS_RAW)
  nimFwDbgScanEndGenRaw = regRead(MACHW_INTC_GEN_RAW)
  snapshotPhyChannel(nimFwDbgScanEndPhyRaw)
  rfPhyTraceCheckpoint(0x51'u32)
  if scan_env.paramPtr != scanParam or scanRequestEpoch != requestEpoch or
      scan_env.channelIndex != currentChannel:
    return KeMsgConsumed
  when defined(bl808WifiDiagWarmScan): inc nimFwDbgWarmScan.end_handled
  let chanIdx = advanceScanChannelIndex()
  let totalChans = scanReq.channelCount
  let abortFlag = scan_env.abortFlag
  var pair: ScanDwellPair
  defer: scanDwellDispose(pair)
  if not scanChannelSequenceDone(chanIdx, totalChans, abortFlag):
    let serial = scanDwellSerial
    let ready = scanDwellReserve(pair)
    let saved = irqSave()
    defer: irqRestore(saved)
    if scan_env.paramPtr != scanParam or scanRequestEpoch != requestEpoch or
        scan_env.channelIndex != chanIdx or serial != scanDwellSerial:
      return KeMsgConsumed
    if scan_env.abortFlag == 0:
      if ready and chanScanPoolOverlay().slot == 0xFF:
        scanDwellInstall(pair, chanCtxtEpochs[3] + 1'u32)
        let installed = scanDwellSerial
        irqRestore(saved)
        try:
          if scanDwellSerial == installed and scanDwellCurrent(): scan_set_channel_request()
        finally: discard irqSave()
      else:
        discard releaseCompletedScanRequest(scanParam, requestEpoch, failed = true)
      return KeMsgConsumed
    # Cancellation during allocation uses the ordinary terminal indication.
  # A basic end envelope can carry the terminal indication without allocation.
  if param != nil:
    let hdr = keMsgHdrFromPayload(param)
    if hdr.id == MM_SCAN_CHANNEL_END_IND and hdr.destId == TASK_SCAN and hdr.paramLen == 0:
      if releaseCompletedScanRequest(scanParam, requestEpoch, param): return KeMsgNoFree
      return KeMsgConsumed
  discard releaseCompletedScanRequest(scanParam, requestEpoch)
  return KeMsgConsumed

proc mm_scan_channel_end_early_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## End the current scan dwell early for quick connect.
  ## The blob (scan_task.o, 19 instrs) asserts at line 186 when TASK_SCAN is
  ## idle and otherwise ends whatever dwell is running. The message can be
  ## dispatched after its dwell finished, so only the dwell that asked is ended
  ## and a late message is dropped instead of asserting.
  if not scanEarlyEndClaim() or ke_state_get(TASK_SCAN) == ScanIdleState:
    return KeMsgConsumed
  scan_terminate_channel_request()
  return KeMsgConsumed

# --- Scan Task Handlers (scan_task.o) ---

when defined(bl808WifiDiagWarmScan):
  proc nimFwWarmScanState*(): uint32 =
    let saved = irqSave()
    defer: irqRestore(saved)
    let chan = chanEnvView()
    # Flags, slot, SCAN state, SCANU state, and live scheduled context.
    chan.flags.uint32 or (chanScanPoolOverlay().slot.uint32 shl 8) or
      (ke_state_get(TASK_SCAN).uint32 shl 16) or
      (ke_state_get(TASK_SCANU).uint32 shl 24) or
      ((chan.scheduledCtxt != nil).uint32 shl 31)

proc scanDurationOrDefault*(duration: uint32): uint32 {.inline.} =
  if duration != 0:
    duration
  else:
    SCAN_DEFAULT_DURATION_US

proc cacheScanStartDurations*(scanReq: ptr ScanStartReqPayload) {.inline.} =
  let duration = scanDurationOrDefault(scanReq.addIeLen)
  scan_env.passiveDuration = duration
  scan_env.activeDuration = duration

proc cacheScanStartContext*(param: pointer, requester: uint8) {.inline.} =
  let saved = irqSave()
  defer: irqRestore(saved)
  inc scanRequestEpoch
  scan_env.channelIndex = 0
  scan_env.abortFlag = 0
  scan_env.requester = requester
  scan_env.paramPtr = param

proc scanStartRequestValid*(paramLen: uint32;
                            scanReq: ptr ScanStartReqPayload): bool {.inline.} =
  ## The archive assumes a complete request and asserts only on zero channels.
  ## Reject malformed lower-MAC messages before indexing channels or IEs.
  if paramLen < ScanStartReqPayloadSize or scanReq == nil:
    return false
  # The duration at request offset 312 is stored in a 16-bit dwell slot.
  if (scanReq.addIeLen shr 10) > high(uint16).uint32:
    return false
  if scanReq.channelCount == 0 or
      scanReq.channelCount.int > scanReq.channelList.len or
      scanReq.vifIdx >= MAX_VIFS.uint8 or
      scanReq.scanType > 1 or
      (scanReq.scanType != 0 and scanReq.ssidFilter[0] > 32) or
      scanReq.ieBodyLen.int > scan_probe_req_ie.ieData.len:
    return false
  for channelIndex in 0 ..< scanReq.channelCount.int:
    let channel = scanReq.channelList[channelIndex]
    if not scanChannelValid(channel.band, channel.prim20Freq):
      return false
  if not probeIesValid(addr scan_probe_req_ie.ieData[0], scanReq.ieBodyLen.uint32):
    return false
  true

proc sendScanStartConfirmation*(cfm: pointer, status: uint8) {.inline.} =
  if cfm != nil:
    when defined(bl808WifiDiagWarmScan):
      inc nimFwDbgWarmScan.lower_replies
      nimFwDbgWarmScanLowerStatus = status.uint32
    statusCfmView(cfm).status = status
    ke_msg_send(cfm)

proc finishAcceptedScanStartReq*(param: pointer): cint {.inline.} =
  scan_ie_download(param)
  return KeMsgNoFree

proc cacheScanuStartRequest*(
    param: pointer,
    req: ptr ScanuStartReqPayload,
    requester: uint8
): uint32 {.inline.} =
  # Invariant (post idle-guard): paramPtr is nil here because scanu_confirm nil'd
  # it at the previous op's completion. A non-nil, different value means an
  # overlap slipped past the guard -> free the abandoned block so it can never
  # dangle, and flag it (nimFwDbgScanuParamOverwrite MUST stay 0 after the fix).
  let previousProducer = scanuProducerRequest
  let previousProducerEpoch = scanuProducerEpoch
  defer:
    scanuProducerRequest = previousProducer
    scanuProducerEpoch = previousProducerEpoch
  var abandoned: pointer
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    if scanu_env.paramPtr != param:
      abandoned = scanu_env.paramPtr
    inc scanuRequestEpoch
    result = scanuRequestEpoch
    scanuProducerRequest = param
    scanuProducerEpoch = result
    scanu_env.paramPtr = param
    scanu_env.pendingJoinRxuMgtInd = nil
    scanu_env.bssidFilterEnabled = 0
    scanu_env.scanBand = 0
    scanu_env.resultState = 0
    scanu_env.directedFound = 0
    scanu_env.requester = requester
    scanu_env.filterBssid = req.bssid
    ke_state_set(TASK_SCANU, ScanuScanningState)
  if abandoned != nil:
    inc nimFwDbgScanuParamOverwrite
    ke_msg_free(keMsgHdrFromPayload(abandoned))

proc scan_start_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SCAN_START_REQ (170 bytes in blob, 45 instrs).
  ## From blob (scan_task.o): allocs SCAN_START_CFM (id=0x401, 1 byte).
  ## Checks scan state; if busy: cfm->status=8. If idle, the vendor asserts
  ## chan_cnt>0; this implementation rejects malformed requests before it
  ## stores scan params in scan_env (param@0, src_id@8, channelIndex@9,
  ## active/passive durations@12/@16), calls scan_ie_download, sends cfm.
  ## Returns KeMsgNoFree on success to keep req message alive.
  ## The request pointer also marks the pre-state-change submission interval.
  if param == nil:
    return KeMsgConsumed
  let reqHdr = keMsgHdrFromPayload(param)
  let requester = reqHdr.srcId
  if requester == TASK_SCANU and not scanuLowerCurrent(param):
    return KeMsgConsumed
  let cfm = ke_msg_try_alloc(SCAN_START_CFM, requester, TASK_SCAN,
                             StatusCfmPayloadSize)
  if requester == TASK_SCANU and not scanuLowerCurrent(param):
    if cfm != nil: ke_msg_free(keMsgHdrFromPayload(cfm))
    return KeMsgConsumed
  if cfm == nil:
    if reqHdr.paramLen < StatusCfmPayloadSize:
      return KeMsgConsumed
    # This request never entered the lower scan state. Return it as the
    # failure reply so SCANU can complete without another allocation.
    when defined(bl808WifiDiagWarmScan):
      inc nimFwDbgWarmScan.lower_replies
      nimFwDbgWarmScanLowerStatus = SCAN_STATUS_FAIL.uint32
    statusCfmView(param).status = SCAN_STATUS_FAIL
    reqHdr.paramLen = StatusCfmPayloadSize
    scanuTrackLowerReply(param, param, done = false)
    ke_msg_forward_and_change_id(param, SCAN_START_CFM, requester, TASK_SCAN)
    return KeMsgNoFree
  let scanState = ke_state_get(TASK_SCAN)
  var cfmStatus = SCAN_STATUS_OK
  var doDownload = true
  var admittedEpoch: uint32
  var admittedReset: uint32
  var pair: ScanDwellPair
  defer: scanDwellDispose(pair)
  if scanState != ScanIdleState or scan_env.paramPtr != nil or chanScanPoolOverlay().slot != 0xFF:
    cfmStatus = SCAN_STATUS_BUSY
    doDownload = false
  else:
    let scanReq = scanStartReqView(param)
    if not scanStartRequestValid(reqHdr.paramLen, scanReq):
      cfmStatus = SCAN_STATUS_BAD_PARAM
      doDownload = false
    else:
      let lowerEpoch = scanRequestEpoch
      let serial = scanDwellSerial
      let ready = scanDwellReserve(pair)
      let saved = irqSave()
      defer: irqRestore(saved)
      if requester == TASK_SCANU and not scanuLowerCurrent(param):
        ke_msg_free(keMsgHdrFromPayload(cfm))
        return KeMsgConsumed
      if lowerEpoch != scanRequestEpoch or serial != scanDwellSerial or
          scan_env.paramPtr != nil or ke_state_get(TASK_SCAN) != ScanIdleState or
          chanScanPoolOverlay().slot != 0xFF:
        cfmStatus = SCAN_STATUS_BUSY
        doDownload = false
      elif not ready:
        cfmStatus = SCAN_STATUS_FAIL
        doDownload = false
      else:
        cacheScanStartContext(param, requester)
        admittedEpoch = scanRequestEpoch
        admittedReset = scanDwellResetEpoch
        cacheScanStartDurations(scanReq)
        scanDwellInstall(pair, chanCtxtEpochs[3] + 1'u32, admitting = true)
  # The accepted path finishes channel setup before publishing its confirmation.
  var handlerResult = KeMsgConsumed
  if doDownload:
    handlerResult = KeMsgNoFree
    if scan_env.paramPtr == param and scanRequestEpoch == admittedEpoch:
      handlerResult = finishAcceptedScanStartReq(param)
    if scanDwellResetEpoch != admittedReset: cfmStatus = SCAN_STATUS_FAIL
  if requester == TASK_SCANU:
    # A terminal failure during inline dwell setup already owns the reply.
    if not scanuLowerCurrent(param) or scanuLower.startCfm != nil:
      ke_msg_free(keMsgHdrFromPayload(cfm))
      return handlerResult
    scanuTrackLowerReply(param, cfm, done = false)
  sendScanStartConfirmation(cfm, cfmStatus)
  return handlerResult

proc scan_start_cfm_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SCAN_START_CFM (30 bytes in blob).
  ## From blob: reads status byte from msg body (a1). If non-zero (error),
  ## tail-calls scanu_confirm(status). Returns 0.
  let saved = irqSave()
  defer: irqRestore(saved)
  if not scanuClaimLowerReply(param, done = false) or
      keMsgHdrFromPayload(param).paramLen < StatusCfmPayloadSize:
    return KeMsgConsumed
  let status = statusCfmView(param).status
  if status != 0:
    scanu_confirm(status)
  return KeMsgConsumed

proc advanceScanuScanBand*() {.inline.} =
  scanu_env.scanBand = scanu_env.scanBand + 1
  scanu_scan_next()

proc scan_done_ind_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SCAN_DONE_IND (164 bytes in blob, 40 instrs).
  ## From blob (scanu_task.o): if join mode has a pending cached RXU_MGT_IND at
  ## scanu_env+0xac, sends SCANU_JOIN_CFM and clears cached scan results.
  ## Otherwise it advances the band/phase byte at +0xb5 and lets
  ## scanu_scan_next either start the next phase or issue SCANU_START_CFM.
  var completedRequest: pointer
  var completedEpoch: uint32
  var reqSrcId: uint8
  var retired: array[SCANU_MAX_RESULT_ENTRIES, pointer]
  # Request and cache ownership move together before the task becomes idle.
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    if scanu_env.paramPtr == nil: return KeMsgConsumed
    let replayDone = scanu_env.pendingJoinRxuMgtInd
    if replayDone != nil:
      if param != replayDone: return KeMsgConsumed
      completedRequest = scanu_env.paramPtr
      reqSrcId = scanu_env.requester
      retired = scanuDetachCachedScanResults()
      inc scanuRequestEpoch
      completedEpoch = scanuRequestEpoch
      scanu_env.paramPtr = nil
      scanu_env.pendingJoinRxuMgtInd = nil
    else:
      if scanuClaimLowerReply(param, done = true):
        advanceScanuScanBand()
      return KeMsgConsumed
  defer: scanuReleaseCompletedOwner(completedEpoch)
  for frame in retired:
    ke_msg_free_payload(frame)
  scanuPublishCompletion(completedRequest, scanuReply(SCANU_JOIN_CFM, reqSrcId),
                         SCANU_JOIN_CFM, reqSrcId, 0)
  return KeMsgConsumed

proc scan_cancel_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SCAN_CANCEL_REQ: cancel ongoing scan.
  ## From blob (scan_task.o, ~20 instrs): checks ke_state_get(TASK_SCAN).
  ## If scan is active (state != 0), sets scan_env.abort (offset 0x0a) = 1
  ## and returns. If scan is idle, calls scan_send_cancel_cfm(status=1, src_id)
  ## so the requester still gets a confirmation.
  ## Ownership covers the pre-state-change interval; a detached request is
  ## already complete even if its task state has not yet changed to idle.
  if param == nil:
    return KeMsgConsumed
  if scan_env.paramPtr != nil:
    scan_env.abortFlag = 1
  else:
    scan_send_cancel_cfm(1, keMsgHdrFromPayload(param).srcId)
  return KeMsgConsumed

const SmScanAbortPayloadSize = sizeof(uint32).uint32

proc smAbortOwnsLowerScan(): bool =
  ## The lower scan running is the one SM's live scan request started.
  scanuLowerCurrent(scan_env.paramPtr) and smAwaits(scanu_env.paramPtr)

proc scan_abort_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SCAN_ABORT_REQ — blob scan_task.o (74 bytes):
  ##   state = ke_state_get(TASK_SCAN)
  ##   if state != 0:
  ##     scan_env[10] = 1                      # abort flag
  ##     if state == 3:
  ##       scan_terminate_channel_request()
  ##   g_bl_ops_funcs[1](.LC0, .LANCHOR0)      # formatted log, always
  ## Blob does NOT emit a SCAN_ABORT_CFM or call ke_state_set — previous
  ## Nim invented both, which meant an extra IPC message + premature
  ## scan-state reset on every abort.
  ## An owned request also counts as active during channel submission.
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    if param != nil:
      let header = keMsgHdrFromPayload(param)
      if header.srcId == TASK_SM and (header.paramLen != SmScanAbortPayloadSize or
          cast[ptr uint32](param)[] != scanRequestEpoch or not smAbortOwnsLowerScan()):
        return KeMsgConsumed
    if scan_env.paramPtr != nil:
      scan_env.abortFlag = 1
      if ke_state_get(TASK_SCAN) == ScanChannelRunningState:
        scan_terminate_channel_request()
  let logPtr = blOpsFunc(4)
  if logPtr != nil:
    cast[proc(format, name: cstring) {.cdecl, varargs.}](logPtr)(
      "%s: scan_abort_req_handler done\r\n", "scan_abort_req_handler")
  return KeMsgConsumed

proc scan_probe_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Probe-req periodic handler.
  ## Blob algorithm:
  ##   if ke_state_get(TASK_SCAN) != 3: return 0
  ##   ret = scan_probe_req_tx()
  ##   if ret != 0:
  ##     g_bl_ops_funcs[1]("scan_probe_req_tx failed!\r\n")
  ##   return 0
  ## Prior Nim bug: read scan_env[0] and logged nothing useful. The blob
  ## does the actual probe-request TX via scan_probe_req_tx.
  if not scanTaskInChannelRunningState():
    return KeMsgConsumed
  if sendPeriodicScanProbeRequest() != 0:
    let logFn = cast[proc(format: cstring) {.cdecl, varargs.}](blOpsFunc(4))
    if logFn != nil:
      logFn("scan_probe_req_tx failed!\r\n")
  return KeMsgConsumed

# --- SCANU Task Handlers (scanu_task.o) ---

proc scanu_start_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SCANU_START_REQ: initiate upper-MAC scan.
  ## From blob (scanu_task.o, 34 instrs):
  ##   1. Store param pointer into scanu_env[0] (paramPtr)
  ##   2. Zero scanu_env[180] (joinFlag, half-word)
  ##   3. Clear scanu_env[222] and scanu_env[228] (result state bytes)
  ##   4. Store source task id into scanu_env[176]
  ##   5. Copy 6 bytes from param+286 (BSSID filter) into scanu_env+182
  ##   6. Tail-call scanu_start(), returns KeMsgNoFree
  if param == nil: return KeMsgConsumed
  let reqHdr = keMsgHdrFromPayload(param)
  if reqHdr.paramLen < ScanuStartReqPayloadSize:
    return KeMsgConsumed
  if smScanRefused(param): return KeMsgNoFree
  let saved = irqSave()
  # Upper scanu owns a SINGLE scanu_env.paramPtr slot. If a new SCANU_START_REQ
  # arrives while a scan/join is still in flight (state != idle), overwriting
  # paramPtr abandons the in-flight ke_msg and makes scanu_confirm's real free
  # (scan_station_ap_me.nim:300) target the wrong/still-live block -> a
  # use-after-free on the shared TLSF heap (the freed ke_msg is reused by Nim
  # ARC, then a stale scanu access corrupts the Nim object -> nimIncRef fault).
  # The lower scan_start_req_handler already busy-rejects (:1074); the upper task
  # lost that guard. Reject the overlap; the dispatcher frees the req (:809), so
  # no leak. Use the rejected request as a busy confirmation so the host
  # completes its wait without allocating or touching the active scan.
  if ke_state_get(TASK_SCANU) != ScanuIdleState:
    irqRestore(saved)
    if reqHdr.srcId == TASK_SM:
      return KeMsgSaved
    scanuAnswer(param, SCANU_START_CFM, reqHdr.srcId, SCAN_STATUS_BUSY)
    return KeMsgNoFree
  defer: irqRestore(saved)
  let req = scanuStartReqView(param)
  let epoch = cacheScanuStartRequest(param, req, reqHdr.srcId)
  if scanuRequestCurrent(param, epoch):
    when defined(bl808WifiDiagWarmScan): inc nimFwDbgWarmScan.upper_admitted
    scanu_start()
  return KeMsgNoFree

{.emit: "__attribute__((optimize(\"crossjumping\"))) int scanu_start_cfm_handler(void*);".}
proc scanu_start_cfm_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle SCANU_START_CFM: upper scan complete (164 bytes in blob, 42 instrs).
  ## From blob (scanu_task.o):
  ##   1. Load sm_env[0] (connect info ptr) into s1
  ##   2. Call ke_state_get(TASK_SM) - assert state==1 (line 402 if not)
  ##   3. Read vifIdx from sm_env[0]+59, call scanu_confirm(vifIdx)
  ##   4. Call sm_get_bss_params(&selectedBssResult, &selectedBssChannel)
  ##   5. Check sm_env[18] (cancel flag):
  ##      - If set: clear flag, call sm_connect_ind(26, 0xFFFF) (aborted)
  ##   6. If not canceled: check selectedBssResult and selectedBssChannel
  ##      - If both valid: call sm_join_bss(vif+80, selectedBssResult, selectedBssChannel, 0)
  ##      - If either null: sm_connect_ind(12, 0xFFFF) (no BSS found)
  ## Only the answer to SM's live scan request is taken (smScanAccept), so
  ## SM is in state 1 here; a failed scan has already ended the attempt.
  if not smScanAccept(param, SCANU_START_CFM): return KeMsgConsumed
  let stationManager = smEnvView()
  when defined(bl808WifiDiagColdScan):
    nimFwDbgColdScanFlow[5] = 1

  # Get VIF entry (blob: vif_mgmt_get_vif at 0x46, not scanu_confirm)
  let vifEntry = vif_mgmt_get_vif(connectInfoView(stationManager.connectInfo).vifIdx)
  # Prevent the compiler from eliding the call when the result is unused.
  {.emit: ["""__asm__ volatile("" : : "r"(""", vifEntry, """));"""].}

  # Get BSS parameters from scan results
  var selectedBssResult: pointer = nil
  var selectedBssChannel: pointer = nil
  sm_get_bss_params(addr selectedBssResult, addr selectedBssChannel)
  when defined(bl808WifiDiagColdScan):
    nimFwDbgColdScanFlow[5] = 2 or ((selectedBssResult != nil).uint32 shl 8) or
      ((selectedBssChannel != nil).uint32 shl 9)

  # Check cancel flag
  if stationManager.cancelRequested != 0:
    # Scan was canceled - clear flag and send abort indication
    stationManager.cancelRequested = 0
    sm_connect_ind(WLAN_FW_CONNECT_ABORT_WHEN_SCANNING.uint16, 0xFFFF'u16)
  elif selectedBssResult != nil and selectedBssChannel != nil and vifEntry != nil:
    # Found BSS - join it
    let vif = vifChannelAt(vifEntry)
    let vifMacAddr = cast[pointer](addr vif.macAddr[0])
    sm_join_bss(vifMacAddr, selectedBssResult, selectedBssChannel, false)
  else:
    # No BSS found
    sm_connect_ind(WLAN_FW_SCAN_NO_BSSID_AND_CHANNEL.uint16, 0xFFFF'u16)
  return 0

proc scanu_join_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SCANU_JOIN_REQ: scan for specific BSS to join (228 bytes in blob).
  ## From blob (scanu_task.o):
  ##   1. Read vifIdx from param[306] (lbu), compute VIF entry
  ##   2. Store param to scanu_env.paramPtr (offset 0)
  ##   3. Copy BSSID from param+286 (6 bytes) to scanu_env filter
  ##   4. Store vifIdx to scanu_env offset 176, clear VIF flags at offset 484
  ##   5. Set scanu_env.bssidFilterEnabled (offset 180) = 1
  ##   6. Copy param to scanu_env storage via memcpy
  ##   7. Clear scanu_env.found (offset specific), set scan duration (0xA00=2560)
  ##   8. Check param[286] bit0 (scan type), if set: ASSERT (line 191)
  ##   9. Call scan_start() to begin the targeted scan
  ##  10. If scan_start succeeds: ke_state_set(TASK_SCANU, ScanuJoiningState), store scan result,
  ##      call scanu_confirm, clear link, send SCANU_JOIN_CFM
  ##  11. If fails: call scanu_confirm(fail)
  if param == nil: return KeMsgConsumed
  if keMsgHdrFromPayload(param).paramLen < ScanuStartReqPayloadSize:
    return KeMsgConsumed
  if smScanRefused(param): return KeMsgNoFree
  let saved = irqSave()
  defer: irqRestore(saved)
  # Same single-paramPtr-slot hazard as scanu_start_req_handler: reject an
  # overlapping join rather than clobbering scanu_env.paramPtr (which would make
  # scanu_confirm free a still-live ke_msg -> shared-heap UAF -> nimIncRef).
  if ke_state_get(TASK_SCANU) != ScanuIdleState:
    if keMsgHdrFromPayload(param).srcId == TASK_SM: return KeMsgSaved
    return KeMsgConsumed
  let req = scanuStartReqView(param)
  let vifIdx = req.vifIdx
  let reqHdr = keMsgHdrFromPayload(param)
  if vifIdx >= MAX_VIFS.uint8:
    # SM's request is always answered, even one its sender should not send.
    if reqHdr.srcId != TASK_SM: return KeMsgConsumed
    scanuAnswer(param, reqHdr.id + 1, TASK_SM, SCAN_STATUS_FAIL)
    return KeMsgNoFree
  let vif = vifChannelForIdx(vifIdx)

  # Store param pointer in scanu_env
  let previousProducer = scanuProducerRequest
  let previousProducerEpoch = scanuProducerEpoch
  defer:
    scanuProducerRequest = previousProducer
    scanuProducerEpoch = previousProducerEpoch
  inc scanuRequestEpoch
  let epoch = scanuRequestEpoch
  scanu_env.paramPtr = param
  scanu_env.pendingJoinRxuMgtInd = nil
  scanuProducerRequest = param
  scanuProducerEpoch = epoch

  # Store requester source task and set flags
  scanu_env.requester = reqHdr.srcId
  vifApConfig(vif).securityFlags = 0
  scanu_env.bssidFilterEnabled = 1
  scanu_env.scanBand = 0
  ke_state_set(TASK_SCANU, ScanuJoiningState)

  # Copy BSSID from param+286 (6 bytes) to scanu_env filter area. Blob has
  # a single memcpy here — previous Nim had it duplicated (once before and
  # once after the flag writes) for no reason.
  discard c_memcpy(addr scanu_env.filterBssid[0], addr req.bssid[0],
                   req.bssid.len.csize_t)

  # Clear found flag, set scan duration
  scanu_env.resultCount = 0
  scanu_env.directedFound = 0
  scanu_env.joinRetryCount = 0x0A'u8

  # A join target must be unicast; the Nim assertion path is not fatal.
  if (req.bssid[0] and 1) != 0:
    scanu_confirm(SCAN_STATUS_BAD_PARAM)
    return KeMsgNoFree

  # Search for BSSID in existing scan results (blob: scanu_search_by_bssid)
  let existing = scanu_search_by_bssid(addr req.bssid[0])
  if not scanuRequestCurrent(param, epoch):
    return KeMsgNoFree

  # Reserve replay completion before transferring the slot's frame. Without
  # a DONE notice the caller must still be able to take the live scan path.
  if existing != nil:
    let existingEntry = scanuResultAt(existing)
    let cachedRxuMgtInd = existingEntry.cachedRxuMgtInd
    let cache = scanuCachedSsidFor(existingEntry)
    if cachedRxuMgtInd != nil and cache != nil:
      let generation = cache.generation
      var done = ke_msg_try_alloc(SCAN_DONE_IND, TASK_SCANU, TASK_SCANU, 0)
      defer:
        if done != nil: ke_msg_free_payload(done)
      if not scanuRequestCurrent(param, epoch): return KeMsgNoFree
      template cacheCurrent(): bool =
        cache.generation == generation and existingEntry.cachedRxuMgtInd == cachedRxuMgtInd
      if done != nil and cacheCurrent():
        ke_state_set(TASK_SCANU, ScanuScanningState)
        if not scanuRequestCurrent(param, epoch): return KeMsgNoFree
        if cacheCurrent():
          scanu_env.pendingJoinRxuMgtInd = done
          existingEntry.cachedRxuMgtInd = nil
          req.flags = 0
          ke_msg_send(cachedRxuMgtInd)
          if scanuRequestCurrent(param, epoch):
            let replayDone = done
            done = nil
            ke_msg_send(replayDone)
          return KeMsgNoFree

  # Start scan (blob: scanu_start → ke_msg_send_basic + scanu_scan_next)
  scanuProducerRequest = previousProducer
  scanuProducerEpoch = previousProducerEpoch
  scanu_start()

  # Scan started, set state
  if scanuRequestCurrent(param, epoch):
    ke_state_set(TASK_SCANU, ScanuJoiningState)
  return 1

{.emit: "__attribute__((optimize(\"crossjumping\"))) int scanu_join_cfm_handler(void*);".}
proc scanu_join_cfm_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle SCANU_JOIN_CFM (434 bytes in blob, 106 instrs).
  ## From blob (scanu_task.o): Assert state==2 (SM_JOINING). If sm_env.canceled(18):
  ## clear flag, sm_connect_ind(25, 0xFFFF). Else: get vif_idx from sm_env_ptr[59].
  ## If vif.flags(484) bit31 set: sm_add_chan_ctx, then alloc msg(10,0,4,28),
  ## chan_ctxt_link, memcpy BSSID(6 bytes from vif+380), set HT rate mask,
  ## ke_msg_send, ke_state_set(SM,3). Copy connection flags to vif[1496].
  ## If bit31 not set: check sm_env[16] flag for sm_join_bss path, else
  ## sm_connect_ind with various error codes (13,14,17,18).
  ## Only the answer to SM's live join request is taken (smScanAccept), so
  ## SM is in state 2 here; a failed join has already ended the attempt.
  if not smScanAccept(param, SCANU_JOIN_CFM): return KeMsgConsumed
  let sm = smEnvView()
  # Check cancelled flag
  if sm.cancelRequested != 0:
    sm.cancelRequested = 0
    sm_connect_ind(25, 0xFFFF'u16)
    return 0
  # Get VIF info
  let connectInfoPtr = sm.connectInfo
  let connectInfo = connectInfoView(connectInfoPtr)
  let vifIdx = connectInfo.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let apConfig = vifApConfig(vif)
  let securityFlagsSigned = cast[int32](apConfig.securityFlags)
  if securityFlagsSigned < 0:  # bit31 set (has channel context to add)
    # The registration of the AP station with MM (state 3). The request and
    # the channel context are set up before any of it is published.
    var prepared = MmStaAddReqPayload(vifIdx: vifIdx, bssid: vif.bssid,
                                      quickConn: sm.connectFlags)
    var preparedChannel: ChanCtxtDefView
    if not smPrepareChannelContext(connectInfoPtr, preparedChannel):
      sm_connect_ind(13, 0xFFFF'u16)
      return KeMsgConsumed
    let apSecurityFlags = apConfig.securityFlags
    if (apSecurityFlags and 2) != 0:
      let htCap = vifHtCapabilities(vif).ampduParams
      mmStaFillAggregation(prepared, htCap)
    let connectFlags = connectInfo.channelDuration
    let msg = cast[ptr MmStaAddReqPayload](
      ke_msg_try_alloc(MM_STA_ADD_REQ, TASK_MM, TASK_SM, MmStaAddReqPayloadSize))
    if msg == nil:
      sm_connect_ind(WLAN_FW_JOIN_NETWORK_FAILURE.uint16, 0xFFFF)
      return KeMsgConsumed
    var channel: ChanCtxtLease
    var chanIdx = 0xFF'u8
    if smAddPreparedChannelContext(preparedChannel, addr chanIdx, addr channel) != 0 or
        not chanLeaseLink(channel, vifIdx):
      chanLeaseRelease(channel)
      ke_msg_free(keMsgHdrFromPayload(msg))
      sm_connect_ind(13, 0xFFFF'u16)
      return KeMsgConsumed
    # The VIF holds the linked context from here on; the teardown of a failed
    # attempt unlinks it, as in the blob.
    msg[] = prepared

    inc nimFwDbgPreauthStaReq
    nimFwDbgPreauthStaReqMeta =
      vifIdx.uint32 or (vif.staIdx.uint32 shl 8) or
      (chanIdx.uint32 shl 16) or (SmWaitingState.uint32 shl 24)
    nimFwDbgPreauthStaReqBssid0 = cast[ptr uint32](addr msg.bssid[0])[]
    nimFwDbgPreauthStaReqBssid1 = cast[ptr uint16](addr msg.bssid[4])[].uint32
    vifKeyPointers(vif).flags = connectFlags
    if (connectFlags and 4) != 0:
      var clearedSecurityFlags = apConfig.securityFlags
      clearedSecurityFlags = clearedSecurityFlags and (not 7'u32)  # Clear bits 0-2
      apConfig.securityFlags = clearedSecurityFlags
    smGo(SmAddingChanState)
    smSend(msg)
  else:
    # No channel context to add
    if sm.joinBssFlag != 0:
      # Join BSS path
      let chanInfo = vif.operChan
      sm_join_bss(cast[pointer](addr vif.macAddr[0]),
                  cast[pointer](addr vif.bssid[0]), chanInfo, true)
    else:
      if (sm.connectModeFlags and 1) != 0:
        sm_connect_ind(17, 0xFFFF'u16)
      elif (sm.connectModeFlags and 2) != 0:
        sm_connect_ind(18, 0xFFFF'u16)
      else:
        sm_connect_ind(14, 0xFFFF'u16)
  return 0

proc scanu_raw_send_busy_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## SCANU is scanning or joining. The blob has no handler here, so the kernel
  ## frees the request and the host waits out its command timeout. The request
  ## points at a host buffer, so it cannot be saved for later either: refuse it
  ## now with a nonzero result.
  if param != nil: scanu_raw_send_cfm(cast[pointer](1), keMsgHdrFromPayload(param).srcId)
  KeMsgConsumed

proc scanu_raw_send_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Acknowledge the raw-send request, copy it into an internal TX frame,
  ## and force-push on AC 3, as in scanu_task.o. Reject invalid lengths before
  ## allocation: an unqueued descriptor has no later completion to release it.
  if param == nil: return 0
  let reqHdr = keMsgHdrFromPayload(param)
  let srcId = reqHdr.srcId
  if reqHdr.paramLen < ScanuRawSendReqPayloadSize:
    scanu_raw_send_cfm(nil, srcId)
    return 0
  let req = cast[ptr ScanuRawSendReqPayload](param)
  let framePtr = req.framePtr
  let frameLen = req.frameLen
  let logFnPtr = blOpsFunc(4)
  if logFnPtr != nil:
    cast[proc(fmt: cstring) {.cdecl, varargs.}](logFnPtr)(
      "[FW] pkt address is %p, len is %lu\r\n", framePtr, frameLen.culong)
  # Synchronously acknowledge with a NULL-result CFM back to the requester.
  # Blob: `li a0, 0; mv a1, saved_a3; call scanu_raw_send_cfm` immediately
  # after the log call — before frame allocation.
  scanu_raw_send_cfm(nil, srcId)
  if frameLen > 511:
    if logFnPtr != nil:
      cast[proc(fmt: cstring) {.cdecl, varargs.}](logFnPtr)(
        "[FW] send len(%d) exceed buf_len(%d)\r\n", cast[cint](frameLen), 512.cint)
    return 0
  if framePtr == nil or frameLen == 0:
    return 0
  let txBuf = txl_frame_get(512)
  if txBuf == nil:
    return 0
  let frameDesc = cast[ptr TxlFrameDescView](txBuf)
  # Copy frame data to the TX descriptor payload area.
  let linkDescPtr = frameDesc.linkDesc
  if linkDescPtr != nil:
    let linkDesc = hostTxLinkDescAt(linkDescPtr)
    discard c_memcpy(addr linkDesc.macHeader[0], framePtr, frameLen.csize_t)
  # Clear TX descriptor fields
  frameDesc.staInfoIdx = 0xFF'u8
  frameDesc.vifIdx = 0
  frameDesc.retryCount = 0
  frameDesc.statusByte = 0
  # Register TX-completion callback (blob: sw at offset 208 of descriptor,
  # self-pointer at +212 — pattern `addi t, s0, 128; sw &cfm, 80(t); sw s0, 84(t)`).
  frameDesc.callback = cast[pointer](cfm_raw_send)
  frameDesc.callbackArg = txBuf
  # Set up HW descriptor length
  if frameDesc.thd != nil:
    let hwDesc = hostTxHwDescAt(frameDesc.thd)
    let lenMinusOne = frameLen - 1
    hwDesc.frameLen = frameLen + 4  # total with FCS
    hwDesc.payloadEnd = hwDesc.payloadStart + lenMinusOne
  # Push for TX (blob: txl_frame_push_force, not txl_frame_push)
  txl_frame_push_force(txBuf, 3)
  # Request acknowledgement is synchronous; this callback only logs TX status.
  return 0

# --- SM Task Handlers (sm_task.o) ---

proc smConnectReqHasSpecificBssid(req: ptr ConnectInfoView): bool {.inline.} =
  if req == nil:
    return false
  if (req.bssid[0] and 1'u8) != 0:
    return false
  var allZero = true
  var allFf = true
  for bssidByteIndex in 0 ..< 6:
    let bssidByte = req.bssid[bssidByteIndex]
    if bssidByte != 0'u8:
      allZero = false
    if bssidByte != 0xFF'u8:
      allFf = false
  not allZero and not allFf

const SmConnectEnvLen = 860'u32
  ## Retained connect-env size: matches the blob's large connect message
  ## (SM_CONNECT_IND is allocated at 860 below) and covers every connect-info
  ## overlay access, including ConnectInfoChannelContextOverlay.chanType at
  ## offset 479 — far past the ~192-byte host SM_CONNECT_REQ param.

proc sm_connect_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SM_CONNECT_REQ: initiate STA connection (173 instrs in blob).
  ## From blob (sm_task.o): validates SM state, loads VIF info, checks
  ## existing connections, allocates connect env message, initiates scan.
  ##
  ## Flow from disasm:
  ##   1. ke_state_get(TASK_SM=4): if state==10, return KeMsgSaved
  ##   2. Allocate SM_CONNECT_CFM (0x1001) for response
  ##   3. ke_state_get(TASK_SM=4): if state!=0, return status=8 (busy)
  ##   4. Resolve VIF: check vif_info_tab[vif_idx].type(+86) and active(+88)
  ##   5. Assert: sta_idx(+96) must be 0xFF (no existing STA)
  ##   6. Assert: channel_ctx(+64) must be nil
  ##   7. Assert: connect_env[0] must be nil (no existing connection)
  ##   8. Assert: connect_env[4] must be nil
  ##   9. Allocate large connect msg (0x1002, size=860)
  ##  10. Setup: store connect params, clear flags, initiate scan
  ##  11. Return: write status to CFM and send
  if param == nil: return KeMsgConsumed
  let req = connectInfoView(param)
  let vifIdx = req.vifIdx

  # Check SM state first
  let state1 = ke_state_get(TASK_SM)
  if state1 == 10:
    return KeMsgSaved

  var cfmStatus: uint8 = 0
  var earlyExit = false

  # Check SM state is idle (0)
  let state2 = ke_state_get(TASK_SM)
  if state2 != 0:
    cfmStatus = 8
    earlyExit = true

  let vif = if vifIdx < MAX_VIFS.uint8: vifChannelForIdx(vifIdx) else: nil
  if not earlyExit:
    if vif == nil:
      cfmStatus = 9
      earlyExit = true
    elif (vif.vifType != 0 or vif.state != 0) and req.authType != 2:
      cfmStatus = 9
      earlyExit = true
    elif connectInfoHasChannelHint(req):
      let hint = cast[ptr ScanChannelEntry](connectInfoChannelHint(param))
      if hint.band != 0 or me_freq_to_chan_ptr(hint.band, hint.prim20Freq) == nil:
        cfmStatus = 9
        earlyExit = true

  if not earlyExit:
    let sm = smEnvView()
    if sm.connectInfo != nil or sm.connectIndMsg != nil:
      cfmStatus = 8
      earlyExit = true
    elif vif.staIdx != 0xFF or vif.chanCtxt != nil:
      # Retain the request in the saved queue until normal cleanup finishes.
      let started = smTeardown(cast[pointer](vif))
      if started and ke_state_get(TASK_SM) != SmIdleState:
        return KeMsgSaved
      if not started or sm.connectInfo != nil or sm.connectIndMsg != nil or
          vif.staIdx != 0xFF or vif.chanCtxt != nil:
        cfmStatus = 8
        earlyExit = true
      elif (vif.vifType != 0 or vif.state != 0) and req.authType != 2:
        cfmStatus = 9
        earlyExit = true

  if earlyExit:
    let cfm = cast[ptr StatusCfmPayload](
      ke_msg_alloc(SM_CONNECT_CFM, TASK_API, TASK_SM, StatusCfmPayloadSize))
    if cfm != nil:
      cfm.status = cfmStatus
      ke_msg_send(cfm)
    return KeMsgConsumed

  let sm = smEnvView()
  let previousEpoch = rxVifEpochs[vifIdx]
  let vifType = vif.vifType
  let vifState = vif.state
  const StopScanCurrentChannelIfTargetApFound = 1'u32 shl 8
  let quickConn = ((req.channelDuration and StopScanCurrentChannelIfTargetApFound) != 0).uint8
  template unclaimed(epoch: uint32): bool =
    rxVifEpochs[vifIdx] == epoch and vif.vifType == vifType and
      vif.state == vifState and vif.staIdx == 0xFF and vif.chanCtxt == nil and
      sm.connectInfo == nil and sm.connectIndMsg == nil and
      ke_state_get(TASK_SM) == SmIdleState

  var confirmation = ke_msg_alloc(SM_CONNECT_CFM, TASK_API, TASK_SM, StatusCfmPayloadSize)
  var indication: pointer
  defer:
    if confirmation != nil: ke_msg_free(keMsgHdrFromPayload(confirmation))
    if indication != nil: ke_msg_free(keMsgHdrFromPayload(indication))
  template confirm(statusValue: uint8) =
    let outgoing = confirmation
    confirmation = nil
    cast[ptr StatusCfmPayload](outgoing).status = statusValue
    ke_msg_send(outgoing)
  if confirmation == nil: return KeMsgConsumed
  if not unclaimed(previousEpoch):
    confirm(8'u8)
    return KeMsgConsumed
  indication = ke_msg_alloc(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
  if indication == nil or not unclaimed(previousEpoch):
    confirm(8'u8)
    return KeMsgConsumed
  discard c_memset(indication, 0, 64.csize_t)

  # Both messages remain private until the VIF has survived allocation and TX retirement.
  if not rxInvalidateVif(vifIdx):
    confirm(8'u8)
    return KeMsgConsumed
  let epoch = previousEpoch + 1'u32
  let publishedIndication = indication
  var published = false
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    if unclaimed(epoch):
      sm.connectInfo = param
      sm.connectIndMsg = indication
      indication = nil
      sm.connectFlags = quickConn
      sm.connectModeFlags = 0
      sm.cancelRequested = 0
      sm.scanResultIndex = 0xFFFFFFFF'u32
      sm.vendorIeLen = sm.vendorIeLen and 0x00FF'u16
      published = true
  if not published:
    confirm(8'u8)
    return KeMsgConsumed

  template current(): bool =
    rxVifEpochs[vifIdx] == epoch and vif.vifType == vifType and
      vif.state == vifState and sm.connectInfo == param and
      sm.connectIndMsg == publishedIndication and ke_state_get(TASK_SM) == SmIdleState
  sm_connection_tlv_set()
  if not current():
    confirm(8'u8)
    return KeMsgNoFree

  var hasBssid, hasChannel, selected: bool
  var hintedBssidSpecific = true
  var selectedBssid: array[6, uint8]
  var selectedChannel: ScanChannelEntry
  var localMac: array[6, uint8]
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    if current():
      var selectedBssResult, selectedBssChannel: pointer
      if connectInfoHasChannelHint(req) and smConnectReqHasSpecificBssid(req):
        selectedBssResult = cast[pointer](addr req.bssid[0])
        selectedBssChannel = connectInfoChannelHint(param)
      elif connectInfoHasChannelHint(req):
        hintedBssidSpecific = false
        selectedBssResult = cast[pointer](addr req.bssid[0])
        selectedBssChannel = connectInfoChannelHint(param)
      else:
        sm_get_bss_params(addr selectedBssResult, addr selectedBssChannel)
      if current():
        hasBssid = selectedBssResult != nil
        hasChannel = selectedBssChannel != nil
        if hasBssid: selectedBssid = cast[ptr array[6, uint8]](selectedBssResult)[]
        if hasChannel: selectedChannel = cast[ptr ScanChannelEntry](selectedBssChannel)[]
        localMac = vif.macAddr
        selected = true
  if not selected:
    confirm(8'u8)
    return KeMsgNoFree
  if hasBssid:
    scanu_prune_scanresult_raw_frames_except_bssid(addr selectedBssid[0])
  else:
    scanu_prune_scanresult_raw_frames()
  if not current():
    confirm(8'u8)
    return KeMsgNoFree
  confirm(0'u8)
  if not current(): return KeMsgNoFree

  let targetBssid = if hasBssid: cast[pointer](addr selectedBssid[0]) else: nil
  let targetChannel = if hasChannel: cast[pointer](addr selectedChannel) else: nil
  if hasBssid and hasChannel and hintedBssidSpecific and
      (selectedBssid[0] and 1'u8) == 0:
    sm_join_bss(unsafeAddr localMac[0], targetBssid, targetChannel, false)
  else:
    sm_scan_bss(unsafeAddr localMac[0], targetBssid, targetChannel)
  # The request and indication have transferred to SM, even if a callback retired them.
  return KeMsgNoFree

proc sm_disconnect_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Pinned sm_task.o saves the request while SM is busy and then reads only
  ## the VIF index. Here it acts only on the STA VIF generation it was sent
  ## for (smDisconnectCurrent, station_abort.nim), even after a join.
  inc nimFwDbgDisconnectReq
  let state = ke_state_get(TASK_SM)
  nimFwDbgDisconnectReqState = state.uint32
  if param == nil: return KeMsgConsumed
  if smDisconnectCurrent(param):
    if state != SmIdleState:
      return KeMsgSaved
    sm_connection_tlv_set()
    sm_handle_connection(cast[ptr uint8](param)[], 19'u16,
      cast[pointer](sm_disconnect_deauth_cfm),
      cast[pointer](sm_disconnect_process))
  # Even an obsolete request must retire its host command. The empty
  # confirmation can use the original allocation, including under pressure.
  keMsgHdrFromPayload(param).paramLen = 0
  ke_msg_forward_and_change_id(param, SM_DISCONNECT_CFM, TASK_API, TASK_SM)
  KeMsgNoFree

proc smQueueOwnedScanAbort() =
  ## Abort the lower scan that SM's scan request started, and clear the
  ## cached results, as the pinned abort handler does in state 1. A scan
  ## SCANU runs for another requester is left alone.
  if not smAbortOwnsLowerScan(): return
  let message = ke_msg_try_alloc(SCAN_ABORT_REQ, TASK_SCAN, TASK_SM, SmScanAbortPayloadSize)
  if message == nil: return
  cast[ptr uint32](message)[] = scanRequestEpoch
  ke_msg_send(message)
  scanu_cached_scanresult_clear()

proc sm_connect_abort_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Pinned sm_connect_abort_req_handler+0x32..0x3a saves the abort in states
  ## 3 and 4 and only confirms it in 5 and 7. Here it ends the attempt in all
  ## four: no frame has been sent to the AP yet. In 5 and 7 the parked auth
  ## or assoc request is freed with the attempt (smGo).
  ## The request is answered in place (it becomes SM_CONNECT_ABORT_CFM), so
  ## it is never saved: it acts on the attempt live when it is dispatched,
  ## if that attempt is on the STA VIF it names. Status 1 for a request that
  ## names no STA VIF or another VIF than the attempt's, and in state 1,
  ## where the abort completes with the scan.
  if param == nil: return KeMsgConsumed
  let header = keMsgHdrFromPayload(param)
  let vifIdx = if header.paramLen == 1: cast[ptr uint8](param)[] else: 0xFF'u8
  let connection = smEnvView().connectInfo
  var status = 1'u8
  if vifIdx < MAX_VIFS.uint8 and vifChannelForIdx(vifIdx).vifIdx == vifIdx and
      vifChannelForIdx(vifIdx).vifType == VIF_TYPE_STA and
      (connection == nil or connectInfoView(connection).vifIdx == vifIdx):
    status = 0
    let state = ke_state_get(TASK_SM)
    if state in [SmAddingChanState, SmSettingBssState, SmAuthStartingState, SmAssociatingState]:
      sm_connect_ind(WLAN_FW_CONNECT_ABORT_BY_USER_NO_DEAUTH, 3)
    elif state == SmScanningState:
      smEnvView().cancelRequested = 1
      status = 1
      smQueueOwnedScanAbort()
    elif state == SmWaitingState:
      smEnvView().cancelRequested = 1
    elif state in [SmAuthenticatingState, SmAssocRspState, SM_ACTIVATING_STATE]:
      sm_handle_connection(vifIdx, WLAN_FW_CONNECT_ABORT_BY_USER_NO_DEAUTH,
        cast[pointer](sm_connect_abort_deauth_cfm), cast[pointer](sm_connect_abort_process))
  cast[ptr StatusCfmPayload](param).status = status
  header.paramLen = StatusCfmPayloadSize
  ke_msg_forward_and_change_id(param, SM_CONNECT_ABORT_CFM, TASK_API, TASK_SM)
  KeMsgNoFree

proc sm_rsp_timeout_ind_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle SM_RSP_TIMEOUT_IND: auth/assoc response timeout (126 bytes in blob).
  ## Blob: loads sm_env[0] (connection env), ke_state_get(SM), then:
  ##   - If no connection env: return 0
  ##   - State must be in the auth/assoc response window after channel grant
  ##   - Check retry count (conn_env[60]) vs max retries (sm_env word at byte 24)
  ##   - If retries available: increment, retry auth in state 6 or assoc in state 8
  ##   - If retries exhausted: sm_connect_ind(11, 0xFFFF)
  ## The expiry carries the stamp of the SM operation that armed it; one from
  ## an earlier operation is stale (smResponseExpiry).
  let stamp = smResponseExpiry(param)
  if stamp == 0: return KeMsgConsumed
  let sm = smEnvView()
  let connEnv = sm.connectInfo
  let state = ke_state_get(TASK_SM)
  inc nimFwDbgSmRspTimeout
  nimFwDbgSmRspTimeoutState = state.uint32
  nimFwDbgSmRspTimeoutRxCtrl = regRead(MACHW_RX_CNTRL_REG)
  when defined(bl808WifiConnectTrace):
    nimFwTrace2U32("[WIFI-NIMFW] sm_rsp_timeout ",
                   state.uint32, cast[uint32](cast[uint](connEnv)))
    nimFwConnectTrace2U32("[WIFI-CT] sm_rsp_timeout ",
                          state.uint32, cast[uint32](cast[uint](connEnv)))
  if connEnv == nil:
    return KeMsgConsumed
  if state != SmAuthenticatingState and state != SmAssocRspState:
    return KeMsgConsumed
  # A MAC ACK does not carry the authentication status or association AID.
  let retryCount = connectInfoAuthRetry(connEnv)[]
  let maxRetries = sm.authRetryLimit
  when defined(bl808WifiConnectTrace):
    nimFwTrace2U32("[WIFI-NIMFW] sm_rsp_retry ",
                   retryCount.uint32, maxRetries)
    nimFwConnectTrace2U32("[WIFI-CT] sm_rsp_retry ",
                          retryCount.uint32, maxRetries)
  if retryCount.uint32 >= maxRetries:
    # Retries exhausted: report timeout failure
    sm_connect_ind(WLAN_FW_AUTH_OR_ASSOC_RESPONSE_TIMEOUT_FAILURE, 0xFFFF'u16)
    return KeMsgConsumed
  # Increment retry count
  connectInfoAuthRetry(connEnv)[] = retryCount + 1
  if state == SmAuthenticatingState:
    if wpa_cbs != nil:
      let wpaCbFn = wpaCallbacks().authTimeout
      if wpaCbFn != nil:
        cast[proc() {.cdecl.}](wpaCbFn)()
        # The supplicant may have ended the attempt.
        if not opCurrent(smOwn.op, stamp): return KeMsgConsumed
    sm_auth_send_pre(1'u16, nil)
  else:
    sm_assoc_req_send_pre()
  return KeMsgConsumed

proc sm_sa_query_timeout_ind_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Retry twice, then report the original AP disconnect reason on the peer's
  ## VIF. Kernel handlers return zero (message consumed), as in sm_task.o.
  let saved = irqSave()
  var locked = true
  defer:
    if locked: irqRestore(saved)
  let serial = smSaQueryClaimTimeout(param)
  if serial == 0: return 0
  let sm = smEnvView()
  let retryCount = sm.saQueryRetryCount
  if retryCount != 0:
    # Debit the claimed attempt before its TX path can call back.
    sm.saQueryRetryCount = retryCount - 1
    sm_issue_sa_query_request()
    return 0
  sm.saQueryActive = 0
  locked = false
  irqRestore(saved)
  when defined(bl808WifiDiagLinkDrop):
    smReportApDisconnect(smSaQuery.peer, sm.saQueryReason, smSaQuery.evidence)
  else:
    smReportApDisconnect(smSaQuery.peer, sm.saQueryReason)
  return 0

proc sm_disconnect*(vifIdx: uint8) {.exportc, cdecl.} =
  ## Request deauthentication for this active STA VIF; complete it after TX.
  if vifIdx.int >= MAX_VIFS:
    return
  let vif = vifChannelForIdx(vifIdx)
  if vif.vifType != 0 or vif.state == 0:
    return
  sm_handle_connection(vifIdx, 20'u16, cast[pointer](sm_disconnect_deauth_cfm),
                       cast[pointer](sm_disconnect_process))

proc sm_delete_resources*(param: pointer = nil) {.exportc, cdecl.} =
  ## Retire STA state through the vendor's ME/MM cleanup exchange.
  smTeardown(param)

proc sm_auth_assoc_send_according_chan*(nextState: uint16 = 0, authSequence: uint16 = 0, challenge: pointer = nil) {.exportc, cdecl.} =
  ## Send auth/assoc on appropriate channel (226 bytes in blob, 57 instrs).
  ## From blob (sm.o): reads the active connection's vif_idx(59).
  ## Direct for one channel, a dominant channel, or remaining time 0/41..199ms.
  ## Otherwise park the request until the channel scheduler activates the VIF
  ## (deferred_auth.nim).
  let connInfo = smEnvView().connectInfo
  if connInfo == nil or nextState notin [SmAuthStartingState, SmAssociatingState]:
    return
  let vifIdx = connectInfoView(connInfo).vifIdx
  let chanCnt = chan_ctxt_cnt()
  when defined(bl808WifiConnectTrace):
    nimFwTrace2U32("[WIFI-NIMFW] auth_sched ",
                   nextState.uint32 or (authSequence.uint32 shl 16),
                   vifIdx.uint32 or (chanCnt.uint32 shl 8) or
                     (ke_state_get(TASK_SM).uint32 shl 16))
    nimFwConnectTrace2U32("[WIFI-CT] auth_sched ",
                          nextState.uint32 or (authSequence.uint32 shl 16),
                          vifIdx.uint32 or (chanCnt.uint32 shl 8) or
                            (ke_state_get(TASK_SM).uint32 shl 16))
  var direct = chanCnt <= 1 or chan_ctxt_use_dominant_chan()
  if not direct:
    let remaining = chan_ctxt_get_remaining_time_ms(cast[pointer](vifChannelForIdx(vifIdx)))
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] auth_rem ", remaining, nextState.uint32)
    direct = remaining == 0 or (remaining - 41'u32) <= 158'u32
  if not direct:
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] auth_queue ", nextState.uint32, authSequence.uint32)
    smDeferredPark(nextState, authSequence, challenge)
  elif nextState == SmAuthStartingState:
    sm_auth_send(authSequence, challenge)
  else:
    sm_assoc_req_send()

proc sm_supplicant_deauth_cfm*(param: pointer; status: uint32) {.exportc, cdecl.} =
  ## Report supplicant deauth completion; bit 23 records the MAC ACK. Any
  ## status ends the wait, as in the blob; param is the wait's stamp.
  if not smDeauthConfirmed(param): return
  if (status and 0x00800000'u32) == 0:
    let logFn = getLogFunc(204)
    if logFn != nil:
      logFn(3, nil, "sm.c", 1717,
            cstring("sm deauth frame transmit failure\r\n"))
  smConnectEnd(8, 15)

# --- APM Task Handlers (apm_task.o) ---

when defined(bl808WifiApHttpSmoke):
  var nimfwApFirmwareStage {.exportc: "nimfw_ap_firmware_stage", wifiCtrl.}: uint32

{.emit: "__attribute__((optimize(\"crossjumping\"))) int apm_start_req_handler(void*);".}
proc apm_start_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Retain the request until the beacon confirmation, as in apm_task.o.
  template stage(value: uint32) =
    when defined(bl808WifiApHttpSmoke): nimfwApFirmwareStage = value
  when defined(bl808WifiApHttpSmoke):
    nimfwApTiming = [regRead(ClicMtimeBase), 0, 0, 0, 0]
    nimfwApQueueSnapshot = default(typeof(nimfwApQueueSnapshot))
  stage(1)
  if param == nil:
    return KeMsgConsumed
  let header = keMsgHdrFromPayload(param)
  let cfm = cast[ptr ApmStartCfmPayload](
    ke_msg_alloc(APM_START_CFM, header.srcId, header.destId, ApmStartCfmPayloadSize))
  if cfm == nil:
    return KeMsgConsumed
  cfm[] = default(ApmStartCfmPayload)
  cfm.vifIdx = 0xFF
  var status = 1'u8
  var entered = false
  var channelAdded = false
  var contextIndex = 0xFF'u8
  let apm = apmEnvView()
  var vif: ptr VifChannelView
  block startAp:
    if header.paramLen < (sizeof(ApmStartReqView) - 3).uint32:
      break startAp
    let req = apmStartReqView(param)
    let vifIdx = req.vifIdx
    cfm.vifIdx = vifIdx
    stage(2)
    if vifIdx.int >= MAX_VIFS:
      break startAp
    vif = vifChannelForIdx(vifIdx)
    status = 4
    if vif.vifType != VIF_TYPE_AP:
      break startAp
    status = 8
    if ke_state_get(TASK_APM) != ApmIdleState or apm.connectInfo != nil or
       apm.hostapdCtx != nil or not mmBeaconPoolIdle():
      break startAp
    # The firmware owns one shared beacon/TIM pool, including for open APs.
    var otherApActive = false
    for otherIdx in 0'u8 ..< MAX_VIFS.uint8:
      if otherIdx != vifIdx:
        let other = vifChannelForIdx(otherIdx)
        if other.vifType == VIF_TYPE_AP and other.state != 0:
          otherApActive = true
          break
    if otherApActive:
      break startAp
    status = 9
    if vif.state != 0 or vif.chanCtxt != nil:
      break startAp
    status = 1
    stage(3)
    if req.channel.band != 0 or req.channelWidth > 4 or
       req.centerFreq1 > 65535 or req.centerFreq2 > 65535 or
       req.hiddenSsid > 2 or req.extraIeLength > 64 or
       req.securityType > 2:
      break startAp
    # Reject an unusable channel before reserving the AP or beacon pool.
    if (req.channelWidth == 0 and
        (req.centerFreq1 != req.channel.freq.uint32 or req.centerFreq2 != 0)) or
       me_freq_to_chan_ptr(req.channel.band, req.channel.freq) == nil:
      break startAp
    var frameExtras: ApFrameExtras
    if not readApFrameExtras(addr req.extraIes[0], req.extraIeLength.uint32, frameExtras):
      break startAp
    if req.embedded != 0:
      if req.ssidLength == 0 or req.ssidLength > 32 or
         req.rates[0] == 0 or req.rates[0] > 12 or req.dtimPeriod == 0:
        break startAp
      me_get_basic_rates(addr req.rates[0], addr req.staRateSeed[0])
    if req.staRateSeed[0] == 0 or req.staRateSeed[0] > 12:
      break startAp
    for rateIndex in 1 .. req.staRateSeed[0].int:
      if me_rate_translate(req.staRateSeed[rateIndex].uint32) >= 12:
        break startAp
    var passphraseLength = 0
    if req.securityType != 0:
      while passphraseLength < req.passphrase.len and req.passphrase[passphraseLength] != 0:
        inc passphraseLength
      if passphraseLength < 8 or passphraseLength > 64 or wpa_cbs == nil or
         wpaCallbacks().beaconRegister == nil or wpaCallbacks().apStopped == nil:
        break startAp
    block:
      stage(4)
      let saved = irqSave()
      defer: irqRestore(saved)
      var selected: uint8
      if not txlHaltVifQueues(vifIdx, selected):
        break startAp
      apm.connectInfo = param
      apmStartConfirmation = cfm
      apmStartSideEffects = false
      apmRollbackActive = false
      apmRollbackHaltPending = false
      entered = true
      apmPendingCancelMask = apmPendingCancelMask or (1'u8 shl vifIdx)
      rxInvalidateQuiescentVif(vifIdx, selected)
    ke_state_set(TASK_APM, ApmActiveState)
    stage(5)
    mm_bcn_init_vif(vif)
    if not apmPrepareStartReplies():
      break startAp
    if me_add_chan_ctx(addr contextIndex, addr req.channel,
                       req.centerFreq1, req.centerFreq2, req.channelWidth) != 0:
      break startAp
    stage(6)
    channelAdded = true
    let apChannel = me_freq_to_chan_ptr(req.channel.band, req.channel.freq)
    if apChannel == nil:
      break startAp
    vif.operChan = apChannel
    cast[ptr ScanChannelEntry](apChannel).txPower = req.channel.txPower
    vif.channelFreqPair = req.centerFreq1.uint16.uint32 or
      (req.centerFreq2.uint16.uint32 shl 16)
    let apConfig = vifApConfig(vif)
    apConfig.authType = if req.channelWidth == 4: 3'u8 else: req.channelWidth
    apConfig.requestedAuthType = req.channelWidth
    apConfig.authConfigPadding[0] = 0
    chan_ctxt_link(vifIdx, contextIndex)
    apm.embeddedEnabled = req.embedded
    apm.flags = req.hiddenSsid
    apm.vifIdx = vifIdx
    apm.cryptoType = req.extraIeLength
    apm.securityIe = default(typeof(apm.securityIe))
    discard c_memcpy(addr apm.securityIe[0], addr req.extraIes[0], req.extraIeLength.csize_t)
    let securityState = vifSecurity(vif)
    securityState.cipher = 0
    if req.embedded != 0:
      apConfig.securityFlags = apConfig.securityFlags and not 3'u32
      if req.qosSupported != 0: apConfig.securityFlags = apConfig.securityFlags or 1
      if meEnvView().htSupp != 0: apConfig.securityFlags = apConfig.securityFlags or 2
      apConfig.beaconInterval = req.beaconInterval
      vif.beaconIntervalTu = req.dtimPeriod.uint16
      apConfig.privacyFlag = req.securityType
      discard c_memcpy(addr vif.supportedRatesLong[0], addr req.ssidLength, 34.csize_t)
      vif.supportedRatesLong[req.ssidLength.int + 1] = 0
      discard c_memcpy(addr vif.basicRates[0], addr req.rates[0], 13.csize_t)
      vif.bssid = vif.macAddr
      # Keep the AP's own configured queues; the live bank may belong to STA.
      vif.wmmQosInfo = 0
      apConfig.aidBitmapFeatureLow = 0
      apConfig.maxAssocRate = 0xFFFF
      if req.securityType != 0:
        stage(7)
        var parameters = default(WpaBeaconRegisterParamView)
        parameters.vifIdx = vifIdx
        parameters.bssid = vif.macAddr
        parameters.ssidLength = req.ssidLength.uint32
        discard c_memcpy(addr parameters.ssid[0], addr req.ssid[0], req.ssidLength.csize_t)
        parameters.authMode = 3
        parameters.pairwiseCipher = 4
        discard c_memcpy(addr parameters.passphrase[0], addr req.passphrase[0],
                         passphraseLength.csize_t)
        let initialize = wpaCallbacks().beaconRegister
        when defined(bl808WifiMbedTlsSha1Lease):
          let expectKeySetup = passphraseLength < 64
          if expectKeySetup and not beginShaApKeySetup():
            break startAp
        when defined(bl808WifiApHttpSmoke):
          nimfwApTiming[1] = regRead(ClicMtimeBase)
        apm.hostapdCtx = cast[proc(p: pointer): pointer {.cdecl.}](initialize)(addr parameters)
        when defined(bl808WifiApHttpSmoke):
          nimfwApTiming[2] = regRead(ClicMtimeBase)
        when defined(bl808WifiMbedTlsSha1Lease):
          # The SDK callback can return non-nil even when key setup fails.
          # Let the common APM failure path tear down that partial context.
          if expectKeySetup and not finishShaApKeySetup():
            break startAp
        if apm.hostapdCtx == nil:
          break startAp
        securityState.cipher = 3
      stage(8)
      # The hardware beacon pool has 512 bytes. Bound every variable append
      # before calling the existing builder, including callback-installed IEs.
      if meBeaconFrameLength(vifIdx, req.hiddenSsid) + req.extraIeLength.uint64 > 512:
        break startAp
      let allocate = blOpsFunc(184)
      if allocate == nil or blOpsFunc(188) == nil:
        break startAp
      apm.pendingBeaconBuffer = cast[proc(size: uint32): pointer {.cdecl.}](allocate)(512)
      if apm.pendingBeaconBuffer == nil:
        break startAp
      let built = me_build_beacon(apm.pendingBeaconBuffer, vifIdx,
        addr req.timOffset, addr req.timLength, req.hiddenSsid)
      if not appendApFrameExtras(apm.pendingBeaconBuffer, built,
          req.timOffset.uint32 + req.timLength.uint32, 512, frameExtras):
        break startAp
      req.beaconLength = (built + frameExtras.length).uint16
    elif req.beaconTemplate == nil or req.beaconLength == 0 or req.beaconLength > 512:
      break startAp
    apmStartBeaconMessage = ke_msg_alloc(MM_BCN_CHANGE_REQ, TASK_MM, TASK_APM,
      req.beaconLength.uint32 + offsetof(MmBcnChangeReqPayload, beaconData).uint32)
    apmStartVifMessage = ke_msg_alloc(MM_SET_VIF_STATE_REQ, TASK_MM, TASK_APM,
                                      MmSetVifStateReqPayloadSize)
    if apmStartBeaconMessage == nil or apmStartVifMessage == nil:
      break startAp
    stage(9)
    let rateBits = me_legacy_rate_bitfield_build(addr vif.basicRates[0], 1) and 0xF
    apConfig.highestRateBit = 1
    for rateIndex in 0'u8 .. 3'u8:
      if (rateBits and (1'u32 shl rateIndex)) != 0:
        apConfig.highestRateBit = rateIndex
    if not apm_set_bss_param(param):
      break startAp
    stage(10)
    var txPowerByte = req.channel.txPower.uint8
    var txPowerRateParam: uint8
    tpc_update_vif_tx_power(cast[pointer](vif), addr txPowerByte, addr txPowerRateParam)
    return KeMsgNoFree
  if entered:
    apm.connectInfo = nil
    apmStartConfirmation = nil
    apm.embeddedEnabled = 0
    apm.cryptoType = 0
    apm.securityIe = default(typeof(apm.securityIe))
    apmFreeStartBuffers()
    apmStartSideEffects = false
    if channelAdded:
      if vif.chanCtxt != nil: chan_ctxt_unlink(cfm.vifIdx)
      else: chan_ctxt_del(contextIndex)
    let context = apm.hostapdCtx
    apm.hostapdCtx = nil
    if context != nil and wpa_cbs != nil and wpaCallbacks().apStopped != nil:
      discard cast[proc(p: pointer): bool {.cdecl.}](wpaCallbacks().apStopped)(context)
    ke_state_set(TASK_APM, ApmIdleState)
  cfm.status = status
  ke_msg_send(cfm)
  KeMsgConsumed

proc apm_stop_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## The vendor saves stop requests during startup and stops a live, idle AP.
  if param == nil:
    return KeMsgConsumed
  let header = keMsgHdrFromPayload(param)
  if header.paramLen >= sizeof(ApmStopReqPayload).uint32:
    let vifIdx = apmStopReqView(param).vifIdx
    if vifIdx.int < MAX_VIFS:
      let vif = vifChannelForIdx(vifIdx)
      if apmStartPendingForVif(vifIdx) or (apmStopActive and apmStopVifIdx == vifIdx):
        return KeMsgSaved
      if vif.vifType == VIF_TYPE_AP and apmVifNeedsStop(vifIdx):
        let vifMask = 1'u8 shl vifIdx
        if ke_state_get(TASK_APM) != ApmIdleState or
           (apmStoppingVifs and vifMask) != 0:
          return KeMsgSaved
        if not apmBeginStop(cast[pointer](vif), param):
          return KeMsgSaved
        return KeMsgNoFree
  ke_msg_send_basic(APM_STOP_CFM, header.srcId, header.destId)
  KeMsgConsumed

proc apm_sta_add_cfm_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## A two-byte vendor confirmation is correlated privately, not by MAC alone.
  if param == nil:
    return 0
  let pendingSlot = apmPendingConfirmationSlot(param)
  if pendingSlot < 0:
    inc nimFwDbgApmStaAddNoSlot
    return 0
  let cfm = apmStaAddCfmParamView(param)
  let slot = apmStaSlot(pendingSlot.uint)
  let staIdx = cfm.staIdx
  if cfm.status != 0 or staIdx.int >= STA_INFO_TAB_ENTRIES:
    inc nimFwDbgApmStaAddNoSlot
    nimFwDbgApmStaAddNoSlotSta = staIdx.uint32 or (cfm.status.uint32 shl 8)
    aidListDelete(addr slot.macAddr[0])
    return 0
  let sta = staInfoForIdx(staIdx)
  if slot.active == 0 or sta.valid == 0 or
     sta.instNbr != apmPendingAssociations[pendingSlot].vifIdx or
     c_memcmp(addr slot.macAddr[0], addr sta.macAddr[0], 6.csize_t) != 0:
    aidListDelete(addr slot.macAddr[0])
    return 0
  let context = slot.staHandle
  apmPendingClear(pendingSlot)
  let generation = apmPendingAssociations[pendingSlot].generation
  slot.staIdx = staIdx
  sta.apmWpaContext = context
  if apm_sta_add(staIdx) != 0:
    # Nothing was published to the host, so no asynchronous delete is needed.
    mm_sta_del(staIdx)
    aidListDelete(addr slot.macAddr[0])
    return 0
  # Host publication can synchronously reenter AP management.
  if apmPendingAssociations[pendingSlot].generation != generation or
     slot.active == 0 or slot.staIdx != staIdx or slot.staHandle != context:
    return 0
  if apmEnvView().hostapdCtx != nil and context != nil and wpa_cbs != nil:
    let callback = wpaCallbacks().staAdd
    if callback != nil:
      cast[proc(context: pointer, index: uint8) {.cdecl.}](callback)(context, staIdx)
  0

{.emit: "__attribute__((optimize(\"crossjumping\"))) int apm_sta_del_req_handler(void*);".}
proc apm_sta_del_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## The vendor replies with three bytes and calls remove(vif, sta, 1, 2).
  if param == nil:
    return 0
  let header = keMsgHdrFromPayload(param)
  let requestedSta = if header.paramLen >= sizeof(ApmStaDelReqPayload).uint32:
      apmStaDelReqView(param).staIdxInVif else: 0xFF'u8
  let epoch = staDeleteEpoch(requestedSta)
  let cfm = cast[ptr ApmStaDelCfmPayload](
    ke_msg_alloc(APM_STA_DEL_CFM, header.srcId, header.destId,
                 ApmStaDelCfmPayloadSize))
  if cfm == nil:
    return 0
  cfm[] = default(ApmStaDelCfmPayload)
  cfm.status = 0xFF
  if header.paramLen < sizeof(ApmStaDelReqPayload).uint32:
    ke_msg_send(cfm)
    return 0
  let req = apmStaDelReqView(param)
  let vifLookupIdx = req.vifLookupIdx
  let staIdxInVif = req.staIdxInVif
  if vifLookupIdx.int >= MAX_VIFS or staIdxInVif >= STA_MGMT_FREE_STAS.uint8:
    ke_msg_send(cfm)
    return 0
  let vif = vifChannelForIdx(vifLookupIdx)
  let sta = staInfoForIdx(staIdxInVif)
  if vif.vifType == 2 and staDeleteIsCurrent(staIdxInVif, epoch) and
     sta.instNbr == vifLookupIdx:
    if apm_sta_remove(vifLookupIdx, staIdxInVif,
                      WLAN_FW_APM_DELETESTA_BY_USER.uint16, 2'u16):
      cfm.status = 0
  ke_msg_send(cfm)
  return 0

proc apm_sta_delete*(staIdx: uint8, macAddr: pointer,
                     statusCode, reasonCode: uint16): bool {.exportc, cdecl.} =
  ## apm.o uses four ordinary C arguments. The boolean result is Nim-side
  ## failure reporting; no deletion is started unless both messages exist.
  if staIdx >= STA_MGMT_FREE_STAS.uint8 or macAddr == nil:
    return false
  let sta = staInfoForIdx(staIdx)
  if sta.valid == 0 or c_memcmp(addr sta.macAddr[0], macAddr, 6.csize_t) != 0:
    return false
  let epoch = staDeleteEpoch(staIdx)
  let msg1 = cast[ptr MeStaDelReqPayload](
    ke_msg_alloc(ME_STA_DEL_REQ, TASK_ME, TASK_APM,
                 MeStaDelReqPayloadSize))
  if msg1 == nil:
    return false
  let msg2 = cast[ptr ApmStaDelIndPayload](
    ke_msg_alloc(APM_STA_DEL_IND, TASK_API, TASK_APM,
                 ApmStaDelIndPayloadSize))
  if msg2 == nil:
    ke_msg_free(keMsgHdrFromPayload(msg1))
    return false
  if not staDeleteIsCurrent(staIdx, epoch):
    ke_msg_free(keMsgHdrFromPayload(msg1))
    ke_msg_free(keMsgHdrFromPayload(msg2))
    return false
  aidListDelete(macAddr)
  if not staDeleteIsCurrent(staIdx, epoch):
    ke_msg_free(keMsgHdrFromPayload(msg1))
    ke_msg_free(keMsgHdrFromPayload(msg2))
    return false
  if apmEnvView().hostapdCtx != nil:
    mm_sec_machwkey_del(staIdx + 8'u8)
  if not staDeleteIsCurrent(staIdx, epoch):
    ke_msg_free(keMsgHdrFromPayload(msg1))
    ke_msg_free(keMsgHdrFromPayload(msg2))
    return false
  sta.apmWpaContext = nil
  let logFn = getLogFunc(204)
  let getTimeFn = cast[proc(): uint32 {.cdecl.}](blOpsFunc(200))
  if logFn != nil and getTimeFn != nil:
    let elapsed = getTimeFn() - sta.connectionStart
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn)(
      2, nil, "apm.c", 583,
      "apm_sta_delete:%d, aid:%d, last seen %ld\r\n",
      staIdx.cint, sta.aid.cint, cast[int32](elapsed).clong)
  if not staDeleteIsCurrent(staIdx, epoch):
    ke_msg_free(keMsgHdrFromPayload(msg1))
    ke_msg_free(keMsgHdrFromPayload(msg2))
    return false
  msg2[] = default(ApmStaDelIndPayload)
  msg2.statusCode = statusCode
  msg2.reasonCode = reasonCode
  msg2.staIdx = staIdx
  msg1.staIdx = staIdx
  ke_msg_send(msg2)
  if not staDeleteIsCurrent(staIdx, epoch):
    msg1.staIdx = 0xFF
  ke_msg_send(msg1)
  true

proc apmVifRunning(vifIdx: uint8): bool =
  if vifIdx.int >= MAX_VIFS or
     ((apmPendingCancelMask or apmStoppingVifs) and (1'u8 shl vifIdx)) != 0 or
     apmStartPendingForVif(vifIdx):
    return false
  let vif = vifChannelForIdx(vifIdx)
  vif.vifType == VIF_TYPE_AP and vif.state != 0

proc apm_sta_connect_timeout_ind_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Vendor scans all seven stations and reports status 4, reason 0xffff.
  var running = false
  for vifIdx in 0'u8 ..< MAX_VIFS.uint8:
    if apmVifRunning(vifIdx): running = true
  if not running:
    return KeMsgConsumed
  let getTimeFnPtr = blOpsFunc(200)
  if getTimeFnPtr != nil:
    let now = cast[proc(): uint32 {.cdecl.}](getTimeFnPtr)()
    for apStaSlotIndex in 0'u8 ..< STA_INFO_TAB_ENTRIES.uint8:
      let sta = staInfoForIdx(apStaSlotIndex)
      let connTime = sta.connectionStart
      if sta.valid != 0 and apmVifRunning(sta.instNbr) and connTime != 0 and
         cast[int32](now - connTime) > 30000:
        apm_sta_fw_delete(apStaSlotIndex,
          WLAN_FW_APM_DELETECONNECTION_TIMEOUT.uint16, 0xFFFF'u16)
  for vifIdx in 0'u8 ..< MAX_VIFS.uint8:
    if apmVifRunning(vifIdx):
      ke_timer_set(KE_FIRST_MSG(TASK_APM.uint16) + 6, TASK_APM, 5000000'u32)
      break
  KeMsgConsumed

proc apm_conf_max_sta_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Clamp the requested station limit, then log and confirm to the sender.
  if param == nil:
    return KeMsgConsumed
  let hdr = keMsgHdrFromPayload(param)
  if hdr.paramLen < ApmConfMaxStaReqPayloadSize:
    return KeMsgConsumed
  let replyDest = hdr.srcId
  let replySource = hdr.destId
  let maxSta = min(apmConfMaxStaReqView(param).maxSta, STA_MGMT_FREE_STAS.uint8)
  let logFn = getLogFunc(204)
  apmEnvView().maxSta = maxSta
  if logFn != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn)(
      2, nil, "apm_task.c", 447, "Adjust max_sta_supported to %u\r\n", maxSta.cuint)
  ke_msg_send_basic(APM_CONF_MAX_STA_CFM, replyDest, replySource)
  KeMsgConsumed

# --- ME Task Handlers (me_task.o) ---

proc me_config_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle ME_CONFIG_REQ (216 bytes in blob, 56 instrs).
  ## From blob (me_task.o): copies 32 bytes of HT cap from req to me_env(+8).
  ## Stores req[46] (ht_supp) at me_env.ht_supp(130). Sends ME_CONFIG_CFM (0xc01)
  ## via ke_msg_send_basic. If HT: queries NSS, stores caps.
  ## Copies def_key(req[44]) to me_env(128), ps_on(req[48]) to me_env(133).
  ## If ps_on: starts MM_SET_PS_MODE_REQ(mode=2) with no second host reply.
  if param == nil or keMsgHdrFromPayload(param).paramLen < 49:
    return KeMsgConsumed
  if ke_state_get(TASK_ME) == MeBusyState or
      meConfigInProgress or meControlCommand != nil or meControlReply != nil:
    return KeMsgSaved
  let requester = keMsgHdrFromPayload(param).srcId
  when defined(bl808HeapGuardMsgs):
    proc tlsfCheckHeapRaw(): cint {.importc: "tlsf_check_heap", cdecl.}
    if tlsfCheckHeapRaw() == 0: nimFwDbgHeapGuardStage = 1  # broken on ENTRY
  let me = meEnvView()
  let req = meConfigReqView(param)
  let htSupp = req.htSupp
  let htCaps = req.htCaps
  let defKey = req.defKey
  let psOn = req.psOn
  let htCapInfo = htCaps[0].uint16 or (htCaps[1].uint16 shl 8)
  var controlReply: pointer
  if psOn != 0:
    result = meReserveControl(param, MM_SET_PS_MODE_REQ, 0, 0)
    if result != KeMsgNoFree:
      return
    controlReply = meControlReply
  else:
    meConfigInProgress = true
  defer:
    if psOn == 0:
      meConfigInProgress = false

  me.htSupp = htSupp
  discard c_memcpy(addr me.htCaps[0], unsafeAddr htCaps[0], 32.csize_t)
  when defined(bl808HeapGuardMsgs):
    if nimFwDbgHeapGuardStage == 0 and tlsfCheckHeapRaw() == 0:
      nimFwDbgHeapGuardStage = 2  # broken after HT-caps memcpy
  ke_msg_send_basic(ME_CONFIG_CFM, requester, TASK_ME)
  when defined(bl808HeapGuardMsgs):
    if nimFwDbgHeapGuardStage == 0 and tlsfCheckHeapRaw() == 0:
      nimFwDbgHeapGuardStage = 3  # broken after ke_msg_send_basic(CFM)
  if psOn != 0:
    if meControlCommand != param or meControlReply != controlReply:
      return KeMsgConsumed
  elif not meConfigInProgress:
    return KeMsgConsumed

  if htSupp != 0:
    let nss = phy_get_nss()
    me.nss = ((nss.uint16 + 1) shr 1).uint8
    me.htCapByte = ((htCapInfo shr 1) and 1).uint8
  else:
    me.nss = 0
    me.htCapByte = 0
  me.defKey = defKey
  me.psOn = psOn
  if psOn != 0:
    result = meForwardControl(param, MM_SET_PS_MODE_REQ, 2, controlReply)
  else:
    result = KeMsgConsumed

proc me_chan_config_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle ME_CHAN_CONFIG_REQ: configure channel parameters.
  ## From blob (me_task.o, 0x3c bytes): memcpy(me_env+0x28, param, 86);
  ##   ke_msg_send_basic(ME_CHAN_CONFIG_CFM, destId=srcId_in, srcId=destId_in).
  if param == nil:
    return KeMsgConsumed
  let hdr = keMsgHdrFromPayload(param)
  if hdr.paramLen < meEnvView().chanConfig.len.uint32:
    return KeMsgConsumed
  let srcId = hdr.destId
  let destId = hdr.srcId
  discard c_memcpy(addr meEnvView().chanConfig[0], param, 86.csize_t)
  ke_msg_send_basic(ME_CHAN_CONFIG_CFM, destId, srcId)
  return 0

{.emit: "__attribute__((optimize(\"crossjumping\"))) int me_sta_add_req_handler(void*);".}
proc me_sta_add_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Translate the ME station request to the distinct MM registration layout.
  ## me_task.o passes the CFM station byte as the logical-index output; the
  ## hardware index has separate scratch storage and is not a station index.
  if param == nil:
    return 0
  let requestHeader = keMsgHdrFromPayload(param)
  let sourceId = requestHeader.srcId
  let destinationId = requestHeader.destId
  let requestLength = requestHeader.paramLen
  let fromApm = sourceId == TASK_APM
  let pendingSlot = if fromApm: apmPendingRequestSlot(param, true) else: -1
  if fromApm and pendingSlot < 0:
    return 0
  let pendingGeneration =
    if fromApm: apmPendingAssociations[pendingSlot].generation else: 0'u32
  var requestCopy = default(MeStaAddReqPayload)
  if requestLength >= 86:
    discard c_memcpy(addr requestCopy, param, 86.csize_t)
  let cfm = cast[ptr MeStaAddCfmPayload](
    ke_msg_alloc(ME_STA_ADD_CFM, sourceId, destinationId,
                 MeStaAddCfmPayloadSize))
  let pendingCurrent = fromApm and
    apmPendingAssociations[pendingSlot].generation == pendingGeneration and
    apmPendingRequestSlot(param, true) == pendingSlot
  if cfm == nil:
    if pendingCurrent:
      aidListDelete(addr apmStaSlot(pendingSlot.uint).macAddr[0])
    return 0
  cfm.staIdx = 0xFF
  cfm.status = 1
  if fromApm:
    if not pendingCurrent:
      ke_msg_send(cfm)
      return 0
    apmPendingAssociations[pendingSlot].request = nil
    apmPendingAssociations[pendingSlot].confirmation = cfm
    apmPendingAssociations[pendingSlot].meQueued = false
  # The final meaningful field is dataRate at byte 85; the C structure has
  # two trailing alignment bytes which are not required to parse the request.
  if requestLength < 86:
    ke_msg_send(cfm)
    return 0
  let req = addr requestCopy
  if req.vifIdx.int >= MAX_VIFS or req.supportedRates[0] > 12:
    ke_msg_send(cfm)
    return 0
  let vif = vifChannelForIdx(req.vifIdx)
  var registration: MmStaAddReqPayload
  discard c_memcpy(addr registration.bssid[0], addr req.macAddr[0], 6.csize_t)
  registration.vifIdx = req.vifIdx
  registration.rssi = req.rssi
  registration.tsfLow = req.tsfLow
  registration.tsfHigh = req.tsfHigh
  registration.dataRate = req.dataRate
  let flags = req.capFlags
  if (flags and 2) != 0:
    let ampdu = meStaAddReqHtCaps(req).ampduParams
    mmStaFillAggregation(registration, ampdu)
  var hardwareIndex = 0xFF'u8
  cfm.status = mm_sta_add(addr registration, addr cfm.staIdx, addr hardwareIndex)
  if fromApm and apmPendingAssociations[pendingSlot].confirmation != cfm:
    if cfm.status == 0 and cfm.staIdx.int < STA_INFO_TAB_ENTRIES:
      mm_sta_del(cfm.staIdx)
    cfm.staIdx = 0xFF
    cfm.status = 1
    ke_msg_send(cfm)
    return 0
  if cfm.status != 0 or cfm.staIdx.int >= STA_INFO_TAB_ENTRIES:
    if cfm.status == 0:
      cfm.status = 1
    cfm.staIdx = 0xFF
    ke_msg_send(cfm)
    return 0
  let sta = staInfoForIdx(cfm.staIdx)
  discard c_memcpy(addr sta.supportedRates[0], addr req.supportedRates[0], 13.csize_t)
  if (flags and 1) != 0:
    sta.capabilityFlags = sta.capabilityFlags or 1
    if (flags and 2) != 0 and meEnvView().htSupp != 0:
      sta.capabilityFlags = sta.capabilityFlags or 2
      discard c_memcpy(addr sta.vhtCaps[0], meStaAddReqCapBlock(req), 32.csize_t)
      me_set_sta_ht_vht_param(cast[pointer](sta), cast[pointer](vifHtCapabilities(vif)))
  if (flags and 8) != 0:
    sta.capabilityFlags = sta.capabilityFlags or 8
  sta.psState = req.uapsdQueues
  sta.uapsdBitmap = req.maxServicePeriod
  sta.aid = req.aid
  let rateStationIdx = cfm.staIdx
  let rateStationEpoch = staDeleteEpoch(rateStationIdx)
  let rateInitialized = meTryInitRate(cast[pointer](sta))
  if not rateInitialized or not staDeleteIsCurrent(rateStationIdx, rateStationEpoch) or
      (fromApm and apmPendingAssociations[pendingSlot].confirmation != cfm):
    if staDeleteIsCurrent(rateStationIdx, rateStationEpoch):
      mm_sta_del(rateStationIdx)
    cfm.staIdx = 0xFF
    cfm.status = 1
    ke_msg_send(cfm)
    return 0
  sta.txPolicyUpdateFlags[0] = sta.txPolicyUpdateFlags[0] or StaTxPolicyUpdateTxPower
  let keyFlagByte = (vifKeyPointers(vif).flags and 0xFF).uint8
  let controlPortState = 2'u8 - (keyFlagByte and 1)
  sta.controlPortState = controlPortState
  sta.rateWord = lmacGateHalfword(vif.apStartBeaconInterval)
  ke_msg_send(cfm)
  0

proc me_sta_del_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Send a separate MM delete request, then acknowledge ME acceptance.
  if param == nil or keMsgHdrFromPayload(param).paramLen < MeStaDelReqPayloadSize:
    return KeMsgConsumed
  let header = keMsgHdrFromPayload(param)
  let requester = header.srcId
  let sourceTask = header.destId
  let staIdx = cast[ptr MeStaDelReqPayload](param).staIdx
  let epoch = staDeleteEpoch(staIdx)
  let mmRequest = ke_msg_try_alloc(MM_STA_DEL_REQ, TASK_MM, TASK_ME,
                                   MmStaDelReqPayloadSize)
  if mmRequest == nil:
    return KeMsgSaved
  let reply = ke_msg_try_alloc(ME_STA_DEL_CFM, requester, sourceTask, 0)
  if reply == nil:
    ke_msg_free(keMsgHdrFromPayload(mmRequest))
    return KeMsgSaved
  mmStaDelReqView(mmRequest).staIdx =
    if staDeleteIsCurrent(staIdx, epoch): staIdx else: 0xFF'u8
  ke_msg_send(mmRequest)
  ke_msg_send(reply)
  KeMsgConsumed

{.emit: "__attribute__((optimize(\"crossjumping\"))) int me_set_active_req_handler(void*);".}
proc me_set_active_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Complete locally only when no MM transition is needed. Otherwise confirm
  ## the requester after MM_SET_IDLE_CFM, not before MAC state has changed.
  when defined(bl808WifiApHttpSmoke):
    if param != nil and param == apmStartRequest and not apmRollbackActive:
      nimfwApTiming[4] = regRead(ClicMtimeBase)
  if param == nil or keMsgHdrFromPayload(param).paramLen < MeSetActiveReqPayloadSize:
    return KeMsgConsumed
  if smStaleRequest(param):
    return KeMsgConsumed
  let state = ke_state_get(TASK_ME)
  if state == MeBusyState:
    return KeMsgSaved
  let me = meEnvView()
  let oldMask = me.activeMask
  let req = cast[ptr MeSetActiveReqPayload](param)
  let active = req.active
  let vifIdx = req.vifIdx
  if vifIdx >= MAX_VIFS.uint8:
    return KeMsgConsumed
  let activeVifMaskBit = 1'u32 shl vifIdx
  if oldMask == 0 and active == 0:
    # Already all inactive, just send basic cfm
    ke_msg_send_basic_reply(param, ME_SET_ACTIVE_CFM)
    return KeMsgConsumed
  if oldMask != 0 and active != 0:
    # Set bit and send basic (already active path)
    me.activeMask = oldMask or activeVifMaskBit
    ke_msg_send_basic_reply(param, ME_SET_ACTIVE_CFM)
    return KeMsgConsumed
  var newMask: uint32
  if active != 0:
    newMask = oldMask or activeVifMaskBit
  else:
    newMask = oldMask and (not activeVifMaskBit)
  meBeginControl(param, MM_SET_IDLE_REQ, uint8(newMask == 0),
                 ME_SET_ACTIVE_CFM, newMask)

proc me_set_active_cfm_handler_sm*(param: pointer): cint {.exportc: "me_set_active_cfm_handler_sm", cdecl, discardable.} =
  ## Blob sm_task.o::me_set_active_cfm_handler (136 bytes): asserts state 4
  ## or 10 (line 690); in state 10 sets SM idle; otherwise sends the
  ## deauthentication sm_init asked for (sm_env[17]) and starts
  ## authentication. Here only SM's live answer is taken: in state 10 the
  ## cleanup's last, after which it goes idle by itself; otherwise the BSS
  ## batch's last.
  if not smTakeAnswer(param): return 0
  if ke_state_get(TASK_SM) == SmDisconnectingState:
    smCleanupConfirmed()
    return 0
  let sm = smEnvView()
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] active_flag ", sm.deauthPending.uint32,
                          ke_state_get(TASK_SM).uint32)
  if sm.deauthPending != 0:
    var build = smTxBegin(sm.connectInfo)
    smDeauthSend(build)
    smTxEnd(build)
    sm.deauthPending = 0
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] active_cfm ", ke_state_get(TASK_SM).uint32,
                          cast[uint32](cast[uint](sm.connectInfo)))
    nimFwConnectTraceHw("[WIFI-CT] active_hw ")
  sm_auth_start()
  return 0

proc me_set_active_cfm_handler_apm*(param: pointer): cint {.exportc: "me_set_active_cfm_handler_apm", cdecl, discardable.} =
  ## Only the reply to this startup's final BSS request may publish its beacon.
  if apmConsumeStartReply(param):
    if apmRollbackActive:
      apmContinueStartRollback()
    elif ke_state_get(TASK_APM) == ApmActiveState:
      assert apmEnvView().pendingBssParams.first == nil
      apm_bcn_set(nil)
    else:
      apm_start_cfm(cast[pointer](1'u))
  KeMsgConsumed

{.emit: "__attribute__((optimize(\"crossjumping\"))) int me_set_ps_disable_req_handler(void*);".}
proc me_set_ps_disable_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle ME_SET_PS_DISABLE_REQ (206 bytes in blob, 54 instrs).
  ## From blob (me_task.o): Nearly identical to me_set_active_req_handler but
  ## operates on me_env.ps_disable_mask (offset 4). Early exit if ps_on==0.
  ## Same bitmask set/clear pattern. Status = seqz * 2 (0 or 2).
  if param == nil or keMsgHdrFromPayload(param).paramLen < MeSetPsDisableReqPayloadSize:
    return KeMsgConsumed
  if smStaleRequest(param):
    return KeMsgConsumed
  let req = cast[ptr MeSetPsDisableReqPayload](param)
  if req.vifIdx >= MAX_VIFS.uint8:
    return KeMsgConsumed
  let me = meEnvView()
  if me.psOn == 0:
    # PS not configured, just send basic cfm
    ke_msg_send_basic_reply(param, ME_SET_PS_DISABLE_CFM)
    return KeMsgConsumed
  let state = ke_state_get(TASK_ME)
  if state == MeBusyState:
    return KeMsgSaved
  let oldMask = me.psDisableMask
  let psDisable = req.disable
  let vifIdx = req.vifIdx
  let psDisableVifMaskBit = 1'u32 shl vifIdx
  if oldMask == 0 and psDisable == 0:
    ke_msg_send_basic_reply(param, ME_SET_PS_DISABLE_CFM)
    return KeMsgConsumed
  if oldMask != 0 and psDisable != 0:
    me.psDisableMask = oldMask or psDisableVifMaskBit
    ke_msg_send_basic_reply(param, ME_SET_PS_DISABLE_CFM)
    return KeMsgConsumed
  # Main path
  var newMask: uint32
  if psDisable != 0:
    newMask = oldMask or psDisableVifMaskBit
  else:
    newMask = oldMask and (not psDisableVifMaskBit)
  meBeginControl(param, MM_SET_PS_MODE_REQ, (if newMask == 0: 2'u8 else: 0'u8),
                 ME_SET_PS_DISABLE_CFM, newMask)

proc me_set_ps_disable_cfm_handler_sm*(param: pointer): cint {.exportc: "me_set_ps_disable_cfm_handler_sm", cdecl, discardable.} =
  ## Blob sm_task.o (108 bytes): asserts state 4, 0 or 10 (line 630), then
  ## sends the next BSS parameter in state 4. The pinned activation sends its
  ## ME_SET_PS_DISABLE_REQ without waiting. Here only SM's live answer is
  ## taken: the BSS batch's first request in state 4, the activation's last
  ## in state 9, or the cleanup's first in state 10.
  if not smTakeAnswer(param): return KeMsgConsumed
  case ke_state_get(TASK_SM)
  of SM_ACTIVATING_STATE: smActivationConfirmed()
  of SmDisconnectingState: smCleanupConfirmed()
  else: sm_send_next_bss_param()
  KeMsgConsumed

proc me_set_ps_disable_cfm_handler_apm*(param: pointer): cint {.exportc: "me_set_ps_disable_cfm_handler_apm", cdecl, discardable.} =
  ## A stop reply or a duplicate cannot consume the next startup BSS request.
  if apmConsumeStartReply(param):
    if apmRollbackActive:
      apmContinueStartRollback()
    elif ke_state_get(TASK_APM) == ApmActiveState:
      apm_send_next_bss_param(param)
    else:
      apm_start_cfm(cast[pointer](1'u))
  KeMsgConsumed


proc me_rc_set_rate_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Select fixed or automatic rates using the vendor's RC-state ABI.
  if param == nil or
      keMsgHdrFromPayload(param).paramLen < MeRcSetRateReqPayloadSize:
    return 0
  let req = meRcSetRateReqView(param)
  let staIdx = req.staIdx
  if staIdx.int >= STA_INFO_TAB_ENTRIES:
    return 0
  let sta = staInfoForIdx(staIdx)
  if sta.valid == 0:
    return 0
  let rcPtr = sta.rcStats
  if rcPtr == nil:
    assert_err("me_task.c", "me_task.c", 653)
    return 0
  let caps = rcRateCapabilities(rcPtr)
  let control = rcTrialControl(rcPtr)
  let fixedRate = req.fixedRate
  if fixedRate == 0xFFFF:
    when defined(bl808m0):
      if caps.fixedRate != fixedRate:
        rcInvalidateTrialTag(sta.infoIdx)
    caps.fixedRate = 0xFFFF'u16
    control.info = control.info and not 0x60'u8
    rc_update_bw_nss_max(
      sta.infoIdx, caps.maxBandwidth, caps.maxNss)
  elif rc_check_fixed_rate_config(rcPtr, fixedRate):
    when defined(bl808m0):
      if caps.fixedRate != fixedRate:
        rcInvalidateTrialTag(sta.infoIdx)
    caps.fixedRate = fixedRate
    control.info = (control.info and not 0x60'u8) or 0x20'u8
  if req.mcsRate != 0:
    sta.txPolicyUpdateFlags[0] = sta.txPolicyUpdateFlags[0] or StaTxPolicyUpdateTxPower
  return 0

proc me_traffic_ind_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Update station traffic flags and, for a sleeping station, request a TIM
  ## bitmap update from MM before acknowledging the original ME request.
  if param == nil: return KeMsgConsumed
  let header = keMsgHdrFromPayload(param)
  if header.paramLen < MeTrafficIndReqPayloadSize: return KeMsgConsumed
  let requester = header.srcId
  let sourceTask = header.destId
  let req = meTrafficIndReqView(param)
  let staIdx = req.staIdx
  if staIdx >= STA_INFO_TAB_ENTRIES.uint8: return KeMsgConsumed
  let uapsd = req.uapsd
  let txAvail = req.txAvail
  let sta = staInfoForIdx(staIdx)
  var flags = sta.trafficFlags
  if txAvail != 0:
    if uapsd != 0:
      flags = flags or 4  # Set uapsd bit
    else:
      flags = flags and not 4'u8  # Clear uapsd bit
  else:
    if uapsd != 0:
      flags = flags or 1  # Set rx traffic bit
    else:
      flags = flags and not 1'u8  # Clear rx traffic bit
  sta.trafficFlags = flags
  # The vendor's message ID 47 is MM_TIM_UPDATE_REQ, not an ME confirmation.
  if sta.psState == 15:
    let aid = sta.aid
    let vifIdx = sta.instNbr
    let tim = cast[ptr MmTimUpdatePayload](
      ke_msg_alloc(MM_TIM_UPDATE_REQ, TASK_MM, TASK_ME,
                   MmTimUpdatePayloadSize))
    if tim != nil:
      tim.aid = aid
      tim.setFlag = uapsd
      tim.vifIdx = vifIdx
      ke_msg_send(tim)
  ke_msg_send_basic(ME_TRAFFIC_IND_CFM, requester, sourceTask)
  KeMsgConsumed

# me_build_associate_req is already implemented at line ~11115 via
# me_build_associate_req_impl with the correct 7-argument blob ABI.

# --- CFG Task Handler (cfg_task.o) ---

proc cfg_start_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Decode SET into one scalar, dispatch it, then acknowledge the CFG request.
  if param == nil:
    return 0
  let hdr = keMsgHdrFromPayload(param)
  if hdr.paramLen < 4:
    return 0
  let destinationId = hdr.srcId
  let sourceId = hdr.destId
  let req = cast[ptr CfgStartReqPayload](param)
  case req.operation
  of 0:
    if hdr.paramLen >= 20 and req.length <= hdr.paramLen - 20:
      let taskId = req.taskId
      let element = req.element
      let valueType = req.valueType
      let valueLength = req.length
      # Zero the unused upper bytes of Boolean results before diagnostic output.
      var decoded: uint32
      let unpacked = c_utils_tlv_bl_unpack_auto(cast[ptr uint32](addr req.data[0]),
        cast[cint](valueLength), cast[uint16](valueType), addr decoded)
      let printFn = cast[proc(format: cstring) {.cdecl, varargs.}](blOpsFunc(4))
      if printFn != nil:
        printFn("unpack ret is %d, result is %lu\r\n", unpacked, decoded.culong)
      if unpacked == 4 and valueLength == 4:
        discard cfg_api_element_set(taskId, element, valueType, addr decoded, nil)
  of 1, 2:
    discard # GET and RESET are no-ops in the pinned handler.
  else:
    dump_cfg_entries()
  let cfm = cast[ptr StatusCfmPayload](
    ke_msg_alloc(CFG_START_CFM, destinationId, sourceId, StatusCfmPayloadSize))
  if cfm != nil:
    cfm.status = 0
    ke_msg_send(cfm)
  return 0

# --- Channel Management (chan.o) missing functions ---

proc chan_get_dominant_chan*(): pointer {.exportc, cdecl, noinline.} =
  ## Get the dominant channel context (highest priority active channel).
  ## The reconnect flag enables the dominant context stored in chan_env+0x28.
  ## noinline: blob calls this as a real function from chan_ctxt_use_dominant_chan.
  if sm_reconn_dominant_flag == 0:
    return nil
  return chanEnvView().dominantCtxt

proc chan_get_next_chan*(): pointer {.exportc, cdecl.} =
  ## Preserve imminent/current operations, fit an earlier TBTT when possible,
  ## otherwise select the active context with the largest remaining budget.
  let env = chanEnvView()
  let curChan = env.currentCtxt
  let tbttEntry = cast[pointer](env.tbttSwitchList.first)
  let macTime = regRead(MACHW_TIMLO_REG)
  let timestamp = env.nextChanTimestamp
  var best = curChan
  if curChan != nil:
    if tbttEntry != nil:
      let tbttNode = chanTbttNodeAt(tbttEntry)
      if tbttNode.state == 2:
        return curChan
    let margin = macTime + 5120'u32
    if cast[int32](margin - timestamp) >= 0:
      return curChan
    if chanCtxtAt(curChan).status == 4:
      return curChan
  if tbttEntry != nil:
    let tbttNode = chanTbttNodeAt(tbttEntry)
    let tbttDeadline = tbttNode.targetTime
    if cast[int32](tbttDeadline - timestamp) < 0:
      if tbttNode.vifIdx >= MAX_VIFS.uint8:
        assert_err("chan.c", "chan.c", 338)
        return nil
      best = vifChannelForIdx(tbttNode.vifIdx).chanCtxt
      if best == nil:
        assert_err("chan.c", "chan.c", 338)
        return nil
      let margin2 = macTime + 5120'u32
      if cast[int32](margin2 - tbttDeadline) >= 0:
        return best
      let bestCtxt = chanCtxtAt(best)
      let availableSlots = if bestCtxt.opSlot > bestCtxt.tbttSlot:
        bestCtxt.opSlot - bestCtxt.tbttSlot
      else:
        0'u16
      let requiredSlots = ((tbttDeadline - macTime) shr 10) and 0xFFFF'u32
      if availableSlots.uint32 >= requiredSlots:
        return best
  var bestPrio: uint16 = 0
  for channelContextPoolIndex in 0'u8 .. 2'u8:
    let cand = chanCtxtForIdx(channelContextPoolIndex)
    if cand.status != 0:
      let candPrio = cand.opSlot
      if candPrio >= bestPrio:
        best = cast[pointer](cand)
        bestPrio = candPrio
  if best == nil:
    assert_err("chan.c", "chan.c", 414)
  return best

proc chan_switch_start*(chanCtxt: pointer) {.exportc, cdecl.} =
  ## Start channel switch (130 bytes in blob, 33 instrs).
  ## From blob (chan.o): if chanCtxt == current_channel(32): checks
  ## chan_env[124] (count>1) and current_channel[23] (type<=2), if ok
  ## tail-calls chan_upd_ctxt_status(chanCtxt, 4). If chanCtxt != current:
  ## checks pending(36) not nil -> return. Stores chanCtxt to pending,
  ## calls chan_upd_ctxt_status(chanCtxt, 2), allocs msg (id=74, 4 bytes),
  ## stores callback pointer, sets chan_env[123]=1, tail-calls ke_msg_send.
  ## Port: the request is the switch's static message, so a start cannot
  ## fail for lack of memory (the blob asserts in ke_msg_alloc instead).
  let saved = irqSave()
  defer: irqRestore(saved)
  let env = chanEnvView()
  if chanCtxt == nil:
    return
  let curCtxt = env.currentCtxt
  if curCtxt == chanCtxt:
    # Same channel: check context conditions
    let ctxtCount = env.ctxtCount
    if ctxtCount <= 1:
      return
    if chanCtxtAt(curCtxt).contextIndexOrMarker > 2:
      return
    chan_upd_ctxt_status(chanCtxt, 4)
    return
  # Different channel: check if another switch is pending
  if env.scheduledCtxt != nil or chanSwitchSlot(chanCtxt) < 0:
    return
  env.scheduledCtxt = chanCtxt
  chan_upd_ctxt_status(chanCtxt, 2)
  if env.scheduledCtxt == chanCtxt: chanSwitchBegin()

proc chan_tbtt_schedule*(tbttEntry: pointer) {.exportc, cdecl.} =
  ## Insert/update a TBTT, advance displaced nodes by their beacon periods,
  ## and arm the head or process it immediately within the two-ms window.
  let saved = irqSave()
  defer: irqRestore(saved)
  var operation: ChanTbttSnapshot
  chanTbttBegin(operation)
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  if tbttEntry != nil:
    # Insert the new TBTT entry
    if not chanTbttInsert(tbttEntry, operation, saved): return
    # Process all entries in the TBTT list
    let tbttList = chanTbttReschedList()
    while tbttList.first != nil:
      if not chanTbttCurrent(operation): return
      let poppedTbttListNode = co_list_pop_front(tbttList)
      if poppedTbttListNode == nil:
        break
      let tbttNode = chanTbttNodeAt(cast[pointer](poppedTbttListNode))
      let tbttVifIdx = tbttNode.vifIdx
      if tbttVifIdx >= MAX_VIFS.uint8:
        outside: assert_warn("chan.c", "chan.c", 2033)
        continue
      let vif = vifChannelForIdx(tbttVifIdx)
      # Check if AP with beacon (vif.ap_bcn_present at offset 86)
      var interval: uint32
      if vif.vifType != 0:
        # AP: beacon interval in TU, convert to microseconds (* 1024)
        interval = vif.apBeaconInterval.uint32 shl 10
      else:
        # STA: get beacon interval from sta_info
        if vif.staIdx < STA_INFO_TAB_ENTRIES.uint8:
          interval = staInfoForIdx(vif.staIdx).initialRateConfig
      if interval == 0:
        # An invalid beacon period must not keep requeueing the same event.
        outside: assert_warn("chan.c", "chan.c", 2033)
        continue
      # Update next_tbtt_time
      let previousTargetTime = tbttNode.targetTime
      tbttNode.targetTime = previousTargetTime + interval
      # Increment miss_count (cap at 5)
      let missedTbttCount = tbttNode.priority
      if missedTbttCount <= 4:
        tbttNode.priority = missedTbttCount + 1
      # Re-insert into sorted list
      if not chanTbttInsert(cast[pointer](poppedTbttListNode), operation, saved): return
  if not chanTbttCurrent(operation): return
  # The single timer belongs to the head, never to a node overtaken or removed.
  let tbttSwitch = cast[pointer](chanTbttPrimaryList().first)
  let timerOwner = chanTbttDeferredSlot()[]
  if timerOwner != nil and timerOwner != tbttSwitch:
    let previous = chanTbttNodeAt(timerOwner)
    if previous.state == 1:
      previous.state = 0
    chanTbttDeferredSlot()[] = nil
    outside: mm_timer_clear(chanTbttTimer())
    if not chanTbttCurrent(operation): return
  if tbttSwitch == nil:
    return
  let switchNode = chanTbttNodeAt(tbttSwitch)
  if switchNode.state == 1 and chanTbttDeferredSlot()[] != tbttSwitch:
    switchNode.state = 0
  let processed = switchNode.state
  if processed != 0:
    return
  # Check time until TBTT
  let tbttTime = switchNode.targetTime
  let macTime = regRead(MACHW_TIMLO_REG)
  if not chanTbttCurrent(operation) or
      cast[pointer](chanTbttPrimaryList().first) != tbttSwitch or
      switchNode.targetTime != tbttTime or switchNode.state != 0:
    return
  let timeUntil = cast[int32](tbttTime - macTime - 2000'u32)
  if timeUntil < 0:
    # Time is past, switch immediately
    if chanTbttDeferredSlot()[] != nil:
      chanTbttDeferredSlot()[] = nil
      outside: mm_timer_clear(chanTbttTimer())
      if not chanTbttCurrent(operation): return
    outside: chan_tbtt_switch_evt(tbttSwitch)
    return
  # Schedule deferred switch: mark processed, set timer
  chanTbttDeferredSlot()[] = tbttSwitch
  switchNode.state = 1  # processed = true
  outside: mm_timer_set(chanTbttTimer(), tbttTime)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void chan_goto_idle_cb(void);".}
proc chan_goto_idle_cb*() {.exportc, cdecl.} =
  ## Channel idle callback (476 bytes in blob, 223 instrs).
  ## From blob (chan.o): clears cca_busy(0x7b). Checks chan_ctxt(0x24) - if nil, return.
  ## Calls mm_force_idle_req(). Checks current_channel(0x20) and flags(0x78) bit5.
  ## If ok: calls blmac_pwr_mgt_setf(1). Two linked-list loops over vif_mgmt_env:
  ## Loop 1 (STA VIFs): for each STA with matching chan_ctxt, active, valid sta_idx,
  ##   and PS state ok: sends null frame via txl_frame_send_null_frame.
  ## Loop 2 (AP VIFs): for each AP with matching chan_ctxt and active:
  ##   sends self-CTS via txl_frame_send_selfcts_frame.
  ## If any frames sent: chan_upd_ctxt_status(chan_ctxt, 3) then tail-call mm_active().
  ## Otherwise: tail-call chan_pre_switch_channel().
  ##
  ## Port: runs for a queued switch (from its request) and again when the
  ## departure's protection times out (chan_ctxt_op_evt). Each run is a new
  ## protection generation. Frames are counted before they are sent, a
  ## refused one is uncounted, and frames that finish while this is still
  ## sending only count (chanSw.building); the tail then waits or departs.
  ## A PS-enabled STA ends sending early, as in the blob, but frames already
  ## sent are still waited for. A failed forced idle asks MM again after the
  ## recovery it posted.
  let env = chanEnvView()
  # Clear CCA busy flag
  env.switchPending = 0
  # Check if channel context exists
  let chanCtxt = env.scheduledCtxt
  if chanCtxt == nil or chanSw.phase notin {swQueued, swProtecting}:
    return
  chanProtectionBegin()
  let serial = chanSw.serial
  template ended(): bool = chanSw.serial != serial
  # Force idle
  if not chanForceIdle():
    if not ended(): chanSwitchSend()
    return
  if ended():
    mmLeaveHwActive()
    return
  # Check current channel and flags
  let curChan = env.currentCtxt
  if curChan == nil or (env.flags and 0x20) != 0:
    # No current channel or busy: skip to pre-switch
    chan_pre_switch_channel()
    return
  let curChanAddr = cast[uint](curChan)
  chanSw.phase = swProtecting
  chanSw.building = true
  chanSw.pmSet = true
  # Set power management flag
  blmac_pwr_mgt_setf(1)
  let token = chanProtectionToken()
  var accepted = false
  template protect(pending: untyped; send: untyped) =
    # The old channel must admit these frames before the new one starts.
    let current = chanCtxtAt(curChan)
    let oldStatus = current.status
    current.status = 6
    inc pending
    let refused = send != 0
    if current.status == 6: current.status = oldStatus
    if ended(): return
    if refused: dec pending
    else: accepted = true
  var selfctsDurationMs = 0'u16
  let ps = psEnvView()
  let vifMgmt = vifMgmtEnvView()
  block build:
    # Loop 1: iterate STA VIFs and send null frames
    var vifNode = cast[pointer](vifMgmt.activeList.first)
    while vifNode != nil:
      let vif = vifChannelAt(cast[pointer](vifNode))
      let vifType = vif.vifType
      let vifChanCtxt = vif.chanCtxt
      if vifType == VIF_TYPE_STA and vifChanCtxt != nil:
        let durationMs = (chanCtxtAt(vifChanCtxt).schedSlot.uint32 shl 10) div 1000
        selfctsDurationMs = (durationMs and 0xFFFF'u32).uint16
        # STA VIF with channel context
        if cast[uint](vifChanCtxt) == curChanAddr:
          let active = vif.state
          let staIdx = vif.staIdx
          if active != 0 and staIdx < STA_INFO_TAB_ENTRIES.uint8:
            if ps.enabled != 0 and (ps.statusFlags and 8) == 0:
              break build
            protect(env.scanDelayCount,
                    txl_frame_send_null_frame(staIdx, cast[pointer](chan_sta_tx_cfm), token))
      vifNode = vif.next
    # Loop 2: iterate AP VIFs and send self-CTS
    vifNode = cast[pointer](vifMgmt.activeList.first)
    while vifNode != nil:
      let vif = vifChannelAt(cast[pointer](vifNode))
      let vifType = vif.vifType
      let vifChanCtxt = vif.chanCtxt
      if vifType == VIF_TYPE_AP and vifChanCtxt != nil:
        if cast[uint](vifChanCtxt) == curChanAddr and env.ctxtCount == 2 and
            selfctsDurationMs != 0:
          let active = vif.state
          if active != 0:
            if vif.postponedStaHead != nil:
              protect(env.connlessDelayCount, txl_frame_send_selfcts_frame(
                vifNode, selfctsDurationMs, cast[pointer](chan_ap_tx_cfm), token))
      vifNode = vif.next
  chanSw.building = false
  if env.scanDelayCount != 0 or env.connlessDelayCount != 0:
    # Frames sent: mark context as PAUSED and reactivate
    chan_upd_ctxt_status(env.scheduledCtxt, 3)
    mm_active()
  elif accepted:
    # Every frame finished while it was being sent.
    chanSwitchDepart()
  else:
    chan_pre_switch_channel()

proc chanConnLessDelay(flags, ctxtCount, scanChannel: uint8; hasAp: bool): uint32 {.inline.} =
  const DelayUnit = 0x7530'u32
  if ctxtCount == 0:
    return 0
  if (flags and 0x01) != 0:
    return DelayUnit
  if (flags and 0x02) == 0:
    return DelayUnit
  if scanChannel == 0:
    return DelayUnit

  let nextCnt = (scanChannel.uint32 + 1) and 3
  if not hasAp and nextCnt != 0:
    return DelayUnit
  if ctxtCount <= 1:
    return DelayUnit * (if hasAp: 8'u32 else: 4'u32)
  if cast[int8](flags) < 0:
    DelayUnit * 16
  else:
    DelayUnit * 8

{.emit: "__attribute__((optimize(\"crossjumping\"))) void chan_conn_less_delay_prog(void);".}
proc chan_conn_less_delay_prog*() {.exportc, cdecl.} =
  ## Program connectionless delay timer (67 instrs, 190 bytes in blob).
  ## From blob (chan.o): checks chan_env flags bit 4 (0x10). If set, returns.
  ## Otherwise sets bit 4, reads MAC timestamp, reads chan_env[124] count.
  ## AP presence, scan cursor, and conflict flags select 1/4/8/16 * 30000 us.
  let saved = irqSave()
  defer: irqRestore(saved)
  let env = chanEnvView()
  let flags = env.flags
  if (flags and 0x10) != 0:
    return
  var mutation: MmTimerMutation
  mmTimerBeginMutation(mutation, chanConnLessDelayTimer())
  defer: mmTimerEndMutation(mutation)
  inc chanConnlessGeneration
  let generation = chanConnlessGeneration
  let resetEpoch = txResetEpoch
  let ctxtCount = env.ctxtCount
  let scanChannel = scan_env.channelIndex
  let scanEpoch = chanCtxtEpochs[3]
  let rocEpoch = chanCtxtEpochs[4]
  let vifs = rxVifEpochs
  let reservedFlags = flags or 0x10'u8
  env.flags = reservedFlags
  defer:
    if chanConnlessGeneration == generation and txResetEpoch == resetEpoch and
        not chanConnlessTimerPending(generation):
      env.flags = env.flags and not 0x10'u8
  template ownsGate(): bool =
    not mutation.cancelled and chanConnlessGeneration == generation and
      txResetEpoch == resetEpoch
  template current(): bool =
    ownsGate() and env.flags == reservedFlags and
      env.ctxtCount == ctxtCount and scan_env.channelIndex == scanChannel and
      chanCtxtEpochs[3] == scanEpoch and chanCtxtEpochs[4] == rocEpoch and
      equalMem(addr rxVifEpochs, unsafeAddr vifs, sizeof(vifs))
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  block prepare:
    outside:
      nimFwTrace2U32("[WIFI-NIMFW] cld_prog flags ", flags.uint32, ctxtCount.uint32)
    if not current(): break prepare
    let macTime = regRead(MACHW_TIMLO_REG)
    if not current(): break prepare
    var hasAp = false
    if ctxtCount != 0 and (flags and 1) == 0 and (flags and 2) != 0 and scanChannel != 0:
      outside: hasAp = vif_mgmt_get_first_ap_inf() != nil
      if not current(): break prepare
    let delay = chanConnLessDelay(flags, ctxtCount, scanChannel, hasAp)
    outside: nimFwTrace2U32("[WIFI-NIMFW] cld_prog delay ", macTime, delay)
    if not current(): break prepare
    mmTimerSetLocked(chanConnLessDelayTimer(), macTime + delay, saved)
    return

  # The other slot can join while the reservation bit is set. Its call did
  # not arm a timer. Keep the reservation if the original waiter still owns
  # its slot, and use the combined delay (ROC wins, so no AP lookup).
  template joined(): bool =
    ownsGate() and
      (((flags and 3) == 2 and env.flags == (reservedFlags or 1) and
        chanCtxtEpochs[3] == scanEpoch) or
       ((flags and 3) == 1 and env.flags == (reservedFlags or 2) and
        chanCtxtEpochs[4] == rocEpoch))
  if not joined(): return
  let macTime = regRead(MACHW_TIMLO_REG)
  if joined():
    let delay = chanConnLessDelay(env.flags, env.ctxtCount, scan_env.channelIndex, false)
    mmTimerSetLocked(chanConnLessDelayTimer(), macTime + delay, saved)

proc chan_ap_tx_cfm*(param: pointer, status: uint32) {.exportc, cdecl.} =
  ## TX confirmation for AP mode channel management (17 instrs).
  ## Blob: decrement chan_env[122]; at zero with [121] zero, force idle and
  ## pre-switch. Any status counts, a TX reset's flush included.
  let saved = irqSave()
  defer: irqRestore(saved)
  chanProtectionDone(param, chanEnvView().connlessDelayCount)

proc chan_sta_tx_cfm*(param: pointer, status: uint32) {.exportc, cdecl.} =
  ## TX confirmation for STA mode channel management (17 instrs).
  ## Blob: decrement chan_env[121]; at zero with [122] zero, force idle and
  ## pre-switch. Any status counts, a TX reset's flush included.
  let saved = irqSave()
  defer: irqRestore(saved)
  chanProtectionDone(param, chanEnvView().scanDelayCount)

# --- TX/RX Functions ---

proc txl_get_seq_ctrl*(): uint16 {.exportc, cdecl.} =
  ## Get next TX sequence control number.
  ## From blob (sm.o local txl_get_seq_ctrl, 8 instrs): reads the global
  ## sequence counter halfword, increments/stores it as a halfword, then returns
  ## the low 16 bits of (counter << 4) for the Sequence Control field.
  let seqCtrl = nextTxSeqCtrl()
  txlSeqRetained = txControlEnv().seqCounter
  nimFwDbgTxSeqLast = seqCtrl.uint32
  nimFwDbgTxSeqCounter = txlSeqRetained.uint32
  return seqCtrl

proc txl_int_fake_transfer*(txDesc: pointer, queueIdx: uint32) {.exportc, cdecl.} =
  ## Fake DMA transfer for internal TX frames (52 bytes in blob, 17 instrs).
  ## From blob: loads THD from desc+108, writes CAFEFADE at THD+72 (status),
  ## stores back-pointer at THD+20, links THD into internal queue via
  ## index computed from a1+22, clears THD+16 (next pointer).
  let desc = hostTxDescAt(txDesc)
  let link = hostTxInternalLinkNodeAt(desc.bufDesc)
  # Publication must stay callback-free, as in the vendor's 52-byte helper.
  let isNullDataFrame =
    link != nil and link.macHeader[0] == 0x48'u8 and link.macHeader[1] == 0x01'u8
  let isTrackedByCallback =
    desc.callback != nil and
    cast[uint32](cast[uint](desc.callback)) == nimFwDbgNullFrameCbSetPtr
  let isTrackedNullFrame = isNullDataFrame or isTrackedByCallback
  # Write fake transfer status marker at THD+72
  link.headerThd.magic = 0xCAFEFADE'u32
  # Store back-pointer to TX descriptor at THD+20
  link.txDesc = txDesc
  # Compute queue entry index (a1 + 22). Each backup queue entry in
  # txl_buffer_env is {head, tail}; the blob stores head at entry+4 and tail at
  # entry+8 after the T-Head indexed-address instruction.
  let head = txBackupQueueHeadPtr(queueIdx)
  let tailPtr = txBackupQueueTailPtr(queueIdx)
  if isTrackedNullFrame:
    inc nimFwDbgNullFrameFakeSeen
    nimFwDbgNullFrameFakeQidx = queueIdx
    nimFwDbgNullFrameFakeLink = pointerAddrU32(cast[pointer](link))
    nimFwDbgNullFrameFakeHeadBefore = pointerAddrU32(head[])
    nimFwDbgNullFrameFakeTailBefore = pointerAddrU32(tailPtr[])
  if head[] == nil:
    head[] = cast[pointer](link)
  else:
    hostTxInternalLinkNodeAt(tailPtr[]).next = cast[pointer](link)
  tailPtr[] = cast[pointer](link)
  link.next = nil
  if isTrackedNullFrame:
    nimFwDbgNullFrameFakeHeadAfter = pointerAddrU32(head[])
    nimFwDbgNullFrameFakeTailAfter = pointerAddrU32(tailPtr[])

proc cfm_raw_send*(param: pointer; status: uint32) {.exportc, cdecl.} =
  ## scanu_task.o replaces a0 with its format string and preserves a1 (status).
  ## The relocation selects g_bl_ops_funcs+4, the printf hook, not a TX owner.
  let logFn = blOpsFunc(4)
  if logFn != nil:
    cast[proc(fmt: cstring) {.cdecl, varargs.}](logFn)(
      "send complete, status is %08lX\r\n", status.culong)

proc txSecKeyFor(desc: ptr HostTxDescView): ptr VifKeySlotView {.inline.} =
  let sta = staInfoForIdx(desc.staInfoIdx)
  let keyMatPtr = sta.keyMat
  nimFwDbgTxSecHdrStaKey0 = sta.keyType.uint32 or
    (sta.cipherSuite.uint32 shl 8) or
    (sta.hwKeyIdx.uint32 shl 16) or
    (sta.keyInstalled.uint32 shl 24)
  nimFwDbgTxSecHdrStaKey1 = pointerAddrU32(cast[pointer](addr sta.keyHolder))
  nimFwDbgTxSecHdrStaKey2 = pointerAddrU32(sta.keyHolder)
  if keyMatPtr == nil:
    inc nimFwDbgTxSecHdrNoKeyMat
    nimFwDbgTxSecHdrMissMeta = desc.staInfoIdx.uint32 or
      (desc.vifIdx.uint32 shl 8)
    nimFwDbgTxSecHdrMissLen = desc.frameLen.uint32
    nimFwDbgTxSecHdrMissKeyMat = 0
    return nil
  let keySlot = txSecurityKeyListAt(keyMatPtr).pairwiseKey
  if keySlot == nil:
    inc nimFwDbgTxSecHdrNoKeySlot
    nimFwDbgTxSecHdrMissMeta = desc.staInfoIdx.uint32 or
      (desc.vifIdx.uint32 shl 8)
    nimFwDbgTxSecHdrMissLen = desc.frameLen.uint32
    nimFwDbgTxSecHdrMissKeyMat = pointerAddrU32(keyMatPtr)
    return nil
  let vif = vifChannelForIdx(desc.vifIdx)
  if (vifKeyPointers(vif).flags and 0x02) != 0:
    if lmacGateHalfword(desc.frameLen) == sta.rateWord:
      return nil
  result = cast[ptr VifKeySlotView](keySlot)
  nimFwDbgTxSecHdrCipher = result.cipherType.uint32

proc txSecKeyUsable(key: ptr VifKeySlotView): bool {.inline.} =
  key != nil and key.installed != 0 and key.cipherType <= 3 and key.staIdx <= 3

proc txSecBumpPn(key: ptr VifKeySlotView, dst: pointer, bytes: csize_t): bool {.inline.} =
  # The fourth WEP counter byte is replaced by the key selector on the wire.
  # Reject exhaustion at the actual IV width, not the backing counter width.
  let currentPn = key.pnLow.uint64 or (key.pnHigh.uint64 shl 32)
  if (bytes == 4 and currentPn >= 0xFFFFFF'u64) or
      (bytes == 6 and currentPn >= 0xFFFFFFFFFFFF'u64):
    return false
  let oldLo = key.pnLow
  let carry = if oldLo == 0xFFFFFFFF'u32: 1'u32 else: 0'u32
  key.pnLow = oldLo + 1
  key.pnHigh = key.pnHigh + carry
  discard c_memcpy(dst, addr key.pnLow, bytes)
  true

proc writeTxCcmpHeader(secHdr: pointer; txDesc: ptr HostTxDescView;
                       txKey: ptr VifKeySlotView) {.inline.} =
  ## CCMP header byte layout is PN0, PN1, reserved-zero, key-id/ext-IV,
  ## PN2, PN3, PN4, PN5. Use the explicit overlay instead of packing
  ## the bytes through uint16 words; the latter puts the ext-IV bit in
  ## the wrong byte on little-endian targets.
  let ccmpHeader = cast[ptr CcmpSecurityHeaderView](secHdr)
  ccmpHeader.pn0 = txDesc.pnScratch[0]
  ccmpHeader.pn1 = txDesc.pnScratch[1]
  ccmpHeader.ccmpReservedZero = 0
  ccmpHeader.keyId = ((txKey.staIdx and 0x03'u8) shl 6) or 0x20'u8
  ccmpHeader.pn2 = txDesc.pnScratch[2]
  ccmpHeader.pn3 = txDesc.pnScratch[3]
  ccmpHeader.pn4 = txDesc.pnScratch[4]
  ccmpHeader.pn5 = txDesc.pnScratch[5]

proc writeTxTkipHeader(secHdr: pointer; txDesc: ptr HostTxDescView;
                       txKey: ptr VifKeySlotView) {.inline.} =
  let tkipHeader = cast[ptr TkipSecurityHeaderView](secHdr)
  tkipHeader.tsc1 = txDesc.pnScratch[1]
  tkipHeader.wepSeed = (tkipHeader.tsc1 or 0x20'u8) and 0x7F'u8
  tkipHeader.tsc0 = txDesc.pnScratch[0]
  tkipHeader.keyId = ((txKey.staIdx and 0x03'u8) shl 6) or 0x20'u8
  tkipHeader.tsc2 = txDesc.pnScratch[2]
  tkipHeader.tsc3 = txDesc.pnScratch[3]
  tkipHeader.tsc4 = txDesc.pnScratch[4]
  tkipHeader.tsc5 = txDesc.pnScratch[5]

proc txSecControlTemplate(desc: ptr HostTxDescView;
                          updateCurrentDesc: uint32): ptr HostTxRateTemplateView {.inline.} =
  if updateCurrentDesc != 0:
    if desc.policy == nil:
      return nil
    return hostTxRateTemplateAt(desc.policy)

  if desc.bufDesc == nil:
    return nil
  hostTxRateTemplate(hostTxLinkDescAt(desc.bufDesc))

proc patchTxSecControlWord(ctrl: ptr HostTxRateTemplateView;
                           key: ptr VifKeySlotView) {.inline.} =
  if ctrl == nil:
    return
  let patched = (ctrl.pendingCount and 0x000FFC00'u32) or key.keyIdx.uint32
  ctrl.pendingCount = patched
  nimFwDbgDhcpTxSecCtl = patched

proc txu_cntrl_sec_hdr_append*(txDesc: pointer, secHdr: pointer,
                               updateCurrentDesc: uint32): pointer {.exportc, cdecl.} =
  ## Prepend an IV immediately before secHdr and return its start, as in the
  ## vendor ABI. secHdr is the end of the reserved security-header space.
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  let hostTxDesc = hostTxDescAt(txDesc)
  if hostTxDesc == nil or secHdr == nil or
      hostTxDesc.staInfoIdx >= STA_INFO_TAB_ENTRIES.uint8 or
      hostTxDesc.vifIdx >= MAX_VIFS.uint8:
    return nil
  inc nimFwDbgTxSecHdrAppend
  if not txSecurityCurrent(hostTxDesc):
    return nil
  let txKey = txSecKeyFor(hostTxDesc)
  if txKey == nil:
    return secHdr
  if not txSecKeyUsable(txKey):
    return nil
  let headerLen =
    case txKey.cipherType
    of 0, 3: 4'u
    of 1, 2: 8'u
    else: 0'u
  let headerStart = cast[pointer](cast[uint](secHdr) - headerLen)
  let packetNumber = hostTxPnScratch(hostTxDesc)
  case txKey.cipherType
  of 0:  # WEP-40
    let securityHeader = cast[ptr TxSecurityHeaderView](headerStart)
    securityHeader.packetNumberLowWord = packetNumber.lo
    let keyIdByte = txKey.staIdx and 0x03'u8
    # The fourth byte is the key selector, not part of the 24-bit IV.
    securityHeader.keyIdAndPacketNumberMidWord =
      (keyIdByte.uint16 shl 14) or (packetNumber.mid and 0x00FF'u16)
  of 1:  # TKIP
    writeTxTkipHeader(headerStart, hostTxDesc, txKey)
  of 2:  # CCMP (AES)
    writeTxCcmpHeader(headerStart, hostTxDesc, txKey)
  of 3:  # WEP-104
    let securityHeader = cast[ptr TxSecurityHeaderView](headerStart)
    securityHeader.packetNumberLowWord = packetNumber.lo
    let keyIdByte = txKey.staIdx and 0x03'u8
    securityHeader.keyIdAndPacketNumberMidWord =
      (keyIdByte.uint16 shl 14) or (packetNumber.mid and 0x00FF'u16)
  else:
    discard
  let secWords = cast[ptr TxSecurityHeaderView](headerStart)
  nimFwDbgDhcpTxSecHdr0 =
    secWords.packetNumberLowWord.uint32 or
      (secWords.keyIdAndPacketNumberMidWord.uint32 shl 16)
  nimFwDbgDhcpTxSecHdr1 = 0
  if headerLen == 8:
    nimFwDbgDhcpTxSecHdr1 =
      secWords.tkipPacketNumberMidWord.uint32 or
        (secWords.tkipPacketNumberHighWord.uint32 shl 16)
  nimFwDbgDhcpTxSecKey =
    txKey.cipherType.uint32 or
    (txKey.staIdx.uint32 shl 8) or
    (txKey.keyIdx.uint32 shl 16) or
    (txKey.installed.uint32 shl 24)
  patchTxSecControlWord(txSecControlTemplate(hostTxDesc, updateCurrentDesc), txKey)
  return headerStart

proc txu_cntrl_sechdr_len_compute*(txDesc: pointer, lenOut: ptr uint32): uint32 {.exportc, cdecl.} =
  ## Compute security header length for a TX descriptor (76 instrs in blob).
  ## From blob (txu_cntrl.o): reads STA index from txDesc[49], resolves STA entry.
  ## Reads key slot pointer from sta+244. If no key, returns 0 with lenOut[]=0.
  ## Checks VIF security type. Based on cipher type at key_slot+152:
  ##   cipher 0 (WEP40): len=4; cipher 2 (CCMP): len=8
  ##   cipher 1 (TKIP): len=8, tail=12; cipher 3 (WEP104): len=4
  ## Increments 64-bit PN counter at key_slot+128. Returns header length.
  ## high(uint32) means an unusable key/counter/descriptor, not plaintext.
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  if lenOut != nil:
    lenOut[] = 0
  inc nimFwDbgTxSecHdrCalls
  let hostTxDesc = hostTxDescAt(txDesc)
  if hostTxDesc == nil or hostTxDesc.staInfoIdx >= STA_INFO_TAB_ENTRIES.uint8 or
      hostTxDesc.vifIdx >= MAX_VIFS.uint8:
    return high(uint32)
  let txKey = txSecKeyFor(hostTxDesc)
  if txKey == nil:
    if not txSecurityBind(hostTxDesc, nil, false):
      return high(uint32)
    return 0
  if not txSecKeyUsable(txKey):
    nimFwDbgTxSecHdrLen = 0
    return high(uint32)
  if not txSecurityBind(hostTxDesc, txKey, false):
    return high(uint32)
  var securityHeaderLen: uint32 = 0
  var securityTailLen: uint32 = 0
  var pnBytes: csize_t
  case txKey.cipherType
  of 0, 3:  # WEP-40/WEP-104
    securityHeaderLen = 4
    securityTailLen = 4
    pnBytes = 4
  of 1:  # TKIP
    securityHeaderLen = 8
    securityTailLen = 12
    pnBytes = 6
  of 2:  # CCMP
    securityHeaderLen = 8
    securityTailLen = 8
    pnBytes = 6
  else:
    nimFwDbgTxSecHdrLen = 0
    return 0
  if not txSecBumpPn(txKey, addr hostTxDesc.pnScratch[0], pnBytes):
    txSecurityForget(txDesc)
    nimFwDbgTxSecHdrLen = 0
    return high(uint32)
  if lenOut != nil:
    lenOut[] = securityTailLen
  nimFwDbgTxSecHdrLen = securityHeaderLen
  return securityHeaderLen

proc rxuMgtUpload(param: pointer; upload: uint8): uint32 =
  # The vendor's shared tail returns whether RX-upper took the descriptor.
  if upload == 0 or not rxStationCurrent(param):
    return 0
  let generation = rxUploadGeneration(param)
  let header = rxMpduHeader(param)
  if header == nil: return 0
  let mm = mmEnvView()
  let vif = vif_mgmt_get_vif(rxuCntrlEnvView().vifIdx)
  var enabled = false
  if vif == nil:
    enabled = (mm.rxPromiscUploadFlag or mm.apPromiscUploadFlag) != 0
  else:
    case vifChannelAt(vif).vifType
    of 0:
      if mm.rxPromiscUploadFlag != 0:
        enabled = true
    of 2:
      if mm.apPromiscUploadFlag != 0:
        enabled = true
    of 1, 3:  # IBSS and mesh use the vendor's unconditional upload path.
      enabled = true
    else:
      discard
  if enabled:
    rxu_mpdu_upload_and_indicate(param)
    if rxUploadCurrent(param, generation) and rxStationCurrent(param) and
        rxMpduHeader(param) == header and rxMpduDescView(param).curDesc != nil:
      return 1
  0

{.emit: "__attribute__((optimize(\"crossjumping\"))) unsigned long rxu_mgt_frame_check(void*, unsigned char);".}
proc rxuCheckBeaconParams(desc: pointer; vifIdx: uint8; length: uint16;
                         frame: pointer): bool =
  if length.int <= sizeof(RxPayloadBufferView):
    me_beacon_check(vifIdx, length, frame)
    return true
  let identity = rxCaptureFrame(desc)
  if identity.frame != frame or identity.length != length: return false
  var view = rxOpenBeaconView(identity)
  defer: rxCloseBeaconView(view)
  if view.data == nil or not rxFrameCurrent(identity): return false
  me_beacon_check(vifIdx, length, view.data)
  true

proc rxu_mgt_frame_check*(param: pointer, staIdxArg: uint8): uint32 {.exportc, cdecl.} =
  ## Check management frame validity and generate RXU_MGT_IND message.
  ## From blob (rxu_cntrl.o, 1350 bytes, 15 function calls).
  ##
  ## Blob register map:
  ##   s0=frameHdr  s1=vifIter/vifIdxByte  s2=bodyLen  s3=frameAccepted  s4=rxDesc
  ##   s5=staIdx(param a1)  s6=skipSecHdr  s7=rxu_cntrl_env  s8=machdrLen
  ##   s9=vifEntry  s10=msgSubtype  s11=ke_msg ptr
  ##
  ## Call graph (from relocations):
  ##   mfp_ignore_mgmt_frame, phyif_utils_decode, vif_mgmt_get_vif (x2),
  ##   apm_embedded_enabled (x2), ke_msg_alloc, ke_msg_send,
  ##   ke_state_get (x2), me_beacon_check, phy_get_channel,
  ##   rxu_mpdu_upload_and_indicate, assert_warn, vif_mgmt_get_first_ap_inf
  ##
  ## Returns: 1 = RX descriptor transferred to upload, 0 = caller may recycle.
  let staIdx = staIdxArg
  if not rxStationCurrent(param):
    return 0

  let generation = rxUploadGeneration(param)
  let rx = rxMpduHeader(param)
  if rx == nil: return 0

  # Stack-local outputs for mfp_ignore_mgmt_frame
  var mfpAcceptedFlag: uint8 = 1      # sp+22 in blob: accepted flag
  var mfpSecondaryFlags: uint8 = 0    # sp+23 in blob: secondary/RSSI flags
  var phyDecodeStatusByte: uint8 = 0  # sp+21 in blob: phyif_utils result

  # Traverse: rxDesc[8] -> bufDesc -> bufDesc[24] -> frameHdr (s0)
  let bufDesc = rx.bufferChain
  if bufDesc == nil: return 0
  let frame = rxFrameAtRef(bufDesc)
  let bodyLen = rx.mpduLengthBytes
  if frame == nil or bodyLen < 24: return 0
  let frameHdr = cast[pointer](frame)
  template currentFrame(): bool =
    rxUploadCurrent(param, generation) and rxStationCurrent(param) and
      rxMpduHeader(param) == rx and rx.bufferChain == bufDesc and
      rx.mpduLengthBytes == bodyLen and rxFrameAtRef(bufDesc) == frame

  let fcFull = frame.frameControl
  let subtypeBits = fcFull and 0x00FC'u16
  when defined(bl808WifiApDiscoveryDiag):
    if subtypeBits == 0x40'u16:
      # RXU has admitted the first DMA segment. Never walk into the next one.
      const macLength = sizeof(MacDataFrameHeaderView).uint32
      let firstSegmentLength = min(bodyLen.uint32, 1736'u32)
      let kind = apProbeClassifyForAp(rxFrameCursor(frameHdr, macLength.uint),
                                      firstSegmentLength - macLength)
      inc apProbeTrace[kind].rxUpper
  if not rxMgmtBodyValid(fcFull, frameHdr, rxuCntrlEnvView().machdrLen.uint16,
      bodyLen):
    return 0
  inc nimFwDbgMgtSeen
  nimFwDbgMgtLastFc = fcFull.uint32 or (rx.hwFlags and 0xFFFF0000'u32)
  let subtypeIndex = ((fcFull shr 4) and 0x0F'u16).int
  if subtypeIndex >= 0 and subtypeIndex < nimFwDbgMgtSubtypeCounts.len:
    inc nimFwDbgMgtSubtypeCounts[subtypeIndex]
  if (fcFull and 0x00FC'u16) == 0x00B0'u16:
    nimFwDbgMgtAuthLastFc = fcFull.uint32 or (rx.hwFlags and 0xFFFF0000'u32)
  elif (fcFull and 0x00FC'u16) == 0x0010'u16 or
      (fcFull and 0x00FC'u16) == 0x0030'u16:
    inc nimFwDbgMgtAssocRspSeen
    nimFwDbgMgtAssocLastFc = fcFull.uint32 or (rx.hwFlags and 0xFFFF0000'u32)

  # Management fragmentation is not supported (More Fragments or nonzero frag).
  if (fcFull and 0x0400'u16) != 0:
    inc nimFwDbgMgtRejected
    nimFwDbgMgtDropReason = 1'u32 or (fcFull.uint32 shl 8)
    return 0

  # Reject if fragment number non-zero (byte 22, low nibble)
  if (frame.seqCtrl and 0x000F'u16) != 0:
    inc nimFwDbgMgtRejected
    nimFwDbgMgtDropReason = 2'u32 or (fcFull.uint32 shl 8) or
      (frame.seqCtrl.uint32 shl 24)
    return 0

  let env = rxuCntrlEnvView()
  # Only unbound frames resolve a VIF here. Associated RX already supplied it;
  # the station argument is a separate index, retained at indication offset 7.
  if staIdx == 0xFF:
    var vifIdx = 0xFF'u8
    let rxFlags = rx.hwFlags
    if (rxFlags and 0x600'u32) == 0:
      # Blob path .L55/.L64: resolve the VIF by matching Addr1 against
      # vif.mac_addr (vif+80). Association/authentication requests addressed
      # to an AP have Addr1 == BSSID. Retry and other flags do not change type.
      var vifEntry = cast[pointer](vifMgmtEnvView().activeList.first)
      var foundVifIdx: uint8 = 0xFF
      let directedProbe = (fcFull and 0x00FC'u16) == 0x0040'u16 and
        (frame.addr1[0] and 1) == 0
      var requestToApVif = directedProbe
      if (fcFull and 0x00FC'u16) in [0x0000'u16, 0x0020'u16, 0x00B0'u16]:
        requestToApVif = true
        for authBssidByteIndex in 0'u ..< 6:
          if frame.addr1[authBssidByteIndex] != frame.addr3[authBssidByteIndex]:
            requestToApVif = false
            break
      while vifEntry != nil:
        let vif = vifChannelAt(vifEntry)
        var macMatch = true
        for vifMacByteIndex in 0'u ..< 6:
          if vif.macAddr[vifMacByteIndex] != frame.addr1[vifMacByteIndex]:
            macMatch = false
            break
        if macMatch:
          let vifType = vif.vifType
          if (vifType == 0 and not requestToApVif) or (vifType == 2 and requestToApVif):
            foundVifIdx = vif.vifIdx
            break
        vifEntry = vif.next
      if directedProbe and foundVifIdx == 0xFF:
        return 0
      vifIdx = foundVifIdx

    env.vifIdx = vifIdx

  # The station-to-VIF fallback must precede MFP, which selects the IGTK
  # through env.vifIdx and can otherwise reject a valid protected frame.
  if env.vifIdx == 0xFF and staIdx < STA_INFO_TAB_ENTRIES.uint8:
    env.vifIdx = staInfoForIdx(staIdx).instNbr
  if not rxBindVif(param, env.vifIdx):
    return 0
  # Reject an unowned peer before MFP or the duplicate-sequence commit.
  if subtypeBits in [0xB0'u16, 0x10'u16, 0x30'u16, 0x80'u16,
      0xA0'u16, 0xC0'u16, 0xD0'u16] and
      (subtypeBits != 0x80'u16 or staIdx < STA_INFO_TAB_ENTRIES.uint8):
    var peerVifIdx = env.vifIdx
    if peerVifIdx == 0xFF and staIdx < STA_INFO_TAB_ENTRIES.uint8:
      peerVifIdx = staInfoForIdx(staIdx).instNbr
    let peerVifEntry =
      if peerVifIdx < MAX_VIFS.uint8: vif_mgmt_get_vif(peerVifIdx)
      else: nil
    if peerVifEntry != nil:
      let peerVif = vifChannelAt(peerVifEntry)
      if peerVif.vifType == 0:
        if subtypeBits == 0x80'u16 and
            frame.addr1 != [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]:
          return 0
        var peer = peerVif.bssid
        if peer == [0'u8, 0, 0, 0, 0, 0] or
            peer == [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]:
          peer = peerVif.currentBssid
        if (peer[0] and 1'u8) != 0 or peer == [0'u8, 0, 0, 0, 0, 0]:
          return 0
        let directed = (frame.addr1[0] and 1'u8) == 0 or
          subtypeBits in [0xB0'u16, 0x10'u16, 0x30'u16, 0xD0'u16]
        for macByteIndex in 0 ..< 6:
          if (directed and frame.addr1[macByteIndex] !=
              peerVif.macAddr[macByteIndex]) or
              frame.addr2[macByteIndex] != peer[macByteIndex] or
              frame.addr3[macByteIndex] != peer[macByteIndex]:
            return 0
      elif peerVif.vifType == 2 and subtypeBits in
          [0xA0'u16, 0xC0'u16, 0xD0'u16]:
        if staIdx >= STA_INFO_TAB_ENTRIES.uint8:
          return 0
        let peerSta = staInfoForIdx(staIdx)
        if peerSta.valid == 0 or peerSta.instNbr != peerVifIdx or
            frame.addr1 != peerVif.macAddr or
            frame.addr2 != peerSta.macAddr or
            frame.addr3 != peerVif.macAddr:
          return 0
  let envPtr = cast[pointer](env)
  let envSeq = env.seqCtrl
  when defined(bl808WifiDiagPeerRxAdmission):
    var verifiedBip = false
    let ignored = mfpIgnoreRxMgmtFrame(param, envPtr, frameHdr, bodyLen,
      addr mfpAcceptedFlag, addr mfpSecondaryFlags, generation, addr verifiedBip)
  else:
    let ignored = mfpIgnoreRxMgmtFrame(param, envPtr, frameHdr, bodyLen,
      addr mfpAcceptedFlag, addr mfpSecondaryFlags, generation)
  if not currentFrame(): return 0
  if ignored:
    return rxuMgtUpload(param, mfpAcceptedFlag)
  when defined(bl808WifiDiagPeerRxAdmission):
    if subtypeBits in [0xA0'u16, 0xC0'u16]:
      if verifiedBip:
        rxMgtNoteProtection(param, generation, rxMgtVerifiedBip)
      elif (fcFull and 0x4000'u16) == 0:
        rxMgtNoteProtection(param, generation, rxMgtWithoutProtection)
  var frameAccepted: uint8 = mfpAcceptedFlag

  # --- Call phyif_utils_decode (blob 0x96-0xa2) ---
  # a0 = rxDesc+40 (RX vector), a1 = &phyDecodeStatusByte (sp+21 in blob)
  var rssiResult: int8 = 0
  discard phyif_utils_decode(cast[pointer](addr rx.phyVector[0]), addr rssiResult)
  if not currentFrame():
    return 0
  phyDecodeStatusByte = cast[uint8](rssiResult)

  # --- Read rxu_cntrl_env fields ---
  let machdrLen = env.machdrLen

  # --- VIF lookup via vif_mgmt_get_vif (blob 0xde) ---
  var vifEntry: pointer = nil  # s9
  if env.vifIdx != 0xFF:
    vifEntry = vif_mgmt_get_vif(env.vifIdx)
  let rxuEnvVifIdx = env.vifIdx
  if not rxBindVif(param, rxuEnvVifIdx):
    return 0

  # --- Subtype dispatch (blob 0xec-0x452) ---
  var msgSubtype: uint8 = 0xFF  # s10: message subtype for ke_msg_alloc
  var skipSecHdr: bool = true   # s6: true = don't adjust for sec header in copy
  var uploadAfterCopy = true

  if frameAccepted != 0:
    case subtypeBits.int
    of 0x80:  # Beacon (blob .L70 at 0x3be)
      let state = ke_state_get(TASK_SCAN)
      if state == ScanChannelRunningState:
        skipSecHdr = true
        msgSubtype = 2
      else:
        # Not active (blob .L103 at 0x3fc): set defaults, fall through to shared .L81
        skipSecHdr = false
        msgSubtype = 0xFF
      # Shared beacon path (blob .L81 at 0x3d2)
      if staIdx != 0xFF:
        if vifEntry != nil:
          let vif = vifChannelAt(vifEntry)
          if vif.vifType == 0 and vif.state != 0:
            # Call me_beacon_check (blob 0x3e8)
            if not rxuCheckBeaconParams(param, rxuEnvVifIdx, bodyLen, frameHdr):
              return 0
            if not currentFrame(): return 0
      else:
        # Unbound station path (blob .L82 at 0x404)
        # Blob calls ke_state_get(TASK_SCAN) a second time and apm_embedded_enabled
        let state2 = ke_state_get(TASK_SCAN)
        if state2 != ScanChannelRunningState:
          discard apm_embedded_enabled(vifEntry)
      # blob .L84 at 0x3f0: reject if msgSubtype was never set
      if msgSubtype == 0xFF:
        frameAccepted = 0

    of 0x10:  # Assoc Resp (blob .L72 at 0x3b6)
      if vifEntry == nil or cast[uint](vifEntry) == 0:
        frameAccepted = 0
      else:
        let vifType = vifChannelAt(vifEntry).vifType
        if vifType != 0:
          frameAccepted = 0
        else:
          skipSecHdr = false
          msgSubtype = 4

    of 0x30:  # Reassoc Resp (blob also .L72)
      if vifEntry == nil or cast[uint](vifEntry) == 0:
        frameAccepted = 0
      else:
        let vifType = vifChannelAt(vifEntry).vifType
        if vifType != 0:
          frameAccepted = 0
        else:
          skipSecHdr = false
          msgSubtype = 4

    of 0x00, 0x20, 0x40:  # Assoc/Reassoc/Probe Req -> AP management (.L85)
      # Probe requests may use a wildcard BSSID; nil selects the embedded AP.
      # Association requests still need a resolved target AP VIF.
      if subtypeBits == 0x40'u16 or vifEntry != nil:
        if apm_embedded_enabled(vifEntry):
          skipSecHdr = true
          msgSubtype = 5
          uploadAfterCopy = false
        else:
          frameAccepted = 0
      else:
        frameAccepted = 0

    of 0x50:  # Probe Resp (blob .L73 at 0x28e)
      skipSecHdr = true
      msgSubtype = 2

    of 0xA0, 0xB0, 0xC0:  # Disassoc/Auth/Deauth
      # Blob special-cases STA auth responses: the RXU_MGT_IND payload starts at
      # the auth body because sm_auth_handler reads auth fields at msg+32.
      # STA disassoc/deauth keep the full management header.
      if vifEntry != nil:
        let vifType = vifChannelAt(vifEntry).vifType
        if vifType != 0:
          # Non-zero vifType: call apm_embedded_enabled (blob .L85 at 0x2b4)
          let apmEnabled = apm_embedded_enabled(vifEntry)
          if apmEnabled:
            skipSecHdr = true
            msgSubtype = 5
            uploadAfterCopy = false
          else:
            frameAccepted = 0
        else:
          if subtypeBits == 0xB0:
            skipSecHdr = false
          else:
            # vifType == 0: debug log (blob 0x444, line 1399), then accept as mgmt
            let subtypeLogFn = getLogFunc(204)
            if subtypeLogFn != nil:
              subtypeLogFn(2, nil, "rxu_cntrl.c", 1399,
                "[FW] got unexpected DISASSOC/DEAUTHENT\r\n")
            skipSecHdr = true
          msgSubtype = 4
      else:
        # No VIF (blob: a4=4 from .L100, takes .L85 apm_embedded path)
        let apmEnabled = apm_embedded_enabled(vifEntry)
        if apmEnabled:
          skipSecHdr = true
          msgSubtype = 5
          uploadAfterCopy = false
        else:
          frameAccepted = 0

    of 0xD0:  # Action frame (blob .L78 at 0x366)
      if staIdx == 0xFF:
        frameAccepted = 0
      else:
        # Read action category using machdrLen offset (blob: th.lrbu a3,s0,s8,0)
        let catByte = rxFrameBodyByte(frame, machdrLen)
        if catByte == 3:  # Block Ack (BA)
          msgSubtype = 6
          skipSecHdr = false
          uploadAfterCopy = false
        elif catByte == 8:  # SA Query
          # Blob validates: rxu_cntrl_env[10] must not be 0xFF
          if rxuEnvVifIdx == 0xFF:
            frameAccepted = 0
          else:
            # Check body length: bodyLen - machdrLen > 3
            if (bodyLen.int - machdrLen.int) > 3:
              # Check vif_info_tab[vifIdx][86] (VIF type) for SA Query acceptance
              let saQueryVif = vif_mgmt_get_vif(rxuEnvVifIdx)
              if saQueryVif == nil or vifChannelAt(saQueryVif).vifType != 0:
                frameAccepted = 0
              else:
                # Look up STA via sta_info_tab using vif_info_tab approach
                skipSecHdr = false
                uploadAfterCopy = false
                msgSubtype = 4
            else:
              frameAccepted = 0
        else:
          frameAccepted = 0
    of 0xEC:  # (blob .L85 at 0x2b4 — subtypes with FC & 0xDC == 0xEC)
      # Disjoint action subtypes: check inline
      frameAccepted = 0
    else:
      # Check for subtypes with bits 0xDC/0xEC pattern (blob .L85 check)
      if (subtypeBits.int and 0xDC) == 0:
        # Type 0x00 with subtype field zero
        skipSecHdr = false
        msgSubtype = 2
      else:
        frameAccepted = 0

  # --- Message allocation and population (blob 0x2c8-0x518) ---
  let dbgState = ke_state_get(TASK_SCAN).uint32
  let dbgMgt0 = (frameAccepted.uint32 shl 24) or
    (msgSubtype.uint32 shl 16) or (staIdx.uint32 shl 8) or rxuEnvVifIdx.uint32
  let dbgMgt1 = (dbgState shl 24) or
    (bodyLen.uint32 shl 8) or machdrLen.uint32
  nimFwDbgMgtLast0 = dbgMgt0
  nimFwDbgMgtLast1 = dbgMgt1
  if frameAccepted != 0 and msgSubtype != 0xFF:
    inc nimFwDbgMgtAccepted
  else:
    inc nimFwDbgMgtRejected
    nimFwDbgMgtDropReason = 3'u32 or (subtypeBits.uint32 shl 8) or
      (msgSubtype.uint32 shl 16) or (frameAccepted.uint32 shl 24)
  if subtypeBits == 0xB0'u16:
    inc nimFwDbgAuthMgtSeen
    nimFwDbgAuthMgtLast0 = dbgMgt0
    nimFwDbgAuthMgtLast1 = dbgMgt1
    if frameAccepted != 0 and msgSubtype != 0xFF:
      inc nimFwDbgAuthMgtAccepted
    else:
      inc nimFwDbgAuthMgtRejected
  nimFwTrace2U32("[WIFI-NIMFW] mgt_pre ", dbgMgt0, dbgMgt1)
  when defined(bl808WifiConnectTrace):
    if subtypeBits == 0xB0'u16 or subtypeBits == 0x10'u16 or subtypeBits == 0x30'u16:
      nimFwConnectTrace2U32("[WIFI-CT] mgt_pre ", dbgMgt0, dbgMgt1)
  if not currentFrame(): return 0
  if frameAccepted == 0 or msgSubtype == 0xFF:
    # Set frameAccepted to result byte for return
    frameAccepted = mfpAcceptedFlag
    # Fall through to epilogue
  else:
    # A queued frame may outlive a radio channel change.
    var chanInfo {.noinit.}: array[2, uint32]
    if not rxReadCapturedChannel(param, chanInfo):
      phy_get_channel_raw(cast[pointer](addr chanInfo[0]), 0)
    if not currentFrame(): return 0

    # Allocate ke_msg: ke_msg_alloc(RXU_MGT_IND, msgSubtype, TASK_RXU, bodyLen+32)
    # Floored at the RxuMgtIndView fixed-header extent (beaconPeriod/capInfo
    # end at offset 68): consumers read AND zero-write those fixed fields on
    # every mgt ind, and short auth/deauth/action frames (~30 byte bodies)
    # otherwise allocate less than the fixed header — the field writes then
    # land past the block (TLSF canary forensics: 65-byte 0x1C00 msgs, canary
    # bytes zeroed up to exactly offset 68, during every connect).
    const RxuMgtIndFixedHeaderLen = 68'u32
    let msgSize = max(bodyLen.uint32 + 32, RxuMgtIndFixedHeaderLen)
    # Keep the captured session outside the vendor-visible payload.
    let msg = rxMgtAllocMessage(param, msgSubtype, msgSize)
    if msg == nil:
      # Debug log: ke_msg_alloc failure (blob 0x308, line 1482)
      let allocLogFn = getLogFunc(204)
      if allocLogFn != nil:
        allocLogFn(2, nil, "rxu_cntrl.c", 1482, "rxu msg alloc failure\r\n")
      frameAccepted = 0
      mfpAcceptedFlag = 0
    else:
      var ownedMsg = msg
      defer:
        if ownedMsg != nil:
          ke_msg_free_payload(ownedMsg)
      if not currentFrame(): return 0
      let ind = rxuMgtIndMsgAt(msg)

      # --- Adjust source pointer for security header (blob 0x460-0x48e) ---
      var copySrc = frameHdr
      var copyLen = bodyLen
      var copyOffset = 0'u32
      var copyPrefix = 0'u32
      let macHeaderLen = rxMacHeaderLen(fcFull)
      if macHeaderLen == 0 or machdrLen < macHeaderLen or
          machdrLen.uint16 > bodyLen:
        return 0
      if not skipSecHdr:
        # Check machdrLen parity: blob calls assert_warn if odd
        if (machdrLen and 1) != 0:
          assert_warn("rxl_cntrl.c", "rxl_cntrl.c", 1491)
          if not currentFrame(): return 0
        # Adjust: subtract machdrLen from bodyLen, advance frameHdr past MAC header
        copyLen = copyLen - machdrLen.uint16
        copyOffset = machdrLen.uint32
      elif machdrLen > macHeaderLen:
        # Whole-frame consumers need the MAC header followed by plaintext,
        # not the retained IV between that header and the management body.
        copyPrefix = macHeaderLen.uint32
        copyOffset = machdrLen.uint32
        copyLen -= (machdrLen - macHeaderLen).uint16
      copySrc = rxFrameCursor(copySrc, copyOffset.uint)

      # --- Populate message fields (blob 0x4a2-0x4fa) ---
      # msg[0..1] = copied frame/body length (blob stores s2 after the optional
      # MAC-header adjustment via th.shia before copying to msg+32).
      ind.frameLen = copyLen
      ind.frameCtrl = fcFull
      ind.staIdx = staIdx
      ind.rxuVifIdx = rxuEnvVifIdx
      ind.freq = (chanInfo[0] shr 16).uint16
      ind.band = (chanInfo[0] and 0xFF).uint8
      ind.rssi = rssiResult
      ind.noiseFloor = rssiResult
      ind.phyVector11 = rx.phyVector[11]
      ind.secondary = mfpSecondaryFlags

      if (subtypeBits == 0x10'u16 or subtypeBits == 0x30'u16) and
          copyLen >= 4:
        nimFwTrace2U32("[WIFI-NIMFW] assoc_copy ",
                       copyLen.uint32,
                       rxFrameWords(copySrc)[0])
        if copyLen >= 12:
          nimFwTrace2U32("[WIFI-NIMFW] assoc_copy2 ",
                         rxFrameWords(copySrc)[1],
                         rxFrameWords(copySrc)[2])
        if not currentFrame(): return 0

      # The vendor populates these AP indication fields for Assoc Req only.
      if msgSubtype == 5 and subtypeBits == 0:
        ind.timestampLow = rx.timestampLow
        ind.timestampHigh = rx.timestampHigh
        ind.phyVector0 = rx.phyVector[0]

      # DMA segments are not contiguous; publish only a complete copy.
      if copyPrefix != 0 and
          not rxuCopyFrameBytes(rx, 0, copyPrefix, addr ind.body[0]):
        return 0
      if not rxuCopyFrameBytes(rx, copyOffset, copyLen.uint32 - copyPrefix,
          rxFrameCursor(addr ind.body[0], copyPrefix.uint)):
        return 0
      if not currentFrame(): return 0

      # Commit only a complete indication, immediately before enqueue so a
      # retry cannot race a queued frame whose sequence is still unrecorded.
      block:
        let savedIrq = irqSave()
        defer: irqRestore(savedIrq)
        if not currentFrame(): return 0
        if staIdx < STA_INFO_TAB_ENTRIES.uint8:
          staRxSequence(staInfoForIdx(staIdx)).nonQosSeqCtrl = envSeq
      # Send message via ke_msg_send (blob 0x504)
      ownedMsg = nil
      ke_msg_send(msg)
      if not currentFrame(): return 0
      inc nimFwDbgMgtMsgSent
      if subtypeBits == 0xB0'u16:
        inc nimFwDbgAuthMgtMsgSent
      mfpAcceptedFlag = uploadAfterCopy.uint8

  if not currentFrame(): return 0
  return rxuMgtUpload(param, mfpAcceptedFlag)

proc rxu_mgt_ind_handler_scanu(param: pointer): cint {.exportc: "rxu_mgt_ind_handler_scanu", cdecl.} =
  ## Handle management frame indication for SCANU task (10 bytes in blob, scanu_task.o).
  ## Tail-calls scanu_frame_handler with the message body.
  if param == nil:
    return KeMsgConsumed
  let payloadLength = keMsgHdrFromPayload(param).paramLen
  if not scanuRxFrameValid(param, payloadLength):
    return KeMsgConsumed
  scanu_frame_handler(param, payloadLength)
  # scanu_frame_handler ALWAYS re-queues the frame via
  # ke_msg_forward_and_change_id -> ke_msg_send (as SCANU_RESULT_IND 0x804), so
  # the frame is now owned by that forwarded dispatch. Return KeMsgNoFree so the
  # message dispatcher does NOT also free it. Previously this proc returned void
  # -> the dispatcher read a garbage return, normalized it to KeMsgConsumed, and
  # freed the already-re-queued frame: a double-free (JTAG/TLSF-confirmed:
  # df_msg = 0x02090804 = SCANU_RESULT_IND) that later surfaced as a
  # use-after-free fault in an unrelated HTTP Table destroy.
  return KeMsgNoFree

proc rxu_mgt_ind_handler_sm(param: pointer): cint {.exportc: "rxu_mgt_ind_handler_sm", cdecl, discardable.} =
  ## Handle management frame indication for SM task (256 bytes in blob, sm_task.o).
  ## Dispatches on 802.11 frame subtype to appropriate SM handler.
  ## Checks ke_state_get(TASK_SM) before calling certain handlers.
  if param == nil:
    return KeMsgConsumed
  if keMsgHdrFromPayload(param).paramLen < 9:
    return KeMsgConsumed
  let msg = rxuMgtDispatchView(param)
  # Frame control at msg body offset 2-3 (LE uint16); mask with 0xFC to get type+subtype
  let frameType = msg.frameCtrl and 0xFC'u16
  let minimumFrameLength =
    case frameType
    of 0xB0'u16, 0x10'u16, 0x30'u16: 6'u32
    of 0xC0'u16, 0xA0'u16: rxMacHeaderLen(msg.frameCtrl).uint32 + 2
    of 0xD0'u16: 4'u32
    else: 0'u32
  if minimumFrameLength != 0 and not smRxFrameFits(param, minimumFrameLength):
    return KeMsgConsumed
  case frameType
  of 0xB0: # Authentication
    inc nimFwDbgAuthSmDispatch
    nimFwDbgAuthSmState = ke_state_get(TASK_SM).uint32
    if nimFwDbgAuthSmState != SmAuthenticatingState: return KeMsgConsumed
    sm_auth_handler(param)
  of 0x10: # Association Response
    when defined(bl808WifiConnectTrace):
      let staVifPair = msg.staIdx.uint32 or (msg.vifIdx.uint32 shl 8)
      nimFwConnectTrace2U32("[WIFI-CT] sm_mgt_assoc ",
                            ke_state_get(TASK_SM).uint32,
                            staVifPair)
    if ke_state_get(TASK_SM) != SmAssocRspState: return KeMsgConsumed
    sm_assoc_rsp_handler(param)
  of 0x30: # Reassociation Response
    when defined(bl808WifiConnectTrace):
      let staVifPair = msg.staIdx.uint32 or (msg.vifIdx.uint32 shl 8)
      nimFwConnectTrace2U32("[WIFI-CT] sm_mgt_reassoc ",
                            ke_state_get(TASK_SM).uint32,
                            staVifPair)
    if ke_state_get(TASK_SM) != SmAssocRspState: return KeMsgConsumed
    sm_assoc_rsp_handler(param)
  of 0xC0, 0xA0: # Deauthentication or disassociation
    let state = ke_state_get(TASK_SM)
    if state == SmIdleState or state == SM_ACTIVATING_STATE:
      return sm_deauth_handler(param)
    # The restart path bypasses the disconnect handler's RX admission.
    if state == SmAuthenticatingState and rxMgtMessageCurrent(keMsgHdrFromPayload(param)):
      sm_auth_start()
  of 0xD0: # Action
    # Only handle SA Query (category == 8)
    if msg.category == 8'u8:
      sm_sa_query_handler(param)
  else:
    discard
  return KeMsgConsumed

proc rxu_mgt_ind_handler_apm(param: pointer): cint {.exportc: "rxu_mgt_ind_handler_apm", cdecl, discardable.} =
  ## Handle management frame indication for APM task (134 bytes in blob, apm_task.o).
  ## Dispatches on 802.11 frame subtype to appropriate AP-mode handler.
  if param == nil:
    return KeMsgConsumed
  if keMsgHdrFromPayload(param).paramLen < 9:
    return KeMsgConsumed
  let msg = rxuMgtDispatchView(param)
  # Frame control at msg body offset 2-3 (LE uint16); mask with 0xFC to get type+subtype
  let frameType = msg.frameCtrl and 0xFC'u16
  # Probe requests may use the wildcard VIF; their handler resolves it first.
  if frameType != 0x40 and not apmVifRunning(msg.vifIdx):
    return KeMsgConsumed
  case frameType
  of 0x40: # Probe Request
    apm_probe_req_handler(param)
  of 0xB0: # Authentication
    apm_auth_handler(param)
  of 0x00, 0x20: # Association Request (0x00) / Reassociation Request (0x20)
    # Blob uses a single apm_assoc_req_handler call site with reassoc flag
    # derived from the subtype.
    let reassocFlag: uint32 = if frameType == 0x20: 1 else: 0
    apm_assoc_req_handler(param, reassocFlag)
  of 0xC0: # Deauthentication
    apm_deauth_handler(param)
  of 0xA0: # Disassociation
    apm_disassoc_handler(param)
  of 0x80: # Beacon
    apm_beacon_handler(param)
  else:
    discard
  0

proc rxu_mgt_ind_handler_bam*(param: pointer): cint
    {.exportc: "rxu_mgt_ind_handler_bam", cdecl.} =
  ## Negotiate the vendor's immediate-BA receive window: at most 12 MPDUs,
  ## the requested TID, no A-MSDU, and no inactivity timeout.
  if param == nil:
    return 0
  let saved = irqSave()
  var irqHeld = true
  defer:
    if irqHeld: irqRestore(saved)
  const bodyOffset = offsetof(RxuMgtIndMsgView, body).uint32
  let payloadLength = keMsgHdrFromPayload(param).paramLen
  if payloadLength < bodyOffset + sizeof(AddBaReqActionBodyView).uint32:
    return 0
  let bodyLength = rxuMgtIndMsgAt(param).frameLen.uint32
  if bodyLength < sizeof(AddBaReqActionBodyView).uint32 or
      bodyLength > payloadLength - bodyOffset:
    return 0
  let msg = rxuMgtDispatchView(param)
  # This vendor has no originator agreement state machine or DELBA handling.
  if (msg.frameCtrl and 0xFC'u16) != 0xD0'u16 or
      msg.category != 3 or msg.actionCode != 0 or msg.dialogToken == 0:
    return 0
  let staIdx = msg.staIdx
  if staIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return 0
  let sta = staInfoForIdx(staIdx)
  if sta.valid == 0 or sta.instNbr >= MAX_VIFS.uint8 or
      sta.instNbr != msg.vifIdx:
    return 0
  let vifIdx = sta.instNbr
  let vifEpoch = rxVifEpochs[vifIdx]
  let stationEpoch = staDeleteEpoch(staIdx)
  let resetEpoch = txResetEpoch
  template requireResponseOwner() =
    if txlResetting() or txlVifIsRetiring(vifIdx) or
        txResetEpoch != resetEpoch or rxVifEpochs[vifIdx] != vifEpoch or
        staDeleteEpoch(staIdx) != stationEpoch or
        sta.valid == 0 or sta.instNbr != vifIdx:
      return 0
  requireResponseOwner()
  let baParam = msg.baParam
  let amsduOK = (baParam and 1'u16) != 0
  let baPolicy = (baParam and 2'u16) != 0
  let tid = ((baParam shr 2) and 0x0F'u16).uint32
  let responseStatus =
    if tid < 8 and baPolicy: 0'u16
    else: 37'u16 # No TSPEC state or delayed-BA responder.
  let bufferSize = (baParam shr 6) and 0x3FF'u16
  # Zero is an unspecified request, not a valid successful response window.
  let acceptedWindow = if bufferSize == 0: 12'u16 else: min(bufferSize, 12'u16)
  let responseParams = (baParam and 0x003E'u16) or 2'u16 or
                       (acceptedWindow shl 6)
  let dialogToken = msg.dialogToken
  # Snapshot the body before diagnostics can retire its station or message.
  let body = addBaReqActionBodyAt(addr rxuMgtIndMsgAt(param).body[0])
  let startingSequence = body.startSeq.uint32 shr 4
  let timeout = body.timeout.uint32
  const
    reqFmt: cstring =
      "-----------------> AABA Request:\r\n    A-MSDU: %s\r\n    Block Ack Policy: %s\r\n    TID: %u\r\n    Number of Buffers: %u\r\n"
    rspFmt: cstring =
      "-----------------> AABA Response:\r\n    A-MSDU: %s\r\n    Block Ack Policy: %s\r\n    TID: %u\r\n    Number of Buffers: %u\r\n    ssn: %u\r\n    timeout: %u\r\n    tid %u\r\n"
    permitted: cstring = "Permitted"
    notPermitted: cstring = "Not Permitted"
    immediate: cstring = "Immediate Block Ack"
    delayed: cstring = "Delayed Block Ack"
  type PrintFn = proc(format: cstring) {.cdecl, varargs, raises: [Exception].}
  let requestPrint = cast[PrintFn](blOpsFunc(4))
  if requestPrint != nil:
    let amsduStr = if amsduOK: permitted else: notPermitted
    let policyStr = if baPolicy: immediate else: delayed
    irqHeld = false
    irqRestore(saved)
    requestPrint(reqFmt, amsduStr, policyStr, tid.cuint, bufferSize.cuint)
    discard irqSave()
    irqHeld = true
    requireResponseOwner()
  let responsePrint = cast[PrintFn](blOpsFunc(4))
  if responsePrint != nil:
    irqHeld = false
    irqRestore(saved)
    # The vendor's diagnostic labels swap these two protocol fields.
    responsePrint(rspFmt, notPermitted, immediate, tid.cuint,
                  acceptedWindow.cuint, startingSequence.cuint, timeout.cuint,
                  tid.cuint)
    discard irqSave()
    irqHeld = true
    requireResponseOwner()
  # Only an accepted EDCA agreement enables the hardware BAM ACK bit.
  if responseStatus == 0:
    regWrite(MACHW_DOZE_CNTRL2_REG, regRead(MACHW_DOZE_CNTRL2_REG) or 0x80'u32)
  bam_send_air_action_frame(staIdx, nil, 1'u8, dialogToken,
                           responseParams, responseStatus, nil)
  return 0
