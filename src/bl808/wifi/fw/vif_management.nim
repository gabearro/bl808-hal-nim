# ###########################################################################
#                  VIF Management (vif_mgmt_*)
# ###########################################################################

proc vif_mgmt_entry_init*(vifEntry: pointer): bool {.exportc, cdecl.} =
  ## Initialize a VIF entry to default state.
  ## Sets vifType=4 (free), vifIdx/instNbr=127, clears chan_ctxt and lists.
  let vif = vifChannelAt(vifEntry)
  for vifIdx in 0'u8 ..< MAX_VIFS.uint8:
    if vifChannelForIdx(vifIdx) == vif:
      if not rxInvalidateVif(vifIdx): return false
      break
  vif.vifType = 4
  vif.txPower = 127
  vif.maxTxPower = 127
  vif.chanCtxt = nil
  true

proc vif_mgmt_add_to_list*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Add VIF entry to the active VIF list and notify platform.
  ## Placeholder: sends notification to platform layer.
  discard

proc vif_mgmt_init*(): bool {.exportc, cdecl.} =
  ## Initialize VIF management.
  ## From blob (67 instrs): zeroes vif_mgmt_env, inits two CoLists (free + active),
  ## zeroes both VIF entries (1512 bytes each), sets default fields, pushes both
  ## entries onto the free list, then tail-calls co_list_push_back for the second.
  let env = vifMgmtEnvView()
  let vifTabBase = cast[uint](addr vif_info_tab[0])
  for vifIdx in 0'u8 ..< MAX_VIFS.uint8:
    if not rxInvalidateVif(vifIdx): return false

  # Zero vif_mgmt_env (20 bytes)
  discard c_memset(env, 0, sizeof(VifMgmtEnvView).csize_t)

  # Init the free VIF list at vif_mgmt_env+0
  co_list_init(addr env.freeList)

  # Init the active VIF list at vif_mgmt_env+8
  co_list_init(addr env.activeList)

  # Zero first VIF entry (1512 bytes)
  discard c_memset(cast[pointer](vifTabBase), 0, VIF_ENTRY_SIZE.csize_t)

  # Set default fields for VIF entry 0
  let vif0 = vifTabBase
  let vif0View = vifChannelAt(vif0)
  vif0View.vifType = 4
  vif0View.txPower = 127
  vif0View.maxTxPower = 127

  # Store vif_mgmt_bcn_to_evt callback in the beacon timeout timer.
  let bcnToEvtAddr = cast[pointer](vif_mgmt_bcn_to_evt)
  vif0View.beaconTimeoutTimer.callback = bcnToEvtAddr
  vif0View.beaconTimeoutTimer.env = cast[uint32](vif0)

  # Push VIF entry 0 onto the free list
  co_list_push_back(addr env.freeList, cast[ptr CoListHdr](vif0))

  # Zero second VIF entry (1512 bytes) at vif_info_tab + 0x5E8
  let vif1 = vifTabBase + VIF_ENTRY_SIZE.uint
  discard c_memset(cast[pointer](vif1), 0, VIF_ENTRY_SIZE.csize_t)

  let vif1Entry = vif1
  let vif1View = vifChannelAt(vif1Entry)
  vif1View.beaconTimeoutTimer.callback = bcnToEvtAddr
  vif1View.beaconTimeoutTimer.env = cast[uint32](vif1Entry)

  # Set default fields for VIF entry 1.
  vif1View.vifType = 4
  vif1View.txPower = 127
  vif1View.maxTxPower = 127

  # Push VIF entry 1 onto the free list (tail call in blob)
  co_list_push_back(addr env.freeList, cast[ptr CoListHdr](vif1Entry))
  true

