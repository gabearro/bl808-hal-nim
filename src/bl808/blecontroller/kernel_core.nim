# Inline helpers
# ---------------------------------------------------------------------------

proc csrRead(csr: uint32): uint32 {.inline.} =
  var val: uint32
  asm """
    csrr %0, mstatus
    : "=r"(`val`)
  """
  val

proc disableInterrupts(): uint32 {.inline.} =
  ## Save mstatus, clear MIE (bit 3). Returns old mstatus.
  let old = csrRead(0x300)
  asm """
    csrci mstatus, 8
  """
  old

proc restoreInterrupts(mstatus: uint32) {.inline.} =
  asm """
    csrw mstatus, %0
    :: "r"(`mstatus`)
  """

# ---------------------------------------------------------------------------
# ======================= CO_LIST IMPLEMENTATION ===========================
# ---------------------------------------------------------------------------

proc ble_co_list_init*(list: ptr CoList) {.exportc, cdecl.} =
  ## Initialize a linked list (set first and last to nil)
  if co_list_init_patch != nil:
    let r = co_list_init_patch(0, list)
    if r != 0:
      return
  list.first = nil
  list.last = nil

proc ble_co_list_push_back*(list: ptr CoList, node: ptr CoListNode) {.exportc, cdecl.} =
  ## Push a node to the back of the list
  if co_list_push_back_patch != nil:
    let r = co_list_push_back_patch(0, list, node)
    if r != 0:
      return
  if node == nil:
    return
  if list.first == nil:
    list.first = node
  else:
    list.last.next = node
  list.last = node
  node.next = nil

proc ble_co_list_push_front*(list: ptr CoList, node: ptr CoListNode) {.exportc, cdecl.} =
  ## Push a node to the front of the list
  if co_list_push_front_patch != nil:
    let r = co_list_push_front_patch(0, list, node)
    if r != 0:
      return
  if node == nil:
    return
  node.next = list.first
  list.first = node
  if list.last == nil:
    list.last = node

proc ble_co_list_pop_front*(list: ptr CoList): ptr CoListNode {.exportc, cdecl.} =
  ## Pop the first node from the list
  var res: pointer
  if co_list_pop_front_patch != nil:
    let r = co_list_pop_front_patch(addr res, list)
    if r != 0:
      return cast[ptr CoListNode](res)
  let node = list.first
  if node == nil:
    return nil
  list.first = node.next
  if list.first == nil:
    list.last = nil
  return node

proc ble_co_list_extract*(list: ptr CoList, node: ptr CoListNode) {.exportc, cdecl.} =
  ## Extract a specific node from the list
  if co_list_extract_patch != nil:
    var found: uint8
    let r = co_list_extract_patch(addr found, list, node, 0)
    if r != 0:
      return
  if node == nil:
    return
  var cur = list.first
  var prev: ptr CoListNode = nil
  while cur != nil:
    if cur == node:
      if prev == nil:
        list.first = cur.next
      else:
        prev.next = cur.next
      if list.last == cur:
        list.last = prev
      return
    prev = cur
    cur = cur.next

proc ble_co_list_extract_after*(list: ptr CoList, prev_node: ptr CoListNode,
                                 node: ptr CoListNode) {.exportc, cdecl.} =
  ## Extract a node that is known to follow prev_node
  if co_list_extract_after_patch != nil:
    let r = co_list_extract_after_patch(0, list, prev_node, node)
    if r != 0:
      return
  if node == nil:
    return
  if prev_node == nil:
    # Node is first
    list.first = node.next
  else:
    prev_node.next = node.next
  if list.last == node:
    list.last = prev_node

proc ble_co_list_find*(list: ptr CoList, node: ptr CoListNode): bool {.exportc, cdecl.} =
  ## Check if a node is in the list
  var res: pointer
  if co_list_find_patch != nil:
    let r = co_list_find_patch(addr res, list, node)
    if r != 0:
      return cast[uint32](res) != 0
  var cur = list.first
  while cur != nil:
    if cur == node:
      return true
    cur = cur.next
  return false

proc ble_co_list_merge*(dest: ptr CoList, src: ptr CoList) {.exportc, cdecl.} =
  ## Merge src list into dest (appending src to end of dest)
  if co_list_merge_patch != nil:
    let r = co_list_merge_patch(0, dest, src)
    if r != 0:
      return
  if src.first == nil:
    return
  if dest.first == nil:
    dest.first = src.first
  else:
    dest.last.next = src.first
  dest.last = src.last
  src.first = nil
  src.last = nil

proc ble_co_list_insert_before*(list: ptr CoList, before_node: ptr CoListNode,
                                 node: ptr CoListNode) {.exportc, cdecl.} =
  ## Insert node before before_node in the list
  if co_list_insert_before_patch != nil:
    let r = co_list_insert_before_patch(0, list, before_node, node)
    if r != 0:
      return
  if node == nil:
    return
  if before_node == nil or before_node == list.first:
    # Insert at front
    node.next = list.first
    list.first = node
    if list.last == nil:
      list.last = node
    return
  var cur = list.first
  while cur != nil:
    if cur.next == before_node:
      node.next = before_node
      cur.next = node
      return
    cur = cur.next

proc ble_co_list_insert_after*(list: ptr CoList, after_node: ptr CoListNode,
                                node: ptr CoListNode) {.exportc, cdecl.} =
  ## Insert node after after_node in the list
  if co_list_insert_after_patch != nil:
    let r = co_list_insert_after_patch(0, list, after_node, node)
    if r != 0:
      return
  if node == nil:
    return
  if after_node == nil:
    # Insert at front
    node.next = list.first
    list.first = node
    if list.last == nil:
      list.last = node
    return
  node.next = after_node.next
  after_node.next = node
  if list.last == after_node:
    list.last = node

proc ble_co_list_size*(list: ptr CoList): uint32 {.exportc, cdecl.} =
  ## Return the number of elements in the list
  var res: uint32
  if co_list_size_patch != nil:
    let r = co_list_size_patch(addr res, list)
    if r != 0:
      return res
  var count: uint32 = 0
  var cur = list.first
  while cur != nil:
    inc count
    cur = cur.next
  return count

proc ble_co_list_check_size_available*(list: ptr CoList, limit: uint32): bool {.exportc, cdecl.} =
  ## Check if the list has fewer than limit elements
  var res: uint8
  if co_list_check_size_available_patch != nil:
    let r = co_list_check_size_available_patch(addr res, list, limit)
    if r != 0:
      return res != 0
  var count: uint32 = 0
  var cur = list.first
  while cur != nil:
    inc count
    if count >= limit:
      return false
    cur = cur.next
  return true

proc ble_co_list_pool_init*(list: ptr CoList, pool: pointer, elt_size: uint32,
                             count: uint32, init_cb: pointer, last_cb: pointer) {.exportc, cdecl.} =
  ## Initialize a list from a pool of fixed-size elements
  ble_co_list_init(list)
  var base = cast[uint](pool)
  for i in 0'u32 ..< count:
    let node = cast[ptr CoListNode](base)
    if init_cb != nil and i < count - 1:
      let cb = cast[proc(p: pointer, data: pointer) {.cdecl.}](init_cb)
      cb(pool, cast[pointer](base))
    if i == count - 1 and last_cb != nil:
      let cb = cast[proc(p: pointer, data: pointer) {.cdecl.}](last_cb)
      cb(pool, cast[pointer](base))
    ble_co_list_push_back(list, node)
    base += elt_size

# Patch wrappers for co_list
proc patch_ble_co_list_init*(list: ptr CoList) {.exportc: "_patch_ble_co_list_init", cdecl.} =
  list.first = nil
  list.last = nil

proc patch_ble_co_list_push_back*(list: ptr CoList, node: ptr CoListNode) {.exportc: "_patch_ble_co_list_push_back", cdecl.} =
  if node == nil:
    return
  if list.first == nil:
    list.first = node
  else:
    list.last.next = node
  list.last = node
  node.next = nil

proc patch_ble_co_list_push_front*(list: ptr CoList, node: ptr CoListNode) {.exportc: "_patch_ble_co_list_push_front", cdecl.} =
  if node == nil:
    return
  node.next = list.first
  list.first = node
  if list.last == nil:
    list.last = node

proc patch_ble_co_list_pop_front*(list: ptr CoList): ptr CoListNode {.exportc: "_patch_ble_co_list_pop_front", cdecl.} =
  let node = list.first
  if node == nil:
    return nil
  list.first = node.next
  if list.first == nil:
    list.last = nil
  return node

proc patch_ble_co_list_extract*(list: ptr CoList, node: ptr CoListNode) {.exportc: "_patch_ble_co_list_extract", cdecl.} =
  if node == nil:
    return
  var cur = list.first
  var prev: ptr CoListNode = nil
  while cur != nil:
    if cur == node:
      if prev == nil:
        list.first = cur.next
      else:
        prev.next = cur.next
      if list.last == cur:
        list.last = prev
      return
    prev = cur
    cur = cur.next

proc patch_ble_co_list_extract_after*(list: ptr CoList, prev_node: ptr CoListNode,
                                          node: ptr CoListNode) {.exportc: "_patch_ble_co_list_extract_after", cdecl.} =
  if node == nil:
    return
  if prev_node == nil:
    list.first = node.next
  else:
    prev_node.next = node.next
  if list.last == node:
    list.last = prev_node

proc patch_ble_co_list_find*(list: ptr CoList, node: ptr CoListNode): bool {.exportc: "_patch_ble_co_list_find", cdecl.} =
  var cur = list.first
  while cur != nil:
    if cur == node:
      return true
    cur = cur.next
  return false

proc patch_ble_co_list_merge*(dest: ptr CoList, src: ptr CoList) {.exportc: "_patch_ble_co_list_merge", cdecl.} =
  if src.first == nil:
    return
  if dest.first == nil:
    dest.first = src.first
  else:
    dest.last.next = src.first
  dest.last = src.last
  src.first = nil
  src.last = nil

