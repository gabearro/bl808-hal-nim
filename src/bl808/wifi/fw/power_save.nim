# ###########################################################################
#                  PS: Power Save
# ###########################################################################

proc ps_init*() {.exportc, cdecl.} =
  ## Initialize power save module.
  ## From disassembly: memset(ps_env, 0, 56), then stores two timer callback
  ## function pointers:
  ##   ps_env[4] (byte offset 16) = ptr to ps_uapsd_timer_handle
  ##   ps_env[10] (byte offset 40) = ptr to ps_tx_null_timer_handle
  mmPsModeCancel()
  let ps = psEnvView()
  discard c_memset(ps, 0, sizeof(PsEnvView).csize_t)
  # Store timer callback function pointers (blob: ps_env[16] and ps_env[40])
  ps.uapsdTimerCallback = cast[pointer](ps_uapsd_timer_handle)
  ps.txNullTimerCallback = cast[pointer](ps_tx_null_timer_handle)

proc ps_set_mode*(mode: uint8, requesterTask: uint8 = TASK_API.uint8) {.exportc, cdecl.} =
  ## Set power save mode (115 instructions in blob).
  ##
  ## Register map: s0=ps_env s1=VIF list (from chan_env) s2=mode s3=chan_env s4=1
  ## Stores requester task at ps_env+1. Checks ps_env+52 (flags):
  ##   if (flags & 1) && (flags & 6): deferred -- set bit 4, store at +53, return.
  ## mode==0: clear ps flag, clear MACHW CCA bit 2, walk VIFs
  ## mode==2: log line 702, set bit 0 in ps_env+52
  ## mode!=0: set MACHW CCA bit 2, walk VIFs
  ## VIF walk: for each STA VIF with connless!=0: call ps_check and update counter.
  let ps = psEnvView()
  ps.mode = requesterTask

  # Check deferred flags at ps_env+52
  let flags52 = ps.flags
  if (flags52 and 1) != 0:
    if (flags52 and 6) != 0:
      ps.flags = flags52 or 0x10
      ps.deferredMode = mode
      return

  if mode == 0:
    # Disable PS: clear transition flags and clear MACHW bit.
    ps.flags = 0
    let machwPowerControl = volatileLoad(cast[ptr uint32](0x24B0004C'u32))
    volatileStore(cast[ptr uint32](0x24B0004C'u32), machwPowerControl and not 4'u32)
  else:
    if mode == 2:
      # Deep sleep: log at line 702, set enable flag bit 0
      let logFn = getLogFunc(204)
      if logFn != nil:
        type LP = proc(level: uint32, tag, file: cstring, line: cint,
                       format: cstring) {.cdecl, varargs.}
        cast[LP](logFn)(1, nil, "ps.c", 702, "Enable DPSM on\r\n")
      ps.flags = ps.flags or 1
    # Enable PS: set MACHW bit
    let machwPowerControl = volatileLoad(cast[ptr uint32](0x24B0004C'u32))
    volatileStore(cast[ptr uint32](0x24B0004C'u32), machwPowerControl or 4'u32)

  # .L39: Load active VIF linked-list head from vif_mgmt_env.
  var vifNode = cast[pointer](vifMgmtEnvView().activeList.first)
  # Clear ps_env flag bytes at offsets 8 and 29
  ps.pendingCount = 0
  ps.psActive = 0
  var lastVisitedVifEntry: pointer = nil
  var cfmCallback: pointer  # s3: ps_disable_cfm or ps_enable_cfm fn ptr
  if mode == 0:
    cfmCallback = cast[pointer](ps_disable_cfm)
  else:
    cfmCallback = cast[pointer](ps_enable_cfm)

  # .L42: Walk VIF linked list (blob: VIF walk with chan_is_on_channel + txl_frame_send_null_frame)
  while vifNode != nil:
    let vif = vifChannelAt(vifNode)
    # .L47: Check VIF type at offset 86; skip non-STA VIFs.
    if vif.vifType == VIF_TYPE_STA:
      # Check connless at offset 88
      if vif.state != 0:
        # Blob: call chan_is_on_channel(vifNode)
        let chanOnFn = cast[proc(vif: pointer): bool {.cdecl.}](chan_is_on_channel)
        if chanOnFn(vifNode):
          vif.psNullRetry = 0
          ps.pendingCount = ps.pendingCount + 1
          # Check VIF flag at 104 for wakeup notification
          if vif.uapsdBitmap != 0:
            ps.psActive = 1
          # Blob: txl_frame_send_null_frame(vif[96], s3=cfmCallback, vifNode)
          let nullFrameStatus = txl_frame_send_null_frame(
            vif.staIdx, cfmCallback, pointerAddrU32(vifNode))
          if nullFrameStatus == 1'u8:
            ps.pendingCount = ps.pendingCount - 1
    # Next VIF: offset 0 is next pointer
    lastVisitedVifEntry = vifNode
    vifNode = vif.next

  # .L42 exit: check ps_env+8 counter
  if ps.pendingCount != 0:
    return

  # No null-frame confirmations are pending; finish synchronously through the
  # same tails as the vendor object.
  if mode == 0:
    discard ps_disable_cfm_handle(lastVisitedVifEntry)
  else:
    ps_enable_cfm_handle(lastVisitedVifEntry)

proc ps_check_beacon*(rxHdr: pointer, unused: uint32, vifEntry: pointer) {.exportc, cdecl.} =
  ## Check beacon for PS-related information (TIM, DTIM).
  ## From blob (106 instrs): loads AID from sta_info_tab[vif[96]] at offset 36.
  ## Clears bit 0 of vif[4]. Checks ps_env enabled and not scanning.
  ## If no rx header, returns. Checks WMM flag at vif[94]. Parses TIM bitmap
  ## from the beacon to determine if traffic is buffered for our AID.
  ## If TIM bit set: calls ps wakeup function and sets bit 6 in vif[4].
  ## If UAPSD bitmap all-AC (0x0F), clears bit 3 of vif[4] flags.
  let vif = vifChannelAt(vifEntry)
  let ps = psEnvView()

  # Load AID from associated STA
  let aid = staInfoForIdx(vif.staIdx).aid

  # Clear bit 0 of vif flags
  var flags = vif.flags
  flags = flags and not 1'u32
  vif.flags = flags

  # Check PS enabled
  if ps.enabled == 0: return

  # Check not scanning (ps_env byte 52, bit 3)
  if (ps.flags and 8) != 0: return

  # Check rx header is valid
  if rxHdr == nil: return

  let tim = timIeAt(rxHdr)
  if vif.psOptions == 0:
    # Non-WMM path: check TIM bitmap-control bit 0.
    let frameTypeBit = tim.bitmapControl
    if (frameTypeBit and 1) != 0:
      # TIM present: set bit 1 in vif[4]
      flags = vif.flags
      flags = flags or 2'u32
      vif.flags = flags
    else:
      # TIM not present: clear bit 1
      flags = vif.flags
      flags = flags and not 2'u32
      vif.flags = flags

  # Parse TIM bitmap to check our AID
  let aidBytePos = aid shr 3  # byte position in TIM bitmap
  let bitmapControl = tim.bitmapControl and 0xFE'u8  # bitmap offset
  let bitmapStart = bitmapControl.uint16

  if aidBytePos < bitmapStart:
    # Our AID is before TIM bitmap range -- check UAPSD and flags
    let uapsd = vif.uapsdBitmap and 0x0F
    flags = vif.flags
    flags = flags and not 4'u32  # clear bit 2
    if uapsd == 0x0F:
      flags = flags and not 8'u32  # also clear bit 3 if all ACs are UAPSD
    vif.flags = flags

    # Check if PS is active or bit 1 is set -> wakeup
    if vif.psFlags != 0 or (flags and 2) != 0:
      # Blob just sets bit 6 in vif[4] here; previous Nim inserted a
      # vif_mgmt_bcn_to_prog call before the flag set which re-programmed the
      # beacon timer — an extra side effect the blob never emits.
      flags = vif.flags
      flags = flags or 64'u32  # set bit 6
      vif.flags = flags
    return

  let timLen = tim.ie.len
  let bitmapEnd = bitmapStart + timLen.uint16 - 4

  if aidBytePos > bitmapEnd:
    # Our AID is after TIM bitmap range
    let uapsd = vif.uapsdBitmap and 0x0F
    flags = vif.flags
    flags = flags and not 4'u32
    if uapsd == 0x0F:
      flags = flags and not 8'u32
    vif.flags = flags
    if vif.psFlags != 0 or (flags and 2) != 0:
      # Blob just sets bit 6 in vif[4] here; previous Nim inserted a
      # vif_mgmt_bcn_to_prog call before the flag set which re-programmed the
      # beacon timer — an extra side effect the blob never emits.
      flags = vif.flags
      flags = flags or 64'u32
      vif.flags = flags
    return

  # Our AID is within TIM bitmap: check our bit
  let timByte = tim.partialBitmap[(aidBytePos - bitmapStart).uint]
  let bitPos = aid and 7
  let bitMask = 1'u8 shl bitPos
  if (timByte and bitMask) != 0:
    # Traffic buffered for us: blob just sets bit 6 in vif[4]; see note above
    # about the removed vif_mgmt_bcn_to_prog call.
    flags = vif.flags
    flags = flags or 64'u32  # set bit 6
    vif.flags = flags
  else:
    # No traffic: check UAPSD and flags
    let uapsd = vif.uapsdBitmap and 0x0F
    flags = vif.flags
    flags = flags and not 4'u32
    if uapsd == 0x0F:
      flags = flags and not 8'u32
    vif.flags = flags
    if vif.psFlags != 0 or (flags and 2) != 0:
      # Blob just sets bit 6 in vif[4] here; previous Nim inserted a
      # vif_mgmt_bcn_to_prog call before the flag set which re-programmed the
      # beacon timer — an extra side effect the blob never emits.
      flags = vif.flags
      flags = flags or 64'u32
      vif.flags = flags
  # Notify traffic detection about TIM (blob: td_pack_tim_ind at 0xb4)
  td_pack_tim_ind(vif.vifIdx)

proc ps_check_tbtt*(vifEntry: pointer) {.exportc, cdecl.} =
  ## TBTT hook from the PS subsystem.
  ## Blob algorithm:
  ##   if ps_env[0] == 0: return
  ##   if (ps_env[52] & 8): return               ; scanning -> skip
  ##   if vif[91] == 0: return                   ; PS not active on this vif
  ##   td_pack_tim_ind(vif[87])                  ; notify upper layer
  ##   vif[4] |= 0x40                            ; mark TBTT handled
  ## Prior Nim bug: called vif_mgmt_bcn_to_prog(vifEntry). That reprograms
  ## the bcn-timeout timer and has nothing to do with TIM packing — AP-side
  ## TIM bits would never be re-sent to host, causing dropped PS deliveries.
  let ps = psEnvView()
  if ps.enabled == 0:
    return
  if (ps.flags and 8'u8) != 0:
    return
  let vif = vifChannelAt(vifEntry)
  if vif.psFlags == 0:
    return
  td_pack_tim_ind(vif.vifIdx)
  vif.flags = vif.flags or 64'u32

proc psTxTidToAc(tid: uint8): uint8 {.inline.} =
  ## Blob uses mac_tid2ac[tid]: 01 00 00 01 02 02 03 03 03.
  case tid
  of 0'u8: 1'u8
  of 1'u8, 2'u8: 0'u8
  of 3'u8: 1'u8
  of 4'u8, 5'u8: 2'u8
  else: 3'u8

proc ps_check_frame*(rxHdr: pointer, frameFlags: uint32, vifEntry: pointer) {.exportc, cdecl.} =
  ## Check received frame for PS state change.
  ## Blob flow:
  ##   - group addr: clear vif[4] bit 1 unless protected && vif[94] == 0.
  ##   - A-MSDU flag in frameFlags bit 9 returns.
  ##   - ps_env[29] gates UAPSD timestamp work, but ps_env[29] == 0 still
  ##     falls through to td_pck_ps_ind(vif[87], 1) and PS-Poll/bit-2 handling.
  ##   - QoS UAPSD MoreData clears vif[4] bit 3 and returns.
  let ps = psEnvView()
  let vif = vifChannelAt(vifEntry)

  # Check PS enabled
  if ps.enabled == 0: return

  # Load frame control from rxHdr
  let hdr = macDataFrameAt(rxHdr)
  let frameCtrl = hdr.frameControl
  let qosTid =
    if (frameCtrl and 0x008C'u16) != 0x0088'u16: 0'u16
    elif (frameCtrl and 0x0300'u16) == 0x0300'u16:
      macQos4AddrFrameAt(rxHdr).qosCtrl
    else:
      macQosDataFrameAt(rxHdr).qosCtrl
  if (qosTid and 0x0F'u16) >= 8:
    return

  # Check Addr1 group bit (bit 0 of rxHdr[4])
  let addr1Group = hdr.addr1[0] and 1'u8
  if addr1Group != 0:
    # Blob clears bit 1 for unprotected group frames, and for protected group
    # frames only when vif[94] is non-zero.
    let protectedFrame = (frameCtrl and 0x2000'u16) != 0
    if protectedFrame and vif.psOptions == 0:
      return
    vif.flags = vif.flags and not 2'u32
    return

  # Check A-MSDU flag (bit 9 of frameFlags)
  if (frameFlags and 0x200'u32) != 0:
    return

  var psActive = ps.psActive
  if psActive != 0:
    if (frameCtrl and 0x008C'u16) == 0x0088'u16:
      let tid = (qosTid and 0x0F).uint8
      let ac = psTxTidToAc(tid)
      let acBit = (vif.uapsdBitmap.uint32 shr ac.uint32) and 1
      if acBit != 0:
        vif.psLastTime = regRead(MACHW_TIMLO_REG)
        if (qosTid and 0x10'u16) == 0:
          return
        let logFn = getLogFunc(204)
        if logFn != nil:
          type LP = proc(level: uint32, tag, file: cstring, line: cint,
                         format: cstring) {.cdecl, varargs.}
          cast[LP](logFn)(1, nil, "ps.c", 1005, "rx frame: UAPSD CLR\r\n")
        vif.flags = vif.flags and not 8'u32
        return
      psActive = 0
    else:
      if (frameCtrl and 0x000C'u16) == 0 and (vif.uapsdBitmap and 8'u8) != 0:
        vif.psLastTime = regRead(MACHW_TIMLO_REG)
      else:
        psActive = 0

  td_pck_ps_ind(vif.vifIdx, 1)
  if psActive != 0:
    return

  if (frameCtrl and 0x2000'u16) != 0:
    if (ps.flags and 8'u8) != 0:
      return
    if ps_send_pspoll(vifEntry) == 0:
      return

  vif.flags = vif.flags and not 4'u32

proc ps_check_tx_frame*(staIdx: uint8, txTid: uint8): bool {.exportc, cdecl.} =
  ## Check if TX frame needs PS handling.
  ## Blob ABI: a0=STA index (desc[49]), a1=TX TID/AC selector (desc[46]).
  ## It computes STA entry from a0, resolves the VIF from sta[39], checks
  ## vif[86]/vif[88], then tests (vif[104] >> mac_tid2ac[a1]) & 1. If UAPSD
  ## matches, logs, sets bit 3 in vif[4], and stores MAC time to vif[100].
  ## Otherwise it tail-calls td_pck_ps_ind(vif[87], 0).
  if psEnvView().enabled == 0 or txlResetting():
    return false

  if staIdx >= STA_INFO_TAB_ENTRIES.uint8 or txTid > 8:
    return false

  let sta = staInfoForIdx(staIdx)

  # Get VIF entry from STA's VIF pointer or compute from staEntry[39]
  let staVifIdx = sta.instNbr
  if staVifIdx >= MAX_VIFS.uint8:
    return false
  let vif = vifChannelForIdx(staVifIdx)

  # Check VIF type (offset 86): must not be monitor (type != monitor)
  if vif.vifType != VIF_TYPE_STA:
    return false

  # Check PS capable (offset 88)
  if vif.state == 0:
    return false

  # Check UAPSD bitmap (vif[104]): shift by mac_tid2ac[txTid].
  let ac = psTxTidToAc(txTid)
  let acBit = (vif.uapsdBitmap.uint32 shr ac.uint32) and 1
  if acBit != 0:
    let resetEpoch = txResetEpoch
    let stationEpoch = staDeleteEpoch(staIdx)
    let vifEpoch = rxVifEpochs[staVifIdx]
    let logFn = getLogFunc(204)
    if logFn != nil:
      type LP = proc(level: uint32, tag, file: cstring, line: cint,
                     format: cstring) {.cdecl, varargs.}
      cast[LP](logFn)(1, nil, "ps.c", 1097, "tx frame: UAPSD\r\n")
    # Diagnostics can synchronously replace the station or its VIF.
    if txlResetting() or txResetEpoch != resetEpoch or
        staDeleteEpoch(staIdx) != stationEpoch or rxVifEpochs[staVifIdx] != vifEpoch or
        sta.instNbr != staVifIdx or vif.vifType != VIF_TYPE_STA or vif.state == 0 or
        psEnvView().enabled == 0:
      return false
    # UAPSD active for this AC: set bit 3 in vif[4]
    var flags = vif.flags
    flags = flags or 8'u32
    vif.flags = flags

    # Read MAC time to vif[100]
    let macTime = regRead(MACHW_TIMLO_REG)
    vif.psLastTime = macTime
    return false

  # Not UAPSD: tail-call td_pck_ps_ind(vifIdx, 0) for TX traffic detection
  td_pck_ps_ind(vif.vifIdx, 0)  # direction=TX
  return false

proc ps_polling_frame*(vifEntry: pointer): uint8 {.exportc, cdecl, discardable,
    noinline.} =
  ## Send PS-Poll frame. Blob (2 instrs): auipc t1, R_RISCV_CALL ps_send_pspoll;
  ## jr t1 — a pure tail-call that forwards the VIF pointer in a0 and returns
  ## ps_send_pspoll's status.
  return ps_send_pspoll(vifEntry)

proc ps_traffic_null_1_recovery*() {.exportc, cdecl.} =
  ## Recovery after null frame 1 failure.
  discard

proc ps_check_tx_status_part0_nim*(vifEntry: pointer, completionFn: pointer): uint32
  {.exportc: "ps_check_tx_status_part0_nim", cdecl.} =
  ## Nim-side implementation. Matches blob `ps_check_tx_status.part.0`.
  ## Blob flow:
  ##   retry = ++vif[95] (u8, zext)
  ##   threshold = *(u32*)(bl_ps_params + 12) // WORD, not byte
  ##   if retry == threshold:
  ##       ps_env[0] = 0
  ##       mm_send_connection_loss_ind(vifEntry, 21)
  ##       return 1
  ##   if retry == threshold >> 1:
  ##       wifi_hosal_pm_post_event(4, 1, 0)
  ##       return 1
  ##   if ps_env[8] == 0:
  ##       return 1
  ##   rc = txl_frame_send_null_frame(staIdx=vif[96], completionFn, vifEntry)
  ##   if rc == 0: return 0
  ##   log failed queueing via g_bl_ops_funcs[1], then return 1
  if vifEntry == nil: return 0'u32
  let ps = psEnvView()
  let vif = vifChannelAt(vifEntry)
  let retry = vif.psNullRetry + 1'u8
  vif.psNullRetry = retry
  # The byte-sized counter is widened before comparing with the full word.
  let threshold = blPsParamsView().nullRetryLimit
  if retry.uint32 == threshold:
    ps.enabled = 0
    mm_send_connection_loss_ind(vifEntry, 21'u16)
    return 1'u32
  # Second branch: retry == threshold >> 1
  let halfThreshold = threshold shr 1
  if retry.uint32 == halfThreshold:
    wifi_hosal_pm_post_event(4'u32, 1'u32, nil)
    return 1'u32
  # If ps_env[8] == 0 -> no outstanding enable count, return 1
  if ps.pendingCount == 0:
    return 1'u32
  let rc = txl_frame_send_null_frame(vif.staIdx, completionFn, pointerAddrU32(vifEntry))
  # Blob semantics:
  #   if rc == 0 (null-frame queued successfully): return 0 (retry in progress)
  #   else (failed to send): log via g_bl_ops_funcs[1] (printf-like fn pointer),
  #     picks "enable" or "disable" string by comparing completionFn vs ps_enable_cfm,
  #     passes format string + mode + retry counter, then return 1.
  if rc == 0'u32:
    return 0'u32
  # Emit the log call. g_bl_ops_funcs[1] is the printf-like pointer at offset 4.
  let logPtr = blOpsFunc(4)
  if logPtr != nil:
    let psEnableAddr = cast[uint](ps_enable_cfm)
    let isEnable = cast[uint](completionFn) == psEnableAddr
    const modeEnable: cstring = "enable"
    const modeDisable: cstring = "disable"
    const fmt: cstring = "abort NULL frame send for PS %s, tried %u\r\n"
    let modeStr = if isEnable: modeEnable else: modeDisable
    let retryCnt = vif.psNullRetry.uint32
    let printFn = cast[proc(fmt: cstring, mode: cstring, tried: uint32){.cdecl, varargs.}](logPtr)
    printFn(fmt, modeStr, retryCnt)
  return 1'u32

# Export an alias with the exact blob-style symbol `ps_check_tx_status.part.0`.
# Use a true GCC `alias` attribute so there's no extra call frame (alias
# symbols resolve at link time to the same address). Matches blob which
# has only the `.part.0` symbol and no wrapper.
{.emit: """
NU32 ps_check_tx_status_part0_alias(void* v, void* f)
    __attribute__((alias("ps_check_tx_status_part0_nim")));
asm(".globl ps_check_tx_status.part.0\n"
    ".set ps_check_tx_status.part.0, ps_check_tx_status_part0_nim");
""".}

proc ps_disable_cfm*(vifEntry: pointer, statusFlags: uint32) {.exportc, cdecl.} =
  ## PS disable confirmation (114 bytes in blob).
  ## Blob: check ps_env[52] bit 2 (scanning) for early return.
  ## If statusFlags bit 23 (0x800000) set: decrement ps_env[8] count,
  ##   clear timer at ps_env+0x24, if count reaches 0 call ps_disable_cfm_handle.
  ## If bit 23 not set: call ps_check_tx_status (inline), loop back if non-zero.
  if not txlFrameCallbackCurrent(): return
  let ps = psEnvView()
  # Check scanning flag: ps_env byte 52, bit 2
  if (ps.flags and 4) != 0:
    return
  let hasTxCfm = (statusFlags and 0x00800000'u32) != 0
  if not hasTxCfm:
    # No HW confirmation bit: check TX status via ps_check_tx_status.part.0
    # (GCC-generated partial function name, need asm label to reference it)
    let checkResult = ps_check_tx_status_part0_nim(vifEntry, cast[pointer](ps_disable_cfm))
    if not txlFrameCallbackCurrent(): return
    if checkResult == 0:
      return
    # Non-zero means TX confirm arrived, fall through to decrement path
  # Decrement TX confirm counter and clear timer
  let pendingNullConfirmCount = ps.pendingCount
  if pendingNullConfirmCount == 0:
    return
  let remainingNullConfirmCount = pendingNullConfirmCount - 1
  ps.pendingCount = remainingNullConfirmCount
  mm_timer_clear(psTxNullTimer())
  if remainingNullConfirmCount != 0:
    return
  # All confirms received: finalize disable
  discard ps_disable_cfm_handle(vifEntry)

proc ps_traffic_status_update*(vifIdx: uint8, status: uint32): uint32 {.exportc, cdecl, discardable.} =
  ## Apply a traffic change to dynamic PS, considering the other STA VIFs.
  ## The notifying VIF's stored flags still describe its previous interval.
  let ps = psEnvView()
  if ps.enabled == 0: return 0
  let psFlags = ps.flags
  if (psFlags and 1) == 0 or (psFlags and 6) != 0: return 0

  var trafficPresent = status != 0
  if not trafficPresent:
    var vifCur = cast[pointer](vifMgmtEnvView().activeList.first)
    while vifCur != nil:
      let vif = vifChannelAt(vifCur)
      if vif.vifIdx != vifIdx and vif.state != 0 and vif.vifType == VIF_TYPE_STA:
        let trafficFlags = tdEntryForVif(vif.vifIdx).prevFlags
        if (trafficFlags and 0x0C) != 0:
          let logFn = getLogFunc(204)
          if logFn != nil:
            type LP = proc(level: uint32, tag, file: cstring, line: cint,
                           format: cstring) {.cdecl, varargs.}
            cast[LP](logFn)(1, nil, "ps.c", 1187, "%s:%d\r\n",
                           cstring("ps_traffic_status_update"), 1187.cint)
          trafficPresent = true
          break
      vifCur = vif.next

  let awake = (ps.flags and 8) != 0
  if trafficPresent:
    if not awake:
      return ps_dpsm_update(1)
  elif awake:
    return ps_dpsm_update(0)
  return 0

proc ps_uapsd_set*(vifEntry: pointer, ac: uint8, enabled: uint32) {.exportc, cdecl.} =
  ## Enable/disable U-APSD for an AC.
  ## From blob (35 instrs): computes bit mask (1 << ac). If enabled (a2 != 0),
  ## ORs into vif[104]. Else ANDs complement. Then checks if ps_env is enabled
  ## and UAPSD timer not already active: if so, reads MAC time, adds to timer
  ## period at ps_env[32], sets mm_timer on ps_env UAPSD timer, and marks
  ## UAPSD timer as active (ps_env[28]=1).
  let vif = vifChannelAt(vifEntry)
  let bitMask = 1'u8 shl ac
  let ps = psEnvView()

  let curBitmap = vif.uapsdBitmap
  if enabled != 0:
    # Set UAPSD bit for this AC
    let newBitmap = curBitmap or bitMask
    vif.uapsdBitmap = newBitmap

    # Check if we should start the UAPSD timer
    if ps.enabled == 0: return
    if ps.uapsdTimerActive != 0: return

    # Start UAPSD timer: mark as will-be-active
    ps.psActive = 1

    # Read MAC time, add period from ps_env[32], set timer
    let macTime = regRead(MACHW_TIMLO_REG)
    mm_timer_set(psUapsdTimer(), macTime + ps.uapsdPeriod)

    # Mark UAPSD timer as active
    ps.uapsdTimerActive = 1
  else:
    # Clear UAPSD bit for this AC
    let newBitmap = curBitmap and not bitMask
    vif.uapsdBitmap = newBitmap

proc ps_uapsd_timer_handle*() {.exportc, cdecl.} =
  ## Trigger eligible STA VIFs after half a U-APSD period without activity.
  ## Vendor uses a signed, wrapped deadline comparison and samples MAC time
  ## separately for each VIF, after each submission, and before rearming.
  var vifPtr = cast[pointer](vifMgmtEnvView().activeList.first)
  var foundAny = false
  let ps = psEnvView()
  while vifPtr != nil:
    let vif = vifChannelAt(vifPtr)
    # Check VIF type == STA (offset 86)
    if vif.vifType != VIF_TYPE_STA:
      vifPtr = vif.next
      continue
    # Check VIF active (offset 88)
    if vif.state == 0:
      vifPtr = vif.next
      continue
    # Check PS flag at VIF+104
    if vif.uapsdBitmap == 0:
      vifPtr = vif.next
      continue
    # Check if on channel (blob: chan_is_on_channel, NOT ps_check_tbtt)
    if not chan_is_on_channel(cast[pointer](vif)):
      vifPtr = vif.next
      continue
    foundAny = true
    let halfPeriod = ps.uapsdPeriod shr 1
    let macTime = macTimeNow()
    let remaining = vif.psLastTime + halfPeriod - macTime
    if cast[int32](remaining) < 0:
      let logFn = getLogFunc(204)
      if logFn != nil:
        type LP = proc(level: uint32, tag, file: cstring, line: cint,
                       format: cstring) {.cdecl, varargs.}
        cast[LP](logFn)(1, nil, "ps.c", 567, "apsd timer: UAPSD\r\n")
      # Set UAPSD trigger flag
      vif.flags = vif.flags or 0x08
      discard txl_frame_send_qosnull_frame(vif.staIdx, 7'u16, nil, 0)
      vif.psLastTime = macTimeNow()
    vifPtr = vif.next
  if not foundAny:
    # Clear the same activity byte that ps_uapsd_set checks before rearming.
    ps.uapsdTimerActive = 0
    return
  let timerTarget = macTimeNow() + ps.uapsdPeriod
  mm_timer_set(psUapsdTimer(), timerTarget)

proc ps_tx_null_timer_handle*() {.exportc, cdecl.} =
  ## TX null frame timer callback (80 bytes in blob).
  ## Blob: checks ps_env flags, then dispatches:
  ##   ps_disable_cfm_handle, ps_enable_cfm_handle, txl_cntrl_clear_ac
  let ps = psEnvView()
  let flags = ps.flags
  if (flags and 1) == 0:
    return
  let pendingNullConfirmCount = ps.pendingCount
  if pendingNullConfirmCount == 0:
    return
  if not txl_cntrl_halt_ac(3): return
  ps.pendingCount = 0
  # The timeout aborts all outstanding null-frame confirmations, then
  # finalizes through the same handler selected by ps_env flags.
  if (flags and 2) != 0:
    discard ps_disable_cfm_handle(nil)
  elif (flags and 4) != 0:
    ps_enable_cfm_handle(nil)
  # Clear any pending TX on AC3 (blob: txl_cntrl_clear_ac)
  if not txl_cntrl_clear_ac(3): return

proc pm_force_sleep_check*(): bool {.exportc, cdecl.} =
  ## Check if forced sleep is allowed.
  ## From blob (ps.o, 2 instrs): always returns 1 (true) - stub.
  return true

proc waitMacPmInterrupt(startTime: uint32): bool =
  var remaining = WifiHwPollLimit
  while (regRead(MACHW_INTC_BASE + 0x06C'u) and 4'u32) == 0:
    if macTimeNow() - startTime > 0x4C4B3F'u32 or remaining == 0:
      noteHwWaitTimeout((MACHW_INTC_BASE + 0x06C'u).uint32, 4)
      return false
    dec remaining
  true

proc waitMacPmState(expected: uint8): bool =
  var remaining = WifiHwPollLimit
  while (regRead(MACHW_STATE_CNTRL_REG) and 0xF'u32) != expected.uint32:
    if remaining == 0:
      noteHwWaitTimeout(MACHW_STATE_CNTRL_REG.uint32,
                        0xF'u32 or (expected.uint32 shl 8))
      return false
    dec remaining
  true

proc set_mac_to_doze*(): uint32 {.exportc, cdecl.} =
  ## Request doze only after the MAC's current-state nibble reaches IDLE.
  var ctrlReg = regRead(MACHW_STATUS_REG)
  ctrlReg = ctrlReg or 0x40'u32
  regWrite(MACHW_STATUS_REG, ctrlReg)
  let curState = regRead(MACHW_STATE_CNTRL_REG) and 0xF'u32
  if curState != 0:
    let logFn = cast[proc(level: uint32; tag, file: cstring; line: cint;
                          format: cstring) {.cdecl, varargs.}](blOpsFunc(204))
    if logFn != nil:
      logFn(4, nil, "bl.c", 286, "mac state not idle, assert.\r\n")
    # The port's assertion recovery returns, so do not continue into doze.
    assert_rec("0", "bl.c", 287)
    return 1
  blDozeEnvView().dozeInProgress = 1
  regWrite(MACHW_STATE_CNTRL_REG, 0x20'u32)
  return 0

proc wait_mac_goto_idle*(): uint32 {.exportc, cdecl.} =
  ## Save the original state before the vendor's second current-state read.
  blDozeEnvView().preState = (regRead(MACHW_STATE_CNTRL_REG) and 0xF'u32).uint8
  if (regRead(MACHW_STATE_CNTRL_REG) and 0xF'u32) == 0:
    return 0
  let startTime = macTimeNow()
  let intcCtrl = MACHW_INTC_BASE + 0x074'u
  var unmask = regRead(intcCtrl)
  unmask = unmask and 0x7FFFFFFF'u32
  regWrite(intcCtrl, unmask)
  regWrite(intcCtrl, regRead(intcCtrl) or 0x04'u32)
  regWrite(MACHW_STATE_CNTRL_REG, 0'u32)
  discard waitMacPmInterrupt(startTime)
  discard macTimeNow()
  let finalState = regRead(MACHW_STATE_CNTRL_REG) and 0xF'u32
  regWrite(MACHW_INTC_BASE + 0x070'u, 0x04'u32)
  unmask = regRead(intcCtrl)
  unmask = unmask and not 0x04'u32
  regWrite(intcCtrl, unmask)
  # Restore bit 31
  unmask = regRead(intcCtrl)
  unmask = unmask or 0x80000000'u32
  regWrite(intcCtrl, unmask)
  return if finalState != 0: 1'u32 else: 0'u32

proc wait_mac_goto_prestate*(): uint32 {.exportc, cdecl.} =
  ## Restore the state saved in bl_env, with a bounded completion wait.
  let preState = blDozeEnvView().preState
  if preState == 0:
    return 0
  let targetBits = preState.uint32 shl 4
  if (targetBits and 0xFFFFFF0F'u32) != 0:
    assert_err("(((uint32_t)nextstate << 4) & ~((uint32_t)0x000000F0)) == 0",
               "module", 1465)
    return 1
  regWrite(MACHW_STATE_CNTRL_REG, targetBits)
  return if waitMacPmState(preState): 0'u32 else: 1'u32

proc wakeup_from_doze_done*(): uint32 {.exportc, cdecl.} =
  ## Complete doze wakeup: clear doze flag in INTC.
  ## From blob (ps.o, 6 instrs): clears bit 31 (0x80000000) in
  ## MACHW_INTC_BASE+0x048, returns 0.
  var reg = regRead(MACHW_INTC_BASE + 0x048'u)
  reg = reg and 0x7FFFFFFF'u32
  regWrite(MACHW_INTC_BASE + 0x048'u, reg)
  return 0

proc wakeup_from_doze_pre*(): uint32 {.exportc, cdecl.} =
  ## Prepare wakeup and restore IRQ controls even if the MAC remains busy.
  let intcCtrl = MACHW_INTC_BASE + 0x074'u
  var unmask = regRead(intcCtrl)
  unmask = unmask and 0x7FFFFFFF'u32
  regWrite(intcCtrl, unmask)
  # Write ack and set idle command
  regWrite(MACHW_INTC_BASE + 0x070'u, 0x04'u32)
  unmask = regRead(intcCtrl)
  unmask = unmask or 0x04'u32
  regWrite(intcCtrl, unmask)
  # Set doze wakeup bit (bit 31) in INTC+0x048
  var dozeReg = regRead(MACHW_INTC_BASE + 0x048'u)
  dozeReg = dozeReg and 0x7FFFFFFF'u32
  dozeReg = dozeReg or 0x80000000'u32
  regWrite(MACHW_INTC_BASE + 0x048'u, dozeReg)
  # Clear doze-in-progress
  blDozeEnvView().dozeInProgress = 0
  # Short spin waiting for INTC bit 2
  var spins = 501'u32
  while spins > 0:
    let status = regRead(MACHW_INTC_BASE + 0x06C'u)
    if (status and 0x04'u32) != 0:
      break
    dec spins
  let startTime = macTimeNow()
  discard waitMacPmInterrupt(startTime)
  discard macTimeNow()
  let idle = waitMacPmState(0)
  # Final: ack, clear, set
  regWrite(MACHW_INTC_BASE + 0x070'u, 0x04'u32)
  unmask = regRead(intcCtrl)
  unmask = unmask and not 0x04'u32
  regWrite(intcCtrl, unmask)
  unmask = regRead(intcCtrl)
  unmask = unmask or 0x80000000'u32
  regWrite(intcCtrl, unmask)
  return if idle: 0'u32 else: 1'u32

proc ps_disable_cfm_handle*(vifEntry: pointer): uint32 {.exportc, cdecl.} =
  ## Handle PS disable confirmation from MAC (232 bytes in blob, 59 instrs).
  ## From blob (ps.o) -- faithful translation:
  ##   s1 = vifEntry
  ##   local localStatus = 0                           ; sp+12
  ##   mm_timer_clear(&ps_env + 12)
  ##   ps_env[0x1c] = 0                                 ; offset 28
  ##   flags = ps_env[52]
  ##   if (flags & 3) == 3 AND s1 != nil:               ; PS disabling path
  ##     flags = (flags & ~2) | 8
  ##     ps_env[52] = flags
  ##     wifi_hosal_pm_post_event(4, 0, &localStatus)
  ##     td_cfm_set_timer(s1[87], localStatus & 0xff)
  ##     s2 = 1
  ##     goto L65
  ##   else:                                            ; .L64
  ##     ps_env[0] = 0
  ##     s2 = 0
  ##     ke_msg_send_basic(32, ps_env[1], 0)
  ##     if s1 != nil: goto L65
  ##     goto L66
  ##   L65:
  ##     if s1[91] != 0:
  ##       ke_env[28] |= 1; ke_env[32] = 1
  ##       ke_evt_set(0x100)
  ##     s1[196] = 0                                   ; blob always stores 0
  ##   L66:
  ##     if ps_env[52] & 0x10:
  ##       ps_env[52] &= ~0x10
  ##       ps_set_mode(ps_env[53], ps_env[1])
  ##   return s2
  let ps = psEnvView()
  var localStatus: uint32 = 0  # PM writes a word at sp+12 in the blob.
  # Blob: mm_timer_clear(&ps_env + 12)
  mm_timer_clear(psUapsdTimer())
  # ps_env[0x1c] (offset 28) = 0
  ps.uapsdTimerActive = 0

  let flags0 = ps.flags
  var result2: uint32 = 0  # s2 in blob

  if (flags0 and 3) == 3 and vifEntry != nil:
    # PS disable path: clear bit 1, set bit 3
    let newFlags = (flags0 and (not 2'u8)) or 8'u8
    ps.flags = newFlags
    # wifi_hosal_pm_post_event(4, 0, &localStatus)
    wifi_hosal_pm_post_event(4, 0, cast[pointer](addr localStatus))
    # td_cfm_set_timer(s1[87], localStatus)
    let vifIdxLocal = vifChannelAt(vifEntry).vifIdx
    td_cfm_set_timer(vifIdxLocal, localStatus and 0xFF'u32)
    result2 = 1
    # fall through to .L65
  else:
    # .L64: send basic message
    ps.enabled = 0
    # ke_msg_send_basic(32, ps_env[1], 0)
    mmPsModeComplete()
    # Blob does not short-circuit the vifEntry==nil case with its own
    # ps_set_mode call — .L64 falls through to .L65 (which is a no-op
    # when vifEntry is NULL) and then reaches the single .L66 ps_set_mode
    # site. Previous Nim duplicated the ps_set_mode call here, producing
    # two call sites for the same code path. Letting control flow
    # through collapses them into one.

  # .L65 (reached from PS-disable path, or from .L64 if vifEntry != nil)
  if vifEntry != nil:
    let vif = vifChannelAt(vifEntry)
    let flagByte = vif.psFlags
    # s1[196] = 0  (blob unconditionally)
    vif.keyPsState = 0
    if flagByte != 0:
      let ps = keEnvPsFlags()
      ps.flags = ps.flags or 1
      ps.staPending = 1
      ke_evt_set(0x100'u32)

  # .L66
  let flagsL66 = ps.flags
  if (flagsL66 and 0x10) != 0:
    ps.flags = flagsL66 and (not 0x10'u8)
    ps_set_mode(ps.deferredMode, ps.mode)
  return result2

proc ps_enable_cfm*(vifEntry: pointer, status: uint32) {.exportc, cdecl.} =
  ## Handle PS enable confirmation (114 bytes in blob).
  ## Blob flow:
  ##   if (ps_env[52] & 2) return;                       ; state guard
  ##   if (status & 0x800000) goto finalize;             ; hw_cfm branch
  ##   if (ps_check_tx_status_part0(vif, ps_enable_cfm) == 0) return
  ## finalize:
  ##   if (ps_env[8] == 0) return;
  ##   ps_env[8] -= 1;
  ##   mm_timer_clear(ps_env + 0x24);                     ; byte offset 36, NOT 12
  ##   if (ps_env[8] != 0) return;
  ##   ps_enable_cfm_handle(vif);                         ; tail call
  if not txlFrameCallbackCurrent(): return
  let ps = psEnvView()
  # State guard: if ps_env[52] & 2 set, abort (PS disable already pending)
  if (ps.flags and 2'u8) != 0:
    return
  # hw_cfm branch: if caller already confirmed TX (status bit 23 set), skip TX poll
  if (status and 0x00800000'u32) == 0:
    # Poll TX status via part.0 clone. Returns 1 when TX has settled, 0 to retry.
    let checkResult = ps_check_tx_status_part0_nim(vifEntry, cast[pointer](ps_enable_cfm))
    if not txlFrameCallbackCurrent(): return
    if checkResult == 0:
      return
  # finalize path
  let pendingNullConfirmCount = ps.pendingCount
  if pendingNullConfirmCount == 0:
    return
  ps.pendingCount = pendingNullConfirmCount - 1
  # Clear TX-null timer at ps_env + 0x24 (byte offset 36, NOT 12)
  mm_timer_clear(psTxNullTimer())
  if ps.pendingCount != 0:
    return
  # Tail-call into handle
  ps_enable_cfm_handle(vifEntry)

proc ps_enable_cfm_handle*(vifEntry: pointer) {.exportc, cdecl, noinline.} =
  ## Finalize PS enable: update state, start timers.
  ## From blob (ps.o, 57 instrs): if ps_env[29] is nonzero and a VIF is
  ## supplied, starts the UAPSD timer. Then checks
  ## ps_env[52] bits [2:0] for 5 (enable+confirm), clears bits, updates VIF.
  ## noinline: blob calls this from ps_dpsm_update, ps_tx_null_timer_handle,
  ## and ps_check_tx_status.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let ps = psEnvView()
  if ps.psActive != 0 and vifEntry != nil:
    let macTime = macTimeNow()
    mm_timer_set(psUapsdTimer(), macTime + ps.uapsdPeriod)
    ps.uapsdTimerActive = 1
    let vifForTimer = vifChannelAt(vifEntry)
    if vifForTimer.state != 0 and vifForTimer.uapsdBitmap != 0:
      let logFn = getLogFunc(204)
      if logFn != nil:
        type LP = proc(level: uint32, tag, file: cstring, line: cint,
                       format: cstring) {.cdecl, varargs.}
        cast[LP](logFn)(1, nil, "ps.c", 208, "enable cfm: UAPSD CLR\r\n")
      vifForTimer.flags = vifForTimer.flags and not 0x08'u32
  # Check and finalize ps_env flags
  let flags = ps.flags
  if (flags and 0x05) == 5 and vifEntry != nil:
    # Clear enable bits, update VIF
    let newFlags = flags and not 0x0C'u8
    ps.flags = newFlags
    let vif = vifChannelAt(vifEntry)
    vif.flags = vif.flags and not 0x42'u32
    # Set PS confirmed in VIF[196]
    vif.keyPsState = 1
  else:
    # Send PS mode confirmation
    ps.enabled = 1
    mmPsModeComplete()
    if vifEntry != nil:
      vifChannelAt(vifEntry).keyPsState = 1

  # Blob .L94: check bit 4 of ps_env[52] for pending ps_set_mode
  let finalFlags = ps.flags
  if (finalFlags and 0x10) != 0:
    let clearedFlags = finalFlags and not 0x10'u8
    ps.flags = clearedFlags
    ps_set_mode(ps.deferredMode, ps.mode)

proc ps_dpsm_update*(enable: uint32): uint32 {.exportc, cdecl, discardable.} =
  ## Update DPSM state (334b in blob, ps.o).
  ## Blob: nonzero starts the disable-confirm path and sends null frames
  ## without callbacks; zero starts the enable-confirm path with ps_enable_cfm
  ## callbacks and the TX-null retry timer.
  let ps = psEnvView()
  if ps.pendingCount != 0:
    return 0  # transition in progress
  # Update flags and state bits
  let flags = ps.flags
  let envWord = ps.statusFlags
  var cfmCallback: pointer
  if enable != 0:
    ps.flags = flags or 0x02
    ps.statusFlags = envWord or 0x08
    cfmCallback = cast[pointer](ps_disable_cfm)
  else:
    ps.flags = flags or 0x04
    ps.statusFlags = envWord and not 0x08'u32
    cfmCallback = cast[pointer](ps_enable_cfm)
  # Update MAC HW power ctrl register at 0x24B0004C
  # Blob: read reg, clear bit 2, set ((enable^1)<<2)
  let hwBase = 0x24B00000'u
  var pmReg = volatileLoad(cast[ptr uint32](hwBase + 0x4C))
  pmReg = pmReg and not 0x04'u32  # clear bit 2
  pmReg = pmReg or (((enable xor 1) and 1) shl 2)  # set bit 2 if disabling
  volatileStore(cast[ptr uint32](hwBase + 0x4C), pmReg)
  ps.pendingCount = 0
  # Walk VIF linked list
  var vifPtr = cast[pointer](vifMgmtEnvView().activeList.first)
  var lastVisitedVifEntry: pointer = nil
  while vifPtr != nil:
    let vif = vifChannelAt(vifPtr)
    lastVisitedVifEntry = vifPtr
    if vif.vifType != VIF_TYPE_STA:
      vifPtr = vif.next
      continue
    let psCapable = vif.state
    if psCapable == 0:  # skip if not PS capable
      vifPtr = vif.next
      continue
    # Call chan_is_on_channel to validate VIF is on channel
    let checkResult = chan_is_on_channel(vifPtr)
    if not checkResult:
      vifPtr = vif.next
      continue
    # Increment active counter, clear PS state, load PS mode
    let pendingNullConfirmSnapshot = ps.pendingCount
    ps.pendingCount = pendingNullConfirmSnapshot + 1
    vif.psNullRetry = 0
    let staIdx = vif.staIdx
    if enable != 0:
      discard txl_frame_send_null_frame(staIdx, nil, 0)
      ps.pendingCount = ps.pendingCount - 1
    else:
      let nullFrameStatus = txl_frame_send_null_frame(
        staIdx, cfmCallback, pointerAddrU32(vifPtr))
      if nullFrameStatus == 1'u8:
        ps.pendingCount = ps.pendingCount - 1
      else:
        # Store current VIF for async completion
        ps.currentVif = vifPtr
        mm_timer_set(psTxNullTimer(), macTimeNow() + blPsParamsView().txNullTimeout)
    vifPtr = vif.next
  # Post-loop: check if all done
  if ps.pendingCount != 0:
    return 0  # still pending
  if enable != 0:
    return ps_disable_cfm_handle(lastVisitedVifEntry)
  else:
    ps_enable_cfm_handle(lastVisitedVifEntry)
  return 0

proc ps_send_pspoll*(vifEntry: pointer): uint8 {.exportc, cdecl, noinline.} =
  ## Send PS-Poll frame (206 bytes in blob, 84 instrs).
  ## noinline: blob calls this from ps_polling_frame (gap target).
  ## From blob (ps.o): reads sta_idx from vif[0x60]. Calls txl_frame_get(16)
  ## to allocate a 16-byte frame descriptor. Calls tpc_update_frame_tx_power.
  ## Builds PS-Poll 802.11 header: FC=0x00A4, Duration=AID|0xC000,
  ## Addr1=BSSID (from sta[4]), Addr2=own MAC (from vif[0x50]).
  ## Sets TX control flags (0x10000053), copies rate info from sta,
  ## calls txl_frame_push(txdesc, AC_VO=3). Returns 0 on push success, 1 on
  ## allocation/push failure.
  let saved = irqSave()
  defer: irqRestore(saved)
  if vifEntry == nil:
    return 1
  let vif = vifChannelAt(vifEntry)
  let vifIdx = vif.vifIdx
  if vifIdx >= MAX_VIFS.uint8 or vifChannelForIdx(vifIdx) != vif:
    return 1
  let staIdx = vif.staIdx
  if staIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return 1
  let identity = TxSessionIdentity(captured: true, vif: vifIdx, station: staIdx,
    vifEpoch: rxVifEpochs[vifIdx], stationEpoch: staDeleteEpoch(staIdx),
    resetEpoch: txResetEpoch)
  # Allocate frame descriptor for 16-byte PS-Poll
  let txdesc = txl_frame_get(16)
  if txdesc == nil:
    return 1  # Allocation failed
  let desc = hostTxDescAt(txdesc)
  let generation = txlFrameLeaseToken(desc)
  desc.vifIdx = vifIdx
  desc.staInfoIdx = staIdx
  if not txlFramePreparationCurrent(desc, identity, generation):
    return 1
  # Update TX power
  tpc_update_frame_tx_power(vifEntry, txdesc)
  if not txlFramePreparationCurrent(desc, identity, generation):
    return 1
  let hdr = hostTxPsPollHeader(desc)
  # Build PS-Poll frame control (0x00A4)
  hdr.frameControl = 0x00A4'u16
  # Get STA info for AID and BSSID
  let sta = staInfoForIdx(staIdx)
  let aid = sta.aid
  let aidWithBits = aid or 0xC000'u16  # Set bits 14-15 per 802.11 spec
  hdr.aid = aidWithBits
  # Copy BSSID to Addr1 (6 bytes from sta[4])
  discard c_memcpy(addr hdr.bssid[0], addr sta.macAddr[0], 6.csize_t)
  # Copy own MAC to Addr2 (6 bytes from vif[0x50])
  discard c_memcpy(addr hdr.transmitterAddr[0], addr vif.macAddr[0], 6.csize_t)
  # Set TX control flags in SW descriptor
  let hwDesc = hostTxHwDescAt(desc.hwDesc)
  hwDesc.controlFlags = hwDesc.controlFlags or 0x10000053'u32
  # Copy rate info from STA
  desc.vifIdx = sta.instNbr
  desc.staInfoIdx = sta.infoIdx
  if not txlFramePreparationCurrent(desc, identity, generation):
    return 1
  # Push frame for transmission
  let pushRc = txl_frame_push(txdesc, 3)  # AC_VO = 3
  return (pushRc xor 1'u8) and 0xFF'u8

proc mac_recovery*(): uint32 {.exportc, cdecl.} =
  ## MAC recovery handler — blob arch_main.o (10 instrs):
  ##   assert_rec(.LC1 /* file */, .LC4 /* func */, 299); return 0
  ## Previous Nim issued a getLogFunc(4) direct log; blob uses assert_rec
  ## which is a distinct sink and is what the recovery-counter audit expects.
  assert_rec("arch_main.c", "arch_main.c", 299)
  return 0

{.emit: "__attribute__((noipa)) unsigned long bl_pwr_find(void*,unsigned long);".}
proc bl_pwr_find*(levels: pointer, count: uint32): uint32 {.exportc, cdecl.} =
  ## Find the index of the maximum value in a signed byte array.
  ## Keep the first maximum. Unlike the vendor's byte-sized cursor, the
  ## exported uint32 count must not wrap at 256 and leave the scan running.
  if levels == nil or count == 0:
    return 0
  let powerLevels = cast[ptr UncheckedArray[int8]](levels)
  var bestIndex = 0'u32
  for scanIndex in 1'u32 ..< count:
    if powerLevels[scanIndex] > powerLevels[bestIndex]:
      bestIndex = scanIndex
  return bestIndex

proc ble_rf_ops*(enable: uint32) {.exportc, cdecl.} =
  ## BLE RF operations toggle (34 bytes in blob, 9 instrs).
  ## From blob: if enable == 0, calls wifi_hosal_rf_turn_off();
  ## else calls wifi_hosal_rf_turn_on(). Returns 0.
  if enable == 0:
    wifi_hosal_rf_turn_off()
  else:
    wifi_hosal_rf_turn_on()

proc rfc_channel_ops*(channel: uint32) {.exportc, cdecl.} =
  ## RF channel operations (12 instrs in blob):
  ##   rf_init(0x2625a00)                     # a0 = packed config pointer
  ##   sm_set_channel_coex_connected()        # uses whatever a0 rf_init left
  ##   return 0
  rf_init(0x02625A00'u32)
  sm_set_channel_coex_connected(0'u8)

proc vif_mgmt_bcn_to_evt*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Convert beacon reception to kernel event.
  ## From blob (vif_mgmt.o, 4 instrs): loads vifEntry[64], if non-nil
  ## tail-calls chan_bcn_to_evt(vifEntry). Otherwise returns.
  let chanCtxt = vifChannelAt(vifEntry).chanCtxt
  if chanCtxt != nil:
    chan_bcn_to_evt()

proc mm_ap_traffic_probe_cfm*(vifEntry: pointer, status: uint32) {.exportc, cdecl.} =
  ## AP traffic probe confirmation handler.
  ## From blob (mm.o, 14 instrs): checks status bit 23 (0x00800000). If set,
  ## resets probe counter to 10 and stores current MAC time at vifEntry+108.
  ## If not set, decrements a nonzero probe counter (mm_env[8]). If already
  ## zero, resets to 10 and calls mm_send_connection_loss_ind(vifEntry, 22).
  if not txlFrameCallbackCurrent(): return
  let mm = mmEnvView()
  if (status and 0x00800000'u32) != 0:
    mm.keepAliveLimit = 10  # reset counter at mm_env offset 32
    vifChannelAt(vifEntry).beaconTimeoutBase = macTimeNow()
  else:
    let keepAliveMissBudget = mm.keepAliveLimit
    if keepAliveMissBudget == 0:
      mm.keepAliveLimit = 10
      # Tail-call connection loss: blob passes vifEntry as a0, reason=22 as a1
      mm_send_connection_loss_ind(vifEntry, 22)
    else:
      mm.keepAliveLimit = keepAliveMissBudget - 1

proc td_timer_end*(tdEntry: pointer) {.exportc, cdecl.} =
  ## End traffic detection timer and update TD state (312 bytes in blob, 79 instrs).
  ## From blob (td.o): reads MAC timestamp, computes traffic direction flags from
  ## TX/RX counters vs threshold, calls notification on direction change, then
  ## resets counters and reschedules timer.
  ##
  ## Entry layout: [0]=timer link, [12]=expiry, [16]=period, [24]=rx_count, [28]=tx_count,
  ##   [32]=ps_rx_count, [36]=ps_tx_count, [40]=vif_idx, [41]=prev_flags,
  ##   [42]=active, [43]=timer-end active latch.
  let td = tdEntryAt(tdEntry)
  let macTime = regRead(MACHW_TIMLO_REG)
  var schedResult: uint32 = 0
  var transitionResult: uint32 = 0

  if td.endActive != 0:
    let threshold = blPsParamsView().trafficThreshold

    # Compute direction flags using sltu comparison against threshold
    var dirFlags: uint32 = 0
    # bit 0: counter at offset 24 >= threshold (not less than)
    if td.rxCount >= threshold:
      dirFlags = dirFlags or 1
    # bit 1: counter at offset 28 >= threshold
    if td.txCount >= threshold:
      dirFlags = dirFlags or 2

    # Check pending TX at offset 16
    var bidir: uint32 = 0
    if td.period != 0:
      dirFlags = dirFlags or 8
      bidir = 1

    # Check TX/RX byte counters at offsets 32,36 against threshold
    if td.psRxCount >= threshold:
      dirFlags = dirFlags or 4
    if td.psTxCount >= threshold:
      dirFlags = dirFlags or 8

    # Call wifi_hosal_pm_post_event (blob: direct call at 0x60)
    wifi_hosal_pm_post_event(4, 0, addr schedResult)

    if schedResult != 0:
      transitionResult = ps_traffic_status_update(td.vifIdx, bidir)
    else:
      # Check for direction change
      let changed = (td.prevFlags.uint32 xor dirFlags) and 0x0C
      if changed != 0:
        # Direction changed: call ps_traffic_status_update
        let dirBits = dirFlags and 0x0C
        # Log via platform ops
        let logFnPtr = blOpsFunc(204)
        if logFnPtr != nil:
          type LP = proc(level: uint32, tag, file: cstring, line: cint,
                         format: cstring) {.cdecl, varargs.}
          let txStatus: cstring = if (dirFlags and 4) != 0: "TX" else: "nul"
          let rxStatus: cstring = if (dirFlags and 8) != 0: "RX" else: "nul"
          cast[LP](logFnPtr)(1, nil, "td.c", 200, "Power Status %s:%s\r\n",
                            txStatus, rxStatus)
        # Notify traffic status change
        transitionResult = ps_traffic_status_update(td.vifIdx, dirBits.uint32)

    # Store new flags
    td.prevFlags = dirFlags.uint8

  # Reset all counters (always, even if not active)
  let vifIdx = td.vifIdx
  td.clearTrafficCounters()

  # Compute VIF active status and reschedule timer
  let vif = vifChannelForIdx(vifIdx)
  let vifConnected = vif.chanCtxt
  let isActive = (vifConnected == chanEnvView().currentCtxt).uint8
  td.endActive = isActive
  if transitionResult != 0:
    return
  let timerTarget = macTime + blPsParamsView().trafficPeriod
  mm_timer_set(tdEntry, timerTarget)

proc phyif_utils_decode*(rxvec: pointer, rssi: ptr int8): uint32 {.exportc, cdecl.} =
  ## Decode RSSI with the vendor RX-vector bit fields and signed arithmetic.
  let rxv = phyRxVectorAt(rxvec)
  let format = (rxv.formatBitsWord shr 16) and 7'u32
  let rate = (rxv.mcsBitsWord shr 12) and 15'u32
  let decoded = if format > 1 or rate > 3:
    # The wide sample is signed; integer division truncates toward zero.
    cast[int16](rxv.rssiRaw.uint16).int32 div 122
  else:
    # CCK uses only the signed low byte. Keep the vendor's binary64 scaling.
    ((-cast[int8](rxv.rssiLo).int32).float64 * 0.7).int32
  rssi[] = cast[int8](decoded)
  return 0
