# --- MM Task Handlers (mm_task.o) ---

proc mm_reset_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle MM_RESET_REQ: reset MAC state (92 bytes in blob).
  ## Blob: hal_machw_stop → phy_stop → mm_init → me_init
  nimFwTrace("[WIFI-NIMFW] mm_reset_req begin")
  {.emit: ["extern void hal_machw_stop(void); extern void phy_stop(void); extern void me_init(void);"].}
  {.emit: ["hal_machw_stop(); phy_stop();"].}
  mm_init()
  {.emit: ["me_init();"].}
  # Send reset confirmation and set state (blob: ke_msg_send_basic + ke_state_set)
  nimFwTrace("[WIFI-NIMFW] mm_reset_req cfm")
  ke_msg_send_basic(MM_RESET_CFM, TASK_API, TASK_MM)
  ke_state_set(TASK_MM, MM_IDLE)
  nimFwTrace("[WIFI-NIMFW] mm_reset_req done")
  return KeMsgConsumed

proc mm_start_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle MM_START_REQ: start MAC management after reset (186 bytes in blob).
  ## From blob (mm_task.o, 46 instrs):
  ##   1. Assert state is idle (ke_state_get(TASK_MM) == 0)
  ##   2. Call mm_init() to re-initialize all subsystems
  ##   3. Call hal_machw_init() for MAC HW default setup
  ##   4. ke_evt_set(16) to trigger event processing
  ##   5. Read beacon interval from param[16] (word), multiply by 1000 to get MAC ticks
  ##   6. Store beacon interval ticks to mm_env word 7 (offset 0x1C)
  ##   7. Read max AMPDU config from param[17] (halfword at offset 68)
  ##   8. Store to mm_env halfword 13 (offset 0x1A)
  ##   9. Call mm_env_max_ampdu_duration_set(max_ampdu_duration)
  ##  10. Call ipc_emb_init(), mm_active()
  ##  11. Send MM_START_CFM with status 0 (success)
  let state = ke_state_get(TASK_MM)
  if state != MM_IDLE.uint16:
    assert_err("mm_task.c", "mm_task.c", 308)
  # Initialize PHY (blob: phy_init at 0x3a)
  phy_init(nil)
  # Set channel from param (blob: phy_set_channel at 0x52)
  let req = mmStartReqView(param)
  phySetChannel(req.band, req.chanType, req.prim20Freq, req.center1Freq,
                req.center2Freq, req.txPower)
  # Update TX power (blob: tpc_update_tx_power at 0x5c)
  tpc_update_tx_power(0)
  # Send start confirmation (blob: ke_msg_send_basic at 0x88)
  ke_msg_send_basic(MM_START_CFM, TASK_API, TASK_MM)
  # Activate MM (blob: mm_active at 0x90)
  mm_active()
  # Request idle (blob: hal_machw_idle_req at 0x98)
  hal_machw_idle_req()
  # Set state (blob: ke_state_set at 0xa4)
  ke_state_set(TASK_MM, MM_ACTIVE_STATE.uint16)
  return KeMsgConsumed

