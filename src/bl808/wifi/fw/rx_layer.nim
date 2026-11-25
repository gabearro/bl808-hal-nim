# ###########################################################################
#                   RX LAYER (rxl_*)
# ###########################################################################

when defined(bl808WifiDirectCsiProbe):
  const DirectCsiProbeSlots = 64
  var nimFwDirectCsiRxCount* {.wifiCtrl, exportc: "nimfw_direct_csi_rx_count".}: uint32
  var nimFwDirectCsiDataCount* {.wifiCtrl, exportc: "nimfw_direct_csi_data_count".}: uint32
  var nimFwDirectCsiFc* {.wifiCtrl, exportc: "nimfw_direct_csi_fc".}:
    array[DirectCsiProbeSlots, uint32]
  var nimFwDirectCsiCtl* {.wifiCtrl, exportc: "nimfw_direct_csi_ctl".}:
    array[DirectCsiProbeSlots, uint32]
  var nimFwDirectCsiStat* {.wifiCtrl, exportc: "nimfw_direct_csi_stat".}:
    array[DirectCsiProbeSlots, uint32]
  var nimFwDirectCsiWin0* {.wifiCtrl, exportc: "nimfw_direct_csi_win0".}:
    array[DirectCsiProbeSlots, uint32]
  var nimFwDirectCsiHash* {.wifiCtrl, exportc: "nimfw_direct_csi_hash".}:
    array[DirectCsiProbeSlots, uint32]

proc nimFwRxDmaAfterInitProbe*() {.exportc, cdecl, noinline.} =
  {.emit: "asm volatile(\"nop\" ::: \"memory\");".}

proc nimFwScanRxFilterProbe*() {.exportc, cdecl, noinline.} =
  {.emit: "asm volatile(\"nop\" ::: \"memory\");".}

proc rx_swdesc_init*() {.exportc, cdecl.} =
  ## Initialize RX software descriptors.
  ## Blob layout is 41 entries of 24 bytes. Each software descriptor stores its
  ## paired RX header descriptor at offset +4.
  let saved = irqSave()
  defer: irqRestore(saved)
  inc rxInitializationEpoch
  rxStationIdentities = default(typeof(rxStationIdentities))
  for rxSwTableIndex in 0 ..< 41:
    inc rxUploadEpochs[rxSwTableIndex]
    rxSwTableDescAt(rxSwTableIndex).firstHeaderDesc =
      cast[pointer](rxHeaderHwDescAt(rxSwTableIndex))

