# ###########################################################################
#                   RX Upper (rxu_*)
# ###########################################################################

proc rxu_cntrl_init*() {.exportc, cdecl.} =
  ## Initialize RX upper control (84 bytes in blob, 24 instrs).
  ## Blob: co_list_init at offsets +0x40, +0x38, +0x48, +0x50, store 0xFFFF at +0x5E.
  let env = rxuCntrlEnvView()
  co_list_init(addr env.uploadList)
  co_list_init(addr env.deferredList)
  co_list_init(addr env.pendingList)
  co_list_init(addr env.freeList)
  env.bssidSeq = 0xFFFF'u16

## rxu_cntrl_env: static context structure used by the RX upper control path.
## Layout (96 bytes, from disassembly of rxu_cntrl_frame_handle):
##   [0..1]   frameCtrl    uint16  - IEEE 802.11 Frame Control
##   [2..3]   seqCtrl      uint16  - Sequence Control field
##   [4..5]   seqNum       uint16  - Sequence number (seqCtrl >> 4)
##   [6]      fragNum      uint8   - Fragment number (seqCtrl & 0xF)
##   [7]      tid          uint8   - Traffic ID (from QoS field)
##   [8]      machdrLen    uint8   - MAC header length in bytes
##   [9]      staIdx       uint8   - STA index (0xFF = unknown)
##   [10]     vifIdx       uint8   - VIF index (0xFF = unknown)
##   [11]     dstIdx       uint8   - Destination STA index (AP forwarding)
##   [16..19] secInfo0     uint32  - Security info word 0 (key offset + counter low)
##   [20..23] secInfo1     uint32  - Security info word 1 (counter high)
##   [24..27] hwRxhdr      uint32  - Stored hw_rxhdr flags (monitor path only)
##   [32..35] secKeyPtr    pointer - Security key context pointer
##   [36..41] da           6 bytes - Destination Address (3 x uint16)
##   [42..47] sa           6 bytes - Source Address (3 x uint16)
##   [48]     secFlags     uint8   - Bit 0: protected frame, bit 1: has sec info
##   [49]     meshFlag     uint8   - Mesh/extra header flag
##   [50]     stripLen     uint8   - MAC header bytes to strip before upload
##   [64..67] pendingPtr   pointer - Pending frame (checked at exit for ke_evt_set)
##   [94..95] bssidSeq     uint16  - Cached BSSID sequence for dup detect
# rxu_cntrl_env is declared above (before rxu_cntrl_init) for forward reference.

## RX upload list: CoList of descriptors pending DMA upload to host.
## Populated by rxu_cntrl_desc_prepare, consumed by rxu_swdesc_upload_evt.
var rxuUploadList* {.exportc: "rxu_upload_list".}: CoList

## RX upload environment: tracks upload state.
## Layout (28 bytes from disassembly):
##   [0..3]   word 0 (flags)
##   [4..7]   word 1 (count/state)
##   [8..11]  word 2
##   [12..15] word 3
##   [16..19] word 4
##   [20..23] uploadCount uint32 - number of descriptors uploaded
##   [24..27] word 6
var rxuUploadEnv* {.exportc: "rxu_upload_env".}: array[7, uint32]

