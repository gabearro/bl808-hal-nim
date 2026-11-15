var smTxSerials {.wifiCtrl.}: array[MAX_VIFS, uint32]

proc smTxCapture(connection: pointer): SmTxBuildContext =
  let saved = irqSave()
  defer: irqRestore(saved)
  if connection == nil or smEnvView().connectInfo != connection: return
  let vifIndex = connectInfoView(connection).vifIdx
  if vifIndex >= MAX_VIFS.uint8: return
  let vif = vifChannelForIdx(vifIndex)
  if vif.vifIdx != vifIndex or vif.vifType != VIF_TYPE_STA: return
  result = SmTxBuildContext(connection: connection, serial: smTxSerials[vifIndex],
    state: ke_state_get(TASK_SM), identity: TxSessionIdentity(captured: true,
      vif: vifIndex, station: 0xFF, vifEpoch: rxVifEpochs[vifIndex],
      stationEpoch: staDeleteEpoch(0xFF), resetEpoch: txResetEpoch))

proc smTxBeginForVif(vifIndex: uint8): SmTxBuildContext =
  let saved = irqSave()
  defer: irqRestore(saved)
  if vifIndex >= MAX_VIFS.uint8: return
  let vif = vifChannelForIdx(vifIndex)
  if vif.vifIdx != vifIndex or vif.vifType != VIF_TYPE_STA: return
  inc smTxSerials[vifIndex]
  result = SmTxBuildContext(connection: smEnvView().connectInfo,
    serial: smTxSerials[vifIndex], state: ke_state_get(TASK_SM),
    identity: TxSessionIdentity(captured: true, vif: vifIndex, station: 0xFF,
      vifEpoch: rxVifEpochs[vifIndex], stationEpoch: staDeleteEpoch(0xFF),
      resetEpoch: txResetEpoch))

proc smTxBegin(connection: pointer): SmTxBuildContext =
  let saved = irqSave()
  defer: irqRestore(saved)
  if connection == nil or smEnvView().connectInfo != connection: return
  smTxBeginForVif(connectInfoView(connection).vifIdx)

proc smTxOwnerCurrent(build: SmTxBuildContext): bool =
  let identity = build.identity
  identity.captured and identity.vif < MAX_VIFS.uint8 and
    identity.resetEpoch == txResetEpoch and
    smTxSerials[identity.vif] == build.serial and
    smEnvView().connectInfo == build.connection and
    rxVifEpochs[identity.vif] == identity.vifEpoch and
    staDeleteEpoch(identity.station) == identity.stationEpoch and
    vifChannelForIdx(identity.vif).vifIdx == identity.vif and
    vifChannelForIdx(identity.vif).vifType == VIF_TYPE_STA and
    (identity.station == 0xFF or
     vifChannelForIdx(identity.vif).staIdx == identity.station) and
    ke_state_get(TASK_SM) == build.state

proc smTxBindStation(build: var SmTxBuildContext; station: uint8): bool =
  if not smTxOwnerCurrent(build): return false
  if station >= STA_INFO_TAB_ENTRIES.uint8 and station != 0xFF: return false
  build.identity.station = station
  build.identity.stationEpoch = staDeleteEpoch(station)
  true

proc smTxFrameCurrent(build: var SmTxBuildContext): bool =
  if not smTxOwnerCurrent(build) or build.frame == nil: return false
  let desc = hostTxDescAt(build.frame)
  if not txlFrameLeaseMatches(desc, build.lease) or
      desc.bufDesc != build.link or desc.hwDesc != build.hardware:
    return false
  txlFramePreparationCurrent(desc, build.identity, build.lease)

proc smTxAdopt(build: var SmTxBuildContext; frame: pointer): bool =
  if frame == nil: return false
  build.frame = frame
  let desc = hostTxDescAt(frame)
  build.lease = txlFrameLeaseToken(desc)
  build.ownsFrame = true
  if not smTxOwnerCurrent(build): return false
  build.link = desc.bufDesc
  build.hardware = desc.hwDesc
  desc.vifIdx = build.identity.vif
  desc.staInfoIdx = build.identity.station
  smTxFrameCurrent(build)

