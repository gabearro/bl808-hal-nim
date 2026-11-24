# ###########################################################################
#                   RX Upper (rxu_*)
# ###########################################################################

const RxuMgmtPnTid = 8'u8

proc rxMgtKeyIndex(key: pointer): int =
  if key == nil: return -1
  for index in 0 ..< STA_INFO_TAB_ENTRIES:
    if key == cast[pointer](addr staInfoForIdx(index.uint8).keyArea[0]):
      return index
  for vifIndex in 0 ..< MAX_VIFS:
    for slot in 0'u .. 5'u:
      if key == cast[pointer](vifKeySlot(vifChannelForIdx(vifIndex.uint8), slot)):
        return STA_INFO_TAB_ENTRIES + vifIndex * 6 + slot.int
  -1

proc rxKeyChange(key: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  let index = rxMgtKeyIndex(key)
  if index < 0: return
  # Completed descriptors retain the old revision before key publication.
  if rxlCntrlEnvView().submittedHead != nil:
    rxl_timer_int_handler()
  if rxKeyRevision == high(uint64):
    rxKeyRevision = 1
    for identity in rxStationIdentities.mitems:
      identity.keyRevision = 0
    for changed in rxKeyLastChanged.mitems:
      changed = 1
  else:
    inc rxKeyRevision
  rxKeyLastChanged[index] = rxKeyRevision

proc rxKeyCurrent(desc, key: pointer): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  let descriptor = rxMpduDescIndex(desc)
  let keyIndex = rxMgtKeyIndex(key)
  if descriptor < 0 or keyIndex < 0 or not rxStationCurrent(desc) or
      cast[ptr VifKeySlotView](key).installed == 0:
    return false
  let captured = rxStationIdentities[descriptor].keyRevision
  captured != 0 and rxKeyLastChanged[keyIndex] <= captured

proc rxMgtReplayReset(key: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  let index = rxMgtKeyIndex(key)
  if index < 0: return
  rxKeyChange(key)
  rxMgtReplayStates[index] = cast[ptr VifKeySlotView](key).replayCounters[0]
  rxMgtReplayValid[index] = true

proc rxMgtReplayForget(key: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  let index = rxMgtKeyIndex(key)
  if index < 0: return
  rxKeyChange(key)
  rxMgtReplayValid[index] = false
  rxMgtReplayStates[index] = default(KeyReplayCounterView)

proc rxMgtReplayCounter(key: pointer): ptr KeyReplayCounterView =
  let index = rxMgtKeyIndex(key)
  if index >= 0 and rxMgtReplayValid[index] and
      cast[ptr VifKeySlotView](key).installed != 0:
    return addr rxMgtReplayStates[index]

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
  ## Include HT control only in management or QoS data headers.
  rxMacHeaderLen(frameCtrl)

proc rxuQosSeqCachePtr(sta: ptr StaInfoView; tid: uint8): ptr uint16 {.inline.} =
  # Vendor address: sta_info_tab + staIdx * 368 + 338 + tid * 2.
  addr staRxSequence(sta).qosSeqCtrl[tid.int]

proc rxuProtectedKey(env: ptr RxuCntrlEnvView, keyIdx: uint8,
                     flagged: bool): ptr VifKeySlotView {.inline.} =
  ## Reference rxu_cntrl.o resolves unflagged protected data to the STA key
  ## context at sta+0x50. The flagged path uses the VIF key table at vif+0x208.
  if flagged:
    let vif = vifChannelForIdx(env.vifIdx)
    return vifRxProtectedKeySlot(vif, keyIdx.uint)
  let sta = staInfoForIdx(env.staIdx)
  cast[ptr VifKeySlotView](addr sta.keyArea[0])

proc rxuTraceProtectedSlot(key: ptr VifKeySlotView; keyIdx: uint8;
                           flagged: bool) {.inline.} =
  if key == nil:
    nimFwDbgRxuProtSlotMeta = keyIdx.uint32 or
      (if flagged: 0x00000100'u32 else: 0'u32)
    nimFwDbgRxuProtSlotKey0 = 0
    nimFwDbgRxuProtSlotKey1 = 0
    nimFwDbgRxuProtSlotKey2 = 0
    nimFwDbgRxuProtSlotKey3 = 0
    return
  nimFwDbgRxuProtSlotMeta =
    keyIdx.uint32 or
    (if flagged: 0x00000100'u32 else: 0'u32) or
    (key.cipherType.uint32 shl 16) or
    (key.staIdx.uint32 shl 20) or
    (key.keyIdx.uint32 shl 24)
  nimFwDbgRxuProtSlotKey0 = cast[ptr uint32](addr key.keyMaterial[0])[]
  nimFwDbgRxuProtSlotKey1 = cast[ptr uint32](addr key.keyMaterial[4])[]
  nimFwDbgRxuProtSlotKey2 = cast[ptr uint32](addr key.keyMaterial[8])[]
  nimFwDbgRxuProtSlotKey3 = cast[ptr uint32](addr key.keyMaterial[12])[]

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
  nimFwDbgRxuProtType =
    frameType or ((hwRxhdrFlags and 0x1C'u32) shl 8) or (hwRxhdrFlags and 0x400'u32)
  case frameType
  of 24:  # TKIP (8 byte header)
    let hdr = rxSecurityHeaderAt[TkipSecurityHeaderView](rxuCtx, hdrOffset)
    env.machdrLen = hdrOffset + 8
    let keyIdx = (hdr.keyId shr 6) and 0x03
    # TKIP header order is TSC1, WEP seed, TSC0, key id, TSC2..TSC5.
    # The replay PN is TSC0,TSC1,TSC2,TSC3,TSC4,TSC5.
    env.secInfo0 = hdr.tsc0.uint32 or (hdr.tsc1.uint32 shl 8) or
      (hdr.tsc2.uint32 shl 16) or (hdr.tsc3.uint32 shl 24)
    env.secInfo1 = hdr.tsc4.uint32 or (hdr.tsc5.uint32 shl 8)
    env.secFlags = env.secFlags or 0x03'u8
    env.secKeyPtr = cast[pointer](rxuProtectedKey(env, keyIdx, flaggedKeyTable))
    rxuTraceProtectedSlot(cast[ptr VifKeySlotView](env.secKeyPtr), keyIdx,
                          flaggedKeyTable)
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
    rxuTraceProtectedSlot(cast[ptr VifKeySlotView](env.secKeyPtr), keyIdx,
                          flaggedKeyTable)
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
  ## Keep strict/windowed data checks, with CCMP PNs starting at one.
  ## Management uses its own counter, not TX PN or the data-TID-zero counter.
  if secKeyPtr == nil or tid > RxuMgmtPnTid:
    return 0
  let key = cast[ptr VifKeySlotView](secKeyPtr)
  let counter = if tid == RxuMgmtPnTid: rxMgtReplayCounter(secKeyPtr)
                else: addr key.replayCounters[tid.int]
  if counter == nil:
    return 0
  let hasRxPn = key.hasRxPn

  # Read incoming PN from descriptor (loaded earlier in call chain)
  let env = rxuCntrlEnvView()
  let pnLo = env.secInfo0
  let pnHi = env.secInfo1
  if key.cipherType == 2 and pnLo == 0 and pnHi == 0:
    return 0

  if hasRxPn == 0:
    # Strict replay check: compare/update the next expected PN per TID.
    let nextLo = pnLo + 1
    let nextHi = pnHi + (if nextLo < pnLo: 1'u32 else: 0'u32)
    let replayCounter = counter
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
    let replayCounterEntry = counter
    nimFwDbgRxuPnMeta = tid.uint32 or (hasRxPn.uint32 shl 8) or
      (env.secFlags.uint32 shl 16)
    nimFwDbgRxuPnStoredLo = replayCounterEntry.pnLow
    nimFwDbgRxuPnStoredHi = replayCounterEntry.pnHigh
    nimFwDbgRxuPnNextLo = pnLo
    nimFwDbgRxuPnNextHi = pnHi
    let receivedPn = (pnHi.uint64 shl 32) or pnLo.uint64
    return replay_counter_validate(replayCounterEntry, receivedPn).cint

proc rxuPnFresh(secKeyPtr: pointer; tid: uint8): bool =
  ## Preview data replay admission without committing an unauthenticated MIC.
  if secKeyPtr == nil or tid >= 8:
    return false
  let key = cast[ptr VifKeySlotView](secKeyPtr)
  let env = rxuCntrlEnvView()
  let received = (env.secInfo1.uint64 shl 32) or env.secInfo0.uint64
  if key.cipherType == 2 and received == 0:
    return false
  var candidate = key.replayCounters[tid.int]
  if key.hasRxPn != 0:
    return replay_counter_validate(addr candidate, received)
  let next = received + 1'u64
  let stored = (candidate.pnHigh.uint64 shl 32) or candidate.pnLow.uint64
  next > stored

proc rxuStripPayloadPrefix(swdesc: ptr RxSwDescView; stripLen: uint32;
                           headerLen: uint8) {.inline.} =
  if swdesc == nil or stripLen == 0:
    return
  let payloadDesc = cast[ptr RxPayloadHwDescView](swdesc.bufferChain)
  if payloadDesc == nil:
    return
  let frameStart = cast[pointer](payloadDesc.bufferStart)
  let uploadStart = cast[pointer](payloadDesc.bufferStart + stripLen)
  # Vendor moves the header backward in place without rebasing the DMA buffer.
  discard c_memmove(uploadStart, frameStart, headerLen.csize_t)

proc rxu_cntrl_desc_prepare*(swdesc: pointer) {.exportc, cdecl, noinline.} =
  ## Set descriptor status=3, push to rxu_cntrl_env upload list under IRQ lock.
  ## Blob (rxu_cntrl_desc_prepare.constprop.0.isra.0, 22 instrs):
  ##   swdesc[20] = 3
  ##   saved = csrrci(mstatus, 0x08)          ; disable MIE, return old mstatus
  ##   co_list_push_back(&rxu_cntrl_env+0x40, swdesc)
  ##   if (saved & 8) csrsi(mstatus, 0x08)    ; restore MIE
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
  let saved = irqSave()
  defer: irqRestore(saved)
  if rxMpduHeader(swdesc) == nil or not rxStationCurrent(swdesc) or
      rxMpduDescView(swdesc).curDesc == nil:
    return
  inc nimFwDbgRxuDescPrepare
  # Mark ready and publish under the same interrupt lock.
  rxMpduDescView(swdesc).descFlag = 3'u8
  co_list_push_back(addr rxuCntrlEnvView().uploadList, cast[ptr CoListHdr](swdesc))

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
  let generation = rxUploadGeneration(param)
  let swdesc = rxMpduHeader(param)
  if swdesc == nil or not rxStationCurrent(param): return

  # Read payload descriptor chain to get frame control. The blob loads
  # swdesc[8] and then reads the frame at payloadDesc[24].
  let payloadDesc = cast[ptr RxPayloadHwDescView](swdesc.bufferChain)
  if payloadDesc == nil or payloadDesc.bufferStart == 0 or
      swdesc.mpduLengthBytes < 2:
    return
  let fc = cast[ptr MacDataFrameHeaderView](
    cast[pointer](payloadDesc.bufferStart)).frameControl

  # Compute header size from FC via rxu_cntrl_machdr_len_get (blob 0x5a)
  let macHdrLen = rxu_cntrl_machdr_len_get(fc)
  let envHdrLen = env.machdrLen
  if macHdrLen == 0 or envHdrLen < macHdrLen or
      envHdrLen.uint16 > swdesc.mpduLengthBytes:
    return
  let adjustment = envHdrLen.int - macHdrLen.int
  if (adjustment and 1) != 0:
    assert_warn(cast[cstring](0), cast[cstring](0), 364)
    return

  # Admit the complete header before publishing an upload-in-progress flag.
  let flagsHi = env.staIdx.uint32 shl 16
  let flagsMid = env.vifIdx.uint32 shl 8
  swdesc.frameControlFlags = swdesc.frameControlFlags or flagsHi or flagsMid or 2'u32
  env.stripLen = 0

  if adjustment != 0:
    # Adjust the upload buffer and software length to hide the stripped header
    # bytes from the host-side DMA upload.
    rxuStripPayloadPrefix(swdesc, adjustment.uint32, macHdrLen)
    if swdesc.mpduLengthBytes >= adjustment.uint16:
      swdesc.mpduLengthBytes = swdesc.mpduLengthBytes - adjustment.uint16
    else:
      swdesc.mpduLengthBytes = 0
    env.stripLen = adjustment.uint8
    env.machdrLen = macHdrLen

  # Clear DMA complete flag
  swdesc.bufferOffset = 0

  # Initiate DMA transfer
  if not rxTransferFrame(param): return

  # Critical section: prepare descriptor under interrupt lock
  let saved = irqSave()
  defer: irqRestore(saved)
  if rxUploadCurrent(param, generation) and rxStationCurrent(param) and
      rxMpduHeader(param) == swdesc:
    rxu_cntrl_desc_prepare(param)

proc rxuCopyFrameBytes(swdesc: ptr RxSwDescView; offset, length: uint32;
                       destination: pointer): bool =
  ## Copy a bounded slice from the already-admitted RX DMA chain.
  if destination == nil or offset > swdesc.mpduLengthBytes.uint32 or
      length > swdesc.mpduLengthBytes.uint32 - offset:
    return false
  var node = rxFrameBufferChainAt(swdesc.bufferChain)
  var skip = offset
  var remaining = length
  var written = 0'u32
  while remaining != 0:
    if node == nil or node.frameData == nil:
      return false
    if skip >= 1736'u32:
      skip -= 1736'u32
    else:
      let count = min(remaining, 1736'u32 - skip)
      discard c_memcpy(rxFrameCursor(destination, written.uint),
        rxFrameCursor(node.frameData, skip.uint), count.csize_t)
      written += count
      remaining -= count
      skip = 0
    if remaining != 0:
      node = rxFrameBufferChainAt(node.next)
  true

proc rxuPortAllows(sta: ptr StaInfoView; protocol: uint16; hasProtocol: bool;
                    destination, localAddress: ptr array[6, uint8]): bool =
  let configuredProtocol = hasProtocol and
    sta.rateWord == lmacGateHalfword(protocol)
  if sta.controlPortState != 2 and
      (sta.controlPortState != 1 or not configuredProtocol):
    return false
  if hasProtocol and (configuredProtocol or protocol == 0x8E88'u16):
    const PaeGroup = [1'u8, 0x80, 0xC2, 0, 0, 3]
    return destination[] == localAddress[] or destination[] == PaeGroup
  true

proc rxuAmsduValid(swdesc: ptr RxSwDescView; frame: ptr MacDataFrameHeaderView;
                   env: ptr RxuCntrlEnvView; vifType: uint8;
                   sta: ptr StaInfoView; localAddress: ptr array[6, uint8]): bool =
  ## Validate the whole aggregate before discarding the outer address context.
  const SnapDestination = [0xAA'u8, 0xAA, 3, 0, 0, 0]
  if (frame.addr1[0] and 1) != 0:
    return false
  if (env.frameCtrl and 0x4000) != 0 and (env.hwRxhdr and 0x1C) != 28:
    return false
  let ds = env.frameCtrl and 0x0300
  let checkDa = ds != 0x0300 and (vifType != 2 or ds == 0)
  let checkSa = ds != 0x0300 and (vifType != 0 or ds == 0)
  let total = swdesc.mpduLengthBytes.uint32
  var offset = env.machdrLen.uint32
  while offset < total:
    var header: RxAmsduSubframeHeaderView
    if not rxuCopyFrameBytes(swdesc, offset, sizeof(header).uint32, addr header):
      return false
    let length = (header.payloadLengthBe[0].uint32 shl 8) or
      header.payloadLengthBe[1].uint32
    if length == 0 or length > 2304 or length > total - offset - sizeof(header).uint32:
      return false
    if header.da == SnapDestination or (header.sa[0] and 1) != 0:
      return false
    if checkDa and (header.da[0] and 1) == 0 and header.da != env.da:
      return false
    if checkSa and header.sa != env.sa:
      return false
    var snap: LlcSnapHeaderView
    let hasProtocol = length >= sizeof(snap).uint32 and
      rxuCopyFrameBytes(swdesc, offset + sizeof(header).uint32,
                       sizeof(snap).uint32, addr snap) and
      (rxSnapIsRfc1042(addr snap) or rxSnapIsBridgeTunnel(addr snap))
    if not rxuPortAllows(sta, snap.ethertype, hasProtocol, addr header.da, localAddress):
      return false
    offset += sizeof(header).uint32 + length
    if offset == total:
      return true
    let padding = (4'u32 - ((sizeof(header).uint32 + length) and 3)) and 3
    if total - offset < padding + sizeof(header).uint32:
      return false
    offset += padding
  false

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
  if param == nil:
    return 0
  let generation = rxUploadGeneration(param)
  if not rxStationCurrent(param):
    return 0
  let swdesc = rxMpduHeader(param)
  if swdesc == nil:
    return 0
  template frameCurrent(): bool =
    rxUploadCurrent(param, generation) and rxStationCurrent(param) and
      rxMpduHeader(param) == swdesc
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
    if swdesc.bufferChain == nil or swdesc.mpduLengthBytes < 2:
      inc nimFwDbgRxuDropInvalid
      doReturn()
    let payload = rxFramePayload(swdesc)
    if payload == nil:
      inc nimFwDbgRxuDropInvalid
      doReturn()
    let frame = macDataFrameAt(payload)
    let frameControl = frame.frameControl
    # Management/control frames never carry DS addresses. Validate direct
    # callers too, before a malformed header can select the Addr4 path.
    if (frameControl and 3) != 0 or
        ((frameControl and 8) == 0 and (frameControl and 0x0300) != 0):
      inc nimFwDbgRxuDropInvalid
      doReturn()
    if (frameControl and 0x00FC'u16) == 0x00B0'u16:
      inc nimFwDbgRxuAuthSeen
      nimFwDbgRxuAuthLast0 = hwFlags
      nimFwDbgRxuAuthLast1 =
        frameControl.uint32 or (swdesc.mpduLengthBytes.uint32 shl 16)
    nimFwTrace2U32("[WIFI-NIMFW] rxu_fc ", hwFlags, frameControl.uint32)
    if not rxUploadCurrent(param, generation) or not rxStationCurrent(param) or
        rxMpduHeader(param) != swdesc: doReturn()

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

    # Destination is unknown unless this frame resolves an AP unicast peer.
    env.staIdx = 0xFF
    env.vifIdx = 0xFF
    env.dstIdx = 0xFF

    # Store frame control at env[0]
    env.frameCtrl = frameControl

    let machdrLen = rxu_cntrl_machdr_len_get(frameControl)
    if machdrLen == 0 or swdesc.mpduLengthBytes < machdrLen.uint16:
      inc nimFwDbgRxuDropInvalid
      doReturn()
    env.machdrLen = machdrLen

    if (frameControl and 0x000C) == 4:
      if (hwFlags and 0x02000000'u32) != 0:
        inc nimFwDbgRxuDropFtype
        doReturn()
      # Control frames have no sequence field or third address.
      env.seqCtrl = 0
      env.seqNum = 0
      env.fragNum = 0
      env.tid = 0
      rxCopyAddr(addr env.da, addr frame.addr1)
      env.sa = default(typeof(env.sa))
      if machdrLen >= 16: rxCopyAddr(addr env.sa, addr frame.addr2)
      if not rxStationCurrent(param): doReturn()
      rxu_mpdu_upload_and_indicate(param)
      if rxUploadCurrent(param, generation) and rxStationCurrent(param) and
          rxMpduHeader(param) == swdesc and rxMpduDescView(param).curDesc != nil:
        returnValue = 1
      doReturn()

    # Store sequence control from the MAC header at env[2]
    let seqCtrl = frame.seqCtrl
    env.seqCtrl = seqCtrl

    # Clear duplicate-detect flag
    rxu_cntrl_duplicate_flag = 0

    # Decompose seqCtrl -> seqNum at env[4], fragNum at env[6]
    env.seqNum = seqCtrl shr 4
    env.fragNum = (seqCtrl and 0xF).uint8

    let securityHeaderLen =
      if (frameControl and 0x4000) != 0:
        case hwFlags and 0x1C'u32
        of 20: 4'u16
        of 24, 28: 8'u16
        else: 0'u16
      else:
        0'u16
    if (frameControl and 0x4000) != 0:
      if swdesc.mpduLengthBytes < machdrLen.uint16 + securityHeaderLen:
        inc nimFwDbgRxuDropInvalid
        doReturn()
    if (frameControl and 0x000C'u16) == 0 and not rxMgmtBodyValid(
        frameControl, payload, machdrLen.uint16 + securityHeaderLen,
        swdesc.mpduLengthBytes):
      inc nimFwDbgRxuDropInvalid
      doReturn()
    # Unlike the blob's three-bit mask, keep the wire TID for raw uploads.
    # The associated EDCA path only has state for the eight user priorities.
    let associated = (hwFlags and 0x02000000'u32) != 0
    env.tid = if (frameControl and 0x008C'u16) == 0x0088'u16:
                (rxQosControl(frame, machdrLen) and 0x0F).uint8
              else: 0'u8
    if associated and env.tid >= 8:
      inc nimFwDbgRxuDropInvalid
      doReturn()
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
        if not frameCurrent(): doReturn()
        nimFwConnectTrace2U32("[WIFI-CT] rx_len ",
                              rxTraceLen.uint32 or (rxTraceEth shl 16),
                              rxTraceState.uint32)
        if not frameCurrent(): doReturn()
        if rxTraceState >= SmAuthStartingState or rxTraceType == 8:
          nimFwConnectTraceBytes("[WIFI-RAW] rx_any ",
                                 cast[pointer](frame),
                                 rxTraceLen.uint32,
                                 96)
          if not frameCurrent(): doReturn()

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
    if associated:
      # .L148: Associated STA / monitor mode path
      let hwStaIdx = (hwFlags shr 15) and 0x3FF'u32
      if hwStaIdx < 8 or hwStaIdx >= 8 + STA_INFO_TAB_ENTRIES.uint32:
        inc nimFwDbgRxuDropStaInactive
        doReturn()
      let staIdx = (hwStaIdx - 8).uint8
      let sta = staInfoForIdx(staIdx)

      # Check STA active at sta_entry[42]
      if sta.valid == 0:
        inc nimFwDbgRxuDropStaInactive
        when defined(bl808WifiConnectTrace):
          nimFwConnectTrace2U32("[WIFI-CT] rx_drop ", 1, staIdx.uint32)
        doReturn()

      let vifIdx = sta.instNbr
      if vifIdx.int >= MAX_VIFS:
        inc nimFwDbgRxuDropStaInactive
        doReturn()
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
        if (frameControl and 0x000C'u16) == 0:
          let protection = env.hwRxhdr and 0x1C'u32
          if protection == 20:
            # Shared-key Authentication is the only WEP management format.
            if (frameControl and 0xFC'u16) != 0xB0'u16: doReturn()
          elif protection == 28:
            # This non-mesh implementation uses pairwise CCMP for robust
            # unicast management, never a data GTK or a non-robust category.
            let bodyOffset = machdrLen.uint16 + 8'u16
            if (sta.capabilityFlags and 8) == 0 or (env.da[0] and 1) != 0 or
                (env.hwRxhdr and 0x400'u32) != 0 or
                swdesc.mpduLengthBytes <= bodyOffset:
              doReturn()
            if not mfp_is_robust_frame(frameControl.uint32,
                rxFrameBytes(frame)[bodyOffset.int].uint32):
              doReturn()
          else:
            doReturn()
        # TKIP and CCMP both require ExtIV in bit 5 of security-header byte 3.
        if ((env.hwRxhdr and 0x1C'u32) == 24 or
            (env.hwRxhdr and 0x1C'u32) == 28) and
            (rxFrameBytes(frame)[machdrLen.int + 3] and 0x20) == 0:
          doReturn()
        if rxu_cntrl_protected_handle(
             cast[ptr uint8](frame), env.hwRxhdr) == 0:
          doReturn()
        if (env.secFlags and 2) != 0 and not rxKeyCurrent(param, env.secKeyPtr):
          doReturn()
        if not frameCurrent(): doReturn()

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
            if not frameCurrent(): doReturn()
          mm_cfg_element_keepalive_timestamp_update()
          doReturn()

        # No reassembly exists here. This gate must precede EAPOL dispatch
        # and replay/sequence updates, including for the first fragment.
        if (env.frameCtrl and 0x0400) != 0 or env.fragNum != 0:
          doReturn()
        let micLength = if (env.secFlags and 1) != 0: 8'u32 else: 0'u32
        if swdesc.mpduLengthBytes.uint32 < env.machdrLen.uint32 + micLength:
          doReturn()
        let msduLength = swdesc.mpduLengthBytes.uint32 -
          env.machdrLen.uint32 - micLength
        # The vendor recognizes A-MSDU only on QoS Data subtype 0x88.
        let isAmsdu = (frameControl and 0x00FC) == 0x0088 and
          (rxQosControl(frame, machdrLen) and 0x80) != 0
        if isAmsdu and not rxuAmsduValid(swdesc, frame, env, vif.vifType,
                                        sta, addr vif.macAddr):
          doReturn()

        # Sequence/reorder context
        var seqCachePtr: ptr uint16
        if (frameControl and 0x0080) != 0:
          seqCachePtr = rxuQosSeqCachePtr(sta, env.tid)
        else:
          seqCachePtr = addr staRxSequence(sta).nonQosSeqCtrl

        # Duplicate sequence check
        let envSeq = env.seqCtrl
        if (frameControl and 0x0800'u16) != 0:
          if seqCachePtr[] == envSeq:
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
        # .L171: EAPOL detection requires RFC1042 SNAP then EtherType 0x888E.
        let msdu = rxMsduView(frame, env.machdrLen)
        let hasSnapHeader = msduLength >= sizeof(LlcSnapHeaderView).uint32
        nimFwDbgRxuSnapLo = if hasSnapHeader: rxSnapTraceLo(addr msdu.snap) else: 0
        nimFwDbgRxuSnapHi = if hasSnapHeader: rxSnapTraceHi(addr msdu.snap) else: 0
        let hasRfc1042Snap = not isAmsdu and hasSnapHeader and
          rxSnapIsRfc1042(addr msdu.snap)
        let etherType = if hasSnapHeader: msdu.snap.ethertype else: 0'u16
        if hasRfc1042Snap:
          inc nimFwDbgRxuAssocSnap
          case etherType
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
                                etherType.uint32 or
                                  ((if hasRfc1042Snap: 1'u32 else: 0'u32) shl 16) or
                                  (env.tid.uint32 shl 24),
                                swdesc.mpduLengthBytes.uint32 or
                                  (env.machdrLen.uint32 shl 16))
          if not frameCurrent(): doReturn()
        let isEapol = hasRfc1042Snap and etherType == 0x8E88'u16
        let hasProtocol = not isAmsdu and hasSnapHeader and
          (hasRfc1042Snap or rxSnapIsBridgeTunnel(addr msdu.snap))
        var waitingForPeer = false
        if not isAmsdu and not rxuPortAllows(sta, etherType, hasProtocol,
                                            addr env.da, addr vif.macAddr):
          waitingForPeer = isEapol and sta.controlPortState == 0 and vif.vifType == 0 and
            fromDs and not toDs and (frameControl and 0x4000) == 0 and env.secFlags == 0 and
            (frame.addr1[0] and 1) == 0 and env.da == vif.macAddr and frame.addr2 == sta.macAddr
          if not waitingForPeer: doReturn()
        let isConfiguredControlPort = hasProtocol and
          sta.rateWord == lmacGateHalfword(etherType)
        var eapolLength = 0'u32
        if isEapol:
          let available = msduLength - sizeof(LlcSnapHeaderView).uint32
          if available < sizeof(RxEapolHeaderView).uint32:
            doReturn()
          let header = cast[ptr RxEapolHeaderView](rxMsduPayload(msdu))
          eapolLength = sizeof(RxEapolHeaderView).uint32 +
            (header.bodyLengthBe[0].uint32 shl 8) + header.bodyLengthBe[1].uint32
          if eapolLength > available:
            doReturn()
          if eapolLength > high(uint16).uint32:
            doReturn()
          if not waitingForPeer and vif.vifType == 0 and
              not smActivationEapolReady(env.vifIdx, staIdx): doReturn()

        # EAPOL and the configured control protocol use the uncontrolled port.
        # Other plaintext data is forbidden on a secured BSS.
        if not isEapol and not isConfiguredControlPort and (frameControl and 0x4000) == 0 and
            vifSecurity(vif).cipher != 0:
          doReturn()

        # .LBB312/.LBB313: MIC verification (Michael MIC for TKIP)
        # Blob builds local DMA descriptor chain from buffer chain, calls me_mic_init/
        # me_mic_calc/me_mic_end, then compares computed MIC with received MIC.
        # On mismatch sends MIC_FAILURE_IND to the host API task (9).
        if (env.secFlags and 1) != 0:
          if not rxKeyCurrent(param, env.secKeyPtr) or not frameCurrent():
            doReturn()
          if not rxuPnFresh(env.secKeyPtr, env.tid):
            inc nimFwDbgRxuDropPn
            doReturn()
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
                      addr env.da[0],
                      addr env.sa[0],
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
          if micOff < 0:
            doReturn()
          var micBuf = rxFrameBufferChainAt(swdesc.bufferChain)
          var rxMic: array[2, uint32]
          let rxMicBytes = cast[ptr UncheckedArray[uint8]](addr rxMic[0])
          var micBytesRead = 0
          while micBytesRead < 8:
            if micBuf == nil:
              assert_rec("rxu_cntrl.c", "rxu_cntrl.c", 852)
              doReturn()
            if micOff >= MAX_DMA_SEG:
              micOff -= MAX_DMA_SEG
            else:
              # The vendor copies bytes here: a MIC can span two DMA buffers.
              let segmentBytes = cast[ptr UncheckedArray[uint8]](micBuf.frameData)
              let bytesToCopy = min(8 - micBytesRead, MAX_DMA_SEG - micOff)
              for micByteIndex in 0 ..< bytesToCopy:
                rxMicBytes[micBytesRead + micByteIndex] = segmentBytes[micOff + micByteIndex]
              micBytesRead += bytesToCopy
              micOff = 0
            if micBytesRead < 8:
              micBuf = rxFrameBufferChainAt(micBuf.next)

          # 4. Compare computed MIC with received MIC
          if not rxKeyCurrent(param, env.secKeyPtr) or not frameCurrent():
            doReturn()
          if rxMic[0] != micCtx[0] or rxMic[1] != micCtx[1]:
            if not frameCurrent(): doReturn()
            if nimFwDbgRxuDhcpMsg(frame, env.machdrLen,
                                  swdesc.mpduLengthBytes) != 0:
              nimFwDbgRecordRxuPnAccept(0xE3'u32, frame, hwFlags, envSeq,
                                        env.tid, env.machdrLen,
                                        swdesc.mpduLengthBytes)
            # Allocation can run recovery; retain only this frame's metadata.
            let failureBssid = staInfoForIdx(env.staIdx).macAddr
            let failurePnLow = env.secInfo0
            let failurePnHigh = env.secInfo1
            let failureIsGroup = ((env.hwRxhdr shr 10) and 1).uint8
            let failureKeyId = secKey.staIdx
            let failureVifIdx = env.vifIdx
            let failMsg = ke_msg_alloc(0xC04'u16, TASK_API, TASK_ME, 24)
            if failMsg != nil:
              if not rxKeyCurrent(param, secKey) or not frameCurrent():
                ke_msg_free_payload(failMsg)
                doReturn()
              let msg = rxMicFailureIndAt(failMsg)
              msg.bssid = failureBssid
              msg.pnLow = failurePnLow
              msg.pnHigh = failurePnHigh
              msg.isGroup = failureIsGroup
              msg.keyId = failureKeyId
              msg.vifIdx = failureVifIdx
              ke_msg_send(failMsg)
            doReturn()

          swdesc.mpduLengthBytes -= 8'u16

        # Commit replay/duplicate state only after the complete MSDU passes
        # integrity checks. Hardware has already authenticated CCMP frames.
        block:
          let savedIrq = irqSave()
          defer: irqRestore(savedIrq)
          if not frameCurrent():
            doReturn()
          if (env.secFlags and 2) != 0:
            if not rxKeyCurrent(param, env.secKeyPtr): doReturn()
            if rxu_cntrl_check_pn(env.secKeyPtr, env.tid) == 0:
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
            if not rxKeyCurrent(param, env.secKeyPtr): doReturn()
          if waitingForPeer and not smActivationRetainM1(env.vifIdx, staIdx, env.sa,
              rxMsduPayload(msdu), eapolLength): doReturn()
          seqCachePtr[] = envSeq
          if waitingForPeer: doReturn()

        if isEapol:
          if not frameCurrent(): doReturn()
          inc nimFwDbgRxuAssocEapol
          let vifType = vif.vifType
          if vifType notin [0'u8, 2'u8]:
            doReturn()
          let offset = env.machdrLen.uint32 + sizeof(LlcSnapHeaderView).uint32
          let sourceAddr = env.sa
          let receivedKey = if (env.secFlags and 2) != 0: env.secKeyPtr else: nil
          var eapolData = rxMsduPayload(msdu)
          var storage: pointer = nil
          var freeFn: proc(p: pointer) {.cdecl.}
          defer:
            if storage != nil:
              freeFn(storage)
          if eapolLength > 1736'u32 - offset:
            let allocFn = cast[proc(size: uint32): pointer {.cdecl.}](blOpsFunc(184))
            freeFn = cast[proc(p: pointer) {.cdecl.}](blOpsFunc(188))
            if allocFn == nil or freeFn == nil:
              doReturn()
            storage = allocFn(eapolLength)
            if storage == nil or
                (receivedKey != nil and not rxKeyCurrent(param, receivedKey)) or
                not frameCurrent() or
                not rxuCopyFrameBytes(swdesc, offset, eapolLength, storage):
              doReturn()
            eapolData = storage
          when defined(bl808WifiConnectTrace):
            nimFwConnectTrace2U32("[WIFI-CT] eapol_rx ",
              staIdx.uint32 or (vifType.uint32 shl 8), eapolLength)
          if vifType == 0 and not smActivationEapolReady(env.vifIdx, staIdx): doReturn()
          if (receivedKey != nil and not rxKeyCurrent(param, receivedKey)) or
              not frameCurrent():
            doReturn()
          if vifType == 2:
            apm_handle_eapol_input(staIdx, eapolData, eapolLength)
          else:
            sm_handle_eapol_input(staIdx, unsafeAddr sourceAddr[0], eapolData,
                                  eapolLength.uint16)
          doReturn()

        # .L174: Build status word for host upload
        let currentFrameControlFlags = swdesc.frameControlFlags
        let combined = (env.staIdx.uint32 shl 16) or
                       (env.vifIdx.uint32 shl 8) or
                       (env.dstIdx.uint32 shl 24) or
                       currentFrameControlFlags
        swdesc.frameControlFlags = combined

        # .LBB349: Reparse FC for QoS TID/AMSDU bits
        let finalFrame = macDataFrameAt(rxFramePayload(swdesc))
        let fcFinal = finalFrame.frameControl
        swdesc.frameControlFlags = swdesc.frameControlFlags and 0xFFFFFF8F'u32

        if (fcFinal and 0x00FC) == 0x0088:
          let qos = rxQosControl(finalFrame, rxu_cntrl_machdr_len_get(fcFinal))
          let tidBits = (qos and 7).uint32 shl 4
          let amsdu = if (qos and 0x80) != 0: 1'u32 else: 0'u32
          swdesc.frameControlFlags = swdesc.frameControlFlags or tidBits or amsdu

        # .L185: LLC/SNAP header check for proper strip length computation.
        # Blob uses two memcmp calls against 6-byte RFC1042 + bridge-tunnel
        # headers at .LANCHOR0 and .LANCHOR1.
        let uploadMacHdrLen = env.machdrLen
        var stripLen = uploadMacHdrLen and 0xFE
        # Vendor +0x7fa goes straight to upload: an A-MSDU already contains
        # its own per-subframe addresses and lengths. Strip only the MAC/IV.
        if (swdesc.frameControlFlags and 1) == 0:
          let msduSnap = rxMsdu(finalFrame, stripLen)
          let isRfc1042 = hasSnapHeader and rxSnapIsRfc1042(msduSnap)
          let preserveLlc = isRfc1042 and
            msduSnap.ethertype in [0x3781'u16, 0xF380'u16] # IPX/AARP, on wire
          let isBridgeTunnel = hasSnapHeader and rxSnapIsBridgeTunnel(msduSnap)

          if (isRfc1042 and not preserveLlc) or isBridgeTunnel:
            stripLen = (stripLen.int - 6).uint8
          else:
            # Retain native LLC payload and prepend an IEEE 802.3 header.
            stripLen = (stripLen.int - 14).uint8
            let lenVal = swdesc.mpduLengthBytes - (uploadMacHdrLen and 0xFE).uint16
            let frameBytes = rxFrameBytes(finalFrame)
            frameBytes[(uploadMacHdrLen and 0xFE).int - 2] = (lenVal shr 8).uint8
            frameBytes[(uploadMacHdrLen and 0xFE).int - 1] = (lenVal and 0xFF).uint8
            env.meshFlag = 1

          let ethHdr = rxEthernetRewriteHeader(finalFrame, stripLen)
          rxCopyAddr(addr ethHdr.da, addr env.da)
          rxCopyAddr(addr ethHdr.sa, addr env.sa)
          if (isRfc1042 and not preserveLlc) or isBridgeTunnel:
            ethHdr.ethertype = msduSnap.ethertype

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
        if not rxTransferFrame(param): doReturn()
        let savedIrq = irqSave()
        if rxUploadCurrent(param, generation) and rxStationCurrent(param) and
            rxMpduHeader(param) == swdesc:
          rxu_cntrl_desc_prepare(param)
          returnValue = 1
        irqRestore(savedIrq)
        break rcfhScope

      else:
        inc nimFwDbgRxuAssocMgmt
        # frameTypeBits == 0: Management in associated path
        let envSeq = env.seqCtrl
        let rxSeq = staRxSequence(sta)
        if (frameControl and 0x0800'u16) != 0:
          let cachedSeq = rxSeq.nonQosSeqCtrl
          if cachedSeq == envSeq: doReturn()

        # A recycled slot can have a valid new station, but not this generation.
        block:
          let savedIrq = irqSave()
          defer: irqRestore(savedIrq)
          if not frameCurrent(): doReturn()
          if (env.secFlags and 2) != 0:
            if not rxKeyCurrent(param, env.secKeyPtr): doReturn()
            if rxu_cntrl_check_pn(env.secKeyPtr, RxuMgmtPnTid) == 0:
              inc nimFwDbgRxuDropPn
              nimFwDbgRecordRxuPnDrop(frame, hwFlags, envSeq, env.tid,
                                      env.machdrLen, swdesc.mpduLengthBytes)
              doReturn()
            if not rxKeyCurrent(param, env.secKeyPtr): doReturn()
          if not frameCurrent(): doReturn()

        # Blob's associated mgmt path (.L158 -> .L163 -> .L234) routes through
        # rxu_mgt_frame_check(param, sta_idx), not the data upload path.
        when defined(bl808WifiDiagPeerRxAdmission):
          if (frameControl and 0xFC'u16) in [0xA0'u16, 0xC0'u16] and
              (frameControl and 0x4000) != 0 and (hwFlags and 0x1C) == 28 and
              (env.secFlags and 2) != 0:
            rxMgtNoteProtection(param, generation, rxMgtVerifiedCcmp)
        returnValue = rxu_mgt_frame_check(param, env.staIdx)
        if returnValue != 0:
          let savedIrq = irqSave()
          if frameCurrent():
            rxSeq.nonQosSeqCtrl = envSeq
          irqRestore(savedIrq)
        nimFwTrace2U32("[WIFI-NIMFW] rxu_mgt_assoc ", frameControl.uint32, returnValue)
        doReturn()

    # ================================================================
    # Non-associated path: dispatch by frame type bits [3:2]
    # ================================================================
    let frameTypeBits = frameControl and 0x000C

    if frameTypeBits == 0:
      # ---- Management frame (type 0) ----
      if (frameControl and 0x4000'u16) != 0 and
          ((hwFlags and 0x1C'u32) != 20 or
            (frameControl and 0xFC'u16) != 0xB0'u16):
        doReturn()
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
        if rxu_cntrl_protected_handle(cast[ptr uint8](frame), hwFlags) == 0:
          doReturn()

      # Management frame filter check (blob: rxu_mgt_frame_check at reloc 0x324)
      let mgtAccepted = rxu_mgt_frame_check(param, 0xFF'u8)
      nimFwTrace2U32("[WIFI-NIMFW] rxu_mgt ", frameControl.uint32, mgtAccepted)
      returnValue = mgtAccepted
      doReturn()

    elif frameTypeBits == 8:
      inc nimFwDbgRxuNonassocData
      # Data addressed to the local AP takes the management response path.
      let firstVif = vif_mgmt_get_first_ap_inf()
      if firstVif != nil:
        let apVif = vifChannelAt(firstVif)
        if c_memcmp(rxAddrPtr(addr frame.addr1), addr apVif.macAddr[0], 6) == 0:
          # DA matches our BSSID: forward to AP MLME
          apm_send_mlme(firstVif, 192, rxAddrPtr(addr frame.addr2), nil, nil, cast[pointer](1))
          doReturn()
      # The vendor's shared fallback uploads the original 802.11 MPDU.
      if not rxStationCurrent(param): doReturn()
      rxu_mpdu_upload_and_indicate(param)
      if rxUploadCurrent(param, generation) and rxStationCurrent(param) and
          rxMpduHeader(param) == swdesc and rxMpduDescView(param).curDesc != nil:
        returnValue = 1
      doReturn()

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
  let env = rxuCntrlEnvView()
  var recoveryRequested = false
  defer:
    let saved = irqSave()
    defer: irqRestore(saved)
    if not recoveryRequested and env.uploadList.first != nil:
      ke_evt_set(0x00800000'u32)
  ke_evt_clear(0x00800000'u32)
  inc nimFwDbgRxuUploadEvt
  let lowerEnv = rxlCntrlEnvView()
  const MAX_DMA_ENTRIES = 4
  const MAX_DMA_SIZE = 1736'u32
  while true:
    let saved = irqSave()
    let uploadListNode = co_list_pop_front(addr env.uploadList)
    if uploadListNode == nil:
      irqRestore(saved)
      break
    let uploadGeneration = rxUploadGeneration(uploadListNode)
    defer: irqRestore(saved)
    template outside(body: untyped) =
      irqRestore(saved)
      try: body
      finally: discard irqSave()
    inc nimFwDbgRxuUploadEntry
    let desc = cast[ptr RxMpduDescView](uploadListNode)
    # Validate the complete chain before marking any payload as host-owned.
    # Structural damage is a reset condition; recycling it could splice an
    # unrelated buffer into the hardware DMA ring.
    let swDesc = rxMpduHeader(uploadListNode)
    if swDesc == nil or swDesc.uploadDone != 0:
      recoveryRequested = true
      outside: assert_rec("rxu_cntrl.c", "rxu_cntrl.c", 2023)
      return
    let chainHead = swDesc.bufferChain
    let frameLength = swDesc.mpduLengthBytes
    let frameOffset = swDesc.bufferOffset
    var expectedDescCount = desc.descCount
    template current(): bool =
      rxUploadCurrent(uploadListNode, uploadGeneration) and
        rxMpduHeader(uploadListNode) == swDesc and swDesc.bufferChain == chainHead and
        swDesc.mpduLengthBytes == frameLength and swDesc.bufferOffset == frameOffset and
        desc.descCount == expectedDescCount
    var previousPayload, lastPayload: pointer
    let chainCount = rxPayloadChainBounds(
      swDesc.bufferChain, previousPayload, lastPayload)
    if chainCount == 0:
      recoveryRequested = true
      outside: assert_rec("rxu_cntrl.c", "rxu_cntrl.c", 2023)
      return
    var checkedPayload = cast[ptr RxPayloadHwDescView](swDesc.bufferChain)
    for _ in 0 ..< chainCount.int:
      if checkedPayload.usedFlag != 0 or
          not rxPayloadBufferValid(cast[pointer](checkedPayload)):
        recoveryRequested = true
        outside: assert_rec("rxu_cntrl.c", "rxu_cntrl.c", 2023)
        return
      checkedPayload = cast[ptr RxPayloadHwDescView](checkedPayload.next)

    # Validate ownership even when the upload pool is full: a duplicate queued
    # descriptor must not release payloads still owned by the host.
    if not rxStationCurrent(uploadListNode):
      outside: rxReleaseUpload(uploadListNode, uploadGeneration)
      continue
    let uploadCount = lowerEnv.uploadCount
    let uploadHeadroom = cast[int32](41'u32 - uploadCount)
    if uploadCount > 41 or uploadHeadroom <= 2:
      let logFn = getLogFunc(204)
      if logFn != nil:
        outside:
          cast[proc(level: uint32; tag, file: cstring; line: cint;
                    format: cstring) {.cdecl, varargs.}](logFn)(
            2, nil, "rxu_cntrl.c", 2002,
            "---->>> Drop before too late %d:%ld\r\n", 41.cint,
            cast[int32](uploadCount).clong)
      if current():
        outside: rxReleaseUpload(uploadListNode, uploadGeneration)
      continue

    # A short chain or a frame beyond the four-entry host ABI must never be
    # delivered as a truncated packet. The offset is inside the first buffer.
    if swDesc.mpduLengthBytes == 0 or swDesc.bufferOffset >= MAX_DMA_SIZE:
      outside: rxReleaseUpload(uploadListNode, uploadGeneration)
      continue
    var remaining = swDesc.mpduLengthBytes.uint32 + swDesc.bufferOffset
    let requiredSegments = (remaining + MAX_DMA_SIZE - 1) div MAX_DMA_SIZE
    if requiredSegments > MAX_DMA_ENTRIES.uint32 or
        requiredSegments > chainCount.uint32 or
        desc.descCount.uint32 > 255'u32 - requiredSegments:
      outside: rxReleaseUpload(uploadListNode, uploadGeneration)
      continue
    # Clear local DMA descriptor array (40 bytes on stack, matching blob layout).
    # Blob: buffer addresses at 0,4,8,12; payload pbuf-holder addresses at
    # 16,20,24,28; lengths (uint16) at 32,34,36,38.
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
      inc expectedDescCount
      # Store buffer address from hw_desc[8] (offsets 0,4,8,12 in dmaArray)
      dmaArray.bufferAddrs[dmaIdx] = uploadPayloadHwDesc.bufferAddr
      # Blob stores hw_desc+28 for the host's custom pbuf storage. The legacy
      # overlay field is named frameLen, but this is not a payload length.
      dmaArray.frameLenFieldAddrs[dmaIdx] =
        cast[uint32](cast[uint](addr uploadPayloadHwDesc.frameLen))
      # Compute transfer length (capped at MAX_DMA_SIZE)
      var xferLen = remaining
      if xferLen > MAX_DMA_SIZE:
        xferLen = MAX_DMA_SIZE
      # Store length as uint16 at offset 32 + dmaIdx*2 in dmaArray
      dmaArray.lengths[dmaIdx] = xferLen.uint16
      # Validation and ownership publication share the interrupt lock.
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
    let monitorCopy = (swDesc.frameControlFlags and 2) != 0
    var uploadResult: cint
    var uploadReturned = false
    try:
      outside:
        uploadResult = rxHostForward(
          uploadListNode,
          uploadGeneration,
          descFlag,
          swPayload,
          swBufOff,
          cast[pointer](addr dmaArray),
          swFcFlag,
        )
      uploadReturned = true
    finally:
      # Copied packets do not retain DMA storage, even if host delivery fails.
      # Legacy zero-copy callbacks have a separate ownership contract.
      if not uploadReturned:
        when defined(bl808WifiRxPbufInput):
          if current():
            outside: rxReleaseUpload(uploadListNode, uploadGeneration)
        else:
          if monitorCopy and current():
            outside: rxReleaseUpload(uploadListNode, uploadGeneration)
    if not current():
      continue
    if uploadResult != 0:
      inc nimFwDbgRxuUploadTcpipFail
      # Upload failed -- free descriptor and try next
      outside: rxReleaseUpload(uploadListNode, uploadGeneration)
      continue
    inc nimFwDbgRxuUploadTcpipOk
    when defined(bl808WifiRxPbufInput):
      # tcpip_stack_input copies RX bytes into PBUF_RAM before calling lwIP.
      # The copied pbuf owns the network packet; recycle the LMAC descriptor
      # immediately so uploadCount does not starve the RX path.
      outside: rxReleaseUpload(uploadListNode, uploadGeneration)
    else:
      if monitorCopy:
        outside: rxReleaseUpload(uploadListNode, uploadGeneration)
      else:
        # Legacy non-copy host delivery retains the descriptor.
        let deliveredCount = desc.descCount.uint32
        let enterFn = cast[proc(): uint32 {.cdecl.}](blOpsFunc(20))
        let leaveFn = cast[proc(level: uint32) {.cdecl.}](blOpsFunc(24))
        if enterFn == nil or leaveFn == nil:
          outside: assert_rec("rxu_cntrl.c", "RX upload callbacks", 0)
          return
        let savedStatus = enterFn()
        try:
          if current():
            lowerEnv.uploadCount = lowerEnv.uploadCount + deliveredCount
        finally:
          leaveFn(savedStatus)
