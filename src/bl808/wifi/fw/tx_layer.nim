# ###########################################################################
#                   TX LAYER (txl_*)
# ###########################################################################

proc txlInvalidateDmaFrame(desc: pointer) =
  # The drain's stack token outlives descriptor release and same-slot reuse.
  for owner in [txActiveDmaOwner, txActiveTriggerOwner]:
    if owner != nil and owner.desc == desc:
      owner.cancelled = true

proc txlInvalidateDmaAc(ac: uint8) =
  for owner in [txActiveDmaOwner, txActiveTriggerOwner]:
    if owner != nil and owner.ac == ac:
      owner.cancelled = true

proc txlInvalidateDmaVif(vif: uint8) =
  for owner in [txActiveDmaOwner, txActiveTriggerOwner]:
    if owner != nil and owner.vif == vif:
      owner.cancelled = true

proc txlInvalidateDmaStation(station: uint8) =
  for owner in [txActiveDmaOwner, txActiveTriggerOwner]:
    if owner != nil and owner.station == station:
      owner.cancelled = true

proc txlInvalidateDmaAll() =
  for owner in [txActiveDmaOwner, txActiveTriggerOwner]:
    if owner != nil:
      owner.cancelled = true

proc txlResetting(): bool {.inline.} =
  txControlEnv().resetInProgress != 0

proc txlCaptureSession(desc: ptr HostTxDescView): TxSessionIdentity =
  # The caller holds interrupts through preparation and publication.
  if desc == nil or desc.vifIdx >= MAX_VIFS.uint8 or
      (desc.staInfoIdx >= STA_INFO_TAB_ENTRIES.uint8 and desc.staInfoIdx != 0xFF):
    return
  result = TxSessionIdentity(captured: true, vif: desc.vifIdx,
    station: desc.staInfoIdx, vifEpoch: rxVifEpochs[desc.vifIdx],
    stationEpoch: staDeleteEpoch(desc.staInfoIdx), resetEpoch: txResetEpoch)

proc txlSessionCurrent(identity: TxSessionIdentity; desc: ptr HostTxDescView): bool =
  if txlResetting() or not identity.captured or identity.resetEpoch != txResetEpoch or
      identity.vif >= MAX_VIFS.uint8:
    return false
  if rxVifEpochs[identity.vif] != identity.vifEpoch or
      staDeleteEpoch(identity.station) != identity.stationEpoch or
      txlVifIsRetiring(identity.vif):
    return false
  desc != nil and desc.vifIdx == identity.vif and desc.staInfoIdx == identity.station

proc txlStationAdmits(desc: ptr HostTxDescView): bool =
  if txlResetting() or desc == nil or desc.vifIdx >= MAX_VIFS.uint8:
    return false
  if txlVifIsRetiring(desc.vifIdx) or not txlFrameSessionCurrent(desc):
    return false
  let staIdx = desc.staInfoIdx
  if staIdx == 0xFF'u8:
    return true
  if staIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return false
  let sta = staInfoForIdx(staIdx)
  sta.instNbr == desc.vifIdx and
    (staIdx >= STA_MGMT_FREE_STAS.uint8 or sta.valid != 0)

proc txlFramePreparationCurrent(desc: ptr HostTxDescView;
    identity: TxSessionIdentity; generation: uint32): bool =
  if desc == nil or not txlFrameLeaseMatches(desc, generation):
    return false
  if not txlSessionCurrent(identity, desc) or not txlStationAdmits(desc) or
      desc.bufDesc == nil or desc.hwDesc == nil:
    txl_frame_release(desc, false)
    return false
  true

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
  ## Full TX reset must retire every software backup queue, not only AC0.
  for queue in txlBufferEnvView().backupQueues.mitems:
    queue.first = nil
    queue.last = nil

proc txl_buffer_reset*() {.exportc, cdecl, noinline.} =
  ## Reset TX buffer pool indices.
  txlBufferEnvView().backupQueues[0].first = nil
  txlBufferEnvView().backupQueues[0].last = nil

proc txlApplyEapolRetryPolicy(rate: ptr HostTxRateTemplateView) {.inline.} =
  ## Optional bench workaround, gated by bl808WifiBootstrapRetryWorkaround.
  ## Normal TX retains the station's negotiated rate and RF power policy.
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
  ## The diagnostic override covers all IPv4/ARP, not only DHCP or startup.
  txlApplyEapolRetryPolicy(rate)

proc txlEnqueuePrepared(param, linkPtr: pointer; queueIdx: uint32) =
  # This commit path must not call diagnostics or other reentrant hooks.
  let link = hostTxInternalLinkNodeAt(linkPtr)
  link.headerThd.magic = 0xCAFEFADE'u32
  link.txDesc = param
  let head = txBackupQueueHeadPtr(queueIdx)
  let tail = txBackupQueueTailPtr(queueIdx)
  if head[] == nil:
    head[] = linkPtr
  else:
    hostTxInternalLinkNodeAt(tail[]).next = linkPtr
  tail[] = linkPtr
  link.next = nil

proc txlPrepareBuffer(param: pointer; queueIdx, flags: uint32): pointer =
  ## Prepare the inline buffer without publishing it. The vendor allocator
  ## performs this work and queue insertion in one call.
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
  let identity = txlCaptureSession(desc)
  template ensureCurrentBuffer() =
    if not txlSessionCurrent(identity, desc) or not txSecurityCurrent(desc):
      return nil
  if not txlSessionCurrent(identity, desc) or not txSecurityCurrent(desc) or
      desc.staInfoIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return nil
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
  if not txuBuildFrame(param, bufPtr):
    return nil
  if not txlSessionCurrent(identity, desc) or desc.policy == nil:
    return nil

  # Copy the TX buffer control template. Vendor emits T-Head indexed load/store
  # opcodes here, equivalent to copying the 60-byte TxBufferControlView.
  let bufferControl = txBufferControlAt(desc.policy)
  let rateTemplate = hostTxRateTemplate(bufLink)
  discard c_memcpy(addr bufLink.rateTemplate[0], bufferControl,
                   sizeof(TxBufferControlView).csize_t)

  let protoTrace = desc.frameLen
  let protoFrameType = lmacGateHalfword(protoTrace)
  when defined(bl808WifiBootstrapRetryWorkaround):
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
    when defined(bl808WifiBootstrapRetryWorkaround):
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
      ensureCurrentBuffer()
      nimFwConnectTrace2U32("[WIFI-CT] txbuf_data2 ",
                            bufLink.headerThd.payloadEnd,
                            bufLink.headerThd.flags)
      ensureCurrentBuffer()
      nimFwConnectTraceBytes("[WIFI-RAW] tx_data ",
                             cast[pointer](addr bufLink.macHeader[0]),
                             hdrLen.uint32,
                             80)
      ensureCurrentBuffer()

  # The vendor queues this node here; retain it privately until commit.
  let dmaEntry = cast[uint](bufLink)
  if isEapol:
    nimFwTrace2U32("[WIFI-NIMFW] txbuf_eapol ",
                   queueIdx or (hdrLen.uint32 shl 8),
                   cast[uint32](dmaEntry))
    ensureCurrentBuffer()
    nimFwTrace2U32("[WIFI-NIMFW] txbuf_ctrl ",
                   cast[uint32](cast[uint](bufferControl)),
                   rateTemplate.magic)
    ensureCurrentBuffer()
    when defined(bl808WifiConnectTrace):
      if nimFwDbgEapolTraceCount < 64'u32:
        nimFwConnectTrace2U32("[WIFI-CT] txbuf_eapol ",
                              queueIdx or (hdrLen.uint32 shl 8) or
                                (padLen.uint32 shl 16),
                              cast[uint32](dmaEntry))
        ensureCurrentBuffer()
        nimFwConnectTrace2U32("[WIFI-CT] txbuf_ctrl ",
                              cast[uint32](cast[uint](bufferControl)),
                              rateTemplate.magic)
        ensureCurrentBuffer()
        nimFwConnectTrace2U32("[WIFI-CT] txbuf_pol0 ",
                              rateTemplate.ntxConfig,
                              rateTemplate.rateWord)
        ensureCurrentBuffer()
        nimFwConnectTrace2U32("[WIFI-CT] txbuf_pol1 ",
                              cast[uint32](rateTemplate.txPower),
                              rateTemplate.retryTxPowerControl2)
        ensureCurrentBuffer()
  if not txlSessionCurrent(identity, desc) or not txSecurityCurrent(desc):
    return nil
  # Keep the prepared node private until its caller commits TX ownership.
  bufLink.next = nil

  # Return buffer control pointer.
  return cast[pointer](dmaEntry)

proc txl_buffer_alloc*(param: pointer, queueIdx: uint32, flags: uint32): pointer {.exportc, cdecl.} =
  let saved = irqSave()
  defer: irqRestore(saved)
  result = txlPrepareBuffer(param, queueIdx, flags)
  if result != nil:
    txlEnqueuePrepared(param, result, queueIdx)

proc txlBuildBufferThd(param: pointer): bool =
  ## Update TX header descriptor chain from buffer pointer array.
  ## From disassembly (52 instrs): walks buffer pointers at param+52 (stride 4),
  ## creates THD entries at linkDesc+92 (stride 20) with cafefade magic,
  ## then sets up the main THD at linkDesc+72 pointing to the header buffer
  ## at linkDesc+348.
  let desc = hostTxDescAt(param)
  if desc == nil or desc.bufDesc == nil or desc.hwDesc == nil:
    return false
  let linkDesc = hostTxLinkDescAt(desc.bufDesc)
  let hwDesc = hostTxHwDescAt(desc.hwDesc)
  hwDesc.status = 0
  hwDesc.controlFlags = 0
  # Validate the complete chain before writing any links or inclusive ranges.
  var payloadBytes = 0'u32
  var payloadEnded = false
  for i in 0 ..< desc.bufferPtrs.len:
    let start = desc.bufferPtrs[i]
    let length = desc.bufferLens[i]
    if start == 0:
      if length != 0:
        return false
      payloadEnded = true
    else:
      if payloadEnded or length == 0 or length - 1 > high(uint32) - start:
        return false
      if length > desc.seqPassthrough.uint32 - payloadBytes:
        return false
      payloadBytes += length
  if payloadBytes == 0:
    inc nimFwDbgTxThdNoBuffer
    nimFwDbgTxThdNoBufferDesc = pointerAddrU32(param)
    return false
  if payloadBytes != desc.seqPassthrough.uint32:
    return false
  let headerBuf = cast[uint32](cast[uint](addr linkDesc.macHeader[0]))
  if linkDesc.headerLen == 0 or linkDesc.headerLen - 1 > high(uint32) - headerBuf:
    return false
  var lastPayloadThdEntry: ptr HostTxThdEntryView = nil
  const CAFEFADE = 0xCAFEFADE'u32
  for payloadThdEntryIndex in 0 ..< desc.bufferPtrs.len:
    let payloadBufferStart = desc.bufferPtrs[payloadThdEntryIndex]
    if payloadBufferStart == 0:
      break
    # Fill THD entry
    let payloadThdEntry = addr linkDesc.payloadThd[payloadThdEntryIndex]
    payloadThdEntry.magic = CAFEFADE
    payloadThdEntry.payloadStart = payloadBufferStart
    let payloadBufferLen = desc.bufferLens[payloadThdEntryIndex]
    payloadThdEntry.flags = 0
    payloadThdEntry.payloadEnd = payloadBufferStart + payloadBufferLen - 1
    lastPayloadThdEntry = payloadThdEntry
    if payloadThdEntryIndex + 1 < desc.bufferPtrs.len:
      payloadThdEntry.next = addr linkDesc.payloadThd[payloadThdEntryIndex + 1]
    else:
      payloadThdEntry.next = nil
  # Set up main THD at linkDesc+72
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
      let identity = txlCaptureSession(desc)
      template ensureCurrentThd() =
        if not txlSessionCurrent(identity, desc) or
            desc.bufDesc != cast[pointer](linkDesc) or
            desc.hwDesc != cast[pointer](hwDesc):
          return false
      let payload0 = addr linkDesc.payloadThd[0]
      nimFwConnectTrace2U32("[WIFI-CT] txthd_data ",
                            protoFrameType.uint32 or
                              (desc.hdrLen.uint32 shl 16) or
                              (desc.secTailLen.uint32 shl 24),
                            hwDesc.frameLen)
      ensureCurrentThd()
      nimFwConnectTrace2U32("[WIFI-CT] txthd_ptr ",
                            payload0.payloadStart,
                            payload0.payloadEnd)
      ensureCurrentThd()
      nimFwConnectTrace2U32("[WIFI-CT] txthd_buf ",
                            desc.bufferPtrs[0],
                            desc.bufferLens[0])
      ensureCurrentThd()
      if desc.bufferPtrs[0] != 0:
        nimFwConnectTraceBytes("[WIFI-RAW] tx_payload ",
                               cast[pointer](desc.bufferPtrs[0].uint),
                               desc.bufferLens[0],
                               384)
        ensureCurrentThd()
  return true

