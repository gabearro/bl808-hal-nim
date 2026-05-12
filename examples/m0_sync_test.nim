## M0 CPS kernel Phase 4 test — sync primitives, channels, tasks.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_sync_test.nim
## Run:   qemu-system-riscv32 -M bl808 -nographic -kernel examples/m0_sync_test
##
## Tests:
##   1. Channel: producer sends 5 values, consumer receives and prints them
##   2. Mutex: two tasks increment a shared counter under a mutex
##   3. Semaphore: three tasks compete for 2 permits
##   4. Event: one task waits for an event, another sets it after a delay
##   5. TaskGroup: spawn 3 tasks and awaitAll

import bl808/startup
import bl808/mmio, bl808/memmap, bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/irq
import bl808/kernel/cps

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var console: Uart

proc printInt(n: int) =
  if n == 0:
    discard console.sendByte(ord('0').uint8)
    return
  var buf: array[12, uint8]
  var i = 0
  var v = n
  if v < 0:
    discard console.sendByte(ord('-').uint8)
    v = -v
  while v > 0 and i < 12:
    buf[i] = (v mod 10).uint8 + ord('0').uint8
    v = v div 10
    inc i
  for j in countdown(i - 1, 0):
    discard console.sendByte(buf[j])

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)

proc runCoreEdgeChecks() =
  let originalRuntime = currentRuntime()
  let customRuntime = CpsRuntime(id: 99, flavor: rfCurrentThread)
  setCurrentRuntime(customRuntime)
  let customHandle = mainRuntime()
  let restoredHandle = originalRuntime.runtime.toHandle()
  var withRuntimeRestored = false
  withRuntime(restoredHandle):
    withRuntimeRestored = currentRuntime().runtime == originalRuntime.runtime
  check("Runtime handle helpers",
        customHandle.runtime == customRuntime and
        withRuntimeRestored and
        currentRuntime().runtime == customRuntime)
  setCurrentRuntime(originalRuntime.runtime)

  let zeroSem = newAsyncSemaphore(0)
  zeroSem.release()
  let semFut = zeroSem.acquire()
  check("Zero-initialized semaphore retains released permit",
        semFut.finished and not semFut.hasError)
  let probeSem = newAsyncSemaphore(1, maxPermits = 1)
  check("Semaphore inspection helpers",
        probeSem.availablePermits() == 1 and
        probeSem.tryAcquire() and
        probeSem.availablePermits() == 0 and
        not probeSem.tryAcquire() and
        probeSem.waitersCount() == 0)

  let err = newException(IOError, "expected edge-test failure")
  let joined = waitAll(completedLocalVoidFuture(), failedLocalVoidFuture(err))
  check("waitAll propagates child errors",
        joined.finished and joined.hasError)

  let tg = newTaskGroup("edge")
  tg.add(completedLocalVoidFuture(), "ok")
  tg.add(failedLocalVoidFuture(err), "failed")
  let groupDone = tg.awaitAll()
  check("TaskGroup propagates child errors",
        groupDone.finished and groupDone.hasError)
  let cancelGroup = newTaskGroup("cancel")
  let cancelFut = newLocalCpsVoidFuture()
  cancelGroup.add(cancelFut, "pending")
  cancelGroup.cancelAll()
  check("TaskGroup cancelAll cancels pending task", cancelFut.isCancelled)

  let slotsBefore = isrBridgeActiveSlotsCount()
  let isrFut = newLocalCpsVoidFuture()
  let slot = registerIsrFuture(isrFut)
  let registered = slot >= 0 and isrBridgeActiveSlotsCount() == slotsBefore + 1
  if slot >= 0:
    cancel(isrFut)
  check("Cancelled ISR future releases bridge slot",
        registered and isrBridgeActiveSlotsCount() == slotsBefore)
  check("ISR bridge overflow counter readable", isrBridgeOverflowCount() >= 0)

  let immediate = withTimeout(completedLocalFuture[int](42), 100)
  check("withTimeout preserves completed typed result",
        immediate.finished and not immediate.hasError and immediate.read() == 42)

  let bounded = newChannel[int](1)
  check("Bounded channel inspection helpers",
        bounded.isEmpty() and
        bounded.trySend(7) and
        bounded.isFull() and
        not bounded.trySend(8) and
        bounded.capacity() == 1)
  let (got, gotOk) = bounded.tryRecv()
  check("Bounded channel tryRecv", gotOk and got == 7 and bounded.isEmpty())
  let unbounded = newUnboundedChannel[int]()
  check("Unbounded channel isEmpty", unbounded.isEmpty())

  let mtx = newAsyncMutex()
  check("Mutex inspection helpers", mtx.tryLock() and mtx.isLocked())
  mtx.unlock()
  let evt = newAsyncEvent()
  let waiting = evt.wait()
  check("Event inspection helpers", not evt.isSet() and evt.waitersCount() == 1)
  evt.set()
  check("Event set releases waiter", evt.isSet() and waiting.finished)
  evt.clear()
  let barrier = newAsyncBarrier(2)
  let first = barrier.arrive()
  let second = barrier.arrive()
  check("Barrier releases all parties", first.finished and second.finished)

