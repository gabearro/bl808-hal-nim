# ###########################################################################
#                      COMMON UTILITIES
# ###########################################################################

proc ascii_to_hex*(c: uint8): uint8 {.exportc, cdecl.} =
  ## Convert a single ASCII hex character to its 4-bit value.
  ## '0'-'9' -> 0-9, 'a'-'f' -> 10-15, 'A'-'F' -> 10-15, else 0.
  let decimalDigit = c - ord('0').uint8
  if decimalDigit <= 9: return decimalDigit
  let lower = c - ord('a').uint8
  if lower <= 5: return c - 87  # 'a' - 87 = 10
  let upper = c - ord('A').uint8
  if upper <= 5: return c - 55  # 'A' - 55 = 10
  return 0

# ###########################################################################
#                      COMMON LIST UTILITIES (co_*)
# ###########################################################################

# Forward declarations -- assert functions defined later but used in early procs.
proc assert_err*(cond: cstring, file: cstring, line: cint) {.exportc, cdecl.}
proc assert_warn*(cond: cstring, file: cstring, line: cint) {.exportc, cdecl.}

proc co_list_init*(list: ptr CoList) {.exportc, cdecl, noinline.} =
  ## Initialize a singly-linked list to empty.
  ## noinline + asm barrier: blob emits real calls to this from many init
  ## functions (txl_cntrl_init, txl_reset, mm_timer_init, etc.); without the
  ## barrier GCC inlines the two-word store.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
  list.first = nil
  list.last = nil

proc co_list_push_back*(list: ptr CoList, elem: ptr CoListHdr) {.exportc, cdecl, noinline.} =
  ## Append element to the end of the list.
  ## noinline: blob keeps this as a distinct function (many call sites).
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  if elem == nil:
    assert_err("co_list.c", "co_list.c", 71)
  if list.first == nil:
    list.first = elem
  else:
    list.last.next = elem
  list.last = elem
  elem.next = nil

proc co_list_push_front*(list: ptr CoList, elem: ptr CoListHdr) {.exportc, cdecl.} =
  ## Prepend element to the front of the list (62 bytes in blob).
  # Blob only asserts on elem==nil (line 94); list==nil not checked.
  if elem == nil:
    assert_err("co_list.c", "co_list.c", 94)
  if list.first == nil:
    list.last = elem
  elem.next = list.first
  list.first = elem

proc co_list_pop_front*(list: ptr CoList): ptr CoListHdr {.exportc, cdecl.} =
  ## Remove and return the first element from the list.
  ## Note: blob does NOT update list.last when list becomes empty.
  result = list.first
  if result != nil:
    list.first = result.next

proc co_list_extract*(list: ptr CoList, elem: ptr CoListHdr) {.exportc, cdecl.} =
  ## Remove a specific element from the list.
  ## Blob asserts list!=nil; does NOT update list.last when removing first element.
  if list == nil:
    assert_err("co_list.c", "co_list.c", 129)
  var currentNode = list.first
  if currentNode == nil: return
  if currentNode == elem:
    list.first = elem.next
    return
  while currentNode.next != nil:
    var nextNode = currentNode.next
    if nextNode == elem:
      if list.last == elem:
        list.last = currentNode
      currentNode.next = elem.next
      return
    currentNode = nextNode

proc co_list_find*(list: ptr CoList, elem: ptr CoListHdr): bool {.exportc, cdecl.} =
  ## Return true if element is in the list.
  var currentNode = list.first
  while currentNode != nil:
    if currentNode == elem: return true
    currentNode = currentNode.next
  return false

proc co_list_cnt*(list: ptr CoList): uint32 {.exportc, cdecl.} =
  ## Count elements in the list.
  result = 0
  var currentNode = list.first
  while currentNode != nil:
    inc result
    currentNode = currentNode.next

proc co_list_insert*(list: ptr CoList, elem: ptr CoListHdr, cmp: proc(a, b: ptr CoListHdr): bool {.cdecl.}) {.exportc, cdecl.} =
  ## Sorted insert: walk the list calling cmp(elem, currentNode). Insert elem
  ## before the first currentNode where cmp returns true. If cmp never returns
  ## true, append.
  var currentNode = list.first
  var previousNode: ptr CoListHdr = nil
  while currentNode != nil:
    if cmp(elem, currentNode):
      break
    previousNode = currentNode
    currentNode = currentNode.next
  if currentNode == nil:
    list.last = elem
  elem.next = currentNode
  if previousNode == nil:
    list.first = elem
  else:
    previousNode.next = elem

proc co_list_insert_after*(list: ptr CoList, refElem: ptr CoListHdr, elem: ptr CoListHdr) {.exportc, cdecl.} =
  ## Insert elem after refElem in the list. If refElem is nil, push to front.
  ## Walks the list to verify refElem exists before inserting.
  if refElem == nil:
    co_list_push_front(list, elem)
    return
  var currentNode = list.first
  while currentNode != nil:
    if currentNode == refElem:
      elem.next = refElem.next
      refElem.next = elem
      if elem.next == nil:
        list.last = elem
      return
    currentNode = currentNode.next

proc co_list_insert_before*(list: ptr CoList, refElem: ptr CoListHdr, elem: ptr CoListHdr) {.exportc, cdecl.} =
  ## Insert elem before refElem.
  ## Blob algorithm:
  ##   if refElem == NULL: tail-call co_list_push_back(list, elem)
  ##   else if list->first == refElem: tail-call co_list_push_front(list, elem)
  ##   else: walk until previousNode->next == refElem; elem->next = refElem;
  ##   previousNode->next = elem
  ## Prior Nim bug: on refElem==nil it called co_list_push_front (would drop
  ## elem at the head instead of the tail, inverting ordering semantics).
  if refElem == nil:
    co_list_push_back(list, elem)
    return
  if list.first == refElem:
    co_list_push_front(list, elem)
    return
  var previousNode = list.first
  while previousNode != nil:
    if previousNode.next == refElem:
      elem.next = refElem
      previousNode.next = elem
      return
    previousNode = previousNode.next

proc co_list_concat*(dst: ptr CoList, src: ptr CoList) {.exportc, cdecl.} =
  ## Concatenate src list onto the end of dst, then clear src.
  ## Note: blob only clears src.first, not src.last.
  if src.first == nil: return
  if dst.first == nil:
    dst.first = src.first
  else:
    dst.last.next = src.first
  dst.last = src.last
  src.first = nil

proc co_list_remove*(list: ptr CoList, previousNode: ptr CoListHdr, elem: ptr CoListHdr) {.exportc, cdecl.} =
  ## Remove elem from list, given its predecessor previousNode (156 bytes in blob).
  ## If previousNode is nil, elem is assumed to be the first element.
  ## Clears elem.next after removal.
  if list == nil:
    assert_err("co_list.c", "co_list.c", 360)
  if elem == nil:
    assert_err("co_list.c", "co_list.c", 362)
  if previousNode != nil:
    # Validate that previousNode actually points to elem
    if previousNode.next != elem:
      assert_err("co_list.c", "co_list.c", 361)
    # Unlink: previousNode->next = elem->next
    previousNode.next = elem.next
    # If elem was the last element, update list.last to previousNode
    if list.last == elem:
      list.last = previousNode
  else:
    # elem is the first element — blob does NOT assert on list.first mismatch
    # here (only 3 asserts at lines 360/361/362); previous Nim added an
    # extra line-363 assert.
    # Unlink from front
    list.first = elem.next
    # If elem was the only element, clear list.last too
    if list.last == elem:
      list.last = nil
  # Clear removed element's next pointer
  elem.next = nil

proc co_list_pool_init*(list: ptr CoList, pool: pointer, elemSize: uint32, poolSize: uint32, defaultValue: pointer = nil) {.exportc, cdecl.} =
  ## Initialize a list pool by linking poolSize elements of elemSize into the list.
  ## Blob inlines the head clear (sw zero, first/last) rather than calling
  ## co_list_init; use field stores to keep the layout explicit.
  list.first = nil
  list.last = nil
  var base = cast[uint](pool)
  for listPoolSlotIndex in 0'u32 ..< poolSize:
    let node = cast[ptr CoListHdr](base)
    if defaultValue != nil:
      copyMem(cast[pointer](base), defaultValue, elemSize.int)
    co_list_push_back(list, node)
    base = base + elemSize.uint

# Double-linked list operations
proc co_dlist_init*(list: ptr CoDlist) {.exportc, cdecl.} =
  list.first = nil
  list.last = nil
  list.elementCount = 0

proc co_dlist_push_back*(list: ptr CoDlist, elem: ptr CoDlistHdr) {.exportc, cdecl.} =
  if list.first == nil:
    list.first = elem
  else:
    list.last.next = elem
  elem.prev = list.last
  elem.next = nil
  list.last = elem
  inc list.elementCount

proc co_dlist_push_front*(list: ptr CoDlist, elem: ptr CoDlistHdr) {.exportc, cdecl.} =
  if list.first == nil:
    list.last = elem
  else:
    list.first.prev = elem
  elem.next = list.first
  elem.prev = nil
  list.first = elem
  inc list.elementCount

proc co_dlist_pop_front*(list: ptr CoDlist): ptr CoDlistHdr {.exportc, cdecl.} =
  result = list.first
  if result == nil: return
  dec list.elementCount
  list.first = result.next
  if list.first != nil:
    list.first.prev = nil
  else:
    list.last = nil

proc co_dlist_extract*(list: ptr CoDlist, elem: ptr CoDlistHdr) {.exportc, cdecl.} =
  if list.first == nil:
    assert_err("co_dlist.c", "co_dlist.c", 142)
  if list.first == elem:
    list.first = elem.next
    if list.first == nil:
      list.last = nil
    else:
      list.first.prev = nil
  else:
    elem.prev.next = elem.next
    if list.last == elem:
      list.last = elem.prev
    else:
      elem.next.prev = elem.prev
  dec list.elementCount

# Pool operations
#
# The blob's co_pool uses a separate node array (8 bytes per node: {next, element})
# to track free pool elements. The pool struct is just {head_ptr, free_count}.
# This differs from co_list which embeds the next pointer in the element itself.

proc co_pool_init*(pool: ptr CoPool, nodeArray: pointer, poolMem: pointer, elemSize: uint32, elemCount: uint32) {.exportc, cdecl.} =
  ## Initialize a pool with a separate node array for free-list tracking (150b blob).
  ## nodeArray: memory for CoPoolNode entries (8 bytes each, elemCount entries)
  ## poolMem: memory for actual pool elements (elemSize bytes each)
  ## elemSize, poolMem must be 4-byte aligned.
  # Blob only asserts the two alignment checks (lines 42/43).
  if (cast[uint](poolMem) and 3) != 0:
    assert_err("co_pool.c", "co_pool.c", 42)
  if (elemSize and 3) != 0:
    assert_err("co_pool.c", "co_pool.c", 43)
  # Blob does NOT zero-initialize the pool memory here — callers are
  # expected to populate elements as they allocate from the free list.
  # Previous Nim emitted a memset that wasn't in blob's call graph.
  var nodeBase = cast[uint](nodeArray)
  var elemBase = cast[uint](poolMem)
  # Build the free-list chain in the node array
  for poolNodeIndex in 0'u32 ..< elemCount:
    let node = cast[ptr CoPoolNode](nodeBase + poolNodeIndex.uint * 8)
    node.element = cast[pointer](elemBase + poolNodeIndex.uint * elemSize.uint)
    if poolNodeIndex + 1 < elemCount:
      node.next = cast[ptr CoPoolNode](nodeBase + (poolNodeIndex.uint + 1) * 8)
    else:
      node.next = nil
  pool.first = cast[ptr CoPoolNode](nodeBase)
  pool.freeNodeCount = elemCount

proc co_pool_alloc*(pool: ptr CoPool, count: uint32): pointer {.exportc, cdecl.} =
  ## Allocate 'count' nodes from the pool. Returns head of allocated chain,
  ## or nil if not enough free nodes.
  if count == 0:
    assert_err("co_pool.c", "co_pool.c", 73)
  if pool.freeNodeCount < count:
    return nil
  result = cast[pointer](pool.first)
  # Walk 'count' nodes to find the new head
  var last = pool.first
  for allocatedNodeIndex in 1'u32 ..< count:
    last = last.next
  # Detach the chain: new pool head is after the last allocated node
  pool.first = last.next
  pool.freeNodeCount -= count
  last.next = nil  # Null-terminate the returned chain

proc co_pool_free*(pool: ptr CoPool, elemChain: pointer, count: uint32) {.exportc, cdecl.} =
  ## Free a chain of 'count' nodes back to the pool (122 bytes in blob).
  # Blob asserts only 113/114 (count/elemChain); `pool == nil` check is not in blob.
  if count == 0:
    assert_err("co_pool.c", "co_pool.c", 113)
  if elemChain == nil:
    assert_err("co_pool.c", "co_pool.c", 114)
  var head = cast[ptr CoPoolNode](elemChain)
  let oldFirst = pool.first
  pool.first = head
  pool.freeNodeCount += count
  # Walk to end of returned chain (blob does NOT assert on nil tail.next).
  var tail = head
  for freedNodeIndex in 1'u32 ..< count:
    tail = tail.next
  # Splice: last node of returned chain points to old head
  tail.next = oldFirst

proc co_pack8p*(dst: pointer, src: pointer, count: uint32) {.exportc, cdecl.} =
  ## Pack byte array from src into dst, 'count' bytes.
  ## From blob: loop copying bytes from src to dst using T-Head extension insns.
  ## (co_list.o / co_ring.o)
  for byteOffset in 0'u32 ..< count:
    let sourceByte = cast[ptr uint8](cast[uint](src) + byteOffset)[]
    cast[ptr uint8](cast[uint](dst) + byteOffset)[] = sourceByte

# ###########################################################################
#                      KERNEL: EVENTS (ke_evt_*)
# ###########################################################################

template keEnvEventField(): ptr uint32 =
  cast[ptr uint32](addr ke_env[0])

template keEnvPsFlags(): ptr KeEnvPsFlagsView =
  cast[ptr KeEnvPsFlagsView](addr ke_env[28])

