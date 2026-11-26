# ###########################################################################
#                  PS: Power Save
# ###########################################################################

# The transition machine (psOwn) and the PM bit's owner.
include ps_machine

when defined(bl808WifiBenchStaUapsd):
  type PsUapsdProbe = object
    attempted, rejected, acked, noAck, eosp, offChannel: uint32
    legacyPollQueued: uint32
  var nimFwDbgUapsd {.wifiCtrl, exportc: "nimfw_dbg_uapsd".}: PsUapsdProbe

  proc psUapsdProbeCfm(arg: pointer; status: uint32) {.cdecl.} =
    if not txlFrameCallbackCurrent() or (status and 0x80000000'u32) == 0:
      return
    if (status and 0x00800000'u32) != 0:
      inc nimFwDbgUapsd.acked
    else:
      inc nimFwDbgUapsd.noAck

proc ps_init*() {.exportc, cdecl.} =
  ## Initialize power save module.
  ## From disassembly: memset(ps_env, 0, 56), then stores two timer callback
  ## function pointers:
  ##   ps_env[4] (byte offset 16) = ptr to ps_uapsd_timer_handle
  ##   ps_env[10] (byte offset 40) = ptr to ps_tx_null_timer_handle
  ## A live transition is dropped first (ps_machine.nim); PS is off.
  psReset()
  let ps = psEnvView()
  discard c_memset(ps, 0, sizeof(PsEnvView).csize_t)
  # Store timer callback function pointers (blob: ps_env[16] and ps_env[40])
  ps.uapsdTimerCallback = cast[pointer](ps_uapsd_timer_handle)
  ps.txNullTimerCallback = cast[pointer](ps_tx_null_timer_handle)

proc ps_set_mode*(mode: uint8, requesterTask: uint8 = TASK_API.uint8) {.exportc, cdecl.} =
  ## Set power save mode (115 instructions in blob): an explicit transition
  ## (ps_machine.nim). Stores the requester task at ps_env+1, sets ps_env+52
  ## bit 0 for dynamic PS (mode 2, logged at line 702), sets the PM bit unless
  ## the mode is 0, and sends a null frame with ps_enable_cfm, or
  ## ps_disable_cfm for mode 0, to each active STA VIF on its channel.
  ##
  ## Runs only while PS is idle: mm_set_ps_mode_req_handler saves a request
  ## until then. The blob parks the mode behind a live DPSM transition
  ## (ps_env+52 bit 4, mode at +53) and replays it from the handles; nothing
  ## is parked here. During a scan or ROC dwell no frame is sent, so the
  ## transition ends here (ps_machine.nim); the blob sends it on the dwell's
  ## channel to the VIF that requested the dwell.
  let ps = psEnvView()
  ps.mode = requesterTask
  let stamp = psStart(psExplicit)
  ps.psActive = 0
  if mode == 2:
    let logFn = getLogFunc(204)
    if logFn != nil:
      type LP = proc(level: uint32, tag, file: cstring, line: cint,
                     format: cstring) {.cdecl, varargs.}
      cast[LP](logFn)(1, nil, "ps.c", 702, "Enable DPSM on\r\n")
  # An explicit mode replaces DPSM's awake state.
  ps.flags = (ps.flags and 0x06'u8) or uint8(mode == 2)
  psApplyPm(mode != 0)
  let callback =
    if mode == 0: cast[pointer](ps_disable_cfm) else: cast[pointer](ps_enable_cfm)
  # .L42: walk the active VIFs (vif_mgmt_env+8).
  var lastSta: pointer = nil
  var node = cast[pointer](vifMgmtEnvView().activeList.first)
  while node != nil:
    let vif = vifChannelAt(node)
    if vif.vifType == VIF_TYPE_STA:
      if vif.state != 0 and chan_is_on_channel(node):
        vif.psNullRetry = 0
        # The VIF's U-APSD categories start the trigger timer at the end.
        if vif.uapsdBitmap != 0:
          ps.psActive = 1
        if not psDwell(): psSend(node, callback, stamp)
      lastSta = node
    node = vif.next
  # The walk is done: the transition ends now unless frames are still out.
  psCount(lastSta)

proc ps_check_beacon*(rxHdr: pointer, unused: uint32, vifEntry: pointer) {.exportc, cdecl.} =
  ## Check beacon for PS-related information (TIM, DTIM).
  ## From blob (106 instrs): loads AID from sta_info_tab[vif[96]] at offset 36.
  ## Clears bit 0 of vif[4]. Checks ps_env enabled and not scanning.
  ## If no rx header, returns. Checks WMM flag at vif[94]. Parses TIM bitmap
  ## from the beacon to determine if traffic is buffered for our AID.
  ## A buffered AID, active PS, or multicast traffic requests a TIM indication
  ## before setting bit 6. Otherwise, clear bit 3 for all-AC UAPSD or bit 2.
  ## The logger and td_pack_tim_ind cannot change the VIF, its station or
  ## PS, so nothing is checked again after them.
  if vifEntry == nil: return
  let vif = vifChannelAt(vifEntry)
  let vifIdx = vif.vifIdx
  if vifIdx >= MAX_VIFS.uint8 or
      cast[pointer](vifChannelForIdx(vifIdx)) != vifEntry:
    return
  let ps = psEnvView()

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
  if vif.staIdx >= STA_INFO_TAB_ENTRIES.uint8: return
  let tim = timIeAt(rxHdr)
  if tim.ie.len < 4: return
  let aid = staInfoForIdx(vif.staIdx).aid
  let aidBytePos = aid shr 3
  let bitmapControl = tim.bitmapControl
  let bitmapStart = (bitmapControl and 0xFE'u8).uint16
  let timLen = tim.ie.len
  var buffered = false
  # Finish reading the RX buffer before calling the platform logger.
  if aidBytePos >= bitmapStart and
      aidBytePos.uint32 <= bitmapStart.uint32 + timLen.uint32 - 4:
    let timByte = tim.partialBitmap[(aidBytePos - bitmapStart).uint]
    buffered = (timByte and (1'u8 shl (aid and 7))) != 0

  if vif.psOptions == 0:
    let multicastBuffered = (bitmapControl and 1) != 0
    let logFn = getLogFunc(204)
    if logFn != nil:
      type LP = proc(level: uint32, tag, file: cstring, line: cint,
                     format: cstring) {.cdecl, varargs.}
      let format: cstring =
        if multicastBuffered: "BCMC: Set\r\n" else: "BCMC: BCN CLR\r\n"
      cast[LP](logFn)(1, nil, "ps.c",
                      if multicastBuffered: 882 else: 885, format)
    flags = vif.flags
    if multicastBuffered:
      flags = flags or 2'u32
    else:
      flags = flags and not 2'u32
    vif.flags = flags

  if not buffered:
    flags = vif.flags
    if (vif.uapsdBitmap and 0x0F) == 0x0F:
      flags = flags and not 8'u32
    else:
      flags = flags and not 4'u32
    vif.flags = flags

  if buffered or vif.psFlags != 0 or (vif.flags and 2) != 0:
    td_pack_tim_ind(vif.vifIdx)
    vif.flags = vif.flags or 64'u32
    # Static PS has no dynamic wake transition to retrieve a buffered BU.
    if buffered and (ps.flags and 0x0F) == 0 and
        vif.vifType == VIF_TYPE_STA and vif.state != 0 and
        (vif.uapsdBitmap and 0x0F) != 0x0F and chan_is_on_operational_channel(vifEntry):
      when defined(bl808WifiBenchStaUapsd):
        if ps_send_pspoll(vifEntry) == 0:
          inc nimFwDbgUapsd.legacyPollQueued
      else:
        discard ps_send_pspoll(vifEntry)

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
  if vifEntry == nil:
    return
  let vif = vifChannelAt(vifEntry)
  let vifIdx = vif.vifIdx
  if vifIdx >= MAX_VIFS.uint8 or
      cast[pointer](vifChannelForIdx(vifIdx)) != vifEntry:
    return
  if vif.psFlags == 0:
    return
  td_pack_tim_ind(vifIdx)
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
  ##   - QoS UAPSD EOSP clears vif[4] bit 3 and returns.
  ## The logger and td_pck_ps_ind cannot change the VIF or PS, and the VIF
  ## stays registered through ps_send_pspoll, so nothing is checked again.
  let ps = psEnvView()
  if ps.enabled == 0 or rxHdr == nil or vifEntry == nil:
    return
  let vif = vifChannelAt(vifEntry)
  let vifIdx = vif.vifIdx
  if vifIdx >= MAX_VIFS.uint8 or
      cast[pointer](vifChannelForIdx(vifIdx)) != vifEntry:
    return

  # Load frame control from rxHdr
  let hdr = macDataFrameAt(rxHdr)
  let frameCtrl = hdr.frameControl
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
      let qosTid =
        if (frameCtrl and 0x0300'u16) == 0x0300'u16:
          macQos4AddrFrameAt(rxHdr).qosCtrl
        else:
          macQosDataFrameAt(rxHdr).qosCtrl
      if (qosTid and 0x0F'u16) >= 8:
        return
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
        when defined(bl808WifiBenchStaUapsd):
          if (vif.flags and 8'u32) != 0:
            inc nimFwDbgUapsd.eosp
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
  if vif == nil or vif.vifIdx != staVifIdx:
    return false

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
    let logFn = getLogFunc(204)
    if logFn != nil:
      type LP = proc(level: uint32, tag, file: cstring, line: cint,
                     format: cstring) {.cdecl, varargs.}
      cast[LP](logFn)(1, nil, "ps.c", 1097, "tx frame: UAPSD\r\n")
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
  # The retry belongs to the live transition and carries its stamp, where
  # the blob passes the VIF (ps_machine.nim).
  let rc = txl_frame_send_null_frame(vif.staIdx, completionFn, psOwn.op.serial)
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

proc ps_disable_cfm*(env: pointer, statusFlags: uint32) {.exportc, cdecl.} =
  ## PS disable confirmation (114 bytes in blob): a null frame of an explicit
  ## PS off. Blob: returns while a sleep is live (ps_env+52 bit 2), retries a
  ## frame without bit 23 (ACK) through ps_check_tx_status.part.0, then
  ## decrements the count, clears the TX-null timer and calls
  ## ps_disable_cfm_handle at zero. `env` is the transition's stamp, where the
  ## blob passes the VIF; only a frame done without an ACK is retried, and a
  ## flushed or released one counts (psConfirm, ps_machine.nim).
  psConfirm(env, statusFlags, cast[pointer](ps_disable_cfm))

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
  ## Update the AC bitmap and arm the shared trigger timer as needed.
  if vifEntry == nil or ac >= 4:
    return
  let saved = irqSave()
  defer: irqRestore(saved)
  let vif = vifChannelAt(vifEntry)
  let bitMask = 1'u8 shl ac
  if enabled == 0:
    vif.uapsdBitmap = vif.uapsdBitmap and not bitMask
    return
  vif.uapsdBitmap = vif.uapsdBitmap or bitMask
  let ps = psEnvView()
  if ps.enabled == 0 or ps.uapsdTimerActive != 0:
    return
  let target = macTimeNow() + ps.uapsdPeriod
  ps.psActive = 1
  # Publish before timer callouts so a reset or clear can retire this arm.
  ps.uapsdTimerActive = 1
  mmTimerSetLocked(psUapsdTimer(), target, saved)

proc psUapsdTimerCurrent(delivery: ptr MmTimerMutation): bool =
  ## The trigger timer is still this delivery's: PS is on, the timer is
  ## active and nothing cleared or re-armed it meanwhile (a PS commit inside
  ## a trigger's TX). A TX reset does not end it.
  let ps = psEnvView()
  ps.enabled != 0 and ps.uapsdTimerActive != 0 and
    (delivery == nil or not delivery.cancelled)

proc psUapsdTriggerTid(bitmap: uint8): uint16 =
  # The installed bits are in hardware AC order: BK, BE, VI, VO.
  if (bitmap and 8) != 0: 7'u16
  elif (bitmap and 4) != 0: 4'u16
  elif (bitmap and 2) != 0: 0'u16
  else: 1'u16

proc ps_uapsd_timer_handle*() {.exportc, cdecl.} =
  ## Trigger eligible STA VIFs after half a U-APSD period without activity.
  ## Vendor uses a signed, wrapped deadline comparison and samples MAC time
  ## separately for each VIF, after each submission, and before rearming.
  ## Only a trigger's submission can run other firmware code: its frame
  ## allocation's pool recovery runs TX callbacks, which can stop or re-arm
  ## this timer (a PS commit) but cannot remove a VIF or a station. So only the
  ## timer's own delivery is checked again after it.
  let saved = irqSave()
  let delivery = mmTimerActiveDelivery(psUapsdTimer())
  irqRestore(saved)
  let ps = psEnvView()
  if not psUapsdTimerCurrent(delivery):
    return
  var foundAny = false
  var vifPtr = cast[pointer](vifMgmtEnvView().activeList.first)
  while vifPtr != nil:
    let vif = vifChannelAt(vifPtr)
    let staIdx = vif.staIdx
    if vif.vifType == VIF_TYPE_STA and vif.state != 0 and
        (vif.uapsdBitmap and 0x0F) != 0 and staIdx < STA_INFO_TAB_ENTRIES.uint8:
      foundAny = true
      # A scan or ROC temporarily prevents TX; it does not retire this VIF.
      if not chan_is_on_operational_channel(vifPtr):
        when defined(bl808WifiBenchStaUapsd):
          inc nimFwDbgUapsd.offChannel
      elif cast[int32](vif.psLastTime + (ps.uapsdPeriod shr 1) - macTimeNow()) < 0:
        let logFn = getLogFunc(204)
        if logFn != nil:
          type LP = proc(level: uint32, tag, file: cstring, line: cint,
                         format: cstring) {.cdecl, varargs.}
          cast[LP](logFn)(1, nil, "ps.c", 567, "apsd timer: UAPSD\r\n")
        let alreadyPending = (vif.flags and 8'u32) != 0
        # Publish before submission so an inline receive can clear EOSP state.
        vif.flags = vif.flags or 0x08'u32
        let tid = psUapsdTriggerTid(vif.uapsdBitmap)
        let callback: pointer =
          when defined(bl808WifiBenchStaUapsd): cast[pointer](psUapsdProbeCfm)
          else: nil
        when defined(bl808WifiBenchStaUapsd):
          inc nimFwDbgUapsd.attempted
        let submitted = txlSendUapsdTrigger(staIdx, tid, callback) == 0
        when defined(bl808WifiBenchStaUapsd):
          if not submitted:
            inc nimFwDbgUapsd.rejected
        if not psUapsdTimerCurrent(delivery):
          return
        if not submitted:
          if not alreadyPending:
            vif.flags = vif.flags and not 8'u32
        else:
          vif.psLastTime = macTimeNow()
    vifPtr = vif.next
  let timerTarget = if foundAny: macTimeNow() + ps.uapsdPeriod else: 0'u32
  let endSaved = irqSave()
  defer: irqRestore(endSaved)
  if not psUapsdTimerCurrent(delivery):
    return
  if not foundAny:
    # Clear the same activity byte that ps_uapsd_set checks before rearming.
    ps.uapsdTimerActive = 0
    return
  mmTimerSetLocked(psUapsdTimer(), timerTarget, endSaved)

proc ps_tx_null_timer_handle*(env: pointer) {.exportc, cdecl.} =
  ## TX null frame timer callback (80 bytes in blob): the deadline of a DPSM
  ## sleep. As the blob does, it ends the sleep as if every frame were
  ## confirmed, then flushes AC3 (tail call to txl_cntrl_clear_ac(3)). `env`
  ## is the sleep's stamp, where the blob's is the VIF of its last frame; that
  ## VIF is kept in the machine. The flushed confirmations are stale.
  if not opCurrent(psOwn.op, opEnvStamp(env)): return
  psFinish(if mmVifCurrent(psOwn.vif): psOwn.vif.vif else: nil)
  discard txl_cntrl_clear_ac(3)

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
  if not idle: return 1
  blDozeEnvView().dozeInProgress = 0
  0

proc ps_disable_cfm_handle*(vifEntry: pointer): uint32 {.exportc, cdecl.} =
  ## Commit a DPSM wake or an explicit PS off (232 bytes in blob, 59
  ## instrs). psFinish calls it while the transition's kind is still
  ## recorded (ps_machine.nim). Blob:
  ##   mm_timer_clear(&ps_env + 12); ps_env[0x1c] = 0
  ##   if (ps_env[52] & 3) == 3 and vif != nil:      ; DPSM wake
  ##     ps_env[52] = (ps_env[52] & ~2) | 8
  ##     wifi_hosal_pm_post_event(4, 0, &localStatus)
  ##     td_cfm_set_timer(vif[87], localStatus & 0xff); return value 1
  ##   else:                                          ; explicit PS off
  ##     ps_env[0] = 0; ke_msg_send_basic(MM_SET_PS_MODE_CFM, ps_env[1], 0)
  ##   if vif != nil:
  ##     if vif[91] != 0: ke_env[28] |= 1; ke_env[32] = 1; ke_evt_set(0x100)
  ##     vif[196] = 0
  ##   replay a parked mode (ps_env[52] bit 4)
  ## Here the transition's kind tells the two apart (the blob would turn PS
  ## off for a wake without a VIF), psFinish clears bit 1 and answers the
  ## request it holds, and no mode is parked.
  let ps = psEnvView()
  mm_timer_clear(psUapsdTimer())
  ps.uapsdTimerActive = 0
  if psOwn.kind == psWake:
    ps.flags = ps.flags or 8'u8
    var localStatus: uint32 = 0  # PM writes a word at sp+12 in the blob.
    wifi_hosal_pm_post_event(4, 0, cast[pointer](addr localStatus))
    if vifEntry != nil:
      td_cfm_set_timer(vifChannelAt(vifEntry).vifIdx, localStatus and 0xFF'u32)
      result = 1
  else:
    ps.enabled = 0
  if vifEntry != nil:
    let vif = vifChannelAt(vifEntry)
    vif.keyPsState = 0
    if vif.psFlags != 0:
      let kePs = keEnvPsFlags()
      kePs.flags = kePs.flags or 1
      kePs.staPending = 1
      ke_evt_set(0x100'u32)

proc ps_enable_cfm*(env: pointer, status: uint32) {.exportc, cdecl.} =
  ## PS enable confirmation (114 bytes in blob): a null frame of an explicit
  ## PS on or of a DPSM sleep. Blob: returns while a wake is live (ps_env+52
  ## bit 1), retries a frame without bit 23 (ACK) through
  ## ps_check_tx_status.part.0, then decrements the count and, at zero, clears
  ## the TX-null timer (ps_env+0x24) and calls ps_enable_cfm_handle. `env` is
  ## the transition's stamp, where the blob passes the VIF; only a frame done
  ## without an ACK is retried, and a flushed or released one counts
  ## (psConfirm, ps_machine.nim).
  psConfirm(env, status, cast[pointer](ps_enable_cfm))

proc ps_enable_cfm_handle*(vifEntry: pointer) {.exportc, cdecl, noinline.} =
  ## Commit a DPSM sleep or an explicit PS on (ps.o, 57 instrs). psFinish
  ## calls it while the transition's kind is still recorded (ps_machine.nim).
  ## Blob: if ps_env[29] (U-APSD in use) and a VIF: arm the U-APSD timer,
  ## set ps_env[28], and for an active VIF with U-APSD categories log line 208
  ## and clear vif[4] bit 3. Then (ps_env[52] & 7) == 5 (DPSM sleep) clears
  ## ps_env[52] bits 2-3, vif[4] bits 1 and 6 and sets vif[196]; otherwise
  ## (explicit) ps_env[0] = 1, MM_SET_PS_MODE_CFM to ps_env[1], vif[196] = 1;
  ## finally a parked mode is replayed. Here psFinish clears bit 2 and answers
  ## the request it holds, and no mode is parked.
  ## noinline: the blob calls it from ps_dpsm_update, ps_tx_null_timer_handle
  ## and ps_check_tx_status.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let ps = psEnvView()
  if ps.psActive != 0 and vifEntry != nil:
    mm_timer_set(psUapsdTimer(), macTimeNow() + ps.uapsdPeriod)
    ps.uapsdTimerActive = 1
    let vif = vifChannelAt(vifEntry)
    if vif.state != 0 and vif.uapsdBitmap != 0:
      let logFn = getLogFunc(204)
      if logFn != nil:
        type LP = proc(level: uint32, tag, file: cstring, line: cint,
                       format: cstring) {.cdecl, varargs.}
        cast[LP](logFn)(1, nil, "ps.c", 208, "enable cfm: UAPSD CLR\r\n")
      vif.flags = vif.flags and not 0x08'u32
  if psOwn.kind == psSleep:
    ps.flags = ps.flags and not 0x08'u8
    if vifEntry != nil:
      let vif = vifChannelAt(vifEntry)
      vif.flags = vif.flags and not 0x42'u32
      vif.keyPsState = 1
  else:
    ps.enabled = 1
    if vifEntry != nil:
      vifChannelAt(vifEntry).keyPsState = 1

proc ps_dpsm_update*(enable: uint32): uint32 {.exportc, cdecl, discardable.} =
  ## Start a DPSM wake (enable != 0) or sleep (334b in blob, ps.o): a
  ## transition (ps_machine.nim). The blob returns while the count is not
  ## zero; here nothing starts while any transition is live. It sets
  ## ps_env+52 bit 1 or 2, writes the PM bit (clear to wake) and sends a null
  ## frame to each active STA VIF on its channel: without a confirmation to
  ## wake, so a wake ends here; with ps_enable_cfm to sleep. The sleep's
  ## TX-null timer is armed with its stamp before the first frame is sent;
  ## the blob arms it in the loop after each send, with the VIF as its
  ## argument. During a scan or ROC dwell no frame is sent, so the transition
  ## ends here (ps_machine.nim); the blob's sleep frame, sent on the dwell's
  ## channel after it writes PM=1, says sleep, and the dwell's end then
  ## restores the bit saved at its start. Returns the wake's
  ## traffic-detection handoff.
  if psOwn.kind != psIdle: return 0
  let ps = psEnvView()
  let waking = enable != 0
  let stamp = psStart(if waking: psWake else: psSleep)
  psApplyPm(not waking)
  if not waking:
    ps.txNullTimerEnv = opStampEnv(stamp)
    mm_timer_set(psTxNullTimer(), macTimeNow() + blPsParamsView().txNullTimeout)
  var lastSta: pointer = nil
  var node = cast[pointer](vifMgmtEnvView().activeList.first)
  while node != nil:
    let vif = vifChannelAt(node)
    if vif.vifType == VIF_TYPE_STA:
      lastSta = node
      if vif.state != 0 and chan_is_on_channel(node) and not psDwell():
        vif.psNullRetry = 0
        if waking:
          discard txl_frame_send_null_frame(vif.staIdx, nil, 0)
        else:
          psSend(node, cast[pointer](ps_enable_cfm), stamp)
    node = vif.next
  psCount(lastSta)

proc ps_send_pspoll*(vifEntry: pointer): uint8 {.exportc, cdecl, noinline.} =
  ## Send PS-Poll frame (206 bytes in blob, 84 instrs).
  ## noinline: blob calls this from ps_polling_frame (gap target).
  ## From blob (ps.o): reads sta_idx from vif[0x60]. Calls txl_frame_get(16)
  ## to allocate a 16-byte frame descriptor. Calls tpc_update_frame_tx_power.
  ## Builds PS-Poll 802.11 header: FC=0x00A4, Duration=AID|0xC000,
  ## Addr1=BSSID (from sta[4]), Addr2=own MAC (from vif[0x50]).
  ## Sets TX control flags (0x10000053), copies rate info from sta,
  ## The blob pushes on VO; IEEE 802.11-2012 9.2.4.2 specifies BE.
  ## Returns 0 on push success, 1 on allocation/push failure.
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
  let pushRc = txl_frame_push(txdesc, API_AC_BE)
  return (pushRc xor 1'u8) and 0xFF'u8

proc mac_recovery*(): uint32 {.exportc, cdecl.} =
  ## bl.o calls assert_rec with the MAC idle failure and bl.c source.
  assert_rec("HW MAC still cann't enter idle", "bl.c", 299)
  return 0

{.emit: "__attribute__((noipa)) unsigned long bl_pwr_find(void*,unsigned long);".}
proc bl_pwr_find*(levels: pointer, count: uint32): uint32 {.exportc, cdecl.} =
  ## The vendor loads the first byte unsigned, then later bytes signed.
  ## Keep the first maximum under that comparison. Unlike the vendor's
  ## byte-sized cursor, the
  ## exported uint32 count must not wrap at 256 and leave the scan running.
  if levels == nil or count == 0:
    return 0
  let powerLevels = cast[ptr UncheckedArray[int8]](levels)
  var bestIndex = 0'u32
  var bestPower = cast[uint8](powerLevels[0]).int32
  for scanIndex in 1'u32 ..< count:
    if powerLevels[scanIndex].int32 > bestPower:
      bestIndex = scanIndex
      bestPower = cast[uint8](powerLevels[scanIndex]).int32
  return bestIndex

proc ble_rf_ops*(enable: uint32): uint32 {.exportc, cdecl.} =
  ## BLE RF operations toggle (34 bytes in blob, 9 instrs).
  ## From blob: if enable == 0, calls wifi_hosal_rf_turn_off();
  ## else calls wifi_hosal_rf_turn_on(). Returns 0.
  if enable == 0:
    wifi_hosal_rf_turn_off()
  else:
    wifi_hosal_rf_turn_on()
  0'u32

proc rfc_channel_ops*(channel: uint32): uint32 {.exportc, cdecl.} =
  ## RF channel operations (12 instrs in blob):
  ##   rf_init(0x02625A00)                    # 40 MHz crystal frequency
  ##   sm_set_channel_coex_connected()        # incoming channel is ignored
  ##   return 0
  discard channel
  rf_init(0x02625A00'u32)
  sm_set_channel_coex_connected()
  0'u32

proc vif_mgmt_bcn_to_evt*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Convert beacon reception to kernel event.
  ## From blob (vif_mgmt.o, 4 instrs): loads vifEntry[64], if non-nil
  ## tail-calls chan_bcn_to_evt(vifEntry). Otherwise returns.
  let chanCtxt = vifChannelAt(vifEntry).chanCtxt
  if chanCtxt != nil:
    chan_bcn_to_evt()

when defined(bl808WifiDiagTrafficProbeHistory):
  static: doAssert defined(bl808WifiDiagLinkDrop)
  const TrafficProbeHistoryLen = 8
  # Sequence (odd during a write), done without ACK, and not-done statuses,
  # then pairs of MAC time and raw callback status.
  var nimFwDbgTrafficProbeHistory {.wifiCtrl, volatile,
      exportc: "nimfw_dbg_traffic_probe_history".}:
    array[3 + 2 * TrafficProbeHistoryLen, uint32]

  proc mmRecordTrafficProbeCompletion(status: uint32) =
    let saved = irqSave()
    defer: irqRestore(saved)
    # Keep the first peer teardown's history through later associations.
    if volatileLoad(addr nimFwDbgPeerDisconnect[0]) != 0 or
        not txlFrameCallbackCurrent(): return
    let history = addr nimFwDbgTrafficProbeHistory
    let serial = volatileLoad(addr history[0])
    let slot = 3 + 2 * int((serial shr 1) mod TrafficProbeHistoryLen.uint32)
    # JTAG may halt the CPU within these stores despite the IRQ lock.
    volatileStore(addr history[0], serial + 1)
    volatileStore(addr history[slot], macTimeNow())
    volatileStore(addr history[slot + 1], status)
    if (status and 0x80000000'u32) == 0:
      volatileStore(addr history[2], volatileLoad(addr history[2]) + 1)
    elif (status and 0x00800000'u32) == 0:
      volatileStore(addr history[1], volatileLoad(addr history[1]) + 1)
    volatileStore(addr history[0], serial + 2)

proc mm_ap_traffic_probe_cfm*(vifEntry: pointer, status: uint32) {.exportc, cdecl.} =
  ## AP traffic probe confirmation handler.
  ## From blob (mm.o, 14 instrs): checks status bit 23 (0x00800000). If set,
  ## resets probe counter to 10 and stores current MAC time at vifEntry+108.
  ## If not set, decrements a nonzero probe counter (mm_env[8]). If already
  ## zero, resets to 10 and calls mm_send_connection_loss_ind(vifEntry, 22).
  if not txlFrameCallbackCurrent(): return
  when defined(bl808WifiDiagLinkDrop):
    inc nimFwDbgTrafficProbe[if (status and 0x80800000'u32) == 0x80800000'u32: 2 else: 3]
    nimFwDbgTrafficProbe[4] = status
  when defined(bl808WifiDiagTrafficProbeHistory):
    mmRecordTrafficProbeCompletion(status)
  # Flush and explicit release can deliver a zero without an air attempt.
  if (status and 0x80000000'u32) == 0 or vifEntry == nil: return
  let vif = vifChannelAt(vifEntry)
  let vifIndex = vif.vifIdx
  if vifIndex >= MAX_VIFS.uint8: return
  let mm = mmEnvView()
  if (status and 0x00800000'u32) != 0:
    inc mmTrafficProbeEpochs[vifIndex]
    mm.keepAliveLimit = 10  # reset counter at mm_env offset 32
    vif.beaconTimeoutBase = macTimeNow()
  else:
    let keepAliveMissBudget = mm.keepAliveLimit
    if keepAliveMissBudget == 0:
      mm.keepAliveLimit = 10
      # A newer ACK can retire this report before SM dispatches it.
      var epoch = mmTrafficProbeEpochs[vifIndex]
      mmPublishConnectionLoss(vifEntry, 22, addr epoch)
    else:
      mm.keepAliveLimit = keepAliveMissBudget - 1

proc td_timer_end*(tdEntry: pointer) {.exportc, cdecl.} =
  ## End traffic detection timer and update TD state (312 bytes in blob, 79 instrs).
  ## From blob (td.o): reads MAC timestamp, computes traffic direction flags from
  ## TX/RX counters vs threshold, calls notification on direction change, then
  ## resets counters and reschedules timer, unless the traffic update armed
  ## it (blob: a non-zero return of ps_traffic_status_update; here
  ## tdCfmArmed, set by td_cfm_set_timer for this VIF).
  ##
  ## Entry layout: [0]=timer link, [12]=expiry, [16]=period, [24]=rx_count, [28]=tx_count,
  ##   [32]=ps_rx_count, [36]=ps_tx_count, [40]=vif_idx, [41]=prev_flags,
  ##   [42]=active, [43]=timer-end active latch.
  if tdEntry == nil: return
  let td = tdEntryAt(tdEntry)
  let vifIdx = td.vifIdx
  if vifIdx >= MAX_VIFS.uint8: return
  let macTime = regRead(MACHW_TIMLO_REG)
  tdCfmArmed[vifIdx] = false

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
    var schedResult: uint32 = 0
    wifi_hosal_pm_post_event(4, 0, addr schedResult)

    if schedResult != 0:
      discard ps_traffic_status_update(vifIdx, bidir)
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
        discard ps_traffic_status_update(vifIdx, dirBits.uint32)
    td.prevFlags = dirFlags.uint8

  # Reset all counters (always, even if not active)
  td.clearTrafficCounters()

  # Compute VIF active status and reschedule timer
  let vif = vifChannelForIdx(vifIdx)
  let vifConnected = vif.chanCtxt
  let isActive = (vifConnected == chanEnvView().currentCtxt).uint8
  td.endActive = isActive
  if not tdCfmArmed[vifIdx]:
    mm_timer_set(tdEntry, macTime + blPsParamsView().trafficPeriod)

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
