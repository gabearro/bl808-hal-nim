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
# Unlike the vendor's fatal assertions, these schedule recovery and return.
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
    return
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
    return
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
    return
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
  ## The archive compares the terminator too, so find(nil) succeeds.
  var currentNode = list.first
  while currentNode != elem:
    if currentNode == nil: return false
    currentNode = currentNode.next
  return true

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
    return
  if previousNode != nil and previousNode.next != elem:
    assert_err("co_list.c", "co_list.c", 361)
    return
  if elem == nil:
    assert_err("co_list.c", "co_list.c", 362)
    return
  if previousNode != nil:
    # Unlink: previousNode->next = elem->next
    previousNode.next = elem.next
    # If elem was the last element, update list.last to previousNode
    if list.last == elem:
      list.last = previousNode
  else:
    # elem is the first element — blob does NOT assert on list.first mismatch
    # here (only 3 asserts at lines 360/361/362); previous Nim added an
    # extra line-363 assert.
    # As with co_list_pop_front, removing the final head leaves last stale.
    list.first = elem.next
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
    return
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
    return
  if (elemSize and 3) != 0:
    assert_err("co_pool.c", "co_pool.c", 43)
    return
  # Blob does NOT zero-initialize the pool memory here — callers are
  # expected to populate elements as they allocate from the free list.
  # Previous Nim emitted a memset that wasn't in blob's call graph.
  let nodes = cast[ptr UncheckedArray[CoPoolNode]](nodeArray)
  let elemBase = cast[uint](poolMem)
  # Build the free-list chain in the node array
  for poolNodeIndex in 0'u32 ..< elemCount:
    let node = addr nodes[poolNodeIndex]
    node.element = cast[pointer](elemBase + poolNodeIndex.uint * elemSize.uint)
    if poolNodeIndex + 1 < elemCount:
      node.next = addr nodes[poolNodeIndex + 1]
    else:
      node.next = nil
  pool.first = cast[ptr CoPoolNode](nodeArray)
  pool.freeNodeCount = elemCount

proc co_pool_alloc*(pool: ptr CoPool, count: uint32): pointer {.exportc, cdecl.} =
  ## Allocate 'count' nodes from the pool. Returns head of allocated chain,
  ## or nil if not enough free nodes.
  if count == 0:
    assert_err("co_pool.c", "co_pool.c", 73)
    return nil
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
    return
  if elemChain == nil:
    assert_err("co_pool.c", "co_pool.c", 114)
    return
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

proc ke_evt_field_get*(): uint32 {.exportc: "nimfw_ke_evt_field_get", cdecl.} =
  ## Live ke-event field snapshot for the host diag (TX-dead wedge forensics).
  keEnvEventField()[]

