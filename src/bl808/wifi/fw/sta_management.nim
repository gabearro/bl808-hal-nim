# ###########################################################################
#                  STA Management (sta_mgmt_*)
# ###########################################################################

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
  var idx = 0'u8
  while idx < STA_MGMT_FREE_STAS.uint8:
    let sta = staInfoForIdx(idx)
    sta_mgmt_entry_init(cast[pointer](sta))
    co_list_push_back(addr sta_info_env, cast[ptr CoListHdr](sta))
    inc idx

  # Initialize broadcast STA entry for VIF 0.
  let bcStaVif0 = staInfoForIdx(STA_MGMT_FREE_STAS.uint8)
  sta_mgmt_entry_init(cast[pointer](bcStaVif0))
  bcStaVif0.instNbr = 0
  bcStaVif0.rxNss = 0
  bcStaVif0.txPolicy = cast[pointer](txBufferControlBcmcDescAt(0))
  bcStaVif0.keyMat = cast[pointer](vifKeyPointers(vifChannelForIdx(0)))
  # Log
  let logFn = getLogFunc(204)
  if logFn != nil:
    cast[proc(a0: uint32, a1: uint32, a2: pointer, a3: uint32, a4: uint32){.cdecl.}](logFn)(
      2, 0, nil, 157, 157)

  # Initialize broadcast STA entry for VIF 1.
  let bcStaVif1 = staInfoForIdx(STA_MGMT_FREE_STAS.uint8 + 1'u8)
  sta_mgmt_entry_init(cast[pointer](bcStaVif1))
  bcStaVif1.instNbr = 1
  bcStaVif1.rxNss = 0
  bcStaVif1.txPolicy = cast[pointer](txBufferControlBcmcDescAt(1))
  bcStaVif1.keyMat = cast[pointer](vifKeyPointers(vifChannelForIdx(1)))
  # Final log via g_bl_ops_funcs
  let logFn2 = getLogFunc(204)
  if logFn2 != nil:
    cast[proc(a0: uint32, a1: uint32, a2: pointer, a3: uint32, a4: uint32){.cdecl.}](logFn2)(
      2, 0, nil, 157, 157)

proc sta_mgmt_register*(param: pointer, staIdxOut: ptr uint8): uint8 {.exportc, cdecl.} =
  ## Register a station (126 instrs).
  ## From blob: pops free STA entry from sta_info_env list via co_list_pop_front,
  ## copies MAC addr/rates/caps from param, computes staIdx via pointer arithmetic,
  ## initializes postponed descriptor halfwords to 0xFFFF, links RC stats pointer,
  ## clears postponed flag, checks VIF HT flags, logs, links STA to VIF list.
  let req = staMgmtRegisterParamView(param)
  let instNbr = req.instNbr
  # Pop free STA entry from sta_info_env free list
  let entry = co_list_pop_front(addr sta_info_env)
  if entry == nil:
    return 1
  let staEntry = cast[uint](entry)
  let sta = staInfoAt(staEntry)
  # Copy MAC address (6 bytes) from param+6 to staEntry+4
  discard c_memcpy(cast[pointer](addr sta.macAddr[0]),
                   cast[pointer](addr req.macAddr[0]), 6.csize_t)
  # Set phy_bw_max (clamped to >= 16)
  var phyBwMax = req.phyBwMax
  if phyBwMax < 16: phyBwMax = 16
  sta.phyBwMax = phyBwMax
  # Copy rates and capability fields
  sta.rateSet = req.rateSet
  sta.vif = req.vif
  sta.instNbr = instNbr
  sta.extFlag = req.extFlag
  sta.registerWord0 = req.registerWord0
  sta.registerWord1 = req.registerWord1
  sta.paramFlag = req.paramFlag
  # Find the popped STA in the typed table.
  var staIdx = 0'u8
  while staIdx < STA_MGMT_FREE_STAS.uint8 and staInfoForIdx(staIdx) != sta:
    inc staIdx
  if staIdx >= STA_MGMT_FREE_STAS.uint8:
    return 1
  staIdxOut[] = staIdx
  sta.infoIdx = staIdx
  # Initial rate config
  sta.initialRateConfig = 0x19000'u32
  sta.supportedRatesBitmap = 0xFFFF'u16
  # Initialize postponed frame descriptors: 9 halfwords at sta+338 stride 4, set to 0xFFFF
  var descAddr = staEntry + 338
  for i in 0 ..< 9:
    cast[ptr uint16](descAddr)[] = 0xFFFF'u16
    descAddr += 4
  for tid in 0'u8 .. 8'u8:
    rxuQosSeqCachePtr(tid)[] = 0xFFFF'u16
  # Store TX policy descriptor pointer at sta+320.
  # Vendor uses one 60-byte txl_buffer_control_desc entry per STA; rc_init
  # later writes the RC stats pointer at sta+324.
  sta.txPolicy = cast[pointer](txBufferControlDescAt(staIdx.int))
  # Clear postponed flag at sta+72
  sta.trafficFlags = 0
  let vif = vifChannelForIdx(instNbr)
  let keyPtrs = vifKeyPointers(vif)
  # Check VIF HT flags at vif+1496
  let vifFlags = keyPtrs.flags
  let logFn = getLogFunc(204)
  if (vifFlags and 8) != 0:
    # HT-capable VIF: postponed list self-pointer at sta+240
    sta.keyMat = cast[pointer](addr sta.keyHolder)
    if logFn != nil:
      cast[proc(a0, a1: uint32, c: pointer, d, e: uint32){.cdecl.}](logFn)(2, 0, nil, 282, 282)
  else:
    # Non-HT VIF: point to VIF key material area at vif+1488
    sta.keyMat = cast[pointer](keyPtrs)
    if logFn != nil:
      cast[proc(a0, a1: uint32, c: pointer, d, e: uint32){.cdecl.}](logFn)(2, 0, nil, 293, 293)
  # Check HT extended flags (bit 4 at vif+1496)
  let vifFlags2 = keyPtrs.flags
  if (vifFlags2 and 16) != 0:
    sta.capabilityFlags = sta.capabilityFlags or 8
  # Push STA onto the VIF's postponed-STA list.
  co_list_push_back(vifPostponedStaList(vif), cast[ptr CoListHdr](staEntry))
  # Mark station as active
  sta.valid = 1
  return 0

proc sta_mgmt_unregister*(staIdx: uint8) {.exportc, cdecl.} =
  ## Unregister a station (29 instrs).
  ## From blob: computes STA entry = sta_info_tab + staIdx*368 (using custom mul insn),
  ## looks up VIF entry from STA's instNbr (offset 39) * 1512,
  ## calls co_list_extract to remove STA from VIF's STA list (at vif+340),
  ## calls sta_mgmt_entry_init to reset the STA entry,
  ## then pushes back to sta_info_env free list via co_list_push_back.
  let sta = staInfoForIdx(staIdx)
  let instNbr = sta.instNbr
  # Extract STA from VIF's STA list
  let vif = vifChannelForIdx(instNbr)
  co_list_extract(vifPostponedStaList(vif), cast[ptr CoListHdr](sta))
  # Re-initialize the STA entry (clears all fields)
  sta_mgmt_entry_init(cast[pointer](sta))
  # Push back to free list
  co_list_push_back(addr sta_info_env, cast[ptr CoListHdr](sta))

proc sta_mgmt_add_key*(param: pointer, hwKeyIdx: uint8) {.exportc, cdecl.} =
  ## Add encryption key for a station (81 instrs).
  ## Blob ABI: a0 = key parameter struct, a1 = hardware key index.
  ##
  ## Assembly trace:
  ##   s4 = param[1] (STA index from param)
  ##   s0 = STA_ENTRY_SIZE(368) * s4 (offset into sta_info_tab)
  ##   s1 = param pointer
  ##   s2 = sta_info_tab base
  ##   Stores a1 at sta[234] (key HW index)
  ##   Stores param[52] at sta[232] (key type: 0=none, 1=CCMP, 3=TKIP)
  ##   Stores param[0] at sta[233] (key cipher suite)
  ##   Stores param[55] at sta[236] (key flags)
  ##   memset(sta+80, 0, 128) -- clear key material area
  ##   Dispatches on key type:
  ##     type 1 (CCMP): clear PN (sta+208..215), copy 16-byte key from param+24..39 to sta+208
  ##     type 3 (TKIP): generate PRNG-based IV, store at sta+208..215
  ##   Sets sta[235] = 1 (key installed), sta[240] = ptr to sta+80 (key material)
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
  # Clear key material area (sta+80, 128 bytes)
  discard c_memset(cast[pointer](addr sta.keyArea[0]), 0, 128.csize_t)
  # Dispatch on key type
  case keyType
  of 1, 2:
    # CCMP: clear PN, copy key from param+24. The supplicant set_key path
    # passes translated cipher 2, while the vendor branch also accepts the
    # CCMP table value 1.
    sta.pnLow = 0
    sta.pnHigh = 0
    # Copy 16-byte temporal key from param+24 to sta+128+88. Blob inlines
    # the word-by-word copy (4 x 4-byte loads+stores); Nim previously
    # used two memcpy calls that aren't in blob's call graph.
    let keySrcU = cast[uint](machwKeyWriteKeyTailPtr(req))
    let keyDstU = cast[uint](addr sta.keyTail[0])
    for i in 0 ..< 4:
      cast[ptr uint32](keyDstU + (i * 4).uint)[] =
        cast[ptr uint32](keySrcU + (i * 4).uint)[]
  of 3:
    # TKIP: generate random IV using PRNG
    let rng = rcPrngNext()
    sta.pnLow = (rng shr 16).uint32
    sta.pnHigh = 0
  else:
    # Unknown type: clear PN
    sta.pnLow = 0
    sta.pnHigh = 0
  # Mark key as installed
  sta.keyInstalled = 1
  # Store pointer to key material
  sta.keyHolder = cast[pointer](addr sta.keyArea[0])
  nimFwDbgStaAddKeyPtrs1 = pointerAddrU32(sta.keyMat)
  nimFwDbgStaAddKeyPtrs2 = pointerAddrU32(sta.keyHolder)

proc sta_mgmt_del_key*(staIdx: uint8, keyIdx: uint8) {.exportc, cdecl.} =
  ## Delete encryption key for a station.
  ## From blob (4 instrs): a0 is treated as a sta_info_tag POINTER (not index).
  ## Clears key state: sta[235]=0, sta[240]=0, sta[72]=1.
  ## NOTE: blob takes pointer in a0; Nim signature has staIdx but callers may
  ## pass either. We handle both by checking if a0 looks like a pointer vs index.
  let staPtr = if staIdx.uint32 > MAX_STAS.uint32:
    # Likely a pointer was passed (C ABI caller)
    cast[uint](staIdx)
  else:
    # Index: compute pointer
    cast[uint](addr sta_info_tab[0]) + staIdx.uint * STA_ENTRY_SIZE.uint
  let sta = staInfoAt(staPtr)
  sta.keyInstalled = 0
  sta.keyHolder = nil
  sta.rxNss = 1

proc sta_mgmt_send_postponed_frame*(vifEntry: pointer, staEntry: pointer, maxCount: uint32): uint32 {.exportc, cdecl.} =
  ## Send postponed frames for a station (full loop with ~100 instrs).
  ## From blob: checks VIF PS mode flags (vif+91), sets ke_env PS bits and
  ## calls ke_evt_set(256) if PS active. Then loops: loads postponed desc from
  ## sta+356, checks txl_cntrl_tx_check, apm_tx_int_ps_check,
  ## apm_tx_int_ps_get_postpone. If no postpone, calls co_list_pop_front to
  ## dequeue. Clears desc+217, pushes via txl_cntrl_push_int, decrements
  ## txl_frame_env+16 counter. Loops until maxCount or list empty. Finally
  ## calls sta_mgmt_postponed_desc_release.
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
    elif vifType != VIF_TYPE_STA:
      # Other mode: set bit 0 in ke_env+28 and set ke_env+31 = 1
      ps.flags = ps.flags or 1
      ps.otherPending = 1
  # Signal TX event
  ke_evt_set(256)
  # Walk postponed descriptor list
  var count: uint32 = 0
  let frameEnv = txFrameEnv()
  while sta.postponedList.first != nil and (maxCount == 0 or count < maxCount):
    let head = sta.postponedList.first
    # Check TX allowed
    let txOk = txl_cntrl_tx_check(vifEntry)
    if not txOk:
      break
    # Check PS state for this frame
    let psOk = apm_tx_int_ps_check(cast[pointer](head))
    if not psOk:
      break
    # Get postpone info
    var postponeFlag: uint32 = 0
    let desc = apm_tx_int_ps_get_postpone(vifEntry, staEntry, addr postponeFlag)
    if postponeFlag != 0:
      break
    var frameDesc: pointer
    if desc != nil:
      frameDesc = desc
    else:
      # Pop from the list
      frameDesc = cast[pointer](co_list_pop_front(addr sta.postponedList))
    # Process the frame
    let txDesc = hostTxDescAt(frameDesc)
    let tid = txDesc.staIdx
    txDesc.postponeFlag = 0
    count += 1
    # Push to TX control
    discard txl_cntrl_push_int(frameDesc, tid)
    # Decrement global postponed count in txl_frame_env+16
    if frameEnv.postponedCount > 0:
      frameEnv.postponedCount = frameEnv.postponedCount - 1
  # Release remaining postponed descriptors
  discard sta_mgmt_postponed_desc_release(staEntry, 0)
  return count

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
  discard sta_mgmt_postponed_desc_release(staEntry, 1'u32)
  discard c_memset(staEntry, 0, 368.csize_t)
  staInfoAt(staEntry).instNbr = 0xFF'u8

proc sta_mgmt_postponed_desc_release*(staEntry: pointer, flag: uint32): uint32 {.exportc, cdecl.} =
  ## Release postponed descriptors for a station entry (58 instrs).
  ## From blob: walks the postponed frame list at sta+356. For each frame:
  ##   - If flag != 0: releases all frames unconditionally.
  ##   - If flag == 0: checks MAC timestamp against frame[84] (TX time).
  ##     If (macTime - txTime) > 0x1D4C0 (~120000 ticks = 120ms), releases frame.
  ##     Otherwise keeps it.
  ## Released frames are freed via keFreeFunc. Returns count of released frames.
  let sta = staInfoAt(staEntry)
  var released: uint32 = 0
  var prev: pointer = nil
  let macTime = regRead(MACHW_TIMLO_REG)
  let maxAge = 0x1D4C0'u32  # ~120ms in MAC ticks
  let frameEnv = txFrameEnv()
  var cur = cast[pointer](sta.postponedList.first)
  while cur != nil:
    if not wifiRamPointer(cur):
      inc nimFwDbgPostponedRelease
      nimFwDbgPostponedReleaseDesc = pointerAddrU32(cur)
      nimFwDbgPostponedReleaseCb = 0xFFFFFFFF'u32
      nimFwDbgPostponedReleaseFc = 0xFFFFFFFF'u32
      nimFwDbgPostponedReleaseFlags = flag or 0x80000000'u32
      if prev == nil:
        sta.postponedList.first = nil
      else:
        cast[ptr CoListHdr](prev).next = nil
      sta.postponedList.last = cast[ptr CoListHdr](prev)
      frameEnv.postponedCount = 0
      break
    let txDesc = hostTxDescAt(cur)
    let next = cast[pointer](cast[ptr CoListHdr](cur).next)
    var doRelease = false
    if flag != 0:
      doRelease = true
    else:
      # Check age: frame TX timestamp at offset 84
      let txTime = txDesc.pendingMacTime
      let age = macTime - txTime
      if age > maxAge:
        doRelease = true
    if doRelease:
      # Remove from postponed list (blob: co_list_remove)
      co_list_remove(addr sta.postponedList, cast[ptr CoListHdr](prev), cast[ptr CoListHdr](cur))
      inc nimFwDbgPostponedRelease
      nimFwDbgPostponedReleaseDesc = pointerAddrU32(cur)
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
      # Release expired/off-channel descriptors without invoking upper-layer
      # completion. The SDK passes doCallback=1 here, but our pure-Nim path can
      # age descriptors whose callback storage was already invalidated by prior
      # host/firmware recycling. Keeping callback dispatch out of the scavenger
      # preserves the descriptor-pool invariant while normal TX confirmations
      # still use txl_frame_evt for valid callbacks.
      {.emit: ["asm volatile(\"mv a1, zero\" ::: \"a1\");"].}
      txl_frame_release(cur)
      if frameEnv.postponedCount > 0:
        frameEnv.postponedCount = frameEnv.postponedCount - 1
      released += 1
    else:
      prev = cur
    cur = next
  return released

proc sta_mgmt_aging_postponed_desc*(staEntry: pointer, maxCount: uint32): uint32 {.exportc, cdecl.} =
  ## Age postponed frame descriptors (25 instrs).
  ## From blob: iterates all entries physically present in sta_info_tab
  ## (7 entries, 368 bytes each), calling sta_mgmt_postponed_desc_release(staEntry, 0).
  ## Accumulates total released count. Returns total.
  var total: uint32 = 0
  for i in 0'u8 ..< STA_INFO_TAB_ENTRIES.uint8:
    let sta = staInfoForIdx(i)
    let released = sta_mgmt_postponed_desc_release(cast[pointer](sta), 0)
    total += released
  return total

