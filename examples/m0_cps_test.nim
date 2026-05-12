## M0 CPS kernel Phase 1 test — verify CPS transform + runtime on bare metal.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_cps_test.nim
##
## This test:
##   1. Initializes the TLSF heap allocator
##   2. Defines a {.cps.} proc that awaits a pre-completed future
##   3. Runs it via the trampoline
##   4. Prints results on UART

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

# ---------------------------------------------------------------------------
# Simple CPS procs to test the transform + runtime
# ---------------------------------------------------------------------------

proc computeValue(x: int): CpsFuture[int] {.cps.} =
  ## A CPS proc that returns immediately (no-await fast path).
  return x * 2 + 1

proc testBasicCps(): CpsVoidFuture {.cps.} =
  ## A CPS proc that awaits another CPS proc.
  let val: int = await computeValue(21)
  if val == 43:
    discard console.sendLine("[PASS] CPS await returned correct value: 43")
  else:
    discard console.sendLine("[FAIL] CPS await returned wrong value")

proc testMultipleAwaits(): CpsVoidFuture {.cps.} =
  ## Test multiple sequential awaits.
  let a: int = await computeValue(10)
  let b: int = await computeValue(20)
  let c: int = await computeValue(30)
  if a == 21 and b == 41 and c == 61:
    discard console.sendLine("[PASS] Multiple awaits correct: 21, 41, 61")
  else:
    discard console.sendLine("[FAIL] Multiple awaits returned wrong values")

proc testPrecompletedFuture(): CpsVoidFuture {.cps.} =
  ## Test awaiting a pre-completed future (fast path).
  let precomp = completedFuture[int](99)
  let val: int = await precomp
  if val == 99:
    discard console.sendLine("[PASS] Pre-completed future: 99")
  else:
    discard console.sendLine("[FAIL] Pre-completed future wrong")

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
  discard console.sendLine("=== BL808 CPS Kernel Phase 1 Test ===")

  # Init heap allocator (required for mm:arc ref objects)
  heapInit()
  discard console.sendLine("[OK] Heap initialized")

  # Report heap stats
  let stats = heapStats()
  discard console.sendString("  Total: ")
  console.sendHex32(stats.totalBytes.uint32)
  discard console.sendLine(" bytes")

  # Run CPS tests via trampoline
  discard console.sendLine("")
  discard console.sendLine("Running CPS tests...")

  runCps(testBasicCps())
  runCps(testMultipleAwaits())
  runCps(testPrecompletedFuture())

  discard console.sendLine("")
  discard console.sendLine("=== Phase 1 Complete ===")

  # Report final heap stats
  let finalStats = heapStats()
  discard console.sendString("  Heap used: ")
  console.sendHex32(finalStats.usedBytes.uint32)
  discard console.sendString(" / ")
  console.sendHex32(finalStats.totalBytes.uint32)
  discard console.sendLine(" bytes")
  discard console.sendString("  Allocs: ")
  console.sendHex32(finalStats.allocCount.uint32)
  discard console.sendString("  Frees: ")
  console.sendHex32(finalStats.freeCount.uint32)
  discard console.sendLine("")

  # Idle
  while true:
    wfi()
