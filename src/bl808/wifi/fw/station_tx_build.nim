var smTxSerials {.wifiCtrl.}: array[MAX_VIFS, uint32]
var smAuthExpected {.wifiCtrl.}: SmAuthResponseExpectation

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

proc smTxSessionCurrent(build: SmTxBuildContext): bool =
  ## The connection attempt that captured `build` is still the live one.
  ## A TX reset retires frames, not the attempt: timers, expected responses
  ## and control exchanges are checked with this, frames with smTxOwnerCurrent.
  let identity = build.identity
  identity.captured and identity.vif < MAX_VIFS.uint8 and
    smTxSerials[identity.vif] == build.serial and
    smEnvView().connectInfo == build.connection and
    rxVifEpochs[identity.vif] == identity.vifEpoch and
    staDeleteEpoch(identity.station) == identity.stationEpoch and
    vifChannelForIdx(identity.vif).vifIdx == identity.vif and
    vifChannelForIdx(identity.vif).vifType == VIF_TYPE_STA and
    (identity.station == 0xFF or
     vifChannelForIdx(identity.vif).staIdx == identity.station) and
    ke_state_get(TASK_SM) == build.state

proc smTxOwnerCurrent(build: SmTxBuildContext): bool =
  build.identity.resetEpoch == txResetEpoch and smTxSessionCurrent(build)

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
  ## Release the frame unless the lower layer took it. A response deadline
  ## the builder armed is left alone: it belongs to the SM operation.
  smTxRelease(build)

proc smTxFail(build: var SmTxBuildContext; status: uint16) =
  smTxRelease(build)
  if smTxOwnerCurrent(build): sm_connect_ind(status, 0xFFFF)

proc smTxSetOwnerState(build: var SmTxBuildContext; state: uint16): bool =
  if not smTxOwnerCurrent(build): return false
  build.state = state
  build.stamp = smGo(state)
  smTxOwnerCurrent(build)

proc smTxSetState(build: var SmTxBuildContext; state: uint16): bool =
  if not smTxFrameCurrent(build) or not smTxSetOwnerState(build, state): return false
  smTxFrameCurrent(build)

proc smAuthRecordResponse(stamp: uint32; algorithm: uint8; txSequence: uint16): bool =
  ## Expect the response to auth transaction `txSequence`, sent by SM
  ## operation `stamp` (state 6). Any later operation makes it stale.
  case algorithm
  of 0'u8:
    if txSequence != 1: return false
  of 1'u8:
    if txSequence notin [1'u16, 3'u16]: return false
  of 3'u8:
    if txSequence notin [1'u16, 2'u16]: return false
  else: return false
  smAuthExpected = SmAuthResponseExpectation(stamp: stamp, algorithm: algorithm,
    txSequence: txSequence)
  true

proc smAuthCancelResponse(stamp: uint32) =
  ## Operation `stamp` did not send its request after all.
  if smAuthExpected.stamp == stamp: smAuthExpected.txSequence = 0

proc smAuthResponseMatches(algorithm, responseSequence: uint16): bool =
  ## The response answers the request the live SM operation sent.
  var txSequence: uint16
  case algorithm
  of 0'u16:
    if responseSequence != 2: return false
    txSequence = 1
  of 1'u16:
    if responseSequence notin [2'u16, 4'u16]: return false
    txSequence = if responseSequence == 2: 1'u16 else: 3'u16
  of 3'u16:
    if responseSequence notin [1'u16, 2'u16]: return false
    txSequence = responseSequence
  else: return false
  opCurrent(smOwn.op, smAuthExpected.stamp) and
    smAuthExpected.algorithm == algorithm.uint8 and smAuthExpected.txSequence == txSequence

proc smAuthConsumeResponse(algorithm, responseSequence: uint16): bool =
  if not smAuthResponseMatches(algorithm, responseSequence): return false
  smAuthExpected.txSequence = 0
  true

proc smTxSubmit(build: var SmTxBuildContext; forced: bool): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  if not smTxFrameCurrent(build): return false
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
