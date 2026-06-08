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
  var pos = cast[uint](buf)
  let endPos = pos + bufLen.uint
  while pos < endPos:
    let ie = macIeAt(pos)
    if ie.id == ieId:
      return cast[pointer](pos)
    pos += ie.totalLen
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
  var pos = cast[uint](buf)
  let endPos = pos + bufLen.uint
  let ouiArr = cast[ptr UncheckedArray[uint8]](oui)
  while pos < endPos:
    let ie = macIeAt(pos)
    if ie.id == 0xDD'u8:
      # Vendor-specific IE found, compare OUI bytes
      let ieData = ie.macIePayload
      var match = true
      for i in 0'u8 ..< ouiLen:
        if ieData[i] != ouiArr[i]:
          match = false
          break
      if match:
        return cast[pointer](pos)
    pos += ie.totalLen
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
  let b = cast[ptr UncheckedArray[uint8]](bssid)
  let byte4 = b[4].uint32 and 0x80  # bit 7 of byte 4
  let byte5 = b[5].uint32
  result = ((byte5 shl 1) or byte4) shl 22

proc mac_paid_gid_ap_compute*(bssid: pointer, aid: uint16): uint32 {.exportc, cdecl.} =
  ## Compute Partial AID and Group ID for AP (13 instructions in blob).
  ## From blob: lbu a5, 5(a0) => byte5 of BSSID
  ##   andi a1, 511 => partialAID = aid & 0x1FF
  ##   srai a0, a5, 4 => upperNibble = byte5 >> 4
  ##   xor a0, a0, a5 => mixed = upperNibble ^ byte5
  ##   slli a0, 5 => mixed <<= 5
  ##   andi a0, 480 => mixed &= 0x1E0 (5-bit field in bits 8:5)
  ##   add a0, a1 => combined = mixed + partialAID
  ##   lui a5, 0x7FC00; slli a0, 22; and a0, a5 => PAID field in bits 30:22
  ##   lui a5, 0x3F0; or a0, a5 => set GID=0x3F (broadcast) in bits 21:16
  let b = cast[ptr UncheckedArray[uint8]](bssid)
  let byte5 = b[5].uint32
  let partialAid = aid.uint32 and 0x1FF'u32
  let upperNibble = byte5 shr 4
  var mixed = (upperNibble xor byte5) shl 5
  mixed = mixed and 0x1E0'u32
  let combined = mixed + partialAid
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
  let word = regRead(regAddr)
  aifs[] = (word and 0xF).uint8             # bits [3:0]
  cwmin[] = ((word shr 4) and 0xF).uint8    # bits [7:4]
  cwmax[] = ((word shr 8) and 0xF).uint8    # bits [11:8]
  txop[] = (word shr 12).uint16             # bits [31:12]
  return 0

proc bl60x_firmwre_mpdu_free*(param: pointer) {.exportc, cdecl.} =
  ## Free an MPDU buffer (24 instrs in blob).
  ## Blob ABI: a0=param. Reads callbacks from g_bl_ops_funcs+20 / +24 (not
  ## bl60x_fw_env!). Decrements rxl_cntrl_env+20 (pending MPDU count) by
  ## param[21] (descriptor count). Tail-calls rxl_mpdu_free(param).
  # Call pre-free callback (g_bl_ops_funcs[5] = byte offset 20)
  let preFree = cast[proc() {.cdecl.}](blOpsFunc(20))
  preFree()
  # Decrement pending MPDU count at rxl_cntrl_env+20
  let rx = rxlCntrlEnvView()
  let descCount = rxMpduDescView(param).descCount
  rx.pendingMpduCount = rx.pendingMpduCount - descCount.uint32
  # Call post-free callback (g_bl_ops_funcs[6] = byte offset 24)
  let postFree = cast[proc() {.cdecl.}](blOpsFunc(24))
  postFree()
  # Tail-call rxl_mpdu_free(param)
  rxl_mpdu_free(param)

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
  var pos = headPtr
  var cur = cast[ptr CoListHdr](pos[])
  while cur != nil:
    let curNode = notifierNodeView(cur)
    let curPrio = curNode.priority
    if curPrio < newPrio:
      # Insert notifier before cur
      newNode.next = cast[pointer](cur)
      pos[] = cast[pointer](notifier)
      return
    # Advance: pos = &cur->next (offset 4)
    pos = addr curNode.next
    cur = cast[ptr CoListHdr](pos[])
  # End of list or empty: insert here
  newNode.next = nil
  pos[] = cast[pointer](notifier)

