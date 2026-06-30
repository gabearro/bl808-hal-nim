# ###########################################################################
#                   RX LAYER (rxl_*)
# ###########################################################################

proc nimFwRxDmaAfterInitProbe*() {.exportc, cdecl, noinline.} =
  {.emit: "asm volatile(\"nop\" ::: \"memory\");".}

proc nimFwScanRxFilterProbe*() {.exportc, cdecl, noinline.} =
  {.emit: "asm volatile(\"nop\" ::: \"memory\");".}

proc rx_swdesc_init*() {.exportc, cdecl.} =
  ## Initialize RX software descriptors.
  ## Blob layout is 41 entries of 24 bytes. Each software descriptor stores its
  ## paired RX header descriptor at offset +4.
  for rxSwTableIndex in 0 ..< 41:
    rxSwTableDescAt(rxSwTableIndex).firstHeaderDesc =
      cast[pointer](rxHeaderHwDescAt(rxSwTableIndex))

proc rxl_hwdesc_init*(resetAll: uint32) {.exportc, cdecl.} =
  ## Initialize RX HW descriptors and program DMA.
  ## From disassembly (159 instrs): Allocates a scratch buffer via
  ## g_bl_ops_funcs[20] (platform alloc), then initializes two descriptor chains:
  ##
  ## 1. HD (Header Descriptor) chain: 41 entries, stride 100 bytes each.
  ##    Each HD is initialized with 0xBAADF00D magic if DMA-owned (field[96]==1).
  ##    Fields cleared: [16,20,64,24,8,28] = 0. Chain linked via [4] pointers.
  ##    HD head written through machwRxSetHdSubmittedHead, then HD DMA is triggered.
  ##
  ## 2. PD (Payload Descriptor) chain: 41 entries, stride 52 bytes each.
  ##    Each PD is initialized with 0xC0DEDBAD magic if DMA-owned (field[20]==1).
  ##    Fields cleared: [16,4,8,0,24] = 0, [12] = next desc addr.
  ##    PD head written through machwRxSetPdSubmittedHead, then PD DMA is triggered.
  ##
  ## 3. Stores chain head/tail pointers into rxl_hwdesc_env.
  ## 4. Tail-calls g_bl_ops_funcs[24] (platform free) to release scratch buffer.
  # Get platform alloc function from g_bl_ops_funcs[20]
  let allocFnPtr = blOpsFunc(20)
  if allocFnPtr == nil: return
  type AllocFn = proc(): pointer {.cdecl.}
  type FreeFn = proc(p: pointer) {.cdecl.}
  let allocFn = cast[AllocFn](allocFnPtr)
  let scratchBuf = allocFn()
  # Constants
  const BAADF00D = 0xBAADF00D'u32
  const C0DEDBAD = 0xC0DEDBAD'u32
  const HD_COUNT = 41
  const PD_COUNT = 41
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
      hd.rxVectorLengthAmpdu = 0
      hd.tsfLow = 0
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
      pd.status = 0
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
  # Terminate PD chain
  if pdPrev != nil:
    cast[ptr RxPayloadHwDescView](pdPrev).next = nil
  # Write PD head to MAC register
  machwRxSetPdSubmittedHead(cast[uint32](pdHead))
  # Trigger PD DMA: write 0x8000000 to trigger register
  machwRxDmaTrigger(0x08000000'u32)
  nimFwRxDmaAfterInitProbe()
  # Sanity check: all chain pointers should be non-nil
  if hdCurrent == nil or hdHead == nil or hdTail == nil or pdCurrent == nil or pdHead == nil or pdTail == nil:
    # Log error via g_bl_ops_funcs[4]
    let logPtr = blOpsFunc(4)
    if logPtr != nil:
      type LogFn = proc(fmt: cstring, a: pointer, b: pointer, c: pointer, d: pointer, e: pointer) {.cdecl.}
      let logFn = cast[LogFn](logPtr)
      logFn("rxl_hwdesc.c", hdHead, hdTail, pdHead, pdTail, nil)
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
  # Free scratch buffer via g_bl_ops_funcs[24] (platform free)
  let freeFnPtr = blOpsFunc(24)
  if freeFnPtr != nil:
    let freeFn = cast[FreeFn](freeFnPtr)
    freeFn(scratchBuf)

proc rxl_init*() {.exportc, cdecl.} =
  ## Initialize RX layer (50b in blob, 4 calls).
  ## Blob: rxl_hwdesc_init(1), rx_swdesc_init(), co_list_init(rxl_cntrl_env), rxu_cntrl_init()
  rxl_hwdesc_init(1)
  rx_swdesc_init()
  co_list_init(addr rxlCntrlEnvView().queue)
  rxu_cntrl_init()

proc rxl_reset*() {.exportc, cdecl.} =
  ## Reset RX layer — blob rxl_cntrl.o::rxl_reset (46 bytes, 3 calls):
  ##   rxl_hwdesc_init(0)
  ##   co_list_init(&rxl_cntrl_env)        # primary RX cntrl queue
  ##   co_list_init(&rxu_cntrl_env.uploadList) # (tail-call) upload list
  ## Previous Nim called rx_swdesc_init / rxu_cntrl_init which do a superset
  ## of work — that duplicates state resets and diverges from blob's behavior
  ## when other reset sequences call those separately.
  rxl_hwdesc_init(0)
  co_list_init(addr rxlCntrlEnvView().queue)
  co_list_init(addr rxuCntrlEnvView().uploadList)

proc rxl_hwdesc_dump*() {.exportc, cdecl, noinline.} =
  ## Dump RX HW descriptor state for debugging.
  ## From disassembly (159 instrs in full dump variant): Uses g_bl_ops_funcs
  ## function pointers to print all RX HW descriptor chain state.
  ##
  ## Structure:
  ##   1. Print header via g_bl_ops_funcs[8] (puts-like)
  ##   2. Print separator line via g_bl_ops_funcs[4] (printf-like with count=41)
  ##   3. Get chain start via g_bl_ops_funcs[20] (timestamp/snapshot)
  ##   4. Loop 41 times over HD chain (stride 100), printing:
  ##      - HD address, fields [0..12] via g_bl_ops_funcs[4] (7-arg format)
  ##      - HD fields [16..30] via g_bl_ops_funcs[4] (6-arg format)
  ##      - HD fields [32..64] via g_bl_ops_funcs[4] (9-arg format)
  ##   5. Get PD chain snapshot via g_bl_ops_funcs[24]
  ##   6. Print PD separator via g_bl_ops_funcs[4]
  ##   7. Loop 41 times over PD chain (stride 52), printing:
  ##      - PD fields with computed length (end-start if non-zero)
  ##
  ## This is purely diagnostic; safe to implement as a logging pass.
  let logFuncPtr = blOpsFunc(4)
  if logFuncPtr == nil: return
  let putsFuncPtr = blOpsFunc(8)
  type PutsFn = proc(s: cstring) {.cdecl.}
  type PrintFn = proc(fmt: cstring) {.cdecl, varargs.}
  let printFn = cast[PrintFn](logFuncPtr)
  # Print header
  if putsFuncPtr != nil:
    let putsFn = cast[PutsFn](putsFuncPtr)
    putsFn("rxl_hwdesc dump")
  # Print HD chain header with count
  printFn("HD chain (%d entries):", 41)
  # Snapshot function for timing (g_bl_ops_funcs[20])
  let snapFuncPtr = blOpsFunc(20)
  var snapResult: pointer = nil
  if snapFuncPtr != nil:
    type SnapFn = proc(): pointer {.cdecl.}
    snapResult = cast[SnapFn](snapFuncPtr)()
  # Walk HD chain - 41 typed entries (blob sym: rx_dma_hdrdesc)
  for headerDescDumpIndex in 0'u32 ..< 41:
    let hd = rxHeaderHwDescAt(headerDescDumpIndex.int)
    printFn("HD[%d] @%p: %08x %08x %08x %08x",
            headerDescDumpIndex, cast[pointer](hd), hd.magic, pointerAddrU32(hd.next),
            hd.bufferAddr, hd.swDesc)
    printFn("  %08x %08x %08x %08x",
            hd.nextThd, hd.status, hd.rxVectorLengthAmpdu, hd.tsfLow)
    printFn("  %08x %08x %08x %08x %08x %08x %08x %08x %08x",
            hd.tsfHigh, hd.rxVector1a, hd.rxVector1b, hd.rxVector1c,
            hd.rxVector1d, hd.rxVector2a, hd.rxVector2b,
            hd.rxVectorStatus, hd.flags)
  # Restore/free snapshot
  if snapFuncPtr != nil and snapResult != nil:
    let freeFuncPtr = blOpsFunc(24)
    if freeFuncPtr != nil:
      type FreeFn = proc(p: pointer) {.cdecl.}
      cast[FreeFn](freeFuncPtr)(snapResult)
  # Print PD chain
  printFn("PD chain (%d entries):", 41)
  for payloadDescDumpIndex in 0'u32 ..< 41:
    let pd = rxPayloadHwDescAt(payloadDescDumpIndex.int)
    # Compute length: if end != 0 then end+1-start else 0
    var pktLen: uint32 = 0
    if pd.bufferEnd != 0:
      pktLen = pd.bufferEnd + 1 - pd.bufferStart
    printFn("PD[%d] @%p: %08x %08x %08x %08x len=%d %04x %04x",
            payloadDescDumpIndex, cast[pointer](pd), pd.magic, pointerAddrU32(pd.next),
            pd.bufferAddr, pd.bufferEnd, pktLen, uint16(pd.status and 0xFFFF'u32),
            uint16(pd.status shr 16))

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
  hd.next = nil
  hd.bufferAddr = 0
  let lastPtr = env.submittedTail
  hd.flags = 0
  hd.tsfLow = 0
  if lastPtr != nil:
    rxHeaderHwDescView(lastPtr).next = appendDesc
  machwRxDmaTrigger(0x10000000'u32)
  let firstPtr = env.submittedHead
  env.submittedTail = appendDesc
  if firstPtr == nil:
    env.submittedHead = appendDesc

proc rxl_pd_append*(swdesc: pointer, prevDesc: pointer, pddesc: pointer) {.exportc, cdecl.} =
  ## Append a payload descriptor to the RX PD chain.
  ## From disassembly (48 instrs): asserts pddesc non-nil, reads MAC HW RX
  ## payload head through machwRxHwPdHead, manages PD chain in
  ## rxl_hwdesc_env[0..4], links pddesc, clears status, and triggers RX PD DMA.
  if pddesc == nil:
    assert_err("rxl_hwdesc.c", "rxl_hwdesc.c", 314)
    return
  let env = rxHwDescEnvView()
  let hwPdHead = machwRxHwPdHead()
  let pd = rxDmaProgressDescAt(pddesc)
  let envTail = cast[uint32](env.pdCurrent)
  if envTail == hwPdHead:
    pd.status = 0
  else:
    env.pdCurrent = pddesc
    if prevDesc != nil:
      rxFrameBufferChainAt(swdesc).next = pddesc
    pd.status = 0
  let oldLast = env.pdTail
  pd.next = nil
  if oldLast != nil:
    rxDmaProgressDescAt(oldLast).next = pddesc
  machwRxDmaTrigger(0x20000000'u32)
  env.pdTail = pddesc

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

proc rxl_mpdu_free*(desc: pointer) {.exportc, cdecl.} =
  ## Free an RX MPDU and all associated descriptors.
  ## From disassembly (54 instrs): loads sw_desc from desc[4], walks the HW
  ## descriptor chain from sw_desc[8]. Calls env[20] get_status, clears
  ## sw_desc[96], then walks chain checking status[16] bit 0. When DMA-owned
  ## descriptor found, saves state, calls rxl_frame_release. Chain exhausted
  ## triggers assert_rec. Finally calls env[24] cleanup.
  let rx = rxMpduDescView(desc)
  let swDescPtr = rx.swDesc
  let sw = rxSwDescView(swDescPtr)
  var dmaProgressDesc = rxDmaProgressDescAt(sw.bufferChain)
  # Call platform get_status via env[20]
  let getStatusFn = blOpsFunc(20)
  var savedStatus: pointer = nil
  if getStatusFn != nil:
    savedStatus = cast[proc(): pointer {.cdecl.}](getStatusFn)()
  sw.uploadDone = 0
  var previousDmaProgressDesc: ptr RxDmaProgressDescView = nil
  while dmaProgressDesc != nil:
    let dmaDescriptorStatus = dmaProgressDesc.status
    dmaProgressDesc.usedFlag = 0
    if (dmaDescriptorStatus and 1) != 0:
      # DMA owned -- save position and release
      rx.curDesc = cast[pointer](dmaProgressDesc)
      rx.prevDesc = cast[pointer](previousDmaProgressDesc)
      rxl_frame_release(desc)
      let cleanFn = blOpsFunc(24)
      if cleanFn != nil:
        cast[proc(a: pointer) {.cdecl.}](cleanFn)(savedStatus)
      return
    previousDmaProgressDesc = dmaProgressDesc
    dmaProgressDesc = rxDmaProgressDescAt(dmaProgressDesc.next)
  assert_rec("rxl_hwdesc.c", "rxl_hwdesc.c", 872)
  let cleanFn = blOpsFunc(24)
  if cleanFn != nil:
    cast[proc(a: pointer) {.cdecl.}](cleanFn)(savedStatus)

proc rxl_mpdu_transfer*(desc: pointer) {.exportc, cdecl.} =
  ## Transfer RX MPDU to host via DMA (42 instrs in blob).
  ## From blob: desc is a wrapper struct. desc[4] = swDesc pointer.
  ## Reads swDesc[8] to get the HW descriptor chain head (s1).
  ## Initializes swDesc[68] area (co_list_init or memset).
  ## Zeroes desc[21] (dmaCount). Walks HW descriptor chain:
  ##   - Check status[16] bit 0: if DMA-owned, save to desc[12]/[16] and return.
  ##   - Otherwise increment dmaCount in desc[21], follow next at offset 4.
  ## If chain exhausted (next==nil): tail-call rxl_mpdu_free(desc) for cleanup.
  if desc == nil: return
  let rx = rxMpduDescView(desc)
  let swDescPtr = rx.swDesc
  if swDescPtr == nil: return
  let sw = rxSwDescView(swDescPtr)
  # Get current PHY channel info into swDesc+68 (blob: phy_get_channel(swDesc+68, 0)).
  phy_get_channel_raw(cast[pointer](addr sw.channelInfo[0]), 0)
  # Get HW descriptor chain head from swDesc[8]
  var dmaProgressDesc = rxDmaProgressDescAt(sw.bufferChain)
  # Clear dmaCount at desc[21]
  rx.descCount = 0
  var previousDmaProgressDesc: ptr RxDmaProgressDescView = nil
  while dmaProgressDesc != nil:
    if (dmaProgressDesc.status and 1) != 0:
      # DMA still owns this descriptor -- save state and return
      rx.prevDesc = cast[pointer](previousDmaProgressDesc)
      rx.curDesc = cast[pointer](dmaProgressDesc)
      return
    # Increment dmaCount
    rx.descCount = rx.descCount + 1
    if dmaProgressDesc.next == nil:
      # Chain exhausted without finding DMA-owned descriptor: assert
      assert_rec("rxl_mpdu.c", "rxl_mpdu.c", 160)
      return
    previousDmaProgressDesc = dmaProgressDesc
    dmaProgressDesc = rxDmaProgressDescAt(dmaProgressDesc.next)

proc rxl_cntrl_evt*() {.exportc, cdecl.} =
  ## RX control event handler (352 instrs).
  ## From disassembly: main RX processing loop that dequeues received frames
  ## from the MAC HW DMA engine and dispatches them to upper-MAC handlers.
  ##
  ## The blob processes up to 5 frames per invocation (loop counter on stack[0]).
  ## For each frame iteration:
  ##   1. Read current RX HW descriptor from rxl_hwdesc_env[0] (-> s6)
  ##   2. Call hal_machw_disable_int with RX event mask in a0; blob helper
  ##      ignores a0 and clears the top-level MAC interrupt gate.
  ##   3. Check rxl_hwdesc_env[24] != 0 (processing flag) -> exit
  ##   4. Check s6 == NULL -> exit
  ##   5. Decrement loop counter; if 0 -> tail-call ke_evt_set(0x100000)
  ##   6. csrrci mstatus,8 to disable IRQs; call rxl_mpdu_transfer(s1); restore
  ##   7. s8 = s6[4] (SW descriptor); s2 = s8[8] (buf chain); assert s2 != nil
  ##   8. s5 = s8[64] (HW status flags)
  ##   9. Check (s5 & 0x20020000) == 0x20020000 -> valid + associated
  ##  10. bfext s5 to get STA index, sta_entry = sta_info_tab[idx*368]
  ##  11. Check sta_entry[42] (active flag); extract vif_idx from sta_entry[39]
  ##  12. s1 = vif_info_tab[vif_idx * 1512]; check vif_entry[86] (crypto)
  ##  13. Frame type dispatch on (frameCtrl & 0xFC):
  ##      - 0x88 (QoS Data): check BA state at sta[73], handle reorder
  ##      - 0xA4 (Action/BAR): send BAR indication to BAM task
  ##      - 0x80 (Data): route to rxu_cntrl_frame_handle
  ##  14. Release frame via rxl_mpdu_free(s6)
  ##  15. Loop or exit
  ##
  ## The function also handles:
  ##   - Per-VIF BA window tracking and advance
  ##   - Sending ke_msg for BAR/ADDBA indications (msg_id=9, dest=BAM task)
  ##   - Incrementing VIF pending BA counter at vif_entry[334]
  ##   - Power save wakeup notifications

  # Blob s1 = &rxl_cntrl_env, s6 = rxl_cntrl_env[0] (first queued RX desc)
  let cntrlEnv = rxlCntrlEnvView()
  let hwFlagsClearMask = 0xFDFFFFFF'u32  # ~0x02000000
  inc nimFwDbgRxlCntrlEvt
  nimFwDbgRxlCntrlHead = pointerAddrU32(cast[pointer](cntrlEnv.queue.first))

  # Clear RX event bit before processing (blob: ke_evt_clear at entry)
  ke_evt_clear(0x00100000'u32)

  var loopCount: int = 5

  # L70: main processing loop (up to 5 frames per call). Blob does NOT disable
  # MAC HW interrupts around the loop — only masks via csrrci mstatus in the
  # co_list_pop critical section below.
  while loopCount > 0:
    let queuedRxMpduDesc = cast[pointer](cntrlEnv.queue.first)
    if cntrlEnv.processingFlag != 0 or queuedRxMpduDesc == nil:
      # L43 in blob: no tail-call to ke_evt_set here — blob simply returns.
      return

    dec loopCount
    if loopCount <= 0:
      ke_evt_set(0x00100000'u32)
      return

    # L45: IRQ-safe pop from front of the cntrl list (blob 0x94)
    let irqState = irqSave()
    discard co_list_pop_front(addr cntrlEnv.queue)
    irqRestore(irqState)

    # Read SW descriptor and buffer chain
    let swDesc = rxMpduDescView(queuedRxMpduDesc).swDesc
    let sw = rxSwDescView(swDesc)
    let bufChain = sw.bufferChain
    var hwFlags = sw.hwFlags
    var staIdx: uint8 = 0
    var sta: ptr StaInfoView = nil
    var staEntry: pointer = nil
    # Blob has ONE rxl_mpdu_free call site at the loop tail; all early
    # exits converge here via the frameWork block.
    var releaseFrame = true
    block frameWork:
     if bufChain == nil:
       assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 479)
       break frameWork

     # Validate frame: both valid and associated bits must be set
     let dbgPayload =
       if bufChain != nil: pointerAddrU32(rxFrameBufferChainAt(bufChain).frameData)
       else: 0'u32
     let dbgFc =
       if dbgPayload != 0: cast[ptr uint16](dbgPayload.uint)[].uint32
       else: 0'u32
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
     nimFwTrace2U32("[WIFI-NIMFW] rxl_frame ", hwFlags, dbgFc)
     if (hwFlags and 0x20020000'u32) != 0x20020000'u32:
       releaseFrame = rxu_cntrl_frame_handle(queuedRxMpduDesc) == 0
       break frameWork

     # Blob uses th.extu(hwFlags, 24, 15), then subtracts the MAC HW STA base.
     staIdx = (((hwFlags shr 15) and 0x3FF) - 8).uint8

     # Look up STA entry, check active flag
     sta = staInfoForIdx(staIdx)
     staEntry = cast[pointer](sta)
     if sta.valid == 0:
       hwFlags = hwFlags and hwFlagsClearMask
       sw.hwFlags = hwFlags
       releaseFrame = rxu_cntrl_frame_handle(queuedRxMpduDesc) == 0
       break frameWork

     # VIF lookup
     let vifIdx = sta.instNbr
     let vif = vifChannelForIdx(vifIdx)
     let vifEntry = cast[pointer](vif)

     # Read frame control from RX header
     let rxHdrPtr = macDataFrameAt(rxFrameBufferChainAt(bufChain).frameData)
     let frameCtrl = rxHdrPtr.frameControl
     let tid = vif.vifIdx
     let maskedFC = frameCtrl and 0x00FC

     # --- Frame type dispatch ---
     # Blob funnels all dispatch paths through a single rxu_cntrl_frame_handle
     # call site, and it shares the alloc/send between the BA-completion and
     # PS-Poll (byte[2]=0) BAM indications. Use flags + single tail calls.
     var dispatchFrame = false
     var bamSendNeeded = false
     var bamSendByte2: uint8 = 0
     block frameDispatch:
       # Check for QoS Data: (maskedFC & 0x8C) == 0x88
       if (maskedFC and 0x8C) == 0x88:
         let staAuth = sta.psMode
         if staAuth == 1:
          # Associated QoS Data: check BA agreement bits
          let fcCheck = frameCtrl and 0x140C
          if fcCheck == 0x0008:
            # Standard QoS data with BA handling
            mm_ps_change_ind(staIdx, 0)
            apm_tx_int_ps_clear(vifEntry, staIdx)
            dispatchFrame = true
            let pendBA = vif.psBaCounter
            if pendBA > 0:
              vif.psBaCounter = pendBA - 1
              if pendBA - 1 == 0:
                let psStaIdx = cast[uint8]((tid.uint + 5'u) and 0xff'u)
                mm_ps_change_ind(psStaIdx, 0)
                apm_tx_int_ps_clear(vifEntry, psStaIdx)
            break frameDispatch

         # Check per-TID BA state
         let baFlags = sta.trafficFlags
         let baState = sta.psStatus
         if (baFlags and 0x0C) != 0:
           if (baState and 6) != 0:
             break frameDispatch  # BA in progress
           if (baFlags and 8) != 0:
             let baCount = sta.uapsdBitmap
             sta.psStatus = 2
             dispatchFrame = true
             discard sta_mgmt_send_postponed_frame(vifEntry,
               staEntry, baCount.uint32)
             if baCount != 0 and (baCount.int - 1) <= 0:
               sta.psStatus = 0
               let staVifIdx = sta.infoIdx
               discard txl_frame_send_qosnull_frame(
                 staVifIdx, frameCtrl or 0x10'u16, nil, 0)
               sta.psStatus = 0
               # BAM notify (byte[2]=0). Shares alloc/send site with the
               # PS-Poll no-BA path via bamSendByte2==0 below.
               bamSendByte2 = 0
               bamSendNeeded = true
           else:
             if (baFlags and 4) != 0:
               sta.psStatus = 4
               let msgP = cast[ptr BamTrafficStatusPayload](
                 ke_msg_alloc(9, TASK_BAM, 0, BamTrafficStatusPayloadSize))
               if msgP != nil:
                 msgP.staIdx = staIdx
                 msgP.tid = tid
                 msgP.status = 1
                 ke_msg_send(msgP)
             else:
               sta.psStatus = 2
               dispatchFrame = true
         elif (baFlags and 0x0C) == 0 and (baState and 6) == 0:
           sta.psStatus = 2
           dispatchFrame = true

       elif (maskedFC and 0xFC) == 0xA4:
         # Blob .L56 handles PS-Poll (Control type, subtype 10 = 0xA4),
         # NOT BAR — previous comment was wrong. PS-Poll indicates the peer
         # is awake and wants buffered frames.
         let baFlags = sta.trafficFlags
         if (baFlags and 2) != 0:
           # BA-busy: mark sta[48] bit 0, flush postponed frames, clear bit.
           # Blob does NOT call rxu_cntrl_frame_handle here — that was a bug
           # which double-processed the PS-Poll descriptor.
           sta.psStatus = sta.psStatus or 1
           discard sta_mgmt_send_postponed_frame(vifEntry, staEntry, 1)
           sta.psStatus = sta.psStatus and not 1'u32
         else:
           # .L59: no BA yet — request a PS-Poll BAM indication.
           bamSendByte2 = 0
           bamSendNeeded = true

       else:
         # Other frame types: standard data path
         dispatchFrame = true
     # Shared tail for all dispatch paths (blob has 1 rxu_cntrl_frame_handle
     # site; dispatchFrame flag set by each path above).
     if dispatchFrame:
       releaseFrame = rxu_cntrl_frame_handle(queuedRxMpduDesc) == 0
       if not releaseFrame:
         break frameWork

     # Shared BAM-indication site (byte[2]=0 paths). Blob has a single
     # alloc/send pair for these; the baFlags&4 path (byte[2]=1) stays
     # separate as its own site above.
     if bamSendNeeded:
       let msgP = cast[ptr BamTrafficStatusPayload](
         ke_msg_alloc(9, TASK_BAM, 0, BamTrafficStatusPayloadSize))
       if msgP != nil:
         msgP.staIdx = staIdx
         msgP.tid = tid
         msgP.status = bamSendByte2
         ke_msg_send(msgP)

     # L54: Post-dispatch -- check pending crypto and VIF mode
     let postVif = vifChannelForIdx(sta.instNbr)
     let postVifEntry = cast[pointer](postVif)
     let pendingCrypto = postVif.state
     if pendingCrypto != 0 and (frameCtrl and 4) == 0:
       # Blob 0x1ee: td_pck_ind(a0=vif[87], a1=staIdx, a2=1) for traffic-detect
       # packet counting. Previously this path mistakenly called ps_check_frame,
       # which double-dipped into PS processing and skipped the per-VIF TX
       # packet counter increment in td_env.
       td_pck_ind(postVif.vifIdx, 1)

     # L66/L67: Check open-mode Beacon/Data frames (maskedFC == 0x80)
     # From blob (offsets 0x200-0x250): if vif_entry[86]==0 (no crypto) and
     # maskedFC==0x80, run the beacon processing pipeline:
     #   mm_check_beacon(bufChain, vifEntry, staEntry, &resultVar)
     #   ps_check_beacon(resultVar, beaconInterval, vifEntry)
     #   vif_mgmt_bcn_recv(vifEntry)
     #   if vifEntry[64] != 0: chan_tbtt_switch_update(vifEntry, vifEntry[36])
     let postCrypto = postVif.vifType
     if postCrypto == 0:
       let postMaskedFC = frameCtrl and 0x00FC
       if postMaskedFC == 0x80:
         # Beacon processing path (blob offsets 0x212-0x254).
         # mm_check_beacon ABI: (a0=bufChain, a1=vifEntry, a2=staEntry, a3=&resultVar)
         var bcnResult: uint32 = 0
         let pVif = postVifEntry
         let pSta = staEntry
         let pBuf = cast[pointer](bufChain)
         let pResult = addr bcnResult
         {.emit: ["asm volatile(\"mv a3, %0\" :: \"r\"(", pResult, ") : \"a3\");"].}
         {.emit: ["asm volatile(\"mv a2, %0\" :: \"r\"(", pSta, ") : \"a2\");"].}
         {.emit: ["asm volatile(\"mv a1, %0\" :: \"r\"(", pVif, ") : \"a1\");"].}
         mm_check_beacon(pBuf)
         # ps_check_beacon ABI: (a0=resultVar, a1=rx frame length, a2=vifEntry)
         let rxFrameLen = beaconRxDescView(pBuf).frameLen
         ps_check_beacon(cast[pointer](bcnResult), rxFrameLen.uint32, pVif)
         vif_mgmt_bcn_recv(pVif)
         # Check channel context and update channel switch timing if needed.
         if postVif.chanCtxt != nil:
           chan_tbtt_switch_update(pVif, postVif.tbttTimer.expiry)
         # Also call ps_check_frame for non-retry frames (blob offset 0x406)
         if (frameCtrl and 4) == 0:
           ps_check_frame(cast[pointer](rxHdrPtr), hwFlags, pVif)

     # L55 (blob 0x3B4..0x3FA): power-save change indications for PS-flagged
     # QoS frames. Tested after the main dispatch path.
     if (frameCtrl and 0x1400) == 0x1400:
       # Blob 0x3C6: mm_ps_change_ind(staIdx, 1)
       mm_ps_change_ind(staIdx, 1)
       let pendBAPs = postVif.psBaCounter
       if pendBAPs == 0:
         # Blob 0x3DE: mm_ps_change_ind((vifHwIdx + 5) & 0xff, 1)
         let psStaIdx = cast[uint8]((tid.uint + 5'u) and 0xff'u)
         mm_ps_change_ind(psStaIdx, 1)

     # Increment VIF pending-BA counter for QoS frames (blob: L65 at 0x3E6)
     if (maskedFC and 0x8C) == 0x88:
       let postVif2 = vifChannelForIdx(sta.instNbr)
       postVif2.psBaCounter = postVif2.psBaCounter + 1

    # L52: Free RX descriptor and loop if the upper RX path did not take it.
    if releaseFrame:
      rxl_mpdu_free(queuedRxMpduDesc)

  # Unreachable exit (loop exits via return)
  ke_evt_set(0x00100000'u32)

proc rxl_cntrl_dump*() {.exportc, cdecl, noinline.} =
  ## Dump RX control state for debugging.
  ## Blob algorithm:
  ##   - Log header via g_bl_ops_funcs[204] (line 763).
  ##   - Call co_list_cnt(&rxl_cntrl_env) -> count.
  ##   - Log count with count in a5 (line 766).
  ##   - Load a6 = g_bl_ops_funcs[204] again, s0 = rxl_cntrl_env[0] (head).
  ##   - Loop: for each node: call logFn(2,0,.LC3,770, node, node->next->field[0x40]).
  ##     Specifically blob does:  a5 = *(s0+4); a6 = *(a5+0x40); jalr(a6, ...)
  ##     So the printed line is via a per-entry function pointer, not the
  ##     generic log fn. Here we emit via the general log fn for simplicity.
  ##   - Log trailer (line 774).
  let logFn = getLogFunc(204)
  if logFn == nil:
    return
  let logProc = cast[proc(a: uint32, b: uint32, c: cstring, d: uint32) {.cdecl, varargs.}](logFn)
  logProc(2, 0, "rxl_cntrl.c", 763)
  let env = rxlCntrlEnvView()
  let count = co_list_cnt(addr env.queue)
  logProc(2, 0, "rxl_cntrl.c", 766, count)
  var queuedRxDesc = env.queue.first
  while queuedRxDesc != nil:
    logProc(2, 0, "rxl_cntrl.c", 770, cast[uint32](cast[uint](queuedRxDesc)))
    queuedRxDesc = queuedRxDesc.next
  logProc(2, 0, "rxl_cntrl.c", 774)

proc rxl_dma_evt*() {.exportc, cdecl.} =
  ## RX DMA event handler.
  ## Blob (21 instrs):
  ##   a5 = g_bl_ops_funcs[204]  (dereferenced via +0xcc)
  ##   log(2, 0, .LC3="rxl_cntrl.c", 826)
  ##   ke_evt_clear(0x00400000)
  ##   *(u32*)0x24A00020 = 32  (DMA ACK register)
  ##   ret
  ## Prior Nim bug: called ke_evt_set; blob calls ke_evt_clear. This is the
  ## DMA completion handler: it runs BECAUSE the event was set, and must
  ## clear it to re-arm.
  let logFn = getLogFunc(204)
  if logFn != nil:
    cast[proc(a0: uint32, a1: uint32, a2: cstring, a3: uint32) {.cdecl.}](logFn)(2, 0, "rxl_cntrl.c", 826)
  inc nimFwDbgRxlDmaEvt
  ke_evt_clear(0x00400000'u32)
  regWrite(0x24A00020'u, 0x20'u32)

proc submittedRxReady(desc: pointer): bool {.inline.} =
  desc != nil and
    (cast[ptr RxlSubmittedDescView](desc).status and 0x4000'u32) != 0

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
  ## After processing, if PD chain exists, tail-calls ke_evt_set(0x100000).
  ## Call graph: co_list_push_back, assert_rec, rxl_hd_append, ke_evt_set
  regWrite(0x24B0807C'u, 0x000A0000'u32)
  let env = rxlCntrlEnvView()
  inc nimFwDbgRxlTimerEvt
  nimFwDbgRxlTimerHead = pointerAddrU32(env.submittedHead)
  var drained = 0'u32

  while drained < WifiRxTimerDrainLimit and submittedRxReady(env.submittedHead):
    inc nimFwDbgRxlTimerReady
    let descPtr = env.submittedHead
    let submitted = cast[ptr RxlSubmittedDescView](descPtr)
    # Dequeue: advance first to next
    let swDescLink = rxMpduDescView(submitted.swDesc)
    env.submittedHead = submitted.next
    let innerDesc = cast[ptr RxPayloadHwDescView](swDescLink.swDesc)
    swDescLink.bufferChain = cast[uint32](cast[uint](submitted.bufferChain))
    let frameLen = innerDesc.frameLen
    let payloadBufferAddr = innerDesc.bufferAddr
    if frameLen != 0:
      if payloadBufferAddr == 0:
        # Error: valid status but no buffer (blob: assert_rec line 193)
        assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 193)
      else:
        # Valid frame: push sw_desc onto rxl_cntrl_env processing list
        co_list_push_back(addr env.queue, cast[ptr CoListHdr](swDescLink))
    else:
      if payloadBufferAddr != 0:
        # Error: no status but has buffer (blob: assert_rec line 227)
        assert_rec("rxl_cntrl.c", "rxl_cntrl.c", 227)
      else:
        # Empty descriptor: clear sw_desc fields and re-append HD for reuse
        swDescLink.curDesc = nil
        swDescLink.prevDesc = nil
        rxl_hd_append(cast[pointer](innerDesc))
    inc drained

  if submittedRxReady(env.submittedHead):
    inc nimFwDbgRxTimerYield
    nimFwDbgRxTimerYieldHead = pointerAddrU32(env.submittedHead)
    rxlScheduleQueuedRx(env)
    regWrite(0x24B0807C'u, 0x000A0000'u32)
    return
  rxlScheduleQueuedRx(env)

proc rxl_timeout_int_handler*() {.exportc, cdecl.} =
  ## RX timeout interrupt handler.
  ## From blob (5 instrs): reads MACHW reg at 0x24B0808C (MACHW_BASE+0x8C),
  ## clears bit 6 (AND with ~64 = 0xFFFFFFBF), writes back; ret.
  let regAddr = MACHW_BASE + 0x8C'u
  var machwInterruptControl = volatileLoad(cast[ptr uint32](regAddr))
  machwInterruptControl = machwInterruptControl and (not 64'u32)  # clear bit 6
  volatileStore(cast[ptr uint32](regAddr), machwInterruptControl)

proc rxl_current_desc_get*(): pointer {.exportc, cdecl.} =
  ## Get current RX descriptor pointers.
  ## Blob (7 instrs): a0=outCurrent, a1=outLast (hidden arg).
  ## Stores rxl_cntrl_env[4] (offset 0x10) to *a0, rx_hwdesc_env[1] to *a1.
  var outLast {.noinit.}: ptr pointer
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", outLast, "));"].}
  # This function is called with (a0=&current, a1=&last) in the blob ABI
  # Store rxl_cntrl_env+16 to *a0 (treated as ptr in Nim return value)
  let currentDesc = rxlCntrlEnvView().currentHd
  if outLast != nil:
    outLast[] = rxHwDescEnvView().pdCurrent
  return currentDesc
