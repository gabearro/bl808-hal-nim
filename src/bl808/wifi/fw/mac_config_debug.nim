# ###########################################################################
#                  MAC Utilities
# ###########################################################################

proc mac_ie_find*(buf: pointer, bufLen: uint32, ieId: uint8): pointer {.exportc, cdecl.} =
  ## Find an Information Element by ID in a buffer.
  ## From blob (11 instrs): a1 = a0 + a1 (end = buf + bufLen), loop:
  ##   bltu a0, a1 => if pos < end, check IE
  ##   lbu a5, 0(a0) => id; beq a5, a2 => return pos if match
  ##   lbu a5, 1(a0); addi a5, 2; add a0, a5 => advance past IE
  ## Returns pointer to matching IE header, or nil if not found.
  if buf == nil:
    return nil
  var pos = cast[uint](buf)
  var remaining = bufLen.uint
  while remaining >= 2:
    let ie = macIeAt(pos)
    let length = ie.totalLen
    if length > remaining:
      return nil
    if ie.id == ieId:
      return cast[pointer](pos)
    pos += length
    remaining -= length
  return nil

proc mac_vsie_find*(buf: pointer, bufLen: uint32, oui: pointer, ouiLen: uint8): pointer {.exportc, cdecl.} =
  ## Find a vendor-specific IE by OUI (33 instructions in blob).
  ## From blob: a1 = buf + bufLen (end), a4 = 0xDD, a2 decremented by 1
  ## (oui adjusted for indexed load trick).
  ## Loop .L6: bltu pos, end => check IE; beq pos, end => return nil;
  ##   pos > end => call assert, return nil.
  ## .L11: lbu id; bne id, 0xDD => skip to .L7. Else a6 = pos+2 (IE body),
  ##   compare ouiLen bytes using indexed loads. Match => return pos.
  ## .L7: lbu len, 1(pos); pos += len + 2; loop back.
  if buf == nil or (oui == nil and ouiLen != 0):
    return nil
  var pos = cast[uint](buf)
  var remaining = bufLen.uint
  let targetOuiBytes = cast[ptr UncheckedArray[uint8]](oui)
  while remaining >= 2:
    let ie = macIeAt(pos)
    let size = ie.totalLen
    if size > remaining:
      return nil
    if ie.id == 0xDD'u8 and ie.len >= ouiLen:
      # Vendor-specific IE found, compare OUI bytes
      let vendorIePayload = ie.macIePayload
      var match = true
      for ouiByteIndex in 0'u8 ..< ouiLen:
        if vendorIePayload[ouiByteIndex] != targetOuiBytes[ouiByteIndex]:
          match = false
          break
      if match:
        return cast[pointer](pos)
    pos += size
    remaining -= size
  # Blob never calls assert on overrun here (0 asserts in its call graph);
  # returning nil is the only outcome for "not found / past end".
  return nil

proc mac_irq*() {.exportc, cdecl.} =
  ## MAC interrupt handler (30 instrs in blob).
  ## Reads MAC platform IRQ status registers. If both zero (spurious), returns.
  ## Otherwise reads handler index from MAC_PL_IRQ_HANDLER, looks up the ISR
  ## in the intc_handler_tab, asserts if NULL, calls it, then tail-calls
  ## bl_irq_handler.
  let status0 = regRead(MAC_PL_IRQ_STATUS0)
  if status0 == 0:
    let status1 = regRead(MAC_PL_IRQ_STATUS1)
    if status1 == 0:
      return  # spurious -- both status regs zero
  # Read IRQ handler index
  let irqIdx = regRead(MAC_PL_IRQ_HANDLER)
  let irqSlot = irqIdx and 0x3F'u32
  let status1 = regRead(MAC_PL_IRQ_STATUS1)
  inc nimFwDbgMacIrq
  nimFwDbgMacIrqLast = irqSlot or (status0 shl 8) or (status1 shl 16)
  nimFwDbgMacIrqLastHandler = irqIdx
  nimFwDbgMacIrqLastIntRaw = regRead(MACHW_INTC_STATUS_RAW)
  nimFwDbgMacIrqLastGenRaw = regRead(MACHW_INTC_GEN_RAW)
  nimFwDbgMacIrqLastRxCtrl = regRead(MACHW_RX_CNTRL_REG)
  nimFwDbgMacIrqLastHd = machwRxHdSubmittedHead()
  nimFwDbgMacIrqLastPd = machwRxPdSubmittedHead()
  case irqSlot
  of 50'u32:
    inc nimFwDbgMacIrqSlot50
  of 52'u32:
    inc nimFwDbgMacIrqSlot52
  of 53'u32:
    inc nimFwDbgMacIrqSlot53
  of 54'u32:
    inc nimFwDbgMacIrqSlot54
  else:
    inc nimFwDbgMacIrqSlotOther
  if irqSlot == 53'u32 or irqSlot == 54'u32:
    nimFwTrace2U32("[WIFI-NIMFW] macirq_tx ",
                   irqSlot or (status0 shl 8),
                   status1)
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] macirq_tx ",
                            irqSlot or (status0 shl 8),
                            status1)
  let handler = cast[proc() {.cdecl.}](intc_handler_tab[irqIdx and 0x3F])
  if handler == nil:
    assert_err("intc.c", "intc.c", 154)
  else:
    handler()
  ipc_emb_notify(0)  # blob: ipc_emb_notify (not bl_irq_handler)

proc mac_paid_gid_sta_compute*(bssid: pointer): uint32 {.exportc, cdecl.} =
  ## Compute Partial AID and Group ID for STA (7 instructions in blob).
  ## From blob: lbu a5, 4(a0); lbu a0, 5(a0); andi a5, 128;
  ##   slli a0, 1; or a0, a5; slli a0, 22; ret.
  ## Extracts bytes 4-5 of BSSID, combines and shifts into PAID/GID format.
  let bssidBytes = cast[ptr UncheckedArray[uint8]](bssid)
  let bssidOctet4Msb = bssidBytes[4].uint32 and 0x80'u32
  let bssidOctet5ForPartialAid = bssidBytes[5].uint32
  result = ((bssidOctet5ForPartialAid shl 1) or bssidOctet4Msb) shl 22

