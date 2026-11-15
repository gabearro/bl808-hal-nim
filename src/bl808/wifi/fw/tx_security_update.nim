proc txSecurityUsesKey(desc, key: pointer): bool =
  for binding in txSecurityReservations:
    if binding.descriptor == desc and binding.key == key:
      return true

proc txSecurityQueueUsesKey(queue: ptr CoList; key: pointer): bool =
  var node = queue.first
  while node != nil:
    if txSecurityUsesKey(node, key):
      return true
    node = node.next

proc txSecurityBeginUpdate(key: pointer): bool =
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  if txlResetting():
    return false
  let index = rxMgtKeyIndex(key)
  if index < 0:
    return false
  let bit = 1'u32 shl index
  if (txSecurityUpdating and bit) != 0:
    return false
  txSecurityUpdating = txSecurityUpdating or bit
  var prepared = false
  defer:
    if not prepared:
      txSecurityUpdating = txSecurityUpdating and not bit

  # Complete every halt before moving any queue into a stack-owned batch.
  let ancestors = txActiveFlush
  var batches: array[NUM_TX_QUEUES, TxFlushBatch]
  var selected: array[NUM_TX_QUEUES, bool]
  defer: txlFlushScopeExit(ancestors)
  for ac in 0'u8 ..< NUM_TX_QUEUES.uint8:
    let active = txActiveDmaOwner
    if txSecurityQueueUsesKey(addr txControlAc(ac.uint32).pending, key) or
        txSecurityQueueUsesKey(txCfmList(ac.uint32), key) or
        (active != nil and not active.cancelled and active.ac == ac and
          txSecurityUsesKey(active.desc, key)):
      if not txl_cntrl_halt_ac(ac): return false
      selected[ac] = true
  for ac in 0'u8 ..< NUM_TX_QUEUES.uint8:
    if selected[ac]:
      txlDetachAc(ac, 0x40000000'u32, batches[ac])
  for ac in 0'u8 ..< NUM_TX_QUEUES.uint8:
    if selected[ac]:
      txl_cfm_flush(ac, addr batches[ac].confirmations, batches[ac].status)
      txl_cfm_flush(ac, addr batches[ac].pending, batches[ac].status)
  prepared = true
  true

proc txSecurityEndUpdate(key: pointer) =
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  let index = rxMgtKeyIndex(key)
  if index >= 0:
    txSecurityUpdating = txSecurityUpdating and not (1'u32 shl index)
