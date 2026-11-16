# ###########################################################################
#                   TX Upper (txu_*)
# ###########################################################################

const
  TxuDropStatusOrdinary = 0x00020000'u32
  TxuDropStatusCryptoPending = 0x00080000'u32
  TxuDropStatusTxNotReady = 0x00100000'u32

proc txu_cntrl_init*() {.exportc, cdecl.} =
  ## Initialize TX upper control.
  discard

proc txuBuildFrame(desc: pointer, bufPtr: pointer): bool =
  ## Build MAC/security/SNAP headers backwards from the supplied header end.
  ## HostTxDescView.frameLen holds the Ethernet type/length in wire byte order;
  ## seqPassthrough holds payload length. Payload buffers need not be adjacent
  ## to the header. Duration/ID is not rewritten, matching the vendor builder.
  let txDesc = hostTxDescAt(desc)
  let saved = irqSave()
  defer: irqRestore(saved)
  let staIdx = txDesc.staIdx
  if staIdx != 0xFF'u8 and staIdx >= 8:
    return false
  let identity = txlCaptureSession(txDesc)
  template ensureCurrentBuild() =
    if txDesc.staIdx != staIdx or not txlSessionCurrent(identity, txDesc):
      return false
  if not txlSessionCurrent(identity, txDesc) or txDesc.staInfoIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return false
  let bufPtrU = cast[uint](bufPtr)
  if bufPtrU == 0:
    return false
  let frameLen = txDesc.frameLen
  let frameType = lmacGateHalfword(frameLen)
  let layout = txFrameBuildLayout(txDesc, bufPtr, frameType)

  txFrameWriteSnap(layout, frameLen)
  let securityEnd = cast[pointer](cast[uint](layout.sec) + layout.secLen.uint)
  if txu_cntrl_sec_hdr_append(desc, securityEnd, 1'u32) != layout.sec:
    return false
  ensureCurrentBuild()

  let vifIdx = txDesc.vifIdx
  let staInfoIdx = txDesc.staInfoIdx
  let vif = vifChannelForIdx(vifIdx)
  let sta = staInfoForIdx(staInfoIdx)

  # Get rate table from STA entry: sta_entry[244] -> rate_ctrl pointer
  let rateCtrl = sta.keyMat
  let pairwiseKey =
    if rateCtrl == nil: 0'u32
    else: pointerAddrU32(txSecurityKeyListAt(rateCtrl).pairwiseKey)

  let hdr = layout.mac
  let hdrBufBase = cast[uint](hdr)

  # Build frame control
  var fc: uint16 = 0
  if staIdx != 0xFF:
    # Set frame control: Data frame (type=2, subtype from txdesc)
    fc = 0x0080'u16  # QoS data subtype in the low FC byte.
    hdr.header.frameControl = fc

    # Write sequence control from txdesc[42]
    hdr.header.seqCtrl = txDesc.seqAssigned shl 4
    hdr.qosCtrl = staIdx.uint16
  else:
    # No STA: zero out frame control and address fields
    hdr.header.frameControl = 0
    hdr.header.seqCtrl = 0

  # OR in "Data" frame type (0x0008) into FC
  var fullFc = hdr.header.frameControl
  fullFc = fullFc or 0x0008  # Data type bit

  # VIF mode selects ToDS/FromDS in the vendor frame builder:
  # 0=STA(ToDS), 2=AP(FromDS), other=no-DS.
  let vifMode = vif.vifType
  if vifMode == 0:
    fullFc = fullFc or 0x0108'u16
  elif vifMode == 2:
    fullFc = fullFc or 0x0208'u16

  # Write back FC
  hdr.header.frameControl = fullFc

  # Addr2 is always the local VIF MAC in the vendor builder.
  discard c_memcpy(addr hdr.header.addr2[0], addr vif.macAddr[0], 6.csize_t)

  # Fill addresses based on To/From DS bits
  let toFromDs = fullFc and 0x0300
  if toFromDs == 0x0100:
    # ToDS=1, FromDS=0: Addr1=BSSID (from STA), Addr2=SA (from VIF), Addr3=DA
    discard c_memcpy(addr hdr.header.addr1[0], addr sta.macAddr[0], 6.csize_t)
    discard c_memcpy(addr hdr.header.addr3[0], addr txDesc.da[0], 6.csize_t)
  elif toFromDs == 0x0200:
    # ToDS=0, FromDS=1: Addr1=DA, Addr2=BSSID, Addr3=SA
    discard c_memcpy(addr hdr.header.addr1[0], addr txDesc.da[0], 6.csize_t)
    discard c_memcpy(addr hdr.header.addr3[0], addr txDesc.sa[0], 6.csize_t)
  else:
    # No DS or WDS: Addr1=DA, Addr2=SA, Addr3=BSSID
    discard c_memcpy(addr hdr.header.addr1[0], addr txDesc.da[0], 6.csize_t)
    discard c_memcpy(addr hdr.header.addr3[0], addr vif.bssid[0], 6.csize_t)

  let headerStaIdx = staIdx
  if headerStaIdx != 0xFF'u8:
    hdr.qosCtrl = headerStaIdx.uint16

  if frameType == 0x0800'u16:
    nimFwDbgDhcpTxDescBytes =
      txDesc.staIdx.uint32 or
      (txDesc.vifIdx.uint32 shl 8) or
      (txDesc.hostVifType.uint32 shl 16) or
      (txDesc.staInfoIdx.uint32 shl 24)
    nimFwDbgDhcpTxHdr0 =
      hdr.header.frameControl.uint32 or
      (hdr.header.seqCtrl.uint32 shl 16)
    nimFwDbgDhcpTxHdr1 =
      macAddrLo32(addr hdr.header.addr1) or
      (cast[ptr uint16](addr hdr.header.addr2[0])[].uint32 shl 16)
    nimFwDbgDhcpTxHdr2 =
      macAddrLo32(addr hdr.header.addr3) or
      (hdr.qosCtrl.uint32 shl 16)

  if frameType == 0x8E88'u16 or frameType == 0x888E'u16:
    nimFwDbgEapolTxDescBytes =
      txDesc.staIdx.uint32 or
      (txDesc.vifIdx.uint32 shl 8) or
      (txDesc.hostVifType.uint32 shl 16) or
      (txDesc.staInfoIdx.uint32 shl 24)
    nimFwDbgEapolTxHdr0 =
      hdr.header.frameControl.uint32 or
      (hdr.header.seqCtrl.uint32 shl 16)
    nimFwDbgEapolTxHdr1 = macAddrLo32(addr hdr.header.addr1)
    nimFwDbgEapolTxHdr2 = macAddrLo32(addr hdr.header.addr2)
    nimFwDbgEapolTxHdr3 =
      macAddrLo32(addr hdr.header.addr3) or
      (hdr.qosCtrl.uint32 shl 16)
    nimFwDbgEapolTxAddrHi =
      macAddrHi16(addr hdr.header.addr1) or
      (macAddrHi16(addr hdr.header.addr2) shl 16)

  when defined(bl808WifiConnectTrace):
    let protoTrace = frameLen
    if protoTrace == 0x8E88'u16:
      nimFwConnectTrace2U32("[WIFI-CT] tx_eapol_fc ",
                            fullFc.uint32 or (vifMode.uint32 shl 16),
                            cast[uint32](hdrBufBase))
      ensureCurrentBuild()
      let addr1Trace = macAddrLo32(addr hdr.header.addr1)
      let addr2Trace = macAddrLo32(addr hdr.header.addr2)
      let addr3Trace = macAddrLo32(addr hdr.header.addr3)
      nimFwConnectTrace2U32("[WIFI-CT] tx_eapol_a12 ", addr1Trace, addr2Trace)
      ensureCurrentBuild()
      nimFwConnectTrace2U32("[WIFI-CT] tx_eapol_a3 ", addr3Trace, frameLen.uint32)
      ensureCurrentBuild()
      let addrHi12Trace = macAddrHi16(addr hdr.header.addr1) or
        (macAddrHi16(addr hdr.header.addr2) shl 16)
      let addrHi3Trace = macAddrHi16(addr hdr.header.addr3)
      nimFwConnectTrace2U32("[WIFI-CT] tx_eapol_ahi ", addrHi12Trace, addrHi3Trace)
      ensureCurrentBuild()
      nimFwConnectTrace2U32("[WIFI-CT] tx_eapol_snap ",
                            snapTraceLo(layout),
                            snapTraceHi(layout))
      ensureCurrentBuild()

  ensureCurrentBuild()
  # Protected data frames need the Protected bit when a pairwise key is active.
  # The reference skips only the control-port EtherType gate; other Ethernet-II
  # data frames (DHCP/ARP/IP) are encrypted and must advertise that in FC.
  if pairwiseKey != 0:
    let keyFlags = vifKeyPointers(vif).flags
    let isControlPort =
      (keyFlags and 2) != 0 and sta.rateWord == lmacGateHalfword(frameLen)
    if not isControlPort:
      hdr.header.frameControl = hdr.header.frameControl or 0x4000'u16

  if frameType == 0x0800'u16:
    let finalStaIdx = staIdx
    if finalStaIdx != 0xFF'u8:
      hdr.qosCtrl = finalStaIdx.uint16
    nimFwDbgDhcpTxLayout[0] = pointerAddrU32(bufPtr)
    nimFwDbgDhcpTxLayout[1] = pointerAddrU32(cast[pointer](layout.mac))
    nimFwDbgDhcpTxLayout[2] = pointerAddrU32(cast[pointer](layout.sec))
    nimFwDbgDhcpTxLayout[3] = pointerAddrU32(cast[pointer](layout.snap))
    nimFwDbgDhcpTxLayout[4] =
      txDesc.hdrLen.uint32 or
      (layout.macLen.uint32 shl 8) or
      (layout.secLen.uint32 shl 16) or
      (layout.snapLen.uint32 shl 24)
    nimFwDbgDhcpTxLayout[5] =
      if layout.secLen >= 4: debugLoadLe32(cast[pointer](layout.sec))
      else: 0'u32
    nimFwDbgDhcpTxLayout[6] = snapTraceLo(layout)
    nimFwDbgDhcpTxLayout[7] = 0
    nimFwDbgDhcpTxHdr0 =
      hdr.header.frameControl.uint32 or
      (hdr.header.seqCtrl.uint32 shl 16)
    nimFwDbgDhcpTxHdr2 =
      macAddrLo32(addr hdr.header.addr3) or
      (hdr.qosCtrl.uint32 shl 16)
    # The header-end pointer does not own any payload bytes. Gather the prefix
    # from descriptor spans, stopping at either the frame or snapshot boundary.
    for value in nimFwDbgDhcpMacRaw.mitems:
      value = 0
    let rawCapacity = nimFwDbgDhcpMacRaw.len.uint32
    let rawHeaderLen = min(txDesc.hdrLen.uint32, rawCapacity)
    if rawHeaderLen != 0:
      discard c_memcpy(addr nimFwDbgDhcpMacRaw[0], cast[pointer](layout.mac),
                       rawHeaderLen.csize_t)
    var macRawLen = rawHeaderLen
    let payloadBytes = txPayloadChainLength(txDesc)
    var remainingPayload =
      if payloadBytes == txDesc.seqPassthrough.int32:
        min(txDesc.seqPassthrough.uint32, 32'u32)
      else: 0'u32
    for i in 0 ..< txDesc.bufferPtrs.len:
      if remainingPayload == 0 or macRawLen == rawCapacity:
        break
      let start = txDesc.bufferPtrs[i]
      let length = txDesc.bufferLens[i]
      let copied = min(length, min(remainingPayload, rawCapacity - macRawLen))
      discard c_memcpy(addr nimFwDbgDhcpMacRaw[macRawLen],
                       cast[pointer](start.uint), copied.csize_t)
      macRawLen += copied
      remainingPayload -= copied
    for i in 0 ..< min(macRawLen - rawHeaderLen, 4'u32):
      nimFwDbgDhcpTxLayout[7] = nimFwDbgDhcpTxLayout[7] or
        (nimFwDbgDhcpMacRaw[rawHeaderLen + i].uint32 shl (8 * i))
    nimFwDbgDhcpMacRawLen = macRawLen
  true

proc txu_cntrl_frame_build*(desc: pointer, bufPtr: pointer) {.exportc, cdecl.} =
  ## Preserve the vendor's void ABI; the in-tree allocator checks the result.
  discard txuBuildFrame(desc, bufPtr)

proc txuCancelFrame(param: pointer; ac: uint8) =
  # A retired peer must not receive rate-control feedback from this drop.
  hostTxDescAt(param).staInfoIdx = 0xFF
  if txlResetting():
    # Reset will clear firmware queues; return this unqueued host frame now.
    txlConfirmUnqueuedHost(param, 0xC0000000'u32 or TxuDropStatusOrdinary, ac)
    return
  txl_cntrl_inc_pck_cnt(ac)
  txl_cfm_push(param, 0xC0000000'u32 or TxuDropStatusOrdinary, ac.uint32)

{.emit: "__attribute__((optimize(\"crossjumping\"))) NIM_BOOL txu_cntrl_push(void*, unsigned char);".}
proc txu_cntrl_push*(param: pointer; ac: uint8): bool {.exportc, cdecl.} =
  ## Push a TX frame from upper MAC to lower TX layer (154 instrs).
  ## From disassembly: this is the main TX data path entry point from the host.
  ## param is a txdesc (TX descriptor from host via IPC).
  ##
  ## Layout of txdesc (param) key fields:
  ##   [32..33] = uint16 frame_len
  ##   [42..43] = uint16 seq_num
  ##   [46]     = uint8 TID (0xFF = non-QoS; named staIdx in HostTxDescView)
  ##   [47]     = uint8 vif_idx
  ##   [49]     = uint8 sta_info_idx
  ##   [88]     = pointer to upper desc / TX policy
  ##   [91]     = uint8 tx_flags (cleared to 0 before push)
  ##   [96..97] = uint16 seq_ctrl_out
  ##   [98]     = uint8 MAC/security header length
  ##   [99]     = uint8 QoS/SNAP extension length
  ##   [100]    = uint8 security tail length
  ##
  ## Function flow:
  ##   1. Resolve sta_info_idx to the STA table. The blob skips only the active
  ##      flag check for sta_info_idx == 0xFF; the control-port gate and later
  ##      rate-control lookup still require a valid STA table entry.
  ##   2. Check the STA gate at sta_info_tab[72/70]. State 2 skips the gate;
  ##      state 1 compares the byte-swapped descriptor halfword with sta+70.
  ##   3. Allocate TX buffer: calls txl_buffer_alloc for the frame
  ##   4. If allocation fails, go to L69 (drop path with error counters)
  ##   5. For TID != 0xFF: assign and increment the STA's per-TID sequence
  ##      counter at sta+52+2*TID, wrapping at 4096.
  ##   6. Call txu_cntrl_frame_build to format the 802.11 header
  ##   7. Set up HW descriptor: compute frame length including header,
  ##      determine if frame needs encryption (FC ToDS/FromDS check for
  ##      Ethernet-II frames needing SNAP), and set ht_flag
  ##   8. Call txl_machdr_format(txdesc, 0) for MAC header formatting
  ##   9. Call txl_cntrl_push_int(txdesc, ac) to push into lower MAC TX queue
  ##  10. Set txdesc[91] = 0 to clear TX flags
  ##  11. Tail-call to txl_cntrl_push(ac, txdesc) via indirect jump
  ##
  ## Drop path (L69): sets up error counters in stack (0x20000, 0x80000,
  ## 0x100000) and returns without transmitting.
  let desc = hostTxDescAt(param)
  txSecurityForget(param)
  let savedIrq = irqSave()
  defer: irqRestore(savedIrq)

  if desc.vifIdx >= MAX_VIFS.uint8 or txlVifIsRetiring(desc.vifIdx):
    txuCancelFrame(param, ac)
    return false
  let identity = txlCaptureSession(desc)
  template ensureCurrentSession() =
    if not txlSessionCurrent(identity, desc):
      txuCancelFrame(param, ac)
      return false

  when defined(bl808WifiConnectTrace):
    let protoTrace = desc.frameLen
    if protoTrace == 0x8E88'u16 or protoTrace == 0x888E'u16:
      nimFwConnectTrace2U32("[WIFI-CT] txu_push_eapol ",
                                    ac.uint32 or (desc.staIdx.uint32 shl 8) or
                                      (desc.vifIdx.uint32 shl 16) or
                                      (desc.staInfoIdx.uint32 shl 24),
                                    cast[uint32](cast[uint](desc.queueFirst)))
  ensureCurrentSession()

  let staInfoIdx = desc.staInfoIdx
  var dropFrame = false
  let sta: ptr StaInfoView =
    if staInfoIdx < STA_INFO_TAB_ENTRIES.uint8:
      staInfoForIdx(staInfoIdx)
    else:
      nil

  # Step 1: Check STA validity. The vendor uses sta_info_idx after the 0xFF
  # branch for the control-port gate; keep that drop behavior without reading
  # outside sta_info_tab.
  if sta == nil:
    dropFrame = true
  else:
    if staInfoIdx != 0xFF'u8:
      if sta.valid == 0:
        dropFrame = true

    if not dropFrame:
      # Step 2: Check STA type and gate halfword (blob uses sta_info_tab, NOT vif).
      let stationControlPortState = sta.controlPortState
      if stationControlPortState == 2:
        discard  # State 2 (ready/AP): skip the STA control-port gate.
      elif stationControlPortState == 1:
        if sta.rateWord != lmacGateHalfword(desc.frameLen):
          dropFrame = true
      else:
        dropFrame = true

  # Step 2: Look up VIF for this frame
  let vifIdx = desc.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let vifEntry = cast[pointer](vif)

  # Blob funnels the 3 drop paths through a shared tail, then uses th.lrw to
  # map reasons 0/1/2 to the status masks below before txl_cfm_push.
  var doDrop = false
  var dropStatus = TxuDropStatusOrdinary
  if dropFrame:
    doDrop = true
  else:
    if vif.vifType == 0:
      if vif.keyPsState != 0:
        doDrop = true
        dropStatus = TxuDropStatusCryptoPending
    if not doDrop and not txl_cntrl_tx_check(vifEntry):
      doDrop = true
      dropStatus = TxuDropStatusTxNotReady
  ensureCurrentSession()
  if doDrop:
    vif.psFlags = 1
    txl_cntrl_inc_pck_cnt(ac)
    let dropErrFlags = 0xC0000000'u32 or dropStatus
    txl_cfm_push(param, dropErrFlags, ac.uint32)
    return false

  # Step 4: Handle sequence number for data frames
  let tid = desc.staIdx  # Host descriptor byte 46 is the TID, not the STA index.
  var hdrLen: uint16 = 24
  if tid != 0xFF:
    let staInfoForSeq = desc.staInfoIdx
    let staSeq = staTxSequence(staInfoForIdx(staInfoForSeq))
    if tid >= 8:
      txuCancelFrame(param, ac)
      return false
    hdrLen = 26
    let seqNum = staSeq.seqCounters[tid.int]
    let nextSeq = (seqNum + 1) and 0xFFF'u16
    staSeq.seqCounters[tid.int] = nextSeq
    desc.seqAssigned = seqNum

  # Step 5: Compute security header length.
  # Blob ABI: (a0=desc, a1=&secTailLenOut) -> returns secHdrLen in a0.
  # Previous Nim discarded the return and used the out-param as the header
  # length — wrong direction. Correct mapping:
  #   return value = sec HEADER length (IV) — added to frame hdr total
  #   *lenOut      = sec TAIL length (MIC/ICV) — written to desc[100]
  var secTailLenOut: uint32 = 0
  let securityHeaderLen = txu_cntrl_sechdr_len_compute(param, addr secTailLenOut)
  ensureCurrentSession()
  if securityHeaderLen notin [0'u32, 4'u32, 8'u32]:
    txuCancelFrame(param, ac)
    return false
  let secHdrLen = securityHeaderLen.uint8
  let secTailLen = cast[uint8](secTailLenOut)

  # Step 6-8: Inline MAC header and descriptor setup (blob does NOT call
  # txu_cntrl_frame_build or txl_machdr_format — handles inline).
  # Blob at 0xe6-0x11e:
  #   desc[96]   = desc[12]                       ; seq_ctrl passthrough
  #   desc[98]   = sechdr_len + mac_hdr_base + SNAP length
  #   desc[99]   = SNAP length
  #   desc[100]  = secTailLen                     ; MIC/ICV byte count
  let frameLen = desc.frameLen
  let frameType = lmacGateHalfword(frameLen)
  # The vendor uses >1536 here but >=1536 in the frame builder.
  let qosExt = txFrameSnapLen(frameType)
  hdrLen += qosExt.uint16

  desc.seqOut = desc.seqPassthrough
  desc.hdrLen = (hdrLen + secHdrLen.uint16).uint8
  desc.qosExtLen = qosExt
  desc.secTailLen = secTailLen
  if frameType == 0x0800'u16:
    nimFwDbgDhcpTxSec =
      secHdrLen.uint32 or
      (secTailLen.uint32 shl 8) or
      (hdrLen.uint32 shl 16) or
      (qosExt.uint32 shl 24)
  when defined(bl808WifiConnectTrace):
    let protoTraceSec = desc.frameLen
    if protoTraceSec == 0x8E88'u16 or protoTraceSec == 0x888E'u16:
      nimFwConnectTrace2U32("[WIFI-CT] txu_sec ",
                            secHdrLen.uint32 or (secTailLen.uint32 shl 8) or
                              (hdrLen.uint32 shl 16) or (qosExt.uint32 shl 24),
                            cast[uint32](desc.policy))
  ensureCurrentSession()

  # Step 9: Rate control check (blob: call me_check_rc at 0x122)
  let staInfoForRate = desc.staInfoIdx
  me_check_rc(staInfoForRate)
  ensureCurrentSession()

  # Step 10: Update buffer control.
  # Blob ABI at 0x12a-0x138:
  #   lbu a4, 49(s0)            ; sta_info_idx
  #   li  a5, 368               ; STA_ENTRY_SIZE
  #   mv  a0, s4                ; s4 = sta_info_tab base
  #   .insn  (th.mula: a0 += a4*a5)   ; a0 = &sta_info_tab[sta_info_idx]
  #   call me_update_buffer_control
  #   sw  a0, 88(s0)             ; desc[88] = returned tx_policy pointer
  let txPolicyForPush = me_update_buffer_control(cast[pointer](staInfoForIdx(staInfoForRate)))
  ensureCurrentSession()

  # Step 11: Store result, clear flags, tail-call txl_cntrl_push
  desc.policy = txPolicyForPush
  if lmacGateHalfword(desc.frameLen) == 0x0800'u16:
    nimFwDbgDhcpTxPolicy = pointerAddrU32(txPolicyForPush)
    nimFwDbgDhcpTxBufDesc = pointerAddrU32(desc.bufDesc)
    nimFwDbgDhcpTxHwDesc = pointerAddrU32(desc.hwDesc)
  vif.psFlags = 0

  # Tail-call to txl_cntrl_push (blob: a0=desc, a1=ac; jr t1 at 0x162)
  return txl_cntrl_push(param, ac) != 0

proc txu_cntrl_cfm*(param: pointer) {.exportc, cdecl.} =
  ## Handle TX upper confirmation (11 instrs in blob).
  ## From disassembly: reads the THD chain pointer from the descriptor,
  ## sets the confirm-done bit (bit 0) in THD[16], writes 0x0101 to THD[12]
  ## (confirm type), clears the ke_msg linkage word at param[-4], then
  ## copies THD[16] to the confirm pointer at param[16].
  txlInvalidateDmaFrame(param)
  let desc = hostTxDescAt(param)
  # a5 = lw 0(hwDescPtr) -> THD base (first word of HW desc is THD addr)
  let thd = hostTxHeadThd(hostTxHwDescAt(desc.hwDesc))
  # THD[16] |= 1  (set confirm-done bit)
  thd.flags = thd.flags or 1
  # THD[12] = 0x0101  (confirm type/status = 257)
  hostTxThdConfirmAt(thd).confirmType = 0x0101'u16
  # Clear ke_msg linkage at param[-4]
  hostTxConfirmLinkWord(desc)[] = 0
  # Copy final THD[16] to confirm pointer
  cast[ptr uint32](desc.cfmDst)[] = thd.flags

proc txu_cntrl_tkip_mic_append*(txdesc: pointer) {.exportc, cdecl.} =
  ## Append TKIP MIC to TX frame (109 instrs).
  ## a0 = TX descriptor.
  ## Looks up STA entry from txdesc[49] (STA index), finds the key-holder at
  ## sta[244], then loads the actual key slot from holder[0]. If no key slot is
  ## installed, returns immediately.
  ## Checks key type at key[152]: type 1 = TKIP, type 0/3 = WEP
  ## scratch descriptor path. For TKIP, appends the link-local scratch
  ## THD as the final payload descriptor, computes Michael across the header
  ## extension and payload THDs, then writes the final 8-byte MIC into that
  ## scratch THD payload.
  let desc = hostTxDescAt(txdesc)
  # Control-port bypass reserves no MIC/ICV even when a key is installed.
  if desc == nil or desc.secTailLen == 0:
    return
  let staIdx = desc.staInfoIdx
  let sta = staInfoForIdx(staIdx)
  # Blob ABI: sta+244 points at a key-holder; holder[0] is the key slot.
  let keyHolder = sta.keyMat
  if keyHolder == nil:
    return
  let keySlot = cast[ptr pointer](cast[uint](keyHolder))[]
  if keySlot == nil:
    return
  let key = cast[ptr VifKeySlotView](keySlot)
  let keyType = key.cipherType
  let linkDesc = desc.bufDesc
  let link = hostTxLinkDescAt(linkDesc)
  let scratchPayloadEndIndex =
    if keyType == 1:
      11
    elif keyType == 0 or keyType == 3:
      3
    else:
      -1
  if scratchPayloadEndIndex < 0:
    return

  let scratch = addr link.micScratch
  let scratchThd = cast[ptr HostTxThdEntryView](scratch)
  var terminalThd = addr link.headerThd
  while terminalThd.next != nil:
    terminalThd = hostTxThdAt(terminalThd.next)
  terminalThd.next = cast[pointer](scratchThd)

  # The link-local MIC scratch doubles as the terminal THD. These field names
  # describe the Michael workspace, but the first 20 bytes are the THD header.
  scratch.magic = 0xCAFEFADE'u32
  scratch.initialLeftWord = 0
  scratch.micInputCursor = cast[pointer](addr scratch.micInputScratch[0])
  scratch.micInputEnd =
    cast[pointer](addr scratch.micInputScratch[scratchPayloadEndIndex])
  scratch.pendingWord = 0

  if keyType == 1:
    let priority = desc.staIdx
    var micCtx {.noinit.}: array[16, uint8]
    let micCtxPtr = cast[pointer](addr micCtx[0])
    let keyMaterial = cast[pointer](cast[uint](keySlot) + 136'u)
    me_mic_init(micCtxPtr, keyMaterial,
                cast[pointer](addr desc.da[0]),
                cast[pointer](addr desc.sa[0]),
                priority)

    let firstMicStart =
      hostTxLinkMacHdrAddr(link) + desc.hdrLen.uint - desc.qosExtLen.uint
    me_mic_calc(micCtxPtr, cast[pointer](firstMicStart), desc.qosExtLen.uint32)

    var payloadThd = hostTxThdAt(link.headerThd.next)
    while payloadThd != nil:
      let nextPayloadThd = payloadThd.next
      if nextPayloadThd == nil:
        me_mic_end(micCtxPtr)
        let micDst = cast[ptr UncheckedArray[uint8]](payloadThd.payloadStart.uint)
        let micResult = cast[ptr UncheckedArray[uint8]](micCtxPtr)
        for micByteIndex in 0 ..< 8:
          micDst[micByteIndex] = micResult[micByteIndex]
        return
      let segmentStart = payloadThd.payloadStart
      let segmentLen = payloadThd.payloadEnd - segmentStart + 1
      me_mic_calc(micCtxPtr, cast[pointer](segmentStart.uint), segmentLen)
      payloadThd = hostTxThdAt(nextPayloadThd)

    me_mic_end(micCtxPtr)
    {.emit: "asm volatile(\"lw a5, 8(zero); ebreak\");".}

  return

proc txu_cntrl_protect_mgmt_frame*(param: pointer, hdrPtr: pointer, extraLen: uint32) {.exportc, cdecl.} =
  ## Apply management frame protection (108 bytes in blob).
  ## Blob: checks cached sechdr_len at param[98], computes if needed,
  ## sets Protected Frame bit (0x4000) in frame header, then appends security header.
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  let desc = hostTxDescAt(param)
  if desc == nil or hdrPtr == nil:
    return
  var secHdrLen: uint8
  var secTailLen: uint8
  if desc.hdrLen == 0:
    # Not cached: compute security header length
    var tailLen: uint32 = 0
    let securityHeaderLen = txu_cntrl_sechdr_len_compute(param, addr tailLen)
    if securityHeaderLen notin [4'u32, 8'u32] or tailLen > high(uint8).uint32:
      desc.hdrLen = 0
      desc.secTailLen = 0
      return
    secHdrLen = securityHeaderLen.uint8
    secTailLen = cast[uint8](tailLen)
    # Cache the results in descriptor
    desc.hdrLen = secHdrLen
    desc.secTailLen = secTailLen
  else:
    # Use cached values
    secHdrLen = desc.hdrLen
    secTailLen = desc.secTailLen
  if not ((secHdrLen == 4 and secTailLen == 4) or
          (secHdrLen == 8 and secTailLen in [8'u8, 12'u8])):
    desc.hdrLen = 0
    desc.secTailLen = 0
    return
  let hdrAddr = cast[uint](hdrPtr)
  # Compute position for security header: hdrPtr + extraLen + secHdrLen
  let secHdrPos = cast[pointer](hdrAddr + extraLen.uint + secHdrLen.uint)
  # Append security header (blob: txu_cntrl_sec_hdr_append(param, secHdrPos))
  let secHdrStart = cast[pointer](hdrAddr + extraLen.uint)
  if txu_cntrl_sec_hdr_append(param, secHdrPos, 0'u32) != secHdrStart:
    desc.hdrLen = 0
    desc.secTailLen = 0
    return
  # Set Protected only after a usable key has supplied the security header.
  let fc = macFrameControlAt(hdrPtr)
  fc.frameControl = fc.frameControl or 0x4000'u16