proc txl_buffer_update_thd*(param: pointer) {.exportc, cdecl.} =
  discard txlBuildBufferThd(param)

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
  let thd = hostTxHeadThd(hw)
  let thdFlags = if thd != nil: thd.flags else: 0'u32
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
    nimFwDbgAuthCfmThdFlags = thdFlags
    if (thdFlags and 0x00010000'u32) != 0:
      inc nimFwDbgAuthCfmAckOk16
    elif (status and 0x00800000'u32) != 0'u32:
      inc nimFwDbgAuthCfmAckOk23
    elif phase == 0'u32:
      inc nimFwDbgAuthCfmAckFail
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
    nimFwDbgAssocCfmThdFlags = thdFlags
    if (thdFlags and 0x00010000'u32) != 0:
      inc nimFwDbgAssocCfmAckOk16
    elif (status and 0x00800000'u32) != 0'u32:
      inc nimFwDbgAssocCfmAckOk23
    elif phase == 0'u32:
      inc nimFwDbgAssocCfmAckFail
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
  let trace = block:
    let saved = irqSave()
    defer: irqRestore(saved)
    txlInvalidateDmaFrame(desc)
    inc nimFwDbgCfmPush
    let txDesc = hostTxDescAt(desc)
    noteMgmtTxConfirm(txDesc, status, 0'u32)
    let fenvPtr = txDesc.hwDesc
    var cfmHeadTrace = 0'u32
    var thdStatusTrace = status
    if fenvPtr != nil:
      cfmHeadTrace = hostTxHwDescAt(fenvPtr).txConfirmDescPtr
      let thdBaseTrace = hostTxHeadThd(hostTxHwDescAt(fenvPtr))
      if thdBaseTrace != nil:
        thdStatusTrace = thdBaseTrace.flags
    let enabled = nimFwDbgCfmTraceCount < 32'u32 or
      cfmHeadTrace == 0xBADCAB1E'u32
    let snapshot = (enabled: enabled,
      acAndCount: acIdx or (nimFwDbgCfmTraceCount shl 8),
      descriptor: pointerAddrU32(desc),
      hardware: pointerAddrU32(fenvPtr), head: cfmHeadTrace,
      queue: pointerAddrU32(txDesc.queueFirst),
      buffer: pointerAddrU32(txDesc.bufDesc), thdStatus: thdStatusTrace)
    if enabled:
      inc nimFwDbgCfmTraceCount
    if fenvPtr != nil:
      let hwdesc = hostTxHeadThd(hostTxHwDescAt(fenvPtr))
      if hwdesc != nil:
        hwdesc.flags = status
    co_list_push_back(txCfmList(acIdx), cast[ptr CoListHdr](desc))
    if acIdx < 5'u32:
      ke_evt_set(txl_cfm_evt_bit[acIdx])
    snapshot
  # Publication transfers ownership; diagnostics use only the old snapshot.
  if trace.enabled:
    nimFwTrace2U32("[WIFI-NIMFW] cfm_push ",
                   trace.acAndCount, trace.descriptor)
    nimFwTrace2U32("[WIFI-NIMFW] cfm_ptrs ",
                   trace.hardware, trace.head)
    nimFwTrace2U32("[WIFI-NIMFW] cfm_links ",
                   trace.queue, trace.buffer)
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] cfm_push ",
                            trace.acAndCount, trace.descriptor)
      nimFwConnectTrace2U32("[WIFI-CT] cfm_ptrs ",
                            trace.hardware, trace.head)
      nimFwConnectTrace2U32("[WIFI-CT] cfm_status ",
                            trace.thdStatus, status)
      nimFwConnectTrace2U32("[WIFI-CT] cfm_links ",
                            trace.queue, trace.buffer)

proc txlCfmPending(acList: ptr CoList): bool {.inline.} =
  acList.first != nil

proc txl_cfm_evt*(ac: uint8) {.exportc, cdecl.} =
  ## Process TX confirmation events (212 bytes in blob).
  ## Blob (txl_cfm.o): ke_evt_field[ac] lookup, assert event pending,
  ##   ke_evt_clear, then loop with IRQ-safe co_list_pop_front:
  ##   me_tx_cfm_singleton → txu_cntrl_cfm → txl_cntrl_env[80]-- → ipc_emb_txcfm
  ##   → ipc_emb_txcfm_ind (per-descriptor, inside loop).
  inc nimFwDbgCfmEvt
  let acIdx = ac.uint32

  let txCtrl = txControlEnv()

  # Compute event field for this AC (blob uses .LANCHOR0 = txl_cfm_evt_bit array).
  let evtField = if acIdx < 5'u32: txl_cfm_evt_bit[acIdx] else: 0'u32

  # Assert event is pending (blob: ke_env[0] & evtField != 0)
  let keEvtBits = cast[ptr uint32](addr ke_env[0])[]
  if (keEvtBits and evtField) == 0:
    assert_err("txl_cfm.c", "txl_cfm.c", 346)
    return
  let acMask = 1'u32 shl acIdx

  # Clear the event (blob: ke_evt_clear with evtField, not acMask)
  ke_evt_clear(evtField)

  # Get per-AC confirmation list
  let acList = txCfmList(acIdx)
  defer:
    let saved = irqSave()
    defer: irqRestore(saved)
    if txlCfmPending(acList):
      ke_evt_set(evtField)
  # Main loop: blob drains all pending TX confirms for this AC.
  while txlCfmPending(acList):
    let trace = block:
      var published = false
      let irqState = irqSave()
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      defer:
        {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
        try:
          irqRestore(irqState)
        finally:
          if published:
            ipc_emb_txcfm_ind(acMask)
      let node = cast[ptr CoListHdr](co_list_pop_front(acList))
      if node == nil:
        return
      node.next = nil
      var completing = TxFlushBatch(previous: txActiveFlush, ac: ac,
        status: 0x40000000'u32, confirmations: CoList(first: node, last: node))
      txActiveFlush = addr completing
      defer: txlFlushScopeExit(completing.previous)
      let descTrace = hostTxDescAt(cast[pointer](node))
      let fenvPtrTrace = descTrace.hwDesc
      var cfmHeadTrace = 0'u32
      var thdStatusTrace = 0'u32
      if fenvPtrTrace != nil:
        cfmHeadTrace = hostTxHwDescAt(fenvPtrTrace).txConfirmDescPtr
        let thdBaseTrace = hostTxHeadThd(hostTxHwDescAt(fenvPtrTrace))
        if thdBaseTrace != nil:
          thdStatusTrace = thdBaseTrace.flags
      let enabled = nimFwDbgCfmTraceCount < 64'u32 or
        cfmHeadTrace == 0xBADCAB1E'u32
      let snapshot = (node: node, enabled: enabled,
        acAndCount: acIdx or (nimFwDbgCfmTraceCount shl 8),
        descriptor: pointerAddrU32(cast[pointer](node)),
        hardware: pointerAddrU32(fenvPtrTrace), head: cfmHeadTrace,
        queue: pointerAddrU32(descTrace.queueFirst),
        buffer: pointerAddrU32(descTrace.bufDesc),
        destination: pointerAddrU32(descTrace.cfmDst), thdStatus: thdStatusTrace)
      if enabled:
        inc nimFwDbgCfmTraceCount
      # Finish peer-dependent work before a restart can reuse the station.
      try:
        me_tx_cfm_singleton(cast[pointer](node))
      finally:
        # Nested retirement may already have delivered this completion.
        if completing.confirmations.first == node:
          completing.confirmations = default(CoList)
          txu_cntrl_cfm(cast[pointer](node))
          txCtrl.packetCounter = txCtrl.packetCounter - 1
          # Publish before an interrupt can recycle the completed wrapper.
          ipc_emb_txcfm(cast[pointer](node))
          published = true
      snapshot
    if trace.enabled:
      nimFwTrace2U32("[WIFI-NIMFW] cfm_evt ",
                     trace.acAndCount, trace.descriptor)
      nimFwTrace2U32("[WIFI-NIMFW] cfm_evt_ptr ",
                     trace.hardware, trace.head)
      nimFwTrace2U32("[WIFI-NIMFW] cfm_evt_lnk ",
                     trace.queue, trace.buffer)
      when defined(bl808WifiConnectTrace):
        nimFwConnectTrace2U32("[WIFI-CT] cfm_evt ",
                              trace.acAndCount, trace.descriptor)
        nimFwConnectTrace2U32("[WIFI-CT] cfm_evt_ptr ",
                              trace.hardware, trace.head)
        nimFwConnectTrace2U32("[WIFI-CT] cfm_evt_status ",
                              trace.thdStatus, trace.destination)
        nimFwConnectTrace2U32("[WIFI-CT] cfm_evt_lnk ",
                              trace.queue, trace.buffer)

proc txl_cfm_flush*(ac: uint8; cfmList: ptr CoList;
                    status: uint32) {.exportc, cdecl, noinline.} =
  ## Flush all pending TX confirmations (190 bytes in blob).
  ## From blob: a0=ac_index, a1=cfm_list_ptr, a2=status.
  ## Iterates the cfm list (a1) via co_list_pop_front, for each descriptor:
  ##   1. Reads desc+112 (THD chain ptr) -> THD[0], desc+104 (DMA link)
  ##   2. If link != nil: write (0x3C000000 | status) to THD[16]
  ##   3. If link == nil: check THD[16]; if >= 0, write status to THD[16]
  ##   4. Check desc+8 (host queue marker):
  ##      - If nil: call txl_frame_cfm(desc), continue loop
  ##      - If present: call txu_cntrl_cfm(desc), decrement txl_cntrl_env[80],
  ##        clear desc+108, increment count, call ipc_emb_txcfm(desc)
  ##   5. After loop: call txl_frame_evt()
  ##   6. If count > 0: tail-call ipc_emb_txcfm_ind(1 << ac)
  let acIdx = ac.uint32
  let txCtrl = txControlEnv()
  let forcedStatus = 0x3C000000'u32 or status
  var flushedHostConfirmCount: uint32 = 0
  defer:
    if flushedHostConfirmCount > 0:
      ipc_emb_txcfm_ind(1'u32 shl acIdx)

  while cfmList.first != nil:
    let saved = irqSave()
    defer: irqRestore(saved)
    let node = co_list_pop_front(cfmList)
    if node == nil:
      break
    let txDesc = hostTxDescAt(cast[pointer](node))
    let thdChainPtr = txDesc.hwDesc
    let linkDesc = txDesc.dmaLink

    let thd = hostTxHeadThd(hostTxHwDescAt(thdChainPtr))
    if linkDesc != nil:
      # DMA owned: force confirm with 0x3C000000 | status
      thd.flags = forcedStatus
    elif cast[int32](thd.flags) >= 0:
      thd.flags = status

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
    # IPC TX confirm to host
    ipc_emb_txcfm(cast[pointer](node))
    flushedHostConfirmCount += 1

  # After loop: signal frame event processing
  txl_frame_evt()

proc txl_cfm_flush_desc*(ac: uint8; desc: pointer; status: uint32) {.exportc, cdecl.} =
  ## Flush a specific TX confirmation descriptor (120 bytes in blob).
  ## From blob ABI: a0=ac_index, a1=desc_ptr, a2=status_override.
  ## Logic: reads desc+112 (THD chain) -> THD[0], desc+104 (DMA link).
  ## If link != nil (DMA owned): write (status_override | 0x3C000000) to THD[16].
  ## If link == nil: check THD[16]; if >= 0, write status_override to THD[16].
  ## Then checks desc+8 (host queue marker):
  ##   - If nil: call txl_frame_cfm(desc), tail-call txl_frame_evt() (return 0)
  ##   - If present: call txu_cntrl_cfm(desc), decrement txl_cntrl_env[80],
  ##     clear desc+108, call ipc_emb_txcfm(desc), ipc_emb_txcfm_ind(1 << ac),
  ##     then tail-call txl_frame_evt().
  let hostCompletion = block:
    let saved = irqSave()
    defer: irqRestore(saved)
    let txDesc = hostTxDescAt(desc)
    let thdChainPtr = txDesc.hwDesc
    let linkDesc = txDesc.dmaLink
    let thd = hostTxHeadThd(hostTxHwDescAt(thdChainPtr))
    if linkDesc != nil:
      thd.flags = status or 0x3C000000'u32
    elif cast[int32](thd.flags) >= 0:
      thd.flags = status
    if txDesc.queueFirst == nil:
      txl_frame_cfm(cast[pointer](txDesc))
      false
    else:
      txu_cntrl_cfm(cast[pointer](txDesc))
      let txCtrl = txControlEnv()
      txCtrl.packetCounter = txCtrl.packetCounter - 1
      txDesc.bufDesc = nil
      ipc_emb_txcfm(cast[pointer](txDesc))
      true
  if hostCompletion:
    ipc_emb_txcfm_ind(1'u32 shl ac)
  # The vendor drains internal completions after either descriptor path.
  txl_frame_evt()

proc txlConfirmUnqueuedHost(desc: pointer; status: uint32; ac: uint8) =
  # This descriptor never entered TX accounting or a firmware queue.
  let saved = irqSave()
  defer: irqRestore(saved)
  let txDesc = hostTxDescAt(desc)
  hostTxHeadThd(hostTxHwDescAt(txDesc.hwDesc)).flags = status
  txu_cntrl_cfm(desc)
  txDesc.bufDesc = nil
  ipc_emb_txcfm(desc)
  ipc_emb_txcfm_ind(1'u32 shl ac)

proc txl_cfm_dump*() {.exportc, cdecl, noinline.} =
  ## Match the vendor's per-AC counts and head-THD confirmation flags.
  let logFuncPtr = getLogFunc(204)
  if logFuncPtr == nil: return
  type
    LogFn = proc(level: uint32; tag, file: cstring; line: cint;
                 format: cstring) {.cdecl, varargs.}
    PrintFn = proc(format: cstring) {.cdecl, varargs.}
  let logFn = cast[LogFn](logFuncPtr)
  let printFn = cast[PrintFn](blOpsFunc(4))
  # Four host wrappers, four internal frames, and two VIF beacon descriptors.
  # Capture all queues before logging can complete, reset, or reuse a frame.
  const MaxSnapshotEntries = 10
  var nodes: array[MaxSnapshotEntries, pointer]
  var statuses: array[MaxSnapshotEntries, uint32]
  var counts: array[5, uint8]
  var captured = 0
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    for queue in 0'u32 ..< 5'u32:
      var node = txCfmList(queue).first
      while node != nil and captured < nodes.len:
        var repeated = false
        for index in 0 ..< captured:
          if nodes[index] == cast[pointer](node):
            repeated = true
            break
        if repeated: break
        nodes[captured] = cast[pointer](node)
        if printFn != nil:
          let desc = hostTxDescAt(cast[pointer](node))
          let headThd =
            if desc.hwDesc != nil: hostTxHeadThd(hostTxHwDescAt(desc.hwDesc))
            else: nil
          if headThd != nil: statuses[captured] = headThd.flags
        inc counts[queue]
        inc captured
        node = node.next
  logFn(2, nil, "txl_cfm.c", 570, "---------- txl_cfm_dump ----------\r\n")
  logFn(2, nil, "txl_cfm.c", 572, "txl_cfm_env:\r\n")
  logFn(2, nil, "txl_cfm.c", 573,
        "  cfmlist: %d [AC_BK AC_BE AC_VI AC_VO AC_BEACON]\r\n", 5.cint)
  var cursor = 0
  for txConfirmQueueIndex in 0'u32 ..< 5'u32:
    let queuedConfirmCount = counts[txConfirmQueueIndex].int
    logFn(2, nil, "txl_cfm.c", 577, "    [%d] cfmlist cnt %d\r\n",
          txConfirmQueueIndex.cint, queuedConfirmCount.cint)
    logFn(2, nil, "txl_cfm.c", 581, "      cfm list:")
    for index in 0 ..< queuedConfirmCount:
      if printFn != nil:
        printFn(" %p(%08lx)", nodes[cursor], statuses[cursor].culong)
      inc cursor
    logFn(2, nil, "txl_cfm.c", 589, "\r\n")

proc txl_cfm_dma_int_handler_backup*() {.exportc, cdecl.} =
  ## Backup DMA interrupt handler for TX confirm.
  ## The vendor relocation targets the status word at ps_env + 4.
  let ps = psEnvView()
  ps.statusFlags = ps.statusFlags and not 1'u32

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
  ## Finally clears the sequence counter halfword at offset 84.
  # Blob order: txl_hwdesc_init FIRST, then buffer/cfm/frame
  txlInvalidateDmaAll()
  txSecurityReset()
  co_list_init(addr txRecoveryPostponed)
  txl_hwdesc_init()
  txl_buffer_init()
  txl_cfm_init()
  txl_frame_init(0)
  let txCtrl = txControlEnv()
  discard c_memset(txCtrl, 0, 92.csize_t)
  for ac in 0'u32 ..< NUM_TX_QUEUES.uint32:
    let acCtrl = txControlAc(ac)
    # co_list_init on the list at offset 4
    co_list_init(addr acCtrl.pending)
    # Clear first descriptor pointer
    acCtrl.current = nil
    acCtrl.packetCount = ipcTxHwDescWordHalfword(ac)
    # Clear busy flag
    acCtrl.busyFlag = 0
  txCtrl.seqCounter = 0
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
  ## Nim publishes software ownership and counts before starting DMA, and
  ## finishes descriptor-dependent work before that handoff can complete.
  let saved = irqSave()
  defer: irqRestore(saved)
  let desc = hostTxDescAt(param)
  if desc == nil:
    return 0'u8
  let identity = txlCaptureSession(desc)
  template ensurePreparedSession() =
    if not txlSessionCurrent(identity, desc) or not txSecurityCurrent(desc):
      if desc.queueFirst == nil:
        txl_frame_release(param, false)
      else:
        desc.bufDesc = nil
        txuCancelFrame(param, ac)
      return 0'u8
  ensurePreparedSession()
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
  # Check desc[8] for existing queue chain (blob at 0x56)
  let queueFirst = desc.queueFirst
  let protoTrace = desc.frameLen
  if protoTrace == 0x8E88'u16 or protoTrace == 0x888E'u16:
    nimFwTrace2U32("[WIFI-NIMFW] txl_push_eapol ",
                   ac.uint32 or (desc.staIdx.uint32 shl 8) or
                     (desc.vifIdx.uint32 shl 16) or
                     (desc.staInfoIdx.uint32 shl 24),
                   cast[uint32](cast[uint](queueFirst)))
  ensurePreparedSession()
  if queueFirst != nil:
    # Queue exists: allocate buffer and update THD (blob: .L119 at 0xc6)
    let bufDesc = txlPrepareBuffer(param, ac.uint32, 0'u32)
    ensurePreparedSession()
    if bufDesc == nil:
      desc.bufDesc = nil
      txuCancelFrame(param, ac)
      return 0'u8
    desc.bufDesc = bufDesc
    hostTxBufferedLinkAt(bufDesc).txDesc = param
    if not txlBuildBufferThd(param):
      desc.bufDesc = nil
      txuCancelFrame(param, ac)
      return 0'u8
    ensurePreparedSession()
  # Complete per-peer work before DMA publication can return the descriptor.
  let vifIdx = desc.vifIdx
  let staIdx = desc.staInfoIdx
  td_pck_ind(vifIdx, staIdx, 0)
  ensurePreparedSession()
  # Power save check (blob: ps_check_tx_frame(desc[49], desc[46]) at 0xb0).
  # desc[46] carries the TX TID/AC selector for the vendor PS path.
  let txTid = desc.staIdx
  discard ps_check_tx_frame(staIdx, txTid)
  ensurePreparedSession()
  # Software ownership and accounting must precede the first hardware trigger.
  txlEnqueuePrepared(param, desc.bufDesc, ac.uint32)
  co_list_push_back(addr txControlAc(ac.uint32).pending, cast[ptr CoListHdr](param))
  let txCtrl = txControlEnv()
  txCtrl.packetCounter = txCtrl.packetCounter + 1
  txl_payload_handle_backup(nil)
  # No descriptor access after this call: completion may have recycled it.
  return 0'u8

proc txl_cntrl_push_int*(param: pointer, ac: uint8): uint8 {.exportc, cdecl.} =
  ## Push an internal frame to TX control (92 instrs / 0x116 bytes in blob).
  ## Blob call graph: txl_cntrl_tx_check, apm_tx_int_ps_check,
  ##   txl_int_fake_transfer, co_list_push_back(x2), txl_payload_handle_backup,
  ##   txl_frame_release, apm_tx_int_ps_postpone.
  let saved = irqSave()
  defer: irqRestore(saved)
  let desc = hostTxDescAt(param)
  if ac >= NUM_TX_QUEUES.uint8:
    if desc != nil:
      txl_frame_release(param, false)
    return 0
  if not txlStationAdmits(desc):
    if desc != nil:
      txl_frame_release(param, false)
    return 0
  let identity = txlCaptureSession(desc)
  let generation = txlFrameLeaseToken(desc)
  template ensureInternalPreparation() =
    if not txlFrameLeaseMatches(desc, generation):
      return 0'u8
    if not txlSessionCurrent(identity, desc) or not txlStationAdmits(desc) or
        not txSecurityCurrent(desc):
      txl_frame_release(param, false)
      return 0'u8
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
  ensureInternalPreparation()
  let chanEnvForDiag = chanEnvView()
  nimFwDbgTxIntLastMeta =
    ac.uint32 or (vifIdxTx.uint32 shl 8) or
    (desc.staIdx.uint32 shl 16) or (desc.staInfoIdx.uint32 shl 24)
  let onChannel = chan_is_on_channel(vifEntryTx)
  ensureInternalPreparation()
  nimFwDbgTxIntLastChan =
    txReady.uint32 or
    (onChannel.uint32 shl 8) or
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
    ensureInternalPreparation()
    let chanEnvTrace = chanEnvView()
    let curCtxtTrace = chanEnvTrace.currentCtxt
    let schedCtxtTrace = chanEnvTrace.scheduledCtxt
    let vifCtxtTrace = vifTx.chanCtxt
    let flagsTrace = chanEnvTrace.flags
    let cntTrace = chanEnvTrace.ctxtCount
    let onChanTrace = chan_is_on_channel(vifEntryTx)
    ensureInternalPreparation()
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
    ensureInternalPreparation()
    nimFwTrace2U32("[WIFI-NIMFW] txint_ptrs ",
                   cast[uint32](cast[uint](curCtxtTrace)),
                   cast[uint32](cast[uint](schedCtxtTrace)))
    ensureInternalPreparation()
    nimFwTrace2U32("[WIFI-NIMFW] txint_vifct ",
                   cast[uint32](cast[uint](vifEntryTx)),
                   cast[uint32](cast[uint](vifCtxtTrace)))
    ensureInternalPreparation()
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] txint_enter ",
                            ac.uint32 or (vifIdxTx.uint32 shl 8) or
                              (desc.staInfoIdx.uint32 shl 16),
                            txReady.uint32 or (onChanTrace.uint32 shl 8) or
                              (flagsTrace.uint32 shl 16) or (cntTrace.uint32 shl 24))
      ensureInternalPreparation()
      let linkRawTrace = hostTxLinkDescAt(linkPtrTrace)
      nimFwConnectTraceBytes("[WIFI-RAW] tx_mgt ",
                             cast[pointer](addr linkRawTrace.macHeader[0]),
                             hostTxHwDescAt(desc.hwDesc).frameLen,
                             96)
      ensureInternalPreparation()
      nimFwConnectTrace2U32("[WIFI-CT] txint_ctxt ",
                            cast[uint32](cast[uint](curCtxtTrace)),
                            cast[uint32](cast[uint](vifCtxtTrace)))
      ensureInternalPreparation()
  if txReady:
    inc nimFwDbgTxIntReady
    # TX allowed: check AP PS state
    # Step 2: apm_tx_int_ps_check (blob 0x50)
    let psOk = apm_tx_int_ps_check(param)
    ensureInternalPreparation()
    if psOk:
      inc nimFwDbgTxIntPsOk
    if traceMgmt:
      let chanEnv = chanEnvView()
      let curCtxt = chanEnv.currentCtxt
      let pendCtxt = chanEnv.scheduledCtxt
      nimFwTrace2U32("[WIFI-NIMFW] txint_ready ",
                     txReady.uint32 or (psOk.uint32 shl 8),
                     cast[uint32](cast[uint](curCtxt) xor cast[uint](pendCtxt)))
      ensureInternalPreparation()
      when defined(bl808WifiConnectTrace):
        nimFwConnectTrace2U32("[WIFI-CT] txint_ready ",
                              txReady.uint32 or (psOk.uint32 shl 8),
                              cast[uint32](cast[uint](curCtxt) xor cast[uint](pendCtxt)))
        ensureInternalPreparation()
    if psOk:
      # Success path: set rcStats flag, DMA transfer, push to queue
      let rcStats = hostTxHwDescAt(rcStatsPtr)
      rcStats.controlFlags = rcStats.controlFlags or 0x100

      if traceMgmt:
        nimFwTrace2U32("[WIFI-NIMFW] txint_push ",
                       txCtrl.packetCounter + 1,
                       cast[uint32](cast[uint](desc.hwDesc)))
        ensureInternalPreparation()
        when defined(bl808WifiConnectTrace):
          nimFwConnectTrace2U32("[WIFI-CT] txint_push ",
                                txCtrl.packetCounter + 1,
                                cast[uint32](cast[uint](desc.hwDesc)))
          ensureInternalPreparation()
      # No callouts between backup/pending publication and accounting.
      txl_int_fake_transfer(param, ac.uint32)
      co_list_push_back(addr txControlAc(ac.uint32).pending, cast[ptr CoListHdr](param))
      txCtrl.packetCounter = txCtrl.packetCounter + 1
      if isTrackedNullFrame:
        inc nimFwDbgNullFrameQueued
      inc nimFwDbgTxIntPush
      txl_payload_handle_backup(param)
      # Ownership may have completed or moved to a new lease during the drain.
      return 1'u8
    # PS check failed: fall through to the not-ready/postpone path.

  # Not-ready path (L103): check STA for off-channel deferral
  let staInstNbr = desc.staInfoIdx
  if staInstNbr == 0xFF:
    inc nimFwDbgTxIntRelease
    if traceMgmt:
      nimFwTrace2U32("[WIFI-NIMFW] txint_release ",
                     txReady.uint32, staInstNbr.uint32)
      ensureInternalPreparation()
      when defined(bl808WifiConnectTrace):
        nimFwConnectTrace2U32("[WIFI-CT] txint_release ",
                              txReady.uint32, staInstNbr.uint32)
        ensureInternalPreparation()
    # No STA: release frame (blob: txl_frame_release at 0x42)
    txl_frame_release(param, false)
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
    ensureInternalPreparation()
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] txint_postpone ",
                            txReady.uint32 or (staInstNbr.uint32 shl 8),
                            pointerAddrU32(staEntry))
      ensureInternalPreparation()
  # Store MAC time if not already pending
  if desc.pendingMacTime == 0:
    let timestamp = macTimeNow()
    ensureInternalPreparation()
    desc.pendingMacTime = timestamp
  # Push to STA pending list (blob: co_list_push_back at 0xE2)
  co_list_push_back(addr sta.postponedList, cast[ptr CoListHdr](param))
  # Count the owner before PS notification can drain the postponed queue.
  let frameEnv = txFrameEnv()
  frameEnv.postponedCount = frameEnv.postponedCount + 1
  apm_tx_int_ps_postpone(param, staEntry)
  return 1'u8

proc txl_cntrl_push_int_force*(param: pointer, ac: uint8): uint8 {.exportc, cdecl.} =
  ## Force push an internal frame to TX control (106 bytes in blob).
  ## Blob: set rcStats[60]|=0x100, irqSave, txl_int_fake_transfer,
  ## co_list_push_back, irqRestore, increment pktCnt, txl_payload_handle_backup.
  let saved = irqSave()
  defer: irqRestore(saved)
  let desc = hostTxDescAt(param)
  if ac >= NUM_TX_QUEUES.uint8:
    if desc != nil:
      txl_frame_release(param, false)
    return 0
  if not txlStationAdmits(desc) or not txSecurityCurrent(desc):
    if desc != nil:
      txl_frame_release(param, false)
    return 0
  # Read RC stats from param[112] and set pending flag
  let rcStats = hostTxHwDescAt(hostTxDescAt(param).hwDesc)
  rcStats.controlFlags = rcStats.controlFlags or 0x100
  # Fake DMA transfer setup (blob: txl_int_fake_transfer at 0x20)
  txl_int_fake_transfer(param, ac.uint32)
  # Push to AC queue
  co_list_push_back(addr txControlAc(ac.uint32).pending, cast[ptr CoListHdr](param))
  # Increment packet counter
  let txCtrl = txControlEnv()
  txCtrl.packetCounter = txCtrl.packetCounter + 1
  # Handle TX backup/scheduling (blob: txl_payload_handle_backup at 0x52)
  txl_payload_handle_backup(param)
  return 1'u8

proc txl_cntrl_halt_ac*(ac: uint8): bool {.exportc, cdecl.} =
  ## Halt TX for a specific access category by writing to MAC HW TX trigger
  ## register (0x24B08180) with an AC-specific bitmask, then polling the
  ## status register (0x24B08188) until the AC's bits clear, and finally
  ## writing the clear bitmask to the clear register (0x24B08184).
  ## From disassembly (65 instrs).
  const
    MACHW_TX_TRIG_SET  = 0x24B08180'u  # TX trigger set register
    MACHW_TX_TRIG_STAT = 0x24B08188'u  # TX trigger status register
    MACHW_TX_TRIG_CLR  = 0x24B08184'u  # TX trigger clear register
    triggerMasks = [0x10000'u32, 0x20000, 0x40000, 0x80000, 0x8000]
    statusMasks = [0x30'u32, 0x300, 0x3000, 0x30000, 0x03]
  if ac >= NUM_TX_QUEUES.uint8:
    assert_err("txl_cntrl.c", "txl_cntrl.c", 0x700)
    return false
  let saved = irqSave()
  defer: irqRestore(saved)
  if txlResetting():
    return false
  regWrite(MACHW_TX_TRIG_SET, triggerMasks[ac])
  # Trigger bits and DMA status fields occupy different bit positions.
  # Do not release descriptors after a poll timeout while DMA still owns them.
  var remaining = WifiHwPollLimit
  while (regRead(MACHW_TX_TRIG_STAT) and statusMasks[ac]) != 0:
    if remaining == 0:
      noteHwWaitTimeout(MACHW_TX_TRIG_STAT.uint32, statusMasks[ac])
      txControlEnv().resetInProgress = 1
      txlInvalidateDmaAll()
      hal_machw_disable_int()
      ke_evt_set(0x80000000'u32)
      return false
    dec remaining
  regWrite(MACHW_TX_TRIG_CLR, triggerMasks[ac])
  true

proc txlDetachAc(ac: uint8; flushMask: uint32; batch: var TxFlushBatch) =
  # The caller has halted this AC. Publish its detached ownership before any
  # callback can enter another retirement or submit a new hardware chain.
  txlInvalidateDmaAc(ac)
  let activeAcReg = MACHW_INTC_BASE + 0x08C'u  # active AC bitmask register
  let setAcReg = MACHW_INTC_BASE + 0x088'u     # AC mask set register
  let curActive = regRead(activeAcReg)
  let acHwMask = 1'u32 shl ac
  let control = txControlAc(ac.uint32)
  let confirmations = txCfmList(ac.uint32)
  batch = TxFlushBatch(previous: txActiveFlush, ac: ac, status: flushMask,
                       pending: control.pending, confirmations: confirmations[])
  txActiveFlush = addr batch
  co_list_init(addr control.pending)
  co_list_init(confirmations)
  control.current = nil
  txlAcPending[ac] = 0
  txlAcBusy[ac] = false
  # The vendor's argumentless buffer_reset clears only AC0. Each AC has its
  # own backup links, and callbacks must not encounter the retired chain.
  txlBufferEnvView().backupQueues[ac].first = nil
  txlBufferEnvView().backupQueues[ac].last = nil
  regWrite(activeAcReg, curActive and (not acHwMask))
  regWrite(setAcReg, acHwMask)

proc txlFlushScopeExit(previous: ptr TxFlushBatch) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var batch = txActiveFlush
  var recovery = false
  while batch != previous and batch != nil:
    if batch.confirmations.first != nil or batch.pending.first != nil or
        batch.postponed.first != nil:
      if not recovery:
        # Reattached queues must not resume DMA before reset completes.
        txControlEnv().resetInProgress = 1
        txlInvalidateDmaAll()
        hal_machw_disable_int()
        recovery = true
      if batch.confirmations.first != nil:
        co_list_concat(txCfmList(batch.ac.uint32), addr batch.confirmations)
      if batch.pending.first != nil:
        co_list_concat(addr txControlAc(batch.ac.uint32).pending, addr batch.pending)
      co_list_concat(addr txRecoveryPostponed, addr batch.postponed)
    batch.confirmations = default(CoList)
    batch.pending = default(CoList)
    batch.postponed = default(CoList)
    batch = batch.previous
  txActiveFlush = previous
  if recovery:
    ke_evt_set(0x80000000'u32)

proc txl_cntrl_flush_ac*(ac: uint8, flushMask: uint32) {.exportc, cdecl.} =
  ## Caller has halted this AC with interrupts disabled.
  if ac >= NUM_TX_QUEUES.uint8:
    assert_err("txl_cntrl.c", "txl_cntrl.c", 0x700)
    return
  var batch: TxFlushBatch
  txlDetachAc(ac, flushMask, batch)
  defer: txlFlushScopeExit(batch.previous)
  # First flush: per-AC txl_cfm_env list.
  txl_cfm_flush(ac, addr batch.confirmations, flushMask)
  # Second flush: per-AC list at txl_cntrl_env[ac*16+4].
  txl_cfm_flush(ac, addr batch.pending, flushMask)

proc txl_cntrl_clear_ac*(ac: uint8): bool {.exportc, cdecl.} =
  ## Clear TX queue for a specific AC.
  ## Blob (18 instrs): saves IRQ state (csrrci mstatus,8), calls
  ## txl_cntrl_halt_ac(ac), then txl_cntrl_flush_ac(ac, 0x40000000),
  ## restores IRQ state.
  let saved = irqSave()
  defer: irqRestore(saved)
  if not txl_cntrl_halt_ac(ac): return false
  txl_cntrl_flush_ac(ac, 0x40000000'u32)
  true

proc txl_cntrl_clear_bcn_ac*(): bool {.exportc, cdecl.} =
  ## Clear beacon TX queue (18 instrs in blob).
  ## From blob: saves IRQ state (csrrci mstatus,8), calls txl_cntrl_halt_ac(4),
  ## then txl_cntrl_flush_ac(4) with 0x40000000 bitmask, restores IRQ state.
  let saved = irqSave()
  defer: irqRestore(saved)
  if not txl_cntrl_halt_ac(4): return false
  txl_cntrl_flush_ac(4, 0x40000000'u32)
  true

proc txl_cntrl_clear_all_ac*(): bool {.exportc, cdecl.} =
  ## Clear all TX queues.
  ## From disassembly (46 instrs): saves IRQ state, then for each AC (4,0,1,2,3)
  ## calls txl_cntrl_halt_ac to stop MAC HW TX, then txl_cntrl_flush_ac with
  ## 0x40000000 to flush pending descriptors. Finally restores IRQ state.
  let saved = irqSave()
  defer: irqRestore(saved)
  # BCN queue first (AC 4), then data queues 0..3
  if not txl_cntrl_halt_ac(4): return false
  txl_cntrl_flush_ac(4, 0x40000000'u32)
  if not txl_cntrl_halt_ac(0): return false
  txl_cntrl_flush_ac(0, 0x40000000'u32)
  if not txl_cntrl_halt_ac(1): return false
  txl_cntrl_flush_ac(1, 0x40000000'u32)
  if not txl_cntrl_halt_ac(2): return false
  txl_cntrl_flush_ac(2, 0x40000000'u32)
  if not txl_cntrl_halt_ac(3): return false
  txl_cntrl_flush_ac(3, 0x40000000'u32)
  true

proc txlQueueReferencesStation(queue: ptr CoList; staIdx: uint8): bool =
  var node = queue.first
  while node != nil:
    if hostTxDescAt(cast[pointer](node)).staInfoIdx == staIdx:
      return true
    node = node.next

proc txlQueueReferencesVif(queue: ptr CoList; vifIdx: uint8): bool =
  var node = queue.first
  while node != nil:
    if hostTxDescAt(cast[pointer](node)).vifIdx == vifIdx:
      return true
    node = node.next

proc txlDrainRetiredPostponed(queue: ptr CoList) =
  while queue.first != nil:
    let frame = hostTxDescAt(co_list_pop_front(queue))
    frame.postponeFlag = 0
    let env = txFrameEnv()
    if env.postponedCount != 0:
      dec env.postponedCount
    txl_frame_release(frame, true)

proc txlVifIsRetiring(vifIdx: uint8): bool =
  vifIdx < MAX_VIFS.uint8 and
    (txRetiringVifMask and (1'u32 shl vifIdx)) != 0 and
    txRetiringVifEpochs[vifIdx] == rxVifEpochs[vifIdx]

proc txlHaltVifQueues(vifIdx: uint8; selected: var uint8): bool =
  selected = 0
  if txlResetting(): return false
  for ac in 0'u8 ..< NUM_TX_QUEUES.uint8:
    if txlQueueReferencesVif(addr txControlAc(ac.uint32).pending, vifIdx) or
        txlQueueReferencesVif(txCfmList(ac.uint32), vifIdx):
      if not txl_cntrl_halt_ac(ac): return false
      selected = selected or (1'u8 shl ac)
  true

proc txlHaltStationQueues(staIdx: uint8; selected: var uint8): bool =
  selected = 0
  if txlResetting(): return false
  for ac in 0'u8 ..< NUM_TX_QUEUES.uint8:
    if txlQueueReferencesStation(addr txControlAc(ac.uint32).pending, staIdx) or
        txlQueueReferencesStation(txCfmList(ac.uint32), staIdx):
      if not txl_cntrl_halt_ac(ac): return false
      selected = selected or (1'u8 shl ac)
  true

proc txl_retire_vif(vifIdx: uint8; selected: uint8) =
  # rxInvalidateVif has advanced the epoch with interrupts disabled.
  if vifIdx >= MAX_VIFS.uint8:
    return
  txlInvalidateDmaVif(vifIdx)
  let oldMask = txRetiringVifMask
  let oldEpoch = txRetiringVifEpochs[vifIdx]
  txRetiringVifMask = oldMask or (1'u32 shl vifIdx)
  txRetiringVifEpochs[vifIdx] = rxVifEpochs[vifIdx]
  defer:
    txRetiringVifMask = oldMask
    txRetiringVifEpochs[vifIdx] = oldEpoch

  let hostQueue = ipcEmbEnvView().hostTxList
  if hostQueue != nil:
    var node = hostQueue.first
    while node != nil:
      let frame = addr cast[ptr IpcHostTxWrapperView](node).txDesc
      if frame.vifIdx == vifIdx:
        # Preserve IPC list/active ownership. The normal consumer will confirm
        # this cancellation without indexing or modifying the replacement VIF.
        frame.vifIdx = 0xFF'u8
        frame.staInfoIdx = 0xFF'u8
      node = node.next

  let ancestors = txActiveFlush
  var batches: array[NUM_TX_QUEUES, TxFlushBatch]
  var postponed: TxFlushBatch
  defer: txlFlushScopeExit(ancestors)
  # The caller halted this selection before publishing the retired identity.
  for ac in 0'u8 ..< NUM_TX_QUEUES.uint8:
    if (selected and (1'u8 shl ac)) != 0:
      txlDetachAc(ac, 0x40000000'u32, batches[ac])
  for station in 0'u8 ..< STA_INFO_TAB_ENTRIES.uint8:
    let queue = addr staInfoForIdx(station).postponedList
    var node = queue.first
    while node != nil:
      let next = node.next
      if hostTxDescAt(cast[pointer](node)).vifIdx == vifIdx:
        co_list_extract(queue, node)
        co_list_push_back(addr postponed.postponed, node)
      node = next
  if postponed.postponed.first != nil:
    postponed.previous = txActiveFlush
    txActiveFlush = addr postponed

  for ac in 0'u8 ..< NUM_TX_QUEUES.uint8:
    if (selected and (1'u8 shl ac)) != 0:
      txl_cfm_flush(ac, addr batches[ac].confirmations, batches[ac].status)
      txl_cfm_flush(ac, addr batches[ac].pending, batches[ac].status)
  txlDrainRetiredPostponed(addr postponed.postponed)
  var batch = ancestors
  while batch != nil:
    if txlQueueReferencesVif(addr batch.confirmations, vifIdx):
      txl_cfm_flush(batch.ac, addr batch.confirmations, batch.status)
    if txlQueueReferencesVif(addr batch.pending, vifIdx):
      txl_cfm_flush(batch.ac, addr batch.pending, batch.status)
    if txlQueueReferencesVif(addr batch.postponed, vifIdx):
      txlDrainRetiredPostponed(addr batch.postponed)
    batch = batch.previous
  if txlQueueReferencesVif(addr txFrameEnv().usedList, vifIdx):
    txl_frame_evt()

proc txl_retire_station(staIdx: uint8; selected: uint8) =
  # The caller has invalidated/detached this station and disabled interrupts.
  # Preserve IPC ownership while preventing old queued frames binding to reuse.
  txlInvalidateDmaStation(staIdx)
  let hostQueue = ipcEmbEnvView().hostTxList
  if hostQueue != nil:
    var node = hostQueue.first
    while node != nil:
      let wrapper = cast[ptr IpcHostTxWrapperView](node)
      if wrapper.txDesc.staInfoIdx == staIdx:
        wrapper.txDesc.staInfoIdx = 0xFF'u8
      node = node.next
  let ancestors = txActiveFlush
  var batches: array[NUM_TX_QUEUES, TxFlushBatch]
  defer: txlFlushScopeExit(ancestors)
  for ac in 0'u8 ..< NUM_TX_QUEUES.uint8:
    if (selected and (1'u8 shl ac)) != 0:
      txlDetachAc(ac, 0x40000000'u32, batches[ac])
  for ac in 0'u8 ..< NUM_TX_QUEUES.uint8:
    if (selected and (1'u8 shl ac)) != 0:
      txl_cfm_flush(ac, addr batches[ac].confirmations, batches[ac].status)
      txl_cfm_flush(ac, addr batches[ac].pending, batches[ac].status)
  # These lists belong to paused outer flushes, whose hardware is already idle.
  var batch = ancestors
  while batch != nil:
    if txlQueueReferencesStation(addr batch.confirmations, staIdx):
      txl_cfm_flush(batch.ac, addr batch.confirmations, batch.status)
    if txlQueueReferencesStation(addr batch.pending, staIdx):
      txl_cfm_flush(batch.ac, addr batch.pending, batch.status)
    if txlQueueReferencesStation(addr batch.postponed, staIdx):
      txlDrainRetiredPostponed(addr batch.postponed)
    batch = batch.previous
  if txlQueueReferencesStation(addr txFrameEnv().usedList, staIdx):
    txl_frame_evt()

proc txl_cntrl_inc_pck_cnt*(ac: uint8) {.exportc, cdecl.} =
  ## Increment packet count for an AC.
  ## From blob (5 instrs): loads txl_cntrl_env word at offset 80 (packet count),
  ## increments by 1, stores back. AC arg is unused (global counter).
  let env = txControlEnv()
  env.packetCounter = env.packetCounter + 1

proc txl_cntrl_env_dump*() {.exportc, cdecl, noinline.} =
  ## Dump pending descriptors, their single policy table, and payload chain.
  let logFuncPtr = getLogFunc(204)
  if logFuncPtr == nil: return
  type
    LogFn = proc(level: uint32; tag, file: cstring; line: cint;
                 format: cstring) {.cdecl, varargs.}
    PrintFn = proc(format: cstring) {.cdecl, varargs.}
  let logFn = cast[LogFn](logFuncPtr)
  let printFn = cast[PrintFn](blOpsFunc(4))
  logFn(2, nil, "txl_cntrl.c", 0x925, "---------- txl_cntrl_env_dump ----\r\n")
  logFn(2, nil, "txl_cntrl.c", 0x927, "txl_cntrl_env:\r\n")
  logFn(2, nil, "txl_cntrl.c", 0x928,
        "  txlist: %d [AC_BK AC_BE AC_VI AC_VO AC_BEACON]\r\n", NUM_TX_QUEUES.cint)
  for ac in 0'u32 ..< NUM_TX_QUEUES.uint32:
    let acCtrl = txControlAc(ac)
    let listCnt = co_list_cnt(addr acCtrl.pending)
    let listFirst = cast[pointer](acCtrl.pending.first)
    logFn(2, nil, "txl_cntrl.c", 0x92C,
          "    [%d] transmitting header %p and cnt %d\r\n", ac.cint, listFirst, listCnt.cint)
    logFn(2, nil, "txl_cntrl.c", 0x931, "      transmitting list:")
    var curDesc = listFirst
    while printFn != nil and curDesc != nil:
      let desc = hostTxDescAt(curDesc)
      let status = if desc.hwDesc != nil: hostTxHwDescAt(desc.hwDesc).confirmStatus
                   else: 0'u32
      printFn(" %p(%08lx)", curDesc, status.culong)
      curDesc = desc.link.next
    logFn(2, nil, "txl_cntrl.c", 0x939, "\r\n")
    curDesc = cast[pointer](acCtrl.pending.first)
    while curDesc != nil:
      let desc = hostTxDescAt(curDesc)
      logFn(2, nil, "txl_cntrl.c", 0x8EF, "        txdesc@%p, pbuf %p:\r\n",
            curDesc, cast[pointer](desc.descriptorStatus.uint))
      if desc.hwDesc != nil:
        let dumpHw = txDumpHwDescAt(desc.hwDesc)
        let hw = addr dumpHw.hardware
        logFn(2, nil, "txl_cntrl.c", 0x8F0,
              "          thd %p, upatterntx %08lx, frmlen %4lu, policyentryaddr %08lx, macctrlinfo1 %08lx, macctrlinfo1 %08lx mediumtimeused %lu\r\n",
              addr hw.magic, hw.magic.culong, hw.frameLen.culong,
              cast[uint](hw.chainedThd).culong, hw.ackPolicyControl.culong,
              hw.controlFlags.culong, dumpHw.mediumTimeUsed.culong)
        let rateThdPtr = hw.chainedThd
        if rateThdPtr != nil:
          let rateDumpDesc = txDumpRateDescAt(rateThdPtr)
          logFn(2, nil, "txl_cntrl.c", 0x8FB,
                "          tbl %p, upatterntx %08lx, phyctrlinfo_1 %08lx, phyctrlinfo_2 %08lx, macctrlinfo_1 %08lx, macctrlinfo_2 %08lx\r\n",
                rateThdPtr, rateDumpDesc.rateDumpHeader0.culong,
                rateDumpDesc.rateDumpHeader1.culong, rateDumpDesc.rateDumpHeader2.culong,
                rateDumpDesc.rateDumpHeader3.culong, rateDumpDesc.macControl2.culong)
          logFn(2, nil, "txl_cntrl.c", 0x903, "            ratecntrlinfo: ")
          for primaryPolicyWord in rateDumpDesc.primaryPolicyWords:
            if printFn != nil:
              printFn(" %08lx", primaryPolicyWord.culong)
          logFn(2, nil, "txl_cntrl.c", 0x907, "\r\n")
          logFn(2, nil, "txl_cntrl.c", 0x908, "            powercntrlinfo:")
          for secondaryPolicyWord in rateDumpDesc.secondaryPolicyWords:
            if printFn != nil:
              printFn(" %08lx", secondaryPolicyWord.culong)
          logFn(2, nil, "txl_cntrl.c", 0x90C, "\r\n")
        var bufferDumpDescPtr = cast[pointer](hw.status.uint)
        var subIdx: uint32 = 0
        while bufferDumpDescPtr != nil:
          let bufferDumpDesc = txDumpBufferDescAt(bufferDumpDescPtr)
          let dataLen = bufferDumpDesc.dataEnd + 1'u32 - bufferDumpDesc.dataStart
          logFn(2, nil, "txl_cntrl.c", 0x911,
                "          pbd[%d] %4lu Bytes %p, upatterntx %08lx, next %08lx, datastartptr %08lx, dataendptr %08lx, bufctrlinfo %08lx\r\n",
                subIdx.cint, dataLen.culong, bufferDumpDescPtr,
                bufferDumpDesc.bufferDumpHeader.culong, cast[uint](bufferDumpDesc.next).culong,
                bufferDumpDesc.dataStart.culong, bufferDumpDesc.dataEnd.culong,
                bufferDumpDesc.control.culong)
          bufferDumpDescPtr = bufferDumpDesc.next
          inc subIdx
      curDesc = desc.link.next

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
  let savedIrq = irqSave()
  defer: irqRestore(savedIrq)
  if txActiveDmaOwner != nil:
    txDmaRescan = true
    return
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

  while true:
    txDmaRescan = false
    for ac in 0'u32 ..< NUM_TX_QUEUES.uint32:
      let acCtrl = txControlAc(ac)
      let backupHead = txBackupQueueHeadPtr(ac)
      var descPtr = backupHead[]

      if descPtr == nil:
        continue

      let acBit = 1'u32 shl ac

      while descPtr != nil:
        block dmaFrame:
          inc nimFwDbgPayDescFound
          let backupDesc = hostTxBufferedLinkAt(descPtr)
          let nextDesc = backupDesc.next

          # Store next as new backup head
          backupHead[] = nextDesc

          # Dereference desc[20] to get the actual TX descriptor (blob: s0 = a0[20])
          let actualDesc = backupDesc.txDesc
          let actualU = cast[uint](actualDesc)
          let actual = hostTxDescAt(actualDesc)
          var owner = TxDmaOwner(desc: actualDesc, vif: actual.vifIdx,
            station: actual.staInfoIdx, ac: ac.uint8)
          txActiveDmaOwner = addr owner
          defer: txActiveDmaOwner = nil
          template checkDmaOwner() =
            if owner.cancelled:
              break dmaFrame
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
              checkDmaOwner()
          if (fcTrace == 0xB0'u8 or fcTrace == 0x00'u8) and actualDesc != nil:
            let mgmtHw = hostTxHwDescAt(actual.hwDesc)
            let mgmtLen =
              if mgmtHw != nil and mgmtHw.frameLen >= 4'u32:
                mgmtHw.frameLen - 4'u32
              else:
                0'u32
            let mgmtMeta =
              (ac and 0xff'u32) or
              ((if actual.queueFirst != nil: 1'u32 else: 0'u32) shl 8) or
              (uint32(actual.staIdx) shl 16) or
              (uint32(actual.vifIdx) shl 24)
            let hw0 =
              if mgmtHw != nil: mgmtHw.payloadStart else: 0'u32
            let hw1 =
              if mgmtHw != nil: mgmtHw.payloadEnd else: 0'u32
            let hw2 =
              if mgmtHw != nil: mgmtHw.retryLimitControl else: 0'u32
            let hw3 =
              if mgmtHw != nil: mgmtHw.ackPolicyControl else: 0'u32
            if fcTrace == 0xB0'u8:
              nimFwDbgAuthPayMeta = mgmtMeta
              nimFwDbgAuthPayLen = mgmtLen or (uint32(actual.frameLen) shl 16)
              nimFwDbgAuthPayHw0 = hw0
              nimFwDbgAuthPayHw1 = hw1
              nimFwDbgAuthPayHw2 = hw2
              nimFwDbgAuthPayHw3 = hw3
            else:
              nimFwDbgAssocPayMeta = mgmtMeta
              nimFwDbgAssocPayLen = mgmtLen or (uint32(actual.frameLen) shl 16)
              nimFwDbgAssocPayHw0 = hw0
              nimFwDbgAssocPayHw1 = hw1
              nimFwDbgAssocPayHw2 = hw2
              nimFwDbgAssocPayHw3 = hw3

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
            checkDmaOwner()
            when defined(bl808WifiConnectTrace):
              nimFwConnectTrace2U32("[WIFI-CT] pay_enter ",
                                    ac or ((if hasPayload != nil: 1'u32 else: 0'u32) shl 8),
                                    cast[uint32](actualU))
              checkDmaOwner()
          if traceEapol:
            let macHdrTrace = cast[ptr MacDataFrameHeaderView](addr backupDesc.macHeader[0])
            let macFrameControlDurationWord =
              macHdrTrace.frameControl.uint32 or (macHdrTrace.duration.uint32 shl 16)
            let macHdrAddr3Word0 = macAddrWord0(addr macHdrTrace.addr3)
            checkDmaOwner()
            nimFwTrace2U32("[WIFI-NIMFW] pay_eapol ",
                           ac or ((if hasPayload != nil: 1'u32 else: 0'u32) shl 8),
                           cast[uint32](actualU))
            checkDmaOwner()
            nimFwTrace2U32("[WIFI-NIMFW] pay_eapol_hdr ",
                           macFrameControlDurationWord,
                           macHdrAddr3Word0)
            checkDmaOwner()
            when defined(bl808WifiConnectTrace):
              if nimFwDbgEapolTraceCount < 64'u32:
                nimFwConnectTrace2U32("[WIFI-CT] pay_eapol ",
                                      ac or ((if hasPayload != nil: 1'u32 else: 0'u32) shl 8) or
                                        (nimFwDbgEapolTraceCount shl 16),
                                      cast[uint32](actualU))
                checkDmaOwner()
                nimFwConnectTrace2U32("[WIFI-CT] pay_eapol_hdr ",
                                      macFrameControlDurationWord,
                                      macHdrAddr3Word0)
                checkDmaOwner()
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
            # For AC==4 (BCN), special beacon handling
            if ac == 4:
              let vif = vifChannelForIdx(actual.vifIdx)  # blob: lbu a3,47(s0)
              let timFlags = vif.timFlags
              let moreData = (backupDesc.macHeader[1] and 0x20'u8) != 0
              if moreData:
                vif.timFlags = timFlags or 2
              else:
                vif.timFlags = timFlags and not 2'u8

            # If sta_idx == 0xFF, format MAC header (blob calls txl_machdr_format)
            let staIdx = actual.staIdx  # blob: lbu a4,46(s0)
            if staIdx == 0xFF:
              txl_machdr_format(cast[pointer](addr backupDesc.macHeader[0]))
              checkDmaOwner()

            # Save link descriptor across call, read THD (s11), call txu_cntrl_tkip_mic_append
            let linkDesc = hostTxLinkDescAt(actual.bufDesc)
            let thd = hostTxHwDescAt(actual.hwDesc)  # saved as s11 across call
            txu_cntrl_tkip_mic_append(actualDesc)
            checkDmaOwner()

            # Copy the two MAC TX control trailer words that follow the 52-byte
            # rate template in TxBufferControlView into their hardware descriptor
            # destinations.
            thd.ackPolicyControl = linkDesc.ackPolicyControl
            thd.chainedThd = cast[pointer](hostTxRateTemplate(linkDesc))
            thd.retryLimitControl = linkDesc.retryLimitControl
            if fcTrace == 0xB0'u8:
              nimFwDbgAuthPayMeta = nimFwDbgAuthPayMeta or 0x80000000'u32
              nimFwDbgAuthPayHw2 = thd.retryLimitControl
              nimFwDbgAuthPayHw3 = thd.ackPolicyControl
            elif fcTrace == 0x00'u8:
              nimFwDbgAssocPayMeta = nimFwDbgAssocPayMeta or 0x80000000'u32
              nimFwDbgAssocPayHw2 = thd.retryLimitControl
              nimFwDbgAssocPayHw3 = thd.ackPolicyControl
            if lmacGateHalfword(actual.frameLen) == 0x0800'u16:
              let rateForDhcp = hostTxRateTemplate(linkDesc)
              nimFwDbgDhcpTxBufDesc = pointerAddrU32(actual.bufDesc)
              nimFwDbgDhcpTxHwDesc = pointerAddrU32(actual.hwDesc)
              captureDhcpTxRateRaw(rateForDhcp)
              checkDmaOwner()
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
              checkDmaOwner()
            if traceMgmt or traceEapol:
              nimFwTrace2U32("[WIFI-NIMFW] pay_rate ",
                             linkDesc.ackPolicyControl,
                             linkDesc.retryLimitControl)
              checkDmaOwner()
              if traceMgmt:
                when defined(bl808WifiConnectTrace):
                  nimFwConnectTrace2U32("[WIFI-CT] pay_rate ",
                                        linkDesc.ackPolicyControl,
                                        linkDesc.retryLimitControl)
                  checkDmaOwner()

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
            checkDmaOwner()
            if traceMgmt:
              when defined(bl808WifiConnectTrace):
                nimFwConnectTrace2U32("[WIFI-CT] pay_link ",
                                      ac or ((if listFirst == nil: 1'u32 else: 0'u32) shl 8),
                                      cast[uint32](thdLink) xor thdStatusBefore)
                checkDmaOwner()
                let linkTrace = hostTxLinkDescAt(actual.bufDesc)
                let rateTrace = hostTxRateTemplate(linkTrace)
                nimFwConnectTrace2U32("[WIFI-CT] pay_hw0 ",
                                      thdForLinkView.payloadEnd,
                                      thdForLinkView.frameLen)
                checkDmaOwner()
                nimFwConnectTrace2U32("[WIFI-CT] pay_hw1 ",
                                      thdForLinkView.retryLimitControl,
                                      pointerAddrU32(thdForLinkView.chainedThd))
                checkDmaOwner()
                nimFwConnectTrace2U32("[WIFI-CT] pay_hw2 ",
                                      thdForLinkView.ackPolicyControl,
                                      thdForLinkView.controlFlags)
                checkDmaOwner()
                nimFwConnectTrace2U32("[WIFI-CT] pay_pol0 ",
                                      rateTrace.magic,
                                      rateTrace.ntxConfig)
                checkDmaOwner()
                nimFwConnectTrace2U32("[WIFI-CT] pay_pol1 ",
                                      rateTrace.policyWord,
                                      rateTrace.rateWord)
                checkDmaOwner()
                nimFwConnectTrace2U32("[WIFI-CT] pay_pol2 ",
                                      rateTrace.retryRateControl2,
                                      cast[uint32](rateTrace.txPower))
                checkDmaOwner()
                nimFwConnectTrace2U32("[WIFI-CT] pay_pol3 ",
                                      rateTrace.retryTxPowerControl0,
                                      rateTrace.retryTxPowerControl1)
                checkDmaOwner()
                nimFwConnectTrace2U32("[WIFI-CT] pay_pol4 ",
                                      rateTrace.retryTxPowerControl2,
                                      linkTrace.ackPolicyControl)
                checkDmaOwner()
            if traceEapol:
              let link = hostTxBufferedLinkAt(actual.bufDesc)
              let rate = hostTxRateTemplate(link)
              nimFwTrace2U32("[WIFI-NIMFW] pay_desc0 ",
                             pointerAddrU32(actual.queueFirst),
                             actual.seqPassthrough.uint32)
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_desc1 ",
                             actual.bufferPtrs[0],
                             actual.bufferLens[0])
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_link0 ",
                             link.headerThd.magic,
                             pointerAddrU32(link.headerThd.next))
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_link1 ",
                             link.headerThd.payloadStart,
                             link.headerThd.payloadEnd)
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_hw0 ",
                             thdForLinkView.magic,
                             thdForLinkView.secondaryTxHwDescPtr)
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_hw1 ",
                             thdForLinkView.secondaryDescToStatusPadding,
                             thdForLinkView.status)
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_hw2 ",
                             thdForLinkView.frameLen,
                             thdForLinkView.retryLimitControl)
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_hw3 ",
                             pointerAddrU32(thdForLinkView.chainedThd),
                             thdForLinkView.ackPolicyControl)
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_hw4 ",
                             thdForLinkView.controlFlags,
                             thdForLinkView.confirmStatus)
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_buf0 ",
                             link.payloadThd[0].magic,
                             pointerAddrU32(link.payloadThd[0].next))
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_buf1 ",
                             link.payloadThd[0].payloadStart,
                             link.payloadThd[0].payloadEnd)
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_pol0 ",
                             rate.magic,
                             rate.ntxConfig)
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_pol1 ",
                             rate.bwMask,
                             rate.pendingCount)
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_pol2 ",
                             rate.policyWord,
                             rate.rateWord)
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_pol3 ",
                             rate.retryRateControl0,
                             rate.retryRateControl1)
              checkDmaOwner()
              nimFwTrace2U32("[WIFI-NIMFW] pay_pol4 ",
                             rate.retryRateControl2,
                             cast[uint32](rate.txPower))
              checkDmaOwner()
              when defined(bl808WifiConnectTrace):
                if nimFwDbgEapolTraceCount < 64'u32:
                  nimFwConnectTrace2U32("[WIFI-CT] pay_desc0 ",
                                        pointerAddrU32(actual.queueFirst),
                                        actual.seqPassthrough.uint32)
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_desc1 ",
                                        actual.bufferPtrs[0],
                                        actual.bufferLens[0])
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_link0 ",
                                        link.headerThd.magic,
                                        pointerAddrU32(link.headerThd.next))
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_link1 ",
                                        link.headerThd.payloadStart,
                                        link.headerThd.payloadEnd)
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_hw0 ",
                                        thdForLinkView.magic,
                                        thdForLinkView.secondaryTxHwDescPtr)
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_hw1 ",
                                        thdForLinkView.secondaryDescToStatusPadding,
                                        thdForLinkView.status)
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_hw2 ",
                                        thdForLinkView.frameLen,
                                        thdForLinkView.retryLimitControl)
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_hw3 ",
                                        pointerAddrU32(thdForLinkView.chainedThd),
                                        thdForLinkView.ackPolicyControl)
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_hw4 ",
                                        thdForLinkView.controlFlags,
                                        thdForLinkView.confirmStatus)
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_buf0 ",
                                        link.payloadThd[0].magic,
                                        pointerAddrU32(link.payloadThd[0].next))
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_buf1 ",
                                        link.payloadThd[0].payloadStart,
                                        link.payloadThd[0].payloadEnd)
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_pol0 ",
                                        rate.magic,
                                        rate.ntxConfig)
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_pol1 ",
                                        rate.bwMask,
                                        rate.pendingCount)
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_pol2 ",
                                        rate.policyWord,
                                        rate.rateWord)
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_pol3 ",
                                        rate.retryRateControl0,
                                        rate.retryRateControl1)
                  checkDmaOwner()
                  nimFwConnectTrace2U32("[WIFI-CT] pay_pol4 ",
                                        rate.retryRateControl2,
                                        cast[uint32](rate.txPower))
                  checkDmaOwner()
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
            let ipcSharedBase = regRead(0x24B00120'u)
            checkDmaOwner()
            let dmaStatus = machwTxDmaStatus()
            checkDmaOwner()
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
              checkDmaOwner()
              if traceMgmt:
                when defined(bl808WifiConnectTrace):
                  nimFwConnectTrace2U32("[WIFI-CT] pay_dma ",
                                        ac or (dmaField shl 8),
                                        dmaStatus)
                  checkDmaOwner()
            if assertLine != 0 and dmaField == 2:
              assert_rec("txl_payload.c", "txl_payload.c", assertLine)
              checkDmaOwner()
            else:
              var trigBits: uint32 = 0
              case ac
              of 0:
                machwTxSetHead(ac, thdLink)
                checkDmaOwner()
                trigBits = 512
              of 1:
                machwTxSetHead(ac, thdLink)
                checkDmaOwner()
                trigBits = 1024
              of 2:
                machwTxSetHead(ac, thdLink)
                checkDmaOwner()
                trigBits = 2048
              of 3:
                machwTxSetHead(ac, thdLink)
                checkDmaOwner()
                trigBits = 4096
              of 4:
                machwTxSetHead(ac, thdLink)
                checkDmaOwner()
                trigBits = 256
              else:
                discard
              machwTxTrigger(trigBits)
              checkDmaOwner()
              nimFwDbgPayTriggerLast = trigBits or (ac shl 16) or 0x80000000'u32
              nimFwDbgPayTxStatus = machwTxStatus()
              checkDmaOwner()
              nimFwDbgPayTxAgg = machwTxAggActive()
              checkDmaOwner()
              nimFwDbgPayTxDma = dmaStatus
              nimFwDbgPayTxCurrent = pointerAddrU32(acCtrl.current)
              nimFwDbgPayTxThd = pointerAddrU32(thdLink)
              nimFwDbgPayTxHead = machwTxHeadValue(ac)
              checkDmaOwner()
              if isTrackedNullFrame:
                nimFwDbgNullFramePayTrigger = nimFwDbgPayTriggerLast
              blmac_abs_timer_set(ac, timerVal)
              checkDmaOwner()
              # Set HW aggregation bits
              machwTxAggSet(acBit)
              checkDmaOwner()
              let aggOr = machwTxAggActive()
              checkDmaOwner()
              machwTxAggActiveSet(acBit or aggOr)
              checkDmaOwner()
              if traceMgmt or traceEapol:
                nimFwTrace2U32("[WIFI-NIMFW] pay_regs ",
                               machwTxStatus(),
                               machwTxAggActive())
                checkDmaOwner()
                if traceMgmt:
                  when defined(bl808WifiConnectTrace):
                    nimFwConnectTrace2U32("[WIFI-CT] pay_regs ",
                                          machwTxStatus(),
                                          machwTxAggActive())
                    checkDmaOwner()
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
            checkDmaOwner()
            nimFwDbgPayTriggerLast = triggerVal or (ac shl 16) or 0x40000000'u32
            nimFwDbgPayTxStatus = machwTxStatus()
            checkDmaOwner()
            nimFwDbgPayTxAgg = machwTxAggActive()
            checkDmaOwner()
            nimFwDbgPayTxDma = machwTxDmaStatus()
            checkDmaOwner()
            nimFwDbgPayTxCurrent = pointerAddrU32(acCtrl.current)
            nimFwDbgPayTxThd = pointerAddrU32(thdLink)
            nimFwDbgPayTxHead = machwTxHeadValue(ac)
            checkDmaOwner()
            if isTrackedNullFrame:
              nimFwDbgNullFramePayTrigger = nimFwDbgPayTriggerLast
            if traceMgmt or traceEapol:
              nimFwTrace2U32("[WIFI-NIMFW] pay_regs ",
                             machwTxStatus(),
                             machwTxAggActive())
              checkDmaOwner()
              if traceMgmt:
                when defined(bl808WifiConnectTrace):
                  nimFwConnectTrace2U32("[WIFI-CT] pay_regs ",
                                        machwTxStatus(),
                                        machwTxAggActive())
                  checkDmaOwner()

          # Update list head
          acCtrl.current = thdLink
        # Reentrant teardown/submission may have replaced the remaining queue.
        descPtr = backupHead[]
    if not txDmaRescan:
      break

proc txlTriggerFrameCurrent(owner: ptr TxDmaOwner; desc: ptr HostTxDescView;
    hardware: ptr HostTxHwDescView; pending: ptr CoList; buffer, hostMarker: pointer;
    hardwareTarget, secondaryTarget: uint32): bool {.noinline.} =
  not owner.cancelled and desc.hwDesc == cast[pointer](hardware) and
    desc.bufDesc == buffer and desc.queueFirst == hostMarker and
    desc.vifIdx == owner.vif and desc.staInfoIdx == owner.station and
    hardware.txConfirmDescPtr == hardwareTarget and
    hardware.secondaryTxHwDescPtr == secondaryTarget and
    cast[pointer](pending.first) == cast[pointer](desc)

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
  let savedIrq = irqSave()
  defer: irqRestore(savedIrq)
  if txActiveTriggerOwner != nil:
    return
  var owner = TxDmaOwner(vif: 0xFF, station: 0xFF, ac: 0xFF)
  txActiveTriggerOwner = addr owner
  defer: txActiveTriggerOwner = nil
  template requireTrigger() =
    if owner.cancelled: return
  inc nimFwDbgTxTrigEntry
  const
    IPC_SHARED_TX_BASE  = 0x24B00120'u
    TX_TIMEOUT_LOCAL    = [200000'u32, 2000000'u32, 400000'u32, 200000'u32, 50000'u32]

  # Check MAC HW TX status. The reference path uses only bits [10:6];
  # higher halt/status bits are not queue-ready indications.
  let txStatus = machwTxStatus()
  requireTrigger()
  let acReady = txStatus and 0x7C0'u32  # bits [10:6]
  nimFwDbgTxTrigAcReady = txStatus
  if acReady == 0:
    inc nimFwDbgTxTrigZeroExit
    return  # No ACs ready for transmission

  # Compute highest-priority AC from CLZ: s0 = 25 - CLZ(acReady)
  var clzResult: cint
  {.emit: [clzResult, " = __builtin_clz((unsigned int)", acReady, ");"].}
  # Blob keeps an assert_err for `ac > 4`. Under upstream GCC -Os the
  # compiler knows `acReady` has bits only in [10:6] so `ac` is always
  # <=4 and elides the check. Use a volatile to defeat the range analysis.
  var acV {.volatile.}: uint32 = 25'u32 - clzResult.uint32
  let ac = acV
  owner.ac = ac.uint8
  if ac > 4:
    assert_err("txl_cntrl.c", "txl_cntrl.c", 0x86C)

  # Set up masks: acBit = 1 << ac, clearMask = ~(1 << ac)
  let clearMask = not (1'u32 shl ac)

  # Store the AC readiness bit to INTC trigger register for HW readback
  let readyBit = 1'u32 shl (ac + 6)
  machwTxReadyAck(readyBit)
  requireTrigger()

  let acCtrl = txControlAc(ac)

  # Main loop (.L137): drain this AC until the vendor exit condition.
  while true:
    owner.desc = nil
    owner.vif = 0xFF
    owner.station = 0xFF
    inc nimFwDbgTxTrigLoops
    let descPtr = cast[pointer](acCtrl.pending.first)
    if descPtr == nil:
      inc nimFwDbgTxTrigNoDesc
      # No descriptor (.L130): clear AC bit in INTC status, clear cntrl_env[0]
      let intcStat = machwTxAggActive()
      requireTrigger()
      if acCtrl.pending.first != nil: continue
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
      requireTrigger()
      if acCtrl.pending.first != nil: return
      machwTxAggActiveSet(intcStat and clearMask)
      return

    # Read THD from descriptor at offset 112
    let desc = hostTxDescAt(descPtr)
    owner.desc = descPtr
    owner.vif = desc.vifIdx
    owner.station = desc.staInfoIdx
    let descAddr = cast[uint](desc)
    var linkPtrTrace = desc.bufDesc
    let hardwarePtr = desc.hwDesc
    let hostMarker = desc.queueFirst
    if hardwarePtr == nil:
      assert_rec("txl_cntrl.c", "TX hardware descriptor", 0)
      return
    let linkTrace = hostTxBufferedLinkAt(linkPtrTrace)
    let fcTrace = if linkTrace != nil: linkTrace.macHeader[0] else: 0'u8
    let fcTrace1 = if linkTrace != nil: linkTrace.macHeader[1] else: 0'u8
    let traceMgmt = linkPtrTrace != nil and nimFwMgmtFcTrace(fcTrace)
    let protoTrace = desc.frameLen
    let traceEapol = protoTrace == 0x8E88'u16 or protoTrace == 0x888E'u16
    let hwDesc = hostTxHwDescAt(desc.hwDesc)
    let hardwareTarget = hwDesc.txConfirmDescPtr
    let secondaryTarget = hwDesc.secondaryTxHwDescPtr
    template requireFrame() =
      if not txlTriggerFrameCurrent(addr owner, desc, hwDesc, addr acCtrl.pending,
          linkPtrTrace, hostMarker, hardwareTarget, secondaryTarget):
        return
    let thdAddr = cast[uint](hwDesc)
    let thdStatus = cast[int32](hwDesc.confirmStatus)
    nimFwDbgTxTrigLastDesc = pointerAddrU32(descPtr)
    nimFwDbgTxTrigLastStatus = hwDesc.confirmStatus
    if traceMgmt or traceEapol:
      nimFwTrace2U32("[WIFI-NIMFW] txtrig_desc ",
                     ac.uint32 or (txStatus shl 8),
                     cast[uint32](thdStatus))
      requireFrame()
      if traceMgmt:
        when defined(bl808WifiConnectTrace):
          nimFwConnectTrace2U32("[WIFI-CT] txtrig_desc ",
                                ac.uint32 or (txStatus shl 8),
                                cast[uint32](thdStatus))
          requireFrame()
    if thdStatus >= 0:
      inc nimFwDbgTxTrigNotReady
      return  # THD not ready (bit 31 clear) -- .L126

    # Check for chained descriptors at desc[8] and desc[108]
    let nextDesc = desc.queueFirst
    if nextDesc != nil:
      let chainedThd = desc.bufDesc
      if chainedThd != nil:
        desc.bufDesc = nil
        linkPtrTrace = nil

    # Program DMA: THD[0] -> head descriptor status.
    let dmaHead = hwDesc.txConfirmDescPtr.uint
    if traceMgmt or traceEapol:
      nimFwTrace2U32("[WIFI-NIMFW] txtrig_dma ",
                     cast[uint32](dmaHead),
                     cast[uint32](thdAddr))
      requireFrame()
      if traceMgmt:
        when defined(bl808WifiConnectTrace):
          nimFwConnectTrace2U32("[WIFI-CT] txtrig_dma ",
                                cast[uint32](dmaHead),
                                cast[uint32](thdAddr))
          requireFrame()
    hostTxHwDescAt(cast[pointer](dmaHead)).status = thdStatus.uint32

    # Check secondary TX hardware descriptor pointer at offset 8
    let secondaryTxHwDesc = cast[pointer](hwDesc.secondaryTxHwDescPtr.uint)
    if secondaryTxHwDesc == nil:
      # No secondary chain (.L133): clear AC bit in INTC status
      let intcStat = machwTxAggActive()
      requireFrame()
      acCtrl.current = nil
      machwTxAggActiveSet(intcStat and clearMask)
      requireFrame()
      # Fall through to .L134 path
    else:
      let secView = hostTxHwDescAt(secondaryTxHwDesc)
      let secStatus = cast[int32](secView.controlFlags)
      if secStatus >= 0:
        # Secondary TX hardware descriptor not ready to pop: vendor rearms the AC timeout only.
        # This is the ONLY silent exit past the head gate in this loop — the
        # HW-correlated TX-dead wedge spins here (txtrig_entry ~1.1k/s with zero
        # cfm while the head THD stays queued). Count it and snapshot BOTH
        # candidate done-words so the sub-cause is decidable from the diag dump
        # (sec_cfm bit31 set + sec_ctrl clear => wrong-word read; both clear =>
        # MACHW never completed the secondary).
        inc nimFwDbgTxTrigSecNotReady
        nimFwDbgTxTrigSecCtrl = secView.controlFlags
        nimFwDbgTxTrigSecCfm = secView.confirmStatus
        let ipcBase = regRead(IPC_SHARED_TX_BASE)
        requireFrame()
        blmac_abs_timer_set(ac, ipcBase + TX_TIMEOUT_LOCAL[ac])
        return
      # secStatus < 0: fall through to pop path (.L134)

    let hostCfm = desc.queueFirst
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
      requireFrame()
      nimFwTrace2U32("[WIFI-NIMFW] txtrig_cfm ",
                     cast[uint32](cast[uint](fenvPtrTrace)),
                     cfmHeadTrace)
      requireFrame()
      nimFwTrace2U32("[WIFI-NIMFW] txtrig_link ",
                     cast[uint32](cast[uint](desc.queueFirst)),
                     cast[uint32](cast[uint](desc.bufDesc)))
      requireFrame()
      when defined(bl808WifiConnectTrace):
        nimFwConnectTrace2U32("[WIFI-CT] txtrig_route ",
                              ac.uint32 or ((if traceRoutedHost: 1'u32 else: 0'u32) shl 8),
                              cast[uint32](descAddr))
        requireFrame()
        nimFwConnectTrace2U32("[WIFI-CT] txtrig_cfm ",
                              cast[uint32](cast[uint](fenvPtrTrace)),
                              cfmHeadTrace)
        requireFrame()
        nimFwConnectTrace2U32("[WIFI-CT] txtrig_link ",
                              cast[uint32](cast[uint](desc.queueFirst)),
                              cast[uint32](cast[uint](desc.bufDesc)))
        requireFrame()
    # Keep the frame visible to teardown until the diagnostic calls finish.
    discard co_list_pop_front(addr acCtrl.pending)
    # Publication ends frame ownership; AC/session teardown still cancels
    # the remaining timer/queue work in this invocation.
    owner.desc = nil
    if hostCfm == nil:
      # Internal management frame: frame-confirm event only.
      txl_frame_cfm(descPtr)
    else:
      # Host/data TX descriptor: route through the AC confirmation queue.
      txl_cfm_push(descPtr, thdStatus.uint32, ac.uint32)
    requireTrigger()

    # Set absolute timer for next TX opportunity and loop to check for more descriptors.
    let ipcBase = regRead(IPC_SHARED_TX_BASE)
    requireTrigger()
    blmac_abs_timer_set(ac, ipcBase + TX_TIMEOUT_LOCAL[ac])
    requireTrigger()

proc txl_current_desc_get*(ac: uint8, outDesc: ptr pointer) {.exportc, cdecl.} =
  ## Get the current TX descriptor for an AC.
  ## From blob (8 instrs): computes txl_cntrl_env + ac*16, reads pending list first
  ## element at offset 4. If non-null, reads txDesc at elem+112 and stores
  ## txDesc+4 to *a1; otherwise stores null to *a1.
  var currentDesc: pointer = nil
  let firstElem = cast[pointer](txControlAc(ac.uint32).pending.first)
  if firstElem != nil:
    let txDesc = hostTxDescAt(firstElem).hwDesc
    currentDesc = cast[pointer](addr hostTxHwDescAt(txDesc).magic)
  outDesc[] = currentDesc

proc txl_reset*(): bool {.exportc, cdecl, discardable.} =
  ## Reset TX layer (87 instrs).
  ## From blob: saves txl_cntrl_env seq counter (offset 84, half-word),
  ## clears pending TX events with ke_evt_clear(0x7C000), then loops waiting
  ## for IPC_EMB_STATUS2 (0x24A00010) bits[15:0] == 0xFFFF (all TX slots idle).
  ## Sets txl_cntrl_env[88] = 1 (reset-in-progress flag).
  ## Then loops ac=0..4: for each AC, writes (1<<ac) to MAC HW 0x24A00020
  ## (TX halt register), calls txl_cfm_flush(s4_base, cfm_list, 0x40000000)
  ## to flush with large timeout mask, then calls txl_cfm_flush again with
  ## per-AC cfm list. After loop: calls txl_hwdesc_reset, txl_buffer_reinit,
  ## txl_cfm_init, memsets txl_cntrl_env to 0 (92 bytes), restores seq counter,
  ## then re-initializes each TX control AC entry's pending list, current
  ## pointer, IPC descriptor halfword, and busy flag.
  let saved = irqSave()
  defer: irqRestore(saved)
  let txCtrl = txControlEnv()
  if txResetActive:
    ke_evt_set(0x80000000'u32)
    return false
  # Completion callbacks may request another reset while this one is draining.
  txResetActive = true
  defer:
    txResetActive = false
    if txCtrl.resetInProgress != 0:
      ke_evt_set(0x80000000'u32)
  txCtrl.resetInProgress = 1
  inc txResetEpoch
  txlInvalidateDmaAll()

  # Save sequence counter before reset
  let savedSeqNum = txCtrl.seqCounter

  # Clear TX-layer events before waiting for idle slots (blob: ke_evt_clear).
  ke_evt_clear(0x7C000'u32)

  # Wait for all TX slots to become idle
  # Blob: reads 0x24A00010 (IPC_EMB_STATUS2), waits for bits[15:0] == 0xFFFF
  const IPC_TX_STATUS_REG = 0x24A00010'u
  var pollsRemaining = WifiHwPollLimit
  while true:
    let status = volatileLoad(cast[ptr uint32](IPC_TX_STATUS_REG))
    if (status and 0xFFFF) == 0xFFFF:
      break
    if pollsRemaining == 0:
      noteHwWaitTimeout(IPC_TX_STATUS_REG.uint32, 0xFFFF'u32)
      hal_machw_disable_int()
      ke_evt_set(0x80000000'u32)
      return false
    dec pollsRemaining

  # Loop ac=0..4: halt AC, then two txl_cfm_flush calls (blob: 10 total flushes)
  #   flush 1: cfm list at txl_cfm_env + ac*8
  #   flush 2: cfm list at txl_cntrl_env+4 + ac*16
  for ac in 0'u32 ..< 5:
    let acBit = 1'u32 shl ac
    volatileStore(cast[ptr uint32](0x24A00020'u), acBit)

    let cfmList1 = txCfmList(ac)
    txl_cfm_flush(ac.uint8, cfmList1, 0x40000000'u32)

    let cfmList2 = addr txControlAc(ac).pending
    txl_cfm_flush(ac.uint8, cfmList2, 0x40000000'u32)

  if txRecoveryPostponed.first != nil:
    txlDrainRetiredPostponed(addr txRecoveryPostponed)
    co_list_init(addr txRecoveryPostponed)

  # A reset callback may be running inside an outer, detached AC/VIF flush.
  # Retire those packets before clearing the shared accounting below.
  var batch = txActiveFlush
  while batch != nil:
    if batch.confirmations.first != nil:
      txl_cfm_flush(batch.ac, addr batch.confirmations, 0x40000000'u32)
    if batch.pending.first != nil:
      txl_cfm_flush(batch.ac, addr batch.pending, 0x40000000'u32)
    txlDrainRetiredPostponed(addr batch.postponed)
    batch = batch.previous

  # Reset HW descriptors, reinit buffer pool, init confirm lists
  # (blob: txl_hwdesc_reset; txl_buffer_reinit; txl_cfm_init)
  txl_hwdesc_reset()
  txl_buffer_reinit()
  txl_cfm_init()

  # Memset txl_cntrl_env to zero (92 bytes)
  discard c_memset(txCtrl, 0, 92.csize_t)
  txCtrl.resetInProgress = 1

  # Restore saved sequence counter
  txCtrl.seqCounter = savedSeqNum

  # Re-initialize per-AC TX control entries.
  for ac in 0'u32 ..< 5:
    let acCtrl = txControlAc(ac)
    co_list_init(addr acCtrl.pending)
    acCtrl.current = nil
    acCtrl.packetCount = ipcTxHwDescWordHalfword(ac)
    acCtrl.busyFlag = 0
    txlAcPending[ac] = 0
    txlAcBusy[ac] = false
  txCtrl.resetInProgress = 0
  true

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

proc txlCaptureFrameIdentity(): TxFrameIdentity =
  let saved = irqSave()
  result.resetEpoch = txResetEpoch
  result.vifEpochs = rxVifEpochs
  for station in 0'u8 ..< STA_MGMT_FREE_STAS.uint8:
    result.stationEpochs[station] = staDeleteEpoch(station)
  irqRestore(saved)

proc txlFrameBeginLease(desc: ptr HostTxDescView; identity: TxFrameIdentity) =
  txSecurityForget(desc)
  let index = txl_frame_desc_index(cast[pointer](desc))
  if index == InvalidFrameDescIndex:
    return
  inc txFrameGeneration
  txFrameIdentities[index] = identity
  txFrameIdentities[index].generation = txFrameGeneration
  txFrameIdentities[index].leased = true

proc txlFrameEndLease(desc: ptr HostTxDescView) =
  txSecurityForget(desc)
  let index = txl_frame_desc_index(cast[pointer](desc))
  if index != InvalidFrameDescIndex:
    txFrameIdentities[index].leased = false

proc txlFrameBindSmOwner(desc: ptr HostTxDescView; connection: pointer;
                         serial: uint32; state: uint16): bool =
  let index = txl_frame_desc_index(desc)
  if index == InvalidFrameDescIndex or not txFrameIdentities[index].leased:
    return false
  txFrameIdentities[index].smConnection = connection
  txFrameIdentities[index].smSerial = serial
  txFrameIdentities[index].smState = state
  txFrameIdentities[index].smTracked = true
  true

proc txlFrameLeaseToken(desc: ptr HostTxDescView): uint32 =
  let index = txl_frame_desc_index(cast[pointer](desc))
  if index != InvalidFrameDescIndex:
    return txFrameIdentities[index].generation
  # The shared beacon descriptor is the only non-pool internal TX frame.
  mmBcnGeneration

proc txlFrameLeaseMatches(desc: ptr HostTxDescView; generation: uint32): bool =
  let index = txl_frame_desc_index(cast[pointer](desc))
  if index == InvalidFrameDescIndex:
    return mmBcnGeneration == generation
  txFrameIdentities[index].leased and
    txFrameIdentities[index].generation == generation

proc txlFrameIdentityCurrent(identity: TxFrameIdentity; vif, station: uint8): bool =
  if not identity.leased or identity.resetEpoch != txResetEpoch or vif >= MAX_VIFS.uint8 or
      identity.vifEpochs[vif] != rxVifEpochs[vif]:
    return false
  station >= STA_MGMT_FREE_STAS.uint8 or
    identity.stationEpochs[station] == staDeleteEpoch(station)

proc txlFrameSessionCurrent(desc: ptr HostTxDescView): bool =
  let index = txl_frame_desc_index(cast[pointer](desc))
  # Host data and the separately owned beacon descriptor have other owners.
  if index == InvalidFrameDescIndex:
    return true
  txlFrameIdentityCurrent(txFrameIdentities[index], desc.vifIdx, desc.staInfoIdx)

proc txlCaptureFrameCallback(desc: ptr HostTxDescView): TxFrameCallbackScope =
  let index = txl_frame_desc_index(cast[pointer](desc))
  if index != InvalidFrameDescIndex:
    result.identity = txFrameIdentities[index]
    result.vif = desc.vifIdx
    result.station = desc.staInfoIdx
    result.tracked = true
  elif desc.callback == cast[pointer](mm_bcn_transmitted):
    result.identity = txlCaptureFrameIdentity()
    result.identity.generation = mmBcnGeneration
    result.identity.leased = true
    result.vif = desc.vifIdx
    result.station = 0xFF
    result.tracked = true
    result.beacon = true

proc txlFrameCallbackCurrent(): bool =
  let scope = txActiveFrameCallback
  scope == nil or not scope.tracked or
    (txlFrameIdentityCurrent(scope.identity, scope.vif, scope.station) and
     (not scope.beacon or scope.identity.generation == mmBcnGeneration))

proc txlInvokeFrameCallback(callback, argument: pointer; status: uint32;
                           context: TxFrameCallbackScope) =
  var scope = context
  scope.previous = txActiveFrameCallback
  txActiveFrameCallback = addr scope
  defer: txActiveFrameCallback = scope.previous
  cast[proc(arg: pointer; status: uint32) {.cdecl, raises: [Exception].}](callback)(argument, status)

proc txl_tx_desc_pointer_plausible(txDescPointer: pointer): bool =
  if txDescPointer == nil:
    return false
  let txDescAddr = cast[uint32](cast[uint](txDescPointer))
  txDescAddr >= 0x2200_0000'u32 and txDescAddr < 0x2210_0000'u32

proc txl_frame_free_list_pop(freeList: ptr CoList): ptr CoListHdr =
  # Only the free list proves that a slot is available. Queue scans cannot
  # account for frames currently held by callers or completion callbacks.
  var node = freeList.first
  var last: ptr CoListHdr = nil
  var seen = 0'u32
  var invalidNode: pointer = nil
  while node != nil:
    let index = txl_frame_desc_index(cast[pointer](node))
    if index == InvalidFrameDescIndex or (seen and (1'u32 shl index)) != 0:
      invalidNode = cast[pointer](node)
      break
    seen = seen or (1'u32 shl index)
    last = node
    node = node.next
  if invalidNode != nil or freeList.last != last:
    inc nimFwDbgFrameGetInvalid
    nimFwDbgFrameGetInvalidPtr = pointerAddrU32(
      if invalidNode != nil: invalidNode else: cast[pointer](freeList.last))
    # Quarantine inconsistent links; never reconstruct availability by guessing.
    freeList.first = nil
    freeList.last = nil
    return nil
  co_list_pop_front(freeList)

proc txl_frame_free_list_push(param: pointer) =
  if not txl_frame_desc_valid(param):
    inc nimFwDbgFrameFreePushInvalid
    nimFwDbgFrameGetInvalidPtr = pointerAddrU32(param)
    return
  co_list_push_back(addr txFrameEnv().freeList, cast[ptr CoListHdr](param))

# TX Frame management
proc txlInvalidateDmaPool() =
  for owner in [txActiveDmaOwner, txActiveTriggerOwner]:
    if owner != nil and txl_frame_desc_valid(owner.desc):
      owner.cancelled = true

proc txl_frame_init*(preservePostponed: uint32) {.exportc, cdecl.} =
  ## Initialize TX frame pool (111 instrs in blob).
  ## Blob calls: co_list_init (x2), memset, co_list_push_back, phy_get_ntx (x2).
  ## Inits free/used lists, loops over the private descriptors pushing each onto
  ## free list, then inits ACK descriptor with PHY params and clears buffer
  ## control globals. Nonzero preservePostponed skips descriptors whose
  ## postpone byte at offset 217 is already set; txl_cntrl_init passes zero.
  txlInvalidateDmaPool()
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
    # Blob: only preserves byte 217 descriptors when a0 is nonzero.
    if preservePostponed != 0 and frameDesc.postponeFlag != 0:
      discard  # already initialized
    else:
      # memset entire 220-byte descriptor to zero
      txlFrameEndLease(frameDesc)
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
  if length == 0 or length > TxlFramePayloadSize:
    return nil
  let saved = irqSave()
  defer: irqRestore(saved)
  # Pool recovery may invoke callbacks that replace the caller's VIF or peer.
  let identity = txlCaptureFrameIdentity()
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
      if not txl_cntrl_clear_ac(3): return nil
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
    txlFrameBeginLease(desc, identity)
    let generation = txlFrameLeaseToken(desc)
    # A free slot starts a new transmission, not a retry of its prior owner.
    # In particular, an old postpone timestamp must not age out the new frame.
    desc.pendingMacTime = 0
    desc.postponeFlag = 0
    desc.retryFlag = 0
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
      if not txlFrameLeaseMatches(desc, generation):
        return nil
      nimFwTrace2U32("[WIFI-NIMFW] frame_hdr ", oldBufPtr, expectedHdrPtr)
      if not txlFrameLeaseMatches(desc, generation):
        return nil
      inc nimFwDbgFrameTraceCount
    hwDesc.payloadStart = expectedHdrPtr
    let curBufPtr = expectedHdrPtr  # hwDesc[20]
    hwDesc.frameLen = length + 4     # data length + FCS
    hwDesc.payloadEnd = curBufPtr + length - 1  # adjusted end

    # Copy 52-byte rate/control template from txl_buffer_control_24G into linkDesc+256
    let rateTemplate = hostTxRateTemplate(linkDesc)
    discard c_memcpy(cast[pointer](rateTemplate),
                     cast[pointer](addr txl_buffer_control_24G[0]), 52)

    # The power lookup takes the packed rate word at linkDesc+276.
    let rateVal = rateTemplate.rateWord
    let txPower = tpc_get_vif_tx_power_vs_rate(rateVal)
    if not txlFrameLeaseMatches(desc, generation):
      return nil
    rateTemplate.txPower = txPower.int32

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
  let saved = irqSave()
  defer: irqRestore(saved)
  let desc = hostTxDescAt(param)
  let identity = txlCaptureSession(desc)
  let generation = txlFrameLeaseToken(desc)
  if not txlFramePreparationCurrent(desc, identity, generation):
    return 0
  if ac >= NUM_TX_QUEUES.uint8:
    txl_frame_release(desc, false)
    return 0
  inc nimFwDbgTxPushCalls
  let hwDesc = hostTxHwDescAt(desc.hwDesc)
  var thdField = hwDesc.payloadStart
  if desc.bufDesc != nil:
    let linkDesc = hostTxLinkDescAt(desc.bufDesc)
    let expectedHdrPtr = cast[uint32](cast[uint](addr linkDesc.macHeader[0]))
    if thdField != expectedHdrPtr:
      nimFwTrace2U32("[WIFI-NIMFW] frame_push_fix ", thdField, expectedHdrPtr)
      if not txlFramePreparationCurrent(desc, identity, generation):
        return 0
      thdField = expectedHdrPtr
      hwDesc.payloadStart = expectedHdrPtr
  if (thdField and 1) != 0:
    assert_err("txl_frame.c", "txl_frame.c", 316)
    if txlFramePreparationCurrent(desc, identity, generation):
      txl_frame_release(desc, false)
    return 0
  # Mask bits [22:15] of control flags
  var ctrlFlags = hwDesc.controlFlags
  ctrlFlags = ctrlFlags and 0xFF87FFFF'u32
  let hdr = macDataFrameAt(cast[pointer](thdField.uint))
  hwDesc.secondaryTxHwDescPtr = 0
  hwDesc.secondaryDescToStatusPadding = 0
  hwDesc.controlFlags = ctrlFlags
  # Vendor normal-push path leaves control frames at no-ACK here; other
  # unicast frames get MAC ACK policy bit 9.
  let typeBits = cast[uint8](hdr.frameControl and 0x000C'u16)  # bits [3:2]
  if typeBits != 4 and (hdr.addr1[0] and 1) == 0:
    hwDesc.ackPolicyControl = 512  # 0x200
  else:
    hwDesc.ackPolicyControl = 0
  hwDesc.confirmStatus = 0
  return txl_cntrl_push_int(param, ac)  # blob: tail-call txl_cntrl_push_int (not txl_cntrl_push)

proc txl_frame_try_push_force(param: pointer, ac: uint8): uint8 =
  ## Force push a frame for transmission.
  ## From disassembly (41 instrs): similar to txl_frame_push but unconditionally
  ## sets ackPolicyControl from the destination address multicast bit,
  ## clears confirmStatus,
  ## then tail-calls txl_cntrl_push_int_force.
  let saved = irqSave()
  defer: irqRestore(saved)
  let desc = hostTxDescAt(param)
  let identity = txlCaptureSession(desc)
  let generation = txlFrameLeaseToken(desc)
  if not txlFramePreparationCurrent(desc, identity, generation):
    return 0
  if ac >= NUM_TX_QUEUES.uint8:
    txl_frame_release(desc, false)
    return 0
  let hwDesc = hostTxHwDescAt(desc.hwDesc)
  var thdField = hwDesc.payloadStart
  if desc.bufDesc != nil:
    let linkDesc = hostTxLinkDescAt(desc.bufDesc)
    let expectedHdrPtr = cast[uint32](cast[uint](addr linkDesc.macHeader[0]))
    if thdField != expectedHdrPtr:
      nimFwTrace2U32("[WIFI-NIMFW] frame_force_fix ", thdField, expectedHdrPtr)
      if not txlFramePreparationCurrent(desc, identity, generation):
        return 0
      thdField = expectedHdrPtr
      hwDesc.payloadStart = expectedHdrPtr
  if (thdField and 1) != 0:
    assert_err("txl_frame.c", "txl_frame.c", 367)
    if txlFramePreparationCurrent(desc, identity, generation):
      txl_frame_release(desc, false)
    return 0
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
  txl_cntrl_push_int_force(param, ac)

proc txl_frame_push_force*(param: pointer, ac: uint8) {.exportc, cdecl.} =
  discard txl_frame_try_push_force(param, ac)

proc txl_frame_cfm*(param: pointer) {.exportc, cdecl.} =
  ## Handle TX frame confirmation.
  ## Blob behavior: push the descriptor on txl_frame_env+8, then signal
  ## the TX frame confirm event (0x80000) for txl_frame_evt.
  let trace = block:
    let saved = irqSave()
    defer: irqRestore(saved)
    txlInvalidateDmaFrame(param)
    inc nimFwDbgFrameCfm
    let desc = hostTxDescAt(param)
    var mgmt, probe: bool
    var confirmStatus, hwStatus: uint32
    if desc.hwDesc != nil:
      let hwDesc = hostTxHwDescAt(desc.hwDesc)
      confirmStatus = hwDesc.confirmStatus
      hwStatus = hwDesc.status
      noteMgmtTxConfirm(desc, confirmStatus, 1'u32)
      if desc.bufDesc != nil:
        let fc = hostTxLinkDescAt(desc.bufDesc).macHeader[0]
        mgmt = nimFwMgmtFcTrace(fc)
        probe = fc == 0x40'u8
    let snapshot = (mgmt: mgmt, probe: probe,
      descriptor: pointerAddrU32(param), hardware: pointerAddrU32(desc.hwDesc),
      confirmStatus: confirmStatus, status: hwStatus)
    let frameEnv = txFrameEnv()
    co_list_push_back(addr frameEnv.usedList, cast[ptr CoListHdr](param))
    ke_evt_set(0x00080000'u32)
    snapshot
  if trace.mgmt:
    nimFwTrace2U32("[WIFI-NIMFW] frame_cfm ",
                   trace.descriptor, trace.hardware)
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] frame_cfm ",
                            trace.confirmStatus, trace.status)
  when defined(bl808WifiScanTrace):
    if trace.probe:
      nimFwTrace2U32("[WIFI-SCAN] probe_cfm ",
                     trace.confirmStatus, trace.status)

proc txl_frame_release*(param: pointer; doCallback: bool) {.exportc, cdecl.} =
  ## Release a TX frame descriptor. Blob (txl_frame_release, 70 bytes):
  ##   if (frame[216] == 0)                         ; internal alloc (valid==0)
  ##     co_list_push_back(&txl_frame_env, frame)   ; return to free list
  ##   if (a1 != 0 && frame[208] != 0)              ; optional callback
  ##     tail-call frame[208](frame[212], 0)
  ##   return
  let completion = block:
    let saved = irqSave()
    defer: irqRestore(saved)
    txlInvalidateDmaFrame(param)
    inc nimFwDbgFrameRelease
    let desc = hostTxDescAt(param)
    let callbackContext = txlCaptureFrameCallback(desc)
    let frameDoneCallbackPtr = if doCallback: desc.callback else: nil
    let frameDoneCallbackArg = desc.callbackArg
    if desc.usedFlag == 0:
      # Capture completion before publishing the reusable slot.
      txlFrameEndLease(desc)
      let frameEnv = txFrameEnv()
      co_list_push_back(addr frameEnv.freeList, cast[ptr CoListHdr](param))
    (callback: frameDoneCallbackPtr, argument: frameDoneCallbackArg,
     context: callbackContext)
  if completion.callback != nil:
    txlInvokeFrameCallback(completion.callback, completion.argument, 0,
                           completion.context)

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
  defer:
    let saved = irqSave()
    defer: irqRestore(saved)
    if txlFrameConfirmPending(frameEnv):
      ke_evt_set(0x00080000'u32)
  while txlFrameConfirmPending(frameEnv):
    # Keep the detached descriptor owned until its completion is captured.
    let saved = irqSave()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    defer:
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      irqRestore(saved)
    let node = co_list_pop_front(addr frameEnv.usedList)
    if node == nil:
      return
    inc nimFwDbgFrameEvtPop
    let desc = hostTxDescAt(node)
    txlInvalidateDmaFrame(desc)
    let generation = txlFrameLeaseToken(desc)
    if not txlFrameSessionCurrent(desc) and desc.hwDesc != nil:
      hostTxHwDescAt(desc.hwDesc).confirmStatus = 0x40000000'u32
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
    # Decrement pending frame counter at txl_cntrl_env[80] unconditionally.
    txCtrl.packetCounter = txCtrl.packetCounter - 1
    # Check for callback at desc[208]
    let callbackPtr = desc.callback
    try:
      if callbackPtr != nil:
        inc nimFwDbgFrameEvtCallback
        # Blob passes desc[112][64] directly as the callback status.
        let thdStatus = hostTxHwDescAt(desc.hwDesc).confirmStatus
        let frameCallbackArg = desc.callbackArg
        let callbackContext = txlCaptureFrameCallback(desc)
        {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
        irqRestore(saved)
        txlInvokeFrameCallback(callbackPtr, frameCallbackArg, thdStatus,
                               callbackContext)
    finally:
      discard irqSave()
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      # The callback may fail after retrying or replacing this pool slot.
      if callbackPtr == nil or txlFrameLeaseMatches(desc, generation):
        if callbackPtr != nil and desc.retryFlag != 0:
          desc.retryFlag = 0
        elif desc.usedFlag == 0:
          inc nimFwDbgFrameEvtFreeRet
          txlFrameEndLease(desc)
          co_list_push_back(addr frameEnv.freeList, cast[ptr CoListHdr](node))
        else:
          inc nimFwDbgFrameEvtUsedSkip

proc txl_frame_send_null_frame*(staIdx: uint8, cfmCallback: pointer, cfmArg: uint32): uint8 {.exportc, cdecl, discardable.} =
  ## Build and send a null data frame (for PS notification).
  ## Blob ABI is (staIdx, cfmCallback, cfmArg), not (vifIdx, staIdx, pwrMgt).
  ## The VIF index is read from sta_info_tab[staIdx]+39 and the callback/arg
  ## are stored verbatim at desc+208/212 for txl_frame_cfm.
  let saved = irqSave()
  defer: irqRestore(saved)
  if staIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return 1
  var nfRA {.noinit.}: uint32
  {.emit: [nfRA, " = (unsigned int)__builtin_return_address(0);"].}
  inc nimFwDbgNullFrameCalls
  nimFwDbgNullFrameCallerRA = nfRA
  let sta = staInfoForIdx(staIdx)
  let vifIdx = sta.instNbr
  if vifIdx >= MAX_VIFS.uint8:
    return 1
  let vif = vifChannelForIdx(vifIdx)
  let vifEntry = cast[pointer](vif)
  let staMacAddr = cast[pointer](addr sta.macAddr[0])
  let identity = TxSessionIdentity(captured: true, vif: vifIdx, station: staIdx,
    vifEpoch: rxVifEpochs[vifIdx], stationEpoch: staDeleteEpoch(staIdx),
    resetEpoch: txResetEpoch)
  # Allocate frame (24 bytes for null data header)
  # Blob passes a0=24 (frame size) and a1=staIdx (original param, used as length hint)
  let frame = txl_frame_get(24)
  if frame == nil:
    return 1
  let desc = hostTxDescAt(frame)
  let generation = txlFrameLeaseToken(desc)
  desc.staInfoIdx = staIdx
  desc.vifIdx = vifIdx
  if not txlFramePreparationCurrent(desc, identity, generation):
    return 1
  tpc_update_frame_tx_power(vifEntry, frame)
  if not txlFramePreparationCurrent(desc, identity, generation):
    return 1
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
  let generation = cast[uint](arg).uint32
  let current = generation != 0 and generation == nimFwKeepaliveGeneration
  if current:
    nimFwKeepaliveInFlight = 0
  inc nimFwDbgNullFrameCfm
  nimFwDbgNullFrameLastStatus = status
  nimFwDbgBleWifiTxCfmBcn = wlanCoexControl()
  nimFwDbgBleWifiTxCfmPti = wlanCoexPti()
  if (status and WifiTxFrameSuccessfulBit) != 0'u32:
    inc nimFwDbgNullFrameAckOk
  else:
    inc nimFwDbgNullFrameAckFail
  if current and nimFwBleWifiRoleWindowActive != 0'u32:
    wifi_nimfw_coex_force_ble_role()

proc wifi_nimfw_send_checked_null_frame(staIdx: uint8; generation: uint32): uint8 =
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
    staIdx, cast[pointer](wifi_nimfw_null_frame_cfm), generation)
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

proc wifi_nimfw_send_checked_qosnull_frame(staIdx: uint8; generation: uint32): uint8 =
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
    staIdx, 0'u16, cast[pointer](wifi_nimfw_null_frame_cfm), generation)
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
  let saved = irqSave()
  defer: irqRestore(saved)
  # Station lists are not the complete owner set during release or recovery.
  if txlResetting() or txActiveFlush != nil or txRecoveryPostponed.first != nil:
    return
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
  let saved = irqSave()
  defer: irqRestore(saved)
  inc nimFwDbgPostponedServiceCalls
  if txlResetting(): return 0
  let resetEpoch = txResetEpoch
  let maxFrames = if limit == 0'u32: 1'u32 else: limit
  var owners: array[MAX_VIFS, StaQueueIdentity]
  for staPostponedVifIndex in 0'u8 ..< MAX_VIFS.uint8:
    let vif = vifChannelForIdx(staPostponedVifIndex)
    if vif.vifType != VIF_TYPE_STA or vif.state == 0 or
        vif.staIdx >= STA_INFO_TAB_ENTRIES.uint8:
      continue
    let sta = staInfoForIdx(vif.staIdx)
    if sta.valid != 0 and sta.instNbr == staPostponedVifIndex:
      owners[staPostponedVifIndex] = staPostponedOwner(cast[pointer](sta))
  var sent = 0'u32
  for owner in owners:
    if owner.entry == nil: continue
    let vif = vifChannelForIdx(owner.vif)
    template current(): bool =
      not txlResetting() and txResetEpoch == resetEpoch and
        staPostponedOwnerCurrent(owner) and
        vif.vifType == VIF_TYPE_STA and vif.state != 0 and
        vif.staIdx == owner.station and staInfoAt(owner.entry).valid != 0
    if not current(): continue
    let txReady = txl_cntrl_tx_check(cast[pointer](vif))
    if not txReady or not current(): continue
    let postponedFramesSent =
      sta_mgmt_send_postponed_frame(cast[pointer](vif), owner.entry, maxFrames - sent)
    sent += postponedFramesSent
    nimFwDbgPostponedServiceSent += postponedFramesSent
    if sent >= maxFrames: break
  if sent == 0'u32 and txResetEpoch == resetEpoch and not txlResetting():
    wifi_nimfw_reconcile_postponed_count()
  sent

proc rfc_channel_ops*(channel: uint32) {.exportc, cdecl.}

proc wifi_nimfw_apply_sta_tx_channel(
    band: uint8,
    chanType: uint8,
    primaryFreq: uint16,
    centerFreq1: uint16,
    centerFreq2: uint16,
    txPower: uint8
  ) {.inline.} =
  ## Keep the ad-hoc STA retune path aligned with chan_pre_switch_channel:
  ## pending RX descriptors must be drained before the PHY moves, otherwise
  ## the auth response can be missed after a successful auth TX ACK.
  rxl_timer_int_handler()
  rxl_cntrl_evt()
  phySetChannel(band, chanType, primaryFreq, centerFreq1, centerFreq2, txPower)
  tpc_update_tx_power(txPower)
  regWrite(MACHW_BASE + 0x0DC'u, 0x1F0'u32)

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
    let connInfo = sm.connectInfo
    if connInfo != nil:
      let vifIdx = connectInfoView(connInfo).vifIdx
      let vif = vifChannelForIdx(vifIdx)
      sourceVif = vifIdx.uint32 or
        (vif.state.uint32 shl 8) or (vif.vifType.uint32 shl 16)
      if vif.channelFreqPair != 0'u32:
        if vif.chanCtxt != nil:
          let ctxt = cast[ptr ChanCtxtView](vif.chanCtxt)
          band = ctxt.channel.band
          chanType = ctxt.channel.chanType
          centerFreq2 = ctxt.channel.centerFreq2
          txPower = ctxt.channel.txPower
        primaryFreq = uint16(vif.channelFreqPair and 0xFFFF'u32)
        centerFreq1 = uint16((vif.channelFreqPair shr 16) and 0xFFFF'u32)
        if centerFreq1 == 0'u16:
          centerFreq1 = primaryFreq
        if txPower == 0'u8:
          txPower = selectedMgmtTxPower().uint8
        source = 5'u32
      elif vif.chanCtxt != nil:
        let ctxt = cast[ptr ChanCtxtView](vif.chanCtxt)
        band = ctxt.channel.band
        chanType = ctxt.channel.chanType
        primaryFreq = ctxt.channel.primFreq
        centerFreq1 = ctxt.channel.centerFreq1
        centerFreq2 = ctxt.channel.centerFreq2
        txPower = ctxt.channel.txPower
        source = 4'u32
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
          if vif.chanCtxt != nil:
            let ctxt = cast[ptr ChanCtxtView](vif.chanCtxt)
            band = ctxt.channel.band
            chanType = ctxt.channel.chanType
            centerFreq2 = ctxt.channel.centerFreq2
            txPower = ctxt.channel.txPower
          primaryFreq = uint16(vif.channelFreqPair and 0xFFFF'u32)
          centerFreq1 = uint16((vif.channelFreqPair shr 16) and 0xFFFF'u32)
          if centerFreq1 == 0'u16:
            centerFreq1 = primaryFreq
          if txPower == 0'u8:
            txPower = selectedMgmtTxPower().uint8
          source = 3'u32
          break
  nimFwDbgStaTxChannelSource = source
  nimFwDbgStaTxChannelReq0 = primaryFreq.uint32 or (centerFreq1.uint32 shl 16)
  nimFwDbgStaTxChannelReq1 = centerFreq2.uint32 or
    (band.uint32 shl 16) or (chanType.uint32 shl 24) or (txPower.uint32 shl 28)
  nimFwDbgStaTxChannelVif = sourceVif
  if primaryFreq != 0'u16 and centerFreq1 != 0'u16:
    let reclaimNeeded =
      nimFwBleWifiRoleWindowEnabled != 0'u32 and
      nim_ble_coex_wifi_rf_reclaim_needed() != 0'u32
    var channel = ChanCtxtDefView(
      band: band, chanType: chanType, primFreq: primaryFreq,
      centerFreq1: centerFreq1, centerFreq2: centerFreq2, txPower: txPower)
    # Other channel users update the PHY state between STA transmissions.
    let channelChanged = not phyChannelMatches(addr channel)
    if reclaimNeeded or channelChanged:
      inc nimFwDbgStaTxRfRestore
      if reclaimNeeded:
        wifi_hosal_rf_turn_on()
        inc nimFwDbgStaTxRfFullRestore
        wifiRfCoreInitMode(40000000'u32, wifiBleCoex)
        phy_init(nil)
      wifi_nimfw_apply_sta_tx_channel(band, chanType, primaryFreq,
                                       centerFreq1, centerFreq2, txPower)

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
    let generation = nimFwKeepaliveGeneration
    const KeepaliveStaleMacTicks = 250_000'u32
    let age = regRead(MACHW_TIMLO_REG) - nimFwKeepaliveStartedAt
    if age >= KeepaliveStaleMacTicks:
      inc nimFwDbgTxStalledInternalRecover
      nimFwDbgTxRecoverAc = 3
      nimFwDbgTxRecoverPending = txFrameEnv().postponedCount
      if not txl_cntrl_clear_ac(3): return 2'u8
      if nimFwKeepaliveGeneration != generation: return 2'u8
      nimFwKeepaliveInFlight = 0
      nimFwKeepaliveTargetCfm = nimFwDbgNullFrameCfm
      if nimFwBleWifiRoleWindowActive != 0'u32:
        wifi_nimfw_coex_force_ble_role()
      if nimFwKeepaliveGeneration != generation or nimFwKeepaliveInFlight != 0:
        return 2'u8
    else:
      if nimFwBleWifiRoleWindowEnabled != 0'u32:
        if wifi_nimfw_coex_force_wifi_role() == 0'u32:
          return 2'u8
      if nimFwKeepaliveGeneration != generation or nimFwKeepaliveInFlight == 0:
        return 2'u8
      discard wifi_nimfw_service_sta_postponed(1)
      if nimFwKeepaliveGeneration != generation or nimFwKeepaliveInFlight == 0:
        return 2'u8
      nimFwDbgBleWifiTxTrigStat = regRead(0x24B08078'u)
      nimFwDbgBleWifiTxTrigAgg = regRead(0x24B0808C'u)
      txl_transmit_trigger()
      inc nimFwDbgNullFrameBusyPsCheck
      return 2'u8

  if txFrameEnv().postponedCount != 0:
    let generation = nimFwKeepaliveGeneration
    discard wifi_nimfw_service_sta_postponed(1)
    if nimFwKeepaliveGeneration != generation or nimFwKeepaliveInFlight != 0:
      return 2'u8
    if txFrameEnv().postponedCount != 0:
      inc nimFwDbgNullFramePostponed
      return 2'u8

  for keepaliveStaVifIndex in 0'u8 ..< MAX_VIFS.uint8:
    let vif = vifChannelForIdx(keepaliveStaVifIndex)
    if vif.vifType == 0'u8 and vif.state != 0'u8:
      let staIdx = vif.staIdx
      if staIdx >= STA_INFO_TAB_ENTRIES.uint8: continue
      let sta = staInfoForIdx(staIdx)
      if sta.valid == 0 or sta.instNbr != keepaliveStaVifIndex: continue
      let owner = staPostponedOwner(cast[pointer](sta))
      let resetEpoch = txResetEpoch
      # Reserve the operation before admission or submission can call back.
      inc nimFwKeepaliveGeneration
      if nimFwKeepaliveGeneration == 0: inc nimFwKeepaliveGeneration
      let generation = nimFwKeepaliveGeneration
      let beforeCfm = nimFwDbgNullFrameCfm
      nimFwKeepaliveInFlight = 1
      nimFwKeepaliveStartedAt = regRead(MACHW_TIMLO_REG)
      nimFwKeepaliveTargetCfm = beforeCfm + 1
      template ensureKeepaliveOwner(status: uint8) =
        if nimFwKeepaliveGeneration != generation: return status
        if txlResetting() or txResetEpoch != resetEpoch or
            not staPostponedOwnerCurrent(owner) or sta.valid == 0 or
            vif.vifType != 0 or vif.state == 0 or vif.staIdx != staIdx:
          nimFwKeepaliveInFlight = 0
          if nimFwBleWifiRoleWindowActive != 0:
            wifi_nimfw_coex_force_ble_role()
          return status
      ensureKeepaliveOwner(2'u8)
      let txReady = txl_cntrl_tx_check(cast[pointer](vif))
      ensureKeepaliveOwner(2'u8)
      if not txReady:
        nimFwKeepaliveInFlight = 0
        inc nimFwDbgNullFrameBusyTxCheck
        return 2'u8
      if nimFwBleWifiRoleWindowEnabled != 0'u32:
        if wifi_nimfw_coex_force_wifi_role() == 0'u32:
          if nimFwKeepaliveGeneration == generation: nimFwKeepaliveInFlight = 0
          return 2'u8
      ensureKeepaliveOwner(2'u8)
      if nimFwStaTxChannelPrepareEnabled != 0'u32:
        wifi_nimfw_prepare_sta_tx_channel()
      ensureKeepaliveOwner(2'u8)
      let keepaliveStatus =
        if nimFwBleWifiRoleWindowEnabled != 0'u32 or
            nimFwKeepaliveQosNullEnabled != 0'u32:
          wifi_nimfw_send_checked_qosnull_frame(staIdx, generation)
        else:
          wifi_nimfw_send_checked_null_frame(staIdx, generation)
      if nimFwKeepaliveGeneration != generation: return keepaliveStatus
      if keepaliveStatus notin [0'u8, 2'u8]:
        nimFwKeepaliveInFlight = 0
        if nimFwBleWifiRoleWindowActive != 0'u32:
          wifi_nimfw_coex_force_ble_role()
        return keepaliveStatus
      if nimFwKeepaliveInFlight == 0: return keepaliveStatus
      inc nimFwDbgNullFrameQueued
      if keepaliveStatus == 2:
        if nimFwBleWifiRoleWindowActive != 0'u32:
          wifi_nimfw_coex_force_ble_role()
        return 2'u8
      discard wifi_nimfw_service_sta_postponed(1)
      ensureKeepaliveOwner(0'u8)
      if nimFwKeepaliveInFlight == 0: return 0'u8
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
  let saved = irqSave()
  defer: irqRestore(saved)
  if staIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return 1
  let sta = staInfoForIdx(staIdx)
  let vifIdx = sta.instNbr
  if vifIdx >= MAX_VIFS.uint8:
    return 1
  let vif = vifChannelForIdx(vifIdx)
  let vifEntry = cast[pointer](vif)
  let staMacAddr = cast[pointer](addr sta.macAddr[0])
  let vifMacAddr = cast[pointer](addr vif.macAddr[0])
  let identity = TxSessionIdentity(captured: true, vif: vifIdx, station: staIdx,
    vifEpoch: rxVifEpochs[vifIdx], stationEpoch: staDeleteEpoch(staIdx),
    resetEpoch: txResetEpoch)
  # Allocate frame (26 bytes for QoS null header)
  let frame = txl_frame_get(26)
  if frame == nil:
    return 1'u8
  let desc = hostTxDescAt(frame)
  let generation = txlFrameLeaseToken(desc)
  desc.staInfoIdx = staIdx
  desc.vifIdx = vifIdx
  if not txlFramePreparationCurrent(desc, identity, generation):
    return 1
  tpc_update_frame_tx_power(vifEntry, frame)
  if not txlFramePreparationCurrent(desc, identity, generation):
    return 1
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
  return publicRc

proc txl_frame_send_selfcts_frame*(vifInfo: pointer, duration: uint16,
    cfmCallback: pointer, cfmArg: uint32): uint8 {.exportc, cdecl,
    discardable.} =
  ## Build and send a self-CTS frame (for NAV protection).
  ## From disassembly (66 instrs): Allocates a 10-byte frame via txl_frame_get(10, ...),
  ## builds a CTS frame header, copies VIF MAC address, stores confirmation
  ## callback/context at desc+208/212, modifies HW descriptor control fields,
  ## and pushes via txl_frame_push(desc, 3).
  ##
  ## Assembly trace:
  ##   s2=vifInfo, s1=duration, s4=cfmCallback, s3=cfmArg
  ##   call txl_frame_get(10, ...)  # 10-byte CTS frame
  ##   if nil: return 1
  ##   s0 = frame desc
  ##   call tpc_update_frame_tx_power(vifInfo, desc)
  ##   linkDesc = desc[108]
  ##   linkDesc[350] = duration (low byte)
  ##   linkDesc[351] = duration >> 8 (high byte)
  ##   linkDesc[348] = 0xC4 (-60 signed = CTS frame control)
  ##   linkDesc[349] = 0 (flags)
  ##   memcpy(linkDesc+352, vifInfo+80, 6) -- RA = own MAC addr
  ##   desc[208] = cfmCallback
  ##   desc[212] = cfmArg
  ##   hwDesc = desc[112]
  ##   hwDesc[60] |= 0x30000063 (control flags: self-CTS protection bits)
  ##   thd = hwDesc[40]; thd[16] &= 0xFFFF0000 (clear low 16 bits of rate)
  ##   desc[47] = vifInfo byte[87] (phy mode)
  ##   desc[49] = 0xFF (broadcast STA index)
  ##   call txl_frame_push(desc, 3)
  ##   return (result ^ 1) & 0xFF
  let saved = irqSave()
  defer: irqRestore(saved)
  if vifInfo == nil:
    return 1
  let vif = vifChannelAt(vifInfo)
  let vifIdx = vif.vifIdx
  if vifIdx >= MAX_VIFS.uint8 or vifChannelForIdx(vifIdx) != vif:
    return 1
  let identity = TxSessionIdentity(captured: true, vif: vifIdx, station: 0xFF'u8,
    vifEpoch: rxVifEpochs[vifIdx], resetEpoch: txResetEpoch)
  # Allocate CTS frame (10 bytes: FC(2) + duration(2) + RA(6))
  # Blob passes a0=10 (frame size) and a1=duration (original param, used as length hint)
  let frame = txl_frame_get(10)
  if frame == nil:
    return 1'u8
  let desc = hostTxDescAt(frame)
  let generation = txlFrameLeaseToken(desc)
  desc.vifIdx = vifIdx
  desc.staInfoIdx = 0xFF'u8
  if not txlFramePreparationCurrent(desc, identity, generation):
    return 1
  # Apply TX power control before filling the descriptor, matching the blob.
  tpc_update_frame_tx_power(vifInfo, frame)
  if not txlFramePreparationCurrent(desc, identity, generation):
    return 1
  # The blob calls a setup function at offset 0x28 with (vifInfo, frame_desc) to
  # associate the frame with VIF context. We handle this inline below.
  let hdr = hostTxCtsHeader(desc)
  # Build CTS frame header at linkDesc+348.
  hdr.frameControl = 0x00C4'u16
  hdr.duration = duration
  # RA = own MAC address from vifInfo+80
  let vifMacAddr = cast[pointer](addr vif.macAddr[0])
  discard c_memcpy(addr hdr.receiverAddr[0], vifMacAddr, 6.csize_t)
  desc.callback = cfmCallback
  desc.callbackArg = cast[pointer](cfmArg.uint)
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
  # Push frame for transmission on AC 3
  let pushRc = txl_frame_push(frame, 3)
  return (pushRc xor 1'u8) and 0xFF'u8

proc txlFrameDumpNodes(list: ptr CoList;
                       nodes: var array[TxlFrameDescCount.int, pointer]): int =
  var node = list.first
  while node != nil and result < nodes.len:
    if txl_frame_desc_index(cast[pointer](node)) == InvalidFrameDescIndex:
      break
    var repeated = false
    for index in 0 ..< result:
      if nodes[index] == cast[pointer](node):
        repeated = true
        break
    if repeated:
      break
    nodes[result] = cast[pointer](node)
    inc result
    node = node.next

proc txl_frame_dump*() {.exportc, cdecl, noinline.} =
  ## Snapshot the four-descriptor pool before invoking diagnostic callbacks.
  type
    LogFn = proc(level: uint32; tag, file: cstring; line: cint; format: cstring)
      {.cdecl, varargs.}
    PrintFn = proc(format: cstring) {.cdecl, varargs.}
  let log = cast[LogFn](blOpsFunc(204))
  if log == nil:
    return
  let print = cast[PrintFn](blOpsFunc(4))
  var freeNodes, usedNodes: array[TxlFrameDescCount.int, pointer]
  let saved = irqSave()
  let frameEnv = txFrameEnv()
  let freeCount = txlFrameDumpNodes(addr frameEnv.freeList, freeNodes)
  let usedCount = txlFrameDumpNodes(addr frameEnv.usedList, usedNodes)
  let descStorageBase = cast[uint](addr txl_frame_desc_storage[0])
  irqRestore(saved)

  log(2, nil, "txl_frame.c", 1101, "---------- txl_frame_dump ----------\r\n")
  log(2, nil, "txl_frame.c", 1103, "txl_frame_desc:\r\n")
  log(2, nil, "txl_frame.c", 1104, "  total: %d\r\n", TxlFrameDescCount.cint)
  log(2, nil, "txl_frame.c", 1105, "  list:")
  if print != nil:
    for frameDescSlotIndex in 0 ..< TxlFrameDescCount.int:
      let descAddr = descStorageBase + frameDescSlotIndex.uint * TxlFrameDescSize
      print(" %p", cast[pointer](descAddr))
  log(2, nil, "txl_frame.c", 1109, "\r\n")
  log(2, nil, "txl_frame.c", 1111, "txl_frame_env:\r\n")
  log(2, nil, "txl_frame.c", 1113, "  desc_free cnt: %d\r\n", freeCount.cint)
  log(2, nil, "txl_frame.c", 1114, "     list:")
  if print != nil:
    for freeNodeIndex in 0 ..< freeCount:
      print(" %p", freeNodes[freeNodeIndex])
  log(2, nil, "txl_frame.c", 1122, "\r\n")
  log(2, nil, "txl_frame.c", 1123, "  desc_done cnt: %d\r\n", usedCount.cint)
  log(2, nil, "txl_frame.c", 1124, "     list:")
  for usedNodeIndex in 0 ..< usedCount:
    log(2, nil, "txl_frame.c", 1128, " %p", usedNodes[usedNodeIndex])
  log(2, nil, "txl_frame.c", 1132, "\r\n")
  log(2, nil, "txl_frame.c", 1133, "========== txl_frame_dump End ======\r\n")
