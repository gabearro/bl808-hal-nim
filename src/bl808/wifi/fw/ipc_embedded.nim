# ###########################################################################
#                  IPC Embedded (ipc_emb_*)
# ###########################################################################

proc ipc_emb_msg_push*(msgDescPtr: pointer) {.exportc, cdecl.} =
  if msgDescPtr == nil:
    return
  let msg = cast[ptr IpcEmbMsgEnvelopeView](msgDescPtr)
  let msgDesc = addr msg.desc
  let shared = cast[ptr IpcSharedMsgView](addr ipcSharedEnv[0])
  # Mirror layout used by ipc_emb_msg_evt on the receive (host→emb) side:
  #   ipc_shared_env[4..5] = id, [6] = dst, [7] = src, [8..11] = paramLen,
  #   [12..] = payload words.
  shared.id = msgDesc.id
  shared.dstId = msgDesc.dstId
  shared.srcId = msgDesc.srcId
  shared.paramLen = msgDesc.paramLen
  # Copy payload words from after the 8-byte header.
  copyIpcPayloadWords(addr shared.payload[0], addr msg.payload[0],
                      msgDesc.paramLen)
  # Raise host-side IpcIrqE2aMsgAck (= 1<<2). The chip's emb→app trigger
  # register is at 0x24800100.
  regWrite(0x24800100'u, 1'u32 shl 2)

