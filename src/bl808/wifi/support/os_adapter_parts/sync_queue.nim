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
proc osMutexCreate(): pointer {.cdecl.} =
  c_calloc(1, sizeof(SimpleMutex).csize_t)
proc osMutexDelete(mutex: pointer) {.cdecl.} = osObjectDelete(mutex)
proc osMutexLock(mutex: pointer): int32 {.cdecl.} =
  if mutex == nil:
    return 1
  let state = cast[ptr SimpleMutex](mutex)
  let saved = osEnterCritical()
  if state.header.deleted or state.header.users == high(uint32) or
      osMutexDepth == high(uint32):
    osExitCritical(saved)
    return 1
  # The global depth keeps IRQs masked until every held mutex is released.
  if osMutexDepth == 0:
    osMutexSavedIrq = saved
  inc state.header.users
  inc osMutexDepth
  osExitCritical(0)
  0
proc osMutexUnlock(mutex: pointer): int32 {.cdecl.} =
  if mutex == nil:
    return 1
  let state = cast[ptr SimpleMutex](mutex)
  let saved = osEnterCritical()
  if state.header.users == 0 or osMutexDepth == 0:
    osExitCritical(saved)
    return 1
  dec state.header.users
  dec osMutexDepth
  let dispose = state.header.deleted and state.header.users == 0
  if osMutexDepth == 0:
    osExitCritical(osMutexSavedIrq)
  else:
    osExitCritical(0)
  if dispose:
    c_free(mutex)
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