proc mac_paid_gid_ap_compute*(bssid: pointer, aid: uint16): uint32 {.exportc, cdecl.} =
  ## Compute Partial AID and Group ID for AP (13 instructions in blob).
  ## From blob: lbu a5, 5(a0) => octet 5 of BSSID
  ##   andi a1, 511 => partialAID = aid & 0x1FF
  ##   srai a0, a5, 4 => upperNibble = bssid octet 5 >> 4
  ##   xor a0, a0, a5 => mixed = upperNibble ^ bssid octet 5
  ##   slli a0, 5 => mixed <<= 5
  ##   andi a0, 480 => mixed &= 0x1E0 (5-bit field in bits 8:5)
  ##   add a0, a1 => combined = mixed + partialAID
  ##   lui a5, 0x7FC00; slli a0, 22; and a0, a5 => PAID field in bits 30:22
  ##   lui a5, 0x3F0; or a0, a5 => set GID=0x3F (broadcast) in bits 21:16
  let bssidBytes = cast[ptr UncheckedArray[uint8]](bssid)
  let bssidOctet5ForPartialAid = bssidBytes[5].uint32
  let partialAid = aid.uint32 and 0x1FF'u32
  let bssidOctet5UpperNibble = bssidOctet5ForPartialAid shr 4
  var bssidMixedAidBits =
    (bssidOctet5UpperNibble xor bssidOctet5ForPartialAid) shl 5
  bssidMixedAidBits = bssidMixedAidBits and 0x1E0'u32
  let combined = bssidMixedAidBits + partialAid
  let paidField = (combined shl 22) and 0x7FC00000'u32
  result = paidField or 0x003F0000'u32  # GID = 63 (broadcast)

# ###########################################################################
#                  EDCA / Configuration
# ###########################################################################

proc bl60x_edca_get*(ac: cint, aifs: ptr uint8, cwmin: ptr uint8, cwmax: ptr uint8, txop: ptr uint16): cint {.exportc, cdecl.} =
  ## Get EDCA parameters for an access category (43 instrs in blob).
  ## Reads HW EDCA register for the given AC from MACHW_BASE + 0x200..0x20C.
  ## Register format: bits[3:0]=AIFS, bits[7:4]=CW_MIN, bits[11:8]=CW_MAX,
  ## bits[31:12]=TXOP.
  var regAddr: uint
  case ac
  of 0: regAddr = MACHW_EDCA_AC_BK_REG  # AC_BK
  of 1: regAddr = MACHW_EDCA_AC_BE_REG  # AC_BE
  of 2: regAddr = MACHW_EDCA_AC_VI_REG  # AC_VI
  of 3: regAddr = MACHW_EDCA_AC_VO_REG  # AC_VO
  else: return -1
  let edcaParamWord = regRead(regAddr)
  aifs[] = (edcaParamWord and 0xF).uint8             # bits [3:0]
  cwmin[] = ((edcaParamWord shr 4) and 0xF).uint8    # bits [7:4]
  cwmax[] = ((edcaParamWord shr 8) and 0xF).uint8    # bits [11:8]
  txop[] = (edcaParamWord shr 12).uint16             # bits [31:12]
  return 0

proc bl60x_firmwre_mpdu_free*(param: pointer) {.exportc, cdecl.} =
  ## Debit the host-retained descriptor count, then recycle that same frame.
  let captureIrq = irqSave()
  let header = rxMpduHeader(param)
  if header == nil or header.uploadDone == 0:
    irqRestore(captureIrq)
    return
  let generation = rxUploadGeneration(param)
  let descCount = rxMpduDescView(param).descCount
  let enterFn = cast[proc(): uint32 {.cdecl.}](blOpsFunc(20))
  let leaveFn = cast[proc(level: uint32) {.cdecl.}](blOpsFunc(24))
  irqRestore(captureIrq)
  if enterFn == nil or leaveFn == nil:
    assert_rec("rxl_cntrl.c", "RX release callbacks", 0)
    return
  template current(): bool =
    rxUploadCurrent(param, generation) and rxMpduHeader(param) == header and
      rxMpduDescView(param).descCount == descCount
  let savedStatus = enterFn()
  var invalidCount = false
  try:
    if not current() or header.uploadDone == 0: return
    let rx = rxlCntrlEnvView()
    if descCount == 0 or rx.uploadCount < descCount.uint32:
      invalidCount = true
    else:
      rx.uploadCount -= descCount.uint32
      # Claim the release before the exit callback can reenter this API.
      header.uploadDone = 0
  finally:
    leaveFn(savedStatus)
  if invalidCount:
    if current(): assert_rec("rxl_cntrl.c", "RX release count", 0)
    return
  let releaseIrq = irqSave()
  defer: irqRestore(releaseIrq)
  if current() and header.uploadDone == 0:
    rxReleaseUpload(param, generation)

# ###########################################################################
#                  Notifier Chain
# ###########################################################################

proc notifier_chain_insert_ordered(headPtr: ptr pointer, notifier: ptr CoListHdr) =
  ## Insert a notifier into a singly-linked list ordered by priority (offset 8).
  ## Blob notifier block layout:
  ##   offset 0: callback function pointer
  ##   offset 4: next pointer (singly-linked)
  ##   offset 8: priority (int32, higher = inserted earlier)
  ## From blob: walks list via offset 4, compares int32 at offset 8.
  ## Inserts before the first node whose priority < new node's priority.
  let newNode = notifierNodeView(notifier)
  let newPrio = newNode.priority
  var linkSlot = headPtr
  var currentNotifier = cast[ptr CoListHdr](linkSlot[])
  while currentNotifier != nil:
    let currentNode = notifierNodeView(currentNotifier)
    let currentPriority = currentNode.priority
    if currentPriority < newPrio:
      # Insert notifier before currentNotifier
      newNode.next = cast[pointer](currentNotifier)
      linkSlot[] = cast[pointer](notifier)
      return
    # Advance: linkSlot = &currentNotifier->next (offset 4)
    linkSlot = addr currentNode.next
    currentNotifier = cast[ptr CoListHdr](linkSlot[])
  # End of list or empty: insert here
  newNode.next = nil
  linkSlot[] = cast[pointer](notifier)

