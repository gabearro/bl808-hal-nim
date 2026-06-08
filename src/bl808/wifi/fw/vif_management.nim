# ###########################################################################
#                  VIF Management (vif_mgmt_*)
# ###########################################################################

proc vif_mgmt_entry_init*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Initialize a VIF entry to default state.
  ## Sets vifType=4 (free), vifIdx/instNbr=127, clears chan_ctxt and lists.
  let vif = vifChannelAt(vifEntry)
  vif.vifType = 4
  vif.txPower = 127
  vif.maxTxPower = 127
  vif.chanCtxt = nil

proc vif_mgmt_add_to_list*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Add VIF entry to the active VIF list and notify platform.
  ## Placeholder: sends notification to platform layer.
  discard

proc vif_mgmt_init*() {.exportc, cdecl.} =
  ## Initialize VIF management.
  ## From blob (67 instrs): zeroes vif_mgmt_env, inits two CoLists (free + active),
  ## zeroes both VIF entries (1512 bytes each), sets default fields, pushes both
  ## entries onto the free list, then tail-calls co_list_push_back for the second.
  let env = vifMgmtEnvView()
  let vifTabBase = cast[uint](addr vif_info_tab[0])

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
  let env = vifMgmtEnvView()
  # Check if VIF management is initialized (vif_mgmt_env[0] = list head)
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
  let entry = co_list_pop_front(addr env.freeList)
  if entry == nil:
    return 1
  let vifEntry = cast[pointer](entry)
  let vif = vifChannelAt(vifEntry)
  # Set VIF type
  vif.vifType = vifType
  # Copy MAC address (6 bytes) to vif+80
  discard c_memcpy(cast[pointer](addr vif.macAddr[0]), macAddr, 6.csize_t)
  # Find the popped VIF in the typed table.
  var vifIdx = 0'u8
  while vifIdx < MAX_VIFS.uint8 and vifChannelForIdx(vifIdx) != vif:
    inc vifIdx
  if vifIdx >= MAX_VIFS.uint8:
    return 1
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
    vif.reserved192[0] = 0
    vif.reserved192[1] = 0
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
  vifIdxOut[] = vifIdx
  co_list_push_back(addr env.activeList, cast[ptr CoListHdr](vifEntry))
  return 0