proc rxu_cntrl_evt*() {.exportc, cdecl.} =
  ## RX upper control event handler.
  ## From disassembly (16 instrs): clears the RXU event bit (0x200000),
  ## then checks if the rxu_cntrl_env pending pointer (offset 64) is non-nil.
  ## If pending work exists, sets the upload event (0x800000).
  ke_evt_clear(0x00200000'u32)
  if rxuCntrlEnvView().uploadList.first != nil:
    ke_evt_set(0x00800000'u32)

## Cached source address of last management frame for duplicate detection.
var rxu_mgmt_dup_addr* {.exportc.}: array[6, uint8]

## Flag byte cleared per new management frame; used for duplicate detection.
var rxu_cntrl_duplicate_flag {.exportc: "rxu_cntrl_duplicate_detect".}: uint8

proc rxu_cntrl_machdr_len_get*(frameCtrl: uint16): uint8 {.exportc, cdecl, noinline.} =
  ## Compute MAC header length from Frame Control.
  ## 24 (3-addr) or 30 (4-addr if ToDS+FromDS), +2 QoS, +4 HT Control.
  ## noinline + asm barrier: blob calls this as a real function from
  ## rxu_mpdu_upload_and_indicate; without noinline GCC inlines the arithmetic.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
  var length: uint8
  if (frameCtrl and 0x0300) == 0x0300: length = 30
  else: length = 24
  if (frameCtrl.uint8 and 0xFC) == 0x88: length += 2
  if (frameCtrl and 0x8000) != 0: length += 4
  return length

proc rxuQosSeqCachePtr(tid: uint8): ptr uint16 {.inline.} =
  addr rxuQosSeqCacheTable().entries[tid.int].seqCtrl

proc rxuProtectedKey(env: ptr RxuCntrlEnvView, keyIdx: uint8,
                     flagged: bool): ptr VifKeySlotView {.inline.} =
  ## Reference rxu_cntrl.o resolves unflagged protected data to the STA key
  ## context at sta+0x50. The flagged path uses the VIF key table at vif+0x208.
  if flagged:
    let vif = vifChannelForIdx(env.vifIdx)
    return vifRxProtectedKeySlot(vif, keyIdx.uint)
  let sta = staInfoForIdx(env.staIdx)
  cast[ptr VifKeySlotView](addr sta.keyArea[0])

proc rxu_cntrl_protected_handle*(rxuCtx: pointer, hwRxhdrFlags: uint32): cint {.exportc, cdecl.} =
  ## Handle protected frame: parse CCMP/TKIP header, set up security context (94 instrs).
  ## a0 = RX upload context pointer, a1 = HW RX header flags.
  ## Dispatches on frame type (bits 4:2 of a1) to determine header type:
  ##   20 = WEP (4-byte hdr), 24 = TKIP (8-byte hdr), 28 = CCMP (8-byte hdr).
  ## Extracts key index from header, looks up STA entry, resolves security key,
  ## stores key address and PN (packet number) into the RX context.
  ## Returns 1 on success, 0 on unrecognized frame type.
  let env = rxuCntrlEnvView()
  let hdrOffset = env.machdrLen
  let frameType = hwRxhdrFlags and 0x1C  # bits 4:2 (cipher type * 4)
  let flaggedKeyTable = (hwRxhdrFlags and 0x400) != 0
  nimFwDbgRxuProtType = frameType or (hwRxhdrFlags and 0x400'u32)
  case frameType
  of 24:  # TKIP (8 byte header)
    let hdr = rxSecurityHeaderAt[TkipSecurityHeaderView](rxuCtx, hdrOffset)
    env.machdrLen = hdrOffset + 8
    let keyIdx = (hdr.keyId shr 6) and 0x03
    env.secInfo0 = hdr.tsc1.uint32 or (hdr.tsc0.uint32 shl 8) or
      (hdr.tsc2.uint32 shl 16) or (hdr.tsc3.uint32 shl 24)
    env.secInfo1 = hdr.tsc4.uint32 or (hdr.tsc5.uint32 shl 8)
    env.secFlags = env.secFlags or 0x03'u8
    env.secKeyPtr = cast[pointer](rxuProtectedKey(env, keyIdx, flaggedKeyTable))
    nimFwDbgRxuProtKey = pointerAddrU32(env.secKeyPtr)
    nimFwDbgRxuProtPnLo = env.secInfo0
    nimFwDbgRxuProtPnHi = env.secInfo1
    return 1
  of 28:  # CCMP (8 byte header)
    let hdr = rxSecurityHeaderAt[CcmpSecurityHeaderView](rxuCtx, hdrOffset)
    env.machdrLen = hdrOffset + 8
    let keyIdx = (hdr.keyId shr 6) and 0x03
    env.secInfo0 = hdr.pn0.uint32 or (hdr.pn1.uint32 shl 8) or
      (hdr.pn2.uint32 shl 16) or (hdr.pn3.uint32 shl 24)
    env.secInfo1 = hdr.pn4.uint32 or (hdr.pn5.uint32 shl 8)
    env.secFlags = env.secFlags or 0x02'u8
    env.secKeyPtr = cast[pointer](rxuProtectedKey(env, keyIdx, flaggedKeyTable))
    nimFwDbgRxuProtKey = pointerAddrU32(env.secKeyPtr)
    nimFwDbgRxuProtPnLo = env.secInfo0
    nimFwDbgRxuProtPnHi = env.secInfo1
    return 1
  of 20:  # WEP (4 byte header)
    env.machdrLen = hdrOffset + 4
    return 1
  else:
    return 0

proc rxu_cntrl_check_pn*(secKeyPtr: pointer, tid: uint8): cint {.exportc, cdecl.} =
  ## Check PN (Packet Number) for replay detection (90 bytes in blob).
  ## From blob (rxu_cntrl.o, 0xAE bytes):
  ##   hasRxPn = secKeyPtr[156]
  ##   pnLo/pnHi loaded from rxu_cntrl_env[16]/[20] (loaded by caller path)
  ##   if hasRxPn == 0: pairwise path — increments incoming PN and compares
  ##       against entry = secKeyPtr + tid*16. Accept if the stored value is
  ##       lower than the incremented incoming value.
  ##   if hasRxPn != 0: group path — if tid==8, remap to 0; then tail-call
  ##       replay_counter_validate(entry, pnLo, pnHi).
  let key = cast[ptr VifKeySlotView](secKeyPtr)
  let hasRxPn = key.hasRxPn

  # Read incoming PN from descriptor (loaded earlier in call chain)
  let env = rxuCntrlEnvView()
  let pnLo = env.secInfo0
  let pnHi = env.secInfo1

  if hasRxPn == 0:
    # Pairwise key — inline compare/update per TID
    let nextLo = pnLo + 1
    let nextHi = pnHi + (if nextLo < pnLo: 1'u32 else: 0'u32)
    let replayCounter = addr key.replayCounters[tid.int]
    let storedHi = replayCounter.pnHigh
    let storedLo = replayCounter.pnLow
    nimFwDbgRxuPnMeta = tid.uint32 or (hasRxPn.uint32 shl 8) or
      (env.secFlags.uint32 shl 16)
    nimFwDbgRxuPnStoredLo = storedLo
    nimFwDbgRxuPnStoredHi = storedHi
    nimFwDbgRxuPnNextLo = nextLo
    nimFwDbgRxuPnNextHi = nextHi
    var accept = false
    if storedHi < nextHi:
      accept = true
    elif storedHi == nextHi:
      if storedLo < nextLo:
        accept = true
    if not accept:
      return 0  # replay detected
    # Update stored PN
      replayCounter.pnLow = nextLo
      replayCounter.pnHigh = nextHi
    return 1
  else:
    # Group key / TID map: if tid==8, remap to 0 (TID 8 used for non-QoS group).
    var adjTid = tid
    if tid == 8:
      adjTid = 0
    let replayCounterEntry = addr key.replayCounters[adjTid.int]
    let replayCounterEntryAddr = cast[uint](replayCounterEntry)
    nimFwDbgRxuPnMeta = tid.uint32 or (hasRxPn.uint32 shl 8) or
      (env.secFlags.uint32 shl 16)
    nimFwDbgRxuPnStoredLo = replayCounterEntry.pnLow
    nimFwDbgRxuPnStoredHi = replayCounterEntry.pnHigh
    nimFwDbgRxuPnNextLo = pnLo
    nimFwDbgRxuPnNextHi = pnHi
    # Tail-call replay_counter_validate(entry, pnLo, pnHi). The callee reads
    # a1/a2 via inline asm, so we emit a direct RISC-V call that pins a0/a1/a2
    # before the call and captures the return in a0.
    var replayValidationStatus: cint
    {.emit: ["""
    {
      register unsigned long _a0 __asm__("a0") = (unsigned long)""", replayCounterEntryAddr, """;
      register unsigned long _a1 __asm__("a1") = (unsigned long)""", pnLo, """;
      register unsigned long _a2 __asm__("a2") = (unsigned long)""", pnHi, """;
      __asm__ volatile (
        "call replay_counter_validate"
        : "+r"(_a0), "+r"(_a1), "+r"(_a2)
        :
        : "ra","memory","a3","a4","a5","a6","a7",
          "t0","t1","t2","t3","t4","t5","t6");
      """, replayValidationStatus, """ = (int)_a0;
    }
    """].}
    return replayValidationStatus

proc rxu_cntrl_desc_prepare*(swdesc: pointer) {.exportc, cdecl, noinline.} =
  ## Set descriptor status=3, push to rxu_cntrl_env upload list under IRQ lock.
  ## Blob (rxu_cntrl_desc_prepare.constprop.0.isra.0, 22 instrs):
  ##   swdesc[20] = 3
  ##   saved = csrrci(mstatus, 0x08)          ; disable MIE, return old mstatus
  ##   co_list_push_back(&rxu_cntrl_env+0x40, swdesc)
  ##   if (saved & 8) csrsi(mstatus, 0x08)    ; restore MIE
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
  if swdesc == nil: return
  inc nimFwDbgRxuDescPrepare
  # Mark descriptor status = 3 (ready for upload)
  rxMpduDescView(swdesc).descFlag = 3'u8
  # Push under IRQ lock
  let saved = irqSave()
  co_list_push_back(addr rxuCntrlEnvView().uploadList, cast[ptr CoListHdr](swdesc))
  irqRestore(saved)

proc rxu_mpdu_upload_and_indicate*(param: pointer) {.exportc, cdecl.} =
  ## Upload MPDU to host and send indication (292 bytes in blob).
  ## From blob (rxu_cntrl.o, constprop.0):
  ##   1. Load rxu_cntrl_env bytes 9,10 -> build upload flags, OR into swdesc[76]
  ##   2. Set bit 1 in swdesc[76] (upload-in-progress flag)
  ##   3. Clear env byte (upload-active = 0)
  ##   4. Load DMA descriptor chain from swdesc[4]->offset 8 -> offset 24 -> read 2 bytes (FC)
  ##   5. Compute header length adjustment: env[8] - fc_hdr_len
  ##   6. If adjustment != 0 and odd: ASSERT (line 364)
  ##   7. If adjustment != 0 and even: adjust DMA pointers using T-head custom insns
  ##      (shift buffer pointers to strip MAC header)
  ##   8. Update swdesc frame length and env header offset
  ##   9. Clear swdesc[84] = 0 (DMA complete flag)
  ##  10. Call rxl_mpdu_transfer(param) to initiate DMA
  ##  11. Disable interrupts (csrrci mstatus, 8)
  ##  12. Call rxu_cntrl_desc_prepare(param) under interrupt lock
  ##  13. Restore interrupts if they were enabled
  let env = rxuCntrlEnvView()
  let mpdu = rxMpduDescView(param)
  let swdesc = rxSwDescView(mpdu.swDesc)

  # Build upload flags from env bytes 9,10, OR into swdesc control word at offset 76
  let flagsHi = env.staIdx.uint32 shl 16
  let flagsMid = env.vifIdx.uint32 shl 8
  swdesc.frameControlFlags = swdesc.frameControlFlags or flagsHi or flagsMid or 2'u32

  # Clear upload-active flag
  env.frameCtrl = env.frameCtrl and 0xFF00'u16

  # Read DMA chain to get frame control
  let dmaDesc = cast[ptr RxPayloadHwDescView](swdesc.firstDmaDesc)
  let frameRef = cast[ptr RxFrameBufferRefView](cast[pointer](dmaDesc.bufferAddr))
  let fc = cast[ptr MacDataFrameHeaderView](frameRef.frameData).frameControl

  # Compute header size from FC via rxu_cntrl_machdr_len_get (blob 0x5a)
  let macHdrLen = rxu_cntrl_machdr_len_get(fc)
  let envHdrLen = env.machdrLen
  let adjustment = (envHdrLen.int - macHdrLen.int) and 0xFF

  if adjustment != 0:
    if (adjustment and 1) != 0:
      # Blob calls assert_warn at 0x8c (not assert_rec)
      assert_warn(cast[cstring](0), cast[cstring](0), 364)
    # Adjust buffer pointers to strip MAC header
    let halfAdj = adjustment.uint32 shr 1
    discard halfAdj
    # Update DMA descriptor frame length
    dmaDesc.frameLen = dmaDesc.frameLen - adjustment.uint16
    # Update env header offset
    env.stripLen = adjustment.uint8
    let newHdrOff = envHdrLen - fc.uint8
    env.machdrLen = envHdrLen - newHdrOff

  # Clear DMA complete flag
  swdesc.bufferOffset = 0

  # Initiate DMA transfer
  rxl_mpdu_transfer(param)

  # Critical section: prepare descriptor under interrupt lock
  var mstatusVal: uint32
  {.emit: ["asm volatile(\"csrrci %0, mstatus, 8\" : \"=r\"(", mstatusVal, "));"].}
  rxu_cntrl_desc_prepare(param)
  if (mstatusVal and 8) != 0:
    {.emit: "asm volatile(\"csrrsi zero, mstatus, 8\");".}

{.emit: "__attribute__((optimize(\"crossjumping\"))) unsigned long rxu_cntrl_frame_handle(void*);".}
proc rxu_cntrl_frame_handle*(param: pointer): uint32 {.exportc, cdecl.} =
  ## Main RX frame dispatch handler (666 instructions in blob).
  ##
  ## Classifies IEEE 802.11 frames by type/subtype, extracts MAC header fields
  ## into rxu_cntrl_env, and dispatches to the appropriate handler.
  ##
  ## Returns (via s2): 0 = dropped, 1 = uploaded to host.
  ##
  ## Register map: s0=env s1=payload s2=retval s3=param s4=sta_info_tab
  ##   s5=frameControl s6=staIdx s7=hwFlags/vif_info_tab s8=frameTypeBits

  let env = rxuCntrlEnvView()
  let swdescPtr = rxMpduDescView(param).swDesc
  let swdesc = rxSwDescView(swdescPtr)
  let hwFlags = swdesc.hwFlags
  nimFwDbgRxuLastHwFlags = hwFlags
  nimFwDbgRxuLastStatus = (hwFlags and 0x1C'u32) shr 2
  nimFwDbgRxuLastLen = swdesc.mpduLengthBytes.uint32

  # Epilogue helper: break to the common tail which emits a single
  # ke_evt_set (matching blob's 1-site pattern). Any caller using
  # doReturn() will exit the rcfhScope and run the shared tail below.
  var returnValue: uint32 = 0
  template doReturn() =
    break rcfhScope

  block rcfhScope:
    # Check valid-frame bit 0x2000
    if (hwFlags and 0x2000) == 0:
      inc nimFwDbgRxuDropInvalid
      doReturn()
    inc nimFwDbgRxuFrameValid

    # .L137: Frame valid -- begin classification
    let frame = macDataFrameAt(rxFramePayload(swdesc))
    let frameControl = frame.frameControl
    nimFwTrace2U32("[WIFI-NIMFW] rxu_fc ", hwFlags, frameControl.uint32)

    # NOTE: The blob does NOT call tcpip_stack_input from rxu_cntrl_frame_handle.
    # The fast-path delivery happens only in rxu_swdesc_upload_evt.
    # Previous code here incorrectly called tcpip_stack_input; removed.

    # Clear swdesc status accumulator at offset 76
    swdesc.frameControlFlags = 0
    env.secInfo0 = 0
    env.secInfo1 = 0
    env.secKeyPtr = nil
    env.secFlags = 0
    env.meshFlag = 0
    env.stripLen = 0

    # Init sta_idx = 0xFF, vif_idx = 0xFF
    env.staIdx = 0xFF
    env.vifIdx = 0xFF

    # Store frame control at env[0]
    env.frameCtrl = frameControl

    # Store sequence control from the MAC header at env[2]
    let seqCtrl = frame.seqCtrl
    env.seqCtrl = seqCtrl

    # Clear duplicate-detect flag
    rxu_cntrl_duplicate_flag = 0

    # Decompose seqCtrl -> seqNum at env[4], fragNum at env[6]
    env.seqNum = seqCtrl shr 4
    env.fragNum = (seqCtrl and 0xF).uint8

    # ---- QoS TID extraction ----
    # Blob at .L139 clears env[7] (TID) for non-QoS frames. If env[7] retained
    # a value from a previous QoS frame, downstream per-TID lookups in the
    # QoS sequence-cache overlay and PN replay index would index wrong entries
    # and reject valid frames. Must clear to 0 on non-QoS path.
    # .L142: Compute MAC header length
    let machdrLen = rxu_cntrl_machdr_len_get(frameControl)
    env.machdrLen = machdrLen
    if (frameControl.uint8 and 0x88) == 0x88:
      env.tid = (rxQosControl(frame, machdrLen) and 7).uint8
    else:
      env.tid = 0'u8
    when defined(bl808WifiConnectTrace):
      let rxTraceState = ke_state_get(TASK_SM)
      let rxTraceType = frameControl and 0x000C
      if rxTraceState >= SmAuthStartingState or rxTraceType == 8:
        let rxTraceLen = swdesc.mpduLengthBytes
        let rxTraceEth =
          if rxTraceLen >= machdrLen.uint16 + 8'u16:
            rxMsdu(frame, machdrLen).ethertype.uint32
        else:
            0'u32
        nimFwConnectTrace2U32("[WIFI-CT] rx_enter ",
                              frameControl.uint32 or (machdrLen.uint32 shl 16),
                              hwFlags)
        nimFwConnectTrace2U32("[WIFI-CT] rx_len ",
                              rxTraceLen.uint32 or (rxTraceEth shl 16),
                              rxTraceState.uint32)
        if rxTraceState >= SmAuthStartingState or rxTraceType == 8:
          nimFwConnectTraceBytes("[WIFI-RAW] rx_any ",
                                 cast[pointer](frame),
                                 rxTraceLen.uint32,
                                 96)

    # ---- Address extraction: ToDS/FromDS ----
    let toDs = (frameControl and 0x0100) != 0
    let fromDs = (frameControl and 0x0200) != 0

    if toDs:
      # DA from Addr3 (offset 16)
      rxCopyAddr(addr env.da, addr frame.addr3)
      if fromDs:
        # WDS: SA from Addr4 (offset 24)
        rxCopyAddr(addr env.sa, addr macQos4AddrFrameAt(frame).addr4)
      else:
        # ToDS only: SA from Addr2 (offset 10)
        rxCopyAddr(addr env.sa, addr frame.addr2)
    elif fromDs:
      # FromDS only: DA from Addr1 (offset 4), SA from Addr3 (offset 16)
      rxCopyAddr(addr env.da, addr frame.addr1)
      rxCopyAddr(addr env.sa, addr frame.addr3)
    else:
      # No DS: DA from Addr1 (offset 4), SA from Addr2 (offset 10)
      rxCopyAddr(addr env.da, addr frame.addr1)
      rxCopyAddr(addr env.sa, addr frame.addr2)

    # ================================================================
    # Branch: associated/monitor (hwFlags bit 25, blob `lui 0x2000`) vs unassociated
    # ================================================================
    if (hwFlags and 0x02000000'u32) != 0:
      # .L148: Associated STA / monitor mode path
      # Extract STA index from hwFlags via B-extension insn (approximate)
      let staIdx = (((hwFlags shr 15) and 0x3FF'u32) - 8).uint8

      let sta = staInfoForIdx(staIdx)

      # Check STA active at sta_entry[42]
      if sta.valid == 0:
        inc nimFwDbgRxuDropStaInactive
        when defined(bl808WifiConnectTrace):
          nimFwConnectTrace2U32("[WIFI-CT] rx_drop ", 1, staIdx.uint32)
        doReturn()

      let vifIdx = sta.instNbr
      env.hwRxhdr = hwFlags
      let vif = vifChannelForIdx(vifIdx)
      env.vifIdx = vifIdx
      env.staIdx = staIdx

      # AP mode unicast DA -> look up destination STA via MAC HW search
      if vif.vifType == 2:
        if (env.da[0] and 1) == 0:
          env.dstIdx = hal_machw_search_addr(addr env.da[0], 0).uint8

      # Mark HT QoS in status accumulator
      if (frameControl and 0x0300) == 0x0300:
        swdesc.frameControlFlags = swdesc.frameControlFlags or 4

        # .L156: Protected frame check (FC bit 14)
      if (env.frameCtrl and 0x4000) != 0:
        if rxu_cntrl_protected_handle(
             cast[ptr uint8](frame), env.hwRxhdr) == 0:
          doReturn()

      # .L160: Frame type dispatch
      let frameTypeBits = frameControl and 0x000C

      if frameTypeBits != 0 and frameTypeBits != 8:
        inc nimFwDbgRxuDropFtype
        when defined(bl808WifiConnectTrace):
          nimFwConnectTrace2U32("[WIFI-CT] rx_drop ", 2, frameControl.uint32)
        doReturn()

      if frameTypeBits == 8:
        inc nimFwDbgRxuAssocData
        nimFwDbgRxuDataFc = frameControl.uint32 or (hwFlags and 0xFFFF0000'u32)
        nimFwDbgRxuDataSeq = env.seqCtrl.uint32 or
          (env.tid.uint32 shl 16) or (env.machdrLen.uint32 shl 24)
        # ---- Data frame (type 2) in associated path ----
        # Blob .L160 at 0x3e6: frameControl & 0x40 = Null subtype (bit 6).
        # Null/CF-Poll frames are keepalive-only (no payload); blob just pokes
        # the keepalive timestamp and returns. Previously Nim incorrectly called
        # rxl_frame_release here which double-released the descriptor.
        if (frameControl and 0x0040) != 0:
          inc nimFwDbgRxuDropNull
          nimFwDbgRxuDropNullFc = frameControl.uint32 or (hwFlags and 0xFFFF0000'u32)
          nimFwDbgRxuDropNullSeq = env.seqCtrl.uint32 or
            (env.tid.uint32 shl 16) or (env.machdrLen.uint32 shl 24)
          when defined(bl808WifiConnectTrace):
            nimFwConnectTrace2U32("[WIFI-CT] rx_drop ", 3, frameControl.uint32)
          mm_cfg_element_keepalive_timestamp_update()
          doReturn()

        # Sequence/reorder context
        var seqCachePtr: ptr uint16
        if (frameControl and 0x0080) != 0:
          seqCachePtr = rxuQosSeqCachePtr(env.tid)
        else:
          seqCachePtr = addr sta.supportedRatesBitmap

        # Duplicate sequence check
        let envSeq = env.seqCtrl
        if frameControl != 0:
          let retryFrame = (frameControl and 0x0800'u16) != 0
          let protectedReplayChecked = (env.secFlags and 2) != 0
          if retryFrame and not protectedReplayChecked and
              seqCachePtr[] == envSeq and nimFwDbgRxuAssocUploadReady != 0:
            inc nimFwDbgRxuDropDup
            nimFwDbgRxuDropDupFc = frameControl.uint32 or (hwFlags and 0xFFFF0000'u32)
            nimFwDbgRxuDropDupSeq = envSeq.uint32 or
              (env.tid.uint32 shl 16) or (env.machdrLen.uint32 shl 24)
            nimFwDbgRecordRxuDupDrop(frame, hwFlags, envSeq, env.tid,
                                     env.machdrLen, seqCachePtr[],
                                     swdesc.mpduLengthBytes)
            when defined(bl808WifiConnectTrace):
              nimFwConnectTrace2U32("[WIFI-CT] rx_drop ", 5, envSeq.uint32)
            doReturn()
        seqCachePtr[] = envSeq

        # PN replay check
        if (env.secFlags and 2) != 0:
          if rxu_cntrl_check_pn(
               env.secKeyPtr,
               env.tid) == 0:
            inc nimFwDbgRxuDropPn
            nimFwDbgRecordRxuPnDrop(frame, hwFlags, envSeq, env.tid,
                                    env.machdrLen, swdesc.mpduLengthBytes)
            when defined(bl808WifiConnectTrace):
              nimFwConnectTrace2U32("[WIFI-CT] rx_drop ", 6, frameControl.uint32)
            doReturn()
          if nimFwDbgRxuDhcpMsg(frame, env.machdrLen,
                                swdesc.mpduLengthBytes) != 0:
            nimFwDbgRecordRxuPnAccept(1'u32, frame, hwFlags, envSeq, env.tid,
                                      env.machdrLen, swdesc.mpduLengthBytes)

        # .L171: EAPOL detection requires RFC1042 SNAP then EtherType 0x888E.
        let msdu = rxMsduView(frame, env.machdrLen)
        nimFwDbgRxuSnapLo = rxSnapTraceLo(addr msdu.snap)
        nimFwDbgRxuSnapHi = rxSnapTraceHi(addr msdu.snap)
        let hasRfc1042Snap = rxSnapIsRfc1042(addr msdu.snap)
        if hasRfc1042Snap:
          inc nimFwDbgRxuAssocSnap
          case msdu.snap.ethertype
          of 0x0008'u16:
            inc nimFwDbgRxuAssocIp
            nimFwDbgRxuIpv4Preupload(frame, env.machdrLen, env.tid,
                                     swdesc.mpduLengthBytes)
          of 0x0608'u16:
            inc nimFwDbgRxuAssocArp
          of 0x8E88'u16:
            discard
          else:
            inc nimFwDbgRxuAssocOther
        else:
          inc nimFwDbgRxuAssocOther
        when defined(bl808WifiConnectTrace):
          nimFwConnectTrace2U32("[WIFI-CT] rx_data ",
                                msdu.snap.ethertype.uint32 or
                                  ((if hasRfc1042Snap: 1'u32 else: 0'u32) shl 16) or
                                  (env.tid.uint32 shl 24),
                                swdesc.mpduLengthBytes.uint32 or
                                  (env.machdrLen.uint32 shl 16))
        if hasRfc1042Snap and msdu.snap.ethertype == 0x8E88'u16:
          inc nimFwDbgRxuAssocEapol
          # .LBB303: EAPOL frame detected -- route based on VIF type
          let vifType = vif.vifType
          let adjustedLen = swdesc.mpduLengthBytes
          let eapolData = rxMsduPayload(msdu)
          let eapolLen = adjustedLen - env.machdrLen.uint16 - sizeof(LlcSnapHeaderView).uint16
          when defined(bl808WifiConnectTrace):
            nimFwConnectTrace2U32("[WIFI-CT] eapol_rx ", staIdx.uint32 or (vifType.uint32 shl 8), eapolLen.uint32)
          if vifType == 2:
            # AP mode: route EAPOL to AP handler
            apm_handle_eapol_input(staIdx, eapolData, eapolLen.uint32)
            break rcfhScope
          else:
            # STA mode: route EAPOL to SM handler
            sm_handle_eapol_input(staIdx, addr env.sa[0], eapolData, eapolLen.uint32)
            break rcfhScope

        # .L170/.L173: Protected + A-MSDU/fragment checks
        let fcR = env.frameCtrl
        if (fcR and 0x4000) != 0:
          if (fcR and 0x0400) != 0:
            if nimFwDbgRxuDhcpMsg(frame, env.machdrLen,
                                  swdesc.mpduLengthBytes) != 0:
              nimFwDbgRecordRxuPnAccept(0xE1'u32, frame, hwFlags, envSeq,
                                        env.tid, env.machdrLen,
                                        swdesc.mpduLengthBytes)
            doReturn()
          if env.fragNum != 0:
            if nimFwDbgRxuDhcpMsg(frame, env.machdrLen,
                                  swdesc.mpduLengthBytes) != 0:
              nimFwDbgRecordRxuPnAccept(0xE2'u32, frame, hwFlags, envSeq,
                                        env.tid, env.machdrLen,
                                        swdesc.mpduLengthBytes)
            doReturn()

        # .LBB312/.LBB313: MIC verification (Michael MIC for TKIP)
        # Blob builds local DMA descriptor chain from buffer chain, calls me_mic_init/
        # me_mic_calc/me_mic_end, then compares computed MIC with received MIC.
        # On mismatch sends MIC_FAILURE_IND via ke_msg_alloc(0xC04, TASK_CFG, TASK_ME, 24).
        if (env.secFlags and 1) != 0:
          let secKeyBase = cast[uint](env.secKeyPtr)
          let secKey = cast[ptr VifKeySlotView](secKeyBase)
          let tidVal = env.tid
          let hdrLen2 = env.machdrLen
          let frameSize = swdesc.mpduLengthBytes
          # dataLen = frameSize - 8 (MIC) - hdrLen
          var dataLen: int = frameSize.int - 8 - hdrLen2.int

          # 1. Init MIC context on stack with TKIP RX MIC key at secKey+144
          var micCtx {.noinit.}: array[4, uint32]  # L, R, pending, nBytes
          me_mic_init(addr micCtx[0],
                      cast[pointer](secKeyBase + 144),
                      addr env.sa[0],
                      addr env.da[0],
                      tidVal)

          # 2. Walk buffer chain computing MIC over MSDU payload
          var micPayloadBuffer = rxFrameBufferChainAt(swdesc.bufferChain)
          var skipBytes = hdrLen2.int  # skip MAC header in first segment
          const MAX_DMA_SEG = 1736
          while dataLen > 0 and micPayloadBuffer != nil:
            let micPayloadBase = cast[uint](micPayloadBuffer.frameData)
            var micSegmentStart = micPayloadBase + skipBytes.uint
            var micSegmentLen = dataLen + skipBytes
            if micSegmentLen > MAX_DMA_SEG:
              micSegmentLen = MAX_DMA_SEG
            micSegmentLen -= skipBytes
            if micSegmentLen > dataLen:
              micSegmentLen = dataLen
            if micSegmentLen > 0:
              me_mic_calc(addr micCtx[0], cast[pointer](micSegmentStart),
                          micSegmentLen.uint32)
              dataLen -= micSegmentLen
            if dataLen > 0:
              micPayloadBuffer = rxFrameBufferChainAt(micPayloadBuffer.next)
              if micPayloadBuffer == nil:
                assert_rec("rxu_cntrl.c", "rxu_cntrl.c", 811)
                doReturn()
            skipBytes = 0  # only first segment has header to skip

          me_mic_end(addr micCtx[0])

          # 3. Read received MIC from tail of frame (last 8 bytes)
          # Walk buffer chain again to find MIC location
          var micOff: int = frameSize.int - 8  # offset of MIC from frame start
          var micBuf = rxFrameBufferChainAt(swdesc.bufferChain)
          var rxMic {.noinit.}: array[2, uint32]
          rxMic[0] = 0; rxMic[1] = 0
          var micSkip = 0
          while micOff > 0 and micBuf != nil:
            let segPayload = cast[uint](micBuf.frameData)
            var segAvail = MAX_DMA_SEG - micSkip
            if segAvail > micOff:
              # MIC starts in this segment
              let micPtr = segPayload + micSkip.uint + micOff.uint
              let micWords = rxMicWordsAt(micPtr)
              rxMic[0] = micWords.lo
              rxMic[1] = micWords.hi
              micOff = 0
            else:
              micOff -= segAvail
              micBuf = rxFrameBufferChainAt(micBuf.next)
              if micBuf == nil:
                assert_rec("rxu_cntrl.c", "rxu_cntrl.c", 852)
                doReturn()
            micSkip = 0

          # 4. Compare computed MIC with received MIC
          if rxMic[0] != micCtx[0] or rxMic[1] != micCtx[1]:
            if nimFwDbgRxuDhcpMsg(frame, env.machdrLen,
                                  swdesc.mpduLengthBytes) != 0:
              nimFwDbgRecordRxuPnAccept(0xE3'u32, frame, hwFlags, envSeq,
                                        env.tid, env.machdrLen,
                                        swdesc.mpduLengthBytes)
            # MIC failure: send indication to host
            let failMsg = ke_msg_alloc(0xC04'u16, TASK_CFG, TASK_ME, 24)
            if failMsg != nil:
              let msg = rxMicFailureIndAt(failMsg)
              # Fill MIC failure indication: BSSID from sta_info_tab
              let staIdxF = env.staIdx
              let staF = staInfoForIdx(staIdxF)
              rxCopyAddr(addr msg.bssid, addr staF.macAddr)
              msg.pnLow = env.secInfo0
              msg.pnHigh = env.secInfo1
              msg.tid = tidVal
              msg.keyType = secKey.staIdx
              msg.vifIdx = env.vifIdx
              msg.hwRxhdrHigh = (env.hwRxhdr shr 24).uint8
              ke_msg_send(failMsg)
            doReturn()

        # .L174: Build status word for host upload
        let currentFrameControlFlags = swdesc.frameControlFlags
        let combined = (env.staIdx.uint32 shl 16) or
                       (env.vifIdx.uint32 shl 8) or
                       (env.dstIdx.uint32 shl 24) or
                       currentFrameControlFlags or 2
        swdesc.frameControlFlags = combined

        # .LBB349: Reparse FC for QoS TID/AMSDU bits
        let finalFrame = macDataFrameAt(rxFramePayload(swdesc))
        let fcFinal = finalFrame.frameControl
        swdesc.frameControlFlags = swdesc.frameControlFlags and 0xFFFFFF8F'u32

        if (fcFinal.uint8 and 0xFC) == 0x88:
          let qos = rxQosControl(finalFrame, rxu_cntrl_machdr_len_get(fcFinal))
          let tidBits = (qos and 7).uint32 shl 4
          let amsdu = if (qos and 0x80) != 0: 1'u32 else: 0'u32
          swdesc.frameControlFlags = swdesc.frameControlFlags or tidBits or amsdu

        # .L185: LLC/SNAP header check for proper strip length computation.
        # Blob uses two memcmp calls against 6-byte RFC1042 + bridge-tunnel
        # headers at .LANCHOR0 and .LANCHOR1.
        var stripLen = machdrLen and 0xFE
        let msduSnap = rxMsdu(finalFrame, stripLen)

        let isRfc1042 = rxSnapIsRfc1042(msduSnap)
        let isIpx = isRfc1042 and msduSnap.ethertype == 0x3781'u16 # 0x8137 LE
        let isBridgeTunnel =
          (not isRfc1042 or isIpx) and rxSnapIsBridgeTunnel(msduSnap)

        if (isRfc1042 and not isIpx) or isBridgeTunnel:
          # .L192: Standard RFC1042/bridge SNAP: strip 6 bytes, keep ethertype.
          stripLen = (stripLen.int - 6).uint8
        else:
          # .L190: A-MSDU sub-frame: strip 14 bytes and write the sub-frame length.
          stripLen = (stripLen.int - 14).uint8
          let adjustedLen2 = swdesc.mpduLengthBytes
          let lenVal = adjustedLen2 - (machdrLen and 0xFE).uint16
          let lenPtr = cast[ptr uint16](addr rxFrameBytes(finalFrame)[(machdrLen and 0xFE).int - 2])
          lenPtr[] = lenVal
          env.meshFlag = 1

        # Clear env[49] for non-A-MSDU frames
        if env.meshFlag != 1:
          env.meshFlag = 0

        # .L191: Rewrite DA/SA into Ethernet-II header
        let ethHdr = rxEthernetRewriteHeader(finalFrame, stripLen)
        rxCopyAddr(addr ethHdr.da, addr env.da)
        rxCopyAddr(addr ethHdr.sa, addr env.sa)

        # Adjust length, set strip info
        swdesc.mpduLengthBytes = swdesc.mpduLengthBytes - stripLen.uint16
        swdesc.bufferOffset = stripLen.uint32
        env.stripLen = stripLen

        # DMA transfer MPDU, then prepare descriptor under irq lock
        # Blob order: rxl_mpdu_transfer → csrrci(irq disable) → rxu_cntrl_desc_prepare
        inc nimFwDbgRxuAssocUploadReady
        if nimFwDbgRxuDhcpMsg(frame, env.machdrLen,
                              swdesc.mpduLengthBytes) != 0:
          nimFwDbgRecordRxuPnAccept(4'u32, frame, hwFlags, envSeq, env.tid,
                                    env.machdrLen, swdesc.mpduLengthBytes)
        rxl_mpdu_transfer(param)
        let savedIrq = irqSave()
        rxu_cntrl_desc_prepare(param)
        irqRestore(savedIrq)
        returnValue = 1
        break rcfhScope

      else:
        inc nimFwDbgRxuAssocMgmt
        # frameTypeBits == 0: Management in associated path
        let envSeq = env.seqCtrl
        if frameControl != 0:
          let cachedSeq = sta.supportedRatesBitmap
          if cachedSeq == envSeq: doReturn()
        sta.supportedRatesBitmap = envSeq

        if (env.secFlags and 2) != 0:
          if rxu_cntrl_check_pn(
               env.secKeyPtr,
               env.tid) == 0:
            inc nimFwDbgRxuDropPn
            nimFwDbgRecordRxuPnDrop(frame, hwFlags, envSeq, env.tid,
                                    env.machdrLen, swdesc.mpduLengthBytes)
            doReturn()

        # Blob's associated mgmt path (.L158 -> .L163 -> .L234) routes through
        # rxu_mgt_frame_check(param, sta_idx), not the data upload path.
        returnValue = rxu_mgt_frame_check(param, env.staIdx)
        nimFwTrace2U32("[WIFI-NIMFW] rxu_mgt_assoc ", frameControl.uint32, returnValue)
        doReturn()

    # ================================================================
    # Non-associated path: dispatch by frame type bits [3:2]
    # ================================================================
    let frameTypeBits = frameControl and 0x000C

    if frameTypeBits == 0:
      # ---- Management frame (type 0) ----
      let addr2Ptr = rxAddrPtr(addr frame.addr2)
      let frameControlFlagByte = (frameControl shr 8).uint8
      let retryFrame = (frameControlFlagByte and 0x08'u8) != 0

      if retryFrame:
        let cachedSeq = env.bssidSeq
        if frame.seqCtrl == cachedSeq:
          if c_memcmp(addr2Ptr, cast[pointer](addr rxu_mgmt_dup_addr[0]), 6) == 0:
            doReturn()

      env.bssidSeq = frame.seqCtrl
      discard c_memcpy(cast[pointer](addr rxu_mgmt_dup_addr[0]), addr2Ptr, 6)

      if (env.frameCtrl and 0x4000) != 0:
        if (hwFlags and 0x1C) != 20: doReturn()
        if rxu_cntrl_protected_handle(cast[ptr uint8](frame), hwFlags) != 0:
          doReturn()

      # Management frame filter check (blob: rxu_mgt_frame_check at reloc 0x324)
      let mgtAccepted = rxu_mgt_frame_check(param, 0xFF'u8)
      nimFwTrace2U32("[WIFI-NIMFW] rxu_mgt ", frameControl.uint32, mgtAccepted)
      returnValue = mgtAccepted
      doReturn()

    elif frameTypeBits == 8:
      inc nimFwDbgRxuNonassocData
      # ---- Data frame (type 2) -- non-associated ----
      # Blob: check if DA matches a known VIF BSSID. If so, forward to
      # scan_indicate for scan module processing. Otherwise release.
      let firstVif = vif_mgmt_get_first_ap_inf()
      if firstVif != nil:
        let apVif = vifChannelAt(firstVif)
        if c_memcmp(rxAddrPtr(addr frame.addr1), addr apVif.macAddr[0], 6) == 0:
          # DA matches our BSSID: forward to AP MLME
          apm_send_mlme(firstVif, 192, rxAddrPtr(addr frame.addr2), nil, nil, cast[pointer](1))
          doReturn()
      # Blob does NOT call rxl_frame_release here; frame is left for
      # the TX-pool recycler. Previous Nim spuriously released.
      break rcfhScope

    else:
      # Control frame (type 1) or reserved: blob also does NOT release.
      break rcfhScope

  # Common tail: single ke_evt_set site (matches blob's shared event tail).
  if env.uploadList.first != nil:
    ke_evt_set(0x00800000'u32)
  return returnValue

{.emit: "__attribute__((optimize(\"crossjumping\"))) void rxu_swdesc_upload_evt(void);".}
proc rxu_swdesc_upload_evt*() {.exportc, cdecl.} =
  ## RX software descriptor upload event.
  ## From disassembly (143 instrs): clears event bit 0x800000, pops descriptors
  ## from the upload list. For each descriptor, checks upload count limit (41),
  ## builds a local DMA descriptor array (up to 4 entries, each 4 bytes of buffer
  ## address + 2 bytes length at offset 32, capped at 1736 per entry), then calls
  ## tcpip_stack_input. On success, updates upload count via platform
  ## callbacks. On failure or limit exceeded, frees the descriptor via rxl_mpdu_free.
  ke_evt_clear(0x00800000'u32)
  inc nimFwDbgRxuUploadEvt
  let env = rxuCntrlEnvView()
  var uploadListNode = co_list_pop_front(addr env.uploadList)
  let uploadEnv = cast[ptr RxuUploadEnvView](addr rxuUploadEnv[0])
  let hwdescCallbacks = cast[ptr RxlHwdescCallbackEnvView](addr rxl_hwdesc_env[0])
  const MAX_DMA_ENTRIES = 4
  const MAX_DMA_SIZE = 1736'u32
  while uploadListNode != nil:
    inc nimFwDbgRxuUploadEntry
    let desc = cast[ptr RxMpduDescView](uploadListNode)
    # Check upload count limit
    let uploadCount = uploadEnv.uploadCount
    if (41 - uploadCount) <= 2:
      # Over limit -- log warning and release
      let logFn = getLogFunc(204)
      if logFn != nil:
        cast[proc(a0: uint32, a1: uint32, a2: cstring, a3: uint32) {.cdecl.}](logFn)(2, 0, "rxu_cntrl.c", 2002)
      rxl_mpdu_free(uploadListNode)
      uploadListNode = co_list_pop_front(addr env.uploadList)
      continue
    # Get sw_desc and compute total remaining bytes
    let swDesc = rxSwDescView(desc.swDesc)
    var remaining = swDesc.mpduLengthBytes.uint32 + swDesc.bufferOffset
    # Clear local DMA descriptor array (40 bytes on stack, matching blob layout).
    # Blob: addresses at offsets 0,4,8,12; lengths (uint16) at offsets 32,34,36,38.
    var dmaArray {.noinit.}: RxUploadDmaArrayView
    discard c_memset(addr dmaArray, 0, sizeof(RxUploadDmaArrayView).csize_t)
    # Get first payload HW descriptor
    var uploadPayloadHwDesc = cast[ptr RxPayloadHwDescView](swDesc.bufferChain)
    var dmaIdx = 0'u32
    # Build DMA entries from HW descriptor chain
    while remaining > 0 and uploadPayloadHwDesc != nil:
      if dmaIdx >= MAX_DMA_ENTRIES.uint32:
        break  # at most 4 entries
      # Increment DMA count in desc
      desc.descCount = desc.descCount + 1
      # Store buffer address from hw_desc[8] (offsets 0,4,8,12 in dmaArray)
      dmaArray.bufferAddrs[dmaIdx] = uploadPayloadHwDesc.bufferAddr
      # Compute transfer length (capped at MAX_DMA_SIZE)
      var xferLen = remaining
      if xferLen > MAX_DMA_SIZE:
        xferLen = MAX_DMA_SIZE
      # Store length as uint16 at offset 32 + dmaIdx*2 in dmaArray
      dmaArray.lengths[dmaIdx] = xferLen.uint16
      # Check hw_desc[20] for warning
      if uploadPayloadHwDesc.usedFlag != 0:
        let logFn = getLogFunc(204)
        if logFn != nil:
          cast[proc(a0: uint32, a1: uint32, a2: cstring, a3: uint32) {.cdecl.}](logFn)(2, 0, "rxu_cntrl.c", 2023)
      # Mark hw_desc as used
      uploadPayloadHwDesc.usedFlag = 1
      # Advance
      if remaining > MAX_DMA_SIZE:
        remaining -= MAX_DMA_SIZE
      else:
        remaining = 0
      uploadPayloadHwDesc = cast[ptr RxPayloadHwDescView](uploadPayloadHwDesc.next)
      dmaIdx += 1
    # Set sw_desc[96] = 1 (upload done flag)
    swDesc.uploadDone = 1
    # Call tcpip_stack_input to deliver frame to TCP/IP stack.
    # Blob args: a0=entry, a1=desc[20] byte, a2=swDesc+28, a3=swDesc[84],
    #            a4=&dmaArray, a5=swDesc[76]&1
    let descFlag = desc.descFlag.uint32
    let swPayload = cast[pointer](addr swDesc.mpduLengthBytes)
    let swBufOff = swDesc.bufferOffset
    let swFcFlag = swDesc.frameControlFlags and 1
    let uploadResult = tcpip_stack_input(
      uploadListNode,
      descFlag,
      swPayload,
      swBufOff,
      cast[pointer](addr dmaArray),
      swFcFlag,
    )
    if uploadResult != 0:
      inc nimFwDbgRxuUploadTcpipFail
      # Upload failed -- free descriptor and try next
      rxl_mpdu_free(uploadListNode)
      uploadListNode = co_list_pop_front(addr env.uploadList)
      continue
    inc nimFwDbgRxuUploadTcpipOk
    when defined(bl808WifiRxPbufInput):
      # tcpip_stack_input copies RX bytes into PBUF_RAM before calling lwIP.
      # The copied pbuf owns the network packet; recycle the LMAC descriptor
      # immediately so uploadCount does not starve the RX path.
      rxl_mpdu_free(uploadListNode)
    else:
      # Upload succeeded -- call platform callbacks and update count
      if hwdescCallbacks.getStatus != nil:
        cast[proc() {.cdecl.}](hwdescCallbacks.getStatus)()
      uploadEnv.uploadCount = uploadEnv.uploadCount + desc.descCount.uint32
      if hwdescCallbacks.clean != nil:
        cast[proc() {.cdecl.}](hwdescCallbacks.clean)()
    uploadListNode = co_list_pop_front(addr env.uploadList)