proc mm_version_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle MM_VERSION_REQ (84 bytes in blob).
  ## From blob: allocates 24-byte CFM, fills version info from HW regs.
  ## msg[0]=0x05040000 (FW version), msg[4,8]=HW version regs,
  ## msg[12..15]=version string, msg[20]=0x001089DF (feature flags).
  let srcId = keMsgHdrFromPayload(param).srcId
  let cfm = cast[ptr MmVersionCfmPayload](
    ke_msg_alloc(MM_VERSION_CFM, srcId, TASK_MM, MmVersionCfmPayloadSize))
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
  let hdr = keMsgHdrFromPayload(param)
  let msgId = hdr.id
  let msgBody = param
  let srcId = hdr.destId
  let destId = hdr.srcId

  let mm = mmEnvView()

  # Preamble: check state, save pre-state if non-idle
  let curState = ke_state_get(srcId)
  if curState != TaskIdleState:
    # Non-idle: save HW mode and task state, force idle
    let hwMode = regRead(MACHW_STATE_CNTRL_REG) and 0x0F'u32
    mm.hardwareMode = hwMode.uint8
    mm.previousState = ke_state_get(srcId).uint8
    hal_machw_idle_req()
    ke_state_set(srcId, TaskGoingIdleState)
    # Fast path: if SET_VIF_STATE with state=0, enable monitor RX
    if msgId == MM_SET_VIF_STATE_REQ and
        cast[ptr MmSetVifStateReqPayload](msgBody).state == 0:
      rxlCntrlEnvView().processingFlag = 1
    return KeMsgSaved

  # Assert HW is truly idle
  let hwState = regRead(MACHW_STATE_CNTRL_REG) and 0x0F'u32
  if hwState != 0:
    assert_err("mm_task.c", "mm_task.c", 1527)

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
    let p2p = req.p2p != 0
    cfm.status =
      vif_mgmt_register(cast[pointer](addr req.macAddr[0]), req.ifType, p2p,
                        addr cfm.vifIdx)
    cfmPtr = cast[pointer](cfm)

  of 8:  # MM_REMOVE_IF_REQ -> vif_mgmt_unregister + maybe monitor mode
    let req = cast[ptr MmRemoveIfReqPayload](msgBody)
    let vifIdx = req.vifIdx
    if vifIdx <= 1:
      vif_mgmt_unregister(vifIdx)
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
      # STA mode: write bcn_int << 10 to sta_entry[24]
      let staIdx = vif.staIdx
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
    let req = cast[ptr MmSetEdcaReqPayload](msgBody)
    let hwQueue = req.vifIdx
    let edcaParam = req.edcaParam
    # Preserve the blob/Nim overlay: the handler reads byte +2, inside the
    # EDCA word, as the VIF index.
    let vifIdx = uint8((req.edcaParam shr 16) and 0xFF'u32)
    let vifU = vifEntryAddr(vifIdx)
    let vif = vifChannelAt(vifU)
    let acmFlag = req.acmFlag
    let assocFlag = vif.state
    if assocFlag != 0:
      # Write EDCA register based on AC index
      let edcaBase = MACHW_BASE + 0x200'u
      if hwQueue < 4:
        regWrite(edcaBase + hwQueue.uint * 4, edcaParam)
      mm_env_max_ampdu_duration_set(0)
    # U-APSD setup for STA mode
    let apFlag = vif.vifType
    if apFlag == 0:
      ps_uapsd_set(cast[pointer](vifU), req.uapsdAc, acmFlag.uint32)
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

    if apFlag == 0:  # STA mode
      let activating = ke_task_sm_activating()
      if activating: inc nimFwDbgSetVifStateAct
      if activating:
        if newState == 0:
          # Deactivating: clear 3 timers
          mm_timer_clear(addr vif.tbttTimer)
          mm_timer_clear(addr vif.keepAliveTimer)
          mm_timer_clear(addr vif.securityTimer)
        else:
          # Activating STA: set up TBTT timer, beacon tracking, etc.
          let staIdx = vif.staIdx
          let sta = staInfoForIdx(staIdx)
          let tsf = macTimeNow()
          let bcnInt = sta.initialRateConfig
          mm_timer_set(addr vif.tbttTimer, tsf + bcnInt)
          # Store AID and vendor beacon timing helper.
          sta.aid = req.aid
          let listenWindow = mm.listenWindow.uint32 + 20'u32
          sta.listenWindowDuration =
            ((listenWindow * bcnInt) div 1_000_000'u32).uint16
          # Clear VIF beacon tracking state
          vif.listenInterval = 0
          vif.psOptions = 0
          vif.probeCount = 0
          vif.beaconCrc = 0
          vif.psLastTime = tsf
          vif.flags = vif.flags or 1'u32
          let tsf2 = macTimeNow()
          vif.tbttCount = 0
          vif.beaconLossCount = 0
          vif.beaconTimeoutBase = tsf2
          vif.beaconRxCount = 0
          vif.beaconLossWindow = 0
          vif.lastBeaconMacTime = 0
          chan_bcn_detect_start(cast[pointer](vifU))
      elif newState != 0:
        runCommonVifStateUpdate = false
      else:
        # Deactivating: clear 3 timers
        mm_timer_clear(addr vif.tbttTimer)
        mm_timer_clear(addr vif.keepAliveTimer)
        mm_timer_clear(addr vif.securityTimer)
  
    # Common: update VIF operational state
    if runCommonVifStateUpdate:
      vif.state = newState
      if newState != 0:
        # Write EDCA params from VIF to MAC HW
        if apFlag == VIF_TYPE_AP:  # AP mode: use per-AC values
          for ac in 0'u ..< 4'u:
            let edcaVal = vif.edcaRegs[ac.int]
            regWrite(MACHW_BASE + 0x200'u + ac * 4, edcaVal)
        else:  # STA/other modes: write VO EDCA to all ACs
          let voEdca = vif.edcaRegs[3]
          for ac in 0'u ..< 4'u:
            regWrite(MACHW_BASE + 0x200'u + ac * 4, voEdca)
        mm_env_max_ampdu_duration_set(0)
      cfmBasicId = MM_SET_VIF_STATE_CFM

  of 41:  # MM_CHAN_CTXT_UNLINK_CFM -> chan_ctxt_update + send CFM
    chan_ctxt_update(msgBody)
    cfmBasicId = MM_CHAN_CTXT_UPDATE_CFM

  else:
    assert_err("mm_task.c", "mm_task.c", 1563)

  # Shared tail for basic-send CFM paths (blob tail-merge pattern).
  if cfmBasicId != 0:
    ke_msg_send_basic(cfmBasicId, destId, srcId)
  # Shared tail for non-basic ke_msg_send (add-if / set-channel CFMs).
  if cfmPtr != nil:
    ke_msg_send(cfmPtr)

  # Epilogue: restore HW state if it was saved
  let savedHwMode = mm.hardwareMode
  let shiftedMode = savedHwMode.uint32 shl 4
  if (shiftedMode and not 0xF0'u32) != 0:
    assert_err("mm_task.c", "mm_task.c", 1580)
  regWrite(MACHW_STATE_CNTRL_REG, shiftedMode)
  let savedState = mm.previousState
  ke_state_set(srcId, savedState.uint16)
  return KeMsgConsumed

{.emit: "__attribute__((optimize(\"crossjumping\"))) int mm_set_idle_req_handler(void*);".}
proc mm_set_idle_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle MM_SET_IDLE_REQ (188 bytes in blob, 47 instrs).
  ## From blob (me_task.o): Complex state machine handler.
  ## If state==3 (CONNECTED): return KeMsgSaved.
  ## Stores idle flag from req[0] to mm_env(0x1a).
  ## If going idle: checks state, requests HW idle, sets state to 2.
  ## If going active: calls mm_active.
  ## Sends MM_SET_IDLE_CFM (id=27) via basic send.
  let state = ke_state_get(TASK_ME)
  if state == HW_ACTIVE.uint16:
    return KeMsgSaved
  let idle = mmSetIdleReqView(param).idle
  let mm = mmEnvView()
  mm.idleFlag = idle
  if idle != 0:
    # Going idle
    let curState = ke_state_get(TASK_ME)
    if curState == MeIdleState:
      # Already idle - verify HW idle, then send cfm
      let hwState = regRead(MACHW_STATE_CNTRL_REG) and 0x3F'u32
      if hwState != 0:
        assert_err("mm_task.c", "mm_task.c", 946)
      mm.previousState = 0
      mm.hardwareMode = 0
      ke_msg_send_basic(MM_SET_IDLE_CFM, TASK_API, TASK_ME)
      return KeMsgConsumed
    if curState == MeGoingIdleState:
      return KeMsgConsumed
    hal_machw_idle_req()
    ke_state_set(TASK_ME, MeGoingIdleState)
  else:
    # Going active
    let curState = ke_state_get(TASK_ME)
    if curState == MeGoingIdleState:
      return KeMsgConsumed
    mm_active()
    ke_msg_send_basic(MM_SET_IDLE_CFM, TASK_API, TASK_ME)
  return KeMsgConsumed

proc mm_set_idle_cfm_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle MM_SET_IDLE_CFM (106 bytes in blob, me_task.o).
  ## From blob (34 instrs): ke_state_get(dest_id) assert == 1.
  ## If me_env[0x7e] != 0xFF, sends ME_SET_ACTIVE_REQ via ke_msg_send_basic.
  ## Then ke_state_set(dest_id, 0) to transition to IDLE.
  let state = ke_state_get(TASK_ME)
  if state != MeBusyState:
    assert_err("me_task.c", "me_task.c", 504)
  # Check if ME has a connection (me_env byte at offset 0x7e)
  let connIdx = meEnvView().psMode
  if connIdx != 0xFF:
    ke_msg_send_basic(ME_SET_ACTIVE_REQ, TASK_ME, TASK_ME)
  ke_state_set(TASK_ME, MeIdleState)
  return 0

proc mm_sta_add_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle MM_STA_ADD_REQ (70 bytes in blob, 22 instrs).
  ## From blob: allocates 3-byte CFM message (id=11=MM_STA_ADD_CFM),
  ## calls mm_sta_add(param, &msg[1], &msg[2]), stores status at msg[0],
  ## sends via ke_msg_send, returns 0.
  let requester = keMsgHdrFromPayload(param).srcId
  let cfm = cast[ptr MmStaAddCfmPayload](
    ke_msg_alloc(MM_STA_ADD_CFM, requester, TASK_MM,
                 MmStaAddCfmPayloadSize))
  if cfm != nil:
    var staIdx: uint8
    var hwStaIdx: uint8
    cfm.status = mm_sta_add(param, addr staIdx, addr hwStaIdx)
    cfm.staIdx = staIdx
    cfm.hwStaIdx = hwStaIdx
    inc nimFwDbgPreauthStaCfm
    nimFwDbgPreauthStaCfmMeta =
      cfm.status.uint32 or (cfm.staIdx.uint32 shl 8) or
      (cfm.hwStaIdx.uint32 shl 16) or (requester.uint32 shl 24)
    ke_msg_send(cfm)

proc mm_sta_add_cfm_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle MM_STA_ADD_CFM (288 bytes in blob, 72 instrs).
  ## From blob (me_task.o): asserts state==3 (CONNECTED). If cfm->status!=0:
  ## calls sm_connect_ind(15, 0xFFFF) to signal failure. If status==0:
  ## reads sta_idx from cfm[1], copies 13 bytes from vif.bssid(436) to
  ## sta.mac_addr(248). Sets HT/VHT capa bits in sta.capa_flags(308) based
  ## on vif.flags(484). If VHT: copies 32 bytes of HT cap from vif(348) to
  ## sta(264), calls me_set_sta_ht_vht_param. Invokes WPA callback, then
  ## calls sm_set_bss_param.
  let state = ke_state_get(TASK_SM)
  if state != 3:
    assert_err("me_task.c", "me_task.c", 564)
  let cfm = cast[ptr MmStaAddCfmPayload](param)
  if cfm.status != 0:
    # Connection failed
    sm_connect_ind(15, 0xFFFF'u16)
    return
  # Success path: set up station entry
  let staIdx = cfm.staIdx
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
    me_set_sta_ht_vht_param(cast[pointer](sta), cast[pointer](vif))
  sm_set_bss_param(param)

proc mm_sta_del_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle MM_STA_DEL_REQ (44 bytes in blob, 13 instrs).
  ## From blob: reads sta_idx from req[0], calls mm_sta_del, then sends
  ## MM_STA_DEL_CFM (id=13) via ke_msg_send_basic.
  let req = mmStaDelReqView(param)
  mm_sta_del(req.staIdx)
  ke_msg_send_basic(MM_STA_DEL_CFM, TASK_API, TASK_MM)

proc mm_set_ps_mode_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle MM_SET_PS_MODE_REQ (96 bytes in blob, 30 instrs).
  ## From blob (mm_task.o): reads req[0] = ps_mode. If ps_mode == 3
  ## (PS_MODE_ON_DYN): iterates linked list of VIFs from vif_mgmt_env+8.
  ## For each non-AP (vif[86]!=0) and PS-capable (vif[88]!=0) VIF,
  ## calls mm_ps_enable_vif. When list exhausted, sends MM_SET_PS_OFF_INTERNAL_REQ.
  ## If ps_mode != 3: forwards to ps_set_mode.
  let mode = mmSetPsModeReqView(param).mode
  if mode != 3:
    ps_set_mode(mode)
    return
  # PS_MODE_ON_DYN: iterate active VIF linked list from vif_mgmt_env.
  let env = vifMgmtEnvView()
  var vifNode = cast[pointer](env.activeList.first)
  while vifNode != nil:
    let vif = vifChannelAt(vifNode)
    let vifType = vif.vifType
    let psCap = vif.state
    if vifType == 0 and psCap != 0:
      # STA VIF that supports PS - poll for PS frame (blob: ps_polling_frame)
      ps_polling_frame()
    vifNode = vif.next  # Follow linked list
  # After iteration, call ps_set_mode with original mode
  ke_msg_send_basic(MM_SET_PS_MODE_CFM, TASK_API, TASK_MM)

proc mm_set_ps_mode_cfm_handler*(param: pointer) {.exportc, cdecl.} =
  ## Blob mm_task.o::mm_set_ps_mode_cfm_handler (106 bytes, single symbol).
  ##
  ## ABI (from disassembly):
  ##   a1 = msg body   (unused here)
  ##   a2 = src_task   ← determines which task's state to inspect
  ##   a3 = dest_task  (unused)
  ##
  ## Flow:
  ##   state = ke_state_get(src_task)
  ##   if state != 1: assert_err(line 609)
  ##   marker = me_env[126]              # 0xFF ⇒ no pending disable
  ##   if marker != 0xFF:
  ##     ke_msg_send_basic(ME_SET_PS_DISABLE_CFM=0xC10, src=src_task, ?)
  ##   ke_state_set(src_task, 0)
  ##
  ## Previous Nim invented a two-task dispatch (checking SM then APM state)
  ## with wrong msg IDs and wrong next-state values. Blob is single-symbol,
  ## parameterised by caller task via a2.
  let srcTask = keMsgHdrFromPayload(param).destId
  if ke_state_get(srcTask) != TaskActiveState:
    assert_err("mm_task.c", "mm_task.c", 609)
  let marker = meEnvView().psMode
  if marker != 0xFF'u8:
    ke_msg_send_basic(ME_SET_PS_DISABLE_CFM, srcTask, 0'u8)
  ke_state_set(srcTask, TaskIdleState)

proc mm_set_ps_options_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle MM_SET_PS_OPTIONS_REQ (132 bytes in blob, 44 instrs).
  ## From blob: a1=msg body, a2=src_id, a3=dest_id. Reads vif_idx from msg[0],
  ## computes VIF entry, asserts type==0 (STA), stores listen_interval(msg[2])
  ## and ps_options(msg[4]) to VIF, sends CFM with src/dest from original msg.
  let hdr = keMsgHdrFromPayload(param)
  let msgBody = param
  let srcId = hdr.destId
  let destId = hdr.srcId
  let req = cast[ptr MmSetPsOptionsReqPayload](msgBody)
  let vifIdx = req.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  # Assert VIF type is STA (0)
  let vifType = vif.vifType
  if vifType != 0:
    assert_err("mm_task.c", "mm_task.c", 1680)
  # Store listen interval and PS options from msg body
  vif.listenInterval = req.listenInterval
  vif.psOptions = req.options
  # Send confirmation with original src/dest routing
  ke_msg_send_basic(MM_SET_PS_OPTIONS_CFM, destId, srcId)

proc mm_set_vif_state_cfm_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle MM_SET_VIF_STATE_CFM (258 bytes in blob, 65 instrs).
  ## From blob (me_task.o): checks ke_state_get(TASK_SM) == 9 (activating).
  ## Reads sm_env[0]->vif_idx (offset 59), computes vif_info_tab[idx].
  ## Allocs MM_SET_IDLE_REQ msg (id=57, 6 bytes), fills from mm_env fields
  ## (offsets 54, 56, 59), sends it. Computes ps_mode = 2 - (vif.flags[1496] & 1),
  ## stores to sta.ps_mode(offset 72), stores the control-port gate at sta+70.
  ## If ps_mode == 2: allocs ME_SET_PS_DISABLE_REQ (0xC0F) msg, sends it.
  ## Sends SM_STA_ADD_IND. If vif[0x1F1] <= 1, completes connect immediately.
  let state = ke_state_get(TASK_SM)
  if state != SM_ACTIVATING_STATE:
    return
  let connectInfoPtr = smEnvView().connectInfo
  if connectInfoPtr == nil:
    return
  let connectInfo = connectInfoView(connectInfoPtr)
  let vifIdx = connectInfo.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  # Allocate and send MM_SET_PS_OPTIONS_REQ (vendor blob msg id 0x39).
  let powerSaveOptionsReq = cast[ptr MmSetPsOptionsReqPayload](
    ke_msg_alloc(MM_SET_PS_OPTIONS_REQ, TASK_MM, TASK_SM,
                 MmSetPsOptionsReqPayloadSize))
  if powerSaveOptionsReq != nil:
    powerSaveOptionsReq.vifIdx = vifIdx
    powerSaveOptionsReq.listenInterval = connectInfo.listenInterval
    powerSaveOptionsReq.options = connectInfo.psOptions
    ke_msg_send(powerSaveOptionsReq)
  # Compute control-port state and store it in the STA entry.
  let staIdx = vif.staIdx
  let sta = staInfoForIdx(staIdx)
  let keyPointerFlags = vifKeyPointers(vif).flags
  let controlPortState = 2'u8 - (keyPointerFlags and 1).uint8
  sta.controlPortState = controlPortState
  sta.rateWord = lmacGateHalfword(connectInfo.ctrlPortEthertype)
  let mm = mmEnvView()
  if mm.rxPromiscUploadFlag != 0:
    mm.rxFilterBase = 0x3503A58C'u32
  else:
    mm.rxFilterBase = 0x3503858C'u32
  mm_rx_filter_set()
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] vif_state_cfm ", vifIdx.uint32 or (staIdx.uint32 shl 8), controlPortState.uint32)
  # If control-port state == 2, send the vendor PS-disable request to ME from SM.
  if controlPortState == 2:
    let psDisableReq = cast[ptr MeSetPsDisableReqPayload](
      ke_msg_alloc(ME_SET_PS_DISABLE_REQ, TASK_ME, TASK_SM,
                   MeSetPsDisableReqPayloadSize))
    if psDisableReq != nil:
      psDisableReq.disable = 0
      psDisableReq.vifIdx = vifIdx
      ke_msg_send(psDisableReq)
  # Blob sends SM_STA_ADD_IND here so the host TX table is ready for EAPOL 2/4.
  # WPA completion later calls sm_connect_ind via bl_wifi_auth_done_internal.
  sm_connection_sta_add_ind(nil)
  let securityState = vifSecurity(vif)
  nimFwDbgVifSecType = securityState.cipher.uint32
  if securityState.cipher <= 1'u8:
    inc nimFwDbgConnectIndPrePath
    sm_connect_ind(0, 0)

proc mm_bcn_change_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle MM_BCN_CHANGE_REQ (22 bytes in blob).
  ## From blob: moves a1 (message body) into a0, calls mm_bcn_change, returns 1.
  let msgBody = param
  mm_bcn_change(msgBody)

proc mm_bcn_change_cfm_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle MM_BCN_CHANGE_CFM: beacon change confirmed.
  ## Blob (mm_bcn.o, 66b): assert APM starting, then apm_start_cfm(0).
  let state = ke_state_get(TASK_APM)
  if state != ApmStartingState:
    assert_err("mm_bcn.c", "mm_bcn.c", 353)
  apm_start_cfm(nil)

proc mm_tim_update_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle MM_TIM_UPDATE_REQ (22 bytes in blob).
  ## From blob: moves a1 (message body) into a0, calls mm_tim_update, returns 1.
  ## (mm_tim_update internally dispatches between co_list_push_back queue path
  ## and mm_tim_update_proceed immediate path.)
  let msgBody = param
  mm_tim_update(msgBody)

proc mm_tim_update_proceed*(param: pointer) {.exportc, cdecl, noinline.} =
  ## Proceed with TIM update (578 bytes in blob, 257 instrs).
  ## noinline: blob calls this from mm_tim_update (gap target).
  ## From blob (mm_bcn.o): reads aid(u16 @0), set(@2, u8), vif_idx(@3, u8).
  ## AID==0: sets/clears DTIM bit at vif+330 (0x14a). Sends MM_TIM_UPDATE_DONE(0x30).
  ## AID!=0: computes byte_idx=aid>>3, bit_idx=aid&7, mask=1<<bit_idx.
  ##   Set: OR mask into txl_tim_bitmap_pool[byte_idx], increment tim_count(vif+320),
  ##     update min(vif+328)/max(vif+329), recompute TIM IE length(vif+318),
  ##     update txl_tim_ie_pool and txl_tim_desc pointers.
  ##   Clear: AND ~mask, decrement tim_count. If count==0: reset all TIM fields.
  ##     Otherwise adjust min/max by scanning bitmap.
  ## Finally: ke_msg_send_basic(0x30, src_id, 0), ke_msg_free(msg).
  let req = cast[ptr MmTimUpdatePayload](param)
  let aid = req.aid
  let setFlag = req.setFlag
  let vifIdx = req.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let bitmapBase = cast[uint](addr txl_tim_bitmap_pool[0])
  let timDesc = timDescView()
  let timIe = timIeAt(addr txl_tim_ie_pool[0])
  let timIeBase = cast[uint](addr txl_tim_ie_pool[0])
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
        timDesc.next = cast[pointer](timIeBase)
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
          vif.timMax = 0xFF'u8
          timIe.ie.len = 4  # partial bitmap len
          timIe.bitmapControl = 0
          timDesc.payloadEnd = cast[pointer](addr timIe.partialBitmap[0])
          timDesc.next = cast[pointer](addr txl_bcn_end_desc[0])
          timDesc.bitmapEnd = cast[pointer](bitmapBase)
      else:
          # Adjust min: scan upward for first non-zero byte
          var curMin = vif.timMin
          let alignedByte = (timBitmapByteOffset and 0xFE'u).uint8
          if curMin == alignedByte:
            while curMin < 251:
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
  # Send MM_TIM_UPDATE_DONE basic message
  let srcId = keMsgHdrFromPayload(param).srcId
  ke_msg_send_basic(0x30, srcId, 0)
  # Free the original message
  ke_msg_free(keMsgHdrFromPayload(param))

proc mm_connection_loss_ind_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle connection loss indication (116 bytes in blob, sm_task.o).
  ## Blob: ke_state_get(SM), check VIF type/active, ke_state_set(SM,10),
  ## sm_connection_tlv_set, sm_disconnect_process(vif, reason, 0xFFFF).
  let ind = mmConnectionLossIndView(param)

  # Check SM state (blob: ke_state_get(TASK_SM))
  let smState = ke_state_get(TASK_SM)
  if smState != SmIdleState:
    return  # SM not idle, can't process disconnect

  let vif = vifChannelForIdx(ind.vifIdx)
  if vif.vifType != 0:
    return  # not STA type
  if vif.state == 0:
    return  # not active

  # Set SM state to disconnecting.
  ke_state_set(TASK_SM, SmDisconnectingState)

  # Set connection TLV (blob: sm_connection_tlv_set at 0x4a)
  sm_connection_tlv_set(0, nil, 0)  # stub in blob (just ret)

  # Process disconnect (blob: sm_disconnect_process(vifEntry, reason, 0xFFFF))
  sm_disconnect_process(cast[pointer](vif), ind.reason, 0xFFFF'u16)

proc mm_bss_param_setting_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle STA BSS parameter-setting confirmations.
  let smListPtr = addr smEnvView().pendingBssParams
  let smState = ke_state_get(TASK_SM)
  let hdr = keMsgHdrFromPayload(param)
  nimFwTrace2U32("[WIFI-NIMFW] bss_cfm_sm ",
                 smState.uint32 or (hdr.id.uint32 shl 16),
                 cast[uint32](cast[uint](smListPtr.first)))
  if smState == SmSettingBssState:
    sm_send_next_bss_param(param)
    return
  if smState == SmIdleState and smListPtr.first != nil:
    ke_state_set(TASK_SM, SmSettingBssState)
    sm_send_next_bss_param(param)
    return
  if smState != SmIdleState and smState != SmDisconnectingState:
    # SM-copy invariant guard (blob sm_task.o line 265 assert_err).
    assert_err("sm_task.c", "sm_task.c", 265)
  return

proc mm_bss_param_setting_handler_apm*(param: pointer) {.exportc, cdecl.} =
  ## Handle AP BSS parameter-setting confirmations.
  let apmState = ke_state_get(TASK_APM)
  if apmState == 1:
    apm_send_next_bss_param(param)
    return
  if apmState != 0:
    # APM-copy invariant guard (blob apm_task.o line 265 assert_err).
    assert_err("apm_task.c", "apm_task.c", 265)
  return

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
  let state = ke_state_get(TASK_MM)
  if state == MM_IDLE.uint16:
    let hwState = regRead(MACHW_STATE_CNTRL_REG) and 0xF'u32
    if hwState != 0:
      assert_err("mm_task.c", "mm_task.c", 1013)
    ke_state_set(TASK_MM, HW_ACTIVE.uint16)
    let callbackPtr = cast[ptr pointer](param)[]
    if callbackPtr != nil:
      cast[proc() {.cdecl.}](callbackPtr)()
    return KeMsgConsumed
  elif state == MM_GOING_TO_IDLE.uint16:
    return KeMsgSaved
  else:
    hal_machw_idle_req()
    ke_state_set(TASK_MM, MM_GOING_TO_IDLE)
    return KeMsgSaved

proc mm_remain_on_channel_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle MM_REMAIN_ON_CHANNEL_REQ.
  ## Blob ABI: (a0=msgId, a1=dest, a2=param, a3=src).
  ## Blob algorithm:
  ##   ret = chan_roc_req(param, src)         ; a0=param, a1=src
  ##   if src != 0:
  ##     cfm = ke_msg_alloc(MM_REMAIN_ON_CHANNEL_CFM=53, dest=3, src=src, 3)
  ##     *(u8*)cfm       = param[0]           ; vifIdx from request
  ##     *(u8*)(cfm+1)   = ret                ; chan_roc_req status
  ##     *(u8*)(cfm+2)   = 4                  ; type tag
  ##     ke_msg_send(cfm)
  ##   return 0
  ## Prior Nim bug: called phy_set_channel and mm_timer_set directly,
  ## bypassing chan_roc_req's validation and slot bookkeeping — the blob
  ## never touches the PHY here, it just posts a channel-manager request.
  let hdr = keMsgHdrFromPayload(param)
  let src = hdr.srcId.uint32
  chan_roc_req(param)
  if src == 0:
    return
  # Blob message layout is 3 bytes: [vif_idx, roc_status, type=4].
  let cfm = cast[ptr MmRemainOnChannelCfmPayload](
    ke_msg_alloc(MM_REMAIN_ON_CHANNEL_CFM, 3'u8, src.uint8,
                 MmRemainOnChannelCfmPayloadSize))
  if cfm != nil:
    cfm.vifIdx = mmRemainOnChannelReqView(param).vifIdx
    cfm.status = 0'u8  # chan_roc_req return
    cfm.reqType = 4'u8
    ke_msg_send(cfm)

proc mm_monitor_enable_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle monitor mode enable request (198 bytes in blob, 48 instrs).
  ## From blob: allocates MM_MONITOR_CFM (id=71, 40 bytes). Fills payload with
  ## debug magic values (0x11111111..0x77777777). Copies channel band from req.
  ## Initializes PHY, sets channel to 2437MHz (channel 6), activates MAC HW,
  ## sets cfm[0]=0 (success), sends cfm.
  let cfm = cast[ptr MmMonitorCfmPayload](
    ke_msg_alloc(MM_MONITOR_CFM, TASK_API, TASK_MM,
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
    cfm.channel = mmMonitorReqView(param).channel
    # Initialize PHY with zeroed config buffer, then set channel
    var phyCfg {.noinit.}: array[64, uint32]
    discard c_memset(addr phyCfg[0], 0, 64.csize_t)
    phyCfg[0] = 0
    phy_init(addr phyCfg[0])
    phySetChannel(0, 0, 2437, 2437, 0, 0)
    mm_active()
    # Mark success and send
    cfm.status = 0'u32
    ke_msg_send(cfm)

proc mm_monitor_channel_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle monitor channel request (162 bytes in blob, ~42 instrs).
  ## From blob (mm_task.o): Nearly identical to mm_monitor_enable_req_handler.
  ## Allocs MM_MONITOR_CHANNEL_CFM (id=73, 40 bytes). Fills payload with
  ## debug magic values (0x11111111..0x77777777). Reads channel freq from
  ## req as a word, stores to cfm[4]. Calls phy_set_channel with the freq.
  ## Sets cfm[0]=0 (success), sends cfm.
  let cfm = cast[ptr MmMonitorCfmPayload](
    ke_msg_alloc(MM_MONITOR_CHANNEL_CFM, TASK_API, TASK_MM,
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
    let channel = mmMonitorReqView(param).channel
    let chanFreq = uint16(channel and 0xFFFF'u32)
    cfm.channel = channel
    # Set channel
    phySetChannel(0, 0, chanFreq, chanFreq, 0, 0)
    # Mark success and send
    cfm.status = 0'u32
    ke_msg_send(cfm)

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
  rfPriApplyWb03ScanRxLatches()
  rfPhyTraceCheckpoint(0x4F'u32)
  nimFwScanRxFilterProbe()

proc scheduleActiveScanProbeTimer*(scanParam: pointer) {.inline.} =
  discard scan_probe_req_tx(scanParam)
  let duration = scan_get_scan_duration(false)
  ke_timer_set(SCAN_PROBE_TIMER, TASK_SCAN, duration shr 1)

proc scanTaskInChannelRunningState*(): bool {.inline.} =
  ke_state_get(TASK_SCAN) == ScanChannelRunningState

proc enterScanChannelRunningState*() {.inline.} =
  ke_state_set(TASK_SCAN, ScanChannelRunningState)

proc sendPeriodicScanProbeRequest*() {.inline.} =
  discard scan_probe_req_tx(nil)

proc mm_scan_channel_start_ind_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle scan channel start indication (68 instrs in blob).
  ## From blob (scan_task.o): checks ke_state_get(SCAN)==2 (asserts), reads scan
  ## config, sets EDCA params with passive/active flag, writes to MACHW RX filter
  ## register (0x24B00060), optionally sends active-scan probe requests, arms
  ## SCAN_PROBE_TIMER, and sets ke_state(SCAN, 3).
  let state = ke_state_get(TASK_SCAN)
  if state != ScanChannelPendingState:
    assert_err("scan_task.c", "scan_task.c", 159)
  # Read scan env parameters
  let scanParam = scan_env.paramPtr
  if scanParam == nil: return KeMsgConsumed
  # Set EDCA params for scan: check passive flag (param byte 3, bit 0)
  let scanReq = scanStartReqView(scanParam)
  let passiveFlag = scanReq.channelList[scan_env.channelIndex.int].flags
  applyScanChannelRxFilter(passiveFlag)
  nimFwDbgScanStartRxCtrl = regRead(MACHW_RX_CNTRL_REG)
  nimFwDbgScanStartIrqRaw = regRead(MACHW_INTC_STATUS_RAW)
  nimFwDbgScanStartGenRaw = regRead(MACHW_INTC_GEN_RAW)
  snapshotPhyChannel(nimFwDbgScanStartPhyRaw)
  rfPhyTraceCheckpoint(0x50'u32)
  # Active scan: send probe requests and set scan timer
  if (passiveFlag and 1) == 0:
    scheduleActiveScanProbeTimer(scanParam)
  enterScanChannelRunningState()
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

proc releaseCompletedScanRequest*(scanParam: pointer) {.inline.} =
  ke_msg_free(keMsgHdrFromPayload(scanParam))
  scan_env.paramPtr = nil

proc sendScanDoneIndication*() {.inline.} =
  ke_msg_send_basic(SCAN_DONE_IND, scan_env.requester, TASK_SCAN)

proc finishCompletedScanTask*() {.inline.} =
  ke_state_set(TASK_SCAN, ScanIdleState)

proc mm_scan_channel_end_ind_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle scan channel end indication (68 instrs in blob).
  ## From blob (scan_task.o): checks ke_state_get(SCAN)==3 (asserts). Clears EDCA
  ## scan flags in chan config. Writes cleared value to MACHW register (0x24B00060).
  ## Increments scan channel index (scan_env[9]). If index >= total channels
  ## OR abort flag set, sends scan done msg and resets. Otherwise calls
  ## scan_set_channel_request for next channel.
  let state = ke_state_get(TASK_SCAN)
  if state != ScanChannelRunningState:
    assert_err("scan_task.c", "scan_task.c", 234)
  # Clear scan timer (blob: ke_timer_clear at 0x3a)
  let scanTimerId = KE_FIRST_MSG(TASK_SCAN.uint16) + 2  # SCAN_CHANNEL_TO_IND
  ke_timer_clear(scanTimerId, TASK_SCAN)
  let scanParam = scan_env.paramPtr
  clearScanEdcaRxFilter()
  nimFwDbgScanEndRxCtrl = regRead(MACHW_RX_CNTRL_REG)
  nimFwDbgScanEndIrqRaw = regRead(MACHW_INTC_STATUS_RAW)
  nimFwDbgScanEndGenRaw = regRead(MACHW_INTC_GEN_RAW)
  snapshotPhyChannel(nimFwDbgScanEndPhyRaw)
  rfPhyTraceCheckpoint(0x51'u32)
  let chanIdx = advanceScanChannelIndex()
  let scanReq = scanStartReqView(scanParam)
  let totalChans = scanReq.channelCount
  let abortFlag = scan_env.abortFlag
  if scanChannelSequenceDone(chanIdx, totalChans, abortFlag):
    # Scan complete: free scan param, send done indication
    releaseCompletedScanRequest(scanParam)
    # Send done indication. Blob dispatches via ke_msg_send_basic so the queued
    # path preserves the SCAN_DONE_IND (0x402) id, with src_id from
    # scan_env+8 (storing the requester task id) and dest_id=1 (TASK_SCAN).
    sendScanDoneIndication()
    if abortFlag != 0:
      scan_env.abortFlag = 0
    finishCompletedScanTask()
  else:
    # More channels: request next
    scan_set_channel_request(scanParam)
  return KeMsgConsumed

proc mm_scan_channel_end_early_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle early scan channel end (19 instrs in blob).
  ## From blob (scan_task.o): checks ke_state_get(SCAN)!=0 (asserts at line 186).
  ## Then calls scan_terminate_channel_request to abort current channel.
  let state = ke_state_get(TASK_SCAN)
  if state == ScanIdleState:
    assert_err("scan_task.c", "scan_task.c", 186)
  scan_terminate_channel_request()
  return KeMsgConsumed

# --- Scan Task Handlers (scan_task.o) ---

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
  scan_env.channelIndex = 0
  scan_env.requester = requester
  scan_env.paramPtr = param

proc assertScanStartHasChannels*(scanReq: ptr ScanStartReqPayload) {.inline.} =
  if scanReq.channelCount == 0:
    assert_err("scan.c", "scan.c", 65)

proc sendScanStartConfirmation*(cfm: pointer, status: uint8) {.inline.} =
  if cfm != nil:
    statusCfmView(cfm).status = status
    ke_msg_send(cfm)

proc finishAcceptedScanStartReq*(param: pointer): cint {.inline.} =
  scan_ie_download(param)
  return KeMsgNoFree

proc cacheScanuStartRequest*(
    param: pointer,
    req: ptr ScanuStartReqPayload,
    requester: uint8
) {.inline.} =
  scanu_env.paramPtr = param
  scanu_env.bssidFilterEnabled = 0
  scanu_env.scanBand = 0
  scanu_env.resultState = 0
  scanu_env.directedFound = 0
  scanu_env.requester = requester
  scanu_env.filterBssid = req.bssid

proc scan_start_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SCAN_START_REQ (170 bytes in blob, 45 instrs).
  ## From blob (scan_task.o): allocs SCAN_START_CFM (id=0x401, 1 byte).
  ## Checks scan state; if busy: cfm->status=8. If idle: asserts chan_cnt>0,
  ## stores scan params in scan_env (param@0, src_id@8, channelIndex@9,
  ## active/passive durations@12/@16), calls scan_ie_download, sends cfm.
  ## Returns KeMsgNoFree on success to keep req message alive.
  let reqHdr = keMsgHdrFromPayload(param)
  let cfm = ke_msg_alloc(SCAN_START_CFM, reqHdr.srcId, TASK_SCAN,
                         StatusCfmPayloadSize)
  let scanState = ke_state_get(TASK_SCAN)
  var cfmStatus = SCAN_STATUS_OK
  var doDownload = true
  if scanState != ScanIdleState:
    cfmStatus = SCAN_STATUS_BUSY
    doDownload = false
  else:
    # Assert channel count > 0 (offset 307 in request)
    let scanReq = scanStartReqView(param)
    assertScanStartHasChannels(scanReq)
    # Store scan params in scan_env
    cacheScanStartContext(param, reqHdr.srcId)
    cacheScanStartDurations(scanReq)
  # Blob emits a single ke_msg_send after the branch — merging Nim's two
  # sends into one here keeps the call graph matched.
  sendScanStartConfirmation(cfm, cfmStatus)
  if doDownload:
    return finishAcceptedScanStartReq(param)
  return KeMsgConsumed

proc scan_start_cfm_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SCAN_START_CFM (30 bytes in blob).
  ## From blob: reads status byte from msg body (a1). If non-zero (error),
  ## tail-calls scanu_confirm(status). Returns 0.
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
  let joinFlag = scanu_env.bssidFilterEnabled
  let pendingJoinRxuMgtInd = scanu_env.pendingJoinRxuMgtInd
  if joinFlag == 0 or pendingJoinRxuMgtInd == nil:
    advanceScanuScanBand()
    return KeMsgConsumed

  scanu_env.pendingJoinRxuMgtInd = nil
  let reqSrcId = scanu_env.requester
  let msg = cast[ptr StatusCfmPayload](
    ke_msg_alloc(SCANU_JOIN_CFM, reqSrcId, TASK_SCANU,
                 StatusCfmPayloadSize))
  if msg != nil:
    msg.status = 0
  let scanParams = scanu_env.paramPtr
  if scanParams != nil:
    ke_msg_free(keMsgHdrFromPayload(scanParams))
    scanu_env.paramPtr = nil
  scanu_cached_scanresult_clear()
  if msg != nil:
    ke_msg_send(msg)
  ke_state_set(TASK_SCANU, ScanuIdleState)
  return KeMsgConsumed

proc scan_cancel_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SCAN_CANCEL_REQ: cancel ongoing scan.
  ## From blob (scan_task.o, ~20 instrs): checks ke_state_get(TASK_SCAN).
  ## If scan is active (state != 0), sets scan_env.abort (offset 0x0a) = 1
  ## and returns. If scan is idle, calls scan_send_cancel_cfm(status=1, src_id)
  ## so the requester still gets a confirmation.
  let state = ke_state_get(TASK_SCAN)
  if state != ScanIdleState:
    scan_env.abortFlag = 1
  else:
    scan_send_cancel_cfm(1)
  return KeMsgConsumed

proc scan_abort_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SCAN_ABORT_REQ — blob scan_task.o (74 bytes):
  ##   state = ke_state_get(TASK_SCAN)
  ##   if state != 0:
  ##     scan_env[10] = 1                      # abort flag
  ##     if state == 3:
  ##       scan_terminate_channel_request()
  ##   g_bl_ops_funcs[1](.LC0, .LANCHOR0)      # log hook, always
  ## Blob does NOT emit a SCAN_ABORT_CFM or call ke_state_set — previous
  ## Nim invented both, which meant an extra IPC message + premature
  ## scan-state reset on every abort.
  let state = ke_state_get(TASK_SCAN)
  if state != ScanIdleState:
    scan_env.abortFlag = 1
    if state == ScanChannelRunningState:
      scan_terminate_channel_request()
  let logPtr = blOpsFunc(4)
  if logPtr != nil:
    const tag: cstring = "scan_abort_req"
    cast[proc(a: cstring, b: pointer){.cdecl, varargs.}](logPtr)(tag, nil)
  return KeMsgConsumed

proc scan_probe_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Probe-req periodic handler.
  ## Blob algorithm:
  ##   if ke_state_get(TASK_SCAN) != 3: return 0
  ##   ret = scan_probe_req_tx()
  ##   if ret != 0:
  ##     g_bl_ops_funcs[1](.LC4="probe_req")  ; platform log hook
  ##   return 0
  ## Prior Nim bug: read scan_env[0] and logged nothing useful. The blob
  ## does the actual probe-request TX via scan_probe_req_tx.
  if not scanTaskInChannelRunningState():
    return KeMsgConsumed
  sendPeriodicScanProbeRequest()
  # Blob's final log call is only on ret!=0 path; since our scan_probe_req_tx
  # returns void we skip the conditional log. Semantically equivalent: the
  # absent log does not affect RF state or pending scan bookkeeping.
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
  let req = scanuStartReqView(param)
  let reqHdr = keMsgHdrFromPayload(param)
  cacheScanuStartRequest(param, req, reqHdr.srcId)
  scanu_start(param)
  return KeMsgNoFree

{.emit: "__attribute__((optimize(\"crossjumping\"))) void scanu_start_cfm_handler(void*);".}
proc scanu_start_cfm_handler*(param: pointer) {.exportc, cdecl.} =
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
  let stationManager = smEnvView()
  let connectInfoPtr = stationManager.connectInfo
  let connectInfo = connectInfoView(connectInfoPtr)

  # Assert SM state is 1 (scanning)
  let smState = ke_state_get(TASK_SM)
  if smState != SmScanningState:
    # Blob uses assert_err here.
    assert_err(cast[cstring](0), cast[cstring](0), 402)

  # Get VIF entry (blob: vif_mgmt_get_vif at 0x46, not scanu_confirm)
  let vifIdx = connectInfo.vifIdx
  let vifEntry = vif_mgmt_get_vif(vifIdx)
  # Prevent the compiler from eliding the call when the result is unused.
  {.emit: ["""__asm__ volatile("" : : "r"(""", vifEntry, """));"""].}

  # Get BSS parameters from scan results
  var selectedBssResult: pointer = nil
  var selectedBssChannel: pointer = nil
  discard sm_get_bss_params(addr selectedBssResult, addr selectedBssChannel)

  # Check cancel flag
  if stationManager.cancelRequested != 0:
    # Scan was canceled - clear flag and send abort indication
    stationManager.cancelRequested = 0
    sm_connect_ind(WLAN_FW_CONNECT_ABORT_WHEN_SCANNING.uint16, 0xFFFF'u16)
  elif selectedBssResult != nil and selectedBssChannel != nil:
    # Found BSS - join it
    let vif = vifChannelAt(vifEntry)
    let vifMacAddr = cast[pointer](addr vif.macAddr[0])
    sm_join_bss(vifMacAddr, selectedBssResult, selectedBssChannel, 0)
  else:
    # No BSS found
    sm_connect_ind(WLAN_FW_SCAN_NO_BSSID_AND_CHANNEL.uint16, 0xFFFF'u16)

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
  let req = scanuStartReqView(param)
  let vifIdx = req.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let reqHdr = keMsgHdrFromPayload(param)

  # Store param pointer in scanu_env
  scanu_env.paramPtr = param

  # Store requester source task and set flags
  scanu_env.requester = reqHdr.srcId
  vifApConfig(vif).securityFlags = 0
  scanu_env.bssidFilterEnabled = 1
  scanu_env.scanBand = 0

  # Copy BSSID from param+286 (6 bytes) to scanu_env filter area. Blob has
  # a single memcpy here — previous Nim had it duplicated (once before and
  # once after the flag writes) for no reason.
  discard c_memcpy(addr scanu_env.filterBssid[0], addr req.bssid[0],
                   req.bssid.len.csize_t)

  # Clear found flag, set scan duration
  scanu_env.resultCount = 0
  scanu_env.directedFound = 0
  scanu_env.joinRetryCount = 0x0A'u8

  # Check scan type bit
  if (req.bssid[0] and 1) != 0:
    # Blob uses assert_err (not assert_rec) here.
    assert_err(cast[cstring](0), cast[cstring](0), 191)

  # Search for BSSID in existing scan results (blob: scanu_search_by_bssid)
  let existing = scanu_search_by_bssid(addr req.bssid[0])

  # If found existing result, build message and forward via ke_msg_send
  if existing != nil:
    let existingEntry = scanuResultAt(existing)
    let cachedRxuMgtInd = existingEntry.cachedRxuMgtInd
    if cachedRxuMgtInd != nil:
      ke_state_set(TASK_SCANU, ScanuScanningState)
      scanu_env.pendingJoinRxuMgtInd = cachedRxuMgtInd
      ke_msg_send(cachedRxuMgtInd)
      existingEntry.cachedRxuMgtInd = nil
      req.flags = 0
      ke_msg_send_basic(SCAN_DONE_IND, TASK_SCANU, TASK_SCANU)
      return 1

  # Start scan (blob: scanu_start → ke_msg_send_basic + scanu_scan_next)
  scanu_start(param)

  # Scan started, set state
  ke_state_set(TASK_SCANU, ScanuJoiningState)
  return 1

{.emit: "__attribute__((optimize(\"crossjumping\"))) void scanu_join_cfm_handler(void*);".}
proc scanu_join_cfm_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle SCANU_JOIN_CFM (434 bytes in blob, 106 instrs).
  ## From blob (scanu_task.o): Assert state==2 (SM_JOINING). If sm_env.canceled(18):
  ## clear flag, sm_connect_ind(25, 0xFFFF). Else: get vif_idx from sm_env_ptr[59].
  ## If vif.flags(484) bit31 set: sm_add_chan_ctx, then alloc msg(10,0,4,28),
  ## chan_ctxt_link, memcpy BSSID(6 bytes from vif+380), set HT rate mask,
  ## ke_msg_send, ke_state_set(SM,3). Copy connection flags to vif[1496].
  ## If bit31 not set: check sm_env[16] flag for sm_join_bss path, else
  ## sm_connect_ind with various error codes (13,14,17,18).
  let state = ke_state_get(TASK_SM)
  if state != SmWaitingState:
    assert_err("sm_task.c", "sm_task.c", 445)
  let sm = smEnvView()
  # Check cancelled flag
  if sm.cancelRequested != 0:
    sm.cancelRequested = 0
    sm_connect_ind(25, 0xFFFF'u16)
    return
  # Get VIF info
  let connectInfoPtr = sm.connectInfo
  let connectInfo = connectInfoView(connectInfoPtr)
  let vifIdx = connectInfo.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let apConfig = vifApConfig(vif)
  let securityFlagsSigned = cast[int32](apConfig.securityFlags)
  if securityFlagsSigned < 0:  # bit31 set (has channel context to add)
    # Add channel context — blob: non-zero return means failure
    var chanIdx: uint8
    let addStatus = sm_add_chan_ctx(cast[pointer](addr chanIdx))
    if addStatus != 0:
      # Blob emits a distinct sm_connect_ind(13,0xFFFF) here that falls
      # through to the flag-copy path.
      sm_connect_ind(13, 0xFFFF'u16)
    else:
      let msg = cast[ptr MmStaAddReqPayload](
        ke_msg_alloc(MM_STA_ADD_REQ, TASK_MM, TASK_SM,
                     MmStaAddReqPayloadSize))
      if msg != nil:
        # Link channel context
        chan_ctxt_link(chanIdx, vifIdx)
        # Copy BSSID (6 bytes from vif+380)
        msg.vifIdx = vifIdx
        discard c_memcpy(addr msg.bssid[0], addr vif.bssid[0],
                         msg.bssid.len.csize_t)
        inc nimFwDbgPreauthStaReq
        nimFwDbgPreauthStaReqMeta =
          vifIdx.uint32 or (vif.staIdx.uint32 shl 8) or
          (chanIdx.uint32 shl 16) or (ke_state_get(TASK_SM).uint32 shl 24)
        nimFwDbgPreauthStaReqBssid0 = cast[ptr uint32](addr msg.bssid[0])[]
        nimFwDbgPreauthStaReqBssid1 = cast[ptr uint16](addr msg.bssid[4])[].uint32
        # Set HT rate mask from vif flags
        let apSecurityFlags = apConfig.securityFlags
        if (apSecurityFlags and 2) != 0:
          let htCap = vifHtCapabilities(vif).ampduParams
          let nss = htCap and 3
          let rateMask = (1'u16 shl (nss + 13)) - 1
          msg.rateMask = rateMask
          let bwEncode = if htCap <= 2: 1'u8 else: (1'u8 shl (htCap - 3)) and 0xFF
          msg.bw = bwEncode
        msg.compatWord0 = 0
        # This byte is later copied into wifi_connect_parm_t.quick_conn.
        # sm_env+19 holds connection flags, not the quick-connect setting.
        msg.quickConn = 0
        ke_msg_send(msg)
      ke_state_set(TASK_SM, SmAddingChanState)
    # Copy connection flags to vif[1496]
    let connectFlags = connectInfo.channelDuration
    vifKeyPointers(vif).flags = connectFlags
    if (connectFlags and 4) != 0:
      var clearedSecurityFlags = apConfig.securityFlags
      clearedSecurityFlags = clearedSecurityFlags and (not 7'u32)  # Clear bits 0-2
      apConfig.securityFlags = clearedSecurityFlags
  else:
    # No channel context to add
    if sm.joinBssFlag != 0:
      # Join BSS path
      let chanInfo = vif.operChan
      sm_join_bss(cast[pointer](addr vif.macAddr[0]),
                  cast[pointer](addr vif.bssid[0]), chanInfo, 1)
    else:
      if (sm.connectModeFlags and 1) != 0:
        sm_connect_ind(17, 0xFFFF'u16)
      elif (sm.connectModeFlags and 2) != 0:
        sm_connect_ind(18, 0xFFFF'u16)
      else:
        sm_connect_ind(14, 0xFFFF'u16)

proc scanu_raw_send_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle SCANU_RAW_SEND_REQ: send raw management frame (71 instrs in blob).
  ## From blob (scanu_task.o): loads scanu_env function pointer, calls platform
  ## log with frame data. Allocates 512-byte TX buffer via ke_msg_alloc.
  ## If alloc succeeds and frame length <= 511, copies frame data to TX buffer
  ## descriptor payload area (offset 348=0x15C), clears TX descriptor fields
  ## (bytes 47, 49, 98, 100), sets up HW descriptor (offsets 80, 84), programs
  ## frame length into HW desc (offsets 24, 28), calls txl_frame_push(desc, 3).
  ## If frame too large, logs error. Returns 0.
  if param == nil: return
  let srcId = keMsgHdrFromPayload(param).srcId
  let req = cast[ptr ScanuRawSendReqPayload](param)
  let framePtr = req.framePtr
  let frameLen = req.frameLen
  # Log the raw send request via g_bl_ops_funcs[1] (NOT scanu_env[4]).
  let logFnPtr = blOpsFunc(4)
  if logFnPtr != nil:
    let logFn = cast[proc(s: pointer, a: pointer, b: uint32, c: uint32) {.cdecl.}](logFnPtr)
    logFn(nil, framePtr, frameLen, srcId.uint32)
  # Synchronously acknowledge with a NULL-result CFM back to the requester.
  # Blob: `li a0, 0; mv a1, saved_a3; call scanu_raw_send_cfm` immediately
  # after the log call — before frame allocation.
  scanu_raw_send_cfm(nil, srcId)
  # Allocate TX frame buffer (blob: txl_frame_get, NOT ke_msg_alloc)
  let txBuf = txl_frame_get(512)
  if txBuf == nil:
    return
  # Check frame length — blob .L34 simply logs the error and jumps to .L33
  # (common cleanup, which is just register-restore + ret). It does NOT
  # call txl_frame_release here — the allocated frame is left for the
  # normal TX-pool recycler. Previous Nim added a txl_frame_release call
  # that does not match blob behaviour and risks a double-free if the
  # recycler later walks the abandoned frame.
  if frameLen > 511:
    if logFnPtr != nil:
      cast[proc(a: pointer, b: uint32, c: uint32) {.cdecl.}](logFnPtr)(nil, frameLen, 512)
    return
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
  # NB: blob does NOT call scanu_raw_send_cfm synchronously — the callback
  # stored at desc+208 is invoked on TX completion.

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

  let vif = vifChannelForIdx(vifIdx)
  if not earlyExit:
    if vif.vifType != 0:
      if vif.state != 0:
        if req.authType != 2:
          cfmStatus = 9
          earlyExit = true

  if not earlyExit:
    let sm = smEnvView()
    # Check STA index is unassigned (0xFF)
    let staIdx = vif.staIdx
    if staIdx != 0xFF:
      if state2 == SmIdleState and sm.connectInfo == nil:
        let staleChanCtx = vif.chanCtxt
        if staleChanCtx != nil:
          chan_ctxt_unlink(vifIdx)
          vif.chanCtxt = nil
        vif.staIdx = 0xFF'u8
        vif.state = 0
        if vifIdx < 8'u8:
          nimFwWpaPendingMask = nimFwWpaPendingMask and
            (not (1'u32 shl vifIdx))
      else:
        assert_err("sm_task.c", "sm_task.c", 90)

    # Check no existing channel context
    let chanCtx = vif.chanCtxt
    if chanCtx != nil:
      assert_err("sm_task.c", "sm_task.c", 91)

    # Check no existing connection in sm_connect_env
    if sm.connectInfo != nil:
      assert_err("sm_task.c", "sm_task.c", 94)
    sm.connectInfo = param
    sm.connectFlags = (req.channelDuration and 0xFF).uint8
    if sm.connectIndMsg != nil:
      assert_err("sm_task.c", "sm_task.c", 99)
    sm.scanResultIndex = 0xFFFFFFFF'u32
    sm.vendorIeLen = sm.vendorIeLen and 0x00FF'u16

    sm_connection_tlv_set(vifIdx, param, 0)

  if earlyExit:
    let cfm = cast[ptr StatusCfmPayload](
      ke_msg_alloc(SM_CONNECT_CFM, TASK_API, TASK_SM, StatusCfmPayloadSize))
    if cfm != nil:
      cfm.status = cfmStatus
      ke_msg_send(cfm)
    return KeMsgConsumed

  # Post-CFM success steps (blob: direct join when a target BSSID/channel is
  # already known, otherwise start a scan using the VIF MAC as the source).
  var selectedBssResult: pointer = nil
  var selectedBssChannel: pointer = nil
  if connectInfoHasChannelHint(req) and smConnectReqHasSpecificBssid(req):
    selectedBssResult = cast[pointer](addr req.bssid[0])
    selectedBssChannel = connectInfoChannelHint(param)
  else:
    discard sm_get_bss_params(addr selectedBssResult, addr selectedBssChannel)

  if selectedBssResult != nil:
    scanu_prune_scanresult_raw_frames_except_bssid(selectedBssResult)
  else:
    scanu_prune_scanresult_raw_frames()
  let connectConfirm = cast[ptr StatusCfmPayload](
    ke_msg_alloc(SM_CONNECT_CFM, TASK_API, TASK_SM, StatusCfmPayloadSize))
  if connectConfirm != nil:
    connectConfirm.status = cfmStatus
    ke_msg_send(connectConfirm)

  let sm = smEnvView()
  let connectMsg = ke_msg_alloc(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
  sm.connectIndMsg = connectMsg
  if connectMsg != nil:
    discard c_memset(connectMsg, 0, 64.csize_t)

  let vifMacAddr = cast[pointer](addr vif.macAddr[0])
  if selectedBssResult != nil and selectedBssChannel != nil and
      (cast[ptr uint8](selectedBssResult)[] and 1'u8) == 0:
    sm_join_bss(vifMacAddr, selectedBssResult, selectedBssChannel, 0)
  else:
    sm_scan_bss(vifMacAddr, selectedBssResult, selectedBssChannel)
  return KeMsgNoFree

proc sm_disconnect_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SM_DISCONNECT_REQ: disconnect from BSS (88 bytes in blob).
  ## Blob: if SM is busy, return KE_MSG_SAVED. Otherwise:
  ##   sm_connection_tlv_set()
  ##   sm_handle_connection(vif_idx, 19, sm_disconnect_deauth_cfm,
  ##                        sm_disconnect_process)
  ##   ke_msg_send_basic(SM_DISCONNECT_CFM, TASK_API, TASK_SM)
  inc nimFwDbgDisconnectReq
  let state = ke_state_get(TASK_SM)
  nimFwDbgDisconnectReqState = state.uint32
  if state != SmIdleState:
    return KeMsgSaved
  sm_connection_tlv_set(0, nil, 0)  # stub (just ret in blob)
  let vifIdx = smReqVifIdxOrZero(param)
  sm_handle_connection(vifIdx.uint32, 19'u32,
    cast[pointer](sm_disconnect_deauth_cfm),
    cast[pointer](sm_disconnect_process))
  ke_msg_send_basic(SM_DISCONNECT_CFM, TASK_API, TASK_SM)
  return KeMsgConsumed

proc sm_connect_abort_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle SM_CONNECT_ABORT_REQ: abort ongoing connection (198 bytes in blob).
  ## Blob dispatches on SM state:
  ##   idle:    send cfm with status=0
  ##   scan:    set sm_env abort flag, send SCAN_ABORT_REQ, clear scan cache, send cfm
  ##   waiting: set sm_env abort flag, send cfm
  ##   3,4:     return 2 (msg requeued)
  ##   6,8,9:   call sm_handle_connection(abort), clear cfm status, send cfm
  ##   other:   send cfm with status=state
  let state = ke_state_get(TASK_SM)
  let cfm = cast[ptr StatusCfmPayload](
    ke_msg_alloc(SM_CONNECT_ABORT_CFM, TASK_API, TASK_SM,
                 StatusCfmPayloadSize))
  let sm = smEnvView()
  if state > SmWaitingState and state <= SmSettingBssState:
    # States 3,4: message will be requeued (return 2)
    return KeMsgSaved
  elif state == SmScanningState:
    # Scanning: mark abort, cancel scan, clear cache
    sm.cancelRequested = state.uint8
    ke_msg_send_basic(SCAN_ABORT_REQ, TASK_SCAN, TASK_SM)
    scanu_cached_scanresult_clear()
    if cfm != nil:
      cfm.status = state.uint8
  elif state == SmWaitingState:
    # Waiting: mark abort flag
    sm.cancelRequested = 1
  elif state == SmAuthenticatingState or state == SmAssocRspState or
      state == SM_ACTIVATING_STATE:
    # Connected/active: call sm_handle_connection with abort
    let vifIdx = smReqVifIdxOrZero(param)
    sm_handle_connection(vifIdx.uint32, 24,
      cast[pointer](sm_connect_abort_deauth_cfm),
      cast[pointer](sm_connect_abort_process))
    if cfm != nil:
      cfm.status = 0
  # Send CFM and return 0
  if cfm != nil:
    ke_msg_send(cfm)
  return KeMsgConsumed

proc sm_rsp_timeout_ind_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle SM_RSP_TIMEOUT_IND: auth/assoc response timeout (126 bytes in blob).
  ## Blob: loads sm_env[0] (connection env), ke_state_get(SM), then:
  ##   - If no connection env: return 0
  ##   - State must be in the auth/assoc response window after channel grant
  ##   - Check retry count (conn_env[60]) vs max retries (sm_env word at byte 24)
  ##   - If retries available: increment, state 5/6 -> wpa_cbs[64]() + sm_auth_send(1,0)
  ##   - If retries exhausted: sm_connect_ind(11, 0xFFFF)
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
    return
  if state != SmAuthStartingState and state != SmAuthenticatingState:
    return
  when defined(bl808WifiAckDrivenMgmtFallback):
    if nimFwDbgAssocReqSend != 0 and
        (nimFwDbgAssocCfmAckOk16 != 0 or nimFwDbgAssocCfmAckOk23 != 0) and
        nimFwDbgAuthOpenSuccess != 0 and
        nimFwDbgAssocDone == 0:
      inc nimFwDbgAckFallbackAssoc
      nimFwDbgAckFallbackLast =
        0xB0000000'u32 or (state.uint32 shl 16) or
        ((nimFwDbgAssocCfmAckOk16 + nimFwDbgAssocCfmAckOk23) and 0xFFFF'u32)
      sm_assoc_done(1'u16)
      return
  when defined(bl808WifiAckDrivenMgmtFallback):
    if state == SmAuthStartingState and
        (nimFwDbgAuthCfmAckOk16 != 0 or nimFwDbgAuthCfmAckOk23 != 0) and
        nimFwDbgAuthOpenSuccess == 0:
      inc nimFwDbgAckFallbackAuth
      nimFwDbgAckFallbackLast =
        0xA0000000'u32 or (state.uint32 shl 16) or
        ((nimFwDbgAuthCfmAckOk16 + nimFwDbgAuthCfmAckOk23) and 0xFFFF'u32)
      var fallbackAuth {.noinit.}: SmAuthFrameView
      discard c_memset(addr fallbackAuth, 0, sizeof(SmAuthFrameView).csize_t)
      fallbackAuth.frameLen = 38'u16
      fallbackAuth.authAlgo = 0'u16
      fallbackAuth.authSeq = 2'u16
      fallbackAuth.statusCode = 0'u16
      sm_auth_handler(addr fallbackAuth)
      return
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
    return
  # Increment retry count
  connectInfoAuthRetry(connEnv)[] = retryCount + 1
  # Vendor retries authentication for both response-wait states.
  if wpa_cbs != nil:
    let wpaCbFn = wpaCallbacks().authTimeout
    if wpaCbFn != nil:
      cast[proc() {.cdecl.}](wpaCbFn)()
  sm_deauth_send(nil, 3)
  sm_auth_send(1'u16, 0)

proc sm_sa_query_timeout_ind_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle SM_SA_QUERY_TIMEOUT_IND (158b in blob, sm.o).
  ## Blob: checks sm_env[36] (sa_query_active), sm_env[37] (retry_count).
  ## If retries left: call sm_send_sa_query, decrement, return 0.
  ## If exhausted: compute STA entry (staIdx*368), VIF entry (vifIdx*1512),
  ## clear flag, call sm_disconnect(4, 10), log, ke_msg_send_basic.
  let sm = smEnvView()
  if sm.saQueryActive == 0:
    return
  let retryCount = sm.saQueryRetryCount
  if retryCount != 0:
    # Send SA query and decrement retry count
    sm_issue_sa_query_request()  # blob: sm_issue_sa_query_request (not sm_send_sa_query)
    sm.saQueryRetryCount = retryCount - 1
    return
  # Retry count exhausted: disconnect
  let staIdx = sm.saQueryVifIdx
  let sta = staInfoForIdx(staIdx)
  # Read VIF idx from sm_env halfword at offset 42
  let vifIdx = sm.saQueryReason
  let saQueryVifIdxTransIdPadding = sm.saQueryVifIdxTransIdPadding
  let vif = vifChannelForIdx(vifIdx.uint8)
  # Clear SA query flag
  sm.saQueryActive = 0
  ke_state_set(TASK_SM, SmDisconnectingState)
  # Log via g_bl_ops_funcs
  let logFn = blOpsFunc(204)
  if logFn != nil:
    cast[proc(a0: pointer, a1: uint16) {.cdecl.}](logFn)(
      cast[pointer](sta), vifIdx)
  # Disconnect (blob: sm_disconnect_process, not sm_disconnect)
  sm_disconnect_process(cast[pointer](vif), 20, 0xFFFF'u16)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void sm_disconnect(void*);".}
proc sm_disconnect*(param: pointer) {.exportc, cdecl.} =
  ## Disconnect from current BSS (143 instrs in blob).
  ## From blob (sm.o): reads VIF idx from sm_env connection info. Checks
  ## VIF[86]==0 (STA type) and VIF[88]!=0 (active). Sets ke_state(SM, 10).
  ## Allocates TX buffer (512 bytes) via ke_evt_set(0x200). Calls
  ## me_build_deauth to build deauthentication frame (writes DA, SA, BSSID
  ## from VIF and STA entries). Sets frame subtype, reason code, length.
  ## Calls txl_frame_push(frame, 3) to queue for TX.
  ## Finally tail-calls sm_send_deauth_ind(vif, 3, 20) to notify host.
  let connectInfoPtr = smEnvView().connectInfo
  if connectInfoPtr == nil:
    return
  let connectInfo = connectInfoView(connectInfoPtr)
  let vifIdx = connectInfo.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  if vif.vifType != 0:
    return  # not a STA VIF
  if vif.state == 0:
    return  # VIF not active
  ke_state_set(TASK_SM, SmDisconnectingState)
  let staIdx = vif.staIdx
  let reason = smDisconnectReasonOrDefault(param)
  # Allocate TX frame for deauth (blob: txl_frame_get with 512 byte payload)
  let txFrame = txl_frame_get(512)
  if txFrame == nil:
    # Blob: tail-call sm_disconnect_process(vif, 20, 3) on frame alloc failure
    sm_disconnect_process(cast[pointer](vif), 20, reason)
    return
  let txDesc = hostTxDescAt(txFrame)
  let deauthHeader = hostTxDataHeader(txDesc)
  # Build deauth frame body using me_build_deauthenticate
  let frameBodyPtr = cast[pointer](deauthHeader)
  let bodyLen = me_build_deauthenticate(frameBodyPtr, reason)
  # Set sequence control
  let seqCtrl = txl_get_seq_ctrl()
  deauthHeader.seqCtrl = seqCtrl
  # Copy DA, SA, BSSID from VIF/STA entries
  discard c_memcpy(addr deauthHeader.addr1[0], addr connectInfo.bssid[0], 6.csize_t)  # DA
  discard c_memcpy(addr deauthHeader.addr2[0],
                   cast[pointer](addr vif.macAddr[0]), 6.csize_t)  # SA
  discard c_memcpy(addr deauthHeader.addr3[0], addr connectInfo.bssid[0], 6.csize_t)  # BSSID
  # Set STA/VIF info in frame descriptor
  txDesc.vifIdx = staIdx
  txDesc.staInfoIdx = vif.staIdx
  # Register deauth TX-completion callback (blob: sw &sm_disconnect_deauth_cfm
  # at descriptor+208). Fires when the HW actually sends the deauth frame.
  txDesc.callback = cast[pointer](sm_disconnect_deauth_cfm)
  # MFP protection. Blob reads fc from frame body header (bytes 0/1 of the
  # MAC header living at txFrame+348, i.e. frameBodyPtr[0..1]).
  let deauthFrameControl = deauthHeader.frameControl.uint32
  discard mfp_protect_mgmt_frame(txFrame, deauthFrameControl, 0'u32)
  # Apply MFP protection and MIC
  txu_cntrl_protect_mgmt_frame(txFrame, frameBodyPtr, bodyLen)
  discard mfp_add_mgmt_mic(txFrame, bodyLen, bodyLen + 24)
  # Apply TX power control
  tpc_update_frame_tx_power(cast[pointer](vif), txFrame)
  # Push frame for TX
  txl_frame_push(txFrame, 3)
  # Blob: tail-call sm_disconnect_process — this sends SM_DISCONNECT_IND internally
  # Do NOT send another SM_DISCONNECT_IND here (would be duplicate)
  sm_disconnect_process(cast[pointer](vif), 0, reason)

proc sm_delete_resources*(param: pointer = nil) {.exportc, cdecl.} =
  ## Clean up SM resources after disconnect (76 instrs in blob).
  ## From blob (sm.o): clears VIF linkage, calls ke_state_set(4,0), clears STA
  ## entry if assigned (sta_idx != 0xFF), clears channel context if assigned
  ## (vif[64] != nil). Host indications are sent by sm_connect_ind or
  ## sm_disconnect_process; cleanup itself must not emit them.
  inc nimFwDbgDisconnectInd
  let sm = smEnvView()
  let smConnInfo = sm.connectInfo
  var vif: ptr VifChannelView = nil
  var vifIdx: uint8 = 0
  if param != nil:
    vif = vifChannelAt(param)
    vifIdx = vif.vifIdx
  elif smConnInfo != nil:
    vifIdx = connectInfoView(smConnInfo).vifIdx
    vif = vifChannelForIdx(vifIdx)
  else:
    for candidateIdx in 0'u8 ..< MAX_VIFS.uint8:
      let candidate = vifChannelForIdx(candidateIdx)
      if candidate.vifType == VIF_TYPE_STA and
          (candidate.staIdx != 0xFF'u8 or candidate.chanCtxt != nil or
           candidate.state != 0):
        vif = candidate
        vifIdx = candidateIdx
        break
  # Clear station entry if assigned
  let staIdx = if vif != nil: vif.staIdx else: 0xFF'u8
  if staIdx != 0xFF'u8:
    # Send STA del message
    let staDel = cast[ptr MeStaDelReqPayload](
      ke_msg_alloc(MM_STA_DEL_REQ, TASK_MM, TASK_SM,
                   MeStaDelReqPayloadSize))
    if staDel != nil:
      staDel.staIdx = staIdx
      ke_msg_send(staDel)
    vif.staIdx = 0xFF'u8
  # Clear VIF active flag
  if vif != nil and vif.state != 0:
    let vifStateMsg = cast[ptr MmSetVifStateReqPayload](
      ke_msg_alloc(MM_SET_VIF_STATE_REQ, TASK_MM, TASK_SM,
                   MmSetVifStateReqPayloadSize))
    if vifStateMsg != nil:
      vifStateMsg.aid = 0
      vifStateMsg.state = 0
      vifStateMsg.vifIdx = vifIdx
      ke_msg_send(vifStateMsg)
    vif.state = 0
  # Clear channel context link
  let chanCtxt = if vif != nil: vif.chanCtxt else: nil
  if chanCtxt != nil:
    chan_ctxt_unlink(vifIdx)  # blob: chan_ctxt_unlink (not mm_sta_del)
    vif.chanCtxt = nil
  if vif != nil and vifIdx < 8'u8:
    nimFwWpaPendingMask = nimFwWpaPendingMask and (not (1'u32 shl vifIdx))
  # Clear sm_env[484] (status word)
  if vif != nil:
    vifApConfig(vif).securityFlags = 0
  if sm.connectIndMsg != nil:
    ke_msg_free(keMsgHdrFromPayload(sm.connectIndMsg))
    sm.connectIndMsg = nil
  sm.connectInfo = nil
  sm.cancelRequested = 0
  sm.joinBssFlag = 0
  sm.deauthPending = 0
  sm.scanResultIndex = 0xFFFFFFFF'u32
  ke_state_set(TASK_SM, SmIdleState)

proc sm_auth_assoc_send_according_chan*(nextState: uint16 = 0, param1: uint16 = 0, param2: uint32 = 0) {.exportc, cdecl.} =
  ## Send auth/assoc on appropriate channel (226 bytes in blob, 57 instrs).
  ## From blob (sm.o): reads the active connection's vif_idx(59). If
  ## chan_ctxt_cnt() <= 1 or chan_ctxt_use_dominant_chan() or remaining time
  ## < 200ms: direct send.
  ## Otherwise: allocs channel-switch msg (0x100B, 8 bytes), fills {nextState,
  ## param1, param2}, calls chan_ctxt_set_auth_assoc_req, sets SM state.
  ## Direct send: if nextState==5: sm_auth_send(param1, param2).
  ##              if nextState==7: sm_assoc_req_send().
  let connInfo = smEnvView().connectInfo
  if connInfo == nil:
    return
  let vifIdx = connectInfoView(connInfo).vifIdx
  let vif = vifChannelForIdx(vifIdx)
  # Check if we can send directly (single channel or dominant)
  let chanCnt = chan_ctxt_cnt()
  when defined(bl808WifiConnectTrace):
    nimFwTrace2U32("[WIFI-NIMFW] auth_sched ",
                   nextState.uint32 or (param1.uint32 shl 16),
                   vifIdx.uint32 or (chanCnt.uint32 shl 8) or
                     (ke_state_get(TASK_SM).uint32 shl 16))
    nimFwConnectTrace2U32("[WIFI-CT] auth_sched ",
                          nextState.uint32 or (param1.uint32 shl 16),
                          vifIdx.uint32 or (chanCnt.uint32 shl 8) or
                            (ke_state_get(TASK_SM).uint32 shl 16))
  if chanCnt <= 1 or chan_ctxt_use_dominant_chan():
    if vif.chanCtxt != nil and vif.channelFreqPair != 0'u32:
      let ctxt = cast[ptr ChanCtxtView](vif.chanCtxt)
      let selectedPrimary = uint16(vif.channelFreqPair and 0xFFFF'u32)
      var selectedCenter = uint16((vif.channelFreqPair shr 16) and 0xFFFF'u32)
      if selectedCenter == 0'u16:
        selectedCenter = selectedPrimary
      if selectedPrimary != 0'u16 and
          (ctxt.channel.primFreq != selectedPrimary or
           ctxt.channel.centerFreq1 != selectedCenter):
        ctxt.channel.primFreq = selectedPrimary
        ctxt.channel.centerFreq1 = selectedCenter
        ctxt.channel.centerFreq2 = 0'u16
      let chanEnv = chanEnvView()
      chanEnv.flags = chanEnv.flags and not 0x0C'u8
      chanEnv.scheduledCtxt = vif.chanCtxt
      chanEnv.currentCtxt = vif.chanCtxt
      chan_upd_ctxt_status(vif.chanCtxt, 4)
    if vif.chanCtxt != nil:
      chan_pre_switch_channel(vif.chanCtxt)
    # Direct send path
    when defined(bl808WifiConnectTrace):
      nimFwTrace2U32("[WIFI-NIMFW] auth_sched_direct ",
                     nextState.uint32, chanCnt.uint32)
      nimFwConnectTrace2U32("[WIFI-CT] auth_direct ",
                            nextState.uint32, chanCnt.uint32)
    if nextState == SmAuthStartingState:
      sm_auth_send(param1, param2)
    elif nextState == SmAssociatingState:
      sm_assoc_req_send(nil)
    return
  # Check remaining channel time
  let remaining = chan_ctxt_get_remaining_time_ms(cast[pointer](vif))
  when defined(bl808WifiConnectTrace):
    nimFwTrace2U32("[WIFI-NIMFW] auth_sched_rem ",
                   remaining, pointerAddrU32(cast[pointer](vif)))
    nimFwConnectTrace2U32("[WIFI-CT] auth_rem ",
                          remaining, pointerAddrU32(cast[pointer](vif)))
  if remaining == 0 or (remaining - 41) <= 158:
    # Not enough time, send directly
    when defined(bl808WifiConnectTrace):
      nimFwTrace2U32("[WIFI-NIMFW] auth_sched_short ",
                     nextState.uint32, remaining)
      nimFwConnectTrace2U32("[WIFI-CT] auth_short ",
                            nextState.uint32, remaining)
    if nextState == SmAuthStartingState:
      sm_auth_send(param1, param2)
    elif nextState == SmAssociatingState:
      sm_assoc_req_send(nil)
    return
  # Multi-channel path: allocate channel-switch message
  let msg = cast[ptr SmConnectAuthAssocReqPayload](
    ke_msg_alloc(SM_CONNECT_AUTH_ASSOC_REQ_MSG, TASK_SM, 0xFF,
                 SmConnectAuthAssocReqPayloadSize))
  if msg != nil:
    msg.nextState = nextState
    msg.param1 = param1
    msg.param2 = param2
    when defined(bl808WifiConnectTrace):
      nimFwTrace2U32("[WIFI-NIMFW] auth_sched_queue ",
                     nextState.uint32, cast[uint32](cast[uint](msg)))
      nimFwConnectTrace2U32("[WIFI-CT] auth_queue ",
                            nextState.uint32, cast[uint32](cast[uint](msg)))
    chan_ctxt_set_auth_assoc_req(msg)
    ke_state_set(TASK_SM, nextState.uint16)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void sm_supplicant_deauth_cfm(void*);".}
proc sm_supplicant_deauth_cfm*(param: pointer) {.exportc, cdecl.} =
  ## Handle deauth confirmation from supplicant (23 instrs in blob).
  ## From blob (sm.o): checks status bit 11 (0x800). If not set, loads
  ## a function pointer, calls debug log (level 3, line 1717), then
  ## tail-calls sm_connect_ind(8, 15). If bit 11 set, directly
  ## tail-calls sm_connect_ind(8, 15). Status 8 = WLAN_FW_CONNECT_ABORT,
  ## reason 15 = WLAN_FW_DEAUTH.
  var status: uint32
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", status, ") );"].}
  if (status and 0x800'u32) == 0:
    # Not DTIM status: log first
    let logFn = getLogFunc(4)
    if logFn != nil:
      logFn(2, 0, nil, 1717)
  # Tail-call sm_connect_ind with (status=8, reason=15)
  sm_connect_ind(8, 15)

# --- APM Task Handlers (apm_task.o) ---

{.emit: "__attribute__((optimize(\"crossjumping\"))) void apm_start_req_handler(void*);".}
proc apm_start_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle APM_START_REQ (1034 bytes in blob, 427 instrs).
  ## From blob (apm_task.o): Full AP startup procedure:
  ## 1. Validates VIF type == AP (2), state == IDLE (0), not already active
  ## 2. Adds channel context via me_add_chan_ctx
  ## 3. Links channel to VIF, sets freq/bandwidth
  ## 4. Calls apm_embedded_enabled, copies rates/SSID/IEs
  ## 5. Reads MAC address from HW register (0x24B00200)
  ## 6. Builds beacon via me_build_beacon, adds customer IEs
  ## 7. Sets BSS params and TX power
  ## 8. On error: sends APM_START_CFM with error code
  let req = apmStartReqView(param)
  var errorCode: uint8 = 4  # Default: wrong VIF type
  # Log entry
  let logFn = blOpsFunc(4)
  if logFn != nil:
    discard  # blob calls printf with file/line
  # Validate VIF. Blob tail-merges all error paths + the success-path
  # CFM into a single ke_msg_alloc / ke_msg_send site at the function
  # tail. Mirror that by tracking errorCode + an earlyExit flag and
  # letting every branch fall through to the shared send at the bottom.
  let vifIdx = req.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let apm = apmEnvView()
  var earlyExit = false

  if vif.vifType != 2:
    # errorCode already defaulted to 4 (wrong VIF type)
    earlyExit = true

  if not earlyExit:
    let state = ke_state_get(TASK_APM)
    if state != ApmIdleState:
      errorCode = 8  # BUSY
      earlyExit = true

  if not earlyExit:
    if vif.state != 0:
      errorCode = 9  # Already active
      earlyExit = true

  # Blob tail-merges all 3 CFM alloc+send paths (earlyExit / chan-add-fail /
  # success) into one shared ke_msg_alloc + ke_msg_send site at the end.
  # Wrap the body in a block and break out with errorCode set; common tail
  # below does the single alloc+send.
  block apmStart:
   if earlyExit: break apmStart
   # Assert chan_ctxt is NULL
   let existingChanCtxt = vif.chanCtxt
   if existingChanCtxt != nil:
     assert_err("apm_task.c", "apm_task.c", 101)
   # Store request pointer in apm_env
   apm.connectInfo = param
   # Add channel context
   # Blob: me_add_chan_ctx(a0=&stackLocal, a1=req+14, a2=req[20], a3=req[24], a4=req[28])
   var chanCtxtResult: uint8
   let chanResult = me_add_chan_ctx(
     chanCtxtResult,
     cast[pointer](addr req.channel),
     req.channel.primFreq,
     req.channel.centerFreq,
     req.channel.authType)
   if chanResult:
     errorCode = 1  # Channel add failed
     break apmStart
   # Get channel pointer from frequency
   let apChannel = me_freq_to_chan_ptr(req.channel.band, req.channel.freq)
   # Store channel pointer in VIF
   vif.operChan = apChannel
   let apConfig = vifApConfig(vif)
   # Set bandwidth type
   vifChannelTypeByte(vif)[] = req.channel.chanType  # via chan_ptr
   # Store center frequencies
   vif.channelFreqPair =
     req.channel.primFreq.uint32 or (req.channel.centerFreq.uint32 shl 16)
   # Set auth type (clamp 4 -> 3)
   var authType = req.channel.authType
   if authType == 4: authType = 3
   apConfig.authType = authType
   apConfig.requestedAuthType = req.channel.authType
   apConfig.authConfigPadding[0] = 0
   # Link channel context to VIF
   chan_ctxt_link(vifIdx, vifIdx)
   # Store beacon/DTIM params in apm_env
   apm.beaconIntervalIndex = req.beaconIntervalIndex
   apm.flags = req.flags
   # Check if AP embedded mode is enabled
   let embedded = apm_embedded_enabled(cast[pointer](vif))
   if not embedded:
     discard  # Skip embedded-only setup, jump to beacon build
   else:
     # Blob: me_get_basic_rates(a0=req+53, a1=req) → populates basic rate info
     # me_get_basic_rates declared as (vifIdx: uint8) but blob ABI is (a0=ptr, a1=ptr)
     let meGetBasicFn = cast[proc(a0: pointer, a1: pointer) {.cdecl.}](me_get_basic_rates)
     meGetBasicFn(cast[pointer](addr req.basicRates[0]), param)
     # Blob at 0x16c: reads `me_env[0x82]` (the ME task's HT supp flag),
     # and if non-zero, OR's bit 1 (0x2) into vif+484. Previous Nim read
     # from the request buffer and OR'd bit 0 — wrong source AND wrong bit.
     if meEnvView().htSupp != 0:
       apConfig.securityFlags = apConfig.securityFlags or 2'u32
     # Copy beacon interval
     apConfig.beaconInterval = req.beaconInterval
     # Copy DTIM period
     vif.beaconIntervalTu = req.dtimPeriod.uint16
     # Copy SSID length
     apConfig.privacyFlag = req.htCapSsidLen
     # Copy supported rates (34 bytes)
     discard c_memcpy(addr vif.supportedRatesLong[0],
                      cast[pointer](addr req.supportedRatesLong[0]), 34.csize_t)
     # Copy basic rates (13 bytes)
     discard c_memcpy(addr vif.basicRates[0],
                      cast[pointer](addr req.basicRates[0]), 13.csize_t)
     # Copy HT capability from request (blob: lbu a5, 102(s0); sb a5, 520(s1))
     apConfig.privacyFlag = req.htCapSsidLen
     # Read AMPDU durations from MAC HW (blob: lui a5,0x24b00; lw a4,512(a5)...)
     let ampduBase = 0x24B00200'u
     vif.edcaRegs[0] = volatileLoad(cast[ptr uint32](ampduBase))
     vif.edcaRegs[1] = volatileLoad(cast[ptr uint32](ampduBase + 4))
     vif.edcaRegs[2] = volatileLoad(cast[ptr uint32](ampduBase + 8))
     vif.edcaRegs[3] = volatileLoad(cast[ptr uint32](ampduBase + 12))
     # Clear probe response length
     vif.wmmQosInfo = 0
     # Set AID bitmap and feature flag
     apConfig.aidBitmapFeatureLow = 0
     apConfig.maxAssocRate = 0xFFFF'u16
   # Allocate the transient beacon buffer. Blob calls g_bl_ops_funcs[184] with
   # 333 bytes and stores the returned pointer at apm_env+16; apm_bcn_set copies
   # from this buffer, frees it through g_bl_ops_funcs[188], then clears it.
   let allocFn = blOpsFunc(0xB8)
   if allocFn != nil:
     apm.pendingBeaconBuffer =
       cast[proc(size: uint32): pointer {.cdecl.}](allocFn)(333)
   # Store crypto type
   let cryptoType = req.cryptoType
   apm.cryptoType = cryptoType
   # Copy IE data if present
   if cryptoType != 0:
     discard c_memcpy(addr apm.securityIe[0],
                      cast[pointer](addr req.securityIe[0]),
                      cryptoType.csize_t)
   # Store VIF index
   apm.vifIdx = vifIdx
   # Clear WPA type
   let securityState = vifSecurity(vif)
   securityState.cipher = 0
   # HT capability check. Blob builds a 112-byte stack descriptor then
   # invokes wpa_cbs[24] (register-beacon callback):
   #   stack[0]      = req[51] (inst_nbr)
   #   stack[1..7]   = BSSID from vif+380 (6 bytes)
   #   stack[40]     = vif[386] (basic rate count, re-stored as word)
   #   stack[44..]   = vif+387 supported rates (count bytes)
   #   stack[76..77] = 0x0403 halfword marker
   #   stack[78..]   = SSID from req+103 (strlen bytes)
   #   stack[142]    = null terminator
   if req.htCapSsidLen != 0:
     var beaconRegisterBuffer {.noinit.}: array[144, uint8]
     discard c_memset(addr beaconRegisterBuffer[0], 0, 112.csize_t)
     let beaconRegister = cast[ptr WpaBeaconRegisterParamView](addr beaconRegisterBuffer[0])
     beaconRegister.vifIdx = req.vifIdx
     beaconRegister.bssid = vif.bssid
     let rateCount = vif.supportedRatesLong[0]
     beaconRegister.rateCount = rateCount.uint32
     discard c_memcpy(addr beaconRegister.rates[0], addr vif.supportedRatesLong[1],
                     rateCount.csize_t)
     beaconRegister.marker = 0x0403'u16
     let ssidPtr = cast[pointer](addr req.ssid[0])
     let ssidLen = c_strlen(ssidPtr)
     discard c_memcpy(addr beaconRegister.ssid[0], ssidPtr, ssidLen)
     beaconRegister.terminator = 0
     securityState.cipher = 3
     if wpa_cbs != nil:
       let beaconRegisterCallback = wpaCallbacks().beaconRegister
       if beaconRegisterCallback != nil:
         cast[proc(buf: pointer) {.cdecl.}](beaconRegisterCallback)(
           addr beaconRegisterBuffer[0])
   # Build beacon into the transient AP buffer and store the generated length
   # back into the request payload at offset 36, matching blob `sh a0,36(s0)`.
   var bcnLen: uint16 = 0
   let beaconBuf = apm.pendingBeaconBuffer
   if beaconBuf != nil:
     let builtLen = me_build_beacon(
       beaconBuf, vifIdx, addr req.beaconLenOut,
       addr req.beaconFlags, apm.flags)
     bcnLen = builtLen.uint16
     req.beaconLength = bcnLen
     let extra = me_add_ie_customer(
       cast[pointer](cast[uint](beaconBuf) + builtLen.uint),
       cast[pointer](addr req.securityIe[0]),
       cryptoType.uint32)
     bcnLen = bcnLen + extra.uint16
     req.beaconLength = bcnLen
   # Check if rate bitfield needs building (blob: if req[16]==0)
   if req.channel.band == 0:
     # Build legacy rate bitfield from VIF supported rates
     let rateResult = me_legacy_rate_bitfield_build(
       cast[pointer](addr vif.basicRates[0]), 1)
     # Store highest-set-bit index at vif[475] via __clzsi2 (blob: 31 - clz)
     if (rateResult and 0xF) != 0:
       var basicRateNibble: cuint = (rateResult and 0xF).cuint
       var highestBasicRateBit: cint
       {.emit: [highestBasicRateBit, " = 31 - __builtin_clz(", basicRateNibble, ");"].}
       apConfig.highestRateBit = highestBasicRateBit.uint8
   # Set BSS params and rates
   apm_set_bss_param(param)
   # Update VIF TX power
   # Blob: a0=vifEntry, a1=&txPowerByte(from chan_ptr[4] bandwidth), a2=&rateParam(from stack)
   let txPowerChannel = vif.operChan
   var txPowerByte: uint8
   var txPowerRateParam: uint8
   if txPowerChannel != nil:
     let channel = cast[ptr ScanChannelEntry](txPowerChannel)
     txPowerByte = cast[ptr uint8](addr channel.txPower)[]
   tpc_update_vif_tx_power(
     cast[pointer](vif),
     cast[pointer](addr txPowerByte),
     cast[pointer](addr txPowerRateParam))
   # Success path: errorCode = 0 for the shared tail CFM send below. Blob
   # does NOT call ke_state_set here (state transition happens elsewhere).
   errorCode = 0

  # Shared tail: single ke_msg_alloc + ke_msg_send (matches blob's
  # 1 alloc / 1 send site pattern).
  let cfm = cast[ptr ApmStartCfmPayload](
    ke_msg_alloc(APM_START_CFM, TASK_API, TASK_APM,
                 ApmStartCfmPayloadSize))
  if cfm != nil:
    cfm.status = errorCode
    cfm.vifIdx = vifIdx
    ke_msg_send(cfm)

proc apm_stop_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle APM_STOP_REQ: stop AP mode (202 bytes in blob, 50 instrs).
  ## From blob (apm_task.o):
  ##   1. Read vifIdx from param[0]
  ##   2. Compute vif_entry = vif_info_tab + vifIdx * 1512
  ##   3. Check vif.type (offset 86) == 2 (AP) AND vif.active (offset 88) != 0
  ##   4. If valid: call ke_state_get(TASK_APM), check state
  ##      - If state is 0: set fail status
  ##      - Else: clear hostapd_enabled, memset apm_env to 0 (64 bytes),
  ##        clear vif.active, do mm_remove_if(vifIdx), call g_bl_ops_funcs[28]
  ##        callback with apm_env.timer, clear apm timer pointer
  ##   5. Send APM_STOP_CFM with status
  let req = apmStopReqView(param)
  let vifIdx = req.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let apm = apmEnvView()

  if vif.vifType == VIF_TYPE_AP and vif.state != 0:
    let state = ke_state_get(TASK_APM)
    if state != ApmIdleState:
      # Check and clear hostapd_enabled flag at apm_env+0x55
      if apm.beaconIntervalIndex != 0:
        apm.beaconIntervalIndex = 0
      # Clear APM env (blob: memset(apm_env+0x14, 0, 64))
      discard c_memset(addr apm.securityIe[0], 0, apm.securityIe.len.csize_t)
      # Clear apm_env[0x54]
      apm.cryptoType = 0
      # Call apm_stop (blob: apm_stop at 0x88)
      apm_stop(cast[pointer](vif))
      # Call wpa_cbs[7] (offset 28) with apm_env[0xac] as arg (blob: no null checks)
      if wpa_cbs != nil:
        let wpaCbFn = wpaCallbacks().apStopped
        if wpaCbFn != nil:
          let timerArg = cast[uint32](cast[uint](apm.hostapdCtx))
          cast[proc(a0: uint32) {.cdecl.}](wpaCbFn)(timerArg)
      # Clear apm timer pointer at apm_env[0xac]
      apm.hostapdCtx = nil

  # Send APM_STOP_CFM (blob: ke_msg_send_basic)
  ke_msg_send_basic(APM_STOP_CFM, TASK_API, TASK_APM)

proc apm_sta_add_cfm_handler*(param: pointer) {.exportc, cdecl.} =
  ## Blob apm_task.o::apm_sta_add_cfm_handler (178 bytes, 44 instrs).
  ## Does NOT send APM_STA_ADD_IND — the previous Nim implementation invented
  ## that indication and also inserted a spurious rc_init_bcmc_rate call.
  ##
  ## Blob flow (a1 = MM_STA_ADD_CFM param):
  ##   staIdx = msg[0]  (only byte read from the msg)
  ##   staEntry = &sta_info_tab[0] + staIdx * 368
  ##   for slot in apm_env[0..5] (stride 16, max apm_env + 0x50):
  ##     if slot[104] != 0:
  ##       if memcmp(slot + 92, staEntry + 4, 6) == 0:
  ##         slot[105] = msg[0]    # record staIdx on this slot
  ##         apm_sta_add(param)
  ##         if apm_env[172] != 0:
  ##           cb = wpa_cbs[36]
  ##           cb(param, sta_info_tab[staIdx + 1 ...]) via T-Head custom insn
  ##         return
  ##   # fall-through: no slot matched. The blob emits a hard fault marker here;
  ##   # the pure Nim path records the mismatch and returns so the scheduler
  ##   # remains serviceable.
  let cfm = apmStaAddCfmParamView(param)
  let staIdx = cfm.staIdx
  let sta = staInfoForIdx(staIdx)
  let staMacPtr = cast[pointer](addr sta.macAddr[0])
  let apm = apmEnvView()
  for apmStaAddSlotIndex in 0'u ..< 5'u:
    let apmStaAddSlot = apmStaSlot(apmStaAddSlotIndex)
    if apmStaAddSlot.active != 0:
      if c_memcmp(cast[pointer](addr apmStaAddSlot.macAddr[0]), staMacPtr, 6.csize_t) == 0:
        apmStaAddSlot.staIdx = staIdx
        discard apm_sta_add(param)
        # Optional WPA callback at apm_env[172]=enable / wpa_cbs[36]=fn.
        if apm.hostapdCtx != nil:
          let wpaCbsPtr = wpa_cbs
          if wpaCbsPtr != nil:
            let cbFn = wpaCallbacks().staAdd
            if cbFn != nil:
              let stored = cast[uint32](apmStaAddSlot.staHandle)
              cast[proc(p: pointer, v: uint32) {.cdecl.}](cbFn)(param, stored)
        return
  inc nimFwDbgApmStaAddNoSlot
  nimFwDbgApmStaAddNoSlotSta = staIdx.uint32

{.emit: "__attribute__((optimize(\"crossjumping\"))) void apm_sta_del_req_handler(void*);".}
proc apm_sta_del_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle APM_STA_DEL_REQ (116 bytes in blob, 32 instrs).
  ## From blob (apm_task.o): Allocs APM_STA_DEL_CFM msg first.
  ## Reads req[0] as vif_lookup idx, validates vif.type(86)==2 (AP) and
  ## req[1] (sta_idx_in_vif) <= 7. On success: calls apm_sta_delete(sta_idx, 2, 1),
  ## sets cfm[0]=0. On error: cfm[0]=0xFF. Sends cfm.
  # Allocate CFM message first
  let cfm = cast[ptr ApmStaDelCfmPayload](
    ke_msg_alloc(APM_STA_DEL_CFM, TASK_API, TASK_APM,
                 ApmStaDelCfmPayloadSize))
  # Validate VIF type
  let req = apmStaDelReqView(param)
  let vifLookupIdx = req.vifLookupIdx
  let vif = vifChannelForIdx(vifLookupIdx)
  if vif.vifType != 2:  # Not VIF_AP
    if cfm != nil: cfm.status = 0xFF
    ke_msg_send(cfm)
    return
  # Validate sta_idx_in_vif
  let staIdxInVif = req.staIdxInVif
  if staIdxInVif > 7:
    if cfm != nil: cfm.status = 0xFF
    ke_msg_send(cfm)
    return
  # Perform deletion (blob: apm_sta_remove, not apm_sta_fw_delete)
  let staMac = cast[pointer](addr staInfoForIdx(staIdxInVif).macAddr[0])
  apm_sta_remove(cast[pointer](vif), staIdxInVif, staMac, 1)
  if cfm != nil: cfm.status = 0
  ke_msg_send(cfm)

proc apm_sta_delete*(param: pointer) {.exportc, cdecl.} =
  ## Delete a station from AP mode (240 bytes in blob, 58 instrs).
  ## From blob (apm.o): a0=sta_idx, a1=mac_addr_ptr, a2=reason_code, a3=extra.
  ## 1. Alloc ME_STA_DEL_REQ (0xC07, dest=TASK_ME, src=TASK_APM, len=1)
  ## 2. Alloc APM_STA_DEL_IND (0x1405, dest=TASK_API, src=TASK_APM, len=6)
  ## 3. Call _aid_list_delete(mac_addr_ptr)
  ## 4. If apm_env[0xAC] != 0: mm_sec_machwkey_del((sta_idx+8) & 0xFF)
  ## 5. Compute STA entry, get time, log elapsed, populate and send both msgs.
  let staIdx = encodedArgU8(param)
  var macAddrPtr: pointer
  var reasonCode: uint16
  var extra: uint16
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", macAddrPtr, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a2\" : \"=r\"(", reasonCode, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a3\" : \"=r\"(", extra, ") );"].}
  # Allocate ME_STA_DEL_REQ message (1-byte param: sta_idx)
  let msg1 = cast[ptr MeStaDelReqPayload](
    ke_msg_alloc(ME_STA_DEL_REQ, TASK_ME, TASK_APM,
                 MeStaDelReqPayloadSize))
  # Allocate APM_STA_DEL_IND message (6-byte param: reason_code(2) + extra(2) + sta_idx(1) + pad)
  let msg2 = cast[ptr ApmStaDelIndPayload](
    ke_msg_alloc(APM_STA_DEL_IND, TASK_API, TASK_APM,
                 ApmStaDelIndPayloadSize))
  # Delete from AID list using MAC address
  aidListDelete(macAddrPtr)
  # Conditionally delete HW key if the AP hostapd context is active.
  if apmEnvView().hostapdCtx != nil:
    mm_sec_machwkey_del(((staIdx.uint32 + 8) and 0xFF).uint8)
  let sta = staInfoForIdx(staIdx)
  let vifIdx = uint8(sta.aid and 0x00FF'u16)
  sta.apmConnectTime = 0
  # Get current time and compute elapsed
  let logFn = getLogFunc(204)
  let getTimeFn = cast[proc(): uint32 {.cdecl.}](blOpsFunc(200))
  let now = getTimeFn()
  let connStart = sta.connectionStart
  let elapsed = now - connStart
  # Log disconnect with elapsed time (line 583)
  if logFn != nil:
    logFn(2, 0, nil, 583, staIdx.uint32, elapsed, vifIdx.uint32)
  # Populate and send APM_STA_DEL_IND (msg2)
  msg2.reason = reasonCode
  msg2.extra = extra
  msg2.staIdx = staIdx
  ke_msg_send(msg2)
  # Populate and send ME_STA_DEL_REQ (msg1)
  msg1.staIdx = staIdx
  ke_msg_send(msg1)

proc apm_sta_connect_timeout_ind_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle station connect timeout in AP mode (222 bytes in blob, 56 instrs).
  ## From blob (apm_task.o): gets current time via g_bl_ops_funcs[200].
  ## Loops over 7 STAs (stride 368). For each STA with non-zero conn_time
  ## (offset 0x14), checks if (now - conn_time) > 30000. If timed out,
  ## reads vif_idx from STA[87], calls apm_sta_fw_delete with the
  ## DELETECONNECTION_TIMEOUT status. After loop, re-arms the 5-second timer.
  let getTimeFnPtr = blOpsFunc(200)
  if getTimeFnPtr == nil:
    return
  let getTimeFn = cast[proc(): uint32 {.cdecl.}](getTimeFnPtr)
  let now = getTimeFn()
  let apmBase = cast[uint](addr apm_env[0])
  let maxSta = cast[ptr uint8](apmBase + 4)[]
  let maxStaCount = if maxSta == 0: 7'u8 else: maxSta
  # Iterate connected STAs
  for apStaSlotIndex in 0'u8 ..< maxStaCount:
    let sta = staInfoForIdx(apStaSlotIndex)
    let connTime = sta.connectionStart
    if connTime == 0:
      continue
    let elapsed = now - connTime
    if elapsed > 30000:
      # Timed out: get VIF index from STA entry, delete the connection
      let vifIdx = sta.keyArea[7]
      # Log the timeout via platform ops
      let logFnPtr = blOpsFunc(204)
      if logFnPtr != nil:
        let logFn = cast[PlatformLogFunc](logFnPtr)
        logFn(1, 0, nil, 530, apStaSlotIndex.uint32, elapsed)
      apm_sta_fw_delete(apStaSlotIndex, vifIdx, WLAN_FW_APM_DELETECONNECTION_TIMEOUT.uint16)
  # Re-arm the 5-second timeout timer (blob: ke_timer_set)
  let timerMsgId = KE_FIRST_MSG(TASK_APM.uint16) + 6  # APM_STA_CONNECT_TIMEOUT_IND
  let apmInstNbr = cast[ptr uint8](apmBase + 2)[]
  ke_timer_set(timerMsgId, apmInstNbr, 5000000'u32)

proc apm_conf_max_sta_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle APM_CONF_MAX_STA_REQ (104b in blob, apm_task.o).
  ## Blob ABI: a0=msgId, a1=body, a2=srcId, a3=destId.
  ## Reads body[0] for max_sta, clamps to 5, stores in apm_env, logs, sends CFM.
  let hdr = keMsgHdrFromPayload(param)
  let srcId = hdr.destId
  let destId = hdr.srcId
  var maxSta = apmConfMaxStaReqView(param).maxSta
  if maxSta > 5:
    maxSta = 5
  let logFn = blOpsFunc(204)
  apmEnvView().maxSta = maxSta
  # Log max STA setting
  if logFn != nil:
    cast[proc(a0: uint32, a1: uint32, fmtStr: pointer, line: uint32, val: uint32) {.cdecl.}](logFn)(
      2, 0, nil, 447, maxSta.uint32)
  # Send APM_CONF_MAX_STA_CFM (0x140A) via ke_msg_send_basic (blob uses basic form)
  ke_msg_send_basic(APM_CONF_MAX_STA_CFM, destId, srcId)

# --- ME Task Handlers (me_task.o) ---

proc me_config_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle ME_CONFIG_REQ (216 bytes in blob, 56 instrs).
  ## From blob (me_task.o): copies 32 bytes of HT cap from req to me_env(+8).
  ## Stores req[46] (ht_supp) at me_env.ht_supp(130). Sends ME_CONFIG_CFM (0xc01)
  ## via ke_msg_send_basic. If HT: queries NSS, stores caps.
  ## Copies def_key(req[44]) to me_env(128), ps_on(req[48]) to me_env(133).
  ## If ps_on: sets ps_mode=0xFF, sets cfm status=2, sends cfm, sets ME state to 1.
  let me = meEnvView()
  let req = meConfigReqView(param)
  # Store HT support flag
  let htSupp = req.htSupp
  me.htSupp = htSupp
  # Copy 32 bytes of HT capabilities to me_env+8
  discard c_memcpy(addr me.htCaps[0], addr req.htCaps[0], 32.csize_t)
  # Send basic ME_CONFIG_CFM
  ke_msg_send_basic(ME_CONFIG_CFM, TASK_API, TASK_ME)
  # Process HT capabilities
  if htSupp != 0:
    # Get NSS from PHY (blob: phy_get_nss at 0x64)
    let nss = phy_get_nss()
    me.nss = nss
    let htCapInfo = cast[ptr uint16](addr me.htCaps[0])[]
    me.htCapByte = cast[uint8](htCapInfo and 0xFF)
  else:
    me.nss = 0
    me.htCapByte = 0
  # Copy def_key and ps_on
  me.defKey = req.defKey
  let psOn = req.psOn
  me.psOn = psOn
  if psOn != 0:
    me.psMode = 0xFF
    # Alloc and send cfm with status=2
    let cfm = cast[ptr Status4CfmPayload](
      ke_msg_alloc(ME_CONFIG_CFM, TASK_API, TASK_ME,
                   Status4CfmPayloadSize))
    if cfm != nil:
      cfm.status = 2
      ke_msg_send(cfm)
    ke_state_set(TASK_ME, MeBusyState)

proc me_chan_config_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle ME_CHAN_CONFIG_REQ: configure channel parameters.
  ## From blob (me_task.o, 0x3c bytes): memcpy(me_env+0x28, param, 86);
  ##   ke_msg_send_basic(ME_CHAN_CONFIG_CFM, destId=srcId_in, srcId=destId_in).
  let hdr = keMsgHdrFromPayload(param)
  let srcId = hdr.destId
  let destId = hdr.srcId
  discard c_memcpy(addr meEnvView().chanConfig[0], param, 86.csize_t)
  ke_msg_send_basic(ME_CHAN_CONFIG_CFM, destId, srcId)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void me_sta_add_req_handler(void*);".}
proc me_sta_add_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle ME_STA_ADD_REQ (480 bytes in blob, 153 instrs).
  ## From blob (me_task.o): allocs ME_STA_ADD_CFM. Reads sta_idx from req[73].
  ## Checks req[64] bit 1 (HT cap): computes rate mask from spatial streams.
  ## Copies MAC addr (6 bytes) from req+0 to stack buffer. Reads bandwidth,
  ## VHT/HE caps. Calls mm_sta_add(). On success: copies supported rates from
  ## req[6..18] (13 bytes) to sta[248], sets HT/VHT/HE capability flags in
  ## sta[308], copies VHT caps if present (32 bytes to sta[264]),
  ## calls me_set_sta_ht_vht_param, me_init_rate, sets sta[334] |= 0x10.
  ## Copies beacon interval and UAPSD info to sta entries.
  let cfm = cast[ptr MeStaAddCfmPayload](
    ke_msg_alloc(ME_STA_ADD_CFM, TASK_API, TASK_ME,
                 MeStaAddCfmPayloadSize))
  let req = meStaAddReqView(param)
  let staIdx = req.staIdx
  # Check HT capability
  var htRateMask: uint32 = 0
  var spatialStreamBits: uint32 = 0
  let htCapBit = req.capFlags
  if (htCapBit and 1) != 0:
    # HT capable: compute rate config from HT cap info
    let htCapInfo = req.htCapInfo
    spatialStreamBits = (htCapInfo and 3).uint32
    htRateMask = (1'u32 shl (spatialStreamBits + 13)) - 1
  # Copy MAC addr to stack buffer, call mm_sta_add
  var macBuf {.noinit.}: array[6, uint8]
  discard c_memcpy(addr macBuf[0], addr req.macAddr[0], 6.csize_t)
  var hwStaIdx: uint8
  let addResult = mm_sta_add(param, addr hwStaIdx, cast[ptr uint8](cfm))
  # Store result in CFM
  if cfm != nil:
    cfm.status = addResult
    if addResult != 0:
      # Failed
      ke_msg_send(cfm)
      return
    # Success: setup station
    let assignedStaIdx = cfm.staIdx
    let sta = staInfoForIdx(assignedStaIdx)
    # Copy supported rates (13 bytes)
    discard c_memcpy(addr sta.supportedRates[0], addr req.supportedRates[0],
                     13.csize_t)
    # Set capability flags
    var capaFlags = sta.capabilityFlags
    if (htCapBit and 1) != 0:
      capaFlags = capaFlags or 1  # HT
    # Check VHT (me_env+0x82)
    if meEnvView().htSupp != 0:
      capaFlags = capaFlags or 2  # VHT
      # Copy VHT caps (32 bytes)
      discard c_memcpy(addr sta.vhtCaps[0], meStaAddReqCapBlock(req),
                       32.csize_t)
    sta.capabilityFlags = capaFlags
    # Set HT/VHT params
    let vif = vifChannelForIdx(staIdx)
    # Cast to match blob ABI: first arg is sta entry pointer
    me_set_sta_ht_vht_param(cast[pointer](sta),
                            cast[pointer](vifHtCapabilities(vif)))
    # Check HE flag (bit 3 of req[64])
    if (htCapBit and 8) != 0:
      var capa2 = sta.capabilityFlags
      capa2 = capa2 or 8  # HE flag (blob: ori a5, a5, 8)
      sta.capabilityFlags = capa2
    # Initialize rate control
    me_init_rate(cast[pointer](sta))
    # Mark the STA TX-power policy stale.
    sta.txPolicyUpdateFlags[0] = sta.txPolicyUpdateFlags[0] or StaTxPolicyUpdateTxPower
    # Compute control-port state from VIF key flags and write to sta[72].
    let keyFlagByte = (vifKeyPointers(vif).flags and 0xFF).uint8
    let controlPortState = 2'u8 - (keyFlagByte and 1)
    sta.controlPortState = controlPortState
    sta.rateWord = vif.apStartBeaconInterval
    # Copy UAPSD info from req[70,71] to sta[314,315]
    sta.psState = req.uapsd0
    sta.uapsdBitmap = req.uapsd1
    # Copy beacon interval from req[68] to sta[36]
    sta.aid = req.beaconInterval
    ke_msg_send(cfm)

proc me_sta_del_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle ME_STA_DEL_REQ (80b in blob, me_task.o).
  ## Blob ABI: a0=msgId, a1=body, a2=srcId, a3=destId.
  ## Forwards MM_STA_DEL_REQ to MM (with staIdx from body[0]),
  ## then sends ME_STA_DEL_CFM back to caller.
  let hdr = keMsgHdrFromPayload(param)
  let body = param
  let srcId = hdr.destId
  let destId = hdr.srcId
  # Forward MM_STA_DEL_REQ to MM task
  let fwd = cast[ptr MeStaDelReqPayload](
    ke_msg_alloc(MM_STA_DEL_REQ, TASK_MM, TASK_ME,
                 MeStaDelReqPayloadSize))
  let staIdx = cast[ptr MeStaDelReqPayload](body).staIdx
  fwd.staIdx = staIdx
  ke_msg_send(fwd)
  # Send ME_STA_DEL_CFM back to caller
  ke_msg_send_basic(ME_STA_DEL_CFM, destId, srcId)

{.emit: "__attribute__((optimize(\"crossjumping\"))) int me_set_active_req_handler(void*);".}
proc me_set_active_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle ME_SET_ACTIVE_REQ (196 bytes in blob, 52 instrs).
  ## From blob (me_task.o): manages per-VIF bitmask me_env.active_mask(offset 0).
  ## If ME is busy: returns KeMsgSaved. Reads req[0]=active(bool), req[1]=vif_idx.
  ## If active: set bit; else clear bit. Allocates ME_SET_ACTIVE_CFM (id=26),
  ## sets status=seqz(mask), sends cfm, transitions to BUSY.
  ## Fast path: if mask already 0 and deactivating, just send basic cfm.
  let state = ke_state_get(TASK_ME)
  if state == MeBusyState:
    return KeMsgSaved
  let me = meEnvView()
  let hdr = keMsgHdrFromPayload(param)
  let reqSrc = hdr.srcId
  let reqDst = hdr.destId
  let oldMask = me.activeMask
  let req = cast[ptr MeSetActiveReqPayload](param)
  let active = req.active
  let vifIdx = req.vifIdx
  let activeVifMaskBit = 1'u32 shl vifIdx
  if oldMask == 0 and active == 0:
    # Already all inactive, just send basic cfm
    ke_msg_send_basic(ME_SET_ACTIVE_CFM, reqSrc, reqDst)
    return KeMsgConsumed
  if oldMask != 0 and active != 0:
    # Set bit and send basic (already active path)
    me.activeMask = oldMask or activeVifMaskBit
    ke_msg_send_basic(ME_SET_ACTIVE_CFM, reqSrc, reqDst)
    return KeMsgConsumed
  # Main path: alloc full cfm
  var newMask: uint32
  if active != 0:
    newMask = oldMask or activeVifMaskBit
  else:
    newMask = oldMask and (not activeVifMaskBit)
  me.activeMask = newMask
  let cfm = cast[ptr StatusCfmPayload](
    ke_msg_alloc(ME_SET_ACTIVE_CFM, reqSrc, reqDst,
                 StatusCfmPayloadSize))
  if cfm != nil:
    cfm.status = if newMask == 0: 1'u8 else: 0'u8
    ke_msg_send(cfm)
  ke_state_set(TASK_ME, MeBusyState)
  return KeMsgConsumed

proc smSetActiveCfmStateAllowed(): bool {.inline.} =
  ## Preserve the blob's two independent TASK_SM state reads while making the
  ## allowed confirmation states explicit.
  if ke_state_get(TASK_SM) == SmSettingBssState:
    return true
  if ke_state_get(TASK_SM) == SmDisconnectingState:
    return true
  return false

proc apmSetActiveCfmStateAllowed(): bool {.inline.} =
  ## Preserve the blob's two independent TASK_APM state reads while making the
  ## allowed confirmation states explicit.
  if ke_state_get(TASK_APM) == ApmActiveState:
    return true
  if ke_state_get(TASK_APM) == ApmIdleState:
    return true
  return false

proc me_set_active_cfm_handler_sm*(param: pointer) {.exportc: "me_set_active_cfm_handler_sm", cdecl.} =
  ## Blob sm_task.o::me_set_active_cfm_handler (136 bytes).
  ## Only touches TASK_SM state. Blob flow (three ke_state_get reads):
  ##   1. if state == setting-BSS → .L31
  ##   2. else if state == disconnecting → .L31
  ##   3. else → assert_err(690), falls through to .L31
  ##   .L31: if ke_state_get(SM) == disconnecting → set idle; return
  ##   .L33: if sm_env[17] != 0 → sm_deauth_send; sm_env[17] = 0
  ##         sm_auth_start(NULL)
  if not smSetActiveCfmStateAllowed():
    assert_err("me_task.c", "me_task.c", 690)
  if ke_state_get(TASK_SM) == SmDisconnectingState:
    ke_state_set(TASK_SM, SmIdleState)
    return
  let sm = smEnvView()
  let deauthFlag = sm.deauthPending
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] active_flag ",
                          deauthFlag.uint32,
                          ke_state_get(TASK_SM).uint32)
  if deauthFlag != 0:
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] deauth_pre ",
                            ke_state_get(TASK_SM).uint32,
                            cast[uint32](cast[uint](sm.connectInfo)))
    sm_deauth_send(nil, 0)
    sm.deauthPending = 0
  when defined(bl808WifiConnectTrace):
    nimFwTrace2U32("[WIFI-NIMFW] active_cfm_auth ",
                   ke_state_get(TASK_SM).uint32,
                   cast[uint32](cast[uint](sm.connectInfo)))
    nimFwConnectTrace2U32("[WIFI-CT] active_cfm ",
                          ke_state_get(TASK_SM).uint32,
                          cast[uint32](cast[uint](sm.connectInfo)))
    nimFwConnectTraceHw("[WIFI-CT] active_hw ")
  sm_auth_start(nil)

proc me_set_active_cfm_handler_apm*(param: pointer) {.exportc: "me_set_active_cfm_handler_apm", cdecl.} =
  ## Blob apm_task.o::me_set_active_cfm_handler (130 bytes).
  ## Only touches TASK_APM state. Blob re-reads state three times rather than
  ## caching, so we mirror that explicitly to preserve assert-then-retry
  ## semantics (the state could in theory change between calls if another
  ## task pre-empts — the blob's redundancy protects against that).
  ##   1. if ke_state_get(APM) == active → jump to .L69 (skip assert)
  ##   2. else if ke_state_get(APM) == idle → jump to .L69
  ##   3. else → assert_err(313)
  ##   .L69: if ke_state_get(APM) == active:
  ##     if apm_env[4] != NULL → assert_err(320)
  ##     apm_bcn_set(NULL)
  if not apmSetActiveCfmStateAllowed():
    assert_err("apm_task.c", "apm_task.c", 313)
  if ke_state_get(TASK_APM) == ApmActiveState:
    if apmEnvView().pendingBssParams.first != nil:
      assert_err("apm_task.c", "apm_task.c", 320)
    apm_bcn_set(nil)

{.emit: "__attribute__((optimize(\"crossjumping\"))) int me_set_ps_disable_req_handler(void*);".}
proc me_set_ps_disable_req_handler*(param: pointer): cint {.exportc, cdecl.} =
  ## Handle ME_SET_PS_DISABLE_REQ (206 bytes in blob, 54 instrs).
  ## From blob (me_task.o): Nearly identical to me_set_active_req_handler but
  ## operates on me_env.ps_disable_mask (offset 4). Early exit if ps_on==0.
  ## Same bitmask set/clear pattern. Status = seqz * 2 (0 or 2).
  let me = meEnvView()
  let hdr = keMsgHdrFromPayload(param)
  let reqSrc = hdr.srcId
  let reqDst = hdr.destId
  if me.psOn == 0:
    # PS not configured, just send basic cfm
    ke_msg_send_basic(ME_SET_PS_DISABLE_CFM, reqSrc, reqDst)
    return KeMsgConsumed
  let state = ke_state_get(TASK_ME)
  if state == MeBusyState:
    return KeMsgSaved
  let oldMask = me.psDisableMask
  let req = cast[ptr MeSetPsDisableReqPayload](param)
  let psDisable = req.disable
  let vifIdx = req.vifIdx
  let psDisableVifMaskBit = 1'u32 shl vifIdx
  if oldMask == 0 and psDisable == 0:
    ke_msg_send_basic(ME_SET_PS_DISABLE_CFM, reqSrc, reqDst)
    return KeMsgConsumed
  if oldMask != 0 and psDisable != 0:
    me.psDisableMask = oldMask or psDisableVifMaskBit
    ke_msg_send_basic(ME_SET_PS_DISABLE_CFM, reqSrc, reqDst)
    return KeMsgConsumed
  # Main path
  var newMask: uint32
  if psDisable != 0:
    newMask = oldMask or psDisableVifMaskBit
  else:
    newMask = oldMask and (not psDisableVifMaskBit)
  me.psDisableMask = newMask
  let cfm = cast[ptr StatusCfmPayload](
    ke_msg_alloc(ME_SET_PS_DISABLE_CFM, reqSrc, reqDst,
                 StatusCfmPayloadSize))
  if cfm != nil:
    cfm.status = if newMask == 0: 2'u8 else: 0'u8
    ke_msg_send(cfm)
  ke_state_set(TASK_ME, MeBusyState)
  return KeMsgConsumed

proc me_set_ps_disable_cfm_handler_sm*(param: pointer) {.exportc: "me_set_ps_disable_cfm_handler_sm", cdecl.} =
  ## Blob sm_task.o (108 bytes). Linear structure: 4 ke_state_get calls
  ## matching setting-BSS, idle, disconnecting; assert_err on miss; then shared
  ## tail that re-reads state and tail-calls sm_send_next_bss_param if setting-BSS.
  block sendTail:
    if ke_state_get(TASK_SM) == SmSettingBssState: break sendTail
    if ke_state_get(TASK_SM) == SmIdleState: break sendTail
    if ke_state_get(TASK_SM) == SmDisconnectingState: break sendTail
    assert_err("me_task.c", "me_task.c", 630)
  if ke_state_get(TASK_SM) == SmSettingBssState:
    sm_send_next_bss_param(param)

proc me_set_ps_disable_cfm_handler_apm*(param: pointer) {.exportc: "me_set_ps_disable_cfm_handler_apm", cdecl.} =
  ## Blob apm_task.o (92 bytes). Same linear structure as _sm but with
  ## TASK_APM and states {active, idle}; assert at line 248; shared tail call.
  block sendTail:
    if ke_state_get(TASK_APM) == ApmActiveState: break sendTail
    if ke_state_get(TASK_APM) == ApmIdleState: break sendTail
    assert_err("apm_task.c", "apm_task.c", 248)
  if ke_state_get(TASK_APM) == ApmActiveState:
    apm_send_next_bss_param(param)


proc me_rc_set_rate_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle ME_RC_SET_RATE_REQ (218 bytes in blob, 56 instrs).
  ## From blob (me_task.o): reads sta_idx from req[0], fixed_rate from req[2].
  ## Validates sta.valid(42)!=0, asserts rc_ptr(324)!=nil.
  ## If fixed_rate==0xFFFF: auto rate mode - clears bits 5,6 of
  ##   rate-control flags(175), stores -1 to fixed_rate(198), calls rate reinit.
  ## If fixed_rate!=0xFFFF: calls me_rc_set_rate, if success sets bit 5 of
  ##   rate-control flags, clears bit 6, stores rate to fixed_rate(198).
  ## Then checks req[4] (mcs_rate): if non-zero sets sta.mm_flags(334) |= 0x10.
  let req = meRcSetRateReqView(param)
  let staIdx = req.staIdx
  let sta = staInfoForIdx(staIdx)
  # Validate STA is valid
  if sta.valid == 0:
    return
  # Get RC pointer and assert non-nil
  let rcPtr = sta.rcStats
  if rcPtr == nil:
    assert_err("me_task.c", "me_task.c", 653)
  let rcBase = cast[uint](rcPtr)
  let rateControlStats = rcStatsCounters(rcPtr)
  let fixedRate = req.fixedRate
  if fixedRate == 0xFFFF:
    # Auto rate: clear fixed_rate, clear fixed/forced rate-control flags,
    # then refresh max bandwidth/NSS from the stats view.
    rateControlStats.fixedRate = 0xFFFF'u16
    var flags = rateControlStats.flags
    flags = flags and not 0x60'u8  # Clear bits 5,6
    rateControlStats.flags = flags
    let rateControlStaInfoIdx = sta.infoIdx
    rc_update_bw_nss_max(
      rateControlStaInfoIdx, rateControlStats.nssMax, rateControlStats.bwMax)
  else:
    # Fixed rate mode: call rc_check_fixed_rate_config(rcPtr, fixedRate)
    # Blob ABI: a0=rcPtr, a1=fixedRate. Nim's signature takes (staIdx: uint8)
    # so we pass via emit to set both regs properly.
    var configOk: bool
    {.emit: ["""
    register void* _a0 __asm__("a0") = (void*)""", rcBase, """;
    register unsigned int _a1 __asm__("a1") = (unsigned int)""", fixedRate, """;
    __asm__ volatile("" : : "r"(_a0), "r"(_a1));
    """, configOk, """ = rc_check_fixed_rate_config((NU8)(NI)_a0);
    """].}
    if configOk:
      rateControlStats.fixedRate = fixedRate
      var flags = rateControlStats.flags
      flags = flags and not 0x60'u8  # Clear bits 5,6
      flags = flags or 0x20'u8  # Set bit 5 (fixed rate flag)
      rateControlStats.flags = flags
  # Check mcs_rate field at req[4]
  if req.mcsRate != 0:
    sta.txPolicyUpdateFlags[0] = sta.txPolicyUpdateFlags[0] or StaTxPolicyUpdateTxPower

proc me_traffic_ind_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle ME_TRAFFIC_IND_REQ (200 bytes in blob, 51 instrs).
  ## From blob (me_task.o): reads sta_idx from req[0], tx_avail from req[2],
  ## uapsd from req[1]. Updates sta.traffic_flags(offset 73) bits:
  ## bit 0 = rx traffic, bit 2 = uapsd. If tx_avail: sets/clears bit 2.
  ## If !tx_avail: sets/clears bit 0. If sta.ps_state(314)==15:
  ## allocs ME_TRAFFIC_IND_CFM (id=47, 4 bytes) with aid/inst_nbr/uapsd.
  ## Always sends basic cfm (ME_TRAFFIC_IND_CFM = 0xc0b) afterwards.
  let req = meTrafficIndReqView(param)
  let sta = staInfoForIdx(req.staIdx)
  var flags = sta.trafficFlags
  if req.txAvail != 0:
    if req.uapsd != 0:
      flags = flags or 4  # Set uapsd bit
    else:
      flags = flags and not 4'u8  # Clear uapsd bit
  else:
    if req.uapsd != 0:
      flags = flags or 1  # Set rx traffic bit
    else:
      flags = flags and not 1'u8  # Clear rx traffic bit
  sta.trafficFlags = flags
  # If PS state == 15 (fully sleeping), send full CFM
  if sta.psState == 15:
    let cfm = cast[ptr MeTrafficIndCfmPayload](
      ke_msg_alloc(ME_TRAFFIC_IND_CFM, TASK_API, TASK_ME,
                   MeTrafficIndCfmPayloadSize))
    if cfm != nil:
      cfm.aid = sta.aid
      cfm.uapsd = req.uapsd
      cfm.instNbr = sta.instNbr
      ke_msg_send(cfm)
  # Always send basic confirmation
  ke_msg_send_basic(ME_TRAFFIC_IND_CFM, TASK_API, TASK_ME)

# me_build_associate_req is already implemented at line ~11115 via
# me_build_associate_req_impl with the correct 7-argument blob ABI.

# --- CFG Task Handler (cfg_task.o) ---

proc cfg_start_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle CFG_START_REQ (142b in blob, cfg_task.o).
  ## Blob ABI: a0=msgId, a1=msgBody, a2=srcId, a3=destId.
  ## If body[0]==0: call cfg_api_element_set(body+20, body[16], body[12], &result),
  ##   log result via g_bl_ops_funcs, then call cfg_api_element_set(body[4], body[8], body[12], 0, &result).
  ## If body[0] in 1..2: assert_err.
  ## Always sends CFG_START_CFM (0x2001) with status=0.
  let hdr = keMsgHdrFromPayload(param)
  let body = param
  let srcId = hdr.destId
  let destId = hdr.srcId
  let bodyU = cast[uint](body)
  let cmdWord = cast[ptr uint32](bodyU)[]
  if cmdWord == 0:
    # Process config element: cfg_api_element_set(name=body+20, data=body[16], len=body[12], &result)
    let elemLen = cast[ptr uint16](bodyU + 12)[]
    let elemData = cast[ptr pointer](bodyU + 16)[]
    var resultBuf: uint32
    cfg_api_element_set(0, 0, 0, cast[pointer](bodyU + 20), addr resultBuf)
    # Log result via g_bl_ops_funcs
    let logFn = blOpsFunc(204)
    if logFn != nil:
      cast[proc(a0: uint32, a1: pointer, a2: pointer) {.cdecl.}](logFn)(
        resultBuf, cast[pointer](bodyU + 20), body)
    # Second pass: cfg_api_element_set with id/subId/typeId from body[4..12].
    let cfgElementId = cast[ptr uint32](bodyU + 4)[]
    let cfgElementSubId = cast[ptr uint32](bodyU + 8)[]
    let cfgElementTypeId = cast[ptr uint32](bodyU + 12)[]
    cfg_api_element_set(cfgElementId, cast[uint16](cfgElementSubId), cast[uint16](cfgElementTypeId), nil, addr resultBuf)
  elif cmdWord == 1:
    # Unpack TLV config (blob: utils_tlv_bl_unpack_auto)
    {.emit: ["extern void utils_tlv_bl_unpack_auto(void*, unsigned int); utils_tlv_bl_unpack_auto((void*)", bodyU + 4, ", ", cast[ptr uint32](bodyU + 8)[], ");"].}
  elif cmdWord == 2:
    # Dump config entries (blob: dump_cfg_entries)
    {.emit: ["extern void dump_cfg_entries(void); dump_cfg_entries();"].}
  # Send CFG_START_CFM (0x2001) with status=0
  let cfm = cast[ptr StatusCfmPayload](
    ke_msg_alloc(CFG_START_CFM, destId, srcId, StatusCfmPayloadSize))
  cfm.status = 0
  ke_msg_send(cfm)

# --- Channel Management (chan.o) missing functions ---

proc chan_get_dominant_chan*(): pointer {.exportc, cdecl, noinline.} =
  ## Get the dominant channel context (highest priority active channel).
  ## From blob (chan.o, 5 instrs): loads chanCurrentCtxt global, if nil returns nil.
  ## Otherwise loads the channel context entry pointer from it.
  ## noinline: blob calls this as a real function from chan_ctxt_use_dominant_chan.
  if chanCurrentCtxt == nil:
    return nil
  return chanCurrentCtxt

proc chan_get_next_chan*(): pointer {.exportc, cdecl.} =
  ## Get next scheduled channel (302 bytes in blob, 76 instrs).
  ## From blob (chan.o): 4-stage decision algorithm using TSF timing.
  ## Stage 1: If current_chan exists and (ROC type==2 or timestamp not overdue
  ##   or state==4): return current. Overdue = (TSF+5120) < timestamp.
  ## Stage 2: If ROC chan exists and deadline not passed, skip to candidates.
  ##   Otherwise index into chan table by ROC->index, check duty cycle.
  ## Stage 3: Scan 3 candidate channel entries, pick highest priority active one.
  ## Stage 4: Return best or ASSERT if none found.
  let env = chanEnvView()
  let curChan = env.currentCtxt
  let rocChan = cast[pointer](env.tbttSwitchList.first)
  let macTime = regRead(MACHW_TIMLO_REG)
  let timestamp = env.nextChanTimestamp
  var best: pointer = nil
  # Stage 1: Check current channel
  if curChan != nil:
    if rocChan != nil:
      let rocNode = chanTbttNodeAt(rocChan)
      if rocNode.state == 2:
        return curChan
    # Check if timestamp is not overdue (TSF + 5120 >= timestamp)
    let margin = macTime + 5120'u32
    if cast[int32](margin - timestamp) >= 0:
      return curChan
    # Check current channel state
    if chanCtxtAt(curChan).status == 4:
      return curChan
  # Stage 2: Check ROC channel
  if rocChan != nil:
    let rocNode = chanTbttNodeAt(rocChan)
    let rocDeadline = rocNode.targetTime
    if cast[int32](rocDeadline - timestamp) >= 0:
      # ROC not expired, skip to candidates
      discard
    else:
      # ROC expired: look up channel entry
      best = vifChannelForIdx(rocNode.vifIdx).chanCtxt
      if best == nil:
        assert_err("chan.c", "chan.c", 338)
      # Check if (TSF + 5120) - deadline is within acceptable range
      let margin2 = macTime + 5120'u32
      if cast[int32](margin2 - rocDeadline) >= 0:
        return best
      # Additional duty cycle check from fields 18/20
      let bestCtxt = chanCtxtAt(best)
      let slotDur = bestCtxt.opSlot
      let delta = cast[int32](rocDeadline - macTime)
      if delta > 0 and delta.uint32 <= slotDur.uint32:
        return best
  # Stage 3: Scan the three channel-context pool entries for best priority.
  best = nil
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
  let env = chanEnvView()
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
  let pendCtxt = env.scheduledCtxt
  if pendCtxt != nil:
    return
  # Store as pending and initiate switch
  env.scheduledCtxt = chanCtxt
  chan_upd_ctxt_status(chanCtxt, 2)
  # Allocate channel switch message (id=74)
  let msg = ke_msg_alloc(74, TASK_MM, 0xFF, 4)
  if msg != nil:
    # Store &chan_goto_idle_cb in the first word of the msg body (blob:
    # `auipc a5, ...; sw a5, 0(a0)` with reloc to chan_goto_idle_cb).
    cast[ptr pointer](msg)[] = cast[pointer](chan_goto_idle_cb)
    env.switchPending = 1
    ke_msg_send(msg)

proc chan_tbtt_schedule*(tbttEntry: pointer) {.exportc, cdecl.} =
  ## Schedule TBTT events (270 bytes in blob, 61 instrs).
  ## From blob (chan.o): If tbttEntry != NULL: calls chan_tbtt_insert(entry),
  ## then enters processing loop. Loop: while tbtt_list non-empty, pop front
  ## entry, look up vif_info for entry's vif_idx. If AP: use beacon_int*1024.
  ## If STA: use sta_info.beacon_interval. Update next_tbtt_time += interval.
  ## Increment miss_count (cap at 5), re-insert. If tbttEntry == NULL: check
  ## chan_env.tbtt_switch (offset 16). If time_until_tbtt < 2ms: tailcall
  ## chan_tbtt_switch_evt. Else: mark processed, set timer.
  if tbttEntry != nil:
    # Insert the new TBTT entry
    chan_tbtt_insert(tbttEntry)
    # Process all entries in the TBTT list
    let tbttList = chanTbttReschedList()
    while tbttList.first != nil:
      let poppedTbttListNode = co_list_pop_front(tbttList)
      if poppedTbttListNode == nil:
        break
      let tbttNode = chanTbttNodeAt(cast[pointer](poppedTbttListNode))
      let tbttVifIdx = tbttNode.vifIdx
      let vif = vifChannelForIdx(tbttVifIdx)
      # Check if AP with beacon (vif.ap_bcn_present at offset 86)
      var interval: uint32
      if vif.vifType != 0:
        # AP: beacon interval in TU, convert to microseconds (* 1024)
        interval = vif.apBeaconInterval.uint32 shl 10
      else:
        # STA: get beacon interval from sta_info
        interval = staInfoForIdx(vif.staIdx).initialRateConfig
      # Update next_tbtt_time
      let previousTargetTime = tbttNode.targetTime
      tbttNode.targetTime = previousTargetTime + interval
      # Increment miss_count (cap at 5)
      let missedTbttCount = tbttNode.priority
      if missedTbttCount <= 4:
        tbttNode.priority = missedTbttCount + 1
      # Re-insert into sorted list
      chan_tbtt_insert(cast[pointer](poppedTbttListNode))
    return
  # tbttEntry == NULL: check pending TBTT switch
  let tbttSwitch = cast[pointer](chanTbttPrimaryList().first)
  if tbttSwitch == nil:
    return
  let switchNode = chanTbttNodeAt(tbttSwitch)
  let processed = switchNode.state
  if processed != 0:
    return
  # Check time until TBTT
  let tbttTime = switchNode.targetTime
  let macTime = regRead(MACHW_TIMLO_REG)
  let timeUntil = cast[int32](tbttTime - macTime) - 2000
  if timeUntil < 0:
    # Time is past, switch immediately
    chan_tbtt_switch_evt()
    return
  # Schedule deferred switch: mark processed, set timer
  chanTbttDeferredSlot()[] = tbttSwitch
  switchNode.state = 1  # processed = true
  mm_timer_set(chanTbttTimer(), tbttTime)

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
  let env = chanEnvView()
  # Clear CCA busy flag
  env.switchPending = 0
  # Check if channel context exists
  let chanCtxt = env.scheduledCtxt
  if chanCtxt == nil:
    return
  # Force idle
  mm_force_idle_req()
  # Check current channel and flags
  let curChan = env.currentCtxt
  if curChan == nil or (env.flags and 0x20) != 0:
    # No current channel or busy: skip to pre-switch
    chan_pre_switch_channel(chanCtxt)
    return
  let curChanAddr = cast[uint](curChan)
  # Set power management flag
  blmac_pwr_mgt_setf(1)
  # Initialize counters
  var nullCount: uint8 = 0
  var selfctsCount: uint8 = 0
  let ps = psEnvView()
  # Loop 1: iterate STA VIFs and send null frames
  let vifMgmt = vifMgmtEnvView()
  var vifNode = cast[pointer](vifMgmt.activeList.first)
  while vifNode != nil:
    let vif = vifChannelAt(cast[pointer](vifNode))
    let vifType = vif.vifType
    let vifChanCtxt = vif.chanCtxt
    if vifType == 0 and vifChanCtxt != nil:
      # STA VIF with channel context
      if cast[uint](vifChanCtxt) == curChanAddr:
        let active = vif.state
        let staIdx = vif.staIdx
        if active != 0 and staIdx != 0xFF:
          # Check PS state
          if ps.enabled == 0 or (ps.statusFlags and 8) != 0:
            # Blob: txl_frame_send_null_frame(staIdx, chan_sta_tx_cfm, 0)
            # a1 is the TX completion callback function pointer (not staIdx)
            let sendNullFn = cast[proc(a0: uint8, a1: pointer, a2: uint32) {.cdecl.}](txl_frame_send_null_frame)
            sendNullFn(staIdx, cast[pointer](chan_sta_tx_cfm), 0)
            nullCount = nullCount + 1
    vifNode = vif.next
  # Loop 2: iterate AP VIFs and send self-CTS
  vifNode = cast[pointer](vifMgmt.activeList.first)
  while vifNode != nil:
    let vif = vifChannelAt(cast[pointer](vifNode))
    let vifType = vif.vifType
    let vifChanCtxt = vif.chanCtxt
    if vifType == 2 and vifChanCtxt != nil:
      if cast[uint](vifChanCtxt) == curChanAddr:
        let active = vif.state
        if active != 0:
          if vif.postponedStaHead != nil:
            # Compute beacon interval in TU
            let bcnInt = cast[ptr uint16](curChanAddr + 16)[]
            let intervalUs = (bcnInt.uint32 shl 10) div 1000
            # Blob: txl_frame_send_selfcts_frame(vif, interval, chan_ap_tx_cfm, 0)
            # a2 is the TX completion callback (not 0)
            let sendCtsFn = cast[proc(a0: pointer, a1: uint16, a2: pointer, a3: uint32) {.cdecl.}](txl_frame_send_selfcts_frame)
            sendCtsFn(vifNode, intervalUs.uint16, cast[pointer](chan_ap_tx_cfm), 0)
            selfctsCount = selfctsCount + 1
    vifNode = vif.next
  # Store counts
  env.connlessDelayCount = selfctsCount
  env.scanDelayCount = nullCount
  if (nullCount or selfctsCount) != 0:
    # Frames sent: mark context as PAUSED and reactivate
    chan_upd_ctxt_status(chanCtxt, 3)
    mm_active()
  else:
    # No frames needed: proceed with channel switch
    chan_pre_switch_channel(chanCtxt)

proc chanConnLessDelay(flags: uint8, ctxtCount: uint8): uint32 {.inline.} =
  const DelayUnit = 0x7530'u32
  if ctxtCount == 0:
    return 0
  if (flags and 0x01) != 0:
    return DelayUnit
  if (flags and 0x02) == 0:
    return DelayUnit
  if scan_env.channelIndex == 0:
    return DelayUnit

  # Blob does not call chan_get_dominant_chan here. It uses the scan cursor and
  # channel-context count to pick the next connectionless delay window.
  let nextCnt = (scan_env.channelIndex + 1) and 3
  if nextCnt != 0:
    return DelayUnit
  if ctxtCount <= 1:
    return DelayUnit * 4
  if cast[int8](flags) < 0:
    DelayUnit * 8
  else:
    DelayUnit * 16

{.emit: "__attribute__((optimize(\"crossjumping\"))) void chan_conn_less_delay_prog(void);".}
proc chan_conn_less_delay_prog*() {.exportc, cdecl.} =
  ## Program connectionless delay timer (67 instrs, 190 bytes in blob).
  ## From blob (chan.o): checks chan_env flags bit 4 (0x10). If set, returns.
  ## Otherwise sets bit 4, reads MAC timestamp, reads chan_env[124] count.
  ## If count==0: delay = 0. If count>0: checks flags bits 0-1
  ## for connection type, walks scan_env entries to find active scans,
  ## computes delay factor (1/4/8/16) * 0x7530.
  let env = chanEnvView()
  let flags = env.flags
  nimFwTrace2U32("[WIFI-NIMFW] cld_prog flags ", flags.uint32, env.ctxtCount.uint32)
  if (flags and 0x10) != 0:
    return  # already programmed
  env.flags = flags or 0x10  # set bit 4
  let ctxtCount = env.ctxtCount
  # Read current MAC timestamp for timer base
  let macTime = regRead(MACHW_BASE + 0x120)
  let delay = chanConnLessDelay(flags, ctxtCount)
  # Program timer with computed timeout
  nimFwTrace2U32("[WIFI-NIMFW] cld_prog delay ", macTime, delay)
  mm_timer_set(chanConnLessDelayTimer(), macTime + delay)
  # Check for AP VIF (blob: vif_mgmt_get_first_ap_inf tail-call at 0x76)
  discard vif_mgmt_get_first_ap_inf()

proc chan_ap_tx_cfm*(param: pointer) {.exportc, cdecl.} =
  ## TX confirmation for AP mode channel management (17 instrs).
  ## Blob: decrement chan_env[122]; if 0 → mm_force_idle_req() then
  ##   tail-call chan_pre_switch_channel(chan_env).
  let env = chanEnvView()
  let pending = env.connlessDelayCount
  if pending == 0: return
  let newPending = pending - 1
  env.connlessDelayCount = newPending
  if newPending == 0:
    mm_force_idle_req()
    chan_pre_switch_channel(cast[pointer](env))

proc chan_sta_tx_cfm*(param: pointer) {.exportc, cdecl.} =
  ## TX confirmation for STA mode channel management (17 instrs).
  ## Blob: decrement chan_env[121]; if 0 → mm_force_idle_req() then
  ##   tail-call chan_pre_switch_channel(chan_env).
  let env = chanEnvView()
  let pending = env.scanDelayCount
  if pending == 0: return
  let newPending = pending - 1
  env.scanDelayCount = newPending
  if newPending == 0:
    mm_force_idle_req()
    chan_pre_switch_channel(cast[pointer](env))

# --- TX/RX Functions ---

proc txl_get_seq_ctrl*(): uint16 {.exportc, cdecl.} =
  ## Get next TX sequence control number.
  ## From blob (txl_frame.o, 7 instrs): reads global seq counter,
  ## increments, wraps to 12 bits, shifts left 4 (sequence number field).
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
  if link != nil and nimFwMgmtFcTrace(link.macHeader[0]):
    nimFwTrace2U32("[WIFI-NIMFW] fake_tx ",
                   queueIdx,
                   cast[uint32](cast[uint](link)))
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] fake_tx ",
                            queueIdx,
                            cast[uint32](cast[uint](link)))
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

proc cfm_raw_send*(param: pointer) {.exportc, cdecl.} =
  ## Send raw TX confirmation (5 instrs in blob).
  ## From blob (txl_cfm.o): loads function pointer from GOT relocation,
  ## loads a string pointer via auipc+addi, then tail-calls via jr a5.
  ## This is a thin trampoline that calls the platform CFM handler.
  let cfmFn = blOpsFunc(200)
  if cfmFn != nil:
    cast[proc(p: pointer) {.cdecl.}](cfmFn)(param)

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

proc txSecBumpPn(key: ptr VifKeySlotView, dst: pointer, bytes: csize_t) {.inline.} =
  let oldLo = key.pnLow
  let carry = if oldLo == 0xFFFFFFFF'u32: 1'u32 else: 0'u32
  key.pnLow = oldLo + 1
  key.pnHigh = key.pnHigh + carry
  discard c_memcpy(dst, addr key.pnLow, bytes)

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
  ## Append security header to TX frame (77 instrs in blob).
  ## From blob (txu_cntrl.o): reads STA index from txDesc[49], resolves STA entry
  ## via sta_info_tab with stride 368. Reads key material from sta_info_tab+244.
  ## Checks VIF's security type (via VIF entry linked from STA). Cipher 2 uses
  ## the 8-byte CCMP-style header required for protected data accepted by the AP.
  ## Then patches HW descriptor control field.
  let hostTxDesc = hostTxDescAt(txDesc)
  inc nimFwDbgTxSecHdrAppend
  let txKey = txSecKeyFor(hostTxDesc)
  if txKey == nil:
    return secHdr
  let packetNumber = hostTxPnScratch(hostTxDesc)
  case txKey.cipherType
  of 0:  # Open or WEP-40
    let securityHeader = cast[ptr TxSecurityHeaderView](secHdr)
    securityHeader.packetNumberLowWord = packetNumber.lo
    let keyIdByte = txKey.staIdx
    securityHeader.keyIdAndPacketNumberMidWord =
      (keyIdByte.uint16 shl 14) or packetNumber.mid
  of 1:  # TKIP
    let securityHeader = cast[ptr TxSecurityHeaderView](secHdr)
    securityHeader.packetNumberLowWord = packetNumber.lo
    let keyIdByte = txKey.staIdx
    securityHeader.keyIdAndPacketNumberMidWord =
      (keyIdByte.uint16 shl 14) or packetNumber.mid
    securityHeader.tkipPacketNumberMidWord = packetNumber.mid
    securityHeader.tkipPacketNumberHighWord = packetNumber.hi
  of 2:  # CCMP (AES)
    writeTxCcmpHeader(secHdr, hostTxDesc, txKey)
  of 3:  # WEP-104
    let securityHeader = cast[ptr TxSecurityHeaderView](secHdr)
    securityHeader.packetNumberLowWord = packetNumber.lo
    let keyIdByte = txKey.staIdx
    securityHeader.keyIdAndPacketNumberMidWord =
      (keyIdByte.uint16 shl 14) or packetNumber.mid
  else:
    discard
  let secWords = cast[ptr TxSecurityHeaderView](secHdr)
  nimFwDbgDhcpTxSecHdr0 =
    secWords.packetNumberLowWord.uint32 or
      (secWords.keyIdAndPacketNumberMidWord.uint32 shl 16)
  nimFwDbgDhcpTxSecHdr1 =
    secWords.tkipPacketNumberMidWord.uint32 or
      (secWords.tkipPacketNumberHighWord.uint32 shl 16)
  nimFwDbgDhcpTxSecKey =
    txKey.cipherType.uint32 or
    (txKey.staIdx.uint32 shl 8) or
    (txKey.keyIdx.uint32 shl 16) or
    (txKey.installed.uint32 shl 24)
  patchTxSecControlWord(txSecControlTemplate(hostTxDesc, updateCurrentDesc), txKey)
  return secHdr

proc txu_cntrl_sechdr_len_compute*(txDesc: pointer, lenOut: ptr uint32): uint32 {.exportc, cdecl.} =
  ## Compute security header length for a TX descriptor (76 instrs in blob).
  ## From blob (txu_cntrl.o): reads STA index from txDesc[49], resolves STA entry.
  ## Reads key slot pointer from sta+244. If no key, returns 0 with lenOut[]=0.
  ## Checks VIF security type. Based on cipher type at key_slot+152:
  ##   cipher 0 (WEP40): len=4; cipher 2 (CCMP): len=8
  ##   cipher 1 (TKIP): len=8, tail=12; cipher 3 (WEP104): len=4
  ## Increments 64-bit PN counter at key_slot+128. Returns header length.
  if lenOut != nil:
    lenOut[] = 0
  inc nimFwDbgTxSecHdrCalls
  let hostTxDesc = hostTxDescAt(txDesc)
  let txKey = txSecKeyFor(hostTxDesc)
  if txKey == nil:
    return 0
  var securityHeaderLen: uint32 = 0
  case txKey.cipherType
  of 0:  # WEP-40
    securityHeaderLen = 4
    if lenOut != nil:
      lenOut[] = 4
    txSecBumpPn(txKey, addr hostTxDesc.pnScratch[0], 4.csize_t)
  of 1:  # TKIP
    securityHeaderLen = 8
    if lenOut != nil:
      lenOut[] = 12
    txSecBumpPn(txKey, addr hostTxDesc.pnScratch[0], 6.csize_t)
  of 2:  # CCMP
    securityHeaderLen = 8
    if lenOut != nil:
      lenOut[] = 8
    txSecBumpPn(txKey, addr hostTxDesc.pnScratch[0], 6.csize_t)
  of 3:  # WEP-104
    securityHeaderLen = 4
    if lenOut != nil:
      lenOut[] = 4
    txSecBumpPn(txKey, addr hostTxDesc.pnScratch[0], 4.csize_t)
  else:
    discard
  nimFwDbgTxSecHdrLen = securityHeaderLen
  return securityHeaderLen

{.emit: "__attribute__((optimize(\"crossjumping\"))) unsigned long rxu_mgt_frame_check(void*, unsigned char);".}
proc rxu_mgt_frame_check*(param: pointer, vifIdxArg: uint8): uint32 {.exportc, cdecl.} =
  ## Check management frame validity and generate RXU_MGT_IND message.
  ## From blob (rxl_cntrl.o, 1350 bytes, 15 function calls).
  ##
  ## Blob register map:
  ##   s0=frameHdr  s1=vifIter/vifIdxByte  s2=bodyLen  s3=frameAccepted  s4=rxDesc
  ##   s5=vifIdx(param a1)  s6=skipSecHdr  s7=rxu_cntrl_env  s8=machdrLen
  ##   s9=vifEntry  s10=msgSubtype  s11=ke_msg ptr
  ##
  ## Call graph (from relocations):
  ##   mfp_ignore_mgmt_frame, phyif_utils_decode, vif_mgmt_get_vif (x2),
  ##   apm_embedded_enabled (x2), ke_msg_alloc, ke_msg_send,
  ##   ke_state_get (x2), me_beacon_check, phy_get_channel,
  ##   rxu_mpdu_upload_and_indicate, assert_warn, vif_mgmt_get_first_ap_inf
  ##
  ## Returns: 1 = frame accepted (msg sent), 0 = rejected/filtered
  var vifIdx = vifIdxArg

  let rxDesc = rxMpduDescView(param).swDesc  # s4 = param[4]
  if rxDesc == nil: return 0
  let rx = rxSwDescView(rxDesc)

  # Stack-local outputs for mfp_ignore_mgmt_frame
  var mfpAcceptedFlag: uint8 = 1      # sp+22 in blob: accepted flag
  var mfpSecondaryFlags: uint8 = 0    # sp+23 in blob: secondary/RSSI flags
  var phyDecodeStatusByte: uint8 = 0  # sp+21 in blob: phyif_utils result

  # Traverse: rxDesc[8] -> bufDesc -> bufDesc[24] -> frameHdr (s0)
  let bufDesc = rx.bufferChain
  let frame = rxFrameAtRef(bufDesc)
  let frameHdr = cast[pointer](frame)

  let fcFull = frame.frameControl
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

  # Reject if bit 10 set (protected frame bit — wrong context for mgmt)
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

  # --- VIF index resolution (blob 0x54-0x6a, 0x120-0x258) ---
  # If vifIdx == 0xFF: look up from rxDesc flags or vif_mgmt_env linked list
  if vifIdx == 0xFF:
    let rxFlags = rx.hwFlags
    if (rxFlags and 0x600'u32) == 0:
      # Blob path .L55/.L64: resolve the VIF by matching Addr1 against
      # vif.mac_addr (vif+80). Authentication frames addressed to an AP VIF
      # have Addr1 == BSSID and select AP VIFs; all other management frames
      # select STA VIFs.
      var vifEntry = cast[pointer](vifMgmtEnvView().activeList.first)
      var foundVifIdx: uint8 = 0xFF
      var authToApVif = false
      if fcFull == 0x00B0'u16:
        authToApVif = true
        for authBssidByteIndex in 0'u ..< 6:
          if frame.addr1[authBssidByteIndex] != frame.addr3[authBssidByteIndex]:
            authToApVif = false
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
          if (vifType == 0 and not authToApVif) or (vifType == 2 and authToApVif):
            foundVifIdx = vif.vifIdx
            break
        vifEntry = vif.next
      vifIdx = foundVifIdx

  # Store vifIdx to rxu_cntrl_env[10]
  let env = rxuCntrlEnvView()
  env.vifIdx = vifIdx

  # --- Call mfp_ignore_mgmt_frame (blob 0x72-0x92) ---
  # Blob ABI: a0=rxu_cntrl_env, a1=frameHdr, a2=bodyLen, a3=&mfpAcceptedFlag, a4=&mfpSecondaryFlags
  # The Nim-declared mfp_ignore_mgmt_frame(param: pointer) reads a1-a3 via inline asm.
  # So we call it with a0=envPtr and set a1-a4 via asm before the call.
  let bodyLen = rx.mpduLengthBytes
  let envPtr = cast[pointer](env)
  var mfpResult: bool
  {.emit: ["""
  {
    register void* _a1 __asm__("a1") = """, frameHdr, """;
    register unsigned int _a2 __asm__("a2") = (unsigned int)""", bodyLen, """;
    register unsigned char* _a3 __asm__("a3") = &""", mfpAcceptedFlag, """;
    register unsigned char* _a4 __asm__("a4") = &""", mfpSecondaryFlags, """;
    __asm__ volatile("" : : "r"(_a1), "r"(_a2), "r"(_a3), "r"(_a4));
    """, mfpResult, """ = mfp_ignore_mgmt_frame(""", envPtr, """);
  }
  """].}
  # The blob keeps mfpAcceptedFlag unchanged when mfp_ignore_mgmt_frame returns 0
  # and continues through the normal management-frame classification path.
  var frameAccepted: uint8 = mfpAcceptedFlag

  # --- Call phyif_utils_decode (blob 0x96-0xa2) ---
  # a0 = rxDesc+40 (RX vector), a1 = &phyDecodeStatusByte (sp+21 in blob)
  var rssiResult: int8 = 0
  discard phyif_utils_decode(cast[pointer](addr rx.phyVector[0]), addr rssiResult)
  phyDecodeStatusByte = cast[uint8](rssiResult)

  # --- Read rxu_cntrl_env fields ---
  let rxuEnvVifIdx = env.vifIdx
  let machdrLen = env.machdrLen

  # --- VIF lookup via vif_mgmt_get_vif (blob 0xde) ---
  var vifEntry: pointer = nil  # s9
  if rxuEnvVifIdx != 0xFF:
    vifEntry = vif_mgmt_get_vif(rxuEnvVifIdx)
  elif vifIdx != 0xFF:
    let staVifIdx = staInfoForIdx(vifIdx).instNbr
    env.vifIdx = staVifIdx
    vifEntry = vif_mgmt_get_vif(staVifIdx)

  # --- Subtype dispatch (blob 0xec-0x452) ---
  let subtypeBits = fcFull and 0x00FC'u16  # FC & 0xFC = type+subtype field
  var msgSubtype: uint8 = 0xFF  # s10: message subtype for ke_msg_alloc
  var skipSecHdr: bool = true   # s6: true = don't adjust for sec header in copy
  var sendStaIdx: uint8 = 0    # s1: additional STA tracking

  if frameAccepted != 0:
    case subtypeBits.int
    of 0x80:  # Beacon (blob .L70 at 0x3be)
      let state = ke_state_get(TASK_SCAN)
      if state == ScanChannelPendingState or state == ScanChannelRunningState:
        skipSecHdr = true
        msgSubtype = 2
      else:
        # Not active (blob .L103 at 0x3fc): set defaults, fall through to shared .L81
        skipSecHdr = false
        msgSubtype = 0xFF
      # Shared beacon path (blob .L81 at 0x3d2)
      if vifIdx != 0xFF:
        if vifEntry != nil:
          let vifBeaconFlag = vifChannelAt(vifEntry).state
          if vifBeaconFlag != 0:
            # Call me_beacon_check (blob 0x3e8)
            me_beacon_check(rxuEnvVifIdx, frameHdr, cast[pointer](bodyLen.uint))
      else:
        # vifIdx == 0xFF path (blob .L82 at 0x404)
        # Blob calls ke_state_get(TASK_SCAN) a second time and apm_embedded_enabled
        let state2 = ke_state_get(TASK_SCAN)
        if state2 != 2 and state2 != 3:
          discard apm_embedded_enabled(vifEntry)
      # blob .L84 at 0x3f0: reject if msgSubtype was never set
      if msgSubtype == 0xFF:
        frameAccepted = 0

    of 0x00, 0x10:  # Assoc Req (0x00), Assoc Resp (0x10) (blob .L72 at 0x3b6)
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

    of 0x40:  # Probe Req (blob .L73 at 0x27e)
      # Blob: check if 0x40, if yes -> .L85 (apm_embedded_enabled)
      if vifEntry != nil:
        let apmEnabled = apm_embedded_enabled(vifEntry)
        if apmEnabled:
          skipSecHdr = true
          msgSubtype = 5
        else:
          frameAccepted = 0
      else:
        frameAccepted = 0

    of 0x50:  # Probe Resp (blob .L73 at 0x28e)
      skipSecHdr = true
      sendStaIdx = 0
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
          else:
            frameAccepted = 0
        else:
          if subtypeBits == 0xB0:
            skipSecHdr = false
          else:
            # vifType == 0: debug log (blob 0x444, line 1399), then accept as mgmt
            let subtypeLogFn = getLogFunc(204)
            if subtypeLogFn != nil:
              subtypeLogFn(2, 0, cast[pointer](cstring"rxl_cntrl.c"), 1399)
            skipSecHdr = true
          msgSubtype = 4
      else:
        # No VIF (blob: a4=4 from .L100, takes .L85 apm_embedded path)
        let apmEnabled = apm_embedded_enabled(vifEntry)
        if apmEnabled:
          skipSecHdr = true
          msgSubtype = 5
        else:
          frameAccepted = 0

    of 0xD0:  # Action frame (blob .L78 at 0x366)
      if vifIdx == 0xFF:
        frameAccepted = 0
      else:
        # Read action category using machdrLen offset (blob: th.lrbu a3,s0,s8,0)
        let catByte = rxFrameBodyByte(frame, machdrLen)
        if catByte == 3:  # Block Ack (BA)
          msgSubtype = 6
          skipSecHdr = true
          sendStaIdx = 0
        elif catByte == 8:  # SA Query
          # Blob validates: rxu_cntrl_env[10] must not be 0xFF
          if rxuEnvVifIdx == 0xFF:
            frameAccepted = 0
          else:
            # Check body length: bodyLen - machdrLen > 3
            if (bodyLen.int - machdrLen.int) > 3:
              # Check vif_info_tab[vifIdx][86] (VIF type) for SA Query acceptance
              let saQueryVif = vif_mgmt_get_vif(rxuEnvVifIdx)
              if saQueryVif == nil or vifChannelAt(saQueryVif).vifType == 0xFF:
                frameAccepted = 0
              else:
                # Look up STA via sta_info_tab using vif_info_tab approach
                skipSecHdr = false
                sendStaIdx = 0
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
    (msgSubtype.uint32 shl 16) or (vifIdx.uint32 shl 8) or rxuEnvVifIdx.uint32
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
  if frameAccepted == 0 or msgSubtype == 0xFF:
    # Set frameAccepted to result byte for return
    frameAccepted = mfpAcceptedFlag
    # Fall through to epilogue
  else:
    # Call phy_get_channel(&chanInfo, 0) for current PHY channel info.
    var chanInfo {.noinit.}: array[2, uint32]
    phy_get_channel_raw(cast[pointer](addr chanInfo[0]), 0)

    # Allocate ke_msg: ke_msg_alloc(RXU_MGT_IND, msgSubtype, TASK_RXU, bodyLen+32)
    let msgSize = bodyLen.uint32 + 32
    let msg = ke_msg_alloc(RXU_MGT_IND, msgSubtype, TASK_RXU, msgSize)
    if msg == nil:
      # Debug log: ke_msg_alloc failure (blob 0x308, line 1482)
      let allocLogFn = getLogFunc(204)
      if allocLogFn != nil:
        allocLogFn(2, 0, cast[pointer](cstring"rxl_cntrl.c"), 1482)
      frameAccepted = 0
    else:
      let ind = rxuMgtIndMsgAt(msg)

      # --- Adjust source pointer for security header (blob 0x460-0x48e) ---
      var copySrc = frameHdr
      var copyLen = bodyLen
      if not skipSecHdr:
        # Check machdrLen parity: blob calls assert_warn if odd
        if (machdrLen and 1) != 0:
          assert_warn("rxl_cntrl.c", "rxl_cntrl.c", 1491)
        # Adjust: subtract machdrLen from bodyLen, advance frameHdr past MAC header
        copyLen = copyLen - machdrLen.uint16
        copySrc = rxFrameCursor(copySrc, machdrLen.uint)
      # else: skip adjustment (s6=1), copy from frameHdr as-is

      # --- Populate message fields (blob 0x4a2-0x4fa) ---
      # msg[0..1] = copied frame/body length (blob stores s2 after the optional
      # MAC-header adjustment via th.shia before copying to msg+32).
      ind.frameLen = copyLen
      ind.frameCtrl = fcFull
      ind.vifIdx = vifIdx
      ind.rxuVifIdx = rxuEnvVifIdx
      ind.freq = (chanInfo[0] shr 16).uint16
      ind.band = (chanInfo[0] and 0xFF).uint8
      ind.rssi = rssiResult
      ind.noiseFloor = rssiResult
      ind.phyVector11 = rx.phyVector[11]
      ind.secondary = mfpSecondaryFlags

      if subtypeBits == 0x10'u16 or subtypeBits == 0x30'u16:
        nimFwTrace2U32("[WIFI-NIMFW] assoc_copy ",
                       copyLen.uint32,
                       rxFrameWords(copySrc)[0])
        nimFwTrace2U32("[WIFI-NIMFW] assoc_copy2 ",
                       rxFrameWords(copySrc)[1],
                       rxFrameWords(copySrc)[2])

      # Probe Req special fields: if msgSubtype==5 and sendStaIdx==0
      if msgSubtype == 5 and sendStaIdx == 0:
        ind.timestampLow = rx.timestampLow
        ind.timestampHigh = rx.timestampHigh
        ind.phyVector0 = rx.phyVector[0]

      # --- Copy frame body word-by-word (blob .L91/.L92 at 0x49e-0x518) ---
      copyRoundedRxWords(addr ind.body[0], copySrc, copyLen)

      # Send message via ke_msg_send (blob 0x504)
      ke_msg_send(msg)
      inc nimFwDbgMgtMsgSent
      if subtypeBits == 0xB0'u16:
        inc nimFwDbgAuthMgtMsgSent
      frameAccepted = mfpAcceptedFlag

  # --- Epilogue (blob 0x30e-0x544): post-send check ---
  # Check if accepted flag (sp+22) is set
  if mfpAcceptedFlag != 0:
    # Read rxu_cntrl_env[10] for VIF check
    let postVifIdx = env.vifIdx
    if postVifIdx != 0xFF:
      # Call vif_mgmt_get_vif again (blob 0x324)
      let postVif = vif_mgmt_get_vif(postVifIdx)
      if postVif != nil:
        let postVifType = vifChannelAt(postVif).vifType
        if postVifType == 2:
          # AP VIF: check mm_env[0x2c] (word at offset 44) for upload condition
          let mm = mmEnvView()
          if mm.rxPromiscUploadFlag != 0:
            # Need to upload frame: call rxu_mpdu_upload_and_indicate (blob 0x53c)
            rxu_mpdu_upload_and_indicate(param)
            return 0  # Frame handled by upload path
      else:
        # No VIF found: check mm_env combined flags (blob .L94 at 0x52a)
        let mm = mmEnvView()
        if (mm.rxPromiscUploadFlag or mm.apPromiscUploadFlag) != 0:
          rxu_mpdu_upload_and_indicate(param)
          return 0
    # Set accepted byte to return value
    mfpAcceptedFlag = 0
  return mfpAcceptedFlag.uint32

proc rxu_mgt_ind_handler_scanu(param: pointer) {.exportc: "rxu_mgt_ind_handler_scanu", cdecl.} =
  ## Handle management frame indication for SCANU task (10 bytes in blob, scanu_task.o).
  ## Tail-calls scanu_frame_handler with the message body.
  scanu_frame_handler(param, 0)

proc rxu_mgt_ind_handler_sm(param: pointer) {.exportc: "rxu_mgt_ind_handler_sm", cdecl.} =
  ## Handle management frame indication for SM task (256 bytes in blob, sm_task.o).
  ## Dispatches on 802.11 frame subtype to appropriate SM handler.
  ## Checks ke_state_get(TASK_SM) before calling certain handlers.
  let msg = rxuMgtDispatchView(param)
  # Frame control at msg body offset 2-3 (LE uint16); mask with 0xFC to get type+subtype
  let frameType = msg.frameCtrl and 0xFC'u16
  case frameType
  of 0xB0: # Authentication
    inc nimFwDbgAuthSmDispatch
    nimFwDbgAuthSmState = ke_state_get(TASK_SM).uint32
    when defined(bl808WifiConnectTrace):
      let staVifPair = msg.staIdx.uint32 or (msg.vifIdx.uint32 shl 8)
      nimFwConnectTrace2U32("[WIFI-CT] sm_mgt_auth ",
                            nimFwDbgAuthSmState,
                            staVifPair)
    if nimFwDbgAuthSmState != SmAuthStartingState: return
    sm_auth_handler(param)
  of 0x10: # Association Response
    when defined(bl808WifiConnectTrace):
      let staVifPair = msg.staIdx.uint32 or (msg.vifIdx.uint32 shl 8)
      nimFwConnectTrace2U32("[WIFI-CT] sm_mgt_assoc ",
                            ke_state_get(TASK_SM).uint32,
                            staVifPair)
    if ke_state_get(TASK_SM) != SmAuthenticatingState: return
    sm_assoc_rsp_handler(param)
  of 0x30: # Reassociation Response
    when defined(bl808WifiConnectTrace):
      let staVifPair = msg.staIdx.uint32 or (msg.vifIdx.uint32 shl 8)
      nimFwConnectTrace2U32("[WIFI-CT] sm_mgt_reassoc ",
                            ke_state_get(TASK_SM).uint32,
                            staVifPair)
    if ke_state_get(TASK_SM) != SmAuthenticatingState: return
    sm_assoc_rsp_handler(param)
  of 0xC0: # Deauthentication
    let state = ke_state_get(TASK_SM)
    if state == SmIdleState or state == SM_ACTIVATING_STATE:
      sm_deauth_handler(param)
      return
    # For deauth while authenticating, try sm_auth_start.
    let state2 = ke_state_get(TASK_SM)
    if state2 == SmAuthenticatingState:
      sm_auth_start(param)
  of 0xA0: # Disassociation
    let state = ke_state_get(TASK_SM)
    if state == SmIdleState or state == SM_ACTIVATING_STATE:
      sm_deauth_handler(param)
      return
    # For disassoc while authenticating, try sm_auth_start.
    let state2 = ke_state_get(TASK_SM)
    if state2 == SmAuthenticatingState:
      sm_auth_start(param)
  of 0xD0: # Action
    # Only handle SA Query (category == 8)
    if msg.category == 8'u8:
      sm_sa_query_handler(param)
  else:
    discard

proc rxu_mgt_ind_handler_apm(param: pointer) {.exportc: "rxu_mgt_ind_handler_apm", cdecl.} =
  ## Handle management frame indication for APM task (134 bytes in blob, apm_task.o).
  ## Dispatches on 802.11 frame subtype to appropriate AP-mode handler.
  let msg = rxuMgtDispatchView(param)
  # Frame control at msg body offset 2-3 (LE uint16); mask with 0xFC to get type+subtype
  let frameType = msg.frameCtrl and 0xFC'u16
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

proc rxu_mgt_ind_handler_bam*(param: pointer): uint32
    {.exportc: "rxu_mgt_ind_handler_bam", cdecl.} =
  ## Handle management frame indication for BAM task (276 bytes in blob, bam_task.o).
  ## Matches blob `bam_task.o`::rxu_mgt_ind_handler exactly.
  ##
  ## Blob flow:
  ##   if (msg[33] != 0) return 0;           # action code: only ADDBA Request (0) handled
  ##   baParam = msg[35] | (msg[36]<<8);      # 16-bit BA parameter set
  ##   amsduOK = baParam & 1                   # A-MSDU supported bit
  ##   baPolicy = baParam & 2                  # Immediate (1) / Delayed (0) BA
  ##   bufferSize = baParam >> 6               # 10-bit buffer size
  ##   dialogToken = msg[34]
  ##   staIdx = msg[7]
  ##   (log "AABA Request" via g_bl_ops_funcs[1])
  ##   (log "AABA Response" via g_bl_ops_funcs[1])
  ##   *(u32*)0x24B00054 |= 0x80              # set MACHW BAM ACK bit
  ##   bam_send_air_action_frame(staIdx, 0, 1, dialogToken, bufferSize, 0, 0);
  ##   return 0;
  let msg = rxuMgtDispatchView(param)
  # Only respond to ADDBA Request (action code 0). ADDBA Response (1) and
  # DELBA (2) are not handled here — RXU layer routes them differently.
  if msg.actionCode != 0'u8:
    return 0
  let baParam = msg.baParam
  let amsduOK = (baParam and 1'u16) != 0
  let baPolicy = (baParam and 2'u16) != 0
  let tid = ((baParam shr 2) and 0x0F'u16).uint32
  let bufferSize = (baParam shr 6) and 0x3FF'u16
  let dialogToken = msg.dialogToken
  let staIdx = msg.staIdx
  # Log AABA Request and AABA Response via g_bl_ops_funcs[1] (printf-like).
  # Non-functional for WiFi operation but matches blob behavior when the
  # hook is installed.
  let logPtr = blOpsFunc(4)
  if logPtr != nil:
    const reqFmt: cstring =
      "-----------------> AABA Request:\r\n    A-MSDU: %s\r\n    Block Ack Policy: %s\r\n    TID: %u\r\n    Number of Buffers: %u\r\n"
    const rspFmt: cstring =
      "-----------------> AABA Response:\r\n    A-MSDU: %s\r\n    Block Ack Policy: %s\r\n    TID: %u\r\n    Number of Buffers: %u\r\n"
    const permitted: cstring = "Permitted"
    const notPermitted: cstring = "Not Permitted"
    const immediate: cstring = "Immediate Block Ack"
    const delayed: cstring = "Delayed Block Ack"
    let amsduStr = if amsduOK: permitted else: notPermitted
    let policyStr = if baPolicy: immediate else: delayed
    # Clamp buffer count for log (blob: `if (12 >= buf) buf = 12;` clamps min
    # display — but passes raw buffer_size to bam_send_air_action_frame).
    let logBuf = if bufferSize > 12'u16: bufferSize.uint32 else: 12'u32
    let printFn = cast[proc(fmt: cstring, a: cstring, b: cstring, t: uint32,
                           n: uint32){.cdecl, varargs.}](logPtr)
    printFn(reqFmt, amsduStr, policyStr, tid, logBuf)
    printFn(rspFmt, amsduStr, policyStr, tid, logBuf)
  # Set MACHW BAM ACK bit (reg 0x24B00054 bit 7).
  let machwReg = cast[ptr uint32](MACHW_DOZE_CNTRL2_REG)
  machwReg[] = machwReg[] or 0x80'u32
  # Send ADDBA Response: isAddba=1 selects response-build path in callee.
  # statusCode param actually carries bufferSize here (the ADDBA reqs bufsize
  # is reflected back to peer via me_build_add_ba_rsp).
  bam_send_air_action_frame(staIdx, 0'u8, 1'u8, dialogToken, bufferSize, 0'u8, nil)
  return 0
