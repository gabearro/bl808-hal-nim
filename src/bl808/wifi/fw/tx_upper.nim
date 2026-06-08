# ###########################################################################
#                   TX Upper (txu_*)
# ###########################################################################

proc txu_cntrl_init*() {.exportc, cdecl.} =
  ## Initialize TX upper control.
  discard

proc txu_cntrl_frame_build*(desc: pointer, bufPtr: pointer) {.exportc, cdecl.} =
  ## Build a TX upper control frame (163 instrs).
  ## From disassembly: constructs the MAC header and HW descriptor fields for
  ## a host-originated TX frame. Blob ABI: a0=txdesc, a1=bufPtr (MAC header
  ## write point = desc+556+hdrLen). The current Nim body still derives the
  ## write point from txdesc itself; bufPtr is accepted for ABI compatibility.
  ##
  ## Layout of txdesc (param):
  ##   [14..15] = uint16 addr1 field (from host)
  ##   [20..25] = addr1 (DA, 3 x uint16)
  ##   [22..23] = addr2 part
  ##   [24..25] = addr3 part
  ##   [26..27] = addr4 part (for 4-addr)
  ##   [28..29] = addr5 part
  ##   [30..31] = addr6 part
  ##   [32..33] = uint16 frame_len (host payload length)
  ##   [42..43] = uint16 seq_ctrl / TID related
  ##   [46]     = uint8 sta_idx
  ##   [47]     = uint8 vif_idx
  ##   [49]     = uint8 sta_info_idx (for rate table lookup)
  ##   [12..13] = uint16 ethertype
  ##
  ## The function:
  ##   1. Reads frame_len from txdesc[32] and checks if <= 1535 (non-802.11)
  ##   2. If > 1535: copies AMSDU sub-header from host descriptor
  ##   3. Calls txl_machdr_format(txdesc, 1) to format MAC header
  ##   4. Looks up VIF entry (vif_info_tab + vif_idx * 1512) and STA entry
  ##      (sta_info_tab + sta_info_idx * 368)
  ##   5. Gets rate/policy table from STA entry
  ##   6. Builds frame control word in the MAC header buffer:
  ##      - If sta_idx==0xFF: sets FC=0 (null header), clears addr fields
  ##      - Else: sets FC with protected bit, power mgmt, from/to DS
  ##   7. Computes address offsets based on FC To/From DS bits:
  ##      - 0x100 (256): use STA rate table addr1/2/3
  ##      - 0x200 (512): use txdesc addr fields for SA
  ##      - 0x000: use txdesc addr + VIF link for BSSID
  ##   8. Fills in Duration/ID, Addr1-4 fields in the MAC header
  ##   9. Checks if frame needs NAV protection (RTS/CTS check) and
  ##      may set "more data" bit 0x4000 in FC
  ##
  ## This is a critical TX path function that formats 802.11 headers.
  let txDesc = hostTxDescAt(desc)
  let bufPtrU = cast[uint](bufPtr)
  if bufPtrU == 0:
    return
  let frameLen = txDesc.frameLen
  let frameType = lmacGateHalfword(frameLen)
  let layout = txFrameBuildLayout(txDesc, bufPtr, frameType)

  txFrameWriteSnap(layout, frameLen)
  discard txu_cntrl_sec_hdr_append(desc, cast[pointer](layout.sec), 1'u32)

  let vifIdx = txDesc.vifIdx
  let staInfoIdx = txDesc.staInfoIdx
  let vif = vifChannelForIdx(vifIdx)
  let sta = staInfoForIdx(staInfoIdx)

  # Get rate table from STA entry: sta_entry[244] -> rate_ctrl pointer
  let rateCtrl = sta.keyMat
  let pairwiseKey =
    if rateCtrl == nil: 0'u32
    else: pointerAddrU32(txSecurityKeyListAt(rateCtrl).pairwiseKey)

  let staIdx = txDesc.staIdx
  let hdr = layout.mac
  let hdrBufBase = cast[uint](hdr)

  # Build frame control
  var fc: uint16 = 0
  if staIdx != 0xFF:
    # Set frame control: Data frame (type=2, subtype from txdesc)
    fc = 0x0080'u16  # QoS data subtype in the low FC byte.
    hdr.data.frameControl = fc

    # Write sequence control from txdesc[42]
    hdr.data.seqCtrl = txDesc.seqAssigned shl 4
    hdr.qosCtrl = staIdx.uint16
  else:
    # No STA: zero out frame control and address fields
    hdr.data.frameControl = 0
    hdr.data.seqCtrl = 0

  # OR in "Data" frame type (0x0008) into FC
  var fullFc = hdr.data.frameControl
  fullFc = fullFc or 0x0008  # Data type bit

  # VIF mode selects ToDS/FromDS in the vendor frame builder:
  # 0=STA(ToDS), 2=AP(FromDS), other=no-DS.
  let vifMode = vif.vifType
  if vifMode == 0:
    fullFc = fullFc or 0x0108'u16
  elif vifMode == 2:
    fullFc = fullFc or 0x0208'u16

  # Write back FC
  hdr.data.frameControl = fullFc

  # Addr2 is always the local VIF MAC in the vendor builder.
  discard c_memcpy(addr hdr.data.addr2[0], addr vif.macAddr[0], 6.csize_t)

  # Fill addresses based on To/From DS bits
  let toFromDs = fullFc and 0x0300
  if toFromDs == 0x0100:
    # ToDS=1, FromDS=0: Addr1=BSSID (from STA), Addr2=SA (from VIF), Addr3=DA
    discard c_memcpy(addr hdr.data.addr1[0], addr sta.macAddr[0], 6.csize_t)
    discard c_memcpy(addr hdr.data.addr3[0], addr txDesc.da[0], 6.csize_t)
  elif toFromDs == 0x0200:
    # ToDS=0, FromDS=1: Addr1=DA, Addr2=BSSID, Addr3=SA
    discard c_memcpy(addr hdr.data.addr1[0], addr txDesc.da[0], 6.csize_t)
    discard c_memcpy(addr hdr.data.addr3[0], addr txDesc.sa[0], 6.csize_t)
  else:
    # No DS or WDS: Addr1=DA, Addr2=SA, Addr3=BSSID
    discard c_memcpy(addr hdr.data.addr1[0], addr txDesc.da[0], 6.csize_t)
    discard c_memcpy(addr hdr.data.addr3[0], addr vif.bssid[0], 6.csize_t)

  let headerStaIdx = txDesc.staIdx
  if headerStaIdx != 0xFF'u8:
    hdr.qosCtrl = headerStaIdx.uint16

  if frameType == 0x0800'u16:
    nimFwDbgDhcpTxDescBytes =
      txDesc.staIdx.uint32 or
      (txDesc.vifIdx.uint32 shl 8) or
      (txDesc.hostVifType.uint32 shl 16) or
      (txDesc.staInfoIdx.uint32 shl 24)
    nimFwDbgDhcpTxHdr0 =
      hdr.data.frameControl.uint32 or
      (hdr.data.seqCtrl.uint32 shl 16)
    nimFwDbgDhcpTxHdr1 =
      macAddrLo32(addr hdr.data.addr1) or
      (cast[ptr uint16](addr hdr.data.addr2[0])[].uint32 shl 16)
    nimFwDbgDhcpTxHdr2 =
      macAddrLo32(addr hdr.data.addr3) or
      (hdr.qosCtrl.uint32 shl 16)

  if frameType == 0x8E88'u16 or frameType == 0x888E'u16:
    nimFwDbgEapolTxDescBytes =
      txDesc.staIdx.uint32 or
      (txDesc.vifIdx.uint32 shl 8) or
      (txDesc.hostVifType.uint32 shl 16) or
      (txDesc.staInfoIdx.uint32 shl 24)
    nimFwDbgEapolTxHdr0 =
      hdr.data.frameControl.uint32 or
      (hdr.data.seqCtrl.uint32 shl 16)
    nimFwDbgEapolTxHdr1 = macAddrLo32(addr hdr.data.addr1)
    nimFwDbgEapolTxHdr2 = macAddrLo32(addr hdr.data.addr2)
    nimFwDbgEapolTxHdr3 =
      macAddrLo32(addr hdr.data.addr3) or
      (hdr.qosCtrl.uint32 shl 16)
    nimFwDbgEapolTxAddrHi =
      macAddrHi16(addr hdr.data.addr1) or
      (macAddrHi16(addr hdr.data.addr2) shl 16)

  when defined(bl808WifiConnectTrace):
    let protoTrace = frameLen
    if protoTrace == 0x8E88'u16:
      nimFwConnectTrace2U32("[WIFI-CT] tx_eapol_fc ",
                            fullFc.uint32 or (vifMode.uint32 shl 16),
                            cast[uint32](hdrBufBase))
      let addr1Trace = macAddrLo32(addr hdr.data.addr1)
      let addr2Trace = macAddrLo32(addr hdr.data.addr2)
      let addr3Trace = macAddrLo32(addr hdr.data.addr3)
      nimFwConnectTrace2U32("[WIFI-CT] tx_eapol_a12 ", addr1Trace, addr2Trace)
      nimFwConnectTrace2U32("[WIFI-CT] tx_eapol_a3 ", addr3Trace, frameLen.uint32)
      let addrHi12Trace = macAddrHi16(addr hdr.data.addr1) or
        (macAddrHi16(addr hdr.data.addr2) shl 16)
      let addrHi3Trace = macAddrHi16(addr hdr.data.addr3)
      nimFwConnectTrace2U32("[WIFI-CT] tx_eapol_ahi ", addrHi12Trace, addrHi3Trace)
      nimFwConnectTrace2U32("[WIFI-CT] tx_eapol_snap ",
                            snapTraceLo(layout),
                            snapTraceHi(layout))

  # Protected data frames need the Protected bit when a pairwise key is active.
  # The reference skips only the control-port EtherType gate; other Ethernet-II
  # data frames (DHCP/ARP/IP) are encrypted and must advertise that in FC.
  if pairwiseKey != 0:
    let keyFlags = vifKeyPointers(vif).flags
    let isControlPort =
      (keyFlags and 2) != 0 and sta.rateWord == lmacGateHalfword(frameLen)
    if not isControlPort:
      hdr.data.frameControl = hdr.data.frameControl or 0x4000'u16

  if frameType == 0x0800'u16:
    let finalStaIdx = txDesc.staIdx
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
      debugLoadLe32(cast[pointer](layout.sec))
    nimFwDbgDhcpTxLayout[6] =
      debugLoadLe32(cast[pointer](layout.snap))
    nimFwDbgDhcpTxLayout[7] =
      debugLoadLe32(bufPtr)
    nimFwDbgDhcpTxHdr0 =
      hdr.data.frameControl.uint32 or
      (hdr.data.seqCtrl.uint32 shl 16)
    nimFwDbgDhcpTxHdr2 =
      macAddrLo32(addr hdr.data.addr3) or
      (hdr.qosCtrl.uint32 shl 16)
    var macRawLen = txDesc.hdrLen.uint32 + 32'u32
    nimFwDbgDhcpMacRawLen = macRawLen
    if macRawLen > nimFwDbgDhcpMacRaw.len.uint32:
      macRawLen = nimFwDbgDhcpMacRaw.len.uint32
    if macRawLen != 0'u32:
      discard c_memcpy(addr nimFwDbgDhcpMacRaw[0], cast[pointer](layout.mac),
                       macRawLen.csize_t)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void txu_cntrl_push(void*);".}
{.emit: "__attribute__((optimize(\"crossjumping\"))) void txu_cntrl_push(void*);".}
proc txu_cntrl_push*(param: pointer) {.exportc, cdecl.} =
  ## Push a TX frame from upper MAC to lower TX layer (154 instrs).
  ## From disassembly: this is the main TX data path entry point from the host.
  ## param is a txdesc (TX descriptor from host via IPC).
  ##
  ## Layout of txdesc (param) key fields:
  ##   [32..33] = uint16 frame_len
  ##   [42..43] = uint16 seq_num
  ##   [46]     = uint8 sta_idx
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
  ##   1. Check if sta_info_idx != 0xFF; if so, look up STA entry and check
  ##      if STA is active (sta_entry[42] != 0). If not active, go to L69 (drop).
  ##   2. Check the STA gate at sta_info_tab[72/70]. Type 2 skips the gate;
  ##      type 1 compares the byte-swapped descriptor halfword with sta+70.
  ##   3. Allocate TX buffer: calls txl_buffer_alloc for the frame
  ##   4. If allocation fails, go to L69 (drop path with error counters)
  ##   5. For sta_idx != 0xFF: compute sequence number from STA entry,
  ##      increment STA's per-TID sequence counter (offset varies by 4-addr)
  ##   6. Call txu_cntrl_frame_build to format the 802.11 header
  ##   7. Set up HW descriptor: compute frame length including header,
  ##      determine if frame needs encryption (FC ToDS/FromDS check for
  ##      frames > 1536 needing QoS), and set ht_flag
  ##   8. Call txl_machdr_format(txdesc, 0) for MAC header formatting
  ##   9. Call txl_cntrl_push_int(txdesc, ac) to push into lower MAC TX queue
  ##  10. Set txdesc[91] = 0 to clear TX flags
  ##  11. Tail-call to txl_cntrl_push(ac, txdesc) via indirect jump
  ##
  ## Drop path (L69): sets up error counters in stack (0x20000, 0x80000,
  ## 0x100000) and returns without transmitting.
  let desc = hostTxDescAt(param)

  # Blob ABI: a0=txdesc (param), a1=ac. Capture a1 since Nim only sees a0.
  var acFromCaller: pointer
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", acFromCaller, ") );"].}
  let ac = cast[uint8](cast[uint](acFromCaller))

  when defined(bl808WifiConnectTrace):
    let protoTrace = desc.frameLen
    if protoTrace == 0x8E88'u16 or protoTrace == 0x888E'u16:
      nimFwConnectTrace2U32("[WIFI-CT] txu_push_eapol ",
                                    ac.uint32 or (desc.staIdx.uint32 shl 8) or
                                      (desc.vifIdx.uint32 shl 16) or
                                      (desc.staInfoIdx.uint32 shl 24),
                                    cast[uint32](cast[uint](desc.queueFirst)))

  let staInfoIdx = desc.staInfoIdx
  var dropFrame = false

  # Step 1: Check STA validity
  if staInfoIdx != 0xFF:
    let sta = staInfoForIdx(staInfoIdx)
    if sta.valid == 0:
      dropFrame = true

    if not dropFrame:
      # Step 2: Check STA type and gate halfword (blob uses sta_info_tab, NOT vif).
      let staType = sta.rxNss
      if staType == 2:
        discard  # Type 2 (AP): skip the STA control-port gate.
      elif staType == 1:
        if sta.rateWord != lmacGateHalfword(desc.frameLen):
          dropFrame = true
      else:
        dropFrame = true

  # Step 2: Look up VIF for this frame
  let vifIdx = desc.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let vifEntry = cast[pointer](vif)

  # Blob funnels the 3 drop paths (dropFrame / crypto-pending /
  # tx-not-ready) through a shared tail with one txl_cntrl_inc_pck_cnt
  # and one txl_cfm_push. Use a drop flag + computed errFlags.
  var doDrop = false
  var dropErrFlags: uint32 = 0
  if dropFrame:
    if vifIdx != 0:
      vif.psFlags = 1
    doDrop = true
    dropErrFlags = 0xC0000000'u32 or vifIdx.uint32
  else:
    if vif.vifType == 0:
      if vif.keyPsState != 0:
        vif.psFlags = 1
        doDrop = true
        dropErrFlags = 0xC0000001'u32
    if not doDrop and not txl_cntrl_tx_check(vifEntry):
      vif.psFlags = 1
      doDrop = true
      dropErrFlags = 0xC0000000'u32 or vifIdx.uint32
  if doDrop:
    txl_cntrl_inc_pck_cnt(ac)
    let irqState = irqSave()
    txl_cfm_push(param, dropErrFlags, ac.uint32)
    irqRestore(irqState)
    return

  # Step 4: Handle sequence number for data frames
  let staIdx = desc.staIdx
  var hdrLen: uint16 = 24
  if staIdx != 0xFF:
    let staInfoForSeq = desc.staInfoIdx
    let staSeq = staTxSequence(staInfoForIdx(staInfoForSeq))
    hdrLen = 26
    let seqNum = staSeq.seqCounter
    let nextSeq = (seqNum + 1) and 0xFFF'u16
    staSeq.seqCounter = nextSeq
    desc.seqAssigned = seqNum

  # Step 5: Compute security header length.
  # Blob ABI: (a0=desc, a1=&secTailLenOut) -> returns secHdrLen in a0.
  # Previous Nim discarded the return and used the out-param as the header
  # length — wrong direction. Correct mapping:
  #   return value = sec HEADER length (IV) — added to frame hdr total
  #   *lenOut      = sec TAIL length (MIC/ICV) — written to desc[100]
  var secTailLenOut: uint32 = 0
  let secHdrLen = cast[uint8](txu_cntrl_sechdr_len_compute(param, addr secTailLenOut))
  let secTailLen = cast[uint8](secTailLenOut)

  # Step 6-8: Inline MAC header and descriptor setup (blob does NOT call
  # txu_cntrl_frame_build or txl_machdr_format — handles inline).
  # Blob at 0xe6-0x11e:
  #   desc[96]   = desc[12]                       ; seq_ctrl passthrough
  #   desc[98]   = sechdr_len + mac_hdr_base + (8 if frame_len > 1536 else 0)
  #   desc[99]   = 8 if frame_len > 1536 else 0   ; QoS/SNAP extension length
  #   desc[100]  = secTailLen                     ; MIC/ICV byte count
  let frameLen = desc.frameLen
  let frameType = lmacGateHalfword(frameLen)
  var qosExt: uint8 = 0
  if frameType > 1536:
    qosExt = 8
    hdrLen += 8

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

  # Step 9: Rate control check (blob: call me_check_rc at 0x122)
  let staInfoForRate = desc.staInfoIdx
  me_check_rc(staInfoForRate)

  # Step 10: Update buffer control.
  # Blob ABI at 0x12a-0x138:
  #   lbu a4, 49(s0)            ; sta_info_idx
  #   li  a5, 368               ; STA_ENTRY_SIZE
  #   mv  a0, s4                ; s4 = sta_info_tab base
  #   .insn  (th.mula: a0 += a4*a5)   ; a0 = &sta_info_tab[sta_info_idx]
  #   call me_update_buffer_control
  #   sw  a0, 88(s0)             ; desc[88] = returned tx_policy pointer
  let txPolicyForPush = me_update_buffer_control(cast[pointer](staInfoForIdx(staInfoForRate)))

  # Step 11: Store result, clear flags, tail-call txl_cntrl_push
  desc.policy = txPolicyForPush
  if lmacGateHalfword(desc.frameLen) == 0x0800'u16:
    nimFwDbgDhcpTxPolicy = pointerAddrU32(txPolicyForPush)
    nimFwDbgDhcpTxBufDesc = pointerAddrU32(desc.bufDesc)
    nimFwDbgDhcpTxHwDesc = pointerAddrU32(desc.hwDesc)
  vif.psFlags = 0

  # Tail-call to txl_cntrl_push (blob: a0=desc, a1=ac; jr t1 at 0x162)
  discard txl_cntrl_push(param, ac)