proc vif_mgmt_unregister*(vifIdx: uint8) {.exportc, cdecl.} =
  ## Unregister a VIF (111 instrs).
  ## From blob: removes VIF from active list, decrements STA/AP count,
  ## clears timers, resets TD, zeroes the VIF entry, reinitializes to free
  ## state, pushes back onto free list, then tail-calls co_list_push_back.
  let env = vifMgmtEnvView()
  let vif = vifChannelForIdx(vifIdx)
  let vifEntry = cast[pointer](vif)

  # Remove VIF from active list
  co_list_extract(addr env.activeList, cast[ptr CoListHdr](vifEntry))

  # Check VIF type and decrement appropriate counter
  let vifType = vif.vifType
  if vifType == VIF_TYPE_STA:
    # Decrement STA count
    env.staCount = env.staCount - 1
  elif vifType == VIF_TYPE_AP:
    # Decrement AP count
    let newApCnt = env.apCount - 1
    env.apCount = newApCnt
    if newApCnt == 0:
      # Last AP removed: reset HW AP info
      mm_hw_ap_info_reset(0)

  # Check if this was the last VIF (STA+AP count == 1)
  if env.staCount.uint + env.apCount.uint == 1:
    # Single VIF remaining: update RX filter and HW config
    let mm = mmEnvView()
    mm.rxFilterExtra = mm.rxFilterExtra and (not 16'u32)  # clear bit 4
    regWrite(MACHW_RX_CNTRL_REG, mm.rxFilterExtra or mm.rxFilterBase)

    # Update beacon control from remaining VIF's channel context
    let otherVifIdx = if vifIdx == 0: 1'u8 else: 0'u8
    let otherVif = vifChannelForIdx(otherVifIdx)
    let bssidLow = otherVif.currentBssid[0].uint32 or
      (otherVif.currentBssid[1].uint32 shl 8) or
      (otherVif.currentBssid[2].uint32 shl 16) or
      (otherVif.currentBssid[3].uint32 shl 24)
    let bssidHigh = otherVif.currentBssid[4].uint32 or
      (otherVif.currentBssid[5].uint32 shl 8)
    regWrite(MACHW_BASE + 0x020'u, bssidLow)
    regWrite(MACHW_BASE + 0x024'u, bssidHigh)

  # Check if WPA deinit callback should be called (for STA type)
  var scanIdx: uint8 = 0
  while scanIdx < MAX_VIFS.uint8:
    let scanType = vifChannelForIdx(scanIdx).vifType
    if scanType == VIF_TYPE_STA:
      break
    scanIdx += 1

  if scanIdx >= MAX_VIFS.uint8:
    # No STA VIFs left: call WPA deinit
    if wpa_cbs != nil:
      let deinitFn = wpaCallbacks().deinit
      if deinitFn != nil:
        cast[proc(){.cdecl.}](deinitFn)()

  # Check for AP beacon clear
  let otherVifType = vifChannelForIdx(if vifIdx == 0: 1'u8 else: 0'u8).vifType
  if otherVifType == VIF_TYPE_AP:
    txl_cntrl_clear_bcn_ac()

  mm_timer_clear(addr vif.tbttTimer)
  mm_timer_clear(addr vif.beaconTimeoutTimer)

  # Reset traffic detection for this VIF
  td_reset(vifIdx)

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

proc vif_mgmt_add_key*(param: pointer, hwKeyIdx: uint8) {.exportc, cdecl.} =
  ## Add encryption key for a VIF (185 instructions).
  ##
  ## Blob ABI: a0=56-byte key parameter, a1=hardware key index.
  ##
  ## param layout (byte offsets from disassembly -- same as mm_sec_machwkey_wr param):
  ##   [0]   u8: staIndex / MAC address index
  ##   [8..23]  key material
  ##   [24..39] RX PN / TKIP MIC key (6 x 32-bit words at [24..47])
  ##   [44..51] TX/RX sequence counters (2 x 32-bit words)
  ##   [52]  u8: cipherType (0=WEP40, 1=TKIP, 3=WEP104, 5=CCMP)
  ##   [53]  u8: keyIdx / VIF slot selector
  ##   [54]  u8: spp
  ##   [55]  u8: has_rx_pn flag
  ##
  ## VIF entry layout (stride = 1512 = 0x5E8 bytes):
  ##   +528 (0x210): start of per-key entries (8 entries, 16 bytes each = 128 bytes)
  ##   +656 (0x290): per-key PN low
  ##   +660 (0x294): per-key PN high
  ##   +664 (0x298): key material (4 x 32-bit words)
  ##   +680 (0x2A8): cipher type
  ##   +681 (0x2A9): sta index
  ##   +682 (0x2AA): keyIdx (key slot HW index written by mm_sec_machwaddr_wr)
  ##   +683 (0x2AB): key installed flag
  ##   +684 (0x2AC): has_rx_pn flag
  ##   +1488 (0x5D0): default key material pointer
  ##   +1492 (0x5D4): group key material pointer
  ##   +1496 (0x5D8): VIF flags

  let req = vifMgmtAddKeyParamView(param)
  let keySlot = req.keySlot  # s7 in blob = keyIdx field from param
  let staIdx = req.staIdx    # s9

  let vif = vifChannelForIdx(keySlot)
  let keyView = vifKeySlot(vif, 0)

  # Zero the per-key context area at vif+528, 128 bytes before populating the
  # metadata fields. Clearing after these stores erases cipher/key identity and
  # leaves group-key RX unable to resolve protected broadcast frames.
  discard c_memset(cast[pointer](keyView), 0, 128.csize_t)

  # Store hardware key index from a1 to vif+682.
  keyView.keyIdx = hwKeyIdx

  # Copy cipher type from param[34] to vif+680
  let cipherType = req.cipherType
  keyView.cipherType = cipherType

  # Copy sta index from param[0] to vif+681
  keyView.staIdx = req.staIdx

  # Copy has_rx_pn from param[37] to vif+684
  let hasRxPn = req.hasRxPn
  keyView.hasRxPn = hasRxPn

  # Dispatch on cipher type
  case cipherType
  of 0, 3:
    # WEP40 / WEP104: generate random PN, store to vif+656/660
    # Uses LCG PRNG: next = state * 0x41C64E6D + 0x3039
    let oldState = rcPrngState
    rcPrngState = oldState * RC_PRNG_MULT + RC_PRNG_INCR
    let newState = rcPrngState
    let pnLo = (newState shr 16).uint32  # top 16 bits as low PN
    keyView.pnLow = pnLo
    keyView.pnHigh = 0

  of 1:
    # TKIP: zero PN, copy 6 key material words from param[24..47]
    keyView.pnLow = 0
    keyView.pnHigh = 0
    discard c_memcpy(addr keyView.keyMaterial[0],
                     vifMgmtAddKeyTkipMaterialPtr(req), 16.csize_t)

  of 5:
    # CCMP: copy 16 bytes of key material from param[8..23] to vif+664
    discard c_memcpy(addr keyView.keyMaterial[0],
                     addr req.ccmpKeyMaterial[0], 16.csize_t)
    # Zero PN
    keyView.pnLow = 0
    keyView.pnHigh = 0

  else:
    # Unknown cipher: zero PN and clear key context
    keyView.pnLow = 0
    keyView.pnHigh = 0

  # Read TX/RX sequence counters from param[44..51] (PN from host)
  let pnLo = le32(addr req.pnLowBytes)
  let pnHi = le32(addr req.pnHighBytes)

  if (pnLo or pnHi) != 0:
    # Host provided a non-zero PN; check if has_rx_pn and cipher != CCMP
    let curCipher = keyView.cipherType
    let curHasRxPn = keyView.hasRxPn
    if curHasRxPn == 0 or curCipher == 5:
      # Broadcast PN: replicate to all 8 key context slots
      # Clear installed flag (will set below)
      keyView.installed = 0
      var i = 0
      while i < 8:
        keyView.replayCounters[i].pnLow = pnLo
        keyView.replayCounters[i].pnHigh = pnHi
        inc i
    else:
      # Unicast PN: write to per-STA rx reorder context
      # staIdx * 10 + 33, shifted left 4, offset from the VIF entry.
      let staReplay = vifKeySlot(vif, staIdx.uint)
      var i = 0
      while i < 8:
        staReplay.replayCounters[i].pnLow = pnLo
        staReplay.replayCounters[i].pnHigh = pnHi
        inc i

  # Validate replay counter before marking key installed
  # Blob calls replay_counter_validate at reloc 0x214 with key PN context
  let pnCtx = cast[pointer](keyView)
  if replay_counter_validate(pnCtx):
    # Mark key as installed only if replay counter validates
    keyView.installed = 1

  # If cipher type is CCMP, update the CCMP key material pointer
  let installedCipher = keyView.cipherType
  let keyPtrs = vifKeyPointers(vif)
  if installedCipher == 5:
    # Store pointer to key context base in vif+1492
    keyPtrs.groupKeyPtr = vifKeySlotPtr(vif, 0)
  else:
    # Store to vif+1480 (default key pointer)
    keyPtrs.defaultKeyPtr = vifKeySlotPtr(vif, 0)

proc vif_mgmt_del_key*(vifEntry: pointer, keySlot: uint8) {.exportc, cdecl, noinline.} =
  ## Delete encryption key for a VIF (35 instrs).
  ## noinline: blob calls this from mm_sec_machwkey_del.
  ## From blob: a0=vifEntry pointer, a1=keySlot index.
  ## Computes key context offset = keySlot * 160 + 528 within VIF entry.
  ## Clears the key valid flag at vif[keyOffset + 675-520] = vif[keySlot*160+675].
  ## Then checks if vif+1488 (default TX key ptr) points to this key context.
  ## If so, scans other key slots (0..3) for a valid key to replace it.
  ## If no valid key found, clears vif+1488. Similarly checks vif+1492 (group key).
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let vif = vifChannelAt(vifEntry)
  let keySlotU = keySlot.uint
  let keyView = vifKeySlot(vif, keySlotU)
  let keyPtrs = vifKeyPointers(vif)
  # Clear key valid flag
  keyView.installed = 0
  # Check if this was the default TX key (vif+1488)
  let defaultKeyPtr = keyPtrs.defaultKeyPtr
  let thisKeyBase = vifKeySlotPtr(vif, keySlotU)
  if defaultKeyPtr == thisKeyBase:
    # This key was the default; find replacement
    keyPtrs.defaultKeyPtr = 0
    # Scan slots 0..3 for a valid key
    for i in 0'u .. 3'u:
      let slotValid = vifKeySlot(vif, i).installed
      if slotValid != 0:
        keyPtrs.defaultKeyPtr = vifKeySlotPtr(vif, i)
        break
  # Check group key pointer (vif+1484)
  let groupKeyPtr = keyPtrs.groupKeyPtr
  if groupKeyPtr == thisKeyBase:
    # Scan for replacement group key
    let validFlag = vifKeySlot(vif, keySlotU + 4'u).installed
    if validFlag == 0:
      keyPtrs.groupKeyPtr = 0

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
  let vif = vifChannelAt(vifEntry)
  var cur = vif.postponedStaHead
  while cur != nil:
    let next = cast[pointer](cast[ptr CoListHdr](cur).next)
    discard sta_mgmt_send_postponed_frame(vifEntry, cur, 0'u32)
    cur = next

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
  var cur = cast[pointer](vifMgmtEnvView().activeList.first)
  while cur != nil:
    let next = vifChannelAt(cur).next
    vif_mgmt_send_postponed_frame(cur)
    cur = next

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
  let curVal = regRead(MACHW_BCN_INT_REG)
  let masked = curVal and 0xFFFF0000'u32
  regWrite(MACHW_BCN_INT_REG, masked or minInterval.uint32)
  # Restore interrupts
  irqRestore(prevIrq)

proc vif_mgmt_switch_channel*(vifIdx: uint8, param: pointer) {.exportc, cdecl.} =
  ## Switch channel for a VIF.
  discard

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
  var entry = cast[pointer](env.activeList.first)
  while entry != nil:
    let vif = vifChannelAt(entry)
    if vif.vifType == VIF_TYPE_AP:
      return entry
    entry = vif.next  # follow linked list next
  return nil

proc vif_mgmt_statistic_dump*() {.exportc, cdecl.} =
  ## Dump VIF statistics for debugging (92 instrs).
  ## Walks the VIF linked list (from vif_mgmt_env), for each VIF:
  ##   logs VIF type (STA/AP), RX/TX packet counts, beacon counts.
  ## Uses g_bl_ops_funcs[4] (printf) and g_bl_ops_funcs[8] (puts) for output.
  ##
  ## Assembly trace:
  ##   s0 = vif list head (from vif_mgmt_env)
  ##   s1 = g_bl_ops_funcs base
  ##   s4 = 2 (AP type constant for comparison)
  ##   s5..s9 = format string pointers for each field
  ##   Loop while s0 != nil:
  ##     check vif.type(+86): print "AP" or "STA" via printf
  ##     if STA: print rx_count(+124), tx_count(+128), total, beacon_cnt(+120),
  ##       beacon_period(+132 >> 10), last_beacon(+136 >> 10)
  ##     print separator via puts
  ##     s0 = vif.next(+0)
  var vifPtr = cast[pointer](vifMgmtEnvView().freeList.first)  # linked list head
  let printFnPtr = blOpsFunc(4)
  let putsFnPtr = blOpsFunc(8)
  if printFnPtr == nil or putsFnPtr == nil:
    return
  type PrintfFn = proc(fmt: cstring, args: uint32) {.cdecl, varargs.}
  type PutsFn = proc(s: cstring) {.cdecl.}
  let printf = cast[PrintfFn](printFnPtr)
  let puts = cast[PutsFn](putsFnPtr)
  while vifPtr != nil:
    let vif = vifChannelAt(vifPtr)
    if vif.vifType == VIF_TYPE_AP:
      printf("VIF[AP] %p:", cast[uint32](vifPtr))
    else:
      printf("VIF[STA] %p:", cast[uint32](vifPtr))
    if vif.vifType == VIF_TYPE_STA:
      let rxCount = vif.beaconLossCount
      printf(" rx=%d", rxCount)
      let txCount = vif.beaconRxCount
      printf(" tx=%d", txCount)
      printf(" total=%d", rxCount + txCount)
      printf(" bcn=%d", vif.tbttCount)
      printf(" period=%d", vif.beaconLossWindow shr 10)
      printf(" last=%d", vif.lastBeaconMacTime shr 10)
    puts("")
    # Follow linked list
    vifPtr = vif.next