proc notifier_chain_remove(headPtr: ptr pointer, notifier: ptr CoListHdr) =
  ## Remove a notifier from a singly-linked list by pointer match.
  ## From blob: walks list via offset 4 (next), compares pointer,
  ## unlinks by setting prev->next = node->next.
  var pos = headPtr
  var cur = cast[ptr CoListHdr](pos[])
  while cur != nil:
    if cur == notifier:
      # Unlink: *pos = notifier->next
      pos[] = notifierNodeView(notifier).next
      return
    pos = addr notifierNodeView(cur).next
    cur = cast[ptr CoListHdr](pos[])

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
  ##   save next from offset 4 before call
  ##   jalr a5(s0, s3=event, s4=data) => callback(node, event, data)
  ##   s0 = s0[4] => advance to next
  ## irqRestore, return 0.
  let saved = irqSave()
  var cur = chain.first
  while cur != nil:
    let node = notifierNodeView(cur)
    let next = cast[ptr CoListHdr](node.next)
    let cb = cast[proc(node: ptr CoListHdr, event: uint32, data: pointer): cint {.cdecl.}](
      node.callback
    )
    if cb != nil:
      discard cb(cur, event, data)
    cur = next
  irqRestore(saved)

proc notifier_chain_call_fromeCritical*(chain: ptr CoList, event: uint32, data: pointer) {.exportc, cdecl.} =
  ## Call notifiers from critical section (no irqSave/irqRestore).
  ## From blob (23 instrs): s0 = chain.first, for each node:
  ##   lw a5, 0(s0) => callback, call callback(node, event, data),
  ##   lw s0, 4(s0) => next. No interrupt manipulation.
  var cur = chain.first
  while cur != nil:
    let node = notifierNodeView(cur)
    let cb = cast[proc(node: ptr CoListHdr, event: uint32, data: pointer): cint {.cdecl.}](
      node.callback
    )
    if cb != nil:
      discard cb(cur, event, data)
    cur = cast[ptr CoListHdr](node.next)

# ###########################################################################
#                  Replay Counter
# ###########################################################################

proc replay_counter_validate*(param: pointer): bool {.exportc, cdecl.} =
  ## Validate replay counter in received frame (44 instrs).
  ## From blob: a0=replay_counter_state (8 bytes: lo32, hi32), a1=new_lo, a2=new_hi.
  ## Compares {state.hi, state.lo} against {new_hi, new_lo} as 64-bit unsigned.
  ## If new < state+1 (i.e., new <= state), returns false (replay detected).
  ## Otherwise: updates state = new, and clears any pending replay slots.
  ## The state has additional slots at offset 8+ for multi-key replay tracking.
  ## Returns true if counter is valid (not replayed).
  var newLo, newHi: uint32
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", newLo, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a2\" : \"=r\"(", newHi, ") );"].}
  let state = replayCounterStateView(param)
  let stateLo = state.pnLow
  let stateHi = state.pnHigh
  # Compare as 64-bit: if new > state, accept; if new <= state, reject
  # Need unsigned 64-bit compare: compare hi first, then lo
  if newHi < stateHi:
    return false  # new is older
  if newHi == stateHi and newLo <= stateLo + 33:
    # Check within window (blob checks state+33 as threshold for lo)
    if newHi == stateHi and newLo <= stateLo:
      return false  # replay
  # Valid: update state
  # Also handle replay window slots at offset 8+ (blob clears slots)
  let slotIdx = (stateLo + 1) and 1  # alternating slot
  let slotOff = slotIdx * 12 + 8
  # Clear slot if counter changed significantly
  if newLo != stateLo + 1:
    let nextSlot = (newLo + 1) and 1
    state.slots[nextSlot].valid = 0
    let prevSlot = newLo and 1
    if prevSlot != slotIdx:
      state.slots[prevSlot].valid = 0
  # Store new counter
  state.pnLow = newLo
  state.pnHigh = newHi
  return true

