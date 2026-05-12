## M0 CPS kernel Phase 3 test — async UART echo via ISR bridge.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_uart_async_test.nim
## Run:   qemu-system-riscv32 -M bl808 -nographic -kernel examples/m0_uart_async_test
##
## Type characters in the QEMU console. Each character is received via
## interrupt-driven async I/O and echoed back. A background timer task
## prints heartbeats every 2 seconds to demonstrate concurrent operation.

import bl808/startup
import bl808/mmio, bl808/memmap, bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/irq
import bl808/kernel/cps
import bl808/kernel/asyncuart

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var console: Uart

# ---------------------------------------------------------------------------
# Async echo task — receives characters via ISR-driven UART
# ---------------------------------------------------------------------------

proc echoTask(au: AsyncUart): CpsVoidFuture {.cps.} =
  discard console.sendLine("Type characters (async echo, 'q' to quit)...")
  var running = true
  while running:
    let ch: uint8 = await au.recv()
    # Echo the character back
    discard console.sendByte(ch)
    # Print hex value
    discard console.sendString(" [0x")
    console.sendHex32(ch.uint32)
    discard console.sendLine("]")
    if ch == ord('q').uint8:
      running = false
  discard console.sendLine("[ECHO] Done — received 'q'")

# ---------------------------------------------------------------------------
# Heartbeat task — demonstrates concurrent operation with ISR-driven task
# ---------------------------------------------------------------------------

proc heartbeatTask(): CpsVoidFuture {.cps.} =
  var count = 0
  while count < 5:
    await sleepMs(2000)
    discard console.sendString("[HEARTBEAT] ")
    let t = readTick()
    console.sendHex32((t shr 32).uint32)
    console.sendHex32((t and 0xFFFFFFFF'u64).uint32)
    discard console.sendLine("")
    count += 1
  discard console.sendLine("[HEARTBEAT] Done — 5 beats")

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
  discard console.sendLine("=== BL808 CPS Kernel Phase 3 Test ===")
  discard console.sendLine("Async UART echo via ISR bridge")
  discard console.sendLine("")

  # Init heap + scheduler
  heapInit()
  schedulerInit()

  # Create async UART on UART0 (IRQ 44, index 0)
  let au = initAsyncUart(console, IrqM0Uart0, 0)

  discard console.sendLine("[OK] Async UART initialized")
  discard console.sendLine("")

  # Spawn tasks
  discard echoTask(au)
  discard heartbeatTask()

  discard console.sendLine("[OK] Tasks spawned, entering scheduler")
  discard console.sendLine("")

  # Enter scheduler — drives both tasks concurrently
  runScheduler()