proc notifier_chain_remove(headPtr: ptr pointer, notifier: ptr CoListHdr) =
  ## Remove a notifier from a singly-linked list by pointer match.
  ## From blob: walks list via offset 4 (next), compares pointer,
  ## unlinks by setting prev->next = node->next.
  var linkSlot = headPtr
  var currentNotifier = cast[ptr CoListHdr](linkSlot[])
  while currentNotifier != nil:
    if currentNotifier == notifier:
      # Unlink: *linkSlot = notifier->next
      linkSlot[] = notifierNodeView(notifier).next
      return
    linkSlot = addr notifierNodeView(currentNotifier).next
    currentNotifier = cast[ptr CoListHdr](linkSlot[])

proc notifier_chain_regsiter*(chain: ptr CoList, notifier: ptr CoListHdr) {.exportc, cdecl.} =
  ## Register notifier with irqSave (64 bytes in blob, 30 instrs).
  ## From blob: irqSave, inline priority-ordered insert, irqRestore, return 0.
  let saved = irqSave()
  notifier_chain_insert_ordered(cast[ptr pointer](addr chain.first), notifier)
  irqRestore(saved)

proc notifier_chain_regsiter_fromCritical*(chain: ptr CoList, notifier: ptr CoListHdr) {.exportc, cdecl.} =
  ## Register notifier from critical section (26 bytes in blob).
  ## From blob: inline priority-ordered insert into singly-linked list.
  notifier_chain_insert_ordered(cast[ptr pointer](addr chain.first), notifier)

proc notifier_chain_unregsiter*(chain: ptr CoList, notifier: ptr CoListHdr) {.exportc, cdecl.} =
  ## Unregister notifier with irqSave (62 bytes in blob, 29 instrs).
  ## From blob: irqSave, inline walk singly-linked list, unlink, irqRestore, return 0.
  let saved = irqSave()
  notifier_chain_remove(cast[ptr pointer](addr chain.first), notifier)
  irqRestore(saved)

proc notifier_chain_unregsiter_fromCritical*(chain: ptr CoList, notifier: ptr CoListHdr) {.exportc, cdecl.} =
  ## Unregister notifier from critical section (22 bytes in blob).
  ## From blob: inline walk singly-linked list, find and unlink matching node.
  notifier_chain_remove(cast[ptr pointer](addr chain.first), notifier)

proc notifier_chain_call*(chain: ptr CoList, event: uint32, data: pointer) {.exportc, cdecl.} =
  ## Call all notifiers in the chain.
  ## From blob (36 instrs): irqSave, s0 = chain.first, for each node:
  ##   lw a5, 0(s0) => callback at offset 0
  ##   jalr a5(s0, s3=event, s4=data) => callback(node, event, data)
  ##   s0 = s0[4] => observe the next link after the callback
  ## irqRestore, return 0.
  let saved = irqSave()
  var currentNotifier = chain.first
  while currentNotifier != nil:
    let notifierNode = notifierNodeView(currentNotifier)
    let callback = cast[proc(node: ptr CoListHdr, event: uint32, data: pointer): cint {.cdecl.}](
      notifierNode.callback
    )
    if callback != nil:
      discard callback(currentNotifier, event, data)
    currentNotifier = cast[ptr CoListHdr](notifierNode.next)
  irqRestore(saved)

proc notifier_chain_call_fromeCritical*(chain: ptr CoList, event: uint32, data: pointer) {.exportc, cdecl.} =
  ## Call notifiers from critical section (no irqSave/irqRestore).
  ## From blob (23 instrs): s0 = chain.first, for each node:
  ##   lw a5, 0(s0) => callback, call callback(node, event, data),
  ##   lw s0, 4(s0) => next. No interrupt manipulation.
  var currentNotifier = chain.first
  while currentNotifier != nil:
    let notifierNode = notifierNodeView(currentNotifier)
    let callback = cast[proc(node: ptr CoListHdr, event: uint32, data: pointer): cint {.cdecl.}](
      notifierNode.callback
    )
    if callback != nil:
      discard callback(currentNotifier, event, data)
    currentNotifier = cast[ptr CoListHdr](notifierNode.next)

# ###########################################################################
#                  Replay Counter
# ###########################################################################

