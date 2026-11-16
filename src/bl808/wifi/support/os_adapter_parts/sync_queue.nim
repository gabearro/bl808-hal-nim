## Semaphore, mutex, and queue adapter callbacks.

proc osSemCreate(init: uint32): pointer {.cdecl.} =
  result = c_calloc(1, sizeof(SimpleSemaphore).csize_t)
  if result != nil:
    cast[ptr SimpleSemaphore](result).available = init != 0
proc osSemDelete(sem: pointer) {.cdecl.} = osObjectDelete(sem)
proc osSemTake(sem: pointer; tick: uint32): int32 {.cdecl.} =
  if not osObjectRetain(sem):
    return 1
  defer: osObjectRelease(sem)
  let semaphore = cast[ptr SimpleSemaphore](sem)
  var state = osWaitState(tick)
  var waitMore = tick != 0
  while true:
    block:
      let saved = osEnterCritical()
      defer: osExitCritical(saved)
      if semaphore.header.deleted:
        return 1
      if semaphore.available:
        semaphore.available = false
        return 0
      if not waitMore:
        return 1
    waitMore = osWaitAgain(state)
proc osSemGive(sem: pointer): int32 {.cdecl.} =
  if not osObjectRetain(sem):
    return 1
  defer: osObjectRelease(sem)
  let semaphore = cast[ptr SimpleSemaphore](sem)
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  if semaphore.header.deleted or semaphore.available:
    return 1
  semaphore.available = true
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
  if queueLen == 0:
    return nil
  let total = sizeof(SimpleQueue).uint64 + queueLen.uint64 * itemSize.uint64
  if total > high(uint32).uint64:
    return nil
  result = c_calloc(1, total.csize_t)
  if result != nil:
    let queueState = cast[ptr SimpleQueue](result)
    queueState.itemSize = itemSize
    queueState.depth = queueLen
proc osQueueDelete(queue: pointer) {.cdecl.} = osObjectDelete(queue)
proc osQueueSendWait(queue, item: pointer; length, ticks: uint32; prio: cint): cint {.cdecl.} =
  discard length; discard prio
  if not osObjectRetain(queue):
    return 1
  defer: osObjectRelease(queue)
  let queueState = cast[ptr SimpleQueue](queue)
  if item == nil and queueState.itemSize != 0:
    return 1
  var state = osWaitState(ticks)
  var waitMore = ticks != 0
  while true:
    block:
      let saved = osEnterCritical()
      defer: osExitCritical(saved)
      if queueState.header.deleted:
        return 1
      if queueState.count < queueState.depth:
        if queueState.itemSize != 0:
          let slot = ptrAt(queue, sizeof(SimpleQueue).uint +
            queueState.writeIdx.uint * queueState.itemSize.uint)
          copyMem(slot, item, queueState.itemSize.uint)
        if queueState.writeIdx == queueState.depth - 1:
          queueState.writeIdx = 0
        else:
          inc queueState.writeIdx
        inc queueState.count
        return 0
      if not waitMore:
        return 1
    waitMore = osWaitAgain(state)
proc osQueueSend(queue, item: pointer; length: uint32): cint {.cdecl.} =
  osQueueSendWait(queue, item, length, 0, 0)
proc osQueueRecv(queue, item: pointer; length, tick: uint32): cint {.cdecl.} =
  discard length
  if not osObjectRetain(queue):
    return 1
  defer: osObjectRelease(queue)
  let queueState = cast[ptr SimpleQueue](queue)
  if item == nil and queueState.itemSize != 0:
    return 1
  var state = osWaitState(tick)
  var waitMore = tick != 0
  while true:
    block:
      let saved = osEnterCritical()
      defer: osExitCritical(saved)
      if queueState.header.deleted:
        return 1
      if queueState.count != 0:
        if queueState.itemSize != 0:
          let slot = ptrAt(queue, sizeof(SimpleQueue).uint +
            queueState.readIdx.uint * queueState.itemSize.uint)
          copyMem(item, slot, queueState.itemSize.uint)
        if queueState.readIdx == queueState.depth - 1:
          queueState.readIdx = 0
        else:
          inc queueState.readIdx
        dec queueState.count
        return 0
      if not waitMore:
        return 1
    waitMore = osWaitAgain(state)