proc ipc_emb_init*() {.exportc, cdecl.} =
  ## Initialize IPC embedded interface.
  ## From disassembly: allocates IPC env via keAllocFunc, stores result,
  ## memset(ipc_emb_env, 0, 20), stores the host TX pending list pointer at
  ## offset 12 and the host TX confirmation list pointer at offset 16.
  ## Then verifies IPC magic 0x49504332 at IPC_EMB_MAGIC_REG (asserts on mismatch),
  ## clears status registers, and configures IPC control register fields via
  ## read-modify-write sequences. Finally writes 0x1F03 to timeout register.

  # Allocate IPC environment via platform hook at g_bl_ops_funcs[0x44]
  # (zero-arg function returning a fresh IPC env block).
  let ipcAllocFn = cast[proc(): pointer {.cdecl.}](
    blOpsFunc(0x44))
  ipcEmbEnv = ipcAllocFn()

  # Clear the 20-byte ipc_emb_env struct
  discard c_memset(addr ipcEmbEnvStruct[0], 0, 20.csize_t)

  # Stash shared-memory ring-cursor pointers at offsets 12 and 16 of
  # ipc_emb_env. Blob writes &ipc_shared_env[0x24cc] and [0x24d4] here —
  # two cursor slots near the end of the shared region used by TX/msg rings.
  let env = ipcEmbEnvView()
  let shared = ipcSharedEnvView()
  env.hostTxList = addr shared.hostTxListCursor
  env.hostTxCfmList = addr shared.hostTxCfmCursor

  # Verify IPC magic value at 0x24800140
  let magic = regRead(IPC_EMB_MAGIC_REG)
  if magic != IPC_MAGIC_VALUE:
    assert_err("ipc_emb.c", "ipc_emb.c", 183)

  # Clear raw status and ack registers (0x24800114, 0x24800118)
  regWrite(IPC_EMB_RAW_STATUS, 0)
  regWrite(IPC_EMB_ACK, 0)

  # Configure IPC control register at 0x24800114 with read-modify-write
  # sequence matching blob ipc_emb_init (10 separate RMW writes, each
  # targeting a distinct 2-bit field).
  let cfgReg = IPC_EMB_RAW_STATUS  # 0x24800114
  var cfg: uint32

  # [1:0] clear
  cfg = regRead(cfgReg)
  cfg = cfg and not 0x3'u32
  regWrite(cfgReg, cfg)

  # [3:2] = 01 (clear then set bit 2)
  cfg = regRead(cfgReg)
  cfg = (cfg and not 0xC'u32) or 0x4'u32
  regWrite(cfgReg, cfg)

  # [9:8] = 10 (set bit 9)
  cfg = regRead(cfgReg)
  cfg = (cfg and not 0x300'u32) or 0x200'u32
  regWrite(cfgReg, cfg)

  # [11:10] = 10 (set bit 11)
  cfg = regRead(cfgReg)
  cfg = (cfg and not 0xC00'u32) or 0x800'u32
  regWrite(cfgReg, cfg)

  # [13:12] = 10 (set bit 13). NB: mask is 0x3000, NOT 0xF000 — blob
  # preserves bits [15:14] (an earlier bug here cleared too much).
  cfg = regRead(cfgReg)
  cfg = (cfg and not 0x3000'u32) or 0x2000'u32
  regWrite(cfgReg, cfg)

  # [17:16] = 11
  cfg = regRead(cfgReg)
  cfg = (cfg and not 0x30000'u32) or 0x30000'u32
  regWrite(cfgReg, cfg)

  # [19:18] = 11
  cfg = regRead(cfgReg)
  cfg = (cfg and not 0xC0000'u32) or 0xC0000'u32
  regWrite(cfgReg, cfg)

  # [21:20] = 11
  cfg = regRead(cfgReg)
  cfg = (cfg and not 0x300000'u32) or 0x300000'u32
  regWrite(cfgReg, cfg)

  # [23:22] = 11
  cfg = regRead(cfgReg)
  cfg = (cfg and not 0xC00000'u32) or 0xC00000'u32
  regWrite(cfgReg, cfg)

  # [25:24] = 11
  cfg = regRead(cfgReg)
  cfg = (cfg and not 0x3000000'u32) or 0x3000000'u32
  regWrite(cfgReg, cfg)

  # Write timeout value 0x1F03 to IPC_EMB_UNMASK_SET (0x2480010C)
  regWrite(IPC_EMB_UNMASK_SET, 0x1F03'u32)

proc ipc_emb_notify*(msg: uint32) {.exportc, cdecl.} =
  ## Notify host of an event via IPC (21 instrs). Blob asserts `ipcEmbEnv`
  ## non-nil, then tail-calls `g_bl_ops_funcs[0x4c](env)`. Nim previously
  ## used `keNotifyFunc` — a never-populated Nim-only global.
  let env = ipcEmbEnv
  if env == nil:
    assert_err("ipc_emb.c", "ipc_emb.c", 146)
    return
  let notifyFn = cast[proc(envArg: pointer) {.cdecl.}](
    blOpsFunc(0x4C))
  notifyFn(env)

proc ipc_emb_wait*() {.exportc, cdecl.} =
  ## Wait for IPC event from host. Blob: calls g_bl_ops_funcs[0x50] (wait fn)
  ## with (&ipcEmbEnv, -1), then `ipc_emb_counter++`.
  let waitFn = cast[proc(env: pointer, timeout: int32): int32 {.cdecl.}](
    blOpsFunc(0x50))
  if waitFn != nil:
    discard waitFn(ipcEmbEnv, -1)
  inc ipc_emb_counter

proc ipc_emb_tx_flow_off*(ac: uint8) {.exportc, cdecl.} =
  ## Stop TX flow for an AC (notify host to stop sending).
  ## Blob:
  ##   *(u32*)(0x24800000+0x110) = 0x1F00   ; IPC_EMB_UNMASK_CLR = TX mask
  ##   tail-call ke_evt_clear(0x3E00)       ; flow-off event
  ## Prior Nim bug: called ke_evt_set (would fire the event continuously).
  regWrite(IPC_EMB_UNMASK_CLR, IPC_IRQ_TX_MASK)
  ke_evt_clear(0x3E00'u32)

proc ipc_emb_tx_flow_on*(ac: uint8) {.exportc, cdecl.} =
  ## Resume TX flow for an AC.
  regWrite(IPC_EMB_UNMASK_SET, IPC_IRQ_TX_MASK)

proc ipc_emb_tx_irq*() {.exportc, cdecl.} =
  ## Handle TX IPC interrupt.
  let status = regRead(IPC_EMB_STATUS2)
  let txBits = status and IPC_IRQ_TX_MASK
  if txBits != 0:
    ke_evt_set(txBits shl 1)
    # Acknowledge
    regWrite(IPC_EMB_UNMASK_CLR, txBits)
    regWrite(IPC_EMB_ACK, txBits)

proc ipc_emb_msg_handler*() {.exportc, cdecl.} =
  ## IPC message handler callback (stored in ipc_emb_env[3] during ipc_emb_init).
  ## Processes incoming messages from host via IPC shared memory.
  discard

proc ipc_emb_tx_evt*(ac: uint32) {.exportc, cdecl.} =
  ## Process TX IPC event for a specific AC (288 bytes in blob, 97 instrs).
  ## From blob: extracts AC index from custom insn on ac, validates non-zero
  ## with debug log. Calls txl_cntrl_env_get(ac). Iterates descriptor list
  ## from ipc_emb_env[12], for each: checks BCN flag (bit 13) and flow control.
  ## Sets up DMA pointers, clears status fields, inits confirm list, marks active.
  ## Advances list. On empty: acks IPC. On flow control: tail-calls backup handler.
  let env = ipcEmbEnvView()
  # Blob: custom insn extracts AC index, then log if non-zero
  if ac != 0:
    let logFn = getLogFunc(0xCC)
    if logFn != nil:
      cast[proc(a0, a1: uint32, file: pointer, line: uint32,
                file2: pointer, val: uint32) {.cdecl.}](logFn)(
        2, 0, nil, 290, nil, ac)
  # Event bits for host TX AC0..AC4 are 0x200..0x2000. The handler table passes
  # the AC number; blob expands it to the event mask before clearing/re-arming.
  let eventMask = 0x200'u32 shl ac
  ke_evt_clear(eventMask)
  # Load descriptor list and BCN flag
  let isBcn = (eventMask and 0x2000'u32) != 0
  # Deref list head -> first descriptor
  var wrapper = ipcHostTxHead(env)
  nimFwTrace2U32("[WIFI-NIMFW] ipc_tx_evt ", ac, pointerAddrU32(cast[pointer](wrapper)))
  var drained = 0'u32
  while drained < WifiIpcTxDrainLimit and wrapper != nil:
    let txDesc = addr wrapper.txDesc
    let ethTypeTrace = txDesc.frameLen
    let pktLenTrace = txDesc.seqPassthrough
    let traceIpc = nimFwDbgIpcTxTraceCount < 16'u32 or
      ethTypeTrace == 0x8E88'u16 or ethTypeTrace == 0x888E'u16
    if traceIpc:
      let tidTrace = txDesc.staIdx.uint32
      let vifTrace = txDesc.vifIdx.uint32
      let staTrace = txDesc.staInfoIdx.uint32
      nimFwTrace2U32("[WIFI-NIMFW] ipc_txd ",
                     ethTypeTrace.uint32 or (pktLenTrace.uint32 shl 16),
                     tidTrace or (vifTrace shl 8) or (staTrace shl 16))
      nimFwTrace2U32("[WIFI-NIMFW] ipc_txd_buf ",
                     txDesc.bufferPtrs[0],
                     txDesc.bufferLens[0])
      inc nimFwDbgIpcTxTraceCount
    # Flow control check for non-BCN queues (blob: .L21 at 0xa2)
    if not isBcn:
      let keEvtFld = cast[ptr uint32](cast[uint](addr keEvtField))[]
      if (keEvtFld and 0x02102000'u32) != 0:
        # Flow control active: re-arm event and return (blob: tail-call ke_evt_set)
        ke_evt_set(eventMask)
        return
    # Write IPC TX status acknowledgement (blob: sw s7,264(s6) at 0xd0)
    volatileStore(cast[ptr uint32](0x24800108'u), 256'u32)
    # Set up DMA descriptor chain fields (blob at 0xd4-0xe2)
    txDesc.aggDescPtr = cast[uint32](cast[uint](addr txDesc.aggDescStorage[0]))
    txDesc.hwDesc = cast[pointer](addr txDesc.aggDescPtr)
    # Clear status fields (blob at 0xe2-0xf6)
    txDesc.policy = nil
    txDesc.dmaLink = nil
    txDesc.cfmStatus = 0
    txDesc.retryCount = 0
    txDesc.lifetime = 0
    txDesc.txFlags = 0
    # CRITICAL: Push descriptor to TX queue via txu_cntrl_push (blob at 0x100).
    # The blob explicitly loads a1=0 before this call; txu_cntrl_push reads a1
    # as the access-category argument even though the C ABI only exposes a0.
    let txParam = cast[pointer](txDesc)
    {.emit: ["asm volatile(\"mv a1, zero\" ::: \"a1\", \"memory\");"].}
    txu_cntrl_push(txParam)
    # Mark descriptor as active (blob: sw s8,8(s0) where s8=1)
    wrapper.active = 1
    # Pop from IPC list (blob: utils_list_pop_front at 0x110)
    discard utils_list_pop_front(env.hostTxList)
    # Reload and loop
    wrapper = ipcHostTxHead(env)
    inc drained
  if wrapper != nil:
    inc nimFwDbgIpcTxYield
    nimFwDbgIpcTxYieldAc = ac
    nimFwDbgIpcTxYieldHead = pointerAddrU32(cast[pointer](wrapper))
    ke_evt_set(eventMask)
    return
  # No more descriptors: write 256 to IPC completion register (blob at 0x86)
  volatileStore(cast[ptr uint32](0x2480010C'u), 256'u32)

proc ipc_emb_cfmback_irq*() {.exportc, cdecl.} =
  ## Handle CFM (confirmation) back IPC interrupt.
  ## From disassembly (29 instrs): reads IPC_EMB_STATUS2 (0x11C), checks bit 5
  ## (RX cfm) and bit 4 (TX cfm). For each set bit, writes to UNMASK_CLR
  ## (0x110) and ACK (0x108), then signals the appropriate kernel event.
  let status = regRead(IPC_EMB_STATUS2)
  if (status and 0x20) != 0:
    # RX confirmation back: write 32 to UNMASK_CLR then ACK
    regWrite(IPC_EMB_UNMASK_CLR, 32)
    regWrite(IPC_REG_BASE + 0x108'u, 32)  # blob: sw a4, 0x108(base)
    ke_evt_set(0x00100000'u32)
  if (status and 0x10) != 0:
    # TX confirmation back: write 16 to UNMASK_CLR then ACK
    regWrite(IPC_EMB_UNMASK_CLR, 16)
    regWrite(IPC_REG_BASE + 0x108'u, 16)
    ke_evt_set(0x00200000'u32)

proc ipc_emb_hostrxdesc_check*(): bool {.exportc, cdecl.} =
  ## Check if host has provided RX descriptors.
  return true

proc ipc_emb_msg_irq*() {.exportc, cdecl.} =
  ## Handle message IPC interrupt (host -> emb).
  ## From disassembly (16 instrs): reads IPC_EMB_STATUS2 (offset 0x11C), checks
  ## bit 1 (msg pending). If set, calls ke_evt_set(0x10000000) to schedule
  ## message processing, then writes 2 to offset 0x110 to acknowledge.
  let status = regRead(IPC_EMB_STATUS2)
  if (status and 2) != 0:
    ke_evt_set(0x10000000'u32)
    regWrite(IPC_EMB_UNMASK_CLR, 2)  # blob: sw 2, 0x110(base)

proc ipcMessagePending(status: uint32, msgBit: uint32): bool {.inline.} =
  (status and msgBit) != 0

proc ipc_emb_msg_evt*() {.exportc, cdecl.} =
  ## Process IPC message event. Blob semantics (from ipc_emb_msg_evt disassembly,
  ## 101 instrs). Host writes the message into `ipc_shared_env` (offsets
  ## 4=msgId, 6=msgDst, 8=paramLen, 12+=payload) then asserts IPC_MSG_BIT
  ## in the status register. This embedded-side handler drains all pending
  ## messages: for each, allocates a ke_msg of size (paramLen+12) via the
  ## platform allocator at g_bl_ops_funcs[184], copies the metadata+payload
  ## into it, increments the per-message counter, validates the dest task id,
  ## signals the MACHW event, and dispatches via ke_msg_send.
  const
    IPC_MSG_BIT = 2'u32  # bit 1 in IPC status for messages
  let shared = cast[ptr IpcSharedMsgView](addr ipcSharedEnv[0])
  let env = ipcEmbEnvView()
  var ipcStatus = regRead(0x24800104'u)
  var drained = 0'u32
  while drained < WifiIpcMsgDrainLimit and ipcMessagePending(ipcStatus, IPC_MSG_BIT):
    nimFwTrace("[WIFI-NIMFW] ipc_emb_msg_evt msg")
    # Ack the msg bit (0x24800108) before processing.
    regWrite(0x24800108'u, IPC_MSG_BIT)
    # Read message metadata directly from ipc_shared_env (NOT via a pointer).
    let msgId = shared.id
    let msgDst = shared.dstId
    let msgParamLen = shared.paramLen
    # Platform allocator at g_bl_ops_funcs[184]: takes total byte count
    # (paramLen + sizeof(KeMsgHdr) for the ke_msg_hdr prefix), returns the new header.
    # Blob: `lw a5, 184(s6); addi a0, a0, 12; jalr a5` with a0 = paramLen.
    let allocFn = cast[proc(sz: uint32): pointer {.cdecl.}](
      blOpsFunc(184))
    let hdrRaw = allocFn(msgParamLen + KeMsgHdrSize.uint32)
    if hdrRaw == nil:
      assert_err("ipc_emb.c", "ipc_emb.c", 0x1E3)
    let hdr = cast[ptr KeMsgHdr](hdrRaw)
    # Fill the newly-allocated header fields: link ptr = 0, msgId, msgDst,
    # srcId = 9 (TASK_API), paramLen.
    hdr.next = nil
    hdr.id = msgId
    hdr.destId = msgDst
    hdr.srcId = 9
    hdr.paramLen = msgParamLen
    # Copy payload word-by-word from ipc_shared_env+12 into the typed ke_msg
    # payload area, matching the vendor IPC word-copy behavior.
    copyIpcPayloadWords(keMsgPayload(hdr), addr shared.payload[0], msgParamLen)
    # Advance per-message counter (stored at ipc_emb_env[0]) and stamp it
    # into the srcId-adjacent slot at ipc_shared_env[7].
    let counter = env.counter
    shared.srcId = counter
    env.counter = counter + 1
    # Validate destination task id (blob: two chained assertions; msgDst
    # must be in [0, 8]; > 10 asserts at line 127, > 8 asserts at line 503).
    let dstCheck = hdr.destId
    if dstCheck > 10:
      assert_err("ipc_emb.c", "ipc_emb.c", 0x7F)
    if dstCheck > 8:
      assert_err("ipc_emb.c", "ipc_emb.c", 0x1F7)
    # Signal the MACHW event (write 4 to 0x24800100) then dispatch.
    regWrite(0x24800100'u, 4'u32)
    ke_msg_send(keMsgPayload(hdr))
    nimFwTrace("[WIFI-NIMFW] ipc_emb_msg_evt dispatched")
    # Re-read IPC status for next iteration (blob: `lw a5, 260(s2); j .L49`).
    inc drained
    ipcStatus = regRead(0x24800104'u)

  if ipcMessagePending(ipcStatus, IPC_MSG_BIT):
    inc nimFwDbgIpcMsgYield
    nimFwDbgIpcMsgYieldStatus = ipcStatus
    return

  # No more messages: clear the kernel event, re-enable MSG IRQ, return.
  # Blob calls ke_evt_clear only when exiting, not at entry.
  ke_evt_clear(0x10000000'u32)
  regWrite(IPC_EMB_UNMASK_SET, IPC_MSG_BIT)

proc ipc_emb_radar_event_ind*() {.exportc, cdecl.} =
  ## Handle radar event indication.
  ## From blob (4 instrs): writes 64 (0x40) to IPC_EMB_STATUS_REG (0x24800100).
  volatileStore(cast[ptr uint32](IPC_EMB_STATUS_REG), 64'u32)

proc ipc_emb_txcfm*(desc: pointer) {.exportc, cdecl.} =
  ## Handle TX confirmation from IPC.
  ## From blob (5 instrs): a1 = desc - 12, loads ipc_emb_env[16] into a0,
  ## tail-calls utils_list_push_back(host_tx_cfm_list, desc-12). The element is
  ## the host wrapper node, not a lower-MAC txl_cfm_env descriptor.
  let wrapper = ipcHostTxWrapperFromDesc(hostTxDescAt(desc))
  let env = ipcEmbEnvView()
  utils_list_push_back(env.hostTxCfmList, addr wrapper.link)

proc ipc_emb_txcfm_ind*(acBit: uint32 = 0) {.exportc, cdecl, noinline.} =
  ## TX confirmation indication to host.
  ## From blob (4 instrs): slli a0,a0,7; writes a0 to IPC_EMB_STATUS_REG (0x24800100); ret.
  ## acBit is shifted left 7 to form the IPC TX confirm bit, then written to status reg.
  let txConfirmStatusBit = acBit shl 7
  volatileStore(cast[ptr uint32](IPC_EMB_STATUS_REG), txConfirmStatusBit)

proc ipc_emb_prim_tbtt_ind*() {.exportc, cdecl.} =
  ## Primary TBTT indication to host — 4 instrs in blob:
  ##   lui a5, 0x24800; li a4, 16; sw a4, 256(a5); ret
  ## i.e. a bare `*(u32*)0x24800100 = 0x10`. Previous Nim routed through
  ## `ipc_emb_notify(IPC_IRQ_TBTT)` which dispatches to a platform callback
  ## — completely different behaviour (callback instead of HW register).
  volatileStore(cast[ptr uint32](IPC_EMB_STATUS_REG), 16'u32)

proc ipc_emb_sec_tbtt_ind*() {.exportc, cdecl.} =
  ## Secondary TBTT indication to host.
  ## From blob (4 instrs): writes 32 (0x20) to IPC_EMB_STATUS_REG (0x24800100); ret.
  volatileStore(cast[ptr uint32](IPC_EMB_STATUS_REG), 32'u32)

proc ipc_emb_dump*() {.exportc, cdecl, noinline.} =
  ## Dump IPC state for debugging.
  ## noinline + asm barrier: blob calls this as a real function from
  ## bl_fw_statistic_dump; without the barrier GCC elides the call of an
  ## empty, side-effect-free proc.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
