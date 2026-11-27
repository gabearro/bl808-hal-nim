"""Exercise the real adapter with modeled clocks, IRQ state and polling.

These are cooperative bare-metal contracts, not an RTOS scheduler model.
"""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW
from test_wifi_message_allocation import run_program


SUPPORT = FW.parent / "support"


def source(events: str | None = None, sync: str | None = None,
           event_post: str | None = None) -> str:
    code = r'''
const BlOsWaitingForever = high(uint32)
var
  interrupts = true
  clock: uint64
  clockAvailable = true
  advanceDelay = true
  delayed: uint64
  polls, samples, copies, allocations, frees, saves, restores: int
  maxPolls = 1000
  lastAllocation: uint64
  failAllocation: bool
  live: seq[pointer]
  pollHook: proc() {.closure.}
  osMutexDepth, osMutexSavedIrq: uint32
  osTaskNotifications: uint32
proc calloc(n, size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc c_calloc(n, size: csize_t): pointer =
  inc allocations
  lastAllocation = n.uint64 * size.uint64
  if failAllocation: return nil
  doAssert lastAllocation <= 65536
  result = calloc(n, size)
  doAssert result != nil
  live.add(result)
proc c_free(p: pointer) =
  if p == nil: return
  let index = live.find(p)
  doAssert index >= 0, "double free or unknown allocation"
  live.delete(index)
  inc frees
  free(p)
proc ptrAt(p: pointer; offset: uint): pointer =
  cast[pointer](cast[uint](p) + offset)
proc osEnterCritical(): uint32 =
  inc saves
  result = interrupts.uint32 * 8
  interrupts = false
proc osExitCritical(saved: uint32) =
  inc restores
  interrupts = (saved and 8) != 0
proc copyMem(dest, src: pointer; size: uint) =
  doAssert not interrupts, "queue copy must precede publication under IRQ mask"
  doAssert dest != nil and src != nil
  inc copies
  system.copyMem(dest, src, size.int)
proc sampleMtimeUs(value: var uint64): bool =
  inc samples
  value = clock
  clockAvailable
proc delayMtimeUs(us: uint32) =
  doAssert interrupts, "blocking delay inside a critical section"
  delayed += us.uint64
  if advanceDelay: clock += us.uint64
proc rawDelay(loops: uint32) =
  doAssert false, "adapter waits must use time units, not raw loop counts"
proc vendorPollOnce() =
  doAssert interrupts, "polling inside a critical section"
  inc polls
  doAssert polls <= maxPolls, "wait did not terminate"
  if pollHook != nil: pollHook()
proc vendorNotifyWork() = discard
'''
    code += (SUPPORT / "defs_parts/local_types.nim").read_text()
    code += (SUPPORT / "os_adapter_parts/object_waits.nim").read_text()
    code += event_post if event_post is not None else r'''
proc aos_post_event(`type`, code: uint16; value: culong): cint = 0
'''
    code += events if events is not None else (SUPPORT / "os_adapter_parts/events_tasks.nim").read_text()
    code += sync if sync is not None else (SUPPORT / "os_adapter_parts/sync_queue.nim").read_text()
    return code