proc ke_evt_set*(evtBit: uint32) {.exportc, cdecl.} =
  ## Set event bit(s) in the kernel event field (interrupt-safe).
  let savedIrqState = irqSave()
  let updatedEventField = keEvtField or evtBit
  keEvtField = updatedEventField
  keEnvEventField()[] = updatedEventField
  if (evtBit and 0x98000000'u32) != 0:
    nimFwTrace2U32("[WIFI-NIMFW] evt_set ", evtBit, updatedEventField)
  irqRestore(savedIrqState)

proc ke_evt_clear*(evtBit: uint32) {.exportc, cdecl, noinline.} =
  ## Clear event bit(s) in the kernel event field (interrupt-safe).
  ## noinline: blob keeps this as a standalone function.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let savedIrqState = irqSave()
  let updatedEventField = keEvtField and (not evtBit)
  keEvtField = updatedEventField
  keEnvEventField()[] = updatedEventField
  if (evtBit and 0x98000000'u32) != 0:
    nimFwTrace2U32("[WIFI-NIMFW] evt_clear ", evtBit, updatedEventField)
  irqRestore(savedIrqState)

proc eventIndex32(x: uint32): uint32 {.inline.} =
  ## Blob ke_evt_schedule calls __clzsi2(event_field) directly. Event bit 31
  ## maps to handler index 0, and bit 6 maps to index 25.
  if x == 0: return 32
  var clzResult: cuint
  let eventField: cuint = x.cuint
  {.emit: [clzResult, " = __builtin_clz(", eventField, ");"].}
  return clzResult.uint32

proc ke_evt_schedule*() {.exportc, cdecl.} =
  ## Process the highest-priority pending event by calling its handler.
  ## From blob: uses clz to find the highest set bit, asserts bit < KE_EVT_MAX,
  ## then dispatches through keEvtHandlers[bit] with indirect call.
  let pendingEventField = keEvtField
  if pendingEventField == 0: return
  let eventIndex = eventIndex32(pendingEventField)
  nimFwTrace2U32("[WIFI-NIMFW] evt_sched ", pendingEventField, eventIndex)
  if eventIndex >= KE_EVT_MAX.uint32:
    assert_err("ke_event.c", "ke_event.c", 236)
  let handler = keEvtHandlers[eventIndex].handler
  if handler == nil:
    assert_err("ke_event.c", "ke_event.c", 236)
  let eventHandler = cast[proc(param: pointer) {.cdecl.}](handler)
  eventHandler(keEvtHandlers[eventIndex].param)

# ###########################################################################
#                      KERNEL: MESSAGES (ke_msg_*)
# ###########################################################################

proc ke_msg_alloc*(id: uint16, destId: uint8, srcId: uint8, paramLen: uint32): pointer {.exportc, cdecl.} =
  ## Allocate a kernel message with header + payload.
  ## Returns pointer to the payload (header is immediately before it).
  ## Blob: `lw a5, 0(g_bl_ops_funcs+0xb8); jalr a5(paramLen+12)` — the platform
  ## allocator at g_bl_ops_funcs byte-offset 0xB8 (word 46) is invoked with the
  ## total size. Nim previously used `keAllocFunc` — a Nim-only global that is
  ## never populated, so the call crashed at runtime.
  let allocFn = cast[proc(sz: uint32): pointer {.cdecl.}](
    blOpsFunc(0xB8))
  let totalSize = paramLen + KeMsgHdrSize.uint32
  let hdr = cast[ptr KeMsgHdr](allocFn(totalSize))
  if hdr == nil:
    assert_err("ke_msg.c", "ke_msg.c", 48)
  hdr.id = id
  hdr.destId = destId
  hdr.srcId = srcId
  hdr.paramLen = paramLen
  hdr.next = nil
  let payload = keMsgPayload(hdr)
  discard c_memset(payload, 0, paramLen.csize_t)
  return payload

proc ke_msg_try_alloc(id: uint16, destId: uint8, srcId: uint8,
                      paramLen: uint32): pointer =
  ## Allocate a kernel message for optional caches. Unlike ke_msg_alloc this
  ## returns nil on heap pressure instead of asserting.
  let allocFn = cast[proc(sz: uint32): pointer {.cdecl.}](
    blOpsFunc(0xB8))
  let totalSize = paramLen + KeMsgHdrSize.uint32
  let hdr = cast[ptr KeMsgHdr](allocFn(totalSize))
  if hdr == nil:
    return nil
  hdr.id = id
  hdr.destId = destId
  hdr.srcId = srcId
  hdr.paramLen = paramLen
  hdr.next = nil
  let payload = keMsgPayload(hdr)
  discard c_memset(payload, 0, paramLen.csize_t)
  return payload

proc ke_msg_send*(param: pointer) {.exportc, cdecl, noinline.} =
  ## Send a kernel message (param points to payload, header is immediately before it).
  ## From blob: asserts destId <= TASK_MAX, routes local tasks to sent queue
  ## with KE_EVT_KE_MESSAGE, routes API/external tasks via IPC push + free.
  ## noinline: blob keeps this as a separate function (>20 call sites).
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let hdr = keMsgHdrFromPayload(param)
  let destTask = hdr.destId
  if destTask > TASK_MAX:
    assert_err("ke_msg.c", "ke_msg.c", 127)
  if destTask <= TASK_LAST_EMB:
    # Internal task: enqueue to sent queue and set message event
    nimFwTrace2U32("[WIFI-NIMFW] ke_msg_send internal ", hdr.id.uint32, destTask.uint32)
    co_list_push_back(addr keMsgQueueSent, cast[ptr CoListHdr](hdr))
    ke_evt_set(KE_EVT_KE_MESSAGE)
  else:
    # API/external task (destTask 9-10): route via bl_rx_e2a_handler
    # Blob: call bl_rx_e2a_handler(param-8), then tail-call g_bl_ops_funcs[0xBC](hdr)
    nimFwTrace("[WIFI-NIMFW] ke_msg_send external")
    bl_rx_e2a_handler(keMsgExternalPayload(param))
    nimFwTrace("[WIFI-NIMFW] ke_msg_send external done")
    # Tail-call through ops function table for message free/schedule
    let opsFn = cast[proc(p: pointer){.cdecl.}](blOpsFunc(0xBC))
    opsFn(cast[pointer](hdr))

proc ke_msg_send_basic*(id: uint16, destId: uint8, srcId: uint8) {.exportc, cdecl, noinline.} =
  ## Allocate and send a zero-length kernel message.
  ## noinline: blob keeps this as a separate helper called from many sites.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let param = ke_msg_alloc(id, destId, srcId, 0)
  if param != nil:
    ke_msg_send(param)

proc ke_msg_forward*(param: pointer, destId: uint8, srcId: uint8) {.exportc, cdecl.} =
  ## Forward an existing message to a different destination.
  let hdr = keMsgHdrFromPayload(param)
  hdr.destId = destId
  hdr.srcId = srcId
  ke_msg_send(param)

proc ke_msg_forward_and_change_id*(param: pointer, newId: uint16, destId: uint8, srcId: uint8) {.exportc, cdecl.} =
  ## Forward a message with a new message ID.
  let hdr = keMsgHdrFromPayload(param)
  hdr.id = newId
  hdr.destId = destId
  hdr.srcId = srcId
  ke_msg_send(param)

template platformFree(p: pointer) =
  ## Invoke the platform free hook from g_bl_ops_funcs+0xBC. The previous Nim
  ## code used `keFreeFunc` — a Nim-only global that is never populated
  ## (would crash). Blob loads the fn-ptr from g_bl_ops_funcs each call.
  let pfFn {.inject.} = cast[proc(q: pointer) {.cdecl.}](
    blOpsFunc(0xBC))
  pfFn(p)

proc ke_msg_free*(param: pointer) {.exportc, cdecl.} =
  ## Free a kernel message. Blob: tail-calls `g_bl_ops_funcs[0xBC](param)`
  ## — param is already the HEADER pointer (callers subtract 12 before
  ## calling).
  platformFree(param)

proc ke_msg_free_payload(param: pointer) {.inline.} =
  if param != nil:
    ke_msg_free(cast[pointer](keMsgHdrFromPayload(param)))

proc ke_msg_discard*(param: pointer): cint {.exportc, cdecl.} =
  ## Message handler: discard (consume and free). Returns 0 = consumed.
  return KeMsgConsumed

proc ke_msg_save*(param: pointer): cint {.exportc, cdecl.} =
  ## Message handler: save (do not free, move to saved queue). Returns 2 = saved.
  ## From blob: ke_msg_save returns saved (not no-free).
  return KeMsgSaved

# ###########################################################################
#                      KERNEL: QUEUE (ke_queue_*)
# ###########################################################################

proc ke_queue_extract*(queue: ptr CoList, cmpFn: proc(elem: ptr CoListHdr, param: pointer): bool {.cdecl.}, param: pointer): ptr CoListHdr {.exportc, cdecl.} =
  ## Extract first element matching cmpFn from queue.
  var previousNode: ptr CoListHdr = nil
  var currentNode = queue.first
  while currentNode != nil:
    let nextNode = currentNode.next
    if cmpFn(currentNode, param):
      if previousNode == nil:
        queue.first = nextNode
      else:
        previousNode.next = nextNode
      if nextNode == nil:
        queue.last = previousNode
      currentNode.next = nil
      return currentNode
    previousNode = currentNode
    currentNode = nextNode
  return nil

# ###########################################################################
#                      KERNEL: INIT / FLUSH
# ###########################################################################

proc ke_init*() {.exportc, cdecl.} =
  ## Initialize the kernel subsystem.
  co_list_init(addr keMsgQueueSent)
  co_list_init(addr keMsgQueueSaved)
  co_list_init(addr keTimerQueue)
  keSavedReschedTask = TASK_NONE
  ke_evt_clear(0xFFFFFFFF'u32)

proc ke_flush*() {.exportc, cdecl.} =
  ## Flush all pending messages and timers. Blob:
  ##   while (msg = co_list_pop_front(&ke_env.q_sent))  ke_msg_free(msg)
  ##   while (msg = co_list_pop_front(&ke_env.q_saved)) ke_msg_free(msg)
  ##   while (tmr = co_list_pop_front(&ke_env.tmr_free)) g_bl_ops_funcs.free(tmr)
  ##   ke_evt_clear(0xFFFFFFFF)  # tail call
  while keMsgQueueSent.first != nil:
    let msg = co_list_pop_front(addr keMsgQueueSent)
    if msg == nil:
      break
    ke_msg_free(msg)
  while keMsgQueueSaved.first != nil:
    let msg = co_list_pop_front(addr keMsgQueueSaved)
    if msg == nil:
      break
    ke_msg_free(msg)
  let freeFnPtr = blOpsFunc(188)
  while keTimerQueue.first != nil:
    let tmr = co_list_pop_front(addr keTimerQueue)
    if tmr == nil:
      break
    if freeFnPtr != nil:
      cast[proc(p: pointer) {.cdecl.}](freeFnPtr)(tmr)
  ke_evt_clear(0xFFFFFFFF'u32)

# ###########################################################################
#                      KERNEL: TASK / STATE
# ###########################################################################

proc cmp_dest_id(elem: ptr CoListHdr, param: pointer): bool {.exportc, cdecl.} =
  ## Compare callback for ke_queue_extract: match by destId.
  let hdr = cast[ptr KeMsgHdr](elem)
  return hdr.destId == encodedArgU8(param)

proc ke_saved_queue_has_dest(taskId: uint8): bool =
  var currentNode = keMsgQueueSaved.first
  while currentNode != nil:
    if cast[ptr KeMsgHdr](currentNode).destId == taskId:
      return true
    currentNode = currentNode.next
  false

proc ke_reschedule_saved_messages(taskId: uint8,
                                  limit: uint32 = WifiSavedMsgDrainLimit): bool =
  ## Move a bounded batch of saved messages back to the sent queue.
  ## Returns true when more saved messages for the task remain.
  var moved = 0'u32
  while moved < limit:
    let node = ke_queue_extract(addr keMsgQueueSaved, cmp_dest_id,
                                cast[pointer](cast[uint](taskId)))
    if node == nil:
      if keSavedReschedTask == taskId:
        keSavedReschedTask = TASK_NONE
      return false
    let saved = irqSave()
    co_list_push_back(addr keMsgQueueSent, node)
    irqRestore(saved)
    ke_evt_set(KE_EVT_KE_MESSAGE)
    inc moved

  let more = ke_saved_queue_has_dest(taskId)
  if more:
    keSavedReschedTask = taskId
    inc nimFwDbgSavedMsgYield
    nimFwDbgSavedMsgYieldTask = taskId.uint32
    ke_evt_set(KE_EVT_KE_MESSAGE)
  elif keSavedReschedTask == taskId:
    keSavedReschedTask = TASK_NONE
  more

proc ke_task_local*(taskId: uint8): bool {.exportc, cdecl, noinline.} =
  ## Return true if taskId is a local embedded task (< TASK_API).
  ## From blob (54 bytes): ASSERT taskId <= 10, then return (taskId < 9).
  ## noinline + asm barrier: blob emits this as a real function called from
  ## ke_state_get/ke_task_schedule; without noinline GCC inlines the body.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
  if taskId > TASK_MAX:
    assert_err("ke_task.c", "ke_task.c", 127)
  return taskId < TASK_API

proc ke_state_set*(taskId: uint8, state: uint16) {.exportc, cdecl.} =
  ## Set the state of a task, and process any saved messages that match.
  ## Blob: when transitioning TASK_MM→0 (idle), clears rxl_cntrl_env[24]
  ## (RX processing flag) so the RX path resumes. Then validates via
  ## ke_task_local, stores state, re-schedules saved messages matching dest.
  if taskId == 0 and state == 0:
    rxlCntrlEnvView().processingFlag = 0
    mmState = MM_IDLE
  # Blob: bounds check taskId <= 9 (line 170) then ke_task_local (line 171).
  if taskId > 9:
    assert_err("ke_task.c", "ke_task.c", 170)
  if not ke_task_local(taskId):
    assert_err("ke_task.c", "ke_task.c", 171)
  let desc = addr keTaskDescs[taskId]
  if desc.stateCount == 0:
    assert_err("ke_task.c", "ke_task.c", 172)
  let sp = desc.statePtr
  if sp == nil:
    assert_err("ke_task.c", "ke_task.c", 177)
  # Early-out if state unchanged
  if sp[] == state: return
  sp[] = state
  discard ke_reschedule_saved_messages(taskId)

proc ke_state_get*(taskId: uint8): uint16 {.exportc, cdecl.} =
  ## Get the current state of a task.
  ## From blob: bounds check, ke_task_local validate, read statePtr.
  ## Blob assert lines: 204/205/206. GCC -Os crossjumps the three
  ## assert_err tail calls into one site; blob keeps them separate.
  ## Representation-only delta — functional parity holds.
  if taskId > 9:
    assert_err("ke_task.c", "ke_task.c", 204)
  if not ke_task_local(taskId):
    assert_err("ke_task.c", "ke_task.c", 205)
  let desc = addr keTaskDescs[taskId]
  if desc.stateCount == 0:
    assert_err("ke_task.c", "ke_task.c", 206)
  return desc.statePtr[]

proc ke_handler_search*(msgId: uint16, desc: ptr KeMsgHandlerDesc): pointer {.exportc, cdecl.} =
  ## Search a message handler descriptor for a matching handler.
  ## Returns the handler function pointer, or nil if not found.
  ## From blob: iterates handler table in reverse order (countdown from numHandlers-1).
  if desc.numHandlers == 0: return nil
  let table = desc.handlers
  var handlerIndex = desc.numHandlers.int - 1
  while handlerIndex >= 0:
    let messageHandlerEntry = keMsgHandlerEntryAt(table, handlerIndex.uint16)
    if uint16(messageHandlerEntry.msgId) == msgId:
      if messageHandlerEntry.handler == nil:
        assert_err("ke_task.c", "ke_task.c", 233)
      return messageHandlerEntry.handler
    dec handlerIndex
  return nil

proc keResumeSavedMessagesIfIdle() {.inline.} =
  if keMsgQueueSent.first == nil and keSavedReschedTask != TASK_NONE:
    discard ke_reschedule_saved_messages(keSavedReschedTask)

proc keUpdateMessageEventAfterSchedule() {.inline.} =
  let saved = irqSave()
  if keMsgQueueSent.first == nil:
    if keSavedReschedTask != TASK_NONE:
      ke_evt_set(KE_EVT_KE_MESSAGE)
    else:
      ke_evt_clear(KE_EVT_KE_MESSAGE)
  irqRestore(saved)

proc ke_task_schedule*() {.exportc, cdecl.} =
  ## Process one pending message from the sent queue.
  ## From blob: uses interrupt-protected pop, then does state-based dispatch:
  ##   1. Look up state handler table for current state → ke_handler_search
  ##   2. If not found, try default handler table → ke_handler_search
  ##   3. Call handler with (msgId, param, srcId, destId)
  ##   4. Handle return: 0=consumed(free), 1=no_free(cleanup), 2=saved
  keResumeSavedMessagesIfIdle()

  let saved = irqSave()
  let node = co_list_pop_front(addr keMsgQueueSent)
  irqRestore(saved)
  nimFwTraceU32("[WIFI-NIMFW] task_sched node=", cast[uint32](cast[uint](node)))
  # Blob uses a single ke_evt_clear site at the common tail. Use a block
  # so every exit path falls through to the same IRQ-safe queue-empty
  # check + ke_evt_clear call.
  block ktsBody:
    if node == nil:
      nimFwTrace("[WIFI-NIMFW] task_sched empty")
      break ktsBody
    let hdr = cast[ptr KeMsgHdr](node)
    let param = keMsgPayload(hdr)
    let destTask = hdr.destId
    let msgId = hdr.id
    nimFwTrace2U32("[WIFI-NIMFW] task_sched msg ", msgId.uint32, destTask.uint32)
    if destTask.int > 9:
      assert_err("ke_task.c", "ke_task.c", 261)
    if not ke_task_local(destTask):
      assert_err("ke_task.c", "ke_task.c", 262)
    let desc = addr keTaskDescs[destTask]
    if desc.stateCount == 0:
      assert_err("ke_task.c", "ke_task.c", 263)
    # Step 1: Try state-based handler lookup
    var handlerFn: pointer = nil
    if desc.stateTable != nil:
      let statePtr = desc.statePtr
      let curState = statePtr[]
      nimFwTraceU32("[WIFI-NIMFW] task_sched state=", curState.uint32)
      let stateDesc = keMsgHandlerDescAt(desc.stateTable, curState)
      handlerFn = ke_handler_search(msgId, stateDesc)
    # Step 2: If no state handler, try default handler
    if handlerFn == nil:
      if desc.defaultHandler != nil:
        let defDesc = cast[ptr KeMsgHandlerDesc](desc.defaultHandler)
        nimFwTrace2U32("[WIFI-NIMFW] task_sched def desc ",
                       cast[uint32](cast[uint](defDesc.handlers)),
                       defDesc.numHandlers.uint32)
        if defDesc.handlers != nil and defDesc.numHandlers > 4:
          let resetEntry = cast[uint](defDesc.handlers) + 4'u * 8'u
          let resetId = cast[ptr uint32](resetEntry)[]
          let resetFn = cast[ptr uint32](resetEntry + 4)[]
          nimFwTrace2U32("[WIFI-NIMFW] task_sched def reset ",
                         resetId, resetFn)
        handlerFn = ke_handler_search(msgId, defDesc)
      if handlerFn == nil:
        # No handler found: free message, fall through to common tail
        nimFwTrace("[WIFI-NIMFW] task_sched no handler")
        platformFree(node)
        break ktsBody
      else:
        nimFwTraceU32("[WIFI-NIMFW] task_sched def handler=", cast[uint32](cast[uint](handlerFn)))
    else:
      nimFwTraceU32("[WIFI-NIMFW] task_sched state handler=", cast[uint32](cast[uint](handlerFn)))
    # Step 3: Call handler. The 65 Nim handlers are all declared as
    # `(param: pointer)` (1-arg). Call with a 1-arg cast so `param`
    # (the payload) lands in a0. Previous code cast to a 4-arg type
    # matching blob's (msgId,param,destId,srcId) ABI — that put msgId
    # in a0, so Nim handlers received msgId instead of the payload.
    let handler = cast[proc(param: pointer): cint {.cdecl.}](handlerFn)
    nimFwTrace("[WIFI-NIMFW] task_sched call")
    let rawHandlerResult = handler(param)
    let normalizedHandlerResult =
      if rawHandlerResult >= KeMsgConsumed and rawHandlerResult <= KeMsgSaved:
        rawHandlerResult
      else:
        KeMsgConsumed
    if rawHandlerResult != normalizedHandlerResult:
      nimFwTrace2U32("[WIFI-NIMFW] task_sched res norm ",
                     rawHandlerResult.uint32, normalizedHandlerResult.uint32)
    else:
      nimFwTraceU32("[WIFI-NIMFW] task_sched res=", normalizedHandlerResult.uint32)
    case normalizedHandlerResult
    of KeMsgConsumed:
      ke_msg_free(node)
    of KeMsgNoFree:
      discard
    of KeMsgSaved:
      co_list_push_back(addr keMsgQueueSaved, node)
    else:
      assert_err("ke_task.c", "ke_task.c", 345)

  # Common tail: one IRQ-safe queue-empty check + ke_evt_clear
  keUpdateMessageEventAfterSchedule()

proc ke_task_sm_activating*(): bool {.exportc, cdecl.} =
  ## Check if the SM task is currently in an activating state.
  ## From blob: calls ke_state_get(TASK_SM) and checks == 9 (SM_ACTIVATING_STATE).
  return ke_state_get(TASK_SM) == SM_ACTIVATING_STATE

# ###########################################################################
#                      KERNEL: TIMERS
# ###########################################################################

proc cmp_abs_time*(a, b: ptr CoListHdr): bool {.exportc, cdecl.} =
  ## Comparator for sorted timer insert (from blob: cmp_abs_time).
  ## Returns true when (unsigned)(b.time - a.time) >= 0x11E1A301, meaning
  ## a.time is effectively BEFORE b.time (with uint32 wrap-around handling).
  let ta = cast[ptr KeTimerEntry](a)
  let tb = cast[ptr KeTimerEntry](b)
  let diff = tb.time - ta.time  # unsigned subtraction
  return diff >= (KE_TIMER_MAX_DELAY + 2)

proc cmp_timer_id*(elem: ptr CoListHdr, param: pointer): bool {.exportc, cdecl.} =
  ## Comparator for ke_queue_extract: match timer by (taskId, instId).
  ## From blob: param encodes (taskId << 16) | instId.
  let tmr = cast[ptr KeTimerEntry](elem)
  let combined = cast[uint32](param)
  let wantId = (combined shr 16).uint16
  let wantInst = (combined and 0xFF).uint8
  return tmr.id == wantId and tmr.taskId == wantInst

const
  # MAC HW timer registers (from ke_timer_hw_set disassembly)
  MACHW_TIMER_TARGET_REG = MACHW_BASE + 0x148'u   # Timer target register
  MACHW_INTC_SOFT_RESET  = MACHW_INTC_BASE + 0x050'u  # Soft reset (write 1 to reset, poll for 0)
  MACHW_INTC_STATUS_RAW  = MACHW_INTC_BASE + 0x06C'u  # IRQ status raw
  MACHW_INTC_STATUS_ACK  = MACHW_INTC_BASE + 0x070'u  # IRQ status ack (write 1 to clear)
  MACHW_INTC_UNMASK_REG  = MACHW_INTC_BASE + 0x074'u  # IRQ unmask/enable
  MACHW_INTC_FORCE_REG   = MACHW_INTC_BASE + 0x07C'u  # IRQ force set
  MACHW_INTC_GEN_STATUS  = MACHW_INTC_BASE + 0x080'u  # Gen int masked status
  MACHW_INTC_GEN_RAW     = MACHW_INTC_BASE + 0x084'u  # Gen int raw status
  MACHW_INTC_IRQ_SET_REG = MACHW_INTC_BASE + 0x088'u  # Gen int ack (write 1 to clear)
  MACHW_INTC_IRQ_STAT_REG = MACHW_INTC_BASE + 0x08C'u # Gen int unmask
  MACHW_TIMER_IRQ_BIT    = 0x100'u32               # bit 8: timer interrupt

proc wifi_nimfw_debug_snapshot*() {.exportc, cdecl.} =
  ## Capture live MAC/RX registers for UART smoke diagnostics.
  nimFwDbgRxlSnapHd = machwRxHdSubmittedHead()
  nimFwDbgRxlSnapPd = machwRxPdSubmittedHead()
  nimFwDbgRxlSnapHwHd = machwRxHwHdHead()
  nimFwDbgRxlSnapHwPd = machwRxHwPdHead()
  nimFwDbgRxlSnapIntUnmask = regRead(MACHW_INTC_UNMASK_REG)
  nimFwDbgRxlSnapGenUnmask = regRead(MACHW_INTC_IRQ_STAT_REG)
  nimFwDbgRxlSnapIrqRaw = regRead(MACHW_INTC_STATUS_RAW)
  nimFwDbgRxlSnapGenRaw = regRead(MACHW_INTC_GEN_RAW)
  nimFwDbgRxlSnapRxCtrlRaw = regRead(MACHW_RX_CNTRL_REG)
  nimFwDbgRxlSnapStatusRaw = regRead(MACHW_STATUS_REG)
  let rxlEnv = rxlCntrlEnvView()
  let rxHwEnv = rxHwDescEnvView()
  nimFwDbgRxlSnapHdStatus =
    if rxlEnv.submittedHead != nil:
      cast[ptr RxlSubmittedDescView](rxlEnv.submittedHead).status
    else:
      0'u32
  nimFwDbgRxlSnapPdStatus =
    if rxHwEnv.pdCurrent != nil:
      let pd = rxDmaProgressDescAt(rxHwEnv.pdCurrent)
      pd.status.uint32 or ((pd.usedFlag and 0xFFFF'u32) shl 16)
    else:
      0'u32
  nimFwDbgRxlSnapMask = nimFwDbgRxlSnapIntUnmask xor
    (nimFwDbgRxlSnapGenUnmask shl 16)
  nimFwDbgRxlSnapRxCtrl = nimFwDbgRxlSnapRxCtrlRaw xor
    (nimFwDbgRxlSnapStatusRaw shl 16)

proc ke_timer_hw_set*(timerEntry: ptr KeTimerEntry) {.exportc, cdecl.} =
  ## Program the HW timer to fire at the given timer entry's expiry time.
  ## From blob: writes target time to MACHW_TIMER_TARGET_REG, enables
  ## timer interrupt bit in MACHW_INTC. If entry is nil, disables timer IRQ.
  let saved = irqSave()
  if timerEntry == nil:
    # Disable timer interrupt
    var stat = regRead(MACHW_INTC_IRQ_STAT_REG)
    stat = stat and not MACHW_TIMER_IRQ_BIT
    regWrite(MACHW_INTC_IRQ_STAT_REG, stat)
  else:
    # Set target time
    regWrite(MACHW_TIMER_TARGET_REG, timerEntry.time)
    # Enable timer interrupt if not already set
    var stat = regRead(MACHW_INTC_IRQ_STAT_REG)
    if (stat and MACHW_TIMER_IRQ_BIT) == 0:
      regWrite(MACHW_INTC_IRQ_SET_REG, MACHW_TIMER_IRQ_BIT)
      stat = stat or MACHW_TIMER_IRQ_BIT
    regWrite(MACHW_INTC_IRQ_STAT_REG, stat)
  irqRestore(saved)

proc ke_timer_set*(taskId: uint16, instId: uint8, delay: uint32) {.exportc, cdecl.} =
  ## Set a kernel timer with given delay (MAC ticks).
  ## From blob: asserts on delay==0 and delay>MAX, uses ke_queue_extract with
  ## cmp_timer_id to find existing timer, uses co_list_insert with cmp_abs_time
  ## for sorted insertion, calls ke_timer_hw_set when the new timer is first.
  if delay == 0:
    assert_err("ke_timer.c", "ke_timer.c", 110)
  if delay > KE_TIMER_MAX_DELAY:
    assert_err("ke_timer.c", "ke_timer.c", 111)
  # Quick-check: is the first entry already this timer?
  var wasFirst = false
  let first = cast[ptr KeTimerEntry](keTimerQueue.first)
  if first != nil and first.id == taskId and first.taskId == instId:
    wasFirst = true
  # Extract existing timer by (taskId, instId) key
  let combined = (taskId.uint32 shl 16) or instId.uint32
  let found = ke_queue_extract(addr keTimerQueue, cmp_timer_id,
                               cast[pointer](combined))
  var existing = cast[ptr KeTimerEntry](found)
  if existing == nil:
    # Allocate new timer entry. Blob at 0x7e: `lw a5, 0(g_bl_ops_funcs+0xb8);
    # jalr a5(12)`. Nim previously used `keAllocFunc` — never populated.
    let allocFn = cast[proc(sz: uint32): pointer {.cdecl.}](
      blOpsFunc(0xB8))
    existing = cast[ptr KeTimerEntry](allocFn(12))
    assert existing != nil, "ke_timer_set: allocation failed"
    existing.id = taskId
    existing.taskId = instId
  # Compute absolute expiry time
  let now = macTimeNow()
  existing.time = now + delay
  # Sorted insertion using cmp_abs_time
  co_list_insert(addr keTimerQueue, cast[ptr CoListHdr](existing), cmp_abs_time)
  # Reprogram HW timer if this timer is now first, or was already first
  if wasFirst or (keTimerQueue.first == cast[ptr CoListHdr](existing)):
    ke_timer_hw_set(cast[ptr KeTimerEntry](keTimerQueue.first))
  # If the timer already expired (diff < 0), trigger immediate event
  let now2 = macTimeNow()
  let diff = cast[int32](existing.time - now2)
  if diff < 0:
    ke_evt_set(KE_EVT_KE_TIMER)

proc ke_timer_clear*(taskId: uint16, instId: uint8) {.exportc, cdecl.} =
  ## Remove a kernel timer.
  ## From blob: if target is first entry, pops it and reprograms HW timer.
  ## If not first, uses ke_queue_extract with cmp_timer_id (no HW reprogram
  ## needed since first timer didn't change).
  let first = cast[ptr KeTimerEntry](keTimerQueue.first)
  if first == nil: return
  if first.id == taskId and first.taskId == instId:
    # First entry matches: pop it
    discard co_list_pop_front(addr keTimerQueue)
    # Reprogram HW timer with new first entry (or nil to disable)
    let newFirst = cast[ptr KeTimerEntry](keTimerQueue.first)
    ke_timer_hw_set(newFirst)
    if newFirst != nil:
      let now = macTimeNow()
      let diff = cast[int32](newFirst.time - now)
      if diff < 0:
        assert_err("ke_timer.c", "ke_timer.c", 214)
    platformFree(cast[pointer](first))
  else:
    # Not first: search by combined key
    let combined = (taskId.uint32 shl 16) or instId.uint32
    let node = ke_queue_extract(addr keTimerQueue, cmp_timer_id,
                                cast[pointer](combined))
    if node != nil:
      platformFree(cast[pointer](node))

proc keTimerExpired(entry: ptr KeTimerEntry): bool {.inline.} =
  entry != nil and cast[int32](entry.time - macTimeNow() - 50) < 0

proc ke_timer_schedule*() {.exportc, cdecl.} =
  ## Process expired timers.
  ## From blob: loops clearing event, checking first timer. If expired,
  ## pops and sends ke_msg_send_basic. If not expired, programs HW timer
  ## and re-checks (races with HW). If queue empty, disables HW timer.
  var drained = 0'u32

  while drained < WifiTimerDrainLimit:
    ke_evt_clear(KE_EVT_KE_TIMER)
    let node = cast[ptr KeTimerEntry](keTimerQueue.first)
    if node == nil:
      # Queue empty: disable HW timer and return
      ke_timer_hw_set(nil)
      return
    let now = macTimeNow()
    let diff = cast[int32](node.time - now - 50)  # 50-tick guard from disasm
    if diff >= 0:
      # Not yet expired: reprogram HW timer
      ke_timer_hw_set(node)
      # Re-check after HW program: timer may have expired during setup
      let now2 = macTimeNow()
      let diff2 = cast[int32](node.time - now2)
      if diff2 >= 0:
        return  # Still not expired, done
      # Fell through: expired during HW setup, continue loop to process it

    # Timer expired: pop, send message, free
    let popped = co_list_pop_front(addr keTimerQueue)
    let expiredTimerEntry = cast[ptr KeTimerEntry](popped)
    ke_msg_send_basic(expiredTimerEntry.id, expiredTimerEntry.taskId, 0xFF)
    platformFree(cast[pointer](expiredTimerEntry))
    inc drained

  let nextTimer = cast[ptr KeTimerEntry](keTimerQueue.first)
  if nextTimer != nil:
    nimFwDbgKeTimerYieldHead = nextTimer.time
    if keTimerExpired(nextTimer):
      inc nimFwDbgKeTimerYield
      ke_evt_set(KE_EVT_KE_TIMER)
    else:
      ke_timer_hw_set(nextTimer)
  else:
    ke_timer_hw_set(nil)

proc ke_timer_active*(taskId: uint16, instId: uint8): bool {.exportc, cdecl.} =
  ## Check if a timer is active.
  var timerEntry = cast[ptr KeTimerEntry](keTimerQueue.first)
  while timerEntry != nil:
    if timerEntry.id == taskId and timerEntry.taskId == instId:
      return true
    timerEntry = cast[ptr KeTimerEntry](cast[ptr CoListHdr](timerEntry).next)
  return false

# ###########################################################################
#                    EVENT HANDLERS & STATISTICS
# ###########################################################################

proc bl_event_handle*(evtType: uint32) {.exportc, cdecl.} =
  ## Handle a platform event (98 bytes in blob).
  ## Blob: uses evtType as index into [0x80, 0x100] for ke_evt_clear bit,
  ## then dispatches: evtType==0 -> bl_main_event_handle(0,0);
  ## evtType!=0 -> bl_main_event_handle(evtType, &ke_env[28]), then memset(&ke_env[28], 0, 5).
  proc bl_main_event_handle(a0: uint32, a1: pointer) {.importc, cdecl.}
  let evtBit = if evtType != 0: 0x100'u32 else: 0x80'u32
  ke_evt_clear(evtBit)
  if evtType == 0:
    bl_main_event_handle(0, nil)
  else:
    let keEnvFlags = keEnvPsFlags()
    bl_main_event_handle(evtType, keEnvFlags)
    discard c_memset(keEnvFlags, 0, 5.csize_t)

proc bl_fw_statistic_dump*() {.exportc, cdecl.} =
  ## Dump firmware statistics (TX/RX counts, queue states).
  ## From blob (50 instrs): allocates 64-byte buffer, irqSave, calls log function
  ## with stats at line 158, then calls 7 sub-dump functions (txl_cntrl_dump,
  ## rxl_cntrl_dump, etc.) to print queue states, then irqRestore.
  let allocFn = cast[proc(sz: uint32): pointer {.cdecl.}](
    blOpsFunc(0xB8))
  let statisticScratch = allocFn(64)
  let saved = irqSave()
  let logFn = blOpsFunc(204)
  if logFn != nil:
    cast[proc(a: uint32, b: uint32, c: cstring, d: uint32) {.cdecl.}](logFn)(
      2, 0, "wifi_mgmr.c", 158)
  # Call dump functions matching blob's sequence (bl_utils_dump, txl_frame_dump,
  # ipc_emb_dump, txl_cntrl_env_dump, txl_cfm_dump, rxl_hwdesc_dump, rxl_cntrl_dump).
  ke_evt_clear(0x40'u32)  # clear dump event
  {.emit: ["extern void bl_utils_dump(void); bl_utils_dump();"].}
  txl_frame_dump()
  ipc_emb_dump()
  txl_cntrl_env_dump()
  txl_cfm_dump()
  rxl_hwdesc_dump()
  rxl_cntrl_dump()
  # Second log call with line 175
  if logFn != nil:
    cast[proc(a: uint32, b: uint32, c: cstring, d: uint32) {.cdecl.}](logFn)(
      2, 0, "wifi_mgmr.c", 175)
  irqRestore(saved)
  if statisticScratch != nil:
    platformFree(statisticScratch)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void bl60x_fw_dump_statistic(int);".}
proc bl60x_fw_dump_statistic*(forced: cint) {.exportc, cdecl.} =
  ## Dump firmware statistics (24 bytes in blob, 7 instrs).
  ## From blob: if forced != 0: tail-call with a0=0; if forced == 0: tail-call with a0=64.
  ## The two paths may call different functions (relocation targets).
  if forced != 0:
    # Forced dump: call with full output (a0=0)
    bl_fw_statistic_dump()
  else:
    # Periodic dump: call with limited output (a0=64)
    # Use ke_evt_set to trigger stats event
    ke_evt_set(0x40'u32)
    bl_fw_statistic_dump()

# ###########################################################################
#                     HAL MAC HW (hal_machw_*)
# ###########################################################################

proc tcpip_stack_input(entry: pointer, descFlag: uint32, payload: pointer, bufOff: uint32, dmaArray: pointer, fcFlag: uint32): cint {.importc: "tcpip_stack_input", cdecl.}
  ## External: fast-path delivery of RX data frames to TCP/IP stack.

proc bl808ApplyPureRfMacTimingBaseline() {.inline.} =
  ## Match the passing vendor MAC timing state observed at the scan
  ## mm_active edge. These timing registers directly gate RX/TX PHY delays.
  regWrite(MACHW_BASE + 0x0E8'u, 0x00016809'u32)
  regWrite(MACHW_BASE + 0x0F0'u, 0x05414002'u32)
  regWrite(MACHW_BASE + 0x0F4'u, 0x0001900A'u32)
  regWrite(MACHW_BASE + 0x0F8'u, 0x00028010'u32)
  regWrite(MACHW_BASE + 0x104'u, 0x0C814028'u32)
  nimFwDbgMacTimingE8 = regRead(MACHW_BASE + 0x0E8'u)
  nimFwDbgMacTimingF0 = regRead(MACHW_BASE + 0x0F0'u)
  nimFwDbgMacTimingF4 = regRead(MACHW_BASE + 0x0F4'u)
  nimFwDbgMacTimingF8 = regRead(MACHW_BASE + 0x0F8'u)
  nimFwDbgMacTiming104 = regRead(MACHW_BASE + 0x104'u)

proc hal_machw_init*() {.exportc, cdecl.} =
  ## Initialize MAC HW registers.
  ## Full reverse-engineered implementation from blob (372 instructions).
  ## Performs soft reset, configures MAC core timing at MACHW_BASE,
  ## rescales timing fields to 40 MHz clock, sets up INTC/coex/RX control.

  const
    MACHW_CLK_FREQ       = 40'u32           # BL808 MAC clock = 40 MHz
    # Register offsets from MACHW_BASE
    REG_04C              = MACHW_BASE + 0x04C'u  # STATUS / gen_int / control bits
    REG_054              = MACHW_BASE + 0x054'u  # DOZE_CNTRL2
    REG_060              = MACHW_BASE + 0x060'u  # RX_CNTRL
    REG_064              = MACHW_BASE + 0x064'u  # RX max lifetime
    REG_09C              = MACHW_BASE + 0x09C'u  # MAX_POWER_LEVEL / antenna cfg
    REG_0A0              = MACHW_BASE + 0x0A0'u  # TRNG / rate-control seed
    REG_0D8              = MACHW_BASE + 0x0D8'u  # Signature / version
    REG_0E4              = MACHW_BASE + 0x0E4'u  # Timing config (clk + slot fields)
    REG_0E8              = MACHW_BASE + 0x0E8'u  # Timing config 2
    REG_0EC              = MACHW_BASE + 0x0EC'u  # Timing config 3
    REG_0F0              = MACHW_BASE + 0x0F0'u  # PLL divider / clock mode
    REG_0F4              = MACHW_BASE + 0x0F4'u  # Timing config 4
    REG_0F8              = MACHW_BASE + 0x0F8'u  # Timing config 5
    REG_104              = MACHW_BASE + 0x104'u  # Timing config 6
    REG_114              = MACHW_BASE + 0x114'u  # TX power / CCA threshold
    REG_150              = MACHW_BASE + 0x150'u  # Max RX length
    REG_224              = MACHW_BASE + 0x224'u  # DMA debug / clear
    REG_310              = MACHW_BASE + 0x310'u  # MAC core control 2
    REG_400              = MACHW_BASE + 0x400'u  # BCN_STATUS (same as MACHW_BCN_STATUS_REG)
    REG_404              = MACHW_BASE + 0x404'u  # BCN interval
    REG_410              = MACHW_BASE + 0x410'u  # BCN enable
    REG_510              = MACHW_BASE + 0x510'u  # Rate control config
    COEX_004             = COEX_BASE + 0x004'u   # COEX control
    COEX_028             = COEX_BASE + 0x028'u   # COEX timing

  var registerWriteback: uint32

  # -----------------------------------------------------------------------
  # Block 1: Trigger soft reset and wait for completion (0x0a - 0x1a)
  # -----------------------------------------------------------------------
  regWrite(MACHW_INTC_SOFT_RESET, 1'u32)
  # Poll blmac_soft_reset_getf() until low byte reads 0
  discard waitMacSoftResetClear()

  # -----------------------------------------------------------------------
  # Block 2: Configure BCN status / MAC core mode (0x1c - 0x5c)
  # -----------------------------------------------------------------------
  # Write beacon interval value to BCN_STATUS+4
  regWrite(REG_404, 0x0024F637'u32)

  # Read BCN_STATUS, set bit 0 (enable), write back
  registerWriteback = regRead(REG_400)
  registerWriteback = registerWriteback or 0x01'u32
  regWrite(REG_400, registerWriteback)

  # Read BCN_STATUS, clear bit 0 (disable), write back
  registerWriteback = regRead(REG_400)
  registerWriteback = registerWriteback and not 0x01'u32
  regWrite(REG_400, registerWriteback)

  # Write 0x68 = core mode (basic MAC, ACK/CTS enabled, etc)
  regWrite(REG_400, 0x68'u32)

  # Read back, set bit 0 (re-enable)
  registerWriteback = regRead(REG_400)
  registerWriteback = registerWriteback or 0x01'u32
  regWrite(REG_400, registerWriteback)

  # Read back, clear bit 5 (soft-reset-done indicator)
  registerWriteback = regRead(REG_400)
  registerWriteback = registerWriteback and not 0x20'u32
  regWrite(REG_400, registerWriteback)

  # -----------------------------------------------------------------------
  # Block 3: COEX and early config (0x5e - 0x6c)
  # -----------------------------------------------------------------------
  regWrite(COEX_004, 0x5010001F'u32)
  regWrite(REG_410, 1'u32)
  regWrite(COEX_028, 10'u32)

  # -----------------------------------------------------------------------
  # Block 4: Get clock frequency (0x6e - 0x7e)
  # In the blob this calls an external function returning the MAC clock freq.
  # BL808 MAC always runs at 40 MHz.
  # -----------------------------------------------------------------------
  let newClk = phy_get_mac_freq()

  # -----------------------------------------------------------------------
  # Block 5: Read old clock from reg[0xE4] and rescale timing fields
  # (0x76 - 0x306)
  # -----------------------------------------------------------------------
  let regE4val = regRead(REG_0E4)
  let oldClk = regE4val and 0xFF'u32  # bits[7:0] = current clock freq

  # Avoid division by zero; if oldClk is 0 treat as identity (use newClk)
  let divisor = if oldClk == 0: newClk else: oldClk

  # Write new clock freq (40) into bits[7:0] of reg[0xE4]
  registerWriteback = regRead(REG_0E4)
  registerWriteback = (registerWriteback and 0xFFFFFF00'u32) or (MACHW_CLK_FREQ and 0xFF'u32)
  regWrite(REG_0E4, registerWriteback)

  # --- Rescale reg[0xE4] bits[17:8] (10-bit field: slot time) ---
  block:
    let slotTimeControl = regRead(REG_0E4)
    let slotTimeField = (slotTimeControl shr 8) and 0x3FF'u32  # extract bits[17:8]
    let scaled = ((slotTimeField * newClk) div divisor) shl 8
    # Assert no overflow into bits[23:18]
    if (scaled and 0x00FC0000'u32) != 0:
      assert_err("hal_machw.c", "hal_machw.c", 0x1D59.cint)
    # Write back bits[17:8]
    registerWriteback = regRead(REG_0E4)
    registerWriteback = (registerWriteback and 0xFFFC00FF'u32) or (scaled and 0x0003FF00'u32)
    regWrite(REG_0E4, registerWriteback)

  # --- Set reg[0xE4] bits[27:18] = 0x88 (fixed value, OR'd as 0x02200000) ---
  registerWriteback = regRead(REG_0E4)
  registerWriteback = (registerWriteback and 0xF003FFFF'u32) or 0x02200000'u32
  regWrite(REG_0E4, registerWriteback)

  # --- Rescale reg[0xE8] bits[23:8] (16-bit field: SIFS time) ---
  block:
    let sifsTimeControl = regRead(REG_0E8)
    let sifsTimeField = (sifsTimeControl shr 8) and 0xFFFF'u32  # extract bits[23:8]
    let scaled = ((sifsTimeField * newClk) div divisor) shl 8
    # Merge: keep bits[31:24] and bits[7:0], replace bits[23:8]
    let preserved = sifsTimeControl and 0xFF0000FF'u32
    regWrite(REG_0E8, (scaled and 0x00FFFF00'u32) or preserved)

  # --- Set reg[0xEC] bits[27:20] = 0x27 (fixed, OR'd as 0x02700000) ---
  registerWriteback = regRead(REG_0EC)
  registerWriteback = (registerWriteback and 0xC00FFFFF'u32) or 0x02700000'u32
  regWrite(REG_0EC, registerWriteback)

  # --- Rescale reg[0xEC] bits[19:10] (10-bit field) ---
  block:
    let machwTimingEcControl = regRead(REG_0EC)
    let timingEcField = (machwTimingEcControl shr 10) and 0x3FF'u32
    let scaled = ((timingEcField * newClk) div divisor) shl 10
    # Assert no overflow into bits[25:20]
    if (scaled and 0x03F00000'u32) != 0:
      assert_err("hal_machw.c", "hal_machw.c", 0x1EA2.cint)
    # Write back bits[19:10]
    registerWriteback = regRead(REG_0EC)
    registerWriteback = (registerWriteback and 0xFFF003FF'u32) or (scaled and 0x000FFC00'u32)
    regWrite(REG_0EC, registerWriteback)

  # --- Set reg[0xEC] bits[9:0] = 180 (0xB4) ---
  registerWriteback = regRead(REG_0EC)
  registerWriteback = (registerWriteback and 0xFFFFFC00'u32) or 180'u32
  regWrite(REG_0EC, registerWriteback)

  # --- Set reg[0xF0] bits[1:0] based on clock frequency ---
  registerWriteback = regRead(REG_0F0)
  if newClk <= 29:
    registerWriteback = registerWriteback or 0x03'u32               # divider = 3
  elif newClk <= 59:
    registerWriteback = (registerWriteback and not 0x03'u32) or 0x02'u32  # divider = 2
  else:
    registerWriteback = (registerWriteback and not 0x03'u32) or 0x01'u32  # divider = 1
  regWrite(REG_0F0, registerWriteback)

  # --- Rescale reg[0xF4] bits[23:8] (16-bit field) ---
  block:
    let machwTimingF4Control = regRead(REG_0F4)
    let timingF4Field = (machwTimingF4Control shr 8) and 0xFFFF'u32
    let scaled = ((timingF4Field * newClk) div divisor) shl 8
    let preserved = machwTimingF4Control and 0xFF0000FF'u32
    regWrite(REG_0F4, (scaled and 0x00FFFF00'u32) or preserved)

  # --- Rescale reg[0xF8] bits[23:8] (16-bit field) ---
  block:
    let machwTimingF8Control = regRead(REG_0F8)
    let timingF8Field = (machwTimingF8Control shr 8) and 0xFFFF'u32
    let scaled = ((timingF8Field * newClk) div divisor) shl 8
    let preserved = machwTimingF8Control and 0xFF0000FF'u32
    regWrite(REG_0F8, (scaled and 0x00FFFF00'u32) or preserved)

  # --- Rescale reg[0x104] bits[29:20] (10-bit field) ---
  block:
    let machwTiming104Control = regRead(REG_104)
    let timing104HighField = (machwTiming104Control shr 20) and 0x3FF'u32
    let scaled = ((timing104HighField * newClk) div divisor) shl 20
    # Assert no overflow into bits[31:30]
    if (scaled and 0xC0000000'u32) != 0:
      assert_err("hal_machw.c", "hal_machw.c", 0x228A.cint)
    # Write back bits[29:20], preserve rest
    registerWriteback = regRead(REG_104)
    registerWriteback = (registerWriteback and 0xC00FFFFF'u32) or (scaled and 0x3FF00000'u32)
    regWrite(REG_104, registerWriteback)

  # --- Rescale reg[0x104] bits[19:10] (10-bit field) ---
  block:
    let machwTiming104Control = regRead(REG_104)
    let timing104MidField = (machwTiming104Control shr 10) and 0x3FF'u32
    let scaled = ((timing104MidField * newClk) div divisor) shl 10
    # Assert no overflow into bits[25:20]
    if (scaled and 0x03F00000'u32) != 0:
      assert_err("hal_machw.c", "hal_machw.c", 0x22A4.cint)
    # Write back bits[19:10], preserve rest
    registerWriteback = regRead(REG_104)
    registerWriteback = (registerWriteback and 0xFFF003FF'u32) or (scaled and 0x000FFC00'u32)
    regWrite(REG_104, registerWriteback)

  # --- Rescale reg[0x104] bits[9:0] (10-bit field) ---
  block:
    let machwTiming104Control = regRead(REG_104)
    let timing104LowField = machwTiming104Control and 0x3FF'u32
    let scaled = (timing104LowField * newClk) div divisor
    # Assert no overflow beyond 10 bits
    if (scaled and 0xFC00'u32) != 0:
      assert_err("hal_machw.c", "hal_machw.c", 0x22BE.cint)
    # Write back bits[9:0], preserve rest
    registerWriteback = regRead(REG_104)
    registerWriteback = (registerWriteback and 0xFFFFFC00'u32) or (scaled and 0x3FF'u32)
    regWrite(REG_104, registerWriteback)

  # -----------------------------------------------------------------------
  # Block 6: INTC / IRQ configuration (0x308 - 0x320)
  # -----------------------------------------------------------------------
  # Write IRQ unmask value to INTC unmask register
  regWrite(MACHW_INTC_UNMASK_REG, 0x8373F14C'u32)

  # Clear bit 11 in STATUS register (0x4C)
  registerWriteback = regRead(REG_04C)
  registerWriteback = registerWriteback and 0xFFFFF7FF'u32  # clear bit 11
  regWrite(REG_04C, registerWriteback)

  # -----------------------------------------------------------------------
  # Block 7: Signature / version assert (0x322 - 0x34a)
  # Read reg[0xD8] bits[31:24] = HW version, must be > 11
  # -----------------------------------------------------------------------
  block:
    let sig = regRead(REG_0D8)
    let version = sig shr 24
    if version <= 11:
      assert_err("hal_machw.c", "hal_machw.c", 351.cint)

  # -----------------------------------------------------------------------
  # Block 8: Debug init via function pointer (0x34c - 0x362)
  # In blob: calls dbg_init(str, 2, 12, 8) through a function pointer.
  # This is a debug/logging init call; skip in reimplementation.
  # -----------------------------------------------------------------------
  # (no-op: debug init not critical for MAC HW operation)

  # -----------------------------------------------------------------------
  # Block 9: Final register configuration (0x364 - 0x45a)
  # -----------------------------------------------------------------------

  # Write CCA/timing config to reg[0xD8]
  regWrite(REG_0D8, 0x00020C08'u32)

  # Write to INTC gen status register
  regWrite(MACHW_INTC_GEN_STATUS, 0x800A07C0'u32)

  # Set bits in STATUS register (0x4C): OR in 0x040007C0
  # (bits 26, 10, 9, 8, 7, 6 = active_clk_gate, CCA, TX, RX enables)
  registerWriteback = regRead(REG_04C)
  registerWriteback = registerWriteback or 0x040007C0'u32
  regWrite(REG_04C, registerWriteback)

  # Set bit 16 in DOZE_CNTRL2 (0x54)
  registerWriteback = regRead(REG_054)
  registerWriteback = (registerWriteback and 0xFFFEFFFF'u32) or 0x00010000'u32
  regWrite(REG_054, registerWriteback)

  # Write RX control register (0x60) = 0x7FFFFFDE
  regWrite(REG_060, 0x7FFFFFDE'u32)

  # Write TX power / CCA threshold (0x114) = 0x0005010A
  regWrite(REG_114, 0x0005010A'u32)

  # Write RX max lifetime (0x64) = 0xFF900064
  regWrite(REG_064, 0xFF900064'u32)

  # Write max RX length (0x150) = 0x1000
  regWrite(REG_150, 0x00001000'u32)

  # Clear DMA debug register (0x224) = 0
  regWrite(REG_224, 0'u32)

  # Write rate-control seed (0xA0) = 0x2020
  regWrite(REG_0A0, 0x00002020'u32)

  # Set bit 12 in STATUS register (0x4C)
  registerWriteback = regRead(REG_04C)
  registerWriteback = (registerWriteback and 0xFFFFEFFF'u32) or 0x00001000'u32
  regWrite(REG_04C, registerWriteback)

  # Set bit 13 in STATUS register (0x4C)
  registerWriteback = regRead(REG_04C)
  registerWriteback = (registerWriteback and 0xFFFFDFFF'u32) or 0x00002000'u32
  regWrite(REG_04C, registerWriteback)

  # Write rate control config (0x510) = 0x1C25
  regWrite(REG_510, 0x00001C25'u32)

  # Set bit 7 in MAC core control 2 (0x310)
  registerWriteback = regRead(REG_310)
  registerWriteback = registerWriteback or 0x80'u32
  regWrite(REG_310, registerWriteback)

  # -----------------------------------------------------------------------
  # Block 10: Antenna / TX chain config (0x402 - 0x448)
  # Call phy_get_ntx() to get number of extra TX chains.
  # Write (ntx + 1) << 26 into reg[0x9C] bits[28:26].
  # -----------------------------------------------------------------------
  block:
    let ntx = phy_get_ntx().uint32
    let ntxField = (ntx + 1) shl 26
    # Assert no overflow into bits[31:29]
    if (ntxField and 0xE0000000'u32) != 0:
      assert_err("hal_machw.c", "hal_machw.c", 0x1539.cint)
    # Write bits[28:26] of reg[0x9C]
    registerWriteback = regRead(REG_09C)
    registerWriteback = (registerWriteback and 0xE3FFFFFF'u32) or (ntxField and 0x1C000000'u32)
    regWrite(REG_09C, registerWriteback)

  # Set bit 25 in STATUS register (0x4C)
  registerWriteback = regRead(REG_04C)
  registerWriteback = (registerWriteback and 0xFDFFFFFF'u32) or 0x02000000'u32
  regWrite(REG_04C, registerWriteback)
  bl808ApplyPureRfMacTimingBaseline()

proc hal_machw_reset*() {.exportc, cdecl.} =
  ## Reset MAC HW: clear state, disable gen-int enable bit, reset DMA,
  ## reconfigure interrupt controller, then re-enable gen-int.
  ## From blob: 0x44B00038 is STATE_CNTRL, 0x44B0004C is STATUS,
  ## 0x44B00054 is DOZE_CNTRL2, 0x44B08050-0x44B0808C are INTC regs.

  # Read state register (touch / prefetch)
  discard regRead(MACHW_STATE_CNTRL_REG)

  # Clear bit 7 (gen-int enable) in STATUS register (0x44B0004C)
  var status = regRead(MACHW_STATUS_REG)
  status = status and not 0x80'u32
  regWrite(MACHW_STATUS_REG, status)

  # Write 0 to STATE_CNTRL -- force to IDLE
  regWrite(MACHW_STATE_CNTRL_REG, 0)

  # Write 0x7C (124) to DOZE_CNTRL2 register
  regWrite(MACHW_DOZE_CNTRL2_REG, 0x7C'u32)

  # Poll STATE_CNTRL until lower 4 bits == 0 (state machine fully idle)
  discard waitRegLowNibbleClear(MACHW_STATE_CNTRL_REG)

  # Clear "idle request pending" flag (bit 2) in halMachwStatusFlags
  halMachwStatusFlags = halMachwStatusFlags and not 0x04'u32

  # Reconfigure DOZE_CNTRL2: clear bit 16, set bit 16
  # (clear bits [16] field, set to 0x10000)
  var doze = regRead(MACHW_DOZE_CNTRL2_REG)
  doze = doze and 0xFFFEFFFF'u32   # clear bit 16
  doze = doze or  0x00010000'u32   # set bit 16
  regWrite(MACHW_DOZE_CNTRL2_REG, doze)

  # Clear lower 6 bits of GEN_INT_UNMASK (0x44B0808C)
  var genUnmask = regRead(MACHW_INTC_IRQ_STAT_REG)
  genUnmask = genUnmask and 0xFFFFFFC0'u32
  regWrite(MACHW_INTC_IRQ_STAT_REG, genUnmask)

  # Write 0xFFFFFFFF to IRQ_FORCE (0x44B0807C) -- clear all pending
  regWrite(MACHW_INTC_FORCE_REG, 0xFFFFFFFF'u32)

  # Write 0x037FF187 to IRQ_STATUS_ACK (0x44B08070) -- acknowledge
  regWrite(MACHW_INTC_STATUS_ACK, 0x037FF187'u32)

  # Set bit 31 in IRQ_UNMASK (0x44B08074): read, clear bit 31, set bit 31
  var unmask = regRead(MACHW_INTC_UNMASK_REG)
  unmask = unmask and not 0x80000000'u32
  unmask = unmask or 0x80000000'u32
  regWrite(MACHW_INTC_UNMASK_REG, unmask)

  # Set bit 31 in GEN_INT_STATUS (0x44B08080): read, clear bit 31, set bit 31
  var genStatus = regRead(MACHW_INTC_GEN_STATUS)
  genStatus = genStatus and not 0x80000000'u32
  genStatus = genStatus or 0x80000000'u32
  regWrite(MACHW_INTC_GEN_STATUS, genStatus)

  # Set bit 7 (gen-int enable) in STATUS register (0x44B0004C)
  status = regRead(MACHW_STATUS_REG)
  status = status or 0x80'u32
  regWrite(MACHW_STATUS_REG, status)

proc hal_machw_stop*() {.exportc, cdecl.} =
  ## Stop MAC HW by triggering soft reset and polling until complete.
  ## From blob: writes 1 to MACHW_INTC_SOFT_RESET (0x44B08050),
  ## then calls blmac_soft_reset_getf in a loop until it returns 0.

  # Trigger soft reset
  regWrite(MACHW_INTC_SOFT_RESET, 1)

  # Poll until soft reset completes via blmac_soft_reset_getf (blob: call in loop)
  discard waitMacSoftResetClear()

proc hal_machw_idle_req*() {.exportc, cdecl.} =
  ## Request MAC HW transition to IDLE state.
  ## From blob: asserts state != 0, disables interrupts, sets an absolute
  ## timer 50000 ticks ahead, configures idle interrupt, clears state register,
  ## sets idle-pending flag, restores interrupts.

  # Read current state -- assert it's not already IDLE (lower 4 bits != 0).
  # Blob uses assert_rec here (a recoverable-assert sink); matching the
  # call graph requires the same helper name.
  let state = regRead(MACHW_STATE_CNTRL_REG) and 0xF'u32
  if state == 0:
    assert_rec("hal_machw.c", "hal_machw.c", 277)
    return

  # Save and disable interrupts
  let saved = irqSave()

  # Read current MAC timestamp, add 50000 (0xC350), write to abs timer target
  let tsNow = regRead(MACHW_TIMLO_REG)
  regWrite(MACHW_ABS_TIMER_REG, tsNow + 0xC350'u32)

  # Write 0x20 (bit 5) to GEN_INT_ACK (0x44B08088) -- clear idle int
  regWrite(MACHW_INTC_IRQ_SET_REG, 0x20'u32)

  # Set bit 5 in GEN_INT_UNMASK (0x44B0808C) -- enable idle interrupt
  var genUnmask = regRead(MACHW_INTC_IRQ_STAT_REG)
  genUnmask = genUnmask or 0x20'u32
  regWrite(MACHW_INTC_IRQ_STAT_REG, genUnmask)

  # Write 4 (bit 2) to IRQ_STATUS_ACK (0x44B08070) -- clear idle IRQ
  regWrite(MACHW_INTC_STATUS_ACK, 0x04'u32)

  # Set bit 2 in IRQ_UNMASK (0x44B08074) -- enable idle IRQ
  var unmask = regRead(MACHW_INTC_UNMASK_REG)
  unmask = unmask or 0x04'u32
  regWrite(MACHW_INTC_UNMASK_REG, unmask)

  # Write 0 to STATE_CNTRL -- request transition to IDLE
  regWrite(MACHW_STATE_CNTRL_REG, 0)

  # Set "idle request pending" flag (bit 2) in halMachwStatusFlags
  halMachwStatusFlags = halMachwStatusFlags or 0x04'u32

  # Restore interrupts
  irqRestore(saved)

proc hal_machw_disable_int*() {.exportc, cdecl.} =
  ## Disable MAC HW interrupts by clearing bit 31 in both
  ## IRQ_UNMASK (0x44B08074) and GEN_INT_STATUS (0x44B08080).
  ## From blob: clears the top-level enable bit that gates all MAC interrupts.

  # Clear bit 31 in IRQ_UNMASK (0x44B08074)
  var unmask = regRead(MACHW_INTC_UNMASK_REG)
  unmask = unmask and not 0x80000000'u32
  regWrite(MACHW_INTC_UNMASK_REG, unmask)

  # Clear bit 31 in GEN_INT_STATUS (0x44B08080)
  var genStatus = regRead(MACHW_INTC_GEN_STATUS)
  genStatus = genStatus and not 0x80000000'u32
  regWrite(MACHW_INTC_GEN_STATUS, genStatus)

proc hal_machw_search_addr*(macAddrPtr: pointer, unusedCompatArg: uint32): uint32 {.exportc, cdecl.} =
  ## Search MAC HW address table for a MAC address (32 instrs).
  ## From blob: writes the 6-byte MAC address into MACHW registers at
  ## 0x24B000BC (lower 4 bytes) and 0x24B000C0 (upper 2 bytes).
  ## Writes 0x20000000 to search trigger register 0x24B000C4.
  ## Polls 0x24B000C4 until bit 29 (0x20000000) clears.
  ## Then checks bit 28 (0x10000000): if set, result = 0xFF (not found),
  ## else result = ((reg >> 16) - 8) & 0xFF.
  discard unusedCompatArg
  let addrView = macAddrAt(macAddrPtr)
  # Write to MACHW search registers
  regWrite(MACHW_BASE + 0x0BC'u, addrView.lowLe)
  regWrite(MACHW_BASE + 0x0C0'u, addrView.highLe)
  # Trigger search
  regWrite(MACHW_BASE + 0x0C4'u, 0x20000000'u32)
  if not waitRegMaskClear(MACHW_BASE + 0x0C4'u, 0x20000000'u32):
    return 0xFF'u32
  let status = regRead(MACHW_BASE + 0x0C4'u)
  # Vendor treats bit 28 as "not found"; the found entry is encoded as
  # the HW address slot in bits [23:16], biased by +8 for STA slots.
  if (status and 0x10000000'u32) != 0:
    return 0xFF'u32
  ((status shr 16) - 8'u32) and 0xFF'u32

proc hal_machw_monitor_mode*(enable: bool) {.exportc, cdecl.} =
  ## Enable monitor mode in MAC HW.
  ## From blob: disables RX/TX complete interrupts, enables promiscuous
  ## reception bits in STATUS_REG, configures RX filter, sets bandwidth fields.
  ## Note: blob ignores the `enable` parameter -- always enables monitor mode.

  # Clear bit 0 in IRQ_UNMASK (disable RX complete interrupt)
  var unmask = regRead(MACHW_INTC_UNMASK_REG)
  unmask = unmask and not 0x01'u32
  regWrite(MACHW_INTC_UNMASK_REG, unmask)

  # Clear bit 1 in IRQ_UNMASK (disable TX complete interrupt)
  unmask = regRead(MACHW_INTC_UNMASK_REG)
  unmask = unmask and not 0x02'u32
  regWrite(MACHW_INTC_UNMASK_REG, unmask)

  # Set bits [10:8] (0x700) in STATUS_REG (enable promiscuous/monitor bits)
  var status = regRead(MACHW_STATUS_REG)
  status = status or 0x700'u32
  regWrite(MACHW_STATUS_REG, status)

  # Compute monitor RX filter mask: 0x80000000 XOR 0xFFFFFFDE = 0x7FFFFFDE
  let monitorFilter = 0x7FFFFFDE'u32

  # Store to halMachwRxCntrlBackup
  halMachwRxCntrlBackup = monitorFilter

  # Combine with existing status flags and write to RX_CNTRL_REG (0x44B00060)
  let rxCntrl = monitorFilter or halMachwStatusFlags
  regWrite(MACHW_RX_CNTRL_REG, rxCntrl)

  # Configure bandwidth field in STATUS_REG: clear bits [16:14], set bits [15:14] (0xC000)
  status = regRead(MACHW_STATUS_REG)
  status = status and 0xFFFE3FFF'u32   # clear bits [16:14]
  status = status or  0x0000C000'u32   # set bits [15:14]
  regWrite(MACHW_STATUS_REG, status)

  # Set bit 13 in STATUS_REG
  status = regRead(MACHW_STATUS_REG)
  status = status and not 0x2000'u32   # clear bit 13
  status = status or 0x2000'u32        # set bit 13
  regWrite(MACHW_STATUS_REG, status)

proc hal_machw_sleep_check*(): bool {.exportc, cdecl.} =
  ## Check if MAC HW can enter sleep mode (44 instrs in blob).
  ## From blob: reads active AC register (0x24B0808C), loops through 10 AC bits.
  ## For each active AC: reads per-AC timestamp from channel status array
  ## (MACHW_BASE+0x128 + i*4), computes time delta vs current MAC time.
  ## If (perAcTime - macTime) > -2000 (recently active): does a second check
  ## with 5000-tick threshold. If still too recent: returns false (cannot sleep).
  ## If all ACs pass: returns true (can sleep).
  const
    MACHW_ACTIVE_AC_REG  = MACHW_INTC_BASE + 0x08C'u
    MACHW_CHAN_STAT_BASE = MACHW_BASE + 0x128'u
  let activeAcs = regRead(MACHW_ACTIVE_AC_REG)
  let macTime = regRead(MACHW_TIMLO_REG)
  for accessCategoryIndex in 0'u32 ..< 10:
    let acBit = 1'u32 shl accessCategoryIndex
    if (activeAcs and acBit) == 0:
      continue
    # Read per-AC channel timestamp
    let perAcTime = regRead(MACHW_CHAN_STAT_BASE + accessCategoryIndex * 4)
    # Check if recently active: -2000 - macTime + perAcTime < 0 means recent
    let delta = cast[int32](-2000) - cast[int32](macTime) + cast[int32](perAcTime)
    if delta >= 0:
      continue  # old enough, this AC is fine
    # Recent activity: secondary check with 5000-tick window
    let macTime2 = regRead(MACHW_TIMLO_REG)
    let longDelta = 5000'i32 - cast[int32](macTime2) + cast[int32](perAcTime)
    if longDelta < 0:
      assert_err("hal_machw.c", "hal_machw.c", 595)
      return false
  return true

{.emit: "__attribute__((optimize(\"crossjumping\"))) void hal_machw_gen_handler(void);".}
proc hal_machw_gen_handler*() {.exportc, cdecl.} =
  ## General MAC HW interrupt handler.
  ## From blob (243 instructions): reads INTC status, acknowledges, then dispatches
  ## each interrupt bit to the appropriate handler.
  ##
  ## INTC status bit map:
  ##   bits 0+18 (0x40001): primary TBTT
  ##   bits 1+19 (0x80002): secondary TBTT
  ##   bit 2:  idle transition (MAC state machine reached idle)
  ##   bit 3:  gen int (secondary interrupt controller, dispatched further)
  ##   bit 7:  unexpected (assert_rec)
  ##   bits 8,12-17,20-22,24-25: unexpected (assert_rec)
  ##
  ## Gen int sub-bits (from MACHW_INTC_GEN_RAW):
  ##   bit 8 (0x100): kernel timer expiry -> KE_EVT_KE_TIMER
  ##   bit 6 (0x040): RX timeout  -> rxl_timeout_int_handler()
  ##   bit 7 (0x080): MM timer expiry -> KE_EVT_MM_TIMER
  ##   bits 0-5:      unexpected (assert_rec)

  # Step 1: Read raw status, mask with unmask register, acknowledge
  let rawStatus = regRead(MACHW_INTC_STATUS_RAW)
  let unmask = regRead(MACHW_INTC_UNMASK_REG)
  let status = unmask and rawStatus
  inc nimFwDbgMachwGen
  nimFwDbgMachwStatus = rawStatus or (status shl 16)
  regWrite(MACHW_INTC_STATUS_ACK, status)
  if status != 0'u32 and (status and 0x0F3FFB8C'u32) != 0'u32:
    nimFwTrace2U32("[WIFI-NIMFW] machw_status ", rawStatus, unmask)
    nimFwTrace2U32("[WIFI-NIMFW] machw_status2 ",
                   status,
                   regRead(MACHW_INTC_GEN_RAW))

  # Step 2: Primary TBTT (bits 0 + 18 = 0x40001)
  if (status and 0x00040001'u32) != 0:
    ke_evt_set(KE_EVT_PRIM_TBTT)

  # Step 3: Secondary TBTT (bits 1 + 19 = 0x80002)
  if (status and 0x00080002'u32) != 0:
    ke_evt_set(KE_EVT_SEC_TBTT)

  # Step 4: Idle transition (bit 2)
  if (status and 0x04'u32) != 0:
    # Read MAC state machine current state (lower 4 bits)
    let macState = regRead(MACHW_STATE_CNTRL_REG) and 0xF'u32
    if macState != 0:
      # State machine not idle yet -- this is an assertion in the blob (line 139)
      assert_rec("hal_machw_gen_handler", "hal_machw.c", 139)
    else:
      # MAC is idle: clear gen int bit 5 (0x20) from gen int unmask
      var genUnmask = regRead(MACHW_INTC_IRQ_STAT_REG)
      genUnmask = genUnmask and not 0x20'u32
      regWrite(MACHW_INTC_IRQ_STAT_REG, genUnmask)
      # Clear bit 2 in ps_env status flags (word at offset 4)
      let ps = psEnvView()
      ps.statusFlags = ps.statusFlags and not 0x04'u32
      # Signal idle event
      ke_evt_set(KE_EVT_IDLE)

  # Step 5: Gen int (bit 3) -- secondary interrupt controller dispatch
  if (status and 0x08'u32) != 0:
    # Read gen int raw status and acknowledge all bits
    let genStatus = regRead(MACHW_INTC_GEN_RAW)
    nimFwDbgMachwGenStatus = genStatus
    regWrite(MACHW_INTC_IRQ_SET_REG, genStatus)

    # Gen bit 8 (0x100): timer expiry
    if (genStatus and 0x100'u32) != 0:
      ke_evt_set(KE_EVT_KE_TIMER)

    # Gen bit 6 (0x40): RX timeout
    if (genStatus and 0x40'u32) != 0:
      rxl_timeout_int_handler()

    # Gen bit 7 (0x80): MM timer expiry
    if (genStatus and 0x80'u32) != 0:
      ke_evt_set(KE_EVT_MM_TIMER)

    # Gen bit 0 (0x01): unexpected -- assert (line 634)
    if (genStatus and 0x01'u32) != 0:
      assert_rec("hal_machw_gen_handler", "hal_machw.c", 634)

    # Gen bits 1-5: unexpected -- assert and skip remaining gen bits
    if (genStatus and 0x02'u32) != 0:
      assert_rec("hal_machw_gen_handler", "hal_machw.c", 637)
    elif (genStatus and 0x04'u32) != 0:
      assert_rec("hal_machw_gen_handler", "hal_machw.c", 638)
    elif (genStatus and 0x08'u32) != 0:
      assert_rec("hal_machw_gen_handler", "hal_machw.c", 639)
    elif (genStatus and 0x10'u32) != 0:
      assert_rec("hal_machw_gen_handler", "hal_machw.c", 640)
    elif (genStatus and 0x20'u32) != 0:
      assert_rec("hal_machw_gen_handler", "hal_machw.c", 641)

  # Step 6: Remaining status bits -- unexpected interrupts (assert_rec tail calls)
  # Each is checked in priority order; first match asserts and returns.
  if (status and 0x80'u32) != 0:        # bit 7
    assert_rec("hal_machw_gen_handler", "hal_machw.c", 695); return
  elif (status and 0x100'u32) != 0:     # bit 8
    assert_rec("hal_machw_gen_handler", "hal_machw.c", 696); return
  elif (status and 0x1000'u32) != 0:    # bit 12
    assert_rec("hal_machw_gen_handler", "hal_machw.c", 697); return
  elif (status and 0x2000'u32) != 0:    # bit 13
    assert_rec("hal_machw_gen_handler", "hal_machw.c", 698); return
  elif (status and 0x4000'u32) != 0:    # bit 14
    assert_rec("hal_machw_gen_handler", "hal_machw.c", 699); return
  elif (status and 0x8000'u32) != 0:    # bit 15
    assert_rec("hal_machw_gen_handler", "hal_machw.c", 700); return
  elif (status and 0x10000'u32) != 0:   # bit 16
    assert_rec("hal_machw_gen_handler", "hal_machw.c", 701); return
  elif (status and 0x20000'u32) != 0:   # bit 17
    assert_rec("hal_machw_gen_handler", "hal_machw.c", 702); return
  elif (status and 0x200000'u32) != 0:  # bit 21
    assert_rec("hal_machw_gen_handler", "hal_machw.c", 703); return
  elif (status and 0x400000'u32) != 0:  # bit 22
    assert_rec("hal_machw_gen_handler", "hal_machw.c", 704); return
  elif (status and 0x1000000'u32) != 0: # bit 24
    assert_rec("hal_machw_gen_handler", "hal_machw.c", 705); return
  elif (status and 0x2000000'u32) != 0: # bit 25
    assert_rec("hal_machw_gen_handler", "hal_machw.c", 706); return
  elif (status and 0x100000'u32) != 0:  # bit 20
    assert_rec("hal_machw_gen_handler", "hal_machw.c", 707); return

proc hal_machw_timing_info*() {.exportc, cdecl.} =
  ## Read and report MAC HW timing register fields.
  ##
  ## Reverse-engineered from blob (210 instructions in hal_machw.o).
  ## The original calls a debug-print module (function pointers at s0[4]/s0[8])
  ## to dump each extracted field. We replicate the exact register reads and
  ## bitfield extractions; the print calls are no-ops since the debug print
  ## infrastructure is not reproduced.
  ##
  ## Registers read (all offsets from MACHW_BASE = 0x44B00000):
  ##   0x0E4  Timing Set 1: txStartDelayOFDM[27:18], slotTime[17:8], macCoreClkFreq[7:0]
  ##   0x0E8  Timing Set 2: txChainDelay[23:8], txDEDelay[7:0]
  ##   0x0EC  Timing Set 3: rxRFDelay[29:20], txDelayRFOnOff[19:10], macProcDelay[9:0]
  ##   0x0F0  Timing Set 4: radioWakeUpTime[31:22], radioChirpTime[21:12], clkDivider[1:0]
  ##   0x0F4  Timing Set 5: ofdmRxStartDelay[23:8], ofdmRxChainDelay[7:0]
  ##   0x0F8  Timing Set 6: dsssRxStartDelay[23:8], dsssRxChainDelay[7:0]
  ##   0x0FC  Timing Set 7: edcaTriggerTimer[11:8], slotCounterAddr[7:0]
  ##   0x100  Timing Set 8: sifsBDelay[31:24], sifsADelay[23:16], eifsDuration[15:8], slotTime2[7:0]
  ##   0x104  Timing Set 9: txDMAProcDelay[29:20], rifsToDelay[19:10], rifsTOInMACClk[9:0]

  const
    REG_0E4 = MACHW_BASE + 0x0E4'u
    REG_0E8 = MACHW_BASE + 0x0E8'u
    REG_0EC = MACHW_BASE + 0x0EC'u
    REG_0F0 = MACHW_BASE + 0x0F0'u
    REG_0F4 = MACHW_BASE + 0x0F4'u
    REG_0F8 = MACHW_BASE + 0x0F8'u
    REG_0FC = MACHW_BASE + 0x0FC'u
    REG_100 = MACHW_BASE + 0x100'u
    REG_104 = MACHW_BASE + 0x104'u

  let printHdrFn = blOpsFunc(8)   # s0[8] = section header print
  let printFldFn = blOpsFunc(4)   # s0[4] = field value print
  type PrintFn = proc(fmt: cstring, a1: uint32, a2: uint32) {.cdecl, varargs.}
  let pHdr = cast[PrintFn](printHdrFn)
  let pFld = cast[PrintFn](printFldFn)

  # --- REG 0xE4: Timing Set 1 ---
  block:
    let timingSet1 = regRead(REG_0E4)
    let txStartDelayOFDM = (timingSet1 shr 18) and 0x3FF'u32   # bits[27:18]
    let slotTime         = (timingSet1 shr 8)  and 0xFFFF'u32   # bits[17:8] (blob uses & 0xFFFF)
    let macCoreClkFreq   = timingSet1 and 0xFF'u32              # bits[7:0]
    if printHdrFn != nil:
      pHdr("hal_machw.c", 0, 0)
    if printFldFn != nil:
      pFld("txStartDelayOFDM", txStartDelayOFDM, txStartDelayOFDM)
      pFld("slotTime", slotTime and 0xFFFF, slotTime and 0xFFFF)
      pFld("macCoreClkFreq", macCoreClkFreq, macCoreClkFreq)

  # --- REG 0xE8: Timing Set 2 ---
  block:
    let timingSet2 = regRead(REG_0E8)
    let txChainDelay = (timingSet2 shr 8) and 0xFFFF'u32       # bits[23:8]
    let txDEDelay    = timingSet2 and 0xFF'u32                  # bits[7:0]
    if printFldFn != nil:
      pFld("txChainDelay", txChainDelay, txChainDelay)
      pFld("txDEDelay", txDEDelay, txDEDelay)

  # --- REG 0xEC: Timing Set 3 ---
  block:
    let timingSet3 = regRead(REG_0EC)
    let rxRFDelay       = (timingSet3 shr 20) and 0x3FF'u32    # bits[29:20]
    let txDelayRFOnOff  = (timingSet3 shr 10) and 0x3FF'u32    # bits[19:10]
    let macProcDelay    = timingSet3 and 0x3FF'u32              # bits[9:0]
    if printFldFn != nil:
      pFld("rxRFDelay", rxRFDelay, rxRFDelay)
      pFld("txDelayRFOnOff", txDelayRFOnOff, txDelayRFOnOff)
      pFld("macProcDelay", macProcDelay, macProcDelay)

  # --- REG 0xF0: Timing Set 4 ---
  block:
    let timingSet4 = regRead(REG_0F0)
    let radioWakeUpTime = timingSet4 shr 22                     # bits[31:22]
    let radioChirpTime  = (timingSet4 shr 12) and 0x3FF'u32    # bits[21:12]
    let clkDivider      = timingSet4 and 0x3'u32                # bits[1:0]
    if printFldFn != nil:
      pFld("radioWakeUpTime", radioWakeUpTime, radioWakeUpTime)
      pFld("radioChirpTime", radioChirpTime, radioChirpTime)
      pFld("clkDivider", clkDivider, clkDivider)

  # --- REG 0xF4: Timing Set 5 ---
  block:
    let timingSet5 = regRead(REG_0F4)
    let ofdmRxStartDelay = (timingSet5 shr 8) and 0xFFFF'u32   # bits[23:8]
    let ofdmRxChainDelay = timingSet5 and 0xFF'u32              # bits[7:0]
    if printFldFn != nil:
      pFld("ofdmRxStartDelay", ofdmRxStartDelay, ofdmRxStartDelay)
      pFld("ofdmRxChainDelay", ofdmRxChainDelay, ofdmRxChainDelay)

  # --- REG 0xF8: Timing Set 6 ---
  block:
    let timingSet6 = regRead(REG_0F8)
    let dsssRxStartDelay = (timingSet6 shr 8) and 0xFFFF'u32   # bits[23:8]
    let dsssRxChainDelay = timingSet6 and 0xFF'u32              # bits[7:0]
    if printFldFn != nil:
      pFld("dsssRxStartDelay", dsssRxStartDelay, dsssRxStartDelay)
      pFld("dsssRxChainDelay", dsssRxChainDelay, dsssRxChainDelay)

  # --- REG 0xFC: Timing Set 7 ---
  block:
    let timingSet7 = regRead(REG_0FC)
    let edcaTriggerTimer = (timingSet7 shr 8) and 0xF'u32      # bits[11:8]
    let slotCounterAddr  = timingSet7 and 0xFF'u32              # bits[7:0]
    if printFldFn != nil:
      pFld("edcaTriggerTimer", edcaTriggerTimer, edcaTriggerTimer)
      pFld("slotCounterAddr", slotCounterAddr, slotCounterAddr)

  # --- REG 0x100: Timing Set 8 ---
  block:
    let timingSet8 = regRead(REG_100)
    let sifsBDelay   = (timingSet8 shr 24) and 0xFF'u32        # bits[31:24]
    let sifsADelay   = (timingSet8 shr 16) and 0xFF'u32        # bits[23:16]
    let eifsDuration = (timingSet8 shr 8)  and 0xFF'u32        # bits[15:8]
    let slotTime2    = timingSet8 and 0xFF'u32                  # bits[7:0]
    if printFldFn != nil:
      pFld("sifsBDelay", sifsBDelay, sifsBDelay)
      pFld("sifsADelay", sifsADelay, sifsADelay)
      pFld("eifsDuration", eifsDuration, eifsDuration)
      pFld("slotTime2", slotTime2, slotTime2)

  # --- REG 0x104: Timing Set 9 ---
  block:
    let timingSet9 = regRead(REG_104)
    let txDMAProcDelay = (timingSet9 shr 20) and 0x3FF'u32     # bits[29:20]
    let rifsToDelay    = (timingSet9 shr 10) and 0x3FF'u32     # bits[19:10]
    let rifsTOInMACClk = timingSet9 and 0x3FF'u32              # bits[9:0]
    if printFldFn != nil:
      pFld("txDMAProcDelay", txDMAProcDelay, txDMAProcDelay)
      pFld("rifsToDelay", rifsToDelay, rifsToDelay)
      pFld("rifsTOInMACClk", rifsTOInMACClk, rifsTOInMACClk)

proc blmac_abs_timer_set*(timerIndex: uint32, timerValue: uint32) {.exportc, cdecl, noinline.} =
  ## Set an absolute timer by index (0..9).
  ## From blob (hal_machw.o, 19 instrs): asserts timerIndex <= 9, then
  ## computes address = (0x092C004A + timerIndex) << 2 and stores timerValue
  ## there. The address formula maps to MACHW_INTC_BASE + 0x128 + timerIndex*4.
  if timerIndex > 9:
    assert_err("hal_machw.c", "hal_machw.c", 0x26A0)
  let timerAddr = MACHW_INTC_BASE + 0x128'u + timerIndex * 4
  regWrite(timerAddr, timerValue)

proc blmac_pwr_mgt_setf*(value: uint32) {.exportc, cdecl, noinline.} =
  ## Set power management field in MAC HW state register.
  ## From blob (chan.o, 17 instrs): shifts value left by 2 (into bits [3:2]),
  ## asserts only bit 2 is valid (andi -5 must be 0), then reads
  ## MACHW_BASE+0x4C, clears bit 2 (andi -5), ORs new value, writes back.
  ## noinline: blob keeps this as a distinct MACHW setter.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let shifted = value shl 2
  if (shifted and not 0x04'u32) != 0:
    assert_err("hal_machw.c", "hal_machw.c", 0x952)
  var reg = regRead(MACHW_BASE + 0x04C'u)
  reg = reg and not 0x04'u32
  reg = reg or shifted
  regWrite(MACHW_BASE + 0x04C'u, reg)

proc blmac_soft_reset_getf*(): uint8 {.exportc, cdecl, noinline.} =
  ## Read soft reset status field from MACHW_INTC.
  ## From blob (hal_machw.o, 14 instrs): reads MACHW_INTC_BASE+0x050,
  ## asserts only bit 0 is used (andi ~1 must be 0), returns low byte.
  let softResetStatus = regRead(MACHW_INTC_BASE + 0x050'u)
  if (softResetStatus and not 0x01'u32) != 0:
    assert_err("hal_machw.c", "hal_machw.c", 285)
  return (softResetStatus and 0xFF'u32).uint8

proc hal_machw_rx_duration*(rxvec: pointer, band: uint32): uint32 {.exportc, cdecl.} =
  ## Calculate RX frame duration from RX vector descriptor.
  ## From blob (hal_machw.o, 45 instrs): reads rxvec fields, programs
  ## MACHW_INTC registers to compute duration via HW, polls completion.
  ## rxvec+40 = format byte, rxvec+44 = length/info.
  ## Returns duration in MAC ticks, or 500 on error.
  let rxv = phyRxVectorAt(rxvec)
  let fmtByte = rxv.durationFormat
  let fmt = fmtByte and 0x7F'u8  # bits [6:0]
  if (fmtByte and 0x80'u8) != 0:
    assert_err("hal_machw.c", "hal_machw.c", 0x1A99)
  # Write format to MACHW_INTC offset 0x164
  regWrite(MACHW_INTC_BASE + 0x164'u, fmt.uint32)
  # Build length word: rxvec[44] shifted left 24 | band
  let lenByte = rxv.durationLength
  let lenWord = (lenByte.uint32 shl 24) or band
  regWrite(MACHW_INTC_BASE + 0x160'u, lenWord)
  # Trigger computation: write 0x80000000 to MACHW_INTC offset 0x168
  regWrite(MACHW_INTC_BASE + 0x168'u, 0x80000000'u32)
  # Poll until bit 18 (0x40000) is set in offset 0x168
  if not waitRegMaskSet(MACHW_INTC_BASE + 0x168'u, 0x40000'u32):
    return 500
  # Check result: if lower 26 bits of offset 0x168 are 0, return 500
  let result_reg = regRead(MACHW_INTC_BASE + 0x168'u)
  let durBits = result_reg and 0x03FFFFFF'u32
  if durBits == 0:
    # Blob uses assert_rec, not assert_warn.
    assert_rec("hal_machw.c", "hal_machw.c", 249)
    return 500
  # Read computed duration from offset 0x168 bits [25:0]
  return durBits and 0xFFFF'u32

proc element_notify_status_enabled*(): uint32 {.exportc, cdecl.} =
  ## Check if element notification is enabled.
  ## From blob (2 instrs): always returns 0 (disabled).
  return 0

proc element_notify*(ctx: pointer, op: uint32, param1: pointer, param2: pointer) {.exportc, cdecl.} =
  ## Send element notification via platform log function.
  ## From blob (notifier.o, 13 instrs): loads log function from g_bl_ops_funcs+0xCC,
  ## reads ctx+8 for state, calls logFn(1, 0, fmtStr, 1826, fileStr, ctxState, param2).
  let logFn = getLogFunc(0xCC)
  if logFn != nil:
    let ctxState = elementNotifyContextAt(ctx).state
    cast[proc(a0: uint32, a1: uint32, a2: cstring, a3: uint32, a4: cstring, a5: pointer, a6: pointer) {.cdecl.}](logFn)(
      1, 0, "element_notify", 1826, "notifier.c", ctxState, param2)

proc is_cck_group*(rateConfig: uint32): bool {.exportc, cdecl, noinline.} =
  ## Check if a rate configuration belongs to a CCK (DSSS) rate group.
  ## From blob (rc.o, 9 instrs): extracts format_mod from bits[12:11],
  ## if non-zero returns false (HT/VHT), else calls rc_get_mcs_index and checks < 4.
  ## noinline: blob keeps this as a separate helper called by rc_calc_tp.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let fmtMod = (rateConfig shr 11) and 0x06'u32
  if fmtMod != 0:
    return false
  # For legacy rates, call rc_get_mcs_index to get MCS index, CCK if < 4
  let mcsIdx = rc_get_mcs_index(rateConfig.uint16)
  return mcsIdx < 4

proc xor_bytes*(dst: pointer, src: pointer, count: uint32) {.exportc: "xor", cdecl.} =
  ## XOR 'count' bytes from src into dst (in-place).
  ## From blob (mfp_bip.o, 9 instrs): loop XORing byte by byte.
  for xorByteOffset in 0'u32 ..< count:
    let sourceByte = cast[ptr uint8](cast[uint](src) + xorByteOffset)[]
    let destinationByte = cast[ptr uint8](cast[uint](dst) + xorByteOffset)[]
    cast[ptr uint8](cast[uint](dst) + xorByteOffset)[] = destinationByte xor sourceByte

proc add_round_key*(roundKeys: pointer, state: pointer, round: uint32) {.exportc, cdecl, noinline.} =
  ## XOR a 16-byte AES round key into state.
  ## From blob (mfp_bip.o, 12 instrs): roundKeys[round*16..+16] XOR state[0..16].
  ## noinline + asm barrier: blob calls this as a separate function from
  ## aes_encrypt_block (11 sites); without noinline GCC inlines/merges calls.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
  let keyBase = cast[uint](roundKeys) + round * 16
  for roundKeyWordIndex in 0'u32 ..< 4:
    let kw = cast[ptr uint32](keyBase + roundKeyWordIndex * 4)[]
    let sw = cast[ptr uint32](cast[uint](state) + roundKeyWordIndex * 4)[]
    cast[ptr uint32](cast[uint](state) + roundKeyWordIndex * 4)[] = sw xor kw

proc aes_cmac_shift_sub_key*(key: pointer) {.exportc, cdecl.} =
  ## Shift AES-CMAC subkey: byte-level left shift of 128-bit key by 1 bit.
  ## From blob (mfp_bip.o, 39 instrs): per-byte left shift within each word,
  ## carrying bit 7 of each byte to bit 0 of the preceding byte (big-endian order).
  ## Inter-word carry: bit 7 of word[k+1] byte[0] -> word[k] byte[3] bit 0.
  ## If original MSB (word[0] byte[0] bit 7) was set, XOR word[3] with 0x87000000.
  let subkeyWords = cast[ptr UncheckedArray[uint32]](key)
  let subkeyWord0 = subkeyWords[0]
  let subkeyWord1 = subkeyWords[1]
  let subkeyWord2 = subkeyWords[2]
  let subkeyWord3 = subkeyWords[3]
  let msb = (subkeyWord0 and 0x80'u32) != 0  # byte[0] bit 7 = big-endian MSB
  # Byte-level left shift: each byte shifts left by 1, carry across bytes
  # Intra-word carry: bit 7 of byte[i] -> bit 0 of byte[i-1] (higher word position)
  # Masks: 0xFEFEFEFE clears carry-in positions, 0x00010101 extracts carries,
  #         0x01000000 inter-word carry into byte[3] bit 0
  const shiftMask = 0xFEFEFEFE'u32
  const carryMask = 0x00010101'u32
  const interMask = 0x01000000'u32
  subkeyWords[0] = ((subkeyWord0 shl 1) and shiftMask) or
    ((subkeyWord0 shr 15) and carryMask) or
    ((subkeyWord1 shl 17) and interMask)
  subkeyWords[1] = ((subkeyWord1 shl 1) and shiftMask) or
    ((subkeyWord1 shr 15) and carryMask) or
    ((subkeyWord2 shl 17) and interMask)
  subkeyWords[2] = ((subkeyWord2 shl 1) and shiftMask) or
    ((subkeyWord2 shr 15) and carryMask) or
    ((subkeyWord3 shl 17) and interMask)
  subkeyWords[3] = ((subkeyWord3 shl 1) and shiftMask) or
    ((subkeyWord3 shr 15) and carryMask)
  if msb:
    subkeyWords[3] = subkeyWords[3] xor 0x87000000'u32  # AES-128 CMAC polynomial (Rb)

proc mfp_is_robust_frame*(frameCtrl: uint32, subtype: uint32): bool {.exportc, cdecl, noinline.} =
  ## Check if a management frame requires protection (MFP).
  ## From blob (mfp.o, 20 instrs): checks frame control type bits [3:2],
  ## if not 0 (not management) returns false. Then checks subtype for
  ## deauth (0xC0) and disassoc (0xD0) which are always robust.
  ## For action frames (0xD0): checks category field.
  ## noinline: blob keeps this as a standalone helper (small but many sites).
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  if (frameCtrl and 0x0C'u32) != 0:
    return false  # Not a management frame
  let subtypeBits = frameCtrl and 0xF0'u32
  if subtypeBits == 0xC0'u32:  # Deauth
    return true
  if subtypeBits == 0xD0'u32:  # Action
    let adj = subtypeBits - 0xA0'u32
    if adj == 0:
      return false
    # Check action category: categories 0-3 and specific higher ones
    if subtype <= 3:
      return true
    if subtype <= 15:
      let mask = 0x00008890'u32  # Categories 4,7,11,15 are robust
      return ((1'u32 shl subtype) and mask) != 0
    # Categories >= 128 are vendor-specific, not robust
    return subtype < 128
  return false

proc mm_timer_hw_set*(timer: pointer) {.exportc, cdecl, noinline.} =
  ## Program or clear the MAC HW absolute timer.
  ## From blob (mm_timer.o, 22 instrs): if timer is nil, clears timer IRQ bit
  ## in INTC unmask register. If non-nil, writes timer->time (offset 12)
  ## to MACHW_ABS_TIMER_REG, then enables timer IRQ bit (0x80) in INTC.
  let saved = irqSave()
  if timer != nil:
    let expiry = mmTimerAt(timer).expiry
    nimFwTrace2U32("[WIFI-NIMFW] mm_timer_hw_set ", cast[uint32](cast[uint](timer)), expiry)
    regWrite(MACHW_ABS_TIMER_REG, expiry)
    # Enable absolute timer IRQ: set bit 7 (0x80) in INTC unmask
    let intcUnmask = MACHW_INTC_BASE + 0x08C'u  # Unmask set/status register
    let unmaskStatus = regRead(intcUnmask)
    if (unmaskStatus and 0x80'u32) == 0:
      # Write 0x80 to unmask set register
      regWrite(MACHW_INTC_BASE + 0x088'u, 0x80'u32)
    regWrite(intcUnmask, unmaskStatus or 0x80'u32)
    nimFwTrace2U32("[WIFI-NIMFW] mm_timer_hw regs ", regRead(MACHW_ABS_TIMER_REG), regRead(MACHW_INTC_BASE + 0x08C'u))
  else:
    # Clear timer IRQ: clear bit 7 (0x80) from INTC unmask
    let intcUnmask = MACHW_INTC_BASE + 0x08C'u
    let unmaskStatus = regRead(intcUnmask)
    regWrite(intcUnmask, unmaskStatus and not 0x80'u32)
  if (saved and 8) != 0:
    irqRestore(saved)

# ###########################################################################
#                      MM: MAC Management
# ###########################################################################

proc mm_rx_filter_set*() {.exportc, cdecl.} =
  ## Apply RX filter: OR mm_env[0] with mm_env[1], write to MACHW_RX_CNTRL_REG.
  ## From disassembly: loads two words from mm_env, ORs them, writes to 0x24B00060.
  let mm = mmEnvView()
  let filter = mm.rxFilterBase or mm.rxFilterExtra
  regWrite(MACHW_RX_CNTRL_REG, filter)

proc mm_env_init*() {.exportc, cdecl.} =
  ## Initialize MM environment struct (68 bytes) and individual state variables.
  ## From disassembly: memset(mm_env, 0, 68), then sets specific fields:
  ##   mm_env[0] = 0x7FFFFFDE (default RX filter, via lui 0x80000 + xori -34)
  ##   halfword at byte offset 26 = 0x0101
  ##   mm_env[7] = 0x4E20 (20000 = keep-alive interval in MAC ticks)
  ##   mm_env[8] = 10 (keep-alive count limit)
  ##   mm_env[13] = 0xFA0 (4000 = max AMPDU duration)
  ## Then tail-calls mm_rx_filter_set().
  let mm = mmEnvView()
  discard c_memset(mm, 0, sizeof(MmEnvView).csize_t)
  mm.rxFilterBase = 0x7FFFFFDE'u32
  mm.idleFlag = 1
  mm.flagsHigh = 1
  mm.keepAliveInterval = 0x4E20'u32
  mm.keepAliveLimit = 10'u32
  mm.maxAmpduDuration = 0xFA0'u32
  # Clear byte offsets 18 and 4 (blob: sh zero, 18(a5); sw zero, 4(a5))
  mm.previousState = 0
  mm.hardwareMode = 0
  mm.rxFilterExtra = 0
  mm_rx_filter_set()
  # Blob: tail-call mm_env_max_ampdu_duration_set
  mm_env_max_ampdu_duration_set(0)

proc mm_init*() {.exportc, cdecl.} =
  ## Initialize the MAC Management module.
  ## From disassembly: calls 11 sub-init functions, then tail-calls
  ## ke_state_set(TASK_MM, MM_IDLE). Master init for the entire lower MAC.
  ## The 11 calls initialize all lower-MAC subsystems: environment, VIF/STA
  ## management, beacons, timers, TX (frame/cntrl/cfm/buffer), RX, and MAC HW.
  # Blob call order: hal_machw_init, mm_env_init, vif_mgmt_init, sta_mgmt_init,
  # td_init, ps_init, txl_cntrl_init, rxl_init, mm_timer_init, scan_init,
  # chan_init, mm_bcn_init (tail-call which does ke_state_set internally)
  nimFwTrace("[WIFI-NIMFW] hal_machw_init begin")
  hal_machw_init()
  nimFwTrace("[WIFI-NIMFW] hal_machw_init done")
  nimFwTrace("[WIFI-NIMFW] mm_env_init begin")
  mm_env_init()
  nimFwTrace("[WIFI-NIMFW] mm_env_init done")
  nimFwTrace("[WIFI-NIMFW] vif_mgmt_init begin")
  vif_mgmt_init()
  nimFwTrace("[WIFI-NIMFW] vif_mgmt_init done")
  nimFwTrace("[WIFI-NIMFW] sta_mgmt_init begin")
  sta_mgmt_init()
  nimFwTrace("[WIFI-NIMFW] sta_mgmt_init done")
  nimFwTrace("[WIFI-NIMFW] td_init begin")
  td_init()
  nimFwTrace("[WIFI-NIMFW] td_init done")
  nimFwTrace("[WIFI-NIMFW] ps_init begin")
  ps_init()
  nimFwTrace("[WIFI-NIMFW] ps_init done")
  nimFwTrace("[WIFI-NIMFW] txl_cntrl_init begin")
  txl_cntrl_init()
  nimFwTrace("[WIFI-NIMFW] txl_cntrl_init done")
  nimFwTrace("[WIFI-NIMFW] rxl_init begin")
  rxl_init()
  nimFwTrace("[WIFI-NIMFW] rxl_init done")
  nimFwTrace("[WIFI-NIMFW] mm_timer_init begin")
  mm_timer_init()
  nimFwTrace("[WIFI-NIMFW] mm_timer_init done")
  nimFwTrace("[WIFI-NIMFW] scan_init begin")
  scan_init()
  nimFwTrace("[WIFI-NIMFW] scan_init done")
  nimFwTrace("[WIFI-NIMFW] chan_init begin")
  chan_init()
  nimFwTrace("[WIFI-NIMFW] chan_init done")
  nimFwTrace("[WIFI-NIMFW] mm_bcn_init begin")
  mm_bcn_init()  # blob tail-call; mm_bcn_init sets ke_state to MM_IDLE
  nimFwTrace("[WIFI-NIMFW] mm_bcn_init done")

proc mm_active*() {.exportc, cdecl.} =
  ## Transition MM and MAC HW to active state.
  ## From disassembly: writes 0x30 to MACHW_STATE_CNTRL_REG (0x24B00038),
  ## then tail-calls ke_state_set(TASK_MM, MM_ACTIVE_STATE).
  regWrite(MACHW_STATE_CNTRL_REG, 0x30'u32)
  ke_state_set(TASK_MM, MM_ACTIVE_STATE.uint16)

proc mm_reset*() {.exportc, cdecl.} =
  ## Reset MM to initial state.
  ## From blob: calls ke_state_get(TASK_MM). If MM_ACTIVE_STATE,
  ## tail-calls mm_active() (NOT mm_env_init). Otherwise tail-calls ke_state_set(TASK_MM, MM_IDLE).
  let curState = ke_state_get(TASK_MM)
  if curState == MM_ACTIVE_STATE.uint16:
    mm_active()  # Blob: R_RISCV_CALL mm_active — reactivates MAC HW, NOT reinit
  else:
    ke_state_set(TASK_MM, MM_IDLE.uint16)

proc mm_env_max_ampdu_duration_set*(duration: uint32) {.exportc, cdecl.} =
  ## Set maximum A-MPDU duration (73 instrs).
  ## From blob: reads EDCA AC registers (BK/BE/VI/VO at 0x24B00200..20C), for each
  ## AC computes duration = reg_val / 150 (using BL808 custom div insn), clamps to
  ## min(150, result), stores as halfwords in mm_env at offsets 8,10,12,14,16.
  ## The last AC value is duplicated to both offset 14 and 16.
  let mm = mmEnvView()
  # For each AC: read EDCA register, extract TXOP field, compute duration.
  # Blob uses BL808 custom div instruction (6cc6b68b etc.) on single read.
  # Logic: if regVal == 0 → 150; else min(150, regVal / 150).
  # Template (not nested proc) so the math inlines at every call site and
  # matches blob's call graph (which has zero calls to a helper here).
  template computeDuration(regAddr: uint): uint16 =
    block:
      let regVal {.gensym.} = volatileLoad(cast[ptr uint32](regAddr))
      var dOut {.gensym.}: uint16 = 150'u16
      if regVal != 0:
        let d {.gensym.} = regVal div 150
        if d <= 150:
          dOut = d.uint16
      dOut
  # AC_BK/BE/VI/VO durations cached in mm_env halfwords at offsets 8..16.
  mm.edcaBkDur = computeDuration(MACHW_EDCA_AC_BK_REG)
  mm.edcaBeDur = computeDuration(MACHW_EDCA_AC_BE_REG)
  mm.edcaViDur = computeDuration(MACHW_EDCA_AC_VI_REG)
  let dVO = computeDuration(MACHW_EDCA_AC_VO_REG)
  mm.edcaVoDur = dVO
  mm.edcaBcnDur = dVO

proc mm_cfg_element_keepalive_timestamp_update*() {.exportc, cdecl.} =
  ## Update keep-alive timestamp to current time (14 instrs).
  ## From blob: calls g_bl_ops_funcs[0xC8] (platform get_time), stores result
  ## in mm_env word at offset 40 (mm_env[10]), increments mm_env word at offset 36
  ## (mm_env[9] = keep-alive counter).
  let mm = mmEnvView()
  let getTimeFn = blOpsFunc(0xC8)
  let now = cast[proc(): uint32 {.cdecl.}](getTimeFn)()
  # Store timestamp at mm_env offset 40 (word 10)
  mm.keepAliveTimestamp = now
  # Increment counter at mm_env offset 36 (word 9)
  mm.keepAliveCounter = mm.keepAliveCounter + 1

proc mm_send_connection_loss_ind*(vifIdx: uint8, reason: uint16) {.exportc, cdecl, noinline.} =
  ## Send connection loss indication to host.
  ## noinline: blob keeps this as a standalone helper (called from multiple sites).
  inc nimFwDbgConnLossInd
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let ind = cast[ptr MmConnectionLossIndPayload](
    ke_msg_alloc(MM_CONNECTION_LOSS_IND, TASK_API, TASK_MM,
                 MmConnectionLossIndPayloadSize))
  if ind != nil:
    ind.reason = reason
    ind.vifIdx = vifIdx
    ke_msg_send(ind)

proc mm_send_csa_traffic_ind*() {.exportc, cdecl.} =
  ## Send CSA traffic indication.
  discard

proc mm_ps_change_ind*(staIdx: uint8, psState: uint8) {.exportc, cdecl.} =
  ## Send MM_PS_CHANGE_IND to host and mirror the state in sta_info_tab.
  staInfoForIdx(staIdx).psMode = psState
  let ind = cast[ptr MmPsChangeIndPayload](
    ke_msg_alloc(MM_PS_CHANGE_IND, TASK_API, TASK_MM,
                 MmPsChangeIndPayloadSize))
  if ind != nil:
    ind.staIdx = staIdx
    ind.psState = psState
    ke_msg_send(ind)

proc mm_set_wpa_rsn_ie*(vifIdx: uint8, ie: pointer, ieLen: uint8) {.exportc, cdecl.} =
  ## Set WPA/RSN IE for the AssocReq's pre-built security IE block.
  ## Blob ABI: a0=vifIdx, a1=ie_ptr, a2=ie_len.
  ## Stores ie pointer at vif+492, length byte at vif+496.
  ##
  ## Prior Nim bug: signature had only (ie, len) — a2 wasn't captured, vif+496
  ## was always written as 0. Caller `bl_wifi_set_appie_internal` (ieType==0)
  ## passed (ie, ieLen) — wrong slots, so vif+492 received the length value as
  ## "ie ptr" and vifIdx came from casting the IE pointer. Result: AssocReq
  ## never carried the RSN IE → Frog accepted us as open assoc → no WPA handshake
  ## → mm_sta_tbtt fired forever → null-frame flood.
  inc nimFwDbgWpaRsnIeSet
  nimFwDbgWpaRsnIeLen = ieLen.uint32
  nimFwDbgWpaRsnIePtr = cast[uint32](ie)
  let vif = vifChannelForIdx(vifIdx)
  let sec = vifSecurity(vif)
  sec.rsnIePtr = cast[uint32](ie)
  sec.rsnIeLen = ieLen

proc mm_force_idle_req*() {.exportc, cdecl.} =
  ## Force MAC HW to idle state (23 instrs).
  ## From blob: saves/disables interrupts, calls hal_machw_reset, rxl_reset,
  ## txl_reset, then ke_state_set(TASK_MM, HW_ACTIVE=3). Clears mm_env halfword
  ## at offset 0x12 to zero. Restores interrupts.
  let saved = irqSave()
  hal_machw_reset()
  rxl_reset()
  txl_reset()
  ke_state_set(TASK_MM, HW_ACTIVE.uint16)
  let mm = mmEnvView()
  mm.previousState = 0
  mm.hardwareMode = 0
  irqRestore(saved)

proc mm_back_to_host_idle*() {.exportc, cdecl.} =
  ## Transition back to host-controlled idle state (27 instrs).
  ## From blob: calls ke_state_get(TASK_MM), asserts result == HW_ACTIVE (3).
  ## If mm_env byte at offset 0x1a is nonzero, calls ke_state_set(TASK_MM, MM_IDLE=0).
  ## Otherwise tail-calls mm_active().
  let state = ke_state_get(TASK_MM)
  if state != HW_ACTIVE.uint16:
    assert_err("mm.c", "mm.c", 1470)
  if mmEnvView().idleFlag != 0:
    # Host bypassed mode: just go to idle state
    ke_state_set(TASK_MM, MM_IDLE.uint16)
  else:
    # Normal path: go to active
    mm_active()

proc mm_hw_idle_evt*() {.exportc, cdecl.} =
  ## Handle HW idle event (11 instrs). Blob:
  ##   ke_evt_clear(0x04000000)
  ##   ke_state_set(TASK_MM=0, 0)    # tail call
  ke_evt_clear(KE_EVT_IDLE)
  ke_state_set(TASK_MM, MM_IDLE.uint16)

proc mm_hw_info_set*(macAddr: pointer) {.exportc, cdecl.} =
  ## Set HW info for a VIF (42 instrs).
  ## From blob: a0 = pointer to MAC address (6 bytes).
  ## Clears bit 1 in MACHW_STATUS_REG, sets bit 0, writes 256 to MACHW+0x1C,
  ## clears MACHW+0x24B080A4 and 0x24B080A8 (MAC HW addr registers).
  ## Writes MAC address bytes into MACHW+0x10 (4 bytes LE) and MACHW+0x14 (2 bytes LE).
  ## Clears bits [10:8] (0x700) in MACHW_STATUS_REG, then applies the STA RX filter.
  let machwBase = MACHW_BASE
  # Clear bit 1, set bit 0 in status register (offset 0x4C)
  var status = regRead(machwBase + 0x4C'u)
  status = status and (not 0x02'u32)
  regWrite(machwBase + 0x4C'u, status)
  status = regRead(machwBase + 0x4C'u)
  status = status or 0x01'u32
  regWrite(machwBase + 0x4C'u, status)
  # Write 256 to MACHW+0x1C (RX buffer size or similar)
  regWrite(machwBase + 0x1C'u, 0x100'u32)
  # Clear MAC HW address registers
  regWrite(0x24B080A4'u, 0)
  regWrite(0x24B080A8'u, 0)
  # Write MAC addr to HW regs.
  let addrView = macAddrAt(macAddr)
  regWrite(machwBase + 0x10'u, addrView.lowLe)
  regWrite(machwBase + 0x14'u, addrView.highLe)
  # Clear bits [10:8] (0x700) in status register
  status = regRead(machwBase + 0x4C'u)
  status = status and (not 0x700'u32)
  regWrite(machwBase + 0x4C'u, status)
  # Apply STA RX filter. Blob chooses the promiscuous STA variant when
  # mm_env+44 is nonzero.
  let mm = mmEnvView()
  if mm.rxPromiscUploadFlag != 0:
    mm.rxFilterBase = 0x3503A58C'u32
  else:
    mm.rxFilterBase = 0x3503858C'u32
  mm_rx_filter_set()

proc mm_hw_ap_info_set*(vifIdx: uint8) {.exportc, cdecl.} =
  ## Set HW AP info for a VIF (26 instrs).
  ## From blob: sets bit 1 in MACHW_STATUS_REG, sets mm_env[0] to AP RX filter
  ## (value depends on mm_env[12] being nonzero), calls mm_rx_filter_set,
  ## then enables beacon TX interrupt in MACHW_INTC.
  # Set bit 1 in MACHW_STATUS_REG (0x24B0004C)
  var status = regRead(MACHW_STATUS_REG)
  status = status or 0x02'u32
  regWrite(MACHW_STATUS_REG, status)
  # Set AP RX filter in mm_env[0]; value depends on mm_env word at offset 48.
  let mm = mmEnvView()
  if mm.apPromiscUploadFlag != 0:
    mm.rxFilterBase = 0x3507A58C'u32
  else:
    mm.rxFilterBase = 0x3507858C'u32
  mm_rx_filter_set()
  # Enable beacon TX interrupt: write 0x40001 to INTC_STATUS_ACK, then OR into INTC_UNMASK
  regWrite(MACHW_INTC_STATUS_ACK, 0x40001'u32)
  var unmask = regRead(MACHW_INTC_UNMASK_REG)
  unmask = unmask or 0x40001'u32
  regWrite(MACHW_INTC_UNMASK_REG, unmask)

proc mm_hw_ap_info_reset*(vifIdx: uint8) {.exportc, cdecl.} =
  ## Reset HW AP info for a VIF (24 instrs).
  ## From blob: clears bit 1 in MACHW_STATUS_REG, sets mm_env[0] to
  ## STA RX filter (0x3503858C), calls mm_rx_filter_set, then masks off
  ## beacon TX interrupt bits in MACHW_INTC.
  # Clear bit 1 in MACHW_STATUS_REG (0x24B0004C)
  var status = regRead(MACHW_STATUS_REG)
  status = status and (not 2'u32)  # andi a5,a5,-3
  regWrite(MACHW_STATUS_REG, status)
  # Set STA RX filter in mm_env[0]
  mmEnvView().rxFilterBase = 0x3503858C'u32
  mm_rx_filter_set()
  # Mask off beacon TX interrupt: write 0x40001 to INTC_STATUS_ACK, then AND out bits
  regWrite(MACHW_INTC_STATUS_ACK, 0x40001'u32)
  var unmask = regRead(MACHW_INTC_UNMASK_REG)
  unmask = unmask and 0xFFFBFFFE'u32  # lui 0xfffc0, addi -2 = 0xFFFBFFFE
  regWrite(MACHW_INTC_UNMASK_REG, unmask)

proc mm_sta_add*(param: pointer, staIdxOut: ptr uint8, hwStaIdxOut: ptr uint8): uint8 {.exportc, cdecl.} =
  ## Add a station to MAC HW.  Reverse-engineered from blob (223 instructions).
  ##
  ## param       -- pointer to MM_STA_ADD_REQ message payload
  ## staIdxOut   -- output: station index assigned by sta_mgmt_register
  ## hwStaIdxOut -- output: HW station index returned by mm_sec_machwaddr_wr
  ##
  ## Returns 0 on success, nonzero on error.
  ##
  ## Blob register map:
  ##   s9=param  s5=staIdxOut  s0=hwStaIdxOut (then vif_info_tab)
  ##   s3=inst_nbr  s4=vifOffset  s2=vifEntry  s6=status  s1=sm_env ptr
  ##   s8=vifType  s7=cipher
  ##
  ## Message layout (param offsets):
  ##   vifIdx = inst_nbr (offset 13)
  ##   quickConn is copied into key buffer offset 125

  # ---- Step 1: Register station via sta_mgmt_register ----
  let regStatus = sta_mgmt_register(param, staIdxOut)
  if regStatus != 0:
    return regStatus

  # ---- Step 2: Read request fields ----
  let req = mmStaAddReqView(param)
  let instNbr = req.vifIdx                                    # VIF index
  let staIdx = staIdxOut[]                                    # station index written by register

  # ---- Step 3: Write MAC address to HW ----
  # mm_sec_machwaddr_wr(staIdx, instNbr, ...)
  # Note: current stub signature is (staIdx, keySlotRaw, unusedCompatArg) but
  # blob ABI is (staIdx, instNbr).
  # Cast-call to match the 2-arg blob ABI; the stub discards args anyway.
  type MacHwAddrWrProc = proc(staIdx: uint8, instNbr: uint8): uint8 {.cdecl.}
  let machwaddrWr = cast[MacHwAddrWrProc](mm_sec_machwaddr_wr)
  let hwIdx = machwaddrWr(staIdx, instNbr)
  hwStaIdxOut[] = hwIdx

  # ---- Step 4: Compute VIF entry pointer ----
  let vif = vifChannelForIdx(instNbr)

  # Read vif type (offset 86) and connected flag (offset 488)
  let sec = vifSecurity(vif)
  if vif.vifType == VIF_TYPE_STA and sec.connected != 0:
    # STA type and connected -- check SM state for key setup
    let sm = smEnvView()
    let smState = sm.state

    if smState == 2:
      # WPS mode: call WPS callback if available
      let wpsCbsPtr = wps_cbs
      if wpsCbsPtr != nil:
        let cbFuncPtr = wpsCallbacks().staConnected
        if cbFuncPtr != nil:
          let vifHwIdx = vif.vifIdx
          let cbStaIdx = staIdxOut[]
          type WpsCbProc = proc(vifHwIdx: uint8, staIdx: uint8) {.cdecl.}
          let wpsStaConnectedCallback = cast[WpsCbProc](cbFuncPtr)
          wpsStaConnectedCallback(vifHwIdx, cbStaIdx)
    else:
      # Not WPS -- check cipher type at vif_entry[497]
      let cipher = sec.cipher

      if cipher >= 2 and cipher <= 4:
        # WPA/WPA2/WPA3 key setup (cipher 2, 3, or 4)
        var keyBuf {.noinit.}: array[128, uint8]
        discard c_memset(addr keyBuf[0], 0, 128)
        let keyReq = cast[ptr WpaKeyWriteParamView](addr keyBuf[0])

        keyReq.vifIdx = vif.vifIdx
        keyReq.staIdx = staIdxOut[]

        let keyDataLen = vif.supportedRatesLong[0]
        keyReq.keyDataLen = keyDataLen.uint32

        keyReq.quickConn = req.quickConn

        discard c_memcpy(addr keyReq.keyMaterial[0],
                         addr vif.supportedRatesLong[1],
                         keyDataLen.csize_t)

        let creds = connectInfoCredentials(sm.connectInfo)
        let ssidPresent = creds.altSsid[0]

        var ssidSrc: pointer
        var ssidLen: csize_t
        if ssidPresent != 0:
          ssidSrc = addr creds.altSsid[0]
          ssidLen = 64
        else:
          ssidSrc = addr creds.keyString[0]
          ssidLen = c_strlen(ssidSrc)

        discard c_memcpy(addr keyReq.ssid[0], ssidSrc, ssidLen)

        # Mark key slots as invalid (-1)
        sec.staKeySlots[0] = 0xFF
        sec.staKeySlots[1] = 0xFF
        sec.staKeySlots[2] = 0xFF

        # Call WPA key write callback: wpa_cbs -> ptr -> [12] = func
        let wpaCbsPtr = wpa_cbs
        if wpaCbsPtr != nil:
          let keyWriteCb = wpaCallbacks().keyWrite
          if keyWriteCb != nil:
            type KeyWriteProc = proc(buf: pointer): uint8 {.cdecl.}
            let kwCb = cast[KeyWriteProc](keyWriteCb)
            discard kwCb(addr keyBuf[0])

      elif cipher == 1:
        # WEP key setup
        # Mark vif_entry[513] = 0xFF (pending)
        sec.staKeySlots[3] = 0xFF'u8

        # Get connect info and SSID/key string
        let creds = connectInfoCredentials(sm.connectInfo)
        let keyStr = cast[pointer](addr creds.keyString[0])

        # Call log function: g_bl_ops_funcs[204](2, 0, .LC1, 1601, .LC32, keyStr, len)
        let logFuncPtr = blOpsFunc(204)
        if logFuncPtr != nil:
          let keyLen = c_strlen(keyStr)
          type LogProc = proc(level: uint32, sev: uint32, file: pointer, line: uint32,
                              fmt: pointer, str: pointer, len: csize_t) {.cdecl.}
          let logFn = cast[LogProc](logFuncPtr)
          logFn(2, 0, nil, 1601, nil, keyStr, keyLen)

        # Build WEP key buffer (56 bytes)
        var wepBuf {.noinit.}: array[56, uint8]
        discard c_memset(addr wepBuf[0], 0, 56)
        let wepReq = cast[ptr WepKeyWriteParamView](addr wepBuf[0])

        wepReq.instNbr = instNbr

        wepReq.selector = 0xFF00'u16

        let wepKeyStr = keyStr
        var keyLen = c_strlen(wepKeyStr).uint8

        wepReq.keyLen = keyLen

        # Blob tail-merges all three WEP-key branches into a single
        # mm_sec_machwkey_wr call site — build the wepBuf, then fall
        # through to one shared write.
        var writeKey = true
        if keyLen == 5 or keyLen == 13:
          # Raw WEP40 / WEP104 share the same memcpy call site.
          wepReq.cipherMode = (if keyLen == 5: 0'u8 else: 3'u8)
          discard c_memcpy(addr wepReq.keyData[0], wepKeyStr, keyLen.csize_t)
        elif keyLen == 10 or keyLen == 26:
          # Hex-encoded WEP key (10 hex = 5 bytes WEP40, 26 hex = 13 bytes WEP104)
          wepReq.cipherMode = (if keyLen == 26: 3'u8 else: 0'u8)
          var hexLen = keyLen
          if (hexLen and 1) != 0:
            hexLen = hexLen and 0xFE'u8
          if hexLen > 0:
            var hexIndex: int = 0
            let hexChars = cast[ptr UncheckedArray[uint8]](wepKeyStr)
            while hexIndex < hexLen.int:
              let hi = ascii_to_hex(hexChars[hexIndex])
              let lo = ascii_to_hex(hexChars[hexIndex + 1])
              wepReq.keyData[hexIndex div 2] = (hi shl 4) or lo
              hexIndex += 2
          wepReq.keyLen = keyLen shr 1
        else:
          # Unknown WEP key length -- log error, unregister, return error
          if logFuncPtr != nil:
            type LogProc2 = proc(level: uint32, sev: uint32, file: pointer, line: uint32,
                                 fmt: pointer) {.cdecl.}
            let logFn2 = cast[LogProc2](logFuncPtr)
            logFn2(2, 0, nil, 1627, nil)
          sta_mgmt_unregister(staIdxOut[])
          return cipher  # error: unsupported cipher/key combo

        # Shared tail: single mm_sec_machwkey_wr call site (blob pattern).
        if writeKey:
          mm_sec_machwkey_wr(addr wepBuf[0])
        # In blob this stores mm_sec_machwkey_wr return value; our stub returns void,
        # so we store 0 (implicit from register after void call).
        sec.staKeySlots[3] = 0

      else:
        # cipher is 0 (open) or > 4: no key setup needed.
        # Fall through to .L159 (final sta_idx store).
        discard

  # ---- Step 5: Final -- store sta_idx in VIF entry if STA type ----
  if vif.vifType != VIF_TYPE_STA:
    return regStatus  # not STA type, return original status (which was 0)

  # Store sta_idx at vif_entry offset 96
  vif.staIdx = staIdxOut[]
  return 0  # success

proc mm_sta_del*(staIdx: uint8) {.exportc, cdecl.} =
  ## Delete a station from MAC HW (109 instrs).
  ## From blob: loads sta_info_tab[staIdx], checks VIF type. For STA-mode VIF,
  ## stores 0xFF to sta[96], deletes up to 3 HW keys via mm_sec_machwkey_del,
  ## then calls mm_sec_machwaddr_del and sta_mgmt_unregister. For AP-mode VIF,
  ## decrements RC ref count, sends MM_STA_DEL_CFM, and calls apm_tx_int_ps_clear.
  let sta = staInfoForIdx(staIdx)

  # Load VIF pointer from sta+39 (vifIdx byte used for table lookup)
  let vifIdx = sta.instNbr
  let vif = vifChannelForIdx(vifIdx)

  if vif.vifType != VIF_TYPE_STA:
    # AP mode path (.L192): check sta+41 for connection status
    let connStatus = sta.psMode
    if connStatus == 1:
      # Decrement VIF-side PS/BA counter at vif+334.
      let rcFlags = vif.psBaCounter
      let newFlags = rcFlags - 1
      vif.psBaCounter = newFlags
      if newFlags == 0:
        # Get key index from vif+87 and add 5 for HW key slot
        let keyBase = vif.vifIdx
        let hwKeyIdx = (keyBase + 5) and 0xFF

        # Send MM_STA_DEL_CFM message
        # Blob: ke_msg_alloc(0x37, 9, TASK_MM, paramLen=2)
        let msg = cast[ptr MmStaDelKeyCfmPayload](
          ke_msg_alloc(0x37'u16, 9, TASK_MM,
                       MmStaDelKeyCfmPayloadSize))
        # Store key index in msg[0], zero in msg[1]
        mmEnvClearKeepAliveTimestampByte1()  # clear byte at mm_env+41
        msg.hwKeyIdx = hwKeyIdx
        msg.status = 0
        ke_msg_send(msg)

        # Call apm_tx_int_ps_clear
        let apStaIdx = vif.vifIdx
        let psIdx = (apStaIdx + 5) and 0xFF
        apm_tx_int_ps_clear(cast[pointer](vif), cast[uint8](psIdx))
    # Exit via sta_mgmt_unregister below
  else:
    # STA mode path: store 0xFF at sta[96] (disassociate)
    vif.staIdx = 0xFF

    # Get encryption key info from VIF entry and delete HW keys
    let sec = vifSecurity(vif)
    if sec.connected != 0:
      let keyType = sec.cipher
      if keyType >= 2 and keyType <= 4:
        # Delete key at vif+510
        let keyVal = sec.staKeySlots[0]
        if keyVal != 0xFF:
          mm_sec_machwkey_del(keyVal)
          sec.staKeySlots[0] = 0xFF

        # Check second VIF for keys
        let keyVal2 = sec.staKeySlots[1]
        if keyVal2 != 0xFF:
          mm_sec_machwkey_del(keyVal2)
          sec.staKeySlots[1] = 0xFF

        # Check third key at vif+512
        let keyVal3 = sec.staKeySlots[2]
        if keyVal3 != 0xFF:
          mm_sec_machwkey_del(keyVal3)
          sec.staKeySlots[2] = 0xFF
      elif keyType == 1:
        # Single key at vif+513
        let keyVal = sec.staKeySlots[3]
        if keyVal != 0xFF:
          mm_sec_machwkey_del(keyVal)
          sec.staKeySlots[3] = 0xFF

  # Common: delete MAC HW address and unregister station
  mm_sec_machwaddr_del(staIdx)
  sta_mgmt_unregister(staIdx)

proc mm_check_rssi*(vifEntry: pointer, newRssi: int8) {.exportc, cdecl.} =
  ## Check RSSI and send indication if threshold crossed (77 instrs).
  ## a0=vifEntry, a1=newRssi.
  ## Reads old RSSI from vifEntry+188, stores new RSSI, reads threshold+direction
  ## from vifEntry+189..191. If threshold is zero, sends unconditionally.
  ## Otherwise checks if threshold crossed (direction-dependent hysteresis)
  ## and sends MM_RSSI_STATUS_IND (msg id 67 = 0x43) if appropriate.
  let vif = vifChannelAt(vifEntry)
  let oldRssi = vif.rssiLast
  vif.rssiLast = newRssi
  let macTime = macTimeNow()
  # Read threshold, direction, and last-reported state
  let threshold = vif.rssiThreshold
  let hysteresis = vif.rssiHysteresis
  let prevState = vif.rssiState
  let rssiTimer = chanRssiLastReportTime()
  # If oldRssi was zero (not initialized), always report
  if oldRssi == 0:
    # Unconditional report -- allocate MM_RSSI_STATUS_IND (id=0x43, size=3)
    let msg = cast[ptr MmRssiStatusIndPayload](
      ke_msg_alloc(0x43, 9, 0, MmRssiStatusIndPayloadSize))
    if msg != nil:
      msg.vifIdx = vif.vifIdx
      msg.thresholdState = prevState
      msg.rssiDbm = newRssi.uint8
      rssiTimer[] = macTime
      ke_msg_send(msg)
    return
  # Check if enough time has passed since last report (~2s = 0x1E8480 MAC ticks)
  if oldRssi != 0:
    let lastTime = rssiTimer[]
    let elapsed = macTime - lastTime
    if elapsed < 0x1E8480'u32:
      return
  # Threshold-based check
  if threshold == 0:
    return
  # Compute new state depending on direction (hysteresis)
  var newState: uint8
  var thresh5 = cast[int8](threshold.int8 - 5)
  if hysteresis == 0:
    # Below-threshold monitoring
    if newRssi >= oldRssi:
      thresh5 = threshold
    newState = if (newRssi < thresh5): 1'u8 else: 0'u8
  else:
    # Above-threshold monitoring
    if oldRssi >= newRssi:
      thresh5 = cast[int8](threshold.int8 + 5)
    let cmp = if (newRssi >= thresh5): 0'u8 else: 1'u8
    newState = cmp xor 1
  # Only send indication if state changed
  let curState = vif.rssiState
  if curState != newState:
    let msg = cast[ptr MmRssiStatusIndPayload](
      ke_msg_alloc(0x43, 9, 0, MmRssiStatusIndPayloadSize))
    if msg != nil:
      msg.vifIdx = vif.vifIdx
      msg.thresholdState = newState
      msg.rssiDbm = newRssi.uint8
      ke_msg_send(msg)
  vif.rssiState = newState

proc mm_check_beacon*(param: pointer) {.exportc, cdecl.} =
  ## Process a received beacon frame (290 instructions in blob).
  ##
  ## Blob ABI: a0=param(rxdesc), a1=vifEntry, a2=staEntry, a3=timIeAddrOut
  ## 14 function calls: mm_check_rssi, 2x hal_machw_rx_duration,
  ## utils_crc32_stream_init/feed_block/results, __udivdi3,
  ## mm_timer_set, mm_timer_clear, mac_ie_find, mm_send_connection_loss_ind,
  ## txl_frame_send_null_frame, indirect log call.

  var vifEntry {.noinit.}: pointer
  var staEntry {.noinit.}: pointer
  var timIeAddrOut {.noinit.}: ptr uint32
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", vifEntry, "));"].}
  {.emit: ["asm volatile(\"mv %0, a2\" : \"=r\"(", staEntry, "));"].}
  {.emit: ["asm volatile(\"mv %0, a3\" : \"=r\"(", timIeAddrOut, "));"].}

  let rx = beaconRxDescView(param)
  let vif = vifChannelAt(vifEntry)
  let sta = staInfoAt(staEntry)

  # Step 1: Extract frame data from rxdesc payload chain
  let payloadDesc = beaconPayloadDescView(rx.payloadDesc)
  if payloadDesc == nil: return
  let frame = beaconFrameFixedView(payloadDesc.frameData)
  if frame == nil: return

  let frameLen = rx.frameLen
  let ieBodyLen =
    if frameLen.uint32 > sizeof(BeaconFrameFixedView).uint32:
      frameLen.uint32 - sizeof(BeaconFrameFixedView).uint32
    else:
      0'u32
  let ieBody = beaconFrameIeBody(frame)

  # Send keepalive null frame after beacon processing (blob: txl_frame_send_null_frame at 0x98)
  let staIdx = vif.staIdx
  discard txl_frame_send_null_frame(staIdx, cast[pointer](mm_ap_traffic_probe_cfm),
                                    pointerAddrU32(vifEntry))

  # Step 2: CSA check - if vif_entry[64] (CSA ctx ptr) nonzero, parse DS Param IE (id=3)
  let csaCtxPtr = vif.chanCtxt
  if csaCtxPtr != nil:
    # Blob calls mac_ie_find(ieBody, ieBodyLen, 3) for DS Parameter Set
    let dsIe = mac_ie_find(ieBody, ieBodyLen, 3)
    if dsIe != nil:
      let csaChan = addr chanCtxtAt(csaCtxPtr).channel
      let csaCtxFreq = csaChan.primFreq
      let newFreq = dsParamFreq(csaChan.band, dsParamSetIeAt(dsIe))
      if csaCtxFreq != newFreq:
        return  # Channel mismatch, bail out

  # Step 3: Increment beacon rx count
  vif.beaconRxCount = vif.beaconRxCount + 1

  # Step 4: Beacon loss timer logic
  let prevTimestamp = vif.lastBeaconMacTime
  if prevTimestamp != 0:
    let macTsNow = volatileLoad(cast[ptr uint32](0x24B00120'u32))
    let threshold = vif.beaconLossWindow
    let elapsed = macTsNow - prevTimestamp
    if elapsed >= threshold:
      # Re-read and update
      let macTs2 = volatileLoad(cast[ptr uint32](0x24B00120'u32))
      vif.beaconLossWindow = macTs2 - prevTimestamp
  else:
    let macTsNow = volatileLoad(cast[ptr uint32](0x24B00120'u32))
    vif.probeCount = 0
    vif.lastBeaconMacTime = macTsNow

  let logFunc = getLogFunc(204)
  let ops = blOpsData()

  # Beacon loss detection: check bcn_to_flag at g_bl_ops_funcs+27
  let prevBcnTime = vif.beaconCrc
  let bcnToFlag = ops.beaconTimeoutConfig[3]
  if bcnToFlag != 0:
    let macTs = volatileLoad(cast[ptr uint32](0x24B00120'u32))
    let vifElapsed = vif.beaconTimeoutBase
    let threshold30s = 0x1C9C380'u32  # 30 seconds in microseconds
    if cast[int32](threshold30s - macTs + vifElapsed) < 0:
      # Beacon loss threshold exceeded - send null frame probe
      let staIdx = vif.staIdx
      let probeCount = ops.beaconProbeCountdown
      if probeCount != 0:
        ops.beaconProbeCountdown = probeCount - 1
      else:
        # Probe countdown expired: reset to 10, send connection loss
        ops.beaconProbeCountdown = 10
        mm_send_connection_loss_ind(staIdx, 22)

  # Step 5: Call mm_check_rssi
  mm_check_rssi(vifEntry, rx.rssi)

  # Step 6: Init CRC for beacon change detection
  var crcState {.noinit.}: array[8, uint8]
  utils_crc32_stream_init(addr crcState[0])
  # Feed 4-byte beacon interval/capability field
  utils_crc32_stream_feed_block(addr crcState[0], addr frame.beaconInterval, 4)

  timIeAddrOut[] = 0  # no TIM IE found yet

  # IE walk: find TIM IE and feed non-TIM IEs into CRC
  var timIe: ptr MacIeView = nil
  var currentIeAddr = cast[uint](ieBody)
  var remaining = ieBodyLen
  while remaining > 0:
    let ie = macIeAt(currentIeAddr)
    let ieId = ie.id
    let ieLen = ie.len
    let totalLen = ieLen.uint32 + 2
    if totalLen > remaining: break
    if ieId == 5:  # TIM IE
      timIeAddrOut[] = cast[uint32](currentIeAddr)
      timIe = ie
    else:
      # Feed non-TIM IEs into CRC for beacon change detection
      utils_crc32_stream_feed_block(addr crcState[0], cast[pointer](currentIeAddr),
                                    ieLen.uint32)
    remaining -= totalLen
    currentIeAddr += totalLen

  # Finalize CRC and store as beacon fingerprint
  let crcResult = utils_crc32_stream_results(addr crcState[0])
  vif.beaconCrc = crcResult

  # Extract DTIM period from TIM IE or the STA beacon timing slot.
  var dtimPeriodFinal: uint16 = sta.listenWindowDuration
  if dtimPeriodFinal == 0:
    dtimPeriodFinal = 1
    if timIe != nil:
      let timData = macIePayload(timIe)
      let dtimP = timData[1]
      if dtimP != 0:
        dtimPeriodFinal = dtimP.uint16
      else:
        dtimPeriodFinal = timData[0]
        if dtimPeriodFinal == 0:
          dtimPeriodFinal = 1

  # Step 7: Call hal_machw_rx_duration for frame timing
  let rxDurFull = hal_machw_rx_duration(param, frameLen.uint32)
  let rxDurHdr = hal_machw_rx_duration(param, 24)

  # Step 8: Extract TSF timestamp (8 bytes at beacon body offsets 24..31)
  let tsfLo = frame.tsfLow
  let tsfHi = frame.tsfHigh

  # Beacon interval (2 bytes at offsets 32..33)
  let bcnInterval = frame.beaconInterval
  let bcnIntTicks = bcnInterval.uint32 shl 10

  # Log beacon (line 272)
  let macTsForLog = volatileLoad(cast[ptr uint32](0x24B00120'u32))
  if logFunc != nil:
    type LogP = proc(a0, a1: uint32, fmt: pointer, line: uint32, a5: uint32) {.cdecl, varargs.}
    cast[LogP](logFunc)(1, 0, nil, 272, bcnInterval.uint32)

  # Step 9: Compute effective interval
  let effectiveInterval = bcnIntTicks * dtimPeriodFinal.uint32

  # Step 10: 64-bit TBTT computation
  let macTsLo = volatileLoad(cast[ptr uint32](0x24B00120'u32))
  let chanOverhead = sta.beaconTimeOffset
  let descAccessTime = volatileLoad(cast[ptr uint32](0x24B080A4'u32))
  let tbttBase = macTsLo - 400'u32 - chanOverhead - descAccessTime

  var nextTbtt: uint32
  if effectiveInterval != 0:
    # 64-bit division: tsf / effectiveInterval to get quotient
    # Blob uses __udivdi3 explicitly; use volatile to prevent GCC optimizing to __umoddi3
    let tsf64 = tsfLo.uint64 or (tsfHi.uint64 shl 32)
    let intv64 = effectiveInterval.uint64
    var quot {.volatile.}: uint64 = tsf64 div intv64
    let nextBcn = (quot + 1) * intv64
    nextTbtt = tbttBase + (nextBcn - tsf64).uint32
  else:
    nextTbtt = tbttBase

  # Check if TBTT changed
  let oldTbtt = vif.tbttTimer.expiry
  if nextTbtt != oldTbtt:
    mm_timer_set(addr vif.tbttTimer, nextTbtt)

  # Step 11: CSA flag check. Blob at .L246 (0x254):
  #   lbu a5, 86(s10); bnez a5, .L247
  #   (CSA == 0 path): addi a0, s10, 140; call mm_timer_clear
  #   (CSA != 0 path): fall through to .L247 — no timer action
  #
  # Prior Nim had this inverted twice over: it called mm_timer_set on the
  # CSA==0 path (wrong function; blob clears) and mm_timer_clear on the
  # CSA!=0 path (blob does nothing there). A mis-armed keep-alive timer
  # plus a phantom clear would cancel STA-mode keep-alive prematurely
  # during channel-switch-announcement processing.
  let vifCsaFlag = vif.vifType
  if vifCsaFlag == 0:
    mm_timer_clear(addr vif.keepAliveTimer)

  # Beacon change detection: compare CRC fingerprint
  let changed = if vif.beaconCrc != prevBcnTime: 1'u32 else: 0'u32
  {.emit: ["asm volatile(\"mv a0, %0\" : : \"r\"(", changed, "));"].}

proc mm_sta_tbtt*(vifIdx: uint8) {.exportc, cdecl.} =
  ## Handle STA TBTT (target beacon transmission time) (108 instrs).
  ## From blob: param is actually a VIF entry pointer (not a u8 vifIdx).
  ## Logs, checks association state (vif+88), computes next TBTT time from
  ## sta_info_tab, programs timers, calls vif_mgmt_bcn_to_prog,
  ## chan_tbtt_switch_update, chan_is_on_channel, ps_check_tbtt.
  ## If probe counter exceeds 100, sends null frame; if > 50, sends PM event.
  let vif = cast[uint](cast[pointer](vifIdx))  # ABI: param is actually a pointer
  let vifView = vifChannelAt(vif)
  inc nimFwDbgStaTbttEnter
  let logFn = getLogFunc(0xCC)
  if logFn != nil:
    cast[proc(a0: uint32, a1: uint32, a2: pointer, a3: uint32, a4: pointer){.cdecl.}](logFn)(
      1, 0, nil, 624, cast[pointer](vif))
  # Check association state at vif+88
  let assocState = vifView.state
  if assocState == 0:
    return
  inc nimFwDbgStaTbttAssoc
  # Compute next TBTT time from associated STA's timer
  let staIdx = vifView.staIdx
  let staTimerVal = staInfoForIdx(staIdx).initialRateConfig
  let vifBcnInterval = vifView.tbttTimer.expiry
  let tbttTime = staTimerVal + vifBcnInterval
  mm_timer_set(addr vifView.tbttTimer, tbttTime)
  # Set keep-alive timer: MAC timestamp + mm_env[7]
  let macTime = regRead(MACHW_TIMLO_REG)
  let keepAliveInterval = mmEnvView().keepAliveInterval
  mm_timer_set(addr vifView.keepAliveTimer, macTime + keepAliveInterval)
  # Increment TBTT count at vif+120
  vifView.tbttCount = vifView.tbttCount + 1
  # Reprogram beacon detection
  vif_mgmt_bcn_to_prog(cast[pointer](vif))
  # Update channel TBTT state
  chan_tbtt_switch_update(cast[pointer](vif), tbttTime)
  # Check if on channel
  let onChan = chan_is_on_channel(cast[pointer](vif))
  if not onChan:
    return
  inc nimFwDbgStaTbttOnChan
  # Set bit 0 in vif+4
  vifView.flags = vifView.flags or 1'u32
  # Check power save TBTT
  ps_check_tbtt(cast[pointer](vif))
  # Increment probe counter at vif+116
  var probeCount = vifView.probeCount
  probeCount = probeCount + 1
  vifView.probeCount = probeCount
  if probeCount > nimFwDbgStaTbttPCMax.uint8:
    nimFwDbgStaTbttPCMax = probeCount.uint32
  # Guard: if WPA handshake is still pending on this VIF, the keep-alive
  # null-frame loop is meaningless (the AP won't ACK us before WPA completes)
  # and will exhaust the 4-entry frame pool. After a generous grace period,
  # give up on the handshake and report connection loss.
  let vifIdxLocal = vifView.vifIdx
  let wpaPending = vifIdxLocal < 8 and
                   (nimFwWpaPendingMask and (1'u32 shl vifIdxLocal)) != 0
  if wpaPending:
    inc nimFwDbgStaTbttSkip
    if probeCount > 60:
      inc nimFwDbgStaTbttGiveup
      # Time out the stuck WPA handshake. Clear the pending bit AND the VIF
      # assoc state (vif+88) so subsequent mm_sta_tbtt entries return early at
      # the assocState==0 gate. Report connection loss to the host so the
      # upper layer can tear down and surface a proper failure status.
      nimFwWpaPendingMask = nimFwWpaPendingMask and (not (1'u32 shl vifIdxLocal))
      vifView.state = 0
      mm_send_connection_loss_ind(vifIdxLocal, 15)
      # Surface a definitive WPA-timeout failure to SM/host so wifiConnect
      # returns quickly instead of waiting for the upper-layer connect-timeout.
      # Match the vendor status reported after supplicant deauth completion:
      # status=8 (WPA/PSK handshake timeout), reason=15.
      if ke_state_get(TASK_SM) == SM_ACTIVATING_STATE:
        sm_connect_ind(WLAN_FW_4WAY_HANDSHAKE_ERROR_PSK_TIMEOUT_FAILURE, 15)
    return
  if probeCount > 100:
    inc nimFwDbgStaTbttPC100
    # Send null frame with probe callback
    let staIdxForNull = vifView.staIdx
    let probeRc = txl_frame_send_null_frame(
      staIdxForNull, cast[pointer](mm_ap_probe_cfm), cast[uint32](vif))
    if probeRc == 0'u8:
      # The TX confirmation callback owns the next liveness decision.
      vifView.probeCount = 0
    else:
      # Descriptor pressure is transient; back off instead of retrying on
      # every TBTT and starving foreground WiFi/BLE coexistence traffic.
      vifView.probeCount = 50
  elif probeCount > 49:
    # Send PM post event (blob: wifi_hosal_pm_post_event tail-call)
    wifi_hosal_pm_post_event(3, 0, nil)

proc mm_tbtt_evt*() {.exportc, cdecl.} =
  ## TBTT event handler (109 instrs).
  ## From blob: reads ke_env (event field), masks with 0x3000000 to extract
  ## TBTT type. Asserts not both primary+secondary. Clears the event bit.
  ## Loads VIF list from vif_mgmt_env+8. Under IRQ protection, halts and
  ## flushes beacon AC (AC=4). Walks VIF list: for AP VIFs (type==2),
  ## decrements bcn_tx_next (vif+325), when it hits 0 resets from bcn_divisor
  ## (vif+324), calls vif_mgmt_bcn_to_prog, and if vif+64 is nonzero computes
  ## TBTT offset and calls chan_tbtt_switch_update. After VIF walk, calls
  ## mm_bcn_transmit, then decrements two countdown bytes (.LANCHOR0 / .LANCHOR1)
  ## and calls sta_mgmt_aging_postponed_desc when first hits 0.
  # Read ke_env field (event bitmap) and mask TBTT bits
  let keEvtVal = keEvtField
  let tbttBits = keEvtVal and 0x03000000'u32  # primary | secondary TBTT
  # Log
  let logFn = getLogFunc(0xCC)
  if logFn != nil:
    cast[proc(a0: uint32, a1: uint32, a2: pointer, a3: uint32, a4: pointer){.cdecl.}](logFn)(
      1, 0, nil, 898, nil)
  # Assert not both bits set simultaneously
  if tbttBits == 0x03000000'u32:
    assert_err("mm_bcn.c", "mm_bcn.c", 902)
  # Clear the TBTT event
  ke_evt_clear(tbttBits)
  # Load active VIF list head from vif_mgmt_env.
  var curVif = cast[pointer](vifMgmtEnvView().activeList.first)
  # Halt and flush beacon AC under interrupt protection
  let saved = irqSave()
  txl_cntrl_halt_ac(4)
  txl_cntrl_flush_ac(4)
  irqRestore(saved)
  # Walk VIF list, handling AP VIFs
  while curVif != nil:
    let vif = vifChannelAt(curVif)
    if vif.vifType == VIF_TYPE_AP:
      # Decrement bcn_tx_next countdown (vif+325)
      var bcnNext = vif.beaconCountdown
      bcnNext = bcnNext - 1
      vif.beaconCountdown = bcnNext
      if bcnNext == 0:
        # Reset from bcn_divisor (vif+324)
        vif.beaconCountdown = vif.beaconDivisor
        # Reprogram beacon timeout
        vif_mgmt_bcn_to_prog(curVif)
        # If vif+64 (chan_ctxt pointer) is nonzero, update TBTT switch
        if vif.chanCtxt != nil:
          # Compute TBTT time from MAC timestamp and channel env
          let macTimeLo = regRead(MACHW_TIMLO_REG)
          let chanEnvOff = regRead(0x24B08040'u32)  # chan env timer offset from intc
          let tbttBase = macTimeLo + 0xFFFFF448'u32  # offset constant from blob
          let tbttShifted = chanEnvOff shl 5
          let tbttTime = (vif.apBeaconInterval.uint32 shl 10) + tbttShifted + tbttBase
          chan_tbtt_switch_update(curVif, tbttTime)
    # Advance to next VIF in linked list (vif+0 = next pointer)
    curVif = vif.next
  # After walk: transmit beacons
  mm_bcn_transmit(0)
  # Decrement aging counters (.LANCHOR0 = mmTbttAgingCount0, .LANCHOR1 = mmTbttAgingCount1)
  mmTbttAgingCount0 = mmTbttAgingCount0 - 1
  mmTbttAgingCount1 = mmTbttAgingCount1 - 1
  if mmTbttAgingCount0 == 0:
    # Reset aging period to 2 and call sta_mgmt_aging_postponed_desc
    mmTbttAgingCount0 = 2
    discard sta_mgmt_aging_postponed_desc(nil, 0)
  if mmTbttAgingCount1 == 0:
    # Reset second counter to 10
    mmTbttAgingCount1 = 10

proc mm_sta_timer_bcn_timeout*(param: pointer) {.exportc, cdecl.} =
  ## Beacon timeout timer handler (25 instrs).
  ## From blob: logs via g_bl_ops_funcs[0xCC] with args (1, 0, file, 600, vifEntry),
  ## increments vifEntry word at offset 124 (bcn_loss_count), clears bit 0 of
  ## vifEntry word at offset 4 (link state flags).
  let vif = vifChannelAt(param)
  let logFn = getLogFunc(0xCC)
  if logFn != nil:
    cast[proc(a0: uint32, a1: uint32, a2: pointer, a3: uint32, a4: pointer){.cdecl.}](logFn)(
      1, 0, nil, 600, param)
  # Increment beacon loss count at vif+124
  vif.beaconLossCount = vif.beaconLossCount + 1
  # Clear bit 0 of vif+4 (link state flags)
  vif.flags = vif.flags and (not 1'u32)

proc mm_sta_timer_bcmc_timeout*(param: pointer) {.exportc, cdecl.} =
  ## Broadcast/multicast timeout timer handler.
  discard

proc mm_sta_timer_data_timeout*(param: pointer) {.exportc, cdecl.} =
  ## Data timeout timer handler (11 instrs).
  ## From blob: tail-calls g_bl_ops_funcs[0xCC] (platform log) with args
  ## (1, 0, file, 611, vifEntry). This is a pure logging/notification function.
  let logFn = getLogFunc(0xCC)
  if logFn != nil:
    cast[proc(a0: uint32, a1: uint32, a2: pointer, a3: uint32, a4: pointer){.cdecl.}](logFn)(
      1, 0, nil, 611, param)

# MM Security operations
proc mm_sec_machwaddr_wr*(staIdx: uint8, keySlotRaw: pointer,
                          unusedCompatArg: uint8): uint8 {.exportc, cdecl, discardable.} =
  ## Write MAC address to HW address table (53 instructions in blob).
  ## Blob ABI: a0=staIdx, a1=keySlot. Looks up MAC from sta_info_tab[a0*368].
  ## Nim ABI keeps three parameters for compatibility but keySlotRaw is
  ## actually the keySlot passed in a1; we read MAC from sta_info_tab internally.
  ##
  ## MACHW register layout (base 0x24B00000 in blob / 0x44B00000 actual):
  ##   +0x0BC: address data low  (halfwords at sta_entry+4/+6, packed)
  ##   +0x0C0: address data high (halfword at sta_entry+8)
  ##   +0x0AC..0x0B8: key material words 0..3 (cleared to 0 for addr write)
  ##   +0x0C4: control register (write hwStaIdx<<16 | keySlot<<4 | 0x40000002)
  discard unusedCompatArg

  # Blob reads the station MAC from sta_info_tab[staIdx].
  let mac = staMacWords(staInfoForIdx(staIdx))

  # Compute HW station index: (staIdx + 8) & 0xFF
  let hwStaIdx = ((staIdx.uint32 + 8) and 0xFF)

  machwSecurityWriteAddress(mac.lo, mac.hi)
  machwSecurityClearKeyMaterial()

  # Validate keySlot field (shifted left 4)
  # Blob: a1 is keySlot. In Nim ABI, keySlotRaw carries this value.
  # Blob: andi a5,s2,-241 = s2 & 0xFFFFFF0F, asserts if non-zero
  # This checks that (keySlot << 4) has no bits outside 4..7 set
  let keySlot = cast[uint32](keySlotRaw)
  let idxField = keySlot shl 4
  if (idxField and 0xFFFFFF0F'u32) != 0:
    assert_err("mm_sec.c", "mm_sec.c", 6259)

  # Build control word: hwStaIdx<<16 | idxField | 0x40000002
  let ctrlWord = (hwStaIdx shl 16) or idxField or 0x40000002'u32
  nimFwConnectTrace2U32("[WIFI-CT] machwaddr ", (staIdx.uint32 or (hwStaIdx shl 8) or (keySlot shl 16)), ctrlWord)
  nimFwConnectTrace2U32("[WIFI-CT] machwmac ", mac.lo, mac.hi)
  machwSecurityWriteControl(ctrlWord)

  # Poll until bit 30 (0x40000000) clears
  discard waitMachwSecurityControlClear(0x40000000'u32)
  return hwStaIdx.uint8

proc mm_sec_machwaddr_del*(staIdx: uint8) {.exportc, cdecl.} =
  ## Delete MAC address from HW address table (42 instructions in blob).
  ## Writes all-ones to address data, zeros to key material, then triggers
  ## the HW with (hwStaIdx<<16 | 0x40000000) and polls until done.
  machwSecurityWriteAddress(0xFFFFFFFF'u32, 0xFFFFFFFF'u32)

  # Compute HW station index: (staIdx + 8) & 0xFF
  let hwStaIdx = ((staIdx.uint32 + 8) and 0xFF)

  machwSecurityClearKeyMaterial()

  # Build control word: hwStaIdx<<16 | 0x40000000, then write
  let ctrlWord = (hwStaIdx shl 16) or 0x40000000'u32
  machwSecurityWriteControl(ctrlWord)

  # Poll until bit 30 (0x40000000) clears
  discard waitMachwSecurityControlClear(0x40000000'u32)

proc mm_sec_macrx_ind*(staIdx: uint8, payload: pointer, length: uint16) {.exportc, cdecl.} =
  ## Forward EAPOL/security frame to host via IPC. Uses platform alloc/free
  ## at g_bl_ops_funcs[0xB8] / [0xBC] (not the never-populated keAllocFunc /
  ## keFreeFunc Nim-only globals).
  let allocFn = cast[proc(sz: uint32): pointer {.cdecl.}](
    blOpsFunc(0xB8))
  let securityIndicationMsg = allocFn(length.uint32 + 16)
  if securityIndicationMsg != nil:
    let ind = secMacRxIndAt(securityIndicationMsg)
    ind.staIdx = staIdx
    ind.length = length
    discard c_memcpy(addr ind.payload[0], payload, length.csize_t)
    ipc_emb_msg_push(securityIndicationMsg)
    platformFree(securityIndicationMsg)

proc mm_sec_machwkey_wr*(param: pointer) {.exportc, cdecl.} =
  ## Write encryption key to MAC HW key table (143 instructions).
  ##
  ## param layout is the 56-byte key buffer built by setKey and the WEP
  ## setup path. mm_sec_machwkey_wr consumes:
  ##   [0]   u8: VIF / MAC address index
  ##   [1]   u8: keyType (0xFF = WEP default key, 0..6 = pairwise/group cipher)
  ##   [8..23]  key material (4 x 32-bit words)
  ##   [52]  u8: cipherType (0=WEP40, 1=TKIP, 3=WEP104, 5=CCMP)
  ##   [53]  u8: keyIdx (HW key slot / VIF index on default-key paths)
  ##   [54]  u8: spp (SPP A-MSDU / MIC mode for TKIP)
  ##
  ## MACHW register offsets (base 0x44B00000):
  ##   +0x080: key RAM window base
  ##   +0x0AC..0x0B8: key material words 0..3
  ##   +0x0BC: key data low
  ##   +0x0C0: key data high
  ##   +0x0C4: key control (write trigger bit 30, poll until clear)
  ##   +0x0D8: key count / config

  let req = machwKeyWriteParamView(param)
  let keyType = req.keyType     # s3
  let keyIdx = req.keyIdx       # s1 (blob: lbu s1,53(a0))
  var hwIdx = req.addrIdx       # s0
  var keyTypeForCtrl = keyType.uint32
  var cipherType = req.cipherType
  inc nimFwDbgMachwKeyWrCalls
  nimFwDbgMachwKeyWrLast0 = req.addrIdx.uint32 or (keyType.uint32 shl 8) or
    (req.keyLen.uint32 shl 16) or (req.macLen.uint32 shl 24)
  nimFwDbgMachwKeyWrLast1 = cipherType.uint32 or (keyIdx.uint32 shl 8) or
    (req.spp.uint32 shl 16) or (req.keyFlags.uint32 shl 24)

  if keyType == 0xFF:
    inc nimFwDbgMachwKeyWrGroup
    # Default WEP / group-key path
    if cipherType == 5:
      # CCMP: derive HW index from key count register top byte
      let keyCount = machwSecurityKeyCount()
      let baseIdx = cast[uint8](keyCount shr 24)
      hwIdx = cast[uint8]((hwIdx.uint32 + baseIdx.uint32 - 3) and 0xFF)
      # Blob 0x48: vif_mgmt_add_key(param, hwIdx)
      vif_mgmt_add_key(param, hwIdx)
      return
    else:
      # WEP40/WEP104: set key data low/high to all-ones (wildcard)
      machwSecurityWriteAddress(0xFFFFFFFF'u32, 0xFFFFFFFF'u32)
      # Blob 0x7c: vif_mgmt_add_key(param, hwIdx)
      vif_mgmt_add_key(param, hwIdx)
    # Blob falls through to the key material/control write for this path.

  else:
    inc nimFwDbgMachwKeyWrPair
    nimFwDbgMachwKeyWrPair0 = nimFwDbgMachwKeyWrLast0
    nimFwDbgMachwKeyWrPair1 = nimFwDbgMachwKeyWrLast1
    nimFwDbgMachwKeyWrPair2 = req.keyWords[0]
    nimFwDbgMachwKeyWrPair3 = req.keyWords[1]
    nimFwDbgMachwKeyWrPair4 = req.keyWords[2]
    nimFwDbgMachwKeyWrPair5 = req.keyWords[3]
    # Pairwise/group key: keyType 0..6
    if keyType > 6:
      assert_err("mm_sec.c", "mm_sec.c", 1137)

    # HW key slot = keyType + 8
    hwIdx = cast[uint8]((keyType.uint32 + 8) and 0xFF)
    # Blob does NOT call mm_sec_machwaddr_wr here.

    # Register key in upper-MAC STA table before programming MAC key RAM.
    # Vendor then remaps req.cipherType through CSWTCH tables for the hardware
    # control word. CSWTCH.121 maps the key-type field, and CSWTCH.122 maps
    # the hardware cipher mode.
    sta_mgmt_add_key(param, hwIdx)

    # Write STA MAC address to KEY_LO/KEY_HI (blob: lookup sta_info_tab by keyType,
    # read MAC bytes from staEntry[4..9], write 32-bit low + 16-bit high)
    let mac = staMacWords(staInfoForIdx(keyType))
    machwSecurityWriteAddress(mac.lo, mac.hi)

    # Check cipher type for dispatch (0..3 only for key RAM write)
  let validCipherType = cipherType <= 3
  if not validCipherType:
    # Vendor asserts, then continues with cipher 0 and key type 1.
    assert_err("mm_sec.c", "mm_sec.c", 1212)
    cipherType = 0
    keyTypeForCtrl = 1

  if validCipherType:
    keyTypeForCtrl =
      case cipherType
      of 0: 0'u32
      of 1: 1'u32
      of 2: 0'u32
      of 3: 1'u32
      else: keyTypeForCtrl

  let hwCipherType =
    case cipherType
    of 0: 1'u32
    of 1: 2'u32
    of 2: 3'u32
    of 3: 1'u32
    else: 0'u32

  machwSecurityWriteKeyMaterial(req.keyWords)

  # Validate keyIdx field (shifted left 4, low nibble must be 0)
  let keyIdxField = keyIdx.uint32 shl 4
  if (keyIdxField and not 0xF0'u32) != 0:
    assert_err("mm_sec.c", "mm_sec.c", 0x1873)

  # Validate spp field (shifted left 2, only bits [3:2] valid)
  let sppField = req.spp.uint32 shl 2  # blob: lbu s2,54(s2)
  if (sppField and not 0x0C'u32) != 0:
    assert_err("mm_sec.c", "mm_sec.c", 0x1874)

  # Build control word and write:
  #   keyIdx<<4 | spp<<2 | keyType<<11 | hwIdx<<16 |
  #   hwCipherType<<8 | 0x40000000
  let ctrlWord = keyIdxField or sppField or
                 (keyTypeForCtrl shl 11) or
                 (hwIdx.uint32 shl 16) or
                 (hwCipherType shl 8) or
                 0x40000000'u32
  if keyType != 0xFF'u8:
    nimFwDbgMachwKeyWrPairCtrl = ctrlWord
  machwSecurityWriteControl(ctrlWord)

  # Poll until bit 30 (trigger) clears
  discard waitMachwSecurityControlClear(0x40000000'u32)
  if keyType != 0xFF'u8:
    machwSecurityWriteControl((hwIdx.uint32 shl 16) or 0x80000000'u32)
    discard waitMachwSecurityControlClear(0x80000000'u32)
    nimFwDbgMachwKeyWrRead0 = volatileLoad(addr machwSecurityRegs().keyMaterial[0])
    nimFwDbgMachwKeyWrRead1 = volatileLoad(addr machwSecurityRegs().keyMaterial[1])
    nimFwDbgMachwKeyWrRead2 = volatileLoad(addr machwSecurityRegs().keyMaterial[2])
    nimFwDbgMachwKeyWrRead3 = volatileLoad(addr machwSecurityRegs().keyMaterial[3])
    nimFwDbgMachwKeyWrReadCtrl = machwSecurityControl()

proc mm_sec_machwkey_del*(keyIdx: uint8) {.exportc, cdecl.} =
  ## Delete encryption key from MAC HW key table (76 instrs in blob).
  ##
  ## Dispatch by keyIdx relative to MACHW topCount (KEY_COUNT[31:24]):
  ##   keyIdx >  topCount        → pairwise key, tail-call vif_mgmt_del_key
  ##                                and SKIP the MACHW key-RAM clear below.
  ##   keyIdx <= topCount && <=7 → group key, clear MACHW KEY_LO/HI to all-ones,
  ##                                call vif_mgmt_del_key, then fall through
  ##                                to clear the MACHW key-RAM entries + wait
  ##                                for KEY_CTRL bit 0x40000000 to clear.
  ##   keyIdx >  7  && <= topCnt → station key path: writes STA MAC to KEY_LO/HI
  ##                                then calls sta_mgmt_del_key, falls through.

  let keyCount = machwSecurityKeyCount()
  let topCount = (keyCount shr 24).uint8

  if keyIdx > topCount:
    # Pairwise key path. Blob math (hwIdx/slot) from blob insns:
    #   hwIdx = (keyIdx - topCount - 1) / 2
    #   vifSlot = 4 + ((keyIdx - topCount - 1) & 1)
    #   vif = vif_info_tab[hwIdx]
    # Blob tail-calls vif_mgmt_del_key here — must RETURN WITHOUT clearing
    # the MACHW key-RAM (that is only done on the group/STA paths below).
    let pairwiseKeySlotOffset = keyIdx.int - topCount.int - 1
    let hwIdx = pairwiseKeySlotOffset div 2
    let vifSlot = 4 + (pairwiseKeySlotOffset and 1)
    let vif = vifChannelForIdx(hwIdx.uint8)
    vif_mgmt_del_key(cast[pointer](vif), vifSlot.uint8)
    return
  elif keyIdx <= 7:
    # Group key path: flood MACHW key data with all-ones, then delete via
    # vif_mgmt_del_key. Blob layout: vifIdx = keyIdx >> 2, vifSlot = keyIdx & 3.
    machwSecurityWriteAddress(0xFFFFFFFF'u32, 0xFFFFFFFF'u32)
    let vifSlot = keyIdx and 3
    let vifIdx = keyIdx shr 2
    let vif = vifChannelForIdx(vifIdx)
    vif_mgmt_del_key(cast[pointer](vif), vifSlot)
  else:
    # Station key: keyIdx - 8 → staIdx. Write STA MAC addr to KEY_LO/HI then
    # sta_mgmt_del_key. Blob falls through to the key-RAM clear + poll.
    let staIdx = keyIdx - 8
    let mac = staMacWords(staInfoForIdx(staIdx))
    machwSecurityWriteAddress(mac.lo, mac.hi)
    sta_mgmt_del_key(staIdx, 0)

  # Group/Station fall-through: clear the MACHW 128-bit key RAM at 0xAC..0xB8.
  # Blob then polls KEY_CTRL (0xC4) until bit 0x40000000 clears (write-done).
  # That is an MMIO write-serialize + delete completion barrier.
  machwSecurityClearKeyMaterial()
  discard waitMachwSecurityControlClear(0x40000000'u32)

  # Write control word with key index and trigger delete (bit 30)
  let ctrlWord = (keyIdx.uint32 shl 16) or 0x40000000'u32
  machwSecurityWriteControl(ctrlWord)

  # Poll until trigger bit clears
  discard waitMachwSecurityControlClear(0x40000000'u32)

proc mm_sec_machwkey_get*(keyIdx: uint8, outBuf: pointer, keySizeOut: pointer): pointer {.exportc, cdecl, discardable.} =
  ## Get key material from MAC HW key table (48 instructions in blob).
  ## Blob ABI: a0=keyIdx, a1=outBuf (16-byte dest), a2=keySizeOut (ptr u8).
  ## Reads key count from MACHW+0x0D8, triggers HW read via MACHW+0x0C4, polls,
  ## then copies 4 words from MACHW+0x080 region (+44..+56) into outBuf, writes
  ## keySize (8 or 16) to *keySizeOut, returns 0 (or -1 on bounds).

  # Read key count and check bounds
  let keyCount = machwSecurityKeyCount()
  let maxIdx = (keyCount shr 24).uint8
  if keyIdx >= maxIdx:
    return cast[pointer](-1)

  # Trigger HW read: keyIdx<<16 | 0x80000000
  let readCmd = (keyIdx.uint32 shl 16) or 0x80000000'u32
  machwSecurityWriteControl(readCmd)

  # Poll until bit 31 clears
  discard waitMachwSecurityControlClear(0x80000000'u32)

  # Check bit 0 of control to determine key size (16 or 8 bytes)
  let ctrlVal = machwSecurityControl()
  var keySize: uint8 = 8
  if (ctrlVal and 1) != 0:
    keySize = 16

  # Copy key material from KEY_RAM+44..+56 into output buffer — blob calls
  # memcpy here rather than inlining the 16-byte copy as four word stores.
  if outBuf != nil:
    discard c_memcpy(outBuf, addr machwSecurityRegs().keyMaterial[0], 16.csize_t)

  # Write key size to keySizeOut
  if keySizeOut != nil:
    cast[ptr uint8](keySizeOut)[] = keySize

  return cast[pointer](0)

proc mm_sec_keydump*() {.exportc, cdecl.} =
  ## Dump all MAC HW security keys for debugging (325 instructions).
  ##
  ## Reads security key RAM via MACHW registers:
  ##   0x24B000C4 = control (write index<<16 | 0x80000000 to trigger, poll bit31)
  ##   0x24B000BC/C0 = key data low/high readback
  ##   0x24B000D8 = total key count
  ##   0x24B000AC..B8 = key material words (4 x 32-bit)
  ## Ends with tail call to mm_rx_filter_set().

  const READ_TRIGGER = 0x80000000'u32
  let regs = machwSecurityRegs()

  # Clear bit 0 of crypto debug flag at 0x20005198
  let flagPtr = cast[ptr uint32](0x20005198'u32)
  volatileStore(flagPtr, volatileLoad(flagPtr) and not 1'u32)

  let logFunc = getLogFunc(76)
  let ops = blOpsData()
  type LogV = proc(a0, a1: uint32, fmt: pointer, line: uint32, a5: uint32) {.cdecl, varargs.}
  type Log0 = proc(a0, a1: uint32, fmt: pointer, line: uint32) {.cdecl, varargs.}

  let totalKeys = volatileLoad(addr regs.keyCount)

  if logFunc != nil: cast[LogV](logFunc)(2, 0, nil, 945, totalKeys)
  if logFunc != nil: cast[LogV](logFunc)(2, 0, nil, 946,
    totalKeys and 0xFF, (totalKeys shr 8) and 0xFF,
    (totalKeys shr 16) and 0xFF, totalKeys shr 24)
  if logFunc != nil: cast[Log0](logFunc)(2, 0, nil, 972)

  let keyCount = cast[int32](volatileLoad(addr regs.keyCount))
  if logFunc != nil: cast[LogV](logFunc)(2, 0, nil, 977, keyCount.uint32)

  var keyTableIndex: int32 = 0
  while keyTableIndex <= keyCount:
    volatileStore(addr regs.control, (keyTableIndex.uint32 shl 16) or READ_TRIGGER)
    discard waitMachwSecurityControlClear(READ_TRIGGER)

    let kdLo = volatileLoad(addr regs.dataLow)
    let kdHi = volatileLoad(addr regs.dataHigh)
    # Blob asserts upper 16 bits of kdHi must be zero (offset 0x116-0x12e)
    if (kdHi and 0xFFFF0000'u32) != 0:
      assert_err("mm_sec.c", "mm_sec.c", keyTableIndex.cint)
    let maskedHi = kdHi and 0xFFFF'u32

    if logFunc != nil: cast[LogV](logFunc)(2, 0, nil, 989, keyTableIndex.uint32,
      kdLo and 0xFF, (kdLo shr 8) and 0xFF,
      (kdLo shr 16) and 0xFF, kdLo shr 24,
      maskedHi and 0xFF, maskedHi shr 8)

    let keyControlValid = volatileLoad(addr regs.control)
    if logFunc != nil: cast[LogV](logFunc)(2, 0, nil, 998, keyControlValid and 1)
    let keyControlCipher = volatileLoad(addr regs.control)
    if logFunc != nil: cast[LogV](logFunc)(2, 0, nil, 999, (keyControlCipher shr 1) and 0x7FFF)
    let keyControlAddr = volatileLoad(addr regs.control)
    if logFunc != nil: cast[LogV](logFunc)(2, 0, nil, 1000, (keyControlAddr shr 16) and 0xFFFF)

    let kw0 = volatileLoad(addr regs.keyMaterial[0])
    let kw1 = volatileLoad(addr regs.keyMaterial[1])
    let kw2 = volatileLoad(addr regs.keyMaterial[2])
    let kw3 = volatileLoad(addr regs.keyMaterial[3])

    if logFunc != nil: cast[LogV](logFunc)(2, 0, nil, 1007,
      kw0 and 0xFF, (kw0 shr 8) and 0xFF,
      (kw0 shr 16) and 0xFF, kw0 shr 24,
      kw1 and 0xFF, (kw1 shr 8) and 0xFF,
      (kw1 shr 16) and 0xFF, kw1 shr 24,
      kw2 and 0xFF, (kw2 shr 8) and 0xFF,
      (kw2 shr 16) and 0xFF, kw2 shr 24,
      kw3 and 0xFF, (kw3 shr 8) and 0xFF,
      (kw3 shr 16) and 0xFF, kw3 shr 24)
    if logFunc != nil: cast[Log0](logFunc)(2, 0, nil, 1014)
    keyTableIndex += 1

  if logFunc != nil: cast[Log0](logFunc)(2, 0, nil, 1016)

  # Dump MAC address bytes from g_bl_ops_funcs struct.
  let macAddrLow = ops.macAddrLow
  let macAddrHigh = ops.macAddrHigh
  if logFunc != nil: cast[LogV](logFunc)(2, 0, nil, 1019,
    macAddrLow and 0xFF, (macAddrLow shr 8) and 0xFF,
    (macAddrLow shr 16) and 0xFF, macAddrLow shr 24,
    macAddrHigh and 0xFF, (macAddrHigh shr 8) and 0xFF)

  let beaconTimeoutConfig = ops.beaconTimeoutConfigWord()
  let adapterTimingConfig28 = ops.adapterTimingConfig28
  if logFunc != nil: cast[LogV](logFunc)(2, 0, nil, 1029,
    beaconTimeoutConfig and 0xFF, (beaconTimeoutConfig shr 8) and 0xFF,
    (beaconTimeoutConfig shr 16) and 0xFF, beaconTimeoutConfig shr 24,
    adapterTimingConfig28 and 0xFF, (adapterTimingConfig28 shr 8) and 0xFF)
  if logFunc != nil: cast[Log0](logFunc)(2, 0, nil, 1037)

  let beaconProbeCountdown = ops.beaconProbeCountdown
  let adapterTimingConfig36 = ops.adapterTimingConfig36
  if logFunc != nil: cast[LogV](logFunc)(2, 0, nil, 1041,
    beaconProbeCountdown and 0xFF, (beaconProbeCountdown shr 8) and 0xFF,
    (beaconProbeCountdown shr 16) and 0xFF, beaconProbeCountdown shr 24,
    adapterTimingConfig36 and 0xFF, (adapterTimingConfig36 shr 8) and 0xFF)

  let adapterTimingConfig40 = ops.adapterTimingConfig40
  let adapterTimingConfig44 = ops.adapterTimingConfig44
  if logFunc != nil: cast[LogV](logFunc)(2, 0, nil, 1051,
    adapterTimingConfig40 and 0xFF, (adapterTimingConfig40 shr 8) and 0xFF,
    (adapterTimingConfig40 shr 16) and 0xFF, adapterTimingConfig40 shr 24,
    adapterTimingConfig44 and 0xFF, (adapterTimingConfig44 shr 8) and 0xFF)
  if logFunc != nil: cast[Log0](logFunc)(2, 0, nil, 1059)

  # Tail call to hal_machw_timing_info (blob reloc at 0x3ee)
  hal_machw_timing_info()

# MM Beacon operations
proc mm_bcn_init*() {.exportc, cdecl.} =
  ## Initialize beacon subsystem (14 instrs in blob).
  ## From blob: memset(mm_bcn_env, 0, 20), then tail-calls co_list_init on
  ## the beacon pending list (at mm_bcn_env + some offset or a separate list).
  let env = bcnEnvView()
  discard c_memset(env, 0, sizeof(MmBcnEnvView).csize_t)
  co_list_init(addr env.timQueue)
  mmBcnInitDone = true

proc mm_bcn_init_vif*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Initialize beacon for a specific VIF (79 instrs).
  ## From blob: param is actually a VIF entry pointer (not a u8 vifIdx).
  ## Calls txl_frame_init_desc(vif+96, txl_bcn_pool, txl_bcn_hwdesc_pool, txl_bcn_buf_ctrl).
  ## Stores txl_bcn_hwdesc_cfms into txl_bcn_hwdesc_pool (the cfm pointer).
  ## Sets up beacon descriptor fields: vif+318=6, vif+328=0xFF, vif+327=0,
  ## vif+320=0, vif+330=0. Initializes txl_tim_desc with magic 0xCAFEFADE,
  ## links to txl_bcn_end_desc and txl_tim_ie_pool. Sets up TIM IE pool bytes
  ## [0]=5, [1]=4, [2]=vif+327, [3]=1, [4]=0xFF. Zeros txl_tim_bitmap_pool
  ## (252 bytes). Clears txl_bcn_end_desc fields. Stores mm_bcn_transmitted
  ## callback at vif+304, vif pointer at vif+308.
  let vif = vifChannelAt(vifEntry)
  let bcnBuf = addr txl_bcn_buf_ctrl[0]
  let bcnHwPool = addr txl_bcn_hwdesc_pool[0]
  let bcnPool = addr txl_bcn_pool[0]
  # Initialize beacon frame descriptor
  txl_frame_init_desc(cast[pointer](vifApBeaconFrameDesc(vif)), cast[pointer](bcnPool),
                       cast[pointer](bcnHwPool), cast[pointer](bcnBuf))
  # Store txl_bcn_hwdesc_cfms pointer into txl_bcn_hwdesc_pool
  let cfmsPtr = addr txl_bcn_hwdesc_cfms
  cast[ptr pointer](cast[uint](bcnHwPool))[] = cast[pointer](cfmsPtr)
  # Set beacon descriptor fields on VIF entry
  vif.timLength = 6'u16
  vif.timMin = 0xFF'u8
  vif.timMax = 0xFF'u8
  vif.timCountdown = 0
  vif.timCount = 0
  vif.timFlags = 0
  # Initialize TIM descriptor (txl_tim_desc): magic + pointers
  let timDesc = timDescView()
  let timIe = timIeAt(addr txl_tim_ie_pool[0])
  let timIeBase = cast[uint](addr txl_tim_ie_pool[0])
  let bcnEnd = beaconEndDesc()
  let bcnEndBase = cast[uint](addr txl_bcn_end_desc[0])
  let timBitmapBase = cast[uint](addr txl_tim_bitmap_pool[0])
  timDesc.magic = 0xCAFEFADE'u32
  timDesc.next = cast[pointer](bcnEndBase)
  timDesc.payloadStart = cast[pointer](timIeBase)
  timDesc.payloadEnd = cast[pointer](timIeBase + 5)
  timDesc.status = 0
  # Set up TIM IE pool bytes
  let timCountdown = vif.timCountdown
  timIe.ie.id = 5        # TIM
  timIe.ie.len = 4
  timIe.bitmapControl = 0
  timIe.dtimCount = timCountdown
  timIe.dtimPeriod = 1
  timIe.partialBitmap[0] = 0xFF'u8
  # Compute bitmap offset from vif+329 and add txl_tim_bitmap_pool base
  let bitmapOff = vif.timMax
  timDesc.bitmapMagic = 0xCAFEFADE'u32
  timDesc.bitmapNext = cast[pointer](bcnEndBase)
  let bitmapAddr = bitmapOff.uint + timBitmapBase
  timDesc.bitmapEnd = cast[pointer](bitmapAddr)
  # Zero TIM bitmap (252 bytes)
  discard c_memset(cast[pointer](timBitmapBase), 0, 252.csize_t)
  # Get beacon HW descriptor from vif+208
  let hwDescPtr = vif.beaconTxDesc
  if hwDescPtr != nil:
    let hwDesc = hostTxHwDescAt(hwDescPtr)
    hwDesc.retryLimitControl = 0
    hwDesc.controlFlags = 0
    hwDesc.status = 0
  # Clear bcn_end_desc fields
  bcnEnd.status = 0
  bcnEnd.magic = 0xCAFEFADE'u32
  bcnEnd.next = 0
  # Store mm_bcn_transmitted callback and VIF pointer
  let frameDesc = vifApBeaconFrameDesc(vif)
  frameDesc.callback = cast[pointer](mm_bcn_transmitted)
  frameDesc.callbackArg = cast[pointer](vif)

proc mm_bcn_change*(param: pointer) {.exportc, cdecl.} =
  ## Apply a pending beacon template change.
  ## Blob algorithm:
  ##   a5 = &mm_bcn_env
  ##   a4 = *(u32*)(mm_bcn_env+4)        ; pending bcn-tx count
  ##   *(u32*)(mm_bcn_env+0) = param     ; stash new template ptr
  ##   if a4 != 0:
  ##     *(u8*)(mm_bcn_env+10) = 1       ; defer until in-flight TX settles
  ##     return
  ##   tail-call mm_bcn_update(param)    ; apply now
  ## Prior Nim bug: tail-called mm_bcn_transmit(0) which kicks a beacon
  ## transmit for vif 0 regardless of the new template pointer — the actual
  ## HW-descriptor rewrite lives in mm_bcn_update.
  let env = bcnEnvView()
  let pending = env.pendingCount
  env.templatePtr = param
  if pending != 0:
    env.deferredChange = 1
    return
  discard mm_bcn_update(param)

proc mm_ap_probe_cfm*(param: pointer) {.exportc, cdecl.} =
  ## Station-side AP keep-alive probe confirm.
  ## Blob algorithm:
  ##   a5 = 0x00800000         ; lui 0x800 => 0x00800000 (tx-OK bit in status)
  ##   a1 = tx_status & a5     ; was a probe-resp ACK observed?
  ##   if a1 != 0:             ; AP answered -> clear the "probe pending" flag
  ##     *(u8*)(vif+116) = 0
  ##     return
  ##   a1 = 16                 ; "beacon loss" reason code
  ##   tail-call mm_send_connection_loss_ind(a0=vif, a1=16)
  ## Prior Nim bug: masked bit 11 (0x800) and called txl_frame_send_null_frame.
  ## That caused:
  ##   - wrong decision (used bit 11 of tx_status, not bit 23)
  ##   - no host notification on AP-disappeared (the real purpose)
  ##   - instead it re-transmitted a null-frame, hiding the connection loss.
  var txStatus: uint32
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", txStatus, ") );"].}
  let vif = vifChannelAt(param)
  if (txStatus and 0x00800000'u32) != 0:
    # Probe got ACKed: AP is still reachable.
    vif.probeCount = 0
    return
  # No ACK -> report connection loss with reason code 16.
  mm_send_connection_loss_ind(vif.vifIdx, 16'u16)

proc mm_bcn_transmitted*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Callback invoked after beacon transmission completes (40 instrs).
  ## From blob: loads mm_bcn_env base (s0), checks [4] (pending count).
  ## If pending == 0, calls assert_rec("mm_bcn.c", "mm_bcn.c", 478).
  ## Decrements pending count. If count reaches 0:
  ##   Checks [10] (deferred beacon change flag). If set, calls
  ##   mm_bcn_transmitted(mm_bcn_env[0]) to process the deferred change.
  ##   Then loops: checks [12] (TIM update queue CoList). While non-empty,
  ##   calls co_list_pop_front, then ke_msg_send(popped_entry + 12) to
  ##   re-send deferred TIM update messages.
  let env = bcnEnvView()
  let pending = env.pendingCount
  if pending == 0:
    # Blob uses assert_err (not assert_rec).
    assert_err("mm_bcn.c", "mm_bcn.c", 478)
  # Decrement pending count
  let newPending = pending - 1
  env.pendingCount = newPending
  if newPending != 0:
    return
  # Pending count reached 0: check deferred beacon change flag at [10]
  if env.deferredChange != 0:
    # Process deferred beacon change (blob: mm_bcn_update, NOT mm_bcn_transmitted)
    discard mm_bcn_update(env.templatePtr)
  # Process TIM update queue at bcnEnvBase+12 (CoList)
  let timQueue = addr env.timQueue
  while timQueue.first != nil:
    let popped = co_list_pop_front(timQueue)
    if popped == nil:
      break
    # Process deferred TIM update (blob: mm_tim_update_proceed, NOT ke_msg_send)
    mm_tim_update_proceed(keMsgPayload(cast[ptr KeMsgHdr](popped)))

proc mm_bcn_update*(vifEntry: pointer): pointer {.exportc, cdecl, noinline.} =
  ## Update beacon content and TX descriptor after beacon change (~105 instrs, 338b).
  ## Blob (mm_bcn.o): memcpy beacon content to pool, me_beacon_check, descriptor setup,
  ## conditional mm_bcn_transmit, tail-call ke_msg_free.
  ## Calls: memcpy, ke_msg_send_basic, me_beacon_check, mm_bcn_transmit, ke_msg_free.
  ## noinline: blob calls this from mm_bcn_change (gap target).
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let bcnReq = beaconChangeReqAt(vifEntry)
  let bcnFrameLen = bcnReq.frameLen  # blob: lhu a2,4(a0)
  let vifIdx = bcnReq.vifIdx         # blob: lbu s0,9(a0)

  # Copy beacon frame content to pool (blob: memcpy(txl_bcn_pool+0x15c, vifEntry+12, len))
  let poolBase = cast[uint](addr txl_bcn_pool[0])
  discard c_memcpy(cast[pointer](poolBase + 0x15C),
                   cast[pointer](addr bcnReq.frameData[0]), bcnFrameLen.csize_t)

  # Clear mm_bcn_env defer flag, set active flag
  let env = bcnEnvView()
  env.deferredChange = 0
  env.active = 1

  # Send notification: ke_msg_send_basic(46=MM_BCN_CHANGE_CFM, src_id, 0)
  let templatePtr = env.templatePtr
  let msgHdr = keMsgHdrFromPayload(cast[pointer](templatePtr))
  ke_msg_send_basic(46, msgHdr.srcId, 0'u8)

  # Recompute VIF from vifIdx (blob uses multiply: vifIdx * 1512)
  let vif = vifChannelForIdx(vifIdx)

  # Read entry metrics
  let beaconChangeReq = beaconChangeReqAt(templatePtr)
  let entryFrameLen = beaconChangeReq.frameLen       # lhu a5,4(templatePtr)
  let entryFlagByte = beaconChangeReq.flagByte       # lbu s5,8(templatePtr)
  let entryHdrLen = beaconChangeReq.headerLen        # lhu s6,6(templatePtr)
  let bodyLen = entryFrameLen - entryFlagByte.uint16           # sub s5,a5,s5
  let hdrLenPlus3 = entryHdrLen + 3                            # addi s6,s6,3

  # Get TX descriptor from VIF
  let txDescPtr = vif.beaconTxDesc                 # lw s0,208(s2)
  let txDesc = hostTxHwDescAt(txDescPtr)
  let staType = vif.vifIdx                         # lbu a0,87(s2)
  let beaconPayloadStart = txDesc.payloadStart      # lw s8,20(s0) = baseOff

  # Store body length to VIF entry
  vif.beaconBodyLength = bodyLen                    # sh s5,316(s2)

  # Call me_beacon_check(vifIdx, entryFrameLen_as_ptr, txDesc[20]_as_ptr)
  # blob: a0=staType(=vifIdx), a1=entryFrameLen, a2=txDesc[20]
  me_beacon_check(staType, cast[pointer](entryFrameLen.uint), cast[pointer](beaconPayloadStart.uint))

  # Update TX descriptors
  let endDesc = beaconEndDesc()
  let adjLen = beaconPayloadStart + (entryHdrLen - 1).uint32
  txDesc.payloadEnd = adjLen                         # sw adjLen, 24(s0)
  let endLen = entryFlagByte.uint32 + 1
  let endAddr = adjLen + endLen
  endDesc.payloadStart = endAddr                     # sw endAddr, txl_bcn_end_desc+8
  let remainLen = bodyLen.uint32 + endAddr - entryHdrLen.uint32 - 1 + 1
  # blob: not(hdrLen) = ~hdrLen, then add to bodyLen+endAddr
  let notHdr = (not entryHdrLen).uint32
  let totalEnd = notHdr + bodyLen.uint32 + endAddr + 1
  endDesc.payloadEnd = totalEnd                      # sw totalEnd, txl_bcn_end_desc+12
  endDesc.status = 0                                 # sw zero, txl_bcn_end_desc+16

  # Read TSF from MAC HW register
  let tsfLo = regRead(0x24B000A0'u)
  let tsfByte = (tsfLo and 0xFF).uint8

  # Set up txl_buffer_control_24G
  let bufCtrl24G = txBufferControl24G()
  txDesc.chainedThd = cast[pointer](bufCtrl24G)       # sw bufCtrl, 40(s0) = policy table ptr
  bufCtrl24G.txPower = tsfByte.int32                  # sw tsfByte, 36(bufCtrl)

  # Set up TIM descriptor pointer and clear fields
  let timDescBase = cast[uint](addr txl_tim_desc[0])
  txDesc.retryLimitControl = 0                      # sw zero, 36(s0)
  txDesc.controlFlags = 0                             # sw zero, 60(s0)
  txDesc.status = timDescBase.uint32                  # sw timDesc, 16(s0)

  # Set beacon enabled flag
  vif.beaconEnabled = 1                               # sb 1, 326(s2)

  # Load TIM bitmap control byte from beacon frame (blob: th.lrbu a5, s8, s6)
  # s8 = txDesc base (beacon buffer), s6 = hdrLenPlus3 = entryHdrLen + 3
  let timByte = cast[ptr uint8](beaconPayloadStart + hdrLenPlus3.uint)[]
  timIeAt(addr txl_tim_ie_pool[0]).dtimPeriod = timByte # txl_tim_ie_pool[3]

  # Clear mm_bcn_env active flag
  env.active = 0

  # Conditional mm_bcn_transmit if mm_bcn_env[8] != 0
  if env.transmitRequested != 0:
    mm_bcn_transmit(vifIdx)

  # Clear entry pointer (blob: sw zero, mm_bcn_env[0] at 0x144)
  env.templatePtr = nil

  # Tail-call ke_msg_free to free the original message header.
  ke_msg_free(msgHdr)
  return nil

proc mm_bcn_transmit*(vifIdx: uint8) {.exportc, cdecl.} =
  ## Trigger beacon transmission for AP-mode VIFs (149 instructions).
  ##
  ## Walks the VIF linked list (vif_info_tab). For each VIF that is in AP mode
  ## (type == 2), has beacons enabled (offset 326 != 0), and has matching
  ## bcn_tx_next == bcn_tx_last (offsets 324 == 325), it:
  ##   1. Computes beacon length from offsets 316 + 318 + 4
  ##   2. Writes length to the TX descriptor (offset 208 -> [28])
  ##   3. Increments the sequence number (txl_cntrl_env offset 84)
  ##   4. Copies the TIM update byte and updates the beacon countdown
  ##   5. Calls mm_ap_probe_cfm(vif, vif+96) to confirm probe response
  ##   6. Calls mm_bcn_update(vif) to update beacon content
  ##   7. If update succeeds, allocates a TIM update frame via
  ##      txl_frame_get(56) and pushes it via txl_cntrl_push_int(4, frame)
  ##   8. After TX, checks STA info via sta_info_tab for PS state changes
  ##
  ## Blob register map:
  ##   s0 = current VIF entry ptr (linked list walk via [0])
  ##   s9 = mm_bcn_env ptr  s5 = VIF_TYPE_AP (2)  s6 = -1 (0xFF)
  ##   s3 = txl_cntrl_env  s2 = txl cntrl byte addr  s1 = bcn_env field
  ##   s7 = sta_info_tab  s8 = STA_ENTRY_SIZE (368)  s10 = sta HW index

  let env = bcnEnvView()

  # Blob checks: if mm_bcn_env[4] != 0, call assert_rec (line 701)
  # Then checks mm_bcn_env[9] (defer flag); if set, sets mm_bcn_env[8]=1 and returns

  # Get VIF list head from vif_mgmt (s0 = first VIF in linked list)
  # Blob: auipc s0; lw s0,[s0] -- loads the first used VIF pointer
  # The VIF entries form a linked list via offset 0 (next pointer).

  # Blob entry 0x2e: if mm_bcn_env[4] (TIM update queue head != NULL) then
  # emit assert_err("...", 701) — indicates a lingering queued TIM update
  # from the previous beacon. Falls through regardless; purely diagnostic.
  if env.pendingCount != 0:
    assert_err("mm_bcn.c", "mm_bcn.c", 701)

  # Iterate through VIF entries checking type == AP.
  for entryVifIdx in 0'u8 ..< 2'u8:
    let vif = vifChannelForIdx(entryVifIdx)
    let vifType = vif.vifType

    if vifType != VIF_TYPE_AP:
      continue

    # Check beacon enabled (offset 326)
    let bcnEnabled = vif.beaconEnabled
    if bcnEnabled == 0:
      continue

    # Check bcn_tx_next == bcn_tx_last (offsets 325, 324)
    if vif.beaconCountdown != vif.beaconDivisor:
      continue

    # Compute beacon frame length: offsets 316 (u16) + 318 (u16) + 4
    let bcnLen1 = vif.beaconBodyLength
    let bcnLen2 = vif.timLength
    let totalLen = bcnLen1.uint32 + bcnLen2.uint32 + 4

    # Write length to TX descriptor: vif[208] -> desc, desc[28] = totalLen
    let txDescPtr = vif.beaconTxDesc
    if txDescPtr != nil:
      hostTxHwDescAt(txDescPtr).frameLen = totalLen

    discard nextTxSeqNumber()

    # Copy TIM update byte (vif+327) into bcn_env field (s1+2)
    # Blob: lbu a5,327(s0); sb a5,2(s1)
    let timUpdate = vif.timCountdown
    mmBcnTemplateByte(2) = timUpdate

    # Read TIM/beacon flags (vif+330) and update TIM bitmap control byte
    # Blob: lbu a3,330(s0); beqz a5,L40 (timUpdate==0 path)
    let timFlags = vif.timFlags

    # Build TIM control byte
    # Blob: reads txl_cntrl byte (s2), conditionally sets bit 0
    # L40 path (timUpdate != 0): check TIM flag bit 1
    # Normal path (timUpdate == 0): check any TIM flag -> set bit 0
    let txCtrlBytePtr = cast[ptr uint8](txControlEnv())
    var txCtrlByte = txCtrlBytePtr[]
    if timUpdate != 0:
      # TIM update pending: conditionally set multicast bit
      if (timFlags and 2) != 0:
        txCtrlByte = txCtrlByte or 1
      else:
        txCtrlByte = txCtrlByte and 0xFE'u8
    else:
      if timFlags != 0:
        txCtrlByte = txCtrlByte or 1
      else:
        txCtrlByte = txCtrlByte and 0xFE'u8

    # Swap bcn_env[3] into vif+327 (TIM bitmap control swap)
    # Blob: lbu a4,3(s1); sb a4,327(s0)
    let bcnEnvSwap = mmBcnTemplateByte(3)
    vif.timCountdown = bcnEnvSwap

    # L43: set bit 0 in control byte and store
    # Blob: ori a5,a5,1; sb a5,0(s2)
    txCtrlByte = txCtrlByte or 1
    txCtrlBytePtr[] = txCtrlByte

    # Check vif+327 (new TIM byte) and decrement beacon countdown
    # Blob: lbu a5,327(s0); mv a0,s0; mv a1,s4
    let newTimByte = vif.timCountdown
    vif.timCountdown = newTimByte - 1

    # Update TX power for beacon frame (blob: tpc_update_frame_tx_power at 0x128)
    let descForTpc = vif.beaconTxDesc
    if descForTpc != nil:
      tpc_update_frame_tx_power(cast[pointer](vif), descForTpc)

    # Check if on operational channel (blob: chan_is_on_operational_channel at 0x132)
    # a0 is blob's s0 = current VIF entry pointer, not vif_idx.
    let onOpChan = chan_is_on_operational_channel(cast[pointer](vif))
    if not onOpChan:
      continue  # skip this VIF if not on channel

    # Blob flow after chan_is_on_operational_channel succeeds:
    #   staHw = vif[87]
    #   msg = ke_msg_alloc(MM_PRIMARY_TBTT_IND=56, dest=TASK_BAM(9),
    #                      src=TASK_MM(0), paramLen=3)
    #   msg[0] = (staHw + 5) & 0xFF
    #   msg[1] = 0; msg[2] = 0
    #   ke_msg_send(msg)
    #   vif[143] = vif[87]
    #   vif[145] = 0xFF
    #   txl_frame_push(vif + 96, 4)  # vif+96 is the pre-allocated bcn frame
    #   if push succeeded: mm_bcn_env[4] += 1
    #
    # Previous Nim had three wrongs here:
    #   (a) invented mm_ap_probe_cfm + mm_bcn_update calls the blob never makes
    #   (b) called txl_frame_get(56) to alloc a fresh frame and pushed that,
    #       instead of pushing the pre-existing beacon frame at vif+96
    #   (c) ke_msg_alloc used TASK_API (dest) / paramLen=4, and stored vifIdx
    #       in msg[0] — blob uses TASK_BAM dest, paramLen=3, and stores the
    #       STA HW index + 5 in msg[0].
    let staHwIdx = vif.vifIdx
    let tbttMsg = cast[ptr MmPrimaryTbttIndPayload](
      ke_msg_alloc(MM_PRIMARY_TBTT_IND, TASK_BAM, TASK_MM,
                   MmPrimaryTbttIndPayloadSize))
    if tbttMsg != nil:
      tbttMsg.staIdx = (staHwIdx + 5) and 0xFF
      ke_msg_send(tbttMsg)

    # Store sta info in the preallocated beacon frame descriptor.
    let bcnDesc = vifApBeaconFrameDesc(vif)
    bcnDesc.vifIdx = staHwIdx
    bcnDesc.staInfoIdx = 0xFF'u8

    # Push pre-existing beacon frame at vif+96 with AC=4 (beacon queue).
    # Blob at 0x184 checks the return value via `beqz a0, .L45`, so the
    # pending-count bump and postponed-frame flush happen only when
    # txl_frame_push returns non-zero. Nim's txl_frame_push is declared
    # void; capture a0 after the call via inline asm to preserve the
    # semantics.
    let bcnFrame = cast[pointer](bcnDesc)
    txl_frame_push(bcnFrame, 4)
    var pushResult: uint32
    {.emit: ["asm volatile(\"mv %0, a0\" : \"=r\"(", pushResult, ") );"].}
    if pushResult != 0:
      env.pendingCount = env.pendingCount + 1
      # Blob .L45 tail: look up the "staHw+5" entry in sta_info_tab and if
      # its BA flags (staEntry[73]) bit 1 is set, mark sta[48] = 9 and flush
      # postponed frames, then clear sta[48]. Previous Nim dropped this whole
      # block, which meant postponed frames queued for the AP's BCMC station
      # were never kicked out after a beacon TX.
      let bcnSta = staInfoForIdx(cast[uint8](staHwIdx.uint + 5'u))
      let staEntryU = cast[uint](bcnSta)
      let baFlags = bcnSta.trafficFlags
      if (baFlags and 2) != 0:
        bcnSta.psStatus = 9
        discard sta_mgmt_send_postponed_frame(cast[pointer](vif),
          cast[pointer](staEntryU), 0'u32)
        bcnSta.psStatus = 0

proc mm_tim_update*(msgBody: pointer) {.exportc, cdecl, noinline.} =
  ## Update TIM (Traffic Indication Map) in beacon (10 instrs).
  ## From blob: a0 is a pointer to the message body (msg payload).
  ## Checks mm_bcn_env+4 (pending beacon). If non-zero, subtracts 12 from a0
  ## to get the ke_msg header and tail-calls co_list_push_back on the TIM
  ## update queue at mm_bcn_env+12. If zero, tail-calls mm_tim_update_proceed.
  ## noinline: blob calls this from mm_tim_update_req_handler (gap target).
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let env = bcnEnvView()
  if env.pendingCount != 0:
    # Queue TIM update for deferred beacon processing
    let msgHdr = cast[ptr CoListHdr](keMsgHdrFromPayload(msgBody))
    co_list_push_back(addr env.timQueue, msgHdr)
  else:
    # No pending beacon, apply immediately (blob tail-calls mm_tim_update_proceed)
    mm_tim_update_proceed(msgBody)

# MM Timer operations
#
# MM timer entry layout (from blob disassembly):
#   offset 0:  ptr CoListHdr.next  (linked list link)
#   offset 4:  ptr callback        (function pointer: proc(env: pointer) {.cdecl.})
#   offset 8:  ptr env             (context pointer passed to callback)
#   offset 12: uint32 time         (absolute MAC HW timestamp for expiry)

proc cmp_mm_timer_time*(a, b: ptr CoListHdr): bool {.cdecl.} =
  ## Comparator for mm_timer sorted insert: returns true when a.time < b.time
  ## (unsigned comparison with wrap-around handling, same pattern as cmp_abs_time).
  ## From blob: compares offset 12 (time field) of each entry.
  let ta = mmTimerAt(a).expiry
  let tb = mmTimerAt(b).expiry
  let diff = ta - tb
  # Timer a should be inserted before b if diff wraps (a is earlier)
  return diff >= 0x80000000'u32

proc mm_timer_init*() {.exportc, cdecl.} =
  ## Initialize MM timer subsystem.
  ## From blob (4 instrs): loads address of mm_timer_list, tail-calls co_list_init.
  co_list_init(addr mm_timer_list)

proc mm_timer_set*(timer: pointer, targetTime: uint32) {.exportc, cdecl.} =
  ## Set an MM-level timer with absolute target time.
  ## From blob (76 instrs): reads MAC HW timestamp. If targetTime is in the past,
  ## clamps to current_time + 3000 (0xBB8). Removes timer from list if present
  ## (pop_front if head, else co_list_extract). Stores target time at timer[12].
  ## Sorted-inserts into mm_timer_list. If timer becomes head, calls mm_timer_schedule.
  ## If time already expired, tail-calls ke_evt_set for immediate processing.
  let macTime = regRead(MACHW_TIMLO_REG)
  var expiry = targetTime
  nimFwTrace2U32("[WIFI-NIMFW] mm_timer_set in ", macTime, targetTime)
  let diff = cast[int32](targetTime - macTime)
  if diff < 0:
    # Timer already past: clamp to now + 3000 ticks (~3ms)
    expiry = macTime + 0xBB8'u32

  let timerView = mmTimerAt(timer)
  let timerHdr = timerView.mmTimerHdr
  var wasFirst = false
  let first = mm_timer_list.first
  if first == timerHdr:
    # Timer is currently the head -- pop it
    discard co_list_pop_front(addr mm_timer_list)
    wasFirst = true
  else:
    # Try to extract from middle of list
    co_list_extract(addr mm_timer_list, timerHdr)

  timerView.expiry = expiry
  nimFwTrace2U32("[WIFI-NIMFW] mm_timer_set timer ", cast[uint32](cast[uint](timer)), expiry)

  # Sorted insert by time
  co_list_insert(addr mm_timer_list, timerHdr, cmp_mm_timer_time)

  # If timer is now first (or was first), program HW timer (blob: mm_timer_hw_set)
  if wasFirst or (mm_timer_list.first == timerHdr):
    mm_timer_hw_set(cast[pointer](mm_timer_list.first))

  # Check if already expired -- trigger immediate processing
  let macTime2 = regRead(MACHW_TIMLO_REG)
  let remaining = cast[int32](expiry - macTime2)
  if remaining < 0:
    ke_evt_set(KE_EVT_MM_TIMER)  # blob uses lui a0, 0x40000 = 0x40000000

proc mm_timer_clear*(timer: pointer) {.exportc, cdecl.} =
  ## Clear an MM-level timer.
  ## From blob (22 instrs):
  ##   if (timer == list.first):
  ##       co_list_pop_front(&list)
  ##       mm_timer_hw_set(list.first)        ; direct HW reprogramming
  ##   else:
  ##       co_list_extract(&list, timer)
  ## The blob tail-calls mm_timer_hw_set (NOT mm_timer_schedule) with the new
  ## list head after popping.
  let timerHdr = mmTimerAt(timer).mmTimerHdr
  let first = mm_timer_list.first
  if timerHdr == first:
    # Timer is head: pop and reprogram HW with the new head (may be nil).
    discard co_list_pop_front(addr mm_timer_list)
    mm_timer_hw_set(cast[pointer](mm_timer_list.first))
  else:
    # Timer is not head: just extract
    co_list_extract(addr mm_timer_list, timerHdr)

proc mmTimerExpired(node: ptr CoListHdr): bool {.inline.} =
  node != nil and
    cast[int32](mmTimerAt(node).expiry - regRead(MACHW_TIMLO_REG)) - 50 < 0

proc mm_timer_schedule*() {.exportc, cdecl.} =
  ## Schedule MM timers -- process all expired timers.
  ## From blob (64 instrs): loop: clear pending timer event. Load list head.
  ## If null, disable abs timer and return. Check head.time vs MAC HW time;
  ## if not expired (diff >= -50), program abs timer and return.
  ## If expired, pop head, call callback(env), repeat.
  var drained = 0'u32

  while drained < WifiTimerDrainLimit:
    # Clear pending MM timer event at start of each iteration
    # (blob: lui a0, 0x40000 -> call function; this acknowledges/clears the
    #  timer interrupt so we can re-arm it)
    ke_evt_clear(KE_EVT_MM_TIMER)

    let head = mm_timer_list.first
    if head == nil:
      # No timers pending -- disable abs timer (blob: mm_timer_hw_set(nil))
      mm_timer_hw_set(nil)
      return

    # Check if head timer has expired
    let headTimer = mmTimerAt(head)
    let expiry = headTimer.expiry
    let macTime = regRead(MACHW_TIMLO_REG)
    let diff = cast[int32](expiry - macTime) - 50  # blob: addi a5, a5, -50

    if diff >= 0:
      # Not expired yet -- program abs timer (blob: mm_timer_hw_set(head))
      mm_timer_hw_set(cast[pointer](head))
      # Blob re-reads MAC time and checks if timer expired between check and
      # programming. If yes, fall through to pop/process; if no, return.
      let macTime2 = regRead(MACHW_TIMLO_REG)
      let diff2 = cast[int32](expiry - macTime2)
      if diff2 >= 0:
        return
      # Expired between check and programming -- fall through to process

    # Timer expired: pop from list
    discard co_list_pop_front(addr mm_timer_list)

    # Get callback and env from timer entry
    let mmTimerCallback = headTimer.callback
    let mmTimerEnv = cast[pointer](headTimer.env)
    if mmTimerCallback == nil:
      # No callback: assert (blob: assert_err "mm_timer.c" line 223)
      assert_err("mm_timer.c", "mm_timer.c", 223)
    # Call callback(env) -- blob reloads and calls unconditionally after assert
    let invokeMmTimerCallback = cast[proc(env: pointer) {.cdecl.}](mmTimerCallback)
    invokeMmTimerCallback(mmTimerEnv)
    inc drained

  let nextTimerNode = mm_timer_list.first
  if nextTimerNode != nil:
    let nextTimer = mmTimerAt(nextTimerNode)
    nimFwDbgMmTimerYieldHead = nextTimer.expiry
    if mmTimerExpired(nextTimerNode):
      inc nimFwDbgMmTimerYield
      ke_evt_set(KE_EVT_MM_TIMER)
    else:
      mm_timer_hw_set(cast[pointer](nextTimerNode))
  else:
    mm_timer_hw_set(nil)

# ###########################################################################
#                     CHANNEL MANAGEMENT (chan_*)
# ###########################################################################

proc chan_init*() {.exportc, cdecl.} =
  ## Initialize channel management module.
  ## From disassembly: memset(chan_env, 0, 132), then iterates over 5 channel
  ## context slots (28 bytes each) in chan_ctxt_pool:
  ##   - memset each to 0
  ##   - Store 0xFF at offsets 14 and 23 (invalid channel index markers)
  ##   - For slots 0..2: call co_list_push_back to add to free list
  ##   - For slot 3: zero out scan-related half-word and byte
  ## After the loop, stores callback/data pointers into chan_env (from blob
  ## disassembly of chan_init at offsets 0x78-0xa8):
  ##   offset 48: chan_tbtt_switch_evt
  ##   offset 64: chan_cde_evt
  ##   offset 68: .LANCHOR2 (data anchor — chan_env itself's later-slot addr)
  ##   offset 80: chan_ctxt_op_evt
  ##   offset 96: chan_conn_less_delay_evt
  let env = chanEnvView()
  discard c_memset(env, 0, sizeof(ChanEnvView).csize_t)
  let poolBase = cast[uint](addr chan_ctxt_pool[0])
  for chanCtxtPoolIndex in 0 ..< 5:
    let ctxt = chanCtxtAt(poolBase + chanCtxtPoolIndex.uint * sizeof(ChanCtxtView).uint)
    discard c_memset(cast[pointer](ctxt), 0, sizeof(ChanCtxtView).csize_t)
    # Store 0xFF at offset 14 and 23 (invalid channel context index)
    ctxt.markInvalid()
    # For slots 0..2, push to the channel context free list
    if chanCtxtPoolIndex <= 2:
      co_list_push_back(addr env.freeList, ctxt.chanCtxtHdr)
  # Store callback function pointers — ORDER MATTERS (earlier Nim versions
  # had these mis-wired, routing HW events to the wrong handlers).
  env.tbttSwitchCallback = cast[pointer](chan_tbtt_switch_evt)
  env.cdeCallback = cast[pointer](chan_cde_evt)
  # Blob stores .LANCHOR2 here — a data anchor pointing at a later chan_env
  # slot used as a self-reference. Mirror with a pointer to chan_env+128.
  env.cdeArg = cast[pointer](addr env.deferredMsg)
  env.ctxtOpCallback = cast[pointer](chan_ctxt_op_evt)
  env.connLessDelayCallback = cast[pointer](chan_conn_less_delay_evt)
  # Reset convenience state variables
  chanCtxtCount = 0
  chanCtxtFlags = 0
  chanCurrentCtxt = nil
  chanPendingCtxt = nil
  chanConflictCount = 0
  chanConflictDetected = false
  chanScanPending = false

proc chan_ctxt_add*(param: pointer, ctxtIdxOut: ptr uint8): uint8 {.exportc, cdecl.} =
  ## Add channel context. Search existing for match, else allocate from free list.
  ## From disassembly (68 instrs).
  let env = chanEnvView()
  let poolBase = cast[uint](addr chan_ctxt_pool[0])
  for existingChannelContextIndex in 0'u8 ..< 3:
    let ctxt = chanCtxtAt(poolBase + existingChannelContextIndex.uint * sizeof(ChanCtxtView).uint)
    if ctxt.contextIndexOrMarker != 0xFF:
      if c_memcmp(addr ctxt.channel, param, 8.csize_t) == 0:
        ctxtIdxOut[] = existingChannelContextIndex
        return 0
  let freeCtxt = co_list_pop_front(addr env.freeList)
  if freeCtxt == nil:
    return 1
  let ctxt = chanCtxtAt(cast[pointer](freeCtxt))
  let chanCtxtPoolIndex =
    ((cast[uint](ctxt) - poolBase) div sizeof(ChanCtxtView).uint).uint8
  ctxt.contextIndexOrMarker = chanCtxtPoolIndex
  ctxtIdxOut[] = chanCtxtPoolIndex
  ctxt.channel = cast[ptr ChanCtxtDefView](param)[]
  return 0

proc chan_ctxt_del*(ctxtIdx: uint8) {.exportc, cdecl.} =
  ## Delete a channel context (58 instrs in blob).
  ## Validates context is in use (offset 23 != 0xFF) and has no linked VIFs
  ## (offset 24 == 0). Extracts from scheduling list, clears with memset,
  ## restores 0xFF markers at offsets 14 and 23.
  let env = chanEnvView()
  let ctxt = chanCtxtForIdx(ctxtIdx)
  # Validate: context must be in use
  if ctxt.contextIndexOrMarker == 0xFF:
    # Blob uses assert_err for chan_ctxt_del invariants.
    assert_err("chan.c", "chan.c", 0xAD0)
  if ctxt.linkCount != 0:
    assert_err("chan.c", "chan.c", 0xAD2)
  # Push back to free list
  co_list_push_back(addr env.freeList, ctxt.chanCtxtHdr)
  # Clear the context with memset
  discard c_memset(cast[pointer](ctxt), 0, sizeof(ChanCtxtView).csize_t)
  # Restore invalid markers at the computed slot
  ctxt.markInvalid()

proc chan_ctxt_link*(ctxtIdx: uint8, vifIdx: uint8) {.exportc, cdecl.} =
  ## Link a channel context to a VIF (83 instrs).
  ## Computes channel context slot = chan_ctxt_pool + ctxtIdx*28,
  ## computes VIF entry = vif_info_tab + vifIdx*1512.
  ## Asserts VIF's current channel ctx (vif+64) is null.
  ## Asserts slot's context-index/marker byte (slot+23) != 0xFF (slot in use).
  ## Stores slot pointer into VIF's channel ctx (vif+64).
  ## Adds survey frequency to chan_env accumulator (offset 108).
  ## Increments link count (slot+24). If link count becomes 1:
  ##   sets slot status to 1 (slot+22), increments chan_env context count (base+124),
  ##   calls chan_bcn_detect_start and chan_tbtt_insert for the VIF.
  ## Otherwise tail-calls chan_tbtt_insert.
  let env = chanEnvView()
  let ctxt = chanCtxtForIdx(ctxtIdx)
  let vif = vifChannelForIdx(vifIdx)
  # Assert VIF has no current channel context
  if vif.chanCtxt != nil:
    assert_err("chan.c", "chan.c", 0xAFE)
  # Assert slot is in use (context-index/marker byte != 0xFF)
  if ctxt.contextIndexOrMarker == 0xFF:
    assert_err("chan.c", "chan.c", 0xAFF)
  # Store slot pointer into VIF's channel context field
  vif.chanCtxt = cast[pointer](ctxt)
  # Add survey frequency to chan_env frequency accumulator at offset 108
  env.slotPeriod = env.slotPeriod + 0xC800'u32 # +51200 per blob
  # Increment link count at slot+24
  var linkCount = ctxt.linkCount
  linkCount = linkCount + 1
  ctxt.linkCount = linkCount
  if linkCount == 1:
    # First link: set status to 1, increment context count
    ctxt.status = 1
    var ctxtCnt = env.ctxtCount
    ctxtCnt = ctxtCnt + 1
    env.ctxtCount = ctxtCnt
  # First link: add this context to the active context list (chan_env+8).
  if linkCount == 1:
    co_list_push_back(addr env.activeList, ctxt.chanCtxtHdr)
  # Trigger channel context update (blob: chan_ctxt_trigger at 0xe4)
  chan_ctxt_trigger(cast[pointer](ctxt))
  # Update TX power for new channel (blob: chan_update_tx_power at 0xfc)
  chan_update_tx_power(cast[pointer](ctxt))

proc chan_ctxt_unlink*(vifIdx: uint8) {.exportc, cdecl.} =
  ## Unlink channel context from VIF (110 instrs in blob).
  ## Extracts VIF's TBTT node from scheduling list, clears VIF-context link,
  ## decrements link count. If scan-linked, adjusts frequency accumulator.
  ## When link count reaches zero: extracts context from list, decrements
  ## context count, handles scheduled/pending context state transitions,
  ## calls chan_ctxt_del. Updates chan_env flags and timer state.
  ## Tail-calls chan_upd_ctxt_status.
  let vif = vifChannelForIdx(vifIdx)
  # Load channel context pointer from VIF offset 64
  let chanCtxtPtr = vif.chanCtxt
  if chanCtxtPtr == nil:
    # Blob emits assert_err here (line 2863 in chan.c); previous Nim used
    # assert_warn which maps to a different sink in the platform layer.
    assert_err("chan.c", "chan.c", 0xB2F)
    # Fall through (blob does not return here)
  let env = chanEnvView()
  # Extract VIF's TBTT node (vif+68) from chan_env scheduling list
  let tbttNode = chanTbttHdr(addr vif.tbttNode)
  co_list_extract(chanTbttPrimaryList(), tbttNode)
  # Clear VIF's link to channel context
  vif.tbttNode.state = 0
  vif.chanCtxt = nil
  let ctxt = chanCtxtAt(chanCtxtPtr)
  # Decrement context link count at offset 24
  var linkCount = ctxt.linkCount
  linkCount = linkCount - 1
  ctxt.linkCount = linkCount
  # Check if context had scan link (offset 22)
  if ctxt.status != 0:
    # Subtract from survey frequency accumulator at chan_env + 108
    env.slotPeriod = env.slotPeriod + 0xFFFF3800'u32
    # Check link count again after scan adjustment
    if ctxt.linkCount == 0:
      # Extract context from active context list (chan_env+8)
      co_list_extract(addr env.activeList, ctxt.chanCtxtHdr)
      # Decrement context count
      var ctxtCount = env.ctxtCount
      ctxtCount = ctxtCount - 1
      env.ctxtCount = ctxtCount
      let schedCtxt = env.scheduledCtxt
      if schedCtxt == nil:
        # No scheduled context -- blob .L446 just clears ctxt[22] and falls
        # through to .L442 for the single chan_ctxt_del call. Previously
        # Nim wrote ctxt[22]=4 in the pendCtxt==chanCtxtPtr branch AND
        # called chan_ctxt_del here separately — that produced a duplicate
        # delete call and also stored the wrong status byte (the blob
        # always writes 0 at this point; the 4 Nim wrote was a stale
        # transcription error).
        ctxt.status = 0
      elif schedCtxt == chanCtxtPtr:
        # Was the scheduled context
        if ctxtCount > 1:
          # Multiple remaining: promote next context to scheduled
          let nextCtxt = env.activeList.first
          env.scheduledCtxt = cast[pointer](nextCtxt)
        elif ctxtCount <= 1:
          # Single or none: trigger channel CDE event (blob: chan_cde_evt at 0xc8)
          chan_cde_evt()
        ctxt.status = 0
      else:
        ctxt.status = 0
  # Check link count for deletion (both scan-linked and non-scan-linked paths)
  if ctxt.linkCount == 0:
    chan_ctxt_del(ctxt.contextIndexOrMarker)
  # Update chan_env flags: clear bit 7
  let remCtxtCnt = env.ctxtCount
  env.flags = env.flags and 0x7F
  if remCtxtCnt == 1:
    # Clear timer targets when only 1 context remains
    chanEnvTimerTarget = 0
    env.timerState = 0
    if env.slotPeriod != 0:
      env.slotPeriod = 0
  # Post-unlink operations (blob: chan_tbtt_schedule + chan_update_tx_power + mm_timer_clear + chan_ctxt_op_evt)
  chan_tbtt_schedule(nil)
  chan_update_tx_power(chanCtxtPtr)
  mm_timer_clear(chanTbttSwitchTimer())
  chan_ctxt_op_evt()

proc chan_ctxt_update*(param: pointer) {.exportc, cdecl.} =
  ## Update a channel context with new parameters (57 instrs).
  ## From blob: a0 = ke_msg payload (MM_CHAN_CTXT_UPDATE_REQ).
  ## payload[0] = channel context index. Computes ctxt entry = chan_ctxt_pool + idx*28.
  ## Copies 10 bytes of channel params from payload+2 to ctxt+4.
  ## If this context is the current active one (chan_env+32 == ctxt), calls
  ## irqSave, chan_send_scanning_stop, hal_machw_set_channel(0), irqRestore.
  ## Then reads channel params and calls phy_set_channel with them.
  ## Writes MAC HW bandwidth register (0x24B000DC) to 496 (0x1F0).
  ## Stores ctxt at chan_env+32, sets ke_evt KE_EVT_KE_MESSAGE, tail-calls
  ## chan_upd_ctxt_status.
  let req = cast[ptr MmChanCtxtUpdatePayload](param)
  let ctxtIdx = req.ctxtIdx
  let env = chanEnvView()
  let ctxt = chanCtxtForIdx(ctxtIdx)
  # Copy 10 bytes of channel parameters from payload+2 to ctxt+4
  discard c_memcpy(addr ctxt.channel, addr req.band,
    sizeof(ChanCtxtDefView).csize_t)
  # Check if this is the currently active context
  let currentCtxt = env.currentCtxt
  let thisCtxt = cast[pointer](ctxt)
  if currentCtxt == thisCtxt:
    # Active context being updated: re-apply channel settings
    let saved = irqSave()
    chan_send_scanning_stop(cast[pointer](env))
    # RX timer + RX control reset before PHY change (blob: rxl_timer_int_handler + rxl_cntrl_evt)
    rxl_timer_int_handler()
    rxl_cntrl_evt()
    # Apply PHY channel settings (blob: phy_set_channel at 0x74)
    phySetChannel(addr ctxt.channel)
    irqRestore(saved)
  # Store context as current
  env.currentCtxt = thisCtxt
  # Update TX power for new channel (blob: tpc_update_tx_power at 0x92)
  tpc_update_tx_power(ctxt.channel.txPower)

proc chan_ctxt_trigger*(ctxt: pointer) {.exportc, cdecl.} =
  ## Trigger a channel context switch (21 instrs).
  ## Blob: a0 = channel context pointer (not index).
  ##   if a0 == 0: return
  ##   if (chan_env[120] & 0x0C) != 0: return
  ##   if chan_env[124] == 1: tail-call chan_switch_start(a0)
  ##   else: stack byte = 0; chan_cde_evt(&byte); return
  if ctxt == nil:
    return
  let env = chanEnvView()
  let chanFlags = env.flags
  if (chanFlags and 0x0C) != 0:
    return
  let ctxtCount = env.ctxtCount
  if ctxtCount == 1:
    chan_switch_start(ctxt)
  else:
    var zeroFlag {.noinit.}: uint8
    zeroFlag = 0
    # Blob passes &zeroFlag via a0 to chan_cde_evt (which reads *a0 as state).
    let zfAddr = cast[uint](addr zeroFlag)
    {.emit: ["asm volatile(\"mv a0, %0\" : : \"r\"(", zfAddr, ") : \"a0\");"].}
    chan_cde_evt()

proc chan_ctxt_cnt*(): uint8 {.exportc, cdecl, noinline.} =
  ## Return the number of active channel contexts.
  return chanEnvView().ctxtCount

proc chan_ctxt_set_auth_assoc_req*(msg: pointer) {.exportc, cdecl, noinline.} =
  ## Park the deferred auth/assoc message for the next channel activation.
  ## From blob (3 instrs): stores a0 at chan_env+0x80 and returns.
  chanEnvView().deferredMsg = msg

proc chan_ctxt_get_remaining_time_ms*(vifEntry: pointer): uint32 {.exportc, cdecl.} =
  ## Get remaining time in ms for the current channel context (30 instrs in blob).
  ## Asserts if vifEntry is NULL. Calls
  ## chan_is_on_operational_channel; if it returns false, returns 0. Otherwise
  ## reads MACHW_TIMLO timestamp and computes (chan_env[0x58] - mactime) / 1000.
  if vifEntry == nil:
    assert_err("chan.c", "chan.c", 0xD21)
  if not chan_is_on_operational_channel(vifEntry):
    return 0
  let macTime = regRead(MACHW_TIMLO_REG)
  return (chanEnvView().remainingTimeTarget - macTime) div 1000

proc chan_ctxt_use_dominant_chan*(): bool {.exportc, cdecl.} =
  ## Check if we should use the dominant channel (8 instrs in blob).
  ## Blob: call chan_get_dominant_chan(); snez a0,a0; ret
  return chan_get_dominant_chan() != nil

proc chan_is_on_channel*(vifEntry: pointer): bool {.exportc, cdecl, noinline.} =
  ## Check if VIF is currently on its operating channel.
  ## From blob (14 instrs): a0 is actually a VIF entry pointer (not index).
  ## Loads current channel context from chan_env global. If null, returns false.
  ## If ctxt status <= 2, compares vif[64] (vif's chan_ctxt) with current ctxt.
  ## If status > 2, compares ctxt[25] with vif[87].
  ## noinline: blob calls this from chan_is_tx_allowed (gap target).
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let currentCtxt = chanEnvView().currentCtxt  # chan_env current context
  if currentCtxt == nil:
    return false
  let ctxt = chanCtxtAt(currentCtxt)
  let contextIndexOrMarker = ctxt.contextIndexOrMarker
  let vif = vifChannelAt(vifEntry)
  if contextIndexOrMarker <= 2:
    return vif.chanCtxt == currentCtxt
  else:
    return ctxt.altIdx == vif.vifIdx

proc chan_is_on_operational_channel*(vifEntry: pointer): bool {.exportc, cdecl, noinline.} =
  ## Check whether the VIF's chan_ctxt == the currently active chan_ctxt.
  ## Blob ABI (11 instrs): a0 = vifEntry pointer; dereferences vif+64 to compare
  ## against chan_env[32] (current ctxt). Returns true iff ctxt status <= 2 and
  ## matches. Previous Nim signature declared `vifIdx: uint8`, which truncated
  ## the incoming pointer to a byte and then treated that byte as a pointer
  ## (undefined behaviour for any caller passing a real vifEntry).
  let currentCtxt = chanEnvView().currentCtxt
  if currentCtxt == nil:
    return false
  let ctxt = chanCtxtAt(currentCtxt)
  if ctxt.contextIndexOrMarker > 2:
    return false
  return vifChannelAt(vifEntry).chanCtxt == currentCtxt

proc chan_is_tx_allowed*(vifEntry: pointer): bool {.exportc, cdecl.} =
  ## Check if TX is allowed on current channel (16 instrs in blob).
  ## From blob: first calls chan_is_on_channel(vif). If false, return false.
  ## Then loads chan_env+36 (scheduled-context ptr). If null, the blob falls
  ## through returning the prior true a0. If a switch is scheduled, loads
  ## chan_env+32 (current ctxt) and returns (ctxt[22] == 6). Note offset 22
  ## in blob = chan-op state byte.
  if not chan_is_on_channel(vifEntry):
    return false
  let env = chanEnvView()
  let schedCtxt = env.scheduledCtxt
  if schedCtxt == nil:
    return true
  let curCtxt = env.currentCtxt
  return chanCtxtAt(curCtxt).status == 6

proc chanScanDurationTicks(req: ptr ChanScanReqPayload): uint16 {.inline.} =
  (req.duration shr 10).uint16

template chanScanChannel(req: ptr ChanScanReqPayload): ptr ChanCtxtDefView =
  cast[ptr ChanCtxtDefView](addr req.band)

proc chan_scan_req*(param: pointer) {.exportc, cdecl.} =
  ## Request channel scan (65 instrs in blob).
  ## Blob keeps scan context state in chan_ctxt_pool, not chan_env.
  ## Start requests set up the scan context and tail-call
  ## chan_conn_less_delay_prog. Abort requests clear the scan timer and run
  ## chan_ctxt_op_evt.
  let scanReq = cast[ptr ChanScanReqPayload](param)
  let reqType = scanReq.reqType
  nimFwTrace2U32("[WIFI-NIMFW] chan_scan_req ", reqType.uint32, encodedArgU32(param))
  if reqType != 0 and reqType != 1:
    return
  let env = chanEnvView()
  if reqType == 0:
    let scan = chanScanPoolOverlay()
    if scan.slot != 0xFF:
      assert_err("chan.c", "chan.c", 0x9E5)
    scan.slot = 3
    scan.vifIdx = 0xFF
    scan.requestVifIdx = scanReq.vifIdx
    scan.active = 1
    nimFwTrace2U32("[WIFI-NIMFW] chan_scan_req duration ",
                   scan.requestVifIdx.uint32, scanReq.duration)
    scan.durationTicks = chanScanDurationTicks(scanReq)
    discard c_memcpy(addr scan.channel, chanScanChannel(scanReq),
                     sizeof(ChanCtxtDefView).csize_t)
    nimFwDbgChanScanChanMeta = packChannelMeta(addr scan.channel)
    nimFwDbgChanScanChanFreq = packChannelFreq(addr scan.channel)
    nimFwTrace2U32("[WIFI-NIMFW] chan_scan_req channel ",
                   scan.channel.band.uint32,
                   scan.channel.primFreq.uint32)
    let chanFlags = env.flags
    env.flags = chanFlags or 0x02
    nimFwTrace2U32("[WIFI-NIMFW] chan_scan_req flags ", chanFlags.uint32, env.flags.uint32)
    chanScanPending = true
    chan_conn_less_delay_prog()
    return
  mm_timer_clear(chanCtxtOpTimer())
  chan_ctxt_op_evt()

proc chan_roc_req*(param: pointer) {.exportc, cdecl, noinline.} =
  ## Request remain-on-channel (54 instrs).
  ## noinline: blob calls this from mm_remain_on_channel_req_handler.
  ## From blob: param[0] = VIF count byte. If non-zero, decrements and returns
  ## (count != 0 ? 1 : 0). If zero, checks chan_env ROC slot (offset 135)
  ## for 0xFF (free). If not free, returns 1. Otherwise:
  ##   - Sets ROC type at chan_env+134 (0x401 = 1025)
  ##   - Stores VIF index at chan_env+126
  ##   - Computes duration = param[4] * 1000 >> 10, stores at chan_env+130
  ##   - Copies param[1] to chan_env+137 (band)
  ##   - Copies 10 bytes from param+8 to chan_env ROC channel descriptor
  ##   - Checks ROC VIF index (s0): if 0, sets flags |= 0x14, checks chan_env+36
  ##     for null and triggers chan_distribute_slots; else sets flags |= 1
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let req = cast[ptr ChanConnLessDelayReqPayload](param)
  let env = chanEnvView()
  if req.remainingCount != 0:
    let newCount = req.remainingCount - 1
    req.remainingCount = newCount
    return  # blob returns (newCount != 0) in a0
  let roc = chanRocOverlay()
  if roc.slot != 0xFF:
    return  # ROC slot busy, return 1
  # Setup ROC
  # rxu_cntrl_frame_handle reaches this helper from the non-associated
  # management-frame path with a1=0xFF in the blob.
  var vifIdx: uint8 = 0xFF
  roc.vifIdx = vifIdx
  roc.stateLo = 0x01
  roc.slot = 0x04
  # Duration: param[4] (ms) * 1000 >> 10
  let durationMs = req.durationMs
  let durationTicks = (durationMs * 1000) shr 10
  roc.durationTicks = durationTicks.uint16
  # Copy band
  let band = req.band
  roc.band = band
  # Copy 10-byte channel descriptor from param+8
  discard c_memcpy(addr roc.channel, addr req.chanDef[0], sizeof(ChanCtxtDefView).csize_t)
  # Set flags based on VIF index
  let chanFlags = env.flags
  if vifIdx == 0:
    env.flags = chanFlags or 0x14  # ROC + connless flags
    let schedCtxt = env.scheduledCtxt
    if schedCtxt == nil:
      chan_switch_start(cast[pointer](chanCtxtForIdx(4)))
  else:
    env.flags = chanFlags or 0x01  # ROC pending flag
    chan_conn_less_delay_prog()

proc chan_bcn_to_evt*() {.exportc, cdecl, noinline.} =
  ## Handle beacon timeout event for channel management.
  ## noinline: blob's vif_mgmt_bcn_to_evt tail-calls this as a real function.
  ## The blob function itself is empty (just ret), but the call must be preserved.
  asm "nop"  # prevent GCC from dead-code-eliminating the call site

proc chan_bcn_detect_start*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Start beacon detection for a VIF. Reads VIF's channel context pointer
  ## (offset 64), checks flags, allocates ke_msg with beacon interval info.
  ## From disassembly (68 instrs).
  let vif = vifChannelAt(vifEntry)
  let chanCtxtPtr = vif.chanCtxt
  if chanCtxtPtr == nil:
    assert_err("chan.c", "chan.c", 0xC5E)
    return
  let env = chanEnvView()
  let chanFlags = env.flags
  if (chanFlags and 0x40) != 0:
    return
  let ctxtCount = env.ctxtCount
  if ctxtCount < 2:
    return
  let param = cast[ptr ChanConnLessDelayReqPayload](
    ke_msg_alloc(0x34, 0, 0, ChanConnLessDelayReqPayloadSize))
  if param == nil:
    return
  param.remainingCount = 0
  let bcnInfo = vif.vifIdx
  param.band = bcnInfo
  let tsfLow = staInfoForIdx(bcnInfo).initialRateConfig
  let bcnIntervalUs = (tsfLow + 0xFFFFEC78'u32) div 1000
  param.durationMs = bcnIntervalUs
  let chanCtxt = chanCtxtAt(chanCtxtPtr)
  discard c_memcpy(addr param.chanDef[0],
                   addr chanCtxt.channel,
                   param.chanDef.len.csize_t)
  ke_msg_send(param)
  env.flags = env.flags or 0x40

proc chan_tbtt_switch_update*(vifEntry: pointer, tbttTime: uint32) {.exportc, cdecl.} =
  ## Update TBTT switch scheduling (36 instrs in blob).
  ## Reads channel context from vifEntry+64, checks status byte at ctxt+22.
  ## If no context or status==0, returns. Computes TBTT target offset based
  ## on whether multiple contexts are active (9000 us for multi, 3000 for single).
  ## Updates vifEntry+72 with new target. If multiple contexts: clears vifEntry+78,
  ## calls co_list_extract on chan_env list, then tail-calls chan_tbtt_insert.
  let vif = vifChannelAt(vifEntry)
  let chanCtxtPtr = vif.chanCtxt
  if chanCtxtPtr == nil:
    return
  let chanCtxt = chanCtxtAt(chanCtxtPtr)
  if chanCtxt.status == 0:
    return
  let ctxtCount = chanEnvView().ctxtCount
  # Select timing offset: 9000 us for multi-context, 3000 us for single
  var tbttLeadTimeUs: uint32
  if ctxtCount > 1:
    tbttLeadTimeUs = 9000'u32   # 0x2328
  else:
    tbttLeadTimeUs = 3000'u32   # 0xBB8
  let tbttTarget = tbttTime - tbttLeadTimeUs
  let tbttNode = addr vif.tbttNode
  # Check if already set to this value
  let curTarget = tbttNode.targetTime
  if curTarget == tbttTarget:
    return
  # Store new TBTT target
  tbttNode.targetTime = tbttTarget
  # Only do list operations if multiple contexts
  if ctxtCount <= 1:
    return
  # Clear scheduling state and re-insert into TBTT list
  tbttNode.state = 0
  co_list_extract(chanTbttPrimaryList(), chanTbttHdr(tbttNode))
  chan_tbtt_schedule(cast[pointer](tbttNode))  # blob: chan_tbtt_schedule (not chan_tbtt_insert)

proc chan_update_tx_power*(ctxt: pointer) {.exportc, cdecl.} =
  ## Update TX power for the current channel (30 instrs).
  ## From blob: a0 = channel context pointer. Checks ctxt[24] (TX power valid).
  ## If zero, returns. Loads chan_env base, checks if a0 matches chan_env[64]
  ## (first VIF chan ctxt). If match, compares ctxt power limits (offset 89,90)
  ## via sign-extend-byte (sext.b), takes minimum, stores back.
  ## Then checks chan_env second VIF (offset 628), same comparison.
  ## Updates chan_env power field with min of both.
  let ctxtView = chanCtxtAt(ctxt)
  if ctxtView.linkCount == 0:
    return
  # Check VIF 0's channel context.
  let vif0 = vifChannelForIdx(0)
  let vif0Ctxt = vif0.chanCtxt
  var minPower: int8 = 127  # start with max
  if ctxt == vif0Ctxt:
    let currentTxPower = vif0.txPower
    let maxTxPower = vif0.maxTxPower
    if currentTxPower < maxTxPower:
      minPower = currentTxPower
    else:
      minPower = maxTxPower
  # Check VIF 1's channel context.
  let vif1 = vifChannelForIdx(1)
  let vif1Ctxt = vif1.chanCtxt
  if ctxt == vif1Ctxt:
    let currentTxPower = vif1.txPower
    let maxTxPower = vif1.maxTxPower
    var effectiveTxPower: int8
    if currentTxPower < maxTxPower:
      effectiveTxPower = currentTxPower
    else:
      effectiveTxPower = maxTxPower
    if effectiveTxPower < minPower:
      minPower = effectiveTxPower
  # Store the minimum power back to the context
  if minPower != 127:
    ctxtView.channel.txPower = cast[uint8](minPower)

proc chan_tbtt_switch_evt*() {.exportc, cdecl.} =
  ## TBTT switch event handler (69 instrs, callback stored in chan_env during chan_init).
  ## Called as timer callback with (a0 = scheduling list VIF TBTT node).
  ## Assembly trace:
  ##   s0 = chan_env base
  ##   s3 = macTimeNow() (from MACHW_TIMLO_REG)
  ##   s1 = chan_env+36 (scheduled context pointer)
  ##   checks ctxtCnt (chan_env+124) > 1, else returns
  ##   a3 = node->byte[8] (VIF index), calls chan_is_on_channel(vifIdx)
  ##   if not on channel AND not scheduled ctx: returns
  ##   checks chan_env flags (offset 120) bit 2|3 for conflict, returns if set
  ##   checks chan_env+32 (pending ctx): if nil or == s1, continues; else returns
  ##   clears node->byte[9] = 0 (priority)
  ##   adjusts pending ctx TBTT half-word at offset 18 by elapsed time
  ##   clamps scheduled ctx half-word at offset 20 (max 20)
  ##   stores macTime at chan_env+112
  ##   sets node->byte[10] = 2 (status = switching)
  ##   if chan_env+36 == nil: tail-calls chan_pre_switch_channel(s1)
  ##
  ## NOTE: This is a timer callback. The blob stores the TBTT node pointer
  ## as the callback's env parameter. Since we register this as a bare callback,
  ## the env param arrives in a0 via the mm_timer dispatch.
  ## We receive it via inline asm since Nim signature has no params.
  var tbttNode {.noinit.}: pointer
  {.emit: ["asm volatile(\"mv %0, a0\" : \"=r\"(", tbttNode, ") );"].}

  let env = chanEnvView()
  let macTime = macTimeNow()
  let ctxtCnt = env.ctxtCount
  if ctxtCnt <= 1:
    return
  let node = chanTbttNodeAt(tbttNode)
  let vifIdx = node.vifIdx
  # Look up VIF's current chan ctxt (vif[64]) via vif_info_tab[vifIdx]
  let vif = vifChannelForIdx(vifIdx)
  let vifChanCtxt = vif.chanCtxt
  # Blob: s1 = vifChanCtxt (vif[64]); a0 = chan_get_dominant_chan().
  # Proceed iff a0 == NULL OR a0 == s1. Otherwise return.
  let dominant = chan_get_dominant_chan()
  if dominant != nil and dominant != vifChanCtxt:
    return
  # Check chan_env flags for conflict (bits 2|3)
  let chanFlags = env.flags
  if (chanFlags and 0x0C) != 0:
    return
  # Blob 0x54: a5 = chan_env[36] (scheduled ctxt list head). If non-null and
  # != vifChanCtxt, return. If null, fall through.
  let schedList = env.scheduledCtxt
  if schedList != nil and schedList != vifChanCtxt:
    return
  # Clear priority byte at node[9]
  node.priority = 0
  # Adjust timing for current/pending ctxt (chan_env+32)
  let pendCtxt = env.currentCtxt
  if pendCtxt != nil:
    let pend = chanCtxtAt(pendCtxt)
    let oldOffset = env.lastMacTime
    let elapsed = macTime - oldOffset
    var remain: uint32
    if elapsed < pend.opSlot.uint32:
      remain = pend.opSlot.uint32 - elapsed
    else:
      remain = 0
    pend.opSlot = remain.uint16
  # Clamp vif ctxt's remaining half-word (offset 20)
  let vifCtxt = chanCtxtAt(vifChanCtxt)
  var toSub = vifCtxt.tbttSlot.uint32
  if toSub > 20:
    toSub = 20
  vifCtxt.tbttSlot = vifCtxt.tbttSlot - toSub.uint16
  # Store current time as new base
  env.lastMacTime = macTime
  # Set status = 2 (switching) at node[10]
  node.state = 2
  # If scheduled list still empty: tail-call chan_switch_start(vifChanCtxt)
  if env.scheduledCtxt == nil:
    chan_switch_start(vifChanCtxt)

proc chan_pre_switch_channel*(ctxt: pointer) {.exportc, cdecl.} =
  ## Pre-switch channel context (176 instrs).
  ## From blob: initiates channel switch. Clears the pre-switch timer first.
  ## Checks chan_env flags (offset 120) bit 5: if set, clears it.
  ## Checks flags bit 3 (scan active): if set, loads ROC context.
  ## Checks flags bit 2 (connless): if set, loads connless context.
  ## If neither, checks chan_env+124 (ctxt count): if count > 1, allocates
  ## stack variable and calls hal_machw_set_channel equivalent.
  ## If count == 1 and matches chan_env+8 (first ctxt), uses that.
  ## Then: if scheduled ctxt exists, reads channel params from ctxt+4..12
  ## (band, type, primFreq, centerFreq1, centerFreq2), calls phy_set_channel.
  ## Reads ctxt+12 (TX power) and calls tpc_update. Writes 496 (0x1F0) to
  ## MACHW+0xDC. Clears chan_env pending (offset where current ctxt is stored).
  ## Stores ctxt at chan_env+32 (current). Calls chan_upd_ctxt_status.
  ## If ctxt type (ctxt+23) == 3 or 4, sets HW state bits.
  ## If type <= 2, walks VIF list checking for matching channel context.
  let env = chanEnvView()
  mm_timer_clear(chanCtxtOpTimer())
  # Check and clear bit 5 in flags
  var chanFlags = env.flags
  if (chanFlags and 0x20) != 0:
    chanFlags = chanFlags and (not 0x20'u8)
    env.flags = chanFlags
  # Determine which context to switch to
  var targetCtxt: pointer = nil
  chanFlags = env.flags
  let schedCtxt = env.scheduledCtxt
  if (chanFlags and 0x08) != 0:
    targetCtxt = cast[pointer](chanCtxtForIdx(3))
    # Mark scheduled context status=1 if it exists
    if schedCtxt != nil:
      chanCtxtAt(schedCtxt).status = 1
    env.scheduledCtxt = targetCtxt
  elif (chanFlags and 0x04) != 0:
    targetCtxt = cast[pointer](chanCtxtForIdx(4))
    if schedCtxt != nil:
      chanCtxtAt(schedCtxt).status = 1
    env.scheduledCtxt = targetCtxt
  else:
    if schedCtxt == nil:
      # No scheduled context; check context count
      let ctxtCount = env.ctxtCount
      if ctxtCount > 1:
        # Blob: stack byte = 1; chan_cde_evt(&byte).  The CDE-event handler
        # populates chan_env[+36] (scheduled ctxt) as a side effect; after
        # the call we fall through and re-read that slot below.
        var stackByte {.noinit.}: uint8
        stackByte = 1
        let sbAddr = cast[uint](addr stackByte)
        {.emit: ["asm volatile(\"mv a0, %0\" : : \"r\"(", sbAddr, ") : \"a0\");"].}
        chan_cde_evt()
      elif ctxtCount == 1:
        targetCtxt = cast[pointer](env.activeList.first)
        env.scheduledCtxt = targetCtxt
      else:
        return
    else:
      targetCtxt = schedCtxt
    # .L216: re-load the scheduled context slot (chan_cde_evt may have written it).
    if targetCtxt == nil:
      targetCtxt = env.scheduledCtxt
  if targetCtxt == nil:
    return
  let ctxt = chanCtxtAt(targetCtxt)
  nimFwDbgChanPreChanMeta = packChannelMeta(addr ctxt.channel)
  nimFwDbgChanPreChanFreq = packChannelFreq(addr ctxt.channel)
  # Drain pending RX descriptors before retuning the PHY; vendor does this on
  # scan channel switches so received beacons/probe responses reach RXU.
  rxl_timer_int_handler()
  rxl_cntrl_evt()
  # .LBB497/.LBE497: Call phy_set_channel with extracted params
  # a5=0, a0..a4 = band,chanType,primFreq,centerFreq1,centerFreq2
  phySetChannel(addr ctxt.channel)

  # Call tpc_update with TX power from context offset 12
  tpc_update_tx_power(ctxt.channel.txPower)

  # Write MAC HW BW register: 0x1F0 -> MACHW+0xDC
  regWrite(MACHW_BASE + 0x0DC'u, 0x1F0'u32)
  # Clear pending context, store as current
  env.scheduledCtxt = nil
  env.currentCtxt = targetCtxt
  # Call chan_upd_ctxt_status to finalize
  chan_upd_ctxt_status(targetCtxt, 4)
  # Check context type for additional handling
  let contextIndexOrMarker = ctxt.contextIndexOrMarker
  if contextIndexOrMarker == 3:
    # .L219 -> .L232 -> .L233: scan type clears MAC scan state, queues the
    # scan-channel start indication, disables PM for the connectionless slot,
    # then reactivates the MAC before the queued indication is dispatched.
    regWrite(MACHW_BASE + 0x220'u, 0'u32)
    ke_msg_send_basic(75, 1, 255)
    let saved = irqSave()
    let ps = psEnvView()
    ps.statusFlags = ps.statusFlags or 0x02'u32
    irqRestore(saved)
    let ccaBusy = regRead(MACHW_BASE + 0x4C'u)
    env.surveySnapshot = (ccaBusy and 0xFF).uint8
    rfPhyTraceCheckpoint(0x45'u32)
    rfPriPrepareWb03MacActiveScanState()
    rfPhyTraceCheckpoint(0x46'u32)
    blmac_pwr_mgt_setf(0)
    rfPhyTraceCheckpoint(0x47'u32)
    mm_active()
    rfPhyTraceCheckpoint(0x48'u32)
  elif contextIndexOrMarker == 4:
    # .L232: ROC type -- IRQ-safe flag set + schedule survey
    let saved = irqSave()
    let ps = psEnvView()
    ps.statusFlags = ps.statusFlags or 0x02'u32
    irqRestore(saved)
    # Read MACHW CCA busy and store survey snapshot
    let ccaBusy = regRead(MACHW_BASE + 0x4C'u)
    env.surveySnapshot = (ccaBusy and 0xFF).uint8
    # Blob 0x130: blmac_pwr_mgt_setf(0) to disable power-save during ROC
    blmac_pwr_mgt_setf(0)
    mm_active()
    waitRfUs(1000'u32)
  elif contextIndexOrMarker <= 2:
    let ps = psEnvView()
    if ps.enabled == 0 or (ps.statusFlags and 8'u32) != 0:
      # Blob .L221: leave PS mode before notifying associated STA VIFs on the
      # active VIF list. The list head is vif_mgmt_env+8, not chan_env.
      blmac_pwr_mgt_setf(0)
      let curCtxt = env.currentCtxt
      var vif2 = cast[pointer](vifMgmtEnvView().activeList.first)
      while vif2 != nil:
        let vif = vifChannelAt(vif2)
        if cast[uint](vif.chanCtxt) == cast[uint](curCtxt):
          if vif.vifType == 0:
            let vifAssoc = vif.state
            if vifAssoc != 0:
              if co_list_cnt(addr txFrameEnv().freeList) > 1'u32:
                discard txl_frame_send_null_frame(vif.staIdx, nil, 0)
              else:
                inc nimFwDbgAutoNullSkipped
        vif2 = vif.next

    # Blob .L222/.L227: walk active VIFs again, mark TD state, release any
    # auth/assoc request deferred by chan_ctxt_set_auth_assoc_req, then flush
    # postponed frames for that VIF.
    var vif3 = cast[pointer](vifMgmtEnvView().activeList.first)
    while vif3 != nil:
      let vif = vifChannelAt(vif3)
      if cast[uint](vif.chanCtxt) == cast[uint](targetCtxt):
        let tdIndex = vif.vifIdx.int * (sizeof(TdEntryView) div sizeof(uint32))
        tdEntryAt(addr td_env[tdIndex]).endActive = 1
        if vif.vifType == 0:
          # Blob 0x1de-0x1f0: send the deferred SM_CONNECT_AUTH_ASSOC_REQ
          # message parked by chan_ctxt_set_auth_assoc_req, then clear it.
          let pendingMsg = env.deferredMsg
          if pendingMsg != nil:
            ke_msg_send(pendingMsg)
            env.deferredMsg = nil
        # Send postponed frames (blob passes vif entry pointer as a0)
        vif_mgmt_send_postponed_frame(vif3)
      vif3 = vif.next
    mm_active()

proc chan_conn_less_delay_evt*() {.exportc, cdecl.} =
  ## Connectionless delay event handler (52 instrs, callback stored in chan_env).
  ## From blob: checks chan_env flags (offset 120):
  ##   bit 0 set: if bit 2 also set, assert_rec; else clear bit 0, set bit 2,
  ##     tail-call chan_distribute_slots, then check chan_env+36 for pre-switch.
  ##   bit 1 set: if bit 3 also set, assert_rec; else clear bit 1, set bit 3,
  ##     tail-call chan_distribute_slots, then check chan_env+36 for pre-switch.
  ##   Neither: return.
  let env = chanEnvView()
  var flags = env.flags
  # Blob uses a single shared chan_switch_start tail site with the
  # slotArg differing per branch. Use a switchArg variable + single
  # conditional tail call.
  var switchArg: pointer = nil
  if (flags and 0x01) != 0:
    if (flags and 0x04) != 0:
      assert_err("chan.c", "chan.c", 874)
    flags = flags and (not 0x01'u8)
    flags = flags or 0x04
    env.flags = flags
    if env.scheduledCtxt == nil:
      switchArg = cast[pointer](chanCtxtForIdx(4))
  elif (flags and 0x02) != 0:
    if (flags and 0x08) != 0:
      assert_err("chan.c", "chan.c", 888)
    flags = flags and (not 0x02'u8)
    flags = flags or 0x08
    env.flags = flags
    if env.scheduledCtxt == nil:
      switchArg = cast[pointer](chanCtxtForIdx(3))
  if switchArg != nil:
    chan_switch_start(switchArg)

proc chan_cde_evt*() {.exportc, cdecl.} =
  ## Channel distribution event handler (212 bytes in blob, 73 instrs).
  ## Called as timer callback with a0 = channel context pointer.
  ## From blob: reads macTime from MACHW, checks ctxtCnt > 1.
  ## State 0: call mm_timer_set with chan_env delay + macTime.
  ## State 1: check flags bits 2-3, if chan_env[116]==0: set flag + schedule,
  ##   else: store macTime + distribute + pre-switch.
  ## State 2: check scheduled ctx, copy status bytes, tail-call pre-switch.
  var ctxtPtr {.noinit.}: pointer
  {.emit: ["asm volatile(\"mv %0, a0\" : \"=r\"(", ctxtPtr, ") );"].}

  let env = chanEnvView()
  let macTime = regRead(MACHW_BASE + 0x120)
  let ctxtCnt = env.ctxtCount
  if ctxtCnt <= 1:
    return
  let ctxtAddr = cast[uint](ctxtPtr)
  let state = cast[ptr uint8](ctxtAddr)[]
  if state == 0:
    # State 0: schedule CDE timer with delay, tail-call chan_distribute_slots
    let delay = env.slotPeriod
    mm_timer_set(chanTbttSwitchTimer(), macTime + delay)
    chan_distribute_slots()
    return
  let adjState = state - 1
  if adjState <= 1:
    # State 1 or 2: check channel flags
    let chanFlags = env.flags
    if (chanFlags and 0x0C) != 0:
      return
    let existFlag = env.cdeStarted
    if existFlag == 0:
      # First entry: set flag, schedule timer
      env.cdeStarted = 1
      let delay = env.slotPeriod
      mm_timer_set(chanTbttSwitchTimer(), macTime + delay)
    else:
      # Re-entry: store macTime, distribute slots, get next channel
      env.lastMacTime = macTime
      chan_distribute_slots()
      let nextChan = chan_get_next_chan()
      # Fall through to state-2 check using nextChan
      if state == 2:
        let schedCtxt = env.scheduledCtxt
        if schedCtxt == nil:
          chan_switch_start(nextChan)
          return
        if schedCtxt == nextChan:
          return
        # Copy status from scheduled to new, mark scheduled as active(1)
        let oldStatus = chanCtxtAt(schedCtxt).status
        chanCtxtAt(nextChan).status = oldStatus
        chanCtxtAt(schedCtxt).status = 1
      env.scheduledCtxt = nextChan
    return
  # State >= 3: check scheduled context (unreachable per blob, adjState > 1 means state >= 3)
  discard

{.emit: "__attribute__((optimize(\"crossjumping\"))) void chan_ctxt_op_evt(void);".}
proc chan_ctxt_op_evt*() {.exportc, cdecl.} =
  ## Channel context operation event handler (468 bytes blob, ~147 instrs).
  ## Called as timer callback with a0 = channel context pointer.
  ## Blob call targets: chan_goto_idle_cb, chan_switch_start, chan_get_dominant_chan,
  ##   chan_get_next_chan, blmac_pwr_mgt_setf, ke_msg_send_basic,
  ##   chan_conn_less_delay_prog, chan_cde_evt, mm_force_idle_req, mm_back_to_host_idle.
  var ctxtPtr {.noinit.}: pointer
  {.emit: ["asm volatile(\"mv %0, a0\" : \"=r\"(", ctxtPtr, ") );"].}

  let env = chanEnvView()
  let ctxt = chanCtxtAt(ctxtPtr)
  let status = ctxt.status

  # status 0-1: return immediately
  if status <= 1:
    return

  # status 2-3: set flags bit 5, check ctxtCnt/scanPend, tail-call chan_goto_idle_cb
  if status == 2 or status == 3:
    env.flags = env.flags or 0x20
    let ctxtCnt = env.ctxtCount
    if ctxtCnt <= 1:
      return
    if env.switchPending != 0:
      return
    # Set status=2, clear chan_env[121,122], tail-call chan_goto_idle_cb
    ctxt.status = 2
    env.scanDelayCount = 0
    env.connlessDelayCount = 0
    chan_goto_idle_cb()
    return

  # status > 4: return
  if status != 4:
    return

  # status == 4: dispatch on the context-index/marker byte at ctxt[23]
  let contextIndexOrMarker = ctxt.contextIndexOrMarker

  if contextIndexOrMarker <= 2:
    # sub 0-2: Set status=1, then switch channel
    ctxt.status = 1
    let ctxtCnt = env.ctxtCount
    if ctxtCnt == 1:
      # Single context: tail-call chan_switch_start(chan_env[8])
      let firstCtxt = cast[pointer](env.activeList.first)
      chan_switch_start(firstCtxt)
      return
    if ctxtCnt >= 2:
      # Multiple contexts: adjust timing, get next/dominant, switch
      let macTime = regRead(MACHW_TIMLO_REG)
      let oldTime = env.lastMacTime
      let elapsed = macTime - oldTime
      var remain = ctxt.opSlot.uint32
      if elapsed < remain:
        remain = remain - elapsed
      else:
        remain = 0
      ctxt.opSlot = remain.uint16
      env.lastMacTime = macTime
      # Check if current == chan_env[8] and ctxtCnt==2
      if ctxtCnt == 2:
        let firstCtxt = cast[pointer](env.activeList.first)
        var nextChan: pointer
        if ctxtPtr == firstCtxt:
          # Current is first: get next from list
          nextChan = cast[ptr pointer](ctxtPtr)[]
        else:
          nextChan = firstCtxt
        # Blob issues a real call to chan_get_dominant_chan; force emission by
        # consuming the result through a volatile asm barrier.
        let dominant = chan_get_dominant_chan()
        {.emit: ["""__asm__ volatile("" : : "r"(""", dominant, """) : "memory");"""].}
        chan_switch_start(nextChan)
        return
      else:
        # >2 contexts: get next via chan_get_next_chan
        let nextChan = chan_get_next_chan()
        chan_switch_start(nextChan)
        return
    # ctxtCnt == 0: just switch to self
    chan_switch_start(ctxtPtr)
    return

  # Blob clears chan_env+0x20 (current context) for completed scan/ROC
  # context operations before retiring the context type. Without this, the
  # next scan reuses the scan context pointer and chan_switch_start can treat
  # the new channel as already current.
  env.currentCtxt = nil

  if contextIndexOrMarker == 3 or contextIndexOrMarker == 4:
    if contextIndexOrMarker == 4:
      # sub 4: clear bcn_detect flag (bit 6) if ctxt[14]==0
      if ctxt.invalidMarker == 0:
        env.flags = env.flags and not 0x40'u8
      # Clear conflict flag (bit 2)
      env.flags = env.flags and not 0x04'u8
    # sub 3 path (also reached from sub 4):
    if contextIndexOrMarker == 3:
      # Clear chan_env[120] bit 3
      env.flags = env.flags and not 0x08'u8
      # Set power management bit in MAC HW (blob: blmac_pwr_mgt_setf at 0x11e)
      blmac_pwr_mgt_setf(0)
      # Send ke_msg_send_basic(77, 1, 0xFF) = MM_CHAN_CTXT_SCHED_CFM
      ke_msg_send_basic(77, 1, 0xFF)
    # Common: set ctxt[23]=0xFF, clear chan_env[120] bit 4
    ctxt.contextIndexOrMarker = 0xFF
    let curFlags = env.flags
    env.flags = curFlags and not 0x10'u8
    # Check chan_env[120] bits 0-1 for conn_less
    if (curFlags and 0x03) != 0:
      chan_conn_less_delay_prog()
    # Check ctxtCnt for next action
    let finalCnt = env.ctxtCount
    if finalCnt == 1:
      # Single context: tail-call chan_switch_start(chan_env[8])
      let firstCtxt = cast[pointer](env.activeList.first)
      chan_switch_start(firstCtxt)
    return

  # sub > 4: call chan_cde_evt or mm_force_idle_req + mm_back_to_host_idle
  let ctxtCnt = env.ctxtCount
  if ctxtCnt < contextIndexOrMarker:
    # Blob: chan_cde_evt with a0 = &local (stack byte = 2)
    # chan_cde_evt grabs a0 via inline asm
    var cdeParam: uint8 = 2
    let cdeFn = cast[proc(p: pointer) {.cdecl.}](chan_cde_evt)
    cdeFn(cast[pointer](addr cdeParam))
  else:
    # Idle: call mm_force_idle_req then tail-call mm_back_to_host_idle
    mm_force_idle_req()
    mm_back_to_host_idle()

proc chan_survey_timer_end*() {.exportc, cdecl.} =
  ## Channel survey timer expiry handler (callback stored in chan_env during chan_init).
  discard

proc chan_distribute_slots*() {.exportc, cdecl.} =
  ## Distribute channel time slots across active contexts (196 instrs).
  ## From blob: walks the VIF list, accumulates slot durations per-context,
  ## handles scan credits, retry counter, and ROC/scan scheduling.
  ## Then walks VIFs again to program per-context slot durations.
  let env = chanEnvView()

  # Load scan pending flag and retry counter
  var scanPendingVal = env.freeList.first  # t4 in blob
  let retryByte = env.flags  # a1 in blob

  # Local accumulator for slot durations (3 bytes at sp+12..14)
  var slotAccum {.noinit.}: array[3, uint8]  # sp+12, sp+13, sp+14

  # Walk VIF list from chan_env+8 (linked list via offset 0)
  var vifPtr = cast[pointer](env.activeList.first)
  var activeCount: uint8 = 0  # a2 in blob
  var needsSwitch: uint8 = 0  # s4 in blob
  var needsScan: bool = false  # s0 in blob
  var accumA0: uint32 = 0  # a0: flag for retry counter update

  while vifPtr != nil:
    let vif = vifChannelAt(vifPtr)
    let chanCtxt = vif.chanCtxt
    if chanCtxt != nil:
      let ctxt = chanCtxtAt(chanCtxt)
      let baseContextSlotIndex = ctxt.contextIndexOrMarker
      activeCount += 1

      # Accumulate base slot: read ctxt+23 as index into slotAccum, increment by 2
      if baseContextSlotIndex < 3:
        slotAccum[baseContextSlotIndex] = slotAccum[baseContextSlotIndex] + 2

      let connlessFlag = vif.state

      # Check if this context is pending ROC
      if connlessFlag == 0:
        if scanPendingVal != nil:
          env.scanCtxt = chanCtxt

        # Accumulate additional slot: read ctxt+23 as index, increment by 8
        let rocContextSlotIndex = ctxt.contextIndexOrMarker
        if rocContextSlotIndex < 3:
          slotAccum[rocContextSlotIndex] = slotAccum[rocContextSlotIndex] + 8

        if not needsScan:
          accumA0 = 1
          needsScan = true
          needsSwitch = 1

      # Check STA type (vif+87): accumulate based on status
      let staType = vif.vifIdx
      let staStatus = staInfoForIdx(staType).psMode
      if (staStatus and 3) != 0:
        let stationPowerSaveContextSlotIndex = ctxt.contextIndexOrMarker
        if stationPowerSaveContextSlotIndex < 3:
          slotAccum[stationPowerSaveContextSlotIndex] =
            slotAccum[stationPowerSaveContextSlotIndex] + 1

      # Check VIF type at vif+86
      let vifType = vif.vifType
      if vifType == 0:
        # STA type: check vif+92 (half-word) scan credit
        let scanCredit = vif.listenInterval
        if scanCredit > 1:
          needsScan = true
        # Check chan_env+125 for scheduling state
        let schedState = env.schedState
        if schedState == 1:
          if connlessFlag == 0:
            let scheduledRocContextSlotIndex = ctxt.contextIndexOrMarker
            if scheduledRocContextSlotIndex < 3:
              slotAccum[scheduledRocContextSlotIndex] =
                slotAccum[scheduledRocContextSlotIndex] + 8
          env.schedState = 2
          needsSwitch = schedState
      elif vifType == 2:
        let apFlag = vif.apChanSwitchPending
        if apFlag != 0:
          vif.apChanSwitchPending = 0
          let apChannelSwitchContextSlotIndex = ctxt.contextIndexOrMarker
          if apChannelSwitchContextSlotIndex < 3:
            slotAccum[apChannelSwitchContextSlotIndex] =
              slotAccum[apChannelSwitchContextSlotIndex] + 6
        if not needsScan:
          accumA0 = 1
          needsScan = true
          needsSwitch = 1

    vifPtr = cast[ptr pointer](cast[uint](vifPtr))[]

  # After walk: update retry counter if needed
  if accumA0 != 0:
    env.flags = retryByte

  # Validate total duration against beacon interval / 0xC800
  let bcnInterval = env.slotPeriod
  let expectedSlots = bcnInterval div 0xC800'u32
  let slotSum = slotAccum[0].uint32 + slotAccum[1].uint32 + slotAccum[2].uint32
  if slotSum != expectedSlots:
    assert_warn("chan.c", "chan.c", 699)  # Blob: assert_warn not assert_rec

  # After VIF walk: check if dominant channel update is needed
  # Blob: if s4 != 0, tail-call chan_get_dominant_chan
  if needsSwitch != 0:
    let dominant = chan_get_dominant_chan()
    {.emit: ["""__asm__ volatile("" : : "r"(""", dominant, """) : "memory");"""].}
    return  # blob tail-calls chan_get_dominant_chan and returns
  # Blob: if retryByte > 0 and no switch needed, decrement retry counter
  if retryByte > 0:
    let retryVal = env.flags
    if retryVal > 0:
      env.flags = retryVal - 1

  # Compute final context info for second pass
  let chanCtxtCount = env.ctxtCount
  let chanSlotSigned = cast[int8](env.flags)
  # slti + addi: multiplier is 2 if negative, 1 if non-negative
  let multiplier: uint32 = if chanSlotSigned < 0: 2'u32 else: 1'u32
  let finalMul = multiplier * chanCtxtCount.uint32

  # Walk VIF list again to program slot durations
  vifPtr = cast[pointer](env.activeList.first)
  while vifPtr != nil:
    let vif = vifChannelAt(vifPtr)
    let chanCtxt = vif.chanCtxt
    if chanCtxt != nil:
      let ctxt = chanCtxtAt(chanCtxt)
      # Clear ctxt[16] and ctxt[20] (half-words)
      ctxt.schedSlot = 0
      ctxt.tbttSlot = 0

      if needsScan:
        let vifType = vif.vifType
        if vifType == 0:
          # STA type with scan credit > 1
          let scanCredit = vif.listenInterval
          if scanCredit > 1:
            # Slot = chanCtxtCount * 50 (from blob: mul a5,a5,a7 where a7=50)
            let scanCreditSlotDuration = env.ctxtCount.uint16 * 50
            ctxt.schedSlot = scanCreditSlotDuration
          else:
            # No scan credit: set to -1 (0xFFFF)
            ctxt.schedSlot = 0xFFFF'u16
        else:
          # Non-STA type: set to -1
          ctxt.schedSlot = 0xFFFF'u16
      else:
        # No scan needed: compute slot from context weight and multiplier
        let contextSlotWeight = ctxt.contextIndexOrMarker
        let weightedSlot = finalMul * contextSlotWeight.uint32 * 50
        # Divide by total slot sum with rounding
        let slotVal = if slotSum > 0: (weightedSlot + slotSum - 1) div slotSum
                      else: weightedSlot
        ctxt.schedSlot = slotVal.uint16

      # Copy ctxt[16] to ctxt[18] (blob: lhu a5,16(a3); sh a5,18(a3))
      ctxt.opSlot = ctxt.schedSlot

      # Compute TBTT slot at ctxt+20
      let vifType2 = vif.vifType
      var bcnInt: uint32
      if vifType2 == 0:
        # STA: get beacon interval from associated STA entry
        let staIdx = vif.staIdx
        bcnInt = staInfoForIdx(staIdx).initialRateConfig
      else:
        # AP: beacon interval from vif+322 << 10
        bcnInt = vif.apBeaconInterval.uint32 shl 10

      # TBTT count = chan_env[108] / bcnInt, clamped to 1 min
      let tbttCount = if bcnInt != 0: bcnInterval div bcnInt else: 1'u32
      let tbttFinal = if tbttCount == 0: 1'u32 else: tbttCount
      # TBTT slot = (tbttFinal & 0xFF) * 20
      ctxt.tbttSlot = ((tbttFinal and 0xFF) * 20).uint16

    vifPtr = cast[ptr pointer](cast[uint](vifPtr))[]

proc chan_tbtt_detect_conflict*(newTime: uint32, curTime: uint32): bool {.exportc, cdecl, noinline.} =
  ## Checks if two TBTT times are within 0x5000 (20480 us) wrapping window.
  ## Returns true if conflict detected.
  ## On conflict: sets chan_env flags. On no conflict: decrements counter.
  let env = chanEnvView()
  var isConflict = true
  let tdiff = cast[int32](newTime - curTime)
  if tdiff >= 0:
    let revDiff = cast[int32](curTime + 0x5000'u32 - newTime)
    if revDiff < 0:
      isConflict = false
  else:
    let revDiff2 = cast[int32](curTime - newTime)
    if revDiff2 < 0:
      isConflict = false
    else:
      let wrap = cast[int32](tdiff + 0x5000'i32)
      if wrap < 0:
        isConflict = false
  if isConflict:
    chanTbttConflictCounter()[] = 3
    if env.schedState == 0:
      env.schedState = 1
    env.flags = env.flags or 0x80
  else:
    let tbttConflictClearCountdown = chanTbttConflictCounter()[]
    if tbttConflictClearCountdown > 0:
      chanTbttConflictCounter()[] = tbttConflictClearCountdown - 1
      if tbttConflictClearCountdown - 1 == 0:
        env.flags = env.flags and 0x7F
  return isConflict

proc chan_tbtt_insert*(tbttNode: pointer) {.exportc, cdecl.} =
  ## Insert a TBTT node into the sorted scheduling list (372 bytes in blob, ~90 instrs).
  ## Two-phase algorithm matching blob (chan.o):
  ## Phase 1: walk chan_env+0x10 list finding insertion point & counting displacements.
  ## Phase 2: process displaced entries (extract, clear timers, re-queue to chan_env+0x18).
  ## Blob uses chan_tbtt_detect_conflict.isra.0 for wrapping time comparison.
  let node = chanTbttNodeAt(tbttNode)
  let tbttList = chanTbttPrimaryList()
  let reschedList = chanTbttReschedList()
  let timerEnv = chanTbttTimer()
  let nodeTime = node.targetTime
  let nodePrio = node.priority

  # Phase 1: Walk list to find insertion point, count displacements
  var scheduledTbttNode = cast[ptr CoListHdr](tbttList.first)
  var insertAfter: ptr CoListHdr = nil  # s4: node to insert after
  var displacedStart: ptr CoListHdr = nil  # s0: first entry to displace
  var displaceCount: uint8 = 0  # s2: number of entries to displace
  var needInsert: bool = false  # s1: whether to do insertion

  while scheduledTbttNode != nil:
    let scheduledTbtt = chanTbttNodeAt(cast[pointer](scheduledTbttNode))
    if scheduledTbtt == node:
      assert_err("chan.c", "chan.c", 1960)
    let scheduledTbttState = scheduledTbtt.state
    let scheduledTbttTime = scheduledTbtt.targetTime

    if scheduledTbttState == 2:
      # Type 2 (scheduled): direct time compare
      if nodeTime >= scheduledTbttTime:
        # Check conflict
        if not chan_tbtt_detect_conflict(nodeTime, scheduledTbttTime):
          # No conflict, insert before this entry
          insertAfter = scheduledTbttNode
      else:
        # nodeTime < scheduledTbttTime: displace this entry
        displacedStart = cast[ptr CoListHdr](tbttNode)
        displaceCount = 1
        needInsert = false  # will be set below
        break
    else:
      # Non-scheduled: use conflict detection
      if not chan_tbtt_detect_conflict(nodeTime, scheduledTbttTime):
        # No conflict: compare times for ordering
        if nodeTime < scheduledTbttTime:
          # Insert before scheduledTbttNode
          needInsert = true
          break
        insertAfter = scheduledTbttNode
      else:
        # Conflict: compare priorities
        let scheduledTbttPriority = scheduledTbtt.priority
        if scheduledTbttPriority < nodePrio:
          # Current has higher priority (lower value), stop here
          displacedStart = cast[ptr CoListHdr](tbttNode)
          displaceCount = 1
          break
        # Current lower priority: will be displaced
        displaceCount += 1
        if displacedStart == nil:
          displacedStart = scheduledTbttNode

    scheduledTbttNode = cast[ptr CoListHdr](scheduledTbttNode.next)

  if scheduledTbttNode == nil and not needInsert:
    needInsert = true

  # Phase 2: Re-insert displaced entries to resched queue
  var toProcess = displacedStart
  var remaining = displaceCount
  while remaining > 0:
    if toProcess == nil:
      assert_err("chan.c", "chan.c", 2033)
    let processNode = chanTbttNodeAt(cast[pointer](toProcess))
    if processNode != node:
      let pType = processNode.state
      if pType == 1:  # periodic type: clear timer
        mm_timer_clear(timerEnv)
        processNode.state = 0
      co_list_extract(tbttList, toProcess)
    co_list_push_back(reschedList, toProcess)
    toProcess = cast[ptr CoListHdr](toProcess.next)
    remaining -= 1

  # Insert newNode into list. Blob always routes through co_list_insert_after
  # (which itself falls back to push_front when refElem is NULL) — keeping the
  # single call site matches blob's call-graph and lets the inner helper pick
  # the right head/tail branch without us materialising an extra push_front.
  if needInsert:
    co_list_insert_after(tbttList,
                         cast[ptr CoListHdr](insertAfter),
                         cast[ptr CoListHdr](tbttNode))

proc chan_send_scanning_stop*(chanEnvPtr: pointer) {.exportc, cdecl.} =
  ## Send scanning stop notification.
  ## (Full implementation in separate batch.)
  discard

proc chan_upd_ctxt_status*(chanCtxtPtr: pointer, newStatus: uint8) {.exportc, cdecl.} =
  ## Update channel context status (54 instrs).
  ## From blob: a0 = chan ctxt entry pointer, a1 = new status.
  ## Reads MAC timestamp from MACHW_TIMLO_REG (0x24B00120).
  ## If new status == 2 (switching): checks context count. If count <= 1,
  ##   arms the context-op timer for now+0xFA0. If count > 1, adds 0xBB8.
  ## If new status == 4 (operating): reads ctxt[23] (type). If type > current
  ##   chan_env+124, checks chan_env ROC slot and VIF counts; may set status to 5.
  ##   Stores ctxt at chan_env+112 (timer base). May compute offset from VIF slots.
  ## Otherwise (status 3 or default): stores 0 remaining, sets status to 3.
  ## Writes status byte at ctxt+22 and arms/clears the context-op timer at
  ## chan_env+0x4c. The callback argument lives at chan_env+0x54.
  var status = newStatus
  let ctxt = chanCtxtAt(chanCtxtPtr)
  let macTime = regRead(MACHW_TIMLO_REG)
  let env = chanEnvView()
  var targetTime: uint32 = 0
  if status == 2:
    # Switching status: compute remaining time
    let ctxtCount = env.ctxtCount
    let extra = if ctxtCount <= 1: 0'u32 else: 0xBB8'u32
    targetTime = macTime + 0xFA0'u32 + extra
  elif status == 4:
    # Operating status: check context type
    if ctxt.contextIndexOrMarker <= 2:
      let ctxtCount = env.ctxtCount
      if ctxtCount > 1:
        if status.uint16 < ctxt.schedSlot:
          env.lastMacTime = macTime
          targetTime = macTime + (ctxt.schedSlot.uint32 shl 10)
        else:
          status = 5
      else:
        status = 5
    else:
      targetTime = macTime + (ctxt.opSlot.uint32 shl 10)
  else:
    status = 3
  # Write status byte
  ctxt.status = status
  if targetTime == 0:
    if status != 3:
      mm_timer_clear(chanCtxtOpTimer())
  else:
    mmTimerAt(chanCtxtOpTimer()).env = cast[uint32](cast[uint](chanCtxtPtr))
    mm_timer_set(chanCtxtOpTimer(), targetTime)

# ###########################################################################
#                     PHY / IE Helpers
# ###########################################################################

proc phy_channel_to_freq*(band: uint8, channel: uint8): uint16 {.weakExport, cdecl, noinline.} =
  ## noinline: blob calls this from me_extract_csa (gap target).
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  if band == 0:
    if channel < 1 or channel > 14: return 0xFFFF'u16
    if channel == 14: return 2484'u16
    return (2407'u16 + channel.uint16 * 5'u16)
  elif band == 1:
    if channel < 1 or channel > 165: return 0xFFFF'u16
    return (5000'u16 + channel.uint16 * 5'u16)
  return 0xFFFF'u16

proc phy_freq_to_channel*(band: uint8, freq: uint16): uint8 {.weakExport, cdecl.} =
  ## Convert frequency to channel number (from blob phy_freq_to_channel).
  ## band=0 -> 2.4GHz, band=1 -> 5GHz.
  if band == 0:
    # 2.4GHz: special case ch14 = 2484 MHz
    if freq == 2484: return 14
    let freqOffsetFromChannelOneMhz = freq.int - 2412
    if freqOffsetFromChannelOneMhz < 0 or freqOffsetFromChannelOneMhz > 72: return 0
    return ((freq.int - 2407) div 5).uint8
  elif band == 1:
    # 5GHz: channels start at 5000 MHz
    let freqOffsetFromFiveGhzBaseMhz = freq.int - 5000
    if freqOffsetFromFiveGhzBaseMhz < 0 or freqOffsetFromFiveGhzBaseMhz > 820: return 0
    return ((freq.int - 5000) div 5).uint8
  return 0

proc find_wpa_rsn_ie*(ieBuf: pointer, ieLen: uint32,
                       wpaOut: ptr pointer, rsnOut: ptr pointer) {.exportc, cdecl.} =
  let wpaOuiPtr = unsafeAddr WPA_OUI[0]
  wpaOut[] = mac_vsie_find(ieBuf, ieLen, cast[pointer](wpaOuiPtr), 4)
  rsnOut[] = mac_ie_find(ieBuf, ieLen, IE_ID_RSN)