proc patch_ble_co_list_insert_before*(list: ptr CoList, before_node: ptr CoListNode,
                                          node: ptr CoListNode) {.exportc: "_patch_ble_co_list_insert_before", cdecl.} =
  if node == nil:
    return
  if before_node == nil or before_node == list.first:
    node.next = list.first
    list.first = node
    if list.last == nil:
      list.last = node
    return
  var cur = list.first
  while cur != nil:
    if cur.next == before_node:
      node.next = before_node
      cur.next = node
      return
    cur = cur.next

proc patch_ble_co_list_insert_after*(list: ptr CoList, after_node: ptr CoListNode,
                                         node: ptr CoListNode) {.exportc: "_patch_ble_co_list_insert_after", cdecl.} =
  if node == nil:
    return
  if after_node == nil:
    node.next = list.first
    list.first = node
    if list.last == nil:
      list.last = node
    return
  node.next = after_node.next
  after_node.next = node
  if list.last == after_node:
    list.last = node

proc patch_ble_co_list_size*(list: ptr CoList): uint32 {.exportc: "_patch_ble_co_list_size", cdecl.} =
  var count: uint32 = 0
  var cur = list.first
  while cur != nil:
    inc count
    cur = cur.next
  return count

proc patch_ble_co_list_check_size_available*(list: ptr CoList, limit: uint32): bool {.exportc: "_patch_ble_co_list_check_size_available", cdecl.} =
  var count: uint32 = 0
  var cur = list.first
  while cur != nil:
    inc count
    if count >= limit:
      return false
    cur = cur.next
  return true

# ---------------------------------------------------------------------------
# ======================== CO_BDADDR =======================================
# ---------------------------------------------------------------------------

proc co_bdaddr_set*(dest: ptr BdAddr, src: ptr BdAddr) {.exportc, cdecl.} =
  discard c_memcpy(dest, src, 6)

proc co_bdaddr_compare*(a: ptr BdAddr, b: ptr BdAddr): bool {.exportc, cdecl.} =
  return c_memcmp(a, b, 6) == 0

# ---------------------------------------------------------------------------
# ======================== KE_EVENT ========================================
# ---------------------------------------------------------------------------

proc patch_ble_ke_event_init*() {.exportc: "_patch_ble_ke_event_init", cdecl.} =
  discard c_memset(addr ke_event_slots[0], 0, (sizeof(KeEventSlot) * KE_EVENT_MAX).csize_t)

proc ble_ke_event_init*() {.exportc, cdecl.} =
  if ke_event_init_patch != nil:
    let r = ke_event_init_patch(0)
    if r != 0:
      return
  discard c_memset(addr ke_event_slots[0], 0, (sizeof(KeEventSlot) * KE_EVENT_MAX).csize_t)

proc patch_ble_ke_event_callback_set*(idx: uint8, cb: KeEventCallback) {.exportc: "_patch_ble_ke_event_callback_set", cdecl.} =
  if idx < KE_EVENT_MAX and cb != nil:
    ke_event_slots[idx].callback = cb

proc ble_ke_event_callback_set*(idx: uint8, cb: KeEventCallback) {.exportc, cdecl.} =
  if ke_event_callback_set_patch != nil:
    var status: uint8
    let r = ke_event_callback_set_patch(addr status, idx, cb)
    if r != 0:
      return
  if idx < KE_EVENT_MAX and cb != nil:
    ke_event_slots[idx].callback = cb

