# ###########################################################################
#                  STA Management (sta_mgmt_*)
# ###########################################################################

proc staDeleteEpoch(staIdx: uint8): uint32 =
  if staIdx < STA_MGMT_FREE_STAS.uint8: staDeleteEpochs[staIdx] else: 0

proc staDeleteIsCurrent(staIdx: uint8, epoch: uint32): bool =
  staIdx < STA_MGMT_FREE_STAS.uint8 and staDeleteEpochs[staIdx] == epoch and
    staInfoForIdx(staIdx).valid != 0

proc staDeleteCancelQueued(staIdx: uint8) =
  if staIdx >= STA_MGMT_FREE_STAS.uint8:
    return
  let saved = irqSave()
  defer: irqRestore(saved)
  for queue in [addr keMsgQueueSent, addr keMsgQueueSaved]:
    var node = queue.first
    while node != nil:
      let header = cast[ptr KeMsgHdr](node)
      if ((header.id == MM_STA_DEL_REQ and header.destId == TASK_MM) or
          (header.id == ME_STA_DEL_REQ and header.destId == TASK_ME)) and
         header.paramLen >= MeStaDelReqPayloadSize:
        let request = cast[ptr MeStaDelReqPayload](keMsgPayload(header))
        if request.staIdx == staIdx:
          request.staIdx = 0xFF
      node = node.next

proc staDeleteInvalidate(staIdx: uint8; cancelQueued = true) =
  if staIdx >= STA_MGMT_FREE_STAS.uint8: return
  let saved = irqSave()
  defer: irqRestore(saved)
  inc staDeleteEpochs[staIdx]
  if cancelQueued: staDeleteCancelQueued(staIdx)

proc sta_mgmt_init*() {.exportc, cdecl.} =
  ## Initialize station management (84 instrs).
  ## From blob: calls co_list_init(&sta_info_env). Loops over the five normal
  ## STA entries, calling sta_mgmt_entry_init and co_list_push_back for each.
  ## Then initializes 2 extra "broadcast" STA entries at table slots 5 and 6
  ## (entry 6 = broadcast STA for VIF 1). Sets up buffer control pointers,
  ## logs via g_bl_ops_funcs[0xCC], and stores cross-references between
  ## VIF and STA tables.
  # Initialize STA free list
  co_list_init(addr sta_info_env)
  # Init each STA entry and push to free list
  var freeStaIndex = 0'u8
  while freeStaIndex < STA_MGMT_FREE_STAS.uint8:
    let sta = staInfoForIdx(freeStaIndex)
    if not staMgmtResetEntry(staPostponedOwner(cast[pointer](sta)), false):
      return
    co_list_push_back(addr sta_info_env, cast[ptr CoListHdr](sta))
    inc freeStaIndex

  # Initialize broadcast STA entry for VIF 0.
  let bcStaVif0 = staInfoForIdx(STA_MGMT_FREE_STAS.uint8)
  if not staMgmtResetEntry(staPostponedOwner(cast[pointer](bcStaVif0)), false):
    return
  bcStaVif0.instNbr = 0
  bcStaVif0.controlPortState = 0
  bcStaVif0.txPolicy = cast[pointer](txBufferControlBcmcDescAt(0))
  let keysVif0 = vifKeyPointers(vifChannelForIdx(0))
  bcStaVif0.keyMat = cast[pointer](keysVif0)
  # Log
  let logFn = getLogFunc(204)
  if logFn != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn)(
      2, nil, "sta_mgmt.c", 157, "------ set default key %p, key ptr %p\r\n",
      cast[pointer](keysVif0), cast[pointer](keysVif0.defaultKeyPtr.uint))

  # Initialize broadcast STA entry for VIF 1.
  let bcStaVif1 = staInfoForIdx(STA_MGMT_FREE_STAS.uint8 + 1'u8)
  if not staMgmtResetEntry(staPostponedOwner(cast[pointer](bcStaVif1)), false):
    return
  bcStaVif1.instNbr = 1
  bcStaVif1.controlPortState = 0
  bcStaVif1.txPolicy = cast[pointer](txBufferControlBcmcDescAt(1))
  let keysVif1 = vifKeyPointers(vifChannelForIdx(1))
  bcStaVif1.keyMat = cast[pointer](keysVif1)
  # Final log via g_bl_ops_funcs
  let logFn2 = getLogFunc(204)
  if logFn2 != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn2)(
      2, nil, "sta_mgmt.c", 157, "------ set default key %p, key ptr %p\r\n",
      cast[pointer](keysVif1), cast[pointer](keysVif1.defaultKeyPtr.uint))