proc ke_evt_set*(evtBit: uint32) {.exportc, cdecl.} =
  ## Set event bit(s) in the kernel event field (interrupt-safe).
  let savedIrqState = irqSave()
  let updatedEventField = keEnvEventField()[] or evtBit
  keEnvEventField()[] = updatedEventField
  if (evtBit and 0x98000000'u32) != 0:
    nimFwTrace2U32("[WIFI-NIMFW] evt_set ", evtBit, updatedEventField)
  irqRestore(savedIrqState)

proc ke_evt_clear*(evtBit: uint32) {.exportc, cdecl, noinline.} =
  ## Clear event bit(s) in the kernel event field (interrupt-safe).
  ## noinline: blob keeps this as a standalone function.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let savedIrqState = irqSave()
  let updatedEventField = keEnvEventField()[] and (not evtBit)
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

proc keDispatchEvent(pendingEventField: uint32) =
  if pendingEventField == 0: return
  let eventIndex = eventIndex32(pendingEventField)
  nimFwTrace2U32("[WIFI-NIMFW] evt_sched ", pendingEventField, eventIndex)
  if eventIndex >= KE_EVT_MAX.uint32:
    assert_err("ke_event.c", "ke_event.c", 236)
    return
  let handler = keEvtHandlers[eventIndex].handler
  if handler == nil:
    assert_err("ke_event.c", "ke_event.c", 236)
    return
  let eventHandler = cast[proc(param: pointer) {.cdecl.}](handler)
  eventHandler(keEvtHandlers[eventIndex].param)

proc ke_evt_schedule*() {.exportc, cdecl.} =
  ## Vendor dispatch picks the highest posted bit through the handler table.
  keDispatchEvent(keEnvEventField()[])

# ###########################################################################
#                      KERNEL: MESSAGES (ke_msg_*)
# ###########################################################################

# TIM lifetime metadata shares the allocation but stays beyond the wire payload.
proc mmConnLossForget(header: pointer)

proc mmTimAllocationSize(id: uint16; destination: uint8; length: uint32): uint32 =
  if id != MM_TIM_UPDATE_REQ or destination != TASK_MM:
    return length
  const
    alignment = alignof(MmTimIdentityNode).uint32
    extra = KeMsgTailSlack + alignment - 1 + sizeof(MmTimIdentityNode).uint32
  if length > high(uint32) - extra:
    return high(uint32)
  let offset = (length + KeMsgTailSlack + alignment - 1) and not (alignment - 1)
  offset + sizeof(MmTimIdentityNode).uint32

proc mmTimRegisterAllocation(header: ptr KeMsgHdr) =
  if header.id != MM_TIM_UPDATE_REQ or header.destId != TASK_MM:
    return
  const alignment = alignof(MmTimIdentityNode).uint32
  let offset = (header.paramLen + KeMsgTailSlack + alignment - 1) and
               not (alignment - 1)
  let node = cast[ptr MmTimIdentityNode](cast[uint](keMsgPayload(header)) + offset.uint)
  node[] = default(MmTimIdentityNode)
  node.message = header
  let saved = irqSave()
  node.next = mmTimIdentities
  mmTimIdentities = node
  irqRestore(saved)

proc mmTimFindStation(vif: uint8; aid: uint16): uint8 =
  if aid != 0:
    for index in 0'u8 ..< STA_MGMT_FREE_STAS.uint8:
      let sta = staInfoForIdx(index)
      if sta.valid != 0 and sta.instNbr == vif and sta.aid == aid:
        return index
  0xFF'u8

proc mmTimCaptureMessage(header: ptr KeMsgHdr) =
  if header.id != MM_TIM_UPDATE_REQ or header.destId != TASK_MM:
    return
  var node = mmTimIdentities
  while node != nil:
    if node.message == cast[pointer](header):
      if node.captured:
        return
      node.captured = true
      if header.paramLen < MmTimUpdatePayloadSize:
        return
      let req = cast[ptr MmTimUpdatePayload](keMsgPayload(header))
      node.aid = req.aid
      node.vif = req.vifIdx
      node.setFlag = req.setFlag
      if node.vif >= MAX_VIFS.uint8 or node.aid > MAX_AID.uint16 or
          vifChannelForIdx(node.vif).vifType != VIF_TYPE_AP:
        return
      node.vifEpoch = rxVifEpochs[node.vif]
      node.station = mmTimFindStation(node.vif, node.aid)
      node.stationEpoch = staDeleteEpoch(node.station)
      node.valid = true
      return
    node = node.next

proc mmTimMessageCurrent(header: ptr KeMsgHdr): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  var node = mmTimIdentities
  while node != nil:
    if node.message == cast[pointer](header):
      if not node.captured or not node.valid or header.id != MM_TIM_UPDATE_REQ or
          header.destId != TASK_MM or header.paramLen < MmTimUpdatePayloadSize or
          rxVifEpochs[node.vif] != node.vifEpoch or
          vifChannelForIdx(node.vif).vifType != VIF_TYPE_AP:
        return false
      let req = cast[ptr MmTimUpdatePayload](keMsgPayload(header))
      if req.vifIdx != node.vif or req.aid != node.aid or req.setFlag != node.setFlag:
        return false
      let station = mmTimFindStation(node.vif, node.aid)
      if station == 0xFF'u8 and node.setFlag == 0:
        # Clearing an unoccupied AID is safe even after its old peer retired.
        return true
      return station == node.station and staDeleteEpoch(station) == node.stationEpoch
    node = node.next

proc mmTimForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr mmTimIdentities
  while link[] != nil:
    if link[].message == header:
      link[] = link[].next
      return
    link = addr link[].next

proc ke_msg_try_alloc(id: uint16, destId: uint8, srcId: uint8,
                      paramLen: uint32): pointer =
  ## Fallible allocation without scheduling recovery.
  const overhead = KeMsgHdrSize.uint32 + KeMsgTailSlack
  let storageLength = chanUpdateStorageLength(id, destId,
    smDisconnectStorageLength(id, destId, mmTimAllocationSize(id, destId, paramLen)))
  if storageLength > high(uint32) - overhead:
    return nil
  let allocFn = cast[proc(sz: uint32): pointer {.cdecl.}](
    blOpsFunc(0xB8))
  if allocFn == nil:
    return nil
  let totalSize = storageLength + overhead
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
  mmTimRegisterAllocation(hdr)
  smDisconnectRegister(hdr)
  chanUpdateRegister(hdr)
  return payload

proc ke_msg_alloc*(id: uint16, destId: uint8, srcId: uint8, paramLen: uint32): pointer {.exportc, cdecl.} =
  ## Unlike the blob's fatal assertion, Nim's reset request returns to its caller.
  result = ke_msg_try_alloc(id, destId, srcId, paramLen)
  if result == nil:
    assert_err("ke_msg.c", "ke_msg.c", 48)

proc ke_msg_send*(param: pointer) {.exportc, cdecl, noinline.} =
  ## Send a kernel message (param points to payload, header is immediately before it).
  ## From blob: asserts destId <= TASK_MAX, routes local tasks to sent queue
  ## with KE_EVT_KE_MESSAGE, routes API/external tasks via IPC push + free.
  ## noinline: blob keeps this as a separate function (>20 call sites).
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  if param == nil:
    return
  let hdr = keMsgHdrFromPayload(param)
  let destTask = hdr.destId
  if destTask > TASK_MAX:
    # Retire the transferred message before a diagnostic callback can reenter.
    ke_msg_free(hdr)
    assert_err("ke_msg.c", "ke_msg.c", 127)
    return
  if destTask <= TASK_LAST_EMB:
    # Internal task: enqueue to sent queue and set message event
    let messageId = hdr.id.uint32
    block:
      let saved = irqSave()
      defer: irqRestore(saved)
      mmTimCaptureMessage(hdr)
      smDisconnectStamp(hdr)
      chanUpdateCaptureMessage(hdr)
      co_list_push_back(addr keMsgQueueSent, cast[ptr CoListHdr](hdr))
      ke_evt_set(KE_EVT_KE_MESSAGE)
    # Queue/event callbacks may already have consumed and freed the message.
    nimFwTrace2U32("[WIFI-NIMFW] ke_msg_send internal ", messageId, destTask.uint32)
  else:
    # API/external task (destTask 9-10): route via bl_rx_e2a_handler
    # Blob: call bl_rx_e2a_handler(param-8), then tail-call g_bl_ops_funcs[0xBC](hdr)
    nimFwTrace("[WIFI-NIMFW] ke_msg_send external")
    bl_rx_e2a_handler(keMsgExternalPayload(param))
    nimFwTrace("[WIFI-NIMFW] ke_msg_send external done")
    # The blob tail-calls g_bl_ops_funcs[0xBC], which is ke_msg_free's body.
    # The message is retired exactly as a consumed internal one is.
    ke_msg_free(hdr)

proc ke_msg_send_basic*(id: uint16, destId: uint8, srcId: uint8) {.exportc, cdecl, noinline.} =
  ## Allocate and send a zero-length kernel message.
  ## noinline: blob keeps this as a separate helper called from many sites.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let param = ke_msg_alloc(id, destId, srcId, 0)
  if param != nil:
    ke_msg_send(param)

proc ke_msg_alloc_reply*(request: pointer, id: uint16, length: uint32): pointer =
  ## Keep private request ownership outside the wire payloads.
  if request == nil:
    return nil
  if request == meControlCommand:
    return meTakeControlReply(request, id, length)
  if smAwaits(request) and length == 0:
    return smTakeReply(request, id)
  if request == apmStartRequest:
    return apmTakeStartReply(request, id, length)
  let header = keMsgHdrFromPayload(request)
  ke_msg_alloc(id, header.srcId, header.destId, length)

proc ke_msg_send_basic_reply*(request: pointer, id: uint16) =
  let reply = ke_msg_alloc_reply(request, id, 0)
  if reply != nil:
    ke_msg_send(reply)

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

var mmEdcaRefresh: tuple[message, context: pointer; vif: uint8;
                         vifEpoch, bindingEpoch: uint32]
var chanCtxtLinkEpochs {.wifiCtrl.}: array[MAX_VIFS, uint32]

type MmConfigIdlePhase = enum
  mmConfigNoIdle, mmConfigAwaitIdle, mmConfigIdleReady

var mmConfigIdle: tuple[owner: pointer; epoch: uint32; phase: MmConfigIdlePhase]

proc mmConfigTrackIdle(owner: pointer; mode, state: uint8): uint32 =
  let mm = mmEnvView()
  mm.hardwareMode = mode
  mm.previousState = state
  inc mmConfigIdle.epoch
  mmConfigIdle.owner = owner
  mmConfigIdle.phase = mmConfigAwaitIdle
  mmConfigIdle.epoch

proc mmConfigCancelIdle() =
  let saved = irqSave()
  defer: irqRestore(saved)
  if mmConfigIdle.phase != mmConfigNoIdle:
    let mm = mmEnvView()
    mm.hardwareMode = 0
    mm.previousState = 0
  inc mmConfigIdle.epoch
  mmConfigIdle.owner = nil
  mmConfigIdle.phase = mmConfigNoIdle

proc mmConfigForgetIdleOwner(header: pointer): bool =
  if header == nil or mmConfigIdle.owner != header: return false
  let saved = irqSave()
  defer: irqRestore(saved)
  if mmConfigIdle.owner != header: return false
  mmConfigIdle.owner = nil
  mmConfigIdle.phase == mmConfigIdleReady

proc mmEdcaForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  if header == mmEdcaRefresh.message:
    mmEdcaRefresh.message = nil

proc ke_msg_free*(param: pointer) {.exportc, cdecl.} =
  ## Free a kernel message. Blob: tail-calls `g_bl_ops_funcs[0xBC](param)`
  ## — param is already the HEADER pointer (callers subtract 12 before
  ## calling). Every message is retired here, including one ke_msg_send has
  ## delivered to the host, so its owners forget it exactly once.
  # The channel switch's static request is never freed.
  if chanSwitchForget(param): return
  mmTimForget(param)
  mmConnLossForget(param)
  rxMgtForget(param)
  chanUpdateForget(param)
  chanBcnRequestForget(param)
  smDisconnectForget(param)
  mmEdcaForget(param)
  let resumePending = mmConfigForgetIdleOwner(param)
  platformFree(param)
  if resumePending:
    ke_evt_set(KE_EVT_KE_MESSAGE)

proc ke_msg_free_payload(param: pointer) {.inline.} =
  if param != nil:
    ke_msg_free(cast[pointer](keMsgHdrFromPayload(param)))

proc ke_msg_discard*(param: pointer): cint {.exportc, cdecl.} =
  ## Message handler: discard (consume and free). Returns 0 = consumed.
  return KeMsgConsumed

proc ke_msg_save*(param: pointer): cint {.exportc, cdecl.} =
  ## Message handler: save (do not free, move to saved queue). Returns 2 = saved.
  ## From blob: ke_msg_save returns saved (not no-free).
  when defined(bl808WifiScanOwnershipBench):
    # SCANU's tables save a request that comes while it scans or joins;
    # scanu_start_req_handler only runs in SCANU's idle state.
    let header = keMsgHdrFromPayload(param)
    if header.id == SCANU_START_REQ and header.srcId == TASK_SM:
      inc nimFwDbgScanOwnershipSaved
  return KeMsgSaved

# ###########################################################################
#                      KERNEL: QUEUE (ke_queue_*)
# ###########################################################################

proc ke_queue_extract*(queue: ptr CoList, cmpFn: proc(elem: ptr CoListHdr, param: pointer): bool {.cdecl.}, param: pointer): ptr CoListHdr {.exportc, cdecl.} =
  ## Extract first element matching cmpFn from queue.
  var previousNode: ptr CoListHdr = nil
  var currentNode = queue.first
  while currentNode != nil:
    let matches = cmpFn(currentNode, param)
    let nextNode = currentNode.next
    if matches:
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
  smSaQueryResetScope()
  mmConfigCancelIdle()
  smActivationCancel()
  chanSwitchReset()
  co_list_init(addr keMsgQueueSent)
  co_list_init(addr keMsgQueueSaved)
  co_list_init(addr keTimerQueue)
  keSavedReschedTask = TASK_NONE
  keSavedReschedMask = 0
  keSavedReschedRemaining = default(typeof(keSavedReschedRemaining))
  ke_evt_clear(0xFFFFFFFF'u32)

proc ke_flush*() {.exportc, cdecl.} =
  ## Flush all pending messages and timers. Blob:
  ##   while (msg = co_list_pop_front(&ke_env.q_sent))  ke_msg_free(msg)
  ##   while (msg = co_list_pop_front(&ke_env.q_saved)) ke_msg_free(msg)
  ##   while (tmr = co_list_pop_front(&ke_env.tmr_free)) g_bl_ops_funcs.free(tmr)
  ##   ke_evt_clear(0xFFFFFFFF)  # tail call
  smSaQueryResetScope()
  mmConfigCancelIdle()
  # The lower scan's answer is flushed with the queues below, so SCANU,
  # which waits on it, drops its request too.
  scanRelease()
  scanuAbandon()
  chanSwitchReset()
  # The flush frees every message SM waits on: drop its attempt or teardown.
  smAbandon()
  # ME before PS, as me_init then mm_init: meControlReset forgets ME's
  # request before cancelling the transition that holds it, so psCancel
  # frees only a host's.
  meControlReset()
  psCancel()
  for vifIdx in 0'u8 ..< MAX_VIFS.uint8:
    apmCancelPendingForVif(vifIdx)
  mm_bcn_flush_updates(false)
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
  keSavedReschedTask = TASK_NONE
  keSavedReschedMask = 0
  keSavedReschedRemaining = default(typeof(keSavedReschedRemaining))
  ke_evt_clear(0xFFFFFFFF'u32)

# ###########################################################################
#                      KERNEL: TASK / STATE
# ###########################################################################

proc cmp_dest_id(elem: ptr CoListHdr, param: pointer): bool {.exportc, cdecl.} =
  ## Compare callback for ke_queue_extract: match by destId.
  let hdr = cast[ptr KeMsgHdr](elem)
  return hdr.destId == encodedArgU8(param)

proc ke_saved_queue_count_dest(taskId: uint8): uint32 =
  var currentNode = keMsgQueueSaved.first
  while currentNode != nil:
    if cast[ptr KeMsgHdr](currentNode).destId == taskId:
      inc result
    currentNode = currentNode.next

proc keUpdateSavedReschedule(taskId: uint8; more: bool) =
  let saved = irqSave()
  defer: irqRestore(saved)
  let taskBit = 1'u16 shl taskId
  if more:
    keSavedReschedMask = keSavedReschedMask or taskBit
  else:
    keSavedReschedMask = keSavedReschedMask and not taskBit
  keSavedReschedTask = TASK_NONE
  # Rotate after each batch without forgetting other tasks' deferred work.
  for distance in 1 .. TASK_API.int:
    let nextTask = ((taskId.int + distance) mod TASK_API.int).uint8
    if (keSavedReschedMask and (1'u16 shl nextTask)) != 0:
      keSavedReschedTask = nextTask
      break

proc keDrainSavedMessages(taskId: uint8; limit: uint32; restart: bool): bool =
  if taskId >= TASK_API:
    return false
  var moved = 0'u32
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    if restart:
      keSavedReschedRemaining[taskId] = ke_saved_queue_count_dest(taskId)
    while moved < limit and keSavedReschedRemaining[taskId] != 0:
      let node = ke_queue_extract(addr keMsgQueueSaved, cmp_dest_id,
                                  cast[pointer](cast[uint](taskId)))
      if node == nil:
        keSavedReschedRemaining[taskId] = 0
        break
      co_list_push_back(addr keMsgQueueSent, node)
      dec keSavedReschedRemaining[taskId]
      inc moved
    result = keSavedReschedRemaining[taskId] != 0
    keUpdateSavedReschedule(taskId, result)
    if result:
      inc nimFwDbgSavedMsgYield
      nimFwDbgSavedMsgYieldTask = taskId.uint32
  # No queue/quota changes follow this callout: it may initiate another request.
  if moved != 0 or result:
    ke_evt_set(KE_EVT_KE_MESSAGE)

proc ke_reschedule_saved_messages(taskId: uint8,
                                  limit: uint32 = WifiSavedMsgDrainLimit): bool =
  ## Bound each explicit request by the current saved-message count.
  keDrainSavedMessages(taskId, limit, true)

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
  # Blob: bounds check taskId <= 9 (line 170) then ke_task_local (line 171).
  if taskId.int >= keTaskDescs.len:
    assert_err("ke_task.c", "ke_task.c", 170)
    return
  if not ke_task_local(taskId):
    assert_err("ke_task.c", "ke_task.c", 171)
    return
  let desc = addr keTaskDescs[taskId]
  if desc.instanceCount == 0 or state >= desc.stateCount:
    assert_err("ke_task.c", "ke_task.c", 172)
    return
  let sp = desc.statePtr
  if sp == nil:
    assert_err("ke_task.c", "ke_task.c", 177)
    return
  if taskId == 0 and state == 0:
    block:
      let saved = irqSave()
      defer: irqRestore(saved)
      let rx = rxlCntrlEnvView()
      rx.processingFlag = 0
      if rx.queue.first != nil:
        ke_evt_set(0x00100000'u32)
  # Early-out if state unchanged
  if sp[] == state: return
  sp[] = state
  discard ke_reschedule_saved_messages(taskId)

proc ke_state_get*(taskId: uint8): uint16 {.exportc, cdecl.} =
  ## Get the current state of a task.
  ## From blob: bounds check, ke_task_local validate, read statePtr.
  ## Invalid descriptors return a non-state value if the diagnostic returns.
  if taskId.int >= keTaskDescs.len:
    assert_err("ke_task.c", "ke_task.c", 204)
    return high(uint16)
  if not ke_task_local(taskId):
    assert_err("ke_task.c", "ke_task.c", 205)
    return high(uint16)
  let desc = addr keTaskDescs[taskId]
  if desc.instanceCount == 0 or desc.stateCount == 0 or desc.statePtr == nil:
    assert_err("ke_task.c", "ke_task.c", 206)
    return high(uint16)
  let state = desc.statePtr[]
  if state >= desc.stateCount:
    assert_err("ke_task.c", "ke_task.c", 206)
    return high(uint16)
  return state

proc mmConfigResumeIdle(epoch: uint32; task: uint8; abandonedOnly = false): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  if mmConfigIdle.epoch != epoch or mmConfigIdle.phase == mmConfigAwaitIdle or
      (ke_evt_field_get() and 0x80000000'u32) != 0 or
      ke_state_get(task) != MM_IDLE.uint16:
    return false
  if abandonedOnly and (mmConfigIdle.phase != mmConfigIdleReady or
      mmConfigIdle.owner != nil or
      (regRead(MACHW_STATE_CNTRL_REG) and 0xFF'u32) != 0):
    return false
  let mm = mmEnvView()
  let nextMode = mm.hardwareMode.uint32 shl 4
  let nextState = mm.previousState.uint16
  if (nextMode and not 0xF0'u32) != 0:
    assert_err("(((uint32_t)nextstate << 4) & ~((uint32_t)0x000000F0)) == 0",
               "module", 1465)
    return false
  if mmConfigIdle.phase == mmConfigIdleReady:
    # Take the restore before publishing state or waking saved work.
    mmConfigCancelIdle()
  regWrite(MACHW_STATE_CNTRL_REG, nextMode)
  ke_state_set(task, nextState)
  true

proc mmConfigResumeAbandonedIdle() =
  if mmConfigIdle.phase == mmConfigIdleReady and mmConfigIdle.owner == nil:
    discard mmConfigResumeIdle(mmConfigIdle.epoch, TASK_MM, abandonedOnly = true)

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
    discard keDrainSavedMessages(keSavedReschedTask, WifiSavedMsgDrainLimit, false)

proc keUpdateMessageEventAfterSchedule() {.inline.} =
  let saved = irqSave()
  if keMsgQueueSent.first == nil:
    if keSavedReschedMask != 0:
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
    if destTask.int >= keTaskDescs.len:
      ke_msg_free(node)
      assert_err("ke_task.c", "ke_task.c", 261)
      break ktsBody
    if not ke_task_local(destTask):
      ke_msg_free(node)
      assert_err("ke_task.c", "ke_task.c", 262)
      break ktsBody
    let desc = addr keTaskDescs[destTask]
    if desc.instanceCount == 0 or desc.stateCount == 0 or desc.statePtr == nil:
      ke_msg_free(node)
      assert_err("ke_task.c", "ke_task.c", 263)
      break ktsBody
    let curState = desc.statePtr[]
    if curState >= desc.stateCount:
      ke_msg_free(node)
      assert_err("ke_task.c", "ke_task.c", 263)
      break ktsBody
    # Step 1: Try state-based handler lookup
    var handlerFn: pointer = nil
    if desc.stateTable != nil:
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
        ke_msg_free(node)
        break ktsBody
      else:
        nimFwTraceU32("[WIFI-NIMFW] task_sched def handler=", cast[uint32](cast[uint](handlerFn)))
    else:
      nimFwTraceU32("[WIFI-NIMFW] task_sched state handler=", cast[uint32](cast[uint](handlerFn)))
    # Step 3: Registered Nim handlers use `(param: pointer): cint`.
    # Call with a 1-arg cast so `param`
    # (the payload) lands in a0. Previous code cast to a 4-arg type
    # matching blob's (msgId,param,destId,srcId) ABI — that put msgId
    # in a0, so Nim handlers received msgId instead of the payload.
    let handler = cast[proc(param: pointer): cint {.cdecl.}](handlerFn)
    nimFwTrace("[WIFI-NIMFW] task_sched call")
    if not rxMgtMessageCurrent(node) or not chanUpdateAdmit(param):
      ke_msg_free(node)
      break ktsBody
    let rawHandlerResult = handler(param)
    when defined(bl808HeapGuardMsgs):
      # Heap-corruption bisector: walk the TLSF heap after EVERY dispatched
      # message; the FIRST message whose handler leaves the heap inconsistent
      # records its id + handler into exported globals (dumped by the entry's
      # diag). Debug-only (define-gated).
      block heapGuard:
        proc tlsfCheckHeapRaw(): cint {.importc: "tlsf_check_heap", cdecl.}
        if nimFwDbgHeapGuardMsg == 0'u32 and tlsfCheckHeapRaw() == 0:
          nimFwDbgHeapGuardMsg = msgId.uint32 or 0x8000_0000'u32
          nimFwDbgHeapGuardHandler = cast[uint32](cast[uint](handlerFn))
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

  # Clear the drained message event first. If the idle owner retires after
  # our restore check, its new message wake must survive this dispatch.
  keUpdateMessageEventAfterSchedule()
  mmConfigResumeAbandonedIdle()

proc ke_task_sm_activating*(): bool {.exportc, cdecl.} =
  ## Check if the SM task is currently in an activating state.
  ## From blob: calls ke_state_get(TASK_SM) and checks == 9 (SM_ACTIVATING_STATE).
  return ke_state_get(TASK_SM) == SM_ACTIVATING_STATE

# ###########################################################################
#                      KERNEL: TIMERS
# ###########################################################################

proc cmp_abs_time*(a, b: ptr CoListHdr): bool {.exportc, cdecl.} =
  ## Comparator for sorted timer insert (from blob: cmp_abs_time).
  ## Returns true when (unsigned)(a.time - b.time) >= 0x11E1A301, meaning
  ## a.time is effectively BEFORE b.time (with uint32 wrap-around handling).
  let ta = cast[ptr KeTimerEntry](a)
  let tb = cast[ptr KeTimerEntry](b)
  let diff = ta.time - tb.time  # unsigned subtraction
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

proc ke_timer_try_set(taskId: uint16; instId: uint8; delay: uint32;
                      stamp: uint32 = 0): bool =
  ## ke_timer_set that reports a delay out of range or an allocation failure
  ## (false) instead of asserting. `stamp` is the owner's Op stamp, kept on
  ## the entry; a stamped expiry carries it as its 4-byte payload
  ## (ke_timer_schedule).
  ##
  ## Kernel timers are set, cleared and expired only by firmware handlers,
  ## and the firmware step is never reentered (wifiStepEnter); nothing called
  ## here (the heap, the timer hardware) runs firmware code. So no other set
  ## or clear can interleave with this one, as in the blob.
  if delay == 0 or delay > KE_TIMER_MAX_DELAY: return false
  let combined = (taskId.uint32 shl 16) or instId.uint32
  var saved = irqSave()
  let first = cast[ptr KeTimerEntry](keTimerQueue.first)
  let wasFirst = first != nil and first.id == taskId and first.taskId == instId
  var entry = cast[ptr KeTimerEntry](ke_queue_extract(addr keTimerQueue, cmp_timer_id,
                                                      cast[pointer](combined)))
  if entry == nil:
    irqRestore(saved)
    let allocFn = cast[proc(sz: uint32): pointer {.cdecl.}](blOpsFunc(0xB8))
    if allocFn != nil:
      entry = cast[ptr KeTimerEntry](allocFn(sizeof(KeTimerEntry).uint32))
    if entry == nil: return false
    saved = irqSave()
  defer: irqRestore(saved)
  let expiry = macTimeNow() + delay
  entry.id = taskId
  entry.taskId = instId
  entry.time = expiry
  entry.stamp = stamp
  co_list_insert(addr keTimerQueue, cast[ptr CoListHdr](entry), cmp_abs_time)
  if wasFirst or keTimerQueue.first == cast[ptr CoListHdr](entry):
    ke_timer_hw_set(cast[ptr KeTimerEntry](keTimerQueue.first))
  if cast[int32](expiry - macTimeNow()) < 0:
    ke_evt_set(KE_EVT_KE_TIMER)
  true

proc ke_timer_set*(taskId: uint16, instId: uint8, delay: uint32) {.exportc, cdecl.} =
  ## Preserve the vendor API; callers needing a fallible set use the helper.
  if delay == 0:
    assert_err("ke_timer.c", "ke_timer.c", 110)
    return
  if delay > KE_TIMER_MAX_DELAY:
    assert_err("ke_timer.c", "ke_timer.c", 111)
    return
  if not ke_timer_try_set(taskId, instId, delay):
    assert_err("ke_timer.c", "ke_timer.c", 128)

proc ke_timer_clear*(taskId: uint16, instId: uint8) {.exportc, cdecl.} =
  ## Remove a kernel timer and reprogram the hardware if the head changed.
  let combined = (taskId.uint32 shl 16) or instId.uint32
  let saved = irqSave()
  let first = cast[ptr KeTimerEntry](keTimerQueue.first)
  let wasFirst = first != nil and first.id == taskId and first.taskId == instId
  let entry = ke_queue_extract(addr keTimerQueue, cmp_timer_id, cast[pointer](combined))
  if wasFirst:
    let head = cast[ptr KeTimerEntry](keTimerQueue.first)
    ke_timer_hw_set(head)
    if head != nil and cast[int32](head.time - macTimeNow()) < 0:
      # The next timer expired while this handler ran. The blob also asserts
      # at line 214 here; in this firmware an assert is a full MAC recovery,
      # so only schedule the expiry.
      ke_evt_set(KE_EVT_KE_TIMER)
  irqRestore(saved)
  if entry != nil: platformFree(entry)

proc keTimerExpired(entry: ptr KeTimerEntry; fromPoll: static bool = false): bool {.inline.} =
  if entry == nil: return false
  let remaining = entry.time - macTimeNow()
  when fromPoll:
    cast[int32](remaining) <= 0
  else:
    cast[int32](remaining - 50'u32) < 0

proc keTimerRequeue(entry: ptr KeTimerEntry; delayUs: uint32) =
  ## Put back a popped expiry that could not be posted, without allocating.
  let saved = irqSave()
  defer: irqRestore(saved)
  entry.time = macTimeNow() + delayUs
  co_list_insert(addr keTimerQueue, cast[ptr CoListHdr](entry), cmp_abs_time)
  if keTimerQueue.first == cast[ptr CoListHdr](entry):
    ke_timer_hw_set(entry)

proc ke_timer_schedule*() {.exportc, cdecl.} =
  ## Process expired timers.
  ## From blob: loops clearing event, checking first timer. If expired,
  ## pops and sends ke_msg_send_basic. If not expired, programs HW timer
  ## and re-checks (races with HW). If queue empty, disables HW timer.
  ## The expiry message goes to a firmware task's queue, so nothing here
  ## runs a handler or touches another timer (see ke_timer_try_set).
  var drained = 0'u32
  while drained < WifiTimerDrainLimit:
    let entry = block:
      let saved = irqSave()
      defer: irqRestore(saved)
      ke_evt_clear(KE_EVT_KE_TIMER)
      let node = cast[ptr KeTimerEntry](keTimerQueue.first)
      if node == nil:
        ke_timer_hw_set(nil)
        return
      if cast[int32](node.time - macTimeNow() - 50) >= 0:
        ke_timer_hw_set(node)
        # The deadline can pass while the hardware is programmed.
        if cast[int32](node.time - macTimeNow()) >= 0: return
      cast[ptr KeTimerEntry](co_list_pop_front(addr keTimerQueue))
    inc drained
    if entry.id == SM_SA_QUERY_TIMEOUT_IND_MSG and entry.taskId == TASK_SM:
      smSaQueryQueueTimeout(entry.stamp)
    else:
      # The blob's ke_msg_alloc halts when the heap is exhausted. Here an
      # expiry that cannot be posted is retried on the same entry in 1 ms,
      # so it is late but never lost. The repeat probe is optional; the
      # channel timer owns dwell progress. A stamped timer's expiry carries
      # its stamp, so its owner can tell it from an earlier operation's.
      let message = ke_msg_try_alloc(entry.id, entry.taskId, 0xFF,
                                     if entry.stamp != 0: 4'u32 else: 0'u32)
      if message != nil:
        if entry.stamp != 0: cast[ptr uint32](message)[] = entry.stamp
        ke_msg_send(message)
      elif not (entry.id == SCAN_PROBE_TIMER and entry.taskId == TASK_SCAN):
        keTimerRequeue(entry, 1000)
        continue
    platformFree(cast[pointer](entry))

  let saved = irqSave()
  defer: irqRestore(saved)
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
  let saved = irqSave()
  defer: irqRestore(saved)
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
  ## Snapshot flow-control flags before the host callback so reentrant
  ## publication cannot be erased by the old post-callback clear.
  proc bl_main_event_handle(a0: uint32, a1: pointer) {.importc, cdecl.}
  if evtType > 1'u32:
    return
  if evtType == 0:
    ke_evt_clear(0x80'u32)
    bl_main_event_handle(0, nil)
  else:
    var pending: KeEnvPsFlagsView
    block:
      let saved = irqSave()
      defer: irqRestore(saved)
      ke_evt_clear(0x100'u32)
      pending = keEnvPsFlags()[]
      discard c_memset(keEnvPsFlags(), 0, sizeof(KeEnvPsFlagsView).csize_t)
    bl_main_event_handle(evtType, addr pending)

proc bl_fw_statistic_dump*() {.exportc, cdecl.} =
  ## Consume the statistics event before invoking any diagnostic callback.
  type LogFn = proc(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.}
  ke_evt_clear(0x40'u32)
  let saved = irqSave()
  defer: irqRestore(saved)
  let logFn = cast[LogFn](blOpsFunc(204))
  if logFn != nil:
    logFn(2, nil, "ke_event.c", 158,
      "\r\n==========================FW STATISTIC DUMP S===================\r\n")
  {.emit: ["extern void bl_utils_dump(void); bl_utils_dump();"].}
  txl_frame_dump()
  ipc_emb_dump()
  txl_cntrl_env_dump()
  txl_cfm_dump()
  rxl_hwdesc_dump()
  rxl_cntrl_dump()
  let endLogFn = cast[LogFn](blOpsFunc(204))
  if endLogFn != nil:
    endLogFn(2, nil, "ke_event.c", 175,
      "==========================FW STATISTIC DUMP E===================\r\n")

{.emit: "__attribute__((optimize(\"crossjumping\"))) void bl60x_fw_dump_statistic(int);".}
proc bl60x_fw_dump_statistic*(forced: cint) {.exportc, cdecl.} =
  ## Forced requests run now; ordinary requests only schedule the event.
  if forced != 0:
    bl_fw_statistic_dump()
  else:
    ke_evt_set(0x40'u32)

# ###########################################################################
#                     HAL MAC HW (hal_machw_*)
# ###########################################################################

proc tcpip_stack_input(entry: pointer, descFlag: uint32, payload: pointer, bufOff: uint32, dmaArray: pointer, fcFlag: uint32): cint {.importc: "tcpip_stack_input", cdecl, raises: [Exception].}
  ## External: fast-path delivery of RX data frames to TCP/IP stack.

proc snapshotMacTimingRegisters() {.inline.} =
  nimFwDbgMacTimingE8 = regRead(MACHW_BASE + 0x0E8'u)
  nimFwDbgMacTimingF0 = regRead(MACHW_BASE + 0x0F0'u)
  nimFwDbgMacTimingF4 = regRead(MACHW_BASE + 0x0F4'u)
  nimFwDbgMacTimingF8 = regRead(MACHW_BASE + 0x0F8'u)
  nimFwDbgMacTiming104 = regRead(MACHW_BASE + 0x104'u)

proc hal_machw_init*(): bool {.exportc, cdecl, discardable.} =
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
  if not waitMacSoftResetClear():
    txControlEnv().resetInProgress = 1
    hal_machw_disable_int()
    ke_evt_set(0x80000000'u32)
    return false

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
      return false
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
    let preserved = regRead(REG_0E8) and 0xFF0000FF'u32
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
      return false
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
    let preserved = regRead(REG_0F4) and 0xFF0000FF'u32
    regWrite(REG_0F4, (scaled and 0x00FFFF00'u32) or preserved)

  # --- Rescale reg[0xF8] bits[23:8] (16-bit field) ---
  block:
    let machwTimingF8Control = regRead(REG_0F8)
    let timingF8Field = (machwTimingF8Control shr 8) and 0xFFFF'u32
    let scaled = ((timingF8Field * newClk) div divisor) shl 8
    let preserved = regRead(REG_0F8) and 0xFF0000FF'u32
    regWrite(REG_0F8, (scaled and 0x00FFFF00'u32) or preserved)

  # --- Rescale reg[0x104] bits[29:20] (10-bit field) ---
  block:
    let machwTiming104Control = regRead(REG_104)
    let timing104HighField = (machwTiming104Control shr 20) and 0x3FF'u32
    let scaled = ((timing104HighField * newClk) div divisor) shl 20
    # Assert no overflow into bits[31:30]
    if (scaled and 0xC0000000'u32) != 0:
      assert_err("hal_machw.c", "hal_machw.c", 0x228A.cint)
      return false
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
      return false
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
      return false
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
      return false

  # -----------------------------------------------------------------------
  # Block 8: Platform diagnostic before final MAC register configuration.
  # The vendor calls g_bl_ops_funcs+4 (_printf), not a debug initializer.
  # -----------------------------------------------------------------------
  let configPrintf = cast[proc(format: cstring; nVap, endIdx, startIdx: cint)
    {.cdecl.}](blOpsFunc(4))
  if configPrintf != nil:
    configPrintf("[WF] [KEY] [CFG] nVAP is %d, endidx %d, startidx %d\r\n",
                 2.cint, 12.cint, 8.cint)

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
      return false
    # Write bits[28:26] of reg[0x9C]
    registerWriteback = regRead(REG_09C)
    registerWriteback = (registerWriteback and 0xE3FFFFFF'u32) or (ntxField and 0x1C000000'u32)
    regWrite(REG_09C, registerWriteback)

  # Set bit 25 in STATUS register (0x4C)
  registerWriteback = regRead(REG_04C)
  registerWriteback = (registerWriteback and 0xFDFFFFFF'u32) or 0x02000000'u32
  regWrite(REG_04C, registerWriteback)
  snapshotMacTimingRegisters()
  true

proc hal_machw_reset*(): bool {.exportc, cdecl, discardable.} =
  ## Reset MAC HW: clear state, disable gen-int enable bit, reset DMA,
  ## reconfigure interrupt controller, then re-enable gen-int.
  ## On timeout, retain queue ownership and request another reset attempt.
  ## From blob: 0x44B00038 is STATE_CNTRL, 0x44B0004C is STATUS,
  ## 0x44B00054 is DOZE_CNTRL2, 0x44B08050-0x44B0808C are INTC regs.
  ## Like the blob, this leaves MM's saved mode and state alone: a
  ## configuration request waiting for idle still has to restore them.

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
  if not waitRegLowNibbleClear(MACHW_STATE_CNTRL_REG):
    # Keep descriptors owned until a later reset reaches hardware idle.
    txControlEnv().resetInProgress = 1
    hal_machw_disable_int()
    ke_evt_set(0x80000000'u32)
    return false

  # Reset and idle completion clear the same pending flag in ps_env.
  let ps = psEnvView()
  ps.statusFlags = ps.statusFlags and not 0x04'u32

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
  true

proc hal_machw_stop*(): bool {.exportc, cdecl, discardable.} =
  ## Stop MAC HW by triggering soft reset and polling until complete.
  ## A bounded failure keeps TX gated and requests deferred recovery.
  ## From blob: writes 1 to MACHW_INTC_SOFT_RESET (0x44B08050),
  ## then calls blmac_soft_reset_getf in a loop until it returns 0.

  mmConfigCancelIdle()
  # Trigger soft reset
  regWrite(MACHW_INTC_SOFT_RESET, 1)

  # Poll until soft reset completes via blmac_soft_reset_getf (blob: call in loop)
  if waitMacSoftResetClear(): return true
  txControlEnv().resetInProgress = 1
  hal_machw_disable_int()
  ke_evt_set(0x80000000'u32)
  false

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
  # A previous hardware transition may already have posted this event.
  ke_evt_clear(KE_EVT_IDLE)

  # Read current MAC timestamp, add 50000 (0xC350), write to abs timer target
  let tsNow = regRead(MACHW_TIMLO_REG)
  regWrite(MACHW_IDLE_TIMER_REG, tsNow + 0xC350'u32)

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

  let ps = psEnvView()
  ps.statusFlags = ps.statusFlags or 0x04'u32

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
  let saved = irqSave()
  defer: irqRestore(saved)
  if macAddrPtr == nil:
    return 0xFF
  let addrView = macAddrAt(macAddrPtr)
  let macLow = addrView.lowLe
  let macHigh = addrView.highLe
  if not waitMachwSecurityControlClear(0xE0000000'u32):
    return 0xFF
  machwSecurityWriteAddress(macLow, macHigh)
  machwSecurityWriteControl(0x20000000'u32)
  if not waitMachwSecurityControlClear(0x20000000'u32):
    return 0xFF'u32
  let status = machwSecurityControl()
  # Vendor treats bit 28 as "not found"; the found entry is encoded as
  # the HW address slot in bits [23:16], biased by +8 for STA slots.
  if (status and 0x10000000'u32) != 0:
    return 0xFF'u32
  let hwIdx = (status shr 16) and 0xFF
  if hwIdx < 8 or hwIdx >= 8 + STA_INFO_TAB_ENTRIES.uint32:
    return 0xFF
  hwIdx - 8

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

  let mm = mmEnvView()
  mm.rxFilterBase = monitorFilter

  # Preserve the MM filter additions across later filter updates.
  let rxCntrl = monitorFilter or mm.rxFilterExtra
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
  ## Allow sleep only when each of the nine enabled timers is far enough ahead.
  const
    MACHW_ACTIVE_AC_REG  = MACHW_INTC_BASE + 0x08C'u
    MACHW_CHAN_STAT_BASE = MACHW_BASE + 0x128'u
  let activeAcs = regRead(MACHW_ACTIVE_AC_REG)
  for accessCategoryIndex in 0'u32 ..< 9:
    let acBit = 1'u32 shl accessCategoryIndex
    if (activeAcs and acBit) == 0:
      continue
    let perAcTime = regRead(MACHW_CHAN_STAT_BASE + accessCategoryIndex * 4)
    let macTime = regRead(MACHW_TIMLO_REG)
    if cast[int32](perAcTime - macTime - 2000'u32) >= 0:
      continue
    # A near deadline vetoes sleep. Fresh reads determine whether it is overdue.
    let perAcTime2 = regRead(MACHW_CHAN_STAT_BASE + accessCategoryIndex * 4)
    let macTime2 = regRead(MACHW_TIMLO_REG)
    if cast[int32](perAcTime2 - macTime2 + 5000'u32) < 0:
      assert_err("!hal_machw_time_past(blmac_abs_timer_get(i) + 5000)",
                 "hal_machw.c", 595)
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
  ## Report timing fields in the order and bit widths used by hal_machw.o.
  type
    HeaderFn = proc(line: cstring) {.cdecl.}
    FieldFn = proc(fmt: cstring, hexValue, decValue: uint32) {.cdecl, varargs.}
  template header(line: cstring) =
    block:
      let callback = cast[HeaderFn](blOpsFunc(8))
      if callback != nil: callback(line)
  template field(fmt: cstring; value: uint32) =
    block:
      let callback = cast[FieldFn](blOpsFunc(4))
      if callback != nil: callback(fmt, value, value)

  header("==========================  Timing Dump =========================\r\n")
  header("[Register]    [ValueName]            [Value(HEX]    [Value(DEC)]\r\n")

  let timing1 = regRead(MACHW_BASE + 0xE4'u)
  field("[Timing1]     txchaindelayinmacclk     0x%04X          %u\r\n",
        (timing1 shr 18) and 0x3FF'u32)
  field("              txrfdelayinmacclk        0x%04X          %u\r\n",
        (timing1 shr 8) and 0x3FF'u32)
  field("              maccoreclkfreq           0x%04X          %u\r\n",
        timing1 and 0xFF'u32)

  let timing2 = regRead(MACHW_BASE + 0xE8'u)
  field("[Timing2]     slotTimeInMACClk         0x%04X          %u\r\n",
        (timing2 shr 8) and 0xFFFF'u32)
  field("              slottime                 0x%04X          %u\r\n",
        timing2 and 0xFF'u32)

  let timing3 = regRead(MACHW_BASE + 0xEC'u)
  field("[Timing3]     rxrfdelayinmacclk        0x%04X          %u\r\n",
        (timing3 shr 20) and 0x3FF'u32)
  field("              txdelayrfoninmacclk      0x%04X          %u\r\n",
        (timing3 shr 10) and 0x3FF'u32)
  field("              macprocdelayinmacclk     0x%04X          %u\r\n",
        timing3 and 0x3FF'u32)

  let timing4 = regRead(MACHW_BASE + 0xF0'u)
  field("[Timing4]     radiowakeuptime          0x%04X          %u\r\n",
        timing4 shr 22)
  field("              radiochirptime           0x%04X          %u\r\n",
        (timing4 shr 12) and 0x3FF'u32)
  field("              wt2cryptclkratio         0x%04X          %u\r\n",
        timing4 and 0x3'u32)

  let timing5 = regRead(MACHW_BASE + 0xF4'u)
  field("[Timing5]     sifsbinmacclk            0x%04X          %u\r\n",
        (timing5 shr 8) and 0xFFFF'u32)
  field("              sifsb                    0x%04X          %u\r\n",
        timing5 and 0xFF'u32)

  let timing6 = regRead(MACHW_BASE + 0xF8'u)
  field("[Timing6]     sifsainmacclk            0x%04X          %u\r\n",
        (timing6 shr 8) and 0xFFFF'u32)
  field("              sifsa                    0x%04X          %u\r\n",
        timing6 and 0xFF'u32)

  let timing7 = regRead(MACHW_BASE + 0xFC'u)
  field("[Timing7]     rxccadelay               0x%04X          %u\r\n",
        (timing7 shr 8) and 0xF'u32)
  field("              rifs                     0x%04X          %u\r\n",
        timing7 and 0xFF'u32)

  let timing8 = regRead(MACHW_BASE + 0x100'u)
  field("[Timing8]     rxstartdelaymimo         0x%04X          %u\r\n",
        timing8 shr 24)
  field("              rxstartdelayshort        0x%04X          %u\r\n",
        (timing8 shr 16) and 0xFF'u32)
  field("              rxstartdelaylong         0x%04X          %u\r\n",
        (timing8 shr 8) and 0xFF'u32)
  field("              rxstartdelayofdm         0x%04X          %u\r\n",
        timing8 and 0xFF'u32)

  let timing9 = regRead(MACHW_BASE + 0x104'u)
  field("[Timing9]     rifstoinmacclk           0x%04X          %u\r\n",
        (timing9 shr 20) and 0x3FF'u32)
  field("              rifsinmacclk             0x%04X          %u\r\n",
        (timing9 shr 10) and 0x3FF'u32)
  field("              txdmaprocdlyinmacclk     0x%04X          %u\r\n",
        timing9 and 0x3FF'u32)

proc blmac_abs_timer_set*(timerIndex: uint32, timerValue: uint32) {.exportc, cdecl, noinline.} =
  ## Program timer slots 0..9 at the MAC timer bank, not the interrupt bank.
  ## Vendor txl_cntrl.o computes (0x092C004A + timerIndex) << 2.
  if timerIndex > 9:
    assert_err("reg_idx <= 9", "module", 0x26A0)
    return
  let timerAddr = MACHW_BASE + 0x128'u + timerIndex * 4
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
    return
  var reg = regRead(MACHW_BASE + 0x04C'u)
  reg = reg and not 0x04'u32
  reg = reg or shifted
  regWrite(MACHW_BASE + 0x04C'u, reg)

proc blmac_soft_reset_getf*(): uint8 {.exportc, cdecl, noinline.} =
  ## Read soft reset status field from MACHW_INTC.
  ## From blob (hal_machw.o, 14 instrs): reads MACHW_INTC_BASE+0x050,
  ## asserts only bit 0 is used (andi ~1 must be 0), returns low byte.
  ## Our recoverable assert keeps an invalid read from ending the reset wait.
  let softResetStatus = regRead(MACHW_INTC_BASE + 0x050'u)
  if (softResetStatus and not 0x01'u32) != 0:
    assert_err("hal_machw.c", "hal_machw.c", 285)
    return 1'u8
  return (softResetStatus and 0xFF'u32).uint8

proc hal_machw_rx_duration*(rxDesc: pointer, frameLen: uint32): uint32 {.exportc, cdecl.} =
  ## Use the RX descriptor's vector and requested length for the MAC duration
  ## engine. The vendor MM object returns 500 when no valid result is available.
  if rxDesc == nil:
    return 500
  const RxToMacRate = [0'u8, 1, 2, 3, 0xFF, 0xFF, 0xFF, 0xFF,
                      10, 8, 6, 4, 11, 9, 7, 5]
  let rxv = addr rxDurationDescAt(rxDesc).vector
  let rateIndex = (rxv.mcsBitsWord shr 12) and 0xF'u32
  let rate = RxToMacRate[rateIndex]
  if (rate and 0x80'u8) != 0:
    assert_err("hal_machw.c", "hal_machw.c", 0x1A99)
    return 500
  let preambleFlag = (rxv.formatBitsWord shr 15) and 1'u32
  regWrite(MACHW_INTC_BASE + 0x164'u, rate.uint32)
  let lenWord = (preambleFlag shl 24) or frameLen
  regWrite(MACHW_INTC_BASE + 0x160'u, lenWord)
  regWrite(MACHW_INTC_BASE + 0x168'u, 0x80000000'u32)
  if not waitRegMaskSet(MACHW_INTC_BASE + 0x168'u, 0x40000000'u32):
    return 500
  if (regRead(MACHW_INTC_BASE + 0x168'u) and 0x40000000'u32) == 0:
    assert_rec("hal_machw.c", "hal_machw.c", 249)
    return 500
  # mm.o:hal_machw_rx_duration+0xac samples the result after the ready check.
  return regRead(MACHW_INTC_BASE + 0x168'u) and 0xFFFF'u32

proc element_notify_status_enabled*(): uint32 {.exportc, cdecl.} =
  ## Check if element notification is enabled.
  ## From blob (2 instrs): always returns 0 (disabled).
  return 0

proc element_notify*(entry, arg1, arg2: pointer; operation: uint8): cint {.exportc, cdecl, discardable.} =
  ## The MM configuration callback logs the entry name and operation byte.
  ## Both opaque arguments are unused, and the vendor returns zero.
  if entry == nil:
    return 0
  let logFn = getLogFunc(204)
  if logFn != nil:
    let name = cast[cstring](cfgApiElementEntryAt(entry).name)
    logFn(1, nil, "mm.c", 1826, "[MM] %s is notfied, with ops %d\r\n",
          name, operation.cint)
  0

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

proc xor_halfwords*(dst: pointer, src: pointer, count: uint32) {.exportc: "xor", cdecl.} =
  ## The vendor helper counts 16-bit elements, not bytes.
  let sourceWords = cast[ptr UncheckedArray[uint16]](src)
  let destinationWords = cast[ptr UncheckedArray[uint16]](dst)
  for xorHalfwordIndex in 0'u32 ..< count:
    destinationWords[xorHalfwordIndex] =
      destinationWords[xorHalfwordIndex] xor sourceWords[xorHalfwordIndex]

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
  ## The second argument is the action category, not the frame subtype.
  if (frameCtrl and 0x0C'u32) != 0:
    return false
  let subtypeBits = frameCtrl and 0xF0'u32
  if subtypeBits == 0xA0'u32 or subtypeBits == 0xC0'u32:
    return true
  if subtypeBits == 0xD0'u32:
    if subtype <= 3:
      return true
    if subtype <= 15:
      let excludedCategories = 0x00008890'u32
      return ((1'u32 shl subtype) and excludedCategories) == 0
    return subtype != 127
  return false

proc mm_timer_hw_set*(timer: pointer) {.exportc, cdecl, noinline.} =
  ## Program or clear the MAC HW absolute timer.
  ## From blob (mm_timer.o, 22 instrs): if timer is nil, clears timer IRQ bit
  ## in INTC unmask register. If non-nil, writes timer->time (offset 12)
  ## to MACHW_ABS_TIMER_REG, then enables timer IRQ bit (0x80) in INTC.
  let saved = irqSave()
  defer: irqRestore(saved)
  # Callers can release IRQs between choosing a head and programming it.
  if cast[ptr CoListHdr](timer) != mm_timer_list.first:
    return
  if timer != nil:
    let revision = mmTimerRevision
    let expiry = mmTimerAt(timer).expiry
    nimFwTrace2U32("[WIFI-NIMFW] mm_timer_hw_set ", cast[uint32](cast[uint](timer)), expiry)
    if mmTimerRevision != revision:
      if mm_timer_list.first != cast[ptr CoListHdr](timer): return
      if mmTimerAt(timer).expiry != expiry: return
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
  ##   mm_env[13] = 0xFA0 (4000 = pre-TBTT duration)
  ## Then tail-calls mm_rx_filter_set().
  let mm = mmEnvView()
  discard c_memset(mm, 0, sizeof(MmEnvView).csize_t)
  mm.rxFilterBase = 0x7FFFFFDE'u32
  mm.idleFlag = 1
  mm.flagsHigh = 1
  mm.keepAliveInterval = 0x4E20'u32
  mm.keepAliveLimit = 10'u32
  mm.tbttPreDuration = 0xFA0'u32
  # Clear byte offsets 18 and 4 (blob: sh zero, 18(a5); sw zero, 4(a5))
  mm.previousState = 0
  mm.hardwareMode = 0
  mm.rxFilterExtra = 0
  mm_rx_filter_set()
  # Blob: tail-call mm_env_max_ampdu_duration_set
  mm_env_max_ampdu_duration_set(0)

proc mm_init*(): bool {.exportc, cdecl, discardable.} =
  ## Initialize the MAC Management module.
  ## From disassembly: calls 11 sub-init functions, then tail-calls
  ## ke_state_set(TASK_MM, MM_IDLE). Master init for the entire lower MAC.
  ## The 11 calls initialize all lower-MAC subsystems: environment, VIF/STA
  ## management, beacons, timers, TX (frame/cntrl/cfm/buffer), RX, and MAC HW.
  # Blob call order: hal_machw_init, mm_env_init, vif_mgmt_init, sta_mgmt_init,
  # td_init, ps_init, txl_cntrl_init, rxl_init, mm_timer_init, scan_init,
  # chan_init, mm_bcn_init (tail-call which does ke_state_set internally)
  nimFwTrace("[WIFI-NIMFW] hal_machw_init begin")
  if not hal_machw_init(): return false
  nimFwTrace("[WIFI-NIMFW] hal_machw_init done")
  nimFwTrace("[WIFI-NIMFW] mm_env_init begin")
  mm_env_init()
  nimFwTrace("[WIFI-NIMFW] mm_env_init done")
  nimFwTrace("[WIFI-NIMFW] vif_mgmt_init begin")
  if not vif_mgmt_init(): return false
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
  if not rxl_init(): return false
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
  true

proc mm_active*() {.exportc, cdecl.} =
  ## Transition MM and MAC HW to active state.
  ## From disassembly: writes 0x30 to MACHW_STATE_CNTRL_REG (0x24B00038),
  ## then tail-calls ke_state_set(TASK_MM, MM_ACTIVE_STATE).
  mmConfigCancelIdle()
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
    # The reset left the MAC idle, so a configuration request that was
    # waiting for the idle interrupt can now run and restore the saved state.
    if mmConfigIdle.phase == mmConfigAwaitIdle:
      mmConfigIdle.phase = mmConfigIdleReady
    ke_state_set(TASK_MM, MM_IDLE.uint16)

proc mm_env_max_ampdu_duration_set*(duration: uint32) {.exportc, cdecl.} =
  ## Cache EDCA bits 27..12 as A-MPDU duration limits. Zero and values over
  ## 150 use the default limit; the VO limit is also used for beacons.
  let mm = mmEnvView()
  template readTxop(regAddr: uint): uint16 =
    ((volatileLoad(cast[ptr uint32](regAddr)) shr 12) and 0xFFFF'u32).uint16

  template computeDuration(regAddr: uint): uint16 =
    block:
      var dOut {.gensym.}: uint16 = 150'u16
      # Vendor rereads for the nonzero check, upper bound, and stored value.
      if readTxop(regAddr) != 0 and readTxop(regAddr) <= 150'u16:
        dOut = readTxop(regAddr)
      dOut
  # AC_BK/BE/VI/VO durations cached in mm_env halfwords at offsets 8..16.
  mm.edcaBkDur = computeDuration(MACHW_EDCA_AC_BK_REG)
  mm.edcaBeDur = computeDuration(MACHW_EDCA_AC_BE_REG)
  mm.edcaViDur = computeDuration(MACHW_EDCA_AC_VI_REG)
  let dVO = computeDuration(MACHW_EDCA_AC_VO_REG)
  mm.edcaVoDur = dVO
  mm.edcaBcnDur = dVO

proc mmEdcaOwner(): ptr VifChannelView =
  ## The four registers belong to the current operating context, not a VIF,
  ## while no switch is under way. Its status does not matter: after a lone
  ## context's operation timer it is 1 (chan.o chan_ctxt_op_evt), still tuned.
  let env = chanEnvView()
  let current = env.currentCtxt
  if current == nil or env.scheduledCtxt != nil or
      chanCtxtAt(current).contextIndexOrMarker > 2:
    return nil
  var link = cast[pointer](vifMgmtEnvView().activeList.first)
  while link != nil:
    let vif = vifChannelAt(link)
    if vif.chanCtxt == current and vif.state != 0:
      if result != nil: return nil
      result = vif
    link = vif.next

proc mmEdcaWord(vif: ptr VifChannelView; queue: int): uint32 {.inline.} =
  vif.edcaRegs[if vif.vifType in [VIF_TYPE_STA, VIF_TYPE_AP]: queue else: 3]

proc mmProgramEdca(vif: ptr VifChannelView) =
  for queue in 0 ..< 4:
    regWrite(MACHW_EDCA_AC_BK_REG + 4'u * queue.uint, mmEdcaWord(vif, queue))
  mm_env_max_ampdu_duration_set(0)

proc mmReplayEdca() =
  let saved = irqSave()
  defer: irqRestore(saved)
  let vif = mmEdcaOwner()
  if vif != nil: mmProgramEdca(vif)

proc mmEdcaRefreshCurrent(): bool =
  let i = mmEdcaRefresh.vif
  i < MAX_VIFS.uint8 and
    rxVifEpochs[i] == mmEdcaRefresh.vifEpoch and
    chanCtxtLinkEpochs[i] == mmEdcaRefresh.bindingEpoch and
    mmEdcaRefresh.context == chanEnvView().currentCtxt and
    mmEdcaOwner() == vifChannelForIdx(i)

proc mmRequestStaEdcaRefresh(vif: ptr VifChannelView) =
  ## Request one idle transition for all four words. An unchanged beacon can
  ## retry a missed allocation; a channel switch can apply the shadow first.
  let saved = irqSave()
  defer: irqRestore(saved)
  if mmEdcaRefresh.message != nil: return
  if vif == nil or vif.vifIdx >= MAX_VIFS.uint8 or mmEdcaOwner() != vif: return
  var changed = false
  for queue in 0 ..< 4:
    if regRead(MACHW_EDCA_AC_BK_REG + 4'u * queue.uint) != vif.edcaRegs[queue]:
      changed = true
      break
  if not changed: return
  let i = vif.vifIdx
  let vifEpoch = rxVifEpochs[i]
  let bindingEpoch = chanCtxtLinkEpochs[i]
  let resetEpoch = txResetEpoch
  let context = vif.chanCtxt
  let request = ke_msg_try_alloc(MM_SET_EDCA_REQ, TASK_MM, TASK_MM, 0)
  if request == nil: return
  let header = cast[pointer](keMsgHdrFromPayload(request))
  if rxVifEpochs[i] != vifEpoch or chanCtxtLinkEpochs[i] != bindingEpoch or
      context != vif.chanCtxt or txResetEpoch != resetEpoch or
      mmEdcaRefresh.message != nil or
      mmEdcaOwner() != vif:
    ke_msg_free(header)
    return
  mmEdcaRefresh = (header, context, i, vifEpoch, bindingEpoch)
  ke_msg_send(request)

proc mm_cfg_element_keepalive_timestamp_update*() {.exportc, cdecl.} =
  ## Update keep-alive timestamp to current time (14 instrs).
  ## From blob: calls g_bl_ops_funcs[0xC8] (platform get_time), stores result
  ## in mm_env word at offset 40 (mm_env[10]), increments mm_env word at offset 36
  ## (mm_env[9] = keep-alive counter).
  let saved = irqSave()
  defer: irqRestore(saved)
  if txlResetting(): return
  let resetEpoch = txResetEpoch
  let mm = mmEnvView()
  let previousCount = mm.keepAliveCounter
  let getTimeFn = cast[proc(): uint32 {.cdecl, raises: [Exception].}](blOpsFunc(0xC8))
  if getTimeFn == nil: return
  var now: uint32
  irqRestore(saved)
  try: now = getTimeFn()
  finally: discard irqSave()
  if txlResetting() or txResetEpoch != resetEpoch: return
  # Store timestamp at mm_env offset 40 (word 10)
  # A nested update has a newer sample; still count this received frame.
  if mm.keepAliveCounter == previousCount:
    mm.keepAliveTimestamp = now
  # Increment counter at mm_env offset 36 (word 9)
  mm.keepAliveCounter = mm.keepAliveCounter + 1

proc mmCaptureVif(vifEntry: pointer): MmVifIdentity =
  for candidate in 0'u8 ..< MAX_VIFS.uint8:
    let vif = vifChannelForIdx(candidate)
    if cast[pointer](vif) == vifEntry and vif.vifIdx == candidate:
      return MmVifIdentity(vif: vifEntry, index: candidate,
        epoch: rxVifEpochs[candidate], station: vif.staIdx,
        stationEpoch: staDeleteEpoch(vif.staIdx), captured: true)

proc mmVifCurrent(identity: MmVifIdentity): bool =
  identity.captured and identity.index < MAX_VIFS.uint8 and
    rxVifEpochs[identity.index] == identity.epoch and
    cast[pointer](vifChannelForIdx(identity.index)) == identity.vif and
    vifChannelForIdx(identity.index).vifIdx == identity.index and
    vifChannelForIdx(identity.index).staIdx == identity.station and
    staDeleteEpoch(identity.station) == identity.stationEpoch

proc mmConnLossTagAt(message: pointer): ptr MmConnLossTag =
  const mask = alignof(MmConnLossTag).uint - 1
  let start = cast[uint](message) + MmConnectionLossIndPayloadSize.uint +
    KeMsgTailSlack.uint
  cast[ptr MmConnLossTag]((start + mask) and not mask)

proc mmConnLossForget(header: pointer) =
  let saved = irqSave()
  defer: irqRestore(saved)
  var link = addr mmConnLossTags
  while link[] != nil:
    if link[].header == header:
      link[] = link[].next
      return
    link = addr link[].next

proc mmConnLossProbeEpoch(reason: uint16; vif: uint8): uint32 {.inline.} =
  # A beacon proves downlink liveness, not that the AP ACKed our traffic.
  if reason == 22: mmTrafficProbeEpochs[vif] else: mmBeaconProbeEpochs[vif]

proc mmConnLossTagFor(message: pointer): ptr MmConnLossTag =
  let header = keMsgHdrFromPayload(message)
  if header.id != MM_CONNECTION_LOSS_IND or header.destId != TASK_SM or
      header.srcId != TASK_MM or
      header.paramLen != MmConnectionLossIndPayloadSize:
    return nil
  var tag = mmConnLossTags
  while tag != nil:
    if tag.header == cast[pointer](header):
      let ind = mmConnectionLossIndView(message)
      if tag.consumed or
          ind.vifIdx != tag.identity.index or ind.reason != tag.reason or
          not mmVifCurrent(tag.identity) or
          (tag.tracksProbe and mmConnLossProbeEpoch(tag.reason, tag.identity.index) != tag.probeEpoch):
        return nil
      return tag
    tag = tag.next

proc mmPublishConnectionLoss(vifEntry: pointer; reason: uint16;
                             probeEpoch: ptr uint32) {.noinline.} =
  inc nimFwDbgConnLossInd
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let saved = irqSave()
  defer: irqRestore(saved)
  let identity = mmCaptureVif(vifEntry)
  let resetEpoch = txResetEpoch
  let tracksProbe = probeEpoch != nil
  let expectedProbe = if tracksProbe: probeEpoch[] else: 0'u32
  template current(): bool =
    mmVifCurrent(identity) and txResetEpoch == resetEpoch and
      (not tracksProbe or mmConnLossProbeEpoch(reason, identity.index) == expectedProbe)
  if not current(): return
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  var ind: ptr MmConnectionLossIndPayload
  outside:
    const alignment = alignof(MmConnLossTag).uint32
    const storageLength = MmConnectionLossIndPayloadSize + KeMsgTailSlack +
      alignment - 1 + sizeof(MmConnLossTag).uint32
    ind = cast[ptr MmConnectionLossIndPayload](
      ke_msg_alloc(MM_CONNECTION_LOSS_IND, TASK_SM, TASK_MM,
                   storageLength))
  if ind == nil: return
  if not current():
    outside: ke_msg_free_payload(ind)
    return
  let header = keMsgHdrFromPayload(ind)
  header.paramLen = MmConnectionLossIndPayloadSize
  ind.reason = reason
  ind.vifIdx = identity.index
  let tag = mmConnLossTagAt(ind)
  tag[] = MmConnLossTag(next: mmConnLossTags, header: cast[pointer](header),
    identity: identity, reason: reason,
    tracksProbe: tracksProbe, probeEpoch: expectedProbe)
  mmConnLossTags = tag
  outside: ke_msg_send(ind)

proc mm_send_connection_loss_ind*(vifEntry: pointer, reason: uint16) {.exportc, cdecl, noinline.} =
  ## Report connection loss without a TBTT probe freshness requirement.
  mmPublishConnectionLoss(vifEntry, reason, nil)

proc mm_ps_change_ind*(staIdx: uint8, psState: uint8) {.exportc, cdecl.} =
  ## Send MM_PS_CHANGE_IND to host and mirror the state in sta_info_tab.
  let saved = irqSave()
  defer: irqRestore(saved)
  if staIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return
  let sta = staInfoForIdx(staIdx)
  let identity = apmPsCapture(sta)
  if not apmPsSessionCurrent(identity):
    return
  let previousMode = sta.psMode
  let ind = cast[ptr MmPsChangeIndPayload](
    ke_msg_alloc(MM_PS_CHANGE_IND, TASK_API, TASK_MM,
                 MmPsChangeIndPayloadSize))
  if not apmPsSessionCurrent(identity) or sta.psMode != previousMode:
    if ind != nil:
      ke_msg_free_payload(ind)
    return
  sta.psMode = psState
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
  if vifIdx >= MAX_VIFS.uint8 or (ie == nil and ieLen != 0):
    return
  inc nimFwDbgWpaRsnIeSet
  nimFwDbgWpaRsnIeLen = ieLen.uint32
  nimFwDbgWpaRsnIePtr = cast[uint32](ie)
  let vif = vifChannelForIdx(vifIdx)
  let sec = vifSecurity(vif)
  sec.rsnIePtr = cast[uint32](ie)
  sec.rsnIeLen = ieLen

proc mm_force_idle_req*(): bool {.exportc, cdecl, discardable.} =
  ## Force MAC HW to idle state (23 instrs).
  ## Return false without publishing completion if a hardware wait fails.
  ## From blob: saves/disables interrupts, calls hal_machw_reset, rxl_reset,
  ## txl_reset, then ke_state_set(TASK_MM, HW_ACTIVE=3). Clears mm_env halfword
  ## at offset 0x12 to zero. Restores interrupts.
  let saved = irqSave()
  defer: irqRestore(saved)
  if not hal_machw_reset(): return false
  # A forced idle takes over from any configuration request waiting for idle.
  mmConfigCancelIdle()
  if not rxl_reset(): return false
  if not txl_reset(): return false
  ke_state_set(TASK_MM, HW_ACTIVE.uint16)
  let mm = mmEnvView()
  mm.previousState = 0
  mm.hardwareMode = 0
  true

proc mm_back_to_host_idle*() {.exportc, cdecl.} =
  ## Transition back to host-controlled idle state (27 instrs).
  ## From blob: calls ke_state_get(TASK_MM), asserts result == HW_ACTIVE (3).
  ## If mm_env byte at offset 0x1a is nonzero, calls ke_state_set(TASK_MM, MM_IDLE=0).
  ## Otherwise tail-calls mm_active().
  let state = ke_state_get(TASK_MM)
  if state != HW_ACTIVE.uint16:
    assert_err("mm.c", "mm.c", 1470)
    # The Nim assertion schedules recovery instead of halting forever.
    return
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
  let saved = irqSave()
  defer: irqRestore(saved)
  ke_evt_clear(KE_EVT_IDLE)
  if ke_state_get(TASK_MM) != MM_GOING_TO_IDLE.uint16 or
      (ke_evt_field_get() and 0x80000000'u32) != 0:
    return
  if mmConfigIdle.phase == mmConfigAwaitIdle:
    mmConfigIdle.phase = mmConfigIdleReady
  ke_state_set(TASK_MM, MM_IDLE.uint16)
  mmConfigResumeAbandonedIdle()

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
  regWrite(0x24B00010'u32, addrView.lowLe)
  regWrite(0x24B00014'u32, addrView.highLe)
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

type
  MmStaKeyPlan = object
    mode: uint8
    boundToConnection: bool
    callback, connection: pointer
    wpa: WpaKeyWriteParamView
    wep: WepKeyWriteParamView

  MmStaDeletion = object
    owner: StaQueueIdentity
    requestEpoch: uint32
    keys: array[4, uint8]
    keyPending: array[4, bool]
    active, running, staMode, apEffectsDone, addressDeleted, requestOwned: bool

var
  mmStaDeletions {.wifiCtrl.}: array[STA_MGMT_FREE_STAS, MmStaDeletion]
  mmStaDelRetryMask {.wifiCtrl.}: uint8
  mmStaDelRetryEpochs {.wifiCtrl.}: array[STA_MGMT_FREE_STAS, uint32]
  mmStaDelRetryReset {.wifiCtrl.}: uint32
  mmStaDelRetryTimer {.wifiCtrl.}: MmTimerView

proc mmStaDelTrackUnpublished(owner: StaQueueIdentity)

proc mmKeyHexDigit(ch: uint8): int {.inline.} =
  if ch >= 0x30 and ch <= 0x39: ch.int - 0x30
  elif ch >= 0x41 and ch <= 0x46: ch.int - 0x41 + 10
  elif ch >= 0x61 and ch <= 0x66: ch.int - 0x61 + 10
  else: -1

proc mmPrepareStaKeys(vif: ptr VifChannelView; quickConn: uint8;
                      plan: var MmStaKeyPlan): bool =
  plan = default(MmStaKeyPlan)
  let security = vifSecurity(vif)
  if vif.vifType != VIF_TYPE_STA or security.connected == 0:
    return true
  let sm = smEnvView()
  plan.boundToConnection = true
  plan.connection = sm.connectInfo
  if sm.state == 2:
    if wps_cbs != nil:
      plan.callback = wpsCallbacks().staConnected
    plan.mode = 1
    return true
  let cipher = security.cipher
  if cipher == 0:
    return true
  if cipher > 4:
    return false
  if plan.connection == nil:
    return false
  let payloadLength = keMsgHdrFromPayload(plan.connection).paramLen
  const keyOffset = offsetof(ConnectInfoCredentialOverlay, keyString).uint32
  if payloadLength <= keyOffset:
    return false
  let credentials = connectInfoCredentials(plan.connection)
  let available = min(payloadLength - keyOffset, credentials.keyString.len.uint32)
  var keyLength = 0
  while keyLength < available.int and credentials.keyString[keyLength] != 0:
    inc keyLength
  if cipher >= 2:
    if wpa_cbs == nil or wpaCallbacks().keyWrite == nil:
      return false
    let ssidLength = vif.supportedRatesLong[0].int
    if ssidLength > 32:
      return false
    plan.mode = 2
    plan.callback = wpaCallbacks().keyWrite
    plan.wpa.vifIdx = vif.vifIdx
    plan.wpa.keyDataLen = ssidLength.uint32
    plan.wpa.quickConn = quickConn
    for i in 0 ..< ssidLength:
      plan.wpa.keyMaterial[i] = vif.supportedRatesLong[i + 1]
    const pmkOffset = offsetof(ConnectInfoCredentialOverlay, altSsid).uint32
    let hasPmk = payloadLength > pmkOffset and credentials.altSsid[0] != 0
    if hasPmk:
      if payloadLength - pmkOffset < plan.wpa.ssid.len.uint32:
        return false
      for i in 0 ..< plan.wpa.ssid.len:
        plan.wpa.ssid[i] = credentials.altSsid[i]
    else:
      if keyLength == available.int and available < 64:
        return false
      for i in 0 ..< keyLength:
        plan.wpa.ssid[i] = credentials.keyString[i]
    # Both 64-byte sources must represent a hex PMK if they fill the field.
    let passphraseLength = if hasPmk: 64 else: keyLength
    if passphraseLength == 64:
      for ch in plan.wpa.ssid:
        if mmKeyHexDigit(ch) < 0:
          return false
    return true
  if keyLength == available.int or keyLength notin [5, 10, 13, 26]:
    return false
  plan.mode = 3
  plan.wep.selector = 0xFF00
  plan.wep.instNbr = vif.vifIdx
  plan.wep.cipherMode = if keyLength in [13, 26]: 3 else: 0
  if keyLength in [5, 13]:
    plan.wep.keyLen = keyLength.uint8
    for i in 0 ..< keyLength:
      plan.wep.keyData[i] = credentials.keyString[i]
  else:
    plan.wep.keyLen = (keyLength div 2).uint8
    for i in 0 ..< keyLength div 2:
      let hi = mmKeyHexDigit(credentials.keyString[i * 2])
      let lo = mmKeyHexDigit(credentials.keyString[i * 2 + 1])
      if hi < 0 or lo < 0:
        return false
      plan.wep.keyData[i] = ((hi shl 4) or lo).uint8
  true

proc mmStaAddCurrent(vifIdx: uint8; vifEpoch: uint32;
                     staIdx: uint8; stationEpoch: uint32): bool =
  if vifIdx >= MAX_VIFS.uint8 or staIdx >= STA_MGMT_FREE_STAS.uint8 or
      rxVifEpochs[vifIdx] != vifEpoch or not staDeleteIsCurrent(staIdx, stationEpoch):
    return false
  staInfoForIdx(staIdx).instNbr == vifIdx

proc mm_sta_add*(param: pointer, staIdxOut: ptr uint8, hwStaIdxOut: ptr uint8): uint8 {.exportc, cdecl.} =
  ## Snapshot requests and keys before callouts; publish outputs only on success.
  if param == nil or staIdxOut == nil or hwStaIdxOut == nil:
    return 1
  staIdxOut[] = 0xFF
  hwStaIdxOut[] = 0xFF
  let saved = irqSave()
  defer: irqRestore(saved)
  var request = mmStaAddReqView(param)[]
  let instNbr = request.vifIdx
  if instNbr >= MAX_VIFS.uint8:
    return 1
  let vif = vifChannelForIdx(instNbr)
  let vifEpoch = rxVifEpochs[instNbr]
  let guarded = vif.vifType == VIF_TYPE_STA
  if guarded and mmStaAddInProgress[instNbr] and mmStaAddVifEpoch[instNbr] == vifEpoch:
    return 1
  let previousActive = mmStaAddInProgress[instNbr]
  let previousEpoch = mmStaAddVifEpoch[instNbr]
  if guarded:
    mmStaAddInProgress[instNbr] = true
    mmStaAddVifEpoch[instNbr] = vifEpoch
  defer:
    if guarded:
      mmStaAddInProgress[instNbr] = previousActive
      mmStaAddVifEpoch[instNbr] = previousEpoch
  var stationEpochs: array[STA_MGMT_FREE_STAS, uint32]
  for i in 0 ..< stationEpochs.len:
    stationEpochs[i] = staDeleteEpoch(i.uint8)
  var keys: MmStaKeyPlan
  if not mmPrepareStaKeys(vif, request.quickConn, keys):
    return 1

  inc nimFwDbgPreauthStaAddEntry
  nimFwDbgPreauthStaAddMeta = instNbr.uint32 or (vif.staIdx.uint32 shl 8) or
    (vif.vifType.uint32 shl 16) or (vifSecurity(vif).connected.uint32 shl 24)
  var staIdx = 0xFF'u8
  let status = sta_mgmt_register(addr request, addr staIdx)
  if status != 0:
    nimFwDbgPreauthStaAddResult = status.uint32 or 0x80000000'u32
    return status
  if staIdx >= STA_MGMT_FREE_STAS.uint8:
    return 1
  let stationEpoch = stationEpochs[staIdx.int]
  template current(): bool =
    mmStaAddCurrent(instNbr, vifEpoch, staIdx, stationEpoch) and
      (not keys.boundToConnection or smEnvView().connectInfo == keys.connection)
  template abortOwned(): uint8 =
    if mmStaAddCurrent(instNbr, vifEpoch, staIdx, stationEpoch):
      var removal: StaQueueIdentity
      if staMgmtBeginRemoval(staIdx, removal) != nil:
        mmStaDelTrackUnpublished(removal)
    1'u8
  if not current():
    return abortOwned()

  let hwIdx = mm_sec_machwaddr_wr(staIdx, cast[pointer](instNbr.uint), 0)
  if hwIdx == 0xFF:
    # The write may have timed out after submission. Keep this slot retired
    # until its hardware address is confirmed clear, so a late write cannot
    # bind the next station allocated at the same index.
    return abortOwned()
  if not current():
    return abortOwned()
  case keys.mode
  of 1:
    if keys.callback != nil:
      cast[proc(vif, station: uint8) {.cdecl.}](keys.callback)(instNbr, staIdx)
  of 2:
    keys.wpa.staIdx = staIdx
    for i in 0 ..< 3:
      vifSecurity(vif).staKeySlots[i] = 0xFF
    # The shim checks the built-in setup without changing the callback ABI.
    if bl808WpaStaConnectResult(keys.callback, addr keys.wpa) != 0:
      return abortOwned()
  of 3:
    vifSecurity(vif).staKeySlots[3] = 0xFF
    let keyIndex = mm_sec_machwkey_wr(addr keys.wep)
    if not current():
      return abortOwned()
    if keyIndex == 0xFF:
      return abortOwned()
    vifSecurity(vif).staKeySlots[3] = keyIndex
  else:
    discard
  if not current():
    return abortOwned()
  if vif.vifType == VIF_TYPE_STA:
    vif.staIdx = staIdx
  staIdxOut[] = staIdx
  hwStaIdxOut[] = hwIdx
  inc nimFwDbgPreauthStaAddExit
  nimFwDbgPreauthStaAddResult = staIdx.uint32 or (hwIdx.uint32 shl 8) or
    (vif.staIdx.uint32 shl 16) or 0x01000000'u32
  0

proc mmStaDelRetryCb(env: pointer) {.cdecl.}

proc mmStaDelRetryPending(staIdx: uint8): bool {.inline.} =
  staIdx < STA_MGMT_FREE_STAS.uint8 and
    (mmStaDelRetryMask and (1'u8 shl staIdx)) != 0 and
    mmStaDelRetryEpochs[staIdx] == staDeleteEpoch(staIdx)

proc mmStaDelQueueRetryLocked(staIdx: uint8; saved: uint32) =
  if staIdx >= STA_MGMT_FREE_STAS.uint8: return
  let hadPending = mmStaDelRetryMask != 0
  mmStaDelRetryEpochs[staIdx] = staDeleteEpoch(staIdx)
  mmStaDelRetryMask = mmStaDelRetryMask or (1'u8 shl staIdx)
  if hadPending: return
  mmStaDelRetryTimer.callback = cast[pointer](mmStaDelRetryCb)
  mmStaDelRetryTimer.env = 0
  mmTimerSetLocked(addr mmStaDelRetryTimer, macTimeNow() + 100_000'u32, saved)

proc mmStaDelTry(staIdx: uint8; saved: uint32): bool =
  ## Keep the retired slot and its original VIF/key identity across HW timeouts.
  ## The caller holds IRQs from identity validation through retry publication.
  if staIdx >= STA_MGMT_FREE_STAS.uint8: return true
  let deletion = addr mmStaDeletions[staIdx]
  if deletion.running: return false
  deletion.running = true
  if deletion.active:
    if not staRemovalCurrent(deletion.owner):
      let oldOwner = deletion.owner
      let sta = staInfoAt(oldOwner.entry)
      if sta.valid == 0 and sta.instNbr == oldOwner.vif and
          rxVifEpochs[oldOwner.vif] == oldOwner.vifEpoch and
          not co_list_find(addr sta_info_env, cast[ptr CoListHdr](oldOwner.entry)):
        deletion.owner.stationEpoch = staDeleteEpoch(staIdx)
      else:
        deletion[] = default(MmStaDeletion)
        mmStaDelRetryMask = mmStaDelRetryMask and not (1'u8 shl staIdx)
        return true
  else:
    var owner: StaQueueIdentity
    let staEntry = staMgmtBeginRemoval(staIdx, owner)
    if staEntry == nil:
      deletion.running = false
      # Retry only a station still on its VIF's list (the TX halt failed).
      # One whose VIF was removed is on no list (vif_mgmt_unregister cleared
      # it) and cannot be removed: it stays valid, as every station of a
      # removed VIF, and the delete is done instead of retried for ever.
      let station = staInfoForIdx(staIdx)
      return station.valid == 0 or station.instNbr >= MAX_VIFS.uint8 or
        not co_list_find(vifPostponedStaList(vifChannelForIdx(station.instNbr)),
                         cast[ptr CoListHdr](station))
    deletion[] = MmStaDeletion(owner: owner, requestEpoch: owner.stationEpoch - 1'u32,
                               active: true, running: true, requestOwned: true)
    let vif = vifChannelForIdx(owner.vif)
    deletion.staMode = vif.vifType == VIF_TYPE_STA
    if deletion.staMode:
      let sec = vifSecurity(vif)
      if sec.connected != 0:
        let slots = if sec.cipher in 2'u8 .. 4'u8: 3
                    elif sec.cipher == 1: 4
                    else: 0
        for slot in 0 ..< slots:
          if slots == 4 and slot != 3: continue
          deletion.keys[slot] = sec.staKeySlots[slot]
          deletion.keyPending[slot] = sec.staKeySlots[slot] != 0xFF
  let owner = deletion.owner
  let sta = staInfoAt(owner.entry)
  template sameDeletion(): bool =
    deletion.active and deletion.owner.entry == owner.entry and
      deletion.owner.stationEpoch == owner.stationEpoch and
      deletion.owner.vifEpoch == owner.vifEpoch
  defer:
    if sameDeletion(): deletion.running = false
  template current(): bool = sameDeletion() and staRemovalCurrent(owner)
  template superseded(): bool =
    if sameDeletion(): deletion[] = default(MmStaDeletion)
    true
  template outsideLock(call: untyped): untyped =
    block:
      irqRestore(saved)
      try:
        call
      finally:
        discard irqSave()
  if not current():
    return superseded()

  let vifIdx = owner.vif
  let vif = vifChannelForIdx(vifIdx)
  var keysRemoved = true

  if not deletion.staMode and not deletion.apEffectsDone:
    deletion.apEffectsDone = true
    let connStatus = sta.psMode
    if connStatus == 1:
      let rcFlags = vif.psBaCounter
      let newFlags = if rcFlags == 0: 0'u8 else: rcFlags - 1
      vif.psBaCounter = newFlags
      if newFlags == 0:
        let bcmcStaIdx = owner.vif + STA_MGMT_FREE_STAS.uint8
        let msg = cast[ptr MmPsChangeIndPayload](
          outsideLock(ke_msg_alloc(MM_PS_CHANGE_IND, TASK_API, TASK_MM,
                                  MmPsChangeIndPayloadSize)))
        if not current():
          if msg != nil:
            outsideLock(ke_msg_free(keMsgHdrFromPayload(msg)))
          return superseded()
        staInfoForIdx(bcmcStaIdx).psMode = 0
        if msg != nil:
          msg.staIdx = bcmcStaIdx
          msg.psState = 0
          outsideLock(ke_msg_send(msg))
          if not current():
            return superseded()
        apm_tx_int_ps_clear(cast[pointer](vif), bcmcStaIdx)
        if not current():
          return superseded()
  else:
    if deletion.staMode:
      if vif.staIdx == staIdx: vif.staIdx = 0xFF
      let sec = vifSecurity(vif)
      for slot in 0 ..< deletion.keyPending.len:
        if not deletion.keyPending[slot]: continue
        let keyVal = deletion.keys[slot]
        let deleted = mmDeleteSecurityKey(keyVal)
        if not current(): return superseded()
        if deleted:
          deletion.keyPending[slot] = false
          if sec.staKeySlots[slot] == keyVal:
            sec.staKeySlots[slot] = 0xFF
        else:
          keysRemoved = false

  if keysRemoved and not deletion.addressDeleted:
    let deleted = mmDeleteSecurityAddress(staIdx)
    if not current(): return superseded()
    if deleted: deletion.addressDeleted = true
  if keysRemoved and deletion.addressDeleted:
    let finished = outsideLock(staMgmtFinishRemoval(owner))
    if finished:
      if sameDeletion():
        deletion[] = default(MmStaDeletion)
        mmStaDelRetryMask = mmStaDelRetryMask and not (1'u8 shl staIdx)
      return true
  false

proc mmStaDelTrackUnpublished(owner: StaQueueIdentity) =
  if not owner.stationTracked or owner.station >= STA_MGMT_FREE_STAS.uint8:
    return
  let saved = irqSave()
  defer: irqRestore(saved)
  let deletion = addr mmStaDeletions[owner.station]
  if not staRemovalCurrent(owner) or deletion.active:
    return
  deletion[] = MmStaDeletion(owner: owner, requestEpoch: owner.stationEpoch - 1'u32,
                             active: true, apEffectsDone: true)
  if not mmStaDelTry(owner.station, saved):
    mmStaDelQueueRetryLocked(owner.station, saved)

proc mm_sta_del*(staIdx: uint8) {.exportc, cdecl.} =
  let saved = irqSave()
  defer: irqRestore(saved)
  if not mmStaDelTry(staIdx, saved): mmStaDelQueueRetryLocked(staIdx, saved)

proc mmStaDelRetryCb(env: pointer) {.cdecl.} =
  let (pending, epochs, reset) = block:
    let saved = irqSave()
    defer: irqRestore(saved)
    let delivery = mmTimerActiveDelivery(addr mmStaDelRetryTimer)
    if delivery != nil and delivery.cancelled: return
    let mask = mmStaDelRetryMask
    mmStaDelRetryMask = 0
    (mask, mmStaDelRetryEpochs, mmStaDelRetryReset)
  # A retry can rearm this timer; only MM reinitialization cancels the batch.
  for staIdx in 0'u8 ..< STA_MGMT_FREE_STAS.uint8:
    if (pending and (1'u8 shl staIdx)) == 0: continue
    let saved = irqSave()
    defer: irqRestore(saved)
    if mmStaDelRetryReset != reset: return
    if staDeleteEpoch(staIdx) == epochs[staIdx] and not mmStaDelTry(staIdx, saved) and
        mmStaDelRetryReset == reset:
      mmStaDelQueueRetryLocked(staIdx, saved)
  let saved = irqSave()
  defer: irqRestore(saved)
  if mmStaDelRetryReset == reset: discard ke_reschedule_saved_messages(TASK_MM)

proc mm_check_rssi*(vifEntry: pointer, newRssi: int8) {.exportc, cdecl.} =
  ## Report periodic RSSI samples and hysteretic threshold transitions.
  let saved = irqSave()
  defer: irqRestore(saved)
  let identity = mmCaptureVif(vifEntry)
  let resetEpoch = txResetEpoch
  if not mmVifCurrent(identity): return
  let vif = vifChannelAt(vifEntry)
  let oldRssi = vif.rssiLast
  vif.rssiLast = newRssi
  let macTime = macTimeNow()
  let threshold = vif.rssiThreshold
  let hysteresis = vif.rssiHysteresis
  let previousState = vif.rssiState
  var expectedState = previousState
  let rssiTimer = mmRssiLastReportTime()
  let lastReportTime = rssiTimer[]
  template current(): bool =
    txResetEpoch == resetEpoch and mmVifCurrent(identity) and
      vif.rssiLast == newRssi and vif.rssiThreshold == threshold and
      vif.rssiHysteresis == hysteresis and vif.rssiState == expectedState
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  template report(state: uint8; periodic: static bool) =
    var msg: ptr MmRssiStatusIndPayload
    outside:
      msg = cast[ptr MmRssiStatusIndPayload](
        ke_msg_alloc(0x43, 9, 0, MmRssiStatusIndPayloadSize))
    if msg == nil: return
    if not current():
      outside: ke_msg_free_payload(msg)
      return
    msg.vifIdx = identity.index
    msg.thresholdState = state
    msg.rssiDbm = newRssi.uint8
    when periodic:
      # A nested report on another VIF must not move the shared clock back.
      if rssiTimer[] == lastReportTime:
        rssiTimer[] = macTime
    else:
      # Publish the state before a notification can synchronously re-enter.
      vif.rssiState = state
      expectedState = state
    outside: ke_msg_send(msg)
    if not current(): return

  if oldRssi == 0 or macTime - lastReportTime > 2_000_000'u32:
    report(previousState, true)
  if threshold == 0: return
  var newState = previousState
  let magnitude = cast[int8](hysteresis).int32
  if previousState == 0:
    if newRssi < oldRssi:
      newState = (newRssi.int32 < threshold.int32 - magnitude).uint8
  elif newRssi > oldRssi:
    newState = (newRssi.int32 <= threshold.int32 + magnitude).uint8
  if newState != previousState:
    report(newState, false)

proc mmResetBeaconProbeCount(vif: ptr VifChannelView) =
  let saved = irqSave()
  defer: irqRestore(saved)
  vif.probeCount = 0
  if vif.vifIdx < MAX_VIFS.uint8:
    inc mmBeaconProbeEpochs[vif.vifIdx]

proc mmCheckBeaconFrame(param, vifEntry, staEntry, frameData: pointer;
                        timOut: var pointer): uint32 =
  ## Process a received beacon frame (290 instructions in blob).
  ##
  ## The exported wrapper below preserves the vendor's TIM-pointer ABI.
  ## 14 function calls: mm_check_rssi, 2x hal_machw_rx_duration,
  ## utils_crc32_stream_init/feed_block/results, __udivdi3,
  ## mm_timer_set, mm_timer_clear, mac_ie_find, mm_send_connection_loss_ind,
  ## txl_frame_send_null_frame, indirect log call.
  ## Returns high(uint32) when frame admission fails; 0 means an unchanged
  ## valid beacon, and 1 means its non-TIM fingerprint changed.

  template rejectBeacon() = return high(uint32)

  timOut = nil
  if param == nil or vifEntry == nil or staEntry == nil or frameData == nil:
    rejectBeacon()
  let frameIdentity = rxCaptureFrameHeader(param, vifEntry, staEntry)
  template requireFrame() =
    if not rxFrameCurrent(frameIdentity):
      timOut = nil
      return
  requireFrame()

  let rx = beaconRxDescView(param)
  let vif = vifChannelAt(vifEntry)
  let sta = staInfoAt(staEntry)

  # Timing metadata still comes from DMA; the caller owns the contiguous bytes.
  let frame = beaconFrameFixedView(frameData)

  let frameLen = rx.frameLen
  if frameLen.uint32 < sizeof(BeaconFrameFixedView).uint32: rejectBeacon()
  let bcnInterval = frame.beaconInterval
  if bcnInterval == 0: rejectBeacon()
  let ieBodyLen = frameLen.uint32 - sizeof(BeaconFrameFixedView).uint32
  let ieBody = beaconFrameIeBody(frame)

  # The vendor reads DS and TIM payloads after finding only their IE IDs.
  # Admit the complete IE stream before callbacks can publish beacon state.
  var ieCursor = cast[uint](ieBody)
  if ieBodyLen.uint > high(uint) - ieCursor: rejectBeacon()
  var ieRemaining = ieBodyLen
  while ieRemaining != 0:
    if ieRemaining < 2: rejectBeacon()
    let ie = macIeAt(ieCursor)
    let size = ie.len.uint32 + 2'u32
    if size > ieRemaining: rejectBeacon()
    if (ie.id == 3 and ie.len != 1) or (ie.id == 5 and ie.len < 4):
      rejectBeacon()
    ieCursor += size.uint
    ieRemaining -= size

  # Step 2: CSA check - if vif_entry[64] (CSA ctx ptr) nonzero, parse DS Param IE (id=3)
  let csaCtxPtr = vif.chanCtxt
  if csaCtxPtr != nil:
    # Blob calls mac_ie_find(ieBody, ieBodyLen, 3) for DS Parameter Set
    let dsIe = mac_ie_find(ieBody, ieBodyLen, 3)
    requireFrame()
    if dsIe != nil:
      let csaChan = addr chanCtxtAt(csaCtxPtr).channel
      let csaCtxFreq = csaChan.primFreq
      let newFreq = dsParamFreq(csaChan.band, dsParamSetIeAt(dsIe))
      if csaCtxFreq != newFreq:
        rejectBeacon()

  # Step 3: Increment beacon rx count
  vif.beaconRxCount = vif.beaconRxCount + 1

  # Compare unsigned MAC-clock gaps; the BL808 resamples on a new maximum.
  let macClock = cast[ptr uint32](0x24B00120'u32)
  let prevTimestamp = vif.lastBeaconMacTime
  if prevTimestamp != 0:
    let elapsed = volatileLoad(macClock) - prevTimestamp
    if elapsed > vif.beaconLossWindow:
      vif.beaconLossWindow = volatileLoad(macClock) - prevTimestamp
  let arrival = volatileLoad(macClock)
  mmResetBeaconProbeCount(vif)
  vif.lastBeaconMacTime = arrival

  let mm = mmEnvView()

  # Probe only after the MM-owned keepalive timeout, as in the vendor path.
  let prevBcnTime = vif.beaconCrc
  let bcnToFlag = mm.flagsHigh
  if bcnToFlag != 0:
    let macTs = volatileLoad(cast[ptr uint32](0x24B00120'u32))
    let vifElapsed = vif.beaconTimeoutBase
    let threshold30s = 0x1C9C380'u32  # 30 seconds in microseconds
    if cast[int32](threshold30s - macTs + vifElapsed) < 0:
      # Beacon loss threshold exceeded - send null frame probe
      when defined(bl808WifiDiagLinkDrop):
        inc nimFwDbgTrafficProbe[0]
      let probeStatus = txl_frame_send_null_frame(vif.staIdx,
        cast[pointer](mm_ap_traffic_probe_cfm), pointerAddrU32(vifEntry))
      when defined(bl808WifiDiagLinkDrop):
        if probeStatus != 0: inc nimFwDbgTrafficProbe[1]
      else:
        discard probeStatus
      requireFrame()
      # A local admission failure is not evidence of a missing AP ACK.

  # Step 5: Call mm_check_rssi
  mm_check_rssi(vifEntry, rx.rssi)
  requireFrame()

  # Step 6: Init CRC for beacon change detection
  var crcState {.noinit.}: uint32
  utils_crc32_stream_init(addr crcState)
  # Feed 4-byte beacon interval/capability field
  utils_crc32_stream_feed_block(addr crcState, addr frame.beaconInterval, 4)

  # IE walk: find TIM IE and feed non-TIM IEs into CRC
  var timIe: ptr MacIeView = nil
  var currentIeAddr = cast[uint](ieBody)
  var remaining = ieBodyLen
  while remaining >= 2:
    let ie = macIeAt(currentIeAddr)
    let ieId = ie.id
    let ieLen = ie.len
    let totalLen = ieLen.uint32 + 2
    if totalLen > remaining: break
    if ieId == 5:  # TIM IE
      if ieLen >= 4:
        timOut = cast[pointer](currentIeAddr)
        timIe = ie
    else:
      # Feed non-TIM IEs into CRC for beacon change detection
      utils_crc32_stream_feed_block(addr crcState, cast[pointer](currentIeAddr + 2),
                                    ieLen.uint32)
    remaining -= totalLen
    currentIeAddr += totalLen

  # The vendor retains the unfinalized context word as its beacon fingerprint.
  discard utils_crc32_stream_results(addr crcState)
  vif.beaconCrc = crcState

  let beaconTsf = frame.tsfLow.uint64 or (frame.tsfHigh.uint64 shl 32)
  let receiveTsf = rx.timestampLow.uint64 or (rx.timestampHigh.uint64 shl 32)
  let bcnIntTicks = bcnInterval.uint32 shl 10

  # Log beacon (line 272)
  let macTsForLog = volatileLoad(cast[ptr uint32](0x24B00120'u32))
  let elapsedForLog = ashr(cast[int32](macTsForLog - mmLastBeaconLogTime), 10)
  # Publish before logging, which may process another beacon synchronously.
  mmLastBeaconLogTime = volatileLoad(cast[ptr uint32](0x24B00120'u32))
  let logFunc = getLogFunc(204)
  if logFunc != nil:
    logFunc(1, nil, "mm.c", 272, "bcn --> %ld\r\n", elapsedForLog.clong)
    requireFrame()

  # The VIF listen interval overrides the TIM countdown; otherwise a zero
  # countdown selects the TIM period. The STA timing word is clock drift.
  var beaconsUntilWake = vif.listenInterval.uint32
  if beaconsUntilWake == 0:
    beaconsUntilWake = 1
    if timIe != nil:
      let timData = macIePayload(timIe)
      beaconsUntilWake = timData[0].uint32
      if beaconsUntilWake == 0:
        beaconsUntilWake = timData[1].uint32
  let clockDrift = sta.listenWindowDuration.uint32 * beaconsUntilWake
  let rxDurFull = hal_machw_rx_duration(param, frameLen.uint32)
  requireFrame()
  let rxDurHdr = hal_machw_rx_duration(param, 24)
  requireFrame()

  # Keep the vendor's unsigned 64-bit alignment and wraparound arithmetic.
  var quotient {.volatile.}: uint64 = beaconTsf div bcnIntTicks.uint64
  let alignedTbtt = quotient * bcnIntTicks.uint64
  let beforeHeader = beaconTsf - rxDurHdr.uint64
  let anchor = min(alignedTbtt, beforeHeader)
  let nextTarget = anchor + (bcnIntTicks * beaconsUntilWake).uint64
  let elapsedTsf = beaconTsf - receiveTsf + (rxDurFull - rxDurHdr).uint64
  let macTsLo = volatileLoad(cast[ptr uint32](0x24B00120'u32))
  let preDuration = mm.tbttPreDuration
  let descAccessTime = volatileLoad(cast[ptr uint32](0x24B080A4'u32))
  let tbttBase = macTsLo - 400'u32 - preDuration - descAccessTime
  let nextTbtt = tbttBase - clockDrift + nextTarget.uint32 - elapsedTsf.uint32

  # Check if TBTT changed
  let oldTbtt = vif.tbttTimer.expiry
  if nextTbtt != oldTbtt:
    mm_timer_set(addr vif.tbttTimer, nextTbtt)
    requireFrame()

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
    requireFrame()

  # Beacon change detection: compare CRC fingerprint
  result = if vif.beaconCrc != prevBcnTime: 1'u32 else: 0'u32

proc mm_check_beacon*(param, vifEntry, staEntry: pointer;
                      timIeAddrOut: ptr uint32): uint32 {.exportc, cdecl.} =
  ## The vendor ABI returns a borrowed DMA pointer, so it only accepts a
  ## contiguous beacon. RXL owns the storage for its split-frame call.
  if timIeAddrOut == nil: return high(uint32)
  timIeAddrOut[] = 0
  if param == nil: return high(uint32)
  let rx = beaconRxDescView(param)
  if rx.payloadDesc == nil or rx.frameLen > sizeof(RxPayloadBufferView).uint16:
    return high(uint32)
  var tim: pointer
  result = mmCheckBeaconFrame(param, vifEntry, staEntry,
    beaconPayloadDescView(rx.payloadDesc).frameData, tim)
  timIeAddrOut[] = pointerAddrU32(tim)

proc mmTimerActiveDelivery(timer: pointer): ptr MmTimerMutation =
  let delivery = mmTimerMutationTop
  if delivery != nil and delivery.delivering and delivery.timer == timer:
    delivery
  else:
    nil

proc mmStaOwnerCurrent(identity: MmVifIdentity): bool {.inline.} =
  ## For an owner that outlives the handler that created it (a queued request
  ## or an armed wake). A TX reset since then does not end it.
  mmVifCurrent(identity) and not txlResetting() and not txlVifIsRetiring(identity.index)

proc mmStaTimerCurrent(identity: MmVifIdentity; resetEpoch: uint32): bool {.inline.} =
  ## For re-checks inside one handler: also false once a nested reset ran.
  mmStaOwnerCurrent(identity) and txResetEpoch == resetEpoch

proc mmStaTbttCurrent(identity: MmVifIdentity; resetEpoch, beaconRxCount: uint32): bool {.noinline.} =
  if not mmStaTimerCurrent(identity, resetEpoch): return false
  let vif = vifChannelAt(identity.vif)
  let sta = staInfoForIdx(identity.station)
  vif.state != 0 and vif.beaconRxCount == beaconRxCount and
    sta.valid != 0 and sta.instNbr == identity.index

proc mmStaBeaconProbeCfm(arg: pointer; txStatus: uint32) {.cdecl.} =
  if (txStatus and 0x80000000'u32) == 0: return
  let saved = irqSave()
  defer: irqRestore(saved)
  let scope = txActiveFrameCallback
  if scope == nil or not scope.tracked or not txlFrameCallbackCurrent(): return
  let vif = vifChannelForIdx(scope.vif)
  # The callback scope owns the VIF; its opaque argument only carries freshness.
  var epoch = cast[uint](arg).uint32
  if mmBeaconProbeEpochs[scope.vif] != epoch: return
  if (txStatus and 0x00800000'u32) != 0:
    mmResetBeaconProbeCount(vif)
  else:
    mmPublishConnectionLoss(vif, 16'u16, addr epoch)

proc mm_sta_tbtt*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Advance the STA beacon timers and request liveness probes on-channel.
  ## Timer callbacks receive the VIF pointer stored in the timer environment.
  let saved = irqSave()
  defer: irqRestore(saved)
  let identity = mmCaptureVif(vifEntry)
  let resetEpoch = txResetEpoch
  template requireOwner() =
    if not mmStaTimerCurrent(identity, resetEpoch): return
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  requireOwner()
  let vifView = vifChannelAt(vifEntry)
  let delivery = mmTimerActiveDelivery(addr vifView.tbttTimer)
  let beaconRxCount = vifView.beaconRxCount
  if delivery != nil and delivery.cancelled: return
  inc nimFwDbgStaTbttEnter
  let logFn = getLogFunc(0xCC)
  if logFn != nil:
    outside:
      cast[proc(level: uint32; tag, file: cstring; line: cint;
                format: cstring) {.cdecl, varargs, raises: [Exception].}](logFn)(
        1, nil, "mm.c", 624, "mm_sta_tbtt\r\n")
    requireOwner()
    if delivery != nil and delivery.cancelled: return
  let staIdx = identity.station
  if staIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return
  # A newer Beacon reanchors TBTT and cancels this listen window's watchdog.
  template requireStation() =
    if not mmStaTbttCurrent(identity, resetEpoch, beaconRxCount): return
  requireStation()
  inc nimFwDbgStaTbttAssoc
  # Advance the prior deadline by the station's beacon interval in MAC ticks.
  let beaconInterval = staInfoForIdx(staIdx).initialRateConfig
  let vifBcnInterval = vifView.tbttTimer.expiry
  let tbttTime = beaconInterval + vifBcnInterval
  mmTimerSetLocked(addr vifView.tbttTimer, tbttTime, saved)
  requireStation()
  # Set keep-alive timer: MAC timestamp + mm_env[7]
  let macTime = regRead(MACHW_TIMLO_REG)
  requireStation()
  let keepAliveInterval = mmEnvView().keepAliveInterval
  # Keep the freshness check and start of the watchdog arm under one lock.
  mmTimerSetLocked(addr vifView.keepAliveTimer, macTime + keepAliveInterval, saved)
  requireStation()
  # Increment TBTT count at vif+120
  vifView.tbttCount = vifView.tbttCount + 1
  # Reprogram beacon detection
  outside: vif_mgmt_bcn_to_prog(vifEntry)
  requireStation()
  # Update channel TBTT state
  outside: chan_tbtt_switch_update(vifEntry, tbttTime)
  requireStation()
  # Check if on channel
  var onChan: bool
  outside: onChan = chan_is_on_channel(vifEntry)
  requireStation()
  if not onChan:
    return
  inc nimFwDbgStaTbttOnChan
  # Set bit 0 in vif+4
  vifView.flags = vifView.flags or 1'u32
  # Check power save TBTT
  outside: ps_check_tbtt(vifEntry)
  requireStation()
  # Saturate the vendor's byte counter so wrap cannot suppress due probes.
  if vifView.probeCount != high(uint8):
    inc vifView.probeCount
  let probeCount = vifView.probeCount
  if probeCount > nimFwDbgStaTbttPCMax.uint8:
    nimFwDbgStaTbttPCMax = probeCount.uint32
  if probeCount > 100:
    inc nimFwDbgStaTbttPC100
    # A new beacon or ACK can invalidate the probe before its callback.
    let epoch = mmBeaconProbeEpochs[identity.index]
    outside:
      discard txl_frame_send_null_frame(
        staIdx, cast[pointer](mmStaBeaconProbeCfm), epoch)
  elif probeCount > 49:
    # Send PM post event (blob: wifi_hosal_pm_post_event tail-call)
    outside: wifi_hosal_pm_post_event(3, 0, nil)

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
  let saved = irqSave()
  defer: irqRestore(saved)
  if mmTbttActive or txlResetting(): return
  mmTbttActive = true
  defer: mmTbttActive = false
  let resetEpoch = txResetEpoch
  template eventCurrent(): bool =
    txResetEpoch == resetEpoch and not txlResetting()
  template requireEvent() =
    if not eventCurrent(): return
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  template currentVif(identity: MmVifIdentity): bool =
    eventCurrent() and mmVifCurrent(identity) and
      not txlVifIsRetiring(identity.index) and
      vifChannelAt(identity.vif).vifType == VIF_TYPE_AP

  # Freeze list membership before any callback can remove or reuse a VIF.
  var captured: array[MAX_VIFS, MmVifIdentity]
  var capturedCount = 0
  var seen = 0'u32
  var node = cast[pointer](vifMgmtEnvView().activeList.first)
  while node != nil:
    let identity = mmCaptureVif(node)
    if not identity.captured or capturedCount == MAX_VIFS or
        (seen and (1'u32 shl identity.index)) != 0:
      outside: assert_err("valid TBTT VIF list", "mm.c", 0)
      return
    captured[capturedCount] = identity
    inc capturedCount
    seen = seen or (1'u32 shl identity.index)
    node = vifChannelAt(node).next

  # Read ke_env field (event bitmap) and mask TBTT bits
  let keEvtVal = keEnvEventField()[]
  let tbttBits = keEvtVal and 0x03000000'u32  # primary | secondary TBTT
  # Log
  let logFn = getLogFunc(0xCC)
  if logFn != nil:
    outside:
      cast[proc(level: uint32; tag, file: cstring; line: cint;
                format: cstring) {.cdecl, varargs, raises: [Exception].}](logFn)(
        1, nil, "mm.c", 898, "mm_tbtt_evt\r\n")
    requireEvent()
  # Assert not both bits set simultaneously
  if tbttBits == 0x03000000'u32:
    outside: assert_err("evt != MM_TBTT_EVT_MASK", "module", 902)
    requireEvent()
  # Clear the TBTT event
  ke_evt_clear(tbttBits)
  # Halt and flush beacon AC under interrupt protection
  var cleared: bool
  outside: cleared = txl_cntrl_clear_bcn_ac()
  requireEvent()
  if not cleared: return
  # Walk VIF list, handling AP VIFs
  for index in 0 ..< capturedCount:
    let identity = captured[index]
    if currentVif(identity):
      let curVif = identity.vif
      let vif = vifChannelAt(curVif)
      # Decrement bcn_tx_next countdown (vif+325)
      var bcnNext = vif.beaconCountdown
      bcnNext = bcnNext - 1
      vif.beaconCountdown = bcnNext
      if bcnNext == 0:
        # Reset from bcn_divisor (vif+324)
        vif.beaconCountdown = vif.beaconDivisor
        # Reprogram beacon timeout
        outside: vif_mgmt_bcn_to_prog(curVif)
        requireEvent()
        if not currentVif(identity): continue
        # If vif+64 (chan_ctxt pointer) is nonzero, update TBTT switch
        if vif.chanCtxt != nil:
          # Compute TBTT time from MAC timestamp and channel env
          let macTimeLo = regRead(MACHW_TIMLO_REG)
          let chanEnvOff = regRead(0x24B08040'u32)  # chan env timer offset from intc
          let tbttBase = macTimeLo + 0xFFFFF448'u32  # offset constant from blob
          let tbttShifted = chanEnvOff shl 5
          let tbttTime = (vif.apBeaconInterval.uint32 shl 10) + tbttShifted + tbttBase
          outside: chan_tbtt_switch_update(curVif, tbttTime)
          requireEvent()
  # A newly registered AP must wait for its own TBTT event.
  var transmit = false
  for index in 0 ..< capturedCount:
    if currentVif(captured[index]): transmit = true
  if transmit:
    outside: mm_bcn_transmit(0)
    requireEvent()
  # Decrement aging counters (.LANCHOR0 = mmTbttAgingCount0, .LANCHOR1 = mmTbttAgingCount1)
  mmTbttAgingCount0 = mmTbttAgingCount0 - 1
  mmTbttAgingCount1 = mmTbttAgingCount1 - 1
  if mmTbttAgingCount0 == 0:
    # Reset aging period to 2 and call sta_mgmt_aging_postponed_desc
    mmTbttAgingCount0 = 2
    outside: discard sta_mgmt_aging_postponed_desc(nil, 0)
    requireEvent()
  if mmTbttAgingCount1 == 0:
    # Reset second counter to 10
    mmTbttAgingCount1 = 10

proc mm_sta_timer_bcn_timeout*(param: pointer) {.exportc, cdecl.} =
  ## Beacon timeout timer handler (25 instrs).
  ## Logs the VIF through g_bl_ops_funcs[0xCC] before updating its state,
  ## increments vifEntry word at offset 124 (bcn_loss_count), clears bit 0 of
  ## vifEntry word at offset 4 (link state flags).
  let saved = irqSave()
  defer: irqRestore(saved)
  let identity = mmCaptureVif(param)
  let resetEpoch = txResetEpoch
  if not mmStaTimerCurrent(identity, resetEpoch): return
  let vif = vifChannelAt(param)
  let delivery = mmTimerActiveDelivery(addr vif.keepAliveTimer)
  let beaconRxCount = vif.beaconRxCount
  if delivery != nil and delivery.cancelled: return
  let logFn = getLogFunc(0xCC)
  if logFn != nil:
    irqRestore(saved)
    try:
      cast[proc(level: uint32; tag, file: cstring; line: cint;
                format: cstring) {.cdecl, varargs, raises: [Exception].}](logFn)(
        1, nil, "mm.c", 600, "beacon timeout %p\r\n", param)
    finally: discard irqSave()
    if not mmStaTimerCurrent(identity, resetEpoch): return
    if (delivery != nil and delivery.cancelled) or vif.beaconRxCount != beaconRxCount:
      return
  # Increment beacon loss count at vif+124
  vif.beaconLossCount = vif.beaconLossCount + 1
  # Clear bit 0 of vif+4 (link state flags)
  vif.flags = vif.flags and (not 1'u32)

proc mm_sta_timer_data_timeout*(param: pointer) {.exportc, cdecl.} =
  ## Data timeout timer handler (11 instrs).
  ## Logs the VIF through g_bl_ops_funcs[0xCC]; no state is changed.
  let logFn = getLogFunc(0xCC)
  if logFn != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs, raises: [Exception].}](logFn)(
      1, nil, "mm.c", 611, "data timeout %p\r\n", param)

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
  let saved = irqSave()
  defer: irqRestore(saved)
  if staIdx >= STA_INFO_TAB_ENTRIES.uint8 or cast[uint](keySlotRaw) > 15:
    return 0xFF
  let sta = staInfoForIdx(staIdx)
  let vifIdx = sta.instNbr
  if vifIdx >= MAX_VIFS.uint8:
    return 0xFF
  let ordinaryStation = staIdx < STA_MGMT_FREE_STAS.uint8
  if (ordinaryStation and sta.valid == 0) or
      (not ordinaryStation and staIdx != STA_MGMT_FREE_STAS.uint8 + vifIdx):
    return 0xFF
  let vifEpoch = rxVifEpochs[vifIdx]
  let stationEpoch = staDeleteEpoch(staIdx)
  let mac = staMacWords(staInfoForIdx(staIdx))
  template current(): bool =
    rxVifEpochs[vifIdx] == vifEpoch and sta.instNbr == vifIdx and
      (not ordinaryStation or
        (sta.valid != 0 and staDeleteEpoch(staIdx) == stationEpoch)) and
      staMacWords(sta) == mac

  # Compute HW station index: (staIdx + 8) & 0xFF
  let hwStaIdx = ((staIdx.uint32 + 8) and 0xFF)

  # The selector was validated before touching either hardware or callbacks.
  let keySlot = cast[uint32](keySlotRaw)
  let idxField = keySlot shl 4

  # Build control word: hwStaIdx<<16 | idxField | 0x40000002
  let ctrlWord = (hwStaIdx shl 16) or idxField or 0x40000002'u32
  nimFwConnectTrace2U32("[WIFI-CT] machwaddr ", (staIdx.uint32 or (hwStaIdx shl 8) or (keySlot shl 16)), ctrlWord)
  if not current():
    return 0xFF
  nimFwConnectTrace2U32("[WIFI-CT] machwmac ", mac.lo, mac.hi)
  if not current():
    return 0xFF

  # A prior read, write, or search may still own the shared command registers.
  if not waitMachwSecurityControlClear(0xE0000000'u32) or not current():
    return 0xFF
  machwSecurityWriteAddress(mac.lo, mac.hi)
  machwSecurityClearKeyMaterial()
  machwSecurityWriteControl(ctrlWord)

  # Poll until bit 30 (0x40000000) clears
  if not waitMachwSecurityControlClear(0x40000000'u32) or not current():
    return 0xFF
  return hwStaIdx.uint8

proc mmDeleteSecurityAddress(staIdx: uint8): bool =
  ## Checked deletion for the vendor's 68-byte address-table routine.
  ## Writes all-ones to address data, zeros to key material, then triggers
  ## the HW with (hwStaIdx<<16 | 0x40000000) and polls until done.
  let saved = irqSave()
  defer: irqRestore(saved)
  if staIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return false
  if not waitMachwSecurityControlClear(0xE0000000'u32):
    return false
  machwSecurityWriteAddress(0xFFFFFFFF'u32, 0xFFFFFFFF'u32)

  # Compute HW station index: (staIdx + 8) & 0xFF
  let hwStaIdx = ((staIdx.uint32 + 8) and 0xFF)

  machwSecurityClearKeyMaterial()

  # Build control word: hwStaIdx<<16 | 0x40000000, then write
  let ctrlWord = (hwStaIdx shl 16) or 0x40000000'u32
  machwSecurityWriteControl(ctrlWord)

  # Poll until bit 30 (0x40000000) clears
  waitMachwSecurityControlClear(0x40000000'u32)

proc mm_sec_machwaddr_del*(staIdx: uint8) {.exportc, cdecl.} =
  discard mmDeleteSecurityAddress(staIdx)

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

when defined(bl808WifiDiagKeyWriteTiming):
  # Pairwise/group: attempts, max idle/trigger/total us, idle/trigger timeouts.
  var wifiKeyWriteTiming {.wifiCtrl, exportc: "nimfw_dbg_key_write_timing", volatile.}:
    array[2, array[6, uint32]]

proc recordKeyWriteTiming(groupKey: bool; enteredAt, idleUs, triggerUs,
                          timeouts: uint32) {.noinline.} =
  when defined(bl808WifiDiagKeyWriteTiming):
    let totalUs = regRead(ClicMtimeBase) - enteredAt
    let timingRow = groupKey.int
    template row: untyped = wifiKeyWriteTiming[timingRow]
    inc row[0]
    row[1] = max(row[1], idleUs)
    row[2] = max(row[2], triggerUs)
    row[3] = max(row[3], totalUs)
    row[4] += timeouts and 1
    row[5] += timeouts shr 1

proc mm_sec_machwkey_wr*(param: pointer): uint8 {.exportc, cdecl, discardable.} =
  ## Write encryption key to MAC HW key table (143 instructions).
  ##
  ## param layout is the 56-byte key buffer built by setKey and the WEP
  ## setup path. mm_sec_machwkey_wr consumes:
  ##   [0]   u8: logical key ID (0..3 data, 4..5 BIP)
  ##   [1]   u8: keyType (0xFF = VIF group key, 0..6 = STA index)
  ##   [8..23]  key material (4 x 32-bit words)
  ##   [52]  u8: cipherType (0=WEP40, 1=TKIP, 2=CCMP, 3=WEP104, 5=BIP)
  ##   [53]  u8: VIF index
  ##   [54]  u8: spp (SPP A-MSDU / MIC mode for TKIP)
  ##
  ## MACHW register offsets (base 0x44B00000):
  ##   +0x080: key RAM window base
  ##   +0x0AC..0x0B8: key material words 0..3
  ##   +0x0BC: key data low
  ##   +0x0C0: key data high
  ##   +0x0C4: key control (write trigger bit 30, poll until clear)
  ##   +0x0D8: key count / config

  let saved = irqSave()
  defer: irqRestore(saved)
  when defined(bl808WifiDiagKeyWriteTiming):
    let enteredAt = regRead(ClicMtimeBase)
  if param == nil:
    return 0xFF
  var request = machwKeyWriteParamView(param)[]
  let req = addr request
  let keyType = req.keyType     # s3
  let keyIdx = req.keyIdx       # s1 (blob: lbu s1,53(a0))
  var hwIdx = req.addrIdx       # s0
  let cipherType = req.cipherType
  if keyIdx >= MAX_VIFS.uint8 or req.spp > 3 or req.macLen > 8:
    return 0xFF
  let expectedLength =
    case cipherType
    of 0: 5'u8
    of 1: 32'u8
    of 2, 5: 16'u8
    of 3: 13'u8
    else: 0'u8
  if expectedLength == 0 or req.keyLen != expectedLength:
    return 0xFF
  # The on-wire TKIP/CCMP PN and BIP IPN are six bytes, even when the host
  # passes the eight-byte replay-counter field.
  if cipherType in [1'u8, 2'u8, 5'u8] and
      req.macAddrCipherPadding != [0'u8, 0'u8]:
    return 0xFF
  let groupKey = keyType == 0xFF
  if groupKey:
    if (cipherType == 5 and req.addrIdx notin [4'u8, 5'u8]) or
        (cipherType != 5 and req.addrIdx > 3):
      return 0xFF
  elif keyType >= STA_INFO_TAB_ENTRIES.uint8 or cipherType == 5 or
      req.addrIdx > 3:
    return 0xFF
  let vifEpoch = rxVifEpochs[keyIdx]
  var stationEpoch: uint32
  var mac: tuple[lo, hi: uint32]
  let ordinaryStation = keyType < STA_MGMT_FREE_STAS.uint8
  if not groupKey:
    let sta = staInfoForIdx(keyType)
    if sta.instNbr != keyIdx or
        (ordinaryStation and sta.valid == 0) or
        (not ordinaryStation and keyType != STA_MGMT_FREE_STAS.uint8 + keyIdx):
      return 0xFF
    stationEpoch = staDeleteEpoch(keyType)
    mac = staMacWords(sta)
  template current(): bool =
    rxVifEpochs[keyIdx] == vifEpoch and
      (groupKey or
        (staInfoForIdx(keyType).instNbr == keyIdx and
          (not ordinaryStation or
            (staInfoForIdx(keyType).valid != 0 and
              staDeleteEpoch(keyType) == stationEpoch)) and
          staMacWords(staInfoForIdx(keyType)) == mac))

  inc nimFwDbgMachwKeyWrCalls
  nimFwDbgMachwKeyWrLast0 = req.addrIdx.uint32 or (keyType.uint32 shl 8) or
    (req.keyLen.uint32 shl 16) or (req.macLen.uint32 shl 24)
  nimFwDbgMachwKeyWrLast1 = cipherType.uint32 or (keyIdx.uint32 shl 8) or
    (req.spp.uint32 shl 16) or (req.keyFlags.uint32 shl 24)

  if keyType == 0xFF:
    inc nimFwDbgMachwKeyWrGroup
    # Default WEP / group-key path
    if cipherType == 5'u8:
      # BIP keys are software-managed, in two virtual slots per VIF above
      # the hardware table. The pairwise flag does not alter this dispatch.
      let keyCount = machwSecurityKeyCount()
      let baseIdx = cast[uint8](keyCount shr 24)
      # The physical table must cover all eight group and seven STA slots;
      # reserve four distinct, non-sentinel virtual slots above it.
      if baseIdx < 14 or baseIdx > 250:
        return 0xFF
      hwIdx = (hwIdx.uint32 + baseIdx.uint32 - 3 +
        (keyIdx.uint32 shl 1)).uint8
      let updateKey = cast[pointer](vifKeySlotPtr(vifChannelForIdx(keyIdx), req.addrIdx.uint))
      if not txSecurityKeyUpdatePending(updateKey) and vifReuseBipKey(req, hwIdx):
        return hwIdx
      if not txSecurityBeginUpdate(updateKey):
        return 0xFF
      defer: txSecurityEndUpdate(updateKey)
      if not current(): return 0xFF
      vif_mgmt_add_key(req, hwIdx)
      return hwIdx
    else:
      # WEP/default-key and CCMP GTK data keys use a wildcard MAC address.
      # CCMP group data (cipher 2) must come through here; treating it like
      # cipher 5 leaves broadcast/multicast data undecryptable.
      hwIdx = cast[uint8]((hwIdx.uint32 + (keyIdx.uint32 shl 2)) and 0xFF)
    # Blob falls through to the key material/control write for this path.

  else:
    inc nimFwDbgMachwKeyWrPair
    nimFwDbgMachwKeyWrPair0 = nimFwDbgMachwKeyWrLast0
    nimFwDbgMachwKeyWrPair1 = nimFwDbgMachwKeyWrLast1
    nimFwDbgMachwKeyWrPair2 = req.keyWords[0]
    nimFwDbgMachwKeyWrPair3 = req.keyWords[1]
    nimFwDbgMachwKeyWrPair4 = req.keyWords[2]
    nimFwDbgMachwKeyWrPair5 = req.keyWords[3]
    # HW key slot = keyType + 8
    hwIdx = cast[uint8]((keyType.uint32 + 8) and 0xFF)
    # Blob does NOT call mm_sec_machwaddr_wr here.

  # Keep the vendor's switch-table encoding, but reject unsupported ciphers
  # before touching the shared command registers or software key state.
  let keyTypeForCtrl =
    case cipherType
    of 0: 0'u32
    of 1: 1'u32
    of 2: 0'u32
    of 3: 1'u32
    else: 0'u32

  let hwCipherType =
    case cipherType
    of 0: 1'u32
    of 1: 2'u32
    of 2: 3'u32
    of 3: 1'u32
    else: 0'u32

  let topCount = (machwSecurityKeyCount() shr 24).uint8
  if hwIdx > topCount:
    return 0xFF
  let updateKey =
    if groupKey: cast[pointer](vifKeySlotPtr(vifChannelForIdx(keyIdx), req.addrIdx.uint))
    else: cast[pointer](addr staInfoForIdx(keyType).keyArea[0])
  if not txSecurityBeginUpdate(updateKey):
    return 0xFF
  defer: txSecurityEndUpdate(updateKey)
  if not current(): return 0xFF
  when defined(bl808WifiDiagKeyWriteTiming):
    let idleAt = regRead(ClicMtimeBase)
  let idleReady = waitMachwSecurityControlClear(0xE0000000'u32)
  when defined(bl808WifiDiagKeyWriteTiming):
    let idleUs = regRead(ClicMtimeBase) - idleAt
    if not idleReady: recordKeyWriteTiming(groupKey, enteredAt, idleUs, 0, 1)
  if not idleReady or not current():
    return 0xFF
  if groupKey:
    rxKeyChange(cast[pointer](vifKeySlotPtr(vifChannelForIdx(keyIdx), req.addrIdx.uint)))
  else:
    rxKeyChange(cast[pointer](addr staInfoForIdx(keyType).keyArea[0]))
  if not current(): return 0xFF
  if groupKey:
    machwSecurityWriteAddress(0xFFFFFFFF'u32, 0xFFFFFFFF'u32)
  else:
    machwSecurityWriteAddress(mac.lo, mac.hi)
  machwSecurityWriteKeyMaterial(req.keyWords)
  nimFwDbgMachwKeyWrPre0 = volatileLoad(addr machwSecurityRegs().keyMaterial[0])
  nimFwDbgMachwKeyWrPre1 = volatileLoad(addr machwSecurityRegs().keyMaterial[1])
  nimFwDbgMachwKeyWrPre2 = volatileLoad(addr machwSecurityRegs().keyMaterial[2])
  nimFwDbgMachwKeyWrPre3 = volatileLoad(addr machwSecurityRegs().keyMaterial[3])

  let keyIdxField = keyIdx.uint32 shl 4
  let sppField = req.spp.uint32 shl 2  # blob: lbu s2,54(s2)

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
  else:
    nimFwDbgMachwKeyWrGroup0 = req.keyWords[0]
    nimFwDbgMachwKeyWrGroup1 = req.keyWords[1]
    nimFwDbgMachwKeyWrGroup2 = req.keyWords[2]
    nimFwDbgMachwKeyWrGroup3 = req.keyWords[3]
    nimFwDbgMachwKeyWrGroupCtrl =
      ctrlWord or (machwSecurityKeyCount() and 0xFF000000'u32)
  nimFwDbgMachwKeyWrCtrlBefore = machwSecurityControl()
  when defined(bl808WifiDiagKeyWriteTiming):
    let triggerAt = regRead(ClicMtimeBase)
  machwSecurityWriteControl(ctrlWord)
  nimFwDbgMachwKeyWrCtrlAfterWrite = machwSecurityControl()

  # Poll until bit 30 (trigger) clears
  let completed = waitMachwSecurityControlClear(0x40000000'u32)
  when defined(bl808WifiDiagKeyWriteTiming):
    let triggerUs = regRead(ClicMtimeBase) - triggerAt
    recordKeyWriteTiming(groupKey, enteredAt, idleUs, triggerUs, (not completed).uint32 shl 1)
  nimFwDbgMachwKeyWrWriteWait = completed.uint32
  if not current():
    return 0xFF
  if not completed:
    # The old key may already have been overwritten. Do not advertise either
    # version as installed, and do not issue cleanup into a busy controller.
    if groupKey:
      vif_mgmt_del_key(cast[pointer](vifChannelForIdx(keyIdx)), req.addrIdx)
      # Without a GTK, later broadcast TX must not fall back to plaintext.
      for staIdx in 0 ..< STA_INFO_TAB_ENTRIES:
        let station = staInfoForIdx(staIdx.uint8)
        if station.instNbr == keyIdx:
          station.controlPortState = 1
    else:
      sta_mgmt_del_key(cast[pointer](staInfoForIdx(keyType)))
    return 0xFF
  if groupKey:
    vif_mgmt_add_key(req, hwIdx)
  else:
    sta_mgmt_add_key(req, hwIdx)
  return hwIdx

proc mmDeleteSecurityKey(keyIdx: uint8): bool =
  ## Invalidate software state and confirm hardware deletion, without changing
  ## the public void ABI. BIP indices above KEY_COUNT[31:24] are software-only.

  let saved = irqSave()
  defer: irqRestore(saved)
  if keyIdx == 0xFF:
    return false
  let keyCount = machwSecurityKeyCount()
  let topCount = (keyCount shr 24).uint8

  if keyIdx > topCount:
    # Virtual BIP path. Blob math (hwIdx/slot) from blob insns:
    #   hwIdx = (keyIdx - topCount - 1) / 2
    #   vifSlot = 4 + ((keyIdx - topCount - 1) & 1)
    #   vif = vif_info_tab[hwIdx]
    # Blob tail-calls vif_mgmt_del_key here — must RETURN WITHOUT clearing
    # the MACHW key-RAM (that is only done on the group/STA paths below).
    let pairwiseKeySlotOffset = keyIdx.int - topCount.int - 1
    if topCount < 14 or topCount > 250 or
        pairwiseKeySlotOffset >= 2 * MAX_VIFS:
      return false
    let hwIdx = pairwiseKeySlotOffset div 2
    let vifSlot = 4 + (pairwiseKeySlotOffset and 1)
    let vif = vifChannelForIdx(hwIdx.uint8)
    let epoch = rxVifEpochs[hwIdx]
    let updateKey = cast[pointer](vifKeySlotPtr(vif, vifSlot.uint))
    if not txSecurityBeginUpdate(updateKey):
      return false
    defer: txSecurityEndUpdate(updateKey)
    if rxVifEpochs[hwIdx] != epoch: return false
    vif_mgmt_del_key(cast[pointer](vif), vifSlot.uint8)
    return true
  if keyIdx >= 8 + STA_INFO_TAB_ENTRIES.uint8:
    return false
  var mac: tuple[lo, hi: uint32]
  var vifIdx: uint8
  var stationEpoch: uint32
  var updateKey: pointer
  let groupKey = keyIdx <= 7
  let staIdx = if groupKey: 0xFF'u8 else: keyIdx - 8
  if groupKey:
    # Group key path: flood MACHW key data with all-ones, then delete via
    # vif_mgmt_del_key. Blob layout: vifIdx = keyIdx >> 2, vifSlot = keyIdx & 3.
    let vifSlot = keyIdx and 3
    vifIdx = keyIdx shr 2
    let vif = vifChannelForIdx(vifIdx)
    updateKey = cast[pointer](vifKeySlotPtr(vif, vifSlot.uint))
    mac = (0xFFFFFFFF'u32, 0xFFFFFFFF'u32)
  else:
    # Station key: retire the software key before waiting on the controller.
    let sta = staInfoForIdx(staIdx)
    vifIdx = sta.instNbr
    if vifIdx >= MAX_VIFS.uint8:
      return false
    stationEpoch = staDeleteEpoch(staIdx)
    mac = staMacWords(sta)
    updateKey = cast[pointer](addr sta.keyArea[0])

  let vifEpoch = rxVifEpochs[vifIdx]
  template current(): bool =
    rxVifEpochs[vifIdx] == vifEpoch and
      (groupKey or
        (staInfoForIdx(staIdx).instNbr == vifIdx and
          staDeleteEpoch(staIdx) == stationEpoch and
          staMacWords(staInfoForIdx(staIdx)) == mac))
  if not txSecurityBeginUpdate(updateKey):
    return false
  defer: txSecurityEndUpdate(updateKey)
  if not current(): return false
  if groupKey:
    let vif = vifChannelForIdx(vifIdx)
    let vifSlot = keyIdx and 3
    let activeDefault = vifKeyPointers(vif).defaultKeyPtr ==
      vifKeySlotPtr(vif, vifSlot.uint)
    vif_mgmt_del_key(cast[pointer](vif), vifSlot)
    if activeDefault and vifKeyPointers(vif).defaultKeyPtr == 0:
      for index in 0 ..< STA_INFO_TAB_ENTRIES:
        let station = staInfoForIdx(index.uint8)
        if station.instNbr == vifIdx:
          station.controlPortState = 1
  else:
    sta_mgmt_del_key(cast[pointer](staInfoForIdx(staIdx)))
  if not waitMachwSecurityControlClear(0xE0000000'u32) or not current():
    return false
  machwSecurityWriteAddress(mac.lo, mac.hi)

  # Group/Station fall-through: clear the MACHW 128-bit key RAM at 0xAC..0xB8.
  machwSecurityClearKeyMaterial()

  # Write control word with key index and trigger delete (bit 30)
  let ctrlWord = (keyIdx.uint32 shl 16) or 0x40000000'u32
  machwSecurityWriteControl(ctrlWord)

  # Poll until trigger bit clears
  let completed = waitMachwSecurityControlClear(0x40000000'u32)
  completed and current()

proc mm_sec_machwkey_del*(keyIdx: uint8) {.exportc, cdecl.} =
  discard mmDeleteSecurityKey(keyIdx)

type
  MmSecurityReadback = object
    control, macLow, macHigh: uint32
    words: array[4, uint32]

proc mmReadSecurityEntry(keyIdx: uint8; readback: var MmSecurityReadback): bool =
  # Read-limit bits 15:8 are distinct from the data/BIP boundary in bits 31:24.
  let saved = irqSave()
  defer: irqRestore(saved)
  let keyCount = machwSecurityKeyCount()
  let maxIdx = ((keyCount shr 8) and 0xFF).uint8
  if keyIdx > maxIdx:
    return false
  if not waitMachwSecurityControlClear(0xE0000000'u32):
    return false
  let readCmd = (keyIdx.uint32 shl 16) or 0x80000000'u32
  machwSecurityWriteControl(readCmd)
  if not waitMachwSecurityControlClear(0x80000000'u32):
    return false
  let regs = machwSecurityRegs()
  var entry: MmSecurityReadback
  entry.control = machwSecurityControl()
  entry.macLow = volatileLoad(addr regs.dataLow)
  entry.macHigh = volatileLoad(addr regs.dataHigh)
  for i in 0 ..< entry.words.len:
    entry.words[i] = volatileLoad(addr regs.keyMaterial[i])
  readback = entry
  true

proc mm_sec_machwkey_get*(keyIdx: uint8, outBuf: pointer, keySizeOut: pointer): pointer {.exportc, cdecl, discardable.} =
  ## The vendor copies exactly the reported 8- or 16-byte hardware key.
  if outBuf == nil or keySizeOut == nil:
    return cast[pointer](-1)
  var entry: MmSecurityReadback
  if not mmReadSecurityEntry(keyIdx, entry):
    return cast[pointer](-1)
  let keySize = if (entry.control and 1) != 0: 16'u8 else: 8'u8
  discard c_memcpy(outBuf, addr entry.words[0], keySize.csize_t)
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
  ## Snapshots each entry before logging; ends with hal_machw_timing_info().
  let regs = machwSecurityRegs()

  # Clear bit 0 of crypto debug flag at 0x20005198
  let flagPtr = cast[ptr uint32](0x20005198'u32)
  volatileStore(flagPtr, volatileLoad(flagPtr) and not 1'u32)

  let logFunc = getLogFunc(204)
  let ops = blOpsData()

  let totalKeys = volatileLoad(addr regs.keyCount)

  if logFunc != nil: logFunc(2, nil, "mm.c", 945,
    "==========================  Keyram Config ========================\r\n")
  if logFunc != nil: logFunc(2, nil, "mm.c", 946,
    "  start %02u -->> end %02u; nVAP %02u; max %02u\r\n",
    totalKeys and 0xFF, (totalKeys shr 8) and 0xFF,
    (totalKeys shr 16) and 0xFF, totalKeys shr 24)
  if logFunc != nil: logFunc(2, nil, "mm.c", 972,
    "==========================  Keyram Dump =========================\r\n")

  let keyCount = ((volatileLoad(addr regs.keyCount) shr 8) and 0xFF).int32
  if logFunc != nil: logFunc(2, nil, "mm.c", 977,
    "[id]   MAC Address     Key Len  VLan ID  Default      \tKey Hexdump(16Bytes MAX)\r\n")

  var keyTableIndex: int32 = 0
  while keyTableIndex <= keyCount:
    var entry: MmSecurityReadback
    if not mmReadSecurityEntry(keyTableIndex.uint8, entry):
      break

    let kdLo = entry.macLow
    let kdHi = entry.macHigh
    # Blob asserts upper 16 bits of kdHi must be zero (offset 0x116-0x12e)
    if (kdHi and 0xFFFF0000'u32) != 0:
      assert_err("mm_sec.c", "mm_sec.c", keyTableIndex.cint)
    let maskedHi = kdHi and 0xFFFF'u32

    if logFunc != nil: logFunc(2, nil, "mm.c", 989,
      "[%02d] %02X:%02X:%02X:%02X:%02X:%02X", keyTableIndex.cint,
      kdLo and 0xFF, (kdLo shr 8) and 0xFF,
      (kdLo shr 16) and 0xFF, kdLo shr 24,
      maskedHi and 0xFF, maskedHi shr 8)

    let keyControlValid = entry.control
    if logFunc != nil: logFunc(2, nil, "mm.c", 998, " %s",
      (if (keyControlValid and 1) != 0: cstring("128-Bit") else: cstring(" 64-Bit")))
    let keyControlCipher = entry.control
    if logFunc != nil: logFunc(2, nil, "mm.c", 999, "    %02u",
      (keyControlCipher shr 1) and 0x7FFF)
    let keyControlAddr = entry.control
    if logFunc != nil: logFunc(2, nil, "mm.c", 1000, "        %u",
      (keyControlAddr shr 16) and 0xFFFF)

    let kw0 = entry.words[0]
    let kw1 = entry.words[1]
    let kw2 = entry.words[2]
    let kw3 = entry.words[3]

    if logFunc != nil: logFunc(2, nil, "mm.c", 1007,
      "     %02X%02X%02X%02X %02X%02X%02X%02X %02X%02X%02X%02X %02X%02X%02X%02X",
      kw0 and 0xFF, (kw0 shr 8) and 0xFF,
      (kw0 shr 16) and 0xFF, kw0 shr 24,
      kw1 and 0xFF, (kw1 shr 8) and 0xFF,
      (kw1 shr 16) and 0xFF, kw1 shr 24,
      kw2 and 0xFF, (kw2 shr 8) and 0xFF,
      (kw2 shr 16) and 0xFF, kw2 shr 24,
      kw3 and 0xFF, (kw3 shr 8) and 0xFF,
      (kw3 shr 16) and 0xFF, kw3 shr 24)
    if logFunc != nil: logFunc(2, nil, "mm.c", 1014, "\r\n")
    keyTableIndex += 1

  if logFunc != nil: logFunc(2, nil, "mm.c", 1016,
    "==========================  MAC Address =========================\r\n")

  # Dump MAC address bytes from g_bl_ops_funcs struct.
  let macAddrLow = ops.macAddrLow
  let macAddrHigh = ops.macAddrHigh
  if logFunc != nil: logFunc(2, nil, "mm.c", 1019,
    "    MAC %02X:%02X:%02X:%02X:%02X:%02X",
    macAddrLow and 0xFF, (macAddrLow shr 8) and 0xFF,
    (macAddrLow shr 16) and 0xFF, macAddrLow shr 24,
    macAddrHigh and 0xFF, (macAddrHigh shr 8) and 0xFF)

  let beaconTimeoutConfig = ops.beaconTimeoutConfigWord()
  let adapterTimingConfig28 = ops.adapterTimingConfig28
  if logFunc != nil: logFunc(2, nil, "mm.c", 1029,
    " Mask %02X:%02X:%02X:%02X:%02X:%02X",
    beaconTimeoutConfig and 0xFF, (beaconTimeoutConfig shr 8) and 0xFF,
    (beaconTimeoutConfig shr 16) and 0xFF, beaconTimeoutConfig shr 24,
    adapterTimingConfig28 and 0xFF, (adapterTimingConfig28 shr 8) and 0xFF)
  if logFunc != nil: logFunc(2, nil, "mm.c", 1037, "\r\n")

  let beaconProbeCountdown = ops.beaconProbeCountdown
  let adapterTimingConfig36 = ops.adapterTimingConfig36
  if logFunc != nil: logFunc(2, nil, "mm.c", 1041,
    "  BSSID %02X:%02X:%02X:%02X:%02X:%02X",
    beaconProbeCountdown and 0xFF, (beaconProbeCountdown shr 8) and 0xFF,
    (beaconProbeCountdown shr 16) and 0xFF, beaconProbeCountdown shr 24,
    adapterTimingConfig36 and 0xFF, (adapterTimingConfig36 shr 8) and 0xFF)

  let adapterTimingConfig40 = ops.adapterTimingConfig40
  let adapterTimingConfig44 = ops.adapterTimingConfig44
  if logFunc != nil: logFunc(2, nil, "mm.c", 1051,
    " Mask %02X:%02X:%02X:%02X:%02X:%02X",
    adapterTimingConfig40 and 0xFF, (adapterTimingConfig40 shr 8) and 0xFF,
    (adapterTimingConfig40 shr 16) and 0xFF, adapterTimingConfig40 shr 24,
    adapterTimingConfig44 and 0xFF, (adapterTimingConfig44 shr 8) and 0xFF)
  if logFunc != nil: logFunc(2, nil, "mm.c", 1059, "\r\n")

  # Tail call to hal_machw_timing_info (blob reloc at 0x3ee)
  hal_machw_timing_info()

# MM Beacon operations
proc mmBeaconPoolIdle(): bool =
  let env = bcnEnvView()
  not mmBcnStopping and env.pendingCount == 0 and env.active == 0 and
    env.templatePtr == nil and env.timQueue.first == nil

proc mmBcnOwnerCurrent(vifIdx: uint8; vifEpoch, poolEpoch: uint32): bool =
  if vifIdx >= MAX_VIFS.uint8 or mmBcnGeneration != poolEpoch or
      rxVifEpochs[vifIdx] != vifEpoch:
    return false
  let vif = vifChannelForIdx(vifIdx)
  vif.vifIdx == vifIdx and vif.vifType == VIF_TYPE_AP

proc mmBcnRequestExecuting(request: pointer): bool =
  var scope = mmBcnActiveUpdate
  while scope != nil:
    if scope.request == request:
      return true
    scope = scope.previous
  false

proc mmBcnReleaseUpdate(header: ptr KeMsgHdr; notify: bool; callbackIrq: uint32) =
  # The caller owns a detached message. No callback can recapture it.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  irqRestore(callbackIrq)
  defer:
    discard irqSave()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  if notify:
    if header.id == MM_BCN_CHANGE_REQ:
      mmBeaconChangeConfirm(header, 1)
    elif header.id == MM_TIM_UPDATE_REQ:
      ke_msg_send_basic(0x30, header.srcId, TASK_MM)
  ke_msg_free(header)

proc mmBcnFlushUpdates(notify: bool; callbackIrq: uint32) =
  # Detach the complete private batch before releasing any message.
  let env = bcnEnvView()
  let templateMessage = env.templatePtr
  var timQueue = env.timQueue
  env.templatePtr = nil
  env.deferredChange = 0
  env.transmitRequested = 0
  co_list_init(addr env.timQueue)
  if templateMessage != nil:
    mmBcnReleaseUpdate(keMsgHdrFromPayload(templateMessage), notify, callbackIrq)
  while timQueue.first != nil:
    let header = cast[ptr KeMsgHdr](co_list_pop_front(addr timQueue))
    mmBcnReleaseUpdate(header, notify, callbackIrq)

proc mm_bcn_flush_updates*(notify: bool) {.exportc, cdecl.} =
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  mmBcnFlushUpdates(notify, saved)

proc mmBcnQueuedUpdateForVif(elem: ptr CoListHdr, param: pointer): bool {.cdecl.} =
  let header = cast[ptr KeMsgHdr](elem)
  if header.destId != TASK_MM:
    return false
  let vifIdx = cast[uint](param).uint8
  let payload = keMsgPayload(header)
  if header.id == MM_BCN_CHANGE_REQ and
     header.paramLen >= offsetof(BeaconChangeReqView, frameData).uint32:
    return beaconChangeReqAt(payload).vifIdx == vifIdx
  if header.id == MM_TIM_UPDATE_REQ and header.paramLen >= MmTimUpdatePayloadSize:
    return cast[ptr MmTimUpdatePayload](payload).vifIdx == vifIdx
  if header.id == MM_SET_VIF_STATE_REQ and header.srcId == TASK_APM and
     header.paramLen >= sizeof(MmSetVifStateReqPayload).uint32:
    let request = cast[ptr MmSetVifStateReqPayload](payload)
    return request.vifIdx == vifIdx and request.state != 0
  false

proc mmBcnCancelQueuedUpdates(vifIdx: uint8; vifEpoch, poolEpoch,
                              callbackIrq: uint32) =
  while mmBcnOwnerCurrent(vifIdx, vifEpoch, poolEpoch):
    var detached: CoList
    for queue in [addr keMsgQueueSent, addr keMsgQueueSaved]:
      while true:
        let node = ke_queue_extract(queue, mmBcnQueuedUpdateForVif,
                                    cast[pointer](vifIdx.uint))
        if node == nil:
          break
        co_list_push_back(addr detached, node)
    if detached.first == nil:
      return
    while detached.first != nil:
      let header = cast[ptr KeMsgHdr](co_list_pop_front(addr detached))
      mmBcnReleaseUpdate(header, true, callbackIrq)

proc mm_bcn_stop*(vifEntry: pointer): bool {.exportc, cdecl.} =
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  if vifEntry == nil or mmBcnStopping:
    return true
  let vif = vifChannelAt(vifEntry)
  let vifIdx = vif.vifIdx
  if vifIdx >= MAX_VIFS.uint8 or vifChannelForIdx(vifIdx) != vif or
      vif.vifType != VIF_TYPE_AP:
    return true
  if not txl_cntrl_halt_ac(4): return false
  let vifEpoch = rxVifEpochs[vifIdx]
  inc mmBcnGeneration
  let poolEpoch = mmBcnGeneration
  let env = bcnEnvView()
  mmBcnStopping = true
  defer:
    if mmBcnGeneration == poolEpoch:
      mmBcnStopping = false
  vif.beaconEnabled = 0
  mmBcnFlushUpdates(true, saved)
  mmBcnCancelQueuedUpdates(vifIdx, vifEpoch, poolEpoch, saved)
  if not mmBcnOwnerCurrent(vifIdx, vifEpoch, poolEpoch):
    return true
  # Halt DMA and drain its callbacks before the VIF or shared pool is reused.
  # Keep ownership checked and DMA detachment in the same IRQ-masked interval.
  if not txl_cntrl_clear_bcn_ac(): return false
  discard irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  mmBcnCancelQueuedUpdates(vifIdx, vifEpoch, poolEpoch, saved)
  if not mmBcnOwnerCurrent(vifIdx, vifEpoch, poolEpoch):
    return true
  env.pendingCount = 0
  env.active = 0
  true

proc mm_bcn_init*() {.exportc, cdecl.} =
  ## Initialize beacon subsystem (14 instrs in blob).
  ## From blob: memset(mm_bcn_env, 0, 20), then tail-calls co_list_init on
  ## the beacon pending list (at mm_bcn_env + some offset or a separate list).
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  let env = bcnEnvView()
  inc mmBcnGeneration
  let poolEpoch = mmBcnGeneration
  mmBcnStopping = true
  mmBcnFlushUpdates(false, saved)
  if mmBcnGeneration != poolEpoch:
    return
  discard c_memset(env, 0, sizeof(MmBcnEnvView).csize_t)
  co_list_init(addr env.timQueue)
  mmBcnInitDone = true
  mmBcnStopping = false

proc mm_bcn_init_vif*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Initialize beacon for a specific VIF (79 instrs).
  ## From blob: param is actually a VIF entry pointer (not a u8 vifIdx).
  ## Calls txl_frame_init_desc(vif+96, txl_bcn_pool, txl_bcn_hwdesc_pool, txl_bcn_buf_ctrl).
  ## Stores txl_bcn_hwdesc_cfms into txl_bcn_hwdesc_pool (the cfm pointer).
  ## Sets up beacon descriptor fields: vif+318=6, vif+328=0xFF, vif+327=0,
  ## vif+320=0, vif+330=0. Initializes txl_tim_desc with magic 0xCAFEFADE,
  ## links to txl_bcn_end_desc and txl_tim_ie_pool. Sets up TIM IE pool bytes
  ## [0]=5, [1]=4, [2]=vif+327, [3]=1. Zeros txl_tim_bitmap_pool
  ## (252 bytes). Clears txl_bcn_end_desc fields. Stores mm_bcn_transmitted
  ## callback at vif+304, vif pointer at vif+308.
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  if vifEntry == nil:
    return
  if not mmBeaconPoolIdle():
    assert_err("mm_bcn.c", "beacon pool busy", 0)
    return
  inc mmBcnGeneration
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
  vif.timMax = 0
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
  # An empty TIM must not advertise buffered traffic for AIDs 1 through 7.
  timIe.partialBitmap[0] = 0
  # Compute bitmap offset from vif+329 and add txl_tim_bitmap_pool base
  let bitmapOff = vif.timMax
  timDesc.bitmapMagic = 0xCAFEFADE'u32
  timDesc.bitmapNext = cast[pointer](bcnEndBase)
  let bitmapAddr = bitmapOff.uint + timBitmapBase
  timDesc.bitmapStart = cast[pointer](timBitmapBase)
  timDesc.bitmapEnd = cast[pointer](bitmapAddr)
  # Zero TIM bitmap (252 bytes)
  discard c_memset(cast[pointer](timBitmapBase), 0, sizeof(txl_tim_bitmap_pool).csize_t)
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
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  let env = bcnEnvView()
  if param == nil or mmBcnRequestExecuting(param) or env.templatePtr == param:
    return
  if not mmBcnStopping and env.active == 0 and env.templatePtr == nil and
      env.pendingCount != 0:
    env.templatePtr = param
    env.deferredChange = 1
    return
  discard mmBcnApplyUpdate(param, saved)

proc mm_ap_probe_cfm*(param: pointer; txStatus: uint32) {.exportc, cdecl.} =
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
  if not txlFrameCallbackCurrent(): return
  if (txStatus and 0x80000000'u32) == 0: return
  let vif = vifChannelAt(param)
  if (txStatus and 0x00800000'u32) != 0:
    # Probe got ACKed: AP is still reachable.
    mmResetBeaconProbeCount(vif)
    return
  # A fresh beacon may have superseded the missed-beacon condition since TX.
  if vif.probeCount > 100:
    mm_send_connection_loss_ind(param, 16'u16)

proc mm_bcn_transmitted*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Apply deferred template/TIM updates after the last beacon completes.
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  if not txlFrameCallbackCurrent(): return
  if vifEntry == nil:
    return
  let vif = vifChannelAt(vifEntry)
  let vifIdx = vif.vifIdx
  if vifIdx >= MAX_VIFS.uint8 or vifChannelForIdx(vifIdx) != vif or
      vif.vifType != VIF_TYPE_AP:
    return
  let vifEpoch = rxVifEpochs[vifIdx]
  let poolEpoch = mmBcnGeneration
  let env = bcnEnvView()
  let pending = env.pendingCount
  if pending == 0:
    assert_err("mm_bcn.c", "mm_bcn.c", 478)
    return
  # Decrement pending count
  let newPending = pending - 1
  env.pendingCount = newPending
  if newPending != 0 or mmBcnStopping:
    return
  # Apply queued TIM changes before a template update can start another DMA.
  let timQueue = addr env.timQueue
  while timQueue.first != nil:
    let popped = co_list_pop_front(timQueue)
    if popped == nil:
      break
    # Process deferred TIM update (blob: mm_tim_update_proceed, NOT ke_msg_send)
    mm_tim_update_proceed(keMsgPayload(cast[ptr KeMsgHdr](popped)))
    if not mmBcnOwnerCurrent(vifIdx, vifEpoch, poolEpoch):
      return
  if env.deferredChange != 0:
    discard mmBcnApplyUpdate(env.templatePtr, saved)

proc mmBeaconTemplateValid(req: ptr BeaconChangeReqView, payloadLength: uint32): bool =
  const prefixSize = offsetof(BeaconChangeReqView, frameData).uint32
  if payloadLength < prefixSize:
    return false
  let length = req.frameLen.uint32
  if req.vifIdx >= MAX_VIFS.uint8 or length < 36 or
     length > (sizeof(txl_bcn_pool) - 0x15C).uint32 or
     length > payloadLength - prefixSize or req.frameData[0] != 0x80:
    return false
  var offset = 36'u32
  var foundTim = false
  while offset < length:
    if length - offset < 2:
      return false
    let ieLength = req.frameData[offset + 1].uint32 + 2
    if ieLength > length - offset:
      return false
    if req.frameData[offset] == 5:
      if foundTim or offset != req.timOffset.uint32 or
         ieLength != req.timLength.uint32 or ieLength < 6 or
         req.frameData[offset + 3] == 0:
        return false
      foundTim = true
    offset += ieLength
  foundTim

proc mmBeaconChangeConfirm(header: ptr KeMsgHdr, status: uint8) =
  # Success retains the vendor's empty CFM. Rejections carry a status byte.
  let length = if status == 0: 0'u32 else: sizeof(MmBcnChangeCfmPayload).uint32
  let cfm = cast[ptr MmBcnChangeCfmPayload](
    ke_msg_alloc_reply(keMsgPayload(header), MM_BCN_CHANGE_CFM, length))
  if cfm != nil:
    if status != 0:
      cfm.status = status
    ke_msg_send(cfm)

proc mmBcnFinishUpdate(scope: ptr MmBcnUpdateScope; status: uint8;
                       callbackIrq: uint32) =
  let header = keMsgHdrFromPayload(scope.request)
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  irqRestore(callbackIrq)
  mmBeaconChangeConfirm(header, status)
  discard irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  # Keep duplicate requests guarded through confirmation, but allow the
  # allocator to reuse this address once the request has actually been freed.
  mmBcnActiveUpdate = scope.previous
  scope.request = nil
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  irqRestore(callbackIrq)
  ke_msg_free(header)
  discard irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}

proc mmBcnApplyUpdate(request: pointer; callbackIrq: uint32): pointer =
  # Called with IRQs masked. Only queued requests remain in templatePtr;
  # an executing request belongs to this stack scope, including during reset.
  if request == nil or mmBcnRequestExecuting(request):
    return nil
  let env = bcnEnvView()
  if env.templatePtr == request and env.pendingCount != 0 and not mmBcnStopping:
    return nil
  var scope = MmBcnUpdateScope(previous: mmBcnActiveUpdate, request: request)
  mmBcnActiveUpdate = addr scope
  if env.templatePtr == request:
    env.templatePtr = nil
    env.deferredChange = 0
  var status = 1'u8
  var vifIdx: uint8
  var vifEpoch, poolEpoch: uint32
  var claimed = false
  block apply:
    if mmBcnStopping or env.active != 0 or env.pendingCount != 0 or
        env.templatePtr != nil:
      status = 8
      break apply
    let bcnReq = beaconChangeReqAt(request)
    if not mmBeaconTemplateValid(bcnReq, keMsgHdrFromPayload(request).paramLen):
      break apply
    vifIdx = bcnReq.vifIdx
    let vif = vifChannelForIdx(vifIdx)
    if vif.vifType != VIF_TYPE_AP or vif.beaconTxDesc == nil:
      break apply
    vifEpoch = rxVifEpochs[vifIdx]
    inc mmBcnGeneration
    poolEpoch = mmBcnGeneration
    claimed = true
    let txDescPtr = vif.beaconTxDesc
    let frameLength = bcnReq.frameLen
    let timOffset = bcnReq.timOffset.uint32
    let timLength = bcnReq.timLength.uint32
    let dtimPeriod = bcnReq.frameData[timOffset + 3]
    let frame = cast[pointer](addr txl_bcn_pool[0x15C])
    env.active = 1
    discard c_memcpy(frame, addr bcnReq.frameData[0], frameLength.csize_t)
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(callbackIrq)
    me_beacon_check(vifIdx, frameLength, frame)
    discard irqSave()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    if not mmBcnOwnerCurrent(vifIdx, vifEpoch, poolEpoch) or
        env.active == 0 or vif.beaconTxDesc != txDescPtr:
      break apply

    let txDesc = hostTxHwDescAt(txDescPtr)
    let frameStart = pointerAddrU32(frame)
    txDesc.payloadStart = frameStart
    txDesc.payloadEnd = frameStart + timOffset - 1
    let endDesc = beaconEndDesc()
    endDesc.status = 0
    endDesc.next = 0
    let timDesc = timDescView()
    if timOffset + timLength < frameLength.uint32:
      endDesc.payloadStart = frameStart + timOffset + timLength
      endDesc.payloadEnd = frameStart + frameLength.uint32 - 1
      timDesc.bitmapNext = cast[pointer](endDesc)
    else:
      # No suffix: avoid an inclusive DMA range with start greater than end.
      endDesc.payloadStart = 0
      endDesc.payloadEnd = 0
      timDesc.bitmapNext = nil
    if vif.timCount == 0:
      timDesc.next = timDesc.bitmapNext
    vif.beaconBodyLength = frameLength - timLength.uint16
    timIeAt(addr txl_tim_ie_pool[0]).dtimPeriod = dtimPeriod
    let bufCtrl24G = txBufferControl24G()
    txDesc.chainedThd = cast[pointer](bufCtrl24G)
    bufCtrl24G.txPower = (regRead(0x24B000A0'u) and 0xFF).int32
    txDesc.retryLimitControl = 0
    txDesc.controlFlags = 0
    txDesc.status = pointerAddrU32(timDesc)
    vif.beaconEnabled = 1
    status = 0
  if claimed and mmBcnOwnerCurrent(vifIdx, vifEpoch, poolEpoch):
    env.active = 0
  mmBcnFinishUpdate(addr scope, status, callbackIrq)
  if status == 0 and mmBcnOwnerCurrent(vifIdx, vifEpoch, poolEpoch) and
      not mmBcnStopping and env.active == 0 and env.pendingCount == 0 and
      env.transmitRequested != 0:
    mm_bcn_transmit(vifIdx)
    discard irqSave()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  nil

proc mm_bcn_update*(vifEntry: pointer): pointer {.exportc, cdecl, noinline.} =
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  discard mmBcnApplyUpdate(vifEntry, saved)
  nil

proc mm_bcn_transmit*(vifIdx: uint8) {.exportc, cdecl.} =
  ## Submit the shared beacon only when its TIM and template are stable.
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  let env = bcnEnvView()
  if mmBcnStopping:
    return
  if env.pendingCount != 0:
    assert_err("mm_bcn.c", "mm_bcn.c", 701)
    return
  if env.active != 0:
    env.transmitRequested = 1
    return
  env.transmitRequested = 0
  var selected: pointer
  var vifEntry = cast[pointer](vifMgmtEnvView().activeList.first)
  while vifEntry != nil:
    let vif = vifChannelAt(vifEntry)
    vifEntry = vif.next
    if vif.vifType != VIF_TYPE_AP or vif.beaconEnabled == 0 or
       vif.beaconCountdown != vif.beaconDivisor or vif.beaconTxDesc == nil:
      continue
    if vif.vifIdx < MAX_VIFS.uint8 and vifChannelForIdx(vif.vifIdx) == vif:
      selected = cast[pointer](vif)
      break
  if selected == nil:
    return
  # Registration reserves the single shared beacon pool for one AP.
  let vif = vifChannelAt(selected)
  let staHwIdx = vif.vifIdx
  let vifEpoch = rxVifEpochs[staHwIdx]
  let txDescPtr = vif.beaconTxDesc
  let hwDesc = hostTxHwDescAt(txDescPtr)
  let frameStart = hwDesc.payloadStart
  if frameStart == 0:
    return
  inc mmBcnGeneration
  let poolEpoch = mmBcnGeneration
  let resetEpoch = txResetEpoch
  env.active = 1
  defer:
    if mmBcnOwnerCurrent(staHwIdx, vifEpoch, poolEpoch):
      env.active = 0
  template ownsPreparation(): bool =
    mmBcnOwnerCurrent(staHwIdx, vifEpoch, poolEpoch) and
      not mmBcnStopping and vif.beaconEnabled != 0 and
      vif.beaconTxDesc == txDescPtr and hwDesc.payloadStart == frameStart
  template current(): bool =
    resetEpoch == txResetEpoch and ownsPreparation()

  let bcnDesc = vifApBeaconFrameDesc(vif)
  let bcnFrame = cast[pointer](bcnDesc)
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  irqRestore(saved)
  tpc_update_frame_tx_power(cast[pointer](vif), bcnFrame)
  discard irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  if not current():
    return
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  irqRestore(saved)
  let onChannel = chan_is_on_operational_channel(cast[pointer](vif))
  discard irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  if not current() or not onChannel:
    return
  let frame = beaconFrameFixedView(cast[pointer](frameStart.uint))
  let timIe = timIeAt(addr txl_tim_ie_pool[0])
  let period = max(timIe.dtimPeriod, 1'u8)
  let currentDtim = if vif.timCountdown < period: vif.timCountdown else: 0'u8
  let deliverMulticast = currentDtim == 0 and vif.timFlags != 0
  let oldDtim = timIe.dtimCount
  let oldControl = timIe.bitmapControl
  let oldCountdown = vif.timCountdown
  let oldSequence = frame.seqCtrl
  let oldLength = hwDesc.frameLen
  timIe.dtimCount = currentDtim
  timIe.bitmapControl = (oldControl and 0xFE) or deliverMulticast.uint8
  vif.timCountdown = if currentDtim == 0: period - 1 else: currentDtim - 1
  frame.seqCtrl = nextTxSeqCtrl()
  hwDesc.frameLen = vif.beaconBodyLength.uint32 + vif.timLength.uint32 + 4
  bcnDesc.vifIdx = staHwIdx
  bcnDesc.staInfoIdx = 0xFF'u8
  # Transfer preparation to the pending reservation before any completion.
  env.pendingCount = 1
  env.active = 0
  env.transmitRequested = 0
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  irqRestore(saved)
  let pushResult = txl_frame_push(bcnFrame, 4)
  discard irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  if not ownsPreparation():
    return
  if pushResult == 0:
    if env.pendingCount == 1:
      env.pendingCount = 0
      timIe.dtimCount = oldDtim
      timIe.bitmapControl = oldControl
      vif.timCountdown = oldCountdown
      frame.seqCtrl = oldSequence
      # The vendor does not refund sequence numbers after a failed push.
      hwDesc.frameLen = oldLength
    return
  if resetEpoch != txResetEpoch:
    return
  if deliverMulticast:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
    let trafficMsg = cast[ptr MmTrafficReqIndPayload](
      ke_msg_alloc(MM_TRAFFIC_REQ_IND, TASK_API, TASK_MM,
                   MmTrafficReqIndPayloadSize))
    discard irqSave()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    if not current():
      if trafficMsg != nil:
        irqRestore(saved)
        ke_msg_free(keMsgHdrFromPayload(trafficMsg))
        discard irqSave()
        {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      return
    if trafficMsg != nil:
      trafficMsg.staIdx = staHwIdx + 5
      trafficMsg.packetCount = 0
      trafficMsg.uapsd = 0
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      irqRestore(saved)
      ke_msg_send(trafficMsg)
      discard irqSave()
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      if not current():
        return
    let bcnSta = staInfoForIdx(cast[uint8](staHwIdx.uint + 5'u))
    if (bcnSta.trafficFlags and 2) != 0:
      bcnSta.psStatus = 9
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      irqRestore(saved)
      discard sta_mgmt_send_postponed_frame(cast[pointer](vif), cast[pointer](bcnSta), 0'u32)
      discard irqSave()
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      if current() and bcnSta.psStatus == 9:
        bcnSta.psStatus = 0

proc mm_tim_update*(msgBody: pointer) {.exportc, cdecl, noinline.} =
  ## Update TIM (Traffic Indication Map) in beacon (10 instrs).
  ## From blob: a0 is a pointer to the message body (msg payload).
  ## Checks mm_bcn_env+4 (pending beacon). If non-zero, subtracts 12 from a0
  ## to get the ke_msg header and tail-calls co_list_push_back on the TIM
  ## update queue at mm_bcn_env+12. If zero, tail-calls mm_tim_update_proceed.
  ## noinline: blob calls this from mm_tim_update_req_handler (gap target).
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  if msgBody == nil:
    return
  let saved = irqSave()
  defer: irqRestore(saved)
  if mmBcnStopping or not mmTimMessageCurrent(keMsgHdrFromPayload(msgBody)):
    let header = keMsgHdrFromPayload(msgBody)
    let sender = header.srcId
    ke_msg_send_basic(0x30, sender, TASK_MM)
    ke_msg_free(header)
    return
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

proc mmTimerCancelMutations(timer: pointer = nil; all = false) =
  let saved = irqSave()
  defer: irqRestore(saved)
  inc mmTimerRevision
  var operation = mmTimerMutationTop
  while operation != nil:
    if all or operation.timer == timer: operation.cancelled = true
    operation = operation.previous

proc mmTimerBeginMutation(operation: var MmTimerMutation; timer: pointer) =
  mmTimerCancelMutations(timer)
  operation = MmTimerMutation(previous: mmTimerMutationTop, timer: timer)
  mmTimerMutationTop = addr operation

proc mmTimerEndMutation(operation: var MmTimerMutation) =
  mmTimerMutationTop = operation.previous

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
  let saved = irqSave()
  defer: irqRestore(saved)
  chanTimerInvalidate()
  mmTimerCancelMutations(all = true)
  co_list_init(addr mm_timer_list)
  inc mmStaDelRetryReset
  mmStaDelRetryMask = 0
  mmStaDelRetryTimer = default(MmTimerView)
  for deletion in mmStaDeletions.mitems:
    deletion = default(MmStaDeletion)

proc mmTimerSetLocked(timer: pointer; targetTime, saved: uint32) =
  ## Caller holds the IRQ lock; saved is the incoming callback IRQ state.
  ## Set an MM-level timer with absolute target time.
  ## From blob (76 instrs): reads MAC HW timestamp. If targetTime is in the past,
  ## clamps to current_time + 3000 (0xBB8). Removes timer from list if present
  ## (pop_front if head, else co_list_extract). Stores target time at timer[12].
  ## Sorted-inserts into mm_timer_list and programs the earliest hardware deadline.
  ## If time already expired, tail-calls ke_evt_set for immediate processing.
  if timer == nil: return
  var operation: MmTimerMutation
  mmTimerBeginMutation(operation, timer)
  defer: mmTimerEndMutation(operation)
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  chanTimerArming(timer)
  let macTime = regRead(MACHW_TIMLO_REG)
  if operation.cancelled: return
  var expiry = targetTime
  outside: nimFwTrace2U32("[WIFI-NIMFW] mm_timer_set in ", macTime, targetTime)
  if operation.cancelled: return
  let diff = cast[int32](targetTime - macTime)
  if diff < 0:
    # Timer already past: clamp to now + 3000 ticks (~3ms)
    expiry = regRead(MACHW_TIMLO_REG) + 0xBB8'u32
    if operation.cancelled: return

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
  outside: nimFwTrace2U32("[WIFI-NIMFW] mm_timer_set timer ", cast[uint32](cast[uint](timer)), expiry)
  if operation.cancelled: return

  # Sorted insert by time
  co_list_insert(addr mm_timer_list, timerHdr, cmp_mm_timer_time)
  chanTimerPublished(timer)

  # If timer is now first (or was first), program HW timer (blob: mm_timer_hw_set)
  if wasFirst or (mm_timer_list.first == timerHdr):
    outside: mm_timer_hw_set(cast[pointer](mm_timer_list.first))
    if operation.cancelled: return

  # Check if already expired -- trigger immediate processing
  let macTime2 = regRead(MACHW_TIMLO_REG)
  if operation.cancelled: return
  let remaining = cast[int32](expiry - macTime2)
  if remaining <= 0:
    ke_evt_set(KE_EVT_MM_TIMER)

proc mm_timer_set*(timer: pointer, targetTime: uint32) {.exportc, cdecl.} =
  if timer == nil: return
  let saved = irqSave()
  defer: irqRestore(saved)
  mmTimerSetLocked(timer, targetTime, saved)

proc mmTimerClearLocked(timer: pointer; saved: uint32) =
  ## Caller holds the IRQ lock; saved is the incoming callback IRQ state.
  ## Clear an MM-level timer.
  ## From blob (22 instrs):
  ##   if (timer == list.first):
  ##       co_list_pop_front(&list)
  ##       mm_timer_hw_set(list.first)        ; direct HW reprogramming
  ##   else:
  ##       co_list_extract(&list, timer)
  ## The blob tail-calls mm_timer_hw_set (NOT mm_timer_schedule) with the new
  ## list head after popping.
  if timer == nil: return
  var operation: MmTimerMutation
  mmTimerBeginMutation(operation, timer)
  defer: mmTimerEndMutation(operation)
  chanTimerInvalidate(timer)
  let timerHdr = mmTimerAt(timer).mmTimerHdr
  let first = mm_timer_list.first
  if timerHdr == first:
    # Timer is head: pop and reprogram HW with the new head (may be nil).
    discard co_list_pop_front(addr mm_timer_list)
    irqRestore(saved)
    try: mm_timer_hw_set(cast[pointer](mm_timer_list.first))
    finally: discard irqSave()
  else:
    # Timer is not head: just extract
    co_list_extract(addr mm_timer_list, timerHdr)

proc mm_timer_clear*(timer: pointer) {.exportc, cdecl.} =
  if timer == nil: return
  let saved = irqSave()
  defer: irqRestore(saved)
  mmTimerClearLocked(timer, saved)

proc mmTimerExpired(node: ptr CoListHdr; fromPoll: static bool = false): bool {.inline.} =
  if node == nil: return false
  let revision = mmTimerRevision
  let expiry = mmTimerAt(node).expiry
  let now = regRead(MACHW_TIMLO_REG)
  if mmTimerRevision != revision: return false
  when fromPoll:
    cast[int32](expiry - now) <= 0
  else:
    cast[int32](expiry - now - 50'u32) < 0

proc mm_timer_schedule*() {.exportc, cdecl.} =
  ## Schedule MM timers -- process all expired timers.
  ## From blob (64 instrs): loop: clear pending timer event. Load list head.
  ## If null, disable abs timer and return. Check head.time vs MAC HW time;
  ## if not expired (diff >= -50), program abs timer and return.
  ## If expired, pop head, call callback(env), repeat.
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    if mmTimerScheduling: return
    mmTimerScheduling = true
  var delivery: MmTimerMutation
  template retireDelivery() =
    if delivery.timer != nil:
      mmTimerEndMutation(delivery)
      delivery.timer = nil
  defer:
    let saved = irqSave()
    retireDelivery()
    mmTimerScheduling = false
    irqRestore(saved)
  var attempts = 0'u32
  while attempts < WifiTimerDrainLimit:
    inc attempts
    let expiredTimer = block:
      let saved = irqSave()
      defer: irqRestore(saved)
      retireDelivery()
      template outside(body: untyped) =
        irqRestore(saved)
        try: body
        finally: discard irqSave()
      ke_evt_clear(KE_EVT_MM_TIMER)
      let head = mm_timer_list.first
      if head == nil:
        outside: mm_timer_hw_set(nil)
        return
      let revision = mmTimerRevision
      let headTimer = mmTimerAt(head)
      let expiry = headTimer.expiry
      let macTime = regRead(MACHW_TIMLO_REG)
      if mmTimerRevision != revision or mm_timer_list.first != head: continue
      if cast[int32](expiry - macTime - 50'u32) >= 0:
        outside: mm_timer_hw_set(cast[pointer](head))
        if mmTimerRevision != revision or mm_timer_list.first != head: continue
        let macTime2 = regRead(MACHW_TIMLO_REG)
        if mmTimerRevision != revision or mm_timer_list.first != head: continue
        if cast[int32](expiry - macTime2) > 0: return
      let callback = headTimer.callback
      let argument = cast[pointer](headTimer.env)
      let serial = chanTimerCapture(cast[pointer](head))
      discard co_list_pop_front(addr mm_timer_list)
      # A same-address clear/rearm after pop still retires this delivery.
      mmTimerBeginMutation(delivery, cast[pointer](head))
      delivery.delivering = true
      (timer: cast[pointer](head), callback: callback, argument: argument, serial: serial)
    if expiredTimer.callback != nil and not chanTimerDispatch(expiredTimer.timer,
        expiredTimer.callback, expiredTimer.argument, expiredTimer.serial):
      cast[proc(env: pointer) {.cdecl.}](expiredTimer.callback)(expiredTimer.argument)

  let saved = irqSave()
  defer: irqRestore(saved)
  retireDelivery()
  let nextTimerNode = mm_timer_list.first
  if nextTimerNode != nil and mmTimerExpired(nextTimerNode):
    nimFwDbgMmTimerYieldHead = mmTimerAt(nextTimerNode).expiry
    inc nimFwDbgMmTimerYield
    ke_evt_set(KE_EVT_MM_TIMER)
  else:
    irqRestore(saved)
    try: mm_timer_hw_set(cast[pointer](mm_timer_list.first))
    finally: discard irqSave()

# ###########################################################################
#                     CHANNEL MANAGEMENT (chan_*)
# ###########################################################################

type
  ChanTbttSnapshot = object
    generation, resetEpoch: uint32
    allocations: array[5, uint32]
    bindings, vifs: array[MAX_VIFS, uint32]

var
  chanCtxtEpochs {.wifiCtrl.}: array[5, uint32]
  chanBcnDetectActive {.wifiCtrl.}: bool
  chanCdeGeneration {.wifiCtrl.}: uint32
  chanTbttGeneration {.wifiCtrl.}: uint32
  chanStatusGeneration {.wifiCtrl.}: uint32
  chanConnlessGeneration {.wifiCtrl.}: uint32

proc chanTbttBegin(snapshot: var ChanTbttSnapshot) =
  inc chanTbttGeneration
  snapshot.generation = chanTbttGeneration
  snapshot.resetEpoch = txResetEpoch
  snapshot.allocations = chanCtxtEpochs
  snapshot.bindings = chanCtxtLinkEpochs
  snapshot.vifs = rxVifEpochs

proc chanTbttCurrent(snapshot: var ChanTbttSnapshot): bool =
  snapshot.generation == chanTbttGeneration and snapshot.resetEpoch == txResetEpoch and
    equalMem(addr snapshot.allocations, addr chanCtxtEpochs, sizeof(chanCtxtEpochs)) and
    equalMem(addr snapshot.bindings, addr chanCtxtLinkEpochs, sizeof(chanCtxtLinkEpochs)) and
    equalMem(addr snapshot.vifs, addr rxVifEpochs, sizeof(rxVifEpochs))

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
  ##   offset 68: .LANCHOR2 (the static CDE event byte)
  ##   offset 80: chan_ctxt_op_evt
  ##   offset 96: chan_conn_less_delay_evt
  chanBcnRequestReset()
  chanSwitchReset()
  let env = chanEnvView()
  for epoch in chanCtxtEpochs.mitems: inc epoch
  for epoch in chanCtxtLinkEpochs.mitems: inc epoch
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
  # The timer delivers event 0 from static storage, not a message pointer.
  env.cdeArg = addr cde_evt_tmr_msg
  env.ctxtOpCallback = cast[pointer](chan_ctxt_op_evt)
  env.connLessDelayCallback = cast[pointer](chan_conn_less_delay_evt)
  # Vendor .bss counters outside chan_env.
  chanConflictCount = 0
  chanSlotConfigCycles = 0

proc chan_ctxt_add*(param: pointer, ctxtIdxOut: ptr uint8): uint8 {.exportc, cdecl.} =
  ## Add channel context. Search existing for match, else allocate from free list.
  ## From disassembly (68 instrs).
  if param == nil or ctxtIdxOut == nil:
    return 1
  let env = chanEnvView()
  let poolBase = cast[uint](addr chan_ctxt_pool[0])
  for existingChannelContextIndex in 0'u8 ..< 3:
    let ctxt = chanCtxtAt(poolBase + existingChannelContextIndex.uint * sizeof(ChanCtxtView).uint)
    if ctxt.contextIndexOrMarker != 0xFF:
      if c_memcmp(addr ctxt.channel, param, 8.csize_t) == 0:
        ctxtIdxOut[] = existingChannelContextIndex
        return 0
  let freeCtxt = env.freeList.first
  if freeCtxt == nil:
    return 1
  let freeAddress = cast[uint](freeCtxt)
  let allocatableBytes = MAX_CHAN_CTXT.uint * sizeof(ChanCtxtView).uint
  if freeAddress < poolBase or freeAddress - poolBase >= allocatableBytes or
      (freeAddress - poolBase) mod sizeof(ChanCtxtView).uint != 0:
    return 1
  let ctxt = chanCtxtAt(cast[pointer](freeCtxt))
  if ctxt.contextIndexOrMarker != 0xFF'u8:
    return 1
  discard co_list_pop_front(addr env.freeList)
  let chanCtxtPoolIndex =
    ((cast[uint](ctxt) - poolBase) div sizeof(ChanCtxtView).uint).uint8
  inc chanCtxtEpochs[chanCtxtPoolIndex]
  ctxt.contextIndexOrMarker = chanCtxtPoolIndex
  ctxtIdxOut[] = chanCtxtPoolIndex
  ctxt.channel = cast[ptr ChanCtxtDefView](param)[]
  return 0

proc chan_ctxt_del*(ctxtIdx: uint8) {.exportc, cdecl.} =
  ## Delete a channel context (58 instrs in blob).
  ## Validates context is in use (offset 23 != 0xFF) and has no linked VIFs
  ## (offset 24 == 0). Port: a switch to the context is redirected (or, with
  ## no context left, abandoned) before the cleared slot is returned; the blob
  ## leaves chan_env+36 pointing at the freed slot.
  let saved = irqSave()
  defer: irqRestore(saved)
  if ctxtIdx >= MAX_CHAN_CTXT.uint8:
    assert_err("chan.c", "chan.c", 0xAD0)
    return
  let env = chanEnvView()
  let ctxt = chanCtxtForIdx(ctxtIdx)
  # Only the owner slot may be retired.
  if ctxt.contextIndexOrMarker != ctxtIdx:
    # Blob uses assert_err for chan_ctxt_del invariants.
    assert_err("chan.c", "chan.c", 0xAD0)
    return
  if ctxt.linkCount != 0:
    assert_err("chan.c", "chan.c", 0xAD2)
    return
  # Hide the slot before the switch is redirected away from it.
  inc chanCtxtEpochs[ctxtIdx]
  let retiredEpoch = chanCtxtEpochs[ctxtIdx]
  ctxt.markInvalid()
  chanSwitchRetire(cast[pointer](ctxt))
  if chanCtxtEpochs[ctxtIdx] != retiredEpoch: return
  # Clear the context with memset
  discard c_memset(cast[pointer](ctxt), 0, sizeof(ChanCtxtView).csize_t)
  # Restore invalid markers at the computed slot
  ctxt.markInvalid()
  co_list_push_back(addr env.freeList, ctxt.chanCtxtHdr)

proc chan_ctxt_link*(vifIdx: uint8, ctxtIdx: uint8) {.exportc, cdecl.} =
  ## Link a channel context to a VIF (83 instrs).
  ## Vendor ABI: VIF index in a0, channel-context index in a1.
  ## Computes channel context slot = chan_ctxt_pool + ctxtIdx*28,
  ## computes VIF entry = vif_info_tab + vifIdx*1512.
  ## Asserts VIF's current channel ctx (vif+64) is null.
  ## Asserts slot's context-index/marker byte (slot+23) != 0xFF (slot in use).
  ## Stores slot pointer into VIF's channel ctx (vif+64).
  ## Adds survey frequency to chan_env accumulator (offset 108).
  ## Increments link count (slot+24). If link count becomes 1:
  ##   sets slot status to 1 (slot+22), increments chan_env context count (base+124),
  ##   appends to the active context list and calls chan_ctxt_trigger.
  ## Every link updates the shared channel's TX power limit.
  if vifIdx >= MAX_VIFS.uint8 or ctxtIdx >= MAX_CHAN_CTXT.uint8:
    return
  let env = chanEnvView()
  let ctxt = chanCtxtForIdx(ctxtIdx)
  let vif = vifChannelForIdx(vifIdx)
  # Assert VIF has no current channel context
  if vif.chanCtxt != nil:
    assert_err("chan.c", "chan.c", 0xAFE)
    return
  # Assert slot is in use (context-index/marker byte != 0xFF)
  if ctxt.contextIndexOrMarker == 0xFF:
    assert_err("chan.c", "chan.c", 0xAFF)
    return
  # Store slot pointer into VIF's channel context field
  inc chanCtxtLinkEpochs[vifIdx]
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
  ## Reschedules TBTT and updates TX power after unlinking.
  if vifIdx >= MAX_VIFS.uint8:
    return
  let vif = vifChannelForIdx(vifIdx)
  # Load channel context pointer from VIF offset 64
  let chanCtxtPtr = vif.chanCtxt
  if chanCtxtPtr == nil:
    # Blob emits assert_err here (line 2863 in chan.c); previous Nim used
    # assert_warn which maps to a different sink in the platform layer.
    assert_err("chan.c", "chan.c", 0xB2F)
    return
  let env = chanEnvView()
  # Extract VIF's TBTT node (vif+68) from chan_env scheduling list
  let tbttNode = chanTbttHdr(addr vif.tbttNode)
  co_list_extract(chanTbttPrimaryList(), tbttNode)
  # Clear VIF's link to channel context
  inc chanCtxtLinkEpochs[vifIdx]
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
        if env.currentCtxt == chanCtxtPtr:
          # Retire the current operation before returning its context to the pool.
          ctxt.status = 4
          mm_timer_clear(chanCtxtOpTimer())
          chan_ctxt_op_evt(chanCtxtPtr)
      # The blob re-points a switch to this context here (count > 1: CDE
      # event 1; count == 1: the remaining context). chan_ctxt_del below does
      # it for every retirement (chanSwitchRetire -> chanSwitchRedirect).
      ctxt.status = 0
  # Check link count for deletion (both scan-linked and non-scan-linked paths)
  if ctxt.linkCount == 0:
    chan_ctxt_del(ctxt.contextIndexOrMarker)
  # Update chan_env flags: clear bit 7
  let remCtxtCnt = env.ctxtCount
  env.flags = env.flags and 0x7F
  if remCtxtCnt == 1:
    env.cdeStarted = 0
    env.schedState = 0
    if sm_reconn_dominant_flag != 0:
      env.dominantCtxt = nil
  chan_tbtt_schedule(nil)
  chan_update_tx_power(chanCtxtPtr)

proc chanLeaseCurrent(lease: ChanCtxtLease): bool =
  if not lease.held or lease.index >= MAX_CHAN_CTXT.uint8 or
      chanCtxtEpochs[lease.index] != lease.allocation:
    return false
  let ctxt = chanCtxtForIdx(lease.index)
  if ctxt.contextIndexOrMarker != lease.index: return false
  not lease.linked or (lease.vif < MAX_VIFS.uint8 and
    chanCtxtLinkEpochs[lease.vif] == lease.binding and
    rxVifEpochs[lease.vif] == lease.vifEpoch and
    vifChannelForIdx(lease.vif).chanCtxt == cast[pointer](ctxt))

proc chanLeaseAcquire(request: pointer; lease: var ChanCtxtLease): uint8 =
  let saved = irqSave()
  defer: irqRestore(saved)
  if request == nil or lease.held: return 1
  let previous = chanCtxtEpochs
  var index = 0xFF'u8
  result = chan_ctxt_add(request, addr index)
  if result != 0: return
  if index >= MAX_CHAN_CTXT.uint8: return 1
  lease = ChanCtxtLease(index: index, vif: 0xFF, held: true,
    allocation: chanCtxtEpochs[index], created: previous[index] != chanCtxtEpochs[index])

proc chanLeaseLink(lease: var ChanCtxtLease; vifIndex: uint8): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  if not chanLeaseCurrent(lease) or lease.linked or vifIndex >= MAX_VIFS.uint8 or
      vifChannelForIdx(vifIndex).chanCtxt != nil: return false
  lease.vif = vifIndex
  lease.vifEpoch = rxVifEpochs[vifIndex]
  lease.binding = chanCtxtLinkEpochs[vifIndex] + 1
  lease.linked = true
  chan_ctxt_link(vifIndex, lease.index)
  chanLeaseCurrent(lease)

proc chanLeaseRelease(lease: var ChanCtxtLease) =
  let saved = irqSave()
  defer: irqRestore(saved)
  let retired = lease
  lease = default(ChanCtxtLease)
  if not chanLeaseCurrent(retired): return
  if retired.linked:
    chan_ctxt_unlink(retired.vif)
  elif retired.created and chanCtxtForIdx(retired.index).linkCount == 0:
    chan_ctxt_del(retired.index)

proc chan_ctxt_update*(param: pointer) {.exportc, cdecl.} =
  ## Store the definition; only the current context drains RX and retunes.
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  if param == nil:
    return
  let req = cast[ptr MmChanCtxtUpdatePayload](param)
  let ctxtIdx = req.ctxtIdx
  if ctxtIdx >= MAX_CHAN_CTXT.uint8:
    return
  let env = chanEnvView()
  let ctxt = chanCtxtForIdx(ctxtIdx)
  if ctxt.contextIndexOrMarker != ctxtIdx:
    return
  let epoch = chanCtxtEpochs[ctxtIdx]
  var channel = cast[ptr ChanCtxtDefView](addr req.band)[]
  ctxt.channel = channel
  let thisCtxt = cast[pointer](ctxt)
  if env.currentCtxt != thisCtxt:
    return
  template current(): bool =
    chanCtxtEpochs[ctxtIdx] == epoch and ctxt.contextIndexOrMarker == ctxtIdx and
      env.currentCtxt == thisCtxt and ctxt.channel.band == channel.band and
      ctxt.channel.chanType == channel.chanType and
      ctxt.channel.primFreq == channel.primFreq and
      ctxt.channel.centerFreq1 == channel.centerFreq1 and
      ctxt.channel.centerFreq2 == channel.centerFreq2 and
      ctxt.channel.phyEnvFlags == channel.phyEnvFlags
  rxl_timer_int_handler()
  if not current():
    return
  rxl_cntrl_evt()
  if not current():
    return
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  irqRestore(saved)
  phySetChannel(addr channel)
  discard irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  if not current():
    return
  let power = ctxt.channel.txPower
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  irqRestore(saved)
  tpc_update_tx_power(power)
  discard irqSave()

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
    var event = 0'u8
    chan_cde_evt(addr event)

proc chan_ctxt_cnt*(): uint8 {.exportc, cdecl, noinline.} =
  ## Return the number of active channel contexts.
  return chanEnvView().ctxtCount

proc chan_ctxt_set_auth_assoc_req*(msg: pointer) {.exportc, cdecl, noinline.} =
  ## Park the deferred auth/assoc message for the next channel activation.
  ## From blob (3 instrs): stores a0 at chan_env+0x80 and returns. SM is its
  ## only caller (smPark).
  chanEnvView().deferredMsg = msg

proc chan_ctxt_get_remaining_time_ms*(vifEntry: pointer): uint32 {.exportc, cdecl.} =
  ## Get remaining time in ms for the current channel context (30 instrs in blob).
  ## Asserts if vifEntry is NULL. Calls
  ## chan_is_on_operational_channel; if it returns false, returns 0. Otherwise
  ## reads MACHW_TIMLO and divides the unsigned 32-bit deadline delta by 1000.
  ## Keep the wrapped delta: zero tells the SM to transmit immediately, while
  ## an expired dwell must defer auth/assoc until the next channel activation.
  if vifEntry == nil:
    assert_err("chan.c", "chan.c", 0xD21)
    return 0
  if not chan_is_on_operational_channel(vifEntry):
    return 0
  let macTime = regRead(MACHW_TIMLO_REG)
  (chanEnvView().remainingTimeTarget - macTime) div 1000

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
  if req.duration == 0:
    return 0
  # A nonzero dwell needs at least one 1024 us slot. Raw channel requests
  # must not wrap the slot count even if they bypass SCAN_START_REQ validation.
  clamp(req.duration shr 10, 1'u32, high(uint16).uint32).uint16

template chanScanChannel(req: ptr ChanScanReqPayload): ptr ChanCtxtDefView =
  cast[ptr ChanCtxtDefView](addr req.band)

proc chan_scan_req*(param: pointer) {.exportc, cdecl.} =
  ## Request channel scan (65 instrs in blob).
  ## Blob keeps scan context state in chan_ctxt_pool, not chan_env.
  ## Start requests set up the scan context and tail-call
  ## chan_conn_less_delay_prog. Abort requests clear the scan timer and run
  ## chan_ctxt_op_evt. TASK_SCAN is the only caller; no call here can run
  ## its code or retire slot 3, so nothing is re-checked after one.
  if param == nil: return
  let reqType = cast[ptr uint8](param)[]
  var request: ChanScanReqPayload
  if reqType == 0: request = cast[ptr ChanScanReqPayload](param)[]
  else: request.reqType = reqType
  let scanReq = addr request
  let saved = irqSave()
  defer: irqRestore(saved)
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  outside:
    nimFwTrace2U32("[WIFI-NIMFW] chan_scan_req ", reqType.uint32, encodedArgU32(param))
  if reqType != 0 and reqType != 1:
    return
  let env = chanEnvView()
  if reqType == 0:
    let scan = chanScanPoolOverlay()
    if scan.slot != 0xFF:
      assert_err("chan.c", "chan.c", 0x9E5)
      return
    inc chanCtxtEpochs[3]
    scan.slot = 3
    scan.vifIdx = 0xFF
    scan.requestVifIdx = scanReq.vifIdx
    scan.active = 1
    outside:
      nimFwTrace2U32("[WIFI-NIMFW] chan_scan_req duration ",
                     scan.requestVifIdx.uint32, scanReq.duration)
    scan.durationTicks = chanScanDurationTicks(scanReq)
    discard c_memcpy(addr scan.channel, chanScanChannel(scanReq),
                     sizeof(ChanCtxtDefView).csize_t)
    nimFwDbgChanScanChanMeta = packChannelMeta(addr scan.channel)
    nimFwDbgChanScanChanFreq = packChannelFreq(addr scan.channel)
    outside:
      nimFwTrace2U32("[WIFI-NIMFW] chan_scan_req channel ",
                     scan.channel.band.uint32,
                     scan.channel.primFreq.uint32)
    let chanFlags = env.flags
    env.flags = chanFlags or 0x02
    outside:
      nimFwTrace2U32("[WIFI-NIMFW] chan_scan_req flags ", chanFlags.uint32, env.flags.uint32)
    when defined(bl808WifiDiagWarmScan): inc nimFwDbgWarmScan.slot_admitted
    outside: chan_conn_less_delay_prog()
    return
  outside: mm_timer_clear(chanCtxtOpTimer())
  outside: chan_ctxt_op_evt(cast[pointer](chanCtxtForIdx(3)))

proc chan_roc_req*(param: pointer; taskId: uint8): uint8 {.exportc, cdecl.} =
  ## Vendor ROC request: op 1 is acknowledged; other nonzero ops fail.
  ## A start request fills context slot 4 and preserves the const request.
  ## The task ID selects immediate internal switching or deferred scheduling.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  if param == nil: return 1
  let saved = irqSave()
  defer: irqRestore(saved)
  result = 1
  if not chanBcnRequestClaim(param, taskId): return
  defer: chanBcnRequestFinish(param, result)
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  let request = mmRemainOnChannelReqView(param)
  if request.opCode != 0:
    return (request.opCode != 1).uint8
  # Validate in milliseconds before multiplying or narrowing to a dwell slot.
  const maxDurationMs = ((1'u32 shl 26) - 1) div 1000
  if request.durationMs > maxDurationMs: return 1
  let roc = chanRocOverlay()
  if roc.slot != 0xFF:
    return 1
  inc chanCtxtEpochs[4]
  let req = request[]
  let env = chanEnvView()
  roc.vifIdx = taskId
  roc.stateLo = 0x01
  roc.slot = 0x04
  let durationTicks = (req.durationMs * 1000'u32) shr 10
  roc.durationTicks = max(durationTicks, (req.durationMs != 0).uint32).uint16
  roc.requestVifIdx = req.vifIdx
  roc.channel = req.channel
  result = 0
  if taskId == 0:
    env.flags = env.flags or 0x14
    if env.scheduledCtxt == nil:
      outside: chan_switch_start(cast[pointer](chanCtxtForIdx(4)))
  else:
    env.flags = env.flags or 0x01
    outside: chan_conn_less_delay_prog()

proc chan_bcn_to_evt*() {.exportc, cdecl, noinline.} =
  ## Handle beacon timeout event for channel management.
  ## noinline: blob's vif_mgmt_bcn_to_evt tail-calls this as a real function.
  ## The blob function itself is empty (just ret), but the call must be preserved.
  asm "nop"  # prevent GCC from dead-code-eliminating the call site

proc chan_bcn_detect_start*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Request a dwell using the VIF's associated station beacon interval.
  let saved = irqSave()
  defer: irqRestore(saved)
  if chanBcnDetectActive: return
  let identity = mmCaptureVif(vifEntry)
  let resetEpoch = txResetEpoch
  if not mmStaTimerCurrent(identity, resetEpoch) or
      identity.station >= STA_INFO_TAB_ENTRIES.uint8:
    return
  let vif = vifChannelAt(vifEntry)
  let chanCtxtPtr = vif.chanCtxt
  if chanCtxtPtr == nil:
    assert_err("chan.c", "chan.c", 0xC5E)
    return
  var contextIndex = MAX_CHAN_CTXT.uint8
  for index in 0'u8 ..< MAX_CHAN_CTXT.uint8:
    if cast[pointer](chanCtxtForIdx(index)) == chanCtxtPtr:
      contextIndex = index
      break
  if contextIndex == MAX_CHAN_CTXT.uint8: return
  let lease = ChanCtxtLease(index: contextIndex, vif: identity.index,
    allocation: chanCtxtEpochs[contextIndex],
    binding: chanCtxtLinkEpochs[identity.index], vifEpoch: identity.epoch,
    held: true, linked: true)
  if not chanLeaseCurrent(lease): return
  let sta = staInfoForIdx(identity.station)
  if sta.valid == 0 or sta.instNbr != identity.index: return
  let channel = chanCtxtAt(chanCtxtPtr).channel
  let beaconInterval = sta.initialRateConfig
  if beaconInterval < 5000'u32: return
  let env = chanEnvView()
  chanBcnRequestPrune()
  if (env.flags and 0x40) != 0 or env.ctxtCount < 2: return
  chanBcnDetectActive = true
  defer: chanBcnDetectActive = false
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  var param: ptr ChanConnLessDelayReqPayload
  outside:
    param = cast[ptr ChanConnLessDelayReqPayload](
      chanBcnRequestAllocate(identity, lease, channel, beaconInterval, resetEpoch))
  if param == nil: return
  if not mmStaTimerCurrent(identity, resetEpoch) or
      not chanLeaseCurrent(lease) or sta.valid == 0 or
      sta.instNbr != identity.index or sta.initialRateConfig != beaconInterval or
      chanCtxtAt(chanCtxtPtr).channel != channel or
      (env.flags and 0x40) != 0 or env.ctxtCount < 2:
    outside: ke_msg_free_payload(param)
    return
  param.remainingCount = 0
  param.band = identity.index
  param.durationMs = (beaconInterval - 5000'u32) div 1000
  copyMem(addr param.chanDef[0], unsafeAddr channel, sizeof(channel))
  if not chanBcnRequestPublish(param):
    outside: ke_msg_free_payload(param)
    return
  outside: ke_msg_send(param)

proc chan_tbtt_switch_update*(vifEntry: pointer, tbttTime: uint32) {.exportc, cdecl.} =
  ## Update TBTT switch scheduling (36 instrs in blob).
  ## Reads channel context from vifEntry+64, checks status byte at ctxt+22.
  ## If no context or status==0, returns. Computes TBTT target offset based
  ## on whether multiple contexts are active (9000 us for multi, 3000 for single).
  ## Updates vifEntry+72 with new target. If multiple contexts: clears vifEntry+78,
  ## calls co_list_extract on chan_env list, then tail-calls chan_tbtt_insert.
  if vifEntry == nil:
    return
  let saved = irqSave()
  defer: irqRestore(saved)
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
  inc chanTbttGeneration
  # Store new TBTT target
  tbttNode.targetTime = tbttTarget
  # Only do list operations if multiple contexts
  if ctxtCount <= 1:
    return
  # Clear scheduling state and re-insert into TBTT list
  tbttNode.state = 0
  co_list_extract(chanTbttPrimaryList(), chanTbttHdr(tbttNode))
  irqRestore(saved)
  try: chan_tbtt_schedule(cast[pointer](tbttNode))
  finally: discard irqSave()

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

proc chanTbttSwitchEvent(tbttNode: pointer; saved: uint32) =
  ## The timer environment is the TBTT node. Debit elapsed 1024-us slots,
  ## consume up to 20 reserved slots, then request its channel when permitted.
  if tbttNode == nil:
    return
  let node = chanTbttNodeAt(tbttNode)
  if node.state == 2 or (node.state == 1 and chanTbttDeferredSlot()[] != tbttNode):
    return
  var operation: ChanTbttSnapshot
  chanTbttBegin(operation)
  if chanTbttDeferredSlot()[] == tbttNode:
    chanTbttDeferredSlot()[] = nil
  if node.state == 1:
    node.state = 0
  let env = chanEnvView()
  let ctxtCnt = env.ctxtCount
  if ctxtCnt <= 1:
    return
  let vifIdx = node.vifIdx
  if vifIdx >= MAX_VIFS.uint8:
    return
  # Look up VIF's current chan ctxt (vif[64]) via vif_info_tab[vifIdx]
  let vif = vifChannelForIdx(vifIdx)
  let vifChanCtxt = vif.chanCtxt
  if vifChanCtxt == nil:
    return
  let target = node.targetTime
  let state = node.state
  let priority = node.priority
  let currentCtxt = env.currentCtxt
  let scheduledCtxt = env.scheduledCtxt
  let deferred = chanTbttDeferredSlot()[]
  let lastTime = env.lastMacTime
  template current(): bool =
    chanTbttCurrent(operation) and node.vifIdx == vifIdx and
      node.targetTime == target and node.state == state and node.priority == priority and
      vif.chanCtxt == vifChanCtxt and env.ctxtCount == ctxtCnt and
      env.currentCtxt == currentCtxt and env.scheduledCtxt == scheduledCtxt and
      env.lastMacTime == lastTime and chanTbttDeferredSlot()[] == deferred
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  let macTime = macTimeNow()
  if not current(): return
  # Blob: s1 = vifChanCtxt (vif[64]); a0 = chan_get_dominant_chan().
  # Proceed iff a0 == NULL OR a0 == s1. Otherwise return.
  var dominant: pointer
  outside: dominant = chan_get_dominant_chan()
  if not current(): return
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
    let elapsed = ((macTime - oldOffset) shr 10) and 0xFFFF'u32
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
    outside: chan_switch_start(vifChanCtxt)

proc chan_tbtt_switch_evt*(tbttNode: pointer) {.exportc, cdecl.} =
  let saved = irqSave()
  defer: irqRestore(saved)
  chanTbttSwitchEvent(tbttNode, saved)

proc chan_pre_switch_channel*() {.exportc, cdecl.} =
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
  ##
  ## Port: publishing the target ends the switch (chanSwitchFinish). Before
  ## that, a switch that finds no target, or loses it during the port's RX
  ## drain, is abandoned there; the blob would return and leave MM in
  ## HW_ACTIVE. After it, the vendor tail always reaches mm_active.
  let env = chanEnvView()
  let serial = chanSwitchSerial()
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
        var event = 1'u8
        chan_cde_evt(addr event)
      elif ctxtCount == 1:
        targetCtxt = cast[pointer](env.activeList.first)
        env.scheduledCtxt = targetCtxt
    else:
      targetCtxt = schedCtxt
    # .L216: re-load the scheduled context slot (chan_cde_evt may have written it).
    if targetCtxt == nil:
      targetCtxt = env.scheduledCtxt
  if chanSwitchSerial() != serial: return
  if targetCtxt == nil:
    chanSwitchFinish(arrived = false)
    return
  let ctxt = chanCtxtAt(targetCtxt)
  nimFwDbgChanPreChanMeta = packChannelMeta(addr ctxt.channel)
  nimFwDbgChanPreChanFreq = packChannelFreq(addr ctxt.channel)
  # Preserve pending scan/ROC results. An ordinary operating-channel switch
  # follows the preceding force-idle RX reset directly into the PHY retune.
  let previousCtxt = env.currentCtxt
  if ctxt.contextIndexOrMarker in [3'u8, 4'u8] or
      previousCtxt == cast[pointer](chanCtxtForIdx(3)) or
      previousCtxt == cast[pointer](chanCtxtForIdx(4)):
    # RX processing can retire or replace the target (it then ends the switch).
    rxl_timer_int_handler()
    rxl_cntrl_evt()
    if chanSwitchSerial() != serial: return
    if env.scheduledCtxt != targetCtxt:
      chanSwitchFinish(arrived = false)
      return
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
  chanSwitchFinish(arrived = true)
  # Call chan_upd_ctxt_status to finalize
  chan_upd_ctxt_status(targetCtxt, 4)
  # Check context type for additional handling
  let contextIndexOrMarker = ctxt.contextIndexOrMarker
  if contextIndexOrMarker == 3:
    # .L219 -> .L232 -> .L233: scan type clears MAC scan state, queues the
    # scan-channel start indication, disables PM for the connectionless slot,
    # then reactivates the MAC before the queued indication is dispatched.
    regWrite(MACHW_BASE + 0x220'u, 0'u32)
    scanDwellPost(MM_SCAN_CHANNEL_START_IND)
    rfPhyTraceCheckpoint(0x45'u32)
    rfPhyTraceCheckpoint(0x46'u32)
    # The dwell holds the PM bit at 0 until it ends. chan.o saves the bit
    # here (+0x128) and restores it at the end; PS's own choice is applied
    # then instead (ps_machine.nim).
    psDwellBegin()
    rfPhyTraceCheckpoint(0x47'u32)
    mm_active()
    rfPhyTraceCheckpoint(0x48'u32)
  elif contextIndexOrMarker == 4:
    # .L232: ROC type -- the dwell holds the PM bit at 0 (blob 0x130).
    psDwellBegin()
    mm_active()
    waitRfUs(1000'u32)
  elif contextIndexOrMarker <= 2:
    mmReplayEdca()
    if psAwake():
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
              chanHomeWakeRequest(vif2, contextIndexOrMarker)
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
          # message parked by chan_ctxt_set_auth_assoc_req.
          smDeferredPublish(vif3)
        # Send postponed frames (blob passes vif entry pointer as a0)
        vif_mgmt_send_postponed_frame(vif3)
      vif3 = vif.next
    mm_active()

proc chanConnlessDelayEvent() =
  ## Caller holds the IRQ lock through the pending-to-active transition.
  ## Connectionless delay event handler (52 instrs, callback stored in chan_env).
  ## From blob: checks chan_env flags (offset 120):
  ##   bit 0 set: if bit 2 also set, assert_err; else clear bit 0, set bit 2.
  ##   bit 1 set: if bit 3 also set, assert_err; else clear bit 1, set bit 3.
  ##   Each valid transition starts its slot if no context is scheduled.
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
      return
    inc chanConnlessGeneration
    flags = flags and (not 0x01'u8)
    flags = flags or 0x04
    env.flags = flags
    if env.scheduledCtxt == nil:
      switchArg = cast[pointer](chanCtxtForIdx(4))
  elif (flags and 0x02) != 0:
    if (flags and 0x08) != 0:
      assert_err("chan.c", "chan.c", 888)
      return
    inc chanConnlessGeneration
    flags = flags and (not 0x02'u8)
    flags = flags or 0x08
    env.flags = flags
    if env.scheduledCtxt == nil:
      switchArg = cast[pointer](chanCtxtForIdx(3))
  if switchArg != nil:
    chan_switch_start(switchArg)

proc chan_conn_less_delay_evt*() {.exportc, cdecl.} =
  let saved = irqSave()
  defer: irqRestore(saved)
  chanConnlessDelayEvent()

proc chan_cde_evt*(param: pointer) {.exportc, cdecl.} =
  ## Channel distribution event handler (212 bytes in blob, 73 instrs).
  ## The callback argument points to the event byte (0, 1, or 2).
  ## From blob: reads macTime from MACHW, checks ctxtCnt > 1.
  ## State 0: call mm_timer_set with chan_env delay + macTime.
  ## States 1/2 arm the timer on first entry, then distribute and select.
  ## State 2 transfers an existing operation or starts the selected channel.
  if param == nil:
    return
  let saved = irqSave()
  defer: irqRestore(saved)
  let state = cast[ptr uint8](param)[]
  if state > 2: return
  let env = chanEnvView()
  let ctxtCnt = env.ctxtCount
  let flags = env.flags
  if ctxtCnt <= 1 or (state != 0 and (flags and 0x0C) != 0): return
  proc activeContext(target: pointer): bool =
    for index in 0'u8 ..< chanCtxtEpochs.len.uint8:
      let ctxt = chanCtxtForIdx(index)
      if cast[pointer](ctxt) == target:
        return ctxt.contextIndexOrMarker == index and ctxt.status != 0
    false
  # Timer programming can reenter channel management through platform callbacks.
  inc chanCdeGeneration
  let generation = chanCdeGeneration
  let resetEpoch = txResetEpoch
  let allocations = chanCtxtEpochs
  let bindings = chanCtxtLinkEpochs
  let currentCtxt = env.currentCtxt
  let scheduledCtxt = env.scheduledCtxt
  let currentView = if activeContext(currentCtxt): chanCtxtAt(currentCtxt) else: nil
  let scheduledView = if activeContext(scheduledCtxt): chanCtxtAt(scheduledCtxt) else: nil
  let currentStatus = if currentView != nil: currentView.status else: 0'u8
  let scheduledStatus = if scheduledView != nil: scheduledView.status else: 0'u8
  let currentIndex = if currentView != nil: currentView.contextIndexOrMarker else: 0xFF'u8
  let scheduledIndex = if scheduledView != nil: scheduledView.contextIndexOrMarker else: 0xFF'u8
  let period = env.slotPeriod
  var started = env.cdeStarted
  var lastTime = env.lastMacTime
  template current(): bool =
    chanCdeGeneration == generation and txResetEpoch == resetEpoch and
      equalMem(addr chanCtxtEpochs, unsafeAddr allocations, sizeof(allocations)) and
      equalMem(addr chanCtxtLinkEpochs, unsafeAddr bindings, sizeof(bindings)) and
      env.ctxtCount == ctxtCnt and env.flags == flags and env.slotPeriod == period and
      env.currentCtxt == currentCtxt and env.scheduledCtxt == scheduledCtxt and
      env.cdeStarted == started and env.lastMacTime == lastTime and
      (currentView == nil or (currentView.status == currentStatus and
        currentView.contextIndexOrMarker == currentIndex)) and
      (scheduledView == nil or (scheduledView.status == scheduledStatus and
        scheduledView.contextIndexOrMarker == scheduledIndex))
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()
  let macTime = regRead(MACHW_TIMLO_REG)
  if not current(): return
  if state == 0:
    outside: mm_timer_set(chanCdeTimer(), macTime + period)
    if current():
      outside: chan_distribute_slots()
    return
  if started == 0:
    started = 1
    env.cdeStarted = started
    outside: mm_timer_set(chanCdeTimer(), macTime + period)
    if not current(): return
  lastTime = macTime
  env.lastMacTime = lastTime
  outside: chan_distribute_slots()
  if not current(): return
  var nextChan: pointer
  outside: nextChan = chan_get_next_chan()
  if not current() or not activeContext(nextChan): return
  if state == 2:
    if scheduledCtxt == nil:
      outside: chan_switch_start(nextChan)
      return
    if scheduledCtxt == nextChan or not activeContext(scheduledCtxt): return
    chanCtxtAt(nextChan).status = chanCtxtAt(scheduledCtxt).status
    chanCtxtAt(scheduledCtxt).status = 1
  env.scheduledCtxt = nextChan

{.emit: "__attribute__((optimize(\"crossjumping\"))) void chan_ctxt_op_evt(void*);".}
proc chanCtxtOpEvent(ctxtPtr: pointer; saved: uint32) =
  ## Channel context operation event handler (468 bytes blob, ~147 instrs).
  ## Called as timer callback with a0 = channel context pointer.
  ## Blob call targets: chan_goto_idle_cb, chan_switch_start, chan_get_dominant_chan,
  ##   chan_get_next_chan, blmac_pwr_mgt_setf, ke_msg_send_basic,
  ##   chan_conn_less_delay_prog, chan_cde_evt, mm_force_idle_req, mm_back_to_host_idle.
  if ctxtPtr == nil:
    return
  var index = 0xFF'u8
  for candidate in 0'u8 ..< chanCtxtEpochs.len.uint8:
    if ctxtPtr == cast[pointer](chanCtxtForIdx(candidate)):
      index = candidate
      break
  if index == 0xFF: return
  let env = chanEnvView()
  let ctxt = chanCtxtAt(ctxtPtr)
  if ctxt.contextIndexOrMarker != index: return
  let status = ctxt.status
  var expectedStatus = status
  let resetEpoch = txResetEpoch
  var allocation = chanCtxtEpochs[index]
  let definition = ctxt.channel
  var expectedCurrent = env.currentCtxt
  var expectedScheduled = env.scheduledCtxt
  var retired = false
  template current(expectedResetEpoch: uint32 = resetEpoch): bool =
    txResetEpoch == expectedResetEpoch and chanCtxtEpochs[index] == allocation and
      ctxt.contextIndexOrMarker == (if retired: 0xFF'u8 else: index) and
      ctxt.status == expectedStatus and
      equalMem(addr ctxt.channel, unsafeAddr definition, sizeof(definition)) and
      env.currentCtxt == expectedCurrent and env.scheduledCtxt == expectedScheduled
  template outside(body: untyped) =
    irqRestore(saved)
    try: body
    finally: discard irqSave()

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
    # chan_goto_idle_cb starts a new protection generation, so confirmations
    # of the timed-out frames, flushed by its forced idle, no longer count.
    env.scanDelayCount = 0
    env.connlessDelayCount = 0
    outside: chan_goto_idle_cb()
    return

  # status > 4: return
  if status != 4:
    return

  # status == 4: dispatch on the context-index/marker byte at ctxt[23]
  let contextIndexOrMarker = ctxt.contextIndexOrMarker

  if contextIndexOrMarker <= 2:
    # sub 0-2: Set status=1, then switch channel
    ctxt.status = 1
    expectedStatus = 1
    let ctxtCnt = env.ctxtCount
    if ctxtCnt <= 1:
      # Zero or one context: tail-call chan_switch_start(chan_env[8]).
      let firstCtxt = cast[pointer](env.activeList.first)
      outside: chan_switch_start(firstCtxt)
      return
    if ctxtCnt >= 2:
      # Multiple contexts: adjust timing, get next/dominant, switch
      let macTime = regRead(MACHW_TIMLO_REG)
      if not current(): return
      let oldTime = env.lastMacTime
      let elapsed = ((macTime - oldTime) shr 10) and 0xFFFF'u32
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
        var dominant: pointer
        outside: dominant = chan_get_dominant_chan()
        if not current(): return
        if dominant != nil:
          nextChan = dominant
        outside: chan_switch_start(nextChan)
        return
      else:
        # >2 contexts: get next via chan_get_next_chan
        var nextChan: pointer
        outside: nextChan = chan_get_next_chan()
        if not current(): return
        outside: chan_switch_start(nextChan)
        return
  if env.currentCtxt != ctxtPtr: return
  # The dwell ends: PS's PM bit applies again (chan.o restores the bit saved
  # when the dwell began).
  outside: psDwellEnd()
  if not current(): return
  # Blob clears chan_env+0x20 (current context) for completed scan/ROC
  # context operations before retiring the context type. Without this, the
  # next scan reuses the scan context pointer and chan_switch_start can treat
  # the new channel as already current.
  env.currentCtxt = nil
  expectedCurrent = nil

  if contextIndexOrMarker == 4:
    if ctxt.invalidMarker == 0:
      env.flags = env.flags and not 0x40'u8
    env.flags = env.flags and not 0x04'u8
  elif contextIndexOrMarker == 3:
    env.flags = env.flags and not 0x08'u8
    scanDwellPost(MM_SCAN_CHANNEL_END_IND)
  # A switch to the slot (none is expected while it is current) is redirected.
  outside: chanSwitchRetire(ctxtPtr)
  expectedScheduled = env.scheduledCtxt
  if not current(): return
  ctxt.contextIndexOrMarker = 0xFF
  inc chanCtxtEpochs[index]
  allocation = chanCtxtEpochs[index]
  retired = true
  let curFlags = env.flags
  env.flags = curFlags and not 0x10'u8
  if (curFlags and 0x03) != 0:
    outside: chan_conn_less_delay_prog()
    if not current(): return
  let finalCnt = env.ctxtCount
  if finalCnt == 1:
    outside: chan_switch_start(cast[pointer](env.activeList.first))
  elif finalCnt > 1:
    var cdeParam: uint8 = 2
    outside: chan_cde_evt(addr cdeParam)
  else:
    var idle: bool
    outside: idle = chanForceIdle()
    # A successful forced idle runs txl_reset once. A second reset or a
    # replacement channel operation must not restore the old MAC state.
    if not idle or not current(resetEpoch + 1'u32) or env.ctxtCount != 0: return
    outside: mm_back_to_host_idle()

proc chan_ctxt_op_evt*(ctxtPtr: pointer) {.exportc, cdecl.} =
  if ctxtPtr == nil: return
  let saved = irqSave()
  defer: irqRestore(saved)
  chanCtxtOpEvent(ctxtPtr, saved)

proc chan_distribute_slots*() {.exportc, cdecl.} =
  ## Recompute per-context airtime from the linked VIFs and traffic credits.
  ## Transient join/AP changes hold the allocation for 50 distribution cycles.
  let env = chanEnvView()
  var contextCredits: array[3, uint16]
  var linkedVifs = 0'u32
  var hasLongListenInterval = false
  var updateSlots = false
  var configCycles = chanSlotConfigCycles
  var vifPtr = cast[pointer](vifMgmtEnvView().activeList.first)
  while vifPtr != nil:
    let vif = vifChannelAt(vifPtr)
    let chanCtxt = vif.chanCtxt
    if chanCtxt != nil:
      let ctxt = chanCtxtAt(chanCtxt)
      let index = ctxt.contextIndexOrMarker
      if index >= contextCredits.len.uint8 or vif.vifIdx >= MAX_VIFS.uint8:
        assert_warn("chan.c", "chan.c", 699)
        return
      inc linkedVifs
      contextCredits[index] += 2
      if vif.state == 0:
        if sm_reconn_dominant_flag != 0:
          env.dominantCtxt = chanCtxt
        contextCredits[index] += 8
        if configCycles == 0:
          configCycles = 50
          updateSlots = true
      let td = tdEntryAt(cast[pointer](cast[uint](addr td_env[0]) +
        vif.vifIdx.uint * sizeof(TdEntryView).uint))
      if (td.prevFlags and 3) != 0:
        inc contextCredits[index]
      if vif.vifType == VIF_TYPE_STA:
        if vif.listenInterval > 1:
          hasLongListenInterval = true
        if env.schedState == 1:
          if vif.state != 0:
            contextCredits[index] += 8
          env.schedState = 2
          updateSlots = true
      elif vif.vifType == VIF_TYPE_AP and vif.apChanSwitchPending != 0:
        vif.apChanSwitchPending = 0
        contextCredits[index] += 6
        if configCycles == 0:
          configCycles = 50
          updateSlots = true
    vifPtr = vif.next
  chanSlotConfigCycles = configCycles
  if linkedVifs != env.slotPeriod div 51200'u32:
    assert_warn("chan.c", "chan.c", 699)
  if not updateSlots and configCycles != 0:
    dec chanSlotConfigCycles
    return
  if chan_get_dominant_chan() != nil and configCycles == 0 and
      sm_reconn_dominant_flag != 0:
    env.dominantCtxt = nil
  let totalCredits = contextCredits[0].uint32 + contextCredits[1].uint32 +
    contextCredits[2].uint32
  let conflictFactor = if (env.flags and 0x80) != 0: 2'u32 else: 1'u32
  let slotBudget = conflictFactor * env.ctxtCount.uint32 * 50
  vifPtr = cast[pointer](vifMgmtEnvView().activeList.first)
  while vifPtr != nil:
    let vif = vifChannelAt(vifPtr)
    let chanCtxt = vif.chanCtxt
    if chanCtxt != nil:
      let ctxt = chanCtxtAt(chanCtxt)
      if hasLongListenInterval:
        if vif.vifType == VIF_TYPE_STA and vif.listenInterval > 1:
          ctxt.schedSlot = env.ctxtCount.uint16 * 50
        else:
          ctxt.schedSlot = 0xFFFF'u16
      else:
        let weightedSlots = slotBudget * contextCredits[ctxt.contextIndexOrMarker].uint32
        var slots = weightedSlots div totalCredits
        # Vendor rounds to nearest, with exact halves rounded down.
        if weightedSlots mod totalCredits > totalCredits div 2:
          inc slots
        ctxt.schedSlot = slots.uint16
      ctxt.opSlot = ctxt.schedSlot
      let beaconIntervalUs =
        if vif.vifType == VIF_TYPE_STA:
          if vif.staIdx < STA_INFO_TAB_ENTRIES.uint8:
            staInfoForIdx(vif.staIdx).initialRateConfig
          else:
            0'u32
        else:
          vif.apBeaconInterval.uint32 shl 10
      let beaconCount = if beaconIntervalUs != 0:
        max(1'u32, env.slotPeriod div beaconIntervalUs)
      else:
        1'u32
      ctxt.tbttSlot = ((beaconCount and 0xFF) * 20).uint16
    vifPtr = vif.next

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

proc chanTbttInsert(tbttNode: pointer; operation: var ChanTbttSnapshot;
                    callbackIrq: uint32): bool =
  ## Insert a TBTT node into the sorted scheduling list (372 bytes in blob, ~90 instrs).
  ## Two-phase algorithm matching blob (chan.o):
  ## Phase 1: walk chan_env+0x10 list finding insertion point & counting displacements.
  ## Phase 2: process displaced entries (extract, clear timers, re-queue to chan_env+0x18).
  ## Blob uses chan_tbtt_detect_conflict.isra.0 for wrapping time comparison.
  if tbttNode == nil:
    return false
  if not chanTbttCurrent(operation): return false
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
  var needInsert = true

  while scheduledTbttNode != nil:
    let scheduledTbtt = chanTbttNodeAt(cast[pointer](scheduledTbttNode))
    if scheduledTbtt == node:
      assert_err("chan.c", "chan.c", 1960)
      return false
    let scheduledTbttState = scheduledTbtt.state
    let scheduledTbttTime = scheduledTbtt.targetTime

    if scheduledTbttState == 2:
      if nodeTime < scheduledTbttTime or
          chan_tbtt_detect_conflict(nodeTime, scheduledTbttTime):
        # An in-progress TBTT cannot be displaced.
        displacedStart = cast[ptr CoListHdr](tbttNode)
        displaceCount = 1
        needInsert = false
        break
      insertAfter = scheduledTbttNode
    else:
      # Non-scheduled: use conflict detection
      if not chan_tbtt_detect_conflict(nodeTime, scheduledTbttTime):
        # No conflict: compare times for ordering
        if cast[int32](nodeTime - scheduledTbttTime) < 0:
          # Insert before scheduledTbttNode
          needInsert = true
          break
        insertAfter = scheduledTbttNode
      else:
        # Conflict: compare priorities
        let scheduledTbttPriority = scheduledTbtt.priority
        if scheduledTbttPriority >= nodePrio:
          # Priority grows with missed TBTTs; the existing node wins a tie.
          displacedStart = cast[ptr CoListHdr](tbttNode)
          displaceCount = 1
          needInsert = false
          break
        # Current lower priority: will be displaced
        displaceCount += 1
        if displacedStart == nil:
          displacedStart = scheduledTbttNode

    scheduledTbttNode = cast[ptr CoListHdr](scheduledTbttNode.next)

  # Phase 2: Re-insert displaced entries to resched queue
  var toProcess = displacedStart
  var remaining = displaceCount
  while remaining > 0:
    if toProcess == nil:
      assert_err("chan.c", "chan.c", 2033)
      return false
    let nextToProcess = toProcess.next
    let processNode = chanTbttNodeAt(cast[pointer](toProcess))
    if processNode != node:
      let pType = processNode.state
      if pType == 1:  # periodic type: clear timer
        processNode.state = 0
        if chanTbttDeferredSlot()[] == cast[pointer](toProcess):
          chanTbttDeferredSlot()[] = nil
        irqRestore(callbackIrq)
        try: mm_timer_clear(timerEnv)
        finally: discard irqSave()
        if not chanTbttCurrent(operation): return false
      co_list_extract(tbttList, toProcess)
    co_list_push_back(reschedList, toProcess)
    toProcess = nextToProcess
    remaining -= 1

  # Insert newNode into list. Blob always routes through co_list_insert_after
  # (which itself falls back to push_front when refElem is NULL) — keeping the
  # single call site matches blob's call-graph and lets the inner helper pick
  # the right head/tail branch without us materialising an extra push_front.
  if needInsert:
    co_list_insert_after(tbttList,
                         cast[ptr CoListHdr](insertAfter),
                         cast[ptr CoListHdr](tbttNode))
  true

proc chan_tbtt_insert*(tbttNode: pointer) {.exportc, cdecl.} =
  if tbttNode == nil: return
  let saved = irqSave()
  defer: irqRestore(saved)
  var operation: ChanTbttSnapshot
  chanTbttBegin(operation)
  discard chanTbttInsert(tbttNode, operation, saved)

proc chan_upd_ctxt_status*(chanCtxtPtr: pointer, newStatus: uint8) {.exportc, cdecl.} =
  ## Update channel context status (54 instrs).
  ## From blob: a0 = chan ctxt entry pointer, a1 = new status.
  ## Reads MAC timestamp from MACHW_TIMLO_REG (0x24B00120).
  ## Status 2 arms now+4000 us, plus 3000 us when multiple contexts exist.
  ## Status 4 uses scheduled slots for normal contexts when count > 1 and
  ## slots > 4, otherwise becomes status 5; reserved contexts use opSlot.
  ## Other inputs become status 3 without changing the existing timer.
  ## The context-op timer and its argument live at chan_env+0x4c/+0x54.
  if chanCtxtPtr == nil: return
  let saved = irqSave()
  defer: irqRestore(saved)
  var index = 0xFF'u8
  for candidate in 0'u8 ..< chanCtxtEpochs.len.uint8:
    if chanCtxtPtr == cast[pointer](chanCtxtForIdx(candidate)):
      index = candidate
      break
  if index == 0xFF: return
  let ctxt = chanCtxtForIdx(index)
  if ctxt.contextIndexOrMarker != index or ctxt.status == 0: return
  inc chanStatusGeneration
  let generation = chanStatusGeneration
  let resetEpoch = txResetEpoch
  let allocation = chanCtxtEpochs[index]
  let previousStatus = ctxt.status
  let env = chanEnvView()
  let current = env.currentCtxt
  let scheduled = env.scheduledCtxt
  let count = env.ctxtCount
  let lastTime = env.lastMacTime
  let macTime = regRead(MACHW_TIMLO_REG)
  if chanStatusGeneration != generation or txResetEpoch != resetEpoch or
      chanCtxtEpochs[index] != allocation or ctxt.contextIndexOrMarker != index or
      ctxt.status != previousStatus or env.currentCtxt != current or
      env.scheduledCtxt != scheduled or env.ctxtCount != count or
      env.lastMacTime != lastTime:
    return
  var status = newStatus
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
  # The state determines whether a deadline exists. Zero is a valid absolute
  # timestamp after MAC-clock wrap, not a request to cancel the timer.
  ctxt.status = status
  if status in {2'u8, 4'u8}:
    mmTimerAt(chanCtxtOpTimer()).env = cast[uint32](cast[uint](chanCtxtPtr))
    mmTimerSetLocked(chanCtxtOpTimer(), targetTime, saved)
  elif status != 3:
    mmTimerClearLocked(chanCtxtOpTimer(), saved)

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
  ## Reject frequencies that have no exact inverse in phy_channel_to_freq.
  if band == 0:
    # 2.4GHz: special case ch14 = 2484 MHz
    if freq == 2484: return 14
    let freqOffsetFromChannelOneMhz = freq.int - 2412
    if freqOffsetFromChannelOneMhz < 0 or freqOffsetFromChannelOneMhz > 60 or
        freqOffsetFromChannelOneMhz mod 5 != 0: return 0
    return ((freq.int - 2407) div 5).uint8
  elif band == 1:
    # The vendor range is 5005..5825 MHz, including channel 165.
    let freqOffsetFromFiveGhzBaseMhz = freq.int - 5005
    if freqOffsetFromFiveGhzBaseMhz < 0 or freqOffsetFromFiveGhzBaseMhz > 820 or
        freqOffsetFromFiveGhzBaseMhz mod 5 != 0: return 0
    return ((freq.int - 5000) div 5).uint8
  return 0

proc find_wpa_rsn_ie*(ieBuf: pointer, ieLen: uint32,
                       wpaOut: ptr pointer, rsnOut: ptr pointer) {.exportc, cdecl.} =
  let wpaOuiPtr = unsafeAddr WPA_OUI[0]
  wpaOut[] = wifiVendorIeFindBounded(ieBuf, ieLen, cast[pointer](wpaOuiPtr), 4)
  rsnOut[] = wifiIeFindBounded(ieBuf, ieLen, IE_ID_RSN)