proc vif_mgmt_register*(macAddr: pointer, vifType: uint8, p2p: bool, vifIdxOut: ptr uint8): uint8 {.exportc, cdecl.} =
  ## Register a new VIF (143 instrs).
  ## From blob: checks vif_mgmt_env[0] (active list head). If vif_mgmt_env[8]
  ## is nonzero, validates MAC address against platform MAC registers. Then calls
  ## mm_hw_info_set. Pops free VIF from vif_mgmt_env list via co_list_pop_front.
  ## Sets vifType, copies MAC addr, computes vifIdx, sets timer constants,
  ## For STA type: increments STA count, sets up STA-specific fields, calls
  ## wpa_cbs[0]->init callback. For AP type: calls mm_hw_ap_info_set on first AP,
  ## increments AP count, calls mm_bcn_init_vif. Then calls td_start and
  ## co_list_push_back to add to active VIF list.
  if txlResetting(): return 1
  let env = vifMgmtEnvView()
  # Check if VIF management is initialized (vif_mgmt_env[0] = list head)
  if vifType == VIF_TYPE_AP and (env.apCount != 0 or not mmBeaconPoolIdle()):
    return 1
  if vifType == VIF_TYPE_AP:
    # A detached AP still owns the shared beacon resources until reset.
    for index in 0'u8 ..< MAX_VIFS.uint8:
      if vifChannelForIdx(index).vifType == VIF_TYPE_AP:
        return 1
  let listHead = env.freeList.first
  if listHead == nil:
    return 1
  # Check if platform MAC address filter is active (vif_mgmt_env+8)
  let platFilter = env.activeList.first
  if platFilter != nil:
    # Validate MAC address against platform registers at 0x24B00000
    let mb = cast[ptr UncheckedArray[uint8]](macAddr)
    let mac32 = mb[0].uint32 or (mb[1].uint32 shl 8) or
                (mb[2].uint32 shl 16) or (mb[3].uint32 shl 24)
    let platMac32 = regRead(0x24B00010'u32)  # platform MAC low 32 bits
    if mac32 != platMac32:
      return 1
    let mac16hi = mb[4].uint16 or (mb[5].uint16 shl 8)
    let platMac16 = cast[uint16](regRead(0x24B00014'u32))
    let macMask = regRead(0x24B0001C'u32)
    let diff = (mac16hi.uint32 xor platMac16.uint32) and (not macMask)
    if diff != 0:
      return 1
    # Set filter flags: OR bit 16 into mm_env[1], write combined filter to RX ctrl
    let mm = mmEnvView()
    mm.rxFilterExtra = mm.rxFilterExtra or 16
    regWrite(MACHW_RX_CNTRL_REG, mm.rxFilterExtra or mm.rxFilterBase)
  # Set up HW info
  mm_hw_info_set(macAddr)
  # Pop free VIF entry from list
  let freeVifListNode = co_list_pop_front(addr env.freeList)
  if freeVifListNode == nil:
    return 1
  let vifEntry = cast[pointer](freeVifListNode)
  let vif = vifChannelAt(vifEntry)
  # Find the popped VIF in the typed table.
  var vifIdx = 0'u8
  while vifIdx < MAX_VIFS.uint8 and vifChannelForIdx(vifIdx) != vif:
    inc vifIdx
  if vifIdx >= MAX_VIFS.uint8:
    return 1
  if not rxInvalidateVif(vifIdx):
    co_list_push_front(addr env.freeList, freeVifListNode)
    return 1
  vif.vifType = vifType
  discard c_memcpy(cast[pointer](addr vif.macAddr[0]), macAddr, 6.csize_t)
  vif.vifIdx = vifIdx
  # Set default EDCA register constants (matching blob values)
  vif.edcaRegs[0] = 0x0A47'u32
  vif.edcaRegs[1] = 0x0A43'u32
  vif.edcaRegs[2] = 0x5E432'u32
  vif.edcaRegs[3] = 0x2F322'u32
  vif.chanCtxt = nil
  vif.tbttNode.vifIdx = vifIdx
  # Type-specific initialization
  if vifType == VIF_TYPE_STA:
    # STA mode
    vif.tbttTimer.env = pointerAddrU32(vifEntry)
    env.staCount = env.staCount + 1
    # Set up STA-mode timer callbacks
    let bcnTimeoutCb = cast[pointer](mm_sta_timer_bcn_timeout)
    let staTbttCb = cast[pointer](mm_sta_tbtt)
    let dataTimeoutCb = cast[pointer](mm_sta_timer_data_timeout)
    vif.tbttTimer.callback = staTbttCb
    vif.keepAliveTimer.callback = bcnTimeoutCb
    vif.keepAliveTimer.env = pointerAddrU32(vifEntry)
    vif.securityTimer.callback = dataTimeoutCb
    vif.securityTimer.env = pointerAddrU32(vifEntry)
    # STA-specific fields
    vif.staIdx = 0xFF
    vif.rssiStatePadding[0] = 0
    vif.rssiStatePadding[1] = 0
    # Call WPA init callback if available
    let wpaCbsPtr = cast[uint](addr wpa_cbs)
    let wpaCbsVal = cast[ptr pointer](wpaCbsPtr)[]
    if wpaCbsVal != nil:
      let initFn = cast[ptr pointer](cast[uint](wpaCbsVal))[]
      if initFn != nil:
        cast[proc(){.cdecl.}](initFn)()
  elif vifType == VIF_TYPE_AP:
    # AP mode
    if env.apCount == 0:
      # First AP VIF: set HW AP info
      mm_hw_ap_info_set(0)
    env.apCount = env.apCount + 1
    # Initialize beacon for this VIF
    mm_bcn_init_vif(vifEntry)
  # Common: call td_start, push to active VIF list, write vifIdx output
  td_start(vifIdx)
  if vifType == VIF_TYPE_STA:
    vif.vifType = VIF_TYPE_STA
  vifIdxOut[] = vifIdx
  co_list_push_back(addr env.activeList, cast[ptr CoListHdr](vifEntry))
  return 0

proc vif_mgmt_unregister*(vifIdx: uint8): bool {.exportc, cdecl, discardable.} =
  ## Unregister a VIF (111 instrs).
  ## From blob: removes VIF from active list, decrements STA/AP count,
  ## clears timers, resets TD, zeroes the VIF entry, reinitializes to free
  ## state, pushes back onto free list, then tail-calls co_list_push_back.
  if vifIdx >= MAX_VIFS.uint8:
    return true
  let saved = irqSave()
  defer: irqRestore(saved)
  let env = vifMgmtEnvView()
  let vif = vifChannelForIdx(vifIdx)
  let vifEntry = cast[pointer](vif)
  let vifType = vif.vifType
  let entryEpoch = rxVifEpochs[vifIdx]
  if vifType != VIF_TYPE_STA and vifType != VIF_TYPE_AP:
    return true
  if not co_list_find(addr env.activeList, cast[ptr CoListHdr](vifEntry)):
    return true
  if vifType == VIF_TYPE_AP:
    let prepared = apmPrepareVifRemoval(vifIdx)
    # Starting an asynchronous AP stop can itself advance the RX epoch.
    if not prepared:
      return false
    if rxVifEpochs[vifIdx] != entryEpoch or vif.vifType != vifType or
        not co_list_find(addr env.activeList, cast[ptr CoListHdr](vifEntry)):
      return true

  var selected: uint8
  if not txlHaltVifQueues(vifIdx, selected): return false
  if vifType == VIF_TYPE_AP and (selected and 0x10'u8) == 0:
    if not txl_cntrl_halt_ac(4): return false
    selected = selected or 0x10'u8
  # Commit removal before any TX completion can reset/register another VIF.
  co_list_extract(addr env.activeList, cast[ptr CoListHdr](vifEntry))
  if vifType == VIF_TYPE_STA:
    dec env.staCount
  else:
    dec env.apCount
  let retiredEpoch = entryEpoch + 1'u32
  template current(): bool =
    rxVifEpochs[vifIdx] == retiredEpoch and vif.vifType == vifType and
      not co_list_find(addr env.activeList, cast[ptr CoListHdr](vifEntry)) and
      not co_list_find(addr env.freeList, cast[ptr CoListHdr](vifEntry))
  rxInvalidateQuiescentVif(vifIdx, selected)
  if not current():
    return true
  if vifType == VIF_TYPE_AP:
    if not mm_bcn_stop(vifEntry):
      # Keep an incomplete removal visible for the saved request's retry.
      if current():
        co_list_push_back(addr env.activeList, cast[ptr CoListHdr](vifEntry))
        inc env.apCount
      return false
    if not current():
      return true

  if vifType == VIF_TYPE_AP and env.apCount == 0:
    mm_hw_ap_info_reset(0)
    if not current():
      return true

  # Check if this was the last VIF (STA+AP count == 1)
  if env.staCount.uint + env.apCount.uint == 1:
    # Single VIF remaining: update RX filter and HW config
    let mm = mmEnvView()
    mm.rxFilterExtra = mm.rxFilterExtra and (not 16'u32)  # clear bit 4
    regWrite(MACHW_RX_CNTRL_REG, mm.rxFilterExtra or mm.rxFilterBase)

    # Update beacon control from remaining VIF's channel context
    let otherVifIdx = if vifIdx == 0: 1'u8 else: 0'u8
    let otherVif = vifChannelForIdx(otherVifIdx)
    if co_list_find(addr env.activeList, cast[ptr CoListHdr](otherVif)):
      let bssidLow = otherVif.currentBssid[0].uint32 or
        (otherVif.currentBssid[1].uint32 shl 8) or
        (otherVif.currentBssid[2].uint32 shl 16) or
        (otherVif.currentBssid[3].uint32 shl 24)
      let bssidHigh = otherVif.currentBssid[4].uint32 or
        (otherVif.currentBssid[5].uint32 shl 8)
      regWrite(MACHW_BASE + 0x020'u, bssidLow)
      regWrite(MACHW_BASE + 0x024'u, bssidHigh)

  # The vendor dispatches teardown by the VIF being removed.
  if vifType == VIF_TYPE_STA:
    if wpa_cbs != nil:
      let deinitFn = wpaCallbacks().deinit
      if deinitFn != nil:
        irqRestore(saved)
        try:
          cast[proc(){.cdecl.}](deinitFn)()
        finally:
          discard irqSave()
        if not current():
          return true

  mm_timer_clear(addr vif.tbttTimer)
  if not current():
    return true
  mm_timer_clear(addr vif.beaconTimeoutTimer)
  if not current():
    return true

  # Reset traffic detection for this VIF
  td_reset(vifIdx)
  if not current():
    return true

  # Zero the entire VIF entry (1512 bytes)
  discard c_memset(vifEntry, 0, VIF_ENTRY_SIZE.csize_t)

  # Reinitialize entry to free state
  vif.vifType = 4
  vif.txPower = 127
  vif.maxTxPower = 127
  # Restore bcn-timeout callback. Blob stores &vif_mgmt_bcn_to_evt.
  vif.beaconTimeoutTimer.callback = cast[pointer](vif_mgmt_bcn_to_evt)
  vif.beaconTimeoutTimer.env = pointerAddrU32(vifEntry)

  # Push entry back onto free list
  co_list_push_back(addr env.freeList, cast[ptr CoListHdr](vifEntry))
  true

proc vifReuseBipKey(param: pointer; hwKeyIdx: uint8): bool =
  let req = vifMgmtAddKeyParamView(param)
  if req == nil or req.keySlot >= MAX_VIFS.uint8 or req.cipherType != 5 or
      req.staIdx notin [4'u8, 5'u8]:
    return false
  let vif = vifChannelForIdx(req.keySlot)
  let key = vifKeySlot(vif, req.staIdx.uint)
  if key.installed == 0 or key.cipherType != 5 or key.staIdx != req.staIdx or
      key.keyIdx != hwKeyIdx or key.keyMaterial != req.ccmpKeyMaterial:
    return false
  # Re-selecting an installed key must not reset either direction's counter.
  vifKeyPointers(vif).groupKeyPtr = vifKeySlotPtr(vif, req.staIdx.uint)
  true

proc vif_mgmt_add_key*(param: pointer, hwKeyIdx: uint8) {.exportc, cdecl.} =
  ## Install one of the VIF's six keys: data slots 0..3 or BIP slots 4..5.
  ## The historical view names staIdx/keySlot hold key ID/VIF index here.
  if vifReuseBipKey(param, hwKeyIdx):
    return
  let req = vifMgmtAddKeyParamView(param)
  let vif = vifChannelForIdx(req.keySlot)
  let keyId = req.staIdx.uint
  let keyView = vifKeySlot(vif, keyId)
  # Only the eight replay counters are cleared, not the key metadata/union.
  discard c_memset(cast[pointer](keyView), 0, 128.csize_t)
  keyView.keyIdx = hwKeyIdx
  let cipherType = req.cipherType
  keyView.cipherType = cipherType
  keyView.staIdx = req.staIdx
  keyView.hasRxPn = req.hasRxPn
  keyView.pnLow = 0
  keyView.pnHigh = 0
  case cipherType
  of 0, 3:
    vifKeyPrngState = vifKeyPrngState * RC_PRNG_MULT + RC_PRNG_INCR
    keyView.pnLow = vifKeyPrngState shr 16
  of 1:
    keyView.keyMaterial = req.tkipKeyMaterial
  of 5:
    keyView.keyMaterial = req.ccmpKeyMaterial
  else: discard

  # WEP ignores the supplied receive PN. Other ciphers store the next PN or
  # pass the received PN through the window validator, as vif_mgmt.o does.
  if cipherType notin [0'u8, 3'u8]:
    let received = le32(addr req.pnLowBytes).uint64 or
      (le32(addr req.pnHighBytes).uint64 shl 32)
    # BIP's KDE IPN is an initial replay floor, including zero. Store its
    # successor so reception rejects IPNs at or below that floor.
    if received != 0 or wifiCipherIsBip(cipherType):
      if wifiKeyUsesDirectReplayPn(cipherType, req.hasRxPn):
        let nextPn = received + 1'u64
        for counter in keyView.replayCounters.mitems:
          counter.pnLow = (nextPn and 0xFFFFFFFF'u64).uint32
          counter.pnHigh = (nextPn shr 32).uint32
      else:
        for counter in keyView.replayCounters.mitems:
          discard replay_counter_validate(addr counter, received)
  keyView.installed = 1
  rxMgtReplayReset(cast[pointer](keyView))
  let keyPtrs = vifKeyPointers(vif)
  if wifiCipherIsBip(cipherType):
    keyPtrs.groupKeyPtr = vifKeySlotPtr(vif, keyId)
  else:
    keyPtrs.defaultKeyPtr = vifKeySlotPtr(vif, keyId)

proc vif_mgmt_del_key*(vifEntry: pointer, keySlot: uint8) {.exportc, cdecl, noinline.} =
  ## Invalidate the key and select the first remaining data/BIP replacement.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let vif = vifChannelAt(vifEntry)
  let keySlotU = keySlot.uint
  let keyView = vifKeySlot(vif, keySlotU)
  let keyPtrs = vifKeyPointers(vif)
  rxMgtReplayForget(cast[pointer](keyView))
  # Clear key valid flag
  keyView.installed = 0
  # Check if this was the default TX key (vif+1488)
  let defaultKeyPtr = keyPtrs.defaultKeyPtr
  var candidate = vifKeySlotPtr(vif, keySlotU)
  if defaultKeyPtr == candidate:
    # This key was the default; find replacement
    keyPtrs.defaultKeyPtr = 0
    # Scan slots 0..3 for a valid key
    for replacementKeySlotIndex in 0'u .. 3'u:
      candidate = vifKeySlotPtr(vif, replacementKeySlotIndex)
      let slotValid = vifKeySlot(vif, replacementKeySlotIndex).installed
      if slotValid != 0:
        keyPtrs.defaultKeyPtr = candidate
        return
  # Vendor retains the last data candidate if no replacement was found.
  let groupKeyPtr = keyPtrs.groupKeyPtr
  if groupKeyPtr == candidate:
    keyPtrs.groupKeyPtr = 0
    for replacementKeySlotIndex in 4'u .. 5'u:
      if vifKeySlot(vif, replacementKeySlotIndex).installed != 0:
        keyPtrs.groupKeyPtr = vifKeySlotPtr(vif, replacementKeySlotIndex)
        break

proc vif_mgmt_send_postponed_frame*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Flush the per-VIF postponed-STA list by calling
  ## sta_mgmt_send_postponed_frame on each STA entry.
  ## Blob algorithm:
  ##   s1 = a0                                   ; vifEntry
  ##   s0 = *(u32*)(vifEntry + 340)              ; postponed-STA list head
  ##   while s0 != 0:
  ##     sta_mgmt_send_postponed_frame(vifEntry, s0, 0)
  ##     s0 = *(u32*)s0                          ; next
  ## Prior Nim bug: called txl_cntrl_push_int(0, cur) — completely wrong:
  ## it would try to push STA list nodes as TX frames.
  let saved = irqSave()
  defer: irqRestore(saved)
  var vifIndex = 0'u8
  while vifIndex < MAX_VIFS.uint8 and
      cast[pointer](vifChannelForIdx(vifIndex)) != vifEntry:
    inc vifIndex
  if vifIndex >= MAX_VIFS.uint8: return
  let vif = vifChannelForIdx(vifIndex)
  let vifEpoch = rxVifEpochs[vifIndex]
  let resetEpoch = txResetEpoch
  # Snapshot identities before a completion can unlink or replace another STA.
  var owners: array[STA_INFO_TAB_ENTRIES, StaQueueIdentity]
  var count = 0
  var seen = 0'u32
  var node = vif.postponedStaHead
  while node != nil:
    var station = 0'u8
    while station < STA_INFO_TAB_ENTRIES.uint8 and
        cast[pointer](staInfoForIdx(station)) != node:
      inc station
    if station >= STA_INFO_TAB_ENTRIES.uint8 or
        (seen and (1'u32 shl station)) != 0:
      return
    seen = seen or (1'u32 shl station)
    let owner = staPostponedOwner(node)
    if not owner.vifTracked or owner.vif != vifIndex: return
    owners[count] = owner
    inc count
    node = cast[pointer](cast[ptr CoListHdr](node).next)
  for index in 0 ..< count:
    if rxVifEpochs[vifIndex] != vifEpoch or txResetEpoch != resetEpoch: return
    let owner = owners[index]
    if staPostponedOwnerCurrent(owner) and
        co_list_find(vifPostponedStaList(vif), cast[ptr CoListHdr](owner.entry)):
      discard sta_mgmt_send_postponed_frame(vifEntry, owner.entry, 0'u32)

proc vif_mgmt_reset*() {.exportc, cdecl.} =
  ## "Reset" step in the VIF-management path.
  ## Blob algorithm:
  ##   s0 = *(u32*)(vif_mgmt_env + 8)      ; head of active vif list
  ##   while s0 != 0:
  ##     vif_mgmt_send_postponed_frame(s0) ; flush postponed frames
  ##     s0 = *(u32*)s0                    ; next vif
  ## Prior Nim bug: walked the active-vif list but called
  ## vif_mgmt_entry_init (reinit fields) instead of flushing postponed frames.
  ## That would corrupt live VIF state on every reset-trigger path.
  let saved = irqSave()
  defer: irqRestore(saved)
  let resetEpoch = txResetEpoch
  let active = addr vifMgmtEnvView().activeList
  var owners: array[MAX_VIFS, tuple[index: uint8, epoch: uint32]]
  var count = 0
  var seen = 0'u32
  var node = cast[pointer](active.first)
  while node != nil:
    var index = 0'u8
    while index < MAX_VIFS.uint8 and
        cast[pointer](vifChannelForIdx(index)) != node:
      inc index
    if index >= MAX_VIFS.uint8 or (seen and (1'u32 shl index)) != 0: return
    seen = seen or (1'u32 shl index)
    owners[count] = (index, rxVifEpochs[index])
    inc count
    node = vifChannelForIdx(index).next
  for index in 0 ..< count:
    if txResetEpoch != resetEpoch: return
    let owner = owners[index]
    let vif = vifChannelForIdx(owner.index)
    if rxVifEpochs[owner.index] == owner.epoch and
        co_list_find(active, cast[ptr CoListHdr](vif)):
      vif_mgmt_send_postponed_frame(cast[pointer](vif))

proc vif_mgmt_bcn_recv*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Beacon received for a VIF.
  ## Blob algorithm:
  ##   a5 = &ps_env
  ##   a4 = *(u8*)(ps_env+0)                    ; PS active flag
  ##   if a4 == 0: return
  ##   a5 = *(u32*)(ps_env+4)                   ; PS env flags
  ##   if (a5 & 8): return
  ##   a5 = *(u32*)(a0+4)                       ; vif->linked_non_ap
  ##   if a5 != 0: return
  ##   mm_timer_clear(a0+40)                    ; kill bcn-timeout watchdog
  ##   tail-call vif_mgmt_bcn_to_evt(a0)        ; post bcn-rx event
  ## Prior Nim bug: read vif_mgmt_env (wrong global) and called
  ## vif_mgmt_bcn_to_prog (schedule next bcn timeout) instead of
  ## vif_mgmt_bcn_to_evt (post the rx-event now).
  let ps = psEnvView()
  if ps.enabled == 0:
    return
  if (ps.statusFlags and 8) != 0:
    return
  let vif = vifChannelAt(vifEntry)
  if vif.flags != 0:
    return
  mm_timer_clear(addr vif.beaconTimeoutTimer)
  vif_mgmt_bcn_to_evt(vifEntry)

proc vif_mgmt_bcn_to_prog*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Program beacon timeout for a VIF (from blob).
  ## Reads MAC timestamp, adds 10000 us (0x2710), then tail-calls
  ## mm_timer_set on the VIF's beacon timeout timer.
  let macTime = macTimeNow()
  let targetTime = macTime + 0x2710'u32  # 10000 us
  mm_timer_set(addr vifChannelAt(vifEntry).beaconTimeoutTimer, targetTime)

proc vif_mgmt_set_ap_bcn_int*(vifEntry: pointer, interval: uint16) {.exportc, cdecl.} =
  ## Set AP beacon interval for a VIF (44 instrs in blob).
  ## Stores interval at vif+322. Under interrupt protection (csrrci/csrsi),
  ## reads env AP count. If only 1 VIF: sets default divisor/multiplier.
  ## If multiple: finds min interval, updates each VIF's divisor (vif+324)
  ## and multiplier (vif+325). Writes min interval to MACHW beacon register.
  let vif = vifChannelAt(vifEntry)
  # Store this VIF's beacon interval at vif+322
  vif.apBeaconInterval = interval
  # Save and disable interrupts
  let prevIrq = irqSave()
  let env = vifMgmtEnvView()
  var minInterval = interval
  # Single VIF case
  if env.apCount <= 1:
    env.primaryApIdx = vif.vifIdx
    vif.beaconDivisor = 1
    vif.beaconCountdown = 1
  else:
    # Multiple VIFs: find the dominant (min interval) VIF
    let vifTabBase = cast[uint](addr vif_info_tab[0])
    let otherVifIdx = env.primaryApIdx
    let otherVif = vifChannelForIdx(otherVifIdx)
    let otherInt = otherVif.apBeaconInterval
    if interval < otherInt:
      env.primaryApIdx = vif.vifIdx
    else:
      minInterval = otherInt
    # Walk VIF linked list (at envBase+8) to update each VIF's beacon divisor
    var curVifPtr = cast[pointer](env.activeList.first)
    while curVifPtr != nil:
      let cv = vifChannelAt(curVifPtr)
      let cvInt = cv.apBeaconInterval
      cv.beaconCountdown = 1
      let divisor = cvInt div minInterval
      cv.beaconDivisor = divisor.uint8
      curVifPtr = cv.next
  # Write minimum interval to HW beacon interval register (lower 16 bits)
  let beaconIntervalRegValue = regRead(MACHW_BCN_INT_REG)
  let beaconIntervalRegHighHalf = beaconIntervalRegValue and 0xFFFF0000'u32
  regWrite(MACHW_BCN_INT_REG, beaconIntervalRegHighHalf or minInterval.uint32)
  # Restore interrupts
  irqRestore(prevIrq)

proc vif_mgmt_switch_channel*(vifIdx: uint8, param: pointer) {.exportc, cdecl.} =
  ## Switch channel for a VIF.
  discard

proc vif_mgmt_sta_status*(vifIdx: uint8; mac: pointer): cint {.exportc, cdecl.} =
  ## -1: no matching STA interface; 0: inactive; 1: station resources in use.
  if vifIdx >= MAX_VIFS.uint8 or mac == nil: return -1
  let saved = irqSave()
  defer: irqRestore(saved)
  let vif = vifChannelForIdx(vifIdx)
  if vif.vifType != VIF_TYPE_STA or vif.vifIdx != vifIdx or
      not co_list_find(addr vifMgmtEnvView().activeList, cast[ptr CoListHdr](vif)) or
      c_memcmp(addr vif.macAddr[0], mac, 6) != 0:
    return -1
  if vif.state == 0 and vif.staIdx == 0xFF and vif.chanCtxt == nil: 0 else: 1

proc vif_mgmt_get_vif*(vifIdx: uint8): pointer {.exportc, cdecl, noinline.} =
  ## Get VIF info pointer by index.
  ## From blob (8 instrs): if vifIdx > 1, returns null.
  ## Otherwise computes vif_info_tab + vifIdx * 1512 and returns pointer.
  if vifIdx >= MAX_VIFS.uint8:
    return nil
  return cast[pointer](vifChannelForIdx(vifIdx))

proc vif_mgmt_get_first_ap_inf*(): pointer {.exportc, cdecl.} =
  ## Get the first AP VIF info pointer.
  ## From blob (10 instrs): checks vif_mgmt_env[17] (AP VIF count).
  ## If 0, returns null. Otherwise walks VIF list from vif_mgmt_env[8],
  ## returning first entry with type == 2 (AP).
  let env = vifMgmtEnvView()
  if env.apCount == 0:
    return nil
  var activeVifListNode = cast[pointer](env.activeList.first)
  while activeVifListNode != nil:
    let vif = vifChannelAt(activeVifListNode)
    if vif.vifType == VIF_TYPE_AP:
      return activeVifListNode
    activeVifListNode = vif.next  # follow linked list next
  return nil

proc vif_mgmt_statistic_dump*() {.exportc, cdecl.} =
  ## Report active VIF beacon statistics, with a bounded pre-callback snapshot.
  type VifStatistics = object
    entry: pointer
    kind: uint8
    lost, received, tbtt, lostWindow, lastBeacon: uint32
  var entries: array[MAX_VIFS, VifStatistics]
  var count = 0
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    var node = cast[pointer](vifMgmtEnvView().activeList.first)
    while node != nil and count < entries.len:
      var repeated = false
      for index in 0 ..< count:
        if entries[index].entry == node: repeated = true
      if repeated: break
      let vif = vifChannelAt(node)
      entries[count] = VifStatistics(entry: node, kind: vif.vifType,
        lost: vif.beaconLossCount, received: vif.beaconRxCount, tbtt: vif.tbttCount,
        lostWindow: vif.beaconLossWindow, lastBeacon: vif.lastBeaconMacTime)
      inc count
      node = vif.next
  type PrintfFn = proc(fmt: cstring) {.cdecl, varargs.}
  type PutsFn = proc(s: cstring) {.cdecl.}
  template print(format: cstring; args: varargs[untyped]) =
    let output = cast[PrintfFn](blOpsFunc(4))
    if output != nil: output(format, args)
  for index in 0 ..< count:
    let vif = entries[index]
    let kind = case vif.kind
      of VIF_TYPE_AP: cstring("AP")
      of VIF_TYPE_STA: cstring("STA")
      else: cstring("Unknown")
    print("======== Vif %p: %s========\r\n", vif.entry, kind)
    if vif.kind == VIF_TYPE_STA:
      print("    bcn_timeout:%lu\r\n", vif.lost.culong)
      print("    bcn_received:%lu\r\n", vif.received.culong)
      print("    bcn_received && timeout counter:%lu\r\n", (vif.lost + vif.received).culong)
      print("    bcn_tbtt counter:%lu\r\n", vif.tbtt.culong)
      print("    bcn_lost_max_interval:%ldms\r\n", (vif.lostWindow shr 10).clong)
      print("    bcn_last_received:%lums\r\n", (vif.lastBeacon shr 10).culong)
    let puts = cast[PutsFn](blOpsFunc(8))
    if puts != nil: puts("------------------------------------\r\n")
