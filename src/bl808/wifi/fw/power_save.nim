# ###########################################################################
#                  PS: Power Save
# ###########################################################################

proc ps_init*() {.exportc, cdecl.} =
  ## Initialize power save module.
  ## From disassembly: memset(ps_env, 0, 56), then stores two timer callback
  ## function pointers:
  ##   ps_env[4] (byte offset 16) = ptr to ps_uapsd_timer_handle
  ##   ps_env[10] (byte offset 40) = ptr to ps_tx_null_timer_handle
  let ps = psEnvView()
  discard c_memset(ps, 0, sizeof(PsEnvView).csize_t)
  # Store timer callback function pointers (blob: ps_env[16] and ps_env[40])
  ps.uapsdTimerCallback = cast[pointer](ps_uapsd_timer_handle)
  ps.txNullTimerCallback = cast[pointer](ps_tx_null_timer_handle)

proc ps_set_mode*(mode: uint8) {.exportc, cdecl.} =
  ## Set power save mode (115 instructions in blob).
  ##
  ## Register map: s0=ps_env s1=VIF list (from chan_env) s2=mode s3=chan_env s4=1
  ## Stores mode at ps_env+1. Checks ps_env+52 (flags):
  ##   if (flags & 1) && (flags & 6): deferred -- set bit 4, store at +53, return.
  ## mode==0: clear ps flag, clear MACHW CCA bit 2, walk VIFs
  ## mode==2: log line 702, set bit 0 in ps_env+52
  ## mode!=0: set MACHW CCA bit 2, walk VIFs
  ## VIF walk: for each STA VIF with connless!=0: call ps_check and update counter.
  let ps = psEnvView()
  ps.mode = mode

  # Check deferred flags at ps_env+52
  let flags52 = ps.flags
  if (flags52 and 1) != 0:
    if (flags52 and 6) != 0:
      ps.flags = flags52 or 0x10
      ps.deferredMode = mode
      return

  if mode == 0:
    # Disable PS: clear enable byte, clear MACHW bit
    # (blob: ps_disable_cfm_handle at 0x9A)
    ps.enabled = 0
    let r = volatileLoad(cast[ptr uint32](0x24B0004C'u32))
    volatileStore(cast[ptr uint32](0x24B0004C'u32), r and not 4'u32)
    # PS disable confirm (blob: ps_disable_cfm_handle at 0x9A)
    let vifIdxForDisable = cast[uint8](ps.statusFlags and 0xFF)
    let vifEntryDisable = cast[pointer](vifChannelForIdx(vifIdxForDisable))
    discard ps_disable_cfm_handle(vifEntryDisable)
  else:
    if mode == 2:
      # Deep sleep: log at line 702, set enable flag bit 0
      let logFn = getLogFunc(204)
      if logFn != nil:
        type LP = proc(a: uint32, b: uint32, c: cstring, d: uint32) {.cdecl, varargs.}
        cast[LP](logFn)(1, 0, "ps.c", 702)
      ps.flags = ps.flags or 1
    # Enable PS: set MACHW bit
    let r = volatileLoad(cast[ptr uint32](0x24B0004C'u32))
    volatileStore(cast[ptr uint32](0x24B0004C'u32), r or 4'u32)

  # .L39: Load active VIF linked-list head from vif_mgmt_env.
  var vifNode = cast[pointer](vifMgmtEnvView().activeList.first)
  # Clear ps_env flag bytes at offsets 8 and 29
  ps.pendingCount = 0
  ps.psActive = 0
  var cfmCallback: pointer  # s3: ps_disable_cfm or ps_enable_cfm fn ptr
  if mode == 0:
    cfmCallback = cast[pointer](ps_disable_cfm)
  else:
    cfmCallback = cast[pointer](ps_enable_cfm_handle)

  # .L42: Walk VIF linked list (blob: VIF walk with chan_is_on_channel + txl_frame_send_null_frame)
  var nullFrameQueued: bool = false
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
          discard txl_frame_send_null_frame(vif.staIdx, cfmCallback,
                                            pointerAddrU32(vifNode))
    # Next VIF: offset 0 is next pointer
    vifNode = vif.next

  # .L42 exit: check ps_env+8 counter
  if ps.pendingCount == 0:
    return  # No VIFs accepted PS change

  # PS enable/disable completion (blob: ps_enable_cfm_handle at 0x14E or via s3 callback)
  if mode != 0:
    let vifIdxForPs = cast[uint8](ps.statusFlags and 0xFF)
    let vifEntryForPs = cast[pointer](vifChannelForIdx(vifIdxForPs))
    ps_enable_cfm_handle(vifEntryForPs)

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

proc ps_check_frame*(rxHdr: pointer, frameFlags: uint32, vifEntry: pointer) {.exportc, cdecl.} =
  ## Check received frame for PS state change.
  ## From blob (114 instrs): checks ps_env enabled. Parses frame control from
  ## rxHdr to determine frame type. For data frames, checks UAPSD trigger/delivery.
  ## For non-PS-Poll QoS null frames with matching BSSID, may trigger sleep transition.
  ## Sets/clears bits in vif[4] based on frame analysis.
  let ps = psEnvView()
  let vif = vifChannelAt(vifEntry)

  # Check PS enabled
  if ps.enabled == 0: return

  # Load frame control from rxHdr
  let hdr = macDataFrameAt(rxHdr)
  let frameCtrl = hdr.frameControl

  # Check Addr1 group bit (bit 0 of rxHdr[4])
  let addr1Group = hdr.addr1[0] and 1'u8
  if addr1Group != 0:
    # Group-addressed frame: check if protected frame
    let protectedBit = frameCtrl and 0x2000'u16
    if protectedBit != 0:
      if vif.psOptions != 0:
        # Clear bit 1 in vif[4]
        var flags = vif.flags
        flags = flags and not 2'u32
        vif.flags = flags
    return

  # Check A-MSDU flag (bit 9 of frameFlags)
  if (frameFlags and 0x200'u32) != 0:
    return

  # PS mode active check (ps_env byte 29). Blob simply returns here when
  # psMode29 == 0; previous Nim inserted a vif_mgmt_bcn_to_prog(vif) call
  # that reprograms the next-beacon timer — an action blob never performs
  # from ps_check_frame.
  if ps.psActive == 0:
    return

  # Check frame subtype (bits [7:4] of frame control)
  let subtypeBits = frameCtrl and 0x00F0'u16
  let typeBits = frameCtrl and 0x000C'u16

  # Check if frame is QoS data (subtype bits 3,0 = 1,0,0,0 = 0x88)
  if (frameCtrl and 0x88) != 0x88:
    # Not QoS data: check for UAPSD trigger
    if (frameCtrl and 0x0C) != 0:
      return  # not data type
    # Check UAPSD bitmap for trigger
    let uapsdBitmap = vif.uapsdBitmap
    if (uapsdBitmap and 8) == 0:
      return

    # UAPSD triggered: read MAC time and store at vif[100]
    let macTime = regRead(MACHW_TIMLO_REG)
    vif.psLastTime = macTime
    return

  # QoS data frame: parse priority and check UAPSD
  # Load QoS TID from frame header (offset depends on addr4 presence)
  let has4Addr = (frameCtrl and 0x0300'u16) == 0x0300'u16
  let qosTid =
    if has4Addr:
      macQos4AddrFrameAt(rxHdr).qosCtrl
    else:
      macQosDataFrameAt(rxHdr).qosCtrl

  # Extract TID (bits 0-2) and map to AC
  let tid = qosTid and 7
  # Load AC mapping from per-VIF UAPSD config
  let acMap = vif.uapsdBitmap

  # Shift UAPSD bitmap by TID's AC to check trigger
  let acBit = (acMap.uint32 shr tid.uint32) and 1
  if acBit == 0:
    return

  # UAPSD delivery enabled for this AC: store MAC time
  let macTime = regRead(MACHW_TIMLO_REG)
  vif.psLastTime = macTime

  # Check MoreData bit (bit 4 of QoS field)
  if (qosTid and 0x10) == 0:
    return

  # MoreData set: check if we should suppress UAPSD trigger
  if (ps.flags and 8) != 0:
    return  # scanning, don't trigger

  # Trigger traffic request
  let vifIdx2 = vif.vifIdx

  # Clear bit 2 in vif[4]
  var flags2 = vif.flags
  flags2 = flags2 and not 4'u32
  vif.flags = flags2

  # Check if FromDS+ToDS match BSSID
  let fc16Check = frameCtrl and 0x2000'u16
  if fc16Check != 0:
    return

  # Trigger traffic detection and PS-Poll (blob calls at 0xfe and 0x11a)
  td_pck_ps_ind(vif.vifIdx, 1)  # traffic detection: vifIdx, direction=RX
  discard ps_send_pspoll(vifEntry)  # send PS-Poll frame

proc ps_check_tx_frame*(vifIdx: uint8, staIdx: uint8): bool {.exportc, cdecl.} =
  ## Check if TX frame needs PS handling.
  ## From blob (60 instrs): checks ps_env enabled, validates vif/sta indices.
  ## Computes STA entry = sta_info_tab + staIdx * 368. Checks vif[86] (type),
  ## vif[88] (PS capable), vif[104] (UAPSD bitmap). If UAPSD trigger AC matches,
  ## logs and sets bit 3 in vif[4], reads MAC time to vif[100].
  ## Otherwise calls vif_mgmt_bcn_to_prog and returns false.
  if psEnvView().enabled == 0:
    return false

  if vifIdx == 0xFF or staIdx == 0xFF:
    return false

  let sta = staInfoForIdx(staIdx)

  # Get VIF entry from STA's VIF pointer or compute from staEntry[39]
  let staVifIdx = sta.instNbr
  let vif = vifChannelForIdx(staVifIdx)

  # Check VIF type (offset 86): must not be monitor (type != monitor)
  if vif.vifType != VIF_TYPE_STA:
    return false

  # Check PS capable (offset 88)
  if vif.state == 0:
    return false

  # Check UAPSD bitmap (vif[104]): shift by STA's AC
  # Get AC from STA TX descriptor
  let ac = sta.infoIdx
  let acBit = (vif.uapsdBitmap.uint32 shr ac.uint32) and 1
  if acBit != 0:
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

proc ps_polling_frame*() {.exportc, cdecl.} =
  ## Send PS-Poll frame. Blob (2 instrs): auipc t1, R_RISCV_CALL ps_send_pspoll;
  ## jr t1 — a pure tail-call that passes the caller's a0 through untouched.
  ## We preserve that ABI by capturing a0 via inline asm so Nim doesn't
  ## overwrite it with `nil`.
  var vifEntry {.noinit.}: pointer
  {.emit: ["asm volatile(\"mv %0, a0\" : \"=r\"(", vifEntry, ") );"].}
  discard ps_send_pspoll(vifEntry)

proc ps_traffic_null_1_recovery*() {.exportc, cdecl.} =
  ## Recovery after null frame 1 failure.
  discard

proc ps_check_tx_status_part0_nim*(vifEntry: pointer, completionFn: pointer): uint32
  {.exportc: "ps_check_tx_status_part0_nim", cdecl.} =
  ## Nim-side implementation. Matches blob `ps_check_tx_status.part.0`.
  ## Blob flow:
  ##   retry = ++vif[95] (u8, zext)
  ##   threshold = *(u32*)(ps_env + 12)     // WORD, not byte
  ##   if retry == threshold:
  ##       ps_env[0] = 0
  ##       mm_send_connection_loss_ind(vif /*truncated to vifIdx*/, 21)
  ##       return 1
  ##   if retry == threshold >> 1:
  ##       wifi_hosal_pm_post_event(4, 1, 0)
  ##       return 1
  ##   if ps_env[8] == 0:
  ##       return 1
  ##   rc = txl_frame_send_null_frame(staIdx=vif[96], completionFn, vifEntry)
  ##   if rc == 0: return 0
  ##   (log via g_bl_ops_funcs[1] if non-null; ignored for correctness)
  ##   return 0
  if vifEntry == nil: return 0'u32
  let vifU = cast[uint](vifEntry)
  let ps = psEnvView()
  let vif = vifChannelAt(vifEntry)
  let retry = vif.psNullRetry + 1'u8
  vif.psNullRetry = retry
  # Blob loads a WORD (lw) at ps_env+12. Compare retry (u8) against low byte.
  let threshold = ps.nullRetryLimit
  let thresholdLo = cast[uint8](threshold and 0xFF)
  if retry == thresholdLo:
    ps.enabled = 0
    mm_send_connection_loss_ind(cast[uint8](vifU and 0xFF), 21'u16)
    return 1'u32
  # Second branch: retry == threshold >> 1
  let halfThreshold = cast[uint8]((threshold shr 1) and 0xFF)
  if retry == halfThreshold:
    wifi_hosal_pm_post_event(4'u32, 1'u32, nil)
    return 1'u32
  # If ps_env[8] == 0 -> no outstanding enable count, return 1
  if ps.pendingCount == 0:
    return 1'u32
  # Send null frame: blob passes (a0=staIdx, a1=completionFn, a2=vifEntry).
  # Our Nim `txl_frame_send_null_frame` has signature (uint8, uint8, bool) but
  # the blob calls it with (staIdx, completionFn, vifEntry). Emit a raw call
  # that pins a0/a1/a2 to the exact values the callee expects — the function
  # stores a2 at desc[212] (completion arg) verbatim, which matches blob.
  let staIdx = vif.staIdx
  var rc: uint32
  {.emit: ["""
  {
    register unsigned long _a0 __asm__("a0") = (unsigned long)""", staIdx, """;
    register unsigned long _a1 __asm__("a1") = (unsigned long)""", completionFn, """;
    register unsigned long _a2 __asm__("a2") = (unsigned long)""", vifEntry, """;
    __asm__ volatile (
      "call txl_frame_send_null_frame"
      : "+r"(_a0), "+r"(_a1), "+r"(_a2)
      :
      : "ra","memory","a3","a4","a5","a6","a7",
        "t0","t1","t2","t3","t4","t5","t6");
    """, rc, """ = (unsigned int)_a0;
  }
  """].}
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
  let ps = psEnvView()
  # Check scanning flag: ps_env byte 52, bit 2
  if (ps.flags and 4) != 0:
    return
  let hasTxCfm = (statusFlags and 0x00800000'u32) != 0
  if not hasTxCfm:
    # No HW confirmation bit: check TX status via ps_check_tx_status.part.0
    # (GCC-generated partial function name, need asm label to reference it)
    var checkResult: uint32
    {.emit: """
extern unsigned int ps_check_tx_status_part0(void*, void*) __asm__("ps_check_tx_status.part.0");
""".}
    {.emit: [checkResult, " = ps_check_tx_status_part0(", vifEntry, ", (void*)", ps_disable_cfm, ");"].}
    if checkResult == 0:
      return
    # Non-zero means TX confirm arrived, fall through to decrement path
  # Decrement TX confirm counter and clear timer
  let cnt = ps.pendingCount
  if cnt == 0:
    return
  let newCnt = cnt - 1
  ps.pendingCount = newCnt
  mm_timer_clear(psTxNullTimer())
  if newCnt != 0:
    return
  # All confirms received: finalize disable
  discard ps_disable_cfm_handle(vifEntry)

proc ps_traffic_status_update*(vifIdx: uint8, status: uint32) {.exportc, cdecl.} =
  ## Update traffic status for PS decisions.
  ## From blob (70 instrs): checks ps_env enabled and PS mode flags.
  ## If status == 0 (idle): walks the registered VIF list looking for VIF with
  ## matching vif_idx. Checks VIF type (offset 86), PS capable (offset 88), and
  ## traffic-detection flags for U-APSD delivery activity.
  ## Then checks ps_env scanning flag (byte 52, bit 3): if s0 (found flag) is set
  ## and not scanning, tail-calls ps wakeup function.
  let ps = psEnvView()

  # Check PS enabled
  if ps.enabled == 0: return

  # Check PS mode flags at ps_env[52]
  let psFlags = ps.flags
  if (psFlags and 1) == 0: return   # PS not in correct mode
  if (psFlags and 6) != 0: return   # mode bits 1-2 set: skip

  var foundVif = false
  if status == 0:
    # Traffic idle: walk the registered VIF list looking for matching vif_idx.
    var vifCur = cast[pointer](vifMgmtEnvView().activeList.first)
    while vifCur != nil:
      let vif = vifChannelAt(vifCur)
      if vif.vifIdx == vifIdx:
        # Found matching VIF: check PS capable, type, UAPSD
        if vif.state != 0:
          if vif.vifType == VIF_TYPE_STA:
            let trafficFlags = tdEntryForVif(vif.vifIdx).prevFlags
            if (trafficFlags and 0x0C) != 0:
              # Log via debug function (blob: dbg_snp_write at line 1187)
              let logFn = getLogFunc(0)
              if logFn != nil:
                logFn(1, 0, nil, 1187)
              foundVif = true
        break  # only check first matching VIF
      vifCur = vif.next

  # Check scanning flag at ps_env[52] bit 3
  let scanning = (ps.flags and 8) != 0

  if not foundVif:
    if scanning:
      return
    return  # no VIF matched, not scanning

  # Found matching VIF: if not scanning, trigger DPSM update (blob: ps_dpsm_update)
  if not scanning:
    ps_dpsm_update(1)  # enable=1: enter dynamic PS mode

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
  ## U-APSD timer callback (91 instrs, stored in ps_env[4] during ps_init).
  ## Walks the VIF info list looking for active STA VIFs in power save.
  ## For each eligible VIF, checks if UAPSD trigger timeout expired.
  ## If expired, logs a warning and sends a QoS null frame to trigger delivery.
  ## Finally schedules the next timer or clears the UAPSD timer state.
  ##
  ## Assembly trace:
  ##   s0 = vif_info_tab linked list head (from vif_mgmt_env)
  ##   s6 = found_any flag (0 initially)
  ##   s1 = 0x24B00 base (for MACHW_TIMLO_REG)
  ##   s2 = ps_env base
  ##   Loops: while s0 != nil:
  ##     check vif.type(+86) != 0 -> skip
  ##     check vif.active(+88) == 0 -> skip
  ##     check vif.ps_flag(+104) == 0 -> skip
  ##     call ps_check_tbtt(vif) -> if 0 -> skip
  ##     check ps_env[32] timer offset: if (now - vif[100]) expired -> trigger
  ##       log warning, set vif[4] |= 8, send ke_msg(7=RXU_NULL_DATA, ...)
  ##       update vif[100] = now
  ##     s0 = vif.next (follow linked list)
  ##   If s6==0 (nothing found): clear timer state, return
  ##   Else: schedule next UAPSD timer with mm_timer_set
  var vifPtr = cast[pointer](vifMgmtEnvView().activeList.first)
  var foundAny = false
  let ps = psEnvView()
  let macTime = macTimeNow()
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
    # Check timer expiry: ps_env[32] has half-period, compare with vif[100] timestamp
    let halfPeriod = ps.uapsdPeriod
    let lastTime = vif.psLastTime
    let elapsed = macTime - (halfPeriod shr 1) - lastTime
    if cast[int32](elapsed) < 0:
      # Timer expired: log and trigger
      let logFn = getLogFunc(204)
      if logFn != nil:
        let log = cast[PlatformLogFunc](logFn)
        log(1, 0, nil, 567)
      # Set UAPSD trigger flag
      vif.flags = vif.flags or 0x08
      # Send QoS null frame (blob: txl_frame_send_qosnull_frame)
      discard txl_frame_send_qosnull_frame(vif.staIdx, 3'u16, nil, 0)
      # Update timestamp
      vif.psLastTime = macTime
    vifPtr = vif.next
  if not foundAny:
    # No active UAPSD VIFs: clear timer state
    ps.uapsdTimerState = 0
    return
  # Schedule next timer: tail-call mm_timer_set with UAPSD timer offset
  let timerTarget = macTime + ps.uapsdPeriod
  mm_timer_set(psUapsdTimer(), timerTarget)

proc ps_tx_null_timer_handle*() {.exportc, cdecl.} =
  ## TX null frame timer callback (80 bytes in blob).
  ## Blob: checks ps_env flags, then dispatches:
  ##   ps_disable_cfm_handle, ps_enable_cfm_handle, txl_cntrl_clear_ac
  let ps = psEnvView()
  let flags = ps.flags
  if (flags and 1) == 0:
    return
  let cnt = ps.pendingCount
  if cnt == 0:
    return
  ps.pendingCount = cnt - 1
  if cnt - 1 != 0:
    return
  # All null frames confirmed: dispatch based on PS mode
  if (flags and 2) != 0:
    discard ps_disable_cfm_handle(nil)
  elif (flags and 4) != 0:
    ps_enable_cfm_handle(nil)
  # Clear any pending TX on AC3 (blob: txl_cntrl_clear_ac)
  txl_cntrl_clear_ac(3)

proc pm_force_sleep_check*(): bool {.exportc, cdecl.} =
  ## Check if forced sleep is allowed.
  ## From blob (ps.o, 2 instrs): always returns 1 (true) - stub.
  return true

proc set_mac_to_doze*(): uint32 {.exportc, cdecl.} =
  ## Transition MAC HW to doze (low-power) state (148 bytes in blob, 40 instrs).
  ## From blob: sets bit 6 (0x40) in MAC_CTRL reg (0x24B0004C), then reads
  ## MAC_STATUS (0x24B00038). If low nibble != 0 (MAC still active), calls
  ## assert fn ptr and diagnostic fn ptr from mm_env before proceeding.
  ## Sets doze_flag global = 1, writes 0x20 (DOZE) to MAC_STATUS.
  # Set bit 6 (doze request) in MAC control register
  var ctrlReg = regRead(MACHW_STATUS_REG)
  ctrlReg = ctrlReg or 0x40'u32
  regWrite(MACHW_STATUS_REG, ctrlReg)
  # Read current state from MAC state/control register
  let curState = regRead(MACHW_STATE_CNTRL_REG) and 0x3F'u32
  if curState != 0:
    # MAC not idle - call assert and diagnostic function pointers
    let mmBase = cast[uint](addr mm_env[0])
    let assertFn = cast[ptr pointer](mmBase + 204)[]
    if assertFn != nil:
      cast[proc(a0: uint32, a1: uint32, file: pointer, line: uint32, rec: pointer) {.cdecl.}](assertFn)(
        TASK_MM.uint32, 0, nil, 286, nil)
    let diagFn = cast[ptr pointer](mmBase + 12)[]
    if diagFn != nil:
      cast[proc(a0: pointer, line: uint32, file: pointer, param: pointer) {.cdecl.}](diagFn)(
        nil, 287, nil, nil)
  # Set doze-in-progress flag
  psDozeEnvView().dozeInProgress = 1
  # Write DOZE command (0x20) to MAC state register
  regWrite(MACHW_STATE_CNTRL_REG, 0x20'u32)
  return 0

proc wait_mac_goto_idle*(): uint32 {.exportc, cdecl.} =
  ## Wait for MAC to reach IDLE state.
  ## From blob (ps.o, 33 instrs): reads state register, stores pre-state byte,
  ## clears bit 31 in INTC unmask, sets bit 2 (IDLE command), writes 0 to
  ## state register. Polls INTC status bit 2 with timeout (0x4C4B3F iterations).
  ## After poll: reads final state, writes 4 to INTC ack, clears bit 2,
  ## sets bit 31 back. Returns 0 if idle reached, 1 if state non-zero.
  let curState = regRead(MACHW_STATE_CNTRL_REG) and 0x3F'u32
  if curState == 0:
    return 0  # Already idle
  # Clear bit 31 of INTC unmask (offset 0x074)
  let intcCtrl = MACHW_INTC_BASE + 0x074'u
  var unmask = regRead(intcCtrl)
  unmask = unmask and 0x7FFFFFFF'u32
  regWrite(intcCtrl, unmask)
  # Set bit 2 (idle command) and clear current state
  regWrite(intcCtrl, unmask or 0x04'u32)
  regWrite(MACHW_STATE_CNTRL_REG, 0'u32)
  # Poll for completion: read timestamp for timeout
  let startTime = macTimeNow()
  let timeout = 0x4C4B3F'u32
  var status = regRead(MACHW_INTC_BASE + 0x06C'u)
  while (status and 0x04'u32) == 0 and macTimeNow() - startTime < timeout:
    status = regRead(MACHW_INTC_BASE + 0x06C'u)
  # Read final state
  let finalState = regRead(MACHW_STATE_CNTRL_REG) and 0x3F'u32
  # Ack: write 4 to ack register, clear bit 2
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
  ## Wait for MAC to return to its saved pre-state.
  ## From blob (ps.o, 23 instrs): reads saved pre-state byte,
  ## if 0 returns immediately. Shifts left by 4 (into bits [7:4]),
  ## writes to state register, then polls until state[3:0] matches.
  let preState = psDozeEnvView().preState
  if preState == 0:
    return 0
  let targetBits = preState.uint32 shl 4
  if (targetBits and 0xFFFFFF0F'u32) != 0:
    assert_err("ps.c", "ps.c", 1465)
  regWrite(MACHW_STATE_CNTRL_REG, targetBits)
  # Poll until state matches pre-state
  discard waitRegLowNibbleEquals(MACHW_STATE_CNTRL_REG, preState.uint32)
  return 0

proc wakeup_from_doze_done*(): uint32 {.exportc, cdecl.} =
  ## Complete doze wakeup: clear doze flag in INTC.
  ## From blob (ps.o, 6 instrs): clears bit 31 (0x80000000) in
  ## MACHW_INTC_BASE+0x048, returns 0.
  var reg = regRead(MACHW_INTC_BASE + 0x048'u)
  reg = reg and 0x7FFFFFFF'u32
  regWrite(MACHW_INTC_BASE + 0x048'u, reg)
  return 0

proc wakeup_from_doze_pre*(): uint32 {.exportc, cdecl.} =
  ## Prepare wakeup from doze state.
  ## From blob (ps.o, 38 instrs): clears bit 31 of INTC+0x074, writes 4 to INTC+0x070,
  ## sets bit 2 of INTC+0x074, sets bit 31 of INTC+0x048. Clears doze flag.
  ## Polls INTC+0x06C bit 2 with short spin (501 iterations).
  ## Then polls with timestamp timeout (0x4C4B3F). When done, waits for
  ## state register [3:0] to reach 0 (idle), then writes 4 to INTC+0x070,
  ## clears bit 2, sets bit 31 of INTC+0x074.
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
  psDozeEnvView().dozeInProgress = 0
  # Short spin waiting for INTC bit 2
  var spins = 501'u32
  while spins > 0:
    let status = regRead(MACHW_INTC_BASE + 0x06C'u)
    if (status and 0x04'u32) != 0:
      break
    dec spins
  # Timestamp-based timeout poll
  let startTime = macTimeNow()
  let timeout = 0x4C4B3F'u32
  var status = regRead(MACHW_INTC_BASE + 0x06C'u)
  while (status and 0x04'u32) == 0 and macTimeNow() - startTime < timeout:
    status = regRead(MACHW_INTC_BASE + 0x06C'u)
  # Wait for state to go idle
  discard waitRegLowNibbleClear(MACHW_STATE_CNTRL_REG)
  # Final: ack, clear, set
  regWrite(MACHW_INTC_BASE + 0x070'u, 0x04'u32)
  unmask = regRead(intcCtrl)
  unmask = unmask and not 0x04'u32
  regWrite(intcCtrl, unmask)
  unmask = regRead(intcCtrl)
  unmask = unmask or 0x80000000'u32
  regWrite(intcCtrl, unmask)
  return 0

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
  ##     td_cfm_set_timer(s1[87], localStatus)
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
  var localStatus: uint8 = 0  # sp+12 in blob
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
    td_cfm_set_timer(vifIdxLocal, localStatus)
    result2 = 1
    # fall through to .L65
  else:
    # .L64: send basic message
    ps.enabled = 0
    ps.mode = 0
    ps.reserved02 = [0'u8, 0'u8]
    let destTask = ps.mode
    # ke_msg_send_basic(32, ps_env[1], 0)
    ke_msg_send_basic(32'u16, destTask, 0)
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
    ps_set_mode(ps.deferredMode)
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
  let ps = psEnvView()
  # State guard: if ps_env[52] & 2 set, abort (PS disable already pending)
  if (ps.flags and 2'u8) != 0:
    return
  # hw_cfm branch: if caller already confirmed TX (status bit 23 set), skip TX poll
  if (status and 0x00800000'u32) == 0:
    # Poll TX status via part.0 clone. Returns 1 when TX has settled, 0 to retry.
    var checkResult: uint32
    {.emit: """
extern unsigned int ps_check_tx_status_part0(void*, void*) __asm__("ps_check_tx_status.part.0");
""".}
    {.emit: [checkResult, " = ps_check_tx_status_part0(", vifEntry, ", (void*)", ps_enable_cfm, ");"].}
    if checkResult == 0:
      return
  # finalize path
  let cnt = ps.pendingCount
  if cnt == 0:
    return
  ps.pendingCount = cnt - 1
  # Clear TX-null timer at ps_env + 0x24 (byte offset 36, NOT 12)
  mm_timer_clear(psTxNullTimer())
  if ps.pendingCount != 0:
    return
  # Tail-call into handle
  ps_enable_cfm_handle(vifEntry)

proc ps_enable_cfm_handle*(vifEntry: pointer) {.exportc, cdecl, noinline.} =
  ## Finalize PS enable: update state, start timers.
  ## From blob (ps.o, 57 instrs): sets ps_env[29]=1 (PS active). If VIF has
  ## DTIM tracking and UAPSD enabled, starts UAPSD timer. Then checks
  ## ps_env[52] bits [2:0] for 5 (enable+confirm), clears bits, updates VIF.
  ## noinline: blob calls this from ps_dpsm_update, ps_tx_null_timer_handle,
  ## and ps_check_tx_status.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let ps = psEnvView()
  # Set PS-active flag
  ps.psActive = 1
  if vifEntry == nil: return
  let vif = vifChannelAt(vifEntry)
  # Check VIF DTIM tracking (offset 88) and UAPSD (offset 104)
  let dtim = vif.state
  if dtim != 0:
    let uapsd = vif.uapsdBitmap
    if uapsd != 0:
      # Start UAPSD timer
      let macTime = macTimeNow()
      mm_timer_set(psUapsdTimer(), macTime + ps.uapsdPeriod)
      # Clear VIF PS-transition flag
      vif.flags = vif.flags and not 0x08'u32
  # Check and finalize ps_env flags
  let flags = ps.flags
  if (flags and 0x05) == 5 and vifEntry != nil:
    # Clear enable bits, update VIF
    let newFlags = flags and not 0x0D'u8
    ps.flags = newFlags
    vif.flags = vif.flags and not 0x42'u32
    # Set PS confirmed in VIF[196]
    vif.keyPsState = 1
  else:
    # Send PS mode confirmation
    ps.enabled = 1
    ke_msg_send_basic(0x20'u16, ps.mode, 0)
    if vifEntry != nil:
      vif.keyPsState = 1

  # Blob .L94: check bit 4 of ps_env[52] for pending ps_set_mode
  let finalFlags = ps.flags
  if (finalFlags and 0x10) != 0:
    let clearedFlags = finalFlags and not 0x10'u8
    ps.flags = clearedFlags
    ps_set_mode(ps.deferredMode)

proc ps_dpsm_update*(enable: uint32) {.exportc, cdecl.} =
  ## Update DPSM state (334b in blob, ps.o).
  ## Blob: check active count, set flags/state, update MAC HW power ctrl,
  ## iterate VIF list calling ps_check_vif/ps_set_vif_mode (enable) or
  ## ps_set_mode_with_callback (disable), tail-call ps_do_sleep on enable done.
  let ps = psEnvView()
  if ps.pendingCount != 0:
    return  # transition in progress
  # Update flags and state bits
  let flags = ps.flags
  let envWord = ps.statusFlags
  if enable != 0:
    ps.flags = flags or 0x02  # enable pending
    ps.statusFlags = envWord or 0x08
  else:
    ps.flags = flags or 0x04  # disable pending
    ps.statusFlags = envWord and not 0x08'u32
  # Update MAC HW power ctrl register at 0x24B0004C
  # Blob: read reg, clear bit 2, set ((enable^1)<<2)
  let hwBase = 0x24B00000'u
  var pmReg = volatileLoad(cast[ptr uint32](hwBase + 0x4C))
  pmReg = pmReg and not 0x04'u32  # clear bit 2
  pmReg = pmReg or (((enable xor 1) and 1) shl 2)  # set bit 2 if disabling
  volatileStore(cast[ptr uint32](hwBase + 0x4C), pmReg)
  # Clear prevent-sleep flag
  ps.deferredMode = 0
  # Walk VIF linked list
  var vifPtr = cast[pointer](vifMgmtEnvView().activeList.first)
  while vifPtr != nil:
    let vif = vifChannelAt(vifPtr)
    let vifAddr = cast[uint](vif)
    if vif.vifType != VIF_TYPE_STA:
      vifPtr = vif.next
      continue
    let psCapable = vif.state
    if psCapable == 0:  # skip if not PS capable
      vifPtr = vif.next
      continue
    # Call chan_is_on_channel to validate VIF is on channel
    let checkResult = chan_is_on_channel(cast[pointer](vifAddr))
    if not checkResult:
      vifPtr = vif.next
      continue
    # Increment active counter, clear PS state, load PS mode
    let c = ps.pendingCount
    ps.pendingCount = c + 1
    vif.psNullRetry = 0
    if enable != 0:
      # Enable path: send null frame PM=1 (blob: txl_frame_send_null_frame)
      let staIdx = vif.staIdx
      discard txl_frame_send_null_frame(staIdx, cast[pointer](ps_enable_cfm), cast[uint32](vifAddr))
      ps.pendingCount = ps.pendingCount - 1
    else:
      # Disable path: send null frame PM=0 (blob: txl_frame_send_null_frame)
      let staIdx = vif.staIdx
      discard txl_frame_send_null_frame(staIdx, cast[pointer](ps_disable_cfm), cast[uint32](vifAddr))
      if ps.pendingCount == c + 1:
        ps.pendingCount = ps.pendingCount - 1
      else:
        # Store current VIF for async completion
        ps.currentVif = vifPtr
        # Set timer: MAC_TIMER + timeout offset
        let macTime = volatileLoad(cast[ptr uint32](hwBase + 0x120))
        let timeout = cast[uint32](ps.uapsdTimerCallback)
        mm_timer_set(psUapsdTimer(), macTime + timeout)
    vifPtr = vif.next
  # Post-loop: check if all done
  if ps.pendingCount != 0:
    return  # still pending
  if enable != 0:
    # Enable done: tail-call to sleep function
    ps_enable_cfm_handle(nil)
  else:
    # Disable done: notify
    discard ps_disable_cfm_handle(nil)

proc ps_send_pspoll*(vifEntry: pointer): uint8 {.exportc, cdecl, noinline.} =
  ## Send PS-Poll frame (206 bytes in blob, 84 instrs).
  ## noinline: blob calls this from ps_polling_frame (gap target).
  ## From blob (ps.o): reads sta_idx from vif[0x60]. Calls txl_frame_get(16)
  ## to allocate a 16-byte frame descriptor. Calls tpc_update_frame_tx_power.
  ## Builds PS-Poll 802.11 header: FC=0x00A4, Duration=AID|0xC000,
  ## Addr1=BSSID (from sta[4]), Addr2=own MAC (from vif[0x50]).
  ## Sets TX control flags (0x10000053), copies rate info from sta,
  ## calls txl_frame_push(txdesc, AC_VO=3). Returns 0 on success, 1 on fail.
  let vif = vifChannelAt(vifEntry)
  let staIdx = vif.staIdx
  # Allocate frame descriptor for 16-byte PS-Poll
  let txdesc = txl_frame_get(16)
  if txdesc == nil:
    return 1  # Allocation failed
  # Update TX power
  tpc_update_frame_tx_power(vifEntry, txdesc)
  let desc = hostTxDescAt(txdesc)
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
  # Push frame for transmission
  txl_frame_push(txdesc, 3)  # AC_VO = 3
  return 0

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
  ## From blob (bl.o, 13 instrs): linear scan tracking running maximum.
  ## Returns index of the entry with the highest value (0 if count==0 or
  ## levels[0] is already the max).
  if count == 0:
    return 0
  let p = cast[ptr UncheckedArray[uint8]](levels)
  var refVal = p[0]  # running max (unsigned byte)
  var bestIdx = 0'u32
  let n = count - 1
  var i = 0'u32
  while i < n:
    let entry = cast[int8](p[i + 1])  # blob uses lb (signed load)
    i += 1
    i = i and 0xFF  # blob: zext.b
    if cast[int8](refVal) >= entry:  # blob: bge (signed compare)
      continue
    refVal = cast[uint8](entry) and 0xFF  # blob: zext.b on new max
    bestIdx = i
  return bestIdx

proc ble_rf_ops*(enable: uint32) {.exportc, cdecl.} =
  ## BLE RF operations toggle (34 bytes in blob, 9 instrs).
  ## From blob: if enable == 0, calls wifi_hosal_rf_turn_off();
  ## else calls wifi_hosal_rf_turn_on(). Returns 0.
  proc wifi_hosal_rf_turn_on() {.importc, cdecl.}
  proc wifi_hosal_rf_turn_off() {.importc, cdecl.}
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
  ## If not set, decrements probe counter (mm_env[8]); when it reaches 0,
  ## resets to 10 and tail-calls mm_send_connection_loss_ind(vifEntry, 22).
  let mm = mmEnvView()
  if (status and 0x00800000'u32) != 0:
    mm.keepAliveLimit = 10  # reset counter at mm_env offset 32
    vifChannelAt(vifEntry).beaconTimeoutBase = macTimeNow()
  else:
    let cnt = mm.keepAliveLimit
    if cnt == 0:
      mm.keepAliveLimit = 10
      # Tail-call connection loss: blob passes vifEntry as a0, reason=22 as a1
      let vifIdx = vifChannelAt(vifEntry).vifIdx
      mm_send_connection_loss_ind(vifIdx, 22)
    else:
      mm.keepAliveLimit = cnt - 1

proc td_timer_end*(tdEntry: pointer) {.exportc, cdecl.} =
  ## End traffic detection timer and update TD state (312 bytes in blob, 79 instrs).
  ## From blob (td.o): reads MAC timestamp, computes traffic direction flags from
  ## TX/RX counters vs threshold, calls notification on direction change, then
  ## resets counters and reschedules timer.
  ##
  ## Entry layout: [0]=timer_hdr, [16]=period, [24]=rx_count, [28]=tx_count,
  ##   [32]=ps_rx_count, [36]=ps_tx_count, [40]=vif_idx, [41]=prev_flags,
  ##   [42]=active, [43]=timer-end active latch.
  let td = tdEntryAt(tdEntry)
  let macTime = regRead(MACHW_TIMLO_REG)
  var schedResult: uint32 = 0

  if td.endActive != 0:
    let config = tdConfig()
    let threshold = config.threshold

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

    if schedResult == 0:
      # Check for direction change
      let changed = (td.prevFlags.uint32 xor dirFlags) and 0x0C
      if changed != 0:
        # Direction changed: call ps_traffic_status_update
        let dirBits = dirFlags and 0x0C
        # Log via platform ops
        let logFnPtr = blOpsFunc(204)
        if logFnPtr != nil:
          let logFn = cast[PlatformLogFunc](logFnPtr)
          logFn(1, 0, nil, 200)
        # Notify traffic status change
        ps_traffic_status_update(td.vifIdx, dirBits.uint32)

    # Store new flags
    td.prevFlags = dirFlags.uint8

  # Reset all counters (always, even if not active)
  let vifIdx = td.vifIdx
  td.clearTrafficCounters()

  # Compute VIF active status and reschedule timer
  let vif = vifChannelForIdx(vifIdx)
  let vifConnected = vif.chanCtxt
  # Check if connection is active (blob: compares vif[64] with a global)
  let isActive = (vifConnected != nil).uint8
  td.endActive = isActive
  if isActive == 0:
    return
  # Reschedule: timer target = macTime + td_period (from config)
  let timerTarget = macTime + tdConfig().period
  mm_timer_set(tdEntry, timerTarget)

proc phyif_utils_decode*(rxvec: pointer, rssi: ptr int8): uint32 {.exportc, cdecl.} =
  ## Decode PHY RSSI from RX vector (128 bytes in blob, 36 instrs).
  ## From blob: reads word1(a0[4]) and byte19(a0[19]). Extracts format bits.
  ## Fast path (fmtVal > 1): combines bytes 19+20 as (byte20<<8)|byte19,
  ##   applies custom PHY insn, divides by 122, converts int→float→int.
  ## Slow path (fmtVal <= 1): reads word0, extracts MCS field, checks > 3,
  ##   calls 3 external functions (__floatsisf, __divsf3, __fixsfsi) for
  ##   float-based RSSI computation.
  ## Returns 0 on success, stores result byte via rssi ptr.
  let rxv = phyRxVectorAt(rxvec)
  let word0 = rxv.word0
  let word1 = rxv.word1
  # Extract format field from word1 via custom PHY insn (approximated)
  let fmtVal = word1 and 0x03'u32
  if fmtVal > 1:
    # Fast path: RSSI from combined bytes 19-20, divide by 122
    let scaled = rxv.rssiRaw.int32 div 122
    rssi[] = cast[int8](scaled and 0xFF)
  else:
    # Slow path: word0-based computation with float math
    let mcsField = (word0 shr 2) and 0x3F'u32  # extract from custom insn
    if mcsField > 3:
      # Use bytes 19-20 path anyway (fallback)
      let scaled = rxv.rssiRaw.int32 div 122
      rssi[] = cast[int8](scaled and 0xFF)
    else:
      # Float-based RSSI computation from MCS field.
      # Blob: __floatsidf(-mcsField) → __muldf3(*, 0.7) → __fixdfsi
      # Use cint (int32) so GCC picks __fixdfsi, matching the blob.
      let negVal: cint = -(mcsField.cint and 0xFF)
      var scaledC: cint = 0
      {.emit: [scaledC, " = (int)((double)", negVal, " * 0.7);"].}
      rssi[] = cast[int8](scaledC and 0xFF)
  return 0