proc patch_ble_ke_event_set*(idx: uint8) {.exportc: "_patch_ble_ke_event_set", cdecl.} =
  if idx < KE_EVENT_MAX:
    let old = disableInterrupts()
    ke_event_field = ke_event_field or (1'u32 shl idx)
    restoreInterrupts(old)

proc ble_ke_event_set*(idx: uint8) {.exportc, cdecl.} =
  if ke_event_set_patch != nil:
    let r = ke_event_set_patch(0, idx)
    if r != 0:
      return
  if idx < KE_EVENT_MAX:
    let old = disableInterrupts()
    ke_event_field = ke_event_field or (1'u32 shl idx)
    restoreInterrupts(old)

proc patch_ble_ke_event_clear*(idx: uint8) {.exportc: "_patch_ble_ke_event_clear", cdecl.} =
  if idx < KE_EVENT_MAX:
    let old = disableInterrupts()
    ke_event_field = ke_event_field and not (1'u32 shl idx)
    restoreInterrupts(old)

proc ble_ke_event_clear*(idx: uint8) {.exportc, cdecl.} =
  if ke_event_clear_patch != nil:
    let r = ke_event_clear_patch(0, idx)
    if r != 0:
      return
  if idx < KE_EVENT_MAX:
    let old = disableInterrupts()
    ke_event_field = ke_event_field and not (1'u32 shl idx)
    restoreInterrupts(old)

proc ble_ke_event_get*(idx: uint8): bool {.exportc, cdecl.} =
  ## Check if an event is set
  if idx >= KE_EVENT_MAX:
    return false
  return (ke_event_field and (1'u32 shl idx)) != 0

proc patch_ble_ke_event_get_all*(): uint32 {.exportc: "_patch_ble_ke_event_get_all", cdecl.} =
  return ke_event_field

proc ble_ke_event_get_all*(): uint32 {.exportc, cdecl.} =
  if ke_event_get_all_patch != nil:
    var res: uint32
    let r = ke_event_get_all_patch(addr res)
    if r != 0:
      return res
  return ke_event_field

proc patch_ble_ke_event_flush*() {.exportc: "_patch_ble_ke_event_flush", cdecl.} =
  ke_event_field = 0

proc ble_ke_event_flush*() {.exportc, cdecl.} =
  if ke_event_flush_patch != nil:
    let r = ke_event_flush_patch()
    if r != 0:
      return
  ke_event_field = 0

proc bleKeEventYieldNeeded(drained, field: uint32): bool {.inline.} =
  drained >= BleKeEventDrainLimit and field != 0

proc patch_ble_ke_event_schedule*() {.exportc: "_patch_ble_ke_event_schedule", cdecl.} =
  var field = ke_event_field
  var drained = 0'u32
  while field != 0:
    # Find lowest set bit
    var bit = 0'u8
    var tmp = field
    while (tmp and 1) == 0:
      tmp = tmp shr 1
      inc bit
    # Clear and dispatch
    let old = disableInterrupts()
    ke_event_field = ke_event_field and not (1'u32 shl bit)
    restoreInterrupts(old)
    if bit < KE_EVENT_MAX and ke_event_slots[bit].callback != nil:
      ke_event_slots[bit].callback(bit)
    inc drained
    field = ke_event_field
    if bleKeEventYieldNeeded(drained, field):
      inc nim_ble_ke_event_yield_count
      nim_ble_ke_event_yield_field = field
      return

proc ble_ke_event_schedule*() {.exportc, cdecl.} =
  if ke_event_schedule_patch != nil:
    let r = ke_event_schedule_patch(0)
    if r != 0:
      return
  patch_ble_ke_event_schedule()

proc ble_ke_get_event_field*(): uint32 {.exportc, cdecl.} =
  return ke_event_field

# ---------------------------------------------------------------------------
# ======================== KE_MEM ==========================================
# ---------------------------------------------------------------------------

var
  ke_mem_pool*: array[KE_MEM_POOL_MAX, uint8]  ## Pool tracking

proc patch_ble_ke_mem_is_in_heap*(p: pointer): bool {.exportc: "_patch_ble_ke_mem_is_in_heap", cdecl.} =
  let addr_val = cast[uint](p)
  let heap_start = cast[uint](ke_mem_heap)
  let heap_end = cast[uint](ke_mem_heap_end)
  return addr_val >= heap_start and addr_val < heap_end

proc ble_ke_mem_is_in_heap*(p: pointer): bool {.exportc, cdecl.} =
  if ke_mem_is_in_heap_patch != nil:
    var res: uint8
    let r = ke_mem_is_in_heap_patch(addr res, p)
    if r != 0:
      return res != 0
  return patch_ble_ke_mem_is_in_heap(p)

proc patch_ble_ke_mem_init*() {.exportc: "_patch_ble_ke_mem_init", cdecl.} =
  ## Initialize kernel memory subsystem
  discard c_memset(addr ke_mem_pool[0], 0, KE_MEM_POOL_MAX.csize_t)

proc ble_ke_mem_init*() {.exportc, cdecl.} =
  if ke_mem_init_patch != nil:
    let r = ke_mem_init_patch(0)
    if r != 0:
      return
  patch_ble_ke_mem_init()

proc ble_ke_mem_is_empty*(): bool {.exportc, cdecl.} =
  ## Check if the memory heap is empty (all freed)
  ## Walk free list to see if total free equals heap size
  return true  # Simplified: report empty when no allocations tracked

proc ble_ke_check_malloc*(): uint32 {.exportc, cdecl.} =
  ## Debug: return number of allocated blocks
  return 0

# ---------------------------------------------------------------------------
# ======================== KE_MALLOC / FREE ================================
# ---------------------------------------------------------------------------

proc patch_ble_ke_malloc*(size: uint32, mtype: uint32): pointer {.exportc: "_patch_ble_ke_malloc", cdecl.} =
  ## Allocate memory from kernel heap
  ## Uses simple first-fit free-list allocator
  ## Each block has a 4-byte header: [size:31 | free:1]
  var res: pointer
  if ke_malloc_patch != nil:
    let r = ke_malloc_patch(addr res, size, mtype)
    if r != 0:
      return res
  # Fallback to C malloc
  proc cmalloc(s: csize_t): pointer {.importc: "malloc", cdecl.}
  return cmalloc(size.csize_t)

proc ble_ke_malloc*(size: uint32, mtype: uint32): pointer {.exportc, cdecl.} =
  if ke_malloc_patch != nil:
    var res: pointer
    let r = ke_malloc_patch(addr res, size, mtype)
    if r != 0:
      return res
  return patch_ble_ke_malloc(size, mtype)

proc patch_ble_ke_free*(p: pointer) {.exportc: "_patch_ble_ke_free", cdecl.} =
  if p == nil:
    return
  if ke_free_patch != nil:
    discard ke_free_patch(0, p)
    return
  proc cfree(p: pointer) {.importc: "free", cdecl.}
  cfree(p)

proc ble_ke_free*(p: pointer) {.exportc, cdecl.} =
  if ke_free_patch != nil:
    discard ke_free_patch(0, p)
    return
  patch_ble_ke_free(p)

proc patch_ble_ke_is_free*(p: pointer): bool {.exportc: "_patch_ble_ke_is_free", cdecl.} =
  if p == nil:
    return true
  if ke_is_free_patch != nil:
    var res: uint8
    discard ke_is_free_patch(addr res, p)
    return res != 0
  return false

proc ble_ke_is_free*(p: pointer): bool {.exportc, cdecl.} =
  if ke_is_free_patch != nil:
    var res: uint8
    let r = ke_is_free_patch(addr res, p)
    if r != 0:
      return res != 0
  return patch_ble_ke_is_free(p)

proc ble_controller_trace_malloc_init*() {.exportc, cdecl.} =
  discard c_memset(addr trace_malloc_info[0], 0, sizeof(trace_malloc_info).csize_t)
  trace_malloc_idx = 0

proc trace_malloc*(size: uint32, p: pointer) {.exportc, cdecl.} =
  if trace_malloc_idx < 16:
    trace_malloc_info[trace_malloc_idx] = cast[uint32](p)
    inc trace_malloc_idx

proc trace_free*(p: pointer) {.exportc, cdecl.} =
  for i in 0 ..< 16:
    if trace_malloc_info[i] == cast[uint32](p):
      trace_malloc_info[i] = 0
      break

proc ble_ke_debug_mem_info*() {.exportc, cdecl.} =
  ## Debug: print memory info (no-op in production)
  discard

# ---------------------------------------------------------------------------
# ======================== KE_MSG ==========================================
# ---------------------------------------------------------------------------

proc getMsgHeader(param: pointer): ptr KeMsgHeader {.inline.} =
  ## Given a pointer to the message parameters, get the header
  let envelope = cast[ptr KeMsgEnvelope](
    cast[uint](param) - offsetof(KeMsgEnvelope, param).uint)
  addr envelope.header

proc getMsgParam(hdr: ptr KeMsgHeader): pointer {.inline.} =
  let envelope = cast[ptr KeMsgEnvelope](hdr)
  cast[pointer](addr envelope.param[0])

proc keStateHandlerAt(base: ptr KeStateHandler, idx: uint8): ptr KeStateHandler {.inline.} =
  addr cast[ptr UncheckedArray[KeStateHandler]](base)[idx]

proc keMsgHandlerEntryAt(base: ptr KeStateMsgHandler,
                         idx: uint16): ptr KeStateMsgHandler {.inline.} =
  addr cast[ptr UncheckedArray[KeStateMsgHandler]](base)[idx]

template emRxDescTableAt(base: uint32): ptr UncheckedArray[EmBufRxDesc] =
  cast[ptr UncheckedArray[EmBufRxDesc]](base)

template emTxDescTableAt(base: uint32): ptr UncheckedArray[EmBufTxDesc] =
  cast[ptr UncheckedArray[EmBufTxDesc]](base)

template emRxFreeTable(): ptr UncheckedArray[EmBufRxFreeSlot] =
  cast[ptr UncheckedArray[EmBufRxFreeSlot]](bleEmPointer(0x35C'u16))

proc emRxDescAt(base: uint32, idx: uint16): ptr EmBufRxDesc {.inline.} =
  addr emRxDescTableAt(base)[idx]

proc emTxDescAt(base: uint32, idx: uint16): ptr EmBufTxDesc {.inline.} =
  addr emTxDescTableAt(base)[idx]

proc emRxFreeSlotAt(idx: uint16): ptr EmBufRxFreeSlot {.inline.} =
  addr emRxFreeTable()[idx]

proc emRxFreeStatusField(idx: uint16): ptr uint16 {.inline.} =
  addr emRxFreeSlotAt(idx).status

proc emRxBufferPointerField(idx: uint16): ptr uint16 {.inline.} =
  addr emRxFreeSlotAt(idx).buf_ptr

proc emTxPoolDescForBufferOffset(offset: uint32): ptr EmBufTxDesc {.inline.} =
  let txDescBase = BLE_EM_BASE + 0x264'u32
  emTxDescAt(txDescBase, uint16(offset div EM_BUF_TX_DATA_SIZE.uint32))

when defined(bl808m0) and bl808BleNimConnectionEnabled and
    bl808BleNimManualConnTx:
  proc handleNimLldMessage(param: pointer): bool =
    if param == nil:
      return false
    let hdr = getMsgHeader(param)
    let p = cast[ptr UncheckedArray[uint8]](param)
    let conhdl = uint16((hdr.dest_id shr 8) and 0x00FF'u16)
    case hdr.id
    of 523'u16:
      let pduLen = uint16(p[2])
      let dataOff = uint16(p[4]) or (uint16(p[5]) shl 8)
      nimLlcpRecordRx(0'u16, dataOff, pduLen)
      if pduLen > 0'u16:
        let opcode = btbleEmRead8(dataOff)
        let reason =
          if pduLen > 1'u16: btbleEmRead8(dataOff + 1'u16)
          else: NimLlcpDefaultReason
        if nimLlcpRxPduValid(opcode, pduLen):
          inc nim_llcp_rx_count
          nim_llcp_last_opcode = opcode.uint32
          nimLlcpObserveEm(conhdl, dataOff, uint8(pduLen))
          nimLlcpRespond(conhdl, opcode, reason)
        else:
          nimLlcpRecordMalformed(0'u16, opcode, pduLen)
      true
    of 525'u16:
      let dataOff = uint16(p[0]) or (uint16(p[1]) shl 8)
      let pduLen = uint16(p[2]) or (uint16(p[3]) shl 8)
      let llid = p[4] and 0x03'u8
      if llid == NimDataLlIdControl and pduLen > 0'u16:
        nimLlcpRecordRx(uint16(llid), dataOff, pduLen)
        let opcode = btbleEmRead8(dataOff)
        let reason =
          if pduLen > 1'u16: btbleEmRead8(dataOff + 1'u16)
          else: NimLlcpDefaultReason
        if nimLlcpRxPduValid(opcode, pduLen):
          inc nim_llcp_rx_count
          nim_llcp_last_opcode = opcode.uint32
          nimLlcpObserveEm(conhdl, dataOff, uint8(pduLen))
          nimLlcpRespond(conhdl, opcode, reason)
        else:
          nimLlcpRecordMalformed(uint16(llid), opcode, pduLen)
      true
    else:
      false

proc patch_ble_ke_msg_alloc*(id: KeMsgId, dest_id: KeTaskId,
                                 src_id: KeTaskId, param_len: uint16): pointer {.exportc: "_patch_ble_ke_msg_alloc", cdecl.} =
  ## Allocate a kernel message with header + param space
  let total = param_len.uint32 + offsetof(KeMsgEnvelope, param).uint32
  let mem = ble_ke_malloc(total, 0)
  if mem == nil:
    return nil
  let hdr = cast[ptr KeMsgHeader](mem)
  hdr.next = cast[ptr KeMsgHeader](cast[uint32](0xFFFFFFFF'u32))  # -1 sentinel
  hdr.id = id
  hdr.dest_id = dest_id
  hdr.src_id = src_id
  hdr.param_len = param_len
  let param = getMsgParam(hdr)
  discard c_memset(param, 0, param_len.csize_t)
  return param

proc ble_ke_msg_alloc*(id: KeMsgId, dest_id: KeTaskId,
                        src_id: KeTaskId, param_len: uint16): pointer {.exportc, cdecl.} =
  if ke_msg_alloc_patch != nil:
    var res: pointer
    let r = ke_msg_alloc_patch(addr res, id, dest_id, src_id, param_len)
    if r != 0:
      return res
  return patch_ble_ke_msg_alloc(id, dest_id, src_id, param_len)

proc patch_ble_ke_msg_send*(param: pointer) {.exportc: "_patch_ble_ke_msg_send", cdecl.} =
  ## Send a kernel message (enqueue to destination)
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    when bl808BleNimManualConnTx:
      if handleNimLldMessage(param):
        ble_ke_free(getMsgHeader(param))
        return
  let old = disableInterrupts()
  let hdr = getMsgHeader(param)
  ble_co_list_push_back(addr ke_msg_queue, cast[ptr CoListNode](hdr))
  restoreInterrupts(old)
  ble_ke_event_set(BleKeMessageEventId)

proc ble_ke_msg_send*(param: pointer) {.exportc, cdecl.} =
  if ke_msg_send_patch != nil:
    let r = ke_msg_send_patch(0, param)
    if r != 0:
      return
  patch_ble_ke_msg_send(param)

proc patch_ble_ke_msg_get_sent_num*(id: KeMsgId): uint32 {.exportc: "_patch_ble_ke_msg_get_sent_num", cdecl.} =
  ## Count messages with given id in the queue
  var count: uint32 = 0
  var cur = cast[ptr KeMsgHeader](ke_msg_queue.first)
  while cur != nil:
    if cur.id == id:
      inc count
    cur = cast[ptr KeMsgHeader](cur.next)
  return count

proc ble_ke_msg_get_sent_num*(id: KeMsgId): uint32 {.exportc, cdecl.} =
  if ke_msg_get_sent_num_patch != nil:
    var res: uint32
    let r = ke_msg_get_sent_num_patch(addr res, id)
    if r != 0:
      return res
  return patch_ble_ke_msg_get_sent_num(id)

proc patch_ble_ke_msg_send_basic*(id: KeMsgId, dest_id: KeTaskId,
                                      src_id: KeTaskId) {.exportc: "_patch_ble_ke_msg_send_basic", cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if id == 0x0213'u16: # LLD_DISC_IND routed to LLC in the vendor task table.
      discard dest_id
      discard src_id
      noteNimPeripheralDisconnectedFrom(3'u32, NimLlcpDefaultReason)
      return
  let param = ble_ke_msg_alloc(id, dest_id, src_id, 0)
  if param != nil:
    ble_ke_msg_send(param)

proc ble_ke_msg_send_basic*(id: KeMsgId, dest_id: KeTaskId,
                             src_id: KeTaskId) {.exportc, cdecl.} =
  if ke_msg_send_basic_patch != nil:
    let r = ke_msg_send_basic_patch(0, id, dest_id, src_id)
    if r != 0:
      return
  patch_ble_ke_msg_send_basic(id, dest_id, src_id)

when defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral):
  type SchArbStartCb = proc(elt: pointer) {.cdecl.}

  const bl808BleNimDeferArbCallbacks* {.booldefine.}: bool = true

  proc runNimArbCallback(cb: SchArbStartCb, elt: pointer) =
    cb(elt)

  when bl808BleNimConnectionEnabled:
    var nim_conn_arb_pending_cb: SchArbStartCb
    var nim_conn_arb_pending_elt: pointer

    proc nimArbCallbackPending(): bool {.inline.} =
      nim_conn_arb_pending_cb != nil

    proc queueNimArbCallback(cb: SchArbStartCb, elt: pointer): bool =
      if nim_conn_arb_pending_cb != nil:
        return false
      nim_conn_arb_pending_cb = cb
      nim_conn_arb_pending_elt = elt
      true

    proc serviceNimArbCallbacks() =
      var drained = 0'u32
      while drained < BleArbCallbackDrainLimit and nimArbCallbackPending():
        let cb = nim_conn_arb_pending_cb
        let elt = nim_conn_arb_pending_elt
        nim_conn_arb_pending_cb = nil
        nim_conn_arb_pending_elt = nil
        if cb != nil:
          runNimArbCallback(cb, elt)
        inc drained
      if nimArbCallbackPending():
        inc nim_ble_arb_callback_yield_count

  proc nimLldRxDescAddr(idx: uint8): uint32 {.inline.} =
    BTBLE_EM_BASE + btbleRxDescOffset(uint32(idx))

  proc lld_rxdesc_buf_ready*(buf: uint16): uint8 {.exportc, cdecl.} =
    let pending = lld_env[16]
    if pending == 0'u8:
      return 0
    var idx = 0'u8
    var mask = pending
    while (mask and 1'u8) == 0'u8:
      inc idx
      mask = mask shr 1
    btbleRxDescSetDataOffset(nimLldRxDescAddr(idx), buf)
    lld_env[16] = pending and not (1'u8 shl idx)
    1

  proc lld_rxdesc_check*(idx: uint8): pointer {.exportc, cdecl.} =
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x6000'u32 or idx.uint32
    inc nim_lld_rx_check_count
    for step in 0'u32 ..< 8'u32:
      let cur = lld_env[14] and 0x07'u8
      let desc = nimLldRxDescAddr(cur)
      let status = btbleRxDescStatus(desc)
      let header = btbleRxDescHeader(desc)
      let meta = btbleRxDescMeta(desc)
      nim_lld_rx_last_idx = idx.uint32
      nim_lld_rx_last_env_idx = cur.uint32
      nim_lld_rx_last_status = status.uint32
      nim_lld_rx_last_header = header.uint32
      nim_lld_rx_last_meta = meta.uint32
      if (status and BtbleRxDescDone) == 0:
        break
      if header == 0'u16:
        btbleRxDescClearDone(desc, status)
        lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
        inc nim_lld_rx_free_count
        continue
      let pduType = uint8(header and 0x000F'u16)
      let dataLlId = uint8(header and 0x0003'u16)
      let advLen = advPayloadLen(header)
      let connLen = connDataPayloadLen(header)
      var scanDescObserved = false
      var scanDescUnsupported = false
      when defined(bl808m0):
        if nim_scan_enabled and advLen > 0'u8:
          scanDescObserved = true
          if advLen >= 6'u8 and
              (pduType == 0x00'u8 or pduType == 0x02'u8 or
               pduType == 0x04'u8 or pduType == 0x06'u8):
            sendLeAdvertisingReportFromRxDesc(header, btbleRxDescDataOffset(desc))
          else:
            scanDescUnsupported = true
      when bl808BleNimConnectionEnabled:
        if pduType == 0x05'u8 and advLen == 34'u8:
          # Match vendor lld_adv_frm_isr timing extraction.
          btbleRecordConnectDescTiming(desc)
          let rxFine = btbleAdvRxFine(desc)
          let rxClock = btbleAdvRxClock(desc)
          var connectPdu: array[34, uint8]
          let dataOff = btbleRxDescDataOffset(desc)
          let payload = btbleEmPayload(dataOff)
          for j in 0 ..< connectPdu.len:
            connectPdu[j] = payload[j]
          btbleRxDescClearDone(desc, status)
          noteNimRxDescConsumed(cur.uint32)
          inc nim_lld_rx_free_count
          handleNimConnectInd(uint8(cur and 0x07'u8),
            cast[ptr UncheckedArray[uint8]](addr connectPdu[0]),
            header, rxClock, rxFine)
          nimConnMark(0x250'u32)
          continue
        when bl808BleNimManualConnTx:
          if nim_conn_started and not connRxStatusAcceptsPayload(status):
            rejectConnRxDescriptor(desc, status, header, cur.uint32)
            continue
          if nim_conn_started and not validConnDataHeader(header):
            btbleRxDescReleaseLink(desc, status)
            noteNimRxDescConsumed(cur.uint32)
            inc nim_lld_rx_free_count
            continue
          if nim_conn_started:
            noteNimPeripheralConnected(activeNimConnectionHandle())
          if nim_conn_started and
              dataLlId == NimDataLlIdControl and connLen > 0'u8:
            let conhdl = activeNimConnectionHandle()
            let dataOff = btbleRxDescDataOffset(desc)
            nimLlcpRecordRx(header, dataOff, connLen.uint16)
            let opcode = btbleEmRead8(dataOff)
            let reason =
              if connLen > 1'u8: btbleEmRead8(dataOff + 1'u16)
              else: NimLlcpDefaultReason
            if nimLlcpRxPduValid(opcode, connLen.uint16):
              inc nim_llcp_rx_count
              nim_llcp_last_opcode =
                (uint32(header) shl 16) or opcode.uint32
              nimLlcpObserveEm(conhdl, dataOff, connLen)
              nimLlcpRespond(conhdl, opcode, reason)
            else:
              nimLlcpRecordMalformed(header, opcode, connLen.uint16)
            btbleRxDescReleaseLink(desc, status)
            noteNimRxDescConsumed(cur.uint32)
            inc nim_lld_rx_free_count
            continue
      if pduType == 0x03'u8 and advLen == 12'u8:
        btbleRxDescClearDone(desc, status)
        lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
        inc nim_lld_rx_free_count
        continue
      if scanDescUnsupported:
        btbleRxDescClearDone(desc, status)
        lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
        inc nim_lld_rx_free_count
        continue
      let descIdx = uint8((meta shr 11) and 0x001F'u16)
      if descIdx == (idx and 0x1F'u8):
        when bl808BleNimManualConnTx:
          if nim_conn_started and not connRxStatusAcceptsPayload(status):
            rejectConnRxDescriptor(desc, status, header, cur.uint32)
            continue
          if nim_conn_started and not validConnDataHeader(header):
            btbleRxDescReleaseLink(desc, status)
            noteNimRxDescConsumed(cur.uint32)
            inc nim_lld_rx_free_count
            continue
          if nim_conn_started:
            noteNimPeripheralConnected(activeNimConnectionHandle())
          if dataLlId == NimDataLlIdControl and connLen > 0'u8:
            let conhdl = activeNimConnectionHandle()
            let dataOff = btbleRxDescDataOffset(desc)
            nimLlcpRecordRx(header, dataOff, connLen.uint16)
            let opcode = btbleEmRead8(dataOff)
            let reason =
              if connLen > 1'u8: btbleEmRead8(dataOff + 1'u16)
              else: NimLlcpDefaultReason
            if nimLlcpRxPduValid(opcode, connLen.uint16):
              nim_llcp_last_opcode =
                (uint32(dataLlId) shl 24) or (uint32(connLen) shl 16) or
                opcode.uint32
              inc nim_llcp_rx_count
              nimLlcpObserveEm(conhdl, dataOff, connLen)
              nimLlcpRespond(conhdl, opcode, reason)
            else:
              nimLlcpRecordMalformed(header, opcode, connLen.uint16)
        nim_lld_rx_desc_idx = cur
        nim_lld_rx_desc_active = 1'u8
        inc nim_lld_rx_check_hit_count
        when defined(bl808BleBridgeDiag):
          nim_bridge_stage = 0x6100'u32 or cur.uint32
        return cast[pointer](desc)
      if scanDescObserved:
        btbleRxDescClearDone(desc, status)
        lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
        inc nim_lld_rx_free_count
        continue
      break
    inc nim_lld_rx_check_miss_count
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x6200'u32 or idx.uint32
    nil

  proc lld_rxdesc_free*(desc: pointer) {.exportc, cdecl.} =
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x6300'u32 or
        (cast[uint32](desc) and 0x000000FF'u32)
    discard desc
    inc nim_lld_rx_free_count
    let cur = lld_env[14] and 0x07'u8
    let descAddr = nimLldRxDescAddr(cur)
    let status = btbleRxDescStatus(descAddr)
    btbleRxDescClearDone(descAddr, status)
    lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
    nim_lld_rx_desc_idx = lld_env[14]
    nim_lld_rx_desc_active = 0'u8

  when bl808BleNimManualConnTx:
    proc serviceNimConnectionLlcpRxDescriptors() =
      if not nim_conn_started:
        return
      var handledLlcp = false
      let startIdx = uint32(lld_env[14] and 0x07'u8)
      for step in 0'u32 ..< 8'u32:
        let cur = (startIdx + step) and 0x07'u32
        let desc = nimLldRxDescAddr(uint8(cur))
        let status = btbleRxDescStatus(desc)
        if (status and BtbleRxDescDone) == 0:
          break
        let header = btbleRxDescHeader(desc)
        let meta = btbleRxDescMeta(desc)
        nim_lld_rx_last_idx = cur
        nim_lld_rx_last_env_idx = uint32(lld_env[14] and 0x07'u8)
        nim_lld_rx_last_status = status.uint32
        nim_lld_rx_last_header = header.uint32
        nim_lld_rx_last_meta = meta.uint32
        if not connRxStatusAcceptsPayload(status):
          rejectConnRxDescriptor(desc, status, header, cur)
          continue
        if not validConnDataHeader(header):
          btbleRxDescReleaseLink(desc, status)
          noteNimRxDescConsumed(cur)
          inc nim_lld_rx_free_count
          continue
        let conhdl = activeNimConnectionHandle()
        noteNimPeripheralConnected(conhdl)
        let dataLlId = uint8(header and 0x0003'u16)
        let pduLen = connDataPayloadLen(header)
        var payloadFresh = true
        when bl808BleNimPureConnection:
          if dataLlId != 0'u8:
            let rxFine = btbleConnRxFine(desc)
            let rxClock = btbleConnRxClock(desc)
            nimConnObserveRxHeader(header, rxClock, rxFine)
            payloadFresh = nim_conn_state.rxPayloadFresh
        if dataLlId == NimDataLlIdControl and pduLen > 0'u8:
          let dataOff = btbleRxDescDataOffset(desc)
          if payloadFresh:
            nimLlcpRecordRx(header, dataOff, pduLen.uint16)
            let opcode = btbleEmRead8(dataOff)
            let reason =
              if pduLen > 1'u8: btbleEmRead8(dataOff + 1'u16)
              else: NimLlcpDefaultReason
            if nimLlcpRxPduValid(opcode, pduLen.uint16):
              inc nim_llcp_rx_count
              handledLlcp = true
              nim_llcp_last_opcode =
                (uint32(header) shl 16) or opcode.uint32
              nimLlcpObserveEm(conhdl, dataOff, pduLen)
              nimLlcpRespond(conhdl, opcode, reason)
            else:
              nimLlcpRecordMalformed(header, opcode, pduLen.uint16)
          btbleRxDescReleaseLink(desc, status)
          if (lld_env[14] and 0x07'u8) == uint8(cur and 0x07'u32):
            noteNimRxDescConsumed(cur)
          inc nim_lld_rx_free_count
        elif (dataLlId == NimDataLlIdStart or
              dataLlId == NimDataLlIdContinuation) and pduLen > 0'u8:
          let dataOff = btbleRxDescDataOffset(desc)
          if payloadFresh:
            if sendHostAclData(conhdl, dataLlId, dataOff, pduLen):
              inc nim_acl_rx_count
            else:
              inc nim_acl_rx_drop_count
          btbleRxDescReleaseLink(desc, status)
          if (lld_env[14] and 0x07'u8) == uint8(cur and 0x07'u32):
            noteNimRxDescConsumed(cur)
          inc nim_lld_rx_free_count
        else:
          btbleRxDescReleaseLink(desc, status)
          if (lld_env[14] and 0x07'u8) == uint8(cur and 0x07'u32):
            noteNimRxDescConsumed(cur)
          inc nim_lld_rx_free_count
          continue
      if not handledLlcp:
        nimLlcpTrySendStartup(activeNimConnectionHandle())

  when not defined(bl808m0):
    proc sch_slice_per_add*(sliceType: uint8, conhdl: uint8,
                            interval: uint32, anchor: uint32,
                            offset: uint16): uint8 {.exportc, cdecl.} =
      when defined(bl808m0) and
          bl808BleNimConnectionEnabled:
        inc nim_slice_add_count
        nim_slice_last_type_con =
          (uint32(sliceType) shl 16) or uint32(conhdl)
        nim_slice_last_interval = interval
        nim_slice_last_anchor = anchor
        nim_slice_last_offset = offset.uint32
      discard sliceType
      discard conhdl
      discard interval
      discard anchor
      discard offset
      0

    proc sch_slice_per_remove*(sliceType: uint8,
                               conhdl: uint8): uint8 {.exportc, cdecl.} =
      when defined(bl808m0) and
          bl808BleNimConnectionEnabled:
        inc nim_slice_remove_count
        nim_slice_last_type_con =
          (uint32(sliceType) shl 16) or uint32(conhdl)
      discard sliceType
      discard conhdl
      0

proc ble_ke_msg_fobflbard*(param: pointer, dest_id: KeTaskId) {.exportc, cdecl.} =
  ## Forward a message to a new destination
  let hdr = getMsgHeader(param)
  hdr.dest_id = dest_id
  ble_ke_msg_send(param)

proc ble_ke_msg_fobflbard_new_id*(param: pointer, id: KeMsgId, dest_id: KeTaskId) {.exportc, cdecl.} =
  ## Forward with new msg id and destination
  let hdr = getMsgHeader(param)
  hdr.id = id
  hdr.dest_id = dest_id
  ble_ke_msg_send(param)

proc patch_ble_ke_msg_free*(msg: ptr KeMsgHeader) {.exportc: "_patch_ble_ke_msg_free", cdecl.} =
  if msg != nil:
    ble_ke_free(msg)

proc ble_ke_msg_free*(msg: ptr KeMsgHeader) {.exportc, cdecl.} =
  if ke_msg_free_patch != nil:
    discard ke_msg_free_patch(0, msg)
    return
  patch_ble_ke_msg_free(msg)

proc ble_ke_msg_dest_id_get*(param: pointer): KeTaskId {.exportc, cdecl.} =
  let hdr = getMsgHeader(param)
  return hdr.dest_id

proc ble_ke_msg_src_id_get*(param: pointer): KeTaskId {.exportc, cdecl.} =
  let hdr = getMsgHeader(param)
  return hdr.src_id

proc ble_ke_msg_in_queue*(param: pointer): bool {.exportc, cdecl.} =
  ## Check if message is currently in the queue (next != -1)
  let hdr = getMsgHeader(param)
  return cast[uint32](hdr.next) != 0xFFFFFFFF'u32

proc ble_ke_msg_discard*(msgid: KeMsgId, dest_id: KeTaskId,
                          src_id: KeTaskId, param: pointer): int32 {.exportc, cdecl.} =
  ## Default message handler: discard (consume the message)
  return KeMsgConsumed

proc ble_ke_msg_save*(msgid: KeMsgId, dest_id: KeTaskId,
                       src_id: KeTaskId, param: pointer): int32 {.exportc, cdecl.} =
  ## Default message handler: save (keep in queue)
  return KeMsgSaved

# ---------------------------------------------------------------------------
# ======================== KE_QUEUE ========================================
# ---------------------------------------------------------------------------

type
  QueueCmpFunc* = proc(a: ptr CoListNode, b: ptr CoListNode, extra: pointer): bool {.cdecl.}

proc patch_ble_ke_queue_extract*(queue: ptr CoList, cmp: QueueCmpFunc,
                                     arg: pointer): ptr CoListNode {.exportc: "_patch_ble_ke_queue_extract", cdecl.} =
  ## Extract first element matching comparison from queue
  var cur = queue.first
  var prev: ptr CoListNode = nil
  while cur != nil:
    if cmp(cur, cast[ptr CoListNode](arg), nil):
      if prev == nil:
        queue.first = cur.next
      else:
        prev.next = cur.next
      if queue.last == cur:
        queue.last = prev
      return cur
    prev = cur
    cur = cur.next
  return nil

proc ble_ke_queue_extract*(queue: ptr CoList, cmp: QueueCmpFunc,
                            arg: pointer): ptr CoListNode {.exportc, cdecl.} =
  if ke_queue_extract_patch != nil:
    discard ke_queue_extract_patch(0, queue, cast[pointer](cmp), arg)
  return patch_ble_ke_queue_extract(queue, cmp, arg)

proc patch_ble_ke_queue_insert*(queue: ptr CoList, node: ptr CoListNode,
                                    cmp: QueueCmpFunc) {.exportc: "_patch_ble_ke_queue_insert", cdecl.} =
  ## Insert into sorted queue
  var cur = queue.first
  var prev: ptr CoListNode = nil
  while cur != nil:
    if cmp(node, cur, nil):
      if prev == nil:
        node.next = queue.first
        queue.first = node
      else:
        node.next = cur
        prev.next = node
      return
    prev = cur
    cur = cur.next
  # Insert at end
  ble_co_list_push_back(queue, node)

proc ble_ke_queue_insert*(queue: ptr CoList, node: ptr CoListNode,
                           cmp: QueueCmpFunc) {.exportc, cdecl.} =
  if ke_queue_insert_patch != nil:
    discard ke_queue_insert_patch(0, queue, node, cast[pointer](cmp))
    return
  patch_ble_ke_queue_insert(queue, node, cmp)

# ---------------------------------------------------------------------------
# ======================== KE COMPARE FUNCTIONS ============================
# ---------------------------------------------------------------------------

proc ble_cmp_dest_id*(a: ptr CoListNode, b: ptr CoListNode): bool {.exportc, cdecl.} =
  ## Compare destination IDs of two messages for queue extraction
  let ha = cast[ptr KeMsgHeader](a)
  let hb = cast[ptr KeMsgHeader](b)
  return ha.dest_id == hb.dest_id

proc patch_ble_cmp_dest_id*(a: ptr CoListNode, b: ptr CoListNode): bool {.exportc: "_patch_ble_cmp_dest_id", cdecl.} =
  return ble_cmp_dest_id(a, b)

proc ble_cmp_abs_time*(a: ptr CoListNode, b: ptr CoListNode): bool {.exportc, cdecl.} =
  ## Compare timer absolute times for sorted insertion
  let ta = cast[ptr KeTimer](a)
  let tb = cast[ptr KeTimer](b)
  let diff = ta.time - tb.time
  return (diff shr 22) != 0  # time comparison with 22-bit wrap

proc patch_ble_cmp_abs_time*(a: ptr CoListNode, b: ptr CoListNode): bool {.exportc: "_patch_ble_cmp_abs_time", cdecl.} =
  return ble_cmp_abs_time(a, b)

proc ble_cmp_timer_id*(a: ptr CoListNode, b: ptr CoListNode): bool {.exportc, cdecl.} =
  ## Compare timer id+task for queue extraction
  let ta = cast[ptr KeTimer](a)
  let tb = cast[ptr KeTimer](b)
  return ta.id == tb.id and ta.task == tb.task

proc patch_ble_cmp_timer_id*(a: ptr CoListNode, b: ptr CoListNode): bool {.exportc: "_patch_ble_cmp_timer_id", cdecl.} =
  return ble_cmp_timer_id(a, b)

# ---------------------------------------------------------------------------
# ======================== KE_TASK =========================================
# ---------------------------------------------------------------------------

proc patch_ble_ke_task_saved_update*(task_type: uint16) {.exportc: "_patch_ble_ke_task_saved_update", cdecl.} =
  ## Update the saved handler for a task based on its current state
  if task_type < KE_TASK_MAX:
    let desc = addr ke_task_desc[task_type]
    if desc.state != nil and desc.state_handler != nil:
      let st = desc.state[]
      if st < desc.state_max:
        ke_task_saved[task_type] = keStateHandlerAt(desc.state_handler, st)

proc ble_ke_task_saved_update*(task_type: uint16) {.exportc, cdecl.} =
  if ke_task_saved_update_patch != nil:
    discard ke_task_saved_update_patch(0, task_type)
    return
  patch_ble_ke_task_saved_update(task_type)

proc patch_ble_ke_handler_search*(msg_id: KeMsgId, task_desc: ptr KeTaskDesc): KeMsgHandler {.exportc: "_patch_ble_ke_handler_search", cdecl.} =
  ## Search for a message handler in a task descriptor
  if task_desc == nil or task_desc.state == nil or task_desc.state_handler == nil:
    return nil
  let st = task_desc.state[]
  if st >= task_desc.state_max:
    return nil
  let state_handler = keStateHandlerAt(task_desc.state_handler, st)
  if state_handler.msg_table != nil:
    for i in 0'u16 ..< state_handler.msg_cnt:
      let entry = keMsgHandlerEntryAt(state_handler.msg_table, i)
      if entry.id == msg_id:
        return entry.handler
  # Check default handler
  if task_desc.default_handler != nil and task_desc.default_handler.msg_table != nil:
    for i in 0'u16 ..< task_desc.default_handler.msg_cnt:
      let entry = keMsgHandlerEntryAt(task_desc.default_handler.msg_table, i)
      if entry.id == msg_id:
        return entry.handler
  return nil

proc ble_ke_handler_search*(msg_id: KeMsgId, task_desc: ptr KeTaskDesc): KeMsgHandler {.exportc, cdecl.} =
  if ke_handler_search_patch != nil:
    var res: pointer
    let r = ke_handler_search_patch(addr res, msg_id, task_desc)
    if r != 0:
      return cast[KeMsgHandler](res)
  return patch_ble_ke_handler_search(msg_id, task_desc)

proc patch_ble_ke_task_handler_get*(msg_id: KeMsgId, task_id: KeTaskId): KeMsgHandler {.exportc: "_patch_ble_ke_task_handler_get", cdecl.} =
  ## Get the handler for a message ID and task ID
  let task_type = (task_id shr 8) and 0xFF
  if task_type >= KE_TASK_MAX:
    return nil
  return ble_ke_handler_search(msg_id, addr ke_task_desc[task_type])

proc ble_ke_task_handler_get*(msg_id: KeMsgId, task_id: KeTaskId): KeMsgHandler {.exportc, cdecl.} =
  if ke_task_handler_get_patch != nil:
    var res: pointer
    let r = ke_task_handler_get_patch(addr res, msg_id, task_id)
    if r != 0:
      return cast[KeMsgHandler](res)
  return patch_ble_ke_task_handler_get(msg_id, task_id)

proc bleKeTaskClearEventIfQueueEmpty() {.inline.} =
  let old = disableInterrupts()
  if ke_msg_queue.first == nil:
    ke_event_field = ke_event_field and not BleKeMessageEventBit
  restoreInterrupts(old)

proc bleKeTaskRescheduleIfQueued() {.inline.} =
  let old = disableInterrupts()
  if ke_msg_queue.first != nil:
    ble_ke_event_set(BleKeMessageEventId)
  restoreInterrupts(old)

proc patch_ble_ke_task_schedule*() {.exportc: "_patch_ble_ke_task_schedule", cdecl.} =
  ## Process one message from the message queue
  let old = disableInterrupts()
  let node = ble_co_list_pop_front(addr ke_msg_queue)
  restoreInterrupts(old)
  if node == nil:
    # Check if queue empty, if so clear event
    bleKeTaskClearEventIfQueueEmpty()
    return
  let hdr = cast[ptr KeMsgHeader](node)
  hdr.next = cast[ptr KeMsgHeader](cast[uint32](0xFFFFFFFF'u32))
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    let nimLlcpTxCfm = hdr.id == 524'u16
  let handler = ble_ke_task_handler_get(hdr.id, hdr.dest_id)
  let param = getMsgParam(hdr)
  if handler != nil:
    let result = handler(hdr.id, param, hdr.dest_id, hdr.src_id)
    case result
    of KeMsgConsumed:
      bleKeTaskRescheduleIfQueued()
    of KeMsgSaved:
      # Re-insert into saved list
      let old3 = disableInterrupts()
      ble_co_list_push_back(addr ke_msg_queue, cast[ptr CoListNode](hdr))
      restoreInterrupts(old3)
    else:
      ble_ke_msg_free(hdr)
      bleKeTaskRescheduleIfQueued()
  else:
    ble_ke_msg_free(hdr)
    bleKeTaskRescheduleIfQueued()
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if nimLlcpTxCfm and nim_llcp_tx_pending == 0:
      nimLlcpTrySendQueued()

proc ble_ke_task_schedule*() {.exportc, cdecl.} =
  if ke_task_schedule_patch != nil:
    let r = ke_task_schedule_patch(0)
    if r != 0:
      return
  patch_ble_ke_task_schedule()

proc patch_ble_ke_task_init*() {.exportc: "_patch_ble_ke_task_init", cdecl.} =
  discard c_memset(addr ke_task_desc[0], 0, (sizeof(KeTaskDesc) * KE_TASK_MAX).csize_t)

proc ble_ke_task_init*() {.exportc, cdecl.} =
  if ke_task_init_patch != nil:
    let r = ke_task_init_patch(0)
    if r != 0:
      return
  patch_ble_ke_task_init()

proc patch_ble_ke_task_create*(task_type: uint8, desc: ptr KeTaskDesc) {.exportc: "_patch_ble_ke_task_create", cdecl.} =
  if task_type < KE_TASK_MAX:
    discard c_memcpy(addr ke_task_desc[task_type], desc, sizeof(KeTaskDesc).csize_t)

proc ble_ke_task_create*(task_type: uint8, desc: ptr KeTaskDesc) {.exportc, cdecl.} =
  if ke_task_create_patch != nil:
    discard ke_task_create_patch(0, task_type, desc)
    return
  patch_ble_ke_task_create(task_type, desc)

proc ble_ke_task_delete*(task_type: uint8) {.exportc, cdecl.} =
  if task_type < KE_TASK_MAX:
    discard c_memset(addr ke_task_desc[task_type], 0, sizeof(KeTaskDesc).csize_t)

proc patch_ble_ke_state_set*(task_id: KeTaskId, state: uint8) {.exportc: "_patch_ble_ke_state_set", cdecl.} =
  let task_type = (task_id shr 8) and 0xFF
  if task_type < KE_TASK_MAX:
    let desc = addr ke_task_desc[task_type]
    if desc.state != nil:
      desc.state[] = state
      ble_ke_task_saved_update(task_type)

proc ble_ke_state_set*(task_id: KeTaskId, state: uint8) {.exportc, cdecl.} =
  if ke_state_set_patch != nil:
    discard ke_state_set_patch(0, task_id, state)
    return
  patch_ble_ke_state_set(task_id, state)

proc patch_ble_ke_state_get*(task_id: KeTaskId): uint8 {.exportc: "_patch_ble_ke_state_get", cdecl.} =
  let task_type = (task_id shr 8) and 0xFF
  if task_type < KE_TASK_MAX:
    let desc = addr ke_task_desc[task_type]
    if desc.state != nil:
      return desc.state[]
  return 0

proc ble_ke_state_get*(task_id: KeTaskId): uint8 {.exportc, cdecl.} =
  if ke_state_get_patch != nil:
    var res: uint8
    let r = ke_state_get_patch(addr res, task_id)
    if r != 0:
      return res
  return patch_ble_ke_state_get(task_id)

proc ble_ke_task_msg_flush*(task_id: KeTaskId) {.exportc, cdecl.} =
  ## Flush all messages for a given task from the queue
  var cur = cast[ptr KeMsgHeader](ke_msg_queue.first)
  var prev: ptr KeMsgHeader = nil
  while cur != nil:
    let next = cast[ptr KeMsgHeader](cur.next)
    if cur.dest_id == task_id:
      if prev == nil:
        ke_msg_queue.first = cast[ptr CoListNode](next)
      else:
        prev.next = next
      if ke_msg_queue.last == cast[ptr CoListNode](cur):
        ke_msg_queue.last = cast[ptr CoListNode](prev)
      ble_ke_msg_free(cur)
    else:
      prev = cur
    cur = next

proc ble_ke_task_check*(task_type: uint8): bool {.exportc, cdecl.} =
  if task_type >= KE_TASK_MAX:
    return false
  return ke_task_desc[task_type].state_handler != nil

# ---------------------------------------------------------------------------
# ======================== KE_TIME / KE_TIMER ==============================
# ---------------------------------------------------------------------------

proc patch_ke_time*(): uint32 {.exportc: "_patch_ke_time", cdecl.} =
  ## Read current BLE base time counter
  ## From disasm: write 0x80000000 to BLE_BASE+0x1C to latch, wait for ready,
  ## then read BLE_BASE+0x1C (half-slot count) and BLE_BASE+0x20 (fine count)
  ## Returns time in 10ms units (half-slots / 16)
  regWrite(BLE_BASE + BLE_BASETIMECNT_OFFSET, 0x80000000'u32)
  discard waitBtbleCommandDone((BLE_BASE + BLE_BASETIMECNT_OFFSET).uint,
                               4096'u32)
  let basetimecnt = regRead(BLE_BASE + BLE_BASETIMECNT_OFFSET)
  let finetimecnt = regRead(BLE_BASE + BLE_FINETIMECNT_OFFSET)
  let half_us_flag = if finetimecnt < 312: 1'u32 else: 0'u32
  return ((basetimecnt + half_us_flag) shl 5) shr 9

proc ble_ke_time*(): uint32 {.exportc, cdecl.} =
  if ke_time_patch != nil:
    var res: uint32
    let r = ke_time_patch(addr res)
    if r != 0:
      return res
  return patch_ke_time()

proc patch_ble_ke_time_cmp*(t1: uint32, t2: uint32): bool {.exportc: "_patch_ble_ke_time_cmp", cdecl.} =
  ## Compare times: returns true if t1 >= t2 (with wrap-around at 22 bits)
  let diff = t1 - t2
  return ((((diff shr 22) xor 1'u32) and 1'u32) != 0'u32)

proc ble_ke_time_cmp*(t1: uint32, t2: uint32): bool {.exportc, cdecl.} =
  if ke_time_cmp_patch != nil:
    var res: uint8
    let r = ke_time_cmp_patch(addr res, t1, t2)
    if r != 0:
      return res != 0
  return patch_ble_ke_time_cmp(t1, t2)

proc patch_ble_ke_time_past*(t: uint32): bool {.exportc: "_patch_ble_ke_time_past", cdecl.} =
  ## Check if time t is in the past
  let now = ble_ke_time()
  return ble_ke_time_cmp(now, t)

proc ble_ke_time_past*(t: uint32): bool {.exportc, cdecl.} =
  if ke_time_past_patch != nil:
    var res: uint8
    let r = ke_time_past_patch(addr res, t)
    if r != 0:
      return res != 0
  return patch_ble_ke_time_past(t)

proc patch_ble_ke_timer_hw_set*(timer: ptr KeTimer) {.exportc: "_patch_ble_ke_timer_hw_set", cdecl.} =
  ## Program the hardware timer with the first timer's expiry
  if timer != nil:
    let target = timer.time and 0x7FFFFF'u32
    # Program the BLE timer target register
    regWrite(BLE_BASE + 0x24'u32, target)

proc ble_ke_timer_hw_set*(timer: ptr KeTimer) {.exportc, cdecl.} =
  if ke_timer_hw_set_patch != nil:
    discard ke_timer_hw_set_patch(0, timer)
    return
  patch_ble_ke_timer_hw_set(timer)

proc bleKeTimerHead(): ptr KeTimer {.inline.} =
  cast[ptr KeTimer](ke_timer_list.first)

proc bleKeTimerExpired(timer: ptr KeTimer): bool {.inline.} =
  timer != nil and ble_ke_time_past(timer.time)

proc bleKeTimerPendingWork(): bool {.inline.} =
  bleKeTimerExpired(bleKeTimerHead())

proc patch_ble_ke_timer_schedule*() {.exportc: "_patch_ble_ke_timer_schedule", cdecl.} =
  ## Process expired timers
  var drained = 0'u32
  while drained < BleKeTimerDrainLimit:
    let timer = bleKeTimerHead()
    if not bleKeTimerExpired(timer):
      break
    discard ble_co_list_pop_front(addr ke_timer_list)
    ble_ke_msg_send_basic(timer.id, timer.task, timer.task)
    ble_ke_free(timer)
    inc drained
  # Reprogram HW timer
  let next = bleKeTimerHead()
  if next != nil:
    if drained >= BleKeTimerDrainLimit and bleKeTimerExpired(next):
      inc nim_ble_ke_timer_yield_count
      nim_ble_ke_timer_yield_time = next.time
    ble_ke_timer_hw_set(next)

proc ble_ke_timer_schedule*() {.exportc, cdecl.} =
  if ke_timer_schedule_patch != nil:
    discard ke_timer_schedule_patch(0)
    return
  patch_ble_ke_timer_schedule()

proc patch_ble_ke_timer_init*() {.exportc: "_patch_ble_ke_timer_init", cdecl.} =
  ble_co_list_init(addr ke_timer_list)

proc ble_ke_timer_init*() {.exportc, cdecl.} =
  if ke_timer_init_patch != nil:
    discard ke_timer_init_patch(0)
    return
  patch_ble_ke_timer_init()

proc patch_ble_ke_timer_set*(id: uint16, task: uint16, delay: uint32) {.exportc: "_patch_ble_ke_timer_set", cdecl.} =
  ## Set (or reset) a kernel timer
  var actual_delay = delay
  if actual_delay == 0:
    actual_delay = 1
  if actual_delay >= 0x400000'u32:
    actual_delay = 0x3FFFFF'u32

  # Check if timer already exists with same id/task
  var existing = false
  let first = cast[ptr KeTimer](ke_timer_list.first)
  if first != nil and first.id == id and first.task == task:
    existing = true

  # Search and remove existing timer with this id/task
  var cur = cast[ptr KeTimer](ke_timer_list.first)
  var timer: ptr KeTimer = nil
  while cur != nil:
    if cur.id == id and cur.task == task:
      timer = cur
      patch_ble_co_list_extract(addr ke_timer_list, cast[ptr CoListNode](timer))
      break
    cur = cur.next

  # Allocate new timer if not found
  if timer == nil:
    timer = cast[ptr KeTimer](ble_ke_malloc(sizeof(KeTimer).uint32, 0))
    if timer == nil:
      return
    timer.id = id
    timer.task = task

  # Set expiry time
  let now = ble_ke_time()
  let target = (now + actual_delay) and 0x7FFFFF'u32
  timer.time = target

  # Insert into sorted timer list
  ble_ke_queue_insert(addr ke_timer_list, cast[ptr CoListNode](timer),
                       cast[QueueCmpFunc](ble_cmp_abs_time))

  # If this is now the first timer or we changed the first, reprogram HW
  if not existing or cast[ptr KeTimer](ke_timer_list.first) == timer:
    ble_ke_timer_hw_set(cast[ptr KeTimer](ke_timer_list.first))

proc ble_ke_timer_set*(id: uint16, task: uint16, delay: uint32) {.exportc, cdecl.} =
  if ke_timer_set_patch != nil:
    let r = ke_timer_set_patch(0, id, task, delay)
    if r != 0:
      return
  patch_ble_ke_timer_set(id, task, delay)

proc patch_ble_ke_timer_clear*(id: uint16, task: uint16) {.exportc: "_patch_ble_ke_timer_clear", cdecl.} =
  ## Clear cancel a timer
  var cur = cast[ptr KeTimer](ke_timer_list.first)
  while cur != nil:
    if cur.id == id and cur.task == task:
      let removedFirst = ke_timer_list.first == cast[ptr CoListNode](cur)
      patch_ble_co_list_extract(addr ke_timer_list, cast[ptr CoListNode](cur))
      ble_ke_free(cur)
      # Reprogram if we removed the first
      if removedFirst and ke_timer_list.first != nil:
        ble_ke_timer_hw_set(cast[ptr KeTimer](ke_timer_list.first))
      return
    cur = cur.next

proc ble_ke_timer_clear*(id: uint16, task: uint16) {.exportc, cdecl.} =
  if ke_timer_clear_patch != nil:
    discard ke_timer_clear_patch(0, id, task)
    return
  patch_ble_ke_timer_clear(id, task)

proc patch_ble_ke_timer_active*(id: uint16, task: uint16): bool {.exportc: "_patch_ble_ke_timer_active", cdecl.} =
  var cur = cast[ptr KeTimer](ke_timer_list.first)
  while cur != nil:
    if cur.id == id and cur.task == task:
      return true
    cur = cur.next
  return false

proc ble_ke_timer_active*(id: uint16, task: uint16): bool {.exportc, cdecl.} =
  if ke_timer_active_patch != nil:
    var res: uint8
    let r = ke_timer_active_patch(addr res, id, task)
    if r != 0:
      return res != 0
  return patch_ble_ke_timer_active(id, task)

proc ble_ke_timer_adjust_all*() {.exportc, cdecl.} =
  ## Adjust all timer times after a clock correction (no-op if no correction needed)
  discard

proc patch_ble_ke_timer_target_get*(): uint32 {.exportc: "_patch_ble_ke_timer_target_get", cdecl.} =
  let first = cast[ptr KeTimer](ke_timer_list.first)
  if first != nil:
    return first.time
  return 0

proc ble_ke_timer_target_get*(): uint32 {.exportc, cdecl.} =
  if ke_timer_target_get_patch != nil:
    var res: uint32
    let r = ke_timer_target_get_patch(addr res)
    if r != 0:
      return res
  return patch_ble_ke_timer_target_get()

# ---------------------------------------------------------------------------
# ======================== KE_INIT / FLUSH / SLEEP =========================
# ---------------------------------------------------------------------------

proc patch_ble_ke_init*() {.exportc: "_patch_ble_ke_init", cdecl.} =
  ble_ke_event_init()
  ble_ke_task_init()
  ble_ke_timer_init()
  ble_ke_mem_init()
  ble_co_list_init(addr ke_msg_queue)

proc ble_ke_init*() {.exportc, cdecl.} =
  if ke_init_patch != nil:
    let r = ke_init_patch(0)
    if r != 0:
      return
  patch_ble_ke_init()

proc bleControllerHasPendingWork(): bool {.inline.}

proc patch_ble_ke_flush*() {.exportc: "_patch_ble_ke_flush", cdecl.} =
  ## Flush all pending messages and timers
  # Drain timer list
  while ke_timer_list.first != nil:
    let node = ble_co_list_pop_front(addr ke_timer_list)
    ble_ke_free(node)
  # Drain message queue
  while ke_msg_queue.first != nil:
    let node = ble_co_list_pop_front(addr ke_msg_queue)
    ble_ke_free(node)
  ke_event_field = 0

proc ble_ke_flush*() {.exportc, cdecl.} =
  if ke_flush_patch != nil:
    discard ke_flush_patch(0)
    return
  patch_ble_ke_flush()

proc patch_ble_ke_sleep_check*(): bool {.exportc: "_patch_ble_ke_sleep_check", cdecl.} =
  return not bleControllerHasPendingWork()

proc ble_ke_sleep_check*(): bool {.exportc, cdecl.} =
  if ke_sleep_check_patch != nil:
    var res: uint8
    let r = ke_sleep_check_patch(addr res)
    if r != 0:
      return res != 0
  return patch_ble_ke_sleep_check()

proc ble_ke_tx_queue_num*(): uint32 {.exportc, cdecl.} =
  return ble_co_list_size(addr ke_msg_queue)

# ---------------------------------------------------------------------------
# ======================== EM_BUF ==========================================
# ---------------------------------------------------------------------------

proc em_buf_init*() {.exportc, cdecl.} =
  ## Initialize exchange memory buffer pools
  ## From disasm: initializes RX and TX buffer descriptors in EM space
  discard c_memset(addr em_buf_env[0], 0, sizeof(em_buf_env).csize_t)

  # Initialize RX buffer pool (5 descriptors of 14 bytes starting at EM offset)
  let rx_base = BLE_EM_BASE + 0x262'u32  # from disasm: 0x28008262
  for i in 0'u16 ..< EM_BUF_RX_COUNT:
    let desc = emRxDescAt(rx_base, i)
    # Set buffer pointer (offset from EM base) = 0x3CC + i * 38
    let buf_offset = 0x3CC'u16 + i * EM_BUF_RX_DATA_SIZE.uint16
    volatileStore(addr desc.buf_ptr, buf_offset)
    # Clear status/flags
    volatileStore(addr desc.status, 0'u16)
    volatileStore(addr desc.data_len, 0'u16)

  # Initialize TX buffer pool descriptors
  let tx_base = BLE_EM_BASE + 0x298'u32
  for i in 0'u16 ..< EM_BUF_TX_COUNT.uint16:
    volatileStore(addr emTxDescAt(tx_base, i).status, 0'u16)

proc em_buf_rx_free*(idx: uint16) {.exportc, cdecl.} =
  ## Free an RX buffer by clearing the used bit in status
  let status_ptr = emRxFreeStatusField(idx)
  let v = volatileLoad(status_ptr)
  volatileStore(status_ptr, v and 0x7FFF'u16)  # Clear bit 15 (used/done flag)

proc em_buf_rx_buff_addr_get*(idx: uint16): pointer {.exportc, cdecl.} =
  ## Get the address of an RX buffer's data area
  let buf_ptr = emRxBufferPointerField(idx)
  let offset = volatileLoad(buf_ptr)
  return bleEmPointer(offset)

proc em_buf_tx_buff_addr_get*(desc: pointer): pointer {.exportc, cdecl.} =
  ## Get TX buffer data address from descriptor
  let txDesc = cast[ptr EmBufTxDesc](desc)
  let offset = volatileLoad(addr txDesc.buf_ptr)
  return bleEmPointer(offset)

proc em_buf_tx_free*(desc: pointer) {.exportc, cdecl.} =
  ## Free a TX buffer
  let txDesc = cast[ptr EmBufTxDesc](desc)
  let offset = volatileLoad(addr txDesc.buf_ptr)
  # Clear allocation status in TX pool
  let pool_idx = offset.uint32
  let old = disableInterrupts()
  # Mark buffer as free in the TX descriptor
  let poolDesc = emTxPoolDescForBufferOffset(pool_idx)
  volatileStore(addr poolDesc.status, 0'u16)
  restoreInterrupts(old)

# ---------------------------------------------------------------------------
# ======================== EA (Event Arbiter) ==============================
# ---------------------------------------------------------------------------

proc ea_init*() {.exportc, cdecl.} =
  ## Initialize the event arbiter
  ble_co_list_init(addr ea_env_list)
  ble_co_list_init(addr ea_env_interval_list)
  ea_env_target = 0
  ea_env_finetarget = 0

proc ea_elt_create*(size: uint32): ptr EaEltTag {.exportc, cdecl.} =
  ## Create an EA element
  let elt = cast[ptr EaEltTag](ble_ke_malloc(size + sizeof(EaEltTag).uint32, 0))
  if elt != nil:
    discard c_memset(elt, 0, (size + sizeof(EaEltTag).uint32).csize_t)
  return elt

proc ea_elt_insert*(elt: ptr EaEltTag) {.exportc, cdecl.} =
  ## Insert an element into the EA schedule
  if elt == nil:
    return
  elt.linked = 1
  ble_co_list_push_back(addr ea_env_list, cast[ptr CoListNode](elt))

proc ea_elt_remove*(elt: ptr EaEltTag) {.exportc, cdecl.} =
  ## Remove an element from the EA schedule
  if elt == nil:
    return
  ble_co_list_extract(addr ea_env_list, cast[ptr CoListNode](elt))
  elt.linked = 0

proc ea_elt_cancel*(elt: ptr EaEltTag) {.exportc, cdecl.} =
  ## Cancel a scheduled element
  if elt == nil:
    return
  ea_elt_remove(elt)
  if elt.ea_cb_cancel != nil:
    let cb = cast[proc(elt: ptr EaEltTag) {.cdecl.}](elt.ea_cb_cancel)
    cb(elt)

proc ea_interval_create*(intv: ptr EaIntervalTag) {.exportc, cdecl.} =
  ## Create an interval element
  if intv != nil:
    discard c_memset(intv, 0, sizeof(EaIntervalTag).csize_t)

proc ea_interval_insert*(intv: ptr EaIntervalTag) {.exportc, cdecl.} =
  ## Insert interval into the interval list
  ble_co_list_push_back(addr ea_env_interval_list, cast[ptr CoListNode](intv))

proc ea_interval_remove*(intv: ptr EaIntervalTag) {.exportc, cdecl.} =
  ## Remove interval from list
  ble_co_list_extract(addr ea_env_interval_list, cast[ptr CoListNode](intv))

proc ea_interval_delete*(intv: ptr EaIntervalTag) {.exportc, cdecl.} =
  ## Delete an interval (remove and free)
  ea_interval_remove(intv)
  ble_ke_free(intv)

proc ea_interval_duration_req*(intv: ptr EaIntervalTag): uint32 {.exportc, cdecl.} =
  ## Get duration requirement for interval
  if intv != nil:
    return intv.bandwidth
  return 0

proc ea_sw_isr*() {.exportc, cdecl.} =
  ## Software ISR for event arbiter
  # Process completed events
  var cur = cast[ptr EaEltTag](ea_env_list.first)
  while cur != nil:
    let next = cast[ptr EaEltTag](cur.node.next)
    if cur.ea_cb_start != nil:
      let cb = cast[proc(elt: ptr EaEltTag) {.cdecl.}](cur.ea_cb_start)
      cb(cur)
    cur = next

proc ea_finetimer_isr*() {.exportc, cdecl.} =
  ## Fine timer ISR
  # Acknowledge interrupt
  regWrite(BLE_BASE + BLE_INTACK_OFFSET, 0x00000001'u32)  # Fine timer IRQ bit
  # Schedule pending events
  ea_sw_isr()

proc ea_offset_req*(intv: ptr EaIntervalTag, offset: ptr uint32): bool {.exportc, cdecl.} =
  ## Request an offset for a new interval
  if offset != nil:
    offset[] = 0
  return true

proc ea_time_get_halfslot_rounded*(): uint32 {.exportc, cdecl.} =
  ## Get current time rounded to half-slot
  regWrite(BLE_BASE + BLE_BASETIMECNT_OFFSET, BtbleBusyBit)
  discard waitBtbleCommandDone((BLE_BASE + BLE_BASETIMECNT_OFFSET).uint)
  return regRead(BLE_BASE + BLE_BASETIMECNT_OFFSET)

proc ea_time_get_slot_rounded*(): uint32 {.exportc, cdecl.} =
  ## Get current time rounded to slot (even half-slot)
  let hs = ea_time_get_halfslot_rounded()
  return hs and 0xFFFFFFFE'u32

proc ea_timer_target_get*(): uint32 {.exportc, cdecl.} =
  return ea_env_target

# ---------------------------------------------------------------------------