proc replay_counter_validate*(param: pointer; received: uint64): bool {.exportc, cdecl.} =
  ## Vendor replay window: a next-PN counter and two rotating 32-bit bitmaps.
  ## Accept unseen PNs up to 32 behind the highest received PN.
  let state = replayCounterStateView(param)
  let last = (state.pnHigh.uint64 shl 32) or state.pnLow.uint64
  if received + 33'u64 < last:
    return false

  let nextPn = received + 1'u64
  # WEXTI in the vendor returns the low 32 bits of each shifted counter.
  let index = ((nextPn shr 5) and 0xFFFFFFFF'u64).uint32
  if nextPn > last:
    let currentIndex = ((last shr 5) and 0xFFFFFFFF'u64).uint32
    if index != currentIndex:
      state.bitmap[((currentIndex + 1'u32) and 1'u32).int] = 0
      if currentIndex != index - 1'u32:
        state.bitmap[(currentIndex and 1'u32).int] = 0
    state.pnLow = (nextPn and 0xFFFFFFFF'u64).uint32
    state.pnHigh = (nextPn shr 32).uint32

  let slot = (index and 1'u32).int
  let bit = 1'u32 shl (nextPn and 31'u64).int
  if (state.bitmap[slot] and bit) != 0:
    return false
  state.bitmap[slot] = state.bitmap[slot] or bit
  return true

# ###########################################################################
#                  Assert Handlers
# ###########################################################################

type ArchAssertLogFn = proc(level: uint32; tag, file: cstring; line: cint;
                            format: cstring) {.cdecl, varargs.}

proc logAssertMacStatus(sourceLine: cint; address: uint; format: cstring) =
  let first = regRead(address)
  let second = regRead(address + 4)
  let third = regRead(address + 8)
  let fourth = regRead(address + 12)
  let logFn = cast[ArchAssertLogFn](blOpsFunc(204))
  if logFn != nil:
    logFn(2, nil, "arch_main.c", sourceLine, format,
          first.culong, second.culong, third.culong, fourth.culong)

proc assert_err*(cond: cstring, file: cstring, line: cint) {.exportc, cdecl.} =
  ## Fatal assertion handler (244 bytes in blob, 75 instrs).
  ## Blob ABI: (a0=cond_or_func, a1=source_file, a2=line_number).
  ## Reloads logFn before each of 6 calls. The blob hangs forever after
  ## logging; the pure Nim path records diagnostics and raises the firmware
  ## reset event so CPS/coexistence service loops remain able to run.
  noteAssertErr(file, line)
  # Direct-UART trace so we can see which assert fired even when nimFwTrace
  # is compiled out and the blob logFn is char-write-blind.
  {.emit: """
  extern void cfg_trace_rc(char *s, int v);
  extern void cfg_trace(char *s);
  cfg_trace("[NIMFW-ASSERT] file=");
  cfg_trace(`file` ? `file` : "(null)");
  cfg_trace_rc(" line=", `line`);
  cfg_trace("[NIMFW-ASSERT] cond=");
  cfg_trace(`cond` ? `cond` : "(null)");
  cfg_trace("\r\n");
  """.}
  var traceBuf: array[96, char]
  let name = if file != nil: file else: cond
  if name != nil:
    discard c_snprintf(addr traceBuf[0], traceBuf.len.csize_t,
                       "[WIFI-NIMFW] assert %s:%d", name, line)
  else:
    discard c_snprintf(addr traceBuf[0], traceBuf.len.csize_t,
                       "[WIFI-NIMFW] assert line %d", line)
  nimFwTrace(cast[cstring](addr traceBuf[0]))
  nimFwTraceU32("[WIFI-NIMFW] assert line ", cast[uint32](line))
  let condition = if cond != nil: cond else: cstring("(null)")
  let sourceFile = if file != nil: file else: cstring("(null)")
  # Call 1: condition/function name
  let logFn1 = cast[ArchAssertLogFn](blOpsFunc(204))
  if logFn1 != nil:
    logFn1(2, nil, "arch_main.c", 148, "[CON Err] %s\r\n", condition)
  # Call 2: source file
  let logFn2 = cast[ArchAssertLogFn](blOpsFunc(204))
  if logFn2 != nil:
    logFn2(2, nil, "arch_main.c", 149, "[file] %s\r\n", sourceFile)
  # Call 3: source line number
  let logFn3 = cast[ArchAssertLogFn](blOpsFunc(204))
  if logFn3 != nil:
    logFn3(2, nil, "arch_main.c", 150, "[line] %d\r\n", line)
  # Call 4: status
  let logFn4 = cast[ArchAssertLogFn](blOpsFunc(204))
  if logFn4 != nil:
    logFn4(2, nil, "arch_main.c", 151, "[MAC] [STATUS] [DUMP]\r\n")
  # The reference labels retain the legacy alias; reads use the BL808 bank.
  logAssertMacStatus(152, MACHW_INTC_BASE + 0x188,
                     "    0x44B08188 %08lX %08lx %08lx %08lx\r\n")
  logAssertMacStatus(158, MACHW_INTC_BASE + 0x198,
                     "    0x44B08198 %08lX %08lx %08lx %08lx\r\n")
  let saved = irqSave()
  hal_machw_disable_int()
  ke_evt_set(0x80000000'u32)
  irqRestore(saved)

proc assert_rec*(cond: cstring, file: cstring, line: cint) {.exportc, cdecl.} =
  ## Recoverable assertion handler (248 bytes in blob, 79 instrs).
  ## Blob ABI: (a0=cond_or_func_name, a1=source_file, a2=line_number).
  ## The vendor's relocated table base + 0x80 and load + 0x4C select slot 204.
  ## It logs the MAC status, prints recovery text, then requests one reset.
  let condition = if cond != nil: cond else: cstring("(null)")
  let sourceFile = if file != nil: file else: cstring("(null)")
  let logFn1 = cast[ArchAssertLogFn](blOpsFunc(204))
  if logFn1 != nil:
    logFn1(2, nil, "arch_main.c", 86, "[CON REC] %s,%s,%d\r\n",
           condition, sourceFile, line)
  let logFn2 = cast[ArchAssertLogFn](blOpsFunc(204))
  if logFn2 != nil:
    logFn2(2, nil, "arch_main.c", 87, "[MAC] [STATUS] [DUMP]\r\n")
  logAssertMacStatus(88, MACHW_INTC_BASE + 0x188,
                     "    0x44B08188 %08lX %08lx %08lx %08lx\r\n")
  logAssertMacStatus(94, MACHW_INTC_BASE + 0x198,
                     "    0x44B08198 %08lX %08lx %08lx %08lx\r\n")
  nimFwTrace2U32("[WIFI-NIMFW] assert_rec ",
                 cast[uint32](line),
                 cast[uint32](cast[uint](file)))
  let printFn = blOpsFunc(4)
  if printFn != nil:
    cast[proc(format: cstring) {.cdecl, varargs.}](printFn)("Recovery MAC...\r\n")
  # Check if reset already pending; if not, trigger reset
  let saved = irqSave()
  if (cast[int32](keEvtField) >= 0):  # bit 31 not set
    # Blob calls hal_machw_disable_int (no arg) before raising the event
    hal_machw_disable_int()
    ke_evt_set(0x80000000'u32)
  irqRestore(saved)

proc assert_warn*(cond: cstring, file: cstring, line: cint) {.exportc, cdecl.} =
  ## Warning assertion handler (128 bytes in blob, ~38 instrs).
  ## Blob ABI: (a0=cond_or_func, a1=source_file, a2=line_number).
  let condition = if cond != nil: cond else: cstring("(null)")
  let sourceFile = if file != nil: file else: cstring("(null)")
  let logFn = cast[ArchAssertLogFn](blOpsFunc(204))
  if logFn != nil:
    logFn(2, nil, "arch_main.c", 179, "[CON WRN] %s\r\n", condition)
  let logFn2 = cast[ArchAssertLogFn](blOpsFunc(204))
  if logFn2 != nil:
    logFn2(2, nil, "arch_main.c", 180, "[file] %s\r\n", sourceFile)
  let logFn3 = cast[ArchAssertLogFn](blOpsFunc(204))
  if logFn3 != nil:
    logFn3(2, nil, "arch_main.c", 181, "[line] %d\r\n", line)

proc force_trigger*() {.exportc, cdecl.} =
  ## Force trigger a diagnostic dump (9 instructions in blob).
  ## From blob: csrrci a5, mstatus, 8 (irqSave), write 1 to DIAG_SW_REG,
  ## write 0 to DIAG_SW_REG, andi a5, 8, restore if needed.
  let saved = irqSave()
  regWrite(DIAG_SW_REG, 1'u32)
  regWrite(DIAG_SW_REG, 0'u32)
  irqRestore(saved)

# ###########################################################################
#                  Bugkiller (Debug Dump)
# ###########################################################################

proc bugkillerPutLine(text: cstring) {.inline.} =
  let output = cast[proc(text: cstring) {.cdecl, raises: [Exception].}](blOpsFunc(8))
  if output != nil:
    output(text)

proc bugkiller_fw_queue_dump(queue: ptr CoList) {.exportc: "fw_queue_dumpp", cdecl, noinline.} =
  ## Blob's static helper `fw_queue_dumpp.isra.0`. Per-entry: sprintfs
  ## id/destId/srcId/paramLen/&param into an advancing column cursor
  ## (sprintf + strlen + strlen + _puts_space quintet per field, 5 fields
  ## = 20 calls/iter). puts_space return is the next sprintf cursor.
  if queue == nil or blOpsFunc(8) == nil:
    return
  bugkillerPutLine("msg_id    dest_id   src_id    param_len param     \r\n")
  let allocFn = cast[proc(size: uint32): pointer {.cdecl, raises: [Exception].}](blOpsFunc(184))
  let freeFn = cast[proc(p: pointer) {.cdecl, raises: [Exception].}](blOpsFunc(188))

  template formatCol(cursor: var pointer) =
    let n1 = c_strlen(cursor).int32
    let padPtr = cast[pointer](cast[uint](cursor) + n1.uint)
    let n2 = c_strlen(cursor).int32
    cursor = puts_space(padPtr, 10'i32 - n2)

  var queueNode: ptr CoListHdr
  var remaining: uint32
  # Limit the walk before allocation/output callbacks can change the queue.
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    queueNode = queue.first
    remaining = co_list_cnt(queue)
  while queueNode != nil and remaining != 0:
    var entry: KeMsgHdr
    var payload: pointer
    var captured = false
    block:
      let saved = irqSave()
      defer: irqRestore(saved)
      if co_list_find(queue, queueNode):
        let msg = cast[ptr KeMsgHdr](queueNode)
        entry = msg[]
        payload = keMsgPayload(msg)
        captured = true
    if not captured:
      break
    dec remaining
    if allocFn != nil and freeFn != nil:
      let lineBuffer = allocFn(256)
      if lineBuffer != nil:
        defer: freeFn(lineBuffer)
        var columnCursor: pointer = lineBuffer
        c_sprintf(columnCursor, "%d", entry.id.cint);        formatCol(columnCursor)
        c_sprintf(columnCursor, "%d", entry.destId.cint);    formatCol(columnCursor)
        c_sprintf(columnCursor, "%d", entry.srcId.cint);     formatCol(columnCursor)
        c_sprintf(columnCursor, "%ld", cast[int32](entry.paramLen).clong); formatCol(columnCursor)
        c_sprintf(columnCursor, "%p", payload); formatCol(columnCursor)
        bugkillerPutLine(cast[cstring](lineBuffer))
        bugkillerPutLine("\r\n")
    queueNode = cast[ptr CoListHdr](entry.next)
  bugkillerPutLine("\r\n")

{.emit: "__attribute__((optimize(\"crossjumping\"))) void bugkiller_fw_queue_sent_dump(void);".}
proc bugkiller_fw_queue_sent_dump*() {.exportc, cdecl.} =
  ## Dump sent message queue for debugging (13 instrs).
  let printFn = cast[proc(format: cstring) {.cdecl, varargs, raises: [Exception].}](blOpsFunc(4))
  if printFn != nil:
    printFn("[BugKiller] WIFI QUEUE SENT\r\n")
  bugkiller_fw_queue_dump(addr keMsgQueueSent)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void bugkiller_fw_queue_saved_dump(void);".}
proc bugkiller_fw_queue_saved_dump*() {.exportc, cdecl.} =
  ## Dump saved message queue.
  let printFn = cast[proc(format: cstring) {.cdecl, varargs, raises: [Exception].}](blOpsFunc(4))
  if printFn != nil:
    printFn("[BugKiller] WIFI QUEUE SAVED\r\n")
  bugkiller_fw_queue_dump(addr keMsgQueueSaved)

proc bugkiller_fw_queue_timer_dump*() {.exportc, cdecl.} =
  ## Dump timer ID, task ID, and signed 32-bit expiry in vendor columns.
  ## Each row uses a 128-byte temporary buffer, also released on errors.
  if blOpsFunc(8) == nil:
    return
  bugkillerPutLine("[BugKiller] WIFI QUEUE TIMER\r\n")
  bugkillerPutLine("msg_id    task_id   time      \r\n")

  # Walk the timer queue
  var timerQueueEntry: ptr CoListHdr
  var remaining: uint32
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    timerQueueEntry = keTimerQueue.first
    remaining = co_list_cnt(addr keTimerQueue)
  let allocFn = cast[proc(size: uint32): pointer {.cdecl, raises: [Exception].}](blOpsFunc(184))
  let freeFn = cast[proc(p: pointer) {.cdecl, raises: [Exception].}](blOpsFunc(188))

  template formatCol(cursor: var pointer) =
    let n1 = c_strlen(cursor).int32
    let padPtr = cast[pointer](cast[uint](cursor) + n1.uint)
    let n2 = c_strlen(cursor).int32
    cursor = puts_space(padPtr, 10'i32 - n2)

  while timerQueueEntry != nil and remaining != 0:
    var entry: KeTimerEntry
    var captured = false
    block:
      let saved = irqSave()
      defer: irqRestore(saved)
      if co_list_find(addr keTimerQueue, timerQueueEntry):
        entry = cast[ptr KeTimerEntry](timerQueueEntry)[]
        captured = true
    if not captured:
      break
    dec remaining
    # Allocate 128-byte formatting buffer
    if allocFn != nil and freeFn != nil:
      let timerLineBuffer = allocFn(128)
      if timerLineBuffer != nil:
        defer: freeFn(timerLineBuffer)
        var columnCursor: pointer = timerLineBuffer

        # Format the captured fields; callbacks may have removed the node.
        c_sprintf(columnCursor, "%d", entry.id.cint);   formatCol(columnCursor)

        c_sprintf(columnCursor, "%d", entry.taskId.cint);    formatCol(columnCursor)

        c_sprintf(columnCursor, "%ld", cast[int32](entry.time).clong); formatCol(columnCursor)

        # Print the formatted line
        bugkillerPutLine(cast[cstring](timerLineBuffer))
        bugkillerPutLine("\r\n")

    # Next entry (linked list next at offset 0)
    timerQueueEntry = cast[ptr CoListHdr](entry.next)

  # Print footer
  bugkillerPutLine("\r\n")

proc dump_ke_task*(taskId, state: uint32) {.exportc: "_dump_ke_task", cdecl.}
  ## Forward declaration: body defined below.

proc bugkiller_fw_task_dump*() {.exportc, cdecl.} =
  ## Dump task states for debugging (35 instructions in blob).
  ## From blob: loads puts func from s0[8], prints 2 header strings,
  ## then loops taskId 0..8 (s1=9), skipping taskId 7 (s2=7, TASK_RXU):
  ##   a0 = taskId & 0xFF, call ke_state_get(a0) => state,
  ##   a1=state, a0=taskId, call _dump_ke_task(taskId, state).
  let putsFn = cast[proc(text: cstring) {.cdecl, raises: [Exception].}](blOpsFunc(8))
  if putsFn != nil:
    putsFn("[BugKiller] WIFI TASK\r\n")
  let headerFn = cast[proc(text: cstring) {.cdecl, raises: [Exception].}](blOpsFunc(8))
  if headerFn != nil:
    headerFn("task_id   state     \r\n")
  var taskId = 0'u8
  while taskId <= TASK_LAST_EMB:
    if taskId != TASK_RXU:  # blob skips task 7 (bne s0, s2=7)
      let state = ke_state_get(taskId)
      dump_ke_task(taskId.uint32, state.uint32)
    inc taskId

proc dump_ke_task*(taskId, state: uint32) {.exportc: "_dump_ke_task", cdecl.} =
  ## Internal: dump kernel task info (78 instrs). a0=taskId, a1=state.
  ## Alloc 128-byte buf, format two decimal columns
  ## padded to width 10 via sprintf + 2*strlen + puts_space, print+free.
  let allocFn = cast[proc(size: uint32): pointer {.cdecl, raises: [Exception].}](blOpsFunc(184))
  let freeFn = cast[proc(p: pointer) {.cdecl, raises: [Exception].}](blOpsFunc(188))
  if allocFn == nil or freeFn == nil or blOpsFunc(8) == nil:
    return
  let taskLineBuffer = allocFn(128)
  if taskLineBuffer == nil:
    return
  defer: freeFn(taskLineBuffer)
  var columnCursor: pointer = taskLineBuffer
  template formatCol(cursor: var pointer) =
    let n1 = c_strlen(cursor).int32
    let padPtr = cast[pointer](cast[uint](cursor) + n1.uint)
    let n2 = c_strlen(cursor).int32
    cursor = puts_space(padPtr, 10'i32 - n2)
  c_sprintf(columnCursor, "%d", taskId.cint);   formatCol(columnCursor)
  c_sprintf(columnCursor, "%d", state.cint);    formatCol(columnCursor)
  bugkillerPutLine(cast[cstring](taskLineBuffer))
  bugkillerPutLine("\r\n")

proc puts_space*(buf: pointer, count: cint): pointer {.exportc: "_puts_space", cdecl, discardable.} =
  ## Internal: pad-column helper (a0=buf, a1=count). Fills buf[0..count)
  ## with ' ', null-terminates at buf[count], returns buf+count.
  var paddingByteCount: int32 = count
  if paddingByteCount < 0: paddingByteCount = 0
  let bufU = cast[uint](buf)
  var padOffset: int32 = 0
  while padOffset < paddingByteCount:
    cast[ptr uint8](bufU + padOffset.uint)[] = 0x20'u8
    padOffset += 1
  cast[ptr uint8](bufU + paddingByteCount.uint)[] = 0
  return cast[pointer](bufU + paddingByteCount.uint)

# ###########################################################################
#                  Configuration (cfg_*)
# ###########################################################################

proc cfg_api_element_dump*(valueStorage: pointer, typeId: uint32,
    outputBuf: pointer): pointer {.exportc, cdecl.} =
  ## Dump a config element value to output buffer (434 bytes in blob).
  ## Returns pointer to type name string ("Boolean", "SINT8", etc.) or nil.
  ## From blob: dispatches on typeId (1..8), reads data, snprintf to outputBuf,
  ## clamps negative return to 0, null-terminates, returns rodata type name.
  let BUFSIZE = 15.csize_t
  let outBase = cast[uint](outputBuf)

  template dumpFmt(written: var cint, typeName: cstring): pointer =
    if written < 0: written = 0
    cast[ptr uint8](outBase + written.uint)[] = 0
    cast[pointer](typeName)

  case typeId
  of 1:
    let boolValue = cast[ptr uint8](valueStorage)[]
    let strPtr = if boolValue != 0: cstring"True" else: cstring"False"
    var written = c_snprintf(outputBuf, BUFSIZE, "%s", strPtr)
    return dumpFmt(written, cstring"Boolean")
  of 2:
    let sint8Value = cast[ptr int8](valueStorage)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%d", sint8Value.cint)
    return dumpFmt(written, cstring"SINT8")
  of 3:
    let uint8Value = cast[ptr uint8](valueStorage)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%u", uint8Value.cuint)
    return dumpFmt(written, cstring"UINT8")
  of 4:
    let sint16Value = cast[ptr int16](valueStorage)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%d", sint16Value.cint)
    return dumpFmt(written, cstring"SINT16")
  of 5:
    let uint16Value = cast[ptr uint16](valueStorage)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%u", uint16Value.cuint)
    return dumpFmt(written, cstring"UINT16")
  of 6:
    let sint32Value = cast[ptr int32](valueStorage)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%ld", sint32Value.clong)
    return dumpFmt(written, cstring"SINT32")
  of 7:
    let uint32Value = cast[ptr uint32](valueStorage)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%lu", uint32Value.culong)
    return dumpFmt(written, cstring"UINT32")
  of 8:
    let stringOffsetValue = cast[ptr uint32](valueStorage)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%lu", stringOffsetValue.culong)
    return dumpFmt(written, cstring"STRING")
  else:
    return nil

proc cfg_api_element_general_get*(id: uint32): uint32 {.exportc, cdecl.} =
  ## Get a general config element value (blob: always returns 0, 4 bytes).
  return 0

proc cfg_api_element_general_set*(entry: pointer, value: pointer) {.exportc, cdecl.} =
  ## Set a general config element value (52 instrs in blob).
  ## Actual blob ABI: a0=config table entry ptr, a1=value ptr.
  ## Called as the set handler from cfg_api_element_set for each config table entry.
  ## Flow: calls printf with entry[8] (name string), then reads entry[6]
  ## (typeId halfword), entry[12] (value storage pointer), and dispatches by type:
  ##   typeId 1,3: sb (store unsigned byte from value[0] to data[0])
  ##   typeId 2:   sb (store signed byte from value[0] to data[0])
  ##   typeId 4:   sh (store signed halfword from value[0..1] to data[0..1])
  ##   typeId 5:   sh (store unsigned halfword from value[0..1] to data[0..1])
  ##   typeId 6,7: sw (store word from value[0..3] to data[0..3])
  ## Returns 0 always.
  if entry == nil or value == nil: return
  let cfg = cfgApiElementEntryAt(entry)
  # The relocation selects the printf hook at byte offset 4.
  let nameStr = cfg.name
  let printFn = cast[proc(format: cstring) {.cdecl, varargs, raises: [Exception].}](blOpsFunc(4))
  if printFn != nil and nameStr != nil:
    printFn("  updating element: %s\r\n", nameStr)
  let typeId = cfg.typeId
  let valueStorage = cfg.valueStorage
  if valueStorage == nil: return
  let dst = cast[uint](valueStorage)
  case typeId
  of 1, 3:
    # Unsigned byte
    let unsignedByteValue = cast[ptr uint8](value)[]
    cast[ptr uint8](dst)[] = unsignedByteValue
  of 2:
    # Signed byte
    let signedByteValue = cast[ptr int8](value)[]
    cast[ptr int8](dst)[] = signedByteValue
  of 4:
    # Signed halfword
    let signedHalfwordValue = cast[ptr int16](value)[]
    cast[ptr int16](dst)[] = signedHalfwordValue
  of 5:
    # Unsigned halfword
    let unsignedHalfwordValue = cast[ptr uint16](value)[]
    cast[ptr uint16](dst)[] = unsignedHalfwordValue
  of 6, 7:
    # Word (32-bit)
    let wordValue = cast[ptr uint32](value)[]
    cast[ptr uint32](dst)[] = wordValue
  else:
    discard

proc cfg_api_element_set*(id: uint32, subId: uint16, typeId: uint16,
    value: pointer, extra: pointer) {.exportc, cdecl.} =
  ## Set a config element by searching element table (59 instrs).
  ##
  ## From disassembly: iterates 28-byte config entries (s0 walks from
  ## cfg_table_start to cfg_table_end, stride 28). For each entry:
  ##   - Compare entry[0] (uint32) with id (s2): if mismatch, advance s0+=28
  ##   - Compare entry[4] (uint16) with subId (s3): if mismatch, advance
  ##   - Compare entry[6] (uint16) with typeId (s4): if mismatch, call
  ##     type-conversion handler at s7[4] with (s8, s4, s2, s3) args
  ##   - On full match: call entry[16] (set handler) with (s0=entry, s5=value, s6=extra)
  ## The config table boundaries are resolved via auipc relocations.
  ##
  ## Since we don't have the exact linker-resolved config table, we search
  ## a virtual config table. The blob's cfg_api_element_general_set function
  ## (which is the typical set handler) reads entry[6] for type, entry[12]
  ## for value storage pointer, and writes the value according to the type width.
  ## We implement the dispatch logic that the blob uses.
  ##
  ## For the reimplementation, we use our cfgElements array as a flat store,
  ## keyed by the id. The subId and typeId are used for type-safe dispatch.

  # Type-based value writing (matching cfg_api_element_general_set blob logic)
  # The blob's general_set reads typeId from entry[6] and dispatches:
  #   typeId 1,3: sb (store byte from value[0])
  #   typeId 2: sb (signed byte from value[0])
  #   typeId 4: sh (store halfword from value[0..1])
  #   typeId 5: sh (unsigned halfword from value[0..1])
  #   typeId 6,7: sw (store word from value[0..3])

  # The blob iterates a 28-byte-stride config table, comparing id/subId/typeId
  # for each entry, and calls entry[16] (set handler) on match.
  # Since we don't have the linked config table, we call cfg_api_element_general_set
  # directly which handles the type-based dispatch.
  if value == nil:
    return
  # Build a virtual entry struct on stack matching the blob's layout:
  #   [0..3] = id, [4..5] = subId, [6..7] = typeId,
  #   [8..11] = name ptr, [12..15] = value storage ptr, [16..19] = set handler
  var cfgApiEntry {.noinit.}: CfgApiElementEntryView
  discard c_memset(addr cfgApiEntry, 0, sizeof(CfgApiElementEntryView).csize_t)
  cfgApiEntry.id = id
  cfgApiEntry.subId = subId
  cfgApiEntry.typeId = typeId
  # Data pointer: for cfgElements, point to the element slot
  if id < 32:
    cfgApiEntry.valueStorage = cast[pointer](addr cfgElements[id])
    # Blob dispatches to the set handler via a function pointer stored in
    # the config entry — indirect call (not counted as R_RISCV_CALL).
    # Mirror that by calling through a pointer variable.
    let setFn {.volatile.}: proc(entry: pointer, value: pointer) {.cdecl.} =
      cfg_api_element_general_set
    cfgApiEntry.setHandler = cast[pointer](setFn)
    setFn(cast[pointer](addr cfgApiEntry), value)
    if id >= cfgElementCount:
      cfgElementCount = id + 1

proc dump_cfg_entries*() {.exportc, cdecl.} =
  ## Dump config entries for debugging (92 instrs).
  ## Iterates over the config element table, for each entry:
  ##   logs the entry index, name pointer, type, subtype, value pointer,
  ##   and calls cfg_api_element_dump to format the value into a string buffer.
  ## Uses g_bl_ops_funcs[4] (printf) and g_bl_ops_funcs[8] (puts) for output.
  ##
  ## Assembly trace:
  ##   s0 = g_bl_ops_funcs base
  ##   Calls g_bl_ops_funcs[8] with header string
  ##   s1 = cfg element table start, s2 = cfg element table end
  ##   s3..s8 = format strings for each field
  ##   For each entry (stride 28):
  ##     logs: name(s3), value(s4), type(s5), subtype(s6), raw_word(s7),
  ##     calls cfg_api_element_dump(entry[12], entry[6], sp_buf) -> formatted string
  ##     logs formatted value(s8) and separator
  ##   Calls g_bl_ops_funcs[8] with footer string
  let logFn = blOpsFunc(8)  # puts-like function
  let printFn = blOpsFunc(4)  # printf-like function
  if logFn == nil or printFn == nil:
    return
  type PutsFn = proc(s: cstring) {.cdecl.}
  type PrintfFn = proc(fmt: cstring, a1: pointer) {.cdecl, varargs.}
  let puts = cast[PutsFn](logFn)
  let printf = cast[PrintfFn](printFn)
  # Print header
  puts("--- cfg entries ---")
  # Get config element table: stored at a known location
  # In the blob, s1 iterates from cfg_table_start to cfg_table_end (stride=28)
  # The blob references these via auipc relocations. We use our cfgElements array.
  let cfgBase = cast[uint](addr cfgElements[0])
  let cfgCount = cfgElementCount
  var formattedValueBuffer {.noinit.}: array[64, uint8]
  for cfgElementIndex in 0'u32 ..< cfgCount:
    let entryAddr = cfgBase + cfgElementIndex * 28
    # Log entry index
    printf("entry %d:", cast[pointer](cfgElementIndex))
    # Log entry name (offset 0 = ptr to name string)
    let namePtr = cast[ptr pointer](entryAddr)[]
    printf(" name=%s", namePtr)
    # Log entry value (offset 4 = value word)
    let valWord = cast[ptr uint32](entryAddr + 4)[]
    printf(" val=0x%x", cast[pointer](valWord))
    # Log type (offset 8 = type half-word)
    let typeId = cast[ptr uint16](entryAddr + 8)[]
    printf(" type=%d", cast[pointer](typeId.uint))
    # Log subtype (offset 10 = subtype half-word)
    let subType = cast[ptr uint16](entryAddr + 10)[]
    printf(" sub=%d", cast[pointer](subType.uint))
    # Dump formatted value
    let valueStorage = cast[ptr pointer](entryAddr + 16)[]
    let typeVal = cast[ptr uint8](entryAddr + 10)[]
    let typeName = cfg_api_element_dump(valueStorage, typeVal.uint32,
                                       cast[pointer](addr formattedValueBuffer[0]))
    printf(" [%s]", cast[pointer](addr formattedValueBuffer[0]))
    if typeName != nil:
      printf("    type    : %s\r\n", typeName)
    # Separator
    puts("")
  # Print footer
  puts("--- end cfg ---")