proc smTxRelease(build: var SmTxBuildContext) =
  let saved = irqSave()
  defer: irqRestore(saved)
  if build.ownsFrame:
    build.ownsFrame = false
    if txlFrameLeaseMatches(hostTxDescAt(build.frame), build.lease):
      txl_frame_release(build.frame, false)

proc smTxEnd(build: var SmTxBuildContext) =
  if build.ownsFrame and build.responseArmed and smTxOwnerCurrent(build):
    build.responseArmed = false
    ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
  smTxRelease(build)

proc smTxFail(build: var SmTxBuildContext; status: uint16) =
  smTxRelease(build)
  if not smTxOwnerCurrent(build): return
  if build.responseArmed:
    build.responseArmed = false
    ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
  if smTxOwnerCurrent(build): sm_connect_ind(status, 0xFFFF)

proc smTxSetOwnerState(build: var SmTxBuildContext; state: uint16): bool =
  if not smTxOwnerCurrent(build): return false
  build.state = state
  ke_state_set(TASK_SM, state)
  smTxOwnerCurrent(build)

proc smTxSetState(build: var SmTxBuildContext; state: uint16): bool =
  if not smTxFrameCurrent(build) or not smTxSetOwnerState(build, state): return false
  smTxFrameCurrent(build)

proc smTxCallbackCurrent(): bool =
  let scope = txActiveFrameCallback
  scope == nil or not scope.identity.smTracked or
    (scope.vif < MAX_VIFS.uint8 and
     smTxSerials[scope.vif] == scope.identity.smSerial and
     smEnvView().connectInfo == scope.identity.smConnection and
     vifChannelForIdx(scope.vif).vifIdx == scope.vif and
     vifChannelForIdx(scope.vif).vifType == VIF_TYPE_STA and
     vifChannelForIdx(scope.vif).staIdx == scope.station and
     ke_state_get(TASK_SM) == scope.identity.smState)

proc smTxTimerCurrent(context: pointer): bool =
  let build = cast[ptr SmTxBuildContext](context)
  if not smTxOwnerCurrent(build[]) or build.frame == nil: return false
  let desc = hostTxDescAt(build.frame)
  txlFrameLeaseMatches(desc, build.lease) and
    desc.bufDesc == build.link and desc.hwDesc == build.hardware and
    txlSessionCurrent(build.identity, desc) and txlStationAdmits(desc)

proc smTxArmResponse(build: var SmTxBuildContext; delay: uint32): bool =
  if not smTxFrameCurrent(build): return false
  if not ke_timer_try_set(SM_RSP_TIMEOUT_IND, TASK_SM, delay,
                          smTxTimerCurrent, addr build): return false
  if not smTxFrameCurrent(build): return false
  build.responseArmed = true
  true

proc smTxSubmit(build: var SmTxBuildContext; forced: bool): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  if not smTxFrameCurrent(build): return false
  let desc = hostTxDescAt(build.frame)
  if desc.callback != nil and
      not txlFrameBindSmOwner(desc, build.connection, build.serial, build.state):
    return false
  # The lower layer consumes the lease on both accepted and failed submission.
  build.ownsFrame = false
  if forced: txl_frame_try_push_force(build.frame, 3) != 0
  else: txl_frame_push(build.frame, 3) != 0

proc smTxFits(build: ptr SmTxBuildContext; buffer: pointer; length: uint32): bool =
  if buffer == nil: return false
  if build == nil: return true
  if not smTxFrameCurrent(build[]): return false
  let base = cast[uint](addr hostTxLinkDescAt(build.link).macHeader[0])
  let address = cast[uint](buffer)
  address >= base and address - base <= TxlFramePayloadSize.uint and
    length.uint <= TxlFramePayloadSize.uint - (address - base)
