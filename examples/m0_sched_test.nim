## M0 CPS kernel Phase 2 test — scheduler + sleep with concurrent tasks.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_sched_test.nim
## Run:   qemu-system-riscv32 -M bl808 -nographic -kernel examples/m0_sched_test
##
## Two CPS tasks run concurrently via the cooperative scheduler:
##   Task A prints every 500ms
##   Task B prints every 250ms
## Expected: interleaved output with B printing twice per A.

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
var pollHookTicks = 0
var usTimerFired = false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc printTick(prefix: string) =
  let t = readTick()
  discard console.sendString(prefix)
  discard console.sendString(" tick=")
  console.sendHex32((t shr 32).uint32)
  console.sendHex32((t and 0xFFFFFFFF'u64).uint32)
  discard console.sendLine("")

# ---------------------------------------------------------------------------
# Concurrent CPS tasks
# ---------------------------------------------------------------------------

proc taskA(): CpsVoidFuture {.cps.} =
  ## Prints every 500ms, 6 times.
  var count = 0
  while count < 6:
    await sleepMs(500)
    printTick("[A] 500ms")
    count += 1
  discard console.sendLine("[A] done")

proc taskB(): CpsVoidFuture {.cps.} =
  ## Prints every 250ms, 12 times.
  var count = 0
  while count < 12:
    await sleepMs(250)
    printTick("[B] 250ms")
    count += 1
  discard console.sendLine("[B] done")

proc taskC(): CpsVoidFuture {.cps.} =
  ## Prints every 1000ms, 3 times.
  var count = 0
  while count < 3:
    await sleepMs(1000)
    printTick("[C] 1000ms")
    count += 1
  discard console.sendLine("[C] done")

proc yieldTest(): CpsVoidFuture {.cps.} =
  ## Tests yieldNow — should interleave with other tasks.
  discard console.sendLine("[Y] yielding 3 times")
  await yieldNow()
  discard console.sendLine("[Y] after yield 1")
  await yieldNow()
  discard console.sendLine("[Y] after yield 2")
  await yieldNow()
  discard console.sendLine("[Y] done")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc main() {.exportc, cdecl.} =
  systemInit()

  # Init UART
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
  discard console.sendLine("=== BL808 CPS Kernel Phase 2 Test ===")
  discard console.sendLine("Scheduler + sleep with concurrent tasks")
  discard console.sendLine("")

  # Init heap + scheduler
  heapInit()
  schedulerInit()
  discard clockGetTickRate()
  disableTimerIrq()
  enableTimerIrq()
  setSchedulerPollHook(proc() =
    if pollHookTicks < 3:
      pollHookTicks.inc
  )
  discard addTimerUs(100, proc() =
    usTimerFired = true
    discard console.sendLine("[T] 100us timer [PASS]")
  )

  discard console.sendLine("[OK] Heap + scheduler initialized")
  printTick("[  ] start")
  discard console.sendLine("")

  # Spawn concurrent tasks. Calling each proc starts executing through
  # the CPS trampoline until the first `await`, which suspends and
  # registers callbacks with the scheduler. We discard the returned
  # futures since the scheduler drives them to completion.
  discard taskA()
  discard taskB()
  discard taskC()
  discard yieldTest()

  discard console.sendLine("[OK] All tasks spawned, entering scheduler")
  discard console.sendLine("")

  # Enter the scheduler — drives all tasks to completion.
  runScheduler()
