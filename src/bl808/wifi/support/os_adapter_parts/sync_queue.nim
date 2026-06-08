## Semaphore, mutex, and queue adapter callbacks.

proc osSemCreate(init: uint32): pointer {.cdecl.} =
  result = c_calloc(1, sizeof(SimpleEventGroup).csize_t)
  if result != nil: cast[ptr SimpleEventGroup](result).bits = init
proc osSemDelete(sem: pointer) {.cdecl.} = c_free(sem)
proc osSemTake(sem: pointer; tick: uint32): int32 {.cdecl.} =
  if osEventGroupWait(sem, 1, 1, 1, tick) != 0: 0 else: -1
proc osSemGive(sem: pointer): int32 {.cdecl.} =
  discard osEventGroupSend(sem, 1)
  0
proc osMutexCreate(): pointer {.cdecl.} = cast[pointer](1)
proc osMutexDelete(mutex: pointer) {.cdecl.} = discard mutex
proc osMutexLock(mutex: pointer): int32 {.cdecl.} =
  discard mutex
  # Bare-metal M0 has no competing tasks; the shared state risk is IRQ re-entry.
  if osMutexDepth == 0:
    osMutexSavedIrq = osEnterCritical()
  inc osMutexDepth
  0
proc osMutexUnlock(mutex: pointer): int32 {.cdecl.} =
  discard mutex
  if osMutexDepth != 0:
    dec osMutexDepth
    if osMutexDepth == 0:
      osExitCritical(osMutexSavedIrq)
  0

proc osQueueCreate(queueLen, itemSize: uint32): pointer {.cdecl.} =
  let total = sizeof(SimpleQueue).uint + queueLen.uint * itemSize.uint
  result = c_calloc(1, total.csize_t)
  if result != nil:
    let q = cast[ptr SimpleQueue](result)
    q.itemSize = itemSize
    q.depth = queueLen
proc osQueueDelete(queue: pointer) {.cdecl.} = c_free(queue)
proc osQueueSendWait(queue, item: pointer; length, ticks: uint32; prio: cint): cint {.cdecl.} =
  discard ticks; discard prio
  if queue == nil: return -1
  let q = cast[ptr SimpleQueue](queue)
  if item == nil or length != q.itemSize or (q.writeIdx - q.readIdx) >= q.depth:
    return -1
  let slot = ptrAt(queue, sizeof(SimpleQueue).uint + (q.writeIdx mod q.depth).uint * q.itemSize.uint)
  copyMem(slot, item, q.itemSize.uint)
  inc q.writeIdx
  0
proc osQueueSend(queue, item: pointer; length: uint32): cint {.cdecl.} =
  osQueueSendWait(queue, item, length, 0, 0)
proc osQueueRecv(queue, item: pointer; length, tick: uint32): cint {.cdecl.} =
  if queue == nil or item == nil: return -1
  let q = cast[ptr SimpleQueue](queue)
  if length != q.itemSize: return -1
  var loops = if tick != 0: tick else: 1'u32
  while tick == BlOsWaitingForever or loops != 0:
    if q.readIdx != q.writeIdx:
      let slot = ptrAt(queue, sizeof(SimpleQueue).uint + (q.readIdx mod q.depth).uint * q.itemSize.uint)
      copyMem(item, slot, q.itemSize.uint)
      inc q.readIdx
      return 0
    if tick != BlOsWaitingForever:
      dec loops
    vendorPollOnce()
    rawDelay(128)
  -1