proc rxInitializeHwDescriptors(resetAll: uint32): bool =
  ## Build the vendor's header/payload chains within one platform critical
  ## section. A nested initialization supersedes the current operation.
  let saved = irqSave()
  inc rxInitializationEpoch
  let generation = rxInitializationEpoch
  let enterFn = cast[proc(): uint32 {.cdecl.}](blOpsFunc(20))
  let leaveFn = cast[proc(level: uint32) {.cdecl.}](blOpsFunc(24))
  irqRestore(saved)
  if enterFn == nil or leaveFn == nil:
    assert_rec("rxl_hwdesc.c", "RX critical callbacks", 0)
    return false
  let savedStatus = enterFn()
  defer:
    leaveFn(savedStatus)
    if rxInitializationEpoch != generation:
      result = false
  if rxInitializationEpoch != generation:
    return false
  type PrintFn = proc(fmt: cstring) {.cdecl, varargs.}
  # Constants
  const BAADF00D = 0xBAADF00D'u32
  const C0DEDBAD = 0xC0DEDBAD'u32
  const HD_COUNT = 41
  const PD_COUNT = 41
  # Each pool needs a current entry and a separate submitted entry. Check both
  # before changing either chain or publishing either DMA head.
  if resetAll == 0:
    var availableHeaders = 0'u32
    var availablePayloads = 0'u32
    for headerDescIndex in 0 ..< HD_COUNT:
      if rxHeaderHwDescAt(headerDescIndex).usedFlag != 1:
        inc availableHeaders
    for payloadDescIndex in 0 ..< PD_COUNT:
      if rxPayloadHwDescAt(payloadDescIndex).usedFlag != 1:
        inc availablePayloads
    if availableHeaders < 2 or availablePayloads < 2:
      let logPtr = blOpsFunc(4)
      if logPtr != nil:
        if availableHeaders < 2:
          cast[PrintFn](logPtr)("No enough DESC %d(%d)\r\n",
            availableHeaders.cint, HD_COUNT.cint)
        else:
          cast[PrintFn](logPtr)("No enough PBD DESC, %d(%d)\r\n",
            availablePayloads.cint, PD_COUNT.cint)
      return false
  # Initialize HD chain
  # HD descriptors are in a contiguous block; we walk through checking DMA ownership
  var hdCurrent: pointer = nil
  var hdHead: pointer = nil
  var hdTail: pointer = nil
  var hdPrev: pointer = nil
  var hdCount: uint32 = 0
  for headerDescIndex in 0 ..< HD_COUNT:
    let hd = rxHeaderHwDescAt(headerDescIndex)
    let dmaOwned = hd.usedFlag
    if resetAll != 0 or dmaOwned != 1:
      if hdPrev != nil:
        cast[ptr RxHeaderHwDescView](hdPrev).next = cast[pointer](hd)
      # Initialize descriptor fields
      hd.nextThd = 0
      hd.status = 0
      hd.flags = 0
      rxForgetStation(cast[pointer](hd))
      hd.rxVectorLengthAmpdu = 0
      # Offset 28 holds frame length followed by A-MPDU status.
      cast[ptr uint16](addr hd.tsfLow)[] = 0'u16
      hd.tsfHigh = 0
      hd.rxVector1a = 0
      hd.rxVector1b = 0
      hd.rxVector1c = 0
      hd.rxVector1d = 0
      hd.rxVector2a = 0
      hd.rxVector2b = 0
      hd.rxVectorStatus = 0
      hd.bufferAddr = 0
      hd.swDesc = cast[uint32](rxSwTableDescAt(headerDescIndex))
      hd.magic = BAADF00D
      hd.next =
        if headerDescIndex + 1 < HD_COUNT:
          cast[pointer](rxHeaderHwDescAt(headerDescIndex + 1))
        else:
          nil
      hdPrev = cast[pointer](hd)
      if hdCount == 0:
        hdCurrent = cast[pointer](hd)
      elif hdCount == 1:
        hdHead = cast[pointer](hd)
      hdTail = cast[pointer](hd)
      hdCount += 1
    else:
      if hdPrev != nil:
        cast[ptr RxHeaderHwDescView](hdPrev).next = nil
  if hdCount <= 3:
    let logPtr = blOpsFunc(4)
    if logPtr != nil:
      cast[PrintFn](logPtr)("No enough DESC %d(%d)\r\n", hdCount.cint, HD_COUNT.cint)
      if rxInitializationEpoch != generation:
        return false
  # Terminate HD chain
  if hdPrev != nil:
    cast[ptr RxHeaderHwDescView](hdPrev).next = nil
  # Write HD head to MAC register
  machwRxSetHdSubmittedHead(cast[uint32](hdHead))
  # Trigger HD DMA: write 0x4000000 to trigger register
  machwRxDmaTrigger(0x04000000'u32)
  # Initialize PD chain
  var pdCurrent: pointer = nil
  var pdHead: pointer = nil
  var pdTail: pointer = nil
  var pdPrev: pointer = nil
  var pdCount: uint32 = 0
  for payloadDescIndex in 0 ..< PD_COUNT:
    let pd = rxPayloadHwDescAt(payloadDescIndex)
    let dmaOwned = pd.usedFlag
    if resetAll != 0 or dmaOwned != 1:
      # Initialize PD descriptor
      if pdPrev != nil:
        cast[ptr RxPayloadHwDescView](pdPrev).next = cast[pointer](pd)
      let payloadBuffer = rxPayloadBufferAt(payloadDescIndex)
      pd.magic = C0DEDBAD
      pd.next =
        if payloadDescIndex + 1 < PD_COUNT:
          cast[pointer](rxPayloadHwDescAt(payloadDescIndex + 1))
        else:
          nil
      # The adjacent reserved halfword is outside bufstatinfo.
      rxDmaProgressDescAt(cast[pointer](pd)).status = 0
      pd.bufferAddr = cast[uint32](addr payloadBuffer.payloadBytes[0])
      pd.bufferEnd = cast[uint32](addr payloadBuffer.payloadBytes[1735])
      pd.bufferStart = cast[uint32](addr payloadBuffer.payloadBytes[0])
      pdPrev = cast[pointer](pd)
      if pdCount == 0:
        pdCurrent = cast[pointer](pd)
      elif pdCount == 1:
        pdHead = cast[pointer](pd)
      pdTail = cast[pointer](pd)
      pdCount += 1
    else:
      if pdPrev != nil:
        cast[ptr RxPayloadHwDescView](pdPrev).next = nil
  if pdCount <= 3:
    let logPtr = blOpsFunc(4)
    if logPtr != nil:
      cast[PrintFn](logPtr)("No enough PBD DESC, %d(%d)\r\n", pdCount.cint, PD_COUNT.cint)
      if rxInitializationEpoch != generation:
        return false
  # Terminate PD chain
  if pdPrev != nil:
    cast[ptr RxPayloadHwDescView](pdPrev).next = nil
  # Write PD head to MAC register
  machwRxSetPdSubmittedHead(cast[uint32](pdHead))
  # Trigger PD DMA: write 0x8000000 to trigger register
  machwRxDmaTrigger(0x08000000'u32)
  nimFwRxDmaAfterInitProbe()
  if rxInitializationEpoch != generation:
    return false
  # Sanity check: all chain pointers should be non-nil
  if hdCurrent == nil or hdHead == nil or hdTail == nil or pdCurrent == nil or pdHead == nil or pdTail == nil:
    # Log error via g_bl_ops_funcs[4]
    let logPtr = blOpsFunc(4)
    if logPtr != nil:
      cast[PrintFn](logPtr)("%p:%p%p vs %p:%p:%p\r\n",
        hdCurrent, hdHead, hdTail, pdCurrent, pdHead, pdTail)
      if rxInitializationEpoch != generation:
        return false
  # Store chain pointers — blob splits across TWO structures:
  # rxl_cntrl_env offsets 8,12,16: submitted HD head, HD tail, current HD.
  # rx_hwdesc_env offsets 0,4: PD tail/current.
  let rxlEnv = rxlCntrlEnvView()
  rxlEnv.submittedHead = hdHead
  rxlEnv.submittedTail = hdTail
  rxlEnv.currentHd = hdCurrent
  let rxHwEnv = rxHwDescEnvView()
  rxHwEnv.pdTail = pdTail
  rxHwEnv.pdCurrent = pdCurrent
  rfPhyTraceCheckpoint(0x10'u32)
  result = rxInitializationEpoch == generation

proc rxl_hwdesc_init*(resetAll: uint32): bool {.exportc, cdecl, discardable.} =
  ## Initialize eligible RX DMA descriptors, preserving entries still in use.
  if rxInitializeHwDescriptors(resetAll): return true
  let saved = irqSave()
  defer: irqRestore(saved)
  txControlEnv().resetInProgress = 1
  hal_machw_disable_int()
  ke_evt_set(0x80000000'u32)
  false

proc rxl_init*(): bool {.exportc, cdecl, discardable.} =
  ## Initialize RX layer (50b in blob, 4 calls).
  ## Blob: rxl_hwdesc_init(1), rx_swdesc_init(), co_list_init(rxl_cntrl_env), rxu_cntrl_init()
  let saved = irqSave()
  defer: irqRestore(saved)
  if not rxl_hwdesc_init(1): return false
  rx_swdesc_init()
  co_list_init(addr rxlCntrlEnvView().queue)
  rxu_cntrl_init()
  true

proc rxl_reset*(): bool {.exportc, cdecl, discardable.} =
  ## Reset RX layer — blob rxl_cntrl.o::rxl_reset (50 bytes, 3 calls):
  ##   rxl_hwdesc_init(0)
  ##   co_list_init(&rxl_cntrl_env)        # primary RX cntrl queue
  ##   co_list_init(&rxu_cntrl_env.uploadList) # (tail-call) upload list
  ## Previous Nim called rx_swdesc_init / rxu_cntrl_init which do a superset
  ## of work — that duplicates state resets and diverges from blob's behavior
  ## when other reset sequences call those separately.
  let saved = irqSave()
  defer: irqRestore(saved)
  if not rxl_hwdesc_init(0): return false
  co_list_init(addr rxlCntrlEnvView().queue)
  co_list_init(addr rxuCntrlEnvView().uploadList)
  true

proc rxl_hwdesc_dump*() {.exportc, cdecl, noinline.} =
  ## Match the vendor's fixed rings and its critical section around headers.
  let logFuncPtr = blOpsFunc(4)
  if logFuncPtr == nil: return
  let putsFuncPtr = blOpsFunc(8)
  type PutsFn = proc(s: cstring) {.cdecl.}
  type PrintFn = proc(fmt: cstring) {.cdecl, varargs.}
  let printFn = cast[PrintFn](logFuncPtr)
  if putsFuncPtr != nil:
    cast[PutsFn](putsFuncPtr)("---------- rxl_hwdesc_dump -------\r\n")
  printFn("rx_dma_hdrdesc: %d\r\n", 41.cint)
  block:
    let enterFn = cast[proc(): uint32 {.cdecl.}](blOpsFunc(20))
    let leaveFn = cast[proc(level: uint32) {.cdecl.}](blOpsFunc(24))
    let entered = enterFn != nil and leaveFn != nil
    let level = if entered: enterFn() else: 0'u32
    defer:
      if entered: leaveFn(level)
    for headerDescDumpIndex in 0'u32 ..< 41:
      let hd = rxHeaderDumpView(rxHeaderHwDescAt(headerDescDumpIndex.int))
      printFn("  [%2d]@%08lx: upatternrx %08lx next %08lx first_pbd_ptr %08lx, swdesc %p\r\n",
              headerDescDumpIndex.cint, cast[uint](hd).culong, hd.magic.culong,
              cast[uint](hd.next).culong, hd.firstPbd.culong,
              cast[pointer](hd.swDesc.uint))
      printFn("    datastartptr %08lx dataendptr %08lx, headerctrlinfo %08lx frmlen %4u ampdu_stat_info %04x\r\n",
              hd.dataStart.culong, hd.dataEnd.culong, hd.headerControl.culong,
              hd.frameLength.cuint, hd.ampduStatus.cuint)
      printFn("    tsflo %08lx tsfhi %08lx recvec1b %08lx recvec1c %08lx recvec1d %08lx recvec2a %08lx recvec2b %08lx statinfo %08lx\r\n",
              hd.timestampLow.culong, hd.timestampHigh.culong,
              hd.rxVector1b.culong, hd.rxVector1c.culong, hd.rxVector1d.culong,
              hd.rxVector2a.culong, hd.rxVector2b.culong, hd.status.culong)
  printFn("rx_payload_desc: %d\r\n", 41.cint)
  for payloadDescDumpIndex in 0'u32 ..< 41:
    let pd = rxPayloadHwDescAt(payloadDescDumpIndex.int)
    var pktLen: uint32 = 0
    if pd.bufferEnd != 0:
      pktLen = pd.bufferEnd + 1'u32 - pd.bufferAddr
    printFn("  [%2d]@%08lx %3lu Bytes: upatternrx %08lx next %08lx datastartptr %08lx dataendptr %08lx bufstatinfo %04x reserved %04X\r\n",
            payloadDescDumpIndex.cint, cast[uint](pd).culong, pktLen.culong,
            pd.magic.culong, cast[uint](pd.next).culong,
            pd.bufferAddr.culong, pd.bufferEnd.culong,
            (pd.status and 0xFFFF'u32).cuint, (pd.status shr 16).cuint)

proc rxl_hd_append*(desc: pointer) {.exportc, cdecl.} =
  ## Append a header descriptor to the RX HD chain.
  ## From disassembly (38 instrs): asserts desc non-nil, reads MAC HW RX header
  ## head through machwRxHwHdHead, manages HD chain in rxl_hwdesc_env[8..16],
  ## clears desc fields, links into chain, and triggers RX HD DMA.
  if desc == nil:
    assert_err("rxl_hwdesc.c", "rxl_hwdesc.c", 267)
    return
  let env = rxlCntrlEnvView()
  let hwHead = machwRxHwHdHead()
  var appendDesc = desc
  let envCur = cast[uint32](env.currentHd)
  if envCur != hwHead:
    env.currentHd = desc
    appendDesc = cast[pointer](envCur)
  let hd = rxHeaderHwDescView(appendDesc)
  rxForgetStation(appendDesc)
  const nextOffset = offsetof(RxHeaderHwDescView, next).uint
  wifiDmaStoreLink(appendDesc, nextOffset, nil)
  hd.bufferAddr = 0
  let lastPtr = env.submittedTail
  hd.flags = 0
  cast[ptr uint16](addr hd.tsfLow)[] = 0'u16
  wifiDmaStoreLink(lastPtr, nextOffset, appendDesc)
  machwRxDmaTrigger(0x01000000'u32)
  let firstPtr = env.submittedHead
  env.submittedTail = appendDesc
  if firstPtr == nil:
    env.submittedHead = appendDesc

proc rxl_pd_append*(swdesc: pointer, prevDesc: pointer, pddesc: pointer) {.exportc, cdecl.} =
  ## Append a payload descriptor to the RX PD chain.
  ## From disassembly (48 instrs): asserts pddesc non-nil, reads MAC HW RX
  ## payload head through machwRxHwPdHead, manages PD chain in
  ## rx_hwdesc_env[0..4], relinks the current/buffer-chain descriptors, clears
  ## the selected status halfword, and triggers RX PD DMA.
  if pddesc == nil:
    assert_err("rxl_hwdesc.c", "rxl_hwdesc.c", 314)
    return
  let env = rxHwDescEnvView()
  let hwPdHead = machwRxHwPdHead()
  let currentDesc = env.pdCurrent
  const nextOffset = offsetof(RxDmaProgressDescView, next).uint
  var submittedHead = swdesc
  var statusDesc = pddesc
  var submittedTail = pddesc
  if cast[uint32](currentDesc) == hwPdHead:
    # Vendor uses th.mveqz here: if prevDesc is nil, submit pddesc directly.
    if prevDesc == nil:
      submittedHead = pddesc
  else:
    env.pdCurrent = pddesc
    statusDesc = currentDesc
    submittedHead = currentDesc
    if prevDesc != nil:
      wifiDmaStoreLink(currentDesc, nextOffset, swdesc)
      submittedTail = prevDesc
    else:
      submittedTail = currentDesc
  rxDmaProgressDescAt(statusDesc).status = 0
  wifiDmaStoreLink(submittedTail, nextOffset, nil)
  wifiDmaStoreLink(env.pdTail, nextOffset, submittedHead)
  machwRxDmaTrigger(0x02000000'u32)
  env.pdTail = submittedTail

proc rxl_frame_release*(desc: pointer) {.exportc, cdecl.} =
  ## Release an RX frame buffer back to the descriptor chain.
  ## From disassembly (16 instrs): reads sw_desc from desc[4], extracts
  ## buffer info, calls rxl_pd_append then tail-calls rxl_hd_append.
  let rx = rxMpduDescView(desc)
  let swDesc = rx.swDesc
  let sw = rxSwDescView(swDesc)
  let bufChain = sw.bufferChain
  let prevDesc = rx.prevDesc
  let pdDesc = rx.curDesc
  rxl_pd_append(bufChain, prevDesc, pdDesc)
  rxl_hd_append(swDesc)

proc rxHeaderDescIndex(desc: pointer): int {.inline.} =
  let base = cast[uint](addr rx_dma_hdrdesc[0])
  let address = cast[uint](desc)
  if address < base:
    return -1
  let offset = address - base
  if offset >= rx_dma_hdrdesc.len.uint or
      offset mod sizeof(RxHeaderHwDescView).uint != 0:
    return -1
  (offset div sizeof(RxHeaderHwDescView).uint).int

proc rxMpduDescIndex(desc: pointer): int {.inline.} =
  let base = cast[uint](addr rx_swdesc_tab[0])
  let address = cast[uint](desc)
  if address < base:
    return -1
  let offset = address - base
  if offset >= rx_swdesc_tab.len.uint or
      offset mod sizeof(RxSwTableDescView).uint != 0:
    return -1
  (offset div sizeof(RxSwTableDescView).uint).int

proc rxMpduHeader(desc: pointer): ptr RxSwDescView {.inline.} =
  let index = rxMpduDescIndex(desc)
  if index < 0 or index >= rx_dma_hdrdesc.len div sizeof(RxHeaderHwDescView):
    return nil
  let header = rxHeaderHwDescAt(index)
  if rxMpduDescView(desc).swDesc != cast[pointer](header) or
      header.swDesc != pointerAddrU32(desc):
    return nil
  rxSwDescView(cast[pointer](header))

proc rxPayloadDescIndex(desc: pointer): int {.inline.} =
  let base = cast[uint](addr rx_payload_desc[0])
  let address = cast[uint](desc)
  if address < base:
    return -1
  let offset = address - base
  if offset >= rx_payload_desc.len.uint or
      offset mod sizeof(RxPayloadHwDescView).uint != 0:
    return -1
  (offset div sizeof(RxPayloadHwDescView).uint).int

proc rxForgetStation(header: pointer) =
  let index = rxHeaderDescIndex(header)
  if index >= 0:
    inc rxUploadEpochs[index]
    rxStationIdentities[index] = default(RxStationIdentity)

proc rxUploadGeneration(desc: pointer): uint32 =
  let index = rxMpduDescIndex(desc)
  if index >= 0: rxUploadEpochs[index] else: 0

proc rxUploadCurrent(desc: pointer; generation: uint32): bool =
  let index = rxMpduDescIndex(desc)
  index >= 0 and rxUploadEpochs[index] == generation

proc rxInvalidateUpload(desc: pointer) =
  let index = rxMpduDescIndex(desc)
  if index >= 0:
    inc rxUploadEpochs[index]

proc rxInvalidateQuiescentVif(vifIdx: uint8; selected: uint8) =
  inc rxVifEpochs[vifIdx]
  txl_retire_vif(vifIdx, selected)

proc rxInvalidateVif(vifIdx: uint8): bool =
  if vifIdx >= MAX_VIFS.uint8: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  var selected: uint8
  if not txlHaltVifQueues(vifIdx, selected): return false
  rxInvalidateQuiescentVif(vifIdx, selected)
  true

proc rxCaptureStation(desc: pointer; flags: uint32; statusWord: ptr uint32 = nil) =
  let saved = irqSave()
  defer: irqRestore(saved)
  let index = rxMpduDescIndex(desc)
  if index < 0:
    return
  inc rxUploadEpochs[index]
  var identity = RxStationIdentity(captured: true, station: 0xFF, vif: 0xFF,
    vifEpochs: rxVifEpochs,
    keyRevision: rxKeyRevision,
    associated: (flags and 0x02000000'u32) != 0)
  if identity.associated:
    let hardwareStation = (flags shr 15) and 0x3FF'u32
    if hardwareStation >= 8 and hardwareStation < 8 + STA_INFO_TAB_ENTRIES.uint32:
      let station = (hardwareStation - 8).uint8
      let sta = staInfoForIdx(station)
      if sta.valid == 0 and statusWord != nil:
        # Match BL808 rxl_cntrl_evt+0x11a..0x12c for a slot already invalid
        # at harvest. A slot retired after harvest must instead fail its epoch check.
        identity.associated = false
        statusWord[] = flags and not 0x02000000'u32
      elif sta.valid != 0 and sta.instNbr < MAX_VIFS.uint8:
        identity.station = station
        identity.vif = sta.instNbr
        identity.epoch = staDeleteEpoch(station)
  rxStationIdentities[index] = identity

proc rxIdentityCurrent(identity: RxStationIdentity): bool =
  if not identity.captured:
    return false
  if identity.vif != 0xFF:
    if identity.vif >= MAX_VIFS.uint8 or
        identity.vifEpochs[identity.vif] != rxVifEpochs[identity.vif]:
      return false
  if not identity.associated:
    return true
  if identity.station >= STA_INFO_TAB_ENTRIES.uint8:
    return false
  let sta = staInfoForIdx(identity.station)
  sta.valid != 0 and sta.instNbr == identity.vif and
    staDeleteEpoch(identity.station) == identity.epoch

proc rxStationCurrent(desc: pointer): bool =
  let index = rxMpduDescIndex(desc)
  index >= 0 and rxIdentityCurrent(rxStationIdentities[index])

proc rxCaptureChannel(desc: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  let index = rxMpduDescIndex(desc)
  if index < 0 or not rxStationCurrent(desc): return
  let header = rxMpduHeader(desc)
  if header == nil: return
  let generation = rxUploadGeneration(desc)
  var channel: array[2, uint32]
  phy_get_channel_raw(addr channel[0], 0)
  if not rxUploadCurrent(desc, generation) or not rxStationCurrent(desc) or
      rxMpduHeader(desc) != header: return
  copyMem(addr header.channelInfo[0], addr channel[0], sizeof(channel))
  rxStationIdentities[index].channelGeneration = generation
  rxStationIdentities[index].channelCaptured = true

proc rxCapturedChannelCurrent(desc: pointer): bool =
  let index = rxMpduDescIndex(desc)
  index >= 0 and rxStationIdentities[index].channelCaptured and
    rxStationIdentities[index].channelGeneration == rxUploadGeneration(desc)

proc rxReadCapturedChannel(desc: pointer; channel: var array[2, uint32]): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  if not rxCapturedChannelCurrent(desc): return false
  let header = rxMpduHeader(desc)
  if header == nil: return false
  copyMem(addr channel[0], addr header.channelInfo[0], sizeof(channel))
  true

proc rxBindVif(desc: pointer; vifIdx: uint8): bool =
  let index = rxMpduDescIndex(desc)
  if index < 0:
    return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let identity = addr rxStationIdentities[index]
  if vifIdx >= MAX_VIFS.uint8:
    return vifIdx == 0xFF and rxIdentityCurrent(identity[])
  if identity.vif != 0xFF and identity.vif != vifIdx:
    return false
  # Bind to the epoch captured at harvest, never the current VIF epoch.
  identity.vif = vifIdx
  rxIdentityCurrent(identity[])

proc rxMgtMessageCurrent(header: pointer; protection: ptr RxMgtProtection = nil): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  when defined(bl808WifiDiagPeerRxAdmission):
    if protection != nil: protection[] = rxMgtProtectionUnknown
  var node = rxMgtIdentities
  while node != nil:
    if node.message == header:
      result = rxIdentityCurrent(node.identity)
      when defined(bl808WifiDiagPeerRxAdmission):
        if result and protection != nil: protection[] = node.identity.mgmtProtection
      return
    node = node.next
  true

proc rxMgtNoteProtection(desc: pointer; generation: uint32; protection: RxMgtProtection) =
  when defined(bl808WifiDiagPeerRxAdmission):
    let saved = irqSave()
    defer: irqRestore(saved)
    let index = rxMpduDescIndex(desc)
    if index >= 0 and rxUploadCurrent(desc, generation) and
        rxIdentityCurrent(rxStationIdentities[index]):
      rxStationIdentities[index].mgmtProtection = protection

proc rxMgtForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr rxMgtIdentities
  while link[] != nil:
    if link[].message == header:
      link[] = link[].next
      return
    link = addr link[].next

proc rxMgtIdentityAt(payload: pointer; payloadLength: uint32): ptr RxMgtIdentityNode =
  const mask = alignof(RxMgtIdentityNode).uint - 1
  let start = cast[uint](payload) + payloadLength.uint + KeMsgTailSlack.uint
  cast[ptr RxMgtIdentityNode]((start + mask) and not mask)

proc rxMgtAllocMessage(frame: pointer; destination: uint8;
                      payloadLength: uint32): pointer =
  let index = rxMpduDescIndex(frame)
  if index < 0:
    return nil
  var identity: RxStationIdentity
  var generation: uint32
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    identity = rxStationIdentities[index]
    generation = rxUploadGeneration(frame)
    if not rxIdentityCurrent(identity):
      return nil
  const
    alignment = alignof(RxMgtIdentityNode).uint32
    nodeSize = sizeof(RxMgtIdentityNode).uint32
    extra = KeMsgTailSlack + alignment - 1 + nodeSize
  if payloadLength > high(uint32) - extra:
    return nil
  # The RV32 kernel header need not preserve the allocator's alignment.
  result = ke_msg_alloc(RXU_MGT_IND, destination, TASK_RXU, payloadLength + extra)
  if result == nil:
    return
  let header = keMsgHdrFromPayload(result)
  header.paramLen = payloadLength
  var current = false
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    current = rxUploadCurrent(frame, generation) and rxIdentityCurrent(identity)
    if current:
      let node = rxMgtIdentityAt(result, payloadLength)
      node.message = cast[pointer](header)
      node.identity = identity
      node.next = rxMgtIdentities
      rxMgtIdentities = node
  if not current:
    ke_msg_free(header)
    return nil

proc rxPayloadBufferValid(desc: pointer): bool {.inline.} =
  let index = rxPayloadDescIndex(desc)
  if index < 0:
    return false
  cast[ptr RxPayloadHwDescView](desc).bufferAddr ==
    pointerAddrU32(addr rxPayloadBufferAt(index).payloadBytes[0])

proc rxPayloadChainBounds(head: pointer; previous, last: var pointer): uint8 =
  ## Status bit 0 marks the final payload descriptor, not DMA ownership.
  ## Check the whole frame before publishing or changing any ownership flags.
  previous = nil
  last = nil
  var current = head
  var predecessor: pointer = nil
  var visited = 0'u64
  for count in 1 .. rx_payload_desc.len div sizeof(RxPayloadHwDescView):
    let index = rxPayloadDescIndex(current)
    if index < 0:
      return 0
    let bit = 1'u64 shl index
    if (visited and bit) != 0:
      return 0
    visited = visited or bit
    let payload = rxDmaProgressDescAt(current)
    if (payload.status and 1) != 0:
      previous = predecessor
      last = current
      return count.uint8
    predecessor = current
    current = payload.next
  0

proc rxBeaconLengthSupported(length: uint16): bool {.inline.} =
  # Beacon MAC header plus the unencrypted management body (no FCS).
  length <= 24'u16 + 2304'u16

proc rxAdmitMpdu(desc: pointer; header: var ptr RxSwDescView): RxFrameAdmission =
  header = rxMpduHeader(desc)
  if header == nil or header.uploadDone != 0 or (header.hwFlags and 0x4000) == 0:
    return rxFrameCorrupt
  var previous, last: pointer
  let count = rxPayloadChainBounds(header.bufferChain, previous, last)
  if count == 0:
    return rxFrameCorrupt
  var payload = cast[ptr RxPayloadHwDescView](header.bufferChain)
  for _ in 0 ..< count.int:
    if payload.usedFlag != 0 or not rxPayloadBufferValid(cast[pointer](payload)) or
        payload.bufferStart != payload.bufferAddr:
      return rxFrameCorrupt
    payload = cast[ptr RxPayloadHwDescView](payload.next)

  if not rxStationCurrent(desc):
    return rxFrameDrop
  # Admission sees the original MPDU, before security/header stripping.
  let length = header.mpduLengthBytes.uint32
  if length < 2 or length > count.uint32 * 1736'u32 or
      length <= (count.uint32 - 1) * 1736'u32 or (header.hwFlags and 0x2000) == 0:
    return rxFrameDrop
  let frame = rxFramePayload(header)
  if frame == nil:
    return rxFrameCorrupt
  let frameControl = macDataFrameAt(frame).frameControl
  let headerLength = rxMacHeaderLen(frameControl)
  if (frameControl and 3) != 0 or
      ((frameControl and 8) == 0 and (frameControl and 0x0300) != 0) or
      headerLength == 0 or length < headerLength.uint32:
    return rxFrameDrop
  # Allow the supported management body, MAC header, and security overhead.
  if (frameControl and 0xC) == 0 and length > 2352:
    return rxFrameDrop
  if (frameControl and 0x00FC) == 0x0080:
    if length < headerLength.uint32 + 12 or not rxBeaconLengthSupported(length.uint16):
      return rxFrameDrop
  rxFrameReady

proc rxFrameCurrent(identity: RxFrameIdentity): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  if identity.header == nil or
      not rxUploadCurrent(identity.descriptor, identity.generation) or
      not rxStationCurrent(identity.descriptor):
    return false
  let header = rxMpduHeader(identity.descriptor)
  header != nil and cast[pointer](header) == identity.header and
    header.bufferChain == identity.payload and
    header.mpduLengthBytes == identity.length and
    rxFramePayload(header) == identity.frame

proc rxCaptureFrame(desc: pointer): RxFrameIdentity =
  let saved = irqSave()
  defer: irqRestore(saved)
  let header = rxMpduHeader(desc)
  if header == nil or not rxStationCurrent(desc) or
      rxPayloadDescIndex(header.bufferChain) < 0:
    return
  result = RxFrameIdentity(descriptor: desc, header: header,
    payload: header.bufferChain, frame: rxFramePayload(header),
    generation: rxUploadGeneration(desc), length: header.mpduLengthBytes)
  if result.frame == nil:
    result = default(RxFrameIdentity)

proc rxCaptureFrameHeader(header, vifEntry, staEntry: pointer): RxFrameIdentity =
  let saved = irqSave()
  defer: irqRestore(saved)
  let index = rxHeaderDescIndex(header)
  if index < 0:
    return
  let descriptor = cast[pointer](rxSwTableDescAt(index))
  let station = rxStationIdentities[index]
  if not station.associated or station.station >= STA_INFO_TAB_ENTRIES.uint8 or
      station.vif >= MAX_VIFS.uint8 or
      cast[pointer](staInfoForIdx(station.station)) != staEntry or
      cast[pointer](vifChannelForIdx(station.vif)) != vifEntry:
    return
  result = rxCaptureFrame(descriptor)

proc rxOpenBeaconView(identity: RxFrameIdentity): RxBeaconView =
  ## Parse through a contiguous copy without changing DMA ownership or links.
  const segmentSize = sizeof(RxPayloadBufferView)
  if not rxBeaconLengthSupported(identity.length) or not rxFrameCurrent(identity):
    return
  if identity.length.int <= segmentSize:
    return RxBeaconView(data: identity.frame)
  let allocate = cast[proc(size: uint32): pointer {.cdecl.}](blOpsFunc(184))
  let release = cast[proc(data: pointer) {.cdecl.}](blOpsFunc(188))
  if allocate == nil or release == nil: return
  let storage = allocate(identity.length.uint32)
  if storage == nil: return
  block copySplitBeacon:
    let saved = irqSave()
    defer: irqRestore(saved)
    if not rxFrameCurrent(identity): break copySplitBeacon
    var previous, last: pointer
    if rxPayloadChainBounds(identity.payload, previous, last) != 2:
      break copySplitBeacon
    for descriptor in [identity.payload, last]:
      if not rxPayloadBufferValid(descriptor): break copySplitBeacon
      let payload = cast[ptr RxPayloadHwDescView](descriptor)
      if payload.usedFlag != 0 or payload.bufferStart != payload.bufferAddr:
        break copySplitBeacon
    let firstBytes = addr rxPayloadBufferAt(rxPayloadDescIndex(identity.payload)).payloadBytes[0]
    let lastBytes = addr rxPayloadBufferAt(rxPayloadDescIndex(last)).payloadBytes[0]
    copyMem(storage, firstBytes, segmentSize)
    copyMem(cast[pointer](cast[uint](storage) + segmentSize.uint), lastBytes,
            identity.length.int - segmentSize)
    return RxBeaconView(data: storage, release: release)
  release(storage)

proc rxCloseBeaconView(view: var RxBeaconView) =
  let owned = view
  view = default(RxBeaconView)
  if owned.release != nil: owned.release(owned.data)

proc rxl_mpdu_free*(desc: pointer) {.exportc, cdecl.} =
  ## Recycle a complete RX frame. Corrupt chains request recovery without
  ## publishing partial chains or leaving the platform critical section open.
  let sw = rxMpduHeader(desc)
  if sw == nil:
    assert_rec("rxl_hwdesc.c", "rxl_hwdesc.c", 872)
    return
  let enterFn = cast[proc(): uint32 {.cdecl.}](blOpsFunc(20))
  let leaveFn = cast[proc(level: uint32) {.cdecl.}](blOpsFunc(24))
  if enterFn == nil or leaveFn == nil:
    assert_rec("rxl_hwdesc.c", "rxl_hwdesc.c", 872)
    return
  rxInvalidateUpload(desc)
  let generation = rxUploadGeneration(desc)
  let rx = rxMpduDescView(desc)
  let bufferChain = sw.bufferChain
  template current(): bool =
    rxUploadCurrent(desc, generation) and rxMpduHeader(desc) == sw and
      sw.bufferChain == bufferChain
  let savedStatus = enterFn()
  var corruptChain = false
  try:
    if not current(): return
    var previous, last: pointer
    let count = rxPayloadChainBounds(bufferChain, previous, last)
    if count == 0:
      corruptChain = true
    else:
      sw.uploadDone = 0
      var payload = rxDmaProgressDescAt(bufferChain)
      for _ in 0 ..< count.int:
        payload.usedFlag = 0
        payload = rxDmaProgressDescAt(payload.next)
      rx.curDesc = last
      rx.prevDesc = previous
      rxl_frame_release(desc)
  finally:
    leaveFn(savedStatus)
  if corruptChain and current():
    assert_rec("rxl_hwdesc.c", "rxl_hwdesc.c", 872)

proc rxReleaseUpload(desc: pointer; generation: uint32) =
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  if rxUploadCurrent(desc, generation):
    rxl_mpdu_free(desc)

proc rxReleaseControlFrame(desc: pointer; generation: uint32;
                           header: ptr RxSwDescView; bufferChain: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  if not rxUploadCurrent(desc, generation) or rxMpduHeader(desc) != header or
      header == nil or header.bufferChain != bufferChain or header.uploadDone != 0:
    return
  # Upper RX can publish the frame before a callback returns or reports an
  # error. Neither queued nor host-owned payloads belong to lower RX anymore.
  var queued = rxuCntrlEnvView().uploadList.first
  var remaining = 41
  while queued != nil and remaining > 0:
    if cast[pointer](queued) == desc:
      ke_evt_set(0x00800000'u32)
      return
    if rxMpduDescIndex(cast[pointer](queued)) < 0:
      break
    queued = queued.next
    dec remaining
  if queued != nil:
    irqRestore(saved)
    try: assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 479)
    finally: discard irqSave()
    return
  rxReleaseUpload(desc, generation)

proc rxTransferFrame(desc: pointer): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  let sw = rxMpduHeader(desc)
  if sw == nil:
    outside: assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 160)
    return false
  let identity = rxCaptureFrame(desc)
  if not rxFrameCurrent(identity): return false
  let rx = rxMpduDescView(desc)
  rx.descCount = 0
  rx.prevDesc = nil
  rx.curDesc = nil
  var previous, last: pointer
  var count = rxPayloadChainBounds(sw.bufferChain, previous, last)
  if count == 0:
    outside: assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 160)
    return false
  if not rxCapturedChannelCurrent(desc):
    var channel: array[2, uint32]
    outside: phy_get_channel_raw(addr channel[0], 0)
    if not rxFrameCurrent(identity): return false
    count = rxPayloadChainBounds(sw.bufferChain, previous, last)
    if count == 0:
      outside: assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 160)
      return false
    if not rxCapturedChannelCurrent(desc):
      copyMem(addr sw.channelInfo[0], addr channel[0], sizeof(channel))
  rx.descCount = count - 1
  rx.prevDesc = previous
  rx.curDesc = last
  true

proc rxl_mpdu_transfer*(desc: pointer) {.exportc, cdecl.} =
  ## Record the last payload and its predecessor before queuing a host upload.
  discard rxTransferFrame(desc)

proc rxlRequestBufferedTraffic(identity: ApmPsSession; packetCount: uint8; uapsd: bool): bool =
  if not apmPsSessionCurrent(identity):
    return false
  let sta = staInfoForIdx(identity.station)
  let powerMode = sta.psMode
  let service = sta.psStatus
  let deliveryMask = sta.psState
  let msg = cast[ptr MmTrafficReqIndPayload](
    ke_msg_alloc(MM_TRAFFIC_REQ_IND, TASK_API, TASK_MM, MmTrafficReqIndPayloadSize))
  if msg == nil:
    return false
  if not apmPsSessionCurrent(identity) or sta.psMode != powerMode or
      sta.psStatus != service or sta.psState != deliveryMask or
      (uapsd and (sta.trafficFlags and 4) == 0):
    ke_msg_free_payload(msg)
    return false
  msg.staIdx = identity.station
  msg.packetCount = packetCount
  msg.uapsd = uapsd.uint8
  ke_msg_send(msg)
  true

proc rxlHandleApPowerSave(vif: ptr VifChannelView; sta: ptr StaInfoView;
                          staIdx: uint8; frame: pointer) =
  if vif == nil or sta == nil or frame == nil:
    return
  let saved = irqSave()
  defer: irqRestore(saved)
  if vif.vifType != VIF_TYPE_AP:
    return
  let identity = apmPsCapture(sta)
  if not apmPsSessionCurrent(identity) or identity.station != staIdx or
      vifChannelForIdx(identity.vif) != vif or vif.vifIdx != identity.vif:
    return
  var expectedPowerMode = sta.psMode
  var expectedService = sta.psStatus
  let deliveryMask = sta.psState
  template ensureCurrentService() =
    if not apmPsSessionCurrent(identity) or sta.psMode != expectedPowerMode or
        sta.psStatus != expectedService or sta.psState != deliveryMask:
      return
  let hdr = macDataFrameAt(frame)
  let frameCtrl = hdr.frameControl
  let vifEntry = cast[pointer](vif)
  let staEntry = cast[pointer](sta)
  let bcmcStaIdx = (vif.vifIdx + 5).uint8
  if sta.psMode != 1:
    if (frameCtrl and 0x1400'u16) == 0x1000'u16:
      expectedPowerMode = 1
      mm_ps_change_ind(staIdx, 1)
      ensureCurrentService()
      if vif.psBaCounter == 0:
        mm_ps_change_ind(bcmcStaIdx, 1)
        ensureCurrentService()
      let countVif = vifChannelForIdx(vif.vifIdx)
      countVif.psBaCounter = countVif.psBaCounter + 1
    return

  if (frameCtrl and 0x140C'u16) == 0x0008'u16:
    expectedPowerMode = 0
    mm_ps_change_ind(staIdx, 0)
    ensureCurrentService()
    apm_tx_int_ps_clear(vifEntry, staIdx)
    ensureCurrentService()
    vif.psBaCounter = vif.psBaCounter - 1
    if vif.psBaCounter == 0:
      mm_ps_change_ind(bcmcStaIdx, 0)
      ensureCurrentService()
      apm_tx_int_ps_clear(vifEntry, bcmcStaIdx)
    return

  if (frameCtrl and 0x00FC'u16) == 0x00A4'u16:
    if (sta.trafficFlags and 2) != 0:
      sta.psStatus = sta.psStatus or 1
      expectedService = sta.psStatus
      discard sta_mgmt_send_postponed_frame(vifEntry, staEntry, 1)
      ensureCurrentService()
      sta.psStatus = sta.psStatus and not 1'u32
      expectedService = sta.psStatus
    else:
      discard rxlRequestBufferedTraffic(identity, 1, false)
      ensureCurrentService()

  if (frameCtrl and 0x008C'u16) != 0x0088'u16:
    return
  let qos =
    if (frameCtrl and 0x0300'u16) == 0x0300'u16:
      macQos4AddrFrameAt(frame).qosCtrl
    else:
      macQosDataFrameAt(frame).qosCtrl
  if (qos and 0x0F'u16) >= 8:
    return
  let tid = (qos and 0x0F).uint8
  let ac = mac_tid2ac[tid]
  if (mac_ac2uapsd[ac] and sta.psState) == 0 or (sta.psStatus and 6) != 0:
    return

  # No buffered traffic still needs an EOSP response to the trigger.
  if (sta.trafficFlags and 0x0C) == 0:
    sta.psStatus = 2
    expectedService = 2
    discard txl_frame_send_qosnull_frame(identity.station, tid.uint16 or 0x10'u16, nil, 0)
    ensureCurrentService()
    sta.psStatus = 0
    return

  var remaining = sta.uapsdBitmap
  if (sta.trafficFlags and 8) != 0:
    sta.psStatus = 2
    expectedService = 2
    let sent = sta_mgmt_send_postponed_frame(vifEntry, staEntry, remaining.uint32)
    ensureCurrentService()
    if remaining != 0:
      if sent >= remaining.uint32:
        discard txl_frame_send_qosnull_frame(identity.station, tid.uint16 or 0x10'u16, nil, 0)
        ensureCurrentService()
        sta.psStatus = 0
        return
      remaining -= sent.uint8

  # The drain can change traffic availability, so reload it before deciding
  # whether the host must supply the rest. Zero denotes an unlimited budget.
  if (sta.trafficFlags and 4) != 0:
    sta.psStatus = 4
    expectedService = 4
    if not rxlRequestBufferedTraffic(identity, remaining, true):
      ensureCurrentService()
      sta.psStatus = 0
  else:
    discard txl_frame_send_qosnull_frame(identity.station, tid.uint16 or 0x10'u16, nil, 0)
    ensureCurrentService()
    sta.psStatus = 0

proc rxlObserveStaWmm(desc: pointer; vif: ptr VifChannelView; sta: ptr StaInfoView;
                     frameData: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  if smActivationLive() and smActivation.vif == vif.vifIdx:
    return
  let identity = rxCaptureFrame(desc)
  var channel: array[2, uint32]
  if not rxFrameCurrent(identity) or not rxReadCapturedChannel(desc, channel): return
  let frame = if frameData != nil: frameData else: identity.frame
  if updateStaWmmFromBeacon(vif, sta, frame, identity.length, (channel[0] shr 16).uint16):
    mmRequestStaEdcaRefresh(vif)

proc rxl_cntrl_evt*() {.exportc, cdecl.} =
  ## Drain at most four queued MPDUs, matching the vendor's pre-decremented
  ## five-iteration budget. Run peer power-save/beacon processing before RX
  ## upper, then free only frames whose ownership was not transferred.

  # Blob s1 = &rxl_cntrl_env, s6 = rxl_cntrl_env[0] (first queued RX desc)
  let cntrlEnv = rxlCntrlEnvView()
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    if rxlControlActive:
      if cntrlEnv.queue.first != nil:
        ke_evt_set(0x00100000'u32)
      return
    rxlControlActive = true
  var recoveryRequested = false
  defer:
    let saved = irqSave()
    defer: irqRestore(saved)
    rxlControlActive = false
    if not recoveryRequested and cntrlEnv.processingFlag == 0 and
        cntrlEnv.queue.first != nil:
      ke_evt_set(0x00100000'u32)
  inc nimFwDbgRxlCntrlEvt
  nimFwDbgRxlCntrlHead = pointerAddrU32(cast[pointer](cntrlEnv.queue.first))

  var loopCount: int = 5

  # L70: main processing loop (up to 5 frames per call). Blob samples the queue
  # head, clears the RX event bit, then tests the processing flag/head. It does
  # not disable MAC HW interrupts around the loop — only masks via csrrci
  # mstatus in the co_list_pop critical section below.
  while loopCount > 0:
    let queuedRxMpduDesc = cast[pointer](cntrlEnv.queue.first)
    let frameGeneration = rxUploadGeneration(queuedRxMpduDesc)
    ke_evt_clear(0x00100000'u32)
    if cntrlEnv.processingFlag != 0 or queuedRxMpduDesc == nil:
      # L43 in blob: no tail-call to ke_evt_set here — blob simply returns.
      return

    dec loopCount
    if loopCount <= 0:
      ke_evt_set(0x00100000'u32)
      return

    if cntrlEnv.queue.first != cast[ptr CoListHdr](queuedRxMpduDesc):
      continue
    if rxMpduDescIndex(queuedRxMpduDesc) < 0:
      recoveryRequested = true
      assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 479)
      return
    if not rxUploadCurrent(queuedRxMpduDesc, frameGeneration):
      continue

    # Validate identities and all bytes read by peer processing before pop.
    var sw: ptr RxSwDescView
    let admission = rxAdmitMpdu(queuedRxMpduDesc, sw)
    if admission == rxFrameCorrupt:
      recoveryRequested = true
      assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 479)
      return
    let next = cast[ptr CoListHdr](queuedRxMpduDesc).next
    if next != nil and rxMpduDescIndex(cast[pointer](next)) < 0:
      recoveryRequested = true
      assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 479)
      return

    # L45: IRQ-safe pop from front of the cntrl list (blob 0x94)
    var popped = false
    block:
      let irqState = irqSave()
      defer: irqRestore(irqState)
      if cntrlEnv.queue.first == cast[ptr CoListHdr](queuedRxMpduDesc) and
          rxUploadCurrent(queuedRxMpduDesc, frameGeneration):
        discard co_list_pop_front(addr cntrlEnv.queue)
        popped = true
    if not popped:
      continue

    # Read SW descriptor and buffer chain
    if admission == rxFrameDrop:
      rxReleaseUpload(queuedRxMpduDesc, frameGeneration)
      continue
    let swDesc = cast[pointer](sw)
    let bufChain = sw.bufferChain
    var releaseFrame = true
    defer:
      if releaseFrame:
        rxReleaseControlFrame(queuedRxMpduDesc, frameGeneration, sw, bufChain)
    let frameIdentity = rxCaptureFrame(queuedRxMpduDesc)
    if frameIdentity.generation != frameGeneration:
      continue
    let hwFlags = sw.hwFlags
    var staIdx: uint8 = 0
    var sta: ptr StaInfoView = nil
    var staEntry: pointer = nil
    # The blob has one tail release. Scope cleanup also covers callback errors
    # while preserving any ownership already transferred to upper RX.
    block frameWork:
      template currentFrame(): bool = rxFrameCurrent(frameIdentity)
      if not currentFrame(): break frameWork
      if bufChain == nil:
        assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 479)
        break frameWork

      # Validate frame: both valid and associated bits must be set
      let dbgPayload = rxFrameBufferChainAt(bufChain).frameData
      if dbgPayload == nil:
        break frameWork
      let dbgFc =
        if dbgPayload != nil: cast[ptr uint16](dbgPayload)[].uint32
        else: 0'u32
      when defined(bl808WifiDirectCsiProbe):
        let rxNumber = nimFwDirectCsiRxCount
        inc nimFwDirectCsiRxCount
        if (dbgFc and 0x000C'u32) == 0x0008'u32:
          inc nimFwDirectCsiDataCount
        if rxNumber < DirectCsiProbeSlots.uint32:
          nimFwDirectCsiFc[rxNumber] = dbgFc
          nimFwDirectCsiCtl[rxNumber] = regRead(0x24C008F8'u)
          nimFwDirectCsiStat[rxNumber] = regRead(0x24C00064'u)
          nimFwDirectCsiWin0[rxNumber] = regRead(0x24C09000'u)
          if (nimFwDirectCsiStat[rxNumber] and 1'u32) != 0'u32:
            var checksum = 0x811C9DC5'u32
            for word in 0'u ..< 52'u:
              checksum = (checksum xor regRead(0x24C09000'u + word * 4'u)) *
                0x01000193'u32
            nimFwDirectCsiHash[rxNumber] = checksum
      inc nimFwDbgRxlFrameSeen
      nimFwDbgRxlLastHwFlags = hwFlags
      nimFwDbgRxlLastFc = dbgFc
      if (dbgFc and 0x000C'u32) == 0'u32:
        inc nimFwDbgRxlMgmtSeen
        nimFwDbgRxlMgmtLast = dbgFc or (hwFlags and 0xFFFF0000'u32)
      if (dbgFc and 0x00FC'u32) == 0x00B0'u32:
        inc nimFwDbgRxlAuthLikeSeen
        nimFwDbgRxlAuthLikeHwFlags = hwFlags
        nimFwDbgRxlAuthLikeFc = dbgFc
      when defined(bl808WifiProbeReplyDiag):
        # Capture before upper RX routing can discard or recycle the MPDU.
        if (dbgFc and 0x00FF'u32) == 0x50 and sw.mpduLengthBytes >= 36:
          let probe = macDataFrameAt(dbgPayload)
          if (probe.addr1[0] and 1) == 0 and probe.addr1 != default(typeof(probe.addr1)):
            for index in 0'u8 ..< MAX_VIFS.uint8:
              if probe.addr1 == vifChannelForIdx(index).macAddr:
                var channel: array[2, uint32]
                if rxReadCapturedChannel(queuedRxMpduDesc, channel):
                  let slot = nimFwDbgProbeReplyCount mod nimFwDbgProbeReplySamples.len.uint32
                  nimFwDbgProbeReplySamples[slot] = [macAddrWord0(addr probe.addr3),
                    probe.addr3[4].uint32 or (probe.addr3[5].uint32 shl 8) or
                    (channel[0] and 0xFFFF0000'u32)]
                  inc nimFwDbgProbeReplyCount
                break
      nimFwTrace2U32("[WIFI-NIMFW] rxl_frame ", hwFlags, dbgFc)
      if not currentFrame(): break frameWork
      if (hwFlags and 0x02002000'u32) != 0x02002000'u32:
        releaseFrame = rxu_cntrl_frame_handle(queuedRxMpduDesc) == 0
        break frameWork

      # Blob uses th.extu(hwFlags, 24, 15), asserts that the raw MAC HW STA
      # index is at least the hardware station base, then subtracts that base.
      let hwStaIdx = (hwFlags shr 15) and 0x3FF'u32
      if (hwStaIdx and 0x3F8'u32) == 0:
        assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 495)
        break frameWork
      if hwStaIdx >= 8 + STA_INFO_TAB_ENTRIES.uint32:
        break frameWork
      staIdx = (hwStaIdx - 8).uint8

      # Look up STA entry, check active flag
      sta = staInfoForIdx(staIdx)
      staEntry = cast[pointer](sta)
      if sta.valid == 0:
        break frameWork

      let lastSeen = cast[proc(): uint32 {.cdecl, raises: [Exception].}](blOpsFunc(200))()
      if not currentFrame():
        break frameWork
      staConnectionStartWord(sta)[] = lastSeen

      # VIF lookup
      let vifIdx = sta.instNbr
      if vifIdx.int >= MAX_VIFS:
        break frameWork
      let vif = vifChannelForIdx(vifIdx)

      # Read frame control from RX header
      let rxHdrPtr = macDataFrameAt(rxFrameBufferChainAt(bufChain).frameData)
      let frameCtrl = rxHdrPtr.frameControl
      let vifHwIdx = vif.vifIdx
      if vifHwIdx.int >= MAX_VIFS:
        break frameWork
      rxlHandleApPowerSave(vifChannelForIdx(vifHwIdx), sta, staIdx, rxHdrPtr)
      if not currentFrame():
        break frameWork
      var dispatchFrame = true

      # L54: Vendor runs post-processing before its single RX-upper call site.
      let postVif = vifChannelForIdx(sta.instNbr)
      let postVifEntry = cast[pointer](postVif)
      let pendingCrypto = postVif.state
      if pendingCrypto != 0:
        if (frameCtrl and 4) == 0:
          # Blob 0x1ee: td_pck_ind(a0=vif[87], a1=staIdx, a2=1) for
          # traffic-detect packet counting.
          td_pck_ind(postVif.vifIdx, staIdx, 1)
          if not currentFrame(): break frameWork

        # L66/L67: STA-mode VIF post-processing. Beacon frames run the beacon
        # pipeline and only reach RX upper when mm_check_beacon returns nonzero;
        # other non-retry frames call ps_check_frame before the shared RX-upper
        # site.
        let postCrypto = postVif.vifType
        if postCrypto == 0:
          let postMaskedFC = frameCtrl and 0x00FC
          if postMaskedFC == 0x80:
            # Beacon processing path (blob offsets 0x212-0x254).
            # mm_check_beacon ABI: (a0=bufChain, a1=vifEntry, a2=staEntry, a3=&resultVar)
            let pVif = postVifEntry
            let pSta = staEntry
            let pBuf = swDesc
            var tim: pointer
            var view: RxBeaconView
            defer: rxCloseBeaconView(view)
            let beaconChanged = block:
              if frameIdentity.length.int > sizeof(RxPayloadBufferView):
                view = rxOpenBeaconView(frameIdentity)
                if view.data == nil or not currentFrame(): break frameWork
                mmCheckBeaconFrame(pBuf, pVif, pSta, view.data, tim)
              else:
                var timAddress: uint32
                let changed = mm_check_beacon(pBuf, pVif, pSta, addr timAddress)
                tim = cast[pointer](timAddress)
                changed
            if not currentFrame(): break frameWork
            if beaconChanged == high(uint32): break frameWork
            # WMM follows its own update count, not the RXU beacon fingerprint.
            rxlObserveStaWmm(queuedRxMpduDesc, postVif, sta, view.data)
            if not currentFrame(): break frameWork
            # ps_check_beacon ABI: (a0=resultVar, a1=rx frame length, a2=vifEntry)
            let rxFrameLen = beaconRxDescView(pBuf).frameLen
            ps_check_beacon(tim, rxFrameLen.uint32, pVif)
            if not currentFrame(): break frameWork
            vif_mgmt_bcn_recv(pVif)
            if not currentFrame(): break frameWork
            if postVif.chanCtxt != nil:
              chan_tbtt_switch_update(pVif, postVif.tbttTimer.expiry)
              if not currentFrame(): break frameWork
            if beaconChanged == 0:
              dispatchFrame = false
          elif (frameCtrl and 4) == 0:
            ps_check_frame(cast[pointer](rxHdrPtr), hwFlags, postVifEntry)
            if not currentFrame(): break frameWork

      # Shared tail for all dispatch paths (blob has one rxu_cntrl_frame_handle
      # site after post-processing).
      if dispatchFrame and currentFrame():
        releaseFrame = rxu_cntrl_frame_handle(queuedRxMpduDesc) == 0
        if not releaseFrame:
          break frameWork

  # Unreachable exit (loop exits via return)
  ke_evt_set(0x00100000'u32)

proc nimfw_dbg_rxl_processing_flag*(): uint32 {.exportc, cdecl.} =
  ## RX control processing flag. Set 1 on MM_SET_VIF_STATE_REQ(state=0) teardown
  ## (task_handlers.nim:98), cleared 0 on TASK_MM->IDLE (kernel_mac_channel.nim:658).
  ## If stuck at 1, rxl_cntrl_evt early-returns (:445) -> RX frozen -> rxStalled.
  rxlCntrlEnvView().processingFlag.uint32

proc nimfw_dbg_mm_state*(): uint32 {.exportc, cdecl.} =
  ## TASK_MM (id 0) state. Should be MM_IDLE(0) in steady state; if stuck in
  ## TaskGoingIdleState the processingFlag never clears and RX stays frozen.
  ke_state_get(0'u8).uint32

proc rxl_cntrl_dump*() {.exportc, cdecl, noinline.} =
  ## The ready-list entries reference headers whose flags are at offset 64.
  let logFn = getLogFunc(204)
  if logFn == nil:
    return
  let logProc = cast[proc(level: uint32; tag, file: cstring; line: cint;
                          format: cstring) {.cdecl, varargs.}](logFn)
  const SlotCount = 41
  var slots: array[SlotCount, uint8]
  var flags: array[SlotCount, uint32]
  var count = 0
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    var visited: array[(SlotCount + 31) div 32, uint32]
    var queuedRxDesc = rxlCntrlEnvView().queue.first
    while queuedRxDesc != nil and count < SlotCount:
      let index = rxMpduDescIndex(cast[pointer](queuedRxDesc))
      if index < 0 or index >= SlotCount: break
      let word = index shr 5
      let mask = 1'u32 shl (index and 31)
      if (visited[word] and mask) != 0: break
      visited[word] = visited[word] or mask
      let header = rxMpduHeader(cast[pointer](queuedRxDesc))
      slots[count] = index.uint8
      flags[count] = if header != nil: header.hwFlags else: 0'u32
      inc count
      queuedRxDesc = queuedRxDesc.next
  # Callbacks may reset the rings; only the captured values are used below.
  logProc(2, nil, "rxl_cntrl.c", 763, "---------- rxl_cntrl_dump --------\r\n")
  logProc(2, nil, "rxl_cntrl.c", 766, "  ready list:%d\r\n", count.cint)
  for entry in 0 ..< count:
    logProc(2, nil, "rxl_cntrl.c", 770, " %p(%08lx)",
            cast[pointer](rxSwTableDescAt(slots[entry].int)), flags[entry].culong)
  logProc(2, nil, "rxl_cntrl.c", 774, "\r\n")

proc rxl_dma_evt*() {.exportc, cdecl.} =
  ## RX DMA event handler.
  ## Blob (21 instrs):
  ##   a5 = g_bl_ops_funcs[204]  (dereferenced via +0xcc)
  ##   log(2, nil, "rxl_cntrl.c", 826, "Nothing TODO with rxl_dma_evt\r\n")
  ##   ke_evt_clear(0x00400000)
  ##   *(u32*)0x24A00020 = 32  (DMA ACK register)
  ##   ret
  ## Prior Nim bug: called ke_evt_set; blob calls ke_evt_clear. This is the
  ## DMA completion handler: it runs BECAUSE the event was set, and must
  ## clear it to re-arm.
  # Retire this completion before a diagnostic callback can reenter RX.
  let logFn = block:
    let saved = irqSave()
    defer: irqRestore(saved)
    let callback = getLogFunc(204)
    inc nimFwDbgRxlDmaEvt
    ke_evt_clear(0x00400000'u32)
    regWrite(0x24A00020'u, 0x20'u32)
    callback
  if logFn != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn)(
      2, nil, "rxl_cntrl.c", 826, "Nothing TODO with rxl_dma_evt\r\n")

proc submittedRxReady(desc: pointer): bool {.inline.} =
  rxHeaderDescIndex(desc) >= 0 and
    (rxHeaderHwDescView(desc).flags and 0x4000'u32) != 0

proc rxlScheduleQueuedRx(env: ptr RxlCntrlEnvView) {.inline.} =
  if env.queue.first != nil:
    ke_evt_set(0x00100000'u32)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void rxl_timer_int_handler(void);".}
proc rxl_timer_int_handler*() {.exportc, cdecl.} =
  ## RX timer interrupt handler.
  ## From disassembly (71 instrs): writes 0xA0000 to MACHW_INTC_FORCE
  ## (0x24B0807C), then loops over the HD chain (rxl_hwdesc_env[8]). For each
  ## descriptor with bit 14 (0x4000) set in status[64], dequeues it, extracts
  ## the sw_desc, moves buffer chain, checks status fields, and dispatches:
  ##   - frameLen!=0, field8!=0: co_list_push_back(rxl_cntrl_env, sw_desc)
  ##   - frameLen!=0, field8==0: assert_rec (line 193)
  ##   - frameLen==0, field8!=0: assert_rec (line 227)
  ##   - frameLen==0, field8==0: clear sw_desc[12,16], rxl_hd_append(innerDesc)
  ## Schedule the ready queue on exit unless a reset replaced its generation.
  ## Call graph: co_list_push_back, assert_rec, rxl_hd_append, ke_evt_set
  let saved = irqSave()
  defer: irqRestore(saved)
  regWrite(0x24B0807C'u, 0x000A0000'u32)
  let env = rxlCntrlEnvView()
  let initialization = rxInitializationEpoch
  defer:
    if rxInitializationEpoch == initialization:
      rxlScheduleQueuedRx(env)
  inc nimFwDbgRxlTimerEvt
  nimFwDbgRxlTimerHead = pointerAddrU32(env.submittedHead)

  var visited = 0'u64
  while env.submittedHead != nil:
    if rxInitializationEpoch != initialization:
      return
    let descPtr = env.submittedHead
    let index = rxHeaderDescIndex(descPtr)
    if index < 0:
      assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 193)
      return
    if not submittedRxReady(descPtr):
      break
    let bit = 1'u64 shl index
    if (visited and bit) != 0:
      assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 193)
      return
    visited = visited or bit
    let submitted = rxHeaderHwDescView(descPtr)
    let swDescLink = rxMpduDescView(cast[pointer](rxSwTableDescAt(index)))
    let innerDesc = rxMpduHeader(cast[pointer](swDescLink))
    let next = submitted.next
    let nextIndex = rxHeaderDescIndex(next)
    if innerDesc == nil or (next != nil and
        (nextIndex < 0 or (visited and (1'u64 shl nextIndex)) != 0)):
      assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 193)
      return
    inc nimFwDbgRxlTimerReady
    env.submittedHead = next
    swDescLink.bufferChain = pointerAddrU32(innerDesc.bufferChain)
    let frameLen = innerDesc.mpduLengthBytes
    let payloadBufferAddr = innerDesc.bufferChain
    if frameLen != 0:
      if rxPayloadDescIndex(payloadBufferAddr) < 0:
        # Error: valid status but no buffer (blob: assert_rec line 193)
        assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 193)
        continue
      else:
        # Valid frame: push sw_desc onto rxl_cntrl_env processing list
        rxCaptureStation(cast[pointer](swDescLink), innerDesc.hwFlags, addr innerDesc.hwFlags)
        let generation = rxUploadGeneration(cast[pointer](swDescLink))
        rxCaptureChannel(cast[pointer](swDescLink))
        if rxInitializationEpoch != initialization:
          return
        if not rxUploadCurrent(cast[pointer](swDescLink), generation) or
            rxMpduHeader(cast[pointer](swDescLink)) != innerDesc or
            innerDesc.bufferChain != payloadBufferAddr or
            innerDesc.mpduLengthBytes != frameLen:
          continue
        co_list_push_back(addr env.queue, cast[ptr CoListHdr](swDescLink))
    else:
      if payloadBufferAddr != nil:
        # Error: no status but has buffer (blob: assert_rec line 227)
        assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 227)
        continue
      else:
        # Empty descriptor: clear sw_desc fields and re-append HD for reuse
        swDescLink.curDesc = nil
        swDescLink.prevDesc = nil
        rxl_hd_append(cast[pointer](innerDesc))

proc rxl_timeout_int_handler*() {.exportc, cdecl.} =
  ## RX timeout interrupt handler.
  ## From blob (5 instrs): reads the interrupt mask register at 0x24B0808C,
  ## clears bit 6 (AND with ~64 = 0xFFFFFFBF), writes back; ret.
  let regAddr = MACHW_INTC_IRQ_STAT_REG
  var machwInterruptControl = volatileLoad(cast[ptr uint32](regAddr))
  machwInterruptControl = machwInterruptControl and (not 64'u32)  # clear bit 6
  volatileStore(cast[ptr uint32](regAddr), machwInterruptControl)

proc rxl_current_desc_get*(outCurrent: ptr pointer, outLast: ptr pointer) {.exportc, cdecl.} =
  ## Get current RX descriptor pointers.
  ## Blob (7 instrs): a0=outCurrent, a1=outLast.
  ## Stores rxl_cntrl_env[16] to *a0 and rx_hwdesc_env[4] to *a1.
  outCurrent[] = rxlCntrlEnvView().currentHd
  outLast[] = rxHwDescEnvView().pdCurrent
