# ###########################################################################
#                   TX LAYER (txl_*)
# ###########################################################################

proc captureDhcpTxRateRaw(rate: ptr HostTxRateTemplateView) =
  if rate == nil:
    return
  nimFwDbgDhcpTxRateRaw[0] = rate.magic
  nimFwDbgDhcpTxRateRaw[1] = rate.ntxConfig
  nimFwDbgDhcpTxRateRaw[2] = rate.bwMask
  nimFwDbgDhcpTxRateRaw[3] = rate.pendingCount
  nimFwDbgDhcpTxRateRaw[4] = rate.policyWord
  nimFwDbgDhcpTxRateRaw[5] = rate.rateWord
  nimFwDbgDhcpTxRateRaw[6] = rate.retryRateControl0
  nimFwDbgDhcpTxRateRaw[7] = rate.retryRateControl1
  nimFwDbgDhcpTxRateRaw[8] = rate.retryRateControl2
  nimFwDbgDhcpTxRateRaw[9] = cast[uint32](rate.txPower)
  nimFwDbgDhcpTxRateRaw[10] = rate.retryTxPowerControl0
  nimFwDbgDhcpTxRateRaw[11] = rate.retryTxPowerControl1
  nimFwDbgDhcpTxRateRaw[12] = rate.retryTxPowerControl2