CASES = {
    "task_create_reports_failure": r'''
proc taskEntry(arg: pointer) {.cdecl.} =
  doAssert false, "unsupported task entry must not run"
var taskHandle = cast[pointer](0x1234'u)
doAssert osTaskCreate("worker", cast[pointer](taskEntry), 1024, nil, 1,
                      addr taskHandle) == -1
doAssert taskHandle == cast[pointer](0x1234'u)
doAssert polls == 0 and allocations == 0
''',
    "mutex_independent_locks": r'''
let first = osMutexCreate()
let second = osMutexCreate()
doAssert first != nil and second != nil and first != second
doAssert osMutexUnlock(first) == 1 and interrupts
doAssert osMutexLock(first) == 0 and not interrupts
doAssert osMutexLock(second) == 0 and not interrupts
doAssert osMutexLock(first) == 0 and osMutexDepth == 3
doAssert osMutexUnlock(second) == 0 and not interrupts
doAssert osMutexUnlock(second) == 1 and not interrupts
doAssert osMutexUnlock(first) == 0 and not interrupts
doAssert osMutexUnlock(first) == 0 and interrupts
doAssert osMutexDepth == 0
osMutexDelete(first)
osMutexDelete(second)
doAssert frees == 2
''',
    "mutex_deferred_delete": r'''
let mutex = osMutexCreate()
doAssert osMutexLock(mutex) == 0
osMutexDelete(mutex)
doAssert frees == 0 and not interrupts
doAssert osMutexLock(mutex) == 1 and not interrupts
doAssert osMutexUnlock(mutex) == 0 and interrupts
doAssert frees == 1 and osMutexDepth == 0
''',
    "mutex_invalid_handles": r'''
failAllocation = true
doAssert osMutexCreate() == nil
failAllocation = false
doAssert osMutexLock(nil) == 1 and osMutexUnlock(nil) == 1
osMutexDelete(nil)
let first = osMutexCreate()
let second = osMutexCreate()
doAssert osMutexLock(first) == 0
doAssert osMutexUnlock(second) == 1 and not interrupts
doAssert osMutexUnlock(first) == 0 and interrupts
osMutexDelete(first)
osMutexDelete(second)
doAssert frees == 2
''',
    "mutex_preserves_masked_state": r'''
let mutex = osMutexCreate()
interrupts = false
doAssert osMutexLock(mutex) == 0 and not interrupts
doAssert osMutexUnlock(mutex) == 0 and not interrupts
interrupts = true
osMutexDelete(mutex)
doAssert frees == 1
''',
    "event_snapshot_clear": r'''
let event = osEventGroupCreate()
doAssert osEventGroupSend(event, 0xA5) == 0xA5
doAssert osEventGroupWait(event, 5, 1, 1, 0) == 0xA5
doAssert osEventGroupWait(event, 1, 1, 0, 0) == 0xA0
doAssert osEventGroupSend(event, 3) == 0xA3
doAssert osEventGroupWait(event, 6, 1, 1, 0) == 0xA3
doAssert osEventGroupWait(event, 6, 1, 0, 0) == 0xA3
doAssert cast[ptr SimpleEventGroup](event).bits == 0xA1
doAssert polls == 0 and samples == 0
osEventGroupDelete(event)
''',
    "event_timeout_units": r'''
let event = osEventGroupCreate()
discard osEventGroupSend(event, 0x80)
doAssert osEventGroupWait(event, 3, 1, 1, 2) == 0x80
doAssert polls == 20 and delayed == 2000
doAssert cast[ptr SimpleEventGroup](event).bits == 0x80
osEventGroupDelete(event)
''',
    "event_last_quantum": r'''
let event = osEventGroupCreate()
pollHook = proc() =
  if polls == 10: discard osEventGroupSend(event, 0x83)
doAssert osEventGroupWait(event, 3, 1, 1, 1) == 0x83
doAssert polls == 10
doAssert cast[ptr SimpleEventGroup](event).bits == 0x80
osEventGroupDelete(event)
''',
    "event_broadcast": r'''
let event = osEventGroupCreate()
var nested = false
pollHook = proc() =
  if not nested:
    nested = true
    doAssert osEventGroupWait(event, 3, 1, 1, 1) == 0x83
  else:
    doAssert osEventGroupSend(event, 0x83) == 0x80
doAssert osEventGroupWait(event, 1, 1, 0, 1) == 0x83
doAssert polls == 2 and cast[ptr SimpleEventGroup](event).waiters == nil
doAssert cast[ptr SimpleEventGroup](event).bits == 0x80
osEventGroupDelete(event)
''',
    "event_nonmatching_waiter": r'''
let event = osEventGroupCreate()
var nested = false
var sent = false
pollHook = proc() =
  if not nested:
    nested = true
    doAssert osEventGroupWait(event, 3, 0, 1, 1) == 0x80
  elif not sent:
    sent = true
    discard osEventGroupSend(event, 0x81)
doAssert osEventGroupWait(event, 1, 1, 1, 1) == 0x81
doAssert cast[ptr SimpleEventGroup](event).bits == 0x80
osEventGroupDelete(event)
''',
    "event_delivered_before_delete": r'''
let event = osEventGroupCreate()
pollHook = proc() =
  discard osEventGroupSend(event, 0x81)
  osEventGroupDelete(event)
  doAssert frees == 0
doAssert osEventGroupWait(event, 1, 1, 1, BlOsWaitingForever) == 0x81
doAssert frees == 1 and polls == 1
''',
    "semaphore_binary": r'''
for initial in [0'u32, 1, 2, high(uint32)]:
  let sem = osSemCreate(initial)
  doAssert osSemTake(sem, 0) == (initial == 0).int32
  doAssert osSemTake(sem, 0) == 1
  doAssert osSemGive(sem) == 0
  doAssert osSemGive(sem) == 1
  doAssert osSemTake(sem, 0) == 0
  doAssert osSemTake(sem, 0) == 1
  osSemDelete(sem)
doAssert polls == 0 and samples == 0
''',
    "semaphore_wait": r'''
let sem = osSemCreate(0)
doAssert osSemTake(sem, 2) == 1
doAssert delayed == 2000 and polls == 20
pollHook = proc() = discard osSemGive(sem)
doAssert osSemTake(sem, BlOsWaitingForever) == 0
doAssert polls == 21
osSemDelete(sem)
''',
    "queue_fifo_fixed_items": r'''
let queue = osQueueCreate(3, 4)
var output: uint32
for batch in 0'u32 ..< 100:
  for i in 0'u32 ..< 3:
    var value = batch * 3 + i
    doAssert osQueueSendWait(queue, addr value, 0, 0, i.cint) == 0
  var overflow = high(uint32)
  doAssert osQueueSend(queue, addr overflow, 4) == 1
  for i in 0'u32 ..< 3:
    doAssert osQueueRecv(queue, addr output, high(uint32), 0) == 0
    doAssert output == batch * 3 + i
  doAssert osQueueRecv(queue, addr output, 4, 0) == 1
  let state = cast[ptr SimpleQueue](queue)
  doAssert state.readIdx < 3 and state.writeIdx < 3 and state.count == 0
doAssert copies == 600 and polls == 0
osQueueDelete(queue)
''',
    "queue_partial_wrap": r'''
let queue = osQueueCreate(3, 4)
var value, output: uint32
for i in 0'u32 ..< 3:
  value = i
  doAssert osQueueSend(queue, addr value, 4) == 0
for i in 0'u32 ..< 100:
  doAssert osQueueRecv(queue, addr output, 4, 0) == 0
  doAssert output == i
  value = i + 3
  doAssert osQueueSend(queue, addr value, 4) == 0
for i in 100'u32 ..< 103:
  doAssert osQueueRecv(queue, addr output, 4, 0) == 0 and output == i
osQueueDelete(queue)
''',
    "queue_send_wait": r'''
let queue = osQueueCreate(1, 4)
var first = 11'u32
var second = 22'u32
var output: uint32
doAssert osQueueSend(queue, addr first, 4) == 0
pollHook = proc() =
  doAssert osQueueRecv(queue, addr output, 4, 0) == 0 and output == 11
doAssert osQueueSendWait(queue, addr second, 4, 1, 9) == 0
doAssert polls == 1
doAssert osQueueRecv(queue, addr output, 4, 0) == 0 and output == 22
osQueueDelete(queue)
''',
    "queue_recv_wait": r'''
let queue = osQueueCreate(1, 4)
var value = 0x12345678'u32
var output: uint32
pollHook = proc() = doAssert osQueueSend(queue, addr value, 4) == 0
doAssert osQueueRecv(queue, addr output, 4, BlOsWaitingForever) == 0
doAssert polls == 1 and output == value
osQueueDelete(queue)
''',
    "queue_timeout_units": r'''
let queue = osQueueCreate(1, 4)
var value = 7'u32
doAssert osQueueRecv(queue, addr value, 4, 1) == 1
doAssert polls == 10 and delayed == 1000 and value == 7
doAssert osQueueSend(queue, addr value, 4) == 0
doAssert osQueueSendWait(queue, addr value, 4, 2, 0) == 1
doAssert polls == 30 and delayed == 3000
osQueueDelete(queue)
''',
    "queue_zero_size": r'''
let queue = osQueueCreate(2, 0)
doAssert osQueueSend(queue, nil, 0) == 0
doAssert osQueueSend(queue, nil, 123) == 0
doAssert osQueueSend(queue, nil, 0) == 1
doAssert osQueueRecv(queue, nil, 0, 0) == 0
doAssert osQueueRecv(queue, nil, 123, 0) == 0
doAssert osQueueRecv(queue, nil, 0, 0) == 1
doAssert copies == 0
osQueueDelete(queue)
''',
    "allocation_guards": r'''
doAssert osQueueCreate(0, 4) == nil
for sizes in [(high(uint32), 4'u32), (0x80000000'u32, 2'u32),
              (high(uint32), high(uint32))]:
  doAssert osQueueCreate(sizes[0], sizes[1]) == nil
doAssert allocations == 0
failAllocation = true
let overhead = sizeof(SimpleQueue).uint32
doAssert osQueueCreate(1, high(uint32) - overhead) == nil
doAssert allocations == 1 and lastAllocation == high(uint32).uint64
doAssert osQueueCreate(1, high(uint32) - overhead + 1) == nil
doAssert allocations == 1
doAssert osSemCreate(1) == nil and osEventGroupCreate() == nil
''',
    "invalid_handles_items": r'''
var value: uint32
doAssert osQueueSend(nil, addr value, 4) == 1
doAssert osQueueRecv(nil, addr value, 4, 1) == 1
doAssert osSemGive(nil) == 1 and osSemTake(nil, 1) == 1
doAssert osEventGroupSend(nil, 1) == 0
doAssert osEventGroupWait(nil, 1, 0, 0, 1) == 0
let queue = osQueueCreate(1, 4)
doAssert osQueueSend(queue, nil, 4) == 1
doAssert osQueueRecv(queue, nil, 4, 1) == 1
osQueueDelete(queue)
osQueueDelete(nil)
osSemDelete(nil)
osEventGroupDelete(nil)
doAssert polls == 0
''',
    "interrupt_masked_immediate_only": r'''
let event = osEventGroupCreate()
let sem = osSemCreate(0)
let queue = osQueueCreate(1, 4)
var value = 99'u32
interrupts = false
doAssert osEventGroupWait(event, 1, 0, 0, BlOsWaitingForever) == 0
doAssert osSemTake(sem, BlOsWaitingForever) == 1
doAssert osQueueRecv(queue, addr value, 4, BlOsWaitingForever) == 1
doAssert osQueueSend(queue, addr value, 4) == 0
doAssert osQueueSendWait(queue, addr value, 4, BlOsWaitingForever, 0) == 1
doAssert osQueueRecv(queue, addr value, 4, 0) == 0
doAssert osSemGive(sem) == 0 and osSemTake(sem, 0) == 0
doAssert osEventGroupSend(event, 0x81) == 0x81
doAssert osEventGroupWait(event, 1, 1, 1, 1) == 0x81
doAssert not interrupts and polls == 0 and samples == 0
interrupts = true
osQueueDelete(queue)
osSemDelete(sem)
osEventGroupDelete(event)
''',
    "clock_unavailable_stalled_rollover": r'''
let sem = osSemCreate(0)
for available in [false, true]:
  for moving in [false, true]:
    clockAvailable = available
    advanceDelay = moving
    clock = high(uint64) - 7
    let before = polls
    doAssert osSemTake(sem, 1) == 1
    doAssert polls - before == 10
doAssert delayed == 4000
osSemDelete(sem)
''',
    "clock_large_progress": r'''
let sem = osSemCreate(0)
pollHook = proc() = clock += high(uint32).uint64 * 1000
doAssert osSemTake(sem, high(uint32) - 1) == 1
doAssert polls == 1
osSemDelete(sem)
''',
    "delete_during_wait": r'''
let event = osEventGroupCreate()
pollHook = proc() =
  osEventGroupDelete(event)
  doAssert frees == 0
  doAssert osEventGroupSend(event, 1) == 0
doAssert osEventGroupWait(event, 1, 0, 0, 1) == 0
doAssert frees == 1
let sem = osSemCreate(0)
pollHook = proc() =
  osSemDelete(sem)
  doAssert frees == 1 and osSemGive(sem) == 1
doAssert osSemTake(sem, 1) == 1
doAssert frees == 2
let queue = osQueueCreate(1, 4)
var value = 7'u32
pollHook = proc() =
  osQueueDelete(queue)
  doAssert frees == 2 and osQueueSend(queue, addr value, 4) == 1
doAssert osQueueRecv(queue, addr value, 4, 1) == 1
doAssert frees == 3 and value == 7
let fullQueue = osQueueCreate(1, 4)
doAssert osQueueSend(fullQueue, addr value, 4) == 0
pollHook = proc() =
  osQueueDelete(fullQueue)
  doAssert frees == 3
doAssert osQueueSendWait(fullQueue, addr value, 4, 1, 0) == 1
doAssert frees == 4
''',
    "exception_cleanup": r'''
let event = osEventGroupCreate()
pollHook = proc() = raise newException(ValueError, "poll")
try:
  discard osEventGroupWait(event, 1, 0, 0, 1)
  doAssert false
except ValueError: discard
doAssert interrupts and cast[ptr SimpleEventGroup](event).header.users == 0
doAssert cast[ptr SimpleEventGroup](event).waiters == nil
doAssert osEventGroupSend(event, 1) == 1
osEventGroupDelete(event)
let sem = osSemCreate(0)
try:
  discard osSemTake(sem, 1)
  doAssert false
except ValueError: discard
doAssert cast[ptr SimpleSemaphore](sem).header.users == 0
osSemDelete(sem)
let queue = osQueueCreate(1, 4)
var value: uint32
try:
  discard osQueueRecv(queue, addr value, 4, 1)
  doAssert false
except ValueError: discard
doAssert cast[ptr SimpleQueue](queue).header.users == 0
osQueueDelete(queue)
''',
    "exception_after_delete": r'''
let event = osEventGroupCreate()
pollHook = proc() =
  osEventGroupDelete(event)
  doAssert frees == 0
  raise newException(ValueError, "deleted event")
try:
  discard osEventGroupWait(event, 1, 0, 0, 1)
  doAssert false
except ValueError: discard
doAssert frees == 1 and interrupts
let sem = osSemCreate(0)
pollHook = proc() =
  osSemDelete(sem)
  raise newException(ValueError, "deleted semaphore")
try:
  discard osSemTake(sem, 1)
  doAssert false
except ValueError: discard
doAssert frees == 2 and interrupts
let queue = osQueueCreate(1, 4)
var value: uint32
pollHook = proc() =
  osQueueDelete(queue)
  raise newException(ValueError, "deleted queue")
try:
  discard osQueueRecv(queue, addr value, 4, 1)
  doAssert false
except ValueError: discard
doAssert frees == 3 and interrupts
''',
    "replacement_during_wait": r'''
var event = osEventGroupCreate()
let oldEvent = event
pollHook = proc() =
  osEventGroupDelete(event)
  event = osEventGroupCreate()
  doAssert event != oldEvent
  discard osEventGroupSend(event, 0x42)
doAssert osEventGroupWait(oldEvent, 1, 0, 0, 1) == 0
doAssert osEventGroupWait(event, 2, 0, 0, 0) == 0x42
osEventGroupDelete(event)
var sem = osSemCreate(0)
let oldSem = sem
pollHook = proc() =
  osSemDelete(sem)
  sem = osSemCreate(1)
  doAssert sem != oldSem
doAssert osSemTake(oldSem, 1) == 1 and osSemTake(sem, 0) == 0
osSemDelete(sem)
var queue = osQueueCreate(1, 4)
let oldQueue = queue
var value = 22'u32
var output = 7'u32
pollHook = proc() =
  osQueueDelete(queue)
  queue = osQueueCreate(1, 4)
  doAssert queue != oldQueue
  doAssert osQueueSend(queue, addr value, 4) == 0
doAssert osQueueRecv(oldQueue, addr output, 4, 1) == 1 and output == 7
doAssert osQueueRecv(queue, addr output, 4, 0) == 0 and output == 22
osQueueDelete(queue)
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_adapter_waits(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case] + r'''
doAssert live.len == 0
doAssert interrupts and saves == restores
''')