proc timeoutEdgeTask(): CpsVoidFuture {.cps.} =
  let stalled = newLocalCpsVoidFuture()
  let timed = withTimeout(stalled, 25, "sync timeout edge")
  await sleepMs(50)
  check("withTimeout fails stalled void future",
        timed.finished and timed.hasError and stalled.isCancelled)

# ---------------------------------------------------------------------------
# Test 1: Channel — producer/consumer
# ---------------------------------------------------------------------------

proc producer(ch: AsyncChannel[int]): CpsVoidFuture {.cps.} =
  var i = 0
  while i < 5:
    await ch.send(i * 10)
    await sleepMs(50)
    i += 1
  discard console.sendLine("[PRODUCER] done")

proc consumer(ch: AsyncChannel[int]): CpsVoidFuture {.cps.} =
  var total = 0
  var i = 0
  while i < 5:
    let val: int = await ch.recv()
    discard console.sendString("[CONSUMER] got ")
    printInt(val)
    discard console.sendLine("")
    total += val
    i += 1
  discard console.sendString("[CONSUMER] total=")
  printInt(total)
  discard console.sendLine(if total == 100: " [PASS]" else: " [FAIL]")

# ---------------------------------------------------------------------------
# Test 2: Mutex — two incrementers
# ---------------------------------------------------------------------------

var sharedCounter: int = 0

proc incrementer(mtx: AsyncMutex, name: string, count: int): CpsVoidFuture {.cps.} =
  var i = 0
  while i < count:
    await mtx.lock()
    let prev = sharedCounter
    await yieldNow()  # yield while holding lock — tests fairness
    sharedCounter = prev + 1
    mtx.unlock()
    i += 1
  discard console.sendString("[")
  discard console.sendString(name)
  discard console.sendLine("] done incrementing")

# ---------------------------------------------------------------------------
# Test 3: Semaphore — gated access
# ---------------------------------------------------------------------------

proc semWorker(sem: AsyncSemaphore, id: int): CpsVoidFuture {.cps.} =
  await sem.acquire()
  discard console.sendString("[SEM] worker ")
  printInt(id)
  discard console.sendLine(" acquired permit")
  await sleepMs(100)
  sem.release()
  discard console.sendString("[SEM] worker ")
  printInt(id)
  discard console.sendLine(" released permit")

# ---------------------------------------------------------------------------
# Test 4: Event — signal/wait
# ---------------------------------------------------------------------------

proc eventWaiter(evt: AsyncEvent): CpsVoidFuture {.cps.} =
  discard console.sendLine("[EVT] waiting for event...")
  await evt.wait()
  discard console.sendLine("[EVT] event received! [PASS]")

proc eventSetter(evt: AsyncEvent): CpsVoidFuture {.cps.} =
  await sleepMs(200)
  discard console.sendLine("[EVT] setting event")
  evt.set()

# ---------------------------------------------------------------------------
# Test 5: TaskGroup — structured concurrency
# ---------------------------------------------------------------------------

proc groupWorker(id: int, ms: uint64): CpsVoidFuture {.cps.} =
  await sleepMs(ms)
  discard console.sendString("[GROUP] worker ")
  printInt(id)
  discard console.sendLine(" done")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud,
    dataBits: data8,
    stopBits: stop1,
    parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 CPS Kernel Phase 4 Test ===")
  discard console.sendLine("Sync primitives, channels, tasks")
  discard console.sendLine("")

  heapInit()
  schedulerInit()

  discard console.sendLine("--- Core edge checks ---")
  runCoreEdgeChecks()
  discard timeoutEdgeTask()

  # Test 1: Channel
  discard console.sendLine("--- Test 1: Channel ---")
  let ch = newChannel[int](2)
  discard producer(ch)
  discard consumer(ch)

  # Test 2: Mutex
  discard console.sendLine("--- Test 2: Mutex ---")
  let mtx = newAsyncMutex()
  sharedCounter = 0
  discard incrementer(mtx, "INC-A", 5)
  discard incrementer(mtx, "INC-B", 5)

  # Test 3: Semaphore (2 permits, 3 workers)
  discard console.sendLine("--- Test 3: Semaphore ---")
  let sem = newAsyncSemaphore(2)
  discard semWorker(sem, 1)
  discard semWorker(sem, 2)
  discard semWorker(sem, 3)

  # Test 4: Event
  discard console.sendLine("--- Test 4: Event ---")
  let evt = newAsyncEvent()
  discard eventWaiter(evt)
  discard eventSetter(evt)

  # Test 5: TaskGroup
  discard console.sendLine("--- Test 5: TaskGroup ---")
  let tg = newTaskGroup("workers")
  tg.add(groupWorker(1, 100))
  tg.add(groupWorker(2, 200))
  tg.add(groupWorker(3, 150))
  # We can't await tg.awaitAll() from non-CPS main, but the tasks
  # will complete naturally via the scheduler.

  discard console.sendLine("")
  discard console.sendLine("[OK] All tests spawned, entering scheduler")
  discard console.sendLine("")

  runScheduler()