# TX Buffer
proc txl_buffer_init*() {.exportc, cdecl.} =
  ## Initialize TX buffer control descriptors.
  ## Vendor initializes the exported 60-byte txl_buffer_control_desc arrays
  ## directly; STA entries point at these records through sta+320.
  txl_buffer_reinit()

  for staPolicySlotIndex in 0 ..< TX_BUFFER_POOL_SIZE:
    let staTxPolicyDesc = txBufferControlDescAt(staPolicySlotIndex)
    staTxPolicyDesc.magic = 0xBADCAB1E'u32
    staTxPolicyDesc.ntxConfig = phy_get_ntx().uint32 shl 14
    let ntxSpatialStreamCount = phy_get_ntx().uint32
    staTxPolicyDesc.bwMask = (1'u32 shl (ntxSpatialStreamCount + 1'u32)) - 1'u32
    staTxPolicyDesc.pendingCount = 0
    staTxPolicyDesc.policyWord = 0xFFFF0704'u32
    staTxPolicyDesc.rateWord = 0
    staTxPolicyDesc.retryRateControl0 = 0
    staTxPolicyDesc.retryRateControl1 = 0
    staTxPolicyDesc.retryRateControl2 = 0
    staTxPolicyDesc.txPower = cast[int32](regRead(MACHW_RNG_REG) and 0xFF'u32)
    staTxPolicyDesc.retryTxPowerControl0 = regRead(MACHW_RNG_REG) and 0xFF'u32
    staTxPolicyDesc.retryTxPowerControl1 = regRead(MACHW_RNG_REG) and 0xFF'u32
    staTxPolicyDesc.retryTxPowerControl2 = regRead(MACHW_RNG_REG) and 0xFF'u32
    staTxPolicyDesc.ackPolicyControl = 0x2200'u32
    staTxPolicyDesc.retryLimitControl = 0x003F0000'u32

  for bcmcPolicySlotIndex in 0 ..< 2:
    let bcmcTxPolicyDesc = txBufferControlBcmcDescAt(bcmcPolicySlotIndex)
    bcmcTxPolicyDesc.magic = 0xBADCAB1E'u32
    bcmcTxPolicyDesc.ntxConfig = phy_get_ntx().uint32 shl 14
    let ntxSpatialStreamCount = phy_get_ntx().uint32
    bcmcTxPolicyDesc.bwMask = (1'u32 shl (ntxSpatialStreamCount + 1'u32)) - 1'u32
    bcmcTxPolicyDesc.pendingCount = 0
    bcmcTxPolicyDesc.policyWord = 0xFFFF0704'u32
    bcmcTxPolicyDesc.rateWord = 0
    bcmcTxPolicyDesc.retryRateControl0 = 0
    bcmcTxPolicyDesc.retryRateControl1 = 0
    bcmcTxPolicyDesc.retryRateControl2 = 0
    bcmcTxPolicyDesc.txPower = cast[int32](regRead(MACHW_RNG_REG) and 0xFF'u32)
    bcmcTxPolicyDesc.retryTxPowerControl0 = 0
    bcmcTxPolicyDesc.retryTxPowerControl1 = 0
    bcmcTxPolicyDesc.retryTxPowerControl2 = 0
    bcmcTxPolicyDesc.ackPolicyControl = 0
    bcmcTxPolicyDesc.retryLimitControl = 0x003F0000'u32

proc txl_buffer_reinit*() {.exportc, cdecl.} =
  ## Reinitialize TX buffer pool indices (5 instrs).
  ## From blob: clears txl_buffer_env offsets 180/184, which are the first
  ## backup queue head/tail pointers in the exported buffer environment.
  txlBufferEnvView().backupQueues[0].first = nil
  txlBufferEnvView().backupQueues[0].last = nil

proc txl_buffer_reset*() {.exportc, cdecl, noinline.} =
  ## Reset TX buffer pool indices.
  txlBufferEnvView().backupQueues[0].first = nil
  txlBufferEnvView().backupQueues[0].last = nil

proc txlApplyEapolRetryPolicy(rate: ptr HostTxRateTemplateView) {.inline.} =
  ## Control-port frames must be ACKed before WPA can advance. The negotiated
  ## RC primary can select data rates that this AP will not ACK for EAPOL M2;
  ## use the same low basic-rate word that already works for management TX.
  when not defined(bl808WifiKeepEapolRcPrimary):
    rate.rateWord = 0x80000400'u32
  when defined(bl808WifiForceEapolPrimaryLegacy):
    rate.rateWord = 0x8000040A'u32
  rate.retryRateControl0 = 0x8000040A'u32
  rate.retryRateControl1 = 0x80001007'u32
  rate.retryRateControl2 = 0x80000400'u32
  rate.txPower = 0x00000070'i32
  rate.retryTxPowerControl0 = 0x00000070'u32
  rate.retryTxPowerControl1 = 0x00000070'u32
  rate.retryTxPowerControl2 = 0x00000070'u32

proc txlApplyBootstrapDataRetryPolicy(rate: ptr HostTxRateTemplateView) {.inline.} =
  ## Immediately after 4WHS the normal RC template can still pick a primary
  ## data rate that the AP does not ACK. Keep DHCP/ARP bootstrap traffic on the
  ## same conservative retry chain used for ACK-critical control-port frames.
  txlApplyEapolRetryPolicy(rate)

proc txl_buffer_alloc*(param: pointer, queueIdx: uint32, flags: uint32): pointer {.exportc, cdecl.} =
  ## Allocate a TX buffer descriptor. Blob ABI: a0=tx_desc, a1=queue idx, a2=user_idx.
  ##
  ## Algorithm (from blob, ~0x90 bytes):
  ##   hdrLen = desc[98]                                        (lbu)
  ##   desc[216] = align16(hdrLen) - hdrLen                     (pad length)
  ##   desc[212] = hdrLen
  ##   desc[460] = user_idx                                     (a2, byte)
  ##   desc[280] = 0xCAFEFADE                                   (magic)
  ##   bufPtr    = desc + 556 + hdrLen
  ##   txu_cntrl_frame_build(desc, bufPtr)                      ; builds 802.11 hdr
  ##   loop 15x { copy txdesc.umac.buf_control[1..15] }         ; buffer control
  ##   atomic link into txl_buffer_env free list (T-Head insns) ; buffer pool
  ##   link into txl_frame_env via frame+4 / frame+8 pointers   ; frame list
  ##   desc[224] = 0                                            ; pending flag
  ##   return desc + 208
  let desc = hostTxDescAt(param)
  let bufLink = hostTxInlineBufferedLink(desc)
  let hdrLen = desc.hdrLen
  let hdrLenU = hdrLen.uint32
  let padLen = ((hdrLenU + 15'u32) and not 15'u32) - hdrLenU

  # Metadata writes in the inline link descriptor at desc+208.
  bufLink.padLen = padLen
  bufLink.headerLen = hdrLenU

  # CAFEFADE magic at desc+280 (buffer validity check).
  const CAFEFADE = 0xCAFEFADE'u32
  bufLink.headerThd.magic = CAFEFADE

  bufLink.userIdx = cast[uint8](flags and 0xFF'u32)

  # Compute MAC header write point: bufPtr = desc + 556 + hdrLen.
  let bufPtr = hostTxLinkMacHdrPtr(bufLink, hdrLen.uint)

  # Build the 802.11 header inline at bufPtr.
  txu_cntrl_frame_build(param, bufPtr)

  # Copy the TX buffer control template. Vendor emits T-Head indexed load/store
  # opcodes here, equivalent to copying the 60-byte TxBufferControlView.
  let bufferControl = txBufferControlAt(desc.policy)
  let rateTemplate = hostTxRateTemplate(bufLink)
  discard c_memcpy(addr bufLink.rateTemplate[0], bufferControl,
                   sizeof(TxBufferControlView).csize_t)

  let protoTrace = desc.frameLen
  let protoFrameType = lmacGateHalfword(protoTrace)
  let isBootstrapData =
    protoFrameType == 0x0800'u16 or protoFrameType == 0x0806'u16
  if isBootstrapData:
    txlApplyBootstrapDataRetryPolicy(rateTemplate)
  if protoFrameType == 0x0800'u16:
    nimFwDbgDhcpTxPolicy = pointerAddrU32(desc.policy)
    nimFwDbgDhcpTxBufDesc = pointerAddrU32(cast[pointer](bufLink))
    nimFwDbgDhcpTxHwDesc = pointerAddrU32(desc.hwDesc)
    captureDhcpTxRateRaw(rateTemplate)
    nimFwDbgDhcpTxRate0 =
      rateTemplate.magic xor (rateTemplate.ntxConfig shl 16)
    nimFwDbgDhcpTxRate1 =
      rateTemplate.pendingCount xor (rateTemplate.policyWord shl 16)
    nimFwDbgDhcpTxRate2 =
      rateTemplate.rateWord xor (cast[uint32](rateTemplate.txPower) shl 16)
    nimFwDbgDhcpTxRate3 =
      rateTemplate.retryTxPowerControl0 xor (rateTemplate.retryTxPowerControl1 shl 16) xor
      rateTemplate.retryTxPowerControl2
    nimFwDbgDhcpTxLink0 = bufLink.ackPolicyControl
    nimFwDbgDhcpTxLink1 = bufLink.retryLimitControl
  let isEapol = protoTrace == 0x8E88'u16 or protoTrace == 0x888E'u16
  if isEapol:
    txlApplyEapolRetryPolicy(rateTemplate)
    nimFwDbgEapolTxPolicy = pointerAddrU32(desc.policy)
    nimFwDbgEapolTxBufDesc = pointerAddrU32(cast[pointer](bufLink))
    nimFwDbgEapolTxHwDesc = pointerAddrU32(desc.hwDesc)
    nimFwDbgEapolTxRate0 =
      rateTemplate.magic xor (rateTemplate.ntxConfig shl 16)
    nimFwDbgEapolTxRate1 =
      rateTemplate.pendingCount xor (rateTemplate.policyWord shl 16)
    nimFwDbgEapolTxRate2 =
      rateTemplate.rateWord xor (cast[uint32](rateTemplate.txPower) shl 16)
    nimFwDbgEapolTxRate3 =
      rateTemplate.retryRateControl0 xor (rateTemplate.retryRateControl1 shl 1) xor
      (rateTemplate.retryRateControl2 shl 2) xor (rateTemplate.retryTxPowerControl2 shl 16)
    nimFwDbgEapolTxLink0 = bufLink.ackPolicyControl
    nimFwDbgEapolTxLink1 = bufLink.retryLimitControl
  when defined(bl808WifiConnectTrace):
    if protoFrameType == 0x0800'u16 or protoFrameType == 0x0806'u16:
      nimFwConnectTrace2U32("[WIFI-CT] txbuf_data ",
                            protoFrameType.uint32 or
                              (queueIdx shl 16) or
                              (hdrLen.uint32 shl 24),
                            bufLink.headerThd.payloadStart)
      nimFwConnectTrace2U32("[WIFI-CT] txbuf_data2 ",
                            bufLink.headerThd.payloadEnd,
                            bufLink.headerThd.flags)
      nimFwConnectTraceBytes("[WIFI-RAW] tx_data ",
                             cast[pointer](addr bufLink.macHeader[0]),
                             hdrLen.uint32,
                             80)

  # Link into txl_buffer_env[queueIdx + 22], matching txl_int_fake_transfer.
  # dmaEntry = desc + 208 is both the return value and the node pushed.
  let dmaEntry = cast[uint](bufLink)
  if isEapol:
    nimFwTrace2U32("[WIFI-NIMFW] txbuf_eapol ",
                   queueIdx or (hdrLen.uint32 shl 8),
                   cast[uint32](dmaEntry))
    nimFwTrace2U32("[WIFI-NIMFW] txbuf_ctrl ",
                   cast[uint32](cast[uint](bufferControl)),
                   rateTemplate.magic)
    when defined(bl808WifiConnectTrace):
      if nimFwDbgEapolTraceCount < 64'u32:
        nimFwConnectTrace2U32("[WIFI-CT] txbuf_eapol ",
                              queueIdx or (hdrLen.uint32 shl 8) or
                                (padLen.uint32 shl 16),
                              cast[uint32](dmaEntry))
        nimFwConnectTrace2U32("[WIFI-CT] txbuf_ctrl ",
                              cast[uint32](cast[uint](bufferControl)),
                              rateTemplate.magic)
        nimFwConnectTrace2U32("[WIFI-CT] txbuf_pol0 ",
                              rateTemplate.ntxConfig,
                              rateTemplate.rateWord)
        nimFwConnectTrace2U32("[WIFI-CT] txbuf_pol1 ",
                              cast[uint32](rateTemplate.txPower),
                              rateTemplate.retryTxPowerControl2)
  let head = txBackupQueueHeadPtr(queueIdx)
  let tailPtr = txBackupQueueTailPtr(queueIdx)
  let listTail = head[]
  if listTail == nil:
    head[] = cast[pointer](bufLink)
  else:
    hostTxBufferedLinkAt(tailPtr[]).next = cast[pointer](bufLink)
  tailPtr[] = cast[pointer](bufLink)

  # Clear pending flag at desc+224.
  bufLink.next = nil

  # Return buffer control pointer.
  return cast[pointer](dmaEntry)

proc txl_buffer_update_thd*(param: pointer) {.exportc, cdecl.} =
  ## Update TX header descriptor chain from buffer pointer array.
  ## From disassembly (52 instrs): walks buffer pointers at param+52 (stride 4),
  ## creates THD entries at linkDesc+92 (stride 20) with cafefade magic,
  ## then sets up the main THD at linkDesc+72 pointing to the header buffer
  ## at linkDesc+348.
  let desc = hostTxDescAt(param)
  let linkDesc = hostTxLinkDescAt(desc.bufDesc)
  let hwDesc = hostTxHwDescAt(desc.hwDesc)
  var payloadThdCount = 0'u32
  var lastPayloadThdEntry: ptr HostTxThdEntryView = nil
  const CAFEFADE = 0xCAFEFADE'u32
  for payloadThdEntryIndex in 0 ..< desc.bufferPtrs.len:
    let payloadBufferStart = desc.bufferPtrs[payloadThdEntryIndex]
    if payloadBufferStart == 0:
      if payloadThdCount == 0:
        inc nimFwDbgTxThdNoBuffer
        nimFwDbgTxThdNoBufferDesc = pointerAddrU32(param)
        hwDesc.status = 0
        hwDesc.controlFlags = 0
        return
      break
    # Fill THD entry
    let payloadThdEntry = addr linkDesc.payloadThd[payloadThdEntryIndex]
    payloadThdEntry.magic = CAFEFADE
    payloadThdEntry.payloadStart = payloadBufferStart
    let payloadBufferLen = desc.bufferLens[payloadThdEntryIndex]
    payloadThdEntry.flags = 0
    payloadThdEntry.payloadEnd = payloadBufferStart + payloadBufferLen - 1
    lastPayloadThdEntry = payloadThdEntry
    payloadThdCount += 1
    if payloadThdEntryIndex + 1 < desc.bufferPtrs.len:
      payloadThdEntry.next = addr linkDesc.payloadThd[payloadThdEntryIndex + 1]
    else:
      payloadThdEntry.next = nil
  # Set up main THD at linkDesc+72
  let headerBuf = cast[uint32](cast[uint](addr linkDesc.macHeader[0]))
  linkDesc.headerThd.magic = CAFEFADE
  linkDesc.headerThd.next = addr linkDesc.payloadThd[0]
  linkDesc.headerThd.payloadStart = headerBuf
  linkDesc.headerThd.payloadEnd = headerBuf + linkDesc.headerLen - 1
  linkDesc.headerThd.flags = 0
  # Link hwDesc to main THD; finalize chain
  hwDesc.status = cast[uint32](cast[uint](addr linkDesc.headerThd))
  if lastPayloadThdEntry != nil:
    lastPayloadThdEntry.flags = 0
    lastPayloadThdEntry.next = nil
  hwDesc.controlFlags = 256
  let protoFrameType = lmacGateHalfword(desc.frameLen)
  if protoFrameType == 0x0800'u16:
    nimFwDbgDhcpTxThd0 =
      hwDesc.status xor (hwDesc.frameLen shl 16)
    nimFwDbgDhcpTxThd1 =
      hwDesc.retryLimitControl xor (pointerAddrU32(hwDesc.chainedThd) shl 16)
    nimFwDbgDhcpTxThd2 =
      hwDesc.ackPolicyControl xor (hwDesc.controlFlags shl 16)
  when defined(bl808WifiConnectTrace):
    if protoFrameType == 0x0800'u16 or protoFrameType == 0x0806'u16:
      let payload0 = addr linkDesc.payloadThd[0]
      nimFwConnectTrace2U32("[WIFI-CT] txthd_data ",
                            protoFrameType.uint32 or
                              (desc.hdrLen.uint32 shl 16) or
                              (desc.secTailLen.uint32 shl 24),
                            hwDesc.frameLen)
      nimFwConnectTrace2U32("[WIFI-CT] txthd_ptr ",
                            payload0.payloadStart,
                            payload0.payloadEnd)
      nimFwConnectTrace2U32("[WIFI-CT] txthd_buf ",
                            desc.bufferPtrs[0],
                            desc.bufferLens[0])
      if desc.bufferPtrs[0] != 0:
        nimFwConnectTraceBytes("[WIFI-RAW] tx_payload ",
                               cast[pointer](desc.bufferPtrs[0].uint),
                               desc.bufferLens[0],
                               384)

# TX Confirm
proc txl_cfm_init*() {.exportc, cdecl.} =
  ## Initialize TX confirmation module.
  ## Blob: memset(txl_cfm_env, 0, 40) + 5× co_list_init over the 40-byte
  ## env struct (each CoList is 8 bytes: first + last pointer).
  ## Unroll the 5-iteration loop explicitly — GCC -Os folded the previous
  ## loop into a single inlined co_list_init, losing the five blob-matching
  ## call sites.
  let cfmEnv = txCfmEnv()
  discard c_memset(cfmEnv, 0, sizeof(TxCfmEnvView).csize_t)
  co_list_init(addr cfmEnv.lists[0])
  co_list_init(addr cfmEnv.lists[1])
  co_list_init(addr cfmEnv.lists[2])
  co_list_init(addr cfmEnv.lists[3])
  co_list_init(addr cfmEnv.lists[4])

proc noteMgmtTxConfirm(desc: ptr HostTxDescView; status: uint32; phase: uint32) {.inline.} =
  if desc == nil or desc.bufDesc == nil or desc.hwDesc == nil:
    return
  let link = hostTxLinkDescAt(desc.bufDesc)
  let fc = link.macHeader[0].uint32 or (link.macHeader[1].uint32 shl 8)
  if fc != 0x00B0'u32 and fc != 0x0000'u32:
    return
  let hw = hostTxHwDescAt(desc.hwDesc)
  let meta =
    desc.frameLen.uint32 or
    (desc.staInfoIdx.uint32 shl 16) or
    (desc.vifIdx.uint32 shl 24) or
    (phase shl 28)
  if fc == 0x00B0'u32:
    case phase
    of 0'u32:
      inc nimFwDbgAuthCfmPush
    of 1'u32:
      inc nimFwDbgAuthCfmFrame
    of 2'u32:
      inc nimFwDbgAuthCfmEvt
    else:
      discard
    nimFwDbgAuthCfmStatus = status
    nimFwDbgAuthCfmHwStatus = hw.confirmStatus or (hw.status shl 16)
    nimFwDbgAuthCfmDesc = pointerAddrU32(cast[pointer](desc))
    nimFwDbgAuthCfmMeta = meta
    nimFwDbgAuthCfmFc = fc
  else:
    case phase
    of 0'u32:
      inc nimFwDbgAssocCfmPush
    of 1'u32:
      inc nimFwDbgAssocCfmFrame
    of 2'u32:
      inc nimFwDbgAssocCfmEvt
    else:
      discard
    nimFwDbgAssocCfmStatus = status
    nimFwDbgAssocCfmHwStatus = hw.confirmStatus or (hw.status shl 16)
    nimFwDbgAssocCfmDesc = pointerAddrU32(cast[pointer](desc))
    nimFwDbgAssocCfmMeta = meta
    nimFwDbgAssocCfmFc = fc

proc txl_cfm_push*(desc: pointer, status: uint32, acIdx: uint32) {.exportc, cdecl.} =
  ## Push a TX descriptor to confirmation queue.
  ## Blob ABI: a0=desc, a1=status, a2=ac_idx.
  ## Blob algorithm:
  ##   *(u32*)(*((u32*)(desc+112)) + 16) = a1  ; status -> hwdesc[16]
  ##   co_list_push_back(&txl_cfm_env, desc)
  ##   a2 = ac_idx
  ##   evt = txl_cfm_evt_bit[a2]
  ##   tail-call ke_evt_set(evt)
  ## Prior Nim bug: tail-called ipc_emb_tx_evt(ac_idx) — completely wrong
  ## target; the blob signals the KE scheduler, not the host IPC.
  inc nimFwDbgCfmPush
  let txDesc = hostTxDescAt(desc)
  noteMgmtTxConfirm(txDesc, status, 0'u32)
  let fenvPtr = txDesc.hwDesc
  var cfmHeadTrace = 0'u32
  if fenvPtr != nil:
    cfmHeadTrace = hostTxHwDescAt(fenvPtr).txConfirmDescPtr
  let traceBadCfm = cfmHeadTrace == 0xBADCAB1E'u32
  if nimFwDbgCfmTraceCount < 32'u32 or traceBadCfm:
    var thdStatusTrace = status
    if fenvPtr != nil:
      let thdBaseTrace = hostTxHeadThd(hostTxHwDescAt(fenvPtr))
      if thdBaseTrace != nil:
        thdStatusTrace = thdBaseTrace.flags
    nimFwTrace2U32("[WIFI-NIMFW] cfm_push ",
                   acIdx or (nimFwDbgCfmTraceCount shl 8),
                   pointerAddrU32(desc))
    nimFwTrace2U32("[WIFI-NIMFW] cfm_ptrs ",
                   cast[uint32](cast[uint](fenvPtr)),
                   cfmHeadTrace)
    nimFwTrace2U32("[WIFI-NIMFW] cfm_links ",
                   cast[uint32](cast[uint](txDesc.queueFirst)),
                   cast[uint32](cast[uint](txDesc.bufDesc)))
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] cfm_push ",
                            acIdx or (nimFwDbgCfmTraceCount shl 8),
                            pointerAddrU32(desc))
      nimFwConnectTrace2U32("[WIFI-CT] cfm_ptrs ",
                            cast[uint32](cast[uint](fenvPtr)),
                            cfmHeadTrace)
      nimFwConnectTrace2U32("[WIFI-CT] cfm_status ",
                            thdStatusTrace,
                            status)
      nimFwConnectTrace2U32("[WIFI-CT] cfm_links ",
                            cast[uint32](cast[uint](txDesc.queueFirst)),
                            cast[uint32](cast[uint](txDesc.bufDesc)))
    inc nimFwDbgCfmTraceCount
  if fenvPtr != nil:
    let hwdesc = hostTxHeadThd(hostTxHwDescAt(fenvPtr))
    if hwdesc != nil:
      hwdesc.flags = status
  # Blob indexes txl_cfm_env by AC before queueing the descriptor.
  co_list_push_back(txCfmList(acIdx), cast[ptr CoListHdr](desc))
  if acIdx < 5'u32:
    ke_evt_set(txl_cfm_evt_bit[acIdx])

proc txlCfmPending(acList: ptr CoList): bool {.inline.} =
  acList.first != nil

proc txl_cfm_evt*() {.exportc, cdecl.} =
  ## Process TX confirmation events (212 bytes in blob).
  ## Blob (txl_cfm.o): ke_evt_field[ac] lookup, assert event pending,
  ##   ke_evt_clear, then loop with IRQ-safe co_list_pop_front:
  ##   me_tx_cfm_singleton → txu_cntrl_cfm → txl_cntrl_env[80]-- → ipc_emb_txcfm
  ##   → ipc_emb_txcfm_ind (per-descriptor, inside loop).
  inc nimFwDbgCfmEvt
  var acIdx {.noinit.}: uint32
  {.emit: ["asm volatile(\"mv %0, a0\" : \"=r\"(", acIdx, ") );"].}

  let txCtrl = txControlEnv()

  # Compute event field for this AC (blob uses .LANCHOR0 = txl_cfm_evt_bit array).
  let evtField = if acIdx < 5'u32: txl_cfm_evt_bit[acIdx] else: 0'u32
  let acMask = 1'u32 shl acIdx

  # Assert event is pending (blob: ke_env[0] & evtField != 0)
  let keEvtBits = cast[ptr uint32](addr ke_env[0])[]
  if (keEvtBits and evtField) == 0:
    assert_err("txl_cfm.c", "txl_cfm.c", 346)

  # Clear the event (blob: ke_evt_clear with evtField, not acMask)
  ke_evt_clear(evtField)

  # Get per-AC confirmation list
  let acList = txCfmList(acIdx)
  var drained = 0'u32

  # Main loop: process a bounded batch of pending TX confirms for this AC.
  while drained < WifiTxCfmDrainLimit and txlCfmPending(acList):
    # IRQ-safe pop (blob: csrrci mstatus,8 / csrsi mstatus,8)
    let irqState = irqSave()
    let node = co_list_pop_front(acList)
    irqRestore(irqState)

    if node == nil:
      return

    let descTrace = hostTxDescAt(cast[pointer](node))
    let nodeU = cast[uint](descTrace)
    let fenvPtrTrace = descTrace.hwDesc
    var cfmHeadTrace = 0'u32
    if fenvPtrTrace != nil:
      cfmHeadTrace = hostTxHwDescAt(fenvPtrTrace).txConfirmDescPtr
    let traceBadCfm = cfmHeadTrace == 0xBADCAB1E'u32
    if nimFwDbgCfmTraceCount < 64'u32 or traceBadCfm:
      var thdStatusTrace = 0'u32
      if fenvPtrTrace != nil:
        let thdBaseTrace = hostTxHeadThd(hostTxHwDescAt(fenvPtrTrace))
        if thdBaseTrace != nil:
          thdStatusTrace = thdBaseTrace.flags
      nimFwTrace2U32("[WIFI-NIMFW] cfm_evt ",
                     acIdx or (nimFwDbgCfmTraceCount shl 8),
                     cast[uint32](nodeU))
      nimFwTrace2U32("[WIFI-NIMFW] cfm_evt_ptr ",
                     cast[uint32](cast[uint](fenvPtrTrace)),
                     cfmHeadTrace)
      nimFwTrace2U32("[WIFI-NIMFW] cfm_evt_lnk ",
                     cast[uint32](cast[uint](descTrace.queueFirst)),
                     cast[uint32](cast[uint](descTrace.bufDesc)))
      when defined(bl808WifiConnectTrace):
        nimFwConnectTrace2U32("[WIFI-CT] cfm_evt ",
                              acIdx or (nimFwDbgCfmTraceCount shl 8),
                              cast[uint32](nodeU))
        nimFwConnectTrace2U32("[WIFI-CT] cfm_evt_ptr ",
                              cast[uint32](cast[uint](fenvPtrTrace)),
                              cfmHeadTrace)
        nimFwConnectTrace2U32("[WIFI-CT] cfm_evt_status ",
                              thdStatusTrace,
                              cast[uint32](cast[uint](descTrace.cfmDst)))
        nimFwConnectTrace2U32("[WIFI-CT] cfm_evt_lnk ",
                              cast[uint32](cast[uint](descTrace.queueFirst)),
                              cast[uint32](cast[uint](descTrace.bufDesc)))
      inc nimFwDbgCfmTraceCount

    # Rate control update
    me_tx_cfm_singleton(cast[pointer](node))
    # Upper-MAC TX confirmation
    txu_cntrl_cfm(cast[pointer](node))
    # Decrement pending MPDU count (blob: txl_cntrl_env[80]--).
    txCtrl.packetCounter = txCtrl.packetCounter - 1
    # IPC TX confirm to host
    ipc_emb_txcfm(cast[pointer](node))
    # IPC confirm indication - called per descriptor inside loop (blob: 0xb4-0xbe)
    ipc_emb_txcfm_ind(acMask)
    inc drained

  if txlCfmPending(acList):
    inc nimFwDbgCfmEvtYield
    nimFwDbgCfmEvtYieldAc = acIdx
    ke_evt_set(evtField)

proc txl_cfm_flush*() {.exportc, cdecl, noinline.} =
  ## Flush all pending TX confirmations (190 bytes in blob).
  ## From blob: a0=ac_index, a1=cfm_list_ptr, a2=ac_mask.
  ## Iterates the cfm list (a1) via co_list_pop_front, for each descriptor:
  ##   1. Reads desc+112 (THD chain ptr) -> THD[0], desc+104 (DMA link)
  ##   2. If link != nil: write (0x3C000000 | ac_mask) to THD[16]
  ##   3. If link == nil: check THD[16]; if >= 0, write ac_mask to THD[16]
  ##   4. Check desc+8 (callback):
  ##      - If nil: call txl_frame_cfm(desc), continue loop
  ##      - If present: call txu_cntrl_cfm(desc), decrement txl_cntrl_env[80],
  ##        clear desc+108, increment count, call ipc_emb_txcfm(desc)
  ##   5. After loop: call txl_frame_evt()
  ##   6. If count > 0: tail-call ipc_emb_txcfm_ind(1 << ac)
  var acIdx {.noinit.}: uint32
  var cfmListPtr {.noinit.}: pointer
  var acMask {.noinit.}: uint32
  {.emit: ["asm volatile(\"mv %0, a0\" : \"=r\"(", acIdx, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", cfmListPtr, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a2\" : \"=r\"(", acMask, ") );"].}

  let cfmList = cast[ptr CoList](cfmListPtr)
  let txCtrl = txControlEnv()
  let forcedStatus = 0x3C000000'u32 or acMask
  var flushedHostConfirmCount: uint32 = 0

  while cfmList.first != nil:
    let node = co_list_pop_front(cfmList)
    if node == nil:
      break
    let txDesc = hostTxDescAt(cast[pointer](node))
    let thdChainPtr = txDesc.hwDesc
    let linkDesc = txDesc.dmaLink

    if thdChainPtr != nil:
      let thd = hostTxHeadThd(hostTxHwDescAt(thdChainPtr))
      if linkDesc != nil:
        # DMA owned: force confirm with 0x3C000000 | ac_mask
        thd.flags = forcedStatus
      elif cast[int32](thd.flags) >= 0:
        thd.flags = acMask

    # Check callback at desc+8
    if txDesc.queueFirst == nil:
      # No callback: call txl_frame_cfm and continue loop
      txl_frame_cfm(cast[pointer](node))
      continue

    # Have callback: process upper-layer confirm
    txu_cntrl_cfm(cast[pointer](node))
    # Decrement pending MPDU count (txl_cntrl_env[80]--).
    txCtrl.packetCounter = txCtrl.packetCounter - 1
    # Clear desc+108 buffer descriptor pointer.
    if txDesc.bufDesc != nil:
      txDesc.bufDesc = nil
    flushedHostConfirmCount += 1
    # IPC TX confirm to host
    ipc_emb_txcfm(cast[pointer](node))

  # After loop: signal frame event processing
  txl_frame_evt()
  # If any callbacks were processed, send IPC confirm indication
  if flushedHostConfirmCount > 0:
    ipc_emb_txcfm_ind(1'u32 shl acIdx)

proc txl_cfm_flush_desc*(desc: pointer) {.exportc, cdecl.} =
  ## Flush a specific TX confirmation descriptor (120 bytes in blob).
  ## From blob ABI: a0=ac_index, a1=desc_ptr, a2=status_override.
  ## Logic: reads desc+112 (THD chain) -> THD[0], desc+104 (DMA link).
  ## If link != nil (DMA owned): write (status_override | 0x3C000000) to THD[16].
  ## If link == nil: check THD[16]; if >= 0, write status_override to THD[16].
  ## Then checks desc+8 (callback):
  ##   - If nil: call txl_frame_cfm(desc), tail-call txl_frame_evt() (return 0)
  ##   - If present: call txu_cntrl_cfm(desc), decrement txl_cntrl_env[80],
  ##     clear desc+108, call ipc_emb_txcfm(desc), tail-call ipc_emb_txcfm_ind(1 << ac)
  var regA0 {.noinit.}: uint32
  var regA1 {.noinit.}: pointer
  var regA2 {.noinit.}: uint32
  {.emit: ["asm volatile(\"mv %0, a0\" : \"=r\"(", regA0, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", regA1, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a2\" : \"=r\"(", regA2, ") );"].}

  let ac = regA0
  let txDesc = hostTxDescAt(regA1)
  let status = regA2

  let thdChainPtr = txDesc.hwDesc
  let linkDesc = txDesc.dmaLink

  if thdChainPtr != nil:
    let thd = hostTxHeadThd(hostTxHwDescAt(thdChainPtr))
    if linkDesc != nil:
      # DMA owned: force confirm with status | 0x3C000000
      thd.flags = status or 0x3C000000'u32
    elif cast[int32](thd.flags) >= 0:
      # Not DMA owned: check if THD[16] is negative (bit 31 set)
      thd.flags = status

  # Check callback at desc+8
  if txDesc.queueFirst == nil:
    # No callback: call txl_frame_cfm then txl_frame_evt
    txl_frame_cfm(cast[pointer](txDesc))
    txl_frame_evt()
    return

  # Have callback: process upper-layer confirm
  txu_cntrl_cfm(cast[pointer](txDesc))
  # Decrement pending MPDU count (txl_cntrl_env[80]--)
  let txCtrl = txControlEnv()
  txCtrl.packetCounter = txCtrl.packetCounter - 1
  # Clear desc+108 buffer descriptor pointer.
  if txDesc.bufDesc != nil:
    txDesc.bufDesc = nil
  # IPC TX confirm to host
  ipc_emb_txcfm(cast[pointer](txDesc))
  # IPC confirm indication
  ipc_emb_txcfm_ind(1'u32 shl ac)

proc txl_cfm_dump*() {.exportc, cdecl, noinline.} =
  ## Dump TX confirmation queue for debugging.
  ## Blob algorithm (190 instrs):
  ##   - Log header line 570, 572, and (5 queues) 573.
  ##   - For i in 0..4:
  ##       cnt = co_list_cnt(&txl_cfm_env + 8*i)
  ##       head = txl_cfm_env[i*2]  (first of that CoList)
  ##       log line 577 with (i, head, cnt)
  ##       log separator line 581
  ##       if cnt != 0:
  ##         walk head: for each node call per-entry printFn:
  ##           printFn_ptr = node->112->16 (a2 arg); log line 589 with extra
  ##       log line 589 with 0 if empty
  ##   Key invariant: co_list_cnt must be invoked every iteration.
  let logFuncPtr = getLogFunc(204)
  if logFuncPtr == nil: return
  type LogFn = proc(level: uint32, sev: uint32, file: cstring, line: uint32) {.cdecl, varargs.}
  let logFn = cast[LogFn](logFuncPtr)
  # Headers
  logFn(2, 0, "txl_cfm.c", 570)
  logFn(2, 0, "txl_cfm.c", 572)
  logFn(2, 0, "txl_cfm.c", 573, 5'u32)
  for txConfirmQueueIndex in 0'u32 ..< 5'u32:
    let listPtr = txCfmList(txConfirmQueueIndex)
    let queuedConfirmCount = co_list_cnt(listPtr)
    let head = listPtr.first
    logFn(2, 0, "txl_cfm.c", 577, txConfirmQueueIndex, head, queuedConfirmCount)
    logFn(2, 0, "txl_cfm.c", 581)
    var node = head
    while node != nil:
      let desc = hostTxDescAt(cast[pointer](node))
      let hwDescPtr = desc.hwDesc
      let txHardwareStatus =
        if hwDescPtr != nil: hostTxHwDescAt(hwDescPtr).status else: 0'u32
      logFn(2, 0, "txl_cfm.c", 585, node, txHardwareStatus)
      node = node.next
    logFn(2, 0, "txl_cfm.c", 589)

proc txl_cfm_dma_int_handler_backup*() {.exportc, cdecl.} =
  ## Backup DMA interrupt handler for TX confirm.
  ## From disassembly: clears bit 0 of txl_cfm_env[1] (status flags word at offset 4).
  txl_cfm_env[1] = txl_cfm_env[1] and not 1'u32

# TX Control
proc txl_cntrl_init*() {.exportc, cdecl.} =
  ## Initialize TX control module.
  ## From disassembly: calls txl_buffer_init, txl_cfm_init, txl_frame_init,
  ## txl_hwdesc_init(0), then memset(txl_cntrl_env, 0, 92).
  ## Loops over 5 AC entries (stride 16), for each:
  ##   - co_list_init on the pending frame list (offset 4)
  ##   - Clear first descriptor pointer (offset 0)
  ##   - Store MAC HW descriptor address at offset 12 (half-word)
  ##   - Clear busy flag at offset 14 (byte)
  ## Finally clears the global txlCntrlBusy flag.
  # Blob order: txl_hwdesc_init FIRST, then buffer/cfm/frame
  txl_hwdesc_init()
  txl_buffer_init()
  txl_cfm_init()
  txl_frame_init()
  let txCtrl = txControlEnv()
  discard c_memset(txCtrl, 0, 92.csize_t)
  for ac in 0'u32 ..< NUM_TX_QUEUES.uint32:
    let acCtrl = txControlAc(ac)
    # co_list_init on the list at offset 4
    co_list_init(addr acCtrl.pending)
    # Clear first descriptor pointer
    acCtrl.current = nil
    acCtrl.packetCount = ipcTxHwDescWordAddrHalfword(ac)
    # Clear busy flag
    acCtrl.busyFlag = 0
  # Clear global busy flag
  txlCntrlBusy = 0
  # Also update convenience arrays
  for accessCategoryIndex in 0 ..< NUM_TX_QUEUES:
    txlAcPending[accessCategoryIndex] = 0
    txlAcBusy[accessCategoryIndex] = false

proc txl_cntrl_tx_check*(vifEntry: pointer): bool {.exportc, cdecl.} =
  ## Check whether TX should be admitted right now.
  ## Blob algorithm:
  ##   a5 = *(u8*)(txl_cntrl_env+0x58)    ; halted-for-all-AC flag
  ##   if (a5 != 0) return 0
  ##   tail-call chan_is_tx_allowed(vifEntry)
  ## Prior Nim bug: walked txlAcPending counters (always return true if any
  ## AC queued), which has the opposite sense (admits when halted).
  if txControlEnv().resetInProgress != 0:
    return false
  return chan_is_tx_allowed(vifEntry)

proc txl_cntrl_push*(param: pointer, ac: uint8): uint8 {.exportc, cdecl.} =
  ## Push a frame descriptor to the TX control queue (224 bytes in blob).
  ## Blob call sequence: THD setup → IRQ save → check desc[8]:
  ##   if nil: txl_int_fake_transfer
  ##   if non-nil: txl_buffer_alloc + txl_buffer_update_thd
  ## → txl_payload_handle_backup → co_list_push_back → IRQ restore
  ## → increment pkt count → td_pck_ind → ps_check_tx_frame → return 0
  let desc = hostTxDescAt(param)
  # Read frame fields for THD setup (blob at 0x0a-0x14)
  let secTailLen = desc.secTailLen
  let hdrLen = desc.hdrLen
  let thd = hostTxHwDescAt(desc.hwDesc)
  let halfLen = desc.seqPassthrough
  let totalLen = secTailLen.uint32 + hdrLen.uint32 + halfLen.uint32 + 4
  # Initialize THD fields (blob at 0x1e-0x4e)
  thd.secondaryDescToStatusPadding = 0
  thd.frameLen = totalLen
  thd.magic = 0xCAFEBABE'u32
  thd.secondaryTxHwDescPtr = 0
  thd.status = 0
  thd.chainedThd = nil
  thd.controlFlags = 0
  thd.payloadStart = 0
  thd.payloadEnd = 0
  thd.frameLenToRetryLimitPadding = 0
  thd.confirmStatus = 0
  # IRQ save (blob: csrrci s2,mstatus,8 at 0x52)
  let saved = irqSave()
  # Check desc[8] for existing queue chain (blob at 0x56)
  let queueFirst = desc.queueFirst
  let protoTrace = desc.frameLen
  if protoTrace == 0x8E88'u16 or protoTrace == 0x888E'u16:
    nimFwTrace2U32("[WIFI-NIMFW] txl_push_eapol ",
                   ac.uint32 or (desc.staIdx.uint32 shl 8) or
                     (desc.vifIdx.uint32 shl 16) or
                     (desc.staInfoIdx.uint32 shl 24),
                   cast[uint32](cast[uint](queueFirst)))
  if queueFirst == nil:
    # Empty queue: fake transfer (blob: txl_int_fake_transfer at 0x5e)
    txl_int_fake_transfer(param, ac.uint32)
  else:
    # Queue exists: allocate buffer and update THD (blob: .L119 at 0xc6)
    let bufDesc = txl_buffer_alloc(param, ac.uint32, 0'u32)
    desc.bufDesc = bufDesc
    if bufDesc != nil:
      hostTxBufferedLinkAt(bufDesc).txDesc = param
    txl_buffer_update_thd(param)
  # Handle payload backup (blob: txl_payload_handle_backup at 0x66)
  txl_payload_handle_backup(nil)
  # Add to per-AC pending list (blob: co_list_push_back at 0x80)
  co_list_push_back(addr txControlAc(ac.uint32).pending, cast[ptr CoListHdr](param))
  # IRQ restore (blob at 0x88-0x8c)
  irqRestore(saved)
  # Increment packet counter (blob at 0x90-0x96)
  let txCtrl = txControlEnv()
  txCtrl.packetCounter = txCtrl.packetCounter + 1
  # Traffic detection indication (blob: td_pck_ind(desc[47], desc[49], 0) at 0xa0)
  let vifIdx = desc.vifIdx
  let staIdx = desc.staInfoIdx
  td_pck_ind(vifIdx, staIdx.uint32)
  # Power save check (blob: ps_check_tx_frame(desc[49], desc[46]) at 0xb0)
  let psArg = desc.staIdx
  discard ps_check_tx_frame(staIdx, psArg)
  return 0'u8

proc txl_cntrl_push_int*(param: pointer, ac: uint8): uint8 {.exportc, cdecl.} =
  ## Push an internal frame to TX control (92 instrs / 0x116 bytes in blob).
  ## Blob call graph: txl_cntrl_tx_check, apm_tx_int_ps_check,
  ##   txl_int_fake_transfer, co_list_push_back(x2), txl_payload_handle_backup,
  ##   txl_frame_release, apm_tx_int_ps_postpone.
  let desc = hostTxDescAt(param)
  inc nimFwDbgTxIntEnter
  let rcStatsPtr = desc.hwDesc
  let txCtrl = txControlEnv()
  let linkPtrTrace = desc.bufDesc
  let fcTrace =
    if linkPtrTrace != nil: hostTxLinkDescAt(linkPtrTrace).macHeader[0]
    else: 0'u8
  nimFwDbgTxIntLastCb = cast[uint32](cast[uint](desc.callback))
  if linkPtrTrace != nil:
    let linkTrace = hostTxLinkDescAt(linkPtrTrace)
    nimFwDbgTxIntLastFc =
      linkTrace.macHeader[0].uint32 or (linkTrace.macHeader[1].uint32 shl 8)
  let isNullDataFrame =
    linkPtrTrace != nil and hostTxLinkDescAt(linkPtrTrace).macHeader[0] == 0x48'u8 and
      hostTxLinkDescAt(linkPtrTrace).macHeader[1] == 0x01'u8
  let isTrackedByCallback =
    desc.callback != nil and
    cast[uint32](cast[uint](desc.callback)) == nimFwDbgNullFrameCbSetPtr
  let isTrackedNullFrame = isNullDataFrame or isTrackedByCallback
  if isTrackedNullFrame:
    inc nimFwDbgNullFrameTxIntSeen
    nimFwDbgNullFrameTxIntBuf = pointerAddrU32(linkPtrTrace)
    if linkPtrTrace != nil:
      let link = hostTxLinkDescAt(linkPtrTrace)
      nimFwDbgNullFrameTxIntFc =
        link.macHeader[0].uint32 or (link.macHeader[1].uint32 shl 8)
  let traceMgmt = linkPtrTrace != nil and nimFwMgmtFcTrace(fcTrace)

  # Step 1: Check TX readiness (blob computes VIF from desc[47], then calls txl_cntrl_tx_check)
  let vifIdxTx = desc.vifIdx
  let vifTx = vifChannelForIdx(vifIdxTx)
  let vifEntryTx = cast[pointer](vifTx)
  let txReady = txl_cntrl_tx_check(vifEntryTx)
  let chanEnvForDiag = chanEnvView()
  nimFwDbgTxIntLastMeta =
    ac.uint32 or (vifIdxTx.uint32 shl 8) or
    (desc.staIdx.uint32 shl 16) or (desc.staInfoIdx.uint32 shl 24)
  nimFwDbgTxIntLastChan =
    txReady.uint32 or
    (chan_is_on_channel(vifEntryTx).uint32 shl 8) or
    (chanEnvForDiag.flags.uint32 shl 16) or
    (chanEnvForDiag.ctxtCount.uint32 shl 24)
  nimFwDbgTxIntLastQueue =
    pointerAddrU32(cast[pointer](txControlAc(ac.uint32).pending.first))
  nimFwDbgTxIntLastHw = pointerAddrU32(desc.hwDesc)
  if traceMgmt:
    nimFwTrace2U32("[WIFI-NIMFW] txint_enter ",
                   ac.uint32 or (vifIdxTx.uint32 shl 8) or
                     (desc.staInfoIdx.uint32 shl 16),
                   pointerAddrU32(param))
    let chanEnvTrace = chanEnvView()
    let curCtxtTrace = chanEnvTrace.currentCtxt
    let schedCtxtTrace = chanEnvTrace.scheduledCtxt
    let vifCtxtTrace = vifTx.chanCtxt
    let flagsTrace = chanEnvTrace.flags
    let cntTrace = chanEnvTrace.ctxtCount
    let onChanTrace = chan_is_on_channel(vifEntryTx)
    var currentContextStatusTrace = 0'u8
    var currentContextIndexTrace = 0'u8
    var currentContextAltIndexTrace = 0'u8
    if curCtxtTrace != nil:
      let curTrace = chanCtxtAt(curCtxtTrace)
      currentContextStatusTrace = curTrace.status
      currentContextIndexTrace = curTrace.contextIndexOrMarker
      currentContextAltIndexTrace = curTrace.altIdx
    nimFwTrace2U32("[WIFI-NIMFW] txint_chan ",
                   txReady.uint32 or (onChanTrace.uint32 shl 8) or
                     (flagsTrace.uint32 shl 16) or (cntTrace.uint32 shl 24),
                   currentContextStatusTrace.uint32 or
                     (currentContextIndexTrace.uint32 shl 8) or
                     (currentContextAltIndexTrace.uint32 shl 16) or
                     (vifChannelAt(vifEntryTx).vifIdx.uint32 shl 24))
    nimFwTrace2U32("[WIFI-NIMFW] txint_ptrs ",
                   cast[uint32](cast[uint](curCtxtTrace)),
                   cast[uint32](cast[uint](schedCtxtTrace)))
    nimFwTrace2U32("[WIFI-NIMFW] txint_vifct ",
                   cast[uint32](cast[uint](vifEntryTx)),
                   cast[uint32](cast[uint](vifCtxtTrace)))
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] txint_enter ",
                            ac.uint32 or (vifIdxTx.uint32 shl 8) or
                              (desc.staInfoIdx.uint32 shl 16),
                            txReady.uint32 or (onChanTrace.uint32 shl 8) or
                              (flagsTrace.uint32 shl 16) or (cntTrace.uint32 shl 24))
      let linkRawTrace = hostTxLinkDescAt(linkPtrTrace)
      nimFwConnectTraceBytes("[WIFI-RAW] tx_mgt ",
                             cast[pointer](addr linkRawTrace.macHeader[0]),
                             hostTxHwDescAt(desc.hwDesc).frameLen,
                             96)
      nimFwConnectTrace2U32("[WIFI-CT] txint_ctxt ",
                            cast[uint32](cast[uint](curCtxtTrace)),
                            cast[uint32](cast[uint](vifCtxtTrace)))
  if txReady:
    inc nimFwDbgTxIntReady
    # TX allowed: check AP PS state
    # Step 2: apm_tx_int_ps_check (blob 0x50)
    let psOk = apm_tx_int_ps_check(param)
    if psOk:
      inc nimFwDbgTxIntPsOk
    if traceMgmt:
      let chanEnv = chanEnvView()
      let curCtxt = chanEnv.currentCtxt
      let pendCtxt = chanEnv.scheduledCtxt
      nimFwTrace2U32("[WIFI-NIMFW] txint_ready ",
                     txReady.uint32 or (psOk.uint32 shl 8),
                     cast[uint32](cast[uint](curCtxt) xor cast[uint](pendCtxt)))
      when defined(bl808WifiConnectTrace):
        nimFwConnectTrace2U32("[WIFI-CT] txint_ready ",
                              txReady.uint32 or (psOk.uint32 shl 8),
                              cast[uint32](cast[uint](curCtxt) xor cast[uint](pendCtxt)))
    if psOk:
      # Success path: set rcStats flag, DMA transfer, push to queue
      if rcStatsPtr != nil:
        let rcStats = hostTxHwDescAt(rcStatsPtr)
        rcStats.controlFlags = rcStats.controlFlags or 0x100

      # IRQ-safe: fake transfer + push to AC queue
      let saved = irqSave()
      txl_int_fake_transfer(param, ac.uint32)
      co_list_push_back(addr txControlAc(ac.uint32).pending, cast[ptr CoListHdr](param))
      irqRestore(saved)

      # Increment packet counter
      txCtrl.packetCounter = txCtrl.packetCounter + 1

      # Payload backup (blob 0xA4)
      txl_payload_handle_backup(param)
      if traceMgmt:
        nimFwTrace2U32("[WIFI-NIMFW] txint_push ",
                       txCtrl.packetCounter,
                       cast[uint32](cast[uint](desc.hwDesc)))
        when defined(bl808WifiConnectTrace):
          nimFwConnectTrace2U32("[WIFI-CT] txint_push ",
                                txCtrl.packetCounter,
                                cast[uint32](cast[uint](desc.hwDesc)))
      if isTrackedNullFrame:
        inc nimFwDbgNullFrameQueued
      inc nimFwDbgTxIntPush
      return 1'u8
    # PS check failed: fall through to the not-ready/postpone path.

  # Not-ready path (L103): check STA for off-channel deferral
  let staInstNbr = desc.staInfoIdx
  if staInstNbr == 0xFF:
    inc nimFwDbgTxIntRelease
    if traceMgmt:
      nimFwTrace2U32("[WIFI-NIMFW] txint_release ",
                     txReady.uint32, staInstNbr.uint32)
      when defined(bl808WifiConnectTrace):
        nimFwConnectTrace2U32("[WIFI-CT] txint_release ",
                              txReady.uint32, staInstNbr.uint32)
    # No STA: release frame (blob: txl_frame_release at 0x42)
    # Blob: a0=param, a1=0 (no callback). txl_frame_release reads a1 via asm.
    {.emit: ["asm volatile(\"mv a1, zero\" ::: \"a1\");"].}
    txl_frame_release(param)
    return 0'u8

  # STA exists: defer TX to off-channel path
  desc.postponeFlag = 1
  if isTrackedNullFrame:
    inc nimFwDbgNullFramePostponed
  inc nimFwDbgTxIntPostpone
  desc.staIdx = ac
  let sta = staInfoForIdx(staInstNbr)
  let staEntry = cast[pointer](sta)
  if traceMgmt:
    nimFwTrace2U32("[WIFI-NIMFW] txint_postpone ",
                   txReady.uint32 or (staInstNbr.uint32 shl 8),
                   pointerAddrU32(staEntry))
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] txint_postpone ",
                            txReady.uint32 or (staInstNbr.uint32 shl 8),
                            pointerAddrU32(staEntry))
  # Store MAC time if not already pending
  if desc.pendingMacTime == 0:
    desc.pendingMacTime = macTimeNow()
  # Push to STA pending list (blob: co_list_push_back at 0xE2)
  co_list_push_back(addr sta.postponedList, cast[ptr CoListHdr](param))
  # Notify PS postpone (blob: apm_tx_int_ps_postpone at 0xEE)
  apm_tx_int_ps_postpone(param, staEntry)
  # Increment frame env counter
  let frameEnv = txFrameEnv()
  frameEnv.postponedCount = frameEnv.postponedCount + 1
  return 1'u8

proc txl_cntrl_push_int_force*(param: pointer, ac: uint8): uint8 {.exportc, cdecl.} =
  ## Force push an internal frame to TX control (106 bytes in blob).
  ## Blob: set rcStats[60]|=0x100, irqSave, txl_int_fake_transfer,
  ## co_list_push_back, irqRestore, increment pktCnt, txl_payload_handle_backup.
  # Read RC stats from param[112] and set pending flag
  let rcStats = hostTxHwDescAt(hostTxDescAt(param).hwDesc)
  rcStats.controlFlags = rcStats.controlFlags or 0x100
  # IRQ save
  let saved = irqSave()
  # Fake DMA transfer setup (blob: txl_int_fake_transfer at 0x20)
  txl_int_fake_transfer(param, ac.uint32)
  # Push to AC queue
  co_list_push_back(addr txControlAc(ac.uint32).pending, cast[ptr CoListHdr](param))
  # IRQ restore
  irqRestore(saved)
  # Increment packet counter
  let txCtrl = txControlEnv()
  txCtrl.packetCounter = txCtrl.packetCounter + 1
  # Handle TX backup/scheduling (blob: txl_payload_handle_backup at 0x52)
  txl_payload_handle_backup(param)
  return 1'u8

proc txl_cntrl_halt_ac*(ac: uint8) {.exportc, cdecl.} =
  ## Halt TX for a specific access category by writing to MAC HW TX trigger
  ## register (0x24B08180) with an AC-specific bitmask, then polling the
  ## status register (0x24B08188) until the AC's bits clear, and finally
  ## writing the clear bitmask to the clear register (0x24B08184).
  ## From disassembly (65 instrs).
  const
    MACHW_TX_TRIG_SET  = 0x24B08180'u  # TX trigger set register
    MACHW_TX_TRIG_STAT = 0x24B08188'u  # TX trigger status register
    MACHW_TX_TRIG_CLR  = 0x24B08184'u  # TX trigger clear register
  var setBit: uint32
  var clearMask: uint32
  case ac
  of 0:  # BK
    setBit = 0x10000'u32     # bit 16
    regWrite(MACHW_TX_TRIG_SET, setBit)
    discard waitRegMaskClear(MACHW_TX_TRIG_STAT, 0x10000'u32)
    clearMask = 0x10000'u32
  of 1:  # BE
    setBit = 0x20000'u32     # bit 17
    regWrite(MACHW_TX_TRIG_SET, setBit)
    discard waitRegMaskClear(MACHW_TX_TRIG_STAT, 0x20000'u32)
    clearMask = 0x20000'u32
  of 2:  # VI
    setBit = 0x40000'u32     # bit 18
    regWrite(MACHW_TX_TRIG_SET, setBit)
    discard waitRegMaskClear(MACHW_TX_TRIG_STAT, 0x40000'u32)
    clearMask = 0x40000'u32
  of 3:  # VO
    setBit = 0x80000'u32     # bit 19
    regWrite(MACHW_TX_TRIG_SET, setBit)
    discard waitRegMaskClear(MACHW_TX_TRIG_STAT, 0x80000'u32)
    clearMask = 0x80000'u32
  of 4:  # BCN
    setBit = 0x8000'u32      # bit 15
    regWrite(MACHW_TX_TRIG_SET, setBit)
    discard waitRegMaskClear(MACHW_TX_TRIG_STAT, 0x03'u32)
    clearMask = 0x8000'u32
  else:
    assert_err("txl_cntrl.c", "txl_cntrl.c", 0x700)
    return
  regWrite(MACHW_TX_TRIG_CLR, clearMask)

proc txl_cntrl_flush_ac*(ac: uint8) {.exportc, cdecl.} =
  ## Flush TX queue for a specific AC (44 instrs in blob).
  ## From blob: reads MACHW active AC register (0x24B0808C), computes 1<<ac bitmask,
  ## then calls txl_cfm_flush twice (per-AC txl_cfm_env + txl_cntrl_env lists),
  ## then txl_buffer_reset. Finally clears the AC bit in active register and sets
  ## the AC mask register (offset 0x88).
  let saved = irqSave()
  let acMask = 1'u32 shl ac
  let acList = cast[pointer](addr txControlAc(ac.uint32).pending)
  let globalCfm = cast[pointer](txCfmList(ac.uint32))
  # First flush: per-AC txl_cfm_env list.
  # Blob passes args via registers: a0=ac, a1=list, a2=acMask.
  {.emit: ["""
  {
    register unsigned int _a0 __asm__("a0") = (unsigned int)""", ac, """;
    register unsigned int _a1 __asm__("a1") = (unsigned int)""", globalCfm, """;
    register unsigned int _a2 __asm__("a2") = (unsigned int)""", acMask, """;
    __asm__ volatile("" : : "r"(_a0), "r"(_a1), "r"(_a2));
    txl_cfm_flush();
  }
  """].}
  # Second flush: per-AC list at txl_cntrl_env[ac*16+4].
  {.emit: ["""
  {
    register unsigned int _a0 __asm__("a0") = (unsigned int)""", ac, """;
    register unsigned int _a1 __asm__("a1") = (unsigned int)""", acList, """;
    register unsigned int _a2 __asm__("a2") = (unsigned int)""", acMask, """;
    __asm__ volatile("" : : "r"(_a0), "r"(_a1), "r"(_a2));
    txl_cfm_flush();
  }
  """].}
  # Reset TX buffer pool (blob: txl_buffer_reset with a0=ac).
  {.emit: ["""
  {
    register unsigned int _a0 __asm__("a0") = (unsigned int)""", ac, """;
    __asm__ volatile("" : : "r"(_a0));
    txl_buffer_reset();
  }
  """].}
  # Clear AC active bits in MACHW registers
  let activeAcReg = MACHW_INTC_BASE + 0x08C'u  # active AC bitmask register
  let setAcReg = MACHW_INTC_BASE + 0x088'u     # AC mask set register
  let curActive = regRead(activeAcReg)
  regWrite(activeAcReg, curActive and (not acMask))
  regWrite(setAcReg, acMask)
  irqRestore(saved)

proc txl_cntrl_clear_ac*(ac: uint8) {.exportc, cdecl.} =
  ## Clear TX queue for a specific AC.
  ## Blob (18 instrs): saves IRQ state (csrrci mstatus,8), calls
  ## txl_cntrl_halt_ac(ac), then txl_cntrl_flush_ac(ac), restores IRQ state.
  let saved = irqSave()
  txl_cntrl_halt_ac(ac)
  txl_cntrl_flush_ac(ac)
  irqRestore(saved)
  if ac < NUM_TX_QUEUES.uint8:
    txlAcPending[ac] = 0
    txlAcBusy[ac] = false

proc txl_cntrl_clear_bcn_ac*() {.exportc, cdecl.} =
  ## Clear beacon TX queue (18 instrs in blob).
  ## From blob: saves IRQ state (csrrci mstatus,8), calls txl_cntrl_halt_ac(4),
  ## then txl_cntrl_flush_ac(4) with 0x40000000 bitmask, restores IRQ state.
  let saved = irqSave()
  txl_cntrl_halt_ac(4)
  txl_cntrl_flush_ac(4)
  irqRestore(saved)

proc txl_cntrl_clear_all_ac*() {.exportc, cdecl.} =
  ## Clear all TX queues.
  ## From disassembly (46 instrs): saves IRQ state, then for each AC (4,0,1,2,3)
  ## calls txl_cntrl_halt_ac to stop MAC HW TX, then txl_cntrl_flush_ac to
  ## flush pending descriptors. Finally restores IRQ state.
  let saved = irqSave()
  # BCN queue first (AC 4), then data queues 0..3
  txl_cntrl_halt_ac(4)
  txl_cntrl_flush_ac(4)
  txl_cntrl_halt_ac(0)
  txl_cntrl_flush_ac(0)
  txl_cntrl_halt_ac(1)
  txl_cntrl_flush_ac(1)
  txl_cntrl_halt_ac(2)
  txl_cntrl_flush_ac(2)
  txl_cntrl_halt_ac(3)
  txl_cntrl_flush_ac(3)
  irqRestore(saved)

proc txl_cntrl_inc_pck_cnt*(ac: uint8) {.exportc, cdecl.} =
  ## Increment packet count for an AC.
  ## From blob (5 instrs): loads txl_cntrl_env word at offset 80 (packet count),
  ## increments by 1, stores back. AC arg is unused (global counter).
  let env = txControlEnv()
  env.packetCounter = env.packetCounter + 1

proc txl_cntrl_env_dump*() {.exportc, cdecl, noinline.} =
  ## Dump TX control environment for debugging.
  ## From disassembly (265 instrs): iterates over 5 AC entries (stride 16) in
  ## txl_cntrl_env, calling the platform log function (g_bl_ops_funcs[204]) to
  ## print per-AC state: first descriptor pointer, list head, busy flag, HW
  ## descriptor address, and pending frame chain details including THD info.
  ##
  ## Register map: s0=g_bl_ops_funcs s4=per-AC base (stride 16)
  ##   s5=ac index  s2=format string  s3=list first ptr  s9=list head result
  ##   s7=THD pointer from desc[112]+40
  ##
  ## The function is purely diagnostic. It reads txl_cntrl_env per-AC structures
  ## and walks linked lists, printing frame descriptors and THD (Transmit Header
  ## Descriptor) fields via the log function.
  ## The blob calls g_bl_ops_funcs[204] (log function) with varying numbers
  ## of arguments (printf-style variadic). We use emit for the variadic calls.
  let logFuncPtr = getLogFunc(204)
  if logFuncPtr == nil: return

  # Helper: call the platform log function with printf-style variadic args.
  # The blob signature is: void log(int level, int sev, const char *file,
  #   int line, const char *fmt, ...);
  # We use a simple 2-arg form for most calls (level=2, sev=0, fmt, line).
  type LogFn2 = proc(level: uint32, sev: uint32, file: cstring, line: uint32) {.cdecl.}
  type LogFn5 = proc(level: uint32, sev: uint32, file: cstring, line: uint32,
                     fmt: cstring, a0: uint32) {.cdecl.}
  type LogFn7 = proc(level: uint32, sev: uint32, file: cstring, line: uint32,
                     fmt: cstring, a0: uint32, a1: uint32, a2: uint32) {.cdecl.}

  let logFn = cast[LogFn2](logFuncPtr)
  let logFn5 = cast[LogFn5](logFuncPtr)
  let logFn7 = cast[LogFn7](logFuncPtr)
  let printFn = blOpsFunc(4)

  # Print header
  logFn(2, 0, "txl_cntrl.c", 0x925)

  for ac in 0'u32 ..< NUM_TX_QUEUES.uint32:
    let acCtrl = txControlAc(ac)
    let listFirst = cast[pointer](acCtrl.pending.first)

    # Blob: s4 = &txl_cntrl_env+4+16*ac (the CoList in that AC slot).
    # At .L167 blob calls co_list_cnt(s4) and feeds result to log.
    let listCnt = co_list_cnt(addr acCtrl.pending)

    # Log per-AC summary (line 0x92C) with (ac, head, cnt)
    logFn7(2, 0, "txl_cntrl.c", 0x92C, "AC", ac,
           cast[uint32](cast[uint](listFirst)), listCnt)

    # Log separator for empty list (blob: line 0x931)
    logFn(2, 0, "txl_cntrl.c", 0x931)

    # Walk descriptor chain (L162 in blob: while s3 != nil)
    var curDesc = listFirst
    while curDesc != nil:
      let desc = hostTxDescAt(curDesc)
      # Print descriptor address and its status (blob: L165)
      let thd = desc.hwDesc
      if thd != nil:
        let hw = hostTxHwDescAt(thd)
        let thdStatus = hw.confirmStatus
        logFn7(2, 0, "txl_cntrl.c", 0x8EF, "thd",
               cast[uint32](thd), thdStatus, cast[uint32](curDesc))
      curDesc = desc.link.next  # next in list

    # Log separator after list walk (blob: line 0x939)
    logFn(2, 0, "txl_cntrl.c", 0x939)

    # Walk the same list again for detailed THD sub-fields (L169/L174)
    curDesc = listFirst
    while curDesc != nil:
      let desc = hostTxDescAt(curDesc)
      let thd = desc.hwDesc
      if thd != nil:
        let hw = hostTxHwDescAt(thd)

        # Print THD header: desc ptr, desc[4] status, thd ptr (blob: L174, line 0x8EF)
        let descriptorStatus = desc.descriptorStatus
        logFn7(2, 0, "txl_cntrl.c", 0x8EF, "desc",
               cast[uint32](curDesc), descriptorStatus, cast[uint32](thd))

        # Print THD sub-fields: frame length, MAC ACK policy control,
        # control flags, and rate-control THD pointer.
        # Blob (L174, offset 0x184): reads thd[112] fields and prints.
        let thdDataLen = hw.frameLen
        let ackPolicyControl = hw.ackPolicyControl
        let thdControlFlags = hw.controlFlags
        logFn7(2, 0, "txl_cntrl.c", 0x8F0, "thd_detail",
               thdDataLen, ackPolicyControl, thdControlFlags)

        # Walk sub-descriptor chain at THD+40 (rate control descriptor).
        let rateThdPtr = hw.chainedThd
        if rateThdPtr != nil:
          let rateDumpDesc = txDumpRateDescAt(rateThdPtr)
          logFn7(2, 0, "txl_cntrl.c", 0x8FB, "rate",
                 rateDumpDesc.rateDumpHeader0, rateDumpDesc.rateDumpHeader1,
                 rateDumpDesc.rateDumpHeader2)
          logFn5(2, 0, "txl_cntrl.c", 0x903, "rate2",
                 rateDumpDesc.rateDumpHeader3)

          for primaryPolicyWord in rateDumpDesc.primaryPolicyWords:
            if printFn != nil:
              let policyPrintFn = cast[proc(fmt: cstring, arg: pointer) {.cdecl.}](printFn)
              policyPrintFn("pol", cast[pointer](primaryPolicyWord))

          logFn(2, 0, "txl_cntrl.c", 0x907)
          logFn(2, 0, "txl_cntrl.c", 0x908)

          for secondaryPolicyWord in rateDumpDesc.secondaryPolicyWords:
            if printFn != nil:
              let policyPrintFn = cast[proc(fmt: cstring, arg: pointer) {.cdecl.}](printFn)
              policyPrintFn("pol2", cast[pointer](secondaryPolicyWord))

          logFn(2, 0, "txl_cntrl.c", 0x90C)

          var nextRateThd = rateDumpDesc.next
          var rateIdx: uint32 = 0
          while nextRateThd != nil and rateIdx < 4:
            logFn5(2, 0, "txl_cntrl.c", 0x90E, "rchain", rateIdx)
            nextRateThd = txDumpRateDescAt(nextRateThd).next
            rateIdx += 1

        # Walk buffer descriptor chain at THD[16] (next pointer).
        var bufferDumpDescPtr = cast[pointer](hw.status)
        var subIdx: uint32 = 0
        while bufferDumpDescPtr != nil:
          let bufferDumpDesc = txDumpBufferDescAt(bufferDumpDescPtr)
          logFn7(2, 0, "txl_cntrl.c", 0x911, "buf",
                 subIdx, bufferDumpDesc.bufferDumpHeader,
                 pointerAddrU32(bufferDumpDesc.next))
          bufferDumpDescPtr = bufferDumpDesc.next  # next buf desc
          inc subIdx

      curDesc = desc.link.next  # next in list

{.emit: "__attribute__((optimize(\"crossjumping\"))) void txl_payload_handle_backup(void*);".}
proc txl_payload_handle_backup*(param: pointer) {.exportc, cdecl.} =
  ## TX payload backup handler.
  ## Iterates over 5 AC entries in txl_cntrl_env (stride 8 for backup at
  ## offset +180, stride 16 for control base). For each AC, walks the pending
  ## backup descriptor chain and re-queues to HW:
  ##   - Gate: all beacon/machdr/tkip/thd work only if actualDesc[8] != nil
  ##   - For AC==4 (BCN): updates vif_info_tab protection flags
  ##   - If sta_idx == 0xFF: calls txl_machdr_format on the MAC header
  ##   - Calls txu_cntrl_tkip_mic_append for TKIP MIC append
  ##   - Patches THD rate/policy fields from link descriptor
  ##   - Links THD+4 into per-AC HW queue
  ##   - On first desc into empty HW queue: assert DMA status, program link
  ##     register, call blmac_abs_timer_set, set AGG bits
  ##   - On subsequent descs (non-empty queue): just write trigger register
  ##
  ## Call graph: assert_rec, blmac_abs_timer_set, txl_machdr_format,
  ##             txu_cntrl_tkip_mic_append
  inc nimFwDbgPayBackupEntry

  template txlDmaStatusField(status: uint32, acIdx: uint32): uint32 =
    ## Vendor uses T-Head bit-extracts here:
    ## AC0=[5:4], AC1=[9:8], AC2=[13:12], AC3=[17:16], AC4=[1:0].
    case acIdx
    of 0'u32:
      (status shr 4) and 3'u32
    of 1'u32:
      (status shr 8) and 3'u32
    of 2'u32:
      (status shr 12) and 3'u32
    of 3'u32:
      (status shr 16) and 3'u32
    of 4'u32:
      status and 3'u32
    else:
      0'u32

  for ac in 0'u32 ..< NUM_TX_QUEUES.uint32:
    let acCtrl = txControlAc(ac)
    let backupHead = txBackupQueueHeadPtr(ac)
    var descPtr = backupHead[]

    if descPtr == nil:
      continue

    let acBit = 1'u32 shl ac

    while descPtr != nil:
      inc nimFwDbgPayDescFound
      let backupDesc = hostTxBufferedLinkAt(descPtr)
      let nextDesc = backupDesc.next

      # Store next as new backup head
      backupHead[] = nextDesc

      # Dereference desc[20] to get the actual TX descriptor (blob: s0 = a0[20])
      let actualDesc = backupDesc.txDesc
      let actualU = cast[uint](actualDesc)
      let actual = hostTxDescAt(actualDesc)
      let fcTrace = backupDesc.macHeader[0]
      let isNullDataFrame =
        backupDesc.macHeader[0] == 0x48'u8 and backupDesc.macHeader[1] == 0x01'u8
      let isTrackedByCallback =
        actualDesc != nil and actual.callback != nil and
        cast[uint32](cast[uint](actual.callback)) == nimFwDbgNullFrameCbSetPtr
      let isTrackedNullFrame =
        isNullDataFrame or isTrackedByCallback
      let traceMgmt = nimFwMgmtFcTrace(fcTrace)
      let protoTrace =
        if actualDesc != nil: actual.frameLen
        else: 0'u16
      let traceEapol = protoTrace == 0x8E88'u16 or protoTrace == 0x888E'u16
      if fcTrace == 0x40'u8 and actualDesc != nil:
        nimFwDbgProbePayMeta =
          (ac and 0xff'u32) or
          ((if actual.queueFirst != nil: 1'u32 else: 0'u32) shl 8) or
          (uint32(actual.staIdx) shl 16) or
          (uint32(actual.vifIdx) shl 24)
        nimFwDbgProbePayDesc = pointerAddrU32(actualDesc)
        nimFwDbgProbePayLink = pointerAddrU32(actual.bufDesc)
        nimFwDbgProbePayHw = pointerAddrU32(actual.hwDesc)
        let probeLink = hostTxLinkDescAt(actual.bufDesc)
        let probeHw = hostTxHwDescAt(actual.hwDesc)
        let probeMacLen =
          if probeHw != nil and probeHw.frameLen >= 4'u32:
            probeHw.frameLen - 4'u32
          else:
            0'u32
        nimFwDbgProbePayLen =
          probeMacLen or (uint32(actual.frameLen) shl 16)
        if probeLink != nil:
          nimFwDbgProbePayLinkHeaderLen = probeLink.headerLen
          nimFwDbgProbePayLinkTxControlXor =
            probeLink.ackPolicyControl xor probeLink.retryLimitControl
        else:
          nimFwDbgProbePayLinkHeaderLen = 0
          nimFwDbgProbePayLinkTxControlXor = 0
        if probeHw != nil:
          nimFwDbgProbePayThd = pointerAddrU32(cast[pointer](addr probeHw.magic))
          nimFwDbgProbePayHwConfirmDescPtr = probeHw.txConfirmDescPtr
          nimFwDbgProbePayHwMagic = probeHw.magic
          nimFwDbgProbePayHwSecondaryDescPtr = probeHw.secondaryTxHwDescPtr
          nimFwDbgProbePayHwSecondaryStatusPadding =
            probeHw.secondaryDescToStatusPadding
          nimFwDbgProbePayHwStart = probeHw.payloadStart
          nimFwDbgProbePayHwEnd = probeHw.payloadEnd
          nimFwDbgProbePayHwFrameLen = probeHw.frameLen
          nimFwDbgProbePayHwStatus = probeHw.status
          nimFwDbgProbePayHwCtrl = probeHw.controlFlags
          nimFwDbgProbePayHwChain = pointerAddrU32(probeHw.chainedThd)
          nimFwDbgProbePayHwRetryLimitControl = probeHw.retryLimitControl
          nimFwDbgProbePayHwAckPolicyControl = probeHw.ackPolicyControl
          nimFwDbgProbePayHwCompatRetryLimitControl = probeHw.retryLimitControl
          nimFwDbgProbePayHwCompatAckPolicyControl = probeHw.ackPolicyControl
        else:
          nimFwDbgProbePayThd = 0
          nimFwDbgProbePayHwConfirmDescPtr = 0
          nimFwDbgProbePayHwMagic = 0
          nimFwDbgProbePayHwSecondaryDescPtr = 0
          nimFwDbgProbePayHwSecondaryStatusPadding = 0
          nimFwDbgProbePayHwStart = 0
          nimFwDbgProbePayHwEnd = 0
          nimFwDbgProbePayHwFrameLen = 0
          nimFwDbgProbePayHwStatus = 0
          nimFwDbgProbePayHwCtrl = 0
          nimFwDbgProbePayHwChain = 0
          nimFwDbgProbePayHwRetryLimitControl = 0
          nimFwDbgProbePayHwAckPolicyControl = 0
          nimFwDbgProbePayHwCompatRetryLimitControl = 0
          nimFwDbgProbePayHwCompatAckPolicyControl = 0
        let copyLen = if probeMacLen < nimFwDbgProbePayRaw.len.uint32:
          probeMacLen
        else:
          nimFwDbgProbePayRaw.len.uint32
        for probePayloadByteIndex in 0 ..< nimFwDbgProbePayRaw.len:
          nimFwDbgProbePayRaw[probePayloadByteIndex] = 0
        if copyLen != 0 and probeLink != nil:
          discard c_memcpy(addr nimFwDbgProbePayRaw[0],
                           addr probeLink.macHeader[0],
                           copyLen)

      # Gate: only do beacon/machdr/tkip/thd patching if actualDesc[8] != nil
      let hasPayload = actual.queueFirst
      if isTrackedNullFrame:
        inc nimFwDbgNullFramePaySeen
        nimFwDbgNullFramePayAc = ac
        nimFwDbgNullFramePayCurrent = pointerAddrU32(acCtrl.current)
        nimFwDbgNullFramePayPending = pointerAddrU32(cast[pointer](acCtrl.pending.first))
        nimFwDbgNullFramePayThdStatus =
          hostTxHwDescAt(actual.hwDesc).confirmStatus
        if hasPayload != nil:
          inc nimFwDbgNullFramePayHasPayload
      if traceMgmt:
        nimFwTrace2U32("[WIFI-NIMFW] pay_enter ",
                       ac or ((if hasPayload != nil: 1'u32 else: 0'u32) shl 8),
                       cast[uint32](actualU))
        when defined(bl808WifiConnectTrace):
          nimFwConnectTrace2U32("[WIFI-CT] pay_enter ",
                                ac or ((if hasPayload != nil: 1'u32 else: 0'u32) shl 8),
                                cast[uint32](actualU))
      if traceEapol:
        let macHdrTrace = cast[ptr MacDataFrameHeaderView](addr backupDesc.macHeader[0])
        let macFrameControlDurationWord =
          macHdrTrace.frameControl.uint32 or (macHdrTrace.duration.uint32 shl 16)
        let macHdrAddr3Word0 = macAddrWord0(addr macHdrTrace.addr3)
        nimFwTrace2U32("[WIFI-NIMFW] pay_eapol ",
                       ac or ((if hasPayload != nil: 1'u32 else: 0'u32) shl 8),
                       cast[uint32](actualU))
        nimFwTrace2U32("[WIFI-NIMFW] pay_eapol_hdr ",
                       macFrameControlDurationWord,
                       macHdrAddr3Word0)
        when defined(bl808WifiConnectTrace):
          if nimFwDbgEapolTraceCount < 64'u32:
            nimFwConnectTrace2U32("[WIFI-CT] pay_eapol ",
                                  ac or ((if hasPayload != nil: 1'u32 else: 0'u32) shl 8) or
                                    (nimFwDbgEapolTraceCount shl 16),
                                  cast[uint32](actualU))
            nimFwConnectTrace2U32("[WIFI-CT] pay_eapol_hdr ",
                                  macFrameControlDurationWord,
                                  macHdrAddr3Word0)
      when declared(NimFwForcedMgmtTxPower):
        let fcForce = cast[ptr uint16](addr backupDesc.macHeader[0])[]
        if ((fcForce.uint32 shr 2) and 3'u32) == 0'u32:
          let forceLink = hostTxLinkDescAt(actual.bufDesc)
          if forceLink != nil:
            let forceRate = hostTxRateTemplate(forceLink)
            forceRate.txPower = NimFwForcedMgmtTxPower.int32
            forceRate.retryTxPowerControl0 = NimFwForcedMgmtTxPower
            forceRate.retryTxPowerControl1 = NimFwForcedMgmtTxPower
            forceRate.retryTxPowerControl2 = NimFwForcedMgmtTxPower
      if hasPayload != nil:
        inc nimFwDbgPayHasPayload
        when declared(rfPriApplyWb03AuthTxLatches):
          let fcForRfLatch = cast[ptr uint16](addr backupDesc.macHeader[0])[]
          let typeForRfLatch = (fcForRfLatch.uint32 shr 2) and 3'u32
          if ac < 4'u32 and typeForRfLatch == 2'u32:
            inc nimFwDbgStaTxRfLatch
            rfPriApplyWb03AuthTxLatches()
        # For AC==4 (BCN), special beacon handling
        if ac == 4:
          let vif = vifChannelForIdx(actual.vifIdx)  # blob: lbu a3,47(s0)
          let protFlags = vif.timFlags
          let isProtected = backupDesc.macHeader[1]  # blob: lbu a3,349(a0)
          if isProtected != 0:
            vif.timFlags = protFlags or 2
          else:
            vif.timFlags = protFlags and not 2'u8

        # If sta_idx == 0xFF, format MAC header (blob calls txl_machdr_format)
        let staIdx = actual.staIdx  # blob: lbu a4,46(s0)
        if staIdx == 0xFF:
          txl_machdr_format(cast[pointer](addr backupDesc.macHeader[0]))

        # Save link descriptor across call, read THD (s11), call txu_cntrl_tkip_mic_append
        let linkDesc = hostTxLinkDescAt(actual.bufDesc)
        let thd = hostTxHwDescAt(actual.hwDesc)  # saved as s11 across call
        txu_cntrl_tkip_mic_append(actualDesc)

        # Copy the two MAC TX control trailer words that follow the 52-byte
        # rate template in TxBufferControlView into their hardware descriptor
        # destinations.
        thd.ackPolicyControl = linkDesc.ackPolicyControl
        thd.chainedThd = cast[pointer](hostTxRateTemplate(linkDesc))
        thd.retryLimitControl = linkDesc.retryLimitControl
        if lmacGateHalfword(actual.frameLen) == 0x0800'u16:
          let rateForDhcp = hostTxRateTemplate(linkDesc)
          nimFwDbgDhcpTxBufDesc = pointerAddrU32(actual.bufDesc)
          nimFwDbgDhcpTxHwDesc = pointerAddrU32(actual.hwDesc)
          captureDhcpTxRateRaw(rateForDhcp)
          nimFwDbgDhcpTxRate0 =
            rateForDhcp.magic xor (rateForDhcp.ntxConfig shl 16)
          nimFwDbgDhcpTxRate1 =
            rateForDhcp.pendingCount xor (rateForDhcp.policyWord shl 16)
          nimFwDbgDhcpTxRate2 =
            rateForDhcp.rateWord xor (cast[uint32](rateForDhcp.txPower) shl 16)
          nimFwDbgDhcpTxRate3 =
            rateForDhcp.retryTxPowerControl0 xor (rateForDhcp.retryTxPowerControl1 shl 16) xor
            rateForDhcp.retryTxPowerControl2
          nimFwDbgDhcpTxLink0 = linkDesc.ackPolicyControl
          nimFwDbgDhcpTxLink1 = linkDesc.retryLimitControl
          nimFwDbgDhcpTxThd0 =
            thd.status xor (thd.frameLen shl 16)
          nimFwDbgDhcpTxThd1 =
            thd.retryLimitControl xor (pointerAddrU32(thd.chainedThd) shl 16)
          nimFwDbgDhcpTxThd2 =
            thd.ackPolicyControl xor (thd.controlFlags shl 16)
          nimFwDbgDhcpTxFinalDesc0 =
            actual.frameLen.uint32 or
            (actual.hdrLen.uint32 shl 16) or
            (actual.qosExtLen.uint32 shl 24)
          nimFwDbgDhcpTxFinalDesc1 =
            actual.secTailLen.uint32 or
            (actual.staIdx.uint32 shl 8) or
            (actual.vifIdx.uint32 shl 16) or
            (actual.staInfoIdx.uint32 shl 24)
          nimFwDbgDhcpTxFinalBuf0 = actual.bufferPtrs[0]
          nimFwDbgDhcpTxFinalLen0 = actual.bufferLens[0]
          nimFwDbgDhcpTxFinalHwStart = thd.payloadStart
          nimFwDbgDhcpTxFinalHwEnd = thd.payloadEnd
          nimFwDbgDhcpTxFinalHwLen = thd.frameLen
          nimFwDbgDhcpTxFinalHwFlags = thd.controlFlags
          nimFwDbgDhcpTxFinalHthdStart = linkDesc.headerThd.payloadStart
          nimFwDbgDhcpTxFinalHthdEnd = linkDesc.headerThd.payloadEnd
          nimFwDbgDhcpTxFinalHthdNext = pointerAddrU32(linkDesc.headerThd.next)
          nimFwDbgDhcpTxFinalHthdFlags = linkDesc.headerThd.flags
          nimFwDbgDhcpTxFinalPthdStart = linkDesc.payloadThd[0].payloadStart
          nimFwDbgDhcpTxFinalPthdEnd = linkDesc.payloadThd[0].payloadEnd
          nimFwDbgDhcpTxFinalPthdNext = pointerAddrU32(linkDesc.payloadThd[0].next)
          nimFwDbgDhcpTxFinalPthdFlags = linkDesc.payloadThd[0].flags
          nimFwDbgDhcpTxFinalBreakpoint()
        if traceMgmt or traceEapol:
          nimFwTrace2U32("[WIFI-NIMFW] pay_rate ",
                         linkDesc.ackPolicyControl,
                         linkDesc.retryLimitControl)
          if traceMgmt:
            when defined(bl808WifiConnectTrace):
              nimFwConnectTrace2U32("[WIFI-CT] pay_rate ",
                                    linkDesc.ackPolicyControl,
                                    linkDesc.retryLimitControl)

      # Increment per-AC packet counter at acCtrlBase+12 (half-word)
      acCtrl.packetCount = acCtrl.packetCount + 1

      # Get THD+4 for linking (blob re-reads actualDesc[112] here at .L60)
      let thdForLinkView = hostTxHwDescAt(actual.hwDesc)
      let thdForLink = cast[uint](thdForLinkView)
      let thdLink = cast[pointer](cast[uint](addr thdForLinkView.magic))

      # Check if per-AC HW queue list is empty
      let listFirst = acCtrl.current
      if traceMgmt or traceEapol:
        let thdStatusBefore = thdForLinkView.confirmStatus
        nimFwTrace2U32("[WIFI-NIMFW] pay_link ",
                       ac or ((if listFirst == nil: 1'u32 else: 0'u32) shl 8),
                       cast[uint32](thdLink) xor thdStatusBefore)
        if traceMgmt:
          when defined(bl808WifiConnectTrace):
            nimFwConnectTrace2U32("[WIFI-CT] pay_link ",
                                  ac or ((if listFirst == nil: 1'u32 else: 0'u32) shl 8),
                                  cast[uint32](thdLink) xor thdStatusBefore)
            let linkTrace = hostTxLinkDescAt(actual.bufDesc)
            let rateTrace = hostTxRateTemplate(linkTrace)
            nimFwConnectTrace2U32("[WIFI-CT] pay_hw0 ",
                                  thdForLinkView.payloadEnd,
                                  thdForLinkView.frameLen)
            nimFwConnectTrace2U32("[WIFI-CT] pay_hw1 ",
                                  thdForLinkView.retryLimitControl,
                                  pointerAddrU32(thdForLinkView.chainedThd))
            nimFwConnectTrace2U32("[WIFI-CT] pay_hw2 ",
                                  thdForLinkView.ackPolicyControl,
                                  thdForLinkView.controlFlags)
            nimFwConnectTrace2U32("[WIFI-CT] pay_pol0 ",
                                  rateTrace.magic,
                                  rateTrace.ntxConfig)
            nimFwConnectTrace2U32("[WIFI-CT] pay_pol1 ",
                                  rateTrace.policyWord,
                                  rateTrace.rateWord)
            nimFwConnectTrace2U32("[WIFI-CT] pay_pol2 ",
                                  rateTrace.retryRateControl2,
                                  cast[uint32](rateTrace.txPower))
            nimFwConnectTrace2U32("[WIFI-CT] pay_pol3 ",
                                  rateTrace.retryTxPowerControl0,
                                  rateTrace.retryTxPowerControl1)
            nimFwConnectTrace2U32("[WIFI-CT] pay_pol4 ",
                                  rateTrace.retryTxPowerControl2,
                                  linkTrace.ackPolicyControl)
        if traceEapol:
          let link = hostTxBufferedLinkAt(actual.bufDesc)
          let rate = hostTxRateTemplate(link)
          nimFwTrace2U32("[WIFI-NIMFW] pay_desc0 ",
                         pointerAddrU32(actual.queueFirst),
                         actual.seqPassthrough.uint32)
          nimFwTrace2U32("[WIFI-NIMFW] pay_desc1 ",
                         actual.bufferPtrs[0],
                         actual.bufferLens[0])
          nimFwTrace2U32("[WIFI-NIMFW] pay_link0 ",
                         link.headerThd.magic,
                         pointerAddrU32(link.headerThd.next))
          nimFwTrace2U32("[WIFI-NIMFW] pay_link1 ",
                         link.headerThd.payloadStart,
                         link.headerThd.payloadEnd)
          nimFwTrace2U32("[WIFI-NIMFW] pay_hw0 ",
                         thdForLinkView.magic,
                         thdForLinkView.secondaryTxHwDescPtr)
          nimFwTrace2U32("[WIFI-NIMFW] pay_hw1 ",
                         thdForLinkView.secondaryDescToStatusPadding,
                         thdForLinkView.status)
          nimFwTrace2U32("[WIFI-NIMFW] pay_hw2 ",
                         thdForLinkView.frameLen,
                         thdForLinkView.retryLimitControl)
          nimFwTrace2U32("[WIFI-NIMFW] pay_hw3 ",
                         pointerAddrU32(thdForLinkView.chainedThd),
                         thdForLinkView.ackPolicyControl)
          nimFwTrace2U32("[WIFI-NIMFW] pay_hw4 ",
                         thdForLinkView.controlFlags,
                         thdForLinkView.confirmStatus)
          nimFwTrace2U32("[WIFI-NIMFW] pay_buf0 ",
                         link.payloadThd[0].magic,
                         pointerAddrU32(link.payloadThd[0].next))
          nimFwTrace2U32("[WIFI-NIMFW] pay_buf1 ",
                         link.payloadThd[0].payloadStart,
                         link.payloadThd[0].payloadEnd)
          nimFwTrace2U32("[WIFI-NIMFW] pay_pol0 ",
                         rate.magic,
                         rate.ntxConfig)
          nimFwTrace2U32("[WIFI-NIMFW] pay_pol1 ",
                         rate.bwMask,
                         rate.pendingCount)
          nimFwTrace2U32("[WIFI-NIMFW] pay_pol2 ",
                         rate.policyWord,
                         rate.rateWord)
          nimFwTrace2U32("[WIFI-NIMFW] pay_pol3 ",
                         rate.retryRateControl0,
                         rate.retryRateControl1)
          nimFwTrace2U32("[WIFI-NIMFW] pay_pol4 ",
                         rate.retryRateControl2,
                         cast[uint32](rate.txPower))
          when defined(bl808WifiConnectTrace):
            if nimFwDbgEapolTraceCount < 64'u32:
              nimFwConnectTrace2U32("[WIFI-CT] pay_desc0 ",
                                    pointerAddrU32(actual.queueFirst),
                                    actual.seqPassthrough.uint32)
              nimFwConnectTrace2U32("[WIFI-CT] pay_desc1 ",
                                    actual.bufferPtrs[0],
                                    actual.bufferLens[0])
              nimFwConnectTrace2U32("[WIFI-CT] pay_link0 ",
                                    link.headerThd.magic,
                                    pointerAddrU32(link.headerThd.next))
              nimFwConnectTrace2U32("[WIFI-CT] pay_link1 ",
                                    link.headerThd.payloadStart,
                                    link.headerThd.payloadEnd)
              nimFwConnectTrace2U32("[WIFI-CT] pay_hw0 ",
                                    thdForLinkView.magic,
                                    thdForLinkView.secondaryTxHwDescPtr)
              nimFwConnectTrace2U32("[WIFI-CT] pay_hw1 ",
                                    thdForLinkView.secondaryDescToStatusPadding,
                                    thdForLinkView.status)
              nimFwConnectTrace2U32("[WIFI-CT] pay_hw2 ",
                                    thdForLinkView.frameLen,
                                    thdForLinkView.retryLimitControl)
              nimFwConnectTrace2U32("[WIFI-CT] pay_hw3 ",
                                    pointerAddrU32(thdForLinkView.chainedThd),
                                    thdForLinkView.ackPolicyControl)
              nimFwConnectTrace2U32("[WIFI-CT] pay_hw4 ",
                                    thdForLinkView.controlFlags,
                                    thdForLinkView.confirmStatus)
              nimFwConnectTrace2U32("[WIFI-CT] pay_buf0 ",
                                    link.payloadThd[0].magic,
                                    pointerAddrU32(link.payloadThd[0].next))
              nimFwConnectTrace2U32("[WIFI-CT] pay_buf1 ",
                                    link.payloadThd[0].payloadStart,
                                    link.payloadThd[0].payloadEnd)
              nimFwConnectTrace2U32("[WIFI-CT] pay_pol0 ",
                                    rate.magic,
                                    rate.ntxConfig)
              nimFwConnectTrace2U32("[WIFI-CT] pay_pol1 ",
                                    rate.bwMask,
                                    rate.pendingCount)
              nimFwConnectTrace2U32("[WIFI-CT] pay_pol2 ",
                                    rate.policyWord,
                                    rate.rateWord)
              nimFwConnectTrace2U32("[WIFI-CT] pay_pol3 ",
                                    rate.retryRateControl0,
                                    rate.retryRateControl1)
              nimFwConnectTrace2U32("[WIFI-CT] pay_pol4 ",
                                    rate.retryRateControl2,
                                    cast[uint32](rate.txPower))
              nimFwDbgEapolTraceCount = nimFwDbgEapolTraceCount + 1
      if listFirst == nil:
        inc nimFwDbgPayEmptyList
        if isTrackedNullFrame:
          inc nimFwDbgNullFramePayEmpty
        # Empty list path (.L64): read ipc_shared_env TX timer base from 0x24B00120,
        # check DMA status, program link register, call blmac_abs_timer_set, set AGG bits.
        # Timer constants: s6=200000, s7=50000, s8=2000000, AC2=400000.
        # Blob tail-merges the 5 per-AC assert_rec calls into one common
        # site — hoist the DMA status check out of the per-AC branches.
        let ipcSharedBase = cast[ptr uint32](0x24B00120'u)[]
        let dmaStatus = machwTxDmaStatus()
        let dmaField = txlDmaStatusField(dmaStatus, ac)
        var assertLine: cint = 0
        var timerVal: uint32
        case ac
        of 0:
          assertLine = 539
          timerVal = ipcSharedBase + 200000'u32
        of 1:
          assertLine = 533
          timerVal = ipcSharedBase + 2000000'u32
        of 2:
          assertLine = 527
          timerVal = ipcSharedBase + 400000'u32
        of 3:
          assertLine = 521
          timerVal = ipcSharedBase + 200000'u32
        of 4:
          assertLine = 514
          timerVal = ipcSharedBase + 50000'u32
        else:
          timerVal = 0
        if traceMgmt or traceEapol:
          nimFwTrace2U32("[WIFI-NIMFW] pay_dma ",
                         ac or (dmaField shl 8),
                         dmaStatus)
          if traceMgmt:
            when defined(bl808WifiConnectTrace):
              nimFwConnectTrace2U32("[WIFI-CT] pay_dma ",
                                    ac or (dmaField shl 8),
                                    dmaStatus)
        if assertLine != 0 and dmaField == 2:
          assert_rec("txl_payload.c", "txl_payload.c", assertLine)
        else:
          var trigBits: uint32 = 0
          case ac
          of 0:
            machwTxSetHead(ac, thdLink)
            trigBits = 512
          of 1:
            machwTxSetHead(ac, thdLink)
            trigBits = 1024
          of 2:
            machwTxSetHead(ac, thdLink)
            trigBits = 2048
          of 3:
            machwTxSetHead(ac, thdLink)
            trigBits = 4096
          of 4:
            machwTxSetHead(ac, thdLink)
            trigBits = 256
          else:
            discard
          machwTxTrigger(trigBits)
          nimFwDbgPayTriggerLast = trigBits or (ac shl 16) or 0x80000000'u32
          nimFwDbgPayTxStatus = machwTxStatus()
          nimFwDbgPayTxAgg = machwTxAggActive()
          nimFwDbgPayTxDma = dmaStatus
          nimFwDbgPayTxCurrent = pointerAddrU32(acCtrl.current)
          nimFwDbgPayTxThd = pointerAddrU32(thdLink)
          nimFwDbgPayTxHead = machwTxHeadValue(ac)
          if isTrackedNullFrame:
            nimFwDbgNullFramePayTrigger = nimFwDbgPayTriggerLast
          blmac_abs_timer_set(ac, timerVal)
          # Set HW aggregation bits
          machwTxAggSet(acBit)
          let aggOr = machwTxAggActive()
          machwTxAggActiveSet(acBit or aggOr)
          if traceMgmt or traceEapol:
            nimFwTrace2U32("[WIFI-NIMFW] pay_regs ",
                           machwTxStatus(),
                           machwTxAggActive())
            if traceMgmt:
              when defined(bl808WifiConnectTrace):
                nimFwConnectTrace2U32("[WIFI-CT] pay_regs ",
                                      machwTxStatus(),
                                      machwTxAggActive())
      else:
        inc nimFwDbgPayNonEmpty
        if isTrackedNullFrame:
          inc nimFwDbgNullFramePayNonEmpty
        # Non-empty list: link into existing chain and write trigger
        hostTxThdAt(listFirst).next = thdLink
        var triggerVal: uint32
        case ac
        of 3: triggerVal = 16
        of 4: triggerVal = 1
        of 2: triggerVal = 8
        of 1: triggerVal = 4
        else: triggerVal = 2    # AC0
        machwTxTrigger(triggerVal)
        nimFwDbgPayTriggerLast = triggerVal or (ac shl 16) or 0x40000000'u32
        nimFwDbgPayTxStatus = machwTxStatus()
        nimFwDbgPayTxAgg = machwTxAggActive()
        nimFwDbgPayTxDma = machwTxDmaStatus()
        nimFwDbgPayTxCurrent = pointerAddrU32(acCtrl.current)
        nimFwDbgPayTxThd = pointerAddrU32(thdLink)
        nimFwDbgPayTxHead = machwTxHeadValue(ac)
        if isTrackedNullFrame:
          nimFwDbgNullFramePayTrigger = nimFwDbgPayTriggerLast
        if traceMgmt or traceEapol:
          nimFwTrace2U32("[WIFI-NIMFW] pay_regs ",
                         machwTxStatus(),
                         machwTxAggActive())
          if traceMgmt:
            when defined(bl808WifiConnectTrace):
              nimFwConnectTrace2U32("[WIFI-CT] pay_regs ",
                                    machwTxStatus(),
                                    machwTxAggActive())

      # Update list head
      acCtrl.current = thdLink

      # Advance to next descriptor in backup chain (.L70 re-reads backup head)
      descPtr = backupHead[]

proc txlTriggerPending(acCtrl: ptr TxControlAcView): bool {.inline.} =
  acCtrl.pending.first != nil

proc txl_transmit_trigger*() {.exportc, cdecl.} =
  ## Trigger TX DMA transmission for the highest-priority ready AC.
  ## Reads MACHW INTC status to find the highest-priority AC with a pending
  ## descriptor, reads its THD, programs MAC HW DMA, and handles chaining.
  ## From disassembly (122 instrs).
  ##
  ## Blob flow:
  ##   1. Read MACHW TX status through the typed register overlay, mask bits [10:6]
  ##   2. CLZ to find highest-priority AC (ac = 25 - CLZ)
  ##   3. Process ONLY that single AC per invocation
  ##   4. Loop within that AC's descriptor chain until THD not ready
  ##   5. For each ready THD: program DMA, handle secondary chain
  ##   6. Tail-call hal_machw_trigger_set(ac, ipc_base + offset) to start TX
  inc nimFwDbgTxTrigEntry
  const
    IPC_SHARED_TX_BASE  = 0x24B00120'u
    TX_TIMEOUT_LOCAL    = [200000'u32, 2000000'u32, 400000'u32, 200000'u32, 50000'u32]

  # Check MAC HW TX status. The reference path uses bits [10:6], but BL808
  # also reports active TX queues in the halt/status field used by
  # txl_cntrl_halt_ac: AC0..AC3 at bits [16..19], beacon at bit 15.
  let txStatus = machwTxStatus()
  let acReady = txStatus and 0x7C0'u32  # bits [10:6]
  let acReadyHigh = txStatus and 0x000F8000'u32
  nimFwDbgTxTrigAcReady = txStatus
  if acReady == 0 and acReadyHigh == 0:
    inc nimFwDbgTxTrigZeroExit
    return  # No ACs ready for transmission

  var ac: uint32
  if acReady != 0:
    # Compute highest-priority AC from CLZ: s0 = 25 - CLZ(acReady)
    var clzResult: cint
    {.emit: [clzResult, " = __builtin_clz((unsigned int)", acReady, ");"].}
    # Blob keeps an assert_err for `ac > 4`. Under upstream GCC -Os the
    # compiler knows `acReady` has bits only in [10:6] so `ac` is always
    # ≤4 and elides the check. Use a volatile to defeat the range analysis.
    var acV {.volatile.}: uint32 = 25'u32 - clzResult.uint32
    ac = acV
  elif (acReadyHigh and 0x00008000'u32) != 0:
    ac = 4'u32
  elif (acReadyHigh and 0x00080000'u32) != 0:
    ac = 3'u32
  elif (acReadyHigh and 0x00040000'u32) != 0:
    ac = 2'u32
  elif (acReadyHigh and 0x00020000'u32) != 0:
    ac = 1'u32
  else:
    ac = 0'u32
  if ac > 4:
    assert_err("txl_cntrl.c", "txl_cntrl.c", 0x86C)

  # Set up masks: acBit = 1 << ac, clearMask = ~(1 << ac)
  let clearMask = not (1'u32 shl ac)

  # Store the AC readiness bit to INTC trigger register for HW readback
  let readyBit = 1'u32 shl (ac + 6)
  machwTxReadyAck(readyBit)

  let acCtrl = txControlAc(ac)
  var drained = 0'u32

  # Main loop (.L137): process a bounded batch of descriptors for this AC.
  while drained < WifiTxTriggerDrainLimit:
    inc nimFwDbgTxTrigLoops
    let descPtr = cast[pointer](acCtrl.pending.first)
    if descPtr == nil:
      inc nimFwDbgTxTrigNoDesc
      # No descriptor (.L130): clear AC bit in INTC status, clear cntrl_env[0]
      let intcStat = machwTxAggActive()
      acCtrl.current = nil
      machwTxAggActiveSet(intcStat and clearMask)
      return
    if not txl_tx_desc_pointer_plausible(descPtr):
      inc nimFwDbgTxPendingInvalid
      nimFwDbgTxPendingInvalidPtr = pointerAddrU32(descPtr)
      acCtrl.pending.first = nil
      acCtrl.pending.last = nil
      acCtrl.current = nil
      let intcStat = machwTxAggActive()
      machwTxAggActiveSet(intcStat and clearMask)
      discard txl_frame_rebuild_free_list()
      return

    # Read THD from descriptor at offset 112
    let desc = hostTxDescAt(descPtr)
    let descAddr = cast[uint](desc)
    let linkPtrTrace = desc.bufDesc
    let linkTrace = hostTxBufferedLinkAt(linkPtrTrace)
    let fcTrace = if linkTrace != nil: linkTrace.macHeader[0] else: 0'u8
    let fcTrace1 = if linkTrace != nil: linkTrace.macHeader[1] else: 0'u8
    let traceMgmt = linkPtrTrace != nil and nimFwMgmtFcTrace(fcTrace)
    let protoTrace = desc.frameLen
    let traceEapol = protoTrace == 0x8E88'u16 or protoTrace == 0x888E'u16
    let hwDesc = hostTxHwDescAt(desc.hwDesc)
    let thdAddr = cast[uint](hwDesc)
    let thdStatus = cast[int32](hwDesc.confirmStatus)
    nimFwDbgTxTrigLastDesc = pointerAddrU32(descPtr)
    nimFwDbgTxTrigLastStatus = hwDesc.confirmStatus
    if traceMgmt or traceEapol:
      nimFwTrace2U32("[WIFI-NIMFW] txtrig_desc ",
                     ac.uint32 or (txStatus shl 8),
                     cast[uint32](thdStatus))
      if traceMgmt:
        when defined(bl808WifiConnectTrace):
          nimFwConnectTrace2U32("[WIFI-CT] txtrig_desc ",
                                ac.uint32 or (txStatus shl 8),
                                cast[uint32](thdStatus))
    if thdStatus >= 0:
      inc nimFwDbgTxTrigNotReady
      return  # THD not ready (bit 31 clear) -- .L126

    # Check for chained descriptors at desc[8] and desc[108]
    let nextDesc = desc.queueFirst
    if nextDesc != nil:
      let chainedThd = desc.bufDesc
      if chainedThd != nil:
        desc.bufDesc = nil

    # Program DMA: THD[0] -> head descriptor status.
    let dmaHead = hwDesc.txConfirmDescPtr.uint
    if traceMgmt or traceEapol:
      nimFwTrace2U32("[WIFI-NIMFW] txtrig_dma ",
                     cast[uint32](dmaHead),
                     cast[uint32](thdAddr))
      if traceMgmt:
        when defined(bl808WifiConnectTrace):
          nimFwConnectTrace2U32("[WIFI-CT] txtrig_dma ",
                                cast[uint32](dmaHead),
                                cast[uint32](thdAddr))
    hostTxHwDescAt(cast[pointer](dmaHead)).status = thdStatus.uint32

    # Check secondary TX hardware descriptor pointer at offset 8
    let secondaryTxHwDesc = cast[pointer](hwDesc.secondaryTxHwDescPtr.uint)
    if secondaryTxHwDesc == nil:
      # No secondary chain (.L133): clear AC bit in INTC status
      let intcStat = machwTxAggActive()
      acCtrl.current = nil
      machwTxAggActiveSet(intcStat and clearMask)
      # Fall through to .L134 path
    else:
      let secStatus = cast[int32](hostTxHwDescAt(secondaryTxHwDesc).controlFlags)
      if secStatus >= 0:
        # Secondary TX hardware descriptor not ready to pop: vendor rearms the AC timeout only.
        let ipcBase = regRead(IPC_SHARED_TX_BASE)
        blmac_abs_timer_set(ac, ipcBase + TX_TIMEOUT_LOCAL[ac])
        return
      # secStatus < 0: fall through to pop path (.L134)

    # .L134: Pop descriptor from list and process confirmation
    discard co_list_pop_front(addr acCtrl.pending)

    let hostCfm = if desc.usedFlag != 0: desc.queueFirst else: nil
    let isNullDataFrame = fcTrace == 0x48'u8 and fcTrace1 == 0x01'u8
    let isTrackedByCallback =
      desc.callback != nil and
      cast[uint32](cast[uint](desc.callback)) == nimFwDbgNullFrameCbSetPtr
    let isTrackedNullFrame =
      isNullDataFrame or isTrackedByCallback
    if isTrackedNullFrame:
      inc nimFwDbgNullFrameTxTrigSeen
      nimFwDbgNullFrameTxTrigUsedFlag = desc.usedFlag.uint32
      if hostCfm == nil:
        inc nimFwDbgNullFrameTxTrigInternal
      else:
        inc nimFwDbgNullFrameTxTrigHost
    nimFwDbgTxRouteUsedFlag = desc.usedFlag.uint32
    if hostCfm == nil:
      inc nimFwDbgTxRouteInternal
    else:
      inc nimFwDbgTxRouteHost
    let fenvPtrTrace = desc.hwDesc
    var cfmHeadTrace = 0'u32
    if fenvPtrTrace != nil:
      cfmHeadTrace = hostTxHwDescAt(fenvPtrTrace).txConfirmDescPtr
    let traceBadCfm = cfmHeadTrace == 0xBADCAB1E'u32
    let traceRoutedHost = hostCfm != nil
    if traceBadCfm or traceRoutedHost or traceMgmt or traceEapol:
      nimFwTrace2U32("[WIFI-NIMFW] txtrig_route ",
                     ac.uint32 or ((if traceRoutedHost: 1'u32 else: 0'u32) shl 8),
                     cast[uint32](descAddr))
      nimFwTrace2U32("[WIFI-NIMFW] txtrig_cfm ",
                     cast[uint32](cast[uint](fenvPtrTrace)),
                     cfmHeadTrace)
      nimFwTrace2U32("[WIFI-NIMFW] txtrig_link ",
                     cast[uint32](cast[uint](desc.queueFirst)),
                     cast[uint32](cast[uint](desc.bufDesc)))
      when defined(bl808WifiConnectTrace):
        nimFwConnectTrace2U32("[WIFI-CT] txtrig_route ",
                              ac.uint32 or ((if traceRoutedHost: 1'u32 else: 0'u32) shl 8),
                              cast[uint32](descAddr))
        nimFwConnectTrace2U32("[WIFI-CT] txtrig_cfm ",
                              cast[uint32](cast[uint](fenvPtrTrace)),
                              cfmHeadTrace)
        nimFwConnectTrace2U32("[WIFI-CT] txtrig_link ",
                              cast[uint32](cast[uint](desc.queueFirst)),
                              cast[uint32](cast[uint](desc.bufDesc)))
    if hostCfm == nil:
      # Internal management frame: frame-confirm event only.
      txl_frame_cfm(descPtr)
    else:
      # Host/data TX descriptor: route through the AC confirmation queue.
      txl_cfm_push(descPtr, thdStatus.uint32, ac.uint32)

    # Set absolute timer for next TX opportunity and loop to check for more descriptors.
    let ipcBase = regRead(IPC_SHARED_TX_BASE)
    blmac_abs_timer_set(ac, ipcBase + TX_TIMEOUT_LOCAL[ac])
    inc drained

  if txlTriggerPending(acCtrl):
    inc nimFwDbgTxTrigYield
    nimFwDbgTxTrigYieldAc = ac
    nimFwDbgTxTrigYieldHead = pointerAddrU32(cast[pointer](acCtrl.pending.first))

proc txl_current_desc_get*(ac: uint8): pointer {.exportc, cdecl.} =
  ## Get the current TX descriptor for an AC.
  ## From blob (8 instrs): computes txl_cntrl_env + ac*16, reads pending list first
  ## element at offset 4. If non-null, reads txDesc at elem+112, returns txDesc+4.
  ## If null, returns null. Blob writes result to *a1 (output param).
  let firstElem = cast[pointer](txControlAc(ac.uint32).pending.first)
  if firstElem == nil:
    return nil
  let txDesc = hostTxDescAt(firstElem).hwDesc
  if txDesc == nil:
    return nil
  return cast[pointer](addr hostTxHwDescAt(txDesc).magic)

proc txl_reset*() {.exportc, cdecl.} =
  ## Reset TX layer (87 instrs).
  ## From blob: saves txl_cntrl_env seq counter (offset 84, half-word),
  ## calls ke_free(0x7C000) to free a large block, then loops waiting for
  ## IPC_EMB_STATUS2 (0x24A00010) bits[15:0] == 0xFFFF (all TX slots idle).
  ## Sets txl_cntrl_env[88] = 1 (reset-in-progress flag).
  ## Then loops ac=0..4: for each AC, writes (1<<ac) to MAC HW 0x24A00020
  ## (TX halt register), calls txl_cfm_flush(s4_base, cfm_list, 0x40000000)
  ## to flush with large timeout mask, then calls txl_cfm_flush again with
  ## per-AC cfm list. After loop: calls txl_hwdesc_reset, txl_frame_reset,
  ## memsets txl_cntrl_env to 0 (92 bytes), restores seq counter, then
  ## re-initializes per-AC descriptors by calling txl_cntrl_init_ac(ac)
  ## and co_list_init for each AC's cfm list.
  let txCtrl = txControlEnv()

  # Save sequence counter before reset
  let savedSeqNum = txCtrl.seqCounter

  # Free large TX buffer block (blob: ke_free(0x7C000))
  # This is a dummy alloc/free matching blob's ke_free call
  # In practice this releases the TX DMA buffer pool

  # Wait for all TX slots to become idle
  # Blob: reads 0x24A00010 (IPC_EMB_STATUS2), waits for bits[15:0] == 0xFFFF
  const IPC_TX_STATUS_REG = 0x24A00010'u
  var waitCount = 0
  while waitCount < 10000:
    let status = volatileLoad(cast[ptr uint32](IPC_TX_STATUS_REG))
    if (status and 0xFFFF) == 0xFFFF:
      break
    waitCount += 1

  # Set reset-in-progress flag
  txCtrl.resetInProgress = 1

  # Clear TX events (blob: ke_evt_clear)
  ke_evt_clear(0x7C000'u32)

  # Loop ac=0..4: halt AC, then two txl_cfm_flush calls (blob: 10 total flushes)
  #   flush 1: cfm list at txl_cfm_env + ac*8
  #   flush 2: cfm list at txl_cntrl_env+4 + ac*16
  for ac in 0'u32 ..< 5:
    let acBit = 1'u32 shl ac
    volatileStore(cast[ptr uint32](0x24A00020'u), acBit)

    let cfmList1 = cast[uint](txCfmList(ac))
    {.emit: ["""{
    register unsigned int _a0 __asm__("a0") = (unsigned int)""", ac, """;
    register unsigned int _a1 __asm__("a1") = (unsigned int)""", cfmList1, """;
    register unsigned int _a2 __asm__("a2") = 0x40000000U;
    __asm__ volatile("" : : "r"(_a0), "r"(_a1), "r"(_a2));
    txl_cfm_flush();
    }"""].}

    let cfmList2 = cast[uint](addr txControlAc(ac).pending)
    {.emit: ["""{
    register unsigned int _a0 __asm__("a0") = (unsigned int)""", ac, """;
    register unsigned int _a1 __asm__("a1") = (unsigned int)""", cfmList2, """;
    register unsigned int _a2 __asm__("a2") = 0x40000000U;
    __asm__ volatile("" : : "r"(_a0), "r"(_a1), "r"(_a2));
    txl_cfm_flush();
    }"""].}

  # Reset HW descriptors, reinit buffer pool, init confirm lists
  # (blob: txl_hwdesc_reset; txl_buffer_reinit; txl_cfm_init)
  txl_hwdesc_reset()
  txl_buffer_reinit()
  txl_cfm_init()

  # Memset txl_cntrl_env to zero (92 bytes)
  discard c_memset(txCtrl, 0, 92.csize_t)

  # Restore saved sequence counter
  txCtrl.seqCounter = savedSeqNum

  # Re-initialize per-AC descriptors and cfm lists
  for ac in 0'u32 ..< 5:
    # Initialize each AC's CoList (cfm list)
    let cfmList = txCfmList(ac)
    # Initialize cfm CoList via real call (blob: co_list_init)
    co_list_init(cfmList)
    txControlAc(ac).current = nil
    ipcTxAcDescClear(ac)

proc txl_machdr_format*(param: pointer) {.exportc, cdecl.} =
  ## Format MAC header for TX frame.
  ## From blob (13 instrs): reads frame[22] (sequence control byte), extracts
  ## fragment number (lower 4 bits). If fragment == 0, increments global sequence
  ## number at txl_cntrl_env+84. Formats sequence control field: (seqNum << 4) | frag,
  ## writes 2 bytes at frame[22..23].
  let hdr = cast[ptr MacDataFrameHeaderView](param)
  let seqCtrlByte = uint8(hdr.seqCtrl and 0xFF'u16)
  let fragNum = seqCtrlByte and 0x0F'u8
  let txCtrl = txControlEnv()
  if fragNum == 0:
    txCtrl.seqCounter = txCtrl.seqCounter + 1  # increment sequence number
  let seqNum = txCtrl.seqCounter
  let seqCtrl = (seqNum.uint16 shl 4) or fragNum.uint16
  hdr.seqCtrl = seqCtrl

proc txl_hwdesc_init*() {.exportc, cdecl, noinline.} =
  ## Blob: single `ret`, no-op stub.
  ## noinline + asm barrier: blob calls this as a real function from
  ## txl_cntrl_init; without the barrier GCC elides empty-body calls.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}

proc txl_hwdesc_reset*() {.exportc, cdecl, noinline.} =
  ## Blob: single `ret`, no-op stub.
  ## noinline + asm barrier: blob calls this as a real function from
  ## txl_reset; without the barrier GCC elides empty-body calls.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}

const
  TxlFrameDescCount = 4'u32
  TxlFrameDescSize = 220'u
  TxlFrameLinkCount = 4'u32
  TxlFrameLinkSize = 860'u
  InvalidFrameDescIndex = 0xFFFF_FFFF'u32

proc txl_frame_desc_index(frameDescPointer: pointer): uint32 {.inline.} =
  if frameDescPointer == nil:
    return InvalidFrameDescIndex
  let base = cast[uint](addr txl_frame_desc_storage[0])
  let frameDescAddr = cast[uint](frameDescPointer)
  let total = TxlFrameDescCount.uint * TxlFrameDescSize
  if frameDescAddr < base or frameDescAddr >= base + total:
    return InvalidFrameDescIndex
  let delta = frameDescAddr - base
  if (delta mod TxlFrameDescSize) != 0'u:
    return InvalidFrameDescIndex
  uint32(delta div TxlFrameDescSize)

proc txl_frame_desc_valid(frameDescPointer: pointer): bool {.inline.} =
  txl_frame_desc_index(frameDescPointer) != InvalidFrameDescIndex

proc txl_tx_desc_pointer_plausible(txDescPointer: pointer): bool =
  if txDescPointer == nil:
    return false
  let txDescAddr = cast[uint32](cast[uint](txDescPointer))
  txDescAddr >= 0x2200_0000'u32 and txDescAddr < 0x2210_0000'u32

proc txl_frame_link_valid(frameLinkPointer: pointer): bool {.inline.} =
  if frameLinkPointer == nil:
    return false
  let base = cast[uint](addr txl_frame_pool[0])
  let frameLinkAddr = cast[uint](frameLinkPointer)
  let total = TxlFrameLinkCount.uint * TxlFrameLinkSize
  if frameLinkAddr < base or frameLinkAddr >= base + total:
    return false
  ((frameLinkAddr - base) mod TxlFrameLinkSize) == 0'u

proc txl_frame_list_contains(list: ptr CoList, needle: pointer): bool =
  var node = cast[pointer](list.first)
  var guard = 0'u32
  while node != nil and guard < 16'u32:
    if not txl_tx_desc_pointer_plausible(node):
      inc nimFwDbgFrameGetInvalid
      nimFwDbgFrameGetInvalidNext = pointerAddrU32(node)
      return false
    if node == needle:
      return true
    node = cast[pointer](cast[ptr CoListHdr](node).next)
    inc guard
  false

proc txl_frame_link_list_contains_desc(head: pointer, needle: pointer): bool =
  var linkPtr = head
  var guard = 0'u32
  while linkPtr != nil and guard < TxlFrameLinkCount:
    if not txl_frame_link_valid(linkPtr):
      return false
    let link = hostTxBufferedLinkAt(linkPtr)
    if link.txDesc == needle:
      return true
    linkPtr = link.next
    inc guard
  false

proc txl_frame_desc_active(frameDescPointer: pointer): bool =
  let frameEnv = txFrameEnv()
  if txl_frame_list_contains(addr frameEnv.usedList, frameDescPointer):
    return true
  for ac in 0'u32 ..< 4'u32:
    let acCtrl = txControlAc(ac)
    if acCtrl.current == frameDescPointer:
      return true
    if txl_frame_list_contains(addr acCtrl.pending, frameDescPointer):
      return true
    if txl_frame_link_list_contains_desc(txBackupQueueHeadPtr(ac)[], frameDescPointer):
      return true
  for postponedStaIndex in 0 ..< STA_INFO_TAB_ENTRIES:
    let sta = staInfoForIdx(postponedStaIndex.uint8)
    if txl_frame_list_contains(addr sta.postponedList, frameDescPointer):
      return true
  false

proc txl_frame_rebuild_free_list(): uint32 =
  let frameEnv = txFrameEnv()
  let saved = irqSave()
  frameEnv.freeList.first = nil
  frameEnv.freeList.last = nil
  for frameDescIndex in 0'u32 ..< TxlFrameDescCount:
    let descPtr = cast[pointer](txlFrameDescAt(frameDescIndex))
    if not txl_frame_desc_active(descPtr):
      co_list_push_back(addr frameEnv.freeList, cast[ptr CoListHdr](descPtr))
      inc result
  irqRestore(saved)
  inc nimFwDbgFrameFreeRebuild
  nimFwDbgFrameFreeReclaimed = result

proc txl_frame_free_list_pop(freeList: ptr CoList): ptr CoListHdr =
  let firstPtr = cast[pointer](freeList.first)
  if firstPtr == nil:
    return nil
  if not txl_frame_desc_valid(firstPtr):
    inc nimFwDbgFrameGetInvalid
    nimFwDbgFrameGetInvalidPtr = pointerAddrU32(firstPtr)
    freeList.first = nil
    freeList.last = nil
    if txl_frame_rebuild_free_list() == 0:
      return nil
  let node = freeList.first
  let nextFreeNode = cast[pointer](node.next)
  if nextFreeNode != nil and not txl_frame_desc_valid(nextFreeNode):
    inc nimFwDbgFrameGetInvalid
    nimFwDbgFrameGetInvalidNext = pointerAddrU32(nextFreeNode)
    freeList.first = nil
    freeList.last = nil
  else:
    freeList.first = node.next
    if freeList.first == nil:
      freeList.last = nil
  node.next = nil
  node

proc txl_frame_free_list_push(param: pointer) =
  if not txl_frame_desc_valid(param):
    inc nimFwDbgFrameFreePushInvalid
    nimFwDbgFrameGetInvalidPtr = pointerAddrU32(param)
    return
  co_list_push_back(addr txFrameEnv().freeList, cast[ptr CoListHdr](param))

# TX Frame management
proc txl_frame_init*() {.exportc, cdecl.} =
  ## Initialize TX frame pool (111 instrs in blob).
  ## Blob calls: co_list_init (x2), memset, co_list_push_back, phy_get_ntx (x2).
  ## Inits free/used lists, loops over the private descriptors pushing each onto free list,
  ## then inits ACK descriptor with PHY params and clears buffer control globals.
  let frameEnv = txFrameEnv()
  # 1. co_list_init on free list (txl_frame_env+0) and used list (txl_frame_env+8)
  co_list_init(addr frameEnv.freeList)
  co_list_init(addr frameEnv.usedList)

  # Clear txl_frame_env+16 (pending count)
  frameEnv.postponedCount = 0

  # 2. Loop over 4 private frame descriptors (.LANCHOR0 to +0x370,
  # stride 0xDC=220). Each descriptor links to the exported per-frame pools.
  for frameDescSlotIndex in 0'u32 ..< TxlFrameDescCount:
    let frameDesc = txlFrameDescAt(frameDescSlotIndex)
    let link = txlFrameLinkDescAt(frameDescSlotIndex)
    let hw = txlFrameHwDescAt(frameDescSlotIndex)
    let hwCfm = txlFrameHwCfmAt(frameDescSlotIndex)
    let payload = txlFramePayloadDescAt(frameDescSlotIndex)
    # Blob: checks byte at desc+217 (used flag); if nonzero, skip init
    if frameDesc.postponeFlag != 0:
      discard  # already initialized
    else:
      # memset entire 220-byte descriptor to zero
      discard c_memset(cast[pointer](frameDesc), 0, sizeof(TxlFrameDescSlotView).csize_t)
      frameDesc.bufDesc = cast[pointer](link)
      frameDesc.policy = cast[pointer](payload)
      frameDesc.hwDesc = cast[pointer](hw)
      frameDesc.usedFlag = 0
      hw.txConfirmDescPtr = cast[uint32](cast[uint](hwCfm))
      hw.magic = 0xCAFEBABE'u32
      hw.payloadStart = cast[uint32](hostTxLinkMacHdrAddr(link))
      hw.frameLenToRetryLimitPadding = 0
      hw.chainedThdToAckPolicyPadding0 = 0
      hw.chainedThdToAckPolicyPadding1 = 0
      hw.chainedThdToAckPolicyPadding2 = 0
      payload.magic = 0xBADCAB1E'u32
      # CRITICAL: push descriptor onto free list (blob: co_list_push_back at 0xD8)
      txl_frame_free_list_push(cast[pointer](frameDesc))

  # 3. Post-loop: init txl_buffer_control_24G globals
  let bufCtrl = txBufferControl24G()
  bufCtrl.ackPolicyControl = 0
  bufCtrl.retryLimitControl = 0

  # ACK descriptor at txl_buffer_control_24G base
  bufCtrl.magic = 0xBADCAB1E'u32
  # PHY NTX for stream config
  let ntx1 = phy_get_ntx().uint32
  bufCtrl.ntxConfig = ntx1 shl 14
  let ntx2 = phy_get_ntx().uint32
  let bwMask = (1'u32 shl (ntx2 + 1)) - 1
  bufCtrl.pendingCount = 0
  bufCtrl.policyWord = 0xFFFF0704'u32
  bufCtrl.rateWord = 0x400'u32
  bufCtrl.bwMask = bwMask

  # Clear remaining txl_buffer_control_24G fields (blob: 6× sw zero at offsets)
  bufCtrl.retryRateControl0 = 0
  bufCtrl.retryRateControl1 = 0
  bufCtrl.retryRateControl2 = 0
  bufCtrl.retryTxPowerControl0 = 0
  bufCtrl.retryTxPowerControl1 = 0
  bufCtrl.retryTxPowerControl2 = 0

proc txl_frame_init_desc*(desc: pointer, linkDesc: pointer, hwDesc: pointer, payloadDesc: pointer) {.exportc, cdecl.} =
  ## Initialize a TX frame descriptor. Clears 220 bytes, sets up THD chain
  ## with cafebabe magic, payload descriptor with badcab1e magic, and stores
  ## back-pointers. Always marks descriptor as used (byte 216 = 1).
  ## From disassembly (38 instrs): 4th arg is a pointer to the payload HW
  ## descriptor (stored at desc[88]), not a boolean flag.
  let frameDesc = hostTxDescAt(desc)
  let hw = hostTxHwDescAt(hwDesc)
  let payload = txBufferControlAt(payloadDesc)
  discard c_memset(desc, 0, 220.csize_t)
  # Set THD magic and chain pointer
  hw.magic = 0xCAFEBABE'u32
  hw.payloadStart = cast[uint32](hostTxLinkMacHdrAddr(hostTxLinkDescAt(linkDesc)))
  hw.frameLenToRetryLimitPadding = 0
  hw.chainedThdToAckPolicyPadding0 = 0
  hw.chainedThdToAckPolicyPadding1 = 0
  hw.chainedThdToAckPolicyPadding2 = 0
  # Set payload HW descriptor magic
  payload.magic = 0xBADCAB1E'u32
  # Store back-pointers
  frameDesc.bufDesc = linkDesc
  frameDesc.policy = payloadDesc
  frameDesc.hwDesc = hwDesc
  # Always mark as used
  frameDesc.usedFlag = 1

proc txl_frame_get*(length: uint32): pointer {.exportc, cdecl.} =
  ## Get a TX frame from the internal frame pool.
  ## From blob (txl_frame.o, 0xFA bytes, 87 instrs):
  ##   Pops a descriptor from txl_frame_env free list (CoList at +0).
  ##   On success: reads hwDesc from desc[112], linkDesc from desc[108],
  ##   sets hwDesc[28] = length+4 (with FCS), hwDesc[24] = hwDesc[20]+length-1,
  ##   memcpy(linkDesc+256, txl_buffer_control_24G, 52) to copy rate template,
  ##   calls tpc_get_vif_tx_power_vs_rate(linkDesc[276]) -> stores at linkDesc[292],
  ##   installs the rate template pointer, clears retryLimitControl,
  ##   controlFlags, status, and desc callback fields.
  ##   On failure: logs via g_bl_ops_funcs[4], tries sta_mgmt_aging_postponed_desc
  ##   to free postponed frames, then txl_cntrl_clear_ac(3) to flush VO queue,
  ##   then co_list_cnt to check if frames freed. Retries pop on success.
  ##   Returns descriptor pointer or nil if pool exhausted.
  var callerRA {.noinit.}: uint32
  {.emit: [callerRA, " = (unsigned int)__builtin_return_address(0);"].}
  let frameEnv = txFrameEnv()
  let freeList = addr frameEnv.freeList
  let logFn = blOpsFunc(4)

  var retryAllocation = true
  while retryAllocation:
    retryAllocation = false
    # Pop from free list
    let freeNode = txl_frame_free_list_pop(freeList)
    if freeNode == nil:
      # Log: "[FW] NULL frame for tx %p, len %d, ra=0x%x"
      if logFn != nil:
        cast[proc(fmt: cstring, a1: uint32, a2: uint32, a3: uint32){.cdecl, varargs.}](logFn)(
          "[FW] NULL frame ra=0x%x len=%d cnt=%d\r\n", callerRA, length,
          nimFwDbgFrameGetFails + 1)
      inc nimFwDbgFrameGetFails

      # Try freeing postponed descriptors
      let pendingCount = frameEnv.postponedCount
      if pendingCount != 0:
        let freed = sta_mgmt_aging_postponed_desc(nil, 0)
        if freed != 0:
          # Log: "[FW] Get (%d) frames from desc_postponed"
          if logFn != nil:
            cast[proc(fmt: cstring, cnt: uint32){.cdecl, varargs.}](logFn)(
              "[FW] Get (%d) frames from desc_postponed\r\n", freed)
          retryAllocation = true
          continue  # retry pop

      # Try flushing AC 3 (VO) queue
      txl_cntrl_clear_ac(3)
      let freeCount = co_list_cnt(freeList)
      if freeCount == 0:
        return nil  # truly exhausted
      # Log: "[FW] Get (%d) frames from AC flushing"
      if logFn != nil:
        cast[proc(fmt: cstring, cnt: uint32){.cdecl, varargs.}](logFn)(
          "[FW] Get (%d) frames from AC flushing\r\n", freeCount)
      retryAllocation = true
      continue  # retry pop

    # Success: set up the descriptor
    let desc = hostTxDescAt(cast[pointer](freeNode))
    let descAddr = cast[uint](freeNode)
    let hwDesc = hostTxHwDescAt(desc.hwDesc)

    # Restore desc+108 (linkDesc) if a prior upper-layer TX cfm cleared it.
    # txl_cfm_flush_list nulls desc+108 on the host-data path, which leaves
    # the descriptor in the free list with linkDesc=nil. sm_handle_connection
    # then reads macHdr=desc[108]=nil and writes the deauth at addr 0, while
    # txl_frame_push reads a stale hwDesc[20] and asserts on bit 0.
    if desc.bufDesc == nil:
      let frameDescPoolIndex = txl_frame_desc_index(cast[pointer](freeNode))
      if frameDescPoolIndex < TxlFrameDescCount:
        desc.bufDesc = cast[pointer](txlFrameLinkDescAt(frameDescPoolIndex))
    let linkDesc = hostTxLinkDescAt(desc.bufDesc)

    # Set buffer length fields in hwDesc. Internal frame descriptors always
    # transmit from their link descriptor's MAC header buffer; restore this
    # invariant on allocation so stale DMA state from a prior use cannot poison
    # txl_frame_push.
    let expectedHdrPtr = cast[uint32](cast[uint](addr linkDesc.macHeader[0]))
    let oldBufPtr = hwDesc.payloadStart
    if nimFwDbgFrameTraceCount < 16'u32 or oldBufPtr != expectedHdrPtr:
      nimFwTrace2U32("[WIFI-NIMFW] frame_get ",
                     length or (nimFwDbgFrameTraceCount shl 16),
                     cast[uint32](descAddr))
      nimFwTrace2U32("[WIFI-NIMFW] frame_hdr ", oldBufPtr, expectedHdrPtr)
      inc nimFwDbgFrameTraceCount
    hwDesc.payloadStart = expectedHdrPtr
    let curBufPtr = expectedHdrPtr  # hwDesc[20]
    hwDesc.frameLen = length + 4     # data length + FCS
    hwDesc.payloadEnd = curBufPtr + length - 1  # adjusted end

    # Copy 52-byte rate/control template from txl_buffer_control_24G into linkDesc+256
    let rateTemplate = hostTxRateTemplate(linkDesc)
    discard c_memcpy(cast[pointer](rateTemplate),
                     cast[pointer](addr txl_buffer_control_24G[0]), 52)

    # Get per-VIF TX power: rate value at linkDesc+0x114 (276)
    # Blob passes the raw 32-bit word as the only argument (a0).  Our Nim
    # signature is (vifIdx, rate) -> the body only reads `rate` (a1), so we
    # pass vifIdx=0 and rate=full word to match the body's arithmetic.
    let rateVal = rateTemplate.rateWord
    let txPower = tpc_get_vif_tx_power_vs_rate(0'u8, rateVal)
    rateTemplate.txPower = txPower

    # Set template pointer and clear control fields
    hwDesc.chainedThd = cast[pointer](rateTemplate)
    hwDesc.retryLimitControl = 0
    hwDesc.controlFlags = 0
    hwDesc.status = 0
    desc.callback = nil
    desc.callbackArg = nil
    # CRITICAL: clear desc+216 (host-TX active flag set by ipc_emb_tx_evt). If a
    # frame descriptor is recycled with desc+216 still at 1, confirmation routes
    # to the upper-layer path instead of txl_frame_cfm. Internal-frame callbacks
    # at desc+208 then never fire.
    nimFwDbgFrameGetUsedBefore = desc.usedFlag.uint32
    desc.usedFlag = 0
    desc.queueFirst = nil
    inc nimFwDbgFrameGet
    return cast[pointer](freeNode)
  nil

proc txl_frame_push*(param: pointer, ac: uint8): uint8 {.exportc, cdecl, noinline, discardable.} =
  ## Push a frame for transmission.
  ## From disassembly (47 instrs): loads hwDesc from param[112], asserts THD
  ## pointer (hwDesc[20]) bit 0 is clear, masks bits [22:15] of hwDesc[60],
  ## clears transient HW descriptor state, conditionally sets
  ## ackPolicyControl based on frame type,
  ## then tail-calls txl_cntrl_push.
  let desc = hostTxDescAt(param)
  inc nimFwDbgTxPushCalls
  let hwDesc = hostTxHwDescAt(desc.hwDesc)
  var thdField = hwDesc.payloadStart
  if desc.bufDesc != nil:
    let linkDesc = hostTxLinkDescAt(desc.bufDesc)
    let expectedHdrPtr = cast[uint32](cast[uint](addr linkDesc.macHeader[0]))
    if thdField != expectedHdrPtr:
      nimFwTrace2U32("[WIFI-NIMFW] frame_push_fix ", thdField, expectedHdrPtr)
      thdField = expectedHdrPtr
      hwDesc.payloadStart = expectedHdrPtr
  if (thdField and 1) != 0:
    assert_err("txl_frame.c", "txl_frame.c", 316)
  # Mask bits [22:15] of control flags
  var ctrlFlags = hwDesc.controlFlags
  ctrlFlags = ctrlFlags and 0xFF87FFFF'u32
  let hdr = macDataFrameAt(cast[pointer](thdField.uint))
  hwDesc.secondaryTxHwDescPtr = 0
  hwDesc.secondaryDescToStatusPadding = 0
  hwDesc.controlFlags = ctrlFlags
  # Unicast data frames require MAC ACK policy bit 9; multicast/control paths do not.
  let typeBits = cast[uint8](hdr.frameControl and 0x000C'u16)  # bits [3:2]
  if typeBits == 4 or (hdr.addr1[0] and 1) != 0:
    hwDesc.ackPolicyControl = 0
  else:
    hwDesc.ackPolicyControl = 512  # 0x200
  hwDesc.confirmStatus = 0
  return txl_cntrl_push_int(param, ac)  # blob: tail-call txl_cntrl_push_int (not txl_cntrl_push)

proc txl_frame_push_force*(param: pointer, ac: uint8) {.exportc, cdecl.} =
  ## Force push a frame for transmission.
  ## From disassembly (41 instrs): similar to txl_frame_push but unconditionally
  ## sets ackPolicyControl from the destination address multicast bit,
  ## clears confirmStatus,
  ## then tail-calls txl_cntrl_push_int_force.
  let desc = hostTxDescAt(param)
  let hwDesc = hostTxHwDescAt(desc.hwDesc)
  var thdField = hwDesc.payloadStart
  if desc.bufDesc != nil:
    let linkDesc = hostTxLinkDescAt(desc.bufDesc)
    let expectedHdrPtr = cast[uint32](cast[uint](addr linkDesc.macHeader[0]))
    if thdField != expectedHdrPtr:
      nimFwTrace2U32("[WIFI-NIMFW] frame_force_fix ", thdField, expectedHdrPtr)
      thdField = expectedHdrPtr
      hwDesc.payloadStart = expectedHdrPtr
  if (thdField and 1) != 0:
    assert_err("txl_frame.c", "txl_frame.c", 367)
  # Mask bits [22:15] of control flags
  var ctrlFlags = hwDesc.controlFlags
  ctrlFlags = ctrlFlags and 0xFF87FFFF'u32
  let hdr = macDataFrameAt(cast[pointer](thdField.uint))
  hwDesc.secondaryTxHwDescPtr = 0
  hwDesc.secondaryDescToStatusPadding = 0
  hwDesc.controlFlags = ctrlFlags
  # MAC ACK policy bit 9 is set only when the destination address is unicast.
  let notBit0 = if (hdr.addr1[0] and 1) == 0: 1'u32 else: 0'u32
  hwDesc.ackPolicyControl = notBit0 shl 9  # 0 or 512
  hwDesc.confirmStatus = 0
  discard txl_cntrl_push_int_force(param, ac)

proc txl_frame_cfm*(param: pointer) {.exportc, cdecl.} =
  ## Handle TX frame confirmation.
  ## Blob behavior: push the descriptor on txl_frame_env+8, then signal
  ## the TX frame confirm event (0x80000) for txl_frame_evt.
  inc nimFwDbgFrameCfm
  let desc = hostTxDescAt(param)
  if desc.hwDesc != nil:
    noteMgmtTxConfirm(desc, hostTxHwDescAt(desc.hwDesc).confirmStatus, 1'u32)
  let linkDesc = desc.bufDesc
  if linkDesc != nil:
    let fcTrace = hostTxLinkDescAt(linkDesc).macHeader[0]
    if nimFwMgmtFcTrace(fcTrace):
      let hwDesc = hostTxHwDescAt(desc.hwDesc)
      nimFwTrace2U32("[WIFI-NIMFW] frame_cfm ",
                     pointerAddrU32(param),
                     cast[uint32](cast[uint](hwDesc)))
      when defined(bl808WifiConnectTrace):
        nimFwConnectTrace2U32("[WIFI-CT] frame_cfm ",
                              hwDesc.confirmStatus,
                              hwDesc.status)
    when defined(bl808WifiScanTrace):
      if fcTrace == 0x40'u8:
        let hwDesc = hostTxHwDescAt(desc.hwDesc)
        nimFwTrace2U32("[WIFI-SCAN] probe_cfm ",
                       hwDesc.confirmStatus,
                       hwDesc.status)
  let frameEnv = txFrameEnv()
  if txl_frame_desc_valid(param):
    co_list_push_back(addr frameEnv.usedList, cast[ptr CoListHdr](param))
    ke_evt_set(0x00080000'u32)
  else:
    inc nimFwDbgFrameFreePushInvalid
    nimFwDbgFrameGetInvalidPtr = pointerAddrU32(param)

proc txl_frame_release*(param: pointer) {.exportc, cdecl.} =
  ## Release a TX frame descriptor. Blob (txl_frame_release, 0x44 bytes):
  ##   if (frame[216] == 0)                         ; internal alloc (valid==0)
  ##     co_list_push_back(&txl_frame_env, frame)   ; return to free list
  ##   if (a1 != 0 && frame[208] != 0)              ; optional callback
  ##     tail-call frame[208](frame[212], 0)
  ##   return
  if param == nil: return
  inc nimFwDbgFrameRelease
  let desc = hostTxDescAt(param)
  var doCallback {.noinit.}: uint32
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", doCallback, ") );"].}
  if desc.usedFlag == 0:
    # Internally allocated frame: return to the frame free list at txl_frame_env.
    txl_frame_free_list_push(param)
  if doCallback != 0:
    let frameDoneCallbackPtr = desc.callback
    if frameDoneCallbackPtr != nil:
      let frameDoneCallbackArg = desc.callbackArg
      cast[proc(buf: pointer, flag: uint32) {.cdecl.}](frameDoneCallbackPtr)(frameDoneCallbackArg, 0)

proc txlFrameConfirmPending(frameEnv: ptr TxFrameEnvView): bool {.inline.} =
  frameEnv.usedList.first != nil

proc txl_frame_evt*() {.exportc, cdecl.} =
  ## TX frame event handler.
  ## From disassembly (53 instrs): Processes all pending TX frame confirmations.
  ## Clears the TX frame event (0x80000), then loops popping descriptors from
  ## the pending confirm list. For each descriptor:
  ##   1. Decrements the global frame pending counter (txl_cntrl_env[80])
  ##   2. If desc has a callback (desc[208] != nil), invokes it with
  ##      (desc[212], hwDesc[64]) as arguments
  ##   3. If desc has retry flag (desc[218] != 0), clears it and re-loops
  ##   4. If desc is not internally allocated (desc[216] == 0), returns it
  ##      to the free list via co_list_push_back
  ##
  ## Assembly trace:
  ##   lui a0, 0x80; call ke_evt_clear  # clear event 0x80000
  ##   loop:
  ##     csrrci s1,mstatus,8            # irqSave
  ##     call co_list_pop_front(pendingList)
  ##     restore irq
  ##     if nil: return
  ##     decrement txl_cntrl_env[80]    # pending count
  ##     if desc[208] (callback ptr):
  ##       call desc[208](desc[212], hwDesc.first[64])
  ##       if desc[218]: clear, loop
  ##     if !desc[216]: push_back to freeList
  ##     loop
  # Clear the TX frame confirm event
  inc nimFwDbgFrameEvtEnter
  ke_evt_clear(0x00080000'u32)
  let txCtrl = txControlEnv()
  let frameEnv = txFrameEnv()
  while txlFrameConfirmPending(frameEnv):
    # Pop from pending list under interrupt protection
    let saved = irqSave()
    let node = co_list_pop_front(addr frameEnv.usedList)
    irqRestore(saved)
    if node == nil:
      return
    inc nimFwDbgFrameEvtPop
    let desc = hostTxDescAt(node)
    let evtLinkDesc = desc.bufDesc
    if evtLinkDesc != nil:
      let evtLink = hostTxLinkDescAt(evtLinkDesc)
      if evtLink.macHeader[0] == 0x48'u8 and evtLink.macHeader[1] == 0x01'u8:
        inc nimFwDbgNullFrameEvtSeen
        nimFwDbgNullFrameEvtDesc = pointerAddrU32(cast[pointer](node))
        nimFwDbgNullFrameEvtCbPtr =
          cast[uint32](cast[uint](desc.callback))
        if desc.callback == nil:
          inc nimFwDbgNullFrameEvtCbNil
    if desc.hwDesc != nil:
      noteMgmtTxConfirm(desc, hostTxHwDescAt(desc.hwDesc).confirmStatus, 2'u32)
    # Decrement pending frame counter at txl_cntrl_env[80].
    if txCtrl.packetCounter > 0:
      txCtrl.packetCounter = txCtrl.packetCounter - 1
    # Check for callback at desc[208]
    let callbackPtr = desc.callback
    if callbackPtr != nil:
      inc nimFwDbgFrameEvtCallback
      # Blob passes desc[112][64] directly as the callback status.
      let thdStatus = hostTxHwDescAt(desc.hwDesc).confirmStatus
      let frameCallbackArg = desc.callbackArg
      type FrameCbFn = proc(arg: pointer, status: uint32) {.cdecl.}
      let frameEventCallback = cast[FrameCbFn](callbackPtr)
      frameEventCallback(frameCallbackArg, thdStatus)
      # Check retry flag at desc[218]
      if desc.retryFlag != 0:
        desc.retryFlag = 0
        continue  # re-process (loop back)
    # If not internally allocated (desc[216] == 0), return to free list
    if desc.usedFlag == 0:
      inc nimFwDbgFrameEvtFreeRet
      # Return to internal free frame list.
      txl_frame_free_list_push(cast[pointer](node))
    else:
      inc nimFwDbgFrameEvtUsedSkip

proc txl_frame_send_null_frame*(staIdx: uint8, cfmCallback: pointer, cfmArg: uint32): uint8 {.exportc, cdecl, discardable.} =
  ## Build and send a null data frame (for PS notification).
  ## Blob ABI is (staIdx, cfmCallback, cfmArg), not (vifIdx, staIdx, pwrMgt).
  ## The VIF index is read from sta_info_tab[staIdx]+39 and the callback/arg
  ## are stored verbatim at desc+208/212 for txl_frame_cfm.
  var nfRA {.noinit.}: uint32
  {.emit: [nfRA, " = (unsigned int)__builtin_return_address(0);"].}
  inc nimFwDbgNullFrameCalls
  nimFwDbgNullFrameCallerRA = nfRA
  let sta = staInfoForIdx(staIdx)
  let vifIdx = sta.instNbr
  let vif = vifChannelForIdx(vifIdx)
  let vifEntry = cast[pointer](vif)
  let staMacAddr = cast[pointer](addr sta.macAddr[0])
  # Allocate frame (24 bytes for null data header)
  # Blob passes a0=24 (frame size) and a1=staIdx (original param, used as length hint)
  let frame = txl_frame_get(24)
  if frame == nil:
    return 1
  let desc = hostTxDescAt(frame)
  tpc_update_frame_tx_power(vifEntry, frame)
  let hdr = hostTxDataHeader(desc)
  # Build null data frame header at linkDesc+348.
  hdr.frameControl = 0x0148'u16  # null data, To-DS
  hdr.duration = 0
  # Addr1 (RA) = STA MAC address (BSSID for to-DS frame)
  discard c_memcpy(addr hdr.addr1[0], staMacAddr, 6.csize_t)
  # Addr2 (SA) = VIF MAC address (at vif_info+80)
  let vifMacAddr = cast[pointer](addr vif.macAddr[0])
  discard c_memcpy(addr hdr.addr2[0], vifMacAddr, 6.csize_t)
  # Addr3 (DA) = STA MAC address
  discard c_memcpy(addr hdr.addr3[0], staMacAddr, 6.csize_t)
  # Sequence number from the global TX control counter.
  hdr.seqCtrl = nextTxSeqCtrl()
  # Store callback info for confirmation
  desc.callback = cfmCallback
  desc.callbackArg = cast[pointer](cfmArg.uint)
  nimFwDbgNullFrameDescLast = pointerAddrU32(frame)
  nimFwDbgNullFrameBufLast = pointerAddrU32(desc.bufDesc)
  nimFwDbgNullFrameFcLast =
    hdr.frameControl.uint32 or (hdr.seqCtrl.uint32 shl 16)
  nimFwDbgNullFrameVifSta =
    staIdx.uint32 or (vifIdx.uint32 shl 8) or (vif.state.uint32 shl 16)
  if cfmCallback != nil:
    inc nimFwDbgNullFrameCbSet
    nimFwDbgNullFrameCbSetPtr = cast[uint32](cast[uint](cfmCallback))
  # Store VIF and STA info in descriptor
  desc.staInfoIdx = staIdx
  desc.vifIdx = vifIdx
  # Push frame for transmission on AC 3 (VO)
  let pushRc = txl_frame_push(frame, 3)
  let publicRc = (pushRc xor 1'u8) and 0xFF'u8
  nimFwDbgNullFramePushRc = pushRc.uint32
  nimFwDbgNullFrameReturn = publicRc.uint32
  nimFwDbgNullFrameBufLast = pointerAddrU32(desc.bufDesc)
  if desc.bufDesc != nil:
    let pushedHdr = hostTxDataHeader(desc)
    nimFwDbgNullFrameFcLast =
      pushedHdr.frameControl.uint32 or (pushedHdr.seqCtrl.uint32 shl 16)
  return publicRc

const WifiTxFrameSuccessfulBit = 1'u32 shl 23

proc wifi_nimfw_coex_force_ble_role*() {.exportc, cdecl.}
{.emit: """
__attribute__((weak)) unsigned long nim_ble_coex_wifi_tx_window_enter(void) { return 1; }
__attribute__((weak)) void nim_ble_coex_wifi_tx_window_leave(void) {}
__attribute__((weak)) unsigned long nim_ble_coex_wifi_rf_reclaim_needed(void) { return 0; }
""".}
proc nim_ble_coex_wifi_tx_window_enter*(): uint32 {.importc, cdecl.}
proc nim_ble_coex_wifi_tx_window_leave*() {.importc, cdecl.}
proc nim_ble_coex_wifi_rf_reclaim_needed*(): uint32 {.importc, cdecl.}

proc wifi_nimfw_null_frame_cfm(arg: pointer, status: uint32) {.cdecl.} =
  discard arg
  inc nimFwDbgNullFrameCfm
  nimFwDbgNullFrameLastStatus = status
  nimFwDbgBleWifiTxCfmBcn = wlanCoexControl()
  nimFwDbgBleWifiTxCfmPti = wlanCoexPti()
  if (status and WifiTxFrameSuccessfulBit) != 0'u32:
    inc nimFwDbgNullFrameAckOk
  else:
    inc nimFwDbgNullFrameAckFail
  if nimFwBleWifiRoleWindowActive != 0'u32:
    wifi_nimfw_coex_force_ble_role()

proc wifi_nimfw_send_checked_null_frame(staIdx: uint8): uint8 =
  ## Send one STA null-data frame using the same descriptor construction path
  ## as the firmware-facing txl_frame_send_null_frame entry point.  Keeping the
  ## public keepalive API on that path avoids a second frame builder drifting
  ## from the reference layout.
  let beforePostponed = txFrameEnv().postponedCount
  nimFwDbgKeepalivePostBefore = beforePostponed
  nimFwDbgKeepaliveTxintBefore = nimFwDbgNullFrameTxIntSeen
  nimFwDbgKeepaliveFakeBefore = nimFwDbgNullFrameFakeSeen
  nimFwDbgKeepalivePayBefore = nimFwDbgNullFramePaySeen
  nimFwDbgKeepaliveCbBefore = nimFwDbgNullFrameCbSet
  let nullFrameStatus = txl_frame_send_null_frame(
    staIdx, cast[pointer](wifi_nimfw_null_frame_cfm), 0)
  let afterPostponed = txFrameEnv().postponedCount
  nimFwDbgKeepaliveRc = nullFrameStatus.uint32
  nimFwDbgKeepalivePostAfter = afterPostponed
  nimFwDbgKeepaliveTxintAfter = nimFwDbgNullFrameTxIntSeen
  nimFwDbgKeepaliveFakeAfter = nimFwDbgNullFrameFakeSeen
  nimFwDbgKeepalivePayAfter = nimFwDbgNullFramePaySeen
  nimFwDbgKeepaliveCbAfter = nimFwDbgNullFrameCbSet
  if nullFrameStatus == 0'u8 and afterPostponed > beforePostponed:
    return 2'u8
  nullFrameStatus

proc wifi_nimfw_send_checked_qosnull_frame(staIdx: uint8): uint8 =
  ## Send one STA QoS-null frame through the reference firmware QoS-null
  ## builder. This exercises the normal QoS management-frame descriptor layout
  ## while preserving the same confirmation counters used by keepalive tests.
  let beforePostponed = txFrameEnv().postponedCount
  nimFwDbgKeepalivePostBefore = beforePostponed
  nimFwDbgKeepaliveTxintBefore = nimFwDbgNullFrameTxIntSeen
  nimFwDbgKeepaliveFakeBefore = nimFwDbgNullFrameFakeSeen
  nimFwDbgKeepalivePayBefore = nimFwDbgNullFramePaySeen
  nimFwDbgKeepaliveCbBefore = nimFwDbgNullFrameCbSet
  let qosNullFrameStatus = txl_frame_send_qosnull_frame(
    staIdx, 0'u16, cast[pointer](wifi_nimfw_null_frame_cfm), 0)
  let afterPostponed = txFrameEnv().postponedCount
  nimFwDbgKeepaliveRc = qosNullFrameStatus.uint32
  nimFwDbgKeepalivePostAfter = afterPostponed
  nimFwDbgKeepaliveTxintAfter = nimFwDbgNullFrameTxIntSeen
  nimFwDbgKeepaliveFakeAfter = nimFwDbgNullFrameFakeSeen
  nimFwDbgKeepalivePayAfter = nimFwDbgNullFramePaySeen
  nimFwDbgKeepaliveCbAfter = nimFwDbgNullFrameCbSet
  if qosNullFrameStatus == 0'u8 and afterPostponed > beforePostponed:
    return 2'u8
  qosNullFrameStatus

proc wifi_nimfw_actual_postponed_count(): uint32 =
  var total = 0'u32
  for postponedCountStaIndex in 0'u8 ..< STA_INFO_TAB_ENTRIES.uint8:
    let sta = staInfoForIdx(postponedCountStaIndex)
    total += co_list_cnt(addr sta.postponedList)
  total

proc wifi_nimfw_reconcile_postponed_count() =
  let frameEnv = txFrameEnv()
  let actual = wifi_nimfw_actual_postponed_count()
  if frameEnv.postponedCount != actual:
    inc nimFwDbgPostponedReconcile
    nimFwDbgPostponedReconcileOld = frameEnv.postponedCount
    nimFwDbgPostponedReconcileNew = actual
    frameEnv.postponedCount = actual

proc wifi_nimfw_service_sta_postponed*(limit: uint32): uint32 {.exportc, cdecl.} =
  ## Bounded service hook for STA-mode frames deferred by txl_cntrl_push_int
  ## while the channel scheduler was temporarily not admitting TX.
  inc nimFwDbgPostponedServiceCalls
  let maxFrames = if limit == 0'u32: 1'u32 else: limit
  var sent = 0'u32
  for staPostponedVifIndex in 0'u8 ..< MAX_VIFS.uint8:
    let vif = vifChannelForIdx(staPostponedVifIndex)
    let vifEntry = cast[pointer](vif)
    if vif.vifType == VIF_TYPE_STA and vif.state != 0'u8:
      let staEntry = cast[pointer](staInfoForIdx(vif.staIdx))
      if txl_cntrl_tx_check(vifEntry):
        let remaining = maxFrames - sent
        let postponedFramesSent =
          sta_mgmt_send_postponed_frame(vifEntry, staEntry, remaining)
        sent += postponedFramesSent
        nimFwDbgPostponedServiceSent += postponedFramesSent
        if sent >= maxFrames:
          break
  if sent == 0'u32:
    wifi_nimfw_reconcile_postponed_count()
  sent

proc rfc_channel_ops*(channel: uint32) {.exportc, cdecl.}

var
  nimFwStaTxPreparedBand: uint8
  nimFwStaTxPreparedChanType: uint8
  nimFwStaTxPreparedPrimaryFreq: uint16
  nimFwStaTxPreparedCenterFreq1: uint16
  nimFwStaTxPreparedCenterFreq2: uint16

proc wifi_nimfw_prepare_sta_tx_channel*() {.exportc, cdecl.} =
  ## Restore the WiFi RF channel before STA TX when another radio user, such as
  ## BLE, may have borrowed the shared RF programming path.
  ## rf_init() calls the cold modem init path only on the first process call and
  ## uses restore on later calls. BLE coexistence still needs a real RF reclaim
  ## because BLE writes the shared 0x2000xxxx RF plane between WiFi transmissions.
  let sm = smEnvView()
  var band = 0'u8
  var chanType = 0'u8
  var primaryFreq = sm.primaryFreq
  var centerFreq1 = sm.centerFreq
  var centerFreq2 = 0'u16
  var txPower = 0'u8
  var source = 0'u32
  var sourceVif = 0xFFFFFFFF'u32
  if primaryFreq != 0'u16 and centerFreq1 != 0'u16:
    source = 1'u32
  if primaryFreq == 0'u16 or centerFreq1 == 0'u16:
    for staTxChannelVifIndex in 0'u8 ..< MAX_VIFS.uint8:
      let vif = vifChannelForIdx(staTxChannelVifIndex)
      if vif.vifType == VIF_TYPE_STA and vif.state != 0'u8:
        sourceVif = staTxChannelVifIndex.uint32 or
          (vif.state.uint32 shl 8) or
          (vif.vifType.uint32 shl 16)
        if vif.chanCtxt != nil:
          let ctxt = cast[ptr ChanCtxtView](vif.chanCtxt)
          band = ctxt.channel.band
          chanType = ctxt.channel.chanType
          primaryFreq = ctxt.channel.primFreq
          centerFreq1 = ctxt.channel.centerFreq1
          centerFreq2 = ctxt.channel.centerFreq2
          txPower = ctxt.channel.txPower
          source = 2'u32
          break
        if vif.channelFreqPair != 0'u32:
          primaryFreq = uint16(vif.channelFreqPair and 0xFFFF'u32)
          centerFreq1 = uint16((vif.channelFreqPair shr 16) and 0xFFFF'u32)
          source = 3'u32
          break
  nimFwDbgStaTxChannelSource = source
  nimFwDbgStaTxChannelReq0 = primaryFreq.uint32 or (centerFreq1.uint32 shl 16)
  nimFwDbgStaTxChannelReq1 = centerFreq2.uint32 or
    (band.uint32 shl 16) or (chanType.uint32 shl 24) or (txPower.uint32 shl 28)
  nimFwDbgStaTxChannelVif = sourceVif
  if primaryFreq != 0'u16 and centerFreq1 != 0'u16:
    if nimFwBleWifiRoleWindowEnabled == 0'u32:
      inc nimFwDbgStaTxRfRestore
      wifi_hosal_rf_turn_on()
      wifiRfCoreInit(40000000'u32)
      phy_init(nil)
      phySetChannel(band, chanType, primaryFreq, centerFreq1, centerFreq2, txPower)
      return
    let reclaimNeeded = nim_ble_coex_wifi_rf_reclaim_needed() != 0'u32
    let channelChanged =
      nimFwStaTxPreparedBand != band or
      nimFwStaTxPreparedChanType != chanType or
      nimFwStaTxPreparedPrimaryFreq != primaryFreq or
      nimFwStaTxPreparedCenterFreq1 != centerFreq1 or
      nimFwStaTxPreparedCenterFreq2 != centerFreq2
    if reclaimNeeded or channelChanged:
      inc nimFwDbgStaTxRfRestore
      wifi_hosal_rf_turn_on()
      if reclaimNeeded:
        inc nimFwDbgStaTxRfFullRestore
        wifiRfCoreInitMode(40000000'u32, wifiBleCoex)
        phy_init(nil)
      phySetChannel(band, chanType, primaryFreq, centerFreq1, centerFreq2, txPower)
      nimFwStaTxPreparedBand = band
      nimFwStaTxPreparedChanType = chanType
      nimFwStaTxPreparedPrimaryFreq = primaryFreq
      nimFwStaTxPreparedCenterFreq1 = centerFreq1
      nimFwStaTxPreparedCenterFreq2 = centerFreq2

proc wifi_nimfw_coex_force_wifi_role*(): uint32 {.exportc, cdecl.} =
  ## Grant the shared RF/PTA fabric to WiFi for one active STA TX window.
  ## These role constants match the BL808 SDK wifi_bt_coex_force_wlan_impl
  ## PTI-priority force mode. Use the transient window only while a WiFi frame is
  ## outstanding; BLE scheduling is paused through the callback below.
  const
    WifiRoleCtrl = 0x50000013'u32
    WifiRoleCtrl2 = 0'u32
  if nimFwBleWifiRoleWindowActive != 0'u32:
    nimFwDbgBleWifiRoleLastCtrl = ptaCoexControl()
    nimFwDbgBleWifiRoleLastCtrl2 = ptaCoexControl2()
    nimFwDbgBleWifiRoleLastMirror = ptaCoexMirror()
    return 1'u32
  if nim_ble_coex_wifi_tx_window_enter() == 0'u32:
    nimFwDbgBleWifiRoleLastCtrl = ptaCoexControl()
    nimFwDbgBleWifiRoleLastCtrl2 = ptaCoexControl2()
    nimFwDbgBleWifiRoleLastMirror = ptaCoexMirror()
    return 0'u32
  nimFwBleWifiRoleWindowActive = 1'u32
  ptaCoexClear()
  wlanCoexWriteControl(0x00000F48'u32)
  wlanCoexWritePti(0xFFFFFFFF'u32)
  wlanCoexWriteControl(0x00000F49'u32)
  ptaCoexWriteControl(WifiRoleCtrl)
  ptaCoexWriteControl2(WifiRoleCtrl2)
  ptaCoexWriteMirror(WifiRoleCtrl)
  nimFwDbgBleWifiTxPreBcn = wlanCoexControl()
  nimFwDbgBleWifiTxPrePti = wlanCoexPti()
  nimFwDbgBleWifiTxPreStat = wlanCoexStatus()
  nimFwDbgBleWifiRoleLastCtrl = ptaCoexControl()
  nimFwDbgBleWifiRoleLastCtrl2 = ptaCoexControl2()
  nimFwDbgBleWifiRoleLastMirror = ptaCoexMirror()
  inc nimFwDbgBleWifiRoleEnter
  1'u32

proc wifi_nimfw_coex_force_ble_role*() {.exportc, cdecl.} =
  ## Return the shared RF/PTA fabric to BLE/BT after the WiFi TX confirmation.
  ## Mirrors the BL808 SDK wifi_bt_coex_force_bt_impl PTI-priority force mode.
  const
    BtRoleCtrl = 0x50000013'u32
    BtRoleCtrl2 = 0'u32
  ptaCoexClear()
  wlanCoexWriteControl(0x00000048'u32)
  wlanCoexWritePti(0'u32)
  wlanCoexWriteControl(0x00000049'u32)
  ptaCoexWriteControl(BtRoleCtrl)
  ptaCoexWriteControl2(BtRoleCtrl2)
  ptaCoexWriteMirror(BtRoleCtrl)
  nimFwBleWifiRoleWindowActive = 0'u32
  nim_ble_coex_wifi_tx_window_leave()
  nimFwDbgBleWifiRoleLastCtrl = ptaCoexControl()
  nimFwDbgBleWifiRoleLastCtrl2 = ptaCoexControl2()
  nimFwDbgBleWifiRoleLastMirror = ptaCoexMirror()
  inc nimFwDbgBleWifiRoleLeave

proc wifi_nimfw_set_sta_tx_channel_prepare_enabled*(enabled: uint32)
    {.exportc, cdecl.} =
  nimFwStaTxChannelPrepareEnabled = if enabled == 0'u32: 0'u32 else: 1'u32

proc wifi_nimfw_set_ble_wifi_role_window_enabled*(enabled: uint32)
    {.exportc, cdecl.} =
  nimFwBleWifiRoleWindowEnabled = if enabled == 0'u32: 0'u32 else: 1'u32
  if nimFwBleWifiRoleWindowEnabled == 0'u32 and
      nimFwBleWifiRoleWindowActive != 0'u32:
    wifi_nimfw_coex_force_ble_role()

proc wifi_nimfw_set_keepalive_qosnull_enabled*(enabled: uint32)
    {.exportc, cdecl.} =
  nimFwKeepaliveQosNullEnabled = if enabled == 0'u32: 0'u32 else: 1'u32

proc wifi_nimfw_send_sta_null_frame*(): uint8 {.exportc, cdecl.} =
  ## Send one STA-mode null-data keepalive frame through the real WiFi TX path.
  ## This is used by coexistence validation to prove WiFi is transmitting while
  ## BLE is connected, without depending on a TCP/IP stack in Nim firmware mode.
  if nimFwKeepaliveInFlight != 0'u32:
    if nimFwDbgNullFrameCfm >= nimFwKeepaliveTargetCfm:
      nimFwKeepaliveInFlight = 0
      if nimFwBleWifiRoleWindowActive != 0'u32:
        wifi_nimfw_coex_force_ble_role()
    else:
      const KeepaliveStaleMacTicks = 250_000'u32
      let age = regRead(MACHW_TIMLO_REG) - nimFwKeepaliveStartedAt
      if age >= KeepaliveStaleMacTicks:
        inc nimFwDbgTxStalledInternalRecover
        nimFwDbgTxRecoverAc = 3
        nimFwDbgTxRecoverPending = txFrameEnv().postponedCount
        txl_cntrl_clear_ac(3)
        nimFwKeepaliveInFlight = 0
        nimFwKeepaliveTargetCfm = nimFwDbgNullFrameCfm
        if nimFwBleWifiRoleWindowActive != 0'u32:
          wifi_nimfw_coex_force_ble_role()
      else:
        if nimFwBleWifiRoleWindowEnabled != 0'u32:
          if wifi_nimfw_coex_force_wifi_role() == 0'u32:
            return 2'u8
        discard wifi_nimfw_service_sta_postponed(1)
        nimFwDbgBleWifiTxTrigStat = regRead(0x24B08078'u)
        nimFwDbgBleWifiTxTrigAgg = regRead(0x24B0808C'u)
        txl_transmit_trigger()
        inc nimFwDbgNullFrameBusyPsCheck
        return 2'u8

  if txFrameEnv().postponedCount != 0:
    discard wifi_nimfw_service_sta_postponed(1)
    if txFrameEnv().postponedCount != 0:
      inc nimFwDbgNullFramePostponed
      return 2'u8

  for keepaliveStaVifIndex in 0'u8 ..< MAX_VIFS.uint8:
    let vif = vifChannelForIdx(keepaliveStaVifIndex)
    if vif.vifType == 0'u8 and vif.state != 0'u8:
      if not txl_cntrl_tx_check(cast[pointer](vif)):
        inc nimFwDbgNullFrameBusyTxCheck
        return 2'u8
      if nimFwBleWifiRoleWindowEnabled != 0'u32:
        if wifi_nimfw_coex_force_wifi_role() == 0'u32:
          return 2'u8
      if nimFwStaTxChannelPrepareEnabled != 0'u32:
        wifi_nimfw_prepare_sta_tx_channel()
      let beforeCfm = nimFwDbgNullFrameCfm
      let keepaliveStatus =
        if nimFwBleWifiRoleWindowEnabled != 0'u32 or
            nimFwKeepaliveQosNullEnabled != 0'u32:
          wifi_nimfw_send_checked_qosnull_frame(vif.staIdx)
        else:
          wifi_nimfw_send_checked_null_frame(vif.staIdx)
      if keepaliveStatus != 0'u8:
        if nimFwBleWifiRoleWindowActive != 0'u32:
          wifi_nimfw_coex_force_ble_role()
        return keepaliveStatus
      if nimFwDbgNullFrameCfm > beforeCfm:
        return 0'u8
      nimFwKeepaliveInFlight = 1
      nimFwKeepaliveStartedAt = regRead(MACHW_TIMLO_REG)
      nimFwKeepaliveTargetCfm = beforeCfm + 1
      inc nimFwDbgNullFrameQueued
      discard wifi_nimfw_service_sta_postponed(1)
      nimFwDbgBleWifiTxTrigStat = regRead(0x24B08078'u)
      nimFwDbgBleWifiTxTrigAgg = regRead(0x24B0808C'u)
      txl_transmit_trigger()
      return 0'u8
  1'u8

proc wifi_nimfw_null_frame_ack_ok_count*(): uint32 {.exportc, cdecl.} =
  nimFwDbgNullFrameAckOk

proc wifi_nimfw_null_frame_cfm_count*(): uint32 {.exportc, cdecl.} =
  nimFwDbgNullFrameCfm

proc wifi_nimfw_null_frame_fail_count*(): uint32 {.exportc, cdecl.} =
  nimFwDbgNullFrameAckFail

{.emit: "__attribute__((optimize(\"crossjumping\"))) unsigned char txl_frame_send_qosnull_frame(unsigned char,unsigned short,void *,unsigned long);".}
proc txl_frame_send_qosnull_frame*(staIdx: uint8, qosCtrl: uint16,
    cfmCallback: pointer, cfmArg: uint32): uint8 {.exportc, cdecl,
    discardable.} =
  ## Build and send a QoS null frame (101 instrs).
  ## Similar to txl_frame_send_null_frame but with QoS header (26 bytes).
  ## Frame Control = 0xC8 (QoS null, subtype 12), with To-DS/From-DS flags
  ## depending on VIF type (STA vs AP).
  ## Assembly trace:
  ##   s4 = sta_info_tab base
  ##   s2 = sta entry = s4 + staIdx * 368
  ##   s0 = sta[39] (VIF index)
  ##   s3 = vif_info_tab base, s5 = vif entry = s3 + sta[39] * 1512
  ##   Allocates txl_frame_get(26, staIdx)
  ##   Builds QoS null frame: FC=0xC8+flags, addresses, seq num, QoS field
  ##   desc[208] = cfmCallback, desc[212] = cfmArg,
  ##   desc[49] = staIdx, desc[47] = sta[39]
  ##   Calls txl_frame_push(desc, 3), returns (result^1)&0xFF
  let sta = staInfoForIdx(staIdx)
  let vifIdx = sta.instNbr
  let vif = vifChannelForIdx(vifIdx)
  let vifEntry = cast[pointer](vif)
  let staMacAddr = cast[pointer](addr sta.macAddr[0])
  let vifMacAddr = cast[pointer](addr vif.macAddr[0])
  # Allocate frame (26 bytes for QoS null header)
  let frame = txl_frame_get(26)
  if frame == nil:
    return 1'u8
  let desc = hostTxDescAt(frame)
  tpc_update_frame_tx_power(vifEntry, frame)
  let hdr = hostTxQosDataHeader(desc)
  # Check VIF type (STA or AP) to determine To-DS/From-DS
  let vifType = vif.vifType
  # Frame Control: 0xC8 = QoS null data (type 2, subtype 12)
  hdr.header.frameControl = if vifType == 0: 0x01C8'u16 else: 0x02C8'u16
  hdr.header.duration = 0
  # Addr1 (RA) = STA MAC
  discard c_memcpy(addr hdr.header.addr1[0], staMacAddr, 6.csize_t)
  # Addr2 (SA) = VIF MAC
  discard c_memcpy(addr hdr.header.addr2[0], vifMacAddr, 6.csize_t)
  # Addr3: depends on direction
  if vifType == 0:
    # STA mode: Addr3 = STA MAC (BSSID via STA, same as addr1)
    discard c_memcpy(addr hdr.header.addr3[0], staMacAddr, 6.csize_t)
  else:
    # AP mode: Addr3 = VIF MAC (BSSID = our address)
    discard c_memcpy(addr hdr.header.addr3[0], vifMacAddr, 6.csize_t)
  # Sequence control at offset 370-371 (bytes 22-23 of MAC header).
  # Vendor leaves QoS null sequence control zero here.
  hdr.header.seqCtrl = 0
  # QoS field at offset 372-373 (bytes 24-25 of MAC header)
  hdr.qosCtrl = qosCtrl
  # Store confirmation context and descriptor metadata exactly like the blob.
  desc.callback = cfmCallback
  desc.callbackArg = cast[pointer](cfmArg.uint)
  desc.staInfoIdx = staIdx
  desc.vifIdx = vifIdx
  nimFwDbgNullFrameDescLast = pointerAddrU32(frame)
  nimFwDbgNullFrameBufLast = pointerAddrU32(desc.bufDesc)
  nimFwDbgNullFrameFcLast =
    hdr.header.frameControl.uint32 or (hdr.qosCtrl.uint32 shl 16)
  nimFwDbgNullFrameVifSta =
    staIdx.uint32 or (vifIdx.uint32 shl 8) or (vif.state.uint32 shl 16)
  if cfmCallback != nil:
    inc nimFwDbgNullFrameCbSet
    nimFwDbgNullFrameCbSetPtr = cast[uint32](cast[uint](cfmCallback))
  # Push frame for TX on AC 3 (VO)
  let pushRc = txl_frame_push(frame, 3)
  let publicRc = (pushRc xor 1'u8) and 0xFF'u8
  nimFwDbgNullFramePushRc = pushRc.uint32
  nimFwDbgNullFrameReturn = publicRc.uint32
  nimFwDbgNullFrameBufLast = pointerAddrU32(desc.bufDesc)
  if desc.bufDesc != nil:
    let pushedHdr = hostTxQosDataHeader(desc)
    nimFwDbgNullFrameFcLast =
      pushedHdr.header.frameControl.uint32 or
      (pushedHdr.qosCtrl.uint32 shl 16)
  return publicRc

proc txl_frame_send_selfcts_frame*(vifInfo: pointer, duration: uint16, rateConfig: uint32, navValue: uint32) {.exportc, cdecl.} =
  ## Build and send a self-CTS frame (for NAV protection).
  ## From disassembly (66 instrs): Allocates a 10-byte frame via txl_frame_get(10, ...),
  ## builds a CTS frame header, copies VIF MAC address, sets rate config/NAV,
  ## modifies HW descriptor control fields, and pushes via txl_frame_push(desc, 3).
  ##
  ## Assembly trace:
  ##   s2=vifInfo, s1=duration, s4=rateConfig, s3=navValue
  ##   call txl_frame_get(10, ...)  # 10-byte CTS frame
  ##   if nil: return 1
  ##   s0 = frame desc
  ##   call txl_frame_init_desc(vifInfo, desc) or similar setup
  ##   linkDesc = desc[108]
  ##   linkDesc[350] = duration (low byte)
  ##   linkDesc[351] = duration >> 8 (high byte)
  ##   linkDesc[348] = 0xC4 (-60 signed = CTS frame control)
  ##   linkDesc[349] = 0 (flags)
  ##   memcpy(linkDesc+352, vifInfo+80, 6) -- RA = own MAC addr
  ##   desc+128+80 = rateConfig
  ##   desc+128+84 = navValue
  ##   hwDesc = desc[112]
  ##   hwDesc[60] |= 0x30000063 (control flags: self-CTS protection bits)
  ##   thd = hwDesc[40]; thd[16] &= 0xFFFF0000 (clear low 16 bits of rate)
  ##   desc[47] = vifInfo byte[87] (phy mode)
  ##   desc[49] = 0xFF (broadcast STA index)
  ##   call txl_frame_push(desc, 3)
  ##   return (result ^ 1) & 0xFF
  let vif = vifChannelAt(vifInfo)
  # Allocate CTS frame (10 bytes: FC(2) + duration(2) + RA(6))
  # Blob passes a0=10 (frame size) and a1=duration (original param, used as length hint)
  let frame = txl_frame_get(10)
  if frame == nil:
    return  # blob returns 1 (failure)
  let desc = hostTxDescAt(frame)
  # The blob calls a setup function at offset 0x28 with (vifInfo, frame_desc) to
  # associate the frame with VIF context. We handle this inline below.
  let hdr = hostTxCtsHeader(desc)
  # Build CTS frame header at linkDesc+348.
  hdr.frameControl = 0x00C4'u16
  hdr.duration = duration
  # RA = own MAC address from vifInfo+80
  let vifMacAddr = cast[pointer](addr vif.macAddr[0])
  discard c_memcpy(addr hdr.receiverAddr[0], vifMacAddr, 6.csize_t)
  # Store rate config and NAV value in descriptor extension area (desc+128+80, desc+128+84)
  let aux = hostTxAuxWords(desc)
  aux.rateConfig = rateConfig
  aux.navValue = navValue
  # Modify HW descriptor control fields for self-CTS
  let hwDesc = hostTxHwDescAt(desc.hwDesc)
  # Set self-CTS protection bits in hwDesc[60]
  hwDesc.controlFlags = hwDesc.controlFlags or 0x30000063'u32
  # Clear low 16 bits of rate descriptor in THD
  let thdPtr = hwDesc.chainedThd
  if thdPtr != nil:
    let rateTemplate = hostTxRateTemplateAt(thdPtr)
    rateTemplate.policyWord = rateTemplate.policyWord and 0xFFFF0000'u32
  # Set phy mode and STA index
  desc.vifIdx = vif.vifIdx  # phy mode
  desc.staInfoIdx = 0xFF'u8  # broadcast STA index
  # Apply TX power control (blob: tpc_update_frame_tx_power)
  tpc_update_frame_tx_power(vifInfo, frame)
  # Push frame for transmission on AC 3
  txl_frame_push(frame, 3)

proc txl_frame_dump*() {.exportc, cdecl, noinline.} =
  ## Dump TX frame pool state for debugging (190 instrs).
  ## From disassembly: uses the platform log function (g_bl_ops_funcs[204])
  ## to print TX frame internal descriptor state.
  ##
  ## Structure: txl_frame_env is an array of 5 internal frame descriptors,
  ## each 220 bytes (0xDC). The function:
  ##   1. Prints header line (line 1101)
  ##   2. Prints separator (line 1103)
  ##   3. Prints "5 desc" indicator (line 1104, a5=5)
  ##   4. Prints another separator (line 1105)
  ##   5. Loops over 5 descriptors, calling g_bl_ops_funcs[4] (a simpler print)
  ##      with each descriptor address
  ##   6. Prints "pending list" header (line 1109)
  ##   7. Prints separator (line 1111)
  ##   8. Gets pending list head via co_list (txl_frame_shared_env), walks chain
  ##      printing each entry (line 1113, 1114)
  ##   9. Prints "used list" header (line 1122)
  ##  10. Gets used list head, walks chain printing each (line 1123, 1124)
  ##  11. Prints footer separators (lines 1132, 1133)
  ##
  ## This is purely a debug/diagnostic function.
  ## The blob calls g_bl_ops_funcs[204] (log function) and g_bl_ops_funcs[4]
  ## (simple print callback) to dump internal TX frame descriptors.
  type LogV = proc(a0, a1: uint32, fmt: pointer, line: uint32, val: uint32) {.cdecl, varargs.}
  var lf = cast[LogV](getLogFunc(204)); if lf == nil: return
  # Header
  lf(2, 0, nil, 0x44D, 0)
  lf = cast[LogV](getLogFunc(204)); if lf != nil: lf(2, 0, nil, 0x44F, 0)
  lf = cast[LogV](getLogFunc(204)); if lf != nil: lf(2, 0, nil, 0x450, 4)
  lf = cast[LogV](getLogFunc(204)); if lf != nil: lf(2, 0, nil, 0x451, 0)
  # Loop 4 descriptors (blob: li a5, 4 at line 1104)
  let descStorageBase = cast[uint](addr txl_frame_desc_storage[0])
  for frameDescSlotIndex in 0 ..< 4:
    let descAddr = descStorageBase + frameDescSlotIndex.uint * 220'u
    lf = cast[LogV](getLogFunc(204)); if lf != nil: lf(2, 0, nil, 0x453, cast[uint32](descAddr))
  # Pending (free) list section — blob uses co_list_cnt + linked list walk
  let frameEnv = txFrameEnv()
  let freeList = addr frameEnv.freeList
  let usedList = addr frameEnv.usedList
  lf = cast[LogV](getLogFunc(204)); if lf != nil: lf(2, 0, nil, 0x455, 0)
  let freeCnt = co_list_cnt(freeList)
  lf = cast[LogV](getLogFunc(204)); if lf != nil: lf(2, 0, nil, 0x457, freeCnt)
  # Walk free list
  var freeNode = freeList.first
  while freeNode != nil:
    lf = cast[LogV](getLogFunc(204)); if lf != nil: lf(2, 0, nil, 0x459, cast[uint32](freeNode))
    freeNode = freeNode.next
  # Used list section — blob calls co_list_cnt on used list
  let usedCnt = co_list_cnt(usedList)
  lf = cast[LogV](getLogFunc(204)); if lf != nil: lf(2, 0, nil, 0x462, usedCnt)
  var usedNode = usedList.first
  while usedNode != nil:
    lf = cast[LogV](getLogFunc(204)); if lf != nil: lf(2, 0, nil, 0x463, cast[uint32](usedNode))
    usedNode = usedNode.next
  # Footer
  lf = cast[LogV](getLogFunc(204)); if lf != nil: lf(2, 0, nil, 0x46C, 0)
  lf = cast[LogV](getLogFunc(204)); if lf != nil: lf(2, 0, nil, 0x46D, 0)