proc txu_cntrl_cfm*(param: pointer) {.exportc, cdecl.} =
  ## Handle TX upper confirmation (11 instrs in blob).
  ## From disassembly: reads the THD chain pointer from the descriptor,
  ## sets the confirm-done bit (bit 0) in THD[16], writes 0x0101 to THD[12]
  ## (confirm type), clears the ke_msg linkage word at param[-4], then
  ## copies THD[16] to the confirm pointer at param[16].
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
  ## Checks key type at key[152]: type 1 = pairwise, type 3 = group.
  ## Sets up MIC context from key material (key+72 or key+48 area), computes
  ## MIC over frame header fields (SA, DA, priority) then frame body.
  ## Writes final 8-byte MIC at end of frame data.
  let desc = hostTxDescAt(txdesc)
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
  # Determine MIC key offset based on key type
  var micKeyOff: uint
  if keyType == 1:
    # Pairwise TKIP: MIC TX key at key+48+24 = key+72
    micKeyOff = 72
  elif keyType == 3:
    # Group TKIP: MIC TX key at key+48
    micKeyOff = 48
  else:
    return
  # Check if MIC calculation context already set up.
  let micArea = tkipMicKeyArea(key, micKeyOff)
  if micArea.scratch != nil:
    return  # MIC already in progress
  # Set up MIC context at linkDesc+316..348 area
  # Layout: [316]=magic(0xCAFEFADE), [320]=L_init, [324]=data_ptr, [328]=end_ptr, [332]=pending
  let scratch = addr link.micScratch
  micArea.scratch = cast[pointer](scratch)
  scratch.dataPtr = cast[pointer](addr scratch.data[0])
  if keyType == 1:
    scratch.endPtr = cast[pointer](addr scratch.data[3])
  else:
    scratch.endPtr = cast[pointer](addr scratch.data[11])
  scratch.magic = 0xCAFEFADE'u32
  scratch.pending = 0
  scratch.micLInit = 0
  if keyType == 1:
    # For pairwise: build MIC header from frame header addresses
    # Extract header fields for MIC init
    let priority = desc.staIdx
    let payloadLen = desc.qosExtLen
    # Get payload pointer from link descriptor
    # Initialize MIC: da (link+352), sa (link+358)
    var micCtx {.noinit.}: array[16, uint8]
    let micCtxPtr = cast[pointer](addr micCtx[0])
    let keyMaterial = cast[pointer](addr micArea.keyMaterial[0])
    me_mic_init(micCtxPtr, keyMaterial,
                cast[pointer](addr desc.sa[0]),
                cast[pointer](addr desc.da[0]),
                priority)
    # Pass 1: MIC over the pseudo-header fields (blob: me_mic_calc at 0xe0,
    # me_mic_end at 0xf4). TKIP MIC spec requires hashing DA||SA||priority||pad
    # as a separate stream so the end marker flushes the partial block.
    let hdrStart = cast[pointer](addr desc.da[0])
    me_mic_calc(micCtxPtr, hdrStart, 14.uint32)  # DA(6)+SA(6)+prio(1)+pad(1)
    me_mic_end(micCtxPtr)
    # Pass 2: MIC over frame body (blob: me_mic_calc at 0x12c, me_mic_end at 0x13e)
    let bodyStart = hostTxLinkMacHdrPtr(link, 26'u)  # skip MAC header
    let bodyLen = payloadLen
    me_mic_calc(micCtxPtr, bodyStart, bodyLen.uint32)
    # Finalize and write MIC
    me_mic_end(micCtxPtr)
    let micDst = cast[ptr UncheckedArray[uint8]](scratch)
    let micResult = cast[ptr UncheckedArray[uint8]](micCtxPtr)
    for i in 0 ..< 8:
      micDst[i] = micResult[i]
  # Group-key/other TKIP modes follow the reference path that only arms the
  # link descriptor scratch state above; no immediate software MIC is appended.
  return

proc txu_cntrl_protect_mgmt_frame*(param: pointer, hdrPtr: pointer, extraLen: uint32) {.exportc, cdecl.} =
  ## Apply management frame protection (108 bytes in blob).
  ## Blob: checks cached sechdr_len at param[98], computes if needed,
  ## sets Protected Frame bit (0x4000) in frame header, then appends security header.
  let desc = hostTxDescAt(param)
  var secHdrLen: uint8
  var secTailLen: uint8
  if desc.hdrLen == 0:
    # Not cached: compute security header length
    var tailLen: uint32 = 0
    secHdrLen = cast[uint8](txu_cntrl_sechdr_len_compute(param, addr tailLen))
    secTailLen = cast[uint8](tailLen)
    # Cache the results in descriptor
    desc.hdrLen = secHdrLen
    desc.secTailLen = secTailLen
  else:
    # Use cached values
    secHdrLen = desc.hdrLen
    secTailLen = desc.secTailLen
  # Set Protected Frame bit (0x4000) in the frame-control field.
  let fc = macFrameControlAt(hdrPtr)
  fc.frameControl = fc.frameControl or 0x4000'u16
  let hdrAddr = cast[uint](hdrPtr)
  # Compute position for security header: hdrPtr + extraLen + secHdrLen
  let secHdrPos = cast[pointer](hdrAddr + extraLen.uint + secHdrLen.uint)
  # Append security header (blob: txu_cntrl_sec_hdr_append(param, secHdrPos))
  discard txu_cntrl_sec_hdr_append(param, secHdrPos, 0'u32)

