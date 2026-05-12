## M0 IPC timeout and stale-slot cleanup test.
##
## Runs without a D0 firmware. Two back-to-back M0->D0 RPC calls should time out
## and the second call proves the first timeout cleared the wire slot.

import bl808/startup
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/cps
import bl808/kernel/ipcbridge

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  RpcTagTimeout = 0x55'u16

var
  console: Uart
  timeoutCount = 0
  failed = false

proc printPassIfDone() =
  if timeoutCount == 2 and not failed:
    discard console.sendLine("[M0] IPC timeout cleanup [PASS]")

proc startTimeoutCall(n: int)

proc onTimeoutCallDone(fut: CpsFuture[uint32], n: int) =
  if hasError(fut):
    timeoutCount += 1
    discard console.sendString("[M0] timeout ")
    discard console.sendByte((ord('0') + n).uint8)
    discard console.sendLine(" [OK]")
    if n == 1:
      startTimeoutCall(2)
    else:
      printPassIfDone()
  else:
    failed = true
    discard console.sendLine("[M0] unexpected IPC response [FAIL]")

proc startTimeoutCall(n: int) =
  let fut = ipcCallU32(RpcTagTimeout, n.uint32, timeoutMs = 50)
  addCallback(fut, proc() = onTimeoutCallDone(fut, n))

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 IPC Timeout Test (M0) ===")

  heapInit()
  schedulerInit()
  ipcBridgeInit()

  startTimeoutCall(1)
  discard addTimerMs(1_000, proc() =
    if timeoutCount != 2:
      failed = true
      discard console.sendLine("[M0] IPC timeout cleanup [FAIL]")
  )

  runScheduler()