# ###########################################################################
#                  Assert Handlers
# ###########################################################################

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
  # Call 1: condition/function name
  let logFn1 = getLogFunc(76)
  if logFn1 != nil:
    logFn1(2, 0, cast[pointer](cond), 148, cast[uint32](cond))
  # Call 2: line
  let logFn2 = getLogFunc(76)
  if logFn2 != nil:
    logFn2(2, 0, cast[pointer](file), 149, cast[uint32](line))
  # Call 3: extra (line number as uint32)
  let logFn3 = getLogFunc(76)
  if logFn3 != nil:
    logFn3(2, 0, cast[pointer](file), 150, cast[uint32](line))
  # Call 4: status
  let logFn4 = getLogFunc(76)
  if logFn4 != nil:
    logFn4(2, 0, cast[pointer](file), 151)
  # Call 5: dump register context words [2..5]
  let logFn5 = getLogFunc(76)
  if logFn5 != nil:
    logFn5(2, 0, nil, 152,
          dbg_assert_block[2], dbg_assert_block[3],
          dbg_assert_block[4], dbg_assert_block[5])
  # Call 6: dump register context words [6..9]
  let logFn6 = getLogFunc(76)
  if logFn6 != nil:
    logFn6(2, 0, nil, 158,
          dbg_assert_block[6], dbg_assert_block[7],
          dbg_assert_block[8], dbg_assert_block[9])
  let saved = irqSave()
  hal_machw_disable_int()
  ke_evt_set(0x80000000'u32)
  irqRestore(saved)

proc assert_rec*(cond: cstring, file: cstring, line: cint) {.exportc, cdecl.} =
  ## Recoverable assertion handler (248 bytes in blob, 79 instrs).
  ## Blob ABI: (a0=cond_or_func_name, a1=source_file, a2=line_number).
  ## From blob: log function at g_bl_ops_funcs[76]. Calls log with file/line
  ## (lines 86-87), dumps dbg_assert_block (lines 88, 94), calls notification
  ## function, irqSave, checks keEvtField bit 31, triggers reset if needed.
  let logFn = getLogFunc(76)
  if logFn != nil:
    logFn(2, 0, cast[pointer](cond), 86)
    logFn(2, 0, cast[pointer](file), 87, cast[uint32](line))
    logFn(2, 0, nil, 88,
          dbg_assert_block[2], dbg_assert_block[3],
          dbg_assert_block[4], dbg_assert_block[5])
    logFn(2, 0, nil, 94,
          dbg_assert_block[6], dbg_assert_block[7],
          dbg_assert_block[8], dbg_assert_block[9])
  nimFwTrace2U32("[WIFI-NIMFW] assert_rec ",
                 cast[uint32](line),
                 cast[uint32](cast[uint](file)))
  # Call notification function from g_bl_ops_funcs[1] (byte offset 4, NOT 80)
  let notifyFn = blOpsFunc(4)
  if notifyFn != nil:
    cast[proc(arg: pointer) {.cdecl.}](notifyFn)(nil)
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
  let logFn = getLogFunc(204)
  if logFn != nil:
    logFn(2, 0, cast[pointer](cond), 179, cast[uint32](cond))
  let logFn2 = getLogFunc(204)
  if logFn2 != nil:
    logFn2(2, 0, cast[pointer](file), 180, cast[uint32](line))
  let logFn3 = getLogFunc(204)
  if logFn3 != nil:
    logFn3(2, 0, cast[pointer](file), 181, cast[uint32](line))

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

proc bugkiller_fw_queue_dump(queue: ptr CoList) {.exportc: "fw_queue_dumpp", cdecl, noinline.} =
  ## Blob's static helper `fw_queue_dumpp.isra.0`. Per-entry: sprintfs
  ## id/destId/srcId/paramLen/&param into an advancing column cursor
  ## (sprintf + strlen + strlen + _puts_space quintet per field, 5 fields
  ## = 20 calls/iter). puts_space return is the next sprintf cursor.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let putsFn = blOpsFunc(8)
  let allocFnPtr = blOpsFunc(184)
  let freeFnPtr = blOpsFunc(188)
  type PutsFnType = proc(s: pointer) {.cdecl.}
  type AllocFnType = proc(sz: uint32): pointer {.cdecl.}
  type FreeFnType = proc(p: pointer) {.cdecl.}
  let puts = cast[PutsFnType](putsFn)

  template formatCol(cursor: var pointer) =
    let n1 = c_strlen(cursor).int32
    let padPtr = cast[pointer](cast[uint](cursor) + n1.uint)
    let n2 = c_strlen(cursor).int32
    cursor = puts_space(padPtr, 10'i32 - n2)

  var cur = queue.first
  while cur != nil:
    let msg = cast[ptr KeMsgHdr](cur)
    if allocFnPtr != nil:
      let allocFn = cast[AllocFnType](allocFnPtr)
      let buf = allocFn(256)
      if buf != nil:
        var col: pointer = buf
        c_sprintf(col, "%d", msg.id.cint);        formatCol(col)
        c_sprintf(col, "%d", msg.destId.cint);    formatCol(col)
        c_sprintf(col, "%d", msg.srcId.cint);     formatCol(col)
        c_sprintf(col, "%d", msg.paramLen.cint);  formatCol(col)
        c_sprintf(col, "0x%08x",
                  cast[uint32](cast[uint](msg) + 12)); formatCol(col)
        if putsFn != nil:
          puts(buf)
          puts(nil)
        if freeFnPtr != nil:
          cast[FreeFnType](freeFnPtr)(buf)
    cur = cur.next
  if putsFn != nil:
    puts(nil)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void bugkiller_fw_queue_sent_dump(void);".}
proc bugkiller_fw_queue_sent_dump*() {.exportc, cdecl.} =
  ## Dump sent message queue for debugging (13 instrs).
  let logFn = getLogFunc(4)
  if logFn != nil:
    logFn(2, 0, nil, 0)
  bugkiller_fw_queue_dump(addr keMsgQueueSent)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void bugkiller_fw_queue_saved_dump(void);".}
proc bugkiller_fw_queue_saved_dump*() {.exportc, cdecl.} =
  ## Dump saved message queue.
  let logFn = getLogFunc(4)
  if logFn != nil:
    logFn(2, 0, nil, 0)
  bugkiller_fw_queue_dump(addr keMsgQueueSaved)

proc bugkiller_fw_queue_timer_dump*() {.exportc, cdecl.} =
  ## Dump timer queue for debugging (109 instrs).
  ## From blob: loads g_bl_ops_funcs (s0), calls puts(header_string1),
  ## then puts(header_string2). Loads keTimerQueue.first (s1).
  ## For each timer entry in the queue:
  ##   1. Allocates 128-byte buffer via g_bl_ops_funcs[184] (alloc)
  ##   2. If alloc fails, skip to next entry
  ##   3. snprintf(buf, "%d", entry.id) (timer msg ID at offset 4, half-word)
  ##   4. strlen(buf), _puts_space(buf+len, 10-len)
  ##   5. snprintf(buf, "%d", entry.taskId) (task ID at offset 6, byte)
  ##   6. strlen(buf), _puts_space(buf+len, 10-len)
  ##   7. snprintf(buf, "0x%08x", entry.time) (expiry at offset 8, word)
  ##   8. strlen(buf), _puts_space(buf+len, 10-len)
  ##   9. calls puts(buf) to print, then puts("\r\n")
  ##  10. calls free(buf) via g_bl_ops_funcs[188]
  ##  11. next = entry[0] (linked list next pointer)
  ## After loop: calls puts(footer_string).
  let putsFn = blOpsFunc(8)
  let printFn = blOpsFunc(4)
  if putsFn == nil:
    return
  type PutsFnType = proc(s: pointer) {.cdecl.}
  type PrintFnType = proc(fmt: pointer, args: uint32) {.cdecl, varargs.}
  let puts = cast[PutsFnType](putsFn)
  # Print two header lines
  puts(nil)  # header 1 (blob uses string literals via auipc)
  puts(nil)  # header 2

  # Walk the timer queue
  var entry = keTimerQueue.first
  let allocFnPtr = blOpsFunc(184)
  let freeFnPtr = blOpsFunc(188)
  let snprintfPtr = blOpsFunc(4)

  template formatCol(cursor: var pointer) =
    let n1 = c_strlen(cursor).int32
    let padPtr = cast[pointer](cast[uint](cursor) + n1.uint)
    let n2 = c_strlen(cursor).int32
    cursor = puts_space(padPtr, 10'i32 - n2)

  while entry != nil:
    # Allocate 128-byte formatting buffer
    if allocFnPtr != nil:
      let allocFn = cast[proc(size: uint32): pointer {.cdecl.}](allocFnPtr)
      let buf = allocFn(128)
      if buf != nil:
        let entryU = cast[uint](entry)
        var col: pointer = buf

        # Format timer ID (half-word at offset 4)
        let timerId = cast[ptr uint16](entryU + 4)[]
        c_sprintf(col, "%d", timerId.cint);   formatCol(col)

        # Format task ID (byte at offset 6)
        let taskId = cast[ptr uint8](entryU + 6)[]
        c_sprintf(col, "%d", taskId.cint);    formatCol(col)

        # Format expiry time (word at offset 8)
        let expiryTime = cast[ptr uint32](entryU + 8)[]
        c_sprintf(col, "0x%08x", expiryTime); formatCol(col)

        # Print the formatted line
        puts(buf)
        puts(nil)  # newline ("\r\n" in blob)

        # Free buffer
        if freeFnPtr != nil:
          let freeFn = cast[proc(p: pointer) {.cdecl.}](freeFnPtr)
          freeFn(buf)

    # Next entry (linked list next at offset 0)
    entry = cast[ptr CoListHdr](cast[ptr pointer](cast[uint](entry))[])

  # Print footer
  puts(nil)

proc dump_ke_task*() {.exportc: "_dump_ke_task", cdecl.}
  ## Forward declaration: body defined below.

proc bugkiller_fw_task_dump*() {.exportc, cdecl.} =
  ## Dump task states for debugging (35 instructions in blob).
  ## From blob: loads puts func from s0[8], prints 2 header strings,
  ## then loops taskId 0..8 (s1=9), skipping taskId 7 (s2=7, TASK_RXU):
  ##   a0 = taskId & 0xFF, call ke_state_get(a0) => state,
  ##   a1=state, a0=taskId, call _dump_ke_task(taskId, state).
  let logFn = getLogFunc(4)
  if logFn != nil:
    logFn(2, 0, nil, 0)  # header line 1
    logFn(2, 0, nil, 0)  # header line 2
  var taskId = 0'u8
  while taskId <= TASK_LAST_EMB:
    if taskId != TASK_RXU:  # blob skips task 7 (bne s0, s2=7)
      let state = ke_state_get(taskId)
      # Call _dump_ke_task via asm ABI (a0=taskId, a1=state)
      {.emit: ["asm volatile(\"mv a1, %0\" : : \"r\"(", state, ") );"].}
      {.emit: ["asm volatile(\"mv a0, %0\" : : \"r\"(", taskId, ") );"].}
      dump_ke_task()
    inc taskId

proc dump_ke_task*() {.exportc: "_dump_ke_task", cdecl.} =
  ## Internal: dump kernel task info (78 instrs). a0=taskId, a1=state.
  ## Alloc 128-byte buf, format two columns ("Task %d" / "State %d")
  ## padded to width 10 via sprintf + 2*strlen + puts_space, print+free.
  var taskId, state: uint32
  {.emit: ["asm volatile(\"mv %0, a0\" : \"=r\"(", taskId, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", state, ") );"].}
  let allocFn = cast[proc(sz: uint32): pointer {.cdecl.}](
    blOpsFunc(0xB8))
  let buf = allocFn(128)
  if buf == nil:
    return
  var col: pointer = buf
  template formatCol(cursor: var pointer) =
    let n1 = c_strlen(cursor).int32
    let padPtr = cast[pointer](cast[uint](cursor) + n1.uint)
    let n2 = c_strlen(cursor).int32
    cursor = puts_space(padPtr, 10'i32 - n2)
  c_sprintf(col, "Task %d", taskId.cint);   formatCol(col)
  c_sprintf(col, "State %d", state.cint);   formatCol(col)
  let putsFn = blOpsFunc(8)
  if putsFn != nil:
    cast[proc(s: pointer) {.cdecl.}](putsFn)(buf)
    cast[proc(s: cstring) {.cdecl.}](putsFn)("\r\n")
  platformFree(buf)

proc puts_space*(buf: pointer, count: cint): pointer {.exportc: "_puts_space", cdecl, discardable.} =
  ## Internal: pad-column helper (a0=buf, a1=count). Fills buf[0..count)
  ## with ' ', null-terminates at buf[count], returns buf+count.
  var c: int32 = count
  if c < 0: c = 0
  let bufU = cast[uint](buf)
  var i: int32 = 0
  while i < c:
    cast[ptr uint8](bufU + i.uint)[] = 0x20'u8
    i += 1
  cast[ptr uint8](bufU + c.uint)[] = 0
  return cast[pointer](bufU + c.uint)

# ###########################################################################
#                  Configuration (cfg_*)
# ###########################################################################

proc cfg_api_element_dump*(dataPtr: pointer, typeId: uint32,
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
    let val = cast[ptr uint8](dataPtr)[]
    let strPtr = if val != 0: cstring"True" else: cstring"False"
    var written = c_snprintf(outputBuf, BUFSIZE, "%s", strPtr)
    return dumpFmt(written, cstring"Boolean")
  of 2:
    let val = cast[ptr int8](dataPtr)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%d", val.cint)
    return dumpFmt(written, cstring"SINT8")
  of 3:
    let val = cast[ptr uint8](dataPtr)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%u", val.cuint)
    return dumpFmt(written, cstring"UINT8")
  of 4:
    let val = cast[ptr int16](dataPtr)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%d", val.cint)
    return dumpFmt(written, cstring"SINT16")
  of 5:
    let val = cast[ptr uint16](dataPtr)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%u", val.cuint)
    return dumpFmt(written, cstring"UINT16")
  of 6:
    let val = cast[ptr int32](dataPtr)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%ld", val.clong)
    return dumpFmt(written, cstring"SINT32")
  of 7:
    let val = cast[ptr uint32](dataPtr)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%lu", val.culong)
    return dumpFmt(written, cstring"UINT32")
  of 8:
    let val = cast[ptr uint32](dataPtr)[]
    var written = c_snprintf(outputBuf, BUFSIZE, "%lu", val.culong)
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
  ## Flow: calls a log function with entry[8] (name string), then reads entry[6]
  ## (typeId halfword), entry[12] (data pointer), and dispatches by type:
  ##   typeId 1,3: sb (store unsigned byte from value[0] to data[0])
  ##   typeId 2:   sb (store signed byte from value[0] to data[0])
  ##   typeId 4:   sh (store signed halfword from value[0..1] to data[0..1])
  ##   typeId 5:   sh (store unsigned halfword from value[0..1] to data[0..1])
  ##   typeId 6,7: sw (store word from value[0..3] to data[0..3])
  ## Returns 0 always.
  if entry == nil or value == nil: return
  let cfg = cfgApiElementEntryAt(entry)
  # Log: blob calls g_bl_ops_funcs[204] with entry[8] (name string)
  let nameStr = cfg.name
  let logFnPtr = getLogFunc(204)
  if logFnPtr != nil and nameStr != nil:
    let logFn = cast[PlatformLogFunc](logFnPtr)
    logFn(1, 0, nameStr, 188)
  let typeId = cfg.typeId
  let dataPtr = cfg.data
  if dataPtr == nil: return
  let dst = cast[uint](dataPtr)
  case typeId
  of 1, 3:
    # Unsigned byte
    let v = cast[ptr uint8](value)[]
    cast[ptr uint8](dst)[] = v
  of 2:
    # Signed byte
    let v = cast[ptr int8](value)[]
    cast[ptr int8](dst)[] = v
  of 4:
    # Signed halfword
    let v = cast[ptr int16](value)[]
    cast[ptr int16](dst)[] = v
  of 5:
    # Unsigned halfword
    let v = cast[ptr uint16](value)[]
    cast[ptr uint16](dst)[] = v
  of 6, 7:
    # Word (32-bit)
    let v = cast[ptr uint32](value)[]
    cast[ptr uint32](dst)[] = v
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
  ## for data pointer, and writes the value according to the type width.
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
  #   [8..11] = name ptr, [12..15] = data ptr, [16..19] = set handler
  var entry {.noinit.}: CfgApiElementEntryView
  discard c_memset(addr entry, 0, sizeof(CfgApiElementEntryView).csize_t)
  entry.id = id
  entry.subId = subId
  entry.typeId = typeId
  # Data pointer: for cfgElements, point to the element slot
  if id < 32:
    entry.data = cast[pointer](addr cfgElements[id])
    # Blob dispatches to the set handler via a function pointer stored in
    # the config entry — indirect call (not counted as R_RISCV_CALL).
    # Mirror that by calling through a pointer variable.
    let setFn {.volatile.}: proc(entry: pointer, value: pointer) {.cdecl.} =
      cfg_api_element_general_set
    entry.setHandler = cast[pointer](setFn)
    setFn(cast[pointer](addr entry), value)
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
  var buf {.noinit.}: array[64, uint8]
  for i in 0'u32 ..< cfgCount:
    let entryAddr = cfgBase + i * 28
    # Log entry index
    printf("entry %d:", cast[pointer](i))
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
    let dataPtr = cast[ptr pointer](entryAddr + 16)[]
    let typeVal = cast[ptr uint8](entryAddr + 10)[]
    let typeName = cfg_api_element_dump(dataPtr, typeVal.uint32,
                                       cast[pointer](addr buf[0]))
    printf(" [%s]", cast[pointer](addr buf[0]))
    if typeName != nil:
      printf("    type    : %s\r\n", typeName)
    # Separator
    puts("")
  # Print footer
  puts("--- end cfg ---")