proc sta_mgmt_register*(param: pointer, staIdxOut: ptr uint8): uint8 {.exportc, cdecl.} =
  ## Configure a free station before publishing it to the VIF's active list.
  if param == nil or staIdxOut == nil:
    return 1
  let saved = irqSave()
  defer: irqRestore(saved)
  let req = staMgmtRegisterParamView(param)[]
  staIdxOut[] = 0xFF
  let instNbr = req.instNbr
  if instNbr >= MAX_VIFS.uint8 or sta_info_env.first == nil:
    return 1
  if (req.macAddr[0] and 1'u8) != 0 or
      req.macAddr == [0'u8, 0, 0, 0, 0, 0]:
    return 1
  let vif = vifChannelForIdx(instNbr)
  let vifEpoch = rxVifEpochs[instNbr]
  let keyPtrs = vifKeyPointers(vif)
  let vifFlags = keyPtrs.flags
  var stationEpochs: array[STA_MGMT_FREE_STAS, uint32]
  for index in 0'u8 ..< STA_MGMT_FREE_STAS.uint8:
    stationEpochs[index] = staDeleteEpoch(index)

  # No station is reserved while the diagnostic callback can reenter.
  let logFn = getLogFunc(204)
  if logFn != nil:
    let stationKey = (vifFlags and 8) != 0
    let line = if stationKey: 282.cint else: 293.cint
    let format = if stationKey:
      cstring("------ %d set default key %p, key ptr %p\r\n")
    else:
      cstring("------ %d set default key %p, ptr %p\r\n")
    var holder = cast[pointer](keyPtrs)
    var key = cast[pointer](keyPtrs.defaultKeyPtr.uint)
    if stationKey:
      holder = nil
      key = nil
      # Inspect only pool members; the head is not reserved until after logging.
      for index in 0'u8 ..< STA_MGMT_FREE_STAS.uint8:
        let candidate = staInfoForIdx(index)
        if cast[ptr CoListHdr](candidate) == sta_info_env.first:
          holder = cast[pointer](addr candidate.keyHolder)
          key = candidate.keyHolder
          break
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn)(
      2, nil, "sta_mgmt.c", line, format, line, holder, key)
  if rxVifEpochs[instNbr] != vifEpoch or sta_info_env.first == nil:
    return 1

  let sta = staInfoAt(cast[uint](sta_info_env.first))
  var staIdx = 0'u8
  while staIdx < STA_MGMT_FREE_STAS.uint8 and staInfoForIdx(staIdx) != sta:
    inc staIdx
  if staIdx >= STA_MGMT_FREE_STAS.uint8:
    return 1
  if sta.valid != 0 or sta.instNbr != 0xFF or
      staDeleteEpoch(staIdx) != stationEpochs[staIdx]:
    return 1

  let freeStaInfoListNode = co_list_pop_front(addr sta_info_env)
  if freeStaInfoListNode == nil:
    return 1
  let staEntry = cast[uint](freeStaInfoListNode)
  sta.macAddr = req.macAddr
  var phyBwMax = req.phyBwMax
  if phyBwMax < 16: phyBwMax = 16
  sta.phyBwMax = phyBwMax
  # Copy rates and capability fields
  sta.rateSet = req.rateSet
  sta.vif = req.vif
  sta.instNbr = instNbr
  sta.extFlag = req.extFlag
  sta.assocInfoWord0 = req.assocInfoWord0
  sta.assocInfoWord1 = req.assocInfoWord1
  sta.paramFlag = req.paramFlag
  sta.infoIdx = staIdx
  # Initial rate config
  sta.initialRateConfig = 0x19000'u32
  # Vendor initializes sta+336 and nine contiguous halfwords at sta+338.
  let rxSeq = staRxSequence(sta)
  rxSeq.nonQosSeqCtrl = 0xFFFF'u16
  for seqCtrl in rxSeq.qosSeqCtrl.mitems:
    seqCtrl = 0xFFFF'u16
  # Store TX policy descriptor pointer at sta+320.
  # Vendor uses one 60-byte txl_buffer_control_desc entry per STA; rc_init
  # later writes the RC stats pointer at sta+324.
  sta.txPolicy = cast[pointer](txBufferControlDescAt(staIdx.int))
  # Vendor clears the controlled-port state at byte 72, not traffic byte 73.
  sta.controlPortState = 0
  if (vifFlags and 8) != 0:
    sta.keyMat = cast[pointer](addr sta.keyHolder)
  else:
    sta.keyMat = cast[pointer](keyPtrs)
  if (keyPtrs.flags and 16) != 0:
    sta.capabilityFlags = sta.capabilityFlags or 8
  # Push STA onto the VIF's postponed-STA list.
  co_list_push_back(vifPostponedStaList(vif), cast[ptr CoListHdr](staEntry))
  # Mark station as active
  sta.valid = 1
  staIdxOut[] = staIdx
  return 0

proc staRemovalCurrent(owner: StaQueueIdentity): bool =
  staPostponedOwnerCurrent(owner) and staInfoAt(owner.entry).valid == 0

proc staMgmtBeginRemoval(staIdx: uint8; owner: var StaQueueIdentity): pointer =
  # A retiring station must not be admitted by RX/TX or removed by callbacks.
  if staIdx >= STA_MGMT_FREE_STAS.uint8:
    return nil
  let saved = irqSave()
  defer: irqRestore(saved)
  let sta = staInfoForIdx(staIdx)
  if sta.valid == 0 or sta.instNbr >= MAX_VIFS.uint8:
    return nil
  let instNbr = sta.instNbr
  let vif = vifChannelForIdx(instNbr)
  if not co_list_find(vifPostponedStaList(vif), cast[ptr CoListHdr](sta)):
    return nil
  var selected: uint8
  if not txlHaltStationQueues(staIdx, selected): return nil
  owner = staPostponedOwner(cast[pointer](sta))
  sta.valid = 0
  staDeleteInvalidate(staIdx)
  owner.stationEpoch = staDeleteEpoch(staIdx)
  co_list_extract(vifPostponedStaList(vif), cast[ptr CoListHdr](sta))
  txl_retire_station(staIdx, selected)
  if not staRemovalCurrent(owner):
    return nil
  cast[pointer](sta)

proc staMgmtFinishRemoval(owner: StaQueueIdentity): bool {.discardable.} =
  # Keep the slot out of the free list until postponed TX callbacks finish.
  if not owner.stationTracked or owner.station >= STA_MGMT_FREE_STAS.uint8:
    return
  if not staMgmtResetEntry(owner, true):
    return
  let saved = irqSave()
  defer: irqRestore(saved)
  let sta = staInfoAt(owner.entry)
  # Reset advances the station epoch once. A later reset or allocation must
  # not let this continuation publish the same storage to the free pool.
  if (owner.stationTracked and
      staDeleteEpoch(owner.station) != owner.stationEpoch + 1'u32) or
      sta.valid != 0 or sta.instNbr != 0xFF or
      co_list_find(addr sta_info_env, cast[ptr CoListHdr](owner.entry)):
    return
  staDeleteCancelQueued(owner.station)
  co_list_push_back(addr sta_info_env, cast[ptr CoListHdr](owner.entry))
  true

proc sta_mgmt_unregister*(staIdx: uint8) {.exportc, cdecl.} =
  ## Vendor order: detach, drain/reset, then return the station to the free list.
  var owner: StaQueueIdentity
  let staEntry = staMgmtBeginRemoval(staIdx, owner)
  if staEntry != nil:
    staMgmtFinishRemoval(owner)

proc sta_mgmt_add_key*(param: pointer, hwKeyIdx: uint8) {.exportc, cdecl.} =
  ## Install station key metadata and reset replay/packet-number state.
  ## Cipher 1 carries the two TKIP MIC keys; ciphers 0/3 seed a WEP IV.
  let req = machwKeyWriteParamView(param)
  let staIdx = req.keyType
  let sta = staInfoForIdx(staIdx)
  inc nimFwDbgStaAddKeyCalls
  nimFwDbgStaAddKeyMeta = staIdx.uint32 or (hwKeyIdx.uint32 shl 8) or
    (req.cipherType.uint32 shl 16) or (req.keyFlags.uint32 shl 24)
  nimFwDbgStaAddKeyPtrs0 = pointerAddrU32(cast[pointer](sta))
  nimFwDbgStaAddKeyPtrs1 = pointerAddrU32(sta.keyMat)
  nimFwDbgStaAddKeyPtrs2 = pointerAddrU32(sta.keyHolder)
  # Store key metadata
  sta.hwKeyIdx = hwKeyIdx
  let keyType = req.cipherType
  sta.keyType = keyType
  let cipherSuite = req.addrIdx
  sta.cipherSuite = cipherSuite
  let keyFlags = req.keyFlags
  sta.keyFlags = keyFlags
  # Eight replay counters precede the TX packet number and MIC-key union.
  discard c_memset(cast[pointer](addr sta.keyArea[0]), 0, 128.csize_t)
  case keyType
  of 1:
    sta.pnLow = 0
    sta.pnHigh = 0
    sta.keyTail = req.temporalKeyTail
  of 0, 3:
    # sta_mgmt.o owns its own LCG, independent of rate-control sampling.
    staKeyPrngState = staKeyPrngState * RC_PRNG_MULT + RC_PRNG_INCR
    sta.pnLow = staKeyPrngState shr 16
    sta.pnHigh = 0
  else:
    # Unknown type: clear PN
    sta.pnLow = 0
    sta.pnHigh = 0
  # Mark key as installed
  sta.keyInstalled = 1
  # Store pointer to key material
  sta.keyHolder = cast[pointer](addr sta.keyArea[0])
  rxMgtReplayReset(sta.keyHolder)
  nimFwDbgStaAddKeyPtrs1 = pointerAddrU32(sta.keyMat)
  nimFwDbgStaAddKeyPtrs2 = pointerAddrU32(sta.keyHolder)

proc sta_mgmt_del_key*(staEntry: pointer) {.exportc, cdecl.} =
  ## Invalidate the station key and close its controlled port.
  let sta = staInfoAt(staEntry)
  rxMgtReplayForget(cast[pointer](addr sta.keyArea[0]))
  sta.keyInstalled = 0
  sta.keyHolder = nil
  sta.controlPortState = 1

proc sta_mgmt_send_postponed_frame*(vifEntry: pointer, staEntry: pointer, maxCount: uint32): uint32 {.exportc, cdecl.} =
  ## Send postponed frames for a station (full loop with ~100 instrs).
  ## From blob: checks VIF PS mode flags (vif+91), sets ke_env PS bits and
  ## calls ke_evt_set(256) if PS active. Then loops: loads postponed desc from
  ## sta+356, checks txl_cntrl_tx_check, apm_tx_int_ps_check,
  ## apm_tx_int_ps_get_postpone. If no postpone, calls co_list_pop_front to
  ## dequeue. Clears desc+217, pushes via txl_cntrl_push_int, decrements
  ## txl_frame_env+16 counter. Loops until maxCount or list empty. Finally
  ## calls sta_mgmt_postponed_desc_release.
  let saved = irqSave()
  defer: irqRestore(saved)
  if vifEntry == nil or staEntry == nil:
    return 0
  let identity = staPostponedOwner(staEntry)
  if not staPostponedOwnerCurrent(identity) or not identity.vifTracked or
      cast[pointer](vifChannelForIdx(identity.vif)) != vifEntry:
    return 0
  let vifView = vifChannelAt(vifEntry)
  let sta = staInfoAt(staEntry)
  let psFlags = vifView.psFlags
  if psFlags != 0:
    let vifType = vifView.vifType
    let ps = keEnvPsFlags()
    if vifType == VIF_TYPE_AP:
      # AP mode: set bit 1 in ke_env+28 and set ke_env+29 = 1
      ps.flags = ps.flags or 2
      ps.apPending = 1
    elif vifType == VIF_TYPE_STA:
      # Other mode: set bit 0 in ke_env+28 and set ke_env+31 = 1
      ps.flags = ps.flags or 1
      ps.otherPending = 1
    # Signal PS work only when the VIF has pending power-save activity.
    ke_evt_set(256)
    if not staPostponedOwnerCurrent(identity):
      return 0
  # Walk postponed descriptor list
  var postponedFramesSent: uint32 = 0
  let frameEnv = txFrameEnv()
  while maxCount == 0 or postponedFramesSent < maxCount:
    if not staPostponedOwnerCurrent(identity):
      return postponedFramesSent
    if sta.postponedList.first == nil:
      break
    if not staPostponedListValid(addr sta.postponedList):
      break
    let head = sta.postponedList.first
    let generation = txlFrameLeaseToken(hostTxDescAt(cast[pointer](head)))
    # Check TX allowed
    let txOk = txl_cntrl_tx_check(vifEntry)
    if not staPostponedOwnerCurrent(identity):
      return postponedFramesSent
    if sta.postponedList.first != head or
        not txlFrameLeaseMatches(hostTxDescAt(cast[pointer](head)), generation):
      continue
    if not txOk:
      break
    # Check PS state for this frame
    let psOk = apm_tx_int_ps_check(cast[pointer](head))
    if not staPostponedOwnerCurrent(identity):
      return postponedFramesSent
    if sta.postponedList.first != head or
        not txlFrameLeaseMatches(hostTxDescAt(cast[pointer](head)), generation):
      continue
    if not psOk:
      break
    # Get postpone info
    var postponeFlag: uint32 = 0
    let desc = apm_tx_int_ps_get_postpone(vifEntry, staEntry, addr postponeFlag)
    if not staPostponedOwnerCurrent(identity):
      return postponedFramesSent
    if postponeFlag != 0:
      break
    var frameDesc: pointer
    if desc != nil:
      frameDesc = desc
    else:
      # Pop from the list
      frameDesc = cast[pointer](co_list_pop_front(addr sta.postponedList))
    if frameDesc == nil:
      break
    # Process the frame
    let txDesc = hostTxDescAt(frameDesc)
    let ac = apmTxDescPsAt(frameDesc).accessCategory
    txDesc.postponeFlag = 0
    postponedFramesSent += 1
    # Transfer accounting before TX can complete, requeue, or retire the station.
    if frameEnv.postponedCount > 0:
      frameEnv.postponedCount = frameEnv.postponedCount - 1
    discard txl_cntrl_push_int(frameDesc, ac)
  # Release remaining postponed descriptors
  if staPostponedOwnerCurrent(identity):
    discard sta_mgmt_postponed_desc_release(staEntry, 0)
  return postponedFramesSent

proc staMgmtResetEntry(owner: StaQueueIdentity; requireRetired: bool): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  if not staPostponedOwnerCurrent(owner):
    return false
  let staEntry = owner.entry
  let sta = staInfoAt(staEntry)
  if requireRetired and sta.valid != 0:
    return false
  var resetOwner = owner
  if owner.stationTracked and owner.station < STA_MGMT_FREE_STAS.uint8:
    let deletion = mmStaDeletions[owner.station]
    let preserveRequest = requireRetired and deletion.active and deletion.requestOwned and
      deletion.owner.entry == owner.entry and
      deletion.owner.stationEpoch == owner.stationEpoch
    staDeleteInvalidate(owner.station, not preserveRequest)
    resetOwner.stationEpoch = staDeleteEpoch(owner.station)
  discard staReleasePostponed(resetOwner, 1'u32, saved)
  if not staPostponedOwnerCurrent(resetOwner) or
      (requireRetired and sta.valid != 0) or sta.postponedList.first != nil:
    return false
  discard c_memset(staEntry, 0, 368.csize_t)
  sta.instNbr = 0xFF'u8
  true

proc sta_mgmt_entry_init*(staEntry: pointer) {.exportc, cdecl.} =
  ## Reset a STA entry to default/free state.
  ## Blob algorithm:
  ##   sta_mgmt_postponed_desc_release(staEntry, 1)   ; release pending TX
  ##   memset(staEntry, 0, 368)                       ; zero entire entry
  ##   *(u8*)(staEntry+39) = 0xFF                     ; invalid staIdx sentinel
  ## Prior Nim bug: called mm_sec_machwkey_del() with a byte from offset 234
  ## (which in an active entry is a QoS field, not a key index) — that both
  ## skipped the TX-desc cleanup the blob does and risked deleting an unrelated
  ## HW key.
  let saved = irqSave()
  let owner = staPostponedOwner(staEntry)
  irqRestore(saved)
  discard staMgmtResetEntry(owner, false)

proc staPostponedOwner(staEntry: pointer): StaQueueIdentity =
  result.entry = staEntry
  if staEntry == nil:
    return
  result.vif = staInfoAt(staEntry).instNbr
  if result.vif < MAX_VIFS.uint8:
    result.vifTracked = true
    result.vifEpoch = rxVifEpochs[result.vif]
  for index in 0'u8 ..< STA_INFO_TAB_ENTRIES.uint8:
    if cast[pointer](staInfoForIdx(index)) == staEntry:
      result.stationTracked = true
      result.station = index
      result.stationEpoch = staDeleteEpoch(index)
      break

proc staPostponedOwnerCurrent(identity: StaQueueIdentity): bool =
  identity.entry != nil and staInfoAt(identity.entry).instNbr == identity.vif and
    (not identity.stationTracked or
     staDeleteEpoch(identity.station) == identity.stationEpoch) and
    (not identity.vifTracked or rxVifEpochs[identity.vif] == identity.vifEpoch)

proc staPostponedListValid(queue: ptr CoList): bool =
  # The vendor pop operation leaves last stale when first becomes nil.
  if queue.first == nil:
    return true
  var slow = queue.first
  var fast = queue.first
  while fast != nil:
    if not wifiRamPointer(cast[pointer](fast)):
      return false
    fast = fast.next
    if fast != nil:
      if not wifiRamPointer(cast[pointer](fast)):
        return false
      fast = fast.next
      slow = slow.next
      if fast != nil and fast == slow:
        return false
  var node = queue.first
  var last: ptr CoListHdr
  while node != nil:
    last = node
    node = node.next
  last == queue.last

proc staReleasePostponed(identity: StaQueueIdentity;
                        flag, callbackIrqState: uint32): uint32 =
  ## Release postponed descriptors for a station entry (58 instrs).
  ## From blob: walks the postponed frame list at sta+356. For each frame:
  ##   - If flag != 0: releases all frames unconditionally.
  ##   - If flag == 0: checks MAC timestamp against frame[84] (TX time).
  ##     If (macTime - txTime) > 0x1D4C0 (~120000 ticks = 120ms), releases frame.
  ##     Otherwise keeps it.
  ## Released internal frames return to their pool and notify their callback.
  let staEntry = identity.entry
  if staEntry == nil:
    return 0
  let saved = irqSave()
  defer: irqRestore(saved)
  if not staPostponedOwnerCurrent(identity):
    return 0
  let sta = staInfoAt(staEntry)
  if sta.postponedList.first == nil:
    return 0
  if not staPostponedListValid(addr sta.postponedList):
    inc nimFwDbgPostponedRelease
    nimFwDbgPostponedReleaseDesc = pointerAddrU32(cast[pointer](sta.postponedList.first))
    nimFwDbgPostponedReleaseCb = 0xFFFFFFFF'u32
    nimFwDbgPostponedReleaseFc = 0xFFFFFFFF'u32
    nimFwDbgPostponedReleaseFlags = flag or 0x80000000'u32
    return 0
  var pending = TxFlushBatch(previous: txActiveFlush, postponed: sta.postponedList)
  var retained = TxFlushBatch(previous: addr pending)
  sta.postponedList = default(CoList)
  txActiveFlush = addr retained
  defer: txlFlushScopeExit(pending.previous)
  var released: uint32 = 0
  let maxAge = 0x1D4C0'u32  # ~120ms in MAC ticks
  let frameEnv = txFrameEnv()
  template releaseFrame(postponedTxDesc: pointer) =
    let txDesc = hostTxDescAt(postponedTxDesc)
    inc nimFwDbgPostponedRelease
    nimFwDbgPostponedReleaseDesc = pointerAddrU32(postponedTxDesc)
    nimFwDbgPostponedReleaseCb = pointerAddrU32(txDesc.callback)
    nimFwDbgPostponedReleaseFlags =
      flag or (txDesc.usedFlag.uint32 shl 8) or
      (txDesc.postponeFlag.uint32 shl 16) or (txDesc.retryFlag.uint32 shl 24)
    if txDesc.bufDesc != nil:
      let link = hostTxLinkDescAt(txDesc.bufDesc)
      nimFwDbgPostponedReleaseFc =
        link.macHeader[0].uint32 or (link.macHeader[1].uint32 shl 8)
    else:
      nimFwDbgPostponedReleaseFc = 0xFFFFFFFF'u32
    txDesc.postponeFlag = 0
    if frameEnv.postponedCount > 0:
      dec frameEnv.postponedCount
    inc released
    # Keep the caller's callback IRQ contract, then reacquire queue ownership.
    irqRestore(callbackIrqState)
    try:
      txl_frame_release(postponedTxDesc, true)
    finally:
      discard irqSave()
  while pending.postponed.first != nil:
    let node = pending.postponed.first
    co_list_remove(addr pending.postponed, nil, node)
    let txDesc = hostTxDescAt(cast[pointer](node))
    let doRelease = flag != 0 or not staPostponedOwnerCurrent(identity) or
      (regRead(MACHW_TIMLO_REG) - txDesc.pendingMacTime) > maxAge
    if doRelease:
      releaseFrame(cast[pointer](node))
    else:
      co_list_push_back(addr retained.postponed, node)
  if not staPostponedOwnerCurrent(identity):
    while retained.postponed.first != nil:
      let node = retained.postponed.first
      co_list_remove(addr retained.postponed, nil, node)
      releaseFrame(cast[pointer](node))
  elif retained.postponed.first != nil:
    # Original survivors precede work appended by callbacks.
    retained.postponed.last.next = sta.postponedList.first
    if sta.postponedList.first == nil:
      sta.postponedList.last = retained.postponed.last
    sta.postponedList.first = retained.postponed.first
    retained.postponed = default(CoList)
  return released

proc sta_mgmt_postponed_desc_release*(staEntry: pointer, flag: uint32): uint32 {.exportc, cdecl.} =
  let saved = irqSave()
  defer: irqRestore(saved)
  staReleasePostponed(staPostponedOwner(staEntry), flag, saved)

proc sta_mgmt_aging_postponed_desc*(staEntry: pointer, maxCount: uint32): uint32 {.exportc, cdecl.} =
  ## Age postponed frame descriptors (25 instrs).
  ## From blob: iterates all entries physically present in sta_info_tab
  ## (7 entries, 368 bytes each), calling sta_mgmt_postponed_desc_release(staEntry, 0).
  ## Accumulates total released count. Returns total.
  let saved = irqSave()
  defer: irqRestore(saved)
  let resetEpoch = txResetEpoch
  var owners: array[STA_INFO_TAB_ENTRIES, StaQueueIdentity]
  for postponedStaIndex in 0'u8 ..< STA_INFO_TAB_ENTRIES.uint8:
    let sta = staInfoForIdx(postponedStaIndex)
    owners[postponedStaIndex] = staPostponedOwner(cast[pointer](sta))
  var total: uint32 = 0
  for owner in owners:
    if txResetEpoch != resetEpoch: break
    if staPostponedOwnerCurrent(owner):
      # Preserve the caller's callback IRQ state while retaining the snapshot.
      total += staReleasePostponed(owner, 0, saved)
  return total
